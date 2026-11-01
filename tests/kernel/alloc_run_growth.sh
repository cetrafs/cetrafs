#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a streaming file's speculative runs grow, so it pays one bitmap sync per big run, not per MiB
#
# The extent tree is never edited while an allocation bit is only in
# cache (cetrafs_tree_append()), so every speculative run costs one
# synchronous bitmap write before the first block of it is mapped. At a
# fixed 256-block run that is one per MiB of a growing file: measured on
# a real LUN, a 4 GiB stream into an open spilled file went from 90-92
# to 83-86 MB/s. A file that streams through whole runs now gets each
# next one twice as long, up to alloc_run_max_blocks (16 MiB), and the
# same stream measured 90-91 MB/s. Small files stay at the base run.
#
# A loop device cannot show the time, so this counts the writes, with
# the file still open (a close is a durability boundary and would flush
# the data into the count).
#
# DISCRIMINATION: the suite runs the same stream with the cap pinned to
# the base run (the fixed-run behaviour) and requires it to cost several
# times more device writes.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PROBE="$(ct_tmp rungrow-probe.py)"
cat >"$PROBE" <<'PY'
import os, sys
def writes():
    return int(open(sys.argv[2]).read().split()[4])
fd = os.open(sys.argv[1], os.O_RDWR)
buf = b'z' * (1 << 20)
w0 = writes()
for i in range(64):
    os.pwrite(fd, buf, 65536 + i * (1 << 20))
print(writes() - w0)  # counted with the fd still open
os.close(fd)
PY

WRITES=0
stream_writes() { # <alloc_run_max_blocks>: sets WRITES
    local dev mnt rc=0 out
    dev="$(ct_dev 560 "rungrow$1")"
    mnt="$(ct_mnt "rungrow$1")"
    ct_mkfs_small "$dev" >/dev/null
    ct_param_set alloc_run_blocks 0
    ct_param_set auto_defrag 0
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"
    for i in $(seq 0 7); do # spill to an external leaf
        dd if=/dev/zero of="$mnt/f" bs=4096 seek="$i" count=1 conv=notrunc status=none
        printf x >"$mnt/fill$i"
    done
    sync
    ct_param_set alloc_run_blocks 256
    ct_param_set alloc_run_max_blocks "$1"
    WRITES="$(python3 "$PROBE" "$mnt/f" "/sys/block/$(basename "$dev")/stat")"
    sync
    ct_umount "$mnt"
    out="$(ct_fsck "$dev" 2>&1)" || rc=$?
    [ "$rc" = 0 ] || fail "max=$1: fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -1)"
}

stream_writes 4096
grow="$WRITES"
stream_writes 256
fixed="$WRITES"
log "device writes during a 64 MiB stream: growing runs $grow, fixed 256-block runs $fixed"
[ "$fixed" -ge 40 ] && pass "control: fixed runs pay about one bitmap write per MiB ($fixed)" ||
    fail "control: fixed runs cost only $fixed writes -- the stream did not exercise the run path"
[ "$grow" -le 16 ] && [ $((grow * 4)) -le "$fixed" ] &&
    pass "growing runs cut the bitmap writes to $grow (from $fixed)" ||
    fail "growing runs cost $grow device writes against $fixed fixed -- the runs are not growing"
ct_exit
