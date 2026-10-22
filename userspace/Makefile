# SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary
.PHONY: all clean endian-check

# The repo root, derived from THIS makefile's own directory rather than
# the caller's cwd: $(PWD) only happened to be right when make was run
# from the repo root, and broke the moment tests/Makefile invoked it.
SDIR = $(CURDIR)/..

MKFS = mkfs.cetra
FSCK = fsck.cetra
DEFRAG = defrag.cetra

all: $(MKFS) $(FSCK) $(DEFRAG)

# The shared on-disk-format header is a prerequisite: editing it MUST
# rebuild every tool, or a stale binary parses the new layout with the
# old struct (bit us for real on the v0x0008 generation field -- fsck
# read the new field as its checksum). The lone "-I" that used to sit
# before -O2 also silently consumed it as an include path, so these were
# building unoptimized; both fixed together.
HDRS = $(SDIR)/include/cetrafs.h crc32c.h devutil.h

# A warning is a build failure here too -- fsck and mkfs write the
# on-disk format, so a sign/truncation warning is a format bug waiting
# to happen. Escape hatch: make userspace CETRAFS_NO_WERROR=1
ifeq ($(CETRAFS_NO_WERROR),)
WERROR = -Werror
endif

# _FORTIFY_SOURCE=3 marks pread/pwrite and friends warn_unused_result,
# so an ignored short or failed I/O becomes a build failure here rather
# than a surprise in a distro build. Debian defaults to level 2, which
# does NOT mark them, so two unchecked preads in mkfs -- a bitmap
# read-modify-write whose failure would have cleared every other bit in
# the block -- built clean locally and only failed on Ubuntu's level 3.
# Needs optimisation to do anything, which -O2 below provides.
HARDEN = -D_FORTIFY_SOURCE=3

$(MKFS): mkfs.c $(HDRS)
	$(CC) -D_FILE_OFFSET_BITS=64 -I $(SDIR)/include -O2 $(HARDEN) -std=gnu99 -Wall -Wextra $(WERROR) -o $@ $<

$(FSCK): fsck.c $(HDRS)
	$(CC) -D_FILE_OFFSET_BITS=64 -I $(SDIR)/include -O2 $(HARDEN) -std=gnu99 -Wall -Wextra $(WERROR) -o $@ $<

$(DEFRAG): defrag.c $(HDRS)
	$(CC) -D_FILE_OFFSET_BITS=64 -I $(SDIR)/include -O2 $(HARDEN) -std=gnu99 -Wall -Wextra $(WERROR) -o $@ $<


# Sparse (>= 0.6.5) static check that every on-disk-struct field is
# accessed through the cetrafs_le*/cetrafs_cpu_to_le* macros, so a
# wrong-endian access is a type error. Needs sparse installed; the
# tools build fine without it (plain-int __le on a normal compiler).
endian-check:
	@for f in mkfs.c fsck.c defrag.c; do \
	  sparse -fmax-warnings=5000 -I $(SDIR)/include -I $(CURDIR) \
	    -D_FILE_OFFSET_BITS=64 $$f; \
	done

clean:
	rm -f $(MKFS)
	rm -f $(FSCK)
	rm -f $(DEFRAG)

format:
	bash -c 'clang-format -i *.{c,h}'
