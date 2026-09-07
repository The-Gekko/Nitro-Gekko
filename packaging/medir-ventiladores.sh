#!/usr/bin/env bash
#
# Mide el SUELO REAL de los ventiladores de este portatil.
#
# POR QUE EXISTE ESTE SCRIPT
#
# El minimo que la aplicacion deja poner a mano (FAN_MIN_PCT) esta elegido a
# ojo, no medido, y eso desentona con todo lo demas del proyecto.  Esto lo
# mide: barre el porcentaje de arriba abajo escribiendo en fan_speed y anota
# las RPM que devuelve el hwmon en cada escalon.  Lo que se busca es el
# porcentaje mas bajo en el que los DOS ventiladores siguen girando.
#
#   sudo ./packaging/medir-ventiladores.sh              barrido completo
#        ./packaging/medir-ventiladores.sh --revisar    dice que haria, sin
#                                                       tocar nada ni pedir root
#   sudo ./packaging/medir-ventiladores.sh --segundos 15   mas tiempo por escalon
#
# SEGURIDAD
#
# Nada de esto es permanente y NO hay forma de salir dejando los ventiladores
# fijos: hay un trap en EXIT, INT y TERM que devuelve 0,0 (automatico) pase lo
# que pase, incluido Ctrl+C o un fallo a mitad.  Y si el trap no llegara a
# ejecutarse, queda una segunda salida: poner el perfil termico en Silencioso o
# Bajo consumo hace que el propio driver llame a acer_set_fan_speed(0,0).
#
# Bajar el ventilador NO puentea ninguna proteccion: el PROCHOT/TCC del chip
# sigue estando, asi que lo peor que puede pasar con el equipo en reposo es que
# suba la temperatura y la CPU se limite sola.  Aun asi, hazlo EN REPOSO: no
# midas con una compilacion o un juego de fondo.
#
# Codigos de salida:  0 bien   1 abortado (falta root, falta el driver)
#                     2 opcion desconocida
#
set -uo pipefail

VENT="/sys/devices/platform/acer-wmi/nitro_sense/fan_speed"
SEGUNDOS=10
MODO="medir"

while (( $# )); do
    case "$1" in
        --revisar|-n|--dry-run) MODO="revisar" ;;
        --segundos) shift; SEGUNDOS="${1:-10}" ;;
        -h|--help|--ayuda)
            awk '/^# /{sub(/^# ?/,""); print} /^set -/{exit}' "$0"
            exit 0 ;;
        *) echo "Opcion desconocida: $1  (prueba $0 --help)" >&2; exit 2 ;;
    esac
    shift
done

if [[ -t 1 ]]; then
    N=$'\e[1m'; V=$'\e[32m'; A=$'\e[33m'; R=$'\e[31m'; F=$'\e[0m'
else
    N=""; V=""; A=""; R=""; F=""
fi
info() { echo "  $*"; }
ok()   { echo "${V}==>${F} $*"; }
avi()  { echo "${A}==>${F} $*"; }
mal()  { echo "${R}==>${F} $*" >&2; }
titulo() { echo; echo "${N}$*${F}"; }

# ---------------------------------------------------------------------------
#  Donde estan los tacometros.  Por NOMBRE, nunca por numero: el numero de
#  hwmon cambia entre arranques (es el gotcha 6 del README).
# ---------------------------------------------------------------------------
hwmon_acer() {
    local d
    for d in /sys/class/hwmon/hwmon*; do
        [[ -r "$d/name" ]] || continue
        if [[ "$(cat "$d/name" 2>/dev/null)" == *acer* ]]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 1
}

rpm() {  # $1 = fichero (fan1_input | fan2_input)
    local h; h="$(hwmon_acer)" || { echo "-"; return; }
    cat "$h/$1" 2>/dev/null || echo "-"
}

titulo "1. Comprobaciones"

if [[ ! -e "$VENT" ]]; then
    mal "No existe $VENT."
    mal "Hace falta el driver linuwu_sense:  sudo ./packaging/instalar-rgb.sh"
    exit 1
fi
ok "fan_speed existe.  Valor ahora mismo: $(cat "$VENT" 2>/dev/null)"

if ! HW="$(hwmon_acer)"; then
    mal "No hay ningun hwmon llamado 'acer': sin tacometros no hay nada que medir."
    exit 1
fi
ok "Tacometros en $HW  (CPU $(rpm fan1_input) rpm, GPU $(rpm fan2_input) rpm)"

PERFIL="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo desconocido)"
info "Perfil termico actual: $PERFIL"
if [[ "$PERFIL" == "quiet" || "$PERFIL" == "low-power" ]]; then
    avi "OJO: en '$PERFIL' el driver devuelve los ventiladores al automatico el"
    avi "solo, asi que la medida saldria mal.  Pon Equilibrado antes."
fi

# Escalones: de 100 a 10 de diez en diez, y de 9 a 1 de uno en uno, que es
# donde esta lo que se busca.
ESCALONES=(100 90 80 70 60 50 40 30 20 15 10 9 8 7 6 5 4 3 2 1)

if [[ "$MODO" == "revisar" ]]; then
    titulo "2. Esto es lo que HARIA, sin hacerlo"
    info "Para cada uno de estos ${#ESCALONES[@]} escalones:"
    info "  ${ESCALONES[*]}"
    info "escribiria '<n>,<n>' en fan_speed, esperaria $SEGUNDOS s y anotaria las RPM."
    info "Al terminar, y tambien si se interrumpe, escribiria '0,0' (automatico)."
    info
    info "Duracion aproximada: $(( ${#ESCALONES[@]} * SEGUNDOS / 60 )) min $(( ${#ESCALONES[@]} * SEGUNDOS % 60 )) s."
    info "Ejecutalo de verdad con:  sudo $0"
    exit 0
fi

[[ $EUID -eq 0 ]] || { mal "Hace falta root:  sudo $0   ($0 --revisar no lo necesita)"; exit 1; }

# ---------------------------------------------------------------------------
#  La red de seguridad.  Se arma ANTES de la primera escritura.
# ---------------------------------------------------------------------------
restaurar() {
    local codigo=$?
    echo
    if printf '0,0' > "$VENT" 2>/dev/null; then
        ok "Ventiladores devueltos al automatico (fan_speed = $(cat "$VENT"))."
    else
        mal "NO se ha podido devolver los ventiladores al automatico."
        mal "Hazlo a mano:  echo '0,0' | sudo tee $VENT"
        mal "O pon el perfil en Silencioso, que hace lo mismo desde el driver."
    fi
    exit $codigo
}
trap restaurar EXIT INT TERM

titulo "2. Barrido  (Ctrl+C en cualquier momento: se restaura solo)"
printf '  %-5s  %10s  %10s\n' "%" "CPU rpm" "GPU rpm"
printf '  %-5s  %10s  %10s\n' "-----" "----------" "----------"

SUELO=""
for pct in "${ESCALONES[@]}"; do
    if ! printf '%s,%s' "$pct" "$pct" > "$VENT" 2>/dev/null; then
        printf '  %-5s  %10s  %10s   %s\n' "$pct" "-" "-" "el driver lo rechaza"
        continue
    fi
    sleep "$SEGUNDOS"
    c="$(rpm fan1_input)"; g="$(rpm fan2_input)"
    marca=""
    if [[ "$c" =~ ^[0-9]+$ && "$g" =~ ^[0-9]+$ ]]; then
        if (( c > 0 && g > 0 )); then
            SUELO="$pct"
        else
            marca="   <- algun ventilador PARADO"
        fi
    fi
    printf '  %-5s  %10s  %10s%s\n' "$pct" "$c" "$g" "$marca"
done

titulo "3. Resultado"
if [[ -n "$SUELO" ]]; then
    ok "Suelo medido: ${SUELO} %  (el mas bajo con los dos ventiladores girando)."
    info
    info "Si quieres usarlo como minimo de la aplicacion, cambialo en LOS DOS"
    info "sitios donde vive, o la interfaz ofrecera un valor que el helper"
    info "rechaza con codigo 2:"
    info "    packaging/nitro-gekko-helper   FAN_MIN_PCT"
    info "    src/gekkonitro/sysfs.py        FAN_MIN_PCT"
    info
    info "Y apunta la tabla de arriba en AGENTS.md: deja de ser una eleccion"
    info "para pasar a ser una medida, que es lo que pide este proyecto."
else
    avi "No se ha podido determinar el suelo: revisa la tabla de arriba."
fi
