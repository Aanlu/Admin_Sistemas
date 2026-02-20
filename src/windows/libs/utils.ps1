$global:LOG_FILE = "..\..\logs\windows_services.log"

function Log-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Log-Ok { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Log-Error { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Log-Warning { param($msg) Write-Host "[AVISO] $msg" -ForegroundColor Yellow }

function Pausa {
    Write-Host "`nPresione [Enter] para continuar..." -ForegroundColor Cyan
    Read-Host | Out-Null
}

function Instalar-DependenciaSilenciosa {
    param([string]$FeatureName)
    
    $check = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
    if ($check.Installed) { return $true }

    Write-Host "[AVISO] Instalando dependencia requerida: $FeatureName..." -ForegroundColor Yellow
    
    try {
        Install-WindowsFeature -Name $FeatureName -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Host "`e[1A`e[K[OK] Dependencia lista: $FeatureName" -ForegroundColor Green
        return $true
    } catch {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] CRÍTICO: Fallo al instalar $FeatureName. Detalle: $($_.Exception.Message)" | Out-File -FilePath $global:LOG_FILE -Append
        Write-Host "`e[1A`e[K[ERROR] Fallo al instalar: $FeatureName. Revise $global:LOG_FILE" -ForegroundColor Red
        return $false
    }
}

function Generar-Menu {
    param(
        [string]$Titulo,
        [string[]]$Opciones,
        [string]$TextoSalida
    )
    
    $MenuOpciones = $Opciones + $TextoSalida
    $Seleccion = 0

    while ($true) {
        Clear-Host
        Write-Host "================================================="
        Write-Host "                $Titulo" -ForegroundColor Yellow
        Write-Host "================================================="
        
        for ($i=0; $i -lt $MenuOpciones.Count; $i++) {
            if ($i -eq $Seleccion) {
                Write-Host "> $($MenuOpciones[$i]) " -BackgroundColor Green -ForegroundColor Black
            } else {
                Write-Host "  $($MenuOpciones[$i])"
            }
        }
        
        $key = [System.Console]::ReadKey($true)
        if ($key.Key -eq "UpArrow") { 
            $Seleccion--
            if ($Seleccion -lt 0) { $Seleccion = $MenuOpciones.Count - 1 }
        } elseif ($key.Key -eq "DownArrow") { 
            $Seleccion++
            if ($Seleccion -ge $MenuOpciones.Count) { $Seleccion = 0 }
        } elseif ($key.Key -eq "Enter") {
            return $Seleccion
        }
    }
}

function Confirmar-Accion {
    param([string]$mensaje)
    $opciones = @("Sí, proceder con la acción")
    $eleccion = Generar-Menu "CONFIRMACIÓN: $mensaje" $opciones "No, cancelar y volver"
    if ($eleccion -eq 0) { return $true } else { return $false }
}

function Obtener-IP-Local {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.InterfaceAlias -notmatch "vEthernet" } | Select-Object -First 1 -ExpandProperty IPAddress
    return $ip
}

function Capturar-IP {
    param([string]$Mensaje)
    
    $ip_local = Obtener-IP-Local
    
    while ($true) {
        Write-Host "$Mensaje [Enter para usar: $($ip_local -join '')]: " -NoNewline
        $input_ip = Read-Host
        
        if ([string]::IsNullOrWhiteSpace($input_ip) -and $ip_local) {
            $input_ip = $ip_local
        }
        
        if (Validar-Formato-IP $input_ip) {
            return $input_ip
        } else {
            Log-Error "IP inválida o prohibida. Intente de nuevo."
        }
    }
}

function Capturar-IP-Opcional {
    param([string]$Mensaje)
    
    while ($true) {
        Write-Host "$Mensaje [Enter para omitir]: " -NoNewline
        $input_ip = Read-Host
        
        if ([string]::IsNullOrWhiteSpace($input_ip)) { return "" }
        if (Validar-Formato-IP $input_ip) { return $input_ip }
        Log-Error "IP inválida o prohibida. Intente de nuevo o presione Enter para omitir."
    }
}

function Validar-Formato-IP {
    param($ip)
    $ipsProhibidas = @("0.0.0.0", "255.255.255.255", "127.0.0.0", "127.0.0.1")
    if ([System.Net.IPAddress]::TryParse($ip, [ref]$null)) {
        if ($ipsProhibidas -contains $ip) { return $false }
        return $true
    }
    return $false
}

function Validar-Rango {
    param($ip1, $ip2)
    $red1 = $ip1.Substring(0, $ip1.LastIndexOf('.'))
    $red2 = $ip2.Substring(0, $ip2.LastIndexOf('.'))
    if ($red1 -ne $red2) { return $false }
    $host1 = [int]($ip1.Split('.')[3])
    $host2 = [int]($ip2.Split('.')[3])
    if ($host2 -le $host1) { return $false }
    return $true
}

function Incrementar-IP {
    param($ip)
    $parts = $ip.Split('.') | ForEach-Object { [int]$_ }
    $parts[3]++
    if ($parts[3] -gt 255) {
        $parts[3] = 0; $parts[2]++
        if ($parts[2] -gt 255) {
            $parts[2] = 0; $parts[1]++
            if ($parts[1] -gt 255) { $parts[1] = 0; $parts[0]++ }
        }
    }
    return "{0}.{1}.{2}.{3}" -f $parts[0], $parts[1], $parts[2], $parts[3]
}

function Obtener-Mascara {
    param($ip)
    $firstOctet = [int]($ip.Split('.')[0])
    if ($firstOctet -ge 1 -and $firstOctet -le 126) { return "255.0.0.0" }
    elseif ($firstOctet -ge 128 -and $firstOctet -le 191) { return "255.255.0.0" }
    else { return "255.255.255.0" }
}

function Obtener-ID-Red {
    param($ip, $mask)
    $ipBytes = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
    $maskBytes = ([System.Net.IPAddress]::Parse($mask)).GetAddressBytes()
    $netBytes = [byte[]]::new(4)
    for($i=0; $i -lt 4; $i++) { $netBytes[$i] = $ipBytes[$i] -band $maskBytes[$i] }
    return ([System.Net.IPAddress]::new($netBytes)).IPAddressToString
}