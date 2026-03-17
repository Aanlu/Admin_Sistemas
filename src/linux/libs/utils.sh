#!/bin/bash

ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
CIAN='\033[0;36m'
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
    local i
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
    # 1er Intento: Preguntamos a la tabla de ruteo cuál es la interfaz que sale a internet (default gateway)
    local iface=$(ip route | grep default | awk '{print $5}' | head -n 1)
    
    # 2do Intento (Fallback): Si es una red aislada sin gateway, tomamos la primera interfaz que esté "UP" (encendida) que no sea localhost (lo)
    if [ -z "$iface" ]; then
        iface=$(ip -br link | grep UP | grep -v "lo" | awk '{print $1}' | head -n 1)
    fi
    
    # Si encontramos una interfaz válida, extraemos su IP con Regex
    if [ -n "$iface" ]; then
        ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1
    fi
}

capturar_ip() {
    local mensaje=$1
    local ip_sugerida=$2 # Nuevo: Recibe una sugerencia dinámica
    local input_ip

    while true; do
        if [ -n "$ip_sugerida" ]; then
            read -p "$mensaje [Enter para usar: $ip_sugerida]: " input_ip
            # Si da enter sin escribir, usamos la sugerida
            [ -z "$input_ip" ] && input_ip="$ip_sugerida"
        else
            read -p "$mensaje: " input_ip
        fi
        
        if validar_formato_ip "$input_ip"; then
            # Retornamos la IP normalizada (sin ceros octales)
            echo $(normalizar_ip "$input_ip")
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

INTERFAZ_SELECCIONADA=""

seleccionar_interfaz_dinamica() {
    # Extraemos las interfaces de forma 100% segura leyendo directamente el kernel
    local arr_ifaces=($(ls -1 /sys/class/net | grep -v lo))
    
    if [ ${#arr_ifaces[@]} -eq 0 ]; then
        log_error "No se detectaron interfaces de red en el sistema." >&2
        return 1
    fi

    # Pasamos el nuevo nombre (arr_ifaces) al generador de menús
    generar_menu "SELECCIONE LA INTERFAZ DE RED" arr_ifaces "Cancelar"
    local eleccion=$?
    
    if [ $eleccion -eq ${#arr_ifaces[@]} ]; then 
        return 1 # El usuario canceló
    fi
    
    # Extraemos el valor correctamente
    INTERFAZ_SELECCIONADA="${arr_ifaces[$eleccion]}"
    return 0
}

ARCHIVO_ESTADO="/etc/admin_sistemas/estado.conf"

inicializar_estado() {
    local dir_estado=$(dirname "$ARCHIVO_ESTADO")
    if [ ! -d "$dir_estado" ]; then
        mkdir -p "$dir_estado"
        chmod 700 "$dir_estado" # Solo root puede ver esta carpeta
    fi
    if [ ! -f "$ARCHIVO_ESTADO" ]; then
        touch "$ARCHIVO_ESTADO"
        chmod 600 "$ARCHIVO_ESTADO"
        # Variables por defecto al nacer el sistema
        echo "DOMINIO_SSL=reprobados.com" > "$ARCHIVO_ESTADO"
        echo "MODO_OFFLINE=false" >> "$ARCHIVO_ESTADO"
    fi
}

# Uso: guardar_estado "CLAVE" "Valor nuevo"
guardar_estado() {
    local clave="$1"
    local valor="$2"
    
    inicializar_estado
    
    # Idempotencia: Si la clave ya existe, la actualiza. Si no, la agrega.
    if grep -q "^${clave}=" "$ARCHIVO_ESTADO"; then
        # Usamos pipes (|) en el sed por si el valor contiene barras (ej. rutas de carpetas)
        sed -i "s|^${clave}=.*|${clave}=${valor}|" "$ARCHIVO_ESTADO"
    else
        echo "${clave}=${valor}" >> "$ARCHIVO_ESTADO"
    fi
}

# Uso: variable=$(leer_estado "CLAVE")
leer_estado() {
    local clave="$1"
    inicializar_estado
    
    # Extrae solo lo que está después del signo igual
    grep "^${clave}=" "$ARCHIVO_ESTADO" | cut -d'=' -f2-
}

# Exportamos el dominio globalmente cada vez que utils.sh es invocado por un módulo
inicializar_estado
export DOMINIO_SSL=$(leer_estado "DOMINIO_SSL")