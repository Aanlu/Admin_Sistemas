#!/bin/bash

source libs/utils.sh
source libs/validaciones.sh

gestionar_instalacion() {
    clear
    echo -e "${AMARILLO}--- GESTIÓN DE INSTALACIÓN ---${RESET}"
    
    if dpkg -s isc-dhcp-server >/dev/null 2>&1; then
        log_ok "El servicio DHCP ya se encuentra instalado."
        
        if confirmar_accion "¿Desea realizar una REINSTALACIÓN completa (borrará configuraciones)?"; then
            echo -e "${AMARILLO}[AVISO] Purgando y reinstalando el servicio silenciosamente...${RESET}"
            export DEBIAN_FRONTEND=noninteractive
            apt-get purge -yq isc-dhcp-server >/dev/null 2>>"$LOG_FILE"
            apt-get update -qq >/dev/null 2>>"$LOG_FILE"
            
            if apt-get install -yq isc-dhcp-server >/dev/null 2>>"$LOG_FILE"; then
                echo -e "\e[1A\e[K${VERDE}[OK] Reinstalación limpia finalizada correctamente.${RESET}"
            else
                echo -e "\e[1A\e[K${ROJO}[ERROR] Fallo en la reinstalación. Revise los logs.${RESET}"
            fi
        else
            log_warning "Acción cancelada por el usuario."
        fi
    else
        log_warning "Dependencias DHCP NO encontradas."
        if confirmar_accion "¿Desea instalar el servicio DHCP ahora?"; then
            instalar_dependencia_silenciosa "isc-dhcp-server"
        else
            log_warning "Instalación cancelada."
        fi
    fi
    pausa
}

configurar_dhcp() {
    clear
    
    if ! dpkg -s isc-dhcp-server >/dev/null 2>&1; then
        log_error "El servicio no está instalado. Ejecute 'Gestión de Instalación' primero."
        pausa; return
    fi

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
    
    local gw=$(capturar_ip_opcional "Gateway")
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
    echo -e "${AMARILLO}--- CONTROL DE SERVICIO DHCP ---${RESET}"
    
    if ! dpkg -s isc-dhcp-server >/dev/null 2>&1; then
        log_error "El servicio no está instalado."
        pausa; return
    fi

    if systemctl is-active --quiet isc-dhcp-server; then
        echo -e "Estado actual del servicio: ${VERDE}ACTIVO${RESET}"
        if confirmar_accion "¿Desea DESACTIVAR el servicio DHCP?"; then
            systemctl stop isc-dhcp-server
            log_warning "Servicio DHCP detenido manualmente."
        else
            log_info "El servicio se mantiene ACTIVO."
        fi
    else
        echo -e "Estado actual del servicio: ${ROJO}INACTIVO${RESET}"
        if confirmar_accion "¿Desea ACTIVAR el servicio DHCP?"; then
            systemctl start isc-dhcp-server
            log_ok "Servicio DHCP iniciado."
        else
            log_info "El servicio se mantiene INACTIVO."
        fi
    fi
    pausa
}

monitorear_clientes(){
    while true; do
        clear
        echo -e "${AMARILLO}=== MONITOR EN TIEMPO REAL (Presione 'x' para salir) ===${RESET}"
        
        if ! dpkg -s isc-dhcp-server >/dev/null 2>&1; then
            log_error "El servicio DHCP no está instalado."
            pausa
            break
        fi

        echo -e "\n${AZUL}[ CONFIGURACIÓN ACTIVA ]${RESET}"
        if [ -f /etc/dhcp/dhcpd.conf ]; then
            grep -v "^#" /etc/dhcp/dhcpd.conf | grep -E "subnet|netmask|range|routers" | sed 's/{//g;s/;//g'
        else
            echo "Sin configuración."
        fi

        echo -e "\n${AZUL}[ ESTADO DEL SERVICIO ]${RESET}"
        if systemctl is-active --quiet isc-dhcp-server; then
             echo -e "Estado: ${VERDE}ACTIVO${RESET}"
             
             echo -e "\n${AMARILLO}[ CLIENTES CONECTADOS ]${RESET}"
             printf "%-18s %-20s %-20s\n" "IP Address" "MAC Address" "Hostname"
             echo "------------------------------------------------------------"
             
             local lease_file="/var/lib/dhcp/dhcpd.leases"
             if [ -f "$lease_file" ]; then
                  grep -E "lease |hardware ethernet|client-hostname" "$lease_file" | awk '
                  BEGIN { RS="}" } 
                  {
                      ip=""; mac=""; name="Unknown";
                      for(i=1;i<=NF;i++) {
                          if($i == "lease") ip=$(i+1);
                          if($i == "hardware") mac=$(i+2);
                          if($i == "client-hostname") { name=$(i+1); gsub(/[";]/, "", name); }
                      }
                      if(ip != "") printf "%-18s %-20s %-20s\n", ip, mac, name;
                  }' | sort -u
             fi
        else
             echo -e "Estado: ${ROJO}INACTIVO${RESET}"
             log_warning "El servicio está detenido. No se muestran clientes."
        fi

        read -t 2 -n 1 key
        if [[ $key == "x" || $key == "X" ]]; then break; fi
    done
}

menu_dhcp() {
    local opciones_dhcp=(
        "Instalar / Reinstalar Servicio"
        "Configurar Ámbito DHCP"
        "Alternar Estado del Servicio (Start/Stop)"
        "Monitorear Clientes (Tiempo Real)"
    )
    
    while true; do
        generar_menu "MÓDULO DE GESTIÓN DHCP" opciones_dhcp "Volver al Menú Principal"
        local eleccion=$?
        
        case $eleccion in
            0) gestionar_instalacion ;;
            1) configurar_dhcp ;;
            2) alternar_servicio ;;
            3) monitorear_clientes ;;
            4) break ;;
        esac
    done
}

menu_dhcp