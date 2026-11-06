#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a freed number's record names nothing, a stale verdict frees nothing, a dead claimant's free is finished
#
# Evict claims the dead record, frees its blocks, then its number
# (cetrafs_free_inode_begin()/_finish()). Three ways the same blocks
# could be freed twice, or never:
#
#   (1) After a complete free the record still named the blocks. A peer
#       holding its own in-core copy of the file evicts later: its
#       verdict matches (dead, same generation, unclaimed), and if a
#       peer's create holds the number's bit at that moment the number
#       reads allocated and the blocks are freed again. Now the record is
#       emptied of every block reference before the number goes.
#   (2) A verdict read before another free of the record acted after it:
#       the claim compared generation and nlink only. It now requires the
#       namespace stamp the verdict read. Staged: evict held between its
#       verdict and its claim while the stamp is moved on the device (a
#       peer's claim-and-release); the evict must free nothing.
#   (3) A claimant that died holding its claim left the number and the
#       unfreed blocks allocated until it came back, and for good if it
#       never did. The orphan scrub now fences it and finishes the free,
#       the number only. Staged: a dead record claimed by a dead peer's row.
#
# DISCRIMINATION: (1) without cetrafs_inode_forget_tree() the dead record
# still lists its extents; (2) without the stamp in the claim the evict
# frees the blocks; (3) with the orphan scrub skipping every claimed
# record the number stays allocated.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/evict_stall_before_free_ms ] || { skip "evict_stall_before_free_ms is missing"; ct_exit; }
IPOKE="$(ct_helper inode_block_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"
ORPHAN_POKE="$(ct_helper orphan_poke)"

IMG="$(ct_image 560 infree)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt infree)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub 0
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
freeblk() { stat -f -c %f "$MNT"; }

# (1) a completed free leaves a record that names no block
dd if=/dev/urandom of="$MNT/a" bs=4096 count=64 status=none
setfattr -n user.k -v "$(head -c 2000 /dev/zero | tr '\0' x)" "$MNT/a" 2>/dev/null || true
sync
AINO="$(stat -c %i "$MNT/a")"
E0="$("$IPOKE" "$IMG" extents "$AINO" 2>&1 | head -1)"
case "$E0" in *" entries=0 "*) fail "setup: the file has no extents on the device ($E0)"; ct_exit ;; esac
rm "$MNT/a"
E1="$("$IPOKE" "$IMG" extents "$AINO" 2>&1 | head -1)"
R1="$("$LOCK_POKE" "$DEV" "$AINO" --rec)"
case "$E1" in
*" entries=0 "*) grep -q '^size=0 ' <<<"$R1" && pass "a freed number's record names no block ($E1)" ||
    fail "a freed number's record keeps its size: $R1" ;;
*) fail "a freed number's record still lists its extents: $E1" ;;
esac

# (2) a verdict taken before the stamp moved frees nothing
dd if=/dev/urandom of="$MNT/b" bs=4096 count=64 status=none
sync
BINO="$(stat -c %i "$MNT/b")"
F0="$(freeblk)"
MARK="$(dmesg_mark)"
ct_param_set evict_stall_before_free_ms 3000
rm "$MNT/b" &
RMPID=$!
sleep 1
"$IPOKE" "$IMG" bumpseq "$BINO" >/dev/null 2>&1
wait "$RMPID" || true
ct_param_set evict_stall_before_free_ms 0
F1="$(freeblk)"
dmesg_since "$MARK" | grep -q "ino=$BINO changed under the verdict -- freeing nothing" &&
    pass "an evict whose verdict predates the record's stamp freed nothing" ||
    fail "an evict acted on a verdict older than the record's stamp (free blocks $F0 -> $F1)"
[ "$F1" -le "$F0" ] || fail "the stale verdict's evict gave blocks back ($F0 -> $F1)"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" ||
    pass "fsck clean after (1) and (2) (the refused free is an orphan, not damage)"

# (3) a dead claimant's free is finished by the orphan scrub
set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$DEV" 1 aa
CINO=40
"$ORPHAN_POKE" "$DEV" "$CINO" 0 0 >/dev/null
"$LOCK_POKE" "$DEV" "$CINO" --ns 1 >/dev/null
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "inode $CINO is allocated" <<<"$OUT" && grep -q 'ns_owner=1 ' <<<"$("$LOCK_POKE" "$DEV" "$CINO")" ||
    { fail "setup: the dead peer's claimed record is not on the device"; ct_exit; }
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set scrub 1
GOT=""
for _ in $(seq 1 $((TEST_STALE_SECS * 4 + 40))); do
    dmesg_since "$MARK" | grep -q "ino=$CINO: finished a free stale node 1 had claimed" && { GOT=1; break; }
    sleep 1
done
ct_param_set scrub 0
[ -n "$GOT" ] && pass "the orphan scrub finished a dead claimant's free" ||
    fail "nobody finished the free a dead node had claimed"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "inode $CINO is allocated" <<<"$OUT" && fail "the dead claimant's number is still allocated" ||
    pass "its number is free on the device"
grep -q '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
