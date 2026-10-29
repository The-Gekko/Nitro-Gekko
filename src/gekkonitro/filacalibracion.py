"""La fila de la calibracion de la bateria: boton, fases y cuanto falta.

Solo pinta.  Que fase es y cuanto queda lo decide calibracion.py, que es
Python puro y tiene sus pruebas; aqui no hay ni una cuenta.  Va en su propio
fichero para no seguir engordando window.py.

Plegada, el subtitulo dice lo esencial («Fase 3 de 4 · quedan 2 h 58 min»).
Desplegada, las cuatro fases: las hechas con lo que duraron, la de ahora con
lo que le falta y las que vienen con lo que suelen durar.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gtk  # noqa: E402

from .calibracion import (  # noqa: E402
    EXPLICACIONES,
    FASES,
    NOMBRES,
    Fase,
    Lectura,
    Ultima,
    Vista,
    formatear_duracion,
    formatear_resultado,
)

ICONO_HECHA = "object-select-symbolic"
ICONO_EN_CURSO = "media-playback-start-symbolic"
#: No «radio-symbolic»: en Adwaita es un circulo vacio, pero hay temas que
#: lo pintan como un aparato de radio (visto con Vivid-Glassy-Dark-Icons).
ICONO_PENDIENTE = "content-loading-symbolic"

SUBTITULO_PARADA = "Se recomienda cada 3 meses. Tarda unas 7 horas, con el cargador puesto."


class FilaCalibracion:
    """Envuelve un Adw.ExpanderRow; window.py lo anade con ``.fila``."""

    def __init__(self, al_pulsar: Callable[[Gtk.Button], None]) -> None:
        self.fila = Adw.ExpanderRow(title="Calibracion de la bateria")
        self.fila.set_subtitle_lines(0)
        self.boton = Gtk.Button(valign=Gtk.Align.CENTER)
        self.boton.connect("clicked", al_pulsar)
        self.fila.add_suffix(self.boton)

        self._barra = Gtk.ProgressBar(valign=Gtk.Align.CENTER, hexpand=True, show_text=True)
        self._fila_progreso = Adw.ActionRow(title="Progreso")
        self._fila_progreso.add_suffix(self._barra)
        self.fila.add_row(self._fila_progreso)

        self._fases: dict[Fase, tuple[Adw.ActionRow, Gtk.Image, Gtk.Label]] = {}
        for numero, fase in enumerate(FASES, 1):
            fila = Adw.ActionRow(title=f"{numero}. {NOMBRES[fase]}", subtitle=EXPLICACIONES[fase])
            fila.set_subtitle_lines(0)
            icono = Gtk.Image()
            etiqueta = Gtk.Label()
            etiqueta.add_css_class("numeric")
            etiqueta.add_css_class("dim-label")
            fila.add_prefix(icono)
            fila.add_suffix(etiqueta)
            self.fila.add_row(fila)
            self._fases[fase] = (fila, icono, etiqueta)

    def pintar(self, calibrando: bool | None, vista: Vista | None,
               lectura: Lectura | None, ultima: Ultima | None) -> None:
        if not calibrando:
            self._pintar_parada(calibrando, ultima)
        else:
            self._pintar_en_marcha(vista, lectura)

    # -- sin calibracion ---------------------------------------------------

    def _pintar_parada(self, calibrando: bool | None, ultima: Ultima | None) -> None:
        self.boton.set_label("Calibrar…")
        self.boton.remove_css_class("suggested-action")
        self.fila.set_expanded(False)
        self.fila.set_enable_expansion(False)
        if calibrando is None:
            self.fila.set_subtitle("No se ha podido leer si hay una calibracion en marcha.")
            return
        texto = SUBTITULO_PARADA
        if ultima is not None:
            fecha = datetime.fromtimestamp(ultima.inicio).strftime("%d/%m/%Y")
            # Lo que duro el ciclo, no hasta que alguien pulso Detener: lo que
            # vaya despues es solo espera (anoche, 80 min de los 8 h totales).
            duracion = (sum(s for _, s in ultima.duraciones)
                        if ultima.completa and ultima.duraciones else ultima.fin - ultima.inicio)
            partes = [f"Ultima: {fecha}", formatear_duracion(duracion)]
            resultado = formatear_resultado(ultima)
            if resultado:
                partes.append(resultado)
            if not ultima.completa:
                partes.append("detenida antes de terminar")
            texto += "\n" + " · ".join(partes)
        self.fila.set_subtitle(texto)

    # -- en marcha ------------------------------------------------------------

    def _pintar_en_marcha(self, vista: Vista | None, lectura: Lectura | None) -> None:
        self.boton.set_label("Detener")
        self.fila.set_enable_expansion(True)
        if vista is None or vista.fase is None:
            self.boton.remove_css_class("suggested-action")
            self.fila.set_subtitle("En marcha. No desconectes el cargador hasta que termine.")
            self._fila_progreso.set_visible(False)
            for fila, icono, etiqueta in self._fases.values():
                icono.set_from_icon_name(ICONO_PENDIENTE)
                etiqueta.set_label("")
            return

        terminada = vista.fase is Fase.TERMINADA
        # Al terminar, Detener es LO que hay que hacer: se resalta.
        if terminada:
            self.boton.add_css_class("suggested-action")
        else:
            self.boton.remove_css_class("suggested-action")

        self.fila.set_subtitle(self._subtitulo(vista, lectura))
        self._pintar_progreso(vista)
        self._pintar_fases(vista)

    @staticmethod
    def _subtitulo(vista: Vista, lectura: Lectura | None) -> str:
        if vista.fase is Fase.TERMINADA:
            texto = EXPLICACIONES[Fase.TERMINADA]
        else:
            numero = FASES.index(vista.fase) + 1
            partes = [f"Fase {numero} de {len(FASES)}: {NOMBRES[vista.fase].lower()}"]
            if lectura is not None and lectura.porcentaje is not None:
                partes.append(f"{lectura.porcentaje} %")
            if vista.restante_total_s is not None:
                partes.append(f"quedan unas {formatear_duracion(vista.restante_total_s)}"
                              if vista.restante_total_s >= 3600
                              else f"quedan unos {formatear_duracion(vista.restante_total_s)}")
            texto = " · ".join(partes)
            if vista.ambigua:
                # Se empezo a mirar con la calibracion ya en marcha: llena o
                # cargando, lo mismo puede ser el principio que el final.
                texto += ("\nNo se vio empezar: si ya se descargo, esta es la "
                          "recarga o ya ha terminado.")
        if vista.aviso:
            texto += f"\n⚠ {vista.aviso}"
        return texto

    def _pintar_progreso(self, vista: Vista) -> None:
        if vista.progreso is None:
            self._fila_progreso.set_visible(False)
            return
        self._fila_progreso.set_visible(True)
        self._barra.set_fraction(min(max(vista.progreso, 0.0), 1.0))
        self._barra.set_text(f"{vista.progreso:.0%}")

    def _pintar_fases(self, vista: Vista) -> None:
        hechas = dict(vista.duraciones)
        pendientes = dict(vista.pendientes)
        for fase, (_fila, icono, etiqueta) in self._fases.items():
            if fase is vista.fase:
                icono.set_from_icon_name(ICONO_EN_CURSO)
                etiqueta.set_label(
                    "" if vista.restante_fase_s is None
                    else f"quedan {formatear_duracion(vista.restante_fase_s)}"
                )
            elif fase in pendientes:
                icono.set_from_icon_name(ICONO_PENDIENTE)
                etiqueta.set_label(f"~{formatear_duracion(pendientes[fase])}")
            else:
                # Hecha.  Sin duracion si ya estaba en curso al empezar a mirar.
                icono.set_from_icon_name(ICONO_HECHA)
                etiqueta.set_label(formatear_duracion(hechas[fase]) if fase in hechas else "hecha")
