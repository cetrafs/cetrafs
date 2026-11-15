#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an O_DIRECT overwrite does not re-read the tree from the device while a peer has the image open
#
# Under nofilelock a live-migration destination holds the image open for
# the whole pre-copy. On the source, every shared-lock O_DIRECT overwrite
# mapped its blocks twice -- the probe, then the DIO's own get_block --
# and each asked the writer's cache question, which a peer's presence
# answers "no": the record and every tree block re-read from the device,
# per call (audit 2026-11-15 B-12). An overwrite maps written blocks only
# and publishes nothing, and no peer can free a block while this node is
# in the file, so it now asks the reader's question, gated on file_seq.
#
# A file of 3,000 one-block extents (a tree with leaf blocks), opened on
# a nofilelock mount; a live node 1 opens it too; 300 random 4 KiB
# O_DIRECT overwrites:
#   1. the device saw fewer reads than one per four writes;
#   2. every overwrite reads back; fsck clean.
#
# DISCRIMINATION: read_trust_writer_defers=1: several device reads per write.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/read_trust_writer_defers ] || { skip "read_trust_writer_defers is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt dowr)"
ct_track mnt "$MNT"
ct_param_set read_trust_writer_defers 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
ct_param_set alloc_run_blocks 0
N=3000
W=300
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

DRV="$(ct_tmp dowr-drv)"
cat >"$DRV" <<'PY'
import os, sys, mmap, random, time
op, path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
def stamp(i, g): return (b"B%07dG%02d" % (i, g)) * 372 + b"\0" * 4
buf = mmap.mmap(-1, 4096)
if op == "build":  # interleaved with a filler: every block its own extent
    f = os.open(path, os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    g = os.open(path + ".fill", os.O_RDWR | os.O_CREAT | os.O_DIRECT, 0o644)
    for b in range(n):
        buf.seek(0); buf.write(stamp(b, 0))
        os.pwritev(f, [buf], b * 4096)
        os.pwritev(g, [buf], b * 4096)
    os.close(g); os.close(f)
elif op == "write":  # <go-file> <count>: open, wait for go, overwrite
    go, w = sys.argv[4], int(sys.argv[5])
    f = os.open(path, os.O_RDWR | os.O_DIRECT)
    open(go + ".open", "w").close()
    while not os.path.exists(go):
        time.sleep(0.05)
    rng = random.Random(3)
    blocks = [rng.randrange(n) for _ in range(w)]
    for b in blocks:
        buf.seek(0); buf.write(stamp(b, 1))
        os.pwritev(f, [buf], b * 4096)
    os.close(f)
    open(go + ".done", "w").write(" ".join(map(str, blocks)))
else:  # check <done-file>
    hit = set(map(int, open(sys.argv[4]).read().split()))
    d = open(path, "rb").read()
    bad = [i for i in range(n) if d[i * 4096:(i + 1) * 4096] != stamp(i, 1 if i in hit else 0)]
    print("ok" if not bad else "BAD_%d" % len(bad))
PY

# <tag> <writer_gate 0|1> -> RES
round() {
    local img dev ino beater go r0 r1 blk wpid o0 o1 t0 t1
    img="$(ct_image 1000 "dowr$1")"
    dev="$(ct_loop "$img")"
    blk="$(basename "$dev")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    python3 -I "$DRV" build "$MNT/f" "$N"
    ct_umount "$MNT"
    mount -t cetrafs -o nofilelock "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    ino="$(stat -c %i "$MNT/f")"
    go="$(ct_tmp "dowr-go$1")"
    rm -f "$go" "$go.open" "$go.done"
    python3 -I "$DRV" write "$MNT/f" "$N" "$go" "$W" &
    wpid=$!
    wait_for 10 "[ -e '$go.open' ]" || { fail "setup: the writer never opened the file"; ct_exit; }
    "$NODE_POKE" "$dev" 1 1 bb "$(date +%s)" >/dev/null
    (for _ in $(seq 1 120); do "$NODE_POKE" "$dev" 1 --beat >/dev/null 2>&1; sleep 0.25; done) &
    beater=$!
    "$LOCK_POKE" "$dev" "$ino" --reader 1 >/dev/null
    sleep 2 # the writer's presence look is at most once a second
    echo "$2" >$P/read_trust_writer_defers
    r0="$(awk '{print $1}' "/sys/block/$blk/stat")"
    o0="$(sed -n 's/^dio_overwrites: //p' "$(ct_procdir "$dev")/info")"
    t0="$(sed -n 's/^tree_reads: //p' "$(ct_procdir "$dev")/info")"
    touch "$go"
    wait_for 120 "[ -e '$go.done' ]" || true
    r1="$(awk '{print $1}' "/sys/block/$blk/stat")"
    o1="$(sed -n 's/^dio_overwrites: //p' "$(ct_procdir "$dev")/info")"
    t1="$(sed -n 's/^tree_reads: //p' "$(ct_procdir "$dev")/info")"
    echo 0 >$P/read_trust_writer_defers
    wait "$wpid" || true
    kill "$beater" 2>/dev/null || true
    wait "$beater" 2>/dev/null || true
    "$LOCK_POKE" "$dev" "$ino" --unreader 1 >/dev/null
    "$NODE_POKE" "$dev" 1 0 bb 0 >/dev/null
    RES="reads=$((r1 - r0)) shared=$((${o1:-0} - ${o0:-0})) tree=$((${t1:-0} - ${t0:-0})) check=$(python3 -I "$DRV" check "$MNT/f" "$N" "$go.done" 2>/dev/null || echo none)"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR|leaked' || true)"
}

round c 1
C="$RES"
log "control (the writer's gate): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get reads "$C")" -ge $((W * 2)) ] ||
    { fail "setup: the control read only $(get reads "$C") blocks for $W overwrites -- no peer window? ($C)"; ct_exit; }
[ "$(get reads "$R")" -lt $((W / 4)) ] &&
    pass "1: $W overwrites in the window read $(get reads "$R") blocks from the device (control: $(get reads "$C"))" ||
    fail "1: $R"
[ "$(get check "$R")" = ok ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "2: every overwrite reads back; fsck clean" || fail "2: $R"
pass "control: the writer's gate read $(get reads "$C") blocks for $W overwrites"
ct_exit
