#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Two-node proof of the journal replay guard (cetrafs_journal_header_t.
# prev_checksum). The real shape of the bug it closes:
#
#   a node dies mid-write under `nofilelock`, HA restarts the VM on a
#   peer, the peer legitimately rewrites the same extent leaf, and the
#   heartbeat sweep then replays the dead node's entry OVER it. The
#   extent map silently reverts to a valid, CRC-correct, wrong state;
#   fsck is clean and only the guest's disk is corrupt.
#
# This needs a genuine hard kill of a mounted node, which the ctest Go
# harness has no primitive for -- hence a script rather than a scenario.
# It drives two machines over ssh and kills the remote one with sysrq-b
# (an immediate reboot, no flush: the closest thing to pulling power).
#
#   ./jreplay_guard.sh corrupt    # negative control: guard OFF, must CORRUPT
#   ./jreplay_guard.sh intact     # guard ON, peer took over, must stay INTACT
#   ./jreplay_guard.sh repair     # guard ON, genuine lost write, must REPAIR
#
# All three are required. "intact" alone would also pass against a build
# that had simply stopped replaying anything, which is why "repair" is
# not optional, and "corrupt" is what proves the assertions can fail.
#
# Env: REMOTE (node to kill), DEV (shared LUN, same path both sides),
#      MNT, RKO (module path on the remote). The LOCAL node is the one
#      you run this on and is never killed.
#
# Two timing requirements, both real deployment concerns:
#   - the local node must notice the death BEFORE any other cluster
#     member does, or some other node performs the replay and the run
#     says nothing about this build -> stale_secs is set low here.
#   - the killed node must NOT come back and mount before the replay,
#     or it replays its own area at mount first.
set -u
REMOTE="${REMOTE:?set REMOTE=<peer node to kill; never this node>}"
DEV="${DEV:?set DEV=<shared LUN, same path on both nodes>}"
MNT="${MNT:-/mnt/ct}"
RKO="${RKO:-/root/cetra-test/cetrafs.ko}"
MODE="${1:-intact}"
P=/sys/module/cetrafs/parameters
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5"
PD=$(basename "$(readlink -f "$DEV")")
TD="$MNT/jreplay-$MODE"
say(){ echo "[$(date +%T)] $*"; }
die(){ echo "FAIL: $*"; exit 1; }
rsh(){ timeout "${2:-60}" $SSH "$REMOTE" "$1"; }
rwait(){ for _ in $(seq 1 "${1:-90}"); do $SSH -o ConnectTimeout=3 "$REMOTE" true 2>/dev/null && return 0; sleep 2; done; return 1; }
ctr(){ sed -n "s/^$1: //p" "/proc/fs/cetrafs/$PD/info"; }

case "$MODE" in corrupt|intact|repair) ;; *) die "mode must be corrupt|intact|repair" ;; esac

cat > /tmp/jrg_io.py <<'PY'
import os, sys
# DIRECTORY operations, not file writes.
#
# Regular-file extent leaves stopped being journalled: a
# regular file republishes its leaf at the next durability boundary, so
# journalling cost three device cache flushes per 4 KiB guest write for
# nothing. That also removed the ORIGINAL corruption vector outright --
# a dead node's journal can no longer carry an extent leaf to replay
# over a peer's newer one.
#
# Dirent and xattr blocks ARE still journalled, because a directory has
# no close and no fsync to republish at. So that is where the replay
# guard still has to be proven, and it is what this drives.
d, n, tag, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
os.makedirs(d, exist_ok=True)
for i in range(n):
    p = "%s/%s-%05d" % (d, tag, i)
    if mode == "create":
        open(p, "w").close()
    else:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
PY

rwait 150 || die "$REMOTE unreachable"

# ORDER MATTERS. The file-lock mode is cluster-wide and set by whichever
# node mounts while no other is mounted; every later mounter inherits it
# and a conflicting -o is REFUSED. So the node carrying -o nofilelock --
# this one -- has to mount first, with the remote unmounted. Getting
# this backwards just produces a file_lock=on cluster and a mount
# refused with -EINVAL.
rsh "umount $MNT 2>/dev/null; true" 60
umount "$MNT" 2>/dev/null || true
mount -t cetrafs -o nofilelock "$DEV" "$MNT" || die "local mount failed"
if ! grep -q "file_lock: off" "/proc/fs/cetrafs/$PD/info"; then
    die "cluster is in file_lock=ON and this bug only exists under nofilelock.
     Some OTHER node established it -- check /proc/fs/cetrafs/$PD/cluster for a
     row with stale=no that is not us. Stop that node (or let it unmount) and
     re-run; this script will not unmount somebody else's mount for you."
fi
rsh "lsmod | grep -q '^cetrafs' || insmod $RKO; mkdir -p $MNT; mountpoint -q $MNT || mount -t cetrafs $DEV $MNT; mountpoint -q $MNT && echo OK" 90 | grep -q OK || die "$REMOTE not mounted"

echo 30 > $P/stale_secs; echo 5 > $P/hb_interval_secs
echo 0 > $P/journal_skip_consume; echo 0 > $P/journal_skip_target_write
[ "$MODE" = corrupt ] && echo 1 > $P/journal_ignore_guard || echo 0 > $P/journal_ignore_guard
rsh "echo 5 > $P/hb_interval_secs; echo 1 > $P/alloc_run_blocks; echo 0 > $P/journal_skip_consume; echo 0 > $P/journal_skip_target_write"
scp -q -o BatchMode=yes /tmp/jrg_io.py "$REMOTE:/tmp/jrg_io.py"
rm -rf "$TD"; mkdir -p "$TD"; sync

say "$REMOTE: populating a directory (dirent blocks are journalled)"
rsh "python3 /tmp/jrg_io.py $TD 400 a create && sync" 240 || die "remote build failed"

if [ "$MODE" = repair ]; then
    # Crash between the journal commit and the in-place write: the entry
    # is live and the target still holds its PRE-image, so replay must
    # apply it. Exactly ONE un-landed write per block -- more than one
    # would have every entry computed from the same pre-image, a fan no
    # real crash produces.
    say "$REMOTE: journalling WITHOUT writing the target (one entry per block)"
    rsh "echo 1 > $P/journal_skip_consume; echo 1 > $P/journal_skip_target_write; python3 /tmp/jrg_io.py $TD 1 b create && sync" 120 || die "injected append failed"
else
    # Entries left live with their targets already written: the state a
    # crash in the consume window leaves behind.
    say "$REMOTE: leaving journal entries live, then growing the file"
    rsh "echo 1 > $P/journal_skip_consume; python3 /tmp/jrg_io.py $TD 20 b create && sync" 240 || die "injected append failed"
fi

say "$REMOTE: sysrq-b (immediate reboot, no flush)"
rsh "nohup sh -c 'sleep 1; echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger' >/dev/null 2>&1 &" 15
sleep 12
$SSH -o ConnectTimeout=3 "$REMOTE" true 2>/dev/null && echo "WARNING: $REMOTE still answering"

A0=$(ctr journal_replay_applied); F0=$(ctr journal_replay_refused); R0=$(ctr journal_replays)
sync; echo 3 > /proc/sys/vm/drop_caches
MD0=$(ls "$TD" | sort | md5sum | cut -d" " -f1); FF0=$(ls "$TD" | wc -l)
say "local before: $FF0 names, md5=$MD0"

if [ "$MODE" != repair ]; then
    say "local: taking the directory over and adding names (what HA's new host does)"
    python3 /tmp/jrg_io.py "$TD" 15 c create || die "local append failed"
    sync; echo 3 > /proc/sys/vm/drop_caches
    MD0=$(ls "$TD" | sort | md5sum | cut -d" " -f1); FF0=$(ls "$TD" | wc -l)
    say "local after takeover: $FF0 names, md5=$MD0"
fi

say "waiting for the local node to replay the dead node's journal"
for _ in $(seq 1 45); do [ "$(ctr journal_replays)" -gt "$R0" ] && break; sleep 3; done
[ "$(ctr journal_replays)" -gt "$R0" ] || die "no replay within 135s (another node may have taken it: check stale_secs)"
sleep 3
A1=$(ctr journal_replay_applied); F1=$(ctr journal_replay_refused)
sync; echo 3 > /proc/sys/vm/drop_caches
MD1=$(ls "$TD" | sort | md5sum | cut -d" " -f1); FF1=$(ls "$TD" | wc -l)
say "local after replay: $FF1 names, md5=$MD1"
echo "applied $A0->$A1   refused $F0->$F1"

N0=$FF0
N1=$FF1
case "$MODE" in
corrupt)
    [ "$MD1" != "$MD0" ] || die "negative control did NOT corrupt -- every other assertion here is vacuous"
    echo "RESULT: CORRUPTED as required (md5 $MD0 -> $MD1, names $N0 -> $N1)" ;;
intact)
    [ "$MD1" = "$MD0" ] || die "replay clobbered the peer's newer write (md5 $MD0 -> $MD1)"
    [ "$FF1" = "$FF0" ] || die "directory changed across the replay ($N0 -> $N1)"
    [ "$((F1-F0))" -gt 0 ] || die "nothing was refused: the entries never reached the guard"
    echo "RESULT: INTACT ($((F1-F0)) entries refused, directory unchanged)" ;;
repair)
    [ "$((A1-A0))" -gt 0 ] || die "replay applied NOTHING: the guard has disabled redo"
    [ "$((F1-F0))" -eq 0 ] || die "replay refused $((F1-F0)) entries nobody else had touched"
    [ "$N1" -gt "$N0" ] || die "name count did not grow ($N0 -> $N1): the repair did not land"
    echo "RESULT: REPAIRED ($((A1-A0)) applied, 0 refused, names $N0 -> $N1)" ;;
esac
rm -rf "$TD"; sync
