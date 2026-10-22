#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a peer's truncate invalidates our cached external extent leaf
#
# A reader node used to keep mapping through its stale cached leaf after
# a peer's truncate or rewrite, returning freed-and-reallocated blocks --
# another file's content -- as this file's data.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

log "checking cross-node extent-leaf staleness on refresh"

# A depth-1 (spilled) file's extent map lives in an external leaf block,
# which readers walk through the ordinary cached path. The refresh that
# fires on every path lookup (d_revalidate -> cetrafs_refresh_vfs_inode_
# if_newer) drops the page cache and the raw inode's cache -- and, since
# this fix, the leaf block's too. Simulate a peer's extent-map rewrite by
# poking the leaf's entry 0 on the loop device's BACKING FILE (invisible
# to the live mount's cache, same trick as inode_block_poke.c) to point
# at a donor file's block, then confirm a fresh path lookup + read
# returns the donor's content (fresh leaf) instead of the original
# (stale cached leaf -- the pre-fix corruption).
G6_POKE="$(ct_helper leaf_poke)"
G6_EXTENT_POKE="$(ct_helper pending_poke)"

G6_IMG="$(mktemp /tmp/cetrafs-g6-XXXXXX.img)"
truncate -s 560M "$G6_IMG"
G6_LOOPDEV="$(losetup --find --show "$G6_IMG")"
G6_MNT="$(mktemp -d /tmp/cetrafs-g6-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$G6_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
mount -t cetrafs "$G6_LOOPDEV" "$G6_MNT"

# Donor: a 1-block file with known content, synced so its block is real.
printf 'DONORDONOR' >"$G6_MNT/donor"
# Victim: force 5 fragmented blocks -> external leaf (same interleaving
# technique the defrag suites use).
for i in 0 1 2 3 4; do
    printf 'VICTIM%04d' "$i" | dd of="$G6_MNT/victimleaf" bs=4096 seek="$i" count=1 conv=notrunc 2>/dev/null
    [ "$i" -lt 4 ] && printf x >"$G6_MNT/g6filler$i"
done
sync "$G6_MNT/victimleaf" "$G6_MNT/donor"
G6_VICTIM_INO="$(stat -c '%i' "$G6_MNT/victimleaf")"
G6_DONOR_INO="$(stat -c '%i' "$G6_MNT/donor")"

# Warm this node's cache of the victim's leaf + content.
head -c 10 "$G6_MNT/victimleaf" >/dev/null

G6_DONOR_PHYS="$("$G6_EXTENT_POKE" "$G6_IMG" extent "$G6_DONOR_INO" | cut -d' ' -f1)"
"$G6_POKE" "$G6_IMG" setphys "$G6_VICTIM_INO" 0 "$G6_DONOR_PHYS" >/dev/null

# Fresh path lookup fires the refresh; the read must now go through the
# POKED leaf (block 0 -> donor's block), not the stale cached one.
G6_READ="$(head -c 10 "$G6_MNT/victimleaf")"
if [ "$G6_READ" = "DONORDONOR" ]; then
    pass "leaf refresh: a peer's extent-map rewrite is visible on the next lookup (leaf cache invalidated)"
else
    fail "leaf refresh: read '$G6_READ' through a stale cached extent leaf, expected 'DONORDONOR'"
fi

umount "$G6_MNT"
rmdir "$G6_MNT"
losetup -d "$G6_LOOPDEV"
rm -f "$G6_IMG" "$G6_POKE" "$G6_EXTENT_POKE"


ct_exit
