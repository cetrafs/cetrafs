#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a group held for an outstanding discard is released on the operator's word
#
# An emptied Block Group whose hand-back UNMAP had an unknown outcome is
# kept out of use until a discard of it has a known one: the UNMAP may
# still land (discard_unknown_outcome.sh C). A device that stopped taking
# discards never gives one, and discard=off does not cancel a command
# already sent, so the group stayed out of use for good with no way for
# an operator to let it go (audit 2026-11-15 BM-48). release_discards=now
# in controls is that way: the operator's word that no earlier UNMAP can
# still land.
#
# Staged as discard_unknown_outcome.sh C, every discard failing unknown
# throughout:
#   A. kept across several passes (the control: nothing else releases
#      it), then release_discards=now -- handed back by the next pass,
#      with no discard of it succeeding, and fsck clean;
#   B. release_discards=now BEFORE the group is pending: a group marked
#      after the word is not covered -- still kept.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in discard_fail_unknown; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
BGPOKE="$(ct_helper bg_poke)"
IMG="$(ct_big_image 1200 dwaive)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt dwaive)"
ct_track mnt "$MNT"
[ "$(cat "/sys/block/$(basename "$DEV")/queue/discard_max_bytes")" != 0 ] ||
    { skip "this loop device takes no discards (backing fs?)"; ct_exit; }
ct_param_set scrub 0
ct_param_set auto_defrag 0
compress_timing
PROC="$(ct_procdir "$DEV")"
info() { awk -v k="$1:" '$1 == k { print $2 }' "$PROC/info"; }

# Fill Block Group 0 (it holds the root), put 96 MiB in group 1, delete
# it with every discard failing unknown. <before-rm hook>.
stage() {
    local free i
    ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    PROC="$(ct_procdir "$DEV")"
    ct_umount "$MNT"
    free="$("$BGPOKE" "$DEV" 0 --dump | sed -n 's/.*free_data_blocks=\([0-9]*\).*/\1/p')"
    ct_mount "$DEV" "$MNT"
    fallocate -l $(((free - 256) * 4096)) "$MNT/pad"
    mkdir "$MNT/bulk"
    for i in 1 2 3; do dd if=/dev/urandom of="$MNT/bulk/f$i" bs=1M count=32 conv=fsync status=none; done
    sync
    HB0="$(info discard_handback_bgs)"
    MARK="$(dmesg_mark)"
    ct_param_set discard_fail_unknown 1000000
    [ -z "${1:-}" ] || "$1"
    rm -rf "$MNT/bulk"
    sync
    wait_for 30 "dmesg_since '$MARK' | grep -q 'hand-back discard failed and may still execute'" ||
        { fail "setup: no hand-back discard failed unknown"; ct_exit; }
}
handed_back() { dmesg_since "$MARK" | grep -q "handed back from ZG"; }
waive() { echo "release_discards=now" >"$PROC/controls"; }

log "A: kept, then released on the operator's word"
stage
sleep 4 # several passes, each failing again
handed_back && fail "A control: handed back with no word and no known outcome" ||
    pass "A control: kept across several failing passes -- nothing else releases it"
[ "$(info discard_pending_bgs)" -ge 1 ] || { fail "A setup: no group recorded as pending"; ct_exit; }
waive
wait_for 30 handed_back && pass "A: release_discards=now -- the next pass handed it back" ||
    fail "A: still kept after the operator's word"
dmesg_since "$MARK" | grep -q "waived by the operator" && pass "A: and says it went back untrimmed, on the word" ||
    fail "A: released without saying why"
[ "$(info discard_handback_bgs)" = "$HB0" ] && pass "A: no discard of it succeeded -- the word released it" ||
    fail "A: a discard succeeded meanwhile ($(($(info discard_handback_bgs) - HB0))) -- the case is not the word's"
ct_param_set discard_fail_unknown 0
[ "$(info discard_pending_bgs)" = 0 ] && pass "A: nothing is held any more" ||
    fail "A: $(info discard_pending_bgs) group(s) still held"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1)" && pass "A: fsck clean" || fail "A: fsck: $(grep -m3 -E '^ERR' <<<"$OUT")"

log "B: a group pending after the word is not covered"
stage waive
sleep 4
handed_back && fail "B: a group marked after the word was released by it" ||
    pass "B: the word covers only what was pending when it was given"
ct_param_set discard_fail_unknown 0
ct_umount "$MNT"
ct_exit
