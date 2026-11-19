#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a held-back leaf a peer rewrote is dropped, not written over the peer's
#
# A close whose boundary failed keeps its held-back tree blocks and is
# finished later -- by the heartbeat, a sync or the unmount -- by a blind
# in-place write of each block. Under nofilelock nothing stood between
# the failure and a peer opening the file, converting a block in the
# same leaf and publishing it: the late write put the old leaf back and
# the peer's fsynced block read as preallocated zeros again, a valid map
# fsck cannot see (audit 2026-11-15 BC-31; reproduced on two nodes,
# ctest late-flush). A boundary now reads each block from the device
# first and drops the set if one is no longer the image it was held
# back against.
#
# Staged on one node, nofilelock: a preallocated file whose O_DIRECT
# writes spill its map into a leaf; one more write whose close fails
# (tree_flush_fail_once: the edit stays held back, the close is queued);
# then, with the heartbeat held off, the peer's conversion is written to
# the leaf on the backing image (leaf_poke written) with its data block.
#   setup: the close failed and was queued; the peer's leaf is on the device;
#   1. the heartbeat's flush dropped the set, loudly (deferred_stale_sets);
#   2. the leaf on the device is still the peer's: its entry written,
#      ours not;
#   3. a fresh mount reads the peer's block;
#   4. fsck is clean.
#
# B. The peer writes INSIDE the window instead: after the device check,
# before the in-place writes (audit F-71; late_flush_window_ms holds it
# there). One of the two writes is lost and cannot be kept -- the peer
# takes no lock to exclude -- so the flush must SAY so: after the writes
# it re-reads what it wrote and the record's stamp, and a peer's write
# marks the file damaged.
#   setup B: the flush paused in its window, the peer's leaf and
#     record publish landed there;
#   5. the loss was reported and the file marked damaged.
# The peer writes BEFORE our write here, so it is the record stamp that
# reports it; the re-read of what we wrote (a peer writing AFTER us)
# has no staging of its own in this suite.
#
# DISCRIMINATION: late_flush_blind=1 writes the set unchecked; the
# control requires the peer's entry back to uninit and its block zeros.
# late_flush_unverified=1 (B): the loss passes silently.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in tree_flush_fail_once late_flush_blind hb_maint_delay_ms late_flush_unverified late_flush_window_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
LP="$(ct_helper leaf_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
MNT="$(ct_mnt lfs)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set tree_flush_fail_once 0
ct_param_set late_flush_blind 0
ct_param_set hb_maint_delay_ms 0
ct_param_set late_flush_unverified 0
ct_param_set late_flush_window_ms 0
IPOKE="$(ct_helper inode_block_poke)"
ct_param_set hb_interval_secs 2

dio_write() { # <path> <block> <tag> [fsync]
    python3 -I - "$@" <<'PY'
import mmap, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
buf.write(sys.argv[3].encode() * (4096 // len(sys.argv[3])))
os.pwritev(fd, [buf], int(sys.argv[2]) * 4096)
if len(sys.argv) > 4:
    os.fsync(fd)
os.close(fd)
PY
}
PEER=32 # the peer's block: in the gap after block 0, apart from OURS's
OURS=900

# <blind 0|1> -> "failed= peer= ondev_peer= ondev_ours= dropped= reads= fsck="
round() {
    local img dev f proc ino mark ent phys s0 s1 failed=0 finished=0 peer=0 op=0 oo=0 reads=0 fsck=0
    img="$(ct_image 560 "lfs$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    f="$MNT/img"
    fallocate -l $((4 << 20)) "$f"
    # 64 apart: gaps too wide for a conversion to zero-fill across, so
    # every write is its own extent and the map spills into a leaf.
    for i in $(seq 0 6); do dio_write "$f" $((i * 64)) "$(printf 'B%07d' $((i * 64)))"; done
    dio_write "$f" 448 B0000448 fsync
    ino="$(stat -c %i "$f")"
    echo "$1" >/sys/module/cetrafs/parameters/late_flush_blind
    echo 8000 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    sleep 3 # a pass already past its delay ends; the next one waits
    s0="$(sed -n 's/^deferred_stale_sets: //p' "$proc/info")"
    mark="$(dmesg_mark)"
    echo 1 >/sys/module/cetrafs/parameters/tree_flush_fail_once
    dio_write "$f" $OURS OURS0900
    dmesg_since "$mark" | grep -q "lock release: ino=$ino extent-tree blocks not durable" && failed=1
    # The peer: its conversion of the gap holding block PEER, and the
    # data it wrote there, on the device under the live mount.
    ent="$("$LP" "$img" show "$ino" | awk -v b=$PEER '{split($3,x,"=");split($5,l,"=");
        if (x[2] <= b && b < x[2] + l[2] && $6 == "uninit=1") {print $2; exit}}')"
    if [ -n "$ent" ]; then
        phys="$("$LP" "$img" show "$ino" | awk -v e="$ent" '$2 == e {split($3,x,"=");split($4,p,"="); print p[2] + '"$PEER"' - x[2]}')"
        python3 -I -c 'import sys; f=open(sys.argv[1],"r+b"); f.seek(int(sys.argv[2])*4096); f.write(b"PEER0032"*512)' "$img" "$phys"
        "$LP" "$img" written "$ino" "$ent" >/dev/null && peer=1
    fi
    echo 0 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    for _ in $(seq 1 60); do
        dmesg_since "$mark" | grep -q "lock release: ino=$ino close publish and flock clear finished by the heartbeat" &&
            { finished=1; break; }
        sleep 0.5
    done
    s1="$(sed -n 's/^deferred_stale_sets: //p' "$proc/info")"
    echo 0 >/sys/module/cetrafs/parameters/late_flush_blind
    umount "$MNT"
    "$LP" "$img" show "$ino" | awk -v b=$PEER '{split($3,x,"=");split($5,l,"=");
        if (x[2] <= b && b < x[2] + l[2]) print $6}' | grep -qx "uninit=0" && op=1
    "$LP" "$img" show "$ino" | awk -v b=$OURS '{split($3,x,"=");split($5,l,"=");
        if (x[2] <= b && b < x[2] + l[2]) print $6}' | grep -qx "uninit=0" && oo=1
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    [ "$(dd if="$f" bs=4096 skip=$PEER count=1 status=none | head -c 8)" = PEER0032 ] && reads=1
    umount "$MNT"
    "$FSCK" "$dev" >/dev/null 2>&1 && fsck=1
    echo "failed=$failed finished=$finished peer=$peer ondev_peer=$op ondev_ours=$oo dropped=$((s1 - s0)) reads=$reads fsck=$fsck"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "checked: $R"
C="$(round 1)"
log "control (blind): $C"
for v in "$R" "$C"; do
    [ "$(get failed "$v")" = 1 ] && [ "$(get peer "$v")" = 1 ] && [ "$(get finished "$v")" = 1 ] ||
        { fail "setup: the close did not fail, the peer's leaf was not planted, or the heartbeat never finished ($v)"; ct_exit; }
done
pass "setup: the close failed and was queued; the peer's leaf was on the device before the heartbeat finished it"
[ "$(get dropped "$R")" = 1 ] && pass "1: the late flush dropped the stale set" ||
    fail "1: dropped=$(get dropped "$R"), want 1"
[ "$(get ondev_peer "$R")" = 1 ] && [ "$(get ondev_ours "$R")" = 0 ] &&
    pass "2: the leaf on the device is the peer's: its entry written, ours not" ||
    fail "2: peer entry written=$(get ondev_peer "$R"), ours written=$(get ondev_ours "$R")"
[ "$(get reads "$R")" = 1 ] && pass "3: a fresh mount reads the peer's block" || fail "3: the peer's block does not read back"
[ "$(get fsck "$R")" = 1 ] && pass "4: fsck is clean" || fail "4: fsck reports problems"
[ "$(get ondev_peer "$C")" = 0 ] && [ "$(get reads "$C")" = 0 ] &&
    pass "control: written unchecked, the old leaf undid the peer's conversion (its block reads zeros)" ||
    fail "control: the peer's conversion survived the blind write -- the suite does not reach the window ($C)"

# <unverified 0|1> -> "failed= paused= peer= finished= reported="
round_w() {
    local img dev f ino mark ent phys failed=0 paused=0 finished=0 peer=0 rep=0
    img="$(ct_image 560 "lfsw$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    f="$MNT/img"
    fallocate -l $((4 << 20)) "$f"
    for i in $(seq 0 6); do dio_write "$f" $((i * 64)) "$(printf 'B%07d' $((i * 64)))"; done
    dio_write "$f" 448 B0000448 fsync
    ino="$(stat -c %i "$f")"
    echo "$1" >/sys/module/cetrafs/parameters/late_flush_unverified
    echo 8000 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    sleep 3
    mark="$(dmesg_mark)"
    echo 1 >/sys/module/cetrafs/parameters/tree_flush_fail_once
    dio_write "$f" $OURS OURS0900
    dmesg_since "$mark" | grep -q "lock release: ino=$ino extent-tree blocks not durable" && failed=1
    echo 6000 >/sys/module/cetrafs/parameters/late_flush_window_ms
    echo 0 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    for _ in $(seq 1 60); do
        dmesg_since "$mark" | grep -q "deferred: ino=$ino: TEST pause" && { paused=1; break; }
        sleep 0.2
    done
    if [ "$paused" = 1 ]; then
        ent="$("$LP" "$img" show "$ino" | awk -v b=$PEER '{split($3,x,"=");split($5,l,"=");
            if (x[2] <= b && b < x[2] + l[2] && $6 == "uninit=1") {print $2; exit}}')"
        if [ -n "$ent" ]; then
            phys="$("$LP" "$img" show "$ino" | awk -v e="$ent" '$2 == e {split($3,x,"=");split($4,p,"="); print p[2] + '"$PEER"' - x[2]}')"
            python3 -I -c 'import sys; f=open(sys.argv[1],"r+b"); f.seek(int(sys.argv[2])*4096); f.write(b"PEER0032"*512)' "$img" "$phys"
            "$LP" "$img" written "$ino" "$ent" >/dev/null &&
                "$IPOKE" "$img" peerseq "$ino" "$(($(sed -n 's/^this_node_id: //p' "$(ct_procdir "$dev")/info") + 1))" >/dev/null &&
                peer=1
        fi
    fi
    for _ in $(seq 1 60); do
        dmesg_since "$mark" | grep -q "lock release: ino=$ino close publish and flock clear finished by the heartbeat" &&
            { finished=1; break; }
        sleep 0.5
    done
    dmesg_since "$mark" | grep -q "ino=$ino: another node wrote the file while this node's tree flush" && rep=1
    echo 0 >/sys/module/cetrafs/parameters/late_flush_window_ms
    echo 0 >/sys/module/cetrafs/parameters/late_flush_unverified
    umount "$MNT" || umount -l "$MNT"
    echo "failed=$failed paused=$paused peer=$peer finished=$finished reported=$rep"
}
R="$(round_w 0)"
log "window checked: $R"
C="$(round_w 1)"
log "control (unverified): $C"
for v in "$R" "$C"; do
    [ "$(get failed "$v")" = 1 ] && [ "$(get paused "$v")" = 1 ] && [ "$(get peer "$v")" = 1 ] ||
        { fail "setup B: the close did not fail, the flush never paused, or the peer's write was not planted ($v)"; ct_exit; }
done
pass "setup B: the peer's leaf and record publish landed inside the late flush's window"
[ "$(get reported "$R")" = 1 ] && pass "5: the loss was reported and the file marked damaged" ||
    fail "5: the peer's write inside the window passed silently ($R)"
[ "$(get reported "$C")" = 0 ] && pass "control: unverified, the loss passed silently" ||
    fail "control: reported anyway -- the suite does not isolate the check ($C)"
ct_exit
