#!/bin/bash

source ./libs/utils.sh

[ "$EUID" -ne 0 ] && { log_error "Este script debe ser ejecutado como root." && exit 1;}

gestionar_instalacion() {
    clear
    echo -e "${AMARILLO}--- GESTIÓN DE INSTALACIÓN ---${RESET}"
    
    if dpkg -s isc-dhcp-server >/dev/null 2>&1; then
        log_ok "El servicio DHCP ya se encuentra instalado."
        echo ""
        read -p "¿Desea realizar una REINSTALACIÓN completa? (s/n): " RESP
        
        if [[ "$RESP" == "s" || "$RESP" == "S" ]]; then
            apt-get purge -y isc-dhcp-server >/dev/null
            apt-get update -qq >/dev/null
            apt-get install -y isc-dhcp-server >/dev/null
            log_ok "Reinstalación finalizada."
        else
            return
        fi
    else
        apt-get update -qq >/dev/null
        apt-get install -y isc-dhcp-server >/dev/null
        log_ok "Instalación completada."
    fi
    pausa
}

configurar(){
    clear
    if ! dpkg -s isc-dhcp-server >/dev/null 2>&1; then
        log_error "El servicio no está instalado."
        pausa
        return
    fi

    INTERFACE="enp0s8"
    [ -z "$INTERFACE" ] && { log_error "Sin interfaz de red detectada."; pausa; return; }
    
    echo -e "${AMARILLO}--- CONFIGURACIÓN DEL ÁMBITO DHCP ---${RESET}"
    read -p "Nombre del Ámbito (Scope): " SCOPE

    while true; do
        read -p "IP Inicial (Se asignará al Servidor): " IP_INICIAL
        validar_formato_ip "$IP_INICIAL" && break
        log_error "IP inválida o prohibida."
    done

    while true; do
        read -p "IP Final del rango: " IP_FINAL
        validar_formato_ip "$IP_FINAL" && validar_rango "$IP_INICIAL" "$IP_FINAL" && break 
        log_error "IP inválida o rango incorrecto."
    done

    MASCARA=$(obtener_mascara "$IP_INICIAL")
    SUBNET=$(obtener_id_red "$IP_INICIAL" "$MASCARA")
    
    preparar_servidor "$INTERFACE" "$IP_INICIAL" "$MASCARA"

    IP_RANGO_INICIO=$(incrementar_ip "$IP_INICIAL")


    while true; do
        read -p "Gateway (Enter para omitir): " GW
        if [ -z "$GW" ]; then break; fi
        validar_formato_ip "$GW" && break 
    done

    while true; do
        read -p "DNS (Enter para omitir): " DNS
        if [ -z "$DNS" ]; then break; fi
        validar_formato_ip "$DNS" && break
    done

    while true; do
        read -p "Tiempo de concesión (segundos): " LEASE_TIME
        if [[ "$LEASE_TIME" =~ ^[0-9]+$ ]] && [ "$LEASE_TIME" -gt 0 ]; then
             break
        else 
             log_error "Debe ser un número entero positivo."
        fi
    done

    sed -i "s/INTERFACESv4=.*/INTERFACESv4=\"$INTERFACE\"/g" /etc/default/isc-dhcp-server
    
    cat > /etc/dhcp/dhcpd.conf <<EOL
default-lease-time $LEASE_TIME;
max-lease-time $LEASE_TIME;
authoritative;

subnet $SUBNET netmask $MASCARA {
    range $IP_RANGO_INICIO $IP_FINAL;
    $( [ ! -z "$GW" ] && echo "option routers $GW;" )
    $( [ ! -z "$DNS" ] && echo "option domain-name-servers $DNS;" )
    option domain-name "$SCOPE";
}
EOL

    systemctl restart isc-dhcp-server
    if systemctl is-active --quiet isc-dhcp-server; then
        log_ok "Servicio Configurado y ACTIVO."
    else
        log_error "Fallo al iniciar el servicio."
        journalctl -u isc-dhcp-server | tail -n 5
    fi
    pausa
}

monitorear(){
    while true; do
        clear
        echo -e "${AMARILLO}=== MONITOR EN TIEMPO REAL (Presione 'x' para salir) ===${RESET}"
        
        echo -e "\n[ CONFIGURACIÓN ACTIVA ]"
        if [ -f /etc/dhcp/dhcpd.conf ]; then
            grep -E "subnet|netmask|range|routers" /etc/dhcp/dhcpd.conf | sed 's/{//g;s/;//g'
        else
            echo "Sin configuración."
        fi

        echo -e "\n[ ESTADO DEL SERVICIO ]"
        if systemctl is-active --quiet isc-dhcp-server; then
             echo -e "Estado: ${VERDE}ACTIVO${RESET}"
        else
             echo -e "Estado: ${ROJO}INACTIVO${RESET}"
        fi

        echo -e "\n[ CLIENTES ]"
        printf "%-18s %-20s %-20s\n" "IP Address" "MAC Address" "Hostname"
        echo "------------------------------------------------------------"
        
        LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
        if [ -f "$LEASE_FILE" ]; then
             grep -E "lease |hardware ethernet|client-hostname" "$LEASE_FILE" | awk '
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

        read -t 2 -n 1 key
        if [[ $key == "x" || $key == "X" ]]; then break; fi
    done
}

menu_principal() {
    OPCIONES=("Instalar / Reinstalar Servicio" "Configurar DHCP" "Monitorear Clientes" "Salir")
    SELECCION=0

    while true; do
        clear
        echo "================================================="
        echo "                  GESTOR DHCP "
        echo "================================================="
        
        for ((i=0; i<${#OPCIONES[@]}; i++)); do
            if [ $i -eq $SELECCION ]; then
                echo -e "${VERDE}> \e[7m ${OPCIONES[$i]} \e[0m${RESET}"
            else
                echo "   ${OPCIONES[$i]}"
            fi
        done

        read -rsn1 key 
        if [[ $key == $'\x1b' ]]; then
            read -rsn2 key 
            if [[ $key == "[A" ]]; then
                ((SELECCION--))
                [ $SELECCION -lt 0 ] && SELECCION=$((${#OPCIONES[@]} - 1))
            elif [[ $key == "[B" ]]; then
                ((SELECCION++))
                [ $SELECCION -ge ${#OPCIONES[@]} ] && SELECCION=0
            fi
        elif [[ $key == "" ]]; then
            case $SELECCION in
                0) gestionar_instalacion ;;
                1) configurar ;;
                2) monitorear ;;
                3) exit 0 ;;
            esac
        fi
    done
}

menu_principal