#!/bin/bash

ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
RESET='\033[0m'

LOG_FILE="../../logs/linux_services.log"
mkdir -p "$(dirname "$LOG_FILE")"

log_info() { echo -e "${AZUL}[INFO]${RESET} $1"; }
log_ok() { echo -e "${VERDE}[OK]${RESET} $1"; }
log_error() { echo -e "${ROJO}[ERROR]${RESET} $1"; }
log_warning() { echo -e "${AMARILLO}[AVISO]${RESET} $1"; }

pausa() {
    echo -e "\n${AZUL}Presione [Enter] para continuar...${RESET}"
    read -r < /dev/tty
}

instalar_dependencia_silenciosa() {
    local paquete=$1
    if dpkg -s "$paquete" >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${AMARILLO}[AVISO] Instalando dependencia requerida: $paquete...${RESET}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>>"$LOG_FILE"
    if apt-get install -yq "$paquete" >/dev/null 2>>"$LOG_FILE"; then
        echo -e "\e[1A\e[K${VERDE}[OK] Dependencia lista: $paquete${RESET}"
        return 0
    else
        echo -e "\e[1A\e[K${ROJO}[ERROR] Fallo al instalar: $paquete. Revise $LOG_FILE${RESET}"
        return 1
    fi
}

generar_menu() {
    local titulo=$1
    local -n opciones_ref=$2
    local texto_salida=$3
    local opciones=("${opciones_ref[@]}" "$texto_salida")
    local seleccion=0

    while true; do
        clear
        echo "================================================="
        echo -e "                 ${AMARILLO}${titulo}${RESET}"
        echo "================================================="
        
        for ((i=0; i<${#opciones[@]}; i++)); do
            if [ $i -eq $seleccion ]; then
                echo -e "${VERDE}> \e[7m ${opciones[$i]} \e[0m${RESET}"
            else
                echo "   ${opciones[$i]}"
            fi
        done

        read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key
            if [[ $key == "[A" ]]; then
                ((seleccion--))
                [ $seleccion -lt 0 ] && seleccion=$((${#opciones[@]} - 1))
            elif [[ $key == "[B" ]]; then
                ((seleccion++))
                [ $seleccion -ge ${#opciones[@]} ] && seleccion=0
            fi
        elif [[ $key == "" ]]; then
            return $seleccion
        fi
    done
}

obtener_ip_local() {
    local iface="enp0s8"
    local ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    echo "$ip"
}

capturar_ip() {
    local mensaje=$1
    local ip_local=$(obtener_ip_local)
    local input_ip

    while true; do
        read -p "$mensaje [Enter para usar: ${ip_local:-Ninguna}]: " input_ip
        if [ -z "$input_ip" ] && [ -n "$ip_local" ]; then
            input_ip="$ip_local"
        fi
        
        if validar_formato_ip "$input_ip"; then
            echo "$input_ip"
            return 0
        else
            log_error "IP inválida o prohibida. Intente de nuevo." >&2
        fi
    done
}

capturar_ip_opcional() {
    local mensaje=$1
    local input_ip

    while true; do
        read -p "$mensaje [Enter para omitir]: " input_ip
        
        if [ -z "$input_ip" ]; then
            echo ""
            return 0
        fi
        
        if validar_formato_ip "$input_ip"; then
            echo "$input_ip"
            return 0
        else
            log_error "IP inválida o prohibida. Intente de nuevo o presione Enter para omitir." >&2
        fi
    done
}

confirmar_accion() {
    local mensaje=$1
    local opciones_binarias=("Sí, proceder con la acción")
    
    generar_menu "CONFIRMACIÓN: $mensaje" opciones_binarias "No, cancelar y volver"
    
    if [ $? -eq 0 ]; then
        return 0
    else
        return 1
    fi
}