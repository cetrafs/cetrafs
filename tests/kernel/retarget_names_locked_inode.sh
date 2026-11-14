#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a rename-over refuses a destination slot that no longer names the locked inode
#
# A name of X is changed only under X's namespace lock. Rename-over
# re-verifies its destination under the locks, then rewrites the slot
# and decrements the count of whatever that slot named -- with no check
# that it is still the inode it locked, the check cetrafs_dir_remove_
# entry() got for unlink (audit 2026-11-14 N1). A slot naming another
# inode had the rename mutate a record it held no lock on. The retarget
# now refuses (-ESTALE, nothing written) and the VFS retries.
#
# Staged like remove_names_locked_inode.sh: rename_verify_stall_ms holds
# `mv x a` after its target check; in the gap the device is rewritten as
# a writer ignoring the lock would: a -> B and c -> A (A one name, B
# two, still consistent).
#   1. the retarget naming another inode is refused;
#   2. the retry renames over what a names now: fsck clean, x's data at
#      a, A through c, B through b.
#
# DISCRIMINATION: retarget_expect_off lets the first retarget through
# (no refusal). Its damage is to the lock rule, a mutation of B under no
# lock, which one node cannot turn into a wrong count; the control can
# only show the check is what refused.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in rename_verify_stall_ms retarget_expect_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
POKE="$(ct_helper corrupt_poke)"
IMG="$(ct_image 560 rtlocked)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rtlocked)"
ct_track mnt "$MNT"

# <tag> <control 0|1>
round() {
    local tag="$1" rc=0 root A B frc=0 fout
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    echo apple >"$MNT/a"
    echo banana >"$MNT/b"
    echo xylophone >"$MNT/x"
    ln "$MNT/b" "$MNT/c"
    sync
    root="$(stat -c %i "$MNT")"; A="$(stat -c %i "$MNT/a")"; B="$(stat -c %i "$MNT/b")"
    ct_param_set retarget_expect_off "$2"
    ct_param_set rename_verify_stall_ms 3000
    MARK="$(dmesg_mark)"
    mv "$MNT/x" "$MNT/a" 2>/dev/null &
    local pid=$!
    for _ in $(seq 1 50); do dmesg_since "$MARK" | grep -q "target verified, pausing" && break; sleep 0.1; done
    dmesg_since "$MARK" | grep -q "target verified, pausing" ||
        { fail "$tag: setup: the rename never reached the pause"; wait "$pid" || true; ct_param_set retarget_expect_off 0; ct_umount "$MNT"; return 0; }
    "$POKE" "$DEV" repoint "$root" a "$B" >/dev/null
    "$POKE" "$DEV" repoint "$root" c "$A" >/dev/null
    wait "$pid" || rc=$?
    ct_param_set rename_verify_stall_ms 0
    ct_param_set retarget_expect_off 0
    if [ "$2" = 1 ]; then
        dmesg_since "$MARK" | grep -q "refusing the rename" &&
            fail "$tag: the retarget was refused with the check off -- the control proves nothing" ||
            pass "$tag: without the check the retarget rewrote a slot naming ino $B, not the locked $A (mv rc=$rc)"
        ct_umount "$MNT"
        return 0
    fi
    dmesg_since "$MARK" | grep -q "refusing the rename" &&
        pass "$tag: 1: the retarget of a slot naming another inode was refused (mv rc=$rc)" ||
        fail "$tag: 1: no refusal in the kernel log (mv rc=$rc)"
    ct_umount "$MNT"
    fout="$(ct_fsck "$DEV" 2>&1)" || frc=$?
    ct_mount "$DEV" "$MNT"
    if [ "$frc" = 0 ] && [ "$(cat "$MNT/a" 2>/dev/null)" = xylophone ] && [ "$(cat "$MNT/c" 2>/dev/null)" = apple ] &&
        [ "$(cat "$MNT/b" 2>/dev/null)" = banana ] && [ ! -e "$MNT/x" ]; then
        pass "$tag: 2: fsck clean; a is x's file, c is A, b is B"
    else
        fail "$tag: 2: fsck rc=$frc $(grep -m2 ERR <<<"$fout" | tr '\n' ' '); a='$(cat "$MNT/a" 2>&1)' c='$(cat "$MNT/c" 2>&1)' b='$(cat "$MNT/b" 2>&1)'"
    fi
    ct_umount "$MNT"
}

round control 1
round main 0
ct_exit
