    . .\libs\utils.ps1
    . .\libs\validaciones.ps1

    function Configurar-Interfaz-SSH {
        Clear-Host
        Write-Host "--- DESPLIEGUE DE RED DE ADMINISTRACIÓN (OUT-OF-BAND) ---" -ForegroundColor Yellow

        $interface = "Ethernet 2"
        $ip_server = "100.0.0.10"
        $ip_client = "100.0.0.11"
        $cidr = 24

        Write-Host "[1/3] Verificando y levantando la interfaz $interface..." -ForegroundColor Cyan
        Enable-NetAdapter -Name $interface -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 1

        $sshCap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
        if ($sshCap.State -ne "Installed") {
            Write-Host "[2/3] Instalando servidor SSH silenciosamente..." -ForegroundColor Cyan
            Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue | Out-Null
            Set-Service -Name sshd -StartupType 'Automatic'
            Start-Service sshd
            New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "Permitir SSH" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null
        } else {
            Write-Host "[2/3] Servicio SSH ya instalado y activo." -ForegroundColor Green
            Set-Service -Name sshd -StartupType 'Automatic' -ErrorAction SilentlyContinue
            Start-Service sshd -ErrorAction SilentlyContinue
        }

        Write-Host "[3/3] Aplicando topología de red..." -ForegroundColor Cyan
        $ipActual = Get-NetIPAddress -InterfaceAlias $interface -IPAddress $ip_server -ErrorAction SilentlyContinue
        
        if ($ipActual) {
            Write-Host "[OK] La IP $ip_server ya está asignada a $interface." -ForegroundColor Green
        } else {
            New-NetIPAddress -InterfaceAlias $interface -IPAddress $ip_server -PrefixLength $cidr -ErrorAction SilentlyContinue | Out-Null
            Restart-Service sshd -ErrorAction SilentlyContinue
            Write-Host "[OK] IP $ip_server asignada correctamente." -ForegroundColor Green
        }

        Write-Host "`n========================================================================" -ForegroundColor Green
        Write-Host "  [!] CONFIGURACIÓN REQUERIDA EN LA MÁQUINA VIRTUAL CLIENTE [!]" -ForegroundColor Yellow
        Write-Host "========================================================================" -ForegroundColor Green
        Write-Host "La red de administración ha sido aislada en el segmento 172.16.99.0/24."
        Write-Host "Para conectarte a este servidor Windows, ejecuta estos comandos en tu"
        Write-Host "VM Cliente (ej. Linux Mint) sobre su interfaz de red interna:`n"
        
        Write-Host "  sudo ip link set dev <INTERFAZ_CLIENTE> up" -ForegroundColor Cyan
        Write-Host "  sudo ip addr flush dev <INTERFAZ_CLIENTE>" -ForegroundColor Cyan
        Write-Host "  sudo ip addr add $ip_client/$cidr dev <INTERFAZ_CLIENTE>`n" -ForegroundColor Cyan
        
        Write-Host "Comando de conexión (ejecutar en el cliente una vez configurada la IP):"
        Write-Host "  ssh $env:USERNAME@$ip_server" -ForegroundColor Yellow
        Write-Host "========================================================================" -ForegroundColor Green
        
        Pausa
    }

    function Alternar-SSH {
        Clear-Host
        Write-Host "--- CONTROL DE SERVICIO SSH ---" -ForegroundColor Yellow
        $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue

        if ($svc -and $svc.Status -eq "Running") {
            if (Confirmar-Accion "¿Desea DESACTIVAR el servicio SSH?") {
                Stop-Service sshd
                Write-Host "Servicio SSH detenido. (Atención: perderás la conexión actual)." -ForegroundColor Yellow
            }
        } else {
            if (Confirmar-Accion "¿Desea ACTIVAR el servicio SSH?") {
                Start-Service sshd -ErrorAction SilentlyContinue
                Write-Host "Servicio SSH iniciado." -ForegroundColor Green
            }
        }
        Pausa
    }

    function Menu-SSH {
        $opciones_ssh = @(
            "Desplegar Red de Administración SSH (Ethernet 3)",
            "Alternar Estado del Servicio (Start/Stop)"
        )

        while ($true) {
            $estado_actual = "INACTIVO"
            $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") {
                $estado_actual = "ACTIVO"
            }

            $titulo_dinamico = "MÓDULO DE GESTIÓN SSH [ $estado_actual ]"

            $eleccion = Generar-Menu $titulo_dinamico $opciones_ssh "Volver al Menú Principal"

            switch ($eleccion) {
                0 { Configurar-Interfaz-SSH }
                1 { Alternar-SSH }
                2 { return }
            }
        }
    }

    Menu-SSH