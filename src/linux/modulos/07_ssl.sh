#!/bin/bash
# ============================================================
# 07_ssl.sh — Práctica 7: Infraestructura de Despliegue Seguro
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../libs/utils.sh"
source "$SCRIPT_DIR/../libs/validaciones.sh"
source "$SCRIPT_DIR/../libs/http_funciones.sh"
source "$SCRIPT_DIR/../libs/ftp_cliente.sh"
source "$SCRIPT_DIR/../libs/ssl_funciones.sh"

DOMINIO_SSL="${DOMINIO_SSL:-reprobados.com}"

configurar_dominio() {
    clear
    echo -e "${AMARILLO}--- CONFIGURACIÓN DE DOMINIO SSL ---${RESET}"
    echo -e "Dominio actual: ${VERDE}$DOMINIO_SSL${RESET}\n"
    echo -e "${AZUL}Este dominio se usará en el CN de todos los certificados.${RESET}"
    echo -e "${AZUL}Debe coincidir con el dominio en el DNS local (P3).${RESET}\n"

    read -p "Nuevo dominio [Enter para mantener '$DOMINIO_SSL']: " nuevo
    if [ -n "$nuevo" ]; then
        nuevo="${nuevo,,}"
        nuevo="${nuevo#www.}"
        if [[ "$nuevo" =~ ^[a-z0-9-]+\.[a-z]{2,}(\.[a-z]{2,})?$ ]]; then
            DOMINIO_SSL="$nuevo"
            export DOMINIO_SSL
            guardar_estado "DOMINIO_SSL" "$DOMINIO_SSL"
            log_ok "Dominio SSL configurado: $DOMINIO_SSL"
        else
            log_error "Formato inválido. Se mantiene: $DOMINIO_SSL"
        fi
    fi
    pausa
}

_crear_usuario_repo() {
    id ftprepositorio >/dev/null 2>&1 && return 0

    getent group ftp_auth >/dev/null || groupadd ftp_auth

    if [ ! -d /var/ftp_master ]; then
        mkdir -p /var/ftp_master/general
        chown root:ftp_auth /var/ftp_master/general
        chmod 2775 /var/ftp_master/general
    fi

    chown root:root /var/ftp_master
    chmod 755 /var/ftp_master

    useradd -M -d /var/ftp_master -s /usr/sbin/nologin \
        -g ftp_auth ftprepositorio 2>/dev/null
    echo "ftprepositorio:Repo_P7!" | chpasswd
    log_ok "Usuario ftprepositorio creado (contraseña: Repo_P7!)"
}

instalar_servidor_http() {
    clear
    echo -e "${AMARILLO}=== INSTALACIÓN HÍBRIDA DE SERVIDOR HTTP ===${RESET}\n"

    local arr_fuentes=(
        "WEB  — Repositorios oficiales (apt / Apache mirrors)"
        "FTP  — Repositorio privado (servidor P5)"
    )
    generar_menu "SELECCIONE LA FUENTE DE INSTALACIÓN" arr_fuentes "Cancelar"
    local fuente=$?
    [ $fuente -eq ${#arr_fuentes[@]} ] && return

    local motor=""
    local version_instalada=""
    local archivo_descargado=""
    local saltar_instalacion=0

    if [ $fuente -eq 0 ]; then
        # ── DESDE WEB ─────────────────────────────────────────
        local arr_motores=("apache2" "nginx" "tomcat")
        generar_menu "SELECCIONE EL MOTOR HTTP" arr_motores "Cancelar"
        local opcion_motor=$?
        [ $opcion_motor -eq ${#arr_motores[@]} ] && return
        motor="${arr_motores[$opcion_motor]}"

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

        local version_sel
        version_sel=$(echo "${arr_versiones[$opcion_ver]}" | awk '{print $1}')

        local ver_actual=""
        if [ "$motor" == "tomcat" ]; then
            [ -f /opt/tomcat/RELEASE-NOTES ] && \
                ver_actual=$(grep "Apache Tomcat Version" /opt/tomcat/RELEASE-NOTES \
                    | grep -oP '\d+\.\d+\.\d+')
        else
            ver_actual=$(dpkg-query -W -f='${Version}' "$motor" 2>/dev/null \
                | cut -d'-' -f1)
        fi

        if [ -n "$ver_actual" ]; then
            if [ "$ver_actual" == "$version_sel" ]; then
                echo -e "\n${AMARILLO}[INFO] La versión $version_sel ya está instalada.${RESET}"
                version_instalada="$version_sel"
                if confirmar_accion "¿Purgar y reinstalar desde cero?"; then
                    saltar_instalacion=0
                else
                    saltar_instalacion=1
                fi
            elif dpkg --compare-versions "$ver_actual" lt "$version_sel"; then
                if ! confirmar_accion "¿Actualizar de $ver_actual a $version_sel?"; then
                    return
                fi
                saltar_instalacion=0
            else
                if ! confirmar_accion "¿Forzar downgrade de $ver_actual a $version_sel?"; then
                    return
                fi
                saltar_instalacion=0
            fi
        else
            saltar_instalacion=0
        fi

        if [ "$saltar_instalacion" -eq 0 ]; then
            echo -e "\n${AMARILLO}--- FASE 3: DESCARGA E INSTALACIÓN ---${RESET}"
            purgar_motor_http "$motor"
            if ! ejecutar_con_loader "Instalando $motor v$version_sel" \
                    instalador_paquetes "$motor" "$version_sel"; then
                log_error "Fallo en la instalación WEB. Revise $LOG_FILE"
                pausa; return
            fi
        fi
        version_instalada="$version_sel"

    else
        # ── DESDE FTP ─────────────────────────────────────────
        if systemctl is-active --quiet vsftpd 2>/dev/null; then

            local arr_ftp_origen=(
                "Local  — este mismo servidor"
                "Remoto — otro servidor FTP"
            )
            generar_menu "ORIGEN DEL REPOSITORIO FTP" arr_ftp_origen "Cancelar"
            local ftp_origen=$?

            if [ $ftp_origen -eq ${#arr_ftp_origen[@]} ]; then
                return
            elif [ $ftp_origen -eq 0 ]; then
                # FTP LOCAL
                local ip_local
                ip_local=$(obtener_ip_local)
                [ -z "$ip_local" ] && ip_local="127.0.0.1"

                FTP_IP="$ip_local"

                local repo_users_ref
                repo_users_ref=$(awk -F: '$6=="/var/ftp_master" {printf "%s ", $1}' \
                    /etc/passwd)
                echo -e "\n${AZUL}[*] Usuarios repo disponibles: ${VERDE}${repo_users_ref}${RESET}"
                echo -e "${AZUL}[*] IP FTP local: ${VERDE}$ip_local${RESET}\n"

                read -p "Usuario FTP [Enter para 'ftprepositorio']: " FTP_USER </dev/tty
                [ -z "$FTP_USER" ] && FTP_USER="ftprepositorio"

                if [ "$FTP_USER" == "ftprepositorio" ]; then
                    _crear_usuario_repo
                    FTP_PASS="Repo_P7!"
                    log_info "Usando usuario interno ftprepositorio (Repo_P7!)"
                else
                    read -s -p "Contraseña para '$FTP_USER': " FTP_PASS </dev/tty
                    echo ""
                    [ -z "$FTP_PASS" ] && { log_error "Contraseña vacía."; pausa; return; }
                fi
                # Verificar conexión — detectar si requiere TLS
            FTP_USA_TLS=false
            echo -e "${CIAN}[*] Verificando conexión a ftp://$FTP_IP ...${RESET}"
            if curl -s --connect-timeout 8 --max-time 15 \
                    --disable-epsv --ftp-pasv --ftp-skip-pasv-ip \
                    "ftp://$FTP_IP/" --user "$FTP_USER:$FTP_PASS" \
                    --list-only >/dev/null 2>&1; then
                FTP_USA_TLS=false
                log_ok "Conexión FTP exitosa como '$FTP_USER'."
            elif curl -s --connect-timeout 8 --max-time 15 \
                    --disable-epsv --ftp-pasv --ftp-skip-pasv-ip \
                    --ssl-reqd --insecure \
                    "ftp://$FTP_IP/" --user "$FTP_USER:$FTP_PASS" \
                    --list-only >/dev/null 2>&1; then
                FTP_USA_TLS=true
                log_ok "Conexión FTPS exitosa como '$FTP_USER' (TLS)."
            else
                log_error "No se pudo conectar al FTP local."
                pausa; return
            fi
                log_ok "Conexión al FTP local exitosa como '$FTP_USER'."

            else
                # FTP REMOTO
                ftp_conectar || { pausa; return; }
            fi

        else
            log_warning "vsftpd no activo. Conexión remota forzada."
            ftp_conectar || { pausa; return; }
        fi

        echo -e "\n${AMARILLO}--- NAVEGANDO REPOSITORIO FTP ---${RESET}"
        ftp_navegar_y_descargar
        if [ $? -ne 0 ] || [ -z "$FTP_ARCHIVO_DESCARGADO" ]; then
            log_error "Fallo al obtener instalador desde el FTP."
            pausa; return
        fi
        archivo_descargado="$FTP_ARCHIVO_DESCARGADO"
        motor="$FTP_MOTOR_DETECTADO"
        echo -e "\n${AMARILLO}--- FASE 3: INSTALACIÓN DESDE ARCHIVO LOCAL ---${RESET}"
        purgar_motor_http "$motor"

        if ! ejecutar_con_loader "Instalando $motor desde FTP" \
                ftp_instalar_binario "$archivo_descargado" "$motor"; then
            log_error "Fallo crítico al instalar binario descargado."
            pausa; return
        fi

        version_instalada=$(basename "$archivo_descargado" \
            | grep -oP '\d+[\.\d]+' | head -1)
        [ -z "$version_instalada" ] && version_instalada="FTP-Offline"
        rm -f "$archivo_descargado"
    fi

    # ── FASE 4: RED ───────────────────────────────────────────
    echo -e "\n${AMARILLO}--- FASE 4: CONFIGURACIÓN DE RED ---${RESET}"

    # CORRECCIÓN CRÍTICA: No usar $() — capturar_puerto_inteligente
    # llama a confirmar_accion/generar_menu que necesitan escribir al terminal.
    # Usamos la variable global PUERTO_CAPTURADO en su lugar.
    capturar_puerto_inteligente "$motor"
    local puerto_http="$PUERTO_CAPTURADO"

    if [ -z "$puerto_http" ]; then
        log_error "No se pudo capturar el puerto."
        pausa; return
    fi

    if ! configurar_puerto_servicio "$motor" "$puerto_http"; then
        log_error "Fallo al inyectar el puerto HTTP."
        pausa; return
    fi
    guardar_estado "PUERTO_HTTP_${motor^^}" "$puerto_http"

    # ── FASE 5: HARDENING ────────────────────────────────────
    echo -e "\n${AMARILLO}--- FASE 5: HARDENING Y CONTENIDO ---${RESET}"
    aplicar_hardening_seguridad "$motor"
    aislar_directorio_web "$motor"
    desplegar_plantilla_html "$motor" "$version_instalada" "$puerto_http"

    # ── FASE 6: SSL OPCIONAL ─────────────────────────────────
    echo ""
    if confirmar_accion "¿Activar SSL/TLS en $motor ahora? (dominio: $DOMINIO_SSL)"; then
        local puerto_ssl
        case "$motor" in
            apache2) puerto_ssl=443  ;;
            nginx)   puerto_ssl=444  ;;
            tomcat)  puerto_ssl=8443 ;;
        esac

        echo -e "${AZUL}[*] Puerto SSL sugerido para $motor: $puerto_ssl${RESET}"
        validar_puerto "$puerto_ssl"
        local estado_puerto_ssl=$?
        if [ $estado_puerto_ssl -ne 0 ]; then
            log_warning "Puerto SSL $puerto_ssl no disponible. Ingrese uno manual."
            read -p "Puerto SSL manual para $motor: " puerto_ssl </dev/tty
        fi

        local ssl_exit=1
        case "$motor" in
            apache2)
                activar_ssl_apache2 "$DOMINIO_SSL" "$puerto_http" "$puerto_ssl"
                ssl_exit=$? ;;
            nginx)
                activar_ssl_nginx "$DOMINIO_SSL" "$puerto_http" "$puerto_ssl"
                ssl_exit=$? ;;
            tomcat)
                activar_ssl_tomcat "$DOMINIO_SSL"
                ssl_exit=$? ;;
        esac

        if [ $ssl_exit -eq 0 ]; then
            guardar_estado "PUERTO_SSL_${motor^^}" "$puerto_ssl"
            guardar_estado "SSL_ACTIVO_${motor^^}" "SI"
            log_ok "SSL/TLS activado → https://$DOMINIO_SSL:$puerto_ssl"
        else
            guardar_estado "SSL_ACTIVO_${motor^^}" "ERROR"
            log_error "Fallo al activar SSL en ${motor^^}. Revise $LOG_FILE."
        fi
    else
        guardar_estado "SSL_ACTIVO_${motor^^}" "NO"
    fi

    log_ok "Despliegue de $motor completado."
    pausa
}

activar_ssl_desde_menu() {
    local motor_forzado="${1:-}"
    local puerto_forzado="${2:-}"

    if [ -z "$motor_forzado" ]; then
        clear
        echo -e "${AMARILLO}--- ACTIVAR SSL/TLS EN SERVIDOR HTTP ---${RESET}"
    fi

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

    if [ -z "$puerto_forzado" ]; then
        case "$motor_forzado" in
            apache2)
                puerto_forzado=$(grep -E "^Listen [0-9]+" \
                    /etc/apache2/ports.conf 2>/dev/null \
                    | grep -v "443" | awk '{print $2}' | head -1)
                ;;
            nginx)
                puerto_forzado=$(grep -E "^\s*listen [0-9]+" \
                    /etc/nginx/sites-available/default 2>/dev/null \
                    | grep -v "443" | head -1 | awk '{print $2}' | tr -d ';')
                ;;
            tomcat)
                puerto_forzado=$(grep -oP \
                    'protocol="HTTP\/1\.1"[^>]+port="\K[^"]+' \
                    /opt/tomcat/conf/server.xml 2>/dev/null | head -1)
                ;;
        esac
        [ -z "$puerto_forzado" ] && puerto_forzado=80
    fi

    echo -e "\n${AZUL}Motor: ${motor_forzado^^} | HTTP: $puerto_forzado | Dominio: $DOMINIO_SSL${RESET}\n"

    local resultado=1
    case "$motor_forzado" in
        apache2)
            activar_ssl_apache2 "$DOMINIO_SSL" "$puerto_forzado"
            resultado=$? ;;
        nginx)
            activar_ssl_nginx "$DOMINIO_SSL" "$puerto_forzado"
            resultado=$? ;;
        tomcat)
            activar_ssl_tomcat "$DOMINIO_SSL"
            resultado=$? ;;
    esac

    if [ $resultado -eq 0 ]; then
        log_ok "SSL activado → https://$DOMINIO_SSL"
    else
        log_error "No se pudo activar SSL en ${motor_forzado^^}."
    fi

    [ -z "$1" ] && pausa
}

activar_ftps_menu() {
    clear
    echo -e "${AMARILLO}--- ACTIVAR FTPS EN VSFTPD ---${RESET}"
    echo -e "${AZUL}Dominio SSL: $DOMINIO_SSL${RESET}\n"

    if ! dpkg -s vsftpd >/dev/null 2>&1; then
        log_error "vsftpd no está instalado. Ejecute el Módulo FTP primero."
        pausa; return
    fi

    if grep -q "^ssl_enable=YES" /etc/vsftpd.conf 2>/dev/null; then
        log_info "FTPS ya está activado."
        if ! confirmar_accion "¿Reconfigurar FTPS con dominio $DOMINIO_SSL?"; then
            pausa; return
        fi
    fi

    activar_ftps_vsftpd "$DOMINIO_SSL"
    pausa
}

gestionar_usuarios_repo() {
    clear
    echo -e "${AMARILLO}=== USUARIOS DE ACCESO AL REPOSITORIO FTP ===${RESET}\n"

    echo -e "${AZUL}[ Usuarios con acceso al repositorio ]${RESET}"
    echo -e "----------------------------------------------------"

    local arr_repo_users=()
    while IFS= read -r linea; do
        local usr home
        usr=$(echo "$linea"  | cut -d: -f1)
        home=$(echo "$linea" | cut -d: -f6)
        local grupo; grupo=$(id -gn "$usr" 2>/dev/null)
        if [ "$home" == "/var/ftp_master" ]; then
            arr_repo_users+=("$usr")
            printf "  ${VERDE}%-15s${RESET} grupo: %-12s\n" "$usr" "$grupo"
        fi
    done < /etc/passwd

    [ ${#arr_repo_users[@]} -eq 0 ] && echo -e "  ${AMARILLO}(ninguno todavía)${RESET}"
    echo ""

    local opciones_repo=(
        "Agregar usuario de descarga"
        "Eliminar usuario de descarga"
        "Verificar acceso (curl test)"
    )

    generar_menu "GESTIÓN DE USUARIOS REPO FTP" opciones_repo "Volver"
    local eleccion=$?
    [ $eleccion -eq ${#opciones_repo[@]} ] && return

    case $eleccion in
        0)
            echo -e "\n${AMARILLO}--- AGREGAR USUARIO DE DESCARGA ---${RESET}"
            echo -e "${AZUL}Podrá navegar /var/ftp_master/ via FTP${RESET}\n"

            local nuevo_usr nuevo_pass
            nuevo_usr=$(capturar_usuario_seguro "Nombre de usuario")

            if id "$nuevo_usr" >/dev/null 2>&1; then
                local home_actual
                home_actual=$(getent passwd "$nuevo_usr" | cut -d: -f6)
                if [ "$home_actual" == "/var/ftp_master" ]; then
                    log_warning "Usuario '$nuevo_usr' ya existe como usuario repo."
                    if confirmar_accion "¿Actualizar su contraseña?"; then
                        read -s -p "Nueva contraseña: " nuevo_pass </dev/tty; echo ""
                        [ -z "$nuevo_pass" ] && { log_error "Vacía."; pausa; return; }
                        echo "$nuevo_usr:$nuevo_pass" | chpasswd
                        log_ok "Contraseña actualizada."
                    fi
                    pausa; return
                else
                    log_error "Usuario '$nuevo_usr' existe con otro rol (home: $home_actual)."
                    pausa; return
                fi
            fi

            read -s -p "Contraseña para $nuevo_usr: " nuevo_pass </dev/tty; echo ""
            [ -z "$nuevo_pass" ] && { log_error "Contraseña vacía."; pausa; return; }

            getent group ftp_auth >/dev/null || groupadd ftp_auth
            useradd -M -d /var/ftp_master -s /usr/sbin/nologin \
                -g ftp_auth "$nuevo_usr"
            echo "$nuevo_usr:$nuevo_pass" | chpasswd

            chown root:root /var/ftp_master
            chmod 755 /var/ftp_master
            grep -q "/usr/sbin/nologin" /etc/shells || \
                echo "/usr/sbin/nologin" >> /etc/shells

            if ! grep -q "^local_root=/var/ftp_master" /etc/vsftpd.conf 2>/dev/null; then
                echo "local_root=/var/ftp_master" >> /etc/vsftpd.conf
                systemctl restart vsftpd >> "$LOG_FILE" 2>&1
            fi

            local ip_show; ip_show=$(obtener_ip_local)
            log_ok "Usuario '$nuevo_usr' creado."
            echo -e "\n${VERDE}Credenciales para el profesor:${RESET}"
            echo -e "  Host : ${CIAN}$ip_show${RESET}"
            echo -e "  User : ${CIAN}$nuevo_usr${RESET}"
            echo -e "  Pass : ${CIAN}$nuevo_pass${RESET}"
            echo -e "  Path : ${CIAN}ftp://$ip_show/http/Linux/${RESET}"
            ;;

        1)
            echo -e "\n${AMARILLO}--- ELIMINAR USUARIO DE DESCARGA ---${RESET}"
            if [ ${#arr_repo_users[@]} -eq 0 ]; then
                log_error "No hay usuarios repo."
                pausa; return
            fi
            generar_menu "USUARIO A ELIMINAR" arr_repo_users "Cancelar"
            local idx=$?
            [ $idx -eq ${#arr_repo_users[@]} ] && return
            local usr_borrar="${arr_repo_users[$idx]}"
            if confirmar_accion "¿Eliminar '$usr_borrar'?"; then
                userdel "$usr_borrar" 2>/dev/null
                log_ok "Usuario '$usr_borrar' eliminado."
            fi
            ;;

        2)
            echo -e "\n${AMARILLO}--- VERIFICACIÓN DE ACCESO FTP ---${RESET}"
            if [ ${#arr_repo_users[@]} -eq 0 ]; then
                log_error "No hay usuarios repo."
                pausa; return
            fi
            generar_menu "USUARIO A VERIFICAR" arr_repo_users "Cancelar"
            local idx=$?
            [ $idx -eq ${#arr_repo_users[@]} ] && return

            local usr_test="${arr_repo_users[$idx]}"
            local ip_ftp; ip_ftp=$(obtener_ip_local)

            read -s -p "Contraseña de $usr_test: " pass_test </dev/tty; echo ""

            echo -e "\n${CIAN}[*] Probando navegación FTP en $ip_ftp...${RESET}\n"

            _ftp_listar() {
                local ruta="$1" etiqueta="$2"
                echo -e "${AZUL}[ $etiqueta ]${RESET}"
                local resultado
                resultado=$(curl -s --connect-timeout 5 \
                    --disable-epsv --ftp-pasv --ftp-skip-pasv-ip \
                    --list-only \
                    "ftp://$ip_ftp/$ruta/" \
                    --user "$usr_test:$pass_test" 2>/dev/null)
                if [ -n "$resultado" ]; then
                    echo "$resultado" | while read -r f; do echo "  $f"; done
                else
                    echo -e "  ${ROJO}(sin respuesta o acceso denegado)${RESET}"
                fi
                echo ""
            }

            _ftp_listar ""                   "Raíz /"
            _ftp_listar "http/Linux"         "/http/Linux/"
            _ftp_listar "http/Linux/Apache"  "/http/Linux/Apache/"
            _ftp_listar "http/Linux/Nginx"   "/http/Linux/Nginx/"
            _ftp_listar "http/Linux/Tomcat"  "/http/Linux/Tomcat/"
            ;;
    esac

    pausa
}

menu_ssl() {
    local opciones_p7=(
        "Instalar Servidor HTTP (WEB o FTP + SSL opcional)"
        "Activar SSL/TLS en servidor ya instalado"
        "Activar FTPS en vsftpd (FTP seguro)"
        "Resumen de estado SSL/TLS (verificación automática)"
        "Preparar repositorio FTP (estructura + binarios + SHA256)"
        "Gestionar usuarios de descarga (Repositorio FTP)"
        "Configurar dominio para certificados [actual: $DOMINIO_SSL]"
    )

    while true; do
        opciones_p7[6]="Configurar dominio para certificados [actual: $DOMINIO_SSL]"

        generar_menu "P7 — INFRAESTRUCTURA DE DESPLIEGUE SEGURO" \
            opciones_p7 "Volver al Menú Principal"
        local eleccion=$?

        case $eleccion in
            0) instalar_servidor_http ;;
            1) activar_ssl_desde_menu ;;
            2) activar_ftps_menu ;;
            3) resumen_ssl_linux ;;
            4) ftp_preparar_repositorio ;;
            5) gestionar_usuarios_repo ;;
            6) configurar_dominio ;;
            7) clear; return ;;
        esac
    done
}

menu_ssl