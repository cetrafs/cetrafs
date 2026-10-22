#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the three tools' command-line contract
#
# mkfs, fsck and defrag are what an administrator actually touches, and
# nothing tested their surface: what they accept, what they refuse, and
# what they exit with. Exit codes matter more than usual here because
# these are the commands a deployment script branches on -- and fsck's
# in particular, since "fsck said OK" is the whole basis for trusting a
# volume.
#
# Needs no kernel module and no mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root

MKFS="$ROOT/userspace/mkfs.cetra"
FSCK="$ROOT/userspace/fsck.cetra"
DEFRAG="$ROOT/userspace/defrag.cetra"

rc_of() { # <expected-rc> <description> <command...>
    local want="$1" desc="$2" got=0
    shift 2
    "$@" >/dev/null 2>&1 || got=$?
    [ "$got" = "$want" ] && pass "$desc (exit $got)" || fail "$desc: exit $got, expected $want"
}

log "every tool refuses to run with no arguments"
rc_of 2 "mkfs with no device" "$MKFS"   # 2 everywhere: all three tools agree
rc_of 2 "fsck with no device" "$FSCK"
rc_of 2 "defrag with no file" "$DEFRAG"
rc_of 2 "defrag with two files" "$DEFRAG" /etc/hostname /etc/hosts

# mkfs's exit-code contract (aligned with fsck/defrag): 2 = bad invocation
# or out-of-range argument, distinct from a real failure. Each of these
# returned 1 before the contract was aligned, so each discriminates.
log "mkfs rejects bad arguments with the usage code (2), not a failure code"
rc_of 2 "mkfs with an unknown option" "$MKFS" /dev/null -Q
rc_of 2 "mkfs with -z out of range" "$MKFS" /dev/null -z 0 -f
rc_of 2 "mkfs with -N below the minimum" "$MKFS" /dev/null -N 1 -f
rc_of 2 "mkfs with -M above the reader-mask cap" "$MKFS" /dev/null -M 99999 -f
# both MiB arguments overflowed the byte multiplication past
# ~2^44 and fed wrapped garbage into every geometry computation -- each of
# these was accepted (and then failed arbitrarily downstream) before the
# upper clamps, so each discriminates.
rc_of 2 "mkfs with -b past the overflow clamp" "$MKFS" /dev/null -b 1125899906842624 -f
rc_of 2 "mkfs with -J past the overflow clamp" "$MKFS" /dev/null -J 1125899906842624 -f

log "a device that is not there, or not a cetrafs volume"
rc_of 3 "fsck on a path that does not exist (3 = could not examine, distinct from usage)" "$FSCK" /nonexistent-device-xyz
# mkfs now agrees with fsck: a device it cannot access is 3, not a generic
# failure -- so a provisioning script can tell "LUN not reachable / in use"
# (3, retry/skip) from "bad geometry" (1, fix the config).
rc_of 3 "mkfs on a path that does not exist (3 = device inaccessible, matches fsck)" "$MKFS" /nonexistent-device-xyz -f
BLANK="$(ct_image 64 blank)"
BLANK_DEV="$(ct_loop "$BLANK")"
rc_of 1 "fsck on a zeroed device reports bad magic" "$FSCK" "$BLANK_DEV"
FSCK_OUT="$("$FSCK" "$BLANK_DEV" 2>&1 || true)"
echo "$FSCK_OUT" | grep -q "bad magic" && pass "...and says so" || fail "fsck said: $FSCK_OUT"

log "defrag's refusals"
rc_of 1 "defrag on a path that does not exist" "$DEFRAG" /nonexistent-file-xyz
rc_of 1 "defrag on a directory" "$DEFRAG" /tmp
# On any other filesystem the ioctl is unknown, which must be a clean
# failure rather than something surprising.
TMPF="$(ct_tmp defragtarget)"
echo data >"$TMPF"
OUT="$("$DEFRAG" "$TMPF" 2>&1 || true)"
case "$OUT" in
*"not on a cetrafs mount"*) pass "defrag on a non-cetrafs file fails with a comprehensible message" ;;
*) fail "defrag on a non-cetrafs file said: $OUT" ;;
esac

log "fsck's exit code is the contract a deployment script branches on"
GOOD="$(ct_image 560 good)"
GOOD_DEV="$(ct_loop "$GOOD")"
"$MKFS" "$GOOD_DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
rc_of 0 "fsck exits 0 on a healthy volume" "$FSCK" "$GOOD_DEV"
"$FSCK" "$GOOD_DEV" 2>/dev/null | grep -q "cetrafs fsck: OK" &&
    pass "...and says OK on stdout" || fail "fsck printed no OK line"
# Break one byte of the superblock and require BOTH a nonzero exit and a
# message: a tool that exits nonzero silently is as hard to act on as
# one that exits zero wrongly.
dd if=/dev/zero of="$GOOD_DEV" bs=1 seek=8 count=4 conv=notrunc status=none
rc_of 1 "fsck exits nonzero on a damaged superblock" "$FSCK" "$GOOD_DEV"
# Captured, not piped: fsck exits nonzero exactly when it finds what
# this is looking for, and `set -o pipefail` would make the pipeline
# nonzero however well grep matched. The same trap N6 recorded -- and
# the first version of this very assertion fell into it.
BROKE_OUT="$("$FSCK" "$GOOD_DEV" 2>&1 || true)"
echo "$BROKE_OUT" | grep -qE "^ERR" && pass "...and prints an ERR line" ||
    fail "fsck exited nonzero but printed no ERR line: $BROKE_OUT"

log "mkfs refuses to overwrite an existing filesystem without -f"
"$MKFS" "$GOOD_DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
rc_of 1 "mkfs on an existing cetrafs volume without -f" "$MKFS" "$GOOD_DEV" -z 1 -b 512 -J 0 -N 1024
rc_of 0 "mkfs on the same volume with -f" "$MKFS" "$GOOD_DEV" -z 1 -b 512 -J 0 -N 1024 -f
rc_of 0 "a dry run writes nothing and succeeds" "$MKFS" "$GOOD_DEV" -z 1 -b 512 -J 0 -N 1024 -n
rc_of 0 "fsck still passes after the dry run" "$FSCK" "$GOOD_DEV"

ct_exit
