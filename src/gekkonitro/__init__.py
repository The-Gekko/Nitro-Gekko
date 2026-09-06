"""Nitro Gekko — panel de control del Acer Nitro AN17-51 para GNOME.

Modulos:
    sysfs    capa de hardware, sin GTK, probable sin sesion grafica
    ajustes  preferencias del usuario en JSON
    grafica  grafica de RPM con cairo
    window   ventana principal
"""

APP_ID = "org.thegekko.nitrogekko"
NOMBRE = "Nitro Gekko"
VERSION = "1.0.0"

__all__ = ["APP_ID", "NOMBRE", "VERSION"]
