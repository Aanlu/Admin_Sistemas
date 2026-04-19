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
function Sync-IdentidadesCSV {
    param([string]$RutaCSV)

    Write-Host "`n[*] Sincronizando Identidades y Horarios (Zero-Trust)..." -ForegroundColor Yellow

    # 1. AUTODESCUBRIMIENTO DEL JSON
    # La función busca el JSON asumiendo la estructura de carpetas de tu proyecto
    $rutaJSON = "C:\Users\Administrador\Admin_Sistemas\config\reglas_gobernanza.json"
    if (-not (Test-Path $rutaJSON)) {
        # Fallback por si la ruta cambió
        $rutaJSON = "$PSScriptRoot\..\config\reglas_gobernanza.json"
        if (-not (Test-Path $rutaJSON)) {
            Write-Host "  [!] ERROR CRITICO: No se encuentra el archivo JSON de reglas." -ForegroundColor Red
            return
        }
    }
    $reglasJSON = Get-Content $rutaJSON -Raw | ConvertFrom-Json

    $domainInfo = Get-ADDomain
    $domainName = $domainInfo.NetBIOSName
    $domainDN = $domainInfo.DistinguishedName
    $recursoCompartido = "\\$env:COMPUTERNAME\Perfiles_P8"

    # 2. CREACIÓN DE ESTRUCTURA (OUs y Grupos)
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

    # 3. PROCESAMIENTO DEL CSV
    if (-not (Test-Path $RutaCSV)) {
        Write-Host "  [!] ERROR: No se encontro el CSV en $RutaCSV" -ForegroundColor Red
        return
    }
    $usuariosData = Import-Csv -Path $RutaCSV -ErrorAction Stop

    foreach ($user in $usuariosData) {
        $username = $user.Usuario.Trim()
        $departamento = $user.Departamento.Trim()
        $targetOU = "OU=$departamento,$ouBase"
        $nombreGrupoSeguridad = "Grupo_$departamento"
        $homeDirectory = "$recursoCompartido\$username"
        
        $reglaAsignada = $reglasJSON.GruposDefinidos | Where-Object { $_.NombreDepartamento -eq $departamento }
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$username'" -ErrorAction SilentlyContinue
        $pass = ConvertTo-SecureString $user.Password -AsPlainText -Force

        # Lógica Idempotente (Crear o Actualizar)
        if (-not $adUser) {
            Write-Host "  [+] Creando nuevo usuario: $username" -ForegroundColor Green
            New-ADUser -SamAccountName $username -UserPrincipalName "$username@$($domainInfo.DNSRoot)" `
                       -Name "$($user.Nombre)" -GivenName $user.Nombre `
                       -AccountPassword $pass -Enabled $true -Path $targetOU
        } else {
            Write-Host "  [~] Actualizando usuario existente: $username" -ForegroundColor Cyan
            Set-ADAccountPassword -Identity $username -NewPassword $pass -Reset:$true
            
            $currentOU = ($adUser.DistinguishedName -split ',', 2)[1]
            if ($currentOU -ne $targetOU) {
                Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $targetOU | Out-Null
            }
        }

        # 4. APLICACIÓN DE HORARIOS Y PERFILES (Manejo del Administrador Supremo)
        if ($reglasJSON.AdministradoresSupremos -contains $username) {
            Write-Host "      [*] $username es ADMIN SUPREMO. Acceso 24/7 sin restricciones." -ForegroundColor Magenta
            try {
                Set-ADUser -Identity $username -Title $departamento -Department $departamento `
                           -HomeDrive "H:" -HomeDirectory $homeDirectory -Clear LogonHours -ErrorAction Stop
            } catch {}
        } else {
            if ($reglaAsignada) {
                # Forzamos que la variable reciba un arreglo de bytes puro
                [byte[]]$horasBytes = Convertir-HorarioABytesUTC -horaInicioLocal $reglaAsignada.HorarioPermitido.HoraInicio -horaFinLocal $reglaAsignada.HorarioPermitido.HoraFin
                
                # Actualizamos perfil base
                Set-ADUser -Identity $username -Title $departamento -Department $departamento -HomeDrive "H:" -HomeDirectory $homeDirectory -ErrorAction SilentlyContinue
                
                # Limpiamos e inyectamos la matriz de bytes pura (SIN silenciador)
                Set-ADUser -Identity $username -Clear logonhours -ErrorAction SilentlyContinue
                Set-ADUser -Identity $username -Replace @{logonhours = $horasBytes} -ErrorAction Stop
                
                Write-Host "      -> Horario UTC inyectado correctamente." -ForegroundColor DarkGray
            }
        }

        # 5. ASIGNACIÓN ESTRICTA DE GRUPOS (Para AppLocker y FSRM)
        foreach ($grp in $reglasJSON.GruposDefinidos.NombreDepartamento) {
            Remove-ADGroupMember -Identity "Grupo_$grp" -Members $username -Confirm:$false -ErrorAction SilentlyContinue
        }
        Add-ADGroupMember -Identity $nombreGrupoSeguridad -Members $username -ErrorAction SilentlyContinue
    }
    
    Write-Host "[OK] Motor de Sincronizacion CSV ejecutado con exito." -ForegroundColor Green
}