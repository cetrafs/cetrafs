# SPDX-License-Identifier: GPL-2.0-or-later
.PHONY: soak all clean mod userspace format check check-one check-slow check-fsck check-caw check-crash ctest endian-check deb deb-clean

SDIR = $(CURDIR)

all: userspace mod

mod:
	$(MAKE) -C $(SDIR)/kmod mod PWD=

userspace:
	$(MAKE) -C $(SDIR)/userspace

clean:
	$(MAKE) -C $(SDIR)/userspace clean PWD=
	$(MAKE) -C $(SDIR)/kmod      clean PWD=

# Whole-tree sparse endian check: every __le on-disk field must be
# accessed through cetrafs_le*/cetrafs_cpu_to_le*. Kernel, userspace
# tools, and the test poke helpers. Needs sparse >= 0.6.5.
endian-check:
	$(MAKE) -C $(SDIR)/kmod endian-check
	$(MAKE) -C $(SDIR)/userspace endian-check
	@for f in tests/helpers/*.c; do \
	  sparse -fmax-warnings=5000 -I $(SDIR)/include -I $(SDIR)/userspace \
	    -D_FILE_OFFSET_BITS=64 $$f; \
	done

format:
	bash -c 'pushd kmod      && clang-format -style=file -i *.{c,h}'
	bash -c 'pushd userspace && clang-format -style=file -i *.{c,h}'

# Build the two Debian packages:
#   cetrafs-dkms  -- module source + DKMS wiring (rebuilt per kernel)
#   cetrafs-tools -- mkfs.cetra / fsck.cetra / defrag.cetra
#
# dpkg-buildpackage always writes beside the source tree, in the PARENT
# directory -- it has no output-directory option -- so the artifacts are
# moved into dist/ afterwards (gitignored) rather than scattered next to
# the checkout. debian/rules deliberately skips `make check` at package-build
# time: it needs root, loads the module, and takes minutes -- so a built
# package is NOT a tested one; run `make check` yourself.
#
# The version lives in THREE places that must agree: debian/changelog
# (the package version, and the source of truth here), dkms.conf's
# PACKAGE_VERSION, and dh_dkms -V in debian/rules -- the last two also
# name the /usr/src/cetrafs-<version> directory the postinst registers
# with DKMS. Bumping one and forgetting the others yields a package whose
# postinst registers a directory that does not exist, and whose module
# therefore never builds; checked here rather than shipped.
# The version lives in debian/changelog and nowhere else. These checks
# assert the OTHER files still derive it rather than carry a copy: they
# used to grep debian/rules for the literal version, which stopped being
# possible -- and so stopped passing -- once rules was parameterised on
# $(VERSION), which is the better arrangement.
deb:
	@command -v dpkg-buildpackage >/dev/null 2>&1 || { \
	  echo "make deb: dpkg-buildpackage not found -- apt install dpkg-dev"; exit 1; }
	@v=$$(dpkg-parsechangelog -S Version 2>/dev/null); \
	if [ -z "$$v" ]; then \
	  echo "make deb: cannot read a version from debian/changelog"; exit 1; fi; \
	if ! grep -q "^PACKAGE_VERSION=\"$$v\"" dkms.conf; then \
	  echo "make deb: dkms.conf PACKAGE_VERSION != $$v (debian/changelog)"; exit 1; fi; \
	if ! grep -q 'VERSION := $$(shell dpkg-parsechangelog' debian/rules; then \
	  echo "make deb: debian/rules no longer derives VERSION from debian/changelog"; exit 1; fi; \
	if ! grep -q '/usr/src/cetrafs-$$(VERSION)' debian/rules; then \
	  echo "make deb: debian/rules installs to a /usr/src dir not keyed on \$$(VERSION)"; exit 1; fi
	@# Every tool userspace/ builds must be INSTALLED by debian/rules.
	@# growfs.cetra was written, tested and committed while debian/rules
	@# still installed only three tools, so the whole feature would have
	@# shipped invisible. Nothing checked, so nothing noticed.
	@for t in $$(sed -n 's/^[A-Z][A-Z]* *= *\([a-z]*\.cetra\)$$/\1/p' userspace/Makefile); do \
	  grep -q "userspace/$$t" debian/rules || { \
	    echo "make deb: userspace builds $$t but debian/rules does not install it"; exit 1; }; \
	  grep -q "$$t" debian/control || { \
	    echo "make deb: $$t is installed but not listed in debian/control"; exit 1; }; \
	done
	@dpkg-checkbuilddeps || { \
	  echo "make deb: install the build dependencies listed above (apt install debhelper dh-dkms)"; exit 1; }
	dpkg-buildpackage -us -uc -b
	@v=$$(dpkg-parsechangelog -S Version); \
	mkdir -p $(SDIR)/dist; \
	for f in $(SDIR)/../cetrafs*_$$v_*.deb $(SDIR)/../cetrafs_$$v_*.buildinfo \
	         $(SDIR)/../cetrafs_$$v_*.changes; do \
	  if [ -e "$$f" ]; then mv -f "$$f" $(SDIR)/dist/; fi; \
	done; \
	echo; echo "built, in dist/:"; ls -1 $(SDIR)/dist

# Undoes `make deb` completely: the staging dirs debhelper leaves in the
# tree AND the packages in dist/. (`make clean` does not touch dist/ --
# rebuilding the module should not throw away packages you just built.)
deb-clean:
	dh clean
	rm -rf $(SDIR)/dist

check: all
	$(MAKE) -C $(SDIR)/tests check

# Image-level only: no module, nothing mounted, runs in seconds. Every
# check it covers is injected as a real fault and required to be caught.
check-fsck: userspace
	$(MAKE) -C $(SDIR)/tests image

# Run one suite, e.g.
#   make check-one SUITE=kernel/nslock.sh
check-one: all
	@test -n "$(SUITE)" || { echo "usage: make check-one SUITE=kernel/<name>.sh"; exit 2; }
	$(MAKE) -C $(SDIR)/tests run SUITE=$(SUITE)

# The CAS/CAW coverage a loop device cannot give: needs a real device
# that reports an atomic COMPARE AND WRITE length, and REFORMATS it.
# Device is a required argument, deliberately -- e.g.
#   make check-caw DEV=/dev/sda
check-caw: all
	@test -n "$(DEV)" || { echo "usage: make check-caw DEV=/dev/sdX (DESTRUCTIVE)"; exit 2; }
	$(MAKE) -C $(SDIR)/tests caw DEV=$(DEV)

# Deliberately separate from `check`: mkfs'ing and exercising a multi-GiB
# device (default 10 GiB, override CETRAFS_SPARSE_TEST_SIZE_MB) is slow
# and not worth paying on every ordinary `make check` run.
check-slow: all
	$(MAKE) -C $(SDIR)/tests sparse

# Crash-consistency: dm-log-writes replay to every durability boundary +
# a dm-flakey power-loss sweep. Opt-in (loop-backed but slow, and needs
# dm-log-writes/dm-flakey). Not part of `check`.
check-crash: all
	$(MAKE) -C $(SDIR)/tests crash

# Not part of `all`: ctest/ is a standalone Go tool for
# multi-node concurrency testing, independent of the kernel module/
# userspace build and not needed to build or test either of those.
ctest:
	$(MAKE) -C $(SDIR)/ctest build

# Mixed-workload soak with a full fsck after each round. Needs the module
# loaded; ROUNDS=n to change the count.
soak:
	@$(MAKE) -C $(SDIR)/tests soak ROUNDS=$(or $(ROUNDS),20)

# The release test bar (D4): every
# loop-backed suite -- check, crash rig, sparse, fuzz, soak -- run in
# sequence under a lock, logged, with a recorded summary. Repeat it,
# because one green run is not evidence for a race test:
#   make release-matrix ARGS="-r 3"
# ctest is NOT included: it needs a real shared LUN and several nodes,
# and it reformats that LUN. The script prints the command to run.
release-matrix: all
	@$(SDIR)/tests/release-matrix.sh $(ARGS)
