"""Escenarios, como los de NitroSense: Uso diario, Juego y Ocasion tranquila.

Un escenario junta en un clic lo que en la ventana se toca por separado: el
modo con cargador, el modo con bateria, los ventiladores y la iluminacion del
teclado.  Es la pagina «Escenario» de NitroSense 5.0, y los tres de fabrica
llevan los valores que trae alli (leidos de ProfilePool/config.json en Windows,
el 2026-09-23):

    Uso diario         opMode 1 (DEFAULT -> balanced)      dcMode 1   WAVE
    Juego              opMode 4 (EXTREME -> balanced-perf.) dcMode 1   BREATHING
    Ocasion tranquila  opMode 0 (QUIET   -> quiet)          dcMode 1   STATIC #ffa000

con los ventiladores en automatico en los tres.

LO QUE NO SE HA COPIADO, Y POR QUE
----------------------------------
- NitroSense activa un escenario SOLO al abrir un juego de su lista.  Aqui no:
  el usuario eligio (2026-09-23) aplicarlos con un clic.  Hacerlo solo exigiria
  un proceso en segundo plano con permiso para cambiar el hardware sin pedir
  contrasena, que es justo lo que este proyecto no instala.
- En NitroSense, tocar el modo o los ventiladores en la pagina principal
  MODIFICA el escenario activo (su log dice «Save scenario» en cada cambio).
  Aqui un escenario es una receta: se aplica, y lo que toques despues no la
  cambia.  Para cambiarla se edita el escenario.

Este modulo es Python puro, como sysfs.py: no importa GTK, asi que se puede
probar sin sesion grafica.  Quien aplica los pasos es la ventana.
"""

from __future__ import annotations

from . import sysfs

#: Los tres modos de ventilador de NitroSense (FAN_MODE Auto/Max/Custom).
MODOS_VENTILADOR = ("auto", "max", "personalizado")

#: Largo maximo del nombre: lo justo para que quepa en la fila sin elidirse.
LARGO_NOMBRE = 40

#: Los escenarios de fabrica de NitroSense.  "teclado" es el nombre de un
#: estilo de sysfs.PRESETS_RGB, o "" para no tocar la iluminacion.  En los
#: ventiladores personalizados, 0 es «Auto» en ese ventilador, igual que en
#: sysfs.escribir_ventiladores().
POR_DEFECTO: tuple[dict, ...] = (
    {
        "nombre": "Uso diario",
        "perfil_ac": "balanced",
        "perfil_bateria": "balanced",
        "ventiladores": "auto",
        "fan_cpu": 50,
        "fan_gpu": 50,
        "teclado": "Onda",
    },
    {
        "nombre": "Juego",
        "perfil_ac": "balanced-performance",
        "perfil_bateria": "balanced",
        "ventiladores": "auto",
        "fan_cpu": 70,
        "fan_gpu": 70,
        "teclado": "Respiracion",
    },
    {
        "nombre": "Ocasion tranquila",
        "perfil_ac": "quiet",
        "perfil_bateria": "balanced",
        "ventiladores": "auto",
        "fan_cpu": 50,
        "fan_gpu": 50,
        "teclado": "Naranja Nitro",
    },
)


def por_defecto() -> list[dict]:
    """Copia NUEVA de los escenarios de fabrica (nunca la tupla compartida)."""
    return [dict(e) for e in POR_DEFECTO]


def _pct_valido(valor) -> bool:
    """0 (automatico) o un entero entre el minimo manual y 100.  Nunca bool."""
    if isinstance(valor, bool) or not isinstance(valor, int):
        return False
    return valor == 0 or sysfs.ControlNitro.FAN_MIN_PCT <= valor <= 100


def normalizar(datos) -> list[dict] | None:
    """Valida lo leido de ajustes.json.  Devuelve la lista limpia o None.

    Se exige exactamente la forma que escribe la aplicacion: tres escenarios,
    cada uno con sus siete claves y del tipo correcto.  Un fichero editado a
    mano que no cuadre se descarta entero (y se usan los de fabrica) en vez de
    aplicar medio escenario raro.  Los perfiles NO se comprueban contra el
    kernel aqui, porque ajustes.json se lee antes de mirar el hardware: eso lo
    hacen plan() y el helper al aplicar.
    """
    if not isinstance(datos, list) or len(datos) != len(POR_DEFECTO):
        return None
    limpios = []
    for entrada in datos:
        if not isinstance(entrada, dict):
            return None
        nombre = entrada.get("nombre")
        if not isinstance(nombre, str) or not nombre.strip() or len(nombre) > LARGO_NOMBRE:
            return None
        for clave in ("perfil_ac", "perfil_bateria"):
            if not isinstance(entrada.get(clave), str) or not entrada[clave]:
                return None
        if entrada.get("ventiladores") not in MODOS_VENTILADOR:
            return None
        if not (_pct_valido(entrada.get("fan_cpu")) and _pct_valido(entrada.get("fan_gpu"))):
            return None
        teclado = entrada.get("teclado")
        if not isinstance(teclado, str) or (teclado and teclado not in sysfs.PRESETS_RGB):
            return None
        limpios.append({
            "nombre": nombre.strip(),
            "perfil_ac": entrada["perfil_ac"],
            "perfil_bateria": entrada["perfil_bateria"],
            "ventiladores": entrada["ventiladores"],
            "fan_cpu": entrada["fan_cpu"],
            "fan_gpu": entrada["fan_gpu"],
            "teclado": teclado,
        })
    return limpios


def ventiladores_de(escenario: dict) -> tuple[int | None, int | None]:
    """(cpu, gpu) para sysfs.escribir_ventiladores(): None es automatico."""
    modo = escenario.get("ventiladores")
    if modo == "max":
        return 100, 100
    if modo == "personalizado":
        cpu, gpu = escenario.get("fan_cpu", 0), escenario.get("fan_gpu", 0)
        return (cpu or None), (gpu or None)
    return None, None


def plan(
    escenario: dict,
    corriente: bool | None,
    perfiles: list[str],
    hay_ventiladores: bool,
    hay_teclado: bool,
) -> list[tuple[str, object]]:
    """Pasos para aplicar *escenario*, en el orden que importa.

    Cada paso es (tipo, valor):

        ("perfil_otra", (fuente, perfil))  anotar el modo de la fuente que NO
                                           es la de ahora (no se escribe)
        ("perfil", (fuente, perfil))       el modo de ahora: se escribe
        ("perfil_directo", perfil)         sin saber la fuente: se escribe tal cual
        ("ventiladores", (cpu, gpu))
        ("teclado", nombre_de_estilo)

    EL ORDEN: el modo antes que los ventiladores, porque poner Silencioso o Eco
    los devuelve al automatico (lo hace el driver) y se llevaria por delante lo
    que se hubiera puesto antes.  Por lo mismo, en esos dos modos los
    ventiladores NI SE MANDAN: NitroSense los bloquea ahi, y escribirlos solo
    serviria para que el siguiente cambio de modo los deshiciera.

    Un perfil que el kernel no ofrezca se salta, en vez de mandar al helper
    algo que va a rechazar con codigo 2.
    """
    pasos: list[tuple[str, object]] = []
    validos = set(perfiles)
    ac, bat = escenario.get("perfil_ac"), escenario.get("perfil_bateria")

    if corriente is None:
        actual = ac if ac in validos else None
        if actual is not None:
            pasos.append(("perfil_directo", actual))
    else:
        fuente, otra = ("ac", "bateria") if corriente else ("bateria", "ac")
        actual = ac if corriente else bat
        otro = bat if corriente else ac
        if otro in validos:
            pasos.append(("perfil_otra", (otra, otro)))
        if actual not in validos:
            actual = None
        else:
            pasos.append(("perfil", (fuente, actual)))

    if hay_ventiladores and not sysfs.ControlNitro.ventiladores_bloqueados(actual):
        pasos.append(("ventiladores", ventiladores_de(escenario)))

    estilo = escenario.get("teclado")
    if hay_teclado and estilo and estilo in sysfs.PRESETS_RGB:
        pasos.append(("teclado", estilo))
    return pasos
