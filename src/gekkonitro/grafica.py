"""Grafica de RPM dibujada a mano con cairo.

Sin dependencias externas (nada de matplotlib): un GtkDrawingArea y cairo, que ya
vienen con GTK4.  Los colores salen de Adw.StyleManager y de Gtk.Widget.get_color(),
asi que el tema claro y el oscuro funcionan solos, sin una linea de CSS propio.

Solo se redibuja cuando entra una muestra nueva (queue_draw en anadir_muestra):
no hay ningun temporizador dentro de este fichero.
"""

from __future__ import annotations

import math
import weakref
from collections import deque

import cairo  # viene con GTK4/pycairo; el propio draw_func recibe un cairo.Context

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gdk, Gtk  # noqa: E402

#: Ventana deslizante: 120 muestras a 1 Hz = 2 minutos de historico.
MUESTRAS = 120

#: Tope del eje Y en RPM.  Los ventiladores del AN17-51 llegan a ~3200 en
#: 'performance', asi que 4000 deja aire sin aplastar la señal.
EJE_MAX = 4000

#: Lineas de rejilla horizontales (0, 1000, 2000, 3000, 4000).
PASO_REJILLA = 1000


class GraficaRPM(Gtk.DrawingArea):
    """Grafico de lineas con dos series (ventilador de CPU y de GPU)."""

    def __init__(self) -> None:
        super().__init__()
        self.set_content_height(150)
        self.set_hexpand(True)
        # deque con maxlen: la ventana deslizante se mantiene sola.
        self._serie1: deque[float | None] = deque(maxlen=MUESTRAS)
        self._serie2: deque[float | None] = deque(maxlen=MUESTRAS)
        self.set_draw_func(self._dibujar)

        # Un cambio de tema (claro <-> oscuro) obliga a repintar con la paleta
        # nueva.  Es un evento raro, no un temporizador.
        #
        # Adw.StyleManager.get_default() es un SINGLETON que vive lo que dure el
        # proceso: una lambda que capture 'self' mantendria viva la grafica para
        # siempre.  Con la ventana de «Reintentar» se construye una grafica
        # nueva, y la vieja se habria quedado repintandose eternamente.  Una
        # referencia debil deja que el widget se libere y vuelve inofensivo al
        # manejador.
        debil = weakref.ref(self)

        def _repintar(*_args) -> None:
            widget = debil()
            if widget is not None:
                widget.queue_draw()

        gestor = Adw.StyleManager.get_default()
        gestor.connect("notify::dark", _repintar)
        gestor.connect("notify::accent-color", _repintar)

    # -- datos --------------------------------------------------------------

    def anadir_muestra(self, fan1: int | None, fan2: int | None) -> None:
        """Anade una muestra y pide UN repintado.  Unico disparador de dibujo."""
        self._serie1.append(float(fan1) if fan1 is not None else None)
        self._serie2.append(float(fan2) if fan2 is not None else None)
        self.queue_draw()

    @property
    def hay_datos(self) -> bool:
        return any(v is not None for v in self._serie1)

    # -- colores del tema ---------------------------------------------------

    def _colores(self) -> tuple[Gdk.RGBA, Gdk.RGBA, Gdk.RGBA]:
        """(color serie 1, color serie 2, color de texto/rejilla).

        La serie 1 usa el color de acento elegido por el usuario en GNOME; la 2,
        el naranja de la paleta de libadwaita, que contrasta con casi todos los
        acentos.  El texto sale de Gtk.Widget.get_color(), o sea del CSS del
        propio widget: cambia solo con el tema, igual que lo hace cualquier
        GtkLabel de la ventana.  Comprobado con una configuracion de GTK limpia:
        get_color() da (1,1,1) en oscuro y (0,0,0.024) en claro.

        (Si un ~/.config/gtk-4.0/gtk.css del usuario fija los colores de
        libadwaita a mano en :root con prioridad USER, get_color() devuelve
        siempre ese color y la grafica se queda con el.  Es correcto: entonces
        TODAS las etiquetas de TODAS las aplicaciones GTK4 hacen lo mismo, y la
        grafica debe parecerse a ellas, no llevar la contraria.)
        """
        gestor = Adw.StyleManager.get_default()
        try:
            c1 = gestor.get_accent_color_rgba()
        except (AttributeError, TypeError):  # pragma: no cover - libadwaita viejo
            c1 = Gdk.RGBA()
            c1.parse("#3584e4")
        try:
            c2 = Adw.AccentColor.to_rgba(Adw.AccentColor.ORANGE)
        except (AttributeError, TypeError):  # pragma: no cover
            c2 = Gdk.RGBA()
            c2.parse("#ed5b00")
        return c1, c2, self.get_color()

    # -- dibujo -------------------------------------------------------------

    def _dibujar(self, area: Gtk.DrawingArea, cr, ancho: int, alto: int) -> None:
        if ancho <= 0 or alto <= 0:
            return

        col1, col2, col_texto = self._colores()

        # Margen izquierdo para las etiquetas del eje Y.
        margen_izq = 38
        margen_sup = 6
        margen_inf = 6
        x0 = margen_izq
        y0 = margen_sup
        w = max(1, ancho - margen_izq - 4)
        h = max(1, alto - margen_sup - margen_inf)

        def y_de(rpm: float) -> float:
            """Convierte RPM a coordenada Y, recortando al tope del eje."""
            v = max(0.0, min(float(EJE_MAX), rpm))
            return y0 + h - (v / EJE_MAX) * h

        # --- rejilla y etiquetas ------------------------------------------
        cr.set_line_width(1.0)
        cr.select_font_face(
            "monospace", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL
        )
        cr.set_font_size(9)
        for rpm in range(0, EJE_MAX + 1, PASO_REJILLA):
            y = round(y_de(rpm)) + 0.5  # +0.5 => linea nitida de 1 px
            # Rejilla muy tenue: no debe competir con los datos.
            cr.set_source_rgba(col_texto.red, col_texto.green, col_texto.blue, 0.13)
            cr.move_to(x0, y)
            cr.line_to(x0 + w, y)
            cr.stroke()
            # Etiqueta alineada a la derecha del margen.
            etiqueta = str(rpm)
            ext = cr.text_extents(etiqueta)
            cr.set_source_rgba(col_texto.red, col_texto.green, col_texto.blue, 0.55)
            cr.move_to(x0 - 6 - ext.width, y + 3)
            cr.show_text(etiqueta)

        if not self.hay_datos:
            # Sin datos aun: un aviso centrado en vez de un lienzo vacio raro.
            texto = "Recogiendo muestras…"
            cr.set_font_size(11)
            ext = cr.text_extents(texto)
            cr.set_source_rgba(col_texto.red, col_texto.green, col_texto.blue, 0.45)
            cr.move_to(x0 + (w - ext.width) / 2, y0 + h / 2)
            cr.show_text(texto)
            return

        # Las muestras se dibujan ancladas a la DERECHA: la ventana crece hacia
        # la izquierda hasta llenarse y luego se desliza.
        paso = w / float(MUESTRAS - 1)

        def x_de(indice: int, total: int) -> float:
            # indice 0 es la muestra mas antigua de las 'total' que tenemos.
            return x0 + w - (total - 1 - indice) * paso

        def trazar(serie: deque, color: Gdk.RGBA) -> None:
            total = len(serie)
            # Trocea la serie en tramos continuos: un None corta la linea en vez
            # de inventar una interpolacion falsa.
            tramos: list[list[tuple[float, float]]] = []
            actual: list[tuple[float, float]] = []
            for i, valor in enumerate(serie):
                if valor is None:
                    if len(actual) > 0:
                        tramos.append(actual)
                        actual = []
                    continue
                actual.append((x_de(i, total), y_de(valor)))
            if actual:
                tramos.append(actual)

            base = y0 + h
            for puntos in tramos:
                if len(puntos) < 2:
                    # Un tramo de una sola muestra (la primera, o una aislada
                    # entre huecos) no forma linea: se pinta como punto, que si
                    # no desaparecia de la grafica sin dejar rastro.
                    cr.set_source_rgba(color.red, color.green, color.blue, 1.0)
                    cr.arc(puntos[0][0], puntos[0][1], 2.6, 0, 2 * math.pi)
                    cr.fill()
                    continue
                # Relleno con gradiente vertical suave bajo la curva.
                grad = cairo.LinearGradient(0, y0, 0, base)
                grad.add_color_stop_rgba(0, color.red, color.green, color.blue, 0.28)
                grad.add_color_stop_rgba(1, color.red, color.green, color.blue, 0.0)
                cr.move_to(puntos[0][0], base)
                for px, py in puntos:
                    cr.line_to(px, py)
                cr.line_to(puntos[-1][0], base)
                cr.close_path()
                cr.set_source(grad)
                cr.fill()
                # Linea principal.
                cr.set_source_rgba(color.red, color.green, color.blue, 1.0)
                cr.set_line_width(1.8)
                cr.set_line_join(cairo.LINE_JOIN_ROUND)
                cr.move_to(*puntos[0])
                for px, py in puntos[1:]:
                    cr.line_to(px, py)
                cr.stroke()
                # Punto en la ultima muestra, para saber donde esta el "ahora".
                ux, uy = puntos[-1]
                if abs(ux - (x0 + w)) < paso:
                    cr.arc(ux, uy, 2.6, 0, 2 * math.pi)
                    cr.fill()

        trazar(self._serie1, col1)
        trazar(self._serie2, col2)

        # --- leyenda -------------------------------------------------------
        cr.set_font_size(10)
        cr.select_font_face(
            "sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL
        )
        lx = x0 + 6
        for color, texto in ((col1, "CPU"), (col2, "GPU")):
            cr.set_source_rgba(color.red, color.green, color.blue, 1.0)
            cr.rectangle(lx, y0 + 4, 8, 3)
            cr.fill()
            cr.set_source_rgba(col_texto.red, col_texto.green, col_texto.blue, 0.7)
            cr.move_to(lx + 12, y0 + 11)
            cr.show_text(texto)
            lx += 12 + cr.text_extents(texto).width + 14
