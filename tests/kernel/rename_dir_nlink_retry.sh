#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a rename over a directory retries the replaced directory's count, as over a file
#
# Renaming over an empty directory zeroes its link count by a swap made
# after its name is gone. That swap got one attempt, while the replaced
# file's -1 got three and a report: one refused swap left the directory
# unreachable and allocated until fsck (audit 2026-11-14 N8).
#
# One injected refusal (rename_nlink_fail=1) on `mv -T x d`, both empty
# directories: the retry must land it, and fsck must be clean.
#
# DISCRIMINATION: rename_dir_one_attempt gives the directory its single
# swap back; the same refusal then leaves fsck reporting the directory.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in rename_nlink_fail rename_dir_one_attempt; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MNT="$(ct_mnt rndir)"
ct_track mnt "$MNT"
ct_param_set rename_nlink_fail 0
ct_param_set rename_dir_one_attempt 0
P=/sys/module/cetrafs/parameters

# <one_attempt 0|1> -> "<injection fired yes|no> <fsck lines naming the directory>"
probe() {
    local dev d out fired
    dev="$(ct_loop "$(ct_image 560 "rndir$1")")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/x" "$MNT/d"
    sync
    d="$(stat -c %i "$MNT/d")"
    echo "$1" >$P/rename_dir_one_attempt
    echo 1 >$P/rename_nlink_fail
    mv -T "$MNT/x" "$MNT/d"
    [ "$(cat $P/rename_nlink_fail)" = 0 ] && fired=yes || fired=no
    echo 0 >$P/rename_nlink_fail
    echo 0 >$P/rename_dir_one_attempt
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    echo "$fired $(grep -cE "^(ERR|WARN).*\b$d\b" <<<"$out" || true)"
}

read -r F N <<<"$(probe 0)"
[ "$F" = yes ] || fail "setup: the injected refusal did not fire"
[ "$N" = 0 ] && pass "a refused swap is retried: fsck has nothing on the replaced directory" ||
    fail "the replaced directory is still reported by fsck ($N line(s))"
read -r F0 N0 <<<"$(probe 1)"
[ "$F0" = yes ] && [ "$N0" -gt 0 ] && pass "control: one attempt leaves the directory for fsck ($N0 line(s)) -- the suite discriminates" ||
    fail "control: one attempt: fired=$F0, $N0 fsck line(s) -- the suite cannot tell"
ct_exit
