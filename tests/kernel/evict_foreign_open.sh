#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a file must not be destroyed while another node still has it open
#
# Eviction is where a file is actually destroyed: its blocks go back to
# the allocator and can be handed to a different file. The "is anybody
# else still using it?" question was asked only in unlink and in
# rename's replace path -- both earlier than the destruction, and
# neither atomic with it. A peer's open takes the FILE lock and takes no
# namespace lock at all, so it can land between that check and this
# destruction. That is P7's lesson in a new place: two locks over one
# record exclude nothing from each other, so the bridge has to be at the
# moment that matters.
#
# Reproduced here by holding the file open locally across the unlink --
# which defers eviction to the close -- and poking a live peer's claim
# into the record in between.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

run_case() { # <poke-a-peer: yes|no> <description>
    local peer="$1" desc="$2"
    local img dev mnt ino mark
    img="$(ct_image 560 evict)"
    dev="$(ct_loop "$img")"
    mnt="$(ct_mnt evict)"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$mnt"
    require_cetrafs_mount "$mnt"

    dd if=/dev/zero of="$mnt/victim" bs=4096 count=16 status=none
    ino="$(stat -c '%i' "$mnt/victim")"
    sync

    # Held open, so the unlink below only removes the NAME -- the inode
    # is destroyed later, at the close.
    exec 9<"$mnt/victim"
    rm "$mnt/victim"

    if [ "$peer" = "yes" ]; then
        # A peer that registered, is beating, and holds the file open
        # for write. Poked after the mount, per the no-CAW gate's
        # watch window.
        "$NODE_POKE" "$img" 1 1 ee "$(date +%s)" >/dev/null 2>&1
        "$LOCK_POKE" "$img" "$ino" 1 1 >/dev/null 2>&1
    fi

    mark="$(dmesg_mark)"
    exec 9<&-          # last reference drops: evict_inode runs here
    sync
    ct_umount "$mnt"

    if [ "$peer" = "yes" ]; then
        if dmesg_since "$mark" | grep -q "ino=$ino is still open on another node"; then
            pass "$desc: eviction declined to free a file a live peer holds open"
        else
            fail "$desc: eviction freed the blocks of a file a live peer had open"
        fi
        # The refusal is supposed to LEAVE the inode allocated: a
        # bounded leak fsck can name, which is the same trade the
        # read-failure path has always made.
        # Retire the simulated peer first, or fsck spends its own
        # liveness window watching a row that will never beat again.
        "$NODE_POKE" "$img" 1 0 ee 0 >/dev/null 2>&1
        # Captured, not piped: fsck exits nonzero when it finds the
        # problem this is looking FOR, and `set -o pipefail` would turn
        # that into a failed test regardless of what grep matched.
        FSCK_OUT="$(ct_fsck "$dev" 2>&1 || true)"
        # The retained inode has nlink=0, which fsck now classifies as the
        # designed cross-node-delete residue: a WARN ("with no directory
        # entry -- deleted but not yet reclaimed"), reclaimed online by the
        # scrub, not a corruption ERR. Both phrasings share "no directory
        # entry".
        if echo "$FSCK_OUT" | grep -qi "no directory entry"; then
            pass "$desc: fsck names the bounded leak the refusal leaves"
        else
            fail "$desc: fsck does not report the retained inode: $(echo "$FSCK_OUT" | tail -2)"
        fi
    else
        if dmesg_since "$mark" | grep -q "is still open on another node"; then
            fail "$desc: eviction refused with no peer anywhere"
        else
            pass "$desc: with no peer, eviction frees normally"
        fi
        ct_fsck "$dev" >/dev/null 2>&1 &&
            pass "$desc: fsck is clean -- everything was returned" ||
            fail "$desc: fsck after an ordinary eviction: $(ct_fsck "$dev" 2>&1 | tail -2)"
    fi
    losetup -d "$dev" 2>/dev/null || true
}

log "a live peer's claim must stop the destruction"
run_case yes "foreign claim"
log "control: the same sequence with nobody else there"
run_case no "no peer"

ct_exit
