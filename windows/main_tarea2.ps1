[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::ResetColor()
[Console]::Clear()

$RutaScript = Split-Path $MyInvocation.MyCommand.Path
. "$RutaScript\libs\Utils.ps1"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    log_error "Este script debe ser ejecutado como Administrador."
    exit
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
        $TiempoConcesion = New-TimeSpan -Seconds 600 
        Start-Sleep -Seconds 1
    } else {
        log_info "Modo Manual."
        $NombreAmbito = Read-Host "Nombre del Ámbito"
        
        do { 
            $IPInicio = Read-Host "IP Inicial" 
            if (-not (Get-IPFormato $IPInicio)) { log_error "IP Inválida o Reservada." }
        } until (Get-IPFormato $IPInicio)
        
        do { 
            $IPFin = Read-Host "IP Final" 
            $Valida = Get-IPFormato $IPFin
            $Rango  = Test-IPRango $IPInicio $IPFin
        } until ($Valida -and $Rango)
        
        do { $PuertaEnlace = Read-Host "Gateway" } until (Get-IPFormato $PuertaEnlace)
        do { $ServidorDNS = Read-Host "DNS" } until (Get-IPFormato $ServidorDNS)

        $Segundos = Read-Host "Tiempo (segundos)"
        if ($Segundos -notmatch "^\d+$") { $Segundos = 600 }
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
        
        try {
            Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 6 -Value $ServidorDNS -ErrorAction Stop
        } catch {
            Set-DhcpServerv4OptionValue -ScopeId $ScopeID -OptionId 6 -Value $ServidorDNS -ErrorAction SilentlyContinue
        }
        
        Restart-Service dhcpserver -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        log_ok "Servidor configurado correctamente."

    } catch {
        log_error "Error crítico: $_"
    }
    Pausa
}

function Monitorear {
    while ($true) {
        [Console]::Clear()
        Write-Host "   --- Estado del Servidor (Tiempo Real) ---" -ForegroundColor Cyan
        Write-Host "       [Presione 'X' para Salir]" -ForegroundColor DarkGray
        Write-Host "   -----------------------------------------" -ForegroundColor Cyan
        Write-Host ""

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
                Write-Host "No hay clientes conectados." -ForegroundColor DarkGray
            }
        } else {
            log_warning "No hay ámbitos configurados. Ejecuta la opción 1 primero."
        }
        
        for ($i = 0; $i -lt 20; $i++) {
            if ([Console]::KeyAvailable) {
                $Key = [Console]::ReadKey($true)
                if ($Key.Key -eq "X") {
                    return 
                }
            }
            Start-Sleep -Milliseconds 100
        }
    }
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