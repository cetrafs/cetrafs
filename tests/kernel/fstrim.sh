#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fstrim gives back the free space inside Block Groups still in use, touching no live block and no metadata
#
# The hand-back (discard_handback.sh) covers a Block Group that goes
# empty. Space freed inside one that stays in use -- a guest's TRIM
# punching holes in a VM image, every other file of a set deleted --
# only goes back when an operator runs fstrim (FITRIM, discard.c).
#
# The oracle is the loop device's backing file: `du` falls only if the
# discards really reached it.
#
#  1. holes in a Block Group that stays in use: fstrim reports the
#     bytes, the image shrinks by at least the holes, and every kept
#     file reads back what was written (cache dropped and remounted:
#     the bytes come from the device, not from memory).
#  2. a second fstrim with nothing new freed is harmless.
#  3. NEGATIVE CONTROL for the range check: the next discard is aimed
#     at the Block Group's first bitmap block and on into its first data
#     blocks (discard_aim_at_bitmap). It must be refused, counted, and
#     leave the volume consistent. DISCRIMINATION (2026-11-10, range
#     check removed): let through, it zeroes the bitmap that maps the
#     kept files and their first blocks, and fsck and the checksums
#     both fail.
# fsck clean after each.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v fstrim >/dev/null || { skip "no fstrim(8)"; ct_exit; }

IMG="$(ct_big_image 1200 fstrim)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fstrim)"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_param_set scrub 0 # nothing else freeing or discarding while the image is measured
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")"

used_kb() { du -k "$IMG" | awk '{ print $1 }'; }
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }
remount() {
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
}
# check_kept <tag>: every kept file still has its checksum, from the device.
check_kept() {
    local bad=0 i
    remount
    for i in $(seq 2 2 40); do
        [ "$(md5sum <"$MNT/f$i" | awk '{ print $1 }')" = "$(sed -n "${i}p" "$SUMS")" ] || bad=$((bad + 1))
    done
    [ "$bad" = 0 ] && pass "$1: all 20 kept files read back exactly what was written" ||
        fail "$1: $bad kept file(s) changed -- a live block was discarded"
}
fsck_clean() {
    local out
    ct_umount "$MNT"
    out="$(ct_fsck "$DEV" 2>&1)" && pass "$1: fsck clean" || fail "$1: fsck: $(grep -m3 -E '^ERR' <<<"$out")"
    ct_mount "$DEV" "$MNT"
}

SUMS="$(mktemp)"
ct_track file "$SUMS"

# ------------------------------------------------------------------- 1
log "1: holes inside a Block Group that stays in use"
for i in $(seq 1 40); do
    dd if=/dev/urandom of="$MNT/f$i" bs=1M count=4 conv=fsync status=none
    md5sum <"$MNT/f$i" | awk '{ print $1 }' >>"$SUMS"
done
sync
for i in $(seq 1 2 40); do rm -f "$MNT/f$i"; done
sync
sleep 3 # a heartbeat tick: anything it would hand back, it has
BEFORE="$(used_kb)"
[ "$BEFORE" -ge 150000 ] && pass "1 setup: the deleted files' 80 MiB still occupy the image ($((BEFORE / 1024)) MiB used)" ||
    { fail "1 setup: only $((BEFORE / 1024)) MiB used after the deletes -- the holes were given back already"; ct_exit; }
C0="$(info discard_cmds)"
T="$(fstrim -v "$MNT" 2>&1)" || fail "1: fstrim failed: $T"
BYTES="$(sed -n 's/.*(\([0-9]*\) bytes) trimmed.*/\1/p' <<<"$T")"
AFTER="$(used_kb)"
[ -n "$BYTES" ] && [ "$BYTES" -ge $((80 << 20)) ] && pass "1: fstrim reports $((BYTES >> 20)) MiB trimmed" ||
    fail "1: fstrim reported '$T'"
[ "$(info discard_cmds)" -gt "$C0" ] && pass "1: $(($(info discard_cmds) - C0)) discard command(s) issued" ||
    fail "1: no discard was counted"
[ $((BEFORE - AFTER)) -ge 76000 ] && pass "1: the image gave back $(((BEFORE - AFTER) / 1024)) MiB (the holes are 80)" ||
    fail "1: the image gave back only $(((BEFORE - AFTER) / 1024)) MiB of the 80 MiB of holes"
[ "$(info trim_leaked_blocks)" = 0 ] && pass "1: every claimed run was given back" ||
    fail "1: $(info trim_leaked_blocks) claimed block(s) left allocated"
check_kept 1
fsck_clean 1

# ------------------------------------------------------------------- 2
log "2: a second fstrim, nothing new freed"
T="$(fstrim -v "$MNT" 2>&1)" && pass "2: fstrim succeeded again: $T" || fail "2: fstrim failed: $T"
check_kept 2

# ------------------------------------------------------------------- 3
log "3: NEGATIVE CONTROL -- a discard aimed at metadata"
R0="$(info discard_refused)"
MARK="$(dmesg_mark)"
ct_param_set discard_aim_at_bitmap 1
fstrim "$MNT" >/dev/null 2>&1 || true
[ "$(cat /sys/module/cetrafs/parameters/discard_aim_at_bitmap)" = N ] ||
    fail "3 setup: no FITRIM discard consumed the aim (nothing was claimed?)"
[ "$(info discard_refused)" -gt "$R0" ] && pass "3: the discard aimed at the bitmap was refused" ||
    fail "3: a discard aimed at the bitmap was not refused"
dmesg_since "$MARK" | grep -q "is not inside BG .* data region .* refused" && pass "3: and said so" ||
    fail "3: no refusal in dmesg"
[ "$(info trim_leaked_blocks)" = 0 ] && pass "3: the run it was claimed for was still given back" ||
    fail "3: the refused run was left allocated"
check_kept 3
fsck_clean 3
ct_umount "$MNT"
ct_exit
