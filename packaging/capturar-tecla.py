#!/usr/bin/env python3
"""Captura que tecla emite un boton del portatil.

Sirve para averiguar el codigo del boton con el logo de la marca (el que en
Windows abre NitroSense) y del boton de cambio de modo, para poder asignarlos
a Nitro Gekko.

No necesita ninguna libreria externa: lee /dev/input/eventN en crudo y
decodifica la estructura input_event a mano.

SI NECESITA PERMISO PARA LEER /dev/input.  En Arch esos nodos son
'crw-rw---- root:input', y un usuario recien creado NO esta en el grupo 'input'
-en este equipo estaba porque se anadio a mano-.  Asi que, tal cual, a la
mayoria de la gente este script le dira que no puede abrir nada.  Hay dos
salidas, y la primera no toca la configuracion del sistema:

    sudo python3 packaging/capturar-tecla.py     # de un tiron, sin cambiar nada
    sudo usermod -aG input "$USER"               # permanente; hay que reiniciar
                                                 # la sesion para que valga

Dar acceso permanente a /dev/input es dar acceso a TODO lo que teclees: un
proceso con ese grupo puede leer el teclado entero.  Para averiguar un codigo
de tecla una vez, usa el sudo puntual.

    python3 packaging/capturar-tecla.py        # escucha 25 segundos
    python3 packaging/capturar-tecla.py 20     # escucha 20 segundos
    python3 packaging/capturar-tecla.py --help # esta ayuda

En este portatil (Acer Nitro AN17-51) el boton con el logo de la marca -el que
en Windows abre NitroSense- emite KEY_PRESENTATION, que para el escritorio es
XF86Presentation.  En GNOME ese atajo lo asigna packaging/preparar-sistema.sh, y
en Hyprland es una linea de su configuracion (README, «En Hyprland»); este
script sirve para averiguar la tecla en un modelo distinto.

Tambien destapa las teclas con el nombre equivocado.  La del microfono de este
equipo llegaba como KEY_F15, que no atiende nadie, y no dejaba ni rastro en
journalctl.  Si una tecla especial sale como F13-F24, el script mira como llama
systemd a ese scancode en otros equipos de la misma marca y da la entrada de
hwdb para corregirlo.
"""

from __future__ import annotations

import os
import re
import select
import shutil
import struct
import subprocess
import sys
import time
from collections import Counter

# struct input_event de 64 bits:
#   struct timeval time  -> 2 x long  (16 bytes)
#   __u16 type, __u16 code, __s32 value
FORMATO = "llHHi"
TAM = struct.calcsize(FORMATO)

EV_KEY = 0x01
EV_MSC = 0x04
MSC_SCAN = 0x04

# --------------------------------------------------------------------------
# Nombre de la tecla: NO se escribe a mano
#
# La tabla escrita a mano que habia aqui tenia cuatro constantes mal:
#   KEY_TOUCHPAD_TOGGLE decia 0x1E4 (484) y son 0x212 (530)
#   KEY_ASSISTANT       decia 431      y son 0x247 (583)
#   KEY_CONTROLPANEL    decia 0x24B    y son 0x243 (579)
#   KEY_NEWS            decia 426      y son 0x1ab (427)
# Con eso el script bautizaba mal la tecla y, peor, daba un nombre de atajo
# equivocado para meter en GNOME.  Ahora los dos nombres salen del propio
# sistema, que es la fuente de verdad:
#
#   /usr/include/linux/input-event-codes.h  ->  KEY_*      (linux-api-headers,
#                                                dependencia de glibc)
#   xkbcli compile-keymap                   ->  el nombre que ve el escritorio
#                                                (libxkbcommon)
#
# El segundo era symbols/inet a pelo, y se quedaba corto: solo sabia leer los
# codigos escritos como <I433>, no los que tienen nombre (<FK08>, <FK15>), y el
# 2026-10-28 dijo que F8 y F15 "no tienen nombre XKB".  F8 es F8, y F15 es
# XF86Launch6.  xkbcli compila el mapa entero, como el escritorio; si no esta
# (en Ubuntu viene en libxkbcommon-tools, que no se instala solo), se lee
# symbols/inet resolviendo los nombres con keycodes/evdev.
#
# El codigo XKB es el de evdev + 8, en decimal.  Comprobado:
#   evdev 425 -> <I433> -> XF86Presentation   (el boton del logo del AN17-51)
#   evdev 185 -> <FK15> -> XF86Launch6        (su tecla del microfono, sin hwdb)
# --------------------------------------------------------------------------

CABECERA_EVDEV = "/usr/include/linux/input-event-codes.h"
SIMBOLOS_XKB = "/usr/share/X11/xkb/symbols/inet"
KEYCODES_XKB = "/usr/share/X11/xkb/keycodes/evdev"
SIN_NOMBRE = "sin nombre XKB"

#: Ultimo recurso si faltan esos ficheros. Solo lo verificado en este equipo.
NOMBRES_MINIMOS = {425: ("KEY_PRESENTATION", "XF86Presentation")}


def _nombres_evdev() -> dict[int, str]:
    """codigo -> KEY_*, leido de la cabecera del kernel."""
    tabla: dict[int, str] = {}
    patron = re.compile(r"^#define\s+(KEY_[A-Z0-9_]+)\s+(0x[0-9a-fA-F]+|\d+)")
    try:
        with open(CABECERA_EVDEV, encoding="utf-8") as fh:
            for linea in fh:
                m = patron.match(linea)
                if m:
                    # KEY_MIN_INTERESTING y KEY_MAX son alias, no teclas.
                    tabla.setdefault(int(m.group(2), 0), m.group(1))
    except OSError:
        pass
    return tabla


def _nombres_x11() -> dict[int, str]:
    """codigo evdev -> XF86*, leido de xkeyboard-config.

    Dos detalles que hay que respetar o sale mal:

      * El numero de <I433> es DECIMAL, no hexadecimal.  Se comprueba en
        keycodes/evdev, donde pone  <I120> = 120;  // #define KEY_MACRO 112
        (120 - 8 = 112).  Interpretarlo en hexadecimal desplaza toda la tabla.

      * symbols/inet trae MUCHOS bloques xkb_symbols (uno por teclado raro de
        fabricante) que asignan simbolos distintos a los mismos codigos.  El
        que usan evdev y GNOME es el bloque llamado "evdev"; si se leen todos,
        gana el primero que aparezca y el nombre sale equivocado.
    """
    tabla: dict[int, str] = {}
    inicio = re.compile(r'^\s*xkb_symbols\s+"([^"]+)"')
    clave = re.compile(r"^\s*key\s+<([^>]+)>\s*\{\s*\[\s*([^\],\s]+)")
    try:
        with open(KEYCODES_XKB, encoding="utf-8") as fh:
            codigos = _codigos_xkb(fh.read())
    except OSError:
        codigos = {}
    dentro = False
    try:
        with open(SIMBOLOS_XKB, encoding="utf-8") as fh:
            for linea in fh:
                m_bloque = inicio.match(linea)
                if m_bloque:
                    dentro = m_bloque.group(1) == "evdev"
                    continue
                if not dentro:
                    continue
                m = clave.match(linea)
                if not m:
                    continue
                nombre = m.group(1)
                if nombre in codigos:
                    xkb = codigos[nombre]
                elif re.fullmatch(r"I\d+", nombre):
                    xkb = int(nombre[1:], 10)
                else:
                    continue
                # El keycode de XKB es el de evdev mas 8.
                tabla[xkb - 8] = m.group(2)
    except OSError:
        pass
    return tabla


def _codigos_xkb(texto: str) -> dict[str, int]:
    """Nombre de tecla XKB -> codigo XKB, con los alias resueltos.

    Vale para keycodes/evdev y para la seccion xkb_keycodes de un mapa
    compilado, que tienen la misma forma:  <FK15> = 193;  alias <I193> = <FK15>;
    """
    codigos = {
        n: int(c) for n, c in re.findall(r"^\s*<([^>]+)>\s*=\s*(\d+)\s*;", texto, re.M)
    }
    for alias, real in re.findall(r"^\s*alias\s+<([^>]+)>\s*=\s*<([^>]+)>\s*;", texto, re.M):
        if real in codigos:
            codigos.setdefault(alias, codigos[real])
    return codigos


def _nombres_xkbcli() -> dict[int, str]:
    """codigo evdev -> nombre, del mapa que compila libxkbcommon.

    Es el mismo que usa el escritorio (GNOME y Hyprland tiran de
    libxkbcommon).  La distribucion del teclado no importa aqui: las teclas
    especiales se llaman igual en todas.
    """
    xkbcli = shutil.which("xkbcli")
    if not xkbcli:
        return {}
    try:
        # stdin a /dev/null: sin el, xkbcli intenta leer un mapa de la entrada
        # que herede.  Desde un pipe salia un mapa vacio, y desde la terminal
        # de 'sudo' se quedaba esperando a que se teclease uno.
        mapa = subprocess.run(
            [xkbcli, "compile-keymap", "--rules", "evdev"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=10, check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    codigos = _codigos_xkb(mapa)
    tabla: dict[int, str] = {}
    for nombre, cuerpo in re.findall(r"\bkey\s+<([^>]+)>\s*\{(.*?)\};", mapa, re.S):
        # Dos formas:  { [ XF86Launch6 ] }  y, con tipo,
        #              { type= "CTRL+ALT", symbols[1]= [ F8, F8, ... ] }
        m = re.search(r"symbols\[[^\]]*\]\s*=\s*\[\s*([^\],\s]+)", cuerpo) or re.match(
            r"\s*\[\s*([^\],\s]+)", cuerpo
        )
        if m and nombre in codigos and m.group(1) != "NoSymbol":
            tabla[codigos[nombre] - 8] = m.group(1)
    return tabla


def construir_nombres() -> dict[int, tuple[str, str]]:
    evdev = _nombres_evdev()
    x11 = _nombres_xkbcli() or _nombres_x11()
    if not evdev and not x11:
        return dict(NOMBRES_MINIMOS)
    codigos = set(evdev) | set(x11)
    return {
        c: (evdev.get(c, f"codigo {c}"), x11.get(c, SIN_NOMBRE))
        for c in codigos
    }


NOMBRES = construir_nombres()


# --------------------------------------------------------------------------
# Teclas con el nombre equivocado
#
# A un scancode que no esta en la tabla de systemd, el kernel le pone el nombre
# que le toca por defecto, y en las teclas especiales de los portatiles suele
# caer en F13-F24.  Asi llegaba la tecla del microfono del AN17-51: scancode
# 0x66, KEY_F15, que el escritorio llama XF86Launch6 y no atiende nadie.  Y sin
# rastro: el kernel solo avisa ("Unknown key pressed") de los scancodes que no
# tienen NINGUN nombre, y este tenia uno.  El arreglo salio de mirar como
# llama systemd a ese mismo scancode en otros Acer (micmute, en cinco
# modelos), que es lo que hace aqui pista_nombre_equivocado().
# --------------------------------------------------------------------------

#: KEY_F13 (183) a KEY_F24 (194).
F13_A_F24 = range(183, 195)
TECLADO_INTERNO = "AT Translated Set 2 keyboard"
TABLA_SYSTEMD = (
    "/usr/lib/udev/hwdb.d/60-keyboard.hwdb",
    "/lib/udev/hwdb.d/60-keyboard.hwdb",
)
DIR_DMI = "/sys/class/dmi/id"


def _leer(ruta: str) -> str:
    try:
        with open(ruta, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def nombres_en_systemd(fabricante: str, scan: int) -> Counter[str]:
    """Como llama la tabla de systemd a este scancode en equipos del fabricante.

    La tabla son registros: una o mas lineas 'evdev:...' seguidas de lineas
    ' KEYBOARD_KEY_xx=nombre'.  Cuenta un nombre por registro cuyo match lleve
    ':svn<fabricante>'.
    """
    clave = f" KEYBOARD_KEY_{scan:x}="
    patron = f":svn{fabricante.lower()}"
    cuenta: Counter[str] = Counter()
    for ruta in TABLA_SYSTEMD:
        try:
            with open(ruta, encoding="utf-8") as fh:
                lineas = fh.read().splitlines()
        except OSError:
            continue
        del_fabricante = False
        venia_de_match = False
        for linea in lineas:
            if linea.startswith("evdev:"):
                if not venia_de_match:
                    del_fabricante = False
                del_fabricante = del_fabricante or patron in linea.lower()
                venia_de_match = True
                continue
            venia_de_match = False
            if del_fabricante and linea.startswith(clave):
                # '!' es "pisar aunque ya tenga nombre"; para el nombre no cuenta.
                nombre = linea[len(clave):].split("#")[0].strip().lstrip("!")
                if nombre:
                    cuenta[nombre] += 1
        break
    return cuenta


def pista_nombre_equivocado(ruta: str, codigo: int, scan: int) -> None:
    fabricante = _leer(f"{DIR_DMI}/sys_vendor")
    m = re.search(r":svn([^:]*):pn([^:]*):", _leer(f"{DIR_DMI}/modalias"))
    tecla = NOMBRES.get(codigo, (f"codigo {codigo}", ""))[0]
    print(f"     OJO: una tecla especial que llega como {tecla} suele tener el")
    print("     nombre equivocado: el kernel le pone el que toca por defecto a")
    print(f"     su scancode (0x{scan:02x}), y para el escritorio no significa nada.")
    sugeridos = nombres_en_systemd(fabricante, scan) if fabricante else Counter()
    if sugeridos:
        lista = ", ".join(f"{n} ({veces})" for n, veces in sugeridos.most_common(3))
        print(f"     En otros equipos de {fabricante}, systemd llama a ese scancode:")
        print(f"        {lista}")
    if not m:
        return
    nombre = sugeridos.most_common(1)[0][0] if sugeridos else "<nombre>"
    # El fichero y las dos ordenes son las que da la cabecera de
    # 60-keyboard.hwdb para las entradas locales.
    print("     Para darle nombre, en /etc/udev/hwdb.d/61-keyboard-local.hwdb:")
    print(f"        evdev:atkbd:dmi:bvn*:bvr*:bd*:svn{m.group(1)}*:pn{m.group(2)}:*")
    print(f"         KEYBOARD_KEY_{scan:x}={nombre}")
    print(f"     y despues:  sudo systemd-hwdb update && sudo udevadm trigger {ruta}")
    if not sugeridos:
        print("     El nombre es el KEY_* de input-event-codes.h en minusculas y sin")
        print("     'KEY_': micmute, prog1, kbdillumdown...")
    print("     Si funciona, vale la pena proponerlo para la tabla de systemd.")


def dispositivos_acer() -> list[tuple[str, str]]:
    """Devuelve [(ruta, nombre)] de los dispositivos de entrada del portatil."""
    encontrados = []
    try:
        with open("/proc/bus/input/devices", encoding="utf-8") as fh:
            bloques = fh.read().split("\n\n")
    except OSError:
        return []
    for bloque in bloques:
        m_nombre = re.search(r'N: Name="([^"]+)"', bloque)
        m_hand = re.search(r"H: Handlers=(.*)", bloque)
        if not m_nombre or not m_hand:
            continue
        nombre = m_nombre.group(1)
        # Solo los del propio portatil: hotkeys WMI y el teclado interno.
        if not re.search(r"Acer|AT Translated|Video Bus", nombre):
            continue
        for h in m_hand.group(1).split():
            if h.startswith("event"):
                ruta = f"/dev/input/{h}"
                if os.access(ruta, os.R_OK):
                    encontrados.append((ruta, nombre))
    return encontrados


def leer_segundos(argv: list[str]) -> int:
    """Un argumento mal escrito daba un traceback de Python en la cara.

        $ ./capturar-tecla.py --help
        ValueError: invalid literal for int() with base 10: '--help'
    """
    if len(argv) == 1:
        return 25
    if len(argv) > 2:
        print(f"Sobran argumentos: {' '.join(argv[2:])}", file=sys.stderr)
        raise SystemExit(2)
    arg = argv[1]
    if arg in ("-h", "--help", "--ayuda"):
        print(__doc__.strip())
        raise SystemExit(0)
    try:
        segundos = int(arg, 10)
    except ValueError:
        print(f"'{arg}' no es un numero de segundos.", file=sys.stderr)
        print("Uso:  capturar-tecla.py [segundos]   (--help para mas)", file=sys.stderr)
        raise SystemExit(2) from None
    if not 1 <= segundos <= 3600:
        print(f"{segundos} segundos esta fuera de rango (1..3600).", file=sys.stderr)
        raise SystemExit(2)
    return segundos


def main() -> None:
    segundos = leer_segundos(sys.argv)

    disp = dispositivos_acer()
    if not disp:
        print("No se pudo abrir ningun dispositivo de entrada del portatil.")
        print()
        if os.geteuid() != 0:
            # Lo normal: /dev/input/event* es 0640 root:input y el usuario no
            # esta en 'input'.  Antes solo se decia «comprueba el grupo», que
            # deja tirado a quien no sepa que hacer con esa informacion.
            print("Casi seguro que es cuestion de permisos: /dev/input/event*")
            print("pertenece a root:input con modo 0640, y tu no estas en ese")
            print("grupo (compruebalo con:  id -nG ).")
            print()
            print("Vuelve a lanzarlo asi, que no cambia nada del sistema:")
            print("    sudo python3 packaging/capturar-tecla.py")
            print()
            print("O, si lo quieres permanente (te deja leer TODO lo que")
            print("teclees, asi que piensatelo):")
            print('    sudo usermod -aG input "$USER"   # y reinicia la sesion')
        else:
            # Con root el permiso no puede ser: es que no hay dispositivos que
            # encajen con los nombres que buscamos.
            print("Estas como root, asi que no es un problema de permisos:")
            print("ninguno de los dispositivos de /proc/bus/input/devices se")
            print("llama 'Acer', 'AT Translated' ni 'Video Bus'.")
            print("Mira la lista completa con:  cat /proc/bus/input/devices")
            print("y prueba con:  sudo evtest   (paquete extra/evtest)")
        raise SystemExit(1)

    print("Escuchando en:")
    for ruta, nombre in disp:
        print(f"  {ruta}  ({nombre})")
    print()
    print("=" * 62)
    print(f"  PULSA AHORA EL BOTON. Tienes {segundos} segundos.")
    print("  Prueba el del logo de la marca y el de cambio de modo.")
    print("=" * 62)
    print()

    ficheros = {}
    for ruta, nombre in disp:
        try:
            ficheros[os.open(ruta, os.O_RDONLY | os.O_NONBLOCK)] = (ruta, nombre)
        except OSError as err:
            print(f"  (no se pudo abrir {ruta}: {err})")

    if not ficheros:
        raise SystemExit(1)

    vistos: set[tuple[str, int]] = set()
    # Por dispositivo: el MSC_SCAN de uno no es el scancode de la tecla de otro.
    ultimo_scan: dict[int, int] = {}
    fin = time.monotonic() + segundos

    try:
        while time.monotonic() < fin:
            listos, _, _ = select.select(list(ficheros), [], [], 0.5)
            for fd in listos:
                ruta, nombre = ficheros[fd]
                try:
                    datos = os.read(fd, TAM * 64)
                except OSError:
                    continue
                for i in range(0, len(datos) - TAM + 1, TAM):
                    _, _, tipo, codigo, valor = struct.unpack(
                        FORMATO, datos[i : i + TAM]
                    )
                    if tipo == EV_MSC and codigo == MSC_SCAN:
                        ultimo_scan[fd] = valor
                    elif tipo == EV_KEY and valor == 1:  # 1 = pulsacion
                        clave = (nombre, codigo)
                        if clave in vistos:
                            continue
                        vistos.add(clave)
                        ev_nombre, x11 = NOMBRES.get(
                            codigo, (f"codigo {codigo}", SIN_NOMBRE)
                        )
                        scan = ultimo_scan.get(fd)
                        print(f"  ┌─ {nombre}")
                        print(f"  │  codigo evdev : {codigo}  ({ev_nombre})")
                        if scan is not None:
                            print(f"  │  scancode     : 0x{scan:02x}")
                        print(f"  │  nombre XKB   : {x11}")
                        if x11 != SIN_NOMBRE:
                            print(f"  └─ para un atajo (GNOME o Hyprland):  {x11}")
                        else:
                            print("  └─ sin nombre XKB: ningun atajo del escritorio la vera")
                        if nombre == TECLADO_INTERNO and codigo in F13_A_F24 and scan is not None:
                            pista_nombre_equivocado(ruta, codigo, scan)
                        print()
    finally:
        for fd in ficheros:
            os.close(fd)

    if not vistos:
        print("No se detecto ninguna pulsacion.")
        print()
        print("Puede significar dos cosas:")
        print("  a) El boton no genera evento de entrada: algunos botones de")
        print("     marca los gestiona el firmware y solo emiten un evento WMI")
        print("     que el driver no traduce a tecla. En ese caso hay que")
        print("     escucharlo por otra via (acpi_listen o el netlink de acpi).")
        print("  b) El evento va a un dispositivo que no estamos escuchando.")
        print("     Prueba con:  sudo evtest   (paquete extra/evtest)")
    else:
        print(f"Detectadas {len(vistos)} tecla(s) distintas.")


if __name__ == "__main__":
    main()
