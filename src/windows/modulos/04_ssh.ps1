. .\libs\utils.ps1
. .\libs\validaciones.ps1

function Inyectar-IP-Inicial {
    $interfaz = Get-NetAdapter | Where-Object { $_.InterfaceAlias -notmatch "Loopback|vEthernet" -and $_.Status -eq "Up" } | Select-Object -Last 1
    if (-not $interfaz) { return }

    $alias = $interfaz.InterfaceAlias
    $ipObj = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue

    if (-not $ipObj -or $ipObj.IPAddress -match "^169\.254\.") {
        $ip_defecto = "10.0.0.10"
        Write-Host "Inyectando IP estática y levantando DHCP de Semilla en $alias..." -ForegroundColor Cyan
        
        New-NetIPAddress -InterfaceAlias $alias -IPAddress $ip_defecto -PrefixLength 24 -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 2
        
        Add-WindowsFeature DHCP -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
        $scopeCheck = Get-DhcpServerv4Scope -ScopeId 10.0.0.0 -ErrorAction SilentlyContinue
        if (-not $scopeCheck) {
            Add-DhcpServerv4Scope -Name "Rescate_ZTP" -StartRange 10.0.0.100 -EndRange 10.0.0.110 -SubnetMask 255.255.255.0 -State Active -ErrorAction SilentlyContinue | Out-Null
            Set-DhcpServerv4OptionValue -ScopeId 10.0.0.0 -OptionId 3 -Value $ip_defecto -Force -ErrorAction SilentlyContinue | Out-Null
            Restart-Service DHCPServer -Force -ErrorAction SilentlyContinue
        }
        
        $global:IP_ACTIVA = $ip_defecto
    } else {
        $global:IP_ACTIVA = $ipObj.IPAddress
    }
}

function Instalar-SSH {
    Clear-Host
    Write-Host "--- INSTALACIÓN Y CONFIGURACIÓN DE SSH ---" -ForegroundColor Yellow

    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Log-Warning "El servicio SSH ya está instalado y operando."
        Pausa; return
    }

    Inyectar-IP-Inicial

    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue | Out-Null

    Set-Service -Name sshd -StartupType 'Automatic' -ErrorAction SilentlyContinue
    Start-Service sshd -ErrorAction SilentlyContinue

    Remove-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "Permitir SSH" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null

    Log-Ok "Servicio SSH y DHCP de rescate desplegados en el puerto 22."
    Pausa
}

function Alternar-SSH {
    Clear-Host
    Write-Host "--- CONTROL DE SERVICIO SSH ---" -ForegroundColor Yellow

    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue

    if ($svc -and $svc.Status -eq "Running") {
        if (Confirmar-Accion "¿Desea DESACTIVAR el servicio SSH?") {
            Stop-Service sshd
            Log-Warning "Servicio SSH detenido."
        }
    } else {
        if (Confirmar-Accion "¿Desea ACTIVAR el servicio SSH?") {
            if (-not $svc) {
                Log-Error "OpenSSH no está instalado."
            } else {
                Start-Service sshd
                Log-Ok "Servicio SSH iniciado."
            }
        }
    }
    Pausa
}

function Menu-SSH {
    $opciones_ssh = @(
        "Instalar y Configurar SSH (Zero-Touch / Autoprovisionamiento)",
        "Alternar Estado del Servicio (Start/Stop)"
    )

    while ($true) {
        $estado_actual = "INACTIVO"
        $comando_conexion = ""
        $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue

        if ($svc -and $svc.Status -eq "Running") {
            $estado_actual = "ACTIVO"
            $ipObj = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback|vEthernet" -and $_.Status -eq "Up" } | Select-Object -First 1
            if ($ipObj) {
                $comando_conexion = " | Comando: ssh $env:USERNAME@$($ipObj.IPAddress)"
            }
        }

        $titulo_dinamico = "MÓDULO DE GESTIÓN SSH [ $estado_actual ]$comando_conexion"

        $eleccion = Generar-Menu $titulo_dinamico $opciones_ssh "Volver al Menú Principal"

        switch ($eleccion) {
            0 { Instalar-SSH }
            1 { Alternar-SSH }
            2 { return }
        }
    }
}

Menu-SSH