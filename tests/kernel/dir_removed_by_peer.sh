#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory a peer removed is not read or written through its old extents
#
# rmdir on one node zeroes the directory's nlink and gives its blocks back.
# Another node that still had the directory cached (a cwd, an open fd, a
# dentry) kept resolving names in it: only adding an entry checked the
# record it had just read fresh for nlink 0 or a new generation. Lookup,
# readdir, unlink, rename and the '..' update walked the dead directory's
# extents -- blocks the allocator may already have given to another
# directory -- found that directory's entries, and removed or retargeted
# them without its namespace lock and without its dirent_seq moving.
#
# The peer's rmdir is played on the device (nlink set to 0 under this
# node's cached directory); the check is that this node neither finds a
# name in it nor writes to its block.
#
# DISCRIMINATION (measured with the check only in add_entry): the name
# resolves and the unlink rewrites the dead directory's block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

REC_POKE="$(ct_helper inode_block_poke)"
EXTENT="$(ct_helper pending_poke)"
IMG="$(ct_image 560 drp)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt drp)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/x"
: >"$MNT/x/n"
sync
XINO="$(stat -c %i "$MNT/x")"
BLK="$("$EXTENT" "$IMG" extent "$XINO" | cut -d' ' -f1)"
[ -n "$BLK" ] && [ "$BLK" -gt 0 ] || { fail "setup: no dirent block found for directory ino $XINO"; ct_exit; }
blk_sum() { dd if="$IMG" bs=4096 skip="$BLK" count=1 status=none | sha256sum | cut -d' ' -f1; }
# This node holds the directory open -- a cwd or a dirfd, from which a
# lookup starts WITHOUT revalidating the directory itself (a path through
# "x/" would, and stop there).
GO="$(mktemp -u /tmp/cetrafs-drp-go-XXXXXX)"
READY="$(mktemp -u /tmp/cetrafs-drp-ready-XXXXXX)"
OUT="$(mktemp /tmp/cetrafs-drp-out-XXXXXX)"
ct_track file "$GO"
ct_track file "$READY"
ct_track file "$OUT"
python3 -I - "$MNT/x" "$READY" "$GO" >"$OUT" 2>&1 <<'PY' &
import errno, os, sys, time
dfd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
os.stat("n", dir_fd=dfd)
open(sys.argv[2], "w").close()
while not os.path.exists(sys.argv[3]):
    time.sleep(0.05)
def attempt(what, fn):
    try:
        fn()
        print(what + "=0")
    except OSError as e:
        print(what + "=" + errno.errorcode.get(e.errno, str(e.errno)))
attempt("lookup", lambda: os.stat("n", dir_fd=dfd))
attempt("unlink", lambda: os.unlink("n", dir_fd=dfd))
sys.stdout.flush()
os.close(dfd)
PY
PID=$!
for i in $(seq 1 100); do [ -e "$READY" ] && break; sleep 0.1; done

log "a peer removes directory x (ino $XINO, block $BLK)"
"$REC_POKE" "$IMG" nlink "$XINO" 0 2>/dev/null
BEFORE="$(blk_sum)"
: >"$GO"
wait "$PID" || true
LOOKUP="$(sed -n 's/^lookup=//p' "$OUT")"
UNLINK="$(sed -n 's/^unlink=//p' "$OUT")"
log "through the held directory: lookup=$LOOKUP unlink=$UNLINK"

[ "$LOOKUP" != 0 ] && pass "lookup in the removed directory finds nothing ($LOOKUP)" ||
    fail "a name still resolves in a directory a peer removed"
[ "$UNLINK" != 0 ] && pass "unlink in the removed directory is refused ($UNLINK)" ||
    fail "unlink succeeded in a directory a peer removed"
[ "$(blk_sum)" = "$BEFORE" ] && pass "the removed directory's block is untouched" ||
    fail "the removed directory's block was rewritten -- it may belong to another directory by now"

# No fsck: the directory's name is still in the root, over a record that
# reads nlink 0 -- the simulation, which fsck rightly reports.
umount "$MNT"
ct_exit
