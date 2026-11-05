#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an rmdir that cannot read its victim fails with the directory still named
#
# rmdir removed the name first and read the victim's record after, so a
# read error there returned EIO with the directory already unnamed: gone
# from the namespace, its record still nlink 2, reachable by nobody, and
# never freed (audit L4). The record is now read before the name goes.
#
# rmdir_victim_read_fail fails that read once.
#
# DISCRIMINATION: with the read back after the removal, the failed rmdir
# leaves no name.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/rmdir_victim_read_fail ] || { skip "rmdir_victim_read_fail is missing"; ct_exit; }

DEV="$(ct_dev 560 rmdirerr)"
MNT="$(ct_mnt rmdirerr)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"

ct_param_set rmdir_victim_read_fail 1
if rmdir "$MNT/d" 2>/dev/null; then
    ct_param_set rmdir_victim_read_fail 0
    fail "setup: the rmdir succeeded although its read was to fail"
    ct_exit
fi
ct_param_set rmdir_victim_read_fail 0
ls "$MNT" | grep -qx d && pass "the rmdir failed with the directory still named" ||
    fail "the failed rmdir left the directory unnamed"
rmdir "$MNT/d" && pass "and a second rmdir removes it" || fail "the directory cannot be removed afterwards"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean: nothing left unreachable"
ct_exit
