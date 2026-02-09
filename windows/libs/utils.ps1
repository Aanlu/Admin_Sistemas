function log_ok { param($Msg) Write-Host "[OK] $Msg" -ForegroundColor Green }
function log_info { param($Msg) Write-Host "[INFO] $Msg" -ForegroundColor Cyan }
function log_error { param($Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function log_warning { param($Msg) Write-Host "[WARNING] $Msg" -ForegroundColor Yellow }

function Pausa {
    Read-Host "Presione [Enter] para continuar..."
}

function Get-InterfazInterna {
    $RutaNat = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
    $IndiceNat = if ($RutaNat) { $RutaNat.InterfaceIndex } else { -1 }

    $Objetivo = Get-NetAdapter | Where-Object {
        $_.Status -eq "Up" -and
        $_.InterfaceIndex -ne $IndiceNat -and
        $_.Name -notmatch "Loopback"
    } | Select-Object -First 1

    if (-not $Objetivo) {
        $Objetivo = Get-NetAdapter | Where-Object { $_.Name -match "Ethernet 2" -or $_.Name -match "Ethernet 3" } | Select-Object -First 1
    }

    if ($Objetivo){
        return $Objetivo 
    } else {
        return $null
    }
}

function Get-IPFormato {
    param([string]$IP)
    if ($IP -match "^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$"){
        $Octetos = $IP.Split(".")
        foreach ($Oct in $Octetos){
            if ([int]$Oct -lt 0 -or [int]$Oct -gt 255) { return $false }
        }
        return $true
    }
    return $false
}

function Test-IPRango {
    param([string]$Inicio, [string]$Fin)
    try {
        $UltInicio = [int]($Inicio.Split(".")[3])
        $UltFin = [int]($Fin.Split(".")[3])

        if ($UltFin -gt $UltInicio) { return $true }
    } catch {
        return $false
    }
    return $false
}

function Preparar-Red {
    param($InterfazAlias)
    $ServerIP = "192.168.100.20"
    $Mascara = 24
    
    log_info "Asignando IP fija $ServerIP/$Mascara a la interfaz $InterfazAlias..."

    try {
        Remove-NetIPAddress -InterfaceAlias $InterfazAlias -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceAlias $InterfazAlias -IPAddress $ServerIP -PrefixLength $Mascara -ErrorAction Stop | Out-Null
        Set-NetIPInterface -InterfaceAlias $InterfazAlias -Dhcp Disabled 
        
        log_ok "IP fija asignada correctamente."
    } catch {
        log_error "Error al asignar la IP fija: $_"
        exit
    }
}