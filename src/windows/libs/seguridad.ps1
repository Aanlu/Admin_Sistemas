# ==============================================================================
# LIBRERIA: seguridad.ps1
# PROPOSITO: RBAC, FGPP, ACLs, CRUD de Identidades y Gestión MFA
# ==============================================================================

function Preparar-InfraestructuraP09 {
    Log-Info "Fase 0: Preparando terreno (Directorios, Compartidos, OUs, SSH y Auditoria)..."

    $rutaLocal = "C:\Admin_Sistemas\RoamingProfiles"
    if (-not (Test-Path $rutaLocal)) { New-Item $rutaLocal -ItemType Directory -Force | Out-Null }
    
    try {
        $acl = Get-Acl $rutaLocal
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("CREATOR OWNER", "FullControl", "ContainerInherit, ObjectInherit", "InheritOnly", "Allow")
        $acl.AddAccessRule($rule)
        Set-Acl $rutaLocal $acl
    } catch {}

    if (-not (Get-SmbShare -Name "RoamingProfiles$" -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name "RoamingProfiles$" -Path $rutaLocal -FullAccess "Administradores" -ReadAccess "Todos" | Out-Null
    }

    $dominio = (Get-ADDomain).DistinguishedName
    foreach ($ou in @("Cuates", "No Cuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou -Path $dominio | Out-Null
        }
    }

    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP_Usuarios_8'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy -Name "FGPP_Usuarios_8" -Precedence 20 -MinPasswordLength 8 -ComplexityEnabled $true
    }

    auditpol /set /subcategory:"{0CCE9215-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable | Out-Null

    $rutaGateway = "C:\Users\Administrador\Admin_Sistemas\src\windows\Gateway-ZeroTrust.ps1"
    if (Test-Path "C:\Users\Administrador\Admin_Sistemas\src\windows\Gateway-ZeroTrust.ps1") {
        Copy-Item "C:\Users\Administrador\Admin_Sistemas\src\windows\Gateway-ZeroTrust.ps1" -Destination $rutaGateway -Force
    }

    $multiDir = "C:\Program Files\multiOTP"
    if (Test-Path $multiDir) {
        $aclM = Get-Acl $multiDir
        $ruleM = New-Object System.Security.AccessControl.FileSystemAccessRule("Usuarios", "Modify", "ContainerInherit, ObjectInherit", "None", "Allow")
        $aclM.AddAccessRule($ruleM)
        Set-Acl $multiDir $aclM
    }

    $sshdConfig = "C:\ProgramData\ssh\sshd_config"
    if (Test-Path $sshdConfig) {
        $conf = Get-Content $sshdConfig
        $newConf = @()
        $inyectado = $false
        foreach ($line in $conf) {
            if ($line -match "(?i)^Match " -and -not $inyectado) {
                $newConf += "ForceCommand powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$rutaGateway`""
                $inyectado = $true
            }
            if ($line -notmatch "ForceCommand powershell") { $newConf += $line }
        }
        if (-not $inyectado) { $newConf += "ForceCommand powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$rutaGateway`"" }
        $newConf | Set-Content $sshdConfig -Force
        Restart-Service sshd -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# FIX: Convierte Base32 → bytes reales → hex (TOTP correcto)
# Antes: convertía cada char a su valor ASCII en hex (A→41, B→42...) — INCORRECTO
# Ahora: decodifica Base32 real (A=0..Z=25, 2=26..7=31) — CORRECTO
# ==============================================================================
function Base32-AHex {
    param([string]$Base32)
    $alfabeto = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $bits = ""
    foreach ($c in $Base32.ToUpper().ToCharArray()) {
        $val = $alfabeto.IndexOf($c)
        if ($val -ge 0) {
            $bits += [Convert]::ToString($val, 2).PadLeft(5, '0')
        }
    }
    # Recortar a múltiplo de 8 bits
    $bits = $bits.Substring(0, [math]::Floor($bits.Length / 8) * 8)
    $hex = ""
    for ($i = 0; $i -lt $bits.Length; $i += 8) {
        $hex += [Convert]::ToInt32($bits.Substring($i, 8), 2).ToString("x2")
    }
    return $hex
}

function Configurar-UsuarioMFA {
    param([string]$Usuario, [string]$Semilla)
    $motpDir = "C:\Program Files\multiOTP"
    if (-not (Test-Path "$motpDir\multiotp.exe")) { return "ERROR" }

    # FIX: decodificación Base32 correcta
    $hex = Base32-AHex -Base32 $Semilla

    Push-Location $motpDir
    .\multiotp.exe -delete $Usuario 2>&1 | Out-Null
    .\multiotp.exe -fastcreate $Usuario 2>&1 | Out-Null
    # FIX: agregar request_prefix_pin=0 — sin esto multiOTP espera PIN+token
    #      y con PIN vacío el hash nunca coincide con los 6 dígitos del Authenticator
    .\multiotp.exe -set $Usuario token_seed=$hex algorithm=TOTP time_interval=30 number_of_digits=6 request_prefix_pin=0 2>&1 | Out-Null
    Pop-Location

    # Guardar semilla Base32 en archivo local para poder mostrarla después
    $semillasDir = "C:\Admin_Sistemas\mfa_seeds"
    if (-not (Test-Path $semillasDir)) { New-Item $semillasDir -ItemType Directory -Force | Out-Null }
    $Semilla | Out-File "$semillasDir\$Usuario.b32" -Encoding ASCII -Force

    return $Semilla
}

function Mostrar-TokenUsuario {
    param([string]$Usuario)
    $motpDir = "C:\Program Files\multiOTP"
    if (-not (Test-Path "$motpDir\multiotp.exe")) { Log-Error "multiOTP no instalado."; return }

    # FIX: leer semilla del archivo guardado (la semilla en el .db está cifrada)
    $semillasDir = "C:\Admin_Sistemas\mfa_seeds"
    $archivoSemilla = "$semillasDir\$Usuario.b32"

    if (Test-Path $archivoSemilla) {
        $semilla = (Get-Content $archivoSemilla -Raw).Trim()
        Write-Host "`n=========================================" -ForegroundColor Cyan
        Write-Host " IDENTIDAD MFA: $Usuario" -ForegroundColor Green
        Write-Host "=========================================" -ForegroundColor Cyan
        Write-Host " Llave para App : " -NoNewline; Write-Host $semilla -ForegroundColor Yellow
        Write-Host " Algoritmo      : TOTP / HMAC-SHA1 / 30s" -ForegroundColor Gray
        Write-Host " Digitos        : 6" -ForegroundColor Gray
        Write-Host "=========================================`n" -ForegroundColor Cyan
        Write-Host " Escanea el QR o introduce la clave manual en Google Authenticator." -ForegroundColor White
    } else {
        Log-Error "No hay semilla guardada para '$Usuario'. Ejecuta Instalacion Completa para regenerar."
    }
}

function Seleccionar-UsuarioAD {
    param([string]$Titulo)
    $lista = @(Get-ADUser -Filter * -SearchBase ((Get-ADDomain).DistinguishedName) | Where-Object { $_.SamAccountName -notmatch "Guest|krbtgt|DefaultAccount" } | Select-Object -ExpandProperty SamAccountName)
    if (-not $lista) { return $null }
    
    $sel = Generar-Menu -Titulo $Titulo -Opciones $lista -TextoSalir "Cancelar y Volver"
    if ($sel -lt $lista.Count) { return $lista[$sel] }
    return $null
}

function Crear-UsuariosRBAC {
    Log-Info "Fase 1: Verificando/Creando identidades, MFA y Perfiles Moviles..."
    
    while ($true) {
        $passAdmins = Read-Host ">>> Defina contrasena maestra ADMINISTRADOR (min 12 chars)"
        if ($passAdmins.Length -ge 12) { break }
        Log-Error "Debe tener al menos 12 caracteres."
    }

    while ($true) {
        $passUsers  = Read-Host ">>> Defina contrasena maestra USUARIOS (min 8 chars)"
        if ($passUsers.Length -ge 8) { break }
        Log-Error "Debe tener al menos 8 caracteres."
    }
    
    $dominio = (Get-ADDomain).DistinguishedName
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $sCuates   = -join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum 32)] })
    $sNoCuates = -join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum 32)] })

    $usuarios = @(
        @{Nombre="admin_identidad"; Tipo="Admin"; Pass=$passAdmins; Path=""; S=(-join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum 32)] }))},
        @{Nombre="admin_storage";   Tipo="Admin"; Pass=$passAdmins; Path=""; S=(-join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum 32)] }))},
        @{Nombre="admin_politicas"; Tipo="Admin"; Pass=$passAdmins; Path=""; S=(-join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum 32)] }))},
        @{Nombre="admin_auditoria"; Tipo="Admin"; Pass=$passAdmins; Path=""; S=(-join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum 32)] }))},
        @{Nombre="usuario_cuate";   Tipo="Cuate";   Pass=$passUsers; Path="OU=Cuates,$dominio";    S=$sCuates},
        @{Nombre="usuario_nocuate"; Tipo="NoCuate"; Pass=$passUsers; Path="OU=No Cuates,$dominio"; S=$sNoCuates}
    )

    foreach ($u in $usuarios) {
        $perfil = "\\$env:COMPUTERNAME\RoamingProfiles$\$($u.Nombre)"
        $p = ConvertTo-SecureString $u.Pass -AsPlainText -Force
        
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Nombre)'" -ErrorAction SilentlyContinue)) {
            if ($u.Path) { New-ADUser -Name $u.Nombre -SamAccountName $u.Nombre -AccountPassword $p -Enabled $true -Path $u.Path -ProfilePath $perfil }
            else          { New-ADUser -Name $u.Nombre -SamAccountName $u.Nombre -AccountPassword $p -Enabled $true -ProfilePath $perfil }
        } else {
            Set-ADAccountPassword -Identity $u.Nombre -NewPassword $p -Reset -ErrorAction SilentlyContinue
            Set-ADUser -Identity $u.Nombre -ProfilePath $perfil -ErrorAction SilentlyContinue
            Unlock-ADAccount -Identity $u.Nombre -ErrorAction SilentlyContinue
        }
        $key = Configurar-UsuarioMFA -Usuario $u.Nombre -Semilla $u.S
        Log-Ok "[$($u.Tipo)] $($u.Nombre) -> MFA Key: $key"
    }

    try {
        $grupoLectores = Get-ADGroup -Identity "S-1-5-32-573" -ErrorAction SilentlyContinue
        if ($grupoLectores) { Add-ADGroupMember -Identity $grupoLectores -Members "admin_auditoria" -ErrorAction SilentlyContinue }
    } catch {}
}

function Configurar-FGPP-Roles {
    Log-Info "Fase 2: Alineando Directivas de Contrasena (FGPP)..."
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'PolAdmin_12'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy -Name "PolAdmin_12" -Precedence 10 -MinPasswordLength 12 -ComplexityEnabled $true -ReversibleEncryptionEnabled $false -LockoutThreshold 3 -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00"
    } else {
        Set-ADFineGrainedPasswordPolicy -Identity "PolAdmin_12" -LockoutThreshold 3 -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00"
    }

    foreach ($admin in @("admin_identidad", "admin_storage", "admin_politicas")) {
        try { Add-ADFineGrainedPasswordPolicySubject "PolAdmin_12" -Subjects $admin -ErrorAction Stop } catch {}
    }
}

function Aplicar-DelegacionControl {
    Log-Info "Fase 3: Inyectando ACLs restrictivos en Active Directory..."
    $dominio = (Get-ADDomain).DistinguishedName
    try {
        $sidStorage  = (Get-ADUser -Identity "admin_storage").SID
        $sidIdentidad = (Get-ADUser -Identity "admin_identidad").SID
    } catch { return }

    $guidResetPassword = New-Object Guid("00299570-246d-11d0-a768-00aa006e0529")
    $guidUserClass     = New-Object Guid("bf967aba-0de6-11d0-a285-00aa003049e2")

    $reglaDeny  = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sidStorage,   [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight, [System.Security.AccessControl.AccessControlType]::Deny,  $guidResetPassword, [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents, $guidUserClass)
    $reglaAllow = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sidIdentidad, [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,     [System.Security.AccessControl.AccessControlType]::Allow, [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents, $guidUserClass)

    foreach ($ou in @("OU=Cuates,$dominio", "OU=No Cuates,$dominio")) {
        if (Get-ADOrganizationalUnit -Identity $ou -ErrorAction SilentlyContinue) {
            $acl = Get-Acl "AD:\$ou"
            $acl.AddAccessRule($reglaDeny)
            $acl.AddAccessRule($reglaAllow)
            Set-Acl "AD:\$ou" -AclObject $acl
        }
    }
}

function Desbloquear-UsuariosAD {
    $bloqueados = @(Search-ADAccount -LockedOut | Select-Object -ExpandProperty SamAccountName)
    if (-not $bloqueados) { Log-Ok "No hay ningun usuario bloqueado."; return }

    $sel = Generar-Menu -Titulo "USUARIOS BLOQUEADOS (LOCKOUT)" -Opciones $bloqueados -TextoSalir "Cancelar"
    if ($sel -lt $bloqueados.Count) {
        $usrTarget = $bloqueados[$sel]
        Unlock-ADAccount -Identity $usrTarget
        Log-Ok "El usuario '$usrTarget' ha sido desbloqueado exitosamente."
    }
}