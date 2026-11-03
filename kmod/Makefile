# SPDX-License-Identifier: GPL-2.0-or-later
.PHONY: all clean mod endian-check

obj-m += cetrafs.o
cetrafs-objs := kmod.o fs.o caw.o dmpath.o nslock.o defrag.o ioutil.o inode.o dir.o file.o xattr.o alloc.o super_ops.o uuid.o node.o zonegroup.o lock.o heartbeat.o journal.o procfs.o scrub.o
ccflags-y := -I$(src)/../include

# A warning is a build failure. This is a filesystem: the warnings that
# matter here are the quiet ones -- -Wframe-larger-than caught v0x0005
# putting a 1 KiB record on 49 call frames (see the trailing-pad note in
# cetrafs.h), which no test would ever have failed on. Escape hatch for
# bisecting an unrelated kernel/compiler combination only:
#   make mod CETRAFS_NO_WERROR=1
ifeq ($(CETRAFS_NO_WERROR),)
ccflags-y += -Werror
endif

# Pin the stack-frame budget instead of inheriting CONFIG_FRAME_WARN,
# which DIFFERS BETWEEN KERNELS and made this project's own dev machine
# blind: Debian's arm64 kernel sets 2048, Proxmox's amd64 kernel sets
# 1024. A 1384-byte frame in cetrafs_lock_open() (two cetrafs_inode_t on
# one frame, 652 bytes each) therefore built clean here and failed the
# deployment build outright -- the first anyone knew of it was the
# operator's compiler.
#
# 1024 is the stricter of the two, so building here now proves the build
# everywhere. It is also the right number on its own terms: the kernel
# stack is 16 KiB and cetrafs sits above dm-multipath, SCSI and the
# IOMMU. See the trailing-pad note in cetrafs.h for what a record on the
# stack costs.
ccflags-y += -Wframe-larger-than=1024

# KASAN inflates EVERY frame: its redzones sit between the locals, so a
# function that measures 900 bytes in production measures ~1300 under
# it. The pin above would reject a kernel it was never written to
# describe -- five dir.c functions fail a KASAN build while being well
# inside budget in the build that ships.
#
# So raise it for that build only:
#   make mod KASAN=1
# It does not relax anything for an ordinary build, and it is not a
# licence to grow frames: a KASAN build that fails even at 2048 is
# telling you something real (cetrafs_dm_collect(), which RECURSES four
# deep, and cetrafs_defrag_inode()'s 652-byte record were both found
# exactly this way).
ifeq ($(KASAN),1)
ccflags-y += -Wframe-larger-than=2048
endif

# Building with clang: `make mod LLVM=1`.
#
# Every source here compiles clean under clang 19 (zero diagnostics on
# cetrafs code), but only once three things the KERNEL puts on the
# command line are dealt with. They are there because the kernel this
# builds against was configured for GCC -- a kernel configured for clang
# never emits them:
#
#   -fconserve-stack, -fmin-function-alignment=  GCC-only, clang errors
#   -fsanitize=bounds-strict                     GCC's UBSAN spelling
#   -Wimplicit-fallthrough=5 and friends         GCC-only -W spellings
#
# The first two come out with ccflags-remove-y; the UBSAN one cannot
# (kbuild appends sanitiser flags AFTER that filter), so UBSAN is off
# for this module under clang -- KASAN, which is the one we want, stays
# on. The -W spellings are silenced rather than removed, since the list
# grows with every kernel.
#
# KNOWN LIMIT, so nobody rediscovers it: this gets every object built
# and linked, then fails on cetrafs.mod.o -- the stub kbuild generates
# itself, compiled by scripts/Makefile.modfinal with the kernel's own
# flags and out of reach of any per-module knob. A LOADABLE clang module
# needs a kernel built with clang (CONFIG_CC_IS_CLANG=y). What this
# target buys today is clang's diagnostics over the whole source, which
# is most of the value.
ifeq ($(LLVM),1)
ccflags-remove-y += -fconserve-stack -fmin-function-alignment=8
UBSAN_SANITIZE := n
ccflags-y += -Wno-unknown-warning-option -Wno-microsoft-anon-tag -Wno-address-of-packed-member
endif

# Trace instrumentation (see kmod.h's ctrace): OFF unless asked for.
#   make mod CETRAFS_TRACE=1
ifneq ($(CETRAFS_TRACE),)
ccflags-y += -DCETRAFS_TRACE
endif

# Build stamp: the git version of the source this .ko was built from, so a
# split-build cluster (nodes accidentally running different modules) is
# visible -- it is printed at load and exposed as MODULE_VERSION
# (/sys/module/cetrafs/version, `modinfo cetrafs.ko`). `git describe` gives
# the tag + commits-since + short hash (e.g. 0.7-2-g1a2b3c4), "-dirty" when
# the tree has uncommitted changes, the bare short hash when no tag is
# reachable, or "unknown" outside a git tree (a tarball build). $(src) is
# the module source dir under kbuild; $(CURDIR) covers the first pass.
#
# "-dirty" alone is identical across different uncommitted edits, so a WIP
# build cannot be told from the one before it in the field. When the tree is
# dirty, append a short hash of the committed-to-worktree diff: each distinct
# set of uncommitted changes then gets its own stamp, which is what makes
# "did my rebuild actually reach every node?" answerable from dmesg/modinfo.
CETRAFS_SRCDIR := $(if $(src),$(src),$(CURDIR))
CETRAFS_GIT_DESC := $(shell git -C $(CETRAFS_SRCDIR) describe --tags --always --dirty 2>/dev/null || echo unknown)
CETRAFS_DIRTY_HASH := $(if $(findstring -dirty,$(CETRAFS_GIT_DESC)),.$(shell git -C $(CETRAFS_SRCDIR) diff HEAD 2>/dev/null | sha1sum | cut -c1-8),)
# What a multi-node test must compare is the SOURCE, not the binary: two
# hypervisors on different kernel builds need two .ko files, which can
# never share an ELF build-id, and the git stamp above only describes the
# source when the building tree's git is current. So the stamp ends in a
# hash of the bytes compiled: every module .c/.h, the on-disk format
# header and this Makefile (its flags change code). modpost's
# generated *.mod.c is per-kernel and left out. ctest's build gate keys
# on this "+src." suffix (ctest/scenarios.go, moduleSourceID()).
CETRAFS_SRC_HASH := $(shell cd $(CETRAFS_SRCDIR) && cat $$(ls *.c *.h Makefile | grep -v '\.mod\.c$$' | LC_ALL=C sort) ../include/cetrafs.h 2>/dev/null | sha1sum | cut -c1-12)
CETRAFS_BUILD_VERSION := $(CETRAFS_GIT_DESC)$(CETRAFS_DIRTY_HASH)+src.$(CETRAFS_SRC_HASH)
ccflags-y += -DCETRAFS_BUILD_VERSION=\"$(CETRAFS_BUILD_VERSION)\"

KDIR ?= /lib/modules/$(shell uname -r)/build

mod:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

# Endianness check: builds under sparse so every raw access to an __le
# field is flagged (the on-disk format is little-endian; the tests cannot
# catch a missing conversion on a little-endian host). Needs sparse
# >= 0.6.5 (older sparse cannot parse this kernel's headers).
endian-check:
	$(MAKE) -C $(KDIR) M=$(CURDIR) C=2 modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
	rm -f *~

format:
	bash -c 'clang-format -i *.{c,h}'
