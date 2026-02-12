function Log-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Log-Ok { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Log-Error { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Log-Warning { param($msg) Write-Host "[AVISO] $msg" -ForegroundColor Yellow }

function Pausa {
    Write-Host "Presione cualquier tecla para continuar..." -NoNewline
    [void][System.Console]::ReadKey($true)
    Write-Host ""
}

function Detectar-Interfaz {
    $iface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notlike "*Loopback*" } | Select-Object -First 1
    if ($iface) { return $iface }
    return $null
}

function Validar-Formato-IP {
    param($ip)
    if ([System.Net.IPAddress]::TryParse($ip, [ref]$null)) {
        if ($ip -eq "0.0.0.0" -or $ip -eq "255.255.255.255") { return $false }
        return $true
    }
    return $false
}

function Validar-Rango {
    param($ip1, $ip2)
    
    $red1 = $ip1.Substring(0, $ip1.LastIndexOf('.'))
    $red2 = $ip2.Substring(0, $ip2.LastIndexOf('.'))

    if ($red1 -ne $red2) {
        Log-Error "Las IPs deben estar estrictamente en el mismo segmento ($red1.x)."
        return $false
    }

    $host1 = [int]($ip1.Split('.')[-1])
    $host2 = [int]($ip2.Split('.')[-1])

    if ($host2 -le $host1) {
        Log-Error "La IP final ($ip2) debe ser mayor que la inicial ($ip1)."
        return $false
    }
    return $true
}

function Obtener-Mascara {
    param($ip)
    $primerOcteto = [int]($ip.Split('.')[0])
    
    if ($primerOcteto -ge 1 -and $primerOcteto -le 126) { return "255.0.0.0" }
    elseif ($primerOcteto -ge 128 -and $primerOcteto -le 191) { return "255.255.0.0" }
    else { return "255.255.255.0" }
}

function Incrementar-IP {
    param($ip)
    $parts = $ip.Split('.') | ForEach-Object { [int]$_ }
    $a = $parts[0]; $b = $parts[1]; $c = $parts[2]; $d = $parts[3]

    $d++
    if ($d -gt 255) {
        $d = 0; $c++
        if ($c -gt 255) {
            $c = 0; $b++
            if ($b -gt 255) {
                $b = 0; $a++
            }
        }
    }
    return "$a.$b.$c.$d"
}