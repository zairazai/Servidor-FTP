#!/bin/bash

set -e  # Detiene el script si hay error

# rutas principales del servidor FTP
FTP_ROOT="/srv/ftp"                    # Carpeta raíz del FTP
GENERAL_DIR="$FTP_ROOT/general"        # Carpeta pública
REPROBADOS_DIR="$FTP_ROOT/reprobados"  # Carpeta grupo reprobados
RECURSADORES_DIR="$FTP_ROOT/recursadores" # Carpeta grupo recursadores
USERS_DIR="$FTP_ROOT/usuarios"         # Carpeta donde estan los usuarios
HOMEVIEWS_DIR="$FTP_ROOT/homeviews"    # Carpeta de vistas FTP

# Archivos de config
VSFTPD_CONF="/etc/vsftpd.conf"
VSFTPD_BACKUP="/etc/vsftpd.conf.bak"

GROUP_REPROBADOS="reprobados"
GROUP_RECURSADORES="recursadores"
GROUP_COMMON="ftpwriters"  # Grupo para escritura en general

# funcion de msjs
info() {
    echo "[INFO] $1"
}

ok() {
    echo "[OK] $1"
}

warn() {
    echo "[WARN] $1"
}

# Validar que se ejecute como admin el script
validacion_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "[ERROR] Este script debe ejecutarse como root."
        exit 1
    fi
}

# Verificar si un paquete está instalado
esta_instalado() {
    dpkg -s "$1" >/dev/null 2>&1
}

# Instalación y verificación de vsftpd
instalar_vsftpd() {
    info "Verificando vsftpd..."

    if esta_instalado vsftpd; then
        ok "vsftpd ya está instalado."
    else
        info "Instalando vsftpd..."
        apt update
        apt install -y vsftpd
        ok "vsftpd instalado."
    fi

    # estatus del servicio
    if systemctl is-enabled vsftpd >/dev/null 2>&1; then
        ok "Servicio habilitado."
    else
        systemctl enable vsftpd
        ok "Servicio habilitado ahora."
    fi

    # Verifica si esta en running
    if systemctl is-active vsftpd >/dev/null 2>&1; then
        ok "Servicio en ejecución."
    else
        systemctl start vsftpd
        ok "Servicio iniciado."
    fi
}

# Crear grupos si no existen
verificar_grupo() {
    if getent group "$1" >/dev/null 2>&1; then
        ok "Grupo $1 ya existe."
    else
        groupadd "$1"
        ok "Grupo $1 creado."
    fi
}

crear_grupos() {
    info "Verificando grupos..."
    verificar_grupo "$GROUP_REPROBADOS"
    verificar_grupo "$GROUP_RECURSADORES"
    verificar_grupo "$GROUP_COMMON"
}

# Crear directorios base
verificar_directorio() {
    if [ -d "$1" ]; then
        ok "Directorio $1 ya existe."
    else
        mkdir -p "$1"
        ok "Directorio $1 creado."
    fi
}

crear_estructura_base() {
    info "Creando estructura base..."

    verificar_directorio "$GENERAL_DIR"
    verificar_directorio "$REPROBADOS_DIR"
    verificar_directorio "$RECURSADORES_DIR"
    verificar_directorio "$USERS_DIR"
    verificar_directorio "$HOMEVIEWS_DIR"

    # Permisos importantes
    chmod 755 /srv
    chmod 755 "$FTP_ROOT"
    chmod 755 "$HOMEVIEWS_DIR"

    # Permisos de carpetas
    chown root:"$GROUP_COMMON" "$GENERAL_DIR"
    chmod 775 "$GENERAL_DIR"

    chown root:"$GROUP_REPROBADOS" "$REPROBADOS_DIR"
    chmod 770 "$REPROBADOS_DIR"

    chown root:"$GROUP_RECURSADORES" "$RECURSADORES_DIR"
    chmod 770 "$RECURSADORES_DIR"

    ok "Estructura base lista."
}

# Configuración de vsftpd
configurar_vsftpd() {
    info "Configurando vsftpd..."

    # Crear backup solo una vez
    if [ -f "$VSFTPD_BACKUP" ]; then
        ok "El respaldo ya existe."
    else
        info "Creando respaldo de vsftpd.conf..."
        cp "$VSFTPD_CONF" "$VSFTPD_BACKUP"
        ok "Backup creado."
    fi

    # Sobrescribir configuración
    cat > "$VSFTPD_CONF" <<EOF
listen=YES
listen_ipv6=NO

anonymous_enable=YES
local_enable=YES
write_enable=YES

anon_root=/srv/ftp/general
anon_upload_enable=NO
anon_mkdir_write_enable=NO

chroot_local_user=YES
allow_writeable_chroot=YES
EOF

    # Reiniciar servicio para aplicar cambios
    systemctl restart vsftpd

    ok "vsftpd configurado correctamente."
}

# Limpiar montajes anteriores del usuario
limpiar_montajes() {
    local username="$1"
    local path="$HOMEVIEWS_DIR/$username"

    for dir in general "$GROUP_REPROBADOS" "$GROUP_RECURSADORES" "$username"; do
        if mountpoint -q "$path/$dir"; then
            umount "$path/$dir"
        fi
    done
}

# Crear o actualizar usuario
gestionar_usuario() {

    local username="$1"
    local password="$2"
    local group="$3"

    local personal_dir="$USERS_DIR/$username"
    local view_dir="$HOMEVIEWS_DIR/$username"

    info "Configurando usuario $username..."

    if id "$username" >/dev/null 2>&1; then
        warn "Usuario ya existe, se actualizará."
    else
        useradd -m "$username"
        ok "Usuario creado."
    fi

    # Actualiza contraseña
    echo "$username:$password" | chpasswd

    # Asignación de grupos
    usermod -G "$group","$GROUP_COMMON" "$username"

    # Carpeta personal del usuario
    mkdir -p "$personal_dir"
    chown "$username:$username" "$personal_dir"
    chmod 700 "$personal_dir"

    # Vista FTP del usuario
    mkdir -p "$view_dir"
    chmod 755 "$view_dir"
    chown root:root "$view_dir"

    # Limpia montajes y estructura anterior
    limpiar_montajes "$username"

    rm -rf "$view_dir/general" \
           "$view_dir/$GROUP_REPROBADOS" \
           "$view_dir/$GROUP_RECURSADORES" \
           "$view_dir/$username"

    # Crea directorios visibles en la raíz del FTP del usuario
    mkdir -p "$view_dir/general"
    mkdir -p "$view_dir/$group"
    mkdir -p "$view_dir/$username"

    # Aplica bind mounts
    info "Aplicando bind mounts para $username..."

    mount --bind "$GENERAL_DIR" "$view_dir/general"

    if [ "$group" = "$GROUP_REPROBADOS" ]; then
        mount --bind "$REPROBADOS_DIR" "$view_dir/$GROUP_REPROBADOS"
    else
        mount --bind "$RECURSADORES_DIR" "$view_dir/$GROUP_RECURSADORES"
    fi

    mount --bind "$personal_dir" "$view_dir/$username"

    # Cambia el home del usuario para que entre directo a su vista FTP
    usermod -d "$view_dir" "$username"

    ok "Usuario configurado completamente."
}

# funcion para pedir num usuarios
pedir_numero_usuarios() {
    local cantidad=""

    while true; do
        read -rp "Número de usuarios: " cantidad

        if [[ "$cantidad" =~ ^[0-9]+$ ]] && [ "$cantidad" -gt 0 ]; then
            echo "$cantidad"
            return
        else
            warn "Debes ingresar un número entero mayor que 0."
        fi
    done
}

# funcion para pedir grupo
pedir_grupo() {
    local grupo=""

    while true; do
        read -rp "Grupo (reprobados/recursadores): " grupo

        if [ "$grupo" = "$GROUP_REPROBADOS" ] || [ "$grupo" = "$GROUP_RECURSADORES" ]; then
            echo "$grupo"
            return
        else
            warn "Grupo inválido. Escribe 'reprobados' o 'recursadores'."
        fi
    done
}

main() {
    local n
    local username
    local password
    local group
    local i

    validacion_root
    instalar_vsftpd
    crear_grupos
    crear_estructura_base
    configurar_vsftpd

    n=$(pedir_numero_usuarios)

    for ((i=1; i<=n; i++)); do
        echo "Usuario $i"
        read -rp "Nombre: " username
        read -rsp "Password: " password
        echo
        group=$(pedir_grupo)

        gestionar_usuario "$username" "$password" "$group"
    done

    systemctl restart vsftpd
    ok "Configuración finalizada."
}

main
