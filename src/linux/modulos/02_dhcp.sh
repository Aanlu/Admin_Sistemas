#!/bin/bash
source libs/utils.sh
source libs/validaciones.sh

gestionar_instalacion() {
    clear
    echo -e "${AMARILLO}--- MANTENIMIENTO DEL SERVICIO DHCP ---${RESET}"
    log_info "Esta opción realizará una purga total y reinstalación limpia."
    
    if confirmar_accion "¿Desea PURGAR y REINSTALAR el servicio DHCP (borrará configuraciones)?"; then
        echo -e "${AMARILLO}[AVISO] Purgando el servicio silenciosamente...${RESET}"
        export DEBIAN_FRONTEND=noninteractive
        
        # Detenemos primero para evitar errores de dpkg
        systemctl stop isc-dhcp-server 2>/dev/null
        
        apt-get purge -yq isc-dhcp-server >/dev/null 2>>"$LOG_FILE"
        # Limpiamos remanentes de configuración que el purge suele dejar
        rm -rf /etc/dhcp/ 2>/dev/null 
        
        apt-get update -qq >/dev/null 2>>"$LOG_FILE"
        
        if apt-get install -yq isc-dhcp-server >/dev/null 2>>"$LOG_FILE"; then
            echo -e "\e[1A\e[K${VERDE}[OK] Reinstalación limpia finalizada correctamente.${RESET}"
        else
            echo -e "\e[1A\e[K${ROJO}[ERROR] Fallo en la reinstalación. Revise $LOG_FILE.${RESET}"
        fi
    else
        log_warning "Acción cancelada."
    fi
    pausa
}

configurar_dhcp() {

    if ! dpkg -s isc-dhcp-server >/dev/null 2>&1; then
        log_warning "Servicio DHCP no detectado. Instalando automáticamente..."
        instalar_dependencia_silenciosa "isc-dhcp-server" || { pausa; return; }
    fi

    seleccionar_interfaz_dinamica
    if [ $? -ne 0 ]; then
        log_warning "Configuración cancelada."
        pausa; return
    fi
    
    local interface="$INTERFAZ_SELECCIONADA"
    
    ip link set dev "$interface" up
    
    echo -e "${AMARILLO}--- CONFIGURACIÓN DEL ÁMBITO DHCP EN $interface ---${RESET}"
    read -p "Nombre del Ámbito (Scope): " scope
    
    local ip_inicial=$(capturar_ip "IP Inicial del servidor/rango DHCP")
    
    local ip_final
    while true; do
        ip_final=$(capturar_ip "IP Final del rango DHCP")
        if validar_rango "$ip_inicial" "$ip_final"; then
            break
        else
            log_error "La IP final debe ser mayor que la inicial ($ip_inicial)."
        fi
    done

    local ip_rango_inicio=$(incrementar_ip "$ip_inicial")
    local gw=$(capturar_ip_opcional "Gateway (Dejar en blanco si es red interna aislada)")
    
    echo -e "\n${AZUL}[ Configuración de DNS ]${RESET}"
    local dns_primario=$(capturar_ip "Servidor DNS Principal" "$ip_inicial")
    local dns_secundario=$(capturar_ip_opcional "Servidor DNS Secundario (Dejar en blanco para omitir)")
    
    local string_dns=""
    if [ -n "$dns_primario" ]; then
        if [ -n "$dns_secundario" ]; then
            string_dns="option domain-name-servers $dns_primario, $dns_secundario;"
        else
            string_dns="option domain-name-servers $dns_primario;"
        fi
    fi

    local lease_time
    while true; do
        read -p "Tiempo de concesión (segundos) [Enter para usar 86400]: " lease_time
        [ -z "$lease_time" ] && lease_time=86400
        if [[ "$lease_time" =~ ^[0-9]+$ ]] && [ "$lease_time" -gt 0 ]; then break; fi
        log_error "Debe ser un número entero positivo."
    done

    local cidr
    while true; do
        read -p "Prefijo de red (CIDR, ej. 24 para 255.255.255.0) [Enter para usar /24]: " cidr
        [ -z "$cidr" ] && cidr=24 # Por defecto usamos /24 que es el estándar de facto
        if [[ "$cidr" =~ ^[0-9]+$ ]] && [ "$cidr" -ge 8 ] && [ "$cidr" -le 30 ]; then break; fi
        log_error "Prefijo CIDR inválido. Use un número entre 8 y 30."
    done

    # Llamamos a nuestra nueva función matemática
    local mascara=$(cidr_a_mascara "$cidr")
    local subnet=$(obtener_id_red "$ip_inicial" "$mascara")

    local file_default="/etc/default/isc-dhcp-server"
    if grep -q "^INTERFACESv4=" "$file_default"; then
        # Si la variable existe y está activa, la modificamos
        sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$interface\"/g" "$file_default"
    elif grep -q "^#INTERFACESv4=" "$file_default" || grep -q "^# INTERFACESv4=" "$file_default"; then
        # Si existe pero está comentada, la descomentamos y modificamos
        sed -i -E "s/^#\s*INTERFACESv4=.*/INTERFACESv4=\"$interface\"/g" "$file_default"
    else
        # Si de plano no existe, la añadimos al final
        echo "INTERFACESv4=\"$interface\"" >> "$file_default"
    fi

    cat > /etc/dhcp/dhcpd.conf <<EOL
default-lease-time $lease_time;
max-lease-time $lease_time;
authoritative;

subnet $subnet netmask $mascara {
    range $ip_rango_inicio $ip_final;
    $( [ ! -z "$gw" ] && echo "option routers $gw;" )
    $string_dns
    option domain-name "$scope";
}
EOL

    echo -e "${CIAN}Asignando IP estática $ip_inicial/$cidr a $interface de forma segura...${RESET}"
    
    # 1. Actualización atómica: Reemplaza o añade la nueva IP sin tumbar el enlace lógico
    ip addr replace "$ip_inicial/$cidr" dev "$interface"
    
    # 2. Limpieza selectiva: Busca IPs viejas en esa interfaz y las borra una por una,
    # excepto la que acabamos de configurar. Evita desconexiones abruptas si hay aliases.
    ip -4 addr show dev "$interface" | grep "inet" | grep -v "$ip_inicial" | awk '{print $2}' | while read -r old_ip; do
        ip addr del "$old_ip" dev "$interface" 2>/dev/null
    done

    echo -e "${CIAN}Reiniciando isc-dhcp-server...${RESET}"
    systemctl restart isc-dhcp-server
    
    if systemctl is-active --quiet isc-dhcp-server; then
        log_ok "Servicio Configurado y ACTIVO en $interface."
        
        # --- INICIO DEL BYPASS CORREGIDO ---
        echo -e "${CIAN}Forzando resolución DNS local hacia $dns_primario (Bypass systemd-resolved)...${RESET}"
        
        # 1. Ajustamos las reglas globales de systemd-resolved con la IP y bloqueamos dominios externos
        sed -i -E "s/^#?DNS=.*/DNS=$dns_primario/" /etc/systemd/resolved.conf
        sed -i -E 's/^#?Domains=.*/Domains=~./' /etc/systemd/resolved.conf
        sed -i -E 's/^#?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
        
        # 2. Reiniciamos el demonio para que asimile los cambios
        systemctl restart systemd-resolved
        
        # 3. Forzamos a la interfaz específica a usar este DNS (evita fugas hacia otras interfaces)
        resolvectl dns "$interface" "$dns_primario" 2>/dev/null || true
        
        # 4. Manejo seguro de resolv.conf (Nunca destruir, siempre respaldar)
        if [ -L /etc/resolv.conf ] || [ -f /etc/resolv.conf ]; then
            # Hacemos backup solo si el backup no existe ya (idempotencia)
            if [ ! -f /etc/resolv.conf.bak_admin_sistemas ]; then
                mv /etc/resolv.conf /etc/resolv.conf.bak_admin_sistemas
            else
                rm -f /etc/resolv.conf # Si ya hay backup, podemos borrar el actual seguro
            fi
        fi
        
        cat > /etc/resolv.conf <<EOF
nameserver $dns_primario
EOF
        log_ok "El servidor ahora resolverá localmente a través de $dns_primario."
        # --- FIN DEL BYPASS CORREGIDO ---

    else
        log_error "Fallo al iniciar el servicio DHCP. Ejecute: journalctl -xeu isc-dhcp-server.service"
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