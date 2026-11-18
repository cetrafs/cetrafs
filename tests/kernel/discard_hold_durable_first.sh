#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# what keeps a discarded range out of use is on the device before the discard is sent
#
# A discard that hangs in a multipath queue past this node's lease
# outlives the node: a peer takes the Zone Group over, recounts from the
# device, and allocates whatever reads free there -- and the queued UNMAP
# then lands on its data, fsck clean (audit 2026-11-15 B-21, B-37).
# Both holds were in this node's cache only while the command was out:
#   T. a FITRIM (and inline discard) claim sets the run's bits in the
#      cache; now they are synced before the discard is sent;
#   H. a hand-back flagged its emptied group DISCARD_PENDING only after
#      a discard failed; now the flag is set by compare-and-swap before
#      the UNMAP goes out, and the release clears it.
# Each discard is held just before it is sent (discard_issue_stall_ms)
# and the image is read meanwhile: T's run reads allocated in the
# group's bitmap, H's group reads flagged. Afterwards the group is
# handed back with the flag clear; fsck clean.
#
# DISCRIMINATION: trim_hold_sync_off=1: T's run reads free on the device
# while its discard waits. handback_flag_first_off=1: H's group reads
# unflagged while its UNMAP waits.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in discard_issue_stall_ms trim_hold_sync_off handback_flag_first_off; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
BGPOKE="$(ct_helper bg_poke)"
BMAP_POKE="$(ct_helper bmap_poke)"
IMG="$(ct_big_image 1200 dhdf)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dhdf)"
ct_track mnt "$MNT"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
P=/sys/module/cetrafs/parameters
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set discard_issue_stall_ms 0
ct_param_set trim_hold_sync_off 0
ct_param_set handback_flag_first_off 0
compress_timing

geom() { "$BGPOKE" "$IMG" "$1" --dump; }
field() { sed -n "s/.*[ ^]$1=\([0-9]*\).*/\1/p; s/^$1=\([0-9]*\).*/\1/p" | head -1; }
# bits_set <bg> <lba> <count>: how many of the run's bits read set on the image
bits_set() {
    local g s ob od
    g="$(geom "$1")"
    s="$(field start_block <<<"$g")" ob="$(field off_data_bmap <<<"$g")" od="$(field off_data_region <<<"$g")"
    "$BMAP_POKE" "$IMG" "$((s + ob))" count "$(($2 - s - od))" "$3"
}
flags_of() { geom "$1" | field flags; }

# --- T ----------------------------------------------------------------------
# <tag> <sync_off 0|1> -> RES
tround() {
    local mark line bg lba cnt set pid
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/f" bs=1M count=16 conv=fsync status=none
    rm -f "$MNT/f"
    sync
    echo "$2" >$P/trim_hold_sync_off
    echo 4000 >$P/discard_issue_stall_ms
    mark="$(dmesg_mark)"
    fstrim "$MNT" >/dev/null 2>&1 &
    pid=$!
    wait_for 20 "dmesg_since '$mark' | grep -q 'pausing .* before it is sent'" || true
    line="$(dmesg_since "$mark" | grep -m1 'pausing .* before it is sent' || true)"
    bg="$(sed -n 's/.* of BG \([0-9]*\):.*/\1/p' <<<"$line")"
    lba="$(sed -n 's/.*discard \[\([0-9]*\) +.*/\1/p' <<<"$line")"
    cnt="$(sed -n 's/.*discard \[[0-9]* +\([0-9]*\)).*/\1/p' <<<"$line")"
    set=""
    [ -n "$bg" ] && set="$(bits_set "$bg" "$lba" "$cnt")"
    echo 0 >$P/discard_issue_stall_ms
    wait "$pid" || true
    echo 0 >$P/trim_hold_sync_off
    ct_umount "$MNT"
    RES="bg=$bg count=${cnt:-0} set=${set:-none} fsck_err=$(ct_fsck "$DEV" 2>&1 | grep -cE '^ERR' || true)"
}

# --- H ----------------------------------------------------------------------
# <tag> <flag_first_off 0|1> -> RES
hround() {
    local mark free i fl after
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    free="$("$BGPOKE" "$DEV" 0 --dump | field free_data_blocks)"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    fallocate -l $(((free - 256) * 4096)) "$MNT/pad"
    mkdir "$MNT/bulk"
    for i in 1 2 3; do dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=32 conv=fsync status=none; done
    sync
    echo "$2" >$P/handback_flag_first_off
    echo 4000 >$P/discard_issue_stall_ms
    mark="$(dmesg_mark)"
    rm -rf "$MNT/bulk"
    sync
    fl=""
    if wait_for 60 "dmesg_since '$mark' | grep -q 'of BG 1: pausing .* before it is sent'"; then
        fl="$(flags_of 1)"
    fi
    echo 0 >$P/discard_issue_stall_ms
    wait_for 60 "dmesg_since '$mark' | grep -q 'BG 1 handed back'" || true
    echo 0 >$P/handback_flag_first_off
    ct_umount "$MNT"
    after="$(flags_of 1)"
    RES="during=${fl:-none} after=$after handed=$(dmesg_since "$mark" | grep -c 'BG 1 handed back' || true)"
    RES="$RES fsck_err=$(ct_fsck "$DEV" 2>&1 | grep -cE '^ERR' || true)"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

tround c 1
TC="$RES"
log "T control (hold not synced): $TC"
tround f 0
TR="$RES"
log "T: $TR"
[ "$(get set "$TR")" != none ] && [ "$(get count "$TR")" -gt 0 ] ||
    { fail "T setup: no FITRIM discard was held ($TR)"; ct_exit; }
[ "$(get set "$TR")" = "$(get count "$TR")" ] && [ "$(get fsck_err "$TR")" = 0 ] &&
    pass "T: all $(get count "$TR") bits of the claimed run were on the device before its discard was sent; fsck clean" ||
    fail "T: $TR"
[ "$(get set "$TC")" != none ] && [ "$(get set "$TC")" -lt "$(get count "$TC")" ] &&
    pass "control: unsynced, only $(get set "$TC") of $(get count "$TC") bits were on the device while the discard waited" ||
    fail "control T: ($TC) -- the suite cannot see the hold"

hround c 1
HC="$RES"
log "H control (flagged only after a failure): $HC"
hround f 0
HR="$RES"
log "H: $HR"
[ "$(get during "$HR")" != none ] || { fail "H setup: no hand-back discard of BG 1 was held ($HR)"; ct_exit; }
[ $(( $(get during "$HR") & 2 )) = 2 ] && [ $(( $(get after "$HR") & 2 )) = 0 ] && [ "$(get handed "$HR")" -ge 1 ] &&
    [ "$(get fsck_err "$HR")" = 0 ] &&
    pass "H: BG 1 read DISCARD_PENDING on the device while its UNMAP waited; handed back with the flag clear; fsck clean" ||
    fail "H: $HR"
[ "$(get during "$HC")" != none ] && [ $(( $(get during "$HC") & 2 )) = 0 ] &&
    pass "control: flagged only after a failure, BG 1 read unflagged while its UNMAP waited" ||
    fail "control H: ($HC) -- the suite cannot see the flag"
ct_exit
