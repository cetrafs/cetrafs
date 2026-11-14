#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a shared-lock O_DIRECT overwrite asks for a capability once, not on every write
#
# The shared O_DIRECT overwrite path (dio_overwrite_shared.sh) must not
# take a write that would strip a privilege. For a file with an xattr
# block it asked the forced-fresh security.capability lookup -- two
# device reads -- on every write(2), on the path that exists to be fast.
# The VFS answers that question once: a write that finds nothing sets
# S_NOSEC (SB_NOSEC comes from get_tree_bdev()), and a chmod +s, a
# security.* setxattr or a peer's identity adopted clears it. The shared
# path now honours and sets it the same way.
#
# A file with an xattr block (a user.* attribute) takes 64 aligned
# O_DIRECT overwrites:
#   1. they ran on the shared path (dio_overwrites moved by 64);
#   2. the capability lookup ran at most once;
#   3. a security.capability set afterwards is still stripped by the
#      next write -- the flag did not outlive what it stood for.
#
# DISCRIMINATION: dio_privs_nosec_off ignores the flag; the lookup then
# runs on every one of the 64 writes.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dio_privs_nosec_off ] || { skip "dio_privs_nosec_off is missing"; ct_exit; }
DEV="$(ct_dev 560 dionosec)"
MNT="$(ct_mnt dionosec)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="/proc/fs/cetrafs/$(basename "$DEV")/info"
ct_param_set dio_privs_nosec_off 0
cnt() { awk -v k="$1:" '$1 == k { print $2 }' "$INFO"; }

writes() { # <file> <n>
    python3 - "$1" "$2" <<'PY'
import mmap, os, sys
buf = mmap.mmap(-1, 4096); buf.write(b"\x5a" * 4096)
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_DIRECT)
for i in range(int(sys.argv[2])):
    assert os.pwrite(fd, buf, (i % 16) * 4096) == 4096
os.close(fd)
PY
}

# <nosec_off> -> "<shared writes> <capability lookups>"
probe() {
    local f="$MNT/f$1" d0 d1 x0 x1
    dd if=/dev/zero of="$f" bs=64k count=1 status=none
    python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.tag", b"x")' "$f"
    sync
    echo "$1" >/sys/module/cetrafs/parameters/dio_privs_nosec_off
    d0="$(cnt dio_overwrites)"; x0="$(cnt dio_privs_xattr_reads)"
    writes "$f" 64
    d1="$(cnt dio_overwrites)"; x1="$(cnt dio_privs_xattr_reads)"
    echo 0 >/sys/module/cetrafs/parameters/dio_privs_nosec_off
    echo "$((d1 - d0)) $((x1 - x0))"
}

read -r D X <<<"$(probe 0)"
log "fixed: $D shared writes, $X capability lookups"
[ "$D" = 64 ] && pass "1: the 64 overwrites ran on the shared path" ||
    { fail "setup: $D of 64 writes took the shared path"; ct_exit; }
[ "$X" -le 1 ] && pass "2: the capability lookup ran $X time(s) for 64 writes" ||
    fail "2: the capability lookup ran $X times for 64 writes"

# The flag must not outlive a capability set after it.
python3 -c '
import os, struct, sys
os.setxattr(sys.argv[1], "security.capability", struct.pack("<IIIII", 0x02000001, 1 << 13, 0, 0, 0))' "$MNT/f0"
writes "$MNT/f0" 1
if python3 -c 'import os,sys; os.getxattr(sys.argv[1], "security.capability")' "$MNT/f0" 2>/dev/null; then
    fail "3: a capability set after the flag survived a write"
else
    pass "3: a capability set after the flag was stripped by the next write"
fi

read -r D0 X0 <<<"$(probe 1)"
[ "$D0" = 64 ] && [ "$X0" -ge 64 ] &&
    pass "control: ignoring the flag, the lookup ran $X0 times for 64 writes -- the suite discriminates" ||
    fail "control: $D0 shared writes, $X0 lookups -- the suite cannot tell"
ct_umount "$MNT"
ct_exit
