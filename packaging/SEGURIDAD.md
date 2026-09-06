# Seguridad de Nitro Gekko

Nitro Gekko necesita escribir en ficheros de `/sys` que son `0644 root:root`.
Eso es un problema de privilegios y hay exactamente dos maneras de resolverlo.
El proyecto trae las dos, y no son intercambiables.

| | Modo **polkit** (por defecto) | Modo **udev** (`--con-udev`) |
|---|---|---|
| Que instala | `nitro-gekko-helper` + una politica polkit | reglas udev + `tmpfiles.d` |
| Permisos de `/sys` | siguen `0644 root:root` | seis rutas pasan a `0664 root:wheel` |
| Quien puede escribir | solo root, previa autenticacion | **cualquier proceso** de un usuario de `wheel` |
| Contrasena | una vez, cacheada unos minutos | ninguna, nunca |
| Se instala con | `sudo ./packaging/install.sh` | `sudo ./packaging/install.sh --con-udev` |

**El modo por defecto es polkit.** Si ejecutas `install.sh` sin banderas no se
abre ni un permiso de `/sys`: se instala un programa auxiliar que corre como
root bajo demanda y una politica que dice quien puede invocarlo.

---

# Parte 1 — Modo polkit (el de por defecto)

## Como funciona

```
   aplicacion (uid 1000)                    root
   ─────────────────────                    ────
   sysfs.py::_escribir()
      │
      │  os.access(ruta, W_OK)?  ──── si ──►  escritura directa (modo udev)
      │  no
      ▼
   pkexec /usr/lib/nitro-gekko/nitro-gekko-helper <accion> <valor>
      │                                        │
      │   polkit: ¿org.thegekko.nitrogekko.aplicar?
      │   auth_admin_keep ► dialogo de GNOME   │
      │                                        ▼
      │                              valida el valor y escribe
      │                              en UNA ruta de su lista blanca
      ◄──────── codigo de salida ──────────────┘
```

Piezas:

- `packaging/nitro-gekko-helper` → `/usr/lib/nitro-gekko/nitro-gekko-helper`
  (`0755 root:root`).
- `packaging/org.thegekko.nitrogekko.policy` →
  `/usr/share/polkit-1/actions/` (`0644 root:root`), accion
  `org.thegekko.nitrogekko.aplicar`, `auth_admin_keep`.

**Quien invoca el helper son DOS piezas, no una.** Ademas de la aplicacion,
la extension de GNOME Shell (`extension/extension.js`) lanza el mismo
`pkexec --disable-internal-agent /usr/lib/nitro-gekko/nitro-gekko-helper perfil
<valor>` para los dos
perfiles que `power-profiles-daemon` no conoce (`quiet` y
`balanced-performance`); los otros tres los cambia por D-Bus, sin
contrasena. Eso no amplia la superficie: es el mismo ejecutable, la misma
accion polkit y la misma interfaz cerrada, y de las diez acciones la
extension solo usa `perfil`. Lo que si conviene tener presente es que la
cache de `auth_admin_keep` la comparten las dos: autorizar desde
Configuracion rapida deja tambien a la aplicacion sin dialogo durante esos
minutos. La extension no trae ningun ejecutable propio y no puede modificar
el helper, que es `root:root 0755` y lo pone el instalador del sistema.

## Lo que hace que esto sea seguro: el helper NO acepta rutas

Una version anterior recibia la ruta como argumento:

```
pkexec nitro-gekko-helper /sys/lo/que/sea  valor      # AGUJERO
```

Eso es escalada de privilegios de manual: con la autorizacion cacheada,
cualquier proceso del usuario (una pestana del navegador, un juego, un
`npm install`) podia hacer que root escribiera en cualquier fichero. Y el
usuario no podia saber que ruta se iba a tocar mirando el dialogo.

Hoy lo unico que cruza la frontera de privilegio son **dos cadenas**: un
nombre de accion de un conjunto cerrado de diez, y un valor. Las rutas son
constantes del propio fichero del helper.

| Accion | Ruta (constante en el helper) | Valores aceptados |
|---|---|---|
| `perfil` | `/sys/firmware/acpi/platform_profile` | uno de los que lista el kernel en `platform_profile_choices` |
| `pl1` | `intel-rapl:0` y `intel-rapl-mmio:0` `constraint_0_power_limit_uw` | entero decimal 10..65 (vatios) |
| `bateria` | `acer-wmi-battery/health_mode` | `0` o `1` |
| `turbo` | `intel_pstate/no_turbo` | `0` o `1` |
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
3. **La lista de perfiles se lee del kernel**, no de una constante: si manana
   el driver expone otros perfiles el helper sigue siendo correcto.
4. **No se lee ni una variable de entorno.** Un programa que corre como root y
   cambia de comportamiento segun el entorno solo es seguro mientras el
   lanzador limpie el entorno. pkexec lo limpia (conserva `SHELL`, `LANG`,
   `LANGUAGE`, `LC_*`, `DISPLAY` y `XAUTHORITY`, y fija
   `PATH=/usr/sbin:/usr/bin:/sbin:/bin`), pero eso es una propiedad del
   lanzador, no del helper.
5. **Interprete absoluto y aislado:** `#!/usr/bin/python3 -I`. No
   `/usr/bin/env python3`, que resolveria el interprete por `$PATH`; y `-I`
   (implica `-E -s -P`) ignora `PYTHONPATH`, `PYTHONHOME`, el
   `site-packages` del usuario y el directorio del script como `sys.path[0]`.
6. **`O_NOFOLLOW` y nunca `O_CREAT`.** El helper no puede crear un fichero
   nuevo en ninguna circunstancia, y no sigue un enlace simbolico en el ultimo
   componente. Se abre una vez y se comprueba el descriptor ya abierto
   (`fstat`), no la ruta: asi no hay ventana TOCTOU entre comprobar y escribir.

## Que se ha intentado romper, y que paso

Todo esto se ejecuta sin privilegio; el helper debe terminar con codigo 5
("no eres root") solo despues de haber aceptado el valor.

| Ataque | Ejemplo | Resultado |
|---|---|---|
| Ruta como valor | `perfil ../../../etc/shadow` | codigo 2, "perfil invalido" |
| Ruta absoluta | `pl1 /dev/sda` | codigo 2 |
| Inyeccion de shell | `pl1 '45; rm -rf /'`, `` pl1 '`id`' ``, `pl1 '$(id)'` | codigo 2. No hay shell en ningun punto: el helper no llama a `subprocess` ni a `os.system`, y la app lanza `pkexec` con una lista de argumentos, no con una cadena |
| Salto de linea en el valor | `pl1 $'45\n\nrm -rf'` | codigo 2 |
| Byte NUL | | imposible por construccion: `execve()` corta los argumentos en el primer NUL, no hay forma de que llegue uno |
| Numeros fuera de rango | `pl1 0`, `pl1 66`, `pl1 -45`, `pl1 9999999999999999999999` | codigo 2 |
| Otras bases | `pl1 0x2d`, `pl1 0o55`, `pl1 4.5e1`, `pl1 NaN`, `pl1 inf` | codigo 2 |
| Digitos que no son ASCII | `pl1 '٤٥'`, `pl1 '६५'`, `pl1 '４５'` | codigo 2 (ver abajo) |
| Espacios, signo, guion bajo | `pl1 ' 45 '`, `pl1 '+45'`, `pl1 '4_5'` | codigo 2 (ver abajo) |
| Campos de mas o de menos | `rgb_efecto '3,5,80,1,255,0,0,0'`, `rgb_zonas 'a,b,c,d,80,90'` | codigo 2 |
| Longitud | 63 y 64 caracteres se examinan; 65 se rechaza antes de mirarlos | codigo 2, "valor demasiado largo" |
| Argumentos | 0, 1 o 3 argumentos; accion vacia; `PERFIL` en mayusculas; `' perfil'` | codigo 1 |
| Enlace simbolico en `/sys` | `ln -s /etc/shadow /sys/firmware/acpi/x` | `EPERM`. sysfs no deja crear entradas **ni a root**, y los directorios son `0755 root:root` |
| TOCTOU | | no hay ventana: las rutas son constantes del fichero y se abre una sola vez, comprobando el descriptor con `fstat` en vez de la ruta |
| Secuencias ANSI en los mensajes de error | `rgb_zonas $'\e[31mXX,...'` | se imprimen con `repr()`, que las escapa: `'\x1b[31mXX'` |

Sobre los digitos no ASCII y los espacios: `int()` de Python es mucho mas
permisivo de lo que parece. `int('٤٥')` vale 45 (digitos arabigo-indices),
`int('４５')` vale 45 (anchura completa), `int('4_5')` vale 45 e `int(' 45\n')`
vale 45. Ninguno era explotable, porque el valor que se escribia se
reconstruia a partir del entero y nunca era el texto original; pero una
interfaz privilegiada que acepta mas de lo que documenta es una interfaz que
nadie puede auditar leyendo su documentacion. El helper usa ahora un parser
estricto: `[-]?[0-9]+` en ASCII y nada mas.

## Que NO cubre este modo

- **El dialogo es de grano grueso.** Una accion polkit se resuelve por
  ejecutable, asi que hay una sola: quien autoriza "cambiar el perfil" esta
  autorizando, mientras dure la cache de `auth_admin_keep`, cualquiera de las
  diez acciones. Por eso el `<message>` de la politica enumera el alcance
  entero y no solo lo que el usuario acaba de tocar. La alternativa (varios
  binarios helper diminutos, uno por accion, como hace gamemode con
  `cpugovctl`, `gpuclockctl`, `cpucorectl` y `procsysctl`) daria granularidad
  real, pero aqui las diez acciones son la misma aplicacion y el mismo
  usuario: separarlas no cambiaria quien puede hacer que.
- **La cache de `auth_admin_keep` es una ventana.** Durante esos minutos, otro
  proceso del mismo usuario que invoque el mismo helper no vera el dialogo.
  Lo que puede hacer con eso esta acotado por la tabla de acciones de arriba:
  ruido, rendimiento y desgaste de bateria. No hay ninguna accion que de una
  shell, escriba en un fichero arbitrario ni lea nada confidencial.
- **Si la politica no llega a `/usr/share/polkit-1/actions`** (por ejemplo con
  un `PREFIX` raro), polkit no conoce la accion y pkexec cae en
  `org.freedesktop.policykit.exec`, que es `auth_admin` sin cache: contrasena
  en cada cambio. `install.sh` avisa de esto y sustituye la ruta del helper en
  la anotacion `exec.path` segun el `PREFIX` real.

## Por que `auth_admin_keep`

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

## Sobre el rango del PL1 (10..65 W)

El helper no acepta un PL1 fuera de 10..65 vatios.

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
PROCHOT/TCC ni el control de ventiladores del EC, asi que el techo fisico lo
sigue poniendo el silicio. Subirlo cuesta calor, ruido y bateria, no dano.

**Ojo con `constraint_0_max_power_uw`.** Vale 45 W aqui y es la potencia base
que Intel declara para el chip, **no** un tope que el kernel imponga: la
prueba es que el MMIO esta ahora mismo en 70 W, por encima de su propio
"maximo". Se lee a titulo informativo (la aplicacion lo ensena como "nominal
declarado") pero no se usa como limite, porque si se usara el helper
prohibiria justo los 65 W con los que la maquina arranca de fabrica.

**El minimo es el que de verdad protege.** El abuso realista del PL1 no es
subirlo, es **bajarlo**: dejarlo en 5 W hace la maquina inservible y el
sintoma ("esto va lentisimo desde hace dias") no apunta a ninguna causa.

## Fugas de informacion en los mensajes de error

No hay. Los mensajes solo contienen: rutas que son constantes publicas del
propio fichero (y ya visibles en este documento), `errno.strerror` del kernel,
la lista de perfiles que el kernel publica en un fichero legible por todo el
mundo, y el valor que el atacante acaba de enviar, siempre con `repr()`. No se
imprime `argv[0]`, ni el entorno, ni el uid, ni ninguna traza de Python: el
helper no deja escapar excepciones.

---

# Parte 2 — Modo udev (`--con-udev`)

Este modo **no se instala si no lo pides**. Existe porque el dialogo de
contrasena, aunque sea una vez cada varios minutos, molesta. Lee esto antes.

## Que se abre exactamente

`packaging/99-nitro-gekko.rules` (4 rutas) y `packaging/nitro-gekko.conf`
(las otras 2, mas red de seguridad para el resto) cambian **seis** ficheros de
`0644 root:root` a `0664 root:wheel`. Nada mas.

| Ruta | Que controla | Lo pone |
|---|---|---|
| `/sys/firmware/acpi/platform_profile` | perfil termico (interfaz legacy, la que notifica) | tmpfiles |
| `/sys/class/platform-profile/platform-profile-0/profile` | el mismo perfil, interfaz nueva | udev + tmpfiles |
| `intel-rapl:0/constraint_0_power_limit_uw` | PL1 por MSR | udev + tmpfiles |
| `intel-rapl-mmio:0/constraint_0_power_limit_uw` | PL1 por MMIO | udev + tmpfiles |
| `acer-wmi-battery/health_mode` | limite de carga de bateria (100 % / 80 %) | udev + tmpfiles |
| `intel_pstate/no_turbo` | turbo de CPU | tmpfiles |

No se abre **ninguna lectura nueva**: los seis ya eran legibles por todo el
mundo. Lo unico que cambia es quien puede **escribir**.

No se toca `constraint_1` (PL2), ni `constraint_2` (peak power), ni ningun
`enabled`, ni nada fuera de esa lista.

**Las rutas del teclado y del EC NO estan aqui.** `four_zone_mode`,
`per_zone_mode`, `backlight_timeout`, `usb_charging`, `battery_calibration` y
`boot_animation_sound` siguen siendo `0644 root:root` incluso con
`--con-udev`, asi que esas seis acciones **siguen pasando por pkexec** y
siguen pidiendo contrasena. Es deliberado: `battery_calibration` arranca un
ciclo completo de descarga y carga de la bateria, y no debe poder dispararlo
un proceso cualquiera sin autenticarse.

## Por que el grupo `wheel`, y cual es el precio

En esta maquina `wheel` ya es "la gente que manda": el usuario esta en `wheel`
y `wheel` tiene `sudo`. De ahi sale el argumento a favor, que es real pero
**parcial**:

> La PERSONA no gana ninguna capacidad nueva. Ya podia escribir esos seis
> ficheros con `sudo tee`. Esto solo le ahorra teclear la contrasena.

Y de ahi el argumento en contra, que es el que importa:

> Los PROCESOS que corren como esa persona SI ganan capacidad nueva.

Antes, escribir en `platform_profile` exigia pasar por `sudo` o por el dialogo
de polkit: una contrasena, una entrada en el journal, un momento en el que la
persona decide. Con las reglas puestas, cualquier cosa que se ejecute con tu
uid — el navegador, una extension del navegador, un juego de Steam, un
`npm install`, un script copiado de un foro — escribe en esos seis ficheros
**en silencio, sin contrasena y sin dejar rastro evidente**.

Ese es el precio. No es cero. Es pequeno, pero no es cero. Y es exactamente lo
que el modo por defecto evita.

## Riesgo concreto de cada ruta

Ninguna de las seis da root, ni lee datos de nadie, ni afecta a otros
usuarios. El dano posible es "molestia y desgaste", y todo es reversible
escribiendo el valor bueno o reiniciando. Pero conviene saber cual es:

**`platform_profile` (las dos rutas).** Un proceso puede poner el portatil en
`performance`. Medido en este equipo: los ventiladores pasan de ~1661 RPM en
`quiet` a ~3237 RPM en `performance`, o sea el doble de ruido, y la
temperatura baja apenas 1 °C. Puede dejarte el portatil soplando a tope de
forma permanente y, como el valor lo relee todo el sistema, parecera que lo
has puesto tu.
Hay un segundo efecto, mas sutil: escribir `balanced-performance` hace que
`power-profiles-daemon` caiga en `g_return_val_if_reached()` y deje su
`ActiveProfile` en `UNSET` (su tabla interna compara con guion bajo,
`balanced_performance`). Resultado visible: **el menu de energia de GNOME se
queda en blanco**. Cualquier proceso con acceso de escritura puede provocarlo
a proposito.

**PL1 (`constraint_0_power_limit_uw`, MSR y MMIO).** Un proceso puede mover el
limite de potencia sostenida de la CPU. Hacia arriba no hay dano posible (ver
el apartado del rango del PL1 en la parte 1: el firmware ya va mas alto por su
cuenta), pero **si desaparece la validacion del helper**: en este modo se
escribe directamente en sysfs y nadie comprueba el rango 10..65 W. El abuso
realista es el contrario: **bajarlo**. Poner PL1 a 5 W deja la maquina
inservible y, como no hay ningun aviso, el sintoma es "esto va lentisimo desde
hace dias" sin causa aparente.

**`health_mode` (limite de carga).** Poner `0` desactiva en silencio el limite
al 80 % que tenias puesto para cuidar la bateria: no lo notas hasta que meses
despues la bateria esta mas gastada de lo que esperabas. Poner `1` te deja al
80 % justo el dia que necesitabas salir con carga completa. Es el que menos
ruido hace y el que mas tarda en verse.

**`no_turbo`.** Un proceso escribe `1` y desactiva el turbo. Perdida de
rendimiento sostenida y silenciosa. Es el menos grave de los seis.

**Techo de riesgo:** ruido, rendimiento y desgaste de bateria. No hay escalada
a root, no hay fuga de informacion, no hay persistencia.

## Sobre las reglas udev en si

`packaging/99-nitro-gekko.rules` esta en el repositorio **aunque no se instale
por defecto**. Notas para quien lo lea o lo edite:

- Pasa `udevadm verify` sin fallos (`install.sh` lo comprueba antes de
  copiarlo).
- Usa `RUN+="/usr/bin/chgrp ..."` y no `MODE=`/`GROUP=`, porque esas claves se
  aplican al nodo de `/dev` y estos dispositivos no tienen nodo: poner
  `MODE="0664"` seria una instruccion silenciosamente inutil.
- `RUN+=` se ejecuta con `execve()`, sin shell: no hay expansion, ni tuberias,
  ni `;`. Todos los binarios van con ruta absoluta porque udev no exporta
  `PATH`.
- Dentro de un valor de udev, `$` introduce una sustitucion de udev: una
  variable de shell `$p` hace que udev **rechace la regla entera**. Por eso
  las rutas van repetidas enteras en vez de usar variables.
- No hay ninguna ruta construida a partir de datos del dispositivo salvo `%k`
  en la regla del perfil, y ahi `%k` es el nombre del kernel del propio
  dispositivo que ya ha casado `SUBSYSTEM=="platform-profile"` y
  `ATTR{name}=="acer-wmi"`.

El riesgo de estas reglas no esta en como estan escritas, esta en **lo que
hacen a proposito**: relajar permisos. Eso es la parte 2 entera de este
documento.

---

# Por que NO se abre `energy_uj`, en ningun modo

`/sys/class/powercap/intel-rapl:0/energy_uj` esta en `0400 root` y **se queda
como esta**. No aparece en las reglas, ni en el `tmpfiles.d`, ni en la lista
blanca del helper, y no debe aparecer nunca.

El motivo es **PLATYPUS (CVE-2020-8694)**. Los contadores de energia de RAPL
tienen resolucion suficiente para que un proceso sin privilegios que los lea
en bucle deduzca **que esta ejecutando el resto del sistema** correlacionando
el consumo con el codigo: se demostro recuperar claves AES-NI y secretos de un
enclave SGX asi. La respuesta del kernel fue justamente quitar la lectura a
los usuarios normales.

Esa diferencia es la clave de todo este documento:

- Las seis rutas de la parte 2 son de **escritura molesta**: un atacante hace
  ruido.
- `energy_uj` es de **lectura confidencial**: un atacante se lleva secretos.

Abrir lo primero es una decision discutible con la que se puede vivir. Abrir
lo segundo seria deshacer una mitigacion del kernel para pintar un numero
bonito.

Consecuencia practica y honesta: **Nitro Gekko no muestra vatios de CPU.** No
es un olvido ni una funcion pendiente. No hay dato porque no se va a leer.

---

# La alternativa que sigue sin estar: un demonio D-Bus

Lo correcto de manual, por encima incluso del helper por pkexec, seria un
**demonio de sistema con polkit por metodo**: un servicio corriendo como root
que exponga `SetPerfil`, `SetPL1`, `SetHealthMode`... cada uno con su accion
polkit (`org.thegekko.nitrogekko.set-perfil`, etc.).

Que ganaria sobre el modo polkit actual:

- Autorizacion **por operacion**: permitir cambiar el perfil sin preguntar y
  exigir contrasena para el PL1, por ejemplo.
- Un unico sitio donde registrar quien pidio que.

Que **no** ganaria, y conviene decirlo porque suele darse por hecho:

- Los ficheros de `/sys` ya son `0644 root:root` en el modo por defecto. Eso
  ya lo tenemos.
- La validacion de los valores ya existe y ya corre como root. Eso ya lo
  tenemos.

Y que costaria:

1. Es practicamente duplicar el proyecto: demonio, servicio D-Bus, politica,
   unidad de systemd y toda la capa de IPC en la aplicacion.
2. Anade un **proceso privilegiado permanente**, que es superficie de ataque
   nueva y de la peor clase: siempre encendido, siempre escuchando. El helper
   por pkexec, en cambio, existe solo durante los milisegundos que tarda en
   escribir en un fichero, y muere.

Es un cambio de riesgo consciente, no un descuido. **Si esta maquina pasara a
tener varios usuarios con permisos distintos, la accion polkit unica deja de
valer y hay que trocearla** (varios helpers a lo gamemode, o el demonio). El
cambio esta acotado: todas las escrituras de la aplicacion pasan por un unico
metodo, `_escribir()` en `src/gekkonitro/sysfs.py`.

---

# Como comprobar en que modo estas, y como deshacerlo

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

Deshacerlo todo:

```bash
sudo ./packaging/install.sh --uninstall
```

Borra el helper, la politica polkit, las reglas udev y el `tmpfiles.d`, y
ademas devuelve las seis rutas a `0644 root:root` en caliente. Si prefieres
quitar solo el modo udev y quedarte con polkit, basta con borrar
`/usr/lib/udev/rules.d/99-nitro-gekko.rules` y
`/usr/lib/tmpfiles.d/nitro-gekko.conf` y reiniciar: al arrancar, los permisos
vuelven a ser los del kernel.
