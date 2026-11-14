#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a live grow is published only under the caller's OWN growfs claim, not any growfs row
#
# CETRAFS_IOC_GROW used to ask "is there some growfs row in REPAIR?".
# Any CAP_SYS_ADMIN program holding no claim, or a claim that belonged to
# someone else, passed that check and published a superblock (audit L8).
# The ioctl now carries the claim it was made under -- the registry row
# and the nonce growfs wrote into that row -- and the kernel publishes
# only while that row still carries that nonce.
#
# The stranger's claim is forged into a free registry row of a mounted
# volume (node_poke), with a nonce this suite then forgets. The probe
# (grow_claim_probe) presents the superblock the device holds, unchanged,
# so nothing is published whatever the verdict: a claim that passes
# fails with -ESTALE ("no longer the one growfs read"), one refused
# fails with -EBUSY before the superblock is looked at.
#
#  A. a probe presenting a WRONG nonce for the row is refused (-EBUSY)
#  B. a probe naming the right row with the owner's nonce passes the
#     claim check (-ESTALE): the identity path accepts its owner
#  C. a probe naming some OTHER row, which is no claim, with the owner's
#     nonce is refused (-EBUSY)
#  D. nothing was published by any of the above (block 0 and layout_gen
#     unchanged)
#  E. control: the TEST ONLY grow_claim_any knob restores the old
#     presence check, and the stranger's probe is then accepted (-ESTALE)
#
# DISCRIMINATION: A is the assertion the old check fails -- with
# grow_claim_any=1 (E) the same probe is accepted. GROW_CLAIM_NEGATIVE=1
# sets that knob before A, and the suite must then FAIL at A: it is the
# negative control, run by hand (tests/README.md, "Prove the assertion
# discriminates").
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
PROBE="$(ct_helper grow_claim_probe)"

IMG="$(ct_image 560 growown)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt growown)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ROW=3

ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/data" bs=1M count=2 conv=fsync status=none

hex_nonce() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n'; }
OWNER="$(hex_nonce)"
STRANGER="$(hex_nonce)"
[ "$OWNER" != "$STRANGER" ] || { skip "no entropy for two nonces"; ct_exit; }

# The stranger's claim: row 3 in REPAIR, labelled as growfs writes it,
# carrying the owner's nonce. Written while mounted, then the device
# cache is dropped so the kernel's next registry read sees it.
"$NPOKE" "$IMG" "$ROW" 2 00 "$(date +%s)" >/dev/null
"$NPOKE" "$IMG" "$ROW" --label0 growfs >/dev/null
"$NPOKE" "$IMG" "$ROW" --uuid "$OWNER" >/dev/null
blockdev --flushbufs "$DEV"
state="$("$NPOKE" "$IMG" "$ROW")"
case "$state" in *state=2*) ;; *) fail "setup: the planted claim row did not land: $state"; ct_exit ;; esac

sb_sum() { dd if="$DEV" bs=4096 count=1 iflag=direct status=none | md5sum; }
layout() { sed -n 's/^layout_gen: //p' "$(ct_procdir "$DEV")/info"; }
probe() { # <row> <nonce> -> the probe's line on stdout; its status in $PRC
    PRC=0
    "$PROBE" "$MNT" "$DEV" "$1" "$2" 2>&1 || PRC=$?
}

SUM0="$(sb_sum)"; GEN0="$(layout)"

if [ "${GROW_CLAIM_NEGATIVE:-0}" = 1 ]; then
    log "NEGATIVE: the TEST ONLY knob restores the presence check before A"
    ct_param_set grow_claim_any 1
fi

log "A: a stranger's nonce for the claimed row is refused"
MARK="$(dmesg_mark)"
out="$(probe "$ROW" "$STRANGER")"
if grep -q 'errno=16 ' <<<"$out" && grep -q 'no growfs claim of this caller' <<<"$(dmesg_since "$MARK")"; then
    pass "A: refused with -EBUSY, for want of the caller's own claim"
else
    fail "A: the stranger's claim was not refused as someone else's: $out"
fi

log "B: the owner's nonce for the claimed row passes the claim check"
out="$(probe "$ROW" "$OWNER")"
if grep -q 'errno=116 ' <<<"$out"; then
    pass "B: passed the claim check and failed later with -ESTALE (the probe's superblock is not a grow)"
else
    fail "B: the owner's identity was not accepted: $out"
fi

log "C: the owner's nonce under another row (no claim there) is refused"
out="$(probe 0 "$OWNER")"
grep -q 'errno=16 ' <<<"$out" && pass "C: refused with -EBUSY" || fail "C: a row that is no claim was accepted: $out"

log "D: nothing was published"
[ "$(sb_sum)" = "$SUM0" ] && [ "$(layout)" = "$GEN0" ] &&
    pass "D: block 0 and layout_gen are unchanged ($GEN0)" || fail "D: a refused or stale grow changed the superblock or the layout"

log "E: control -- the old presence check accepts the stranger's claim"
ct_param_set grow_claim_any 1
out="$(probe "$ROW" "$STRANGER")"
if grep -q 'errno=116 ' <<<"$out"; then
    pass "E: with the TEST knob on, the stranger's claim is accepted (-ESTALE) -- A tests what the knob removes"
else
    fail "E: control -- the stranger's claim was not accepted with the knob on: $out"
fi
ct_param_set grow_claim_any 0

# Leave the registry as it was: the planted row goes back to FREE.
"$NPOKE" "$IMG" "$ROW" 0 00 0 >/dev/null
blockdev --flushbufs "$DEV"
ct_umount "$MNT"
out="$(ct_fsck "$DEV" 2>&1)" && pass "fsck is clean after the probes" ||
    fail "fsck: $(grep -m3 -iE 'err|bad|corrupt' <<<"$out" | tr '\n' ' ')"
ct_exit
