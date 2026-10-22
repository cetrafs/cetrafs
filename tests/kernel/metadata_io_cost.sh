#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the device writes a namespace operation costs
#
# Journaling a block costs FOUR synchronous writes -- payload, header,
# target, consume -- and on the shared LUN this filesystem is for a
# write is ~38 ms, six times a read. mkdir journaled the child's first
# dirent block, which at that moment is referenced by nothing: the
# child's record is not written yet and the parent's entry comes last.
# A crash there leaves an allocated inode and block that nothing names,
# the bounded leak fsck already reports, so the journal was buying a
# repair for a block no reader could find. Dropping it took mkdir from
# 15.1 device writes to 12.1 on this harness, 11 to 8 on the LUN.
#
# The assertion is the device write COUNT, because that is the thing
# that was wrong. Note it is also the thing a loop device CAN see:
# the same measurement for READS shows nothing here, since the blocks
# in question are buffer-cache hits.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 ra)"
LOOPDEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt ra-mnt)"
# -J 4: journaling MUST be on. With -J 0 the journal is a silent no-op
# and three of the five reads under test never happen at all, so the
# whole suite would pass against either build.
ct_mkfs "$LOOPDEV" -z 1 -b 512 -N 1024 -M 2 -J 4 -f >/dev/null
ct_track mnt "$MNT"
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"

BASE="$(basename "$LOOPDEV")"
rw_now() { awk '{print $1, $5}' "/sys/block/$BASE/stat"; }

# Warm: the first touch of any structure reads it once legitimately.
# Steady state is what this measures.
mkdir -p "$MNT/w"
for i in $(seq 1 20); do : >"$MNT/w/warm$i"; done
for i in $(seq 1 20); do rm -f "$MNT/w/warm$i"; done
sync; sleep 1

N=40
per_op() { # which (reads|writes), op-name, command-prefix
  local which="$1"; shift; shift
  local r0 w0 r1 w1
  sync; sleep 1
  read -r r0 w0 <<<"$(rw_now)"
  for i in $(seq 1 $N); do "$@" "$i"; done
  sync
  read -r r1 w1 <<<"$(rw_now)"
  if [ "$which" = reads ]; then
    awk -v a="$r0" -v b="$r1" -v n="$N" 'BEGIN{printf "%.2f", (b-a)/n}'
  else
    awk -v a="$w0" -v b="$w1" -v n="$N" 'BEGIN{printf "%.2f", (b-a)/n}'
  fi
}

do_create() { : >"$MNT/w/f$1"; }
do_mkdir()  { mkdir "$MNT/w/d$1"; }

CREATE_W="$(per_op writes create do_create)"
MKDIR_W="$(per_op writes mkdir do_mkdir)"
log "device writes per op: create=$CREATE_W mkdir=$MKDIR_W"

# Bounds, not exact counts: the read count legitimately moves with
# unrelated work. They sit between what the fixed build measures and
# what the pre-fix build measured, so each discriminates.
#   create: 3 journal reads removed    mkdir: 6 (two journaled blocks)
#                                              plus the new dirent block
assert_lt() { # label, value, bound
  if awk -v v="$2" -v b="$3" 'BEGIN{exit !(v < b)}'; then
    pass "$1 ($2 < $3)"
  else
    fail "$1: $2 device writes/op, expected < $3"
  fi
}
# mkdir legitimately costs more than create: one extra block (the
# child's dirent block) and its record. Stated as a DIFFERENCE so the
# assertion does not move with unrelated per-op work; the absolute
# bound is the backstop. Before the fix: mkdir 15.1, create 11.1.
DIFF="$(awk -v m="$MKDIR_W" -v c="$CREATE_W" 'BEGIN{printf "%.2f", m - c}')"
log "mkdir costs $DIFF more device writes than create"
assert_lt "mkdir does not journal the child dirent block nothing can reach" "$DIFF" 2.5
# A journaled block costs three synchronous writes PLUS two cache flushes:
# blkdev_issue_flush() so the journal entry is durable before the in-place
# write, and again so the target is durable before the entry is consumed --
# crash-ordering safety on a volatile write cache, which the deployment LUN
# reports (write-back). Those flushes count as device writes here, raising
# the per-op floor by ~2 (create 9.x -> 11.1, mkdir 10.x -> 12.1); reverting
# them drops it back, so these still discriminate. The crash rig's Phase 4
# is the direct proof the flushes are emitted.
# v0x0005 raised the per-dir-op floor by one write: the namespace lock's
# release now publishes the parent's FILE sector (size/mtime/extents)
# separately from the sector-0 swap that carries dirent_seq -- the
# two-step publish that makes dirent_seq the freshness barrier. One
# extra 512-byte sector write per directory-mutating op, bounded here.
assert_lt "mkdir device writes stay bounded" "$MKDIR_W" 14.8
assert_lt "create device writes stay bounded" "$CREATE_W" 12.6

# The content must still be right: a blind write that skipped the read
# publishes uninitialised memory if any byte goes unwritten.
[ "$(ls "$MNT/w" | wc -l)" = "$((N * 2))" ] &&
    pass "every create and mkdir landed" ||
    fail "expected $((N * 2)) entries, found $(ls "$MNT/w" | wc -l)"
for i in 1 $((N / 2)) $N; do
  [ -f "$MNT/w/f$i" ] || fail "f$i missing"
  [ -d "$MNT/w/d$i" ] || fail "d$i missing"
done
pass "spot-checked entries are the right type"

log "record writes and compare-and-swaps per operation"
# Neither is visible in /sys/block -- a CAW is a passthrough request the
# block layer does not account, and a record write is one 4 KiB write
# among many -- and neither can be measured on a loop device by timing,
# where the CAS fallback is itself a write so folding a write into a CAS
# nets to zero. procfs counts them, which makes the cost assertable
# here and observable on the real LUN at the same time.
PROC="/proc/fs/cetrafs/$(basename "$LOOPDEV")/info"
counter() { grep "^$1:" "$PROC" | awk '{print $2}'; }

per_op_counter() { # counter-name, op-fn, first-index
  local c="$1" fn="$2" first="$3" a b i
  sync; a="$(counter "$c")"
  for ((i = first; i < first + 20; i++)); do "$fn" "$i"; done
  sync; b="$(counter "$c")"
  awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f", (b-a)/20}'
}
do_create2() { : >"$MNT/w/g$1"; }
do_unlink2() { rm -f "$MNT/w/g$1"; }

CW="$(per_op_counter record_writes do_create2 0)"
UW="$(per_op_counter record_writes do_unlink2 0)"
log "record writes per op: create=$CW unlink=$UW"

# v0x0005 accounting: a create writes the child's whole record (freshly
# allocated, nothing shares it) = 1, plus the parent's two-step release
# publish (file sector + sector-0 swap, both counted as record writes on
# a no-CAW device) = 2 more. Unlink stages the victim's decrement into
# the release swap (1) and the parent's dirent shrink costs the same
# two-step (the file-sector write; the swap carries the rest) -- the
# measured steady state is ~1/op because the parent's file sector only
# changes when the dirent block content changes shape. The bounds assert
# the ORDER of cost, not the exact fold: a regression to per-field
# writes would blow straight past them.
assert_lt "create stays at child-record + two-step parent release" "$CW" 3.5
assert_lt "unlink folds its updates into the release publishes" "$UW" 1.6

ct_umount "$MNT"
ct_mount "$LOOPDEV" "$MNT"
require_cetrafs_mount "$MNT"
[ "$(ls "$MNT/w" | wc -l)" = "$((N * 2))" ] &&
    pass "and survive a remount" ||
    fail "after remount: expected $((N * 2)) entries, found $(ls "$MNT/w" | wc -l)"
ct_umount "$MNT"
ct_fsck "$LOOPDEV"
pass "fsck clean"

ct_exit
