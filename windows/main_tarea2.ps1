﻿if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "[ERROR] Este script debe ser ejecutado como Administrador." -ForegroundColor Red
    exit
}

function Log-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Log-Ok { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Log-Error { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Log-Warning { param($msg) Write-Host "[AVISO] $msg" -ForegroundColor Yellow }

function Pausa {
    Write-Host "`nPresione cualquier tecla para continuar..." -NoNewline -ForegroundColor Gray
    [void][System.Console]::ReadKey($true)
    Write-Host ""
}

function Validar-Formato-IP {
    param($ip)
    $ipsProhibidas = @("0.0.0.0", "255.255.255.255", "127.0.0.0", "127.0.0.1")
    
    if ([System.Net.IPAddress]::TryParse($ip, [ref]$null)) {
        if ($ipsProhibidas -contains $ip) {
            return $false
        }
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
        Log-Error "Intentaste saltar de la red $red1 a la red $red2."
        return $false
    }
    
    $host1 = [int]($ip1.Split('.')[3])
    $host2 = [int]($ip2.Split('.')[3])

    if ($host2 -le $host1) {
        Log-Error "La IP final ($ip2) debe ser mayor que la inicial ($ip1)."
        return $false
    }
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

function Seleccionar-Interfaz {
    $interfaces = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    if ($interfaces.Count -eq 0) { Log-Error "No hay interfaces de red activas."; return $null }
    
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

function Gestionar-Instalacion {
    Clear-Host
    Write-Host "--- GESTIÓN DE INSTALACIÓN ---" -ForegroundColor Yellow
    
    $check = Get-WindowsFeature -Name DHCP
    
    if ($check.Installed) {
        Log-Ok "El servicio DHCP ya se encuentra instalado."
        Write-Host ""
        
        do {
            $resp = Read-Host "¿Desea realizar una REINSTALACIÓN completa? (s/n)"
        } until ($resp -match "^[sSnN]$")

        if ($resp -eq "s" -or $resp -eq "S") {
            Write-Host "Desinstalando servicio..." -ForegroundColor Gray
            Uninstall-WindowsFeature -Name DHCP -IncludeManagementTools -WarningAction SilentlyContinue | Out-Null
            Write-Host "Reinstalando limpio..." -ForegroundColor Gray
            Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
            Log-Ok "Reinstalación finalizada correctamente."
            Pausa
        } else {
            return
        }
    } else {
        Log-Warning "Dependencias DHCP NO encontradas."
        
        do {
            $resp = Read-Host "¿Desea instalar el servicio DHCP ahora? (s/n)"
        } until ($resp -match "^[sSnN]$")
        
        if ($resp -eq "s" -or $resp -eq "S") {
            Write-Host "Instalando servicio..." -ForegroundColor Cyan
            Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
            Log-Ok "Instalación completada correctamente."
            Pausa
        } else {
            Write-Host "Instalación cancelada por el usuario." -ForegroundColor Gray
            Pausa
        }
    }
}

function Configurar {
    Clear-Host
    if (-not (Get-WindowsFeature -Name DHCP).Installed) {
        Log-Error "El servicio no está instalado."
        Pausa; return
    }

    $adapter = Seleccionar-Interfaz
    if (-not $adapter) { Pausa; return }
    $ALIAS = $adapter.Name

    Write-Host "`n--- CONFIGURACIÓN DEL ÁMBITO DHCP ---" -ForegroundColor Yellow
    $SCOPE_NAME = Read-Host "Nombre del Ámbito (Scope)"
    if ([string]::IsNullOrWhiteSpace($SCOPE_NAME)) { $SCOPE_NAME = "Scope_Default" }

    while ($true) {
        $IP_INICIAL = Read-Host "IP Inicial (Se asignará al Servidor)"
        if (Validar-Formato-IP $IP_INICIAL) { break }
        Log-Error "IP inválida o prohibida."
    }

    while ($true) {
        $IP_FINAL = Read-Host "IP Final del rango"
        if ((Validar-Formato-IP $IP_FINAL) -and (Validar-Rango $IP_INICIAL $IP_FINAL)) { break }
        Log-Error "IP inválida o rango incorrecto."
    }

    $MASCARA = Obtener-Mascara $IP_INICIAL
    $SUBNET_ID = Obtener-ID-Red $IP_INICIAL $MASCARA
    
    $CIDR = 24
    if ($MASCARA -eq "255.0.0.0") { $CIDR = 8 }
    elseif ($MASCARA -eq "255.255.0.0") { $CIDR = 16 }

    $IP_RANGO_INICIO = Incrementar-IP $IP_INICIAL

    $GW_INPUT = Read-Host "Gateway (Enter para omitir)"
    $GW = $null
    if (Validar-Formato-IP $GW_INPUT) { $GW = $GW_INPUT }

    $DNS_INPUT = Read-Host "DNS (Enter para omitir)"
    $DNS = $null
    if (Validar-Formato-IP $DNS_INPUT) { $DNS = $DNS_INPUT }

    while ($true) {
        $LEASE_STR = Read-Host "Tiempo de concesión (segundos)"
        if ($LEASE_STR -match "^\d+$" -and [int]$LEASE_STR -gt 0) { 
            $LEASE_TIME = [int]$LEASE_STR
            break 
        }
        Log-Error "Debe ser un número entero positivo."
    }

    try {
        Write-Host "Configurando interfaz de red..." -ForegroundColor Gray
        
        Set-NetIPInterface -InterfaceAlias $ALIAS -Dhcp Disabled -AddressFamily IPv4 -ErrorAction SilentlyContinue
        Remove-NetIPAddress -InterfaceAlias $ALIAS -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceAlias $ALIAS -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        
        if (-not [string]::IsNullOrWhiteSpace($GW)) {
            New-NetIPAddress -InterfaceAlias $ALIAS -IPAddress $IP_INICIAL -PrefixLength $CIDR -DefaultGateway $GW -ErrorAction Stop | Out-Null
        } else {
            New-NetIPAddress -InterfaceAlias $ALIAS -IPAddress $IP_INICIAL -PrefixLength $CIDR -ErrorAction Stop | Out-Null
        }
        
        Write-Host "Reiniciando adaptador para aplicar cambios..." -ForegroundColor Gray
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
        
        if (-not [string]::IsNullOrWhiteSpace($GW)) {
            Set-DhcpServerv4OptionValue -ScopeId $SUBNET_ID -OptionId 3 -Value $GW -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrWhiteSpace($DNS)) {
            Set-DhcpServerv4OptionValue -ScopeId $SUBNET_ID -OptionId 6 -Value $DNS -ErrorAction SilentlyContinue
        }

        Set-DhcpServerv4OptionValue -ScopeId $SUBNET_ID -OptionId 15 -Value $SCOPE_NAME -ErrorAction SilentlyContinue

        Write-Host "Aplicando reglas de Firewall y Bindings..." -ForegroundColor Gray
        Remove-NetFirewallRule -DisplayName "DHCP-Allow" -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "DHCP-Allow" -Direction Inbound -LocalPort 67,68 -Protocol UDP -Action Allow | Out-Null
        
        Restart-Service DHCPServer -Force
        Start-Sleep -Seconds 2
        
        Set-DhcpServerv4Binding -InterfaceAlias $ALIAS -BindingState $true -ErrorAction Stop
        
        Restart-Service DHCPServer -Force
        
        Log-Ok "Servicio Configurado y ACTIVO."
        Log-Info "Ámbito: $SCOPE_NAME | Rango: $IP_RANGO_INICIO - $IP_FINAL | Lease: $LEASE_TIME s"
    } catch {
        Log-Error "Fallo en configuración: $($_.Exception.Message)"
        if ($_.Exception.Message -match "parámetro no es correcto") {
            Log-Warning "AVISO: Windows no permite asignar IPs que inician con 127.x.x.x a adaptadores físicos."
        }
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

    $svc = Get-Service DHCPServer
    
    if ($svc.Status -eq "Running") {
        Write-Host "El servicio está actualmente: " -NoNewline
        Write-Host "ACTIVO" -ForegroundColor Green
        
        do { $resp = Read-Host "¿Desea DESACTIVAR el servicio? (s/n)" } until ($resp -match "^[sSnN]$")
        
        if ($resp -eq "s" -or $resp -eq "S") {
            Stop-Service DHCPServer -Force
            Log-Warning "Servicio detenido."
        }
    } else {
        Write-Host "El servicio está actualmente: " -NoNewline
        Write-Host "INACTIVO" -ForegroundColor Red
        
        do { $resp = Read-Host "¿Desea ACTIVAR el servicio? (s/n)" } until ($resp -match "^[sSnN]$")
        
        if ($resp -eq "s" -or $resp -eq "S") {
            Start-Service DHCPServer
            Log-Ok "Servicio iniciado."
        }
    }
    Pausa
}
function Monitorear {
    while ($true) {
        Clear-Host
        Write-Host "=== MONITOR EN TIEMPO REAL (Presione 'x' para salir) ===" -ForegroundColor Yellow
        
        if (-not (Get-WindowsFeature -Name DHCP).Installed) {
            Write-Host "`n[ERROR] El servicio DHCP no está instalado." -ForegroundColor Red
            Write-Host "Debe instalar el rol DHCP antes de monitorear." -ForegroundColor Gray
            Pausa
            break
        }

        $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Select-Object -First 1
        $svc = Get-Service DHCPServer -ErrorAction SilentlyContinue
        
        Write-Host "`n[ ESTADO DEL SERVICIO ]"
        Write-Host "Estado: " -NoNewline
        if ($svc.Status -eq "Running") { 
            Write-Host "ACTIVO" -ForegroundColor Green 
        } else { 
            Write-Host "INACTIVO" -ForegroundColor Red 
        }

        Write-Host "`n[ CONFIGURACIÓN ]"
        if ($scope) {
            Write-Host "subnet $($scope.ScopeId) netmask $($scope.SubnetMask) {"
            Write-Host "  range $($scope.StartRange) $($scope.EndRange);"
            Write-Host "}"
            
            if ($svc.Status -eq "Running") {
                Write-Host "`n[ CLIENTES ]"
                "{0,-18} {1,-20} {2,-20}" -f "IP Address", "MAC Address", "Hostname"
                Write-Host "------------------------------------------------------------"
                
                $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
                foreach ($lease in $leases) {
                    "{0,-18} {1,-20} {2,-20}" -f $lease.IPAddress.IPAddressToString, $lease.ClientId, $lease.HostName
                }
            } else {
                Log-Warning "El servicio está detenido. No se muestran clientes."
            }

        } else {
            Write-Host "Estado: Desactivado / Sin Configuración." -ForegroundColor Red
            Write-Host "Acción requerida: Asignar Configuración en el menú principal." -ForegroundColor Gray
        }

        if ([System.Console]::KeyAvailable) {
            $key = [System.Console]::ReadKey($true)
            if ($key.KeyChar -eq 'x' -or $key.KeyChar -eq 'X') { break }
        }
        Start-Sleep -Seconds 2
    }
}

$OPCIONES = @("Instalar / Reinstalar Servicio", "Configurar DHCP", "Activar/Desactivar Servicio", "Monitorear Clientes", "Salir")
$SELECCION = 0

while ($true) {
    Clear-Host
    Write-Host "================================================="
    Write-Host "                  GESTOR DHCP "
    Write-Host "================================================="
    
    for ($i=0; $i -lt $OPCIONES.Count; $i++) {
        if ($i -eq $SELECCION) {
            Write-Host "> $($OPCIONES[$i])" -BackgroundColor Green -ForegroundColor Black
        } else {
            Write-Host "  $($OPCIONES[$i])"
        }
    }
    
    $key = [System.Console]::ReadKey($true)
    if ($key.Key -eq "UpArrow") { 
        $SELECCION--
        if ($SELECCION -lt 0) { $SELECCION = $OPCIONES.Count - 1 }
    } elseif ($key.Key -eq "DownArrow") { 
        $SELECCION++
        if ($SELECCION -ge $OPCIONES.Count) { $SELECCION = 0 }
    } elseif ($key.Key -eq "Enter") {
        switch ($SELECCION) {
            0 { Gestionar-Instalacion }
            1 { Configurar }
            2 { Alternar-Servicio }
            3 { Monitorear }
            4 { exit }
        }
    }
}