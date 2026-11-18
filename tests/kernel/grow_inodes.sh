#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a grow adds inodes: the inode table chains a segment, live or offline, and every reader follows it (M-36)
#
# The inode count was fixed at mkfs from the formatted size and never
# grew, growfs included: a volume made small and grown to many times its
# size kept its first inode count, and creates failed ENOSPC with the
# volume nearly empty -- reformat to fix (audit 2026-11-15 M-36). The
# table now grows the way the Block Group table does: a grow appends a
# segment (header, bitmap, records) and links it, and inode numbers go
# on where the table ended.
#
#   setup: a volume formatted with mkfs's minimum, 1024 inodes, runs out
#          of them, ENOSPC with the space free;
#   1. a LIVE grow to 1100M with -N 1300 adds inodes: the
#      creates that failed now succeed, at numbers past the old table;
#   2. their data reads back; unlinking files in both segments gives
#      their numbers back (statfs f_ffree), and they are reused;
#   3. after a remount every file reads back, and fsck is clean -- it
#      walks the chain;
#   4. an OFFLINE grow with -N 1600 appends a second segment, linked from the
#      first one's tail: creates reach its numbers, fsck clean;
#   5. a node that has not caught up with a live grow
#      (grow_skip_local_publish) learns the new segment from its
#      heartbeat, and then creates in it;
#   6. a damaged chain is refused, by fsck and by the mount: a segment
#      with no magic, one failing its checksum, a chain that loops.
#
# DISCRIMINATION: a growfs that adds no inodes fails 1, 2, 4 and 5: the
# creates still fail ENOSPC. With cetrafs_seg_read()'s magic and
# checksum checks skipped for the inode chain, 6's mount fails on the
# magic and crc cases (a loop is still refused by the numbering).
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
SEGPOKE="$(ct_helper seg_poke)"

IMG="$(ct_big_image 2900 growino)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt growino)"
ct_track mnt "$MNT"
ct_param_set hb_interval_secs 2
ct_param_set grow_skip_local_publish 0
ct_param_set layout_refresh_hb_off 0

info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
# <prefix> <max>: create files of one stamped block until ENOSPC; prints
# how many were made. Any other error fails the run.
create() {
    python3 -I - "$MNT" "$1" "$2" <<'PY'
import errno, os, sys
mnt, pre, mx = sys.argv[1], sys.argv[2], int(sys.argv[3])
n = 0
while n < mx:
    p = "%s/%s%d" % (mnt, pre, n)
    try:
        fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except OSError as e:
        if e.errno == errno.ENOSPC:
            break
        raise
    os.write(fd, (b"%s%d " % (pre.encode(), n)) * 64)
    os.fsync(fd)
    os.close(fd)
    n += 1
print(n, flush=True)
PY
}
# <prefix> <n>: every file reads back what create() wrote
check() {
    python3 -I - "$MNT" "$1" "$2" <<'PY'
import os, sys
mnt, pre, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
bad = [i for i in range(n) if open("%s/%s%d" % (mnt, pre, i), "rb").read() != (b"%s%d " % (pre.encode(), i)) * 64]
print("ok" if not bad else "BAD %d first %d" % (len(bad), bad[0]), flush=True)
PY
}
maxino() { stat -c %i "$MNT"/* | sort -n | tail -1; }

ct_mkfs "$DEV" -s 600M -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

A="$(create a 2000)"
[ "$A" -ge 1000 ] && [ "$A" -lt 1024 ] && [ "$(df --output=avail -B1M "$MNT" | tail -1 | tr -d ' ')" -gt 400 ] &&
    pass "setup: $A creates used every inode (1024), ENOSPC with the space free" ||
    { fail "setup: $A creates before ENOSPC, or the volume is not nearly empty -- not the volume this suite needs"; ct_exit; }

log "1: a live grow to 1100M, -N 1300"
GEN0="$(info layout_gen)"
OUT="$(ct_growfs "$DEV" -s 1100M -N 1300 2>&1)" || { fail "1: growfs: $OUT"; ct_exit; }
grep -q 'completed live' <<<"$OUT" || fail "1: growfs did not grow the mounted volume live: $OUT"
N1="$(info inodes_count)"
[ "$N1" = 1300 ] && [ "$(info layout_gen)" -gt "$GEN0" ] && pass "1: the table grew to $N1 inodes, live" ||
    fail "1: the volume has $N1 inodes after the grow (layout_gen $GEN0 -> $(info layout_gen))"
B="$(create b 2000)"
[ "$B" -ge 250 ] && pass "1: $B creates that the full table refused now succeed" ||
    fail "1: only $B creates succeed after the grow -- the grow added no usable inode"
[ "$(maxino)" -gt 1024 ] && pass "1: new files take numbers past the old table (up to $(maxino))" ||
    fail "1: no file has a number past 1024 -- the new segment was never used"

R="$(check a "$A") $(check b "$B")"
[ "$R" = "ok ok" ] && pass "2: every file reads back" || fail "2: $R"
F0="$(stat -f -c %d "$MNT")"
rm -f "$MNT/a3" "$MNT/b$((B - 1))"
sync
sleep 11 # statfs recounts the inode bitmap at most every 10 s
F1="$(stat -f -c %d "$MNT")"
[ "$((F1 - F0))" -eq 2 ] && pass "2: unlinking a file in each segment gave both numbers back (f_ffree $F0 -> $F1)" ||
    fail "2: f_ffree went $F0 -> $F1 after unlinking two files"
C="$(create c 2)"
[ "$C" = 2 ] && pass "2: the freed numbers are used again" || fail "2: $C of 2 creates succeeded"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR|leaked' <<<"$OUT" && fail "3: fsck after the live grow: $(grep -E '^ERR|leaked' <<<"$OUT" | head -3)" ||
    pass "3: fsck is clean after the live grow"
ct_mount "$DEV" "$MNT"
R="$(check a 3) $(check b $((B - 1)))"
[ "$R" = "ok ok" ] && pass "3: after a remount every file reads back" || fail "3: $R"
ct_umount "$MNT"

log "4: an offline grow to 1600M, -N 1600"
OUT="$(ct_growfs "$DEV" -s 1600M -N 1600 2>&1)" || { fail "4: growfs: $OUT"; ct_exit; }
ct_mount "$DEV" "$MNT"
[ "$(info inodes_count)" = 1600 ] && pass "4: the table has 1600 inodes" ||
    fail "4: the table has $(info inodes_count) inodes after -N 1600"
D="$(create d 2000)"
[ "$(maxino)" -gt "$N1" ] && pass "4: $D creates reach the second segment (up to $(maxino), past $N1)" ||
    fail "4: no number past $N1 after $D creates"
R="$(check d "$D")"
[ "$R" = ok ] && pass "4: they read back" || fail "4: $R"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR|leaked' <<<"$OUT" && fail "4: fsck: $(grep -E '^ERR|leaked' <<<"$OUT" | head -3)" ||
    pass "4: fsck is clean with two appended segments"

log "5: a node behind a live grow catches up by heartbeat"
ct_mount "$DEV" "$MNT"
rm -f "$MNT"/d*
E0="$(create e 2000)"
GEN1="$(info layout_gen)"
ct_param_set grow_skip_local_publish 1
OUT="$(ct_growfs "$DEV" -s 2100M -N 1900 2>&1)" || { fail "5: growfs: $OUT"; ct_exit; }
ct_param_set grow_skip_local_publish 0
for i in $(seq 1 40); do
    [ "$(info layout_gen)" -gt "$GEN1" ] && break
    sleep 0.5
done
[ "$(info inodes_count)" = 1900 ] && pass "5: the heartbeat brought this node to 1900 inodes" ||
    fail "5: this node knows $(info inodes_count) inodes after the grow it did not publish"
E="$(create f 2000)"
[ "$(maxino)" -gt 1600 ] && pass "5: $E creates reach the segment it caught up with (up to $(maxino))" ||
    fail "5: no number past 1600 after $E creates (E0=$E0)"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR|leaked' <<<"$OUT" && fail "5: fsck: $(grep -E '^ERR|leaked' <<<"$OUT" | head -3)" ||
    pass "5: fsck is clean with three appended segments"

log "6: a damaged inode chain is refused"
# Each injection rewrites one header block, the chain's head or its
# tail; both are kept and put back between cases.
DUMP="$(SEG_POKE_CHAIN=inode "$SEGPOKE" "$DEV" dump)"
HEAD="$(sed -n 's/^head=\([0-9]*\) .*/\1/p' <<<"$DUMP")"
TAIL="$(sed -n 's/.* tail=\([0-9]*\) .*/\1/p' <<<"$DUMP")"
[ -n "$HEAD" ] && [ -n "$TAIL" ] && [ "$HEAD" != "$TAIL" ] ||
    { fail "6 setup: the inode chain is not two or more segments: $DUMP"; ct_exit; }
SAVE="$(ct_tmp growino-save)"
keep() { dd if="$DEV" of="$SAVE.$1" bs=4096 skip="$1" count=1 iflag=direct status=none; }
back() { dd if="$SAVE.$1" of="$DEV" bs=4096 seek="$1" count=1 oflag=direct conv=notrunc status=none; }
keep "$HEAD"
keep "$TAIL"
for how in magic crc loop; do
    SEG_POKE_CHAIN=inode "$SEGPOKE" "$DEV" "$how" >/dev/null || { fail "6 setup: seg_poke $how failed"; continue; }
    OUT="$(ct_fsck "$DEV" 2>&1 || true)"
    grep -q '^ERR: inode table' <<<"$OUT" && pass "6: fsck reports the inode chain ($how): $(grep '^ERR: inode table' <<<"$OUT" | head -1)" ||
        fail "6: fsck does not report a damaged inode chain ($how): $(tail -2 <<<"$OUT" | tr '\n' ' ')"
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        fail "6: a volume whose inode chain is damaged ($how) mounted"
        umount "$MNT"
    else
        pass "6: the mount refuses the damaged inode chain ($how)"
    fi
    back "$HEAD"
    back "$TAIL"
done
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "6: the volume put back does not check clean: $(grep '^ERR' <<<"$OUT" | head -2)" ||
    pass "6: put back, the volume checks clean"
ct_exit
