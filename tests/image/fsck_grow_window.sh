#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a grow interrupted between its publish and its Zone Group credits is fsck-clean; any other lag is not
#
# growfs publishes the superblock first and credits the Zone Groups
# after it (growfs.c, "After the publish"). A crash in between leaves
# each Zone Group's free count short by exactly its share of the last
# grow's Block Groups -- capacity the superblock already counts. The
# mount reconciles it, and the crash cut suite (tests/crash/growfs_crash.sh)
# found fsck calling that state damage at two of its cuts. fsck now
# accepts that one lag, as a note, when it is exact, the Block Groups
# are untouched, and it is lower rather than higher.
#
#  1. a grow that stops before the credits: fsck is clean, says so, and
#     names the lag.
#  2. control: that Zone Group's count one block LOWER than the lag:
#     fsck refuses it -- the acceptance is exact, not "some lag".
#  3. control: one block HIGHER: refused -- the direction counts too.
#
# DISCRIMINATION: before the fix, case 1 read "ERR: ZG0 aggregate ...
# != ... actually free" and exited 1; cases 2 and 3 were refused then
# too, so they guard the tolerance against being widened.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
POKE="$(ct_helper zg_poke)"

IMG="$(ct_image 1200 growwin)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -s 600M -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
ct_fsck "$DEV" >/dev/null 2>&1 && pass "setup: a fresh two-Zone-Group volume is clean" ||
    { fail "setup: a fresh volume is not clean"; ct_exit; }

OUT="$(CETRAFS_GROWFS_TEST_NO_AGGREGATE=1 "$ROOT/userspace/growfs.cetra" "$DEV" -s 1200M 2>&1)" ||
    { fail "setup: the grow failed: $(tail -1 <<<"$OUT")"; ct_exit; }

# The grow published, and the credits were never written: the lag is real
# and the note must name it. The Zone Group whose lag it names, and the
# size of that lag, are what the controls below are built on.
LINE="$(ct_fsck "$DEV" 2>&1 || true)"
NOTE="$(grep -m1 'does not yet include' <<<"$LINE" || true)"
if [ -z "$NOTE" ]; then
    fail "setup: fsck does not see the uncredited grow: $(grep -m1 'ERR' <<<"$LINE" || echo "$LINE" | head -1)"
    ct_exit
fi
Z="$(sed -n 's/^note: Zone Group \([0-9]*\)'"'"'s free count.*/\1/p' <<<"$NOTE")"
SHARE="$(sed -n 's/.* the \([0-9]*\) blocks of the Block Groups.*/\1/p' <<<"$NOTE")"
[ -n "$Z" ] && [ -n "$SHARE" ] && [ "$SHARE" -gt 0 ] || { fail "setup: cannot read the lag from the note: $NOTE"; ct_exit; }

ct_fsck "$DEV" >/dev/null 2>&1 && pass "1: a grow that published and stopped before its credits fsck clean, naming the lag on Zone Group $Z ($SHARE blocks)" ||
    fail "1: fsck refuses the interrupted grow it should accept"

# The stored count, and so the lag it implies, read off the device.
STORED="$("$POKE" "$DEV" "$Z" | sed -n 's/.*free_data_blocks=//p')"
[ -n "$STORED" ] || { fail "setup: zg_poke cannot read Zone Group $Z"; ct_exit; }
TRUTH=$((STORED + SHARE))

"$POKE" "$DEV" "$Z" free $((STORED - 1)) >/dev/null
if ct_fsck "$DEV" >/dev/null 2>&1; then
    fail "2: fsck accepts a count one block below the lag -- the acceptance is not exact"
else
    pass "2: control: one block more lag than the grow's share is refused"
fi
"$POKE" "$DEV" "$Z" free $((TRUTH + 1)) >/dev/null
if ct_fsck "$DEV" >/dev/null 2>&1; then
    fail "3: fsck accepts a count one block ABOVE the truth -- a high count must never be tolerated"
else
    pass "3: control: a count above the truth is refused, whatever the share"
fi

# And the value the grow would have written is accepted again, so the
# controls above are not refusing for an unrelated reason.
"$POKE" "$DEV" "$Z" free "$STORED" >/dev/null
ct_fsck "$DEV" >/dev/null 2>&1 && pass "the restored lag is accepted again (the controls failed for the stated reason)" ||
    fail "the restored lag is refused: the controls above proved nothing"

losetup -d "$DEV" 2>/dev/null || true
ct_exit
