#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a stat-only publish does not erase a peer's change stamp from this node's view
#
# A reader keeps its cached extent map until the file_seq stamp shows a
# change by ANOTHER node (read_cache_trust.sh, case 3). Every publish of
# the file sector restamps file_seq with this node's id -- including a
# stat-only one (utimensat, chmod-free setattr, writeback of local time
# dirt) that publishes no tree. Landing between a peer's publish and the
# reader's next look, it turned "a peer changed the map" into "the last
# change was mine", and the reader went on mapping through the tree it
# had cached before the peer's change (CLAUDE.md rule 10).
#
# The peer's publish is poked on the device: block 0 repointed at a
# donor and file_seq stamped as node 1. Then a local futimens + fsync,
# on an fd opened before the change (a path-based touch would revalidate
# the dentry, re-read the record and note the stamp first), publishes
# stat only, and the held reader reads block 0 again.
#
# DISCRIMINATION: with stat_publish_ignore_overstamp=1 the publish does
# not note what it overstamped, and the reader reads the old block.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LEAF_POKE="$(ct_helper leaf_poke)"
EXTENT_POKE="$(ct_helper pending_poke)"
REC_POKE="$(ct_helper inode_block_poke)"
PROBE="$(ct_helper odirect_probe)"

IMG="$(ct_image 560 spps)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt spps-mnt)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

printf 'DONORDONOR' >"$MNT/donor"
sync "$MNT/donor"
DONOR_PHYS="$("$EXTENT_POKE" "$IMG" extent "$(stat -c '%i' "$MNT/donor")" | cut -d' ' -f1)"

# A spilled (depth-1) victim, so the leaf poke can repoint block 0.
build_victim() {
    local i
    for i in 0 1 2 3 4; do
        printf 'VICTIM%04d' "$i" | dd of="$MNT/$1" bs=4096 seek="$i" count=1 conv=notrunc 2>/dev/null
        [ "$i" -lt 4 ] && printf x >"$MNT/${1}_f$i"
    done
    sync "$MNT/$1"
}

# probe <file>: hold a read-only O_DIRECT fd, read block 0; the peer
# repoints it and stamps; this node publishes stat only; read again.
probe() {
    local file="$1" ino ready go out pid i
    ino="$(stat -c '%i' "$MNT/$file")"
    ready="$(ct_tmp spps-ready)"; rm -f "$ready"
    go="$(ct_tmp spps-go)"; rm -f "$go"
    out="$(ct_tmp spps-out)"
    "$PROBE" "$MNT/$file" "$ready" "$go" ro >"$out" 2>&1 &
    pid=$!
    # A second fd, opened before the peer's change: futimens on it needs
    # no path lookup, so no revalidate re-reads the record first.
    exec 9<"$MNT/$file"
    for i in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.1; done
    "$LEAF_POKE" "$IMG" setphys "$ino" 0 "$DONOR_PHYS" >/dev/null
    "$REC_POKE" "$IMG" peerseq "$ino" 1 2>/dev/null
    # This node's stat-only publish, before the reader looks again.
    python3 -c 'import os; os.utime(9, (1700000000, 1700000000)); os.fsync(9)'
    exec 9<&-
    SEQ_NODE="$("$REC_POKE" "$IMG" seq "$ino" | cut -d' ' -f2)"
    sleep 1.5
    : >"$go"
    wait "$pid" 2>/dev/null || true
    READ1="$(sed -n 's/^read1 //p' "$out")"
    READ2="$(sed -n 's/^read2 //p' "$out")"
    MTIME="$(stat -c %Y "$MNT/$file")"
}

build_victim v
probe v
log "read1=$READ1 read2=$READ2 mtime=$MTIME stamp-node-after-publish=$SEQ_NODE"
[ "$SEQ_NODE" != 1 ] || fail "setup: the stat publish did not land -- the device still carries the peer's stamp"
[ "$READ1" = VICTIM0000 ] || fail "setup: first read was '$READ1', expected VICTIM0000"
[ "$MTIME" = 1700000000 ] || fail "setup: the touch did not land (mtime $MTIME)"
[ "$READ2" = DONORDONOR ] &&
    pass "the held reader re-mapped block 0 after the peer's change, through this node's stat publish" ||
    fail "the reader read '$READ2' through a map the peer had changed: the stat publish erased the peer's stamp"

ct_umount "$MNT"
ct_exit
