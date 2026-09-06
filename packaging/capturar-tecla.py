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
en Windows abre NitroSense- emite KEY_PRESENTATION, que en GNOME se llama
XF86Presentation.  Ese atajo lo asigna solo packaging/preparar-sistema.sh; este
script sirve para averiguarlo en un modelo distinto.
"""

from __future__ import annotations

import os
import re
import select
import struct
import sys
import time

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
# equivocado para meter en GNOME.  Ahora los dos nombres salen de los ficheros
# del propio sistema, que son la fuente de verdad:
#
#   /usr/include/linux/input-event-codes.h  ->  KEY_*      (linux-api-headers,
#                                                dependencia de glibc)
#   /usr/share/X11/xkb/symbols/inet         ->  XF86*      (xkeyboard-config)
#
# En el segundo, el codigo XKB es el de evdev + 8 y se escribe en hexadecimal
# como <I1A9>.  Comprobado:
#   evdev 425 -> <I433> -> XF86Presentation   (el boton del logo del AN17-51)
# --------------------------------------------------------------------------

CABECERA_EVDEV = "/usr/include/linux/input-event-codes.h"
SIMBOLOS_XKB = "/usr/share/X11/xkb/symbols/inet"

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
    clave = re.compile(r"^\s*key\s+<I(\d+)>\s*\{\s*\[\s*(\S+)\s*\]")
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
                if m:
                    # El keycode de XKB es el de evdev mas 8.
                    tabla[int(m.group(1), 10) - 8] = m.group(2)
    except OSError:
        pass
    return tabla


def construir_nombres() -> dict[int, tuple[str, str]]:
    evdev = _nombres_evdev()
    x11 = _nombres_x11()
    if not evdev and not x11:
        return dict(NOMBRES_MINIMOS)
    codigos = set(evdev) | set(x11)
    return {
        c: (evdev.get(c, f"codigo {c}"), x11.get(c, "sin nombre X11"))
        for c in codigos
    }


NOMBRES = construir_nombres()


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
    ultimo_scan: int | None = None
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
                        ultimo_scan = valor
                    elif tipo == EV_KEY and valor == 1:  # 1 = pulsacion
                        clave = (nombre, codigo)
                        if clave in vistos:
                            continue
                        vistos.add(clave)
                        ev_nombre, x11 = NOMBRES.get(
                            codigo, (f"codigo {codigo}", "sin nombre X11")
                        )
                        print(f"  ┌─ {nombre}")
                        print(f"  │  codigo evdev : {codigo}  ({ev_nombre})")
                        if ultimo_scan is not None:
                            print(f"  │  scancode     : 0x{ultimo_scan:02x}")
                        print(f"  │  nombre X11   : {x11}")
                        if x11.startswith("XF86") or x11 == "Print":
                            print(f"  └─ para el atajo de GNOME usa:  {x11}")
                        else:
                            print("  └─ esta tecla no tiene nombre XKB: capturala")
                            print("     en Configuracion > Teclado > Atajos")
                            print("     personalizados, pulsandola en el dialogo.")
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
