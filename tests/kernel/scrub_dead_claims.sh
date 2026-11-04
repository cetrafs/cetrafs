#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the orphan scrub reclaims a deleted file whose only claims are a dead node's
#
# A file deleted while a peer held it open stays allocated (nlink 0)
# until that peer closes it -- the orphan the scrub reclaims. But the
# scrub skipped any such record still carrying a presence bit or a lock,
# and a peer that DIED holding it open never closes it: its bit or lock
# stayed, and the inode number and every block of the file leaked until
# an offline fsck.
#
# Now the scrub judges each claim's holder: a dead one is fenced, its
# journal replayed and its claim cleared, and the record is judged again.
#
# Staged with orphan_poke: ino 30 carries a dead node 1's presence bit,
# ino 31 its exclusive lock; ino 32 the presence bit of node 3, a peer
# that keeps beating. 30 and 31 must be reclaimed, 32 spared.
#
# DISCRIMINATION: with the scrub skipping every record with a claim, 30
# and 31 are still allocated.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper orphan_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
RD=30 LK=31 LIVE=32

IMG="$(ct_image 560 scrubdead)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt scrubdead)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"

set_stale_window "$TEST_STALE_SECS"
poke_dead_peer "$DEV" 1 aa
"$POKE" "$DEV" "$RD" 0 0x2 >/dev/null
"$POKE" "$DEV" "$LK" 0 0 >/dev/null
"$LOCK_POKE" "$DEV" "$LK" 1 1 >/dev/null
"$POKE" "$DEV" "$LIVE" 0 0x8 >/dev/null
grep -q 'owner=1 mode=1' <<<"$("$LOCK_POKE" "$DEV" "$LK")" &&
    grep -q 'readers=0x2$' <<<"$("$LOCK_POKE" "$DEV" "$RD")" &&
    grep -q 'readers=0x8$' <<<"$("$LOCK_POKE" "$DEV" "$LIVE")" ||
    { fail "setup: the claims were not planted"; ct_exit; }
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
for i in $RD $LK $LIVE; do
    grep -q "inode $i is allocated" <<<"$OUT" || { fail "setup: fsck does not see orphan $i"; ct_exit; }
done
pass "setup: three orphans -- a dead node's presence bit, its lock, a live node's presence bit"

ct_param_set scrub 0
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
# Node 3 is planted only now -- a loop device has no CAW, so the mount
# gate refuses a volume with a live peer -- and beats for the whole run.
"$NODE_POKE" "$IMG" 3 1 cc "$(date +%s)" >/dev/null
( while :; do "$NODE_POKE" "$IMG" 3 --beat >/dev/null 2>&1 || true; sleep 1; done ) &
BEATER=$!
ct_track cmd "kill $BEATER"
ct_param_set scrub 1
for _ in $(seq 1 $((TEST_STALE_SECS * 4 + 40))); do
    R="$("$LOCK_POKE" "$IMG" "$RD")"; L="$("$LOCK_POKE" "$IMG" "$LK")"
    grep -q 'readers=0x0$' <<<"$R" && grep -q 'mode=0' <<<"$L" && break
    sleep 0.5
done
sleep 6 # one more scrub cycle after the claims went: the reclaim itself
ct_umount "$MNT"
kill "$BEATER" 2>/dev/null || true
wait "$BEATER" 2>/dev/null || true
"$NODE_POKE" "$DEV" 3 0 cc 0 >/dev/null
log "$(dmesg_since "$MARK" | grep -E 'scrub|stale' | head -8)"

OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "inode $RD is allocated" <<<"$OUT" &&
    fail "ino $RD still allocated: the scrub never gets past a dead node's presence bit" ||
    pass "ino $RD reclaimed past a dead node's presence bit"
grep -q "inode $LK is allocated" <<<"$OUT" &&
    fail "ino $LK still allocated: the scrub never gets past a dead node's lock" ||
    pass "ino $LK reclaimed past a dead node's lock"
grep -q "inode $LIVE is allocated" <<<"$OUT" &&
    pass "ino $LIVE spared: a live peer still reads it" ||
    fail "ino $LIVE freed although a live, beating peer holds it open"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
