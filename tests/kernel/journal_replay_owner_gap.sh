#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# replay re-reads its target after the owner check, not only before it
#
# A redo re-reads the target immediately before acting (rule 15) -- and
# then ran the owner check, which reads the owner's record and tree from
# the device, before the blind write. Under nofilelock a live peer can
# rewrite the target in that gap, and the dead node's image then lands
# on top of the live write (audit 2026-11-14 C1). The target is now read
# once more after the owner check and must still be what was judged.
#
# Played on one node, as journal_replay_live_writer.sh: a stale peer's
# entry for a directory block written against S0 and carrying S2; the
# device holds S0, so the verdict is "redo"; a live writer lands S1
# while replay is paused after the owner check (journal_owner_pause_ms).
#
# DISCRIMINATION: journal_no_last_read skips the new re-read; the block
# then ends as S2, the dead node's image over the live write.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in journal_owner_pause_ms journal_no_last_read; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
JPOKE="$(ct_helper journal_poke)"
EXTENT="$(ct_helper pending_poke)"
IMG="$(ct_image 560 jrog)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jrog)"
S0="$(ct_tmp jrog-s0)"
S1="$(ct_tmp jrog-s1)"
S2="$(ct_tmp jrog-s2)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
: >"$MNT/d/a"
sync
XINO="$(stat -c %i "$MNT/d")"
ct_umount "$MNT"
BLK="$("$EXTENT" "$IMG" extent "$XINO" | cut -d' ' -f1)"
[ -n "$BLK" ] && [ "$BLK" -gt 0 ] || { fail "setup: no dirent block for directory ino $XINO"; ct_exit; }
grab() { dd if="$DEV" of="$1" bs=4096 skip="$BLK" count=1 iflag=direct status=none; }
put() { dd if="$1" of="$DEV" bs=4096 seek="$BLK" count=1 conv=notrunc oflag=direct status=none; }
sum() { dd if="$DEV" bs=4096 skip="$BLK" count=1 iflag=direct status=none | sha256sum | cut -d' ' -f1; }
grab "$S0"
ct_mount "$DEV" "$MNT"
: >"$MNT/d/live_writers_name"
ct_umount "$MNT"
grab "$S1"
ct_mount "$DEV" "$MNT"
rm "$MNT/d/live_writers_name"
: >"$MNT/d/dead_nodes_name"
ct_umount "$MNT"
grab "$S2"
[ "$(sha256sum <"$S0")" != "$(sha256sum <"$S1")" ] && [ "$(sha256sum <"$S1")" != "$(sha256sum <"$S2")" ] ||
    { fail "setup: the three images are not distinct"; ct_exit; }
compress_timing
ct_param_set journal_owner_pause_ms 1500
ct_param_set journal_no_last_read 0

# <no_last_read 0|1> -> sha of the block after replay
round() {
    echo "$1" >/sys/module/cetrafs/parameters/journal_no_last_read
    poke_dead_peer "$DEV" 1 aa
    put "$S0"
    "$JPOKE" "$DEV" 1 0 "$BLK" "$S2" --guard-current >/dev/null
    local mark
    mark="$(dmesg_mark)"
    ct_mount "$DEV" "$MNT"
    wait_for 40 "dmesg_since '$mark' | grep -q 'pausing .* after the owner check of target $BLK'" ||
        { echo "noreach"; ct_umount "$MNT"; return; }
    put "$S1"
    wait_for 30 "dmesg_since '$mark' | grep -qE 'changed after its owner|journal replay: node 1 .*(replayed|applied)'" || true
    sleep 2
    ct_umount "$MNT"
    echo 0 >/sys/module/cetrafs/parameters/journal_no_last_read
    sum
}
R="$(round 0)"
[ "$R" != noreach ] || { fail "setup: replay never reached the owner check of the target"; ct_exit; }
[ "$R" = "$(sha256sum <"$S1" | cut -d' ' -f1)" ] && pass "a write landing after the owner check survives the replay" ||
    fail "replay wrote over a block that changed after its owner check"
R0="$(round 1)"
[ "$R0" = "$(sha256sum <"$S2" | cut -d' ' -f1)" ] &&
    pass "control: without the last re-read the dead node's image lands over the live write -- the suite discriminates" ||
    fail "control: without the last re-read the block is not S2 ($R0) -- the suite cannot tell"
ct_exit
