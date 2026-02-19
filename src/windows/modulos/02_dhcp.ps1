. .\libs\utils.ps1
. .\libs\validaciones.ps1

if (-not (Instalar-DependenciaSilenciosa "DHCP")) { return }

function Seleccionar-Interfaz {
    $interfaces = Get-NetAdapter | Where-Object { $_.Virtual -eq $false -and $_.InterfaceDescription -notlike "*Loopback*" }
    if ($interfaces.Count -eq 0) { Log-Error "No hay interfaces fisicas activas."; return $null }
    
    Write-Host "`n--- SELECCIÓN DE INTERFAZ ---" -ForegroundColor Cyan
    for ($i=0; $i -lt $interfaces.Count; $i++) {
        Write-Host "[$i] $($interfaces[$i].Name) | Desc: $($interfaces[$i].InterfaceDescription)"
    }
    
    while ($true) {
        $sel = Read-Host "Seleccione interfaz"
        if ($sel -match "^\d+$" -and [int]$sel -lt $interfaces.Count) { return $interfaces[[int]$sel] }
        Log-Error "Selección inválida."
    }
}

function Configurar-DHCP {
    Clear-Host
    
    $adapter = Seleccionar-Interfaz
    if (-not $adapter) { Pausa; return }
    $ALIAS = $adapter.Name

    Write-Host "`n--- CONFIGURACIÓN DEL ÁMBITO DHCP ---" -ForegroundColor Yellow
    $SCOPE_NAME = Read-Host "Nombre del Ámbito (Scope)"
    if ([string]::IsNullOrWhiteSpace($SCOPE_NAME)) { $SCOPE_NAME = "Scope_Default" }

    $IP_INICIAL = Capturar-IP "IP Inicial (Se asignara al Servidor)"
    
    while ($true) {
        $IP_FINAL = Capturar-IP "IP Final del rango"
        if (Validar-Rango $IP_INICIAL $IP_FINAL) { break }
        Log-Error "Rango incorrecto. Revise el segmento."
    }

    $MASCARA = Obtener-Mascara $IP_INICIAL
    $SUBNET_ID = Obtener-ID-Red $IP_INICIAL $MASCARA
    
    $CIDR = 24
    if ($MASCARA -eq "255.0.0.0") { $CIDR = 8 }
    elseif ($MASCARA -eq "255.255.0.0") { $CIDR = 16 }

    $IP_RANGO_INICIO = Incrementar-IP $IP_INICIAL

    $GW = Capturar-IP "Gateway"
    $DNS = Capturar-IP "Servidor DNS principal"

    while ($true) {
        $LEASE_STR = Read-Host "Tiempo de concesión (segundos)"
        if ($LEASE_STR -match "^\d+$" -and [int]$LEASE_STR -gt 0) { 
            $LEASE_TIME = [int]$LEASE_STR
            break 
        }
        Log-Error "Debe ser un número entero positivo."
    }

    try {
        Set-NetIPInterface -InterfaceAlias $ALIAS -Dhcp Disabled -AddressFamily IPv4 -ErrorAction SilentlyContinue
        Remove-NetIPAddress -InterfaceAlias $ALIAS -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceAlias $ALIAS -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        
        New-NetIPAddress -InterfaceAlias $ALIAS -IPAddress $IP_INICIAL -PrefixLength $CIDR -DefaultGateway $GW -ErrorAction Stop | Out-Null
        
        Disable-NetAdapter -Name $ALIAS -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Enable-NetAdapter -Name $ALIAS -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 4

        $scopeCheck = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        if ($scopeCheck) { 
            $scopeCheck | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue 
        }

        $timespan = New-TimeSpan -Seconds $LEASE_TIME
        Add-DhcpServerv4Scope -Name $SCOPE_NAME -StartRange $IP_RANGO_INICIO -EndRange $IP_FINAL -SubnetMask $MASCARA -State Active -LeaseDuration $timespan -ErrorAction Stop | Out-Null
        
        Set-DhcpServerv4OptionValue -ScopeId $SUBNET_ID -OptionId 3 -Value $GW -ErrorAction SilentlyContinue
        Set-DhcpServerv4OptionValue -ScopeId $SUBNET_ID -OptionId 6 -Value $DNS -ErrorAction SilentlyContinue
        Set-DhcpServerv4OptionValue -ScopeId $SUBNET_ID -OptionId 15 -Value $SCOPE_NAME -ErrorAction SilentlyContinue

        Remove-NetFirewallRule -DisplayName "DHCP-Allow" -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "DHCP-Allow" -Direction Inbound -LocalPort 67,68 -Protocol UDP -Action Allow | Out-Null
        
        Restart-Service DHCPServer -Force
        Start-Sleep -Seconds 2
        Set-DhcpServerv4Binding -InterfaceAlias $ALIAS -BindingState $true -ErrorAction Stop
        Restart-Service DHCPServer -Force
        
        Log-Ok "Servicio Configurado y ACTIVO."
    } catch {
        Log-Error "Fallo en configuracion: $($_.Exception.Message)"
    }
    Pausa
}

function Alternar-Servicio {
    Clear-Host
    $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
    
    if ($svc.Status -eq "Running") {
        Stop-Service DHCPServer -Force
        Log-Warning "Servicio DHCP detenido manualmente."
    } else {
        Start-Service DHCPServer
        Log-Ok "Servicio DHCP iniciado."
    }
    Pausa
}

function Menu-DHCP {
    $OpcionesDHCP = @(
        "Configurar Ámbito DHCP",
        "Alternar Estado del Servicio (Start/Stop)"
    )
    
    while ($true) {
        $Eleccion = Generar-Menu "MÓDULO DE GESTIÓN DHCP" $OpcionesDHCP "Volver al Menú Principal"
        
        switch ($Eleccion) {
            0 { Configurar-DHCP }
            1 { Alternar-Servicio }
            2 { return }
        }
    }
}

Menu-DHCP