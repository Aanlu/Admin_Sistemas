#!/bin/bash

ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
CIAN='\033[0;36m'
RESET='\033[0m'

# Ruta absoluta basada en BASH_SOURCE — funciona sin importar CWD
_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$(cd "$_UTILS_DIR/../../.." 2>/dev/null && pwd)/logs/linux_services.log"
unset _UTILS_DIR
mkdir -p "$(dirname "$LOG_FILE")"

log_info() { echo -e "${AZUL}[INFO]${RESET} $1"; }
log_ok() { echo -e "${VERDE}[OK]${RESET} $1"; }
log_error() { echo -e "${ROJO}[ERROR]${RESET} $1"; }
log_warning() { echo -e "${AMARILLO}[AVISO]${RESET} $1"; }

# ============================================================
# _escapar_sed <valor>
# Escapa los metacaracteres que sed interpreta en el lado
# derecho de una sustitución con delimitador '|':
#   \  → \\   (debe ser primero para no doble-escapar)
#   |  → \|   (nuestro delimitador)
#   &  → \&   (en el reemplazo, & significa "match completo")
# ============================================================
_escapar_sed() {
    local valor="$1"
    # Orden importa: primero backslash, luego los demás
    printf '%s' "$valor" \
        | sed -e 's/\\/\\\\/g' \
              -e 's/|/\\|/g'   \
              -e 's/&/\\&/g'
}

# ============================================================
# _inyectar_template <archivo> <@@CLAVE@@> <valor_real>
# Reemplaza un placeholder en una plantilla de forma segura.
# Uso: _inyectar_template "/etc/nginx/nginx.conf" "@@DOMINIO@@" "$dominio"
# ============================================================
_inyectar_template() {
    local archivo="$1"
    local clave="$2"
    local valor="$3"

    if [ ! -f "$archivo" ]; then
        log_error "_inyectar_template: el archivo '$archivo' no existe."
        return 1
    fi

    local valor_esc
    valor_esc=$(_escapar_sed "$valor")
    sed -i "s|${clave}|${valor_esc}|g" "$archivo"
}

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

    # FIX VSCode: su terminal no es TTY estándar.
    # Forzamos lectura desde /dev/tty para que funcione
    # aunque stdin esté redirigido o sea un pseudo-terminal.
    local TTY_INPUT="/dev/tty"
    [ ! -r "$TTY_INPUT" ] && TTY_INPUT="/dev/stdin"

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

        # Leer el primer byte desde el TTY real
        IFS= read -rsn1 <"$TTY_INPUT" key

        if [[ $key == $'\x1b' ]]; then
            # FIX CRÍTICO: VSCode envía ESC, [, A/B en ráfagas separadas.
            # read -rsn2 espera 2 bytes en un solo syscall y falla si llegan
            # en ráfagas distintas. Leer de a 1 byte con timeout resuelve esto.
            local k2="" k3=""
            IFS= read -rsn1 -t 0.15 <"$TTY_INPUT" k2
            IFS= read -rsn1 -t 0.15 <"$TTY_INPUT" k3

            case "${k2}${k3}" in
                "[A")
                    ((seleccion--))
                    [ $seleccion -lt 0 ] && seleccion=$(( ${#opciones[@]} - 1 ))
                    ;;
                "[B")
                    ((seleccion++))
                    [ $seleccion -ge ${#opciones[@]} ] && seleccion=0
                    ;;
            esac
        elif [[ $key == "" ]]; then
            return $seleccion
        fi
    done
}

obtener_ip_local() {
    # PROBLEMA ORIGINAL: toma la primera interfaz con gateway = siempre NAT (10.0.2.x)
    # CORRECCIÓN: En VirtualBox con múltiples interfaces, preferir la que NO sea NAT.
    # NAT de VirtualBox siempre es 10.0.2.x — la excluimos explícitamente.
    # La interfaz bridge/host-only es la que el profesor ve desde Windows.

    local ip

    # Intento 1: Primera IP que no sea loopback ni NAT de VirtualBox
    ip=$(ip -4 addr show \
        | grep "inet " \
        | grep -oP '(?<=inet\s)\d+(\.\d+){3}' \
        | grep -v "^127\." \
        | grep -v "^10\.0\.2\." \
        | head -1)

    # Intento 2: Si no encontró nada (solo NAT disponible), usar la ruta default
    if [ -z "$ip" ]; then
        local iface
        iface=$(ip route | grep default | awk '{print $5}' | head -1)
        [ -n "$iface" ] && ip=$(ip -4 addr show "$iface" \
            | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    fi

    echo "$ip"
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

ejecutar_con_loader() {
    local mensaje="$1"
    shift
    local comando=("$@")

    # Pre-flight check de locks dpkg
    local lock_timer=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock     >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock          >/dev/null 2>&1; do

        if [ $lock_timer -eq 0 ]; then
            printf "  ${AMARILLO}[⏳]${RESET} Lock dpkg activo, esperando liberación..."
        fi
        sleep 1
        (( lock_timer++ ))

        if [ $lock_timer -ge 30 ]; then
            printf "\n"
            log_warning "Lock no liberado tras 30s. Forzando limpieza de dpkg..."
            fuser -k /var/lib/dpkg/lock-frontend >/dev/null 2>&1
            fuser -k /var/lib/dpkg/lock          >/dev/null 2>&1
            fuser -k /var/lib/apt/lists/lock     >/dev/null 2>&1
            fuser -k /var/cache/apt/archives/lock >/dev/null 2>&1
            dpkg --configure -a >> "$LOG_FILE" 2>&1
            break
        fi
    done
    [ $lock_timer -gt 0 ] && printf "\n"

    # CORRECCIÓN CRÍTICA: 'env VARIABLE=valor funcion_bash' falla porque
    # env solo ejecuta binarios del PATH, no funciones de Bash.
    # Exportamos DEBIAN_FRONTEND antes y llamamos el array directamente.
    export DEBIAN_FRONTEND=noninteractive
    "${comando[@]}" >> "$LOG_FILE" 2>&1 < /dev/null &
    local pid=$!

    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0

    while kill -0 $pid 2>/dev/null; do
        printf "\r  ${CIAN}%s${RESET} %s..." "${frames[i]}" "$mensaje"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.1
    done

    wait $pid
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        printf "\r\e[K  ${VERDE}[✔]${RESET} %s completado.\n" "$mensaje"
    else
        printf "\r\e[K  ${ROJO}[✖]${RESET} %s falló. (Revise $LOG_FILE)\n" "$mensaje"
    fi
    return $exit_code
}