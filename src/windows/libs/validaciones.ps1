function Validar-Formato-IP {
    param([string]$ip)
    
    if ($ip -notmatch "^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$") { 
        return $false 
    }
    $octetos = $ip.Split('.')
    foreach ($oct in $octetos) {
        if ([int]$oct -lt 0 -or [int]$oct -gt 255) { return $false }
    }

    $ipsProhibidas = @("0.0.0.0", "255.255.255.255", "127.0.0.0", "127.0.0.1")
    
    $ip_limpia = "{0}.{1}.{2}.{3}" -f [int]$octetos[0], [int]$octetos[1], [int]$octetos[2], [int]$octetos[3]

    if ($ipsProhibidas -contains $ip_limpia) { return $false }
    
    return $true
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