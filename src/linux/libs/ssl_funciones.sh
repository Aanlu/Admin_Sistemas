#!/bin/bash
# ============================================================
# ssl_funciones.sh — SSL/TLS para P7 (Linux)
# Maneja: Apache2, Nginx, Tomcat, vsftpd
# Dependencias: openssl, utils.sh
# ============================================================

# Dominio configurable — puede sobreescribirse antes de sourcing
DOMINIO_SSL="${DOMINIO_SSL:-reprobados.com}"
DIR_SSL="/etc/ssl/admin_sistemas"

# ------------------------------------------------------------
# generar_cert_autofirmado <dominio>
# Idempotente: no regenera si el cert es válido y no expira en <24h
# ------------------------------------------------------------
generar_cert_autofirmado() {
    local dominio="$1"
    local crt="$DIR_SSL/$dominio.crt"
    local key="$DIR_SSL/$dominio.key"

    mkdir -p "$DIR_SSL"

    # Idempotencia: verificar si ya existe y sigue siendo válido (>1 día de vida)
    if [ -f "$crt" ] && [ -f "$key" ]; then
        if openssl x509 -in "$crt" -noout -checkend 86400 >/dev/null 2>&1; then
            log_info "Certificado para $dominio ya existe y es válido."
            return 0
        else
            log_warning "Certificado para $dominio expirado. Regenerando..."
        fi
    fi

    log_info "Generando certificado autofirmado para $dominio..."

    # SAN (Subject Alternative Names) para que coincida con el dominio
    # y sea compatible con verificaciones modernas
    local san_conf
    san_conf=$(mktemp)
    cat > "$san_conf" <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
C  = MX
ST = Sinaloa
L  = Culiacan
O  = Admin_Sistemas
CN = $dominio

[v3_req]
subjectAltName = DNS:$dominio, DNS:www.$dominio, DNS:ftp.$dominio, DNS:*.${dominio}
keyUsage       = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

    openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "$key" \
        -out "$crt" \
        -config "$san_conf" \
        >> "$LOG_FILE" 2>&1

    rm -f "$san_conf"

    if [ -f "$crt" ] && [ -f "$key" ]; then
        chmod 600 "$key"
        chmod 644 "$crt"
        log_ok "Certificado generado: $crt"
        log_ok "  CN: $dominio | Válido: 365 días | SAN: www.$dominio, ftp.$dominio"
        return 0
    else
        log_error "Error al generar el certificado SSL."
        return 1
    fi
}

# ------------------------------------------------------------
# activar_ssl_apache2 <dominio> [puerto_http]
# Configura HTTPS en el puerto 443 con redirección HTTP→HTTPS
# ------------------------------------------------------------
activar_ssl_apache2() {
    local dominio="$1"
    local puerto_http="${2:-80}"
    local puerto_ssl="${3:-443}" # Parámetro dinámico para evitar colisiones

    local crt="$DIR_SSL/$dominio.crt"
    local key="$DIR_SSL/$dominio.key"

    if ! dpkg -s apache2 >/dev/null 2>&1; then
        log_error "Apache2 no está instalado."
        return 1
    fi

    generar_cert_autofirmado "$dominio" || return 1

    # Permisos para www-data
    chown root:www-data "$key"
    chmod 640 "$key"

    a2enmod ssl rewrite headers >> "$LOG_FILE" 2>&1

    # SNAPSHOT: Respaldo de seguridad (Idempotente)
    local conf_default="/etc/apache2/sites-available/000-default.conf"
    if [ -f "$conf_default" ] && [ ! -f "${conf_default}.bak_admin" ]; then
        cp "$conf_default" "${conf_default}.bak_admin"
        log_info "Snapshot de seguridad HTTP creado para Apache2."
    fi

    # Agregar Listen dinámico
    if ! grep -q "^Listen $puerto_ssl" /etc/apache2/ports.conf; then
        echo "Listen $puerto_ssl" >> /etc/apache2/ports.conf
    fi

    # Crear VirtualHost SSL
    cat > /etc/apache2/sites-available/001-ssl.conf <<EOF
# P7 — SSL VirtualHost generado automáticamente
<VirtualHost *:$puerto_ssl>
    ServerName $dominio
    ServerAlias www.$dominio
    DocumentRoot /var/www/apache2

    SSLEngine on
    SSLCertificateFile    $crt
    SSLCertificateKeyFile $key

    # HSTS básico (1 año)
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-Content-Type-Options nosniff

    <Directory /var/www/apache2>
        Options -Indexes -FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>

# Redirección HTTP → HTTPS usando el puerto SSL dinámico
<VirtualHost *:$puerto_http>
    ServerName $dominio
    ServerAlias www.$dominio
    RewriteEngine On
    RewriteRule ^(.*)$ https://$dominio:$puerto_ssl\$1 [R=301,L]
</VirtualHost>
EOF

    a2ensite 001-ssl >> "$LOG_FILE" 2>&1
    ufw allow "$puerto_ssl"/tcp >/dev/null 2>&1

    if apache2ctl configtest >> "$LOG_FILE" 2>&1; then
        systemctl restart apache2 >> "$LOG_FILE" 2>&1
    else
        log_error "Error en la configuración de Apache2. Revise $LOG_FILE"
        return 1
    fi

    if systemctl is-active --quiet apache2; then
        log_ok "Apache2 SSL activo → https://$dominio:$puerto_ssl"
        return 0
    else
        log_error "Apache2 no pudo reiniciar con SSL."
        return 1
    fi
}

# ------------------------------------------------------------
# activar_ssl_nginx <dominio> [puerto_http]
# ------------------------------------------------------------
activar_ssl_nginx() {
    local dominio="$1"
    local puerto_http="${2:-80}"
    local puerto_ssl="${3:-443}"

    local crt="$DIR_SSL/$dominio.crt"
    local key="$DIR_SSL/$dominio.key"

    if ! dpkg -s nginx >/dev/null 2>&1; then
        log_error "Nginx no está instalado."
        return 1
    fi

    generar_cert_autofirmado "$dominio" || return 1

    chown root:www-data "$key"
    chmod 640 "$key"

    local conf_nginx="/etc/nginx/sites-available/default"
    
    # SNAPSHOT: Respaldo de seguridad (Idempotente)
    if [ -f "$conf_nginx" ] && [ ! -f "${conf_nginx}.bak_admin" ]; then
        cp "$conf_nginx" "${conf_nginx}.bak_admin"
        log_info "Snapshot de seguridad HTTP creado para Nginx."
    fi

    cat > "$conf_nginx" <<EOF
# P7 — Nginx SSL generado automáticamente
server {
    listen $puerto_ssl ssl default_server;
    listen [::]:$puerto_ssl ssl default_server;

    server_name $dominio www.$dominio;
    root /var/www/nginx;
    index index.html;

    ssl_certificate     $crt;
    ssl_certificate_key $key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # HSTS básico
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;

    server_tokens off;

    location / {
        try_files \$uri \$uri/ =404;
        limit_except GET POST { deny all; }
    }
}

# Redirección HTTP → HTTPS
server {
    listen $puerto_http default_server;
    listen [::]:$puerto_http default_server;
    server_name $dominio www.$dominio;
    
    # Redirige usando el puerto SSL dinámico si no es 443
    if (\$host = $dominio) {
        return 301 https://\$host:$puerto_ssl\$request_uri;
    }
    return 404;
}
EOF

    ufw allow "$puerto_ssl"/tcp >/dev/null 2>&1

    if nginx -t >> "$LOG_FILE" 2>&1; then
        systemctl restart nginx >> "$LOG_FILE" 2>&1
    else
        log_error "Error en configuración de Nginx. Revise $LOG_FILE"
        return 1
    fi

    if systemctl is-active --quiet nginx; then
        log_ok "Nginx SSL activo → https://$dominio:$puerto_ssl"
        return 0
    else
        log_error "Nginx no pudo reiniciar con SSL."
        return 1
    fi
}

# ------------------------------------------------------------
# activar_ssl_tomcat <dominio>
# Usa el Connector NIO2 con PEM directamente (sin keytool/JKS)
# ------------------------------------------------------------
activar_ssl_tomcat() {
    local dominio="$1"

    local crt="$DIR_SSL/$dominio.crt"
    local key="$DIR_SSL/$dominio.key"

    if [ ! -d /opt/tomcat ]; then
        log_error "Tomcat no está instalado en /opt/tomcat."
        return 1
    fi

    generar_cert_autofirmado "$dominio" || return 1

    # Tomcat lee el key como el usuario tomcat
    chown root:tomcat "$key"
    chmod 640 "$key"
    chown root:tomcat "$crt"
    chmod 644 "$crt"

    local server_xml="/opt/tomcat/conf/server.xml"

    # Idempotencia: solo agregar si el conector 8443 no existe
    if grep -q 'port="8443"' "$server_xml"; then
        log_info "Conector SSL (8443) ya existe en server.xml. Actualizando cert paths..."
        sed -i "s|certificateFile=\"[^\"]*\"|certificateFile=\"$crt\"|g" "$server_xml"
        sed -i "s|certificateKeyFile=\"[^\"]*\"|certificateKeyFile=\"$key\"|g" "$server_xml"
    else
        # Insertar el Connector HTTPS justo antes del cierre de </Service>
        sed -i "/<\/Service>/i\\
\\
    <!-- P7 — Conector HTTPS/SSL generado automáticamente -->\\
    <Connector port=\"8443\" protocol=\"org.apache.coyote.http11.Http11NioProtocol\"\\
               maxThreads=\"150\" SSLEnabled=\"true\">\\
        <SSLHostConfig hostName=\"_default_\">\\
            <Certificate certificateFile=\"$crt\"\\
                         certificateKeyFile=\"$key\"\\
                         type=\"RSA\" />\\
        </SSLHostConfig>\\
    </Connector>" "$server_xml"
    fi

    ufw allow 8443/tcp >/dev/null 2>&1
    systemctl restart tomcat >> "$LOG_FILE" 2>&1

    # Polling de arranque (Tomcat tarda)
    local contador=0
    while [ $contador -lt 15 ]; do
        sleep 2; ((contador++))
        if ss -tln | grep -qE ":8443\s"; then
            log_ok "Tomcat SSL activo → https://$dominio:8443"
            return 0
        fi
    done

    log_error "Tomcat no enlazó el puerto 8443 en el tiempo esperado."
    log_error "Revise: journalctl -xeu tomcat | tail -20"
    return 1
}

# ------------------------------------------------------------
# activar_ftps_vsftpd <dominio>
# Activa SSL/TLS explícito en vsftpd (FTPS sobre puerto 21)
# ------------------------------------------------------------
activar_ftps_vsftpd() {
    local dominio="$1"

    local crt="$DIR_SSL/$dominio.crt"
    local key="$DIR_SSL/$dominio.key"

    if ! dpkg -s vsftpd >/dev/null 2>&1; then
        log_error "vsftpd no está instalado."
        return 1
    fi

    generar_cert_autofirmado "$dominio" || return 1

    # vsftpd corre como root para leer el key
    chmod 600 "$key"
    chmod 644 "$crt"

    local conf="/etc/vsftpd.conf"

    # Función auxiliar de edición idempotente
    _vsftpd_set() {
        local param="$1" valor="$2"
        if grep -q "^${param}=" "$conf"; then
            sed -i "s|^${param}=.*|${param}=${valor}|" "$conf"
        elif grep -q "^#${param}=" "$conf"; then
            sed -i "s|^#${param}=.*|${param}=${valor}|" "$conf"
        else
            echo "${param}=${valor}" >> "$conf"
        fi
    }

    _vsftpd_set "ssl_enable"             "YES"
    _vsftpd_set "allow_anon_ssl"         "NO"
    _vsftpd_set "force_local_data_ssl"   "YES"
    _vsftpd_set "force_local_logins_ssl" "YES"
    _vsftpd_set "ssl_tlsv1_2"           "YES"
    _vsftpd_set "ssl_sslv2"             "NO"
    _vsftpd_set "ssl_sslv3"             "NO"
    _vsftpd_set "require_ssl_reuse"     "NO"
    _vsftpd_set "ssl_ciphers"           "HIGH"
    _vsftpd_set "rsa_cert_file"         "$crt"
    _vsftpd_set "rsa_private_key_file"  "$key"

    systemctl restart vsftpd >> "$LOG_FILE" 2>&1

    if systemctl is-active --quiet vsftpd; then
        log_ok "FTPS activo → ftps://$dominio:21 (SSL explícito)"
        return 0
    else
        log_error "vsftpd no pudo reiniciar con FTPS."
        log_error "Revise: journalctl -xeu vsftpd"
        return 1
    fi
}

# ------------------------------------------------------------
# verificar_ssl_servicio <nombre> <host:puerto> [starttls_proto]
# Retorna CN del cert si OK, "ERROR" si falla
# ------------------------------------------------------------
verificar_ssl_servicio() {
    local nombre="$1"
    local host_puerto="$2"
    local starttls="${3:-}"  # ej. "ftp" para FTPS

    local cmd_opts="-connect $host_puerto -servername ${host_puerto%%:*}"
    [ -n "$starttls" ] && cmd_opts="$cmd_opts -starttls $starttls"

    local cn
    cn=$(echo "" | timeout 5 openssl s_client $cmd_opts 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 | xargs)

    local expiry
    expiry=$(echo "" | timeout 5 openssl s_client $cmd_opts 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null \
        | sed 's/notAfter=//')

    if [ -n "$cn" ]; then
        printf "${VERDE}[OK]${RESET}    %-12s → %-30s CN=%-25s Expira: %s\n" \
            "$nombre" "$host_puerto" "$cn" "$expiry"
        return 0
    else
        printf "${ROJO}[ERROR]${RESET} %-12s → %-30s SSL no responde o no configurado\n" \
            "$nombre" "$host_puerto"
        return 1
    fi
}

# ------------------------------------------------------------
# resumen_ssl_linux
# Prueba todos los servicios SSL/TLS en el sistema Linux
# ------------------------------------------------------------
resumen_ssl_linux() {
    clear
    echo -e "${AMARILLO}=====================================================${RESET}"
    echo -e "${AMARILLO}       RESUMEN SSL/TLS — SERVIDORES LINUX            ${RESET}"
    echo -e "${AMARILLO}=====================================================${RESET}"
    echo ""
    printf "${AMARILLO}%-8s %-12s %-30s %-26s %s${RESET}\n" \
        "ESTADO" "SERVICIO" "ENDPOINT" "CN DEL CERTIFICADO" "EXPIRACIÓN"
    echo "-----------------------------------------------------------------------"

    local errores=0

    # Apache2 HTTPS
    if dpkg -s apache2 >/dev/null 2>&1 && systemctl is-active --quiet apache2; then
        verificar_ssl_servicio "Apache2" "localhost:443" || ((errores++))
    else
        printf "${AMARILLO}[SKIP]${RESET}  %-12s → No instalado o inactivo\n" "Apache2"
    fi

    # Nginx HTTPS
    if dpkg -s nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
        verificar_ssl_servicio "Nginx" "localhost:443" || ((errores++))
    else
        printf "${AMARILLO}[SKIP]${RESET}  %-12s → No instalado o inactivo\n" "Nginx"
    fi

    # Tomcat HTTPS
    if [ -d /opt/tomcat ] && systemctl is-active --quiet tomcat; then
        verificar_ssl_servicio "Tomcat" "localhost:8443" || ((errores++))
    else
        printf "${AMARILLO}[SKIP]${RESET}  %-12s → No instalado o inactivo\n" "Tomcat"
    fi

    # vsftpd FTPS (STARTTLS)
    if dpkg -s vsftpd >/dev/null 2>&1 && systemctl is-active --quiet vsftpd; then
        verificar_ssl_servicio "vsftpd" "localhost:21" "ftp" || ((errores++))
    else
        printf "${AMARILLO}[SKIP]${RESET}  %-12s → No instalado o inactivo\n" "vsftpd"
    fi

    echo ""
    echo "-----------------------------------------------------------------------"
    if [ $errores -eq 0 ]; then
        log_ok "Todos los servicios activos responden con SSL/TLS."
    else
        log_warning "$errores servicio(s) no responden correctamente por SSL."
    fi

    echo ""
    echo -e "${AZUL}Certificados en $DIR_SSL:${RESET}"
    ls -la "$DIR_SSL"/*.crt 2>/dev/null | awk '{print "  "$NF}' || echo "  Ninguno generado aún."

    pausa
}