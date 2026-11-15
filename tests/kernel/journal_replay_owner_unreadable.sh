#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# replay retries an unreadable owner record, and refuses the entry when it stays unreadable
#
# The owner check (journal_replay_owner.sh) confirms a target is still
# its owner's before the redo. When the owner's record could not be read
# the verdict was left to the replay guard alone -- a fail-open: a block
# freed and reallocated with matching bytes was then redone onto a
# stranger. Now an unreadable owner is retried with backoff (a path
# failover is transient), and an owner still unreadable after that makes
# the entry refused: the area stays DIRTY and the block is not written.
#
# Staged single-node as journal_replay_owner.sh stages its cases: the
# root's dirent block in two states, an entry carrying the older one,
# guarded against the newer, planted in this node's own area. The own
# area is replayed at mount, and a refused replay fails that mount.
#
# 1. control: the owner read fails twice, then succeeds: retried, applied.
# 2. the owner stays unreadable: the mount is refused, the block is
#    untouched, the area is still DIRTY, and dmesg says the owner was
#    unreadable; and its teardown announced no clean departure (B-6).
# 3. the way out of 2 (A-10/B-6): with the owner still unreadable, the
#    mount stays refused; fsck --discard-journal parks the area CLEAN
#    without applying the entry, and the volume mounts with the block
#    as it was (state B). (No fsck verdict: case 1's redo of an older
#    dirent block leaves the root's size behind its entries, by staging.)
# 4. control: journal_owner_fail_open (the old verdict) applies the same
#    entry under the same failure -- so 2 is the owner check and nothing else.
#
# DISCRIMINATION: with the fail-open verdict (case 4's knob, or the
# pre-fix code) case 2 applies the entry and the root goes back to the
# older state. An fsck without --discard-journal leaves 3 refused.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_owner_read_fail ] || { skip "journal_owner_read_fail is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"

IMG="$(ct_image 560 jowun)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jowun)"
BLK_A="$(ct_tmp jowun-a)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

# 2 leaves row 0 departed uncleanly, which every later mount watches
# for the stale window; the short watch keeps the suite under its limit
ct_param_set twin_watch_short 1

lsroot() { ls "$MNT" | sort | tr '\n' ' '; }
blk() { dd if="$IMG" bs=4096 skip="$TARGET_LBA" count=1 status=none | sha256sum | cut -d' ' -f1; }
reset_knobs() {
    ct_param_set journal_owner_read_fail 0
    ct_param_set journal_owner_fail_open 0
}

mount -t cetrafs "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
echo data >"$MNT/f"
MARK="$(dmesg_mark)"
touch "$MNT/alpha"
TARGET_LBA="$(dmesg_since "$MARK" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
ct_umount "$MNT"
[ -n "$TARGET_LBA" ] || { fail "setup: the create journaled no dirent block"; ct_exit; }
dd if="$IMG" of="$BLK_A" bs=4096 skip="$TARGET_LBA" count=1 status=none # state A: f alpha
mount -t cetrafs "$DEV" "$MNT"
touch "$MNT/beta"                                                       # state B: alpha beta f
ct_umount "$MNT"
WANT_B="$(blk)"

# plant: the state-A image, guarded against what the block reads now
plant() { "$JPOKE" "$IMG" "$NID" 0 "$TARGET_LBA" "$BLK_A" --guard-current >/dev/null; }
# restore_b: put state B back (a replay that applied the entry moved it to A)
restore_b() {
    mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || true
    [ "$(lsroot)" = "alpha f " ] && touch "$MNT/beta"
    ct_umount "$MNT" 2>/dev/null || true
}

# ------------------------------------------------------------------- 1
reset_knobs
plant
ct_param_set journal_owner_read_fail 2
mount -t cetrafs "$DEV" "$MNT"
LS="$(lsroot)"
LEFT="$(cat /sys/module/cetrafs/parameters/journal_owner_read_fail)"
ct_umount "$MNT"
reset_knobs
[ "$LEFT" = 0 ] || { fail "setup: the owner read was not reached ($LEFT of 2 failures left)"; ct_exit; }
[ "$LS" = "alpha f " ] && pass "1: control: two unreadable owner reads are retried and the entry is applied" ||
    fail "1: a transient owner read failure refused the entry: root is '$LS'"
restore_b

# ------------------------------------------------------------------- 2
plant
WANT_CUR="$(blk)"
ct_param_set journal_owner_read_fail 1000
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    ct_umount "$MNT"
    STAGE2=mounted
else
    STAGE2=refused
fi
LEFT="$(cat /sys/module/cetrafs/parameters/journal_owner_read_fail)"
reset_knobs
DUMP="$("$JPOKE" "$IMG" "$NID" --dump 2>/dev/null || true)"
[ "$LEFT" -lt 1000 ] || { fail "setup: the owner read was never attempted"; ct_exit; }
dmesg_since "$MARK" | grep -q "could not read owner ino" &&
    pass "2: the unreadable owner was reported" || fail "2: no unreadable-owner message in dmesg"
[ "$STAGE2" = refused ] && pass "2: the mount is refused while the owner stays unreadable" ||
    fail "2: the mount succeeded with an entry whose owner could not be checked"
[ "$(blk)" = "$WANT_CUR" ] && pass "2: the target block was not written" ||
    fail "2: the target block was redone on the guard alone"
grep -q "^state=1 " <<<"$DUMP" && pass "2: the area stays DIRTY, the entry kept" ||
    fail "2: the area was parked clean over an unverified entry ($DUMP)"
# B-6: the refused mount's teardown must not announce a clean departure
# over the unreplayed area (departure 1): peers would take the row as
# a clean leaver, and the next mount would skip its own-claim sweeps.
ROW="$("$(ct_helper node_poke)" "$DEV" 0 | sed -n 's/.*departure=\([0-9]*\).*/\1/p')"
[ "$ROW" != 1 ] && pass "2: no clean departure announced over the unreplayed area (departure=$ROW)" ||
    fail "2: the refused mount announced a clean departure over a DIRTY own area"

# ------------------------------------------------------------------- 3
ct_param_set journal_owner_read_fail 1000
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null && { ct_umount "$MNT"; fail "setup: 3: the wedged area mounted"; ct_exit; }
FOUT="$("$ROOT/userspace/fsck.cetra" --discard-journal "$NID" "$DEV" 2>&1)" || true
log "fsck --discard-journal: $(grep -E 'discard|parked|ERR' <<<"$FOUT" | tr '\n' ' ')"
DUMP="$("$JPOKE" "$IMG" "$NID" --dump 2>/dev/null || true)"
grep -q "^state=0 " <<<"$DUMP" && pass "3: --discard-journal parked the area CLEAN" ||
    fail "3: the area is still DIRTY after --discard-journal ($DUMP)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    LS="$(lsroot)"
    ct_umount "$MNT"
else
    LS=refused
fi
reset_knobs
[ "$LS" = "alpha beta f " ] && pass "3: the volume mounts again, the entry not applied" ||
    fail "3: after --discard-journal the mount gave '$LS'"
[ "$(blk)" = "$WANT_CUR" ] && pass "3: the target block was not written" || fail "3: the target block changed"

# ------------------------------------------------------------------- 4
plant
ct_param_set journal_owner_fail_open 1
ct_param_set journal_owner_read_fail 1000
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    LS="$(lsroot)"
    ct_umount "$MNT"
else
    LS=refused
fi
reset_knobs
[ "$LS" = "alpha f " ] && pass "4: control: the old fail-open verdict applies the same entry under the same failure" ||
    fail "4: control: with the fail-open verdict the entry was not applied ('$LS') -- 2 proves nothing"
ct_exit
