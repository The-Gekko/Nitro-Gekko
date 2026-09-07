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

## Por donde empezar

**Si solo quieres usarlo:** [Requisitos](#requisitos) ·
[Instalacion](#instalacion) · [Si tu Acer es otro
modelo](#si-tu-acer-es-otro-modelo) · [Desinstalacion](#desinstalacion).

**Si vas a tocar el codigo** —persona o agente de IA—: lee antes [Como tratar
este programa](#como-tratar-este-programa). No es un adorno: aqui se pone un
modulo del kernel en la lista negra de otro, y hay cambios que no fallan hasta
el siguiente arranque.

**Este README es el unico documento del repositorio.** Los apuntes largos que
antes vivian en `packaging/SEGURIDAD.md` y en `extension/README.md`, y el
`AGENTS.md` con el contrato de trabajo, se quedan en la copia local y no se
publican; lo imprescindible de los dos primeros esta recogido aqui, en
[Seguridad y permisos](#seguridad-y-permisos) y en [La extension de GNOME
Shell](#la-extension-de-gnome-shell).

---

## Instalacion rapida, y lo que toca de tu sistema

```bash
git clone https://github.com/The-Gekko/Nitro-Gekko.git
cd Nitro-Gekko
./packaging/preparar-sistema.sh --revisar   # diagnostico: NO toca nada
sudo ./packaging/preparar-sistema.sh        # 1. el hardware
sudo ./packaging/instalar-rgb.sh            # 2. el driver del teclado RGB
sudo ./packaging/install.sh                 # 3. la aplicacion
```

**Lo que tienes que saber antes del paso 2, y no despues.** Ese paso instala un
modulo de kernel por DKMS y **pone `acer_wmi` en la lista negra**, porque los
dos drivers reclaman los mismos GUID de WMI. A partir de ahi, los perfiles
termicos y las RPM dependen de que ese modulo compile en cada kernel nuevo. Si
un dia no compila, arrancas sin perfiles, sin RPM y sin RGB. No se rompe nada
fisico y se sale con dos ordenes, que estan escritas dentro del propio
`/etc/modprobe.d/nitro-gekko-rgb.conf`:

```bash
sudo rm /etc/modprobe.d/nitro-gekko-rgb.conf /etc/modules-load.d/linuwu-sense.conf
echo 'options acer_wmi predator_v4=1' | sudo tee /etc/modprobe.d/acer-wmi.conf
```

**Si no te compensa ese riesgo, saltate el paso 2.** Con los pasos 1 y 3 tienes
perfil termico, ventiladores, PL1, turbo, bateria y temperaturas; pierdes el
teclado RGB, el control manual de los ventiladores y el overdrive del panel, y
**no se toca ningun modulo del kernel**. La aplicacion oculta sola lo que no
haya.

Todo esto, con detalle y con las medidas: [Instalacion](#instalacion), [El
riesgo real de este paso, dicho
claro](#el-riesgo-real-de-este-paso-dicho-claro) y
[Desinstalacion](#desinstalacion).

---

## Que es

Una aplicacion de escritorio y una extension de GNOME Shell que ponen en un
sitio comodo lo que en este portatil solo se puede tocar escribiendo a mano en
`/sys` como root:

- **Perfil termico** — los cinco perfiles reales del equipo
  (`low-power`, `quiet`, `balanced`, `balanced-performance`, `performance`),
  leidos del kernel, no codificados a fuego.
- **Ventiladores** — RPM del ventilador de CPU y del de GPU, en vivo,
  con las RPM tipicas de cada perfil medidas en este equipo como referencia, y
  **control manual** de los dos, que es lo que en Windows hace NitroSense.
- **Potencia** — limite de potencia sostenida de la CPU (PL1), estado del
  turbo, y un interruptor para **reaplicar el PL1 cuando cambias de perfil**
  (hace falta: el firmware reescribe el PL1 por MMIO en cada cambio).
- **Bateria** — limite de carga al 80 % y temperatura de la bateria.
- **Pantalla** — overdrive del panel.
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

**Opcional, y ya no imprescindible.** El modulo DKMS `acer-wmi-battery`, que no
viene con el kernel. En el AUR hay dos paquetes: `acer-wmi-battery-dkms` y
`acer-wmi-battery-dkms-git`. Aqui esta probado con el **`-git`**.

El **limite de carga al 80 % ya no depende de el**: si no esta, la aplicacion lo
lleva por `nitro_sense/battery_limiter`, del propio `linuwu_sense`. Lo que si se
pierde sin este modulo es **la temperatura de la bateria**, que la publica el
modulo y no el EC. Cual de los dos caminos se usa, y por que, esta en
[Overdrive del panel y limite de carga por el
EC](#overdrive-del-panel-y-limite-de-carga-por-el-ec).

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
  protege de verdad y ese vale para cualquier chip. Ver [Sobre el rango del
  PL1](#sobre-el-rango-del-pl1-10-a-65-w).
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

## Anade tu modelo

Si tu Acer no esta en la tabla DMI del driver, esto es lo que hay que hacer. La
buena noticia es que **la mayoria de la gente resuelve su caso en el paso 2, sin
recompilar nada**.

**1. Averigua tu identificacion.** Es lo unico que hace falta para todo lo demas:

```bash
cat /sys/class/dmi/id/product_name    # p. ej. Nitro AN17-51
cat /sys/class/dmi/id/board_name      # p. ej. Spacia_RTH
```

**2. Pruebalo ANTES de tocar una linea de C.** El driver acepta forzar el tipo
de equipo por parametro de modulo, y eso se deshace reiniciando:

```bash
sudo modprobe -r linuwu_sense
sudo modprobe linuwu_sense nitro_v4=1      # Nitro de 2023 en adelante
# o bien
sudo modprobe linuwu_sense predator_v4=1   # Predator Helios/Neo
```

**3. Mira que ha aparecido.** El driver no dice que quirk ha casado, asi que se
deduce de los directorios que crea:

```bash
ls /sys/devices/platform/acer-wmi/
cat /sys/firmware/acpi/platform_profile_choices
```

| Lo que ves | Que quirk ha casado |
|---|---|
| `predator_sense/` con 7 ficheros | `.predator_v4` |
| `nitro_sense/` con 7 ficheros (con `lcd_override` y `boot_animation_sound`) | `.nitro_v4` |
| `nitro_sense/` con 5 ficheros | `.nitro_sense` (Nitro V y Nitro antiguos) |
| `four_zoned_kb/` | `.four_zone_kb` (teclado RGB de 4 zonas) |

Con esto ya tienes perfiles termicos y RPM. **Lo que el parametro NO puede darte
es el RGB**: el camino del parametro salta a un quirk con `.four_zone_kb = 0`
explicito, y no existe ningun parametro para forzarlo. Para eso hay que estar en
la tabla.

**4. Antes de perseguir el RGB, comprueba que tu teclado es de los que van por
WMI.** Los Acer de 2025 en adelante han movido el RGB a un controlador **ENE
KB5130 por i2c-HID**, y ahi las escrituras WMI **devuelven exito y el teclado no
cambia**. Se reconoce asi:

```bash
ls /sys/bus/i2c/devices | grep -i ene     # si sale ENEK5130, es de esa familia
```

Si tu equipo es de esa familia, anadir la entrada DMI con `.four_zone_kb=1` solo
crea un directorio que no enciende nada. Esta reportado al menos en Nitro
AN18-61, ANV16S-41, AN16S-61 y Predator PHN16S-71 ([issue
82](https://github.com/0x7375646F/Linuwu-Sense/issues/82), [issue
84](https://github.com/0x7375646F/Linuwu-Sense/issues/84), [issue
109](https://github.com/0x7375646F/Linuwu-Sense/issues/109)), y confirmado
tambien fuera de este driver ([facer
#287](https://github.com/JafarAkhondali/acer-predator-turbo-and-rgb-keyboard-linux-module/issues/287)).

**5. Anade tu entrada.** En `rgb/src/linuwu_sense.c`, justo detras de la del
AN17-51, copiando la de un modelo de tu misma hornada:

```c
{
    .callback = dmi_matched,
    .ident = "Acer Nitro ANxx-yy",
    .matches = {
        DMI_MATCH(DMI_SYS_VENDOR, "Acer"),
        DMI_MATCH(DMI_PRODUCT_NAME, "Nitro ANxx-yy"),
    },
    .driver_data = &quirk_acer_nitro_an17_51,   /* el que dedujiste en el paso 3 */
},
```

**No quites la entrada del AN17-51 ni cambies la version de `rgb/dkms.conf` por
tu cuenta:** `instalar-rgb.sh` aborta si no encuentra la cadena `Nitro AN17-51`
en el fuente (asi comprueba que el fuente es el parcheado y no el del upstream,
que en kernel 7.2 ni compila) y tambien si el nombre y la version del
`dkms.conf` no coinciden con los suyos.

**6. Instala y comprueba.** `sudo ./packaging/instalar-rgb.sh` verifica solo que
no se ha perdido nada, y **se revierte solo** si el driver nuevo no repone los
perfiles ni los tacometros. Si repone eso pero no hay RGB, avisa y te deja
decidir: quedarse sin RGB no empeora el equipo, quedarse sin perfiles si.

### Que se sabe de cada modelo

Solo el AN17-51 esta probado aqui. Todo lo demas viene del upstream y de lo que
ha reportado otra gente, y va con su nivel de evidencia y su enlace, para que
cada uno juzgue. Revisado en septiembre de 2026.

| Modelo | En la tabla | Evidencia | Fuente |
|---|---|---|---|
| Nitro AN17-51 | si | **probado aqui** | este repositorio |
| Nitro AN16-41 / AN16-42 / AN16-43 | si | del upstream | [Linuwu-Sense](https://github.com/0x7375646F/Linuwu-Sense) |
| Nitro AN515-58 | si | del upstream; con BIOS V2.18 el modo estatico apaga el teclado | [issue 99](https://github.com/0x7375646F/Linuwu-Sense/issues/99) |
| Predator PHN16-71 / PHN16-72 | si | del upstream | Linuwu-Sense |
| Nitro ANV15-41 / ANV15-51 / AN515-55 | si, sin RGB | del upstream | Linuwu-Sense |
| Predator PH16-71 / PH18-71 / PTX17-71 / PH315-53 | si, sin RGB | del upstream | Linuwu-Sense |
| Nitro ANV15-52 | **no** | confirmado por un tercero con `quirk_acer_nitro` | [PR 117](https://github.com/0x7375646F/Linuwu-Sense/pull/117) |
| Nitro AN515-45 | **no** | confirmado por un tercero, con RGB, en kernel 6.17 | [PR 92](https://github.com/0x7375646F/Linuwu-Sense/pull/92) |
| Predator PH315-52 | **no** | confirmado por un tercero (quirk de 2019, no `predator_v4`) | [PR 119](https://github.com/0x7375646F/Linuwu-Sense/pull/119) |
| Predator PH18-73 | **no** | confirmado por un tercero | [PR 123](https://github.com/0x7375646F/Linuwu-Sense/pull/123) |
| Predator PHN16-73 | **no** | funciona forzado por parametro; solo falta la entrada DMI | [issue 126](https://github.com/0x7375646F/Linuwu-Sense/issues/126) |
| Nitro AN517-41, Predator PH315-54, Nitro AN515-54 / AN515-57 | **no** | **solo plausible**: sus autores no lo probaron en hardware | [PR 124](https://github.com/0x7375646F/Linuwu-Sense/pull/124), [PR 55](https://github.com/0x7375646F/Linuwu-Sense/pull/55), [PR 34](https://github.com/0x7375646F/Linuwu-Sense/pull/34) |
| Nitro AN18-61 / ANV16S-41 / AN16S-61, Predator PHN16S-71 | **no, y no se van a anadir** | teclado ENE KB5130 por i2c-HID: el RGB **no va por WMI** | [issue 82](https://github.com/0x7375646F/Linuwu-Sense/issues/82) |

Los cinco marcados como «confirmado por un tercero» son los unicos candidatos
razonables a entrar en la tabla. No estan todavia porque aqui no hay forma de
probarlos, y este proyecto no mete en su lista de compatibilidad cosas que no
puede sostener. Si tienes uno de esos y lo pruebas, esa es la mejor
contribucion posible.

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

### Empaquetado para Arch (AUR)

En [`packaging/aur/`](packaging/aur) hay un `PKGBUILD` que produce **tres
paquetes desde un solo `pkgbase`**, y son tres a proposito:

| Paquete | Que lleva |
|---|---|
| `nitro-gekko` | la aplicacion, el helper y la politica polkit |
| `gnome-shell-extension-nitro-gekko` | solo la extension; funciona sin la aplicacion |
| `linuwu-sense-an17-dkms` | el modulo DKMS **y la lista negra de `acer_wmi`** |

El tercero esta separado porque es el unico que puede dejar un arranque sin
ventiladores: tiene que ser una decision explicita, no un efecto colateral de
instalar una aplicacion de escritorio. Su `.install` solo imprime el aviso de
comprobar `dkms status linuwu-sense` **antes de reiniciar**; no carga ni
descarga modulos, que es lo que dice la guia de DKMS de Arch.

El `PKGBUILD` construye llamando al mismo `install.sh` con `DESTDIR`, `PREFIX` y
`DIR_EXTENSIONES`, asi que no hay una segunda lista de ficheros que se pueda
quedar desfasada.

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
`bateria`, `bateria_ec`, `turbo`, `ventiladores`, `overdrive`, `rgb_efecto`,
`rgb_zonas`, `retro_timeout`, `usb_carga`, `calibracion`, `sonido_arranque`) y
un valor que valida contra el propio kernel antes de escribirlo. La lista blanca de rutas vive dentro del helper.

Lo llama la aplicacion **y tambien la extension de GNOME Shell**: para los
dos perfiles que `power-profiles-daemon` no conoce (`quiet` y
`balanced-performance`) la extension lanza el mismo `pkexec` con el mismo
helper, de forma asincrona. Los otros tres los cambia sin contrasena por
D-Bus. Detalles y medidas en [La extension de GNOME
Shell](#la-extension-de-gnome-shell).

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
se abre `energy_uj`: [Seguridad y permisos](#seguridad-y-permisos).

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

Estan documentadas dentro del codigo, y **los numeros no son decorativos**: los
comentarios de `src/gekkonitro/` citan «gotcha 1», «gotcha 4», «gotcha 6» y
«gotcha 7», y son estos.

1. **Escribir `balanced-performance` deja el menu de energia de GNOME en
  blanco.** Es un fallo de `power-profiles-daemon` 0.30: su tabla interna compara con
  `balanced_performance`, con guion bajo, y al no encontrarlo cae en
  `g_return_val_if_reached()` y deja `ActiveProfile` en `UNSET`. La aplicacion
  **avisa con un icono** en ese perfil concreto en vez de esconderlo.
2. **El firmware pone el PL1 muy por encima del TDP del chip.** El i7-13620H es
  de 45 W nominales y Acer lo deja en **65 W (MSR) / 70 W (MMIO)**. Medido en
  este equipo con carga sostenida a 16 hilos: con 65 W se queda en 63 W y
  85 °C; **con 45 W baja a 41,9 W y 66 °C**, sin throttling y con mucho menos
  ruido. `preparar-sistema.sh` instala `rapl-pl1.service`, que reaplica ese
  limite en cada arranque y despues de suspender. **El 45 no esta cableado**:
  el script lee la potencia base que declara tu propio chip en
  `intel-rapl:0/constraint_0_max_power_uw` y usa esa. Si tu CPU declara 55 W,
  el limite sera 55 W; si tu firmware ya respeta el nominal, el paso se salta;
  y si no hay RAPL de Intel (un Acer con CPU AMD), no instala nada.
3. **No hay vatios de CPU.** `energy_uj` esta cerrado por la mitigacion de
  PLATYPUS (CVE-2020-8694) y no se va a abrir. No es una funcion pendiente: ver
  [Por que no se abre energy_uj](#por-que-no-se-abre-energy_uj-en-ningun-modo).
4. **El PL1 se reescribe solo al cambiar de perfil** (por MMIO: `balanced`
  → 70 W, `performance` → 100 W). El que manda es el MSR, y por eso el MMIO
  suele quedar descolgado. De ahi el interruptor «Reaplicar PL1 al cambiar de
  perfil».
5. **La temperatura de la bateria se divide entre 1000 y ya esta.** El valor
  bruto `33000` son 33,0 °C. La formula `(v-2731)*100` que aparece en el driver
  es su conversion interna y aqui daria un disparate.
6. **El numero de `hwmon` cambia entre arranques.** La aplicacion resuelve el
  ventilador buscando por nombre (`acer`), nunca por numero.
7. **La ruta legacy del perfil es la que notifica.**
  `/sys/firmware/acpi/platform_profile` y
  `/sys/class/platform-profile/platform-profile-0/profile` son el mismo dato,
  pero solo la primera avisa de los cambios, y es la que vigila
  `power-profiles-daemon`. Por eso se lee de la de `/sys/class`, que es un pelin
  mas barata, y se **escribe siempre en la legacy**.

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

## Control manual de los ventiladores

Es la funcion que en Windows trae NitroSense, y **la unica de la aplicacion que
puede empeorar el equipo si se usa mal**. La expone el mismo driver
`linuwu_sense` en `nitro_sense/fan_speed`, con el formato `cpu,gpu` en por
ciento.

| Valor | Que hace |
|---|---|
| `0,0` | **automatico**: los lleva el EC segun la temperatura |
| `100,100` | los dos al maximo |
| `n,m` | velocidad fija en cada uno |

La aplicacion **no deja poner menos de un 20 %** y no acepta un `0` suelto. Ese
20 no es una medida, es una eleccion prudente, y esta dicho asi tanto aqui como
en el comentario del helper. Para convertirlo en una medida hay un script que
barre el porcentaje de arriba abajo anotando las RPM de cada escalon, y que
**devuelve los ventiladores al automatico pase lo que pase**, incluido un
Ctrl+C a mitad:

```bash
./packaging/medir-ventiladores.sh --revisar   # dice que haria, sin tocar nada
sudo ./packaging/medir-ventiladores.sh        # ~3 min, hazlo con el equipo en reposo
```

El motivo del minimo es otro: por debajo de cierto punto el ventilador
puede quedarse parado, y el sintoma —un portatil que se calienta y se limita
solo— no apunta a ninguna causa. Un `0` en un solo campo significa para el driver
«ese ventilador en automatico y el otro fijo», y el mismo digito no puede
querer decir dos cosas en una interfaz privilegiada: o los dos, o ninguno.

**Tres cosas que la interfaz dice y conviene repetir:**

1. **Bajar la velocidad no puentea nada.** El PROCHOT/TCC del chip sigue ahi:
   un porcentaje bajo con carga se traduce en calor y en que la CPU se limite
   sola, no en dano.
2. **Al automatico se vuelve por dos caminos.** Apagando el interruptor, o
   poniendo el perfil en **Silencioso** o **Bajo consumo**: el propio driver
   llama a `acer_set_fan_speed(0, 0)` al aplicar esos dos. Por eso la
   aplicacion relee el estado cada segundo, para enterarse de un cambio que no
   ha hecho ella.
3. **No sobrevive a un reinicio.** El driver guarda el estado en
   `/etc/predator_state` **al descargarse el modulo**, no al apagar, y lo
   reaplica al cargarse: lo que reaparezca puede ser un valor viejo.

## Overdrive del panel y limite de carga por el EC

Dos cosas mas que el driver ya publicaba y que ahora estan en la interfaz.

**Overdrive del panel** (`nitro_sense/lcd_override`). Acelera el cambio de color
de los pixeles, a cambio de poder dejar estelas. La aplicacion **no promete
ninguna cifra de tiempo de respuesta**: la de la ficha de Acer no es una medida
de este equipo y no hay lectura de software que la confirme. Lo unico que si se
comprueba es que el atributo relee lo que se le escribe. Si devuelve algo que no
sea `0` ni `1`, la fila sale **desactivada diciendo que no se sabe**, nunca
apagada.

**Limite de carga al 80 %.** Hay dos caminos para lo mismo y la aplicacion elige
solo:

| Fuente | Ruta | Coste de lectura | Cuando se usa |
|---|---|---|---|
| Modulo DKMS del AUR | `acer-wmi-battery/health_mode` | **0,006 ms** | siempre que este |
| El propio `linuwu_sense` | `nitro_sense/battery_limiter` | **4,888 ms** (WMI) | solo si no esta el otro |

Medido en este equipo, mediana de 25 lecturas. El del modulo DKMS gana porque es
una variable suya y cabe en el ciclo de 1 Hz; el del EC es una llamada WMI real
y va al ciclo de 10 s. Y si estando los dos se escribiera por el del EC, el
modulo DKMS se quedaria con su copia desfasada para siempre.

**Lo que cambia esto para quien instala:** `acer-wmi-battery` pasa de ser
necesario para el limite de carga a ser **recomendado**. Sin el, el limite
sigue funcionando por el EC; lo que se pierde es **la temperatura de la
bateria**, que la publica ese modulo y no el EC.

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

## El sonido: el DTS:X Ultra que traia Windows

La ficha oficial de este portatil (SKU AN17-51-74WP) promete *«DTS: X(R) Ultra
audio, Acer Purified, Acer TrueHarmony»* y **dos altavoces de 2 W**. En Windows
eso se nota; en Linux no esta, y conviene saber por que, porque es una pregunta
que se repite.

**DTS:X Ultra no es hardware.** Es un *APO* (Audio Processing Object) de
Windows: un objeto COM que corre **en modo usuario** y que el motor de audio de
Windows inyecta en la cadena, instalado junto al driver Realtek. La
documentacion de Microsoft lo dice con todas las letras: *«All of the APOs are
COM based and run in user mode... none of the effects are running in hardware or
in kernel mode»*.

De ahi salen las tres consecuencias que importan aqui:

- **No hay nada que portar al modulo del kernel.** `linuwu_sense` son 4620
  lineas y no tiene una sola de audio: lo unico que roza el sonido es el pitido
  de arranque (`boot_animation_sound`), que la aplicacion **ya expone**.
- **No hay DSP donde meterlo.** SOF (el DSP de audio de Intel) no tiene modulo
  DTS en su fuente, y la topologia que carga este equipo
  (`sof-hda-generic-2ch.tplg`) **no tiene ni un ecualizador en el camino de
  reproduccion**: su unico `EQIIR` cuelga de la tuberia de captura. Los unicos
  controles de reproduccion del DSP son ganancias.
- **Tampoco hay volumen escondido.** El codec es un Realtek ALC245 sin
  amplificador inteligente (ni `cs35l41`, ni `tas27xx`, ni `max98xxx`), y el
  amplificador de salida ya esta al maximo de fabrica (`Amp-Out vals: [0x57
  0x57]` de `nsteps=0x57`). No hay ningun quirk que aplicar.

### Lo que si hay: EasyEffects

El equivalente honesto es **EasyEffects sobre PipeWire**, que hace el mismo
trabajo (ecualizador, realce de graves, compresion multibanda, limitador) y lo
hace mejor que cualquier pestana que se anadiera aqui. Es otra aplicacion, y
esta bien que lo sea: **Nitro Gekko no lleva pestana de audio y no la va a
llevar**.

Lo que si trae este repositorio son tres presets de EasyEffects pensados para
dos altavoces pequenos, en [`extras/audio/`](extras/audio):

| Preset | Para que |
|---|---|
| `Nitro Gekko - Musica` | equilibrado, sin ensanchado |
| `Nitro Gekko - Pelicula` | dialogo por delante, escenario algo mas ancho |
| `Nitro Gekko - Juego` | pasos y direccion, escenario ancho |

```bash
cp extras/audio/'Nitro Gekko - '*.json ~/.local/share/easyeffects/output/
```

y luego elegirlos en EasyEffects, en **Presets**. Se regeneran con
`python3 extras/audio/generar-presets.py`, que escribe la curva a partir de una
tabla legible en vez de a mano.

> **Estas curvas NO estan medidas**, y es la unica cosa de este repositorio de
> la que se dice eso. Todo lo demas que se afirma aqui viene de una medicion;
> esto no: no hay microfono de medicion. Son un punto de partida razonado —por
> debajo de 100 Hz un altavoz de 2 W no da nada, asi que el grave se sugiere con
> armonicos en vez de subir la banda— y se espera que los retoques.

### Como convive con lo que ya tengas

**Un solo procesador de audio, y ya lo tienes.** El riesgo real no es que Nitro
Gekko se pelee con EasyEffects: es apilar dos capas de proceso (por ejemplo un
`filter-chain` de PipeWire encima de EasyEffects), que suma ganancias, satura y
deja un sonido peor que sin nada. Por eso aqui **no se instala ningun DSP**:
solo se dejan unos ficheros de preset, que son el propio EasyEffects.

**EasyEffects procesa UN dispositivo cada vez.** Si esta fijado a unos
auriculares Bluetooth, los altavoces del portatil salen sin procesar, y al
reves. La solucion es atar un preset a cada salida, y para eso hay un ayudante
que lee los dispositivos de PipeWire y escribe la regla:

```bash
python3 extras/audio/autocarga-easyeffects.py --listar
python3 extras/audio/autocarga-easyeffects.py \
    --sink alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink \
    --preset 'Nitro Gekko - Musica'
```

Existe porque **el formato de esas reglas no esta documentado en ninguna
parte**, y las dos cosas que hay que saber se sacaron leyendo el fuente de
EasyEffects:

- El fichero se llama `<dispositivo>:<ruta>.json`, y `<ruta>` **no** es el
  perfil de la tarjeta ni el nombre del puerto: es la **descripcion** de la
  ruta (`stream_output_effects.cpp` pasa `node.device_route_description`). En un
  escritorio en espanol eso es literalmente `Auriculares` o `Speaker`. **Si
  cambias el idioma del sistema, la regla deja de casar** y hay que rehacerla.
- Las tres llamadas a la autocarga estan dentro de un
  `if (node.name == DbStreamOutputs::outputDevice())`. O sea que **solo se
  dispara para el dispositivo que EasyEffects tiene como salida**: con un
  dispositivo fijado no se disparara nunca al cambiar a otro. Hay que dejar
  activado **«usar el dispositivo por defecto»**.

Comprobado en esta maquina cambiando la salida por defecto y mirando que preset
quedaba cargado: a los altavoces entra `Nitro Gekko - Musica`, y al volver a los
auriculares Bluetooth vuelve el preset que ya habia. El ayudante avisa solo si
detecta que falta lo de «usar el dispositivo por defecto».

Y una obviedad que no lo es: **solo hay un preset activo**. Cargar uno
**sustituye** al anterior, no se suman.

---

## Seguridad y permisos

Nitro Gekko necesita escribir en ficheros de `/sys` que son `0644 root:root`.
Eso es un problema de privilegios y hay exactamente dos maneras de resolverlo.
El proyecto trae las dos, y **no son intercambiables**.

| | Modo **polkit** (por defecto) | Modo **udev** (`--con-udev`) |
|---|---|---|
| Que instala | `nitro-gekko-helper` + una politica polkit | reglas udev + `tmpfiles.d` |
| Permisos de `/sys` | siguen `0644 root:root` | seis rutas pasan a `0664 root:wheel` |
| Quien puede escribir | solo root, previa autenticacion | **cualquier proceso** de un usuario de `wheel` |
| Contrasena | una vez, cacheada unos minutos | ninguna, nunca |
| Se instala con | `sudo ./packaging/install.sh` | `sudo ./packaging/install.sh --con-udev` |

Si ejecutas `install.sh` sin banderas **no se abre ni un permiso de `/sys`**: se
instala un programa auxiliar que corre como root bajo demanda y una politica que
dice quien puede invocarlo.

### Modo polkit, el de por defecto

```
   aplicacion (uid 1000)                    root
   ---------------------                    ----
   sysfs.py::_escribir()
      |
      |  os.access(ruta, W_OK)?  ---- si -->  escritura directa (modo udev)
      |  no
      v
   pkexec /usr/lib/nitro-gekko/nitro-gekko-helper <accion> <valor>
      |                                        |
      |   polkit: org.thegekko.nitrogekko.aplicar
      |   auth_admin_keep -> dialogo de GNOME  |
      |                                        v
      |                              valida el valor y escribe
      |                              en UNA ruta de su lista blanca
      <--------- codigo de salida --------------
```

Piezas: `packaging/nitro-gekko-helper` va a
`/usr/lib/nitro-gekko/nitro-gekko-helper` (`0755 root:root`) y
`packaging/org.thegekko.nitrogekko.policy` a `/usr/share/polkit-1/actions/`
(`0644 root:root`), con la accion `org.thegekko.nitrogekko.aplicar`.

Al helper lo invocan **dos piezas, no una**: la aplicacion y tambien la
extension de GNOME Shell, para los dos perfiles que `power-profiles-daemon` no
conoce. Es el mismo ejecutable, la misma accion y la misma interfaz cerrada, y
de las trece acciones la extension solo usa `perfil`. Lo que si conviene tener
presente es que **la cache de `auth_admin_keep` la comparten las dos**:
autorizar desde Configuracion rapida deja tambien a la aplicacion sin dialogo
durante esos minutos.

### Lo que hace que esto sea seguro: el helper no acepta rutas

Una version anterior recibia la ruta como argumento:

```
pkexec nitro-gekko-helper /sys/lo/que/sea  valor      # AGUJERO
```

Eso es escalada de privilegios de manual: con la autorizacion cacheada,
cualquier proceso del usuario (una pestana del navegador, un juego, un
`npm install`) podia hacer que root escribiera en cualquier fichero. Y el
usuario no podia saber que ruta se iba a tocar mirando el dialogo.

Hoy lo unico que cruza la frontera de privilegio son **dos cadenas**: un nombre
de accion de un conjunto cerrado de trece, y un valor. Las rutas son constantes
del propio fichero del helper.

| Accion | Ruta (constante en el helper) | Valores aceptados |
|---|---|---|
| `perfil` | `/sys/firmware/acpi/platform_profile` | uno de los que lista el kernel en `platform_profile_choices` |
| `pl1` | `intel-rapl:0` y `intel-rapl-mmio:0` `constraint_0_power_limit_uw` | entero decimal 10..65 (vatios) |
| `bateria` | `acer-wmi-battery/health_mode` | `0` o `1` |
| `bateria_ec` | `acer-wmi/nitro_sense/battery_limiter` | `0` o `1` |
| `turbo` | `intel_pstate/no_turbo` | `0` o `1` |
| `ventiladores` | `acer-wmi/nitro_sense/fan_speed` | `0,0` (automatico) o los dos entre 20 y 100 |
| `overdrive` | `acer-wmi/nitro_sense/lcd_override` | `0` o `1` |
| `rgb_efecto` | `acer-wmi/four_zoned_kb/four_zone_mode` | `modo,vel,brillo,dir,R,G,B` con rango por campo |
| `rgb_zonas` | `acer-wmi/four_zoned_kb/per_zone_mode` | 4 colores `RRGGBB` + brillo 0..100 |
| `retro_timeout` | `acer-wmi/nitro_sense/backlight_timeout` | `0` o `1` |
| `usb_carga` | `acer-wmi/nitro_sense/usb_charging` | `0`, `10`, `20` o `30` |
| `calibracion` | `acer-wmi/nitro_sense/battery_calibration` | `0` o `1` |
| `sonido_arranque` | `acer-wmi/nitro_sense/boot_animation_sound` | `0` o `1` |

Propiedades que se mantienen a proposito:

1. **Ningun valor llega a `/sys` tal cual.** Todos los validadores
   *reconstruyen* lo que escriben a partir de enteros ya comprobados o de una
   lista cerrada. `pl1 45` no escribe `"45"`, escribe `str(45 * 1_000_000)`.
2. **Se valida ANTES de comprobar root.** Un valor absurdo se rechaza sin que
   polkit llegue a molestar al usuario con el dialogo.
3. **La lista de perfiles se lee del kernel**, no de una constante: si manana el
   driver expone otros perfiles el helper sigue siendo correcto.
4. **No se lee ni una variable de entorno.** pkexec limpia el entorno, pero eso
   es una propiedad del lanzador, no del helper.
5. **Interprete absoluto y aislado:** `#!/usr/bin/python3 -I`. No
   `/usr/bin/env python3`, que resolveria el interprete por `$PATH`; y `-I`
   (implica `-E -s -P`) ignora `PYTHONPATH`, `PYTHONHOME`, el `site-packages`
   del usuario y el directorio del script como `sys.path[0]`.
6. **`O_NOFOLLOW`, `O_NONBLOCK`, `O_TRUNC` y nunca `O_CREAT`.** El helper no
   puede crear un fichero nuevo en ninguna circunstancia y no sigue un enlace
   simbolico en el ultimo componente. Se abre una vez y se comprueba el
   descriptor ya abierto con `fstat`, no la ruta: asi no hay ventana TOCTOU.

### Que se ha intentado romper, y que paso

Todo esto se ejecuta sin privilegio; el helper debe terminar con codigo 5 («no
eres root») solo despues de haber aceptado el valor.

| Ataque | Ejemplo | Resultado |
|---|---|---|
| Ruta como valor | `perfil ../../../etc/shadow` | codigo 2, «perfil invalido» |
| Ruta absoluta | `pl1 /dev/sda` | codigo 2 |
| Inyeccion de shell | `pl1 '45; rm -rf /'`, `` pl1 '`id`' `` | codigo 2. No hay shell en ningun punto: el helper no llama a `subprocess` ni a `os.system`, y la app lanza `pkexec` con una lista de argumentos, no con una cadena |
| Salto de linea en el valor | `pl1 $'45\n\nrm -rf'` | codigo 2 |
| Byte NUL | | imposible por construccion: `execve()` corta los argumentos en el primer NUL |
| Numeros fuera de rango | `pl1 0`, `pl1 66`, `pl1 -45` | codigo 2 |
| Otras bases | `pl1 0x2d`, `pl1 4.5e1`, `pl1 NaN` | codigo 2 |
| Digitos que no son ASCII | `pl1 '٤٥'`, `pl1 '４５'` | codigo 2 |
| Espacios, signo, guion bajo | `pl1 ' 45 '`, `pl1 '+45'`, `pl1 '4_5'` | codigo 2 |
| Campos de mas o de menos | `rgb_efecto '3,5,80,1,255,0,0,0'` | codigo 2 |
| Longitud | 63 y 64 caracteres se examinan; 65 se rechaza antes de mirarlos | codigo 2, «valor demasiado largo» |
| Enlace simbolico en `/sys` | `ln -s /etc/shadow /sys/firmware/acpi/x` | `EPERM`. sysfs no deja crear entradas **ni a root** |
| Secuencias ANSI en los errores | `rgb_zonas $'\e[31mXX,...'` | se imprimen con `repr()`, que las escapa |

Sobre los digitos no ASCII: `int()` de Python es mucho mas permisivo de lo que
parece. `int('٤٥')` vale 45 (digitos arabigo-indices), `int('４５')` vale 45
(anchura completa), `int('4_5')` vale 45 e `int(' 45\n')` vale 45. Ninguno era
explotable, porque el valor que se escribia se reconstruia a partir del entero;
pero una interfaz privilegiada que acepta mas de lo que documenta es una
interfaz que nadie puede auditar leyendo su documentacion. El helper usa un
parser estricto: `[-]?[0-9]+` en ASCII y nada mas.

**Los codigos de salida son un contrato**, no un detalle: la aplicacion y la
extension deciden con ellos el mensaje que ve el usuario.

| Codigo | Significado | Quien lo pone |
|---|---|---|
| `0` | escrito | el helper |
| `1` | argumentos mal (numero, accion desconocida) | el helper |
| `2` | valor rechazado por el validador | el helper |
| `5` | no eres root (se ha validado igualmente) | el helper |
| `126` | el usuario cerro el dialogo, o no autorizado | pkexec |
| `127` | no se encontro el helper | pkexec |

Cerrar el dialogo **no es un fallo**: ni la aplicacion ni la extension sacan
aviso de error con el 126.

### Por que auth_admin_keep y no otra cosa

- `yes` (sin contrasena) es lo que usa `power-profiles-daemon` para
  `switch-profile`. Ahi es defendible: es un metodo D-Bus que solo acepta tres
  nombres de perfil y no puede escribir un limite de potencia arbitrario. Este
  helper si puede. `yes` seria, en la practica, el modo udev.
- `auth_admin` (contrasena en **cada** llamada) haria inusable el control del
  PL1: una contrasena por cada paso del deslizador.
- `auth_admin_keep` es lo que usan `systemd` (`manage-units`),
  `gnome-remote-desktop` y `meson` para este mismo patron.
- `allow_any` y `allow_inactive` van a `no`: nada de sesiones remotas ni de
  usuarios que no esten fisicamente delante.

Lo que **no** cubre: el dialogo es de grano grueso. Una accion polkit se
resuelve por ejecutable, asi que hay una sola, y quien autoriza «cambiar el
perfil» esta autorizando, mientras dure la cache, cualquiera de las trece
acciones. Por eso el `<message>` de la politica enumera el alcance entero. Lo
que se puede hacer con esa ventana esta acotado por la tabla de acciones:
ruido, rendimiento y desgaste de bateria. Ninguna accion da una shell, escribe
en un fichero arbitrario ni lee nada confidencial.

### Sobre el rango del PL1 (10 a 65 W)

El helper no acepta un PL1 fuera de 10 a 65 vatios, y ese rango vive **en dos
sitios que tienen que coincidir**: `PL1_MIN_W` / `PL1_MAX_W` en
`packaging/nitro-gekko-helper` y el `Adw.SpinRow.new_with_range(10, 65, 1)` de
`src/gekkonitro/window.py`. Cambiar uno solo hace que la interfaz ofrezca un
valor que el helper rechaza con codigo 2.

**El maximo no puede danar la maquina.** Medido en este equipo (i7-13620H):

```
intel-rapl:0/constraint_1_power_limit_uw       = 115000000   # PL2, 115 W
intel-rapl-mmio:0/constraint_0_power_limit_uw  =  70000000   # 70 W ahora mismo
intel-rapl:0/constraint_0_max_power_uw         =  45000000   # base declarada
```

El firmware Acer ya sostiene 70 W por MMIO al cambiar de perfil (100 W en
`performance`) y ya autoriza rafagas de 115 W por PL2. Un PL1 de 65 W queda
**por debajo** de lo que la maquina hace sola. Ademas PL1 es un limite de
*potencia*, no un desbloqueo de voltaje ni de frecuencia: no puentea el
PROCHOT/TCC ni el control de ventiladores del EC.

**Ojo con `constraint_0_max_power_uw`.** Vale 45 W aqui y es la potencia base
que Intel declara para el chip, **no** un tope que el kernel imponga: la prueba
es que el MMIO esta ahora mismo en 70 W, por encima de su propio «maximo». Se
lee a titulo informativo pero no se usa como limite, porque si se usara el
helper prohibiria justo los 65 W con los que la maquina arranca de fabrica.

**El minimo es el que de verdad protege.** El abuso realista del PL1 no es
subirlo, es **bajarlo**: dejarlo en 5 W hace la maquina inservible y el sintoma
(«esto va lentisimo desde hace dias») no apunta a ninguna causa.

### Modo udev, el opcional sin contrasena

Este modo **no se instala si no lo pides**. Existe porque el dialogo de
contrasena, aunque sea una vez cada varios minutos, molesta.

`packaging/99-nitro-gekko.rules` (4 rutas) y `packaging/nitro-gekko.conf` (las
otras 2) cambian **seis** ficheros de `0644 root:root` a `0664 root:wheel`.
Nada mas.

| Ruta | Que controla | Lo pone |
|---|---|---|
| `/sys/firmware/acpi/platform_profile` | perfil termico (interfaz legacy, la que notifica) | tmpfiles |
| `/sys/class/platform-profile/platform-profile-0/profile` | el mismo perfil, interfaz nueva | udev + tmpfiles |
| `intel-rapl:0/constraint_0_power_limit_uw` | PL1 por MSR | udev + tmpfiles |
| `intel-rapl-mmio:0/constraint_0_power_limit_uw` | PL1 por MMIO | udev + tmpfiles |
| `acer-wmi-battery/health_mode` | limite de carga de bateria | udev + tmpfiles |
| `intel_pstate/no_turbo` | turbo de CPU | tmpfiles |

No se abre **ninguna lectura nueva**: los seis ya eran legibles por todo el
mundo. Lo unico que cambia es quien puede **escribir**. No se toca
`constraint_1` (PL2), ni `constraint_2`, ni ningun `enabled`.

**Las rutas del teclado y del EC NO estan aqui.** `four_zone_mode`,
`per_zone_mode`, `backlight_timeout`, `usb_charging`, `battery_calibration` y
`boot_animation_sound` siguen siendo `0644 root:root` incluso con `--con-udev`,
asi que esas seis acciones **siguen pasando por pkexec** y siguen pidiendo
contrasena. Es deliberado: `battery_calibration` arranca un ciclo completo de
descarga y carga de la bateria.

El argumento a favor de este modo es real pero parcial:

> La PERSONA no gana ninguna capacidad nueva. Ya podia escribir esos seis
> ficheros con `sudo tee`. Esto solo le ahorra teclear la contrasena.

Y el argumento en contra es el que importa:

> Los PROCESOS que corren como esa persona SI ganan capacidad nueva.

Con las reglas puestas, cualquier cosa que se ejecute con tu uid —el navegador,
una extension del navegador, un juego, un `npm install`, un script copiado de un
foro— escribe en esos seis ficheros **en silencio, sin contrasena y sin dejar
rastro evidente**. Y en este modo la aplicacion escribe directa en sysfs:
**la validacion del helper desaparece**, incluido el rango 10..65 W.

Riesgo concreto de cada ruta, para no exagerarlo ni minimizarlo:

- **`platform_profile`.** Un proceso puede dejar el portatil en `performance`:
  de ~1661 RPM en `quiet` a ~3237 RPM, el doble de ruido para ganar 1 °C. Y
  escribiendo `balanced-performance` puede dejar a proposito el menu de energia
  de GNOME en blanco.
- **PL1 (MSR y MMIO).** Hacia arriba no hay dano posible. El abuso realista es
  bajarlo: a 5 W la maquina queda inservible sin ningun aviso.
- **`health_mode`.** Poner `0` desactiva en silencio el limite al 80 % que
  tenias puesto para cuidar la bateria; no lo notas hasta meses despues.
- **`no_turbo`.** Perdida de rendimiento sostenida y silenciosa. El menos grave.

**Techo de riesgo:** ruido, rendimiento y desgaste de bateria. No hay escalada
a root, no hay fuga de informacion, no hay persistencia. Es pequeno, pero no es
cero, y es exactamente lo que el modo por defecto evita.

### Por que no se abre energy_uj, en ningun modo

`/sys/class/powercap/intel-rapl:0/energy_uj` esta en `0400 root` y **se queda
como esta**. No aparece en las reglas, ni en el `tmpfiles.d`, ni en la lista
blanca del helper, y no debe aparecer nunca.

El motivo es **PLATYPUS (CVE-2020-8694)**. Los contadores de energia de RAPL
tienen resolucion suficiente para que un proceso sin privilegios que los lea en
bucle deduzca **que esta ejecutando el resto del sistema** correlacionando el
consumo con el codigo: se demostro recuperar claves AES-NI y secretos de un
enclave SGX asi. La respuesta del kernel fue quitar la lectura a los usuarios
normales.

Esa diferencia es la clave de todo este apartado:

- Las seis rutas del modo udev son de **escritura molesta**: un atacante hace
  ruido.
- `energy_uj` es de **lectura confidencial**: un atacante se lleva secretos.

Consecuencia practica y honesta: **Nitro Gekko no muestra vatios de CPU.** No es
un olvido ni una funcion pendiente. No hay dato porque no se va a leer.

### En que modo esta esta maquina

Que hay instalado:

```bash
ls -l /usr/lib/nitro-gekko/nitro-gekko-helper \
      /usr/share/polkit-1/actions/org.thegekko.nitrogekko.policy \
      /usr/lib/udev/rules.d/99-nitro-gekko.rules \
      /usr/lib/tmpfiles.d/nitro-gekko.conf 2>&1
```

Los dos primeros = modo polkit. Los dos ultimos = ademas, modo udev.

Que permisos hay abiertos ahora mismo:

```bash
ls -l /sys/firmware/acpi/platform_profile \
      /sys/class/platform-profile/platform-profile-0/profile \
      /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw \
      /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw \
      /sys/bus/wmi/drivers/acer-wmi-battery/health_mode \
      /sys/devices/system/cpu/intel_pstate/no_turbo
```

Si sale `rw-r--r-- root root`, estas en modo polkit y no hay nada abierto. Si
sale `rw-rw-r-- root wheel`, lo ha puesto el modo udev de Nitro Gekko.
Cualquier otra cosa de `/sys` con permisos raros **no es de Nitro Gekko**.

Para quitar solo el modo udev y quedarte con polkit basta con borrar
`/usr/lib/udev/rules.d/99-nitro-gekko.rules` y
`/usr/lib/tmpfiles.d/nitro-gekko.conf` y reiniciar: al arrancar, los permisos
vuelven a ser los del kernel. `install.sh --uninstall` lo hace ademas **en
caliente**, sin esperar al reinicio.

### La alternativa que sigue sin estar: un demonio D-Bus

Lo correcto de manual, por encima incluso del helper por pkexec, seria un
demonio de sistema con **polkit por metodo**: `SetPerfil`, `SetPL1`,
`SetHealthMode`, cada uno con su accion. Ganaria autorizacion por operacion y un
unico sitio donde registrar quien pidio que. No ganaria nada de lo que ya
tenemos: los ficheros de `/sys` ya son `0644 root:root` y la validacion ya corre
como root. Y costaria duplicar el proyecto y anadir un **proceso privilegiado
permanente**, que es superficie de ataque nueva y de la peor clase: siempre
encendido, siempre escuchando. El helper existe solo durante los milisegundos
que tarda en escribir en un fichero, y muere.

Es un cambio de riesgo consciente, no un descuido. **Si esta maquina pasara a
tener varios usuarios con permisos distintos, la accion polkit unica deja de
valer y hay que trocearla.** El cambio esta acotado: todas las escrituras de
la aplicacion pasan por un unico metodo: `_escribir()`, en
`src/gekkonitro/sysfs.py`.

---

## La extension de GNOME Shell

Un toggle en **Configuracion rapida** para cambiar el perfil termico sin abrir
la aplicacion. Es el 90 % del uso diario.

- **UUID:** `nitro-gekko@thegekko.dev`
- **Destino:** GNOME Shell **50** (`shell-version: ["50"]`)
- **Ficheros:** `extension/metadata.json`, `extension.js`, `stylesheet.css`

Ensena el perfil activo como subtitulo con su icono, despliega **los perfiles
leidos de sysfs** (nunca codificados: salen de
`/sys/class/platform-profile/platform-profile-0/choices`), muestra las RPM de
los dos ventiladores dentro del menu, marca `balanced-performance` con un aviso
y trae un boton «Abrir Nitro Gekko» solo si la aplicacion esta instalada.

### La escalera para cambiar de perfil

Los cinco perfiles se pueden aplicar desde aqui. Se prueban por orden, de lo
gratis a lo que pide contrasena, y **cada peldano se comprueba releyendo
sysfs**: nada se da por bueno porque una llamada haya respondido «correcto».

| # | Via | Contrasena | Cuando sirve |
|---|---|---|---|
| 1 | ya esta puesto | — | se pulsa el perfil activo |
| 2 | D-Bus a `power-profiles-daemon` | **no** | `low-power`, `balanced`, `performance` |
| 3 | escritura directa en sysfs | **no** | solo si se instalo con `--con-udev` |
| 4 | `pkexec` + helper del sistema | **si, una vez** | `quiet` y `balanced-performance` en modo polkit |

`power-profiles-daemon` expone la accion polkit
`org.freedesktop.UPower.PowerProfiles.switch-profile` con **`implicit active:
yes`**: la sesion activa cambia de perfil sin contrasena y PPD escribe el
`platform_profile` por nosotros, como root. Pero PPD solo conoce tres perfiles,
asi que `quiet` y `balanced-performance` bajan al peldano 4.

Las normas de revision de extensions.gnome.org permiten ese peldano
explicitamente: *«Spawning privileged subprocesses should be avoided at all
costs. If absolutely necessary, the subprocess MUST be run with `pkexec` and
MUST NOT be an executable or script that can be modified by a user process.»*
El helper vive en `/usr/lib/nitro-gekko/nitro-gekko-helper`, es `root:root 0755`
y lo pone el instalador del sistema; la extension no trae ningun ejecutable ni
lo puede modificar, y si el helper no esta instalado lo dice y no intenta nada.

**No bloquea el compositor.** Medido dentro de un `gnome-shell` 50.4 real:
lanzar el proceso con `Gio.Subprocess` cuesta **7 ms**, y con un hijo corriendo
3 segundos el shell sigue contestando por D-Bus en **11 a 18 ms**. Dos detalles
que no se pueden quitar: se **cierra Configuracion rapida antes de lanzar
`pkexec`** (el propio `polkitAgent.js` avisa de que el dialogo puede no llegar a
abrirse si otro actor tiene el *grab*), y se lanza con
**`--disable-internal-agent`**, porque sin esa bandera pkexec registraria un
agente de **texto** esperando una contrasena por una entrada estandar que nadie
va a rellenar.

### Dos fallos ajenos que la extension tiene que sortear

**1. `power-profiles-daemon` responde «correcto» sin hacer nada.** PPD guarda el
perfil activo en una variable suya y, si le pides el que ya cree tener, sale sin
tocar el hardware y responde bien. En este portatil pasa constantemente, porque
`quiet` y `balanced-performance` se escriben por el peldano 4 y PPD se queda
creyendo que sigue en el ultimo que el puso. Reproducido:

```
platform_profile   = balanced-performance
PPD ActiveProfile  = balanced
Set(ActiveProfile, "balanced")  -> rc=0
platform_profile   = balanced-performance    <-- NO HA CAMBIADO NADA
```

Pulsar «Equilibrado» no hacia absolutamente nada, y sin un solo error. La salida
es el *empujon*: si PPD ya cree estar en el perfil pedido, se le pasa antes por
otro (elegido de la lista que el propio PPD publica) para que el siguiente `Set`
sea un cambio de verdad.

**2. Una lectura suelta de `platform_profile` puede mentir.** El *getter* hace
una llamada WMI real y `linuwu_sense` no la excluye mutuamente con las demas.
Medido con el equipo quieto en `balanced` y otro proceso leyendo
`/sys/devices/platform/acer-wmi/nitro_sense/{usb_charging,backlight_timeout}`
—exactamente lo que hace la ventana de Nitro Gekko mientras esta abierta—, sobre
**400 lecturas** de `platform_profile`:

```
345 correctas
 31 fallidas       (EIO / «la operacion no esta soportada»)
 24 con OTRO VALOR («quiet» estando en «balanced»)
```

Un **13,75 %** de lecturas inservibles. Es un fallo del **driver**, no de la
extension; se compensa, no se arregla. Toda lectura que decida algo pasa por
`_leerPerfilFiable()`, que insiste hasta que **dos lecturas seguidas dicen lo
mismo**, separadas 120 ms. Con la lectura confirmada, 25 de 25 correctas bajo
esa misma carga.

### Decisiones que no se pueden deshacer sin romper algo

- **El temporizador solo vive con el menu abierto.** Las RPM se refrescan cada
  2 s, pero unicamente entre `open-state-changed(true)` y `(false)`. Medido:
  6 s con el menu cerrado, **0 lecturas y 0 temporizadores**. El subtitulo se
  mantiene al dia con un `GFileMonitor` sobre el fichero de perfil, que si
  funciona en sysfs.
- **Todo es asincrono, ficheros y procesos.** Una sola llamada sincrona congela
  el compositor entero.
- **Las banderas de escritura tienen que ser `Gio.FileCreateFlags.NONE`.** Con
  `REPLACE_DESTINATION`, GLib crea un temporal en el mismo directorio y lo
  renombra encima; en sysfs el directorio no es escribible y la escritura falla.
- **Ni un solo perfil codificado a fuego, tampoco el neutro.** El perfil neutro
  y el rapido se eligen en tiempo de ejecucion de la lista de `choices`: el
  neutro es `balanced` si esta, y si no el del medio; el rapido es el ultimo,
  que es el mas potente porque `choices` viene ordenado de menos a mas.
- **El ornamento tiene que quedarse el ultimo hijo de la fila.**
  `PopupImageMenuItem` mueve la marca de seleccion detras de la etiqueta; todo
  lo que se anada despues con `add_child()` va detras de la marca y la empuja al
  centro. Las RPM de referencia y el triangulo de aviso se insertan con
  `insert_child_above()`.
- **Nada de `TABLA[id]` a pelo.** La tabla de presentacion se consulta con
  `Object.hasOwn()` y el mapeo a PPD es un `Map`: con acceso directo a un objeto
  literal, un perfil llamado `constructor` o `toString` devuelve el miembro
  heredado de `Object.prototype` y la extension revienta.
- **Ninguna senal se queda con una promesa suelta.** Las cinco que arrancan
  trabajo asincrono pasan por un envoltorio que hace `.catch()`. Un rechazo sin
  capturar sale en el journal como `Unhandled promise rejection` y encima deja
  la interfaz mintiendo.
- **`opacity` no existe en el CSS de St.** Lo que hay que atenuar se atenua
  poniendo la propiedad del actor desde `extension.js`.
- **Cuidado con `error instanceof Gio.IOErrorEnum`:** en GJS es cierto para
  **cualquier** `GError` del dominio Gio, «Permiso denegado» incluido. Se
  comprueba `error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED)`.
- **`QuickSettingsItem` crea el menu pero no lo destruye**, y su actor cuelga
  del *overlay* del panel: hay que llamar a `this.menu.destroy()` a mano en
  `disable()`. Comprobado desactivando la extension con el menu abierto y el
  temporizador corriendo: no queda ni el temporizador, ni el `Cancellable` sin
  cancelar, ni un `pkexec` en vuelo (se mata con `force_exit()`).

### Si el toggle no aparece

**Si el equipo no expone `/sys/firmware/acpi/platform_profile`, la extension no
se dibuja.** No es un fallo ni un error silencioso: sin esa ruta no hay perfiles
que ofrecer, asi que el indicador no se crea. Y **solo carga en GNOME Shell
50**: `metadata.json` declara `"shell-version": ["50"]` y GNOME rechaza como
*outdated* cualquier extension cuya version no este en esa lista, sin explicar
gran cosa.

Para ver que pasa:

```bash
gnome-extensions info nitro-gekko@thegekko.dev   # el campo State lo dice
journalctl -f -o cat /usr/bin/gnome-shell
```

---

## Como tratar este programa

Todo lo anterior explica **como se usa**. Esto explica **como se toca**, y esta
escrito para quien retome el proyecto: una persona, o un agente de IA al que le
suelten el repositorio y una tarea.

En la copia local de trabajo hay ademas un `AGENTS.md` con el contrato corto
—como se trabaja, que se comprueba antes de dar algo por bueno, y una bitacora
de hallazgos que se actualiza en cada sesion—. No se publica: si algo de ahi le
sirve a quien clone el repositorio, tiene que acabar en este README.

Leelo entero antes de editar un fichero. No es celo: este proyecto pone un
modulo de kernel en la lista negra del otro, escribe en `/etc` y expone un
programa que corre como root. Casi todo se arregla en dos ordenes, pero hay
fallos que **no se ven hasta el siguiente arranque**, que es el peor momento
para descubrirlos.

### Lo primero: el alcance

Esto se escribio, se midio y se probo en **un** portatil: Acer Nitro AN17-51
(Spacia_RTH, BIOS V1.11), Arch Linux, kernel `linux-zen`, GNOME 50.4 sobre
Wayland. Todo lo demas es hipotesis, y en este repositorio las hipotesis van
declaradas como tales.

Hay tres cosas que son **medidas de este equipo, no lecturas del tuyo**, y que
por lo tanto pueden mentir en cualquier otra maquina:

| Que | Donde vive | Si estas en otro equipo |
|---|---|---|
| RPM tipicas por perfil | `RPM_TIPICAS` en `src/gekkonitro/sysfs.py` | son de referencia; las RPM en vivo si son las tuyas |
| Rango del PL1, 10 a 65 W | `PL1_MIN_W`/`PL1_MAX_W` en `packaging/nitro-gekko-helper` **y** el `SpinRow` de `src/gekkonitro/window.py` | el 65 es el valor de fabrica de este chip |
| `KEY_PRESENTATION` del boton de la marca | `packaging/preparar-sistema.sh` | averigualo con `packaging/capturar-tecla.py` |

De los siete modelos que reconoce la tabla DMI del driver, **solo el AN17-51
esta probado**; los otros seis vienen del upstream. Eso esta dicho en
[Si tu Acer es otro modelo](#si-tu-acer-es-otro-modelo) y no se quita.

### El mapa

```
src/gekkonitro/     la aplicacion GTK4/libadwaita
  sysfs.py          TODO el acceso a /sys y TODAS las escrituras. Python puro:
                    no importa gi, GTK ni GLib, para poder probarlo sin sesion
                    grafica.  Aqui esta _escribir(), la frontera de privilegio
  window.py         la unica capa que toca widgets. Tres bucles de refresco
  grafica.py        la grafica de RPM con cairo. Sin temporizador propio
  ajustes.py        dos claves en ~/.config/nitro-gekko/ajustes.json
  __main__.py       Adw.Application, ventana unica
extension/          extension de GNOME Shell 50. Funciona sin la aplicacion
packaging/          helper privilegiado, politica polkit, reglas udev y los
                    cuatro instaladores
rgb/                copia MODIFICADA de Linuwu-Sense + DKMS. Codigo ajeno
data/               icono, .desktop
nitro-gekko         lanzador de desarrollo: ejecuta el repositorio sin instalar
```

**Dos ficheros concentran casi todo el riesgo**, y conviene abrirlos antes que
ningun otro:

- `src/gekkonitro/sysfs.py`, metodo `_escribir()`: por ahi sale **toda**
  escritura de la aplicacion. Si cambias como se escribe, se cambia aqui y en
  ningun otro sitio.
- `packaging/nitro-gekko-helper`, diccionario `ACCIONES`: la unica lista blanca
  de rutas que corre como root.

Y una frontera que no es evidente: **los nombres de accion son un contrato
entre procesos**. La cadena que viaja por `pkexec` es literalmente `perfil`,
`pl1`, `rgb_zonas`... y la usan a la vez `sysfs.py`, el helper y
`extension.js`. Renombrar uno rompe las tres piezas a la vez, y falla en
tiempo de ejecucion, no al compilar.

### Las reglas que no se negocian

Cada una de estas esta puesta por un fallo que ya paso, y casi todas tienen su
parrafo de «por que» dentro del codigo.

1. **El helper nunca recibe una ruta.** Ni entera, ni un trozo, ni un indice que
   se concatene a una ruta. Solo un nombre de accion de la lista cerrada y un
   valor. Anadir un argumento de ruta es reabrir un agujero de escalada a root
   que ya estuvo abierto.
2. **No se toca el shebang `#!/usr/bin/python3 -I`** ni se leen variables de
   entorno en el helper. Con `env python3` y sin `-I`, un `PATH` o un
   `PYTHONPATH` manipulados ejecutan codigo arbitrario **como root** (comprobado
   con la version anterior).
3. **No se «limpia» la funcion `escribir()` del helper.** `O_NOFOLLOW`,
   `O_NONBLOCK`, `O_TRUNC`, la ausencia de `O_CREAT` y el `fstat` sobre el
   descriptor ya abierto son cinco medidas con su fallo reproducido detras. Sin
   `O_NONBLOCK`, un `os.open()` sobre una FIFO **cuelga para siempre** a un
   proceso root con la autorizacion ya concedida.
4. **El rango del PL1 se queda en 10 a 65 W, en los dos sitios a la vez.** Y
   `constraint_0_max_power_uw` se lee como informacion, nunca como limite.
5. **`--con-udev` no se pone por defecto ni se «simplifica» quitando el camino
   pkexec.** En ese modo desaparece la validacion entera del helper.
6. **`energy_uj` no se abre nunca**, y por eso no hay vatios de CPU. No es una
   funcion pendiente.
7. **El perfil se ESCRIBE siempre en `/sys/firmware/acpi/platform_profile`**, la
   ruta legacy, aunque se lea de la de `/sys/class`. La legacy es la unica que
   notifica, y es la que vigila `power-profiles-daemon`: escribir en la otra
   funciona pero deja al resto del sistema desincronizado.
8. **No se cablea ningun numero de `hwmon` ni el nombre del nodo de bateria.**
   El hwmon se busca por nombre (`acer`) porque el numero cambia entre
   arranques; la bateria se elige por contenido (`type=Battery` y
   `scope != Device`), porque si no la aplicacion acaba ensenando la bateria de
   un raton inalambrico (comprobado: `hidpp_battery_0`, 58 %).
9. **Ninguna lectura de `/sys/devices/platform/acer-wmi/*` entra en el bucle de
   1 Hz sin medirla antes.** Casi todas son llamadas WMI reales al firmware, y
   ademas son las que hacen mentir a las lecturas de perfil de la extension.
   Medido aqui (mediana de 25 lecturas):

   | Atributo | Coste | Donde va |
   |---|---|---|
   | `fan_speed` | **0,007 ms** | ciclo de 1 Hz: no es WMI, el driver devuelve dos variables suyas |
   | `battery_limiter` | 4,888 ms | ciclo de 10 s, y solo si no esta el modulo DKMS |
   | `lcd_override` | 5,229 ms | bajo demanda, nunca en un temporizador |
   | `usb_charging` | 6,775 ms | dentro de `leer_teclado()`, bajo demanda |
   | `leer_teclado()` entero | 47 a 53 ms | al abrir la pagina y tras cada cambio |

   `fan_speed` es la unica excepcion y ademas **tiene** que estar a 1 Hz: el
   propio driver devuelve los ventiladores al automatico al pasar el perfil a
   Silencioso o Bajo consumo, asi que la interfaz se entera de un cambio que no
   ha hecho ella.
10. **No se toca `rgb/src/linuwu_sense.c` sin conservar sus dos parches**
    (el quirk del AN17-51 con `.four_zone_kb=1` y su entrada DMI, y los tres
    `strncpy()` -> `memcpy()`). Traer el fuente del upstream tal cual es la
    forma mas rapida de dejar el portatil sin ventiladores en el siguiente
    arranque, porque `acer_wmi` esta en la lista negra.
11. **No se cambia `shell-version` de `extension/metadata.json`** para «que
    funcione en mi GNOME». Declara `["50"]` a proposito, que es donde esta
    probada. Ampliar el array no hace que funcione: hace que cargue sin estar
    probada.
12. **En la politica polkit, `allow_active` sigue siendo `auth_admin_keep`**, y
    en sus comentarios XML no puede haber dos guiones seguidos. Un XML mal
    formado no da error visible: polkit lo descarta en silencio y pkexec cae en
    `auth_admin` sin cache, o sea contrasena en cada pulsacion.
13. **En `99-nitro-gekko.rules` no se usa `MODE=`, `GROUP=` ni `ATTR{}`** para
    cambiar permisos, sino `RUN+="/usr/bin/chgrp ..."` con rutas absolutas: esos
    dispositivos no tienen nodo en `/dev` y las otras claves serian
    silenciosamente inutiles. Un `$` de shell dentro de un valor hace que udev
    **rechace la regla entera**.
14. **Las listas cerradas se leen de su fuente, no se inventan.** Los perfiles,
    de `platform_profile_choices`; los ocho efectos RGB y sus rangos, del
    `switch` de `four_zoned_rgb_kb_store()` en el driver; `usb_charging`, de
    `0/10/20/30` y nada mas (el driver interpreta en silencio como 0 cualquier
    otro valor, asi que relajar la validacion hace creer al usuario que ha
    puesto un 15 % que en realidad lo desactiva).
15. **`battery_calibration` no se expone en la interfaz.** El helper la acepta y
    el driver la tiene, pero un ciclo de calibracion descarga y recarga la
    bateria entera durante horas y no puede quedar a un clic.
16. **Los avisos honestos no se quitan, y los avisos no se convierten en
    abortos.** Cada script tiene decidido si se planta o si sigue, y la
    asimetria es deliberada: `install.sh` avisa y sigue porque solo copia
    ficheros; `preparar-sistema.sh` aborta si no eres Acer;
    `instalar-rgb.sh` **se revierte solo** si el driver nuevo no repone los
    perfiles y los tacometros, porque el siguiente arranque seria sin
    ventiladores.
17. **Todo lo que pueda pasar por pkexec es asincrono** y vuelve al hilo de la
    interfaz con `GLib.idle_add`. En la extension, sin excepcion: una llamada
    sincrona dentro de `gnome-shell` congela el compositor entero.
18. **No se traduce nada al ingles** ni se «limpian» los comentarios largos.
    Ver [El estilo, que hay que imitar](#el-estilo-que-hay-que-imitar).

### El presupuesto de tiempo

El reparto de lecturas de la aplicacion no es una preferencia: sale de medir con
`time.perf_counter`, y la tabla completa esta en la cabecera de
`src/gekkonitro/sysfs.py`.

| Ciclo | Periodo | Coste | Que lee |
|---|---|---|---|
| `leer_rapido()` | 1 s | 0,6 ms | ventiladores, temperatura, PL1, bateria, frecuencia |
| `leer_lento()` | 10 s | 10,0 ms | perfil (ACPI) y temperatura de bateria (WMI) |
| `leer_gpu()` | 5 s, en un hilo | variable | `nvidia-smi`, que despierta la tarjeta |
| `leer_teclado()` | **bajo demanda** | 47 a 53 ms | los cinco atributos del EC y del RGB |

Lo contraintuitivo, y por eso esta medido: **leer el perfil es la lectura mas
cara de todas** (5 a 7 ms; es una llamada ACPI real, no un fichero). Por eso no
esta en el bucle de 1 Hz aunque parezca lo natural, y se relee al instante
solo despues de que lo escribamos nosotros.

### El flujo de trabajo

**Lo instalado es una COPIA.** Editar el repositorio no cambia lo que corre.
Esta es la primera hora perdida de todo el que retoma esto, porque se depura
contra codigo viejo:

| Lo que editas | Lo que corre | Como se actualiza |
|---|---|---|
| `src/gekkonitro/` | `/usr/lib/nitro-gekko/gekkonitro/` | `sudo ./packaging/install.sh`, o pruebalo antes con `./nitro-gekko` |
| `extension/` | `~/.local/share/gnome-shell/extensions/nitro-gekko@thegekko.dev/` | copiar y **cerrar sesion** (en Wayland `Alt+F2 r` no vale) |
| `packaging/nitro-gekko-helper` | `/usr/lib/nitro-gekko/nitro-gekko-helper` | `sudo ./packaging/install.sh` |
| `rgb/src/linuwu_sense.c` | el modulo DKMS de `/usr/src` | `sudo ./packaging/instalar-rgb.sh` |

**`install.sh` copia `src/` y `extension/` con `cp -a` y solo limpia
`__pycache__`.** Todo lo demas que haya en esas carpetas se instala como codigo
de sistema: un `.bak` del editor acaba en `/usr/lib/nitro-gekko/` y se queda
ahi. Mira que hay antes de instalar.

**No hay pruebas automaticas, ni CI, ni `pyproject.toml`, ni linters.** El
estilo es una convencion, no una regla que compruebe una maquina. Lo que si hay
son cuatro comprobaciones baratas, y son las que se pasan antes de dar nada por
bueno:

```bash
bash -n packaging/install.sh packaging/preparar-sistema.sh \
        packaging/instalar-rgb.sh packaging/probar-rgb.sh   # sintaxis, sin ejecutar
python3 -m py_compile src/gekkonitro/*.py packaging/nitro-gekko-helper
udevadm verify packaging/99-nitro-gekko.rules               # lo mismo que hace install.sh
xmllint --noout --valid packaging/org.thegekko.nitrogekko.policy
```

Con el `xmllint`, ojo: **no basta con el codigo de salida**. `install.sh` exige
que la salida sea **vacia**, porque un aviso de validacion no siempre cambia el
codigo de retorno y un `.policy` invalido degrada la autenticacion en silencio.

### Como probar sin quedarte sin ventiladores

Por orden de seguridad. Los cuatro primeros no tocan nada:

```bash
./nitro-gekko                                    # la app desde el repositorio
DESTDIR=/tmp/prueba ./packaging/install.sh       # arbol falso: ni root, ni /sys,
find /tmp/prueba -type f | sort                  #   ni udev, ni caches
./packaging/preparar-sistema.sh --revisar        # diagnostico del hardware
./packaging/probar-rgb.sh --dry-run              # los 8 pasos, sin darlos
```

Para ensayar lo que diria en **otro** equipo sin tener otro equipo, los scripts
aceptan variables de entorno pensadas justo para eso (solo con `--revisar`):

```bash
DIR_DMI=/ruta/falsa      ./packaging/preparar-sistema.sh --revisar  # otro modelo
DIR_POWERCAP=/ruta/falsa ./packaging/preparar-sistema.sh --revisar  # sin RAPL de Intel
```

Los validadores del helper se prueban **sin privilegio y sin tocar nada**: el
helper valida antes de comprobar que es root, asi que un valor bueno termina en
codigo 5 («no eres root») y uno malo en codigo 2:

```bash
./packaging/nitro-gekko-helper pl1 45   ; echo $?   # 5  -> aceptado
./packaging/nitro-gekko-helper pl1 66   ; echo $?   # 2  -> fuera de rango
./packaging/nitro-gekko-helper perfil ../../etc/shadow ; echo $?   # 2
```

Y la capa de hardware entera se puede ejercitar desde una consola de texto,
porque `sysfs.py` no importa GTK:

```bash
PYTHONPATH=src python3 -c 'from gekkonitro import sysfs; c=sysfs.ControlNitro(); \
print(c.diagnostico(), c.leer_rapido(), c.leer_lento())'
```

**El unico ensayo que descarga drivers en caliente es `probar-rgb.sh`**, y esta
pensado para ejecutarse **antes** de instalar nada: si ya tienes `linuwu_sense`
cargado se planta a proposito. Restaura solo el driver de partida aunque falle a
mitad o lo cortes con Ctrl+C. `instalar-rgb.sh`, en cambio, **no tiene ensayo en
seco**: cualquier ejecucion que no sea `--help` compila e instala de verdad.

> **En esta maquina de desarrollo dos de esas ordenes ya no valen**, y no es que
> esten rotas: `probar-rgb.sh` se niega porque `linuwu_sense` ya esta instalado,
> y `make -C rgb` aborta porque la ruta del repositorio tiene un espacio y
> kbuild no los admite. Para compilar a mano:
> `cp -a rgb /tmp/rgb && make -C /tmp/rgb`.

### Si un arranque se queda sin perfiles ni ventiladores

Es el unico dano practico que este proyecto puede causar, y viene siempre de lo
mismo: `acer_wmi` esta en la lista negra y el modulo DKMS no ha compilado
contra el kernel nuevo. Se reconoce y se arregla como esta escrito en [El
riesgo real de este paso, dicho
claro](#el-riesgo-real-de-este-paso-dicho-claro). Las mismas instrucciones van
dentro de
`/etc/modprobe.d/nitro-gekko-rgb.conf`, que es el fichero que uno acaba
encontrando cuando busca por que se ha quedado sin ventiladores. **No las
borres de ahi.**

### Donde vive cada version

Son cuatro sitios, y dos de ellos **tienen que coincidir literalmente**:

| Fichero | Que declara |
|---|---|
| `src/gekkonitro/__init__.py` | `VERSION` de la aplicacion |
| `extension/metadata.json` | `version-name` y `shell-version` |
| `rgb/dkms.conf` | `PACKAGE_NAME` y `PACKAGE_VERSION` |
| `packaging/instalar-rgb.sh` | `NOMBRE` y `VERSION`, que **deben** ser los mismos que los de `dkms.conf` |

Si no coinciden, DKMS registra el modulo con otro nombre y ni siquiera
`--revertir` sabe quitarlo.

### El estilo, que hay que imitar

El proyecto esta escrito entero en castellano: comentarios, docstrings,
identificadores, banderas (`--revisar`, `--revertir`, `--ayuda`), mensajes de la
interfaz y documentacion. El ingles solo entra donde lo impone una API ajena
(`do_activate`, `enable`, `disable`), donde es un nombre del kernel
(`platform_profile`, `four_zone_mode`, `health_mode`) o en la traduccion
obligatoria de la politica polkit.

**La ortografia tiene dos zonas, y son deliberadas:**

| Zona | Como se escribe |
|---|---|
| `README.md`, `packaging/`, `src/`, `rgb/`, `data/`, `nitro-gekko` | castellano **sin tildes y sin enye**: «aplicacion», «termico», «asi», «pestanas», «contrasena», y el si afirmativo tambien sin tilde |
| `extension/` (js, css, json y sus notas) | castellano **con todas las tildes y enyes** |

No es un descuido que arreglar: son 7000 lineas coherentes. Antes de escribir
una linea, mira en que zona estas. `packaging/nitro-gekko-helper` es ademas
**ASCII puro**: ni comillas angulares, ni raya larga, ni grados.

El resto de convenciones, tal como estan en el codigo:

- **Cabeceras de seccion** con una linea de guiones: 76 columnas en Python
  (`# ` + 74), 77 en Bash (`# ` + 75, y el titulo con dos espacios), 78 en
  JavaScript (`// ` + 75). Las sub-cabeceras dentro de una funcion son de una
  sola linea: `# -- grupo 3: potencia ------`. No es decoracion: es como se
  navegan ficheros de 1000 a 1600 lineas.
- **Prosa y comentarios cortados a mano en torno a 78 u 80 columnas.** Las
  tablas y los bloques de codigo se dejan correr.
- **Las constantes de modulo de Python se documentan con `#:`** antes de la
  definicion, no con un `#` normal.
- **Cifras con coma decimal y espacio antes de la unidad:** «41,9 W»,
  «13,75 %», «66 °C», «~2200 rpm».
- **Toda afirmacion tecnica va con su medida y con como se obtuvo.** «Es
  rapido» no vale; el patron es «Medido en este equipo (i7-13620H): ...» o
  «Comprobado dentro de gnome-shell 50.4: ...».
- **Se separa siempre lo medido aqui de lo heredado, y se dice lo que NO esta
  probado.**
- **El enfasis en el codigo es con MAYUSCULAS** dentro de la frase (NO, NUNCA,
  SOLO, SIEMPRE) y con el marcador `OJO:` para las trampas; en markdown, con
  **negrita**. No hay ni un `TODO`, ni un `FIXME`, ni un `HACK`: lo que falta se
  argumenta en prosa.
- **Los comentarios explican el fallo anterior**, en pasado y con el sintoma
  reproducido: «Antes...», «Una version anterior recibia...», «Reproducido:»,
  «Comprobado con xprop». **Esos parrafos son la documentacion real del
  proyecto**: borrar uno hace que el siguiente deshaga la correccion creyendo
  que simplifica.
- **Los mensajes al usuario dicen QUE falta, POR QUE y la ORDEN exacta que lo
  arregla.** Nunca «no disponible» a secas.
- **Sin emojis en ninguna parte**, y badges solo en el bloque HTML de cabecera
  de este README.
- **Los titulos de los `.md` van en minuscula tipo frase**, sin numerar y sin
  signos de interrogacion aunque sean preguntas.
- **En los mensajes de commit**, prefijo de conventional commits en el asunto y
  cuerpo largo en castellano, dividido en apartados subrayados con guiones.

Un detalle que despista: el codigo cita «gotcha 1», «gotcha 4», «gotcha 6» y
«gotcha 7». Son los cuatro numeros de [Cosas raras de este portatil que
conviene saber](#cosas-raras-de-este-portatil-que-conviene-saber), que es la
lista a la que se refieren.

### Que hay en el repositorio que no es nuestro

- **`rgb/src/linuwu_sense.c`** son 4620 lineas ajenas con **dos** cambios
  propios. Conserva su `SPDX-License-Identifier`, los avisos de copyright de sus
  autores y el aviso de modificacion que exige la seccion 5(a) de la GPL. Eso no
  es una cortesia: es la licencia.
- **`rgb/Makefile.upstream`** esta ahi solo como referencia y **no se ejecuta
  nunca**: su objetivo `install` pide un `linuwu_sense.service` que no existe en
  este arbol. El que se usa es `rgb/Makefile`.
- **`LICENSE`** es la GPL-3.0 completa. Ver
  [Licencia y creditos](#licencia-y-creditos).

### Que no se va a anadir, y por que

No es una lista de tareas pendientes. Es una lista de cosas decididas:

| | Por que no |
|---|---|
| Vatios de CPU en vivo | `energy_uj` esta cerrado por la mitigacion de PLATYPUS y no se va a abrir |
| Una pestana de audio, o «DTS» | DTS:X Ultra es un APO de Windows en modo usuario: no hay nada en firmware, ni en el EC, ni en WMI, ni en `linuwu_sense`. Duplicar un ecualizador seria un EasyEffects peor. Ver [El sonido](#el-sonido-el-dtsx-ultra-que-traia-windows) |
| Entradas DMI de modelos que nadie ha probado | convierte la tabla de compatibilidad en una promesa que el proyecto no puede sostener. Ver [Que se sabe de cada modelo](#que-se-sabe-de-cada-modelo) |
| Calibracion de bateria en la interfaz | horas de descarga y recarga; no puede estar a un clic |
| `--con-udev` por defecto | quita la validacion del helper y abre seis rutas a cualquier proceso del usuario |
| Un demonio D-Bus con polkit por metodo | anadiria un proceso privilegiado permanente para ganar granularidad que hoy no hace falta |
| Perfiles o efectos codificados a mano | se leen del kernel y del driver, que es lo que los hace correctos manana |

### Sobre este README y los ficheros que no se publican

Al repositorio publico sube **un solo documento: este**. Se quedan en la copia
local las notas largas de trabajo (`packaging/SEGURIDAD.md` y
`extension/README.md`), cuyo contenido imprescindible esta recogido arriba en
[Seguridad y permisos](#seguridad-y-permisos) y en [La extension de GNOME
Shell](#la-extension-de-gnome-shell), y el `AGENTS.md`, que es el contrato de
trabajo y la bitacora de hallazgos.

El `.gitignore` **tampoco se publica**, y eso tiene una consecuencia que
conviene saber: quien clone el repositorio no recibe ninguna de esas reglas,
asi que en su copia los `.md` locales, los `.ko` y los `__pycache__` vuelven a
aparecer como ficheros sin seguimiento. Si vuelves a anadir un documento
interno, comprueba que sigue fuera del indice:

```bash
git ls-files | grep '\.md$'      # tiene que decir solo: README.md
git status --short               # y no debe aparecer ningun .md nuevo
```

Y si escribes algo aqui que remita a un fichero local, dilo con esa palabra
—«en la copia local»— para que quien lo lea desde GitHub no busque un fichero
que no le ha llegado.

---

## Si algo no funciona

Antes de abrir nada, dos atajos que resuelven la mayoria de los casos:

- **Tu Acer no es un AN17-51:** [Anade tu modelo](#anade-tu-modelo). Casi todo
  se arregla forzando el quirk por parametro de modulo, sin recompilar.
- **Te has quedado sin perfiles ni ventiladores:** [El riesgo real de este paso,
  dicho claro](#el-riesgo-real-de-este-paso-dicho-claro). Son dos ordenes, y
  estan escritas dentro del propio `/etc/modprobe.d/nitro-gekko-rgb.conf`.

Si aun asi hace falta, las [plantillas de
incidencia](.github/ISSUE_TEMPLATE) piden de entrada lo que siempre hay que
preguntar: la salida de `./packaging/preparar-sistema.sh --revisar`, tu cadena
DMI, el kernel, la version de GNOME y `dkms status`. Con eso se puede empezar;
sin eso, no.

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
