#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a split of a full leaf no longer writes a journal batch of its own
#
# Random 4 KiB writes into a preallocated image convert one block out of
# the preallocated extent each, and once the leaf holding it is full each
# conversion splits it: the extent shrinks there and the rest moves to
# another leaf. The device must never hold the destination without the
# source, and while a boundary went to the journal in chunks of 16 --
# atomic only within a chunk -- every such split wrote everything held
# back at once: a whole batch, three cache flushes, per guest write
# (cetrafs_convert_source_durable()). A boundary is now ONE batch, every
# entry durable before any target, and an inode's held-back set is kept
# under half the journal so it always fits (cetrafs_deferred_capped()).
#
#  1. the workload with convert_flush_always=1 -- the old behaviour, the
#     control -- writes the source at many splits: proof the workload
#     reaches them (at least 20), and the flush count it costs;
#  2. the same workload now writes none, and issues at least two fewer
#     cache flushes per split it skipped; the data reads back and fsck is clean;
#  3. a small journal (journal_slots_max=8, so a cap of 4) makes the cap
#     engage: the held-back set is written early, more than once, and the
#     result still reads back and checks clean.
#  4. the batch is atomic past 16 blocks: an image with many leaves, a
#     fsync whose held-back set is larger than the old 16-entry chunk,
#     stopped the moment its entries are durable
#     (journal_batch_crash_before_targets). After the remount's replay
#     every write the fsync covered reads back. With 16-entry chunks the
#     stop came after the FIRST chunk, and the writes mapped by the rest
#     were gone.
#
# The crash orders themselves are leaf_batch_order.sh (entries before
# targets) and convert_leaf_order.sh (no order leaves the moved blocks
# named twice); this suite says what the change costs and that it runs.
# A loop device cannot say what a flush costs on a SAN -- counted here,
# measured on the deployment LUN.
# ct-timeout: 600
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 1200 cvsplit)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt cvsplit)"
ct_track mnt "$MNT"
ct_param_set convert_flush_always 0
# This suite is about the APPEND a full leaf's convert falls back to; a
# full leaf is split by range first now (cetrafs_tree_split_leaf(),
# prealloc_random_lookup.sh), so the fallback is reached only with the
# split off.
ct_param_set leaf_split_off 1
ct_param_set journal_slots_max 0
ct_param_set journal_batch_crash_before_targets 0
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
flushes() { awk -v d="$(basename "$DEV")" '$3 == d { print $19 + 0 }' /proc/diskstats; }

# <n>: fallocate 256 MiB, then n random 4 KiB writes, one fd, fsync at the end
workload() {
    python3 - "$MNT/img" "$1" <<'PY'
import os, sys, random
path, n = sys.argv[1], int(sys.argv[2])
fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
os.posix_fallocate(fd, 0, 256 << 20)
random.seed(7)
offs = random.sample(range(0, (256 << 20) // 4096), n)
for i, b in enumerate(offs):
    os.pwrite(fd, (b"%08d" % b) * 512, b * 4096)
os.fsync(fd)
os.close(fd)
fd = os.open(path, os.O_RDONLY)
bad = sum(1 for b in offs if os.pread(fd, 8, b * 4096) != b"%08d" % b)
os.close(fd)
print(bad)
PY
}

# <tag>: run it on a fresh volume; sets SRC, FL, BAD
run() {
    ct_mkfs "$DEV" -s 1G -z 1 -b 512 -J 2 -M 4 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    local s0 f0 c0
    s0="$(info convert_source_flushes)"; f0="$(flushes)"; c0="$(info deferred_cap_flushes)"
    BAD="$(workload 1500)"
    SRC=$(($(info convert_source_flushes) - s0)); FL=$(($(flushes) - f0))
    CAP=$(($(info deferred_cap_flushes) - c0))
    ct_umount "$MNT"
    out="$(ct_fsck "$DEV" 2>&1)" && pass "$1: fsck clean" || fail "$1: fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
    [ "$BAD" = 0 ] && pass "$1: every written block reads back" || fail "$1: $BAD written blocks read back wrong"
}

log "1: control -- the source written at every full-leaf split, as before"
ct_param_set convert_flush_always 1
run "control"
ct_param_set convert_flush_always 0
SRC1="$SRC"; FL1="$FL"
[ "$SRC1" -ge 20 ] && pass "control: the workload split full leaves and wrote the source $SRC1 times ($FL1 cache flushes)" ||
    { fail "control: setup: only $SRC1 split writes -- the workload does not reach full-leaf splits"; ct_exit; }

log "2: the same workload, one atomic batch per boundary"
run "atomic"
[ "$SRC" = 0 ] && pass "atomic: no split wrote its source" || fail "atomic: $SRC splits still wrote their source"
# Each source write was a whole batch -- three cache flushes. Asked for
# two per split, so a stray flush elsewhere does not fail it.
[ "$FL" -le $((FL1 - 2 * SRC1)) ] && pass "atomic: $FL cache flushes, against $FL1 with $SRC1 source writes" ||
    fail "atomic: $FL cache flushes, against $FL1 with $SRC1 source writes -- not the batches the splits cost"

log "3: a small journal makes the cap engage"
ct_param_set journal_slots_max 8
run "capped"
ct_param_set journal_slots_max 0
[ "$CAP" -ge 2 ] && pass "capped: the held-back set reached its cap and was written early $CAP times" ||
    fail "capped: the cap engaged $CAP times -- the set never reached 4 blocks, or nothing capped it"
[ "$SRC" = 0 ] && pass "capped: and no split wrote its source (8 slots is still atomic)" ||
    fail "capped: $SRC splits wrote their source"

log "4: a batch larger than 16 blocks is atomic"
ct_mkfs "$DEV" -s 1G -z 1 -b 512 -J 2 -M 4 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
BAD="$(workload 3000)" # many leaves, all on the device after its fsync
[ "$BAD" = 0 ] || { fail "4: setup: the first writes did not read back ($BAD)"; ct_exit; }
exec 7<>"$MNT/img"
python3 - 7 <<'PY'
import os, sys, random
fd = int(sys.argv[1])
random.seed(11)
for b in random.sample(range(0, (256 << 20) // 4096), 600):
    os.pwrite(fd, (b"%08d" % b) * 512, b * 4096)
PY
ct_param_set journal_batch_crash_before_targets 1
MARK="$(dmesg_mark)"
python3 -c 'import os,sys; os.fsync(int(sys.argv[1]))' 7 2>/dev/null || true
ct_param_set journal_batch_crash_before_targets 0
exec 7>&-
N="$(dmesg_since "$MARK" | sed -n 's/.*TEST stop after \([0-9]*\) entries, before their targets.*/\1/p' | head -1)"
[ -n "$N" ] || { fail "4: setup: the batch did not stop between its entries and its targets"; ct_exit; }
pass "4: setup: the fsync's batch stopped after $N entries, before any target"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
BAD="$(python3 - "$MNT/img" <<'PY'
import os, sys, random
fd = os.open(sys.argv[1], os.O_RDONLY)
random.seed(7)
first = random.sample(range(0, (256 << 20) // 4096), 3000)
random.seed(11)
second = random.sample(range(0, (256 << 20) // 4096), 600)
bad = sum(1 for b in set(first) | set(second) if os.pread(fd, 8, b * 4096) != b"%08d" % b)
print(bad)
PY
)"
[ "$BAD" = 0 ] && pass "4: after the replay every write the fsync covered reads back ($N entries, one batch)" ||
    fail "4: $BAD writes lost after the replay of a $N-entry batch -- it was not atomic"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "4: fsck clean" || fail "4: fsck: $(grep -m3 ERR <<<"$out" | tr '\n' ' ')"
ct_exit
