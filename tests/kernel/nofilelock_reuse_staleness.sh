#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# nofilelock must not trust a cached inode for a file nobody has open
#
# Under nofilelock, cetrafs_lock_held_for_write_locally() decided the
# cache was authoritative whenever no FOREIGN node had the file open.
# A file open on NO node satisfies that trivially -- so a closed file's
# in-core inode was trusted indefinitely, and the caller that skips its
# refresh on that basis also skips the GENERATION check that detects
# inode-number reuse. The object then keeps the dead file's type and ops.
#
# Seen in production on a three-node cluster: inode 3 was a 3 GiB regular
# file; a peer deleted it and reallocated the number as a VM directory;
# two nodes went on reporting a 3 GiB regular file -- each with its own
# stale mtime, nothing in dmesg -- until their caches were dropped. The
# on-disk state was correct throughout, so this is a staleness bug, not
# data loss, but a node serving the wrong TYPE for a live inode is the
# corruption CLAUDE.md's generation rule exists to prevent.
#
# Here one kernel plays both parts: cache the inode, then rewrite its
# on-disk record with a new generation and a different type (what a peer
# reusing the number leaves behind), then look it up again.
#
# Discrimination: restore the predicate to
# `return !cetrafs_inode_foreign_opener_cached(inode);` and the lookup
# keeps returning the stale identity, failing the assertion below.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 nflreuse)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nflreuse)"
POKE="$(ct_helper inode_block_poke)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
# The bug is specific to nofilelock: with the lock ON the predicate asks
# lock_writer_count, which already requires a local writer.
mount -t cetrafs -o nofilelock "$DEV" "$MNT" || fail "nofilelock mount failed"
require_cetrafs_mount "$MNT"
grep -q "file_lock: off" "$(ct_procdir "$DEV")/info" || fail "not mounted nofilelock -- this suite tests the wrong mode"

# A directory, so the reuse flips type in the direction production saw
# (regular file -> something else) when we retype it below.
mkdir "$MNT/victim"
echo hello > "$MNT/victim/f"
sync
INO="$(stat -c %i "$MNT/victim")"
[ -n "$INO" ] && [ "$INO" -gt 0 ] || fail "could not read the victim inode number"
log "victim is ino=$INO, type=$(stat -c %F "$MNT/victim")"

# Cache it, then make sure nothing holds it open: that is the exact
# state the predicate got wrong.
stat "$MNT/victim" >/dev/null
TYPE_BEFORE="$(stat -c %F "$MNT/victim")"
[ "$TYPE_BEFORE" = "directory" ] || fail "setup wrong: victim is $TYPE_BEFORE"

# A peer deletes it and reuses the number for a REGULAR file: new
# generation, different type. Written straight to the backing file, so
# this kernel's caches are untouched -- exactly a peer's view.
"$POKE" "$IMG" retype "$INO" 999 >/dev/null 2>&1 || fail "could not retype ino $INO"

# THE assertion: the next lookup must not serve the dead identity.
TYPE_AFTER="$(stat -c %F "$MNT/victim" 2>/dev/null || echo "gone")"
log "after a peer reused ino $INO: lookup reports '$TYPE_AFTER'"

[ "$TYPE_AFTER" != "directory" ] ||
    fail "lookup still reports a directory -- the reused inode's generation was never checked"

# It must not Oops or hang either: the point of unhashing is that the
# next iget builds a correct object rather than refreshing fields onto
# one with the wrong ops.
ls "$MNT" >/dev/null 2>&1 || true
stat "$MNT/victim" >/dev/null 2>&1 || true

ct_umount "$MNT"
pass "a closed file's cached inode is revalidated, so inode-number reuse is caught"

ct_exit
