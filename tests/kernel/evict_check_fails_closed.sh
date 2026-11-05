#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an eviction whose "is another node using it?" check fails frees nothing
#
# Evict is where a deleted file's inode number and blocks go back to the
# allocator, and its one guard against a peer that still has the file
# open is cetrafs_lock_foreign_user_exists(). The guard read only the
# out-parameters when the call SUCCEEDED, so any error -- the forced-fresh
# read failing, a stale holder's fence or replay failing, the node id
# missing -- left the free going ahead: the check failed OPEN, and the
# reclaim CAS after it re-asks nothing about the file lock or readers
# (audit 2026-11-05, N1).
#
# evict_check_fail makes the next eviction's check fail. A deleted file
# must then keep its inode number and blocks: fsck names it as an orphan
# (allocated, nlink 0) whose record still holds its blocks -- the safe
# direction, reclaimed by fsck -r -- where the fail-open guard freed both.
#
# Control first: the same delete with the check working frees everything.
#
# DISCRIMINATION: proven 2026-11-05 with the old guard restored (an error
# read as "no foreign user", knob kept): no refusal is logged, and the
# inode number and all 64 blocks are freed -- three assertions fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/evict_check_fail ] || { skip "evict_check_fail is missing"; ct_exit; }
FSCK="$ROOT/userspace/fsck.cetra"

DEV="$(ct_dev 560 evcf)"
MNT="$(ct_mnt evcf)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"

fsck_out() { "$FSCK" "$DEV" 2>&1 || true; }
refd() { sed -n 's/.* \([0-9][0-9]*\) data blocks referenced.*/\1/p' <<<"$1" | head -1; }

# ---------------------------------------------------------------- control
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
dd if=/dev/urandom of="$MNT/control" bs=4096 count=64 conv=fsync status=none
rm -f "$MNT/control"
sync
ct_umount "$MNT"
OUT="$(fsck_out)"
if grep -qE 'orphan|leaked' <<<"$OUT"; then
    fail "setup: a plain delete already leaves residue -- this suite could not tell the cases apart: $(grep -E 'orphan|leaked' <<<"$OUT" | head -2)"
    ct_exit
fi
R0="$(refd "$OUT")"
[ -n "$R0" ] || { fail "setup: fsck printed no referenced-block count"; ct_exit; }
pass "control: a delete with the check working frees its inode and blocks ($R0 blocks referenced after)"

# ---------------------------------------------------------------- the check fails
ct_mount "$DEV" "$MNT"
dd if=/dev/urandom of="$MNT/victim" bs=4096 count=64 conv=fsync status=none
INO="$(stat -c %i "$MNT/victim")"
MARK="$(dmesg_mark)"
ct_param_set evict_check_fail 1
rm -f "$MNT/victim"
sync
LEFT="$(cat /sys/module/cetrafs/parameters/evict_check_fail)"
ct_param_set evict_check_fail 0
[ "$LEFT" = 0 ] || { fail "setup: the delete never reached evict's check (knob still $LEFT)"; ct_umount "$MNT"; ct_exit; }
dmesg_since "$MARK" | grep -q "ino=$INO could not ask whether another node still uses it" &&
    pass "evict reported the failed check for ino $INO" ||
    fail "evict did not report refusing on the failed check (ino $INO)"
ct_umount "$MNT"

OUT="$(fsck_out)"
log "$(grep -E 'orphan|leaked|ERR' <<<"$OUT" | head -3 | tr '\n' ';')"
grep -qE "inode $INO is allocated but has nlink=0" <<<"$OUT" &&
    pass "the failed check kept inode $INO's number allocated" ||
    fail "inode $INO's number was freed although the check never answered"
R1="$(refd "$OUT")"
[ -n "$R1" ] && [ "$R1" -ge $((R0 + 64)) ] &&
    pass "and its 64 blocks: still named by the orphan's record ($R0 -> $R1 referenced)" ||
    fail "its blocks were freed although the check never answered ($R0 -> ${R1:-?} referenced)"
grep -q '^ERR' <<<"$OUT" && fail "fsck reports damage: $(grep '^ERR' <<<"$OUT" | head -2)" ||
    pass "nothing worse than residue: no fsck ERR"
ct_exit
