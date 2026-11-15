#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a file passing half its extent tree's capacity is announced, once
#
# A file's extent tree holds 258,064 extents at most, and a guest's
# scattered first writes walk it up one entry each; at the limit a write
# needing a new extent fails ENOSPC with the volume free and nothing had
# said it was coming (audit 2026-11-14 A-1). A depth-2 tree passing half
# its leaf blocks now logs a warning naming the file, and info counts it
# (tree_half_full).
#
# The tree is capped (TEST ONLY tree_root_cap=2, tree_idx_cap=4: eight
# leaves) and random 4 KiB O_DIRECT writes go into a preallocated file
# until the first ENOSPC.
#   setup: the file reached its limit;
#   1. the warning named this file, before the limit was reached;
#   2. it came once, and info's tree_half_full went up by one;
#   3. a second file run to its limit adds one more.
#
# DISCRIMINATION: with the warning removed (no tree_half_full line, no
# message) 1-3 fail.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in tree_root_cap tree_idx_cap; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
DEV="$(ct_dev 1200 thfw)"
MNT="$(ct_mnt thfw)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -f >/dev/null
ct_param_set tree_root_cap 2
ct_param_set tree_idx_cap 4
ct_param_set auto_defrag 0
ct_mount "$DEV" "$MNT"
PROC="$(ct_procdir "$DEV")"
NBLK=16384

# <file> -> "writes=<n> enospc=<0|1> at_warn=<writes when the counter moved, or -1>"
drive() {
    python3 -I - "$1" "$NBLK" "$PROC/info" <<'PY'
import os, sys, ctypes, random, errno
path, nblk, info = sys.argv[1], int(sys.argv[2]), sys.argv[3]
def cnt():
    for l in open(info):
        if l.startswith("tree_half_full:"):
            return int(l.split()[1])
    return -1
l = ctypes.CDLL("libc.so.6", use_errno=True)
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
if l.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(nblk * 4096)) != 0:
    sys.exit(3)
os.close(fd)
buf = ctypes.create_string_buffer(8192)
a = (ctypes.addressof(buf) + 4095) & ~4095
mv = (ctypes.c_char * 4096).from_address(a)
mv[:] = b"w" * 4096
fd = os.open(path, os.O_RDWR | os.O_DIRECT)
r = random.Random(7)
c0, done, enospc, at = cnt(), 0, 0, -1
for _ in range(20000):
    try:
        os.pwrite(fd, mv, r.randrange(nblk) * 4096)
    except OSError as e:
        if e.errno == errno.ENOSPC:
            enospc = 1
            break
        raise
    done += 1
    if at < 0 and c0 >= 0 and cnt() > c0:
        at = done
os.close(fd)
print("writes=%d enospc=%d at_warn=%d" % (done, enospc, at), flush=True)
PY
}
get() { sed -n "s/.*$1=\(-\{0,1\}[0-9]*\).*/\1/p" <<<"$2"; }
cnt() { sed -n 's/^tree_half_full: //p' "$PROC/info"; }

C0="$(cnt)"
MARK="$(dmesg_mark)"
R="$(drive "$MNT/a")"
log "a: $R"
INO="$(stat -c %i "$MNT/a")"
[ "$(get enospc "$R")" = 1 ] || { fail "setup: the file never reached its tree's limit ($R)"; ct_exit; }
pass "setup: the file reached its tree's limit after $(get writes "$R") writes"
W="$(dmesg_since "$MARK" | grep -c "ino=$INO: extent tree past half full" || true)"
AT="$(get at_warn "$R")"
[ "$W" -ge 1 ] && [ "$AT" -gt 0 ] && [ "$AT" -lt "$(get writes "$R")" ] &&
    pass "1: the warning named ino $INO at write $AT, before the limit at $(get writes "$R")" ||
    fail "1: no warning before the limit (messages=$W, counter moved at write $AT)"
C1="$(cnt)"
[ "$W" = 1 ] && [ -n "$C0" ] && [ "$((C1 - C0))" = 1 ] && pass "2: once, and tree_half_full went $C0 -> $C1" ||
    fail "2: messages=$W, tree_half_full ${C0:-missing} -> ${C1:-missing}"
R2="$(drive "$MNT/b")"
C2="$(cnt)"
[ "$(get enospc "$R2")" = 1 ] && [ -n "$C1" ] && [ "$((C2 - C1))" = 1 ] && pass "3: a second file adds one ($C1 -> $C2)" ||
    fail "3: second file: $R2, tree_half_full ${C1:-missing} -> ${C2:-missing}"
ct_umount "$MNT"
ct_exit
