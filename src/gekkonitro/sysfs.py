"""Capa de acceso al hardware del Acer Nitro AN17-51.

Esta capa NO importa GTK ni GLib: es Python puro para poder probarla sin sesion
grafica.  Todas las funciones de escritura devuelven un ``Resultado`` y NUNCA
lanzan una excepcion hacia la UI.

Costes medidos en la maquina (mediana de 20 lecturas, time.perf_counter):
    fan1_input .......................  0.114 ms
    coretemp temp1_input .............  0.009 ms
    BAT1/capacity ....................  0.008 ms
    rapl constraint_0_power_limit_uw .  0.011 ms
    cpufreq x16 ......................  0.153 ms
    acer-wmi-battery/temperature .....  5.097 ms  <- llamada WMI/ACPI real
    platform_profile (legacy) ........  7.367 ms  <- ¡tambien es ACPI!
    platform-profile-0/profile .......  5.151 ms  <- ¡tambien es ACPI!

De ahi el reparto en dos ciclos: `leer_rapido()` (1 Hz, submilisegundo) solo toca
ficheros baratos, y `leer_lento()` (0,1 Hz) agrupa las tres lecturas ACPI caras.
El contrato del proyecto sugeria releer el perfil en el bucle de 1 Hz; al medirlo
resulta ser la lectura MAS cara de todas, asi que va al ciclo lento (y se relee
al instante despues de que escribamos nosotros el perfil).
"""

from __future__ import annotations

import glob
import os
import shutil
import subprocess
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------
# Rutas del contrato de sysfs (verificadas en la maquina, no inventar)
# --------------------------------------------------------------------------

#: Ruta legacy del perfil.  Es la que notifica los cambios (gotcha 7) y la que
#: escribimos, aunque leamos de la de /sys/class que es un pelin mas barata.
PERFIL_LEGACY = Path("/sys/firmware/acpi/platform_profile")
PERFIL_CLASE = Path("/sys/class/platform-profile/platform-profile-0/profile")
PERFIL_CHOICES = Path("/sys/class/platform-profile/platform-profile-0/choices")

#: PL1 por MSR: es el que manda de verdad (medido: 41,9 W sostenidos con 45 W).
PL1_MSR = Path("/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw")
#: PL1 por MMIO: el firmware lo reescribe al cambiar de perfil (gotcha 4).
PL1_MMIO = Path("/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw")
PL2_MSR = Path("/sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw")
PL_MAX = Path("/sys/class/powercap/intel-rapl:0/constraint_0_max_power_uw")

HEALTH_MODE = Path("/sys/bus/wmi/drivers/acer-wmi-battery/health_mode")
TEMP_BATERIA = Path("/sys/bus/wmi/drivers/acer-wmi-battery/temperature")
NO_TURBO = Path("/sys/devices/system/cpu/intel_pstate/no_turbo")

BAT_CAPACIDAD = Path("/sys/class/power_supply/BAT1/capacity")
BAT_ESTADO = Path("/sys/class/power_supply/BAT1/status")

CPUFREQ_GLOB = "/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"

# --------------------------------------------------------------------------
# Teclado RGB de 4 zonas y extras del EC.
#
# Estas rutas SOLO existen con el driver linuwu_sense cargado
# (packaging/instalar-rgb.sh). Con el acer_wmi del kernel no estan, y la
# aplicacion oculta esa parte de la interfaz en vez de mostrarla en gris.
# --------------------------------------------------------------------------
ACER_WMI = Path("/sys/devices/platform/acer-wmi")
RGB_EFECTO = ACER_WMI / "four_zoned_kb" / "four_zone_mode"
RGB_ZONAS = ACER_WMI / "four_zoned_kb" / "per_zone_mode"
RETRO_TIMEOUT = ACER_WMI / "nitro_sense" / "backlight_timeout"
USB_CARGA = ACER_WMI / "nitro_sense" / "usb_charging"
CALIBRACION = ACER_WMI / "nitro_sense" / "battery_calibration"
SONIDO_ARRANQUE = ACER_WMI / "nitro_sense" / "boot_animation_sound"

#: Los 8 efectos que acepta four_zone_mode, con su nombre en espanol y si
#: necesitan direccion o color. Tomados del driver y de su documentacion.
#: (id, nombre, usa_color, usa_direccion, usa_velocidad)
EFECTOS_RGB = (
    (0, "Fijo",           True,  False, False),
    (1, "Respiracion",    True,  False, True),
    (2, "Neon",           False, False, True),
    (3, "Onda",           False, True,  True),
    (4, "Desplazamiento", True,  True,  True),
    (5, "Zoom",           True,  False, True),
    (6, "Meteorito",      True,  False, True),
    (7, "Destellos",      True,  False, True),
)

#: Presets listos para usar. El usuario pidio "formas bonitas" ya hechas
#: ademas de poder montarse la suya.
#: nombre -> ("efecto", "modo,vel,brillo,dir,R,G,B") | ("zonas", "c,c,c,c,brillo")
PRESETS_RGB = {
    "Arcoiris":      ("zonas",  "ff0000,ffcc00,00ff88,3388ff,100"),
    "Gekko":         ("zonas",  "22d3ee,4ade80,4ade80,f472b6,100"),
    "Hielo":         ("zonas",  "00e5ff,0091ff,0091ff,00e5ff,100"),
    "Magma":         ("zonas",  "ff2d00,ff7300,ffb300,ff2d00,100"),
    "Onda cian":     ("efecto", "3,4,100,1,0,229,255"),
    "Respiracion":   ("efecto", "1,3,100,0,138,43,226"),
    "Meteorito":     ("efecto", "6,5,100,0,255,0,128"),
    "Destellos":     ("efecto", "7,4,100,0,255,255,255"),
    "Neon":          ("efecto", "2,4,100,0,0,0,0"),
    "Blanco fijo":   ("efecto", "0,0,100,0,255,255,255"),
    "Apagado":       ("efecto", "0,0,0,0,0,0,0"),
}

#: Segundos entre lecturas del ciclo lento (ACPI caro).
PERIODO_LENTO = 10.0

#: RPM tipicas medidas por perfil.  Se muestran en la UI como referencia.
RPM_TIPICAS = {
    "low-power": 1663,
    "quiet": 1661,
    "balanced": 2200,
    "balanced-performance": 2377,
    "performance": 3237,
}

#: Nombres bonitos para los perfiles del kernel.
ETIQUETAS_PERFIL = {
    "low-power": "Bajo consumo",
    "quiet": "Silencioso",
    "balanced": "Equilibrado",
    "balanced-performance": "Equilibrado-rendimiento",
    "performance": "Rendimiento",
}

#: Perfil que rompe el menu de energia de GNOME (gotcha 1).
PERFIL_PROBLEMATICO = "balanced-performance"

#: Candidatos para el helper con privilegios.  Si ninguno existe, la escritura
#: no escribible devuelve un error claro en vez de intentar un pkexec imposible.
HELPERS = (
    Path("/usr/lib/nitro-gekko/nitro-gekko-helper"),
    Path("/usr/local/lib/nitro-gekko/nitro-gekko-helper"),
)


# --------------------------------------------------------------------------
# Tipos de retorno
# --------------------------------------------------------------------------


@dataclass(slots=True)
class Resultado:
    """Resultado de una escritura.  Nunca se lanza, siempre se devuelve."""

    ok: bool
    mensaje: str
    #: "directo" | "pkexec" | "ninguno" — como se intento escribir.
    via: str = "ninguno"

    def __bool__(self) -> bool:
        return self.ok


@dataclass(slots=True)
class EstadoRapido:
    """Instantanea barata, se refresca a 1 Hz."""

    fan1: int | None = None
    fan2: int | None = None
    temp_paquete: float | None = None
    pl1_msr_w: float | None = None
    pl1_mmio_w: float | None = None
    pl2_w: float | None = None
    no_turbo: bool | None = None
    bat_capacidad: int | None = None
    bat_estado: str | None = None
    health_mode: bool | None = None
    freq_media_mhz: float | None = None
    #: Coste real de esta lectura, en milisegundos (se muestra en la UI).
    coste_ms: float = 0.0


@dataclass(slots=True)
class EstadoLento:
    """Instantanea cara (ACPI/WMI), se refresca cada PERIODO_LENTO segundos."""

    perfil: str | None = None
    temp_bateria: float | None = None
    coste_ms: float = 0.0


@dataclass(slots=True)
class EstadoTeclado:
    """Estado del teclado RGB y de los extras del EC (driver linuwu_sense)."""

    #: False cuando el driver linuwu_sense no esta cargado: la UI se oculta.
    disponible: bool = False
    #: (modo, velocidad, brillo, direccion, r, g, b) tal cual lo lee el driver.
    efecto: tuple[int, ...] | None = None
    #: ["rrggbb"] x4 + brillo
    zonas: list[str] | None = None
    brillo_zonas: int | None = None
    #: True = la retroiluminacion se apaga sola tras 30 s de inactividad.
    retro_timeout: bool | None = None
    usb_carga: int | None = None
    calibracion: bool | None = None
    sonido_arranque: bool | None = None


@dataclass(slots=True)
class Diagnostico:
    """Que falta para que la app pueda funcionar."""

    hay_perfil: bool = False
    hay_hwmon_acer: bool = False
    faltantes: list[str] = field(default_factory=list)

    @property
    def utilizable(self) -> bool:
        return self.hay_perfil and self.hay_hwmon_acer


# --------------------------------------------------------------------------
# Utilidades de lectura tolerantes a fallo
# --------------------------------------------------------------------------


def _leer_texto(ruta: Path | str) -> str | None:
    """Lee un fichero de sysfs.  Devuelve None ante cualquier problema."""
    try:
        with open(ruta, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except (OSError, ValueError):
        return None


def _leer_int(ruta: Path | str) -> int | None:
    texto = _leer_texto(ruta)
    if texto is None:
        return None
    try:
        return int(texto.split()[0])
    except (ValueError, IndexError):
        return None


# --------------------------------------------------------------------------
# Control principal
# --------------------------------------------------------------------------


class ControlNitro:
    """Acceso cacheado y barato al hardware del portatil."""

    def __init__(self) -> None:
        # Cache de rutas hwmon resueltas POR NOMBRE.  El numero de hwmon no es
        # estable entre arranques (gotcha 6), asi que guardamos el Path pero lo
        # revalidamos en cada uso.
        self._cache_hwmon: dict[str, Path] = {}
        self._perfiles: list[str] | None = None

    # -- resolucion de hwmon ------------------------------------------------

    def _hwmon(self, nombre: str) -> Path | None:
        """Devuelve el directorio hwmon cuyo 'name' contiene *nombre*.

        Cachea el resultado y lo revalida: si el directorio desaparece o el
        fichero 'name' ya no encaja (reasignacion tras un rearranque en caliente
        del modulo), se vuelve a buscar.
        """
        cacheado = self._cache_hwmon.get(nombre)
        if cacheado is not None:
            actual = _leer_texto(cacheado / "name")
            if actual is not None and nombre in actual:
                return cacheado
            # Cache invalido: la ruta ya no es lo que creiamos.
            del self._cache_hwmon[nombre]

        for directorio in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
            ruta = Path(directorio)
            actual = _leer_texto(ruta / "name")
            if actual is not None and nombre in actual:
                self._cache_hwmon[nombre] = ruta
                return ruta

        # Plan B para el acer: la ruta de plataforma directa.
        if nombre == "acer":
            for directorio in sorted(
                glob.glob("/sys/devices/platform/acer-wmi/hwmon/hwmon*")
            ):
                ruta = Path(directorio)
                self._cache_hwmon[nombre] = ruta
                return ruta
        return None

    def ruta_hwmon_acer(self) -> Path | None:
        return self._hwmon("acer")

    def ruta_hwmon_coretemp(self) -> Path | None:
        return self._hwmon("coretemp")

    # -- diagnostico de hardware -------------------------------------------

    def diagnosticar(self) -> Diagnostico:
        """Comprueba si el hardware minimo esta presente."""
        diag = Diagnostico()
        diag.hay_perfil = PERFIL_CHOICES.exists() or PERFIL_LEGACY.exists()
        if not diag.hay_perfil:
            diag.faltantes.append(
                "No existe /sys/firmware/acpi/platform_profile. El firmware ACPI "
                "no expone perfiles de plataforma: comprueba que arrancas con un "
                "kernel reciente y sin 'acpi=off'."
            )
        diag.hay_hwmon_acer = self.ruta_hwmon_acer() is not None
        if not diag.hay_hwmon_acer:
            diag.faltantes.append(
                "No hay ningun hwmon llamado 'acer'. Carga el modulo con "
                "'sudo modprobe acer_wmi' y revisa 'dmesg | grep acer'."
            )
        return diag

    # -- perfiles ----------------------------------------------------------

    def perfiles(self, refrescar: bool = False) -> list[str]:
        """Lista de perfiles LEIDA de 'choices'.  Nunca codificada a fuego."""
        if self._perfiles is not None and not refrescar:
            return self._perfiles
        texto = _leer_texto(PERFIL_CHOICES)
        if not texto:
            # Sin 'choices' no inventamos: lista vacia y la UI lo refleja.
            self._perfiles = []
        else:
            self._perfiles = texto.split()
        return self._perfiles

    def perfil_actual(self) -> str | None:
        """Perfil activo.  OJO: ~5 ms, es una llamada ACPI. Va en ciclo lento."""
        return _leer_texto(PERFIL_CLASE) or _leer_texto(PERFIL_LEGACY)

    # -- ciclos de lectura --------------------------------------------------

    def leer_rapido(self) -> EstadoRapido:
        """Ciclo de 1 Hz.  Solo ficheros baratos: cuesta menos de 1 ms."""
        inicio = time.perf_counter()
        est = EstadoRapido()

        acer = self.ruta_hwmon_acer()
        if acer is not None:
            est.fan1 = _leer_int(acer / "fan1_input")
            est.fan2 = _leer_int(acer / "fan2_input")

        coretemp = self.ruta_hwmon_coretemp()
        if coretemp is not None:
            crudo = _leer_int(coretemp / "temp1_input")
            if crudo is not None:
                est.temp_paquete = crudo / 1000.0

        for atributo, ruta in (
            ("pl1_msr_w", PL1_MSR),
            ("pl1_mmio_w", PL1_MMIO),
            ("pl2_w", PL2_MSR),
        ):
            crudo = _leer_int(ruta)
            if crudo is not None:
                setattr(est, atributo, crudo / 1_000_000.0)

        crudo = _leer_int(NO_TURBO)
        if crudo is not None:
            est.no_turbo = bool(crudo)

        est.bat_capacidad = _leer_int(BAT_CAPACIDAD)
        est.bat_estado = _leer_texto(BAT_ESTADO)

        crudo = _leer_int(HEALTH_MODE)
        if crudo is not None:
            est.health_mode = bool(crudo)

        est.freq_media_mhz = self._frecuencia_media()

        est.coste_ms = (time.perf_counter() - inicio) * 1000.0
        return est

    def leer_lento(self) -> EstadoLento:
        """Ciclo de 0,1 Hz.  Agrupa las lecturas ACPI/WMI caras (~10 ms)."""
        inicio = time.perf_counter()
        est = EstadoLento()
        est.perfil = self.perfil_actual()
        crudo = _leer_int(TEMP_BATERIA)
        if crudo is not None:
            # 33000 son 33,0 C: es simplemente /1000.  La formula (v-2731)*100
            # es la conversion INTERNA del driver y aqui daria 3056900.
            est.temp_bateria = crudo / 1000.0
        est.coste_ms = (time.perf_counter() - inicio) * 1000.0
        return est

    def _frecuencia_media(self) -> float | None:
        """Media de scaling_cur_freq de todos los nucleos, en MHz."""
        valores = []
        for ruta in glob.glob(CPUFREQ_GLOB):
            khz = _leer_int(ruta)
            if khz is not None:
                valores.append(khz)
        if not valores:
            return None
        return sum(valores) / len(valores) / 1000.0

    def pl1_maximo_w(self) -> float:
        """Maximo nominal declarado por el chip (45 W en el i7-13620H)."""
        crudo = _leer_int(PL_MAX)
        return crudo / 1_000_000.0 if crudo else 45.0

    # -- escrituras ---------------------------------------------------------

    @staticmethod
    def _helper() -> Path | None:
        """Primer helper con privilegios que exista, o None."""
        for ruta in HELPERS:
            if ruta.exists():
                return ruta
        return None

    def _escribir(
        self,
        ruta: Path,
        valor: str,
        etiqueta: str,
        exito: str | None = None,
        accion: str | None = None,
        valor_helper: str | None = None,
        al_terminar: "Callable[[Resultado], None] | None" = None,
    ) -> Resultado:
        """Escribe *valor* en *ruta*, con fallback al helper por pkexec.

        SOBRE *accion* Y *valor_helper*
        --------------------------------
        El helper NO recibe rutas.  Antes se le pasaba `str(ruta)` como
        argumento, y eso era un agujero de escalada de privilegios: cualquier
        proceso que corriese como el usuario podia pedirle que escribiera como
        root en cualquier fichero.  Ahora cruza la frontera de privilegio solo
        un NOMBRE DE ACCION de un conjunto cerrado («perfil», «pl1»,
        «bateria», «turbo») y su valor; la lista blanca de rutas vive dentro
        del helper.  Si una escritura no tiene accion asociada, simplemente no
        hay camino privilegiado para ella.

        SOBRE *al_terminar*
        -------------------
        La escritura directa es instantanea, pero la de pkexec abre un dialogo
        de contrasena que tarda lo que tarde el usuario.  Hacerla sincrona
        congelaba la ventana.  Si se pasa *al_terminar*, la parte lenta corre
        en un hilo y el callback recibe el Resultado desde ESE hilo (quien
        llama es responsable de volver al hilo de la interfaz, normalmente con
        GLib.idle_add).  Sin *al_terminar* el comportamiento es el de siempre,
        sincrono, que es lo que usan las pruebas.

        *etiqueta* es un SINTAGMA NOMINAL («el Turbo Boost», «el perfil ...»)
        porque se incrusta en «No se pudo cambiar {etiqueta}: ...».  El mensaje
        de exito lo pone quien llama en *exito*, porque una frase que encaje en
        el fallo casi nunca encaja tambien en el acierto: con una sola etiqueta
        salian toasts como «Turbo Boost desactivado aplicado.» o «la carga
        completa aplicado.».

        Estrategia obligatoria:
          1. Si os.access(ruta, W_OK) -> escritura directa.
          2. Si no -> helper por pkexec.
          3. Si no hay helper o pkexec -> error claro, nunca una excepcion.
        """
        hecho = exito or f"Cambiado {etiqueta}."

        def entregar(r: Resultado) -> Resultado:
            if al_terminar is not None:
                al_terminar(r)
            return r

        if not ruta.exists():
            return entregar(Resultado(
                False,
                f"No se pudo cambiar {etiqueta}: la ruta {ruta} no existe en este "
                f"sistema.",
            ))

        # 1) Escritura directa si el usuario tiene permiso (solo si se
        #    instalaron las reglas udev opcionales con --con-udev).
        if os.access(ruta, os.W_OK):
            try:
                with open(ruta, "w", encoding="ascii") as fh:
                    fh.write(valor)
                return entregar(Resultado(True, hecho, via="directo"))
            except OSError as err:
                # El kernel puede rechazar el valor aunque el fichero sea RW.
                return entregar(Resultado(
                    False, f"El kernel rechazo {etiqueta}: {err.strerror}.",
                    via="directo",
                ))

        # 2) Camino privilegiado: helper + pkexec (el portal de GNOME).
        if accion is None:
            return entregar(Resultado(
                False,
                f"No se pudo cambiar {etiqueta}: {ruta} no es escribible y esta "
                f"operacion no tiene una accion privilegiada asociada.",
            ))
        helper = self._helper()
        if helper is None:
            return entregar(Resultado(
                False,
                f"No se pudo cambiar {etiqueta}: {ruta} no es escribible por tu "
                f"usuario y no esta instalado el helper de Nitro Gekko. Ejecuta "
                f"el instalador del proyecto.",
            ))
        if shutil.which("pkexec") is None:
            return entregar(Resultado(
                False,
                f"No se pudo cambiar {etiqueta}: hace falta pkexec (polkit) y no "
                f"esta instalado.",
            ))

        argv = ["pkexec", str(helper), accion, valor_helper if valor_helper is not None else valor]

        def ejecutar() -> Resultado:
            try:
                proceso = subprocess.run(
                    argv, capture_output=True, text=True, timeout=180
                )
            except subprocess.TimeoutExpired:
                return Resultado(
                    False,
                    f"El dialogo de autorizacion no respondio a tiempo; "
                    f"{etiqueta} no se ha cambiado.",
                    via="pkexec",
                )
            except OSError as err:
                return Resultado(
                    False, f"No se pudo lanzar el helper para {etiqueta}: {err}",
                    via="pkexec",
                )
            codigo = proceso.returncode
            if codigo == 0:
                return Resultado(True, hecho, via="pkexec")
            if codigo == 126:
                # pkexec: el usuario cerro el dialogo o no esta autorizado.
                return Resultado(
                    False, f"Autorizacion cancelada: {etiqueta} no se ha cambiado.",
                    via="pkexec",
                )
            if codigo == 127:
                return Resultado(
                    False,
                    f"No se encontro el helper de Nitro Gekko. Reinstala el "
                    f"proyecto.",
                    via="pkexec",
                )
            detalle = (proceso.stderr or "").strip() or f"codigo {codigo}"
            return Resultado(
                False, f"No se pudo cambiar {etiqueta}: {detalle}", via="pkexec"
            )

        # El dialogo de contrasena puede tardar lo que tarde la persona: si nos
        # dieron callback, no bloqueamos el hilo de la interfaz.
        if al_terminar is not None:
            threading.Thread(
                target=lambda: al_terminar(ejecutar()),
                name=f"nitro-pkexec-{accion}",
                daemon=True,
            ).start()
            return Resultado(True, "Esperando autorizacion...", via="pkexec")

        return ejecutar()

    def como_se_escribiria(self, ruta: Path) -> str:
        """Diagnostico SIN escribir: dice que via se usaria para esa ruta.

        Se usa en las pruebas y para el tooltip de la UI, de modo que no haga
        falta tocar sysfs para saber si la app podra actuar.
        """
        if not ruta.exists():
            return "imposible: la ruta no existe"
        if os.access(ruta, os.W_OK):
            return "directo"
        if self._helper() is None:
            return "imposible: sin permiso y sin helper instalado"
        if shutil.which("pkexec") is None:
            return "imposible: sin permiso y sin pkexec"
        return "pkexec"

    def escribir_perfil(
        self, perfil: str, al_terminar: Callable[[Resultado], None] | None = None
    ) -> Resultado:
        """Cambia el perfil termico.

        Escribe en la ruta LEGACY porque es la que notifica el cambio al resto
        del sistema (power-profiles-daemon la vigila con GFileMonitor).
        """
        validos = self.perfiles()
        if validos and perfil not in validos:
            return Resultado(False, f"'{perfil}' no es un perfil valido en este equipo.")
        bonito = ETIQUETAS_PERFIL.get(perfil, perfil)
        return self._escribir(
            PERFIL_LEGACY,
            perfil,
            f"el perfil «{bonito}»",
            exito=f"Perfil «{bonito}» aplicado.",
            accion="perfil",
            al_terminar=al_terminar,
        )

    def escribir_pl1(
        self,
        vatios: float,
        ambas: bool = True,
        al_terminar: Callable[[Resultado], None] | None = None,
    ) -> Resultado:
        """Fija PL1 en vatios.  Por defecto escribe MSR y MMIO.

        El MSR es el que manda; el MMIO se escribe tambien porque el firmware lo
        reescribe al cambiar de perfil y dejarlo descolgado confunde a quien mire
        las lecturas (gotcha 4).
        """
        uw = str(int(round(vatios * 1_000_000)))
        principal = self._escribir(
            PL1_MSR,
            uw,
            "el PL1 del MSR",
            exito=f"PL1 fijado a {vatios:.0f} W.",
            accion="pl1",
            # El helper recibe VATIOS, no microvatios: su rango duro esta en
            # vatios y asi el valor que se audita en el journal es legible.
            valor_helper=str(int(round(vatios))),
            al_terminar=al_terminar,
        )
        # Por la via privilegiada el helper ya escribe MSR y MMIO de una vez,
        # asi que no hay segunda llamada (seria un segundo dialogo de
        # contrasena para la misma accion del usuario).
        if principal.via == "pkexec":
            return principal
        if not principal.ok or not ambas:
            return principal
        secundario = self._escribir(
            PL1_MMIO,
            uw,
            "el PL1 del MMIO",
            exito=f"PL1 fijado a {vatios:.0f} W en el MMIO.",
        )
        if not secundario.ok:
            # El MSR, que es el que manda, si se aplico: no es un fallo total.
            return Resultado(
                True,
                f"PL1 a {vatios:.0f} W aplicado en el MSR (el que manda); el MMIO "
                f"no se pudo escribir.",
                via=principal.via,
            )
        return Resultado(True, f"PL1 fijado a {vatios:.0f} W.", via=principal.via)

    def escribir_health_mode(
        self, activar: bool, al_terminar: Callable[[Resultado], None] | None = None
    ) -> Resultado:
        """Limite de carga al 80 %.  Conmuta en caliente, sin recargar modulo."""
        if activar:
            etiqueta = "el limite de carga al 80 %"
            exito = "Limite de carga al 80 % activado."
        else:
            etiqueta = "el limite de carga de la bateria"
            exito = "Limite de carga desactivado: la bateria cargara al 100 %."
        return self._escribir(
            HEALTH_MODE, "1" if activar else "0", etiqueta, exito=exito,
            accion="bateria", al_terminar=al_terminar,
        )

    def escribir_no_turbo(
        self, sin_turbo: bool, al_terminar: Callable[[Resultado], None] | None = None
    ) -> Resultado:
        """no_turbo: 0 = turbo activo, 1 = desactivado."""
        exito = (
            "Turbo Boost desactivado." if sin_turbo else "Turbo Boost activado."
        )
        return self._escribir(
            NO_TURBO, "1" if sin_turbo else "0", "el Turbo Boost", exito=exito,
            accion="turbo", al_terminar=al_terminar,
        )

    # ----------------------------------------------------------------------
    # Teclado RGB de 4 zonas y extras del EC (driver linuwu_sense)
    # ----------------------------------------------------------------------

    def hay_teclado_rgb(self) -> bool:
        """True si el driver linuwu_sense esta cargado y expone el RGB."""
        return RGB_EFECTO.exists() and RGB_ZONAS.exists()

    def leer_teclado(self) -> EstadoTeclado:
        """Lee todo el estado del teclado y de los extras del EC.

        Es una lectura CARA: cada atributo de este grupo es una llamada WMI
        real al firmware, del mismo orden que platform_profile (~5-7 ms cada
        una). No la metas en el bucle de 1 Hz: la pagina de iluminacion la
        pide al abrirse y despues de cada cambio, y con eso basta.
        """
        est = EstadoTeclado()
        if not self.hay_teclado_rgb():
            return est
        est.disponible = True

        crudo = _leer_texto(RGB_EFECTO)
        if crudo:
            try:
                est.efecto = tuple(int(x) for x in crudo.split(","))
            except ValueError:
                est.efecto = None

        crudo = _leer_texto(RGB_ZONAS)
        if crudo:
            partes = crudo.split(",")
            if len(partes) >= 4:
                est.zonas = [p.strip().lower() for p in partes[:4]]
                if len(partes) >= 5:
                    try:
                        est.brillo_zonas = int(partes[4])
                    except ValueError:
                        pass

        v = _leer_int(RETRO_TIMEOUT)
        est.retro_timeout = None if v is None or v < 0 else bool(v)
        est.usb_carga = _leer_int(USB_CARGA)
        v = _leer_int(CALIBRACION)
        est.calibracion = None if v is None else bool(v)
        v = _leer_int(SONIDO_ARRANQUE)
        est.sonido_arranque = None if v is None else bool(v)
        return est

    def escribir_rgb_efecto(
        self,
        modo: int,
        velocidad: int = 4,
        brillo: int = 100,
        direccion: int = 1,
        color: tuple[int, int, int] = (255, 255, 255),
        al_terminar: Callable[[Resultado], None] | None = None,
    ) -> Resultado:
        """Aplica uno de los 8 efectos animados del firmware.

        Los modos 3 (Onda) y 4 (Desplazamiento) EXIGEN direccion 1 o 2; con 0
        el driver devuelve -EINVAL. Se corrige aqui en vez de dejar que el
        usuario reciba un error de E/S sin explicacion.
        """
        if modo in (3, 4) and direccion == 0:
            direccion = 1
        r, g, b = color
        valor = f"{modo},{velocidad},{brillo},{direccion},{r},{g},{b}"
        nombre = next((n for i, n, *_ in EFECTOS_RGB if i == modo), f"modo {modo}")
        return self._escribir(
            RGB_EFECTO, valor, f"el efecto «{nombre}»",
            exito=f"Efecto «{nombre}» aplicado.",
            accion="rgb_efecto", valor_helper=valor, al_terminar=al_terminar,
        )

    def escribir_rgb_zonas(
        self,
        colores: list[str],
        brillo: int = 100,
        al_terminar: Callable[[Resultado], None] | None = None,
    ) -> Resultado:
        """Color fijo e independiente para cada una de las 4 zonas.

        *colores* son cuatro cadenas 'rrggbb' sin almohadilla, de izquierda a
        derecha del teclado.
        """
        if len(colores) != 4:
            return Resultado(False, "Hacen falta exactamente 4 colores, uno por zona.")
        limpios = [c.lstrip("#").lower() for c in colores]
        valor = ",".join(limpios) + f",{brillo}"
        return self._escribir(
            RGB_ZONAS, valor, "los colores del teclado",
            exito="Colores del teclado aplicados.",
            accion="rgb_zonas", valor_helper=valor, al_terminar=al_terminar,
        )

    def aplicar_preset(
        self, nombre: str, al_terminar: Callable[[Resultado], None] | None = None
    ) -> Resultado:
        """Aplica uno de los presets de PRESETS_RGB por su nombre."""
        entrada = PRESETS_RGB.get(nombre)
        if entrada is None:
            return Resultado(False, f"No existe el preset «{nombre}».")
        tipo, valor = entrada
        ruta = RGB_ZONAS if tipo == "zonas" else RGB_EFECTO
        accion = "rgb_zonas" if tipo == "zonas" else "rgb_efecto"
        return self._escribir(
            ruta, valor, f"el estilo «{nombre}»",
            exito=f"Estilo «{nombre}» aplicado.",
            accion=accion, valor_helper=valor, al_terminar=al_terminar,
        )

    def escribir_retro_timeout(
        self, apagar_solo: bool, al_terminar: Callable[[Resultado], None] | None = None
    ) -> Resultado:
        """Retroiluminacion: apagado automatico por inactividad, o siempre encendida.

        Es el interruptor que en Windows trae NitroSense. El firmware apaga la
        retroiluminacion tras unos 30 segundos sin teclear cuando esta a 1.
        """
        exito = (
            "El teclado se apagara solo tras unos segundos sin usarlo."
            if apagar_solo else
            "El teclado se quedara siempre encendido."
        )
        return self._escribir(
            RETRO_TIMEOUT, "1" if apagar_solo else "0",
            "el apagado automatico del teclado", exito=exito,
            accion="retro_timeout", al_terminar=al_terminar,
        )

    def escribir_usb_carga(
        self, umbral: int, al_terminar: Callable[[Resultado], None] | None = None
    ) -> Resultado:
        """Umbral de bateria por debajo del cual deja de cargar por USB apagado.

        Solo 0, 10, 20 y 30. El driver interpreta cualquier otro valor como 0
        en silencio, asi que se valida antes.
        """
        if umbral not in (0, 10, 20, 30):
            return Resultado(False, "La carga USB solo admite 0, 10, 20 o 30.")
        exito = (
            "Carga USB con el portatil apagado desactivada." if umbral == 0
            else f"Carga USB activa mientras la bateria supere el {umbral} %."
        )
        return self._escribir(
            USB_CARGA, str(umbral), "la carga USB", exito=exito,
            accion="usb_carga", al_terminar=al_terminar,
        )

    def escribir_sonido_arranque(
        self, activo: bool, al_terminar: Callable[[Resultado], None] | None = None
    ) -> Resultado:
        """El sonido que hace el portatil al encenderse."""
        exito = "Sonido de arranque activado." if activo else "Sonido de arranque silenciado."
        return self._escribir(
            SONIDO_ARRANQUE, "1" if activo else "0", "el sonido de arranque",
            exito=exito, accion="sonido_arranque", al_terminar=al_terminar,
        )


# --------------------------------------------------------------------------
# GPU NVIDIA (fuera del bucle de 1 Hz: nvidia-smi despierta la GPU)
# --------------------------------------------------------------------------


@dataclass(slots=True)
class EstadoGpu:
    vatios: float | None = None
    temperatura: float | None = None
    pstate: str | None = None
    disponible: bool = False


def leer_gpu(timeout: float = 2.0) -> EstadoGpu:
    """Consulta nvidia-smi.  Pensada para llamarse en un hilo, cada 5 s.

    Si nvidia-smi no existe, tarda demasiado o devuelve basura, se informa con
    disponible=False y la UI oculta la fila en vez de bloquearse.
    """
    est = EstadoGpu()
    if shutil.which("nvidia-smi") is None:
        return est
    try:
        proceso = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=power.draw,temperature.gpu,pstate",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return est
    if proceso.returncode != 0:
        return est
    partes = [p.strip() for p in proceso.stdout.strip().split(",")]
    if len(partes) < 3:
        return est
    try:
        est.vatios = float(partes[0])
        est.temperatura = float(partes[1])
    except ValueError:
        # Algunas GPU devuelven [N/A]; sigue siendo util el pstate.
        pass
    est.pstate = partes[2]
    est.disponible = est.temperatura is not None
    return est
