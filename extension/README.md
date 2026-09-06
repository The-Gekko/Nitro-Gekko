# Extensión de GNOME Shell — Nitro Gekko

Toggle de **Configuración rápida** para cambiar el perfil térmico del Acer Nitro
AN17-51 sin abrir la aplicación completa. Es el 90 % del uso diario.

- **UUID:** `nitro-gekko@thegekko.dev`
- **Destino:** GNOME Shell **50** (`shell-version: ["50"]`)
- **Ficheros:** `metadata.json`, `extension.js`, `stylesheet.css`, `README.md`

## Qué hace

- Muestra el **perfil activo como subtítulo** del toggle, con un **icono
  coherente** con ese perfil (ahorro / equilibrado / rendimiento).
- Despliega un menú con **los perfiles leídos de sysfs**, nunca codificados:
  salen de `/sys/class/platform-profile/platform-profile-0/choices`. Si el
  kernel expone un perfil que la extensión no conoce, se muestra igualmente con
  un nombre derivado.
- Cambia el perfil por la vía más barata que funcione, ver la escalera de abajo.
- Enseña las **RPM de los ventiladores** (CPU y GPU) dentro del menú.
- Marca con un aviso el perfil `balanced-performance`.
- Botón **«Abrir Nitro Gekko»**, sólo si la aplicación está instalada.

## La escalera para cambiar de perfil

Los cinco perfiles se pueden aplicar desde aquí. Se prueban por orden, de lo
gratis a lo que pide contraseña, y **cada peldaño se comprueba releyendo
sysfs**: nada se da por bueno porque una llamada haya respondido «correcto».

| # | Vía | Contraseña | Cuándo sirve |
|---|---|---|---|
| 1 | ¿ya está puesto? | — | se pulsa el perfil activo |
| 2 | D-Bus a `power-profiles-daemon` | **no** | `low-power`, `balanced`, `performance` |
| 3 | escritura directa en sysfs | **no** | sólo si se instaló con `--con-udev` |
| 4 | `pkexec` + helper del sistema | **sí, una vez** | `quiet` y `balanced-performance` en modo polkit |

`power-profiles-daemon` expone la acción polkit
`org.freedesktop.UPower.PowerProfiles.switch-profile` con **`implicit active:
yes`**: la sesión activa puede cambiar de perfil **sin contraseña**, y PPD
escribe el `platform_profile` por nosotros, como root. Pero PPD sólo conoce
tres perfiles, así que `quiet` y `balanced-performance` bajan al peldaño 4.

### Por qué el peldaño 4 es `pkexec` y no una notificación

Antes, `quiet` y `balanced-performance` sacaban una notificación que mandaba a
abrir la ventana de Nitro Gekko. Era un callejón sin salida evitable: la
aplicación hace exactamente lo mismo que hacemos ahora aquí.

Las normas de revisión de extensions.gnome.org lo permiten explícitamente:
*«Spawning privileged subprocesses should be avoided at all costs. If absolutely
necessary, the subprocess MUST be run with `pkexec` and MUST NOT be an
executable or script that can be modified by a user process.»* El helper vive en
`/usr/lib/nitro-gekko/nitro-gekko-helper`, es `root:root 0755` y lo pone el
instalador del sistema; la extensión no trae ningún ejecutable ni lo puede
modificar, y si el helper no está instalado, lo dice y no intenta nada.

**No bloquea el compositor.** Medido dentro de un `gnome-shell` 50.4 real:
lanzar el proceso con `Gio.Subprocess` cuesta **7 ms**, y con un hijo corriendo
3 segundos el shell sigue contestando por D-Bus en **11-18 ms**. El diálogo de
contraseña lo pinta el propio `gnome-shell` (componente `polkitAgent`, activo en
el modo `user` de GNOME 50); es un `ModalDialog` corriente que mueve el mismo
bucle principal.

Dos detalles que no se pueden quitar:

- **Se cierra Configuración rápida antes de lanzar `pkexec`.** El propio
  `polkitAgent.js` del Shell avisa de que el diálogo puede no llegar a abrirse
  si otro actor tiene el *grab*: *«One way to make this happen is by running
  'sleep 3; pkexec bash' and then opening a popup menu»*. En GNOME 50
  `pushModal()` ya usa `global.stage.grab()` y devuelve *grab* siempre
  (comprobado con el menú abierto), pero dejar el menú abierto debajo del
  diálogo es feo y evitarlo no cuesta nada.
- **Va con `--disable-internal-agent`.** Sin esa bandera, si `pkexec` no
  encuentra un agente de autenticación **se registra uno de texto propio**, y
  eso dentro de `gnome-shell` sería un hijo esperando una contraseña por una
  entrada estándar que nadie va a rellenar. Con la bandera se falla limpio.

Códigos de salida que se distinguen (`pkexec(1)`, polkit 127): **126** = el
usuario cerró el diálogo —eso no es un fallo, no se le saca ninguna
notificación—; **127** = no autorizado; cualquier otro viene del helper, que ya
explica en castellano qué valor rechazó.

## Dos fallos ajenos que esta extensión tiene que sortear

### 1. `power-profiles-daemon` responde «correcto» sin hacer nada

PPD guarda el perfil activo en una variable suya y, si le pides el que ya cree
tener, **sale sin tocar el hardware y responde bien**. En este portátil eso pasa
constantemente, porque `quiet` y `balanced-performance` se escriben por el
peldaño 4 y PPD, que no los conoce, se queda creyendo que sigue en el último que
él puso. Reproducido:

```
platform_profile   = balanced-performance
PPD ActiveProfile  = balanced
Set(ActiveProfile, "balanced")  -> rc=0
platform_profile   = balanced-performance    <-- NO HA CAMBIADO NADA
```

Es decir: pulsar «Equilibrado» **no hacía absolutamente nada, y sin un solo
error**. La salida es el *empujón*: si PPD ya cree estar en el perfil pedido, se
le pasa antes por otro (elegido de la lista que el propio PPD publica) para que
el siguiente `Set` sea un cambio de verdad. Dos llamadas D-Bus más y ninguna
contraseña.

### 2. Una lectura suelta de `platform_profile` puede mentir

El *getter* del perfil hace una llamada WMI real y `linuwu_sense` no la excluye
mutuamente con las demás. Si hay otra operación WMI en vuelo, la lectura se
cruza con ella. Medido con el equipo quieto en `balanced` y otro proceso leyendo
`/sys/devices/platform/acer-wmi/nitro_sense/{usb_charging,backlight_timeout}`
—exactamente lo que hace la ventana de Nitro Gekko mientras está abierta—, sobre
**400 lecturas** de `platform_profile`:

```
345 correctas
 31 fallidas       (EIO / «la operación no está soportada»)
 24 con OTRO VALOR («quiet» estando en «balanced»)
```

Un **13,75 %** de lecturas inservibles. Con el equipo en reposo el ruido es
mucho menor (1 de 1954 leyendo a 50 Hz durante 75 s) y el journal del kernel lo
clava en el mismo milisegundo que la actividad del EC:

```
01:52:47.061477 kernel: linuwu_sense: usb charging get status
01:52:47.061    lectura de platform_profile -> "quiet"
01:52:47.068    lectura de platform_profile -> "balanced"
```

Es un fallo del **driver**, no de aquí; se compensa, no se arregla. Toda lectura
que decida algo pasa por `_leerPerfilFiable()`, que insiste hasta que **dos
lecturas seguidas dicen lo mismo**, separadas 120 ms para no caer en la misma
ventana. Sin eso: se daría por fallido un cambio que sí funcionó —y se le
sacaría al usuario un diálogo de contraseña para nada—, o el toggle enseñaría
«Silencioso» estando en «Equilibrado». Con la lectura confirmada, 25 de 25
lecturas correctas bajo esa misma carga.

## Decisiones que importan

**El temporizador sólo vive con el menú abierto.** Las RPM se refrescan cada 2 s,
pero únicamente entre `open-state-changed(true)` y `open-state-changed(false)`.
Medido: 6 s con el menú cerrado, **0 lecturas y 0 temporizadores**; al cerrarlo,
la fuente desaparece del `GLib.MainContext`. Para mantener el subtítulo al día
sin temporizadores se usa un `GFileMonitor` sobre el fichero de perfil, que sí
funciona en sysfs (llegan `CHANGED` y `CHANGES_DONE_HINT`).

**Todo es asíncrono, ficheros y procesos.** `load_contents_async`,
`replace_contents_bytes_async`, `enumerate_children_async`,
`communicate_utf8_async`. Ni una llamada síncrona: una sola congela el
compositor entero.

**Las banderas de escritura tienen que ser `Gio.FileCreateFlags.NONE`.** Con
`REPLACE_DESTINATION`, GLib intenta crear un fichero temporal en el mismo
directorio y renombrarlo encima; en sysfs el directorio no es escribible y la
escritura falla. Con `NONE`, GLib escribe en el sitio.

**Ni un solo perfil codificado a fuego, tampoco el neutro.** La lista sale de
`choices`, pero además el perfil *neutro* (al que vuelve el toggle al pulsarlo
estando activo) y el perfil *rápido* por defecto se eligen de esa misma lista en
tiempo de ejecución: el neutro es `balanced` **si está**, y si no el del medio;
el rápido es el último, que es el más potente porque `choices` viene ordenado de
menos a más.

**El ornamento tiene que quedarse el último hijo de la fila.**
`PopupImageMenuItem` mueve a propósito la marca de selección detrás de la
etiqueta para que quede pegada al borde derecho. Todo lo que se añada después
con `add_child()` va *detrás de la marca* y la empuja al centro de la fila
(verificado: salía `[icono] [Equilibrado] [✓] [~2200 rpm]`). Las RPM de
referencia y el triángulo de aviso se insertan con `insert_child_above()` justo
encima de la etiqueta: `[icono] [Equilibrado] [~2200 rpm] [✓]`.

**Nada de `TABLA[id]` a pelo, ni para los nombres ni para el mapeo a PPD.** La
tabla de presentación se consulta con `Object.hasOwn()` y el mapeo a PPD es un
`Map`. Con el acceso directo a un objeto literal, un perfil llamado
`constructor`, `toString` o `valueOf` devuelve el miembro heredado de
`Object.prototype` y la extensión revienta con `Wrong type undefined; string
expected`.

**Ninguna señal se queda con una promesa suelta.** Las cinco que arrancan
trabajo asíncrono pasan por un envoltorio que hace `.catch()`:
`_lanzarCambioDePerfil()` para las dos que cambian de perfil (el cuerpo del
toggle y cada fila del menú), `_lanzarRelectura()` para el
`open-state-changed` del menú y el `changed` del vigilante de ficheros, y
`_lanzarLecturaVentiladores()` para el temporizador de RPM. Un rechazo sin
capturar sale en el journal como `Unhandled promise rejection` y encima deja la
interfaz mintiendo; comprobado que llegaba a pasar haciendo fallar
`_sincronizar()` y emitiendo `changed` en el vigilante.

**El número de hwmon no es estable entre arranques**, así que nunca se codifica.
Se resuelve por la ruta de la plataforma `/sys/devices/platform/acer-wmi/hwmon/`
y, si eso falla, recorriendo `/sys/class/hwmon` en busca del que se llame `acer`.

**`opacity` no existe en el CSS de St.** Lo que hay que atenuar se atenúa desde
`extension.js` poniendo la propiedad del actor. Ver el comentario de
`stylesheet.css`, que trae la comprobación.

> Cuidado con `error instanceof Gio.IOErrorEnum`: en GJS es cierto para
> **cualquier** `GError` del dominio Gio, «Permiso denegado» incluido. Usarlo
> para detectar cancelaciones se traga justo el error del que hay que avisar.
> Aquí se comprueba `error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED)`.

## El aviso de `balanced-performance`

Ese perfil deja **el menú de energía de GNOME en blanco**. No es culpa de la
extensión: `power-profiles-daemon` compara `balanced_performance` con guion bajo
en su tabla interna, cae en `g_return_val_if_reached()` y deja `ActiveProfile` en
`UNSET`.

El perfil **no se oculta ni se bloquea** —funciona perfectamente y el portátil va
bien—, pero aparece marcado con un triángulo de aviso en la lista y, mientras
está activo, con una explicación dentro del menú.

## Limpieza al desactivar

Comprobado desactivando la extensión **con el menú abierto y el temporizador
corriendo**: desaparece el elemento de la rejilla, el menú del *overlay* y el
icono de la barra; el temporizador ya no existe en el `GLib.MainContext`; el
`Gio.Cancellable` queda cancelado; `QuickSettingsMenu._activeMenu` se suelta y
el panel deja de estar atenuado; y un `pkexec` en vuelo se mata con
`force_exit()`. Después se puede volver a activar sin un solo error.

`QuickSettingsItem` crea el menú pero **no** lo destruye con el botón
(verificado en `quickSettings.js` de GNOME 50.4: no hay ni un `connect('destroy')`),
y su actor cuelga del *overlay* del panel. Por eso se llama a `this.menu.destroy()`
a mano.

## Si tu portátil no es un Acer Nitro AN17-51

Dos cosas que conviene saber antes de instalarla en otro equipo:

- **Si tu equipo no expone `/sys/firmware/acpi/platform_profile`, la extensión
  no aparece en Configuración rápida.** No es un fallo ni un error silencioso:
  sin esa ruta no hay perfiles que ofrecer, así que el indicador no se crea.
  Para que aparezca hace falta un driver de plataforma que la registre — en el
  AN17-51 lo hace `linuwu_sense`, y lo instala `packaging/instalar-rgb.sh`.
- **Las RPM que se ven junto a cada perfil (`~2200 rpm`) están medidas en un
  AN17-51 concreto**, no leídas de tu equipo. Son una referencia para saber de
  un vistazo cuál va a hacer ruido, y en otro modelo serán distintas. Las RPM
  del pie del menú, en cambio, sí son las de tus ventiladores en ese momento.

## Instalación

La instala el instalador del proyecto, **no a mano**. Copia esta carpeta a:

```
~/.local/share/gnome-shell/extensions/nitro-gekko@thegekko.dev/
```

El nombre de la carpeta **tiene que ser exactamente el UUID** de `metadata.json`.
En Wayland hay que **cerrar y volver a abrir la sesión** para que GNOME Shell vea
una extensión nueva (`Alt+F2` + `r` sólo funciona en X11). Después:

```
gnome-extensions enable nitro-gekko@thegekko.dev
```

La extensión funciona sola: lee los perfiles y las RPM sin necesitar nada del
paquete principal, y los tres perfiles que conoce `power-profiles-daemon` se
cambian sin contraseña. Para `quiet` y `balanced-performance` en modo polkit
necesita el helper del sistema (peldaño 4); si no está, lo dice.

## Depuración

```
journalctl -f -o cat /usr/bin/gnome-shell
```
