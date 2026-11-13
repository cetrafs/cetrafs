# SPDX-License-Identifier: GPL-2.0-or-later
# tests/Makefile -- entry points for the cetrafs test suites.
#
# Everything here shells out to run.sh, which is also usable directly for
# one suite (./tests/run.sh kernel/nslock.sh). The top-level Makefile
# forwards `make check` / `check-fsck` / `check-caw` / `soak` here.
#
#   make -C tests check     image + kernel  (the regression set; needs root)
#   make -C tests image     image-level only, no module, seconds
#   make -C tests kernel    everything needing a loaded module
#   make -C tests list      every suite with its one-line purpose
#   make -C tests helpers   just build the C poke helpers
#   make -C tests caw DEV=/dev/sdX  DESTRUCTIVE, real device only
#   make -C tests sparse            slow, opt-in (loop-backed, multi-GiB)
#   make -C tests soak ROUNDS=20    slow, opt-in, module must be loaded
#   make -C tests matrix [CONFIGS="nofilelock bg1g"]  a suite slice under each configuration
#
# CI: `make -C tests check` is the one target to run. It exits nonzero on
# any failure, and on any suite that aborts without failing an assertion
# -- the mode that otherwise prints no summary and reads like success.

RUN     := ./run.sh
# io_shim is an LD_PRELOAD library, not a program: fsck_io_partial.sh
# builds it itself with -shared.
HELPERS := $(patsubst helpers/%.c,.build/%,$(filter-out helpers/io_shim.c,$(wildcard helpers/*.c)))
CFLAGS  := -D_FILE_OFFSET_BITS=64 -I ../include -I ../userspace -O2 -std=gnu99

.PHONY: check image kernel list helpers run caw sparse soak matrix clean crash

# One invocation, not `image kernel` as two: the module is then loaded
# once for the whole batch and there is a single results table.
check:
	$(RUN) image kernel

image:
	$(RUN) image

kernel:
	$(RUN) kernel

list:
	@$(RUN) -l

helpers: $(HELPERS)

.build/%: helpers/%.c ../include/cetrafs.h
	@mkdir -p .build
	$(CC) $(CFLAGS) -o $@ $<

# Real-device targets. No default DEV: nothing destructive should ever be
# reachable by typing the wrong target.
caw:
	@test -n "$(DEV)" || { echo "usage: make caw DEV=/dev/sdX  (DESTRUCTIVE)"; exit 2; }
	./device/caw_compare_and_write.sh $(DEV)

# Loop-backed like the kernel/ suites, but multi-GiB and slow, so it is
# opt-in rather than part of `check`. CETRAFS_SPARSE_TEST_SIZE_MB sets
# the device size (default 10 GiB).
sparse:
	./stress/sparse_bigfile.sh

crash:
	./crash/crash_consistency.sh
	./crash/buffered_extent_order.sh
	./crash/leaf_batch_order.sh
	./crash/growfs_crash.sh

soak:
	./stress/soak.sh $(ROUNDS)

# A slice of the kernel suites under each mount-option / mkfs-geometry
# configuration (tests/matrix.sh). Not part of `check`.
matrix:
	./matrix.sh $(CONFIGS)

clean:
	rm -rf .build

# One suite by path, for `make -C tests run SUITE=kernel/nslock.sh`.
run:
	@test -n "$(SUITE)" || { echo "usage: make run SUITE=kernel/<name>.sh"; exit 2; }
	$(RUN) $(SUITE)
