#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a record publish never carries an extent root ahead of the tree blocks it points through
#
# Tree edits are held back until a durability boundary (leafdefer.c);
# the root lives in the inode's shadow, and any record publish --
# writeback's, sync's -- carried it to the device. A convert that shrank
# an extent in leaf L (held back) and appended the written block to a
# new leaf N (written at once) published a root naming both: a crash
# then left the old L, whose extent still covers the block, and N, which
# names it too -- one block named twice, freed twice by a later delete
# (audit 2026-11-15 B-23). A publish now writes the held set first, and
# while any of it stays held it keeps the device's root.
#
# A preallocated file whose one leaf is full (writes to 1, 3, ..., 251
# split its extent), then a write to 253 through a held fd: L shrinks
# (held back), N takes the block. tree_flush_skip_all keeps the set held
# through a syncfs, which runs the record publish; the backing file is
# copied there -- the device a crash leaves -- and fsck'd.
#   (the control is the setup check: it shows the copy damaged)
#   1. the copy has no block named twice: fsck reports no ERR.
#
# DISCRIMINATION: publish_root_ahead=1 (the old publish): the copy names
# block 253's block from two leaves, fsck ERR.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in publish_root_ahead tree_flush_skip_all; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt prat)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set publish_root_ahead 0
ct_param_set tree_flush_skip_all 0
export CETRAFS_PEER_PROBE_SECS=1 # the copy's row looks live: watched two beats, not the window
P=/sys/module/cetrafs/parameters

# <old 0|1> -> "leaves=<before>/<after> fsck=<clean|ERR> why=<first ERR>"
round() {
    local img dev t copy out l0 l1 ino
    img="$(ct_image 560 "prat$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    fallocate -l $((1024 * 4096)) "$MNT/f"
    python3 -I - "$MNT/f" <<'PY'
import os, sys, mmap
m = mmap.mmap(-1, 4096)
for b in range(1, 252, 2):
    m.seek(0); m.write(((b'blk%08d' % b) * 512)[:4096])
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT); os.pwrite(fd, m, b * 4096); os.close(fd)
PY
    ino="$(stat -c %i "$MNT/f")"
    l0="$(filefrag "$MNT/f" 2>/dev/null | grep -o '[0-9]* extent' | grep -o '[0-9]*')"
    t="$(ct_tmp "prat-ctl$1")"
    rm -rf "$t"; mkdir -p "$t"
    echo "$1" >$P/publish_root_ahead
    echo 1 >$P/tree_flush_skip_all
    python3 -I - "$MNT/f" "$t" <<'PY' &
import os, sys, mmap, time
m = mmap.mmap(-1, 4096); m.write(((b'blk%08d' % 253) * 512)[:4096])
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
os.pwrite(fd, m, 253 * 4096)
open(os.path.join(sys.argv[2], "w"), "w").close()
while not os.path.exists(os.path.join(sys.argv[2], "close")):
    time.sleep(0.05)
os.close(fd)
PY
    local wpid=$!
    while [ ! -e "$t/w" ]; do sleep 0.05; done
    l1="$(filefrag "$MNT/f" 2>/dev/null | grep -o '[0-9]* extent' | grep -o '[0-9]*')"
    sync -f "$MNT" 2>/dev/null || true # the record publish; the held set stays held
    copy="$(ct_tmp "prat-copy$1")"
    cp --sparse=always "$img" "$copy"
    echo 0 >$P/tree_flush_skip_all
    echo 0 >$P/publish_root_ahead
    touch "$t/close"
    wait "$wpid" || true
    ct_umount "$MNT"
    local cdev
    cdev="$(ct_loop "$copy")"
    out="$(ct_fsck "$cdev" 2>&1 || true)"
    losetup -d "$cdev" 2>/dev/null || true
    local why
    why="$(grep -m1 '^ERR' <<<"$out" | tr ' ' '_' | cut -c1-120)"
    grep -qE '^ERR' <<<"$out" && out=ERR || out=clean
    echo "leaves=$l0/$l1 fsck=$out why=${why:-none}"
}
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

R="$(round 0)"
log "fixed: $R"
C="$(round 1)"
log "control (root published ahead): $C"
[ "$(get fsck "$R")" = clean ] && pass "1: the copy taken after the publish names no block twice; fsck clean" ||
    fail "1: the copy is damaged: $(get why "$R")"
[ "$(get fsck "$C")" = ERR ] && pass "control: with the root ahead of its leaf the copy is damaged ($(get why "$C"))" ||
    fail "control: the old publish left a clean copy -- the suite does not reach the held-back leaf"
ct_exit
