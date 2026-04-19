# =============================================================================
# http_funciones.ps1 - Motor de Despliegue HTTP No-Interactivo
# =============================================================================

# =============================================================================
# FIX: RESOLVER RUTA DE CURL.EXE
# En PowerShell, "curl" es alias de Invoke-WebRequest. Necesitamos curl.exe
# nativo de Windows (C:\Windows\System32\curl.exe), disponible desde WS2019+.
# =============================================================================
function Resolver-CurlExe {
    # Intentar la ruta nativa de Windows primero (mas rapida y segura)
    $rutaNativa = "C:\Windows\System32\curl.exe"
    if (Test-Path $rutaNativa) { return $rutaNativa }

    # Buscar en PATH como fallback
    $cmd = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Buscar en rutas de Git si lo tienen instalado
    foreach ($r in @("C:\Program Files\Git\mingw64\bin\curl.exe",
                     "C:\Program Files\Git\usr\bin\curl.exe")) {
        if (Test-Path $r) { return $r }
    }

    Write-Host "  [CRITICO] curl.exe no encontrado. Instale Windows 10/WS2019+ o Git." -ForegroundColor Red
    return $null
}

# =============================================================================
# ESCRITURA DE ARCHIVOS SIN BOM
# =============================================================================
function Escribir-Archivo {
    param([string]$Ruta, [string]$Contenido)
    try {
        $dir = Split-Path -Parent $Ruta
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Ruta, $Contenido, $enc)
    } catch {
        Escribir-Log "ERROR" "Escribir-Archivo '$Ruta': $($_.Exception.Message)"
    }
}

# =============================================================================
# LOG
# =============================================================================
function Escribir-Log {
    param([string]$Nivel, [string]$Msg)
    $ts      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linea   = "[$ts] [$Nivel] $Msg"
    $logPath = Join-Path $global:REPO_ROOT "logs\windows_services.log"

    if (Test-Path $logPath) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($logPath)
            if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
                $textoActual = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
                [System.IO.File]::WriteAllText($logPath, $textoActual, [System.Text.UTF8Encoding]::new($false))
            }
        } catch { }
    }

    $enc = [System.Text.UTF8Encoding]::new($false)
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $writer = [System.IO.StreamWriter]::new($logPath, $true, $enc)
            $writer.WriteLine($linea)
            $writer.Close()
            break
        } catch {
            if ($i -lt 2) { Start-Sleep -Milliseconds 80 }
        }
    }
}

# =============================================================================
# CHOCOLATEY
# =============================================================================
function Asegurar-Chocolatey {
    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }

    Write-Host "  [*] Chocolatey no detectado. Evaluando entorno de red..." -ForegroundColor Cyan

    $netCheck = Test-NetConnection community.chocolatey.org -Port 443 -WarningAction SilentlyContinue
    if (-not $netCheck.TcpTestSucceeded) {
        Write-Host "  [CRITICO] Entorno aislado sin internet. Imposible instalar Chocolatey en caliente." -ForegroundColor Red
        Escribir-Log "ERROR" "Intento de instalar Chocolatey fallido por falta de acceso a internet."
        return $false
    }

    Write-Host "  [*] Descargando e instalando motor Chocolatey..." -ForegroundColor Cyan
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $job = Start-Job -ScriptBlock {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) 2>&1
    }

    while ($job.State -eq 'Running') { Start-Sleep -Milliseconds 400 }
    Receive-Job $job | Out-Null; Remove-Job $job

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "  [OK] Gestor de paquetes listo." -ForegroundColor Green
        return $true
    }
    Write-Host "  [ERROR] Fallo la orquestacion del gestor de paquetes." -ForegroundColor Red
    return $false
}

# =============================================================================
# DETECCION DINAMICA DE RUTAS
# =============================================================================
function Obtener-RutaApache {
    $appData = [System.Environment]::GetFolderPath("ApplicationData")
    foreach ($r in @("C:\Apache24", "$appData\Apache24", "C:\tools\Apache24", "C:\Program Files\Apache24", "$env:APPDATA\Apache24")) {
        if (Test-Path "$r\bin\httpd.exe") { return $r }
    }
    $f = Get-ChildItem "C:\ProgramData\chocolatey\lib\apache-httpd" -Recurse -Filter "httpd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { return Split-Path (Split-Path $f.DirectoryName) }
    return $null
}

function Obtener-RutaNginx {
    foreach ($r in @("C:\tools\nginx", "C:\nginx")) {
        if (Test-Path "$r\nginx.exe") { return $r }
    }
    foreach ($base in @("C:\tools", "C:\ProgramData\chocolatey\lib\nginx")) {
        if (-not (Test-Path $base)) { continue }
        $f = Get-ChildItem $base -Recurse -Filter "nginx.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.DirectoryName }
    }
    return $null
}

function Obtener-SvcApache {
    foreach ($n in @("Apache2.4","Apache2.2","apache","httpd","ApacheHTTPServer")) {
        if (Get-Service $n -ErrorAction SilentlyContinue) { return $n }
    }
    $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match "Apache" } | Select-Object -First 1
    if ($svc) { return $svc.Name }
    return $null
}

# =============================================================================
# CAPTURAR ENTERO (Fallback de seguridad interna)
# =============================================================================
if (-not (Get-Command Capturar-Entero -ErrorAction SilentlyContinue)) {
    function Capturar-Entero {
        param([string]$Mensaje)
        while ($true) {
            Write-Host "  $Mensaje : " -NoNewline -ForegroundColor Cyan
            $raw = Read-Host
            $n   = 0
            if ([int]::TryParse($raw.Trim(), [ref]$n) -and $n -gt 0 -and $n -le 65535) { return $n }
            Write-Host "  [!] Invalido." -ForegroundColor Red
        }
    }
}

# =============================================================================
# DETECTAR PUERTO ACTUAL
# =============================================================================
function Detectar-PuertoActual {
    param([string]$Motor)
    switch ($Motor) {
        "iis" {
            $w3 = Get-Process w3wp -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($w3) {
                $conn = Get-NetTCPConnection -OwningProcess $w3.Id -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($conn) { return $conn.LocalPort }
            }
        }
        "apache" {
            $proc = Get-Process httpd -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc) {
                $conn = Get-NetTCPConnection -OwningProcess $proc.Id -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($conn) { return $conn.LocalPort }
            }
            $d = Obtener-RutaApache
            if ($d -and (Test-Path "$d\conf\httpd.conf")) {
                $linea = Select-String -Path "$d\conf\httpd.conf" -Pattern '^\s*Listen\s+(\d+)' | Select-Object -First 1
                $p = 0
                if ($linea -and [int]::TryParse($linea.Matches[0].Groups[1].Value,[ref]$p)) { return $p }
            }
        }
        "nginx" {
            $proc = Get-Process nginx -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc) {
                $conn = Get-NetTCPConnection -OwningProcess $proc.Id -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($conn) { return $conn.LocalPort }
            }
        }
    }
    return 0
}

# =============================================================================
# LIBERAR PUERTO ANTERIOR
# =============================================================================
function Liberar-PuertoAnterior {
    param([string]$Motor, [int]$Puerto)
    Write-Host "  [*] Purgando dependencias previas del motor $Motor..." -ForegroundColor DarkGray

    switch ($Motor) {
        "iis" {
            Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 400
        }
        "apache" {
            $svc = Obtener-SvcApache
            if ($svc) { Stop-Service $svc -NoWait -ErrorAction SilentlyContinue }
            $d = Obtener-RutaApache
            if ($d -and (Test-Path "$d\bin\httpd.exe")) {
                & "$d\bin\httpd.exe" -k uninstall 2>&1 | Out-Null
            }
            Get-Process httpd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        "nginx" {
            $d = Obtener-RutaNginx
            if ($d -and (Test-Path "$d\nginx.exe")) {
                & "$d\nginx.exe" -p $d -s stop 2>&1 | Out-Null
            }
            Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    if ($Puerto -gt 0) {
        Get-NetTCPConnection -LocalPort $Puerto -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -gt 4 } | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    }
}

# =============================================================================
# FIX: OBTENER MOTORES INSTALADOS
# Cuando Get-WindowsFeature falla (error 0x80070003), usa deteccion por servicio.
# =============================================================================
function Obtener-MotoresInstalados {
    $resultado = @()

    # IIS: intentar Get-WindowsFeature, si falla verificar servicio W3SVC
    $iisInstalado = $false
    try {
        $iis = Get-WindowsFeature -Name "Web-Server" -ErrorAction Stop
        $iisInstalado = $iis.Installed
    } catch {
        # Fallback: verificar si el servicio W3SVC existe
        $iisInstalado = ($null -ne (Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue))
    }
    if ($iisInstalado) { $resultado += "iis" }

    if ($null -ne (Obtener-RutaApache)) { $resultado += "apache" }
    if ($null -ne (Obtener-RutaNginx))  { $resultado += "nginx"  }
    return $resultado
}

# =============================================================================
# FIX: OBTENER INFO SERVIDOR
# Fallback a deteccion por servicio cuando Get-WindowsFeature no responde.
# =============================================================================
function Obtener-InfoServidor {
    param([string]$Motor)
    $version = "N/D"; $puerto = 0; $estado = "No instalado"; $url = "-"

    switch ($Motor) {
        "iis" {
            # FIX: Intentar Get-WindowsFeature, si falla usar Get-Service como fallback
            $instalado = $false
            try {
                $feat = Get-WindowsFeature -Name "Web-Server" -ErrorAction Stop
                $instalado = $feat.Installed
            } catch {
                $svc = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
                $instalado = ($null -ne $svc)
            }
            if (-not $instalado) { return $null }

            $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue
            if ($reg -and $reg.MajorVersion) { $version = "$($reg.MajorVersion).$($reg.MinorVersion)" }
            $svcObj = Get-Service W3SVC -ErrorAction SilentlyContinue
            $estado = if ($svcObj -and $svcObj.Status -eq "Running") { "Corriendo" } else { "Detenido" }
            $puerto = Detectar-PuertoActual -Motor "iis"
        }
        "apache" {
            $d = Obtener-RutaApache
            if (-not $d) { return $null }
            try {
                $vraw = & "$d\bin\httpd.exe" -v 2>&1 | Select-Object -First 1
                if ($vraw -match "Apache/([\d\.]+)") { $version = $Matches[1] }
            } catch { $version = "Apache" }
            $estado = if (Get-Process httpd -ErrorAction SilentlyContinue) { "Corriendo" } else { "Detenido" }
            $puerto = Detectar-PuertoActual -Motor "apache"
        }
        "nginx" {
            $d = Obtener-RutaNginx
            if (-not $d) { return $null }
            try {
                $vraw = & "$d\nginx.exe" -v 2>&1 | Select-Object -First 1
                if (($vraw -join '') -match "nginx/([\d\.]+)") { $version = $Matches[1] }
            } catch { $version = "nginx" }
            $estado = if (Get-Process nginx -ErrorAction SilentlyContinue) { "Corriendo" } else { "Detenido" }
            $puerto = Detectar-PuertoActual -Motor "nginx"
        }
    }
    return [PSCustomObject]@{ Motor = $Motor; Version = $version; Puerto = $puerto; Estado = $estado; URL = if($puerto -gt 0){"http://localhost:$puerto"}else{"-"} }
}

# =============================================================================
# ACTUALIZAR PUERTO EN HTML
# =============================================================================
function Actualizar-PuertoEnHTML {
    param([string]$Motor, [int]$PuertoNuevo)
    $rutaHtml = switch ($Motor) {
        "iis"    { "C:\inetpub\wwwroot\index.html" }
        "apache" { $d = Obtener-RutaApache; if ($d) { Join-Path $d "htdocs\index.html" } }
        "nginx"  { $d = Obtener-RutaNginx;  if ($d) { Join-Path $d "html\index.html"   } }
    }
    if (-not $rutaHtml -or -not (Test-Path $rutaHtml)) {
        $info = Obtener-InfoServidor -Motor $Motor
        Desplegar-PlantillaHTML -Motor $Motor -Version (if($info){$info.Version}else{"N/D"}) -Puerto $PuertoNuevo
        return
    }
    try {
        $html = [System.IO.File]::ReadAllText($rutaHtml, [System.Text.Encoding]::UTF8)
        if ($html -match '<span\s+id="puerto-display">[^<]*</span>') {
            $html = $html -replace '(<span\s+id="puerto-display">)[^<]*(</span>)', "`$1$PuertoNuevo`$2"
            Escribir-Archivo $rutaHtml $html
        } else {
            $info = Obtener-InfoServidor -Motor $Motor
            Desplegar-PlantillaHTML -Motor $Motor -Version (if($info){$info.Version}else{"N/D"}) -Puerto $PuertoNuevo
        }
    } catch { }
}

# =============================================================================
# DESINSTALAR SERVIDOR COMPLETO
# =============================================================================
function Desinstalar-ServidorCompleto {
    param([string]$Motor)
    $errores = 0
    try {
        Liberar-PuertoAnterior -Motor $Motor -Puerto 0

        switch ($Motor) {
            "iis" {
                try { Uninstall-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction Stop | Out-Null }
                catch { & dism /online /disable-feature /featurename:IIS-WebServerRole /norestart 2>&1 | Out-Null }
                if (Test-Path "C:\inetpub\wwwroot") { Remove-Item "C:\inetpub\wwwroot\*" -Recurse -Force -ErrorAction SilentlyContinue }
            }
            "apache" {
                & choco uninstall apache-httpd -y --no-progress 2>&1 | Out-Null
                $d = Obtener-RutaApache
                if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
                Get-ChildItem "C:\ProgramData\chocolatey\lib*" -Filter "apache-httpd" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                foreach ($sn in @("Apache","Apache2.4","httpd")) { Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\$sn" -Recurse -Force -ErrorAction SilentlyContinue }
            }
            "nginx" {
                & choco uninstall nginx -y --no-progress 2>&1 | Out-Null
                Get-ChildItem "C:\tools" -Filter "nginx*" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                Get-ChildItem "C:\ProgramData\chocolatey\lib*" -Filter "nginx" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\nginx" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match "^HTTP-$Motor-" } | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    } catch { $errores++ }
    return ($errores -eq 0)
}

# =============================================================================
# VERSIONES DINAMICAS
# =============================================================================
function Extraer-VersionesDinamicas {
    param([string]$Motor)
    if ($Motor -eq "iis") {
        $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue
        $ver = if ($reg -and $reg.MajorVersion) { "$($reg.MajorVersion).$($reg.MinorVersion)" } else { "10.0" }
        return @("$ver (LTS - Nativo)")
    }
    if (-not (Asegurar-Chocolatey)) { return @() }

    $paquete = if ($Motor -eq "apache") { "apache-httpd" } else { "nginx" }
    $raw = choco search $paquete --exact --all 2>$null
    $versiones = @($raw | Select-String "^$paquete\s+([\d\.]+)" | ForEach-Object { $_.Matches.Groups[1].Value } | Sort-Object -Descending { [version]($_ -join '.') })

    if ($versiones.Count -eq 0) { return @() }
    return @("$($versiones[0]) (Latest)")
}

# =============================================================================
# VALIDACION DE PUERTO ESTRICTA
# =============================================================================
function Validar-PuertoTCP {
    param([int]$Puerto, [string]$Motor = "")
    if ($Puerto -in @(135, 139, 445, 3389, 5985, 5986, 21, 22, 25, 53, 67, 68)) { return 2 }

    $conns = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) { return 0 }

    $procesoPermitido = switch ($Motor) { "iis" { "w3wp" } "apache" { "httpd" } "nginx" { "nginx" } default { "" } }
    $externo = $conns | Where-Object {
        try {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            $proc -and ($proc.ProcessName -ne $procesoPermitido)
        } catch { $true }
    }
    if ($externo) { return 1 } else { return 0 }
}

# =============================================================================
# INSTALACION DE PAQUETES (El Core de la Inyección)
# =============================================================================
function Instalar-PaquetesWeb {
    param([string]$Motor, [string]$Version, [int]$Puerto = 80)
    $ProgressPreference = 'SilentlyContinue'

    if ($Motor -eq "iis") {
        Write-Host "  [*] Instalando IIS..." -ForegroundColor Cyan
        try { Install-WindowsFeature -Name Web-Server,Web-Mgmt-Tools -IncludeManagementTools -ErrorAction Stop | Out-Null; return $true }
        catch { return $false }
    }

    if (-not (Asegurar-Chocolatey)) { return $false }
    $paquete = if ($Motor -eq "apache") { "apache-httpd" } else { "nginx" }
    
    Liberar-PuertoAnterior -Motor $Motor -Puerto 0

    if ($Motor -eq "apache") {
        Write-Host "  [*] Instalando dependencias visuales (VC++)..." -ForegroundColor DarkGray
        & choco install vcredist140 -y --no-progress 2>&1 | Out-Null
        
        $tmpDir = Join-Path $env:TEMP "apache-nupkg-patch"
        $srcDir = Join-Path $tmpDir "source"; $extDir = Join-Path $tmpDir "extracted"
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
        New-Item -ItemType Directory -Path $extDir -Force | Out-Null
        
        $nupkgDst = Join-Path $srcDir "$paquete.$Version.nupkg"
        Write-Host "  [*] Generando parche dinamico de puertos para $Motor..." -ForegroundColor Cyan
        
        try {
            $curlArgs = @("-L", "-s", "-o", $nupkgDst, "https://community.chocolatey.org/api/v2/package/$paquete/$Version")
            $proc = Start-Process -FilePath "curl.exe" -ArgumentList $curlArgs -WindowStyle Hidden -PassThru
            $proc.WaitForExit()
            
            if ($proc.ExitCode -ne 0 -or -not (Test-Path $nupkgDst)) { throw "Fallo la descarga." }

            $zipTmp = $nupkgDst -replace '\.nupkg$', '.zip'
            Copy-Item -Path $nupkgDst -Destination $zipTmp -Force
            Expand-Archive -Path $zipTmp -DestinationPath $extDir -Force -ErrorAction Stop
            Remove-Item $zipTmp -Force

            $installScript = Get-ChildItem $extDir -Recurse -Filter "chocolateyInstall.ps1" | Select-Object -First 1
            if ($installScript) {
                $scriptContent = Get-Content $installScript.FullName -Raw -Encoding UTF8
                $patched = $scriptContent -replace '(?m)^(\s*)(throw\s+[''"]Please specify a different port number\.\.\.[''"])', '$1# [PATCHED]'
                $patched = $patched -replace '(?m)if\s*\(\s*-not\s*\(\s*Assert-TcpPortIsOpen[^\)]+\)\s*\)', 'if ($false)'
                [System.IO.File]::WriteAllText($installScript.FullName, $patched, [System.Text.UTF8Encoding]::new($false))
                
                Remove-Item $nupkgDst -Force
                Compress-Archive -Path "$extDir\*" -DestinationPath "$nupkgDst.zip" -Force
                Move-Item -Path "$nupkgDst.zip" -Destination $nupkgDst -Force
            }
            & choco install $paquete --version $Version -y --no-progress --source $srcDir 2>&1 | Out-Null
        } catch { return $false } finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    } else {
        Write-Host "  [*] Instalando Nginx..." -ForegroundColor Cyan
        & choco install $paquete --version $Version -y --no-progress 2>&1 | Out-Null
    }

    Write-Host "  [*] Extrayendo y verificando binarios..." -ForegroundColor Cyan
    Start-Sleep -Seconds 5

    if ($Motor -eq "apache") {
        $exeRuta = (Obtener-RutaApache) + "\bin\httpd.exe"
        if (Test-Path $exeRuta) {
            & $exeRuta -k install 2>&1 | Out-Null
            # Eliminamos el sc.exe que forzaba NetworkService para evitar el crash de logs.
            Start-Service Apache2.4 -ErrorAction SilentlyContinue
        }
    }
    return $true
}

# =============================================================================
# CONFIGURACION DE PUERTO (Fix: Arranque Forzado PS 5.1)
# =============================================================================
function Configurar-PuertoServicio {
    param([string]$Motor, [int]$Puerto)
    try {
        if ($Motor -eq "iis") {
            Import-Module WebAdministration
            Set-ItemProperty "IIS:\Sites\Default Web Site" -Name Bindings -Value @(@{ protocol="http"; bindingInformation="*:${Puerto}:" })
            Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
            Start-Service W3SVC -ErrorAction SilentlyContinue
        } elseif ($Motor -eq "apache") {
            $dir = Obtener-RutaApache
            $confPath = Join-Path $dir "conf\httpd.conf"
            $dirUnix = $dir -replace "\\", "/"
            
            $conf = Get-Content $confPath -Raw
            $conf = $conf -replace '(?m)^ServerRoot\s+"[^"]+"', "ServerRoot `"$dirUnix`""
            $conf = $conf -replace '(?m)^DocumentRoot\s+"[^"]+"', "DocumentRoot `"$dirUnix/htdocs`""
            $conf = $conf -replace '(?m)^<Directory\s+"[^"]+/htdocs">', "<Directory `"$dirUnix/htdocs`">"
            $conf = $conf -replace '(?m)^Listen \d+', "Listen $Puerto"
            [System.IO.File]::WriteAllText($confPath, $conf, [System.Text.ASCIIEncoding]::new())
            
            $svc = Obtener-SvcApache
            Stop-Service $svc -Force -ErrorAction SilentlyContinue
            Start-Service $svc -ErrorAction SilentlyContinue
        } elseif ($Motor -eq "nginx") {
            $dir = Obtener-RutaNginx
            $confPath = Join-Path $dir "conf\nginx.conf"
            $nuevoConf = @"
worker_processes  1;
events { worker_connections  1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    server_tokens off;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    server {
        listen       $Puerto;
        server_name  localhost;
        root         html;
        index        index.html index.htm;
    }
}
"@
            Escribir-Archivo $confPath $nuevoConf
            Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Process "$dir\nginx.exe" -ArgumentList "-p `"$dir`"" -WorkingDirectory $dir -WindowStyle Hidden
        }
        
        Remove-NetFirewallRule -DisplayName "HTTP-$Motor-$Puerto" -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "HTTP-$Motor-$Puerto" -Direction Inbound -LocalPort $Puerto -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
        return $true
    } catch { return $false }
}

# =============================================================================
# HARDENING DE SEGURIDAD
# =============================================================================
function Aplicar-HardeningSeguridad {
    param([string]$Motor)
    Write-Host "  [*] Inyectando politicas de seguridad y preparacion SSL..." -ForegroundColor DarkGray

    if ($Motor -eq "iis") {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering" -name "removeServerHeader" -value "true" -ErrorAction SilentlyContinue
    } elseif ($Motor -eq "apache") {
        $dir = Obtener-RutaApache
        $confPath = Join-Path $dir "conf\httpd.conf"
        if (-not (Test-Path $confPath)) { return }

        $contenido = Get-Content $confPath -Raw
        $contenido = $contenido -replace '(?m)^#\s*(LoadModule headers_module.*)', '$1'
        $contenido = $contenido -replace '(?m)^#\s*(LoadModule rewrite_module.*)', '$1'
        $contenido = $contenido -replace '(?m)^#\s*(LoadModule ssl_module.*)', '$1'
        $contenido = $contenido -replace '(?m)^#\s*(LoadModule socache_shmcb_module.*)', '$1'

        if ($contenido -notmatch "ServerTokens Prod") {
            $contenido += "`nServerTokens Prod`nServerSignature Off`nTraceEnable Off`nHeader always set X-Frame-Options SAMEORIGIN`nHeader always set X-Content-Type-Options nosniff"
        }
        [System.IO.File]::WriteAllText($confPath, $contenido, [System.Text.ASCIIEncoding]::new())
        Restart-Service (Obtener-SvcApache) -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# AISLAMIENTO NTFS
# =============================================================================
function Aislar-DirectorioWeb {
    param([string]$Motor)
    $ruta = switch ($Motor) {
        "iis"    { "C:\inetpub\wwwroot" }
        "apache" { $d = Obtener-RutaApache; if ($d) { Join-Path $d "htdocs" } }
        "nginx"  { $d = Obtener-RutaNginx;  if ($d) { Join-Path $d "html"   } }
    }
    if (-not $ruta -or -not (Test-Path $ruta)) { return }

    try {
        $acl = Get-Acl $ruta
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))
        }
        if ($Motor -eq "iis") {
            foreach ($sid in @('S-1-5-32-568','S-1-5-17')) {
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"))
            }
        } elseif ($Motor -eq "apache") {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new('S-1-5-20', "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"))
        }
        Set-Acl -Path $ruta -AclObject $acl
    } catch { }
}

# =============================================================================
# PLANTILLA HTML
# =============================================================================
function Desplegar-PlantillaHTML {
    param([string]$Motor, [string]$Version, [int]$Puerto)
    $rutaHtml = switch ($Motor) {
        "iis"    { "C:\inetpub\wwwroot\index.html" }
        "apache" { $d = Obtener-RutaApache; if ($d) { Join-Path $d "htdocs\index.html" } }
        "nginx"  { $d = Obtener-RutaNginx;  if ($d) { Join-Path $d "html\index.html"   } }
    }
    if (-not $rutaHtml) { return }
    $dir = Split-Path -Parent $rutaHtml
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }

    $fallback = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8"><title>$($Motor.ToUpper()) - Servidor HTTP</title>
  <style>body{font-family:sans-serif;background:#1a1a2e;color:#eee;text-align:center;padding:50px}</style>
</head>
<body>
  <h1>$($Motor.ToUpper())</h1>
  <p>Version: $Version | Puerto: <span id="puerto-display">$Puerto</span></p>
</body></html>
"@
    Escribir-Archivo $rutaHtml $fallback
}



