#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an orphan fsck links into lost+found keeps its file type in the directory entry
#
# fsck typed every non-directory it recovered as a regular file. The
# entry's type is what readdir hands out as d_type, and `find -type l`,
# fts, rsync and tar trust it without a stat -- so a recovered symlink
# was missed by all of them (audit 2026-11-06 L26). The kernel derives
# it from the mode (cetrafs_dirent_type()); fsck now does the same.
#
# Staged: a symlink and a regular file whose names are erased. After
# fsck -r both are in /lost+found; readdir must type the symlink as one.
#
# DISCRIMINATION: typing DIR-or-REG, the symlink reads as a regular file.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
CPOKE="$(ct_helper corrupt_poke)"

DEV="$(ct_dev 560 lftype)"
MNT="$(ct_mnt lftype)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ln -s /some/target "$MNT/sl"
echo data >"$MNT/reg"
SL="$(stat -c %i "$MNT/sl")"
RG="$(stat -c %i "$MNT/reg")"
ROOT_INO="$(stat -c %i "$MNT")"
ct_umount "$MNT"
"$CPOKE" "$DEV" dirent "$ROOT_INO" sl >/dev/null
"$CPOKE" "$DEV" dirent "$ROOT_INO" reg >/dev/null
blockdev --flushbufs "$DEV"
"$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || true

ct_mount "$DEV" "$MNT"
dtype() { python3 -c 'import os,sys
for e in os.scandir(sys.argv[1]):
    if e.name == sys.argv[2]:
        print("lnk" if e.is_symlink() else "dir" if e.is_dir(follow_symlinks=False) else "reg" if e.is_file(follow_symlinks=False) else "other")' "$MNT/lost+found" "$1"; }
[ -L "$MNT/lost+found/#$SL" ] && [ -f "$MNT/lost+found/#$RG" ] ||
    { fail "setup: the orphans were not recovered: $(ls -la "$MNT/lost+found" 2>&1 | tr '\n' '|')"; ct_umount "$MNT"; ct_exit; }
pass "setup: both orphans are in /lost+found (stat agrees: symlink and regular file)"
T="$(dtype "#$SL")"
[ "$T" = lnk ] && pass "readdir types the recovered symlink as a symlink" ||
    fail "readdir types the recovered symlink as '$T'"
T="$(dtype "#$RG")"
[ "$T" = reg ] && pass "and the regular file as a regular file" || fail "the regular file reads as '$T'"
ct_umount "$MNT"
ct_exit
