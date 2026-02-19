#!/bin/bash

[ "$EUID" -ne 0 ] && { echo "Este script debe ser ejecutado como root."; exit 1; }

cd "$(dirname "$0")" || exit 1
source libs/utils.sh

opciones_principales=(
    "Diagnóstico de Red"
    "Configuración Servidor DHCP"
    "Configuración Servidor DNS (CRUD)"
)

while true; do
    generar_menu "      MENÚ PRINCIPAL" opciones_principales "Salir del Sistema"
    eleccion=$?

    case $eleccion in
        0) bash modulos/01_diagnostico.sh ;;
        1) bash modulos/02_dhcp.sh ;;
        2) log_warning "Módulo DNS se implementará en la siguiente fase."; pausa ;;
        3) clear; echo -e "${VERDE}Cerrando sistema...${RESET}"; exit 0 ;;
    esac
done