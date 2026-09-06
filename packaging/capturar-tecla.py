#!/usr/bin/env python3
"""Captura que tecla emite un boton del portatil.

Sirve para averiguar el codigo del boton con el logo de la marca (el que en
Windows abre NitroSense) y del boton de cambio de modo, para poder asignarlos
a Nitro Gekko.

No necesita root ni ninguna libreria externa: lee /dev/input/eventN en crudo y
decodifica la estructura input_event a mano.  El usuario ya pertenece al grupo
'input', que es quien puede leer esos dispositivos.

    ./capturar-tecla.py            # escucha en todos los dispositivos Acer
    ./capturar-tecla.py 20         # escucha 20 segundos
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

#: Nombres de las teclas que mas probablemente emita un boton de marca.
#: (codigo evdev -> nombre X11/Wayland con el que se configura el atajo)
NOMBRES = {
    148: ("KEY_PROG1", "XF86Launch1"),
    149: ("KEY_PROG2", "XF86Launch2"),
    202: ("KEY_PROG3", "XF86Launch3"),
    203: ("KEY_PROG4", "XF86Launch4"),
    138: ("KEY_HELP", "XF86Support"),
    140: ("KEY_CALC", "XF86Calculator"),
    0x1E4: ("KEY_TOUCHPAD_TOGGLE", "XF86TouchpadToggle"),
    431: ("KEY_ASSISTANT", "XF86Assistant"),
    0x24B: ("KEY_CONTROLPANEL", "XF86ControlPanel"),
}


def dispositivos_acer() -> list[tuple[str, str]]:
    """Devuelve [(ruta, nombre)] de los dispositivos de entrada del portatil."""
    encontrados = []
    try:
        bloques = open("/proc/bus/input/devices").read().split("\n\n")
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


def main() -> None:
    segundos = int(sys.argv[1]) if len(sys.argv) > 1 else 25

    disp = dispositivos_acer()
    if not disp:
        print("No se pudo abrir ningun dispositivo de entrada del portatil.")
        print("Comprueba que perteneces al grupo 'input':  id -nG")
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
                            codigo, (f"codigo {codigo}", "desconocido")
                        )
                        print(f"  ┌─ {nombre}")
                        print(f"  │  codigo evdev : {codigo}  ({ev_nombre})")
                        if ultimo_scan is not None:
                            print(f"  │  scancode     : 0x{ultimo_scan:02x}")
                        print(f"  │  nombre X11   : {x11}")
                        print(f"  └─ para el atajo de GNOME usa:  {x11}")
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
