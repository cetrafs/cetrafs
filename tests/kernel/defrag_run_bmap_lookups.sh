#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the defrag run allocator reads each bitmap block once, not once per bit
#
# The defragmenter's destination run was found by testing the bitmap one
# bit at a time -- a cached bitmap read and a CRC per bit -- and claimed
# one bit at a time with a restamp each, all under alloc_mutex, which
# every allocation on the node waits for (audit 2026-11-22 N-10; the
# writer's run claim had the same shape fixed as P2). It is now searched
# word-wise and claimed holding one bitmap block at a time.
#
# A file of 64 extents of 16 blocks each (interleaved with a filler) is
# defragmented by hand:
#   1. it reads back, ends in at most two extents, and fsck is clean;
#   2. the run allocator made far fewer bitmap lookups (info
#      defrag_run_bmap_lookups) than the blocks it moved.
#
# DISCRIMINATION: defrag_run_per_bit=1 (as before): at least one lookup
# per block moved.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
require_file_lock_mode "the defragmenter, which nofilelock disables (nofilelock_no_defrag.sh)"
[ -w /sys/module/cetrafs/parameters/defrag_run_per_bit ] || { skip "defrag_run_per_bit is missing"; ct_exit; }
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_param_set defrag_run_per_bit 0
DEFRAG="$ROOT/userspace/defrag.cetra"
MNT="$(ct_mnt drbl)"
ct_track mnt "$MNT"
P=/sys/module/cetrafs/parameters

# <per_bit 0|1> -> "<lookups> <data ok|bad> <extents after> <fsck ERR lines>"
probe() {
    local dev info l0 l1 sum ok ext err
    dev="$(ct_loop "$(ct_image 560 "drbl$1")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    info="$(ct_procdir "$dev")/info"
    python3 - "$MNT/f" <<'PY'
import os, sys
a = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
b = os.open(sys.argv[1] + ".fill", os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(64):
    os.pwrite(a, os.urandom(16 * 4096), i * 16 * 4096); os.fsync(a)
    os.pwrite(b, b"x" * 4096, i * 4096); os.fsync(b)
os.close(a); os.close(b)
PY
    sum="$(md5sum <"$MNT/f")"
    sync
    echo "$1" >$P/defrag_run_per_bit
    l0="$(sed -n 's/^defrag_run_bmap_lookups: //p' "$info")"
    "$DEFRAG" "$MNT/f" >/dev/null 2>&1 || true
    l1="$(sed -n 's/^defrag_run_bmap_lookups: //p' "$info")"
    echo 0 >$P/defrag_run_per_bit
    ext="$(filefrag "$MNT/f" 2>/dev/null | grep -o '[0-9]* extent' | grep -o '[0-9]*' || echo 99)"
    echo 3 >/proc/sys/vm/drop_caches
    [ "$(md5sum <"$MNT/f")" = "$sum" ] && ok=ok || ok=bad
    ct_umount "$MNT"
    err="$(ct_fsck "$dev" 2>&1 | grep -c '^ERR' || true)"
    echo "$((l1 - l0)) $ok $ext $err"
}
read -r L OK E ERR <<<"$(probe 0)"
log "word-wise: $L lookups, data $OK, $E extent(s) after, fsck ERR $ERR"
read -r L0 OK0 E0 _ <<<"$(probe 1)"
log "control (per bit): $L0 lookups, data $OK0, $E0 extent(s) after"
[ "${E:-99}" -le 2 ] && [ "${E0:-99}" -le 2 ] || { fail "setup: the defrag did not move the file ($E / $E0 extents)"; ct_exit; }
[ "$OK" = ok ] && [ "$ERR" = 0 ] && pass "1: the defragmented file reads back, fsck clean" ||
    fail "1: data $OK, fsck ERR $ERR"
[ "$L" -gt 0 ] && [ "$L" -lt 64 ] && pass "2: 1024 blocks moved with $L bitmap lookups" ||
    fail "2: 1024 blocks moved with $L bitmap lookups"
[ "$L0" -ge 1024 ] && pass "control: bit by bit, $L0 lookups" ||
    fail "control: bit by bit took only $L0 lookups -- the suite does not reach the run allocator"
ct_exit
