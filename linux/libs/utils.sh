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
    local nat_iface=$(ip route show default | awk '{print $5}' | head -n1)
    
    if [ -z "$nat_iface" ]; then
        nat_iface="lo"
    fi

    local target_ip=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | grep -v "$nat_iface" | head -n 1)
    
    if [ -z "$target_ip" ]; then
        target_ip="enp0s8" 
    fi
    
    echo "$target_ip"
}

validar_formato_ip() {
    local ip=$1
    
    if [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        IFS='.' read -r -a octetos <<< "$ip"
        
        for oct in "${octetos[@]}"; do
            if [[ "$oct" -lt 0 || "$oct" -gt 255 ]]; then
                return 1
            fi
        done

        if [[ "$ip" == "0.0.0.0" ]]; then return 1; fi
        if [[ "$ip" == "255.255.255.255" ]]; then return 1; fi
        if [[ ${octetos[0]} -eq 127 ]]; then return 1; fi
        if [[ ${octetos[0]} -ge 224 ]]; then return 1; fi
        
        return 0
    else
        return 1
    fi
}

validar_rango(){
    local ip1=$1
    local ip2=$2
    
    local red1=$(echo "$ip1" | cut -d. -f1-3)
    local red2=$(echo "$ip2" | cut -d. -f1-3)

    if [ "$red1" != "$red2" ]; then
        log_error "Las IPs deben pertenecer al mismo segmento de red."
        return 1
    fi

    local host1=$(echo "$ip1" | cut -d. -f4)
    local host2=$(echo "$ip2" | cut -d. -f4)

    if [ "$host2" -gt "$host1" ]; then
        return 0
    else
        return 1
    fi
}

preparar_servidor(){
    local iface=$1
    local ip_fija="192.168.100.20/24" 

    log_info "Asignando IP fija $ip_fija a la interfaz $iface..."

    ip link set dev "$iface" up
    ip addr flush dev "$iface"
    ip addr add "$ip_fija" dev "$iface"

    if ip addr show "$iface" | grep -q "192.168.100.20"; then
        log_ok "IP fija asignada correctamente."
    else
        log_error "Error al asignar la IP fija."
        exit 1
    fi
}