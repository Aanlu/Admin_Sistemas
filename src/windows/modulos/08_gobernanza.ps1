# ==============================================================================
# MÓDULO 08: Gobernanza Dinámica Zero-Trust
# ==============================================================================

# Resolución de ruta absoluta infalible (Sube un nivel a /windows y entra a /libs)
$libsDir = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\libs")

# Importar librerías forzosamente
. "$libsDir\fsrm_funciones.ps1"
. "$libsDir\gobernanza_funciones.ps1"
. "$libsDir\applocker_funciones.ps1"
. "$libsDir\ad_funciones.ps1"

Function Generar-PayloadsClientes {
    Write-Host "`n[*] Forjando Payloads de Aprovisionamiento Zero-Touch..." -ForegroundColor Yellow

    $payloadDir = "C:\Admin_Sistemas\Payloads"
    if (-Not (Test-Path $payloadDir)) { New-Item -Path $payloadDir -ItemType Directory -Force | Out-Null }

    $ipServidor = "192.168.50.10"
    $dominio    = "gobernanza.local"

    # ======================================================================
    # PAYLOAD 1: WINDOWS 10
    # ======================================================================
    $scriptWin = @"
# Ejecutar como Administrador en Windows 10
Write-Host "--- APROVISIONAMIENTO WINDOWS 10 ---" -ForegroundColor Cyan

# 1. Secuestro de DNS (Obligatorio para encontrar el dominio)
`$iface = Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' } | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex `$iface.ifIndex -ServerAddresses "$ipServidor"
Write-Host "[OK] DNS redirigido al Controlador de Dominio ($ipServidor)." -ForegroundColor Green

# 2. Union al Dominio
Write-Host "`n[*] Ingrese credenciales de GOBERNANZA\Administrador para unir el equipo:" -ForegroundColor Yellow
Add-Computer -DomainName "$dominio" -Credential (Get-Credential) -Restart
"@
    $rutaWin = Join-Path $payloadDir "Unir_Win10.ps1"
    $scriptWin | Out-File $rutaWin -Encoding UTF8

    # ======================================================================
    # PAYLOAD 2: LINUX MINT
    # ======================================================================
    $scriptLinux = @"
#!/bin/bash
echo "=========================================================="
echo "    ORQUESTACION: INTEGRACION DE LINUX MINT A AD"
echo "=========================================================="

# 1. Instalación de dependencias exigidas por la rúbrica
echo "[*] Instalando realmd, sssd, adcli y utilidades PAM..."
sudo apt-get update -qq
sudo apt-get install -y realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin oddjob oddjob-mkhomedir packagekit > /dev/null

# 2. Corrección estricta de DNS (Apunta directo al corazón del Server)
echo "[*] Forzando resolución DNS hacia el Controlador de Dominio..."
echo "192.168.50.10 gobernanza.local" | sudo tee -a /etc/hosts > /dev/null

# 3. Unión al Dominio
echo "[*] Iniciando protocolo de unión Kerberos..."
echo "Se solicitara la contraseña de 'Administrador' de Windows Server:"
sudo realm join -U Administrador gobernanza.local

# 4. Modificación de sssd.conf (Exigencia de la rúbrica)
echo "[*] Inyectando parámetro fallback_homedir en sssd.conf..."
sudo sed -i 's/fallback_homedir = .*/fallback_homedir = \/home\/%u@%d/' /etc/sssd/sssd.conf
sudo systemctl restart sssd

# 5. Configuración de Sudoers (Exigencia de la rúbrica)
echo "[*] Otorgando privilegios de sudo a los administradores del AD..."
echo "%Administradores@gobernanza.local ALL=(ALL:ALL) ALL" | sudo tee /etc/sudoers.d/ad-admins > /dev/null
sudo chmod 0440 /etc/sudoers.d/ad-admins

# 6. Activación de creación de directorios automáticos
echo "[*] Activando PAM mkhomedir..."
sudo pam-auth-update --enable mkhomedir

echo "[+] SISTEMA SELLADO. Linux Mint ahora pertenece a gobernanza.local"
echo "Reinicia la maquina e inicia sesion como: luis00@gobernanza.local"
"@
    $rutaLinux = Join-Path $payloadDir "Unir_Linux.sh"
    # Linux usa saltos de línea LF, debemos asegurarnos de que el script no lleve CRLF de Windows
    [IO.File]::WriteAllText($rutaLinux, ($scriptLinux -replace "`r`n", "`n"))

    Write-Host "  [+] Generado: $rutaWin" -ForegroundColor Green
    Write-Host "  [+] Generado: $rutaLinux" -ForegroundColor Green
    Write-Host "`nInstrucciones: Copie estos archivos a sus respectivas maquinas virtuales y ejecutelos." -ForegroundColor Magenta
}


function Menu-Gobernanza {
    
    # --------------------------------------------------------------------------
    # FASE 0: Escudo Protector e Inicialización Core
    # --------------------------------------------------------------------------
    if (-not (Verificar-EntornoGobernanza)) {
        Write-Host "`n[!] ALERTA ARQUITECTÓNICA [!]" -ForegroundColor Red
        Write-Host "El servidor actual NO es un Controlador de Dominio (Faltan cimientos)." -ForegroundColor Yellow
        
        if (Confirmar-Accion "¿Desea ejecutar la orquestación de Fase 0 (Red, DHCP, AD, FSRM) y reiniciar?") {
            Instalar-InfraestructuraCore
        }
        return # Expulsamos al usuario al menú principal si decide no instalar
    }

    # Si ya es Controlador de Dominio, aseguramos que los clientes tengan Internet
    Asegurar-EnrutamientoDNS
    # --------------------------------------------------------------------------
    # FASE 1: Entorno Listo - Despliegue de Interfaz
    # --------------------------------------------------------------------------
    $configDir = Join-Path $global:REPO_ROOT "config"
    $rutaCSV   = Join-Path $configDir "usuarios.csv"

    $OpcionesGobernanza = @(
        "Visualizar/Administrar Reglas Globales (JSON)",
        "Motor de Sincronizacion CSV (Aprovisionar Usuarios)",
        "Crear Usuario Manual (Interactivo)",
        "Desplegar Cuotas y File Screens (FSRM)",
        "Configurar AppLocker + Logoff Forzado (GPOs)",
        "Generar Payloads de Clientes (Scripts Win10/Mint)"
    )

    while ($true) {
        $Eleccion = Generar-Menu "GOBERNANZA ZERO-TRUST (AD/FSRM/AppLocker)" $OpcionesGobernanza "Volver al Menu Principal"

        switch ($Eleccion) {
            0 { Show-AdministrarReglas }
            1 {
                Write-Host "`n[*] Iniciando motor de sincronizacion declarativo..." -ForegroundColor Yellow
                Sync-IdentidadesCSV -RutaCSV $rutaCSV
                Pausa
            }
            2 {
                # Se modularizará más adelante en ad_funciones.ps1
                Write-Host "`n[*] Creacion manual interactiva en construccion..." -ForegroundColor Cyan
                Pausa
            }
            3 {
                Write-Host "`n[*] Desplegando almacenamiento dinamico y apantallamiento..." -ForegroundColor Yellow
                $reglasJSON = Cargar-Reglas
                Configurar-AlmacenamientoDinamicop8 -RutaCSV $rutaCSV -reglasJSON $reglasJSON   
                Pausa
            }
            4 {
                Configurar-AppLockerP8
                Pausa
            }
            5 {     
                Generar-PayloadsClientes
                Read-Host "`nPresione [Enter] para continuar..."
            }
            6 { return }
        }
    }
}