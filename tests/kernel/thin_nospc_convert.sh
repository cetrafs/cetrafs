#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a full thin pool refuses a split's tree block before the extent is shrunk
#
# A write into the middle of a preallocated extent whose array is full
# shrinks that extent and appends the written block and the rest of it
# through the tree, into tree blocks reserved first. Since A-4 a new
# metadata block refused by a full thin pool is an ENOSPC for the
# operation, not a stop -- clean for a block nothing names, but this one
# came AFTER the shrink, which may already be on the device: the written
# block and the rest of the preallocation fell into a hole (B-2 re-opened).
# The reserved blocks are now written when they are reserved, so the
# pool says no before anything is edited; and an append still refused
# ENOSPC after a shrink stops the mount rather than leave the hole.
#
# One preallocated extent; O_DIRECT writes to blocks 1, 3, ..., 251 each
# split its tail in the middle (+2 entries), leaving its leaf at 253 of
# 254 -- and with no journal (-J 0) the shrink of a split is written to
# the device at once. The write to block 253 needs room. TEST ONLY
# new_block_nospc=1 makes the pool full for that write's new block.
#   1. the write fails ENOSPC and the mount keeps running;
#   2. nothing was given back and the preallocation is whole;
#   3. once the pool has room, the same write succeeds;
#   4. after a remount every written block reads back, the rest zeros; fsck clean.
#
# DISCRIMINATION: resv_provision_off=1 (reserve without writing): the
# refusal lands on the append after the shrink -- the mount stops. With
# that stop removed too, the written block's mapping is dropped (fsck:
# leaked), the window this suite was written for.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in new_block_nospc resv_provision_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt tnc)"
ct_track mnt "$MNT"
# The tree is filled a block-sized convert at a time; a 64 KiB convert
# unit would coalesce the scattered writes that fill it.
ct_param_set convert_unit_blocks 1
ct_param_set new_block_nospc 0
ct_param_set resv_provision_off 0
ct_param_set auto_defrag 0

# <provision_off 0|1> -> "w1=<rc> w3=<errno|ok> stopped=<yes|no> gb=<n> blocks=<before>/<after> again=<ok|errno> bad=<n> fsck=<clean|ERR|LEAK>"
round() {
    local dev proc g0 g1 out st b0 b1 again bad w
    dev="$(ct_dev 560 "tnc$1")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    fallocate -l $((NB * 4096)) "$MNT/f"
    w() { python3 -I -c "
import os, sys, mmap, errno
m = mmap.mmap(-1, 4096); b = int(sys.argv[2]); m.write(((b'blk%08d' % b) * 512)[:4096])
try:
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT); os.pwrite(fd, m, b * 4096); os.close(fd); print('ok')
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))" "$MNT/f" "$1"; }
    local w1 w3
    for b in $(seq 1 2 251); do
        w1="$(w "$b")"
        [ "$w1" = ok ] || break
    done
    b0="$(stat -c %b "$MNT/f")"
    g0="$(sed -n 's/^giveback_blocks: //p' "$proc/info")"
    echo "$1" >/sys/module/cetrafs/parameters/resv_provision_off
    echo 1 >/sys/module/cetrafs/parameters/new_block_nospc
    w3="$(w 253)"
    echo 0 >/sys/module/cetrafs/parameters/new_block_nospc
    echo 0 >/sys/module/cetrafs/parameters/resv_provision_off
    st="$(sed -n 's/^shutdown: //p' "$proc/controls" 2>/dev/null || echo yes)"
    g1="$(sed -n 's/^giveback_blocks: //p' "$proc/info" 2>/dev/null || echo "$g0")"
    b1="$(stat -c %b "$MNT/f" 2>/dev/null || echo 0)"
    again="$(w 253)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    bad=unread
    if [ "$st" = no ]; then
        ct_mount "$dev" "$MNT"
        bad="$(python3 -I -c "
import sys
d = open(sys.argv[1], 'rb').read()
bad = 0
for b in range(int(sys.argv[2])):
    want = ((b'blk%08d' % b) * 512)[:4096] if b % 2 and b <= 253 else bytes(4096)
    bad += d[b * 4096:(b + 1) * 4096] != want
print(bad)" "$MNT/f" "$NB")"
        ct_umount "$MNT"
    fi
    out="$(ct_fsck "$dev" 2>&1 || true)"
    if grep -qE '^ERR' <<<"$out"; then out=ERR; elif grep -q leaked <<<"$out"; then out=LEAK; else out=clean; fi
    echo "w1=$w1 w3=$w3 stopped=$st gb=$((g1 - g0)) blocks=$b0/$b1 again=$again bad=$bad fsck=$out"
}
NB=1024
get() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "provisioned: $R"
C="$(round 1)"
log "control (reserved unwritten): $C"
[ "$(get w1 "$R")" = ok ] || { fail "setup: the first write failed ($R)"; ct_exit; }
[ "$(get w3 "$R")" = ENOSPC ] && [ "$(get stopped "$R")" = no ] &&
    pass "1: the write failed ENOSPC, the mount kept running" || fail "1: $R"
[ "$(get gb "$R")" = 0 ] && [ "$(get blocks "$R" | cut -d/ -f1)" = "$(get blocks "$R" | cut -d/ -f2)" ] &&
    pass "2: nothing given back, the preallocation whole ($(get blocks "$R"))" || fail "2: $R"
[ "$(get again "$R")" = ok ] && pass "3: with room again the same write succeeds" || fail "3: $R"
[ "$(get bad "$R")" = 0 ] && [ "$(get fsck "$R")" = clean ] && pass "4: every written block reads back after a remount; fsck clean" ||
    fail "4: $R"
# Reached the post-shrink append: the stop -- or, without it, the damage
# (the written block's mapping dropped and leaked, a tail given back).
if [ "$(get stopped "$C")" = yes ]; then
    pass "control: refused after the shrink, the append stops the mount -- the window the provisioning closes"
elif [ "$(get fsck "$C")" != clean ] || [ "$(get gb "$C")" != 0 ]; then
    pass "control: refused after the shrink, the append destroyed state (fsck $(get fsck "$C"), $(get gb "$C") given back)"
else
    fail "control: the unprovisioned reservation did not reach the post-shrink append ($C)"
fi
ct_exit
