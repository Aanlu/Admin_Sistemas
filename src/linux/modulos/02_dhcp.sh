#!/bin/bash

source ../libs/utils.sh
source ../libs/validaciones.sh

instalar_dependencia_silenciosa "isc-dhcp-server" || exit 1

configurar_dhcp() {
    clear
    local interface="enp0s8"
    
    echo -e "${AMARILLO}--- CONFIGURACIÓN DEL ÁMBITO DHCP ---${RESET}"
    read -p "Nombre del Ámbito (Scope): " scope
    
    local ip_inicial=$(capturar_ip "IP Inicial (Se asignará al Servidor)")
    
    local ip_final
    while true; do
        read -p "IP Final del rango: " ip_final
        if validar_formato_ip "$ip_final" && validar_rango "$ip_inicial" "$ip_final"; then
            break
        else
            log_error "IP final inválida o fuera de rango."
        fi
    done

    local mascara=$(obtener_mascara "$ip_inicial")
    local subnet=$(obtener_id_red "$ip_inicial" "$mascara")
    local cidr=24
    [ "$mascara" == "255.0.0.0" ] && cidr=8
    [ "$mascara" == "255.255.0.0" ] && cidr=16

    ip link set dev "$interface" up
    ip addr flush dev "$interface"
    ip addr add "$ip_inicial/$cidr" dev "$interface"
    sleep 1

    local ip_rango_inicio=$(incrementar_ip "$ip_inicial")
    
    local gw=$(capturar_ip "Gateway")
    local dns=$(capturar_ip "Servidor DNS principal")
    
    local lease_time
    while true; do
        read -p "Tiempo de concesión (segundos): " lease_time
        if [[ "$lease_time" =~ ^[0-9]+$ ]] && [ "$lease_time" -gt 0 ]; then break; fi
        log_error "Debe ser un número entero positivo."
    done

    sed -i "s/INTERFACESv4=.*/INTERFACESv4=\"$interface\"/g" /etc/default/isc-dhcp-server

    cat > /etc/dhcp/dhcpd.conf <<EOL
default-lease-time $lease_time;
max-lease-time $lease_time;
authoritative;

subnet $subnet netmask $mascara {
    range $ip_rango_inicio $ip_final;
    $( [ ! -z "$gw" ] && echo "option routers $gw;" )
    $( [ ! -z "$dns" ] && echo "option domain-name-servers $dns;" )
    option domain-name "$scope";
}
EOL

    systemctl restart isc-dhcp-server
    if systemctl is-active --quiet isc-dhcp-server; then
        log_ok "Servicio Configurado y ACTIVO."
    else
        log_error "Fallo al iniciar el servicio. Revise $LOG_FILE"
    fi
    pausa
}

alternar_servicio() {
    clear
    if systemctl is-active --quiet isc-dhcp-server; then
        systemctl stop isc-dhcp-server
        log_warning "Servicio DHCP detenido manualmente."
    else
        systemctl start isc-dhcp-server
        log_ok "Servicio DHCP iniciado."
    fi
    pausa
}

menu_dhcp() {
    local opciones_dhcp=(
        "Configurar Ámbito DHCP"
        "Alternar Estado del Servicio (Start/Stop)"
    )
    
    while true; do
        generar_menu "MÓDULO DE GESTIÓN DHCP" opciones_dhcp "Volver al Menú Principal"
        local eleccion=$?
        
        case $eleccion in
            0) configurar_dhcp ;;
            1) alternar_servicio ;;
            2) break ;;
        esac
    done
}

menu_dhcp