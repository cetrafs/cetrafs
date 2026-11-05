#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a write-open clearing a stale reader's bit puts back only a bit it took
#
# A write-open that finds a stale node's presence bit fences the node and
# clears the bit; if the node re-attached meanwhile, the bit is put back
# (it may be the node's new open). But a re-attaching node SWEEPS its own
# leftovers first, and a CLEAR that finds the bit already clear reads,
# through the CAS wrapper, exactly like one that cleared it: the bit was
# "given back" to a node holding no open of the file, and every write-
# open of it, from every node, was refused as "another node is reading
# it" until that node next opened and closed it for read. The give-back
# now requires the clear to have taken a set bit -- reclaim_reattach_
# swept.sh's fix for the lock, applied to the reader bit.
#
# Staged: registry row 1 is a departed node with this file's reader bit;
# the write-open's clear is held after the fence
# (reclaim_stall_before_swap_ms) while row 1 beats AND withdraws its bit.
#
# DISCRIMINATION: the setup checks require the fence and the withdrawn
# bit. Proven by removing the rctx.displaced test: the bit is put back
# and the file is refused to writers.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/reclaim_stall_before_swap_ms ] || { skip "reclaim_stall_before_swap_ms is missing"; ct_exit; }
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 rrsw)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rrsw)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/zero of="$MNT/f" bs=4096 count=4 conv=fsync status=none
INO="$(stat -c %i "$MNT/f")"
ct_umount "$MNT"

"$NPOKE" "$IMG" 1 1 bb 0 >/dev/null 2>&1 || { fail "setup: could not register row 1"; ct_exit; }
"$LPOKE" "$IMG" "$INO" --reader 1 >/dev/null
grep -q "readers=0x2" <<<"$("$LPOKE" "$IMG" "$INO")" || { fail "setup: row 1's reader bit is not set: $("$LPOKE" "$IMG" "$INO")"; ct_exit; }
ct_mount "$DEV" "$MNT"

ct_param_set reclaim_stall_before_swap_ms 2000
MARK="$(dmesg_mark)"
( sleep 0.8; "$NPOKE" "$IMG" 1 --beat >/dev/null 2>&1; "$LPOKE" "$IMG" "$INO" --unreader 1 >/dev/null 2>&1 ) &
B=$!
RC=0
python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$MNT/f" 2>/dev/null || RC=$?
wait "$B" || true
LEFT="$(cat /sys/module/cetrafs/parameters/reclaim_stall_before_swap_ms)"
ct_param_set reclaim_stall_before_swap_ms 0
L="$("$LPOKE" "$IMG" "$INO")"
log "write-open rc=$RC; $L; $(dmesg_since "$MARK" | grep -m1 'came back' || true)"
# The stall is one-shot: consumed means the clear was reached.
[ "$LEFT" = 0 ] ||
    { fail "setup: the stall was never consumed -- no clear of row 1's bit was attempted: $(dmesg_since "$MARK" | tail -3 | tr '\n' ' ')"; ct_exit; }
grep -q "readers=0x2\|readers=0x3" <<<"$L" &&
    fail "row 1 was handed back a reader bit no open of it owns: $L" ||
    pass "row 1 was not handed a reader bit it had already withdrawn ($L)"
RC2=0
python3 -c 'import os,sys; os.close(os.open(sys.argv[1], os.O_RDWR))' "$MNT/f" 2>/dev/null || RC2=$?
[ "$RC2" = 0 ] && pass "the file opens for writing" || fail "the file is refused to writers (rc=$RC2, first open rc=$RC)"
"$NPOKE" "$IMG" 1 0 bb 0 >/dev/null 2>&1
ct_umount "$MNT"
ct_exit
