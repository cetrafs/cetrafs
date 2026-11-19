#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck -r on a volume with journal entries a mount has not replayed gives no clean verdict
#
# A journal entry not yet on its target disables fsck -r (the walk is of
# the volume before a mount replays it; fsck_repair_pending_journal.sh).
# With nothing else wrong, the run still ended "cetrafs fsck: OK", exit
# 0: a script that asked for a repair read "checked and clean" for a
# volume that was neither (audit 2026-11-15 BL-115).
#
# Staged: a clean volume, and one valid journal entry for a directory
# block whose payload differs from the block.
#   setup: fsck sees the entry;
#   1. fsck -r exits 1 and says it gave no verdict, not OK;
#   2. a check alone (no -r) still says OK, exit 0, with its WARN.
#
# DISCRIMINATION: CETRAFS_TEST_FSCK_PENDING_JOURNAL_OK=1 -- fsck -r says
# OK and exits 0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
JPOKE="$(ct_helper journal_poke)"
IMG="$(ct_image 560 fsckpv)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsckpv)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
mkdir "$MNT/D"
: >"$MNT/D/a"
DINO="$(stat -c %i "$MNT/D")"
sync
ct_umount "$MNT"
LBA="$(awk '/^ext 0 /{split($4,a,"="); print a[2]}' <<<"$("$IPOKE" "$DEV" extents "$DINO")")"
[ -n "$LBA" ] || { fail "setup: D's block was not found"; ct_exit; }
PAY="$(ct_tmp fsckpv-pay)"
dd if="$DEV" of="$PAY" bs=4096 skip="$LBA" count=1 status=none
printf '\x5a' | dd of="$PAY" bs=1 seek=2000 conv=notrunc status=none
"$JPOKE" "$DEV" 0 0 "$LBA" "$PAY" --guard-current >/dev/null
blockdev --flushbufs "$DEV"

OUT="$(ct_fsck "$DEV" 2>&1)" && RC=0 || RC=$?
grep -q "not yet applied to block $LBA" <<<"$OUT" || { fail "setup: fsck does not see the pending entry: $OUT"; ct_exit; }
pass "setup: one journal entry for D's block $LBA is pending"
[ "$RC" = 0 ] && grep -q "cetrafs fsck: OK" <<<"$OUT" && pass "2: a check alone still says OK (exit 0), with its WARN" ||
    fail "2: the check exited $RC: $(tail -1 <<<"$OUT")"

OUT="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" && RC=0 || RC=$?
[ "$RC" = 1 ] && grep -q "no verdict" <<<"$OUT" && ! grep -q "cetrafs fsck: OK" <<<"$OUT" &&
    pass "1: fsck -r exits 1 and gives no verdict" || fail "1: fsck -r exited $RC: $(tail -1 <<<"$OUT")"

OUT="$(CETRAFS_TEST_FSCK_PENDING_JOURNAL_OK=1 "$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1)" && RC=0 || RC=$?
[ "$RC" = 0 ] && grep -q "cetrafs fsck: OK" <<<"$OUT" &&
    pass "control: with the old verdict, fsck -r said OK and exited 0 with repair disabled" ||
    fail "control: fsck -r exited $RC -- the suite does not reach the verdict ($(tail -1 <<<"$OUT"))"
ct_exit
