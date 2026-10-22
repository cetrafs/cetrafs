#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# security.* and trusted.* extended attributes
#
# The handler took `user.` only, which blocked two real deployments.
# A host running SELinux in ENFORCING mode labels files through
# security.selinux: a filesystem that cannot store it gives its files
# whatever an unlabelled filesystem's default policy allows, which for
# a VM-image store is likely nothing. And overlayfs refuses to use a
# filesystem as an UPPER layer unless it can store trusted.overlay.*.
#
# Compared against tmpfs rather than hardcoded expectations: a
# filesystem that has had this right for years is a better oracle.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 xns)"
LOOPDEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt xns-mnt)"
REF="$(ct_mnt xnsref)"
ct_mkfs_small "$LOOPDEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"
mount -t tmpfs none "$REF"
ct_track mnt "$REF"

OUT="$(python3 - "$MNT" "$REF" <<'PY'
import os, sys, errno

cet, ref = sys.argv[1], sys.argv[2]

def mk(d):
    p = os.path.join(d, "f")
    open(p, "w").close()
    return p

a, b = mk(cet), mk(ref)

def rc(fn):
    try:
        fn()
        return "ok"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))

def both(label, fn):
    # The same operation on cetrafs and on tmpfs; the answers must agree.
    ra, rb = rc(lambda: fn(a)), rc(lambda: fn(b))
    print(("PASS" if ra == rb else "FAIL"), f"{label}: cetrafs={ra} tmpfs={rb}")

both("setting a security.* attribute", lambda p: os.setxattr(p, b"security.cetratest", b"hello"))
both("setting a trusted.* attribute", lambda p: os.setxattr(p, b"trusted.overlay.test", b"up"))
both("setting a user.* attribute", lambda p: os.setxattr(p, b"user.plain", b"u"))

for name, want in ((b"security.cetratest", b"hello"), (b"trusted.overlay.test", b"up")):
    try:
        got = os.getxattr(a, name)
    except OSError as e:
        got = errno.errorcode.get(e.errno, str(e.errno)).encode()
    print(("PASS" if got == want else "FAIL"),
          f"{name.decode()} reads back: got {got!r} want {want!r}")

ca = sorted(os.listxattr(a))
cb = sorted(os.listxattr(b))
print(("PASS" if ca == cb else "FAIL"), f"listxattr returns all three: cetrafs={ca} tmpfs={cb}")

# Removal, per namespace.
for name in (b"security.cetratest", b"trusted.overlay.test"):
    both(f"removing {name.decode()}", lambda p, n=name: os.removexattr(p, n))
print(("PASS" if sorted(os.listxattr(a)) == ["user.plain"] else "FAIL"),
      f"only user.plain is left: {sorted(os.listxattr(a))}")

# Re-set one so the remount check below has something to find. Must not
# raise: against a build without the handlers every call here fails, and
# the point is to REPORT that, not to die before printing anything.
rc(lambda: os.setxattr(a, b"security.cetratest", b"hello"))
PY
)"
echo "$OUT"
echo "$OUT" | grep -q "^FAIL" && fail "namespace behaviour differs from tmpfs (above)" ||
    pass "security.*, trusted.* and user.* all behave as tmpfs does"

log "they survive a remount"
ct_umount "$MNT"
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"
V="$(python3 -c "import os,sys; print(os.getxattr(sys.argv[1], b'security.cetratest').decode())" "$MNT/f" 2>/dev/null || true)"
[ "$V" = "hello" ] && pass "security.* survived the remount" || fail "security.* lost across remount: '$V'"

log "a new file is labelled at creation, not left for a relabel"
# Without security_inode_init_security() the LSM never gets to stamp a
# new inode, so every file lands unlabelled and only a later restorecon
# fixes it. No LSM is active here, so the observable is that the hook is
# wired without breaking creation.
: >"$MNT/fresh" && pass "create still succeeds with the security hook wired" || fail "create failed"
mkdir "$MNT/freshdir" && pass "and mkdir" || fail "mkdir failed"
ln -s t "$MNT/freshlink" && pass "and symlink" || fail "symlink failed"

ct_umount "$MNT"
ct_fsck "$LOOPDEV" >/dev/null
pass "fsck clean"
ct_exit
