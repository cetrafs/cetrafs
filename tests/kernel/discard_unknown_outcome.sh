#!/usr/bin/env bash
# a discard whose outcome is unknown is treated as still to land: its blocks are not handed out
#
# A discard that fails on a timeout, a path failure or a plain I/O error
# may be a command the array runs anyway. If the blocks were handed out
# in between, that late UNMAP destroys whatever was written to them --
# silently, fsck sees nothing (bug class 30: a transport result read as
# definite). So only a failure that certainly did not execute (the
# target refused it: -EREMOTEIO; unsupported; invalid) lets the blocks
# go; any other keeps them:
#
#  A. FITRIM, unknown (-EIO): the claimed run stays allocated -- a leak
#     for the scrub, every block of it -- and the next writer is placed
#     elsewhere.
#  B. CONTRAST, definite (-EREMOTEIO): the same run is given back and the
#     next writer IS placed in it. Proves A's writer was kept out by the
#     verdict, not by the layout.
#  C. hand-back, unknown: the emptied Block Group is NOT handed back by
#     the pass whose discard failed; it is discarded again on a later
#     tick and handed back after that.
#  D. CONTRAST, definite: handed back in the same pass, no retry.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fstrim >/dev/null || { skip "no fstrim(8)"; ct_exit; }
for p in discard_fail_unknown discard_fail_definite; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
PP="$(ct_helper pending_poke)"
BGPOKE="$(ct_helper bg_poke)"

IMG="$(ct_big_image 1200 dunk)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dunk)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
PROC="$(ct_procdir "$DEV")"

ext() { "$PP" "$IMG" extent "$(stat -c %i "$1")" | awk '{ print $1 }'; }
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }
fresh() {
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
}

# hole: an 8 MiB hole at the front of the data, a kept file behind it.
hole() {
    fresh
    dd if=/dev/urandom of="$MNT/h" bs=1M count=8 conv=fsync status=none
    dd if=/dev/urandom of="$MNT/k" bs=1M count=8 conv=fsync status=none
    sync
    HOLE="$(ext "$MNT/h")"
    rm -f "$MNT/h"
    sync
}
in_hole() { [ "$1" -ge "$HOLE" ] && [ "$1" -lt $((HOLE + 2048)) ]; }
# leaked_in_hole: how many of the hole's blocks fsck finds allocated and unreferenced.
leaked_in_hole() {
    CETRAFS_FSCK_DUMP_LEAKS=1 ct_fsck "$DEV" 2>&1 |
        awk -v lo="$HOLE" -v hi=$((HOLE + 2048)) -F'lba=' '/^LEAK: lba=/ { if ($2 >= lo && $2 < hi) n++ } END { print n + 0 }'
}

# ------------------------------------------------------------------- A
log "A: FITRIM, a discard of unknown outcome"
hole
L0="$(info trim_leaked_blocks)"
ct_param_set discard_fail_unknown 1
fstrim -m 4M "$MNT" >/dev/null 2>&1 && fail "A: fstrim succeeded over a failed discard" ||
    pass "A: fstrim reports the failure"
ct_param_set discard_fail_unknown 0
[ "$(info trim_leaked_blocks)" = $((L0 + 2048)) ] && pass "A: the whole claimed run (2048 blocks) was kept" ||
    fail "A: kept $(($(info trim_leaked_blocks) - L0)) blocks, not the run's 2048"
dd if=/dev/urandom of="$MNT/w" bs=1M count=4 conv=fsync status=none
! in_hole "$(ext "$MNT/w")" && pass "A: the next writer was placed outside the kept run" ||
    fail "A: the next writer was given block $(ext "$MNT/w"), inside a run whose UNMAP may still land"
ct_umount "$MNT"
N="$(leaked_in_hole)"
[ "$N" = 2048 ] && pass "A: fsck finds all 2048 blocks allocated and unreferenced -- a leak for the scrub" ||
    fail "A: fsck finds $N of the run's 2048 blocks leaked"

# ------------------------------------------------------------------- B
log "B: CONTRAST -- a discard the target refused"
hole
L0="$(info trim_leaked_blocks)"
ct_param_set discard_fail_definite 1
fstrim -m 4M "$MNT" >/dev/null 2>&1 || true
ct_param_set discard_fail_definite 0
[ "$(info trim_leaked_blocks)" = "$L0" ] && pass "B: a refused discard keeps nothing" ||
    fail "B: a refused discard kept $(($(info trim_leaked_blocks) - L0)) blocks"
dd if=/dev/urandom of="$MNT/w" bs=1M count=4 conv=fsync status=none
in_hole "$(ext "$MNT/w")" && pass "B: and the next writer IS placed in the run -- A's writer was kept out by the verdict" ||
    fail "B setup: the next writer was not placed in the hole even when it was free: A proves nothing"
ct_umount "$MNT"
N="$(leaked_in_hole)"
[ "$N" = 0 ] && pass "B: fsck finds none of the run leaked" || fail "B: fsck finds $N blocks of the run leaked"

# ------------------------------------------------------------------- C/D
# handback <fail-param>: fill Block Group 0 with a preallocated file (it
# holds the root and never empties), put 96 MiB in group 1, delete it,
# and let the hand-back meet a failing discard. Sets LOG, HB (hand-back
# discards that succeeded meanwhile), ERRS.
handback() {
    local free mark i
    fresh
    ct_umount "$MNT"
    free="$("$BGPOKE" "$IMG" 0 --dump | sed -n 's/.*free_data_blocks=\([0-9]*\).*/\1/p')"
    ct_mount "$DEV" "$MNT"
    fallocate -l $(((free - 256) * 4096)) "$MNT/pad"
    mkdir "$MNT/bulk"
    for i in 1 2 3; do dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=32 conv=fsync status=none; done
    sync
    HB0="$(info discard_handback_bgs)"
    E0="$(info discard_errors)"
    mark="$(dmesg_mark)"
    ct_param_set "$1" 1
    rm -rf "$MNT/bulk"
    sync
    for i in $(seq 1 40); do
        dmesg_since "$mark" | grep -q "handed back from ZG" && break
        sleep 0.5
    done
    sleep 2
    ct_param_set "$1" 0
    LOG="$(dmesg_since "$mark")"
    HB=$(($(info discard_handback_bgs) - HB0))
    ERRS=$(($(info discard_errors) - E0))
}

log "C: hand-back, a discard of unknown outcome"
handback discard_fail_unknown
[ "$ERRS" = 1 ] || { fail "C setup: $ERRS discard error(s), not the one injected"; ct_exit; }
grep -q "handed back from ZG" <<<"$LOG" && pass "C: the emptied Block Group was handed back in the end" ||
    fail "C: the Block Group was never handed back"
[ "$HB" -ge 1 ] && pass "C: only after a later discard of it succeeded ($HB)" ||
    fail "C: handed back with no successful discard -- released over an UNMAP that may still land"
ct_umount "$MNT"

log "D: CONTRAST -- a discard the target refused"
handback discard_fail_definite
[ "$ERRS" = 1 ] || { fail "D setup: $ERRS discard error(s), not the one injected"; ct_exit; }
grep -q "handed back from ZG" <<<"$LOG" && pass "D: handed back" || fail "D: never handed back"
[ "$HB" = 0 ] && pass "D: in the same pass, with no retry -- so C's retry is the unknown verdict's doing" ||
    fail "D: a refused discard was retried ($HB)"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "D: fsck clean" || fail "D: fsck: $(grep -m3 -E '^ERR' <<<"$OUT")"
ct_exit
