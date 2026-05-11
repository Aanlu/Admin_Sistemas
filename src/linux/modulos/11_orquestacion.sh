#!/bin/bash
source libs/utils.sh

DIR_DEPLOY="/opt/infra_iac"
DIR_TEMPLATES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../templates/linux" && pwd)"
DOCKER_COMPOSE="sudo /usr/local/bin/docker-compose"

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
    log_info "Fase 0: Limpieza profunda y preparación del entorno..."
    
    # 1. Bajar stack de orquestación sin la bandera -v (Protege la base de datos)
    if [ -d "$DIR_DEPLOY" ]; then
        cd "$DIR_DEPLOY" && $DOCKER_COMPOSE down --remove-orphans >/dev/null 2>&1
    fi

    # 2. Bajar stack de correo (Módulo 12) si existe para robarle el puerto 80
    if [ -d "/opt/infra_mail" ]; then
        cd "/opt/infra_mail" && $DOCKER_COMPOSE down --remove-orphans >/dev/null 2>&1
    fi

    # 3. Forzar borrado de contenedores zombies y redes
    sudo docker rm -f frontend_nginx webapp_interna db_postgres panel_pgadmin >/dev/null 2>&1
    sudo docker network rm infra_iac_red_publica infra_iac_red_datos red_publica red_datos >/dev/null 2>&1
    
    # 4. Matar cualquier servicio nativo en los puertos
    sudo systemctl stop apache2 tomcat nginx 2>/dev/null
    sudo fuser -k 80/tcp 8080/tcp 2>/dev/null
    
    # 5. Recrear directorio limpio
    sudo rm -rf "$DIR_DEPLOY" && mkdir -p "$DIR_DEPLOY"

    # 6. Instalar dependencias si no existen
    instalar_dependencia_silenciosa "docker.io"
    instalar_dependencia_silenciosa "ufw"
}

desplegar_stack() {
    # Llamamos a nuestra súper función unificada
    limpiar_y_preparar_entorno
    
    log_info "Configurando variables de entorno (Zero Hardcoding)..."
    log_info "Configurando variables de entorno (Zero Hardcoding)..."
    read -p "Usuario DB [admin_db]: " db_user; db_user=${db_user:-admin_db}
    read -sp "Password DB: " db_pass; echo ""
    # Genera password automático si se deja en blanco
    db_pass=${db_pass:-$(tr -dc A-Za-z0-9_ < /dev/urandom | head -c 16)}
    
    read -p "Email pgAdmin [admin@fim.uas]: " pg_email; pg_email=${pg_email:-admin@fim.uas}
    read -sp "Password pgAdmin: " pg_pass; echo ""
    pg_pass=${pg_pass:-$(tr -dc A-Za-z0-9_ < /dev/urandom | head -c 16)}

    # Copiamos las plantillas
    cp "$DIR_TEMPLATES/docker-compose.yml.template" "$DIR_DEPLOY/docker-compose.yml"
    cp "$DIR_TEMPLATES/nginx-iac.conf.template" "$DIR_DEPLOY/nginx.conf"
    cp "$DIR_TEMPLATES/env.template" "$DIR_DEPLOY/.env"

    # Inyectamos
    _inyectar_template "$DIR_DEPLOY/.env" "@@DB_USER@@" "$db_user"
    _inyectar_template "$DIR_DEPLOY/.env" "@@DB_PASS@@" "$db_pass"
    _inyectar_template "$DIR_DEPLOY/.env" "@@DB_NAME@@" "app_db"
    _inyectar_template "$DIR_DEPLOY/.env" "@@PG_EMAIL@@" "$pg_email"
    _inyectar_template "$DIR_DEPLOY/.env" "@@PG_PASS@@" "$pg_pass"
    _inyectar_template "$DIR_DEPLOY/.env" "@@NGINX_PORT@@" "80"

    chmod 600 "$DIR_DEPLOY/.env"

    log_info "Configurando Firewall Perimetral (UFW)..."
    ufw allow 22/tcp >/dev/null 2>&1
    ufw deny 8080/tcp >/dev/null 2>&1
    ufw deny 5432/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    
    cd "$DIR_DEPLOY" || exit
    ejecutar_con_loader "Levantando Microservicios IaC" sudo docker-compose up -d
    log_ok "Despliegue completado con éxito."
    pausa
}

prueba_11_1() {
    echo -e "\n${AMARILLO}[ PRUEBA 11.1 - Aislamiento de red ]${RESET}"
    echo -e "Usando el comando: ${AZUL}curl --connect-timeout 2 http://localhost:5432${RESET}"
    if curl --connect-timeout 2 http://localhost:5432 &>/dev/null; then
        log_error "Fallo: El servicio de BD está expuesto al exterior."
    else
        log_ok "Éxito: Conexión rechazada o timeout (Servicio invisible fuera de Docker)."
    fi
    pausa
}

prueba_11_2() {
    echo -e "\n${AMARILLO}[ PRUEBA 11.2 - Resolución interna DNS ]${RESET}"
    echo -e "Usando el comando: ${AZUL}sudo docker exec frontend_nginx ping -c 2 db_postgres${RESET}"
    if sudo docker exec frontend_nginx ping -c 2 db_postgres | grep -q "0% packet loss"; then
        log_ok "Éxito: Los contenedores se comunican por nombre de servicio."
    else
        log_error "Fallo: No hay resolución DNS interna."
    fi
    pausa
}

prueba_11_3() {
    HOST_IP=$(obtener_ip_local)
    echo -e "\n${AMARILLO}[ PRUEBA 11.3 - Túnel Cifrado de Gestión ]${RESET}"
    echo -e "Esta prueba debe realizarse desde la máquina física (Windows)."
    echo -e "Usando el comando en tu terminal local (CMD/PowerShell):"
    echo -e "${AZUL}ssh -L 8080:127.0.0.1:8080 usuario@${HOST_IP:-<IP-DEL-SERVIDOR>}${RESET}"
    echo -e "Una vez conectado, abre en tu navegador web: ${CIAN}http://localhost:8080${RESET}"
    echo -e "Deberías ver la pantalla de login de pgAdmin4."
    pausa
}

prueba_11_4() {
    echo -e "\n${AMARILLO}[ PRUEBA 11.4 - Persistencia y Buen Funcionamiento ]${RESET}"
    echo -e "Usando los comandos: ${AZUL}sudo docker-compose down && sudo docker-compose up -d${RESET}"
    cd "$DIR_DEPLOY" && sudo docker-compose down && sudo docker-compose up -d
    
    log_info "Esperando 12 segundos para evaluación del healthcheck de la base de datos..."
    sleep 12
    
    echo -e "Usando el comando: ${AZUL}sudo docker inspect --format='{{json .State.Health.Status}}' db_postgres${RESET}"
    local health=$(sudo docker inspect --format='{{json .State.Health.Status}}' db_postgres | tr -d '"')
    if [ "$health" == "healthy" ]; then
        log_ok "Éxito: Base de datos saludable. pgAdmin iniciará gracias a depends_on."
    else
        log_warning "Estado: '$health'. Puede requerir más tiempo en este hardware, pgAdmin esperará."
    fi
    pausa
}

opciones_modulo11=(
    "Desplegar Infraestructura (Docker Compose)"
    "Prueba 11.1: Validación de aislamiento de red"
    "Prueba 11.2: Validación de resolución interna DNS"
    "Prueba 11.3: Validación de túnel cifrado (SSH Local Forward)"
    "Prueba 11.4: Validación de persistencia y healthcheck"
)

while true; do
    generar_menu "MÓDULO 11: ORQUESTACIÓN IaC" opciones_modulo11 "Regresar al Menú Principal"
    eleccion=$?

    case $eleccion in
        0) desplegar_stack ;;
        1) prueba_11_1 ;;
        2) prueba_11_2 ;;
        3) prueba_11_3 ;;
        4) prueba_11_4 ;;
        5) break ;;
    esac
done