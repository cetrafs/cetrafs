#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a dirent remove refuses a name that does not name the inode the operation locked
#
# A name of X is added, removed or moved only under X's own namespace
# lock. The online recount after a crash relies on it: it counts X's
# names across the volume, and a count of 0 frees X
# (cetrafs_ns_count_names()). unlink and rmdir broke it in a "mismatch
# branch": when the entry they removed named some other inode than the
# one they had locked, they went on, decremented that unlocked record,
# and dropped the LOCKED inode's in-core count although it lost no name.
# cetrafs_dir_remove_entry() now takes the locked inode's number and
# refuses (-ESTALE, nothing written) an entry naming any other.
#
# Unreachable in normal use -- the name is verified under the parent's
# lock first -- so it is staged: unlink_verify_stall_ms holds `rm a` between
# that verify and the remove, and the device is rewritten in the gap, as a
# writer ignoring the lock would. Files a (A) and b (B), and c a second
# name of B. On the device, a -> B and c -> A: still consistent (A one
# name, B two).
#
# DISCRIMINATION: remove_expect_off=1 lets the remove through: entry a
# (B's) goes, A's count drops to 0 while c still names it, and fsck finds
# both.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in unlink_verify_stall_ms remove_expect_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
POKE="$(ct_helper corrupt_poke)"
IMG="$(ct_image 560 rmlocked)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rmlocked)"
ct_track mnt "$MNT"

# <tag> <control 0|1>
round() {
    local tag="$1" rc=0 out root A B
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    echo apple >"$MNT/a"
    echo banana >"$MNT/b"
    ln "$MNT/b" "$MNT/c"
    sync
    root="$(stat -c %i "$MNT")"; A="$(stat -c %i "$MNT/a")"; B="$(stat -c %i "$MNT/b")"
    ct_param_set remove_expect_off "$2"
    ct_param_set unlink_verify_stall_ms 3000
    MARK="$(dmesg_mark)"
    rm "$MNT/a" >"$MNT.rmout" 2>&1 &
    local pid=$!
    for _ in $(seq 1 50); do dmesg_since "$MARK" | grep -q "name verified, pausing" && break; sleep 0.1; done
    dmesg_since "$MARK" | grep -q "name verified, pausing" ||
        { fail "$tag: setup: the unlink never reached the pause"; wait "$pid" || true; ct_param_set remove_expect_off 0; ct_umount "$MNT"; return 0; }
    "$POKE" "$DEV" repoint "$root" a "$B" >/dev/null
    "$POKE" "$DEV" repoint "$root" c "$A" >/dev/null
    wait "$pid" || rc=$?
    out="$(cat "$MNT.rmout")"; rm -f "$MNT.rmout"
    ct_param_set unlink_verify_stall_ms 0
    ct_param_set remove_expect_off 0
    ct_umount "$MNT"
    local frc=0 fout
    fout="$(ct_fsck "$DEV" 2>&1)" || frc=$?
    if [ "$2" = 1 ]; then
        [ "$rc" = 0 ] && [ "$frc" != 0 ] &&
            pass "$tag: without the check the remove went through and fsck finds the damage: $(grep -m1 ERR <<<"$fout")" ||
            fail "$tag: without the check: rm rc=$rc, fsck rc=$frc -- the control proves nothing"
    else
        # The VFS retries an -ESTALE unlink once with a fresh lookup: that
        # finds a -> B, locks B and removes B's name correctly, so rm may
        # succeed. What matters is that the first remove was refused and
        # the volume is the one the retry describes.
        dmesg_since "$MARK" | grep -q "refusing the remove" && pass "$tag: the remove naming another inode was refused (rm rc=$rc)" ||
            fail "$tag: no refusal in the kernel log (rm rc=$rc: $out)"
        [ "$frc" = 0 ] && pass "$tag: fsck clean" ||
            fail "$tag: fsck rc=$frc: $(grep -m3 ERR <<<"$fout" | tr '\n' ' ')"
        ct_mount "$DEV" "$MNT"
        [ "$(cat "$MNT/c" 2>/dev/null)" = apple ] && [ "$(cat "$MNT/b" 2>/dev/null)" = banana ] &&
            pass "$tag: A still reads through c and B through b" ||
            fail "$tag: c reads '$(cat "$MNT/c" 2>&1)', b reads '$(cat "$MNT/b" 2>&1)'"
        ct_umount "$MNT"
    fi
}

round control 1
round main 0
ct_exit
