#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an fsync whose tree flush failed does not publish the record over it
#
# fsync makes the bitmap bits and the extent-tree blocks durable, then
# publishes the record that names them. A step that failed was folded
# into the return value and the record published anyway: the size and
# the map named blocks whose tree was not on the device (rule 8; audit
# 2026-11-15 BL-22). The record now stays unpublished, dirty for the next
# boundary, and the fsync returns the error.
#
# Staged: a file whose map spilled into a leaf; an append past its end,
# its data written; the next tree flush fails (tree_flush_fail_once).
#   setup: the fsync failed;
#   1. the fsync wrote no record (record_writes did not move).
#
# DISCRIMINATION: fsync_publish_after_fail=1 -- the fsync writes the
# record over the failed flush.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in tree_flush_fail_once fsync_publish_after_fail; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
IPOKE="$(ct_helper inode_block_poke)"
MNT="$(ct_mnt fsff)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set tree_flush_fail_once 0
ct_param_set fsync_publish_after_fail 0

# <publish 0|1> -> "depth= failed= published="
round() {
    local img dev f ino depth=0 out
    img="$(ct_image 560 "fsff$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    f="$MNT/f"
    # Every other block: one extent each, so the map spills into a leaf.
    for i in $(seq 0 2 40); do
        dd if=/dev/urandom of="$f" bs=4096 count=1 seek="$i" conv=notrunc,fsync status=none
    done
    ino="$(stat -c %i "$f")"
    sync
    depth="$("$IPOKE" "$img" extents "$ino" | sed -n 's/.*depth=\([0-9]*\).*/\1/p' | head -1)"
    echo "$1" >/sys/module/cetrafs/parameters/fsync_publish_after_fail
    out="$(python3 -I - "$f" "$(ct_procdir "$dev")/info" <<'PY'
import os, sys
def writes():
    for l in open(sys.argv[2]):
        if l.startswith("record_writes:"):
            return int(l.split()[1])
fd = os.open(sys.argv[1], os.O_WRONLY)
os.pwrite(fd, b"A" * 4096, 60 * 4096)
w0 = writes()
open("/sys/module/cetrafs/parameters/tree_flush_fail_once", "w").write("1")
failed = 0
try:
    os.fsync(fd)
except OSError:
    failed = 1
print("failed=%d published=%d" % (failed, writes() - w0))
os.close(fd)
PY
)"
    echo 0 >/sys/module/cetrafs/parameters/tree_flush_fail_once
    echo 0 >/sys/module/cetrafs/parameters/fsync_publish_after_fail
    umount "$MNT" || umount -l "$MNT"
    echo "depth=${depth:-0} $out"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "held back: $R"
C="$(round 1)"
log "control (published): $C"
for v in "$R" "$C"; do
    [ "$(get depth "$v")" -ge 1 ] && [ "$(get failed "$v")" = 1 ] ||
        { fail "setup: no leaf, or the fsync did not fail ($v)"; ct_exit; }
done
pass "setup: the fsync over a spilled map failed in its tree flush"
[ "$(get published "$R")" = 0 ] && pass "1: the fsync published no record over its failed flush" ||
    fail "1: the record was published over the failed flush ($R)"
[ "$(get published "$C")" -ge 1 ] && pass "control: publishing anyway, the fsync wrote the record" ||
    fail "control: no record was written anyway -- the suite does not reach the publish ($C)"
ct_exit
