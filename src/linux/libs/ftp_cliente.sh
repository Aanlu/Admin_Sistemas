#!/bin/bash
# ============================================================
# ftp_cliente.sh — Cliente FTP no-interactivo para P7
# Dependencias: curl, utils.sh, validaciones.sh
# ============================================================

# Globals de sesión FTP (se llenan en ftp_conectar)
FTP_IP=""
FTP_USER=""
FTP_PASS=""
FTP_REPO_BASE="http"   # ruta base en el servidor FTP

# ------------------------------------------------------------
# ftp_conectar
# Pide credenciales y verifica la conexión antes de continuar
# ------------------------------------------------------------
ftp_conectar() {
    clear
    echo -e "${AMARILLO}--- CONEXIÓN AL SERVIDOR FTP (PRÁCTICA 5) ---${RESET}"

    FTP_IP=$(capturar_ip "IP del servidor FTP")

    read -p "Usuario FTP: " FTP_USER
    [ -z "$FTP_USER" ] && { log_error "Usuario vacío."; return 1; }

    read -s -p "Contraseña FTP: " FTP_PASS
    echo ""
    [ -z "$FTP_PASS" ] && { log_error "Contraseña vacía."; return 1; }

    echo -e "${CIAN}[*] Verificando conexión a ftp://$FTP_IP ...${RESET}"
    if curl -s --connect-timeout 8 \
            "ftp://$FTP_IP/" \
            --user "$FTP_USER:$FTP_PASS" \
            --list-only >/dev/null 2>&1; then
        log_ok "Conexión al servidor FTP exitosa."
        return 0
    else
        log_error "No se pudo conectar al servidor FTP en $FTP_IP."
        log_error "Verifique que el servicio vsftpd esté activo (Módulo FTP)."
        FTP_IP=""; FTP_USER=""; FTP_PASS=""
        return 1
    fi
}

# ------------------------------------------------------------
# ftp_listar_directorio <ruta>
# Retorna línea por línea los nombres de archivos/carpetas
# ------------------------------------------------------------
ftp_listar_directorio() {
    local ruta="$1"
    curl -s --connect-timeout 10 \
         --list-only \
         "ftp://$FTP_IP/$ruta/" \
         --user "$FTP_USER:$FTP_PASS" 2>/dev/null \
    | grep -v "^$"
}

# ------------------------------------------------------------
# ftp_descargar_archivo <ruta_remota> <destino_local>
# Retorna 0 si OK, 1 si error
# ------------------------------------------------------------
ftp_descargar_archivo() {
    local ruta_remota="$1"
    local destino="$2"

    echo -e "${CIAN}[*] Descargando: $(basename "$ruta_remota")...${RESET}"

    curl -s --progress-bar --connect-timeout 30 \
         "ftp://$FTP_IP/$ruta_remota" \
         --user "$FTP_USER:$FTP_PASS" \
         -o "$destino" 2>&1

    if [ -f "$destino" ] && [ -s "$destino" ]; then
        log_ok "Descarga completada: $destino"
        return 0
    else
        log_error "Fallo en la descarga de $ruta_remota"
        rm -f "$destino"
        return 1
    fi
}

# ------------------------------------------------------------
# ftp_verificar_hash <archivo_local> <ruta_hash_remota>
# Descarga el .sha256 del FTP y verifica la integridad
# Retorna 0 si OK, 1 si hash incorrecto, 2 si no hay .sha256
# ------------------------------------------------------------
ftp_verificar_hash() {
    local archivo_local="$1"
    local ruta_hash_remota="$2"
    local archivo_hash="/tmp/$(basename "$archivo_local").sha256"

    echo -e "${CIAN}[*] Verificando integridad SHA256...${RESET}"

    # Intentar descargar el .sha256
    curl -s --connect-timeout 10 \
         "ftp://$FTP_IP/$ruta_hash_remota" \
         --user "$FTP_USER:$FTP_PASS" \
         -o "$archivo_hash" 2>/dev/null

    if [ ! -f "$archivo_hash" ] || [ ! -s "$archivo_hash" ]; then
        log_warning "No se encontró archivo .sha256 en el repositorio. Omitiendo verificación."
        rm -f "$archivo_hash"
        return 2
    fi

    local hash_remoto
    hash_remoto=$(awk '{print tolower($1)}' "$archivo_hash")
    local hash_local
    hash_local=$(sha256sum "$archivo_local" | awk '{print tolower($1)}')

    rm -f "$archivo_hash"

    if [ "$hash_remoto" == "$hash_local" ]; then
        log_ok "Integridad verificada — SHA256 coincide."
        log_ok "  Hash: $hash_local"
        return 0
    else
        log_error "¡INTEGRIDAD COMPROMETIDA! Los hashes NO coinciden."
        log_error "  Remoto : $hash_remoto"
        log_error "  Local  : $hash_local"
        log_error "El archivo puede haber sido corrompido durante la transferencia."
        rm -f "$archivo_local"
        return 1
    fi
}

# ------------------------------------------------------------
# ftp_navegar_y_descargar <motor>
# Navega dinámicamente la estructura /http/Linux/<Motor>/
# Muestra menú con archivos disponibles, descarga y verifica
# Imprime la ruta del archivo descargado en stdout
# Retorna 0 si OK, 1 si error o cancelación
# ------------------------------------------------------------
ftp_navegar_y_descargar() {
    local motor="$1"

    # Mapear nombre interno → nombre de carpeta en el FTP
    local dir_motor
    case "$motor" in
        apache2) dir_motor="Apache"  ;;
        nginx)   dir_motor="Nginx"   ;;
        tomcat)  dir_motor="Tomcat"  ;;
        *)       dir_motor="${motor^}" ;;
    esac

    local ruta_dir="$FTP_REPO_BASE/Linux/$dir_motor"

    echo -e "${AZUL}[*] Listando ftp://$FTP_IP/$ruta_dir/ ...${RESET}"

    # Obtener lista filtrando los .sha256 (solo mostramos los binarios)
    local archivos=()
    while IFS= read -r nombre; do
        [[ "$nombre" == *.sha256 ]] && continue
        [[ -n "$nombre" ]] && archivos+=("$nombre")
    done < <(ftp_listar_directorio "$ruta_dir")

    if [ ${#archivos[@]} -eq 0 ]; then
        log_error "No se encontraron instaladores en el repositorio para $dir_motor."
        log_error "Use 'Preparar Repositorio FTP' primero para poblar el repositorio."
        return 1
    fi

    generar_menu "SELECCIONE EL INSTALADOR [ftp://$FTP_IP/$ruta_dir/]" archivos "Cancelar"
    local eleccion=$?
    [ $eleccion -eq ${#archivos[@]} ] && return 1

    local archivo_sel="${archivos[$eleccion]}"
    local ruta_archivo="$ruta_dir/$archivo_sel"
    local destino="/tmp/$archivo_sel"

    # Si ya existe de una descarga anterior, preguntar
    if [ -f "$destino" ]; then
        if confirmar_accion "El archivo $archivo_sel ya existe en /tmp. ¿Volver a descargar?"; then
            rm -f "$destino"
        else
            echo "$destino"
            return 0
        fi
    fi

    ftp_descargar_archivo "$ruta_archivo" "$destino" || return 1

    ftp_verificar_hash "$destino" "${ruta_archivo}.sha256"
    local hash_result=$?

    # hash_result=1 → comprometido → ftp_verificar_hash ya borró el archivo
    [ $hash_result -eq 1 ] && return 1

    echo "$destino"
    return 0
}

# ------------------------------------------------------------
# ftp_instalar_binario <archivo_local> <motor>
# Instala el binario descargado según su extensión
# Retorna 0 si OK
# ------------------------------------------------------------
ftp_instalar_binario() {
    local archivo="$1"
    local motor="$2"
    local ext="${archivo##*.}"

    export DEBIAN_FRONTEND=noninteractive

    echo -e "${CIAN}[*] Instalando $motor desde $(basename "$archivo")...${RESET}"

    case "$ext" in
        deb)
            # Instalar .deb y resolver dependencias
            dpkg -i "$archivo" >> "$LOG_FILE" 2>&1
            apt-get install -f -yq >> "$LOG_FILE" 2>&1
            ;;
        gz | tgz)
            if [[ "$motor" == "tomcat" ]]; then
                # Mismo flujo que instalador_paquetes pero desde archivo local
                apt-get install -yq default-jdk >> "$LOG_FILE" 2>&1
                id -u tomcat >/dev/null 2>&1 || \
                    useradd -m -U -d /opt/tomcat -s /bin/false tomcat

                rm -rf /opt/tomcat/*
                mkdir -p /opt/tomcat

                # Verificar que es un gzip real
                if ! file "$archivo" | grep -q "gzip compressed"; then
                    log_error "El archivo no es un tar.gz válido: $archivo"
                    return 1
                fi

                tar -xf "$archivo" -C /opt/tomcat --strip-components=1 >> "$LOG_FILE" 2>&1
                chown -R tomcat:tomcat /opt/tomcat
                chmod -R u+x /opt/tomcat/bin

                # Crear servicio si no existe
                if [ ! -f /etc/systemd/system/tomcat.service ]; then
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
                fi
            else
                log_error "Extensión .tar.gz no soportada para $motor desde FTP."
                return 1
            fi
            ;;
        *)
            log_error "Extensión de archivo no reconocida: .$ext"
            return 1
            ;;
    esac

    log_ok "$motor instalado desde archivo local."
    return 0
}

# ------------------------------------------------------------
# ftp_preparar_repositorio
# Crea la estructura de directorios en /var/ftp_master/http/
# Descarga binarios desde APT/web y genera hashes SHA256
# ------------------------------------------------------------
ftp_preparar_repositorio() {
    clear
    echo -e "${AMARILLO}--- PREPARAR REPOSITORIO FTP ---${RESET}"
    echo -e "${AZUL}Directorio base: /var/ftp_master/http/${RESET}\n"

    if [ ! -d "/var/ftp_master" ]; then
        log_error "El directorio /var/ftp_master no existe."
        log_error "Ejecute primero 'Instalar / Preparar Bóveda FTP' (Módulo FTP)."
        pausa; return 1
    fi

    # Crear estructura de directorios
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

    # Descargar binarios Linux
    if confirmar_accion "¿Descargar instaladores Linux desde APT y generar hashes SHA256?"; then
        echo -e "\n${CIAN}[2/3] Descargando binarios Linux...${RESET}"
        export DEBIAN_FRONTEND=noninteractive
        local tmp_dir="/tmp/repo_prep"
        mkdir -p "$tmp_dir"

        # Apache2
        echo -e "  ${AZUL}→ Apache2...${RESET}"
        (cd "$tmp_dir" && apt-get download apache2 2>/dev/null)
        for f in "$tmp_dir"/apache2*.deb; do
            [ -f "$f" ] || continue
            mv "$f" "/var/ftp_master/http/Linux/Apache/"
            local dest="/var/ftp_master/http/Linux/Apache/$(basename "$f")"
            sha256sum "$dest" | awk '{print $1}' > "${dest}.sha256"
            log_ok "  apache2: $(basename "$f")"
        done

        # Nginx
        echo -e "  ${AZUL}→ Nginx...${RESET}"
        (cd "$tmp_dir" && apt-get download nginx 2>/dev/null)
        for f in "$tmp_dir"/nginx*.deb; do
            [ -f "$f" ] || continue
            mv "$f" "/var/ftp_master/http/Linux/Nginx/"
            local dest="/var/ftp_master/http/Linux/Nginx/$(basename "$f")"
            sha256sum "$dest" | awk '{print $1}' > "${dest}.sha256"
            log_ok "  nginx: $(basename "$f")"
        done

        # Tomcat — descargar tar.gz desde Apache mirrors
        echo -e "  ${AZUL}→ Tomcat (descargando última versión)...${RESET}"
        local tomcat_ver
        tomcat_ver=$(curl -s https://archive.apache.org/dist/tomcat/tomcat-10/ \
            | grep -oP 'v10\.[0-9]+\.[0-9]+' | sort -uV | tail -1 | sed 's/v//')

        if [ -n "$tomcat_ver" ]; then
            local tomcat_url="https://archive.apache.org/dist/tomcat/tomcat-10/v${tomcat_ver}/bin/apache-tomcat-${tomcat_ver}.tar.gz"
            local tomcat_dest="/var/ftp_master/http/Linux/Tomcat/apache-tomcat-${tomcat_ver}.tar.gz"
            if [ ! -f "$tomcat_dest" ]; then
                curl -f -s --progress-bar "$tomcat_url" -o "$tomcat_dest" 2>&1
                if file "$tomcat_dest" | grep -q "gzip compressed"; then
                    sha256sum "$tomcat_dest" | awk '{print $1}' > "${tomcat_dest}.sha256"
                    log_ok "  tomcat: apache-tomcat-${tomcat_ver}.tar.gz"
                else
                    rm -f "$tomcat_dest"
                    log_warning "  Tomcat: no se pudo descargar (requiere internet)"
                fi
            else
                log_info "  Tomcat: ya existe en el repositorio"
            fi
        fi

        rm -rf "$tmp_dir"
    fi

    echo -e "\n${CIAN}[3/3] Aplicando permisos finales...${RESET}"
    chown -R root:ftp_auth /var/ftp_master/http
    find /var/ftp_master/http -type d -exec chmod 2775 {} \;
    find /var/ftp_master/http -type f -exec chmod 664 {} \;

    echo -e "\n${AZUL}Contenido del repositorio:${RESET}"
    find /var/ftp_master/http -type f | sort | sed 's|/var/ftp_master/http/||' | \
        while read -r f; do echo "  $f"; done

    log_ok "Repositorio FTP listo."
    pausa
}