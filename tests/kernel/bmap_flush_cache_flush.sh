#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# allocation bits written for a publish are flushed out of the device cache before it
#
# The whole-record writer and the namespace CAS write the allocation
# bitmap first and wait for it -- and then wrote the record with no
# cache flush between. On a write-back LUN the two complete into cache
# and reach the media in either order: a power cut after the record and
# before the bitmap leaves a new directory or xattr block referenced and
# FREE (audit 2026-11-14 A2, rule 8). cetrafs_alloc_flush_bitmaps() now
# issues one cache flush after it writes any bits, which covers every
# publish; a call with nothing to write stays free.
#
# Counted on the loop device's flush requests (field 16 of its stat):
#   1. setxattrs that spill into a new xattr block (namespace CAS),
#   2. creates that grow a directory into a new dirent block (whole
#      record),
# each issue more flushes than with bmap_flush_no_cache_flush, and an
# idle flush (a chmod: no allocation) issues none of its own.
#
# DISCRIMINATION: bmap_flush_no_cache_flush, the old behaviour, in the
# same run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/bmap_flush_no_cache_flush ] || { skip "bmap_flush_no_cache_flush is missing"; ct_exit; }
IMG="$(ct_image 560 bmcf)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bmcf)"
ct_mkfs_small "$DEV" >/dev/null
ST="/sys/block/$(basename "$DEV")/stat"
[ "$(wc -w <"$ST")" -ge 17 ] || { skip "this kernel does not count flush requests in $ST"; ct_exit; }
flushes() { awk '{ print $16 }' "$ST"; }
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
ct_param_set bmap_flush_no_cache_flush 0
sleep 2

# <knob> <tag> -> flushes across: setxattr | dir growth | chmod
measure() {
    local b x d c i
    echo "$1" >/sys/module/cetrafs/parameters/bmap_flush_no_cache_flush
    : >"$MNT/x$2"
    mkdir "$MNT/d$2"
    sync
    b="$(flushes)"
    python3 -c 'import os, sys; [os.setxattr(sys.argv[1], "user.k%d" % k, b"v" * 200) for k in range(12)]' "$MNT/x$2"
    x=$(($(flushes) - b))
    b="$(flushes)"
    for i in $(seq 200); do : >"$MNT/d$2/name-long-enough-to-fill-a-block-$i"; done
    d=$(($(flushes) - b))
    sync
    b="$(flushes)"
    chmod 600 "$MNT/x$2"
    c=$(($(flushes) - b))
    echo 0 >/sys/module/cetrafs/parameters/bmap_flush_no_cache_flush
    echo "$x $d $c"
}
read -r X D C <<<"$(measure 0 a)"
read -r X0 D0 C0 <<<"$(measure 1 b)"
log "flushes: setxattr $X (control $X0), directory growth $D (control $D0), chmod $C (control $C0)"
[ "$X" -gt "$X0" ] && pass "a setxattr that allocates its block flushes the bitmap before publishing ($X vs $X0)" ||
    fail "a setxattr that allocates issued $X flush(es), $X0 without the bitmap flush -- none orders its bits"
[ "$D" -gt "$D0" ] && pass "a directory growing a block flushes the bitmap before publishing ($D vs $D0)" ||
    fail "directory growth issued $D flush(es), $D0 without the bitmap flush -- none orders its bits"
[ "$C" = "$C0" ] && pass "a publish that allocated nothing pays no extra flush ($C)" ||
    fail "a chmod issued $C flush(es) against $C0 -- an idle bitmap flush is not free"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q '^ERR' <<<"$out" && fail "fsck: $(grep '^ERR' <<<"$out" | head -3)" || pass "fsck clean"
ct_exit
