. .\libs\utils.ps1
. .\libs\validaciones.ps1
. .\libs\seguridad.ps1

function Gestionar-Instalacion {
    Clear-Host
    Write-Host "--- GESTIÓN DE INSTALACIÓN ---" -ForegroundColor Yellow
    
    $check = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    if ($check.Installed) {
        Log-Ok "El servicio DHCP ya se encuentra instalado."
        
        if (Confirmar-Accion "¿Desea realizar una REINSTALACIÓN completa (borrará configuraciones)?") {
            Write-Host "[AVISO] Purgando y reinstalando el servicio silenciosamente..." -ForegroundColor Yellow
            Remove-WindowsFeature -Name DHCP -Remove -ErrorAction SilentlyContinue | Out-Null
            Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
            Write-Host "`e[1A`e[K[OK] Reinstalación limpia finalizada correctamente." -ForegroundColor Green
        } else {
            Log-Warning "Acción cancelada por el usuario."
        }
    } else {
        Log-Warning "Dependencias DHCP NO encontradas."
        if (Confirmar-Accion "¿Desea instalar el servicio DHCP ahora?") {
            Instalar-DependenciaSilenciosa "DHCP" | Out-Null
        } else {
            Log-Warning "Instalación cancelada."
        }
    }
    Pausa
}

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
    if (-not (Get-WindowsFeature -Name DHCP).Installed) {
        Log-Error "El servicio no está instalado. Ejecute 'Gestión de Instalación' primero."
        Pausa; return
    }

    $adapter = Seleccionar-Interfaz
    if (-not $adapter) { Pausa; return }
    $ALIAS = $adapter.Name

    Write-Host "`n--- CONFIGURACIÓN DEL ÁMBITO DHCP ---" -ForegroundColor Yellow
    $SCOPE_NAME = Read-Host "Nombre del Ámbito (Scope)"
    if ([string]::IsNullOrWhiteSpace($SCOPE_NAME)) { $SCOPE_NAME = "Scope_Default" }

    $IP_INICIAL = Capturar-IP "IP Inicial (Se asignará al Servidor)"
    
    while ($true) {
        $IP_FINAL = Capturar-IP "IP Final del rango"
        if (Validar-Rango $IP_INICIAL $IP_FINAL) { break }
        Log-Error "IP final inválida o fuera de rango."
    }

    $MASCARA = Obtener-Mascara $IP_INICIAL
    $SUBNET_ID = Obtener-ID-Red $IP_INICIAL $MASCARA
    
    $CIDR = 24
    if ($MASCARA -eq "255.0.0.0") { $CIDR = 8 }
    elseif ($MASCARA -eq "255.255.0.0") { $CIDR = 16 }

    $IP_RANGO_INICIO = Incrementar-IP $IP_INICIAL

    $GW = Capturar-IP-Opcional "Gateway"
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
        
        if ([string]::IsNullOrWhiteSpace($GW)) {
            New-NetIPAddress -InterfaceAlias $ALIAS -IPAddress $IP_INICIAL -PrefixLength $CIDR -ErrorAction Stop | Out-Null
        } else {
            New-NetIPAddress -InterfaceAlias $ALIAS -IPAddress $IP_INICIAL -PrefixLength $CIDR -DefaultGateway $GW -ErrorAction Stop | Out-Null
        }
        

        Write-Host "`n[AVISO] Reiniciando interfaz y estabilizando enlace. Por favor espere..." -ForegroundColor Yellow
        Write-Host "`n[AVISO] Reiniciando interfaz y estabilizando enlace. Por favor espere..." -ForegroundColor Yellow
        Restart-NetAdapter -Name $ALIAS -ErrorAction SilentlyContinue
        
        $intentos = 0
        while ((Get-NetAdapter -Name $ALIAS).Status -ne "Up" -and $intentos -lt 10) {
            Start-Sleep -Seconds 1
            $intentos++
        }
        Start-Sleep -Seconds 4 
        $scopeCheck = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        if ($scopeCheck) { 
            $scopeCheck | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue 
        }

        $timespan = New-TimeSpan -Seconds $LEASE_TIME
        Add-DhcpServerv4Scope -Name $SCOPE_NAME -StartRange $IP_RANGO_INICIO -EndRange $IP_FINAL -SubnetMask $MASCARA -State Active -LeaseDuration $timespan -ErrorAction Stop | Out-Null
        
        if ($GW) { Set-DhcpServerv4OptionValue -ScopeId $SUBNET_ID -OptionId 3 -Value @($GW) -Force -ErrorAction Stop }
        Set-DhcpServerv4OptionValue -ScopeId $SUBNET_ID -OptionId 6 -Value @($DNS) -Force -ErrorAction Stop
        Set-DhcpServerv4OptionValue -ScopeId $SUBNET_ID -OptionId 15 -Value $SCOPE_NAME -Force -ErrorAction Stop
        Abrir-Puertos-Servicio -NombreServicio "DHCP" -Puertos 67,68 -Protocolo UDP
        Permitir-Ping-Global
        Restart-Service DHCPServer -Force
        Start-Sleep -Seconds 2
        Set-DhcpServerv4Binding -InterfaceAlias $ALIAS -BindingState $true -ErrorAction SilentlyContinue
        Restart-Service DHCPServer -Force
        
        Log-Ok "Servicio Configurado y ACTIVO."
    } catch {
        Log-Error "Fallo en configuracion: $($_.Exception.Message)"
    }
    Pausa
}

function Alternar-Servicio {
    Clear-Host
    Write-Host "--- CONTROL DE SERVICIO DHCP ---" -ForegroundColor Yellow
    if (-not (Get-WindowsFeature -Name DHCP).Installed) {
        Log-Error "El servicio no está instalado."
        Pausa; return
    }

    $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
    if ($svc.Status -eq "Running") {
        Write-Host "Estado actual del servicio: " -NoNewline; Write-Host "ACTIVO" -ForegroundColor Green
        if (Confirmar-Accion "¿Desea DESACTIVAR el servicio DHCP?") {
            Stop-Service DHCPServer -Force
            Log-Warning "Servicio DHCP detenido manualmente."
        } else { Log-Info "El servicio se mantiene ACTIVO." }
    } else {
        Write-Host "Estado actual del servicio: " -NoNewline; Write-Host "INACTIVO" -ForegroundColor Red
        if (Confirmar-Accion "¿Desea ACTIVAR el servicio DHCP?") {
            Start-Service DHCPServer
            Log-Ok "Servicio DHCP iniciado."
        } else { Log-Info "El servicio se mantiene INACTIVO." }
    }
    Pausa
}

function Monitorear-Clientes {
    while ($true) {
        Clear-Host
        Write-Host "=== MONITOR EN TIEMPO REAL (Presione 'x' para salir) ===" -ForegroundColor Yellow
        
        if (-not (Get-WindowsFeature -Name DHCP).Installed) {
            Log-Error "El servicio DHCP no está instalado."
            Pausa; break
        }

        Write-Host "`n[ CONFIGURACIÓN ACTIVA ]" -ForegroundColor Cyan
        $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        if ($scope) {
            Write-Host "Scope: $($scope.Name) | Rango: $($scope.StartRange) - $($scope.EndRange) | Máscara: $($scope.SubnetMask)"
        } else { Write-Host "Sin configuración." }

        Write-Host "`n[ ESTADO DEL SERVICIO ]" -ForegroundColor Cyan
        $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
        if ($svc.Status -eq "Running") {
             Write-Host "Estado: " -NoNewline; Write-Host "ACTIVO" -ForegroundColor Green
             
             Write-Host "`n[ CLIENTES CONECTADOS ]" -ForegroundColor Yellow
             Write-Host ("{0,-18} {1,-20} {2,-20}" -f "IP Address", "MAC Address", "Hostname")
             Write-Host "------------------------------------------------------------"
             
             $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
             if ($leases) {
                 foreach ($l in $leases) { Write-Host ("{0,-18} {1,-20} {2,-20}" -f $l.IPAddress, $l.ClientId, $l.HostName) }
             }
        } else {
             Write-Host "Estado: " -NoNewline; Write-Host "INACTIVO" -ForegroundColor Red
             Log-Warning "El servicio está detenido. No se muestran clientes."
        }

        if ([System.Console]::KeyAvailable) {
            $key = [System.Console]::ReadKey($true)
            if ($key.KeyChar -eq 'x' -or $key.KeyChar -eq 'X') { break }
        }
        Start-Sleep -Seconds 2
    }
}

function Menu-DHCP {
    $OpcionesDHCP = @(
        "Instalar / Reinstalar Servicio",
        "Configurar Ámbito DHCP",
        "Alternar Estado del Servicio (Start/Stop)",
        "Monitorear Clientes (Tiempo Real)"
    )
    
    while ($true) {
        $Eleccion = Generar-Menu "MÓDULO DE GESTIÓN DHCP" $OpcionesDHCP "Volver al Menú Principal"
        
        switch ($Eleccion) {
            0 { Gestionar-Instalacion }
            1 { Configurar-DHCP }
            2 { Alternar-Servicio }
            3 { Monitorear-Clientes }
            4 { return }
        }
    }
}

Menu-DHCP