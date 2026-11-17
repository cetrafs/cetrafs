#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a rebuilt registry row takes back the incarnation its node's claims carry
#
# fsck -r rebuilds a damaged registry row as a dead node, and kept the
# damaged image's incarnation (audit 2026-11-15 F-51). A re-attach of
# that node draws a new incarnation that is "never the value the row held
# before" -- now the damaged value, not the real one -- so it could draw
# the real one, and an old claim of the node would read as the new
# mount's: a file busy until fsck. The claims the records carry still
# name the real value; the rebuild restores it from them.
#
# Row 1 is registered with incarnation 0x1235; the root's record carries
# a presence claim of node 1 stamped 4660 (0x1234) -- as if the row's
# incarnation had been damaged from 0x1234 -- and the row is then damaged
# (csum_poke). fsck -r must rebuild it with incarnation 4660.
#
# DISCRIMINATION: control -- the same without the claim: the row keeps
# the image's value, so the restore comes from the claim alone.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
POKE="$(ct_helper csum_poke)"
NODE_POKE="$(ct_helper node_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 560 rowinc)"
DEV="$(ct_loop "$IMG")"
OUTF="$(ct_tmp)"

# <claim 0|1> -> the rebuilt row's incarnation
round() {
    ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null
    "$NODE_POKE" "$DEV" 1 1 aa "$(date +%s)" >/dev/null
    "$NODE_POKE" "$DEV" 1 --inc 0x1235 >/dev/null
    [ "$1" = 0 ] || INODE_LOCK_POKE_INC=4660 "$LOCK_POKE" "$DEV" 1 --reader 1 >/dev/null
    "$POKE" "$DEV" node 1 >/dev/null
    blockdev --flushbufs "$DEV"
    "$FSCK" -r "$DEV" >"$OUTF" 2>&1 || true
    blockdev --flushbufs "$DEV"
    "$NODE_POKE" "$DEV" 1 | sed -n 's/.*incarnation=\([0-9]*\).*/\1/p' | head -1
}

F="$(round 1)"
OUT="$(cat "$OUTF")"
grep -q "rebuilt node slot 1" <<<"$OUT" || { fail "setup: row 1 was not rebuilt: $(grep -E 'ERR|slot 1' <<<"$OUT" | head -2 | tr '\n' ' ')"; ct_exit; }
[ "$F" = 4660 ] && grep -q "incarnation restored to 4660" <<<"$OUT" &&
    pass "the rebuilt row took back the incarnation its node's claim carries (4660)" ||
    fail "rebuilt with incarnation $F, not the claim's 4660"
C="$(round 0)"
[ "$C" != 4660 ] && pass "control: with no claim the row keeps the image's value ($C)" ||
    fail "control: 4660 without any claim -- the restore does not come from the claims"
ct_exit
