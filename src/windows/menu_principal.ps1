if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "[ERROR] Este script debe ser ejecutado como Administrador." -ForegroundColor Red
    exit
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -Path $ScriptDir

# ── RUTAS GLOBALES ────────────────────────────────────────────────────────────
$global:REPO_ROOT    = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$global:LOG_FILE     = Join-Path $global:REPO_ROOT "logs\windows_services.log"
$global:TEMPLATE_WIN = Join-Path $global:REPO_ROOT "templates\windows\index.web.template"

# Garantizar que el directorio de logs exista
$logsDir = Split-Path -Parent $global:LOG_FILE
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

$global:APACHE_LOUNGE_MAP = [ordered]@{}

# ── Librerias base (INYECCIÓN DE MEMORIA CORREGIDA) ───────────────────────────
. .\libs\utils.ps1
. .\libs\validaciones.ps1
. .\libs\seguridad.ps1
. .\libs\http_funciones.ps1
. .\libs\ftp_cliente.ps1     # REQUERIDO PARA REPOSITORIO FTP
. .\libs\ssl_funciones.ps1   # REQUERIDO PARA CIFRADO PKI

# ── Modulos (CARGA DE MÓDULOS COMPLETADA) ─────────────────────────────────────
. .\modulos\01_diagnostico.ps1
. .\modulos\02_dhcp.ps1
. .\modulos\03_dns.ps1
. .\modulos\04_ssh.ps1
. .\modulos\05_ftp.ps1
. .\modulos\06_http.ps1
. .\modulos\07_ssl.ps1       # REQUERIDO PARA MENU-SSL
. .\modulos\08_gobernanza.ps1
. .\modulos\09_seguridad_rbac.ps1 # REQUERIDO PARA MENU-GOBERNANZA

# ── Interfaz de Usuario ───────────────────────────────────────────────────────
$OpcionesPrincipales = @(
    "Diagnostico de Red",
    "Configuracion Servidor DHCP",
    "Configuracion Servidor DNS",
    "SSH",
    "FTP",
    "HTTP",
    "SSL / Repositorio FTP",
    "Gobernanza Zero-Trust (P8 / AD)",  # <--- AGREGA ESTA LÍNEA
    "Seguridad RBAC y MFA (P9)"           # <--- AGREGA ESTA LÍNEA
)

while ($true) {
    $Eleccion = Generar-Menu "      MENU PRINCIPAL" $OpcionesPrincipales "Salir del Sistema"

    switch ($Eleccion) {
        0 { Menu-Diagnostico }
        1 { Menu-DHCP }
        2 { Menu-DNS }
        3 { Menu-SSH }
        4 { Menu-FTP }
        5 { Menu-HTTP }
        6 { Menu-SSL }
        7 { Menu-Gobernanza }  # <--- ENRUTA HACIA EL MÓDULO 08
        8 { Menu-P09 }         # <--- ENRUTA HACIA EL MÓDULO 09
        9 {                    # <--- EL BOTÓN DE SALIR AHORA ES EL 8
            Clear-Host
            Write-Host "Cerrando sistema..." -ForegroundColor Green
            exit
        }
    }
}