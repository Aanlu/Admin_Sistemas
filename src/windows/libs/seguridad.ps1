# ==============================================================================
# LIBRERIA: seguridad.ps1
# PROPOSITO: RBAC, FGPP, ACLs, CRUD de Identidades y Gestión MFA
# ==============================================================================

function Preparar-InfraestructuraP09 {
    Log-Info "Fase 0: Preparando terreno..."

    $rutaLocal = "C:\Admin_Sistemas\RoamingProfiles"
    if (-not (Test-Path $rutaLocal)) { New-Item $rutaLocal -ItemType Directory -Force | Out-Null }

    if (-not (Get-SmbShare -Name "RoamingProfiles$" -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name "RoamingProfiles$" -Path $rutaLocal -FullAccess "Everyone" | Out-Null
        Log-Ok "Share RoamingProfiles creado (Full para Everyone, NTFS restringe)."
    }

    $acl = Get-Acl $rutaLocal
    $acl.SetAccessRuleProtection($true, $false)

    $sidSystem    = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $sidAdmins    = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $sidCreator   = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::CreatorOwnerSid, $null)
    $sidAuthUsers = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid, $null)

    $rFull    = [System.Security.AccessControl.FileSystemRights]::FullControl
    $rProfile = [System.Security.AccessControl.FileSystemRights]"ReadAndExecute, AppendData, ReadPermissions"
    $iAll     = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    $iNone    = [System.Security.AccessControl.InheritanceFlags]::None
    $pNone    = [System.Security.AccessControl.PropagationFlags]::None
    $pInhOnly = [System.Security.AccessControl.PropagationFlags]::InheritOnly
    $aAllow   = [System.Security.AccessControl.AccessControlType]::Allow

    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidSystem,    $rFull,    $iAll,  $pNone,    $aAllow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidAdmins,   $rFull,    $iAll,  $pNone,    $aAllow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidCreator,  $rFull,    $iAll,  $pInhOnly, $aAllow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidAuthUsers,$rProfile, $iNone, $pNone,    $aAllow)))
    Set-Acl $rutaLocal $acl
    Log-Ok "Permisos NTFS SID-safe aplicados."

    $dominio = (Get-ADDomain).DistinguishedName
    foreach ($ou in @("Cuates", "No Cuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou -Path $dominio -ProtectedFromAccidentalDeletion $false | Out-Null
        }
    }

    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP_Usuarios_8'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy -Name "FGPP_Usuarios_8" -Precedence 20 -MinPasswordLength 8 -ComplexityEnabled $true
    }

    auditpol /set /subcategory:"{0cce9215-69ae-11d9-bed3-505054503030}" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"{0cce9216-69ae-11d9-bed3-505054503030}" /success:enable /failure:enable | Out-Null
    Log-Ok "Auditoria Logon/Logoff activada."

    $multiDir = "C:\Program Files\multiOTP"
    if (-not (Test-Path "$multiDir\multiotp.exe")) {
        Log-Warning "multiOTP no detectado. Descargando..."
        try {
            if (-not (Test-Path $multiDir)) { New-Item -ItemType Directory -Path $multiDir -Force | Out-Null }
            $zipPath = "$env:TEMP\multiotp.zip"
            $tempExt = "$env:TEMP\multiotp_ext"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri "https://download.multiotp.net/multiotp.zip" -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            if (Test-Path $tempExt) { Remove-Item $tempExt -Recurse -Force | Out-Null }
            Expand-Archive -Path $zipPath -DestinationPath $tempExt -Force
            $exe = Get-ChildItem -Path $tempExt -Filter "multiotp.exe" -Recurse | Select-Object -First 1
            if ($exe) { Copy-Item -Path "$($exe.DirectoryName)\*" -Destination $multiDir -Recurse -Force; Log-Ok "multiOTP instalado." }
            else { Log-Error "multiotp.exe no encontrado en el ZIP." }
        } catch { Log-Error "Fallo la descarga de multiOTP: $($_.Exception.Message)" }
    }

    if (Test-Path "$multiDir\multiotp.exe") {
        $sidUsers = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinUsersSid, $null)
        $aclM = Get-Acl $multiDir
        $aclM.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidUsers, "Modify", "ContainerInherit, ObjectInherit", "None", "Allow")))
        Set-Acl $multiDir $aclM

        & "$multiDir\multiotp.exe" -config max_fail_count=3 | Out-Null
        & "$multiDir\multiotp.exe" -config lock_timeout=1800 | Out-Null
        Log-Ok "multiOTP: 3 intentos max, bloqueo 30 min."
    }

    $origenGateway = "C:\Users\Administrador\Admin_Sistemas\src\windows\Gateway-ZeroTrust.ps1"
    $rutaGateway   = "C:\Admin_Sistemas\Gateway-ZeroTrust.ps1"
    if (Test-Path $origenGateway) { Copy-Item $origenGateway -Destination $rutaGateway -Force }

    $sshdConfig = "C:\ProgramData\ssh\sshd_config"
    if (Test-Path $sshdConfig) {
        $confLimpia = Get-Content $sshdConfig | Where-Object {
            $_ -notmatch "ForceCommand" -and $_ -notmatch "Match User" -and $_ -notmatch "Gateway-ZeroTrust"
        }
        $confLimpia = $confLimpia -replace "^#?PasswordAuthentication (no|yes)", "PasswordAuthentication yes"
        $bloqueZeroTrust = @(
            "",
            "Match User Administrador,Administrator",
            "    ForceCommand none",
            "",
            "Match User *,!Administrador,!Administrator",
            "    ForceCommand powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$rutaGateway`"",
            ""
        )
        Set-Content -Path $sshdConfig -Value ($confLimpia + $bloqueZeroTrust) -Force
        Restart-Service sshd -Force -ErrorAction SilentlyContinue
        Log-Ok "Directivas SSH inyectadas."
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

    $semillasDir = "C:\Admin_Sistemas\mfa_seeds"
    if (-not (Test-Path $semillasDir)) { New-Item $semillasDir -ItemType Directory -Force | Out-Null }

    $dbPath = "$motpDir\users\$($Usuario.ToLower()).db"
    if (Test-Path $dbPath) { Remove-Item $dbPath -Force }

    Push-Location $motpDir
    .\multiotp.exe -createga $Usuario.ToLower() $Semilla 2>&1 | Out-Null
    .\multiotp.exe -set $Usuario.ToLower() prefix-pin=0 2>&1 | Out-Null
    Pop-Location

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
    $netbios  = (Get-ADDomain).Name

    try {
        $sidStorage   = (Get-ADUser -Identity "admin_storage").SID
        $sidIdentidad = (Get-ADUser -Identity "admin_identidad").SID
    } catch { Log-Error "Faltan usuarios administradores."; return }

    $guidResetPassword = New-Object Guid("00299570-246d-11d0-a768-00aa006e0529")
    $guidUserClass     = New-Object Guid("bf967aba-0de6-11d0-a285-00aa003049e2")

    $reglaDeny  = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sidStorage,   [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight, [System.Security.AccessControl.AccessControlType]::Deny,  $guidResetPassword, [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents, $guidUserClass)
    $reglaAllow = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sidIdentidad, [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,     [System.Security.AccessControl.AccessControlType]::Allow, [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents, $guidUserClass)

    dsacls $dominio /I:S /D "$netbios\admin_storage:CA;Reset Password;user" 2>$null | Out-Null
    Log-Ok "DENY Reset Password aplicado a nivel de dominio para admin_storage."

    foreach ($ouName in @("Cuates", "No Cuates")) {
        $ouObj = Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" -SearchBase $dominio -SearchScope Subtree -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ouObj) { Log-Warning "OU '$ouName' no encontrada."; continue }

        $ouDN = $ouObj.DistinguishedName
        $acl  = Get-Acl "AD:\$ouDN"
        $acl.AddAccessRule($reglaDeny)
        $acl.AddAccessRule($reglaAllow)
        Set-Acl "AD:\$ouDN" -AclObject $acl
        Log-Ok "ACLs aplicadas en $ouDN"

        dsacls $ouDN /I:T /G "$netbios\admin_identidad:CCDC;user"          2>$null | Out-Null
        dsacls $ouDN /I:S /G "$netbios\admin_identidad:CA;Reset Password;user"  2>$null | Out-Null
        dsacls $ouDN /I:S /G "$netbios\admin_identidad:CA;Change Password;user" 2>$null | Out-Null
        Log-Ok "Delegacion admin_identidad aplicada en OU=$ouName."
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
function Sync-MFA-DesdeCSV {
    $RutaCSV = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\config\usuarios.csv")
    Log-Info "Sincronizando tokens MFA masivos desde CSV..."
    if (-not (Test-Path $RutaCSV)) { Log-Error "No se encontro el CSV en $RutaCSV"; return }

    $usuarios = Import-Csv -Path $RutaCSV -ErrorAction SilentlyContinue
    if (-not $usuarios) { Log-Error "El CSV esta vacio o corrupto."; return }

    $sCuates   = "CUATESAAAAAA2226"
    $sNoCuates = "NOCUATESAAAA2226"
    $motpDir   = "C:\Program Files\multiOTP"
    $semillasDir = "C:\Admin_Sistemas\mfa_seeds"
    if (-not (Test-Path $semillasDir)) { New-Item $semillasDir -ItemType Directory -Force | Out-Null }

    Push-Location $motpDir
    foreach ($u in $usuarios) {
        $username = $u.Usuario.Trim().ToLower()
        $depto    = $u.Departamento.Trim()
        $semilla  = if ($depto -match "No") { $sNoCuates } else { $sCuates }

        $dbPath = "$motpDir\users\$username.db"
        if (Test-Path $dbPath) { Remove-Item $dbPath -Force }

        .\multiotp.exe -createga $username $semilla 2>&1 | Out-Null
        .\multiotp.exe -set $username prefix-pin=0 2>&1 | Out-Null

        $semilla | Out-File "$semillasDir\$username.b32" -Encoding ASCII -Force
        Log-Ok "MFA vinculado: $username ($depto)"
    }
    Pop-Location
}