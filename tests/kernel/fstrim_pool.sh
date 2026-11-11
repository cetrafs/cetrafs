#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fstrim reaches space handed back to the pool while discard was off
#
# An emptied Block Group goes back to the unowned pool and is discarded
# on the way out -- but only while discard is on. Handed back with
# discard off (`nodiscard`, or discard=off in controls), it reached the
# pool still mapped, and nothing ever trimmed it: FITRIM walked only the
# groups a node owns. Measured on an FC array: 200 GiB freed, 1 GiB
# trimmed (docs/internal/UNMAP-BENCHMARK.md).
#
# FITRIM now has a pool pass: it claims each pool group not marked
# DISCARDED, hands it straight back through the ordinary release (which
# discards it and sets the mark), and skips marked groups, so a pool is
# trimmed once. A claim clears the mark, and so does a release that
# did not discard: a group that held data is never pooled marked.
#
# A loop device turns a discard into a hole in the backing file, so the
# image's allocated size is what the array would get back.
#
# DISCRIMINATION: with fitrim_skip_pool (the old FITRIM) case 1's fstrim
# gives the space back to nobody, and case 2 asserts exactly that before
# the real pass runs.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fstrim >/dev/null || { skip "no fstrim(8)"; ct_exit; }

BGPOKE="$(ct_helper bg_poke)"
IMG="$(ct_big_image 1200 fstpool)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fstpool)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }

ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
BG0_FREE="$("$BGPOKE" "$IMG" 0 --dump | sed -n 's/.*free_data_blocks=\([0-9]*\).*/\1/p')"
[ -n "$BG0_FREE" ] && [ "$BG0_FREE" -gt 1024 ] || { fail "setup: cannot read Block Group 0's free count"; ct_exit; }
ct_param_set scrub 0
compress_timing
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"
# Block Group 0 full, so the bulk below lands in Block Group 1, which the
# delete empties and the heartbeat hands back to the pool.
fallocate -l $(((BG0_FREE - 256) * 4096)) "$MNT/pad"
dd if=/dev/urandom of="$MNT/keep" bs=1M count=1 conv=fsync status=none
KEEP="$(md5sum <"$MNT/keep")"
sync

used_kb() { du -k "$IMG" | awk '{ print $1 }'; }
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }

# Write 96 MiB, delete it, wait for the emptied group to go to the pool.
fill_delete_handback() {
    local mark i
    mkdir "$MNT/bulk"
    for i in 1 2 3; do dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=32 conv=fsync status=none; done
    sync
    mark="$(dmesg_mark)"
    rm -rf "$MNT/bulk"
    sync
    wait_for 20 "dmesg_since '$mark' | grep -q 'handed back from ZG'" || return 1
    sleep 2 # the rest of the pass
}

# ------------------------------------------------------------------- 1
log "1: a group handed back with discard off stays mapped"
echo "discard=off" >"$PROC/controls"
EMPTY="$(used_kb)"
HB0="$(info discard_handback_bgs)"
fill_delete_handback || { fail "1 setup: the emptied Block Group was never handed back"; ct_exit; }
POOLED="$(used_kb)"
[ $((POOLED - EMPTY)) -ge 90000 ] && pass "1 setup: the pool group still holds $(((POOLED - EMPTY) / 1024)) MiB of the image" ||
    { fail "1 setup: only $(((POOLED - EMPTY) / 1024)) MiB left mapped after the hand-back"; ct_exit; }
[ "$(info discard_handback_bgs)" = "$HB0" ] && pass "1 setup: and the hand-back discarded nothing" ||
    { fail "1 setup: the hand-back discarded with discard off"; ct_exit; }
echo "discard=on" >"$PROC/controls"

# ------------------------------------------------------------------- 2
log "2: NEGATIVE CONTROL -- fstrim without the pool pass"
ct_param_set fitrim_skip_pool 1
fstrim "$MNT" >/dev/null 2>&1 || fail "2: fstrim failed"
ct_param_set fitrim_skip_pool 0
[ $((POOLED - $(used_kb))) -lt 16000 ] && pass "2: the old FITRIM gives back $(((POOLED - $(used_kb)) / 1024)) MiB of the pool's $(((POOLED - EMPTY) / 1024))" ||
    fail "2: fstrim without the pool pass gave back $(((POOLED - $(used_kb)) / 1024)) MiB -- 3 measures something else"

# ------------------------------------------------------------------- 3
log "3: fstrim trims the pool"
BEFORE="$(used_kb)"
HB1="$(info discard_handback_bgs)"
T="$(fstrim -v "$MNT" 2>&1)" || fail "3: fstrim failed: $T"
AFTER="$(used_kb)"
[ $((BEFORE - AFTER)) -ge 90000 ] && pass "3: the image gave back $(((BEFORE - AFTER) / 1024)) MiB" ||
    fail "3: the image gave back only $(((BEFORE - AFTER) / 1024)) MiB of the pool's 96"
[ "$(info discard_handback_bgs)" -gt "$HB1" ] && pass "3: through the release's discard ($(($(info discard_handback_bgs) - HB1)) group(s))" ||
    fail "3: no hand-back discard was counted"
BYTES="$(sed -n 's/.*(\([0-9]*\) bytes) trimmed.*/\1/p' <<<"$T")"
[ -n "$BYTES" ] && [ "$BYTES" -ge $((96 << 20)) ] && pass "3: and fstrim reports it ($((BYTES >> 20)) MiB)" ||
    fail "3: fstrim reported '$T'"

# ------------------------------------------------------------------- 4
log "4: a second fstrim leaves the pool alone"
HB2="$(info discard_handback_bgs)"
fstrim "$MNT" >/dev/null 2>&1 || fail "4: fstrim failed"
[ "$(info discard_handback_bgs)" = "$HB2" ] && pass "4: the group marked DISCARDED was not discarded again" ||
    fail "4: the pool was discarded again ($(($(info discard_handback_bgs) - HB2)) group(s)) -- the mark is not kept"

# ------------------------------------------------------------------- 5
log "5: a group that held data again is not left marked"
echo "discard=off" >"$PROC/controls"
EMPTY="$(used_kb)"
fill_delete_handback || { fail "5 setup: the emptied Block Group was never handed back"; ct_exit; }
[ $(($(used_kb) - EMPTY)) -ge 90000 ] || { fail "5 setup: the reused group left nothing mapped"; ct_exit; }
echo "discard=on" >"$PROC/controls"
HB3="$(info discard_handback_bgs)"
BEFORE="$(used_kb)"
fstrim "$MNT" >/dev/null 2>&1 || fail "5: fstrim failed"
[ $((BEFORE - $(used_kb))) -ge 90000 ] && [ "$(info discard_handback_bgs)" -gt "$HB3" ] &&
    pass "5: the group claimed and freed again was trimmed again" ||
    fail "5: the reused group was skipped: it went back to the pool still marked DISCARDED"

# ------------------------------------------------------------------- end
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(md5sum <"$MNT/keep")" = "$KEEP" ] && pass "the kept file reads back exactly what was written" ||
    fail "the kept file changed -- a live block was discarded"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" || fail "fsck: $(grep -m3 -E '^ERR' <<<"$OUT")"
ct_exit
