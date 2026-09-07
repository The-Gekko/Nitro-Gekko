#!/usr/bin/env python3
"""Ata un preset de EasyEffects a un dispositivo de salida (autocarga).

QUE PROBLEMA RESUELVE

EasyEffects procesa UN dispositivo cada vez.  Si tienes auriculares Bluetooth y
los altavoces del portatil, el preset bueno para unos no vale para los otros, y
sin autocarga hay que cambiarlo a mano cada vez.  Con una regla de autocarga por
dispositivo, EasyEffects carga el preset que le corresponde al enchufar o
conectar.

EL FORMATO NO ESTA DOCUMENTADO, ASI QUE SE VERIFICO EN EL FUENTE

De ``src/presets_autoload_manager.cpp`` de EasyEffects:

    getFilePath()  ->  <directorio>/<device>:<route>.json
                       y en los dos campos las "/" se sustituyen por "_"
    add()          ->  claves: device, device-description, device-profile,
                       preset-name

Y de ``src/stream_output_effects.cpp``, la parte que importa y que es
contraintuitiva:

    autoload(PipelineType::output, node.name, node.device_route_description)

O sea que ``device-profile`` NO es el perfil de la tarjeta ni el nombre del
puerto: es la DESCRIPCION de la ruta.  En un sistema en espanol eso es
literalmente «Auriculares» o «Speaker», segun lo que traduzca PipeWire.  Si
cambias el idioma del escritorio, la regla deja de casar y hay que rehacerla.

OTRO DETALLE QUE CUESTA UNA TARDE

Las tres llamadas a autoload() estan dentro de un
``if (node.name == DbStreamOutputs::outputDevice())``.  Es decir: la autocarga
SOLO se dispara para el dispositivo que EasyEffects tiene configurado como
salida.  Si tienes fijado un dispositivo concreto, no se disparara nunca al
cambiar a otro.  Hay que dejar activado **«usar el dispositivo por defecto»**
(``useDefaultOutputDevice=true`` en ~/.config/easyeffects/db/easyeffectsrc).

USO

    python3 extras/audio/autocarga-easyeffects.py --listar
    python3 extras/audio/autocarga-easyeffects.py --sink <nombre> --preset "<preset>"
    python3 extras/audio/autocarga-easyeffects.py --quitar --sink <nombre>

Los cambios se notan sin reiniciar EasyEffects: la regla se lee del disco cada
vez que cambia el dispositivo.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

AUTOLOAD = Path.home() / ".local/share/easyeffects/autoload/output"
PRESETS = Path.home() / ".local/share/easyeffects/output"
CONFIG = Path.home() / ".config/easyeffects/db/easyeffectsrc"


def salidas() -> list[dict]:
    """Sinks de PipeWire con su descripcion y la DESCRIPCION de su ruta activa.

    Se saca de pactl porque es lo que hay en cualquier instalacion; el nodo de
    EasyEffects se descarta, que no es un dispositivo de verdad.
    """
    if shutil.which("pactl") is None:
        sys.exit("Hace falta pactl (pipewire-pulse o pulseaudio-utils).")
    texto = subprocess.run(["pactl", "list", "sinks"], capture_output=True,
                           text=True, check=False).stdout
    tarjetas = subprocess.run(["pactl", "list", "cards"], capture_output=True,
                              text=True, check=False).stdout

    # puerto -> descripcion, tal como los publica PipeWire
    descripciones: dict[str, str] = {}
    for linea in tarjetas.splitlines():
        m = re.match(r"\s+([\w.\[\] -]+?): (.+?) \(type: ", linea)
        if m:
            descripciones[m.group(1).strip()] = m.group(2).strip()

    fuera = []
    actual: dict = {}
    for linea in texto.splitlines():
        if m := re.match(r"\s*Name: (.+)", linea):
            if actual:
                fuera.append(actual)
            actual = {"device": m.group(1).strip()}
        elif m := re.match(r"\s*Description: (.+)", linea):
            actual["device-description"] = m.group(1).strip()
        elif m := re.match(r"\s*Active Port: (.+)", linea):
            puerto = m.group(1).strip()
            actual["puerto"] = puerto
            actual["device-profile"] = descripciones.get(puerto, puerto)
    if actual:
        fuera.append(actual)
    return [s for s in fuera if not s["device"].startswith("easyeffects")]


def ruta_regla(sink: dict) -> Path:
    # Misma construccion que getFilePath() de EasyEffects, "/" incluidas.
    dev = sink["device"].replace("/", "_")
    ruta = sink["device-profile"].replace("/", "_")
    return AUTOLOAD / f"{dev}:{ruta}.json"


def avisar_del_dispositivo_por_defecto() -> None:
    try:
        texto = CONFIG.read_text(encoding="utf-8")
    except OSError:
        return
    if "useDefaultOutputDevice=true" not in texto:
        print()
        print("  OJO: EasyEffects tiene fijado un dispositivo de salida concreto")
        print("  (useDefaultOutputDevice=false), y con eso la autocarga NO se")
        print("  dispara al cambiar de dispositivo.  Activa «usar el dispositivo")
        print("  por defecto» en la pestana de salida de EasyEffects.")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--listar", action="store_true", help="ensena las salidas y sus reglas")
    p.add_argument("--sink", help="nombre del sink (el de --listar)")
    p.add_argument("--preset", help="nombre del preset, sin .json")
    p.add_argument("--quitar", action="store_true", help="borra la regla de ese sink")
    args = p.parse_args()

    encontradas = salidas()

    if args.listar or not args.sink:
        print("Salidas de audio y su regla de autocarga:\n")
        for s in encontradas:
            regla = ruta_regla(s)
            preset = "-"
            if regla.is_file():
                try:
                    preset = json.loads(regla.read_text(encoding="utf-8")).get("preset-name", "?")
                except (OSError, ValueError):
                    preset = "(fichero ilegible)"
            print(f"  {s['device']}")
            print(f"      descripcion : {s.get('device-description', '?')}")
            print(f"      ruta        : {s.get('device-profile', '?')}   (puerto {s.get('puerto', '?')})")
            print(f"      preset      : {preset}")
            print()
        if PRESETS.is_dir():
            nombres = sorted(f.stem for f in PRESETS.glob("*.json"))
            print("Presets de salida disponibles: " + (", ".join(nombres) or "ninguno"))
        avisar_del_dispositivo_por_defecto()
        return 0

    sink = next((s for s in encontradas if s["device"] == args.sink), None)
    if sink is None:
        sys.exit(f"No hay ninguna salida que se llame {args.sink!r}. Prueba --listar.")

    regla = ruta_regla(sink)
    if args.quitar:
        if regla.is_file():
            regla.unlink()
            print(f"  borrada  {regla.name}")
        else:
            print("  no habia regla para ese dispositivo")
        return 0

    if not args.preset:
        sys.exit("Falta --preset (o usa --quitar).")
    if PRESETS.is_dir() and not (PRESETS / f"{args.preset}.json").is_file():
        sys.exit(f"No existe el preset {args.preset!r} en {PRESETS}.")

    AUTOLOAD.mkdir(parents=True, exist_ok=True)
    regla.write_text(json.dumps({
        "device": sink["device"],
        "device-description": sink.get("device-description", ""),
        "device-profile": sink.get("device-profile", ""),
        "preset-name": args.preset,
    }, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"  escrita  {regla.name}")
    print(f"           {sink.get('device-description', '')} -> {args.preset}")
    avisar_del_dispositivo_por_defecto()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
