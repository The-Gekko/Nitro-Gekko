"""Pruebas de src/gekkonitro/calibracion.py: fases, tiempos y estado guardado.

Python puro, sin hardware ni sesion grafica.  Desde la raiz del repositorio:

    PYTHONPATH=src python3 -m unittest discover -s tests -v

Los numeros de los casos salen de la calibracion medida en el AN17-51 la noche
del 2026-10-29 (ver la seccion de la calibracion en el README).
"""

from __future__ import annotations

import csv
import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from gekkonitro import calibracion as cal
from gekkonitro.calibracion import Fase

HORA = 3600.0
LLENA = 4_051_000
DISENO = 5_850_000


def lectura(momento, estado, porcentaje, *, calibrando=True, llena=LLENA,
            corriente=None, en_corriente=True):
    return cal.Lectura(
        momento=momento, calibrando=calibrando, estado=estado,
        porcentaje=porcentaje, llena_uah=llena, diseno_uah=DISENO,
        corriente_ua=corriente, en_corriente=en_corriente,
    )


def empezada(momento=0.0, porcentaje=82, llena=3_067_000):
    """Estado justo despues de pulsar «Calibrar» en la aplicacion."""
    return cal.empezar(cal.Estado(), lectura(momento, "Charging", porcentaje, llena=llena))


def seguir(estado, desde, hasta, estado_bat, porcentaje, paso=60.0, **kw):
    """Una lectura por minuto entre *desde* y *hasta* (horas), como la ventana
    abierta o 'nitro-gekko --avisos'.  Sin huecos, las fases cuentan."""
    t = desde * HORA
    while t <= hasta * HORA:
        estado = cal.avanzar(estado, lectura(t, estado_bat, porcentaje, **kw))
        t += paso
    return estado


def fases(estado):
    return [f for f, *_ in estado.en_curso.fases]


class FasesDeUnaNoche(unittest.TestCase):
    """La secuencia completa, vista desde la aplicacion abierta toda la noche."""

    def test_recorre_las_cuatro_fases_y_termina(self):
        estado = empezada()
        pasos = [
            (0.1 * HORA, "Charging", 95, Fase.CARGA),
            (0.2 * HORA, "Full", 100, Fase.ESPERA),
            (1.8 * HORA, "Discharging", 60, Fase.DESCARGA),
            (3.5 * HORA, "Discharging", 5, Fase.DESCARGA),
            (5.0 * HORA, "Charging", 10, Fase.RECARGA),
            (6.8 * HORA, "Full", 100, Fase.TERMINADA),
        ]
        for momento, estado_bat, pct, esperada in pasos:
            estado = cal.avanzar(estado, lectura(momento, estado_bat, pct))
            self.assertEqual(cal.fase_actual(estado, lectura(momento, estado_bat, pct)), esperada)
        self.assertEqual(fases(estado),
                         [Fase.CARGA, Fase.ESPERA, Fase.DESCARGA, Fase.RECARGA, Fase.TERMINADA])

    def test_al_detenerla_queda_el_resultado_y_se_cierra(self):
        estado = empezada()
        for momento, estado_bat, pct in [(0.2 * HORA, "Full", 100), (1.8 * HORA, "Discharging", 5),
                                         (5.0 * HORA, "Charging", 10), (6.8 * HORA, "Full", 100)]:
            estado = cal.avanzar(estado, lectura(momento, estado_bat, pct))
        estado = cal.avanzar(estado, lectura(8.0 * HORA, "Not charging", 100, calibrando=False))
        self.assertIsNone(estado.en_curso)
        ultima = estado.ultima
        self.assertTrue(ultima.completa)
        self.assertEqual(ultima.llena_inicio, 3_067_000)
        self.assertEqual(ultima.llena_fin, LLENA)
        self.assertEqual(ultima.diseno, DISENO)
        self.assertAlmostEqual(ultima.fin - ultima.inicio, 8.0 * HORA)

    def test_detenida_a_medias_no_cuenta_como_completa(self):
        estado = empezada()
        estado = cal.avanzar(estado, lectura(2 * HORA, "Discharging", 70))
        estado = cal.avanzar(estado, lectura(2.1 * HORA, "Discharging", 69, calibrando=False))
        self.assertFalse(estado.ultima.completa)

    def test_sin_calibracion_no_se_crea_nada(self):
        estado = cal.avanzar(cal.Estado(), lectura(0, "Charging", 50, calibrando=False))
        self.assertEqual(estado, cal.Estado())


class FasesSinHaberLoVisto(unittest.TestCase):
    """La aplicacion estuvo cerrada: hay que deducir la fase sin el historial."""

    def test_cargando_por_debajo_del_inicio_es_la_recarga(self):
        # Empezo al 82 %; ahora carga al 30 %: solo puede ser despues de descargar.
        estado = empezada(porcentaje=82)
        estado = cal.avanzar(estado, lectura(5 * HORA, "Charging", 30))
        self.assertEqual(cal.fase_actual(estado, lectura(5 * HORA, "Charging", 30)), Fase.RECARGA)

    def test_llena_a_las_siete_horas_es_que_ya_termino(self):
        estado = empezada(porcentaje=82)
        estado = cal.avanzar(estado, lectura(7 * HORA, "Full", 100))
        self.assertEqual(cal.fase_actual(estado, lectura(7 * HORA, "Full", 100)), Fase.TERMINADA)

    def test_llena_a_la_hora_todavia_espera(self):
        estado = empezada(porcentaje=82)
        estado = cal.avanzar(estado, lectura(1 * HORA, "Full", 100))
        self.assertEqual(cal.fase_actual(estado, lectura(1 * HORA, "Full", 100)), Fase.ESPERA)

    def test_empezada_fuera_de_la_app_no_adivina_por_el_tiempo(self):
        # La primera vez que la vemos ya estaba en marcha: no se sabe cuando
        # empezo, asi que una bateria llena es ambigua.
        estado = cal.avanzar(cal.Estado(), lectura(0, "Full", 100))
        self.assertFalse(estado.en_curso.inicio_conocido)
        vista = cal.vista(estado, lectura(8 * HORA, "Full", 100))
        self.assertEqual(vista.fase, Fase.ESPERA)
        self.assertTrue(vista.ambigua)
        self.assertIsNone(vista.progreso)

    def test_descargando_no_es_ambiguo_nunca(self):
        estado = cal.avanzar(cal.Estado(), lectura(0, "Discharging", 40))
        vista = cal.vista(estado, lectura(0, "Discharging", 40))
        self.assertEqual(vista.fase, Fase.DESCARGA)
        self.assertFalse(vista.ambigua)

    def test_parada_por_el_limite_del_80_avisa(self):
        # Con el limite puesto, la bateria se queda en «Not charging» al 80 %
        # y la calibracion no puede llenarla: es la fase de carga, atascada.
        estado = empezada(porcentaje=80)
        parada = lectura(0.5 * HORA, "Not charging", 80)
        vista = cal.vista(cal.avanzar(estado, parada), parada)
        self.assertEqual(vista.fase, Fase.CARGA)
        self.assertIn("80 %", vista.aviso)


class Tropiezos(unittest.TestCase):
    """Lecturas sueltas, cargador quitado, huecos y procesos que se pisan."""

    def test_un_cargando_suelto_en_plena_descarga_no_salta_a_la_recarga(self):
        estado = empezada()
        estado = seguir(estado, 1.7, 2.5, "Discharging", 50)
        estado = cal.avanzar(estado, lectura(2.51 * HORA, "Charging", 50))
        estado = cal.avanzar(estado, lectura(2.52 * HORA, "Discharging", 49))
        self.assertEqual(cal.fase_actual(estado, lectura(2.52 * HORA, "Discharging", 49)),
                         Fase.DESCARGA)
        self.assertNotIn(Fase.RECARGA, fases(estado))

    def test_desenchufar_en_la_carga_no_cuenta_como_descarga(self):
        # Quitar el cargador un rato en la fase 1 baja el porcentaje, pero no
        # es la descarga de la calibracion: esa va con el cargador puesto.
        estado = empezada(porcentaje=82)
        estado = seguir(estado, 0.0, 0.3, "Discharging", 70, en_corriente=False)
        estado = seguir(estado, 0.31, 0.4, "Charging", 71)
        self.assertEqual(fases(estado), [Fase.CARGA])
        self.assertEqual(cal.fase_actual(estado, lectura(0.4 * HORA, "Charging", 71)), Fase.CARGA)

    def test_un_hueco_largo_no_cuenta_para_las_duraciones(self):
        # Nadie miro entre las 0,5 h y las 4 h: no se sabe cuando empezo la
        # descarga, asi que ni la espera tiene duracion ni la descarga se
        # cuenta por el reloj (va por el porcentaje).
        estado = empezada()
        estado = seguir(estado, 0.1, 0.5, "Full", 100)
        ahora = lectura(4.0 * HORA, "Discharging", 40)
        estado = cal.avanzar(estado, ahora)
        vista = cal.vista(estado, ahora)
        self.assertNotIn(Fase.ESPERA, dict(vista.duraciones))
        esperado = (40 - cal.PCT_FIN_DESCARGA) / (100 - cal.PCT_FIN_DESCARGA) * cal.MIN_DESCARGA * 60
        self.assertAlmostEqual(vista.restante_fase_s, esperado, delta=1)

    def test_cerrar_horas_despues_no_infla_la_recarga(self):
        estado = empezada()
        estado = seguir(estado, 0.05, 1.7, "Full", 100)
        estado = seguir(estado, 1.71, 4.9, "Discharging", 5)
        estado = seguir(estado, 4.91, 5.5, "Charging", 40)
        # Todo cerrado a las 5,5 h; se vuelve a mirar a las 9 h, ya parada.
        estado = cal.avanzar(estado, lectura(9.0 * HORA, "Full", 100, calibrando=False))
        duraciones = dict(estado.ultima.duraciones)
        self.assertTrue(estado.ultima.completa)
        self.assertIn(Fase.DESCARGA, duraciones)
        self.assertNotIn(Fase.RECARGA, duraciones)

    def test_una_duracion_guardada_absurda_se_ignora(self):
        anterior = cal.Ultima(inicio=0, fin=1, llena_inicio=1, llena_fin=1, diseno=1,
                              completa=True, duraciones=((Fase.DESCARGA, 20 * HORA),))
        estado = cal.empezar(cal.Estado(ultima=anterior), lectura(0, "Discharging", 99))
        vista = cal.vista(estado, lectura(0, "Discharging", 99))
        self.assertAlmostEqual(vista.restante_fase_s, cal.MIN_DESCARGA * 60, delta=1)

    def test_avanzar_existente_no_resucita_una_cerrada(self):
        # 'nitro-gekko --avisos' leyo «en marcha» justo antes de que se pulsara
        # Detener en la ventana: con esa lectura vieja no puede volver a abrirla.
        cerrada = cal.Estado(ultima=cal.Ultima(inicio=0, fin=1, llena_inicio=1, llena_fin=2,
                                               diseno=3, completa=True))
        self.assertEqual(cal.avanzar_existente(cerrada, lectura(5, "Full", 100)), cerrada)


class Tiempos(unittest.TestCase):

    def test_carga_inicial_por_porcentaje_y_el_resto_por_lo_medido(self):
        estado = empezada(porcentaje=82)
        vista = cal.vista(estado, lectura(0, "Charging", 82))
        carga = (100 - 82) * cal.MIN_POR_PUNTO_CARGA * 60
        self.assertAlmostEqual(vista.restante_fase_s, carga, delta=1)
        resto = (cal.MIN_ESPERA + cal.MIN_DESCARGA + cal.MIN_RECARGA) * 60
        self.assertAlmostEqual(vista.restante_total_s, carga + resto, delta=1)

    def test_descarga_cuenta_desde_que_empezo_la_fase(self):
        # El medidor descalibrado no baja parejo (marcaba 6 % con 47 min por
        # delante): lo que si es estable es la duracion, a corriente fija.
        estado = empezada()
        estado = seguir(estado, 0.05, 1.79, "Full", 100)
        estado = seguir(estado, 1.8, 2.8, "Discharging", 40)
        vista = cal.vista(estado, lectura(2.8 * HORA, "Discharging", 40))
        self.assertAlmostEqual(vista.restante_fase_s, (cal.MIN_DESCARGA - 60) * 60, delta=61)
        self.assertAlmostEqual(vista.restante_total_s,
                               (cal.MIN_DESCARGA - 60 + cal.MIN_RECARGA) * 60, delta=61)

    def test_descarga_sin_ver_su_inicio_va_por_porcentaje(self):
        ahora = lectura(0, "Discharging", 52)
        vista = cal.vista(cal.avanzar(cal.Estado(), ahora), ahora)
        esperado = (52 - cal.PCT_FIN_DESCARGA) / (100 - cal.PCT_FIN_DESCARGA) * cal.MIN_DESCARGA * 60
        self.assertAlmostEqual(vista.restante_fase_s, esperado, delta=1)

    def test_usa_las_duraciones_de_la_ultima_calibracion(self):
        anterior = cal.Ultima(inicio=0, fin=1, llena_inicio=1, llena_fin=1, diseno=1,
                              completa=True, duraciones=((Fase.DESCARGA, 150 * 60.0),))
        estado = cal.empezar(cal.Estado(ultima=anterior), lectura(0, "Discharging", 99))
        vista = cal.vista(estado, lectura(0, "Discharging", 99))
        self.assertAlmostEqual(vista.restante_fase_s, 150 * 60, delta=1)

    def test_espera_cuenta_desde_que_empezo_la_fase(self):
        estado = empezada()
        estado = seguir(estado, 0.01, 0.49, "Charging", 90)
        estado = seguir(estado, 0.5, 1.0, "Full", 100)
        vista = cal.vista(estado, lectura(1.0 * HORA, "Full", 100))
        self.assertAlmostEqual(vista.restante_fase_s, (cal.MIN_ESPERA - 30) * 60, delta=61)

    def test_espera_pasada_de_tiempo_no_da_negativo(self):
        estado = empezada()
        estado = seguir(estado, 0.01, 3.0, "Full", 100)
        vista = cal.vista(estado, lectura(3.0 * HORA, "Full", 100))
        self.assertEqual(vista.restante_fase_s, 0)

    def test_terminada_no_tiene_nada_pendiente(self):
        estado = empezada()
        for momento, estado_bat, pct in [(2 * HORA, "Discharging", 50), (5 * HORA, "Charging", 6),
                                         (6 * HORA, "Full", 100)]:
            estado = cal.avanzar(estado, lectura(momento, estado_bat, pct))
        vista = cal.vista(estado, lectura(6 * HORA, "Full", 100))
        self.assertEqual(vista.fase, Fase.TERMINADA)
        self.assertEqual(vista.restante_total_s, 0)
        self.assertEqual(vista.progreso, 1.0)

    def test_progreso_solo_con_inicio_conocido(self):
        estado = empezada()
        ahora = lectura(2 * HORA, "Discharging", 60, corriente=1_230_000)
        vista = cal.vista(cal.avanzar(estado, ahora), ahora)
        self.assertGreater(vista.progreso, 0.0)
        self.assertLess(vista.progreso, 1.0)

    def test_duraciones_de_las_fases_ya_hechas(self):
        estado = empezada(momento=0.0)
        estado = seguir(estado, 0.01, 0.09, "Charging", 95)
        estado = seguir(estado, 0.1, 1.69, "Full", 100)
        estado = seguir(estado, 1.7, 1.7, "Discharging", 99)
        vista = cal.vista(estado, lectura(1.7 * HORA, "Discharging", 99))
        duraciones = dict(vista.duraciones)
        self.assertAlmostEqual(duraciones[Fase.CARGA], 0.1 * HORA, delta=60)
        self.assertAlmostEqual(duraciones[Fase.ESPERA], 1.6 * HORA, delta=60)
        self.assertNotIn(Fase.DESCARGA, duraciones)

    def test_al_cerrar_guarda_las_duraciones_vistas(self):
        estado = empezada(momento=0.0)
        estado = seguir(estado, 0.05, 1.69, "Full", 100)
        estado = seguir(estado, 1.7, 4.99, "Discharging", 5)
        estado = seguir(estado, 5.0, 6.79, "Charging", 40)
        estado = seguir(estado, 6.8, 6.9, "Full", 100)
        estado = cal.avanzar(estado, lectura(6.95 * HORA, "Full", 100, calibrando=False))
        duraciones = dict(estado.ultima.duraciones)
        self.assertAlmostEqual(duraciones[Fase.DESCARGA], 3.3 * HORA, delta=60)
        self.assertAlmostEqual(duraciones[Fase.RECARGA], 1.8 * HORA, delta=60)

    def test_formato_de_duraciones(self):
        self.assertEqual(cal.formatear_duracion(30), "menos de 1 min")
        self.assertEqual(cal.formatear_duracion(45 * 60), "45 min")
        self.assertEqual(cal.formatear_duracion(2 * HORA + 5 * 60), "2 h 5 min")
        self.assertEqual(cal.formatear_duracion(3 * HORA), "3 h")


class Avisos(unittest.TestCase):

    def test_sin_cargador_avisa_una_vez(self):
        estado = empezada()
        sin = lectura(1 * HORA, "Discharging", 90, en_corriente=False)
        estado, mensajes = cal.notificaciones(cal.avanzar(estado, sin), sin)
        self.assertEqual(len(mensajes), 1)
        self.assertIn("cargador", mensajes[0])
        estado, mensajes = cal.notificaciones(cal.avanzar(estado, sin), sin)
        self.assertEqual(mensajes, [])

    def test_al_terminar_avisa_que_hay_que_detenerla(self):
        estado = empezada()
        estado = cal.avanzar(estado, lectura(2 * HORA, "Discharging", 50))
        estado = cal.avanzar(estado, lectura(5 * HORA, "Charging", 8))
        fin = lectura(6 * HORA, "Full", 100)
        estado, mensajes = cal.notificaciones(cal.avanzar(estado, fin), fin)
        self.assertEqual(len(mensajes), 1)
        self.assertIn("Detener", mensajes[0])
        _, mensajes = cal.notificaciones(cal.avanzar(estado, fin), fin)
        self.assertEqual(mensajes, [])


class LaNocheDeVerdad(unittest.TestCase):
    """Las 488 lecturas reales, una por minuto, de la calibracion del
    2026-10-29 (tests/datos/calibracion-2026-10-29.csv), pasadas por el modulo.

    Las duraciones de referencia salen de esta misma noche, asi que esto no
    prueba que las estimaciones acierten en otra: prueba que la deteccion de
    fases y el cierre no se rompan.
    """

    CSV = Path(__file__).parent / "datos" / "calibracion-2026-10-29.csv"

    def _repasar(self):
        with open(self.CSV, encoding="utf-8") as fh:
            filas = list(csv.DictReader(fh))
        lecturas = [
            (f["hora"][11:16], cal.Lectura(
                momento=datetime.strptime(f["hora"], "%Y-%m-%d %H:%M:%S").timestamp(),
                calibrando=f["calibracion"] == "1", estado=f["estado"],
                porcentaje=int(f["porcentaje"]), llena_uah=int(f["charge_full"]),
                diseno_uah=DISENO, corriente_ua=int(f["current_now"]),
                en_corriente=f["cargador"] == "1"))
            for f in filas
        ]
        estado = cal.empezar(cal.Estado(), lecturas[0][1])
        cambios, vistas = [], {}
        for hora, lec in lecturas[1:]:
            estado = cal.avanzar(estado, lec)
            v = cal.vista(estado, lec)
            if v is not None:
                vistas[hora] = v
                if not cambios or cambios[-1][1] is not v.fase:
                    cambios.append((hora, v.fase))
        return estado, cambios, vistas

    def test_cada_fase_en_el_minuto_en_que_paso(self):
        _, cambios, _ = self._repasar()
        self.assertEqual(cambios, [
            ("02:37", Fase.CARGA), ("02:39", Fase.ESPERA), ("04:15", Fase.DESCARGA),
            ("07:32", Fase.RECARGA), ("09:19", Fase.TERMINADA),
        ])

    def test_el_cierre_da_el_resultado_de_esa_noche(self):
        estado, _, _ = self._repasar()
        self.assertIsNone(estado.en_curso)
        self.assertTrue(estado.ultima.completa)
        self.assertEqual(cal.formatear_resultado(estado.ultima), "3067 → 4051 mAh (52 % → 69 %)")
        self.assertEqual({f for f, _ in estado.ultima.duraciones},
                         {Fase.CARGA, Fase.ESPERA, Fase.DESCARGA, Fase.RECARGA})

    def test_a_media_descarga_el_total_que_falta_cuadra(self):
        # A las 05:36 faltaban 3 h 43 min para llegar al 100 % final (09:19).
        _, _, vistas = self._repasar()
        self.assertAlmostEqual(vistas["05:36"].restante_total_s, (3 * 60 + 43) * 60, delta=120)


class EstadoGuardado(unittest.TestCase):

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.ruta = Path(self._dir.name) / "sub" / "calibracion.json"

    def tearDown(self):
        self._dir.cleanup()

    def test_ida_y_vuelta(self):
        estado = seguir(empezada(), 0.01, 0.2, "Full", 100)
        cal.guardar(estado, self.ruta)
        self.assertEqual(cal.cargar(self.ruta), estado)

    def test_sin_fichero_es_un_estado_vacio(self):
        self.assertEqual(cal.cargar(self.ruta), cal.Estado())

    def test_fichero_roto_no_tumba_la_aplicacion(self):
        self.ruta.parent.mkdir(parents=True)
        self.ruta.write_text("{esto no es json", encoding="utf-8")
        self.assertEqual(cal.cargar(self.ruta), cal.Estado())

    def test_version_desconocida_se_ignora(self):
        self.ruta.parent.mkdir(parents=True)
        self.ruta.write_text(json.dumps({"version": 99}), encoding="utf-8")
        self.assertEqual(cal.cargar(self.ruta), cal.Estado())

    def test_tipos_raros_en_el_fichero_dan_estado_vacio(self):
        # Un porcentaje como texto rompia la comparacion mas tarde, dentro del
        # temporizador, en vez de aqui.
        cal.guardar(empezada(), self.ruta)
        datos = json.loads(self.ruta.read_text(encoding="utf-8"))
        datos["en_curso"]["porcentaje_inicio"] = "82"
        self.ruta.write_text(json.dumps(datos), encoding="utf-8")
        self.assertEqual(cal.cargar(self.ruta), cal.Estado())

    def test_actualizar_carga_aplica_y_guarda(self):
        cal.guardar(empezada(), self.ruta)
        nuevo, guardado = cal.actualizar(
            lambda e: cal.avanzar(e, lectura(60, "Full", 100)), self.ruta)
        self.assertTrue(guardado)
        self.assertEqual(cal.cargar(self.ruta), nuevo)
        self.assertEqual(fases(nuevo), [Fase.CARGA, Fase.ESPERA])


if __name__ == "__main__":
    unittest.main()
