# ==============================================================================
# LIBRERIA: seguridad_funciones.ps1
# PROPOSITO: RBAC, FGPP, ACLs y Utilidades de Identidad
# ==============================================================================

function Crear-UsuariosRBAC {
    Log-Info "Verificando/Creando usuarios delegados..."
    $passDefault = ConvertTo-SecureString "ZeroTrust.2026*" -AsPlainText -Force
    
    $usuarios = @(
        @{Nombre="admin_identidad"; Desc="IAM Operator"},
        @{Nombre="admin_storage"; Desc="Storage Operator"},
        @{Nombre="admin_politicas"; Desc="GPO Compliance"},
        @{Nombre="admin_auditoria"; Desc="Security Auditor"}
    )

    foreach ($usr in $usuarios) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($usr.Nombre)'" -ErrorAction SilentlyContinue)) {
            New-ADUser -Name $usr.Nombre -SamAccountName $usr.Nombre -AccountPassword $passDefault -Enabled $true -Description $usr.Desc
            Log-Ok "Usuario creado: $($usr.Nombre)"
        } else {
            Log-Warning "Usuario $($usr.Nombre) ya existe."
        }
    }
}

# Reemplazar la función de Delegación en seguridad_funciones.ps1
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

    # Inyección directa a nivel de dominio vía LDAP (Infalible)
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

function Configurar-FGPP-Roles {
    Log-Info "Alineando Directivas de Contrasena (FGPP)..."
    
    # FIX: Se inyecta el LockoutThreshold directamente en la FGPP para que no herede 0 del sistema
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'PolAdmin_12'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy -Name "PolAdmin_12" -Precedence 10 -MinPasswordLength 12 -ComplexityEnabled $true -ReversibleEncryptionEnabled $false -LockoutThreshold 3 -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00"
        Log-Ok "Politica FGPP (12 chars + Lockout) creada."
    } else {
        # Actualizar por si existia sin el parche de bloqueo
        Set-ADFineGrainedPasswordPolicy -Identity "PolAdmin_12" -LockoutThreshold 3 -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00"
        Log-Ok "Politica FGPP actualizada con reglas de bloqueo."
    }

    $admins = @("admin_identidad", "admin_storage", "admin_politicas")
    foreach ($admin in $admins) {
        try { Add-ADFineGrainedPasswordPolicySubject "PolAdmin_12" -Subjects $admin -ErrorAction Stop } catch {}
    }
    Log-Ok "Politicas enlazadas a los roles correspondientes."
}

function Desbloquear-UsuariosAD {
    $bloqueados = Get-ADUser -Filter 'LockedOut -eq $true' -Properties LockedOut
    
    if (-not $bloqueados) {
        Log-Info "No hay usuarios bloqueados en el dominio en este momento."
        return
    }

    $opciones = @($bloqueados | Select-Object -ExpandProperty SamAccountName)
    $sel = Generar-Menu -Titulo "DESBLOQUEAR USUARIOS" -Opciones $opciones -TextoSalir "Cancelar y Volver"
    
    if ($sel -lt $opciones.Count) {
        $usrTarget = $opciones[$sel]
        Unlock-ADAccount -Identity $usrTarget
        Log-Ok "El usuario '$usrTarget' ha sido desbloqueado exitosamente."
    }
}

# ARCHIVO: src/windows/libs/seguridad_funciones.ps1
function Preparar-InfraestructuraP09 {
    Log-Info "Fase 0: Preparando terreno (C++, Bloqueos y Gateway)..."

    # 1. Reanimación de multiOTP: Descarga e instala Visual C++
    $vc64 = "$env:TEMP\vc_redist.x64.exe"
    if (-not (Test-Path $vc64)) {
        Log-Info "Descargando dependencias C++ para el motor MFA..."
        Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vc64
        Start-Process -FilePath $vc64 -ArgumentList "/install /quiet /norestart" -Wait
    }

    # 2. Configuración de Política de Bloqueo Zero-Trust (3x30)
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP_Lockout_30'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy -Name "FGPP_Lockout_30" -Precedence 10 `
            -LockoutThreshold 3 -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00"
        Log-Ok "Política de bloqueo 3 intentos / 30 min configurada."
    }

    # 3. Despliegue del Gateway a Producción
    $DestGW = "C:\Admin_Sistemas\Gateway-ZeroTrust.ps1"
    if (-not (Test-Path "C:\Admin_Sistemas")) { New-Item "C:\Admin_Sistemas" -ItemType Directory }
    Copy-Item -Path "$PSScriptRoot\..\Gateway-ZeroTrust.ps1" -Destination $DestGW -Force
    Log-Ok "Gateway Zero-Trust actualizado en C:\Admin_Sistemas."

    # 4. Configuración de Auditoría de Logon
    auditpol /set /subcategory:"Logon" /success:enable /failure:enable | Out-Null
    
    $exeMFA = "C:\Program Files\multiOTP\multiotp.exe"
    if (Test-Path $exeMFA) {
        & $exeMFA -config max_fail_count=3 | Out-Null
        & $exeMFA -config lock_timeout=1800 | Out-Null
    }
}