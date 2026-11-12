#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a held-back leaf batch's entries never reach the device before what they name
#
# A regular file's extent-leaf edits are held back (leafdefer.c) and
# written at the next durability boundary through the journal, in one
# batch (cetrafs_journal_write_deferred()). The entries name data blocks
# and the bitmap bits that allocated them, so step 0 writes the bitmaps
# and FLUSHES the cache before the first entry: an entry that is durable
# while what it names is still in a volatile cache is, after a power
# cut, a replayed leaf pointing at blocks that hold nothing (C2).
#
# A loop device completes every write durably and in order, so no mount
# or fsck can see this order -- leaf_boundary_journaled shows the leaf
# went through the journal, not that the flush sits before it. This
# reads the order out of a dm-log-writes recording instead: from a mark
# placed just before the boundary, at the first write into the journal
# area, how many data-region writes (file data, and the bitmaps, which
# live in the Block Groups) were issued since the last FLUSH? It must
# be none.
#
# The workload: a file past its four inline extents (so its tree has a
# leaf), then O_DIRECT writes into holes -- new extents, leaf edits held
# back -- and an fsync, the boundary that writes the batch.
#
# DISCRIMINATION: built in. journal_batch_skip_flush drops step 0's
# flush, and the same recording must then show data-region writes
# pending at the first entry; if it does not, this suite proves nothing.
#
# Opt-in like the rest of tests/crash (make check-crash).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
modprobe dm-log-writes 2>/dev/null || true
command -v dmsetup >/dev/null || { skip "dmsetup not found"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/journal_batch_skip_flush ] || { skip "journal_batch_skip_flush is missing"; ct_exit; }

REPLAY="$CT_BUILD/replay-log"
RESTAMP="$CT_BUILD/fuzz_restamp"
mkdir -p "$CT_BUILD"
if [ ! -x "$REPLAY" ] || [ "$ROOT/tests/crash/replay-log.c" -nt "$REPLAY" ]; then
    cc -O2 -std=gnu99 -Wall -o "$REPLAY" "$ROOT/tests/crash/replay-log.c" || { fail "replay-log build failed"; ct_exit; }
fi
if [ ! -x "$RESTAMP" ] || [ "$ROOT/tests/fuzz/fuzz_restamp.c" -nt "$RESTAMP" ] || [ "$ROOT/include/cetrafs.h" -nt "$RESTAMP" ]; then
    cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
        -o "$RESTAMP" "$ROOT/tests/fuzz/fuzz_restamp.c" || { fail "fuzz_restamp build failed"; ct_exit; }
fi
ct_param_set auto_defrag 0
ct_param_set scrub 0

SZ_MB=560
SECTORS=$((SZ_MB * 1024 * 1024 / 512))
MNT="$(ct_mnt lbatch)"
ct_track mnt "$MNT"

# record <skip_flush>: the workload through dm-log-writes; prints the
# order check's answer.
record() {
    local skip="$1" data log dm lw
    data="$(ct_loop "$(ct_image "$SZ_MB" "lbatch-d$skip")")"
    log="$(ct_loop "$(ct_image 512 "lbatch-l$skip")")"
    dm="lbatch_${skip}_$$"
    dmsetup create "$dm" --table "0 $SECTORS log-writes $data $log"
    ct_track dm "$dm"
    lw="/dev/mapper/$dm"
    ct_mkfs "$lw" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$lw" "$MNT"
    python3 -I - "$MNT/vm" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)
for i in range(8):                       # eight extents: past the four inline slots
    os.pwrite(fd, b"D" * 4096, i * 2 * 4096)
    os.fsync(fd)
os.ftruncate(fd, 1024 * 4096)
os.fsync(fd)
os.close(fd)
PY
    sync
    ct_param_set journal_batch_skip_flush "$skip"
    dmsetup message "$dm" 0 mark boundary
    python3 -I - "$MNT/vm" <<'PY'
import mmap, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
buf.write(b"N" * 4096)
for i in range(16):                      # sixteen new extents, in holes
    os.pwrite(fd, buf, (100 + i * 3) * 4096)
os.fsync(fd)                             # the boundary: the batch goes out
os.close(fd)
PY
    ct_param_set journal_batch_skip_flush 0
    ct_umount "$MNT"
    dmsetup remove "$dm"
    blockdev --flushbufs "$log"
    local bg_regions_start=0 node_journal_start=0 node_journal_blocks=0 node_table_count=0
    eval "$("$RESTAMP" "$data" info | awk -F= '/^(bg_regions_start|node_journal_start|node_journal_blocks|node_table_count)=/{print $1"="$2}')"
    "$REPLAY" --log "$log" --check-flushed-after-mark boundary --data-start "$bg_regions_start" \
        --journal-start "$node_journal_start" --journal-blocks $((node_table_count * node_journal_blocks)) || true
}

OUT="$(record 1)"
log "control (step 0's flush skipped): $OUT"
case "$OUT" in
pending=0\ *) fail "setup: with the flush skipped nothing was pending at the first entry ($OUT) -- this suite proves nothing"; ct_exit ;;
pending=*) pass "control: without the flush, data-region writes are still volatile when the first entry is written ($OUT)" ;;
*) fail "setup: the recording has no journal write after the boundary ($OUT) -- the batch never went through the journal"; ct_exit ;;
esac

OUT="$(record 0)"
log "as shipped: $OUT"
case "$OUT" in
pending=0\ *) pass "every data and bitmap write the batch names was flushed before its first entry" ;;
*) fail "the batch's first entry was written with data-region writes still volatile: $OUT" ;;
esac
ct_exit
