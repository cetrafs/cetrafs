#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a peer's security.* change drops this node's cached LSM label
#
# A labelling LSM (SELinux, Smack) caches an inode's label from
# security.* and enforces that copy. A peer's setxattr reaches this node
# as a record refresh, which goes through none of the VFS paths that tell
# the LSM, so the old label stayed in force (class 42's sibling of
# S_NOSEC). The refresh now calls security_inode_invalidate_secctx() when
# the record's ctime moved -- a setxattr moves it, in seconds -- and once
# more after a refresh made while ctime's second could still change
# again unseen (kmod/inode.c, cetrafs_inode_label_may_be_stale()).
#
# What this suite can see: the trigger, through label_invalidations.
# What it cannot: an LSM acting on it -- no labelling LSM runs on the
# test machines, where the hook does nothing. That half is a gap.
#
#   setup: a file whose ctime is seconds old; one refresh settles it, a
#     second invalidates nothing (it does not fire on every lookup).
#   a peer's change: the record's ctime moved on the device -> the next
#     refresh invalidates.
#   the same second: a refresh right after, ctime unchanged, invalidates
#     once more -- a second change in that second would look identical.
#   settled: seconds later, at most one more, then none.
#
# DISCRIMINATION: without the call the counter never moves; without the
# same-second rule the immediate re-refresh invalidates nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 lsm)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt lsm)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="$(ct_procdir "$DEV")/info"
grep -q '^label_invalidations: ' "$PROC" || { skip "label_invalidations is missing"; ct_exit; }
c() { sed -n 's/^label_invalidations: //p' "$PROC"; }
refresh() { stat "$MNT/f" >/dev/null; }

: >"$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
sleep 3
refresh
A="$(c)"
refresh
B="$(c)"
[ "$B" = "$A" ] && pass "setup: a settled file's refresh invalidates nothing ($A)" ||
    { fail "setup: every refresh invalidates ($A -> $B) -- the trigger cannot be told apart"; ct_exit; }

NOW="$(date +%s)"
"$IPOKE" "$IMG" setctime "$INO" "$NOW" 2>/dev/null
refresh
C="$(c)"
[ "$C" -gt "$B" ] && pass "a peer's change (ctime moved) invalidates the label ($B -> $C)" ||
    fail "the refresh adopted a peer's changed record and kept the cached label ($B -> $C)"
refresh
D="$(c)"
[ "$D" -gt "$C" ] && pass "a refresh in the same second invalidates again: a second change would look identical ($C -> $D)" ||
    fail "a refresh within ctime's second kept the label: a second same-second change is missed ($C -> $D)"
sleep 3
refresh
refresh
E="$(c)"
refresh
F="$(c)"
[ "$F" = "$E" ] && [ $((E - D)) -le 1 ] && pass "settled again: at most one more, then none ($D -> $E -> $F)" ||
    fail "the label keeps being invalidated after the change settled ($D -> $E -> $F)"
ct_umount "$MNT"
ct_exit
