#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the boundary fence witness trusts no clock, and covers the record publish
#
# B-18 made a boundary read this node's row fresh before writing shared
# state -- but skipped the read when the last one was under a second old
# by jiffies, the clock a paused node cannot trust, and only the bitmap
# flush, the held-bitmap flush and the discards asked at all: the
# journal, the tree batches and the record publish still asked the clock
# alone (review F-8). Callers now share a read only when it started after
# they arrived, and those three ask the device too.
#
# The blind tick of fence_witness_boundary.sh (fence_skip_precheck and
# hb_renew_fail, the lease far longer than the suite); a peer's reclaim
# is the epoch bumped on the device.
#   A. an allocating fsync, the bump, at once another: the second fails
#      and the mount is fenced -- no second of grace;
#   B. a file written, 1.5 s, the bump, then an overwrite of its block
#      and fsync -- no allocation, so only the record publish writes: it
#      fails and the mount is fenced.
#
# DISCRIMINATION: fence_witness_f8_off=1 (the B-18 witness): both
# boundaries succeed and the mount is not fenced.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/fence_witness_f8_off ] || { skip "fence_witness_f8_off is missing"; ct_exit; }
NODE_POKE="$(ct_helper node_poke)"
MNT="$(ct_mnt fwu)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set fence_witness_f8_off 0
ct_param_set fence_skip_precheck 0
ct_param_set hb_renew_fail 0

# <case A|B> <old 0|1> -> "pre=<ok|err> post=<ok|err> fenced=<yes|no>"
round() {
    local dev proc out
    dev="$(ct_dev 560 "fwu$1$2")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    echo "$2" >/sys/module/cetrafs/parameters/fence_witness_f8_off
    echo 1 >/sys/module/cetrafs/parameters/fence_skip_precheck
    echo 1 >/sys/module/cetrafs/parameters/hb_renew_fail
    out="$(python3 -I - "$1" "$MNT" "$NODE_POKE" "$dev" <<'PY'
import os, sys, time, subprocess
case, mnt, poke, dev = sys.argv[1:5]
def fsync_write(name, flags):
    fd = None
    try:
        fd = os.open(os.path.join(mnt, name), flags, 0o644)
        os.pwrite(fd, os.urandom(4096), 0)
        os.fsync(fd)
        return "ok"
    except OSError:
        return "err"
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
pre = fsync_write("a", os.O_CREAT | os.O_WRONLY)
if case == "B":
    time.sleep(1.5)
subprocess.run([poke, dev, "0", "--bump-fence", "1"], check=True, stdout=subprocess.DEVNULL)
if case == "A":
    post = fsync_write("b", os.O_CREAT | os.O_WRONLY)
else:
    post = fsync_write("a", os.O_WRONLY)
print("pre=%s post=%s" % (pre, post))
sys.stdout.flush()
PY
)" || true
    local f
    f="$(sed -n 's/^shutdown: //p' "$proc/controls")"
    echo 0 >/sys/module/cetrafs/parameters/hb_renew_fail
    echo 0 >/sys/module/cetrafs/parameters/fence_skip_precheck
    echo 0 >/sys/module/cetrafs/parameters/fence_witness_f8_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    echo "$out fenced=$f"
}
get() { sed -n "s/.*$1=\([0-9a-zA-Z]*\).*/\1/p" <<<"$2"; }

for c in A B; do
    R="$(round $c 0)"
    log "$c fixed: $R"
    C="$(round $c 1)"
    log "$c control (B-18 witness): $C"
    [ "$(get pre "$R")" = ok ] && [ "$(get pre "$C")" = ok ] || { fail "$c setup: the boundary before the bump failed ($R | $C)"; continue; }
    [ "$(get post "$R")" = err ] && [ "$(get fenced "$R")" = yes ] &&
        pass "$c: the boundary after the bump failed and the mount fenced" ||
        fail "$c: after the bump: $R"
    [ "$(get post "$C")" = ok ] && [ "$(get fenced "$C")" = no ] &&
        pass "$c control: the B-18 witness let the boundary out after the bump" ||
        fail "$c control: the B-18 witness stopped it ($C) -- the case does not isolate F-8"
done
ct_exit
