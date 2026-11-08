#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an extent-cache fill that straddles a drop does not store what it read
#
# An extent walk reads the record and a leaf, then stores the extent it
# found in the per-inode cache, keyed by the record it read (file_seq,
# depth, entries, blocks). A drop landing between the read and the store
# used to be undone by the store: the drop emptied the cache, and the
# walk then filled it with an extent read BEFORE the drop. The key does
# not catch that when the walk's record is already the new one -- a
# record buffer refreshed with a peer's stamp while the leaf beside it
# is still the cached, older block (class 41, docs/internal/BUG-CLASSES.md).
# Every drop now moves a per-inode generation, the walk samples it
# before it reads the tree, and the store refuses when it moved
# (cetrafs_inode_ext_cache_store()).
#
# The interleaving, driven with test knobs:
#   1. an O_DIRECT reader maps block 1: the leaf is now a cached buffer;
#   2. the device repoints block 0 at another file's block and a peer's
#      file_seq lands in the record (written behind the mount's back, so
#      the cached leaf stays the old one);
#   3. a stat's refresh reads the record fresh and declines to apply it
#      (apply_trylock_fail_once -- in the field, any reader holding the
#      inode lock): the record buffer now carries the peer's stamp, and
#      nothing has marked the tree cold;
#   4. the reader maps block 0, trusting its cache (read_trust_ignore_stamp
#      stands in for "inside the once-a-second stamp window"): the new
#      record, the OLD leaf. ext_fill_stall_ms holds it before its store;
#   5. in the pause, a buffered read runs the stamp check, sees the
#      peer's stamp and marks the tree cold; the reconcile drops the
#      cache and the leaf, and settles. (The paused reader holds
#      inode_lock -- legacy direct I/O maps under it -- so neither a
#      stat nor a second direct read could get here.);
#   6. the pause ends and the walk stores; the reader maps block 0 again.
#      It must follow the device's map.
#
# DISCRIMINATION: with ext_cache_ignore_gen=1 (the store as it was), step
# 6 reads the old block through the extent stored after the drop -- its
# key is the record the cache now holds, so nothing else refuses it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in ext_fill_stall_ms ext_cache_ignore_gen apply_trylock_fail_once read_trust_ignore_stamp; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
LEAF_POKE="$(ct_helper leaf_poke)"
IPOKE="$(ct_helper inode_block_poke)"
EXTENT_POKE="$(ct_helper pending_poke)"

# run <ignore_gen>: one round on a fresh volume; sets R0/R1 (the two
# reads of block 0) and N (stores refused). Not in a subshell: the
# harness tracks what it creates.
run() {
    local IMG DEV MNT INO DONOR_PHYS STEP OUT READER PROC A B D0 D1 R MARK
    R0="" R1="" N=0
    IMG="$(ct_image 560 ecf)"
    DEV="$(ct_loop "$IMG")"
    MNT="$(ct_mnt ecf)"
    ct_mkfs_small "$DEV" >/dev/null
    ct_track mnt "$MNT"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    ct_param_set auto_defrag 0
    ct_param_set scrub 0
    PROC="$(ct_procdir "$DEV")"
    info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }

    printf 'DONORDONOR' >"$MNT/donor"
    sync "$MNT/donor"
    DONOR_PHYS="$("$EXTENT_POKE" "$IMG" extent "$(stat -c '%i' "$MNT/donor")" | cut -d' ' -f1)"
    # A spilled (depth-1) victim: five blocks that cannot merge.
    for i in 0 1 2 3 4; do
        printf 'VICTIM%04d' "$i" | dd of="$MNT/v" bs=4096 seek="$i" count=1 conv=notrunc 2>/dev/null
        [ "$i" -lt 4 ] && printf x >"$MNT/v_f$i"
    done
    sync "$MNT/v"
    INO="$(stat -c '%i' "$MNT/v")"
    [ "$("$LEAF_POKE" "$IMG" leaf "$INO" 2>/dev/null || echo 0)" -gt 0 ] ||
        { fail "setup: the victim has no external leaf"; ct_exit; }

    # The reader: one O_DIRECT fd held throughout; step n maps the block
    # named in the go-file.
    STEP="$(ct_tmp)"
    rm -f "$STEP"
    OUT="$(ct_tmp)"
    python3 -I - "$MNT/v" "$STEP" >"$OUT" 2>&1 <<'PY' &
import mmap, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
buf = mmap.mmap(-1, 4096)
for n in range(3):
    p = "%s.%d" % (sys.argv[2], n)
    while not os.path.exists(p):
        time.sleep(0.02)
    os.preadv(fd, [buf], int(open(p).read()) * 4096)
    print("read%d %s" % (n, buf[:10].decode(errors="replace")), flush=True)
os.close(fd)
PY
    READER=$!
    go() { echo "$2" >"$STEP.t" && mv "$STEP.t" "$STEP.$1"; }
    waitread() { for _ in $(seq 1 200); do grep -q "^read$1 " "$OUT" && return; sleep 0.05; done; }
    got() { sed -n "s/^read$1 //p" "$OUT"; }
    abort() {
        ct_param_set ext_fill_stall_ms 0
        ct_param_set read_trust_ignore_stamp 0
        ct_param_set apply_trylock_fail_once 0
        go 1 0
        go 2 0
        wait "$READER" 2>/dev/null || true
        rm -f "$STEP".[0-9]
        ct_param_set ext_cache_ignore_gen 0
        fail "$1"
        ct_exit
    }

    go 0 1 # 1. the leaf is cached; the cache holds block 1's extent
    waitread 0
    [ "$(got 0)" = VICTIM0001 ] || abort "setup: block 1 read '$(got 0)'"
    sleep 1.2 # the next stamp check is due

    # 2. behind the mount's back
    "$LEAF_POKE" "$IMG" setphys "$INO" 0 "$DONOR_PHYS" >/dev/null
    "$IPOKE" "$IMG" peerseq "$INO" 5 >/dev/null
    # 3. a refresh that reads the record and declines
    ct_param_set apply_trylock_fail_once 1
    stat "$MNT/v" >/dev/null
    ct_param_set apply_trylock_fail_once 0
    D0="$(info file_cache_drops)"

    # 4. the walk: new record, old leaf, held before its store
    A="$(info ext_cache_stale_refused)"
    ct_param_set ext_cache_ignore_gen "$1"
    ct_param_set read_trust_ignore_stamp 1
    ct_param_set ext_fill_stall_ms 6000
    MARK="$(dmesg_mark)"
    go 1 0
    for _ in $(seq 1 50); do
        dmesg_since "$MARK" | grep -q "ino=$INO: TEST pause of [0-9]*ms before an extent-cache store" && break
        sleep 0.1
    done
    ct_param_set ext_fill_stall_ms 0 # the pause in progress keeps its length
    ct_param_set read_trust_ignore_stamp 0
    dmesg_since "$MARK" | grep -q "ino=$INO: TEST pause" || abort "setup: the walk of block 0 never paused before its store"

    # 5. the stamp check, from a reader that does not take inode_lock
    R="$(python3 -I - "$MNT/v" <<'PY2'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
print(os.pread(fd, 10, 2 * 4096).decode(errors="replace"))
PY2
)"
    sleep 0.3 # the reconcile it queued runs unstalled
    D1="$(info file_cache_drops)"
    [ "$D1" -gt "$D0" ] && ! grep -q '^read1 ' "$OUT" ||
        abort "setup: no drop inside the pause (drops $D0 -> $D1, buffered read '$R', block 0 read '$(got 1)')"

    waitread 1
    go 2 0 # 6.
    waitread 2
    wait "$READER" 2>/dev/null || true
    rm -f "$STEP".[0-9]
    ct_param_set ext_cache_ignore_gen 0
    B="$(info ext_cache_stale_refused)"
    R0="$(got 1)"
    R1="$(got 2)"
    N=$((B - A))
    # No fsck: block 0 of the victim now shares the donor's block on purpose.
    ct_umount "$MNT"
}

run 0
pass "setup: the cache was dropped while a walk was paused before its store"
[ "$R0" = VICTIM0000 ] && pass "setup: the paused walk mapped through the old leaf ($R0)" ||
    { fail "setup: the paused walk returned '$R0', expected VICTIM0000 -- it did not read the old leaf"; ct_exit; }
[ "$N" -ge 1 ] && pass "the store after the drop was refused ($N)" ||
    fail "no store was refused across the drop"
[ "$R1" = DONORDONOR ] && pass "the next read followed the device's map" ||
    fail "the next read returned '$R1' through an extent stored after the drop"

# Control: the same round with the generation ignored must go stale, or
# this suite proves nothing about it.
run 1
[ "$R0" = VICTIM0000 ] || { fail "control setup: the paused walk returned '$R0'"; ct_exit; }
[ "$R1" = VICTIM0000 ] && pass "control: with the generation ignored, the read goes stale ($R1)" ||
    fail "control: with the generation ignored the read returned '$R1' -- this suite does not discriminate"
ct_exit
