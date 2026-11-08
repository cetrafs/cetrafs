#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a claim given back after the re-attach sweep is swept again; a held one is not
#
# A node back from a crash sweeps the claims its previous incarnation
# left (reattach_sweeps_claims). A peer that displaced one of them while
# the node was down, and then found the row re-attached, undoes its
# steal (cetrafs_lock_undo_steal()) -- and if the sweep has already
# passed that record, the lock lands on an incarnation that never opened
# the file. Nothing local releases it and the row is live, so nothing
# remote reclaims it: the file is refused to writers (TODO.md F10). A
# second pass, own_claim_resweep_secs after the mount, clears claims of
# this node that nothing here holds -- judged per inode under its
# lock_mutex -- and must never clear one a local open does hold.
#
# Staged: a crashed-looking row is re-attached with the late pass a few
# seconds out. Before it runs, one file is opened for write here (its
# lock is real), and a lock and a presence bit of this row are planted
# on two other files through the backing image, as a late give-back
# would leave them.
#
# DISCRIMINATION: the planted lock is checked still held just before the
# pass is due and gone after it, so it is the pass that clears it; with
# lock_resweep_ignore_local=1 (the predicate ignoring local users) the
# held file's lock is cleared too, which the held-lock check catches.
# Each round re-attaches after an unclean departure, which waits out the
# stale window (120 s) before registering: two rounds, hence the limit.
# ct-timeout: 480
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in own_claim_resweep_secs lock_resweep_ignore_local; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

# run <resweep_secs> <ignore_local>: one round; sets GIVEN READER HELD
# (the three records afterwards), EARLY (the planted lock before the
# pass is due) and NCLR (late_claims_cleared delta).
run() {
    local IMG DEV MNT NID2 GI RI HI PROC C0 C1 MARK HELD0
    IMG="$(ct_image 560 lcr)"
    DEV="$(ct_loop "$IMG")"
    MNT="$(ct_mnt lcr)"
    ct_mkfs_small "$DEV" >/dev/null
    ct_param_set hb_interval_secs 2
    ct_track mnt "$MNT"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    NID="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
    for f in given reader held; do echo "$f" >"$MNT/$f"; done
    GI="$(stat -c %i "$MNT/given")"; RI="$(stat -c %i "$MNT/reader")"; HI="$(stat -c %i "$MNT/held")"
    ct_umount "$MNT"
    "$NODE_POKE" "$DEV" "$NID" --beat >/dev/null # the row looks crashed

    ct_param_set own_claim_resweep_secs "$1"
    ct_param_set lock_resweep_ignore_local "$2"
    MARK="$(dmesg_mark)"
    ct_mount "$DEV" "$MNT"
    PROC="$(ct_procdir "$DEV")"
    NID2="$(sed -n "s/^this_node_id: //p" "$PROC/info")"
    [ "$NID2" = "$NID" ] && dmesg_since "$MARK" | grep -q "re-attached row $NID" ||
        { fail "setup: the remount did not re-attach row $NID (got $NID2)"; ct_exit; }
    C0="$(sed -n 's/^late_claims_cleared: //p' "$PROC/info")"
    exec 7>>"$MNT/held" # a real local writer: its lock must survive
    # As a late give-back leaves them, behind the mount's back.
    "$LOCK_POKE" "$IMG" "$GI" "$NID" 1 >/dev/null
    "$LOCK_POKE" "$IMG" "$RI" --reader "$NID" >/dev/null
    HELD0="$("$LOCK_POKE" "$IMG" "$HI")"
    if ! grep -q "owner=$NID mode=1" <<<"$HELD0" || ! grep -q "owner=$NID mode=1" <<<"$("$LOCK_POKE" "$IMG" "$GI")"; then
        exec 7>&-
        fail "setup: held '$HELD0', given '$("$LOCK_POKE" "$IMG" "$GI")' -- not both locked by row $NID"
        ct_exit
    fi
    sleep 2
    EARLY="$("$LOCK_POKE" "$IMG" "$GI")"
    dmesg_since "$MARK" | grep -q 'late sweep of this node' && EARLY="the pass ran before the early look"
    for _ in $(seq 1 $(($1 * 10 + 50))); do
        dmesg_since "$MARK" | grep -q 'late sweep of this node' && break
        sleep 0.1
    done
    GIVEN="$("$LOCK_POKE" "$IMG" "$GI")"; READER="$("$LOCK_POKE" "$IMG" "$RI")"; HELD="$("$LOCK_POKE" "$IMG" "$HI")"
    C1="$(sed -n 's/^late_claims_cleared: //p' "$PROC/info")"
    NCLR=$((C1 - C0))
    echo more >&7 && WROTE=1 || WROTE=0
    exec 7>&-
    ct_param_set lock_resweep_ignore_local 0
    ct_param_set own_claim_resweep_secs 600
    ct_umount "$MNT"
    # No fsck: the planted claims were cleared by the pass, or are
    # deliberately still there.
}

run 8 0
pass "setup: re-attached; a held file and two planted claims of row $NID before the late pass"
grep -q "owner=$NID mode=1" <<<"$EARLY" && pass "the planted lock was still held before the pass was due" ||
    fail "setup: the planted lock was gone before the pass was due ($EARLY) -- something else cleared it"
grep -q 'mode=0' <<<"$GIVEN" && pass "the given-back lock was cleared ($GIVEN)" || fail "the given-back lock is still held: $GIVEN"
grep -q 'readers=0x0$' <<<"$READER" && pass "the given-back presence bit was cleared ($READER)" ||
    fail "the given-back presence bit is still set: $READER"
grep -q "owner=$NID mode=1" <<<"$HELD" && pass "the lock a local writer holds was left alone ($HELD)" ||
    fail "the late pass cleared the lock of a file open for write here: $HELD"
[ "$NCLR" -eq 2 ] && pass "exactly two records were cleared" || fail "late_claims_cleared moved by $NCLR, expected 2"
[ "$WROTE" = 1 ] && pass "the held file still takes writes" || fail "the held file's writer failed after the pass"

# Control: ignoring local users, the held lock goes.
run 8 1
grep -q 'mode=0' <<<"$HELD" && pass "control: a predicate ignoring local users clears the held lock -- the check above discriminates" ||
    fail "control: even ignoring local users the held lock survived ($HELD) -- the check does not discriminate"
ct_exit
