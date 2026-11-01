#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a defrag step whose publish reports failure but landed frees nothing the record names
#
# Each defrag step publishes the new extent tree with a compare-and-swap
# and, on failure, frees the new tree's metadata and the destination
# blocks it had copied into. A failure is not proof the swap did not
# land: a CAS whose timeout cannot be settled (its verify re-read fails,
# or the region changed meanwhile) returns an error with its outcome
# unknown. Freeing on the strength of the error alone leaves a record
# naming blocks the allocator reads as FREE -- the next file to
# allocate gets the defragmented file's data.
#
# The knob makes one publish land and then report -EIO.
#
# DISCRIMINATION (measured on the unfixed code): after the volume is
# filled, the defragmented file's content has been overwritten by a
# later file's data.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 900 dpu)"
MNT="$(ct_mnt dpu)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0

log "building a 160-extent file"
SRC="$(ct_tmp dpu-src)"
BLK="$(ct_tmp dpu-blk)"
: >"$SRC"
for i in $(seq 0 159); do
    dd if=/dev/urandom of="$BLK" bs=4096 count=1 status=none
    cat "$BLK" >>"$SRC"
    dd if="$BLK" of="$MNT/fragfile" bs=4096 seek="$i" count=1 conv=notrunc status=none
    [ "$i" -lt 159 ] && printf x >"$MNT/filler$i"
done
sync
SUM_BEFORE="$(sha256sum "$SRC" | cut -d' ' -f1)"

MARK="$(dmesg_mark)"
ct_param_set defrag_publish_lost_ack 1
OUT="$("$ROOT/userspace/defrag.cetra" "$MNT/fragfile" 2>&1)" || true
ct_param_set defrag_publish_lost_ack 0
log "defrag: $(tr '\n' ' ' <<<"$OUT")"
[ "$(cat /sys/module/cetrafs/parameters/defrag_publish_lost_ack)" = N ] &&
    pass "setup: the injected publish failure was consumed -- a step reached it" ||
    { fail "setup: no defrag step reached the publish"; ct_exit; }

echo 3 >/proc/sys/vm/drop_caches
[ "$(sha256sum "$MNT/fragfile" | cut -d' ' -f1)" = "$SUM_BEFORE" ] && pass "content intact from disk" ||
    fail "content WRONG after the step whose publish was reported failed"

log "forcing reuse of anything defrag wrongly freed"
n=0
while dd if=/dev/urandom of="$MNT/reuse_$n" bs=1M count=4 status=none 2>/dev/null; do
    n=$((n + 1)); [ "$n" -gt 40 ] && break
done
sync
echo 3 >/proc/sys/vm/drop_caches
[ "$(sha256sum "$MNT/fragfile" | cut -d' ' -f1)" = "$SUM_BEFORE" ] &&
    pass "content still intact after the volume filled over freed space" ||
    fail "a later allocation overwrote the file's blocks: defrag freed what the record names"

ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
if grep -q '^ERR' <<<"$out"; then
    fail "fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -2)"
else
    pass "fsck: no errors (rc=$rc; a leak would be the accepted cost of an unknown outcome)"
fi
ct_exit
