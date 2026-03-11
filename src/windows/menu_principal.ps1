

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -Path $ScriptDir

# ── Librerías base ──────────────────────────────────────────────────────────
. .\libs\utils.ps1
. .\libs\validaciones.ps1
. .\libs\seguridad.ps1

# ── Funciones auxiliares de módulos ────────────────────────────────────────
# http_funciones.ps1 se carga aquí porque 06_http.ps1 ya no usa $PSScriptRoot
# (ese contexto apuntaba a este directorio y rompía la ruta relativa)
. .\libs\http_funciones.ps1

# ── Módulos: se cargan UNA sola vez. El switch llama a la función, no al archivo.
. .\modulos\01_diagnostico.ps1
. .\modulos\02_dhcp.ps1
. .\modulos\03_dns.ps1
. .\modulos\04_ssh.ps1
. .\modulos\05_ftp.ps1
. .\modulos\06_http.ps1

$OpcionesPrincipales = @(
    "Diagnóstico de Red",
    "Configuración Servidor DHCP",
    "Configuración Servidor DNS",
    "SSH",
    "FTP",
    "HTTP"
)

while ($true) {
    $Eleccion = Generar-Menu "      MENÚ PRINCIPAL" $OpcionesPrincipales "Salir del Sistema"

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