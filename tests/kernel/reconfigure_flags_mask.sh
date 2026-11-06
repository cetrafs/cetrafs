#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a reconfigure refuses a read-only flip only when it asks for one
#
# The VFS changes only the superblock flags named in sb_flags_mask. The
# reconfigure compared fc->sb_flags' SB_RDONLY with the mount's without
# looking at the mask, so on a read-only mount a reconfigure through the
# new mount API that never mentions ro or rw (fspick builds it with
# sb_flags = 0) read as "read-only -> read-write" and was refused
# (audit 2026-11-06 L26).
#
# On a read-only mount: a reconfigure naming no flag must succeed and
# leave the mount read-only; one asking for rw must still be refused.
#
# DISCRIMINATION: ignoring the mask, the flagless reconfigure is refused.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PICK="$(ct_helper fspick_reconfigure)"

DEV="$(ct_dev 560 rcfmask)"
MNT="$(ct_mnt rcfmask)"
ct_mkfs_small "$DEV" >/dev/null
mount -t cetrafs -o ro "$DEV" "$MNT"
ct_track mnt "$MNT"
require_cetrafs_mount "$MNT"
ro() { findmnt -no OPTIONS "$MNT" | tr ',' '\n' | grep -qx ro; }
ro || { fail "setup: the mount is not read-only"; ct_exit; }

R="$("$PICK" "$MNT" rw || true)"
case "$R" in
"err 38") skip "this kernel has no fspick/fsconfig"; ct_exit ;;
err*) pass "a reconfigure asking for read-write is refused ($R)" ;;
*) fail "a reconfigure asking for read-write was accepted" ;;
esac
ro || fail "the mount became read-write"

R="$("$PICK" "$MNT" || true)"
[ "$R" = ok ] && pass "a reconfigure naming neither ro nor rw succeeds" ||
    fail "a reconfigure naming neither ro nor rw was refused ($R) -- read as a read-only flip it never asked for"
ro && pass "and the mount is still read-only" || fail "the mount became read-write"
umount "$MNT"
ct_exit
