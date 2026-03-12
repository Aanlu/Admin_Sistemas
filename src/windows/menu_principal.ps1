if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "[ERROR] Este script debe ser ejecutado como Administrador." -ForegroundColor Red
    exit
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -Path $ScriptDir

# ── RUTAS GLOBALES (calculadas UNA sola vez desde el punto de entrada) ────────
# Equivalente exacto al patron de Linux:
#   DIR_BASE=$(dirname "$(readlink -f "$0")")   <- eso es $ScriptDir (src\windows\)
#   LOG_FILE="$DIR_BASE/../../logs/..."          <- subir 2 niveles = Admin_Sistemas\
#
# $ScriptDir = src\windows\
# Split-Path -Parent $ScriptDir = src\
# Split-Path -Parent (Split-Path -Parent $ScriptDir) = Admin_Sistemas\  ← REPO_ROOT
$global:REPO_ROOT    = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$global:LOG_FILE     = Join-Path $global:REPO_ROOT "logs\windows_services.log"
$global:TEMPLATE_WIN = Join-Path $global:REPO_ROOT "templates\windows\index.web.template"

# Garantizar que el directorio de logs exista (equivalente a: mkdir -p logs/)
$logsDir = Split-Path -Parent $global:LOG_FILE
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

# Mapa de versiones Apache Lounge (se rellena en Extraer-VersionesDinamicas)
$global:APACHE_LOUNGE_MAP = [ordered]@{}

# ── Librerias base ────────────────────────────────────────────────────────────
. .\libs\utils.ps1
. .\libs\validaciones.ps1
. .\libs\seguridad.ps1

# ── Funciones auxiliares de modulos ──────────────────────────────────────────
# http_funciones.ps1 se carga aqui porque cuando se hace dot-source desde aqui,
# $PSScriptRoot dentro de las funciones apunta a src\windows\ (este directorio),
# NO al directorio de libs\. Al usar $global:REPO_ROOT eliminamos esa dependencia.
. .\libs\http_funciones.ps1

# ── Modulos: se cargan UNA sola vez. El switch llama a la funcion, no al archivo.
. .\modulos\01_diagnostico.ps1
. .\modulos\02_dhcp.ps1
. .\modulos\03_dns.ps1
. .\modulos\04_ssh.ps1
. .\modulos\05_ftp.ps1
. .\modulos\06_http.ps1

$OpcionesPrincipales = @(
    "Diagnostico de Red",
    "Configuracion Servidor DHCP",
    "Configuracion Servidor DNS",
    "SSH",
    "FTP",
    "HTTP"
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
        6 {
            Clear-Host
            Write-Host "Cerrando sistema..." -ForegroundColor Green
            exit
        }
    }
}