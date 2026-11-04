#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# defrag plans from the record and leaf as the DEVICE has them
#
# Defrag rebuilds a file's whole extent tree from the extents it reads
# and publishes it. For a depth-1 file it read the leaf with a plain
# cached read, under "defrag pins the file's exclusive write lock, so no
# peer can be rewriting this leaf: cached is correct" -- and the record
# the same way. The pin stops a peer writing NEXT; it says nothing about
# what a peer wrote and closed since this node cached the leaf. Defrag
# then published a tree without the peer's extents: its data gone, its
# blocks leaked, the file's size put back.
#
# The background pass is the exposed one: defrag.cetra's ioctl comes
# through an open, whose refresh drops a tree a peer has changed, but
# the janitor pins an idle file without opening it.
#
# Staged with one node: the victim spills to a leaf; the janitor is
# triggered and held before it pins the file; one scrub cycle leaves the
# leaf in this node's cache (reads go through the in-core extent cache
# and never touch it); then a "peer" appends a block on the device --
# data written, bitmap bit set, the leaf's last extent grown over it,
# the record's size raised and stamped by another node. Then the pass
# runs, and after a remount the appended block must still be the
# file's.
#
# DISCRIMINATION: without the refresh at the pin
# (cetrafs_lock_defrag_begin()), the pass moves all 7 blocks and then
# publishes this node's stale size: 6 blocks after the remount. Without
# that AND with the leaf read cached again (cetrafs_bread_retry() in
# cetrafs_defrag_read_extents()), it moves 6 and the 7th is lost too.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LEAK="$(ct_helper data_leak_poke)"
IPOKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper leaf_poke)"
[ -w /sys/module/cetrafs/parameters/auto_defrag_begin_delay_ms ] || { skip "auto_defrag_begin_delay_ms is missing"; ct_exit; }

IMG="$(ct_image 560 dfleaf)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dfleaf)"
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
cycles() { sed -n 's/^scrub_cycles: //p' "$PROC"; }
NODE="$(sed -n 's/^this_node_id: //p' "$PROC")"
PEER=$(((${NODE:-0} + 1) % 4))

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
grep -q '^depth=1 ' <<<"$("$IPOKE" "$IMG" extents "$INO" | head -1)" ||
    { fail "setup: the victim did not spill to a leaf"; ct_umount "$MNT"; ct_exit; }

# The background pass, queued by a write-open + close (the trigger) and
# held before it pins the file. That close's open refreshed this node's
# view; what follows it is what the pass must see.
ct_param_set auto_defrag_min_extents 2
ct_param_set auto_defrag_min_pct 0
ct_param_set auto_defrag_begin_delay_ms 15000
ct_param_set auto_defrag 1
: >>"$MNT/victim"
T0=$SECONDS

# One scrub cycle caches the leaf; then no more, so nothing refreshes it.
C0="$(cycles)"
DEADLINE=$((SECONDS + 10))
while [ "$(cycles)" -lt $((C0 + 1)) ] && [ "$SECONDS" -lt "$DEADLINE" ]; do sleep 0.5; done
ct_param_set scrub 0
sleep 1

# The peer's append: block 6 of the file, right after the last extent.
read -r ENT PHYS LEN <<<"$("$LPOKE" "$IMG" show "$INO" | sort -t= -k3 -n |
    awk '{split($4,p,"="); split($5,l,"="); e=$2; ph=p[2]; ln=l[2]} END {print e, ph, ln}')"
NEXT=$((PHYS + LEN))
DATA_START="$(echo "$("$LEAK" "$DEV" 0 0 1)" | sed -n 's/.* lba \([0-9]*\).*/\1/p')"
"$LEAK" "$DEV" 0 $((NEXT - DATA_START)) 1 >/dev/null
python3 -c 'import os,sys; f=os.open(sys.argv[1],os.O_WRONLY); os.pwrite(f,b"PEER"*1024,int(sys.argv[2])*4096); os.fsync(f); os.close(f)' "$IMG" "$NEXT"
"$LPOKE" "$IMG" growlen "$INO" "$ENT" 1 >/dev/null
"$IPOKE" "$IMG" setsize "$INO" $((7 * 4096)) 2>/dev/null
"$IPOKE" "$IMG" peerseq "$INO" "$PEER" 2>/dev/null
[ $((SECONDS - T0)) -lt 13 ] || fail "setup: the peer's append landed $((SECONDS - T0))s after the trigger -- maybe after the pass began"
log "peer appended block 6 at $NEXT (leaf entry $ENT now len $((LEN + 1)), size 7 blocks)"

# Wait for the pass to rebuild the file on the device.
DEADLINE=$((SECONDS + 60))
until grep -q '^depth=0 ' <<<"$("$IPOKE" "$IMG" extents "$INO" | head -1)" || [ "$SECONDS" -ge "$DEADLINE" ]; do
    sleep 1
done
ct_param_set auto_defrag 0
ct_param_set auto_defrag_begin_delay_ms 0

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
RES="$(python3 -c '
import os, sys
d = open(sys.argv[1], "rb").read()
want = b"".join(bytes([65 + i]) * 4096 for i in range(6)) + b"PEER" * 1024
print("ok" if d == want else "size %d, block 6 %s" % (len(d), "missing" if len(d) <= 6 * 4096 else repr(d[6*4096:6*4096+8])))
' "$MNT/victim")"
[ "$RES" = ok ] && pass "after defrag and a remount the file still has the peer's appended block" ||
    fail "after defrag the peer's append is gone: $RES"

ct_umount "$MNT"
# Setup, judged afterwards: defrag must actually have rebuilt the file.
# A declined defrag leaves the poked leaf alone and passes the check
# above against the bug.
SHAPE="$("$IPOKE" "$IMG" extents "$INO" | head -1)"
grep -q '^depth=0 entries=1 ' <<<"$SHAPE" && pass "setup: defrag rebuilt the file into one extent ($SHAPE)" ||
    fail "setup: defrag did not rebuild the file ($SHAPE) -- the check above proves nothing"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
