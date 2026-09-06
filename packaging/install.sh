#!/usr/bin/env bash
# ============================================================================
#  Nitro Gekko - instalador
#
#  Panel de control del Acer Nitro AN17-51 para GNOME.
#
#  USO
#    sudo ./packaging/install.sh                 instala en el sistema
#    sudo ./packaging/install.sh --uninstall     desinstala
#    DESTDIR=/tmp/prueba ./packaging/install.sh  instala en un arbol falso
#                                                (no toca el sistema, no pide root)
#
#  Con DESTDIR puesto el instalador NO recarga udev, NO recarga tmpfiles y NO
#  toca /sys: solo construye el arbol de ficheros. Es la forma de revisar que
#  va a instalar antes de dejarle tocar el equipo de verdad.
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
#  Identidad del proyecto
# ---------------------------------------------------------------------------
readonly APP_ID="org.thegekko.nitrogekko"
readonly APP_NOMBRE="Nitro Gekko"
readonly APP_BIN="nitro-gekko"

# Raiz del proyecto = el directorio padre de packaging/
RAIZ="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly RAIZ

# ---------------------------------------------------------------------------
#  Rutas de instalacion
#
#  El codigo de la aplicacion va a /usr/lib/nitro-gekko y no a /usr/share.
#  Motivo: es codigo privado del programa, no datos compartidos. Aunque sea
#  Python (independiente de arquitectura), la convencion de Arch y de la FHS
#  para "codigo que solo ejecuta este programa y nadie mas importa" es
#  /usr/lib/<programa>. En /usr/share van el .desktop, el icono y el esquema,
#  que si son datos compartidos con el escritorio.
# ---------------------------------------------------------------------------
PREFIX="${PREFIX:-/usr}"
DESTDIR="${DESTDIR:-}"

readonly DIR_APP="${PREFIX}/lib/${APP_BIN}"
readonly DIR_BIN="${PREFIX}/bin"
readonly DIR_UDEV="${PREFIX}/lib/udev/rules.d"
readonly DIR_TMPFILES="${PREFIX}/lib/tmpfiles.d"
readonly DIR_DESKTOP="${PREFIX}/share/applications"
readonly DIR_ICONOS="${PREFIX}/share/icons/hicolor"
readonly DIR_ESQUEMAS="${PREFIX}/share/glib-2.0/schemas"

readonly DIR_POLKIT="${PREFIX}/share/polkit-1/actions"

readonly FICHERO_UDEV="99-nitro-gekko.rules"
readonly FICHERO_TMPFILES="nitro-gekko.conf"
readonly FICHERO_HELPER="nitro-gekko-helper"
readonly FICHERO_POLICY="org.thegekko.nitrogekko.policy"

# Modo de privilegios.  Por DEFECTO solo polkit: la aplicacion llama al helper
# por pkexec y GNOME pide la contrasena.  Con --con-udev se instalan ademas las
# reglas que abren esas rutas de /sys al grupo 'wheel', lo que evita el dialogo
# a cambio de que CUALQUIER proceso del usuario pueda escribir ahi sin
# autenticarse.  Ver packaging/SEGURIDAD.md.
CON_UDEV=0

# ---------------------------------------------------------------------------
#  Salida por pantalla
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_ROJO=$'\033[31m'; C_AMAR=$'\033[33m'; C_VERDE=$'\033[32m'
    C_AZUL=$'\033[34m'; C_NEG=$'\033[1m';   C_FIN=$'\033[0m'
else
    C_ROJO=''; C_AMAR=''; C_VERDE=''; C_AZUL=''; C_NEG=''; C_FIN=''
fi

info()  { printf '%s==>%s %s\n'      "$C_AZUL"  "$C_FIN" "$*"; }
ok()    { printf '%s  ok%s  %s\n'    "$C_VERDE" "$C_FIN" "$*"; }
aviso() { printf '%sAVISO%s %s\n'    "$C_AMAR"  "$C_FIN" "$*" >&2; }
error() { printf '%sERROR%s %s\n'    "$C_ROJO"  "$C_FIN" "$*" >&2; }
titulo(){ printf '\n%s%s%s\n'        "$C_NEG"   "$*"     "$C_FIN"; }

HUBO_AVISOS=0
aviso_contado() { HUBO_AVISOS=$((HUBO_AVISOS + 1)); aviso "$@"; }

# ---------------------------------------------------------------------------
#  Usuario real (el instalador corre como root via sudo, pero la extension de
#  GNOME Shell va en el HOME de la persona, no en el de root)
# ---------------------------------------------------------------------------
detectar_usuario() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        USUARIO="$SUDO_USER"
    elif [[ -n "${PKEXEC_UID:-}" ]]; then
        USUARIO="$(id -nu "$PKEXEC_UID")"
    else
        USUARIO="$(id -nu)"
    fi
    HOME_USUARIO="$(getent passwd "$USUARIO" | cut -d: -f6)"
    if [[ -z "$HOME_USUARIO" ]]; then
        HOME_USUARIO="${HOME:-/root}"
    fi
    DIR_EXTENSIONES="${HOME_USUARIO}/.local/share/gnome-shell/extensions"
}

# ---------------------------------------------------------------------------
#  Comprobaciones del equipo. Ninguna aborta: esto avisa, no manda.
# ---------------------------------------------------------------------------
comprobar_hardware() {
    titulo "1. Hardware"

    # Variable para poder probar el aviso con un DMI falso:
    #   DIR_DMI=/ruta/falsa ./packaging/install.sh
    local dmi="${DIR_DMI:-/sys/class/dmi/id}"
    local vendor producto familia placa
    vendor="$(cat "$dmi/sys_vendor"     2>/dev/null || echo '?')"
    producto="$(cat "$dmi/product_name" 2>/dev/null || echo '?')"
    familia="$(cat "$dmi/product_family" 2>/dev/null || echo '?')"
    placa="$(cat "$dmi/board_name"      2>/dev/null || echo '?')"

    info "Fabricante : $vendor"
    info "Modelo     : $producto"
    info "Familia    : $familia"
    info "Placa      : $placa"

    if [[ "$vendor" != "Acer" ]]; then
        aviso_contado "Este equipo no es un Acer (sys_vendor = '$vendor')."
        aviso_contado "Nitro Gekko esta hecho para un Acer Nitro AN17-51. Las rutas de"
        aviso_contado "sysfs que abre pueden no existir aqui, o significar otra cosa."
        aviso_contado "Se continua igualmente, pero revisa packaging/SEGURIDAD.md antes."
    elif [[ "$producto" != *Nitro* && "$familia" != *Nitro* ]]; then
        aviso_contado "Es un Acer pero no parece un Nitro ('$producto' / '$familia')."
        aviso_contado "Probado unicamente en Nitro AN17-51. Se continua."
    else
        ok "Acer Nitro detectado."
        if [[ "$producto" != "Nitro AN17-51" ]]; then
            aviso_contado "El modelo probado es 'Nitro AN17-51' y este es '$producto'."
            aviso_contado "Deberia funcionar, pero los vatios y las RPM de referencia"
            aviso_contado "que muestra la aplicacion son los de ese modelo."
        fi
    fi
}

# ---------------------------------------------------------------------------
#  acer_wmi + predator_v4=1. Sin esto no hay perfiles de plataforma.
# ---------------------------------------------------------------------------
explicar_predator_v4() {
    cat <<'AYUDA'

  Como arreglarlo:

    1) Crea el fichero de opciones del modulo:

         echo 'options acer_wmi predator_v4=1' | sudo tee /etc/modprobe.d/acer-wmi.conf

    2) Recarga el modulo en caliente:

         sudo modprobe -r acer_wmi && sudo modprobe acer_wmi

       Si da "module in use", reinicia y ya esta.

    3) Comprueba que ha funcionado:

         cat /sys/module/acer_wmi/parameters/predator_v4      # debe decir Y
         cat /sys/class/platform-profile/platform-profile-0/choices

       Lo segundo debe imprimir:
         low-power quiet balanced balanced-performance performance

    4) Si acer_wmi va compilado dentro del kernel en vez de como modulo,
       el fichero de modprobe.d no sirve: hay que anadir acer_wmi.predator_v4=1
       a la linea de arranque del kernel.

AYUDA
}

comprobar_modulo() {
    titulo "2. Modulo acer_wmi"

    local hay_problema=0

    if [[ ! -d /sys/module/acer_wmi ]]; then
        aviso_contado "El modulo acer_wmi NO esta cargado."
        hay_problema=1
    else
        ok "acer_wmi cargado."
        local p=/sys/module/acer_wmi/parameters/predator_v4
        if [[ -r "$p" ]]; then
            local v; v="$(cat "$p")"
            case "$v" in
                Y|y|1) ok "predator_v4 = $v" ;;
                *)     aviso_contado "predator_v4 = '$v' (deberia ser Y o 1)."
                       hay_problema=1 ;;
            esac
        else
            aviso_contado "Este acer_wmi no tiene el parametro predator_v4."
            aviso_contado "Kernel demasiado antiguo o modulo distinto."
            hay_problema=1
        fi
    fi

    if [[ -e /sys/firmware/acpi/platform_profile ]]; then
        ok "platform_profile existe."
        local choices=/sys/class/platform-profile/platform-profile-0/choices
        if [[ -r "$choices" ]]; then
            info "Perfiles disponibles: $(cat "$choices")"
        fi
    else
        aviso_contado "NO existe /sys/firmware/acpi/platform_profile."
        aviso_contado "Sin eso, el control de perfiles de la aplicacion no hara nada."
        hay_problema=1
    fi

    if [[ ! -e /sys/bus/wmi/drivers/acer-wmi-battery/health_mode ]]; then
        aviso_contado "No esta el modulo DKMS acer-wmi-battery (health_mode no existe)."
        aviso_contado "Sin el, la aplicacion no podra limitar la carga de la bateria al 80%."
        aviso_contado "Es un modulo aparte, no viene con el kernel: acer-wmi-battery-dkms."
    else
        ok "acer-wmi-battery presente (limite de carga disponible)."
    fi

    if (( hay_problema )); then
        explicar_predator_v4
    fi
}

comprobar_grupo_wheel() {
    titulo "3. Grupo wheel"
    if getent group wheel >/dev/null; then
        ok "El grupo wheel existe (gid $(getent group wheel | cut -d: -f3))."
        if id -nG "$USUARIO" | tr ' ' '\n' | grep -qx wheel; then
            ok "El usuario '$USUARIO' pertenece a wheel."
        else
            aviso_contado "El usuario '$USUARIO' NO esta en el grupo wheel."
            aviso_contado "Nitro Gekko no podra escribir nada. Anadelo con:"
            aviso_contado "    sudo usermod -aG wheel $USUARIO"
            aviso_contado "y vuelve a iniciar sesion."
        fi
    else
        aviso_contado "No existe el grupo 'wheel' en este sistema."
        aviso_contado "Las reglas y el tmpfiles.d se instalaran pero no serviran de nada."
    fi
}

# ---------------------------------------------------------------------------
#  Ayudantes de instalacion
# ---------------------------------------------------------------------------
# poner <modo> <origen> <destino-sin-DESTDIR>
poner() {
    local modo="$1" origen="$2" destino="$3"
    if [[ ! -e "$origen" ]]; then
        aviso_contado "No existe '${origen#"$RAIZ"/}', se omite."
        return 1
    fi
    install -Dm"$modo" "$origen" "${DESTDIR}${destino}"
    ok "${destino}"
}

# poner_arbol <origen-dir> <destino-dir-sin-DESTDIR>
poner_arbol() {
    local origen="$1" destino="$2"
    if [[ ! -d "$origen" ]]; then
        aviso_contado "No existe el directorio '${origen#"$RAIZ"/}', se omite."
        return 1
    fi
    if [[ -z "$(ls -A "$origen" 2>/dev/null)" ]]; then
        aviso_contado "El directorio '${origen#"$RAIZ"/}' esta vacio, se omite."
        return 1
    fi
    install -d "${DESTDIR}${destino}"
    cp -a "$origen"/. "${DESTDIR}${destino}/"
    # Basura de Python: no tiene nada que hacer en /usr.
    find "${DESTDIR}${destino}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find "${DESTDIR}${destino}" -name '*.pyc' -type f -delete 2>/dev/null || true
    # 'cp -a' equivale a '--preserve=all': arrastra el modo Y el propietario
    # del repositorio.  Sin normalizar, un clon hecho con umask 002 dejaba
    # /usr/lib/nitro-gekko/gekkonitro/*.py como 664 usuario:usuario, es decir
    # codigo de sistema que cualquier proceso del usuario puede reescribir.
    # Comprobado: cp -a de un fichero 666 lo deja 666 en el destino.
    find "${DESTDIR}${destino}" -type d -exec chmod 755 {} +
    find "${DESTDIR}${destino}" -type f -exec chmod 644 {} +
    # El propietario solo se puede cambiar con root.  La extension se vuelve
    # a asignar al usuario mas abajo, en instalar().
    if [[ "$(id -u)" -eq 0 ]]; then
        chown -R root:root "${DESTDIR}${destino}"
    fi
    ok "${destino}/  ($(find "${DESTDIR}${destino}" -type f | wc -l) ficheros)"
}

# UUID de la extension, leido de metadata.json (nunca inventado)
uuid_extension() {
    local meta="$RAIZ/extension/metadata.json"
    [[ -f "$meta" ]] || return 1
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["uuid"])' "$meta" 2>/dev/null
}

# ---------------------------------------------------------------------------
#  Instalar
# ---------------------------------------------------------------------------
instalar() {
    titulo "4. Instalando ficheros"
    [[ -n "$DESTDIR" ]] && info "DESTDIR = $DESTDIR (no se toca el sistema real)"

    # -- permisos (1): helper privilegiado + politica polkit -----------------
    # Este es el camino POR DEFECTO. El helper corre como root via pkexec y solo
    # acepta cuatro acciones con nombre; la lista de rutas vive dentro de el, no
    # se le pasa desde fuera.
    poner 755 "$RAIZ/packaging/$FICHERO_HELPER" "$DIR_APP/$FICHERO_HELPER" || true
    if [[ -f "$RAIZ/packaging/$FICHERO_POLICY" ]]; then
        # Una politica polkit mal formada se ignora en silencio y el helper
        # dejaria de poder autenticarse, asi que se valida antes de copiarla.
        if command -v xmllint >/dev/null; then
            if xmllint --noout "$RAIZ/packaging/$FICHERO_POLICY" 2>/dev/null; then
                ok "politica polkit bien formada"
            else
                aviso_contado "El XML de $FICHERO_POLICY no es valido; polkit lo ignoraria."
            fi
        fi
        poner 644 "$RAIZ/packaging/$FICHERO_POLICY" "$DIR_POLKIT/$FICHERO_POLICY" || true
    else
        aviso_contado "Falta packaging/$FICHERO_POLICY: la app no podra pedir permisos."
    fi

    # -- permisos (2): reglas udev y tmpfiles, SOLO con --con-udev ------------
    # udev descarta en silencio una regla que no sabe leer, asi que se valida
    # antes de instalarla: si no, los permisos no se aplicarian nunca y no
    # habria ni un mensaje que lo dijera.
    if (( ! CON_UDEV )); then
        info "Modo polkit (por defecto): no se abren permisos de /sys."
        info "La aplicacion pedira la contrasena por el dialogo de GNOME."
        info "Para el modo sin contrasena: $0 --con-udev  (lee SEGURIDAD.md antes)."
    elif command -v udevadm >/dev/null && [[ -f "$RAIZ/packaging/$FICHERO_UDEV" ]]; then
        if udevadm verify "$RAIZ/packaging/$FICHERO_UDEV" >/dev/null 2>&1; then
            ok "reglas udev validadas con 'udevadm verify'"
        else
            aviso_contado "'udevadm verify' rechaza packaging/$FICHERO_UDEV:"
            udevadm verify "$RAIZ/packaging/$FICHERO_UDEV" 2>&1 | sed 's/^/      /' >&2 || true
        fi
    fi
    if (( CON_UDEV )); then
        poner 644 "$RAIZ/packaging/$FICHERO_UDEV"     "$DIR_UDEV/$FICHERO_UDEV"     || true
        poner 644 "$RAIZ/packaging/$FICHERO_TMPFILES" "$DIR_TMPFILES/$FICHERO_TMPFILES" || true
    fi

    # -- codigo de la aplicacion ---------------------------------------------
    # Si esto no esta, no hay aplicacion: ni lanzador ni entrada de menu, que
    # solo servirian para fallar con ModuleNotFoundError al pulsarlos.
    local hay_codigo=0
    if [[ -d "$RAIZ/src/gekkonitro" ]]; then
        if poner_arbol "$RAIZ/src/gekkonitro" "$DIR_APP/gekkonitro"; then
            hay_codigo=1
        fi
    else
        aviso_contado "NO existe src/gekkonitro: la aplicacion no se instala."
        aviso_contado "Se omiten tambien el lanzador y la entrada de menu, que sin"
        aviso_contado "codigo solo darian ModuleNotFoundError. Lanza el instalador"
        aviso_contado "desde la raiz del repositorio completo."
    fi

    # -- lanzador en /usr/bin -------------------------------------------------
    # Se instala bin/nitro-gekko si existe; si no, se genera uno.
    # OJO: el ./nitro-gekko de la raiz del proyecto NO se instala a proposito.
    # Ese es el lanzador de DESARROLLO: apunta con PYTHONPATH y XDG_DATA_DIRS
    # al arbol del repositorio, asi que en /usr/bin dejaria de funcionar en
    # cuanto el repositorio cambiara de sitio.
    if (( ! hay_codigo )); then
        info "Sin codigo instalado: se omite el lanzador."
    elif [[ -f "$RAIZ/bin/$APP_BIN" ]]; then
        poner 755 "$RAIZ/bin/$APP_BIN" "$DIR_BIN/$APP_BIN" || true
    else
        install -d "${DESTDIR}${DIR_BIN}"
        cat > "${DESTDIR}${DIR_BIN}/${APP_BIN}" <<LANZADOR
#!/bin/sh
# Lanzador de $APP_NOMBRE (generado por packaging/install.sh).
# Si la aplicacion cambia de punto de entrada, este es el unico fichero
# que hay que tocar.
PYTHONPATH="${DIR_APP}\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHONPATH
exec /usr/bin/python3 -m gekkonitro "\$@"
LANZADOR
        chmod 755 "${DESTDIR}${DIR_BIN}/${APP_BIN}"
        ok "${DIR_BIN}/${APP_BIN}  (generado)"
    fi

    # -- .desktop -------------------------------------------------------------
    local desktop
    desktop="$(find "$RAIZ/data" -maxdepth 2 -name "${APP_ID}.desktop" -print -quit 2>/dev/null || true)"
    if (( ! hay_codigo )); then
        info "Sin codigo instalado: se omite la entrada de menu."
    elif [[ -n "$desktop" ]]; then
        poner 644 "$desktop" "$DIR_DESKTOP/${APP_ID}.desktop" || true
    else
        aviso_contado "No se encuentra ${APP_ID}.desktop en data/, se omite."
    fi

    # -- iconos ---------------------------------------------------------------
    # Se acepta tanto data/icons/hicolor/... (arbol ya montado) como
    # data/<APP_ID>.svg suelto.
    local instalado_icono=0
    if [[ -d "$RAIZ/data/icons/hicolor" ]]; then
        while IFS= read -r -d '' icono; do
            local rel="${icono#"$RAIZ"/data/icons/hicolor/}"
            install -Dm644 "$icono" "${DESTDIR}${DIR_ICONOS}/${rel}"
            ok "${DIR_ICONOS}/${rel}"
            instalado_icono=1
        done < <(find "$RAIZ/data/icons/hicolor" -type f \( -name '*.svg' -o -name '*.png' \) -print0 2>/dev/null)
    fi
    if (( ! instalado_icono )); then
        local suelto
        suelto="$(find "$RAIZ/data" -maxdepth 1 -name "${APP_ID}.svg" -print -quit 2>/dev/null || true)"
        if [[ -n "$suelto" ]]; then
            poner 644 "$suelto" "$DIR_ICONOS/scalable/apps/${APP_ID}.svg" || true
            instalado_icono=1
        fi
    fi
    (( instalado_icono )) || aviso_contado "No se ha encontrado ningun icono en data/, se omite."

    # -- esquema de GSettings (si lo hay) -------------------------------------
    local esquema
    esquema="$(find "$RAIZ/data" -maxdepth 2 -name "${APP_ID}.gschema.xml" -print -quit 2>/dev/null || true)"
    if [[ -n "$esquema" ]]; then
        poner 644 "$esquema" "$DIR_ESQUEMAS/${APP_ID}.gschema.xml" || true
    fi

    # -- extension de GNOME Shell (en el HOME del usuario, no en /usr) --------
    titulo "5. Extension de GNOME Shell"
    local uuid
    if uuid="$(uuid_extension)" && [[ -n "$uuid" ]]; then
        info "UUID leido de extension/metadata.json: $uuid"
        if poner_arbol "$RAIZ/extension" "${DIR_EXTENSIONES}/${uuid}"; then
            # La extension es del usuario, no de root.
            if [[ -z "$DESTDIR" ]] && [[ "$(id -u)" -eq 0 ]]; then
                chown -R "$USUARIO": "${DIR_EXTENSIONES}/${uuid}"
                ok "Propietario ajustado a $USUARIO."
            fi
            info "Para activarla:  gnome-extensions enable $uuid"
            info "En Wayland hace falta cerrar y abrir sesion (no vale Alt+F2 r)."
        fi
    else
        aviso_contado "No hay extension/metadata.json (o no tiene 'uuid'): extension omitida."
    fi
}

# ---------------------------------------------------------------------------
#  Recargas (solo instalacion real)
# ---------------------------------------------------------------------------
recargar() {
    titulo "6. Aplicando permisos"

    if [[ -n "$DESTDIR" ]]; then
        info "DESTDIR activo: no se recarga udev, ni tmpfiles, ni /sys."
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        aviso_contado "Sin root no se puede recargar. Hazlo a mano:"
        aviso_contado "    sudo udevadm control --reload"
        aviso_contado "    sudo udevadm trigger --action=change --subsystem-match=platform-profile --subsystem-match=powercap --subsystem-match=wmi"
        aviso_contado "    sudo systemd-tmpfiles --create $FICHERO_TMPFILES"
        return 0
    fi

    if (( ! CON_UDEV )); then
        # En modo polkit no se instala ninguna regla ni tmpfiles, asi que no
        # hay nada que recargar: intentarlo solo produce un error confuso
        # ("Failed to read /usr/lib/tmpfiles.d/nitro-gekko.conf").
        info "Modo polkit: no hay reglas de permisos que recargar."
        return 0
    fi

    info "Recargando reglas de udev..."
    # Con guarda a proposito: en un chroot o un contenedor sin udevd corriendo
    # esto falla, y con 'set -e' mataba el instalador justo despues de haber
    # dejado las reglas puestas y antes de aplicar el tmpfiles.
    if udevadm control --reload 2>/dev/null; then
        # Se dispara solo en los subsistemas implicados; un trigger global es
        # innecesario y molesta al resto del sistema.
        udevadm trigger --action=change \
            --subsystem-match=platform-profile \
            --subsystem-match=powercap \
            --subsystem-match=wmi || true
        udevadm settle --timeout=10 || true
        ok "udev recargado."
    else
        aviso_contado "No se ha podido hablar con udevd (chroot o contenedor?)."
        aviso_contado "Las reglas quedan instaladas y se aplicaran al arrancar."
    fi

    info "Aplicando tmpfiles..."
    # Se le pasa la RUTA ABSOLUTA del fichero recien instalado, no el nombre a
    # secas: systemd-tmpfiles solo resuelve nombres sueltos dentro de sus
    # directorios estandar (/etc, /run, /usr/lib, /usr/local/lib). Con un
    # PREFIX fuera de esos, 'systemd-tmpfiles --create nitro-gekko.conf'
    # devuelve 1 ("No such file or directory") y con 'set -e' se llevaba por
    # delante el resto del instalador. Comprobado.
    if systemd-tmpfiles --create "${DIR_TMPFILES}/${FICHERO_TMPFILES}"; then
        ok "tmpfiles aplicado."
    else
        aviso_contado "systemd-tmpfiles ha fallado. Aplicalo a mano:"
        aviso_contado "    sudo systemd-tmpfiles --create ${DIR_TMPFILES}/${FICHERO_TMPFILES}"
    fi

    if command -v update-desktop-database >/dev/null; then
        update-desktop-database -q "$DIR_DESKTOP" 2>/dev/null || true
    fi
    if command -v gtk4-update-icon-cache >/dev/null; then
        gtk4-update-icon-cache -qtf "$DIR_ICONOS" 2>/dev/null || true
    fi
    if [[ -d "$DIR_ESQUEMAS" ]] && command -v glib-compile-schemas >/dev/null; then
        glib-compile-schemas "$DIR_ESQUEMAS" 2>/dev/null || true
    fi

    titulo "7. Permisos resultantes"
    local ruta
    for ruta in "${RUTAS_SYSFS[@]}"; do
        if [[ -e "$ruta" ]]; then
            printf '  %s\n' "$(ls -l "$ruta")"
        else
            printf '  %s  %s(no existe)%s\n' "$ruta" "$C_AMAR" "$C_FIN"
        fi
    done
}

# ---------------------------------------------------------------------------
#  Rutas de sysfs que toca este paquete (para informar y para --uninstall)
# ---------------------------------------------------------------------------
RUTAS_SYSFS=(
    /sys/firmware/acpi/platform_profile
    /sys/class/platform-profile/platform-profile-0/profile
    /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
    /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
    /sys/bus/wmi/drivers/acer-wmi-battery/health_mode
    /sys/devices/system/cpu/intel_pstate/no_turbo
)

# ---------------------------------------------------------------------------
#  Desinstalar
# ---------------------------------------------------------------------------
desinstalar() {
    titulo "Desinstalando $APP_NOMBRE"
    [[ -n "$DESTDIR" ]] && info "DESTDIR = $DESTDIR"

    local objetivo
    for objetivo in \
        "$DIR_UDEV/$FICHERO_UDEV" \
        "$DIR_TMPFILES/$FICHERO_TMPFILES" \
        "$DIR_BIN/$APP_BIN" \
        "$DIR_DESKTOP/${APP_ID}.desktop" \
        "$DIR_ESQUEMAS/${APP_ID}.gschema.xml"
    do
        if [[ -e "${DESTDIR}${objetivo}" ]]; then
            # Sin el 'else' esto era una bomba: con 'set -e', un solo rm sin
            # permiso abortaba la desinstalacion y dejaba instalado todo lo
            # demas -- incluidas las reglas que abren /sys. Verificado.
            if rm -f "${DESTDIR}${objetivo}" 2>/dev/null; then
                ok "borrado ${objetivo}"
            else
                aviso_contado "NO se ha podido borrar ${objetivo}"
            fi
        fi
    done

    if [[ -d "${DESTDIR}${DIR_APP}" ]]; then
        if rm -rf "${DESTDIR}${DIR_APP:?}" 2>/dev/null; then
            ok "borrado ${DIR_APP}/"
        else
            aviso_contado "NO se ha podido borrar ${DIR_APP}/"
        fi
    fi

    # Iconos: solo los nuestros, por nombre exacto.
    if [[ -d "${DESTDIR}${DIR_ICONOS}" ]]; then
        while IFS= read -r -d '' icono; do
            if rm -f "$icono" 2>/dev/null; then
                ok "borrado ${icono#"$DESTDIR"}"
            else
                aviso_contado "NO se ha podido borrar ${icono#"$DESTDIR"}"
            fi
        # Ojo: "<APP_ID>.*" no casa con "<APP_ID>-symbolic.svg"; hacen falta los dos patrones.
        done < <(find "${DESTDIR}${DIR_ICONOS}" -type f \( -name "${APP_ID}.*" -o -name "${APP_ID}-*" \) -print0 2>/dev/null)
    fi

    # Extension
    local uuid
    if uuid="$(uuid_extension)" && [[ -n "$uuid" ]]; then
        if [[ -d "${DESTDIR}${DIR_EXTENSIONES}/${uuid}" ]]; then
            if rm -rf "${DESTDIR}${DIR_EXTENSIONES:?}/${uuid:?}" 2>/dev/null; then
                ok "borrada extension ${uuid}"
            else
                aviso_contado "NO se ha podido borrar la extension ${uuid}"
            fi
        fi
    else
        aviso_contado "Sin extension/metadata.json no se sabe que UUID borrar."
        aviso_contado "Mira a mano en ${DIR_EXTENSIONES}/"
    fi

    # Devolver sysfs a como estaba (0644 root:root). Solo en sistema real.
    if [[ -z "$DESTDIR" && "$(id -u)" -eq 0 ]]; then
        titulo "Devolviendo los permisos de sysfs a root"
        local ruta
        for ruta in "${RUTAS_SYSFS[@]}"; do
            if [[ -e "$ruta" ]]; then
                chgrp root "$ruta" 2>/dev/null || true
                chmod 0644  "$ruta" 2>/dev/null || true
                ok "$ruta -> 0644 root:root"
            fi
        done
        udevadm control --reload || true
        ok "udev recargado."
    elif [[ -z "$DESTDIR" ]]; then
        aviso_contado "Sin root no se han podido devolver los permisos de /sys."
        aviso_contado "Se arreglan solos al reiniciar, o ejecuta esto como root:"
        local ruta
        for ruta in "${RUTAS_SYSFS[@]}"; do
            aviso_contado "    chgrp root '$ruta' && chmod 0644 '$ruta'"
        done
    fi

    # Refrescar las caches del escritorio. Sin esto, la entrada de menu y el
    # icono seguian saliendo en el lanzador de aplicaciones (apuntando a un
    # binario que ya no existe) hasta que otro paquete regenerase las caches.
    if [[ -z "$DESTDIR" && "$(id -u)" -eq 0 ]]; then
        if command -v update-desktop-database >/dev/null; then
            update-desktop-database -q "$DIR_DESKTOP" 2>/dev/null || true
        fi
        if command -v gtk4-update-icon-cache >/dev/null; then
            gtk4-update-icon-cache -qtf "$DIR_ICONOS" 2>/dev/null || true
        fi
        if [[ -d "$DIR_ESQUEMAS" ]] && command -v glib-compile-schemas >/dev/null; then
            glib-compile-schemas "$DIR_ESQUEMAS" 2>/dev/null || true
        fi
        ok "Caches del escritorio actualizadas."
    fi

    printf '\n'
    if (( HUBO_AVISOS )); then
        aviso "Desinstalacion terminada con $HUBO_AVISOS aviso(s): ha quedado algo sin borrar."
        aviso "Repasa la lista de arriba; si son ficheros de /usr, repite con sudo."
    else
        ok "Desinstalado por completo."
    fi
    info "Si la extension estaba activa, cierra y abre sesion."
}

# ---------------------------------------------------------------------------
#  Ayuda
# ---------------------------------------------------------------------------
ayuda() {
    cat <<AYUDA
$APP_NOMBRE - instalador

  Uso:
    sudo $0                      Instala en el sistema
    sudo $0 --uninstall          Desinstala
    DESTDIR=/ruta $0             Instala en un arbol falso (sin root, sin tocar nada)
    sudo $0 --con-udev           Instala Y abre /sys al grupo 'wheel'
                                 (sin dialogo de contrasena; menos seguro)
    $0 --help                    Esta ayuda

  Variables:
    DESTDIR    Prefijo de destino para pruebas o para empaquetar. Si esta
               puesto, NO se recarga udev ni tmpfiles ni se toca /sys.
    PREFIX     Prefijo de instalacion. Por omision /usr.
    DIR_DMI    Directorio de identificacion del equipo. Por omision
               /sys/class/dmi/id. Solo sirve para probar el aviso de
               hardware no compatible sin tener otro portatil delante.

  Que instala:
    ${DIR_UDEV}/${FICHERO_UDEV}
    ${DIR_TMPFILES}/${FICHERO_TMPFILES}
    ${DIR_APP}/gekkonitro/
    ${DIR_BIN}/${APP_BIN}
    ${DIR_DESKTOP}/${APP_ID}.desktop
    ${DIR_ICONOS}/<tamano>/apps/${APP_ID}.*
    ${DIR_ESQUEMAS}/${APP_ID}.gschema.xml   (si existe)
    \$HOME/.local/share/gnome-shell/extensions/<uuid>/

  Los dos primeros dan escritura al grupo 'wheel' sobre seis rutas de /sys.
  Lee packaging/SEGURIDAD.md antes de instalarlo: explica exactamente que se
  abre y que puede hacer con ello un proceso que corra como tu usuario.
AYUDA
}

# ---------------------------------------------------------------------------
#  Principal
# ---------------------------------------------------------------------------
main() {
    local accion="instalar"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall|--desinstalar) accion="desinstalar" ;;
            --con-udev)                CON_UDEV=1 ;;
            -h|--help|--ayuda)         ayuda; exit 0 ;;
            *) error "Opcion desconocida: $1"; ayuda; exit 2 ;;
        esac
        shift
    done

    detectar_usuario

    printf '%s%s%s  (%s)\n' "$C_NEG" "$APP_NOMBRE" "$C_FIN" "$APP_ID"
    info "Proyecto : $RAIZ"
    info "Usuario  : $USUARIO  (HOME $HOME_USUARIO)"

    # Desinstalar del sistema real necesita root igual que instalar. Antes no
    # se comprobaba: sin sudo, el primer rm de /usr fallaba y la desinstalacion
    # se paraba ahi dejando puestas las reglas que abren /sys, con la persona
    # convencida de haberlas quitado.
    if [[ "$accion" == "desinstalar" ]]; then
        if [[ -z "$DESTDIR" && "$(id -u)" -ne 0 ]]; then
            error "Para desinstalar del sistema hace falta root."
            error "    sudo $0 --uninstall"
            exit 1
        fi
        desinstalar
        exit 0
    fi

    # Root obligatorio solo si se va a tocar el sistema de verdad.
    if [[ -z "$DESTDIR" && "$(id -u)" -ne 0 ]]; then
        error "Para instalar en el sistema hace falta root."
        error "    sudo $0"
        error "O prueba sin tocar nada:"
        error "    DESTDIR=/tmp/prueba-nitro-gekko $0"
        exit 1
    fi

    comprobar_hardware
    comprobar_modulo
    comprobar_grupo_wheel
    instalar
    recargar

    titulo "Resumen"
    if (( HUBO_AVISOS )); then
        aviso "Terminado con $HUBO_AVISOS aviso(s). Leelos antes de dar por bueno esto."
    else
        ok "Terminado sin avisos."
    fi
    if [[ -z "$DESTDIR" ]]; then
        info "Lanza la aplicacion con: $APP_BIN"
        info "Si el limite de carga de bateria sale como no disponible tras"
        info "reiniciar, fuerza la carga temprana del modulo:"
        info "    echo acer_wmi_battery | sudo tee /etc/modules-load.d/acer-wmi-battery.conf"
    fi
}

main "$@"
