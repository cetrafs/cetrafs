#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a whole-tree walk reads its extent leaves together, not one round trip each
#
# A walk over a fragmented file's whole tree (the free of a truncate, an
# evict) read each extent leaf in turn: one device round trip per leaf,
# measured at up to ~1000 serial reads before anything was freed (audit
# 2026-11-14 P12). With the walk's cache trusted, the leaves under an index
# block are now read ahead together, so the device has them in flight at
# once.
#
# Setup: a file with ~12000 extents (dozens of extent leaves), its cache
# dropped, on a volume whose device answers each read after a fixed delay
# (dm-delay). Then truncate to zero -- a walk of the whole tree.
#   1. fixed: the truncate is clearly faster than the serial walk;
#   2. control (flatten_prefetch_off): the serial walk is the slower one.
#
# DISCRIMINATION: flatten_prefetch_off is assertion 2 itself. The serial walk
# must take at least 40 device delays, or the setup did not produce enough
# leaves to tell the two apart, and the suite fails on that first.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/flatten_prefetch_off ] || { skip "flatten_prefetch_off is missing"; ct_exit; }
command -v dmsetup >/dev/null 2>&1 || { skip "dmsetup is not installed"; ct_exit; }
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt twr)"
ct_track mnt "$MNT"
ct_param_set flatten_prefetch_off 0
DELAY=5

# <prefetch_off 0|1> -> "<truncate ms>"
probe() {
    local dev
    dev="$(ct_delay_dev 800 "$DELAY" twr$1)"
    [ -n "$dev" ] || { skip "could not create a delayed device"; ct_exit; }
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    python3 -I - "$MNT/frag" <<'PY'
import os, sys
f = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
blk = b"x" * 4096
for i in range(12000):                  # one block, then a hole: one extent each
    os.pwrite(f, blk, i * 8192)
os.fsync(f)
os.close(f)
PY
    sync
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    echo 3 >/proc/sys/vm/drop_caches
    echo "$1" >$P/flatten_prefetch_off
    local t0 t1
    t0="$(date +%s%N)"
    truncate -s 0 "$MNT/frag"
    t1="$(date +%s%N)"
    echo 0 >$P/flatten_prefetch_off
    ct_umount "$MNT"
    echo $(((t1 - t0) / 1000000))
}

MS="$(probe 0)"
CMS="$(probe 1)"
log "fixed (read ahead): truncate of the whole tree took ${MS} ms; control (serial): ${CMS} ms"
# setup: the serial walk must be long enough to be a walk of many leaves
[ "$CMS" -ge $((DELAY * 40)) ] || fail "setup: the serial walk took only ${CMS} ms -- too few leaves to tell the walks apart"
[ $((MS * 10)) -lt $((CMS * 7)) ] && pass "1: the whole-tree walk reads its leaves together (${MS} ms vs ${CMS} ms serial)" ||
    fail "1: the whole-tree walk took ${MS} ms, not clearly below the serial ${CMS} ms"
[ "$CMS" -gt "$MS" ] && pass "control: one read per leaf is the slower walk (${CMS} ms) -- the suite discriminates" ||
    fail "control: the serial walk was not slower (${CMS} ms vs ${MS} ms)"
ct_exit
