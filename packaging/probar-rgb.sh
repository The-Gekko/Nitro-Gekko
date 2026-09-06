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
set -uo pipefail

KO="${KO:-/tmp/claude-1000/-home-the-gekko/af26ab48-d61a-4cc7-84e4-611eca7955e8/scratchpad/linuwu/src/linuwu_sense.ko}"
SEGUNDOS_MIRAR="${SEGUNDOS_MIRAR:-30}"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

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
restaurar() {
    local rc=$?
    paso "RESTAURANDO el estado original"
    if lsmod | grep -q '^linuwu_sense '; then
        rmmod linuwu_sense 2>/dev/null && ok "linuwu_sense descargado" || mal "no se pudo descargar linuwu_sense"
    fi
    if ! lsmod | grep -q '^acer_wmi '; then
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
[[ -f "$KO" ]]    || { mal "no existe el modulo compilado: $KO"; exit 1; }
ok "modulo: $KO"

VM_KO="$(modinfo -F vermagic "$KO" 2>/dev/null | tr -d ' ' )"
VM_SYS="$(uname -r)"
if [[ "$VM_KO" == "$VM_SYS"* ]]; then ok "vermagic coincide con $VM_SYS"
else mal "vermagic del modulo ($VM_KO) NO coincide con el kernel ($VM_SYS)"; exit 1; fi

PERFIL_PREVIO="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || true)"
HW_PREVIO="$(hwmon_acer)"
ok "estado previo: perfil=$PERFIL_PREVIO  hwmon=$HW_PREVIO"

if (( DRY )); then
    echo
    echo "${N}--dry-run: esto es lo que HARIA, sin hacerlo:${F}"
    echo "  1. rmmod acer_wmi"
    echo "  2. insmod $KO"
    echo "  3. buscar el grupo sysfs four_zoned_kb"
    echo "  4. escribir 4 colores distintos y esperar ${SEGUNDOS_MIRAR}s para que mires el teclado"
    echo "  5. comprobar si platform_profile y los tacometros siguen existiendo"
    echo "  6. rmmod linuwu_sense && modprobe acer_wmi predator_v4=1"
    exit 0
fi

trap restaurar EXIT INT TERM

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
