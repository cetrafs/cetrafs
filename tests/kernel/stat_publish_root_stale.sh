#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a record publish does not carry its extent root over a peer's newer one
#
# The stat publish copied the in-core shadow's extent root over the
# device's -- "strictly newer: this node is the file's writer", which is
# the file lock's promise and nofilelock has no lock. A close whose
# record publish failed was finished by the heartbeat after a peer had
# opened the file, converted another unit of the same inline extent and
# fsynced: the old map went back on top and the peer's block read as
# zeros, with fsck clean (audit 2026-11-15 BC-54, BC-31's inline-map
# sibling; reproduced on two nodes first). The shadow now carries the
# stamp of the record it was built on, and a publish that finds a
# peer's later stamp keeps the peer's root and drops its own.
#
# Staged on one node, nofilelock: a 1 MiB preallocated file (one inline
# extent); a write into unit 0 whose close's record publish fails
# (close_publish_fail: queued for the heartbeat, held off); then the
# peer's publish on the backing image -- the extent marked written, a
# marker in block 40's data block, file_seq stamped by node 3.
#   setup: the close failed and was queued; the peer's record is on the device;
#   1. the heartbeat's publish dropped this node's map, loudly;
#   2. the record still carries the peer's extent, written;
#   3. a fresh mount reads the peer's block 40;
#   4. fsck is clean.
#
# DISCRIMINATION: stat_publish_root_over_peer=1 carries the root as
# before; the control requires the extent back to unwritten past unit 0
# and block 40 reading zeros.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in close_publish_fail stat_publish_root_over_peer hb_maint_delay_ms; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
IPOKE="$(ct_helper inode_block_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
MNT="$(ct_mnt sprs)"
ct_track mnt "$MNT"
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set close_publish_fail 0
ct_param_set stat_publish_root_over_peer 0
ct_param_set hb_maint_delay_ms 0
ct_param_set hb_interval_secs 2

# <over 0|1> -> "failed= finished= peer= dropped= ext_written= reads= fsck="
round() {
    local img dev f ino mark phys failed=0 finished=0 peer=0 dropped=0 ew=0 reads=0 fsck=0
    img="$(ct_image 560 "sprs$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    f="$MNT/img"
    fallocate -l $((1 << 20)) "$f"
    sync "$f"
    ino="$(stat -c %i "$f")"
    phys="$(filefrag -v "$f" | awk '$1 == "0:" {sub(/\.\..*/, "", $4); print $4 + 40}')"
    echo "$1" >/sys/module/cetrafs/parameters/stat_publish_root_over_peer
    echo 8000 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    sleep 3 # a pass already past its delay ends; the next one waits
    mark="$(dmesg_mark)"
    python3 -I - "$f" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.pwrite(fd, b"OURS0001" * 512, 4096)
open("/sys/module/cetrafs/parameters/close_publish_fail", "w").write("1")
os.close(fd)
PY
    dmesg_since "$mark" | grep -q "lock release: ino=$ino failed to persist inode state" && failed=1
    # The peer: its conversion of the whole extent, its data in block 40,
    # its stamp -- on the device under the live mount.
    if [ -n "$phys" ] && [ "$("$IPOKE" "$img" extents "$ino" 2>&1 | grep -c 'depth=0')" = 1 ]; then
        python3 -I -c 'import sys; f=open(sys.argv[1],"r+b"); f.seek(int(sys.argv[2])*4096); f.write(b"PEER0040"*512)' "$img" "$phys"
        "$IPOKE" "$img" extset "$ino" 0 uninit 0 2>/dev/null && "$IPOKE" "$img" peerseq "$ino" 3 2>/dev/null && peer=1
    fi
    echo 0 >/sys/module/cetrafs/parameters/hb_maint_delay_ms
    for _ in $(seq 1 60); do
        dmesg_since "$mark" | grep -q "lock release: ino=$ino close publish and flock clear finished by the heartbeat" &&
            { finished=1; break; }
        sleep 0.5
    done
    dmesg_since "$mark" | grep -q "ino=$ino: another node (3) published the file's extent map" && dropped=1
    echo 0 >/sys/module/cetrafs/parameters/stat_publish_root_over_peer
    umount "$MNT"
    "$IPOKE" "$img" extents "$ino" 2>&1 | grep -q "entries=1 " && ew=1
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    [ "$(dd if="$f" bs=4096 skip=40 count=1 status=none | head -c 8)" = PEER0040 ] && reads=1
    umount "$MNT"
    "$FSCK" "$dev" >/dev/null 2>&1 && fsck=1
    echo "failed=$failed finished=$finished peer=$peer dropped=$dropped ext_written=$ew reads=$reads fsck=$fsck"
}
get() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }

R="$(round 0)"
log "checked: $R"
C="$(round 1)"
log "control (root carried): $C"
for v in "$R" "$C"; do
    [ "$(get failed "$v")" = 1 ] && [ "$(get peer "$v")" = 1 ] && [ "$(get finished "$v")" = 1 ] ||
        { fail "setup: the close did not fail, the peer's record was not planted, or the heartbeat never finished ($v)"; ct_exit; }
done
pass "setup: the close failed and was queued; the peer's record was on the device before the heartbeat finished it"
[ "$(get dropped "$R")" = 1 ] && pass "1: the publish dropped this node's map, loudly" || fail "1: no drop message"
[ "$(get ext_written "$R")" = 1 ] && pass "2: the record still carries the peer's single written extent" ||
    fail "2: the record's extents changed: $R"
[ "$(get reads "$R")" = 1 ] && pass "3: a fresh mount reads the peer's block 40" || fail "3: the peer's block 40 does not read back"
[ "$(get fsck "$R")" = 1 ] && pass "4: fsck is clean" || fail "4: fsck reports problems"
[ "$(get reads "$C")" = 0 ] && [ "$(get ext_written "$C")" = 0 ] &&
    pass "control: carried over the peer's, the old map undid its conversion (block 40 reads zeros)" ||
    fail "control: the peer's conversion survived -- the suite does not reach the window ($C)"
ct_exit
