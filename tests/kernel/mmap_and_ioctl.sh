#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# shared writable mappings, and the ioctl surface
#
# mmap had no coverage at all. The question that matters for a clustered
# filesystem is what holds the cross-node exclusive lock: .release only
# runs when the last reference to the struct file goes, and a live
# mapping holds one -- so close() on a mapped file must NOT release the
# lock, or a peer could claim the file while this node is still writing
# to it through the mapping.
#
# The ioctl surface is small (one command) but its refusals are what
# keep it safe: the write-open IS the cross-node exclusivity, so a
# read-only fd must not be able to start a relocation.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 mmap)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mmap)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "a shared writable mapping reaches the device"
dd if=/dev/zero of="$MNT/m" bs=4096 count=16 status=none
sync
python3 - "$MNT" <<'PY'
import mmap, os, sys
f = open(sys.argv[1] + "/m", "r+b")
mm = mmap.mmap(f.fileno(), 16 * 4096)
mm[0:8] = b"MAPPED!!"
mm[4096 * 15:4096 * 15 + 8] = b"LASTPAGE"
mm.flush()
mm.close()
f.close()
PY
sync
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(head -c 8 "$MNT/m")" = "MAPPED!!" ] && pass "a write through a shared mapping survives a remount" ||
    fail "the first page reads '$(head -c 8 "$MNT/m")'"
[ "$(dd if="$MNT/m" bs=1 skip=$((4096 * 15)) count=8 status=none)" = "LASTPAGE" ] &&
    pass "so does a write to the last page" || fail "the last page did not survive"

log "a live mapping keeps the cross-node lock held past close()"
# .release runs when the last reference to the struct file drops, and a
# mapping holds one. If close() released the lock, a peer could claim a
# file this node is still writing to through its mapping.
INO="$(stat -c '%i' "$MNT/m")"
OUT="$(python3 - "$MNT" "$LOCK_POKE" "$IMG" "$INO" <<'PY'
import mmap, os, subprocess, sys
mnt, poke, img, ino = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def lock():
    return subprocess.run([poke, img, ino], capture_output=True, text=True).stdout.strip()

f = open(mnt + "/m", "r+b")
mm = mmap.mmap(f.fileno(), 4096)
print("while-open:" + lock())
f.close()                      # fd gone, mapping still alive
mm[0:4] = b"LIVE"
mm.flush()
print("after-close:" + lock())
mm.close()                     # now the last reference goes
import time
time.sleep(0.3)
print("after-munmap:" + lock())
PY
)"
echo "$OUT" | sed 's/^/    /'
echo "$OUT" | grep -q "^while-open:owner=0 mode=1" &&
    pass "the write lock is held while the file is open and mapped" ||
    fail "the lock was not held during the mapping: $(echo "$OUT" | grep while-open)"
echo "$OUT" | grep -q "^after-close:owner=0 mode=1" &&
    pass "close() with a live mapping does NOT release the lock" ||
    fail "close() released the lock while a mapping was still writing: $(echo "$OUT" | grep after-close)"
echo "$OUT" | grep -q "^after-munmap:owner=65535" &&
    pass "munmap releases it" ||
    fail "the lock survived munmap: $(echo "$OUT" | grep after-munmap)"
[ "$(head -c 4 "$MNT/m")" = "LIVE" ] && pass "the write made after close() through the mapping landed" ||
    fail "the post-close mapped write was lost"

log "mmap's own refusals"
OUT="$(python3 - "$MNT" <<'PY'
import mmap, os, sys, errno
mnt = sys.argv[1]
# writable shared mapping of a read-only fd must be refused
f = open(mnt + "/m", "rb")
try:
    mmap.mmap(f.fileno(), 4096, flags=mmap.MAP_SHARED, prot=mmap.PROT_WRITE)
    print("rw-on-ro:allowed")
except (PermissionError, OSError) as e:
    print("rw-on-ro:" + errno.errorcode.get(e.errno, str(e.errno)))
f.close()
# a private mapping may be written and must not reach the file
f = open(mnt + "/m", "rb")
mm = mmap.mmap(f.fileno(), 4096, flags=mmap.MAP_PRIVATE, prot=mmap.PROT_READ | mmap.PROT_WRITE)
mm[0:7] = b"PRIVATE"
mm.close()
f.close()
print("private-wrote:" + open(mnt + "/m", "rb").read(7).decode())
PY
)"
# Both branches of this used to call pass(), so the suite reported
# success whether the mapping was refused OR allowed -- a test that
# could not fail. The probe prints "rw-on-ro:allowed" when the kernel
# permits it, which is the one outcome that must be a failure; any errno
# is a refusal and acceptable (EACCES is what Linux returns, but the
# property under test is "refused", not "refused with this errno").
RWRO="$(echo "$OUT" | grep '^rw-on-ro:' || true)"
[ -n "$RWRO" ] || fail "the mmap probe printed no rw-on-ro result -- it did not run"
case "$RWRO" in
    rw-on-ro:allowed) fail "a writable SHARED mapping of a read-only fd was ALLOWED" ;;
    *) pass "a writable shared mapping of a read-only fd is refused ($RWRO)" ;;
esac
echo "$OUT" | grep -q "private-wrote:LIVE" &&
    pass "a private mapping's writes never reach the file" ||
    fail "a MAP_PRIVATE write reached the file: $(echo "$OUT" | grep private-wrote)"

log "the ioctl surface"
OUT="$(python3 - "$MNT" <<'PY'
import fcntl, os, struct, sys, errno
mnt = sys.argv[1]
# _IOR('C', 0x01, struct of 3 u64) -> dir=2, size=24, type='C', nr=1
CETRAFS_IOC_DEFRAG = (2 << 30) | (24 << 16) | (ord('C') << 8) | 1
buf = bytearray(24)

def t(path, flags, cmd, label):
    try:
        fd = os.open(path, flags)
    except OSError as e:
        print(label + ":openfail-" + errno.errorcode.get(e.errno, str(e.errno)))
        return
    try:
        fcntl.ioctl(fd, cmd, buf, True)
        print(label + ":ok")
    except OSError as e:
        print(label + ":" + errno.errorcode.get(e.errno, str(e.errno)))
    finally:
        os.close(fd)

t(mnt + "/m", os.O_RDONLY, CETRAFS_IOC_DEFRAG, "defrag-ro")
t(mnt + "/m", os.O_RDWR, CETRAFS_IOC_DEFRAG, "defrag-rw")
t(mnt + "/m", os.O_RDWR, (2 << 30) | (24 << 16) | (ord('C') << 8) | 0x7f, "unknown-cmd")
t(mnt, os.O_RDONLY | os.O_DIRECTORY, CETRAFS_IOC_DEFRAG, "defrag-on-dir")
PY
)"
echo "$OUT" | sed 's/^/    /'
echo "$OUT" | grep -q "^defrag-ro:EBADF" &&
    pass "defrag on a read-only fd is refused: the write-open IS the exclusivity" ||
    fail "defrag on a read-only fd: $(echo "$OUT" | grep defrag-ro)"
echo "$OUT" | grep -q "^defrag-rw:ok" && pass "defrag on a write fd runs" ||
    fail "defrag on a write fd: $(echo "$OUT" | grep defrag-rw)"
echo "$OUT" | grep -q "^unknown-cmd:ENOTTY" && pass "an unknown ioctl gives ENOTTY" ||
    fail "an unknown ioctl: $(echo "$OUT" | grep unknown-cmd)"
echo "$OUT" | grep -qE "^defrag-on-dir:(ENOTTY|EBADF|EISDIR)" &&
    pass "defrag on a directory is refused ($(echo "$OUT" | sed -n 's/^defrag-on-dir://p'))" ||
    fail "defrag on a directory: $(echo "$OUT" | grep defrag-on-dir)"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_exit
