#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Does a survivor keep serving a STALE extent tree after a peer wrote the
# file and went away?
#
# Under nofilelock the gate on "may I trust my cached extent tree" used
# to be cetrafs_lock_held_for_write_locally() == "no peer has this file
# open RIGHT NOW". That describes the present and is consulted about the
# past: a peer that wrote the file and CLOSED it is not open, so the
# predicate says "trust your cache" about a cache filled before those
# writes. Reported from production as: node A died, HA moved the VM to
# B, B could not start it at all, A was switched back on and started it
# immediately -- B was mapping the image through a frozen tree while a
# freshly-mounted node read the same file perfectly.
#
# Fixed by cetrafs_inode_t.file_seq, the file-domain twin of dirent_seq.
#
#   ./stale_tree_cache.sh            # must end COHERENT
#   FSI=1 ./stale_tree_cache.sh      # negative control: must end STALE
#
# FSI=1 sets the file_seq_ignore module param, restoring the old
# predicate. Without that run proving the assertion CAN fail, a green
# result here means nothing.
#
# Env: REMOTE, DEV, MNT, RKO as in jreplay_guard.sh. REMOTE is killed.
set -u
REMOTE="${REMOTE:?set REMOTE=<peer node to kill; never this node>}"
DEV="${DEV:?set DEV=<shared LUN, same path on both nodes>}"
MNT="${MNT:-/mnt/ct}"
RKO="${RKO:-/root/cetra-test/cetrafs.ko}"
FSI="${FSI:-0}"
P=/sys/module/cetrafs/parameters
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5"
PD=$(basename "$(readlink -f "$DEV")"); TD="$MNT/staletree"
say(){ echo "[$(date +%T)] $*"; }
die(){ echo "FAIL: $*"; exit 1; }
rsh(){ timeout "${2:-60}" $SSH "$REMOTE" "$1"; }
rwait(){ for _ in $(seq 1 "${1:-90}"); do $SSH -o ConnectTimeout=3 "$REMOTE" true 2>/dev/null && return 0; sleep 2; done; return 1; }

cat > /tmp/stc_io.py <<'PY'
import os, sys
# Interleave two files so the victim's extents are non-contiguous and it
# spills out of the 4 inline slots into external leaf blocks -- the
# blocks whose caching is the whole question.
d, n, tag, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3], 0), sys.argv[4]
fl = os.O_WRONLY | os.O_APPEND | (os.O_CREAT if mode == "create" else 0)
a = os.open(d + "/victim", fl, 0o644); b = os.open(d + "/spacer", fl, 0o644)
for i in range(n):
    os.write(a, bytes([(tag + i) & 0xff]) * 4096); os.fsync(a)
    os.write(b, bytes([(tag + i) ^ 0xff]) * 4096); os.fsync(b)
os.close(a); os.close(b)
PY

rwait 150 || die "$REMOTE unreachable"
# The node carrying -o nofilelock must mount FIRST (cluster-wide mode).
rsh "umount $MNT 2>/dev/null; true" 60; umount "$MNT" 2>/dev/null || true
mount -t cetrafs -o nofilelock "$DEV" "$MNT" || die "local mount failed"
grep -q "file_lock: off" "/proc/fs/cetrafs/$PD/info" || die "cluster is file_lock=ON; this bug needs nofilelock"
rsh "lsmod|grep -q '^cetrafs' || insmod $RKO; mkdir -p $MNT; mount -t cetrafs $DEV $MNT && echo OK" 90 | grep -q OK || die "$REMOTE not mounted"

echo "$FSI" > $P/file_seq_ignore
echo 30 > $P/stale_secs; echo 5 > $P/hb_interval_secs
rsh "echo 5 > $P/hb_interval_secs; echo 1 > $P/alloc_run_blocks"
rm -rf "$TD"; mkdir -p "$TD"; sync
scp -q -o BatchMode=yes /tmp/stc_io.py "$REMOTE:/tmp/stc_io.py"

say "A: create the image (20 fragmented blocks)"
rsh "python3 /tmp/stc_io.py $TD 20 0x10 create && sync" 240 || die "A create failed"

# B reads it NOW, while A is alive -- this is the read that fills B's
# cache. Everything A writes afterwards is what B must still see.
say "B: read the image while A is alive (fills B's cache)"
EARLY=$(filefrag "$TD/victim")
say "B sees: $EARLY"

say "A: append 25 more blocks, close, then die"
rsh "python3 /tmp/stc_io.py $TD 25 0x7E append && sync" 240 || die "A append failed"
TRUTH_A=$(rsh "filefrag $TD/victim" 30); say "A's truth: $TRUTH_A"
rsh "nohup sh -c 'sleep 1; echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger' >/dev/null 2>&1 &" 15
sleep 14

AFTER_MD5=$(md5sum "$TD/victim" | cut -d' ' -f1); AFTER=$(filefrag "$TD/victim")
say "B sees (A gone): $AFTER"

# Ground truth: a cold mount has no cache to be wrong about.
umount "$MNT"; mount -t cetrafs -o nofilelock "$DEV" "$MNT"
TRUTH_MD5=$(md5sum "$TD/victim" | cut -d' ' -f1); TRUTH=$(filefrag "$TD/victim")
say "B sees (cold cache): $TRUTH"
NA=$(echo "$AFTER" | grep -o '[0-9]* extents' | cut -d' ' -f1)
NT=$(echo "$TRUTH" | grep -o '[0-9]* extents' | cut -d' ' -f1)
echo; echo "warm after peer died : $NA extents  md5=$AFTER_MD5"
echo "cold remount         : $NT extents  md5=$TRUTH_MD5"
rm -rf "$TD"; sync; echo 0 > $P/file_seq_ignore

if [ "$AFTER_MD5" = "$TRUTH_MD5" ] && [ "$NA" = "$NT" ]; then
    [ "$FSI" = 1 ] && die "negative control did NOT reproduce the bug -- the assertion is vacuous"
    echo "RESULT: COHERENT -- the survivor saw the peer's committed state without a remount"
else
    [ "$FSI" = 1 ] && { echo "RESULT: STALE as required (negative control)"; exit 0; }
    die "STALE -- the survivor served a cached view a cold mount disagrees with"
fi
