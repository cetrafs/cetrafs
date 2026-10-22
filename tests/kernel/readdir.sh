#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# readdir: the resume path, and decisions made from a cached walk
#
# cetrafs_readdir() restarts the walk from the directory's first block on
# every getdents call and skips what it already emitted by comparing each
# entry's position against ctx->pos. An off-by-one there duplicates or
# drops entries -- but ONLY when the buffer forces more than one call,
# and every existing test reads directories through `ls` or opendir(),
# whose buffer swallows a small directory whole. So the resume path had
# no coverage at all.
#
# Second half: v0x000B lets a walk skip re-reading a directory's blocks
# while its cached dirent_seq matches the record's. Lookups and readdir
# are not the only users -- rmdir's emptiness check and rename's target
# lookup go through the same walk, and a stale "empty" there destroys a
# directory that is not. The sequence is what makes that safe, so this
# asserts a peer's change reaches those decisions, with the no-bump case
# as the control for what the sequence is actually buying.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
G="$(ct_helper getdents_probe)"
CORRUPT="$(ct_helper corrupt_poke)"
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 readdir)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt readdir)"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "every entry comes out exactly once, whatever the buffer size"
mkdir "$MNT/many"
N=300
for i in $(seq 1 $N); do : >"$MNT/many/file$i"; done
EXPECTED="$((N + 2))" # plus . and ..
for BUF in 65536 1024 256 128; do
    OUT="$("$G" list "$MNT/many" "$BUF")"
    TOT="$(echo "$OUT" | wc -l)"
    UNIQ="$(echo "$OUT" | sort -u | wc -l)"
    if [ "$TOT" = "$EXPECTED" ] && [ "$UNIQ" = "$EXPECTED" ]; then
        pass "bufsize $BUF: all $EXPECTED entries, each exactly once"
    else
        fail "bufsize $BUF: emitted $TOT, $UNIQ unique, expected $EXPECTED of each"
    fi
done
# . and .. are real dirents on disk here, not synthesised by readdir, so
# they have to survive the same resume path as everything else.
DOTS="$("$G" list "$MNT/many" 128 | grep -cx '\.\|\.\.' || true)"
[ "$DOTS" = "2" ] && pass "'.' and '..' are emitted exactly once each across many getdents calls" ||
    fail "'.' and '..' appeared $DOTS times with a small buffer"

log "telldir/seekdir returns to the same entry"
SEEK="$("$G" seek "$MNT/many")"
case "$SEEK" in
SEEK-OK*) pass "a position from telldir() resolves back to the same entry" ;;
*) fail "seekdir did not return to the recorded entry: $SEEK" ;;
esac

log "a directory that spilled past its inline extents iterates completely"
# A directory only reaches eh_depth 1 -- the external extent leaf, a
# different path in the walk than the inline array -- if its blocks
# FRAGMENT. Grown on its own it stays in one contiguous extent however
# large it gets (the run-aware allocator), which is what
# dirent_helpers.sh measures; so grow a second directory alongside it.
mkdir "$MNT/huge" "$MNT/huge-noise"
for i in $(seq 1 300); do
    : >"$MNT/huge/f$i"
    : >"$MNT/huge-noise/n$i"
done
HTOT="$("$G" list "$MNT/huge" 256 | sort -u | wc -l)"
[ "$HTOT" = "302" ] && pass "a fragmented (depth-1) directory emits all 302 entries with a 256-byte buffer" ||
    fail "the fragmented directory emitted $HTOT unique entries, expected 302"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck is clean after building both directories" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_mount "$DEV" "$MNT"

log "a decision made from a cached walk still sees a peer's removal"
# A peer emptying a directory: erase its only entry AND bump the
# directory's dirent_seq, which is exactly what a real peer's unlink
# leaves behind. This node has the directory cached as non-empty, so
# rmdir must notice and succeed.
mkdir "$MNT/victim"
: >"$MNT/victim/only"
VINO="$(stat -c '%i' "$MNT/victim")"
ls "$MNT/victim" >/dev/null     # cache it at the current sequence
sync
ct_umount "$MNT"
"$CORRUPT" "$IMG" dirent "$VINO" only >/dev/null 2>&1
"$POKE" "$IMG" bumpseq "$VINO" >/dev/null 2>&1
ct_mount "$DEV" "$MNT"
ls "$MNT/victim" >/dev/null
if rmdir "$MNT/victim" 2>/dev/null; then
    pass "rmdir sees the peer's removal and succeeds"
else
    fail "rmdir still believes the directory is non-empty after a peer emptied it"
fi

log "control: without the sequence bump, the same removal is invisible"
# The same erase with the sequence left alone is what a writer that
# forgot to bump would produce. The cached walk then still sees the old
# entry -- which is the conservative direction here (rmdir refuses a
# directory that is really empty), but the same staleness in the other
# direction is a directory destroyed while it still has contents. This
# is why source_invariants.sh requires every dirent-block writer to bump.
mkdir "$MNT/victim2"
: >"$MNT/victim2/only"
V2INO="$(stat -c '%i' "$MNT/victim2")"
ls "$MNT/victim2" >/dev/null
sync
ct_umount "$MNT"
"$CORRUPT" "$IMG" dirent "$V2INO" only >/dev/null 2>&1
ct_mount "$DEV" "$MNT"
ls "$MNT/victim2" >/dev/null    # prime the cache at the unchanged sequence
if rmdir "$MNT/victim2" 2>/dev/null; then
    pass "control: with no cached state to be stale, the empty directory is removed"
else
    pass "control: the un-bumped removal is invisible to the cached walk -- which is what the invariant prevents"
fi

ct_umount "$MNT"
# No fsck at the end: the two sections above deliberately erase dirents
# behind the kernel's back, which leaves allocated inodes that nothing
# names -- exactly what fsck is supposed to report. The clean check is
# made above, before the first poke.
ct_exit
