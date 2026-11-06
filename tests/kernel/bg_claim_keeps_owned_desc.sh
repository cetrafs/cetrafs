#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# claiming a Block Group never drops the cached descriptors of the ones this node owns
#
# PERFORMANCE.md invariant 3: never invalidate a Block Group descriptor
# this node owns -- the allocator reads it per block. The claim scan
# force-read every descriptor to find a FREE one, its own included, so
# every claim attempt (each ENOSPC on a full volume makes one) threw the
# owned ones away (audit 2026-11-06 L26). An owned Block Group is never
# FREE, so the scan skips it.
#
# Staged: two Block Groups, the second poked FREE; the first filled so
# the allocator claims the second. A kprobe on cetrafs_invalidate_block()
# filtered on Block Group 0's descriptor block counts the drops; the
# suite skips where kprobes are unavailable.
#
# DISCRIMINATION: scanning its own, the claim drops BG 0's descriptor.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
SBP="$(ct_helper sb_poke)"

IMG="$(ct_image 1200 bgckeep)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bgckeep)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
"$POKE" "$DEV" 1 --owner 65535 >/dev/null
DESC0="$("$SBP" "$IMG" 2>/dev/null | sed -n 's/^bg_table_start=//p')" # never grown: BG 0 is its first entry
[ -n "$DESC0" ] || { fail "setup: no bg_table_start"; ct_exit; }
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
dd if=/dev/zero of="$MNT/warm" bs=4096 count=16 conv=fsync status=none
sync
OWNER0="$("$MAP" "$DEV" | awk '/^bg 1 /{split($3,a,"="); print a[2]}')"
[ "$OWNER0" = 65535 ] || { fail "setup: BG 1 is not FREE before the fill (owner $OWNER0)"; ct_umount "$MNT"; ct_exit; }

T=/sys/kernel/tracing
# A kprobe records nothing with tracing switched off, which would read as
# "no hits": say so instead of passing.
[ "$(cat "$T/tracing_on" 2>/dev/null)" = 1 ] || { skip "tracing is off (tracing_on != 1): a kprobe would record nothing"; ct_exit; }
EV=cetrafs_bgck_$$
kp_off() {
    echo 0 >"$T/events/kprobes/$EV/enable" 2>/dev/null || true
    echo "-:kprobes/$EV" >>"$T/kprobe_events" 2>/dev/null || true
}
echo "p:kprobes/$EV cetrafs:cetrafs_invalidate_block blk=\$arg2:u64" >>"$T/kprobe_events" 2>/dev/null ||
    { skip "cannot place a kprobe on cetrafs_invalidate_block"; ct_umount "$MNT"; ct_exit; }
echo "blk == $DESC0" >"$T/events/kprobes/$EV/filter"
: >"$T/trace"
echo 1 >"$T/events/kprobes/$EV/enable"
DD="$(dd if=/dev/zero of="$MNT/fill" bs=1M count=560 conv=fsync 2>&1 | tail -1 || true)"
log "fill: $DD"
HITS="$(grep -c "$EV:" "$T/trace" || true)"
kp_off
sync
OWNER1="$("$MAP" "$DEV" | awk '/^bg 1 /{split($3,a,"="); print a[2]}')"
log "BG 1 owner now $OWNER1; BG 0 descriptor (block $DESC0) dropped $HITS time(s) during the fill"
[ "$OWNER1" = 0 ] || { fail "setup: the fill never claimed BG 1 (owner $OWNER1)"; ct_umount "$MNT"; ct_exit; }
pass "setup: filling BG 0 made the allocator claim BG 1"
[ "$HITS" = 0 ] && pass "and no claim dropped the cached descriptor of BG 0, which this node owns" ||
    fail "the claim scan dropped BG 0's descriptor $HITS time(s) -- invariant 3"
rm -f "$MNT/fill"
ct_umount "$MNT"
ct_exit
