#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create whose iget fails gives its number back unlocked, so the next create can use it
#
# Since BM-29 a new record is written holding its own namespace lock.
# When the create then failed to instantiate it (iget), the unwind freed
# the number with a swap that zeroes nlink and leaves the lock alone: the
# number went back carrying this node's live lock, and every PEER's allocator
# refused it until this node's next mount (audit 2026-11-15 F-52). The
# unwind now writes the record back dead and unlocked first.
#
# For create, mkdir and symlink: TEST ONLY iget_read_fail=1 fails the
# new object's iget; the operation fails; the freed number's record on
# the device must name no namespace-lock holder. (This node may take its
# own lock over, so its next create reuses the number either way; a PEER
# drawing it waits for a release that never comes, then leaves it
# allocated -- cetrafs_birth_await_release().) fsck stays clean.
#
# DISCRIMINATION: born_unwind_off=1 -- the record keeps this node's lock.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
LOCK_POKE="$(ct_helper inode_lock_poke)"
for k in iget_read_fail born_unwind_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
ct_param_set born_unwind_off 0
ct_param_set iget_read_fail 0
IMG="$(ct_image 560 bornuw)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bornuw)"
ct_track mnt "$MNT"

# <op> <off 0|1> -> RES "failed=<y|n> ns_owner=<id> fsck=<ok|bad>"
round() {
    local want failed=n
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    touch "$MNT/a"
    want=$(($(stat -c %i "$MNT/a") + 1))
    echo "$2" >$P/born_unwind_off
    echo 1 >$P/iget_read_fail
    case "$1" in
    create) touch "$MNT/x" 2>/dev/null || failed=y ;;
    mkdir) mkdir "$MNT/x" 2>/dev/null || failed=y ;;
    symlink) ln -s target "$MNT/x" 2>/dev/null || failed=y ;;
    esac
    echo 0 >$P/iget_read_fail
    echo 0 >$P/born_unwind_off
    ct_umount "$MNT"
    blockdev --flushbufs "$DEV"
    RES="failed=$failed ns_owner=$("$LOCK_POKE" "$DEV" "$want" | sed -n 's/.*ns_owner=\([0-9]*\).*/\1/p')"
    ct_fsck "$DEV" >/dev/null 2>&1 && RES="$RES fsck=ok" || RES="$RES fsck=bad"
}
NONE=65535 # CETRAFS_NODE_ID_NONE
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

for op in create mkdir symlink; do
    round "$op" 0
    F="$RES"
    round "$op" 1
    C="$RES"
    log "$op fixed: $F; control: $C"
    [ "$(field failed "$F")" = y ] || { fail "$op: setup: the injected iget failure did not fail it ($F)"; continue; }
    [ "$(field ns_owner "$F")" = "$NONE" ] && [ "$(field fsck "$F")" = ok ] &&
        pass "$op: the failed birth's number went back unlocked; fsck clean" || fail "$op: $F"
    [ "$(field ns_owner "$C")" != "$NONE" ] &&
        pass "$op control: without the unwind the freed number kept this node's lock ($C)" ||
        fail "$op control: unlocked even without the unwind -- the suite does not see F-52: $C"
done
ct_exit
