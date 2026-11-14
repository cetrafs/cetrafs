#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the defrag mover batches a step across its source runs, not within one run
#
# A contiguous source run was read as one batch, but a heavily fragmented
# file is made of runs of ONE block, and each of those still cost a read
# round trip and a write round trip under the file's exclusive locks: two
# per block, ~256 per 512 KiB step (audit 2026-11-14 M1). A step's source
# blocks are now read as one batch and its writes waited for once, however
# many runs they come from.
#
# Setup: a 512-block file whose blocks alternate with a filler file's, so
# every run of the file is one block; the filler is then removed. The
# device answers each request after a fixed delay (dm-delay), so the time
# of the defrag is its round trips.
#   1. fixed: the defrag is clearly faster than one round trip per block;
#   2. control (defrag_copy_serial): one round trip per block, as a run of
#      one block costs before this change.
# The file must read back unchanged and be one or two extents after.
#
# DISCRIMINATION: defrag_copy_serial is assertion 2 itself. The serial copy
# must take at least 40 device delays, or the setup did not make the
# fragmented source the suite is about, and the suite fails on that first.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/defrag_copy_serial ] || { skip "defrag_copy_serial is missing"; ct_exit; }
command -v dmsetup >/dev/null 2>&1 || { skip "dmsetup is not installed"; ct_exit; }
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_param_set defrag_copy_serial 0
DEFRAG="$ROOT/userspace/defrag.cetra"
MNT="$(ct_mnt dar)"
ct_track mnt "$MNT"
P=/sys/module/cetrafs/parameters
DELAY=5
BLOCKS=512

# <serial 0|1> -> "<defrag ms> <extents before> <extents after> <data ok|bad> <fsck ok|bad>"
probe() {
    local dev t0 t1 eb ea sum ok fk
    dev="$(ct_delay_dev 800 "$DELAY" dar$1)"
    [ -n "$dev" ] || { skip "could not create a delayed device"; ct_exit; }
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    python3 -I - "$MNT/f" "$MNT/f.fill" "$BLOCKS" <<'PY'
import os, sys
a = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
b = os.open(sys.argv[2], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(int(sys.argv[3])):
    os.pwrite(a, os.urandom(4096), i * 4096); os.fsync(a)
    os.pwrite(b, b"x" * 4096, i * 4096); os.fsync(b)
os.close(a); os.close(b)
PY
    rm -f "$MNT/f.fill"
    sum="$(md5sum <"$MNT/f")"
    sync
    echo 3 >/proc/sys/vm/drop_caches
    eb="$(filefrag -v "$MNT/f" 2>/dev/null | awk '/^ *[0-9]+:/ {n++} END {print n + 0}')"
    echo "$1" >$P/defrag_copy_serial
    t0="$(date +%s%N)"
    "$DEFRAG" "$MNT/f" >/dev/null 2>&1 || true
    t1="$(date +%s%N)"
    echo 0 >$P/defrag_copy_serial
    ea="$(filefrag -v "$MNT/f" 2>/dev/null | awk '/^ *[0-9]+:/ {n++} END {print n + 0}')"
    [ "$(md5sum <"$MNT/f")" = "$sum" ] && ok=ok || ok=bad
    echo 3 >/proc/sys/vm/drop_caches
    ct_umount "$MNT"
    fk=ok
    ct_fsck "$dev" >/dev/null 2>&1 || fk=bad
    echo "$(((t1 - t0) / 1000000)) ${eb:-0} ${ea:-?} $ok $fk"
}

read -r MS EB EA OK FK <<<"$(probe 0)"
read -r CMS CEB CEA COK CFK <<<"$(probe 1)"
log "fixed (batched across runs): defrag took ${MS} ms ($EB runs before, $EA extents after); control (serial): ${CMS} ms"
# setup: the source really was fragmented into one-block runs
[ "$EB" -ge $((BLOCKS * 3 / 4)) ] && [ "$CEB" -ge $((BLOCKS * 3 / 4)) ] ||
    fail "setup: the source had $EB and $CEB extents, not one-block runs"
[ "$CMS" -ge $((DELAY * 40)) ] || fail "setup: the serial copy took only ${CMS} ms -- too few round trips to tell them apart"
[ "$OK" = ok ] && [ "$COK" = ok ] && pass "data: the file reads back unchanged" || fail "data: the file changed (fixed $OK, control $COK)"
[ "$FK" = ok ] && [ "$CFK" = ok ] && pass "fsck is clean after both defrags" || fail "fsck reported errors (fixed $FK, control $CFK)"
[ "${EA:-99}" -le 2 ] && pass "the defrag left the file in $EA extent(s)" || fail "the defrag left $EA extents -- it did not move the file"
[ $((MS * 10)) -lt $((CMS * 7)) ] && pass "1: the step reads its blocks together (${MS} ms vs ${CMS} ms serial)" ||
    fail "1: the defrag took ${MS} ms, not clearly below the serial ${CMS} ms"
[ "$CMS" -gt "$MS" ] && pass "control: one round trip per block is the slower copy (${CMS} ms) -- the suite discriminates" ||
    fail "control: the serial copy was not slower (${CMS} ms vs ${MS} ms)"
ct_exit
