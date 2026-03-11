#!/bin/bash

extraer_versiones_dinamicas() {
    local paquete_web=$1
    
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        return 1
    fi

    if [ "$paquete_web" == "tomcat" ]; then
        local versiones_tomcat=$(curl -s https://archive.apache.org/dist/tomcat/tomcat-10/ | grep -oP 'v10\.[0-9]+\.[0-9]+' | sort -uV | sed 's/v//')
        [ -z "$versiones_tomcat" ] && return 1
        
        local latest=$(echo "$versiones_tomcat" | tail -n 1)
        local oldest=$(echo "$versiones_tomcat" | head -n 1)
        local lts=$(echo "$versiones_tomcat" | tail -n 2 | head -n 1)
        
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
    
    local lista_versiones=$(apt-cache madison "$paquete_web" 2>/dev/null | awk '{print $3}' | sort -ur)
    [ -z "$lista_versiones" ] && return 1

    local latest=$(echo "$lista_versiones" | head -n 1)
    local oldest=$(echo "$lista_versiones" | tail -n 1)
    
    local lts=$(apt-cache policy "$paquete_web" 2>/dev/null | grep -B 1 "500 http://.*ubuntu.* main" | head -n 1 | awk '{print $1}')
    
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
        wget -q "https://archive.apache.org/dist/tomcat/tomcat-10/v${version}/bin/apache-tomcat-${version}.tar.gz" -O /tmp/tomcat.tar.gz >> "$LOG_FILE" 2>&1
        if [ ! -f /tmp/tomcat.tar.gz ]; then
            rm -f /usr/sbin/policy-rc.d
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
        rm -f /usr/sbin/policy-rc.d
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
        
        rm -f /etc/apt/preferences.d/99-downgrade
        rm -f /usr/sbin/policy-rc.d
        trap - INT
        return $install_status
    fi
}

configurar_puerto_servicio() {
    local motor=$1
    local puerto=$2

    fuser -k -n tcp "$puerto" >/dev/null 2>&1

    case $motor in
        apache2)
            if [ ! -f /etc/apache2/ports.conf ]; then
                echo "Listen $puerto" > /etc/apache2/ports.conf
            else
                sed -i -E "s/^Listen [0-9]+/Listen $puerto/g" /etc/apache2/ports.conf
            fi
            mkdir -p /var/www/apache2
            if [ -f /etc/apache2/sites-available/000-default.conf ]; then
                sed -i -E "s|<VirtualHost \*:.*>|<VirtualHost \*:$puerto>|g" /etc/apache2/sites-available/000-default.conf
                sed -i -E "s|^\s*DocumentRoot.*|        DocumentRoot /var/www/apache2|g" /etc/apache2/sites-available/000-default.conf
            fi
            systemctl restart apache2 >/dev/null 2>&1
            ;;
        nginx)
            mkdir -p /var/www/nginx
            cat > /etc/nginx/sites-available/default <<EOF
server {
    listen $puerto default_server;
    listen [::]:$puerto default_server;
    root /var/www/nginx;
    index index.html index.htm index.nginx-debian.html;
    server_name _;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
            systemctl restart nginx >/dev/null 2>&1
            ;;
        tomcat)
            [ -f /opt/tomcat/conf/server.xml ] && sed -i -E "s/Connector port=\"[0-9]+\"/Connector port=\"$puerto\"/g" /opt/tomcat/conf/server.xml
            systemctl restart tomcat >/dev/null 2>&1
            ;;
    esac

    if systemctl is-active --quiet "$motor"; then
        ufw allow "$puerto"/tcp >/dev/null 2>&1
        return 0
    else
        return 1
    fi
}

aplicar_hardening_seguridad() {
    local motor=$1
    
    case $motor in
        apache2)
            if [ -f /etc/apache2/conf-available/security.conf ]; then
                sed -i 's/^ServerTokens OS/ServerTokens Prod/g' /etc/apache2/conf-available/security.conf
                sed -i 's/^ServerSignature On/ServerSignature Off/g' /etc/apache2/conf-available/security.conf
                sed -i 's/^TraceEnable On/TraceEnable Off/g' /etc/apache2/conf-available/security.conf
            fi
            [ -f /etc/apache2/apache2.conf ] && sed -i 's/Options Indexes FollowSymLinks/Options -Indexes -FollowSymLinks/g' /etc/apache2/apache2.conf
            a2enmod headers >> "$LOG_FILE" 2>&1
            if [ -f /etc/apache2/apache2.conf ] && ! grep -q "X-Frame-Options" /etc/apache2/apache2.conf; then
                echo "Header always append X-Frame-Options SAMEORIGIN" >> /etc/apache2/apache2.conf
                echo "Header always append X-Content-Type-Options nosniff" >> /etc/apache2/apache2.conf
            fi
            systemctl restart apache2 >> "$LOG_FILE" 2>&1
            ;;
        nginx)
            [ -f /etc/nginx/nginx.conf ] && sed -i 's/.*server_tokens off;/        server_tokens off;/g' /etc/nginx/nginx.conf
            if [ -f /etc/nginx/nginx.conf ] && ! grep -q "X-Frame-Options" /etc/nginx/nginx.conf; then
                sed -i '/http {/a \ \ \ \ add_header X-Content-Type-Options nosniff;' /etc/nginx/nginx.conf
                sed -i '/http {/a \ \ \ \ add_header X-Frame-Options SAMEORIGIN;' /etc/nginx/nginx.conf
            fi
            if [ -f /etc/nginx/sites-available/default ] && ! grep -q "limit_except" /etc/nginx/sites-available/default; then
                sed -i '/location \/ {/a \ \ \ \ \ \ \ \ limit_except GET POST { deny all; }' /etc/nginx/sites-available/default
            fi
            systemctl restart nginx >> "$LOG_FILE" 2>&1
            ;;
        tomcat)
            if [ -f /opt/tomcat/conf/server.xml ] && ! grep -q 'server="Tomcat"' /opt/tomcat/conf/server.xml; then
                sed -i 's/protocol="HTTP\/1.1"/protocol="HTTP\/1.1" server="Tomcat"/g' /opt/tomcat/conf/server.xml
            fi
            if [ -f /opt/tomcat/conf/web.xml ] && ! grep -q "HttpHeaderSecurityFilter" /opt/tomcat/conf/web.xml; then
                sed -i '/<\/web-app>/i \
    <filter>\n        <filter-name>httpHeaderSecurity</filter-name>\n        <filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class>\n        <init-param>\n            <param-name>antiClickJackingEnabled</param-name>\n            <param-value>true</param-value>\n        </init-param>\n    </filter>\n    <filter-mapping>\n        <filter-name>httpHeaderSecurity</filter-name>\n        <url-pattern>/*</url-pattern>\n    </filter-mapping>' /opt/tomcat/conf/web.xml
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
    local ruta_template="../../templates/linux/index.web.template"
    
    [ "$motor" == "tomcat" ] && ruta_html="/opt/tomcat/webapps/ROOT/index.html" && mkdir -p /opt/tomcat/webapps/ROOT/

    if [ -f "$ruta_template" ]; then
        cp "$ruta_template" "$ruta_html"
        sed -i "s/@@MOTOR@@/${motor^^}/g" "$ruta_html"
        sed -i "s/@@VERSION@@/$version/g" "$ruta_html"
        sed -i "s/@@PUERTO@@/$puerto/g" "$ruta_html"
    else
        echo "<h1>Servidor: ${motor^^} - Version: $version - Puerto: $puerto</h1>" > "$ruta_html"
    fi
}