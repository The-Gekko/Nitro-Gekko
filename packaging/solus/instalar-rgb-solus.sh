#!/usr/bin/env bash
#
# Driver del teclado RGB (linuwu_sense) en Solus, SIN DKMS.
#
# No hace falta llamarlo por su nombre: packaging/instalar-rgb.sh detecta
# Solus y le pasa el control con los mismos argumentos.
#
#   sudo ./packaging/instalar-rgb.sh              instala
#   sudo ./packaging/instalar-rgb.sh --revertir   desinstala y devuelve acer_wmi
#        ./packaging/instalar-rgb.sh --help       esta ayuda (no pide root)
#
# POR QUE NO VALE EL DE ARCH
# --------------------------
# Solus no empaqueta DKMS y eopkg no admite hooks de terceros.  El modulo se
# ata al vermagic exacto del kernel, y Solus saca kernel casi cada semana: sin
# nada que lo recompile, la primera actualizacion dejaria el portatil con
# acer_wmi en la lista negra y sin linuwu_sense, o sea sin perfiles, sin
# tacometros y sin RGB.
#
# QUE HACE EN SU LUGAR
# --------------------
#  1. Compila con make contra /usr/lib/modules/<kernel>/build y deja el .ko en
#     /usr/lib/modules/<kernel>/updates/.  Medido en este equipo: 2,6 s.
#  2. nitro-gekko-rgb-solus.service lo recompila al arrancar con un kernel
#     nuevo y cambia acer_wmi por linuwu_sense en caliente.
#  3. RED DE SEGURIDAD: la lista negra de acer_wmi va con una linea 'install'
#     en /etc/modprobe.d/nitro-gekko-rgb.conf.  Si linuwu_sense no carga (no
#     compilado para ese kernel, o falla), carga acer_wmi, que con
#     predator_v4=1 da perfiles y RPM.  Un kernel nuevo sin el modulo ya no
#     deja el equipo sin perfiles: lo peor es arrancar sin RGB unos segundos.
#  4. Antes de dar la instalacion por buena, PRUEBA esa red de seguridad de
#     verdad: aparta el .ko, comprueba que entra acer_wmi con perfiles y lo
#     devuelve.  Si algo de eso falla, lo deshace todo.
#
# Requisitos (el instalador facil, ./instalar.sh, los pone solo):
#   sudo eopkg install gcc make binutils cpio zstd linux-current-headers
#   (linux-lts-headers si arrancas con el kernel lts)
#
# Codigos de salida: 0 bien, 1 abortado o revertido, 2 opcion desconocida.
#
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
DIR_BIN=/usr/lib/nitro-gekko-rgb
BIN="$DIR_BIN/nitro-gekko-rgb-solus"
UNIDAD=/etc/systemd/system/nitro-gekko-rgb-solus.service
CONF_BL=/etc/modprobe.d/nitro-gekko-rgb.conf
CONF_LOAD=/etc/modules-load.d/linuwu-sense.conf
CONF_ACER=/etc/modprobe.d/acer-wmi.conf
MARCA_ACER='# puesto-por-nitro-gekko'
KVER="$(uname -r)"
KO="/usr/lib/modules/$KVER/updates/linuwu_sense.ko"

# Nombre y version se leen de rgb/dkms.conf, que es la unica fuente: asi no
# hay un tercer sitio que mantener a mano cuando cambie la version (ver
# «Donde vive cada version» en el README).
NOMBRE="$(sed -n 's/^PACKAGE_NAME="\(.*\)"$/\1/p'    "$RAIZ/rgb/dkms.conf" 2>/dev/null | head -1)"
VERSION="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$RAIZ/rgb/dkms.conf" 2>/dev/null | head -1)"
FUENTE="/usr/src/${NOMBRE}-${VERSION}"

if [[ -t 1 ]]; then V=$'\033[32m'; R=$'\033[31m'; A=$'\033[33m'; C=$'\033[36m'; N=$'\033[1m'; F=$'\033[0m'
else V=; R=; A=; C=; N=; F=; fi
titulo(){ echo; echo "${N}${C}$*${F}"; }
ok(){   echo "  ${V}ok${F}    $*"; }
mal(){  echo "  ${R}mal${F}   $*"; }
avi(){  echo "  ${A}··${F}    $*"; }
info(){ echo "        $*"; }

ayuda() {
    awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

case "${1:-}" in
    --revertir|--uninstall|--desinstalar) ACCION="revertir" ;;
    -h|--help|--ayuda)                    ayuda; exit 0 ;;
    "")                                   ACCION="instalar" ;;
    *) echo "Opcion desconocida: $1  (prueba ./packaging/instalar-rgb.sh --help)"; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    echo "Sobran argumentos: $*"; exit 2
fi
[[ $EUID -eq 0 ]] || { echo "Hace falta root:  sudo ./packaging/instalar-rgb.sh   (--help no lo necesita)"; exit 1; }

cargado() { grep -q "^$1 " /proc/modules; }
hwmon_acer() {
    local d
    for d in /sys/class/hwmon/hwmon*; do
        [[ "$(cat "$d/name" 2>/dev/null)" == acer ]] && { echo "$d"; return 0; }
    done
    return 1
}
# Tras cargar un driver, platform_profile y el hwmon tardan un poco en
# aparecer.  Se espera hasta 5 s en vez de un sleep fijo.
esperar_perfiles() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -e /sys/firmware/acpi/platform_profile ]] && hwmon_acer >/dev/null && return 0
        sleep 0.5
    done
    return 1
}
# El paquete de headers depende del kernel con el que se arranca.
paquete_headers() {
    case "$KVER" in
        *.lts) echo linux-lts-headers ;;
        *)     echo linux-current-headers ;;
    esac
}

# ---------------------------------------------------------------------------
#  Revertir: volver a acer_wmi
# ---------------------------------------------------------------------------
revertir() {
    titulo "Revirtiendo: volver a acer_wmi"
    local f

    # EL CAMBIO DE DRIVER VA ANTES DE BORRAR NADA.  Antes se borraba el .ko,
    # se hacia depmod y DESPUES 'modprobe -r linuwu_sense': modprobe ya no
    # encontraba el modulo en el indice, no descargaba nada (el error iba a
    # /dev/null) y linuwu_sense se quedaba cargado en memoria.  Como da los
    # mismos perfiles que acer_wmi, la comprobacion de abajo se lo creia y el
    # script decia «acer_wmi al mando» con linuwu_sense en /proc/modules
    # (comprobado el 2026-09-25).  rmmod va de respaldo: descarga por nombre,
    # sin mirar el indice.
    if cargado linuwu_sense; then
        if modprobe -r linuwu_sense 2>/dev/null || rmmod linuwu_sense 2>/dev/null; then
            ok "linuwu_sense descargado"
        else
            mal "no se pudo descargar linuwu_sense (en uso?): se ira al reiniciar"
        fi
    fi
    modprobe sparse_keymap 2>/dev/null
    cargado acer_wmi || modprobe acer_wmi predator_v4=1 2>/dev/null

    systemctl disable "$(basename "$UNIDAD")" >/dev/null 2>&1
    for f in "$CONF_BL" "$CONF_LOAD" "$UNIDAD"; do
        if [[ -e "$f" ]]; then
            rm -f "$f" && ok "borrado $f"
        else
            info "$f no estaba"
        fi
    done
    systemctl daemon-reload
    for f in /usr/lib/modules/*/updates/linuwu_sense.ko; do
        [[ -e "$f" ]] || continue
        rm -f "$f" && ok "borrado $f"
        rmdir "$(dirname "$f")" 2>/dev/null
    done
    for f in "$DIR_BIN" /usr/src/linuwu-sense-*; do
        [[ -e "$f" ]] && rm -rf "$f" && ok "borrado $f"
    done
    depmod -a

    # Igual que instalar-rgb.sh --revertir: sin predator_v4=1 persistente, el
    # proximo arranque seria sin perfiles.  Se deja con la marca, para que
    # 'preparar-sistema.sh --revertir' sepa que lo puso este proyecto.
    if [[ -f "$CONF_ACER" ]] && grep -q 'predator_v4=1' "$CONF_ACER"; then
        ok "$CONF_ACER ya fija predator_v4=1 (los perfiles sobreviven al reinicio)"
    else
        install -d "$(dirname "$CONF_ACER")"
        [[ -f "$CONF_ACER" ]] && printf '\n' >> "$CONF_ACER"
        {
            printf '%s\n' "$MARCA_ACER"
            printf '%s\n' '# Escrito por packaging/instalar-rgb.sh --revertir (Solus).  Sin'
            printf '%s\n' '# predator_v4=1 el acer-wmi de mainline no crea platform_profile ni el'
            printf '%s\n' '# hwmon de los ventiladores en este modelo.'
            printf '%s\n' '# Para quitarlo:  sudo ./packaging/preparar-sistema.sh --revertir'
            printf '%s\n' 'options acer_wmi predator_v4=1'
        } >> "$CONF_ACER" && ok "escrito $CONF_ACER (predator_v4=1 persistente)"
    fi

    # Se mira QUE driver hay, no solo que haya perfiles: linuwu_sense tambien
    # los da, y fiarse solo de platform_profile es lo que hizo mentir a la
    # version anterior.
    if cargado acer_wmi && ! cargado linuwu_sense && esperar_perfiles; then
        ok "acer_wmi al mando: platform_profile = $(cat /sys/firmware/acpi/platform_profile)"
    elif cargado linuwu_sense; then
        mal "linuwu_sense sigue cargado en memoria: reinicia para volver a acer_wmi"
    else
        mal "no han vuelto los perfiles termicos: reinicia"
    fi
    info "gcc, make, cpio, zstd y $(paquete_headers) siguen instalados;"
    info "quitalos con eopkg si no los usas para otra cosa."
    info "/etc/four_zone_kb_state y /etc/predator_state los escribe el propio"
    info "modulo al descargarse; no estorban, pero puedes borrarlos."
}

if [[ "$ACCION" == "revertir" ]]; then
    revertir
    exit 0
fi

# ---------------------------------------------------------------------------
titulo "1. Comprobaciones"
# ---------------------------------------------------------------------------
PROD="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
if [[ "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" != Acer ]]; then
    mal "este equipo no es un Acer: linuwu_sense no tendria a que engancharse"
    info "No se instala nada. Abortado."
    exit 1
fi
if [[ "$PROD" == "Nitro AN17-51" ]]; then
    ok "modelo: $PROD"
else
    avi "modelo ${PROD:-desconocido} (esto se escribio para el AN17-51)"
    info "Si no se crean los perfiles, el paso 5 lo deshace solo."
fi

if [[ -z "$NOMBRE" || -z "$VERSION" || ! -d "$RAIZ/rgb/src" || ! -f "$RAIZ/rgb/Makefile" ]]; then
    mal "fuente incompleto en $RAIZ/rgb (falta src/, Makefile o dkms.conf)"
    info "Clona el repositorio completo: rgb/ va con el."
    exit 1
fi
ok "fuente: $RAIZ/rgb  (${NOMBRE} ${VERSION}, leido de rgb/dkms.conf)"

FALTAN=()
for p in gcc make; do command -v "$p" >/dev/null || FALTAN+=("$p"); done
[[ -d "/usr/lib/modules/$KVER/build/include" ]] || FALTAN+=("$(paquete_headers)")
if (( ${#FALTAN[@]} )); then
    mal "falta: ${FALTAN[*]}"
    info "Instalalo con:"
    info "    sudo eopkg install gcc make binutils cpio zstd $(paquete_headers)"
    exit 1
fi
ok "gcc, make y headers de $KVER"

if [[ -f "$CONF_ACER" ]] && grep -q 'predator_v4=1' "$CONF_ACER"; then
    ok "$CONF_ACER con predator_v4=1 (es lo que usa la red de seguridad)"
else
    mal "falta predator_v4=1 en $CONF_ACER"
    info "Sin el, la red de seguridad cargaria un acer_wmi sin perfiles."
    info "Ejecuta antes:  sudo ./packaging/preparar-sistema.sh"
    exit 1
fi

# Si acer_wmi viajara dentro del initramfs se cargaria antes de leer la lista
# negra.  No es grave (el servicio lo cambia al arrancar), pero se dice.  Sin
# cpio o zstd no se puede mirar, y entonces se dice eso, no «no va».
if command -v cpio >/dev/null && command -v zstdcat >/dev/null; then
    EN_INITRD=0
    for f in /usr/lib/kernel/initrd-*; do
        [[ -f "$f" ]] || continue
        # Sustitucion de proceso y no tuberia (regla 20 del README).
        if grep -q 'acer-wmi\.ko' < <({ zstdcat "$f" 2>/dev/null || cat "$f"; } | cpio -it 2>/dev/null); then
            avi "acer_wmi va dentro de $(basename "$f"): el servicio lo cambiara en cada arranque"
            EN_INITRD=1
        fi
    done
    (( EN_INITRD )) || ok "acer_wmi no va en el initramfs: la lista negra actua desde el arranque"
else
    avi "sin cpio o zstd no se puede mirar el initramfs (sudo eopkg install cpio zstd)"
fi

# ---------------------------------------------------------------------------
titulo "2. Fuente y script de arranque"
# ---------------------------------------------------------------------------
# Se borran tambien fuentes de versiones anteriores: el script de arranque
# compila el que encuentre en /usr/src/linuwu-sense-*, y tiene que haber uno.
for f in /usr/src/linuwu-sense-*; do
    [[ -e "$f" && "$f" != "$FUENTE" ]] && rm -rf "$f" && avi "borrado un fuente antiguo: $f"
done
rm -rf "$FUENTE"
if ! { install -d "$FUENTE" && cp -r "$RAIZ/rgb/src" "$RAIZ/rgb/Makefile" "$FUENTE/"; }; then
    mal "no se pudo copiar el fuente a $FUENTE (disco lleno? /usr de solo lectura?)"
    rm -rf "$FUENTE"
    exit 1
fi
chown -R root:root "$FUENTE"
find "$FUENTE" -type d -exec chmod 755 {} +
find "$FUENTE" -type f -exec chmod 644 {} +
ok "$FUENTE"
install -Dm755 "$AQUI/nitro-gekko-rgb-solus" "$BIN" && ok "$BIN"

# ---------------------------------------------------------------------------
titulo "3. Compilando para $KVER"
# ---------------------------------------------------------------------------
rm -f "$KO"
"$BIN" compilar "$KVER" | sed 's/^/        /'
if [[ ! -f "$KO" ]]; then
    mal "no se ha compilado: no se toca nada mas (acer_wmi sigue al mando)"
    exit 1
fi
ok "$KO"
info "vermagic: $(modinfo -F vermagic "$KO")"

# ---------------------------------------------------------------------------
titulo "4. Configuracion de arranque"
# ---------------------------------------------------------------------------
install -Dm644 "$AQUI/nitro-gekko-rgb.conf" "$CONF_BL" && ok "$CONF_BL (lista negra + red de seguridad)"
# Solus es stateless: /etc/modules-load.d no existe hasta que alguien lo crea.
# Antes aqui habia un 'echo >' a secas y fallaba con «No existe el fichero o
# el directorio» (comprobado el 2026-09-25).
install -d "$(dirname "$CONF_LOAD")" && echo linuwu_sense > "$CONF_LOAD" && ok "$CONF_LOAD"
install -Dm644 "$AQUI/nitro-gekko-rgb-solus.service" "$UNIDAD"
systemctl daemon-reload
systemctl enable "$(basename "$UNIDAD")" >/dev/null 2>&1 && ok "$(basename "$UNIDAD") activado"
# 'modprobe -c' (la configuracion efectiva) y no 'modprobe -n -v': este
# ultimo no ensena NADA si linuwu_sense ya esta cargado, y en una
# reinstalacion lo esta.  Daba un aviso falso (comprobado el 2026-09-25).
if grep -q '^install linuwu_sense ' < <(modprobe -c 2>/dev/null); then
    ok "modprobe ve la regla 'install' de linuwu_sense"
else
    avi "modprobe no muestra la regla 'install': revisa $CONF_BL"
fi

# ---------------------------------------------------------------------------
titulo "5. Cambiando de driver ahora"
# ---------------------------------------------------------------------------
PERFIL="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo balanced)"
cargado acer_wmi && modprobe -r acer_wmi && ok "acer_wmi descargado"
# Por la ruta normal, con la regla 'install', igual que en el arranque.
modprobe linuwu_sense
if cargado linuwu_sense && esperar_perfiles; then
    ok "linuwu_sense cargado"
else
    mal "linuwu_sense no da perfiles en este equipo: deshaciendo"
    revertir
    exit 1
fi

# ---------------------------------------------------------------------------
titulo "6. Probando la red de seguridad (simula un kernel nuevo sin compilar)"
# ---------------------------------------------------------------------------
modprobe -r linuwu_sense
mv "$KO" "$KO.prueba" && depmod -a "$KVER"
modprobe linuwu_sense 2>/dev/null   # la regla 'install' tiene que caer en acer_wmi
RED=0
if cargado acer_wmi && ! cargado linuwu_sense && esperar_perfiles \
   && [[ "$(cat /sys/module/acer_wmi/parameters/predator_v4 2>/dev/null)" == Y ]]; then
    ok "sin el .ko entra acer_wmi con predator_v4=Y: $(cat /sys/firmware/acpi/platform_profile_choices)"
    RED=1
else
    mal "la red de seguridad NO ha funcionado"
fi
# Y lo que hara el servicio en el arranque siguiente: volver a linuwu_sense.
mv "$KO.prueba" "$KO" && depmod -a "$KVER"
"$BIN" arrancar | sed 's/^/        /'
if ! cargado linuwu_sense || ! esperar_perfiles; then
    mal "no se ha podido volver a linuwu_sense: deshaciendo"
    revertir
    exit 1
fi
ok "el servicio de arranque vuelve a poner linuwu_sense"
if (( ! RED )); then
    mal "sin red de seguridad esto no se deja instalado: deshaciendo"
    revertir
    exit 1
fi

# ---------------------------------------------------------------------------
titulo "7. Verificacion"
# ---------------------------------------------------------------------------
echo "$PERFIL" > /sys/firmware/acpi/platform_profile 2>/dev/null
ok "platform_profile: $(cat /sys/firmware/acpi/platform_profile)  ($(cat /sys/firmware/acpi/platform_profile_choices))"
HW="$(hwmon_acer)" && ok "tacometros: fan1=$(cat "$HW/fan1_input") fan2=$(cat "$HW/fan2_input") rpm"
BASE=/sys/devices/platform/acer-wmi
if [[ -d "$BASE/four_zoned_kb" ]]; then
    ok "teclado RGB de 4 zonas: $(ls "$BASE/four_zoned_kb" | tr '\n' ' ')"
else
    avi "four_zoned_kb AUSENTE: tu modelo no esta en la tabla DMI del driver"
    info "Perfiles y tacometros si funcionan; simplemente no hay RGB que dar."
fi
[[ -d "$BASE/nitro_sense" ]] && ok "nitro_sense: $(ls "$BASE/nitro_sense" | tr '\n' ' ')"

# power-profiles-daemon arranco antes de que hubiera platform_profile y se
# queda con el driver 'placeholder' hasta que se reinicia.  Medido el
# 2026-09-25: con platform_profile ya creado en caliente seguia en
# 'placeholder'; tras reiniciarlo, 'platform_profile'.
if systemctl is-active power-profiles-daemon >/dev/null 2>&1; then
    systemctl restart power-profiles-daemon
    sleep 1
    info "power-profiles-daemon: $(powerprofilesctl list 2>/dev/null | grep -m1 PlatformDriver | xargs)"
fi

echo
echo "  ${V}Driver instalado y verificado.${F}"
echo "  Tras cada actualizacion del kernel se recompila solo al arrancar."
echo "  Estado en cualquier momento:  $BIN estado"
echo "  Para volver a acer_wmi:       sudo ./packaging/instalar-rgb.sh --revertir"
exit 0
