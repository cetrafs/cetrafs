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
CETRAFS_BUILD_VERSION := $(CETRAFS_GIT_DESC)$(CETRAFS_DIRTY_HASH)
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
