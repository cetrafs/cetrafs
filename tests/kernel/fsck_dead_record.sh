#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck tells a deleted record's stale extents from corruption, and repairs around them safely
#
# A deleted record (nlink=0) whose number has not been reclaimed yet
# still carries the extents of its last life, and those blocks were
# freed by that life's evict: some are free, some belong to other files
# by now, and its extent leaf may itself have been reused. fsck used to
# count those extents as live and report "referenced by more than one
# inode", "marked FREE" and "failed its tail checksum" -- ERR on a
# healthy volume. The kernel's reclaim frees only the number (the leak
# reclaim keeps every block a live record names), so none of it is
# shared data; it is a leftover, and now reported as WARN.
#
#   1. a create that failed after its birth claim (birth_check_fail)
#      leaves such a record; another file takes its blocks. fsck: WARN
#      and exit 0; -r converges; the other file is intact.
#   2. the same with a depth-1 record whose leaf no longer verifies.
#   3. SAFETY: a record whose nlink drifted to 0 while a name still
#      points at it is a live file. fsck must call it ERR, and -r must
#      not free the blocks its unreadable leaf hides: once the leaf is
#      restamped the file reads back byte-exact.
#   4. a number taken by a create stopped before its record write: the
#      bit is set over an all-zero record. WARN, and -r frees it.
#
# The kernel no longer leaves such a record behind -- a freed number's
# record names nothing since evict clears it first -- but a volume
# written before that, or a crash in the middle of it, still can. So 1
# and 2 plant it: the record as it was while the file lived, put back
# over the dead number with nlink 0.
#
# DISCRIMINATION: 1 and 2 fail against the previous fsck (ERR, exit 1).
# 3 fails if the deleted-record walk stops deferring leak repair: the
# first -r then clears the live file's blocks.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/birth_check_fail ] || { skip "birth_check_fail is missing"; ct_exit; }

IPOKE="$(ct_helper inode_block_poke)"
TPOKE="$(ct_helper blk_tail_poke)"
IMG="$(ct_image 560 deadrec)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt deadrec)"
FSCK="$ROOT/userspace/fsck.cetra"

fresh() {
    ct_mkfs_small "$DEV" >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
}
frag() { # <path>: a strided file, one extent per block, so it spills to depth 1
    python3 -I - "$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(30):
    os.pwrite(fd, os.urandom(4096), i * 2 * 4096)
os.fsync(fd); os.close(fd)
PY
}
# failed_create: the next create claims the lowest free number and fails
# after its birth claim, leaving that number allocated under its dead
# record -- what a spurious read error used to do in a churn run.
failed_create() {
    ct_param_set birth_check_fail 1
    if touch "$MNT/doomed_create" 2>/dev/null; then
        ct_param_set birth_check_fail 0
        fail "setup: the create succeeded -- birth_check_fail was not reached"
        ct_exit
    fi
    ct_param_set birth_check_fail 0
}
SBPOKE="$(ct_helper sb_poke)"
rec_at() { # <ino>: the byte offset of its record (one per block)
    echo $((($("$SBPOKE" "$DEV" | sed -n 's/^inode_table_start=//p') + $1 - 1) * 4096))
}
save_rec() { dd if="$IMG" bs=1 skip="$(rec_at "$1")" count=4096 status=none >"$2"; }
# The record of the file's last life, back over its dead number, nlink 0.
plant_dead_rec() { # <ino> <saved>
    dd if="$2" of="$IMG" bs=1 seek="$(rec_at "$1")" count=4096 conv=notrunc,fsync status=none
    "$IPOKE" "$IMG" nlink "$1" 0 >/dev/null
    blockdev --flushbufs "$DEV"
}
check() { # <label>: fsck must exit 0 with no ERR; prints its output
    local rc=0 out
    out="$("$FSCK" "$DEV" 2>&1)" || rc=$?
    if [ "$rc" = 0 ] && ! grep -q '^ERR' <<<"$out"; then
        pass "$1: fsck exits 0, no ERR"
    else
        fail "$1: fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -3)"
    fi
    FSCK_OUT="$out"
}
converge() { # <label>: at most two -r runs reach a fully clean volume
    local r out
    for r in 1 2; do "$FSCK" -r "$DEV" >/dev/null 2>&1 || true; done
    out="$("$FSCK" "$DEV" 2>&1 || true)"
    grep -qE '^(ERR|WARN)' <<<"$out" && fail "$1: after two fsck -r: $(grep -E '^(ERR|WARN)' <<<"$out" | head -2)" ||
        pass "$1: two fsck -r runs leave it clean"
}

# ---------------------------------------------------------------- 1
log "1: a deleted record whose blocks other files took"
fresh
dd if=/dev/urandom of="$MNT/old" bs=4096 count=16 status=none
sync
N="$(stat -c %i "$MNT/old")"
ct_umount "$MNT"
REC="$(ct_tmp deadrec-1)"
save_rec "$N" "$REC"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
rm "$MNT/old"
sync
failed_create
dd if=/dev/urandom of="$MNT/taker" bs=4096 count=64 status=none
SUM="$(sha256sum <"$MNT/taker")"
ct_umount "$MNT"
plant_dead_rec "$N" "$REC"
check "1"
grep -q "inode $N (deleted, not yet reclaimed) still names .* another file now holds" <<<"$FSCK_OUT" &&
    pass "1: set up -- ino $N's stale extents overlap a live file, and fsck says so" ||
    { fail "1: not set up: no stale-overlap WARN for ino $N: $(grep -E '^(ERR|WARN)' <<<"$FSCK_OUT" | head -3)"; ct_exit; }
converge "1"
ct_mount "$DEV" "$MNT"
[ "$(sha256sum <"$MNT/taker")" = "$SUM" ] && pass "1: the live file is intact after the repair" ||
    fail "1: the live file changed across fsck -r"
ct_umount "$MNT"

# ---------------------------------------------------------------- 2
log "2: a deleted record whose extent leaf no longer verifies"
fresh
frag "$MNT/old"
N="$(stat -c %i "$MNT/old")"
[ "$("$IPOKE" "$IMG" extents "$N" | grep -o 'depth=[01]')" = "depth=1" ] ||
    { fail "2: setup: the file did not spill to depth 1"; ct_exit; }
ct_umount "$MNT"
REC="$(ct_tmp deadrec-2)"
save_rec "$N" "$REC"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
rm "$MNT/old"
sync
failed_create
ct_umount "$MNT"
plant_dead_rec "$N" "$REC"
"$TPOKE" "$IMG" leaf "$N" corrupt >/dev/null
check "2"
grep -q "WARN: inode $N's extent leaf .* failed its tail checksum" <<<"$FSCK_OUT" &&
    pass "2: set up -- the dead record's leaf fails, reported as WARN" ||
    { fail "2: not set up: $(grep -E '^(ERR|WARN)' <<<"$FSCK_OUT" | head -3)"; ct_exit; }
converge "2"

# ---------------------------------------------------------------- 3
log "3: a NAMED file whose nlink drifted to 0, with an unreadable leaf"
fresh
frag "$MNT/keep"
N="$(stat -c %i "$MNT/keep")"
SUM="$(sha256sum <"$MNT/keep")"
ct_umount "$MNT"
"$IPOKE" "$IMG" nlink "$N" 0 >/dev/null
"$TPOKE" "$IMG" leaf "$N" corrupt >/dev/null
OUT="$("$FSCK" "$DEV" 2>&1 || true)"
grep -q "^ERR: inode $N has nlink=0 but 1 directory entries name it" <<<"$OUT" &&
    pass "3: fsck reports the named nlink=0 file as ERR" ||
    fail "3: no ERR for the named nlink=0 file: $(grep -E '^(ERR|WARN)' <<<"$OUT" | head -3)"
"$FSCK" -r "$DEV" >/dev/null 2>&1 || true
"$FSCK" -r "$DEV" >/dev/null 2>&1 || true
"$TPOKE" "$IMG" leaf "$N" restamp >/dev/null
blockdev --flushbufs "$DEV"
OUT="$("$FSCK" "$DEV" 2>&1 || true)"
grep -q '^ERR' <<<"$OUT" && fail "3: after -r and the restamp: $(grep '^ERR' <<<"$OUT" | head -3)" ||
    pass "3: after -r and the restamp fsck finds nothing wrong"
ct_mount "$DEV" "$MNT"
# A filler first: any block -r wrongly freed is handed to it, so the
# comparison below sees the damage instead of the old bytes still there.
dd if=/dev/zero of="$MNT/filler" bs=4096 count=256 status=none
sync
echo 3 >/proc/sys/vm/drop_caches
[ "$(sha256sum <"$MNT/keep" 2>/dev/null)" = "$SUM" ] &&
    pass "3: the file reads back byte-exact -- fsck -r freed none of its blocks" ||
    fail "3: the file's content changed: fsck -r freed blocks its unreadable leaf hid"
ct_umount "$MNT"

# ---------------------------------------------------------------- 4
log "4: a number whose record was never written"
fresh
ct_umount "$MNT"
SBPOKE="$(ct_helper sb_poke)"
IBM="$("$SBPOKE" "$DEV" | sed -n 's/^inode_bmap_start=//p')"
N=9
python3 -I - "$IMG" "$IBM" "$N" <<'PY'
import os, sys
img, ibm, ino = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fd = os.open(img, os.O_RDWR)
off = ibm * 4096 + (ino - 1) // 8
b = os.pread(fd, 1, off)[0]
os.pwrite(fd, bytes([b | (1 << ((ino - 1) % 8))]), off)
os.fsync(fd)
PY
blockdev --flushbufs "$DEV"
check "4"
grep -q "WARN: inode $N is marked in use but its record was never written" <<<"$FSCK_OUT" &&
    pass "4: set up -- the bit is set over an all-zero record, reported as an interrupted create" ||
    { fail "4: not set up: $(grep -E '^(ERR|WARN)' <<<"$FSCK_OUT" | head -3)"; ct_exit; }
converge "4"
ct_exit
