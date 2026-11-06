#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# dropping a cold extent tree reads and drops only addresses inside the data regions
#
# When a peer's publish makes this node's cached extent tree cold, the
# reconcile walks the record's root, force-reads each interior and drops
# every block it names. Those addresses came off the disk and were used
# unchecked (rule 19): a damaged root aimed a forced read and a stream of
# invalidations at whatever it named (audit 2026-11-06 L20).
#
# Staged on a live mount: a file's record is rewritten as depth 2 with
# its root slot naming a block past the end of the device, stamped as a
# peer's publish, and the file is opened. The reconcile must not issue
# that read. A read past the end of the device fails without a word in
# dmesg, so a kprobe on cetrafs_bread_uncached() filtered on that block
# is the instrument; the suite skips where kprobes are unavailable.
#
# DISCRIMINATION: without the address check the reconcile reads past
# the end of the device.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IBP="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 treeaddr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt treeaddr)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
dd if=/dev/urandom of="$MNT/v" bs=4096 count=1 conv=fsync status=none
sync
INO="$(stat -c %i "$MNT/v")"
cat "$MNT/v" >/dev/null
BAD=$(( $(blockdev --getsz "$DEV") / 8 + 4096 ))
drops() { sed -n 's/^file_cache_drops: //p' "$(ct_procdir "$DEV")/info"; }
D0="$(drops)"
"$IBP" "$IMG" idxaddr "$INO" 0 "$BAD" 2>/dev/null
"$IBP" "$IMG" peerseq "$INO" 1 2>/dev/null
T=/sys/kernel/tracing
# A kprobe records nothing with tracing switched off, which would read as
# "no hits": say so instead of passing.
[ "$(cat "$T/tracing_on" 2>/dev/null)" = 1 ] || { skip "tracing is off (tracing_on != 1): a kprobe would record nothing"; ct_exit; }
EV=cetrafs_l20_$$
kp_off() {
    echo 0 >"$T/events/kprobes/$EV/enable" 2>/dev/null || true
    echo "-:kprobes/$EV" >>"$T/kprobe_events" 2>/dev/null || true
}
echo "p:kprobes/$EV cetrafs:cetrafs_bread_uncached blk=\$arg2:u64" >>"$T/kprobe_events" 2>/dev/null ||
    { skip "cannot place a kprobe on cetrafs_bread_uncached"; umount "$MNT"; ct_exit; }
echo "blk == $BAD" >"$T/events/kprobes/$EV/filter"
: >"$T/trace"
echo 1 >"$T/events/kprobes/$EV/enable"
cat "$MNT/v" >/dev/null 2>&1 || true
cat "$MNT/v" >/dev/null 2>&1 || true
sleep 2
D1="$(drops)"
HITS="$(grep -c "$EV:" "$T/trace" || true)"
kp_off
[ -n "$D0" ] && [ "$D1" -gt "$D0" ] ||
    { fail "setup: the peer's stamp never made the tree cold (file_cache_drops $D0 -> $D1)"; kp_off; umount "$MNT"; ct_exit; }
pass "setup: the peer's stamp made the tree cold"
[ "$HITS" != 0 ] &&
    fail "the reconcile force-read block $BAD, past the end of the device ($HITS read(s))" ||
    pass "the reconcile issued no read at the out-of-range address $BAD"
umount "$MNT" # the record is damaged on purpose: no fsck
ct_exit
