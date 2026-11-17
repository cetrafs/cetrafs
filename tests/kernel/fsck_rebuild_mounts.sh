#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a volume whose damaged global records fsck -r rebuilt mounts and works again
#
# One damaged Zone Group record, Block Group descriptor or Node Registry
# row refused every mount (audit 2026-11-15 B-14). fsck -r now rebuilds
# each (tests/image/fsck_rebuild_records.sh checks fsck's side); this is
# the kernel's side: the volume the rebuild leaves must mount, take
# writes, and check clean afterwards.
#
# Staged on a used volume: a file written, then ZG0's record, BG1's
# descriptor and the registry row of a dead peer owning ZG1 damaged at
# once.
#   control: before the repair, the mount is refused;
#   fixed:   after fsck -r, it mounts, the old file reads back, a new
#            one is written, the rebuilt row reads as a dead node, and
#            fsck is clean.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
export CETRAFS_PEER_PROBE_SECS=3
POKE="$(ct_helper csum_poke)"
ZG_POKE="$(ct_helper zg_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 1200 rebmnt)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rebmnt)"
ct_track mnt "$MNT"

ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
head -c 1M /dev/urandom >"$MNT/old"
SUM="$(md5sum <"$MNT/old")"
ct_umount "$MNT"
poke_dead_peer "$DEV" 1 aa
"$ZG_POKE" "$DEV" 1 1 >/dev/null
"$POKE" "$DEV" zg-hot 0 >/dev/null
"$POKE" "$DEV" bg-desc 1 >/dev/null
"$POKE" "$DEV" node 1 >/dev/null
blockdev --flushbufs "$DEV"

if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    ct_umount "$MNT"
    fail "control: the damaged volume mounted -- the suite damaged nothing the mount reads"
else
    pass "control: the damaged volume is refused"
fi

out="$("$FSCK" -r "$DEV" 2>&1 || true)"
n=$(grep -cE "rebuilt the record of ZG0|rebuilt the descriptor of BG1|rebuilt node slot 1 as a dead node" <<<"$out" || true)
[ "$n" = 3 ] && pass "fsck -r rebuilt all three records" ||
    fail "fsck -r rebuilt $n of 3: $(grep -E 'ERR|rebuilt' <<<"$out" | head -4 | tr '\n' ' ')"

ct_mount "$DEV" "$MNT"
[ "$(md5sum <"$MNT/old")" = "$SUM" ] && pass "the file written before the damage reads back" ||
    fail "the old file changed"
head -c 4M /dev/urandom >"$MNT/new" && sync && pass "a new file is written" || fail "the write failed"
# The mount reads the rebuilt row, and as the crashed node it stands for:
# REGISTERED, departed dead, stale -- reclaimable whenever its Zone
# Group is wanted (this mount takes the unowned ZG0 and needs no more).
row="$(grep '^node 1:' "$(ct_procdir "$DEV")/cluster" || true)"
grep -q 'state=REGISTERED .*departure=dead stale=yes' <<<"$row" &&
    pass "the rebuilt row reads as a dead, stale node" || fail "row 1 as the mount reads it: ${row:-absent}"
ct_umount "$MNT"
out="$("$FSCK" "$DEV" 2>&1)" && pass "fsck clean afterwards" ||
    fail "fsck: $(grep -E '^ERR' <<<"$out" | head -3 | tr '\n' ' ')"
ct_exit
