#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory grows past the 4 inline extents into an external leaf
#
# Previously dir.c appended one extent per dirent block and stopped
# at the 4 inline ones, so EVERY directory hit ENOSPC at exactly 58
# usable names on a completely empty volume. Directories now grow through
# the same extent machinery regular files use.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

# A volume with one file, 'victim', whose inode number the pokes below
# address. Every suite that touches the on-disk lock fields starts from
# exactly this state, freshly built -- nothing here inherits anything
# from another suite.
LOCK_IMG="$(ct_image 560 lock)"
LOCK_LOOPDEV="$(ct_loop "$LOCK_IMG")"
LOCK_MNT="$(ct_mnt lock-mnt)"
ct_mkfs_small "$LOCK_LOOPDEV" >/dev/null
ct_track mnt "$LOCK_MNT"
ct_mount "$LOCK_LOOPDEV" "$LOCK_MNT"
require_cetrafs_mount "$LOCK_MNT"
echo "victim content" >"$LOCK_MNT/victim"
VICTIM_INO="$(stat -c '%i' "$LOCK_MNT/victim")"

log "checking a directory can grow past 4 blocks"
# Previously dir.c appended one new extent per new dirent block and
# stopped at the 4 inline ones, so ANY directory hit ENOSPC at exactly
# 60 dirents -- 58 usable once '.' and '..' are counted -- on a
# completely empty volume. Directories now grow through the same extent
# machinery files use (contiguity merge + depth-1 external leaf spill),
# so the only real limit is free inodes/blocks.
NSDIRGROW="$LOCK_MNT/growdir"
mkdir -p "$NSDIRGROW"
GROW_MADE=0
for i in $(seq 1 200); do
    touch "$NSDIRGROW/g$i" 2>/dev/null || break
    GROW_MADE=$i
done
[ "$GROW_MADE" -eq 200 ] &&
    pass "dirgrow: created 200 entries in one directory (old cap was 58)" ||
    fail "dirgrow: only created $GROW_MADE of 200 entries before failing"

# Every name must still be findable -- a grown directory is useless if
# lookup or readdir can only see the first few blocks' worth.
GROW_SEEN="$(ls "$NSDIRGROW" | wc -l)"
[ "$GROW_SEEN" -eq "$GROW_MADE" ] &&
    pass "dirgrow: readdir returns all $GROW_SEEN entries" ||
    fail "dirgrow: readdir returned $GROW_SEEN entries, expected $GROW_MADE"
if [ -e "$NSDIRGROW/g1" ] && [ -e "$NSDIRGROW/g137" ] && [ -e "$NSDIRGROW/g200" ]; then
    pass "dirgrow: lookup finds entries in the first, middle and last blocks"
else
    fail "dirgrow: lookup failed for an entry past the first dirent block"
fi

# Removing an entry must free its slot for reuse rather than only ever
# appending -- otherwise a long-lived directory grows without bound.
rm -f "$NSDIRGROW/g137"
[ -e "$NSDIRGROW/g137" ] && fail "dirgrow: removed entry still present" ||
    pass "dirgrow: entry removed from a grown directory"
touch "$NSDIRGROW/g137b"
[ -e "$NSDIRGROW/g137b" ] && pass "dirgrow: a freed slot in a grown directory is reusable" ||
    fail "dirgrow: could not create into a grown directory after a removal"

# And the whole thing must come back cleanly -- including the external
# leaf block the extent list spilled into, if it did.
GROWFREE_BEFORE="$(stat -f -c '%f' "$LOCK_MNT")"
rm -rf "$NSDIRGROW"
sync
GROWFREE_AFTER="$(stat -f -c '%f' "$LOCK_MNT")"
[ "$GROWFREE_AFTER" -ge "$GROWFREE_BEFORE" ] &&
    pass "dirgrow: removing the grown directory returned its blocks" ||
    fail "dirgrow: free blocks went backwards after rm -rf ($GROWFREE_BEFORE -> $GROWFREE_AFTER)"


ct_exit
