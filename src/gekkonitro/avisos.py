"""Aviso en pantalla al cambiar de modo, para escritorios sin la extension.

En GNOME lo hace la extension: vigila platform_profile y, cuando el modo cambia
desde fuera -la tecla de modo, la aplicacion, el cambio de cargador a
bateria-, lo ensena en el OSD de GNOME Shell, como la ventana de NitroSense al
pulsar su tecla.  Fuera de GNOME no hay extension, y la tecla de modo cambiaba
el modo sin decir a cual (Hyprland 0.56.2 con Caelestia, 2026-10-28).

Esto hace lo mismo con una notificacion corriente (org.freedesktop.Notifications),
que entiende cualquier escritorio con servidor de notificaciones: Caelestia,
mako, dunst, swaync...  Se lanza al entrar en la sesion:

    nitro-gekko --avisos

En GNOME no hace falta: saldrian dos avisos por cada cambio.

No carga GTK.  Es un proceso que vive toda la sesion, y GTK4 con libadwaita le
sumaria 25 MB por nada (33 MB con Gio solo, 58 MB con GTK4 y Adw, medido en
este equipo).  Por eso __main__ lo despacha antes de importarlos.
"""

from __future__ import annotations

import sys

from gi.repository import Gio, GLib

from . import APP_ID, NOMBRE
from .sysfs import ETIQUETAS_PERFIL, PERFIL_LEGACY, leer_perfil_confirmado

#: Id propio para que GApplication garantice UNA sola copia: una segunda
#: 'nitro-gekko --avisos' se registra en el bus, ve que ya hay otra y sale sin
#: hacer nada.  Sin esto, cada vez que alguien la lanzara dos veces saldrian
#: dos avisos por cambio.
ID_AVISOS = APP_ID + ".Avisos"

#: Iconos por perfil: los mismos que PRESENTACION_PERFILES de
#: extension/extension.js.  Estan en Adwaita, asi que los encuentra cualquier
#: tema de iconos que herede de el.
ICONOS_PERFIL = {
    "low-power": "power-profile-power-saver-symbolic",
    "quiet": "power-profile-power-saver-symbolic",
    "balanced": "power-profile-balanced-symbolic",
    "balanced-performance": "power-profile-performance-symbolic",
    "performance": "power-profile-performance-symbolic",
}

#: Cuanto se queda el aviso en pantalla.  Es de paso, como el OSD de GNOME.
DURACION_MS = 2500

#: Espera antes de releer.  El vigilante avisa DOS veces por cambio (CHANGED y
#: CHANGES_DONE_HINT, lo mismo que ve la extension); con esta espera las dos se
#: quedan en una sola relectura.
MS_AGRUPAR = 150


class Avisos(Gio.Application):
    def __init__(self) -> None:
        super().__init__(
            application_id=ID_AVISOS,
            flags=Gio.ApplicationFlags.DEFAULT_FLAGS,
        )
        self._perfil: str | None = None
        self._vigilante: Gio.FileMonitor | None = None
        self._pendiente = 0
        #: Id de la notificacion anterior.  Se pasa como replaces_id para que un
        #: cambio nuevo SUSTITUYA al aviso que siga en pantalla en vez de
        #: apilarse debajo, que es lo que haria pulsar la tecla de modo cuatro
        #: veces seguidas.
        self._id_aviso = 0

    def do_startup(self) -> None:  # noqa: N802 (nombre impuesto por GObject)
        Gio.Application.do_startup(self)
        # La primera lectura no es un cambio: no avisa.
        self._perfil = leer_perfil_confirmado()
        self._vigilante = Gio.File.new_for_path(str(PERFIL_LEGACY)).monitor_file(
            Gio.FileMonitorFlags.NONE, None
        )
        self._vigilante.connect("changed", self._al_cambiar)
        # Sin ventana, GApplication saldria nada mas arrancar.
        self.hold()

    def do_activate(self) -> None:  # noqa: N802
        # Una segunda copia llega aqui como 'activate' remoto: ya esta todo
        # montado, no hay nada que hacer.
        pass

    def _al_cambiar(self, *_args) -> None:
        if not self._pendiente:
            self._pendiente = GLib.timeout_add(MS_AGRUPAR, self._releer)

    def _releer(self) -> bool:
        self._pendiente = 0
        perfil = leer_perfil_confirmado()
        # Sin dos lecturas de acuerdo no se anuncia nada: el vigilante volvera
        # a avisar en el siguiente cambio.
        if perfil is not None and perfil != self._perfil:
            anterior, self._perfil = self._perfil, perfil
            if anterior is not None:
                self._avisar(perfil)
        return GLib.SOURCE_REMOVE

    def _avisar(self, perfil: str) -> None:
        nombre = ETIQUETAS_PERFIL.get(perfil, perfil)
        pistas = {
            # Que no se quede en el historial de notificaciones: es un aviso de
            # paso, no algo que haya que leer despues.
            "transient": GLib.Variant("b", True),
            "urgency": GLib.Variant("y", 0),
            "desktop-entry": GLib.Variant("s", APP_ID),
            # Los servidores que la entienden lo tratan como un OSD y lo
            # sustituyen en sitio en vez de animarlo como notificacion nueva.
            "x-canonical-private-synchronous": GLib.Variant("s", "nitro-gekko-modo"),
        }
        parametros = GLib.Variant(
            "(susssasa{sv}i)",
            (
                NOMBRE,
                self._id_aviso,
                ICONOS_PERFIL.get(perfil, APP_ID),
                f"Modo {nombre}",
                "",
                [],
                pistas,
                DURACION_MS,
            ),
        )
        try:
            respuesta = self.get_dbus_connection().call_sync(
                "org.freedesktop.Notifications",
                "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications",
                "Notify",
                parametros,
                GLib.VariantType("(u)"),
                Gio.DBusCallFlags.NONE,
                2000,
                None,
            )
            self._id_aviso = respuesta.unpack()[0]
        except GLib.Error as error:
            # Sin servidor de notificaciones el aviso se pierde, pero el
            # proceso sigue: puede que el servidor arranque despues.
            print(f"nitro-gekko --avisos: no se pudo avisar: {error.message}", file=sys.stderr)


def main() -> int:
    if not PERFIL_LEGACY.exists():
        print(
            f"nitro-gekko --avisos: no existe {PERFIL_LEGACY}.  Sin driver de "
            "plataforma no hay modo que vigilar; mira  "
            "./packaging/preparar-sistema.sh --revisar",
            file=sys.stderr,
        )
        return 1
    # Sin '--avisos': GApplication parsea su propia linea de ordenes y la
    # rechazaria como opcion desconocida.
    return Avisos().run([sys.argv[0]])
