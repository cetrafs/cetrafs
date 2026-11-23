#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# one Block Group whose descriptor cannot be read does not stop every publish on the node
#
# The boundary flush writes the allocation bitmap of every Block Group
# this node allocated from since the last boundary, and found each
# bitmap by reading the group's descriptor. When that read failed, the
# flush failed, put the mark back and refused the publish -- and since
# the mark is node-wide, so did every later fsync, close and namespace
# operation of every file, each finding the same mark (N-44). The
# bitmap's place is part of the layout the mount verified; the flush
# now falls back to that.
#
# One Zone Group of two or more Block Groups: a write marks BG 0's
# bitmap dirty, BG 0's descriptor is then damaged on the device and its
# cached copy dropped; an fsync of ANOTHER file must succeed, as must one of
# the first -- with the file's bits read back set off the device.
#
# DISCRIMINATION: bmap_flush_needs_desc=1 fails the flush on the
# descriptor, as before: both fsyncs fail (EIO).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
MNT="$(ct_mnt bfdu)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
[ -w /sys/module/cetrafs/parameters/bmap_flush_needs_desc ] || { skip "bmap_flush_needs_desc is missing"; ct_exit; }
ct_param_set bmap_flush_needs_desc 0
POKE="$(ct_helper csum_poke)"
EXTENT="$(ct_helper pending_poke)"
BG_POKE="$(ct_helper bg_poke)"
BMAP_POKE="$(ct_helper bmap_poke)"
SBP="$(ct_helper sb_poke)"

# <tag> <needs_desc 0|1> -> RES "<seen> <fsync other errno> <fsync a errno>"
round() {
    local img dev mark seen r1 r2 desc
    img="$(ct_image 1700 "bfdu$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$(ct_bgs_of_zg "$dev" 0 | wc -l)" -ge 2 ] || { RES="nobg"; return; }
    ct_mount "$dev" "$MNT"
    echo seed >"$MNT/other"
    sync
    echo "$2" >/sys/module/cetrafs/parameters/bmap_flush_needs_desc
    mark="$(dmesg_mark)"
    # A write into BG 0, kept open (a close is a boundary and would flush
    # it): its bitmap is dirty, in memory only, and marked. Then BG 0's
    # descriptor is damaged in the backing image and ITS page alone is
    # dropped from the device's cache (clean, so fadvise drops it; the
    # dirty bitmap pages stay) -- so the only way the file's bits reach
    # the device is the flush under test. Two fsyncs are asked for.
    desc="$("$SBP" "$img" | sed -n 's/^bg_table_start=\([0-9]*\)$/\1/p')"
    local g0 bstart nbits
    g0="$("$BG_POKE" "$img" 0 --dump)"
    bstart=$(( $(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$g0") + $(sed -n 's/.*off_data_bmap=\([0-9]*\).*/\1/p' <<<"$g0") ))
    nbits="$(sed -n 's/.*data_block_count=\([0-9]*\).*/\1/p' <<<"$g0")"
    read -r r1 r2 b0 b1 <<<"$(python3 -I -c '
import os, subprocess, sys
mnt, dev, poke, img, desc, bmp, bstart, nbits = sys.argv[1:9]
def ondev():
    return subprocess.run([bmp, img, bstart, "count", "0", nbits], capture_output=True, text=True).stdout.strip()
fa = os.open(mnt + "/a", os.O_WRONLY | os.O_CREAT, 0o644)
os.write(fa, os.urandom(1 << 20))
subprocess.run([poke, img, "bg-desc", "0"], check=True, stdout=subprocess.DEVNULL)
fd = os.open(dev, os.O_RDONLY)
os.posix_fadvise(fd, int(desc) * 4096, 4096, os.POSIX_FADV_DONTNEED)
os.close(fd)
before = ondev()
def tryfs(fd):
    try:
        os.fsync(fd)
        return "0"
    except OSError as e:
        return str(e.errno)
fo = os.open(mnt + "/other", os.O_WRONLY | os.O_APPEND)
os.write(fo, b"x")
r1 = tryfs(fo)
r2 = tryfs(fa)
after = ondev()
os.close(fo)
try:
    os.close(fa)
except OSError:
    pass
print(r1, r2, before, after)' "$MNT" "$dev" "$POKE" "$img" "$desc" "$BMAP_POKE" "$bstart" "$nbits")"
    echo 0 >/sys/module/cetrafs/parameters/bmap_flush_needs_desc
    seen="$(dmesg_since "$mark" | grep -c 'BG 0 failed its descriptor checksum' || true)"
    # What the fsync claims, read off the device: a's first extent's
    # bits set in BG 0's bitmap (the descriptor's fields still parse).
    local ino ext lba cnt g st ob od set=none
    ino="$(stat -c %i "$MNT/a")"
    ext="$("$EXTENT" "$dev" extent "$ino" 2>/dev/null || true)"
    lba="${ext%% *}"; cnt="$(cut -d' ' -f2 <<<"$ext")"
    g="$("$BG_POKE" "$dev" 0 --dump 2>/dev/null || true)"
    st="$(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$g")"
    ob="$(sed -n 's/.*off_data_bmap=\([0-9]*\).*/\1/p' <<<"$g")"
    od="$(sed -n 's/.*off_data_region=\([0-9]*\).*/\1/p' <<<"$g")"
    if [ -n "$lba" ] && [ -n "$cnt" ] && [ -n "$st" ] && [ "$lba" -ge $((st + od)) ]; then
        set="$("$BMAP_POKE" "$dev" "$((st + ob))" count "$((lba - st - od))" "$cnt")/$cnt"
    fi
    ct_umount "$MNT" 2>/dev/null || umount -l "$MNT"
    RES="$seen $r1 $r2 $set $b0 $b1"
}

round c 1
read -r CS C1 C2 _ _ _ <<<"$RES"
log "control (flush needs the descriptor): descriptor failures $CS, fsync other errno $C1, fsync a errno $C2"
round f 0
read -r S R1 R2 BITS B0 B1 <<<"$RES"
log "fixed: descriptor failures $S, fsync other errno $R1, fsync a errno $R2, a's first extent set on the device: $BITS, BG 0's bits on the device $B0 before the fsyncs and $B1 after"
[ "$S" != nobg ] && [ "${S:-0}" -ge 1 ] && pass "setup: BG 0's descriptor no longer reads" ||
    fail "setup: BG 0's descriptor still read ($RES)"
[ "$R1" = 0 ] && pass "1: an fsync of another file succeeded" || fail "1: fsync of another file: errno $R1"
[ "$R2" = 0 ] && pass "2: an fsync of the file in BG 0 succeeded" || fail "2: errno $R2"
[ "${BITS%/*}" = "${BITS#*/}" ] && [ "$BITS" != none ] && [ $((B1 - B0)) -ge "${BITS#*/}" ] &&
    pass "2: and its bits are on the device ($BITS of its first extent, written by the fsyncs: $B0 -> $B1)" ||
    fail "2: a's first extent reads $BITS set in BG 0's bitmap on the device (BG 0 $B0 -> $B1 across the fsyncs) -- the flush missed the bitmap"
[ "$C1" != 0 ] && [ "$C2" != 0 ] && pass "control: with the flush needing the descriptor both fsyncs failed" ||
    fail "control: fsyncs $C1 / $C2 -- the damage did not reach the flush"
ct_exit
