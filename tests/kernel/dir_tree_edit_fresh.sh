#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# under nofilelock a directory's tree edits read the tree fresh, never through the file lock's trust
#
# Growing a directory past its inline extents edits its tree, reading
# the last path down through cetrafs_read_tree_bh_for() -- whose trust
# came from the FILE lock: under nofilelock "no peer has it open", and a
# directory is never open, so a peer's growth of the same directory was
# read from this node's cache. Only the dirent_seq gate ahead of it kept
# that safe, and the comment said "a directory always reads fresh"
# (audit 2026-11-15 F-68). A directory's tree now never trusts its cache
# by a file-lock predicate (cetrafs_tree_cache_trusted()).
#
# A nofilelock mount; a directory is grown, its blocks interleaved with a
# file's so they do not merge, until its tree is external (depth >= 1).
# More creates then grow it further.
#   setup: the directory is depth >= 1;
#   1. the creates that grow it read tree blocks fresh (tree_reads_fresh
#      moves);
#   2. every name reads back, fsck is clean.
#
# DISCRIMINATION: dir_tree_lock_trust=1 restores the file-lock predicate:
# the same growth reads nothing fresh. A single node cannot produce the
# peer's growth this protects against; the read itself is the observable.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dir_tree_lock_trust ] || { skip "dir_tree_lock_trust is missing"; ct_exit; }
IPOKE="$(ct_helper inode_block_poke)"
ct_param_set dir_tree_lock_trust 0

# probe <trust 0|1> -> "<depth> <fresh reads during growth> <names ok> <fsck rc>"
probe() {
    local img dev mnt ino depth f0 f1 ok=yes frc=0
    img="$(ct_image 560 "dtef$1")"
    dev="$(ct_loop "$img")"
    mnt="$(ct_mnt "dtef$1")"
    ct_track mnt "$mnt"
    ct_mkfs "$dev" -z 1 -J 0 -N 4096 -f >/dev/null
    mount -t cetrafs -o nofilelock "$dev" "$mnt"
    mkdir "$mnt/d"
    grow() { # <from> <to>: names in d, each dirent block followed by a data block
        python3 -I - "$mnt" "$1" "$2" <<'PY'
import os, sys
mnt, a, b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
for i in range(a, b):
    open(os.path.join(mnt, "d", "name-%06d-%s" % (i, "x" * 40)), "w").close()
    if i % 40 == 0:
        with open(os.path.join(mnt, "pad%06d" % i), "wb") as f:
            f.write(b"p" * 4096)
            os.fsync(f.fileno())
PY
    }
    grow 0 600
    sync
    ino="$(stat -c %i "$mnt/d")"
    depth="$("$IPOKE" "$img" extents "$ino" 2>/dev/null | sed -n 's/^depth=\([0-9]*\).*/\1/p')"
    echo "$1" >/sys/module/cetrafs/parameters/dir_tree_lock_trust
    f0="$(sed -n 's/^tree_reads_fresh: //p' "$(ct_procdir "$dev")/info")"
    grow 600 1400
    f1="$(sed -n 's/^tree_reads_fresh: //p' "$(ct_procdir "$dev")/info")"
    echo 0 >/sys/module/cetrafs/parameters/dir_tree_lock_trust
    [ "$(ls "$mnt/d" | wc -l)" = 1400 ] || ok=no
    umount "$mnt"
    ct_fsck "$dev" >/dev/null 2>&1 || frc=$?
    echo "${depth:-?} $((f1 - f0)) $ok $frc"
}

read -r D F OK FRC <<<"$(probe 0)"
[ "$D" != "?" ] && [ "$D" -ge 1 ] || { fail "setup: the directory's tree is depth $D, not external"; ct_exit; }
pass "setup: the directory's tree is depth $D"
[ "$F" -gt 0 ] && pass "1: growing it read $F tree blocks fresh" || fail "1: growing it read no tree block fresh"
[ "$OK" = yes ] && [ "$FRC" = 0 ] && pass "2: all 1,400 names list; fsck clean" || fail "2: names ok: $OK, fsck rc $FRC"
read -r D F OK FRC <<<"$(probe 1)"
[ "$F" = 0 ] && pass "control: with the file-lock predicate the same growth reads nothing fresh -- the suite discriminates" ||
    fail "control: $F fresh reads with the old predicate -- the suite cannot tell"
ct_exit
