"""Preferencias del usuario en un JSON.

Se elige JSON sobre GSettings a proposito: un esquema GSettings hay que
compilarlo e INSTALARLO en /usr/share/glib-2.0/schemas para que la app arranque,
lo que impide probarla sin instalar.  Un JSON en GLib.get_user_config_dir()
funciona desde el primer momento, tanto instalada como ejecutada desde el
repositorio.  Son dos claves: no merece un esquema.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from gi.repository import GLib

#: Fichero: ~/.config/nitro-gekko/ajustes.json
NOMBRE_APP = "nitro-gekko"
FICHERO = "ajustes.json"

#: Valores por defecto.  Cualquier clave ausente en disco cae aqui.
#:
#: El TIPO de cada valor por defecto es tambien el tipo permitido: un fichero
#: editado a mano con {"pl1_vatios": "muchos"} se descarta clave a clave en vez
#: de colarse hasta la interfaz.  Antes no se comprobaba y el valor entraba tal
#: cual.
POR_DEFECTO: dict = {
    # Reescribir PL1 (MSR y MMIO) despues de cambiar de perfil, porque el
    # firmware pisa el MMIO en cada cambio (gotcha 4).
    "reaplicar_pl1": False,
    # Ultimo PL1 aplicado con exito, en vatios.  Se guarda como registro de lo
    # que el usuario eligio; la app NO lo impone al arrancar (el limite que
    # manda lo dice el MSR, y es de ahi de donde se rellena el selector), asi
    # que hoy solo se lee abriendo el fichero.
    "pl1_vatios": 45,
}

#: Tipo aceptado por clave, deducido del valor por defecto.  bool va antes que
#: int a proposito: en Python bool es subclase de int y un True colandose en
#: pl1_vatios seria un PL1 de 1 W.
TIPOS: dict = {
    "reaplicar_pl1": bool,
    "pl1_vatios": int,
}


def _valido(clave: str, valor) -> bool:
    """¿Es *valor* del tipo que espera *clave*?  bool e int no se mezclan."""
    esperado = TIPOS.get(clave)
    if esperado is None:
        return False
    if esperado is bool:
        return isinstance(valor, bool)
    if esperado is int:
        # isinstance(True, int) es cierto en Python: hay que excluir bool.
        return isinstance(valor, int) and not isinstance(valor, bool)
    return isinstance(valor, esperado)


class Ajustes:
    """Carga/guarda perezosa y tolerante a fallos."""

    def __init__(self) -> None:
        self._ruta = Path(GLib.get_user_config_dir()) / NOMBRE_APP / FICHERO
        self._datos = dict(POR_DEFECTO)
        self._cargar()

    def _cargar(self) -> None:
        try:
            with open(self._ruta, "r", encoding="utf-8") as fh:
                disco = json.load(fh)
            if isinstance(disco, dict):
                # Solo claves conocidas Y del tipo correcto: un JSON manipulado
                # (o simplemente editado a mano) no mete basura en la interfaz.
                for clave in POR_DEFECTO:
                    if clave in disco and _valido(clave, disco[clave]):
                        self._datos[clave] = disco[clave]
        except (OSError, ValueError):
            # No hay fichero todavia, o esta corrupto: se usan los defectos.
            pass

    def guardar(self) -> bool:
        """Escritura atomica: fichero temporal + rename, para no dejar restos."""
        try:
            self._ruta.parent.mkdir(parents=True, exist_ok=True)
            temporal = self._ruta.with_suffix(".tmp")
            with open(temporal, "w", encoding="utf-8") as fh:
                json.dump(self._datos, fh, indent=2, ensure_ascii=False)
            os.replace(temporal, self._ruta)
            return True
        except OSError:
            return False

    # Acceso por atributo con validacion minima.
    def obtener(self, clave: str):
        return self._datos.get(clave, POR_DEFECTO.get(clave))

    def fijar(self, clave: str, valor) -> None:
        if not _valido(clave, valor):
            return
        if self._datos.get(clave) == valor:
            return
        self._datos[clave] = valor
        self.guardar()

    @property
    def ruta(self) -> Path:
        return self._ruta
