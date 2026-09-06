# Makefile minimo para DKMS. El del upstream trae bloques de firma de modulo y
# de instalacion manual que aqui estorban: DKMS ya se encarga de ambas cosas.
obj-m := src/linuwu_sense.o

KVER ?= $(shell uname -r)
KDIR := /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
