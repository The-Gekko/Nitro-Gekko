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
#   sudo ./instalar-rgb.sh              instala
#   sudo ./instalar-rgb.sh --revertir   desinstala y devuelve acer_wmi
#
set -uo pipefail

NOMBRE="linuwu-sense"
VERSION="1.0.0-an17.1"
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

[[ $EUID -eq 0 ]] || { echo "Hace falta root:  sudo $0"; exit 1; }

# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--revertir" || "${1:-}" == "--uninstall" ]]; then
    titulo "Revirtiendo: volver a acer_wmi"
    rm -f "$CONF_BL" "$CONF_LOAD" && ok "quitados los ficheros de configuracion"
    if dkms status "$NOMBRE/$VERSION" 2>/dev/null | grep -q .; then
        dkms remove "$NOMBRE/$VERSION" --all >/dev/null 2>&1 && ok "modulo quitado de DKMS"
    fi
    rm -rf "$DESTINO" && ok "fuente eliminado de /usr/src"
    depmod -a
    modprobe -r linuwu_sense 2>/dev/null
    modprobe sparse_keymap 2>/dev/null
    modprobe acer_wmi predator_v4=1 2>/dev/null && ok "acer_wmi recargado"
    sleep 2
    echo
    info "platform_profile: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo AUSENTE)"
    exit 0
fi

# ---------------------------------------------------------------------------
titulo "1. Comprobaciones"
PROD="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
[[ "$PROD" == "Nitro AN17-51" ]] && ok "modelo: $PROD" || avi "modelo $PROD (esto se escribio para el AN17-51)"
[[ -d "$ORIGEN/src" ]] || { mal "no encuentro el fuente en $ORIGEN"; exit 1; }
ok "fuente: $ORIGEN"
command -v dkms >/dev/null && ok "dkms $(dkms --version 2>/dev/null | head -1)" || { mal "falta dkms:  sudo pacman -S dkms"; exit 1; }
KH="$(pacman -Qq linux-zen-headers 2>/dev/null || pacman -Qq linux-headers 2>/dev/null)"
[[ -n "$KH" ]] && ok "headers: $KH" || { mal "faltan los headers del kernel"; exit 1; }
grep -q "Nitro AN17-51" "$ORIGEN/src/linuwu_sense.c" && ok "el fuente lleva el parche del AN17-51" || { mal "el fuente NO lleva el parche"; exit 1; }
grep -q "strncpy(" "$ORIGEN/src/linuwu_sense.c" && { mal "el fuente aun tiene strncpy(): no compilara en kernel 7.2"; exit 1; } || ok "sin strncpy(): compilara en kernel 7.2+"

# ---------------------------------------------------------------------------
titulo "2. Instalando el fuente en /usr/src"
rm -rf "$DESTINO"
mkdir -p "$DESTINO"
cp -r "$ORIGEN/src" "$ORIGEN/Makefile" "$ORIGEN/dkms.conf" "$DESTINO/"
# Normalizar permisos: el repositorio puede venir de un clon con umask laxo y
# esto acaba en /usr/src, que es codigo de sistema.
chown -R root:root "$DESTINO"
find "$DESTINO" -type d -exec chmod 755 {} +
find "$DESTINO" -type f -exec chmod 644 {} +
ok "$DESTINO"

# ---------------------------------------------------------------------------
titulo "3. Compilando con DKMS"
dkms remove "$NOMBRE/$VERSION" --all >/dev/null 2>&1 || true
if dkms add "$NOMBRE/$VERSION" >/dev/null 2>&1; then ok "anadido a DKMS"; else mal "dkms add fallo"; exit 1; fi
if dkms build "$NOMBRE/$VERSION" >/tmp/dkms-nitro.log 2>&1; then
    ok "compilado"
else
    mal "dkms build fallo. Ultimas lineas:"
    tail -15 /tmp/dkms-nitro.log | sed 's/^/      /'
    exit 1
fi
if dkms install "$NOMBRE/$VERSION" >>/tmp/dkms-nitro.log 2>&1; then ok "instalado"; else mal "dkms install fallo"; exit 1; fi
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
# Para volver atras:  sudo ./packaging/instalar-rgb.sh --revertir
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
FALLOS=0
P="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo AUSENTE)"
if [[ "$P" != AUSENTE ]]; then
    ok "platform_profile: $P"
    info "perfiles: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null)"
else mal "platform_profile AUSENTE"; FALLOS=1; fi

HW=""; for d in /sys/class/hwmon/hwmon*; do [[ "$(cat "$d/name" 2>/dev/null)" == acer ]] && HW="$d"; done
if [[ -n "$HW" ]]; then ok "tacometros: fan1=$(cat "$HW/fan1_input") fan2=$(cat "$HW/fan2_input")  ($HW)"
else mal "hwmon 'acer' AUSENTE"; FALLOS=1; fi

BASE=/sys/devices/platform/acer-wmi
if [[ -d "$BASE/four_zoned_kb" ]]; then
    ok "RGB de 4 zonas: $BASE/four_zoned_kb"
    ls "$BASE/four_zoned_kb" | sed 's/^/        /'
else mal "four_zoned_kb AUSENTE: no habra RGB"; FALLOS=1; fi

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
if (( FALLOS )); then
    echo "  ${R}Hubo fallos.${F} Para volver atras:  sudo $0 --revertir"
    exit 1
fi
echo "  ${V}Driver instalado y verificado.${F}"
echo "  Sobrevive a las actualizaciones de kernel gracias a DKMS."
echo "  Para volver a acer_wmi:  sudo $0 --revertir"
