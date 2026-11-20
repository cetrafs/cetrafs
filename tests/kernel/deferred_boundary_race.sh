#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# two boundaries of one node on the same held-back set: the second never reads the first's write as a peer's
#
# A boundary collects a file's held-back tree blocks, with the device
# image each should have, and only then takes the file's claim. Another
# boundary of this node -- sync's, a writeback tick's, the file's own
# fsync or close -- could write and settle the same blocks in between.
# Judged by the images collected before, the device showed this node's
# own write: "another node wrote the file", the set dropped and the
# record's shadow with it. The file's newest extents were lost, written
# blocks reading as zeros, on a one-node volume (churn_oracle).
#
# Staged on one node: a file grown past the record's four slots, its new
# leaf's edit held back. A boundary sync starts for the file is held
# between its collect and its claim (deferred_collect_stall_ms); meanwhile
# the file's last close runs its own boundary, which writes and settles
# the same leaf. Then the held boundary resumes.
#   1. no set is dropped as a peer's write;
#   2. after a remount every written block holds its data;
#   3. fsck is clean.
# The loss itself needs a shadow not yet published when the set is
# dropped, which churn_oracle reaches and this staging does not: here the
# close publishes first. The false verdict is what drops it.
#
# DISCRIMINATION: deferred_snapshot_trusted=1 judges the set by the images
# collected before the claim: the same steps must read this node's own
# write as a peer's and drop the set.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in deferred_collect_stall_ms deferred_collect_stall_ino deferred_snapshot_trusted; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
DEV="$(ct_dev 560 dbrace)"
MNT="$(ct_mnt dbrace)"
ct_track mnt "$MNT"
compress_timing
for k in deferred_collect_stall_ms deferred_collect_stall_ino deferred_snapshot_trusted auto_defrag; do
    ct_param_set "$k" "$(cat $P/$k)"
done
ct_param_set auto_defrag 0
RES="$(ct_tmp dbrace-res)"

# <trusted 0|1>: writes "dropped=<n> lost=<n> extents=<n> fsck=<0|1>" to $RES
round() {
    local trusted="$1" f ino mark dropped lost fsck=0 ext
    ct_mkfs "$DEV" -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    f="$MNT/f"
    : >"$f"
    ino="$(stat -c %i "$f")"
    echo "$trusted" >"$P/deferred_snapshot_trusted"
    echo "$ino" >"$P/deferred_collect_stall_ino"
    mark="$(dmesg_mark)"
    # One process keeps the file open throughout: a last close is a
    # boundary of its own and would write the held set first.
    python3 - "$f" "$P/deferred_collect_stall_ms" <<'PY'
import os, subprocess, sys, time
path, stall = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_RDWR)
# Four one-block extents with holes between: the record's four slots,
# durable. A fifth grows the tree (a new leaf; the root that names it is
# the record's shadow until a publish), a sixth edits that leaf (held).
for i in range(4):
    os.pwrite(fd, bytes([0x40 + i]) * 4096, i * 2 * 4096)
os.fsync(fd)
os.pwrite(fd, b"\x44" * 4096, 8 * 4096)
os.pwrite(fd, b"\x45" * 4096, 10 * 4096)
open(stall, "w").write("1500")
s1 = subprocess.Popen(["sync"])   # a boundary for the file (sync's, or its writeback's) collects, then pauses
time.sleep(0.4)
os.close(fd)                      # the last close's boundary writes and settles the same set meanwhile
s1.wait()
PY
    ext="$(filefrag -v "$f" | grep -cE '^ *[0-9]+:' || true)"
    echo 0 >"$P/deferred_snapshot_trusted"
    echo 0 >"$P/deferred_collect_stall_ms"
    dropped="$(dmesg_since "$mark" | grep -c "ino=$ino: tree block .* changed on the device" || true)"
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    lost="$(python3 - "$f" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
want = {i * 2: 0x40 + i for i in range(6)}
print(sum(1 for b, v in want.items() if os.pread(fd, 4096, b * 4096) != bytes([v]) * 4096))
PY
)"
    ct_umount "$MNT"
    ct_fsck "$DEV" >/dev/null 2>&1 && fsck=1
    echo "dropped=$dropped lost=$lost extents=$ext fsck=$fsck" >"$RES"
}

field() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

round 0
R="$(cat "$RES")"
log "fixed: $R"
[ "$(field extents "$R")" -ge 5 ] || { fail "setup: the file's tree has no leaf ($R)"; ct_exit; }
[ "$(field dropped "$R")" = 0 ] && pass "1: no set was dropped as a peer's write" ||
    fail "1: this node's own boundary read as a peer's ($R)"
[ "$(field lost "$R")" = 0 ] && pass "2: after a remount every written block holds its data" ||
    fail "2: $(field lost "$R") written block(s) lost ($R)"
[ "$(field fsck "$R")" = 1 ] && pass "3: fsck clean" || fail "3: fsck ($R)"

round 1
C="$(cat "$RES")"
log "control (snapshot trusted): $C"
[ "$(field dropped "$C")" -ge 1 ] &&
    pass "control: judged by the images collected before the claim, this node's own write reads as a peer's and the set is dropped ($C)" ||
    fail "control: the old judgement did not drop the set ($C) -- the staging does not reach the race"
ct_exit
