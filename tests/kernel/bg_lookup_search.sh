#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the LBA -> Block Group lookup searches, it never walks the whole table
#
# Every free (and every replay bitmap check) resolves its LBA to a Block
# Group. Arithmetic -- (lba - bg_regions_start) / bg_size_blocks -- hits
# on a volume never grown; it misses past a grow's hole (each grow leaves
# one where the previous tail reserve was) and for an LBA in no data
# region at all. A miss used to read, and CRC, every descriptor in the
# table, once per freed extent (audit L20: a hostile extent made each
# free cost the whole table; on a grown volume every free past the hole
# paid it). The miss is now a binary search on the ordered starts.
#
# A: a twice-grown volume, a file preallocated across the whole data
#    area, the last block of every extent punched (past the hole those
#    miss the arithmetic and resolve through the search), then removed;
#    fsck must find nothing leaked or double-freed.
# B: a file whose extent names a block in the first grow's hole (inside
#    the data area's bounding box, in no Block Group); its removal may
#    read O(log BGs) descriptors, not all of them.
#
# DISCRIMINATION: proven by (B) restoring the linear walk (the read
# count is the table size) and (A) making the search miss (the post-hole
# frees are refused and fsck lists them leaked).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
PPOKE="$(ct_helper extent_phys_poke)"

# The smallest Block Group is 512 MiB; ~120 of them make a search and a
# walk differ by an order of magnitude. Sparse: only metadata and the
# preallocation's bitmaps are ever written (fallocate writes no data).
DEV="$(ct_sparse_dev 65536 bgls)"
IMG="$(losetup -nO BACK-FILE "$DEV")"
MNT="$(ct_mnt bgls)"
ct_track mnt "$MNT"
ct_mkfs "$DEV" -s 20G -b 512 -z 1 -J 0 -N 1024 -f >/dev/null
ct_growfs "$DEV" -s 40G >/dev/null 2>&1 || { fail "setup: the first grow failed"; ct_exit; }
ct_growfs "$DEV" -s 63G >/dev/null 2>&1 || { fail "setup: the second grow failed"; ct_exit; }
ct_fsck "$DEV" >/dev/null 2>&1 || { fail "setup: the twice-grown volume is not clean"; ct_exit; }

reads() { sed -n 's/^bg_lookup_reads: //p' "$(ct_procdir "$DEV")/info"; }

# ---------------------------------------------------------------- A
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
INFO="$(ct_procdir "$DEV")/info"
BGS="$(sed -n 's/^block_group_count: //p' "$INFO")"
FREE_KB="$(df -Pk "$MNT" | awk 'NR==2 {print $4}')"
fallocate -l $(((FREE_KB - 8192) * 1024)) "$MNT/big" || { fail "setup: could not preallocate the data area"; ct_exit; }
sync
# Each extent is freed by its START, and a start never misses the
# arithmetic (a hole shifts it by less than a Block Group). The last
# block of a post-hole extent does: punch every extent's last block.
command -v filefrag >/dev/null || { skip "filefrag is not installed"; ct_umount "$MNT"; ct_exit; }
LASTS="$(filefrag -v -b4096 "$MNT/big" | awk -F: '$1 ~ /^ *[0-9]+$/ { split($2, a, "[.]+"); print a[2] + 0 }')"
NPUNCH=0
R0="$(reads)"
for l in $LASTS; do
    fallocate -p -o $((l * 4096)) -l 4096 "$MNT/big" && NPUNCH=$((NPUNCH + 1))
done
sync
RA=$(($(reads) - R0))
rm "$MNT/big"
sync
ct_umount "$MNT"
OUT="$(CETRAFS_FSCK_DUMP_LEAKS=1 ct_fsck "$DEV" 2>&1 || true)"
NLEAK="$(grep -c '^LEAK:' <<<"$OUT" || true)"
log "A: $BGS Block Groups; preallocated $((FREE_KB / 1024)) MiB, punched $NPUNCH extent tails ($RA search reads), removed it; leaked after: $NLEAK"
[ "$RA" -gt 0 ] || { fail "setup: no free went past the arithmetic -- the holes were never crossed"; ct_exit; }
grep -qE '^ERR' <<<"$OUT" && fail "A: fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "A: fsck clean after freeing across the grown volume"
[ "$NLEAK" = 0 ] && pass "A: every block past the holes was freed (none leaked)" ||
    fail "A: $NLEAK blocks leaked -- frees past a hole did not resolve their Block Group"

# ---------------------------------------------------------------- B
ct_mount "$DEV" "$MNT"
dd if=/dev/zero of="$MNT/victim" bs=4096 count=1 conv=fsync status=none
INO="$(stat -c %i "$MNT/victim")"
ct_umount "$MNT"
POKED="$("$PPOKE" "$IMG" "$INO" bg_seg_first)" || { fail "setup: could not aim the extent into the hole: $POKED"; ct_exit; }
log "B: $POKED"
blockdev --flushbufs "$DEV"
ct_mount "$DEV" "$MNT"
R0="$(reads)"
rm -f "$MNT/victim"
sync
R1="$(reads)"
ct_umount "$MNT"
D=$((R1 - R0))
LOG2=0
n=1
while [ "$n" -lt "$BGS" ]; do n=$((n * 2)); LOG2=$((LOG2 + 1)); done
# One extent; the free path and the replay-bitmap check may each look it up.
LIMIT=$((2 * (LOG2 + 1)))
log "B: removing a file whose extent names the hole read $D descriptors through the search ($BGS BGs, limit $LIMIT)"
[ "$D" -gt 0 ] || { fail "setup: the hostile extent's free never reached the search"; ct_exit; }
[ "$D" -le "$LIMIT" ] && pass "B: the lookup searched ($D reads), it did not walk $BGS descriptors" ||
    fail "B: the lookup read $D descriptors for one extent ($BGS Block Groups)"
ct_mount "$DEV" "$MNT"
pass "B: the volume still mounts"
ct_umount "$MNT"
ct_exit
