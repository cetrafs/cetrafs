#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repair of root's link count in the run that creates lost+found counts lost+found
#
# fsck -r creates /lost+found when it first needs it, mid-pass, and raises
# root's nlink on disk for it. The root check afterwards compared the
# counts it had tallied before, so when root's count was wrong anyway it
# wrote subdirs + 2 without lost+found -- one short, and the next run
# reported it again (audit 2026-11-06 L10). The same for an orphan
# directory linked into an existing lost+found whose own count was off.
#
# Staged: root with one subdirectory and its nlink poked wrong, and a
# live orphan file that makes the repair create lost+found. One fsck -r;
# then a plain fsck must find root's count right.
#
# DISCRIMINATION: with the pre-tally counts, the second run reports
# root nlink=3 where 4 is expected.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
CPOKE="$(ct_helper corrupt_poke)"

DEV="$(ct_dev 560 lfroot)"
MNT="$(ct_mnt lfroot)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
mkdir "$MNT/keep"
dd if=/dev/urandom of="$MNT/wanted" bs=4096 count=2 status=none
ROOT_INO="$(stat -c %i "$MNT")"
ct_umount "$MNT"
"$CPOKE" "$DEV" dirent "$ROOT_INO" wanted >/dev/null # a live orphan: lost+found will be made
"$IPOKE" "$DEV" nlink "$ROOT_INO" 9 >/dev/null       # and root's count is wrong anyway
blockdev --flushbufs "$DEV"

OUT1="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "root directory has nlink=9" <<<"$OUT1" ||
    { fail "setup: fsck does not see root's wrong count: $(grep -E '^ERR' <<<"$OUT1" | head -2)"; ct_exit; }
R="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
grep -q "created /lost+found" <<<"$R" || { fail "setup: the repair did not create lost+found"; ct_exit; }
OUT2="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "root directory has nlink" <<<"$OUT2" &&
    fail "after one repair root's count is still wrong: $(grep 'root directory has nlink' <<<"$OUT2")" ||
    pass "one repair set root's count including the lost+found it created"
grep -qE '^ERR' <<<"$OUT2" && fail "fsck after the repair: $(grep '^ERR' <<<"$OUT2" | head -3)" ||
    pass "fsck clean after one repair"
ct_exit
