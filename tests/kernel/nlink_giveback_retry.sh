#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a link or rename whose name never landed gives its +1 back, retried, and says so if it cannot
#
# link() and a rename of a file raise the link count before the new
# name is written, so a failure in between never leaves a name the count
# does not cover. When the name write fails, the +1 is given back -- by
# one swap whose result nobody read. A refused swap left the count one
# high, silently, and the file was then never freed: its last unlink
# drops it to 1, not 0 (audit 2026-11-06 L4).
#
# For link and for rename, with the name write made to fail
# (link_name_fail_once, rename_name_fail_once):
#   A: the give-back refused once -- the retry must land it, and fsck
#      find nothing wrong with the file's count;
#   B: refused every time -- the count left high must be reported.
#
# DISCRIMINATION: with the single unchecked swap A leaves fsck reporting
# the count, and B logs nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in link_name_fail_once rename_name_fail_once rename_nlink_fail; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done

DEV="$(ct_dev 560 nlinkgb)"
MNT="$(ct_mnt nlinkgb)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

try() { # <op> <name>: run op with its name write failing; prints the inode
    local op="$1" f="$MNT/$2"
    echo data >"$f"
    sync
    local ino; ino="$(stat -c %i "$f")"
    if [ "$op" = link ]; then
        ct_param_set link_name_fail_once 1
        ln "$f" "$f.2" 2>/dev/null && { fail "setup: $op succeeded with its name write failing"; ct_exit; }
        [ "$(cat /sys/module/cetrafs/parameters/link_name_fail_once)" = N ] || { fail "setup: the link's name fault did not fire"; ct_exit; }
    else
        ct_param_set rename_name_fail_once 1
        mv "$f" "$f.2" 2>/dev/null && { fail "setup: $op succeeded with its name write failing"; ct_exit; }
        [ "$(cat /sys/module/cetrafs/parameters/rename_name_fail_once)" = N ] || { fail "setup: the rename's name fault did not fire"; ct_exit; }
    fi
    echo "$ino"
}

for op in link rename; do
    # A: one refusal
    ct_param_set rename_nlink_fail 1
    INO="$(try "$op" "a_$op")"
    LEFT="$(cat /sys/module/cetrafs/parameters/rename_nlink_fail)"
    ct_param_set rename_nlink_fail 0
    [ "$LEFT" = 0 ] || { fail "$op A: setup: the give-back was never refused ($LEFT left)"; ct_exit; }
    [ "$(stat -c %h "$MNT/a_$op")" = 1 ] && pass "$op A: the in-core count is back to 1" ||
        fail "$op A: the in-core count is $(stat -c %h "$MNT/a_$op")"
    # B: every attempt refused
    MARK="$(dmesg_mark)"
    ct_param_set rename_nlink_fail 3
    INOB="$(try "$op" "b_$op")"
    ct_param_set rename_nlink_fail 0
    dmesg_since "$MARK" | grep -q "$op: un-.* ino=$INOB kept a link count one too high" &&
        pass "$op B: the count left high is reported, naming inode $INOB" ||
        fail "$op B: a give-back that never landed said nothing"
    eval "A_$op=$INO"
done
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
for op in link rename; do
    eval "I=\$A_$op"
    grep -qE "^(ERR|WARN).*inode $I\b" <<<"$OUT" &&
        fail "$op A: fsck finds inode $I's count wrong: $(grep -E "inode $I\b" <<<"$OUT" | head -1)" ||
        pass "$op A: the retry landed the give-back (fsck has nothing on inode $I)"
done
ct_exit
