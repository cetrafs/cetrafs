#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node whose row another incarnation with its UUID has taken over stops, and does not mark that row departed
#
# A node with our UUID -- a clone, a host reinstalled with the same
# machine id -- that finds our row silent for a window re-attaches to it:
# same UUID, same fence_epoch, a new incarnation. When the stalled
# original resumed, its renewal, its own fence check, its frees flag and
# its departure at unmount compared state, UUID and epoch -- all still
# matching -- and never the incarnation, so it went on beating and
# writing beside the node that now held its row, and its unmount wrote
# "departed" over that node's live row. On a volume with no atomic CAW
# no lease runs out for it either (audit 2026-11-11 N2).
#
# Played on one node: our row's incarnation is rewritten under the mount,
# as the re-attach would.
#
#  1. the next heartbeat fences the mount (it says its row is no longer
#     its own), and a write fails.
#  2. the unmount leaves the row as the other incarnation holds it: not
#     departed.
#  3. CONTROL: a change to a field that is not the row's identity (its
#     label) fences nothing.
#
# DISCRIMINATION (2026-11-11, the incarnation compares removed): 1 keeps
# beating and writing, 2 finds the row marked departed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 rowtk)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt rowtk)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
compress_timing

field() { blockdev --flushbufs "$DEV"; "$POKE" "$DEV" 0 | sed -n "s/.* $1=\\([0-9]*\\).*/\\1/p"; }

# ------------------------------------------------------------------- 3
log "3: CONTROL -- a non-identity field changes under the mount"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
blockdev --flushbufs "$DEV"
"$POKE" "$DEV" 0 --label other >/dev/null
sleep 4 # several ticks
dmesg_since "$MARK" | grep -q "SELF-FENCED" && fail "3: a label change fenced the mount" ||
    pass "3: a label change fences nothing"
echo ok >"$MNT/c" && sync && pass "3: and the mount still writes" || fail "3: the mount stopped writing"
ct_umount "$MNT"

# ------------------------------------------------------------------- 1
log "1: our row taken over by another incarnation with our UUID"
MARK="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
INC="$(field incarnation)"
[ -n "$INC" ] || { fail "setup: cannot read our row's incarnation"; ct_exit; }
"$POKE" "$DEV" 0 --inc $((INC + 1)) >/dev/null
blockdev --flushbufs "$DEV"
wait_for 10 "dmesg_since '$MARK' | grep -q 'SELF-FENCED'" &&
    pass "1: the mount found its row is no longer its own, and fenced" ||
    fail "1: the mount went on beating on a row another incarnation holds"
if echo x >"$MNT/after" 2>/dev/null && sync "$MNT/after" 2>/dev/null; then
    fail "1: a write still succeeded after the takeover"
else
    pass "1: and a write fails"
fi

# ------------------------------------------------------------------- 2
umount "$MNT" 2>/dev/null || umount -l "$MNT"
[ "$(field departure)" = 0 ] && [ "$(field incarnation)" = $((INC + 1)) ] &&
    pass "2: the unmount left the other incarnation's row as it was (not departed)" ||
    fail "2: the displaced node's unmount wrote over the row it lost (departure $(field departure), incarnation $(field incarnation))"
ct_exit
