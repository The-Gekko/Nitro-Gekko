#!/usr/bin/env bash
# ============================================================================
#  Nitro Gekko - instalador
#
#  Panel de control del Acer Nitro AN17-51 para GNOME.
#
#  USO
#    sudo ./packaging/install.sh                 instala en el sistema (polkit)
#    sudo ./packaging/install.sh --con-udev      instala Y abre /sys a 'wheel'
#    sudo ./packaging/install.sh --uninstall     desinstala
#    DESTDIR=/tmp/prueba ./packaging/install.sh  instala en un arbol falso
#                                                (no toca el sistema, no pide root)
#
#  Este script instala la APLICACION (codigo, lanzador, icono, extension de
#  GNOME Shell, helper privilegiado y politica polkit).  El HARDWARE -modulo
#  acer_wmi/linuwu_sense, limite de PL1, power-profiles-daemon, atajo del
#  boton de la marca- lo prepara ./packaging/preparar-sistema.sh, que es otro
#  script y se lanza aparte.
#
#  Con DESTDIR puesto el instalador NO recarga udev, NO recarga tmpfiles, NO
#  refresca las caches del escritorio y NO toca /sys: solo construye el arbol
#  de ficheros. Es la forma de revisar que va a instalar antes de dejarle
#  tocar el equipo de verdad.
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
#  Identidad del proyecto
# ---------------------------------------------------------------------------
readonly APP_ID="org.thegekko.nitrogekko"
readonly APP_NOMBRE="Nitro Gekko"
readonly APP_BIN="nitro-gekko"

# Raiz del proyecto = el directorio padre de packaging/
RAIZ="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly RAIZ

# ---------------------------------------------------------------------------
#  Rutas de instalacion
#
#  El codigo de la aplicacion va a /usr/lib/nitro-gekko y no a /usr/share.
#  Motivo: es codigo privado del programa, no datos compartidos. Aunque sea
#  Python (independiente de arquitectura), la convencion de Arch y de la FHS
#  para "codigo que solo ejecuta este programa y nadie mas importa" es
#  /usr/lib/<programa>. En /usr/share van el .desktop, el icono y el esquema,
#  que si son datos compartidos con el escritorio.
# ---------------------------------------------------------------------------
PREFIX="${PREFIX:-/usr}"
DESTDIR="${DESTDIR:-}"

readonly DIR_APP="${PREFIX}/lib/${APP_BIN}"
readonly DIR_BIN="${PREFIX}/bin"
readonly DIR_UDEV="${PREFIX}/lib/udev/rules.d"
readonly DIR_TMPFILES="${PREFIX}/lib/tmpfiles.d"
readonly DIR_DESKTOP="${PREFIX}/share/applications"
readonly DIR_ICONOS="${PREFIX}/share/icons/hicolor"
readonly DIR_ESQUEMAS="${PREFIX}/share/glib-2.0/schemas"

readonly DIR_POLKIT="${PREFIX}/share/polkit-1/actions"
readonly DIR_SYSTEMD="${PREFIX}/lib/systemd/system"
#: Donde el helper anota lo que aplica, para reponerlo en el siguiente
#: arranque.  Va en /var y no en $PREFIX porque son datos, no programa.
readonly DIR_ESTADO="/var/lib/${APP_BIN}"

readonly FICHERO_UDEV="99-nitro-gekko.rules"
readonly FICHERO_TMPFILES="nitro-gekko.conf"
readonly FICHERO_HELPER="nitro-gekko-helper"
readonly FICHERO_RESTAURAR="nitro-gekko-restaurar"
readonly FICHERO_UNIDAD="nitro-gekko-restaurar.service"
readonly FICHERO_POLICY="org.thegekko.nitrogekko.policy"

# Modo de privilegios.  Por DEFECTO solo polkit: la aplicacion llama al helper
# por pkexec y GNOME pide la contrasena.  Con --con-udev se instalan ademas las
# reglas que abren esas rutas de /sys al grupo 'wheel', lo que evita el dialogo
# a cambio de que CUALQUIER proceso del usuario pueda escribir ahi sin
# autenticarse.  Ver la seccion 'Seguridad y permisos' del README.
CON_UDEV=0

# ---------------------------------------------------------------------------
#  Salida por pantalla
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_ROJO=$'\033[31m'; C_AMAR=$'\033[33m'; C_VERDE=$'\033[32m'
    C_AZUL=$'\033[34m'; C_NEG=$'\033[1m';   C_FIN=$'\033[0m'
else
    C_ROJO=''; C_AMAR=''; C_VERDE=''; C_AZUL=''; C_NEG=''; C_FIN=''
fi

info()  { printf '%s==>%s %s\n'      "$C_AZUL"  "$C_FIN" "$*"; }
ok()    { printf '%s  ok%s  %s\n'    "$C_VERDE" "$C_FIN" "$*"; }
aviso() { printf '%sAVISO%s %s\n'    "$C_AMAR"  "$C_FIN" "$*" >&2; }
error() { printf '%sERROR%s %s\n'    "$C_ROJO"  "$C_FIN" "$*" >&2; }
titulo(){ printf '\n%s%s%s\n'        "$C_NEG"   "$*"     "$C_FIN"; }

# Se cuentan por separado dos cosas que NO son lo mismo:
#   aviso  -> algo que la persona deberia leer (hardware distinto, falta un
#             modulo opcional).  El instalador sigue y termina bien.
#   error  -> un fichero que habia que instalar y NO se instalo (disco lleno,
#             /usr de solo lectura, sin permiso).  Eso hace que el instalador
#             termine con codigo != 0, para que un makepkg o un script que lo
#             llame se entere.
HUBO_AVISOS=0
HUBO_ERRORES=0
aviso_contado() { HUBO_AVISOS=$((HUBO_AVISOS + 1)); aviso "$@"; }
error_contado() { HUBO_ERRORES=$((HUBO_ERRORES + 1)); error "$@"; }

# ---------------------------------------------------------------------------
#  Usuario real (el instalador corre como root via sudo, pero la extension de
#  GNOME Shell va en el HOME de la persona, no en el de root)
# ---------------------------------------------------------------------------
detectar_usuario() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        USUARIO="$SUDO_USER"
    elif [[ -n "${PKEXEC_UID:-}" ]]; then
        USUARIO="$(id -nu "$PKEXEC_UID")"
    else
        USUARIO="$(id -nu)"
    fi
    HOME_USUARIO="$(getent passwd "$USUARIO" | cut -d: -f6)"
    if [[ -z "$HOME_USUARIO" ]]; then
        HOME_USUARIO="${HOME:-/root}"
    fi
    # Se deja sobrescribir desde fuera A PROPOSITO.
    #
    # Sin esto no se puede empaquetar: dentro de makepkg el HOME es el de root,
    # asi que el paquete acababa conteniendo
    # root/.local/share/gnome-shell/extensions/... (comprobado construyendo el
    # paquete).  Un PKGBUILD pasa DIR_EXTENSIONES=/usr/share/gnome-shell/
    # extensions y la extension cae donde debe.  Sin la variable, el
    # comportamiento es exactamente el de siempre.
    DIR_EXTENSIONES="${DIR_EXTENSIONES:-${HOME_USUARIO}/.local/share/gnome-shell/extensions}"
}

# ---------------------------------------------------------------------------
#  Comprobaciones del equipo. Ninguna aborta: esto avisa, no manda.
# ---------------------------------------------------------------------------
comprobar_hardware() {
    titulo "1. Hardware"

    # Variable para poder probar el aviso con un DMI falso:
    #   DIR_DMI=/ruta/falsa ./packaging/install.sh
    local dmi="${DIR_DMI:-/sys/class/dmi/id}"
    local vendor producto familia placa
    vendor="$(cat "$dmi/sys_vendor"     2>/dev/null || echo '?')"
    producto="$(cat "$dmi/product_name" 2>/dev/null || echo '?')"
    familia="$(cat "$dmi/product_family" 2>/dev/null || echo '?')"
    placa="$(cat "$dmi/board_name"      2>/dev/null || echo '?')"

    info "Fabricante : $vendor"
    info "Modelo     : $producto"
    info "Familia    : $familia"
    info "Placa      : $placa"

    if [[ "$vendor" != "Acer" ]]; then
        aviso_contado "Este equipo no es un Acer (sys_vendor = '$vendor')."
        aviso_contado "Nitro Gekko esta hecho para un Acer Nitro AN17-51. Las rutas de"
        aviso_contado "sysfs que abre pueden no existir aqui, o significar otra cosa."
        aviso_contado "Se continua igualmente, pero lee antes 'Seguridad y permisos'"
        aviso_contado "en el README."
    elif [[ "$producto" != *Nitro* && "$familia" != *Nitro* ]]; then
        aviso_contado "Es un Acer pero no parece un Nitro ('$producto' / '$familia')."
        aviso_contado "Probado unicamente en Nitro AN17-51. Se continua."
    else
        ok "Acer Nitro detectado."
        if [[ "$producto" != "Nitro AN17-51" ]]; then
            aviso_contado "El modelo probado es 'Nitro AN17-51' y este es '$producto'."
            aviso_contado "Deberia funcionar, pero los vatios y las RPM de referencia"
            aviso_contado "que muestra la aplicacion son los de ese modelo."
        fi
    fi
}

# ---------------------------------------------------------------------------
#  acer_wmi + predator_v4=1. Sin esto no hay perfiles de plataforma.
# ---------------------------------------------------------------------------
explicar_predator_v4() {
    cat <<'AYUDA'

  Como arreglarlo:

    1) Crea el fichero de opciones del modulo:

         echo 'options acer_wmi predator_v4=1' | sudo tee /etc/modprobe.d/acer-wmi.conf

    2) Recarga el modulo en caliente:

         sudo modprobe -r acer_wmi && sudo modprobe acer_wmi

       Si da "module in use", reinicia y ya esta.

    3) Comprueba que ha funcionado:

         cat /sys/module/acer_wmi/parameters/predator_v4      # debe decir Y
         cat /sys/class/platform-profile/platform-profile-0/choices

       Lo segundo debe imprimir:
         low-power quiet balanced balanced-performance performance

    4) Si acer_wmi va compilado dentro del kernel en vez de como modulo,
       el fichero de modprobe.d no sirve: hay que anadir acer_wmi.predator_v4=1
       a la linea de arranque del kernel.

    5) Si despues de todo esto platform_profile sigue sin aparecer, tu modelo
       no lo reconoce acer_wmi ni forzando el quirk.  Queda la otra via, que
       ademas es la unica con teclado RGB:

         sudo ./packaging/instalar-rgb.sh     (linuwu_sense por DKMS)

       Se deshace solo si tampoco te da los perfiles, asi que probarlo no te
       deja peor de lo que estabas.

AYUDA
}

comprobar_modulo() {
    titulo "2. Driver de la plataforma Acer"

    local hay_problema=0

    # Hay DOS drivers validos y son mutuamente excluyentes:
    #   acer_wmi predator_v4=1  -> perfiles termicos y tacometros
    #   linuwu_sense            -> lo mismo Y ADEMAS el teclado RGB de 4 zonas
    # linuwu_sense sustituye a acer_wmi, asi que buscar solo acer_wmi daba un
    # aviso falso en cuanto se instalaba el driver del RGB.
    if [[ -d /sys/module/linuwu_sense ]]; then
        ok "linuwu_sense cargado (perfiles, ventiladores y teclado RGB)"
    elif [[ ! -d /sys/module/acer_wmi ]]; then
        aviso_contado "No hay ningun driver de plataforma Acer cargado."
        aviso_contado "Ejecuta:  sudo ./packaging/preparar-sistema.sh"
        hay_problema=1
    else
        ok "acer_wmi cargado."
        local p=/sys/module/acer_wmi/parameters/predator_v4
        if [[ -r "$p" ]]; then
            local v; v="$(cat "$p")"
            case "$v" in
                Y|y|1) ok "predator_v4 = $v" ;;
                *)     aviso_contado "predator_v4 = '$v' (deberia ser Y o 1)."
                       hay_problema=1 ;;
            esac
        else
            aviso_contado "Este acer_wmi no tiene el parametro predator_v4."
            aviso_contado "Kernel demasiado antiguo o modulo distinto."
            hay_problema=1
        fi
    fi

    if [[ -e /sys/firmware/acpi/platform_profile ]]; then
        ok "platform_profile existe."
        local choices=/sys/class/platform-profile/platform-profile-0/choices
        if [[ -r "$choices" ]]; then
            info "Perfiles disponibles: $(cat "$choices")"
        fi
    else
        aviso_contado "NO existe /sys/firmware/acpi/platform_profile."
        aviso_contado "Sin eso, el control de perfiles de la aplicacion no hara nada."
        hay_problema=1
    fi

    if [[ ! -e /sys/bus/wmi/drivers/acer-wmi-battery/health_mode ]]; then
        aviso_contado "No esta el modulo DKMS acer-wmi-battery (health_mode no existe)."
        aviso_contado "Sin el, la aplicacion no podra limitar la carga de la bateria al 80%."
        aviso_contado "Es un modulo aparte, no viene con el kernel; esta en el AUR:"
        aviso_contado "    yay -S acer-wmi-battery-dkms-git"
        aviso_contado "Despues, 'sudo ./packaging/preparar-sistema.sh' le pone la carga temprana."
    else
        ok "acer-wmi-battery presente (limite de carga disponible)."
    fi

    if (( hay_problema )); then
        aviso_contado "Todo esto lo deja listo, y de forma reversible:"
        aviso_contado "    sudo ./packaging/preparar-sistema.sh"
        aviso_contado "Si prefieres hacerlo a mano, los pasos son estos:"
        explicar_predator_v4
    fi
}

comprobar_grupo_wheel() {
    titulo "3. Grupo wheel"
    # 'wheel' importa en los DOS modos, pero por motivos distintos:
    #   polkit    -> en Arch la regla por defecto (50-default.rules) considera
    #                administradores a los miembros de wheel, asi que son los
    #                que pueden responder al dialogo de auth_admin_keep.
    #   --con-udev -> es el grupo al que se le abre la escritura en /sys.
    if getent group wheel >/dev/null; then
        ok "El grupo wheel existe (gid $(getent group wheel | cut -d: -f3))."
        if id -nG "$USUARIO" | tr ' ' '\n' | grep -qx wheel; then
            ok "El usuario '$USUARIO' pertenece a wheel."
        elif (( CON_UDEV )); then
            aviso_contado "El usuario '$USUARIO' NO esta en el grupo wheel."
            aviso_contado "Con --con-udev es wheel quien recibe la escritura en /sys, asi"
            aviso_contado "que la aplicacion no podra cambiar nada. Anadelo con:"
            aviso_contado "    sudo usermod -aG wheel $USUARIO"
            aviso_contado "y vuelve a iniciar sesion."
        else
            aviso_contado "El usuario '$USUARIO' NO esta en el grupo wheel."
            aviso_contado "En modo polkit la aplicacion funciona igual, pero el dialogo"
            aviso_contado "pedira la contrasena de un administrador y no la tuya."
        fi
    elif (( CON_UDEV )); then
        aviso_contado "No existe el grupo 'wheel' en este sistema."
        aviso_contado "Las reglas udev y el tmpfiles.d se instalaran pero no serviran de nada."
    else
        aviso_contado "No existe el grupo 'wheel' en este sistema: comprueba a quien"
        aviso_contado "considera administrador tu polkit antes de dar esto por bueno."
    fi
}

# ---------------------------------------------------------------------------
#  Ayudantes de instalacion
# ---------------------------------------------------------------------------
# poner <modo> <origen> <destino-sin-DESTDIR>
poner() {
    local modo="$1" origen="$2" destino="$3"
    if [[ ! -e "$origen" ]]; then
        aviso_contado "No existe '${origen#"$RAIZ"/}', se omite."
        return 1
    fi
    # OJO: casi todas las llamadas a 'poner' llevan '|| true', y eso APAGA
    # 'set -e' dentro de la funcion.  Sin comprobar aqui el codigo de salida,
    # un 'install' que falla (disco lleno, destino de solo lectura, sin
    # permiso) seguia cayendo en la linea siguiente e imprimiendo "ok", y el
    # instalador terminaba diciendo "Terminado sin avisos".  Comprobado con un
    # directorio de destino en 0555.
    if ! install -Dm"$modo" "$origen" "${DESTDIR}${destino}"; then
        error_contado "NO se pudo instalar ${destino}"
        return 1
    fi
    ok "${destino}"
}

# poner_arbol <origen-dir> <destino-dir-sin-DESTDIR>
poner_arbol() {
    local origen="$1" destino="$2"
    if [[ ! -d "$origen" ]]; then
        aviso_contado "No existe el directorio '${origen#"$RAIZ"/}', se omite."
        return 1
    fi
    if [[ -z "$(ls -A "$origen" 2>/dev/null)" ]]; then
        aviso_contado "El directorio '${origen#"$RAIZ"/}' esta vacio, se omite."
        return 1
    fi
    # Mismo motivo que en 'poner': aqui 'set -e' no protege nada porque la
    # funcion se llama dentro de un 'if'.  Un fallo de cp dejaba el arbol a
    # medias y la funcion devolvia 0, asi que el instalador daba por instalado
    # el codigo y ponia el lanzador y la entrada de menu apuntando a nada.
    if ! install -d "${DESTDIR}${destino}"; then
        error_contado "NO se pudo crear ${destino}/"
        return 1
    fi
    if ! cp -a "$origen"/. "${DESTDIR}${destino}/"; then
        error_contado "NO se pudo copiar el arbol en ${destino}/"
        return 1
    fi
    # Basura de Python: no tiene nada que hacer en /usr.
    find "${DESTDIR}${destino}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find "${DESTDIR}${destino}" -name '*.pyc' -type f -delete 2>/dev/null || true
    # Basura del editor.  Se limpia en el DESTINO y no en el origen a proposito:
    # asi se lleva por delante tambien la que instalaron versiones anteriores.
    # Paso real: /usr/lib/nitro-gekko/gekkonitro/window.py.bak, 35938 bytes,
    # instalado como codigo de sistema porque `cp -a` copia todo lo que
    # encuentra y quedandose ahi para siempre, porque `cp -a` tampoco borra.
    # No es cosmetico: era codigo viejo, propiedad de root, dentro de /usr.
    local basura=0 sobrante
    while IFS= read -r sobrante; do
        rm -f "$sobrante" && basura=$(( basura + 1 ))
    done < <(find "${DESTDIR}${destino}" -type f \
                  \( -name '*.bak' -o -name '*.orig' -o -name '*.rej' \
                     -o -name '*~' -o -name '*.swp' -o -name '*.swo' \
                     -o -name '*.tmp' \) 2>/dev/null)
    (( basura > 0 )) && info "Se han quitado $basura fichero(s) de basura del editor de ${destino}/."
    # 'cp -a' equivale a '--preserve=all': arrastra el modo Y el propietario
    # del repositorio.  Sin normalizar, un clon hecho con umask 002 dejaba
    # /usr/lib/nitro-gekko/gekkonitro/*.py como 664 usuario:usuario, es decir
    # codigo de sistema que cualquier proceso del usuario puede reescribir.
    # Comprobado: cp -a de un fichero 666 lo deja 666 en el destino.
    find "${DESTDIR}${destino}" -type d -exec chmod 755 {} +
    find "${DESTDIR}${destino}" -type f -exec chmod 644 {} +
    # El propietario solo se puede cambiar con root.  La extension se vuelve
    # a asignar al usuario mas abajo, en instalar().
    if [[ "$(id -u)" -eq 0 ]]; then
        chown -R root:root "${DESTDIR}${destino}"
    fi
    local n
    n="$(find "${DESTDIR}${destino}" -type f | wc -l)"
    if (( n == 0 )); then
        error_contado "${destino}/ ha quedado vacio: la copia no ha llegado."
        return 1
    fi
    ok "${destino}/  ($n ficheros)"
}

# UUID de la extension, leido de metadata.json (nunca inventado)
uuid_extension() {
    local meta="$RAIZ/extension/metadata.json"
    [[ -f "$meta" ]] || return 1
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["uuid"])' "$meta" 2>/dev/null
}

# Versiones de GNOME Shell que declara la extension, una por linea.
versiones_extension() {
    local meta="$RAIZ/extension/metadata.json"
    [[ -f "$meta" ]] || return 1
    python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print("\n".join(str(v) for v in d.get("shell-version", [])))' "$meta" 2>/dev/null
}

# ---------------------------------------------------------------------------
#  ¿Va a cargar la extension en ESTE GNOME?
#
#  GNOME rechaza toda extension cuyo metadata.json no incluya la version de
#  Shell que corre: la marca como "outdated" y se queda desactivada.  Y
#  'gnome-extensions enable' no explica el motivo.  Como aqui metadata.json
#  declara UNA sola version, en cualquier otro GNOME la extension no cargara
#  jamas -- y sin este aviso la persona se queda dando vueltas al 'enable'
#  creyendo que ha instalado mal algo.
#
#  Es un AVISO, no un error: la aplicacion no depende de la extension.
# ---------------------------------------------------------------------------
comprobar_version_gnome() {
    local uuid="$1"
    local declaradas lista mia mayor
    declaradas="$(versiones_extension || true)"
    if [[ -z "$declaradas" ]]; then
        aviso_contado "extension/metadata.json no declara 'shell-version'."
        aviso_contado "GNOME no cargara una extension sin ese campo."
        return 0
    fi
    lista="$(printf '%s' "$declaradas" | tr '\n' ' ')"
    if ! command -v gnome-shell >/dev/null; then
        info "No hay gnome-shell aqui: la extension queda copiada pero sin usar."
        info "La aplicacion funciona igual sin ella."
        return 0
    fi
    mia="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)*' | head -1 || true)"
    mayor="${mia%%.*}"
    if [[ -z "$mayor" ]]; then
        info "No se ha podido leer la version de GNOME Shell; se omite la comprobacion."
        return 0
    fi
    # GNOME acepta tanto "50" como "50.4" en el array; se prueban las dos.
    if printf '%s\n' "$declaradas" | grep -qx -e "$mayor" -e "$mia"; then
        ok "GNOME Shell $mia esta en la lista de la extension ($lista)"
    else
        aviso_contado "Tu GNOME Shell es $mia y la extension declara: $lista"
        aviso_contado "GNOME la marcara como 'outdated' y NO la cargara. El comando"
        aviso_contado "'gnome-extensions enable $uuid' no te dira por que."
        aviso_contado "La APLICACION funciona igual: lo unico que pierdes es el"
        aviso_contado "control del perfil y las RPM desde Configuracion rapida."
        aviso_contado "Si quieres intentarlo igualmente, anade \"$mayor\" al array"
        aviso_contado "shell-version de extension/metadata.json y repite la instalacion."
        aviso_contado "No usa ninguna API estrenada en 50, pero no esta probada fuera."
    fi
    return 0
}

# ---------------------------------------------------------------------------
#  Instalar
# ---------------------------------------------------------------------------
instalar() {
    titulo "4. Instalando ficheros"
    [[ -n "$DESTDIR" ]] && info "DESTDIR = $DESTDIR (no se toca el sistema real)"

    # -- permisos (1): helper privilegiado + politica polkit -----------------
    # Este es el camino POR DEFECTO. El helper corre como root via pkexec y solo
    # acepta TRECE acciones con nombre; la lista de rutas vive dentro de el, no
    # se le pasa desde fuera.  Ver 'Seguridad y permisos' en el README.
    poner 755 "$RAIZ/packaging/$FICHERO_HELPER" "$DIR_APP/$FICHERO_HELPER" || true

    # -- persistencia entre arranques ----------------------------------------
    # El helper anota en $DIR_ESTADO cada valor que aplica; esta unidad lo
    # repone al arrancar.  Hace falta porque el driver solo guarda su estado
    # cuando se DESCARGA el modulo, y al apagar el equipo eso no pasa: lo que
    # repondria es lo que hubiera la ultima vez que alguien hizo un rmmod.
    if [[ -f "$RAIZ/packaging/$FICHERO_RESTAURAR" ]]; then
        poner 755 "$RAIZ/packaging/$FICHERO_RESTAURAR" "$DIR_APP/$FICHERO_RESTAURAR" || true
        poner 644 "$RAIZ/packaging/$FICHERO_UNIDAD" "$DIR_SYSTEMD/$FICHERO_UNIDAD" || true
        # El directorio de estado lo crea aqui el instalador y no el helper en
        # caliente: asi es root:root 0755 desde el primer momento y nadie puede
        # adelantarse a crearlo con otros permisos.
        if install -d -m 755 -o root -g root "${DESTDIR}${DIR_ESTADO}" 2>/dev/null \
           || install -d -m 755 "${DESTDIR}${DIR_ESTADO}" 2>/dev/null; then
            ok "${DIR_ESTADO}/  (estado para reponer tras reiniciar)"
        else
            aviso_contado "NO se pudo crear ${DIR_ESTADO}/: no se repondran los ajustes."
        fi
    fi
    if [[ -f "$RAIZ/packaging/$FICHERO_POLICY" ]]; then
        # Una politica polkit mal formada se ignora EN SILENCIO: la accion
        # org.thegekko.nitrogekko.aplicar no existiria y pkexec caeria en
        # org.freedesktop.policykit.exec (auth_admin sin cache = contrasena en
        # cada pulsacion).  Como el sintoma no dice la causa, esto ABORTA la
        # instalacion en vez de avisar.  Se valida ademas contra el DTD local
        # de polkit, con --nonet, sustituyendo la URL remota por la ruta local:
        # asi tambien se detecta un elemento o un atributo que polkit no
        # entienda, no solo el XML roto.
        if command -v xmllint >/dev/null; then
            if ! xmllint --nonet --noout "$RAIZ/packaging/$FICHERO_POLICY"; then
                error_contado "El XML de $FICHERO_POLICY no esta bien formado; polkit lo ignoraria."
                exit 1
            fi
            local dtd="/usr/share/polkit-1/policyconfig-1.dtd"
            if [[ -r "$dtd" ]]; then
                local tmp_pol
                tmp_pol="$(mktemp)"
                sed "s#http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd#${dtd}#" \
                    "$RAIZ/packaging/$FICHERO_POLICY" > "$tmp_pol"
                # `xmllint --valid` DEVUELVE 0 CUANDO NO ENCUENTRA EL DTD: se
                # limita a imprimir "Validation failed: no DTD found !" y sale
                # con exito.  Comprobado en libxml2 con esta misma politica:
                #
                #   $ sed 's#.../PolicyKit/1/policyconfig.dtd#...#' pol \
                #       | xmllint --nonet --noout --valid - ; echo $?
                #   -:78: validity error : Validation failed: no DTD found !
                #   0
                #
                # O sea que si el DOCTYPE del fichero cambia y la sustitucion
                # deja de casar, fiarse del codigo de salida daria "ok" SIN
                # HABER VALIDADO NADA.  Por eso no basta con mirar el codigo:
                # se exige ademas que xmllint NO haya dicho nada.  Cualquier
                # diagnostico (DTD no encontrado, elemento no declarado, error
                # de E/S) significa que la politica no esta validada.
                local salida_val=""
                if salida_val="$(xmllint --nonet --noout --valid "$tmp_pol" 2>&1)" \
                   && [[ -z "$salida_val" ]]; then
                    ok "politica polkit valida contra $dtd"
                else
                    [[ -n "$salida_val" ]] && printf '%s\n' "$salida_val" >&2
                    rm -f "$tmp_pol"
                    error_contado "$FICHERO_POLICY no valida contra el DTD de polkit."
                    exit 1
                fi
                rm -f "$tmp_pol"
            else
                ok "politica polkit bien formada (sin DTD local para validar)"
            fi
        else
            aviso_contado "Sin xmllint: no se ha podido validar $FICHERO_POLICY."
        fi

        # La anotacion exec.path de la politica lleva la ruta ABSOLUTA del
        # helper escrita a mano (/usr/lib/...).  Con PREFIX distinto de /usr el
        # helper acabaria en otro sitio y la anotacion apuntaria a un fichero
        # que no existe: polkit no casaria la accion y pkexec pediria
        # contrasena en cada pulsacion.  Se sustituye al instalar.
        local ruta_helper="${DIR_APP}/${FICHERO_HELPER}"
        install -d "${DESTDIR}${DIR_POLKIT}"
        if sed "s#<annotate key=\"org.freedesktop.policykit.exec.path\">[^<]*#<annotate key=\"org.freedesktop.policykit.exec.path\">${ruta_helper}#" \
               "$RAIZ/packaging/$FICHERO_POLICY" > "${DESTDIR}${DIR_POLKIT}/${FICHERO_POLICY}"; then
            chmod 644 "${DESTDIR}${DIR_POLKIT}/${FICHERO_POLICY}"
            [[ -z "$DESTDIR" ]] && [[ "$(id -u)" -eq 0 ]] && \
                chown root:root "${DESTDIR}${DIR_POLKIT}/${FICHERO_POLICY}"
            ok "${DIR_POLKIT}/${FICHERO_POLICY}  (exec.path -> ${ruta_helper})"
        else
            error_contado "No se ha podido instalar $FICHERO_POLICY."
            exit 1
        fi
        # polkit solo lee /etc/polkit-1/actions, /run/polkit-1/actions,
        # /usr/local/share/polkit-1/actions y /usr/share/polkit-1/actions
        # (comprobado en polkit 127).  Con cualquier otro PREFIX la politica
        # se copia a un sitio que polkit nunca mira.
        case "$DIR_POLKIT" in
            /usr/share/polkit-1/actions|/usr/local/share/polkit-1/actions|/etc/polkit-1/actions) ;;
            *) aviso_contado "polkit NO lee $DIR_POLKIT: la app pedira contrasena en cada cambio." ;;
        esac
    else
        error_contado "Falta packaging/$FICHERO_POLICY: la app no podria pedir permisos."
        exit 1
    fi

    # -- permisos (2): reglas udev y tmpfiles, SOLO con --con-udev ------------
    # udev descarta en silencio una regla que no sabe leer, asi que se valida
    # antes de instalarla: si no, los permisos no se aplicarian nunca y no
    # habria ni un mensaje que lo dijera.
    if (( ! CON_UDEV )); then
        info "Modo polkit (por defecto): no se abren permisos de /sys."
        info "La aplicacion pedira la contrasena por el dialogo de GNOME."
        info "Para el modo sin contrasena: $0 --con-udev  (lee antes el README)."
    elif command -v udevadm >/dev/null && [[ -f "$RAIZ/packaging/$FICHERO_UDEV" ]]; then
        if udevadm verify "$RAIZ/packaging/$FICHERO_UDEV" >/dev/null 2>&1; then
            ok "reglas udev validadas con 'udevadm verify'"
        else
            aviso_contado "'udevadm verify' rechaza packaging/$FICHERO_UDEV:"
            udevadm verify "$RAIZ/packaging/$FICHERO_UDEV" 2>&1 | sed 's/^/      /' >&2 || true
        fi
    fi
    if (( CON_UDEV )); then
        poner 644 "$RAIZ/packaging/$FICHERO_UDEV"     "$DIR_UDEV/$FICHERO_UDEV"     || true
        poner 644 "$RAIZ/packaging/$FICHERO_TMPFILES" "$DIR_TMPFILES/$FICHERO_TMPFILES" || true
    fi

    # -- codigo de la aplicacion ---------------------------------------------
    # Si esto no esta, no hay aplicacion: ni lanzador ni entrada de menu, que
    # solo servirian para fallar con ModuleNotFoundError al pulsarlos.
    local hay_codigo=0
    if [[ -d "$RAIZ/src/gekkonitro" ]]; then
        if poner_arbol "$RAIZ/src/gekkonitro" "$DIR_APP/gekkonitro"; then
            hay_codigo=1
        fi
    else
        aviso_contado "NO existe src/gekkonitro: la aplicacion no se instala."
        aviso_contado "Se omiten tambien el lanzador y la entrada de menu, que sin"
        aviso_contado "codigo solo darian ModuleNotFoundError. Lanza el instalador"
        aviso_contado "desde la raiz del repositorio completo."
    fi

    # -- lanzador en /usr/bin -------------------------------------------------
    # Se instala bin/nitro-gekko si existe; si no, se genera uno.
    # OJO: el ./nitro-gekko de la raiz del proyecto NO se instala a proposito.
    # Ese es el lanzador de DESARROLLO: apunta con PYTHONPATH y XDG_DATA_DIRS
    # al arbol del repositorio, asi que en /usr/bin dejaria de funcionar en
    # cuanto el repositorio cambiara de sitio.
    if (( ! hay_codigo )); then
        info "Sin codigo instalado: se omite el lanzador."
    elif [[ -f "$RAIZ/bin/$APP_BIN" ]]; then
        poner 755 "$RAIZ/bin/$APP_BIN" "$DIR_BIN/$APP_BIN" || true
    else
        if ! install -d "${DESTDIR}${DIR_BIN}"; then
            error_contado "NO se pudo crear ${DIR_BIN}"
            return 1
        fi
        cat > "${DESTDIR}${DIR_BIN}/${APP_BIN}" <<LANZADOR
#!/bin/sh
# Lanzador de $APP_NOMBRE (generado por packaging/install.sh).
# Si la aplicacion cambia de punto de entrada, este es el unico fichero
# que hay que tocar.
PYTHONPATH="${DIR_APP}\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHONPATH
exec /usr/bin/python3 -m gekkonitro "\$@"
LANZADOR
        chmod 755 "${DESTDIR}${DIR_BIN}/${APP_BIN}"
        ok "${DIR_BIN}/${APP_BIN}  (generado)"
    fi

    # -- .desktop -------------------------------------------------------------
    local desktop
    desktop="$(find "$RAIZ/data" -maxdepth 2 -name "${APP_ID}.desktop" -print -quit 2>/dev/null || true)"
    if (( ! hay_codigo )); then
        info "Sin codigo instalado: se omite la entrada de menu."
    elif [[ -n "$desktop" ]]; then
        poner 644 "$desktop" "$DIR_DESKTOP/${APP_ID}.desktop" || true
    else
        aviso_contado "No se encuentra ${APP_ID}.desktop en data/, se omite."
    fi

    # -- iconos ---------------------------------------------------------------
    # Se acepta tanto data/icons/hicolor/... (arbol ya montado) como
    # data/<APP_ID>.svg suelto.
    #
    # UN SVG TIENE QUE DECLARAR SU ETIQUETA <svg DENTRO DE LOS PRIMEROS 256
    # BYTES.  No es un capricho de estilo: GdkPixbuf averigua el formato de un
    # fichero olfateando solo el principio, y GNOME Shell carga los iconos por
    # ahi.  Medido en esta maquina por biseccion: con `<svg` en el byte 256
    # carga, en el 257 contesta «Couldn't recognize the image file format».
    # Un comentario largo por delante de la etiqueta basta para pasarse, y el
    # sintoma no es un icono feo: es NINGUN icono, y solo en la rejilla de
    # aplicaciones, que es el unico sitio que pide 96 px y por tanto el unico
    # que cae en el SVG en vez de en un PNG. rsvg-convert y los navegadores lo
    # renderizan igual, asi que a ojo el fichero parece perfecto.
    comprobar_svg() {
        # Sustitucion de proceso y no tuberia: con `set -o pipefail`, un
        # `head | grep -q` devuelve 141 si grep acierta pronto y head se lleva
        # un SIGPIPE.  Ver «Las reglas que no se negocian» del README.
        grep -q '<svg' < <(head -c 256 "$1")
    }
    local instalado_icono=0
    if [[ -d "$RAIZ/data/icons/hicolor" ]]; then
        while IFS= read -r -d '' icono; do
            local rel="${icono#"$RAIZ"/data/icons/hicolor/}"
            if [[ "$icono" == *.svg ]] && ! comprobar_svg "$icono"; then
                error_contado "${rel}: la etiqueta <svg no esta en los primeros 256 bytes."
                aviso "GdkPixbuf no sabra que formato es y GNOME lo pintara vacio."
                aviso "Mueve el comentario de cabecera DENTRO del <svg>, detras de la etiqueta."
                continue
            fi
            if install -Dm644 "$icono" "${DESTDIR}${DIR_ICONOS}/${rel}"; then
                ok "${DIR_ICONOS}/${rel}"
                instalado_icono=1
            else
                error_contado "NO se pudo instalar ${DIR_ICONOS}/${rel}"
            fi
        done < <(find "$RAIZ/data/icons/hicolor" -type f \( -name '*.svg' -o -name '*.png' \) -print0 2>/dev/null)
    fi
    if (( ! instalado_icono )); then
        local suelto
        suelto="$(find "$RAIZ/data" -maxdepth 1 -name "${APP_ID}.svg" -print -quit 2>/dev/null || true)"
        if [[ -n "$suelto" ]]; then
            poner 644 "$suelto" "$DIR_ICONOS/scalable/apps/${APP_ID}.svg" || true
            instalado_icono=1
        fi
    fi
    (( instalado_icono )) || aviso_contado "No se ha encontrado ningun icono en data/, se omite."

    # -- esquema de GSettings (si lo hay) -------------------------------------
    local esquema
    esquema="$(find "$RAIZ/data" -maxdepth 2 -name "${APP_ID}.gschema.xml" -print -quit 2>/dev/null || true)"
    if [[ -n "$esquema" ]]; then
        poner 644 "$esquema" "$DIR_ESQUEMAS/${APP_ID}.gschema.xml" || true
    fi

    # -- extension de GNOME Shell (en el HOME del usuario, no en /usr) --------
    titulo "5. Extension de GNOME Shell"
    local uuid
    if uuid="$(uuid_extension)" && [[ -n "$uuid" ]]; then
        info "UUID leido de extension/metadata.json: $uuid"
        if poner_arbol "$RAIZ/extension" "${DIR_EXTENSIONES}/${uuid}"; then
            # La extension es del usuario, no de root.
            if [[ -z "$DESTDIR" ]] && [[ "$(id -u)" -eq 0 ]]; then
                chown -R "$USUARIO": "${DIR_EXTENSIONES}/${uuid}"
                ok "Propietario ajustado a $USUARIO."
            fi
            comprobar_version_gnome "$uuid"
            info "Para activarla:  gnome-extensions enable $uuid"
            info "En Wayland hace falta cerrar y abrir sesion (no vale Alt+F2 r)."
        fi
    else
        aviso_contado "No hay extension/metadata.json (o no tiene 'uuid'): extension omitida."
    fi
}

# ---------------------------------------------------------------------------
#  Caches del escritorio
#
#  Esto tiene que correr SIEMPRE que se haya instalado de verdad, y no solo
#  con --con-udev.  La cache de iconos no se actualiza sola: sin regenerarla,
#  GNOME Shell sigue leyendo el indice viejo y la aplicacion sale SIN ICONO en
#  la rejilla aunque el PNG este en su sitio y GTK lo encuentre por busqueda
#  directa.  Se llama DESPUES de copiar los iconos, nunca antes.
#
#  BUG ARREGLADO: este bloque estaba dentro de recargar(), detras del
#  'return 0' del modo polkit -- que es el modo POR DEFECTO.  Es decir, en la
#  instalacion normal no se ejecutaba nunca y el icono no aparecia.
# ---------------------------------------------------------------------------
refrescar_caches() {
    # En Arch /usr/bin/gtk-update-icon-cache es un enlace a
    # gtk4-update-icon-cache (paquete gtk-update-icon-cache): basta con
    # llamar al primero que exista, llamar a los dos es redundante.
    local cache_iconos=""
    if command -v gtk-update-icon-cache >/dev/null; then
        cache_iconos=gtk-update-icon-cache
    elif command -v gtk4-update-icon-cache >/dev/null; then
        cache_iconos=gtk4-update-icon-cache
    fi
    if [[ -n "$cache_iconos" ]]; then
        if "$cache_iconos" -f -t -q "$DIR_ICONOS" 2>/dev/null; then
            ok "cache de iconos regenerada ($cache_iconos)"
        else
            aviso_contado "no se pudo regenerar la cache de iconos"
        fi
    else
        aviso_contado "falta gtk-update-icon-cache: el icono puede no aparecer."
        aviso_contado "    sudo pacman -S gtk-update-icon-cache"
    fi

    if command -v update-desktop-database >/dev/null; then
        update-desktop-database -q "$DIR_DESKTOP" 2>/dev/null \
            && ok "base de datos de aplicaciones actualizada" || true
    fi
    if [[ -d "$DIR_ESQUEMAS" ]] && command -v glib-compile-schemas >/dev/null; then
        glib-compile-schemas "$DIR_ESQUEMAS" 2>/dev/null \
            && ok "esquemas de GSettings compilados" || true
    fi
    # Nunca devuelve error: ninguna de estas caches es motivo para dar la
    # instalacion por fallida, y con 'set -e' un return != 0 la tumbaria.
    return 0
}

# ---------------------------------------------------------------------------
#  Recargas (solo instalacion real)
# ---------------------------------------------------------------------------
recargar() {
    titulo "6. Aplicando permisos y refrescando caches"

    if [[ -n "$DESTDIR" ]]; then
        info "DESTDIR activo: no se recarga udev, ni tmpfiles, ni caches, ni /sys."
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        aviso_contado "Sin root no se puede recargar. Hazlo a mano:"
        aviso_contado "    sudo gtk-update-icon-cache -f -t $DIR_ICONOS"
        aviso_contado "    sudo update-desktop-database $DIR_DESKTOP"
        if (( CON_UDEV )); then
            aviso_contado "    sudo udevadm control --reload"
            aviso_contado "    sudo udevadm trigger --action=change --subsystem-match=platform-profile --subsystem-match=powercap --subsystem-match=wmi"
            aviso_contado "    sudo systemd-tmpfiles --create ${DIR_TMPFILES}/${FICHERO_TMPFILES}"
        fi
        return 0
    fi

    # -- unidad que repone los ajustes tras reiniciar ------------------------
    if [[ -f "${DIR_SYSTEMD}/${FICHERO_UNIDAD}" ]] && command -v systemctl >/dev/null; then
        systemctl daemon-reload 2>/dev/null || true
        # 'enable' a secas, sin --now: al instalar no hay nada que reponer
        # todavia, y arrancarla aqui solo serviria para escribir en el journal
        # que el fichero de estado no existe.
        if systemctl enable "${FICHERO_UNIDAD}" >/dev/null 2>&1; then
            ok "${FICHERO_UNIDAD} activada (repone tus ajustes al arrancar)"
        else
            aviso_contado "NO se pudo activar ${FICHERO_UNIDAD}: los ajustes no se repondran."
            aviso_contado "    sudo systemctl enable ${FICHERO_UNIDAD}"
        fi
    fi

    if (( ! CON_UDEV )); then
        # En modo polkit no se instala ninguna regla ni tmpfiles, asi que no
        # hay nada que recargar: intentarlo solo produce un error confuso
        # ("Failed to read /usr/lib/tmpfiles.d/nitro-gekko.conf").  Las caches
        # del escritorio SI hay que refrescarlas, y por eso ya no se sale de
        # la funcion aqui.
        info "Modo polkit: no hay reglas de permisos que recargar."
        refrescar_caches
        return 0
    fi

    info "Recargando reglas de udev..."
    # Con guarda a proposito: en un chroot o un contenedor sin udevd corriendo
    # esto falla, y con 'set -e' mataba el instalador justo despues de haber
    # dejado las reglas puestas y antes de aplicar el tmpfiles.
    if udevadm control --reload 2>/dev/null; then
        # Se dispara solo en los subsistemas implicados; un trigger global es
        # innecesario y molesta al resto del sistema.
        udevadm trigger --action=change \
            --subsystem-match=platform-profile \
            --subsystem-match=powercap \
            --subsystem-match=wmi || true
        udevadm settle --timeout=10 || true
        ok "udev recargado."
    else
        aviso_contado "No se ha podido hablar con udevd (chroot o contenedor?)."
        aviso_contado "Las reglas quedan instaladas y se aplicaran al arrancar."
    fi

    info "Aplicando tmpfiles..."
    # Se le pasa la RUTA ABSOLUTA del fichero recien instalado, no el nombre a
    # secas: systemd-tmpfiles solo resuelve nombres sueltos dentro de sus
    # directorios estandar (/etc, /run, /usr/lib, /usr/local/lib). Con un
    # PREFIX fuera de esos, 'systemd-tmpfiles --create nitro-gekko.conf'
    # devuelve 1 ("No such file or directory") y con 'set -e' se llevaba por
    # delante el resto del instalador. Comprobado.
    if systemd-tmpfiles --create "${DIR_TMPFILES}/${FICHERO_TMPFILES}"; then
        ok "tmpfiles aplicado."
    else
        aviso_contado "systemd-tmpfiles ha fallado. Aplicalo a mano:"
        aviso_contado "    sudo systemd-tmpfiles --create ${DIR_TMPFILES}/${FICHERO_TMPFILES}"
    fi

    refrescar_caches

    titulo "7. Permisos resultantes de /sys"
    local ruta
    for ruta in "${RUTAS_SYSFS[@]}"; do
        if [[ -e "$ruta" ]]; then
            printf '  %s\n' "$(ls -l "$ruta")"
        else
            printf '  %s  %s(no existe)%s\n' "$ruta" "$C_AMAR" "$C_FIN"
        fi
    done
}

# ---------------------------------------------------------------------------
#  Rutas de sysfs que toca este paquete (para informar y para --uninstall)
# ---------------------------------------------------------------------------
RUTAS_SYSFS=(
    /sys/firmware/acpi/platform_profile
    /sys/class/platform-profile/platform-profile-0/profile
    /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
    /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
    /sys/bus/wmi/drivers/acer-wmi-battery/health_mode
    /sys/devices/system/cpu/intel_pstate/no_turbo
)

# ---------------------------------------------------------------------------
#  Desinstalar
# ---------------------------------------------------------------------------
desinstalar() {
    titulo "Desinstalando $APP_NOMBRE"
    [[ -n "$DESTDIR" ]] && info "DESTDIR = $DESTDIR"

    # OJO con la lista: tiene que cubrir TODO lo que instala instalar(), en
    # los dos modos.  La politica polkit faltaba, y al desinstalar quedaba
    # /usr/share/polkit-1/actions/org.thegekko.nitrogekko.policy registrando
    # una accion cuyo ejecutable (/usr/lib/nitro-gekko/nitro-gekko-helper) ya
    # no existia -- mientras el script decia "Desinstalado por completo".
    # El helper no hace falta nombrarlo: vive dentro de $DIR_APP, que se borra
    # entero mas abajo.
    # La unidad se para y se desactiva ANTES de borrar el fichero, o systemd
    # se queda con un enlace roto en /etc/systemd/system/multi-user.target.wants
    # y lo dice en cada arranque.
    if [[ -z "$DESTDIR" ]] && command -v systemctl >/dev/null; then
        if systemctl list-unit-files "$FICHERO_UNIDAD" >/dev/null 2>&1; then
            systemctl disable --now "$FICHERO_UNIDAD" >/dev/null 2>&1 || true
        fi
    fi

    local objetivo
    for objetivo in \
        "$DIR_POLKIT/$FICHERO_POLICY" \
        "$DIR_SYSTEMD/$FICHERO_UNIDAD" \
        "$DIR_UDEV/$FICHERO_UDEV" \
        "$DIR_TMPFILES/$FICHERO_TMPFILES" \
        "$DIR_BIN/$APP_BIN" \
        "$DIR_DESKTOP/${APP_ID}.desktop" \
        "$DIR_ESQUEMAS/${APP_ID}.gschema.xml"
    do
        if [[ -e "${DESTDIR}${objetivo}" ]]; then
            # Sin el 'else' esto era una bomba: con 'set -e', un solo rm sin
            # permiso abortaba la desinstalacion y dejaba instalado todo lo
            # demas -- incluidas las reglas que abren /sys. Verificado.
            if rm -f "${DESTDIR}${objetivo}" 2>/dev/null; then
                ok "borrado ${objetivo}"
            else
                aviso_contado "NO se ha podido borrar ${objetivo}"
            fi
        fi
    done

    if [[ -d "${DESTDIR}${DIR_APP}" ]]; then
        if rm -rf "${DESTDIR}${DIR_APP:?}" 2>/dev/null; then
            ok "borrado ${DIR_APP}/"
        else
            aviso_contado "NO se ha podido borrar ${DIR_APP}/"
        fi
    fi

    # El estado guardado se va con la desinstalacion: dejarlo seria guardar
    # ajustes de un programa que ya no esta, y ademas confundiria a quien
    # reinstale mas adelante reponiendole algo de hace meses.
    if [[ -d "${DESTDIR}${DIR_ESTADO}" ]]; then
        if rm -rf "${DESTDIR}${DIR_ESTADO:?}" 2>/dev/null; then
            ok "borrado ${DIR_ESTADO}/"
        else
            aviso_contado "NO se ha podido borrar ${DIR_ESTADO}/"
        fi
    fi

    # Iconos: solo los nuestros, por nombre exacto.
    if [[ -d "${DESTDIR}${DIR_ICONOS}" ]]; then
        while IFS= read -r -d '' icono; do
            if rm -f "$icono" 2>/dev/null; then
                ok "borrado ${icono#"$DESTDIR"}"
            else
                aviso_contado "NO se ha podido borrar ${icono#"$DESTDIR"}"
            fi
        # Ojo: "<APP_ID>.*" no casa con "<APP_ID>-symbolic.svg"; hacen falta los dos patrones.
        done < <(find "${DESTDIR}${DIR_ICONOS}" -type f \( -name "${APP_ID}.*" -o -name "${APP_ID}-*" \) -print0 2>/dev/null)
    fi

    # Extension
    local uuid
    if uuid="$(uuid_extension)" && [[ -n "$uuid" ]]; then
        if [[ -d "${DESTDIR}${DIR_EXTENSIONES}/${uuid}" ]]; then
            if rm -rf "${DESTDIR}${DIR_EXTENSIONES:?}/${uuid:?}" 2>/dev/null; then
                ok "borrada extension ${uuid}"
            else
                aviso_contado "NO se ha podido borrar la extension ${uuid}"
            fi
        fi
    else
        aviso_contado "Sin extension/metadata.json no se sabe que UUID borrar."
        aviso_contado "Mira a mano en ${DIR_EXTENSIONES}/"
    fi

    # Devolver sysfs a como estaba (0644 root:root). Solo en sistema real.
    if [[ -z "$DESTDIR" && "$(id -u)" -eq 0 ]]; then
        titulo "Devolviendo los permisos de sysfs a root"
        local ruta
        for ruta in "${RUTAS_SYSFS[@]}"; do
            if [[ -e "$ruta" ]]; then
                chgrp root "$ruta" 2>/dev/null || true
                chmod 0644  "$ruta" 2>/dev/null || true
                ok "$ruta -> 0644 root:root"
            fi
        done
        udevadm control --reload || true
        ok "udev recargado."
    elif [[ -z "$DESTDIR" ]]; then
        aviso_contado "Sin root no se han podido devolver los permisos de /sys."
        aviso_contado "Se arreglan solos al reiniciar, o ejecuta esto como root:"
        local ruta
        for ruta in "${RUTAS_SYSFS[@]}"; do
            aviso_contado "    chgrp root '$ruta' && chmod 0644 '$ruta'"
        done
    fi

    # Refrescar las caches del escritorio. Sin esto, la entrada de menu y el
    # icono seguian saliendo en el lanzador de aplicaciones (apuntando a un
    # binario que ya no existe) hasta que otro paquete regenerase las caches.
    if [[ -z "$DESTDIR" && "$(id -u)" -eq 0 ]]; then
        refrescar_caches
    fi

    # Comprobacion final: no basta con fiarse de los avisos, se mira el disco.
    # Si queda algo, el codigo de salida lo dice (importante para un script que
    # llame a esto y de la desinstalacion por buena).
    local restos=()
    local objetivo2
    for objetivo2 in \
        "$DIR_POLKIT/$FICHERO_POLICY" \
        "$DIR_UDEV/$FICHERO_UDEV" \
        "$DIR_TMPFILES/$FICHERO_TMPFILES" \
        "$DIR_BIN/$APP_BIN" \
        "$DIR_DESKTOP/${APP_ID}.desktop" \
        "$DIR_ESQUEMAS/${APP_ID}.gschema.xml" \
        "$DIR_APP"
    do
        if [[ -e "${DESTDIR}${objetivo2}" ]]; then
            restos+=("$objetivo2")
        fi
    done
    if [[ -d "${DESTDIR}${DIR_ICONOS}" ]]; then
        while IFS= read -r -d '' sobra; do
            restos+=("${sobra#"$DESTDIR"}")
        done < <(find "${DESTDIR}${DIR_ICONOS}" -type f \
                 \( -name "${APP_ID}.*" -o -name "${APP_ID}-*" \) -print0 2>/dev/null)
    fi

    printf '\n'
    if (( ${#restos[@]} )); then
        error "Ha quedado sin borrar:"
        local r
        for r in "${restos[@]}"; do error "    $r"; done
        error "Si son ficheros de /usr, repite con sudo."
        info "Si la extension estaba activa, cierra y abre sesion."
        return 1
    fi
    if (( HUBO_AVISOS )); then
        aviso "Desinstalacion terminada con $HUBO_AVISOS aviso(s), pero no queda ningun fichero."
    else
        ok "Desinstalado por completo."
    fi
    info "Si la extension estaba activa, cierra y abre sesion."
    return 0
}

# ---------------------------------------------------------------------------
#  Ayuda
# ---------------------------------------------------------------------------
ayuda() {
    cat <<AYUDA
$APP_NOMBRE - instalador de la aplicacion

  Instala el codigo, el lanzador, el icono, la extension de GNOME Shell, el
  helper privilegiado y la politica polkit.  El HARDWARE (modulo acer_wmi o
  linuwu_sense, limite de PL1, power-profiles-daemon, atajo del boton de la
  marca) lo prepara otro script:  sudo ./packaging/preparar-sistema.sh

  Uso:
    sudo $0
        Instala en el sistema.  Modo polkit: /sys sigue siendo de root y cada
        cambio pasa por el helper, que pide la contrasena una vez por sesion.

    sudo $0 --con-udev
        Instala y ademas abre seis rutas de /sys al grupo 'wheel'.  Sin
        dialogo de contrasena, pero cualquier proceso tuyo puede escribir ahi.

    sudo $0 --uninstall
        Desinstala todo lo que puso, y lo comprueba fichero a fichero.

    DESTDIR=/ruta $0
        Construye el arbol de ficheros en /ruta.  Sin root y sin tocar nada
        del sistema: es la forma de ver que va a instalar antes de dejarlo.

    $0 --help
        Esta ayuda.

  Variables:
    DESTDIR    Prefijo de destino para pruebas o para empaquetar. Si esta
               puesto, NO se recarga udev, ni tmpfiles, ni las caches del
               escritorio, ni se toca /sys.
    PREFIX     Prefijo de instalacion. Por omision /usr.
    DIR_EXTENSIONES
               Donde se copia la extension de GNOME Shell. Por omision, la
               carpeta del usuario que lanzo el sudo. Un paquete la pone en
               /usr/share/gnome-shell/extensions.
    DIR_DMI    Directorio de identificacion del equipo. Por omision
               /sys/class/dmi/id. Solo sirve para probar el aviso de
               hardware no compatible sin tener otro portatil delante.

  Que instala SIEMPRE  (todo root:root; los modos entre parentesis):
    0755  ${DIR_APP}/${FICHERO_HELPER}
          el unico que corre como root, invocado por pkexec
    0644  ${DIR_POLKIT}/${FICHERO_POLICY}
    0644  ${DIR_APP}/gekkonitro/*.py       (directorios 0755)
    0755  ${DIR_BIN}/${APP_BIN}
    0644  ${DIR_DESKTOP}/${APP_ID}.desktop
    0644  ${DIR_ICONOS}/<tamano>/apps/${APP_ID}.*
    0644  ${DIR_ESQUEMAS}/${APP_ID}.gschema.xml   (si existe)
          \$HOME/.local/share/gnome-shell/extensions/<uuid>/   (del usuario)

  Que instala SOLO con --con-udev:
    0644  ${DIR_UDEV}/${FICHERO_UDEV}
    0644  ${DIR_TMPFILES}/${FICHERO_TMPFILES}

  Esos dos ultimos son los que dan escritura al grupo 'wheel' sobre seis rutas
  de /sys, y por eso NO se instalan por defecto: sin ellos cualquier cambio
  pasa por el helper y por el dialogo de contrasena de GNOME.  Lee la seccion
  'Seguridad y permisos' del README antes de usar --con-udev: explica
  exactamente que se abre y que puede hacer con ello un proceso que corra
  como tu usuario.

  Codigos de salida:
    0  todo instalado (puede haber avisos informativos)
    1  falto algo por instalar o por borrar, o falta root
    2  opcion desconocida
AYUDA
}

# ---------------------------------------------------------------------------
#  Principal
# ---------------------------------------------------------------------------
main() {
    local accion="instalar"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall|--desinstalar) accion="desinstalar" ;;
            --con-udev)                CON_UDEV=1 ;;
            -h|--help|--ayuda)         ayuda; exit 0 ;;
            *) error "Opcion desconocida: $1"; ayuda; exit 2 ;;
        esac
        shift
    done

    detectar_usuario

    printf '%s%s%s  (%s)\n' "$C_NEG" "$APP_NOMBRE" "$C_FIN" "$APP_ID"
    info "Proyecto : $RAIZ"
    info "Usuario  : $USUARIO  (HOME $HOME_USUARIO)"

    # Desinstalar del sistema real necesita root igual que instalar. Antes no
    # se comprobaba: sin sudo, el primer rm de /usr fallaba y la desinstalacion
    # se paraba ahi dejando puestas las reglas que abren /sys, con la persona
    # convencida de haberlas quitado.
    if [[ "$accion" == "desinstalar" ]]; then
        if [[ -z "$DESTDIR" && "$(id -u)" -ne 0 ]]; then
            error "Para desinstalar del sistema hace falta root."
            error "    sudo $0 --uninstall"
            exit 1
        fi
        desinstalar
        exit $?
    fi

    # Root obligatorio solo si se va a tocar el sistema de verdad.
    if [[ -z "$DESTDIR" && "$(id -u)" -ne 0 ]]; then
        error "Para instalar en el sistema hace falta root."
        error "    sudo $0"
        error "O prueba sin tocar nada:"
        error "    DESTDIR=/tmp/prueba-nitro-gekko $0"
        exit 1
    fi

    # Con DESTDIR puesto se esta construyendo un arbol de ficheros, no
    # instalando en esta maquina: diagnosticar el equipo de la jaula de
    # compilacion no dice nada util y ensucia la salida de makepkg.  No cambian
    # el codigo de salida (son avisos), asi que saltarselas no altera nada mas.
    if [[ -z "$DESTDIR" ]]; then
        comprobar_hardware
        comprobar_modulo
        comprobar_grupo_wheel
    fi
    instalar
    recargar

    titulo "Resumen"
    if (( HUBO_ERRORES )); then
        error "Terminado con $HUBO_ERRORES error(es): hay ficheros que NO se han instalado."
        error "Revisa el espacio libre y los permisos del destino y vuelve a lanzarlo."
        (( HUBO_AVISOS )) && aviso "Ademas hubo $HUBO_AVISOS aviso(s)."
        return 1
    fi
    if (( HUBO_AVISOS )); then
        aviso "Terminado con $HUBO_AVISOS aviso(s). Leelos antes de dar por bueno esto."
    else
        ok "Terminado sin avisos."
    fi
    if [[ -z "$DESTDIR" ]]; then
        info "Lanza la aplicacion con: $APP_BIN"
        info "Si algo del hardware sale como no disponible (perfiles, RPM,"
        info "limite de carga de bateria), preparalo con:"
        info "    sudo ./packaging/preparar-sistema.sh"
    fi
    return 0
}

main "$@"
