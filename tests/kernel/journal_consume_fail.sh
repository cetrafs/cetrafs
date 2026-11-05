#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a replay that cannot consume an entry leaves the journal area dirty
#
# Replay redoes an entry, then consumes it (zeroes its header). A consume
# the device refused was logged and the area parked CLEAN regardless:
# the leftover header then sat in its slot belonging to no replay, to be
# judged later by a 32-bit CRC that a later header can legitimately
# recur (audit L8). Now the area stays DIRTY and the replay fails like
# one whose redo failed -- this node's own area at mount fails the
# mount -- and the next replay finds the redo on the target and skips it.
#
# Staged as journal_replay_guard.sh stages a redo: a guarded entry for
# this node's own area carrying an older image of a dirent block; the
# consume is failed once (journal_consume_fail_once).
#
# DISCRIMINATION: proven by letting the failed consume fall through to
# the old park (the "goto out_free" removed): the area reads CLEAN after
# the failed replay.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_consume_fail_once ] || { skip "journal_consume_fail_once is missing"; ct_exit; }
JPOKE="$(ct_helper journal_poke)"

IMG="$(ct_image 560 jcf)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jcf)"
ct_track mnt "$MNT"
PD="$(basename "$DEV")"
BLK_A="$(ct_tmp jcf-a)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
MARK="$(dmesg_mark)"
touch "$MNT/alpha"
TARGET_LBA="$(dmesg_since "$MARK" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1)"
ct_umount "$MNT"
[ -n "$TARGET_LBA" ] || { fail "setup: no journal entry logged for a create"; ct_exit; }
dd if="$DEV" of="$BLK_A" bs=4096 skip="$TARGET_LBA" count=1 status=none
ct_mount "$DEV" "$MNT"
touch "$MNT/beta"
ct_umount "$MNT"

"$JPOKE" "$DEV" "$NID" 0 "$TARGET_LBA" "$BLK_A" --guard-current >/dev/null
grep -q "^state=1 " <<<"$("$JPOKE" "$DEV" "$NID" --dump)" || { fail "setup: the planted entry did not dirty the area"; ct_exit; }

ct_param_set journal_consume_fail_once 1
MARK="$(dmesg_mark)"
RC=0
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || RC=$?
mountpoint -q "$MNT" && umount "$MNT"
ct_param_set journal_consume_fail_once 0
D="$("$JPOKE" "$DEV" "$NID" --dump)"
log "after the failed consume: mount rc=$RC; $D"
dmesg_since "$MARK" | grep -q "could not consume txn" ||
    { fail "setup: the consume was never failed -- the replay did not reach it"; ct_exit; }
grep -q "^state=1 " <<<"$D" && pass "the area stays DIRTY after a consume the device refused" ||
    fail "the area was parked CLEAN over an entry it could not consume: $D"
[ "$RC" != 0 ] && pass "and the mount that replayed its own area failed (rc $RC)" ||
    fail "the mount went ahead over an unconsumed entry of its own"

MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
LS="$(ls "$MNT" | sort | tr '\n' ' ')"
ct_umount "$MNT"
D="$("$JPOKE" "$DEV" "$NID" --dump)"
log "after the next mount: $LS; $D"
grep -q "^state=0 " <<<"$D" && pass "the next replay consumed it and parked the area CLEAN" ||
    fail "the area is still dirty after a clean replay: $D"
[ "$LS" = "alpha " ] && pass "the redo stands, applied once ($LS)" || fail "the directory reads '$LS', expected 'alpha '"
dmesg_since "$MARK" | grep -q "NOT applying it" && fail "the second replay refused its own redo as a foreign write" ||
    pass "the second replay did not take its own redo for a foreign write"

# No fsck: the staged redo puts an older dirent block under a record that
# already counts the newer entry -- a state the staging makes and no crash
# does (journal_replay_guard.sh stages the same way and runs none either).
ct_exit
