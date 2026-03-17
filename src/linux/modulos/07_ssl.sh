#!/bin/bash
# ============================================================
# 07_ssl.sh — Práctica 7: Infraestructura de Despliegue Seguro
# Integra: FTP client dinámico + SSL/TLS en 4 servidores Linux
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../libs/utils.sh"
source "$SCRIPT_DIR/../libs/validaciones.sh"
source "$SCRIPT_DIR/../libs/http_funciones.sh"
source "$SCRIPT_DIR/../libs/ftp_cliente.sh"
source "$SCRIPT_DIR/../libs/ssl_funciones.sh"

# Dominio para los certificados SSL (configurable al inicio)
DOMINIO_SSL="${DOMINIO_SSL:-reprobados.com}"

# ============================================================
# CONFIGURAR DOMINIO SSL
# Permite cambiar el dominio antes de generar cualquier cert
# ============================================================
configurar_dominio() {
    clear
    echo -e "${AMARILLO}--- CONFIGURACIÓN DE DOMINIO SSL ---${RESET}"
    echo -e "Dominio actual: ${VERDE}$DOMINIO_SSL${RESET}"
    echo ""
    echo -e "${AZUL}Este dominio se usará en el CN de todos los certificados.${RESET}"
    echo -e "${AZUL}Debe coincidir con el dominio registrado en el DNS local (P3).${RESET}\n"

    read -p "Nuevo dominio [Enter para mantener '$DOMINIO_SSL']: " nuevo
    if [ -n "$nuevo" ]; then
        # Validar formato de dominio
        nuevo="${nuevo,,}"
        nuevo="${nuevo#www.}"
        if [[ "$nuevo" =~ ^[a-z0-9-]+\.[a-z]{2,}(\.[a-z]{2,})?$ ]]; then
            DOMINIO_SSL="$nuevo"
            # Exportar para que ssl_funciones.sh use el nuevo valor
            export DOMINIO_SSL
            log_ok "Dominio SSL configurado: $DOMINIO_SSL"
        else
            log_error "Formato inválido. Se mantiene: $DOMINIO_SSL"
        fi
    fi
    pausa
}

# ============================================================
# INSTALACIÓN HÍBRIDA (FTP o WEB)
# Flujo completo: fuente → motor → versión → instalar →
#                 puerto → hardening → SSL opcional
# ============================================================
instalar_servidor_http() {
    clear
    echo -e "${AMARILLO}=== INSTALACIÓN HÍBRIDA DE SERVIDOR HTTP ===${RESET}\n"

    # 1. Seleccionar fuente de instalación
    local arr_fuentes=("WEB  — Repositorios oficiales (apt / Apache mirrors)" \
                       "FTP  — Repositorio privado (servidor P5)")
    generar_menu "SELECCIONE LA FUENTE DE INSTALACIÓN" arr_fuentes "Cancelar"
    local fuente=$?
    [ $fuente -eq ${#arr_fuentes[@]} ] && return

    # Si elige FTP, conectar primero
    if [ $fuente -eq 1 ]; then
        ftp_conectar || { pausa; return; }
    fi

    # 2. Seleccionar motor HTTP
    local arr_motores=("apache2" "nginx" "tomcat")
    generar_menu "SELECCIONE EL MOTOR HTTP" arr_motores "Cancelar"
    local opcion_motor=$?
    [ $opcion_motor -eq ${#arr_motores[@]} ] && return
    local motor="${arr_motores[$opcion_motor]}"

    # 3. Obtener versión e instalar
    local version_instalada=""

    if [ $fuente -eq 0 ]; then
        # ── INSTALACIÓN DESDE WEB ──────────────────────────────
        echo -e "\n${AZUL}[*] Interrogando repositorios...${RESET}"
        local string_versiones
        string_versiones=$(extraer_versiones_dinamicas "$motor")
        if [ -z "$string_versiones" ]; then
            log_error "Sin acceso a internet o repositorios no disponibles."
            pausa; return
        fi

        mapfile -t arr_versiones <<< "$string_versiones"
        generar_menu "SELECCIONE LA VERSIÓN DE ${motor^^}" arr_versiones "Cancelar"
        local opcion_ver=$?
        [ $opcion_ver -eq ${#arr_versiones[@]} ] && return

        local version_con_etiqueta="${arr_versiones[$opcion_ver]}"
        local version_sel
        version_sel=$(echo "$version_con_etiqueta" | awk '{print $1}')

        # Verificar idempotencia
        local ver_actual=""
        if [ "$motor" == "tomcat" ]; then
            [ -f /opt/tomcat/RELEASE-NOTES ] && \
                ver_actual=$(grep "Apache Tomcat Version" /opt/tomcat/RELEASE-NOTES \
                    | grep -oP '\d+\.\d+\.\d+')
        else
            ver_actual=$(dpkg-query -W -f='${Version}' "$motor" 2>/dev/null | cut -d'-' -f1)
        fi

        local saltar_instalacion=0
        if [ -n "$ver_actual" ]; then
            if [ "$ver_actual" == "$version_sel" ]; then
                echo -e "\n${AMARILLO}[INFO] La versión $version_sel ya está instalada.${RESET}"
                saltar_instalacion=1
            elif dpkg --compare-versions "$ver_actual" lt "$version_sel"; then
                if ! confirmar_accion "¿Actualizar de $ver_actual a $version_sel?"; then return; fi
            else
                if ! confirmar_accion "¿Forzar downgrade de $ver_actual a $version_sel?"; then return; fi
            fi
        fi

        if [ $saltar_instalacion -eq 0 ]; then
            echo -e "\n${AMARILLO}--- FASE 3: DESCARGA E INSTALACIÓN ---${RESET}"
            systemctl stop "$motor" >> "$LOG_FILE" 2>&1

            # Purga limpia
            case "$motor" in
                apache2)
                    apt-get purge -yq 'apache2*' 'libapr*' >> "$LOG_FILE" 2>&1
                    rm -rf /etc/apache2 /var/www/apache2 >> "$LOG_FILE" 2>&1 ;;
                nginx)
                    apt-get purge -yq 'nginx*' 'libnginx-mod*' >> "$LOG_FILE" 2>&1
                    rm -rf /etc/nginx /var/www/nginx >> "$LOG_FILE" 2>&1 ;;
                tomcat)
                    rm -rf /opt/tomcat >> "$LOG_FILE" 2>&1 ;;
            esac
            apt-get autoremove -yq --purge >> "$LOG_FILE" 2>&1

            if ! instalador_paquetes "$motor" "$version_sel"; then
                log_error "Fallo en la instalación. Revise $LOG_FILE"
                pausa; return
            fi
        fi
        version_instalada="$version_sel"

    else
        # ── INSTALACIÓN DESDE FTP ──────────────────────────────
        echo -e "\n${AMARILLO}--- NAVEGANDO REPOSITORIO FTP ---${RESET}"
        local archivo_descargado
        archivo_descargado=$(ftp_navegar_y_descargar "$motor")
        if [ $? -ne 0 ] || [ -z "$archivo_descargado" ]; then
            log_error "No se pudo obtener el instalador desde el FTP."
            pausa; return
        fi

        echo -e "\n${AMARILLO}--- INSTALANDO DESDE ARCHIVO LOCAL ---${RESET}"
        systemctl stop "$motor" >> "$LOG_FILE" 2>&1

        case "$motor" in
            apache2)
                apt-get purge -yq 'apache2*' 'libapr*' >> "$LOG_FILE" 2>&1
                rm -rf /etc/apache2 /var/www/apache2 >> "$LOG_FILE" 2>&1 ;;
            nginx)
                apt-get purge -yq 'nginx*' 'libnginx-mod*' >> "$LOG_FILE" 2>&1
                rm -rf /etc/nginx /var/www/nginx >> "$LOG_FILE" 2>&1 ;;
        esac
        apt-get autoremove -yq --purge >> "$LOG_FILE" 2>&1

        if ! ftp_instalar_binario "$archivo_descargado" "$motor"; then
            log_error "Fallo en la instalación del binario descargado."
            pausa; return
        fi

        # Extraer versión del nombre del archivo
        version_instalada=$(basename "$archivo_descargado" \
            | grep -oP '\d+[\.\d]+' | head -1)
        [ -z "$version_instalada" ] && version_instalada="desconocida"
        rm -f "$archivo_descargado"
    fi

    # 4. Configurar puerto
    echo -e "\n${AMARILLO}--- FASE 4: CONFIGURACIÓN DE RED ---${RESET}"
    local puerto_sel
    while true; do
        puerto_sel=$(capturar_entero "Puerto TCP de escucha")
        validar_puerto "$puerto_sel"
        local ep=$?
        if [ $ep -eq 0 ]; then
            log_ok "Puerto $puerto_sel libre y validado."
            break
        elif [ $ep -eq 2 ]; then
            log_error "Puerto $puerto_sel reservado para infraestructura crítica."
        else
            log_error "Puerto $puerto_sel ya en uso. Elija otro."
        fi
    done

    if ! configurar_puerto_servicio "$motor" "$puerto_sel"; then
        log_error "Fallo al configurar el puerto."
        pausa; return
    fi

    # 5. Hardening
    echo -e "\n${AMARILLO}--- FASE 5: HARDENING ---${RESET}"
    aplicar_hardening_seguridad "$motor"
    aislar_directorio_web "$motor"

    # 6. Plantilla HTML
    echo -e "\n${AMARILLO}--- FASE 6: CONTENIDO WEB ---${RESET}"
    desplegar_plantilla_html "$motor" "$version_instalada" "$puerto_sel"

    # 7. SSL opcional
    echo ""
    if confirmar_accion "¿Desea activar SSL/TLS en $motor ahora? (dominio: $DOMINIO_SSL)"; then
        activar_ssl_desde_menu "$motor" "$puerto_sel"
    fi

    log_ok "Despliegue de $motor completado."
    pausa
}

# ============================================================
# ACTIVAR SSL EN SERVIDOR YA INSTALADO
# ============================================================
activar_ssl_desde_menu() {
    local motor_forzado="${1:-}"
    local puerto_forzado="${2:-}"

    if [ -z "$motor_forzado" ]; then
        clear
        echo -e "${AMARILLO}--- ACTIVAR SSL/TLS EN SERVIDOR HTTP ---${RESET}"
    fi

    # Detectar motores instalados
    local arr_instalados=()
    if [ -z "$motor_forzado" ]; then
        dpkg -s apache2 >/dev/null 2>&1 && systemctl is-active --quiet apache2 \
            && arr_instalados+=("apache2")
        dpkg -s nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx \
            && arr_instalados+=("nginx")
        [ -d /opt/tomcat ] && systemctl is-active --quiet tomcat \
            && arr_instalados+=("tomcat")

        if [ ${#arr_instalados[@]} -eq 0 ]; then
            log_error "No hay servidores HTTP activos para configurar SSL."
            pausa; return
        fi

        generar_menu "SELECCIONE EL MOTOR A ASEGURAR" arr_instalados "Cancelar"
        local elec=$?
        [ $elec -eq ${#arr_instalados[@]} ] && return
        motor_forzado="${arr_instalados[$elec]}"
    fi

    # Detectar puerto HTTP actual si no se pasó
    if [ -z "$puerto_forzado" ]; then
        case "$motor_forzado" in
            apache2)
                puerto_forzado=$(grep -E "^Listen [0-9]+" /etc/apache2/ports.conf \
                    | grep -v "443" | awk '{print $2}' | head -1)
                ;;
            nginx)
                puerto_forzado=$(grep -E "^\s*listen [0-9]+" \
                    /etc/nginx/sites-available/default 2>/dev/null \
                    | grep -v "443" | head -1 | awk '{print $2}' | tr -d ';')
                ;;
            tomcat)
                puerto_forzado=$(grep -oP 'protocol="HTTP\/1\.1"[^>]+port="\K[^"]+' \
                    /opt/tomcat/conf/server.xml 2>/dev/null | head -1)
                ;;
        esac
        [ -z "$puerto_forzado" ] && puerto_forzado=80
    fi

    echo -e "\n${AZUL}Motor: ${motor_forzado^^} | Puerto HTTP actual: $puerto_forzado | Dominio SSL: $DOMINIO_SSL${RESET}\n"

    local resultado=1
    case "$motor_forzado" in
        apache2) activar_ssl_apache2 "$DOMINIO_SSL" "$puerto_forzado"; resultado=$? ;;
        nginx)   activar_ssl_nginx   "$DOMINIO_SSL" "$puerto_forzado"; resultado=$? ;;
        tomcat)  activar_ssl_tomcat  "$DOMINIO_SSL";                   resultado=$? ;;
    esac

    [ $resultado -eq 0 ] && \
        log_ok "SSL activado. Acceso seguro: https://$DOMINIO_SSL" || \
        log_error "No se pudo activar SSL en ${motor_forzado^^}."

    [ -z "$1" ] && pausa
}

# ============================================================
# ACTIVAR FTPS EN VSFTPD
# ============================================================
activar_ftps_menu() {
    clear
    echo -e "${AMARILLO}--- ACTIVAR FTPS EN VSFTPD ---${RESET}"
    echo -e "${AZUL}Dominio SSL: $DOMINIO_SSL${RESET}\n"

    if ! dpkg -s vsftpd >/dev/null 2>&1; then
        log_error "vsftpd no está instalado. Ejecute el Módulo FTP primero."
        pausa; return
    fi

    echo -e "${AZUL}Estado actual:${RESET}"
    if grep -q "^ssl_enable=YES" /etc/vsftpd.conf 2>/dev/null; then
        log_info "FTPS ya está activado."
        if ! confirmar_accion "¿Desea reconfigurar FTPS con el dominio $DOMINIO_SSL?"; then
            pausa; return
        fi
    fi

    activar_ftps_vsftpd "$DOMINIO_SSL"
    pausa
}

# ============================================================
# MENÚ PRINCIPAL P7
# ============================================================
menu_ssl() {
    local opciones_p7=(
        "Instalar Servidor HTTP (WEB o FTP + SSL opcional)"
        "Activar SSL/TLS en servidor ya instalado"
        "Activar FTPS en vsftpd (FTP seguro)"
        "Resumen de estado SSL/TLS (verificación automática)"
        "Preparar repositorio FTP (estructura + binarios + SHA256)"
        "Configurar dominio para certificados [actual: $DOMINIO_SSL]"
    )

    while true; do
        # Actualizar etiqueta del dominio en el menú
        opciones_p7[5]="Configurar dominio para certificados [actual: $DOMINIO_SSL]"

        generar_menu "P7 — INFRAESTRUCTURA DE DESPLIEGUE SEGURO" opciones_p7 "Volver al Menú Principal"
        local eleccion=$?

        case $eleccion in
            0) instalar_servidor_http ;;
            1) activar_ssl_desde_menu ;;
            2) activar_ftps_menu ;;
            3) resumen_ssl_linux ;;
            4) ftp_preparar_repositorio ;;
            5) configurar_dominio ;;
            6) clear; return ;;
        esac
    done
}

menu_ssl