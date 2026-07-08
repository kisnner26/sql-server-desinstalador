#!/usr/bin/env bash
# =============================================================================
#  SQL Server Complete Removal Utility  (Linux)
#  Elimina TODO rastro de SQL Server: servicio, paquetes, datos, temporales,
#  repositorios, usuario del sistema y variables de entorno.
#  Deja el sistema listo para una reinstalacion limpia desde cero.
#
#  Incluye asistente grafico previo a la desinstalacion (pantallas de
#  bienvenida, terminos y condiciones, deteccion, confirmacion y progreso):
#    - Si hay entorno grafico y "zenity" disponible -> asistente en ventanas.
#    - Si no, pero hay "whiptail"/"dialog"          -> asistente en modo texto.
#    - Si no hay ninguno                             -> flujo de texto plano.
#
#  Desarrollado por: Kisnner Obando
#  Uso legitimo: limpieza de tu propio servidor / equipos que administras.
#  NO es un producto oficial de Microsoft. SQL Server y SSMS son marcas
#  registradas de Microsoft Corporation, mencionadas aqui solo de forma
#  descriptiva.
# =============================================================================
#  USO:
#    sudo ./uninstall-sqlserver.sh                # asistente (grafico o texto, auto-detectado)
#    sudo ./uninstall-sqlserver.sh --cli          # fuerza el flujo de texto plano (automatizable)
#    sudo ./uninstall-sqlserver.sh --cli --dry-run    # simulacion en modo texto plano
#    sudo ./uninstall-sqlserver.sh --cli --force      # sin preguntar (automatizacion)
#    sudo ./uninstall-sqlserver.sh --cli --keep-data  # rescata datos antes de borrar
# =============================================================================

set -uo pipefail
shopt -s lastpipe 2>/dev/null || true

# ------------------------------------------------------------------ variables
DRY_RUN=0
FORCE=0
KEEP_DATA=0
FORCE_CLI=0
UI_MODE=""
TUI_BIN=""
LOG_FILE="/tmp/sqlserver_removal_$(date +%Y%m%d_%H%M%S).log"
REMOVED=0
FAILED=0
PKG=""

C_RESET='\033[0m'; C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_GRAY='\033[0;90m'

# Listas de referencia (compartidas por el escaneo y la eliminacion real)
PACKAGES=(
    mssql-server mssql-server-ha mssql-server-agent mssql-server-fts
    mssql-server-polybase mssql-server-polybase-hadoop mssql-server-is
    mssql-tools mssql-tools18 msodbcsql17 msodbcsql18 mssql-cli
    mssql-server-extensibility
)
DIRS=(
    "/var/opt/mssql" "/opt/mssql" "/opt/mssql-tools" "/opt/mssql-tools18"
    "/opt/microsoft/msodbcsql17" "/opt/microsoft/msodbcsql18"
    "/opt/microsoft/mssql-tools" "/opt/microsoft/mssql-tools18"
    "/var/log/mssql" "/etc/mssql-conf"
)
SERVICES=(mssql-server mssql-server-agent mssql-launchpadd)

# ------------------------------------------------------------------- funciones base
log() {
    # En modo grafico/TUI el stdout se usa para alimentar la barra de progreso,
    # asi que solo se escribe en el log; en modo texto plano tambien se imprime.
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date +%H:%M:%S)"
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"
    if [ "$UI_MODE" = "plain" ]; then
        local color="$C_GRAY"
        case "$level" in
            OK)    color="$C_GREEN" ;;
            WARN)  color="$C_YELLOW" ;;
            ERROR) color="$C_RED" ;;
            STEP)  color="$C_CYAN" ;;
        esac
        echo -e "${color}[$ts] [$level] ${msg}${C_RESET}"
    fi
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log INFO "(simulado) $*"
        return 0
    fi
    if "$@" >> "$LOG_FILE" 2>&1; then
        return 0
    else
        return 1
    fi
}

remove_path() {
    local path="$1"
    [ -e "$path" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        log INFO "(simulado) rm -rf $path"
        return 0
    fi
    if rm -rf "$path" >> "$LOG_FILE" 2>&1; then
        log OK "Eliminado: $path"; REMOVED=$((REMOVED+1))
    else
        log ERROR "No se pudo eliminar: $path"; FAILED=$((FAILED+1))
    fi
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then PKG="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG="yum"
    elif command -v zypper >/dev/null 2>&1; then PKG="zypper"
    fi
}

detect_ui_mode() {
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        UI_MODE="zenity"
    elif command -v whiptail >/dev/null 2>&1; then
        UI_MODE="whiptail"; TUI_BIN="whiptail"
    elif command -v dialog >/dev/null 2>&1; then
        UI_MODE="whiptail"; TUI_BIN="dialog"
    else
        UI_MODE="plain"
    fi
}

banner() {
    clear 2>/dev/null || true
    echo -e "${C_CYAN}"
    echo "================================================================================"
    echo ""
    echo "     SQL SERVER  ->  COMPLETE REMOVAL UTILITY  (Linux)"
    echo "     Desinstalacion total: servicio, paquetes, datos, repos, usuario"
    echo ""
    echo "     Version 2.0    |    Desarrollado por Kisnner Obando"
    echo ""
    echo "================================================================================"
    echo -e "${C_RESET}"
    echo -e "${C_GRAY} Registro de la operacion: $LOG_FILE${C_RESET}\n"
}

scan_summary() {
    # Cuenta (sin borrar nada) cuantos elementos coinciden, para mostrarlos
    # antes de pedir confirmacion.
    local pkg_count=0 dir_count=0 svc_count=0
    for pkg in "${PACKAGES[@]}"; do
        case "$PKG" in
            apt)          dpkg -s "$pkg" >/dev/null 2>&1 && pkg_count=$((pkg_count+1)) ;;
            dnf|yum|zypper) rpm -q "$pkg" >/dev/null 2>&1 && pkg_count=$((pkg_count+1)) ;;
        esac
    done
    for d in "${DIRS[@]}"; do [ -e "$d" ] && dir_count=$((dir_count+1)); done
    for svc in "${SERVICES[@]}"; do
        systemctl list-unit-files 2>/dev/null | grep -q "^${svc}" && svc_count=$((svc_count+1))
    done
    echo "$pkg_count $dir_count $svc_count"
}

eula_text() {
    cat <<'EOF'
TERMINOS Y CONDICIONES DE USO
================================================================================

1. NATURALEZA DE LA HERRAMIENTA
   Este script es una utilidad INDEPENDIENTE desarrollada por Kisnner Obando.
   NO es un producto oficial de Microsoft, no esta afiliado, respaldado ni
   asociado con Microsoft Corporation. "SQL Server" y "SQL Server Management
   Studio" son marcas registradas de Microsoft Corporation, mencionadas aqui
   unicamente con fines descriptivos.

2. NATURALEZA DESTRUCTIVA E IRREVERSIBLE
   Esta herramienta ELIMINA DE FORMA PERMANENTE: el servicio de SQL Server,
   los paquetes instalados, TODAS las bases de datos y archivos de datos
   (.mdf/.ndf/.ldf/.bak salvo que actives "conservar datos"), archivos de
   configuracion, repositorios, el usuario del sistema "mssql" y archivos
   temporales relacionados. Esta accion NO SE PUEDE DESHACER.

3. RESPONSABILIDAD DEL USUARIO
   Es tu responsabilidad haber realizado una copia de seguridad de cualquier
   dato que necesites conservar antes de continuar. Se recomienda ejecutar
   primero el modo simulacion para revisar exactamente que se eliminaria.

4. SIN GARANTIA
   Esta herramienta se entrega "TAL CUAL", sin garantia de ningun tipo. El
   autor no se hace responsable de perdida de datos, tiempo de inactividad,
   o cualquier dano derivado de su uso.

5. PERMISOS
   Requiere privilegios de administrador (root) para ejecutarse, ya que
   modifica servicios del sistema, paquetes y archivos protegidos.

Al continuar, confirmas que has leido y aceptas estos terminos.
================================================================================
EOF
}

# ------------------------------------------------------------------ argumentos
for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --force)     FORCE=1 ;;
        --keep-data) KEEP_DATA=1 ;;
        --cli)       FORCE_CLI=1 ;;
        -h|--help)   grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
        *) echo "Opcion desconocida: $arg"; exit 1 ;;
    esac
done

detect_pkg_manager
detect_ui_mode
[ "$FORCE_CLI" -eq 1 ] && UI_MODE="plain"

# --------------------------------------------------------------- comprobacion root
if [ "$(id -u)" -ne 0 ]; then
    case "$UI_MODE" in
        zenity)   zenity --error --title="Permisos insuficientes" --text="Este script debe ejecutarse como root.\n\nUsa: sudo $0" 2>/dev/null ;;
        whiptail) $TUI_BIN --title "Permisos insuficientes" --msgbox "Este script debe ejecutarse como root.\n\nUsa: sudo $0" 10 60 ;;
    esac
    echo "ERROR: este script debe ejecutarse como root. Usa: sudo $0" >&2
    exit 1
fi

log INFO "Gestor de paquetes detectado: ${PKG:-ninguno}"
log INFO "Modo de interfaz: $UI_MODE"

# ============================================================ PASOS DE ELIMINACION
step_stop_services() {
    for svc in "${SERVICES[@]}"; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
            run systemctl stop "$svc"    && log OK "Servicio detenido: $svc"
            run systemctl disable "$svc"  && log OK "Servicio deshabilitado: $svc"
        fi
    done
    for p in sqlservr sqlagent msmdsrv; do
        if pgrep -x "$p" >/dev/null 2>&1; then
            run pkill -9 -x "$p" && log OK "Proceso terminado: $p"
        fi
    done
}

step_remove_packages() {
    for pkg in "${PACKAGES[@]}"; do
        case "$PKG" in
            apt)
                if dpkg -s "$pkg" 2>/dev/null | grep -q '^Status:.*\binstalled'; then
                    run env DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "$pkg" \
                        && { log OK "Paquete purgado: $pkg"; REMOVED=$((REMOVED+1)); } \
                        || { log WARN "No se pudo purgar: $pkg"; FAILED=$((FAILED+1)); }
                fi ;;
            dnf|yum)
                if rpm -q "$pkg" >/dev/null 2>&1; then
                    run "$PKG" remove -y "$pkg" \
                        && { log OK "Paquete eliminado: $pkg"; REMOVED=$((REMOVED+1)); } \
                        || { log WARN "No se pudo eliminar: $pkg"; FAILED=$((FAILED+1)); }
                fi ;;
            zypper)
                if rpm -q "$pkg" >/dev/null 2>&1; then
                    run zypper --non-interactive remove -u "$pkg" \
                        && { log OK "Paquete eliminado: $pkg"; REMOVED=$((REMOVED+1)); } \
                        || { log WARN "No se pudo eliminar: $pkg"; FAILED=$((FAILED+1)); }
                fi ;;
        esac
    done
    case "$PKG" in
        apt)      run env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y ;;
        dnf|yum)  run "$PKG" autoremove -y ;;
    esac
}

step_remove_repos() {
    remove_path "/etc/apt/sources.list.d/mssql-server.list"
    if dpkg -s powershell >/dev/null 2>&1 || dpkg -s dotnet-runtime-8.0 >/dev/null 2>&1 || dpkg -l 2>/dev/null | grep -qE '^ii\s+(powershell|dotnet-sdk|dotnet-runtime)'; then
        log WARN "Se conserva msprod.list: PowerShell/.NET instalados dependen de ese repo."
    else
        remove_path "/etc/apt/sources.list.d/msprod.list"
    fi
    remove_path "/etc/yum.repos.d/mssql-server.repo"
    remove_path "/etc/yum.repos.d/msprod.repo"
    remove_path "/etc/zypp/repos.d/mssql-server.repo"

    if grep -Rls "packages.microsoft.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -q .; then
        log WARN "Se conserva la llave GPG de Microsoft: hay otros repos de MS en uso (VS Code, Edge, .NET...)."
    else
        remove_path "/etc/apt/trusted.gpg.d/microsoft.gpg"
        remove_path "/usr/share/keyrings/microsoft-prod.gpg"
    fi
    [ "$PKG" = "apt" ] && run apt-get update
}

step_remove_dirs() {
    if [ "$KEEP_DATA" -eq 1 ]; then
        RESCUE_DIR="/var/backups/sqlserver_data_$(date +%Y%m%d_%H%M%S)"
        if [ -d /var/opt/mssql ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log INFO "(simulado) rescatar .mdf/.ndf/.ldf/.bak de /var/opt/mssql a $RESCUE_DIR"
            else
                mkdir -p "$RESCUE_DIR"
                local rescued=0
                while IFS= read -r -d '' f; do
                    local base dest n
                    base="$(basename "$f")"
                    dest="$RESCUE_DIR/$base"
                    n=1
                    while [ -e "$dest" ]; do dest="$RESCUE_DIR/${n}_${base}"; n=$((n+1)); done
                    if cp -p "$f" "$dest" >> "$LOG_FILE" 2>&1; then
                        rescued=$((rescued+1))
                    else
                        log WARN "No se pudo rescatar: $f"; FAILED=$((FAILED+1))
                    fi
                done < <(find /var/opt/mssql \( -name '*.mdf' -o -name '*.ndf' -o -name '*.ldf' -o -name '*.bak' \) -type f -print0 2>/dev/null)
                if [ "$rescued" -gt 0 ]; then
                    log OK "Datos rescatados: $rescued archivos en $RESCUE_DIR"
                else
                    rmdir "$RESCUE_DIR" 2>/dev/null || true
                    log INFO "keep-data: no se encontraron archivos de datos que rescatar."
                fi
            fi
        fi
    fi
    for d in "${DIRS[@]}"; do
        remove_path "$d"
    done
    if [ -d /opt/microsoft ]; then
        run rmdir --ignore-fail-on-non-empty /opt/microsoft || true
    fi
}

step_remove_temp() {
    shopt -s nullglob
    for f in /tmp/mssql* /tmp/*mssql*.log /tmp/sqlservr* /var/tmp/mssql*; do
        remove_path "$f"
    done
    shopt -u nullglob
}

step_remove_user() {
    if id mssql >/dev/null 2>&1; then
        run userdel -r mssql 2>/dev/null && log OK "Usuario 'mssql' eliminado" || log WARN "El usuario 'mssql' pudo no eliminarse por completo"
    fi
    if getent group mssql >/dev/null 2>&1; then
        run groupdel mssql && log OK "Grupo 'mssql' eliminado" || log WARN "No se pudo eliminar el grupo 'mssql'"
    fi
}

step_clean_path() {
    for profile in /etc/profile.d/mssql-tools.sh /root/.bashrc /home/*/.bashrc /root/.profile /home/*/.profile; do
        [ -f "$profile" ] || continue
        if grep -q "mssql-tools" "$profile" 2>/dev/null; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log INFO "(simulado) limpiar referencias mssql-tools en $profile"
            else
                cp "$profile" "${profile}.sqlbak" 2>/dev/null || true
                grep -v "mssql-tools" "$profile" > "${profile}.tmp" 2>/dev/null || true
                mv "${profile}.tmp" "$profile"
                log OK "Referencias mssql-tools limpiadas en: $profile (respaldo .sqlbak)"
            fi
        fi
    done
    remove_path "/etc/profile.d/mssql-tools.sh"
}

print_summary_plain() {
    echo ""
    echo -e "${C_CYAN}================================================================================${C_RESET}"
    echo -e "${C_CYAN}  RESUMEN DE LA OPERACION${C_RESET}"
    echo -e "${C_CYAN}================================================================================${C_RESET}"
    log OK   "Elementos eliminados : $REMOVED"
    if [ "$FAILED" -gt 0 ]; then
        log WARN "Fallos / revision manual: $FAILED"
    else
        log OK   "Fallos / revision manual: $FAILED"
    fi
    echo ""
    if [ "$DRY_RUN" -eq 1 ]; then
        log STEP "SIMULACION completada. No se elimino nada. Ejecuta sin --dry-run para aplicar."
    else
        log STEP "Limpieza completada. Se recomienda reiniciar antes de reinstalar."
        echo -e "${C_GREEN} El sistema esta listo para una instalacion limpia de SQL Server.${C_RESET}"
    fi
    echo -e "${C_GRAY} Log completo: $LOG_FILE${C_RESET}\n"
}

# ============================================================ FLUJO: TEXTO PLANO
run_plain_flow() {
    banner
    if [ "$DRY_RUN" -eq 1 ]; then
        log STEP "Modo: SIMULACION (--dry-run): no se borrara nada."
    else
        log STEP "Modo: REAL: se eliminaran datos de forma permanente."
    fi
    [ "$KEEP_DATA" -eq 1 ] && log WARN "Opcion --keep-data activa: los .mdf/.ndf/.ldf/.bak se copiaran a /var/backups/sqlserver_data_<fecha> antes de borrar."

    if [ "$DRY_RUN" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
        echo -e "${C_YELLOW}"
        echo " ADVERTENCIA: se eliminara SQL Server y TODOS sus datos de este servidor."
        echo " Esta accion NO se puede deshacer."
        echo -e "${C_RESET}"
        read -r -p " Escribe SI (mayusculas) para continuar: " ANS
        if [ "$ANS" != "SI" ]; then
            log WARN "Operacion cancelada por el usuario."
            exit 0
        fi
    fi

    log STEP "PASO 1/7 - Deteniendo y deshabilitando el servicio mssql-server..."
    step_stop_services
    log STEP "PASO 2/7 - Desinstalando paquetes de SQL Server y herramientas..."
    step_remove_packages
    log STEP "PASO 3/7 - Eliminando repositorios de paquetes de Microsoft SQL..."
    step_remove_repos
    log STEP "PASO 4/7 - Eliminando directorios, datos y binarios..."
    step_remove_dirs
    log STEP "PASO 5/7 - Limpiando archivos temporales..."
    step_remove_temp
    log STEP "PASO 6/7 - Eliminando usuario y grupo del sistema 'mssql'..."
    step_remove_user
    log STEP "PASO 7/7 - Limpiando referencias a mssql-tools en el PATH..."
    step_clean_path

    print_summary_plain
}

# ============================================================ FLUJO: ZENITY (GUI)
run_zenity_wizard() {
    zenity --info --title="Desinstalador de SQL Server" --width=480 \
        --text="<b>Asistente de desinstalacion completa de SQL Server</b>\n\nEste asistente eliminara el servicio, los paquetes, los datos y los archivos temporales de SQL Server de este equipo, dejandolo listo para una instalacion limpia.\n\nDesarrollado por Kisnner Obando." \
        --ok-label="Comenzar" 2>/dev/null
    [ $? -ne 0 ] && { log WARN "Operacion cancelada por el usuario."; exit 0; }

    local eula_file; eula_file="$(mktemp)"
    eula_text > "$eula_file"
    zenity --text-info --title="Terminos y condiciones" --width=640 --height=440 \
        --filename="$eula_file" \
        --checkbox="He leido y acepto los terminos y condiciones" \
        --ok-label="Aceptar y continuar" --cancel-label="Cancelar" 2>/dev/null
    local rc=$?
    rm -f "$eula_file"
    [ $rc -ne 0 ] && { log WARN "Operacion cancelada (terminos no aceptados)."; exit 0; }

    read -r PKG_COUNT DIR_COUNT SVC_COUNT <<< "$(scan_summary)"

    local options
    options=$(zenity --list --title="Opciones de desinstalacion" --width=520 --height=250 \
        --text="Se detectaron: $PKG_COUNT paquete(s), $DIR_COUNT carpeta(s), $SVC_COUNT servicio(s).\n\nSelecciona las opciones antes de continuar:" \
        --checklist --column="" --column="Opcion" --separator="|" --hide-header \
        FALSE "Modo simulacion (no elimina nada, solo muestra que haria)" \
        FALSE "Conservar archivos de datos (.mdf/.ndf/.ldf/.bak)" 2>/dev/null)
    local rc2=$?
    [ $rc2 -ne 0 ] && { log WARN "Operacion cancelada por el usuario."; exit 0; }
    DRY_RUN=0; KEEP_DATA=0
    [[ "$options" == *"simulacion"* ]] && DRY_RUN=1
    [[ "$options" == *"Conservar"* ]] && KEEP_DATA=1

    local warn_line
    if [ "$DRY_RUN" -eq 1 ]; then
        warn_line="Modo SIMULACION: no se eliminara nada realmente."
    else
        warn_line="ADVERTENCIA: esta accion eliminara SQL Server y TODOS sus datos de forma permanente."
    fi
    zenity --question --title="Confirmar desinstalacion" --width=520 \
        --text="Se eliminaran: $PKG_COUNT paquete(s), $DIR_COUNT carpeta(s), $SVC_COUNT servicio(s).\n\n$warn_line\n\n¿Deseas continuar?" \
        --ok-label="Desinstalar" --cancel-label="Cancelar" 2>/dev/null
    [ $? -ne 0 ] && { log WARN "Operacion cancelada por el usuario."; exit 0; }

    local count_file; count_file="$(mktemp)"
    echo "0 0" > "$count_file"
    {
        echo 5;  echo "# Deteniendo servicios..."
        step_stop_services
        echo 30; echo "# Desinstalando paquetes..."
        step_remove_packages
        echo 45; echo "# Eliminando repositorios..."
        step_remove_repos
        echo 65; echo "# Eliminando directorios y datos..."
        step_remove_dirs
        echo 80; echo "# Limpiando temporales..."
        step_remove_temp
        echo 90; echo "# Eliminando usuario del sistema..."
        step_remove_user
        echo 97; echo "# Limpiando variables de entorno..."
        step_clean_path
        echo 100; echo "# Completado"
        echo "$REMOVED $FAILED" > "$count_file"
    } | zenity --progress --title="Desinstalando SQL Server" --text="Iniciando..." \
        --percentage=0 --auto-close --no-cancel --width=460 2>/dev/null

    read -r REMOVED FAILED < "$count_file"
    rm -f "$count_file"

    if [ "$FAILED" -gt 0 ]; then
        zenity --warning --title="Desinstalacion completada con avisos" --width=480 \
            --text="Elementos eliminados: $REMOVED\nCon fallos (revision manual): $FAILED\n\nLog completo:\n$LOG_FILE" 2>/dev/null
    elif [ "$DRY_RUN" -eq 1 ]; then
        zenity --info --title="Simulacion completada" --width=480 \
            --text="Simulacion completada, no se elimino nada.\n\nLog completo:\n$LOG_FILE" 2>/dev/null
    else
        zenity --info --title="Desinstalacion completada" --width=480 \
            --text="Elementos eliminados: $REMOVED\n\nEl sistema esta listo para una instalacion limpia.\nSe recomienda reiniciar el equipo.\n\nLog completo:\n$LOG_FILE" 2>/dev/null
        if zenity --question --title="Reiniciar equipo" --text="¿Deseas reiniciar el equipo ahora?" \
            --ok-label="Reiniciar" --cancel-label="Mas tarde" 2>/dev/null; then
            reboot
        fi
    fi
}

# ============================================================ FLUJO: WHIPTAIL/DIALOG (TUI)
run_whiptail_wizard() {
    $TUI_BIN --title "Desinstalador de SQL Server" --msgbox \
        "Asistente de desinstalacion completa de SQL Server\n\nEste asistente eliminara el servicio, los paquetes, los datos y los archivos temporales de SQL Server de este equipo.\n\nDesarrollado por Kisnner Obando." 14 70

    local eula_file; eula_file="$(mktemp)"
    eula_text > "$eula_file"
    $TUI_BIN --title "Terminos y condiciones" --textbox "$eula_file" 24 78
    rm -f "$eula_file"
    if ! $TUI_BIN --title "Aceptar terminos" --yesno "¿Aceptas los terminos y condiciones que acabas de leer?" 8 70; then
        log WARN "Operacion cancelada (terminos no aceptados)."
        exit 0
    fi

    read -r PKG_COUNT DIR_COUNT SVC_COUNT <<< "$(scan_summary)"

    local choices
    choices=$($TUI_BIN --title "Opciones de desinstalacion" --checklist \
        "Detectado: $PKG_COUNT paquete(s), $DIR_COUNT carpeta(s), $SVC_COUNT servicio(s).\n\nSelecciona con espacio, confirma con Enter:" \
        14 70 2 \
        "DRYRUN"   "Modo simulacion (no elimina nada)" OFF \
        "KEEPDATA" "Conservar archivos de datos (.mdf/.ndf/.ldf/.bak)" OFF \
        3>&1 1>&2 2>&3)
    local rc=$?
    if [ $rc -ne 0 ]; then
        log WARN "Operacion cancelada por el usuario."
        exit 0
    fi
    DRY_RUN=0; KEEP_DATA=0
    [[ "$choices" == *"DRYRUN"* ]] && DRY_RUN=1
    [[ "$choices" == *"KEEPDATA"* ]] && KEEP_DATA=1

    local warn_line
    if [ "$DRY_RUN" -eq 1 ]; then
        warn_line="Modo SIMULACION: no se eliminara nada realmente."
    else
        warn_line="ADVERTENCIA: esta accion es IRREVERSIBLE."
    fi
    if ! $TUI_BIN --title "Confirmar desinstalacion" --yesno \
        "Se eliminaran: $PKG_COUNT paquete(s), $DIR_COUNT carpeta(s), $SVC_COUNT servicio(s).\n\n$warn_line\n\n¿Continuar?" \
        --defaultno 12 70; then
        log WARN "Operacion cancelada por el usuario."
        exit 0
    fi

    local count_file; count_file="$(mktemp)"
    echo "0 0" > "$count_file"
    {
        echo 5
        step_stop_services
        echo 30
        step_remove_packages
        echo 45
        step_remove_repos
        echo 65
        step_remove_dirs
        echo 80
        step_remove_temp
        echo 90
        step_remove_user
        echo 97
        step_clean_path
        echo 100
        echo "$REMOVED $FAILED" > "$count_file"
    } | $TUI_BIN --title "Desinstalando SQL Server" --gauge "Por favor espera, esto puede tardar unos minutos..." 8 70 0

    read -r REMOVED FAILED < "$count_file"
    rm -f "$count_file"

    if [ "$FAILED" -gt 0 ]; then
        $TUI_BIN --title "Completado con avisos" --msgbox \
            "Elementos eliminados: $REMOVED\nCon fallos (revision manual): $FAILED\n\nLog completo:\n$LOG_FILE" 12 70
    elif [ "$DRY_RUN" -eq 1 ]; then
        $TUI_BIN --title "Simulacion completada" --msgbox \
            "Simulacion completada, no se elimino nada.\n\nLog completo:\n$LOG_FILE" 10 70
    else
        $TUI_BIN --title "Desinstalacion completada" --msgbox \
            "Elementos eliminados: $REMOVED\n\nEl sistema esta listo para una instalacion limpia.\nSe recomienda reiniciar el equipo.\n\nLog completo:\n$LOG_FILE" 12 70
        if $TUI_BIN --title "Reiniciar equipo" --yesno "¿Deseas reiniciar el equipo ahora?" --defaultno 8 60; then
            reboot
        fi
    fi
}

# ------------------------------------------------------------------------ MAIN
case "$UI_MODE" in
    zenity)   run_zenity_wizard ;;
    whiptail) run_whiptail_wizard ;;
    *)        run_plain_flow ;;
esac
