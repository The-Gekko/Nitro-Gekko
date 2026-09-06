/* extension.js — Nitro Gekko
 *
 * Toggle de Configuración rápida para cambiar el perfil térmico del
 * Acer Nitro AN17-51 sin abrir la aplicación completa.
 *
 * API verificada contra GNOME Shell 50.4 real (gjs 1.88.1) extrayendo el
 * JavaScript del gresource incrustado en /usr/lib/gnome-shell/libshell-18.so.
 * Nada de esto viene de una guía de GNOME 45: las firmas están comprobadas.
 *
 * Reglas que se respetan aquí, y por qué:
 *  - TODO el acceso a ficheros y TODO lanzamiento de procesos es asíncrono.
 *    Una llamada síncrona en el proceso de gnome-shell congela el compositor
 *    entero. Medido: lanzar un proceso con Gio.Subprocess cuesta 7 ms y el
 *    shell sigue respondiendo en 11-18 ms mientras el hijo corre 3 s.
 *  - El temporizador de RPM sólo vive mientras el menú está abierto. Con el
 *    menú cerrado no queda ni un solo temporizador corriendo.
 *  - Ningún cambio de perfil se da por bueno sin RELEERLO de sysfs. Hay al
 *    menos un camino (ver ponerPerfilPpd) que responde «correcto» sin haber
 *    hecho nada.
 */

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import Shell from 'gi://Shell';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import {QuickMenuToggle, SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';

// ---------------------------------------------------------------------------
// Rutas de sysfs. Verificadas en la máquina; no inventar ni "arreglar".
// ---------------------------------------------------------------------------

/* El fichero legacy es el que hay que escribir y el que notifica los cambios.
 * Escribir en /sys/class/platform-profile/platform-profile-0/profile funciona
 * pero NO dispara notificación en ese mismo fichero. */
const RUTA_PERFIL = '/sys/firmware/acpi/platform_profile';

/* La lista de perfiles se lee de aquí. Nunca se codifica a fuego. */
const RUTA_PERFILES_DISPONIBLES =
    '/sys/class/platform-profile/platform-profile-0/choices';

/* El número de hwmon CAMBIA entre arranques: siempre hay que resolverlo.
 * Plan A: la ruta de la plataforma acer-wmi, que tiene un único hijo hwmonN.
 * Plan B: recorrer /sys/class/hwmon buscando el que se llame 'acer'. */
const RUTA_HWMON_PLATAFORMA = '/sys/devices/platform/acer-wmi/hwmon';
const RUTA_HWMON_CLASE = '/sys/class/hwmon';

/* Helper privilegiado del paquete principal. La extensión NO lo trae ni lo
 * puede instalar: sólo lo usa si el instalador lo ha dejado puesto, y siempre
 * a través de pkexec. Mismas rutas candidatas que busca la aplicación en
 * src/gekkonitro/sysfs.py, para que las dos coincidan siempre. */
const RUTAS_HELPER = [
    '/usr/lib/nitro-gekko/nitro-gekko-helper',
    '/usr/local/lib/nitro-gekko/nitro-gekko-helper',
];

/* Fichero .desktop de la aplicación completa. El botón para abrirla sólo
 * aparece si la aplicación está realmente instalada. */
const ID_APLICACION = 'org.thegekko.nitrogekko.desktop';

/* Cada cuánto se refrescan las RPM, SÓLO con el menú abierto. */
const INTERVALO_RPM_SEGUNDOS = 2;

/* Cuántas veces se relee platform_profile antes de dar un cambio por fallido,
 * y cuánto se espera entre lecturas. Una lectura suelta puede mentir; el
 * porqué, con la medida que lo demuestra, está en _perfilRealEs(). */
const INTENTOS_LECTURA_PERFIL = 3;
const MS_ENTRE_LECTURAS = 120;

/* Atenuación de las RPM de referencia, 0-255.
 *
 * OJO: esto NO se puede hacer desde stylesheet.css. St ignora la propiedad CSS
 * 'opacity' por completo — no está entre las que entiende. Comprobado dentro de
 * gnome-shell 50.4: a un St.Label con set_style('opacity: 0.2') y con
 * set_style('opacity: 51') le siguen quedando actor.opacity y
 * get_paint_opacity() en 255, mientras que 'font-size' y 'color' puestos por la
 * misma vía sí se aplican. (El propio tema del Shell tiene una regla
 * 'opacity: 0.5' que tampoco hace nada.) Así que se atenúa desde aquí, que es
 * lo único que funciona, y además compone bien sobre el tema claro y el oscuro
 * sin escribir ningún color a fuego. */
const OPACIDAD_RPM_REFERENCIA = 160;

/* Perfil neutro al que vuelve el toggle cuando se pulsa estando activo.
 * Es sólo el PREFERIDO: el perfil neutro de verdad se elige en tiempo de
 * ejecución de entre los que el kernel expone en 'choices'. El contrato del
 * proyecto prohíbe dar por hecho que un perfil concreto existe. */
const PERFIL_NEUTRO_PREFERIDO = 'balanced';

/* Perfil roto: escribirlo hace que power-profiles-daemon caiga en
 * g_return_val_if_reached() y deje ActiveProfile en UNSET, porque su tabla
 * interna compara 'balanced_performance' con GUION BAJO. El efecto visible es
 * que el menú de energía de GNOME se queda EN BLANCO. No se oculta el perfil:
 * se avisa. */
const PERFIL_CON_BUG_PPD = 'balanced-performance';

/* Nombres bonitos e iconos por perfil. Es sólo una tabla de presentación: la
 * lista real de perfiles sale de 'choices', y cualquier perfil que aparezca ahí
 * y no esté en esta tabla se muestra igualmente con un nombre derivado. */
const PRESENTACION_PERFILES = {
    'low-power': {
        nombre: 'Bajo consumo',
        icono: 'power-profile-power-saver-symbolic',
        rpmTipicas: 1663,
    },
    'quiet': {
        nombre: 'Silencioso',
        icono: 'power-profile-power-saver-symbolic',
        rpmTipicas: 1661,
    },
    'balanced': {
        nombre: 'Equilibrado',
        icono: 'power-profile-balanced-symbolic',
        rpmTipicas: 2200,
    },
    'balanced-performance': {
        nombre: 'Equilibrado con rendimiento',
        icono: 'power-profile-performance-symbolic',
        rpmTipicas: 2377,
    },
    'performance': {
        nombre: 'Rendimiento',
        icono: 'power-profile-performance-symbolic',
        rpmTipicas: 3237,
    },
};

const PRESENTACION_POR_DEFECTO = {
    nombre: 'Personalizado',
    icono: 'power-profile-balanced-symbolic',
    rpmTipicas: null,
};

/**
 * Devuelve nombre e icono de un perfil, derivando algo razonable si el kernel
 * expone un perfil que esta versión no conoce.
 *
 * @param {string} id identificador crudo del perfil, tal cual está en sysfs
 * @returns {{nombre: string, icono: string, rpmTipicas: ?number}} presentación
 */
function presentacionDe(id) {
    // Object.hasOwn, NO «if (PRESENTACION_PERFILES[id])». Con la forma corta,
    // un perfil llamado 'constructor', 'toString' o 'valueOf' devuelve el
    // miembro HEREDADO de Object.prototype, que no tiene ni nombre ni icono, y
    // la extensión revienta al asignarlos. Reproducido dentro de gnome-shell:
    // «JS ERROR: Error: Wrong type undefined; string expected» en _sincronizar.
    if (typeof id === 'string' && Object.hasOwn(PRESENTACION_PERFILES, id))
        return PRESENTACION_PERFILES[id];

    // Perfil desconocido: 'algo-raro' -> 'Algo raro'.
    const legible = String(id ?? '').replace(/[-_]/g, ' ').trim();
    return {
        ...PRESENTACION_POR_DEFECTO,
        nombre: legible
            ? legible.charAt(0).toUpperCase() + legible.slice(1)
            : PRESENTACION_POR_DEFECTO.nombre,
    };
}

// ---------------------------------------------------------------------------
// Envoltorios asíncronos sobre Gio.
//
// gjs 1.88 NO auto-promisifica los métodos async de Gio (comprobado: llamar a
// load_contents_async sin callback lanza TypeError). Y la lista que gnome-shell
// promisifica de forma global está en ui/environment.js: de lo que usamos aquí,
// sólo entran Gio.File.query_info_async y Gio.DBusConnection.call. Se quedan
// fuera load_contents_async, replace_contents_bytes_async,
// enumerate_children_async, next_files_async y communicate_utf8_async.
//
// En vez de promisificar nosotros lo que falta —que mutaría los prototipos para
// TODO el proceso de gnome-shell, compartido con las demás extensiones—, se
// envuelven los callbacks a mano. Cuesta cuatro líneas y no toca nada ajeno.
// Los dos que el Shell ya promisifica se siguen llamando con callback a
// propósito, para que todo el fichero tenga la misma forma: Gio._promisify
// respeta el callback cuando se le pasa uno (comprobado con gjs 1.88).
// ---------------------------------------------------------------------------

/**
 * Lee un fichero de texto completo de forma asíncrona.
 *
 * @param {string} ruta ruta absoluta del fichero
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<string>} contenido sin espacios sobrantes
 */
function leerTexto(ruta, cancelable) {
    return new Promise((resolver, rechazar) => {
        Gio.File.new_for_path(ruta).load_contents_async(cancelable, (fichero, res) => {
            try {
                const [correcto, datos] = fichero.load_contents_finish(res);
                if (!correcto)
                    throw new Error(`No se pudo leer ${ruta}`);
                resolver(new TextDecoder().decode(datos).trim());
            } catch (e) {
                rechazar(e);
            }
        });
    });
}

/**
 * Escribe texto en un fichero de forma asíncrona.
 *
 * IMPORTANTE: las banderas tienen que ser Gio.FileCreateFlags.NONE. Con
 * REPLACE_DESTINATION, GLib intenta crear un fichero temporal en el mismo
 * directorio y renombrarlo encima, algo IMPOSIBLE en sysfs porque el directorio
 * no es escribible. Comprobado en esta máquina reproduciendo el caso (fichero
 * escribible dentro de un directorio 0555): con NONE escribe en el sitio y no
 * deja basura; con REPLACE_DESTINATION falla con «Permiso denegado».
 *
 * @param {string} ruta ruta absoluta del fichero
 * @param {string} texto contenido a escribir
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<void>} promesa que falla si no hay permiso
 */
function escribirTexto(ruta, texto, cancelable) {
    return new Promise((resolver, rechazar) => {
        const fichero = Gio.File.new_for_path(ruta);
        const bytes = new GLib.Bytes(new TextEncoder().encode(texto));
        fichero.replace_contents_bytes_async(
            bytes, null, false, Gio.FileCreateFlags.NONE, cancelable,
            (obj, res) => {
                try {
                    obj.replace_contents_finish(res);
                    resolver();
                } catch (e) {
                    rechazar(e);
                }
            });
    });
}

/**
 * ¿Existe esta ruta? Comprobación asíncrona; nunca lanza.
 *
 * @param {string} ruta ruta absoluta a comprobar
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<boolean>} true si la ruta existe y se puede consultar
 */
function existe(ruta, cancelable) {
    return new Promise(resolver => {
        Gio.File.new_for_path(ruta).query_info_async(
            Gio.FILE_ATTRIBUTE_STANDARD_TYPE, Gio.FileQueryInfoFlags.NONE,
            GLib.PRIORITY_DEFAULT, cancelable, (obj, res) => {
                try {
                    obj.query_info_finish(res);
                    resolver(true);
                } catch (e) {
                    resolver(false);
                }
            });
    });
}

/**
 * Lista los nombres de los hijos de un directorio de forma asíncrona.
 *
 * @param {string} ruta directorio a listar
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<string[]>} nombres de los hijos
 */
async function listarDirectorio(ruta, cancelable) {
    const enumerador = await new Promise((resolver, rechazar) => {
        Gio.File.new_for_path(ruta).enumerate_children_async(
            Gio.FILE_ATTRIBUTE_STANDARD_NAME, Gio.FileQueryInfoFlags.NONE,
            GLib.PRIORITY_DEFAULT, cancelable, (obj, res) => {
                try {
                    resolver(obj.enumerate_children_finish(res));
                } catch (e) {
                    rechazar(e);
                }
            });
    });

    const nombres = [];
    try {
        for (;;) {
            // next_files_async, no next_file(): next_file() es síncrono.
            const lote = await new Promise((resolver, rechazar) => {
                enumerador.next_files_async(
                    64, GLib.PRIORITY_DEFAULT, cancelable, (obj, res) => {
                        try {
                            resolver(obj.next_files_finish(res));
                        } catch (e) {
                            rechazar(e);
                        }
                    });
            });

            if (lote.length === 0)
                break;
            for (const info of lote)
                nombres.push(info.get_name());
        }
    } finally {
        // En 'finally' a propósito: si next_files_async falla a media lista, sin
        // esto el descriptor del directorio se quedaría abierto para siempre.
        enumerador.close_async(GLib.PRIORITY_DEFAULT, null, null);
    }

    return nombres;
}

// ---------------------------------------------------------------------------
// power-profiles-daemon
// ---------------------------------------------------------------------------

const PPD_NOMBRE = 'org.freedesktop.UPower.PowerProfiles';
const PPD_RUTA = '/org/freedesktop/UPower/PowerProfiles';

/**
 * Mapeo entre los perfiles del kernel y los que conoce power-profiles-daemon.
 *
 * POR QUE ESTO IMPORTA: PPD expone la acción polkit
 * org.freedesktop.UPower.PowerProfiles.switch-profile con «implicit active: yes»,
 * es decir, la sesión activa puede cambiar de perfil SIN CONTRASEÑA. Y PPD
 * escribe el platform_profile por nosotros, como root. Comprobado en esta
 * máquina: poner ActiveProfile=power-saver deja platform_profile en low-power.
 *
 * Así que para tres de los cinco perfiles no hace falta ni regla de udev ni
 * pkexec: basta pedírselo a PPD. Los otros dos («quiet» y
 * «balanced-performance») PPD no los conoce y hay que escribirlos por otra vía.
 *
 * Es un Map y no un objeto literal por lo mismo que presentacionDe() usa
 * Object.hasOwn: con un objeto, PERFIL_A_PPD['constructor'] devolvería una
 * función heredada de Object.prototype en vez de undefined, y acabaríamos
 * metiendo esa función en un GLib.Variant('s').
 */
const PERFIL_A_PPD = new Map([
    ['low-power', 'power-saver'],
    ['balanced', 'balanced'],
    ['performance', 'performance'],
]);

/**
 * Llama a un método de D-Bus del sistema y devuelve la respuesta.
 *
 * @param {string} interfaz nombre de la interfaz
 * @param {string} metodo nombre del método
 * @param {?GLib.Variant} argumentos argumentos empaquetados
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<GLib.Variant>} respuesta cruda
 */
function llamarPpd(interfaz, metodo, argumentos, cancelable) {
    return new Promise((resolver, rechazar) => {
        Gio.DBus.system.call(
            PPD_NOMBRE, PPD_RUTA, interfaz, metodo, argumentos,
            null, Gio.DBusCallFlags.NONE, 5000, cancelable,
            (fuente, res) => {
                try {
                    resolver(fuente.call_finish(res));
                } catch (e) {
                    rechazar(e);
                }
            });
    });
}

/**
 * Lee una propiedad de power-profiles-daemon.
 *
 * @param {string} propiedad nombre de la propiedad
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<*>} valor ya desempaquetado
 */
async function leerPropiedadPpd(propiedad, cancelable) {
    const respuesta = await llamarPpd(
        'org.freedesktop.DBus.Properties', 'Get',
        new GLib.Variant('(ss)', [PPD_NOMBRE, propiedad]), cancelable);
    const [valor] = respuesta.recursiveUnpack();
    return valor;
}

/**
 * Asigna ActiveProfile de una sola llamada, sin comprobar nada.
 *
 * @param {string} ppd nombre del perfil en PPD
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<void>} promesa que falla si PPD rechaza el cambio
 */
async function asignarPerfilPpd(ppd, cancelable) {
    await llamarPpd(
        'org.freedesktop.DBus.Properties', 'Set',
        new GLib.Variant('(ssv)', [PPD_NOMBRE, 'ActiveProfile',
            new GLib.Variant('s', ppd)]),
        cancelable);
}

/**
 * Elige un perfil de PPD distinto del que se quiere poner, para el empujón.
 *
 * @param {string} objetivo perfil de PPD al que se quiere llegar
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<?string>} otro perfil que PPD conozca, o null si no hay
 */
async function otroPerfilPpd(objetivo, cancelable) {
    // La lista se pide a PPD en vez de codificarla: PPD publica los perfiles
    // que de verdad tiene, y son tres o menos según el hardware.
    let lista;
    try {
        lista = await leerPropiedadPpd('Profiles', cancelable);
    } catch (e) {
        lista = null;
    }

    const nombres = Array.isArray(lista)
        ? lista.map(entrada => entrada?.Profile).filter(n => typeof n === 'string')
        : [];

    // Se prefiere 'balanced' como perfil de paso: es el menos brusco de los
    // tres. Sólo se va a 'power-saver' cuando el objetivo ES 'balanced'.
    const preferidos = ['balanced', 'power-saver', 'performance'];
    for (const candidato of preferidos) {
        if (candidato !== objetivo && nombres.includes(candidato))
            return candidato;
    }
    return nombres.find(n => n !== objetivo) ?? null;
}

/**
 * Cambia el perfil pidiéndoselo a power-profiles-daemon por D-Bus.
 *
 * EL EMPUJÓN, Y POR QUÉ HACE FALTA:
 *
 * PPD guarda el perfil activo en una variable suya y, si le pides el que ya
 * cree tener, sale sin tocar el hardware y responde «correcto». En este
 * portátil eso pasa constantemente, porque «quiet» y «balanced-performance» se
 * escriben por el camino privilegiado y PPD, que no los conoce, se queda
 * creyendo que sigue en el último que él puso.
 *
 * Reproducido en la máquina, con la extensión cargada en un gnome-shell 50.4:
 *
 *     platform_profile      = balanced-performance
 *     PPD ActiveProfile     = balanced
 *     Set(ActiveProfile, "balanced")  -> responde bien (rc=0)
 *     platform_profile      = balanced-performance   <-- NO HA CAMBIADO NADA
 *
 * Es decir: pulsar «Equilibrado» no hacía absolutamente nada y no salía ni un
 * error. La salida es pasar antes por otro perfil, para que el siguiente Set
 * sea un cambio de verdad. Cuesta dos llamadas D-Bus más y ninguna contraseña.
 *
 * @param {string} ppd nombre del perfil en PPD
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<void>} promesa que falla si PPD rechaza el cambio
 */
async function ponerPerfilPpd(ppd, cancelable) {
    let actual = null;
    try {
        actual = await leerPropiedadPpd('ActiveProfile', cancelable);
    } catch (e) {
        if (esCancelacion(e))
            throw e;
        // Si no se puede leer, se intenta el Set igual: en el peor caso no
        // hace nada y el que llama lo detecta al releer sysfs.
    }

    if (actual === ppd) {
        const paso = await otroPerfilPpd(ppd, cancelable);
        if (paso !== null)
            await asignarPerfilPpd(paso, cancelable);
    }

    await asignarPerfilPpd(ppd, cancelable);
}

// ---------------------------------------------------------------------------
// Helper privilegiado por pkexec
//
// ¿ES ACEPTABLE HACER ESTO DESDE UNA EXTENSIÓN? Sí, y es la única forma
// bendecida. Las normas de revisión de extensions.gnome.org lo dicen tal cual:
// «Spawning privileged subprocesses should be avoided at all costs. If
// absolutely necessary, the subprocess MUST be run with pkexec and MUST NOT be
// an executable or script that can be modified by a user process.» El helper
// vive en /usr/lib/nitro-gekko/, es root:root 0755 y lo pone el instalador del
// sistema, no la extensión; la extensión no trae ningún ejecutable.
//
// ¿BLOQUEA EL COMPOSITOR MIENTRAS SALE EL DIÁLOGO? No. Medido dentro de un
// gnome-shell 50.4 real: lanzar el proceso cuesta 7 ms, y con un hijo corriendo
// 3 segundos el shell contesta por D-Bus en 11-18 ms todo el rato. El diálogo
// de contraseña lo pinta el propio gnome-shell (el componente 'polkitAgent',
// que en GNOME 50 está activo en el modo 'user'), es un ModalDialog normal y
// corriente y lo mueve el mismo bucle principal. Nada espera a nada.
//
// DOS DETALLES QUE SÍ IMPORTAN:
//
//  1) Se cierra Configuración rápida ANTES de lanzar pkexec. El propio
//     gnome-shell avisa en polkitAgent.js de que el diálogo puede no llegar a
//     abrirse si otro actor tiene el grab: «One way to make this happen is by
//     running 'sleep 3; pkexec bash' and then opening a popup menu». En GNOME
//     50 pushModal() ya usa global.stage.grab() y devuelve grab siempre
//     (comprobado: con el menú abierto, pushModal sigue funcionando), pero
//     dejar el menú abierto debajo del diálogo es feo y no cuesta nada evitarlo.
//
//  2) Va con --disable-internal-agent. Sin esa bandera, pkexec se registra un
//     agente de TEXTO propio si no encuentra ninguno, y eso dentro de
//     gnome-shell sería un proceso hijo esperando una contraseña por una
//     entrada estándar que nadie va a rellenar. Con la bandera, si no hay
//     agente gráfico se falla limpio y se avisa.
// ---------------------------------------------------------------------------

/* Códigos de salida de pkexec, según pkexec(1) de esta máquina (polkit 127):
 * 126 = el usuario cerró el diálogo de autenticación.
 * 127 = no autorizado, o error al obtener la autorización.
 * Cualquier otro = el código con el que terminó el propio helper. */
const PKEXEC_DESCARTADO = 126;
const PKEXEC_NO_AUTORIZADO = 127;

/**
 * Busca el helper privilegiado. No lo instala ni lo crea: sólo mira si está.
 *
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<?string>} ruta del helper, o null si no está instalado
 */
async function buscarHelper(cancelable) {
    for (const ruta of RUTAS_HELPER) {
        if (await existe(ruta, cancelable))
            return ruta;
    }
    return null;
}

/**
 * Ejecuta el helper por pkexec sin bloquear el bucle principal del shell.
 *
 * @param {string} ruta ruta absoluta del helper
 * @param {string} accion nombre de acción del helper (aquí siempre «perfil»)
 * @param {string} valor valor a aplicar
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @param {function(Gio.Subprocess):void} alLanzar recibe el proceso recién
 *   lanzado, para poder matarlo si se desactiva la extensión a media faena
 * @returns {Promise<{estado: number, error: string}>} código y stderr del hijo
 */
function ejecutarHelper(ruta, accion, valor, cancelable, alLanzar) {
    return new Promise((resolver, rechazar) => {
        let proceso;
        try {
            proceso = Gio.Subprocess.new(
                ['pkexec', '--disable-internal-agent', ruta, accion, valor],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        } catch (e) {
            rechazar(e);
            return;
        }

        alLanzar(proceso);

        proceso.communicate_utf8_async(null, cancelable, (obj, res) => {
            try {
                const [, , salidaError] = obj.communicate_utf8_finish(res);
                resolver({
                    estado: obj.get_exit_status(),
                    error: (salidaError ?? '').trim(),
                });
            } catch (e) {
                rechazar(e);
            }
        });
    });
}

// ---------------------------------------------------------------------------
// Clasificación de errores
// ---------------------------------------------------------------------------

/**
 * ¿Este error es simplemente que hemos cancelado la operación al desactivar?
 *
 * @param {Error} error error capturado
 * @returns {boolean} true si es una cancelación y hay que ignorarlo
 */
function esCancelacion(error) {
    // OJO: NO vale «error instanceof Gio.IOErrorEnum». En GJS eso es cierto
    // para CUALQUIER GError del dominio Gio, incluido «Permiso denegado», y
    // haría que el fallo de escritura se tragase en silencio justo cuando hay
    // que avisar. Comprobado en la máquina.
    return error?.matches?.(
        Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED) === true;
}

/**
 * ¿El fallo es por falta de permisos de escritura?
 *
 * @param {Error} error error capturado
 * @returns {boolean} true si es «Permiso denegado»
 */
function esPermisoDenegado(error) {
    return error?.matches?.(
        Gio.IOErrorEnum, Gio.IOErrorEnum.PERMISSION_DENIED) === true;
}

// ---------------------------------------------------------------------------
// Filas informativas del menú
// ---------------------------------------------------------------------------

/**
 * Fila no interactiva con un icono y un texto. Se usa para las RPM y para el
 * aviso del bug de power-profiles-daemon.
 */
const FilaInformativa = GObject.registerClass(
class FilaInformativa extends PopupMenu.PopupBaseMenuItem {
    _init(icono, texto) {
        super._init({reactive: false, can_focus: false, activate: false});

        this.add_style_class_name('nitro-gekko-fila-informativa');

        this._icono = new St.Icon({
            icon_name: icono,
            style_class: 'popup-menu-icon',
        });
        this.add_child(this._icono);

        this._etiqueta = new St.Label({
            text: texto,
            y_align: Clutter.ActorAlign.CENTER,
            x_expand: true,
        });
        this._etiqueta.clutter_text.line_wrap = true;
        this.add_child(this._etiqueta);
        this.label_actor = this._etiqueta;
    }

    /**
     * Cambia el texto de la fila.
     *
     * @param {string} texto nuevo texto
     */
    set texto(texto) {
        this._etiqueta.text = texto;
    }

    /**
     * Texto actual de la fila.
     *
     * @returns {string} texto que se está mostrando
     */
    get texto() {
        return this._etiqueta.text;
    }
});

// ---------------------------------------------------------------------------
// El toggle
// ---------------------------------------------------------------------------

const ToggleNitroGekko = GObject.registerClass(
class ToggleNitroGekko extends QuickMenuToggle {
    _init() {
        super._init({
            title: 'Perfil térmico',
            menuButtonAccessibleName: 'Abrir el menú de perfiles de Nitro Gekko',
            // Arranca oculto: sólo se muestra si el sysfs de perfiles existe.
            visible: false,
        });

        this._cancelable = new Gio.Cancellable();
        this._elementosPerfil = new Map();
        this._perfilActivo = null;
        // Ambos se recalculan con la lista real de 'choices' en cuanto se lee;
        // esto es sólo el valor de arranque por si el menú se pinta antes.
        this._perfilNeutro = PERFIL_NEUTRO_PREFERIDO;
        this._ultimoPerfilRapido = PERFIL_NEUTRO_PREFERIDO;
        this._rutaHwmon = null;
        this._idTemporizadorRpm = 0;
        // Temporizadores de una sola vez de _esperar(). No son temporizadores
        // de fondo: viven milisegundos, dentro de una lectura o un cambio.
        this._idsEspera = new Map();
        // Contador de relecturas: sólo la última puede pintar el resultado.
        this._lectura = 0;
        this._vigilanteDePerfil = null;
        this._fuenteNotificaciones = null;
        this._idFuenteDestruida = 0;
        this._idAppSystem = 0;
        // Contador de peticiones: sólo la última puede tocar la interfaz. Sin
        // esto, dos clics seguidos dejan que la respuesta lenta de la primera
        // pise el resultado de la segunda.
        this._peticion = 0;
        // Proceso de pkexec en vuelo, si lo hay. Se guarda para poder matarlo
        // al desactivar la extensión y para no abrir dos diálogos a la vez.
        this._procesoHelper = null;

        // --- Menú -----------------------------------------------------------
        this.menu.setHeader('power-profile-balanced-symbolic', 'Perfil térmico');

        this._seccionPerfiles = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._seccionPerfiles);

        // Aviso del bug de PPD. Sólo visible cuando el perfil afectado
        // está activo; el perfil NO se oculta ni se bloquea.
        this._avisoPpd = new FilaInformativa(
            'dialog-warning-symbolic',
            'Este perfil deja el menú de energía de GNOME en blanco ' +
            '(fallo conocido de power-profiles-daemon). El portátil funciona ' +
            'con normalidad.');
        this._avisoPpd.visible = false;
        this.menu.addMenuItem(this._avisoPpd);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Fila de RPM. Se refresca SÓLO con el menú abierto.
        this._filaVentiladores = new FilaInformativa(
            'weather-windy-symbolic', 'Ventiladores: leyendo…');
        this.menu.addMenuItem(this._filaVentiladores);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._elementoAbrirApp = this.menu.addAction(
            'Abrir Nitro Gekko', () => this._abrirAplicacion());
        this._sincronizarBotonAplicacion();

        // --- Señales --------------------------------------------------------

        // Pulsar el cuerpo del toggle alterna entre el perfil neutro y el
        // último perfil "rápido" elegido, igual que hace el toggle de energía
        // de GNOME.
        this.connect('clicked', () => {
            const destino = this.checked
                ? this._perfilNeutro
                : this._ultimoPerfilRapido;
            this._lanzarCambioDePerfil(destino);
        });

        // El temporizador de RPM vive y muere con el menú. Con el menú cerrado
        // no queda NADA corriendo: ni temporizador, ni lecturas de sysfs.
        this.menu.connect('open-state-changed', (menu, abierto) => {
            if (abierto) {
                // Al abrir, refrescamos también el perfil por si ha cambiado
                // desde fuera y el vigilante de ficheros no se enteró.
                this._lanzarRelectura();
                this._sincronizarBotonAplicacion();
                this._arrancarRefrescoRpm();
            } else {
                this._pararRefrescoRpm();
            }
        });

        // Si la aplicación se instala o se desinstala mientras la sesión está
        // viva, el botón aparece o desaparece solo.
        this._idAppSystem = Shell.AppSystem.get_default().connect(
            'installed-changed', () => this._sincronizarBotonAplicacion());

        this.connect('destroy', () => this._alDestruir());

        // --- Arranque asíncrono ---------------------------------------------
        this._inicializar().catch(error => {
            if (!esCancelacion(error))
                console.error(`Nitro Gekko: fallo al inicializar: ${error.message}`);
        });
    }

    /**
     * Carga la lista de perfiles y el perfil activo, y monta el vigilante.
     *
     * @returns {Promise<void>} promesa del arranque
     */
    async _inicializar() {
        let crudo;
        try {
            crudo = await leerTexto(RUTA_PERFILES_DISPONIBLES, this._cancelable);
        } catch (error) {
            if (esCancelacion(error))
                return;
            // Sin sysfs de perfiles no hay nada que enseñar: el toggle se queda
            // oculto en lugar de mostrar un control muerto.
            console.warn('Nitro Gekko: no hay perfiles de plataforma ' +
                `(${RUTA_PERFILES_DISPONIBLES}); se oculta el toggle.`);
            return;
        }

        const perfiles = crudo.split(/\s+/).filter(p => p.length > 0);
        if (perfiles.length === 0)
            return;

        this._construirMenuPerfiles(perfiles);
        this.visible = true;

        // Vigilamos el fichero legacy, que es el que sí notifica los cambios.
        // Así el subtítulo se mantiene al día sin ningún temporizador.
        this._montarVigilanteDePerfil();

        await this._leerPerfilActivo();
    }

    /**
     * Crea un elemento de menú por cada perfil leído de 'choices'.
     *
     * @param {string[]} perfiles identificadores crudos del kernel
     */
    _construirMenuPerfiles(perfiles) {
        this._seccionPerfiles.removeAll();
        this._elementosPerfil.clear();

        // El perfil neutro y el «rápido» salen de la lista REAL del kernel, no
        // de una constante: si un día 'balanced' o 'performance' no existieran,
        // pulsar el cuerpo del toggle escribiría un valor inválido y el único
        // aviso sería una notificación de error. 'choices' viene ordenado de
        // menos a más potencia, así que el último es el más rápido.
        this._perfilNeutro = perfiles.includes(PERFIL_NEUTRO_PREFERIDO)
            ? PERFIL_NEUTRO_PREFERIDO
            : perfiles[Math.floor(perfiles.length / 2)];
        this._ultimoPerfilRapido = perfiles.at(-1);

        // Del más potente al más silencioso, como el menú de energía de GNOME.
        for (const perfil of [...perfiles].reverse()) {
            const {nombre, icono, rpmTipicas} = presentacionDe(perfil);

            const elemento = new PopupMenu.PopupImageMenuItem(nombre, icono);
            elemento.label.x_expand = true;

            /* PopupImageMenuItem coloca el ornamento (la marca de perfil
             * activo) como ÚLTIMO hijo a propósito, para que la marca quede
             * pegada al borde derecho de la fila. Si añadiéramos lo nuestro con
             * add_child() iría DESPUÉS del ornamento y la marca acabaría en
             * mitad de la fila, entre el nombre y las RPM. Verificado dentro de
             * gnome-shell: el orden salía
             *   [icono] [Equilibrado] [✓] [~2200 rpm]
             * Insertando por encima de la etiqueta el ornamento se queda donde
             * tiene que estar:
             *   [icono] [Equilibrado] [~2200 rpm] [✓]
             */
            let ultimoAnadido = elemento.label;
            const anadirTrasLaEtiqueta = actor => {
                elemento.insert_child_above(actor, ultimoAnadido);
                ultimoAnadido = actor;
            };

            // Referencia de ruido medida en esta máquina, como ayuda para
            // elegir sin tener que abrir la aplicación.
            if (rpmTipicas !== null) {
                const referencia = new St.Label({
                    text: `~${rpmTipicas} rpm`,
                    style_class: 'nitro-gekko-rpm-referencia',
                    y_align: Clutter.ActorAlign.CENTER,
                    // Atenuado desde aquí, no desde el CSS: St ignora la
                    // propiedad 'opacity' de las hojas de estilo (ver la
                    // constante OPACIDAD_RPM_REFERENCIA).
                    opacity: OPACIDAD_RPM_REFERENCIA,
                });
                anadirTrasLaEtiqueta(referencia);
            }

            // El perfil que rompe el menú de energía de GNOME va marcado.
            if (perfil === PERFIL_CON_BUG_PPD) {
                const aviso = new St.Icon({
                    icon_name: 'dialog-warning-symbolic',
                    style_class: 'popup-menu-icon nitro-gekko-icono-aviso',
                });
                anadirTrasLaEtiqueta(aviso);
            }

            elemento.connect('activate', () => this._lanzarCambioDePerfil(perfil));
            this._elementosPerfil.set(perfil, elemento);
            this._seccionPerfiles.addMenuItem(elemento);
        }
    }

    /**
     * Vigila el fichero de perfil para enterarse de los cambios hechos desde
     * fuera (la aplicación, el menú de energía de GNOME, un script).
     *
     * Un GFileMonitor no consume nada mientras no pasa nada, al contrario que
     * un temporizador de 1 Hz permanente. Comprobado que funciona sobre sysfs:
     * al cambiar el perfil desde fuera llegan CHANGED y CHANGES_DONE_HINT, y el
     * subtítulo se pone al día con el menú cerrado.
     */
    _montarVigilanteDePerfil() {
        try {
            const fichero = Gio.File.new_for_path(RUTA_PERFIL);
            this._vigilanteDePerfil = fichero.monitor_file(
                Gio.FileMonitorFlags.NONE, this._cancelable);
            this._vigilanteDePerfil.connect(
                'changed', () => this._lanzarRelectura());
        } catch (error) {
            // Si el vigilante no se puede montar no es fatal: el perfil se
            // relee igualmente cada vez que se abre el menú.
            console.warn(`Nitro Gekko: sin vigilante de perfil (${error.message})`);
        }
    }

    /**
     * Arranca una relectura del perfil desde un manejador de señal.
     *
     * Existe por lo mismo que _lanzarCambioDePerfil(): las señales no pueden
     * quedarse con una promesa suelta. Aquí lo disparan dos, el
     * 'open-state-changed' del menú y el 'changed' del vigilante de ficheros,
     * y _leerPerfilActivo() puede rechazar por su parte final —la que pinta—,
     * que está fuera del try a propósito. Reproducido antes de existir esto,
     * dentro de un gnome-shell 50.4: haciendo fallar _sincronizar() y emitiendo
     * 'changed' en el vigilante, el journal soltaba «Gjs-WARNING: Unhandled
     * promise rejection».
     *
     * No se saca notificación: una relectura fallida no es una acción que el
     * usuario haya pedido, y el vigilante volverá a avisar. Con el aviso en el
     * journal basta.
     *
     * @returns {void} no devuelve nada a propósito: el que llama es una señal
     */
    _lanzarRelectura() {
        this._leerPerfilActivo().catch(error => {
            if (esCancelacion(error))
                return;
            console.error(`Nitro Gekko: fallo al releer el perfil: ${error}`);
        });
    }

    /**
     * Relee el perfil activo y actualiza la interfaz.
     *
     * PUEDE RECHAZAR: la parte que pinta (_sincronizar) se deja fuera del try
     * para que quien haya pedido un cambio se entere de que la interfaz no se
     * pudo actualizar. Por eso las señales pasan por _lanzarRelectura().
     *
     * @returns {Promise<void>} promesa de la lectura
     */
    async _leerPerfilActivo() {
        // El vigilante de ficheros dispara dos veces por cambio (CHANGED y
        // CHANGES_DONE_HINT) y la lectura confirmada tarda unos ms, así que
        // dos relecturas se pueden solapar. Sólo la última pinta.
        const mia = ++this._lectura;

        let perfil;
        try {
            perfil = await this._leerPerfilFiable();
        } catch (error) {
            if (!esCancelacion(error))
                console.warn(`Nitro Gekko: no se pudo leer el perfil: ${error.message}`);
            return;
        }

        if (mia !== this._lectura)
            return;

        if (perfil === null) {
            // Ni una lectura buena: se deja lo que hubiera en pantalla, que es
            // más honesto que borrarlo. El vigilante volverá a avisar.
            console.warn('Nitro Gekko: platform_profile no se dejó leer.');
            return;
        }

        this._perfilActivo = perfil;
        this._sincronizar();
    }

    /**
     * Vuelca el perfil activo en el icono, el subtítulo, la marca del menú y
     * el aviso del bug de PPD.
     */
    _sincronizar() {
        const perfil = this._perfilActivo;
        const {nombre, icono} = presentacionDe(perfil ?? this._perfilNeutro);

        // Icono coherente con el perfil, tanto en el toggle como en la
        // cabecera del menú.
        this.set({subtitle: nombre, iconName: icono});
        this.menu.setHeader(icono, 'Perfil térmico', nombre);

        // El toggle se ve "encendido" cuando NO estamos en el perfil neutro.
        this.checked = perfil !== null && perfil !== this._perfilNeutro;
        if (this.checked)
            this._ultimoPerfilRapido = perfil;

        for (const [id, elemento] of this._elementosPerfil) {
            elemento.setOrnament(id === perfil
                ? PopupMenu.Ornament.CHECK
                : PopupMenu.Ornament.NONE);
        }

        this._avisoPpd.visible = perfil === PERFIL_CON_BUG_PPD;
    }

    // -- Cambio de perfil ----------------------------------------------------

    /**
     * Arranca un cambio de perfil desde un manejador de señal.
     *
     * Existe para que ninguna señal se quede con una promesa suelta: un rechazo
     * sin capturar sale en el journal como «JS ERROR: Unhandled promise
     * rejection» y encima deja la interfaz mintiendo.
     *
     * @param {string} perfil identificador crudo del kernel
     */
    _lanzarCambioDePerfil(perfil) {
        this._aplicarPerfil(perfil).catch(error => {
            if (esCancelacion(error))
                return;
            console.error(`Nitro Gekko: fallo al aplicar «${perfil}»: ${error}`);
            this._notificar(
                'No se pudo cambiar el perfil térmico',
                `Fallo inesperado al aplicar «${presentacionDe(perfil).nombre}»: ` +
                `${error.message}`);
        });
    }

    /**
     * Aplica un perfil y deja la interfaz contando la verdad.
     *
     * @param {string} perfil identificador crudo del kernel
     * @returns {Promise<void>} promesa del cambio completo
     */
    async _aplicarPerfil(perfil) {
        const mia = ++this._peticion;

        // Respuesta inmediata en la interfaz; al terminar se relee el estado
        // real y se corrige si hizo falta.
        this._perfilActivo = perfil;
        this._sincronizar();

        let fallo = null;
        let reventon = null;
        try {
            fallo = await this._intentarCambio(perfil);
        } catch (error) {
            if (esCancelacion(error))
                return;
            // No se relanza todavía: primero hay que dejar la interfaz
            // diciendo la verdad, y sólo después contar lo que pasó. Si se
            // relanzara aquí, el toggle se quedaría enseñando el perfil que
            // pedimos y que no llegó a aplicarse.
            reventon = error;
        }

        // Si mientras tanto ha entrado otra petición, esta ya no manda.
        if (mia !== this._peticion)
            return;

        // Se relee SIEMPRE: la interfaz nunca se queda con lo que quisimos
        // hacer, sino con lo que de verdad pone en sysfs.
        await this._leerPerfilActivo();

        if (reventon !== null)
            throw reventon;

        if (fallo !== null)
            this._notificar(fallo.titulo, fallo.cuerpo);
    }

    /**
     * Escalera de intentos para poner un perfil, de lo gratis a lo que pide
     * contraseña. Cada peldaño se comprueba releyendo sysfs.
     *
     *   1. ¿Ya está puesto? (lectura confirmada) -> nada que hacer.
     *   2. power-profiles-daemon (D-Bus)  -> sin contraseña (los 3 que conoce).
     *   3. Escritura directa en sysfs     -> sin contraseña, sólo en modo udev.
     *   4. Helper por pkexec              -> una contraseña, cacheada después.
     *
     * @param {string} perfil identificador crudo del kernel
     * @returns {Promise<?{titulo: string, cuerpo: string}>} null si se aplicó,
     *   o el aviso que hay que enseñar si no se pudo
     */
    async _intentarCambio(perfil) {
        if (await this._perfilRealEs(perfil))
            return null;

        // -- 2) power-profiles-daemon ---------------------------------------
        const ppd = PERFIL_A_PPD.get(perfil);
        if (ppd !== undefined) {
            try {
                await ponerPerfilPpd(ppd, this._cancelable);
                if (await this._perfilRealEs(perfil))
                    return null;
                console.warn('Nitro Gekko: power-profiles-daemon aceptó ' +
                    `«${ppd}» pero platform_profile no cambió; se sigue por otra vía.`);
            } catch (error) {
                if (esCancelacion(error))
                    throw error;
                console.warn(`Nitro Gekko: power-profiles-daemon rechazó «${ppd}»: ${error.message}`);
            }
        }

        // -- 3) escritura directa (modo udev) -------------------------------
        let permisoDenegado = false;
        try {
            await escribirTexto(RUTA_PERFIL, `${perfil}\n`, this._cancelable);
            if (await this._perfilRealEs(perfil))
                return null;
        } catch (error) {
            if (esCancelacion(error))
                throw error;
            permisoDenegado = esPermisoDenegado(error);
            if (!permisoDenegado) {
                // El firmware ha rechazado el valor: eso no lo arregla pkexec.
                return {
                    titulo: 'No se pudo cambiar el perfil térmico',
                    cuerpo: `El sistema rechazó «${presentacionDe(perfil).nombre}»: ` +
                        error.message,
                };
            }
        }

        // -- 4) helper privilegiado por pkexec ------------------------------
        return this._cambiarConHelper(perfil, permisoDenegado);
    }

    /**
     * Lee el perfil de sysfs sin tocar la interfaz. Devuelve null si falla.
     *
     * @returns {Promise<?string>} perfil leído, o null si no se pudo leer
     */
    async _leerPerfilCrudo() {
        try {
            return await leerTexto(RUTA_PERFIL, this._cancelable);
        } catch (error) {
            if (esCancelacion(error))
                throw error;
            return null;
        }
    }

    /**
     * Lee el perfil de sysfs hasta que DOS lecturas seguidas digan lo mismo.
     *
     * Y no es paranoia: en este portátil UNA lectura suelta de
     * platform_profile MIENTE con toda tranquilidad, y a veces ni siquiera
     * llega a responder. El getter del perfil hace una llamada WMI de verdad y
     * linuwu_sense no la excluye mutuamente con las demás, así que si hay otra
     * operación WMI en vuelo la lectura se cruza con ella.
     *
     * Medido en la máquina, con el equipo quieto en «balanced» y otro proceso
     * leyendo /sys/devices/platform/acer-wmi/nitro_sense/{usb_charging,
     * backlight_timeout} —exactamente lo que hace la ventana de Nitro Gekko
     * mientras está abierta—, sobre 400 lecturas de platform_profile:
     *
     *     345 correctas
     *      31 fallidas       (EIO / «la operación no está soportada»)
     *      24 con OTRO VALOR («quiet» estando en «balanced»)
     *
     * Es decir, un 13,75 % de lecturas inservibles. Sin el equipo cargado el
     * ruido es mucho menor (1 de 1954 leyendo a 50 Hz durante 75 s), y el
     * journal del kernel lo clava en el mismo milisegundo que el EC:
     *
     *     01:52:47.061477 kernel: linuwu_sense: usb charging get status
     *     01:52:47.061    lectura de platform_profile -> "quiet"
     *     01:52:47.068    lectura de platform_profile -> "balanced"
     *
     * Consecuencias si nos creyéramos una lectura suelta: dar por fallido un
     * cambio que sí funcionó (y sacarle al usuario un diálogo de contraseña
     * para nada), dar por hecho un cambio que no se hizo, o enseñar
     * «Silencioso» en el toggle estando en «Equilibrado». Con dos lecturas de
     * acuerdo, la probabilidad de tragarse el fallo baja al cuadrado, y las
     * lecturas van separadas MS_ENTRE_LECTURAS para no caer en la misma
     * ventana de la llamada WMI ajena.
     *
     * Esto es un fallo del DRIVER, no de aquí. Se compensa, no se arregla.
     *
     * @returns {Promise<?string>} perfil confirmado, la última lectura si
     *   ninguna se repite, o null si no se pudo leer ni una vez
     */
    async _leerPerfilFiable() {
        let anterior = null;
        for (let intento = 0; intento < INTENTOS_LECTURA_PERFIL; intento++) {
            if (intento > 0)
                await this._esperar(MS_ENTRE_LECTURAS);

            const leido = await this._leerPerfilCrudo();
            if (leido !== null && leido === anterior)
                return leido;
            if (leido !== null)
                anterior = leido;
        }
        return anterior;
    }

    /**
     * ¿El perfil que hay puesto es este?
     *
     * @param {string} perfil identificador crudo del kernel
     * @returns {Promise<boolean>} true si coincide con la lectura confirmada
     */
    async _perfilRealEs(perfil) {
        return await this._leerPerfilFiable() === perfil;
    }

    /**
     * Espera asíncrona con los temporizadores apuntados, para poder quitarlos
     * si desactivan la extensión a media espera.
     *
     * Es un Map de id -> resolvedor, y no un solo id, porque puede haber DOS
     * esperas solapadas: la de un cambio de perfil en curso y la de una
     * relectura disparada por el vigilante de ficheros. Con un solo id, el
     * primero se perdería y su temporizador quedaría suelto.
     *
     * @param {number} ms milisegundos a esperar
     * @returns {Promise<void>} promesa que se cumple al pasar el tiempo
     */
    _esperar(ms) {
        return new Promise(resolver => {
            const id = GLib.timeout_add(
                GLib.PRIORITY_DEFAULT, ms, () => {
                    this._idsEspera.delete(id);
                    resolver();
                    return GLib.SOURCE_REMOVE;
                });
            // Se guarda el resolvedor, no sólo el id: al destruir hay que
            // desatascar la espera además de quitar el temporizador. Si sólo
            // se quitara el temporizador, la promesa no se cumpliría nunca y
            // la función que la espera se quedaría viva —con este objeto ya
            // destruido dentro— para siempre.
            this._idsEspera.set(id, resolver);
        });
    }

    /**
     * Último recurso: pedirle al helper del sistema que lo escriba como root.
     *
     * @param {string} perfil identificador crudo del kernel
     * @param {boolean} permisoDenegado si la escritura directa dio «Permiso
     *   denegado» (lo normal en modo polkit)
     * @returns {Promise<?{titulo: string, cuerpo: string}>} null si se aplicó
     */
    async _cambiarConHelper(perfil, permisoDenegado) {
        const nombre = presentacionDe(perfil).nombre;

        if (this._procesoHelper !== null) {
            return {
                titulo: 'Hay una autorización a medias',
                cuerpo: 'Termina o cancela el diálogo de contraseña que ya está ' +
                    'abierto antes de cambiar de perfil otra vez.',
            };
        }

        const helper = await buscarHelper(this._cancelable);
        if (helper === null) {
            return {
                titulo: 'Ese perfil necesita Nitro Gekko instalado',
                cuerpo: `«${nombre}» no lo conoce power-profiles-daemon, así que ` +
                    'hay que escribirlo en el sistema y esta sesión no tiene ' +
                    (permisoDenegado ? 'permiso' : 'forma de hacerlo') + '. ' +
                    'Falta el ayudante del sistema: instala Nitro Gekko con ' +
                    'packaging/install.sh y vuelve a intentarlo.',
            };
        }

        // El diálogo de contraseña lo pinta el propio gnome-shell. Se cierra
        // Configuración rápida antes para que no quede un menú abierto debajo.
        Main.panel.closeQuickSettings();

        let resultado;
        try {
            resultado = await ejecutarHelper(
                helper, 'perfil', perfil, this._cancelable,
                proceso => (this._procesoHelper = proceso));
        } catch (error) {
            if (esCancelacion(error))
                throw error;
            return {
                titulo: 'No se pudo pedir autorización',
                cuerpo: `No se ha podido ejecutar pkexec para aplicar «${nombre}»: ` +
                    `${error.message}`,
            };
        } finally {
            this._procesoHelper = null;
        }

        if (resultado.estado === 0) {
            if (await this._perfilRealEs(perfil))
                return null;
            return {
                titulo: 'El perfil no se quedó puesto',
                cuerpo: `El ayudante aplicó «${nombre}» sin error, pero el kernel ` +
                    'sigue informando de otro perfil. Mira el estado en la ' +
                    'ventana de Nitro Gekko.',
            };
        }

        // El usuario cerró el diálogo: eso no es un fallo, es una decisión.
        // No se le saca una notificación por cancelar; la interfaz vuelve sola
        // al perfil real porque _aplicarPerfil relee siempre al terminar.
        if (resultado.estado === PKEXEC_DESCARTADO)
            return null;

        if (resultado.estado === PKEXEC_NO_AUTORIZADO) {
            return {
                titulo: 'Autorización denegada',
                cuerpo: `No se ha autorizado el cambio a «${nombre}». Hace falta ` +
                    'la contraseña de un administrador (acción ' +
                    'org.thegekko.nitrogekko.aplicar).',
            };
        }

        // Cualquier otro código viene del propio helper, que ya escribe en
        // castellano y explica qué valor rechazó y por qué.
        return {
            titulo: `No se pudo aplicar «${nombre}»`,
            cuerpo: resultado.error !== ''
                ? resultado.error
                : `El ayudante del sistema terminó con el código ${resultado.estado}.`,
        };
    }

    // -- RPM de los ventiladores --------------------------------------------

    /**
     * Arranca el refresco periódico de RPM. Sólo se llama al ABRIR el menú.
     */
    _arrancarRefrescoRpm() {
        this._lanzarLecturaVentiladores();

        if (this._idTemporizadorRpm !== 0)
            return;

        this._idTemporizadorRpm = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT, INTERVALO_RPM_SEGUNDOS, () => {
                this._lanzarLecturaVentiladores();
                return GLib.SOURCE_CONTINUE;
            });
    }

    /**
     * Arranca una lectura de RPM desde un temporizador o desde la apertura del
     * menú, sin dejar la promesa suelta.
     *
     * _leerVentiladores() se protege con un try/catch, pero la asignación del
     * texto de la fila está DENTRO de ese catch: si el actor ya no vale, el
     * propio catch revienta y la promesa se rechaza sin nadie que la recoja.
     *
     * @returns {void} no devuelve nada a propósito: el que llama es una señal
     */
    _lanzarLecturaVentiladores() {
        this._leerVentiladores().catch(error => {
            if (esCancelacion(error))
                return;
            console.error(`Nitro Gekko: fallo al leer las RPM: ${error}`);
        });
    }

    /**
     * Para el refresco de RPM. Se llama al CERRAR el menú y al destruir, para
     * que jamás quede un temporizador vivo de fondo.
     */
    _pararRefrescoRpm() {
        if (this._idTemporizadorRpm !== 0) {
            GLib.source_remove(this._idTemporizadorRpm);
            this._idTemporizadorRpm = 0;
        }
    }

    /**
     * Lee fan1_input (CPU) y fan2_input (GPU) y los pinta en el menú.
     *
     * Medido en la máquina: 1,4-2,3 ms por pasada, así que a 0,5 Hz no se nota.
     *
     * @returns {Promise<void>} promesa de la lectura
     */
    async _leerVentiladores() {
        try {
            if (this._rutaHwmon === null)
                this._rutaHwmon = await resolverHwmonAcer(this._cancelable);

            if (this._rutaHwmon === null) {
                this._filaVentiladores.texto = 'Ventiladores: no disponibles';
                return;
            }

            const [cpu, gpu] = await Promise.all([
                leerTexto(`${this._rutaHwmon}/fan1_input`, this._cancelable),
                leerTexto(`${this._rutaHwmon}/fan2_input`, this._cancelable),
            ]);

            this._filaVentiladores.texto =
                `Ventiladores · CPU ${cpu} rpm · GPU ${gpu} rpm`;
        } catch (error) {
            if (esCancelacion(error))
                return;

            // El número de hwmon puede haber cambiado: se fuerza a resolverlo
            // otra vez en la siguiente pasada.
            this._rutaHwmon = null;
            this._filaVentiladores.texto = 'Ventiladores: no disponibles';
        }
    }

    // -- Aplicación completa -------------------------------------------------

    /**
     * Muestra el botón «Abrir Nitro Gekko» sólo si el .desktop existe.
     */
    _sincronizarBotonAplicacion() {
        const aplicacion =
            Shell.AppSystem.get_default().lookup_app(ID_APLICACION);
        this._elementoAbrirApp.visible = aplicacion !== null;
    }

    /**
     * Lanza la aplicación completa y cierra Configuración rápida.
     */
    _abrirAplicacion() {
        const aplicacion =
            Shell.AppSystem.get_default().lookup_app(ID_APLICACION);
        if (aplicacion === null) {
            this._sincronizarBotonAplicacion();
            return;
        }

        Main.overview.hide();
        Main.panel.closeQuickSettings();
        aplicacion.activate();
    }

    // -- Notificaciones ------------------------------------------------------

    /**
     * Enseña una notificación del sistema. No falla en silencio nunca.
     *
     * @param {string} titulo título de la notificación
     * @param {string} cuerpo texto explicativo
     */
    _notificar(titulo, cuerpo) {
        if (this._fuenteNotificaciones === null) {
            this._fuenteNotificaciones = new MessageTray.Source({
                title: 'Nitro Gekko',
                iconName: 'dialog-warning-symbolic',
            });
            // La fuente se autodestruye cuando se cierra su última
            // notificación, así que sólo hay que soltar la referencia.
            this._idFuenteDestruida = this._fuenteNotificaciones.connect(
                'destroy', () => {
                    this._fuenteNotificaciones = null;
                    this._idFuenteDestruida = 0;
                });
            Main.messageTray.add(this._fuenteNotificaciones);
        }

        const notificacion = new MessageTray.Notification({
            source: this._fuenteNotificaciones,
            title: titulo,
            body: cuerpo,
            iconName: 'dialog-warning-symbolic',
            urgency: MessageTray.Urgency.HIGH,
        });
        this._fuenteNotificaciones.addNotification(notificacion);
    }

    // -- Limpieza ------------------------------------------------------------

    /**
     * Suelta absolutamente todo: temporizador, vigilante, señales, procesos y
     * lecturas en vuelo. Una extensión que no limpia es una fuga en el
     * compositor.
     */
    _alDestruir() {
        this._pararRefrescoRpm();

        // El cancelable, ANTES de desatascar las esperas: así lo que estuviera
        // esperando se despierta, va a leer, se encuentra la operación
        // cancelada y se retira sin tocar nada de este objeto ya destruido.
        this._cancelable.cancel();

        for (const [id, resolver] of this._idsEspera) {
            GLib.source_remove(id);
            resolver();
        }
        this._idsEspera.clear();

        // Si nos desactivan con el diálogo de contraseña abierto, se mata el
        // pkexec: cancelar la lectura de sus tuberías no basta, el hijo seguiría
        // vivo y acabaría aplicando un perfil que ya nadie espera.
        if (this._procesoHelper !== null) {
            try {
                this._procesoHelper.force_exit();
            } catch (e) {
                // Ya había terminado; no hay nada que hacer.
            }
            this._procesoHelper = null;
        }

        if (this._vigilanteDePerfil !== null) {
            this._vigilanteDePerfil.cancel();
            this._vigilanteDePerfil = null;
        }

        if (this._idAppSystem) {
            Shell.AppSystem.get_default().disconnect(this._idAppSystem);
            this._idAppSystem = 0;
        }

        // No se destruye la fuente de notificaciones a propósito: su método
        // destroy(reason) reemite la señal 'destroy', declarada con un
        // parámetro TYPE_UINT, y llamarlo sin razón emitiría un «undefined»
        // donde se espera un entero. Además arrancaría de las manos del
        // usuario un aviso que quizá está leyendo. La bandeja ya la destruye
        // sola cuando se cierra su última notificación.
        if (this._fuenteNotificaciones !== null) {
            if (this._idFuenteDestruida) {
                this._fuenteNotificaciones.disconnect(this._idFuenteDestruida);
                this._idFuenteDestruida = 0;
            }
            this._fuenteNotificaciones = null;
        }

        this._elementosPerfil.clear();

        // QuickSettingsItem crea el menú pero NO lo destruye con el botón
        // (verificado en quickSettings.js de GNOME 50.4: no hay ni un solo
        // connect('destroy')). Su contenedor cuelga del overlay del panel, así
        // que si no lo destruimos a mano se queda ahí colgado cada vez que se
        // desactiva la extensión. PopupMenuBase.destroy() sí hace actor.destroy()
        // y, antes, close(), que devuelve el brillo del panel y suelta la
        // referencia que QuickSettingsMenu guarda en _activeMenu.
        this.menu.destroy();
    }
});

/**
 * Localiza el directorio hwmon del chip acer.
 *
 * El número de hwmon NO es estable entre arranques, así que jamás se codifica:
 * se resuelve por la ruta de la plataforma y, si eso falla, por nombre.
 *
 * @param {?Gio.Cancellable} cancelable cancelable para abortar al desactivar
 * @returns {Promise<?string>} ruta del directorio hwmon, o null si no aparece
 */
async function resolverHwmonAcer(cancelable) {
    // Plan A: /sys/devices/platform/acer-wmi/hwmon/hwmonN
    try {
        const hijos = await listarDirectorio(RUTA_HWMON_PLATAFORMA, cancelable);
        const hwmon = hijos.find(nombre => nombre.startsWith('hwmon'));
        if (hwmon)
            return `${RUTA_HWMON_PLATAFORMA}/${hwmon}`;
    } catch (e) {
        if (esCancelacion(e))
            throw e;
        // La plataforma puede no existir; se prueba el plan B.
    }

    // Plan B: buscar en /sys/class/hwmon el que se llame 'acer'.
    const hijos = await listarDirectorio(RUTA_HWMON_CLASE, cancelable);
    for (const nombre of hijos) {
        const directorio = `${RUTA_HWMON_CLASE}/${nombre}`;
        try {
            const etiqueta = await leerTexto(`${directorio}/name`, cancelable);
            if (etiqueta.includes('acer'))
                return directorio;
        } catch (e) {
            if (esCancelacion(e))
                throw e;
            // hwmon sin 'name' legible: no es el nuestro, se sigue buscando.
        }
    }

    return null;
}

// ---------------------------------------------------------------------------
// Indicador y extensión
// ---------------------------------------------------------------------------

const IndicadorNitroGekko = GObject.registerClass(
class IndicadorNitroGekko extends SystemIndicator {
    _init() {
        super._init();

        this._icono = this._addIndicator();

        this._toggle = new ToggleNitroGekko();

        // El icono de la barra superior sigue al del perfil activo...
        this._toggle.bind_property('icon-name',
            this._icono, 'icon-name',
            GObject.BindingFlags.SYNC_CREATE);
        // ...y sólo se ve cuando NO estamos en el perfil neutro, para no
        // añadir ruido permanente a la barra.
        this._toggle.bind_property('checked',
            this._icono, 'visible',
            GObject.BindingFlags.SYNC_CREATE);

        this.quickSettingsItems.push(this._toggle);
    }
});

export default class ExtensionNitroGekko extends Extension {
    enable() {
        this._indicador = new IndicadorNitroGekko();

        // addExternalIndicator es la API pública de GNOME 50 para meter cosas
        // en Configuración rápida: coloca el indicador y sus elementos en la
        // posición correcta respecto a los del propio Shell.
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicador);
    }

    disable() {
        // Si enable() se quedó a medias, no hay nada que soltar.
        if (!this._indicador)
            return;

        // destroy() de cada elemento dispara la limpieza del toggle.
        this._indicador.quickSettingsItems.forEach(elemento => elemento.destroy());
        this._indicador.destroy();
        this._indicador = null;
    }
}
