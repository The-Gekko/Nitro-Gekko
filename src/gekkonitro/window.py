"""Ventana principal de Nitro Gekko.

AdwApplicationWindow -> AdwToastOverlay -> AdwToolbarView -> AdwHeaderBar +
una sola AdwPreferencesPage con cinco grupos.

El bucle de refresco se detiene cuando la ventana deja de ser visible y se
reanuda al volver, para no quemar CPU en segundo plano.
"""

from __future__ import annotations

import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402

from . import sysfs  # noqa: E402
from .ajustes import Ajustes  # noqa: E402
from .grafica import GraficaRPM  # noqa: E402

#: Periodo del bucle barato (ventiladores, temperaturas, PL1).
PERIODO_RAPIDO = 1
#: Periodo del bucle caro (perfil + temperatura de bateria: ~10 ms de ACPI).
PERIODO_LENTO = 10
#: Periodo de consulta a la GPU (nvidia-smi despierta la tarjeta).
PERIODO_GPU = 5

#: Iconos por perfil.  Se usan en el desplegable y en la fila de RPM tipicas.
ICONOS_PERFIL = {
    "low-power": "power-profile-power-saver-symbolic",
    "quiet": "weather-clear-night-symbolic",
    "balanced": "power-profile-balanced-symbolic",
    "balanced-performance": "speedometer-symbolic",
    "performance": "power-profile-performance-symbolic",
}

#: Texto del aviso del perfil roto (gotcha 1).
AVISO_BP = (
    "Este perfil deja en blanco el menu de energia de GNOME.\n\n"
    "No es un fallo de Nitro Gekko: power-profiles-daemon compara internamente "
    "«balanced_performance» (con guion bajo) contra el «balanced-performance» "
    "(con guion) del kernel, no encaja, y deja su propiedad ActiveProfile sin "
    "valor. El portatil funciona con normalidad; solo el menu se queda vacio "
    "hasta que elijas otro perfil."
)

#: Explicacion del «Not charging» que confunde a todo el mundo.
AYUDA_NOT_CHARGING = (
    "Con el limite activo la bateria deja de cargar al llegar al 80 %, y "
    "entonces BAT1 informa «Not charging». Es el comportamiento correcto, no "
    "una averia ni un cargador defectuoso."
)


class VentanaNitro(Adw.ApplicationWindow):
    """Ventana unica de la aplicacion."""

    def __init__(self, app: Adw.Application) -> None:
        super().__init__(application=app, title="Nitro Gekko")
        self.set_default_size(560, 780)

        self._control = sysfs.ControlNitro()
        self._ajustes = Ajustes()

        # Identificadores de los temporizadores activos (None = parado).
        self._id_rapido: int | None = None
        self._id_lento: int | None = None
        self._id_gpu: int | None = None
        #: Guarda durante la construccion, cuando aun no hay estado de hardware.
        self._cargando = True
        #: La interfaz de verdad (no la pagina de error) esta construida.
        self._interfaz_lista = False
        #: La ventana ya se ha cerrado: no se vuelve a arrancar ningun bucle.
        self._cerrada = False
        #: Superficie GDK a la que estamos escuchando 'notify::state'.
        self._superficie_enganchada = None

        # ULTIMO ESTADO LEIDO DEL HARDWARE.  Es la defensa contra la reentrada:
        # un manejador solo escribe si el valor del widget DIFIERE del hardware.
        #
        # No basta con una bandera del tipo "estoy recargando": al revertir un
        # widget desde dentro de su propio notify, GObject NO entrega la
        # notificacion en el acto, la encola hasta que termina la emision en
        # curso.  Para entonces la bandera ya se ha vuelto a poner en False y el
        # manejador se ejecuta otra vez -> revierte -> vuelve a ejecutarse...
        # bucle infinito (reproducido: el interruptor de bateria escribia
        # 0,1,0,1... sin parar).  Comparar contra el hardware corta el ciclo,
        # porque la reversion deja el widget EXACTAMENTE en el valor del
        # hardware y la notificacion encolada se vuelve inofensiva.
        self._perfil_actual: str | None = None
        self._hw_salud: bool | None = None
        self._hw_turbo: bool | None = None
        self._hw_pl1_w: float | None = None
        self._gpu_consultando = False

        self._toasts = Adw.ToastOverlay()
        self.set_content(self._toasts)

        # Arranque y parada del bucle segun visibilidad REAL de la ventana.
        # Se conectan ANTES de decidir si hay hardware: si solo se conectaran en
        # la rama buena, una ventana nacida en modo «hardware ausente» que luego
        # acierta con «Reintentar» se quedaba sin 'unmap' ni 'close-request', y
        # los tres temporizadores seguian leyendo sysfs para siempre despues de
        # cerrarla (medido: seguian vivos tras close()).
        self.connect("map", self._al_mapear)
        self.connect("unmap", lambda *_: self._parar_bucles())
        self.connect("notify::is-active", self._al_cambiar_actividad)
        self.connect("close-request", self._al_cerrar)

        diagnostico = self._control.diagnosticar()
        if not diagnostico.utilizable:
            # Falta hardware: pagina de estado explicativa, no un cierre feo.
            self._toasts.set_child(self._construir_estado_error(diagnostico))
            return

        self._toasts.set_child(self._construir_interfaz())
        self._interfaz_lista = True
        self._cargando = False

    # ------------------------------------------------------------------
    # Construccion de la interfaz
    # ------------------------------------------------------------------

    def _construir_estado_error(self, diagnostico: sysfs.Diagnostico) -> Gtk.Widget:
        """AdwStatusPage que dice QUE falta y COMO arreglarlo."""
        estado = Adw.StatusPage(
            icon_name="dialog-warning-symbolic",
            title="Hardware no compatible",
            description="\n\n".join(diagnostico.faltantes),
        )
        caja = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        boton = Gtk.Button(label="Reintentar")
        boton.set_halign(Gtk.Align.CENTER)
        boton.add_css_class("pill")
        boton.add_css_class("suggested-action")
        boton.connect("clicked", self._reintentar_deteccion)
        estado.set_child(boton)

        vista = Adw.ToolbarView()
        cabecera = Adw.HeaderBar()
        vista.add_top_bar(cabecera)
        vista.set_content(estado)
        caja.append(vista)
        vista.set_vexpand(True)
        return caja

    def _reintentar_deteccion(self, _boton) -> None:
        """Vuelve a mirar el hardware (util si acabas de cargar el modulo)."""
        self._control = sysfs.ControlNitro()
        diagnostico = self._control.diagnosticar()
        if diagnostico.utilizable:
            self._toasts.set_child(self._construir_interfaz())
            self._interfaz_lista = True
            self._cargando = False
            self._arrancar_bucles()
            self._notificar("Hardware detectado.")
        else:
            self._notificar("Sigue sin detectarse el hardware del Acer.")

    def _construir_interfaz(self) -> Gtk.Widget:
        pagina = Adw.PreferencesPage()
        pagina.add(self._grupo_perfil())
        pagina.add(self._grupo_ventiladores())
        pagina.add(self._grupo_potencia())
        pagina.add(self._grupo_bateria())
        pagina.add(self._grupo_temperaturas())

        # La pagina de teclado solo existe si el driver linuwu_sense esta
        # cargado. Con el acer_wmi del kernel se omite entera, en vez de
        # ensenar una pestana llena de controles en gris que no explican nada.
        self._hay_teclado = self._control.hay_teclado_rgb()

        vista = Adw.ToolbarView()
        cabecera = Adw.HeaderBar()

        boton_menu = Gtk.MenuButton(icon_name="open-menu-symbolic")
        menu = Gtk.Builder.new_from_string(
            """
            <interface>
              <menu id="menu">
                <section>
                  <item>
                    <attribute name="label">Acerca de Nitro Gekko</attribute>
                    <attribute name="action">app.acerca-de</attribute>
                  </item>
                </section>
              </menu>
            </interface>
            """,
            -1,
        ).get_object("menu")
        boton_menu.set_menu_model(menu)
        cabecera.pack_end(boton_menu)

        vista.add_top_bar(cabecera)
        if self._hay_teclado:
            self._pila = Adw.ViewStack()
            self._pila.add_titled_with_icon(
                pagina, "sistema", "Sistema", "speedometer-symbolic"
            )
            self._pila.add_titled_with_icon(
                self._pagina_teclado(), "teclado", "Teclado",
                "keyboard-brightness-symbolic",
            )
            conmutador = Adw.ViewSwitcher(
                stack=self._pila, policy=Adw.ViewSwitcherPolicy.WIDE
            )
            cabecera.set_title_widget(conmutador)
            vista.set_content(self._pila)
        else:
            vista.set_content(pagina)
        return vista

    # -- grupo 1: perfil termico ---------------------------------------

    def _grupo_perfil(self) -> Adw.PreferencesGroup:
        """Selector de perfil.

        DECISION DE DISEÑO (medida, no intuida): NO se usa un AdwToggleGroup con
        las cinco etiquetas de texto.  Medido con get_preferred_size() dentro de
        una AdwPreferencesPage en una ventana de 900 px:

            AdwToggleGroup (5 etiquetas): natural 619 px, asignado 565 px -> ELIDE
            AdwComboRow                 : natural 190 px, asignado 571 px -> cabe

        El clamp de AdwPreferencesPage concede 575 px al grupo, de modo que el
        ToggleGroup se queda 54 px corto SIEMPRE y elide las etiquetas: el
        usuario veria «Equilibrado-r…» y «Bajo cons…».  Con un AdwComboRow el
        nombre del perfil se lee entero, sobra sitio para el icono de aviso de
        «balanced-performance» como sufijo, y ademas se adapta solo si en el
        futuro el kernel expone mas perfiles (la lista sale de 'choices').
        """
        grupo = Adw.PreferencesGroup(
            title="Perfil termico",
            description="Controla la curva de ventilacion y el limite de potencia "
            "del firmware.",
        )

        perfiles = self._control.perfiles()
        self._perfiles = perfiles
        etiquetas = [sysfs.ETIQUETAS_PERFIL.get(p, p) for p in perfiles]

        self._combo_perfil = Adw.ComboRow(
            title="Perfil activo",
            model=Gtk.StringList.new(etiquetas),
        )
        self._combo_perfil.set_use_subtitle(False)

        # Icono de aviso para 'balanced-performance' (gotcha 1).  Va como sufijo
        # de la fila y solo se muestra cuando ese perfil esta seleccionado.
        self._aviso_perfil = Gtk.Image(icon_name="dialog-warning-symbolic")
        self._aviso_perfil.set_tooltip_text(AVISO_BP)
        self._aviso_perfil.add_css_class("warning")
        self._aviso_perfil.set_visible(False)
        self._combo_perfil.add_suffix(self._aviso_perfil)

        self._combo_perfil.connect("notify::selected", self._al_elegir_perfil)
        grupo.add(self._combo_perfil)

        # Fila con las RPM tipicas medidas de cada perfil.
        fila_rpm = Adw.ActionRow(
            title="RPM tipicas por perfil",
            subtitle="Medidas en este equipo. «Rendimiento» sopla al doble para "
            "ganar apenas 1 °C.",
        )
        # Sin limite de lineas: con las cinco columnas de iconos ocupando el
        # sufijo, a 360 px (el ancho minimo que admite la ventana) tres lineas
        # no daban para el subtitulo y se elidia. Que envuelva lo que necesite.
        fila_rpm.set_subtitle_lines(0)
        caja = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        caja.set_valign(Gtk.Align.CENTER)
        for perfil in perfiles:
            rpm = sysfs.RPM_TIPICAS.get(perfil)
            if rpm is None:
                continue
            columna = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
            columna.set_tooltip_text(
                f"{sysfs.ETIQUETAS_PERFIL.get(perfil, perfil)}: ~{rpm} RPM"
            )
            icono = Gtk.Image(icon_name=ICONOS_PERFIL.get(perfil, "emblem-system-symbolic"))
            icono.add_css_class("dim-label")
            valor = Gtk.Label(label=str(rpm))
            valor.add_css_class("caption")
            valor.add_css_class("numeric")
            valor.add_css_class("dim-label")
            columna.append(icono)
            columna.append(valor)
            caja.append(columna)
        fila_rpm.add_suffix(caja)
        grupo.add(fila_rpm)
        return grupo

    # -- grupo 2: ventiladores -----------------------------------------

    def _grupo_ventiladores(self) -> Adw.PreferencesGroup:
        grupo = Adw.PreferencesGroup(
            title="Ventiladores",
            description="Ultimos 2 minutos, una muestra por segundo.",
        )

        self._grafica = GraficaRPM()
        # AdwPreferencesGroup mete los GtkListBoxRow en su lista interna y
        # CUALQUIER otro widget en una caja posterior: si se anade la grafica
        # suelta, aparece DEBAJO de las filas. Envolviendola en un ListBoxRow no
        # activable entra en la lista y queda arriba del todo, dentro de la
        # misma tarjeta que las dos filas de RPM.
        fila_grafica = Gtk.ListBoxRow()
        fila_grafica.set_activatable(False)
        fila_grafica.set_selectable(False)
        self._grafica.set_margin_top(10)
        self._grafica.set_margin_bottom(6)
        self._grafica.set_margin_start(6)
        self._grafica.set_margin_end(6)
        fila_grafica.set_child(self._grafica)
        grupo.add(fila_grafica)

        self._fila_fan1, self._lbl_fan1, self._nivel_fan1 = self._fila_ventilador(
            "Ventilador de CPU", "fan1_input"
        )
        self._fila_fan2, self._lbl_fan2, self._nivel_fan2 = self._fila_ventilador(
            "Ventilador de GPU", "fan2_input"
        )
        grupo.add(self._fila_fan1)
        grupo.add(self._fila_fan2)
        return grupo

    def _fila_ventilador(self, titulo: str, fichero: str):
        """AdwActionRow con etiqueta monoespaciada y GtkLevelBar 0..4000."""
        fila = Adw.ActionRow(title=titulo, subtitle=fichero)
        nivel = Gtk.LevelBar.new_for_interval(0, 4000)
        nivel.set_size_request(120, -1)
        nivel.set_valign(Gtk.Align.CENTER)
        nivel.set_mode(Gtk.LevelBarMode.CONTINUOUS)
        etiqueta = Gtk.Label(label="—")
        # 'numeric' da cifras tabulares: el numero no baila al cambiar.
        etiqueta.add_css_class("numeric")
        etiqueta.add_css_class("dim-label")
        etiqueta.set_width_chars(9)
        etiqueta.set_xalign(1.0)
        caja = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        caja.set_valign(Gtk.Align.CENTER)
        caja.append(nivel)
        caja.append(etiqueta)
        fila.add_suffix(caja)
        return fila, etiqueta, nivel

    # -- grupo 3: potencia ---------------------------------------------

    def _grupo_potencia(self) -> Adw.PreferencesGroup:
        grupo = Adw.PreferencesGroup(
            title="Potencia",
            description="PL1 es la potencia sostenida de la CPU. No hay lectura de "
            "vatios en vivo: el kernel bloquea energy_uj por la mitigacion "
            "PLATYPUS (CVE-2020-8694).",
        )

        maximo = self._control.pl1_maximo_w()
        self._spin_pl1 = Adw.SpinRow.new_with_range(10, 65, 1)
        self._spin_pl1.set_title("Limite de potencia sostenida (PL1)")
        self._spin_pl1.set_subtitle(
            f"En vatios. El nominal declarado del chip es {maximo:.0f} W."
        )
        self._spin_pl1.connect("notify::value", self._al_cambiar_pl1)
        grupo.add(self._spin_pl1)

        # Fila de solo lectura: MSR frente a MMIO.
        self._fila_efectivo = Adw.ActionRow(
            title="PL1 efectivo",
            subtitle="MSR y MMIO, tal como los reporta el kernel.",
        )
        self._lbl_msr = Gtk.Label(label="—")
        self._lbl_msr.add_css_class("numeric")
        self._lbl_mmio = Gtk.Label(label="—")
        self._lbl_mmio.add_css_class("numeric")
        caja = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        caja.set_valign(Gtk.Align.CENTER)
        caja.append(self._lbl_msr)
        separador = Gtk.Label(label="/")
        separador.add_css_class("dim-label")
        caja.append(separador)
        caja.append(self._lbl_mmio)
        self._fila_efectivo.add_suffix(caja)
        grupo.add(self._fila_efectivo)

        self._sw_reaplicar = Adw.SwitchRow(
            title="Reaplicar PL1 al cambiar de perfil",
            subtitle="El firmware reescribe el PL1 por MMIO en cada cambio de "
            "perfil (70 W en equilibrado, 100 W en rendimiento).",
        )
        self._sw_reaplicar.set_active(bool(self._ajustes.obtener("reaplicar_pl1")))
        self._sw_reaplicar.connect("notify::active", self._al_cambiar_reaplicar)
        grupo.add(self._sw_reaplicar)

        self._sw_turbo = Adw.SwitchRow(
            title="Turbo Boost",
            subtitle="Permite a la CPU superar su frecuencia base.",
        )
        self._sw_turbo.connect("notify::active", self._al_cambiar_turbo)
        grupo.add(self._sw_turbo)
        return grupo

    # -- grupo 4: bateria ----------------------------------------------

    def _grupo_bateria(self) -> Adw.PreferencesGroup:
        grupo = Adw.PreferencesGroup(title="Bateria")

        self._sw_salud = Adw.SwitchRow(
            title="Limitar carga al 80 %",
            subtitle="Alarga la vida de la bateria si usas el portatil enchufado.",
        )
        self._sw_salud.set_subtitle_lines(3)
        self._sw_salud.connect("notify::active", self._al_cambiar_salud)
        grupo.add(self._sw_salud)

        self._fila_temp_bat = Adw.ActionRow(
            title="Temperatura de la bateria",
            subtitle="Se consulta cada 10 s: es una llamada WMI de ~5 ms.",
        )
        self._lbl_temp_bat = Gtk.Label(label="—")
        self._lbl_temp_bat.add_css_class("numeric")
        self._lbl_temp_bat.add_css_class("dim-label")
        self._fila_temp_bat.add_suffix(self._lbl_temp_bat)
        grupo.add(self._fila_temp_bat)
        return grupo

    # -- grupo 5: temperaturas -----------------------------------------

    def _grupo_temperaturas(self) -> Adw.PreferencesGroup:
        grupo = Adw.PreferencesGroup(title="Temperaturas")

        self._fila_cpu = Adw.ActionRow(
            title="Paquete de CPU", subtitle="coretemp · Package id 0"
        )
        self._lbl_cpu = Gtk.Label(label="—")
        self._lbl_cpu.add_css_class("numeric")
        self._lbl_cpu.add_css_class("dim-label")
        self._fila_cpu.add_suffix(self._lbl_cpu)
        grupo.add(self._fila_cpu)

        self._fila_freq = Adw.ActionRow(
            title="Frecuencia media", subtitle="Media de los 16 hilos"
        )
        self._lbl_freq = Gtk.Label(label="—")
        self._lbl_freq.add_css_class("numeric")
        self._lbl_freq.add_css_class("dim-label")
        self._fila_freq.add_suffix(self._lbl_freq)
        grupo.add(self._fila_freq)

        # La fila de GPU nace oculta y solo aparece si nvidia-smi responde.
        self._fila_gpu = Adw.ActionRow(title="GPU", subtitle="NVIDIA")
        self._lbl_gpu = Gtk.Label(label="—")
        self._lbl_gpu.add_css_class("numeric")
        self._lbl_gpu.add_css_class("dim-label")
        self._fila_gpu.add_suffix(self._lbl_gpu)
        self._fila_gpu.set_visible(False)
        grupo.add(self._fila_gpu)
        return grupo

    # ------------------------------------------------------------------
    # Bucles de refresco
    # ------------------------------------------------------------------

    def _arrancar_bucles(self) -> None:
        """Arranca los temporizadores si procede y no estaban ya en marcha.

        La guarda es imprescindible: el compositor sigue emitiendo
        'notify::state' DESPUES del unmap y del cierre de la ventana, y como
        esos estados ya no traen SUSPENDED, _al_cambiar_estado los interpretaba
        como «ha vuelto a ser visible» y rearmaba los tres bucles con la ventana
        cerrada (medido: 4 tics del ciclo de 1 Hz en 4 s tras close(), mas un
        nvidia-smi cada 5 s despertando la GPU).  Solo se lee sysfs con la
        interfaz construida, la ventana mapeada y sin haberse cerrado.
        """
        if not self._interfaz_lista or self._cerrada or not self.get_mapped():
            return
        if self._id_rapido is None:
            self._tic_rapido()  # pintado inmediato, sin esperar 1 s
            self._id_rapido = GLib.timeout_add_seconds(PERIODO_RAPIDO, self._tic_rapido)
        if self._id_lento is None:
            self._tic_lento()
            self._id_lento = GLib.timeout_add_seconds(PERIODO_LENTO, self._tic_lento)
        if self._id_gpu is None:
            self._tic_gpu()
            self._id_gpu = GLib.timeout_add_seconds(PERIODO_GPU, self._tic_gpu)

    def _parar_bucles(self) -> None:
        """Detiene los temporizadores: en segundo plano no gastamos CPU."""
        for atributo in ("_id_rapido", "_id_lento", "_id_gpu"):
            ident = getattr(self, atributo, None)
            if ident is not None:
                GLib.source_remove(ident)
                setattr(self, atributo, None)

    def _al_mapear(self, *_args) -> None:
        """La ventana aparece: arranca y engancha el estado del toplevel.

        En Wayland minimizar NO desmapea la ventana, asi que 'unmap' por si solo
        no basta. GTK 4.12+ expone GDK_TOPLEVEL_STATE_SUSPENDED, que el
        compositor activa cuando la ventana deja de ser visible de verdad
        (minimizada, tapada por otra o en otro escritorio): es la senal correcta
        para dejar de leer sysfs.
        """
        self._arrancar_bucles()
        # La GdkSurface se destruye y se vuelve a crear si la ventana se
        # desrealiza, asi que no basta con una bandera de «ya enganchado»:
        # comparamos la superficie concreta para no quedarnos escuchando a una
        # superficie muerta (y para no conectar dos veces a la misma).
        superficie = self.get_surface()
        if superficie is not None and superficie is not self._superficie_enganchada:
            superficie.connect("notify::state", self._al_cambiar_estado)
            self._superficie_enganchada = superficie

    def _al_cambiar_estado(self, superficie, _pspec) -> None:
        """El compositor dice si la ventana sigue siendo visible."""
        try:
            estado = superficie.get_state()
        except AttributeError:  # pragma: no cover - GDK sin get_state
            return
        oculta = bool(estado & Gdk.ToplevelState.SUSPENDED) or bool(
            estado & Gdk.ToplevelState.MINIMIZED
        )
        if oculta:
            self._parar_bucles()
        else:
            self._arrancar_bucles()

    def _al_cambiar_actividad(self, *_args) -> None:
        """Respaldo: al recuperar el foco nos aseguramos de estar leyendo."""
        if self.get_property("is-active"):
            self._arrancar_bucles()

    def _al_cerrar(self, *_args) -> bool:
        """La ventana se cierra: se para todo y no se vuelve a arrancar."""
        self._cerrada = True
        self._parar_bucles()
        return False

    def _tic_rapido(self) -> bool:
        estado = self._control.leer_rapido()
        self._cargando = True
        try:
            # Ventiladores + grafica.
            self._grafica.anadir_muestra(estado.fan1, estado.fan2)
            for valor, etiqueta, nivel in (
                (estado.fan1, self._lbl_fan1, self._nivel_fan1),
                (estado.fan2, self._lbl_fan2, self._nivel_fan2),
            ):
                if valor is None:
                    etiqueta.set_label("s/d")
                    nivel.set_value(0)
                else:
                    etiqueta.set_label(f"{valor} RPM")
                    nivel.set_value(min(valor, 4000))

            # Temperatura y frecuencia.
            self._lbl_cpu.set_label(
                "—" if estado.temp_paquete is None else f"{estado.temp_paquete:.0f} °C"
            )
            self._lbl_freq.set_label(
                "—"
                if estado.freq_media_mhz is None
                else f"{estado.freq_media_mhz / 1000:.2f} GHz"
            )

            # PL1 efectivo: MSR y MMIO, con el MMIO en ambar si difieren.
            self._actualizar_pl1(estado)

            # Turbo (no_turbo invertido).  Se apunta SIEMPRE el estado real
            # ANTES de tocar el widget: el manejador compara contra el.
            if estado.no_turbo is not None:
                self._hw_turbo = not estado.no_turbo
                self._sw_turbo.set_active(self._hw_turbo)

            # Bateria.
            if estado.health_mode is not None:
                self._hw_salud = estado.health_mode
                self._sw_salud.set_active(estado.health_mode)
            self._actualizar_subtitulo_bateria(estado)
        finally:
            self._cargando = False
        return GLib.SOURCE_CONTINUE

    def _actualizar_pl1(self, estado: sysfs.EstadoRapido) -> None:
        msr, mmio = estado.pl1_msr_w, estado.pl1_mmio_w
        self._lbl_msr.set_label("—" if msr is None else f"MSR {msr:.0f} W")
        self._lbl_mmio.set_label("—" if mmio is None else f"MMIO {mmio:.0f} W")

        # El spin refleja el MSR mientras el usuario no lo este tocando.
        if msr is not None:
            self._hw_pl1_w = msr
            if not self._spin_en_edicion():
                self._spin_pl1.set_value(round(msr))

        self._lbl_mmio.remove_css_class("warning")
        if msr is not None and mmio is not None and abs(msr - mmio) > 0.5:
            # Discrepancia: la pintamos en ambar y explicamos quien manda.
            self._lbl_mmio.add_css_class("warning")
            self._fila_efectivo.set_tooltip_text(
                f"El registro MMIO ({mmio:.0f} W) no coincide con el MSR "
                f"({msr:.0f} W).\n\nManda el MSR: es el limite que la CPU respeta "
                f"de verdad (medido: 41,9 W sostenidos con el MSR en 45 W). El "
                f"firmware del portatil reescribe el MMIO en cada cambio de "
                f"perfil, por eso suele quedar descolgado."
            )
        else:
            self._fila_efectivo.set_tooltip_text(
                "MSR y MMIO coinciden. El MSR es el limite que manda."
            )

    def _spin_en_edicion(self) -> bool:
        """¿Esta el usuario tocando ahora mismo el selector de PL1?

        No vale `self._spin_pl1.has_focus()`: dentro de una AdwSpinRow el foco
        real lo tiene el GtkText interno, de modo que has_focus() sobre la fila
        devuelve False SIEMPRE (comprobado: get_focus() -> GtkText,
        spin.has_focus() -> False).  Con aquella comprobacion el tic de 1 Hz
        pisaba el valor que el usuario estuviera escribiendo.  Hay que preguntar
        por el widget con foco de la ventana y ver si cuelga de la fila.
        """
        foco = self.get_focus()
        if foco is None:
            return False
        return foco is self._spin_pl1 or foco.is_ancestor(self._spin_pl1)

    def _actualizar_subtitulo_bateria(self, estado: sysfs.EstadoRapido) -> None:
        capacidad = estado.bat_capacidad
        bruto = estado.bat_estado or "desconocido"
        traduccion = {
            "Charging": "cargando",
            "Discharging": "descargando",
            "Full": "llena",
            "Not charging": "sin cargar",
            "Unknown": "desconocido",
        }
        legible = traduccion.get(bruto, bruto.lower())
        partes = []
        if capacidad is not None:
            partes.append(f"{capacidad} %")
        partes.append(legible)
        texto = " · ".join(partes)

        # El caso que confunde: limite activo + «Not charging» a 80 %.
        if estado.health_mode and bruto == "Not charging":
            texto += ". Ha llegado al limite y ha dejado de cargar a proposito."
        self._sw_salud.set_subtitle(texto)
        self._sw_salud.set_tooltip_text(AYUDA_NOT_CHARGING)

    def _tic_lento(self) -> bool:
        """Ciclo caro: perfil (ACPI, ~5 ms) y temperatura de bateria (WMI, ~5 ms)."""
        estado = self._control.leer_lento()
        self._cargando = True
        try:
            if estado.perfil is not None and estado.perfil != self._perfil_actual:
                self._perfil_actual = estado.perfil
                if estado.perfil in self._perfiles:
                    self._combo_perfil.set_selected(self._perfiles.index(estado.perfil))
                self._aviso_perfil.set_visible(
                    estado.perfil == sysfs.PERFIL_PROBLEMATICO
                )
            self._lbl_temp_bat.set_label(
                "—" if estado.temp_bateria is None else f"{estado.temp_bateria:.1f} °C"
            )
        finally:
            self._cargando = False
        return GLib.SOURCE_CONTINUE

    def _tic_gpu(self) -> bool:
        """Lanza nvidia-smi en un hilo: nunca bloquea la UI."""
        if self._gpu_consultando:
            return GLib.SOURCE_CONTINUE  # la anterior sigue viva, no encolamos otra
        self._gpu_consultando = True

        def trabajo() -> None:
            estado = sysfs.leer_gpu()
            # Volvemos al hilo principal para tocar widgets.
            GLib.idle_add(self._pintar_gpu, estado)

        threading.Thread(target=trabajo, daemon=True).start()
        return GLib.SOURCE_CONTINUE

    def _pintar_gpu(self, estado: sysfs.EstadoGpu) -> bool:
        self._gpu_consultando = False
        if self._cerrada or not self._interfaz_lista:
            # nvidia-smi tarda hasta 300 ms: la ventana puede haberse cerrado
            # mientras respondia. No tocamos widgets de una ventana muerta.
            return GLib.SOURCE_REMOVE
        if not estado.disponible:
            # nvidia-smi no responde o tarda: ocultamos la fila, sin drama.
            self._fila_gpu.set_visible(False)
            return GLib.SOURCE_REMOVE
        self._fila_gpu.set_visible(True)
        partes = [f"{estado.temperatura:.0f} °C"]
        if estado.vatios is not None:
            partes.append(f"{estado.vatios:.1f} W")
        self._lbl_gpu.set_label(" · ".join(partes))
        self._fila_gpu.set_subtitle(
            f"NVIDIA · estado de energia {estado.pstate}"
            if estado.pstate
            else "NVIDIA"
        )
        return GLib.SOURCE_REMOVE


    # ------------------------------------------------------------------
    # Pagina de teclado (solo con el driver linuwu_sense)
    # ------------------------------------------------------------------

    def _pagina_teclado(self) -> Gtk.Widget:
        """Iluminacion del teclado RGB de 4 zonas y extras del EC.

        El estado se lee al construir y despues de cada cambio, NUNCA en el
        bucle de 1 Hz: leer este grupo cuesta ~89 ms porque cada atributo es
        una llamada WMI real al firmware.
        """
        self._tec = self._control.leer_teclado()

        pagina = Adw.PreferencesPage()
        pagina.add(self._grupo_estilos())
        pagina.add(self._grupo_efecto())
        pagina.add(self._grupo_zonas())
        pagina.add(self._grupo_comportamiento())
        return pagina

    def _grupo_estilos(self) -> Adw.PreferencesGroup:
        """Estilos listos para usar, en una rejilla de botones con su color."""
        grupo = Adw.PreferencesGroup(
            title="Estilos",
            description="Toca uno y se aplica al instante. Debajo puedes montarte el tuyo.",
        )
        caja = Gtk.FlowBox(
            selection_mode=Gtk.SelectionMode.NONE,
            max_children_per_line=3,
            min_children_per_line=2,
            row_spacing=8,
            column_spacing=8,
            homogeneous=True,
            margin_top=6,
            margin_bottom=6,
        )
        for nombre in sysfs.PRESETS_RGB:
            tipo, valor = sysfs.PRESETS_RGB[nombre]
            boton = Gtk.Button(css_classes=["card"], height_request=54)
            contenido = Gtk.Box(
                orientation=Gtk.Orientation.VERTICAL, spacing=4,
                margin_top=8, margin_bottom=8, margin_start=6, margin_end=6,
            )
            # Muestra de color: para los presets por zonas se pintan las cuatro
            # franjas reales; para los efectos, el color que llevan.
            muestra = Gtk.DrawingArea(height_request=12)
            if tipo == "zonas":
                cols = [self._hex_a_rgb(c) for c in valor.split(",")[:4]]
            else:
                p = valor.split(",")
                cols = [(int(p[4]) / 255, int(p[5]) / 255, int(p[6]) / 255)] * 4
            muestra.set_draw_func(self._pintar_muestra, cols)
            contenido.append(muestra)
            contenido.append(Gtk.Label(label=nombre, css_classes=["caption"]))
            boton.set_child(contenido)
            boton.connect("clicked", self._al_pulsar_preset, nombre)
            caja.append(boton)

        fila = Adw.PreferencesRow(activatable=False, css_classes=["no-hover"])
        fila.set_child(caja)
        grupo.add(fila)
        return grupo

    @staticmethod
    def _hex_a_rgb(texto: str) -> tuple[float, float, float]:
        t = texto.strip().lstrip("#")
        try:
            return (int(t[0:2], 16) / 255, int(t[2:4], 16) / 255, int(t[4:6], 16) / 255)
        except (ValueError, IndexError):
            return (0.5, 0.5, 0.5)

    @staticmethod
    def _pintar_muestra(area, cr, ancho, alto, colores) -> None:
        """Cuatro franjas: es literalmente lo que van a ver en el teclado."""
        n = max(1, len(colores))
        paso = ancho / n
        radio = min(6, alto / 2)
        for i, (r, g, b) in enumerate(colores):
            cr.set_source_rgb(r, g, b)
            cr.rectangle(i * paso, 0, paso + 1, alto)
            cr.fill()
        # Borde redondeado por encima, para que no parezca un bloque pegado.
        cr.set_source_rgba(0, 0, 0, 0.25)
        cr.set_line_width(1)
        cr.rectangle(0.5, 0.5, ancho - 1, alto - 1)
        cr.stroke()

    def _grupo_efecto(self) -> Adw.PreferencesGroup:
        """Los 8 efectos del firmware, con sus parametros."""
        grupo = Adw.PreferencesGroup(
            title="Efecto propio",
            description="Los ocho efectos que trae el firmware, con sus ajustes.",
        )

        nombres = Gtk.StringList()
        for _, nombre, *_r in sysfs.EFECTOS_RGB:
            nombres.append(nombre)
        self._combo_efecto = Adw.ComboRow(
            title="Efecto", subtitle="Animacion de la retroiluminacion", model=nombres
        )
        actual = self._tec.efecto[0] if self._tec.efecto else 0
        if 0 <= actual < len(sysfs.EFECTOS_RGB):
            self._combo_efecto.set_selected(actual)
        grupo.add(self._combo_efecto)

        self._esc_velocidad = Adw.SpinRow.new_with_range(0, 9, 1)
        self._esc_velocidad.set_title("Velocidad")
        self._esc_velocidad.set_subtitle("0 la mas lenta, 9 la mas rapida")
        self._esc_velocidad.set_value(
            self._tec.efecto[1] if self._tec.efecto and len(self._tec.efecto) > 1 else 4
        )
        grupo.add(self._esc_velocidad)

        self._esc_brillo = Adw.SpinRow.new_with_range(0, 100, 5)
        self._esc_brillo.set_title("Brillo")
        self._esc_brillo.set_value(
            self._tec.efecto[2] if self._tec.efecto and len(self._tec.efecto) > 2 else 100
        )
        grupo.add(self._esc_brillo)

        dirs = Gtk.StringList()
        for d in ("Sin direccion", "Derecha a izquierda", "Izquierda a derecha"):
            dirs.append(d)
        self._combo_direccion = Adw.ComboRow(
            title="Direccion",
            subtitle="Solo la usan Onda y Desplazamiento",
            model=dirs,
        )
        d0 = self._tec.efecto[3] if self._tec.efecto and len(self._tec.efecto) > 3 else 1
        self._combo_direccion.set_selected(min(max(d0, 0), 2))
        grupo.add(self._combo_direccion)

        fila_color = Adw.ActionRow(
            title="Color", subtitle="El efecto Neon y Onda ignoran el color"
        )
        self._color_efecto = Gtk.ColorDialogButton(dialog=Gtk.ColorDialog())
        if self._tec.efecto and len(self._tec.efecto) >= 7:
            r, g, b = self._tec.efecto[4], self._tec.efecto[5], self._tec.efecto[6]
        else:
            r = g = b = 255
        self._color_efecto.set_rgba(Gdk.RGBA(red=r / 255, green=g / 255, blue=b / 255, alpha=1))
        self._color_efecto.set_valign(Gtk.Align.CENTER)
        fila_color.add_suffix(self._color_efecto)
        grupo.add(fila_color)

        boton = Gtk.Button(label="Aplicar efecto", css_classes=["suggested-action"],
                           halign=Gtk.Align.END, margin_top=8, margin_bottom=4)
        boton.connect("clicked", self._al_aplicar_efecto)
        fila_boton = Adw.PreferencesRow(activatable=False)
        fila_boton.set_child(boton)
        grupo.add(fila_boton)
        return grupo

    def _grupo_zonas(self) -> Adw.PreferencesGroup:
        """Color fijo e independiente para cada una de las 4 zonas."""
        grupo = Adw.PreferencesGroup(
            title="Color por zona",
            description="Cuatro zonas de izquierda a derecha del teclado. "
                        "Aplicar aqui desactiva cualquier animacion.",
        )
        self._colores_zona: list[Gtk.ColorDialogButton] = []
        zonas = self._tec.zonas or ["ffffff"] * 4
        etiquetas = ("Zona 1 · izquierda", "Zona 2", "Zona 3", "Zona 4 · derecha")
        for i, etiqueta in enumerate(etiquetas):
            fila = Adw.ActionRow(title=etiqueta)
            boton = Gtk.ColorDialogButton(dialog=Gtk.ColorDialog(), valign=Gtk.Align.CENTER)
            r, g, b = self._hex_a_rgb(zonas[i] if i < len(zonas) else "ffffff")
            boton.set_rgba(Gdk.RGBA(red=r, green=g, blue=b, alpha=1))
            fila.add_suffix(boton)
            self._colores_zona.append(boton)
            grupo.add(fila)

        self._brillo_zonas = Adw.SpinRow.new_with_range(0, 100, 5)
        self._brillo_zonas.set_title("Brillo")
        self._brillo_zonas.set_value(self._tec.brillo_zonas or 100)
        grupo.add(self._brillo_zonas)

        boton = Gtk.Button(label="Aplicar colores", css_classes=["suggested-action"],
                           halign=Gtk.Align.END, margin_top=8, margin_bottom=4)
        boton.connect("clicked", self._al_aplicar_zonas)
        fila_boton = Adw.PreferencesRow(activatable=False)
        fila_boton.set_child(boton)
        grupo.add(fila_boton)
        return grupo

    def _grupo_comportamiento(self) -> Adw.PreferencesGroup:
        """Los interruptores que en Windows trae NitroSense."""
        grupo = Adw.PreferencesGroup(title="Comportamiento")

        self._sw_retro = Adw.SwitchRow(
            title="Apagar el teclado solo",
            subtitle="Se apaga tras unos 30 s sin teclear. Desactivalo para "
                     "dejarlo siempre encendido.",
        )
        if self._tec.retro_timeout is not None:
            self._sw_retro.set_active(self._tec.retro_timeout)
        self._sw_retro.connect("notify::active", self._al_cambiar_retro)
        grupo.add(self._sw_retro)

        opciones = Gtk.StringList()
        for t in ("Desactivada", "Hasta el 10 % de bateria",
                  "Hasta el 20 % de bateria", "Hasta el 30 % de bateria"):
            opciones.append(t)
        self._combo_usb = Adw.ComboRow(
            title="Carga USB con el portatil apagado",
            subtitle="Deja de cargar por debajo del umbral, para no vaciar la bateria",
            model=opciones,
        )
        mapa = {0: 0, 10: 1, 20: 2, 30: 3}
        self._combo_usb.set_selected(mapa.get(self._tec.usb_carga or 0, 0))
        self._combo_usb.connect("notify::selected", self._al_cambiar_usb)
        grupo.add(self._combo_usb)

        self._sw_sonido = Adw.SwitchRow(
            title="Sonido al encender",
            subtitle="El sonido que hace el portatil al arrancar",
        )
        if self._tec.sonido_arranque is not None:
            self._sw_sonido.set_active(self._tec.sonido_arranque)
        self._sw_sonido.connect("notify::active", self._al_cambiar_sonido)
        grupo.add(self._sw_sonido)
        return grupo

    # -- acciones de la pagina de teclado --------------------------------

    def _al_pulsar_preset(self, _boton, nombre: str) -> None:
        self._lanzar_escritura(
            lambda cb: self._control.aplicar_preset(nombre, al_terminar=cb),
            self._refrescar_teclado, lambda: None,
        )

    def _al_aplicar_efecto(self, _boton) -> None:
        modo = self._combo_efecto.get_selected()
        c = self._color_efecto.get_rgba()
        color = (int(c.red * 255), int(c.green * 255), int(c.blue * 255))
        self._lanzar_escritura(
            lambda cb: self._control.escribir_rgb_efecto(
                modo,
                velocidad=int(self._esc_velocidad.get_value()),
                brillo=int(self._esc_brillo.get_value()),
                direccion=self._combo_direccion.get_selected(),
                color=color,
                al_terminar=cb,
            ),
            self._refrescar_teclado, lambda: None,
        )

    def _al_aplicar_zonas(self, _boton) -> None:
        colores = []
        for boton in self._colores_zona:
            c = boton.get_rgba()
            colores.append(
                f"{int(c.red * 255):02x}{int(c.green * 255):02x}{int(c.blue * 255):02x}"
            )
        self._lanzar_escritura(
            lambda cb: self._control.escribir_rgb_zonas(
                colores, brillo=int(self._brillo_zonas.get_value()), al_terminar=cb
            ),
            self._refrescar_teclado, lambda: None,
        )

    def _al_cambiar_retro(self, *_a) -> None:
        if self._cargando:
            return
        deseado = self._sw_retro.get_active()
        previo = self._tec.retro_timeout

        def fallo() -> None:
            if previo is not None:
                self._cargando = True
                self._sw_retro.set_active(previo)
                self._cargando = False

        self._lanzar_escritura(
            lambda cb: self._control.escribir_retro_timeout(deseado, al_terminar=cb),
            self._refrescar_teclado, fallo,
        )

    def _al_cambiar_usb(self, *_a) -> None:
        if self._cargando:
            return
        umbral = (0, 10, 20, 30)[self._combo_usb.get_selected()]
        self._lanzar_escritura(
            lambda cb: self._control.escribir_usb_carga(umbral, al_terminar=cb),
            self._refrescar_teclado, lambda: None,
        )

    def _al_cambiar_sonido(self, *_a) -> None:
        if self._cargando:
            return
        activo = self._sw_sonido.get_active()
        self._lanzar_escritura(
            lambda cb: self._control.escribir_sonido_arranque(activo, al_terminar=cb),
            self._refrescar_teclado, lambda: None,
        )

    def _refrescar_teclado(self) -> None:
        """Relee el estado real tras un cambio. Cuesta ~89 ms: solo aqui."""
        self._tec = self._control.leer_teclado()

    # ------------------------------------------------------------------
    # Acciones del usuario
    # ------------------------------------------------------------------

    def _notificar(self, mensaje: str) -> None:
        """Toast, nunca un dialogo modal para algo trivial."""
        self._toasts.add_toast(Adw.Toast(title=mensaje, timeout=4))

    def _informar(self, resultado: sysfs.Resultado) -> None:
        self._notificar(resultado.mensaje)

    # -- escritura asincrona -------------------------------------------------
    #
    # Las escrituras que necesitan privilegio pasan por pkexec, que abre el
    # dialogo de contrasena de GNOME.  Ese dialogo tarda lo que tarde la
    # persona, asi que la escritura NO puede ser sincrona: congelaria la
    # ventana.  El patron es:
    #   1. Se lanza la escritura pasando un callback.
    #   2. Si la escritura es directa (rutas ya escribibles), el callback llega
    #      al instante; si va por pkexec, llega desde otro hilo cuando el
    #      usuario responde.
    #   3. En ambos casos volvemos al hilo de la interfaz con GLib.idle_add
    #      antes de tocar un solo widget.
    # Mientras tanto la UI se queda mostrando el valor optimista; si falla o el
    # usuario cancela, se revierte.

    def _lanzar_escritura(self, lanzar, al_exito, al_fallo) -> None:
        """*lanzar* recibe el callback y llama al metodo de sysfs con el."""

        def desde_cualquier_hilo(resultado: sysfs.Resultado) -> None:
            GLib.idle_add(self._resolver_escritura, resultado, al_exito, al_fallo)

        lanzar(desde_cualquier_hilo)

    def _resolver_escritura(self, resultado, al_exito, al_fallo) -> bool:
        if resultado.ok:
            al_exito()
        else:
            al_fallo()
        self._notificar(resultado.mensaje)
        return False

    def _al_elegir_perfil(self, *_args) -> None:
        if self._cargando:
            return
        indice = self._combo_perfil.get_selected()
        if indice < 0 or indice >= len(self._perfiles):
            return
        perfil = self._perfiles[indice]
        if perfil == self._perfil_actual:
            return

        anterior = self._perfil_actual

        def al_fallo() -> None:
            # Deshacemos la seleccion visual: la UI no debe mentir.
            if anterior in self._perfiles:
                self._cargando = True
                self._combo_perfil.set_selected(self._perfiles.index(anterior))
                self._cargando = False

        def al_exito() -> None:
            self._perfil_actual = perfil
            # El firmware reescribe el PL1 por MMIO en cada cambio de perfil.
            if self._ajustes.reaplicar_pl1:
                GLib.timeout_add(600, self._reaplicar_pl1)

        self._lanzar_escritura(
            lambda cb: self._control.escribir_perfil(perfil, al_terminar=cb),
            al_exito,
            al_fallo,
        )
        return

    def _reaplicar_pl1(self) -> bool:
        """Reescribe el PL1 que estaba puesto, tras un cambio de perfil.

        Se toma del selector (que refleja el MSR real, y el MSR es el que el
        firmware NO pisa) y no de ajustes.json: si el usuario nunca ha tocado el
        PL1, en ajustes esta el valor por defecto y reaplicarlo cambiaria el
        limite de la CPU sin que nadie lo haya pedido.
        """
        vatios = float(self._spin_pl1.get_value())
        if self._hw_pl1_w is not None and abs(vatios - self._hw_pl1_w) < 0.5:
            vatios = self._hw_pl1_w
        self._lanzar_escritura(
            lambda cb: self._control.escribir_pl1(vatios, ambas=True, al_terminar=cb),
            lambda: None,
            lambda: None,
        )
        return GLib.SOURCE_REMOVE

    def _al_cambiar_pl1(self, *_args) -> None:
        vatios = self._spin_pl1.get_value()
        # Si ya coincide con el hardware no hay nada que escribir: esto absorbe
        # tanto la actualizacion del tic de 1 Hz como cualquier reversion.
        if self._cargando or self._hw_pl1_w is None:
            return
        if abs(vatios - self._hw_pl1_w) < 0.5:
            return
        previo_w = self._hw_pl1_w

        def al_fallo_pl1() -> None:
            # Devolvemos el widget al valor real del hardware.
            self._cargando = True
            self._spin_pl1.set_value(round(previo_w))
            self._cargando = False

        def al_exito_pl1() -> None:
            self._hw_pl1_w = vatios
            # Se guarda SOLO si la escritura ha funcionado: guardarlo antes
            # dejaba en ajustes.json un vatiaje que el hardware nunca acepto, y
            # «Reaplicar PL1» lo habria impuesto en el siguiente cambio de
            # perfil.
            self._ajustes.fijar("pl1_vatios", int(vatios))

        self._lanzar_escritura(
            lambda cb: self._control.escribir_pl1(vatios, ambas=True, al_terminar=cb),
            al_exito_pl1,
            al_fallo_pl1,
        )

    def _al_cambiar_reaplicar(self, *_args) -> None:
        if self._cargando:
            return
        self._ajustes.fijar("reaplicar_pl1", self._sw_reaplicar.get_active())

    def _al_cambiar_turbo(self, *_args) -> None:
        deseado = self._sw_turbo.get_active()
        if self._cargando or self._hw_turbo is None or deseado == self._hw_turbo:
            return
        previo = self._hw_turbo

        def al_fallo() -> None:
            self._cargando = True
            self._sw_turbo.set_active(previo)
            self._cargando = False

        def al_exito() -> None:
            self._hw_turbo = deseado

        # El interruptor esta INVERTIDO respecto a no_turbo.
        self._lanzar_escritura(
            lambda cb: self._control.escribir_no_turbo(not deseado, al_terminar=cb),
            al_exito,
            al_fallo,
        )

    def _al_cambiar_salud(self, *_args) -> None:
        deseado = self._sw_salud.get_active()
        if self._cargando or self._hw_salud is None or deseado == self._hw_salud:
            return
        previo_salud = self._hw_salud

        def al_fallo_salud() -> None:
            self._cargando = True
            self._sw_salud.set_active(previo_salud)
            self._cargando = False

        def al_exito_salud() -> None:
            self._hw_salud = deseado

        self._lanzar_escritura(
            lambda cb: self._control.escribir_health_mode(deseado, al_terminar=cb),
            al_exito_salud,
            al_fallo_salud,
        )
        return
