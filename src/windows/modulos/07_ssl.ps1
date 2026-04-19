# ============================================================
# 07_ssl.ps1 - P7: Infraestructura de Despliegue Seguro (Windows)
# Compatible: PowerShell 5.1 (Windows Server 2022)
# Fixes:
#   - Orquestador automatizado y parametrizado (Cero iteracción en ejecución)
#   - Asistente de inyección de variables en el menú
#   - Estado transaccional (archivo .tmp, solo escribe al exito)
#   - OpenSSL verificado al entrar al modulo
#   - Junction apunta a C:\FTP_Master\http\Windows\
# ============================================================

$global:DOMINIO_SSL  = "reprobados.com"
$global:WIN_ESTADO   = Join-Path $global:REPO_ROOT "config\windows_estado.conf"
$global:WIN_ESTADO_TMP = Join-Path $global:REPO_ROOT "config\windows_estado.tmp"

$global:SITE_NAME    = "Servidor_FTP_Secure"
# Crear directorio config
$configDir = Split-Path $global:WIN_ESTADO
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

# ============================================================
# ESTADO TRANSACCIONAL (Corregido para no borrar historial)
# ============================================================
function Iniciar-TransaccionEstado {
    if (Test-Path $global:WIN_ESTADO) {
        Copy-Item $global:WIN_ESTADO $global:WIN_ESTADO_TMP -Force
    } elseif (Test-Path $global:WIN_ESTADO_TMP) {
        Remove-Item $global:WIN_ESTADO_TMP -Force
    }
    
    if (-not (Test-Path $global:WIN_ESTADO_TMP)) {
        New-Item -ItemType File -Path $global:WIN_ESTADO_TMP -Force | Out-Null
    }
}

function Guardar-EstadoTmp {
    param([string]$Clave, [string]$Valor)
    if (-not (Test-Path $global:WIN_ESTADO_TMP)) {
        New-Item -ItemType File -Path $global:WIN_ESTADO_TMP -Force | Out-Null
    }
    $lineas = @(Get-Content $global:WIN_ESTADO_TMP -Encoding ASCII -ErrorAction SilentlyContinue)
    $nuevas = @()
    foreach ($linea in $lineas) {
        if ($linea -notmatch ("^" + $Clave + "=")) { $nuevas += $linea }
    }
    $nuevas += ($Clave + "=" + $Valor)
    $nuevas | Set-Content $global:WIN_ESTADO_TMP -Encoding ASCII
}

function Confirmar-TransaccionEstado {
    if (Test-Path $global:WIN_ESTADO_TMP) {
        Copy-Item $global:WIN_ESTADO_TMP $global:WIN_ESTADO -Force
        Remove-Item $global:WIN_ESTADO_TMP -Force
    }
}

function Cancelar-TransaccionEstado {
    if (Test-Path $global:WIN_ESTADO_TMP) {
        Remove-Item $global:WIN_ESTADO_TMP -Force
    }
}

function Guardar-EstadoWin {
    param([string]$Clave, [string]$Valor)
    if (-not (Test-Path $global:WIN_ESTADO)) {
        New-Item -ItemType File -Path $global:WIN_ESTADO -Force | Out-Null
    }
    $lineas = @(Get-Content $global:WIN_ESTADO -Encoding ASCII -ErrorAction SilentlyContinue)
    $nuevas = @()
    foreach ($linea in $lineas) {
        if ($linea -notmatch ("^" + $Clave + "=")) { $nuevas += $linea }
    }
    $nuevas += ($Clave + "=" + $Valor)
    $nuevas | Set-Content $global:WIN_ESTADO -Encoding ASCII
}

function Leer-EstadoWin {
    param([string]$Clave)
    if (-not (Test-Path $global:WIN_ESTADO)) { return "" }
    $lineas = Get-Content $global:WIN_ESTADO -Encoding ASCII -ErrorAction SilentlyContinue
    foreach ($linea in $lineas) {
        if ($linea -match ("^" + $Clave + "=")) {
            return ($linea -replace ("^" + $Clave + "="), "")
        }
    }
    return ""
}

# ============================================================
# CONFIGURAR DOMINIO SSL
# ============================================================
function Configurar-DominioSSL {
    Clear-Host
    Write-Host "--- CONFIGURACION DE DOMINIO SSL ---" -ForegroundColor Yellow
    Write-Host "  Dominio actual: $($global:DOMINIO_SSL)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Nuevo dominio [Enter para mantener '$($global:DOMINIO_SSL)']: " -NoNewline
    $nuevo = Read-Host
    if (-not [string]::IsNullOrWhiteSpace($nuevo)) {
        $nuevo = $nuevo.ToLower() -replace "^www\.", ""
        if ($nuevo -match "^[a-z0-9\-]+\.[a-z]{2,}(\.[a-z]{2,})?$") {
            $global:DOMINIO_SSL = $nuevo
            Guardar-EstadoWin "DOMINIO_SSL" $nuevo
            Log-Ok "Dominio SSL: $nuevo"
        } else {
            Log-Error "Formato invalido. Se mantiene: $($global:DOMINIO_SSL)"
        }
    }
    Pausa
}

# ============================================================
# CREAR USUARIO REPO P7
# ============================================================
function Crear-UsuarioRepoP7 {
    param([string]$Usuario = "ftprepo", [string]$Password = "Repo_P7!")

    $existe = Get-LocalUser $Usuario -ErrorAction SilentlyContinue
    if ($existe) { return }

    $passSegura = ConvertTo-SecureString $Password -AsPlainText -Force
    New-LocalUser -Name $Usuario -Password $passSegura `
        -PasswordNeverExpires -UserMayNotChangePassword `
        -Description $global:REPO_FTP_DESC `
        -ErrorAction SilentlyContinue | Out-Null

    FTP-Asegurar-Junction -NombreUsuario $Usuario | Out-Null

    $appcmd = "$env:systemroot\system32\inetsrv\appcmd.exe"
    if (Test-Path $appcmd) {
        $siteName = if ($global:SITE_NAME) { $global:SITE_NAME } else { "Servidor_FTP_Secure" }
        & $appcmd set config $siteName `
            "/section:system.ftpServer/security/authorization" `
            "/+[accessType='Allow',users='$nuevoUser',permissions='Read']" `
            /commit:apphost 2>&1 | Out-Null
    }
    Log-Ok "Usuario repo '$Usuario' creado (pass: $Password)"
}

# ============================================================
# INSTALAR SERVIDOR HTTP (AUTOMATIZADO / NO INTERACTIVO)
# Cero menús. Todo se recibe por parámetros para despliegue masivo.
# ============================================================
function Instalar-ServidorHTTP-Automatizado {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("WEB", "FTP")][string]$Fuente,
        [Parameter(Mandatory=$true)][ValidateSet("iis", "apache", "nginx")][string]$Motor,
        [Parameter(Mandatory=$true)][int]$PuertoHTTP,
        [Parameter(Mandatory=$true)][bool]$HabilitarSSL,
        [int]$PuertoSSL = 443,
        [string]$FtpIP = "127.0.0.1",
        [string]$FtpUser = "luis",
        [string]$FtpPass = "123"
    )

    Clear-Host
    Write-Host "=== DESPLIEGUE AUTOMATIZADO: $($Motor.ToUpper()) VIA $Fuente ===" -ForegroundColor Yellow
    Write-Host "  [*] HTTP: $PuertoHTTP | SSL Activo: $HabilitarSSL | HTTPS: $PuertoSSL" -ForegroundColor Cyan

    Iniciar-TransaccionEstado
    $versionInstalada  = ""

    # ── FASE 1: OBTENCION DE BINARIOS (WEB vs FTP) ─────────────────
    if ($Fuente -eq "WEB") {
        Write-Host "`n--- FASE 1: DESCARGA WEB OFICIAL ---" -ForegroundColor Yellow
        $versiones = @(Extraer-VersionesDinamicas -Motor $Motor)
        if ($versiones.Count -eq 0) {
            Log-Error "Sin conexion a repositorios oficiales (Chocolatey/Windows)."
            Cancelar-TransaccionEstado; return $false
        }
        $versionInstalada = ($versiones[0] -split ' ')[0] 

        Liberar-PuertoAnterior -Motor $Motor -Puerto $PuertoHTTP
        if (-not (Instalar-PaquetesWeb -Motor $Motor -Version $versionInstalada)) {
            Log-Error "Fallo en la instalacion WEB automatizada."
            Cancelar-TransaccionEstado; return $false
        }
    } 
    else {
        Write-Host "`n--- FASE 1: OBTENCION DESDE REPOSITORIO FTP ---" -ForegroundColor Yellow
        $carpetaMotor = switch ($Motor.ToLower()) {
            "iis"    { "IIS" }
            "apache" { "Apache" }
            "nginx"  { "Nginx" }
            default  { $Motor }
        }
        $rutaRemota = $carpetaMotor
        $rutaInstalador = FTP-Obtener-Instalador-Automatizado -IP $FtpIP -Usuario $FtpUser -Password $FtpPass -Motor $Motor -OS "Windows"
        
        if (-not $rutaInstalador) {
            Log-Error "Orquestacion FTP fallida (Archivo corrupto o no encontrado)."
            Cancelar-TransaccionEstado; return $false
        }

        Liberar-PuertoAnterior -Motor $Motor -Puerto $PuertoHTTP
        if (-not (Instalar-Desde-FTP -Archivo $rutaInstalador -Motor $Motor -RutaRemota $rutaRemota)) {
            Log-Error "Fallo critico al instalar el binario local extraido del FTP."
            Cancelar-TransaccionEstado; return $false
        }
        
        $matchVer = [regex]::Match((Split-Path $rutaInstalador -Leaf), '\d+[\.\d]+')
        $versionInstalada = if ($matchVer.Success) { $matchVer.Value } else { "FTP-Offline" }
        Remove-Item $rutaInstalador -Force -ErrorAction SilentlyContinue
    }

    # ── FASE 2: CONFIGURACION DE RED Y HARDENING ─────────────────
    Write-Host "`n--- FASE 2: BINDING Y HARDENING ---" -ForegroundColor Yellow
    
    $estHttp = Validar-PuertoTCP -Puerto $PuertoHTTP -Motor $Motor
    if ($estHttp -ne 0) {
        Log-Error "El puerto HTTP $PuertoHTTP esta bloqueado o en uso. Abortando automatizacion."
        Cancelar-TransaccionEstado; return $false
    }

    if (-not (Configurar-PuertoServicio -Motor $Motor -Puerto $PuertoHTTP)) {
        Log-Error "Fallo al aplicar el puerto $PuertoHTTP."
        Cancelar-TransaccionEstado; return $false
    }
    Guardar-EstadoTmp ("PUERTO_HTTP_" + $Motor.ToUpper()) "$PuertoHTTP"

    Aplicar-HardeningSeguridad -Motor $Motor
    Aislar-DirectorioWeb -Motor $Motor
    Desplegar-PlantillaHTML -Motor $Motor -Version $versionInstalada -Puerto $PuertoHTTP

    # ── FASE 3: CIFRADO SSL/TLS OBLIGATORIO ──────────────────────
    Write-Host "`n--- FASE 3: SEGURIDAD SSL/TLS ---" -ForegroundColor Yellow
    if ($HabilitarSSL) {
        $estSsl = Validar-PuertoTCP -Puerto $PuertoSSL -Motor $Motor
        if ($estSsl -ne 0) {
            Log-Error "El puerto SSL $PuertoSSL no esta disponible."
            Guardar-EstadoTmp ("SSL_ACTIVO_" + $Motor.ToUpper()) "ERROR"
        } else {
            $sslOk = switch ($Motor) {
                "iis"    { Activar-SSL-IIS    -Dominio $global:DOMINIO_SSL -PuertoHTTP $PuertoHTTP -PuertoSSL $PuertoSSL }
                "apache" { Activar-SSL-Apache -Dominio $global:DOMINIO_SSL -PuertoHTTP $PuertoHTTP -PuertoSSL $PuertoSSL }
                "nginx"  { Activar-SSL-Nginx  -Dominio $global:DOMINIO_SSL -PuertoHTTP $PuertoHTTP -PuertoSSL $PuertoSSL }
            }

            if ($sslOk) {
                Guardar-EstadoTmp ("PUERTO_SSL_" + $Motor.ToUpper()) "$PuertoSSL"
                Guardar-EstadoTmp ("SSL_ACTIVO_" + $Motor.ToUpper()) "SI"
                Log-Ok "Tunel SSL asegurado -> https://$($global:DOMINIO_SSL):$PuertoSSL"
            } else {
                Guardar-EstadoTmp ("SSL_ACTIVO_" + $Motor.ToUpper()) "ERROR"
                Log-Error "Fallo en la inyeccion de certificados."
            }
        }
    } else {
        Guardar-EstadoTmp ("SSL_ACTIVO_" + $Motor.ToUpper()) "NO"
        Log-Warning "Despliegue realizado SIN cifrado SSL (Peligro)."
    }

    Confirmar-TransaccionEstado
    Write-Host "`n[OK] ORQUESTACION DE $($Motor.ToUpper()) FINALIZADA CON EXITO." -ForegroundColor Green
    return $true
}

# ============================================================
# INSTALAR DESDE FTP
# ============================================================
function Instalar-Desde-FTP {
    param([string]$Archivo, [string]$Motor, [string]$RutaRemota = "")
    $ext = [System.IO.Path]::GetExtension($Archivo).ToLower()

    if ($Motor -eq "iis") {
        Log-Info "IIS se instala como rol de Windows."
        return (Instalar-PaquetesWeb -Motor "iis" -Version "" -Puerto 80)
    }
    
    if ($Motor -eq "apache" -or $Motor -eq "nginx") {
        if ($ext -eq ".nupkg" -or $ext -eq ".zip") {
            if (Asegurar-Chocolatey) {
                $dirFuente = Split-Path $Archivo
                $paquete   = if ($Motor -eq "apache") { "apache-httpd" } else { "nginx" }
                
                if ($Motor -eq "apache") { 
                    Stop-Service W3SVC -Force -ErrorAction SilentlyContinue 
                    
                    Write-Host "  [*] Buscando dependencias offline (vcredist140)..." -ForegroundColor Cyan
                    # FIX: buscar vcredist en disco local (FTP_Master) o carpeta temporal
                    $vcLocalDir = "C:\FTP_Master\http\Windows\Apache"
                    $vcFile = Get-ChildItem -Path $dirFuente -Filter "vcredist140*.nupkg" -EA SilentlyContinue | Select-Object -First 1
                    if (-not $vcFile) {
                        $vcFile = Get-ChildItem -Path $vcLocalDir -Filter "vcredist140*.nupkg" -EA SilentlyContinue | Select-Object -First 1
                        if ($vcFile) {
                            Copy-Item $vcFile.FullName $dirFuente -Force
                            $vcFile = Get-ChildItem -Path $dirFuente -Filter "vcredist140*.nupkg" -EA SilentlyContinue | Select-Object -First 1
                        }
                    }
                    if ($vcFile) {
                        Log-Info "Instalando dependencia offline: $($vcFile.Name)"
                        & choco install vcredist140 --source $dirFuente -y --no-progress 2>&1 | Out-Null
                    } else {
                        Log-Warning "vcredist140 no encontrado. Apache podria fallar."
                    }
                }
                
                $resultado = & choco install $paquete --source $dirFuente -y --no-progress 2>&1
                Escribir-Log "INFO" "choco install local: $($resultado -join ' ')"
                
                # FIX: registrar servicio Apache igual que hace la instalacion WEB:
                if ($Motor -eq "apache") {
                    $apacheRuta = Obtener-RutaApache
                    if ($apacheRuta -and (Test-Path "$apacheRuta\bin\httpd.exe")) {
                        & "$apacheRuta\bin\httpd.exe" -k uninstall 2>&1 | Out-Null
                        & "$apacheRuta\bin\httpd.exe" -k install -n "Apache2.4" 2>&1 | Out-Null
                        & sc.exe config Apache2.4 obj= "NT AUTHORITY\NetworkService" password= "" | Out-Null
                        Start-Service Apache2.4 -EA SilentlyContinue
                        Start-Sleep -Seconds 2
                    }
                }
                return ($LASTEXITCODE -eq 0 -or (Get-Service Apache2.4 -EA SilentlyContinue))
            }
        }
        Log-Warning "Tipo no reconocido. Usando instalacion WEB."
        return (Instalar-PaquetesWeb -Motor $Motor -Version "" -Puerto 80)
    }
    Log-Error "Motor '$Motor' no reconocido."
    return $false
}

# ============================================================
# ACTIVAR SSL EN SERVIDOR YA INSTALADO
# ============================================================
function Activar-SSL-Existente {
    Clear-Host
    Write-Host "--- ACTIVAR SSL/TLS EN SERVIDOR HTTP ---" -ForegroundColor Yellow
    Write-Host ""

    $instalados = @(Obtener-MotoresInstalados)
    if ($instalados.Count -eq 0) { Log-Error "No hay servidores instalados."; Pausa; return }

    $selMotor = Generar-Menu "MOTOR A ASEGURAR" $instalados "Cancelar"
    if ($selMotor -eq $instalados.Count) { return }
    $motor = $instalados[$selMotor]

    $pHTTP = Leer-EstadoWin ("PUERTO_HTTP_" + $motor.ToUpper())
    $pHTTPInt = 0
    if ([string]::IsNullOrEmpty($pHTTP) -or -not [int]::TryParse($pHTTP, [ref]$pHTTPInt) -or $pHTTPInt -eq 0) {
        $pHTTPInt = Detectar-PuertoActual -Motor $motor
        if (-not $pHTTPInt -or $pHTTPInt -eq 0) {
            $pHTTPInt = Capturar-Entero "Puerto HTTP actual de $motor"
        }
    }

    $puertoSSLSugerido = switch ($motor) { "iis" { 443 } "apache" { 8443 } "nginx" { 444 } default { 443 } }
    $puertoSSL = Capturar-Puerto-SSL -Motor $motor -PuertoSugerido $puertoSSLSugerido

    Write-Host ""
    Write-Host "  Motor: $($motor.ToUpper()) | HTTP: $pHTTPInt | HTTPS: $puertoSSL | Dominio: $($global:DOMINIO_SSL)" `
               -ForegroundColor Cyan
    Write-Host ""

    $sslOk = $false
    if ($motor -eq "iis") {
        $sslOk = Activar-SSL-IIS    -Dominio $global:DOMINIO_SSL -PuertoHTTP $pHTTPInt -PuertoSSL $puertoSSL
    } elseif ($motor -eq "apache") {
        $sslOk = Activar-SSL-Apache -Dominio $global:DOMINIO_SSL -PuertoHTTP $pHTTPInt -PuertoSSL $puertoSSL
    } elseif ($motor -eq "nginx") {
        $sslOk = Activar-SSL-Nginx  -Dominio $global:DOMINIO_SSL -PuertoHTTP $pHTTPInt -PuertoSSL $puertoSSL
    }

    if ($sslOk) {
        Guardar-EstadoWin ("PUERTO_SSL_" + $motor.ToUpper()) "$puertoSSL"
        Guardar-EstadoWin ("SSL_ACTIVO_" + $motor.ToUpper()) "SI"
        Log-Ok "SSL activado -> https://$($global:DOMINIO_SSL):$puertoSSL"
    } else {
        Guardar-EstadoWin ("SSL_ACTIVO_" + $motor.ToUpper()) "ERROR"
        Log-Error "No se pudo activar SSL en $($motor.ToUpper())."
    }
    Pausa
}

# ============================================================
# GESTIONAR USUARIOS DE DESCARGA
# ============================================================
function Gestionar-UsuariosRepo-Win {
    Clear-Host
    Write-Host "=== USUARIOS REPOSITORIO FTP/HTTP (P7) ===" -ForegroundColor Yellow
    Write-Host ""

    $usuarios = @(Get-LocalUser -ErrorAction SilentlyContinue |
                  Where-Object { $_.Description -eq $global:REPO_FTP_DESC })

    Write-Host "  [ Usuarios P7 actuales ]" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 50))
    if ($usuarios.Count -eq 0) {
        Write-Host "  (ninguno todavia)" -ForegroundColor DarkGray
    } else {
        foreach ($u in $usuarios) {
            $junccion = "C:\FTP_Root\LocalUser\$($u.Name)"
            $juncOk   = $false
            if (Test-Path $junccion) {
                $item = Get-Item $junccion -Force -ErrorAction SilentlyContinue
                $juncOk = ($item.LinkType -eq "Junction")
            }
            $juncTag = if ($juncOk) { "[junction OK]" } else { "[SIN junction!]" }
            $color   = if ($juncOk) { "Green" } else { "Red" }
            Write-Host ("  " + $u.Name.PadRight(20) + "Habilitado: " + $u.Enabled + "  $juncTag") `
                       -ForegroundColor $color
        }
    }
    Write-Host ""

    $opciones = @(
        "Agregar usuario de descarga",
        "Eliminar usuario de descarga",
        "Verificar acceso + arbol FTP + permisos NTFS"
    )
    $sel = Generar-Menu "GESTION USUARIOS REPO" $opciones "Volver"
    if ($sel -eq $opciones.Count) { return }

    if ($sel -eq 0) {
        Write-Host "`n--- AGREGAR USUARIO ---" -ForegroundColor Yellow
        Write-Host "  Nombre de usuario: " -NoNewline
        $nuevoUser = Read-Host
        if ([string]::IsNullOrWhiteSpace($nuevoUser)) { Pausa; return }

        $nuevoPassSec = Read-Host "  Contrasena" -AsSecureString
        $existeUser = Get-LocalUser $nuevoUser -ErrorAction SilentlyContinue
        
        if ($existeUser) {
            Log-Warning "Usuario '$nuevoUser' ya existe."
            if (Confirmar-Accion "Actualizar contrasena y corregir junction?") {
                Set-LocalUser -Name $nuevoUser -Password $nuevoPassSec
                FTP-Asegurar-Junction -NombreUsuario $nuevoUser | Out-Null
                Log-Ok "Actualizado."
            }
            Pausa; return
        }

        New-LocalUser -Name $nuevoUser -Password $nuevoPassSec `
            -PasswordNeverExpires -UserMayNotChangePassword `
            -Description $global:REPO_FTP_DESC `
            -ErrorAction SilentlyContinue | Out-Null

        $juncOk = FTP-Asegurar-Junction -NombreUsuario $nuevoUser
        if ($juncOk) { Log-Ok "Junction creada: C:\FTP_Root\LocalUser\$nuevoUser -> $($global:REPO_FTP_DIR)" }
        else         { Log-Warning "Junction fallo — verifique IIS-FTP." }

        $appcmd = "$env:systemroot\system32\inetsrv\appcmd.exe"
        if (Test-Path $appcmd) {
            $siteName = if ($global:SITE_NAME) { $global:SITE_NAME } else { "Servidor_FTP_Secure" }
            & $appcmd set config $siteName `
                "/section:system.ftpServer/security/authorization" `
                "/+[accessType='Allow',users='$nuevoUser',permissions='Read']" `
                /commit:apphost 2>&1 | Out-Null
        }

        $passTxt = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($nuevoPassSec))
        $ipLocal = Obtener-IP-Local

        Log-Ok "Usuario '$nuevoUser' creado."
        Write-Host ""
        Write-Host "  Credenciales para el profesor:" -ForegroundColor Green
        Write-Host "  Host : $ipLocal"     -ForegroundColor Cyan
        Write-Host "  User : $nuevoUser"   -ForegroundColor Cyan
        Write-Host "  Pass : $passTxt"     -ForegroundColor Cyan
        Write-Host "  Path : ftp://$ipLocal/http/Windows/" -ForegroundColor Cyan

    } elseif ($sel -eq 1) {
        if ($usuarios.Count -eq 0) { Log-Error "No hay usuarios."; Pausa; return }
        $names   = @($usuarios | ForEach-Object { $_.Name })
        $selUser = Generar-Menu "USUARIO A ELIMINAR" $names "Cancelar"
        if ($selUser -eq $names.Count) { return }
        $nombre = $names[$selUser]
        
        if (Confirmar-Accion "Eliminar usuario '$nombre' y su junction?") {
            $junccion = "C:\FTP_Root\LocalUser\$nombre"
            if (Test-Path $junccion) { cmd /c "rmdir `"$junccion`"" 2>&1 | Out-Null }
            Remove-LocalUser -Name $nombre -ErrorAction SilentlyContinue
            Log-Ok "Usuario '$nombre' y junction eliminados."
        }
        } elseif ($sel -eq 2) {
        if ($usuarios.Count -eq 0) { Log-Error "No hay usuarios."; Pausa; return }
        $names   = @($usuarios | ForEach-Object { $_.Name })
        $selUser = Generar-Menu "USUARIO A VERIFICAR" $names "Cancelar"
        if ($selUser -eq $names.Count) { return }

        $usr     = $names[$selUser]
        $passRaw = Read-Host "  Contrasena de $usr" -AsSecureString
        $pass    = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($passRaw))
        $ipFTP   = Obtener-IP-Local

        Write-Host "`n  [*] Probando navegacion FTPS en $ipFTP..." -ForegroundColor Cyan

        $ftpIpAntes   = $global:FTP_IP
        $ftpUserAntes = $global:FTP_USER
        $ftpPassAntes = $global:FTP_PASS
        $ftpSslAntes  = $global:FTP_USA_SSL

        $global:FTP_IP      = $ipFTP
        $global:FTP_USER    = $usr
        $global:FTP_PASS    = $pass
        $global:FTP_USA_SSL = $true # PARCHE: Forzar el túnel SSL para la auditoría

        if (FTP-Probar-Conexion -UsarSSL $true) { 
            Log-Ok "Conexion FTPS (Segura) exitosa como '$usr'." 
        } else { 
            Log-Error "No se pudo conectar al FTPS. Verificando junction y Firewall..." 
        }

        # PARCHE: Las rutas se ajustaron a la realidad del chroot de IIS FTP
        foreach ($ruta in @("", "Apache", "Nginx", "IIS")) {
            $label = if ($ruta -eq "") { "Raiz (Repositorio Windows) /" } else { "/$ruta/" }
            Write-Host "`n  [ $label ]" -ForegroundColor Cyan
            $items = @(FTP-Listar-Directorio $ruta)
            if ($items.Count -gt 0) { foreach ($item in $items) { Write-Host "    $item" -ForegroundColor Green } } 
            else { Write-Host "    (vacio o inaccesible)" -ForegroundColor DarkGray }
        }

        Write-Host "`n  Arbol del repositorio local (Fisico):" -ForegroundColor Yellow
        FTP-Mostrar-Arbol-Repositorio

        Write-Host "  Permisos NTFS del directorio base:" -ForegroundColor Yellow
        FTP-Mostrar-Permisos-NTFS -Ruta $global:REPO_FTP_DIR

        $junccion = "C:\FTP_Root\LocalUser\$usr"
        Write-Host "  Junction de $usr :" -ForegroundColor Yellow
        if (Test-Path $junccion) {
            $item = Get-Item $junccion -Force -ErrorAction SilentlyContinue
            if ($item.LinkType -eq "Junction") { Write-Host "    $junccion -> $($item.Target)" -ForegroundColor Green } 
            else { Write-Host "    $junccion (NO es junction — carpeta normal)" -ForegroundColor Red }
        } else { Write-Host "    (no existe)" -ForegroundColor Red }

        $global:FTP_IP      = $ftpIpAntes
        $global:FTP_USER    = $ftpUserAntes
        $global:FTP_PASS    = $ftpPassAntes
        $global:FTP_USA_SSL = $ftpSslAntes
    }
    Pausa
}

# ============================================================
# MENU PRINCIPAL P7 (Orquestador SSL)
# ============================================================
function Menu-SSL {
    Write-Host ""
    Verificar-Dependencias-P7

    $dom = Leer-EstadoWin "DOMINIO_SSL"
    if (-not [string]::IsNullOrEmpty($dom)) { $global:DOMINIO_SSL = $dom }

    while ($true) {
        $opcionesP7 = @(
            "Asistente de Despliegue de Servidor HTTP (Orquestador)",
            "Activar SSL/TLS en servidor ya instalado",
            "Activar FTPS en IIS FTP",
            "Resumen SSL/TLS (verificacion automatica)",
            "Preparar repositorio FTP (estructura + binarios + SHA256)",
            "Gestionar usuarios de descarga (Repositorio FTP)",
            ("Configurar dominio SSL [actual: " + $global:DOMINIO_SSL + "]")
        )

        $eleccion = Generar-Menu "P7 -- INFRAESTRUCTURA DE DESPLIEGUE SEGURO" $opcionesP7 "Volver al Menu Principal"

        if ($eleccion -eq 0) {
            # ── EL ASISTENTE: RECOLECTA ARGUMENTOS Y DISPARA EL ORQUESTADOR ──
            Clear-Host
            Write-Host "=== ASISTENTE DE PREPARACION (ORQUESTADOR) ===" -ForegroundColor Yellow
            $fuentes = @("WEB", "FTP")
            $selF = Generar-Menu "FUENTE DE INSTALACION" $fuentes "Cancelar"
            if ($selF -eq $fuentes.Count) { continue }
            $fuenteSel = $fuentes[$selF]

            $motores = @("iis", "apache", "nginx")
            $selM = Generar-Menu "MOTOR HTTP" $motores "Cancelar"
            if ($selM -eq $motores.Count) { continue }
            $motorSel = $motores[$selM]

            $pSugerido = switch ($motorSel) { "iis" { 80 } "apache" { 81 } "nginx" { 82 } default { 80 } }
            $pHttp = Capturar-Entero "Ingrese el Puerto HTTP [Sugerido: $pSugerido]"
            
            $habSsl = Confirmar-Accion "¿Habilitar cifrado SSL/TLS?"
            $pSsl = 443
            if ($habSsl) {
                $pSslSug = switch ($motorSel) { "iis" { 443 } "apache" { 8443 } "nginx" { 444 } default { 443 } }
                $pSsl = Capturar-Entero "Ingrese el Puerto SSL [Sugerido: $pSslSug]"
            }

            $fIp = "127.0.0.1"; $fUser = "luis"; $fPass = "123"
            if ($fuenteSel -eq "FTP") {
                $fIp = Obtener-IP-Local
                Write-Host "`n  [ Datos de Conexion FTP ]" -ForegroundColor Cyan
                $inIp = Read-Host "  IP del FTP [Enter para $fIp]"
                if (-not [string]::IsNullOrWhiteSpace($inIp)) { $fIp = $inIp }
                
                $inUser = Read-Host "  Usuario [Enter para 'luis']"
                if (-not [string]::IsNullOrWhiteSpace($inUser)) { $fUser = $inUser }
                
                $fPassRaw = Read-Host "  Contrasena" -AsSecureString
                $fPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($fPassRaw))
            }

            # La Inyeccion: Ejecuta la logica real 100% ciega.
            Instalar-ServidorHTTP-Automatizado -Fuente $fuenteSel -Motor $motorSel -PuertoHTTP $pHttp -HabilitarSSL $habSsl -PuertoSSL $pSsl -FtpIP $fIp -FtpUser $fUser -FtpPass $fPass
            Pausa

        } elseif ($eleccion -eq 1) {
            Activar-SSL-Existente
        } elseif ($eleccion -eq 2) {
            Clear-Host
            Write-Host "--- ACTIVAR FTPS EN IIS FTP ---" -ForegroundColor Yellow
            Write-Host "  Dominio: $($global:DOMINIO_SSL)" -ForegroundColor Cyan
            Write-Host ""
            $ftpsOk = Activar-FTPS-IIS -Dominio $global:DOMINIO_SSL
            if ($ftpsOk) { Guardar-EstadoWin "FTPS_ACTIVO" "SI" }
            else         { Guardar-EstadoWin "FTPS_ACTIVO" "ERROR" }
            Pausa   
        } elseif ($eleccion -eq 3) {
            Resumen-SSL-Windows
        } elseif ($eleccion -eq 4) {
            FTP-Preparar-Repositorio
        } elseif ($eleccion -eq 5) {
            Gestionar-UsuariosRepo-Win
        } elseif ($eleccion -eq 6) {
            Configurar-DominioSSL
        } elseif ($eleccion -eq 7) {
            Clear-Host; return
        }
    }
}