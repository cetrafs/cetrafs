#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a lockless lookup never reads an extent leaf halfway through an edit
#
# A cached leaf is the memory the extent-tree writers edit in place,
# under the buffer lock and invalidate_lock. The point lookup read it
# with neither, from paths that hold neither: an O_DIRECT read,
# writeback. An entry is several stores, and dropping one from the
# unordered array copies the LAST entry over it -- so a scan meanwhile
# could find the last extent's logical range on the dropped extent's
# physical blocks, and read (or, from writeback, write) the wrong ones.
# qemu cache=none with random I/O into preallocated space is this.
#
# Staged: a spilled file whose leaf holds a preallocated extent first
# and a written block last. An async O_DIRECT write covers the whole
# preallocated extent; its completion drops the entry and copies the
# last one into the slot, held halfway (leaf_drop_copy_stall_ms). An
# O_DIRECT read of the last entry's block runs meanwhile, and must
# return that block's own bytes.
#
# DISCRIMINATION: without the buffer lock in
# cetrafs_tree_lookup_unchecked() the read returns the preallocated
# extent's blocks, i.e. the write's 'D's.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/leaf_drop_copy_stall_ms ] || { skip "leaf_drop_copy_stall_ms is missing"; ct_exit; }
AIO="$(ct_helper dio_aio)"
IPOKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper leaf_poke)"

IMG="$(ct_image 560 leaftorn)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt leaftorn)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set alloc_run_blocks 0
ct_param_set auto_defrag 0
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
F="$MNT/victim"

# Preallocated [100,102) first (after its written neighbour 99), then blocks 0..5 written one at a time,
# each separated from the last by a spacer block: seven entries.
python3 - "$MNT" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
v = os.open(sys.argv[1] + "/victim", os.O_RDWR | os.O_CREAT, 0o644)
s = os.open(sys.argv[1] + "/spacer", os.O_WRONLY | os.O_CREAT, 0o644)
if libc.fallocate(v, 0, ctypes.c_long(99 * 4096), ctypes.c_long(3 * 4096)):
    sys.exit("fallocate failed: %d" % ctypes.get_errno())
# Block 99 written: the preallocated [100,102) then has a written
# neighbour, which is what makes its whole-extent conversion DROP the
# entry (and grow the neighbour) rather than flip it in place.
os.pwrite(v, b"N" * 4096, 99 * 4096); os.fsync(v)
for i in range(6):
    os.pwrite(s, b"s" * 4096, i * 4096); os.fsync(s)
    os.pwrite(v, (b"%d" % i) * 4096, i * 4096); os.fsync(v)
os.close(s); os.close(v)
PY
sync
INO="$(stat -c %i "$F")"
SHOW="$("$LPOKE" "$IMG" show "$INO" 2>&1 || true)"
FIRST="$(sed -n 's/^ent 0 block=\([0-9]*\) .*uninit=\([01]\)$/\1 \2/p' <<<"$SHOW")"
LAST="$(grep '^ent ' <<<"$SHOW" | tail -1 | sed -n 's/^ent [0-9]* block=\([0-9]*\) phys=[0-9]* len=\([0-9]*\) uninit=0$/\1 \2/p')"
if [ "$FIRST" != "100 1" ] || [ -z "$LAST" ]; then
    fail "setup: the leaf is not [preallocated first ... written last]: $(tr '\n' ' ' <<<"$SHOW")"
    ct_exit
fi
LBLK="${LAST% *}"
pass "setup: entry 0 is the preallocated [100,+2), the last entry is written block $LBLK"
WANT="${LBLK: -1}"

ct_param_set leaf_drop_copy_stall_ms 2000
OUT="$("$AIO" readmid "$F" $((100 * 4096)) 8192 400 "$LBLK")"
ct_param_set leaf_drop_copy_stall_ms 0
log "async write over [100,102) + read of block $LBLK meanwhile: $OUT"
grep -q 'inflight=1' <<<"$OUT" ||
    fail "setup: the write had completed before the read -- nothing raced"
FIRSTB="$(sed -n 's/.*first=\(.\).*/\1/p' <<<"$OUT")"
[ "$FIRSTB" = "$WANT" ] && pass "the read of block $LBLK returned its own bytes" ||
    fail "the read of block $LBLK returned '$FIRSTB', not '$WANT' -- it mapped through a half-copied leaf entry"

# And afterwards, everything is where it belongs.
RES="$(python3 - "$F" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
bad = [i for i in range(6) if d[i*4096:(i+1)*4096] != (b"%d" % i) * 4096]
bad += [b for b in (100, 101) if d[b*4096:(b+1)*4096] != b"D" * 4096]
bad += [99] if d[99*4096:100*4096] != b"N" * 4096 else []
print("ok" if not bad else "bad blocks %s" % bad)
PY
)"
[ "$RES" = ok ] && pass "the file's contents are intact afterwards" || fail "after the race: $RES"

ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
