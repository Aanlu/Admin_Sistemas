# http_funciones.ps1
# Requiere globals de menu_principal.ps1:
#   $global:REPO_ROOT  $global:LOG_FILE  $global:TEMPLATE_WIN
#
# Contrato con 06_http.ps1:
#   Todas las funciones publicas retornan $true/$false o un valor concreto.
#   Nunca lanzan excepciones al caller: el catch interno loguea y retorna $false.
#
# CORRECCIONES v2 (respecto al log de errores):
#   FIX-1  Extraer-VersionesDinamicas  : IIS devuelvia "Version 10.0 (Build...)"
#           -> split(" ")[0] daba "Version" como version. Ahora extrae solo numeric.
#   FIX-2  Configurar-PuertoServicio   : nginx -t escribe a stderr; capturado con
#           2>&1 produce un array. "-notmatch" sobre array devuelve elementos filtrados
#           (truthy), no un bool -> siempre lanzaba "nginx.conf invalido" aunque OK.
#           Solucion: ($testOut -join ' ') antes de comparar.
#   FIX-3  Actualizar-PuertoEnHTML     : si la plantilla externa no tiene el span
#           id="puerto-display", el puerto nunca se actualizaba en el HTML.
#           Solucion: fallback que regenera el HTML completo con el nuevo puerto.
#   FIX-4  Desinstalar-ServidorCompleto: nginx >= 1.x instala en C:\tools\nginx-VERSION
#           (directorio versionado). El reset solo borraba C:\tools\nginx (fijo).
#           Solucion: buscar y borrar todos los directorios C:\tools\nginx* .

# =============================================================================
# ESCRITURA DE ARCHIVOS SIN BOM
# PowerShell 5.1: Set-Content -Encoding UTF8 SIEMPRE agrega BOM (EF BB BF).
# nginx y Apache no pueden parsear configs con BOM y mueren silenciosamente.
# =============================================================================
function Escribir-Archivo {
    param([string]$Ruta, [string]$Contenido)
    try {
        $dir = Split-Path -Parent $Ruta
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $enc = New-Object System.Text.UTF8Encoding $false   # $false = sin BOM
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
                [System.IO.File]::WriteAllText($logPath, $textoActual,
                    [System.Text.UTF8Encoding]::new($false))
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

    Write-Host "  [*] Chocolatey no encontrado. Instalando..." -ForegroundColor Cyan
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $job = Start-Job -ScriptBlock {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-Expression ((New-Object Net.WebClient).DownloadString(
            'https://community.chocolatey.org/install.ps1')) 2>&1
    }
    $sp = @('|','/','-','\'); $i = 0
    while ($job.State -eq 'Running') {
        Write-Host "`r  $($sp[$i % 4]) Instalando Chocolatey..." -NoNewline -ForegroundColor Cyan
        Start-Sleep -Milliseconds 250; $i++
    }
    Receive-Job $job | Out-Null; Remove-Job $job

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
    while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "`r  [OK] Chocolatey instalado.              " -ForegroundColor Green
        return $true
    }
    Write-Host "`r  [ERROR] No se pudo instalar Chocolatey." -ForegroundColor Red
    return $false
}

# =============================================================================
# DETECCION DINAMICA DE RUTAS
# =============================================================================
function Obtener-RutaApache {
    $appData = [System.Environment]::GetFolderPath("ApplicationData")
    foreach ($r in @(
        "C:\Apache24",
        "$appData\Apache24",
        "C:\tools\Apache24",
        "C:\Program Files\Apache24"
    )) {
        if (Test-Path "$r\bin\httpd.exe") { return $r }
    }
    $f = Get-ChildItem "C:\ProgramData\chocolatey\lib\apache-httpd" `
             -Recurse -Filter "httpd.exe" -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($f) { return Split-Path (Split-Path $f.DirectoryName) }
    $f2 = Get-ChildItem $appData -Recurse -Filter "httpd.exe" -ErrorAction SilentlyContinue |
          Select-Object -First 1
    if ($f2) { return Split-Path (Split-Path $f2.DirectoryName) }
    return $null
}

function Obtener-RutaNginx {
    # Rutas fijas de versiones antiguas (sin sufijo de version en el nombre)
    foreach ($r in @("C:\tools\nginx", "C:\nginx")) {
        if (Test-Path "$r\nginx.exe") { return $r }
    }
    # nginx >= 1.x extrae en C:\tools\nginx-VERSION  o  C:\ProgramData\chocolatey\lib\nginx\tools\nginx-VERSION
    # Busqueda recursiva que cubre ambos casos
    foreach ($base in @("C:\tools", "C:\ProgramData\chocolatey\lib\nginx")) {
        if (-not (Test-Path $base)) { continue }
        $f = Get-ChildItem $base -Recurse -Filter "nginx.exe" -ErrorAction SilentlyContinue |
             Select-Object -First 1
        if ($f) { return $f.DirectoryName }
    }
    return $null
}

function Obtener-SvcApache {
    foreach ($n in @("Apache2.4","Apache2.2","apache","httpd","ApacheHTTPServer")) {
        if (Get-Service $n -ErrorAction SilentlyContinue) { return $n }
    }
    $svc = Get-Service -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -match "Apache" } |
           Select-Object -First 1
    if ($svc) { return $svc.Name }
    return $null
}

# =============================================================================
# CAPTURAR ENTERO  (fallback si menu_principal.ps1 no lo define aun)
# =============================================================================
if (-not (Get-Command Capturar-Entero -ErrorAction SilentlyContinue)) {
    function Capturar-Entero {
        param([string]$Mensaje)
        while ($true) {
            Write-Host "  $Mensaje : " -NoNewline -ForegroundColor Cyan
            $raw = Read-Host
            $n   = 0
            if ([int]::TryParse($raw.Trim(), [ref]$n) -and $n -gt 0 -and $n -le 65535) {
                return $n
            }
            Write-Host "  [!] Valor invalido. Ingrese un numero entre 1 y 65535." -ForegroundColor Red
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
                $conn = Get-NetTCPConnection -OwningProcess $w3.Id -State Listen `
                            -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($conn) { return $conn.LocalPort }
            }
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $binding = Get-WebBinding -Name "Default Web Site" -ErrorAction SilentlyContinue |
                           Select-Object -First 1
                if ($binding) {
                    $partes = $binding.bindingInformation -split ":"
                    $p = 0
                    if ($partes.Count -ge 2 -and [int]::TryParse($partes[1],[ref]$p) -and $p -gt 0) {
                        return $p
                    }
                }
            } catch { }
        }

        "apache" {
            $proc = Get-Process httpd -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc) {
                $conn = Get-NetTCPConnection -OwningProcess $proc.Id -State Listen `
                            -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($conn) { return $conn.LocalPort }
            }
            $d = Obtener-RutaApache
            if ($d) {
                $conf = Join-Path $d "conf\httpd.conf"
                if (Test-Path $conf) {
                    $linea = Select-String -Path $conf -Pattern '^\s*Listen\s+(\d+)' |
                             Select-Object -First 1
                    if ($linea) {
                        $p = 0
                        if ([int]::TryParse($linea.Matches[0].Groups[1].Value,[ref]$p)) { return $p }
                    }
                }
            }
        }

        "nginx" {
            $proc = Get-Process nginx -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc) {
                $conn = Get-NetTCPConnection -OwningProcess $proc.Id -State Listen `
                            -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($conn) { return $conn.LocalPort }
            }
            $d = Obtener-RutaNginx
            if ($d) {
                $conf = Join-Path $d "conf\nginx.conf"
                if (Test-Path $conf) {
                    $linea = Select-String -Path $conf -Pattern '^\s*listen\s+(\d+)' |
                             Select-Object -First 1
                    if ($linea) {
                        $p = 0
                        if ([int]::TryParse($linea.Matches[0].Groups[1].Value,[ref]$p)) { return $p }
                    }
                }
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

    Write-Host "  [*] Liberando motor anterior ($Motor) y puerto $Puerto..." -ForegroundColor Cyan

    switch ($Motor) {
        "iis" {
            Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 600
        }
        "apache" {
            # CRITICO: Stop-Service -Force espera indefinidamente si el servicio esta
            # trabado. Patron correcto: señal de parada + timeout + kill forzado.
            $svc = Obtener-SvcApache
            if ($svc) {
                # -NoWait: enviar señal stop sin bloquear el hilo actual
                Stop-Service $svc -NoWait -ErrorAction SilentlyContinue
                # Esperar max 5s a que el servicio llegue a Stopped
                $deadline = (Get-Date).AddSeconds(5)
                while ((Get-Date) -lt $deadline) {
                    $st = (Get-Service $svc -ErrorAction SilentlyContinue).Status
                    if (-not $st -or $st -eq "Stopped") { break }
                    Start-Sleep -Milliseconds 400
                }
            }
            # Señal graceful de Apache (puede fallar si el servicio ya esta muerto)
            $d = Obtener-RutaApache
             if ($d) {
            $rutaExe = Join-Path $d "bin\httpd.exe"
            if (Test-Path $rutaExe) {
                & $rutaExe -k uninstall 2>&1 | Out-Null
                Start-Sleep -Milliseconds 300
                }
             }
            # Kill forzado de todos los procesos httpd residuales
            Get-Process httpd -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
        }
        "nginx" {
            $d = Obtener-RutaNginx
            if ($d -and (Test-Path "$d\nginx.exe")) {
                & "$d\nginx.exe" -p $d -s stop 2>&1 | Out-Null
                Start-Sleep -Milliseconds 600
            }
            Get-Process nginx -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    if ($Puerto -gt 0) {
        $conns = Get-NetTCPConnection -LocalPort $Puerto -ErrorAction SilentlyContinue
        foreach ($c in $conns) {
            if ($c.OwningProcess -gt 4) {
                Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Milliseconds 400
    }

    Escribir-Log "INFO" "Liberar-PuertoAnterior completado: motor=$Motor puerto=$Puerto"
}

# =============================================================================
# OBTENER MOTORES INSTALADOS
# =============================================================================
function Obtener-MotoresInstalados {
    $resultado = @()
    $iis = Get-WindowsFeature -Name "Web-Server" -ErrorAction SilentlyContinue
    if ($iis -and $iis.Installed) { $resultado += "iis" }
    if ($null -ne (Obtener-RutaApache)) { $resultado += "apache" }
    if ($null -ne (Obtener-RutaNginx))  { $resultado += "nginx"  }
    return $resultado
}

# =============================================================================
# OBTENER INFO SERVIDOR
# =============================================================================
function Obtener-InfoServidor {
    param([string]$Motor)

    $version = "N/D"
    $puerto  = 0
    $estado  = "No instalado"
    $url     = "-"

    switch ($Motor) {
        "iis" {
            $feat = Get-WindowsFeature -Name "Web-Server" -ErrorAction SilentlyContinue
            if (-not ($feat -and $feat.Installed)) { return $null }

            # FIX-1 aplicado aqui tambien: extraer version numerica del registro
            $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue
            if ($reg) {
                if ($reg.MajorVersion) {
                    $version = "$($reg.MajorVersion).$($reg.MinorVersion)"
                } elseif ($reg.VersionString -match '(\d+\.\d+[\.\d]*)') {
                    $version = $Matches[1]
                } else {
                    $version = "IIS"
                }
            }
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

            $svc    = Obtener-SvcApache
            $svcObj = if ($svc) { Get-Service $svc -ErrorAction SilentlyContinue } else { $null }
            $estado = if ($svcObj -and $svcObj.Status -eq "Running") { "Corriendo" }
                      elseif (Get-Process httpd -ErrorAction SilentlyContinue) { "Corriendo" }
                      else { "Detenido" }
            $puerto = Detectar-PuertoActual -Motor "apache"
        }

        "nginx" {
            $d = Obtener-RutaNginx
            if (-not $d) { return $null }
            try {
                # nginx -v escribe a stderr; 2>&1 lo captura
                $vraw = & "$d\nginx.exe" -v 2>&1 | Select-Object -First 1
                if (($vraw -join '') -match "nginx/([\d\.]+)") { $version = $Matches[1] }
            } catch { $version = "nginx" }

            $estado = if (Get-Process nginx -ErrorAction SilentlyContinue) { "Corriendo" }
                      else { "Detenido" }
            $puerto = Detectar-PuertoActual -Motor "nginx"
        }

        default { return $null }
    }

    $url = if ($puerto -gt 0) { "http://localhost:$puerto" } else { "(detenido)" }

    return [PSCustomObject]@{
        Motor   = $Motor
        Version = $version
        Puerto  = $puerto
        Estado  = $estado
        URL     = $url
    }
}

# =============================================================================
# ACTUALIZAR PUERTO EN HTML
# FIX-3: Si el span id="puerto-display" no existe (plantilla externa sin el span),
# ya no se limita a loguear un warning: regenera el HTML completo con el nuevo
# puerto usando Desplegar-PlantillaHTML. Asi el cambio de puerto siempre se refleja
# en la pagina independientemente de que plantilla se haya usado al desplegar.
# =============================================================================
function Actualizar-PuertoEnHTML {
    param([string]$Motor, [int]$PuertoNuevo)

    $rutaHtml = switch ($Motor) {
        "iis"    { "C:\inetpub\wwwroot\index.html" }
        "apache" { $d = Obtener-RutaApache; if ($d) { Join-Path $d "htdocs\index.html" } }
        "nginx"  { $d = Obtener-RutaNginx;  if ($d) { Join-Path $d "html\index.html"   } }
    }

    if (-not $rutaHtml -or -not (Test-Path $rutaHtml)) {
        # No hay HTML: generar desde cero
        $info = Obtener-InfoServidor -Motor $Motor
        $ver  = if ($info) { $info.Version } else { "N/D" }
        Desplegar-PlantillaHTML -Motor $Motor -Version $ver -Puerto $PuertoNuevo
        Escribir-Log "INFO" "HTML creado (no existia): motor=$Motor puerto=$PuertoNuevo"
        return
    }

    try {
        $html = [System.IO.File]::ReadAllText($rutaHtml, [System.Text.Encoding]::UTF8)

        if ($html -match '<span\s+id="puerto-display">[^<]*</span>') {
            # Camino rapido: solo actualizar el span
            $html = $html -replace `
                '(<span\s+id="puerto-display">)[^<]*(</span>)', `
                "`$1$PuertoNuevo`$2"
            Escribir-Archivo $rutaHtml $html
            Escribir-Log "INFO" "HTML actualizado (span): motor=$Motor puerto=$PuertoNuevo"
        } else {
            # FIX-3: el HTML existe pero no tiene el span (plantilla externa).
            # Regenerar completo con el nuevo puerto para que siempre sea coherente.
            Escribir-Log "WARN" "span#puerto-display no encontrado en $Motor -> regenerando HTML"
            $info = Obtener-InfoServidor -Motor $Motor
            $ver  = if ($info) { $info.Version } else { "N/D" }
            Desplegar-PlantillaHTML -Motor $Motor -Version $ver -Puerto $PuertoNuevo
            Escribir-Log "INFO" "HTML regenerado: motor=$Motor puerto=$PuertoNuevo"
        }
    } catch {
        Escribir-Log "ERROR" "Actualizar-PuertoEnHTML ($Motor): $($_.Exception.Message)"
    }
}

# =============================================================================
# DESINSTALAR SERVIDOR COMPLETO
# FIX-4: nginx instala en C:\tools\nginx-VERSION (directorio versionado).
#         La limpieza ahora borra todos los directorios C:\tools\nginx* .
# =============================================================================
function Desinstalar-ServidorCompleto {
    param([string]$Motor)
    $errores = 0

    try {
        switch ($Motor) {

            "iis" {
                Write-Host "  [*] Deteniendo IIS (W3SVC + WAS)..." -ForegroundColor Cyan
                Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
                Stop-Service WAS   -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 800

                Write-Host "  [*] Deshabilitando rol Web-Server..." -ForegroundColor Cyan
                try {
                    Uninstall-WindowsFeature -Name Web-Server -IncludeManagementTools `
                        -ErrorAction Stop | Out-Null
                } catch {
                    & dism /online /disable-feature /featurename:IIS-WebServerRole /norestart 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { $errores++ }
                }

                $wwwroot = "C:\inetpub\wwwroot"
                if (Test-Path $wwwroot) {
                    Remove-Item "$wwwroot\*" -Recurse -Force -ErrorAction SilentlyContinue
                }
                Escribir-Log "INFO" "IIS desinstalado."
            }

            "apache" {
                Write-Host "  [*] Deteniendo Apache..." -ForegroundColor Cyan
                $svc = Obtener-SvcApache
                if ($svc) {
                    Stop-Service $svc -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                }

                $d = Obtener-RutaApache
                if ($d -and (Test-Path "$d\bin\httpd.exe")) {
                    Write-Host "  [*] Desregistrando servicio del SCM..." -ForegroundColor Cyan
                    & "$d\bin\httpd.exe" -k uninstall 2>&1 | Out-Null
                    Start-Sleep -Milliseconds 300
                }

                foreach ($sn in @("Apache","Apache2.4","Apache2.2","httpd","ApacheHTTPServer")) {
                    if (Get-Service $sn -ErrorAction SilentlyContinue) {
                        & sc.exe delete $sn 2>&1 | Out-Null
                        Escribir-Log "INFO" "SCM: servicio '$sn' eliminado."
                    }
                }

                Get-Process httpd -ErrorAction SilentlyContinue |
                    Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 400

                Write-Host "  [*] Desinstalando via Chocolatey..." -ForegroundColor Cyan
                $out = & choco uninstall apache-httpd -y --no-progress 2>&1
                Escribir-Log "CHOCO" ($out -join " | ")

                # Borrar directorio DESPUES del uninstall
                if ($d -and (Test-Path $d)) {
                    Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
                    Escribir-Log "INFO" "Directorio $d eliminado."
                }
                $appData = [System.Environment]::GetFolderPath("ApplicationData")
                $dAlt = Join-Path $appData "Apache24"
                if (Test-Path $dAlt) {
                    Remove-Item $dAlt -Recurse -Force -ErrorAction SilentlyContinue
                }

                foreach ($lib in @(
                    "C:\ProgramData\chocolatey\lib\apache-httpd",
                    "C:\ProgramData\chocolatey\lib-bad\apache-httpd"
                )) {
                    if (Test-Path $lib) {
                        Remove-Item $lib -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }

                Write-Host "  [*] Limpiando registro de Windows..." -ForegroundColor Cyan
                foreach ($sn in @("Apache","Apache2.4","Apache2.2","httpd","ApacheHTTPServer")) {
                    $regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$sn"
                    if (Test-Path $regKey) {
                        Remove-Item $regKey -Recurse -Force -ErrorAction SilentlyContinue
                        Escribir-Log "INFO" "Registro eliminado: $regKey"
                    }
                }
                Escribir-Log "INFO" "Apache desinstalado completamente."
            }

            "nginx" {
                Write-Host "  [*] Deteniendo nginx..." -ForegroundColor Cyan
                $d = Obtener-RutaNginx
                if ($d -and (Test-Path "$d\nginx.exe")) {
                    & "$d\nginx.exe" -p $d -s stop 2>&1 | Out-Null
                    Start-Sleep -Milliseconds 600
                }
                Get-Process nginx -ErrorAction SilentlyContinue |
                    Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 400

                Write-Host "  [*] Desinstalando via Chocolatey..." -ForegroundColor Cyan
                $out = & choco uninstall nginx -y --no-progress 2>&1
                Escribir-Log "CHOCO" ($out -join " | ")

                # Borrar el directorio detectado (puede ser C:\tools\nginx-VERSION)
                if ($d -and (Test-Path $d)) {
                    Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
                    Escribir-Log "INFO" "Directorio $d eliminado."
                }

                # FIX-4: limpiar TODOS los directorios nginx* bajo C:\tools
                # (choco crea C:\tools\nginx-1.29.6, no solo C:\tools\nginx)
                if (Test-Path "C:\tools") {
                    Get-ChildItem "C:\tools" -Filter "nginx*" -Directory `
                        -ErrorAction SilentlyContinue |
                        ForEach-Object {
                            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                            Escribir-Log "INFO" "Directorio nginx versionado eliminado: $($_.FullName)"
                        }
                }

                foreach ($lib in @(
                    "C:\ProgramData\chocolatey\lib\nginx",
                    "C:\ProgramData\chocolatey\lib-bad\nginx"
                )) {
                    if (Test-Path $lib) {
                        Remove-Item $lib -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }

                # Por si se registro como servicio manualmente
                $regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\nginx"
                if (Test-Path $regKey) {
                    & sc.exe delete nginx 2>&1 | Out-Null
                    Remove-Item $regKey -Recurse -Force -ErrorAction SilentlyContinue
                }
                Escribir-Log "INFO" "nginx desinstalado completamente."
            }
        }

        Write-Host "  [*] Eliminando reglas de firewall del modulo HTTP..." -ForegroundColor Cyan
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match "^HTTP-$Motor-" } |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue

        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path","User")

    } catch {
        $errores++
        Escribir-Log "ERROR" "Desinstalar-ServidorCompleto ($Motor): $($_.Exception.Message)"
        Write-Host "  [!] Error durante el reset: $($_.Exception.Message)" -ForegroundColor Red
    }

    return ($errores -eq 0)
}

# =============================================================================
# VERSIONES DINAMICAS
# FIX-1: IIS devuelvia "Version 10.0 (Build 20348)" como VersionString.
#         Al hacer ($str -split " ")[0] se obtenia la palabra "Version".
#         Ahora se extrae la version numerica usando MajorVersion/MinorVersion
#         del registro (enteros puros) o regex como fallback.
# =============================================================================
function Extraer-VersionesDinamicas {
    param([string]$Motor)

    if ($Motor -eq "iis") {
        $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue

        # FIX-1: usar enteros puros del registro en vez de VersionString
        $ver = if ($reg -and $reg.MajorVersion) {
            "$($reg.MajorVersion).$($reg.MinorVersion)"
        } elseif ($reg -and $reg.VersionString -match '(\d+\.\d+[\.\d]*)') {
            $Matches[1]
        } else {
            # Ultimo recurso: version del SO
            (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Version
        }

        return @("$ver (LTS - Nativo del Kernel)")
    }

    if (-not (Asegurar-Chocolatey)) { return @() }

    $paquete = if ($Motor -eq "apache") { "apache-httpd" } else { "nginx" }
    Write-Host "  [*] Consultando versiones en Chocolatey para '$paquete'..." -ForegroundColor Cyan

    $raw      = choco search $paquete --exact --all 2>$null
    $versiones = @(
        $raw | Select-String "^$paquete\s+([\d\.]+)" |
               ForEach-Object { $_.Matches.Groups[1].Value }
    )

    if ($versiones.Count -eq 0) {
        Escribir-Log "ERROR" "Sin versiones en Chocolatey para $paquete"
        return @()
    }

    if ($Motor -eq "apache") {
        $versiones = @($versiones | Where-Object {
            $partes = ($_ -split '\.')[0..2]
            try { [version]($partes -join '.') -ge [version]"2.4.50" } catch { $false }
        })
        if ($versiones.Count -eq 0) {
            Escribir-Log "ERROR" "No hay versiones funcionales de apache-httpd en Chocolatey."
            return @()
        }
    }

    $versiones = @(
        $versiones | Sort-Object -Descending {
            $partes = ($_ -split '\.')[0..2]
            try { [version]($partes -join '.') } catch { [version]"0.0.0" }
        }
    )

    $latest = $versiones[0]
    $lts    = if ($versiones.Count -ge 2) { $versiones[1] } else { $versiones[0] }
    $oldest = $versiones[-1]

    $resultado = @("$lts (LTS)")
    if ($latest -ne $lts)                          { $resultado += "$latest (Latest)" }
    if ($oldest -ne $lts -and $oldest -ne $latest) { $resultado += "$oldest (Oldest)" }

    return $resultado
}

# =============================================================================
# VALIDACION DE PUERTO
# No reporta "en uso" si el proceso en ese puerto es uno de nuestros motores
# (evita falso positivo al reinstalar el mismo motor).
# =============================================================================
function Validar-PuertoTCP {
    param([int]$Puerto, [string]$Motor = "")

    if ($Puerto -in @(135, 139, 445, 3389, 5985, 5986)) { return 2 }

    $conns = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) { return 0 }

    # Determinar el proceso legítimo según el motor solicitado
    $procesoPermitido = switch ($Motor) {
        "iis"    { "w3wp" }
        "apache" { "httpd" }
        "nginx"  { "nginx" }
        default  { "" }
    }

    $externo = $conns | Where-Object {
        try {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            # Si hay un proceso y NO es el proceso permitido, entonces está ocupado por un ajeno
            $proc -and ($proc.ProcessName -ne $procesoPermitido)
        } catch { $true }
    }

    if ($externo) { return 1 } else { return 0 }
}

# =============================================================================
# INSTALACION DE PAQUETES
# =============================================================================
function Instalar-PaquetesWeb {
    param([string]$Motor, [string]$Version, [int]$Puerto = 80)
    $ProgressPreference = 'SilentlyContinue'

    if ($Motor -eq "iis") {
        Write-Host "  [*] Instalando rol IIS (Web-Server)..." -ForegroundColor Cyan

        $isoSrc = Get-Volume -ErrorAction SilentlyContinue |
                  Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } |
                  ForEach-Object { "$($_.DriveLetter):\sources\sxs" } |
                  Where-Object   { Test-Path $_ } |
                  Select-Object -First 1

        $ok = $false
        try {
            $params = @{
                Name                   = @("Web-Server","Web-Mgmt-Tools")
                IncludeManagementTools = $true
                ErrorAction            = "Stop"
            }
            if ($isoSrc) {
                Write-Host "  [*] Fuente ISO detectada: $isoSrc" -ForegroundColor DarkCyan
                $params["Source"] = $isoSrc
            }
            Install-WindowsFeature @params | Out-Null
            $ok = $true
        } catch {
            Write-Host "  [*] Install-WindowsFeature fallo. Intentando via DISM..." -ForegroundColor Yellow
            & dism /online /enable-feature /featurename:IIS-WebServerRole `
                   /featurename:IIS-ManagementConsole /all /norestart 2>&1 | Out-Null
            $ok = ($LASTEXITCODE -eq 0)
        }

        if (-not $ok) {
            Escribir-Log "ERROR" "IIS: fallo instalacion."
            Write-Host "  [!] Montar el ISO de Windows Server en la unidad CD e intentar de nuevo." -ForegroundColor Yellow
            return $false
        }

        New-Item -ItemType Directory -Path "C:\inetpub\wwwroot" -Force `
            -ErrorAction SilentlyContinue | Out-Null
        Escribir-Log "INFO" "IIS instalado correctamente."
        return $true
    }

    if (-not (Asegurar-Chocolatey)) { return $false }

    $paquete = if ($Motor -eq "apache") { "apache-httpd" } else { "nginx" }

    Write-Host "  [*] Configurando exclusiones de Windows Defender..." -ForegroundColor Cyan
    $excluir = @("C:\ProgramData\chocolatey","C:\Apache24","C:\tools")
    foreach ($ruta in $excluir) {
        Add-MpPreference -ExclusionPath $ruta -ErrorAction SilentlyContinue
    }

    if ($Motor -eq "apache") {
        Write-Host "  [*] Verificando Visual C++ 2015-2022..." -ForegroundColor Cyan
        & choco install vcredist140 -y --no-progress 2>&1 | Out-Null
        Escribir-Log "INFO" "Dependencias VC++ verificadas."
    }

    Write-Host "  [*] Limpiando instalacion anterior de $Motor..." -ForegroundColor Cyan

    if ($Motor -eq "nginx") {
        $d = Obtener-RutaNginx
        if ($d -and (Test-Path "$d\nginx.exe")) {
            & "$d\nginx.exe" -p $d -s stop 2>&1 | Out-Null
            Start-Sleep -Milliseconds 600
        }
        Get-Process nginx -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue

    } elseif ($Motor -eq "apache") {
        $svc = Obtener-SvcApache
        if ($svc) {
            Stop-Service $svc -NoWait -ErrorAction SilentlyContinue
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-Date) -lt $deadline) {
                $st = (Get-Service $svc -ErrorAction SilentlyContinue).Status
                if (-not $st -or $st -eq "Stopped") { break }
                Start-Sleep -Milliseconds 400
            }
        }
        $d = Obtener-RutaApache
        if ($d) {
            $rutaExe = Join-Path $d "bin\httpd.exe"
            if (Test-Path $rutaExe) {
                & $rutaExe -k uninstall 2>&1 | Out-Null
                Start-Sleep -Milliseconds 300
            }
        }
        foreach ($sn in @("Apache","Apache2.4","Apache2.2","httpd","ApacheHTTPServer")) {
            if (Get-Service $sn -ErrorAction SilentlyContinue) {
                & sc.exe delete $sn 2>&1 | Out-Null
            }
        }
        Get-Process httpd -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }

    $uninstOut = & choco uninstall $paquete -y --no-progress 2>&1
    Escribir-Log "INFO" "choco uninstall $paquete : $($uninstOut -join ' | ')"

    if ($Motor -eq "apache") {
        $dApache = Obtener-RutaApache
        if (-not $dApache) {
            $appData = [System.Environment]::GetFolderPath("ApplicationData")
            foreach ($c in @("$appData\Apache24","C:\Apache24")) {
                if (Test-Path $c) { $dApache = $c; break }
            }
        }
        if ($dApache -and (Test-Path $dApache)) {
            Remove-Item $dApache -Recurse -Force -ErrorAction SilentlyContinue
            Escribir-Log "INFO" "Directorio $dApache eliminado para reinstalacion limpia."
        }
    }

    # Para nginx: limpiar directorios versionados residuales antes del install
    if ($Motor -eq "nginx" -and (Test-Path "C:\tools")) {
        Get-ChildItem "C:\tools" -Filter "nginx*" -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }

    foreach ($lib in @(
        "C:\ProgramData\chocolatey\lib\$paquete",
        "C:\ProgramData\chocolatey\lib-bad\$paquete"
    )) {
        if (Test-Path $lib) {
            Remove-Item $lib -Recurse -Force -ErrorAction SilentlyContinue
            Escribir-Log "INFO" "Residuos Chocolatey eliminados: $lib"
        }
    }

    # ─────────────────────────────────────────────────────────────────────────
    # ─────────────────────────────────────────────────────────────────────────
    # INSTALACION APACHE: DESCARGA LOCAL + PARCHE DE PORT-CHECK
    #
    # Problema: chocolateyInstall.ps1 de apache-httpd tiene un port-check
    #   hardcodeado al 8080 que corre ANTES de extraer los binarios.
    #   No acepta parametros externos para cambiarlo.
    #   Chocolatey v2.6.0 hace limpieza COMPLETA al fallar (borra lib Y lib-bad),
    #   por lo que la estrategia de "dos pasadas" no funciona: no queda nada
    #   en disco que parchear despues del fallo.
    #
    # Solucion: descargar el .nupkg manualmente (es un zip), extraerlo,
    #   parchear el port-check ANTES de que choco lo ejecute, reempacarlo,
    #   e instalarlo desde una fuente local. Choco nunca ve el 8080.
    # ─────────────────────────────────────────────────────────────────────────
    if ($Motor -eq "apache") {
        $tmpDir    = Join-Path $env:TEMP "apache-nupkg-patch"
        $srcDir    = Join-Path $tmpDir   "source"
        $extDir    = Join-Path $tmpDir   "extracted"
        $nupkgName = "$paquete.$Version.nupkg"
        $nupkgDst  = Join-Path $srcDir $nupkgName
        $nupkgUrl  = "https://community.chocolatey.org/api/v2/package/$paquete/$Version"

        # Limpiar temp de intentos anteriores
        if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
        New-Item -ItemType Directory -Path $extDir -Force | Out-Null

        Write-Host "  [*] Descargando $paquete $Version desde Chocolatey..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgDst -UseBasicParsing -ErrorAction Stop
            Escribir-Log "INFO" "nupkg descargado: $nupkgDst"
        } catch {
            Escribir-Log "ERROR" "Fallo la descarga del nupkg: $($_.Exception.Message)"
            Write-Host "  [!] No se pudo descargar el paquete. Verificar conexion a internet." -ForegroundColor Red
            foreach ($ruta in $excluir) { Remove-MpPreference -ExclusionPath $ruta -ErrorAction SilentlyContinue }
            return $false
        }

        # Extraer (nupkg = zip renombrado)
        try {
            # Bypass para PS 5.1: requiere estrictamente la extensión .zip
            $zipTmp = $nupkgDst -replace '\.nupkg$', '.zip'
            Copy-Item -Path $nupkgDst -Destination $zipTmp -Force
            
            Expand-Archive -Path $zipTmp -DestinationPath $extDir -Force -ErrorAction Stop
            
            Remove-Item -Path $zipTmp -Force
        } catch {
            Escribir-Log "ERROR" "Fallo la extraccion del nupkg: $($_.Exception.Message)"
            Write-Host "  [!] No se pudo extraer el paquete descargado." -ForegroundColor Red
            foreach ($ruta in $excluir) { Remove-MpPreference -ExclusionPath $ruta -ErrorAction SilentlyContinue }
            return $false
        }

        # Localizar chocolateyInstall.ps1 dentro del nupkg extraido
        $installScript = Get-ChildItem $extDir -Recurse -Filter "chocolateyInstall.ps1" `
                             -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $installScript) {
            Escribir-Log "ERROR" "chocolateyInstall.ps1 no encontrado dentro del nupkg extraido."
            Write-Host "  [!] Estructura del paquete inesperada." -ForegroundColor Red
            foreach ($ruta in $excluir) { Remove-MpPreference -ExclusionPath $ruta -ErrorAction SilentlyContinue }
            return $false
        }

        Write-Host "  [*] Parcheando port-check del 8080 en chocolateyInstall.ps1..." -ForegroundColor Cyan
        $scriptContent = Get-Content $installScript.FullName -Raw -Encoding UTF8
        
        # Parche actualizado basado en el log de estructura real:
        # Busca el throw, ignorando si usa comillas simples o dobles
        $patched = $scriptContent -replace '(?m)^(\s*)(throw\s+[''"]Please specify a different port number\.\.\.[''"])', '$1# [PATCHED-8080] $2'
        
        # Fallback de seguridad: Si también está el Assert, lo anulamos forzando a $true
        $patched = $patched -replace '(?m)if\s*\(\s*-not\s*\(\s*Assert-TcpPortIsOpen[^\)]+\)\s*\)', 'if ($false)'

        if ($patched -eq $scriptContent) {
            Escribir-Log "WARN" "Patch no modifico ningun patron. Contenido del script:"
            $scriptContent -split "`n" | Select-Object -First 60 |
                ForEach-Object { Escribir-Log "SCRIPT" $_ }
            Write-Host "  [!] No se encontraron los patrones del port-check." -ForegroundColor Yellow
        } else {
            [System.IO.File]::WriteAllText($installScript.FullName, $patched,
                [System.Text.UTF8Encoding]::new($false))
            Escribir-Log "INFO" "chocolateyInstall.ps1 parcheado correctamente."
            Write-Host "  [OK] Port-check desactivado." -ForegroundColor Green
        }

        # Reempacar el nupkg (Bypass para PS 5.1)
        try {
            Remove-Item $nupkgDst -Force -ErrorAction SilentlyContinue
            
            # Comprimimos a .zip primero
            $zipDst = "$nupkgDst.zip"
            Compress-Archive -Path "$extDir\*" -DestinationPath $zipDst -Force -ErrorAction Stop
            
            # Renombramos el .zip a .nupkg para que choco lo acepte
            Move-Item -Path $zipDst -Destination $nupkgDst -Force
            
            Escribir-Log "INFO" "nupkg reempacado exitosamente."
        } catch {
            Escribir-Log "ERROR" "Fallo al reempacar el nupkg: $($_.Exception.Message)"
            Write-Host "  [!] Error al re-comprimir el parche." -ForegroundColor Red
            foreach ($ruta in $excluir) { Remove-MpPreference -ExclusionPath $ruta -ErrorAction SilentlyContinue }
            return $false
        }

        # Instalar desde la fuente local (choco no toca internet, usa nuestro nupkg)
        Escribir-Log "INFO" "Instalando $paquete $Version desde fuente local parcheada."
        Write-Host "  [*] Instalando $Motor $Version desde fuente local..." -ForegroundColor Cyan
        $chocoOutput = & choco install $paquete --version $Version -y --no-progress `
                           --source $srcDir 2>&1
        $chocoOutput | ForEach-Object { Escribir-Log "CHOCO" $_ }
        $chocoExitCode = $LASTEXITCODE

        # Limpiar temp independientemente del resultado
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

        if ($chocoExitCode -ne 0) {
            Escribir-Log "ERROR" "$paquete v$Version fallo (exit $chocoExitCode)."
            $errLines = $chocoOutput | Where-Object { $_ -match "ERROR|failed|exited|Unable" }
            if ($errLines) {
                Write-Host "  [!] Detalle:" -ForegroundColor Yellow
                $errLines | Select-Object -Last 4 |
                    ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
            }
            foreach ($ruta in $excluir) { Remove-MpPreference -ExclusionPath $ruta -ErrorAction SilentlyContinue }
            return $false
        }
    } else {
        # nginx: instalacion directa sin two-pass (no tiene port-check en el script)
        Escribir-Log "INFO" "Iniciando: choco install $paquete --version $Version"
        Write-Host "  [*] Instalando $Motor $Version via Chocolatey..." -ForegroundColor Cyan
        $chocoOutput = & choco install $paquete --version $Version -y --no-progress 2>&1
        $chocoOutput | ForEach-Object { Escribir-Log "CHOCO" $_ }

        if ($LASTEXITCODE -ne 0) {
            Escribir-Log "ERROR" "$paquete v$Version fallo (exit $LASTEXITCODE)."
            $errLines = $chocoOutput | Where-Object { $_ -match "ERROR|failed|exited|Unable" }
            if ($errLines) {
                Write-Host "  [!] Detalle:" -ForegroundColor Yellow
                $errLines | Select-Object -Last 4 |
                    ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
            }
            foreach ($ruta in $excluir) { Remove-MpPreference -ExclusionPath $ruta -ErrorAction SilentlyContinue }
            return $false
        }
    }

    Write-Host "  [*] Esperando extraccion de binarios en disco..." -ForegroundColor Cyan
    $exeRuta = $null; $encontrado = $false
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Milliseconds 500
        if ($i % 8 -eq 0) {
            Write-Host "`r  [*] Esperando extraccion... $([int]($i/2))s " -NoNewline -ForegroundColor Cyan
        }
        if ($Motor -eq "apache") {
            $d = Obtener-RutaApache
            if ($d -and (Test-Path "$d\bin\httpd.exe")) {
                $exeRuta = "$d\bin\httpd.exe"; $encontrado = $true; break
            }
        } else {
            $d = Obtener-RutaNginx
            if ($d -and (Test-Path "$d\nginx.exe")) {
                $exeRuta = "$d\nginx.exe"; $encontrado = $true; break
            }
        }
    }
    Write-Host ""

    foreach ($ruta in $excluir) {
        Remove-MpPreference -ExclusionPath $ruta -ErrorAction SilentlyContinue
    }

    if (-not $encontrado) {
        Escribir-Log "ERROR" "Ejecutable no aparecio en disco tras 60s: $Motor $Version"
        Write-Host "  [!] El ejecutable no esta en disco. Posible problema de VM o antivirus." -ForegroundColor Red
        return $false
    }

    Write-Host "`r  [OK] Binarios extraidos: $exeRuta                    " -ForegroundColor Green

    if ($Motor -eq "apache") {
        Write-Host "  [*] Registrando Apache como servicio de Windows..." -ForegroundColor Cyan
        & $exeRuta -k install 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        Start-Service "Apache2.4" -ErrorAction SilentlyContinue
    }

    Escribir-Log "INFO" "$paquete v$Version instalado correctamente."
    return $true
}

# =============================================================================
# CONFIGURACION DE PUERTO
# FIX-2: nginx -t escribe a stderr. Con 2>&1, $testOut es un array mixto.
#         "-notmatch" sobre un array NO devuelve bool: devuelve los elementos
#         que no coinciden (array filtrado). Un array no vacio es truthy, por lo
#         que la condicion siempre disparaba el throw aunque nginx reportara OK.
#         Solucion: convertir el array a string con -join antes de comparar.
# =============================================================================
function Configurar-PuertoServicio {
    param([string]$Motor, [int]$Puerto)

    $conns = Get-NetTCPConnection -LocalPort $Puerto -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        if ($c.OwningProcess -gt 4) {
            Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
        }
    }
    if ($conns) { Start-Sleep -Milliseconds 400 }

    try {
        if ($Motor -eq "iis") {
            Import-Module WebAdministration -ErrorAction Stop
            Set-ItemProperty "IIS:\Sites\Default Web Site" -Name Bindings `
                -Value @(@{ protocol="http"; bindingInformation="*:${Puerto}:" })
            Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2

            $ok = $false
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Milliseconds 500
                if (Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue) {
                    $ok = $true; break
                }
            }
            if (-not $ok) { throw "IIS no bindeo el puerto $Puerto tras reinicio." }
            Escribir-Log "INFO" "IIS configurado en puerto $Puerto."
        }

        elseif ($Motor -eq "apache") {
            $dir = Obtener-RutaApache
            if (-not $dir) { throw "httpd.exe no encontrado. Verificar instalacion." }

            $httpdExe = Join-Path $dir "bin\httpd.exe"
            $confPath = Join-Path $dir "conf\httpd.conf"
            $dirUnix  = $dir -replace "\\", "/"

            $svc = Obtener-SvcApache
            if ($svc) {
                Stop-Service $svc -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 600
            }
            Get-Process httpd -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            & $httpdExe -k uninstall 2>&1 | Out-Null
            foreach ($sn in @("Apache","Apache2.4","httpd")) {
                if (Get-Service $sn -ErrorAction SilentlyContinue) {
                    & sc.exe delete $sn 2>&1 | Out-Null
                }
            }
            Start-Sleep -Milliseconds 800

            $conf = Get-Content $confPath -Raw -ErrorAction Stop
            $conf = $conf -replace '(?m)^ServerRoot\s+"[^"]+"',         "ServerRoot `"$dirUnix`""
            $conf = $conf -replace '(?m)^DocumentRoot\s+"[^"]+"',       "DocumentRoot `"$dirUnix/htdocs`""
            $conf = $conf -replace '(?m)^<Directory\s+"[^"]+/htdocs">', "<Directory `"$dirUnix/htdocs`">"
            $conf = $conf -replace '(?m)^Listen \d+',                   "Listen $Puerto"
            [System.IO.File]::WriteAllText($confPath, $conf, [System.Text.ASCIIEncoding]::new())

            $sintaxis = & $httpdExe -t 2>&1
            Escribir-Log "APACHE" ($sintaxis -join " | ")
            if (($sintaxis -join ' ') -notmatch "Syntax OK") {
                throw "httpd.conf invalido tras edicion: $($sintaxis -join ' ')"
            }

            & $httpdExe -k install -f "`"$confPath`"" 2>&1 | Out-Null
            Start-Sleep -Milliseconds 500

            $svcNuevo = Obtener-SvcApache
            if ($svcNuevo) {
                Start-Service $svcNuevo -ErrorAction SilentlyContinue
            } else {
                Start-Process $httpdExe -ArgumentList "-k start" -WindowStyle Hidden
            }

            $bindeado = $false
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 500
                if (Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue) {
                    $bindeado = $true; break
                }
            }
            if (-not $bindeado) {
                $errLog = Join-Path $dir "logs\error.log"
                if (Test-Path $errLog) {
                    Get-Content $errLog -Tail 5 -ErrorAction SilentlyContinue |
                        ForEach-Object { Escribir-Log "APACHE-ERR" $_ }
                }
                throw "Apache arranco pero no bindeo el puerto $Puerto (ver APACHE-ERR en log)."
            }
            Escribir-Log "INFO" "Apache configurado en puerto $Puerto."
        }

        elseif ($Motor -eq "nginx") {
            $dir      = Obtener-RutaNginx
            if (-not $dir) { throw "nginx.exe no encontrado. Verificar instalacion." }

            $confPath = Join-Path $dir "conf\nginx.conf"
            $nginxExe = Join-Path $dir "nginx.exe"

            $nuevoConf = @"
worker_processes  1;
events {
    worker_connections  1024;
}
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout  65;
    server_tokens off;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    server {
        listen       $Puerto;
        server_name  localhost;
        root         html;
        index        index.html index.htm;
        location / {
            try_files `$uri `$uri/ =404;
        }
    }
}
"@
            Escribir-Archivo $confPath $nuevoConf

            if (Get-Process nginx -ErrorAction SilentlyContinue) {
                & $nginxExe -p $dir -s stop 2>&1 | Out-Null
                Start-Sleep -Milliseconds 800
                Get-Process nginx -ErrorAction SilentlyContinue |
                    Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 400
            }

            # FIX-2: nginx -t escribe a stderr -> array mixto al capturar con 2>&1
            # Unir el array con -join ANTES de usar -notmatch para obtener un bool real
            $testOut    = & $nginxExe -p $dir -t 2>&1
            $testOutStr = ($testOut -join ' ')
            Escribir-Log "NGINX" ($testOut -join " | ")
            if ($testOutStr -notmatch "syntax is ok" -and $testOutStr -notmatch "test is successful") {
                throw "nginx.conf invalido: $testOutStr"
            }

            Start-Process $nginxExe -ArgumentList "-p `"$dir`"" `
                          -WorkingDirectory $dir -WindowStyle Hidden

            $bindeado = $false
            for ($i = 0; $i -lt 13; $i++) {
                Start-Sleep -Milliseconds 300
                if (Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue) {
                    $bindeado = $true; break
                }
            }
            if (-not $bindeado) {
                $errLog = Join-Path $dir "logs\error.log"
                if (Test-Path $errLog) {
                    Write-Host "  [!] nginx error.log (ultimas 5 lineas):" -ForegroundColor Red
                    Get-Content $errLog -Tail 5 -ErrorAction SilentlyContinue |
                        ForEach-Object { Write-Host "      $_" -ForegroundColor DarkRed }
                }
                throw "nginx arranco pero no bindeo el puerto $Puerto."
            }
            Escribir-Log "INFO" "nginx configurado en puerto $Puerto."
        }

        Remove-NetFirewallRule -DisplayName "HTTP-$Motor-$Puerto" -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "HTTP-$Motor-$Puerto" `
            -Direction Inbound -LocalPort $Puerto -Protocol TCP `
            -Action Allow -ErrorAction SilentlyContinue | Out-Null

        Escribir-Log "INFO" "$Motor configurado en puerto $Puerto. Firewall ajustado."
        return $true

    } catch {
        Escribir-Log "ERROR" "Configurar-PuertoServicio ($Motor) puerto $Puerto : $($_.Exception.Message)"
        Write-Host "  [!] $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# =============================================================================
# HARDENING DE SEGURIDAD
# =============================================================================
function Aplicar-HardeningSeguridad {
    param([string]$Motor)
    Write-Host "  [*] Aplicando hardening de seguridad..." -ForegroundColor Cyan

    if ($Motor -eq "iis") {
        Import-Module WebAdministration -ErrorAction SilentlyContinue

        Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
            -filter "system.webServer/security/requestFiltering" `
            -name "removeServerHeader" -value "true" -ErrorAction SilentlyContinue

        Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
            -filter "system.webServer/httpProtocol/customHeaders" `
            -name "collection" -AtElement @{ name='X-Powered-By' } `
            -ErrorAction SilentlyContinue

        $existentes = @(
            (Get-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
             -filter "system.webServer/httpProtocol/customHeaders" `
             -name "collection" -ErrorAction SilentlyContinue) |
            ForEach-Object { $_.name }
        )
        foreach ($h in @(
            @{ name='X-Frame-Options';        value='SAMEORIGIN' },
            @{ name='X-Content-Type-Options'; value='nosniff' }
        )) {
            if ($h.name -notin $existentes) {
                Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' `
                    -filter "system.webServer/httpProtocol/customHeaders" `
                    -name "collection" -value $h -ErrorAction SilentlyContinue
            }
        }

    } elseif ($Motor -eq "apache") {
        $dir      = Obtener-RutaApache
        $confPath = Join-Path $dir "conf\httpd.conf"
        if (-not (Test-Path $confPath)) { return }

        $contenido = Get-Content $confPath -Raw
        $contenido = $contenido -replace '#LoadModule headers_module', 'LoadModule headers_module'

        if ($contenido -notmatch "ServerTokens Prod") {
            $contenido += "`nServerTokens Prod"
            $contenido += "`nServerSignature Off"
            $contenido += "`nTraceEnable Off"
            $contenido += "`nHeader always set X-Frame-Options SAMEORIGIN"
            $contenido += "`nHeader always set X-Content-Type-Options nosniff"
        }

        [System.IO.File]::WriteAllText($confPath, $contenido, [System.Text.ASCIIEncoding]::new())

        # FIX-2 aplicado aqui tambien: unir antes de -notmatch
        $sintaxis = & (Join-Path $dir "bin\httpd.exe") -t 2>&1
        if (($sintaxis -join ' ') -notmatch "Syntax OK") {
            Escribir-Log "ERROR" "Hardening Apache: httpd.conf invalido: $($sintaxis -join ' ')"
            Write-Host "  [!] Error en httpd.conf tras hardening. Ver log." -ForegroundColor Red
            return
        }

        $svc = Obtener-SvcApache
        if ($svc) { Restart-Service $svc -Force -ErrorAction SilentlyContinue }
    }
    # nginx: server_tokens off y headers inyectados en Configurar-PuertoServicio
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
        $acl  = Get-Acl $ruta
        $inh  = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
        $none = [System.Security.AccessControl.PropagationFlags]"None"
        $allow= [System.Security.AccessControl.AccessControlType]"Allow"
        $acl.SetAccessRuleProtection($true, $false)

        foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
            $acl.AddAccessRule(
                [System.Security.AccessControl.FileSystemAccessRule]::new(
                    [System.Security.Principal.SecurityIdentifier]::new($sid),
                    "FullControl", $inh, $none, $allow))
        }
        if ($Motor -eq "iis") {
            foreach ($sid in @('S-1-5-32-568','S-1-5-17')) {
                $acl.AddAccessRule(
                    [System.Security.AccessControl.FileSystemAccessRule]::new(
                        [System.Security.Principal.SecurityIdentifier]::new($sid),
                        "ReadAndExecute", $inh, $none, $allow))
            }
        }
        Set-Acl -Path $ruta -AclObject $acl
        Escribir-Log "INFO" "Permisos NTFS aplicados en $ruta para $Motor"
    } catch {
        Escribir-Log "ERROR" "Aislar-DirectorioWeb ($Motor): $($_.Exception.Message)"
    }
}

# =============================================================================
# PLANTILLA HTML
# El span id="puerto-display" es el gancho para Actualizar-PuertoEnHTML.
# Si la plantilla externa ($global:TEMPLATE_WIN) no tiene ese span,
# Actualizar-PuertoEnHTML regenerara este fallback con el nuevo puerto.
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

    if (Test-Path $global:TEMPLATE_WIN) {
        $html = (Get-Content $global:TEMPLATE_WIN -Raw -Encoding UTF8) `
                    -replace "@@MOTOR@@",   $Motor.ToUpper() `
                    -replace "@@VERSION@@", $Version `
                    -replace "@@PUERTO@@",  "$Puerto"
        Escribir-Archivo $rutaHtml $html
    } else {
        $fallback = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$($Motor.ToUpper()) - Servidor HTTP</title>
  <style>
    body  { font-family: Segoe UI, sans-serif; max-width: 600px; margin: 60px auto;
            background: #1a1a2e; color: #eee; text-align: center; }
    h1    { color: #e94560; }
    .badge{ display:inline-block; background:#16213e; border:1px solid #e94560;
            border-radius:6px; padding:8px 20px; margin:6px; font-size:1.1em; }
    .label{ color:#aaa; font-size:.85em; display:block; }
  </style>
</head>
<body>
  <h1>$($Motor.ToUpper())</h1>
  <p>Servidor HTTP activo</p>
  <div class="badge"><span class="label">Version</span>$Version</div>
  <div class="badge"><span class="label">Puerto</span><span id="puerto-display">$Puerto</span></div>
  <div class="badge"><span class="label">Motor</span>$($Motor.ToUpper())</div>
</body>
</html>
"@
        Escribir-Archivo $rutaHtml $fallback
        Escribir-Log "WARN" "Plantilla externa no encontrada: $($global:TEMPLATE_WIN). Usando fallback."
    }

    Escribir-Log "INFO" "Plantilla desplegada: $rutaHtml (motor=$Motor ver=$Version puerto=$Puerto)"
}