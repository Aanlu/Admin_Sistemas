#!/bin/bash

# Colores para resaltar información
ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[0;33m'
AZUL='\033[0;34m'
RESET='\033[0m'

#log_info: Imprime un mensaje de información
log_info() {
    echo -e "${VERDE}[INFO]${RESET} $1"
}
#log_ok: Imprime un mensaje de éxito
log_ok() {
    echo -e "${VERDE}[OK]${RESET} $1"
}
#log_error: Imprime un mensaje de advertencia
log_error() {
    echo -e "${ROJO}[ERROR]${RESET} $1"
}

detectar_intefaz() {
    local nat_interface=$(ip route show default | awk '{print $5}' | head -n 1) # Detectar la interfaz de red utilizada para la conexión a Internet

    local target_ip=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -n 1) # Obtener la primera interfaz de red no loopback

    if [ -z "$target_ip" ]; then
        target_ip=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -n 1) # Si no se encuentra la interfaz de red, usar la primera interfaz no loopback
    fi

}

validar_formato_ip() {
    local ip=$1 # Obtener la dirección IP del host local

    # Validar el formato de la dirección IP utilizando una expresión regular
    if [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then 
        IFS='.' read -r -a octetos <<< "$ip" # Dividir la dirección IP en octetos
        for oct in "${octetos[@]}"; do # Validar que cada octeto esté en el rango de 0 a 255
            if [[ "&oct" -lt 0 || "&oct" -gt 255 ]]; then # Si algún octeto no está en el rango válido, imprimir un mensaje de error y salir
                log_error "La dirección IP no es válida: $ip"
                return 1
            fi
        done
    else
        return 0
    fi
}

validar_rango(){
    local ip1=$1 # Obtener la dirección IP del host local
    local ip2=$2 # Obtener la dirección IP del host remoto

    local last1=$(echo "$ip1" | cut -d. -f4) # Obtener el último octeto de la dirección IP del host local
    local last2=$(echo "$ip2" | cut -d. -f4) # Obtener el último octeto de la dirección IP del host remoto

    if [ "$last2" -gt "$last1" ]; then # Validar que el último octeto de la dirección IP del host remoto sea mayor que el del host local
        return 0
    else
        return 1
    fi
}