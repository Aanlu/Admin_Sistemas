#!/bin/bash

# Importar utils desde la raíz del proyecto
source libs/utils.sh

# ==========================================
# VARIABLES DE CONFIGURACIÓN
# ==========================================
NETWORK_NAME="infra_red"
SUBNET="172.20.0.0/16"
VOL_DB="db_data"
VOL_WEB="web_content"
DB_CONTAINER="bd_postgres"
WEB_CONTAINER="web_server"
FTP_CONTAINER="ftp_server"

# ==========================================
# DEPENDENCIA Y AUDITORÍA
# ==========================================


pull_con_reintento() {
    local imagen=$1
    local intentos=3
    for i in $(seq 1 $intentos); do
        log_info "Descargando $imagen (intento $i/$intentos)..."
        if sudo docker pull "$imagen"; then
            return 0
        fi
        [ $i -lt $intentos ] && sleep 5
    done
    log_error "No se pudo descargar $imagen después de $intentos intentos."
    return 1
}

ver_pagina_web() {
    clear
    echo -e "${AZUL}==========================================================${RESET}"
    echo -e "           ${AMARILLO}VERIFICACIÓN DEL SERVICIO WEB${RESET}"
    echo -e "${AZUL}==========================================================${RESET}"

    # --- 1. Estado del contenedor ---
    echo -e "\n${CIAN}[1] Estado del contenedor web:${RESET}"
    if sudo docker ps --format "{{.Names}}" | grep -q "^${WEB_CONTAINER}$"; then
        log_ok "$WEB_CONTAINER está corriendo."
        sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep $WEB_CONTAINER
    else
        log_error "$WEB_CONTAINER NO está corriendo. Ejecuta primero la opción 'Desplegar Infraestructura'."
        pausa
        return
    fi

    # --- 2. Verificar respuesta HTTP con curl ---
    echo -e "\n${CIAN}[2] Respuesta HTTP (curl localhost:80):${RESET}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null)
    
    if [ "$HTTP_CODE" = "200" ]; then
        log_ok "HTTP $HTTP_CODE — Apache respondiendo correctamente."
    elif [ "$HTTP_CODE" = "000" ]; then
        log_error "Sin respuesta. El puerto 80 no está accesible."
    else
        log_warning "HTTP $HTTP_CODE — Respuesta inesperada."
    fi

    # --- 3. Mostrar contenido HTML en terminal ---
    echo -e "\n${CIAN}[3] Contenido HTML recibido:${RESET}"
    echo -e "${AMARILLO}-------------------------------------------${RESET}"
    curl -s http://localhost 2>/dev/null || echo "No se pudo obtener contenido."
    echo -e "\n${AMARILLO}-------------------------------------------${RESET}"

    # --- 4. Headers HTTP ---
    echo -e "\n${CIAN}[4] Headers de respuesta (seguridad):${RESET}"
    curl -sI http://localhost 2>/dev/null | grep -E "(HTTP|Server:|Content-Type:)" || echo "No disponible."

    # --- 5. Instrucciones Port Forward VSCode ---
    HOST_PORT=80
    echo -e "\n${CIAN}[5] Ver en navegador desde tu PC (VSCode Port Forwarding):${RESET}"
    echo -e "${AMARILLO}"
    echo -e "  Opción A — Automático (recomendado):"
    echo -e "    1. En VSCode: Panel inferior → pestaña ${RESET}${AZUL}PORTS${AMARILLO}"
    echo -e "    2. Clic en ${RESET}${AZUL}\"Forward a Port\"${AMARILLO}"
    echo -e "    3. Escribe: ${RESET}${CIAN}${HOST_PORT}${AMARILLO} y presiona Enter"
    echo -e "    4. Abre en tu navegador: ${RESET}${CIAN}http://localhost:${HOST_PORT}${AMARILLO}"
    echo -e ""
    echo -e "  Opción B — Manual (desde tu terminal local, fuera de SSH):"
    HOST_IP=$(obtener_ip_local)
    echo -e "    ${RESET}${CIAN}ssh -L ${HOST_PORT}:localhost:${HOST_PORT} usuario@${HOST_IP:-<IP-DEL-SERVIDOR>}${AMARILLO}"
    echo -e "    Luego abre: ${RESET}${CIAN}http://localhost:${HOST_PORT}${RESET}"

    pausa
}

verificar_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_warning "Docker no detectado. Instalando dependencia..."
        instalar_dependencia_silenciosa "docker.io"
        systemctl enable --now docker >/dev/null 2>&1
        hash -r 
        sleep 2
    fi
}

auditar_entorno() {
    clear
    echo -e "${AZUL}==========================================================${RESET}"
    echo -e "                 ${AMARILLO}AUDITORÍA DE SERVICIOS${RESET}"
    echo -e "${AZUL}==========================================================${RESET}"
    
    echo -e "\n${CIAN}[1] Puertos bloqueados (80/21):${RESET}"
    ss -tulpn | grep -E ':(80|21)\b' || echo "Puertos libres."

    echo -e "\n${CIAN}[2] Servicios Nativos:${RESET}"
    for srv in apache2 vsftpd; do
        systemctl is-active --quiet $srv && log_error "$srv está corriendo localmente."
    done

    echo -e "\n${CIAN}[3] Contenedores activos:${RESET}"
    sudo docker ps --format "table {{.Names}}\t{{.Status}}"
    
    pausa
}

liberar_recursos_locales() {
    log_info "Limpiando procesos en puertos 80 y 21..."
    systemctl stop apache2 vsftpd 2>/dev/null
    # Matar procesos persistentes que impiden el bind de Docker
    if command -v fuser >/dev/null 2>&1; then
        sudo fuser -k 80/tcp 21/tcp >/dev/null 2>&1
    fi
    sleep 1
}

# ==========================================
# INSTALACIÓN (IDEMPOTENTE)
# ==========================================

instalar_infraestructura() {
    verificar_docker
    liberar_recursos_locales

    log_info "Eliminando contenedores e imagen previa..."
    sudo docker rm -f $DB_CONTAINER $WEB_CONTAINER $FTP_CONTAINER >/dev/null 2>&1

    log_info "Configurando Red y Volúmenes..."
    sudo docker network inspect $NETWORK_NAME >/dev/null 2>&1 || \
        sudo docker network create --driver bridge --subnet $SUBNET $NETWORK_NAME >/dev/null

    sudo docker volume create $VOL_DB >/dev/null
    sudo docker volume create $VOL_WEB >/dev/null

    # ── Preparar contenido estático en el volumen ──────────────────
    log_info "Preparando contenido web estático..."
    local TMP_WEB="/tmp/web_content"
    mkdir -p "$TMP_WEB/css"
    cat > "$TMP_WEB/index.html" <<'HTML'
<html>
  <head><link rel="stylesheet" href="css/style.css"></head>
  <body><h1>Servidor UAS - Tarea 10</h1></body>
</html>
HTML
    cat > "$TMP_WEB/css/style.css" <<'CSS'
body { background: #1a1a2e; color: #00d4ff; text-align: center; padding-top: 80px; font-family: sans-serif; }
CSS
    # Copiar al volumen usando un contenedor alpine ya en caché
    sudo docker run --rm \
        -v $VOL_WEB:/vol \
        -v "$TMP_WEB":/src \
        alpine:latest \
        sh -c "cp -r /src/* /vol/ && chmod -R 755 /vol"

    # ── Imágenes: pull con reintento ───────────────────────────────
    pull_con_reintento "httpd:alpine"      || { pausa; return 1; }
    pull_con_reintento "postgres:15-alpine" || { pausa; return 1; }
    pull_con_reintento "fauria/vsftpd"     || { pausa; return 1; }

    # ── Contenedores ──────────────────────────────────────────────
    ejecutar_con_loader "Iniciando PostgreSQL" \
        sudo docker run -d \
            --name $DB_CONTAINER \
            --network $NETWORK_NAME \
            -v $VOL_DB:/var/lib/postgresql/data \
            -e POSTGRES_USER=admin \
            -e POSTGRES_PASSWORD=secreto \
            -e POSTGRES_DB=empresa_db \
            postgres:15-alpine

    HOST_IP=$(obtener_ip_local)
    ejecutar_con_loader "Iniciando FTP Server" \
        sudo docker run -d \
            --name $FTP_CONTAINER \
            --network $NETWORK_NAME \
            -p 21:21 -p 20:20 \
            -p 21100-21110:21100-21110 \
            -v $VOL_WEB:/home/vsftpd/ftpuser \
            -e FTP_USER=ftpuser \
            -e FTP_PASS=ftppass \
            -e PASV_ADDRESS=${HOST_IP:-127.0.0.1} \
            -e PASV_MIN_PORT=21100 \
            -e PASV_MAX_PORT=21110 \
            fauria/vsftpd

    # httpd:alpine escucha en 80, hardening via variables de entorno
    ejecutar_con_loader "Iniciando Web Server (httpd:alpine)" \
        sudo docker run -d \
            --name $WEB_CONTAINER \
            --network $NETWORK_NAME \
            --memory="512m" \
            --cpus="0.5" \
            -p 80:80 \
            -v $VOL_WEB:/usr/local/apache2/htdocs \
            httpd:alpine

    log_ok "Despliegue completado."
    pausa
}

# ==========================================
# MENÚ DE PRUEBAS (DISPLAY DE COMANDOS)
# ==========================================

opciones_modulo10=(
    "Auditar Entorno (Ver estado de puertos/docker)"
    "Desplegar Infraestructura (Instalación limpia)"
    "Ver Página Web"   # <-- NUEVA
    "Prueba 10.1: Persistencia de BD (Comandos)"
    "Prueba 10.2: Aislamiento de red (Comandos)"
    "Prueba 10.3: Permisos FTP y Web (Comandos)"
    "Prueba 10.4: Límites de Recursos (Comandos)"
)

while true; do
    generar_menu "MÓDULO 10: CONTENEDORES" opciones_modulo10 "Regresar al Menú Principal"
    eleccion=$?

    case $eleccion in
        0) auditar_entorno ;;
        1) instalar_infraestructura ;;
        2) ver_pagina_web ;;
        3)
            echo -e "\n${AMARILLO}[ PRUEBA 10.1 - PERSISTENCIA ]${RESET}"
            echo -e "Copia estos comandos para demostrar que los datos sobreviven al borrado:"
            echo -e "${CIAN}# 1. Crear dato:\n${RESET}sudo docker exec -it $DB_CONTAINER psql -U admin -d empresa_db -c \"CREATE TABLE IF NOT EXISTS pruebas (dato TEXT); INSERT INTO pruebas VALUES ('Persistencia OK');\""
            echo -e "${CIAN}# 2. Borrar contenedor:\n${RESET}sudo docker rm -f $DB_CONTAINER"
            echo -e "${CIAN}# 3. Recrear y verificar:\n${RESET}sudo docker run -d --name $DB_CONTAINER --network $NETWORK_NAME -v $VOL_DB:/var/lib/postgresql/data -e POSTGRES_USER=admin -e POSTGRES_PASSWORD=secreto -e POSTGRES_DB=empresa_db postgres:15-alpine"
            echo -e "sleep 5 && sudo docker exec -it $DB_CONTAINER psql -U admin -d empresa_db -c \"SELECT * FROM pruebas;\""
            pausa ;;
        4)
            echo -e "\n${AMARILLO}[ PRUEBA 10.2 - RED ]${RESET}"
            echo -e "Comando para probar la resolución de nombres interna:"
            echo -e "${CIAN}sudo docker exec -it $WEB_CONTAINER ping -c 4 $DB_CONTAINER${RESET}"
            pausa ;;
        5)
            echo -e "\n${AMARILLO}[ PRUEBA 10.3 - FTP & PERMISOS ]${RESET}"
            echo -e "Comandos para subir archivo y verificar via HTTP:"
            echo -e "${CIAN}echo '<h1>Prueba FTP</h1>' > test.html${RESET}"
            echo -e "${CIAN}curl -T test.html ftp://ftpuser:ftppass@localhost/test.html${RESET}"
            echo -e "${CIAN}# Ajustar permisos para que Apache pueda leerlo:${RESET}"
            echo -e "${CIAN}sudo docker exec $WEB_CONTAINER chmod 644 /usr/local/apache2/htdocs/test.html${RESET}"
            echo -e "${CIAN}curl -s http://localhost/test.html${RESET}"
            pausa ;;
        6)
            echo -e "\n${AMARILLO}[ PRUEBA 10.4 - RECURSOS ]${RESET}"
            echo -e "Comando para evidenciar los límites de RAM (512MiB):"
            echo -e "${CIAN}sudo docker stats $WEB_CONTAINER --no-stream${RESET}"
            pausa ;;
        7) break ;;
    esac
done