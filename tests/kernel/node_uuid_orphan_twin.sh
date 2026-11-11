#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# an orphan row with this machine's identity does not hide a live twin's row
#
# Registration re-attaches to a row carrying this machine's UUID, after
# watching it if it was not left cleanly (node_uuid_twin.sh). It took
# the FIRST such row and looked no further. A registration whose
# give-back failed leaves its fresh row behind with our UUID, and an
# orphan like that at a lower index than a live twin's row was watched,
# found quiet and re-attached -- the twin's beating row never looked at,
# the two machines then one node (audit 2026-11-11 N6).
#
#  A. row 0 an orphan (ours, not left cleanly, silent), row 1 a twin
#     beating with the same identity: the mount is refused.
#  B. the twin gone (row 1 silent too): the mount re-attaches.
#
# DISCRIMINATION (2026-11-11, node.c before this fix): A mounts.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"

DEV="$(ct_dev 560 orphtwin)"
MNT="$(ct_mnt orphtwin)"
ct_mkfs_small "$DEV" >/dev/null
compress_timing
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT"
grep -q '^state=1 .*departure=1 ' <<<"$("$NODE_POKE" "$DEV" 0)" ||
    { fail "setup: row 0 is not ours: $("$NODE_POKE" "$DEV" 0)"; ct_exit; }

"$NODE_POKE" "$DEV" 1 --copy-from 0 >/dev/null
"$NODE_POKE" "$DEV" 0 --depart 0 >/dev/null
"$NODE_POKE" "$DEV" 1 --beat >/dev/null
grep -q '^state=1 .*departure=0 ' <<<"$("$NODE_POKE" "$DEV" 0)" &&
    grep -q '^state=1 .*departure=0 ' <<<"$("$NODE_POKE" "$DEV" 1)" &&
    pass "setup: rows 0 and 1 both carry this machine's identity, neither left cleanly" ||
    { fail "setup: $("$NODE_POKE" "$DEV" 0) / $("$NODE_POKE" "$DEV" 1)"; ct_exit; }

log "A: row 0 an orphan, row 1 a beating twin"
( for _ in $(seq 1 60); do "$NODE_POKE" "$DEV" 1 --beat >/dev/null 2>&1 || true; sleep 1; done ) &
TWIN=$!
MARK="$(dmesg_mark)"
rc=0
mount -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$?
kill "$TWIN" 2>/dev/null || true
wait "$TWIN" 2>/dev/null || true
if [ "$rc" != 0 ] && grep -q "row 1 carries this machine's identity" <<<"$(dmesg_since "$MARK")"; then
    pass "A: refused -- row 1 is a live twin's"
else
    [ "$rc" = 0 ] && umount "$MNT"
    fail "A: mount rc=$rc -- an orphan row hid a twin beating on row 1"
fi

log "B: both rows silent"
"$NODE_POKE" "$DEV" 0 --depart 0 >/dev/null
if ct_mount "$DEV" "$MNT"; then
    pass "B: re-attached once no row beats"
    ct_umount "$MNT"
else
    fail "B: refused although nothing beats"
fi
ct_exit
