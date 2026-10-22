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
#
# CI: `make -C tests check` is the one target to run. It exits nonzero on
# any failure, and on any suite that aborts without failing an assertion
# -- the mode that otherwise prints no summary and reads like success.

RUN     := ./run.sh
HELPERS := $(patsubst helpers/%.c,.build/%,$(wildcard helpers/*.c))
CFLAGS  := -D_FILE_OFFSET_BITS=64 -I ../include -I ../userspace -O2 -std=gnu99

.PHONY: check image kernel list helpers run caw sparse soak clean crash

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

soak:
	./stress/soak.sh $(ROUNDS)

clean:
	rm -rf .build

# One suite by path, for `make -C tests run SUITE=kernel/nslock.sh`.
run:
	@test -n "$(SUITE)" || { echo "usage: make run SUITE=kernel/<name>.sh"; exit 2; }
	$(RUN) $(SUITE)
