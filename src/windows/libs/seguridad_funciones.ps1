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

function Preparar-InfraestructuraP09 {
    Log-Info "Fase 0: Preparando terreno (Directorios, Compartidos, OUs y Permisos)..."

    $rutaLocal = "C:\Admin_Sistemas\RoamingProfiles"
    if (-not (Test-Path $rutaLocal)) { 
        New-Item $rutaLocal -ItemType Directory -Force | Out-Null 
        Log-Ok "Directorio base creado: $rutaLocal"
    }

    # 1. Reparar Permisos de Red (SMB) - SOLUCIÓN AL PERFIL TEMPORAL
    Remove-SmbShare -Name "RoamingProfiles$" -Force -ErrorAction SilentlyContinue
    New-SmbShare -Name "RoamingProfiles$" -Path $rutaLocal -FullAccess "Todos" | Out-Null
    Log-Ok "Recurso compartido (RoamingProfiles$) liberado con FullAccess a Todos."

    # 2. Reparar Permisos Físicos (NTFS) - SOLUCIÓN AL PERFIL TEMPORAL
    Log-Info "Inyectando permisos NTFS Zero-Trust..."
    $acl = Get-Acl $rutaLocal
    $acl.SetAccessRuleProtection($true, $false) # Romper herencia

    # Limpiar reglas existentes para evitar conflictos
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) } | Out-Null

    $ruleAdmins  = New-Object System.Security.AccessControl.FileSystemAccessRule("Administradores", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
    $ruleSystem  = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
    $ruleCreator = New-Object System.Security.AccessControl.FileSystemAccessRule("CREATOR OWNER", "FullControl", "ContainerInherit, ObjectInherit", "InheritOnly", "Allow")
    
    # Regla clave: Usuarios solo pueden CREAR en la raíz, sin leer lo de otros
    $ruleUsers   = New-Object System.Security.AccessControl.FileSystemAccessRule("Usuarios del dominio", "CreateFiles, AppendData, ReadAndExecute", "None", "None", "Allow")

    $acl.AddAccessRule($ruleAdmins)
    $acl.AddAccessRule($ruleSystem)
    $acl.AddAccessRule($ruleCreator)
    $acl.AddAccessRule($ruleUsers)

    Set-Acl $rutaLocal $acl
    Log-Ok "Permisos NTFS aplicados correctamente."

    # 3. OUs y FGPP
    $dominio = (Get-ADDomain).DistinguishedName
    foreach ($ou in @("Cuates", "No Cuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou -Path $dominio | Out-Null
        }
    }

    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP_Usuarios_8'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy -Name "FGPP_Usuarios_8" -Precedence 20 -MinPasswordLength 8 -ComplexityEnabled $true
    }

    # 4. Auditoría y MFA
    auditpol /set /subcategory:"{0cce9215-69ae-11d9-bed3-505054503030}" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"{0cce9216-69ae-11d9-bed3-505054503030}" /success:enable /failure:enable | Out-Null
    
    $exeMFA = "C:\Program Files\multiOTP\multiotp.exe"
    if (Test-Path $exeMFA) {
        & $exeMFA -config max_fail_count=3 | Out-Null
        & $exeMFA -config lock_timeout=1800 | Out-Null
    }
}