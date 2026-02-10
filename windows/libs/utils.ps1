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

function Configurar {
    [Console]::Clear()
    $NombreAmbito = $null; $IPInicio = $null; $IPFin = $null; 
    $PuertaEnlace = $null; $ServidorDNS = $null; $TiempoConcesion = $null

    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "                SERVIDOR DHCP " -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan

    $Interfaz = Get-InterfazInterna
    if (-not $Interfaz) {
        log_error "No se detectó una interfaz de red interna adecuada."
        Pausa; return
    }

    log_info "Interfaz detectada: $($Interfaz.Name)"
    Preparar-Red -InterfazAlias $Interfaz.Name

    Write-Host "1) Automatico"
    Write-Host "2) Manual"
    $Opcion = Read-Host "Opción (1/2)"

    if ($Opcion -eq "1") {
        log_info "Modo Automático."
        $NombreAmbito  = "Red_Sistemas"
        $IPInicio      = "192.168.100.50"
        $IPFin         = "192.168.100.150"
        $PuertaEnlace  = "192.168.100.1"
        $ServidorDNS   = "192.168.100.10"
        $TiempoConcesion = New-TimeSpan -Minutes 10
    } else {
        log_info "Modo Manual."
        $NombreAmbito = Read-Host "Nombre del Ámbito"
        do { $IPInicio = Read-Host "IP Inicial" } until (Get-IPFormato $IPInicio)
        do { $IPFin = Read-Host "IP Final" } until (Get-IPFormato $IPFin -and (Test-IPRango $IPInicio $IPFin))
        $PuertaEnlace = Read-Host "Gateway"
        $ServidorDNS = Read-Host "DNS"
        $Segundos = Read-Host "Tiempo (segundos)"
        $TiempoConcesion = New-TimeSpan -Seconds ([int]$Segundos)
    }

    $Octetos = $IPInicio.Split(".")
    $ScopeID = "$($Octetos[0]).$($Octetos[1]).$($Octetos[2]).0"

    Write-Host ""
    log_info "Verificando dependencias..."
    
    if (-not (Get-WindowsFeature -Name DHCP).Installed) { Install-WindowsFeature DHCP -IncludeManagementTools | Out-Null }
    if (-not (Get-WindowsFeature -Name DNS).Installed) { Install-WindowsFeature DNS -IncludeManagementTools | Out-Null }

    log_info "Configurando DHCP para red: $ScopeID ..."

    try {
        $ScopesViejos = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        if ($ScopesViejos) {
            $ScopesViejos | Remove-DhcpServerv4Scope -Force
        }

        Add-DhcpServerv4Scope -Name $NombreAmbito -StartRange $IPInicio -EndRange $IPFin -SubnetMask 255.255.255.0 -State Active -LeaseDuration $TiempoConcesion
        
        Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 3 -Value $PuertaEnlace
        Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 6 -Value $ServidorDNS -Force -ErrorAction SilentlyContinue
        
        Restart-Service dhcpserver
        log_ok "Servidor configurado correctamente."

    } catch {
        log_error "Error crítico: $_"
    }
    Pausa
}

function Monitorear {
    [Console]::Clear()
    Write-Host "   --- Estado del Servidor ---" -ForegroundColor Cyan
    
    if ((Get-Service dhcpserver).Status -eq "Running") {
        log_ok "Estado: Activo"
    } else {
        log_error "Estado: Inactivo"
    }

    $ScopeInfo = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if ($ScopeInfo) {
        $ID = $ScopeInfo.ScopeId.IPAddressToString

        Write-Host "    --- DETALLES DEL ÁMBITO ($ID) ---" -ForegroundColor Yellow
        Write-Host "Nombre:       $($ScopeInfo.Name)"
        Write-Host "Rango:        $($ScopeInfo.StartRange) - $($ScopeInfo.EndRange)"
        Write-Host "Máscara:      $($ScopeInfo.SubnetMask)"
        Write-Host "Lease Time:   $($ScopeInfo.LeaseDuration)"
        
        $Gw = (Get-DhcpServerv4OptionValue -ScopeId $ID -OptionId 3 -ErrorAction SilentlyContinue).Value
        $Dns = (Get-DhcpServerv4OptionValue -ScopeId $ID -OptionId 6 -ErrorAction SilentlyContinue).Value
        
        Write-Host "Gateway:      $Gw"
        Write-Host "DNS:          $Dns"

        Write-Host ""
        Write-Host "   --- Clientes DHCP Actuales ---" -ForegroundColor Cyan
        $Concesiones = Get-DhcpServerv4Lease -ScopeId $ID -ErrorAction SilentlyContinue

        if ($Concesiones) {
            $Concesiones | Select-Object @{N='IP Cliente';E={$_.IPAddress}}, @{N='MAC';E={$_.ClientId}}, @{N='Hostname';E={$_.HostName}} | Format-Table -AutoSize
        } else {
            Write-Host "No hay clientes conectados."
        }
    } else {
        log_warning "No hay ámbitos configurados. Ejecuta la opción 1 primero."
    }
    Pausa
}

while ($true) {
    [Console]::Clear()
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "                SERVIDOR DHCP" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "1) Configurar Servidor"
    Write-Host "2) Monitorear Clientes"
    Write-Host "3) Salir"
    
    $Seleccion = Read-Host "Seleccione una opción (1-3)"
    
    switch ($Seleccion) {
        "1" { Configurar }
        "2" { Monitorear }
        "3" { log_info "Saliendo..."; exit }
        default { log_error "Opción no válida."; Start-Sleep -Seconds 1 }
    }
}