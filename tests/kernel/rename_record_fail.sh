#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a rename whose directory record write fails after its dirent landed is never undone into two names
#
# A rename-over rewrites the destination's dirent in place (retarget),
# and a directory moving to another parent rewrites its '..'; each then
# writes the directory's record (mtime, dirent_seq). That record write
# can fail on its own -- a bitmap flush error, a getblk failure, a fence
# -- and the helpers returned its error exactly as if nothing had been
# written. The caller then undid a rename whose name had already landed
# (audit 2026-11-22 N-26):
#   - a file renamed over another: the destination now named the moved
#     file, the replaced file's -1 was skipped, and the undo gave the old
#     name its count back -- the moved file had TWO names and a count of
#     one, so an unlink through either freed blocks the other still named;
#   - a directory renamed over an empty one: the same, a directory with
#     two names;
#   - a directory moved to another parent: '..' named the new parent
#     while the directory stayed in the old one.
#
# rename_record_fail_once fails the record write once AFTER the dirent
# write (bit 0 the retarget, bit 1 the '..'). Each case checks, after a
# remount, the names and counts, and fsck:
#   1. file over file: one name, the moved file's data, nlink 1;
#   2. directory over empty directory: one name, its contents;
#   3. directory to another parent, '..' record failing: the directory
#      stayed where it was, and fsck finds its '..' naming that parent.
#   4. what peers see: the record write that failed was also the one to
#      move the destination directory's dirent_seq, the stamp a peer's
#      cached dirent blocks are judged by (cetrafs_dir_needs_fresh()).
#      Unmoved, a peer kept serving the block from before the landed
#      dirent -- the destination name resolving to the replaced inode --
#      until the directory next changed. A file renamed over another in
#      a DIFFERENT directory, so nothing else of the rename stamps the
#      destination (a same-directory rename's remove does, and a failed
#      '..' is put back by a record write that stamps it): its on-disk
#      dirent_seq must move. Control: with dir_stamp_fallback_off it
#      does not, so the check can see the difference.
#
# DISCRIMINATION (measured on the unfixed code): case 1 leaves both names
# on one inode with nlink 1, case 2 both names on one directory, case 3
# a '..' naming the other parent; fsck reports each. Case 4 is
# discriminated in-suite by its control.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in rename_record_fail_once dir_stamp_fallback_off; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
LPOKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 rnrf)"
MNT="$(ct_mnt rnrf)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

do_rename() {
    python3 -c '
import errno, os, sys
try:
    os.rename(sys.argv[1], sys.argv[2]); print("OK")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$1" "$2"
}
remount() { ct_umount "$MNT"; ct_mount "$DEV" "$MNT"; require_cetrafs_mount "$MNT"; }
fsck_clean() { # <label>
    local frc=0 fo
    ct_umount "$MNT"
    fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
    [ "$frc" = 0 ] && pass "$1: fsck clean" || fail "$1: fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -2 | tr '\n' ' ')"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
}
knob_spent() { [ "$(cat /sys/module/cetrafs/parameters/rename_record_fail_once)" = 0 ]; }

# 1. file over file
mkdir "$MNT/f"
echo moved >"$MNT/f/a"
echo replaced >"$MNT/f/b"
sync
ct_param_set rename_record_fail_once 1
RES="$(do_rename "$MNT/f/a" "$MNT/f/b")"
knob_spent && pass "1: setup: the retarget's record write was failed (rename returned $RES)" ||
    { fail "1: setup: the knob was not consumed -- the rename never reached the retarget"; ct_exit; }
remount
NAMES="$(ls "$MNT/f" | tr '\n' ' ')"
if [ "$NAMES" = "b " ] && [ "$(cat "$MNT/f/b")" = moved ] && [ "$(stat -c %h "$MNT/f/b")" = 1 ]; then
    pass "1: one name, the moved file's data, nlink 1"
else
    fail "1: names '$NAMES', b reads '$(cat "$MNT/f/b" 2>/dev/null)', nlink $(stat -c %h "$MNT/f/b" 2>/dev/null)"
fi
fsck_clean "1"

# 2. directory over an empty directory
mkdir -p "$MNT/d/x" "$MNT/d/y"
echo inside >"$MNT/d/x/keep"
sync
ct_param_set rename_record_fail_once 1
RES="$(do_rename "$MNT/d/x" "$MNT/d/y")"
knob_spent && pass "2: setup: the retarget's record write was failed (rename returned $RES)" ||
    { fail "2: setup: the knob was not consumed"; ct_exit; }
remount
NAMES="$(ls "$MNT/d" | tr '\n' ' ')"
[ "$NAMES" = "y " ] && [ "$(cat "$MNT/d/y/keep" 2>/dev/null)" = inside ] &&
    pass "2: one name, the directory's contents" || fail "2: names '$NAMES', y/keep '$(cat "$MNT/d/y/keep" 2>/dev/null)'"
fsck_clean "2"

# 3. directory to another parent, its '..' record write failing
mkdir -p "$MNT/p1/m" "$MNT/p2"
echo stays >"$MNT/p1/m/keep"
sync
ct_param_set rename_record_fail_once 2
RES="$(do_rename "$MNT/p1/m" "$MNT/p2/m")"
knob_spent && [ "$RES" != OK ] && pass "3: setup: the '..' record write was failed and the rename reported it ($RES)" ||
    { fail "3: setup: knob $(cat /sys/module/cetrafs/parameters/rename_record_fail_once), rename $RES"; ct_exit; }
remount
# The on-disk '..' is fsck's to judge: the VFS answers '..' from its own
# dentry tree, not from the dirent.
[ "$(cat "$MNT/p1/m/keep" 2>/dev/null)" = stays ] && [ ! -e "$MNT/p2/m" ] &&
    pass "3: the directory stayed in p1" ||
    fail "3: p1/m '$(cat "$MNT/p1/m/keep" 2>/dev/null)', p2/m exists: $([ -e "$MNT/p2/m" ] && echo yes || echo no)"
fsck_clean "3"

# 4. the stamp peers judge their cache by
dseq() { blockdev --flushbufs "$DEV"; "$LPOKE" "$DEV" "$1" --rec | sed -n 's/.*dirent_seq=\([0-9]*\).*/\1/p'; }
# stamp_case <tag> <fallback_off 0|1> -> yes | no | unarmed
stamp_case() {
    local d="$MNT/s$1" yino b a r=no
    mkdir -p "$d/x" "$d/y"
    echo moved >"$d/x/a"
    echo replaced >"$d/y/b"
    sync
    yino="$(stat -c %i "$d/y")"
    ct_param_set dir_stamp_fallback_off "$2"
    b="$(dseq "$yino")"
    ct_param_set rename_record_fail_once 1
    do_rename "$d/x/a" "$d/y/b" >/dev/null
    a="$(dseq "$yino")"
    ct_param_set dir_stamp_fallback_off 0
    if ! knob_spent; then
        r=unarmed
    elif [ -n "$b" ] && [ "$a" != "$b" ]; then
        r=yes
    fi
    echo "$r"
}
R="$(stamp_case ctl 1)"
[ "$R" = no ] && pass "4: control: with the fallback off, the destination's dirent_seq stays where it was" ||
    { fail "4: control: the destination's dirent_seq moved: $R -- the check cannot tell"; ct_exit; }
R="$(stamp_case fix 0)"
[ "$R" = yes ] && pass "4: the destination's dirent_seq moved although its record write failed" ||
    fail "4: the destination's dirent_seq: $R"
fsck_clean "4"
ct_exit
