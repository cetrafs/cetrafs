#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# replay does not redo a target that is torn only because a live writer is mid-write
#
# Replay redoes an entry whose target fails its own tail checksum: that
# is a block a crash tore, and the case the journal exists for. But a
# forced-fresh read of a block a LIVE node is writing at that moment
# also reads torn -- a 4 KiB write is not atomic against a reader -- and
# under nofilelock a live node may well be writing the dead one's blocks
# (the VM HA restarted elsewhere). Replay took that transient tear for a
# crash's and wrote the dead node's image over the live write.
#
# A tear from a crash stays; a tear from a write in flight converges in
# milliseconds. So a torn target is re-read, with backoff, before it is
# redone, and the redo re-checks the target immediately before writing.
#
# Played on one node: a stale peer's live entry for a directory block
# (written against image S0, carrying S2); on the device, a torn mix of
# S0 and S1 -- a live writer halfway through writing S1 -- which then
# completes while replay is deciding.
#
# DISCRIMINATION (measured on the old code): replay redoes S2 over the
# live writer's completed S1, in both cases.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_replay_apply_pause_ms ] || { skip "journal_replay_apply_pause_ms is missing"; ct_exit; }

JPOKE="$(ct_helper journal_poke)"
EXTENT="$(ct_helper pending_poke)"
IMG="$(ct_image 560 jrl)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jrl)"
S0="$(ct_tmp jrl-s0)"
S1="$(ct_tmp jrl-s1)"
S2="$(ct_tmp jrl-s2)"
TORN="$(ct_tmp jrl-torn)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

# Three successive images of one directory block.
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
blk_sum() { dd if="$DEV" bs=4096 skip="$BLK" count=1 iflag=direct status=none | sha256sum | cut -d' ' -f1; }
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
# Half of S1 over S0: what a reader sees while S1 is being written.
{ head -c 2048 "$S1"; tail -c +2049 "$S0"; } >"$TORN"

# The dead peer wrote its entry against S0.
compress_timing
poke_dead_peer "$DEV" 1 aa
put "$S0"
"$JPOKE" "$DEV" 1 0 "$BLK" "$S2" --guard-current >/dev/null
put "$TORN"

ct_param_set journal_replay_apply_pause_ms 1500
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# The stale sweep reaches node 1's journal once its heartbeat is judged
# stopped; the live writer completes as soon as replay has looked.
wait_for 30 "dmesg_since '$MARK' | grep -qE 'is TORN|reads torn|pausing'" ||
    { fail "setup: replay never looked at the torn target"; ct_exit; }
put "$S1"
pass "setup: the live writer completed its write while replay was deciding"
wait_for 30 "dmesg_since '$MARK' | grep -q 'journal replay: node 1'" || true
sleep 2
ct_umount "$MNT"

GOT="$(blk_sum)"
if [ "$GOT" = "$(sha256sum <"$S1" | cut -d' ' -f1)" ]; then
    pass "the live writer's block survived the replay"
elif [ "$GOT" = "$(sha256sum <"$S2" | cut -d' ' -f1)" ]; then
    fail "replay wrote the dead node's image over the live writer's completed write"
else
    fail "the block is neither the live write nor the dead node's image"
fi
dmesg_since "$MARK" | grep -q "has changed since the entry was written" &&
    pass "and replay refused the entry as superseded" ||
    fail "replay did not refuse the entry: $(dmesg_since "$MARK" | grep 'journal replay' | tail -2)"

log "the live writer lands between replay's verdict and its redo"
# The target still holds S0 when replay judges it -- redo is right at
# that instant -- and S1 lands in the gap before the redo.
put "$S0"
"$JPOKE" "$DEV" 1 0 "$BLK" "$S2" --guard-current >/dev/null
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
wait_for 30 "dmesg_since '$MARK' | grep -q 'pausing .* before redoing target $BLK'" ||
    { fail "setup: replay never reached the redo of the untouched target"; ct_exit; }
put "$S1"
wait_for 30 "dmesg_since '$MARK' | grep -qE 'has changed since|replayed'" || true
sleep 2
ct_umount "$MNT"
[ "$(blk_sum)" = "$(sha256sum <"$S1" | cut -d' ' -f1)" ] && pass "the redo re-checked the block and left the live write alone" ||
    fail "replay redid a block that changed after its verdict"

log "control: a tear nobody is writing is still redone"
ct_param_set journal_replay_apply_pause_ms 0
put "$S0"
"$JPOKE" "$DEV" 1 0 "$BLK" "$S2" --guard-current >/dev/null
put "$TORN"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
wait_for 30 "dmesg_since '$MARK' | grep -q 'is TORN'" ||
    fail "control: replay never redid the torn target: $(dmesg_since "$MARK" | grep 'journal replay' | tail -2)"
sleep 1
ct_umount "$MNT"
[ "$(blk_sum)" = "$(sha256sum <"$S2" | cut -d' ' -f1)" ] && pass "control: the crash's tear was repaired from the entry" ||
    fail "control: the torn target was not repaired"
ct_exit
