#!/bin/bash

extraer_versiones_dinamicas() {
    local paquete_web=$1

    _verificar_y_reparar_dns() {
        if ! nslookup archive.apache.org >/dev/null 2>&1 && \
           ! nslookup google.com >/dev/null 2>&1; then

            log_warning "DNS local no resuelve dominios externos. Reparando automáticamente..."
            chattr -i /etc/resolv.conf 2>/dev/null || true

            local gw
            gw=$(ip route | grep default | awk '{print $3}' | head -1)

            if [ -n "$gw" ]; then
                log_info "Usando gateway $gw como DNS temporal..."
                echo "nameserver $gw" > /etc/resolv.conf
                if nslookup google.com >/dev/null 2>&1; then
                    log_ok "DNS reparado → $gw"
                    return 0
                fi
            fi

            log_warning "Gateway no resuelve. Usando DNS público de respaldo..."
            printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf

            if nslookup google.com >/dev/null 2>&1; then
                log_ok "DNS reparado → 8.8.8.8 (temporal para instalación)"
                return 0
            fi

            log_error "Sin conectividad DNS. Verifique la red de la VM."
            return 1
        fi
        return 0
    }

    if ! curl -s --connect-timeout 5 --max-time 8 \
            "https://archive.apache.org" >/dev/null 2>&1; then
        _verificar_y_reparar_dns || return 1
        if ! curl -s --connect-timeout 5 --max-time 8 \
                "https://archive.apache.org" >/dev/null 2>&1; then
            return 1
        fi
    fi

    if [ "$paquete_web" == "tomcat" ]; then
        local versiones_tomcat
        versiones_tomcat=$(curl -s --max-time 15 \
            https://archive.apache.org/dist/tomcat/tomcat-10/ \
            | grep -oP 'v10\.[0-9]+\.[0-9]+' | sort -uV | sed 's/v//')
        [ -z "$versiones_tomcat" ] && return 1

        local latest oldest lts
        latest=$(echo "$versiones_tomcat" | tail -n 1)
        oldest=$(echo "$versiones_tomcat" | head -n 1)
        lts=$(echo "$versiones_tomcat" | tail -n 2 | head -n 1)

        echo "$lts (LTS)"
        [ "$latest" != "$lts" ] && echo "$latest (Latest)"
        [ "$oldest" != "$lts" ] && [ "$oldest" != "$latest" ] && echo "$oldest (Oldest)"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C.UTF-8

    if [ "$paquete_web" == "apache2" ]; then
        if ! ls /etc/apt/sources.list.d/ 2>/dev/null | grep -q "ondrej-ubuntu-apache2"; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -yq software-properties-common >/dev/null 2>&1
            timeout 20s add-apt-repository ppa:ondrej/apache2 -y >/dev/null 2>&1
            apt-get update -qq >/dev/null 2>&1
        fi
    elif [ "$paquete_web" == "nginx" ]; then
        if ! ls /etc/apt/sources.list.d/ 2>/dev/null | grep -q "ondrej-ubuntu-nginx"; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -yq software-properties-common >/dev/null 2>&1
            timeout 20s add-apt-repository ppa:ondrej/nginx-mainline -y >/dev/null 2>&1
            apt-get update -qq >/dev/null 2>&1
        fi
    fi

    local lista_versiones
    lista_versiones=$(apt-cache madison "$paquete_web" 2>/dev/null \
        | awk '{print $3}' | sort -ur)
    [ -z "$lista_versiones" ] && return 1

    local latest oldest lts
    latest=$(echo "$lista_versiones" | head -n 1)
    oldest=$(echo "$lista_versiones" | tail -n 1)
    lts=$(apt-cache policy "$paquete_web" 2>/dev/null \
        | grep -B 1 "500 http://.*ubuntu.* main" | head -n 1 | awk '{print $1}')

    [ -z "$lts" ] && lts=$(echo "$lista_versiones" | sed -n '2p')
    [ -z "$lts" ] && lts="$latest"

    echo "$lts (LTS)"
    [ "$latest" != "$lts" ] && echo "$latest (Latest)"
    [ "$oldest" != "$lts" ] && [ "$oldest" != "$latest" ] && echo "$oldest (Oldest)"
}

validar_puerto() {
    local puerto=$1
    if [[ "$puerto" -eq 22 || "$puerto" -eq 21 || "$puerto" -eq 53 ]]; then
        return 2
    fi
    if ss -tln | grep -qE ":${puerto}\s"; then
        return 1
    else
        return 0
    fi
}

instalador_paquetes() {
    local paquete=$1
    local version=$2

    trap 'rm -rf /tmp/tomcat.tar.gz /etc/apt/preferences.d/99-downgrade /usr/sbin/policy-rc.d; exit 1' INT
    export DEBIAN_FRONTEND=noninteractive

    echo -e '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    if [ "$paquete" == "tomcat" ]; then
        apt-get install -yq default-jdk >> "$LOG_FILE" 2>&1
        id -u tomcat >/dev/null 2>&1 || useradd -m -U -d /opt/tomcat -s /bin/false tomcat
        rm -rf /opt/tomcat/*
        curl -f -s "https://archive.apache.org/dist/tomcat/tomcat-10/v${version}/bin/apache-tomcat-${version}.tar.gz" \
            -o /tmp/tomcat.tar.gz >> "$LOG_FILE" 2>&1

        if [ ! -f /tmp/tomcat.tar.gz ] || ! file /tmp/tomcat.tar.gz | grep -q "gzip compressed"; then
            echo -e "\n${ROJO}[ERROR] La versión $version de Tomcat no se pudo descargar.${RESET}"
            rm -f /tmp/tomcat.tar.gz /usr/sbin/policy-rc.d
            trap - INT
            return 1
        fi
        mkdir -p /opt/tomcat
        tar -xf /tmp/tomcat.tar.gz -C /opt/tomcat --strip-components=1 >> "$LOG_FILE" 2>&1
        chown -R tomcat:tomcat /opt/tomcat
        chmod -R u+x /opt/tomcat/bin
        cat > /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Apache Tomcat 10
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=/usr/lib/jvm/default-java"
Environment="CATALINA_HOME=/opt/tomcat"
Environment="CATALINA_BASE=/opt/tomcat"
Environment="CATALINA_PID=/opt/tomcat/temp/tomcat.pid"
ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >> "$LOG_FILE" 2>&1
        systemctl enable tomcat >> "$LOG_FILE" 2>&1
        rm -f /usr/sbin/policy-rc.d /tmp/tomcat.tar.gz
        trap - INT
        return 0
    else
        local pin_packages="${paquete}*"
        if [ "$paquete" == "apache2" ]; then pin_packages="apache2* libapr*"; fi
        if [ "$paquete" == "nginx" ]; then pin_packages="nginx* libnginx-mod*"; fi

        cat > /etc/apt/preferences.d/99-downgrade <<EOF
Package: $pin_packages
Pin: version $version
Pin-Priority: 1001
EOF
        apt-get update -qq >> "$LOG_FILE" 2>&1
        apt-get install -yq --allow-downgrades "${paquete}=${version}" >> "$LOG_FILE" 2>&1
        local install_status=$?

        rm -f /etc/apt/preferences.d/99-downgrade /usr/sbin/policy-rc.d
        trap - INT
        return $install_status
    fi
}

configurar_puerto_servicio() {
    local motor=$1
    local puerto=$2

    echo -e "${CIAN}[*] Asignando el puerto de escucha $puerto a $motor...${RESET}"

    case "$motor" in
        apache2)
            sed -i "s/^Listen .*/Listen $puerto/" /etc/apache2/ports.conf
            sed -i "s/<VirtualHost \*:.*>/<VirtualHost \*:$puerto>/" \
                /etc/apache2/sites-available/000-default.conf
            ;;
        nginx)
            sed -i "s/listen [0-9]\+/listen $puerto/g" \
                /etc/nginx/sites-available/default
            ;;
        tomcat)
            sed -i "s/port=\"[0-9]\+\" protocol=\"HTTP\/1.1\"/port=\"$puerto\" protocol=\"HTTP\/1.1\"/" \
                /opt/tomcat/conf/server.xml
            ;;
    esac
    return 0
}

aplicar_hardening_seguridad() {
    local motor=$1

    case $motor in
        apache2)
            if [ -f /etc/apache2/conf-available/security.conf ]; then
                sed -i 's/^ServerTokens OS/ServerTokens Prod/g' \
                    /etc/apache2/conf-available/security.conf
                sed -i 's/^ServerSignature On/ServerSignature Off/g' \
                    /etc/apache2/conf-available/security.conf
                sed -i 's/^TraceEnable On/TraceEnable Off/g' \
                    /etc/apache2/conf-available/security.conf
            fi
            [ -f /etc/apache2/apache2.conf ] && \
                sed -i 's/Options Indexes FollowSymLinks/Options -Indexes -FollowSymLinks/g' \
                    /etc/apache2/apache2.conf
            a2enmod headers >> "$LOG_FILE" 2>&1
            if [ -f /etc/apache2/apache2.conf ] && \
               ! grep -q "X-Frame-Options" /etc/apache2/apache2.conf; then
                echo "Header always append X-Frame-Options SAMEORIGIN" >> /etc/apache2/apache2.conf
                echo "Header always append X-Content-Type-Options nosniff" >> /etc/apache2/apache2.conf
            fi
            systemctl restart apache2 >> "$LOG_FILE" 2>&1
            ;;
        nginx)
            if [ -f /etc/nginx/nginx.conf ]; then
                if grep -q "#\s*server_tokens off;" /etc/nginx/nginx.conf; then
                    sed -i -E 's/.*#\s*server_tokens off;.*/    server_tokens off;/g' \
                        /etc/nginx/nginx.conf
                elif ! grep -q "server_tokens off;" /etc/nginx/nginx.conf; then
                    sed -i '/http {/a \ \ \ \ server_tokens off;' /etc/nginx/nginx.conf
                fi
            fi
            if [ -f /etc/nginx/nginx.conf ] && \
               ! grep -q "X-Frame-Options" /etc/nginx/nginx.conf; then
                sed -i '/http {/a \ \ \ \ add_header X-Content-Type-Options nosniff;' \
                    /etc/nginx/nginx.conf
                sed -i '/http {/a \ \ \ \ add_header X-Frame-Options SAMEORIGIN;' \
                    /etc/nginx/nginx.conf
            fi
            if [ -f /etc/nginx/sites-available/default ] && \
               ! grep -q "limit_except" /etc/nginx/sites-available/default; then
                sed -i '/location \/ {/a \ \ \ \ \ \ \ \ limit_except GET POST { deny all; }' \
                    /etc/nginx/sites-available/default
            fi
            systemctl restart nginx >> "$LOG_FILE" 2>&1
            ;;
        tomcat)
            if [ -f /opt/tomcat/conf/server.xml ] && \
               ! grep -q 'server="Tomcat"' /opt/tomcat/conf/server.xml; then
                sed -i 's/protocol="HTTP\/1.1"/protocol="HTTP\/1.1" server="Tomcat"/g' \
                    /opt/tomcat/conf/server.xml
            fi
            if [ -f /opt/tomcat/conf/web.xml ] && \
               ! grep -q "HttpHeaderSecurityFilter" /opt/tomcat/conf/web.xml; then
                sed -i '/<\/web-app>/i \
    <filter>\n        <filter-name>httpHeaderSecurity</filter-name>\n        <filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class>\n        <init-param>\n            <param-name>antiClickJackingEnabled</param-name>\n            <param-value>true</param-value>\n        </init-param>\n    </filter>\n    <filter-mapping>\n        <filter-name>httpHeaderSecurity</filter-name>\n        <url-pattern>/*</url-pattern>\n    </filter-mapping>' \
                    /opt/tomcat/conf/web.xml
            fi
            systemctl restart tomcat >> "$LOG_FILE" 2>&1
            ;;
    esac
}

aislar_directorio_web() {
    local motor=$1
    rm -rf /var/www/html 2>/dev/null

    if [ "$motor" == "tomcat" ]; then
        chown -R tomcat:tomcat /opt/tomcat/webapps
        find /opt/tomcat/webapps -type d -exec chmod 750 {} \;
        find /opt/tomcat/webapps -type f -exec chmod 640 {} \;
    else
        chown -R www-data:www-data /var/www/$motor
        find /var/www/$motor -type d -exec chmod 755 {} \;
        find /var/www/$motor -type f -exec chmod 644 {} \;
    fi
}

desplegar_plantilla_html() {
    local motor=$1
    local version=$2
    local puerto=$3
    local ruta_html="/var/www/$motor/index.html"

    [ "$motor" == "tomcat" ] && \
        ruta_html="/opt/tomcat/webapps/ROOT/index.html" && \
        mkdir -p /opt/tomcat/webapps/ROOT/

    # CORRECCIÓN: ruta absoluta basada en BASH_SOURCE, no relativa al CWD
    # CWD puede cambiar dependiendo de cómo se ejecutó el script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local ruta_template="${script_dir}/../../templates/linux/index.web.template"

    if [ -f "$ruta_template" ]; then
        cp "$ruta_template" "$ruta_html"
        sed -i "s|@@MOTOR@@|${motor^^}|g"  "$ruta_html"
        sed -i "s|@@VERSION@@|$version|g"  "$ruta_html"
        sed -i "s|@@PUERTO@@|$puerto|g"    "$ruta_html"
        log_ok "Plantilla desplegada en $ruta_html"
    else
        log_warning "Plantilla no encontrada en $ruta_template — usando fallback"
        printf '<h1>%s — v%s</h1>\n<p>Puerto: <span id="puerto-display">%s</span></p>\n' \
            "${motor^^}" "$version" "$puerto" > "$ruta_html"
    fi
}

purgar_motor_http() {
    local motor=$1
    echo -e "${CIAN}[*] Limpiando instalaciones previas de $motor...${RESET}"
    systemctl stop "$motor" >/dev/null 2>&1

    fuser -k /var/lib/dpkg/lock-frontend   >/dev/null 2>&1
    fuser -k /var/lib/dpkg/lock            >/dev/null 2>&1
    fuser -k /var/lib/apt/lists/lock       >/dev/null 2>&1
    fuser -k /var/cache/apt/archives/lock  >/dev/null 2>&1
    dpkg --configure -a >> "$LOG_FILE" 2>&1

    local -a opts_dpkg=(
        "-o" "Dpkg::Options::=--force-confdef"
        "-o" "Dpkg::Options::=--force-confold"
    )

    case "$motor" in
        apache2)
            ejecutar_con_loader "Purgando Apache2" \
                apt-get purge -yq "${opts_dpkg[@]}" 'apache2*' 'libapr*'
            rm -rf /etc/apache2 /var/www/apache2 /var/www/html >/dev/null 2>&1
            ;;
        nginx)
            ejecutar_con_loader "Purgando Nginx" \
                apt-get purge -yq "${opts_dpkg[@]}" 'nginx*' 'libnginx-mod*'
            rm -rf /etc/nginx /var/www/nginx /var/www/html >/dev/null 2>&1
            ;;
        tomcat)
            rm -rf /opt/tomcat /etc/systemd/system/tomcat.service >/dev/null 2>&1
            systemctl daemon-reload >/dev/null 2>&1
            ;;
    esac

    ejecutar_con_loader "Limpiando dependencias huérfanas" \
        apt-get autoremove -yq --purge "${opts_dpkg[@]}"
    ejecutar_con_loader "Limpiando caché de paquetes" \
        apt-get clean
}

# Variable global para retornar el puerto — evita el subshell que congela generar_menu
PUERTO_CAPTURADO=""

capturar_puerto_inteligente() {
    local motor=$1
    local p_sugerido
    PUERTO_CAPTURADO=""

    case "$motor" in
        apache2) p_sugerido=80   ;;
        nginx)   p_sugerido=81   ;;
        tomcat)  p_sugerido=8080 ;;
    esac

    validar_puerto "$p_sugerido"
    if [ $? -eq 0 ]; then
        # CORRECCIÓN CRÍTICA: NO usar $() para capturar — generar_menu necesita
        # escribir directo al terminal. Usamos variable global PUERTO_CAPTURADO.
        if confirmar_accion "El puerto $p_sugerido es el estándar para $motor y está libre. ¿Usarlo?"; then
            PUERTO_CAPTURADO="$p_sugerido"
            return 0
        fi
    else
        log_warning "Puerto por defecto ($p_sugerido) ocupado. Asigne uno manual."
    fi

    local puerto_manual
    while true; do
        capturar_entero "Ingrese el puerto TCP para $motor"
        # capturar_entero también usa variable global si lo modificamos,
        # pero como no capturamos con $() aquí está bien leerlo con read directo
        read -p "Ingrese el puerto TCP para $motor: " puerto_manual </dev/tty
        puerto_manual="${puerto_manual// /}"

        if ! [[ "$puerto_manual" =~ ^[1-9][0-9]*$ ]] || [ "$puerto_manual" -gt 65535 ]; then
            log_error "Número inválido. Use un entero entre 1 y 65535."
            continue
        fi

        validar_puerto "$puerto_manual"
        local estado=$?

        if [ $estado -eq 0 ]; then
            log_ok "Puerto $puerto_manual libre y validado."
            PUERTO_CAPTURADO="$puerto_manual"
            return 0
        elif [ $estado -eq 2 ]; then
            log_error "Puerto reservado para infraestructura crítica."
        else
            log_error "Puerto YA EN USO. Elija otro."
        fi
    done
}