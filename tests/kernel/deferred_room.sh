#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a held-back set whose cap flush keeps failing refuses the write, not the boundary
#
# A regular file's extent-tree blocks are held back and written at the
# next durability boundary as ONE journal batch, so an inode's set is
# kept under half the journal: at the cap it is written early
# (cetrafs_deferred_capped()). A cap write that FAILED only warned, and
# every later mutation added its blocks on top. Past the journal's size
# no boundary could write the set -- a batch larger than the journal is
# refused for good, not split -- so fsync failed at every try and
# unmount dropped it: the writes those leaves mapped were gone, with
# their data on the device (review of 46e9e39). Now a mutation that
# finds the set at the cap tries the write again first and, if it still
# fails, fails itself (cetrafs_deferred_room()): the write errors, and
# the set stays small enough for the boundary.
#
# Staged: journal_slots_max=8 (a cap of 4), and journal_batch_fail makes
# every held-back batch write fail -- cap flushes and boundaries alike --
# as a device refusing the journal's writes would.
# Random 4 KiB writes into a fallocated image, fsynced every 16 (each
# fsync fails); then the failure is lifted and the file fsynced again.
#
#  1. tree changes are refused while the set cannot be written
#     (deferred_room_refusals moves) -- those boundaries fail, the
#     conversions stay pending; once the device works again the fsync
#     succeeds, and after a remount every write reads back; fsck clean.
#  2. control (deferred_room_off=1, the old path): nothing is refused,
#     the set outgrows the journal, the last fsync is refused ("does not
#     fit the journal"), and after the remount writes are gone.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in journal_batch_fail deferred_room_off journal_slots_max; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

IMG="$(ct_image 1200 droom)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt droom)"
ct_track mnt "$MNT"
OKS="$(ct_tmp droom-ok)"
ct_param_set journal_batch_fail 0
ct_param_set deferred_room_off 0
ct_param_set journal_slots_max 8
# One tree change per converted block, wherever the image lives: a loop
# device over a filesystem that zeroes ranges marks a whole 64 KiB unit
# written on its first write (the sparse unit, the convert widen), the
# set then stays small, and the control never outgrows the journal -- so
# the suite passed or failed by whether its image landed on tmpfs.
ct_param_set convert_unit_blocks 1
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

# Writes with every held-back batch failing, fsyncing every 16 writes,
# then lifts the failure and fsyncs once more. Prints "<writes> <failed
# fsyncs> <last fsync rc>"; the offsets written go to $OKS.
workload() {
    python3 - "$MNT/img" "$OKS" <<'PY'
import os, sys, random
path, oks = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
os.posix_fallocate(fd, 0, 64 << 20)
os.fsync(fd)
open("/sys/module/cetrafs/parameters/journal_batch_fail", "w").write("1")
random.seed(5)
good, bad = [], 0
# A write into preallocated space changes the tree at the next
# boundary (the conversion is pending until then), so fsync every few
# writes: each boundary converts, holds its tree blocks back, and fails
# to write them while the journal refuses -- the set grows across
# boundaries. bad counts the boundaries that failed.
for i, b in enumerate(random.sample(range(0, (64 << 20) // 4096), 3000)):
    os.pwrite(fd, (b"%08d" % b) * 512, b * 4096)
    good.append(b)
    if i % 16 == 15:
        try:
            os.fsync(fd)
        except OSError:
            bad += 1
open("/sys/module/cetrafs/parameters/journal_batch_fail", "w").write("0")
try:
    os.fsync(fd)
    rc = 0
except OSError as e:
    rc = e.errno
os.close(fd)
open(oks, "w").write("\n".join(str(b) for b in good))
print(len(good), bad, rc)
PY
}

# Reads back every offset in $OKS; prints how many are wrong.
readback() {
    python3 - "$MNT/img" "$OKS" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
offs = [int(l) for l in open(sys.argv[2]) if l.strip()]
print(sum(1 for b in offs if os.pread(fd, 8, b * 4096) != b"%08d" % b))
os.close(fd)
PY
}

run() { # <tag>: sets GOOD REFUSED FSYNC LOST REFUSALS
    ct_mkfs "$DEV" -s 1G -z 1 -b 512 -J 2 -M 4 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    local r0
    r0="$(info deferred_room_refusals)"
    MARK="$(dmesg_mark)"
    read -r GOOD REFUSED FSYNC <<<"$(workload)"
    REFUSALS=$(($(info deferred_room_refusals) - r0))
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    LOST="$(readback)"
    ct_umount "$MNT"
    log "$1: $GOOD writes, $REFUSED failed fsyncs, $REFUSALS refusals, last fsync rc $FSYNC, $LOST lost after remount"
}

# ------------------------------------------------------------------ 2
log "2: control -- the old path: the cap flush only warns"
ct_param_set deferred_room_off 1
run "control"
ct_param_set deferred_room_off 0
[ "$FSYNC" != 0 ] && dmesg_since "$MARK" | grep -q "does not fit the journal" &&
    pass "control: the set outgrew the journal and the fsync was refused (rc $FSYNC)" ||
    { fail "control: setup: the fsync was not refused for size (rc $FSYNC) -- the suite does not reach the bug"; ct_exit; }
[ "$LOST" -gt 0 ] && pass "control: $LOST writes are gone after the remount -- the loss this fixes" ||
    fail "control: nothing was lost -- the suite cannot tell the fix from its absence"

# ------------------------------------------------------------------ 1
log "1: a write that finds the set at its cap, and still cannot write it, fails"
run "fix"
[ "$REFUSALS" -gt 0 ] &&
    pass "1: $REFUSALS tree changes were refused while the held-back set could not be written" ||
    fail "1: no tree change was refused -- the set grew unchecked"
[ "$FSYNC" = 0 ] && pass "1: once the device works again, the fsync writes the set" ||
    fail "1: the fsync failed (rc $FSYNC) -- the set is still too large for the journal"
[ "$LOST" = 0 ] && pass "1: all $GOOD writes read back after a remount" ||
    fail "1: $LOST of $GOOD writes are gone after the remount"
out="$(ct_fsck "$DEV" 2>&1)" && pass "1: fsck clean" || fail "1: fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
