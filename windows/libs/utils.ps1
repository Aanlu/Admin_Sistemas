[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RutaScript = Split-Path $MyInvocation.MyCommand.Path
. "$RutaScript\libs\Utils.ps1"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    log_error "Este script debe ser ejecutado como Administrador."
    exit
}

function gestionar_instalacion {
    Clear-Host
    Write-Host "${AMARILLO}--- GESTIÓN DE INSTALACIÓN ---${RESET}"
    $feat = Get-WindowsFeature DHCP
    if ($feat.Installed) {
        log_ok "El servicio DHCP ya se encuentra instalado."
        Write-Host ""
        $RESP = Read-Host "¿Desea realizar una REINSTALACIÓN completa? (s/n)"
        if ($RESP -eq "s" -or $RESP -eq "S") {
            log_info "Eliminando servicio..."
            Uninstall-WindowsFeature DHCP -IncludeManagementTools
            log_info "Instalando servicio..."
            Install-WindowsFeature DHCP -IncludeManagementTools
            log_ok "Reinstalación finalizada."
        }
    } else {
        log_info "Instalando servicio DHCP..."
        Install-WindowsFeature DHCP -IncludeManagementTools
        log_ok "Instalación completada."
    }
    Pausa
}

function Configurar {
    Clear-Host
    if (-not (Get-WindowsFeature DHCP).Installed) { log_error "El servicio no está instalado."; Pausa; return }
    
    $Interfaz = detectar_intefaz
    if (-not $Interfaz) { log_error "No se detectó interfaz adecuada."; Pausa; return }
    
    log_info "Interfaz detectada: $Interfaz"
    
    Write-Host "`n${AMARILLO}--- CONFIGURACIÓN DEL ÁMBITO DHCP ---${RESET}"
    $NombreAmbito = Read-Host "Nombre del Ámbito (Scope)"

    do { $IP_INI = Read-Host "IP Servidor / Inicial" } until (validar_formato_ip $IP_INI)
    do { $IP_FIN = Read-Host "IP Final del rango" } until ((validar_formato_ip $IP_FIN) -and (validar_rango $IP_INI $IP_FIN))
    
    $MASK = obtener_mascara $IP_INI
    $SUBNET = obtener_id_red $IP_INI $MASK
    preparar_servidor $Interfaz $IP_INI $MASK

    do { $GW = Read-Host "Gateway (Enter para omitir)" 
         if($GW -eq ""){break}
    } until (validar_formato_ip $GW)

    do { $DNS = Read-Host "DNS (Enter para omitir)" 
         if($DNS -eq ""){break}
    } until (validar_formato_ip $DNS)

    do { $LEASE = Read-Host "Tiempo de concesión (segundos)" } until ($LEASE -match "^\d+$")

    log_info "Limpiando configuraciones previas..."
    Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Remove-DhcpServerv4Scope -Force

    log_info "Creando nuevo ámbito en $SUBNET..."
    Add-DhcpServerv4Scope -Name $NombreAmbito -StartRange $IP_INI -EndRange $IP_FIN -SubnetMask $MASK -State Active -LeaseDuration (New-TimeSpan -Seconds $LEASE)
    
    if ($GW) { Set-DhcpServerv4OptionValue -ScopeId $SUBNET -OptionId 3 -Value $GW }
    if ($DNS) { Set-DhcpServerv4OptionValue -ScopeId $SUBNET -OptionId 6 -Value $DNS }

    Restart-Service dhcpserver -Force
    log_ok "Servicio configurado y reiniciado."
    Pausa
}

function Monitorear {
    while ($true) {
        Clear-Host
        Write-Host "${AMARILLO}=== MONITOR DHCP (Tiempo Real) ===${RESET}"
        Write-Host "[Presione 'X' para volver al menú]`n"
        
        $s = Get-Service dhcpserver
        Write-Host "servivio DHCP: $($s.Status)" -ForegroundColor Cyan

        $Scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        if ($Scopes) {
            foreach ($sc in $Scopes) {
                Write-Host "`n--- Ámbito: $($sc.Name) ($($sc.ScopeId)) ---" -ForegroundColor Yellow
                Write-Host "Rango: $($sc.StartRange) - $($sc.EndRange)"
                Write-Host "Máscara: $($sc.SubnetMask)"
                
                $leases = Get-DhcpServerv4Lease -ScopeId $sc.ScopeId -ErrorAction SilentlyContinue
                Write-Host "Clientes conectados: $($leases.Count)"
                if ($leases) {
                    $leases | Select-Object IPAddress, ClientId, HostName | Format-Table -AutoSize
                }
            }
        } else {
            log_warning "No hay ámbitos configurados."
        }

        if ([Console]::KeyAvailable) {
            if ([Console]::ReadKey($true).Key -eq "X") { break }
        }
        Start-Sleep -Seconds 2
    }
}

while ($true) {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "                    GESTOR DHCP  " -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "1) Instalar / Reinstalar Servicio"
    Write-Host "2) Configurar DHCP"
    Write-Host "3) Monitorear Clientes"
    Write-Host "4) Salir"
    
    $op = Read-Host "`nSeleccione una opción"
    switch ($op) {
        "1" { gestionar_instalacion }
        "2" { Configurar }
        "3" { Monitorear }
        "4" { log_info "Saliendo..."; exit }
        default { log_error "Opción inválida." ; Start-Sleep -Seconds 1 }
    }
}