#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# damage a mount finds is recorded in the superblock and outlives a remount until fsck -r finds the volume clean
#
# A mount that finds damaged metadata counts it and refuses writes to
# the inode -- in memory, which the remount an operator does next
# forgot. The first node to find damage now records it in block 0
# (cetrafs_superblock_t.fsck_needed_since/_node, format 0x000A), from
# its heartbeat, by compare-and-write.
#
#  A. an inode record damaged on the device; a stat meets it: the mount
#     counts it and, within a few beats, the mark is on the device.
#  B. a remount reports the mark (dmesg and procfs info), with the
#     damage still there and nothing new found yet.
#  C. the damage put right by hand: fsck (check) still fails on the mark
#     alone; fsck -r clears it; a following fsck is OK and block 0 has
#     no mark.
#  D. a mark set by a peer while a mount is in flight is not a rewrite:
#     the mount comes up (it used to be refused as "mkfs?").
#  E. what fsck -r says about the clear is what it did (audit 2026-11-15
#     BL-68): it names the row and time it cleared -- it printed the
#     zeroed fields, "row 0 at 0" -- and a block 0 that no longer
#     verifies at the clear (CETRAFS_TEST_FSCK_CLEAR_MARK_BADCRC) is not
#     "cleared": the mark stays and fsck fails.
#
# DISCRIMINATION: with damage_record_off the mark never reaches the
# device and A-C fail (the run below does that as its negative
# control); D fails with the mount-time check comparing block 0 byte
# for byte (checked 2026-11-10).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
SBPOKE="$(ct_helper sb_poke)"

IMG="$(ct_image 560 fsckmark)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsckmark)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2 # read at mount
ct_param_set mount_register_stall_ms 0
ct_mkfs_small "$DEV" -N 2048 >/dev/null

sbf() { blockdev --flushbufs "$DEV"; "$SBPOKE" "$IMG" | sed -n "s/^$1=//p"; }
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo hello >"$MNT/victim"
sync
INO="$(stat -c %i "$MNT/victim")"
ct_umount "$MNT"
[ "$(sbf fsck_needed_since)" = 0 ] || { fail "setup: a fresh volume already carries a mark"; ct_exit; }
ITS="$(sbf inode_table_start)"
SAVED="$(ct_tmp fsckmark-ino)"
dd if="$IMG" of="$SAVED" bs=4096 skip=$((ITS + INO - 1)) count=1 status=none
"$IPOKE" "$IMG" corrupt "$INO" >/dev/null 2>&1

# ------------------------------------------------------------------- A
log "A: a mount meets a damaged inode record"
ct_mount "$DEV" "$MNT"
stat "$MNT/victim" >/dev/null 2>&1 || true
cat "$MNT/victim" >/dev/null 2>&1 || true
[ "$(info corruptions)" -ge 1 ] 2>/dev/null ||
    { fail "setup: the damaged record was not counted (corruptions: $(info corruptions))"; ct_exit; }
pass "A: setup: the mount counted the damage"
SINCE=""
for _ in $(seq 1 15); do
    SINCE="$(sbf fsck_needed_since)"
    [ -n "$SINCE" ] && [ "$SINCE" != 0 ] && break
    sleep 1
done
[ -n "$SINCE" ] && [ "$SINCE" != 0 ] && pass "A: the mark is on the device (since $SINCE)" ||
    fail "A: no mark on the device 15 s after the damage was found"
ROW="$(sed -n 's/^node \([0-9]*\): .*(this node)$/\1/p' "$(ct_procdir "$DEV")/cluster")"
[ "$SINCE" != 0 ] && [ "$(sbf fsck_needed_node)" = "$ROW" ] && pass "A: recorded by this node's row ($ROW)" ||
    fail "A: recorded by row '$(sbf fsck_needed_node)', this node is row $ROW"
grep -q "^since $SINCE by row $ROW\$" <<<"$(info fsck_needed)" && pass "A: and procfs info reports it" ||
    fail "A: procfs info says '$(info fsck_needed)'"
ct_umount "$MNT"

# ------------------------------------------------------------------- B
log "B: a remount reports the mark"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
[ "$(info corruptions)" = 0 ] || log "(the remount already met the damage again)"
dmesg_since "$MARK" | grep -q "this volume needs fsck" && pass "B: the mount said the volume needs fsck" ||
    fail "B: the remount did not report the mark"
grep -q "^since $SINCE by row $ROW\$" <<<"$(info fsck_needed)" && pass "B: and procfs info still reports it" ||
    fail "B: after the remount procfs info says '$(info fsck_needed)'"
ct_umount "$MNT"

# ------------------------------------------------------------------- C
log "C: fsck reports the mark; -r clears it once the volume is clean"
dd if="$SAVED" of="$IMG" bs=4096 seek=$((ITS + INO - 1)) count=1 conv=notrunc status=none
blockdev --flushbufs "$DEV"
OUT="$(ct_fsck "$DEV" 2>&1)" && RC=0 || RC=$?
[ "$RC" != 0 ] && grep -q "marked as needing fsck" <<<"$OUT" && pass "C: fsck fails on the mark alone" ||
    fail "C: fsck exited $RC without reporting the mark: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" && RC=0 || RC=$?
grep -q "cleared the needs-fsck mark" <<<"$OUT" && pass "C: fsck -r cleared it" ||
    fail "C: fsck -r (exit $RC) did not clear the mark: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "C: and the next fsck is OK" || fail "C: fsck after -r: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
[ "$(sbf fsck_needed_since)" = 0 ] && pass "C: block 0 carries no mark" ||
    fail "C: block 0 still says since $(sbf fsck_needed_since)"

# ------------------------------------------------------------------- D
log "D: a peer records a mark while a mount is in flight"
ct_param_set mount_register_stall_ms 4000
MARK="$(dmesg_mark)"
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null &
MP=$!
sleep 1.5
"$SBPOKE" "$IMG" fsck_needed_since 1234567 >/dev/null
"$SBPOKE" "$IMG" fsck_needed_node 7 >/dev/null
if wait "$MP"; then
    pass "D: the mount came up"
    grep -q "^since 1234567 by row 7\$" <<<"$(info fsck_needed)" && pass "D: and soon reports the peer's mark" ||
        { sleep 5; grep -q "^since 1234567 by row 7\$" <<<"$(info fsck_needed)" &&
            pass "D: and soon reports the peer's mark" || fail "D: procfs info says '$(info fsck_needed)'"; }
    ct_umount "$MNT"
else
    fail "D: the mount was refused: $(dmesg_since "$MARK" | grep -m1 -E 'refusing|rewritten' || true)"
fi
ct_param_set mount_register_stall_ms 0

# ------------------------------------------------------------------- E
log "E: fsck -r reports the clear it made, and only one it made"
"$SBPOKE" "$IMG" fsck_needed_since 1234567 >/dev/null
"$SBPOKE" "$IMG" fsck_needed_node 7 >/dev/null
blockdev --flushbufs "$DEV"
OUT="$(CETRAFS_TEST_FSCK_CLEAR_MARK_BADCRC=1 "$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" && RC=0 || RC=$?
! grep -q "cleared the needs-fsck mark" <<<"$OUT" && [ "$RC" != 0 ] &&
    pass "E: a block 0 that no longer verifies is not reported cleared, and fsck fails (exit $RC)" ||
    fail "E: refused clear: exit $RC, $(grep -m1 -E 'cleared|no longer verifies' <<<"$OUT" || true)"
[ "$(sbf fsck_needed_since)" = 1234567 ] && pass "E: and the mark stays" ||
    fail "E: the mark reads $(sbf fsck_needed_since) after a refused clear"
OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" && RC=0 || RC=$?
grep -q "cleared the needs-fsck mark (recorded by registry row 7 at 1234567)" <<<"$OUT" &&
    pass "E: the clear names the row and time it cleared" ||
    fail "E: fsck -r (exit $RC) said: $(grep -m1 'needs-fsck' <<<"$OUT" || echo nothing)"
[ "$(sbf fsck_needed_since)" = 0 ] && pass "E: block 0 carries no mark" ||
    fail "E: block 0 still says since $(sbf fsck_needed_since)"
ct_exit
