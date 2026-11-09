#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a journal entry aimed at Block Groups a live grow added is replayed, not dropped, by a node that has not caught up
#
# A peer can publish a live grow, allocate in the new space, journal a
# write there and die -- all before this node's next heartbeat. Replay
# asks which Block Group each target lies in, and the answer "outside
# every data region" drops the entry and lets the area be parked CLEAN.
# Against a layout that lags the device, that answer was wrong, and the
# torn block the entry would have repaired stayed torn for good
# (GROWFS-LIVE-REVIEW H1). cetrafs_bg_id_for_lba() now refreshes the
# layout before it says "outside", and says "cannot tell" (-EAGAIN,
# area left DIRTY) when the refresh fails.
#
# Staged on one node: grow_skip_local_publish commits a grow without
# switching this node, and layout_refresh_hb_off keeps the heartbeat
# from catching up on its own -- so the lookup is the only thing that
# can learn the new layout. A dead peer's journal then holds one entry
# for a block in the new Block Group. journal_ignore_guard takes the
# freshly-allocated and freed-since checks out of the way (the block was
# never really allocated here); they are not what is tested, and with
# them in place the entry would be consumed without a write, so the
# block's content would not tell the two outcomes apart.
#
#  A. first replay: the refresh is made to fail (layout_refresh_fail_once)
#     -> "could not tell", the area stays dirty; a later replay
#     refreshes, applies the entry, and the block holds the payload.
#  B. a target past the end of the GROWN volume (on the device, in no
#     Block Group) is still refused as outside every data region: the
#     refresh made the answer current, it did not make it permissive.
#
# DISCRIMINATION: with cetrafs_bg_id_for_lba() not refreshing, A's entry
# is dropped as "outside every BG data region", the area is parked
# clean, and the block never receives the payload (2026-11-08).
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODEPOKE="$(ct_helper node_poke)"
JPOKE="$(ct_helper journal_poke)"

IMG="$(ct_big_image 2100 growreplay)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt growreplay)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2
ct_param_set grow_skip_local_publish 0
ct_param_set layout_refresh_hb_off 0
ct_param_set layout_refresh_fail_once 0
ct_param_set journal_ignore_guard 0

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
blk() { dd if="$IMG" bs=4096 skip="$1" count=1 status=none | sha256sum | cut -d' ' -f1; }
wait_blk() { # <lba> <sum> <secs>
    local i
    for i in $(seq 1 "$3"); do
        [ "$(blk "$1")" = "$2" ] && return 0
        sleep 1
    done
    return 1
}

ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 4 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(info this_node_id)"
PEER=$(((NID + 1) % 4))

# ------------------------------------------------------------ the grow
ct_param_set layout_refresh_hb_off 1
gen0="$(info layout_gen)"
ct_param_set grow_skip_local_publish 1
out="$(ct_growfs "$DEV" -s 1400M 2>&1)" || { fail "setup: the grow failed: $(tail -2 <<<"$out")"; ct_exit; }
[ "$(cat /sys/module/cetrafs/parameters/grow_skip_local_publish)" = "N" ] ||
    { fail "setup: the grow did not consume grow_skip_local_publish"; ct_exit; }
[ "$(info layout_gen)" = "$gen0" ] ||
    { fail "setup: this node switched to the grown layout itself -- nothing would lag"; ct_exit; }
NEWBG="$(sed -n 's/.*new BG regions: LBA \([0-9][0-9]*\) .*/\1/p' <<<"$out")"
[ -n "$NEWBG" ] || { fail "setup: growfs did not say where the new Block Group is"; ct_exit; }
TARGET=$((NEWBG + 65536)) # the middle of the new 512 MiB Block Group: data, not header
pass "setup: the grow is on the device; this node is still at layout_gen $gen0; target block $TARGET"

# ------------------------------------------------------------------- A
log "A: an entry into the new Block Group, replayed by a node that lags"
PAY="$(ct_tmp growreplay-pay)"
head -c 4096 /dev/urandom >"$PAY"
WANT="$(sha256sum <"$PAY" | cut -d' ' -f1)"
[ "$(blk "$TARGET")" != "$WANT" ] || { fail "A: setup: the target already holds the payload"; ct_exit; }
ct_param_set journal_ignore_guard 1
ct_param_set layout_refresh_fail_once 1
MARK="$(dmesg_mark)"
"$NODEPOKE" "$IMG" "$PEER" 1 ee 0 >/dev/null 2>&1 # REGISTERED, last_seen=0: stale at once
"$JPOKE" "$IMG" "$PEER" 0 "$TARGET" "$PAY" >/dev/null 2>&1
GOT=""
wait_blk "$TARGET" "$WANT" 40 && GOT=1
LEFT="$(cat /sys/module/cetrafs/parameters/layout_refresh_fail_once)"
ct_param_set layout_refresh_fail_once 0
D="$(dmesg_since "$MARK")"
if grep -q "target block $TARGET, which is outside every BG data region" <<<"$D"; then
    fail "A: the entry was dropped as outside every data region -- the lagging layout was taken as current"
else
    pass "A: the entry was never judged outside every data region"
fi
[ -n "$GOT" ] && pass "A: a later replay applied the entry (the block holds its payload)" ||
    fail "A: the entry was lost: the block in the new Block Group never received its payload"
[ "$LEFT" = N ] || { fail "A: setup: no refresh was attempted (layout_refresh_fail_once not consumed)"; ct_exit; }
grep -q "could not tell where target block $TARGET lies" <<<"$D" &&
    pass "A: the failed refresh left the entry for the next replay ('could not tell')" ||
    fail "A: the failed refresh was not reported as 'could not tell'"
[ "$(info layout_gen)" = "$((gen0 + 1))" ] && pass "A: the lookup brought this node to layout_gen $((gen0 + 1))" ||
    fail "A: this node is at layout_gen $(info layout_gen), not $((gen0 + 1))"

# ------------------------------------------------------------------- B
log "B: a target past the end of the grown volume is still refused"
TOTAL="$(info total_blocks)"
DEVB=$(($(blockdev --getsize64 "$DEV") / 4096))
OUT=$((TOTAL + 16))
[ "$OUT" -lt "$DEVB" ] || { fail "B: setup: the device has no room past the volume ($TOTAL of $DEVB blocks)"; ct_exit; }
PEER2=$(((NID + 2) % 4))
r0="$(info layout_refresh_refused)"
MARK="$(dmesg_mark)"
SUM0="$(blk "$OUT")"
"$NODEPOKE" "$IMG" "$PEER2" 1 ee 0 >/dev/null 2>&1
"$JPOKE" "$IMG" "$PEER2" 0 "$OUT" "$PAY" >/dev/null 2>&1
for _ in $(seq 1 30); do
    dmesg_since "$MARK" | grep -q "target block $OUT, which is outside every BG data region" && break
    sleep 1
done
dmesg_since "$MARK" | grep -q "target block $OUT, which is outside every BG data region" &&
    pass "B: refused as outside every data region" ||
    fail "B: a target past the grown volume was not refused as outside every region"
[ "$(blk "$OUT")" = "$SUM0" ] && pass "B: and nothing was written there" || fail "B: the block past the volume was written"
[ "$(info layout_refresh_refused)" = "$r0" ] && pass "B: the refresh found the layout current (not refused)" ||
    fail "B: a refresh was refused while judging a target past the end"
ct_param_set journal_ignore_guard 0
ct_param_set layout_refresh_hb_off 0
ct_umount "$MNT"
ct_exit
