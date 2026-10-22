#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# extended attributes: the full surface, and the boundaries
#
# Existing coverage was four assertions inside posix_file_ops.sh. The
# xattr block is a dense array of fixed-size entries with a hard cap on
# the key length (64), the value length (256) and the number of entries
# that fit one block -- so this is a feature defined almost entirely by
# its boundaries, and the boundaries are what nothing checked.
#
# tmpfs is the reference for the behaviour cetrafs implements; where it
# deliberately does less (only user.*), that is asserted as a refusal
# rather than compared.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 xattr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt xattr)"
REF="$(ct_mnt xattrref)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "the error contract matches tmpfs"
OUT="$(python3 - "$MNT" "$REF" <<'PY'
import os, sys, errno
def t(tag, label, fn):
    try:
        fn(); print("%s|%s|ok" % (tag, label))
    except OSError as e:
        print("%s|%s|%s" % (tag, label, errno.errorcode.get(e.errno, e.errno)))
for root, tag in ((sys.argv[1], "fs"), (sys.argv[2], "ref")):
    p = root + "/f"
    open(p, "w").write("x")
    t(tag, "set", lambda: os.setxattr(p, b"user.a", b"1"))
    t(tag, "create-on-existing", lambda: os.setxattr(p, b"user.a", b"2", os.XATTR_CREATE))
    t(tag, "replace-on-missing", lambda: os.setxattr(p, b"user.zz", b"2", os.XATTR_REPLACE))
    t(tag, "get-missing", lambda: os.getxattr(p, b"user.zz"))
    t(tag, "remove-missing", lambda: os.removexattr(p, b"user.zz"))
    t(tag, "empty-value", lambda: os.setxattr(p, b"user.e", b""))
PY
)"
for case in set create-on-existing replace-on-missing get-missing remove-missing empty-value; do
    got="$(echo "$OUT" | sed -n "s/^fs|$case|//p")"
    want="$(echo "$OUT" | sed -n "s/^ref|$case|//p")"
    [ "$got" = "$want" ] && pass "$case -> $got (matches tmpfs)" ||
        fail "$case: cetrafs '$got', tmpfs '$want'"
done

log "the boundaries of a fixed-size entry"
OUT="$(python3 - "$MNT" <<'PY'
import os, sys, errno
p = sys.argv[1] + "/b"
open(p, "w").write("x")
def t(label, fn):
    try:
        r = fn(); print("%s|%s" % (label, "ok" if r is None else repr(r)))
    except OSError as e: print("%s|%s" % (label, errno.errorcode.get(e.errno, e.errno)))
# key[] is 64 bytes including the NUL, so a 63-character name is the
# largest that fits and 64 must be refused.
t("name-63", lambda: os.setxattr(p, b"user." + b"n" * 58, b"v"))
t("name-64", lambda: os.setxattr(p, b"user." + b"n" * 59, b"v"))
# value[] is 256 bytes, so 256 fits exactly and 257 must not.
t("value-256", lambda: os.setxattr(p, b"user.v256", b"A" * 256))
t("value-257", lambda: os.setxattr(p, b"user.v257", b"A" * 257))
t("value-256-readback", lambda: os.getxattr(p, b"user.v256") == b"A" * 256)
PY
)"
echo "$OUT" | grep -q "^name-63|ok" && pass "a 63-character name is accepted (the largest that fits)" ||
    fail "name-63: $(echo "$OUT" | grep name-63)"
echo "$OUT" | grep -q "^name-64|ENAMETOOLONG" && pass "a 64-character name is refused" ||
    fail "name-64: $(echo "$OUT" | grep name-64)"
echo "$OUT" | grep -q "^value-256|ok" && pass "a 256-byte value is accepted (the largest that fits)" ||
    fail "value-256: $(echo "$OUT" | grep value-256)"
echo "$OUT" | grep -q "^value-257|E2BIG" && pass "a 257-byte value is refused" ||
    fail "value-257: $(echo "$OUT" | grep value-257)"
echo "$OUT" | grep -q "^value-256-readback|True" && pass "the 256-byte value reads back whole" ||
    fail "the maximum-length value did not round-trip"

log "running out of room in the one block is an honest ENOSPC"
OUT="$(python3 - "$MNT" <<'PY'
import os, sys, errno
p = sys.argv[1] + "/many"
open(p, "w").write("x")
n = 0
try:
    for i in range(64):
        os.setxattr(p, ("user.k%02d" % i).encode(), b"v")
        n += 1
except OSError as e:
    print("stopped|%d|%s" % (n, errno.errorcode.get(e.errno, e.errno)))
else:
    print("stopped|%d|none" % n)
print("listed|%d" % len(os.listxattr(p)))
PY
)"
echo "$OUT" | grep -q "|ENOSPC" && pass "filling the block stops with ENOSPC, not silent truncation ($(echo "$OUT" | sed -n 's/^stopped|\([0-9]*\).*/\1/p') set)" ||
    fail "filling the block: $(echo "$OUT" | grep stopped)"
SET="$(echo "$OUT" | sed -n 's/^stopped|\([0-9]*\).*/\1/p')"
LISTED="$(echo "$OUT" | sed -n 's/^listed|//p')"
[ "$SET" = "$LISTED" ] && pass "every attribute that was accepted is listed back ($LISTED)" ||
    fail "$SET were accepted but $LISTED are listed"

log "listxattr's buffer-size convention"
OUT="$(python3 - "$MNT" <<'PY'
import ctypes, os, sys, errno
libc = ctypes.CDLL(None, use_errno=True)
p = (sys.argv[1] + "/b").encode()
need = libc.listxattr(p, None, 0)
print("need|%d" % need)
buf = ctypes.create_string_buffer(max(need - 1, 1))
r = libc.listxattr(p, buf, need - 1)
print("small|%d|%s" % (r, errno.errorcode.get(ctypes.get_errno(), "") if r < 0 else ""))
buf = ctypes.create_string_buffer(need)
print("exact|%d" % libc.listxattr(p, buf, need))
PY
)"
NEED="$(echo "$OUT" | sed -n 's/^need|//p')"
[ "$NEED" -gt 0 ] && pass "listxattr with size 0 reports the space required ($NEED bytes)" ||
    fail "listxattr(size=0) returned $NEED"
echo "$OUT" | grep -q "^small|-1|ERANGE" && pass "a buffer one byte short gives ERANGE" ||
    fail "a short buffer: $(echo "$OUT" | grep small)"
[ "$(echo "$OUT" | sed -n 's/^exact|//p')" = "$NEED" ] && pass "a buffer of exactly that size succeeds" ||
    fail "an exact-sized buffer: $(echo "$OUT" | grep exact)"

log "the block is given back when the last attribute goes"
avail() { df --output=avail "$MNT" | tail -1; }
: >"$MNT/acct"
sync
FREE_NOXATTR="$(avail)"
python3 -c "
import os, sys
os.setxattr(sys.argv[1] + '/acct', b'user.one', b'v')" "$MNT"
sync
[ "$(avail)" -lt "$FREE_NOXATTR" ] && pass "the first attribute allocates a block" ||
    fail "setting an attribute consumed no space"
python3 -c "
import os, sys
p = sys.argv[1] + '/acct'
for k in os.listxattr(p):
    os.removexattr(p, k)" "$MNT"
sync
[ "$(avail)" = "$FREE_NOXATTR" ] && pass "removing the last attribute frees it again" ||
    fail "free space is $(avail), was $FREE_NOXATTR before any attribute existed"

log "only user.* -- the other namespaces are refused, not half-stored"
for ns in trusted.t security.s system.posix_acl_access; do
    if setfattr -n "$ns" -v x "$MNT/b" 2>/dev/null; then
        fail "a '$ns' attribute was accepted"
    else
        pass "'$ns' is refused"
    fi
done
# Nothing from a refused namespace may appear in the listing.
python3 -c "
import os, sys
names = os.listxattr(sys.argv[1] + '/b')
sys.exit(0 if all(n.startswith('user.') for n in names) else 1)" "$MNT" &&
    pass "every listed name is in the user namespace" || fail "a non-user.* name was listed"

log "attributes survive a remount"
python3 -c "
import os, sys
p = sys.argv[1] + '/persist'
open(p, 'w').write('x')
os.setxattr(p, b'user.keep', b'value-that-persists')" "$MNT"
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
python3 -c "
import os, sys
p = sys.argv[1] + '/persist'
assert os.getxattr(p, b'user.keep') == b'value-that-persists', os.getxattr(p, b'user.keep')
assert os.listxattr(p) == ['user.keep'], os.listxattr(p)" "$MNT" &&
    pass "an attribute reads back identically after a remount" ||
    fail "the attribute did not survive a remount"

ct_umount "$MNT"
# Capture first, grep after (pipefail). The leak grep is the control for
# fsck walking xattr_block: without it, the surviving user.keep block
# reads as "marked in use but referenced by no inode".
FSCK_OUT="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean" ||
    fail "fsck: $(printf '%s\n' "$FSCK_OUT" | tail -3)"
printf '%s\n' "$FSCK_OUT" | grep "referenced by no inode" >/dev/null &&
    fail "the xattr block was reported as a leak" ||
    pass "the xattr block is referenced, not a phantom leak"
ct_exit
