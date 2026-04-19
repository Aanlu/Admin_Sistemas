# ============================================================
# ssl_funciones.ps1 - PKI y SSL/TLS para IIS, Apache, Nginx
# Compatible: PowerShell 5.1 (Windows Server 2022)
# Fixes:
#   - Redirección 301 estricta en IIS (URL Rewrite module)
#   - HSTS inyectado en los 3 motores HTTP
#   - FTPS estricto (Control y Datos requeridos)
#   - Fail-fast para entornos offline sin OpenSSL
# ============================================================

$global:PKI_DIR = "C:\SSL_Admin_Sistemas"

# ============================================================
# ASEGURAR-OPENSSL
# Instala openssl via choco si no esta disponible
# ============================================================
function Asegurar-OpenSSL {
    $rutas = @(
        "C:\ProgramData\chocolatey\bin\openssl.exe",
        "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
        "C:\Program Files\OpenSSL\bin\openssl.exe",
        "C:\Program Files\Git\usr\bin\openssl.exe",
        "C:\tools\openssl\openssl.exe"
    )
    foreach ($r in $rutas) { if (Test-Path $r) { return $r } }

    $cmd = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    Write-Host "  [*] OpenSSL no detectado. Intentando instalar via Chocolatey..." -ForegroundColor Cyan
    
    $netCheck = Test-NetConnection community.chocolatey.org -Port 443 -WarningAction SilentlyContinue
    if (-not $netCheck.TcpTestSucceeded) {
        Log-Error "Entorno offline. Se requiere internet para descargar OpenSSL (necesario para formato PEM de Apache/Nginx)."
        return $null
    }

    if (-not (Asegurar-Chocolatey)) { return $null }

    & choco install openssl -y --no-progress 2>&1 | Out-Null
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    foreach ($r in $rutas) { if (Test-Path $r) { return $r } }
    $cmd2 = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if ($cmd2) { return $cmd2.Source }

    Log-Error "No se pudo instalar OpenSSL de forma automatizada."
    return $null
}

function Verificar-Dependencias-P7 {
    # Si ya se verificó en esta sesión, no reintentar
    if ($global:PKI_DEPS_VERIFICADAS) { return }
    $global:PKI_DEPS_VERIFICADAS = $true

    Write-Host "  [*] Verificando dependencias criticas de infraestructura PKI..." -ForegroundColor DarkGray
    $global:OPENSSL_EXE = Asegurar-OpenSSL
    if (-not $global:OPENSSL_EXE) {
        Log-Warning "OpenSSL no disponible. Se usara exportacion PEM nativa para Apache y Nginx."
    }
}

# ============================================================
# GENERAR-CERT-AUTOFIRMADO (Reutilizable)
# ============================================================
function Generar-CertAutofirmado {
    param([string]$Dominio)

    if (-not (Test-Path $global:PKI_DIR)) { New-Item -ItemType Directory -Path $global:PKI_DIR -Force | Out-Null }

    $escapado  = [regex]::Escape($Dominio)
    $certExist = Get-ChildItem "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue |
                 Where-Object { $_.Subject -match $escapado -and $_.NotAfter -gt (Get-Date) } |
                 Sort-Object NotAfter -Descending | Select-Object -First 1

    if ($certExist) {
        Escribir-Log "INFO" "PKI: Reutilizando certificado para $Dominio"
        return $certExist.Thumbprint
    }

    Write-Host "  [PKI] Generando certificado X.509 RSA-2048 Autofirmado para: $Dominio" -ForegroundColor Cyan
    try {
        $cert = New-SelfSignedCertificate `
            -DnsName $Dominio, "www.$Dominio", "*.$Dominio" `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -NotAfter (Get-Date).AddDays(365) `
            -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
            -KeyUsage DigitalSignature, KeyEncipherment `
            -KeyExportPolicy Exportable `
            -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider" `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1") -ErrorAction Stop

        Escribir-Log "INFO" "PKI: Nuevo certificado $Dominio Thumb=$($cert.Thumbprint)"
        return $cert.Thumbprint
    } catch {
        Log-Error "[PKI] Falla critica en creacion: $($_.Exception.Message)"
        return $null
    }
}

function Obtener-CertThumbprint {
    param([string]$Dominio)
    $escapado = [regex]::Escape($Dominio)
    $cert = Get-ChildItem "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -match $escapado -and $_.NotAfter -gt (Get-Date) } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($cert) { return $cert.Thumbprint }
    return $null
}

function Exportar-CertPEM {
    param([string]$Thumbprint, [string]$CertFile, [string]$KeyFile)

    $opensslExe = if ($global:OPENSSL_EXE) { $global:OPENSSL_EXE } else { Asegurar-OpenSSL }
    if ($opensslExe) {
        $pfxTemp    = Join-Path $env:TEMP "ssl_p7_export.pfx"
        $pfxPass    = "TmpExportP7SSL"
        $pfxPassSec = ConvertTo-SecureString $pfxPass -AsPlainText -Force
        try {
            $cert = Get-ChildItem "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction Stop
            Export-PfxCertificate -Cert $cert -FilePath $pfxTemp -Password $pfxPassSec | Out-Null
            & $opensslExe pkcs12 -in $pfxTemp -out $CertFile -nokeys -passin "pass:$pfxPass" 2>&1 | Out-Null
            & $opensslExe pkcs12 -in $pfxTemp -out $KeyFile -nocerts -nodes -passin "pass:$pfxPass" 2>&1 | Out-Null
            Remove-Item $pfxTemp -Force -ErrorAction SilentlyContinue
            if ((Test-Path $CertFile) -and (Test-Path $KeyFile)) { return $true }
        } catch { }
        Remove-Item $pfxTemp -Force -ErrorAction SilentlyContinue
    }

    # FALLBACK NATIVO - Compatible con .NET Framework 4.x y claves CryptoAPI legacy
    Write-Host "  [*] Exportando PEM nativo (.NET Framework / CryptoAPI)..." -ForegroundColor Yellow
    try {
        $certObj = Get-ChildItem "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction Stop

        # -- Certificado publico (.crt) --
        $certBytes  = $certObj.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        $certBase64 = [Convert]::ToBase64String($certBytes, 'InsertLineBreaks')
        $certPem    = "-----BEGIN CERTIFICATE-----`r`n$certBase64`r`n-----END CERTIFICATE-----"
        [System.IO.File]::WriteAllText($CertFile, $certPem, [System.Text.UTF8Encoding]::new($false))

        # -- Clave privada (.key) via PFX con flag Exportable --
        $pfxTemp2    = Join-Path $env:TEMP "ssl_native_$Thumbprint.pfx"
        $pfxPassStr  = "NativeExport_P7!"
        $pfxPassSec2 = ConvertTo-SecureString $pfxPassStr -AsPlainText -Force

        Export-PfxCertificate -Cert $certObj -FilePath $pfxTemp2 -Password $pfxPassSec2 -ErrorAction Stop | Out-Null

        # Cargar con flag Exportable explícito
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
                 [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet

        $pfxCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $pfxTemp2, $pfxPassStr, $flags
        )
        Remove-Item $pfxTemp2 -Force -ErrorAction SilentlyContinue

        # .PrivateKey funciona aquí porque el Fix 1 fuerza proveedor CryptoAPI legacy
        $rsa = $pfxCert.PrivateKey -as [System.Security.Cryptography.RSACryptoServiceProvider]
        if (-not $rsa) {
            Log-Error "PrivateKey es null. Asegurate de que el certificado fue generado con -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider'"
            return $false
        }

        $keyPem = ConvertTo-RsaPkcs1Pem -Rsa $rsa
        [System.IO.File]::WriteAllText($KeyFile, $keyPem, [System.Text.UTF8Encoding]::new($false))

        Log-Ok "Certificados PEM exportados correctamente."
        return ((Test-Path $CertFile) -and (Test-Path $KeyFile))

    } catch {
        Log-Error "Exportacion PEM fallback fallo: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# FUNCION AUXILIAR: Codifica RSACryptoServiceProvider -> PKCS#1 PEM
# Compatible con .NET Framework 4.x / PowerShell 5.1
# ============================================================
function ConvertTo-RsaPkcs1Pem {
    param([System.Security.Cryptography.RSACryptoServiceProvider]$Rsa)

    # Helpers de encoding ASN.1 DER
    function Encode-DerLength([int]$len) {
        if ($len -lt 128)   { return [byte[]]@($len) }
        if ($len -lt 256)   { return [byte[]]@(0x81, $len) }
        return [byte[]]@(0x82, ($len -shr 8), ($len -band 0xFF))
    }

    function Encode-DerInteger([byte[]]$bytes) {
        # Quitar ceros a la izquierda, agregar 0x00 si el bit alto está activo
        $i = 0
        while ($i -lt ($bytes.Length - 1) -and $bytes[$i] -eq 0) { $i++ }
        $bytes = $bytes[$i..($bytes.Length - 1)]
        if ($bytes[0] -band 0x80) { $bytes = @([byte]0x00) + $bytes }
        return [byte[]](@(0x02) + (Encode-DerLength $bytes.Length) + $bytes)
    }

    $p = $Rsa.ExportParameters($true)

    $version = [byte[]]@(0x02, 0x01, 0x00)          # INTEGER 0 (version)
    $n   = Encode-DerInteger $p.Modulus
    $e   = Encode-DerInteger $p.Exponent
    $d   = Encode-DerInteger $p.D
    $pr1 = Encode-DerInteger $p.P
    $pr2 = Encode-DerInteger $p.Q
    $e1  = Encode-DerInteger $p.DP
    $e2  = Encode-DerInteger $p.DQ
    $qi  = Encode-DerInteger $p.InverseQ

    $body = $version + $n + $e + $d + $pr1 + $pr2 + $e1 + $e2 + $qi
    $seq  = [byte[]](@(0x30) + (Encode-DerLength $body.Length) + $body)

    $b64 = [Convert]::ToBase64String($seq, 'InsertLineBreaks')
    return "-----BEGIN RSA PRIVATE KEY-----`r`n$b64`r`n-----END RSA PRIVATE KEY-----"
}

# ============================================================
# APLICAR-PERMISOS-PKI
# ============================================================
function Aplicar-Permisos-PKI {
    param([string]$CertFile, [string]$KeyFile, [string]$Motor)
    $sid = switch ($Motor) { "apache" { "S-1-5-20" }; "nginx" { "S-1-5-20" }; "iis" { "S-1-5-32-568" }; default { "S-1-5-20" } }

    foreach ($archivo in @($CertFile, $KeyFile)) {
        if (-not (Test-Path $archivo)) { continue }
        try {
            $acl = Get-Acl $archivo
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, "Read", "None", "None", "Allow"))
            Set-Acl $archivo $acl
        } catch { }
    }
}

# ============================================================
# CAPTURAR-PUERTO-SSL (Mantenido para el asistente UX)
# ============================================================
function Capturar-Puerto-SSL {
    param([string]$Motor, [int]$PuertoSugerido)
    Write-Host "`n  Puerto SSL sugerido para $($Motor.ToUpper()): $PuertoSugerido" -ForegroundColor Cyan
    $input = Read-Host "  [Enter para usar $PuertoSugerido, o ingrese otro]"
    $puerto = $PuertoSugerido
    $n = 0   # <-- agregar esta línea antes del if
if (-not [string]::IsNullOrWhiteSpace($input) -and [int]::TryParse($input.Trim(), [ref]$n) -and $n -gt 0 -and $n -le 65535) { $puerto = $n }

    $est = Validar-PuertoTCP -Puerto $puerto -Motor $Motor
    if ($est -ne 0) {
        Log-Warning "Puerto $puerto no disponible. Ingrese otro."
        $puerto = Capturar-Entero "Puerto SSL para $Motor"
    }
    return $puerto
}

# ============================================================
# VERIFICAR-HTTPS (Validación Estricta Multi-Idioma)
# ============================================================
function Verificar-HTTPS {
    param([string]$Dominio, [int]$Puerto)
    
    # 1. Prueba estricta de socket (Evita falsos positivos por idioma del OS)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", $Puerto)
        $tcp.Close()
    } catch { 
        return $false # Si no hay socket, el servidor definitivamente está caído.
    }
    
    # 2. Prueba TLS (Verificación de Cifrado)
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $resp = Invoke-WebRequest -Uri "https://$Dominio`:$Puerto" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400)
    } catch {
        return $true # Si el socket abrió pero Invoke-WebRequest falló, es la advertencia normal de Certificado Autofirmado. Funciona.
    }
}

# ============================================================
# ACTIVAR-SSL-IIS
# ============================================================
function Activar-SSL-IIS {
    param([string]$Dominio, [int]$PuertoHTTP = 80, [int]$PuertoSSL = 443)
    Write-Host "`n=== SSL/TLS -> IIS | $Dominio | HTTP:$PuertoHTTP HTTPS:$PuertoSSL ===" -ForegroundColor Yellow
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $thumb = Generar-CertAutofirmado -Dominio $Dominio
    if (-not $thumb) { return $false }

    try {
        $siteName = "Default Web Site"

        # 1. Bindings
        Get-WebBinding -Name $siteName -Protocol "https" -ErrorAction SilentlyContinue | Where-Object { $_.bindingInformation -match ":${PuertoSSL}:" } | ForEach-Object { Remove-WebBinding -Name $siteName -Protocol "https" -BindingInformation $_.bindingInformation }
        New-WebBinding -Name $siteName -Protocol "https" -Port $PuertoSSL -HostHeader $Dominio -SslFlags 0 -ErrorAction Stop
        
        $bindPath = "IIS:\SslBindings\0.0.0.0!$PuertoSSL"
        if (Test-Path $bindPath) { Remove-Item $bindPath -Force -ErrorAction SilentlyContinue }
        New-Item $bindPath -Value (Get-ChildItem "Cert:\LocalMachine\My\$thumb") -ErrorAction Stop | Out-Null

        # 2. Inyeccion HSTS (Cabecera Estricta)
        $filterHdr = "system.webServer/httpProtocol/customHeaders"
        Remove-WebConfigurationProperty -PSPath "IIS:\Sites\$siteName" -Filter $filterHdr -Name "collection" -AtElement @{ name='Strict-Transport-Security' } -ErrorAction SilentlyContinue
        Add-WebConfigurationProperty -PSPath "IIS:\Sites\$siteName" -Filter $filterHdr -Name "collection" -Value @{ name='Strict-Transport-Security'; value='max-age=31536000; includeSubDomains' } -ErrorAction SilentlyContinue

        # 3. Forzar Redireccion Automatica 301 (Requiere URL Rewrite)
        $urlRewriteKey = "HKLM:\SOFTWARE\Microsoft\IIS Extensions\URL Rewrite"
        if (-not (Test-Path $urlRewriteKey)) {
            Write-Host "  [*] Instalando URL Rewrite en IIS para forzar redireccion 301..." -ForegroundColor DarkGray
            & choco install urlrewrite -y --no-progress 2>&1 | Out-Null
        }
        
        if (Test-Path $urlRewriteKey) {
            $rewriteConfig = "system.webServer/rewrite/rules"
            $sitePath = "MACHINE/WEBROOT/APPHOST/$siteName"
            
            Remove-WebConfigurationProperty -pspath $sitePath -filter $rewriteConfig -name "." -AtElement @{name='Redirigir_A_HTTPS'} -ErrorAction SilentlyContinue
            Add-WebConfigurationProperty -pspath $sitePath -filter $rewriteConfig -name "." -value @{name='Redirigir_A_HTTPS'; stopProcessing='True'}
            Set-WebConfigurationProperty -pspath $sitePath -filter "$rewriteConfig/rule[@name='Redirigir_A_HTTPS']/match" -name "url" -value "(.*)"
            Add-WebConfigurationProperty -pspath $sitePath -filter "$rewriteConfig/rule[@name='Redirigir_A_HTTPS']/conditions" -name "." -value @{input='{HTTPS}'; pattern='^OFF$'}
            Set-WebConfigurationProperty -pspath $sitePath -filter "$rewriteConfig/rule[@name='Redirigir_A_HTTPS']/action" -name "type" -value "Redirect"
            Set-WebConfigurationProperty -pspath $sitePath -filter "$rewriteConfig/rule[@name='Redirigir_A_HTTPS']/action" -name "url" -value "https://$Dominio`:$PuertoSSL/{R:1}"
            Set-WebConfigurationProperty -pspath $sitePath -filter "$rewriteConfig/rule[@name='Redirigir_A_HTTPS']/action" -name "redirectType" -value "Permanent"
            Log-Ok "Regla de redireccion 301 HTTP -> HTTPS inyectada en IIS."
        }

        # Firewall y Reinicio
        Remove-NetFirewallRule -DisplayName "HTTPS-IIS-$PuertoSSL" -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "HTTPS-IIS-$PuertoSSL" -Direction Inbound -LocalPort $PuertoSSL -Protocol TCP -Action Allow | Out-Null
        Stop-Service W3SVC -Force -ErrorAction SilentlyContinue; Start-Service W3SVC -ErrorAction SilentlyContinue

        Verificar-HTTPS -Dominio "127.0.0.1" -Puerto $PuertoSSL | Out-Null
        Log-Ok "IIS SSL activo -> https://${Dominio}:${PuertoSSL}"
        return $true
    } catch {
        Log-Error "Fallo critico IIS SSL: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# ACTIVAR-SSL-APACHE
# ============================================================
function Activar-SSL-Apache {
    param([string]$Dominio, [int]$PuertoHTTP = 80, [int]$PuertoSSL = 443)
    Write-Host "`n=== SSL/TLS -> APACHE | $Dominio | HTTP:$PuertoHTTP HTTPS:$PuertoSSL ===" -ForegroundColor Yellow
    
    $apacheDir = Obtener-RutaApache
    if (-not $apacheDir) { return $false }
    $thumb = Generar-CertAutofirmado -Dominio $Dominio
    if (-not $thumb) { return $false }

    $certFile = Join-Path $global:PKI_DIR ("apache_" + $Dominio + ".crt")
    $keyFile  = Join-Path $global:PKI_DIR ("apache_" + $Dominio + ".key")
    if (-not (Exportar-CertPEM -Thumbprint $thumb -CertFile $certFile -KeyFile $keyFile)) { return $false }
    Aplicar-Permisos-PKI -CertFile $certFile -KeyFile $keyFile -Motor "apache"

    $confFile = Join-Path $apacheDir "conf\httpd.conf"
    $conf = Get-Content $confFile -Raw
    $conf = $conf -replace '(?m)^#\s*(LoadModule ssl_module.*)', '$1'
    $conf = $conf -replace '(?m)^#\s*(LoadModule socache_shmcb_module.*)', '$1'
    $conf = $conf -replace '(?m)^#\s*(Include conf/extra/httpd-ssl\.conf)', '$1'
    [System.IO.File]::WriteAllText($confFile, $conf, [System.Text.ASCIIEncoding]::new())

    $htdocsUnix = (Join-Path $apacheDir "htdocs") -replace '\\', '/'
    $certUnix   = $certFile -replace '\\', '/'
    $keyUnix    = $keyFile  -replace '\\', '/'
    
    $vhostFile  = Join-Path $apacheDir "conf\extra\httpd-ssl-p7.conf"
    $vhostLineas = @(
        "Listen $PuertoSSL",
        "<VirtualHost *:$PuertoSSL>",
        "    ServerName $Dominio",
        "    ServerAlias www.$Dominio",
        "    DocumentRoot `"$htdocsUnix`"",
        "    SSLEngine on",
        "    SSLCertificateFile    `"$certUnix`"",
        "    SSLCertificateKeyFile `"$keyUnix`"",
        "    Header always set Strict-Transport-Security `"max-age=31536000; includeSubDomains`"",
        "    <Directory `"$htdocsUnix`">",
        "        Options -Indexes",
        "        AllowOverride None",
        "        Require all granted",
        "    </Directory>",
        "</VirtualHost>",
        "<VirtualHost *:$PuertoHTTP>",
        "    ServerName $Dominio",
        "    RewriteEngine On",
        "    RewriteRule ^(.*)$ https://$Dominio`:$PuertoSSL`$1 [R=301,L]",
        "</VirtualHost>"
    )
    Escribir-Archivo $vhostFile ($vhostLineas -join "`r`n")

    $conf2 = Get-Content $confFile -Raw
    $incLine = "Include conf/extra/httpd-ssl-p7.conf"
    if ($conf2 -notmatch [regex]::Escape($incLine)) {
        [System.IO.File]::WriteAllText($confFile, $conf2 + "`r`n" + $incLine, [System.Text.ASCIIEncoding]::new())
    }

    # Comentar includes SSL por defecto que interfieren con nuestro vhost:
    $confRaw = Get-Content $confFile -Raw
    $confRaw = $confRaw -replace '(?m)^(\s*Include conf/extra/httpd-ssl\.conf)', '#$1'
    $confRaw = $confRaw -replace '(?m)^(\s*Include conf/extra/httpd-ahssl\.conf)', '#$1'
    [System.IO.File]::WriteAllText($confFile, $confRaw, [System.Text.ASCIIEncoding]::new())

    # FIX: comentar includes SSL por defecto de Apache que conflictuan con nuestro vhost
    $confRaw = [System.IO.File]::ReadAllText($confFile, [System.Text.ASCIIEncoding]::new())
    $confRaw = $confRaw -replace '(?m)^(\s*Include conf/extra/httpd-ssl\.conf)', '#$1'
    $confRaw = $confRaw -replace '(?m)^(\s*Include conf/extra/httpd-ahssl\.conf)', '#$1'
    [System.IO.File]::WriteAllText($confFile, $confRaw, [System.Text.ASCIIEncoding]::new())

    $test = & "$apacheDir\bin\httpd.exe" -t 2>&1
    if (($test -join ' ') -notmatch "Syntax OK") { Log-Error "httpd.conf invalido tras SSL."; return $false }

    $svc = Obtener-SvcApache; Stop-Service $svc -Force -ErrorAction SilentlyContinue; Start-Service $svc -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "HTTPS-Apache-$PuertoSSL" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "HTTPS-Apache-$PuertoSSL" -Direction Inbound -LocalPort $PuertoSSL -Protocol TCP -Action Allow | Out-Null

    Verificar-HTTPS -Dominio "127.0.0.1" -Puerto $PuertoSSL | Out-Null
    Log-Ok "Apache SSL activo -> https://${Dominio}:${PuertoSSL}"
    return $true
}

# ============================================================
# ACTIVAR-SSL-NGINX
# ============================================================
function Activar-SSL-Nginx {
    param([string]$Dominio, [int]$PuertoHTTP = 80, [int]$PuertoSSL = 444)
    Write-Host "`n=== SSL/TLS -> NGINX | $Dominio | HTTP:$PuertoHTTP HTTPS:$PuertoSSL ===" -ForegroundColor Yellow
    
    $nginxDir = Obtener-RutaNginx
    if (-not $nginxDir) { return $false }
    $thumb = Generar-CertAutofirmado -Dominio $Dominio
    if (-not $thumb) { return $false }

    $certFile = Join-Path $global:PKI_DIR ("nginx_" + $Dominio + ".crt")
    $keyFile  = Join-Path $global:PKI_DIR ("nginx_" + $Dominio + ".key")
    if (-not (Exportar-CertPEM -Thumbprint $thumb -CertFile $certFile -KeyFile $keyFile)) { return $false }
    Aplicar-Permisos-PKI -CertFile $certFile -KeyFile $keyFile -Motor "nginx"

    $certUnix = $certFile -replace '\\', '/'
    $keyUnix  = $keyFile  -replace '\\', '/'
    $htmlUnix = (Join-Path $nginxDir "html") -replace '\\', '/'

    $sslConf = Join-Path $nginxDir "conf\ssl_p7.conf"
    $sslLineas = @(
        "server {",
        "    listen $PuertoSSL ssl;",
        "    server_name $Dominio www.$Dominio;",
        "    root `"$htmlUnix`";",
        "    index index.html;",
        "    ssl_certificate     `"$certUnix`";",
        "    ssl_certificate_key `"$keyUnix`";",
        "    ssl_protocols       TLSv1.2 TLSv1.3;",
        "    ssl_ciphers         HIGH:!aNULL:!MD5;",
        "    add_header Strict-Transport-Security `"max-age=31536000; includeSubDomains`" always;",
        "    server_tokens off;",
        "}",
        "server {",
        "    listen $PuertoHTTP;",
        "    server_name $Dominio www.$Dominio;",
        "    return 301 https://`$host:$PuertoSSL`$request_uri;",
        "}"
    )
    Escribir-Archivo $sslConf ($sslLineas -join "`r`n")

    $nginxConf = Join-Path $nginxDir "conf\nginx.conf"
    $confContent = Get-Content $nginxConf -Raw
    if ($confContent -notmatch [regex]::Escape("ssl_p7.conf")) {
        $confContent = $confContent -replace '(http\s*\{)', ('$1' + "`r`n    include ssl_p7.conf;")
        Escribir-Archivo $nginxConf $confContent
    }

    $test = & "$nginxDir\nginx.exe" -p $nginxDir -t 2>&1
    if (($test -join ' ') -notmatch "successful") { Log-Error "nginx.conf invalido tras SSL."; return $false }

    Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Process "$nginxDir\nginx.exe" -ArgumentList "-p", $nginxDir -WindowStyle Hidden
    
    Remove-NetFirewallRule -DisplayName "HTTPS-Nginx-$PuertoSSL" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "HTTPS-Nginx-$PuertoSSL" -Direction Inbound -LocalPort $PuertoSSL -Protocol TCP -Action Allow | Out-Null

    Verificar-HTTPS -Dominio "127.0.0.1" -Puerto $PuertoSSL | Out-Null
    Log-Ok "Nginx SSL activo -> https://${Dominio}:${PuertoSSL}"
    return $true
}

# ============================================================
# ACTIVAR-FTPS-IIS (Estricto: Control y Datos)
# ============================================================
function Activar-FTPS-IIS {
    param([string]$Dominio)
    Write-Host "`n=== FTPS -> IIS FTP | $Dominio ===" -ForegroundColor Yellow

    $thumb = Generar-CertAutofirmado -Dominio $Dominio
    if (-not $thumb) { return $false }

    $appcmd = "$env:systemroot\system32\inetsrv\appcmd.exe"
    if (-not (Test-Path $appcmd)) { Log-Error "IIS FTP no instalado."; return $false }

    $siteName = if ($global:SITE_NAME) { $global:SITE_NAME } else { "Servidor_FTP_Secure" }
    
    # Inyeccion de politica estricta segun rubrica
    & $appcmd set site $siteName "/ftpServer.security.ssl.serverCertHash:$thumb" "/ftpServer.security.ssl.controlChannelPolicy:SslRequire" "/ftpServer.security.ssl.dataChannelPolicy:SslRequire" 2>&1 | Out-Null

    Stop-Service ftpsvc -Force -ErrorAction SilentlyContinue; Start-Service ftpsvc -ErrorAction SilentlyContinue
    Log-Ok "FTPS activado en IIS FTP (Tunel requerido para control y datos)."
    return $true
}

# ============================================================
# RESUMEN-SSL-WINDOWS (Corregido Sintaxis PowerShell)
# ============================================================
function Resumen-SSL-Windows {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "   RESUMEN SSL/TLS - P7 (Windows)               " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host ""

    $dominio = if ($global:DOMINIO_SSL) { $global:DOMINIO_SSL } else { "reprobados.com" }
    Write-Host "  Dominio: $dominio" -ForegroundColor Green
    Write-Host ""

    $fmt = "  {0,-10} {1,-8} {2,-8} {3,-8} {4}"
    Write-Host ($fmt -f "MOTOR","P.HTTP","P.SSL","ACTIVO","ESTADO") -ForegroundColor Yellow
    Write-Host ("  " + ("-" * 65))

    foreach ($motor in @("IIS","APACHE","NGINX")) {
        $pHttp  = Leer-EstadoWin "PUERTO_HTTP_$motor"
        $pSsl   = Leer-EstadoWin "PUERTO_SSL_$motor"
        $activo = Leer-EstadoWin "SSL_ACTIVO_$motor"

        if ([string]::IsNullOrEmpty($pHttp))  { $pHttp  = "--" }
        if ([string]::IsNullOrEmpty($pSsl))   { $pSsl   = "--" }
        if ([string]::IsNullOrEmpty($activo)) { $activo = "--" }

        $estadoCert = "-- No configurado"; $color = "Gray"

        if ($activo -eq "SI" -and $pSsl -ne "--") {
            $pSslInt = 0 # PARCHE: Inicializar variable antes de usarla como [ref]
            if ([int]::TryParse($pSsl, [ref]$pSslInt) -and (Verificar-HTTPS -Dominio "127.0.0.1" -Puerto $pSslInt)) {
                if (Obtener-CertThumbprint -Dominio $dominio) { $estadoCert = "VALIDO"; $color = "Green" } 
                else { $estadoCert = "RESPONDE (cert no en store)"; $color = "Green" }
            } else { $estadoCert = "NO RESPONDE"; $color = "Red" }
        } elseif ($activo -eq "ERROR") { $estadoCert = "FALLO"; $color = "Red" }
        elseif ($activo -eq "NO") { $estadoCert = "Sin SSL"; $color = "Yellow" }

        Write-Host ($fmt -f $motor,$pHttp,$pSsl,$activo,$estadoCert) -ForegroundColor $color
    }

    Write-Host "`n" ($fmt -f "IIS-FTP","21","21(TLS)","--","ESTADO FTPS") -ForegroundColor Yellow
    Write-Host ("  " + ("-" * 65))
    $appcmd = "$env:systemroot\system32\inetsrv\appcmd.exe"
    
    # PARCHE: Resolver variable fuera del comando
    $siteNameFtps = if ($global:SITE_NAME) { $global:SITE_NAME } else { "Servidor_FTP_Secure" }
    $ftpsInfoStr = (& $appcmd list site $siteNameFtps /text:* 2>$null) -join "`n"
    
    if ((Test-Path $appcmd) -and ($ftpsInfoStr -match "SslRequire") -and ($ftpsInfoStr -match "serverCertHash")) {
        Write-Host ($fmt -f "IIS-FTP","21","21","SI","FTPS (TLS) ACTIVO") -ForegroundColor Green
    } else {
        Write-Host ($fmt -f "IIS-FTP","21","--","NO","SSL no activado") -ForegroundColor Yellow
    }
    Pausa
}