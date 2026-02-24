#!/bin/bash
source libs/utils.sh
source libs/validaciones.sh

configurar_interfaz_ssh() {
    clear
    echo -e "${AMARILLO}--- DESPLIEGUE DE RED DE ADMINISTRACIÓN ---${RESET}"
    
    local interface="enp0s9"
    local ip_server="100.0.0.10"
    local ip_client="100.0.0.11"
    local cidr="24"
    
    echo -e "${CIAN}[1/3] Verificando y levantando la interfaz $interface...${RESET}"
    ip link set dev "$interface" up
    sleep 1
    
    if ! dpkg -s openssh-server >/dev/null 2>&1; then
        echo -e "${CIAN}[2/3] Instalando servidor SSH silenciosamente...${RESET}"
        instalar_dependencia_silenciosa "openssh-server"
        systemctl enable ssh --now >/dev/null 2>&1
        ufw allow 22/tcp >/dev/null 2>&1
    else
        echo -e "${VERDE}[2/3] Servicio SSH ya instalado y activo.${RESET}"
    fi

    echo -e "${CIAN}[3/3] Aplicando topología de red...${RESET}"
    if ip addr show "$interface" | grep -q "$ip_server"; then
        echo -e "${VERDE}[OK] La IP $ip_server ya está asignada a $interface.${RESET}"
    else
        ip addr add "$ip_server/$cidr" dev "$interface" 2>/dev/null
        systemctl restart ssh
        echo -e "${VERDE}[OK] IP $ip_server asignada correctamente.${RESET}"
    fi

    echo -e "\n${VERDE}========================================================================${RESET}"
    echo -e "${AMARILLO}  [!] CONFIGURACIÓN REQUERIDA EN LA MÁQUINA VIRTUAL CLIENTE [!]${RESET}"
    echo -e "${VERDE}========================================================================${RESET}"
    echo -e "La red de administración ha sido aislada en el segmento 1.1.1.1/24."
    echo -e "Para conectarte a este servidor sin sufrir desconexiones al tocar el DHCP,"
    echo -e "ejecuta estos comandos en tu VM Cliente sobre su interfaz"
    echo -e "correspondiente a la red interna 2:\n"
    
    echo -e "  ${CIAN}sudo ip link set dev <INTERFAZ_CLIENTE> up${RESET}"
    echo -e "  ${CIAN}sudo ip addr flush dev <INTERFAZ_CLIENTE>${RESET}"
    echo -e "  ${CIAN}sudo ip addr add $ip_client/$cidr dev <INTERFAZ_CLIENTE>${RESET}\n"
    
    echo -e "Comando de conexión (ejecutar en el cliente una vez configurada la IP):"
    echo -e "  ${AMARILLO}ssh ${SUDO_USER:-$USER}@$ip_server${RESET}"
    echo -e "${VERDE}========================================================================${RESET}"
    
    pausa
}

alternar_ssh() {
    clear
    echo -e "${AMARILLO}--- CONTROL DE SERVICIO SSH ---${RESET}"
    if systemctl is-active --quiet ssh; then
        if confirmar_accion "¿Desea DESACTIVAR el servicio SSH?"; then
            systemctl stop ssh
            log_warning "Servicio SSH detenido. (Atención: perderás la conexión actual)."
        fi
    else
        if confirmar_accion "¿Desea ACTIVAR el servicio SSH?"; then
            systemctl start ssh
            log_ok "Servicio SSH iniciado."
        fi
    fi
    pausa
}

menu_ssh() {
    local opciones_ssh=(
        "Desplegar Red de Administración SSH (enp0s9)"
        "Alternar Estado del Servicio (Start/Stop)"
    )
    
    while true; do
        local estado_actual="INACTIVO"
        systemctl is-active --quiet ssh && estado_actual="ACTIVO"
        
        generar_menu "MÓDULO DE GESTIÓN SSH [ $estado_actual ]" opciones_ssh "Volver al Menú Principal"
        local eleccion=$?
        
        case $eleccion in
            0) configurar_interfaz_ssh ;;
            1) alternar_ssh ;;
            2) break ;;
        esac
    done
}

menu_ssh