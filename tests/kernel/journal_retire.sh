#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# controls retire_journal=<row>:<incarnation> gives up a dead node's entries that will not settle
#
# A dead node's area with an entry kept -- for a live writer, or
# undecided -- stays dirty until that node mounts again, which a
# decommissioned host never does. Meanwhile the file the entry is for
# cannot be opened anywhere, the dead node's presence bits stay, and
# every open re-scans the area (audit 2026-11-15 F-40). The operator can
# now retire the area: what can be redone is, the rest is said entry by
# entry and consumed unapplied, and the area is parked clean.
#
# Staged as journal_replay_scope.sh's S: node 1 dead with one entry for
# file v's extent leaf, node 2 live and v open for write there, so the
# entry is kept and v refused.
#   1. a wrong incarnation is refused, and so is a live row;
#   2. the right one retires the entry, saying which block it was for;
#   3. v then opens, the area does not come back, fsck clean.
#
# DISCRIMINATION: step 3's open of v is refused before the retirement
# (the same open, the same mount).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
JPOKE="$(ct_helper journal_poke)"
IPOKE="$(ct_helper inode_block_poke)"
LFPOKE="$(ct_helper leaf_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
NPOKE="$(ct_helper node_poke)"
MNT="$(ct_mnt jret)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set hb_replay_sweep_off 1
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }
nfmount() { mount -t cetrafs -o nofilelock "$1" "$2"; }

IMG="$(ct_image 560 jret)"
DEV="$(ct_loop "$IMG")"
dir="$(ct_tmp jret-d)"
rm -rf "$dir"
mkdir -p "$dir"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
nfmount "$DEV" "$MNT"
dd if=/dev/urandom of="$MNT/v" bs=4096 count=60 conv=fsync status=none
for i in $(seq 1 2 59); do fallocate -p -o $((i * 4096)) -l 4096 "$MNT/v"; done
sync
INO="$(stat -c %i "$MNT/v")"
umount "$MNT"
p="$("$IPOKE" "$IMG" leaf "$INO" | sed -n 's/.*leaf_lba=\([0-9]*\).*/\1/p')"
[ -n "$p" ] || { fail "setup: v has no external leaf"; ct_exit; }
a="$dir/a" b="$dir/b"
dd if="$IMG" of="$a" bs=4096 skip="$p" count=1 status=none
ent="$("$LFPOKE" "$IMG" show "$INO" | awk '$3 == "block=0" { print $2; exit }')"
ph="$("$LFPOKE" "$IMG" show "$INO" | awk '$3 == "block=0" { sub("phys=", "", $4); print $4; exit }')"
"$LFPOKE" "$IMG" setphys "$INO" "$ent" $((ph + 1)) >/dev/null
dd if="$IMG" of="$b" bs=4096 skip="$p" count=1 status=none
dd if="$a" of="$IMG" bs=4096 seek="$p" count=1 conv=notrunc status=none
cmp -s "$a" "$b" && { fail "setup: the dead node's image is the leaf as it is"; ct_exit; }
compress_timing
poke_dead_peer "$DEV" 1 aa
"$NPOKE" "$DEV" 1 --mode 2 >/dev/null
"$NPOKE" "$DEV" 1 --inc 7 >/dev/null
"$JPOKE" "$DEV" 1 0 "$p" "$b" --guard-current >/dev/null
poke_dead_peer "$DEV" 2 bb
"$NPOKE" "$DEV" 2 --mode 2 >/dev/null
"$NPOKE" "$DEV" 2 --inc 9 >/dev/null
"$LPOKE" "$DEV" "$INO" --writer 2 >/dev/null
"$LPOKE" "$DEV" "$INO" --reader 1 >/dev/null
blockdev --flushbufs "$DEV"

nfmount "$DEV" "$MNT"
ct_beat_row "$DEV" 2
wait_out_stale_window
CTL="$(ct_procdir "$DEV")/controls"
cat "$MNT/v" >/dev/null 2>&1 && { fail "setup: v opened -- the entry was not kept"; ct_exit; }
pass "before: v is refused while node 1's entry for it is kept"

echo "retire_journal=1:6" >"$CTL" 2>/dev/null && fail "1: a wrong incarnation was accepted" ||
    pass "1: a wrong incarnation is refused"
echo "retire_journal=2:9" >"$CTL" 2>/dev/null && fail "1: a live row's journal was retired" ||
    pass "1: a live row is refused"
MARK="$(dmesg_mark)"
if echo "retire_journal=1:7" >"$CTL" 2>/dev/null; then
    dmesg_since "$MARK" | grep -q "retiring node 1's entry txn .*: block $p of ino $INO" &&
        pass "2: the entry for v's leaf (block $p) was retired, and said so" ||
        fail "2: retired without naming block $p: $(dmesg_since "$MARK" | grep -i retir | head -3)"
else
    fail "2: the retirement was refused: $(dmesg_since "$MARK" | grep -iE 'retir|journal' | head -3)"
fi
cat "$MNT/v" >/dev/null 2>&1 && pass "3: v opens after the retirement" || fail "3: v is still refused"
MARK="$(dmesg_mark)"
echo 0 >/sys/module/cetrafs/parameters/hb_replay_sweep_off
sleep 4
dmesg_since "$MARK" | grep -q "journal replay: node 1" && fail "3: node 1's area was replayed again" ||
    pass "3: the area stayed clean"
ct_unbeat
umount "$MNT" 2>/dev/null || umount -l "$MNT"
reset_stale_window
"$NPOKE" "$DEV" 2 --depart 1 >/dev/null # node 2 was a stand-in: let fsck run without watching it
blockdev --flushbufs "$DEV"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "3: fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "3: fsck clean"
ct_exit
