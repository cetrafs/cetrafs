#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# flock(LOCK_EX) under nofilelock takes the file as the device has it, not as this node cached it
#
# Under nofilelock the migration orchestrator holds the target's fd open
# across the handoff and closes the window with flock(LOCK_EX)
# (docs/internal/OPERATIONS.md). From the claim on, this node is the
# file's only writer, and both cache predicates go back to trusting what
# it has in core. A peer that extended the file while this node had it
# open -- the source host, writing until the handoff -- left a newer
# size and tree on the device, stamped with its file_seq. If the claim
# does not reconcile, the first append after it lands at this node's
# old end of file, over the peer's extension, and its publish puts the
# old size back. The default mount's resume does exactly this reconcile
# (lock_resume_reconcile.sh); this is the same hazard reached through
# the explicit claim.
#
# Staged with one node: the peer's extension is the record rewritten on
# the device (8 KiB -> 16 KiB, stamped by another node id) while this
# node's fd is open and idle. Then flock(LOCK_EX) and one append.
#
# The same claim must also drop the pages this node read while the peer
# was writing: from the claim on the read gate trusts them. Applying the
# peer's record drops them (the refresh's invalidate_inode_pages2()); the
# "pages" rounds read block 0 before the peer overwrites it on the
# device, and read it again after LOCK_EX.
#
# DISCRIMINATION: flock_claim_no_reconcile=1 skips the reconcile; the
# append then lands at 8 KiB, and the read after the claim returns the
# page cached before the peer's overwrite.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/flock_claim_no_reconcile ] || { skip "flock_claim_no_reconcile is missing"; ct_exit; }

POKE="$(ct_helper inode_block_poke)"
IMG="$(ct_image 560 nflrec)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nflrec)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
grep -q '^file_lock: off' "$(ct_procdir "$DEV")/info" || { fail "setup: the mount is not nofilelock"; ct_exit; }
NODE="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((${NODE:-0} + 1) % 4))

# round <name> <skip-reconcile 0|1>
round() {
    local name="$1" F="$MNT/f.$1" GATE INO SZ TAIL
    GATE="$(ct_tmp "nflrec-gate-$1")"
    rm -f "$GATE" "$GATE.done"
    ct_param_set flock_claim_no_reconcile "$2"
    python3 - "$F" "$GATE" <<'PY' &
import os, sys, fcntl, time
path, gate = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
os.write(fd, b"a" * 8192); os.fsync(fd)
open(gate, "w").close()
while not os.path.exists(gate + ".done"):      # the peer extends it
    time.sleep(0.05)
fcntl.flock(fd, fcntl.LOCK_EX)                 # the handoff closes: ours alone
os.write(fd, b"W" * 4096); os.fsync(fd)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
    local pid=$!
    for _ in $(seq 1 100); do [ -e "$GATE" ] && break; sleep 0.1; done
    [ -e "$GATE" ] || { fail "$name: setup: the writer never got going"; wait "$pid" || true; return 0; }
    INO="$(stat -c %i "$F")"
    "$POKE" "$IMG" setsize "$INO" 16384 2>/dev/null
    "$POKE" "$IMG" peerseq "$INO" "$PEER" 2>/dev/null
    touch "$GATE.done"
    wait "$pid" || fail "$name: the writer process failed"
    ct_param_set flock_claim_no_reconcile 0

    ct_umount "$MNT"
    mount -t cetrafs -o nofilelock "$DEV" "$MNT"
    SZ="$(stat -c %s "$F")"
    TAIL="$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(d[16384:16388])' "$F")"
    if [ "$2" = 1 ]; then
        [ "$SZ" != 20480 ] && pass "$name: without the reconcile the append used the stale size ($SZ)" ||
            fail "$name: without the reconcile the append still landed at the peer's end -- the control proves nothing"
    else
        [ "$SZ" = 20480 ] && [ "$TAIL" = "b'WWWW'" ] &&
            pass "$name: the append after LOCK_EX landed at the peer's end of file (size $SZ)" ||
            fail "$name: the append after LOCK_EX did not land at the peer's end: size $SZ, bytes at 16 KiB $TAIL"
    fi
}

round control 1
round main 0

# pages <name> <skip-reconcile 0|1>
pages() {
    local name="$1" F="$MNT/p.$1" GATE OUT PB GOT
    GATE="$(ct_tmp "nflrec-pgate-$1")"
    OUT="$(ct_tmp "nflrec-pout-$1")"
    rm -f "$GATE" "$GATE.done" "$OUT"
    ct_param_set flock_claim_no_reconcile "$2"
    python3 - "$F" "$GATE" "$OUT" <<'PY' &
import os, sys, fcntl, time
path, gate, out = sys.argv[1], sys.argv[2], sys.argv[3]
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
os.write(fd, b"a" * 8192); os.fsync(fd)
os.pread(fd, 4096, 0)                          # cached here, before the peer
open(gate, "w").close()
while not os.path.exists(gate + ".done"):      # the peer overwrites block 0
    time.sleep(0.05)
fcntl.flock(fd, fcntl.LOCK_EX)
open(out, "wb").write(os.pread(fd, 4, 0))
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
    local pid=$!
    for _ in $(seq 1 100); do [ -e "$GATE" ] && break; sleep 0.1; done
    [ -e "$GATE" ] || { fail "$name: setup: the reader never got going"; wait "$pid" || true; return 0; }
    PB="$(filefrag -v "$F" 2>/dev/null | awk '$1 == "0:" { sub(/\.\..*/, "", $4); print $4; exit }')"
    case "$PB" in "" | *[!0-9]*) fail "$name: setup: no physical block for block 0 ($PB)"; touch "$GATE.done"; wait "$pid" || true; return 0 ;; esac
    printf 'P%.0s' $(seq 1 4096) | dd of="$IMG" bs=4096 seek="$PB" conv=notrunc,fsync status=none
    "$POKE" "$IMG" peerseq "$(stat -c %i "$F")" "$PEER" 2>/dev/null
    touch "$GATE.done"
    wait "$pid" || fail "$name: the reader process failed"
    ct_param_set flock_claim_no_reconcile 0
    GOT="$(cat "$OUT" 2>/dev/null)"
    if [ "$2" = 1 ]; then
        [ "$GOT" = aaaa ] && pass "$name: without the reconcile the read after LOCK_EX served the page cached before the peer" ||
            fail "$name: without the reconcile the read returned '$GOT' -- the control proves nothing"
    else
        [ "$GOT" = PPPP ] && pass "$name: the read after LOCK_EX returns the peer's data" ||
            fail "$name: the read after LOCK_EX returned '$GOT', not the peer's overwrite"
    fi
}

pages pages_control 1
pages pages_main 0

ct_umount "$MNT"
ct_exit
