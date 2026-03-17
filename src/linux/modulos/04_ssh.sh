#!/bin/bash
source libs/utils.sh
source libs/validaciones.sh

configurar_interfaz_ssh() {
    
    # 1. Menú Dinámico: Dejamos que el sistema dicte qué interfaces existen
    seleccionar_interfaz_dinamica
    if [ $? -ne 0 ]; then
        log_warning "Configuración SSH cancelada."
        pausa; return
    fi
    
    local interface="$INTERFAZ_SELECCIONADA"

    # El resto de tu código a partir de aquí se mantiene exactamente igual...
    local ip_server=$(capturar_ip "IP del Servidor SSH" "100.0.0.10")
    local cidr="24"
    
    echo -e "${CIAN}[1/3] Levantando administrativamente $interface...${RESET}"
    ip link set dev "$interface" up
    
    if ! dpkg -s openssh-server >/dev/null 2>&1; then
        echo -e "${CIAN}[2/3] Instalando servidor SSH silenciosamente...${RESET}"
        instalar_dependencia_silenciosa "openssh-server"
        systemctl enable ssh --now >/dev/null 2>&1
        ufw allow 22/tcp >/dev/null 2>&1
    else
        echo -e "${VERDE}[2/3] Servicio SSH ya instalado y activo.${RESET}"
    fi

    echo -e "${CIAN}[3/3] Aplicando topología de red de forma segura...${RESET}"
    
    # 1. Reemplazo atómico para no tirar el túnel SSH si estamos conectados
    ip addr replace "$ip_server/$cidr" dev "$interface" 2>/dev/null
    
    # 2. Limpiamos silenciosamente IPs anteriores que no sean la nueva
    ip -4 addr show dev "$interface" | grep "inet" | grep -v "$ip_server" | awk '{print $2}' | while read -r old_ip; do
        ip addr del "$old_ip" dev "$interface" 2>/dev/null
    done
    
    systemctl restart ssh

    # 3. Auditoría Inteligente: Polling en lugar de Sleep
    echo -e "${CIAN}[*] Validando demonio SSH y conectividad de red...${RESET}"
    local TIMEOUT=10
    local CONTADOR=0
    local LISTO=false

    while [ $CONTADOR -lt $TIMEOUT ]; do
        # Cuestionamos el estado del servicio Y si la interfaz realmente retuvo la IP
        if systemctl is-active --quiet ssh && ip addr show "$interface" | grep -q "$ip_server"; then
            LISTO=true
            break
        fi
        sleep 1
        ((CONTADOR++))
    done

    if [ "$LISTO" = true ]; then
        echo -e "\n${VERDE}========================================================================${RESET}"
        echo -e "${AMARILLO}  [!] CONFIGURACIÓN REQUERIDA EN LA MÁQUINA VIRTUAL CLIENTE [!]${RESET}"
        echo -e "${VERDE}========================================================================${RESET}"
        echo -e "Interfaz de puente activa: ${VERDE}$interface${RESET}"
        echo -e "IP asignada al servidor: ${VERDE}$ip_server/$cidr${RESET}\n"
        echo -e "Comando de conexión desde el host físico:"
        echo -e "  ${AMARILLO}ssh ${SUDO_USER:-$USER}@$ip_server${RESET}"
        echo -e "\nPara VSCode Remote SSH — añadir en ~/.ssh/config del host:"
        echo -e "  ${CIAN}Host vm-linux${RESET}"
        echo -e "  ${CIAN}  HostName $ip_server${RESET}"
        echo -e "  ${CIAN}  User ${SUDO_USER:-$USER}${RESET}"
        echo -e "  ${CIAN}  ServerAliveInterval 30${RESET}"
        echo -e "  ${CIAN}  ServerAliveCountMax 3${RESET}"
        echo -e "${VERDE}========================================================================${RESET}"
    else
        log_error "Fallo crítico: El servicio SSH o la interfaz no se inicializaron a tiempo."
    fi
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
        "Desplegar Red de Administración SSH (Interfaz Dinámica)"
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
