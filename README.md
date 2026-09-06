<p align="center">
  <img src="data/logo.png" alt="Nitro Gekko" width="380">
</p>

<h1 align="center">Nitro Gekko</h1>

<p align="center">
  Panel de control del portátil <b>Acer Nitro AN17-51</b> para GNOME.<br>
  Perfil térmico, ventiladores, límite de potencia y salud de la batería, sin editar <code>/sys</code> a mano.
</p>

<p align="center">
  <img alt="Plataforma" src="https://img.shields.io/badge/plataforma-Arch%20Linux-1793D1?logo=archlinux&logoColor=white">
  <img alt="Escritorio" src="https://img.shields.io/badge/escritorio-GNOME%2050%20%2F%20Wayland-4A86CF?logo=gnome&logoColor=white">
  <img alt="Stack" src="https://img.shields.io/badge/GTK4-libadwaita-745FB5">
  <img alt="Lenguaje" src="https://img.shields.io/badge/Python-3.14-3776AB?logo=python&logoColor=white">
  <img alt="Licencia" src="https://img.shields.io/badge/licencia-GPL--3.0-blue">
</p>

<p align="center">
  <sub>Proyecto personal. Escrito y probado para <b>un modelo concreto</b>: Acer Nitro AN17-51 (Spacia_RTH, BIOS V1.11).</sub>
</p>

---

## Que es

Una aplicacion de escritorio y una extension de GNOME Shell que ponen en un
sitio comodo lo que en este portatil solo se puede tocar escribiendo a mano en
`/sys` con `sudo`:

- **Perfil termico** — los cinco perfiles reales del equipo
  (`low-power`, `quiet`, `balanced`, `balanced-performance`, `performance`),
  leidos del kernel, no codificados a fuego.
- **Ventiladores** — RPM del ventilador de CPU y del de GPU, en vivo,
  con las RPM tipicas de cada perfil medidas en este equipo como referencia.
- **Potencia** — limite de potencia sostenida de la CPU (PL1), estado del
  turbo, y un interruptor para **reaplicar el PL1 cuando cambias de perfil**
  (hace falta: el firmware reescribe el PL1 por MMIO en cada cambio).
- **Bateria** — limite de carga al 80 % y temperatura de la bateria.
- **Temperaturas** — paquete de CPU, frecuencia media y datos de la GPU.

La extension anade el cambio de perfil termico y las RPM a **Configuracion
rapida**, para no tener que abrir la aplicacion.

## Que resuelve

En un Nitro AN17-51 con Arch, de fabrica:

- Los perfiles termicos no aparecen hasta que cargas `acer_wmi` con
  `predator_v4=1`, y aun asi solo se cambian escribiendo en `/sys` como root.
- El PL1 se pierde cada vez que cambias de perfil, porque el firmware lo
  reescribe por MMIO. Sin reaplicarlo, ajustar la potencia no sirve de nada.
- El limite de carga al 80 % existe (modulo DKMS `acer-wmi-battery`) pero no
  tiene ninguna interfaz grafica.
- Las RPM de los ventiladores estan en un `hwmon` **cuyo numero cambia entre
  arranques**, asi que ni siquiera puedes dejarte un alias hecho.

Nitro Gekko junta todo eso y, de paso, deja los permisos puestos para que no
haga falta `sudo` cada vez.

---

## Requisitos

**Hardware.** Acer Nitro AN17-51. Puede que funcione en otros Nitro con el
mismo firmware; el instalador avisa si detecta otro equipo pero no se planta.

**Sistema.** Todo esto ya viene en una instalacion normal de Arch con GNOME:

| | Version probada |
|---|---|
| GNOME Shell | 50.4 (Wayland) |
| GTK4 | 4.22.4 |
| libadwaita | 1.9.3 |
| Python | 3.14.7 |
| python-gobject | 3.56.3 |
| systemd | 261 (para `udev` y `systemd-tmpfiles`) |

No hay dependencias fuera de eso. Nada que instalar con `pip`.

**Modulo del kernel.** `acer_wmi` cargado con `predator_v4=1`:

```bash
echo 'options acer_wmi predator_v4=1' | sudo tee /etc/modprobe.d/acer-wmi.conf
sudo modprobe -r acer_wmi && sudo modprobe acer_wmi
cat /sys/class/platform-profile/platform-profile-0/choices
# debe imprimir: low-power quiet balanced balanced-performance performance
```

Si no lo haces, el instalador te lo dice paso a paso y sigue adelante.

**Opcional.** El modulo DKMS `acer-wmi-battery` (paquete AUR
`acer-wmi-battery-dkms`). Sin el todo funciona menos el limite de carga al 80 %.

**Tu usuario debe estar en el grupo `wheel`.** Es donde el instalador deja los
permisos de escritura.

---

## Instalacion

```bash
git clone <repo> "Nitro Gekko" && cd "Nitro Gekko"

# 1. Mira antes que va a hacer, sin tocar nada:
DESTDIR=/tmp/prueba ./packaging/install.sh
find /tmp/prueba

# 2. Lee esto. Es corto y explica la unica decision discutible del proyecto:
less packaging/SEGURIDAD.md

# 3. Instala de verdad:
sudo ./packaging/install.sh
```

Despues, activa la extension y **cierra y abre sesion** (en Wayland no vale
`Alt+F2 r`):

```bash
gnome-extensions enable nitro-gekko@thegekko.dev
```

Lanza la aplicacion con `nitro-gekko` o desde el menu.

### Que instala

```
/usr/lib/udev/rules.d/99-nitro-gekko.rules      permisos (eventos)
/usr/lib/tmpfiles.d/nitro-gekko.conf            permisos (arranque)
/usr/lib/nitro-gekko/gekkonitro/                la aplicacion
/usr/bin/nitro-gekko                            lanzador
/usr/share/applications/…desktop                entrada de menu
/usr/share/icons/hicolor/…                      icono
~/.local/share/gnome-shell/extensions/<uuid>/   extension
```

Los dos primeros dan **escritura al grupo `wheel` sobre seis ficheros de
`/sys`** y nada mas. No abren ninguna lectura nueva.
Que son, que puede hacer un proceso con ellos, por que **no** se abre
`energy_uj`, y cual seria la alternativa mas segura: todo esta en
[`packaging/SEGURIDAD.md`](packaging/SEGURIDAD.md).

Para probar sin instalar nada, el repositorio trae su propio lanzador:

```bash
./nitro-gekko
```

(Funciona en modo lectura; para escribir hacen falta los permisos, o `sudo`.)

## Desinstalacion

```bash
sudo ./packaging/install.sh --uninstall
```

Borra todo lo de la lista **y ademas devuelve los seis ficheros de `/sys` a
`0644 root:root`** en el momento, sin esperar a un reinicio.

---

## Cosas raras de este portatil que conviene saber

Estan documentadas dentro del codigo, pero por si te pican:

- **Escribir `balanced-performance` deja el menu de energia de GNOME en blanco.**
  Es un fallo de `power-profiles-daemon` 0.30: su tabla interna compara con
  `balanced_performance`, con guion bajo, y al no encontrarlo cae en
  `g_return_val_if_reached()` y deja `ActiveProfile` en `UNSET`. La aplicacion
  **avisa con un icono** en ese perfil concreto en vez de esconderlo.
- **El PL1 se reescribe solo al cambiar de perfil** (`performance` → 100 W,
  `balanced` → 70 W, por MMIO). El que manda es el MSR. De ahi el interruptor
  «Reaplicar PL1 al cambiar de perfil».
- **El numero de `hwmon` cambia entre arranques.** La aplicacion resuelve el
  ventilador buscando por nombre (`acer`), nunca por numero.
- **No hay vatios de CPU.** `energy_uj` esta cerrado por la mitigacion de
  PLATYPUS (CVE-2020-8694) y no se va a abrir. Ver `packaging/SEGURIDAD.md`.
- **La temperatura de la bateria se divide entre 1000 y ya esta.** El valor
  bruto `33000` son 33,0 °C. La formula `(v-2731)*100` que aparece en el driver
  es su conversion interna y aqui daria un disparate.

## Teclado RGB de 4 zonas

El AN17-51 lleva teclado **RGB de 4 zonas** (ficha oficial de Acer:
*"Backlit keyboard: Yes (4 zones RGB)"*). En Linux se veia siempre naranja
porque **`acer-wmi` de mainline no tiene una sola linea de codigo RGB**: el
naranja es el estado por defecto que deja el EC cuando nada le manda otra cosa.

Nitro Gekko lo resuelve con `linuwu-sense` parcheado (ver `rgb/`), instalado por
DKMS para que sobreviva a las actualizaciones de kernel:

```bash
sudo ./packaging/instalar-rgb.sh
```

El parche son dos cosas:

1. `quirk_acer_nitro_an17_51` con `.nitro_v4=1, .four_zone_kb=1` y su entrada
   DMI. El AN17-51 no esta en la tabla del upstream, y sin la entrada el grupo
   `four_zoned_kb` no llega a crearse. Forzar el parametro `nitro_v4=1` **no
   basta**: ese camino selecciona un quirk con `.four_zone_kb = 0` explicito.
2. Tres `strncpy()` a `memcpy()`. En kernel 7.2 `strncpy` ya no esta declarado
   y el upstream no compila.

> `linuwu_sense` **sustituye** a `acer_wmi` (reclaman los mismos GUID de WMI).
> Se verifico con datos que no se pierde nada: `platform_profile` con los cinco
> perfiles y el hwmon con los dos tacometros siguen ahi. `instalar-rgb.sh
> --revertir` deshace el cambio.

### Lo que puedes hacer

| | |
|---|---|
| **11 estilos listos** | Arcoiris, Gekko, Hielo, Magma, Onda cian, Respiracion, Meteorito, Destellos, Neon, Blanco fijo, Apagado |
| **8 efectos del firmware** | Fijo · Respiracion · Neon · Onda · Desplazamiento · Zoom · Meteorito · Destellos, con velocidad (0-9), brillo (0-100), direccion y color |
| **Color por zona** | Un color independiente para cada una de las cuatro zonas, con selector de color |
| **Apagado automatico** | El interruptor que traia NitroSense: teclado siempre encendido, o que se apague solo tras ~30 s sin teclear |
| **Carga USB apagado** | Umbral de bateria (0 / 10 / 20 / 30 %) por debajo del cual deja de cargar por USB con el portatil apagado |
| **Sonido de arranque** | Silenciar el sonido de encendido |

Los modos **Onda** y **Desplazamiento** exigen direccion 1 o 2; con 0 el driver
devuelve `-EINVAL`. La aplicacion lo corrige sola.

## El boton con el logo de la marca

El boton que en Windows abre NitroSense emite `KEY_PRESENTATION`
(evdev 425, scancode `0xf5`) desde el teclado i8042 — no desde el dispositivo de
hotkeys WMI, que es donde todo el mundo lo busca. En GNOME el atajo se llama
`XF86Presentation`, y `preparar-sistema.sh` lo asigna a `nitro-gekko`.

Si tu unidad emite otra tecla, averigualo con:

```bash
python3 packaging/capturar-tecla.py
```

