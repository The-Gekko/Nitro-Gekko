#!/usr/bin/env bash
#
# Prueba EN CALIENTE del RGB de 4 zonas del teclado del Acer Nitro AN17-51.
#
# Nada de esto persiste: no se instala en /lib/modules, no se toca DKMS, no se
# ejecuta depmod y no se escribe en /etc. Un reinicio deja el sistema exactamente
# como estaba. Ademas hay un `trap` que restaura el driver original aunque el
# script falle a mitad o lo interrumpas con Ctrl+C.
#
# QUE HACE Y POR QUE ES DELICADO
# ------------------------------
# Linuwu-Sense NO convive con el acer_wmi del kernel: lo SUSTITUYE. Los dos
# reclaman los mismos GUID de WMI. Asi que para probar el RGB hay que descargar
# acer_wmi, y con el se van (temporalmente) las tres cosas que hoy funcionan
# gracias a el:
#     /sys/firmware/acpi/platform_profile      (los 5 perfiles termicos)
#     hwmon 'acer' con fan1_input / fan2_input (los tacometros)
#     power-profiles-daemon reportando PlatformDriver
# El script comprueba explicitamente si el driver nuevo las repone, porque de
# eso depende que merezca la pena quedarse con el.
#
# SI ALGO SALE MAL Y EL EC QUEDA RARO (ventiladores fijos, teclado apagado):
#     apaga el portatil, desconecta el cargador, manten pulsado el boton de
#     encendido 30 segundos, vuelve a conectar y enciende. Eso resetea el EC.
#
#   make -C rgb                                 compila el modulo a probar
#   sudo ./packaging/probar-rgb.sh              prueba de verdad (necesita root)
#        ./packaging/probar-rgb.sh --dry-run    dice que haria, sin hacerlo
#        ./packaging/probar-rgb.sh --help       esta ayuda
#
# Si la prueba convence, ./packaging/instalar-rgb.sh lo deja permanente por DKMS.
#
set -uo pipefail

# Raiz del repositorio = el directorio padre de packaging/
RAIZ="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Modulo a probar. Por omision, el que deja `make -C rgb` en el propio
# repositorio: el Makefile declara `obj-m := src/linuwu_sense.o`, asi que
# kbuild escribe el .ko en rgb/src/, no en rgb/.
#
#   cd rgb && make          # compila contra el kernel en marcha
#   sudo ./packaging/probar-rgb.sh
#
# Si ya lo tienes compilado en otro sitio, pasalo por la variable:
#   sudo KO=/ruta/a/linuwu_sense.ko ./packaging/probar-rgb.sh
KO="${KO:-$RAIZ/rgb/src/linuwu_sense.ko}"
SEGUNDOS_MIRAR="${SEGUNDOS_MIRAR:-30}"
# Opciones.  Una opcion que no se reconozca ABORTA: este script descarga
# acer_wmi en caliente, asi que no puede ponerse a hacerlo por haber escrito
# mal un argumento.
DRY=0
case "${1:-}" in
    --dry-run|-n|--revisar) DRY=1 ;;
    -h|--help|--ayuda)
        awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
        exit 0 ;;
    "") ;;
    *) echo "Opcion desconocida: $1  (prueba $0 --help)" >&2; exit 2 ;;
esac
[[ $# -gt 1 ]] && { echo "Sobran argumentos: $*" >&2; exit 2; }

if [[ -t 1 ]]; then V=$'\033[32m'; R=$'\033[31m'; A=$'\033[33m'; N=$'\033[1m'; F=$'\033[0m'
else V=; R=; A=; N=; F=; fi
paso(){ echo; echo "${N}==> $*${F}"; }
ok(){   echo "  ${V}ok${F}  $*"; }
mal(){  echo "  ${R}!!${F}  $*"; }
avi(){  echo "  ${A}··${F}  $*"; }

hwmon_acer(){ for d in /sys/class/hwmon/hwmon*; do [[ "$(cat "$d/name" 2>/dev/null)" == acer ]] && { echo "$d"; return; }; done; }

# ---------------------------------------------------------------------------
#  Restauracion. Se ejecuta SIEMPRE: exito, error o Ctrl+C.
# ---------------------------------------------------------------------------
# Con `trap ... INT`, bash entra aqui con $? = 0 y el script acabaria
# diciendo que todo fue bien tras un Ctrl+C.  Se marca la interrupcion.
INTERRUMPIDO=0
al_interrumpir() { INTERRUMPIDO=1; exit 130; }

restaurar() {
    local rc=$?
    (( INTERRUMPIDO )) && rc=130
    paso "RESTAURANDO el estado original"
    # OJO: "el estado original" es el driver que estaba cargado AL EMPEZAR, no
    # acer_wmi siempre.  Antes se recargaba acer_wmi incondicionalmente, asi que
    # en un equipo que ya tenia linuwu_sense instalado de forma permanente esta
    # prueba DESCARGABA el driver bueno y ponia acer_wmi en su sitio -- dejando
    # al usuario sin RGB hasta reiniciar mientras el script anunciaba "estado
    # original restaurado".  Ahora se repone lo que hubiera.
    if lsmod | grep -q '^linuwu_sense ' && [[ "${DRIVER_PREVIO:-}" != "linuwu_sense" ]]; then
        rmmod linuwu_sense 2>/dev/null && ok "linuwu_sense descargado" || mal "no se pudo descargar linuwu_sense"
    fi
    if [[ "${DRIVER_PREVIO:-}" == "linuwu_sense" ]]; then
        if lsmod | grep -q '^linuwu_sense '; then
            ok "linuwu_sense sigue cargado (era el driver de partida)"
        else
            modprobe linuwu_sense 2>/dev/null && ok "linuwu_sense recargado" \
                || mal "NO se pudo recargar linuwu_sense. Reinicia para volver al estado normal."
        fi
    elif ! lsmod | grep -q '^acer_wmi '; then
        # predator_v4=1 es lo que en ESTE modelo crea platform_profile y el hwmon.
        modprobe acer_wmi predator_v4=1 2>/dev/null && ok "acer_wmi recargado con predator_v4=1" \
            || mal "NO se pudo recargar acer_wmi. Reinicia para volver al estado normal."
    fi
    sleep 2
    local p h
    p="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo AUSENTE)"
    h="$(hwmon_acer)"
    echo
    echo "  Estado tras restaurar:"
    echo "    platform_profile : $p"
    if [[ -n "$h" ]]; then
        echo "    ventiladores     : fan1=$(cat "$h/fan1_input" 2>/dev/null) fan2=$(cat "$h/fan2_input" 2>/dev/null)  ($h)"
    else
        echo "    ventiladores     : ${R}AUSENTES${F}  <-- reinicia si no vuelven"
    fi
    [[ -n "${PERFIL_PREVIO:-}" && "$p" != "AUSENTE" && "$p" != "$PERFIL_PREVIO" ]] && {
        echo "$PERFIL_PREVIO" > /sys/firmware/acpi/platform_profile 2>/dev/null && \
            echo "    perfil devuelto a: $PERFIL_PREVIO"
    }
    exit $rc
}

# ---------------------------------------------------------------------------
paso "Comprobaciones previas"
# El chequeo de root va DESPUES del de --dry-run: un ensayo en seco no toca
# nada, asi que no tiene sentido exigir privilegios para poder leerlo.
(( DRY )) || [[ $EUID -eq 0 ]] || { mal "hay que ejecutarlo como root (pkexec/sudo)."; exit 1; }

como_compilar() {
    avi "Compilalo primero contra el kernel en marcha:"
    avi "    make -C \"$RAIZ/rgb\""
    avi "Si la ruta del repositorio tiene espacios, kbuild no compila ahi."
    avi "Copialo a una ruta limpia y pasa el modulo por la variable KO:"
    avi "    cp -a \"$RAIZ/rgb\" /tmp/rgb && make -C /tmp/rgb"
    avi "    sudo KO=/tmp/rgb/src/linuwu_sense.ko $0"
}

# En --dry-run que falte el modulo NO es motivo para abortar: la gracia del
# ensayo en seco es poder leer el plan completo antes de compilar nada.  Solo
# se aborta cuando la prueba va en serio.
HAY_KO=1
if [[ ! -f "$KO" ]]; then
    HAY_KO=0
    mal "no existe el modulo compilado: $KO"
    como_compilar
    (( DRY )) || exit 1
    avi "Se sigue igualmente porque esto es un ensayo en seco."
else
    ok "modulo: $KO"
    VM_KO="$(modinfo -F vermagic "$KO" 2>/dev/null | tr -d ' ' )"
    VM_SYS="$(uname -r)"
    if [[ "$VM_KO" == "$VM_SYS"* ]]; then
        ok "vermagic coincide con $VM_SYS"
    else
        mal "vermagic del modulo ($VM_KO) NO coincide con el kernel ($VM_SYS)"
        avi "Recompilalo contra $VM_SYS o el kernel rechazara el insmod."
        (( DRY )) || exit 1
    fi
fi

PERFIL_PREVIO="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || true)"
HW_PREVIO="$(hwmon_acer)"
ok "estado previo: perfil=$PERFIL_PREVIO  hwmon=$HW_PREVIO"

# Que driver esta al mando AHORA.  Hace falta para dos cosas: para no romperle
# la instalacion a quien ya tiene linuwu_sense puesto por DKMS, y para que la
# restauracion reponga lo que habia y no acer_wmi por defecto.
DRIVER_PREVIO=""
if lsmod | grep -q '^linuwu_sense '; then DRIVER_PREVIO="linuwu_sense"
elif lsmod | grep -q '^acer_wmi ';     then DRIVER_PREVIO="acer_wmi"
fi
ok "driver al mando: ${DRIVER_PREVIO:-ninguno}"

# Esta prueba es para ANTES de instalar.  Con linuwu_sense ya cargado no tiene
# nada que demostrar y si mucho que estropear: el primer paso ('modprobe -r
# acer_wmi') falla porque acer_wmi ni siquiera esta, y a partir de ahi el script
# solo puede dejar el equipo peor de lo que estaba.
if [[ "$DRIVER_PREVIO" == "linuwu_sense" ]]; then
    mal "linuwu_sense YA esta cargado: este equipo ya tiene el driver del RGB."
    avi "Esta prueba sirve para ver el RGB ANTES de instalar nada, no despues."
    avi "Si lo que quieres es probar un .ko distinto, quita primero el instalado:"
    avi "    sudo ./packaging/instalar-rgb.sh --revertir"
    avi "y vuelve a lanzar esta prueba.  Para comprobar que el RGB funciona sin"
    avi "tocar el driver, abre Nitro Gekko y usa la pagina «Teclado»."
    (( DRY )) || exit 1
    echo
    avi "Se sigue igualmente porque esto es un ensayo en seco."
fi

if (( DRY )); then
    echo
    echo "${N}--dry-run: esto es lo que HARIA, sin hacerlo:${F}"
    echo "  1. modprobe -r acer_wmi"
    echo "  2. modprobe rfkill sparse_keymap wmi video   (dependencias de insmod)"
    echo "  3. insmod $KO"
    echo "  4. buscar el grupo sysfs four_zoned_kb"
    echo "  5. escribir 3 combinaciones de color y esperar 6s entre cada una"
    echo "  6. dejar 4 colores fijos ${SEGUNDOS_MIRAR}s para que mires el teclado"
    echo "  7. comprobar si platform_profile y los tacometros siguen existiendo"
    echo "  8. rmmod linuwu_sense y volver al driver de partida (${DRIVER_PREVIO:-acer_wmi predator_v4=1})"
    echo "     (el paso 8 va en un trap: corre tambien si falla o si haces Ctrl+C)"
    echo
    if [[ "$DRIVER_PREVIO" == "linuwu_sense" ]]; then
        echo "  ${A}Aqui ya manda linuwu_sense, asi que hoy no se ejecutaria:${F}"
        echo "  ${A}el paso 1 fallaria y la prueba no tiene nada que demostrar.${F}"
    elif (( HAY_KO )); then
        echo "  Nada de esto persiste: no se toca /etc, ni DKMS, ni /lib/modules."
        echo "  Para hacerlo de verdad:  sudo $0"
    else
        echo "  ${A}Falta el modulo, asi que hoy no se podria ejecutar.${F}"
    fi
    exit 0
fi

# El EXIT cubre tambien la salida por INT/TERM, porque al_interrumpir llama a
# exit.  Asi la restauracion corre una sola vez, no dos.
trap restaurar EXIT
trap al_interrumpir INT TERM

# ---------------------------------------------------------------------------
paso "Cambiando acer_wmi -> linuwu_sense (en caliente, sin persistir)"
modprobe -r acer_wmi 2>/dev/null && ok "acer_wmi descargado" || { mal "no se pudo descargar acer_wmi"; exit 1; }

# CLAVE: `modprobe -r` no solo quita acer_wmi, tambien arrastra las
# dependencias que se quedan sin usuarios. sparse_keymap tenia UN solo usuario
# (acer_wmi), asi que se descarga con el; e `insmod` -a diferencia de modprobe-
# no resuelve dependencias, de modo que el intento anterior murio con
#     linuwu_sense: Unknown symbol sparse_keymap_setup (err -2)
# Se recargan explicitamente antes de insertar el modulo nuevo.
for dep in rfkill sparse_keymap wmi video; do
    modprobe "$dep" 2>/dev/null || avi "no se pudo cargar $dep"
done
ok "dependencias presentes: $(lsmod | grep -cE '^(rfkill|sparse_keymap|wmi|video) ')/4"

salida_insmod="$(insmod "$KO" 2>&1)"
if [[ -z "$salida_insmod" ]]; then
    ok "linuwu_sense cargado"
else
    mal "insmod fallo: $salida_insmod"
    avi "Simbolos que faltan (si los hay):"
    journalctl -k -n 20 --no-pager 2>/dev/null | grep -i "unknown symbol" | sed 's/^/      /'
    exit 1
fi
sleep 3
dmesg | tail -6 | sed 's/^/      /'

# ---------------------------------------------------------------------------
paso "¿Aparecio el control de RGB de 4 zonas?"
GRUPO="$(find /sys -maxdepth 8 -type d -name four_zoned_kb 2>/dev/null | head -1)"
if [[ -z "$GRUPO" ]]; then
    mal "NO existe el grupo four_zoned_kb."
    avi "El quirk del AN17-51 no se aplico, o el driver no lo registro."
    avi "Comprueba: dmesg | grep -i linuwu"
    exit 1
fi
ok "grupo encontrado: $GRUPO"
ls -l "$GRUPO" | sed 's/^/      /'

# ---------------------------------------------------------------------------
paso "ESCRIBIENDO COLORES — ${N}MIRA EL TECLADO AHORA${F}"
# per_zone_mode: "RRGGBB,RRGGBB,RRGGBB,RRGGBB,brillo"  (4 zonas de izq. a der.)
# Se eligen cuatro colores MUY distintos entre si y muy distintos del naranja
# por defecto, para que no haya ninguna duda de si ha cambiado o no.
SECUENCIA=(
    "ff0000,00ff00,0000ff,ffff00,100|rojo · verde · azul · amarillo"
    "00ffff,00ffff,00ffff,00ffff,100|todo CIAN"
    "ff00ff,ff00ff,ff00ff,ff00ff,100|todo MAGENTA"
)
for entrada in "${SECUENCIA[@]}"; do
    valor="${entrada%%|*}"; desc="${entrada##*|}"
    if echo "$valor" > "$GRUPO/per_zone_mode" 2>/dev/null; then
        ok "escrito: $desc"
    else
        mal "el firmware rechazo: $desc"
    fi
    sleep 6
done

echo
echo "  ${N}Dejando el teclado en 4 colores durante ${SEGUNDOS_MIRAR} segundos.${F}"
echo "  ${N}MIRA EL TECLADO: ¿ves rojo, verde, azul y amarillo por zonas?${F}"
echo "$GRUPO/per_zone_mode <- ff0000,00ff00,0000ff,ffff00,100"
echo "ff0000,00ff00,0000ff,ffff00,100" > "$GRUPO/per_zone_mode" 2>/dev/null || true
sleep "$SEGUNDOS_MIRAR"

# ---------------------------------------------------------------------------
paso "¿El driver nuevo repone lo que daba acer_wmi?"
P_NUEVO="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo AUSENTE)"
[[ "$P_NUEVO" != AUSENTE ]] && ok "platform_profile SIGUE: $P_NUEVO" || mal "platform_profile AUSENTE con linuwu_sense"
CH="$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || echo '-')"
echo "      perfiles: $CH"
H_NUEVO="$(hwmon_acer)"
if [[ -n "$H_NUEVO" ]]; then
    ok "tacometros SIGUEN: fan1=$(cat "$H_NUEVO/fan1_input" 2>/dev/null) fan2=$(cat "$H_NUEVO/fan2_input" 2>/dev/null)"
else
    mal "hwmon 'acer' AUSENTE con linuwu_sense"
    find /sys/devices/platform -maxdepth 4 -name 'fan*_input' 2>/dev/null | sed 's/^/      otro: /'
fi

echo
echo "${N}Fin de la prueba. Ahora se restaura el driver original.${F}"
