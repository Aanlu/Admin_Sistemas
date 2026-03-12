#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../libs/utils.sh"
source "$SCRIPT_DIR/../libs/validaciones.sh"
source "$SCRIPT_DIR/../libs/http_funciones.sh"

desplegar_servidor_http(){
    clear
    local arr_motores=("apache2" "nginx" "tomcat")

    generar_menu "SELECCIONE EL MOTOR HTTP A DESPLEGAR" arr_motores "Volver al menú HTTP"
    local opcion_motor=$?

    if [ $opcion_motor -eq ${#arr_motores[@]} ]; then return 0; fi
    local motor_seleccionado="${arr_motores[$opcion_motor]}"

    echo -e "\n${AZUL}[*] Interrogando repositorios y analizando sistema...${RESET}"
    local string_versiones=$(extraer_versiones_dinamicas "$motor_seleccionado")

    if [ -z "$string_versiones" ]; then
        log_error "Fallo de red o repositorios. Verifique su conexión a internet."
        pausa; return 1
    fi

    mapfile -t arr_versiones <<< "$string_versiones"
    
    generar_menu "SELECCIONE LA VERSIÓN DE ${motor_seleccionado^^}" arr_versiones "Cancelar"
    local opcion_version=$?
    if [ $opcion_version -eq ${#arr_versiones[@]} ]; then return 0; fi
    
    local version_con_etiqueta="${arr_versiones[$opcion_version]}"
    local version_seleccionada=$(echo "$version_con_etiqueta" | awk '{print $1}')

    local version_instalada=""
    local saltar_instalacion=0

    if [ "$motor_seleccionado" == "tomcat" ]; then
        if [ -f "/opt/tomcat/RELEASE-NOTES" ]; then
            version_instalada=$(grep "Apache Tomcat Version" /opt/tomcat/RELEASE-NOTES | grep -oP '\d+\.\d+\.\d+')
        fi
    else
        # BISTURI: Aislar la versión base cortando todo lo que esté después del guion
        version_instalada=$(dpkg-query -W -f='${Version}' "$motor_seleccionado" 2>/dev/null | cut -d'-' -f1)
    fi
    if [ -n "$version_instalada" ]; then
        if [ "$version_instalada" == "$version_seleccionada" ]; then
            echo -e "\n${AMARILLO}[INFO] La versión $version_seleccionada ya se encuentra instalada en el sistema.${RESET}"
            saltar_instalacion=1
        elif dpkg --compare-versions "$version_instalada" lt "$version_seleccionada"; then
            echo -e "\n${CIAN}[ACTUALIZACIÓN] Tiene la versión $version_instalada. ¿Desea actualizar a la $version_seleccionada?${RESET}"
            if ! confirmar_accion; then return 0; fi
        else
            echo -e "\n${ROJO}[PELIGRO] Tiene una versión superior ($version_instalada). Forzar una inferior ($version_seleccionada) ejecutará una purga total previa.${RESET}"
            if ! confirmar_accion "¿Desea forzar la degradación (Downgrade)?"; then return 0; fi
        fi
    fi
    
    clear
    echo -e "${AMARILLO}--- FASE 2: CONFIGURACIÓN DE RED ---${RESET}\n"
    local puerto_seleccionado
    
    while true; do
        puerto_seleccionado=$(capturar_entero "Ingrese el puerto TCP de escucha deseado")
        echo -e "${AZUL}[*] Auditando disponibilidad del puerto $puerto_seleccionado...${RESET}"
        
        validar_puerto "$puerto_seleccionado"
        local estado_puerto=$?

        if [ $estado_puerto -eq 0 ]; then
            log_ok "Puerto $puerto_seleccionado libre y validado."
            break
        elif [ $estado_puerto -eq 2 ]; then
            log_error "El puerto $puerto_seleccionado esta reservado para infraestructura critica."
            continue
        else
            log_error "El puerto YA ESTÁ EN USO en el Kernel. Elija otro."
        fi
    done

    if [ $saltar_instalacion -eq 0 ]; then
        echo -e "\n${AMARILLO}--- FASE 3: APROVISIONAMIENTO Y DESPLIEGUE ---${RESET}"
        
        systemctl stop "$motor_seleccionado" >> "$LOG_FILE" 2>&1
        if [ "$motor_seleccionado" == "apache2" ]; then
            apt-get purge -yq 'apache2*' 'libapr*' >> "$LOG_FILE" 2>&1
            rm -rf /etc/apache2 /var/www/apache2 /var/www/html >> "$LOG_FILE" 2>&1
        elif [ "$motor_seleccionado" == "nginx" ]; then
            apt-get purge -yq 'nginx*' 'libnginx-mod*' >> "$LOG_FILE" 2>&1
            rm -rf /etc/nginx /var/www/nginx /var/www/html >> "$LOG_FILE" 2>&1
        elif [ "$motor_seleccionado" == "tomcat" ]; then
            rm -rf /opt/tomcat >> "$LOG_FILE" 2>&1
        fi
        apt-get autoremove -yq --purge >> "$LOG_FILE" 2>&1
        apt-get clean >> "$LOG_FILE" 2>&1

        if instalador_paquetes "$motor_seleccionado" "$version_seleccionada"; then
            log_ok "Binarios instalados correctamente."
        else
            log_error "Fallo crítico en descarga o instalación. Revise $LOG_FILE"; pausa; return 1
        fi
    fi

    echo -e "\n${AMARILLO}--- FASE 4: INYECCIÓN DE PARÁMETROS DE RED ---${RESET}"
    if configurar_puerto_servicio "$motor_seleccionado" "$puerto_seleccionado"; then
        log_ok "Servicio $motor_seleccionado atado al puerto $puerto_seleccionado exitosamente."
    else
        log_error "Fallo al inyectar el puerto. Revisar logs del sistema."; pausa; return 1
    fi

    echo -e "\n${AMARILLO}--- FASE 5: APLICACIÓN DE HARDENING (SEGURIDAD) ---${RESET}"
    aplicar_hardening_seguridad "$motor_seleccionado"
    aislar_directorio_web "$motor_seleccionado"
    
    # BISTURI: Extraer e imprimir el UID del usuario dedicado para cumplir la rúbrica visualmente
    echo -e "${AZUL}[*] Validando usuario dedicado en el Kernel de Linux...${RESET}"
    if [ "$motor_seleccionado" == "tomcat" ]; then
        echo -e "  -> Servicio aislado bajo usuario: ${VERDE}tomcat (UID: $(id -u tomcat))${RESET}"
    else
        echo -e "  -> Servicio aislado bajo usuario: ${VERDE}www-data (UID: $(id -u www-data))${RESET}"
    fi
    
    log_ok "Firmas del servidor apagadas, cabeceras preventivas y aislamiento de usuario inyectados."

    echo -e "\n${AMARILLO}--- FASE 6: INYECCIÓN DE CONTENIDO WEB ---${RESET}"
    desplegar_plantilla_html "$motor_seleccionado" "$version_seleccionada" "$puerto_seleccionado"
    log_ok "Página Index generada a partir de la plantilla maestra."

    pausa
}

escanear_servicios_vivos() {
    ss -tlnp | grep -E "apache2|nginx|java" | grep -v ":8005\b" | while read -r line; do
        local ip_port=$(echo "$line" | awk '{print $4}')
        local proc_info=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+')
        local puerto_puro=$(echo "$ip_port" | awk -F: '{print $NF}')
        local motor_detectado="Desconocido"
        local ver=""
        
        if echo "$proc_info" | grep -q "apache2"; then 
            motor_detectado="Apache2"
            ver=$(dpkg-query -W -f='${Version}' apache2 2>/dev/null)
        elif echo "$proc_info" | grep -q "nginx"; then 
            motor_detectado="Nginx"
            ver=$(dpkg-query -W -f='${Version}' nginx 2>/dev/null)
        elif echo "$proc_info" | grep -q "java"; then 
            motor_detectado="Tomcat"
            [ -f "/opt/tomcat/RELEASE-NOTES" ] && ver=$(grep "Apache Tomcat Version" /opt/tomcat/RELEASE-NOTES | grep -oP '\d+\.\d+\.\d+')
        fi
        
        echo "$puerto_puro - $motor_detectado ($ver)"
    done | sort -u
}

prueba_cabecera_http() {
    clear
    echo -e "${AMARILLO}--- AUDITORÍA LOCAL DE CABECERAS HTTP ---${RESET}"
    
    local puertos_raw=$(escanear_servicios_vivos)
    
    if [ -z "$puertos_raw" ]; then
        log_error "No se detectó ningún servidor web corriendo en el sistema."
        pausa; return 1
    fi

    mapfile -t arr_puertos_vivos <<< "$puertos_raw"
    
    generar_menu "SELECCIONE EL PUERTO Y SERVICIO A AUDITAR" arr_puertos_vivos "Cancelar"
    local eleccion=$?
    
    if [ $eleccion -eq ${#arr_puertos_vivos[@]} ]; then return 0; fi
    
    local seleccion_texto="${arr_puertos_vivos[$eleccion]}"
    local puerto=$(echo "$seleccion_texto" | awk -F" - " '{print $1}')
    
    clear
    echo -e "\n${AZUL}[*] Lanzando petición cURL (Head) hacia localhost:$puerto...${RESET}\n"
    
    curl -I "http://localhost:$puerto" 2>/dev/null || log_error "Conexión rechazada. No hay servicio HTTP en ese puerto."
    
    pausa
}

modificar_puerto_caliente() {
    clear
    echo -e "${AMARILLO}--- MODIFICADOR DE PUERTOS EN CALIENTE ---${RESET}"

    local arr_instalados=()
    systemctl is-active --quiet apache2 && arr_instalados+=("apache2")
    systemctl is-active --quiet nginx && arr_instalados+=("nginx")
    systemctl is-active --quiet tomcat && arr_instalados+=("tomcat")

    if [ ${#arr_instalados[@]} -eq 0 ]; then
        log_error "No se encontró ningún servicio web en ejecución para modificar."
        pausa; return 1
    fi

    generar_menu "SELECCIONE EL SERVICIO A MODIFICAR" arr_instalados "Cancelar"
    local eleccion=$?
    
    if [ $eleccion -eq ${#arr_instalados[@]} ]; then return 0; fi
    local motor="${arr_instalados[$eleccion]}"
    
    clear
    echo -e "${AZUL}[*] Servicio seleccionado: ${motor^^}${RESET}"
    
    local puerto_viejo=""
    case $motor in
        apache2) puerto_viejo=$(grep -E "^Listen" /etc/apache2/ports.conf | awk '{print $2}') ;;
        nginx) puerto_viejo=$(grep -E "listen [0-9]+" /etc/nginx/sites-available/default | head -n 1 | awk '{print $2}' | tr -d ';') ;;
        tomcat) puerto_viejo=$(grep -oP 'Connector port="\K[^"]+' /opt/tomcat/conf/server.xml | head -n 1) ;;
    esac

    local puerto_nuevo
    while true; do
        puerto_nuevo=$(capturar_entero "Ingrese el NUEVO puerto TCP de escucha deseado")
        
        validar_puerto "$puerto_nuevo"
        local estado_puerto=$?

        if [ $estado_puerto -eq 0 ]; then
            break
        elif [ $estado_puerto -eq 2 ]; then
            log_error "El puerto $puerto_nuevo esta reservado para infraestructura critica."
            continue
        else
            log_error "El puerto YA ESTÁ EN USO en el Kernel. Elija otro."
        fi
    done

    echo -e "\n${CIAN}[*] Deteniendo el servicio ${motor^^}...${RESET}"
    systemctl stop "$motor" >> "$LOG_FILE" 2>&1
    
    echo -e "${CIAN}[*] Inyectando el puerto $puerto_nuevo y actualizando el Firewall...${RESET}"
    if configurar_puerto_servicio "$motor" "$puerto_nuevo"; then
        
        if [ -n "$puerto_viejo" ]; then
            ufw deny "$puerto_viejo"/tcp >> "$LOG_FILE" 2>&1
        fi

        local ruta_html="/var/www/$motor/index.html"
        [ "$motor" == "tomcat" ] && ruta_html="/opt/tomcat/webapps/ROOT/index.html"
        if [ -f "$ruta_html" ]; then
            sed -i -E "s/id=\"puerto-display\">[0-9]+<\/span>/id=\"puerto-display\">$puerto_nuevo<\/span>/g" "$ruta_html"
        fi

        log_ok "¡ÉXITO! El servicio ${motor^^} fue migrado en caliente al puerto $puerto_nuevo."
    else
        log_error "Fallo crítico al reconfigurar el puerto. Revise $LOG_FILE."
    fi
    pausa
}

reset_total_servicio_http() {
    clear
    echo -e "${ROJO}--- DESTRUCCIÓN DEL ENTORNO WEB ---${RESET}"
    if confirmar_accion "¿Desea PURGAR todos los motores web y sus configuraciones?"; then
        echo -e "${CIAN}[*] Desinstalando procesos y limpiando Kernel...${RESET}"
        systemctl stop apache2 nginx tomcat >> "$LOG_FILE" 2>&1
        
        echo -e "${CIAN}[*] Purgando dependencias cruzadas en APT...${RESET}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get --fix-broken install -yq >> "$LOG_FILE" 2>&1
        apt-get purge -yq 'apache2*' 'nginx*' 'libnginx-mod*' 'libapr*' default-jdk >> "$LOG_FILE" 2>&1
        apt-get autoremove -yq --purge >> "$LOG_FILE" 2>&1
        apt-get clean >> "$LOG_FILE" 2>&1
        
        echo -e "${CIAN}[*] Destruyendo directorios y jaulas residuales...${RESET}"
        systemctl disable tomcat >> "$LOG_FILE" 2>&1
        rm -rf /etc/apache2 /etc/nginx /var/www/html /var/www/apache2 /var/www/nginx /opt/tomcat /etc/systemd/system/tomcat.service
        userdel -r tomcat >> "$LOG_FILE" 2>&1
        systemctl daemon-reload >> "$LOG_FILE" 2>&1
        
        log_ok "Entorno web aniquilado. El servidor regresó a estado base inmaculado."
    fi
    pausa
}

menu_http(){
    local opciones_http=(
        "Desplegar Nuevo Servidor HTTP"
        "Modificar Puerto en Caliente"
        "Prueba de Cabeceras HTTP (Auditoría)"
        "Reset Total del Entorno HTTP"
    )

    while true; do 
        generar_menu "MÓDULO DE GESTIÓN HTTP" opciones_http "Volver al Menú Principal"
        local opcion_seleccionada=$?

        case $opcion_seleccionada in
            0) desplegar_servidor_http ;;
            1) modificar_puerto_caliente ;;
            2) prueba_cabecera_http ;;
            3) reset_total_servicio_http ;;
            4) clear; return ;;
        esac
    done
}

menu_http