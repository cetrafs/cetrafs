#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# sendfile, splice and copy_file_range work, and a stopped mount refuses them
#
# cetrafs_file_ops had no splice_read/splice_write, and since 6.5 the VFS
# fails sendfile(2), splice(2) and copy_file_range()'s fallback with
# EINVAL when they are missing: cp --reflink=auto, rsync's sendfile path,
# anything zero-copy, out of a VM image or into one.
#
# And a stopped mount refuses a splice read, as it refuses read(2).
#
# DISCRIMINATION: without the two ops all four copies fail with EINVAL.
# The stopped-mount check is a plain assertion, not a discriminator:
# filemap_splice_read in place of copy_splice_read passes it too (the
# stop drops the page cache), measured when the ops were added.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 splice)"
MNT="$(ct_mnt splice)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
head -c 300000 /dev/urandom >"$MNT/src"
WANT="$(sha256sum <"$MNT/src" | cut -d' ' -f1)"
OUTSIDE="$(ct_tmp spliceout)"

RES="$(python3 - "$MNT" "$OUTSIDE" <<'PY'
import errno, os, sys
mnt, outside = sys.argv[1], sys.argv[2]
src = mnt + "/src"
size = os.stat(src).st_size
def run(name, fn):
    try:
        fn(); print(name, "ok")
    except OSError as e:
        print(name, errno.errorcode.get(e.errno, str(e.errno)))
def sendfile_to(dst):
    i = os.open(src, os.O_RDONLY); o = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    off = 0
    while off < size:
        n = os.sendfile(o, i, off, size - off)
        if n == 0: raise OSError(errno.EIO, "short")
        off += n
    os.close(i); os.close(o)
def splice_pipe(dst):
    i = os.open(src, os.O_RDONLY); o = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    r, w = os.pipe()
    left = size
    while left:
        n = os.splice(i, w, min(left, 65536))
        if n == 0: raise OSError(errno.EIO, "short")
        m = 0
        while m < n:
            m += os.splice(r, o, n - m)
        left -= n
    os.close(i); os.close(o); os.close(r); os.close(w)
def cfr(dst):
    i = os.open(src, os.O_RDONLY); o = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    left = size
    while left:
        n = os.copy_file_range(i, o, left)
        if n == 0: raise OSError(errno.EIO, "short")
        left -= n
    os.close(i); os.close(o)
run("sendfile-out", lambda: sendfile_to(outside))       # cetrafs -> elsewhere (splice_read)
run("sendfile-in", lambda: sendfile_to(mnt + "/sf"))     # cetrafs -> cetrafs (both)
run("splice", lambda: splice_pipe(mnt + "/sp"))
run("copy_file_range", lambda: cfr(mnt + "/cfr"))
PY
)"
log "$(tr '\n' ' ' <<<"$RES")"
while read -r name r; do
    case "$name" in
    sendfile-out) f="$OUTSIDE" ;; sendfile-in) f="$MNT/sf" ;; splice) f="$MNT/sp" ;; copy_file_range) f="$MNT/cfr" ;;
    esac
    if [ "$r" = ok ] && [ "$(sha256sum <"$f" | cut -d' ' -f1)" = "$WANT" ]; then
        pass "$name: copied, and the copy matches"
    else
        fail "$name: $r$([ "$r" = ok ] && echo ', but the copy differs')"
    fi
done <<<"$RES"

# A stopped mount refuses reads -- spliced ones too, even from cache.
# The fd is opened BEFORE the stop: the open is not what is under test.
cat "$MNT/src" >/dev/null
R="$(python3 - "$MNT/src" "$OUTSIDE" "$(ct_procdir "$DEV")/controls" <<'PY'
import errno, os, sys, time
i = os.open(sys.argv[1], os.O_RDONLY)
o = os.open(sys.argv[2], os.O_WRONLY | os.O_TRUNC)
open(sys.argv[3], "w").write("shutdown=now\n")
time.sleep(1)
try:
    print("served %d" % os.sendfile(o, i, 0, 65536))
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e.errno)))
PY
)"
grep -q '^stopped: manual' "$(ct_procdir "$DEV")/info" || fail "setup: the mount did not stop"
case "$R" in
served*) fail "a stopped mount served sendfile from its page cache ($R)" ;;
*) pass "a stopped mount refuses sendfile ($R)" ;;
esac
umount "$MNT" || umount -l "$MNT"
ct_exit
