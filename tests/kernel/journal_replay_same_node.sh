#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# two contexts of one node never replay the same dead node's journal at once
#
# Across nodes, replays of one area are serialised by the replay claim.
# But the claim accepts its own owner re-entering, and nothing on the
# node serialised its own replayers: the heartbeat's sweep and an open
# reclaiming the dead node's file lock could both apply its entries at
# once -- the first parks the area CLEAN and releases, the node
# remounts and logs again, and the second is still applying entries by
# slot over a live journal (audit R14).
#
# Staged: a stale peer with a dirty journal entry and a file whose lock
# it holds. The sweep's replay is held inside its redo
# (journal_replay_apply_pause_ms, which logs "pausing" per entry it is
# about to apply); a write-open of the file starts the second replay.
#
# DISCRIMINATION: without the per-area mutex both replays apply the
# entry -- two "pausing" lines. Proven 2026-11-05 by removing the mutex
# from cetrafs_journal_replay_node(): "2 replays applied node 1's entry".
# (A code edit, not a knob: a knob that turns off the serialisation of
# replay would be a way to corrupt a volume.)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_replay_apply_pause_ms ] || { skip "journal_replay_apply_pause_ms is missing"; ct_exit; }
NODEPOKE="$(ct_helper node_poke)"
JPOKE="$(ct_helper journal_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
EPOKE="$(ct_helper pending_poke)"
ct_param_set hb_interval_secs 2

IMG="$(ct_image 560 jsame)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jsame)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((NID + 1) % 4))
dd if=/dev/zero of="$MNT/f" bs=4096 count=2 conv=fsync status=none
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"
# An ALLOCATED target: replay skips a block freed since its entry
# (journal_replay_freed_target.sh), so a free one would test nothing.
TARGET="$("$EPOKE" "$IMG" extent "$INO" | cut -d' ' -f1)"
[ -n "$TARGET" ] && [ "$TARGET" -gt 0 ] || { fail "setup: no data block for f ($TARGET)"; ct_exit; }
"$LPOKE" "$IMG" "$INO" "$PEER" 1 >/dev/null
ct_mount "$DEV" "$MNT"

ct_param_set journal_replay_apply_pause_ms 3000
PAY="$(ct_tmp jsame-pay)"; head -c 4096 /dev/urandom >"$PAY" # differs from the target, so replay must redo it
MARK="$(dmesg_mark)"
"$NODEPOKE" "$IMG" "$PEER" 1 ee 0 >/dev/null 2>&1   # REGISTERED, last_seen=0: stale at once
"$JPOKE" "$IMG" "$PEER" 0 "$TARGET" "$PAY" >/dev/null 2>&1
for _ in $(seq 1 100); do
    dmesg_since "$MARK" | grep -q "journal replay: pausing" && break
    sleep 0.1
done
dmesg_since "$MARK" | grep -q "journal replay: pausing" ||
    { fail "setup: the sweep never started replaying node $PEER"; ct_exit; }
pass "setup: the sweep is inside node $PEER's replay"

# The second context: reclaiming the peer's lock replays its journal first.
python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$MNT/f" 2>/dev/null || true
sleep 4
ct_param_set journal_replay_apply_pause_ms 0
N="$(dmesg_since "$MARK" | grep -c "journal replay: pausing" || true)"
log "redo passes over the entry: $N"
[ "$N" = 1 ] && pass "one replay applied the entry; the other waited and found the area clean" ||
    fail "$N replays applied node $PEER's entry -- two contexts of this node replayed one area at once"

ct_umount "$MNT"
ct_exit
