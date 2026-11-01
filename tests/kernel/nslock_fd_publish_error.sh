#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory's size survives a transient failure of the namespace release's file-sector publish
#
# A create or unlink stages the directory's new size, and the namespace
# lock's release publishes it -- the file sector first, then the
# namespace sector that clears the lock. The second step retries until
# it commits; the first gave up on its first failure, logged "fsck-
# visible, repaired by -r", and went on. Neither half of that held:
# fsck does not check a directory's size, and every later create or
# unlink adjusts the size it reads from the device, so one lost publish
# left the size wrong by one entry for good. (The directory's extents
# are not at stake: growth commits them synchronously, before the entry
# is written.)
#
# nslock_fd_publish_fail fails the next N of those publishes.
#
# DISCRIMINATION (measured on the unfixed code): after two creates and
# a remount the directory is 798 bytes instead of 1064 -- and fsck,
# which does not check a directory's size, calls the volume clean.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
DE=266 # sizeof(cetrafs_dirent_t)

DEV="$(ct_dev 560 nsfd)"
MNT="$(ct_mnt nsfd)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/d"
s0="$(stat -c %s "$MNT/d")"
[ "$s0" = $((2 * DE)) ] && pass "setup: an empty directory is $s0 bytes" || { fail "setup: empty dir is $s0"; ct_exit; }

ct_param_set nslock_fd_publish_fail 2 # transient: two attempts fail
: >"$MNT/d/a"
left="$(cat /sys/module/cetrafs/parameters/nslock_fd_publish_fail)"
ct_param_set nslock_fd_publish_fail 0
[ "$left" -lt 2 ] && pass "setup: the create's file-sector publish was failed ($((2 - left)) time(s))" ||
    { fail "setup: the knob was not consumed"; ct_exit; }
: >"$MNT/d/b"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
got="$(stat -c %s "$MNT/d")"
want=$((4 * DE))
[ "$got" = "$want" ] && pass "after remount the directory is $got bytes (2 entries + . and ..)" ||
    fail "after remount the directory is $got bytes, not $want -- a lost publish left it one entry short for good"
ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean" || fail "fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
