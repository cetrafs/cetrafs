#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory move whose '..' rewrite fails changes nothing, and says so
#
# Moving a directory to another parent is three writes: the name into
# the new parent, the name out of the old one, and the directory's own
# '..'. The '..' came LAST, so when it failed the move had already
# happened -- under the new name, out of the old parent -- while
# rename(2) returned an error and '..' still named the old parent. The
# caller believed nothing moved, the tree said it had, and fsck found a
# '..' naming a directory that is not the parent.
#
# '..' is now rewritten first: if that fails, nothing else has been
# touched. If a later step fails before the old name is gone, '..' is
# put back.
#
# rename_dotdot_fail_once fails the '..' rewrite once.
#
# DISCRIMINATION (measured on the unfixed code): rename returns EIO
# and the directory has moved anyway, with fsck reporting its '..' names
# the old parent. With the put-back removed, the ENOSPC case leaves a
# '..' naming the parent the directory never reached.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 rndd)"
MNT="$(ct_mnt rndd)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir -p "$MNT/A/P" "$MNT/B"
echo keep >"$MNT/A/P/inside"
sync

ct_param_set rename_dotdot_fail_once 1
res="$(python3 -c '
import errno, os, sys
try:
    os.rename(sys.argv[1], sys.argv[2]); print("OK")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$MNT/A/P" "$MNT/B/P")"
[ "$(cat /sys/module/cetrafs/parameters/rename_dotdot_fail_once)" = N ] &&
    pass "setup: the '..' rewrite was failed" || { fail "setup: the knob was not consumed"; ct_exit; }
[ "$res" = EIO ] && pass "rename reported the failure (EIO)" || fail "rename returned $res"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
log "after remount: $(cd "$MNT" && find . | sort | tr '\n' ' ')"
[ "$(cat "$MNT/A/P/inside" 2>/dev/null)" = keep ] && [ ! -e "$MNT/B/P" ] &&
    pass "a failed rename left the directory where it was" ||
    fail "the rename failed but the directory moved anyway"
ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean: '..' names the real parent" || fail "fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -2)"

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mv "$MNT/A/P" "$MNT/B/P" && [ "$(cat "$MNT/B/P/inside")" = keep ] && pass "the same move succeeds without the fault" ||
    fail "the move fails without the fault"

log "the name write fails AFTER '..' moved: '..' must be put back"
mkdir "$MNT/C" "$MNT/A/R"
for i in $(seq 1 13); do : >"$MNT/C/f$i"; done # 15 entries with . and ..: C's block is full
dd if=/dev/zero of="$MNT/fill" bs=1M status=none 2>/dev/null || true # and so is the volume
sync
res="$(python3 -c '
import errno, os, sys
try:
    os.rename(sys.argv[1], sys.argv[2]); print("OK")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$MNT/A/R" "$MNT/C/R")"
[ "$res" = ENOSPC ] && pass "setup: the name write failed (ENOSPC), after the '..' rewrite" ||
    { fail "setup: rename returned $res, not ENOSPC -- the name write did not fail"; ct_exit; }
ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean: the failed move put '..' back" || fail "fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
