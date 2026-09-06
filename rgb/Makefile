# Makefile minimo para DKMS. El del upstream (conservado en Makefile.upstream)
# trae bloques de firma de modulo y de instalacion manual que aqui estorban:
# DKMS ya se encarga de ambas cosas.
obj-m := src/linuwu_sense.o

KVER ?= $(shell uname -r)
KDIR := /lib/modules/$(KVER)/build

# kbuild NO admite espacios en la ruta que se le pasa por M=: su propio
# Makefile parte la variable por espacios y se queda con el primer trozo. El
# sintoma es un error que despista mucho:
#     *** specified external module directory "/home/…/Proyecto" does not exist
# Es una limitacion de kbuild, no algo que se pueda arreglar con comillas.
# DKMS no la sufre porque compila desde /usr/src/linuwu-sense-<version>.
# $(words) parte por espacios en blanco: una ruta limpia es UNA sola palabra.
ifneq ($(words $(CURDIR)),1)
  $(error La ruta '$(CURDIR)' tiene espacios y kbuild no los admite. \
    Compila con DKMS (sudo ../packaging/instalar-rgb.sh) o copia rgb/ a una \
    ruta sin espacios: cp -a . /tmp/rgb && make -C /tmp/rgb)
endif

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
