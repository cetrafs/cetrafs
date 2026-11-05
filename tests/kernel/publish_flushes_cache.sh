#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a publish is ordered against what it names, and against the free after it, by a cache flush
#
# Completed is not durable. On a volatile write cache two writes that
# completed in order can survive a power cut in either order. Every
# publish is an ordering claim of that kind:
#   - before it: the record names blocks whose data, leaves and bitmap
#     bits were written first (rule 8) -- close, writeback, truncate,
#     punch, fallocate, defrag;
#   - after it: a free relies on the publish having reached the device
#     (rule 21) -- truncate, punch, defrag, evict.
# Only fsync, the journal and (since the last fix) sync/unmount flushed.
#
# The block layer counts flush requests per device (field 16 of
# /sys/block/<dev>/stat). Each operation below must issue its flushes;
# the control repeats it with publish_flush_skip=1 and must count none,
# which proves the flushes counted are the publish points' and not
# something else's.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/publish_flush_skip ] || { skip "publish_flush_skip is missing"; ct_exit; }

IMG="$(ct_image 560 pubflush)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pubflush)"
ct_mkfs_small "$DEV" >/dev/null
ST="/sys/block/$(basename "$DEV")/stat"
[ "$(wc -w <"$ST")" -ge 17 ] || { skip "this kernel does not count flush requests in $ST"; ct_exit; }
flushes() { awk '{ print $16 }' "$ST"; }
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
sleep 2

# close_flushes <file>: the flushes counted across the close of a write fd
# whose data was written into newly allocated blocks.
close_flushes() {
    python3 - "$1" "$ST" <<'PY'
import os, sys
def fl():
    return int(open(sys.argv[2]).read().split()[15])
f = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
os.write(f, os.urandom(64 * 4096))
b = fl()
os.close(f)
print(fl() - b)
sys.stdout.flush()
PY
}

# op_flushes <command...>: the flushes counted across <command>.
op_flushes() {
    local B
    B="$(flushes)"
    "$@"
    echo $(($(flushes) - B))
}

check() {
    local what="$1" n="$2" min="$3" ctl="$4"
    log "$what: $n flush(es); with publish_flush_skip: $ctl"
    [ "$n" -ge "$min" ] && pass "$what issued $n cache flush(es) (at least $min)" ||
        fail "$what issued $n cache flush(es), fewer than $min: what it publishes or frees is ordered by completion only"
    [ "$ctl" = 0 ] && pass "control: $what with the publish flushes off issued none" ||
        fail "control: $what issued $ctl flush(es) with the publish flushes off -- something else flushes, the count proves nothing"
}

# The close of a writer: one before its publish.
N="$(close_flushes "$MNT/c1")"
ct_param_set publish_flush_skip 1
C="$(close_flushes "$MNT/c2")"
ct_param_set publish_flush_skip 0
check "close after a write" "$N" 1 "$C"

# truncate: one before the publish, one between it and the free.
sync
N="$(op_flushes truncate -s 4096 "$MNT/c1")"
ct_param_set publish_flush_skip 1
C="$(op_flushes truncate -s 4096 "$MNT/c2")"
ct_param_set publish_flush_skip 0
check "truncate" "$N" 2 "$C"

# unlink: the evict flushes before it frees.
dd if=/dev/urandom of="$MNT/u1" bs=4096 count=16 conv=fsync status=none
dd if=/dev/urandom of="$MNT/u2" bs=4096 count=16 conv=fsync status=none
sync
sleep 1
N="$(op_flushes rm -f "$MNT/u1")"
ct_param_set publish_flush_skip 1
C="$(op_flushes rm -f "$MNT/u2")"
ct_param_set publish_flush_skip 0
check "unlink" "$N" 1 "$C"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
