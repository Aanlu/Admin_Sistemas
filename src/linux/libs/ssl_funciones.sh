#!/bin/bash
# ============================================================
# ssl_funciones.sh — PKI, SSL/TLS y auditoría final
# Llamado por: 07_ssl.sh (via source)
# Funciones exportadas:
#   activar_ssl_apache2, activar_ssl_nginx, activar_ssl_tomcat
#   activar_ftps_vsftpd, resumen_ssl_linux
# ============================================================

PKI_DIR="/etc/ssl/admin_sistemas"

# ============================================================
# INTERNA: Genera certificado autofirmado RSA-2048
# Retorna 0=OK, 1=fallo — el error BURBUJEA al orquestador
# ============================================================
_generar_cert_autofirmado() {
    local dominio="$1"
    local cert_path="$2"
    local key_path="$3"

    mkdir -p "$PKI_DIR"
    # CORRECCIÓN: 750 permite que servicios del grupo (tomcat, www-data)
    # puedan traversar el directorio sin exponer las claves a otros usuarios
    chmod 750 "$PKI_DIR"
    chown root:ssl-cert "$PKI_DIR" 2>/dev/null || chmod 755 "$PKI_DIR"

    echo -e "${CIAN}[PKI] Generando certificado X.509 autofirmado para: $dominio${RESET}"

    # -nodes     → sin passphrase (Apache/Nginx/Tomcat arrancan solos)
    # -subj      → evita el prompt interactivo (crítico dentro del loader)
    # CN=*.$dom  → wildcard cubre www.$dominio y subdominios
    if ! openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "$key_path" \
        -out    "$cert_path" \
        -subj   "/C=MX/ST=Sinaloa/L=Culiacan/O=Universidad/OU=Redes/CN=*.$dominio" \
        >> "$LOG_FILE" 2>&1; then

        log_error "[PKI] openssl falló al generar el certificado. Revise $LOG_FILE"
        return 1
    fi

    chmod 600 "$key_path"
    chmod 644 "$cert_path"
    log_ok "[PKI] Cert: $cert_path"
    log_ok "[PKI] Key:  $key_path"
    return 0
}

# ============================================================
# INTERNA: Resuelve la ruta base del proyecto
# Desde libs/ sube 3 niveles → admin_sistemas/
# ============================================================
_ruta_template() {
    local nombre_template="$1"
    local base
    base="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    echo "${base}/templates/linux/${nombre_template}"
}

# ============================================================
# SSL APACHE2
# Parámetros: dominio  puerto_http  puerto_ssl
# ============================================================
activar_ssl_apache2() {
    local dominio="$1"
    local puerto_http="${2:-80}"
    local puerto_ssl="${3:-443}"

    echo -e "\n${AMARILLO}=== SSL/TLS → APACHE2 | $dominio | HTTP:$puerto_http HTTPS:$puerto_ssl ===${RESET}"

    # 1. Verificar que apache2 esté instalado
    if ! dpkg -s apache2 >/dev/null 2>&1; then
        log_error "Apache2 no está instalado. Instálelo primero."
        return 1
    fi

    local cert_path="$PKI_DIR/apache2_${dominio}.crt"
    local key_path="$PKI_DIR/apache2_${dominio}.key"

    # 2. Generar certificado — si falla, abortamos (NO falso positivo)
    _generar_cert_autofirmado "$dominio" "$cert_path" "$key_path" || return 1

    # 3. Activar módulos requeridos
    echo -e "${CIAN}[*] Activando módulos: ssl, rewrite, headers...${RESET}"
    a2enmod ssl     >> "$LOG_FILE" 2>&1
    a2enmod rewrite >> "$LOG_FILE" 2>&1
    a2enmod headers >> "$LOG_FILE" 2>&1

        if ! grep -q "^ServerName" /etc/apache2/apache2.conf 2>/dev/null; then
        echo "ServerName $dominio" >> /etc/apache2/apache2.conf
    fi

# Añadir puerto SSL en ports.conf SOLO si no existe ya
    if ! grep -qE "^Listen\s+${puerto_ssl}(\s|$)" /etc/apache2/ports.conf 2>/dev/null; then
        echo "Listen $puerto_ssl" >> /etc/apache2/ports.conf
    fi

    # 5. Crear VirtualHost SSL (desde plantilla o inline)
    local vhost_file="/etc/apache2/sites-available/ssl_${dominio}.conf"
    local template
    template=$(_ruta_template "apache.ssl.template")

    if [ -f "$template" ]; then
        cp "$template" "$vhost_file"
        # Usar inyector seguro si está disponible (utils.sh), si no sed directo
        if declare -f _inyectar_template >/dev/null 2>&1; then
            _inyectar_template "$vhost_file" "@@DOMINIO@@"     "$dominio"
            _inyectar_template "$vhost_file" "@@PUERTO_SSL@@"  "$puerto_ssl"
            _inyectar_template "$vhost_file" "@@PUERTO_HTTP@@" "$puerto_http"
            _inyectar_template "$vhost_file" "@@CERT_PATH@@"   "$cert_path"
            _inyectar_template "$vhost_file" "@@KEY_PATH@@"    "$key_path"
        else
            sed -i "s|@@DOMINIO@@|$dominio|g"         "$vhost_file"
            sed -i "s|@@PUERTO_SSL@@|$puerto_ssl|g"   "$vhost_file"
            sed -i "s|@@PUERTO_HTTP@@|$puerto_http|g" "$vhost_file"
            sed -i "s|@@CERT_PATH@@|$cert_path|g"     "$vhost_file"
            sed -i "s|@@KEY_PATH@@|$key_path|g"       "$vhost_file"
        fi
    else
        # Fallback inline — plantilla no encontrada
        cat > "$vhost_file" <<EOF
<VirtualHost *:${puerto_ssl}>
    ServerName ${dominio}
    ServerAlias www.${dominio}
    DocumentRoot /var/www/apache2
    SSLEngine on
    SSLCertificateFile    ${cert_path}
    SSLCertificateKeyFile ${key_path}
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    <Directory /var/www/apache2>
        Options -Indexes -FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
<VirtualHost *:${puerto_http}>
    ServerName ${dominio}
    ServerAlias www.${dominio}
    RewriteEngine On
    RewriteRule ^(.*)$ https://${dominio}:${puerto_ssl}\$1 [R=301,L]
</VirtualHost>
EOF
    fi

    # 6. Activar sitio SSL y desactivar default HTTP
    a2ensite "ssl_${dominio}" >> "$LOG_FILE" 2>&1
    a2dissite 000-default     >> "$LOG_FILE" 2>&1

    # 7. Validar config ANTES de reiniciar (evita apagar Apache con config rota)
    if ! apache2ctl configtest >> "$LOG_FILE" 2>&1; then
        log_error "Configuración Apache inválida. No se reinició. Revise $LOG_FILE"
        return 1
    fi

    systemctl restart apache2 >> "$LOG_FILE" 2>&1
    ufw allow "$puerto_ssl"/tcp >> "$LOG_FILE" 2>&1

    log_ok "Apache2 SSL activo → https://${dominio}:${puerto_ssl}"
    return 0
}

# ============================================================
# SSL NGINX
# Parámetros: dominio  puerto_http  puerto_ssl
# ============================================================
activar_ssl_nginx() {
    local dominio="$1"
    local puerto_http="${2:-81}"
    local puerto_ssl="${3:-444}"

    echo -e "\n${AMARILLO}=== SSL/TLS → NGINX | $dominio | HTTP:$puerto_http HTTPS:$puerto_ssl ===${RESET}"

    if ! dpkg -s nginx >/dev/null 2>&1; then
        log_error "Nginx no está instalado. Instálelo primero."
        return 1
    fi

    local cert_path="$PKI_DIR/nginx_${dominio}.crt"
    local key_path="$PKI_DIR/nginx_${dominio}.key"

    _generar_cert_autofirmado "$dominio" "$cert_path" "$key_path" || return 1

    local nginx_conf="/etc/nginx/sites-available/ssl_${dominio}"
    local template
    template=$(_ruta_template "nginx.ssl.template")

    if [ -f "$template" ]; then
        cp "$template" "$nginx_conf"
        if declare -f _inyectar_template >/dev/null 2>&1; then
            _inyectar_template "$nginx_conf" "@@DOMINIO@@"     "$dominio"
            _inyectar_template "$nginx_conf" "@@PUERTO_SSL@@"  "$puerto_ssl"
            _inyectar_template "$nginx_conf" "@@PUERTO_HTTP@@" "$puerto_http"
            _inyectar_template "$nginx_conf" "@@CERT_PATH@@"   "$cert_path"
            _inyectar_template "$nginx_conf" "@@KEY_PATH@@"    "$key_path"
        else
            sed -i "s|@@DOMINIO@@|$dominio|g"         "$nginx_conf"
            sed -i "s|@@PUERTO_SSL@@|$puerto_ssl|g"   "$nginx_conf"
            sed -i "s|@@PUERTO_HTTP@@|$puerto_http|g" "$nginx_conf"
            sed -i "s|@@CERT_PATH@@|$cert_path|g"     "$nginx_conf"
            sed -i "s|@@KEY_PATH@@|$key_path|g"       "$nginx_conf"
        fi
    else
        cat > "$nginx_conf" <<EOF
server {
    listen ${puerto_ssl} ssl default_server;
    listen [::]:${puerto_ssl} ssl default_server;
    server_name ${dominio} www.${dominio};
    root /var/www/nginx;
    index index.html;
    ssl_certificate     ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
}
server {
    listen ${puerto_http} default_server;
    listen [::]:${puerto_http} default_server;
    server_name ${dominio} www.${dominio};
    return 301 https://\$host:${puerto_ssl}\$request_uri;
}
EOF
    fi

    # Deshabilitar default y activar el nuestro
    rm -f /etc/nginx/sites-enabled/default
    ln -sf "$nginx_conf" "/etc/nginx/sites-enabled/ssl_${dominio}"

    # Validar antes de reiniciar
    if ! nginx -t >> "$LOG_FILE" 2>&1; then
        log_error "Configuración Nginx inválida. No se reinició. Revise $LOG_FILE"
        return 1
    fi

    systemctl restart nginx >> "$LOG_FILE" 2>&1
    ufw allow "$puerto_ssl"/tcp >> "$LOG_FILE" 2>&1

    log_ok "Nginx SSL activo → https://${dominio}:${puerto_ssl}"
    return 0
}

# ============================================================
# SSL TOMCAT (PKCS12 + conector NIO en server.xml)
# Parámetros: dominio  [puerto_ssl=8443]
# El puerto HTTP lo lee del server.xml existente
# ============================================================
activar_ssl_tomcat() {
    local dominio="$1"
    local puerto_ssl="${2:-8443}"

    echo -e "\n${AMARILLO}=== SSL/TLS → TOMCAT | $dominio | HTTPS:$puerto_ssl ===${RESET}"

    if [ ! -d /opt/tomcat ]; then
        log_error "Tomcat no está instalado en /opt/tomcat"
        return 1
    fi

    local cert_pem="$PKI_DIR/tomcat_${dominio}.crt"
    local key_pem="$PKI_DIR/tomcat_${dominio}.key"
    local p12_path="$PKI_DIR/tomcat_${dominio}.p12"
    local p12_pass="tomcat_ssl_p7"

    # 1. Generar PEM
    _generar_cert_autofirmado "$dominio" "$cert_pem" "$key_pem" || return 1

    # 2. Convertir PEM → PKCS12 (formato nativo del conector NIO)
    echo -e "${CIAN}[*] Convirtiendo PEM → PKCS12 para conector NIO...${RESET}"
    if ! openssl pkcs12 -export \
        -in      "$cert_pem" \
        -inkey   "$key_pem" \
        -out     "$p12_path" \
        -name    "tomcat_ssl" \
        -passout "pass:$p12_pass" \
        >> "$LOG_FILE" 2>&1; then
        log_error "Fallo al generar PKCS12. Revise $LOG_FILE"
        return 1
    fi
    chown tomcat:tomcat "$p12_path"
    chmod 640 "$p12_path"
    # CORRECCIÓN: asegurar que tomcat puede entrar al directorio PKI
    chown root:tomcat "$PKI_DIR" 2>/dev/null || true
    chmod 750 "$PKI_DIR"

    # 3. Leer puerto HTTP actual del server.xml
    local server_xml="/opt/tomcat/conf/server.xml"
    local puerto_http_actual
    puerto_http_actual=$(grep -oP 'Connector port="\K[0-9]+' "$server_xml" 2>/dev/null \
        | grep -v "^8005$" | head -1)
    [ -z "$puerto_http_actual" ] && puerto_http_actual=8080

    # 4. Inyectar conector SSL en server.xml
    # Verificamos si ya existe un conector SSL para no duplicarlo
    if grep -q "SSLEnabled=\"true\"" "$server_xml" 2>/dev/null; then
        log_warning "Ya existe un conector SSL en server.xml. Reemplazando..."
        # Eliminar conector SSL anterior
        python3 - "$server_xml" <<'PYEOF' 2>/dev/null
import sys, re
with open(sys.argv[1], 'r') as f:
    content = f.read()
content = re.sub(
    r'<Connector[^>]+SSLEnabled="true".*?</Connector>',
    '', content, flags=re.DOTALL
)
with open(sys.argv[1], 'w') as f:
    f.write(content)
PYEOF
    fi

    # Insertar el nuevo conector SSL justo después del conector HTTP
    local template
    template=$(_ruta_template "server.xml.template")

    if [ -f "$template" ]; then
        # Leer el fragmento de conectores desde la plantilla y sustituir variables
        local fragmento
        fragmento=$(cat "$template")
        fragmento="${fragmento//@@PUERTO_HTTP@@/$puerto_http_actual}"
        fragmento="${fragmento//@@PUERTO_SSL@@/$puerto_ssl}"
        fragmento="${fragmento//@@CERT_PATH@@/$p12_path}"
        fragmento="${fragmento//@@KEY_PATH@@/$p12_pass}"

        # Reemplazar el conector HTTP existente con el par HTTP+SSL del template
        python3 - "$server_xml" "$puerto_http_actual" "$fragmento" <<'PYEOF' 2>/dev/null
import sys, re

server_xml = sys.argv[1]
puerto_http = sys.argv[2]
fragmento   = sys.argv[3]

with open(server_xml, 'r') as f:
    content = f.read()

# Eliminar el conector HTTP original
content = re.sub(
    r'<Connector\s+port="' + puerto_http + r'"[^/]*/?>',
    '',
    content
)

# Inyectar el par de conectores antes del cierre </Service>
content = content.replace('</Service>', fragmento + '\n</Service>', 1)

with open(server_xml, 'w') as f:
    f.write(content)
PYEOF
    else
        # Fallback inline — sin plantilla
        python3 - "$server_xml" "$puerto_http_actual" "$puerto_ssl" "$p12_path" "$p12_pass" <<'PYEOF' 2>/dev/null
import sys, re

server_xml    = sys.argv[1]
puerto_http   = sys.argv[2]
puerto_ssl    = sys.argv[3]
p12_path      = sys.argv[4]
p12_pass      = sys.argv[5]

with open(server_xml, 'r') as f:
    content = f.read()

# Eliminar conector HTTP original
content = re.sub(
    r'<Connector\s+port="' + puerto_http + r'"[^/]*/?>',
    '',
    content
)

nuevo = f"""
    <Connector port="{puerto_http}" protocol="HTTP/1.1"
               connectionTimeout="20000" redirectPort="{puerto_ssl}"
               server="Tomcat" />
    <Connector port="{puerto_ssl}"
               protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true" server="Tomcat">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="{p12_path}"
                         certificateKeystorePassword="{p12_pass}"
                         certificateKeystoreType="PKCS12"
                         type="RSA" />
        </SSLHostConfig>
    </Connector>"""

content = content.replace('</Service>', nuevo + '\n</Service>', 1)

with open(server_xml, 'w') as f:
    f.write(content)
PYEOF
    fi

    ufw allow "$puerto_ssl"/tcp >> "$LOG_FILE" 2>&1
    systemctl restart tomcat >> "$LOG_FILE" 2>&1

    log_ok "Tomcat SSL activo → https://${dominio}:${puerto_ssl}"
    return 0
}

# ============================================================
# FTPS en vsftpd
# Parámetros: dominio
# ============================================================
activar_ftps_vsftpd() {
    local dominio="$1"

    echo -e "\n${AMARILLO}=== FTPS → VSFTPD | $dominio ===${RESET}"

    if ! dpkg -s vsftpd >/dev/null 2>&1; then
        log_error "vsftpd no está instalado."
        return 1
    fi

    local cert_path="$PKI_DIR/vsftpd_${dominio}.crt"
    local key_path="$PKI_DIR/vsftpd_${dominio}.key"

    _generar_cert_autofirmado "$dominio" "$cert_path" "$key_path" || return 1

    local conf="/etc/vsftpd.conf"

    # Actualizar o agregar directivas SSL de forma idempotente
    _vsftpd_set() {
        local clave="$1" valor="$2"
        if grep -q "^${clave}=" "$conf" 2>/dev/null; then
            sed -i "s|^${clave}=.*|${clave}=${valor}|" "$conf"
        elif grep -q "^#${clave}=" "$conf" 2>/dev/null; then
            sed -i "s|^#${clave}=.*|${clave}=${valor}|" "$conf"
        else
            echo "${clave}=${valor}" >> "$conf"
        fi
    }

    _vsftpd_set "ssl_enable"              "YES"
    _vsftpd_set "allow_anon_ssl"          "NO"
    _vsftpd_set "force_local_data_ssl"    "YES"
    _vsftpd_set "force_local_logins_ssl"  "YES"
    _vsftpd_set "ssl_tlsv1"               "YES"
    _vsftpd_set "ssl_sslv2"               "NO"
    _vsftpd_set "ssl_sslv3"               "NO"
    _vsftpd_set "require_ssl_reuse"       "NO"
    _vsftpd_set "ssl_ciphers"             "HIGH"
    _vsftpd_set "rsa_cert_file"           "$cert_path"
    _vsftpd_set "rsa_private_key_file"    "$key_path"

    systemctl restart vsftpd >> "$LOG_FILE" 2>&1

    if systemctl is-active --quiet vsftpd; then
        log_ok "FTPS activado en vsftpd. Conectar con FTPES (TLS Explícito) al puerto 21."
        return 0
    else
        log_error "vsftpd no arrancó tras activar FTPS. Revise $LOG_FILE"
        return 1
    fi
}

# ============================================================
# AUDITORÍA FINAL: resumen_ssl_linux
# Lee estado.conf y verifica los puertos SSL con openssl s_client
# ============================================================
resumen_ssl_linux() {
    clear
    echo -e "${CIAN}=================================================${RESET}"
    echo -e "${AMARILLO}     RESUMEN SSL/TLS — INFRAESTRUCTURA P7        ${RESET}"
    echo -e "${CIAN}=================================================${RESET}\n"

    local dominio
    dominio=$(leer_estado "DOMINIO_SSL" 2>/dev/null)
    [ -z "$dominio" ] && dominio="${DOMINIO_SSL:-reprobados.com}"

    echo -e "${AZUL}Dominio PKI base: ${VERDE}$dominio${RESET}\n"

    printf "${AMARILLO}%-10s %-8s %-8s %-8s %-30s${RESET}\n" \
        "MOTOR" "P.HTTP" "P.SSL" "ACTIVO" "ESTADO CERTIFICADO"
    echo "-------------------------------------------------------------------"

    local motores=("APACHE2" "NGINX" "TOMCAT")

    for motor in "${motores[@]}"; do
        local p_http p_ssl ssl_activo estado_cert color

        p_http=$(leer_estado "PUERTO_HTTP_${motor}" 2>/dev/null)
        p_ssl=$(leer_estado "PUERTO_SSL_${motor}"   2>/dev/null)
        ssl_activo=$(leer_estado "SSL_ACTIVO_${motor}" 2>/dev/null)

        [ -z "$p_http" ]    && p_http="--"
        [ -z "$p_ssl" ]     && p_ssl="--"
        [ -z "$ssl_activo" ] && ssl_activo="--"

        if [ "$ssl_activo" == "SI" ] && [ "$p_ssl" != "--" ]; then
            # Verificación real con openssl s_client (timeout 3s)
            local resultado
            resultado=$(echo "Q" | timeout 3s openssl s_client \
                -connect "127.0.0.1:${p_ssl}" \
                -servername "$dominio" 2>&1)

            if echo "$resultado" | grep -q "CONNECTED"; then
                local fecha_exp
                fecha_exp=$(echo "$resultado" \
                    | grep "notAfter" | awk -F= '{print $2}')
                estado_cert="✔ VÁLIDO (exp: $fecha_exp)"
                color="$VERDE"
            else
                estado_cert="✖ NO RESPONDE (puerto $p_ssl)"
                color="$ROJO"
            fi
        elif [ "$ssl_activo" == "ERROR" ]; then
            estado_cert="⚠ FALLÓ AL CONFIGURAR"
            color="$ROJO"
        elif [ "$ssl_activo" == "NO" ]; then
            estado_cert="— Sin SSL (solo HTTP)"
            color="$AMARILLO"
        else
            estado_cert="— No configurado"
            color="$RESET"
        fi

        printf "${color}%-10s %-8s %-8s %-8s %-30s${RESET}\n" \
            "$motor" "$p_http" "$p_ssl" "$ssl_activo" "$estado_cert"
    done

    # FTPS
    echo ""
    printf "${AMARILLO}%-10s %-8s %-8s %-8s %-30s${RESET}\n" \
        "VSFTPD" "21" "21(TLS)" "--" "ESTADO FTPS"
    echo "-------------------------------------------------------------------"
    if grep -q "^ssl_enable=YES" /etc/vsftpd.conf 2>/dev/null; then
        printf "${VERDE}%-10s %-8s %-8s %-8s %-30s${RESET}\n" \
            "VSFTPD" "21" "21" "SI" "✔ FTPS (TLS Explícito) ACTIVO"
    else
        printf "${AMARILLO}%-10s %-8s %-8s %-8s %-30s${RESET}\n" \
            "VSFTPD" "21" "--" "NO" "— SSL no activado en vsftpd"
    fi

    echo -e "\n${AZUL}Certificados en $PKI_DIR:${RESET}"
    if [ -d "$PKI_DIR" ]; then
        ls -1 "$PKI_DIR" 2>/dev/null | while read -r f; do
            echo "  $f"
        done
    else
        echo "  (directorio vacío — ningún certificado generado aún)"
    fi

    echo ""
    pausa
}