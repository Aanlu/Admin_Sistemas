#!/bin/bash

validar_formato_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        IFS='.' read -r -a octetos <<< "$ip"
        for oct in "${octetos[@]}"; do
            # Forzamos base 10 para evaluar el límite de 255
            local num=$((10#$oct))
            if [[ "$num" -lt 0 || "$num" -gt 255 ]]; then return 1; fi
        done
        
        local ip_limpia=$(normalizar_ip "$ip")
        if [[ "$ip_limpia" == "0.0.0.0" || "$ip_limpia" == "255.255.255.255" || "$ip_limpia" == "127.0.0.1" ]]; then return 1; fi
        return 0
    else
        return 1
    fi
}

validar_rango() {
    local ip1=$1 
    local ip2=$2 
    local int_ip1=0
    local int_ip2=0
    
    IFS=. read -r i1 i2 i3 i4 <<< "$ip1"
    int_ip1=$(( (10#$i1 << 24) + (10#$i2 << 16) + (10#$i3 << 8) + 10#$i4 ))
    
    IFS=. read -r i1 i2 i3 i4 <<< "$ip2"
    int_ip2=$(( (10#$i1 << 24) + (10#$i2 << 16) + (10#$i3 << 8) + 10#$i4 ))
    
    if [ "$int_ip2" -le "$int_ip1" ]; then return 1; fi
    return 0
}

obtener_mascara() {
    local ip=$1
    local pri_oct=$(echo "$ip" | cut -d. -f1)
    local num=$((10#$pri_oct))
    
    if [ "$num" -ge 1 ] && [ "$num" -le 126 ]; then echo "255.0.0.0";
    elif [ "$num" -ge 128 ] && [ "$num" -le 191 ]; then echo "255.255.0.0";
    else echo "255.255.255.0"; fi
}

obtener_id_red() {
    local ip=$1
    local mask=$2
    
    IFS=. read -r i1 i2 i3 i4 <<< "$ip"
    IFS=. read -r m1 m2 m3 m4 <<< "$mask"
    
    echo "$((10#$i1 & 10#$m1)).$((10#$i2 & 10#$m2)).$((10#$i3 & 10#$m3)).$((10#$i4 & 10#$m4))"
}

incrementar_ip() {
    local ip=$1
    IFS='.' read -r a b c d <<< "$ip"
    
    a=$((10#$a))
    b=$((10#$b))
    c=$((10#$c))
    d=$((10#$d))
    
    d=$((d + 1))
    if [ "$d" -gt 255 ]; then
        d=0; c=$((c + 1))
        if [ "$c" -gt 255 ]; then
            c=0; b=$((b + 1))
            if [ "$b" -gt 255 ]; then
                b=0; a=$((a + 1))
            fi
        fi
    fi
    echo "$a.$b.$c.$d"
}

normalizar_ip() {
    local ip_sucia=$1
    if [[ $ip_sucia =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        IFS='.' read -r i1 i2 i3 i4 <<< "$ip_sucia"
        echo "$((10#$i1)).$((10#$i2)).$((10#$i3)).$((10#$i4))"
    else
        echo "$ip_sucia"
    fi
}
capturar_entero() {
    local mensaje=$1
    local input_num
    while true; do
        read -p "$mensaje: " input_num
        if [[ "$input_num" =~ ^[1-9][0-9]{0,2}$ ]]; then
            echo "$input_num"
            return 0
        else
            log_error "Entrada inválida. Debe ser un número entero mayor a 0." >&2
        fi
    done
}

capturar_usuario_seguro() {
    local mensaje=$1
    local input_str
    while true; do
        read -p "$mensaje: " input_str
        if [[ "$input_str" =~ ^[a-z_][a-z0-9_-]{1,31}$ ]]; then
            echo "$input_str"
            return 0
        else
            log_error "Nombre inválido. Use solo minúsculas y números (sin espacios)." >&2
        fi
    done
}