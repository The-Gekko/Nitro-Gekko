# Extensión de GNOME Shell — Nitro Gekko

Toggle de **Configuración rápida** para cambiar el perfil térmico del Acer Nitro
AN17-51 sin abrir la aplicación completa. Es el 90 % del uso diario.

- **UUID:** `nitro-gekko@thegekko.dev`
- **Destino:** GNOME Shell **50** (`shell-version: ["50"]`)
- **Ficheros:** `metadata.json`, `extension.js`, `stylesheet.css`

## Qué hace

- Muestra el **perfil activo como subtítulo** del toggle, con un **icono
  coherente** con ese perfil (ahorro / equilibrado / rendimiento).
- Despliega un menú con **los perfiles leídos de sysfs**, nunca codificados:
  salen de `/sys/class/platform-profile/platform-profile-0/choices`. Si el
  kernel expone un perfil que la extensión no conoce, se muestra igualmente con
  un nombre derivado.
- Escribe el perfil elegido en `/sys/firmware/acpi/platform_profile` (la ruta
  *legacy*, que es la que notifica el cambio a `power-profiles-daemon`).
- Enseña las **RPM de los ventiladores** (CPU y GPU) dentro del menú.
- Marca con un aviso el perfil `balanced-performance`.
- Botón **«Abrir Nitro Gekko»**, sólo si la aplicación está instalada.

## Decisiones que importan

**El temporizador sólo vive con el menú abierto.** Las RPM se refrescan cada 2 s,
pero únicamente entre `open-state-changed(true)` y `open-state-changed(false)`.
Con el menú cerrado no queda ni un temporizador ni una lectura de sysfs. Para
mantener el subtítulo al día sin temporizadores se usa un `GFileMonitor` sobre
el fichero de perfil, que no consume nada mientras no pasa nada.

**Todo el acceso a ficheros es asíncrono.** `load_contents_async` y
`replace_contents_bytes_async`, siempre. Una llamada síncrona dentro del proceso
de `gnome-shell` congela el compositor entero.

**Las banderas de escritura tienen que ser `Gio.FileCreateFlags.NONE`.** Con
`REPLACE_DESTINATION`, GLib intenta crear un fichero temporal en el mismo
directorio y renombrarlo encima; en sysfs el directorio no es escribible y la
escritura falla. Con `NONE`, GLib escribe en el sitio. Comprobado reproduciendo
el caso (fichero escribible dentro de un directorio `0555`).

**Ni un solo perfil codificado a fuego, tampoco el neutro.** La lista sale de
`choices`, pero además el perfil *neutro* (al que vuelve el toggle al pulsarlo
estando activo) y el perfil *rápido* por defecto se eligen de esa misma lista en
tiempo de ejecución: el neutro es `balanced` **si está**, y si no el del medio;
el rápido es el último, que es el más potente porque `choices` viene ordenado de
menos a más. Antes eran dos constantes: si el kernel dejara de exponer
`performance`, pulsar el cuerpo del toggle habría escrito un valor inválido.

**El ornamento tiene que quedarse el último hijo de la fila.**
`PopupImageMenuItem` mueve a propósito la marca de selección detrás de la
etiqueta para que quede pegada al borde derecho. Todo lo que se añada después
con `add_child()` va *detrás de la marca* y la empuja al centro de la fila
(verificado dentro de gnome-shell: salía `[icono] [Equilibrado] [✓] [~2200 rpm]`).
Las RPM de referencia y el triángulo de aviso se insertan con
`insert_child_above()` justo encima de la etiqueta, y la marca se queda donde
debe: `[icono] [Equilibrado] [~2200 rpm] [✓]`.

**Nada de `PRESENTACION_PERFILES[id]` a pelo.** La tabla de nombres se consulta
con `Object.hasOwn()`. Con el acceso directo, un perfil llamado `constructor`,
`toString` o `valueOf` devuelve el miembro heredado de `Object.prototype` —que no
tiene ni nombre ni icono— y la extensión revienta con
`Wrong type undefined; string expected` al asignarlos.

**El número de hwmon no es estable entre arranques**, así que nunca se codifica.
Se resuelve por la ruta de la plataforma `/sys/devices/platform/acer-wmi/hwmon/`
y, si eso falla, recorriendo `/sys/class/hwmon` en busca del que se llame `acer`.

**Fallo de escritura con elegancia.** Si no hay permiso (la regla de udev no está
instalada todavía), sale una notificación del sistema que dice explícitamente que
hay que instalar Nitro Gekko. Nunca falla en silencio.

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

Sin la regla de udev del paquete principal, el toggle se ve y lee bien, pero al
cambiar de perfil avisará de que falta instalar Nitro Gekko.

## Depuración

```
journalctl -f -o cat /usr/bin/gnome-shell
```
