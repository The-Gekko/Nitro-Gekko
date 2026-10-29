#!/usr/bin/env bash
#
# Prepara el Acer Nitro AN17-51 para que Nitro Gekko tenga algo que controlar.
#
# install.sh instala la APLICACION.  Este script prepara el HARDWARE: sin el,
# en un sistema recien instalado la mitad de la app aparece en gris porque las
# rutas de /sys ni siquiera existen.
#
# Cada paso dice QUE hace, POR QUE, y como deshacerlo.  Nada se aplica en
# silencio y todo es reversible.
#
#   sudo ./packaging/preparar-sistema.sh              aplica lo que falte
#        ./packaging/preparar-sistema.sh --revisar    solo diagnostica, no
#                                                     toca nada y no pide root
#   sudo ./packaging/preparar-sistema.sh --revertir   deshace lo que puso
#
#   (--revisar tambien acepta -n y --dry-run; --revertir acepta --uninstall)
#
# Codigos de salida:  0 bien   1 abortado (no es un Acer, o falta root)   2 opcion
# desconocida.  Son los mismos que usan install.sh, instalar-rgb.sh y probar-rgb.sh.
#
# Variables para PROBARLO sin tener otro portatil delante (solo con --revisar):
#   DIR_DMI        directorio de identificacion del equipo.  Por omision
#                  /sys/class/dmi/id.  Sirve para ver que dice este script en un
#                  equipo que no es un Acer, o en un Acer que no es el AN17-51.
#   DIR_POWERCAP   directorio de la interfaz RAPL.  Por omision
#                  /sys/class/powercap.  Sirve para ver el paso 3 en un equipo
#                  sin RAPL de Intel (cualquier Nitro con CPU AMD, por ejemplo).
#   OS_RELEASE     fichero os-release.  Por omision /etc/os-release.  Sirve
#                  para ver los avisos de una distribucion desde otra.
#
# Vale para Arch, Solus y Ubuntu.  Lo que cambia entre ellas son las ordenes
# que se sugieren (pacman, eopkg o apt) y, en Solus y Ubuntu, que el driver del
# RGB lleva una red de seguridad que usa el predator_v4=1 del paso 1.
#
set -uo pipefail

MODO="aplicar"
case "${1:-}" in
    --revisar|-n|--dry-run) MODO="revisar" ;;
    --revertir|--uninstall) MODO="revertir" ;;
    -h|--help|--ayuda)
        # Cabecera de comentarios completa, hasta la primera linea que no lo
        # sea: asi la ayuda no se descuadra al editar el encabezado.
        awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
        exit 0 ;;
    "") ;;
    # Codigo 2, igual que install.sh / instalar-rgb.sh / probar-rgb.sh.  Este
    # script escribe en /etc y recarga modulos: no puede ponerse a hacerlo por
    # haber escrito mal un argumento.
    *) echo "Opcion desconocida: $1  (prueba $0 --help)" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    echo "Sobran argumentos: $*  (prueba $0 --help)" >&2
    exit 2
fi

if [[ -t 1 ]]; then V=$'\033[32m'; R=$'\033[31m'; A=$'\033[33m'; C=$'\033[36m'; N=$'\033[1m'; F=$'\033[0m'
else V=; R=; A=; C=; N=; F=; fi
titulo(){ echo; echo "${N}${C}$*${F}"; }
ok(){   echo "  ${V}ok${F}    $*"; }
falta(){ echo "  ${A}falta${F} $*"; }
mal(){  echo "  ${R}mal${F}   $*"; }
info(){ echo "        $*"; }

CAMBIOS=0
PENDIENTE_REINICIO=0

# Arch, Solus o Ubuntu, las distribuciones que mantiene el proyecto.  Decide
# que orden se sugiere en los avisos (pacman, eopkg o apt) y si el driver del
# RGB lleva red de seguridad.  OS_RELEASE permite ver los avisos de otra sin
# tenerla delante (solo con --revisar).
DISTRO="$(
    f="${OS_RELEASE:-/etc/os-release}"
    case " $(sed -n 's/^ID=//p; s/^ID_LIKE=//p' "$f" 2>/dev/null | tr -d '"' | tr '\n' ' ') " in
        *" solus "*)  echo solus ;;
        *" arch "*)   echo arch ;;
        *" ubuntu "*) echo ubuntu ;;
        *)            echo otra ;;
    esac
)"
# En Solus y en Ubuntu la lista negra de acer_wmi lleva una linea 'install'
# que, si linuwu_sense no carga, carga acer_wmi: la red de seguridad (en
# Solus porque no hay DKMS; en Ubuntu, sobre todo, por Secure Boot).  Y lo que
# le da los perfiles a ese acer_wmi es el predator_v4=1 del paso 1.
RED_SEGURIDAD=0
[[ "$DISTRO" == solus || "$DISTRO" == ubuntu ]] && RED_SEGURIDAD=1

[[ $EUID -eq 0 || "$MODO" == "revisar" ]] || {
    echo "Hace falta root.  Usa:  sudo $0   (o --revisar para solo diagnosticar)"
    exit 1
}

# ---------------------------------------------------------------------------
#  Quien es la persona que esta delante
#
#  El script corre como root por sudo, pero la extension de GNOME Shell y el
#  atajo de teclado viven en la sesion del USUARIO, no en la de root.  Se
#  resuelve una sola vez, aqui, y se usa en todos los pasos.
# ---------------------------------------------------------------------------
USUARIO="${SUDO_USER:-}"
[[ -z "$USUARIO" && -n "${PKEXEC_UID:-}" ]] && USUARIO="$(id -nu "$PKEXEC_UID" 2>/dev/null)"
[[ -z "$USUARIO" && $EUID -ne 0 ]] && USUARIO="$(id -un)"
[[ -z "$USUARIO" ]] && USUARIO="$(logname 2>/dev/null || true)"
UID_USUARIO="$(id -u "$USUARIO" 2>/dev/null || true)"

# Ejecuta un comando EN LA SESION del usuario.
#
# Dos trampas, las dos comprobadas:
#
#   1. `runuser` SOLO lo puede usar root ("no pueden utilizarlo usuarios
#      distintos de root").  Con --revisar sin sudo todas las llamadas
#      fallaban, y como iban con 2>/dev/null el script daba por no activada
#      una extension que si lo estaba y por no asignado un atajo que si lo
#      estaba.  Si ya somos el usuario, se ejecuta directamente.
#
#   2. dconf LEE del fichero pero para ESCRIBIR necesita el bus de sesion.
#      Sin DBUS_SESSION_BUS_ADDRESS intenta 'dbus-launch --autolaunch' y
#      falla con codigo 1.  sudo limpia esa variable, asi que los
#      `gsettings set` de mas abajo no hacian nada -- y el script imprimia
#      igualmente "ok  boton de la marca -> nitro-gekko".  Se le pasa el bus
#      del usuario explicitamente.
como_usuario() {
    [[ -n "$USUARIO" ]] || return 1
    if [[ "$(id -un)" == "$USUARIO" ]]; then
        "$@"
    else
        runuser -u "$USUARIO" -- env \
            XDG_RUNTIME_DIR="/run/user/${UID_USUARIO}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_USUARIO}/bus" \
            "$@"
    fi
}

# ¿Esta delante en Hyprland?  Lo usan el paso 5 (el aviso de modo que en GNOME
# da la extension) y el 6 (el atajo del boton de la marca): en los dos, lo que
# en GNOME pone o mira este script, en Hyprland es una linea de SU
# configuracion.
HYPRLAND=0
[[ -n "$USUARIO" ]] && pgrep -u "$USUARIO" -x Hyprland >/dev/null && HYPRLAND=1

# ---------------------------------------------------------------------------
titulo "0. ¿Es este el portatil correcto?"
# ---------------------------------------------------------------------------
DIR_DMI="${DIR_DMI:-/sys/class/dmi/id}"
PRODUCTO="$(cat "$DIR_DMI/product_name" 2>/dev/null || echo desconocido)"
VENDOR="$(cat "$DIR_DMI/sys_vendor" 2>/dev/null || echo desconocido)"
info "$VENDOR $PRODUCTO"
if [[ "$PRODUCTO" == "Nitro AN17-51" ]]; then
    ok "modelo exacto para el que se escribio esto"
elif [[ "$VENDOR" == "Acer" ]]; then
    falta "Acer pero no AN17-51: puede funcionar, puede que no. Continua bajo tu criterio."
    info "Todo lo que este script mide y decide sale del AN17-51 (i7-13620H)."
    info "Lo unico que se adapta solo a tu equipo es el PL1 del paso 3, que se"
    info "toma de la potencia base que declara TU chip.  El resto -el quirk"
    info "predator_v4 del paso 1 y el atajo del paso 6- puede no encajar."
    info "Pasa primero --revisar y lee lo que haria antes de dejarle escribir."
else
    mal "no es un Acer. Esto no te va a servir de nada."
    [[ "$MODO" == "aplicar" ]] && { echo; echo "Abortado."; exit 1; }
fi

# ---------------------------------------------------------------------------
titulo "1. Driver de plataforma  —  perfiles termicos y tacometros"
# ---------------------------------------------------------------------------
# Hacen falta platform_profile y el hwmon 'acer'.  Hay DOS drivers que los dan,
# y son EXCLUYENTES porque reclaman los mismos GUID de WMI:
#
#   linuwu_sense            lo instala packaging/instalar-rgb.sh por DKMS.  Da
#                           lo mismo que acer_wmi y ademas el teclado RGB de 4
#                           zonas.  Es el que usa este proyecto, y deja
#                           acer_wmi en la lista negra.
#   acer_wmi predator_v4=1  la alternativa, sin RGB.  El AN17-51 no esta en la
#                           tabla de quirks DMI de acer-wmi, asi que sin ese
#                           parametro el driver no registra ni platform_profile
#                           ni el hwmon de los ventiladores.
#
# Por eso este paso NO fuerza acer_wmi cuando linuwu_sense ya esta al mando:
# escribir /etc/modprobe.d/acer-wmi.conf seria papel mojado (el modulo esta en
# la lista negra) y recargarlo a la fuerza le quitaria los GUID a linuwu_sense.
CONF_ACER=/etc/modprobe.d/acer-wmi.conf
COPIA_ACER="${CONF_ACER}.antes-de-nitro-gekko"
# Marca para saber DESPUES si la linea la pusimos nosotros o ya estaba ahi.
MARCA_ACER='# puesto-por-nitro-gekko'

DRIVER=""
if [[ -d /sys/module/linuwu_sense ]]; then
    DRIVER="linuwu_sense"
elif [[ -d /sys/module/acer_wmi ]]; then
    DRIVER="acer_wmi"
fi

# EN SOLUS Y EN UBUNTU ES DISTINTO: alli el fichero NO es inerte con
# linuwu_sense al mando.  Su lista negra lleva una red de seguridad que, si
# linuwu_sense no carga (kernel nuevo sin compilar, o en Ubuntu la clave de
# Secure Boot sin enrolar), carga acer_wmi, y lo que le da los perfiles es
# este predator_v4=1.  Antes este paso se lo saltaba al ver linuwu_sense, y
# tras una desinstalacion a medias el RGB ya no se dejaba reinstalar
# (comprobado en Solus el 2026-09-25).
if [[ "$DRIVER" == "linuwu_sense" ]] && (( ! RED_SEGURIDAD )); then
    ok "driver al mando: linuwu_sense  (lo instala instalar-rgb.sh; incluye el RGB)"
    info "acer_wmi no se toca: linuwu_sense lo sustituye y lo deja en lista negra."
    [[ -f "$CONF_ACER" ]] && \
        info "$CONF_ACER existe, pero es inerte mientras linuwu_sense este cargado."
elif [[ -f "$CONF_ACER" ]] && grep -q "predator_v4=1" "$CONF_ACER"; then
    ok "$CONF_ACER ya lo tiene"
    [[ "$DRIVER" == "linuwu_sense" ]] && \
        info "linuwu_sense al mando; aqui este fichero es el de la red de seguridad del RGB."
else
    falta "$CONF_ACER sin predator_v4=1"
    [[ "$DRIVER" == "linuwu_sense" ]] && \
        info "Aqui hace falta aunque mande linuwu_sense: es lo que usa la red de seguridad del RGB."
    if [[ "$MODO" == "aplicar" ]]; then
        # OJO: aqui habia un '>' a secas.  /etc/modprobe.d/acer-wmi.conf es un
        # nombre generico que puede existir ya con opciones puestas por la
        # persona o por su distribucion (force_series=, brightness=...), y ese
        # '>' las borraba en silencio.  Ahora se guarda una copia y se ANADE.
        if [[ -f "$CONF_ACER" ]]; then
            if [[ ! -f "$COPIA_ACER" ]]; then
                cp -a "$CONF_ACER" "$COPIA_ACER" && info "copia de lo que habia en $COPIA_ACER"
            fi
            printf '\n' >> "$CONF_ACER"
        fi
        # Solus es stateless: un /etc recien instalado casi no trae nada, y
        # un directorio de /etc puede no existir hasta que alguien lo crea.
        install -d "$(dirname "$CONF_ACER")"
        {
            printf '%s\n' "$MARCA_ACER"
            printf '%s\n' '# El AN17-51 no esta en la tabla de quirks DMI de acer-wmi, asi que hay que'
            printf '%s\n' '# forzar el quirk para tener platform_profile (5 perfiles termicos) y el'
            printf '%s\n' '# hwmon con las RPM de los ventiladores.'
            printf '%s\n' '#'
            printf '%s\n' '# Si instalas el teclado RGB (packaging/instalar-rgb.sh), linuwu_sense pasa'
            printf '%s\n' '# a sustituir a acer_wmi y este fichero se queda inerte.  En Solus y en'
            printf '%s\n' '# Ubuntu no: lo usa la red de seguridad del RGB si linuwu_sense no carga.'
            printf '%s\n' '# Para quitarlo:  sudo ./packaging/preparar-sistema.sh --revertir'
            printf '%s\n' 'options acer_wmi predator_v4=1'
        } >> "$CONF_ACER"
        ok "escrito $CONF_ACER"
        CAMBIOS=1
        # En Ubuntu el initramfs lo hace dracut y lleva una copia de
        # /etc/modprobe.d.  Si acer_wmi viajara dentro, en el arranque se
        # cargaria con la copia vieja, SIN predator_v4=1, y no habria perfiles
        # aunque este fichero lo diga.  Se mira y solo se regenera si lo lleva.
        if [[ "$DISTRO" == ubuntu ]] && command -v lsinitrd >/dev/null \
           && grep -q 'acer-wmi\.ko' < <(lsinitrd "/boot/initrd.img-$(uname -r)" 2>/dev/null); then
            info "acer_wmi va dentro del initramfs: regenerandolo para que lleve predator_v4=1..."
            update-initramfs -u -k "$(uname -r)" >/dev/null 2>&1 && ok "initramfs regenerado" \
                || mal "no se pudo regenerar:  sudo update-initramfs -u"
        fi
    fi
fi
if [[ "$MODO" == "revertir" ]]; then
    # Solo se borra lo que pusimos NOSOTROS.  Un 'rm -f' incondicional se
    # llevaba por delante las opciones de acer_wmi que hubiera antes.
    # Y en Solus y Ubuntu, no mientras siga el driver del RGB: sin este fichero
    # su red de seguridad cargaria un acer_wmi sin perfiles (regla 25 del
    # README).
    if (( RED_SEGURIDAD )) && [[ -f /etc/modprobe.d/nitro-gekko-rgb.conf ]]; then
        falta "$CONF_ACER se deja: el driver del RGB sigue instalado y lo necesita"
        info "Revierte antes el RGB:  sudo ./packaging/instalar-rgb.sh --revertir"
    elif [[ -f "$COPIA_ACER" ]]; then
        mv -f "$COPIA_ACER" "$CONF_ACER" && ok "restaurado $CONF_ACER tal como estaba" \
            && PENDIENTE_REINICIO=1
    elif [[ -f "$CONF_ACER" ]] && grep -qF "$MARCA_ACER" "$CONF_ACER"; then
        rm -f "$CONF_ACER" && ok "borrado $CONF_ACER" && PENDIENTE_REINICIO=1
    elif [[ -f "$CONF_ACER" ]] && grep -q "predator_v4=1" "$CONF_ACER"; then
        # Escrito por una version anterior de este script (sin marca) o a mano.
        rm -f "$CONF_ACER" && ok "borrado $CONF_ACER (solo tenia predator_v4)" \
            && PENDIENTE_REINICIO=1
    elif [[ -f "$CONF_ACER" ]]; then
        falta "$CONF_ACER existe pero no lo escribimos nosotros: se deja como esta"
        info "Si de verdad lo quieres fuera:  sudo rm $CONF_ACER"
    else
        info "$CONF_ACER no estaba"
    fi
fi

if [[ -e /sys/firmware/acpi/platform_profile ]]; then
    ok "platform_profile activo: $(cat /sys/firmware/acpi/platform_profile)"
    info "perfiles: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null)"
elif [[ "$DRIVER" == "linuwu_sense" ]]; then
    mal "linuwu_sense cargado pero sin platform_profile. Mira:  dmesg | grep -i linuwu"
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
    # La lectura es milesimas de grado (33000 = 33,0 C).  Pero el EC devuelve
    # basura de vez en cuando: en una ejecucion real de este script salio
    # "temperatura de bateria: -247 C", que esta por debajo del cero absoluto.
    # Se comprueba el rango en vez de imprimir lo que sea.
    TEMP_BAT="$(cat /sys/bus/wmi/drivers/acer-wmi-battery/temperature 2>/dev/null || true)"
    if [[ "$TEMP_BAT" =~ ^-?[0-9]+$ ]] && (( TEMP_BAT > -20000 && TEMP_BAT < 120000 )); then
        info "temperatura de bateria: $(( TEMP_BAT / 1000 )) C"
    else
        info "temperatura de bateria: lectura descartada (bruto '${TEMP_BAT:-nada}')"
        info "   el EC devuelve valores imposibles de vez en cuando; vuelve a mirar."
    fi
elif [[ -e /sys/devices/platform/acer-wmi/nitro_sense/battery_limiter ]]; then
    # El limite ya no depende de este modulo: linuwu_sense lo da por el EC.
    # Antes se decia «la app no podra tocar el limite de carga» tambien aqui,
    # y era falso.
    ok "limite de carga por linuwu_sense (nitro_sense/battery_limiter)"
    info "sin acer-wmi-battery solo falta la temperatura de la bateria"
else
    falta "sin limite de carga: ni acer-wmi-battery ni el de linuwu_sense"
    info "El de linuwu_sense llega con el driver del teclado RGB:"
    info "   sudo ./packaging/instalar-rgb.sh"
    if [[ "$DISTRO" == arch ]]; then
        info "O el modulo aparte, desde AUR:   yay -S acer-wmi-battery-dkms-git"
        info "Y asegura la carga temprana:"
        info "   echo acer_wmi_battery | sudo tee /etc/modules-load.d/acer-wmi-battery.conf"
    fi
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
            install -d "$(dirname "$CONF_CARGA")" \
                && echo acer_wmi_battery > "$CONF_CARGA" && ok "escrito $CONF_CARGA" && CAMBIOS=1
        fi
    fi
fi
[[ "$MODO" == "revertir" && -f "$CONF_CARGA" ]] && rm -f "$CONF_CARGA" && ok "borrado $CONF_CARGA"

# ---------------------------------------------------------------------------
titulo "3. PL1: devolver la CPU a su potencia base declarada"
# ---------------------------------------------------------------------------
# El firmware de Acer fija PL1 muy por encima del TDP nominal del chip.  En el
# AN17-51 (i7-13620H, 45 W nominales) lo deja en 65 W (MSR) / 70 W (MMIO).
# Medido en ese equipo: con 65 W la carga sostenida a 16 hilos se queda en
# 63 W y 85 C; con 45 W baja a 41,9 W y 66 C, sin throttling.
# Ademas el firmware REESCRIBE el PL1 por MMIO cada vez que cambia el perfil
# (performance -> 100 W), pero el valor del MSR sobrevive y es el que manda.
#
# EL OBJETIVO NO ES "45 W": es la potencia base que el PROPIO CHIP declara, que
# el kernel publica en constraint_0_max_power_uw.  Cablear 45 W aqui estaria
# bien para este portatil y seria un destrozo silencioso en otro Acer con un
# chip mas grande (un i9-13900HX declara bastante mas): le dejaria la CPU
# capada en cada arranque sin que nadie entendiera por que va lento.  Se lee
# del sistema, y si no se puede leer NO se inventa un numero: se explica y se
# salta el paso.
DIR_POWERCAP="${DIR_POWERCAP:-/sys/class/powercap}"
RAPL="$DIR_POWERCAP/intel-rapl:0"
RAPL_MMIO="$DIR_POWERCAP/intel-rapl-mmio:0"
UNIDAD=/etc/systemd/system/rapl-pl1.service

leer_w() { local v; v="$(cat "$1" 2>/dev/null)" || return 1; [[ "$v" =~ ^[0-9]+$ ]] || return 1; echo $(( v / 1000000 )); }

PL1_ACTUAL="$(leer_w "$RAPL/constraint_0_power_limit_uw" || true)"
NOMINAL="$(leer_w "$RAPL/constraint_0_max_power_uw" || true)"

if [[ "$MODO" == "revertir" ]]; then
    if [[ -f "$UNIDAD" ]]; then
        # Se devuelve AHORA el PL1 que tenia el firmware, anotado en la propia
        # unidad al crearla.  Antes se dejaba el de la unidad hasta reiniciar,
        # y eso era una trampa: desinstalar y volver a instalar sin reiniciar
        # encontraba el PL1 ya en la potencia base, decia «tu firmware no lo
        # infla» y NO creaba la unidad; al siguiente arranque el firmware lo
        # subia otra vez (100 W medidos aqui) y ya nadie lo bajaba.  Comprobado
        # el 2026-09-25.  Una unidad de una version anterior no lleva la nota,
        # y entonces se hace como antes.
        ANTES_UW="$(sed -n 's/^# pl1-firmware-uw=\([0-9]\+\)$/\1/p' "$UNIDAD" | head -1)"
        systemctl disable --now rapl-pl1.service >/dev/null 2>&1
        rm -f "$UNIDAD"; systemctl daemon-reload
        ok "rapl-pl1.service eliminado"
        if [[ -n "$ANTES_UW" ]] && echo "$ANTES_UW" > "$RAPL/constraint_0_power_limit_uw" 2>/dev/null; then
            ok "PL1 devuelto a $(( ANTES_UW / 1000000 )) W, lo que tenia el firmware antes de instalar"
        else
            info "el PL1 sigue en ${PL1_ACTUAL:-?} W hasta reiniciar; despues vuelve el del firmware"
        fi
    else
        info "rapl-pl1.service no estaba"
    fi
elif [[ ! -d "$RAPL" ]]; then
    # Acer con CPU AMD, o intel_rapl_common sin cargar.  Antes se instalaba
    # igualmente una unidad que escribia en una ruta inexistente con '|| true':
    # quedaba activada para siempre sin hacer absolutamente nada.
    falta "no existe $RAPL: este equipo no expone RAPL de Intel"
    info "El limite de potencia sostenida no se puede fijar por esta via."
    info "En CPU AMD el equivalente es ryzenadj/RyzenAdj, que no usa este proyecto."
    info "Se salta el paso: no se instala ninguna unidad."
elif [[ -z "$NOMINAL" || "$NOMINAL" -lt 10 || "$NOMINAL" -gt 150 ]]; then
    falta "no se ha podido leer una potencia base creible en $RAPL/constraint_0_max_power_uw"
    info "Leido: '${NOMINAL:-nada}' W. Sin un valor de referencia del propio chip"
    info "este script NO va a cablear un numero: te dejaria la CPU capada a un"
    info "valor que no tiene nada que ver con tu procesador."
    info "Si sabes cual es el TDP nominal de tu CPU, ponlo a mano:"
    info "   echo \$((TDP*1000000)) | sudo tee $RAPL/constraint_0_power_limit_uw"
    info "Se salta el paso."
elif systemctl is-enabled rapl-pl1.service >/dev/null 2>&1; then
    ok "rapl-pl1.service ya activo (PL1 actual: ${PL1_ACTUAL:-?} W)"
elif [[ -n "$PL1_ACTUAL" && "$PL1_ACTUAL" -le "$NOMINAL" ]]; then
    ok "el PL1 (${PL1_ACTUAL} W) ya esta en la potencia base del chip (${NOMINAL} W)"
    info "Tu firmware no lo infla: no hay nada que corregir aqui."
else
    info "CPU: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
    info "PL1 actual: ${PL1_ACTUAL:-?} W   potencia base declarada: ${NOMINAL} W"
    falta "el firmware sostiene ${PL1_ACTUAL:-?} W sobre un chip de ${NOMINAL} W nominales"
    if [[ "$MODO" == "aplicar" ]]; then
        OBJETIVO_UW=$(( NOMINAL * 1000000 ))
        # La primera linea anota el PL1 del firmware, para que --revertir lo
        # pueda devolver sin esperar a reiniciar (ver la rama de revertir).
        ANTES_UW="$(cat "$RAPL/constraint_0_power_limit_uw" 2>/dev/null || true)"
        cat > "$UNIDAD" <<UNIT
# pl1-firmware-uw=${ANTES_UW}
[Unit]
Description=Limitar PL1 de la CPU a ${NOMINAL}W (potencia base declarada por el chip; el firmware Acer la sobrepasa)
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo ${OBJETIVO_UW} > ${RAPL}/constraint_0_power_limit_uw || true'
ExecStart=/bin/sh -c 'echo ${OBJETIVO_UW} > ${RAPL_MMIO}/constraint_0_power_limit_uw || true'

[Install]
WantedBy=multi-user.target
WantedBy=suspend.target
WantedBy=hibernate.target
WantedBy=hybrid-sleep.target
UNIT
        systemctl daemon-reload
        systemctl enable --now rapl-pl1.service >/dev/null 2>&1
        sleep 1
        NUEVO="$(leer_w "$RAPL/constraint_0_power_limit_uw" || echo 0)"
        if [[ "$NUEVO" -le "$NOMINAL" ]]; then
            ok "PL1 fijado a ${NUEVO} W y persistido (unidad rapl-pl1.service)"
            info "Para deshacerlo:  sudo $0 --revertir"
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
    case "$DISTRO" in
        solus)  info "Instalalo con:  sudo eopkg install power-profiles-daemon" ;;
        ubuntu) info "Instalalo con:  sudo apt install power-profiles-daemon" ;;
        *)      info "Instalalo con:  sudo pacman -S power-profiles-daemon" ;;
    esac
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
GM=""
[[ -n "$USUARIO" ]] && GM="$(getent passwd "$USUARIO" 2>/dev/null | cut -d: -f6)/.config/gamemode.ini"
# Se ignoran las lineas de comentario (# y ;): el propio fichero puede explicar
# en un comentario por que se quito ese hook, y eso no es un problema.
if [[ -n "$GM" && -f "$GM" ]] && grep -vE '^\s*[#;]' "$GM" 2>/dev/null | grep -q "powerprofilesctl set"; then
    falta "$GM usa 'powerprofilesctl set' en un hook"
    info "'set' es permanente: si el juego crashea, el perfil se queda en"
    info "performance para siempre. Usa esto en las opciones de Steam:"
    info "   powerprofilesctl launch -p performance -- gamemoderun %command%"
fi

# ---------------------------------------------------------------------------
titulo "5. Extension de GNOME Shell  —  o el aviso de modo fuera de GNOME"
# ---------------------------------------------------------------------------
if [[ -n "$USUARIO" ]]; then
    HOME_U="$(getent passwd "$USUARIO" | cut -d: -f6)"
    EXT="$HOME_U/.local/share/gnome-shell/extensions/nitro-gekko@thegekko.dev"
    if ! command -v gnome-shell >/dev/null; then
        # Antes, en Hyprland, este paso decia "falta  instalada pero NO
        # activada", como si hubiera algo que arreglar.  Sin GNOME Shell no hay
        # nada que activar.
        info "aqui no hay GNOME Shell: la extension no aplica"
        [[ -d "$EXT" ]] && info "(esta copiada en $EXT, pero no hace nada)"
    elif [[ -d "$EXT" ]]; then
        ok "extension instalada"
        if como_usuario gnome-extensions list --enabled 2>/dev/null | grep -q nitro-gekko; then
            ok "y activada"
        else
            falta "instalada pero NO activada"
            # La causa mas comun de que 'enable' no sirva de nada NO es el
            # comando: es que GNOME la marque como 'outdated' porque su
            # shell-version no incluye esta version de Shell.  El comando no lo
            # dice, asi que se dice aqui.
            META="$EXT/metadata.json"
            DECLARA="$(sed -n 's/.*"shell-version"[^[]*\[\([^]]*\)\].*/\1/p' \
                       <(tr -d '\n' < "$META" 2>/dev/null) 2>/dev/null | tr -d ' "')"
            MI_GNOME="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
            if [[ -n "$DECLARA" && -n "$MI_GNOME" ]] \
               && ! printf '%s' ",$DECLARA," | grep -q ",$MI_GNOME,"; then
                mal "tu GNOME Shell es $MI_GNOME y la extension declara [$DECLARA]"
                info "GNOME NO la cargara: 'enable' la dejara como 'outdated' sin decir por que."
                info "La aplicacion funciona igual; solo pierdes Configuracion rapida."
                info "Para intentarlo: anade $MI_GNOME a shell-version en"
                info "   extension/metadata.json  y repite  sudo ./packaging/install.sh"
            else
                info "Actívala con:   gnome-extensions enable nitro-gekko@thegekko.dev"
                info "En Wayland hay que cerrar y volver a abrir sesion."
            fi
        fi
    else
        # Es opcional (install.sh --sin-extension): la aplicacion no la necesita.
        info "extension no instalada (es opcional; la aplicacion funciona sin ella)"
        info "La instala:  sudo ./packaging/install.sh"
    fi

    # El aviso de cambio de modo que en GNOME da la extension, en Hyprland lo
    # da 'nitro-gekko --avisos' (src/gekkonitro/avisos.py).  Como el atajo del
    # paso 6, se arranca desde la configuracion de Hyprland, que este script no
    # edita.  El patron lleva 'python3 -m' para no encontrar a este mismo
    # script ni a quien lo tenga abierto en un editor.
    if (( HYPRLAND )); then
        if [[ "$MODO" == "revertir" ]]; then
            info "el aviso de modo se arranca desde tu configuracion de Hyprland: si lo"
            info "quieres fuera, borra la linea de 'nitro-gekko --avisos'."
        elif pgrep -u "$USUARIO" -f 'python3 -m gekkonitro --avisos$' >/dev/null; then
            ok "aviso de cambio de modo activo (nitro-gekko --avisos)"
        else
            falta "en Hyprland nadie avisa en pantalla al cambiar de modo"
            info "Arrancalo con la sesion, desde tu configuracion de Hyprland:"
            info "   hyprland.lua:   hl.exec_cmd(\"nitro-gekko --avisos\")  dentro de hl.on(\"hyprland.start\", ...)"
            info "   hyprland.conf:  exec-once = nitro-gekko --avisos"
        fi
    fi
else
    falta "no se ha podido averiguar que usuario esta delante"
    info "Lanzalo con sudo desde tu sesion, no desde una consola de root."
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
#
# Solo GNOME guarda los atajos en gsettings.  En Hyprland el esquema de
# media-keys ni siquiera existe ("No existe el esquema"), y este paso lo
# intentaba igual: cada instalacion acababa en "mal  no se pudo escribir el
# atajo" y la tecla seguia sin hacer nada (comprobado el 2026-10-28 con
# Hyprland 0.56.2 y Caelestia).  Alli el atajo es una linea de SU
# configuracion, y esa configuracion es de la persona: cada cual la tiene
# partida a su manera (hyprland.conf, hyprland.lua, los ficheros de usuario
# de Caelestia...), asi que este script no la edita.  Mira si el atajo existe
# y, si no, dice que linea poner.  Las dos comprobaciones son independientes:
# quien tenga GNOME y Hyprland instalados recibe las dos.
ATAJOS_GNOME=0
gsettings list-keys org.gnome.settings-daemon.plugins.media-keys >/dev/null 2>&1 && ATAJOS_GNOME=1

if (( HYPRLAND )); then
    # hyprctl encuentra la sesion por HYPRLAND_INSTANCE_SIGNATURE, que sudo
    # borra; sin ella responde "HYPRLAND_INSTANCE_SIGNATURE not set!" y no
    # lista nada.  -i 0 coge la primera instancia de $XDG_RUNTIME_DIR/hypr,
    # que como_usuario si le pasa.
    if [[ "$MODO" == "revertir" ]]; then
        info "el atajo de Hyprland no lo pone este script, asi que tampoco lo quita:"
        info "si lo quieres fuera, borra la linea de XF86Presentation de tu configuracion."
    elif grep -qF '"XF86Presentation"' < <(como_usuario hyprctl -i 0 binds -j 2>/dev/null); then
        ok "el boton de la marca tiene atajo en Hyprland"
    else
        falta "el boton de la marca no tiene atajo en Hyprland"
        info "Este script no edita tu configuracion de Hyprland; anade tu esta linea:"
        info "   hyprland.lua:   hl.bind(\"XF86Presentation\", hl.dsp.exec_cmd(\"nitro-gekko\"))"
        info "   hyprland.conf:  bind = , XF86Presentation, exec, nitro-gekko"
        info "Con Caelestia va en ~/.config/caelestia/hypr-user.lua.  Hyprland la recarga solo."
    fi
fi

if [[ -n "$USUARIO" ]] && (( ! ATAJOS_GNOME && ! HYPRLAND )); then
    falta "ni GNOME ni Hyprland: el boton de la marca no se puede asignar desde aqui"
    info "Asigna en tu escritorio la tecla XF86Presentation al comando 'nitro-gekko'."
elif [[ -n "$USUARIO" ]] && (( ATAJOS_GNOME )); then
    RUTA_ATAJO=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/nitro-gekko/
    ESQ="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${RUTA_ATAJO}"
    ACTUAL="$(como_usuario gsettings get "$ESQ" command 2>/dev/null || echo "''")"

    if [[ "$MODO" == "revertir" ]]; then
        # --revertir tiene que deshacer TODO lo que puso este script, y el
        # atajo tambien lo puso este script.  Antes se quedaba, apuntando a un
        # 'nitro-gekko' que la desinstalacion ya habia borrado.
        if [[ "$ACTUAL" == "'nitro-gekko'" ]]; then
            LISTA="$(como_usuario gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo '@as []')"
            NUEVA="$(printf '%s' "$LISTA" | sed -e "s|, *'${RUTA_ATAJO}'||" -e "s|'${RUTA_ATAJO}', *||" -e "s|\['${RUTA_ATAJO}'\]|@as []|")"
            como_usuario gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$NUEVA" 2>/dev/null
            como_usuario dconf reset -f "$RUTA_ATAJO" 2>/dev/null
            # Se RELEE, igual que en la rama de aplicar: bajo sudo sin bus de
            # sesion accesible los dos 'set'/'reset' de arriba fallan en
            # silencio (van con 2>/dev/null) y antes se imprimia "eliminado"
            # sobre un atajo que seguia puesto.
            if [[ "$(como_usuario gsettings get "$ESQ" command 2>/dev/null || true)" == "'nitro-gekko'" ]]; then
                mal "no se pudo borrar el atajo en la sesion de $USUARIO"
                info "Quitalo desde TU sesion (sin sudo):"
                info "   ./packaging/preparar-sistema.sh --revertir"
                info "o a mano en Configuracion > Teclado > Atajos personalizados."
            else
                ok "atajo del boton de la marca eliminado"
            fi
        else
            ok "el boton de la marca no estaba asignado por nosotros"
        fi
    elif [[ "$ACTUAL" == "'nitro-gekko'" ]]; then
        ok "el boton de la marca abre Nitro Gekko"
    else
        falta "el boton de la marca no esta asignado"
        if [[ "$MODO" == "aplicar" ]]; then
            LISTA="$(como_usuario gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null)"
            if [[ "$LISTA" != *"custom-keybindings/nitro-gekko"* ]]; then
                NUEVA="${LISTA%]}"
                [[ "$NUEVA" == "@as [" || "$NUEVA" == "[" ]] && NUEVA="['$RUTA_ATAJO']" \
                    || NUEVA="${NUEVA}, '${RUTA_ATAJO}']"
                como_usuario gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$NUEVA" 2>/dev/null
            fi
            como_usuario gsettings set "$ESQ" name 'Abrir Nitro Gekko' 2>/dev/null
            como_usuario gsettings set "$ESQ" command 'nitro-gekko' 2>/dev/null
            como_usuario gsettings set "$ESQ" binding 'XF86Presentation' 2>/dev/null
            # Se COMPRUEBA que ha cuajado en vez de darlo por hecho: si el bus
            # de sesion no estaba accesible, gsettings falla en silencio y
            # antes se imprimia "ok" igual.
            if [[ "$(como_usuario gsettings get "$ESQ" command 2>/dev/null || true)" == "'nitro-gekko'" ]]; then
                ok "boton de la marca -> nitro-gekko"
                CAMBIOS=1
            else
                mal "no se pudo escribir el atajo en la sesion de $USUARIO"
                info "Hazlo desde TU sesion (sin sudo):"
                info "   ./packaging/preparar-sistema.sh --revisar   para ver como quedo"
                info "o a mano en Configuracion > Teclado > Atajos personalizados,"
                info "con la tecla XF86Presentation y el comando 'nitro-gekko'."
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
titulo "7. Tecla del microfono (F8)  —  silenciarlo"
# ---------------------------------------------------------------------------
# La tecla F8, la del icono del microfono, manda el scancode 0x66 por el
# teclado i8042.  La tabla de teclas de systemd (60-keyboard.hwdb) le pone
# micmute a ese mismo 0x66 en cinco Acer recientes -Nitro AN515-47 y
# ANV15-51, Predator PT314-52s, PHN16-71 y PHN16-72-, pero el AN17-51 no esta,
# y el kernel le da el nombre por defecto de ese scancode: KEY_F15.  Para XKB
# eso es XF86Launch6, que no atiende nadie, asi que la tecla llega al
# escritorio y no hace nada.  Y no deja rastro en journalctl: no es una tecla
# desconocida, es una tecla con el nombre equivocado.
#
# Se le da su nombre con una entrada de hwdb igual que la de esos cinco
# equipos.  De ahi en adelante es XF86AudioMicMute, y eso ya lo atienden GNOME
# y Caelestia sin nada mas.  Medido en el AN17-51 el 2026-10-28 (BIOS V1.12)
# con packaging/capturar-tecla.py.
#
# OJO con 0xf0, que tambien sale de este teclado.  La primera version de este
# paso lo tomo por la tecla del microfono porque era el unico "Unknown key
# pressed" de journalctl, y lo convertia en micmute.  Era otra tecla: en el
# Nitro AN515-58 y el Predator PH315-52 la tabla de systemd lo llama
# kbdillumdown (Fn+F9, bajar la luz del teclado).  En este equipo no se ha
# comprobado cual es, y por eso no se toca.
#
# La entrada va atada al modelo (pnNitroAN17-51): en otro Acer el mismo
# scancode puede ser otra tecla, y alli no se instala.
#
# Se compila con 'systemd-hwdb update' a secas, que es lo que manda la propia
# cabecera de 60-keyboard.hwdb para las entradas locales.  Eso deja la base en
# /etc/udev/hwdb.bin, y udev usa la de /etc antes que la de /usr/lib/udev.  No
# tapa las actualizaciones de systemd: con ficheros en /etc/udev/hwdb.d, el
# servicio systemd-hwdb-update la rehace en cada arranque que siga a una
# actualizacion de paquetes (ConditionNeedsUpdate=/etc; en Arch lo arma el hook
# de pacman).
#
# La primera version de este paso compilaba con --usr, creyendo lo contrario:
# que un hwdb.bin en /etc se quedaria viejo para siempre.  En el siguiente
# arranque systemd creo el de /etc el solo (2026-10-28, 18:38: "Finished
# Rebuild Hardware Database"), que es su diseno.
HWDB=/etc/udev/hwdb.d/61-nitro-gekko-teclado.hwdb

compilar_hwdb() {
    systemd-hwdb update
}

# El nodo del teclado interno cambia de numero entre arranques: se busca por
# nombre, como el hwmon 'acer' del paso 1.
TECLADO_AT=""
for e in /sys/class/input/event*; do
    [[ "$(cat "$e/device/name" 2>/dev/null)" == "AT Translated Set 2 keyboard" ]] && TECLADO_AT="${e##*/}"
done
# Lo que udev le ha aplicado DE VERDAD al teclado, no lo que diga el fichero:
# un .hwdb sin compilar no hace nada.  Se lee sin root.
tecla_66() {
    [[ -n "$TECLADO_AT" ]] || return 0
    sed -n 's/^KEYBOARD_KEY_66=//p' < <(udevadm info --query=property --name="/dev/input/$TECLADO_AT" 2>/dev/null)
}
T66="$(tecla_66)"

if [[ "$MODO" == "revertir" ]]; then
    if [[ -f "$HWDB" ]]; then
        rm -f "$HWDB"
        compilar_hwdb && ok "borrado $HWDB"
        # udev ASIGNA teclas pero no las desasigna: la que ya esta puesta en
        # el kernel sigue hasta reiniciar.
        info "La tecla del microfono seguira silenciandolo hasta reiniciar."
        PENDIENTE_REINICIO=1
    else
        info "$HWDB no estaba"
    fi
elif [[ "$PRODUCTO" != "Nitro AN17-51" ]]; then
    info "el scancode de la tecla del microfono se midio en el AN17-51: en tu modelo no se toca nada."
    info "Si la tuya no responde, averigua su scancode con:"
    info "   sudo python3 packaging/capturar-tecla.py"
elif [[ -z "$TECLADO_AT" ]]; then
    falta "no se encuentra el teclado interno (AT Translated Set 2 keyboard)"
elif [[ "$T66" == micmute ]]; then
    ok "la tecla del microfono lo silencia (KEY_MICMUTE)"
elif [[ -n "$T66" && ! -f "$HWDB" ]]; then
    ok "la tecla del microfono ya tiene nombre ($T66), puesto por otra regla: no se toca"
else
    falta "la tecla del microfono llega como KEY_F15 y no la atiende nadie (scancode 0x66)"
    if [[ "$MODO" == "aplicar" ]]; then
        install -d "$(dirname "$HWDB")"
        cat > "$HWDB" <<'HWDB'
# Puesto por Nitro Gekko (packaging/preparar-sistema.sh, paso 7).
# La tecla del microfono (F8) del Acer Nitro AN17-51.  Sin esto el kernel la
# llama KEY_F15, que no atiende nadie.  Es la misma entrada que trae systemd
# para el Nitro AN515-47 y ANV15-51 y los Predator PHN16-71 y PHN16-72.
# Para quitarlo:  sudo ./packaging/preparar-sistema.sh --revertir
evdev:atkbd:dmi:bvn*:bvr*:bd*:svnAcer*:pnNitroAN17-51:*
 KEYBOARD_KEY_66=micmute                                # Microphone mute button
HWDB
        compilar_hwdb
        # Se reaplica al teclado YA, sin reiniciar, y se comprueba leyendo lo
        # que udev le puso, no dandolo por hecho.
        udevadm trigger --action=change "/sys/class/input/$TECLADO_AT"
        udevadm settle --timeout=5
        if [[ "$(tecla_66)" == micmute ]]; then
            ok "tecla del microfono -> silenciarlo ($HWDB)"
            # Hipotesis, no comprobada aqui: libinput (debajo de GNOME y de
            # Hyprland) lee al abrir el teclado que teclas tiene, y una que no
            # estaba entonces puede no llegarle hasta volver a abrirlo.
            # Cerrar sesion lo vuelve a abrir.
            info "Si en esta sesion todavia no responde, cierra sesion y vuelve a entrar."
            CAMBIOS=1
        else
            mal "escrito $HWDB, pero udev no lo ha aplicado al teclado"
            info "Reinicia y vuelve a mirar con --revisar."
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
