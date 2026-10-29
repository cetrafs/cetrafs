#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the background defrag janitor, and the fragmentation-index gate
#
# A file qualifies only when its extent count is at least
# auto_defrag_min_pct of the MINIMUM a file that size could occupy, and
# it has at least auto_defrag_min_extents. Raw extent count is the wrong
# trigger: the 128 MB per-extent cap means a big contiguous file
# legitimately needs many extents and must never be churned.
set -euo pipefail
# A silent set -e abort in this suite's index-gate section has failed
# three full-gate runs while every isolated run passed, and left its
# mount behind for the suites after it. Name the dying command instead
# of guessing at it.
trap 'echo "ABORT at line $LINENO: $BASH_COMMAND (rc=$?)" >&2' ERR
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
# This suite needs FRAGMENTED files: an external leaf, a depth-1 tree, an
# auto-defrag trigger. Speculative run allocation makes a sequential write
# land contiguously and merge into one extent, so the fragmentation its
# setup relies on never happens and the suite would test nothing (several
# assertions below check exactly that precondition, which is how this was
# caught). Turn runs off so allocation goes back one block at a time.
ct_param_set alloc_run_blocks 0

log "checking AUTOMATIC background defrag (kernel-triggered)"

# Build a 16-extent file with the janitor disabled (runtime module
# param), re-enable it, then trigger with a bare write-open+close -- the
# last-writer close reports the extent count, the background worker
# claims the idle file's cross-node lock and relocates it. Assert via
# dmesg + the manual tool reporting an already-contiguous file.
AD_IMG="$(mktemp /tmp/cetrafs-ad-XXXXXX.img)"
truncate -s 560M "$AD_IMG"
AD_LOOPDEV="$(losetup --find --show "$AD_IMG")"
AD_MNT="$(mktemp -d /tmp/cetrafs-ad-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$AD_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
mount -t cetrafs "$AD_LOOPDEV" "$AD_MNT"
require_cetrafs_mount "$AD_MNT"

ct_param_set auto_defrag 0

rm -f /tmp/cetrafs-ad-src
for i in $(seq 0 15); do
    dd if=/dev/urandom of=/tmp/cetrafs-ad-blk bs=4096 count=1 status=none
    cat /tmp/cetrafs-ad-blk >>/tmp/cetrafs-ad-src
    dd if=/tmp/cetrafs-ad-blk of="$AD_MNT/adfile" bs=4096 seek="$i" count=1 conv=notrunc status=none
    [ "$i" -lt 15 ] && printf x >"$AD_MNT/adfiller$i"
done
rm -f /tmp/cetrafs-ad-blk
AD_SUM_BEFORE="$(sha256sum "$AD_MNT/adfile" | cut -d' ' -f1)"

ct_param_set auto_defrag 1  # re-enable: this section tests the trigger
DMESG_MARK_AD="$(dmesg_mark)"
: >> "$AD_MNT/adfile"   # bare write-open + close = the trigger

AD_DONE=0
for _ in $(seq 1 20); do
    if dmesg_since "$DMESG_MARK_AD" | grep -q 'auto-defrag: ino=.* extents 16 -> 1'; then
        AD_DONE=1
        break
    fi
    sleep 0.5
done
[ "$AD_DONE" = "1" ] && pass "auto-defrag: background worker relocated the 16-extent file to 1 extent" ||
    fail "auto-defrag: no completion line in dmesg: $(dmesg_since "$DMESG_MARK_AD" | grep -i defrag)"

AD_SUM_AFTER="$(sha256sum "$AD_MNT/adfile" | cut -d' ' -f1)"
[ "$AD_SUM_BEFORE" = "$AD_SUM_AFTER" ] && pass "auto-defrag: content byte-identical after the background move" ||
    fail "auto-defrag: content changed"

AD_TOOL_OUT="$("$ROOT/userspace/defrag.cetra" "$AD_MNT/adfile")"
echo "$AD_TOOL_OUT" | grep -q 'extents 1 -> 1 (0 blocks moved)' &&
    pass "auto-defrag: manual tool confirms the file is already contiguous" ||
    fail "auto-defrag: tool says: $AD_TOOL_OUT"

umount "$AD_MNT"
"$ROOT/userspace/fsck.cetra" "$AD_LOOPDEV" >/dev/null &&
    pass "auto-defrag: fsck clean after the background move" ||
    fail "auto-defrag: fsck errors after the background move"
rmdir "$AD_MNT"
losetup -d "$AD_LOOPDEV"
rm -f "$AD_IMG" /tmp/cetrafs-ad-src
ct_param_set auto_defrag 0

log "checking the auto-defrag fragmentation-index gate (only genuinely-fragmented files)"
# Two files on one mount: (1) a 20-block CONTIGUOUS file (written in one
# sequential pass -- one extent, index 100) must NOT be queued even
# though it's larger than the min-extents floor in blocks; (2) a 20-block
# file written with interleaved fillers (20 one-block extents, index
# ~2000) MUST be relocated. Guards the "don't defrag what isn't actually
# fragmented" requirement.
IDX_IMG="$(mktemp /tmp/cetrafs-idx-XXXXXX.img)"
truncate -s 560M "$IDX_IMG"
IDX_LOOPDEV="$(losetup --find --show "$IDX_IMG")"
IDX_MNT="$(mktemp -d /tmp/cetrafs-idx-mnt-XXXXXX)"
"$ROOT/userspace/mkfs.cetra" "$IDX_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
mount -t cetrafs "$IDX_LOOPDEV" "$IDX_MNT"
require_cetrafs_mount "$IDX_MNT"
# Build the probes with THIS mount's janitor OFF. With it on, a fast
# box collapses the fragmented probe WHILE the dd loop is still
# interleaving it (a loaded 8-core traced the janitor moving 4, then 7,
# then 10... blocks as the file grew), so the "20 fragments, then one
# move" premise this gate asserts never exists to begin with.
echo "auto_defrag off" >"$(ct_procdir "$IDX_LOOPDEV")/controls"
ct_param_set auto_defrag 1  # this section tests the index gate

DMESG_MARK_IDX="$(dmesg_mark)"
# contiguous: single sequential write, no interleaving -> coalesces to 1 extent
dd if=/dev/urandom of="$IDX_MNT/contig" bs=4096 count=20 conv=fsync status=none
# fragmented: interleave fillers so every block is its own extent
for i in $(seq 0 19); do
    dd if=/dev/urandom of=/tmp/cetrafs-idx-blk bs=4096 count=1 status=none
    dd if=/tmp/cetrafs-idx-blk of="$IDX_MNT/fragged" bs=4096 seek="$i" count=1 conv=notrunc status=none
    [ "$i" -lt 19 ] && printf x >"$IDX_MNT/ifiller$i"
done
rm -f /tmp/cetrafs-idx-blk
sync "$IDX_MNT/contig" "$IDX_MNT/fragged"
# bare write-open+close on each to fire the close trigger
# Probes built and verified: NOW arm the janitor and only then take the
# window the asserts read. The bare re-opens below are the triggers.
echo "auto_defrag on" >"$(ct_procdir "$IDX_LOOPDEV")/controls"
DMESG_MARK_IDX="$(dmesg_mark)"
: >> "$IDX_MNT/contig"
: >> "$IDX_MNT/fragged"

# The same 120s budget as every other janitor wait in this directory --
# the 10s one below missed under loaded full gates, and worse: the LOG
# capture after it ran `grep` inside a command substitution with no
# match tolerance, so a quiet janitor aborted the whole suite under
# set -e with no error text, LEFT ITS MOUNT MOUNTED, and the three
# defrag suites after it failed against the leftovers. Every "janitor
# never ran" full-gate failure of 2026-10-29 traces back to this one
# line; the ERR trap above is what finally named it.
IDX_DONE=0
for _ in $(seq 1 240); do
    dmesg_since "$DMESG_MARK_IDX" | grep -q 'auto-defrag: ino=.* blocks moved' && { IDX_DONE=1; break; }
    sleep 0.5
done
IDX_LOG="$(dmesg_since "$DMESG_MARK_IDX" | grep 'auto-defrag:' || true)"

# the fragged file must have been moved; the contig file must NOT appear
FRAGGED_INO="$(stat -c '%i' "$IDX_MNT/fragged")"
CONTIG_INO="$(stat -c '%i' "$IDX_MNT/contig")"
echo "$IDX_LOG" | grep -q "ino=$FRAGGED_INO .*blocks moved" &&
    pass "index gate: the genuinely-fragmented file (index ~2000) was auto-defragged" ||
    { fail "index gate: fragmented file not defragged; log: $IDX_LOG"
      log "diag: param auto_defrag=$(cat /sys/module/cetrafs/parameters/auto_defrag 2>/dev/null)"
      log "diag: index mount controls: $(grep -E 'defrag' "$(ct_procdir "$IDX_LOOPDEV")/controls" 2>/dev/null | tr '\n' ' ')"
      log "diag: index mount info: $(grep -E 'defrag' "$(ct_procdir "$IDX_LOOPDEV")/info" 2>/dev/null | tr '\n' ' ')"; }
if echo "$IDX_LOG" | grep -q "ino=$CONTIG_INO .*blocks moved"; then
    fail "index gate: the CONTIGUOUS file (index 100) was wrongly auto-defragged"
else
    pass "index gate: the contiguous file was correctly left alone"
fi

ct_param_set auto_defrag 0
umount "$IDX_MNT"; rmdir "$IDX_MNT"; losetup -d "$IDX_LOOPDEV"; rm -f "$IDX_IMG"



ct_exit
