#!/usr/bin/env bash
#
# Driver del teclado RGB (linuwu_sense) en Ubuntu: DKMS, red de seguridad y
# Secure Boot.
#
# No hace falta llamarlo por su nombre: packaging/instalar-rgb.sh detecta
# Ubuntu y le pasa el control con los mismos argumentos.
#
#   sudo ./packaging/instalar-rgb.sh              instala
#   sudo ./packaging/instalar-rgb.sh --revertir   desinstala y devuelve acer_wmi
#        ./packaging/instalar-rgb.sh --help       esta ayuda (no pide root)
#
# POR QUE NO VALE TAL CUAL EL DE ARCH
# -----------------------------------
# DKMS si hay, y recompila el modulo en cada kernel nuevo desde
# /etc/kernel/postinst.d.  Lo que cambia es lo de alrededor:
#
#  - SECURE BOOT.  Viene activado de fabrica, y con el el kernel solo carga
#    modulos firmados con una clave en la que confia.  DKMS firma linuwu_sense
#    con la clave MOK de Ubuntu (/var/lib/shim-signed/mok/, que este script
#    crea si no existe), pero esa clave hay que ENROLARLA en el firmware:
#    'mokutil --import' ahora y, al reiniciar, «Enroll MOK» en la pantalla
#    azul de MOK Manager.  Hasta entonces el modulo no carga ("Key was
#    rejected by service").
#  - Por eso la lista negra lleva la RED DE SEGURIDAD de Solus: si
#    linuwu_sense no carga -clave sin enrolar, o un kernel nuevo que rompe la
#    compilacion-, entra acer_wmi con predator_v4=1, con perfiles y RPM.  Lo
#    peor que pasa es arrancar sin RGB.
#  - Ni pacman ni libalpm: el aviso de kernel va en /etc/kernel/postinst.d y
#    /etc/kernel/header_postinst.d, y nunca hace fallar a apt.
#  - El initramfs lo hace dracut (Ubuntu 25.10 en adelante).  Si acer_wmi
#    viajara dentro, se cargaria antes de leer la lista negra; se mira y, si
#    hace falta, se regenera.
#
# QUE HACE
# --------
#  1. Comprueba equipo, fuente, dkms, headers y el predator_v4=1 que usa la
#     red de seguridad.
#  2. Copia el fuente a /usr/src, crea la clave de firma si falta (antes de
#     que DKMS lo intente y se ponga a preguntar a ciegas) y lo compila e
#     instala con DKMS.
#  3. Con Secure Boot, mira si la clave con la que DKMS ha firmado esta
#     enrolada.
#  4. Lista negra con red de seguridad, carga en el arranque y aviso de kernel.
#  5. Cambia de driver en caliente y PRUEBA la red de seguridad de verdad.  Si
#     algo falla, lo deshace todo.
#  6. Si la clave no esta enrolada, la deja pedida con 'mokutil --import', que
#     te pide una contrasena de un solo uso: la que escribiras al reiniciar.
#
# Requisitos (el instalador facil, ./instalar.sh, los pone solo):
#   sudo apt install dkms mokutil linux-headers-$(uname -r)
#   y el linux-headers-<sabor> de tu kernel (linux-headers-generic-hwe-26.04,
#   por ejemplo), para que DKMS tenga headers en los kernels que vengan.
#
# Codigos de salida: 0 bien, 1 abortado o revertido, 2 opcion desconocida,
# 3 instalado pero falta reiniciar para enrolar la clave de Secure Boot.
#
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
ORIGEN="$RAIZ/rgb"
CONF_BL=/etc/modprobe.d/nitro-gekko-rgb.conf
CONF_LOAD=/etc/modules-load.d/linuwu-sense.conf
CONF_ACER=/etc/modprobe.d/acer-wmi.conf
MARCA_ACER='# puesto-por-nitro-gekko'
AVISO_KERNEL=zz-nitro-gekko-rgb
HOOKS=(/etc/kernel/postinst.d/$AVISO_KERNEL /etc/kernel/header_postinst.d/$AVISO_KERNEL)

# Nombre y version se leen de rgb/dkms.conf, que es la unica fuente, igual que
# en Solus (ver «Donde vive cada version» en el README).
NOMBRE="$(sed -n 's/^PACKAGE_NAME="\(.*\)"$/\1/p'    "$ORIGEN/dkms.conf" 2>/dev/null | head -1)"
VERSION="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$ORIGEN/dkms.conf" 2>/dev/null | head -1)"
DESTINO="/usr/src/${NOMBRE}-${VERSION}"

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
predator_v4_activo() {
    [[ "$(cat /sys/module/acer_wmi/parameters/predator_v4 2>/dev/null)" == Y ]]
}

# ---------------------------------------------------------------------------
#  Secure Boot
# ---------------------------------------------------------------------------
sb_activo() {
    if command -v mokutil >/dev/null; then
        grep -q 'SecureBoot enabled' < <(mokutil --sb-state 2>/dev/null)
        return
    fi
    # Sin mokutil, la variable EFI: 4 bytes de atributos y despues el valor.
    local v=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
    [[ -r "$v" && "$(od -An -t u1 -j4 -N1 "$v" 2>/dev/null | tr -d ' ')" == 1 ]]
}

# El certificado con el que firma DKMS.  Manda lo que diga su configuracion (la
# ultima asignacion gana, igual que cuando dkms la lee con 'source'); si no
# dice nada, los dos sitios de siempre: el de Ubuntu (shim-signed) y el de
# DKMS de upstream.
certificado_mok() {
    local f c="" c2
    for f in /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf; do
        [[ -r "$f" ]] || continue
        c2="$(sed -n "s/^[[:space:]]*mok_certificate=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*$/\1/p" "$f" | tail -1)"
        [[ -n "$c2" ]] && c="$c2"
    done
    for f in "$c" /var/lib/shim-signed/mok/MOK.der /var/lib/dkms/mok.pub; do
        [[ -n "$f" && -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

# La clave con la que DKMS firma, creada ANTES de compilar.
#
# Si /var/lib/shim-signed/mok/MOK.priv no existe, el dkms de Ubuntu la crea en
# mitad de 'dkms build' y a continuacion lanza 'update-secureboot-policy
# --enroll-key', que pregunta una contrasena por debconf.  Aqui la salida de
# dkms va a un log: la pregunta no se veria y el script se quedaria parado
# esperando una respuesta invisible.  Leido en /usr/sbin/dkms 3.2.2
# (prepare_mok).  Creandola antes, dkms la encuentra y no pregunta nada, y la
# peticion de enrolarla se hace al final, a la vista, con 'mokutil --import'.
# dkms firma siempre que el kernel tenga CONFIG_MODULE_SIG_HASH, haya o no
# Secure Boot, asi que esto va siempre.
preparar_clave_mok() {
    local priv=/var/lib/shim-signed/mok/MOK.priv cert=/var/lib/shim-signed/mok/MOK.der
    # Una clave propia en la configuracion de DKMS manda: no se toca.
    if grep -qE '^[[:space:]]*mok_signing_key=' /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf 2>/dev/null; then
        ok "DKMS firma con la clave de su configuracion (/etc/dkms/framework.conf)"
        return 0
    fi
    if [[ -f "$priv" && -f "$cert" ]]; then
        ok "clave de firma: $cert (ya existia)"
        return 0
    fi
    if ! command -v update-secureboot-policy >/dev/null; then
        mal "falta update-secureboot-policy (paquete shim-signed): DKMS no podria firmar"
        return 1
    fi
    # Lo mismo que hace dkms: un certificado sin su clave privada no sirve para
    # firmar, y update-secureboot-policy no crea nada si el certificado existe.
    [[ -f "$cert" && ! -f "$priv" ]] && rm -f "$cert"
    if SHIM_NOTRIGGER=y update-secureboot-policy --new-key >/dev/null 2>&1 \
       && [[ -f "$priv" && -f "$cert" ]]; then
        ok "clave de firma creada: $cert"
        return 0
    fi
    mal "no se pudo crear la clave de firma en /var/lib/shim-signed/mok/"
    return 1
}

# enrolada | pendiente | no
#   enrolada   el firmware ya confia en ella: el modulo carga.
#   pendiente  pedida con 'mokutil --import' pero falta reiniciar y aceptarla.
#   no         ni lo uno ni lo otro.
estado_clave() {
    local cert="$1" huella
    if grep -q 'is already enrolled' < <(mokutil --test-key "$cert" 2>/dev/null); then
        echo enrolada; return
    fi
    huella="$(openssl x509 -inform DER -in "$cert" -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//')"
    if [[ -n "$huella" ]] && grep -qiF "$huella" < <(mokutil --list-new 2>/dev/null); then
        echo pendiente; return
    fi
    echo no
}

explicar_mok_manager() {
    info "Al reiniciar aparece una pantalla azul, MOK Manager («Perform MOK"
    info "management»).  Tienes unos segundos: pulsa una tecla y despues"
    info ""
    info "    Enroll MOK  ->  Continue  ->  Yes  ->  la contrasena  ->  Reboot"
    info ""
    info "En esa pantalla el teclado es el estadounidense: si la contrasena"
    info "lleva ñ o simbolos, puede que no te deje escribirla."
    info "Si se pasa el tiempo, arranca normal SIN enrolar (con acer_wmi y sin"
    info "RGB, nada mas): vuelve a lanzar esto y reinicia otra vez."
    info ""
    info "Ya enrolada, para comprobar que todo quedo bien:"
    info "    sudo ./packaging/instalar-rgb.sh"
}

# ---------------------------------------------------------------------------
#  Initramfs
#
#  Si acer_wmi va dentro, en el arranque se carga con la configuracion de
#  modprobe.d que tenia el initramfs al generarse: sin la lista negra nueva (o
#  sin quitar la vieja, al revertir).  Se mira cada initramfs y se regenera
#  solo el que lo lleve.  En Ubuntu 26.04 lo hace dracut; con initramfs-tools
#  (una actualizacion desde una version antigua) la orden de listar es otra.
# ---------------------------------------------------------------------------
initramfs_al_dia() {
    local listar img k
    if command -v lsinitrd >/dev/null; then listar=lsinitrd
    elif command -v lsinitramfs >/dev/null; then listar=lsinitramfs
    else
        avi "no hay lsinitrd ni lsinitramfs: no se puede mirar si acer_wmi va en el initramfs"
        return 0
    fi
    for img in /boot/initrd.img-*; do
        [[ -f "$img" ]] || continue
        k="${img#/boot/initrd.img-}"
        [[ -d "/usr/lib/modules/$k/kernel" ]] || continue
        # Sustitucion de proceso y no tuberia (regla 20 del README).
        if grep -q 'acer-wmi\.ko' < <("$listar" "$img" 2>/dev/null); then
            info "acer_wmi va dentro del initramfs de $k: regenerandolo..."
            if update-initramfs -u -k "$k" >/dev/null 2>&1; then
                ok "initramfs de $k regenerado con la configuracion nueva"
            else
                avi "no se pudo regenerar el initramfs de $k:  sudo update-initramfs -u -k $k"
            fi
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
#  Headers para los kernels que vengan
#
#  En Ubuntu los kernels nuevos llegan por un metapaquete linux-image-<sabor>
#  (linux-image-generic-hwe-26.04, por ejemplo), y sus headers por
#  linux-headers-<sabor>.  Sin el segundo, el kernel nuevo llega sin headers y
#  DKMS no puede compilar nada: arrancarias con acer_wmi y sin RGB.
# ---------------------------------------------------------------------------
headers_que_faltan() {
    local p sabor
    while read -r p; do
        sabor="${p#linux-image-}"
        apt-cache show "linux-headers-$sabor" >/dev/null 2>&1 || continue
        grep -q '^install ok installed' < <(dpkg-query -W -f='${Status}' "linux-headers-$sabor" 2>/dev/null) \
            || echo "linux-headers-$sabor"
    done < <(dpkg-query -W -f='${Package} ${Status}\n' 'linux-image-*' 2>/dev/null \
             | awk '$NF == "installed" && $1 !~ /[0-9]+\.[0-9]+\.[0-9]+-/ && $1 !~ /^linux-image-(unsigned|uc)-/ {print $1}')
}

# ---------------------------------------------------------------------------
#  Restos registrados con OTRO nombre.  El porque esta en instalar-rgb.sh: hasta
#  la version 1.0.0-an17.1 la version llevaba guion.  En Ubuntu no hay hook de
#  pacman que los cree, pero un repositorio copiado de un Arch si puede
#  haberlos dejado, y se barre igual.
# ---------------------------------------------------------------------------
limpiar_restos_de_otro_nombre() {
    local nv d
    command -v dkms >/dev/null || return 0
    while read -r nv; do
        [[ -z "$nv" || "$nv" == "$NOMBRE/$VERSION" ]] && continue
        if dkms remove "$nv" --all </dev/null >/dev/null 2>&1; then
            avi "quitado un registro DKMS antiguo con otro nombre: $nv"
        else
            mal "no se pudo quitar el registro DKMS antiguo: $nv"
            info "Quitalo a mano:  sudo dkms remove $nv --all"
        fi
    done < <(dkms status 2>/dev/null | sed 's/[,:].*//' | grep '^linuwu' | sort -u)
    for d in /usr/src/linuwu-sense-*; do
        [[ -d "$d" && "$d" != "$DESTINO" ]] || continue
        rm -rf "$d" && avi "borrado un fuente antiguo: $d"
    done
}

# ---------------------------------------------------------------------------
#  Revertir: volver a acer_wmi
# ---------------------------------------------------------------------------
revertir() {
    titulo "Revirtiendo: volver a acer_wmi"
    local f resto fallos=0

    # EL CAMBIO DE DRIVER VA ANTES DE BORRAR NADA (lo mismo que en Solus):
    # con el modulo ya fuera del indice, 'modprobe -r' no lo encuentra y
    # linuwu_sense se queda en memoria dando los mismos perfiles, con lo que la
    # comprobacion final se lo creeria.  rmmod va de respaldo: descarga por
    # nombre, sin mirar el indice.
    if cargado linuwu_sense; then
        if modprobe -r linuwu_sense 2>/dev/null || rmmod linuwu_sense 2>/dev/null; then
            ok "linuwu_sense descargado"
        else
            mal "no se pudo descargar linuwu_sense (en uso?): se ira al reiniciar"
            fallos=1
        fi
    fi
    modprobe sparse_keymap 2>/dev/null
    cargado acer_wmi || modprobe acer_wmi predator_v4=1 2>/dev/null

    for f in "$CONF_BL" "$CONF_LOAD" "${HOOKS[@]}"; do
        if [[ -e "$f" ]]; then
            rm -f "$f" && ok "borrado $f" || { mal "NO se pudo borrar $f"; fallos=1; }
        else
            info "$f no estaba"
        fi
    done

    if command -v dkms >/dev/null && grep -q . < <(dkms status "$NOMBRE/$VERSION" 2>/dev/null); then
        if dkms remove "$NOMBRE/$VERSION" --all >/dev/null 2>&1; then
            ok "modulo quitado de DKMS"
        else
            mal "'dkms remove' fallo; mira:  dkms status $NOMBRE"
            fallos=1
        fi
    else
        info "no estaba registrado en DKMS"
    fi
    if [[ -d "$DESTINO" ]]; then
        rm -rf "$DESTINO" && ok "fuente eliminado de $DESTINO" || { mal "NO se pudo borrar $DESTINO"; fallos=1; }
    fi
    limpiar_restos_de_otro_nombre

    resto="$(find /usr/lib/modules -name 'linuwu_sense.ko*' 2>/dev/null)"
    if [[ -n "$resto" ]]; then
        mal "queda el modulo instalado en /usr/lib/modules:"
        printf '%s\n' "$resto" | sed 's/^/        /'
        info "Borralo a mano y vuelve a ejecutar:  sudo depmod -a"
        fallos=1
    fi
    depmod -a

    # Sin predator_v4=1 persistente el proximo arranque seria sin perfiles: lo
    # mismo que en Arch y en Solus, y con la misma marca, para que
    # 'preparar-sistema.sh --revertir' sepa que lo puso este proyecto.
    if [[ -f "$CONF_ACER" ]] && grep -q 'predator_v4=1' "$CONF_ACER"; then
        ok "$CONF_ACER ya fija predator_v4=1 (los perfiles sobreviven al reinicio)"
    else
        [[ -f "$CONF_ACER" ]] && printf '\n' >> "$CONF_ACER"
        if {
            printf '%s\n' "$MARCA_ACER"
            printf '%s\n' '# Escrito por packaging/instalar-rgb.sh --revertir (Ubuntu).  Sin'
            printf '%s\n' '# predator_v4=1 el acer-wmi de mainline no crea platform_profile ni el'
            printf '%s\n' '# hwmon de los ventiladores en este modelo.'
            printf '%s\n' '# Para quitarlo:  sudo ./packaging/preparar-sistema.sh --revertir'
            printf '%s\n' 'options acer_wmi predator_v4=1'
        } >> "$CONF_ACER"; then
            ok "escrito $CONF_ACER (predator_v4=1 persistente)"
        else
            mal "no se pudo escribir $CONF_ACER"
            info "    echo 'options acer_wmi predator_v4=1' | sudo tee $CONF_ACER"
            fallos=1
        fi
    fi
    initramfs_al_dia

    # Se mira QUE driver hay, no solo que haya perfiles: linuwu_sense tambien
    # los da.
    if cargado acer_wmi && ! cargado linuwu_sense && esperar_perfiles; then
        ok "acer_wmi al mando: platform_profile = $(cat /sys/firmware/acpi/platform_profile)"
    elif cargado linuwu_sense; then
        mal "linuwu_sense sigue cargado en memoria: reinicia para volver a acer_wmi"
        fallos=1
    else
        mal "no han vuelto los perfiles termicos: reinicia"
        fallos=1
    fi

    local cert
    if command -v mokutil >/dev/null && cert="$(certificado_mok)"; then
        info "La clave MOK de DKMS ($cert) se queda: no estorba, y la"
        info "usaria cualquier otro modulo DKMS.  Para quitarla del firmware:"
        info "    sudo mokutil --delete $cert   (y reiniciar para confirmarlo)"
    fi
    info "dkms, mokutil y los headers siguen instalados; quitalos con apt si"
    info "no los usas para otra cosa."
    return "$fallos"
}

if [[ "$ACCION" == "revertir" ]]; then
    if revertir; then
        echo
        echo "  ${V}Revertido: acer_wmi vuelve a estar al mando.${F}"
        exit 0
    fi
    echo
    echo "  ${R}La reversion ha quedado incompleta.${F} Repasa los mensajes de arriba."
    exit 1
fi

# Un fallo a partir de que el driver esta puesto: se deshace todo y se sale.
abortar() {
    mal "$*"
    info "Deshaciendo todo para volver a acer_wmi:"
    revertir
    exit 1
}

# Pide la clave con 'mokutil --import', que pregunta la contrasena por la
# terminal.  Sin terminal (lanzado con --si desde pkexec) no puede, y se dice
# la orden en vez de fingir que se ha hecho.
pedir_clave() {
    info "mokutil te pide ahora una contrasena, dos veces.  Es de un solo uso:"
    info "solo sirve para confirmar la clave en el siguiente arranque."
    echo
    if [[ -t 0 ]] && mokutil --import "$CERT"; then
        ok "clave pedida"
    else
        avi "no se ha podido pedir desde aqui (sin terminal?).  Hazlo tu:"
        info "    sudo mokutil --import $CERT"
    fi
    echo
}

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
    info "Si no se crean los perfiles, el paso 6 lo deshace solo."
fi

FUENTE_C="$ORIGEN/src/linuwu_sense.c"
if [[ -z "$NOMBRE" || -z "$VERSION" || ! -f "$FUENTE_C" || ! -f "$ORIGEN/Makefile" ]]; then
    mal "fuente incompleto en $ORIGEN (falta src/, Makefile o dkms.conf)"
    info "Clona el repositorio completo: rgb/ va con el."
    exit 1
fi
ok "fuente: $ORIGEN  (${NOMBRE} ${VERSION}, leido de rgb/dkms.conf)"
grep -q "Nitro AN17-51" "$FUENTE_C" && ok "el fuente lleva el parche del AN17-51" \
    || { mal "el fuente NO lleva el parche del AN17-51"; exit 1; }
grep -q "four_zoned_kb" "$FUENTE_C" && ok "el fuente registra el grupo four_zoned_kb (RGB)" \
    || { mal "el fuente no crea four_zoned_kb: no habria RGB"; exit 1; }

command -v dkms >/dev/null && ok "dkms $(dkms --version 2>/dev/null | head -1)" \
    || { mal "falta dkms:  sudo apt install dkms"; exit 1; }

# Para que kernel se compila: el razonamiento entero esta en instalar-rgb.sh.
# En corto: el kernel en marcha, salvo que ya no tenga arbol de construccion
# (actualizado y sin reiniciar); entonces el mas nuevo que lo tenga, que es el
# que vas a arrancar.
KVER="$(uname -r)"
KVER_OBJETIVO="$KVER"
EN_CALIENTE=1
if [[ ! -d "/usr/lib/modules/$KVER/build/include" ]]; then
    EN_CALIENTE=0
    KVER_OBJETIVO="$(
        for d in /usr/lib/modules/*/build/include; do
            [[ -d "$d" ]] || continue
            d="${d%/build/include}"; echo "${d##*/}"
        done | sort -V | tail -1
    )"
fi
if [[ -z "$KVER_OBJETIVO" ]]; then
    mal "ningun kernel de /usr/lib/modules tiene headers"
    info "Sin ellos, DKMS no puede compilar nada:"
    info "    sudo apt install linux-headers-$KVER"
    exit 1
fi
if (( EN_CALIENTE )); then
    ok "headers del kernel en marcha: linux-headers-$KVER_OBJETIVO"
else
    avi "el kernel en marcha ($KVER) no tiene headers."
    info "Pasa cuando has actualizado el kernel y todavia no has reiniciado."
    info "Se compila para $KVER_OBJETIVO, que es el que vas a arrancar."
fi
FALTAN_META="$(headers_que_faltan | tr '\n' ' ')"
if [[ -n "${FALTAN_META// /}" ]]; then
    avi "los kernels que vengan llegaran SIN headers, y sin ellos sin RGB:"
    info "    sudo apt install ${FALTAN_META% }"
else
    ok "los headers siguen al kernel (los kernels nuevos traeran los suyos)"
fi

if [[ -f "$CONF_ACER" ]] && grep -q 'predator_v4=1' "$CONF_ACER"; then
    ok "$CONF_ACER con predator_v4=1 (es lo que usa la red de seguridad)"
else
    mal "falta predator_v4=1 en $CONF_ACER"
    info "Sin el, la red de seguridad cargaria un acer_wmi sin perfiles."
    info "Ejecuta antes:  sudo ./packaging/preparar-sistema.sh"
    exit 1
fi

SB=0
if sb_activo; then
    SB=1
    ok "Secure Boot activado: el modulo tiene que ir firmado con una clave enrolada"
    if ! command -v mokutil >/dev/null; then
        mal "falta mokutil, y sin el no se puede enrolar la clave:  sudo apt install mokutil"
        exit 1
    fi
else
    ok "Secure Boot desactivado: el modulo carga sin firma"
fi

# ---------------------------------------------------------------------------
titulo "2. Instalando el fuente en /usr/src"
# ---------------------------------------------------------------------------
dkms remove "$NOMBRE/$VERSION" --all >/dev/null 2>&1 || true
limpiar_restos_de_otro_nombre
rm -rf "$DESTINO"
if ! { install -d "$DESTINO" && cp -r "$ORIGEN/src" "$ORIGEN/Makefile" "$ORIGEN/dkms.conf" "$DESTINO/"; }; then
    mal "no se pudo copiar el fuente a $DESTINO (disco lleno? /usr de solo lectura?)"
    rm -rf "$DESTINO"
    exit 1
fi
# El repositorio puede venir de un clon con umask laxo y esto es codigo de
# sistema.  Y fuera la basura de una compilacion a mano (make -C rgb).
find "$DESTINO" \( -name '*.o' -o -name '*.ko' -o -name '*.mod*' -o -name '.*.cmd' \
                   -o -name 'Module.symvers' -o -name 'modules.order' \) -delete 2>/dev/null
chown -R root:root "$DESTINO"
find "$DESTINO" -type d -exec chmod 755 {} +
find "$DESTINO" -type f -exec chmod 644 {} +
ok "$DESTINO"

# ---------------------------------------------------------------------------
titulo "3. Compilando con DKMS para $KVER_OBJETIVO"
# ---------------------------------------------------------------------------
LOG="$(mktemp /var/log/dkms-nitro-gekko.XXXXXX 2>/dev/null || mktemp)"
chmod 600 "$LOG"
info "log de la compilacion: $LOG"
# Hasta aqui no se ha tocado ningun modulo: si DKMS falla, basta con quitar lo
# que se ha registrado.
fallo_dkms() {
    mal "$1 fallo. Ultimas lineas:"
    tail -15 "$LOG" | sed 's/^/      /'
    info "Log completo en: $LOG"
    dkms remove "$NOMBRE/$VERSION" --all >/dev/null 2>&1
    rm -rf "$DESTINO"
    info "No se ha tocado ningun modulo: acer_wmi sigue al mando."
    exit 1
}
if ! preparar_clave_mok; then
    rm -rf "$DESTINO"
    info "No se ha tocado ningun modulo: acer_wmi sigue al mando."
    exit 1
fi
# Con </dev/null: si algo dentro de dkms se pusiera a preguntar, que falle en
# vez de quedarse esperando una respuesta que va a un log.
dkms add "$NOMBRE/$VERSION" </dev/null >>"$LOG" 2>&1 && ok "anadido a DKMS" || fallo_dkms "dkms add"
dkms build "$NOMBRE/$VERSION" -k "$KVER_OBJETIVO" </dev/null >>"$LOG" 2>&1 && ok "compilado" || fallo_dkms "dkms build"
dkms install "$NOMBRE/$VERSION" -k "$KVER_OBJETIVO" </dev/null >>"$LOG" 2>&1 && ok "instalado" || fallo_dkms "dkms install"
dkms status "$NOMBRE" | sed 's/^/        /'
KO="$(modinfo -k "$KVER_OBJETIVO" -n linuwu_sense 2>/dev/null)"
[[ -f "$KO" ]] || fallo_dkms "encontrar el .ko instalado (modinfo -n linuwu_sense)"
ok "$KO"

# ---------------------------------------------------------------------------
titulo "4. Secure Boot"
# ---------------------------------------------------------------------------
CLAVE="ninguna"      # enrolada | pendiente | no | ninguna (sin Secure Boot)
CERT=""
if (( SB )); then
    FIRMA="$(modinfo -F signer "$KO" 2>/dev/null)"
    if [[ -z "$FIRMA" ]]; then
        mal "DKMS NO ha firmado el modulo: con Secure Boot el kernel no lo cargaria nunca"
        info "Mira mok_signing_key y mok_certificate en /etc/dkms/framework.conf"
        info "y el log: $LOG"
        fallo_dkms "firmar el modulo"
    fi
    if ! CERT="$(certificado_mok)"; then
        mal "el modulo va firmado ('$FIRMA') pero no encuentro el certificado"
        info "Lo busque en /etc/dkms/framework.conf, /var/lib/shim-signed/mok/MOK.der"
        info "y /var/lib/dkms/mok.pub."
        fallo_dkms "encontrar la clave MOK"
    fi
    ok "firmado por «$FIRMA» con $CERT"
    # Se comprueba que el modulo lo firma ESE certificado y no otro: modinfo da
    # el numero de serie del certificado firmante.
    SERIE_KO="$(modinfo -F sig_key "$KO" 2>/dev/null | tr -d ':' | tr 'a-f' 'A-F')"
    SERIE_CERT="$(openssl x509 -inform DER -in "$CERT" -noout -serial 2>/dev/null | sed 's/.*=//' | tr 'a-f' 'A-F')"
    if [[ -n "$SERIE_KO" && "$SERIE_KO" == "$SERIE_CERT" ]]; then
        ok "el certificado es el que ha firmado el modulo"
    else
        avi "no se puede confirmar que $CERT sea el que firmo el modulo"
        info "(serie del modulo: ${SERIE_KO:-?}; del certificado: ${SERIE_CERT:-?})"
    fi
    CLAVE="$(estado_clave "$CERT")"
    case "$CLAVE" in
        enrolada)  ok "la clave esta enrolada en el firmware: el modulo carga" ;;
        pendiente) avi "la clave esta pedida pero falta reiniciar para aceptarla" ;;
        no)        avi "la clave NO esta enrolada: hasta enrolarla, el modulo no carga"
                   info "Se pide al final, despues de probar que todo lo demas va." ;;
    esac
else
    info "sin Secure Boot no hay nada que enrolar"
fi

# ---------------------------------------------------------------------------
titulo "5. Configuracion de arranque"
# ---------------------------------------------------------------------------
install -Dm644 "$AQUI/nitro-gekko-rgb.conf" "$CONF_BL" && ok "$CONF_BL (lista negra + red de seguridad)" \
    || abortar "no se pudo escribir $CONF_BL"
install -d "$(dirname "$CONF_LOAD")" && echo linuwu_sense > "$CONF_LOAD" && ok "$CONF_LOAD (carga en el arranque)"
for h in "${HOOKS[@]}"; do
    install -Dm755 "$AQUI/$AVISO_KERNEL" "$h" && ok "$h" \
        || avi "no se pudo instalar $h: un kernel sin el modulo no te avisara"
done
# 'modprobe -c' (la configuracion efectiva) y no 'modprobe -n -v', que no
# ensena nada si linuwu_sense ya esta cargado (lo midio el de Solus).
if grep -q '^install linuwu_sense ' < <(modprobe -c 2>/dev/null); then
    ok "modprobe ve la regla 'install' de linuwu_sense"
else
    abortar "modprobe no ve la regla 'install' de $CONF_BL: sin ella no hay red de seguridad"
fi
initramfs_al_dia

# ---------------------------------------------------------------------------
#  Si se ha compilado para OTRO kernel, aqui se termina: un .ko de un kernel
#  que no esta corriendo no se puede cargar ni probar.
# ---------------------------------------------------------------------------
if (( ! EN_CALIENTE )); then
    titulo "Resumen"
    echo "  ${A}Instalado para $KVER_OBJETIVO, que no es el kernel en marcha.${F}"
    info "Al reiniciar con el arrancaras con linuwu_sense; si no cargara, con"
    info "acer_wmi y los perfiles (la red de seguridad)."
    if [[ "$CLAVE" == no ]]; then
        info "Antes, Secure Boot necesita que enroles la clave de DKMS."
        pedir_clave
        explicar_mok_manager
        exit 3
    fi
    [[ "$CLAVE" == pendiente ]] && { explicar_mok_manager; exit 3; }
    info "Despues, para verificarlo:  sudo ./packaging/instalar-rgb.sh"
    exit 0
fi

# ---------------------------------------------------------------------------
titulo "6. Cambiando de driver ahora"
# ---------------------------------------------------------------------------
PERFIL="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo balanced)"
RED=0
if [[ "$CLAVE" == no || "$CLAVE" == pendiente ]]; then
    # Con la clave sin enrolar el kernel rechaza el modulo: es exactamente el
    # caso para el que esta la red de seguridad, asi que se prueba con el y no
    # con una simulacion.
    info "Con la clave sin enrolar linuwu_sense no puede cargar todavia, que es"
    info "justo el caso de la red de seguridad: se prueba con el."
    cargado acer_wmi && modprobe -r acer_wmi && ok "acer_wmi descargado"
    modprobe linuwu_sense 2>/dev/null
    if cargado linuwu_sense; then
        # No deberia pasar con Secure Boot y la clave fuera, pero si pasa,
        # mejor: el driver ya esta.
        avi "linuwu_sense ha cargado aun sin la clave enrolada"
        esperar_perfiles || abortar "linuwu_sense no da perfiles en este equipo"
        CLAVE=enrolada
    elif cargado acer_wmi && esperar_perfiles && predator_v4_activo; then
        ok "el kernel rechaza linuwu_sense y entra acer_wmi con predator_v4=Y"
        RED=1
    else
        abortar "la red de seguridad NO ha funcionado: no se deja instalado"
    fi
else
    cargado acer_wmi && modprobe -r acer_wmi && ok "acer_wmi descargado"
    # Por la ruta normal, con la regla 'install', igual que en el arranque.
    modprobe linuwu_sense
    if cargado linuwu_sense && esperar_perfiles; then
        ok "linuwu_sense cargado"
    else
        abortar "linuwu_sense no da perfiles en este equipo"
    fi
fi

if [[ "$CLAVE" == enrolada || "$CLAVE" == ninguna ]]; then
    titulo "7. Probando la red de seguridad (simula un kernel sin el modulo)"
    modprobe -r linuwu_sense
    if mv "$KO" "$KO.prueba" && depmod -a "$KVER"; then
        modprobe linuwu_sense 2>/dev/null   # la regla 'install' tiene que caer en acer_wmi
        if cargado acer_wmi && ! cargado linuwu_sense && esperar_perfiles && predator_v4_activo; then
            ok "sin el modulo entra acer_wmi con predator_v4=Y: $(cat /sys/firmware/acpi/platform_profile_choices)"
            RED=1
        else
            mal "la red de seguridad NO ha funcionado"
        fi
        mv "$KO.prueba" "$KO" && depmod -a "$KVER"
    else
        mal "no se pudo apartar $KO para la prueba"
    fi
    cargado acer_wmi && modprobe -r acer_wmi
    modprobe linuwu_sense 2>/dev/null
    if ! cargado linuwu_sense || ! esperar_perfiles; then
        abortar "no se ha podido volver a linuwu_sense"
    fi
    ok "de vuelta en linuwu_sense"
    (( RED )) || abortar "sin red de seguridad esto no se deja instalado"
fi

# ---------------------------------------------------------------------------
titulo "Verificacion"
# ---------------------------------------------------------------------------
echo "$PERFIL" > /sys/firmware/acpi/platform_profile 2>/dev/null
ok "platform_profile: $(cat /sys/firmware/acpi/platform_profile)  ($(cat /sys/firmware/acpi/platform_profile_choices))"
HW="$(hwmon_acer)" && ok "tacometros: fan1=$(cat "$HW/fan1_input") fan2=$(cat "$HW/fan2_input") rpm"
BASE=/sys/devices/platform/acer-wmi
if cargado linuwu_sense; then
    if [[ -d "$BASE/four_zoned_kb" ]]; then
        ok "teclado RGB de 4 zonas: $(ls "$BASE/four_zoned_kb" | tr '\n' ' ')"
    else
        avi "four_zoned_kb AUSENTE: tu modelo no esta en la tabla DMI del driver"
        info "Perfiles y tacometros si funcionan; simplemente no hay RGB que dar."
    fi
    [[ -d "$BASE/nitro_sense" ]] && ok "nitro_sense: $(ls "$BASE/nitro_sense" | tr '\n' ' ')"
else
    info "driver ahora: acer_wmi (perfiles y RPM).  El RGB llega al enrolar la clave."
fi

# power-profiles-daemon se queda con el driver 'placeholder' si
# platform_profile aparece despues de que arranque (medido en Solus): tras
# cambiar de driver en caliente hay que reiniciarlo.
if systemctl is-active power-profiles-daemon >/dev/null 2>&1; then
    systemctl restart power-profiles-daemon
    sleep 1
    info "power-profiles-daemon: $(powerprofilesctl list 2>/dev/null | grep -m1 PlatformDriver | xargs)"
fi

# ---------------------------------------------------------------------------
#  La clave de Secure Boot, lo ultimo: solo se pide cuando todo lo demas esta
#  probado, para no dejar una clave pedida de un driver que se ha revertido.
# ---------------------------------------------------------------------------
case "$CLAVE" in
    no)
        titulo "8. Enrolar la clave de DKMS en Secure Boot"
        pedir_clave
        explicar_mok_manager
        echo
        echo "  ${A}Instalado: falta reiniciar y enrolar la clave para tener RGB.${F}"
        echo "  Mientras tanto tienes perfiles y RPM con acer_wmi, como hasta ahora."
        exit 3 ;;
    pendiente)
        titulo "Falta reiniciar para enrolar la clave"
        explicar_mok_manager
        echo
        echo "  ${A}Instalado: falta reiniciar y enrolar la clave para tener RGB.${F}"
        exit 3 ;;
esac

echo
echo "  ${V}Driver instalado y verificado.${F}"
echo "  DKMS lo recompila en cada kernel nuevo; si un dia no puede, arrancas"
echo "  con acer_wmi y perfiles, y apt te lo dice al instalar ese kernel."
echo "  Para volver a acer_wmi:  sudo ./packaging/instalar-rgb.sh --revertir"
exit 0
