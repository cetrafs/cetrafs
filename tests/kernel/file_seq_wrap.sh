#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a refresh orders this node's own file_seq stamps across the 48-bit wrap
#
# file_seq's low 48 bits are nanoseconds, which wrap every ~3.26 days.
# The refresh behind stat and lookup refuses a record carrying an OWN
# stamp older than the publish this node last noted -- applying it
# would revert in-core state -- and it decided "older" with a plain
# '<'. After a wrap every newer own stamp compares older, so a record a
# local publisher had moved on (a background defrag, a staged release,
# writeback) was refused, and in-core stayed stale until the next close.
# The real clock stepping backward did the same; stamps now come from a
# per-mount clock that never does.
#
# Staged: this node's publish is stamped at the top of the range
# (file_seq_force_val); then the record is rewritten on the device with
# a larger size and the next own stamp, which wraps to 0. A stat must
# show the new size.
#
# DISCRIMINATION: with the compare back to a plain '<', the stat shows
# the old size.
#
# And ordering modulo the wrap is right only while two stamps are less
# than HALF a wrap apart: a publish noted ~1.63 days before a newer
# local one had the newer one judged older (audit L25). The last round
# notes a publish stamped more than half a wrap ago
# (file_seq_force_age_ns), then a local publisher that does not note
# (file_seq_skip_note) stamps a newer one; the device's size is moved on
# under it. Against the half-wrap compare the stat shows the old size.
#
# NOT COVERED: the backward step itself (cetrafs_sb_stamp_ns()). Staging
# it means stepping the test box's real clock under everything else
# running there; the per-mount clock is monotonic by construction, and
# this suite proves only the ordering it feeds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/file_seq_force_val ] || { skip "file_seq_force_val is missing"; ct_exit; }
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 seqwrap)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt seqwrap)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NODE="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"

# round <name> <value>: publish stamped <value>, then an own-node stamp
# one past it lands on the device with the size raised.
round() {
    local name="$1" val="$2" F="$MNT/f.$1" INO SZ
    ct_param_set file_seq_force_val "$val"
    dd if=/dev/zero of="$F" bs=4096 count=2 conv=fsync status=none
    sync
    ct_param_set file_seq_force_val 0
    INO="$(stat -c %i "$F")"
    "$POKE" "$IMG" setsize "$INO" 16384 2>/dev/null
    "$POKE" "$IMG" peerseq "$INO" "$NODE" 2>/dev/null
    SZ="$(stat -c %s "$F")"
    [ "$SZ" = 16384 ] &&
        pass "$name: the newer own stamp was applied (size $SZ)" ||
        fail "$name: the newer own stamp was refused as superseded (size $SZ, want 16384)"
}

# Below the top: no wrap, the plain case must keep working.
round plain 1000
# At the top: the next stamp wraps to 0.
round wrap 281474976710655

# More than half a wrap between our note and a newer own stamp.
F="$MNT/f.halfwrap"
ct_param_set file_seq_force_age_ns $(( (1 << 47) + 1000000000000 ))
dd if=/dev/zero of="$F" bs=4096 count=2 conv=fsync status=none
sync
ct_param_set file_seq_force_age_ns 0
ct_param_set file_seq_skip_note 1
truncate -s 12288 "$F"
sync
ct_param_set file_seq_skip_note 0
INO="$(stat -c %i "$F")"
SEQ="$("$POKE" "$IMG" seq "$INO" 2>&1 | head -1)"
"$POKE" "$IMG" setsize "$INO" 16384 2>/dev/null
SZ="$(stat -c %s "$F")"
log "halfwrap: record after the un-noted publish: $SEQ"
[ "$SZ" = 16384 ] &&
    pass "halfwrap: an own stamp newer by more than half a wrap was applied (size $SZ)" ||
    fail "halfwrap: an own stamp newer by more than half a wrap was refused as superseded (size $SZ, want 16384)"

ct_umount "$MNT"
ct_exit
