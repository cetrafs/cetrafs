#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a reader trusts its cached map between change stamps; defrag needs the file alone
#
# A node that only READS a file used to re-read the inode record from the
# device for every 4 KiB it mapped, holes included -- the write lock's
# cache question asked of a reader. On an iSCSI LUN a read-only open read
# at ~10 MB/s against ~100 MB/s read-write, and a VM's qcow2 backing file
# is opened read-only.
#
# A reader may trust its cache because nothing it maps through can be
# freed under it: every block-freeing path refuses while a live peer is
# in read_open_nodes. Defrag was the one that did not look -- it took the
# exclusive lock, which a reader never holds -- so it is checked here too.
#
# Four claims, each with the knob that breaks it:
#   1. a read-only sequential read costs a handful of device reads, not
#      one per page                         (read_trust_off)
#   2. a held read-only fd keeps its cached map while nothing changed
#      (read_trust_off)
#   3. a peer's file_seq stamp still sends it fresh within a second
#      (read_trust_ignore_stamp)
#   4. defrag refuses a file a live peer has open for read
#      (defrag_ignore_readers)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

LEAF_POKE="$(ct_helper leaf_poke)"
EXTENT_POKE="$(ct_helper pending_poke)"
REC_POKE="$(ct_helper inode_block_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"
PROBE="$(ct_helper odirect_probe)"

IMG="$(ct_image 560 rct)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rct-mnt)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
LOOP="$(basename "$DEV")"

dev_reads() { awk '{print $1}' "/sys/block/$LOOP/stat"; }

# reads_for <file>: device reads issued by one cold, read-only,
# sequential pass over <file>.
reads_for() {
    local before
    sync
    echo 3 >/proc/sys/vm/drop_caches
    before="$(dev_reads)"
    dd if="$1" of=/dev/null bs=1M status=none
    echo $(($(dev_reads) - before))
}

# ---------------------------------------------------------------- 1
log "1. a read-only sequential read does not re-read the record per page"
truncate -s 64M "$MNT/sparse"
printf 'HEAD' | dd of="$MNT/sparse" conv=notrunc status=none
dd if=/dev/urandom of="$MNT/data" bs=1M count=32 status=none
PAGES_SPARSE=$((64 * 256))
PAGES_DATA=$((32 * 256))

N_SPARSE="$(reads_for "$MNT/sparse")"
N_DATA="$(reads_for "$MNT/data")"
ct_param_set read_trust_off 1
C_SPARSE="$(reads_for "$MNT/sparse")"
C_DATA="$(reads_for "$MNT/data")"
ct_param_set read_trust_off 0
log "device reads: sparse $N_SPARSE (control $C_SPARSE), data $N_DATA (control $C_DATA)"

# The control proves the counter can see the per-page cost at all.
[ "$C_SPARSE" -ge "$PAGES_SPARSE" ] ||
    fail "setup: with read_trust_off the sparse read cost only $C_SPARSE reads -- the counter cannot see the per-page cost"
[ "$N_SPARSE" -lt 256 ] &&
    pass "64 MiB of holes read with $N_SPARSE device reads (per-page re-read: $C_SPARSE)" ||
    fail "64 MiB of holes cost $N_SPARSE device reads -- the record is being re-read per page"
[ "$N_DATA" -lt $((PAGES_DATA / 4)) ] &&
    pass "32 MiB of data read with $N_DATA device reads (readahead batches it; read_trust_off: $C_DATA)" ||
    fail "32 MiB of data cost $N_DATA device reads for $PAGES_DATA pages"

# ------------------------------------------------------- 2 and 3
# A spilled (depth-1) victim whose block 0 the backing-file poke can
# repoint at a donor: a forced-fresh read sees the poke, a cached one
# does not. One read-only O_DIRECT fd is held across it, the way qemu
# holds a backing file: no re-open, so no lookup refresh to hide behind.
printf 'DONORDONOR' >"$MNT/donor"
sync "$MNT/donor"
DONOR_PHYS="$("$EXTENT_POKE" "$IMG" extent "$(stat -c '%i' "$MNT/donor")" | cut -d' ' -f1)"

build_victim() {
    local i
    for i in 0 1 2 3 4; do
        printf 'VICTIM%04d' "$i" | dd of="$MNT/$1" bs=4096 seek="$i" count=1 conv=notrunc 2>/dev/null
        [ "$i" -lt 4 ] && printf x >"$MNT/${1}_f$i"
    done
    sync "$MNT/$1"
}

# probe <file> <stamp: yes|no>: read block 0, repoint it (and with
# "yes" stamp file_seq as node 1's publish), read it again on the same fd.
probe() {
    local file="$1" stamp="$2" ino ready go out pid i
    ino="$(stat -c '%i' "$MNT/$file")"
    ready="$(mktemp -u /tmp/cetrafs-rct-ready-XXXXXX)"
    go="$(mktemp -u /tmp/cetrafs-rct-go-XXXXXX)"
    out="$(mktemp /tmp/cetrafs-rct-out-XXXXXX)"
    "$PROBE" "$MNT/$file" "$ready" "$go" ro >"$out" 2>&1 &
    pid=$!
    for i in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.1; done
    "$LEAF_POKE" "$IMG" setphys "$ino" 0 "$DONOR_PHYS" >/dev/null
    [ "$stamp" = yes ] && "$REC_POKE" "$IMG" peerseq "$ino" 1 2>/dev/null
    # Past the once-a-second stamp check, so case 3 measures the stamp
    # and not the clock.
    sleep 1.5
    : >"$go"
    wait "$pid" 2>/dev/null || true
    READ1="$(sed -n 's/^read1 //p' "$out")"
    READ2="$(sed -n 's/^read2 //p' "$out")"
    rm -f "$ready" "$go" "$out"
}

log "2. a held read-only fd keeps its cached map while the stamp is unchanged"
build_victim v2
probe v2 no
[ "$READ1" = VICTIM0000 ] || fail "setup: first read was '$READ1', expected VICTIM0000"
[ "$READ2" = VICTIM0000 ] &&
    pass "unchanged stamp: the reader mapped from its cache (poke not seen)" ||
    fail "unchanged stamp: the reader read '$READ2' -- it went to the device for its map"

ct_param_set read_trust_off 1
build_victim v2c
probe v2c no
ct_param_set read_trust_off 0
[ "$READ2" = DONORDONOR ] &&
    pass "control: with read_trust_off the same reader sees the poke (the probe discriminates)" ||
    fail "control: read_trust_off read '$READ2', expected DONORDONOR -- case 2 proves nothing"

log "3. a peer's file_seq stamp sends the reader fresh"
build_victim v3
probe v3 yes
[ "$READ1" = VICTIM0000 ] || fail "setup: first read was '$READ1', expected VICTIM0000"
[ "$READ2" = DONORDONOR ] &&
    pass "peer stamp: the held reader re-mapped block 0 from the device" ||
    fail "peer stamp: the reader read '$READ2' through a map the peer had changed (frozen extent tree)"

ct_param_set read_trust_ignore_stamp 1
build_victim v3c
probe v3c yes
ct_param_set read_trust_ignore_stamp 0
[ "$READ2" = VICTIM0000 ] &&
    pass "control: ignoring the stamp leaves the reader on its stale map (case 3 discriminates)" ||
    fail "control: read_trust_ignore_stamp read '$READ2' -- something else refreshed the map, case 3 proves nothing"

# ---------------------------------------------------------------- 4
log "4. defrag refuses a file a live peer has open for read"
for i in 0 1 2 3 4 5 6; do
    dd if=/dev/urandom of="$MNT/frag" bs=4096 seek="$i" count=1 conv=notrunc status=none
    [ "$i" -lt 6 ] && printf x >"$MNT/frag_f$i"
done
sync "$MNT/frag"
FRAG_INO="$(stat -c '%i' "$MNT/frag")"
FRAG_SUM="$(sha256sum "$MNT/frag" | cut -d' ' -f1)"

umount "$MNT"
"$LOCK_POKE" "$DEV" "$FRAG_INO" --reader 1 >/dev/null
ct_mount "$DEV" "$MNT"
# After the mount, as read_presence.sh explains: a row nobody has watched
# yet reads alive.
"$NODE_POKE" "$DEV" 1 1 cc "$(date +%s)" >/dev/null
# defrag.cetra opens the file for write, which the access rule already
# refuses past a live reader (access_rule.sh). Turn that off for both
# arms, so defrag's own check is the only thing that can refuse here.
ct_param_set lock_ignore_readers 1

OUT="$("$ROOT/userspace/defrag.cetra" "$MNT/frag" 2>&1 || true)"
log "defrag.cetra: $OUT"
if echo "$OUT" | grep -qE '[1-9][0-9]* blocks moved'; then
    fail "defrag moved blocks of a file a live peer has open for read"
else
    pass "defrag declined: a live peer has the file open for read"
fi

ct_param_set defrag_ignore_readers 1
OUT="$("$ROOT/userspace/defrag.cetra" "$MNT/frag" 2>&1 || true)"
ct_param_set defrag_ignore_readers 0
ct_param_set lock_ignore_readers 0
echo "$OUT" | grep -qE '[1-9][0-9]* blocks moved' &&
    pass "control: with the check off the same defrag moves blocks (case 4 discriminates)" ||
    fail "control: defrag_ignore_readers still moved nothing ($OUT) -- case 4 proves nothing"
[ "$(sha256sum "$MNT/frag" | cut -d' ' -f1)" = "$FRAG_SUM" ] ||
    fail "frag content changed across the control defrag"

# No fsck at the end: cases 2 and 3 repoint four files at the donor's
# block on purpose, which fsck rightly calls a cross-file overlap.
"$NODE_POKE" "$DEV" 1 0 cc 0 >/dev/null 2>&1 || true
umount "$MNT"

ct_exit
