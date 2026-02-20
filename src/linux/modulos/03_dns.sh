#!/bin/bash

source libs/utils.sh
source libs/validaciones.sh

verificar_ip_fija() {
    clear
    echo -e "${AMARILLO}--- VERIFICACIÓN DE RED ESTÁTICA ---${RESET}"
    local iface="enp0s8" 
    local ip_actual=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    
    if [ -z "$ip_actual" ]; then
        log_warning "No se detectó una IP configurada en la interfaz $iface."
    else
        log_info "IP actual detectada en $iface: $ip_actual"
    fi

    if confirmar_accion "¿Desea asignar una nueva IP fija antes de continuar?"; then
        local nueva_ip=$(capturar_ip "Ingrese la nueva IP fija a asignar")
        local mascara=$(obtener_mascara "$nueva_ip")
        local cidr=24
        [ "$mascara" == "255.0.0.0" ] && cidr=8
        [ "$mascara" == "255.255.0.0" ] && cidr=16
        
        ip addr flush dev "$iface"
        ip addr add "$nueva_ip/$cidr" dev "$iface"
        ip link set dev "$iface" up
        log_ok "IP Fija asignada correctamente: $nueva_ip"
    else
        log_info "Manteniendo configuración de red actual."
    fi
    pausa
}

verificar_ip_fija

instalar_dependencia_silenciosa "bind9" || { log_error "Fallo al instalar bind9."; pausa; exit 1; }
instalar_dependencia_silenciosa "bind9utils" || { log_error "Fallo al instalar bind9utils."; pausa; exit 1; }
instalar_dependencia_silenciosa "bind9-doc" || { log_error "Fallo al instalar bind9-doc."; pausa; exit 1; }
instalar_dependencia_silenciosa "dnsutils" || { log_error "Fallo al instalar dnsutils."; pausa; exit 1; }

TEMPLATE_ZONA="../../templates/linux/db.zona.template"
CONF_LOCAL="/etc/bind/named.conf.local"
DIR_ZONAS="/var/cache/bind"

[ ! -d "$DIR_ZONAS" ] && mkdir -p "$DIR_ZONAS"

ZONA_SELECCIONADA=""

seleccionar_zona() {
    local zonas=()
    ZONA_SELECCIONADA=""
    
    for archivo in "$DIR_ZONAS"/db.*; do
        if [ -f "$archivo" ]; then
            local nombre_base=$(basename "$archivo")
            zonas+=("${nombre_base#db.}")
        fi
    done

    if [ ${#zonas[@]} -eq 0 ]; then
        return 1
    fi

    generar_menu "SELECCIONE LA ZONA DNS" zonas "Cancelar y Volver"
    local eleccion=$?

    if [ $eleccion -eq ${#zonas[@]} ]; then
        return 2
    else
        ZONA_SELECCIONADA="${zonas[$eleccion]}"
        return 0
    fi
}

crear_zona() {
    clear
    echo -e "${AMARILLO}--- CREACIÓN DE ZONA DNS ---${RESET}"
    
    if systemctl is-active --quiet bind9; then
        log_info "Servicio BIND9 detectado y operando en segundo plano."
    fi

    if [ ! -f "$TEMPLATE_ZONA" ]; then
        log_error "Falta el archivo de plantilla base en la ruta de templates."
        pausa; return
    fi

    local dominio
    while true; do
        read -p "Ingrese el nombre del dominio principal a configurar: " dominio
        [ -z "$dominio" ] && return
        dominio=${dominio,,}
        dominio=${dominio#www.}
        if [[ ! "$dominio" =~ ^[a-z0-9-]+\.[a-z]{2,}(\.[a-z]{2,})?$ ]]; then
            log_error "Formato inválido. Indique una extensión de dominio válida."
            continue 
        fi
        break
    done

    local archivo_zona="$DIR_ZONAS/db.$dominio"
    if [ -f "$archivo_zona" ]; then
        log_error "La zona ya existe en el servidor. Abortando para evitar sobrescritura."
        pausa; return
    fi

    local ip_server=$(capturar_ip "IP del Servidor para registros raíz y subdominios")

    cp "$TEMPLATE_ZONA" "$archivo_zona"
    sed -i "s/@@DOMINIO@@/$dominio/g" "$archivo_zona"
    sed -i "s/@@IP_SERVIDOR@@/$ip_server/g" "$archivo_zona"

    if ! grep -q "zone \"$dominio\"" "$CONF_LOCAL"; then
        cat >> "$CONF_LOCAL" <<EOF
zone "$dominio" {
    type master;
    file "$archivo_zona";
};
EOF
    fi

    if named-checkconf >/dev/null 2>&1 && named-checkzone "$dominio" "$archivo_zona" >/dev/null 2>&1; then
        systemctl restart bind9
        log_ok "Zona de dominio generada y cargada exitosamente."
    else
        log_error "Error de sintaxis en el archivo. Se requiere revisión manual."
    fi
    pausa
}

leer_zona() {
    seleccionar_zona
    local estado=$?
    [ $estado -eq 1 ] && { clear; log_error "No hay zonas DNS creadas actualmente."; pausa; return; }
    [ $estado -eq 2 ] && return

    local dominio="$ZONA_SELECCIONADA"
    local archivo_zona="$DIR_ZONAS/db.$dominio"

    clear
    echo -e "${AMARILLO}--- LECTURA DE REGISTROS ---${RESET}"
    echo -e "\n${AZUL}[ Registros de la zona: $dominio ]${RESET}"
    printf "${AMARILLO}%-20s %-10s %-20s${RESET}\n" "HOSTNAME" "TIPO" "DIRECCIÓN IP"
    echo "--------------------------------------------------"
    grep -E "\s+IN\s+(A|CNAME)\s+" "$archivo_zona" | grep -v "@@" | awk '{
        printf "%-20s %-10s %-20s\n", $1, $3, $4
    }'
    pausa
}

agregar_registro() {
    seleccionar_zona
    local estado=$?
    [ $estado -eq 1 ] && { clear; log_error "No hay zonas para modificar. Gestione una primero."; pausa; return; }
    [ $estado -eq 2 ] && return

    local dominio="$ZONA_SELECCIONADA"
    local archivo_zona="$DIR_ZONAS/db.$dominio"

    clear
    echo -e "${AMARILLO}--- AGREGAR / MODIFICAR HOST EN ZONA: $dominio ---${RESET}"
    
    echo -e "\n${AZUL}[ Registros actuales ]${RESET}"
    printf "${AMARILLO}%-20s %-10s %-20s${RESET}\n" "HOSTNAME" "TIPO" "DIRECCIÓN IP"
    echo "--------------------------------------------------"
    grep -E "\s+IN\s+A\s+" "$archivo_zona" | grep -v "@@" | awk '{
        printf "%-20s %-10s %-20s\n", $1, $3, $4
    }'
    echo ""
    
    local host
    while true; do
        read -p "Nombre del host a registrar o modificar (ej. www, @, ns1): " host
        [ -z "$host" ] && continue
        
        host=${host,,}
        host=${host%.$dominio}
        
        if [[ ! "$host" =~ ^[a-z0-9-]+$ ]] && [[ "$host" != "@" ]]; then
            log_error "Caracteres inválidos. Emplee únicamente letras, números, guiones o @."
            continue
        fi
        break
    done

    local ip_host=$(capturar_ip "Nueva IP a asignar al host")

    if grep -q "^$host\s" "$archivo_zona"; then
        log_warning "El host indicado ya existe en esta zona."
        if confirmar_accion "¿Desea ACTUALIZAR la IP de este registro existente?"; then
            cp "$archivo_zona" "$archivo_zona.bak"
            
            sed -i -E "/^${host}[[:space:]]+IN[[:space:]]+A/d" "$archivo_zona"
            
            [ -n "$(tail -c 1 "$archivo_zona")" ] && echo "" >> "$archivo_zona"
            echo "$host   IN   A   $ip_host" >> "$archivo_zona"
            
            local salida_bind
            if salida_bind=$(named-checkzone "$dominio" "$archivo_zona" 2>&1); then
                rm "$archivo_zona.bak"
                systemctl restart bind9
                log_ok "Registro actualizado y servicio DNS reiniciado correctamente."
            else
                mv "$archivo_zona.bak" "$archivo_zona"
                log_error "Fallo de validación. Se revirtió el cambio para proteger la zona."
                echo -e "\n${ROJO}--- DETALLE TÉCNICO DEL RECHAZO (BIND9) ---${RESET}"
                echo "$salida_bind"
                echo -e "${ROJO}-------------------------------------------${RESET}"
            fi
        else
            log_info "Modificación cancelada. El registro original se mantiene intacto."
        fi
    else
        [ -n "$(tail -c 1 "$archivo_zona")" ] && echo "" >> "$archivo_zona"
        echo "$host   IN   A   $ip_host" >> "$archivo_zona"
        
        local salida_bind
        if salida_bind=$(named-checkzone "$dominio" "$archivo_zona" 2>&1); then
            systemctl restart bind9
            log_ok "Nuevo host agregado y servicio DNS actualizado correctamente."
        else
            sed -i -E "/^${host}[[:space:]]+IN[[:space:]]+A[[:space:]]+${ip_host}$/d" "$archivo_zona"
            log_error "Fallo de validación. Se revirtió el cambio para proteger el servicio."
            echo -e "\n${ROJO}--- DETALLE TÉCNICO DEL RECHAZO (BIND9) ---${RESET}"
            echo "$salida_bind"
            echo -e "${ROJO}-------------------------------------------${RESET}"
        fi
    fi
    pausa
}

eliminar_registro() {
    seleccionar_zona
    local estado=$?
    [ $estado -eq 1 ] && { clear; log_error "No hay zonas disponibles para modificar."; pausa; return; }
    [ $estado -eq 2 ] && return

    local dominio="$ZONA_SELECCIONADA"
    local archivo_zona="$DIR_ZONAS/db.$dominio"

    clear
    echo -e "${AMARILLO}--- ELIMINAR HOST DE ZONA: $dominio ---${RESET}"
    
    echo -e "\n${AZUL}[ Hosts activos en la configuración ]${RESET}"
    printf "${AMARILLO}%-20s %-10s %-20s${RESET}\n" "HOSTNAME" "TIPO" "DIRECCIÓN IP"
    echo "--------------------------------------------------"
    grep -E "\s+IN\s+A\s+" "$archivo_zona" | grep -v "@@" | awk '{
        printf "%-20s %-10s %-20s\n", $1, $3, $4
    }'
    echo ""
    
    read -p "Nombre del host a eliminar: " host
    host=${host,,}
    host=${host%.$dominio}
    
    if [ "$host" == "ns1" ] || [ "$host" == "@" ]; then
        log_error "Prohibido eliminar registros críticos del sistema."
        pausa; return
    fi

    if grep -q "^$host\s" "$archivo_zona"; then
        if confirmar_accion "¿Confirma la eliminación permanente del host seleccionado?"; then
            sed -i "/^$host\s.*IN\s.*A/d" "$archivo_zona"
            systemctl restart bind9
            log_ok "Registro de host eliminado correctamente."
        else
            log_warning "Eliminación cancelada por el usuario."
        fi
    else
        log_error "El host no se encontró en la tabla de la zona."
    fi
    pausa
}

validar_resolucion() {
    seleccionar_zona
    local estado=$?
    [ $estado -eq 1 ] && { clear; log_error "No hay zonas DNS disponibles para someter a validación."; pausa; return; }
    [ $estado -eq 2 ] && return

    local dominio="$ZONA_SELECCIONADA"
    
    clear
    echo -e "${AMARILLO}--- VALIDACIÓN Y PRUEBAS DE RESOLUCIÓN ---${RESET}"
    
    echo -e "\n${AZUL}Fase 1: Verificación de Sintaxis con checkconf...${RESET}"
    if named-checkconf >/dev/null 2>&1; then
        log_ok "Sintaxis global operativa y correcta."
    else
        log_error "Se encontraron errores estructurales en named.conf.local."
    fi

    echo -e "\n${AZUL}Fase 2: Prueba de Resolución local mediante nslookup...${RESET}"
    nslookup "$dominio" 127.0.0.1 || log_error "Fallo en la resolución del servidor de nombres."

    echo -e "\n${AZUL}Fase 3: Prueba de Conectividad de red hacia el subdominio web...${RESET}"
    ping -c 3 "www.$dominio" || log_warning "Paquetes perdidos. Posible bloqueo de cortafuegos ICMP o equipo apagado."
    
    pausa
}

modificar_nombre_zona() {
    seleccionar_zona
    local estado=$?
    [ $estado -eq 1 ] && { clear; log_error "No hay zonas para renombrar."; pausa; return; }
    [ $estado -eq 2 ] && return

    local dominio_viejo="$ZONA_SELECCIONADA"
    local archivo_viejo="$DIR_ZONAS/db.$dominio_viejo"

    clear
    echo -e "${AMARILLO}--- MIGRACIÓN DE DOMINIO (RENOMBRAR ZONA) ---${RESET}"
    echo -e "${AZUL}Zona actual a modificar: $dominio_viejo${RESET}"
    
    local dominio_nuevo
    while true; do
        read -p "Ingrese el NUEVO nombre del dominio (ej. aprobados.com): " dominio_nuevo
        [ -z "$dominio_nuevo" ] && return
        
        dominio_nuevo=${dominio_nuevo,,}
        dominio_nuevo=${dominio_nuevo#www.}
        
        if [[ ! "$dominio_nuevo" =~ ^[a-z0-9-]+\.[a-z]{2,}(\.[a-z]{2,})?$ ]]; then
            log_error "Formato inválido. Indique una extensión de dominio válida."
            continue 
        fi
        if [ "$dominio_viejo" == "$dominio_nuevo" ]; then
            log_error "El nuevo nombre no puede ser idéntico al actual."
            continue
        fi
        break
    done

    local archivo_nuevo="$DIR_ZONAS/db.$dominio_nuevo"
    
    if [ -f "$archivo_nuevo" ]; then
        log_error "El dominio '$dominio_nuevo' ya existe. Colisión detectada."
        pausa; return
    fi

    if confirmar_accion "¿Confirma la migración de $dominio_viejo hacia $dominio_nuevo?"; then

        cp "$archivo_viejo" "$archivo_nuevo"
        
        sed -i "s/$dominio_viejo/$dominio_nuevo/g" "$archivo_nuevo"
        

        sed -i "s/zone \"$dominio_viejo\"/zone \"$dominio_nuevo\"/g" "$CONF_LOCAL"
        sed -i "s/db.$dominio_viejo/db.$dominio_nuevo/g" "$CONF_LOCAL"
        

        if named-checkconf >/dev/null 2>&1 && named-checkzone "$dominio_nuevo" "$archivo_nuevo" >/dev/null 2>&1; then

            rm -f "$archivo_viejo"
            systemctl restart bind9
            log_ok "Migración exitosa. La zona ahora opera como $dominio_nuevo"
        else
            rm -f "$archivo_nuevo"
            sed -i "s/zone \"$dominio_nuevo\"/zone \"$dominio_viejo\"/g" "$CONF_LOCAL"
            sed -i "s/db.$dominio_nuevo/db.$dominio_viejo/g" "$CONF_LOCAL"
            log_error "La validación de BIND9 falló. Se revirtieron los cambios por seguridad."
        fi
    else
        log_warning "Migración cancelada."
    fi
    pausa
}
eliminar_zona() {
    seleccionar_zona
    local estado=$?
    [ $estado -eq 1 ] && { clear; log_error "No hay zonas DNS para eliminar."; pausa; return; }
    [ $estado -eq 2 ] && return

    local dominio="$ZONA_SELECCIONADA"
    local archivo_zona="$DIR_ZONAS/db.$dominio"

    clear
    echo -e "${AMARILLO}--- DESTRUCCIÓN DE ZONA DNS: $dominio ---${RESET}"
    
    echo -e "${ROJO}¡ADVERTENCIA! Esta acción destruirá el archivo físico y desconectará la zona del orquestador.${RESET}"
    
    if confirmar_accion "¿Está absolutamente seguro de ELIMINAR toda la zona '$dominio'?"; then
        rm -f "$archivo_zona"
        
        sed -i "/zone \"$dominio\" {/,/};/d" "$CONF_LOCAL"
        
        systemctl restart bind9
        log_ok "La zona $dominio y todos sus registros han sido aniquilados del servidor."
    else
        log_warning "Destrucción abortada."
    fi
    pausa
}

menu_dns() {
    local opciones_dns=(
        "Crear Nueva Zona DNS"
        "Listar Registros de Zona"
        "Agregar / Modificar Registro de Host"
        "Eliminar Registro de Host"
        "Modificar Nombre de Zona (Renombrar)"
        "Eliminar Zona DNS Completa"
        "Validar Resolución de Nombres"
    )
    
    while true; do
        generar_menu "MÓDULO DE GESTIÓN DNS" opciones_dns "Volver al Menú Principal"
        local eleccion=$?
        
        case $eleccion in
            0) crear_zona ;;
            1) leer_zona ;;
            2) agregar_registro ;;
            3) eliminar_registro ;;
            4) modificar_nombre_zona ;;
            5) eliminar_zona ;;
            6) validar_resolucion ;;
            7) break ;;
        esac
    done
}

menu_dns