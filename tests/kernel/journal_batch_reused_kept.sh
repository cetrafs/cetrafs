#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a refused tree batch never zeroes the kept entry whose slot it took over
#
# A tree block whose target write was refused keeps its journal entry
# live for replay, its slot held; the next boundary's batch takes that
# slot over for the block's new entry. When the batch's entry writes were
# refused definitely -- nothing of it on the device -- the batch retired
# every slot by zeroing its header, the taken-over one included: the one
# redo of a target the device had refused, gone, while the boundary
# failed ENOSPC and the mount ran on with that target unprotected (the
# batch form of audit 2026-11-22 N-67). The kept entry now stays, held,
# and the mount stops, as the single-block path does.
#
# A preallocated file, its map in one leaf, all on one open fd (a close
# is a boundary, and would rewrite the refused leaf):
#   setup: the leaf's target write refused (tree_target_nospc=1): fsync
#     ENOSPC, the entry kept, its slot held;
#   the act: the next fsync's entry writes, payload and header, refused
#     (journal_entry_nospc=2);
#   1. the kept entry is still on the device, its slot held;
#   2. the mount stopped, saying the kept entry stays;
#   3. a remount replays it: every block of the setup's write reads back,
#      fsck clean.
#
# DISCRIMINATION: journal_reused_zeroed=1 (as before): the batch zeroes
# the kept entry and the mount runs on.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in journal_reused_zeroed tree_target_nospc journal_entry_nospc tree_refusal_stops; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
SBPOKE="$(ct_helper sb_poke)"
MNT="$(ct_mnt jbrk)"
ct_track mnt "$MNT"
ct_param_set journal_reused_zeroed 0
ct_param_set tree_target_nospc 0
ct_param_set journal_entry_nospc 0
ct_param_set tree_refusal_stops 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# acts <file> <dev> <info> <first header lba> <slots> <zeroed> <setup-to>:
# write blocks 0..setup-to (each i*4 its number) and fsync, then on the
# SAME fd the setup and the act; the counters and the live entry headers
# on the device after each
acts() { python3 -I - "$@" <<'EOF'
import errno, mmap, os, sys
f, dev, info = sys.argv[1], sys.argv[2], sys.argv[3]
h0, ns, zeroed = int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
P = "/sys/module/cetrafs/parameters/"
def knob(n, v):
    with open(P + n, "w") as k:
        k.write(v)
def stat(n):
    for l in open(info):
        if l.startswith(n + ": "):
            return int(l.split()[1])
    return -1
def live():
    d = os.open(dev, os.O_RDONLY | os.O_DIRECT)
    buf = mmap.mmap(-1, 4096)
    n = 0
    for s in range(ns):
        os.preadv(d, [buf], (h0 + 2 * s) * 4096)
        n += buf[:] != bytes(4096)
    os.close(d)
    return n
def wsync(fd, a, b):
    try:
        for i in range(a, b):
            os.pwrite(fd, (b"%08d" % (i * 4)) * 512, i * 4 * 4096)
        os.fsync(fd)
        return "0"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))
fd = os.open(f, os.O_RDWR)
out = ["first=" + wsync(fd, 0, 16)]
knob("tree_target_nospc", "1")
out.append("setup=" + wsync(fd, 16, 24))
knob("tree_target_nospc", "0")
out += ["s1=%d" % stat("journal_slots_stuck"), "l1=%d" % live()]
k0 = stat("journal_reused_kept")
knob("journal_reused_zeroed", zeroed)
knob("journal_entry_nospc", "2")
out.append("act=" + wsync(fd, 24, 32))
knob("journal_entry_nospc", "0")
knob("journal_reused_zeroed", "0")
out += ["s2=%d" % stat("journal_slots_stuck"), "l2=%d" % live(), "kept=%d" % (stat("journal_reused_kept") - k0)]
print(" ".join(out), flush=True)
try:
    os.close(fd)
except OSError:
    pass
EOF
}
# check <file> <to>: every block i*4 (i < to) holds its number
check() { python3 -I - "$1" "$2" <<'EOF'
import os, sys
f, n = sys.argv[1], int(sys.argv[2])
fd = os.open(f, os.O_RDONLY)
bad = sum(os.pread(fd, 4096, i * 16384) != (b"%08d" % (i * 4)) * 512 for i in range(n))
os.close(fd)
print("ok" if bad == 0 else "bad%d" % bad)
EOF
}

# <tag> <zeroed 0|1> -> RES
round() {
    local dev proc node js jb mark rep
    dev="$(ct_dev 560 "jbrk$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")/info"
    node="$(sed -n 's/^this_node_id: //p' "$proc")"
    js="$("$SBPOKE" "$dev" | sed -n 's/^node_journal_start=//p')"
    jb="$("$SBPOKE" "$dev" | sed -n 's/^node_journal_blocks=//p')"
    fallocate -l 8M "$MNT/img"
    mark="$(dmesg_mark)"
    RES="$(acts "$MNT/img" "$dev" "$proc" $((js + node * jb + 1)) $(((jb - 1) / 2)) "$2")"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    RES="$RES stays=$(dmesg_since "$mark" | grep -c 'the kept entry it was to supersede stays' || true)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    rep="$(dmesg_since "$mark" | grep -cE 'journal replay: node [0-9]+ replayed [1-9]' || true)"
    RES="$RES replayed=$rep data=$(check "$MNT/img" 24)"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (zeroed): $C"
[ "$(get first "$R")" = 0 ] && [ "$(get setup "$R")" = ENOSPC ] && [ "$(get setup "$C")" = ENOSPC ] ||
    { fail "setup: the leaf's target was not refused: $R / $C"; ct_exit; }
[ "$(get s1 "$R")" = 1 ] && [ "$(get l1 "$R")" -ge 1 ] && [ "$(get s1 "$C")" = 1 ] ||
    { fail "setup: the refused target left no kept entry ($R / $C)"; ct_exit; }
[ "$(get l2 "$R")" = "$(get l1 "$R")" ] && [ "$(get s2 "$R")" = 1 ] && [ "$(get kept "$R")" = 1 ] &&
    pass "1: the kept entry is still on the device and its slot held" || fail "1: $R"
[ "$(get stopped "$R")" -ge 1 ] && [ "$(get stays "$R")" -ge 1 ] && pass "2: the mount stopped, saying the kept entry stays" ||
    fail "2: $R"
[ "$(get replayed "$R")" -ge 1 ] && [ "$(get data "$R")" = ok ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "3: the remount replayed it; every block of the setup's write reads back, fsck clean" || fail "3: $R"
[ "$(get l2 "$C")" -lt "$(get l1 "$C")" ] && [ "$(get stopped "$C")" = 0 ] &&
    pass "control: as before, the batch zeroed the kept entry and the mount ran on ($C)" ||
    fail "control: $C -- the act does not reach the batch's retire"
ct_exit
