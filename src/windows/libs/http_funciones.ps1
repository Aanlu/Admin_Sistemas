function Extraer-VersionesDinamicas {
    param([string]$Motor)

    # CORREGIDO: usar return explícito con array en lugar de Write-Output
    # para garantizar tipo consistente y validación confiable en el caller

    if ($Motor -eq "iis") {
        $os = (Get-CimInstance Win32_OperatingSystem).Version
        return @("$os (LTS - Nativo del Kernel)")
    }

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        $ProgressPreference = 'SilentlyContinue'
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }

    $paquete = if ($Motor -eq "apache") { "apache-httpd" } else { "nginx" }
    $versiones = choco search $paquete --exact --all | Select-String -Pattern "^$paquete\s+([\d\.]+)" | ForEach-Object { $_.Matches.Groups[1].Value }

    if (-not $versiones -or $versiones.Count -eq 0) { return @() }

    $latest = $versiones[0]
    $oldest = $versiones[-1]
    $lts    = if ($versiones.Count -ge 3) { $versiones[2] } else { $latest }

    $resultado = @()
    if ($lts)                                                        { $resultado += "$lts (LTS)" }
    if ($latest -and $latest -ne $lts)                               { $resultado += "$latest (Latest)" }
    if ($oldest -and $oldest -ne $lts -and $oldest -ne $latest)      { $resultado += "$oldest (Oldest)" }

    return $resultado
}

function Validar-PuertoTCP {
    param([int]$Puerto)

    if ($Puerto -in @(21, 22, 53, 135, 139, 445, 3389)) { return 2 }
    $enUso = Get-NetTCPConnection -LocalPort $Puerto -ErrorAction SilentlyContinue
    if ($enUso) { return 1 }
    return 0
}

function Instalar-PaquetesWeb {
    param([string]$Motor, [string]$Version)

    $ProgressPreference = 'SilentlyContinue'

    if ($Motor -eq "iis") {
        Instalar-DependenciaSilenciosa "Web-Server" | Out-Null
        Instalar-DependenciaSilenciosa "Web-Mgmt-Tools" | Out-Null
        return $true
    }

    $paquete = if ($Motor -eq "apache") { "apache-httpd" } else { "nginx" }
    choco install $paquete --version $Version -y --force --no-progress | Out-Null
    return $?
}

function Configurar-PuertoServicio {
    param([string]$Motor, [int]$Puerto)

    if ($Motor -eq "iis") {
        Import-Module WebAdministration
        Set-ItemProperty -Path "IIS:\Sites\Default Web Site" -Name Bindings -Value @(@{protocol = "http"; bindingInformation = "*:$Puerto:" })
        Restart-Service W3SVC -Force
    }
    elseif ($Motor -eq "apache") {
        $confPath = "C:\tools\apache24\conf\httpd.conf"
        if (Test-Path $confPath) {
            (Get-Content $confPath) -replace "^Listen \d+", "Listen $Puerto" | Set-Content $confPath
        }
        Restart-Service apache -ErrorAction SilentlyContinue
    }
    elseif ($Motor -eq "nginx") {
        $confPath = "C:\tools\nginx\conf\nginx.conf"
        if (Test-Path $confPath) {
            (Get-Content $confPath) -replace "listen\s+\d+;", "listen       $Puerto;" | Set-Content $confPath
        }
        $nginxProc = Get-Process nginx -ErrorAction SilentlyContinue
        if ($nginxProc) { $nginxProc | Stop-Process -Force }
        Start-Process -FilePath "C:\tools\nginx\nginx.exe" -WorkingDirectory "C:\tools\nginx" -WindowStyle Hidden
    }

    New-NetFirewallRule -DisplayName "HTTP-$Motor-$Puerto" -Direction Inbound -LocalPort $Puerto -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    return $true
}

function Aplicar-HardeningSeguridad {
    param([string]$Motor)

    if ($Motor -eq "iis") {
        Import-Module WebAdministration
        Remove-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "collection" -AtElement @{name = 'X-Powered-By' } -ErrorAction SilentlyContinue
        Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "collection" -value @{name = 'X-Frame-Options'; value = 'SAMEORIGIN' } -ErrorAction SilentlyContinue
        Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/httpProtocol/customHeaders" -name "collection" -value @{name = 'X-Content-Type-Options'; value = 'nosniff' } -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering" -name "removeServerHeader" -value "true" -ErrorAction SilentlyContinue
    }
    elseif ($Motor -eq "apache") {
        $confPath = "C:\tools\apache24\conf\httpd.conf"
        if (Test-Path $confPath) {
            $conf = Get-Content $confPath
            if (-not ($conf -match "ServerTokens Prod")) {
                Add-Content -Path $confPath -Value "`nServerTokens Prod`nServerSignature Off`nHeader always append X-Frame-Options SAMEORIGIN`nHeader always append X-Content-Type-Options nosniff"
            }
        }
        Restart-Service apache -ErrorAction SilentlyContinue
    }
}

function Aislar-DirectorioWeb {
    param([string]$Motor)

    $rutaHtml = ""
    if ($Motor -eq "iis")    { $rutaHtml = "C:\inetpub\wwwroot" }
    elseif ($Motor -eq "apache") { $rutaHtml = "C:\tools\apache24\htdocs" }
    elseif ($Motor -eq "nginx")  { $rutaHtml = "C:\tools\nginx\html" }

    if (-not $rutaHtml) { return }

    $Acl = Get-Acl $rutaHtml
    $Acl.SetAccessRuleProtection($true, $false)
    $SidSys = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $SidAdm = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($SidSys, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
    $Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($SidAdm, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
    Set-Acl -Path $rutaHtml -AclObject $Acl
}

function Desplegar-PlantillaHTML {
    param([string]$Motor, [string]$Version, [int]$Puerto)

    $rutaHtml = ""
    if ($Motor -eq "iis")    { $rutaHtml = "C:\inetpub\wwwroot\index.html" }
    elseif ($Motor -eq "apache") { $rutaHtml = "C:\tools\apache24\htdocs\index.html" }
    elseif ($Motor -eq "nginx")  { $rutaHtml = "C:\tools\nginx\html\index.html" }

    if (-not $rutaHtml) { return }

    $rutaTemplate = "..\..\templates\linux\index.web.template"
    if (Test-Path $rutaTemplate) {
        (Get-Content $rutaTemplate) -replace "@@MOTOR@@", $Motor.ToUpper() -replace "@@VERSION@@", $Version -replace "@@PUERTO@@", $Puerto | Set-Content -Path $rutaHtml -Encoding UTF8
    }
    else {
        "<h1>Servidor: $($Motor.ToUpper()) - Version: $Version - Puerto: $Puerto</h1>" | Set-Content -Path $rutaHtml -Encoding UTF8
    }
}