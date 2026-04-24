# ==============================================================================
# MÓDULO: ad_funciones.ps1 (VERSIÓN DEFINITIVA Y SINCRONIZADA)
# PROPÓSITO: Creación Idempotente, Horarios UTC y Excepciones de Admin
# ==============================================================================

# Función interna de cálculo matemático
function Convertir-HorarioABytesUTC {
    param([int]$horaInicioLocal, [int]$horaFinLocal)
    [byte[]]$horasBytes = New-Object byte[] 21
    $desfaseUTC = -7 # Huso horario Los Mochis (UTC-7)
    $inicioUTC = ($horaInicioLocal - $desfaseUTC) % 24
    $finUTC = ($horaFinLocal - $desfaseUTC) % 24

    for ($dia = 0; $dia -lt 7; $dia++) {
        for ($hora = 0; $hora -lt 24; $hora++) {
            $permitido = $false
            if ($inicioUTC -lt $finUTC) {
                if ($hora -ge $inicioUTC -and $hora -lt $finUTC) { $permitido = $true }
            } else {
                if ($hora -ge $inicioUTC -or $hora -lt $finUTC) { $permitido = $true }
            }
            if ($permitido) {
                $byteIndex = [math]::Floor((($dia * 24) + $hora) / 8)
                $bitIndex = (($dia * 24) + $hora) % 8
                $horasBytes[$byteIndex] = $horasBytes[$byteIndex] -bor ([math]::Pow(2, $bitIndex))
            }
        }
    }
    return ,$horasBytes
}

# La función principal con el nombre exacto que busca tu menú
# La función principal blindada contra rutas vacías y saltos de línea
function Sync-IdentidadesCSV {
    param([string]$RutaCSV)

    Write-Host "`n[*] Sincronizando Identidades y Horarios (Zero-Trust)..." -ForegroundColor Yellow

    # 1. AUTODESCUBRIMIENTO INFALIBLE DE RUTAS
    # Si la ruta global falla, triangulamos la posicion real del script
    $basePath = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\")
    $rutaJSON = Join-Path $basePath "config\reglas_gobernanza.json"
    
    if (-not $RutaCSV -or -not (Test-Path $RutaCSV -ErrorAction SilentlyContinue)) {
        $RutaCSV = Join-Path $basePath "config\usuarios.csv"
    }

    if (-not (Test-Path $rutaJSON)) {
        Write-Host "  [!] ERROR CRITICO: No se encuentra reglas_gobernanza.json en: $rutaJSON" -ForegroundColor Red
        return
    }
    if (-not (Test-Path $RutaCSV)) {
        Write-Host "  [!] ERROR CRITICO: No se encuentra usuarios.csv en: $RutaCSV" -ForegroundColor Red
        return
    }

    try {
        $reglasJSON = Get-Content $rutaJSON -Raw | ConvertFrom-Json
        $domainInfo = Get-ADDomain -ErrorAction Stop
    } catch {
        Write-Host "  [!] ERROR: El Servidor no es Controlador de Dominio o el JSON esta corrupto." -ForegroundColor Red
        return
    }
    
    $domainName = $domainInfo.NetBIOSName
    $domainDN = $domainInfo.DistinguishedName
    $recursoCompartido = "\\$env:COMPUTERNAME\Perfiles_P8"
    $recursoPerfiles = "\\$env:COMPUTERNAME\RoamingProfiles$"

    # 2. CREACIÓN DE ESTRUCTURA CENTRAL (OUs y Grupos)
    $ouBase = "OU=Gobernanza,$domainDN"
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Gobernanza'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name "Gobernanza" -Path $domainDN | Out-Null
    }

    foreach ($grupo in $reglasJSON.GruposDefinidos) {
        $nombreGrupo = $grupo.NombreDepartamento
        $ouPath = "OU=$nombreGrupo,$ouBase"
        
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$nombreGrupo'" -SearchBase $ouBase -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $nombreGrupo -Path $ouBase | Out-Null
        }

        if (-not (Get-ADGroup -Filter "Name -eq 'Grupo_$nombreGrupo'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name "Grupo_$nombreGrupo" -GroupCategory Security -GroupScope Global -Path $ouPath | Out-Null
        }
    }

    # 3. PROCESAMIENTO DEL CSV (Con Filtro Anti-Crash)
    $usuariosData = Import-Csv -Path $RutaCSV -ErrorAction Stop

        foreach ($user in $usuariosData) {
        if ([string]::IsNullOrWhiteSpace($user.Usuario)) { continue }

        $username = $user.Usuario.Trim()
        
        # --- LÓGICA DE DISTRIBUCIÓN DINÁMICA ---
        # Filtramos la palabra para que el CSV sea flexible (Ej. "Cuate" o "No Cuate")
        $deptRaw = $user.Departamento.Trim()
        $departamento = if ($deptRaw -match "No") { "No Cuates" } else { "Cuates" }
        
        $targetOU = "OU=$departamento,$ouBase"
        $nombreGrupoSeguridad = "Grupo_$departamento"
        # ---------------------------------------

        $homeDirectory = "$recursoCompartido\$username"
        $profilePath = "$recursoPerfiles\$username"
        
        $reglaAsignada = $reglasJSON.GruposDefinidos | Where-Object { $_.NombreDepartamento -eq $departamento }
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$username'" -ErrorAction SilentlyContinue
        
        # Salvaguarda por si la columna de password viene vacía
        $passString = if ($user.Password) { $user.Password.Trim() } else { "ZeroTrust.2026*" }
        $pass = ConvertTo-SecureString $passString -AsPlainText -Force

        # Lógica Idempotente (Crear o Actualizar)
        if (-not $adUser) {
            Write-Host "  [+] Creando nuevo usuario: $username" -ForegroundColor Green
            try {
                New-ADUser -SamAccountName $username -UserPrincipalName "$username@$($domainInfo.DNSRoot)" `
                           -Name "$($user.Nombre)" -GivenName $user.Nombre `
                           -AccountPassword $pass -Enabled $true -Path $targetOU
            } catch {
                Write-Host "      [X] Fallo al crear $username : $($_.Exception.Message)" -ForegroundColor Red
                continue
            }
        } else {
            Write-Host "  [~] Actualizando usuario existente: $username" -ForegroundColor Cyan
            Set-ADAccountPassword -Identity $username -NewPassword $pass -Reset:$true -ErrorAction SilentlyContinue
            
            $currentOU = ($adUser.DistinguishedName -split ',', 2)[1]
            if ($currentOU -ne $targetOU) {
                Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $targetOU -ErrorAction SilentlyContinue | Out-Null
            }
        }

        # 4. APLICACIÓN DE HORARIOS Y PERFILES (Manejo del Administrador Supremo)
        $scriptLogon = "redireccion_carpetas.bat"

        if ($reglasJSON.AdministradoresSupremos -contains $username) {
            Write-Host "      [*] $username es ADMIN SUPREMO. Acceso 24/7 sin restricciones." -ForegroundColor Magenta
            try {
                Set-ADUser -Identity $username -Title $departamento -Department $departamento `
                           -HomeDrive "H:" -HomeDirectory $homeDirectory `
                           -ProfilePath $profilePath -ScriptPath $scriptLogon -Clear LogonHours -ErrorAction Stop
            } catch {}
        } else {
            if ($reglaAsignada) {
                [byte[]]$horasBytes = Convertir-HorarioABytesUTC -horaInicioLocal $reglaAsignada.HorarioPermitido.HoraInicio -horaFinLocal $reglaAsignada.HorarioPermitido.HoraFin
                
                Set-ADUser -Identity $username -Title $departamento -Department $departamento `
                           -HomeDrive "H:" -HomeDirectory $homeDirectory `
                           -ProfilePath $profilePath -ScriptPath $scriptLogon -ErrorAction SilentlyContinue
                
                Set-ADUser -Identity $username -Clear logonhours -ErrorAction SilentlyContinue
                Set-ADUser -Identity $username -Replace @{logonhours = $horasBytes} -ErrorAction SilentlyContinue
                
                Write-Host "      -> Horario UTC, Perfil Movil y Redireccion inyectados." -ForegroundColor DarkGray
            }
        }

        # 5. ASIGNACIÓN ESTRICTA DE GRUPOS
        foreach ($grp in $reglasJSON.GruposDefinidos.NombreDepartamento) {
            Remove-ADGroupMember -Identity "Grupo_$grp" -Members $username -Confirm:$false -ErrorAction SilentlyContinue
        }
        Add-ADGroupMember -Identity $nombreGrupoSeguridad -Members $username -ErrorAction SilentlyContinue
    }
    
    Write-Host "[OK] Motor de Sincronizacion CSV ejecutado con exito." -ForegroundColor Green
}
function Instalar-InfraestructuraCore {
    Write-Host "[*] INICIANDO ORQUESTACION DE FASE 0: AD DS, DNS Y DHCP..." -ForegroundColor Cyan

    Write-Host "[*] Instalando roles de servidor..." -ForegroundColor Yellow
    Install-WindowsFeature -Name AD-Domain-Services, DNS, DHCP, FS-Resource-Manager -IncludeManagementTools

    $DomainName = "gobernanza.local"
    $NetbiosName = "GOBERNANZA"
    
    Write-Host "[!] PROMOVIENDO SERVIDOR A DC. EL SISTEMA SE REINICIARA AL FINALIZAR." -ForegroundColor Red
    
    $SafeModePassword = ConvertTo-SecureString "ZeroTrust.2026*" -AsPlainText -Force
    
    Install-AddsForest -DomainName $DomainName -DomainNetbiosName $NetbiosName `
                       -SafeModeAdministratorPassword $SafeModePassword -Force:$true
}

Function Configurar-GpoLogoffForzado {
    Write-Host "`n[*] Configurando GPO de Desconexión Forzada (Logoff)..." -ForegroundColor Yellow
    $nombreGPO = "GPO_ZeroTrust_Logoff"
    
    if (-not (Get-GPO -Name $nombreGPO -ErrorAction SilentlyContinue)) {
        $gpo = New-GPO -Name $nombreGPO
        New-GPLink -Name $nombreGPO -Target (Get-ADDomain).DistinguishedName -LinkEnabled Yes | Out-Null
        
        # La directiva "Network security: Force logoff when logon hours expire" es una clave de registro
        Set-GPRegistryValue -Name $nombreGPO -Key "HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" -ValueName "enableforcedlogoff" -Type DWord -Value 1 | Out-Null
        
        Write-Host "  [+] GPO '$nombreGPO' creada y vinculada al dominio." -ForegroundColor Green
        Write-Host "  [!] Los usuarios serán expulsados automáticamente al terminar su turno." -ForegroundColor Green
    } else {
        Write-Host "  [-] La GPO de Logoff Forzado ya está activa." -ForegroundColor DarkGray
    }
}