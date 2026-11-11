#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a redo is announced as the dead node's change, so the REPLAYING node stops trusting its own cached tree too
#
# After a redo, replay advances the owner's change stamp so a node that
# cached the block reads it again (L9). For a file that stamp is a
# file_seq, whose top bits name the node that made the change, and every
# gate that decodes it reads "mine" as "my own writeback: my cache is
# right". Drawn as the REPLAYING node's, the stamp was therefore heard by
# every node except the one most likely to hold the file: under
# nofilelock the VM is restarted on a survivor, and that survivor's
# heartbeat is what replays the dead node's journal. Its cached tree
# went on mapping the leaf as it was before the redo (review F1).
#
# The redo is the dead node's write landing, so its stamp names the dead
# node.
#
# Played on one node, nofilelock: a file with an external extent leaf,
# open and read here (its tree cached), and a stale peer's live journal
# entry putting an older image of that leaf back. After the replay,
# this node must see the leaf the device holds.
#
# The redo moves block 0's extent. It is written through this node's
# own buffer cache, so the leaf BUFFER is current here (fiemap and
# O_DIRECT already map block 0 the new way); what is not is everything
# built from the old mapping -- the clean pages a reader filled, which
# only marking the tree cold drops. So the observable is an ordinary
# read of block 0.
#
#  1. the stamp is a peer's: the cache is dropped (file_cache_drops) and
#     a read of block 0 returns what the redone leaf maps.
#  2. CONTROL, replay_stamp_as_self (the stamp as it was drawn before):
#     nothing is dropped, and the read returns the bytes the old
#     mapping gave.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v filefrag >/dev/null || { skip "no filefrag(8)"; ct_exit; }
for p in replay_stamp_as_self journal_replay_apply_pause_ms; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
JPOKE="$(ct_helper journal_poke)"
POKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper leaf_poke)"

IMG="$(ct_image 560 jrstamp)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt jrstamp)"
OLD="$(ct_tmp jrstamp-old)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0 # the rolled-back leaf leaves the newer extents' blocks unreferenced

mnt_nfl() { mount -t cetrafs -o nofilelock "$DEV" "$MNT" && ct_track mnt "$MNT"; }
info() { awk -v k="$1:" '$1 == k { print $2 }' "$(ct_procdir "$DEV")/info"; }

# holes <from> <to>: punch every other block of [from,to) out of v,
# leaving each block between two holes an extent of its own.
holes() {
    local i
    for i in $(seq "$1" 2 $(($2 - 1))); do
        fallocate -p -o $((i * 4096)) -l 4096 "$MNT/v"
    done
}

# blk0: v's block 0 as an ordinary (buffered) read returns it.
blk0() { dd if="$MNT/v" bs=4096 count=1 status=none | sha256sum | cut -d' ' -f1; }
devblk() { dd if="$DEV" bs=4096 skip="$1" count=1 iflag=direct status=none | sha256sum | cut -d' ' -f1; }
# phys0: the physical block fiemap reports for v's logical block 0.
# (awk reads to the end: an early exit kills filefrag with SIGPIPE, and
# pipefail turns that into an abort.)
phys0() { filefrag -v "$MNT/v" | awk '$1 == "0:" && !done { sub(/\.\..*/, "", $4); print $4; done = 1 }'; }

# stage: v with an external leaf, every other block punched out; OLD =
# the same leaf with block 0's extent pointing one block on (the block
# punched out after it) -- a valid leaf the device does not hold, as a
# dead node's journal entry would carry. Sets INO, LEAF, P_NEW (block
# 0's physical as the device has it) and P_OLD (as OLD has it).
stage() {
    local cur ent
    ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    mnt_nfl
    require_cetrafs_mount "$MNT"
    dd if=/dev/urandom of="$MNT/v" bs=4096 count=160 conv=fsync status=none
    holes 1 160
    sync
    INO="$(stat -c %i "$MNT/v")"
    P_NEW="$(phys0)"
    ct_umount "$MNT"
    SHAPE="$("$POKE" "$IMG" extents "$INO")"
    case "$SHAPE" in depth=1*) ;; *) fail "setup: v did not spill into a leaf: $SHAPE"; ct_exit ;; esac
    LEAF="$("$POKE" "$IMG" leaf "$INO" | sed -n 's/.*leaf_lba=\([0-9]*\).*/\1/p')"
    [ -n "$LEAF" ] && [ -n "$P_NEW" ] || { fail "setup: no leaf block ($LEAF) or block 0 mapping ($P_NEW) for v"; ct_exit; }
    ent="$("$LPOKE" "$IMG" show "$INO" | awk -v p="$P_NEW" '$3 == "block=0" && $4 == "phys=" p && !done { print $2; done = 1 }')"
    [ -n "$ent" ] || { fail "setup: no leaf entry maps block 0 at $P_NEW"; ct_exit; }
    cur="$(ct_tmp jrstamp-cur)"
    dd if="$IMG" of="$cur" bs=4096 skip="$LEAF" count=1 status=none
    P_OLD=$((P_NEW + 1))
    "$LPOKE" "$IMG" setphys "$INO" "$ent" "$P_OLD" >/dev/null
    dd if="$IMG" of="$OLD" bs=4096 skip="$LEAF" count=1 status=none
    dd if="$cur" of="$IMG" bs=4096 seek="$LEAF" count=1 conv=notrunc status=none
    cmp -s "$cur" "$OLD" && { fail "setup: the older leaf image is the current one"; ct_exit; }
    [ "$(devblk "$P_NEW")" != "$(devblk "$P_OLD")" ] ||
        { fail "setup: blocks $P_NEW and $P_OLD hold the same bytes -- a read cannot tell the mappings apart"; ct_exit; }
    return 0
}

# replay_under_cache: a dead peer's entry puts OLD back over the leaf;
# this node mounts, opens and reads v (caching its tree) while the
# replay is held before its redo, then lets the redo land. Sets SEEN
# (fiemap's extent count afterwards) and DROPS (cache drops meanwhile).
replay_under_cache() {
    local mark d0
    compress_timing
    poke_dead_peer "$DEV" 1 aa
    "$JPOKE" "$DEV" 1 0 "$LEAF" "$OLD" --guard-current >/dev/null
    ct_param_set journal_replay_apply_pause_ms 4000
    mark="$(dmesg_mark)"
    mnt_nfl
    exec 3<"$MNT/v"
    cat "$MNT/v" >/dev/null
    [ "$(phys0)" = "$P_NEW" ] || fail "setup: before the redo this node maps block 0 at $(phys0), not $P_NEW"
    dd if="$DEV" bs=4096 skip="$LEAF" count=1 iflag=direct status=none | cmp -s - "$OLD" &&
        { fail "setup: the redo landed before this node had cached the tree"; exec 3<&-; ct_exit; }
    d0="$(info file_cache_drops)"
    wait_for 60 "dmesg_since '$mark' | grep -q 'pausing .* before redoing target $LEAF'" ||
        { fail "setup: the replay never reached the redo of the leaf: $(dmesg_since "$mark" | grep 'journal replay' | tail -2)"; exec 3<&-; ct_exit; }
    cat "$MNT/v" >/dev/null # read again while the redo is pending
    ct_param_set journal_replay_apply_pause_ms 0
    wait_for 30 "[ \"\$(dd if='$DEV' bs=4096 skip=$LEAF count=1 iflag=direct status=none | cmp -s - '$OLD' && echo y)\" = y ]" ||
        { fail "setup: the redo never put the older leaf back"; exec 3<&-; ct_exit; }
    sleep 2.5 # past the once-a-second stamp check
    SEEN="$(blk0)"
    SUM_NEW="$(devblk "$P_NEW")"
    SUM_OLD="$(devblk "$P_OLD")"
    DROPS=$(($(info file_cache_drops) - d0))
    exec 3<&-
    ct_umount "$MNT"
    ct_param_set journal_replay_apply_pause_ms 0
    reset_stale_window
}

# ------------------------------------------------------------------- 1
log "1: the replaying node holds the file, its tree cached"
stage
replay_under_cache
[ "$DROPS" -ge 1 ] && pass "1: the redo's stamp read as a peer's change on the replaying node ($DROPS cache drop(s))" ||
    fail "1: the replaying node took the redo's stamp for its own writeback and kept its cache"
[ "$SEEN" = "$SUM_OLD" ] && pass "1: and a read of block 0 goes through the leaf the device holds (block $P_OLD)" ||
    { [ "$SEEN" = "$SUM_NEW" ] && fail "1: a read of block 0 still maps it at $P_NEW, through the leaf as it was before the redo" ||
        fail "1: a read of block 0 returned neither block's bytes"; }

# ------------------------------------------------------------------- 2
log "2: CONTROL -- the stamp names the replaying node"
stage
ct_param_set replay_stamp_as_self 1
replay_under_cache
ct_param_set replay_stamp_as_self 0
[ "$DROPS" = 0 ] && [ "$SEEN" = "$SUM_NEW" ] &&
    pass "2: named as its own, the stamp left the stale mapping trusted (block 0 read from $P_NEW; the device's leaf says $P_OLD) -- what 1 prevents" ||
    fail "2: even stamped as its own the cache was dropped ($DROPS) or the read went to the device's leaf -- 1 proves nothing"
ct_exit
