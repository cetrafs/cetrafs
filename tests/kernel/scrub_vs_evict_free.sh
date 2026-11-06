#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub never reclaims a deleted file's blocks while its evict is still freeing them
#
# Evict used to free the inode NUMBER first and the extents after, one by
# one -- for a fragmented VM image tens of thousands of frees, seconds to
# minutes. From the number free on, the record is a freed slot, which the
# block scrub does not walk, so every extent not yet freed was set in the
# bitmap and named by nothing: a candidate. The scrub freed them, the
# allocator handed them to another file, and the evict's own free then
# cleared the bit under it (audit 2026-11-06 H1). Now the number is freed
# last, the record claimed throughout (cetrafs_free_inode_begin()).
#
# Staged on one node: evict_free_stall_ms holds the evict between owning
# the free and its first block free -- the window a fragmented file's
# frees open in production -- while the scrub cycles every few seconds.
# Asserted: the scrub ran across the window, reclaimed nothing, the
# blocks came back through the evict alone (free count restored) and
# fsck is clean.
#
# DISCRIMINATION: with the number freed first (cetrafs_free_inode_if_dead()
# before the stall) the scrub reclaims the file's blocks inside the
# window and the evict then frees them a second time.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/evict_free_stall_ms ] || { skip "evict_free_stall_ms is missing"; ct_exit; }

BLOCKS=2000
HOLD_MS=9000 # three 3 s scrub cycles
DEV="$(ct_dev 900 scevict)"
MNT="$(ct_mnt scevict)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set scrub_interval_secs 2
ct_param_set scrub_gap_secs 1
ct_param_set scrub 0 # armed for the window only
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
PROC="$(ct_procdir "$DEV")"
reclaimed() { sed -n 's/^scrub_reclaimed: //p' "$PROC/info"; }
cycles() { sed -n 's/^scrub_cycles: //p' "$PROC/info"; }
freeblk() { stat -f -c %f "$MNT"; }

F0="$(freeblk)"
dd if=/dev/urandom of="$MNT/vm.img" bs=4096 count="$BLOCKS" status=none
sync
F1="$(freeblk)"
[ $((F0 - F1)) -ge "$BLOCKS" ] || { fail "setup: the file did not take $BLOCKS blocks ($F0 -> $F1)"; ct_exit; }

MARK="$(dmesg_mark)"
R0="$(reclaimed)"
C0="$(cycles)"
ct_param_set evict_free_stall_ms "$HOLD_MS"
ct_param_set scrub 1
T0=$SECONDS
rm "$MNT/vm.img" &
RMPID=$!
wait "$RMPID" || fail "setup: the unlink failed"
HELD=$((SECONDS - T0))
ct_param_set evict_free_stall_ms 0
# two more cycles after the evict: a verdict taken inside the window
# would be acted on by now
wait_for 30 '[ "$(( $(cycles) - '"$C0"' ))" -ge 3 ]' || true
NC=$(($(cycles) - C0))
GOT=$(($(reclaimed) - R0))
ct_param_set scrub 0

[ "$HELD" -ge $((HOLD_MS / 1000 - 1)) ] || fail "setup: the evict was not held (${HELD}s) -- the window never opened"
[ "$NC" -ge 2 ] || { fail "setup: the scrub ran $NC cycle(s) across the window -- nothing was measured"; ct_exit; }
[ "$GOT" = 0 ] && pass "the scrub reclaimed nothing while the evict was freeing ($NC cycles)" ||
    fail "the scrub reclaimed $GOT block(s) of a file whose evict was still freeing them"
F2="$(freeblk)"
[ "$F2" -ge "$F0" ] && pass "the evict gave every block back ($F1 -> $F2, started at $F0)" ||
    fail "the free count did not come back ($F0 before, $F2 after)"
dmesg_since "$MARK" | grep -qiE "already free|double free" &&
    fail "a block was freed twice: $(dmesg_since "$MARK" | grep -iE 'already free|double free' | head -2)" ||
    pass "no block was freed twice"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && ! grep -q '^ERR' <<<"$OUT" && pass "fsck clean" ||
    fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)"
ct_exit
