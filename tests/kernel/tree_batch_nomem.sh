#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a tree batch short of memory fails its boundary with ENOMEM, sends nothing, and the mount runs on
#
# A regular file's held-back extent-leaf edits reach the device at a
# boundary in one journal batch. Running out of memory while preparing
# it was taken for the device's answer: a buffer that could not be had
# stopped the mount as an unknown outcome, and status arrays that could
# not be had were counted as the device refusing for space (audit
# 2026-11-22 N-29). And an entry prepared before the shortage was left
# held, for the heartbeat's flush to write later into a slot the batch
# had given up. Everything is now taken before anything is published; a
# shortage aborts what it took, gives the slots back, and the boundary
# fails with ENOMEM, the blocks still held back.
#
# A preallocated file whose map spans several leaves; writes at both ends
# and an fsync -- a batch of at least two leaves -- with memory running
# out (journal_batch_nomem) at
#   B. the second entry's buffers;
#   A. the status arrays;
# each: fsync fails ENOMEM, the mount runs on, nothing is counted as a
# device refusal; the next fsync lands; after a remount every block
# written reads back and fsck is clean.
#
# DISCRIMINATION: journal_batch_nomem_old=1 (as before): B stops the
# mount; A fails ENOSPC, counted as a refusal.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in journal_batch_nomem journal_batch_nomem_old; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt tbnm)"
ct_track mnt "$MNT"
ct_param_set journal_batch_nomem 0
ct_param_set journal_batch_nomem_old 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
# wsync <file> <off> <blocks...>: write each named block with its number,
# then fsync; "0" or the errno name
wsync() { python3 -I - "$@" <<'PY'
import errno, os, sys
f = sys.argv[1]
try:
    fd = os.open(f, os.O_RDWR)
    try:
        for b in sys.argv[2:]:
            b = int(b)
            os.pwrite(fd, (b"%08d" % b) * 512, b * 4096)
        os.fsync(fd)
    finally:
        os.close(fd)
    print(0)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
PY
}
# check <file> <blocks...>: every named block holds its number
check() { python3 -I - "$@" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
bad = sum(os.pread(fd, 4096, int(b) * 4096) != (b"%08d" % int(b)) * 512 for b in sys.argv[2:])
print("ok" if bad == 0 else "bad%d" % bad)
PY
}

# <tag> <old 0|1> -> RES
round() {
    local dev mark proc n0 r0 b a b_after a_after written
    dev="$(ct_dev 560 "tbnm$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    fallocate -l 16M "$MNT/img"
    # every 4th block of 4096: ~2000 extents, the map over several leaves
    written="$(seq 0 4 4095 | tr '\n' ' ')"
    # shellcheck disable=SC2086
    [ "$(wsync "$MNT/img" $written)" = 0 ] || { RES="setup=fsync"; ct_umount "$MNT"; return; }
    n0="$(sed -n 's/^journal_batch_nomem: //p' "$proc/info")"
    r0="$(sed -n 's/^tree_refusals: //p' "$proc/info")"
    echo "$2" >$P/journal_batch_nomem_old
    mark="$(dmesg_mark)"
    echo 1 >$P/journal_batch_nomem
    b="$(wsync "$MNT/img" 1 4093)"
    b_after="$(wsync "$MNT/img" 2 4094)"
    echo 2 >$P/journal_batch_nomem
    a="$(wsync "$MNT/img" 5 4089)"
    a_after="$(wsync "$MNT/img" 6 4090)"
    echo 0 >$P/journal_batch_nomem
    echo 0 >$P/journal_batch_nomem_old
    RES="setup=ok b=$b b_after=$b_after a=$a a_after=$a_after"
    RES="$RES batch=$(dmesg_since "$mark" | grep -oP 'no memory to send a batch of \K[0-9]+' | head -1 || true)"
    RES="$RES nomem=$(($(sed -n 's/^journal_batch_nomem: //p' "$proc/info" 2>/dev/null || echo "$n0") - n0))"
    RES="$RES refusals=$(($(sed -n 's/^tree_refusals: //p' "$proc/info" 2>/dev/null || echo "$r0") - r0))"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    if [ "$(get stopped "$RES")" = 0 ]; then
        ct_mount "$dev" "$MNT"
        # shellcheck disable=SC2086
        RES="$RES data=$(check "$MNT/img" $written 1 4093 2 4094 5 4089 6 4090)"
        ct_umount "$MNT"
        RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
    fi
}

round f 0
R="$RES"
log "fixed: $R"
round c 1
C="$RES"
log "control (as before): $C"
[ "$(get setup "$R")" = ok ] && [ "$(get setup "$C")" = ok ] || { fail "setup: $R / $C"; ct_exit; }
[ "${R#*batch=}" != "$R" ] && [ "$(get batch "$R")" -ge 2 ] 2>/dev/null ||
    { fail "setup: the batch that ran short held fewer than two blocks ($R)"; ct_exit; }
[ "$(get b "$R")" = ENOMEM ] && [ "$(get b_after "$R")" = 0 ] &&
    pass "B: buffers short: fsync failed ENOMEM, and the next one landed" || fail "B: $R"
[ "$(get a "$R")" = ENOMEM ] && [ "$(get a_after "$R")" = 0 ] &&
    pass "A: arrays short: fsync failed ENOMEM, and the next one landed" || fail "A: $R"
[ "$(get stopped "$R")" = 0 ] && [ "$(get nomem "$R")" = 2 ] && [ "$(get refusals "$R")" = 0 ] &&
    pass "the mount ran on; two shortages counted, no device refusal" || fail "counts: $R"
[ "$(get data "$R")" = ok ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "after a remount every block written reads back and fsck is clean" || fail "remount: $R"
[ "$(get stopped "$C")" -ge 1 ] && pass "control: as before, the buffer shortage stopped the mount ($C)" ||
    fail "control: $C -- the shortage does not reach the batch"
ct_exit
