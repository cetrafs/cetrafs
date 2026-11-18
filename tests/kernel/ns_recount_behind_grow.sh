#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the namespace recount walks the device's inode table, not the one this node last caught up with
#
# Taking over a dead holder's namespace lock recounts the file's names
# (cetrafs_ns_count_names()), walking every allocated directory up to
# cetrafs_sb_inodes() -- this node's count. A directory in a segment a
# peer's grow appended, which this node has not caught up with, was past
# that bound: the file it names counted 0, and nlink 0 was published
# over a named file (format batch review H1; rule 6).
#
# Staged as ns_recount_fresh_bitmap.sh stages it, with two states of one
# volume: BEFORE (old/F, the inode table full) and AFTER, where a "peer"
# grew the volume (an inode segment appended) and ran mkdir new && mv
# old/F new/F -- new's number is in the new segment. This node mounts
# BEFORE and holds an fd on F; AFTER's superblock, tables and regions are
# written behind the mount, with layout_refresh_hb_off keeping the
# heartbeat from catching up; F's lock is handed to a dead peer and an
# fchmod through the fd takes it over and recounts.
#   setup: F at nlink 1 on the device, the dead peer's lock, new past
#          this node's inode count;
#   1. after the takeover F still says nlink 1, and new/F reads back.
#
# DISCRIMINATION: without the layout refresh in cetrafs_ns_count_names(),
# the recount publishes nlink 0.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
SB_POKE="$(ct_helper sb_poke)"
MNT="$(ct_mnt nrbg)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set hb_interval_secs 1
ct_param_set stale_secs "$TEST_STALE_SECS"
ct_param_set layout_refresh_hb_off 0
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }

IMG="$(ct_big_image 1200 nrbg)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
mkdir "$MNT/old" "$MNT/fill"
echo payload >"$MNT/old/F"
FI="$(stat -c %i "$MNT/old/F")"
# the table full, so the peer's mkdir lands in the segment its grow adds
python3 -I - "$MNT/fill" <<'PY'
import errno, os, sys
n = 0
while True:
    try:
        os.close(os.open(os.path.join(sys.argv[1], "f%d" % n), os.O_CREAT | os.O_EXCL | os.O_WRONLY))
    except OSError as e:
        if e.errno == errno.ENOSPC:
            break
        raise
    n += 1
PY
ct_umount "$MNT"
BEFORE="$(ct_tmp nrbg-before)"; cp --sparse=always "$IMG" "$BEFORE"
OUT="$(ct_growfs "$DEV" -s 1100M -N 1300 2>&1)" || { fail "setup: growfs: $OUT"; ct_exit; }
ct_mount "$DEV" "$MNT"
mkdir "$MNT/new"
mv "$MNT/old/F" "$MNT/new/F"
NI="$(stat -c %i "$MNT/new")"
ct_umount "$MNT"
AFTER="$(ct_tmp nrbg-after)"; cp --sparse=always "$IMG" "$AFTER"
[ "$NI" -gt 1024 ] || { fail "setup: new is inode $NI, inside the table this node knows"; ct_exit; }
eval "$("$SB_POKE" "$AFTER" | grep -E '^(node_table_start|bg_regions_start)=')"
log "F=$FI new=$NI; superblock and tables [0,$node_table_start), regions from $bg_regions_start"

cp --sparse=always "$BEFORE" "$IMG"
ct_mount "$DEV" "$MNT"
ct_param_set layout_refresh_hb_off 1
T="$(ct_tmp nrbg-sync)"
rm -rf "$T"; mkdir -p "$T"
python3 -I - "$MNT/old/F" "$T" <<'PY' &
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
WPID=$!
while [ ! -e "$T/w" ]; do sleep 0.05; done
# the peer's device, behind the mount: its superblock and tables (the
# grow's), and every region (the new segment among them)
dd if="$AFTER" of="$IMG" bs=4096 count="$node_table_start" conv=notrunc,fsync status=none
dd if="$AFTER" of="$IMG" bs=4096 skip="$bg_regions_start" seek="$bg_regions_start" conv=notrunc,fsync status=none
"$LOCK_POKE" "$IMG" "$FI" --ns 1 >/dev/null
poke_dead_peer "$DEV" 1 bb
SETUP="$("$LOCK_POKE" "$IMG" --rec "$FI") $("$LOCK_POKE" "$IMG" "$FI")"
KNOWN="$(info inodes_count)"
wait_out_stale_window
touch "$T/go"
wait "$WPID" || true
NL="$("$LOCK_POKE" "$IMG" --rec "$FI" | sed -n 's/.*nlink=\([0-9]*\).*/\1/p')"
umount "$MNT" 2>/dev/null || umount -l "$MNT"
ct_param_set layout_refresh_hb_off 0

grep -q 'nlink=1 ' <<<"$SETUP" && grep -q 'ns_owner=1 ' <<<"$SETUP " && [ "$KNOWN" = 1024 ] ||
    { fail "setup: F not at nlink 1 under the dead peer's lock, or this node not behind ($KNOWN inodes): $SETUP"; ct_exit; }
pass "setup: F at nlink 1, the dead peer's lock, and this node behind the grow ($KNOWN inodes, new=$NI)"
ct_mount "$DEV" "$MNT"
[ "$(cat "$MNT/new/F" 2>/dev/null)" = payload ] && RD=ok || RD=bad
ct_umount "$MNT"
[ "$NL" = 1 ] && [ "$RD" = ok ] && pass "1: the takeover's recount kept nlink 1; new/F reads back" ||
    fail "1: after the takeover: nlink=$NL, new/F reads $RD"
ct_exit
