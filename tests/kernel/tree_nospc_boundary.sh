#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a held-back tree-block write refused for space fails the boundary with ENOSPC; the mount runs on
#
# Any refused metadata write stopped the mount (audit 2026-11-14 A-4).
# A regular file's extent-leaf edits wait in core and reach the device at
# a boundary, in one journal batch: the entries, a flush, then the leaves
# in place. A DEFINITE refusal now leaves the mount up:
#   - of the entries: nothing of the batch landed; the entries are
#     retired and the leaves stay held back;
#   - of a leaf (its entry durable): the entry stays live for replay --
#     the state a crash right there leaves -- and the leaf stays held
#     back.
# Either way the boundary fails with ENOSPC and the next one retries.
#
# A preallocated image with every 4th block written (its map in a leaf),
# then more such writes and an fsync, with:
#   E. every journal entry write refused (journal_entry_nospc);
#   T. every leaf target write refused (tree_target_nospc);
# each: fsync fails ENOSPC, the mount runs on, refusals are counted; the
# refusals stop and the next fsync lands; after a remount every block
# written reads back and fsck is clean.
#
# DISCRIMINATION: tree_refusal_stops=1 (as before): E stops the mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in tree_refusal_stops tree_target_nospc journal_entry_nospc; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
LP="$(ct_helper leaf_poke)"
MNT="$(ct_mnt tnb)"
ct_track mnt "$MNT"
ct_param_set tree_refusal_stops 0
ct_param_set tree_target_nospc 0
ct_param_set journal_entry_nospc 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
# wsync <file> <from> <to>: write blocks from*4 .. (to-1)*4, each its own
# number, then fsync; "0" or the errno name of the fsync
wsync() { python3 -I - "$@" <<'PY'
import errno, os, sys
f, a, b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    fd = os.open(f, os.O_RDWR)
    try:
        for i in range(a, b):
            os.pwrite(fd, (b"%08d" % (i * 4)) * 512, i * 4 * 4096)
        os.fsync(fd)
    finally:
        os.close(fd)
    print(0)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
PY
}
fs() { python3 -I -c '
import errno, os, sys
try:
    fd = os.open(sys.argv[1], os.O_RDWR)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    print(0)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$1"; }
# check <file> <to>: every block i*4 (i < to) holds its number
check() { python3 -I - "$1" "$2" <<'PY'
import os, sys
f, n = sys.argv[1], int(sys.argv[2])
fd = os.open(f, os.O_RDONLY)
bad = sum(os.pread(fd, 4096, i * 16384) != (b"%08d" % (i * 4)) * 512 for i in range(n))
os.close(fd)
print("ok" if bad == 0 else "bad%d" % bad)
PY
}

# <tag> <stops 0|1> -> RES
round() {
    local img dev mark proc n ino leaf e t
    img="$(ct_image 560 "tnb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    fallocate -l 8M "$MNT/img"
    [ "$(wsync "$MNT/img" 0 24)" = 0 ] || { RES="setup=fsync"; ct_umount "$MNT"; return; }
    ino="$(stat -c %i "$MNT/img")"
    leaf="$("$LP" "$img" leaf "$ino" 2>/dev/null || true)"
    [ -n "$leaf" ] && [ "$leaf" -gt 0 ] 2>/dev/null || { RES="setup=noleaf"; ct_umount "$MNT"; return; }
    n="$(sed -n 's/^tree_refusals: //p' "$proc/info")"
    echo "$2" >$P/tree_refusal_stops
    mark="$(dmesg_mark)"
    echo 100000 >$P/journal_entry_nospc
    e="$(wsync "$MNT/img" 24 48)"
    sleep 2
    echo 0 >$P/journal_entry_nospc
    RES="setup=ok e=$e e_after=$(fs "$MNT/img")"
    echo 100000 >$P/tree_target_nospc
    t="$(wsync "$MNT/img" 48 72)"
    sleep 2
    echo 0 >$P/tree_target_nospc
    echo 0 >$P/tree_refusal_stops
    RES="$RES t=$t t_after=$(fs "$MNT/img")"
    RES="$RES refusals=$(($(sed -n 's/^tree_refusals: //p' "$proc/info" 2>/dev/null || echo "$n") - n))"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    if [ "$(get stopped "$RES")" = 0 ]; then
        ct_mount "$dev" "$MNT"
        RES="$RES data=$(check "$MNT/img" 72)"
        ct_umount "$MNT"
        RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
    fi
}

round c 1
C="$RES"
log "control (a refusal stops): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get setup "$R")" = ok ] && [ "$(get setup "$C")" = ok ] ||
    { fail "setup: the file never got an extent leaf ($R / $C)"; ct_exit; }
[ "$(get e "$R")" = ENOSPC ] && [ "$(get e_after "$R")" = 0 ] &&
    pass "E: the batch's entries refused: fsync failed ENOSPC, and landed once they were not" || fail "E: $R"
[ "$(get t "$R")" = ENOSPC ] && [ "$(get t_after "$R")" = 0 ] &&
    pass "T: the leaf's write refused: fsync failed ENOSPC, and landed once it was not" || fail "T: $R"
[ "$(get stopped "$R")" = 0 ] && [ "$(get refusals "$R")" -ge 2 ] &&
    pass "the mount ran on; refusals counted" || fail "mount: $R"
[ "$(get data "$R")" = ok ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "after a remount every block written reads back and fsck is clean" || fail "remount: $R"
[ "$(get stopped "$C")" -ge 1 ] && pass "control: with refusals stopping, the mount stopped ($C)" ||
    fail "control: $C -- the injection does not reach the tree batch"
ct_exit
