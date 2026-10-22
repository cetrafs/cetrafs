#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the namespace lock covers every record its operation mutates, and
# defers to a live peer's file lock
#
# Two separate properties, both easy to get subtly wrong:
#
#  * SCOPE. The lock is taken on the set of inodes whose records the
#    operation writes, not just the parent directory. Parent-only would
#    let two nodes unlinking two hardlinks of one file, through two
#    different directories, both read-modify-write that file's nlink.
#    The set is acquired in ascending inode order so two nodes taking
#    overlapping sets cannot deadlock.
#
#  * THE OTHER LOCK. The namespace lock and the cross-node file lock are
#    different locks over the same record -- holding one excludes nothing
#    holding the other. A peer that owns the file lock rewrites the
#    record through ordinary writeback, so a namespace operation that
#    mutates it anyway loses whatever it wrote. unlink, rename-replace,
#    setattr and setxattr all refuse with -ETXTBSY while a live peer
#    holds it; link did not, and an nlink increment lost that way leaves
#    a hardlink whose target believes nlink=1 -- unlinking either name
#    then frees the blocks while the other still points at them.
#
# Measured discrimination: removing the foreign-lock check from link
# fails 3 of these 7 assertions (the link succeeds, it leaves a dirent,
# and the later "works again" case then fails because the name is
# already taken). The lock-release sweep and the nlink check pass either
# way and are statements of the invariant.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 nss)"
MNT="$(ct_mnt nss)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "checking the lock is released by every namespace operation it brackets"
mkdir "$MNT/d"
: >"$MNT/d/a"
ln "$MNT/d/a" "$MNT/d/b"
mv "$MNT/d/b" "$MNT/d/c"
chmod 0640 "$MNT/d/a"
rm "$MNT/d/c"
rmdir_target="$MNT/d2"; mkdir "$rmdir_target"; rmdir "$rmdir_target"
sync
# Collect the inodes that actually EXIST before unmounting. Scanning a
# fixed range would sweep up never-allocated records too, and those are
# zero-filled -- which reads as ns_owner=0, i.e. "locked by node 0",
# because the unlocked sentinel is 0xFFFF and not 0. Only an allocated
# record has had that field set explicitly.
INOS="$(find "$MNT" -printf '%i\n' | sort -un | tr '\n' ' ')"
ct_umount "$MNT"
# ns_lock_owner must be back at the unlocked sentinel on every one.
LEAKED=""
for ino in $INOS; do
    DUMP="$("$LOCK_POKE" "$DEV" "$ino" 2>/dev/null || true)"
    case "$DUMP" in
        *ns_owner=65535*|"") ;;
        *) LEAKED="$LEAKED ino=$ino($DUMP)" ;;
    esac
done
[ -z "$LEAKED" ] && pass "nslock scope: every inode's lock was released" ||
    fail "nslock scope: lock left held on:$LEAKED"
ct_mount "$DEV" "$MNT"

log "checking link refuses while a LIVE peer holds the file lock"
: >"$MNT/target"
TINO="$(stat -c '%i' "$MNT/target")"
ct_umount "$MNT"
# A peer that registered and is still heartbeating, holding the file.
"$LOCK_POKE" "$DEV" "$TINO" 1 1 >/dev/null
ct_mount "$DEV" "$MNT"
# Poked AFTER the mount, deliberately. Liveness is observed hb_seq
# PROGRESS, so a row with a fresh timestamp and a frozen counter is only
# "alive" for as long as nothing has been watching it -- and the no-CAW
# mount gate now watches, blocking a full window before it will admit a
# second mounter. Poking before the mount would spend exactly the
# observation budget this section depends on.
"$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
if ln "$MNT/target" "$MNT/target-link" 2>/dev/null; then
    fail "nslock scope: link succeeded while a live peer held the file lock -- its nlink bump can be lost"
else
    pass "nslock scope: link refused while a live peer holds the file lock"
fi
[ -e "$MNT/target-link" ] &&
    fail "nslock scope: the refused link left a dirent behind" ||
    pass "nslock scope: the refused link left no dirent"

log "checking it proceeds once that peer is gone"
ct_umount "$MNT"
# The simulated peer departs too -- otherwise every later mount in this
# suite spends a full watch window on the gate deciding whether a row
# that will never beat again is alive.
"$NODE_POKE" "$DEV" 1 0 aa 0 >/dev/null
"$LOCK_POKE" "$DEV" "$TINO" 65535 0 >/dev/null   # clear the foreign claim
ct_mount "$DEV" "$MNT"
ln "$MNT/target" "$MNT/target-link" &&
    pass "nslock scope: link works again once the claim clears" ||
    fail "nslock scope: link still refused after the claim cleared"
NL="$(stat -c '%h' "$MNT/target")"
[ "$NL" = "2" ] && pass "nslock scope: the target's nlink is 2" ||
    fail "nslock scope: nlink is $NL, expected 2"
ct_umount "$MNT"

ct_exit
