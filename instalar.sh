#!/usr/bin/env bash
#
# Instalacion facil de Nitro Gekko, en Arch o en Solus.
#
# Hace, en este orden y parando si algo sale mal, lo mismo que los pasos
# manuales del README:
#
#   1. instala las dependencias con pacman o con eopkg;
#   2. sudo ./packaging/preparar-sistema.sh   el hardware (predator_v4, PL1,
#                                             atajo del boton de la marca);
#   3. sudo ./packaging/instalar-rgb.sh       el driver del teclado RGB
#                                             (DKMS en Arch; en Solus, sin
#                                             DKMS y con red de seguridad);
#   4. sudo ./packaging/install.sh            la aplicacion.
#
# No hace nada que no hagan ya esos scripts: los llama, con sus avisos y sus
# comprobaciones.  Lo unico propio es elegir los paquetes de cada distribucion.
#
#   sudo ./instalar.sh                    todo
#   sudo ./instalar.sh --sin-extension    todo menos la extension de GNOME Shell
#   sudo ./instalar.sh --sin-rgb          sin el driver del RGB: no se toca
#                                         ningun modulo del kernel
#        ./instalar.sh --revisar          dice que haria; no toca nada ni
#                                         pide root
#   sudo ./instalar.sh --desinstalar      lo quita todo, en orden inverso
#   sudo ./instalar.sh --si ...           no pregunta (para lanzarlo sin
#                                         terminal, por ejemplo con pkexec)
#        ./instalar.sh --help             esta ayuda
#
# Solo Arch y Solus: son las dos distribuciones que mantiene el proyecto.  En
# cualquier otra se planta y remite a los pasos manuales del README.
#
# Variables para PROBARLO sin tener la otra distribucion delante (solo con
# --revisar):
#   OS_RELEASE   fichero os-release.  Por omision /etc/os-release.
#
# Codigos de salida: 0 bien, 1 abortado o fallido, 2 opcion desconocida.
#
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAQ="$RAIZ/packaging"

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

# ---------------------------------------------------------------------------
#  Opciones.  Se leen ANTES de exigir root, y una que no se reconozca ABORTA:
#  este script pone un modulo de kernel en la lista negra de otro, y no puede
#  ponerse a hacerlo por una errata en un argumento.
# ---------------------------------------------------------------------------
ACCION="instalar"
CON_RGB=1
CON_EXTENSION=1
SIN_PREGUNTAR=0
for arg in "$@"; do
    case "$arg" in
        --sin-rgb)                              CON_RGB=0 ;;
        --sin-extension)                        CON_EXTENSION=0 ;;
        --si|--yes)                             SIN_PREGUNTAR=1 ;;
        --revisar|-n|--dry-run)                 ACCION="revisar" ;;
        --desinstalar|--uninstall|--revertir)   ACCION="desinstalar" ;;
        -h|--help|--ayuda)                      ayuda; exit 0 ;;
        *) echo "Opcion desconocida: $arg  (prueba $0 --help)" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
#  Distribucion
# ---------------------------------------------------------------------------
OSR="${OS_RELEASE:-/etc/os-release}"
case " $(sed -n 's/^ID=//p; s/^ID_LIKE=//p' "$OSR" 2>/dev/null | tr -d '"' | tr '\n' ' ') " in
    *" solus "*) DISTRO=solus ;;
    *" arch "*)  DISTRO=arch ;;
    *)           DISTRO=otra ;;
esac
NOMBRE_DISTRO="$(sed -n 's/^PRETTY_NAME=//p' "$OSR" 2>/dev/null | tr -d '"')"
KVER="$(uname -r)"

# Paquetes de cada distribucion.  Los nombres estan sacados de la propia
# distribucion, no de memoria: en Solus con 'eopkg search-file' sobre cada
# fichero que usa la aplicacion (2026-09-25); en Arch, los 'depends' del
# PKGBUILD de packaging/aur/.
#
#   Arch    python python-gobject gtk4 libadwaita polkit power-profiles-daemon
#           libxml2 (xmllint, con el que install.sh valida la politica polkit)
#   Solus   python3 python-gobject libgtk-4 libadwaita polkit
#           power-profiles-daemon libxml2
#
# Para el RGB:
#   Arch    dkms y los headers del kernel CON EL QUE ARRANCAS: se pregunta a
#           pacman a que paquete pertenece /usr/lib/modules/<kernel>/vmlinuz
#           (linux-zen -> linux-zen-headers).  Los de otro kernel no sirven.
#   Solus   gcc make binutils, cpio y zstd (para mirar el initramfs) y
#           linux-current-headers o linux-lts-headers segun el kernel.  En
#           una instalacion recien hecha de Solus 4.9 no hay ninguno.
paquetes() {
    local pkg_kernel
    case "$DISTRO" in
        arch)
            echo python python-gobject gtk4 libadwaita polkit power-profiles-daemon libxml2
            if (( CON_RGB )); then
                echo dkms
                pkg_kernel="$(pacman -Qqo "/usr/lib/modules/$KVER/vmlinuz" 2>/dev/null)"
                if [[ -n "$pkg_kernel" ]]; then
                    echo "${pkg_kernel}-headers"
                fi
            fi ;;
        solus)
            echo python3 python-gobject libgtk-4 libadwaita polkit power-profiles-daemon libxml2
            if (( CON_RGB )); then
                echo gcc make binutils cpio zstd
                case "$KVER" in
                    *.lts) echo linux-lts-headers ;;
                    *)     echo linux-current-headers ;;
                esac
            fi ;;
    esac
}

# Los que faltan, para decirlo antes de instalar.  Sin el gestor de paquetes
# delante (probando con OS_RELEASE) no se puede saber, y se dice.
faltan() {
    local p instalados
    case "$DISTRO" in
        arch)
            command -v pacman >/dev/null || { echo "?"; return; }
            for p in $(paquetes); do pacman -Qq "$p" >/dev/null 2>&1 || echo "$p"; done ;;
        solus)
            command -v eopkg >/dev/null || { echo "?"; return; }
            instalados="$(eopkg list-installed 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $1}')"
            for p in $(paquetes); do grep -qx "$p" <<<"$instalados" || echo "$p"; done ;;
    esac
}

instalar_paquetes() {
    local lista
    # Solo los que faltan.  Llamar a eopkg con todo ya instalado no es gratis:
    # cada operacion termina en usysconf, que reaplica presets y hace sync().
    lista="$(faltan | tr '\n' ' ')"
    lista="${lista% }"
    if [[ -z "$lista" ]]; then
        ok "ya estaban todas: $(paquetes | tr '\n' ' ')"
        return 0
    fi
    info "faltan: $lista"
    case "$DISTRO" in
        arch)
            # Sin -y a proposito: 'pacman -Sy paquete' es una actualizacion
            # parcial, que en Arch no esta soportada.  Si la base de datos esta
            # vieja y falla, la orden correcta es actualizar el sistema entero.
            # shellcheck disable=SC2086
            pacman -S --needed $( (( SIN_PREGUNTAR )) && echo --noconfirm ) $lista || {
                mal "pacman ha fallado"
                info "Si dice que no encuentra un paquete, actualiza antes el sistema:"
                info "    sudo pacman -Syu"
                return 1
            }
            if (( CON_RGB )) && ! pacman -Qqo "/usr/lib/modules/$KVER/vmlinuz" >/dev/null 2>&1; then
                avi "no se sabe de que paquete es el kernel $KVER: instala sus headers a mano"
            fi ;;
        solus)
            # eopkg termina ejecutando usysconf, que hace un sync().  Con mucha
            # escritura pendiente en otro disco (una descarga de Steam a un USB,
            # por ejemplo) se queda ahi varios minutos: no esta colgado.
            # shellcheck disable=SC2086
            eopkg install $( (( SIN_PREGUNTAR )) && echo -y ) $lista || {
                mal "eopkg ha fallado"
                info "Actualiza el sistema y vuelve a probar:  sudo eopkg upgrade"
                return 1
            } ;;
    esac
}

# ---------------------------------------------------------------------------
#  Lo que se va a hacer, dicho antes
# ---------------------------------------------------------------------------
plan() {
    local f
    titulo "Nitro Gekko: instalacion facil"
    info "Sistema : ${NOMBRE_DISTRO:-?}  (kernel $KVER)"
    info "Equipo  : $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    if [[ "$(sed -n 's/^ID=//p' "$OSR" 2>/dev/null | tr -d '"')" != "$DISTRO" ]]; then
        avi "derivada de $DISTRO, no $DISTRO: no esta probada; se usan las ordenes de $DISTRO"
    fi
    echo
    info "1. Dependencias: $(paquetes | tr '\n' ' ')"
    f="$(faltan | tr '\n' ' ')"
    if [[ "$f" == "? " ]]; then
        info "   (no se puede saber cuales faltan: no hay gestor de paquetes de $DISTRO aqui)"
    elif [[ -n "$f" ]]; then
        info "   faltan: $f"
    else
        info "   estan todas"
    fi
    info "2. Hardware: acer_wmi con predator_v4=1, PL1 a la potencia base del chip,"
    info "   boton de la marca -> Nitro Gekko  (packaging/preparar-sistema.sh)"
    if (( CON_RGB )); then
        info "3. Driver del teclado RGB: linuwu_sense, y acer_wmi a la LISTA NEGRA"
        if [[ "$DISTRO" == solus ]]; then
            info "   Solus: sin DKMS; se recompila al arrancar con un kernel nuevo y, si"
            info "   no puede, entra acer_wmi con perfiles (red de seguridad)"
        else
            info "   Arch: por DKMS.  Si un kernel nuevo no lo compila, arrancas sin"
            info "   perfiles ni RPM hasta arreglarlo (README, «El riesgo real de este paso»)"
        fi
    else
        info "3. Driver del teclado RGB: NO (--sin-rgb).  No se toca ningun modulo."
    fi
    if (( CON_EXTENSION )); then
        info "4. Aplicacion y extension de GNOME Shell  (packaging/install.sh)"
    else
        info "4. Aplicacion, sin la extension de GNOME Shell  (packaging/install.sh --sin-extension)"
    fi
}

# ---------------------------------------------------------------------------
#  Principal
# ---------------------------------------------------------------------------
if [[ "$DISTRO" == otra ]]; then
    mal "${NOMBRE_DISTRO:-esta distribucion} no esta soportada: solo Arch y Solus."
    info "Los pasos manuales del README te dicen que hace falta; los scripts de"
    info "packaging/ no dependen de la distribucion salvo por los avisos."
    exit 1
fi

if [[ "$ACCION" == "revisar" ]]; then
    plan
    titulo "Diagnostico del hardware (no toca nada)"
    "$PAQ/preparar-sistema.sh" --revisar
    echo
    echo "  Modo revision: no se ha tocado nada."
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo "Hace falta root:  sudo $0 $*   (--revisar no lo necesita)"; exit 1; }

if [[ "$ACCION" == "desinstalar" ]]; then
    titulo "Nitro Gekko: desinstalando, en orden inverso al de instalacion"
    if (( ! SIN_PREGUNTAR )); then
        [[ -t 0 ]] || { mal "sin terminal no se puede preguntar: anade --si"; exit 1; }
        read -r -p "  ¿Quitar la aplicacion, el driver del RGB y los ajustes del sistema? [s/N] " r
        [[ "$r" == [sS]* ]] || { echo "  Cancelado."; exit 1; }
    fi
    FALLO=0
    "$PAQ/install.sh" --uninstall || FALLO=1
    # El driver solo se revierte si esta puesto: revertirlo recarga modulos.
    if [[ -e /etc/modprobe.d/nitro-gekko-rgb.conf ]] || grep -q '^linuwu_sense ' /proc/modules; then
        "$PAQ/instalar-rgb.sh" --revertir || FALLO=1
    else
        info "el driver del RGB no estaba instalado"
    fi
    "$PAQ/preparar-sistema.sh" --revertir || FALLO=1
    echo
    info "Las dependencias (python, gtk4, dkms o gcc, headers...) se quedan: puede"
    info "que otras cosas las usen.  Quitalas con tu gestor de paquetes si quieres."
    exit "$FALLO"
fi

plan
if (( ! SIN_PREGUNTAR )); then
    if [[ ! -t 0 ]]; then
        mal "sin terminal no se puede pedir confirmacion: lanzalo con --si"
        exit 1
    fi
    echo
    read -r -p "  ¿Seguir? [s/N] " r
    [[ "$r" == [sS]* ]] || { echo "  Cancelado; no se ha tocado nada."; exit 1; }
fi

titulo "1. Dependencias"
instalar_paquetes || exit 1
ok "dependencias instaladas"

titulo "2. Hardware  (packaging/preparar-sistema.sh)"
"$PAQ/preparar-sistema.sh" || { mal "preparar-sistema.sh ha fallado: se para aqui"; exit 1; }

RGB_OK=1
if (( CON_RGB )); then
    titulo "3. Driver del teclado RGB  (packaging/instalar-rgb.sh)"
    # Si falla no se para: el script se deshace solo y deja acer_wmi con los
    # perfiles, y la aplicacion funciona sin RGB.
    if ! "$PAQ/instalar-rgb.sh"; then
        RGB_OK=0
        avi "el driver del RGB no se ha instalado; se sigue con la aplicacion sin RGB"
    fi
fi

titulo "4. Aplicacion  (packaging/install.sh)"
ARGS=()
(( CON_EXTENSION )) || ARGS+=(--sin-extension)
"$PAQ/install.sh" "${ARGS[@]}" || { mal "install.sh ha fallado"; exit 1; }

titulo "Resumen"
ok "Nitro Gekko instalado.  Abrelo desde el menu, con 'nitro-gekko' o con el"
info "boton del logo de la marca."
(( CON_RGB && ! RGB_OK )) && avi "sin teclado RGB: mira los mensajes del paso 3"
if (( CON_EXTENSION )); then
    info "Para la extension:  gnome-extensions enable nitro-gekko@thegekko.dev"
    info "y cierra y abre sesion (en Wayland no vale Alt+F2 r)."
fi
info "Reinicia una vez para comprobar que todo arranca solo, y despues:"
info "    ./packaging/preparar-sistema.sh --revisar"
exit 0
