Import-Module WebAdministration -ErrorAction SilentlyContinue

# Asegúrate de que tus módulos utils y validaciones existan y funcionen
. .\libs\utils.ps1
. .\libs\validaciones.ps1

$global:DIR_FTP_ROOT = "C:\FTP_Root"
$global:DIR_FTP_MASTER = "C:\FTP_Master"
$global:SITE_NAME = "Servidor_FTP_Secure"

function Gestionar-InstalacionFTP {
    Clear-Host
    
    if (-not (Test-Path $global:DIR_FTP_MASTER)) { 
        New-Item -Path $global:DIR_FTP_MASTER -ItemType Directory -Force | Out-Null 
    }
    $global:LOG_FILE = "$global:DIR_FTP_MASTER\ftp_diagnostico.log"
    Start-Transcript -Path $global:LOG_FILE -Append -Force
    
    Write-Host "--- 1. PREPARACION BASE DEL SERVIDOR FTP IIS (CHROOT ESTRICTO TIPO LINUX) ---" -ForegroundColor Yellow
    
    Instalar-DependenciaSilenciosa "Web-Ftp-Server" | Out-Null
    Instalar-DependenciaSilenciosa "Web-Ftp-Ext" | Out-Null
    Instalar-DependenciaSilenciosa "Web-Mgmt-Console" | Out-Null
    Instalar-DependenciaSilenciosa "Web-Scripting-Tools" | Out-Null

    Start-Service ftpsvc -ErrorAction SilentlyContinue
    Set-Service ftpsvc -StartupType Automatic -ErrorAction SilentlyContinue

    Remove-NetFirewallRule -DisplayName "FTP-Control-Port21" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "FTP-Control-Port21" -Direction Inbound -LocalPort 21 -Protocol TCP -Action Allow | Out-Null
    
    Remove-NetFirewallRule -DisplayName "FTP-Pasivo-IIS" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "FTP-Pasivo-IIS" -Direction Inbound -LocalPort 40000-40100 -Protocol TCP -Action Allow | Out-Null

    secedit /export /cfg "$env:temp\secpol.cfg" | Out-Null
    (Get-Content "$env:temp\secpol.cfg") -replace 'PasswordComplexity = 1', 'PasswordComplexity = 0' | Set-Content "$env:temp\secpol.cfg"
    secedit /configure /db "$env:windir\security\local.sdb" /cfg "$env:temp\secpol.cfg" /areas SECURITYPOLICY | Out-Null

    Write-Host "[*] Configurando bóvedas físicas, túneles anónimos y reglas NTFS..." -ForegroundColor Cyan
    
    if (-not (Test-Path "$DIR_FTP_ROOT\LocalUser")) {
        New-Item -Path "$DIR_FTP_ROOT\LocalUser" -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path "$DIR_FTP_MASTER\general")) {
        New-Item -Path "$DIR_FTP_MASTER\general" -ItemType Directory -Force | Out-Null
    }

    if (Test-Path "$DIR_FTP_ROOT\LocalUser\Public") {
        Remove-Item -Path "$DIR_FTP_ROOT\LocalUser\Public" -Force -Recurse -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Junction -Path "$DIR_FTP_ROOT\LocalUser\Public" -Target "$DIR_FTP_MASTER\general" | Out-Null

    $SidSys = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18') 
    $SidAdm = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544') 
    $SidUsr = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545') 
    $IusrAccount = New-Object System.Security.Principal.NTAccount("IUSR")
    $IisIusrsAccount = New-Object System.Security.Principal.NTAccount("IIS_IUSRS")

    $AclRoot = Get-Acl $DIR_FTP_ROOT
    # FORZADO DE JAULA: Retiramos el permiso ReadAndExecute a 'Users'. Si la jaula falla, NTFS bloqueará la vista.
    $AclRoot.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($IisIusrsAccount, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")))
    Set-Acl -Path $DIR_FTP_ROOT -AclObject $AclRoot

    $AclGeneral = Get-Acl "$DIR_FTP_MASTER\general"
    $AclGeneral.SetAccessRuleProtection($true, $false)
    $AclGeneral.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($SidSys, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
    $AclGeneral.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($SidAdm, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
    $AclGeneral.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($SidUsr, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")))
    $AclGeneral.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($IusrAccount, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")))
    Set-Acl -Path "$DIR_FTP_MASTER\general" -AclObject $AclGeneral

    Write-Host "[*] Desplegando Sitio FTP..." -ForegroundColor Cyan
    $appcmd = "$env:systemroot\system32\inetsrv\appcmd.exe"
    
    Get-Website | Where-Object { $_.Bindings.Collection.BindingInformation -match ":21:" -and $_.Name -ne $SITE_NAME } | Stop-Website -ErrorAction SilentlyContinue
    cmd.exe /c "$appcmd delete site $SITE_NAME >nul 2>&1"
    
    & $appcmd add site /name:$SITE_NAME /bindings:ftp://*:21 /physicalPath:$DIR_FTP_ROOT
    
    & $appcmd set site $SITE_NAME "/ftpServer.security.ssl.controlChannelPolicy:SslAllow" "/ftpServer.security.ssl.dataChannelPolicy:SslAllow"
    & $appcmd set site $SITE_NAME "/ftpServer.security.authentication.basicAuthentication.enabled:true"
    & $appcmd set site $SITE_NAME "/ftpServer.security.authentication.anonymousAuthentication.enabled:true"
    
    # --- CAMBIO CRÍTICO: CHROOT PERFECTO ---
    # IsolateRootDirectoryOnly es el enum exacto de IIS que atrapa al usuario en LocalUser\Usuario
    & $appcmd set site $SITE_NAME "/ftpServer.userIsolation.mode:IsolateRootDirectoryOnly"
    
    & $appcmd set config $SITE_NAME "/section:system.ftpServer/security/authorization" "/+`"[accessType='Allow',users='*',permissions='Read,Write']`"" /commit:apphost
    & $appcmd set config $SITE_NAME "/section:system.ftpServer/security/authorization" "/+`"[accessType='Allow',users='?',permissions='Read,Write']`"" /commit:apphost

    Restart-Service ftpsvc -ErrorAction SilentlyContinue
    Stop-Transcript
    
    Write-Host "`n[+] Entorno base FTP instalado. Aislamiento tipo Linux activado." -ForegroundColor Green
    Pausa
}

function Seleccionar-CrearGrupoFTP {
    $arr_grupos = @()
    if (Test-Path $DIR_FTP_MASTER) {
        Get-ChildItem -Path $DIR_FTP_MASTER -Directory | Where-Object { $_.Name -ne "general" } | ForEach-Object {
            $arr_grupos += $_.Name
        }
    }

    $arr_grupos += "++ CREAR NUEVO GRUPO ++"
    $eleccion = Generar-Menu "SELECCIONE EL GRUPO PARA EL USUARIO" $arr_grupos "Cancelar"

    if ($eleccion -eq $arr_grupos.Count) {
        return $null
    } elseif ($arr_grupos[$eleccion] -eq "++ CREAR NUEVO GRUPO ++") {
        $nuevo_grupo = Capturar-UsuarioSeguro "Escriba el nombre del nuevo grupo"
        if (Confirmar-Accion "Crear/Utilizar el grupo '$nuevo_grupo' y su boveda compartida?") {
            
            if (-not (Get-LocalGroup -Name $nuevo_grupo -ErrorAction SilentlyContinue)) {
                New-LocalGroup -Name $nuevo_grupo -Description "Grupo de acceso FTP" | Out-Null
            }

            $rutaGrupo = "$DIR_FTP_MASTER\$nuevo_grupo"
            if (-not (Test-Path $rutaGrupo)) {
                New-Item -Path $rutaGrupo -ItemType Directory -Force | Out-Null
            }

            $SidSys = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
            $SidAdm = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')

            $AclGrupo = Get-Acl $rutaGrupo
            $AclGrupo.SetAccessRuleProtection($true, $false)
            $AclGrupo.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($SidSys, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
            $AclGrupo.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($SidAdm, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
            
            $GrpAccount = New-Object System.Security.Principal.NTAccount($nuevo_grupo)
            $AclGrupo.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($GrpAccount, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")))
            
            Set-Acl -Path $rutaGrupo -AclObject $AclGrupo

            return $nuevo_grupo
        }
        return $null
    } else {
        return $arr_grupos[$eleccion]
    }
}

function Procesar-UsuarioFTP {
    param([string]$Usuario, [string]$Password, [string]$Grupo)

    $usrFisico = "$global:DIR_FTP_ROOT\LocalUser\$Usuario"
    $SecurePass = ConvertTo-SecureString $Password -AsPlainText -Force

    $usrObj = Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue

    if ($usrObj) {
        Log-Info "Usuario existente. Sincronizando contraseña y asegurando membresía..."
        Set-LocalUser -Name $Usuario -Password $SecurePass -ErrorAction SilentlyContinue
        Add-LocalGroupMember -Group $Grupo -Member $Usuario -ErrorAction SilentlyContinue
    } else {
        Write-Host "Creando usuario local: $Usuario ($Grupo)..." -ForegroundColor Cyan
        try {
            New-LocalUser -Name $Usuario -Password $SecurePass -PasswordNeverExpires -UserMayNotChangePassword -Description "Usuario FTP Automatizado" -ErrorAction Stop | Out-Null
            Add-LocalGroupMember -Group $Grupo -Member $Usuario -ErrorAction SilentlyContinue
            
            $GrupoUsuarios = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([System.Security.Principal.NTAccount]).Value
            Add-LocalGroupMember -Group $GrupoUsuarios -Member $Usuario -ErrorAction SilentlyContinue

            Add-LocalGroupMember -Group "IIS_IUSRS" -Member $Usuario -ErrorAction SilentlyContinue
        } catch {
            Log-Error "Fallo crítico al crear a '$Usuario'. Detalle del error: $_"
            return 
        }
    }

    # --- CAMBIO CRÍTICO: LÓGICA DE MIGRACIÓN TIPO LINUX (Borrado de Fantasmas) ---
    if (Test-Path $usrFisico) {
        $carpetas = Get-ChildItem -Path $usrFisico -Directory
        foreach ($carpeta in $carpetas) {
            $nombreCarpeta = $carpeta.Name
            
            # Identificamos si es un grupo antiguo. Conservamos 'general', la carpeta del '$Usuario' y el '$Grupo' actual.
            if ($nombreCarpeta -ne "general" -and $nombreCarpeta -ne $Usuario -and $nombreCarpeta -ne $Grupo) {
                
                # 1. ARREGLO DESTRUCTIVO: Usamos rmdir nativo para destrozar el Junction sin que PowerShell evalúe su contenido.
                # Esto garantiza que visualmente DESAPAREZCA del cliente FTP.
                cmd.exe /c "rmdir `"$($carpeta.FullName)`" 2>nul"
                
                # 2. Sacamos al usuario del grupo viejo en Windows para revocarle el NTFS
                Remove-LocalGroupMember -Group $nombreCarpeta -Member $Usuario -ErrorAction SilentlyContinue
                
                Write-Host "[-] El túnel visual y el acceso al grupo '$nombreCarpeta' han sido destruidos." -ForegroundColor DarkYellow
            }
        }
    }

    # Creación de la carpeta estructural privada con el nombre del usuario
    if (-not (Test-Path "$usrFisico\$Usuario")) {
        New-Item -Path "$usrFisico\$Usuario" -ItemType Directory -Force | Out-Null
    }
    
    $SidSys = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $AclUsr = Get-Acl $usrFisico
    $AclUsr.SetAccessRuleProtection($true, $false)
    $UsrAccount = New-Object System.Security.Principal.NTAccount($Usuario)
    
    $AclUsr.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($UsrAccount, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")))
    $AclUsr.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($SidSys, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
    Set-Acl -Path $usrFisico -AclObject $AclUsr

    # UNIONES (Junctions)
    $JunctionGeneral = "$usrFisico\general"
    if (-not (Test-Path $JunctionGeneral)) {
        New-Item -ItemType Junction -Path $JunctionGeneral -Target "$global:DIR_FTP_MASTER\general" | Out-Null
    }

    $JunctionGrupo = "$usrFisico\$Grupo"
    if (-not (Test-Path $JunctionGrupo)) {
        New-Item -ItemType Junction -Path $JunctionGrupo -Target "$global:DIR_FTP_MASTER\$Grupo" | Out-Null
    }

    Log-Ok "Usuario $Usuario estructurado perfectamente. Túneles sincronizados y jaula sellada."
}

function Gestionar-UsuariosFTP {
    Clear-Host
    Write-Host "--- 2. AUTOMATIZACION MASIVA DE USUARIOS (WINDOWS) ---" -ForegroundColor Yellow
    
    if (-not (Test-Path "$DIR_FTP_MASTER\general")) {
        Log-Error "Debe preparar el entorno base (Opcion 1) antes de operar."
        Pausa; return
    }

    $n_users = Capturar-Entero "¿Cuántos usuarios desea registrar o modificar?"

    for ($i=1; $i -le $n_users; $i++) {
        Write-Host "`n--- Usuario $i de $n_users ---" -ForegroundColor Yellow
        $nombre = Capturar-UsuarioSeguro "Identificador del usuario"
        $password = Read-Host "Contraseña (Puede ser simple gracias a la anulación de políticas)" -AsSecureString
        $passPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
        
        $grupoSeleccionado = Seleccionar-CrearGrupoFTP
        if ($grupoSeleccionado) {
            Procesar-UsuarioFTP -Usuario $nombre -Password $passPlain -Grupo $grupoSeleccionado
        } else {
            Log-Warning "Configuracion cancelada para el usuario $nombre."
        }
    }
    Pausa
}

function Resetear-EntornoFTP {
    Clear-Host
    Write-Host "--- 5. DESTRUCCION TOTAL DEL ENTORNO FTP IIS (RESET) ---" -ForegroundColor Red
    
    if (Confirmar-Accion "PELIGRO EXTREMO! Destruir Usuarios IIS, Grupos y Bovedas?") {
        $appcmd = "$env:systemroot\system32\inetsrv\appcmd.exe"
        & $appcmd delete site $SITE_NAME | Out-Null

        if (Test-Path "$DIR_FTP_ROOT\LocalUser") {
            Get-ChildItem -Path "$DIR_FTP_ROOT\LocalUser" -Directory | Where-Object { $_.Name -ne "Public" } | ForEach-Object {
                Remove-LocalUser -Name $_.Name -ErrorAction SilentlyContinue
            }
        }
        
        if (Test-Path $DIR_FTP_MASTER) {
            Get-ChildItem -Path $DIR_FTP_MASTER -Directory | Where-Object { $_.Name -ne "general" } | ForEach-Object {
                Remove-LocalGroup -Name $_.Name -ErrorAction SilentlyContinue
            }
        }

        if (Test-Path $DIR_FTP_ROOT) { Remove-Item -Path $DIR_FTP_ROOT -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $DIR_FTP_MASTER) { Remove-Item -Path $DIR_FTP_MASTER -Recurse -Force -ErrorAction SilentlyContinue }

        Log-Ok "El entorno IIS FTP fue purgado."
    }
    Pausa
}

function Menu-FTP {
    $OpcionesFTP = @(
        "Instalar / Preparar Boveda IIS (Base en Blanco)",
        "Gestionar Usuarios Masivos (Crear/Migrar)",
        "Destruir Entorno FTP (Reset Total para Examen)"
    )
    
    while ($true) {
        $estado = if (Test-Path "$DIR_FTP_MASTER\general") { "ACTIVO" } else { "INACTIVO" }
        $Eleccion = Generar-Menu "MODULO DE GESTION FTP IIS [ $estado ]" $OpcionesFTP "Volver al Menu Principal"
        
        switch ($Eleccion) {
            0 { Gestionar-InstalacionFTP }
            1 { Gestionar-UsuariosFTP }
            2 { Resetear-EntornoFTP }
            3 { return }
        }
    }
}

Menu-FTP