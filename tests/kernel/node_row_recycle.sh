#!/usr/bin/env bash
# a new machine takes over a row whose machine left cleanly, when no row is free
#
# Registration claimed a FREE row, or re-attached a row carrying its own
# identity, and nothing else. A volume whose rows had all been used once
# refused every new machine for good ("registry full"), and no tool
# forgets a departed node (audit O11). A row whose machine departed
# CLEANLY -- its claims released, its journal parked -- may now be taken
# over, and only when no FREE row is left.
#
# Staged on a four-row registry (-M 4):
#  1. control: every row belongs to a machine that is stale but did not
#     leave (departure NONE). Nothing may be taken: the mount is refused.
#  2. every row belongs to a machine that left cleanly (departure CLEAN).
#     The mount must take one over, and the row must read as this node's.
#
# DISCRIMINATION: with no takeover (the pre-fix registration) case 2 is
# refused with "found none free", the same as case 1.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 noderecyc)"
MNT="$(ct_mnt noderecyc)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_track mnt "$MNT"
ct_param_set stale_secs 15 # before the pokes: the rows carry the window they are planted with

plant_all() { # plant_all <last_seen>: every row a different machine, all with the given last_seen
    local r
    for r in 0 1 2 3; do
        "$NPOKE" "$DEV" "$r" 1 "$((r + 17))" "$1" >/dev/null || return 1
    done
}
row0() { "$NPOKE" "$DEV" 0 2>&1; }

# ------------------------------------------------------------------- 1
plant_all 1 || { fail "setup: could not plant four live-looking rows"; ct_exit; }
blockdev --flushbufs "$DEV"
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
    ct_umount "$MNT"
    C1=mounted
else
    C1=refused
fi
dmesg_since "$MARK" | grep -q "found none free" &&
    pass "1: control: with no free row and no departed row the registration is refused" ||
    fail "1: control: the registration did not report that no row was free (mount: $C1)"
[ "$C1" = refused ] || { fail "1: control: a mount took a row that belonged to a live machine"; }

# ------------------------------------------------------------------- 2
plant_all 0 || { fail "setup: could not plant four departed rows"; ct_exit; }
[ "$(row0 | sed -n 's/.* departure=\([0-9]*\).*/\1/p' | head -1)" = 1 ] ||
    { fail "setup: the planted row is not a clean departure"; ct_exit; }
blockdev --flushbufs "$DEV"
MARK="$(dmesg_mark)"
if mount -t cetrafs "$DEV" "$MNT"; then
    MOUNTED=1
else
    MOUNTED=0
fi
dmesg_since "$MARK" | grep -q "claimed row" && CLAIMED=1 || CLAIMED=0
[ "$MOUNTED" = 1 ] && pass "2: a new machine mounts on a volume whose rows all belong to departed machines" ||
    { fail "2: the mount was refused although every row had left cleanly"; ct_exit; }
[ "$CLAIMED" = 1 ] && pass "2: and it claimed a row" || fail "2: no claim was logged"
ROW="$(row0)"
ct_umount "$MNT"
grep -q "state=1 " <<<"$ROW" && grep -q " departure=0 " <<<"$ROW" &&
    pass "2: the taken-over row reads as registered to this node (state=1, departure=0)" ||
    fail "2: row 0 after the takeover: $ROW"
ct_exit
