#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the work the heartbeat tick does, proven to have RUN
#
# Periodic work fails silently by nature: nothing errors, the work
# simply stops happening. This project has already been bitten once --
# folding two record writes into one CAS silently stopped the background
# defragmenter, because its gate keyed off a value that only read NONE
# as a side effect of the old code -- and three of the tick's passes
# still had no test that they run ON A TICK. The call sites that WERE
# covered are different ones: the pending-free drain was tested at
# MOUNT, journal replay at ZG-STEAL time, and auto-defrag only at CLOSE.
#
# Each section below therefore asserts the observable appears with
# nothing touching the filesystem but time, and each has been checked by
# disabling the call and watching the assertion fail. That last step is
# the whole point: a test that cannot fail proves nothing, and a
# tick-driven test that merely re-checks correct-when-called code is
# exactly that.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
# This suite needs FRAGMENTED files: an external leaf, a depth-1 tree, an
# auto-defrag trigger. Speculative run allocation makes a sequential write
# land contiguously and merge into one extent, so the fragmentation its
# setup relies on never happens and the suite would test nothing (several
# assertions below check exactly that precondition, which is how this was
# caught). Turn runs off so allocation goes back one block at a time.
ct_param_set alloc_run_blocks 0
PENDPOKE="$(ct_helper pending_poke)"
NODEPOKE="$(ct_helper node_poke)"
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"

# Compress the tick so a suite does not wait 15s per observation. The
# parameter is runtime-writable precisely so tests need not.
# ct_param_set, not a hand-rolled trap: a `trap ... EXIT` in a suite
# REPLACES the harness's own cleanup trap, and it would restore after
# ct_exit has already checked. The setter restores inside ct_exit,
# before the check.
ct_param_set hb_interval_secs 2

# Wait for a condition, up to N seconds. Takes a shell STRING and
# re-evaluates it each round: the first version took "command args" and
# the command substitutions in those args were expanded once, at call
# time, so the condition could never change and every wait timed out
# while the thing being waited for had already happened.
IMG="$(ct_image 560 hbwork)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt hbwork)"
# A real journal area: the stale-peer sweep has nothing to replay without one.
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "the pending-free queue is drained ON A TICK, not only at mount"
# tests/kernel/pending_free.sh covers the drain at MOUNT and proves the
# free is applied exactly once. What it cannot show is that the TICK
# drains at all -- a different call site. The entry here names a block
# that is already free, so applying it is a no-op (apply tests each bit
# before clearing) and the only observable is that the entry was
# CONSUMED, which is what the tick is responsible for.
FREE_LBA="$(python3 -c "print(60000)")"
"$PENDPOKE" "$IMG" add 0 "$FREE_LBA" 1 >/dev/null
[ "$("$PENDPOKE" "$IMG" dump 0 | grep -c .)" -ge 1 ] &&
    pass "a pending-free entry is queued against this node's own zone group" ||
    fail "the poke did not queue anything -- nothing below would mean anything"

if wait_for 20 '[ "$("$PENDPOKE" "$IMG" dump 0 | grep -c . || true)" = "0" ]'; then
    pass "the heartbeat tick drained the queue with nothing else touching the filesystem"
else
    fail "the queue still holds $("$PENDPOKE" "$IMG" dump 0 | grep -c .) entr(ies) after 20s of ticks"
fi

log "a stale peer's dirty journal is swept ON A TICK"
# The ZG-steal and lock-reclaim paths replay a stale node's journal
# themselves, promptly, and those are the paths that have tests. This
# sweep is the catch-all for a crashed node that owned no zone group and
# held no lock anyone has since asked about -- so nothing else would
# ever replay it, and nothing proved the sweep runs.
PEER=1
PAY="$(mktemp)"; head -c 4096 /dev/zero >"$PAY"
"$NODEPOKE" "$IMG" "$PEER" 1 ee 0 >/dev/null 2>&1   # REGISTERED, last_seen=0 -> stale at once
"$JPOKE" "$IMG" "$PEER" 0 60001 "$PAY" >/dev/null 2>&1
rm -f "$PAY"
# The lease this sweep must revoke before it touches the peer's state.
ROW_BEFORE="$("$NODEPOKE" "$IMG" "$PEER")"
EPOCH_BEFORE="${ROW_BEFORE#*fence_epoch=}"; EPOCH_BEFORE="${EPOCH_BEFORE%% *}"
MARK="$(dmesg_mark)"
# Scoped to THIS run and to this peer: the first version grepped all of
# dmesg for "replay" and would have passed on any earlier line.
if wait_for 20 'dmesg_since "$MARK" | grep -q "journal replay: node '"$PEER"' replayed"'; then
    pass "the tick noticed a stale peer's dirty journal and replayed it"
else
    fail "no replay happened in 20s of ticks: $(dmesg_since "$MARK" | tail -3)"
fi

# ...and FENCED it first. Replay blind-writes a peer's recorded block
# images and zeroes its journal slot headers. If that peer is merely
# SLOW rather than dead, its journal is dirty because it is mid-
# operation -- so replaying lands old images over blocks it is still
# writing and destroys the write-ahead protection of the operation in
# flight. The ZG-steal and lock-reclaim paths revoke the lease first;
# this sweep did not, and it is the ONE site where nothing else has,
# since it exists for a node nobody took a ZG or a lock from.
#
# Asserted after the replay is observed, so the ordering under test
# (fence, THEN replay) is the only way this can be true.
ROW_AFTER="$("$NODEPOKE" "$IMG" "$PEER")"
EPOCH_AFTER="${ROW_AFTER#*fence_epoch=}"; EPOCH_AFTER="${EPOCH_AFTER%% *}"
[ "$EPOCH_AFTER" -gt "$EPOCH_BEFORE" ] &&
    pass "the tick revoked the stale peer's lease before replaying it ($EPOCH_BEFORE -> $EPOCH_AFTER)" ||
    fail "the peer's journal was replayed with its lease intact (fence_epoch still $EPOCH_AFTER): a merely-slow node would keep writing into what we just rewrote"

log "auto-defrag triggers from the EXTENT-APPEND path, on a file never closed"
# The case this filesystem exists for: a VM image open for months. Only
# the close-time trigger had a test, and a file that is never closed
# never reaches it -- cetrafs_defrag_consider() is called from file.c's
# extent-append path for exactly that reason.
ct_param_set auto_defrag 1
# The WRITE fd must stay open, and that is subtler than it looks: the
# close-time trigger fires when the last WRITE opener closes, not when
# the last opener does. A first version had the shell hold a read-only
# fd while the writing process exited -- which fires the close trigger,
# so the assertion below passed with the append-path trigger disabled
# and proved nothing. Measured; now a background writer holds the write
# fd open for the whole observation and is killed afterwards.
#
# DENSE but physically fragmented: two files written alternately a block
# at a time, so the allocator interleaves them. The very first version
# wrote one file at stride 2, which is fragmented but SPARSE -- and
# defrag declines a sparse file with -EOPNOTSUPP on a path that logs
# nothing, so the test sat waiting for something the kernel had already
# silently refused. A dense, scattered file is the real VM-image shape
# anyway.
: >"$MNT/openfile"
MARK_DEF="$(dmesg_mark)"
python3 -u -c '
import os, sys, time
a = os.open(sys.argv[1], os.O_WRONLY)
b = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT, 0o644)
blk = b"v" * 4096
for i in range(24):
    os.pwrite(a, blk, i * 4096)
    os.pwrite(b, blk, i * 4096)      # steals the next physical block
os.fsync(a); os.fsync(b)
os.close(b)
time.sleep(120)                      # a is NEVER closed while we observe
' "$MNT/openfile" "$MNT/filler" &
HOLDER=$!
sleep 3
INO="$(stat -c '%i' "$MNT/openfile")"

# The observable is that the janitor RAN, not the end state. The
# append-path trigger fires DURING the writes, so by the time the shell
# can look the relocation has usually already happened -- an
# "extents before vs after" assertion then measures nothing and passes
# trivially, which is exactly what the first version of this did.
#
# The worker logs the move with the inode number, and fd 9 holds the
# file open throughout, so a line naming this inode can only have come
# from the append-path trigger: the close-time one has not run yet.
if wait_for 40 'dmesg_since "$MARK_DEF" | grep -q "auto-defrag: ino='"$INO"'"'; then
    pass "the janitor relocated a file that is still open (append-path trigger fired)"
    dmesg_since "$MARK_DEF" | grep "auto-defrag: ino=$INO" | head -1 | sed 's/^/       /'
else
    fail "no auto-defrag for ino=$INO in 40s with the file still open -- the append-path trigger never fired"
fi

kill -0 "$HOLDER" 2>/dev/null &&
    pass "the writer still holds the file open, so this was not the close-time trigger" ||
    fail "the writing process exited -- its close could have been what fired the janitor"
kill "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true
exec 9>&-

log "the volume is consistent after all of it"
sync
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -3)"
ct_exit
