#!/bin/bash

# Resolución de ruta absoluta: obtiene la carpeta actual (modulos)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Subimos un nivel (../) para salir de 'modulos' y luego entramos a 'libs'
source "$SCRIPT_DIR/../libs/utils.sh"
source "$SCRIPT_DIR/../libs/validaciones.sh"

DIR_FTP_MASTER="/var/ftp_master"
CONF_FTP="/etc/vsftpd.conf"
GRUPO_SELECCIONADO=""

gestionar_instalacion_ftp() {
    clear
    echo -e "${AMARILLO}--- 1. PREPARACIÓN BASE DEL SERVIDOR FTP (EN BLANCO) ---${RESET}"
    
    if dpkg -s vsftpd >/dev/null 2>&1; then
        log_ok "El servicio vsftpd ya está instalado en el sistema."
    else
        log_info "Instalando vsftpd silenciosamente..."
        instalar_dependencia_silenciosa "vsftpd"
    fi

    echo -e "\n${AZUL}[*] Configurando políticas de seguridad estrictas...${RESET}"
    
    [ ! -f "${CONF_FTP}.bak" ] && cp "$CONF_FTP" "${CONF_FTP}.bak"

    # Se agregó file_open_mode=0777 para que junto al umask 002, 
    # garantice permisos rwxrwxr-x y borrado cruzado perfecto.
    cat > "$CONF_FTP" <<EOF
listen=NO
listen_ipv6=YES
anonymous_enable=YES
local_enable=YES
write_enable=YES
local_umask=002
file_open_mode=0777
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
rsa_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
rsa_private_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
ssl_enable=NO
anon_root=$DIR_FTP_MASTER/general
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_world_readable_only=YES
pasv_min_port=40000
pasv_max_port=40100
EOF

    if ! grep -q "/usr/sbin/nologin" /etc/shells; then
        echo "/usr/sbin/nologin" >> /etc/shells
    fi

    echo -e "\n${AZUL}[*] Construyendo bóveda pública y grupos base...${RESET}"
    
    getent group ftp_auth >/dev/null || groupadd ftp_auth

    mkdir -p "$DIR_FTP_MASTER/general"

    chown root:ftp_auth "$DIR_FTP_MASTER/general"
    chmod 2775 "$DIR_FTP_MASTER/general"

    ufw allow 21/tcp >/dev/null 2>&1
    ufw allow 40000:40100/tcp >/dev/null 2>&1

    systemctl restart vsftpd
    log_ok "Entorno base FTP instalado. (0 Grupos, 0 Usuarios)."
    pausa
}

seleccionar_o_crear_grupo() {
    local arr_grupos=()
    GRUPO_SELECCIONADO=""
    
    if [ -d "$DIR_FTP_MASTER" ]; then
        for dir in "$DIR_FTP_MASTER"/*; do
            if [ -d "$dir" ]; then
                local nombre_carpeta=$(basename "$dir")
                [ "$nombre_carpeta" != "general" ] && arr_grupos+=("$nombre_carpeta")
            fi
        done
    fi

    arr_grupos+=("++ CREAR NUEVO GRUPO ++")
    generar_menu "SELECCIONE EL GRUPO PARA EL USUARIO" arr_grupos "Cancelar"
    local eleccion=$?

    if [ $eleccion -eq ${#arr_grupos[@]} ]; then
        return 1
    elif [ "${arr_grupos[$eleccion]}" == "++ CREAR NUEVO GRUPO ++" ]; then
        local nuevo_grupo=$(capturar_usuario_seguro "Escriba el nombre del nuevo grupo")
        if confirmar_accion "¿Crear el grupo '$nuevo_grupo' y su bóveda compartida?"; then
            
            if ! getent group "$nuevo_grupo" >/dev/null 2>&1; then
                groupadd "$nuevo_grupo"
            fi
            
            mkdir -p "$DIR_FTP_MASTER/$nuevo_grupo"
            chown root:"$nuevo_grupo" "$DIR_FTP_MASTER/$nuevo_grupo"
            
            # SOLUCION: 2775 asegura la travesía en vsftpd. 
            # El aislamiento lo da el chroot, no el permiso de la bóveda.
            chmod 2775 "$DIR_FTP_MASTER/$nuevo_grupo"
            
            GRUPO_SELECCIONADO="$nuevo_grupo"
            return 0
        else
            return 1
        fi
    else
        GRUPO_SELECCIONADO="${arr_grupos[$eleccion]}"
        return 0
    fi
}

procesar_usuario() {
    local usuario=$1
    local password=$2
    local grupo=$3
    local home_usr="/home/$usuario"

    if id "$usuario" &>/dev/null; then
        log_warning "El usuario '$usuario' ya existe. Verificando rol..."
        
        local grupo_actual=$(id -gn "$usuario")
        if [ "$grupo_actual" != "$grupo" ]; then
            echo -e "${CIAN}Migrando usuario de '$grupo_actual' a '$grupo'...${RESET}"
            
            # --- SOLUCIÓN DE AUDITORÍA: DESTRUCCIÓN DE CACHÉ Y SESIONES ACTIVAS ---
            # Matamos cualquier proceso FTP activo exclusivo de este usuario 
            # para obligar al cliente (FileZilla) a reconectarse y ver la nueva realidad NTFS/Linux.
            pkill -u "$usuario" vsftpd 2>/dev/null
            
            # Desmontaje perezoso (-l) para evitar cuelgues de "Target is Busy"
            if mountpoint -q "$home_usr/$grupo_actual"; then
                umount -l "$home_usr/$grupo_actual" 2>/dev/null
            fi
            [ -d "$home_usr/$grupo_actual" ] && rmdir "$home_usr/$grupo_actual" 2>/dev/null
            
            usermod -g "$grupo" -a -G ftp_auth "$usuario"
            
            mkdir -p "$home_usr/$grupo"
            mount --bind "$DIR_FTP_MASTER/$grupo" "$home_usr/$grupo"
            
            sed -i "\|/var/ftp_master/$grupo_actual $home_usr/$grupo_actual|d" /etc/fstab
            echo "/var/ftp_master/$grupo $home_usr/$grupo none bind 0 0" >> /etc/fstab
            systemctl daemon-reload >/dev/null 2>&1
            
            log_ok "Migración de grupo completada exitosamente."
        else
            log_info "Actualizando contraseña para el usuario '$usuario'..."
            echo "$usuario:$password" | chpasswd
        fi
    else
        echo -e "${CIAN}Desplegando nuevo usuario: $usuario ($grupo)...${RESET}"
        
        # SOLUCIÓN DE AUDITORÍA VISUAL: 
        # Se cambió -m por -M y se forzó el directorio con -d. 
        # Esto EVITA que Linux copie los archivos ocultos basura (.bashrc, .profile, etc)
        useradd -M -d "$home_usr" -s /usr/sbin/nologin -g "$grupo" -G ftp_auth "$usuario"
        echo "$usuario:$password" | chpasswd

        # Construcción manual y estéril de la jaula (chroot)
        mkdir -p "$home_usr"
        chown "$usuario":"$grupo" "$home_usr"
        chmod a-w "$home_usr"

        # Creación de los túneles y la carpeta privada con el nombre del usuario
        mkdir -p "$home_usr/$usuario"
        mkdir -p "$home_usr/general"
        mkdir -p "$home_usr/$grupo"

        chown "$usuario":"$grupo" "$home_usr/$usuario"

        mount --bind "$DIR_FTP_MASTER/general" "$home_usr/general"
        mount --bind "$DIR_FTP_MASTER/$grupo" "$home_usr/$grupo"

        if ! grep -q "$home_usr/general" /etc/fstab; then
            echo "/var/ftp_master/general $home_usr/general none bind 0 0" >> /etc/fstab
        fi
        if ! grep -q "$home_usr/$grupo" /etc/fstab; then
            echo "/var/ftp_master/$grupo $home_usr/$grupo none bind 0 0" >> /etc/fstab
        fi
        
        systemctl daemon-reload >/dev/null 2>&1
        log_ok "Estructura virtual montada correctamente."
    fi
}

gestionar_usuarios_ftp() {
    clear
    echo -e "${AMARILLO}--- 2. AUTOMATIZACIÓN MASIVA DE USUARIOS ---${RESET}"
    
    if ! dpkg -s vsftpd >/dev/null 2>&1 || [ ! -d "$DIR_FTP_MASTER/general" ]; then
        log_error "Debe preparar el entorno base FTP (Opción 1) antes de operar."
        pausa; return
    fi

    local n_users=$(capturar_entero "¿Cuántos usuarios desea registrar o modificar?")

    for (( usr_idx=1; usr_idx<=n_users; usr_idx++ )); do
        echo -e "\n${AMARILLO}--- Usuario $usr_idx de $n_users ---${RESET}"
        local nombre=$(capturar_usuario_seguro "Identificador del usuario")
        
        read -s -p "Contraseña para $nombre: " password
        echo ""
        
        seleccionar_o_crear_grupo
        if [ $? -eq 0 ]; then
            procesar_usuario "$nombre" "$password" "$GRUPO_SELECCIONADO"
        else
            log_warning "Configuración cancelada para el usuario $nombre."
        fi
    done
    pausa
}

eliminar_usuarios_ftp() {
    clear
    echo -e "${AMARILLO}--- 3. GESTIÓN DE ELIMINACIÓN DE USUARIOS ---${RESET}"
    
    local arr_users=($(awk -F: '$7 == "/usr/sbin/nologin" && $6 ~ "^/home/" {print $1}' /etc/passwd))
    
    if [ ${#arr_users[@]} -eq 0 ]; then
        log_warning "No existen usuarios FTP en el sistema."
        pausa; return
    fi

    local opciones=("Exterminar TODOS los usuarios" "Eliminar un usuario en específico")
    generar_menu "SELECCIONE UNA MODALIDAD" opciones "Cancelar"
    local eleccion=$?

    if [ $eleccion -eq 0 ]; then
        if confirmar_accion "¡PELIGRO! ¿Destruir TODOS los usuarios FTP y su información personal?"; then
            for usr in "${arr_users[@]}"; do
                for mnt in $(mount | grep "/home/$usr/" | awk '{print $3}'); do
                    umount -l "$mnt" 2>/dev/null
                done
                sed -i "\|/home/$usr/|d" /etc/fstab
                userdel -r "$usr" 2>/dev/null
            done
            systemctl daemon-reload >/dev/null 2>&1
            log_ok "Purga masiva de usuarios completada."
        fi
    elif [ $eleccion -eq 1 ]; then
        generar_menu "SELECCIONE EL USUARIO A DESTRUIR" arr_users "Cancelar"
        local usr_eleccion=$?
        if [ $usr_eleccion -ne ${#arr_users[@]} ]; then
            local usr_borrar="${arr_users[$usr_eleccion]}"
            if confirmar_accion "¿Eliminar al usuario '$usr_borrar' del sistema operativo?"; then
                for mnt in $(mount | grep "/home/$usr_borrar/" | awk '{print $3}'); do
                    umount -l "$mnt" 2>/dev/null
                done
                sed -i "\|/home/$usr_borrar/|d" /etc/fstab
                systemctl daemon-reload >/dev/null 2>&1
                userdel -r "$usr_borrar" 2>/dev/null
                log_ok "El usuario '$usr_borrar' dejó de existir."
            fi
        fi
    fi
    pausa
}

eliminar_grupo_ftp() {
    clear
    echo -e "${AMARILLO}--- 4. ELIMINAR GRUPO ESPECÍFICO ---${RESET}"
    
    local arr_grupos=()
    if [ -d "$DIR_FTP_MASTER" ]; then
        for dir in "$DIR_FTP_MASTER"/*; do
            if [ -d "$dir" ]; then
                local nombre_carpeta=$(basename "$dir")
                [ "$nombre_carpeta" != "general" ] && arr_grupos+=("$nombre_carpeta")
            fi
        done
    fi

    if [ ${#arr_grupos[@]} -eq 0 ]; then
        log_warning "No hay grupos personalizados para eliminar."
        pausa; return
    fi

    generar_menu "SELECCIONE EL GRUPO A DESTRUIR" arr_grupos "Cancelar"
    local eleccion=$?

    if [ $eleccion -ne ${#arr_grupos[@]} ]; then
        local grupo_borrar="${arr_grupos[$eleccion]}"
        if confirmar_accion "¡ATENCIÓN! ¿Eliminar '$grupo_borrar' y borrar sus archivos compartidos?"; then
            
            for mnt in $(mount | grep "$DIR_FTP_MASTER/$grupo_borrar" | awk '{print $3}'); do
                umount -l "$mnt" 2>/dev/null
            done
            
            sed -i "\|/var/ftp_master/$grupo_borrar|d" /etc/fstab
            systemctl daemon-reload >/dev/null 2>&1
            rm -rf "$DIR_FTP_MASTER/$grupo_borrar"
            groupdel "$grupo_borrar" >/dev/null 2>&1
            
            log_ok "La bóveda del grupo '$grupo_borrar' fue destruida."
        fi
    fi
    pausa
}

resetear_entorno_ftp() {
    clear
    echo -e "${ROJO}--- 5. DESTRUCCIÓN TOTAL DEL ENTORNO FTP (RESET) ---${RESET}"
    echo -e "Esta acción devolverá el servidor a estado de fábrica respecto al FTP."
    
    if confirmar_accion "¡PELIGRO EXTREMO! ¿Desea aniquilar Usuarios, Grupos, Bóveda y Configuraciones?"; then
        
        echo -e "${CIAN}Aniquilando usuarios FTP y sus rastros...${RESET}"
        local arr_users=($(awk -F: '$7 == "/usr/sbin/nologin" && $6 ~ "^/home/" {print $1}' /etc/passwd))
        for usr in "${arr_users[@]}"; do
            for mnt in $(mount | grep "/home/$usr/" | awk '{print $3}'); do
                umount -l "$mnt" 2>/dev/null
            done
            sed -i "\|/home/$usr/|d" /etc/fstab
            userdel -r "$usr" 2>/dev/null
        done

        echo -e "${CIAN}Desmontando túneles huérfanos y limpiando fstab...${RESET}"
        for mnt in $(mount | grep "ftp_master" | awk '{print $3}'); do
            umount -l "$mnt" 2>/dev/null
        done
        sed -i '/ftp_master/d' /etc/fstab
        systemctl daemon-reload >/dev/null 2>&1
        
        echo -e "${CIAN}Destruyendo grupos del sistema...${RESET}"
        if [ -d "$DIR_FTP_MASTER" ]; then
            for dir in "$DIR_FTP_MASTER"/*; do
                if [ -d "$dir" ]; then
                    local grp=$(basename "$dir")
                    [ "$grp" != "general" ] && groupdel "$grp" >/dev/null 2>&1
                fi
            done
        fi
        
        echo -e "${CIAN}Borrando bóveda maestra...${RESET}"
        rm -rf /var/ftp_master
        
        echo -e "${CIAN}Restaurando configuración original de vsftpd...${RESET}"
        if [ -f "/etc/vsftpd.conf.bak" ]; then
            cp "/etc/vsftpd.conf.bak" "/etc/vsftpd.conf"
        fi
        
        systemctl restart vsftpd 2>/dev/null
        log_ok "El entorno fue completamente purgado. Estás listo para un examen en blanco."
    else
        log_warning "Operación de reseteo abortada."
    fi
    pausa
}

alternar_ftp() {
    clear
    echo -e "${AMARILLO}--- CONTROL DE SERVICIO FTP ---${RESET}"
    if systemctl is-active --quiet vsftpd; then
        if confirmar_accion "¿Desea DESACTIVAR el servicio FTP?"; then
            systemctl stop vsftpd
            log_warning "Servicio FTP detenido."
        fi
    else
        if confirmar_accion "¿Desea ACTIVAR el servicio FTP?"; then
            systemctl start vsftpd
            log_ok "Servicio FTP iniciado."
        fi
    fi
    pausa
}

auditoria_ftp() {
    clear
    echo -e "${AMARILLO}--- AUDITORÍA VISUAL DEL SISTEMA ---${RESET}"
    
    echo -e "${AZUL}[ Usuarios FTP Activos en el Sistema Operativo ]${RESET}"
    awk -F: '$7 == "/usr/sbin/nologin" && $6 ~ "^/home/" {printf "Usuario: %-15s Grupo Ppal: %s\n", $1, $4}' /etc/passwd | while read line; do
        usr=$(echo $line | awk '{print $2}')
        grp_name=$(id -gn $usr 2>/dev/null)
        echo "Usuario: $usr | Rol Asignado: $grp_name"
    done
    [ $(awk -F: '$7 == "/usr/sbin/nologin" && $6 ~ "^/home/" {print $1}' /etc/passwd | wc -l) -eq 0 ] && echo "Ninguno."

    echo -e "\n${AZUL}[ Carpetas Maestras (Bóveda) ]${RESET}"
    ls -ld /var/ftp_master/* 2>/dev/null | awk '{print $1, $3, $4, $9}' || echo "La bóveda no existe."
    
    echo -e "\n${AZUL}[ Túneles Activos (Bind Mounts) ]${RESET}"
    mount | grep ftp_master | awk '{print $1 " -> " $3}' || echo "Sin túneles."
    
    echo -e "\n${AZUL}[ Estado en /etc/fstab ]${RESET}"
    grep "ftp_master" /etc/fstab || echo "Limpio."
    
    pausa
}

menu_ftp() {
    local opciones_ftp=(
        "Instalar / Preparar Bóveda (Base en Blanco)"
        "Gestionar Usuarios Masivos (Crear/Migrar)"
        "Gestionar Eliminación de Usuarios"
        "Eliminar Grupo Específico"
        "Destruir Entorno FTP (Reset Total para Examen)"
        "Alternar Estado del Servicio (Start/Stop)"
        "Auditoría Visual del Sistema"
    )
    
    while true; do
        local estado_actual="INACTIVO"
        systemctl is-active --quiet vsftpd && estado_actual="ACTIVO"
        
        generar_menu "MÓDULO DE GESTIÓN FTP [ $estado_actual ]" opciones_ftp "Volver al Menú Principal"
        local eleccion=$?
        
        case $eleccion in
            0) gestionar_instalacion_ftp ;;
            1) gestionar_usuarios_ftp ;;
            2) eliminar_usuarios_ftp ;;
            3) eliminar_grupo_ftp ;;
            4) resetear_entorno_ftp ;;
            5) alternar_ftp ;;
            6) auditoria_ftp ;;
            7) clear; break ;;
        esac
    done
}

menu_ftp