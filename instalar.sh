#!/usr/bin/env bash
#
# Instalacion facil de Nitro Gekko, en Arch, en Solus o en Ubuntu.
#
# Hace, en este orden y parando si algo sale mal, lo mismo que los pasos
# manuales del README:
#
#   1. instala las dependencias con pacman, eopkg o apt;
#   2. sudo ./packaging/preparar-sistema.sh   el hardware (predator_v4, PL1,
#                                             atajo del boton de la marca);
#   3. sudo ./packaging/instalar-rgb.sh       el driver del teclado RGB
#                                             (DKMS en Arch; en Solus, sin
#                                             DKMS y con red de seguridad; en
#                                             Ubuntu, DKMS con red de
#                                             seguridad y Secure Boot);
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
# Solo Arch, Solus y Ubuntu: son las distribuciones que mantiene el proyecto.
# En cualquier otra se planta y remite a los pasos manuales del README.
#
# Variables para PROBARLO sin tener la otra distribucion delante (solo con
# --revisar):
#   OS_RELEASE   fichero os-release.  Por omision /etc/os-release.
#
# Codigos de salida: 0 bien, 1 abortado o fallido, 2 opcion desconocida.  En
# Ubuntu con Secure Boot puede terminar bien pero con un reinicio pendiente
# para enrolar la clave del driver del RGB: lo dice el resumen.
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
    *" solus "*)  DISTRO=solus ;;
    *" arch "*)   DISTRO=arch ;;
    *" ubuntu "*) DISTRO=ubuntu ;;
    *)            DISTRO=otra ;;
esac
NOMBRE_DISTRO="$(sed -n 's/^PRETTY_NAME=//p' "$OSR" 2>/dev/null | tr -d '"')"
KVER="$(uname -r)"

# Paquetes de cada distribucion.  Los nombres estan sacados de la propia
# distribucion, no de memoria: en Solus con 'eopkg search-file' sobre cada
# fichero que usa la aplicacion (2026-09-25); en Arch, los 'depends' del
# PKGBUILD de packaging/aur/; en Ubuntu 26.04, con 'dpkg -S' sobre los mismos
# ficheros (2026-10-17).
#
#   Arch    python python-gobject gtk4 libadwaita polkit power-profiles-daemon
#           libxml2 (xmllint, con el que install.sh valida la politica polkit)
#   Solus   python3 python-gobject libgtk-4 libadwaita polkit
#           power-profiles-daemon libxml2
#   Ubuntu  python3 python3-gi python3-gi-cairo gir1.2-gtk-4.0 gir1.2-adw-1
#           polkitd pkexec power-profiles-daemon libxml2-utils
#           gtk-update-icon-cache.  Los gir1.2-* son los que dejan importar
#           Gtk 4 y Adw desde Python, y desde polkit 121 pkexec va en un
#           paquete aparte.  python3-gi-cairo NO es opcional: sin el, cada
#           dibujo con cairo (las graficas de RPM, las muestras de color)
#           falla con «Couldn't find foreign struct converter for
#           'cairo.Context'» y la ventana sale vacia.  En Arch y Solus va
#           dentro de python-gobject; en Ubuntu, aparte (visto el 2026-10-17
#           en la primera instalacion real).
#
# Para el RGB:
#   Arch    dkms y los headers del kernel CON EL QUE ARRANCAS: se pregunta a
#           pacman a que paquete pertenece /usr/lib/modules/<kernel>/vmlinuz
#           (linux-zen -> linux-zen-headers).  Los de otro kernel no sirven.
#   Solus   gcc make binutils, cpio y zstd (para mirar el initramfs) y
#           linux-current-headers o linux-lts-headers segun el kernel.  En
#           una instalacion recien hecha de Solus 4.9 no hay ninguno.
#   Ubuntu  dkms, mokutil (Secure Boot), linux-headers-<kernel en marcha> y
#           el linux-headers-<sabor> que acompana al linux-image-<sabor>
#           instalado (generic-hwe-26.04, por ejemplo): sin el, los kernels
#           que lleguen con las actualizaciones vendran sin headers y DKMS no
#           podra compilar nada para ellos.
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
        ubuntu)
            echo python3 python3-gi python3-gi-cairo gir1.2-gtk-4.0 gir1.2-adw-1 \
                 polkitd pkexec power-profiles-daemon libxml2-utils gtk-update-icon-cache
            if (( CON_RGB )); then
                echo dkms mokutil "linux-headers-$KVER"
                headers_del_sabor
            fi ;;
    esac
}

# Ubuntu: el linux-headers-<sabor> de cada linux-image-<sabor> instalado.  Los
# linux-image con version en el nombre (linux-image-7.0.0-38-generic) son un
# kernel concreto, no un sabor, y se descartan; lo mismo los -unsigned.
headers_del_sabor() {
    command -v dpkg-query >/dev/null || return 0
    local p
    while read -r p; do
        apt-cache show "linux-headers-${p#linux-image-}" >/dev/null 2>&1 \
            && echo "linux-headers-${p#linux-image-}"
    done < <(dpkg-query -W -f='${Package} ${Status}\n' 'linux-image-*' 2>/dev/null \
             | awk '$NF == "installed" && $1 !~ /[0-9]+\.[0-9]+\.[0-9]+-/ && $1 !~ /^linux-image-(unsigned|uc)-/ {print $1}')
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
        ubuntu)
            command -v dpkg-query >/dev/null || { echo "?"; return; }
            for p in $(paquetes); do
                grep -q '^install ok installed' < <(dpkg-query -W -f='${Status}' "$p" 2>/dev/null) || echo "$p"
            done ;;
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
        ubuntu)
            # En apt, al reves que en Arch, refrescar las listas sin actualizar
            # el sistema es lo normal y no deja nada a medias.  Sin ello, unas
            # listas viejas piden versiones que el espejo ya ha borrado (404).
            apt-get update || avi "apt-get update ha fallado; se intenta con las listas que hay"
            # Sin terminal (con --si desde pkexec) debconf no tiene donde
            # preguntar: se le dice que no lo intente.
            if (( SIN_PREGUNTAR )) && [[ ! -t 0 ]]; then
                export DEBIAN_FRONTEND=noninteractive
            fi
            # shellcheck disable=SC2086
            apt-get install $( (( SIN_PREGUNTAR )) && echo -y ) $lista || {
                mal "apt ha fallado"
                info "Actualiza el sistema y vuelve a probar:"
                info "    sudo apt update && sudo apt full-upgrade"
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
        case "$DISTRO" in
            solus)
                info "   Solus: sin DKMS; se recompila al arrancar con un kernel nuevo y, si"
                info "   no puede, entra acer_wmi con perfiles (red de seguridad)" ;;
            ubuntu)
                info "   Ubuntu: por DKMS, y si linuwu_sense no carga entra acer_wmi con"
                info "   perfiles (red de seguridad)"
                if grep -q 'SecureBoot enabled' < <(mokutil --sb-state 2>/dev/null); then
                    info "   Secure Boot ACTIVADO: hay que enrolar la clave con la que DKMS"
                    info "   firma el modulo.  Te pedira una contrasena de un solo uso y un"
                    info "   reinicio; hasta entonces, perfiles y RPM si, RGB no"
                fi ;;
            *)
                info "   Arch: por DKMS.  Si un kernel nuevo no lo compila, arrancas sin"
                info "   perfiles ni RPM hasta arreglarlo (README, «El riesgo real de este paso»)" ;;
        esac
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
    mal "${NOMBRE_DISTRO:-esta distribucion} no esta soportada: solo Arch, Solus y Ubuntu."
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
    # El fuente en /usr/src cuenta: es lo que queda de una instalacion que se
    # quedo a medias, y DKMS lo seguiria compilando en cada kernel.
    if [[ -e /etc/modprobe.d/nitro-gekko-rgb.conf ]] || grep -q '^linuwu_sense ' /proc/modules \
       || compgen -G '/usr/src/linuwu-sense-*' >/dev/null; then
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
RGB_REINICIO=0
if (( CON_RGB )); then
    titulo "3. Driver del teclado RGB  (packaging/instalar-rgb.sh)"
    # Si falla no se para: el script se deshace solo y deja acer_wmi con los
    # perfiles, y la aplicacion funciona sin RGB.  El 3 no es un fallo: en
    # Ubuntu con Secure Boot, instalado y a falta de enrolar la clave.
    "$PAQ/instalar-rgb.sh"
    case $? in
        0) ;;
        3) RGB_REINICIO=1 ;;
        *) RGB_OK=0
           avi "el driver del RGB no se ha instalado; se sigue con la aplicacion sin RGB" ;;
    esac
fi

titulo "4. Aplicacion  (packaging/install.sh)"
ARGS=()
(( CON_EXTENSION )) || ARGS+=(--sin-extension)
"$PAQ/install.sh" "${ARGS[@]}" || { mal "install.sh ha fallado"; exit 1; }

titulo "Resumen"
ok "Nitro Gekko instalado.  Abrelo desde el menu, con 'nitro-gekko' o con el"
info "boton del logo de la marca."
(( CON_RGB && ! RGB_OK )) && avi "sin teclado RGB: mira los mensajes del paso 3"
if (( RGB_REINICIO )); then
    avi "el teclado RGB llega al REINICIAR y enrolar la clave en la pantalla azul"
    info "de MOK Manager: Enroll MOK -> Continue -> Yes -> contrasena -> Reboot."
    info "Despues, para comprobarlo:  sudo ./packaging/instalar-rgb.sh"
fi
if (( CON_EXTENSION )); then
    info "Para la extension:  gnome-extensions enable nitro-gekko@thegekko.dev"
    info "y cierra y abre sesion (en Wayland no vale Alt+F2 r)."
fi
info "Reinicia una vez para comprobar que todo arranca solo, y despues:"
info "    ./packaging/preparar-sistema.sh --revisar"
exit 0
