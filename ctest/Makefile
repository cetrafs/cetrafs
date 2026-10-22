# SPDX-License-Identifier: GPL-2.0-or-later
.PHONY: build clean embed

# The slave compiles test helpers from C (they reuse the real on-disk
# structs), and a node may have no cetrafs checkout at all -- so the
# sources are embedded in the binary. go:embed cannot reference paths
# outside this directory, hence the copy. Generated, never committed: a
# second copy of cetrafs.h in git is a copy that drifts.
embed:
	@mkdir -p embedded
	@cp ../tests/helpers/*.c embedded/
	@cp ../include/cetrafs.h ../userspace/crc32c.h ../userspace/devutil.h embedded/
	@cp ../userspace/fsck.c ../userspace/mkfs.c embedded/

build: embed
	go build -o ctest .

clean:
	rm -f ctest
	rm -f embedded/*.c embedded/*.h
