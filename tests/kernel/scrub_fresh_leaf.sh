#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the scrub's DECIDING pass must read the extent LEAF from the device too
#
# scrub_fresh_refset.sh made the deciding pass re-read every allocated
# inode RECORD fresh. The tree under it was still walked from the buffer
# cache, under a comment saying the scrub "reads conservatively" -- and
# for a depth-1 or depth-2 file the record only points at its leaves; the
# extents are in them. A peer appending extents to a leaf in place leaves
# this node holding the older leaf, which names fewer blocks, and the
# scrub frees what it does not see named: rule 6 one level down. Every VM
# image of any size is depth 1 or 2.
#
# Staged with one node, as scrub_fresh_refset.sh is: the victim is spilled
# to depth 1 and one scrub cycle is let run, which leaves its leaf in
# this node's cache; then a block is allocated behind the kernel's back
# and the leaf's last extent is grown ON THE DEVICE to cover it. The
# kernel holds a leaf that does not name it.
#
# DISCRIMINATION: with cetrafs_scrub_tree_bread() reading cached on the
# deciding pass too (return cetrafs_bread_retry() whatever 'fresh' says),
# the block is reclaimed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LEAK="$(ct_helper data_leak_poke)"
IPOKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper leaf_poke)"

IMG="$(ct_image 560 scrubleaf)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt scrubleaf)"
ct_mkfs_small "$DEV" -z 1 >/dev/null

ct_param_set scrub 1
ct_param_set scrub_interval_secs 3
ct_param_set scrub_gap_secs 2
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0

ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
cycles()  { sed -n 's/^scrub_cycles: //p' "$PROC"; }
reclaim() { sed -n 's/^scrub_reclaimed: //p' "$PROC"; }

# Six single-block extents, a spacer block between each so none merge:
# more than the record's 4 inline slots, so the map spills to a leaf.
# The victim's block is written LAST, so the block after it is free.
python3 - "$MNT" <<'PY'
import os, sys
v = os.open(sys.argv[1] + "/victim", os.O_WRONLY | os.O_CREAT, 0o644)
s = os.open(sys.argv[1] + "/spacer", os.O_WRONLY | os.O_CREAT, 0o644)
for i in range(6):
    if i:
        os.pwrite(s, b"s" * 4096, (i - 1) * 4096); os.fsync(s)
    os.pwrite(v, bytes([65 + i]) * 4096, i * 4096); os.fsync(v)
os.close(s); os.close(v)
PY
sync
INO="$(stat -c %i "$MNT/victim")"
SHAPE="$("$IPOKE" "$IMG" extents "$INO" | head -1)"
grep -q '^depth=1 ' <<<"$SHAPE" || { fail "setup: the victim did not spill to a leaf ($SHAPE)"; ct_umount "$MNT"; ct_exit; }
# The entry with the highest physical start: the block after it is the
# one nobody has allocated.
LAST="$("$LPOKE" "$IMG" show "$INO" | sort -t= -k3 -n | awk '{split($4,p,"="); split($5,l,"="); e=$2; ph=p[2]; ln=l[2]} END {print e, ph, ln}')"
read -r ENT PHYS LEN <<<"$LAST"
NEXT=$((PHYS + LEN))
log "victim ino=$INO $SHAPE; highest extent: entry $ENT phys=$PHYS len=$LEN"

# One full scrub cycle first. Its walk is what puts the leaf in this
# node's buffer cache -- reads of the file go through the in-core extent
# cache and never touch the leaf block -- so after it the cached copy
# exists and is clean, and the poke below makes it stale. Before it,
# a cached read would simply fetch the poked leaf from the device and
# the test would pass against the bug.
C0="$(cycles)"
DEADLINE=$((SECONDS + 60))
while [ "$(cycles)" -lt $((C0 + 1)) ]; do
    [ "$SECONDS" -lt "$DEADLINE" ] || { fail "setup: no scrub cycle completed in 60s"; break; }
    sleep 1
done

DATA_START="$(echo "$("$LEAK" "$DEV" 0 0 1)" | sed -n 's/.* lba \([0-9]*\).*/\1/p')"
"$LEAK" "$DEV" 0 $((NEXT - DATA_START)) 1 >/dev/null
log "allocated block $NEXT behind the kernel's back"
C0="$(cycles)"; R0="$(reclaim)"

"$LPOKE" "$IMG" growlen "$INO" "$ENT" 1 >/dev/null
AFTER="$("$LPOKE" "$IMG" show "$INO" | awk -v e="$ENT" '$2 == e {split($5,l,"="); print l[2]}')"
[ "$AFTER" = $((LEN + 1)) ] &&
    pass "setup: the leaf on the device now covers $NEXT (len $LEN -> $AFTER); the cached leaf does not" ||
    { fail "setup: growlen did not land (len reads $AFTER)"; ct_umount "$MNT"; ct_exit; }

log "waiting for 2 full scrub cycles (from $C0) ..."
DEADLINE=$((SECONDS + 90))
while [ "$(cycles)" -lt $((C0 + 2)) ]; do
    [ "$SECONDS" -lt "$DEADLINE" ] || { fail "no 2 scrub cycles completed in 90s (cycles=$(cycles))"; break; }
    sleep 1
done
REC=$(($(reclaim) - R0))
[ "$REC" = 0 ] &&
    pass "the scrub freed nothing: its deciding pass re-read the leaf and saw the block named" ||
    fail "the scrub reclaimed $REC block(s) that the on-disk leaf names -- it decided on a cached leaf"

ct_umount "$MNT"
ct_exit
