#!/bin/bash

source ./libs/utils.sh

[ "$EUID" -ne 0 ] && { log_error "Este script debe ser ejecutado como root." && exit 1;}

configurar(){
    clear
    echo "================================================="
    echo "                SERVIDOR DHCP"
    echo "================================================="

    INTERFACE=$(detectar_intefaz)
    
    if [ -z "$INTERFACE" ]; then
        log_error "No se detectó interfaz de red válida."
        pausa
        return
    fi

    log_info "Interfaz de red detectada: $INTERFACE"
    preparar_servidor "$INTERFACE"

    echo "1) Automatico"
    echo "2) Manual"
    read -p "Opción (1/2): " OP

    if [ "$OP" == "1" ]; then
        log_info "Configuración automática seleccionada."
        
        SCOPE="Red_Sistemas"
        IP_INICIAL="192.168.100.50"
        IP_FINAL="192.168.100.150"
        GW="192.168.100.1"
        DNS="192.168.100.20"
        LEASE_TIME="600"
        
        sleep 1
    else
        log_info "Modo manual seleccionado."
        read -p "Ingrese el nombre del ámbito (scope): " SCOPE

        while true; do
            read -p "IP inicial del rango DHCP: " IP_INICIAL
            validar_formato_ip "$IP_INICIAL" && break || log_error "Formato de IP inválido o reservado."
        done

        while true; do
            read -p "IP final del rango DHCP: " IP_FINAL
            validar_formato_ip "$IP_FINAL" && validar_rango "$IP_INICIAL" "$IP_FINAL" && break || log_error "IP inválida o rango incorrecto."
        done

        while true; do
            read -p "Gateway: " GW
            validar_formato_ip "$GW" && break || log_error "IP inválida."
        done

        while true; do
            read -p "DNS: " DNS
            validar_formato_ip "$DNS" && break || log_error "IP inválida."
        done
        
        read -p "Tiempo de concesión (lease time) en segundos: " LEASE_TIME
        [[ "$LEASE_TIME" =~ ^[0-9]+$ ]] || LEASE_TIME=600
    fi

    echo ""
    log_info "Verificando dependencias..."
    if ! dpkg -s isc-dhcp-server >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y isc-dhcp-server -qq >/dev/null 2>&1
        log_ok "[Instalación COMPLETADA]"
    else
        log_ok "Servicio ya instalado."
    fi

    log_info "Configurando el servicio DHCP..."
    
    sed -i "s/INTERFACESv4=.*/INTERFACESv4=\"$INTERFACE\"/g" /etc/default/isc-dhcp-server

    [ ! -f /etc/dhcp/dhcpd.conf.bak ] && cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.bak

    cat > /etc/dhcp/dhcpd.conf <<EOL
ddns-update-style none;
default-lease-time $LEASE_TIME;
max-lease-time 7200;
authoritative;

subnet 192.168.100.0 netmask 255.255.255.0 {
    range $IP_INICIAL $IP_FINAL;
    option routers $GW;
    option domain-name-servers $DNS;
    option domain-name "$SCOPE";
}
EOL

    if systemctl restart isc-dhcp-server; then
        log_ok "Servicio reiniciado y configurado correctamente."
    else
        log_error "Error al iniciar el servicio. Verifique 'systemctl status isc-dhcp-server'."
        cat /etc/dhcp/dhcpd.conf
    fi
    pausa
}

monitorear(){
    while true; do
        clear
        echo "   --- Estado del Servidor (Tiempo Real) ---"
        echo "       [Presione 'x' para salir]"
        echo ""

        if systemctl is-active --quiet isc-dhcp-server; then
            log_ok "Estado: Activo"
        else
            log_error "Estado: Inactivo"
        fi

        echo ""
        echo "   --- Clientes DHCP Actuales ---"
        echo -e "IP Address\tMAC Address\tHostname"
        echo "---------------------------------------------"
        
        LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
        
        if [ -f "$LEASE_FILE" ]; then
            grep -E "lease |hardware ethernet|client-hostname" "$LEASE_FILE" | awk '{
                if ($1=="lease") ip=$2;
                if ($1=="hardware") mac=$3;
                if ($1=="client-hostname") { name=$2; gsub(/[";]/, "", name); }
                if ($1=="}") { 
                    if (ip && mac) print ip "\t" mac "\t" (name ? name : "N/A"); 
                    ip=""; mac=""; name=""; 
                }
            }' | sort | uniq
        else 
            echo "No se han registrado clientes DHCP aún."
        fi
        
        read -t 2 -n 1 key
        if [[ $key = "x" || $key = "X" ]]; then
            break
        fi
    done
}

while true; do
    clear
    echo "================================================="
    echo "                SERVIDOR DHCP"
    echo "================================================="
    echo "1) Configurar Servidor"
    echo "2) Monitorear Clientes"
    echo "3) Salir"
    read -p "Seleccione una opción (1-3): " OPCION
    case $OPCION in
        1) configurar ;;
        2) monitorear ;;
        3) log_info "Saliendo..." && exit 0 ;;
        *) log_error "Opción no válida. Intente nuevamente." ;;
    esac
done