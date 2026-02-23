#!/bin/bash

inyectar_ip_inicial() {
    local interface="enp0s8"
    local ip_defecto="10.0.0.10"
    local cidr="24"
    local ip_actual=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

    if [ -z "$ip_actual" ]; then
        echo -e "${CIAN}Inyectando IP estática y DHCP de Semilla en $interface...${RESET}"
        ip addr flush dev "$interface" >/dev/null 2>&1
        ip addr add "$ip_defecto/$cidr" dev "$interface" >/dev/null 2>&1
        ip link set dev "$interface" up >/dev/null 2>&1
        sleep 2
        IP_ACTIVA=$ip_defecto

        instalar_dependencia_silenciosa "isc-dhcp-server" >/dev/null 2>&1
        
        cat > /etc/dhcp/dhcpd.conf <<EOF
subnet 10.0.0.0 netmask 255.255.255.0 {
  range 10.0.0.100 10.0.0.110;
  option routers 10.0.0.10;
}
EOF
        sed -i "s/INTERFACESv4=\"\"/INTERFACESv4=\"$interface\"/g" /etc/default/isc-dhcp-server
        systemctl restart isc-dhcp-server >/dev/null 2>&1
    else
        IP_ACTIVA=$ip_actual
    fi
}

instalar_ssh() {
    clear
    echo -e "${AMARILLO}--- INSTALACIÓN Y CONFIGURACIÓN DE SSH ---${RESET}"
    
    if systemctl is-active --quiet ssh; then
        log_warning "El servicio SSH ya está instalado y operando."
        pausa; return
    fi

    inyectar_ip_inicial

    instalar_dependencia_silenciosa "openssh-server" || { log_error "Fallo al instalar openssh-server."; pausa; return; }
    
    systemctl enable ssh --now >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1
    
    log_ok "Servicio SSH y DHCP de rescate desplegados."
    pausa
}

alternar_ssh() {
    clear
    echo -e "${AMARILLO}--- CONTROL DE SERVICIO SSH ---${RESET}"
    
    if systemctl is-active --quiet ssh; then
        if confirmar_accion "¿Desea DESACTIVAR el servicio SSH?"; then
            systemctl stop ssh
            log_warning "Servicio SSH detenido."
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
        "Instalar y Configurar SSH (Zero-Touch / Autoprovisionamiento)"
        "Alternar Estado del Servicio (Start/Stop)"
    )
    
    while true; do
        local estado_actual="INACTIVO"
        local comando_conexion=""
        
        if systemctl is-active --quiet ssh; then
            estado_actual="ACTIVO"
            local ip_activa=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
            comando_conexion=" | Comando: ssh $USER@$ip_activa"
        fi
        
        local titulo_dinamico="MÓDULO DE GESTIÓN SSH [ $estado_actual ]$comando_conexion"

        generar_menu "$titulo_dinamico" opciones_ssh "Volver al Menú Principal"
        local eleccion=$?
        
        case $eleccion in
            0) instalar_ssh ;;
            1) alternar_ssh ;;
            2) break ;;
        esac
    done
}

menu_ssh