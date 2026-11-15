#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# evict frees what the record names under its claim, not what it named at the verdict
#
# Evict read the extent list and the xattr pointer before claiming the
# dead record, and freed them after. The claim compares the namespace
# stamp, which a peer's namespace-locked truncate or removexattr on the
# dead record does not move: the peer freed what it took off the record,
# the claim still landed, and evict freed the same blocks again -- a
# live block once one was reallocated (audit 2026-11-15 BM N-69). Evict
# now re-reads the record under its claim and frees what it names then.
#
# A file of 64 blocks with an xattr block is unlinked; evict is parked
# between its verdict and its claim (evict_stall_before_free_ms), and the
# record is changed there as a peer's truncate to 0 and removexattr leave
# it (inode_lock_poke --peer-strip; the poke frees nothing, as the peer's
# frees are its own):
#   1. evict saw the change and freed none of the 65 blocks the verdict
#      read named;
#   2. it still freed the number.
#
# DISCRIMINATION: evict_claim_no_reread=1 (free what the verdict read):
# the 65 blocks are freed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in evict_claim_no_reread evict_stall_before_free_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt ecr)"
ct_track mnt "$MNT"
ct_param_set evict_claim_no_reread 0
ct_param_set evict_stall_before_free_ms 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
info() { sed -n "s/^$1: //p" "$PROC/info"; }
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | sed 's/^[^=]*=//'; }

# <tag> <no_reread 0|1> -> RES
round() {
    local img dev ino b0 i0 c0 rpid
    img="$(ct_image 560 "ecr$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs_small "$dev" >/dev/null
    ct_mount "$dev" "$MNT"
    PROC="$(ct_procdir "$dev")"
    dd if=/dev/urandom of="$MNT/f" bs=4096 count=64 conv=fsync status=none
    python3 -I -c 'import os, sys; os.setxattr(sys.argv[1], "user.k", b"v" * 200)' "$MNT/f"
    ino="$(stat -c %i "$MNT/f")"
    sync
    b0="$(info free_data_blocks)" i0="$(info free_inodes)" c0="$(info evict_rereads_changed)"
    echo "$2" >$P/evict_claim_no_reread
    echo 3000 >$P/evict_stall_before_free_ms
    rm -f "$MNT/f" &
    rpid=$!
    sleep 1
    "$LOCK_POKE" "$img" --peer-strip "$ino" 1 >/dev/null
    wait "$rpid" || true
    echo 0 >$P/evict_stall_before_free_ms
    echo 0 >$P/evict_claim_no_reread
    sync
    RES="freed_blocks=$(($(info free_data_blocks) - b0)) freed_inodes=$(($(info free_inodes) - i0))"
    RES="$RES changed=$(($(info evict_rereads_changed) - c0))"
    ct_umount "$MNT"
}

round c 1
C="$RES"
log "control (free what the verdict read): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get freed_blocks "$C")" -ge 65 ] ||
    { fail "setup: the control did not free the file's 65 blocks ($C) -- the stall or the file did not happen"; ct_exit; }
[ "$(get changed "$R")" = 1 ] && [ "$(get freed_blocks "$R")" = 0 ] &&
    pass "1: evict saw the change under its claim and freed none of the 65 blocks the verdict named" || fail "1: $R"
[ "$(get freed_inodes "$R")" = 1 ] && pass "2: the number was freed" || fail "2: $R"
pass "control: freeing what the verdict read freed $(get freed_blocks "$C") blocks the record no longer named"
ct_exit
