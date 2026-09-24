"""Capa de acceso al hardware del Acer Nitro AN17-51.

Esta capa NO importa GTK ni GLib: es Python puro para poder probarla sin sesion
grafica.  Todas las funciones de escritura devuelven un ``Resultado`` y NUNCA
lanzan una excepcion hacia la UI.

Costes medidos en la maquina (mediana de 20 lecturas, time.perf_counter):
    fan1_input .......................  0.114 ms
    coretemp temp1_input .............  0.009 ms
    <bateria>/capacity ...............  0.008 ms
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

Coste de las tres funciones publicas, medido con time.perf_counter (mediana de
15 llamadas seguidas, maquina en reposo):

    leer_rapido() ...   0,6 ms         -> ciclo de 1 Hz
    leer_lento() ....  10,0 ms         -> ciclo de 10 s
    leer_teclado() ..  47 a 53 ms      -> SOLO al abrir la pagina y tras un cambio

El desglose de leer_teclado() explica el numero: per_zone_mode 25,5 ms,
usb_charging 7,1 ms, four_zone_mode 5,1 ms, backlight_timeout 5,1 ms,
boot_animation_sound 5,0 ms; suman 47,8 ms.  Cada uno es una llamada WMI real
al firmware.  Por eso `leer_teclado()` NO se llama nunca desde un temporizador:
los unicos dos sitios que la invocan son la construccion de la pagina de
teclado y el refresco posterior a una escritura del usuario.

Lecturas anadidas el 2026-09-23 para igualar a NitroSense.  Se escribieron desde
Windows y se midieron en la maquina el mismo dia, ya en Linux (mediana de 200
lecturas, 20 en las de firmware):

    /proc/stat ........................  0,017 ms                -> 1 Hz
    /proc/meminfo .....................  0,008 ms                -> 1 Hz
    ACAD/online .......................  0,054 ms  (_PSR)        -> 10 s
    BAT1/charge_full(_design) .........  0,008 ms                -> 10 s
    module/.../cycle_gaming_thermal_profile  0,007 ms            -> bajo demanda
    nitro_sense/battery_calibration ...  5,4 ms    <- WMI real   -> bajo demanda

Los dos ciclos, medidos otra vez en las mismas condiciones contra la version
anterior: leer_lento() 10,4 ms frente a 10,2; leer_rapido() sin diferencia.
Lo que se temia del cargador no se cumple: 'online' cuesta cien veces menos que
leer el perfil.  Sigue en el ciclo de 10 s porque ahi basta, no por su coste.
En este equipo la bateria publica charge_* (uAh), no energy_*.
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
PL_MAX = Path("/sys/class/powercap/intel-rapl:0/constraint_0_max_power_uw")

HEALTH_MODE = Path("/sys/bus/wmi/drivers/acer-wmi-battery/health_mode")
TEMP_BATERIA = Path("/sys/bus/wmi/drivers/acer-wmi-battery/temperature")
NO_TURBO = Path("/sys/devices/system/cpu/intel_pstate/no_turbo")

#: Directorio de las fuentes de alimentacion.  El nodo de LA bateria del
#: portatil se resuelve por contenido, NO por nombre: aqui se llama ``BAT1``,
#: pero el nombre lo pone el firmware ACPI y en otros equipos es ``BAT0``.
#: Ademas cuelgan aqui las baterias de los perifericos (un raton inalambrico
#: aparece como ``hidpp_battery_0`` con ``type=Battery``), que se descartan
#: por ``scope=Device``.  Ver ``_bateria_base()``.
POWER_SUPPLY = Path("/sys/class/power_supply")

CPUFREQ_GLOB = "/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"

#: Contadores del kernel para el uso de CPU y de memoria que NitroSense ensena
#: en su pagina de supervision (CPU_USAGE y RAM_USAGE de GET_MONITOR_DATA).
PROC_STAT = Path("/proc/stat")
PROC_MEMINFO = Path("/proc/meminfo")

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
SONIDO_ARRANQUE = ACER_WMI / "nitro_sense" / "boot_animation_sound"

#: Velocidad manual de los ventiladores, "cpu,gpu" en por ciento.  0,0 es
#: AUTOMATICO (manda el EC), que es tambien la vuelta atras.
#:
#: OJO, es la excepcion del grupo: cuesta 0,007 ms (mediana de 25 lecturas),
#: no 5 ms como sus vecinos, porque el driver devuelve dos variables suyas en
#: vez de preguntarle al firmware.  Por eso ESTA si cabe en el ciclo de 1 Hz.
VENTILADORES = ACER_WMI / "nitro_sense" / "fan_speed"

#: Overdrive del panel.  Lectura de 5,2 ms: WMI de verdad, solo bajo demanda.
OVERDRIVE = ACER_WMI / "nitro_sense" / "lcd_override"

#: Limite de carga POR EL EC, el equivalente de HEALTH_MODE sin depender del
#: modulo del AUR.  Lectura de 4,9 ms (WMI) frente a los 0,006 ms de
#: HEALTH_MODE: ver fuente_limite_carga().
BAT_LIMITER = ACER_WMI / "nitro_sense" / "battery_limiter"

#: Calibracion de la bateria: 1 mientras dura un ciclo, 0 si no.
#:
#: Antes la aplicacion NO la exponia (regla 15 del README): un ciclo descarga y
#: recarga la bateria entera durante horas y no podia quedar a un clic.  El
#: 2026-09-23 el usuario pidio tenerla igual que en NitroSense, que la ofrece
#: (via Care Center) detras de un asistente de avisos.  Se expone ASI, y solo
#: asi: detras de un dialogo de confirmacion, con el cargador conectado, y
#: sin reponerse nunca al arrancar (el helper sigue sin anotarla).
#:
#: Se lee BAJO DEMANDA y nunca desde un temporizador: son 4,9 ms de WMI, y antes
#: se leia en cada refresco del teclado sin que nadie mirase el resultado.
CALIBRACION = ACER_WMI / "nitro_sense" / "battery_calibration"

#: Que hace la tecla de modo del portatil.  Es un parametro del modulo, no un
#: atributo del firmware: el que gira los modos al pulsarla es el propio
#: linuwu_sense (acer_thermal_profile_change(), en rgb/src/linuwu_sense.c).
#:   Y -> recorre los modos: Silencioso > Equilibrado > Rendimiento > Turbo
#:        con cargador, y Equilibrado <-> Eco con bateria.
#:   N -> activa y desactiva el Turbo, volviendo al modo que hubiera.
#: Son las dos opciones de NitroSense («Mode Cycle Switching» y «Turbo On/Off»).
#: El acer_wmi de mainline tiene un parametro con el mismo nombre, pero en el
#: AN17-51 su tecla va por otro camino (acer_toggle_turbo), asi que solo se
#: ofrece con linuwu_sense.
TECLA_MODO = Path("/sys/module/linuwu_sense/parameters/cycle_gaming_thermal_profile")

#: Los 8 efectos que acepta four_zone_mode, con su nombre en espanol y que
#: parametros usa cada uno.  NO estan copiados de ninguna documentacion: salen
#: del switch de four_zoned_rgb_kb_store() en rgb/src/linuwu_sense.c, que es
#: quien pone a cero los parametros que el modo no usa antes de mandarlos al
#: firmware.  Por eso «Onda cian» no salia cian: el driver borra el color en el
#: modo 3 (comprobado: se escribio 0,229,255 y four_zone_mode devuelve 0,0,0).
#: (id, nombre, usa_color, usa_direccion, usa_velocidad)
EFECTOS_RGB = (
    (0, "Fijo",           True,  False, False),  # speed=0, direction=0
    (1, "Respiracion",    True,  False, False),  # speed=0, direction=0
    (2, "Neon",           False, False, True),   # rgb=0, direction=0
    (3, "Onda",           False, True,  True),   # rgb=0, exige direction>0
    (4, "Desplazamiento", True,  True,  True),   # sin restricciones
    (5, "Zoom",           True,  False, True),   # direction=0
    (6, "Meteorito",      True,  False, True),   # direction=0
    (7, "Destellos",      True,  False, True),   # direction=0
)

#: Presets listos para usar. El usuario pidio "formas bonitas" ya hechas
#: ademas de poder montarse la suya.
#: nombre -> ("efecto", "modo,vel,brillo,dir,R,G,B") | ("zonas", "c,c,c,c,brillo")
PRESETS_RGB = {
    "Arcoiris":      ("zonas",  "ff0000,ffcc00,00ff88,3388ff,100"),
    "Gekko":         ("zonas",  "22d3ee,4ade80,4ade80,f472b6,100"),
    "Hielo":         ("zonas",  "00e5ff,0091ff,0091ff,00e5ff,100"),
    "Magma":         ("zonas",  "ff2d00,ff7300,ffb300,ff2d00,100"),
    # El modo 3 ignora el RGB (lo pone a cero el driver), asi que ni se
    # manda un color ni se promete uno en el nombre.
    "Onda":          ("efecto", "3,4,100,1,0,0,0"),
    "Respiracion":   ("efecto", "1,3,100,0,138,43,226"),
    "Meteorito":     ("efecto", "6,5,100,0,255,0,128"),
    "Destellos":     ("efecto", "7,4,100,0,255,255,255"),
    "Neon":          ("efecto", "2,4,100,0,0,0,0"),
    "Blanco fijo":   ("efecto", "0,0,100,0,255,255,255"),
    # El color de fabrica de NitroSense: #ffa000 en los tres escenarios que
    # trae de serie (leido de ProfilePool/config.json en Windows).  Es el que
    # usa el escenario «Ocasion tranquila».
    "Naranja Nitro": ("efecto", "0,0,100,0,255,160,0"),
    "Apagado":       ("efecto", "0,0,0,0,0,0,0"),
}

#: RPM tipicas medidas por perfil.  Se muestran en la UI como referencia.
RPM_TIPICAS = {
    "low-power": 1663,
    "quiet": 1661,
    "balanced": 2200,
    "balanced-performance": 2377,
    "performance": 3237,
}

#: Nombres de los perfiles del kernel, LOS MISMOS QUE PONE NITROSENSE.
#:
#: Antes eran traducciones literales («Bajo consumo», «Equilibrado-rendimiento»,
#: «Rendimiento»), y la de «performance» confundia: ese perfil NO es el
#: Rendimiento de NitroSense, es su Turbo.  La correspondencia sale del driver
#: (acer_predator_v4_platform_profile_get(), en rgb/src/linuwu_sense.c):
#:
#:     firmware ECO         -> low-power             -> «Eco»
#:     firmware QUIET       -> quiet                 -> «Silencioso»
#:     firmware BALANCED    -> balanced              -> «Equilibrado»
#:     firmware PERFORMANCE -> balanced-performance  -> «Rendimiento»
#:     firmware TURBO       -> performance           -> «Turbo»
#:
#: y los nombres, de las cadenas de NitroSense 5.0 en espanol
#: (MUI_Operating_Mode_*): Silencioso, Equilibrado, Rendimiento, Turbo y Eco.
#: Asi el mismo modo se llama igual en los dos sistemas del arranque dual.
ETIQUETAS_PERFIL = {
    "low-power": "Eco",
    "quiet": "Silencioso",
    "balanced": "Equilibrado",
    "balanced-performance": "Rendimiento",
    "performance": "Turbo",
}

#: Perfiles que NitroSense ofrece con la bateria.  Leido del propio NitroSense
#: 5.0 (onBatteryPowerMode(): DEFAULT y ECO) y confirmado por el driver, que con
#: bateria RECHAZA quiet, balanced-performance y performance con -EOPNOTSUPP
#: (acer_predator_v4_platform_profile_set: «in official version this is not
#: supported when its not plugged in AC»).
PERFILES_CON_BATERIA = ("balanced", "low-power")

#: Perfil que NitroSense NO ofrece con el cargador enchufado (onACMode()
#: filtra ECO: «Solo se puede utilizar con bateria»).  El driver SI lo acepta
#: con cargador; se oculta por decision del usuario (2026-09-23), para que la
#: aplicacion se comporte como Windows.
PERFIL_SOLO_BATERIA = "low-power"

#: Por debajo de esta carga NitroSense bloquea el modo en Equilibrado (y Eco
#: con bateria): «El modo del sistema esta bloqueado. Cargue la bateria como
#: minimo el 40 %» (MUI_Low_Battery_Locked).  En Windows lo decide un aviso del
#: EC (BATTERY_BOOST), que linuwu_sense recibe (WMID_BATTERY_BOOST_EVENT) y no
#: usa; aqui se deduce del porcentaje, que es lo que dicen esas cadenas.
BATERIA_MINIMA_MODOS = 40

#: Perfiles que devuelven los ventiladores al automatico: el driver llama a
#: acer_set_fan_speed(0, 0) al ponerlos, y NitroSense bloquea su control de
#: ventiladores en ellos (fanLockByMode: QUIET y ECO).
PERFILES_SIN_VENTILADOR_MANUAL = ("quiet", "low-power")

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
        # Sin esto `if resultado:` seria SIEMPRE cierto (un objeto normal es
        # verdadero), que es justo el error que este tipo existe para evitar.
        return self.ok


@dataclass(slots=True)
class EstadoRapido:
    """Instantanea barata, se refresca a 1 Hz."""

    fan1: int | None = None
    fan2: int | None = None
    temp_paquete: float | None = None
    pl1_msr_w: float | None = None
    pl1_mmio_w: float | None = None
    no_turbo: bool | None = None
    bat_capacidad: int | None = None
    bat_estado: str | None = None
    health_mode: bool | None = None
    freq_media_mhz: float | None = None
    #: Velocidad manual de los ventiladores en por ciento, o None si el driver
    #: no la expone.  Un 0 en un campo significa AUTOMATICO en ese ventilador,
    #: no "parado": (0, 0) es el automatico de los dos.
    fan_cpu_pct: int | None = None
    fan_gpu_pct: int | None = None
    #: Uso de CPU en por ciento, medio de todos los hilos, desde la lectura
    #: anterior.  None en la primera lectura: hace falta una diferencia.
    uso_cpu: float | None = None
    #: Memoria en uso (MemTotal - MemAvailable) y total, en MiB.
    memoria_usada_mib: int | None = None
    memoria_total_mib: int | None = None
    #: Coste real de esta lectura, en milisegundos.  NO se muestra en la
    #: interfaz: esta para poder medir el bucle desde una consola sin tener que
    #: instrumentar nada, y es lo que respalda los numeros de la cabecera.
    coste_ms: float = 0.0


@dataclass(slots=True)
class EstadoLento:
    """Instantanea cara (ACPI/WMI), se refresca cada 10 s."""

    perfil: str | None = None
    temp_bateria: float | None = None
    #: Limite de carga leido POR EL EC.  Solo se rellena cuando esa es la
    #: fuente (ver fuente_limite_carga()): cuesta 4,9 ms de WMI y por eso no
    #: esta en el ciclo rapido, donde si esta el health_mode del modulo DKMS.
    limite_carga_ec: bool | None = None
    #: True con el cargador enchufado, False con bateria, None si no se sabe.
    #: Decide que modos se ofrecen, como en NitroSense.
    corriente: bool | None = None
    #: Capacidad actual de la bateria frente a la de fabrica, en por ciento, y
    #: ciclos de carga.  Es lo que NitroSense ensena como salud de la bateria.
    salud_bateria_pct: float | None = None
    ciclos_bateria: int | None = None
    #: Igual que en EstadoRapido: medicion interna, no se muestra.
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
    sonido_arranque: bool | None = None


@dataclass(slots=True)
class Diagnostico:
    """Que falta para que la app pueda funcionar."""

    hay_perfil: bool = False
    hay_hwmon_acer: bool = False
    faltantes: list[str] = field(default_factory=list)

    @property
    def utilizable(self) -> bool:
        """¿Merece la pena abrir la interfaz?

        SOLO depende del perfil de plataforma.  Antes tambien exigia el hwmon
        'acer' (`hay_perfil and hay_hwmon_acer`), y eso era demasiado duro para
        cualquiera que no tenga exactamente este portatil: en un Acer donde el
        driver registre `platform_profile` pero NO los tacometros -otro modelo,
        un quirk sin hwmon, un `acer_wmi` mas antiguo- la aplicacion se negaba
        entera con «Hardware no compatible», escondiendo el perfil termico, el
        PL1, el Turbo, la bateria y las temperaturas, que funcionan
        perfectamente sin un solo ventilador leido.

        Sin RPM lo unico que se pierde son dos filas y una grafica, y esas ya
        saben ensenar «—» cuando no hay dato.  El aviso se da igual: sigue en
        `faltantes` y la ventana lo enseña al abrirse.
        """
        return self.hay_perfil

    @property
    def completo(self) -> bool:
        """Todo el hardware esperado, tacometros incluidos."""
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


#: Cache del nodo de la bateria: el nombre no cambia mientras el equipo este
#: encendido, y recorrer el directorio en cada refresco de 1 Hz seria tonto.
_BATERIA_CACHE: Path | None = None


def _bateria_base(refrescar: bool = False) -> Path | None:
    """Nodo de sysfs de la bateria interna del portatil, o None si no hay.

    NO se codifica ``BAT1``.  Ese es el nombre que le da el firmware ACPI de
    este equipo; el del portatil de al lado puede ser ``BAT0``, y con la ruta
    cableada la aplicacion se quedaba sin porcentaje ni estado de carga sin
    decir por que.

    Se descartan dos cosas:

    * ``type != Battery`` (el cargador aparece como ``ACAD``, ``type=Mains``).
    * ``scope == Device``: asi es como el kernel marca la bateria de un
      PERIFERICO.  Comprobado en esta maquina, donde un raton Logitech expone
      ``hidpp_battery_0`` con ``type=Battery`` y ``capacity=58``; sin este
      filtro la aplicacion habria acabado ensenando la bateria del raton.

    Se prefieren los nodos llamados ``BAT*``, que es la convencion ACPI para
    la bateria del propio equipo.
    """
    global _BATERIA_CACHE
    if not refrescar and _BATERIA_CACHE is not None and _BATERIA_CACHE.exists():
        return _BATERIA_CACHE
    try:
        nodos = sorted(POWER_SUPPLY.iterdir())
    except OSError:
        return None

    def valida(d: Path) -> bool:
        if _leer_texto(d / "type") != "Battery":
            return False
        if _leer_texto(d / "scope") == "Device":
            return False
        return (d / "capacity").exists()

    for preferido in (True, False):
        for d in nodos:
            if d.name.startswith("BAT") is preferido and valida(d):
                _BATERIA_CACHE = d
                return d
    return None


def en_corriente() -> bool | None:
    """¿Esta enchufado el cargador?  True, False, o None si no se sabe.

    Se busca por CONTENIDO, igual que la bateria: el nodo que tenga
    ``type=Mains`` (aqui se llama ``ACAD``, en otros equipos ``AC`` o
    ``ADP1``).  Si hay varios -cargador de barril y USB-C- basta con que uno
    este ``online``.  Sin ningun nodo Mains se devuelve None y la interfaz
    ofrece todos los modos, que es lo que hacia antes de esta funcion.

    ``online`` evalua el metodo _PSR del ACPI, pero es barato: 0,054 ms de
    mediana, medido el 2026-09-23.  Va en el ciclo de 10 s porque ahi basta.
    """
    try:
        nodos = sorted(POWER_SUPPLY.iterdir())
    except OSError:
        return None
    visto = False
    for d in nodos:
        if _leer_texto(d / "type") != "Mains":
            continue
        online = _leer_int(d / "online")
        if online is None:
            continue
        visto = True
        if online:
            return True
    return False if visto else None


def salud_bateria() -> tuple[float | None, int | None]:
    """(capacidad actual frente a la de fabrica en %, ciclos) o (None, None).

    El kernel publica la capacidad en energia (``energy_*``, µWh) o en carga
    (``charge_*``, µAh) segun el firmware; se usa la pareja que exista, sin
    mezclarlas.  Un ``cycle_count`` de 0 es el valor que ponen muchos
    firmwares cuando NO lo cuentan, asi que 0 se devuelve como None en vez de
    afirmar que la bateria esta sin estrenar.
    """
    bat = _bateria_base()
    if bat is None:
        return None, None
    pct = None
    for llena, fabrica in (("energy_full", "energy_full_design"),
                           ("charge_full", "charge_full_design")):
        actual, diseno = _leer_int(bat / llena), _leer_int(bat / fabrica)
        if actual is not None and diseno:
            pct = actual * 100.0 / diseno
            break
    ciclos = _leer_int(bat / "cycle_count")
    return pct, (ciclos if ciclos else None)


def modo_ventiladores(cpu: int | None, gpu: int | None) -> str | None:
    """Traduce lo que devuelve fan_speed a los tres modos de NitroSense.

    NitroSense tiene Automatico, Maximo y Personalizado (FAN_MODE Auto/Max/
    Custom).  El driver no guarda el modo, solo los dos porcentajes, pero la
    correspondencia es exacta porque es la misma que usa acer_set_fan_speed():
    0,0 manda el comando de automatico y 100,100 el de maximo.
    """
    if cpu is None or gpu is None:
        return None
    if cpu == 0 and gpu == 0:
        return "auto"
    if cpu == 100 and gpu == 100:
        return "max"
    return "personalizado"


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
        #: (total, reposo) de la lectura anterior de /proc/stat, para sacar el
        #: uso de CPU como diferencia entre dos lecturas.
        self._cpu_previa: tuple[int, int] | None = None

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
            # OJO: la causa casi nunca es 'acpi=off' ni un kernel viejo, que es
            # lo que decia el mensaje anterior y no llevaba a ninguna parte.  En
            # un Acer recien instalado la causa es que NO HAY DRIVER DE
            # PLATAFORMA cargado: el AN17-51 no esta en la tabla de quirks DMI
            # del acer-wmi de mainline, asi que sin predator_v4=1 -o sin
            # linuwu_sense- el driver no registra platform_profile.  Ese es
            # justo el trabajo de los dos scripts que se nombran aqui.
            diag.faltantes.append(
                "No existe /sys/firmware/acpi/platform_profile, asi que no hay "
                "perfiles termicos que cambiar. Casi siempre es que falta el "
                "driver de plataforma: preparalo con "
                "'sudo ./packaging/preparar-sistema.sh' (acer_wmi con "
                "predator_v4=1) o con 'sudo ./packaging/instalar-rgb.sh' "
                "(linuwu_sense, que ademas da el teclado RGB). Comprueba "
                "despues con 'cat /sys/firmware/acpi/platform_profile_choices' "
                "y 'dmesg | grep -i acer'. Si tu equipo no es un Acer, este "
                "programa no tiene nada que controlar aqui."
            )
        diag.hay_hwmon_acer = self.ruta_hwmon_acer() is not None
        if not diag.hay_hwmon_acer:
            # OJO: en este proyecto el hwmon 'acer' lo publica linuwu_sense, y
            # acer_wmi esta en la lista negra precisamente para dejarle sitio.
            # Decir aqui «modprobe acer_wmi» mandaba al usuario a cargar el
            # modulo equivocado.
            diag.faltantes.append(
                "No hay ningun hwmon llamado 'acer', asi que no se pueden leer "
                "las RPM de los ventiladores. Instala el driver del proyecto con "
                "'sudo ./packaging/instalar-rgb.sh' y comprueba con "
                "'lsmod | grep linuwu' y 'dmesg | grep -i acer'. Si usas el "
                "acer_wmi del kernel en vez de linuwu_sense, quitalo de la lista "
                "negra y cargalo con 'sudo modprobe acer_wmi'."
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

    def perfiles_permitidos(
        self, corriente: bool | None, capacidad: int | None
    ) -> list[str]:
        """Los modos que NitroSense ofreceria ahora mismo, en orden de 'choices'.

        Con cargador: todos menos Eco.  Con bateria: Equilibrado y Eco.  Con la
        bateria por debajo del 40 %: Equilibrado (y Eco si ademas no hay
        cargador).  Son las tres reglas de IsDisableOperatingBtn() y de
        onACMode()/onBatteryPowerMode() en NitroSense 5.0.

        Si no se sabe si hay cargador (None) no se filtra nada, que es lo que
        hacia la aplicacion antes.  Y si el filtro deja la lista vacia -otro
        modelo con otros nombres de perfil- se devuelven todos: una lista vacia
        dejaria el selector inservible, y el kernel sigue siendo quien rechaza
        lo que no admite.
        """
        todos = list(self.perfiles())
        if corriente is None:
            return todos
        if corriente:
            permitidos = [p for p in todos if p != PERFIL_SOLO_BATERIA]
        else:
            permitidos = [p for p in todos if p in PERFILES_CON_BATERIA]
        if capacidad is not None and capacidad < BATERIA_MINIMA_MODOS:
            permitidos = [p for p in permitidos if p in PERFILES_CON_BATERIA]
        return permitidos or todos

    @staticmethod
    def motivo_limite_modos(corriente: bool | None, capacidad: int | None) -> str | None:
        """Explicacion de por que faltan modos en el selector, o None si no faltan.

        Los textos siguen a los de NitroSense en espanol (MUI_On_Battery_Power,
        MUI_Low_Battery_Locked), para que el aviso sea el mismo en los dos
        sistemas.
        """
        if corriente is None:
            return None
        if capacidad is not None and capacidad < BATERIA_MINIMA_MODOS:
            return (
                f"La bateria esta al {capacidad} %. Igual que en Windows, el modo "
                f"queda en Equilibrado hasta que cargue como minimo el "
                f"{BATERIA_MINIMA_MODOS} %."
            )
        if not corriente:
            return (
                "Con bateria solo estan Equilibrado y Eco, como en NitroSense. "
                "Silencioso, Rendimiento y Turbo vuelven al enchufar el cargador; "
                "el driver los rechaza sin el."
            )
        return None

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
        ):
            crudo = _leer_int(ruta)
            if crudo is not None:
                setattr(est, atributo, crudo / 1_000_000.0)

        crudo = _leer_int(NO_TURBO)
        if crudo is not None:
            est.no_turbo = bool(crudo)

        bat = _bateria_base()
        if bat is not None:
            est.bat_capacidad = _leer_int(bat / "capacity")
            est.bat_estado = _leer_texto(bat / "status")

        crudo = _leer_int(HEALTH_MODE)
        if crudo is not None:
            est.health_mode = bool(crudo)

        # Velocidad manual de los ventiladores.  Cabe aqui, y solo ella de todo
        # /sys/devices/platform/acer-wmi/: 0,007 ms medidos (mediana de 25),
        # porque el driver devuelve dos variables suyas sin llamar al firmware.
        # Sus vecinas del mismo directorio cuestan 5 ms de WMI y no caben.
        #
        # Y tiene que estar a 1 Hz: el propio driver devuelve los ventiladores
        # al automatico cuando el perfil pasa a 'quiet' o 'low-power'
        # (linuwu_sense.c, acer_set_fan_speed(0,0)), asi que la interfaz se
        # entera sola de un cambio que no ha hecho ella.
        texto = _leer_texto(VENTILADORES)
        if texto is not None:
            partes = texto.split(",")
            if len(partes) == 2:
                try:
                    est.fan_cpu_pct = int(partes[0])
                    est.fan_gpu_pct = int(partes[1])
                except ValueError:
                    pass

        est.freq_media_mhz = self._frecuencia_media()
        est.uso_cpu = self._uso_cpu()
        est.memoria_usada_mib, est.memoria_total_mib = self._memoria()

        est.coste_ms = (time.perf_counter() - inicio) * 1000.0
        return est

    def _uso_cpu(self) -> float | None:
        """Uso medio de CPU desde la lectura anterior, en por ciento.

        Primera linea de /proc/stat: user nice system idle iowait irq softirq
        steal (guest y guest_nice NO se suman: el kernel ya los cuenta dentro
        de user y nice).  El reposo es idle + iowait.
        """
        linea = _leer_texto(PROC_STAT)
        if not linea:
            return None
        campos = linea.splitlines()[0].split()
        if len(campos) < 5 or campos[0] != "cpu":
            return None
        try:
            valores = [int(v) for v in campos[1:9]]
        except ValueError:
            return None
        total = sum(valores)
        reposo = valores[3] + (valores[4] if len(valores) > 4 else 0)
        previa, self._cpu_previa = self._cpu_previa, (total, reposo)
        if previa is None:
            return None
        d_total, d_reposo = total - previa[0], reposo - previa[1]
        if d_total <= 0:
            return None
        return max(0.0, min(100.0, 100.0 * (d_total - d_reposo) / d_total))

    @staticmethod
    def _memoria() -> tuple[int | None, int | None]:
        """(usada, total) en MiB a partir de /proc/meminfo.

        «Usada» es MemTotal - MemAvailable, que es lo que ensenan el monitor de
        GNOME y el de NitroSense; MemFree solo dejaria fuera la cache y daria
        un porcentaje alarmante que no significa nada.
        """
        texto = _leer_texto(PROC_MEMINFO)
        if not texto:
            return None, None
        datos: dict[str, int] = {}
        for linea in texto.splitlines():
            clave, _, resto = linea.partition(":")
            if clave in ("MemTotal", "MemAvailable"):
                try:
                    datos[clave] = int(resto.split()[0])
                except (ValueError, IndexError):
                    pass
        total, libre = datos.get("MemTotal"), datos.get("MemAvailable")
        if total is None or libre is None:
            return None, None
        return (total - libre) // 1024, total // 1024

    def fuente_limite_carga(self) -> str | None:
        """De donde sale el limite de carga al 80 %: "dkms", "ec" o None.

        HAY DOS CAMINOS PARA LO MISMO Y EL ORDEN NO ES ARBITRARIO
        ---------------------------------------------------------
        - "dkms": ``acer-wmi-battery/health_mode``, del modulo del AUR.
        - "ec":   ``nitro_sense/battery_limiter``, del propio linuwu_sense.

        Se prefiere SIEMPRE el del modulo DKMS cuando existe, por dos motivos
        medidos en esta maquina (mediana de 25 lecturas):

            health_mode      0,006 ms   <- variable del modulo
            battery_limiter  4,888 ms   <- llamada WMI real al firmware

        El primero cabe en el ciclo de 1 Hz; el segundo, no. Y ademas, si
        estando los dos escribieramos por ``battery_limiter``, el modulo DKMS
        se quedaria con su copia desfasada para siempre.

        Sin el modulo del AUR ya no se pierde la funcion, que era lo que pasaba
        antes: se pierde solo la temperatura de la bateria, que la publica ese
        mismo modulo y no el EC.
        """
        if HEALTH_MODE.exists():
            return "dkms"
        if BAT_LIMITER.exists():
            return "ec"
        return None

    def leer_lento(self) -> EstadoLento:
        """Ciclo de 0,1 Hz.  Agrupa las lecturas ACPI/WMI caras (~10 ms)."""
        inicio = time.perf_counter()
        est = EstadoLento()
        est.perfil = self.perfil_actual()
        # Solo cuando el limite de carga lo lleva el EC: son 4,9 ms de WMI y
        # por eso no esta en el ciclo rapido.  Con el modulo DKMS instalado
        # esta lectura no se hace nunca.
        if self.fuente_limite_carga() == "ec":
            crudo = _leer_int(BAT_LIMITER)
            if crudo is not None:
                est.limite_carga_ec = bool(crudo)
        crudo = _leer_int(TEMP_BATERIA)
        if crudo is not None:
            # 33000 son 33,0 C: es simplemente /1000.  La formula (v-2731)*100
            # es la conversion INTERNA del driver y aqui daria 3056900.
            est.temp_bateria = crudo / 1000.0
        # El cargador va aqui y no a 1 Hz: 'online' evalua _PSR por ACPI y no
        # esta medido (ver la cabecera).  Diez segundos de retraso no importan:
        # quien cambia el modo al enchufar o desenchufar es el propio driver
        # (WMID_AC_EVENT), no la aplicacion; esto solo decide que se OFRECE.
        est.corriente = en_corriente()
        est.salud_bateria_pct, est.ciclos_bateria = salud_bateria()
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

    def pl1_maximo_w(self) -> float | None:
        """Potencia base declarada por el chip, o None si no se puede leer.

        Devuelve None A PROPOSITO cuando no hay RAPL de Intel (un Acer con CPU
        AMD) o cuando ``constraint_0_max_power_uw`` no existe.  Antes devolvia
        45.0 como respaldo, que es la cifra de ESTE portatil (i7-13620H): en
        cualquier otro equipo la interfaz afirmaba «Tu chip declara 45 W
        nominales» sin haber leido nada.  Un numero inventado presentado como
        lectura es peor que no dar numero.
        """
        crudo = _leer_int(PL_MAX)
        return crudo / 1_000_000.0 if crudo else None

    # -- que partes del hardware existen en ESTE equipo ---------------------
    #
    # El AN17-51 las tiene todas, asi que en la maquina del autor estas tres
    # funciones devuelven siempre True.  En otro Acer no: intel_pstate no
    # existe con CPU AMD ni arrancando con 'intel_pstate=disable', y
    # acer-wmi-battery es un DKMS del AUR que el README declara OPCIONAL.
    #
    # La interfaz las necesita para desactivar el control en vez de ensenarlo
    # apagado: sin esto, el interruptor se movia al pulsarlo, no se escribia
    # nada, no salia ningun aviso y el usuario se quedaba creyendo que habia
    # cambiado algo.  Ver el comentario de _grupo_potencia en window.py.

    @staticmethod
    def hay_pl1() -> bool:
        """¿Existe el PL1 por MSR? (RAPL de Intel presente)"""
        return PL1_MSR.exists()

    @staticmethod
    def hay_turbo() -> bool:
        """¿Existe intel_pstate/no_turbo?"""
        return NO_TURBO.exists()

    @staticmethod
    def hay_salud_bateria() -> bool:
        """¿Hay limite de carga al 80 %, venga de donde venga?

        Antes esto era «¿esta cargado el DKMS acer-wmi-battery?», y con eso la
        fila salia en gris en cualquier equipo sin ese modulo del AUR.  Pero
        linuwu_sense publica lo mismo en ``nitro_sense/battery_limiter``, asi
        que basta con que exista UNA de las dos.  Cual se usa lo decide
        ``fuente_limite_carga()``, que prefiere el DKMS por coste.
        """
        return HEALTH_MODE.exists() or BAT_LIMITER.exists()

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
        solo_helper: bool = False,
    ) -> Resultado:
        """Escribe *valor* en *ruta*, con fallback al helper por pkexec.

        SOBRE *accion* Y *valor_helper*
        --------------------------------
        El helper NO recibe rutas.  Antes se le pasaba `str(ruta)` como
        argumento, y eso era un agujero de escalada de privilegios: cualquier
        proceso que corriese como el usuario podia pedirle que escribiera como
        root en cualquier fichero.  Ahora cruza la frontera de privilegio solo
        un NOMBRE DE ACCION de un conjunto cerrado (la lista esta en ACCIONES,
        dentro de packaging/nitro-gekko-helper) y su valor; la lista blanca de
        rutas vive dentro del helper.  Si una escritura no tiene accion
        asociada, simplemente no hay camino privilegiado para ella: se intenta
        directa y, si no hay permiso, se devuelve un error claro.

        SOBRE *solo_helper*
        -------------------
        Para las acciones que no son «escribe esto en esa ruta» sino «anota
        esto y aplicalo solo si toca»: el modo de un escenario para la OTRA
        fuente de alimentacion (perfil_ac con bateria, perfil_bateria con
        cargador) no se puede escribir en /sys, porque no es el modo de ahora.
        Con True se salta la escritura directa aunque la ruta sea escribible
        (modo --con-udev) y se va siempre al helper, que es quien anota.

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
        if not solo_helper and os.access(ruta, os.W_OK):
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
            f"el modo «{bonito}»",
            exito=f"Modo «{bonito}» aplicado.",
            accion="perfil",
            al_terminar=al_terminar,
        )

    def escribir_perfil_fuente(
        self, fuente: str, perfil: str,
        al_terminar: Callable[[Resultado], None] | None = None,
    ) -> Resultado:
        """Fija el modo que se usara con el cargador («ac») o con la bateria.

        Es el opMode/dcMode de los escenarios de NitroSense: cada escenario
        guarda un modo para cada fuente de alimentacion.  El helper lo ANOTA y
        solo lo escribe en /sys si esa fuente es la de ahora; el otro se aplica
        al enchufar o desenchufar (nitro-gekko-corriente.service).  Por eso va
        siempre por el helper (solo_helper=True): sin el no hay donde anotarlo.
        """
        if fuente not in ("ac", "bateria"):
            return Resultado(False, f"Fuente de alimentacion desconocida: {fuente!r}.")
        validos = self.perfiles()
        if validos and perfil not in validos:
            return Resultado(False, f"'{perfil}' no es un perfil valido en este equipo.")
        bonito = ETIQUETAS_PERFIL.get(perfil, perfil)
        cuando = "con cargador" if fuente == "ac" else "con bateria"
        return self._escribir(
            PERFIL_LEGACY,
            perfil,
            f"el modo {cuando}",
            exito=f"Modo {cuando}: «{bonito}».",
            accion=f"perfil_{fuente}",
            al_terminar=al_terminar,
            solo_helper=True,
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

        def completar(msr: Resultado) -> Resultado:
            """Anade la escritura del MMIO al resultado del MSR.

            Va en una funcion aparte porque tiene que aplicarse TAMBIEN al
            resultado que viaja por el callback asincrono.  Antes el MMIO se
            escribia despues de haber llamado ya a *al_terminar* con el
            resultado del MSR a secas, y el Resultado combinado se devolvia
            como valor de retorno... que `VentanaNitro._lanzar_escritura`
            descarta.  Por la via DIRECTA (reglas udev de `--con-udev`) el
            usuario veia «PL1 fijado a N W.» aunque el MMIO no se hubiera
            podido escribir.  Reproducido con un MSR escribible y un MMIO en
            modo 0444: toast «PL1 fijado a 50 W.», MMIO intacto.
            """
            # Por la via privilegiada el helper ya escribe MSR y MMIO de una
            # vez, asi que no hay segunda llamada (seria un segundo dialogo de
            # contrasena para la misma accion del usuario).
            if msr.via == "pkexec" or not msr.ok or not ambas:
                return msr
            secundario = self._escribir(
                PL1_MMIO,
                uw,
                "el PL1 del MMIO",
                exito=f"PL1 fijado a {vatios:.0f} W en el MMIO.",
            )
            if not secundario.ok:
                # El MSR, que es el que manda, si se aplico: no es un fallo
                # total, pero el usuario tiene que enterarse igual.
                return Resultado(
                    True,
                    f"PL1 a {vatios:.0f} W aplicado en el MSR (el que manda); el "
                    f"MMIO no se pudo escribir.",
                    via=msr.via,
                )
            return Resultado(True, f"PL1 fijado a {vatios:.0f} W.", via=msr.via)

        argumentos = dict(
            exito=f"PL1 fijado a {vatios:.0f} W.",
            accion="pl1",
            # El helper recibe VATIOS, no microvatios: su rango duro esta en
            # vatios y asi el valor que se audita en el journal es legible.
            valor_helper=str(int(round(vatios))),
        )
        if al_terminar is None:
            return completar(
                self._escribir(PL1_MSR, uw, "el PL1 del MSR", **argumentos)
            )
        # Camino asincrono: el callback tiene que recibir el resultado
        # COMBINADO, no el del MSR suelto.  El valor de retorno de aqui lo
        # ignora quien llama, asi que el unico canal fiable es el callback.
        return self._escribir(
            PL1_MSR,
            uw,
            "el PL1 del MSR",
            al_terminar=lambda r: al_terminar(completar(r)),
            **argumentos,
        )

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
        # La ruta y la accion dependen de quien publique la funcion en este
        # equipo; ver fuente_limite_carga().
        if self.fuente_limite_carga() == "ec":
            ruta, accion = BAT_LIMITER, "bateria_ec"
        else:
            ruta, accion = HEALTH_MODE, "bateria"
        return self._escribir(
            ruta, "1" if activar else "0", etiqueta, exito=exito,
            accion=accion, al_terminar=al_terminar,
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

        Es una lectura CARA: 47 a 53 ms medidos (mediana de 25 llamadas),
        porque cada atributo es una llamada WMI real al firmware (per_zone_mode
        25,5 ms, usb_charging 7,1 ms, four_zone_mode 5,1 ms, backlight_timeout
        5,1 ms, boot_animation_sound 5,0 ms).  No la metas en el bucle de 1 Hz:
        la pagina de iluminacion la pide al abrirse y despues de cada cambio, y
        con eso basta.
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

    # ----------------------------------------------------------------------
    # Ventiladores y panel (driver linuwu_sense, grupo nitro_sense)
    #
    # Estan aqui y no con el teclado porque no tienen nada que ver con el RGB:
    # un Acer puede exponer nitro_sense sin four_zoned_kb.
    # ----------------------------------------------------------------------

    #: Minimo por ciento que la aplicacion deja poner a mano.  Tiene que ser el
    #: mismo FAN_MIN_PCT que el helper, o la interfaz ofreceria un valor que el
    #: helper rechaza con codigo 2.
    #:
    #: MEDIDO, no elegido: por debajo de ~25 % el EC impone su propio suelo
    #: (~2590 rpm) y las rpm dejan de bajar, asi que pedir 1 % y pedir 20 %
    #: hacen lo mismo.  30 es el escalon mas bajo que todavia se distingue.  La
    #: tabla entera del barrido esta en packaging/nitro-gekko-helper.
    FAN_MIN_PCT = 30

    def hay_ventiladores_manuales(self) -> bool:
        """True si el driver deja fijar la velocidad de los ventiladores."""
        return VENTILADORES.exists()

    @staticmethod
    def ventiladores_bloqueados(perfil: str | None) -> bool:
        """¿Bloquea este modo el control de ventiladores, como en NitroSense?

        En Silencioso y Eco NitroSense desactiva su control de ventiladores
        («El control del ventilador se desactivo en modo Silencioso»), y el
        driver los devuelve al automatico al entrar en esos dos modos.
        """
        return perfil in PERFILES_SIN_VENTILADOR_MANUAL

    def escribir_ventiladores(
        self, cpu: int | None, gpu: int | None,
        al_terminar: Callable[[Resultado], None] | None = None,
    ) -> Resultado:
        """Velocidad de los ventiladores: automatico, maximo o personalizada.

        ``cpu`` y ``gpu`` en por ciento, o None para dejar ESE ventilador en
        automatico.  Los tres modos de NitroSense salen asi:

            Automatico     -> (None, None)  -> "0,0"
            Maximo         -> (100, 100)    -> "100,100"
            Personalizado  -> cualquier otra pareja, con cada ventilador entre
                              FAN_MIN_PCT y 100, o None para dejarlo en «Auto»

        POR QUE AHORA SE ACEPTA UN VENTILADOR EN AUTOMATICO Y EL OTRO FIJO
        ------------------------------------------------------------------
        Antes no: «un 0 suelto querria decir dos cosas».  El 2026-09-23 el
        usuario pidio que funcionase como NitroSense, que tiene una casilla
        «Auto» por ventilador (fan_custom_auto en su FAN_CONTROL).  Y la
        ambiguedad no existe de verdad: el minimo manual es 30, asi que un 0 en
        un campo SOLO puede significar automatico.  Es ademas lo que hace el
        driver: acer_set_fan_speed() tiene ramas propias para «CUSTOM FAN MODE
        (CPU)» y «(GPU)».

        LO QUE HAY QUE SABER ANTES DE USAR ESTO
        ---------------------------------------
        1. El automatico se recupera SIEMPRE, y por dos caminos: desde aqui con
           ``escribir_ventiladores(None, None)``, o poniendo el modo en
           Silencioso o Eco, porque el propio driver llama a
           ``acer_set_fan_speed(0, 0)`` al aplicarlos.
        2. Lo repone nitro-gekko-restaurar en el siguiente arranque; el driver
           por su cuenta solo guarda el estado al DESCARGARSE el modulo.
        3. Bajar la velocidad no puentea nada: el PROCHOT/TCC del propio chip
           sigue estando, asi que un porcentaje bajo con carga se traduce en
           calor y en que la CPU se limite sola, no en dano.
        """
        if cpu is None and gpu is None:
            return self._escribir(
                VENTILADORES, "0,0", "los ventiladores",
                exito="Ventiladores en automatico: los lleva el EC.",
                accion="ventiladores", al_terminar=al_terminar,
            )
        for valor, cual in ((cpu, "CPU"), (gpu, "GPU")):
            if valor is not None and not (self.FAN_MIN_PCT <= valor <= 100):
                return Resultado(
                    False,
                    f"La velocidad del ventilador de {cual} tiene que estar entre "
                    f"{self.FAN_MIN_PCT} y 100 %, o en automatico.",
                )
        if cpu == 100 and gpu == 100:
            exito = "Ventiladores al maximo."
        else:
            partes = [
                f"{cual} {'automatico' if v is None else f'{v} %'}"
                for v, cual in ((cpu, "CPU"), (gpu, "GPU"))
            ]
            exito = "Ventiladores fijados: " + ", ".join(partes) + "."
        valor = f"{cpu or 0},{gpu or 0}"
        return self._escribir(
            VENTILADORES, valor, "los ventiladores",
            exito=exito, accion="ventiladores", al_terminar=al_terminar,
        )

    def hay_overdrive(self) -> bool:
        """True si el driver expone el overdrive del panel."""
        return OVERDRIVE.exists()

    def leer_overdrive(self) -> int | None:
        """Overdrive del panel: 0, 1, o None si no se puede saber.

        Se lee BAJO DEMANDA y nunca desde un temporizador: cuesta 5,2 ms
        (mediana de 25 lecturas), que es una llamada WMI real al firmware.
        """
        return _leer_int(OVERDRIVE)

    def escribir_overdrive(
        self, activo: bool, al_terminar: Callable[[Resultado], None] | None = None
    ) -> Resultado:
        """Overdrive del panel.

        Lo que hace de verdad esta en el firmware y la aplicacion no lo puede
        comprobar: lo unico que si se comprueba es que el atributo relee lo que
        le escribimos.  Por eso la interfaz no promete ninguna cifra de tiempo
        de respuesta: la de la ficha de Acer no es una medida de este equipo.
        """
        exito = "Overdrive del panel activado." if activo else "Overdrive del panel desactivado."
        return self._escribir(
            OVERDRIVE, "1" if activo else "0", "el overdrive del panel",
            exito=exito, accion="overdrive", al_terminar=al_terminar,
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

    # ----------------------------------------------------------------------
    # Tecla de modo y calibracion de la bateria (lo que faltaba de NitroSense)
    # ----------------------------------------------------------------------

    @staticmethod
    def hay_tecla_modo() -> bool:
        """True si linuwu_sense publica el parametro de la tecla de modo."""
        return TECLA_MODO.exists()

    @staticmethod
    def leer_tecla_modo() -> bool | None:
        """True = recorre los modos, False = activa y desactiva el Turbo.

        Es un parametro del modulo (una variable en memoria), no una llamada
        al firmware: se puede leer sin miedo, aunque solo se hace bajo demanda.
        """
        texto = _leer_texto(TECLA_MODO)
        if texto in ("Y", "y", "1"):
            return True
        if texto in ("N", "n", "0"):
            return False
        return None

    def escribir_tecla_modo(
        self, ciclo: bool, al_terminar: Callable[[Resultado], None] | None = None
    ) -> Resultado:
        """Comportamiento de la tecla de modo, como la opcion de NitroSense."""
        exito = (
            "La tecla de modo recorrera los modos." if ciclo
            else "La tecla de modo activara y desactivara el Turbo."
        )
        return self._escribir(
            TECLA_MODO, "1" if ciclo else "0", "el comportamiento de la tecla de modo",
            exito=exito, accion="tecla_modo", al_terminar=al_terminar,
        )

    @staticmethod
    def hay_calibracion() -> bool:
        """True si el driver expone la calibracion de la bateria."""
        return CALIBRACION.exists()

    @staticmethod
    def leer_calibracion() -> bool | None:
        """¿Hay un ciclo de calibracion en marcha?  4,9 ms de WMI: bajo demanda."""
        v = _leer_int(CALIBRACION)
        return None if v is None else bool(v)

    def escribir_calibracion(
        self, activar: bool, al_terminar: Callable[[Resultado], None] | None = None
    ) -> Resultado:
        """Arranca o detiene un ciclo de calibracion de la bateria.

        La interfaz SOLO llama aqui despues de un dialogo de confirmacion con
        los avisos de NitroSense, y con el cargador enchufado.  El helper no lo
        anota: reponerlo en cada arranque descargaria la bateria entera sin que
        nadie lo hubiera pedido esa vez.
        """
        exito = (
            "Calibracion de la bateria en marcha. No desconectes el cargador."
            if activar else "Calibracion de la bateria detenida."
        )
        return self._escribir(
            CALIBRACION, "1" if activar else "0", "la calibracion de la bateria",
            exito=exito, accion="calibracion", al_terminar=al_terminar,
        )


# --------------------------------------------------------------------------
# GPU NVIDIA (fuera del bucle de 1 Hz: nvidia-smi despierta la GPU)
# --------------------------------------------------------------------------


@dataclass(slots=True)
class EstadoGpu:
    vatios: float | None = None
    temperatura: float | None = None
    pstate: str | None = None
    #: Uso y frecuencia del nucleo grafico: los GPU1_USAGE y GPU1_FREQUENCY
    #: que NitroSense ensena en su supervision.
    uso: int | None = None
    reloj_mhz: int | None = None
    disponible: bool = False


def _numero(texto: str) -> float | None:
    """float de un campo de nvidia-smi, o None si es [N/A] o basura."""
    try:
        return float(texto)
    except ValueError:
        return None


def leer_gpu(timeout: float = 2.0) -> EstadoGpu:
    """Consulta nvidia-smi.  Pensada para llamarse en un hilo, cada 5 s.

    Si nvidia-smi no existe, tarda demasiado o devuelve basura, se informa con
    disponible=False y la UI oculta la fila en vez de bloquearse.

    El uso y la frecuencia van en la MISMA consulta que ya se hacia: lo caro es
    lanzar nvidia-smi y despertar la tarjeta, no pedirle dos campos mas.
    """
    est = EstadoGpu()
    if shutil.which("nvidia-smi") is None:
        return est
    try:
        proceso = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=power.draw,temperature.gpu,pstate,"
                "utilization.gpu,clocks.gr",
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
    # Solo la primera linea: con dos GPU NVIDIA habria una por tarjeta.
    primera = proceso.stdout.strip().splitlines()[0] if proceso.stdout.strip() else ""
    partes = [p.strip() for p in primera.split(",")]
    if len(partes) < 3:
        return est
    # Campo a campo: algunas GPU devuelven [N/A] en el consumo y siguen
    # sirviendo la temperatura y el pstate.
    est.vatios = _numero(partes[0])
    est.temperatura = _numero(partes[1])
    est.pstate = partes[2]
    if len(partes) >= 5:
        uso, reloj = _numero(partes[3]), _numero(partes[4])
        est.uso = None if uso is None else int(uso)
        est.reloj_mhz = None if reloj is None else int(reloj)
    est.disponible = est.temperatura is not None
    return est
