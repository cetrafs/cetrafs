#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a leaf torn under a dead opener's unreplayed journal is not marked damaged
#
# Since 02e7f2d a tree block that fails its tail checksum marks its file
# damaged, refusing every write to it until remount. A node that dies
# under nofilelock with a leaf half-written leaves exactly that, and its
# replay -- once it is stale -- rewrites the block. HA restarting the VM
# here inside the window read the torn leaf first: the image was marked
# and stayed unwritable after the replay had repaired it (audit
# 2026-11-15 F-35, BM-37). A tear while a node that has the file open
# has a dirty journal now fails the read without the mark.
#
# This node has "frag" open. Then, as a peer would leave it: node 1
# dead, also with frag open, its journal holding one entry for frag's
# leaf (the good image), the leaf on the device torn, and a change
# stamp from node 1 so this node reads the tree again. (An open after
# that is held back until node 1 is replayed -- the open gate -- so the
# reader that meets the tear is one that had the file open before.)
# The sweep is held off:
#   1. the held fd's read fails, and the file is not marked: a fchmod on
#      it is not refused as damage (EUCLEAN) -- node 1's presence still
#      refuses it ETXTBSY, the setattr guard's answer, which ends with
#      node 1's reclaim;
#   2. with the sweep let go, the replay -- under this node's own
#      opener -- repairs the leaf, and the fd reads the file as written.
#
# DISCRIMINATION: tear_replay_ignored=1 (as before): marked, and the
# fchmod is refused EUCLEAN.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"
BPOKE="$(ct_helper blk_tail_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt tlar)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set tear_replay_ignored 0
ct_param_set hb_replay_sweep_off 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
nfmount() { mount -t cetrafs -o nofilelock "$1" "$2"; }

# <tag> <ignored 0|1> -> RES
round() {
    local img dev dir ino p sum mark out hp
    img="$(ct_image 560 "tlar$1")"
    dev="$(ct_loop "$img")"
    dir="$(ct_tmp "tlar-$1")"
    rm -rf "$dir"
    mkdir -p "$dir"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    echo "$2" >$P/tear_replay_ignored
    echo 1 >$P/hb_replay_sweep_off
    compress_timing
    nfmount "$dev" "$MNT"
    python3 - "$MNT/frag" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(30):
    os.pwrite(fd, b'f' * 4096, i * 2 * 4096)
os.fsync(fd); os.close(fd)
PY
    sync
    ino="$(stat -c %i "$MNT/frag")"
    sum="$(md5sum <"$MNT/frag" | cut -d' ' -f1)"
    p="$("$IPOKE" "$dev" leaf "$ino" | sed -n 's/.*leaf_lba=\([0-9]*\).*/\1/p')"
    [ -n "$p" ] || { fail "setup: frag has no external leaf"; ct_exit; }
    dd if="$dev" of="$dir/good" bs=4096 skip="$p" count=1 iflag=direct status=none
    # the holder: reads on "go", reads again on "go2"
    python3 -I - "$MNT/frag" "$dir" <<'PY' &
import hashlib, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY)
d = sys.argv[2]
def wait(n):
    while not os.path.exists(os.path.join(d, n)):
        time.sleep(0.05)
def rd():
    try:
        h = hashlib.md5()
        off = 0
        while True:
            b = os.pread(fd, 65536, off)
            if not b:
                return h.hexdigest()
            h.update(b)
            off += len(b)
    except OSError as e:
        return "errno%d" % e.errno
open(os.path.join(d, "ready"), "w").close()
wait("go")
r1 = rd()
try:
    os.fchmod(fd, 0o600); x = "set"
except OSError as e:
    x = str(e.errno)
open(os.path.join(d, "r1"), "w").write("%s %s" % (r1, x))
wait("go2")
open(os.path.join(d, "r2"), "w").write(rd())
os.close(fd)
PY
    hp=$!
    wait_for 20 "[ -e '$dir/ready' ]" || { fail "setup: the holder never opened frag"; ct_exit; }
    "$BPOKE" "$dev" leaf "$ino" corrupt >/dev/null
    poke_dead_peer "$dev" 1 aa
    "$(ct_helper node_poke)" "$dev" 1 --mode 2 >/dev/null
    "$JPOKE" "$dev" 1 0 "$p" "$dir/good" --guard-current >/dev/null
    "$LPOKE" "$dev" "$ino" --reader 1 >/dev/null
    "$LPOKE" "$dev" --peer-size "$ino" "$(stat -c %s "$MNT/frag")" 1 >/dev/null
    sync
    echo 3 >/proc/sys/vm/drop_caches # the read must map through the tree
    mark="$(dmesg_mark)"
    touch "$dir/go"
    wait_for 60 "[ -e '$dir/r1' ]" || { fail "setup: the holder's first read never finished"; ct_exit; }
    out="$(dmesg_since "$mark")"
    if [ "$2" = 0 ]; then
        echo 0 >$P/hb_replay_sweep_off
        wait_for 90 "dmesg_since '$mark' | grep -q 'journal replay: node 1 replayed'" || true
    fi
    touch "$dir/go2"
    wait "$hp" || true
    read -r r1 x <"$dir/r1" || true
    [ "$r1" = "$sum" ] && r1=read || r1="failed($r1)"
    r2="$(cat "$dir/r2" 2>/dev/null || echo none)"
    [ "$r2" = "$sum" ] && r2=intact || r2="bad($r2)"
    RES="read=$r1 marked=$(grep -c "ino=$ino is damaged" <<<"$out" || true) chmod=$x"
    RES="$RES awaits=$(grep -c 'awaiting replay: not counted' <<<"$out" || true) after=$r2"
    echo 0 >$P/tear_replay_ignored
    echo 0 >$P/hb_replay_sweep_off
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    reset_stale_window
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (as before): $C"
[ "$(get read "$R")" != read ] && [ "$(get read "$C")" != read ] ||
    { fail "setup: the torn leaf read back ($R / $C)"; ct_exit; }
[ "$(get marked "$R")" = 0 ] && [ "$(get awaits "$R")" -ge 1 ] && [ "$(get chmod "$R")" != 117 ] &&
    pass "1: the tear awaited the dead node's replay -- not marked, nothing refused as damage" || fail "1: $R"
[ "$(get after "$R")" = intact ] && pass "2: the replay repaired the leaf and the file reads as written" ||
    fail "2: $R"
[ "$(get marked "$C")" -ge 1 ] && [ "$(get chmod "$C")" = 117 ] &&
    pass "control: as before, the file was marked and the fchmod refused EUCLEAN" ||
    fail "control: not marked without the change -- the suite does not reach it: $C"
ct_exit
