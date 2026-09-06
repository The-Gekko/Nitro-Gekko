"""Preferencias del usuario en un JSON.

Se elige JSON sobre GSettings a proposito: un esquema GSettings hay que
compilarlo e INSTALARLO en /usr/share/glib-2.0/schemas para que la app arranque,
lo que impide probarla sin instalar.  Un JSON en GLib.get_user_config_dir()
funciona desde el primer momento, tanto instalada como ejecutada desde el
repositorio.  Son cuatro claves: no merece un esquema.
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
POR_DEFECTO: dict = {
    # Reescribir PL1 (MSR y MMIO) despues de cambiar de perfil, porque el
    # firmware pisa el MMIO en cada cambio (gotcha 4).
    "reaplicar_pl1": False,
    # Ultimo PL1 elegido por el usuario, en vatios.
    "pl1_vatios": 45,
    # RESERVADA, todavia sin efecto: la ventana no la aplica al arrancar ni
    # ofrece manera de fijarla. Se persiste para no romper el fichero de quien
    # ya la tenga escrita, pero hoy no cambia el comportamiento de la app.
    "perfil_por_defecto": None,
}


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
                # Solo claves conocidas: un JSON manipulado no mete basura.
                for clave in POR_DEFECTO:
                    if clave in disco:
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
        if clave not in POR_DEFECTO:
            return
        if self._datos.get(clave) == valor:
            return
        self._datos[clave] = valor
        self.guardar()

    @property
    def ruta(self) -> Path:
        return self._ruta
