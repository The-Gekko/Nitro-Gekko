#!/usr/bin/env bash
#
# Prepara el Acer Nitro AN17-51 para que Nitro Gekko tenga algo que controlar.
#
# install.sh instala la APLICACION.  Este script prepara el HARDWARE: sin el,
# en un Arch recien instalado la mitad de la app aparece en gris porque las
# rutas de /sys ni siquiera existen.
#
# Cada paso dice QUE hace, POR QUE, y como deshacerlo.  Nada se aplica en
# silencio y todo es reversible.
#
#   sudo ./preparar-sistema.sh              aplica lo que falte
#   sudo ./preparar-sistema.sh --revisar    solo diagnostica, no toca nada
#   sudo ./preparar-sistema.sh --revertir   deshace lo que puso este script
#
set -uo pipefail

MODO="aplicar"
case "${1:-}" in
    --revisar|-n|--dry-run) MODO="revisar" ;;
    --revertir|--uninstall) MODO="revertir" ;;
    -h|--help)
        sed -n '2,14p' "$0" | sed 's/^# \?//'
        exit 0 ;;
    "") ;;
    *) echo "Opcion desconocida: $1"; exit 1 ;;
esac

if [[ -t 1 ]]; then V=$'\033[32m'; R=$'\033[31m'; A=$'\033[33m'; C=$'\033[36m'; N=$'\033[1m'; F=$'\033[0m'
else V=; R=; A=; C=; N=; F=; fi
titulo(){ echo; echo "${N}${C}$*${F}"; }
ok(){   echo "  ${V}ok${F}    $*"; }
falta(){ echo "  ${A}falta${F} $*"; }
mal(){  echo "  ${R}mal${F}   $*"; }
info(){ echo "        $*"; }

CAMBIOS=0
PENDIENTE_REINICIO=0

[[ $EUID -eq 0 || "$MODO" == "revisar" ]] || {
    echo "Hace falta root.  Usa:  sudo $0   (o --revisar para solo diagnosticar)"
    exit 1
}

# ---------------------------------------------------------------------------
titulo "0. ¿Es este el portatil correcto?"
# ---------------------------------------------------------------------------
PRODUCTO="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo desconocido)"
VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo desconocido)"
info "$VENDOR $PRODUCTO"
if [[ "$PRODUCTO" == "Nitro AN17-51" ]]; then
    ok "modelo exacto para el que se escribio esto"
elif [[ "$VENDOR" == "Acer" ]]; then
    falta "Acer pero no AN17-51: puede funcionar, puede que no. Continua bajo tu criterio."
else
    mal "no es un Acer. Esto no te va a servir de nada."
    [[ "$MODO" == "aplicar" ]] && { echo; echo "Abortado."; exit 1; }
fi

# ---------------------------------------------------------------------------
titulo "1. acer_wmi con predator_v4=1  —  perfiles termicos y tacometros"
# ---------------------------------------------------------------------------
# El AN17-51 NO esta en la tabla de quirks DMI de acer-wmi, asi que por defecto
# el driver no registra ni platform_profile ni el hwmon de los ventiladores.
# El parametro predator_v4=1 fuerza el quirk y en este modelo funciona: las
# escrituras a platform_profile se aceptan y aparecen fan1_input/fan2_input.
CONF_ACER=/etc/modprobe.d/acer-wmi.conf
if [[ -f "$CONF_ACER" ]] && grep -q "predator_v4=1" "$CONF_ACER"; then
    ok "$CONF_ACER ya lo tiene"
else
    falta "$CONF_ACER sin predator_v4=1"
    if [[ "$MODO" == "aplicar" ]]; then
        printf '# Nitro Gekko: el AN17-51 no esta en la tabla de quirks DMI de\n# acer-wmi, asi que hay que forzar el quirk para tener platform_profile\n# (5 perfiles termicos) y el hwmon con las RPM de los ventiladores.\noptions acer_wmi predator_v4=1\n' > "$CONF_ACER"
        ok "escrito $CONF_ACER"
        CAMBIOS=1
    elif [[ "$MODO" == "revertir" ]]; then
        :
    fi
fi
if [[ "$MODO" == "revertir" && -f "$CONF_ACER" ]]; then
    rm -f "$CONF_ACER" && ok "borrado $CONF_ACER" && PENDIENTE_REINICIO=1
fi

if [[ -e /sys/firmware/acpi/platform_profile ]]; then
    ok "platform_profile activo: $(cat /sys/firmware/acpi/platform_profile)"
    info "perfiles: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null)"
else
    falta "platform_profile NO existe todavia"
    if [[ "$MODO" == "aplicar" ]]; then
        info "recargando acer_wmi..."
        modprobe -r acer_wmi 2>/dev/null
        # modprobe -r arrastra las dependencias sin usuarios (sparse_keymap);
        # se recargan explicitamente por si acaso.
        modprobe sparse_keymap 2>/dev/null
        modprobe acer_wmi predator_v4=1 2>/dev/null
        sleep 2
        if [[ -e /sys/firmware/acpi/platform_profile ]]; then
            ok "platform_profile creado: $(cat /sys/firmware/acpi/platform_profile)"
            CAMBIOS=1
        else
            mal "sigue sin aparecer. Mira:  dmesg | grep -i acer"
        fi
    fi
fi

HW_ACER=""
for d in /sys/class/hwmon/hwmon*; do
    [[ "$(cat "$d/name" 2>/dev/null)" == acer ]] && HW_ACER="$d"
done
if [[ -n "$HW_ACER" ]]; then
    ok "tacometros: fan1=$(cat "$HW_ACER/fan1_input" 2>/dev/null) rpm  fan2=$(cat "$HW_ACER/fan2_input" 2>/dev/null) rpm"
else
    falta "sin hwmon 'acer': no habra lectura de ventiladores"
fi

# ---------------------------------------------------------------------------
titulo "2. acer-wmi-battery  —  limite de carga al 80 %"
# ---------------------------------------------------------------------------
# No esta en el kernel: viene del AUR (acer-wmi-battery-dkms-git). El parche
# para subirlo a mainline va por la revision v6 (agosto 2026) y su tabla DMI
# NO incluye el AN17-51, asi que de momento el DKMS es la unica via.
if [[ -e /sys/bus/wmi/drivers/acer-wmi-battery/health_mode ]]; then
    ok "health_mode disponible (valor actual: $(cat /sys/bus/wmi/drivers/acer-wmi-battery/health_mode))"
    info "temperatura de bateria: $(( $(cat /sys/bus/wmi/drivers/acer-wmi-battery/temperature 2>/dev/null || echo 0) / 1000 )) C"
else
    falta "sin acer-wmi-battery: la app no podra tocar el limite de carga"
    info "Instalalo desde AUR:   yay -S acer-wmi-battery-dkms-git"
    info "Y asegura la carga temprana:"
    info "   echo acer_wmi_battery | sudo tee /etc/modules-load.d/acer-wmi-battery.conf"
fi

# Carga temprana: sin esto, tras un reinicio el modulo puede no estar cargado
# cuando arranca la app y el limite de bateria sale como no disponible.
CONF_CARGA=/etc/modules-load.d/acer-wmi-battery.conf
if [[ -e /sys/bus/wmi/drivers/acer-wmi-battery/health_mode ]]; then
    if [[ -f "$CONF_CARGA" ]]; then
        ok "carga temprana configurada"
    else
        falta "sin carga temprana del modulo de bateria"
        if [[ "$MODO" == "aplicar" ]]; then
            echo acer_wmi_battery > "$CONF_CARGA" && ok "escrito $CONF_CARGA" && CAMBIOS=1
        fi
    fi
fi
[[ "$MODO" == "revertir" && -f "$CONF_CARGA" ]] && rm -f "$CONF_CARGA" && ok "borrado $CONF_CARGA"

# ---------------------------------------------------------------------------
titulo "3. PL1 a 45 W  —  el ruido sostenido"
# ---------------------------------------------------------------------------
# El firmware de Acer fija PL1 en 65 W (MSR) / 70 W (MMIO) sobre un TDP nominal
# de 45 W. Medido en este equipo: con 65 W la carga sostenida a 16 hilos se
# queda en 63 W y 85 C; con 45 W baja a 41,9 W y 66 C, sin throttling.
# Ademas el firmware REESCRIBE el PL1 por MMIO cada vez que cambia el perfil
# (performance -> 100 W), pero el valor del MSR sobrevive y es el que manda.
UNIDAD=/etc/systemd/system/rapl-pl1.service
PL1_ACTUAL=$(( $(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null || echo 0) / 1000000 ))
info "PL1 actual: ${PL1_ACTUAL} W  (nominal del chip: $(( $(cat /sys/class/powercap/intel-rapl:0/constraint_0_max_power_uw 2>/dev/null || echo 0) / 1000000 )) W)"
if [[ "$MODO" == "revertir" ]]; then
    if [[ -f "$UNIDAD" ]]; then
        systemctl disable --now rapl-pl1.service >/dev/null 2>&1
        rm -f "$UNIDAD"; systemctl daemon-reload
        ok "rapl-pl1.service eliminado (el PL1 vuelve al valor del firmware al reiniciar)"
    fi
elif systemctl is-enabled rapl-pl1.service >/dev/null 2>&1; then
    ok "rapl-pl1.service ya activo"
else
    falta "sin limite de PL1: la CPU puede quemar 65 W sostenidos"
    if [[ "$MODO" == "aplicar" ]]; then
        cat > "$UNIDAD" <<'UNIT'
[Unit]
Description=Limitar PL1 de la CPU a 45W (TDP nominal del i7-13620H; el firmware Acer lo pone en 65W/70W)
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 45000000 > /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw || true'
ExecStart=/bin/sh -c 'echo 45000000 > /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw || true'

[Install]
WantedBy=multi-user.target
WantedBy=suspend.target
WantedBy=hibernate.target
WantedBy=hybrid-sleep.target
UNIT
        systemctl daemon-reload
        systemctl enable --now rapl-pl1.service >/dev/null 2>&1
        sleep 1
        NUEVO=$(( $(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw) / 1000000 ))
        if [[ "$NUEVO" -le 45 ]]; then
            ok "PL1 fijado a ${NUEVO} W y persistido"
            CAMBIOS=1
        else
            mal "la escritura no cuajo (PL1 sigue en ${NUEVO} W): ¿bloqueado por BIOS?"
        fi
    fi
fi

# ---------------------------------------------------------------------------
titulo "4. power-profiles-daemon  —  la trampa del perfil pegado"
# ---------------------------------------------------------------------------
# PPD 0.30 guarda el perfil en /var/lib/power-profiles-daemon/state.ini y lo
# RESTAURA en cada arranque. Un 'powerprofilesctl set performance' que no se
# libere (por ejemplo, un hook de gamemode que use 'set' en vez de 'launch')
# deja la maquina en performance para siempre, entre reinicios incluidos.
# Con predator_v4 activo eso ademas pone el EC en su curva mas ruidosa:
# medido, 3237 rpm frente a 1661 en 'quiet', para ganar 1 grado.
if ! systemctl is-active power-profiles-daemon >/dev/null 2>&1; then
    falta "power-profiles-daemon no esta activo"
    info "Instalalo con:  sudo pacman -S power-profiles-daemon"
else
    ok "power-profiles-daemon activo"
    DRV="$(powerprofilesctl list 2>/dev/null | grep -m1 PlatformDriver | awk '{print $2}')"
    if [[ "$DRV" == "platform_profile" ]]; then
        ok "PPD controla el EC (PlatformDriver: platform_profile)"
    else
        falta "PPD no ve el driver de plataforma (PlatformDriver: ${DRV:-ninguno})"
        info "Sin esto el menu de energia de GNOME solo cambia el EPP de la CPU,"
        info "no la curva del ventilador. Se arregla con el paso 1."
    fi
    ESTADO=/var/lib/power-profiles-daemon/state.ini
    if grep -q "Profile=performance" "$ESTADO" 2>/dev/null; then
        falta "PPD esta PEGADO en 'performance' y lo restaurara en cada arranque"
        if [[ "$MODO" == "aplicar" ]]; then
            powerprofilesctl set balanced 2>/dev/null && ok "cambiado a 'balanced'" && CAMBIOS=1
        fi
    else
        ok "perfil guardado: $(grep -m1 Profile "$ESTADO" 2>/dev/null || echo '?')"
    fi
fi

# gamemode: el hook con 'set' es el que deja el perfil pegado.
GM="$(getent passwd "${SUDO_USER:-${PKEXEC_UID:+$(id -nu "$PKEXEC_UID")}}" 2>/dev/null | cut -d: -f6)/.config/gamemode.ini"
# Se ignoran las lineas de comentario (# y ;): el propio fichero puede explicar
# en un comentario por que se quito ese hook, y eso no es un problema.
if [[ -f "$GM" ]] && grep -vE '^\s*[#;]' "$GM" 2>/dev/null | grep -q "powerprofilesctl set"; then
    falta "$GM usa 'powerprofilesctl set' en un hook"
    info "'set' es permanente: si el juego crashea, el perfil se queda en"
    info "performance para siempre. Usa esto en las opciones de Steam:"
    info "   powerprofilesctl launch -p performance -- gamemoderun %command%"
fi

# ---------------------------------------------------------------------------
titulo "5. Extension de GNOME Shell"
# ---------------------------------------------------------------------------
USUARIO="${SUDO_USER:-}"
[[ -z "$USUARIO" && -n "${PKEXEC_UID:-}" ]] && USUARIO="$(id -nu "$PKEXEC_UID" 2>/dev/null)"
[[ -z "$USUARIO" ]] && USUARIO="$(logname 2>/dev/null || true)"
if [[ -n "$USUARIO" ]]; then
    HOME_U="$(getent passwd "$USUARIO" | cut -d: -f6)"
    EXT="$HOME_U/.local/share/gnome-shell/extensions/nitro-gekko@thegekko.dev"
    if [[ -d "$EXT" ]]; then
        ok "extension instalada"
        if runuser -u "$USUARIO" -- gnome-extensions list --enabled 2>/dev/null | grep -q nitro-gekko; then
            ok "y activada"
        else
            falta "instalada pero NO activada"
            info "Actívala con:   gnome-extensions enable nitro-gekko@thegekko.dev"
            info "En Wayland hay que cerrar y volver a abrir sesion."
        fi
    else
        falta "extension no instalada (la pone install.sh)"
    fi
fi

# ---------------------------------------------------------------------------
titulo "6. Teclado RGB y boton de la marca"
# ---------------------------------------------------------------------------
BASE_WMI=/sys/devices/platform/acer-wmi
if [[ -d "$BASE_WMI/four_zoned_kb" ]]; then
    ok "teclado RGB de 4 zonas disponible (driver linuwu_sense)"
    info "colores actuales: $(cat "$BASE_WMI/four_zoned_kb/per_zone_mode" 2>/dev/null)"
    T="$(cat "$BASE_WMI/nitro_sense/backlight_timeout" 2>/dev/null)"
    [[ "$T" == "0" ]] && info "retroiluminacion: siempre encendida" \
                      || info "retroiluminacion: se apaga sola por inactividad"
else
    falta "sin RGB: falta el driver linuwu_sense"
    info "Instalalo con:  sudo ./packaging/instalar-rgb.sh"
fi

# El boton con el logo de la marca (el que en Windows abre NitroSense) emite
# KEY_PRESENTATION (evdev 425, scancode 0xf5) desde el teclado i8042. En
# GNOME el atajo se llama XF86Presentation.
if [[ -n "${USUARIO:-}" ]]; then
    RUTA_ATAJO=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/nitro-gekko/
    ESQ="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${RUTA_ATAJO}"
    ACTUAL="$(runuser -u "$USUARIO" -- gsettings get "$ESQ" command 2>/dev/null || echo "''")"
    if [[ "$ACTUAL" == "'nitro-gekko'" ]]; then
        ok "el boton de la marca abre Nitro Gekko"
    else
        falta "el boton de la marca no esta asignado"
        if [[ "$MODO" == "aplicar" ]]; then
            LISTA="$(runuser -u "$USUARIO" -- gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null)"
            if [[ "$LISTA" != *"custom-keybindings/nitro-gekko"* ]]; then
                NUEVA="${LISTA%]}"
                [[ "$NUEVA" == "@as [" || "$NUEVA" == "[" ]] && NUEVA="['$RUTA_ATAJO']" \
                    || NUEVA="${NUEVA}, '${RUTA_ATAJO}']"
                runuser -u "$USUARIO" -- gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$NUEVA" 2>/dev/null
            fi
            runuser -u "$USUARIO" -- gsettings set "$ESQ" name 'Abrir Nitro Gekko' 2>/dev/null
            runuser -u "$USUARIO" -- gsettings set "$ESQ" command 'nitro-gekko' 2>/dev/null
            runuser -u "$USUARIO" -- gsettings set "$ESQ" binding 'XF86Presentation' 2>/dev/null
            ok "boton de la marca -> nitro-gekko"
            CAMBIOS=1
        fi
    fi
fi

# ---------------------------------------------------------------------------
titulo "Resumen"
# ---------------------------------------------------------------------------
case "$MODO" in
    revisar)  echo "  Modo revision: no se ha tocado nada." ;;
    revertir) echo "  Revertido lo que este script habia puesto." ;;
    aplicar)
        if (( CAMBIOS )); then
            echo "  Se aplicaron cambios.  Vuelve a lanzarlo con --revisar para confirmar."
        else
            echo "  Todo estaba ya en su sitio.  Nada que hacer."
        fi ;;
esac
(( PENDIENTE_REINICIO )) && echo "  ${A}Hay cambios que necesitan reiniciar para surtir efecto.${F}"
echo
echo "  Lanza la aplicacion con:  nitro-gekko"
