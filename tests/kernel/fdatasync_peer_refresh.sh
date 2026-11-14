#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a file kept current only by fdatasync still takes a peer's record change
#
# An fdatasync of a pure overwrite leaves the new times unpublished for
# writeback (P8(c)), up to 30 s. The refresh guard used to count times
# that differ from the stat baseline as unpublished local state and
# decline a peer's record apply -- so under nofilelock a node that only
# ever fdatasyncs its image kept a peer's size, and every other field,
# out for that window, and a read past its stale size came back short.
#
# Now the guard declines only for size, blocks and a staged shadow; the
# apply keeps this node's unpublished times, and writeback still
# publishes them.
#
# Close publishes the times, so the window is a file held open -- a VM
# image -- and what applies a peer's record to it is a lock boundary:
# here flock(LOCK_EX) under nofilelock, whose claim reconciles the
# record and fails (EWOULDBLOCK) when the apply declines. Staged with
# one node: the file is held open, written over and fdatasync'd (times
# left behind); the peer's change is the record rewritten on the device
# (a larger size, file_seq stamped by another node id); the flock must
# succeed and see the peer's size.
#   1. flock(LOCK_EX) sees the peer's size;
#   2. this node's own mtime survived the apply, and a full fsync
#      publishes it.
#
# DISCRIMINATION: apply_times_decline=1, the old guard: the reopen
# reports the old size.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/apply_times_decline ] || { skip "apply_times_decline is missing"; ct_exit; }

POKE="$(ct_helper inode_block_poke)"
IMG="$(ct_image 560 dsyncpeer)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dsyncpeer)"
ct_mkfs_small "$DEV" >/dev/null
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
ct_track mnt "$MNT"
require_cetrafs_mount "$MNT"
NODE="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
PEER=$(((${NODE:-0} + 1) % 4))

# <name> <decline 0|1> -> "<size seen> <mtime kept 0|1> <device mtime == local after fsync 0|1>"
round() {
    local F="$MNT/$1" ino out
    python3 -c 'import os,sys; fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT,0o644); os.write(fd,b"a"*8192); os.fsync(fd); os.close(fd)' "$F"
    ino="$(stat -c %i "$F")"
    ct_param_set apply_times_decline "$2"
    out="$(python3 - "$F" "$IMG" "$POKE" "$ino" "$PEER" <<'PY'
import os, sys, time, subprocess
f, img, poke, ino, peer = sys.argv[1:]
import fcntl
fd = os.open(f, os.O_RDWR)
time.sleep(1.2)                       # the overwrite moves mtime by a second
os.pwrite(fd, b"b" * 4096, 0)
os.fdatasync(fd)                      # times left for writeback
m_local = os.fstat(fd).st_mtime_ns // 10**9
dev_m = int(subprocess.check_output([poke, img, "mtime", ino]).split()[-1])
if dev_m == m_local:
    print("setup-times-published 0 0"); sys.exit(0)
subprocess.check_call([poke, img, "setsize", ino, "16384"], stderr=subprocess.DEVNULL)
subprocess.check_call([poke, img, "peerseq", ino, peer], stderr=subprocess.DEVNULL)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)  # the claim reconciles the peer's record
except OSError as e:
    print("flock-refused-%d 0 0" % e.errno); sys.exit(0)
size = os.fstat(fd).st_size
kept = int(os.fstat(fd).st_mtime_ns // 10**9 == m_local)
os.fsync(fd)
dev_m = int(subprocess.check_output([poke, img, "mtime", ino]).split()[-1])
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
print(size, kept, int(dev_m == m_local))
PY
)"
    ct_param_set apply_times_decline 0
    echo "$out"
}

read -r S K P <<<"$(round fixed 0)"
log "fixed: after flock, size $S, local mtime kept $K, published by fsync $P"
read -r S0 K0 P0 <<<"$(round control 1)"
log "control: after flock, size $S0"
[ "$S" != setup-times-published ] && [ "$S0" != setup-times-published ] ||
    { fail "setup: the fdatasync published the times -- no unpublished times to test"; ct_exit; }
[ "$S" = 16384 ] && pass "1: flock(LOCK_EX) sees the peer's size ($S)" ||
    fail "1: flock(LOCK_EX) sees size $S -- the peer's record was declined"
[ "$K" = 1 ] && [ "$P" = 1 ] && pass "2: this node's mtime survived the apply and fsync published it" ||
    fail "2: local mtime kept=$K, published by fsync=$P"
[ "$S0" != 16384 ] && pass "control: the old guard declines the peer's record ($S0)" ||
    fail "control: the old guard gave size $S0 -- the test does not discriminate"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^(ERR|WARN)' <<<"$OUT" && fail "fsck: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -2)" || pass "fsck clean"
ct_exit
