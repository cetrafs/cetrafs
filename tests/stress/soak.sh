#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mixed-workload soak with a full fsck after every round -- runnable unattended (slow, opt-in)
#
# mount_test.sh proves specific behaviours; this hammers the structure
# with the operations that actually mutate it and then asks fsck whether
# anything broke. Since fsck gained its content and namespace passes it
# can name real damage -- cross-file block overlap, blocks in use but
# marked free, leaked blocks, unreachable inodes, nlink mismatches --
# so a round that comes back clean means something.
#
# Usage (from the repository root):
#   make soak ROUNDS=200 SOAK_MAX_SECS=7200
#   tests/stress/soak.sh [rounds]            (default 20)
#
# Unattended: no prompts, no terminal needed. It stops starting new rounds
# at the deadline, finishes the round it is in, writes a report, and exits:
#   0  every round that ran was clean and the run reached its end
#      (the round count, or the deadline)
#   1  at least one round was ANOMALOUS (an operation failed, or fsck
#      reported a problem) or ABORTED (mkfs or mount failed); the failing
#      image is kept as mix-fail-N.img beside the report
#   2  a precondition failed (module not loaded, scratch directory unusable);
#      nothing ran, so there is no result
#
# Environment:
#   SOAK_MAX_SECS  stop starting rounds after this many seconds (0 = no
#                  limit, the default). Checked between rounds only.
#   SOAK_DIR       scratch directory: images, the mountpoint, mkfs logs and
#                  the report (default ${CT_BIG_DIR:-/root}/cetrafs-soak).
#                  Not /tmp: a 700 MiB image per round does not fit a tmpfs.
#   SOAK_REPORT    the report file (default $SOAK_DIR/report.txt). One line
#                  per round, then a SUMMARY line; the file is rewritten
#                  from the start on every run.
#   SOAK_IMG_MB    image size per round (default 700). Too small for mkfs
#                  is how the abort path is exercised on purpose.
#   SOAK_INJECT_FSCK=1  NEGATIVE CONTROL: after each round's operations,
#                  overwrite the Zone Group table on the unmounted image
#                  before fsck, so every round is an anomaly. Proves the
#                  exit status and the report, nothing else.
#
# Scheduling it is the operator's job, and nothing here installs a unit:
# see tests/README.md, "Unattended soak", for a cron entry and the
# systemd-timer equivalent.
#
# Needs the module already loaded; it deliberately does NOT insmod, so it
# can be pointed at whatever build you want to exercise. Every step that
# could silently no-op (mkfs, mount) is checked -- a soak that passes
# because it never touched the filesystem is worse than no soak.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROUNDS="${1:-20}"
MAX_SECS="${SOAK_MAX_SECS:-0}"
DIR="${SOAK_DIR:-${CT_BIG_DIR:-/root}/cetrafs-soak}"
REPORT="${SOAK_REPORT:-$DIR/report.txt}"
IMG="$DIR/mix.img"
MNT="$DIR/mixmnt"
MKFS_LOG="$DIR/mkfs.log"
IMG_MB="${SOAK_IMG_MB:-700}"
LOOP=""

case "$ROUNDS$MAX_SECS" in
*[!0-9]*)
    echo "soak: ROUNDS and SOAK_MAX_SECS must be whole numbers" >&2
    exit 2
    ;;
esac
if ! lsmod | grep -q '^cetrafs '; then
    echo "soak: cetrafs module not loaded -- nothing was run" >&2
    exit 2
fi
mkdir -p "$DIR" "$MNT" 2>/dev/null || {
    echo "soak: cannot create scratch directory $DIR" >&2
    exit 2
}
: >"$REPORT" || {
    echo "soak: cannot write report $REPORT" >&2
    exit 2
}

say() {
    echo "$*"
    echo "$*" >>"$REPORT"
}

# Whatever happens -- abort, deadline, a signal -- the loop device and the
# mount go, so an unattended run never leaves a mount behind for the next.
cleanup() {
    if grep -q " $MNT cetrafs " /proc/self/mounts 2>/dev/null; then
        umount "$MNT" 2>/dev/null || true
    fi
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" 2>/dev/null || true
    fi
    rm -f "$IMG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

START=$(date +%s)
CLEAN=0
ANOM=0
ABORTED=0
RAN=0
STOPPED_AT_DEADLINE=0
say "soak start $(date -u +%Y-%m-%dT%H:%M:%SZ) rounds=$ROUNDS max_secs=$MAX_SECS dir=$DIR"

for r in $(seq 1 "$ROUNDS"); do
    if [ "$MAX_SECS" -gt 0 ] && [ $(($(date +%s) - START)) -ge "$MAX_SECS" ]; then
        STOPPED_AT_DEADLINE=1
        say "deadline reached after $RAN round(s) -- not starting round $r"
        break
    fi
    RAN=$((RAN + 1))
    rm -f "$IMG"
    truncate -s "${IMG_MB}M" "$IMG"
    LOOP=$(losetup --find --show "$IMG") || {
        say "round $r: ABORTED (no loop device)"
        ABORTED=$((ABORTED + 1))
        break
    }
    if ! "$ROOT/userspace/mkfs.cetra" "$LOOP" -z 1 -b 512 -J 1 -M 4 -N 3000 -f >"$MKFS_LOG" 2>&1; then
        say "round $r: ABORTED mkfs failed: $(tail -1 "$MKFS_LOG")"
        ABORTED=$((ABORTED + 1))
        losetup -d "$LOOP" 2>/dev/null
        LOOP=""
        break
    fi
    if ! mount -t cetrafs "$LOOP" "$MNT" 2>/dev/null || ! grep -q " $MNT cetrafs " /proc/self/mounts; then
        say "round $r: ABORTED mount failed"
        ABORTED=$((ABORTED + 1))
        losetup -d "$LOOP" 2>/dev/null
        LOOP=""
        break
    fi
    ERRS=0
    mkdir -p $MNT/a/b/c $MNT/z 2>/dev/null || ERRS=$((ERRS+1))
    # 1. grow a directory well past its inline extents
    for i in $(seq 1 120); do : > $MNT/a/f$i 2>/dev/null || ERRS=$((ERRS+1)); done
    # 2. files with data, then truncate and punch holes
    for i in $(seq 1 25); do
        dd if=/dev/zero of=$MNT/a/b/d$i bs=4096 count=$((i%9+1)) status=none 2>/dev/null || ERRS=$((ERRS+1))
    done
    for i in $(seq 1 10); do truncate -s $((i*1024)) $MNT/a/b/d$i 2>/dev/null || ERRS=$((ERRS+1)); done
    for i in $(seq 11 18); do
        fallocate -p -o 4096 -l 4096 $MNT/a/b/d$i 2>/dev/null || true
    done
    # 3. hardlinks, then drop some
    for i in $(seq 1 15); do ln $MNT/a/f$i $MNT/z/l$i 2>/dev/null || ERRS=$((ERRS+1)); done
    for i in $(seq 1 7); do rm -f $MNT/z/l$i 2>/dev/null || ERRS=$((ERRS+1)); done
    # 4. renames, within and across directories
    for i in $(seq 20 40); do mv $MNT/a/f$i $MNT/a/b/c/r$i 2>/dev/null || ERRS=$((ERRS+1)); done
    for i in $(seq 41 55); do mv $MNT/a/f$i $MNT/a/f$i.ren 2>/dev/null || ERRS=$((ERRS+1)); done
    # 5. xattrs
    for i in $(seq 1 12); do
        python3 -c "import os,sys; os.setxattr(sys.argv[1],'user.k%d'%$i,b'v'*$i)" $MNT/a/b/d$i 2>/dev/null || ERRS=$((ERRS+1))
    done
    # 6. delete a swathe, including a whole subtree
    for i in $(seq 56 120); do rm -f $MNT/a/f$i 2>/dev/null || ERRS=$((ERRS+1)); done
    rm -rf $MNT/a/b/c 2>/dev/null || ERRS=$((ERRS+1))
    sync
    umount "$MNT"
    if [ "${SOAK_INJECT_FSCK:-0}" = 1 ]; then
        dd if=/dev/urandom of="$LOOP" bs=4096 count=1 seek=1 conv=notrunc status=none 2>/dev/null
        blockdev --flushbufs "$LOOP" 2>/dev/null || true
    fi
    FSCK_RC=0
    FSCK="$("$ROOT/userspace/fsck.cetra" "$LOOP" 2>&1)" || FSCK_RC=$?
    losetup -d "$LOOP" 2>/dev/null
    LOOP=""
    PROBLEM=0
    grep -q "problem" <<<"$FSCK" && PROBLEM=1
    if [ "$ERRS" != "0" ] || [ "$FSCK_RC" != "0" ] || [ "$PROBLEM" = 1 ]; then
        ANOM=$((ANOM + 1))
        say "round $r: ANOMALY op_errors=$ERRS fsck_rc=$FSCK_RC"
        grep -E "ERR|WARN|problem" <<<"$FSCK" | head -6 | sed 's/^/    /' | tee -a "$REPORT"
        cp "$IMG" "$DIR/mix-fail-$r.img" 2>/dev/null
    else
        CONTENT="$(grep -oE 'content: [^,]+' <<<"$FSCK" | head -1)"
        CLEAN=$((CLEAN + 1))
        say "round $r: clean  (${CONTENT:-content: ?})"
    fi
    rm -f "$IMG"
done

ELAPSED=$(($(date +%s) - START))
if [ "$ABORTED" -gt 0 ] || [ "$ANOM" -gt 0 ]; then
    VERDICT=FAIL
else
    VERDICT=PASS
fi
say "SUMMARY verdict=$VERDICT rounds_run=$RAN clean=$CLEAN anomalous=$ANOM aborted=$ABORTED deadline_hit=$STOPPED_AT_DEADLINE elapsed_s=$ELAPSED"
if [ "$VERDICT" = FAIL ]; then
    say "failing images, if any, are in $DIR (mix-fail-N.img)"
    exit 1
fi
exit 0
