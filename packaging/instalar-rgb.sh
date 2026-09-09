#!/usr/bin/env bash
#
# Instala de forma PERMANENTE el driver linuwu-sense parcheado para el
# Acer Nitro AN17-51, que es lo unico que da control del teclado RGB de 4 zonas
# en Linux.
#
# POR QUE ESTO ES SEGURO EN ESTE EQUIPO (y no lo era a ciegas)
# ------------------------------------------------------------
# linuwu_sense SUSTITUYE a acer_wmi: los dos reclaman los mismos GUID de WMI.
# El riesgo era perder lo que acer_wmi nos daba. La prueba en caliente lo
# descarto con datos:
#     platform_profile SIGUE: balanced
#     perfiles: low-power quiet balanced balanced-performance performance
#     tacometros SIGUEN: fan1=1750 fan2=1755
# Es decir, linuwu_sense repone las dos cosas Y ademas anade el RGB, el
# temporizador de retroiluminacion, la carga USB y la calibracion de bateria.
#
# POR QUE DKMS
# ------------
# El modulo se ata al vermagic exacto del kernel. Sin DKMS, la primera
# actualizacion de linux-zen te dejaria sin perfiles, sin tacometros y sin RGB
# a la vez. DKMS lo recompila en cada kernel nuevo.
#
#   sudo ./packaging/instalar-rgb.sh              instala
#   sudo ./packaging/instalar-rgb.sh --revertir   desinstala y devuelve acer_wmi
#        ./packaging/instalar-rgb.sh --help       esta ayuda (no pide root)
#
# Para PROBAR el RGB antes de instalar nada de forma permanente:
#   make -C rgb && sudo ./packaging/probar-rgb.sh
#
set -uo pipefail

NOMBRE="linuwu-sense"
# SIN GUION EN LA VERSION, y tiene que decir lo mismo que rgb/dkms.conf (se
# comprueba mas abajo).  El motivo largo esta escrito alli: el hook de pacman
# adivina nombre y version partiendo el directorio de /usr/src por el ultimo
# guion, y un guion aqui hace que registre el modulo con otro nombre.
VERSION="1.0.0.an17.1"
ORIGEN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rgb"
DESTINO="/usr/src/${NOMBRE}-${VERSION}"
CONF_BL=/etc/modprobe.d/nitro-gekko-rgb.conf
CONF_LOAD=/etc/modules-load.d/linuwu-sense.conf

if [[ -t 1 ]]; then V=$'\033[32m'; R=$'\033[31m'; A=$'\033[33m'; C=$'\033[36m'; N=$'\033[1m'; F=$'\033[0m'
else V=; R=; A=; C=; N=; F=; fi
titulo(){ echo; echo "${N}${C}$*${F}"; }
ok(){ echo "  ${V}ok${F}    $*"; }
mal(){ echo "  ${R}mal${F}   $*"; }
avi(){ echo "  ${A}··${F}    $*"; }
info(){ echo "        $*"; }

# ---------------------------------------------------------------------------
#  Opciones.  Se leen ANTES de exigir root: pedir la contrasena para poder
#  leer la ayuda no tiene sentido.  Y una opcion que no se reconozca ABORTA:
#  antes cualquier argumento raro se ignoraba en silencio y el script se ponia
#  a instalar el driver, que no es precisamente inocuo.
# ---------------------------------------------------------------------------
ayuda() {
    # Se imprime la cabecera de comentarios completa, hasta la primera linea
    # que no sea un comentario.  Un rango de lineas cableado ('sed -n 2,32p')
    # se descuadra en cuanto alguien anade o quita una linea del encabezado.
    awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

ACCION="instalar"
case "${1:-}" in
    --revertir|--uninstall|--desinstalar) ACCION="revertir" ;;
    -h|--help|--ayuda)                    ayuda; exit 0 ;;
    "")                                   ;;
    *) echo "Opcion desconocida: $1"; echo; ayuda; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    echo "Sobran argumentos: $*"; exit 2
fi

[[ $EUID -eq 0 ]] || { echo "Hace falta root:  sudo $0   ($0 --help no lo necesita)"; exit 1; }

# ---------------------------------------------------------------------------
#  Restos registrados con OTRO nombre.
#
#  Hasta la version 1.0.0-an17.1 la version llevaba guion, y el hook de pacman
#  registraba el modulo como 'linuwu-sense-1.0.0/an17.1' en paralelo al nuestro
#  (parte /usr/src/<nombre>-<version> por el ultimo guion; el porque completo
#  esta en rgb/dkms.conf).  Ese registro duplicado no lo quitaba nadie -ni el
#  --revertir de antes, que solo miraba $NOMBRE/$VERSION- y volvia a intentar
#  compilar, y a fallar, en cada kernel nuevo.  Se barre por prefijo, no por un
#  nombre concreto, para que valga tambien si el reparto vuelve a cambiar.
# ---------------------------------------------------------------------------
limpiar_restos_de_otro_nombre() {
    local nv d encontrado=0
    while read -r nv; do
        [[ -z "$nv" || "$nv" == "$NOMBRE/$VERSION" ]] && continue
        encontrado=1
        if dkms remove "$nv" --all </dev/null >/dev/null 2>&1; then
            avi "quitado un registro DKMS antiguo con otro nombre: $nv"
        else
            mal "no se pudo quitar el registro DKMS antiguo: $nv"
            info "Quitalo a mano:  sudo dkms remove $nv --all"
        fi
    done < <(dkms status 2>/dev/null | sed 's/[,:].*//' | grep '^linuwu' | sort -u)

    for d in /usr/src/linuwu-sense-*; do
        [[ -d "$d" && "$d" != "$DESTINO" ]] || continue
        encontrado=1
        rm -rf "$d" && avi "borrado un fuente antiguo: $d" \
            || { mal "no se pudo borrar $d"; info "Borralo a mano o el hook de pacman lo seguira compilando."; }
    done

    (( encontrado )) || info "no hay restos con otro nombre"
}

# ---------------------------------------------------------------------------
if [[ "$ACCION" == "revertir" ]]; then
    titulo "Revirtiendo: volver a acer_wmi"
    FALLOS=0

    # 'rm -f' sobre lo que no existe devuelve 0, asi que antes se imprimia
    # "quitados los ficheros de configuracion" aunque no hubiera ninguno.
    for f in "$CONF_BL" "$CONF_LOAD"; do
        if [[ -e "$f" ]]; then
            rm -f "$f" && ok "borrado $f" || { mal "NO se pudo borrar $f"; FALLOS=1; }
        else
            info "$f no estaba"
        fi
    done

    if command -v dkms >/dev/null && dkms status "$NOMBRE/$VERSION" 2>/dev/null | grep -q .; then
        if dkms remove "$NOMBRE/$VERSION" --all >/dev/null 2>&1; then
            ok "modulo quitado de DKMS"
        else
            mal "'dkms remove' fallo; mira:  dkms status $NOMBRE"
            FALLOS=1
        fi
    else
        info "no estaba registrado en DKMS"
    fi

    if [[ -d "$DESTINO" ]]; then
        rm -rf "$DESTINO" && ok "fuente eliminado de $DESTINO" || { mal "NO se pudo borrar $DESTINO"; FALLOS=1; }
    else
        info "$DESTINO no estaba"
    fi

    limpiar_restos_de_otro_nombre

    # Restos de un 'dkms install' que no se pudo deshacer: si el .ko sigue en
    # /lib/modules, el modulo se volveria a cargar al arrancar y todo esto no
    # habria servido de nada.
    RESTO_KO="$(find /lib/modules -name 'linuwu_sense.ko*' 2>/dev/null)"
    if [[ -n "$RESTO_KO" ]]; then
        mal "queda el modulo instalado en /lib/modules:"
        printf '%s\n' "$RESTO_KO" | sed 's/^/        /'
        info "Borralo a mano y vuelve a ejecutar:  depmod -a"
        FALLOS=1
    fi

    depmod -a

    if lsmod | grep -q '^linuwu_sense '; then
        modprobe -r linuwu_sense 2>/dev/null && ok "linuwu_sense descargado" \
            || { mal "no se pudo descargar linuwu_sense (reinicia)"; FALLOS=1; }
    fi
    modprobe sparse_keymap 2>/dev/null
    modprobe acer_wmi predator_v4=1 2>/dev/null && ok "acer_wmi recargado" \
        || { mal "no se pudo cargar acer_wmi; reinicia para volver al estado normal"; FALLOS=1; }

    # EL PARAMETRO TIENE QUE PERSISTIR, NO SOLO APLICARSE AHORA.
    #
    # Ese 'modprobe acer_wmi predator_v4=1' devuelve los perfiles y los
    # tacometros EN CALIENTE, pero en el proximo arranque el modulo lo carga
    # udev por modalias y SIN parametros: sin predator_v4=1 el AN17-51 no esta
    # en la tabla de quirks DMI de acer-wmi y no se registra ni
    # platform_profile ni el hwmon.  Es decir, quien instalara solo el RGB
    # (sin pasar antes por preparar-sistema.sh, que es lo que escribe este
    # fichero) revertia, veia "acer_wmi vuelve a estar al mando", reiniciaba y
    # se quedaba sin perfiles ni ventiladores sin saber por que.
    #
    # Se escribe con la MISMA marca que usa preparar-sistema.sh para que su
    # --revertir sepa que esta linea la pusimos nosotros y la pueda quitar.
    CONF_ACER=/etc/modprobe.d/acer-wmi.conf
    MARCA_ACER='# puesto-por-nitro-gekko'
    if [[ -f "$CONF_ACER" ]] && grep -q "predator_v4=1" "$CONF_ACER"; then
        ok "$CONF_ACER ya fija predator_v4=1 (los perfiles sobreviven al reinicio)"
    else
        [[ -f "$CONF_ACER" ]] && printf '\n' >> "$CONF_ACER"
        if {
            printf '%s\n' "$MARCA_ACER"
            printf '%s\n' '# Escrito por packaging/instalar-rgb.sh --revertir.  Sin predator_v4=1 el'
            printf '%s\n' '# acer-wmi de mainline no reconoce este modelo y no crea platform_profile'
            printf '%s\n' '# ni el hwmon de los ventiladores en el proximo arranque.'
            printf '%s\n' '# Para quitarlo:  sudo ./packaging/preparar-sistema.sh --revertir'
            printf '%s\n' 'options acer_wmi predator_v4=1'
        } >> "$CONF_ACER"; then
            ok "escrito $CONF_ACER (predator_v4=1 persistente)"
        else
            mal "no se pudo escribir $CONF_ACER"
            info "Hazlo a mano o los perfiles no volveran tras reiniciar:"
            info "    echo 'options acer_wmi predator_v4=1' | sudo tee $CONF_ACER"
            FALLOS=1
        fi
    fi
    sleep 2

    echo
    P_TRAS="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo AUSENTE)"
    info "platform_profile: $P_TRAS"
    [[ "$P_TRAS" == AUSENTE ]] && { mal "no han vuelto los perfiles termicos: reinicia."; FALLOS=1; }
    HW_TRAS=""; for d in /sys/class/hwmon/hwmon*; do [[ "$(cat "$d/name" 2>/dev/null)" == acer ]] && HW_TRAS="$d"; done
    if [[ -n "$HW_TRAS" ]]; then
        info "tacometros:       fan1=$(cat "$HW_TRAS/fan1_input" 2>/dev/null) fan2=$(cat "$HW_TRAS/fan2_input" 2>/dev/null)"
    else
        mal "no han vuelto los tacometros: reinicia."
        FALLOS=1
    fi

    echo
    if (( FALLOS )); then
        echo "  ${R}La reversion ha quedado incompleta.${F} Repasa los mensajes de arriba."
        exit 1
    fi
    echo "  ${V}Revertido: acer_wmi vuelve a estar al mando.${F}"
    echo "  El teclado RGB deja de poder controlarse hasta que lo instales otra vez."
    exit 0
fi

# ---------------------------------------------------------------------------
titulo "1. Comprobaciones"
PROD="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
VEND="$(cat /sys/class/dmi/id/sys_vendor  2>/dev/null || true)"
# En un equipo que no es Acer este modulo no puede engancharse a nada: reclama
# GUID de WMI que solo publica el firmware de Acer.  Se aborta AQUI, antes de
# compilar nada, en vez de descubrirlo despues de un 'dkms build' de varios
# minutos y con /usr/src y la lista negra ya escritos.
if [[ "$VEND" != "Acer" ]]; then
    mal "este equipo es '${VEND:-desconocido} ${PROD:-?}', no un Acer."
    info "linuwu_sense reclama GUID de WMI que solo existen en firmware Acer:"
    info "aqui no se cargaria y solo conseguirias dejar acer_wmi en lista negra."
    info "No se instala nada. Abortado."
    exit 1
fi
if [[ "$PROD" == "Nitro AN17-51" ]]; then
    ok "modelo: $PROD"
else
    avi "modelo ${PROD:-desconocido} (esto se escribio para el AN17-51)"
    info "El parche DMI de rgb/src/linuwu_sense.c solo anade el AN17-51.  En otro"
    info "Acer el driver cargara igual (es el acer-wmi completo), pero el teclado"
    info "de 4 zonas puede no aparecer.  Si eso pasa, el paso 6 te lo dira y"
    info "podras revertirlo; y si ademas se perdieran los perfiles termicos o los"
    info "tacometros, este script lo deshace SOLO antes de terminar."
fi

# -- el arbol de fuentes tiene que estar COMPLETO ---------------------------
# Antes solo se comprobaba que existiera rgb/src/.  Si faltaba el Makefile o
# el dkms.conf, el 'cp' de mas abajo fallaba, el script seguia (no hay set -e)
# e imprimia "ok /usr/src/...", y el fallo no salia hasta el 'dkms add', ya con
# medio arbol copiado en /usr/src.
FUENTE_C="$ORIGEN/src/linuwu_sense.c"
for f in "$ORIGEN/src" "$FUENTE_C" "$ORIGEN/Makefile" "$ORIGEN/dkms.conf"; do
    [[ -e "$f" ]] || { mal "falta ${f#"$(dirname "$ORIGEN")"/}"; \
                       info "Clona el repositorio completo: rgb/ va con el."; exit 1; }
done
ok "fuente completo: $ORIGEN"

# -- el dkms.conf tiene que decir lo mismo que este script ------------------
# 'dkms add' usa el nombre y la version que pone el dkms.conf, no los de aqui.
# Si no coinciden, el arbol se registra con otro nombre y todos los 'dkms
# build/install/remove/status' de mas abajo apuntan a la nada.
CONF_NOMBRE="$(sed -n 's/^PACKAGE_NAME="\(.*\)"$/\1/p'    "$ORIGEN/dkms.conf" | head -1)"
CONF_VERSION="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$ORIGEN/dkms.conf" | head -1)"
if [[ "$CONF_NOMBRE" != "$NOMBRE" || "$CONF_VERSION" != "$VERSION" ]]; then
    mal "rgb/dkms.conf dice '${CONF_NOMBRE}/${CONF_VERSION}' y este script espera '${NOMBRE}/${VERSION}'."
    info "Cuadra los dos antes de seguir, o DKMS registrara el modulo con otro"
    info "nombre y ni --revertir sabra quitarlo."
    exit 1
fi
ok "dkms.conf coherente: ${CONF_NOMBRE}/${CONF_VERSION}"

command -v dkms >/dev/null && ok "dkms $(dkms --version 2>/dev/null | head -1)" || { mal "falta dkms:  sudo pacman -S dkms"; exit 1; }

# -- headers del kernel EN MARCHA ------------------------------------------
# Mirar si el paquete linux-zen-headers esta instalado no basta: lo que DKMS
# necesita es el arbol de construccion del kernel que esta corriendo AHORA.
# Puedes tener los headers de linux-zen instalados y estar arrancado con
# linux normal, y entonces la compilacion falla.
KDIR="/lib/modules/$(uname -r)/build"
if [[ -d "$KDIR" ]]; then
    ok "headers del kernel en marcha: $KDIR"
else
    mal "no existe $KDIR: faltan los headers del kernel $(uname -r)"
    case "$(uname -r)" in
        *-zen) info "Instalalos con:  sudo pacman -S linux-zen-headers" ;;
        *-lts) info "Instalalos con:  sudo pacman -S linux-lts-headers" ;;
        *)     info "Instalalos con:  sudo pacman -S linux-headers" ;;
    esac
    exit 1
fi

grep -q "Nitro AN17-51" "$FUENTE_C" && ok "el fuente lleva el parche del AN17-51" || { mal "el fuente NO lleva el parche"; exit 1; }
# OJO: hay que mirar solo el CODIGO, no los comentarios.  La cabecera del
# fichero explica el parche y ahi aparece la palabra `strncpy()` escrita a
# proposito; un `grep -q "strncpy("` a secas la encontraba y abortaba la
# instalacion con "el fuente aun tiene strncpy()" en un fuente que estaba
# perfectamente.  Se descartan las lineas de comentario de bloque (` * `) y de
# linea (`//`, `/*`), que es donde vive esa explicacion.
solo_codigo() { grep -vE '^[[:space:]]*(\*|//|/\*)' "$1"; }
if solo_codigo "$FUENTE_C" | grep -q "strncpy("; then
    mal "el fuente aun tiene strncpy() en el codigo: no compilara en kernel 7.2"
    info "Lineas:"
    grep -nE '^[[:space:]]*[^ *(/].*strncpy\(' "$FUENTE_C" | head -5 | sed 's/^/        /'
    exit 1
fi
ok "sin strncpy() en el codigo: compilara en kernel 7.2+"
grep -q "four_zoned_kb" "$FUENTE_C" && ok "el fuente registra el grupo four_zoned_kb (RGB)" || { mal "el fuente no crea four_zoned_kb: no habria RGB"; exit 1; }

# ---------------------------------------------------------------------------
titulo "2. Instalando el fuente en /usr/src"
rm -rf "$DESTINO"
mkdir -p "$DESTINO" || { mal "no se pudo crear $DESTINO"; exit 1; }
if ! cp -r "$ORIGEN/src" "$ORIGEN/Makefile" "$ORIGEN/dkms.conf" "$DESTINO/"; then
    mal "no se pudo copiar el fuente a $DESTINO (disco lleno? /usr de solo lectura?)"
    rm -rf "$DESTINO"
    exit 1
fi
# Normalizar permisos: el repositorio puede venir de un clon con umask laxo y
# esto acaba en /usr/src, que es codigo de sistema.
chown -R root:root "$DESTINO"
find "$DESTINO" -type d -exec chmod 755 {} +
find "$DESTINO" -type f -exec chmod 644 {} +
ok "$DESTINO"

# ---------------------------------------------------------------------------
titulo "3. Compilando con DKMS"
# El log va a un fichero creado con mktemp, no a un /tmp/dkms-nitro.log de
# nombre fijo: /tmp lo puede escribir cualquiera y ese nombre es adivinable.
LOG="$(mktemp /var/log/dkms-nitro-gekko.XXXXXX 2>/dev/null || mktemp)"
chmod 600 "$LOG"
info "log de la compilacion: $LOG"

dkms remove "$NOMBRE/$VERSION" --all >/dev/null 2>&1 || true
limpiar_restos_de_otro_nombre
if dkms add "$NOMBRE/$VERSION" >>"$LOG" 2>&1; then ok "anadido a DKMS"; else
    mal "dkms add fallo. Ultimas lineas:"; tail -15 "$LOG" | sed 's/^/      /'; exit 1; fi
if dkms build "$NOMBRE/$VERSION" >>"$LOG" 2>&1; then
    ok "compilado"
else
    mal "dkms build fallo. Ultimas lineas:"
    tail -15 "$LOG" | sed 's/^/      /'
    info "Log completo en: $LOG"
    exit 1
fi
if dkms install "$NOMBRE/$VERSION" >>"$LOG" 2>&1; then ok "instalado"; else
    mal "dkms install fallo. Ultimas lineas:"; tail -15 "$LOG" | sed 's/^/      /'; exit 1; fi
dkms status "$NOMBRE" | sed 's/^/        /'

# ---------------------------------------------------------------------------
titulo "4. Configurando la carga en el arranque"
# acer_wmi y linuwu_sense no pueden convivir. Se pone acer_wmi en la lista
# negra y se carga linuwu_sense explicitamente.
cat > "$CONF_BL" <<'EOF'
# Nitro Gekko: linuwu_sense sustituye a acer_wmi (reclaman los mismos GUID de
# WMI). linuwu_sense da todo lo que daba acer_wmi con predator_v4=1
# -platform_profile con 5 perfiles y el hwmon de los ventiladores- y ademas el
# teclado RGB de 4 zonas, el temporizador de retroiluminacion, la carga USB y
# la calibracion de bateria.
#
# =========================================================================
#  SI ALGUN DIA ARRANCAS SIN PERFILES TERMICOS NI VENTILADORES, LEE ESTO
# =========================================================================
# Este fichero aparta acer_wmi para dejarle sitio a linuwu_sense, que es un
# modulo DKMS. DKMS lo recompila en cada kernel nuevo, pero una actualizacion
# de kernel PUEDE romper esa compilacion (el driver usa API interna del
# kernel). Si eso pasa, arrancas sin ninguno de los dos: sin platform_profile,
# sin RPM y sin RGB. Se reconoce asi:
#
#     dkms status linuwu-sense      # no dice 'installed' para tu kernel
#     lsmod | grep -c linuwu_sense  # 0
#
# ARREGLO INMEDIATO (recupera perfiles y ventiladores AHORA, sin RGB):
#
#     sudo rm /etc/modprobe.d/nitro-gekko-rgb.conf
#     sudo rm /etc/modules-load.d/linuwu-sense.conf
#     echo 'options acer_wmi predator_v4=1' | sudo tee /etc/modprobe.d/acer-wmi.conf
#     sudo modprobe acer_wmi predator_v4=1
#
# Y CUANDO QUIERAS VOLVER A INTENTARLO, con el repositorio delante:
#
#     sudo ./packaging/instalar-rgb.sh --revertir   # limpia el DKMS viejo
#     sudo ./packaging/instalar-rgb.sh              # recompila con el kernel nuevo
#
# (Hace falta tener instalados los headers del kernel EN MARCHA: sin ellos
#  DKMS no puede recompilar nada.  pacman -S linux-zen-headers, o los que
#  correspondan a tu kernel.)
blacklist acer_wmi
EOF
ok "$CONF_BL (acer_wmi en lista negra)"

echo linuwu_sense > "$CONF_LOAD"
ok "$CONF_LOAD (carga en el arranque)"

# ---------------------------------------------------------------------------
titulo "5. Cambiando el driver ahora, sin reiniciar"
PERFIL_PREVIO="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo balanced)"
modprobe -r acer_wmi 2>/dev/null && ok "acer_wmi descargado"
# modprobe -r arrastra dependencias sin usuarios (sparse_keymap); modprobe del
# modulo nuevo las vuelve a traer solo, a diferencia de insmod.
if modprobe linuwu_sense 2>/dev/null; then
    ok "linuwu_sense cargado"
else
    mal "no se pudo cargar linuwu_sense; devolviendo acer_wmi"
    modprobe sparse_keymap 2>/dev/null; modprobe acer_wmi predator_v4=1 2>/dev/null
    rm -f "$CONF_BL" "$CONF_LOAD"
    exit 1
fi
sleep 3

# ---------------------------------------------------------------------------
titulo "6. Verificando que no se ha perdido nada"
# Se separan DOS clases de fallo, porque no piden la misma reaccion:
#
#   GRAVE  -> el equipo ha quedado PEOR que antes: linuwu_sense no repone
#             platform_profile o los tacometros que daba acer_wmi.  Eso pasa en
#             modelos que no estan en la tabla DMI del driver.  Aqui NO basta
#             con avisar: acer_wmi ya esta en la lista negra y en el proximo
#             arranque el portatil se queda sin perfiles termicos.  Se deshace
#             solo, ahora mismo.
#   SIN_RGB -> perfiles y ventiladores funcionan, pero el modelo no expone el
#             teclado de 4 zonas.  El equipo no ha empeorado: se avisa y se
#             deja la decision a quien lo instala.
GRAVE=0
SIN_RGB=0
P="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo AUSENTE)"
if [[ "$P" != AUSENTE ]]; then
    ok "platform_profile: $P"
    info "perfiles: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null)"
else mal "platform_profile AUSENTE"; GRAVE=1; fi

HW=""; for d in /sys/class/hwmon/hwmon*; do [[ "$(cat "$d/name" 2>/dev/null)" == acer ]] && HW="$d"; done
if [[ -n "$HW" ]]; then ok "tacometros: fan1=$(cat "$HW/fan1_input") fan2=$(cat "$HW/fan2_input")  ($HW)"
else mal "hwmon 'acer' AUSENTE"; GRAVE=1; fi

BASE=/sys/devices/platform/acer-wmi
if [[ -d "$BASE/four_zoned_kb" ]]; then
    ok "RGB de 4 zonas: $BASE/four_zoned_kb"
    ls "$BASE/four_zoned_kb" | sed 's/^/        /'
else
    mal "four_zoned_kb AUSENTE: este modelo no expone el teclado de 4 zonas"
    info "El driver ha cargado, pero tu equipo ($PROD) no esta en su tabla DMI"
    info "con .four_zone_kb=1, o su teclado no es RGB por zonas."
    SIN_RGB=1
fi

for g in nitro_sense predator_sense; do
    if [[ -d "$BASE/$g" ]]; then
        ok "grupo $g:"
        ls "$BASE/$g" | sed 's/^/        /'
    fi
done

# El limite de bateria pasa a estar en DOS sitios: el DKMS de acer-wmi-battery
# y el propio linuwu_sense. Conviene saberlo para no pelearse consigo mismo.
if [[ -e /sys/bus/wmi/drivers/acer-wmi-battery/health_mode ]]; then
    avi "acer-wmi-battery sigue cargado y tambien controla el limite de carga."
    info "No es un fallo, pero ahora hay dos interfaces para lo mismo."
    info "Nitro Gekko usa la de acer-wmi-battery, que ya estaba probada."
fi

[[ "$P" != AUSENTE && "$P" != "$PERFIL_PREVIO" ]] && echo "$PERFIL_PREVIO" > /sys/firmware/acpi/platform_profile 2>/dev/null

titulo "Resumen"
if (( GRAVE )); then
    mal "linuwu_sense NO repone lo que daba acer_wmi en este equipo."
    info "Dejarlo asi te dejaria sin perfiles termicos ni tacometros en el"
    info "proximo arranque, porque acer_wmi ya estaria en la lista negra."
    info "Deshaciendo el cambio automaticamente:"
    rm -f "$CONF_BL" "$CONF_LOAD" && ok "quitados $CONF_BL y $CONF_LOAD"
    lsmod | grep -q '^linuwu_sense ' && { modprobe -r linuwu_sense 2>/dev/null \
        && ok "linuwu_sense descargado" || mal "no se pudo descargar linuwu_sense"; }
    modprobe sparse_keymap 2>/dev/null
    modprobe acer_wmi predator_v4=1 2>/dev/null && ok "acer_wmi recargado" \
        || mal "no se pudo recargar acer_wmi: REINICIA para volver al estado normal"
    echo
    # Ese predator_v4=1 de arriba vale para AHORA. En el proximo arranque el
    # modulo lo carga udev sin parametros, asi que si nadie ha escrito el
    # fichero de modprobe.d los perfiles se vuelven a perder al reiniciar.
    if [[ -f /etc/modprobe.d/acer-wmi.conf ]] && grep -q "predator_v4=1" /etc/modprobe.d/acer-wmi.conf; then
        info "predator_v4=1 esta en /etc/modprobe.d/acer-wmi.conf: sobrevive al reinicio."
    else
        avi "predator_v4=1 solo esta puesto EN CALIENTE: al reiniciar se pierde."
        info "Para dejarlo fijo (y con ello los perfiles y los tacometros):"
        info "    sudo ./packaging/preparar-sistema.sh"
    fi
    info "El modulo sigue registrado en DKMS pero ya no se carga al arrancar."
    info "Para borrarlo del todo:  sudo $0 --revertir"
    exit 1
fi
if (( SIN_RGB )); then
    echo "  ${A}Instalado, pero sin teclado RGB en este modelo.${F}"
    echo "  Los perfiles termicos y los tacometros SI funcionan con linuwu_sense,"
    echo "  asi que el equipo no ha perdido nada; simplemente no hay RGB que dar."
    echo "  Si prefieres volver a acer_wmi:  sudo $0 --revertir"
    exit 0
fi
echo "  ${V}Driver instalado y verificado.${F}"
echo "  Sobrevive a las actualizaciones de kernel gracias a DKMS."
echo "  Para volver a acer_wmi:  sudo $0 --revertir"
