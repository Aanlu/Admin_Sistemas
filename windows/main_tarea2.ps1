$RutaScript = Split-Path $MyInvocation.MyCommand.Path
. "$RutaScript\libs\Utils.ps1"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    log_error "Este script debe ser ejecutado como Administrador."
    exit
}

function Configurar {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "                 SERVIDOR DHCP (Windows)" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan

    $Interfaz = Get-InterfazInterna
    
    if (-not $Interfaz) {
        log_error "No se detectó una interfaz de red interna adecuada."
        Pausa
        return
    }

    log_info "Interfaz de red detectada: $($Interfaz.Name)"
    Preparar-Red -InterfazAlias $Interfaz.Name

    Write-Host "1) Automatico"
    Write-Host "2) Manual"
    $Opcion = Read-Host "Opción (1/2)"

    if ($Opcion -eq "1") {
        log_info "Configuración automática seleccionada."
        log_info "Cargando valores predeterminados..."
        
        $NombreAmbito  = "Red_Sistemas"
        $IPInicio      = "192.168.100.50"
        $IPFin         = "192.168.100.150"
        $PuertaEnlace  = "192.168.100.1"
        $ServidorDNS   = "192.168.100.20"
        $TiempoConcesion = New-TimeSpan -Seconds 600 
        Start-Sleep -Seconds 1
    } else {
        log_info "Modo manual seleccionado."
        $NombreAmbito = Read-Host "Ingrese el nombre del ámbito"

        do {
            $IPInicio = Read-Host "IP inicial del rango"
        } until (Get-IPFormato $IPInicio)

        do {
            $IPFin = Read-Host "IP final del rango"
        } until (Get-IPFormato $IPFin -and (Test-IPRango $IPInicio $IPFin))

        $PuertaEnlace = Read-Host "Gateway"
        $ServidorDNS = Read-Host "DNS"
        $Segundos = Read-Host "Tiempo de concesión (segundos)"
        $TiempoConcesion = New-TimeSpan -Seconds ([int]$Segundos)
    }

    Write-Host ""
    log_info "Verificando dependencias..."
    
    if (-not (Get-WindowsFeature -Name DHCP).Installed) {
        Install-WindowsFeature DHCP -IncludeManagementTools | Out-Null
        log_ok "[COMPLETADO] Servicio instalado correctamente."
    } else {
        log_ok "Servicio ya instalado."
    }

    log_info "Configurando el servicio DHCP..."

    try {
        if (Get-DhcpServerv4Scope -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue) {
            Remove-DhcpServerv4Scope -ScopeId 192.168.100.0 -Force
        }

        Add-DhcpServerv4Scope -Name $NombreAmbito -StartRange $IPInicio -EndRange $IPFin -SubnetMask 255.255.255.0 -State Active -LeaseDuration $TiempoConcesion
        Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -OptionId 3 -Value $PuertaEnlace
        Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -OptionId 6 -Value $ServidorDNS
        
        Restart-Service dhcpserver
        log_ok "Servicio reiniciado y configurado correctamente."

    } catch {
        log_error "Error al configurar DHCP: $_"
    }
    Pausa
}

function Monitorear {
    Clear-Host
    Write-Host "  --- Estado del Servidor ---" -ForegroundColor Cyan
    
    if ((Get-Service dhcpserver).Status -eq "Running") {
        log_ok "Estado: Activo"
    } else {
        log_error "Estado: Inactivo"
    }

    Write-Host ""
    Write-Host "  --- Clientes DHCP Actuales ---" -ForegroundColor Cyan
    
    $Concesiones = Get-DhcpServerv4Lease -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue

    if ($Concesiones) {
        $Concesiones | Select-Object @{N='Direccion IP';E={$_.IPAddress}}, @{N='Direccion MAC';E={$_.ClientId}}, @{N='Nombre Host';E={$_.HostName}} | Format-Table -AutoSize
    } else {
        Write-Host "No se han registrado clientes DHCP aún."
    }
    Pausa
}

while ($true) {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "                 SERVIDOR DHCP" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "1) Configurar Servidor"
    Write-Host "2) Monitorear Clientes"
    Write-Host "3) Salir"
    
    $Seleccion = Read-Host "Seleccione una opción (1-3)"
    
    switch ($Seleccion) {
        "1" { Configurar }
        "2" { Monitorear }
        "3" { log_info "Saliendo..."; exit }
        default { log_error "Opción no válida. Intente nuevamente."; Start-Sleep -Seconds 1 }
    }
}