[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::ResetColor()
[Console]::Clear()

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Este script debe ser ejecutado como Administrador." -ForegroundColor Red
    exit
}

function log_ok { param($Msg) Write-Host "[OK] $Msg" -ForegroundColor Green }
function log_info { param($Msg) Write-Host "[INFO] $Msg" -ForegroundColor Cyan }
function log_error { param($Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function log_warning { param($Msg) Write-Host "[WARNING] $Msg" -ForegroundColor Yellow }

function Pausa {
    Write-Host ""
    Read-Host "Presione [Enter] para continuar..."
    [Console]::Clear()
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

    return $Objetivo 
}

function Get-IPFormato {
    param([string]$IP)
    $IPAddress = $null
    
    if (-not [System.Net.IPAddress]::TryParse($IP, [ref]$IPAddress)) { return $false }

    if ($IPAddress.ToString() -eq "0.0.0.0") { return $false }
    if ($IPAddress.ToString() -eq "255.255.255.255"){ return $false }
    if ($IPAddress.GetAddressBytes()[0] -ge 224) { return $false }
    if ($IPAddress.GetAddressBytes()[0] -eq 127) { return $false }
    
    return $true
}

function Test-IPRango {
    param([string]$Inicio, [string]$Fin)
    try {
        $OctInicio = $Inicio.Split(".")
        $OctFin = $Fin.Split(".")

        if ("$($OctInicio[0]).$($OctInicio[1]).$($OctInicio[2])" -ne "$($OctFin[0]).$($OctFin[1]).$($OctFin[2])") {
            log_error "Las IPs deben estar en el mismo segmento de red."
            return $false
        }

        if ([int]$OctFin[3] -gt [int]$OctInicio[3]) { return $true }
    } catch {
        return $false
    }
    return $false
}

function Preparar-Red {
    param($InterfazAlias)
    $ServerIP = "192.168.100.10"
    $Mascara = 24
    
    log_info "Asignando IP fija $ServerIP/$Mascara a la interfaz $InterfazAlias..."

    try {
        Remove-NetIPAddress -InterfaceAlias $InterfazAlias -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceAlias $InterfazAlias -IPAddress $ServerIP -PrefixLength $Mascara -Confirm:$false -ErrorAction Stop | Out-Null
        Set-NetIPInterface -InterfaceAlias $InterfazAlias -Dhcp Disabled 
        
        log_ok "IP fija asignada correctamente."
    } catch {
        log_error "Error al asignar la IP fija: $_"
        exit
    }
}