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

    case $eleccion in
        0) source modulos/01_diagnostico.sh ;;
        1) source modulos/02_dhcp.sh ;;
        2) source modulos/03_dns.sh ;;
        3) source modulos/04_ssh.sh ;;
        4) clear; echo -e "${VERDE}Cerrando sistema...${RESET}"; exit 0 ;;
    esac
done