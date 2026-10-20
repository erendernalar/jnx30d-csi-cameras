# Out-of-tree build of the patched NVIDIA nv_ov9281 driver for L4T R35.6.x
# (kernel 5.10.216-tegra). Build ON THE JETSON against the installed
# nvidia-l4t-kernel-headers package — not Ubuntu generic headers.
#
#   make                 # build nv_ov9281.ko
#   make check           # print vermagic of built module vs running kernel
#
# KDIR    : kernel build dir   (default: running kernel's headers)
# NVSRC   : NVIDIA overlay tree containing include/media/camera_common.h

obj-m := nv_ov9281.o

KDIR  ?= /lib/modules/$(shell uname -r)/build
NVSRC ?= $(shell readlink -f $(KDIR))/../nvidia

ccflags-y += -I$(NVSRC)/include -I$(src)

all:
	@test -f $(NVSRC)/include/media/camera_common.h || \
	  { echo "ERROR: $(NVSRC)/include/media/camera_common.h not found."; \
	    echo "Install nvidia-l4t-kernel-headers or pass NVSRC=<path>"; exit 1; }
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

check:
	@echo "running : $$(uname -r)"
	@modinfo -F vermagic ./nv_ov9281.ko
	@modinfo -F depends ./nv_ov9281.ko

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
