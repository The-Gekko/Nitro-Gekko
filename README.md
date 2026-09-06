<p align="center">
  <img src="data/logo.png" alt="Nitro Gekko" width="380">
</p>

<h1 align="center">Nitro Gekko</h1>

<p align="center">
  Panel de control del portátil <b>Acer Nitro AN17-51</b> para GNOME.<br>
  Perfil térmico, ventiladores, límite de potencia, salud de la batería y
  teclado RGB, sin editar <code>/sys</code> a mano.
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
`/sys` como root:

- **Perfil termico** — los cinco perfiles reales del equipo
  (`low-power`, `quiet`, `balanced`, `balanced-performance`, `performance`),
  leidos del kernel, no codificados a fuego.
- **Ventiladores** — RPM del ventilador de CPU y del de GPU, en vivo,
  con las RPM tipicas de cada perfil medidas en este equipo como referencia.
- **Potencia** — limite de potencia sostenida de la CPU (PL1), estado del
  turbo, y un interruptor para **reaplicar el PL1 cuando cambias de perfil**
  (hace falta: el firmware reescribe el PL1 por MMIO en cada cambio).
- **Bateria** — limite de carga al 80 % y temperatura de la bateria.
- **Teclado RGB de 4 zonas** — efectos del firmware, color por zona y los
  extras del EC (apagado automatico, carga USB, sonido de arranque).
- **Temperaturas** — paquete de CPU, frecuencia media y datos de la GPU.

La extension anade el cambio de perfil termico y las RPM a **Configuracion
rapida**, para no tener que abrir la aplicacion.

## Que resuelve

En un Nitro AN17-51 con Arch, de fabrica:

- Los perfiles termicos no aparecen hasta que cargas un driver de plataforma
  que conozca este modelo, y aun asi solo se cambian escribiendo en `/sys`
  como root.
- El PL1 se pierde cada vez que cambias de perfil, porque el firmware lo
  reescribe por MMIO. Sin reaplicarlo, ajustar la potencia no sirve de nada.
- El limite de carga al 80 % existe (modulo DKMS `acer-wmi-battery`) pero no
  tiene ninguna interfaz grafica.
- Las RPM de los ventiladores estan en un `hwmon` **cuyo numero cambia entre
  arranques**, asi que ni siquiera puedes dejarte un alias hecho.
- El teclado RGB se queda **siempre naranja**, porque el `acer-wmi` de
  mainline no tiene ni una linea de codigo RGB.

Nitro Gekko junta todo eso y pide la autorizacion **una sola vez** por el
dialogo de GNOME en vez de exigir `sudo` en cada cambio.

---

## Requisitos

**Hardware.** Acer Nitro AN17-51. Puede que funcione en otros Nitro con el
mismo firmware; el instalador avisa si detecta otro equipo pero no se planta.
Si el tuyo **no** es un AN17-51, lee [Si tu Acer es otro
modelo](#si-tu-acer-es-otro-modelo) antes de ejecutar nada.

**Sistema.** Esto ya viene en una instalacion normal de Arch con GNOME:

| | Version probada | ¿Requisito duro? |
|---|---|---|
| GNOME Shell | 50.4 (Wayland) | **si, para la extension** (ver aviso) |
| GTK4 | 4.22.4 | no, vale cualquier GTK 4 reciente |
| libadwaita | 1.9.3 | 1.5+ (`Adw.AboutDialog` es de 1.5; `Adw.SpinRow` y `Adw.ToolbarView`, de 1.4) |
| Python | 3.14.7 | 3.10+ (`@dataclass(slots=True)`) |
| python-gobject | 3.56.3 | no |
| polkit | para el dialogo de autorizacion (`pkexec`) | **si** en el modo por defecto |
| systemd | 261.2 (`rapl-pl1.service` fija el PL1 en cada arranque) | **si** |

La aplicacion no necesita nada mas: no se instala nada con `pip`.

**Para el teclado RGB hacen falta dos paquetes que Arch NO trae de serie.**
`instalar-rgb.sh` compila el modulo del kernel por DKMS, y eso no funciona sin
esto (comprobado: en este equipo los dos estan «instalados explicitamente», o
sea que los tuvo que poner el usuario, y nada mas del sistema depende de
`dkms`):

```bash
sudo pacman -S dkms linux-zen-headers   # linux-headers / linux-lts-headers
                                        # segun el kernel con el que ARRANQUES
```

`dkms` ya arrastra `gcc`, `make` y `patch`, asi que no hace falta `base-devel`.
Los headers tienen que ser los del kernel **en marcha**, no los de otro que
tengas instalado: `instalar-rgb.sh` lo comprueba y te dice cual falta.

> **La extension solo carga en GNOME Shell 50.** Su `metadata.json` declara
> `"shell-version": ["50"]` y GNOME **rechaza** una extension cuya version no
> este en esa lista: `gnome-extensions enable` la marca como *outdated* y no
> explica gran cosa. Con GNOME 48 o 49 **la aplicacion funciona igual** —es la
> que hace el trabajo—; lo unico que te pierdes es el atajo de Configuracion
> rapida. Si quieres intentarlo, anade tu version a ese array: la extension no
> usa ninguna API estrenada en 50, pero no esta probada en otra.

**Driver de plataforma.** Hacen falta `platform_profile` y el `hwmon` llamado
`acer`. Hay dos maneras de tenerlos, y **son excluyentes** (los dos drivers
reclaman los mismos GUID de WMI):

| | Perfiles + ventiladores | Teclado RGB | Como |
|---|---|---|---|
| **`linuwu_sense`** (recomendado) | si | **si** | `sudo ./packaging/instalar-rgb.sh` |
| `acer_wmi predator_v4=1` | si | no | `sudo ./packaging/preparar-sistema.sh` |

Lo que este proyecto usa e instala es **`linuwu_sense`**, porque es el unico
que da el RGB. Ver [Teclado RGB de 4 zonas](#teclado-rgb-de-4-zonas). El
instalador acepta cualquiera de los dos y no se planta con ninguno.

Para comprobar que hay driver, valga cual valga:

```bash
cat /sys/firmware/acpi/platform_profile_choices
# en el AN17-51: low-power quiet balanced balanced-performance performance
```

Lo que importa es que **el fichero exista y no salga vacio**, no que diga
exactamente eso: la aplicacion lee la lista del kernel y pinta los perfiles que
haya. Si tu equipo expone tres en vez de cinco, veras tres, no un error.

**Opcional.** El modulo DKMS `acer-wmi-battery`, que no viene con el kernel.
En el AUR hay dos paquetes: `acer-wmi-battery-dkms` y
`acer-wmi-battery-dkms-git`. Aqui esta probado con el **`-git`**. Sin este
modulo todo funciona menos el limite de carga al 80 %: esa fila aparece
**desactivada**, y su subtitulo trae el `yay -S` que hace falta para tenerla.

Si quieres ademas que el limite quede puesto ya al cargar el modulo, el propio
modulo trae un parametro para eso (por omision **no** toca lo que hubiera):

```bash
echo 'options acer_wmi_battery enable_health_mode=1' \
  | sudo tee /etc/modprobe.d/acer_wmi_battery.conf
```

**Tu usuario debe poder autenticarse como administrador ante polkit.** En Arch
eso significa estar en el grupo `wheel`. Es lo que hace que el dialogo de
contrasena te acepte.

---

## Si tu Acer es otro modelo

Esto se escribio y se midio en **un** portatil. Nada aqui te va a decir que lo
tuyo funciona si no lo he probado, asi que esto es lo que hace cada pieza
cuando el DMI no dice `Nitro AN17-51`.

**Lo que comprueba cada script, y si se planta o no:**

| Script | Si no eres un AN17-51 |
|---|---|
| `install.sh` | avisa y **sigue**. Solo copia ficheros; no toca hardware |
| `preparar-sistema.sh` | avisa y sigue si eres Acer; **aborta** si no lo eres |
| `instalar-rgb.sh` | avisa y sigue, pero **se deshace solo** si el driver nuevo no repone los perfiles ni los tacometros |
| `probar-rgb.sh` | no comprueba el modelo, pero **se planta** si ya tienes `linuwu_sense` cargado: es una prueba para ANTES de instalar. Restaura sola el driver que hubiera al empezar |

**El teclado RGB depende de que tu modelo este en la tabla DMI del driver.**
El fuente de `rgb/` reconoce el teclado de 4 zonas en siete equipos —extraidos
de la propia tabla del fichero, no de memoria:

```
Nitro AN17-51   Nitro AN16-43   Nitro AN16-42   Nitro AN515-58
Nitro AN16-41   Predator PHN16-71   Predator PHN16-72
```

De esos, el unico probado aqui es el AN17-51; los otros seis vienen del
proyecto original, [Linuwu-Sense](https://github.com/0x7375646F/Linuwu-Sense).
Si el tuyo no esta, `instalar-rgb.sh` te lo dira despues de instalar
(«four_zoned_kb AUSENTE»), y los perfiles y los ventiladores seguiran
funcionando; simplemente no habra RGB. La aplicacion **oculta entera** la
pestana «Teclado» en ese caso, en vez de enseñarla en gris.

**Lo que va a estar mal aunque todo cargue**, porque son medidas de este
equipo y no lecturas:

- Las **RPM de referencia** por perfil (la tabla de arriba). El ventilador de
  tu equipo no tiene por que girar a eso. Las RPM que la aplicacion muestra
  **en vivo** si son las tuyas: salen del `hwmon`.
- El **rango del deslizador del PL1, fijado a 10–65 W**. Los 65 son el valor
  de fabrica de *este* chip. Si tu CPU es mayor, el maximo se te queda corto y
  **la aplicacion no podra devolverte tu valor de fabrica**: tendrias que
  reiniciar o escribirlo a mano en
  `intel-rapl:0/constraint_0_power_limit_uw`. El minimo (10 W) es el que
  protege de verdad y ese vale para cualquier chip. Ver
  [`packaging/SEGURIDAD.md`](packaging/SEGURIDAD.md).
- El **boton del logo de la marca**. Aqui emite `KEY_PRESENTATION`; en tu
  equipo puede ser otra tecla. Averigualo con
  `sudo python3 packaging/capturar-tecla.py` y cambia el atajo a mano.

**Y lo que mas se nota en otro modelo: el paso 1 te puede BAJAR el techo de
potencia sostenida de la CPU.** `preparar-sistema.sh` instala
`rapl-pl1.service`, que en cada arranque (y despues de suspender) fija el PL1
a la **potencia base declarada por tu chip** (`constraint_0_max_power_uw`).
En el AN17-51 eso es bajar de 65 a 45 W y es justo lo que se busca: menos
ruido y 19 grados menos. En un Nitro con un procesador mayor esa cifra puede
quedar muy por debajo de lo que Acer sostiene de fabrica —simulado aqui con
una CPU que declara 55 W y un firmware que sostiene 100: el servicio la
dejaria en 55 en cada arranque—, y lo vas a notar en rendimiento sostenido.
No es un fallo del script (lee tu chip, no cablea 45), pero conviene decidirlo
tu:

```bash
./packaging/preparar-sistema.sh --revisar   # el paso 3 dice las dos cifras
                                            # ANTES de tocar nada
sudo ./packaging/preparar-sistema.sh --revertir   # quita el servicio
```

Ojo con el combo: el deslizador del PL1 de la aplicacion tampoco pasa de
65 W, asi que si tu firmware sostenia mas, no vas a poder devolverlo desde la
interfaz.

**Los controles cuyo `/sys` no exista salen DESACTIVADOS, no apagados.** Son
tres, y los tres pueden faltar en otro Acer:

| Control | Depende de | Si no esta |
|---|---|---|
| Turbo Boost | `intel_pstate/no_turbo` | fila en gris. Falta con CPU AMD y arrancando con `intel_pstate=disable` |
| PL1 y «Reaplicar PL1» | `/sys/class/powercap/intel-rapl:0` | fila en gris. Falta con CPU AMD; ahi el equivalente es RyzenAdj, que este proyecto no usa |
| Limitar carga al 80 % | `acer-wmi-battery` (AUR) | fila en gris, con el `yay -S` que hace falta escrito en el propio subtitulo |

La distincion importa: un interruptor **apagado** afirma que esa funcion existe
y esta desactivada, y en un equipo que no la tiene eso es mentira. Uno **en
gris** dice «aqui no hay tal cosa», y el subtitulo explica por que y que
instalar. Las lecturas que falten se pintan `s/d` o `—`, nunca como un cero.

**Como salir de todo, en orden inverso al de instalacion:**

```bash
sudo ./packaging/install.sh --uninstall
sudo ./packaging/instalar-rgb.sh --revertir
sudo ./packaging/preparar-sistema.sh --revertir
```

Queda **un** fichero que ninguna de las tres ordenes borra: `linuwu_sense`
guarda el ultimo estado del teclado en `/etc/four_zone_kb_state`, que escribe el
propio modulo al descargarse (es codigo del upstream, no de este repositorio).
Son 44 bytes binarios y no estorban a nada, pero si quieres dejarlo todo limpio:
`sudo rm -f /etc/four_zone_kb_state`.

---

## Instalacion

```bash
git clone https://github.com/The-Gekko/Nitro-Gekko.git
cd Nitro-Gekko

# 1. Prepara el HARDWARE (driver, PL1, atajo del boton de la marca).
#    Diagnostica primero, sin tocar nada:
./packaging/preparar-sistema.sh --revisar
sudo ./packaging/preparar-sistema.sh

# 2. Teclado RGB (instala linuwu_sense por DKMS y aparta acer_wmi):
sudo ./packaging/instalar-rgb.sh

# 3. Mira antes que va a instalar la aplicacion, sin tocar nada:
DESTDIR=/tmp/prueba ./packaging/install.sh
find /tmp/prueba

# 4. Instala de verdad:
sudo ./packaging/install.sh
```

El paso 1 detecta que driver de plataforma tienes y se adapta: si
`linuwu_sense` ya esta cargado **no toca `acer_wmi`**, porque el paso 2 lo deja
en la lista negra. Puedes ejecutar los dos pasos en este orden sin que se
pisen; si solo quieres el paso 2, tambien vale.

Despues, activa la extension y **cierra y abre sesion** (en Wayland no vale
`Alt+F2 r`):

```bash
gnome-extensions enable nitro-gekko@thegekko.dev
```

Lanza la aplicacion con `nitro-gekko`, desde el menu, o con el **boton del logo
de la marca** del teclado (`preparar-sistema.sh` lo deja asignado).

### Que instala

```
/usr/lib/nitro-gekko/nitro-gekko-helper           ayudante privilegiado
/usr/share/polkit-1/actions/…policy               politica de autorizacion
/usr/lib/nitro-gekko/gekkonitro/                  la aplicacion
/usr/bin/nitro-gekko                              lanzador
/usr/share/applications/…desktop                  entrada de menu
/usr/share/icons/hicolor/…                        iconos
~/.local/share/gnome-shell/extensions/<uuid>/     extension
```

### Como se piden los permisos (esto importa)

Por omision, Nitro Gekko funciona en **modo polkit**, y **no cambia los
permisos de ningun fichero de `/sys`**: siguen siendo `0644 root:root`.

Cuando hay que escribir algo, la aplicacion llama por `pkexec` a un ayudante
minusculo, `nitro-gekko-helper`, que corre como root. El helper **no acepta
rutas**: solo un nombre de accion de una lista cerrada (`perfil`, `pl1`,
`bateria`, `turbo`, `rgb_efecto`, `rgb_zonas`, `retro_timeout`, `usb_carga`,
`calibracion`, `sonido_arranque`) y un valor que valida contra el propio
kernel antes de escribirlo. La lista blanca de rutas vive dentro del helper.

Lo llama la aplicacion **y tambien la extension de GNOME Shell**: para los
dos perfiles que `power-profiles-daemon` no conoce (`quiet` y
`balanced-performance`) la extension lanza el mismo `pkexec` con el mismo
helper, de forma asincrona. Los otros tres los cambia sin contrasena por
D-Bus. Detalles y medidas en [`extension/README.md`](extension/README.md).

La accion polkit es `org.thegekko.nitrogekko.aplicar`, con `auth_admin_keep`:
GNOME pide la contrasena **una vez** y la recuerda unos minutos para la sesion
activa, para que mover el deslizador del PL1 no pregunte en cada paso.

Existe ademas un **modo opcional sin contrasena**:

```bash
sudo ./packaging/install.sh --con-udev
```

Ese modo instala una regla de `udev` y un `tmpfiles.d` que abren **seis rutas
de `/sys` al grupo `wheel`**. Es comodo y es peor: cualquier proceso que corra
con tu uid puede entonces escribir ahi en silencio.
Que se abre exactamente, que puede hacer un proceso con ello, y por que **no**
se abre `energy_uj`: [`packaging/SEGURIDAD.md`](packaging/SEGURIDAD.md).

Para probar sin instalar nada, el repositorio trae su propio lanzador:

```bash
./nitro-gekko
```

(Lee siempre; para escribir necesita el helper y la politica ya instalados,
que es lo que hace `install.sh`.)

## Desinstalacion

```bash
sudo ./packaging/install.sh --uninstall   # la aplicacion
sudo ./packaging/instalar-rgb.sh --revertir   # el driver del RGB
sudo ./packaging/preparar-sistema.sh --revertir   # lo que toco del sistema
```

Si habias instalado con `--con-udev`, la desinstalacion borra tambien la regla
y el `tmpfiles.d` **y devuelve las seis rutas de `/sys` a `0644 root:root`** en
el momento, sin esperar a un reinicio.

---

## Cosas raras de este portatil que conviene saber

Estan documentadas dentro del codigo, pero por si te pican:

- **Escribir `balanced-performance` deja el menu de energia de GNOME en blanco.**
  Es un fallo de `power-profiles-daemon` 0.30: su tabla interna compara con
  `balanced_performance`, con guion bajo, y al no encontrarlo cae en
  `g_return_val_if_reached()` y deja `ActiveProfile` en `UNSET`. La aplicacion
  **avisa con un icono** en ese perfil concreto en vez de esconderlo.
- **El firmware pone el PL1 muy por encima del TDP del chip.** El i7-13620H es
  de 45 W nominales y Acer lo deja en **65 W (MSR) / 70 W (MMIO)**. Medido en
  este equipo con carga sostenida a 16 hilos: con 65 W se queda en 63 W y
  85 °C; **con 45 W baja a 41,9 W y 66 °C**, sin throttling y con mucho menos
  ruido. `preparar-sistema.sh` instala `rapl-pl1.service`, que reaplica ese
  limite en cada arranque y despues de suspender. **El 45 no esta cableado**:
  el script lee la potencia base que declara tu propio chip en
  `intel-rapl:0/constraint_0_max_power_uw` y usa esa. Si tu CPU declara 55 W,
  el limite sera 55 W; si tu firmware ya respeta el nominal, el paso se salta;
  y si no hay RAPL de Intel (un Acer con CPU AMD), no instala nada.
- **El PL1 se reescribe solo al cambiar de perfil** (por MMIO: `balanced`
  → 70 W, `performance` → 100 W). El que manda es el MSR, y por eso el MMIO
  suele quedar descolgado. De ahi el interruptor «Reaplicar PL1 al cambiar de
  perfil».
- **El numero de `hwmon` cambia entre arranques.** La aplicacion resuelve el
  ventilador buscando por nombre (`acer`), nunca por numero.
- **No hay vatios de CPU.** `energy_uj` esta cerrado por la mitigacion de
  PLATYPUS (CVE-2020-8694) y no se va a abrir. Ver `packaging/SEGURIDAD.md`.
- **La temperatura de la bateria se divide entre 1000 y ya esta.** El valor
  bruto `33000` son 33,0 °C. La formula `(v-2731)*100` que aparece en el driver
  es su conversion interna y aqui daria un disparate.

### RPM tipicas medidas por perfil

Son las que la aplicacion y la extension muestran como referencia. Medidas en
este equipo, en reposo:

| Perfil | RPM |
|---|---|
| `low-power` | ~1663 |
| `quiet` | ~1661 |
| `balanced` | ~2200 |
| `balanced-performance` | ~2377 |
| `performance` | ~3237 |

Es decir: `performance` casi **duplica el ruido** de `quiet` para ganar
alrededor de 1 °C.

## Teclado RGB de 4 zonas

El AN17-51 lleva teclado **RGB de 4 zonas** (ficha oficial de Acer:
*"Backlit keyboard: Yes (4 zones RGB)"*). En Linux se veia siempre naranja
porque **`acer-wmi` de mainline no tiene una sola linea de codigo RGB**: el
naranja es el estado por defecto que deja el EC cuando nada le manda otra cosa.

Nitro Gekko lo resuelve con **[Linuwu-Sense](https://github.com/0x7375646F/Linuwu-Sense)
parcheado**, instalado por DKMS para que sobreviva a las actualizaciones de
kernel:

```bash
sudo ./packaging/instalar-rgb.sh
```

`rgb/src/linuwu_sense.c` **no es codigo nuestro**: es una copia **modificada**
del fuente de Linuwu-Sense (que a su vez deriva del `acer-wmi` del kernel
Linux). Se conservan intactos su cabecera de licencia, su `SPDX-License-Identifier`
y los avisos de copyright de sus autores originales; el aviso de modificacion,
como exige la GPL, esta al principio del propio fichero. Ver
[Licencia y creditos](#licencia-y-creditos).

El parche son dos cosas, y solo dos:

1. `quirk_acer_nitro_an17_51` con `.nitro_v4=1, .four_zone_kb=1` y su entrada
   DMI. El AN17-51 no esta en la tabla del upstream, y sin la entrada el grupo
   `four_zoned_kb` no llega a crearse. Forzar el parametro `nitro_v4=1` **no
   basta**: ese camino selecciona un quirk con `.four_zone_kb = 0` explicito.
2. Tres `strncpy()` a `memcpy()`. En kernel 7.2 `strncpy` ya no esta declarado
   y el upstream no compila.

> `linuwu_sense` **sustituye** a `acer_wmi` (reclaman los mismos GUID de WMI),
> asi que `instalar-rgb.sh` deja `acer_wmi` en la lista negra.
> Se verifico con datos que no se pierde nada: `platform_profile` con los cinco
> perfiles y el hwmon con los dos tacometros siguen ahi. `instalar-rgb.sh
> --revertir` deshace el cambio y devuelve `acer_wmi`.

### El riesgo real de este paso, dicho claro

Poner `acer_wmi` en la lista negra significa que **los perfiles termicos y los
tacometros pasan a depender de que el modulo DKMS compile**. DKMS lo recompila
en cada kernel nuevo, pero `linuwu_sense` usa API interna del kernel y una
actualizacion **puede** romper esa compilacion. Si eso ocurre arrancas sin
ninguno de los dos drivers: sin `platform_profile`, sin RPM y sin RGB. No se
rompe nada fisico y se arregla en dos ordenes, pero conviene saberlo antes y no
descubrirlo tres meses despues.

Se reconoce asi:

```bash
dkms status linuwu-sense       # no dice 'installed' para el kernel en marcha
lsmod | grep linuwu_sense      # no aparece
```

Y se recupera asi, sin necesitar el repositorio (perfiles y ventiladores
vuelven al instante; el RGB no, hasta recompilar):

```bash
sudo rm /etc/modprobe.d/nitro-gekko-rgb.conf /etc/modules-load.d/linuwu-sense.conf
echo 'options acer_wmi predator_v4=1' | sudo tee /etc/modprobe.d/acer-wmi.conf
sudo modprobe acer_wmi predator_v4=1
```

Estas mismas instrucciones van escritas **dentro** de
`/etc/modprobe.d/nitro-gekko-rgb.conf`, que es el fichero que uno acaba
encontrando cuando busca por que se ha quedado sin ventiladores.

Para probarlo en caliente, sin instalar ni persistir nada:

```bash
make -C rgb                               # compila contra el kernel en marcha
sudo ./packaging/probar-rgb.sh --dry-run  # enseña lo que haria
sudo ./packaging/probar-rgb.sh            # lo hace, y restaura al terminar
```

> **Ojo con los espacios en la ruta.** `kbuild` no admite espacios en el
> directorio que se le pasa por `M=`: parte la variable por espacios y falla
> con un `does not exist` que despista mucho. Si has clonado en una ruta con
> espacios, el `Makefile` te lo dice y aborta. Compila entonces por DKMS
> (`sudo ./packaging/instalar-rgb.sh`, que copia el fuente a `/usr/src`) o
> copia `rgb/` a una ruta limpia:
> `cp -a rgb /tmp/rgb && make -C /tmp/rgb` y luego
> `sudo KO=/tmp/rgb/src/linuwu_sense.ko ./packaging/probar-rgb.sh`.

### Lo que puedes hacer

| | |
|---|---|
| **11 estilos listos** | Arcoiris, Gekko, Hielo, Magma, Onda, Respiracion, Meteorito, Destellos, Neon, Blanco fijo, Apagado |
| **8 efectos del firmware** | Fijo · Respiracion · Neon · Onda · Desplazamiento · Zoom · Meteorito · Destellos, con velocidad (0-9), brillo (0-100), direccion (0-2) y color |
| **Color por zona** | Un color independiente para cada una de las cuatro zonas, con selector de color |
| **Apagado automatico** | El interruptor que traia NitroSense: teclado siempre encendido, o que se apague solo tras ~30 s sin teclear |
| **Carga USB apagado** | Umbral de bateria (0 / 10 / 20 / 30 %) por debajo del cual deja de cargar por USB con el portatil apagado |
| **Calibracion de bateria** | El driver y el helper la aceptan (`nitro-gekko-helper calibracion 0\|1`), pero la aplicacion **no la expone**: un ciclo de calibracion descarga y recarga la bateria entera durante horas y no debe quedar a un clic de distancia |
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
sudo python3 packaging/capturar-tecla.py
```

Lleva `sudo` a proposito: `/dev/input/event*` es `0640 root:input` y en Arch un
usuario normal **no** esta en el grupo `input`. El script te lo explica si lo
lanzas sin permisos. Cuando te diga el nombre de la tecla (`XF86Algo`), ponlo
en *Configuracion > Teclado > Atajos personalizados* con el comando
`nitro-gekko`, o cambia `XF86Presentation` por el tuyo en
`packaging/preparar-sistema.sh`.

---

## Licencia y creditos

Nitro Gekko se distribuye bajo la **GNU General Public License v3.0 o
posterior**. El texto completo esta en [`LICENSE`](LICENSE).

El proyecto **enlaza con codigo de kernel bajo GPL** y lo redistribuye, asi que
esto no es una preferencia: es la licencia que toca.

| Componente | Origen | Licencia |
|---|---|---|
| Aplicacion, extension, instaladores | este repositorio | GPL-3.0-or-later |
| `rgb/src/linuwu_sense.c` | copia **modificada** de [Linuwu-Sense](https://github.com/0x7375646F/Linuwu-Sense), de 0x7375646F (Sudo) | GPL-2.0-or-later |
| ↳ del que a su vez deriva | `drivers/platform/x86/acer-wmi.c` del kernel Linux, de Carlos Corbacho y E.M. Smith | GPL-2.0-or-later |

`GPL-2.0-**or-later**` permite redistribuir ese fichero como parte de un
conjunto GPL-3.0; por eso las dos licencias conviven aqui sin conflicto. El
fichero conserva su `SPDX-License-Identifier`, sus avisos de copyright
originales y un aviso de modificacion en la cabecera que detalla exactamente
que se cambio, como pide la seccion 5(a) de la GPL.

Gracias a **0x7375646F** por Linuwu-Sense: sin ese trabajo el teclado de este
portatil seguiria siendo naranja.
