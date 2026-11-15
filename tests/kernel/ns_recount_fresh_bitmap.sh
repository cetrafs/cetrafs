#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the namespace recount finds a directory a peer created, not only the ones this node has seen
#
# Taking over a dead holder's namespace lock recounts the file's names
# (cetrafs_ns_count_names()), walking the directories the inode bitmap
# says exist -- from this node's CACHED bitmap, which changes only on its
# own swaps. A directory a peer created since was skipped, the file it
# names counted 0, and nlink 0 was published: the file freed while a name
# still reaches it (audit 2026-11-15 B-22). The walk now reads the bitmap
# fresh.
#
# Staged with two states of one volume: BEFORE (old/F) and AFTER, where a
# "peer" ran mkdir new && mv old/F new/F. This node mounts BEFORE, holds
# an fd on F, and its mount caches the inode bitmap. AFTER's tables and
# data regions are then written behind the mount (the backing file, not
# the loop device, so the cache keeps BEFORE's bitmap) -- the device a
# peer leaves -- and F's namespace lock is handed to a dead peer. An
# fchmod through the held fd takes the lock over and recounts.
#   setup: F has nlink 1 on the device and the lock is the dead peer's;
#   1. after the takeover, F's record still says nlink 1, and new/F reads
#      back after a remount.
#
# DISCRIMINATION: ns_count_cached_bmap=1 (the cached bitmap): nlink 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/ns_count_cached_bmap ] || { skip "ns_count_cached_bmap is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
SB_POKE="$(ct_helper sb_poke)"
MNT="$(ct_mnt nrfb)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set hb_interval_secs 1
ct_param_set stale_secs "$TEST_STALE_SECS"

IMG="$(ct_image 560 nrfb)"
DEV="$(ct_loop "$IMG")"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
mkdir "$MNT/old"
echo payload >"$MNT/old/F"
FI="$(stat -c %i "$MNT/old/F")"
ct_umount "$MNT"
BEFORE="$(ct_tmp nrfb-before)"; cp --sparse=always "$IMG" "$BEFORE"
ct_mount "$DEV" "$MNT"
mkdir "$MNT/new"
mv "$MNT/old/F" "$MNT/new/F"
NI="$(stat -c %i "$MNT/new")"
ct_umount "$MNT"
AFTER="$(ct_tmp nrfb-after)"; cp --sparse=always "$IMG" "$AFTER"
eval "$("$SB_POKE" "$AFTER" | grep -E '^(inode_bmap_start|node_table_start|bg_regions_start)=')"
log "F=$FI new=$NI; tables [$inode_bmap_start,$node_table_start), regions from $bg_regions_start"

# <old 0|1> -> "nlink=<n> reads=<ok|bad>"
round() {
    local t nl rd
    cp --sparse=always "$BEFORE" "$IMG"
    echo "$1" >/sys/module/cetrafs/parameters/ns_count_cached_bmap
    ct_mount "$DEV" "$MNT"
    t="$(ct_tmp "nrfb-ctl$1")"
    rm -rf "$t"; mkdir -p "$t"
    python3 -I - "$MNT/old/F" "$t" <<'PY' &
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
open(os.path.join(sys.argv[2], "w"), "w").close()
while not os.path.exists(os.path.join(sys.argv[2], "go")):
    time.sleep(0.05)
try:
    os.fchmod(fd, 0o600)
except OSError as e:
    print("fchmod: %s" % e, file=sys.stderr)
os.close(fd)
PY
    local wpid=$!
    while [ ! -e "$t/w" ]; do sleep 0.05; done
    # the peer's device, behind the mount: its tables and data regions
    dd if="$AFTER" of="$IMG" bs=4096 skip="$inode_bmap_start" seek="$inode_bmap_start" \
        count=$((node_table_start - inode_bmap_start)) conv=notrunc,fsync status=none
    dd if="$AFTER" of="$IMG" bs=4096 skip="$bg_regions_start" seek="$bg_regions_start" conv=notrunc,fsync status=none
    "$LOCK_POKE" "$IMG" "$FI" --ns 1 >/dev/null
    poke_dead_peer "$DEV" 1 bb
    SETUP="$("$LOCK_POKE" "$IMG" --rec "$FI") $("$LOCK_POKE" "$IMG" "$FI")"
    wait_out_stale_window
    touch "$t/go"
    wait "$wpid" || true
    nl="$("$LOCK_POKE" "$IMG" --rec "$FI" | sed -n 's/.*nlink=\([0-9]*\).*/\1/p')"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >/sys/module/cetrafs/parameters/ns_count_cached_bmap
    ct_mount "$DEV" "$MNT"
    [ "$(cat "$MNT/new/F" 2>/dev/null)" = payload ] && rd=ok || rd=bad
    ct_umount "$MNT"
    echo "nlink=$nl reads=$rd setup=[$SETUP]"
}
get() { grep -o "$1=[0-9a-zA-Z]*" <<<"$2" | head -1 | cut -d= -f2; } # the first: setup= repeats names

R="$(round 0)"
log "fixed: $R"
C="$(round 1)"
log "control (cached bitmap): $C"
grep -q 'nlink=1 ' <<<"${R#*setup=}" && grep -q 'ns_owner=1 ' <<<"${R#*setup=} " ||
    { fail "setup: F was not at nlink 1 with the dead peer's lock ($R)"; ct_exit; }
pass "setup: F at nlink 1 on the device, its lock the dead peer's"
[ "$(get nlink "$R")" = 1 ] && [ "$(get reads "$R")" = ok ] && pass "1: the takeover's recount kept nlink 1; new/F reads back" ||
    fail "1: after the takeover: nlink=$(get nlink "$R") reads=$(get reads "$R")"
[ "$(get nlink "$C")" = 0 ] && pass "control: with the cached bitmap the recount published nlink 0 over a named file" ||
    fail "control: the cached bitmap kept nlink $(get nlink "$C") -- the suite does not reach the stale walk"
ct_exit
