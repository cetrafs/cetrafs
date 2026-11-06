#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a replay that cannot read where its target lies keeps the entry for the next replay
#
# Before it trusts an entry, replay asks which Block Group its target
# lies in. Any nonzero answer was read as "outside every data region",
# and the entry was dropped -- including a descriptor that merely failed
# to read (a cold read during a path failover). The area was then parked
# CLEAN over it, so the torn block the entry would have repaired stayed
# torn for good (audit 2026-11-06 M3).
#
# Staged: a dead peer's journal holds one entry for a data block of a
# real file; journal_replay_lookup_fail fails the first replay's lookup.
# The heartbeat sweep's next replay must still apply the entry -- the
# block ends up holding its payload.
#
# DISCRIMINATION: with any lookup error read as "outside every region"
# the entry is dropped, the area parked clean, and the block keeps its
# old contents.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/journal_replay_lookup_fail ] || { skip "journal_replay_lookup_fail is missing"; ct_exit; }
NODEPOKE="$(ct_helper node_poke)"
JPOKE="$(ct_helper journal_poke)"
EPOKE="$(ct_helper pending_poke)"
ct_param_set hb_interval_secs 2

IMG="$(ct_image 560 jrlook)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jrlook)"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((NID + 1) % 4))
dd if=/dev/zero of="$MNT/f" bs=4096 count=2 conv=fsync status=none
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"
TARGET="$("$EPOKE" "$IMG" extent "$INO" | cut -d' ' -f1)"
[ -n "$TARGET" ] && [ "$TARGET" -gt 0 ] || { fail "setup: no data block for f ($TARGET)"; ct_exit; }
blk() { dd if="$IMG" bs=4096 skip="$TARGET" count=1 status=none | sha256sum | cut -d' ' -f1; }
PAY="$(ct_tmp jrlook-pay)"
head -c 4096 /dev/urandom >"$PAY" # differs from the target, so only the redo can put it there
WANT="$(sha256sum <"$PAY" | cut -d' ' -f1)"

ct_mount "$DEV" "$MNT"
ct_param_set journal_replay_lookup_fail 1
MARK="$(dmesg_mark)"
"$NODEPOKE" "$IMG" "$PEER" 1 ee 0 >/dev/null 2>&1 # REGISTERED, last_seen=0: stale at once
"$JPOKE" "$IMG" "$PEER" 0 "$TARGET" "$PAY" >/dev/null 2>&1
GOT=""
for _ in $(seq 1 30); do
    [ "$(blk)" = "$WANT" ] && { GOT=1; break; }
    sleep 1
done
LEFT="$(cat /sys/module/cetrafs/parameters/journal_replay_lookup_fail)"
ct_param_set journal_replay_lookup_fail 0
[ "$LEFT" = 0 ] || { fail "setup: no replay reached the target lookup"; ct_umount "$MNT"; ct_exit; }
dmesg_since "$MARK" | grep -q "could not tell where target block $TARGET lies" &&
    pass "the failed lookup was reported, not read as 'outside every region'" ||
    fail "the failed lookup was not reported as such"
[ -n "$GOT" ] && pass "a later replay applied the entry (the block holds its payload)" ||
    fail "the entry was lost: the block never received its payload"
ct_umount "$MNT"
ct_exit
