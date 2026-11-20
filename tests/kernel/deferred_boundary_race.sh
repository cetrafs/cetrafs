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
# Then the same with the file's fsync in the pause instead of its close:
# fsync writes the whole set, so the held boundary finds every block no
# longer held back and sends nothing. What it never sent is not its to
# read back -- counted as written against no image, the read-back called
# it "another node wrote the file" and marked the file damaged (EUCLEAN).
#   4. no window loss, the file not marked damaged, its data and fsck clean.
# The loss itself needs a shadow not yet published when the set is
# dropped, which churn_oracle reaches and this staging does not: here the
# close publishes first. The false verdict is what drops it.
#
# DISCRIMINATION: deferred_snapshot_trusted=1 judges the set by the images
# collected before the claim: the same steps must read this node's own
# write as a peer's and drop the set. deferred_unsent_counted=1 counts an
# unsent block as written: the fsync staging must report a window loss.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
P=/sys/module/cetrafs/parameters
for k in deferred_collect_stall_ms deferred_collect_stall_ino deferred_snapshot_trusted deferred_unsent_counted; do
    [ -w "$P/$k" ] || { skip "$k is missing"; ct_exit; }
done
DEV="$(ct_dev 560 dbrace)"
MNT="$(ct_mnt dbrace)"
ct_track mnt "$MNT"
compress_timing
for k in deferred_collect_stall_ms deferred_collect_stall_ino deferred_snapshot_trusted deferred_unsent_counted auto_defrag; do
    ct_param_set "$k" "$(cat $P/$k)"
done
ct_param_set auto_defrag 0
RES="$(ct_tmp dbrace-res)"

# <trusted 0|1> <close|fsync> <unsent_counted 0|1>: writes
# "dropped=<n> window=<n> err=<0|1> lost=<n> extents=<n> fsck=<0|1>" to $RES
round() {
    local trusted="$1" how="$2" unsent="$3" f ino mark dropped window lost fsck=0 ext err
    ct_mkfs "$DEV" -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    f="$MNT/f"
    : >"$f"
    ino="$(stat -c %i "$f")"
    echo "$trusted" >"$P/deferred_snapshot_trusted"
    echo "$unsent" >"$P/deferred_unsent_counted"
    echo "$ino" >"$P/deferred_collect_stall_ino"
    mark="$(dmesg_mark)"
    # One process keeps the file open throughout: a last close is a
    # boundary of its own and would write the held set first.
    err="$(python3 - "$f" "$P/deferred_collect_stall_ms" "$how" <<'PY'
import os, subprocess, sys, time
path, stall, how = sys.argv[1], sys.argv[2], sys.argv[3]
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
err = 0
try:
    if how == "fsync":
        os.fsync(fd)              # the file's fsync writes and settles the whole set meanwhile
    os.close(fd)                  # or the last close's boundary does
except OSError:
    err = 1
s1.wait()
try:                              # a file marked damaged refuses a write
    fd = os.open(path, os.O_RDWR)
    os.pwrite(fd, b"\x40" * 4096, 0)
    os.fsync(fd)
    os.close(fd)
except OSError:
    err = 1
print(err, flush=True)
PY
)"
    ext="$(filefrag -v "$f" | grep -cE '^ *[0-9]+:' || true)"
    echo 0 >"$P/deferred_snapshot_trusted"
    echo 0 >"$P/deferred_unsent_counted"
    echo 0 >"$P/deferred_collect_stall_ms"
    dropped="$(dmesg_since "$mark" | grep -c "ino=$ino: tree block .* changed on the device" || true)"
    window="$(dmesg_since "$mark" | grep -c "ino=$ino: another node wrote the file while" || true)"
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
    echo "dropped=$dropped window=$window err=$err lost=$lost extents=$ext fsck=$fsck" >"$RES"
}

field() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

round 0 close 0
R="$(cat "$RES")"
log "fixed: $R"
[ "$(field extents "$R")" -ge 5 ] || { fail "setup: the file's tree has no leaf ($R)"; ct_exit; }
[ "$(field dropped "$R")" = 0 ] && pass "1: no set was dropped as a peer's write" ||
    fail "1: this node's own boundary read as a peer's ($R)"
[ "$(field lost "$R")" = 0 ] && pass "2: after a remount every written block holds its data" ||
    fail "2: $(field lost "$R") written block(s) lost ($R)"
[ "$(field fsck "$R")" = 1 ] && pass "3: fsck clean" || fail "3: fsck ($R)"

round 0 fsync 0
F="$(cat "$RES")"
log "fsync in the pause: $F"
[ "$(field extents "$F")" -ge 5 ] || { fail "setup: the file's tree has no leaf ($F)"; ct_exit; }
[ "$(field window "$F")" = 0 ] && [ "$(field err "$F")" = 0 ] && [ "$(field dropped "$F")" = 0 ] &&
    [ "$(field lost "$F")" = 0 ] && [ "$(field fsck "$F")" = 1 ] &&
    pass "4: a set another boundary wrote is not read back as lost; the file stays whole ($F)" ||
    fail "4: ($F)"

round 1 close 0
C="$(cat "$RES")"
log "control (snapshot trusted): $C"
[ "$(field dropped "$C")" -ge 1 ] &&
    pass "control: judged by the images collected before the claim, this node's own write reads as a peer's and the set is dropped ($C)" ||
    fail "control: the old judgement did not drop the set ($C) -- the staging does not reach the race"

round 0 fsync 1
U="$(cat "$RES")"
log "control (unsent counted): $U"
[ "$(field window "$U")" -ge 1 ] &&
    pass "control: an unsent block counted as written reads back as a window loss ($U)" ||
    fail "control: counting the unsent block raised no window loss ($U) -- the staging does not reach it"
ct_exit
