#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an inode-number claim this node could not give back is retried
#
# Freeing an inode number claims its dead record (ns_lock_owner = this
# node), clears the bit, then RELEASES the record; a create that fails
# after its birth claim gives it back with BIRTH_ABORT. Either give-back
# failing was logged (or not even that: `(void)`) and left. The record
# then stayed locked by a node that keeps beating: every orphan scrub
# skipped it and every peer that drew the number abandoned it, for good.
# Now the heartbeat retries it.
#
# A: an unlink's evict, its RELEASE failing once.
# B: a create whose post-claim bit check fails (birth_check_fail), its
#    BIRTH_ABORT failing once.
# Each: the record must still be claimed right after, and released a few
# heartbeats later.
#
# DISCRIMINATION: with the give-backs fire-and-forget, both records still
# read ns_owner=<this node> when the wait ends.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in reclaim_giveback_fail birth_check_fail; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 rcgive)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rcgive)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 2
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"

# check <label> <mark>: the inode the failed give-back names must be
# claimed now and released within 20 s.
check() {
    local ino d
    ino="$(dmesg_since "$2" | sed -n 's/.*inode ino=\([0-9]*\): reclaim claim not given back.*/\1/p' | head -1)"
    [ -n "$ino" ] || { fail "$1: setup: no give-back failed ($(dmesg_since "$2" | tail -2))"; return; }
    d="$("$LOCK_POKE" "$IMG" "$ino")"
    grep -q "ns_owner=$NID " <<<"$d" || { fail "$1: setup: ino $ino is not claimed by this node right after ($d)"; return; }
    for _ in $(seq 1 20); do
        grep -q 'ns_owner=65535' <<<"$("$LOCK_POKE" "$IMG" "$ino")" && { pass "$1: the heartbeat gave ino $ino back"; return; }
        sleep 1
    done
    fail "$1: ino $ino is still claimed by this node 20 s later ($("$LOCK_POKE" "$IMG" "$ino"))"
}

# --- A: RELEASE, from an unlink's evict.
echo a >"$MNT/a"; sync
MARK="$(dmesg_mark)"
ct_param_set reclaim_giveback_fail 1
rm "$MNT/a"
sync
check "A (release)" "$MARK"

# --- B: BIRTH_ABORT, from a create that fails after its claim.
MARK="$(dmesg_mark)"
ct_param_set birth_check_fail 1
ct_param_set reclaim_giveback_fail 1
if ( : >"$MNT/b" ) 2>/dev/null; then
    fail "B: setup: the create succeeded -- the injected bit-check failure did not fire"
else
    check "B (birth abort)" "$MARK"
fi
ct_param_set birth_check_fail 0
ct_param_set reclaim_giveback_fail 0

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
