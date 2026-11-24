#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Zone Group in use keeps its empty Block Groups for the hand-back grace
#
# The heartbeat hands back every empty Block Group of an owned Zone Group.
# A node filling space fast -- a disk move into a sparse image -- claimed
# a Zone Group, had most of it handed back (and UNMAPped) at the next
# beat, filled the few groups it kept, ran out and claimed the next one:
# stop-and-go writes and a Zone Group's worth of UNMAP per cycle. A Zone
# Group this node claimed or allocated in now keeps its empty groups for
# handback_grace seconds (procfs controls, 30 .. 1800, default 150) and
# hands them back once the node has left it alone that long.
#
#   1. the controls show the default 150 and refuse 29 and 1801;
#   2. CONTROL, the test knob turning the grace off: the groups a deleted
#      directory emptied are handed back within a few beats -- the setup
#      does arrange a hand-back, so case 3 keeping them is the grace;
#   3. with handback_grace=30, a Zone Group just written to hands back
#      nothing for the first 15 s (15 beats of the 1 s test tick);
#   4. ...and hands them back once 30 s pass with no allocation in it;
#   5. fsck clean, kept file intact;
#   6. on a nearly full volume (nothing left a peer could claim) the
#      grace is waived: the same emptying hands back within 15 s even at
#      handback_grace=30 -- parked space there is a peer's ENOSPC.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

FREE_MARK=65535
MAP="$(ct_helper bg_map)"
DEV="$(ct_dev 3600 hbgrace)"
MNT="$(ct_mnt hbgrace)"
compress_timing

released() {
    local out
    out="$("$MAP" "$DEV")"
    awk -v f="$FREE_MARK" '/^bg /{split($3,a,"="); if (a[2]+0 == f+0) n++} END{print n+0}' <<<"$out"
}

# Fill through a directory, remove the directory whole (its dirent
# blocks with it), then write one small file -- an allocation in the
# Zone Group, the instant the grace counts from.
#   roomy: two Zone Groups, 1 GiB written into the one this node claims;
#          the other, unowned, is room a peer could take;
#   tight: one Zone Group, filled to ENOSPC; nothing left for a peer.
setup() { # roomy|tight
    local i=0 max
    if [ "$1" = roomy ]; then
        ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 2048 -f >/dev/null
        max=64
    else
        ct_mkfs "$DEV" -s 1800 -z 1 -b 512 -J 0 -N 2048 -f >/dev/null
        max=300
    fi
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    PROC="$(ct_procdir "$DEV")"
    mkdir -p "$MNT/bulk"
    while [ "$i" -lt "$max" ] && dd if=/dev/zero of="$MNT/bulk/f$i" bs=1M count=16 status=none 2>/dev/null; do
        i=$((i + 1))
    done
    sync
    [ "$i" -gt 8 ] || { fail "setup: only $i files written"; ct_exit; }
    if [ "$1" = roomy ]; then
        [ "$i" = "$max" ] || { fail "setup: roomy volume full after $i files"; ct_exit; }
    fi
}
empty_it() {
    rm -rf "$MNT/bulk"
    dd if=/dev/urandom of="$MNT/keep" bs=1M count=4 status=none
    sync
    sha_keep="$(sha256sum <"$MNT/keep")"
}

# ------------------------------------------------------------- 1. bounds
ct_param_set handback_grace_off 0
setup roomy
ctl="$(cat "$PROC/controls")"
grep -q '^handback_grace_secs: 150$' <<<"$ctl" &&
    pass "1: a new mount starts with the 150 s default" ||
    fail "1: the controls do not show handback_grace_secs: 150: $(grep handback <<<"$ctl")"
for bad in 29 1801 -1 abc; do
    if echo "handback_grace=$bad" >"$PROC/controls" 2>/dev/null; then
        fail "1: handback_grace=$bad was accepted"
    else
        pass "1: handback_grace=$bad refused"
    fi
done
for good in 1800 30; do
    echo "handback_grace=$good" >"$PROC/controls" 2>/dev/null &&
        ctl="$(cat "$PROC/controls")" && grep -q "^handback_grace_secs: $good\$" <<<"$ctl" &&
        pass "1: handback_grace=$good accepted and shown" ||
        fail "1: handback_grace=$good not applied"
done

# --------------------------------------- 3 and 4. the grace, at 30 s
empty_it
t0=$SECONDS
sleep 15
n="$(released)"
[ "$n" -eq 0 ] &&
    pass "3: within the grace (15 s after the last allocation) no Block Group was handed back" ||
    fail "3: $n Block Group(s) handed back $((SECONDS - t0)) s into a 30 s grace"
if wait_for 60 '[ "$(released)" -gt 0 ]'; then
    pass "4: after the grace the emptied Block Groups went back ($(released), $((SECONDS - t0)) s after the last allocation)"
    [ $((SECONDS - t0)) -ge 28 ] && pass "4: not before the 30 s were up" ||
        fail "4: handed back after $((SECONDS - t0)) s, inside a 30 s grace"
else
    fail "4: nothing handed back $((SECONDS - t0)) s after the last allocation -- the grace never ends"
fi
[ "$(sha256sum <"$MNT/keep")" = "$sha_keep" ] && pass "5: the kept file reads back intact" ||
    fail "5: the kept file changed"
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "5: clean after the grace run" ||
    fail "5: not clean: $(ct_fsck "$DEV" 2>&1 | grep -m1 ERR)"

# ------------------------------------- 6. a nearly full volume waives it
setup tight
echo "handback_grace=30" >"$PROC/controls"
empty_it
t0=$SECONDS
if wait_for 15 '[ "$(released)" -gt 0 ]'; then
    pass "6: with nothing left for a peer the grace is waived: $(released) Block Group(s) back within $((SECONDS - t0)) s"
else
    fail "6: a nearly full volume kept its emptied Block Groups through the grace -- a peer would read ENOSPC"
fi
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "6: clean" || fail "6: not clean: $(ct_fsck "$DEV" 2>&1 | grep -m1 ERR)"

# ---------------------------------------------- 2. control: grace off
ct_param_set handback_grace_off 1
setup roomy
empty_it
t0=$SECONDS
if wait_for 15 '[ "$(released)" -gt 0 ]'; then
    pass "2: control: with the grace off the same setup hands back $(released) Block Group(s) within $((SECONDS - t0)) s -- case 3 kept them because of the grace"
else
    fail "2: control: even with the grace off nothing went back in 15 s -- case 3 proves nothing"
fi
ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "2: clean" || fail "2: not clean: $(ct_fsck "$DEV" 2>&1 | grep -m1 ERR)"
ct_exit
