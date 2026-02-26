#!/bin/bash

[ "$EUID" -ne 0 ] && { echo "Este script debe ser ejecutado como root."; exit 1; }

DIR_BASE=$(dirname "$(readlink -f "$0")")
cd "$DIR_BASE" || exit 1

source libs/utils.sh

opciones_principales=(
    "Diagnóstico de Red"
    "Configuración Servidor DHCP"
    "Configuración Servidor DNS"
    "SSH"
)

while true; do
    generar_menu "      MENÚ PRINCIPAL" opciones_principales "Salir del Sistema"
    eleccion=$?

    # Al usar 'bash' en lugar de 'source', cada módulo nace y muere en su propia burbuja de memoria.
    case $eleccion in
        0) bash modulos/01_diagnostico.sh ;;
        1) bash modulos/02_dhcp.sh ;;
        2) bash modulos/03_dns.sh ;;
        3) bash modulos/04_ssh.sh ;;
        4) clear; echo -e "${VERDE}Cerrando sistema...${RESET}"; exit 0 ;;
    esac
done