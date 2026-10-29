#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the remembered extent answers repeat lookups, and never answers a stale one
#
# The buffered write path hands cetrafs_get_block() ONE block at a time by
# contract, so every 4 KiB walks the extent tree from the record down. On a
# compact file that costs nothing -- the root slots' ei_block_end ranges
# exclude everything. On a file with thousands of extents (a VM image
# written in place for months) the ranges stop excluding, because each leaf
# ends up covering a wide and nearly empty span: measured on a real LUN at
# 4.39 leaf+index reads per lookup against 0.00 on a 2-extent file, 3.24 us
# per block against 1.15, and half the throughput.
#
# cetrafs_inode_info.ext_* remembers the last extent a walk resolved, keyed
# on the record it came from (depth, entry count, block count), so any
# mutation that changed the map simply misses instead of needing every
# writer to remember to invalidate. Same LUN, same file: 710 -> 1091 MB/s,
# 1,150,546 tree reads -> 32,109.
#
# Two things have to be true and this asserts both:
#   1. it is actually used (hits, on a rewrite that allocates nothing), and
#   2. it never answers with a mapping the file no longer has.
#
# Discrimination: ext_cache=0 makes the hit counter stay at zero and the
# first assertion fails. For the second, ext_cache_trust_stale=1 keeps the
# entry after the map changed -- it disables BOTH the key check and the
# explicit drops, because either one alone still catches the fault and the
# control then passes, proving nothing (which is exactly what the first
# version of this suite did). The suite runs that negative control itself,
# so a silently-vacuous content check cannot pass unnoticed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 extcache)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt extcache)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

PROC="$(ct_procdir "$DEV")/info"
hits()   { sed -n 's/^ext_cache_hits: //p' "$PROC"; }
misses() { sed -n 's/^ext_cache_misses: //p' "$PROC"; }

[ -n "$(hits)" ] || fail "procfs has no ext_cache_hits counter"

# A file whose extent tree SPILLS out of the record: the inline array holds
# 4 extents, so writing scattered 64 KiB islands and then filling the gaps
# leaves a multi-extent tree in external leaves. The entry is only ever
# consulted for a spilled tree -- an inline array is already in the record
# the caller just read, with nothing to save.
python3 - "$MNT/frag" <<'PY'
import os, sys
f = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644)
os.ftruncate(f, 64 << 20)
buf = b'\0' * 65536
for i in range(0, 1024, 4):          # every 4th island: holes in between
    os.pwrite(f, buf, i * 65536)
os.fsync(f)
os.close(f)
PY
# Fill the holes, so that from here on a rewrite allocates NOTHING and every
# lookup is a pure repeat lookup.
dd if=/dev/zero of="$MNT/frag" bs=64k count=1024 conv=notrunc,fdatasync status=none
sync

H0="$(hits)"; M0="$(misses)"
dd if=/dev/zero of="$MNT/frag" bs=64k count=1024 conv=notrunc,fdatasync status=none
H1="$(hits)"; M1="$(misses)"
HD=$((H1 - H0)); MD=$((M1 - M0))
log "rewrite with nothing to allocate: $HD hits, $MD misses"

# 1. It is used at all.
[ "$HD" -gt 0 ] ||
    fail "the remembered extent was never used: $HD hits in a rewrite of a spilled tree -- every 4 KiB walked the tree"
# And used for the large majority: one miss per extent is the floor (the
# walk that populates it), hits are every block after it.
[ "$HD" -gt "$MD" ] ||
    fail "more misses ($MD) than hits ($HD) on a repeat rewrite -- the entry is being thrown away between blocks"

# 2. It never answers with a mapping the file no longer has. Each of these
# mutates the map in a different way, and the bytes read back afterwards
# must be what was written -- through the same fd and after a remount.
content_ok() { # 0 if every byte reads back as it should
    # A stale remembered extent is only VISIBLE where the mapping
    # changed: re-reading an island nobody touched gives the same right
    # blocks whether the entry was dropped or not. The punched range is
    # the one place the answer differs -- a hole must read as zeros, and
    # an entry that outlived the punch still points at the data that
    # used to be there. Reading it back is therefore the whole test, and
    # the first version of this suite SKIPPED it.
    python3 - "$MNT/frag" <<'PY'
import os, sys, ctypes

ISL, N = 65536, 128
PUNCH = 10                      # the island to punch
p = sys.argv[1]
f = os.open(p, os.O_RDWR)
os.ftruncate(f, 0)
os.ftruncate(f, N * ISL)
for i in range(0, N, 2):        # islands with a self-identifying payload
    os.pwrite(f, bytes([(i & 0x7f) | 0x80]) * ISL, i * ISL)
os.fsync(f)

# Read every island: this is what populates the remembered extent.
for i in range(0, N, 2):
    if os.pread(f, ISL, i * ISL) != bytes([(i & 0x7f) | 0x80]) * ISL:
        print("island %d was already wrong before any mutation" % i)
        os._exit(1)

# Now change what those offsets map to.
libc = ctypes.CDLL("libc.so.6", use_errno=True)
FALLOC_FL_KEEP_SIZE, FALLOC_FL_PUNCH_HOLE = 0x01, 0x02
if libc.fallocate(f, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
                  ctypes.c_long(PUNCH * ISL), ctypes.c_long(ISL)) != 0:
    print("punch failed: %s" % os.strerror(ctypes.get_errno()))
    os._exit(1)
os.ftruncate(f, 64 * ISL)       # drop the upper half
os.ftruncate(f, N * ISL)        # and grow back: those offsets are holes now
os.fsync(f)

# Force the reads through the mapping path rather than the page cache,
# otherwise this measures the page cache and not the extent lookup.
os.posix_fadvise(f, 0, N * ISL, os.POSIX_FADV_DONTNEED)

bad = []
if os.pread(f, ISL, PUNCH * ISL) != bytes(ISL):
    bad.append("punched island %d does not read as zeros" % PUNCH)
for i in range(64, N, 2):       # beyond the shrink, re-grown: holes
    if os.pread(f, ISL, i * ISL) != bytes(ISL):
        bad.append("island %d past the truncate does not read as zeros" % i)
        break
for i in range(0, 64, 2):       # untouched: must still be intact
    if i == PUNCH:
        continue
    if os.pread(f, ISL, i * ISL) != bytes([(i & 0x7f) | 0x80]) * ISL:
        bad.append("island %d lost its contents" % i)
        break
os.close(f)
for b in bad:
    print(b)
os._exit(1 if bad else 0)
PY
}

content_ok && pass "content survives grow/punch/shrink under the remembered extent" ||
    fail "a read landed on the wrong blocks after the map changed -- the entry outlived its record"

# The negative control: keep the entry after the map changed, with every
# invalidation disabled. The very same sequence must now be caught -- if it
# still passes, the check above proves nothing.
log "negative control: ext_cache_trust_stale=1, the content check must now FAIL"
ct_param_set ext_cache_trust_stale 1
if content_ok; then
    fail "the content check passed with every invalidation DISABLED -- it cannot detect a stale mapping, so it proves nothing"
else
    pass "with invalidation off the stale mapping IS caught -- the check discriminates"
fi
ct_param_set ext_cache_trust_stale 0

# And the file is still consistent on disk after all of it.
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults after the extent-cache exercises"

pass "the remembered extent is used, and never answers for a record it did not come from"

ct_exit
