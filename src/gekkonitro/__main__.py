"""Punto de entrada de Nitro Gekko.

Uso:
    python3 -m gekkonitro
    ./nitro-gekko          (lanzador del repositorio, sin instalar)
"""

from __future__ import annotations

import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from . import APP_ID, NOMBRE, VERSION  # noqa: E402
from .window import VentanaNitro  # noqa: E402


class AplicacionNitro(Adw.Application):
    def __init__(self) -> None:
        super().__init__(
            application_id=APP_ID,
            flags=Gio.ApplicationFlags.DEFAULT_FLAGS,
        )
        self._ventana: VentanaNitro | None = None

        accion = Gio.SimpleAction.new("acerca-de", None)
        accion.connect("activate", self._acerca_de)
        self.add_action(accion)

        accion_salir = Gio.SimpleAction.new("salir", None)
        accion_salir.connect("activate", lambda *_: self.quit())
        self.add_action(accion_salir)
        self.set_accels_for_action("app.salir", ["<Primary>q", "<Primary>w"])

    def do_activate(self) -> None:  # noqa: N802 (nombre impuesto por GObject)
        # Ventana unica: si ya existe, la traemos al frente.
        if self._ventana is None:
            self._ventana = VentanaNitro(self)
        self._ventana.present()

    def _acerca_de(self, *_args) -> None:
        dialogo = Adw.AboutDialog(
            application_name=NOMBRE,
            application_icon=APP_ID,
            version=VERSION,
            developer_name="The Gekko",
            comments=(
                "Panel de control del Acer Nitro AN17-51: perfil termico, "
                "ventiladores, limite de potencia de la CPU y salud de la bateria."
            ),
            license_type=Gtk.License.GPL_3_0,
        )
        dialogo.present(self._ventana)


def main(argv: list[str] | None = None) -> int:
    # El nombre del programa hay que fijarlo ANTES de crear la ventana.
    # Arrancando con 'python3 -m gekkonitro' GLib lo deduce del argv y se queda
    # en "__main__.py": bajo Wayland da igual (GTK manda el application_id como
    # app_id), pero bajo XWayland la ventana salia con
    # WM_CLASS = "__main__.py", que NO casa con el
    # StartupWMClass=org.thegekko.nitrogekko del .desktop.  Resultado: icono
    # generico y entrada duplicada en el Dash.  Comprobado con xprop.
    GLib.set_prgname(APP_ID)
    GLib.set_application_name(NOMBRE)
    return AplicacionNitro().run(argv if argv is not None else sys.argv)


if __name__ == "__main__":
    sys.exit(main())
