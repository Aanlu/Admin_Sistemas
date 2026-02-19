if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "[ERROR] Este script debe ser ejecutado como Administrador." -ForegroundColor Red
    exit
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -Path $ScriptDir

. .\libs\utils.ps1

$OpcionesPrincipales = @(
    "Diagnóstico de Red",
    "Configuración Servidor DHCP",
    "Configuración Servidor DNS (CRUD)"
)

while ($true) {
    $Eleccion = Generar-Menu "MENÚ PRINCIPAL - ADMIN SISTEMAS" $OpcionesPrincipales "Salir del Sistema"

    switch ($Eleccion) {
        0 { . .\modulos\01_diagnostico.ps1 }
        1 { . .\modulos\02_dhcp.ps1 }
        2 { 
            Log-Warning "Módulo DNS se implementará en la siguiente fase."
            Pausa 
        }
        3 { 
            Clear-Host
            Write-Host "Cerrando sistema..." -ForegroundColor Green
            exit 
        }
    }
}