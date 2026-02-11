#!/bin/bash

ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
RESET='\033[0m'

log_info() { echo -e "${AZUL}[INFO]${RESET} $1"; }
log_ok() { echo -e "${VERDE}[OK]${RESET} $1"; }
log_error() { echo -e "${ROJO}[ERROR]${RESET} $1"; }
log_warning() { echo -e "${AMARILLO}[AVISO]${RESET} $1"; }

pausa() { read -rsp "Presione [Enter] para continuar..." -n1; echo ""; }

detectar_intefaz() {
    local iface=$(ip route show default | awk '{print $5}' | head -n1)
    if [ -z "$iface" ]; then
        iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -n 1)
    fi
    echo "$iface"
}

validar_formato_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        IFS='.' read -r -a octetos <<< "$ip"
        for oct in "${octetos[@]}"; do
            if [[ "$oct" -lt 0 || "$oct" -gt 255 ]]; then return 1; fi
        done
        
        if [[ "$ip" == "0.0.0.0" ]]; then return 1; fi
        if [[ "$ip" == "255.255.255.255" ]]; then return 1; fi
        if [[ "${octetos[0]}" -eq 127 ]]; then return 1; fi
        
        return 0
    else
        return 1
    fi
}

validar_rango(){
    local ip1=$1; local ip2=$2
    IFS=. read -r a b c d <<< "$ip1"
    local val1=$((a * 256 ** 3 + b * 256 ** 2 + c * 256 + d))
    IFS=. read -r a b c d <<< "$ip2"
    local val2=$((a * 256 ** 3 + b * 256 ** 2 + c * 256 + d))
    
    if [ "$val2" -gt "$val1" ]; then return 0; else return 1; fi
}

obtener_mascara() {
    local ip=$1
    local pri_oct=$(echo "$ip" | cut -d. -f1)
    if [ "$pri_oct" -ge 1 ] && [ "$pri_oct" -le 126 ]; then echo "255.0.0.0";
    elif [ "$pri_oct" -ge 128 ] && [ "$pri_oct" -le 191 ]; then echo "255.255.0.0";
    else echo "255.255.255.0"; fi
}

obtener_id_red() {
    local ip=$1; local mask=$2
    IFS=. read -r i1 i2 i3 i4 <<< "$ip"
    IFS=. read -r m1 m2 m3 m4 <<< "$mask"
    echo "$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).$((i4 & m4))"
}

preparar_servidor(){
    local iface=$1; local ip_asignada=$2; local mascara=$3
    local cidr=24
    [ "$mascara" == "255.0.0.0" ] && cidr=8
    [ "$mascara" == "255.255.0.0" ] && cidr=16

    ip link set dev "$iface" up
    ip addr flush dev "$iface"
    ip addr add "$ip_asignada/$cidr" dev "$iface"
    sleep 1
}