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
	@cp ../include/cetrafs.h ../userspace/*.h embedded/
	@cp ../userspace/fsck.c ../userspace/mkfs.c ../userspace/growfs.c embedded/

# GOARCH=amd64 (or any) cross-builds for nodes of another architecture;
# always through here, so the embedded sources are the tree's (README).
build: embed
	CGO_ENABLED=0 GOARCH=$(or $(GOARCH),$(shell go env GOARCH)) go build -o ctest .

clean:
	rm -f ctest
	rm -f embedded/*.c embedded/*.h
