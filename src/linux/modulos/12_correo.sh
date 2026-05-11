#!/bin/bash
source libs/utils.sh

DIR_DEPLOY="/opt/infra_mail"
DIR_TEMPLATES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../templates/linux/mail" && pwd)"
DOCKER_COMPOSE="sudo /usr/local/bin/docker-compose"

# ─────────────────────────────────────────────
# Garantiza que docker-compose esté disponible
# ─────────────────────────────────────────────
verificar_docker_compose() {
    if ! command -v /usr/local/bin/docker-compose &>/dev/null; then
        log_info "docker-compose no encontrado. Instalando..."
        sudo curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
            -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        log_ok "docker-compose instalado: $(/usr/local/bin/docker-compose version --short)"
    fi
}

limpiar_y_preparar_entorno() {
    verificar_docker_compose
    log_info "Fase 0: Aplicando Idempotencia (Liberando puertos y conflictos)..."
    
    # Se remueve la bandera -v para proteger la persistencia de correos y BDD
    if [ -d "/opt/infra_iac" ]; then 
        cd "/opt/infra_iac" && $DOCKER_COMPOSE down --remove-orphans >/dev/null 2>&1
    fi
    
    if [ -d "$DIR_DEPLOY" ]; then 
        cd "$DIR_DEPLOY" && $DOCKER_COMPOSE down --remove-orphans >/dev/null 2>&1
    fi
    
    sudo docker rm -f core_mailserver db_webmail portal_webmail >/dev/null 2>&1
    sudo fuser -k 80/tcp 443/tcp 25/tcp 143/tcp 587/tcp 993/tcp 2>/dev/null
    sudo rm -rf "$DIR_DEPLOY" && mkdir -p "$DIR_DEPLOY"
}

crear_cuentas_correo() {
    local dom=$1
    local pass_admin=$2
    local pass_dir=$3
    log_info "Creando buzones criptográficos..."
    sudo docker exec core_mailserver setup email add "admin@${dom}" "${pass_admin}" >/dev/null 2>&1
    sudo docker exec core_mailserver setup email add "director@${dom}" "${pass_dir}" >/dev/null 2>&1
    log_ok "Cuentas admin@${dom} y director@${dom} creadas con éxito."
}

desplegar_stack() {
    limpiar_y_preparar_entorno
    log_info "Configuración de Dominio y Seguridad..."
    read -p "Dominio de la organización [reprobados.com]: " dominio; dominio=${dominio:-reprobados.com}
    read -sp "Contraseña admin@$dominio [Enter para default: 12345]: " admin_pass; echo ""
    admin_pass=${admin_pass:-12345}
    read -sp "Contraseña director@$dominio [Enter para default: 12345]: " dir_pass; echo ""
    dir_pass=${dir_pass:-12345}

    db_root_pass=$(tr -dc A-Za-z0-9_ < /dev/urandom | head -c 16)
    rc_db_pass=$(tr -dc A-Za-z0-9_ < /dev/urandom | head -c 16)

    cp "$DIR_TEMPLATES/docker-compose.yml.template" "$DIR_DEPLOY/docker-compose.yml"
    cp "$DIR_TEMPLATES/env.template" "$DIR_DEPLOY/.env"

    _inyectar_template "$DIR_DEPLOY/.env" "@@DOMAIN@@" "$dominio"
    _inyectar_template "$DIR_DEPLOY/.env" "@@ADMIN_PASS@@" "$admin_pass"
    _inyectar_template "$DIR_DEPLOY/.env" "@@DIRECTOR_PASS@@" "$dir_pass"
    _inyectar_template "$DIR_DEPLOY/.env" "@@DB_ROOT_PASS@@" "$db_root_pass"
    _inyectar_template "$DIR_DEPLOY/.env" "@@RC_DB_PASS@@" "$rc_db_pass"

    log_info "Generando certificados SSL/TLS para el dominio $dominio..."
    mkdir -p "$DIR_DEPLOY/config/ssl"
    sudo openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
        -subj "/C=MX/ST=Sinaloa/L=Los Mochis/O=FIM/CN=mail.${dominio}" \
        -keyout "$DIR_DEPLOY/config/ssl/mail.${dominio}-key.pem" \
        -out "$DIR_DEPLOY/config/ssl/mail.${dominio}-cert.pem" >/dev/null 2>&1
    sudo chmod -R 777 "$DIR_DEPLOY/config"

    log_info "Ajustando Firewall (UFW)..."
    sudo ufw allow 80/tcp && sudo ufw allow 25/tcp && sudo ufw allow 143/tcp \
        && sudo ufw allow 587/tcp && sudo ufw allow 993/tcp >/dev/null 2>&1

    cd "$DIR_DEPLOY" || exit
    ejecutar_con_loader "Levantando Infraestructura de Correo y Webmail" $DOCKER_COMPOSE up -d

    log_info "Esperando 30 segundos a que el motor criptográfico inicialice..."
    sleep 30

    log_info "Configurando políticas de confianza TLS en el Webmail..."
    sudo docker exec portal_webmail bash -c 'echo "\$config[\"imap_conn_options\"] = array(\"ssl\" => array(\"verify_peer\" => false, \"verify_peer_name\" => false, \"allow_self_signed\" => true));" >> /var/www/html/config/config.inc.php'
    sudo docker exec portal_webmail bash -c 'echo "\$config[\"smtp_conn_options\"] = array(\"ssl\" => array(\"verify_peer\" => false, \"verify_peer_name\" => false, \"allow_self_signed\" => true));" >> /var/www/html/config/config.inc.php'

    crear_cuentas_correo "$dominio" "$admin_pass" "$dir_pass"
    log_ok "Despliegue finalizado."
    echo -e "\e[1;36mIngresa a http://$(obtener_ip_local) desde Windows para ver Roundcube.\e[0m"
    pausa
}

prueba_12_2() {
    echo -e "\n\e[1;33m[ PRUEBA 12.2 - Auditoría de Registros (Logging) ]\e[0m"
    sudo docker exec core_mailserver tail -n 20 /var/log/mail/mail.log
    pausa
}

prueba_12_3() {
    echo -e "\n\e[1;33m[ PRUEBA 12.3 - Verificación de Fail2ban ]\e[0m"
    sudo docker exec core_mailserver fail2ban-client status dovecot || echo "Fail2ban inicializando..."
    pausa
}

prueba_13_4_crear() {
    echo -e "\n\e[1;33m[ PRUEBA 13.4 (Fase 1) - Crear Respaldo ]\e[0m"
    FECHA=$(date +"%Y%m%d_%H%M")
    BACKUP_FILE="/opt/backup_buzones_$FECHA.tar.gz"
    # Verificar que el volumen existe antes de respaldar
    if [ ! -d "/var/lib/docker/volumes/mail_buzones/_data" ]; then
        log_error "Volumen mail_buzones no encontrado. ¿Está el stack desplegado?"
        pausa; return
    fi
    sudo tar -czvf "$BACKUP_FILE" -C /var/lib/docker/volumes/mail_buzones/_data . >/dev/null 2>&1
    if [ -f "$BACKUP_FILE" ]; then
        log_ok "Respaldo exitoso creado en: $BACKUP_FILE"
    else
        log_error "Fallo al crear el respaldo."
    fi
    pausa
}

prueba_13_4_restaurar() {
    echo -e "\n\e[1;33m[ PRUEBA 13.4 (Fase 2) - Restaurar Respaldo ]\e[0m"
    LATEST_BACKUP=$(ls -t /opt/backup_buzones_*.tar.gz 2>/dev/null | head -n 1)
    if [ -z "$LATEST_BACKUP" ]; then
        log_error "No hay respaldos en /opt/. Ejecuta la Fase 1 primero."
        pausa; return
    fi
    log_info "Se restaurará el archivo: $LATEST_BACKUP"
    echo -e "\e[1;31mADVERTENCIA: Asegúrate de haber borrado un correo en Roundcube para probar la recuperación.\e[0m"
    read -p "¿Continuar con la restauración? (s/n): " confirm
    if [[ "$confirm" == "s" ]]; then
        cd "$DIR_DEPLOY" && $DOCKER_COMPOSE stop mailserver
        log_info "Restaurando volumen..."
        sudo tar -xzvf "$LATEST_BACKUP" -C /var/lib/docker/volumes/mail_buzones/_data >/dev/null 2>&1
        cd "$DIR_DEPLOY" && $DOCKER_COMPOSE start mailserver
        log_ok "Restauración lista. Ve a Roundcube y verifica que tu correo volvió."
    fi
    pausa
}

asistente_pruebas_gui() {
    clear
    echo -e "\e[1;36m=== ASISTENTE DE PRUEBAS GRÁFICAS (GUI) ===\e[0m"
    echo -e "Realiza esto en tu Windows y toma capturas:\n"
    echo -e "\e[1;32m1. PRUEBA 13.5 (Login):\e[0m Entra a http://$(obtener_ip_local) e inicia sesión."
    echo -e "\e[1;32m2. PRUEBA 13.6 (Adjuntos):\e[0m Envía un correo con archivo a director@reprobados.com."
    echo -e "\e[1;32m3. PRUEBA 12.1 (Thunderbird):\e[0m Abre Thunderbird, conecta la cuenta y envía un correo."
    echo -e "\e[1;32m4. PRUEBA 13.7 (Persistencia):\e[0m Ve a Roundcube, cambia el idioma o el tema visual."
    echo -e "\nPresiona Enter CUANDO HAYAS CAMBIADO EL TEMA para simular la caída del servidor..."
    read -p ""
    log_info "Reiniciando servidor web forzosamente..."
    sudo docker restart portal_webmail >/dev/null
    log_ok "Servidor reiniciado. Recarga Roundcube en Windows y toma captura de que tu tema se guardó."
    pausa
}

opciones_modulo12=(
    "Desplegar Infraestructura (Mailserver + Roundcube)"
    "Prueba 12.2: Auditoría de registros (mail.log)"
    "Prueba 12.3: Verificación de seguridad Fail2ban"
    "Prueba 13.4 (Paso 1): Crear Respaldo de Buzones"
    "Prueba 13.4 (Paso 2): Restaurar Respaldo ante desastre"
    "Asistente para Pruebas Gráficas (12.1, 13.5, 13.6, 13.7)"
)

while true; do
    generar_menu "MÓDULO 12: INFRAESTRUCTURA DE CORREO" opciones_modulo12 "Regresar"
    eleccion=$?
    case $eleccion in
        0) desplegar_stack ;;
        1) prueba_12_2 ;;
        2) prueba_12_3 ;;
        3) prueba_13_4_crear ;;
        4) prueba_13_4_restaurar ;;
        5) asistente_pruebas_gui ;;
        6) break ;;
    esac
done