#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a write that strips security.capability completes instead of waiting on itself
#
# A write to a file that carries security.capability drops the capability:
# file_remove_privs() -> notify_change() -> cetrafs_setattr(), which holds the
# inode's namespace lock; setattr_prepare() then runs security_inode_killpriv()
# -> __vfs_removexattr() -> cetrafs_xattr_handler_set(), which took the SAME
# namespace lock again. The namespace mutex is not re-entrant, so the writer
# slept on itself in D state for ever. Found by the O_DIRECT overwrite suite
# (dio_overwrite_shared.sh), which writes to such a file on purpose.
#
# Both write paths are checked: a buffered write (the exclusive path) and an
# O_DIRECT overwrite (which must route to the exclusive path, since stripping
# a privilege is a setattr). Each must return the full count, leave the file
# with no security.capability, and keep the bytes.
#
# DISCRIMINATION: xattr_nested_wait=1 restores the second acquire. The writer
# then hangs, and the suite kills it at its deadline and requires that to be
# the failure: a hang is the bug, and it cannot be reported any other way
# (the process is in an uninterruptible wait that a timeout cannot end, so the
# control kills it with SIGKILL, which the namespace mutex's killable wait honours).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/xattr_nested_wait ] || { skip "xattr_nested_wait is missing"; ct_exit; }

DEV="$(ct_dev 560 xattrnest)"
MNT="$(ct_mnt xattrnest)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# A vfs_cap_data blob, revision 2: magic, then permitted/inheritable pairs.
# Its contents do not matter to the strip; the xattr's presence does.
CAP_PY='
import os, sys, struct
p, mode = sys.argv[1], sys.argv[2]
BS = 4096
blob = struct.pack("<I4I", 0x02000000, 0, 0, 0, 0)
fd = os.open(p, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o755)
os.write(fd, b"A" * (4 * BS)); os.fsync(fd); os.close(fd)
os.setxattr(p, "security.capability", blob)
want = bytearray(b"A" * (4 * BS))
data = b"B" * BS
if mode == "buffered":
    fd = os.open(p, os.O_RDWR)
    n = os.pwrite(fd, data, BS); os.fsync(fd); os.close(fd)
else:
    import mmap, ctypes
    m = mmap.mmap(-1, 2 * BS)
    o = (-ctypes.addressof(ctypes.c_char.from_buffer(m))) % BS
    m[o:o + BS] = data
    fd = os.open(p, os.O_RDWR | os.O_DIRECT)
    n = os.pwrite(fd, memoryview(m)[o:o + BS], BS); os.close(fd)
want[BS:2 * BS] = data
try:
    os.getxattr(p, "security.capability")
    stripped = False
except OSError:
    stripped = True
fd = os.open(p, os.O_RDONLY)
got = os.pread(fd, 4 * BS, 0); os.close(fd)
print("RESULT n=%d stripped=%d data=%s" % (n, int(stripped), "ok" if got == bytes(want) else "BAD"))
sys.stdout.flush()
'

# run_writer <mode> <file>: the writer in its own process, with a deadline
# that kills it. Prints its RESULT line, or HUNG when it had to be killed.
run_writer() {
    local mode="$1" p="$2" pid rc=0 out
    out="$(ct_tmp "xattrnest_$(basename "$p")")"
    python3 -c "$CAP_PY" "$p" "$mode" >"$out" 2>&1 &
    pid=$!
    for _ in $(seq 1 60); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        echo "HUNG"
        return 0
    fi
    wait "$pid" || rc=$?
    if [ "$rc" != 0 ]; then
        echo "ERROR rc=$rc $(tr '\n' ' ' <"$out")"
        return 0
    fi
    grep '^RESULT' "$out" || echo "NORESULT $(tr '\n' ' ' <"$out")"
}

for mode in buffered direct; do
    R="$(run_writer "$mode" "$MNT/caps_$mode")"
    case "$R" in
        RESULT*"n=4096 stripped=1 data=ok"*) pass "$mode: the write returned the full count, stripped security.capability, and kept its bytes" ;;
        HUNG) fail "$mode: the write hung -- it waited on the namespace lock it already held" ;;
        *) fail "$mode: $R" ;;
    esac
done

# Negative control: the second acquire restored. The writer must hang.
ct_param_set xattr_nested_wait 1
R="$(run_writer buffered "$MNT/caps_control")"
ct_param_set xattr_nested_wait 0
case "$R" in
    HUNG) pass "control: with the nesting check removed the same write hangs, and the suite catches it" ;;
    *) fail "control: with the nesting check removed the write did not hang -- the check cannot discriminate: $R" ;;
esac

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null && pass "fsck clean after the strips" || fail "fsck found faults after the strips"

ct_exit
