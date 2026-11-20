#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a publish whose cache flush the device refused stops the mount AND reports the failure
#
# Every extent-map publish (truncate, punch, fallocate, defrag) flushes
# the device cache after its swap, so the frees that follow cannot reach
# the device first. A refused flush stops the mount -- the publish
# landed, its durability is unknown -- and the publish then returned
# success: a punch or a fallocate told its caller it was done (audit
# 2026-11-15 BL-79). It now returns EIO. (A truncate is not the probe:
# what it does after the publish fails on a stopped mount anyway.)
#   setup: the flush was refused and the mount stopped;
#   1. the punch failed.
#
# B. A publish that landed and then failed is not undone: the callers
# used to free the new tree's blocks as if it had not landed, leaving the
# record naming free blocks -- held off only by the stop refusing every
# free. With the stop disabled (error_policy_off), so the fix is the only
# guard: a punch over a file with a tree leaf, its flush refused.
#   setup B: the file has a tree leaf, and the punch failed;
#   2. fsck finds no block in use but marked free.
#
# C. The same for a swap whose outcome is unknown (a timed-out command
# that could not be settled): it returns an error, may have landed, and
# the callers freed the new tree on the error alone. The publish now
# asks the record. Staged by a swap that lands and reports an error
# (fd_cas_lost_ack), on a truncate over a file with a tree leaf.
#   setup C: the file has a tree leaf, and the truncate failed;
#   3. fsck finds no block in use but marked free.
#
# DISCRIMINATION: fd_post_flush_stop_ok=1 -- the punch reports success
# on the stopped mount; fd_landed_hidden=1 -- B and C: the new tree's
# blocks are freed under the record.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in fd_post_flush_fail fd_post_flush_stop_ok fd_landed_hidden error_policy_off fd_cas_lost_ack; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt pfref)"
ct_track mnt "$MNT"
ct_param_set fd_post_flush_fail 0
ct_param_set fd_post_flush_stop_ok 0
ct_param_set fd_landed_hidden 0
ct_param_set error_policy_off 0
ct_param_set fd_cas_lost_ack 0
IPOKE="$(ct_helper inode_block_poke)"

# <stop_ok 0|1> -> "stopped= rc="
round() {
    local img dev proc mark stopped=0 rc=0
    img="$(ct_image 560 "pfref$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    dd if=/dev/urandom of="$MNT/f" bs=1M count=4 conv=fsync status=none
    echo "$1" >/sys/module/cetrafs/parameters/fd_post_flush_stop_ok
    mark="$(dmesg_mark)"
    echo 1 >/sys/module/cetrafs/parameters/fd_post_flush_fail
    # The punch's own answer, not the close's: on the stopped mount the
    # close cannot publish the times the punch moved, and fallocate(1)
    # reports that as its failure.
    rc="$(python3 -I - "$MNT/f" <<'PY2'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_long]
fd = os.open(sys.argv[1], os.O_RDWR)
rc = libc.fallocate(fd, 0x01 | 0x02, 0, 1 << 20)  # PUNCH_HOLE | KEEP_SIZE
print(0 if rc == 0 else ctypes.get_errno(), flush=True)
try:
    os.close(fd)
except OSError:
    pass
PY2
)" || rc=1
    echo 0 >/sys/module/cetrafs/parameters/fd_post_flush_fail
    echo 0 >/sys/module/cetrafs/parameters/fd_post_flush_stop_ok
    dmesg_since "$mark" | grep -q "refused a cache flush after a publish" &&
        [ "$(sed -n 's/^fenced: //p' "$proc/info")" = yes ] && stopped=1
    umount "$MNT" || umount -l "$MNT"
    echo "stopped=$stopped rc=$rc"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "reported: $R"
C="$(round 1)"
log "control (success reported): $C"
for v in "$R" "$C"; do
    [ "$(get stopped "$v")" = 1 ] || { fail "setup: the refused flush did not stop the mount ($v)"; ct_exit; }
done
pass "setup: the flush after the punch's publish was refused, and the mount stopped"
[ "$(get rc "$R")" != 0 ] && pass "1: the punch failed" || fail "1: the punch reported success ($R)"
[ "$(get rc "$C")" = 0 ] && pass "control: reporting success, the punch said it was done on a stopped mount" ||
    fail "control: the punch failed anyway -- the suite does not reach the publish ($C)"

# <hidden 0|1> <b|c> -> "leaf= rc= free="
round_b() {
    local img dev ino leaf=0 rc=0 free=0 o i
    img="$(ct_image 560 "pfref$2$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    dd if=/dev/urandom of="$MNT/f" bs=1M count=2 conv=fsync status=none
    for i in $(seq 1 2 63); do fallocate -p -o $((i * 4096)) -l 4096 "$MNT/f"; done
    sync
    ino="$(stat -c %i "$MNT/f")"
    ct_umount "$MNT"
    [ "$("$IPOKE" "$dev" extents "$ino" 2>/dev/null | awk '/depth=/{sub(/.*depth=/,""); print $1+0; exit}')" -gt 0 ] 2>/dev/null &&
        leaf=1
    ct_mount "$dev" "$MNT"
    echo "$1" >/sys/module/cetrafs/parameters/fd_landed_hidden
    if [ "$2" = b ]; then
        echo 1 >/sys/module/cetrafs/parameters/error_policy_off
        echo 1 >/sys/module/cetrafs/parameters/fd_post_flush_fail
        fallocate -p -o $((70 * 4096)) -l $((8 * 4096)) "$MNT/f" 2>/dev/null || rc=$?
        echo 0 >/sys/module/cetrafs/parameters/fd_post_flush_fail
    else
        echo 1 >/sys/module/cetrafs/parameters/fd_cas_lost_ack
        truncate -s $((40 * 4096)) "$MNT/f" 2>/dev/null || rc=$?
        echo 0 >/sys/module/cetrafs/parameters/fd_cas_lost_ack
    fi
    umount "$MNT" || umount -l "$MNT"
    echo 0 >/sys/module/cetrafs/parameters/error_policy_off
    echo 0 >/sys/module/cetrafs/parameters/fd_landed_hidden
    o="$(ct_fsck "$dev" 2>&1 || true)"
    grep -q "in use but marked free" <<<"$o" && free=1
    grep -m3 "^ERR" <<<"$o" >&2 || true
    echo "leaf=$leaf rc=$rc free=$free"
}
R="$(round_b 0 b)"
log "landed, not undone: $R"
C="$(round_b 1 b)"
log "control (undone): $C"
for v in "$R" "$C"; do
    [ "$(get leaf "$v")" = 1 ] && [ "$(get rc "$v")" != 0 ] ||
        { fail "setup B: no tree leaf, or the punch did not fail ($v)"; ct_exit; }
done
pass "setup B: a punch over a file with a tree leaf failed after its publish landed"
[ "$(get free "$R")" = 0 ] && pass "2: nothing the record names was freed" ||
    fail "2: the record names blocks marked free ($R)"
[ "$(get free "$C")" = 1 ] && pass "control: undoing the landed publish freed blocks the record names" ||
    fail "control: nothing was freed anyway -- the suite does not reach the undo ($C)"

R="$(round_b 0 c)"
log "outcome unknown, asked the record: $R"
C="$(round_b 1 c)"
log "control (undone on the error): $C"
for v in "$R" "$C"; do
    [ "$(get leaf "$v")" = 1 ] && [ "$(get rc "$v")" != 0 ] ||
        { fail "setup C: no tree leaf, or the truncate did not fail ($v)"; ct_exit; }
done
pass "setup C: a truncate over a file with a tree leaf failed with its swap on the device"
[ "$(get free "$R")" = 0 ] && pass "3: nothing the record names was freed" ||
    fail "3: the record names blocks marked free ($R)"
[ "$(get free "$C")" = 1 ] && pass "control: undone on the error alone, blocks the record names were freed" ||
    fail "control: nothing was freed anyway -- the suite does not reach the undo ($C)"
ct_exit
