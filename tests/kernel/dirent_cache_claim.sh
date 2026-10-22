#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# only a walk that read every block may claim the dirent cache
#
# Reading a directory means reading every one of its dirent blocks
# forced-fresh, because any node may mutate any directory at any moment.
# dirent_seq makes that affordable: the record carries a counter that
# every mutation bumps, a node remembers the seq at which it last read
# the whole directory fresh, and while the two match its cached blocks
# are known current.
#
# "Read the WHOLE directory fresh" is the entire basis of that claim, and
# two of the three places that claimed it had not. cetrafs_dir_remove_
# entry() stops its scan at the entry it came to remove, and
# cetrafs_dir_update_dotdot() stops at '..' in the first block -- yet both
# then asserted the whole directory was cached and current at the new
# sequence. Every subsequent read-only walk trusts that: entries a peer
# deleted keep being listed, entries it added stay invisible, and nothing
# corrects it until something bumps the sequence again.
#
# cetrafs_dir_add_entry() is the one that may claim, and only because it
# has no choice but to scan everything -- a duplicate name could be in
# any block.
#
# The peer is simulated the usual way: edits to the backing file behind a
# live mount, which is exactly what another node's writes look like to
# this one.
#
# Measured discrimination: restoring remove_entry's claim fails two
# assertions -- f60 stays listed and the count is 60 rather than 59 --
# which is the same symptom a real two-node run produced ("four files
# still listed after unlinks that all reported success"). The '..'
# rewrite assertion passes either way here, because the rename that
# drives it also goes through add_entry/remove_entry on the directories
# involved; it is kept as a statement of the invariant, not as a
# discriminator.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
CPOKE="$(ct_helper corrupt_poke)"
IPOKE="$(ct_helper inode_block_poke)"

DEV="$(ct_dev 560 dcc)"
IMG="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt dcc)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# Enough files to span several dirent blocks (15 per block), so "early"
# and "late" really are different blocks.
mkdir "$MNT/d"
: >"$MNT/d/early"
for i in $(seq 1 60); do : >"$MNT/d/f$(printf '%02d' "$i")"; done
DINO="$(stat -c '%i' "$MNT/d")"
sync

log "priming this node's cache with a full read-only walk"
ls "$MNT/d" >/dev/null
[ "$(ls "$MNT/d" | wc -l)" = "61" ] && pass "dirent cache: all 61 entries visible before the peer acts" ||
    fail "dirent cache: expected 61 entries, got $(ls "$MNT/d" | wc -l)"

log "a peer removes a LATE entry and bumps the sequence"
# f60 lives well past 'early', so a scan that stops at 'early' never
# reaches its block.
"$CPOKE" "$IMG" dirent "$DINO" "f60" >/dev/null
"$IPOKE" "$IMG" bumpseq "$DINO" >/dev/null

log "this node removes an EARLY entry -- a scan that stops before the peer's block"
rm "$MNT/d/early"
sync

# The question: does this node now serve its unrefreshed cached copy of
# the late block, or go back to the device?
if ls "$MNT/d" | grep -qx "f60"; then
    fail "dirent cache: f60 is still listed -- a partial scan claimed the cache and the stale block is trusted"
else
    pass "dirent cache: the peer's removal is visible after a partial-scan mutation"
fi
[ "$(ls "$MNT/d" | wc -l)" = "59" ] &&
    pass "dirent cache: exactly 59 entries (61 less the peer's and ours)" ||
    fail "dirent cache: $(ls "$MNT/d" | wc -l) entries, expected 59"

log "checking the same for the '..' rewrite path"
mkdir "$MNT/d2"
for i in $(seq 1 40); do : >"$MNT/d2/g$(printf '%02d' "$i")"; done
mkdir "$MNT/d2/sub"
D2INO="$(stat -c '%i' "$MNT/d2")"
sync
ls "$MNT/d2" >/dev/null                       # prime
"$CPOKE" "$IMG" dirent "$D2INO" "g40" >/dev/null
"$IPOKE" "$IMG" bumpseq "$D2INO" >/dev/null
mv "$MNT/d2/sub" "$MNT/d/sub"                 # rewrites sub's '..', touching d2's first block
sync
if ls "$MNT/d2" | grep -qx "g40"; then
    fail "dirent cache: g40 still listed after a '..' rewrite claimed the cache"
else
    pass "dirent cache: the peer's removal is visible after a '..' rewrite too"
fi

ct_umount "$MNT"
ct_exit
