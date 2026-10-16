# SPDX-License-Identifier: GPL-2.0+
#
# Outer Makefile for the DKMS package amd-isp4-capture.
#
# This file only calls kbuild; the module itself is described by ./Kbuild
# (which kbuild reads instead of this file) and driver/Kbuild.
#
# Manual build (nothing is installed):
#   make -C dkms                                  # running kernel
#   make -C dkms KDIR=/path/to/kernel/build       # another kernel
#   make -C dkms KDIR=... clean
# DKMS calls it from its build directory as   make KDIR=${kernel_source_dir} modules
# (see dkms.conf).
#
# Toolchain: a module must be built with the same compiler family as the
# kernel.  If $(KDIR)/.config has CONFIG_CC_IS_CLANG=y (clang, possibly with
# ThinLTO, like CachyOS kernels), LLVM=1 is passed; for a gcc-built kernel it
# is not.  An explicit "make LLVM=1" or "make LLVM=" on the command line wins.
#
# Note: do not test KERNELRELEASE here to detect "called by kbuild": DKMS
# passes KERNELRELEASE=<kernel version> on the command line of this outer make.

KVER ?= $(if $(KERNELRELEASE),$(KERNELRELEASE),$(shell uname -r))
KDIR ?= /lib/modules/$(KVER)/build

# This directory (the M= directory), independent of how make was started.
PKGDIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

KCONFIG := $(KDIR)/.config
ifeq ($(origin LLVM),undefined)
LLVM := $(if $(shell grep -s '^CONFIG_CC_IS_CLANG=y' $(KCONFIG)),1,)
endif
KBUILD_LLVM := $(if $(LLVM),LLVM=$(LLVM),)

.PHONY: all modules clean check-headers

all: modules

modules: check-headers
	$(MAKE) -C $(KDIR) M=$(PKGDIR) $(KBUILD_LLVM) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PKGDIR) $(KBUILD_LLVM) clean

# Same checks DKMS runs as PRE_BUILD, so a manual build fails the same way.
check-headers:
	sh $(PKGDIR)/check-generated-headers.sh $(KDIR)
