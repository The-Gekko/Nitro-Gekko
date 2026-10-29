"""Seguimiento de la calibracion de la bateria: en que fase va y cuanto falta.

El firmware no lo dice.  nitro_sense/battery_calibration solo vale 0 o 1, y la
calibracion son horas en las que, sin esto, la aplicacion solo sabia decir «en
marcha».  Aqui se deduce de lo que si publica la bateria (estado y porcentaje),
con las duraciones medidas en el AN17-51 la noche del 2026-10-29: 488 lecturas,
una por minuto, en tests/datos/calibracion-2026-10-29.csv.

    1. carga hasta el 100 % ....... 82 -> 100 % en unos 6 min
    2. «llena», terminando de cargar  95 min: el EC la da por llena pero sigue
                                      entrando corriente (de 4 A a 0,4 A)
    3. descarga, con el cargador .. 197 min, 100 -> 4 %, a 1,23 A casi fijos
                                      (1,09 a 1,36 A): la impone el EC
    4. recarga hasta el 100 % ..... 107 min, de 6 a 100 %
    y despues, llena, la calibracion SIGUE en marcha: no se cerro sola en
    1 h 20 min, y hubo que pulsar Detener.  Esa es la quinta «fase»,
    TERMINADA, que no es del firmware sino el aviso de que hay que pararla.

Los tiempos que faltan van por la DURACION de cada fase y no por el porcentaje,
y es a proposito.  Con el medidor descalibrado -que es justo cuando se
calibra- el porcentaje no baja parejo: en la descarga marcaba 6 % con 47 min
por delante, y en la recarga paso del 6 al 68 % en media hora y tardo otra hora
y cuarto en llegar al 100.  Lo que si es estable es el reloj: el EC descarga a
corriente fija.  Contrastado contra esas 488 lecturas (ver el README).  Al
cerrar una calibracion completa se guardan sus duraciones, y la siguiente
estima con ellas en vez de con las de aqui: asi se ajusta sola cuando la
bateria se gaste.

Lo que NO se da por bueno, porque engaña (todo con su prueba):

  * Un «Discharging» con el cargador quitado no es la fase 3: es que alguien
    lo ha desenchufado.  Tampoco cuenta lo que baja el porcentaje mientras.
  * Un «Charging» suelto en plena descarga no es la recarga: para pasar a la
    fase 4 la descarga tiene que haber llegado abajo (PCT_DESCARGA_HECHA).
  * Una fase que se empezo a ver tras un rato sin mirar no tiene hora de
    inicio fiable: ni cuenta su duracion ni se estima por el reloj.

Python puro, como sysfs.py y escenarios.py: no importa gi y no lee /sys (las
lecturas se las pasa quien llama), para poder probarlo sin hardware ni sesion
grafica (tests/test_calibracion.py).  Todo es inmutable: cada funcion devuelve
un Estado nuevo.
"""

from __future__ import annotations

import fcntl
import json
import os
import tempfile
from collections.abc import Callable
from dataclasses import dataclass, replace
from enum import Enum
from pathlib import Path


class Fase(str, Enum):
    CARGA = "carga"
    ESPERA = "espera"
    DESCARGA = "descarga"
    RECARGA = "recarga"
    TERMINADA = "terminada"


#: Las cuatro del firmware, en orden.  TERMINADA va detras y no se numera.
FASES = (Fase.CARGA, Fase.ESPERA, Fase.DESCARGA, Fase.RECARGA)
_ORDEN = {f: i for i, f in enumerate((*FASES, Fase.TERMINADA))}

NOMBRES = {
    Fase.CARGA: "Cargar hasta el 100 %",
    Fase.ESPERA: "Terminar de llenarla",
    Fase.DESCARGA: "Descargarla con el cargador puesto",
    Fase.RECARGA: "Recargar hasta el 100 %",
    Fase.TERMINADA: "Terminada",
}

EXPLICACIONES = {
    Fase.CARGA: "La bateria se carga hasta arriba.",
    Fase.ESPERA: (
        "El firmware la da por llena, pero sigue entrando corriente hasta que "
        "se completa; despues empieza a descargarla."
    ),
    Fase.DESCARGA: (
        "El firmware la descarga hasta casi vaciarla, aunque el cargador siga "
        "puesto: asi mide cuanto le cabe de verdad."
    ),
    Fase.RECARGA: "La vuelve a cargar hasta el 100 %.",
    Fase.TERMINADA: (
        "La bateria ya hizo el ciclo completo, pero el firmware no cierra la "
        "calibracion solo: pulsa Detener."
    ),
}

#: Duraciones medidas en el AN17-51 (ver la cabecera), en minutos.  Se usan
#: hasta que haya una calibracion completa guardada.
MIN_ESPERA = 95
MIN_DESCARGA = 197
MIN_RECARGA = 107
#: La carga inicial depende de donde empiece, y es corta: va por porcentaje.
#: Medio minuto por punto es la parte rapida de la recarga (6 -> 68 % en 30
#: min); la cola lenta ya la cubre la espera.
MIN_POR_PUNTO_CARGA = 0.5
#: Hasta donde la vacia el firmware (minimo medido: 4 %).
PCT_FIN_DESCARGA = 4
#: Por debajo de esto, la descarga ha llegado abajo y lo siguiente es la
#: recarga.  Con margen sobre el 4 % medido, por si otro dia para antes.
PCT_DESCARGA_HECHA = 15
#: Por encima de esto, «llena».  Por debajo, un «Not charging» es una carga
#: parada, no la espera: lo que pasa con el limite del 80 % puesto.
PCT_LLENA = 99
#: Margen para dar por hecho que ya descargo sin haberlo visto: estar por
#: debajo del porcentaje con el que empezo.  Tres puntos, para no tomar por
#: descarga el baile de un punto que tiene cualquier lectura de bateria.
MARGEN_PCT = 3
#: Sin haber visto la descarga, a partir de cuanto rato desde «Calibrar» ya
#: tiene que haber terminado: carga desde 0 (unos 50 min) + espera (95) +
#: descarga (197) son 5 h 42 min; con margen, 6 h.  Va por el reloj de pared
#: (time.time()), no por uno monotono, porque el estado sobrevive al proceso:
#: una suspension o un salto de NTP lo pueden adelantar, y por eso solo se usa
#: cuando no se ha podido mirar.
S_DESCARGA_HECHA = 6 * 3600
#: Mas de esto entre dos lecturas es un hueco sin mirar.  La ventana lee cada
#: segundo y 'nitro-gekko --avisos' cada 60 s: 150 s perdonan un tic perdido.
S_HUECO_MAX = 150
#: Una duracion guardada que se va mas alla de esto respecto a la medida no
#: se cree: viene de una calibracion rara, no de una bateria mas gastada.
FACTOR_DURACION_MAX = 2.0

_DEFECTO_S = {
    Fase.ESPERA: MIN_ESPERA * 60.0,
    Fase.DESCARGA: MIN_DESCARGA * 60.0,
    Fase.RECARGA: MIN_RECARGA * 60.0,
}


@dataclass(frozen=True)
class Lectura:
    """Lo que se sabe de la bateria en un momento.  None = no se pudo leer."""

    momento: float
    calibrando: bool | None
    estado: str | None
    porcentaje: int | None
    llena_uah: int | None = None
    diseno_uah: int | None = None
    corriente_ua: int | None = None
    en_corriente: bool | None = None


@dataclass(frozen=True)
class Registro:
    """La calibracion en marcha, tal como se ha ido viendo."""

    inicio: float
    #: True si se vio empezar (se pulso «Calibrar» en la aplicacion).  Si la
    #: primera vez que se ve ya estaba en marcha, no se sabe cuando empezo, y
    #: no se puede deducir nada por el reloj.
    inicio_conocido: bool
    porcentaje_inicio: int | None
    llena_inicio: int | None
    #: El mas bajo visto CON el cargador puesto.
    porcentaje_minimo: int | None
    #: (fase, momento en que se vio empezar, si se vio en el momento).  En
    #: orden y sin repetir.  Una fase vista tras un hueco no es «exacta».
    fases: tuple[tuple[Fase, float, bool], ...] = ()
    #: Hubo algun rato sin mirar.  Sin huecos, lo que no se vio no paso.
    hueco: bool = False
    ultimo_visto: float | None = None
    avisado_fin: bool = False
    avisado_cargador: bool = False


@dataclass(frozen=True)
class Ultima:
    """El resultado de la ultima calibracion, para ensenarlo y para estimar."""

    inicio: float
    fin: float
    llena_inicio: int | None
    llena_fin: int | None
    diseno: int | None
    completa: bool
    #: Duracion de cada fase vista entera, en segundos.
    duraciones: tuple[tuple[Fase, float], ...] = ()


@dataclass(frozen=True)
class Estado:
    en_curso: Registro | None = None
    ultima: Ultima | None = None


@dataclass(frozen=True)
class Vista:
    """Lo que hay que ensenar de una calibracion en marcha."""

    fase: Fase | None
    #: CARGA puede ser la recarga y ESPERA puede ser el final, si no se vio
    #: ni empezar ni descargar: la interfaz lo dice en vez de afirmar.
    ambigua: bool
    restante_fase_s: float | None
    restante_total_s: float | None
    #: De 0 a 1 sobre la calibracion entera; None si no se sabe cuando empezo.
    progreso: float | None
    #: Duracion de las fases ya terminadas, en segundos.
    duraciones: tuple[tuple[Fase, float], ...] = ()
    #: Lo que se espera que dure cada fase que falta, en segundos.
    pendientes: tuple[tuple[Fase, float], ...] = ()
    aviso: str | None = None


# --------------------------------------------------------------------------
# Fases
# --------------------------------------------------------------------------


def _minimo(a: int | None, b: int | None) -> int | None:
    if a is None:
        return b
    if b is None:
        return a
    return min(a, b)


def _vio(reg: Registro, fase: Fase) -> bool:
    return any(f is fase for f, *_ in reg.fases)


def _descarga_hecha(reg: Registro, lectura: Lectura) -> bool:
    """¿Ha llegado ya abajo la descarga de la fase 3?"""
    vio_descarga = _vio(reg, Fase.DESCARGA)
    # Mirando sin huecos y sin haberla visto, no ha pasado: cualquier bajada
    # es de haber quitado el cargador, que no cuenta.
    if not (vio_descarga or reg.hueco):
        return False
    minimo = reg.porcentaje_minimo
    if minimo is not None and minimo <= PCT_DESCARGA_HECHA:
        return True
    if (not vio_descarga and minimo is not None and reg.porcentaje_inicio is not None
            and minimo < reg.porcentaje_inicio - MARGEN_PCT):
        # No se vio descargar, pero esta por debajo de donde empezo, con el
        # cargador puesto: solo puede ser la recarga.
        return True
    return reg.inicio_conocido and lectura.momento - reg.inicio > S_DESCARGA_HECHA


def _fase_leida(reg: Registro, lectura: Lectura) -> Fase | None:
    """La fase que dice esta lectura, sin mirar las que ya se vieron."""
    if lectura.estado == "Discharging":
        # Sin cargador no es la descarga de la calibracion: la del EC va con
        # el cargador puesto.  No se apunta nada.
        return Fase.DESCARGA if lectura.en_corriente is not False else None
    hecha = _descarga_hecha(reg, lectura)
    llena = lectura.porcentaje is not None and lectura.porcentaje >= PCT_LLENA
    if lectura.estado == "Charging" or (lectura.estado in ("Full", "Not charging") and not llena):
        return Fase.RECARGA if hecha else Fase.CARGA
    if lectura.estado in ("Full", "Not charging"):
        return Fase.TERMINADA if hecha else Fase.ESPERA
    return None


def _fase(reg: Registro, lectura: Lectura) -> Fase | None:
    """La fase, sin volver nunca atras.

    Durante la espera el EC puede alternar «Full» y «Charging» mientras le
    entra corriente; sin esto, la interfaz saltaria de la fase 2 a la 1.
    """
    leida = _fase_leida(reg, lectura)
    if not reg.fases:
        return leida
    ultima_vista = reg.fases[-1][0]
    if leida is None or _ORDEN[leida] < _ORDEN[ultima_vista]:
        return ultima_vista
    return leida


def _registrar(reg: Registro, lectura: Lectura) -> Registro:
    hueco = reg.ultimo_visto is not None and lectura.momento - reg.ultimo_visto > S_HUECO_MAX
    minimo = reg.porcentaje_minimo
    if lectura.en_corriente is not False:
        minimo = _minimo(minimo, lectura.porcentaje)
    reg = replace(reg, porcentaje_minimo=minimo, hueco=reg.hueco or hueco)
    fase = _fase(reg, lectura)
    if fase is not None and (not reg.fases or reg.fases[-1][0] is not fase):
        # La primera se ve en el momento solo si se vio empezar la calibracion.
        exacta = reg.inicio_conocido if reg.ultimo_visto is None else not hueco
        reg = replace(reg, fases=(*reg.fases, (fase, lectura.momento, exacta)))
    return replace(reg, ultimo_visto=lectura.momento)


def _duraciones(reg: Registro) -> tuple[tuple[Fase, float], ...]:
    """Duracion de las fases cuyo principio y final se vieron en el momento.
    La que esta en curso no tiene final todavia y no sale."""
    return tuple(
        (fase, t1 - t0)
        for (fase, t0, exacta0), (_, t1, exacta1) in zip(reg.fases, reg.fases[1:])
        if exacta0 and exacta1
    )


def _cerrar(reg: Registro, lectura: Lectura) -> Ultima:
    vistas = {f for f, *_ in reg.fases}
    llena = lectura.porcentaje is not None and lectura.porcentaje >= PCT_LLENA
    completa = Fase.TERMINADA in vistas or (Fase.RECARGA in vistas and llena)
    # Se detuvo en plena recarga, con la bateria ya llena: la recarga acaba
    # ahora, pero solo si se estaba mirando.  Cerrar horas despues (todo
    # apagado entre medias) le pondria a la recarga una duracion falsa, y esa
    # duracion es la que usaria la calibracion siguiente para estimar.
    al_momento = (reg.ultimo_visto is not None
                  and lectura.momento - reg.ultimo_visto <= S_HUECO_MAX)
    if reg.fases and reg.fases[-1][0] is Fase.RECARGA and llena and al_momento:
        reg = replace(reg, fases=(*reg.fases, (Fase.TERMINADA, lectura.momento, True)))
    return Ultima(
        inicio=reg.inicio,
        fin=lectura.momento,
        llena_inicio=reg.llena_inicio,
        llena_fin=lectura.llena_uah,
        diseno=lectura.diseno_uah,
        completa=completa,
        duraciones=_duraciones(reg),
    )


def _nuevo_registro(lectura: Lectura, inicio_conocido: bool) -> Registro:
    return Registro(
        inicio=lectura.momento,
        inicio_conocido=inicio_conocido,
        porcentaje_inicio=lectura.porcentaje,
        llena_inicio=lectura.llena_uah,
        porcentaje_minimo=None,
        # Si ya estaba en marcha al empezar a mirar, todo lo de antes es hueco.
        hueco=not inicio_conocido,
    )


def empezar(estado: Estado, lectura: Lectura) -> Estado:
    """Se acaba de pulsar «Calibrar» y el firmware lo ha aceptado."""
    return replace(estado, en_curso=_registrar(_nuevo_registro(lectura, True), lectura))


def avanzar(estado: Estado, lectura: Lectura) -> Estado:
    """Apunta una lectura.  Abre el registro si la calibracion ya estaba en
    marcha sin haberla visto empezar, y lo cierra cuando termina."""
    reg = estado.en_curso
    if lectura.calibrando is None:
        # No se pudo leer si sigue en marcha: no se abre ni se cierra nada.
        return estado
    if not lectura.calibrando:
        if reg is None:
            return estado
        return Estado(en_curso=None, ultima=_cerrar(reg, lectura))
    if reg is None:
        reg = _nuevo_registro(lectura, False)
    return replace(estado, en_curso=_registrar(reg, lectura))


def avanzar_existente(estado: Estado, lectura: Lectura) -> Estado:
    """Como avanzar(), pero sin abrir nunca un registro nuevo.

    Es la de 'nitro-gekko --avisos', que lee battery_calibration ANTES de
    coger el fichero: si entre medias se pulso Detener en la ventana, su
    lectura dice «en marcha» y avanzar() reabriria una calibracion cerrada.
    Al cerrarla otra vez, pisaria el resultado bueno con uno a medias.
    Abrir le toca solo a la ventana, que relee justo antes.
    """
    if estado.en_curso is None:
        return estado
    return avanzar(estado, lectura)


def fase_actual(estado: Estado, lectura: Lectura) -> Fase | None:
    if estado.en_curso is None or not lectura.calibrando:
        return None
    return _fase(estado.en_curso, lectura)


# --------------------------------------------------------------------------
# Tiempos
# --------------------------------------------------------------------------


def _duracion_esperada(fase: Fase, estado: Estado) -> float:
    """La de la ultima calibracion completa si la hay y es creible; si no, la
    medida."""
    defecto = _DEFECTO_S[fase]
    ultima = estado.ultima
    if ultima is not None and ultima.completa:
        for f, segundos in ultima.duraciones:
            if f is fase and defecto / FACTOR_DURACION_MAX <= segundos <= defecto * FACTOR_DURACION_MAX:
                return segundos
    return defecto


def _inicio_visto(reg: Registro, fase: Fase) -> float | None:
    """Cuando se vio empezar esta fase, o None si no se vio en el momento."""
    for f, t, exacta in reg.fases:
        if f is fase:
            return t if exacta else None
    return None


def _restante_fase(estado: Estado, lectura: Lectura, fase: Fase) -> float | None:
    pct = lectura.porcentaje
    if fase is Fase.TERMINADA:
        return 0.0
    if fase is Fase.CARGA:
        return None if pct is None else max(100 - pct, 0) * MIN_POR_PUNTO_CARGA * 60
    total = _duracion_esperada(fase, estado)
    desde = _inicio_visto(estado.en_curso, fase)
    if desde is not None:
        return max(total - (lectura.momento - desde), 0.0)
    # Sin ver empezar la fase, por el porcentaje: es lo unico que queda.
    if fase is Fase.ESPERA or pct is None:
        return total
    tramo = 100 - PCT_FIN_DESCARGA
    if fase is Fase.DESCARGA:
        return total * max(pct - PCT_FIN_DESCARGA, 0) / tramo
    return total * max(100 - pct, 0) / tramo


def _aviso(lectura: Lectura) -> str | None:
    if lectura.en_corriente is False:
        return "Conecta el cargador: la calibracion lo necesita hasta el final."
    if (lectura.estado == "Not charging" and lectura.porcentaje is not None
            and lectura.porcentaje < PCT_LLENA):
        return (f"La bateria no carga y esta al {lectura.porcentaje} %. Si el limite "
                "de carga del 80 % esta puesto, quitalo: la calibracion necesita llenarla.")
    return None


def vista(estado: Estado, lectura: Lectura) -> Vista | None:
    reg = estado.en_curso
    if reg is None or not lectura.calibrando:
        return None
    fase = _fase(reg, lectura)
    ambigua = (fase in (Fase.CARGA, Fase.ESPERA)
               and not reg.inicio_conocido and not _descarga_hecha(reg, lectura))
    restante_fase = restante_total = progreso = None
    pendientes: tuple[tuple[Fase, float], ...] = ()
    if fase is not None:
        pendientes = tuple((f, _duracion_esperada(f, estado))
                           for f in FASES if _ORDEN[f] > _ORDEN[fase])
        restante_fase = _restante_fase(estado, lectura, fase)
        if restante_fase is not None:
            restante_total = restante_fase + sum(s for _, s in pendientes)
        if fase is Fase.TERMINADA:
            progreso = 1.0
        elif reg.inicio_conocido and restante_total is not None:
            hecho = lectura.momento - reg.inicio
            progreso = hecho / (hecho + restante_total) if hecho + restante_total > 0 else 0.0
    return Vista(
        fase=fase,
        ambigua=ambigua,
        restante_fase_s=restante_fase,
        restante_total_s=restante_total,
        progreso=progreso,
        duraciones=_duraciones(reg),
        pendientes=pendientes,
        aviso=_aviso(lectura),
    )


def lectura_de(detalle, *, calibrando: bool | None, en_corriente: bool | None,
               momento: float) -> Lectura:
    """Lectura a partir de un sysfs.DetalleBateria (o lo que tenga sus campos).

    Aqui no se importa sysfs a proposito: este modulo no toca /sys.
    """
    return Lectura(
        momento=momento,
        calibrando=calibrando,
        estado=detalle.estado,
        porcentaje=detalle.porcentaje,
        llena_uah=detalle.llena_uah,
        diseno_uah=detalle.diseno_uah,
        corriente_ua=detalle.corriente_ua,
        en_corriente=en_corriente,
    )


def formatear_duracion(segundos: float) -> str:
    minutos = round(segundos / 60)
    if minutos < 1:
        return "menos de 1 min"
    horas, minutos = divmod(minutos, 60)
    if not horas:
        return f"{minutos} min"
    return f"{horas} h" if not minutos else f"{horas} h {minutos} min"


def formatear_resultado(ultima: Ultima) -> str:
    """«3067 → 4051 mAh (52 % → 69 %)», o lo que se pueda de eso."""
    if ultima.llena_inicio is None or ultima.llena_fin is None:
        return ""
    texto = f"{ultima.llena_inicio // 1000} → {ultima.llena_fin // 1000} mAh"
    if ultima.diseno:
        antes = 100 * ultima.llena_inicio / ultima.diseno
        despues = 100 * ultima.llena_fin / ultima.diseno
        texto += f" ({antes:.0f} % → {despues:.0f} %)"
    return texto


# --------------------------------------------------------------------------
# Avisos para quien no tenga la ventana abierta (nitro-gekko --avisos)
# --------------------------------------------------------------------------


def notificaciones(estado: Estado, lectura: Lectura) -> tuple[Estado, list[str]]:
    """Lo que hay que avisar con esta lectura, una sola vez cada cosa.

    Se llama DESPUES de avanzar().  Lo ya avisado queda apuntado en el
    registro, que se guarda, para no repetirlo aunque se reinicie el proceso.
    """
    reg = estado.en_curso
    if reg is None:
        return estado, []
    mensajes = []
    if lectura.en_corriente is False and not reg.avisado_cargador:
        mensajes.append("Conecta el cargador: la calibracion lo necesita hasta el final.")
        reg = replace(reg, avisado_cargador=True)
    elif lectura.en_corriente and reg.avisado_cargador:
        reg = replace(reg, avisado_cargador=False)
    if _fase(reg, lectura) is Fase.TERMINADA and not reg.avisado_fin:
        mensajes.append(
            "Ha terminado, pero el firmware no la cierra solo: abre Nitro Gekko "
            "y pulsa Detener."
        )
        reg = replace(reg, avisado_fin=True)
    return replace(estado, en_curso=reg), mensajes


# --------------------------------------------------------------------------
# Estado guardado
#
# En $XDG_STATE_HOME/nitro-gekko/calibracion.json (~/.local/state/...): es
# estado, no preferencias, y por eso no va con ajustes.json.  Lo escriben la
# ventana y 'nitro-gekko --avisos', los dos por actualizar(): cargar, cambiar
# y guardar con un cerrojo (flock) en calibracion.json.lock, para que uno no
# pise lo que acaba de escribir el otro (por ejemplo, lo ya avisado, que se
# volveria a avisar).
# --------------------------------------------------------------------------

VERSION = 1


def ruta_estado() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(Path.home(), ".local", "state")
    return Path(base) / "nitro-gekko" / "calibracion.json"


def _a_dict_registro(reg: Registro) -> dict:
    return {
        "inicio": reg.inicio,
        "inicio_conocido": reg.inicio_conocido,
        "porcentaje_inicio": reg.porcentaje_inicio,
        "llena_inicio": reg.llena_inicio,
        "porcentaje_minimo": reg.porcentaje_minimo,
        "fases": [[f.value, t, exacta] for f, t, exacta in reg.fases],
        "hueco": reg.hueco,
        "ultimo_visto": reg.ultimo_visto,
        "avisado_fin": reg.avisado_fin,
        "avisado_cargador": reg.avisado_cargador,
    }


def _a_dict_ultima(u: Ultima) -> dict:
    return {
        "inicio": u.inicio,
        "fin": u.fin,
        "llena_inicio": u.llena_inicio,
        "llena_fin": u.llena_fin,
        "diseno": u.diseno,
        "completa": u.completa,
        "duraciones": [[f.value, s] for f, s in u.duraciones],
    }


# Los tipos se comprueban AL CARGAR.  Un porcentaje guardado como texto no
# fallaba aqui, sino mas tarde, en una comparacion dentro del temporizador de
# la ventana o de --avisos, y una excepcion ahi lo da de baja.

def _entero(v) -> int | None:
    if v is None or (isinstance(v, int) and not isinstance(v, bool)):
        return v
    raise TypeError(f"no es un entero: {v!r}")


def _real(v) -> float:
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v)
    raise TypeError(f"no es un numero: {v!r}")


def _real_o_none(v) -> float | None:
    return None if v is None else _real(v)


def _logico(v) -> bool:
    if isinstance(v, bool):
        return v
    raise TypeError(f"no es un si/no: {v!r}")


def _de_dict_registro(d: dict) -> Registro:
    fases = []
    for entrada in d.get("fases", []):
        fase, t, *resto = entrada
        fases.append((Fase(fase), _real(t), _logico(resto[0]) if resto else True))
    return Registro(
        inicio=_real(d["inicio"]),
        inicio_conocido=_logico(d["inicio_conocido"]),
        porcentaje_inicio=_entero(d.get("porcentaje_inicio")),
        llena_inicio=_entero(d.get("llena_inicio")),
        porcentaje_minimo=_entero(d.get("porcentaje_minimo")),
        fases=tuple(fases),
        hueco=_logico(d.get("hueco", True)),
        ultimo_visto=_real_o_none(d.get("ultimo_visto")),
        avisado_fin=_logico(d.get("avisado_fin", False)),
        avisado_cargador=_logico(d.get("avisado_cargador", False)),
    )


def _de_dict_ultima(d: dict) -> Ultima:
    return Ultima(
        inicio=_real(d["inicio"]),
        fin=_real(d["fin"]),
        llena_inicio=_entero(d.get("llena_inicio")),
        llena_fin=_entero(d.get("llena_fin")),
        diseno=_entero(d.get("diseno")),
        completa=_logico(d["completa"]),
        duraciones=tuple((Fase(f), _real(s)) for f, s in d.get("duraciones", [])),
    )


def cargar(ruta: Path | None = None) -> Estado:
    """El estado guardado.  Ante cualquier problema, uno vacio: un fichero
    roto no puede dejar la pagina de la bateria sin pintar."""
    try:
        datos = json.loads((ruta or ruta_estado()).read_text(encoding="utf-8"))
        if datos.get("version") != VERSION:
            return Estado()
        en_curso = datos.get("en_curso")
        ultima = datos.get("ultima")
        return Estado(
            en_curso=_de_dict_registro(en_curso) if en_curso else None,
            ultima=_de_dict_ultima(ultima) if ultima else None,
        )
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return Estado()


def guardar(estado: Estado, ruta: Path | None = None) -> bool:
    """Escribe de golpe (fichero temporal + fsync + rename): quien lea a la vez
    ve el viejo o el nuevo, nunca uno a medias, y un apagon no deja uno vacio.
    Devuelve False si no se pudo."""
    ruta = ruta or ruta_estado()
    datos = {
        "version": VERSION,
        "en_curso": _a_dict_registro(estado.en_curso) if estado.en_curso else None,
        "ultima": _a_dict_ultima(estado.ultima) if estado.ultima else None,
    }
    temporal = None
    try:
        ruta.parent.mkdir(parents=True, exist_ok=True)
        fd, temporal = tempfile.mkstemp(dir=ruta.parent, prefix=".calibracion-")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(datos, fh, indent=1)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(temporal, ruta)
        return True
    except OSError:
        # Un disco lleno no puede dejar temporales sueltos en ~/.local/state.
        if temporal is not None:
            try:
                os.unlink(temporal)
            except OSError:
                pass
        return False


def actualizar(cambio: Callable[[Estado], Estado],
               ruta: Path | None = None) -> tuple[Estado, bool]:
    """Carga, aplica *cambio* y guarda si algo cambio, con el cerrojo cogido.

    Devuelve el estado nuevo y si quedo guardado (True tambien si no habia
    nada que guardar).  Sin poder crear el cerrojo, se hace sin el: peor es
    no seguir la calibracion.
    """
    ruta = ruta or ruta_estado()
    try:
        ruta.parent.mkdir(parents=True, exist_ok=True)
        cerrojo = open(ruta.with_name(ruta.name + ".lock"), "a", encoding="utf-8")
    except OSError:
        cerrojo = None
    try:
        if cerrojo is not None:
            fcntl.flock(cerrojo, fcntl.LOCK_EX)
        estado = cargar(ruta)
        nuevo = cambio(estado)
        guardado = nuevo == estado or guardar(nuevo, ruta)
        return nuevo, guardado
    finally:
        if cerrojo is not None:
            cerrojo.close()
