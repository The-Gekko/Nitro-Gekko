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

Tambien vigila la calibracion de la bateria, que dura unas siete horas y suele
dejarse de noche con la ventana cerrada.  Avisa si se desconecta el cargador y
cuando termina, porque el firmware NO la cierra solo y hay que pulsar Detener
(medido el 2026-10-29: seguia en marcha 1 h 20 min despues de acabar).  Solo
mira cuando hay una apuntada en el estado de calibracion.py: el resto del
tiempo no toca el firmware.

No carga GTK.  Es un proceso que vive toda la sesion, y GTK4 con libadwaita le
sumaria 25 MB por nada (33 MB con Gio solo, 58 MB con GTK4 y Adw, medido en
este equipo).  Por eso __main__ lo despacha antes de importarlos.
"""

from __future__ import annotations

import sys
import time
import traceback

from gi.repository import Gio, GLib

from . import APP_ID, NOMBRE, calibracion
from .sysfs import (
    ETIQUETAS_PERFIL,
    PERFIL_LEGACY,
    ControlNitro,
    detalle_bateria,
    en_corriente,
    leer_perfil_confirmado,
)

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

#: Cada cuanto se mira la calibracion.  Solo cuesta algo si hay una apuntada:
#: entonces battery_calibration es WMI de verdad (10 ms), una vez por minuto.
#: Sin ninguna, es leer un JSON pequeno o ver que no existe.
S_CALIBRACION = 60
ICONO_CALIBRACION = "battery-caution-symbolic"


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
        #: Avisos de la calibracion ya dados que no se pudieron apuntar en el
        #: fichero de estado.  Solo se usa si guardar falla.
        self._avisados_sin_guardar: set[str] = set()

    def do_startup(self) -> None:  # noqa: N802 (nombre impuesto por GObject)
        Gio.Application.do_startup(self)
        # La primera lectura no es un cambio: no avisa.
        self._perfil = leer_perfil_confirmado()
        self._vigilante = Gio.File.new_for_path(str(PERFIL_LEGACY)).monitor_file(
            Gio.FileMonitorFlags.NONE, None
        )
        self._vigilante.connect("changed", self._al_cambiar)
        GLib.timeout_add_seconds(S_CALIBRACION, self._mirar_calibracion)
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
        self._id_aviso = self._enviar(
            f"Modo {nombre}", "", ICONOS_PERFIL.get(perfil, APP_ID),
            pistas, DURACION_MS, self._id_aviso,
        )

    def _mirar_calibracion(self) -> bool:
        """Apunta en que va la calibracion y avisa de lo que haga falta.

        Las mismas cuentas que la ventana (calibracion.py), y sobre el mismo
        fichero de estado: lo que apunte aqui con la ventana cerrada -como el
        momento en que empezo la descarga- lo aprovecha ella al abrirse.

        Nada puede escapar de aqui: una excepcion daria de baja el
        temporizador, y la vigilancia de toda la noche moriria sin decir nada.
        """
        try:
            self._mirar_calibracion_ahora()
        except Exception:  # noqa: BLE001 - ver el docstring
            traceback.print_exc()
        return GLib.SOURCE_CONTINUE

    def _mirar_calibracion_ahora(self) -> None:
        if calibracion.cargar().en_curso is None:
            return
        lectura = calibracion.lectura_de(
            detalle_bateria(),
            calibrando=ControlNitro.leer_calibracion(),
            en_corriente=en_corriente(),
            momento=time.time(),
        )
        mensajes: list[str] = []

        def cambio(estado: calibracion.Estado) -> calibracion.Estado:
            # avanzar_existente: esta lectura se hizo antes de coger el
            # fichero, y no puede reabrir una calibracion que la ventana acabe
            # de cerrar con Detener.
            nuevo, avisos = calibracion.notificaciones(
                calibracion.avanzar_existente(estado, lectura), lectura)
            mensajes[:] = avisos
            return nuevo

        _, guardado = calibracion.actualizar(cambio)
        if not guardado:
            # Sin poder apuntar lo avisado en el fichero (disco lleno, sin
            # permiso), se recuerda aqui: si no, se repetiria cada minuto.
            mensajes[:] = [m for m in mensajes if m not in self._avisados_sin_guardar]
            self._avisados_sin_guardar.update(mensajes)
        pistas = {
            # Estos SI se quedan en el historial: son para leerlos al volver.
            "urgency": GLib.Variant("y", 1),
            "desktop-entry": GLib.Variant("s", APP_ID),
        }
        for mensaje in mensajes:
            self._enviar("Calibracion de la bateria", mensaje, ICONO_CALIBRACION, pistas, -1, 0)

    def _enviar(self, resumen: str, cuerpo: str, icono: str, pistas: dict,
                duracion_ms: int, reemplaza: int) -> int:
        """Una notificacion por org.freedesktop.Notifications.  Devuelve su id,
        o *reemplaza* si no se pudo mandar."""
        parametros = GLib.Variant(
            "(susssasa{sv}i)",
            (NOMBRE, reemplaza, icono, resumen, cuerpo, [], pistas, duracion_ms),
        )
        conexion = self.get_dbus_connection()
        if conexion is None:
            print("nitro-gekko --avisos: sin bus de sesion, no se puede avisar", file=sys.stderr)
            return reemplaza
        try:
            respuesta = conexion.call_sync(
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
            return respuesta.unpack()[0]
        except GLib.Error as error:
            # Sin servidor de notificaciones el aviso se pierde, pero el
            # proceso sigue: puede que el servidor arranque despues.
            print(f"nitro-gekko --avisos: no se pudo avisar: {error.message}", file=sys.stderr)
            return reemplaza


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
