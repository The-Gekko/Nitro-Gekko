#!/usr/bin/env python3
"""Genera los presets de EasyEffects de Nitro Gekko.

POR QUE UN GENERADOR Y NO TRES JSON A MANO
-------------------------------------------
Un preset de EasyEffects 8 son ~22 KB de JSON con 15 bandas de ecualizador por
canal y ocho bandas de compresor multibanda.  Editar eso a mano es como se
cuelan los errores, y ademas el fichero no explica POR QUE cada banda vale lo
que vale.  Aqui la curva se escribe en una tabla legible y el resto de las
claves se copian de una PLANTILLA REAL, que es lo que garantiza que EasyEffects
las acepte: si se inventa una clave, el programa la ignora en silencio.

LA PLANTILLA
------------
Se usa un preset existente del usuario como esqueleto de claves (por omision
~/.local/share/easyeffects/output/Sony Ultra.json, y si no esta, cualquiera de
ese directorio).  De el se copia la ESTRUCTURA; todos los valores que importan
se sobrescriben aqui.  Asi el resultado es valido para la version de
EasyEffects que tenga instalada esta maquina, sin cablear un esquema que cambia
entre versiones mayores.

    python3 extras/audio/generar-presets.py            # escribe en extras/audio/
    python3 extras/audio/generar-presets.py --instalar # y los copia a EasyEffects

AVISO HONESTO
-------------
Estas curvas NO estan medidas.  Todo lo demas que afirma este proyecto viene de
una medicion (RPM, vatios, milisegundos); esto no: no hay aqui microfono de
medicion ni forma de sacar la respuesta en frecuencia de los altavoces.  Son un
punto de partida razonado para un portatil de dos altavoces pequenos y sin
subwoofer, y se espera que cada uno los retoque.
"""

from __future__ import annotations

import argparse
import copy
import json
import shutil
import sys
from pathlib import Path

#: Las 15 frecuencias que usa el ecualizador de EasyEffects en su reparto por
#: defecto.  Se leen de la plantilla y se comprueban contra esta lista: si la
#: plantilla trae otro reparto, las curvas de abajo no significarian lo mismo.
FRECUENCIAS = (50, 100, 156, 220, 311, 440, 622, 880,
               1250, 1750, 2500, 3500, 5000, 10000, 20000)

DIR_PRESETS = Path.home() / ".local/share/easyeffects/output"

# ---------------------------------------------------------------------------
#  Las tres curvas
#
#  Una ganancia por cada frecuencia de FRECUENCIAS, en dB.  El criterio, para
#  un portatil de dos altavoces pequenos montados hacia arriba y sin subwoofer:
#
#   - Por debajo de 100 Hz el altavoz no da nada: subirlo solo distorsiona.  El
#     grave se sugiere con bass_enhancer (armonicos), que es el mismo truco
#     psicoacustico que usan los DSP comerciales, no subiendo la banda.
#   - Entre 220 y 440 Hz esta la caja: bajarlo quita el sonido a lata.
#   - Entre 2,5 y 5 kHz esta la voz y el detalle, pero tambien la estridencia;
#     se sube con cuidado y no se sube 6,3 kHz a la vez.
#   - Por encima de 10 kHz se abre el aire, que es lo que hace que suene
#     "grande" un altavoz pequeno.
# ---------------------------------------------------------------------------
PERFILES = {
    "Nitro Gekko - Musica": {
        "descripcion": "Equilibrado. Nada llama la atencion, que es la gracia.",
        "eq":      (1.0, 3.0, 2.0, -1.5, -2.5, -1.0, -0.5, 0.0,
                    0.5, 1.0, 2.0, 2.0, 2.5, 3.0, 1.5),
        "grave":   {"amount": 5.0, "harmonics": 7.0, "scope": 100.0, "blend": 1.0},
        "ancho":   None,          # sin ensanchado: en musica se nota y molesta
        "compresor": "suave",
        "techo":   -1.5,
    },
    "Nitro Gekko - Pelicula": {
        "descripcion": "Dialogo por delante y golpes contenidos.",
        "eq":      (0.5, 2.5, 1.5, -2.0, -3.0, -1.5, -0.5, 0.5,
                    1.5, 2.5, 3.0, 2.5, 2.0, 2.5, 1.0),
        "grave":   {"amount": 4.0, "harmonics": 6.0, "scope": 90.0, "blend": 0.0},
        "ancho":   0.35,
        "compresor": "fuerte",    # que no haya que subir el volumen en los susurros
        "techo":   -1.0,
    },
    "Nitro Gekko - Juego": {
        "descripcion": "Pasos y direccion. Escenario ancho y agudo presente.",
        "eq":      (1.0, 2.5, 1.0, -2.0, -3.0, -2.0, -1.0, 0.0,
                    1.0, 2.0, 3.0, 3.5, 3.5, 3.0, 1.5),
        "grave":   {"amount": 6.0, "harmonics": 8.0, "scope": 110.0, "blend": 1.0},
        "ancho":   0.55,
        "compresor": "medio",
        "techo":   -1.0,
    },
}

#: Cuanto aprieta el compresor multibanda en cada perfil.  (ratio, makeup dB)
COMPRESOR = {"suave": (1.6, 1.5), "medio": (2.0, 2.5), "fuerte": (2.6, 3.5)}

#: Esquema de stereo_tools tal como lo escribe EasyEffects 8.2.9.
#:
#: NO esta inventado: es el bloque literal de un preset real de esta maquina
#: (~/.local/share/easyeffects/input/*.json), con los valores puestos a neutro.
#: Hace falta porque la plantilla de SALIDA puede no traer este modulo -- solo
#: aparece en un preset si el usuario lo llego a anadir a la cadena--, y sin el
#: los perfiles de pelicula y de juego se quedaban sin ensanchado y sin decirlo.
STEREO_TOOLS_NEUTRO = {
    "balance-in": 0.0, "balance-out": 0.0, "bypass": True, "delay": 0.0,
    "dry": -100.0, "input-gain": 0.0, "middle-level": 0.0, "middle-panorama": 0.0,
    "mode": "LR > LR (Stereo Default)", "mutel": False, "muter": False,
    "output-gain": 0.0, "phasel": False, "phaser": False, "sc-level": 1.0,
    "side-balance": 0.0, "side-level": 0.0, "softclip": False,
    "stereo-base": 0.0, "stereo-phase": 0.0, "wet": 0.0,
}


def plantilla(ruta: Path | None) -> dict:
    """Devuelve el esqueleto de claves de un preset de salida existente."""
    if ruta is None:
        preferido = DIR_PRESETS / "Sony Ultra.json"
        candidatos = [preferido] if preferido.is_file() else sorted(DIR_PRESETS.glob("*.json"))
        candidatos = [c for c in candidatos if not c.name.startswith("Nitro Gekko")]
        if not candidatos:
            sys.exit(
                "No hay ningun preset de salida de EasyEffects del que copiar la\n"
                "estructura. Abre EasyEffects, guarda un preset cualquiera en\n"
                f"{DIR_PRESETS} y vuelve a ejecutar esto, o pasa uno con --plantilla."
            )
        ruta = candidatos[0]
    datos = json.loads(ruta.read_text(encoding="utf-8"))
    if "output" not in datos:
        sys.exit(f"{ruta} no es un preset de SALIDA (no tiene la clave 'output').")
    return datos["output"]


def construir(base: dict, perfil: dict) -> dict:
    o = copy.deepcopy(base)

    # -- cadena de efectos ---------------------------------------------------
    # Solo se usan modulos que ya aparecen en la plantilla: anadir uno cuyo
    # esquema no conocemos es como se acaba con un preset que EasyEffects
    # carga a medias y sin decir nada.
    orden = ["equalizer#0", "bass_enhancer#0", "multiband_compressor#0", "maximizer#0"]
    if perfil["ancho"] is not None:
        o.setdefault("stereo_tools#0", copy.deepcopy(STEREO_TOOLS_NEUTRO))
        orden.insert(2, "stereo_tools#0")
    o["plugins_order"] = [p for p in orden if p in o]

    # -- ecualizador ---------------------------------------------------------
    eq = o["equalizer#0"]
    eq["bypass"] = False
    eq["mode"] = "IIR"
    eq["split-channels"] = False
    # Margen de sobra antes del limitador: con las bandas subidas y sin bajar la
    # entrada, el maximizador trabaja todo el rato y el sonido se aplana.
    eq["input-gain"] = -6.0
    eq["output-gain"] = 0.0
    for lado in ("left", "right"):
        bandas = eq[lado]
        for i, (frec, ganancia) in enumerate(zip(FRECUENCIAS, perfil["eq"])):
            b = bandas[f"band{i}"]
            b["frequency"] = float(frec)
            b["gain"] = float(ganancia)
            b["type"] = "Bell"
            b["mute"] = False
            b["solo"] = False

    # -- grave por armonicos -------------------------------------------------
    be = o["bass_enhancer#0"]
    be["bypass"] = False
    be.update(perfil["grave"])
    be["floor-active"] = True
    be["floor"] = 20.0

    # -- ensanchado del escenario -------------------------------------------
    if "stereo_tools#0" in o:
        st = o["stereo_tools#0"]
        if perfil["ancho"] is None:
            st["bypass"] = True
        else:
            st["bypass"] = False
            st["mode"] = "LR > LR (Stereo Default)"
            st["stereo-base"] = float(perfil["ancho"])
            st["softclip"] = False

    # -- compresor multibanda ------------------------------------------------
    ratio, makeup = COMPRESOR[perfil["compresor"]]
    mb = o["multiband_compressor#0"]
    mb["bypass"] = False
    for i in range(8):
        clave = f"band{i}"
        if clave not in mb:
            continue
        banda = mb[clave]
        if not isinstance(banda, dict):
            continue
        banda["compressor-enable"] = True
        banda["compression-mode"] = "Downward"
        banda["ratio"] = float(ratio)
        banda["makeup"] = float(makeup)
        banda["attack-threshold"] = -20.0

    # -- techo ---------------------------------------------------------------
    mx = o["maximizer#0"]
    mx["bypass"] = False
    mx["threshold"] = float(perfil["techo"])
    mx["release"] = 100.0

    # bass_loudness se queda como esta y en bypass: compensa el volumen bajo y
    # se pisa con lo que hace el ecualizador.
    if "bass_loudness#0" in o:
        o["bass_loudness#0"]["bypass"] = True

    return {"output": o}


def main() -> int:
    p = argparse.ArgumentParser(description="Genera los presets de EasyEffects de Nitro Gekko.")
    p.add_argument("--plantilla", type=Path, default=None,
                   help="preset de salida del que copiar la estructura de claves")
    p.add_argument("--salida", type=Path, default=Path(__file__).resolve().parent,
                   help="donde escribir los .json (por omision, junto a este script)")
    p.add_argument("--instalar", action="store_true",
                   help="copiarlos ademas a ~/.local/share/easyeffects/output/")
    args = p.parse_args()

    base = plantilla(args.plantilla)
    frec_plantilla = tuple(int(base["equalizer#0"]["left"][f"band{i}"]["frequency"])
                           for i in range(min(15, int(base["equalizer#0"].get("num-bands", 15)))))
    if len(frec_plantilla) != len(FRECUENCIAS):
        print(f"AVISO: la plantilla trae {len(frec_plantilla)} bandas y las curvas de este\n"
              f"       script estan escritas para {len(FRECUENCIAS)}. Se ajusta lo que cabe.")

    args.salida.mkdir(parents=True, exist_ok=True)
    for nombre, perfil in PERFILES.items():
        destino = args.salida / f"{nombre}.json"
        destino.write_text(json.dumps(construir(base, perfil), indent=4, ensure_ascii=False) + "\n",
                           encoding="utf-8")
        print(f"  escrito  {destino}   ({perfil['descripcion']})")
        if args.instalar:
            DIR_PRESETS.mkdir(parents=True, exist_ok=True)
            shutil.copy2(destino, DIR_PRESETS / destino.name)
            print(f"  copiado  {DIR_PRESETS / destino.name}")

    if not args.instalar:
        print(f"\nPara instalarlos:  cp extras/audio/'Nitro Gekko - '*.json {DIR_PRESETS}/")
        print("Y luego elegirlos en EasyEffects, en Presets.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
