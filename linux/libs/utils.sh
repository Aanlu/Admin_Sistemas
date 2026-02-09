#!/bin/bash

ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[0;33m'
AZUL='\033[0;34m'
RESET='\033[0m'

log_info() {
    echo -e "${AZUL}[INFO]${RESET} $1"
}
log_ok() {
    echo -e "${VERDE}[OK]${RESET} $1"
}
log_error() {
    echo -e "${ROJO}[ERROR]${RESET} $1"
}

log_warning() {
    echo -e "${AMARILLO}[WARNING]${RESET} $1"
}

pausa() {
    read -p "Presione [Enter] para continuar..."
}

detectar_intefaz() {
    local target_ip=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -n 1)
    if [ -z "$target_ip" ]; then
        target_ip=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -n 1)
    fi
    echo "$target_ip"
}

validar_formato_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then 
        IFS='.' read -r -a octetos <<< "$ip"
        for oct in "${octetos[@]}"; do
            if [[ "$oct" -lt 0 || "$oct" -gt 255 ]]; then
                log_error "La dirección IP no es válida: $ip"
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

validar_rango(){
    local ip1=$1
    local ip2=$2
    local last1=$(echo "$ip1" | cut -d. -f4)
    local last2=$(echo "$ip2" | cut -d. -f4)

    if [ "$last2" -gt "$last1" ]; then
        return 0
    else
        return 1
    fi
}

