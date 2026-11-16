#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# controls dead=<row>:<incarnation> -- an HA agent declares a fenced host dead
#
# A host that stops beating is stale to its peers only after the stale
# window, and until then every file it held stays held: on a default
# mount an open of one gets ETXTBSY. Proxmox HA restarts a lost node's VMs
# well inside that window, and with max_restart=1 may give up on them
# (audit 2026-11-15 M-48, G-25). An agent that has power-fenced the host
# now declares its row dead: the fence CAS plus departure=DEAD, bound to
# the incarnation it read, so every node reads the row stale at once.
# And every reclaim fence records departure=DEAD too, so a row one path
# has judged costs the next observer one read, not another window.
#
#   D. row 1 holds v's lock and has gone silent, inside the window: the
#      open is refused; a wrong incarnation and this node's own row are
#      refused; the right one fences the row, and the open goes ahead;
#   R. row 2, stale, holds w's lock: the open's reclaim fence leaves the
#      row departure=DEAD.
#
# DISCRIMINATION: D's open before the declaration (the same open, the
# same row, refused). reclaim_fence_no_dead=1: R's row stays departure=0.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
IMG="$(ct_image 560 decl)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt decl)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0
ct_param_set reclaim_fence_no_dead 0
row() { "$NPOKE" "$DEV" "$1"; }
field() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
can_write() { (exec 9>>"$1") 2>/dev/null; }
bail() { fail "$*"; ct_exit; }

ct_mkfs "$DEV" -z 1 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
CTL="$(ct_procdir "$DEV")/controls"
echo v >"$MNT/v"
echo w >"$MNT/w"
echo x >"$MNT/x"
sync
V="$(stat -c %i "$MNT/v")" W="$(stat -c %i "$MNT/w")" X="$(stat -c %i "$MNT/x")"
ME="$(sed -n 's/^node \([0-9]*\): .*(this node)$/\1/p' "$(ct_procdir "$DEV")/cluster")"
MYINC="$(field incarnation "$(row "$ME")")"
[ -n "$ME" ] && [ -n "$MYINC" ] || bail "setup: this node's row not found in cluster"

log "D: row 1 holds v's lock, then goes silent inside the stale window"
poke_dead_peer "$DEV" 1 aa
"$NPOKE" "$DEV" 1 --inc 7 >/dev/null
ct_beat_row "$DEV" 1
INODE_LOCK_POKE_INC=7 "$LPOKE" "$DEV" "$V" 1 1 >/dev/null
sleep 2
ct_unbeat
grep -q "^node 1: .*stale=no incarnation=7" "$(ct_procdir "$DEV")/cluster" ||
    bail "setup: row 1 is not a live-looking peer of incarnation 7: $(grep '^node 1:' "$(ct_procdir "$DEV")/cluster")"
can_write "$MNT/v" && bail "setup: v opened for write past row 1's lock -- nothing to declare"
pass "before: the open of row 1's file is refused while its row is not stale"

echo "dead=1:6" >"$CTL" 2>/dev/null && fail "a wrong incarnation was accepted" ||
    pass "a wrong incarnation is refused"
[ "$(field departure "$(row 1)")" = 0 ] && pass "...and the row was not touched" ||
    fail "the refused declaration changed the row: $(row 1)"
echo "dead=$ME:$MYINC" >"$CTL" 2>/dev/null && fail "this node's own row was declared dead" ||
    pass "this node's own row is refused"
if command -v setpriv >/dev/null; then
    setpriv --bounding-set -sys_admin --inh-caps -sys_admin sh -c "echo dead=1:7 >'$CTL'" 2>/dev/null &&
        fail "a writer without CAP_SYS_ADMIN declared a row dead" ||
        pass "a writer without CAP_SYS_ADMIN is refused"
    [ "$(field departure "$(row 1)")" = 0 ] || fail "the refused declaration changed the row: $(row 1)"
else
    skip "setpriv not installed: the CAP_SYS_ADMIN refusal is not exercised"
fi

echo "dead=1:7" >"$CTL" && pass "the declaration naming row 1's incarnation is accepted" ||
    fail "the declaration was refused"
R1="$(row 1)"
[ "$(field departure "$R1")" = 2 ] && [ "$(field fence_reason "$R1")" = 3 ] && [ "$(field fenced_by "$R1")" = "$ME" ] &&
    pass "row 1: departure=DEAD, fenced by this node, reason declared" || fail "row 1 after the declaration: $R1"
grep -q "^node 1: .*departure=dead stale=yes" "$(ct_procdir "$DEV")/cluster" &&
    pass "cluster reads row 1 dead and stale at once" ||
    fail "cluster: $(grep '^node 1:' "$(ct_procdir "$DEV")/cluster")"
can_write "$MNT/v" && pass "after: the same open goes ahead, without waiting out the window" ||
    fail "v still refused after the declaration"
echo "dead=1:7" >"$CTL" 2>/dev/null && fail "a second declaration of a departed row was accepted" ||
    pass "a row already departed is refused"

# <row> <ino> <no_dead 0|1> <name> -> the row after an open reclaims the lock
reclaim() {
    poke_dead_peer "$DEV" "$1" bb
    "$NPOKE" "$DEV" "$1" --stale 15 >/dev/null # its own window floors ours
    "$LPOKE" "$DEV" "$2" "$1" 1 >/dev/null
    echo "$3" >/sys/module/cetrafs/parameters/reclaim_fence_no_dead
    # The watch starts on a tick, and the tick was scheduled before the
    # window was compressed: wait for the verdict itself.
    wait_for 60 "grep -q '^node $1: .*stale=yes' '$(ct_procdir "$DEV")/cluster'" || echo -n "stale=never "
    if can_write "$MNT/$4"; then echo -n "opened=yes "; else echo -n "opened=no "; fi
    echo 0 >/sys/module/cetrafs/parameters/reclaim_fence_no_dead
    row "$1"
}

log "R: a reclaim fence records departure=DEAD"
# This mount's own timing, at its floor: the watch window is per mount.
HB0="$(sed -n 's/^hb_interval_secs: //p' "$CTL")" ST0="$(sed -n 's/^stale_secs: //p' "$CTL")"
echo hb_interval_secs=5 >"$CTL"
echo stale_secs=15 >"$CTL"
R2="$(reclaim 2 "$W" 0 w)"
R3="$(reclaim 3 "$X" 1 x)"
echo "stale_secs=$ST0" >"$CTL"
echo "hb_interval_secs=$HB0" >"$CTL"
log "row 2: $R2"
log "row 3 (control): $R3"
[ "$(field opened "$R2")" = yes ] && [ "$(field fence_reason "$R2")" = 1 ] && [ "$(field departure "$R2")" = 2 ] &&
    pass "R: the reclaim fenced row 2 and recorded it dead" || fail "R: $R2"
[ "$(field opened "$R3")" = yes ] && [ "$(field fence_reason "$R3")" = 1 ] && [ "$(field departure "$R3")" = 0 ] &&
    pass "R control: as before, the reclaim fenced row 3 and left departure unset" ||
    fail "R control: the control did not reach the reclaim fence: $R3"

ct_umount "$MNT"
ct_exit
