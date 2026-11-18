#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a write into a hole maps through the cached tree in the migration window, unless a peer's stamp says otherwise
#
# Under nofilelock a live-migration destination holds the image open for
# the whole pre-copy, and the writer's cache question answers "no" for
# all of it: every write that ALLOCATES -- a guest filling a sparse
# image -- re-read the record and every tree block on the way from the
# device (audit 2026-11-15 B-12; overwrites were 1f0da45). The record is
# still read fresh per call; the tree under it is trusted unless that
# record carries a peer's newer file_seq.
#
# A file of 3,000 one-block extents with a hole after each, on a
# nofilelock mount; a live node 1 opens it too; 300 O_DIRECT writes into
# the holes:
#   1. at least one device read fewer per write than the control, which
#      walked the tree from the device on every write (the extent's
#      insertion still reads what it rewrites fresh -- rule 5);
#   2. a peer's publish (its file_seq on the record): the next write into
#      a hole sees it before it maps, and walks the tree from the device
#      (alloc_trust_cold) -- never with the stamp ignored. This node's
#      writes are fsynced first: a peer publishing over this node's
#      unpublished changes is two writers, and the fresh record then
#      carries this node's own pending stamp (the shadow overlay). Counted
#      as total cold marks, this case read 2 against 1 only when the
#      shadow happened to be published first, and failed 1 run in 4;
#   3. every write reads back; fsck clean.
#
# DISCRIMINATION: alloc_trust_off=1: 1 fails (the tree read per write).
# alloc_trust_ignore_stamp=1: 2 fails (the peer's change is not seen).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in alloc_trust_off alloc_trust_ignore_stamp; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt awr)"
ct_track mnt "$MNT"
ct_param_set alloc_trust_off 0
ct_param_set alloc_trust_ignore_stamp 0
ct_param_set cold_work_stall_ms 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set alloc_run_blocks 0
N=3000
W=300
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

DRV="$(ct_tmp awr-drv)"
cat >"$DRV" <<'PY'
import os, sys, mmap, random, time
op, path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
def stamp(i, g): return (b"B%07dG%02d" % (i, g)) * 372 + b"\0" * 4
buf = mmap.mmap(-1, 4096)
if op == "build":  # even blocks only, interleaved with a filler: every block its own extent
    f = os.open(path, os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    g = os.open(path + ".fill", os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    for b in range(n):
        buf.seek(0); buf.write(stamp(2 * b, 0))
        os.pwritev(f, [buf], 2 * b * 4096)
        os.pwritev(g, [buf], b * 4096)
    os.close(g); os.close(f)
elif op == "write":  # <go-file> <count>: open, wait for go, write into holes, then one more on "go2"
    go, w = sys.argv[4], int(sys.argv[5])
    f = os.open(path, os.O_RDWR | os.O_DIRECT)
    open(go + ".open", "w").close()
    while not os.path.exists(go):
        time.sleep(0.05)
    rng = random.Random(3)
    blocks = rng.sample(range(n - 1), w + 1)
    for b in blocks[:w]:
        buf.seek(0); buf.write(stamp(2 * b + 1, 1))
        os.pwritev(f, [buf], (2 * b + 1) * 4096)
    os.fsync(f)  # published: the peer's stamp lands on this node's own (case 2)
    open(go + ".done", "w").write(" ".join(str(2 * b + 1) for b in blocks[:w]))
    while not os.path.exists(go + "2"):
        time.sleep(0.05)
    b = blocks[w]
    buf.seek(0); buf.write(stamp(2 * b + 1, 1))
    os.pwritev(f, [buf], (2 * b + 1) * 4096)
    os.close(f)
    open(go + ".done2", "w").write(" ".join(str(2 * b + 1) for b in blocks))
else:  # check <done-file>
    hit = set(map(int, open(sys.argv[4]).read().split()))
    d = open(path, "rb").read()
    bad = 0
    for i in range(2 * n):
        want = stamp(i, 0) if i % 2 == 0 else (stamp(i, 1) if i in hit else None)
        got = d[i * 4096:(i + 1) * 4096]
        if want is None:
            if got and got != b"\0" * len(got): bad += 1
        elif got != want:
            bad += 1
    print("ok" if not bad else "BAD_%d" % bad)
PY

# <tag> <alloc_trust_off 0|1> <ignore_stamp 0|1> -> RES
round() {
    local img dev ino beater go blk wpid t1 t2 r0 r1 size proc
    img="$(ct_image 1000 "awr$1")"
    dev="$(ct_loop "$img")"
    blk="$(basename "$dev")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    python3 -I "$DRV" build "$MNT/f" "$N"
    ct_umount "$MNT"
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    proc="$(ct_procdir "$dev")"
    ino="$(stat -c %i "$MNT/f")"
    go="$(ct_tmp "awr-go$1")"
    rm -f "$go" "$go.open" "$go.done" "$go"2 "$go.done2"
    python3 -I "$DRV" write "$MNT/f" "$N" "$go" "$W" &
    wpid=$!
    wait_for 10 "[ -e '$go.open' ]" || { fail "setup: the writer never opened the file"; ct_exit; }
    "$NODE_POKE" "$dev" 1 1 bb "$(date +%s)" >/dev/null
    # Beats until the round kills it: a beater that ran out (it used to
    # stop after 40 s) left node 1 silent on a slow host, this node the
    # sole opener of the file, and the write rightly trusting its cache
    # without asking the stamp -- case 2 then failed 1 run in 4.
    (while :; do "$NODE_POKE" "$dev" 1 --beat >/dev/null 2>&1; sleep 0.25; done) &
    beater=$!
    "$LOCK_POKE" "$dev" "$ino" --reader 1 >/dev/null
    sleep 2 # the writer's presence look is at most once a second
    echo "$2" >$P/alloc_trust_off
    echo "$3" >$P/alloc_trust_ignore_stamp
    r0="$(awk '{print $1}' "/sys/block/$blk/stat")"
    touch "$go"
    wait_for 120 "[ -e '$go.done' ]" || true
    r1="$(awk '{print $1}' "/sys/block/$blk/stat")"
    # a peer's publish: its stamp on the record, the size it leaves unchanged
    size="$(stat -c %s "$MNT/f")"
    # The reconcile a noticed stamp queues is held back, so the tree is
    # still cold when the write maps: noticed by the write itself or by
    # a path just before it, the mapping must walk it from the device.
    echo 3000 >$P/cold_work_stall_ms
    "$LOCK_POKE" "$dev" --peer-size "$ino" "$size" 1 >/dev/null
    t1="$(sed -n 's/^alloc_trust_cold: //p' "$proc/info")"
    touch "$go"2
    wait_for 30 "[ -e '$go.done2' ]" || true
    t2="$(sed -n 's/^alloc_trust_cold: //p' "$proc/info")"
    echo 0 >$P/alloc_trust_off
    echo 0 >$P/alloc_trust_ignore_stamp
    echo 0 >$P/cold_work_stall_ms
    wait "$wpid" || true
    kill "$beater" 2>/dev/null || true
    wait "$beater" 2>/dev/null || true
    "$LOCK_POKE" "$dev" "$ino" --unreader 1 >/dev/null
    "$NODE_POKE" "$dev" 1 0 bb 0 >/dev/null
    RES="reads=$((r1 - r0)) cold_after_peer=$((t2 - t1))"
    RES="$RES check=$(python3 -I "$DRV" check "$MNT/f" "$N" "$go.done2" 2>/dev/null || echo none)"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR|leaked' || true)"
}

round c 1 0
C="$RES"
log "control (tree re-read in the window): $C"
round s 0 1
S="$RES"
log "control (stamp ignored): $S"
round f 0 0
R="$RES"
log "fixed: $R"
[ "$(get reads "$C")" -ge $((W * 3)) ] ||
    { fail "setup: the control read only $(get reads "$C") blocks for $W writes -- no peer window? ($C)"; ct_exit; }
[ "$(get reads "$R")" -le $(($(get reads "$C") - W)) ] &&
    pass "1: $W writes into holes read $(get reads "$R") blocks from the device (control: $(get reads "$C"))" ||
    fail "1: $R"
# The allocating mapping found the tree cold and walked it from the
# device: the peer's stamp was seen BEFORE the mapping. With the stamp
# ignored it trusts the cache and never counts.
[ "$(get cold_after_peer "$R")" -ge 1 ] &&
    pass "2: the next write saw the peer's stamp before mapping (alloc_trust_cold +$(get cold_after_peer "$R"))" ||
    fail "2: $R (stamp ignored: $S)"
[ "$(get check "$R")" = ok ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "3: every write reads back; fsck clean" || fail "3: $R"
pass "control: the writer's gate read $(get reads "$C") blocks for $W writes"
[ "$(get cold_after_peer "$S")" = 0 ] &&
    pass "control: with the stamp ignored the write mapped through the cached tree (alloc_trust_cold +0)" ||
    fail "control: with the stamp ignored the write still found the tree cold -- the suite does not reach the stamp: $S"
ct_exit
