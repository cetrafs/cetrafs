#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a release build's TEST ONLY knobs are read-only and refuse every set
#
# About 600 TEST ONLY module parameters -- skip the single-mounter gate,
# turn off the lease, the publish flushes, the error policy -- were
# root-writable in every build, and a modprobe.d line or a copied recipe
# was all it took (audit 2026-11-15 M-30). A release build (make
# CETRAFS_RELEASE=1, as the DKMS and Debian packages build) now shows each
# read-only at its default and refuses a set, at load as at run time.
#
# A release .ko is built from this tree into a scratch copy and loaded in
# place of the suite's module:
#   1. a load naming a knob fails;
#   2. loaded plainly, a knob is 0444, a write is refused, its value
#      unchanged, and properties says test_params: locked;
# CONTROL: the developer build the suites run takes the same load option,
# shows the knob 0644, and says settable.
# The batch's module is loaded back afterwards.
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
KNOB=bitmap_writeback
[ -e "/sys/module/cetrafs/parameters/$KNOB" ] || { skip "$KNOB is missing"; ct_exit; }
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"
SRC="$(mktemp -d /tmp/cetrafs-release-XXXXXX)"
cp -a "$ROOT/kmod" "$ROOT/include" "$SRC/"
make -C "$SRC/kmod" clean >/dev/null 2>&1 || true
make -C "$SRC/kmod" KDIR="$KDIR" CETRAFS_RELEASE=1 mod >"$SRC/build.log" 2>&1 ||
    { fail "setup: the release build failed: $(tail -3 "$SRC/build.log" | tr '\n' ' ')"; rm -rf "$SRC"; ct_exit; }
REL="$SRC/kmod/cetrafs.ko"
DEVK="$ROOT/kmod/cetrafs.ko"
IMG="$(ct_image 560 relknob)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt relknob)"
ct_mkfs_small "$DEV" >/dev/null

unload() {
    rmmod cetrafs 2>/dev/null || true
    for _ in $(seq 1 300); do [ -d /sys/module/cetrafs ] || break; sleep 0.2; done
}
# <ko> -> RES: "optload=<ok|refused> perm=<octal> write=<ok|refused> value=<v> props=<settable|locked|?>"
probe() {
    local p
    unload
    insmod "$1" "$KNOB=1" 2>/dev/null && { RES="optload=ok"; unload; } || RES="optload=refused"
    insmod "$1" || { RES="$RES load=fail"; return 0; } # plain: cas_selftest is a TEST ONLY knob too
    p="/sys/module/cetrafs/parameters/$KNOB"
    RES="$RES perm=$(stat -c %a "$p")"
    (echo 1 >"$p") 2>/dev/null && RES="$RES write=ok" || RES="$RES write=refused"
    RES="$RES value=$(cat "$p")"
    echo 0 >"$p" 2>/dev/null || true
    mount -t cetrafs "$DEV" "$MNT"
    RES="$RES props=$(sed -n 's/^test_params: //p' "$(ct_procdir "$DEV")/properties")"
    umount "$MNT"
    unload
}
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

probe "$REL"
R="$RES"
probe "$DEVK"
C="$RES"
log "release: $R"
log "developer (control): $C"
# The batch's module back, with the harness's own load settings; not
# ours to unload at the end.
unset CT_BATCH_MODULE
require_module
CT_MODULE_LOADED=0
rm -rf "$SRC"

[ "$(field optload "$C")" = ok ] && [ "$(field perm "$C")" = 644 ] && [ "$(field write "$C")" = ok ] &&
    [ "$(field props "$C")" = settable ] &&
    pass "control: the developer build takes the knob at load and at run time, and says settable" ||
    fail "control: the developer build does not take the knob -- the suite cannot see a lock: $C"
[ "$(field optload "$R")" = refused ] && pass "1: a release build refuses a load that names a TEST ONLY knob" ||
    fail "1: the release build loaded with $KNOB=1: $R"
[ "$(field perm "$R")" = 444 ] && [ "$(field write "$R")" = refused ] && [ "$(field value "$R")" = N ] &&
    pass "2: loaded, the knob is read-only, a write is refused and it keeps its default" ||
    fail "2: $R"
[ "$(field props "$R")" = locked ] && pass "2: and properties says test_params: locked" || fail "2: properties: $R"
ct_exit
