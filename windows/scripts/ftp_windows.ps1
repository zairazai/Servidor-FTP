# Detiene el script si ocurre un error no controlado
$ErrorActionPreference = "Stop"

# Rutas principales del servidor FTP
$FTP_ROOT         = "C:\FTP"                 # Carpeta raíz del FTP
$GENERAL_DIR      = "$FTP_ROOT\general"      # Carpeta pública
$REPROBADOS_DIR   = "$FTP_ROOT\reprobados"   # Carpeta grupo reprobados
$RECURSADORES_DIR = "$FTP_ROOT\recursadores" # Carpeta grupo recursadores
$USERS_DIR        = "$FTP_ROOT\usuarios"     # Carpeta de usuarios
$ANON_DIR         = "$FTP_ROOT\anon"         # Carpeta para acceso anónimo

# Datos del sitio FTP
$FTP_SITE_NAME = "FTP-Sistemas"
$FTP_PORT      = 21

# Grupos principales
$GROUP_REPROBADOS   = "reprobados"
$GROUP_RECURSADORES = "recursadores"
$GROUP_COMMON       = "ftpwriters"

# Funciones de mensajes

function Info($mensaje) {
    Write-Host "[INFO] $mensaje" -ForegroundColor Cyan
}

function Ok($mensaje) {
    Write-Host "[OK] $mensaje" -ForegroundColor Green
}

function Warn($mensaje) {
    Write-Host "[WARN] $mensaje" -ForegroundColor Yellow
}

# Validar ejecución como administrador
function Validar-Administrador {
    $actual = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($actual)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "[ERROR] Este script debe ejecutarse como Administrador." -ForegroundColor Red
        exit 1
    }

    Ok "El script se está ejecutando con privilegios de administrador."
}

# Verificar si una característica está instalada

function Esta-InstaladaCaracteristica($nombre) {
    $feature = Get-WindowsFeature -Name $nombre
    return $feature.Installed
}

# Instalar IIS y FTP
function Instalar-FTPWindows {
    Info "Verificando instalación de IIS y FTP..."

    $features = @("Web-Server","Web-Ftp-Server","Web-Ftp-Service","Web-Mgmt-Console")
    $faltantes = @()

    foreach ($feature in $features) {
        if (-not (Esta-InstaladaCaracteristica $feature)) {
            $faltantes += $feature
        }
    }

    if ($faltantes.Count -eq 0) {
        Ok "Las características necesarias ya están instaladas."
    }
    else {
        Info "Instalando características faltantes: $($faltantes -join ', ')"
        Install-WindowsFeature -Name $faltantes -IncludeManagementTools | Out-Null
        Ok "Características instaladas correctamente."
    }
}

# Verificar si un grupo local existe
function Existe-Grupo($nombreGrupo) {
    try {
        Get-LocalGroup -Name $nombreGrupo -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# Crear grupo local si no existe
function Verificar-Grupo($nombreGrupo) {
    if (Existe-Grupo $nombreGrupo) {
        Ok "El grupo '$nombreGrupo' ya existe."
    }
    else {
        New-LocalGroup -Name $nombreGrupo | Out-Null
        Ok "Grupo '$nombreGrupo' creado."
    }
}

# Crear grupos del sistema
function Crear-Grupos {
    Info "Verificando grupos del sistema..."
    Verificar-Grupo $GROUP_REPROBADOS
    Verificar-Grupo $GROUP_RECURSADORES
    Verificar-Grupo $GROUP_COMMON
}

# Verificar si una carpeta existe

function Verificar-Directorio($ruta) {
    if (Test-Path $ruta) {
        Ok "El directorio '$ruta' ya existe."
    }
    else {
        New-Item -ItemType Directory -Path $ruta -Force | Out-Null
        Ok "Directorio '$ruta' creado."
    }
}

# Crear estructura base de carpetas
function Crear-EstructuraBase {
    Info "Creando estructura base del servidor FTP..."

    Verificar-Directorio $FTP_ROOT
    Verificar-Directorio $GENERAL_DIR
    Verificar-Directorio $REPROBADOS_DIR
    Verificar-Directorio $RECURSADORES_DIR
    Verificar-Directorio $USERS_DIR
    Verificar-Directorio $ANON_DIR

    Ok "Estructura base lista."
}


# Aplicar permisos NTFS a las carpetas base
function Configurar-PermisosBase {
    Info "Configurando permisos NTFS base..."

    # Carpeta pública general
    icacls $GENERAL_DIR /inheritance:r       | Out-Null
    icacls $GENERAL_DIR /grant "Administrators:(OI)(CI)F" | Out-Null
    icacls $GENERAL_DIR /grant "IUSR:(OI)(CI)RX"          | Out-Null
    icacls $GENERAL_DIR /grant "${GROUP_COMMON}:(OI)(CI)M" | Out-Null

    # Carpeta del grupo reprobados
    icacls $REPROBADOS_DIR /inheritance:r            | Out-Null
    icacls $REPROBADOS_DIR /grant "Administrators:(OI)(CI)F" | Out-Null
    icacls $GENERAL_DIR /grant "${GROUP_COMMON}:(OI)(CI)M" | Out-Null

    # Carpeta del grupo recursadores
    icacls $RECURSADORES_DIR /inheritance:r              | Out-Null
    icacls $RECURSADORES_DIR /grant "Administrators:(OI)(CI)F" | Out-Null
    icacls $RECURSADORES_DIR /grant "${GROUP_RECURSADORES}:(OI)(CI)M" | Out-Null

    # Carpeta de usuarios (se deja cerrada por defecto)
    icacls $USERS_DIR /inheritance:r            | Out-Null
    icacls $USERS_DIR /grant "Administrators:(OI)(CI)F" | Out-Null

    # Carpeta raíz
    icacls $FTP_ROOT /grant "IUSR:(OI)(CI)(RX)" | Out-Null
    icacls $FTP_ROOT /grant "Users:(OI)(CI)(RX)" | Out-Null

    Ok "Permisos NTFS base aplicados."
}

# Verificar si un usuario local existe
function Existe-Usuario($nombreUsuario) {
    try {
        Get-LocalUser -Name $nombreUsuario -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# Agregar un usuario a un grupo si no pertenece todavía
function Agregar-AGrupoSiNoExiste($grupo, $usuario) {
    $miembros = Get-LocalGroupMember -Group $grupo -ErrorAction SilentlyContinue

    if ($miembros -and ($miembros.Name -match "\\$usuario$")) {
        Ok "El usuario '$usuario' ya pertenece al grupo '$grupo'."
    }
    else {
        Add-LocalGroupMember -Group $grupo -Member $usuario
        Ok "Usuario '$usuario' agregado al grupo '$grupo'."
    }
}

# Crear o actualizar usuario
function Gestionar-Usuario($username, $passwordPlano, $grupo) {
    Info "Procesando usuario '$username'..."

    $passwordSegura = ConvertTo-SecureString $passwordPlano -AsPlainText -Force
    $personalDir = "$USERS_DIR\$username"

    if (Existe-Usuario $username) {
        Warn "El usuario '$username' ya existe. Se actualizará."
        Set-LocalUser -Name $username -Password $passwordSegura
        Ok "Contraseña actualizada para '$username'."
    }
    else {
        New-LocalUser -Name $username -Password $passwordSegura -PasswordNeverExpires -AccountNeverExpires | Out-Null
        Ok "Usuario '$username' creado."
    }

    # Asignar grupos
    Agregar-AGrupoSiNoExiste $grupo $username
    Agregar-AGrupoSiNoExiste $GROUP_COMMON $username

    # Crear carpeta personal
    if (-not (Test-Path $personalDir)) {
        New-Item -ItemType Directory -Path $personalDir -Force | Out-Null
        Ok "Carpeta personal creada para '$username'."
    }
    else {
        Ok "La carpeta personal de '$username' ya existe."
    }

    # Permisos de carpeta personal
    icacls $personalDir /inheritance:r | Out-Null
    icacls $personalDir /grant "Administrators:(OI)(CI)F" | Out-Null
    icacls $personalDir /grant "${username}:(OI)(CI)M" | Out-Null

    Ok "Usuario '$username' configurado correctamente."
}

# Importar módulo de IIS
function Importar-WebAdministration {
    Import-Module WebAdministration
    Ok "Módulo WebAdministration cargado."
}

# Verificar si el sitio FTP ya existe

function Existe-SitioFTP($nombreSitio) {
    $sitio = Get-Website | Where-Object { $_.Name -eq $nombreSitio }
    return $null -ne $sitio
}

# Crear o actualizar sitio FTP

function Configurar-SitioFTP {
    Info "Configurando sitio FTP en IIS..."

    if (-not (Existe-SitioFTP $FTP_SITE_NAME)) {
        New-WebFtpSite -Name $FTP_SITE_NAME -Port $FTP_PORT -PhysicalPath $FTP_ROOT -Force | Out-Null
        Ok "Sitio FTP '$FTP_SITE_NAME' creado."
    }
    else {
        Ok "El sitio FTP '$FTP_SITE_NAME' ya existe."
    }

    # Iniciar sitio si no está activo
    $sitio = Get-Website -Name $FTP_SITE_NAME
    if ($sitio.State -ne "Started") {
        Start-Website -Name $FTP_SITE_NAME
        Ok "Sitio FTP iniciado."
    }
    else {
        Ok "El sitio FTP ya está en ejecución."
    }
}

# Configurar autenticación del sitio FTP

function Configurar-AutenticacionFTP {
    Info "Configurando autenticación FTP..."

    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter "system.applicationHost/sites/site[@name='$FTP_SITE_NAME']/ftpServer/security/authentication/anonymousAuthentication" `
        -Name enabled -Value True

    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter "system.applicationHost/sites/site[@name='$FTP_SITE_NAME']/ftpServer/security/authentication/basicAuthentication" `
        -Name enabled -Value True

    Ok "Autenticación anónima y básica habilitadas."
}

# Configurar SSL del sitio FTP

function Configurar-SSLFTP {
    Info "Configurando política SSL del sitio FTP..."

    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter "system.applicationHost/sites/site[@name='$FTP_SITE_NAME']/ftpServer/security/ssl" `
        -Name controlChannelPolicy -Value "SslAllow"

    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter "system.applicationHost/sites/site[@name='$FTP_SITE_NAME']/ftpServer/security/ssl" `
        -Name dataChannelPolicy -Value "SslAllow"

    Ok "Política SSL configurada en modo Allow."
}

# Configurar aislamiento de usuarios

function Configurar-UserIsolation {
    Info "Configurando FTP User Isolation..."

    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter "system.applicationHost/sites/site[@name='$FTP_SITE_NAME']/ftpServer/userIsolation" `
        -Name mode -Value "None"

    Ok "User Isolation configurado en modo None."
}

# Configurar reglas de autorización FTP, Se limpia y vuelve a crear reglas para evitar duplicados

function Configurar-AutorizacionFTP {
    Info "Configurando reglas de autorización FTP..."

    $configPath = "MACHINE/WEBROOT/APPHOST"
    $filterBase = "system.applicationHost/sites/site[@name='$FTP_SITE_NAME']/ftpServer/security/authorization"

    # Limpiar reglas previas si existen
    try {
        Clear-WebConfiguration -PSPath $configPath -Filter $filterBase -ErrorAction SilentlyContinue
    }
    catch {
        Warn "No se pudieron limpiar reglas previas automáticamente. Se continuará con la configuración."
    }

    # Agregar regla para anonymous (solo lectura)
    Add-WebConfiguration -PSPath $configPath -Filter $filterBase `
        -Value @{accessType='Allow';users='anonymous';permissions='Read'} | Out-Null

    # Agregar regla para ftpwriters (lectura y escritura)
    Add-WebConfiguration -PSPath $configPath -Filter $filterBase `
        -Value @{accessType='Allow';roles=$GROUP_COMMON;permissions='Read,Write'} | Out-Null

    Ok "Reglas de autorización FTP configuradas."
}

# Pedir número de usuarios

function Pedir-NumeroUsuarios {
    while ($true) {
        $cantidad = Read-Host "Número de usuarios"

        if ($cantidad -match '^\d+$' -and [int]$cantidad -gt 0) {
            return [int]$cantidad
        }
        else {
            Warn "Debes ingresar un número entero mayor que 0."
        }
    }
}


# Pedir grupo válido

function Pedir-Grupo {
    while ($true) {
        $grupo = Read-Host "Grupo (reprobados/recursadores)"

        if ($grupo -eq $GROUP_REPROBADOS -or $grupo -eq $GROUP_RECURSADORES) {
            return $grupo
        }
        else {
            Warn "Grupo inválido. Escribe 'reprobados' o 'recursadores'."
        }
    }
}


# Reiniciar IIS
function Reiniciar-IIS {
    Info "Reiniciando IIS..."
    iisreset | Out-Null
    Ok "IIS reiniciado correctamente."
}

# Función principal

function Main {
    Validar-Administrador
    Instalar-FTPWindows
    Crear-Grupos
    Crear-EstructuraBase
    Configurar-PermisosBase
    Importar-WebAdministration
    Configurar-SitioFTP
    Configurar-AutenticacionFTP
    Configurar-SSLFTP
    Configurar-UserIsolation
    Configurar-AutorizacionFTP

    $n = Pedir-NumeroUsuarios

    for ($i = 1; $i -le $n; $i++) {
        Write-Host "Usuario $i"
        $username = Read-Host "Nombre"
        $password = Read-Host "Password"
        $grupo = Pedir-Grupo

        Gestionar-Usuario $username $password $grupo
    }

    Reiniciar-IIS
    Ok "Configuración finalizada."
}

Main