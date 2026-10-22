#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# unlink must not decide "is anybody using this?" about the wrong inode
#
# Enumerated after ctest found rename's version of this. Every namespace
# operation identifies its victim from the VFS's own earlier lookup
# (d_inode(dentry)), which on a shared LUN a peer can invalidate at any
# moment by renaming something else onto that name. rename re-verifies
# the destination under the lock; unlink did not.
#
# cetrafs_dir_remove_entry() reports the inode the NAME actually
# resolved to, and the record decrement correctly follows that. But
# everything DECIDED before it ran used the stale d_inode:
#
#   - cetrafs_lock_foreign_claim_exists() and _reader_exists() -- the
#     two checks that stop this node destroying a file a live peer is
#     writing or reading -- were asked about the inode
#     the dentry remembered, not the one about to lose its last name.
#   - the inode is what the namespace lock set was built from, so the
#     record that really gets mutated is mutated holding no lock on it.
#
# Two hypotheses that testing REFUTED, recorded so they are not
# re-litigated:
#
#   - rmdir looks like it has the same hole (its emptiness check runs on
#     the stale d_inode while nlink=0 is written to whatever the name
#     names). It is not reachable: a rename that replaces a DIRECTORY
#     always leaves the old one at nlink=0, and N2's refusal to refresh
#     an nlink==0 record makes d_revalidate invalidate that dentry, so
#     the lookup is redone and resolves correctly. Asserted below so it
#     stays that way.
#   - unlink's drop_nlink() on the stale in-core inode looked like
#     durable link-count corruption. It is masked: the peer's rename
#     costs that inode exactly one link too, so the stale in-core count
#     minus one equals the correct answer. A test built on it would be
#     the "right and wrong agree" control this project has already been
#     bitten by.
#
# A peer is simulated the way every cross-node test here does it: poke
# the backing file behind the live mount, after a sync so no dirty
# buffer masks it, bumping the directory's dirent_seq as a real peer's
# mutation would.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
CPOKE="$(ct_helper corrupt_poke)"
IPOKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
NPOKE="$(ct_helper node_poke)"

# A peer that is registered and beating, so cetrafs_node_is_stale() says
# it is alive -- an unregistered row reads as stale and correctly blocks
# nothing, which is how this suite's first draft failed its own control.
peer_alive() { "$NPOKE" "$1" 1 1 ee "$(date +%s)" >/dev/null 2>&1; }
ROOT_INO=1

IMG="$(ct_image 560 staleden)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt staleden)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "control: the peer-open check works when the dentry is NOT stale"
# Exactly the N6 assertion, restated here so the real case below is
# known to be testing the repointing and not the check itself.
printf 'zzz' >"$MNT/direct"
DIRECT="$(stat -c '%i' "$MNT/direct")"
sync
peer_alive "$IMG"
"$LPOKE" "$IMG" "$DIRECT" 1 1 >/dev/null        # node 1 holds it exclusively
"$IPOKE" "$IMG" bumpseq "$ROOT_INO" >/dev/null
if rm -f "$MNT/direct" 2>/dev/null; then
    fail "unlink removed a file a live peer holds open -- the check itself is broken"
else
    pass "unlink refuses a file a live peer holds open (ETXTBSY)"
fi

log "the real case: the name was repointed at a file a live peer holds open"
# Start: A and A2 name X; B names Y. A peer then renames B onto A, so
# the name A resolves to Y and X keeps its one other name A2.
printf 'xxx' >"$MNT/A"; ln "$MNT/A" "$MNT/A2"; printf 'yyy' >"$MNT/B"
X="$(stat -c '%i' "$MNT/A")"; Y="$(stat -c '%i' "$MNT/B")"
stat "$MNT/A" >/dev/null          # cache the dentry: d_inode(A) == X
sync
"$CPOKE" "$IMG" repoint "$ROOT_INO" A "$Y" >/dev/null
"$CPOKE" "$IMG" dirent "$ROOT_INO" B >/dev/null
"$IPOKE" "$IMG" nlink "$X" 1 >/dev/null
# ...and that peer still holds Y open for write. X is NOT locked, so a
# check asked about X sees nothing and lets the unlink through.
peer_alive "$IMG"
"$LPOKE" "$IMG" "$Y" 1 1 >/dev/null
"$IPOKE" "$IMG" bumpseq "$ROOT_INO" >/dev/null

if rm -f "$MNT/A" 2>/dev/null; then
    fail "unlink destroyed the last name of a file a live peer holds open, because it asked about the inode the dentry remembered"
else
    pass "unlink refuses: the question is asked about the inode the NAME resolves to"
fi

log "...and the entry is still there, so nothing was half-done"
ls "$MNT" | grep -qx A && pass "the name A survives the refusal" || fail "the name A was removed anyway"
[ "$(stat -c '%h' "$MNT/A2")" = "1" ] && pass "X's surviving name still reports one link" ||
    fail "A2 reports nlink=$(stat -c '%h' "$MNT/A2")"

log "the window d_revalidate cannot cover: repointed while the unlink waits for the lock"
# revalidate asks "does this name still resolve to this inode?" on every
# path lookup -- but it asks BEFORE the namespace lock, and
# cetrafs_nslock_acquire() sleeps while a live peer holds that lock. So
# the name can be repointed during the wait, after the only check that
# would have caught it.
#
# Reproduced for real rather than simulated with a module knob: the
# parent's ns_lock_owner is poked to a live peer, which parks the unlink
# inside the acquire retry loop; the name is repointed while it is
# parked; then the lock is released and the unlink proceeds with a
# dentry that went stale after revalidate.
printf 'ppp' >"$MNT/W"; ln "$MNT/W" "$MNT/W2"; printf 'qqq' >"$MNT/V"
WX="$(stat -c '%i' "$MNT/W")"; WY="$(stat -c '%i' "$MNT/V")"
stat "$MNT/W" >/dev/null          # revalidate will see W -> WX and pass
sync
peer_alive "$IMG"
"$LPOKE" "$IMG" "$ROOT_INO" --ns 1 >/dev/null     # a live peer holds the parent's ns lock
sync

rm -f "$MNT/W" >/tmp/ct_w.out 2>&1 &
RMPID=$!
sleep 1                                            # parked in nslock_acquire

# The peer finishes its rename(V -> W) while we wait: the name W now
# resolves to WY, and that peer holds WY open for write.
"$CPOKE" "$IMG" repoint "$ROOT_INO" W "$WY" >/dev/null
"$CPOKE" "$IMG" dirent "$ROOT_INO" V >/dev/null
"$IPOKE" "$IMG" nlink "$WX" 1 >/dev/null
"$LPOKE" "$IMG" "$WY" 1 1 >/dev/null
"$IPOKE" "$IMG" bumpseq "$ROOT_INO" >/dev/null
"$LPOKE" "$IMG" "$ROOT_INO" --ns 65535 >/dev/null  # ...and releases the lock

wait "$RMPID" && RMRC=0 || RMRC=$?
if [ "$RMRC" -eq 0 ]; then
    fail "unlink proceeded on a dentry that went stale after revalidate: it destroyed the last name of a file a live peer holds open"
else
    pass "unlink refuses a dentry that went stale while it waited for the namespace lock ($(cat /tmp/ct_w.out | sed 's/.*: //'))"
fi
ls "$MNT" | grep -qx W && pass "the repointed name still exists" || fail "the name W was removed"
rm -f /tmp/ct_w.out

log "rmdir's version stays unreachable (the nlink==0 refresh guard covers it)"
mkdir "$MNT/dempty" "$MNT/dfull"; : >"$MNT/dfull/child"
DE="$(stat -c '%i' "$MNT/dempty")"; DF="$(stat -c '%i' "$MNT/dfull")"
stat "$MNT/dempty" >/dev/null
sync
# A peer's rename(dfull -> dempty): the name now resolves to the
# POPULATED directory, and the replaced one is left at nlink=0 -- which
# is precisely what makes the stale dentry self-invalidating.
"$CPOKE" "$IMG" repoint "$ROOT_INO" dempty "$DF" >/dev/null
"$IPOKE" "$IMG" nlink "$DE" 0 >/dev/null
"$IPOKE" "$IMG" bumpseq "$ROOT_INO" >/dev/null
if rmdir "$MNT/dempty" 2>/dev/null; then
    fail "rmdir of an empty dentry destroyed the populated directory the name now names"
else
    pass "rmdir refuses: the stale dentry is re-resolved and the directory is not empty"
fi
[ -e "$MNT/dempty/child" ] && pass "the populated directory and its child are intact" ||
    fail "the child is gone -- the directory was destroyed"

ct_umount "$MNT"
ct_exit
