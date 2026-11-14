#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# A takeover recount of one file's names reads the volume in batches, not one
# block per round trip (audit 2026-11-14 N2).
#
# Recounting a file's names (cetrafs_ns_count_names(), reached from
# cetrafs_ns_reconcile()) has to visit every allocated inode record and every
# dirent block on the volume: a name of the file can sit in any directory and
# there is no reverse index. What it does NOT need is one device round trip per
# block. The inode records and a directory's dirent blocks are read as batches
# (cetrafs_bread_uncached_batch / _list), so the walk issues a handful of
# requests where it used to issue one per inode.
#
# The staging is the one of ns_count_reconcile.sh's unlink cut: the victim's
# directory has released and the victim's own lock is still set with nlink 1
# and no name, so the mount's own-claim sweep takes the file over and recounts
# it. The volume carries ~300 files in 20 directories so the walk is large.
#
# Measured as device read requests the mount issued (/sys/block/<loop>/stat).
# A cold mount reads the descriptors serially on its own (a floor of several
# hundred requests), so the walk is the DIFFERENCE between the same copy
# mounted with the batched walk and with ns_count_serial=1 (TEST ONLY, the old
# one-block-per-round-trip walk). Assertions:
#   - setup: the volume really holds the inodes and directories the walk
#     reads, and the copy shows the victim's count behind (fsck's LAG);
#   - both walks publish an exact count (fsck clean afterwards);
#   - the serial walk pays at least half a request per name more.
#
# DISCRIMINATION: NS_WALK_CONTROL=1 runs the batched round with the serial
# walk; the difference vanishes and the suite fails.
# ct-timeout: 1200
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/nslock_release_stall_ms ] || { skip "nslock_release_stall_ms is missing"; ct_exit; }
ct_param_set hb_interval_secs 1
ct_param_set stale_secs "$TEST_STALE_SECS"
export CETRAFS_PEER_PROBE_SECS=1
LAG='^ERR: inode [0-9]+ is allocated \(nlink=[0-9]+\) but NO directory entry names it'

DEV="$(ct_dev 562 nswalk)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt nswalk)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo victim >"$MNT/v" # numbered before the directories below
mkdir "$MNT/d2"
for g in $(seq 1 20); do
    mkdir "$MNT/g$g"
    for f in $(seq 1 15); do : >"$MNT/g$g/f$f"; done
done
mv "$MNT/v" "$MNT/d2/v"
sync
VI="$(stat -c %i "$MNT/d2/v")"
D2I="$(stat -c %i "$MNT/d2")"
ALLOC="$(find "$MNT" | wc -l)"
DIRS="$(find "$MNT" -type d | wc -l)"
[ "$VI" -lt "$D2I" ] || { fail "setup: the victim ($VI) is not numbered below its directory ($D2I)"; ct_exit; }
[ "$ALLOC" -ge 300 ] && [ "$DIRS" -ge 20 ] ||
    { fail "setup: the volume holds $ALLOC names in $DIRS directories, not a walk worth measuring"; ct_exit; }

SNAP="$(ct_tmp)"
ct_param_set nslock_release_stall_ms 3000
(rm "$MNT/d2/v") &
op=$!
sleep 4.5
b=0
a=0
kill -0 "$op" 2>/dev/null && b=1
cp --sparse=always "$BACK" "$SNAP"
kill -0 "$op" 2>/dev/null && a=1
wait "$op" || true
ct_param_set nslock_release_stall_ms 0
[ "$b$a" = 11 ] || { fail "setup: the unlink was not held in its window for the whole copy"; ct_exit; }
ct_umount "$MNT"
sdev="$(ct_loop "$SNAP")"
out="$(ct_fsck "$sdev" 2>&1 || true)"
losetup -d "$sdev" 2>/dev/null || true
grep -qE "$LAG" <<<"$out" || { fail "setup: the copy shows no lag for the victim: $(grep -m2 '^ERR' <<<"$out" | tr '\n' ' ')"; ct_exit; }
pass "setup: $ALLOC names in $DIRS directories; the copy shows the victim's count behind"

# <serial 0|1> -> READS = device read requests the mount issued; FSCK = fsck's
# output. The mount reads the whole volume's descriptors serially on its own,
# so the walk is measured as a difference between two mounts of the same copy.
mount_reads() {
    local work sdev name r0 r1
    work="$(ct_tmp)"
    cp --sparse=always "$SNAP" "$work"
    sdev="$(ct_loop "$work")"
    name="$(basename "$sdev")"
    ct_param_set ns_count_serial "$1"
    r0="$(awk '{print $1}' "/sys/block/$name/stat")"
    ct_mount "$sdev" "$MNT"
    r1="$(awk '{print $1}' "/sys/block/$name/stat")"
    ct_param_set ns_count_serial 0
    ct_umount "$MNT"
    FSCK="$(ct_fsck "$sdev" 2>&1 || true)"
    losetup -d "$sdev" 2>/dev/null || true
    rm -f "$work"
    READS=$((r1 - r0))
}

# The batched walk, and the serial walk, each exact.
# NS_WALK_CONTROL=1 runs the batched round with the serial walk: the
# negative control that must make the bound below fail.
[ -w /sys/module/cetrafs/parameters/ns_count_serial ] || { fail "ns_count_serial is missing"; ct_exit; }
mount_reads "${NS_WALK_CONTROL:-0}" 0
FIX_READS="$READS"
FIX_FSCK="$FSCK"
mount_reads 1 0
SERIAL_READS="$READS"
SERIAL_FSCK="$FSCK"
for r in FIX SERIAL; do
    eval "f=\$${r}_FSCK"
    grep -qE "$LAG" <<<"$f" && { fail "$r round left the victim's count behind: $(grep -m2 '^ERR' <<<"$f" | tr '\n' ' ')"; ct_exit; }
done
GAP=$((SERIAL_READS - FIX_READS))
if [ $((GAP * 2)) -ge "$ALLOC" ]; then
    pass "the takeover recount of one file: $FIX_READS read requests batched, $SERIAL_READS one-block-per-round-trip, same copy; the count is exact both ways"
else
    fail "the batched walk saves only $GAP of the $ALLOC names' round trips ($FIX_READS batched, $SERIAL_READS serial)"
fi
ct_exit
