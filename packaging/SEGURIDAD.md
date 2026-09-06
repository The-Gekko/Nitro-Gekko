# Seguridad: por que Nitro Gekko abre seis ficheros de /sys al grupo `wheel`

Este documento explica la unica decision incomoda del proyecto. Leelo antes de
ejecutar `install.sh`. No hay letra pequena.

---

## Que se abre exactamente

`packaging/99-nitro-gekko.rules` y `packaging/nitro-gekko.conf` cambian seis
ficheros de `0644 root:root` a **`0664 root:wheel`**. Nada mas.

| Ruta | Que controla |
|---|---|
| `/sys/firmware/acpi/platform_profile` | perfil termico (interfaz legacy, la que notifica) |
| `/sys/class/platform-profile/platform-profile-0/profile` | el mismo perfil, interfaz nueva |
| `/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw` | PL1 por MSR |
| `/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw` | PL1 por MMIO |
| `/sys/bus/wmi/drivers/acer-wmi-battery/health_mode` | limite de carga de bateria (100% / 80%) |
| `/sys/devices/system/cpu/intel_pstate/no_turbo` | turbo de CPU |

No se abre **ninguna lectura nueva**: los seis ya eran legibles por todo el
mundo. Lo unico que cambia es quien puede **escribir**.

No se toca `constraint_1` (PL2), ni `constraint_2` (peak power), ni ningun
`enabled`, ni nada fuera de esa lista.

---

## Por que el grupo `wheel`

Porque en esta maquina `wheel` ya es, de hecho, "la gente que manda":
el usuario `the-gekko` esta en `wheel` y `wheel` tiene `sudo`.

De ahi sale el argumento a favor, que es real pero **parcial**:

> La PERSONA no gana ninguna capacidad nueva. Ya podia escribir esos seis
> ficheros con `sudo tee`. Esto solo le ahorra teclear la contrasena.

Y de ahi sale el argumento en contra, que es el que importa:

> Los PROCESOS que corren como esa persona SI ganan capacidad nueva.

Esa es la diferencia y conviene tenerla clara. Antes, escribir en
`platform_profile` exigia pasar por `sudo`: una contrasena, un registro en el
journal, un momento en el que la persona decide. Despues de instalar esto,
cualquier cosa que se ejecute con tu uid — el navegador, una extension del
navegador, un juego de Steam, un `npm install`, un script que copies de un
foro — puede escribir en esos seis ficheros **en silencio, sin contrasena y sin
dejar rastro evidente**.

Ese es el precio. No es cero. Es pequeno, pero no es cero.

---

## Riesgo concreto de cada ruta

Ninguna de las seis da root, ni lee datos de nadie, ni afecta a otros usuarios.
El dano posible es de tipo "molestia y desgaste", y todo es reversible
escribiendo el valor bueno o reiniciando. Pero conviene saber cual es:

**`platform_profile` (las dos rutas)**
Un proceso puede poner el portatil en `performance`. Medido en este equipo:
los ventiladores pasan de ~1661 RPM en `quiet` a ~3237 RPM en `performance`,
o sea el doble de ruido, y la temperatura baja apenas 1 °C. Un proceso
malicioso o simplemente mal escrito puede dejarte el portatil soplando a tope
de forma permanente, y como el valor lo relee todo el sistema parecera que lo
has puesto tu.
Hay un segundo efecto, mas sutil: escribir `balanced-performance` hace que
`power-profiles-daemon` 0.30 caiga en `g_return_val_if_reached()` y deje su
`ActiveProfile` en `UNSET` (su tabla interna compara con guion bajo,
`balanced_performance`). Resultado visible: **el menu de energia de GNOME se
queda en blanco**. Cualquier proceso con acceso de escritura puede provocar eso
a proposito.

**PL1 (`constraint_0_power_limit_uw`, MSR y MMIO)**
Un proceso puede mover el limite de potencia sostenida de la CPU dentro de lo
que permita el firmware. Hacia arriba esta acotado: el maximo declarado es
`constraint_0_max_power_uw = 45000000` (45 W) y el firmware/EC recorta lo que
se salga; medido, con MSR a 45 W el equipo sostiene 41,9 W a 66 °C. No se puede
"quemar" el portatil desde aqui.
El abuso realista es el contrario: **bajarlo**. Poner PL1 a 5 W deja la maquina
inservible y, como no hay ningun aviso, el sintoma es "esto va lentisimo desde
hace dias" sin causa aparente.

**`health_mode` (limite de carga)**
Un proceso puede cambiar el limite de carga de la bateria. Poner `0` desactiva
en silencio el limite al 80% que tenias puesto para cuidar la bateria: no lo
notas hasta que meses despues la bateria esta mas gastada de lo que esperabas.
Poner `1` te deja al 80% justo el dia que necesitabas salir con carga completa.
Es el que menos ruido hace y el que mas tarda en verse.

**`no_turbo`**
Un proceso puede escribir `1` y desactivar el turbo. Perdida de rendimiento
sostenida y silenciosa. Es el menos grave de los seis.

**Resumen del techo de riesgo:** ruido, rendimiento y desgaste de bateria.
No hay escalada a root, no hay fuga de informacion, no hay persistencia.

---

## Por que NO se abre `energy_uj`

`/sys/class/powercap/intel-rapl:0/energy_uj` esta en `0400 root` y **se queda
como esta**. No aparece en las reglas ni en el `tmpfiles.d`, y no debe
aparecer nunca.

El motivo es **PLATYPUS (CVE-2020-8694)**. Los contadores de energia de RAPL
tienen resolucion suficiente para que un proceso sin privilegios que los lea en
bucle deduzca **que esta ejecutando el resto del sistema** correlacionando el
consumo con el codigo: se demostro recuperar claves AES-NI y secretos de un
enclave SGX asi. La respuesta del kernel fue justamente quitar la lectura a los
usuarios normales.

Esa diferencia es la clave de todo este documento:

- Las seis rutas de arriba son de **escritura molesta**: un atacante hace ruido.
- `energy_uj` es de **lectura confidencial**: un atacante se lleva secretos.

Abrir lo primero es una decision discutible con la que se puede vivir. Abrir lo
segundo seria deshacer una mitigacion de seguridad del kernel para pintar un
numero bonito.

Consecuencia practica y honesta: **Nitro Gekko no muestra vatios de CPU.**
No es un olvido ni una funcion pendiente. No hay dato porque no se va a leer.

---

## La alternativa mas segura, y por que no esta en esta version

Lo correcto de manual seria un **demonio D-Bus de sistema con polkit por
accion**: un servicio corriendo como root que exponga
`SetPerfil`, `SetPL1`, `SetHealthMode` y `SetTurbo`, cada uno con su accion
polkit (`org.thegekko.nitrogekko.set-perfil`, etc.), y la aplicacion hablando
por D-Bus en vez de escribir en `/sys`.

Eso resuelve de verdad el problema de arriba:

- Los ficheros de `/sys` siguen siendo `0644 root:root`. Un proceso cualquiera
  con tu uid **no puede** tocarlos.
- polkit decide **por accion** quien puede hacer que: se puede permitir cambiar
  el perfil sin preguntar y exigir contrasena para cambiar PL1, por ejemplo.
- Queda registro de quien pidio que.
- El demonio valida los valores antes de escribirlos, asi que no se puede
  colar un PL1 de 1 W por accidente.

**Por que no esta en esta version:**

1. Es practicamente duplicar el proyecto. Hace falta el demonio, el fichero de
   servicio D-Bus, la politica polkit, la unidad de systemd y toda la capa de
   IPC en la aplicacion. Es mas codigo que la aplicacion entera.
2. Anade un **proceso privilegiado permanente**, que es superficie de ataque
   nueva: si el demonio valida mal una entrada, el fallo esta en algo que corre
   como root. El enfoque de udev + tmpfiles no deja ningun proceso corriendo:
   son dos ficheros de texto y cero codigo en ejecucion.
3. El escenario para el que polkit brilla — varios usuarios, alguno sin
   privilegios, en la misma maquina — aqui no existe: es un portatil personal
   con un unico usuario que ya esta en `wheel` y ya tiene `sudo`.

Es un cambio de riesgo consciente, no un descuido. **Si esta maquina pasara a
tener mas de un usuario, o un usuario sin `sudo`, esta decision deja de valer y
hay que hacer el demonio.** El cambio esta acotado: todas las escrituras de la
aplicacion pasan por un unico metodo, `_escribir()` en
`src/gekkonitro/sysfs.py`, asi que cambiar el backend es tocar un fichero.

---

## Como deshacerlo

```bash
sudo ./packaging/install.sh --uninstall
```

Borra las reglas y el `tmpfiles.d`, y ademas devuelve las seis rutas a
`0644 root:root` en caliente. Si prefieres hacerlo a mano, basta con borrar
`/usr/lib/udev/rules.d/99-nitro-gekko.rules` y
`/usr/lib/tmpfiles.d/nitro-gekko.conf` y reiniciar: al arrancar, los permisos
vuelven a ser los del kernel.

Para comprobar en cualquier momento que hay abierto:

```bash
ls -l /sys/firmware/acpi/platform_profile \
      /sys/class/platform-profile/platform-profile-0/profile \
      /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw \
      /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw \
      /sys/bus/wmi/drivers/acer-wmi-battery/health_mode \
      /sys/devices/system/cpu/intel_pstate/no_turbo
```

Todo lo que salga como `rw-rw-r-- root wheel` lo ha puesto esto. Cualquier otra
cosa de `/sys` con permisos raros **no es de Nitro Gekko**.
