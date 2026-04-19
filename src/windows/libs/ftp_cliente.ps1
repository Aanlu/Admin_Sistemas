# ============================================================
# ftp_cliente.ps1 - Cliente FTP y Descargas Híbridas para P7
# ============================================================

$global:FTP_IP              = ""
$global:FTP_USER            = ""
$global:FTP_PASS            = ""
$global:FTP_USA_SSL         = $false
$global:REPO_FTP_DESC       = "Usuario repositorio FTP P7"
$global:REPO_FTP_DIR        = "C:\FTP_Master\http\Windows"

# ============================================================
# DESCARGA-RAPIDA (Motor de transferencia Multimodal)
# FIX ANALÍTICO: Uso de curl.exe nativo para HTTP/HTTPS (CDN)
# ============================================================
function Descarga-Rapida {
    param(
        [string]$Url,
        [string]$Destino,
        [string]$Usuario = "",
        [string]$Password = ""
    )

    $esFTP  = $Url -match "^ftp://"
    $nombre = Split-Path $Destino -Leaf
    $spin   = @('|','/','-','\')
    $i      = 0

    Write-Host "  [*] Descargando: $nombre" -ForegroundColor Cyan

    try {
        if ($esFTP) {
            # --- MOTOR FTP PURO (.NET FtpWebRequest) ---
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            
            $req = [System.Net.FtpWebRequest][System.Net.WebRequest]::Create($Url)
            $req.Method     = [System.Net.WebRequestMethods+Ftp]::DownloadFile
            $req.UsePassive = $true
            $req.UseBinary  = $true
            $req.EnableSsl  = $global:FTP_USA_SSL
            $req.Timeout    = 120000
            if (-not [string]::IsNullOrEmpty($Usuario)) {
                $req.Credentials = New-Object System.Net.NetworkCredential($Usuario, $Password)
            }

            $resp   = $req.GetResponse()
            $stream = $resp.GetResponseStream()
            $fs     = [System.IO.FileStream]::new($Destino, [System.IO.FileMode]::Create)
            $buf    = New-Object byte[] 8192
            $total  = 0

            while ($true) {
                $read = $stream.Read($buf, 0, $buf.Length)
                if ($read -le 0) { break }
                $fs.Write($buf, 0, $read)
                $total += $read
                $kb = [math]::Round($total / 1KB, 0)
                Write-Host ("`r  " + $spin[$i % 4] + " $kb KB...") -NoNewline -ForegroundColor Cyan
                $i++
            }
            $fs.Close(); $stream.Close(); $resp.Close()

        } else {
            # --- MOTOR HTTP/HTTPS MODERNO (curl.exe nativo de WS 2022) ---
            # Evita el bloqueo TLS de .NET Framework durante las redirecciones CDN
            $curlArgs = @("-L", "-s", "-o", $Destino, $Url)
            if (-not [string]::IsNullOrEmpty($Usuario)) {
                $curlArgs += "-u", "$Usuario`:$Password"
            }
            
            # Ejecutamos curl en background para mantener el hilo principal libre y pintar el UI
            $proc = Start-Process -FilePath "curl.exe" -ArgumentList $curlArgs -WindowStyle Hidden -PassThru
            
            while (-not $proc.HasExited) {
                Write-Host ("`r  " + $spin[$i % 4] + " Negociando con CDN y descargando...") -NoNewline -ForegroundColor Cyan
                Start-Sleep -Milliseconds 150
                $i++
            }
            
            if ($proc.ExitCode -ne 0) { throw "El servidor remoto rechazo la conexion (curl exit: $($proc.ExitCode))" }
        }

    } catch {
        Write-Host "`r  [ERROR] $($_.Exception.Message)                    " -ForegroundColor Red
        if (Test-Path $Destino) { Remove-Item $Destino -Force -ErrorAction SilentlyContinue }
        return $false
    }

    # Validación Estricta Anti-Corrupción
    if (-not (Test-Path $Destino) -or (Get-Item $Destino).Length -lt 10) {
        Write-Host "`r  [ERROR] Archivo no creado o vacio (Rechazado).        " -ForegroundColor Red
        if (Test-Path $Destino) { Remove-Item $Destino -Force -ErrorAction SilentlyContinue }
        return $false
    }

    $kb = [math]::Round((Get-Item $Destino).Length / 1KB, 1)
    Write-Host ("`r  [OK] $nombre ($kb KB)                    ") -ForegroundColor Green
    return $true
}

function Descarga-FTP-Rapida {
    param([string]$UrlFtp, [string]$Destino, [string]$Usuario = "", [string]$Password = "")
    return Descarga-Rapida -Url $UrlFtp -Destino $Destino -Usuario $Usuario -Password $Password
}

# ============================================================
# FTP-LISTAR-DIRECTORIO
# ============================================================
function FTP-Listar-Directorio {
    param([string]$Ruta)

    $url = "ftp://" + $global:FTP_IP + "/" + $Ruta + "/"
    try {
        $req = [System.Net.FtpWebRequest][System.Net.WebRequest]::Create($url)
        $req.Method      = [System.Net.WebRequestMethods+Ftp]::ListDirectory
        $req.Credentials = New-Object System.Net.NetworkCredential($global:FTP_USER, $global:FTP_PASS)
        $req.UsePassive  = $true
        $req.UseBinary   = $true
        $req.EnableSsl   = $global:FTP_USA_SSL
        $req.Timeout     = 15000

        if ($global:FTP_USA_SSL) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }

        $resp   = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $lista  = @()
        while (-not $reader.EndOfStream) {
            $linea = $reader.ReadLine().Trim()
            if ($linea) { $lista += (Split-Path $linea -Leaf) }
        }
        $reader.Close(); $resp.Close()
        return $lista
    } catch { return @() }
}

# ============================================================
# FTP-PROBAR-CONEXION
# ============================================================
function FTP-Probar-Conexion {
    param([bool]$UsarSSL = $false)
    $url = "ftp://" + $global:FTP_IP + "/"
    try {
        $req = [System.Net.FtpWebRequest][System.Net.WebRequest]::Create($url)
        $req.Method      = [System.Net.WebRequestMethods+Ftp]::ListDirectory
        $req.Credentials = New-Object System.Net.NetworkCredential($global:FTP_USER, $global:FTP_PASS)
        $req.UsePassive  = $true
        $req.EnableSsl   = $UsarSSL
        $req.Timeout     = 8000
        if ($UsarSSL) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
        $resp = $req.GetResponse(); $resp.Close()
        return $true
    } catch { return $false }
}

# ============================================================
# FTP-VERIFICAR-HASH
# ============================================================
function FTP-Verificar-Hash {
    param([string]$ArchivoLocal, [string]$RutaHashRemota)
    $archivoHash = $ArchivoLocal + ".sha256"
    $urlHash     = "ftp://" + $global:FTP_IP + "/" + $RutaHashRemota
    
    Write-Host "  [*] Descargando checksum SHA256..." -ForegroundColor Cyan
    $ok = Descarga-Rapida -Url $urlHash -Destino $archivoHash -Usuario $global:FTP_USER -Password $global:FTP_PASS
    
    if (-not $ok -or -not (Test-Path $archivoHash)) {
        if (Test-Path $archivoHash) { Remove-Item $archivoHash -Force }
        return 2
    }
    
    $contenido  = (Get-Content $archivoHash -Raw -Encoding ASCII).Trim()
    $hashRemoto = ($contenido -split '\s+')[0].ToLower()
    Remove-Item $archivoHash -Force -ErrorAction SilentlyContinue
    
    if ($hashRemoto.Length -ne 64) { return 1 }
    
    Write-Host "  [*] Calculando y verificando integridad SHA256 local..." -ForegroundColor Cyan
    $hashLocal = (Get-FileHash $ArchivoLocal -Algorithm SHA256).Hash.ToLower()
    
    if ($hashLocal -eq $hashRemoto) {
        Write-Host "  [OK] SHA256 PASSED: $hashRemoto" -ForegroundColor Green
        return 0
    }
    
    Write-Host "  [CRÍTICO] SHA256 FAILED. Archivo corrupto detectado." -ForegroundColor Red
    Remove-Item $ArchivoLocal -Force -ErrorAction SilentlyContinue
    return 1
}

# ============================================================
# FTP-OBTENER-INSTALADOR-AUTOMATIZADO
# ============================================================
function FTP-Obtener-Instalador-Automatizado {
    param(
        [Parameter(Mandatory=$true)][string]$IP,
        [Parameter(Mandatory=$true)][string]$Usuario,
        [Parameter(Mandatory=$true)][string]$Password,
        [Parameter(Mandatory=$true)][string]$Motor,
        [Parameter(Mandatory=$true)][string]$OS
    )

    $global:FTP_IP = $IP
    $global:FTP_USER = $Usuario
    $global:FTP_PASS = $Password
    $global:FTP_USA_SSL = $false

    Write-Host "  [*] Negociando conexion con ftp://$IP..." -ForegroundColor Cyan
    if (-not (FTP-Probar-Conexion -UsarSSL $false)) {
        Write-Host "  [*] Conexion plana rechazada. Intentando tunel seguro (FTPS)..." -ForegroundColor Yellow
        $global:FTP_USA_SSL = $true
        if (-not (FTP-Probar-Conexion -UsarSSL $true)) {
            Write-Host "  [ERROR] Imposible conectar al FTP. Verifique credenciales o firewall." -ForegroundColor Red
            return $null
        }
    }

    $carpetaMotor = switch ($Motor.ToLower()) {
        "iis"    { "IIS" }
        "apache" { "Apache" }
        "nginx"  { "Nginx" }
        "tomcat" { "Tomcat" }
        default  { $Motor }
    }
    
    $rutaRemota = $carpetaMotor
    Write-Host "  [*] Explorando directorio remoto: /$rutaRemota/" -ForegroundColor Cyan

    $archivosRemotos = @(FTP-Listar-Directorio $rutaRemota)
    if ($archivosRemotos.Count -eq 0) {
        Write-Host "  [ERROR] El directorio /$rutaRemota/ esta vacio o inaccesible." -ForegroundColor Red
        return $null
    }

    $instalador = $archivosRemotos | Where-Object { $_ -notmatch '\.sha256$' -and $_ -match '\.(msi|zip|nupkg|exe|deb|tar\.gz|cmd)$' } | Select-Object -First 1
    $hashFile   = if ($instalador) { $archivosRemotos | Where-Object { $_ -match "$([regex]::Escape($instalador))\.sha256$" } | Select-Object -First 1 } else { $null }

    if (-not $instalador) {
        Write-Host "  [ERROR] No se encontro ningun binario instalable en la carpeta." -ForegroundColor Red
        return $null
    }

    $guid = [guid]::NewGuid().ToString().Substring(0,8)
    $tempDir = Join-Path $env:TEMP "P7_FTP_$guid"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    
    $rutaLocalInstalador = Join-Path $tempDir $instalador

    $urlInstalador = "ftp://$IP/$rutaRemota/$instalador"
    Write-Host "  [*] Descargando binario: $instalador" -ForegroundColor Cyan
    $okDescarga = Descarga-Rapida -Url $urlInstalador -Destino $rutaLocalInstalador -Usuario $Usuario -Password $Password
    
    if (-not $okDescarga) { return $null }

    if ($hashFile) {
        $rutaRemotaHash = "$rutaRemota/$hashFile"
        $validacion = FTP-Verificar-Hash -ArchivoLocal $rutaLocalInstalador -RutaHashRemota $rutaRemotaHash
        
        if ($validacion -eq 1) { return $null }
    }

    return $rutaLocalInstalador
}

# ============================================================
# FUNCIONES DE PREPARACION DE SERVIDOR FTP
# ============================================================
function FTP-Asegurar-Junction {
    param([string]$NombreUsuario)
    $carpetaUser  = "C:\FTP_Root\LocalUser\$NombreUsuario"
    $destJunction = $global:REPO_FTP_DIR

    if (-not (Test-Path $destJunction)) { New-Item -ItemType Directory -Path $destJunction -Force | Out-Null }

    if (Test-Path $carpetaUser) {
        $item = Get-Item $carpetaUser -Force -ErrorAction SilentlyContinue
        if (($item.LinkType -eq "Junction") -and ($item.Target -match "FTP_Master")) { return $true }
        Remove-Item $carpetaUser -Recurse -Force -ErrorAction SilentlyContinue
    }

    cmd /c "mklink /J `"$carpetaUser`" `"$destJunction`"" 2>&1 | Out-Null
    return (Test-Path $carpetaUser)
}

function FTP-Mostrar-Arbol-Repositorio {
    $base = $global:REPO_FTP_DIR
    if (-not (Test-Path $base)) { Write-Host "  (directorio no existe aun)" -ForegroundColor DarkGray; return }
    Write-Host "`n  $base\" -ForegroundColor Cyan
    foreach ($carpeta in @("Apache","Nginx","IIS")) {
        $ruta = Join-Path $base $carpeta
        Write-Host "  +-- $carpeta\" -ForegroundColor Yellow
        if (-not (Test-Path $ruta)) { Write-Host "  |   (vacia)" -ForegroundColor DarkGray; continue }
        $archivos = @(Get-ChildItem $ruta -File -ErrorAction SilentlyContinue)
        if ($archivos.Count -eq 0) { Write-Host "  |   (vacia)" -ForegroundColor DarkGray; continue }
        foreach ($arch in $archivos) {
            $kb    = [math]::Round($arch.Length / 1KB, 1)
            $esha  = $arch.Name -match '\.sha256$'
            $color = if ($esha) { "DarkCyan" } else { "White" }
            $tag   = if ($esha) { "[SHA256]" } else {
                if (Test-Path ($arch.FullName + ".sha256")) { "[$kb KB] [hash OK]" } else { "[$kb KB] [sin hash]" }
            }
            Write-Host "  |   +-- $($arch.Name)  $tag" -ForegroundColor $color
        }
    }
    Write-Host ""
}

function FTP-Mostrar-Permisos-NTFS {
    param([string]$Ruta = $global:REPO_FTP_DIR)
    if (-not (Test-Path $Ruta)) { return }
    Write-Host "`n  Permisos NTFS: $Ruta" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 60))
    try {
        $acl = Get-Acl $Ruta
        foreach ($r in $acl.Access) {
            $color = if ($r.AccessControlType -eq "Allow") { "Green" } else { "Red" }
            Write-Host ("  {0,-35} {1,-20} {2}" -f $r.IdentityReference, $r.FileSystemRights, $r.AccessControlType) -ForegroundColor $color
        }
    } catch { }
    Write-Host ""
}

function FTP-Preparar-Repositorio {
    Clear-Host
    Write-Host "--- PREPARAR REPOSITORIO FTP (WINDOWS) ---" -ForegroundColor Yellow
    Write-Host "  Base: $($global:REPO_FTP_DIR)\" -ForegroundColor Cyan

    Write-Host "`n  [1/3] Creando estructura..." -ForegroundColor Cyan
    foreach ($dir in @("C:\FTP_Master\http\Linux\Apache", "C:\FTP_Master\http\Linux\Nginx", "C:\FTP_Master\http\Linux\Tomcat", "C:\FTP_Master\http\Windows\IIS", "C:\FTP_Master\http\Windows\Apache", "C:\FTP_Master\http\Windows\Nginx")) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
    Write-Host "  [OK] Estructura creada." -ForegroundColor Green

    Write-Host "`n  [2/3] Descargando binarios..." -ForegroundColor Cyan
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { Write-Host "  [!] Chocolatey no disponible." -ForegroundColor Red; return }

    Write-Host "  -> Descargando dependencias (vcredist140)..." -ForegroundColor Blue
    $vcVerRaw = choco search vcredist140 --exact --all --limit-output 2>$null | Select-Object -First 1
    if ($vcVerRaw) {
        $vcVer = ($vcVerRaw -split '\|')[1].Trim()
        $vcDest = "C:\FTP_Master\http\Windows\Apache\vcredist140.$vcVer.nupkg"
        if (-not (Test-Path $vcDest)) { Descarga-Rapida -Url "https://community.chocolatey.org/api/v2/package/vcredist140/$vcVer" -Destino $vcDest | Out-Null }
    }

    foreach ($motor in @("apache","nginx")) {
        $carpeta = if ($motor -eq "apache") { "Apache" } else { "Nginx" }
        $paquete = if ($motor -eq "apache") { "apache-httpd" } else { "nginx" }
        $dirDest = "C:\FTP_Master\http\Windows\$carpeta"
        Write-Host "  -> $carpeta..." -ForegroundColor Blue

        $verRaw = choco search $paquete --exact --all --limit-output 2>$null | Select-Object -First 1
        if (-not $verRaw) { continue }
        $ver = ($verRaw -split '\|')[1].Trim()

        $nupkgNombre = "$paquete.$ver.nupkg"
        $nupkgDest   = Join-Path $dirDest $nupkgNombre
        $hashDest    = "$nupkgDest.sha256"

        if ((Test-Path $nupkgDest) -and (Test-Path $hashDest)) { Write-Host "  [OK] $carpeta ya existe." -ForegroundColor DarkGray; continue }

        $ok = Descarga-Rapida -Url "https://community.chocolatey.org/api/v2/package/$paquete/$ver" -Destino $nupkgDest

        if ($ok) {
            if ($motor -eq "apache") {
                Write-Host "  [*] Aplicando parche de port-check 8080 para offline..." -ForegroundColor Cyan
                $tmpDir = Join-Path $env:TEMP "apache-ftp-patch"
                $extDir = Join-Path $tmpDir "extracted"
                New-Item -ItemType Directory -Path $extDir -Force | Out-Null 
                
                $zipTmp = $nupkgDest -replace '\.nupkg$', '.zip'
                Copy-Item -Path $nupkgDest -Destination $zipTmp -Force
                Expand-Archive -Path $zipTmp -DestinationPath $extDir -Force
                Remove-Item -Path $zipTmp -Force
                
                $installScript = Get-ChildItem $extDir -Recurse -Filter "chocolateyInstall.ps1" | Select-Object -First 1
                if ($installScript) {
                    $scriptContent = Get-Content $installScript.FullName -Raw -Encoding UTF8
                    $patched = $scriptContent -replace '(?m)^(\s*)(throw\s+[''"]Please specify a different port number\.\.\.[''"])', '$1# [PATCHED]'
                    $patched = $patched -replace '(?m)if\s*\(\s*-not\s*\(\s*Assert-TcpPortIsOpen[^\)]+\)\s*\)', 'if ($false)'
                    [System.IO.File]::WriteAllText($installScript.FullName, $patched, [System.Text.UTF8Encoding]::new($false))
                    
                    Remove-Item $nupkgDest -Force
                    Compress-Archive -Path "$extDir\*" -DestinationPath $zipTmp -Force
                    Move-Item -Path $zipTmp -Destination $nupkgDest -Force
                }
                Remove-Item $tmpDir -Recurse -Force
            }

            $hash = (Get-FileHash $nupkgDest -Algorithm SHA256).Hash.ToLower()
            "$hash  $nupkgNombre" | Out-File $hashDest -Encoding ASCII -Force
        }
    }

    $iisInfo = "C:\FTP_Master\http\Windows\IIS\iis_info.txt"
    if (-not (Test-Path $iisInfo)) { "IIS: Install-WindowsFeature Web-Server" | Out-File $iisInfo -Encoding ASCII }

    Write-Host "  [3/3] Corrigiendo junctions usuarios P7..." -ForegroundColor Cyan
    $usuariosP7 = @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Description -eq $global:REPO_FTP_DESC })
    if ($usuariosP7) { foreach ($u in $usuariosP7) { FTP-Asegurar-Junction $u.Name | Out-Null } }

    try {
        $acl  = Get-Acl $global:REPO_FTP_DIR
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new("IIS_IUSRS","ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow"))
        Set-Acl $global:REPO_FTP_DIR $acl -ErrorAction SilentlyContinue
    } catch { }

    FTP-Mostrar-Arbol-Repositorio
    Write-Host "[OK] Repositorio FTP listo." -ForegroundColor Green
    Pausa
}