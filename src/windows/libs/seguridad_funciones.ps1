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

function Aplicar-DelegacionControl {
    Log-Info "Inyectando ACL restrictivo para admin_storage..."
    
    $dominio = (Get-ADDomain).DistinguishedName
    $ouCuates = "OU=Cuates,$dominio"
    $ouNoCuates = "OU=No Cuates,$dominio"
    
    try {
        $sidStorage = (Get-ADUser -Identity "admin_storage").SID
        $sidIdentidad = (Get-ADUser -Identity "admin_identidad").SID
    } catch {
        Log-Error "Faltan usuarios administradores. Ejecuta el paso de creacion primero."
        return
    }

    $guidResetPassword = New-Object Guid("00299570-246d-11d0-a768-00aa006e0529")
    $guidUserClass = New-Object Guid("bf967aba-0de6-11d0-a285-00aa003049e2")

    # Regla: Denegar a admin_storage
    $reglaDeny = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sidStorage, [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight, [System.Security.AccessControl.AccessControlType]::Deny, $guidResetPassword, [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents, $guidUserClass)
    
    # Regla: Permitir a admin_identidad
    $reglaAllow = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sidIdentidad, [System.DirectoryServices.ActiveDirectoryRights]::GenericAll, [System.Security.AccessControl.AccessControlType]::Allow, [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents, $guidUserClass)

    foreach ($targetOU in @($ouCuates, $ouNoCuates)) {
        if (Get-ADOrganizationalUnit -Identity $targetOU -ErrorAction SilentlyContinue) {
            $acl = Get-Acl "AD:\$targetOU"
            $acl.AddAccessRule($reglaDeny)
            $acl.AddAccessRule($reglaAllow)
            Set-Acl "AD:\$targetOU" -AclObject $acl
            Log-Ok "ACLs aplicadas en $targetOU"
        }
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
    Log-Info "Fase 0: Preparando terreno (Directorios, Compartidos y OUs)..."

    # 1. Preparar recurso compartido para Perfiles Móviles
    $rutaLocal = "C:\Admin_Sistemas\RoamingProfiles"
    if (-not (Test-Path $rutaLocal)) { 
        New-Item $rutaLocal -ItemType Directory -Force | Out-Null 
        Log-Ok "Directorio base creado: $rutaLocal"
    }

    if (-not (Get-SmbShare -Name "RoamingProfiles$" -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name "RoamingProfiles$" -Path $rutaLocal -FullAccess "Todos" | Out-Null
        Log-Ok "Recurso compartido oculto (RoamingProfiles$) levantado en la red."
    } else {
        Log-Warning "El recurso RoamingProfiles$ ya estaba activo."
    }

    # 2. Verificación de Unidades Organizativas (OUs) base
    $dominio = (Get-ADDomain).DistinguishedName
    $ous = @("Cuates", "No Cuates")
    foreach ($ou in $ous) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou -Path $dominio | Out-Null
            Log-Ok "Unidad Organizativa creada: $ou"
        } else {
            Log-Warning "La OU '$ou' ya existe. Omitiendo."
        }
    }

    # 3. FGPP para Usuarios Normales (8 caracteres, tu código original)
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP_Usuarios_8'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy -Name "FGPP_Usuarios_8" -Precedence 20 -MinPasswordLength 8 -ComplexityEnabled $true
        Log-Ok "Politica base para usuarios (8 caracteres) lista."
    }
}