#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a chmod of a directory never re-publishes this node's stale size over a peer's
#
# A directory's size and blocks are moved only by namespace operations,
# each of which writes the record itself, synchronously. The one path
# that publishes a directory's FILE sector from core -- setattr, through
# cetrafs_write_vfs_inode()'s three-way merge -- therefore had nothing
# of its own to add to them, but merged them against a baseline those
# direct writes never updated: after a local create (core and device
# S1, baseline still S0) and a peer's removal (device back to S0, equal
# to the baseline, so "unchanged"), the merge kept OUR S1 and wrote it
# over the peer's.
#
# The peer is played by inode_block_poke setsize. fchmod on an open fd,
# so no lookup refreshes the directory first.
#
# Every directory size/blocks change is staged and published through
# cetrafs_write_raw_inode_fd(), which installs the baseline since
# 581db98; the other direct directory writes move only times, the dirent
# stamp, or nlink on a dead record.
#
# DISCRIMINATION (measured with that baseline install removed): the
# fchmod published 798 over the peer's 532.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

DEV="$(ct_dev 560 dirsz)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt dirsz)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/d"
DINO="$(stat -c %i "$MNT/d")"
S0="$("$IPOKE" "$BACK" size "$DINO")"
res="$(python3 - "$MNT/d" "$IPOKE" "$BACK" "$DINO" "$S0" <<'PY'
import os, subprocess, sys
d, poke, back, ino, s0 = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
fd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
os.close(os.open(d + "/x", os.O_CREAT | os.O_WRONLY, 0o644))  # local create: S0 -> S1
s1 = subprocess.check_output([poke, back, "size", ino]).decode().strip()
subprocess.run([poke, back, "setsize", ino, s0], check=True, stderr=subprocess.DEVNULL)  # the peer
os.fchmod(fd, 0o750)
after = subprocess.check_output([poke, back, "size", ino]).decode().strip()
print(s1, after)
PY
)"
read -r S1 AFTER <<<"$res"
log "directory size: before create $S0, after create $S1, peer set $S0, after fchmod $AFTER"
[ "$S1" != "$S0" ] && pass "setup: the create moved the directory's size ($S0 -> $S1)" ||
    { fail "setup: the create did not change the size"; ct_exit; }
[ "$AFTER" = "$S0" ] && pass "the fchmod left the peer's size alone" ||
    fail "the fchmod published $AFTER over the peer's $S0 -- this node's stale size won"
[ "$(stat -c %a "$MNT/d")" = 750 ] && pass "the chmod itself landed" || fail "mode is $(stat -c %a "$MNT/d")"

ct_umount "$MNT"
ct_exit
