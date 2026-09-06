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
 *  - TODO el acceso a ficheros es asíncrono (load_contents_async /
 *    replace_contents_bytes_async). Una llamada síncrona en el proceso de
 *    gnome-shell congela el compositor entero.
 *  - El temporizador de RPM sólo vive mientras el menú está abierto. Con el
 *    menú cerrado no queda ni un solo temporizador corriendo.
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

/* Fichero .desktop de la aplicación completa. El botón para abrirla sólo
 * aparece si la aplicación está realmente instalada. */
const ID_APLICACION = 'org.thegekko.nitrogekko.desktop';

/* Cada cuánto se refrescan las RPM, SÓLO con el menú abierto. */
const INTERVALO_RPM_SEGUNDOS = 2;

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
// load_contents_async sin callback lanza TypeError). Y gnome-shell sólo
// promisifica delete_async, touch_async y query_info_async, no los que usamos.
// En vez de mutar Gio.File.prototype para todo el proceso de gnome-shell
// (efecto global, compartido con las demás extensiones), envolvemos los
// callbacks a mano. Cuesta cuatro líneas y no toca nada ajeno.
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

    enumerador.close_async(GLib.PRIORITY_DEFAULT, null, null);
    return nombres;
}

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
            // hwmon sin 'name' legible: no es el nuestro, se sigue buscando.
        }
    }

    return null;
}

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
    // que avisar de que falta instalar Nitro Gekko. Comprobado en la máquina.
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
        this._vigilanteDePerfil = null;
        this._fuenteNotificaciones = null;
        this._idFuenteDestruida = 0;

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
            this._aplicarPerfil(destino);
        });

        // El temporizador de RPM vive y muere con el menú. Con el menú cerrado
        // no queda NADA corriendo: ni temporizador, ni lecturas de sysfs.
        this.menu.connect('open-state-changed', (menu, abierto) => {
            if (abierto) {
                // Al abrir, refrescamos también el perfil por si ha cambiado
                // desde fuera y el vigilante de ficheros no se enteró.
                this._leerPerfilActivo();
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

            elemento.connect('activate', () => this._aplicarPerfil(perfil));
            this._elementosPerfil.set(perfil, elemento);
            this._seccionPerfiles.addMenuItem(elemento);
        }
    }

    /**
     * Vigila el fichero de perfil para enterarse de los cambios hechos desde
     * fuera (la aplicación, el menú de energía de GNOME, un script).
     *
     * Un GFileMonitor no consume nada mientras no pasa nada, al contrario que
     * un temporizador de 1 Hz permanente.
     */
    _montarVigilanteDePerfil() {
        try {
            const fichero = Gio.File.new_for_path(RUTA_PERFIL);
            this._vigilanteDePerfil = fichero.monitor_file(
                Gio.FileMonitorFlags.NONE, this._cancelable);
            this._vigilanteDePerfil.connect(
                'changed', () => this._leerPerfilActivo());
        } catch (error) {
            // Si el vigilante no se puede montar no es fatal: el perfil se
            // relee igualmente cada vez que se abre el menú.
            console.warn(`Nitro Gekko: sin vigilante de perfil (${error.message})`);
        }
    }

    /**
     * Relee el perfil activo y actualiza la interfaz.
     *
     * @returns {Promise<void>} promesa de la lectura
     */
    async _leerPerfilActivo() {
        try {
            const perfil = await leerTexto(RUTA_PERFIL, this._cancelable);
            this._perfilActivo = perfil;
            this._sincronizar();
        } catch (error) {
            if (!esCancelacion(error))
                console.warn(`Nitro Gekko: no se pudo leer el perfil: ${error.message}`);
        }
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

    /**
     * Escribe el perfil elegido en sysfs.
     *
     * @param {string} perfil identificador crudo del kernel
     * @returns {Promise<void>} promesa de la escritura
     */
    async _aplicarPerfil(perfil) {
        // Respuesta inmediata en la interfaz; si la escritura falla, el
        // vigilante o la relectura devuelven el estado real.
        this._perfilActivo = perfil;
        this._sincronizar();

        try {
            await escribirTexto(RUTA_PERFIL, `${perfil}\n`, this._cancelable);
        } catch (error) {
            if (esCancelacion(error))
                return;

            // Volvemos a leer para que la interfaz no mienta.
            this._leerPerfilActivo();

            if (esPermisoDenegado(error)) {
                this._notificar(
                    'Falta instalar Nitro Gekko',
                    'No hay permiso para escribir el perfil térmico. Instala ' +
                    'Nitro Gekko para añadir la regla de udev que da acceso ' +
                    `al grupo «wheel» sobre ${RUTA_PERFIL}.`);
            } else {
                this._notificar(
                    'No se pudo cambiar el perfil térmico',
                    `El sistema rechazó el cambio a «${presentacionDe(perfil).nombre}»: ` +
                    error.message);
            }
            return;
        }

        // Confirmamos leyendo: el firmware puede rechazar o remapear el valor.
        await this._leerPerfilActivo();
    }

    // -- RPM de los ventiladores --------------------------------------------

    /**
     * Arranca el refresco periódico de RPM. Sólo se llama al ABRIR el menú.
     */
    _arrancarRefrescoRpm() {
        this._leerVentiladores();

        if (this._idTemporizadorRpm !== 0)
            return;

        this._idTemporizadorRpm = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT, INTERVALO_RPM_SEGUNDOS, () => {
                this._leerVentiladores();
                return GLib.SOURCE_CONTINUE;
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
     * Suelta absolutamente todo: temporizador, vigilante, señales y lecturas
     * en vuelo. Una extensión que no limpia es una fuga en el compositor.
     */
    _alDestruir() {
        this._pararRefrescoRpm();

        this._cancelable.cancel();

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
        // desactiva la extensión. PopupMenuBase.destroy() sí hace actor.destroy().
        this.menu.destroy();
    }
});

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
