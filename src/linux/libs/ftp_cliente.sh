#!/bin/bash
# ============================================================
# ftp_cliente.sh — Cliente FTP no-interactivo para P7
# ============================================================

FTP_IP=""
FTP_USER=""
FTP_PASS=""
FTP_REPO_BASE="http"
FTP_MOTOR_DETECTADO=""
FTP_USA_TLS=false
FTP_ARCHIVO_DESCARGADO=""

ftp_conectar() {
    clear
    echo -e "${AMARILLO}--- CONEXIÓN AL SERVIDOR FTP (PRÁCTICA 5) ---${RESET}"

    local ip_default; ip_default=$(obtener_ip_local)
    [ -z "$ip_default" ] && ip_default="127.0.0.1"

    FTP_IP=$(capturar_ip "IP del servidor FTP" "$ip_default")

    read -p "Usuario FTP [Enter para Anónimo]: " FTP_USER
    [ -z "$FTP_USER" ] && FTP_USER="anonymous"

    if [ "$FTP_USER" == "anonymous" ]; then
        FTP_PASS="anon@localhost.local"
        log_info "Autenticando en modo Anónimo..."
    else
        read -s -p "Contraseña FTP: " FTP_PASS
        echo ""
        [ -z "$FTP_PASS" ] && { log_error "Contraseña vacía no permitida."; return 1; }
    fi

    echo -e "${CIAN}[*] Verificando conexión a ftp://$FTP_IP ...${RESET}"

    # Intentar primero sin TLS
    if curl -s --connect-timeout 8 --max-time 15 \
            --disable-epsv --ftp-pasv --ftp-skip-pasv-ip \
            "ftp://$FTP_IP/" --user "$FTP_USER:$FTP_PASS" \
            --list-only >/dev/null 2>&1; then
        FTP_USA_TLS=false
        log_ok "Conexión FTP exitosa (sin cifrar)."
        return 0
    fi

    # Si falla, intentar con TLS explícito (FTPES)
    if curl -s --connect-timeout 8 --max-time 15 \
            --disable-epsv --ftp-pasv --ftp-skip-pasv-ip \
            --ssl-reqd \
            --insecure \
            "ftp://$FTP_IP/" --user "$FTP_USER:$FTP_PASS" \
            --list-only >/dev/null 2>&1; then
        FTP_USA_TLS=true
        log_ok "Conexión FTPS exitosa (TLS explícito)."
        return 0
    fi

    log_error "No se pudo conectar al servidor FTP en $FTP_IP."
    FTP_IP=""; FTP_USER=""; FTP_PASS=""
    return 1
}

ftp_listar_directorio() {
    local ruta="$1"
    local tls_flags=""
    $FTP_USA_TLS && tls_flags="--ssl-reqd --insecure"

    curl -s \
        --connect-timeout 10 --max-time 20 \
        --disable-epsv --ftp-pasv --ftp-skip-pasv-ip \
        $tls_flags \
        --list-only \
        "ftp://$FTP_IP/$ruta/" \
        --user "$FTP_USER:$FTP_PASS" \
        2>/dev/null \
    | grep -v "^$"
}

ftp_descargar_archivo() {
    local ruta_remota="$1"
    local destino="$2"
    local nombre; nombre=$(basename "$ruta_remota")
    local tls_flags=""
    $FTP_USA_TLS && tls_flags="--ssl-reqd --insecure"

    echo -e "${CIAN}[*] Descargando: $nombre${RESET}"

    curl -s \
        --connect-timeout 30 --max-time 300 \
        --disable-epsv --ftp-pasv --ftp-skip-pasv-ip \
        $tls_flags \
        "ftp://$FTP_IP/$ruta_remota" \
        --user "$FTP_USER:$FTP_PASS" \
        -o "$destino" &
    local curl_pid=$!

    local tam_remoto=0
    local tam_str
    tam_str=$(curl -sI \
        --connect-timeout 5 \
        --disable-epsv --ftp-pasv --ftp-skip-pasv-ip \
        $tls_flags \
        "ftp://$FTP_IP/$ruta_remota" \
        --user "$FTP_USER:$FTP_PASS" \
        2>/dev/null \
        | grep -i "content-length" | awk '{print $2}' | tr -d '\r')
    [[ "$tam_str" =~ ^[0-9]+$ ]] && tam_remoto=$tam_str

    local ancho=35
    while kill -0 "$curl_pid" 2>/dev/null; do
        local bytes=0
        [ -f "$destino" ] && bytes=$(stat -c%s "$destino" 2>/dev/null || echo 0)
        bytes=${bytes:-0}
        if [ "$tam_remoto" -gt 0 ] 2>/dev/null; then
            local pct=$(( bytes * 100 / tam_remoto ))
            [ "$pct" -gt 100 ] && pct=100
            local rellenos=$(( pct * ancho / 100 ))
            local barra; barra=$(printf '%0.s█' $(seq 1 "$rellenos" 2>/dev/null))
            local hr; hr=$(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B")
            printf "\r  [%-${ancho}s] %3d%% %s  " "$barra" "$pct" "$hr"
        else
            local hr; hr=$(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B")
            printf "\r  ${CIAN}↓${RESET} Descargando... %-12s" "$hr"
        fi
        sleep 0.4
    done
    wait "$curl_pid"
    local exit_curl=$?
    printf "\n"

    if [ $exit_curl -ne 0 ] || [ ! -f "$destino" ] || [ ! -s "$destino" ]; then
        log_error "Fallo en la descarga de $nombre (curl exit: $exit_curl)"
        rm -f "$destino"; return 1
    fi

    local bytes_final; bytes_final=$(stat -c%s "$destino" 2>/dev/null || echo 0)
    if [ "$bytes_final" -lt 10240 ]; then
        log_error "Archivo demasiado pequeño ($bytes_final bytes)."
        rm -f "$destino"; return 1
    fi

    log_ok "Descarga completada: $nombre ($(numfmt --to=iec-i --suffix=B "$bytes_final" 2>/dev/null))"
    return 0
}

ftp_verificar_hash() {
    local archivo_local="$1"
    local ruta_hash_remota="$2"
    local nombre_archivo; nombre_archivo=$(basename "$archivo_local")
    local dir_local; dir_local=$(dirname "$archivo_local")
    local archivo_hash="${archivo_local}.sha256"

    echo -e "${CIAN}[*] Descargando checksum SHA256 del servidor...${RESET}"

    curl -s --connect-timeout 10 \
        --disable-epsv --ftp-pasv --ftp-skip-pasv-ip \
        "ftp://$FTP_IP/$ruta_hash_remota" \
        --user "$FTP_USER:$FTP_PASS" \
        -o "$archivo_hash" 2>/dev/null

    if [ ! -f "$archivo_hash" ] || [ ! -s "$archivo_hash" ]; then
        log_warning "No se encontró .sha256 en el servidor. Omitiendo verificación."
        rm -f "$archivo_hash"
        return 2
    fi

    local hash_remoto; hash_remoto=$(awk '{print tolower($1)}' "$archivo_hash")

    if [ -z "$hash_remoto" ] || [ ${#hash_remoto} -ne 64 ]; then
        log_error "Formato inválido en el archivo .sha256 del servidor."
        rm -f "$archivo_hash"
        return 1
    fi

    echo "$hash_remoto  $nombre_archivo" > "$archivo_hash"

    echo -e "${CIAN}[*] Verificando integridad con sha256sum -c ...${RESET}"
    local resultado
    resultado=$(cd "$dir_local" && sha256sum -c "$(basename "$archivo_hash")" 2>&1)
    local exit_check=$?
    rm -f "$archivo_hash"

    if [ $exit_check -eq 0 ]; then
        log_ok "Integridad verificada — sha256sum -c: PASSED"
        log_ok "  SHA256: $hash_remoto"
        return 0
    else
        log_error "¡INTEGRIDAD COMPROMETIDA! sha256sum -c: FAILED"
        log_error "  $resultado"
        rm -f "$archivo_local"
        return 1
    fi
}

ftp_navegar_y_descargar() {
    FTP_MOTOR_DETECTADO=""
    FTP_ARCHIVO_DESCARGADO=""
    local ruta_base="$FTP_REPO_BASE/Linux"

    # ── NIVEL 1: Selección de carpeta de servicio ──────────────
    while true; do
        echo -e "${AZUL}[*] Listando carpetas en ftp://$FTP_IP/$ruta_base/ ...${RESET}"

        local carpetas=()
        while IFS= read -r nombre; do
            [[ -n "$nombre" ]] && carpetas+=("$nombre")
        done < <(ftp_listar_directorio "$ruta_base")

        if [ ${#carpetas[@]} -eq 0 ]; then
            log_error "No se encontraron carpetas en $ruta_base."
            log_error "Ejecute 'Preparar Repositorio FTP' primero."
            return 1
        fi

        generar_menu "SERVICIO A INSTALAR [/$ruta_base/]" carpetas "Cancelar"
        local eleccion_carpeta=$?
        [ $eleccion_carpeta -eq ${#carpetas[@]} ] && return 1

        local carpeta_sel="${carpetas[$eleccion_carpeta]}"
        local ruta_dir="$ruta_base/$carpeta_sel"

        case "${carpeta_sel,,}" in
            apache|apache2) FTP_MOTOR_DETECTADO="apache2" ;;
            nginx)          FTP_MOTOR_DETECTADO="nginx"   ;;
            tomcat)         FTP_MOTOR_DETECTADO="tomcat"  ;;
            *)              FTP_MOTOR_DETECTADO="${carpeta_sel,,}" ;;
        esac

        # ── NIVEL 2: Selección de archivo ──────────────────────
        while true; do
            echo -e "${AZUL}[*] Listando instaladores en ftp://$FTP_IP/$ruta_dir/ ...${RESET}"

            local archivos=()
            local tiene_hash=false

            while IFS= read -r nombre; do
                if [[ "$nombre" == *.sha256 ]]; then
                    tiene_hash=true
                    continue
                fi
                [[ -n "$nombre" ]] && archivos+=("$nombre")
            done < <(ftp_listar_directorio "$ruta_dir")

            # Auto-poblar si vacío
            if [ ${#archivos[@]} -eq 0 ]; then
                log_warning "Repositorio vacío para $carpeta_sel."
                if curl -s --connect-timeout 3 "https://archive.apache.org" >/dev/null 2>&1; then
                    log_info "Descargando binarios automáticamente..."
                    _ftp_poblar_motor "$FTP_MOTOR_DETECTADO" "$ruta_dir"
                    archivos=()
                    tiene_hash=false
                    while IFS= read -r nombre; do
                        [[ "$nombre" == *.sha256 ]] && { tiene_hash=true; continue; }
                        [[ -n "$nombre" ]] && archivos+=("$nombre")
                    done < <(ftp_listar_directorio "$ruta_dir")
                fi

                if [ ${#archivos[@]} -eq 0 ]; then
                    log_error "El repositorio sigue vacío."
                    # Ofrecer volver al nivel 1
                    log_warning "Volviendo a selección de servicio..."
                    sleep 1
                    break  # Rompe nivel 2, vuelve al while de nivel 1
                fi
            fi

            $tiene_hash \
                && log_info "Checksums SHA256 disponibles." \
                || log_warning "Sin checksums — se omitirá verificación."

            # Agregar opción "← Volver" al array de archivos
            local archivos_con_volver=("${archivos[@]}" "← Volver a selección de servicio")

            generar_menu "INSTALADOR [/$ruta_dir/]" archivos_con_volver "Cancelar"
            local eleccion_archivo=$?

            # Cancelar total
            if [ $eleccion_archivo -eq ${#archivos_con_volver[@]} ]; then
                return 1
            fi

            # Volver al nivel 1
            if [ $eleccion_archivo -eq ${#archivos[@]} ]; then
                break  # Sale del while nivel 2, regresa al while nivel 1
            fi

            # Archivo seleccionado
            local archivo_sel="${archivos[$eleccion_archivo]}"
            local ruta_archivo="$ruta_dir/$archivo_sel"
            local destino="/tmp/$archivo_sel"

            if [ -f "$destino" ] && [ -s "$destino" ]; then
                if confirmar_accion "$archivo_sel ya existe en /tmp. ¿Volver a descargar?"; then
                    rm -f "$destino"
                else
                    FTP_ARCHIVO_DESCARGADO="$destino"
                    return 0
                fi
            fi

            ftp_descargar_archivo "$ruta_archivo" "$destino" || {
                log_error "Fallo en la descarga."
                continue  # Permite reintentar en el mismo nivel 2
            }

            if $tiene_hash; then
                ftp_verificar_hash "$destino" "${ruta_archivo}.sha256"
                [ $? -eq 1 ] && {
                    log_error "Hash inválido. Elige otro archivo."
                    continue
                }
            fi

            FTP_ARCHIVO_DESCARGADO="$destino"
            return 0

        done  # fin nivel 2
    done  # fin nivel 1
}

_ftp_poblar_motor() {
    local motor="$1"
    local ruta_relativa="$2"
    local dir_local="/var/ftp_master/$ruta_relativa"

    mkdir -p "$dir_local"
    chown root:ftp_auth "$dir_local" 2>/dev/null
    chmod 2775 "$dir_local"

    export DEBIAN_FRONTEND=noninteractive
    local ok=0

    case "$motor" in
        apache2|nginx)
            local ver=$(apt-cache show "$motor" 2>/dev/null \
                | grep "^Version:" | head -1 | awk '{print $2}' | cut -d'-' -f1)
            [ -z "$ver" ] && ver="latest"
            local bundle_name="${motor}_${ver}_offline_bundle.tar.gz"
            local bundle_dest="$dir_local/$bundle_name"

            if [ ! -f "$bundle_dest" ]; then
                local b_dir="/tmp/bundle_ftp_$motor"
                mkdir -p "$b_dir"
                local deps=$(apt-cache depends "$motor" 2>/dev/null \
                    | grep -E "Depends:|PreDepends:" | awk '{print $2}' | tr -d '<>')
                (cd "$b_dir" && apt-get download "$motor" $deps >/dev/null 2>&1)
                tar -czf "$bundle_dest" -C "$b_dir" . 2>/dev/null
                rm -rf "$b_dir"
                (cd "$dir_local" && sha256sum "$bundle_name") > "${bundle_dest}.sha256"
                log_ok "  Bundle offline creado: $bundle_name"
                ok=1
            else
                log_info "  $motor: Bundle offline ya existe."
                ok=1
            fi
            ;;
        tomcat)
            local tomcat_ver; tomcat_ver=$(curl -s \
                https://archive.apache.org/dist/tomcat/tomcat-10/ \
                | grep -oP 'v10\.[0-9]+\.[0-9]+' | sort -uV | tail -1 | sed 's/v//')
            if [ -n "$tomcat_ver" ]; then
                local nombre="apache-tomcat-${tomcat_ver}.tar.gz"
                local dest="$dir_local/$nombre"
                if [ ! -f "$dest" ]; then
                    local url="https://archive.apache.org/dist/tomcat/tomcat-10/v${tomcat_ver}/bin/${nombre}"
                    curl -f -# "$url" -o "$dest"
                    if file "$dest" 2>/dev/null | grep -q "gzip compressed"; then
                        (cd "$dir_local" && sha256sum "$nombre") > "${dest}.sha256"
                        log_ok "  Descargado: $nombre"
                        ok=1
                    else
                        rm -f "$dest"
                    fi
                else
                    ok=1
                fi
            fi
            ;;
    esac

    chown -R root:ftp_auth "$dir_local"
    find "$dir_local" -type f -exec chmod 664 {} \;
    return $(( 1 - ok ))
}

ftp_instalar_binario() {
    local archivo="$1"
    local motor="$2"
    local ext="${archivo##*.}"

    export DEBIAN_FRONTEND=noninteractive
    echo -e "${CIAN}[*] Instalando $motor desde $(basename "$archivo")...${RESET}"

    dpkg --configure -a >> "$LOG_FILE" 2>&1
    apt-get -f install -yq >> "$LOG_FILE" 2>&1

    if [ "$ext" == "deb" ]; then
        local arch_deb; arch_deb=$(dpkg --info "$archivo" 2>/dev/null \
            | grep "Architecture:" | awk '{print $2}')
        local arch_sys; arch_sys=$(dpkg --print-architecture)
        if [ -n "$arch_deb" ] && [ "$arch_deb" != "all" ] && \
           [ "$arch_deb" != "$arch_sys" ]; then
            log_error "Arquitectura incompatible: .deb=$arch_deb, sistema=$arch_sys."
            return 1
        fi
    fi

    case "$ext" in
        deb)
            dpkg -i "$archivo" >> "$LOG_FILE" 2>&1
            apt-get install -f -yq >> "$LOG_FILE" 2>&1
            ;;
        gz|tgz)
            if [ "$motor" == "tomcat" ]; then
                if ! java -version >/dev/null 2>&1; then
                    echo -e "${AMARILLO}[*] JDK no detectado. Instalando...${RESET}"
                    if curl -s --connect-timeout 3 "https://archive.apache.org" \
                            >/dev/null 2>&1; then
                        if ! apt-get install -yq default-jdk >> "$LOG_FILE" 2>&1; then
                            log_error "No se pudo instalar default-jdk."
                            return 1
                        fi
                    else
                        local jdk_deb
                        jdk_deb=$(find /var/ftp_master -maxdepth 4 \
                            \( -name "default-jdk*.deb" -o -name "openjdk*.deb" \) \
                            2>/dev/null | head -1)
                        if [ -n "$jdk_deb" ]; then
                            dpkg -i "$jdk_deb" >> "$LOG_FILE" 2>&1
                            apt-get install -f -yq >> "$LOG_FILE" 2>&1
                        else
                            log_error "Sin JDK y sin internet. Imposible instalar Tomcat."
                            return 1
                        fi
                    fi
                    if ! java -version >/dev/null 2>&1; then
                        log_error "JDK instalado pero 'java' no ejecutable."
                        return 1
                    fi
                fi

                id -u tomcat >/dev/null 2>&1 || \
                    useradd -m -U -d /opt/tomcat -s /bin/false tomcat

                if ! file "$archivo" | grep -q "gzip compressed"; then
                    log_error "El .tar.gz está corrupto."
                    return 1
                fi

                rm -rf /opt/tomcat/*
                mkdir -p /opt/tomcat
                tar -xf "$archivo" -C /opt/tomcat --strip-components=1 >> "$LOG_FILE" 2>&1
                chown -R tomcat:tomcat /opt/tomcat
                chmod -R u+x /opt/tomcat/bin

                if [ ! -f /etc/systemd/system/tomcat.service ]; then
                    cat > /etc/systemd/system/tomcat.service <<'EOF'
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
                    systemctl enable tomcat  >> "$LOG_FILE" 2>&1
                fi

            elif [[ "$archivo" == *"offline_bundle"* ]]; then
                echo -e "${CIAN}[*] Desempaquetando bundle offline...${RESET}"
                local tmp_extract; tmp_extract=$(mktemp -d)
                tar -xf "$archivo" -C "$tmp_extract"
                dpkg -i "$tmp_extract"/*.deb >> "$LOG_FILE" 2>&1
                apt-get install -f -yq      >> "$LOG_FILE" 2>&1
                rm -rf "$tmp_extract"
            else
                log_error "Extensión .tar.gz no reconocida para motor '$motor'."
                return 1
            fi
            ;;
        *)
            log_error "Extensión no reconocida: .$ext"
            return 1
            ;;
    esac

    log_ok "$motor instalado correctamente desde archivo local."
    return 0
}

ftp_preparar_repositorio() {
    clear
    echo -e "${AMARILLO}--- PREPARAR REPOSITORIO FTP ---${RESET}"
    echo -e "${AZUL}Directorio base: /var/ftp_master/http/${RESET}\n"

    if [ ! -d "/var/ftp_master" ]; then
        log_warning "/var/ftp_master no existe. Creando bóveda mínima..."
        mkdir -p /var/ftp_master/general
        getent group ftp_auth >/dev/null || groupadd ftp_auth
        chown root:ftp_auth /var/ftp_master/general
        chmod 2775 /var/ftp_master/general
    fi

    local dirs=(
        "/var/ftp_master/http/Linux/Apache"
        "/var/ftp_master/http/Linux/Nginx"
        "/var/ftp_master/http/Linux/Tomcat"
        "/var/ftp_master/http/Windows/IIS"
        "/var/ftp_master/http/Windows/Apache"
        "/var/ftp_master/http/Windows/Nginx"
    )

    echo -e "${CIAN}[1/3] Creando estructura de directorios...${RESET}"
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        chown root:ftp_auth "$dir" 2>/dev/null
        chmod 2775 "$dir"
    done
    log_ok "Estructura creada."

    if confirmar_accion "¿Descargar instaladores Linux (APT + Apache mirrors) y generar SHA256?"; then
        echo -e "\n${CIAN}[2/3] Descargando binarios Linux...${RESET}"
        export DEBIAN_FRONTEND=noninteractive

        for motor in apache2 nginx; do
            local carpeta="Apache"
            [ "$motor" == "nginx" ] && carpeta="Nginx"
            local dir_dest="/var/ftp_master/http/Linux/$carpeta"
            echo -e "  ${AZUL}→ $carpeta (LTS + Latest)...${RESET}"

            local tmp_dir; tmp_dir=$(mktemp -d)
            local ver_lts; ver_lts=$(apt-cache policy "$motor" 2>/dev/null \
                | grep -B1 "500 http://.*ubuntu.* main" | head -1 | awk '{print $1}')
            local ver_latest; ver_latest=$(apt-cache madison "$motor" 2>/dev/null \
                | awk '{print $3}' | head -1)
            [ -z "$ver_lts" ] && ver_lts="$ver_latest"

            for ver in "$ver_lts" "$ver_latest"; do
                [ -z "$ver" ] && continue
                (cd "$tmp_dir" && apt-get download "${motor}=${ver}" 2>/dev/null)
                local f; f=$(ls "$tmp_dir"/${motor}*.deb 2>/dev/null | head -1)
                if [ -n "$f" ]; then
                    local nombre; nombre=$(basename "$f")
                    local dest="$dir_dest/$nombre"
                    if [ -f "$dest" ]; then
                        rm -f "$f"
                        log_info "  Ya existe: $nombre"
                        continue
                    fi
                    mv "$f" "$dest"
                    (cd "$dir_dest" && sha256sum "$nombre") > "${dest}.sha256"
                    log_ok "  $carpeta: $nombre"
                fi
            done
            rm -rf "$tmp_dir"
        done

        echo -e "  ${AZUL}→ Tomcat (Latest)...${RESET}"
        local tomcat_ver; tomcat_ver=$(curl -s \
            https://archive.apache.org/dist/tomcat/tomcat-10/ \
            | grep -oP 'v10\.[0-9]+\.[0-9]+' | sort -uV | tail -1 | sed 's/v//')

        if [ -n "$tomcat_ver" ]; then
            local nombre="apache-tomcat-${tomcat_ver}.tar.gz"
            local dest="/var/ftp_master/http/Linux/Tomcat/$nombre"
            if [ ! -f "$dest" ]; then
                local url="https://archive.apache.org/dist/tomcat/tomcat-10/v${tomcat_ver}/bin/${nombre}"
                curl -f -s --progress-bar "$url" -o "$dest" 2>&1
                if file "$dest" 2>/dev/null | grep -q "gzip compressed"; then
                    (cd /var/ftp_master/http/Linux/Tomcat && sha256sum "$nombre") > "${dest}.sha256"
                    log_ok "  Tomcat: $nombre"
                else
                    rm -f "$dest"
                    log_warning "  Tomcat: no se pudo descargar"
                fi
            else
                log_info "  Tomcat: ya existe en el repositorio"
            fi
        fi
    fi

    echo -e "\n${CIAN}[3/3] Aplicando permisos finales...${RESET}"
    chown -R root:ftp_auth /var/ftp_master/http
    find /var/ftp_master/http -type d -exec chmod 2775 {} \;
    find /var/ftp_master/http -type f -exec chmod 664 {} \;

    echo -e "\n${AZUL}Contenido del repositorio:${RESET}"
    find /var/ftp_master/http -type f | sort \
        | sed 's|/var/ftp_master/http/||' \
        | while read -r f; do echo "  $f"; done

    log_ok "Repositorio FTP listo con checksums SHA256."
    pausa
}