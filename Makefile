obj-m += turing_write.o
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
	sudo insmod turing_write.ko
	dmesg | grep turing_write

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
