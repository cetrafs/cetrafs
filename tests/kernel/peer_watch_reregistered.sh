#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a row re-registered at the very hb_seq last sampled is a new holder, not a node that stopped
#
# Liveness is decided by watching a row's hb_seq stand still. hb_seq
# restarts at 1 when a row is registered afresh, so the SAME machine
# re-registering a row (after a repair retired it, unseen by us) can
# stand at the value we last sampled -- and the watch read "has not
# moved since then": a live node judged stale, its lock broken, its
# lease revoked. The row's incarnation (format 0x000A) is drawn anew at
# every registration and re-attach; every watch now compares it with
# hb_seq and the uuid (kmod's struct cetrafs_row_mark, devutil.h's
# cetrafs_row_same_beat()). Staged by keeping hb_seq and changing only
# the incarnation, which is what such a row looks like:
#
#  A. the peer watch: node 1 holds f's lock and was sampled; after the
#     stale window its row carries a new incarnation at the same hb_seq.
#     A write-open must be refused (a live holder) and node 1's lease
#     left alone.
#  B. the fence: an open judged node 1 stale and is held before its
#     fence (fence_stall_ms) while the row's incarnation changes at the
#     same hb_seq. The fence must refuse, as for a node that came back.
#  C. control: the same open with no new incarnation reclaims -- the
#     window was long enough, and A and B were refused for the
#     incarnation and nothing else.
#  D. the tools' live-mount probe: fsck watches a REGISTERED row that
#     does not beat, and its incarnation changes during the window. fsck
#     must refuse as for a mounted node; control: unchanged, it runs.
#
# DISCRIMINATION (checked 2026-11-10, each weakened alone): with the
# watch keyed on hb_seq and uuid only, A's procfs view reads stale=yes
# (the open is then refused only by the fence, which A also asserts
# against) and C's reclaim never happens; with the fence comparing
# hb_seq only, B's open succeeds and revokes node 1's lease; with the
# tools comparing hb_seq only, D's fsck runs on the "mounted" volume.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/fence_stall_ms ] || { skip "fence_stall_ms is missing"; ct_exit; }
NPOKE="$(ct_helper node_poke)"
LPOKE="$(ct_helper inode_lock_poke)"

IMG="$(ct_image 560 prereg)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt prereg)"
ct_mkfs_small "$DEV" >/dev/null
set_stale_window "$TEST_STALE_SECS"
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo x >"$MNT/f"
echo y >"$MNT/g"
FI="$(stat -c %i "$MNT/f")"
GI="$(stat -c %i "$MNT/g")"
sync
blockdev --flushbufs "$DEV"

# Node 1: registered, silent, incarnation 111; it holds f's and g's locks.
"$NPOKE" "$IMG" 1 1 bb "$(date +%s)" >/dev/null
"$NPOKE" "$IMG" 1 --beat >/dev/null
"$NPOKE" "$IMG" 1 --inc 111 >/dev/null
"$LPOKE" "$IMG" "$FI" 1 1 >/dev/null
"$LPOKE" "$IMG" "$GI" 1 1 >/dev/null
row() { "$NPOKE" "$IMG" 1; }
epoch() { sed -n 's/.*fence_epoch=\([0-9]*\).*/\1/p' <<<"$(row)"; }
hbseq() { sed -n 's/.*hb_seq=\([0-9]*\).*/\1/p' <<<"$(row)"; }
wopen() { # <file> <rcfile> <errfile>: open for write, record rc and stderr
    local rc=0
    { : >>"$1"; } 2>"$3" || rc=$?
    echo "$rc" >"$2"
}
ct_track file "$IMG.rc"; ct_track file "$IMG.err"
E0="$(epoch)"
H0="$(hbseq)"

# First look: the watch samples node 1's row (alive, by definition).
{ : >>"$MNT/f"; } 2>/dev/null && { fail "setup: f opened for write past node 1's lock"; ct_exit; }

# ------------------------------------------------------------------- A
log "A: node 1's row, same hb_seq ($H0), a new incarnation after the stale window"
wait_out_stale_window
"$NPOKE" "$IMG" 1 --inc 222 >/dev/null
[ "$(hbseq)" = "$H0" ] || { fail "setup: the incarnation poke moved hb_seq ($H0 -> $(hbseq))"; ct_exit; }
# The watch alone first: procfs's cluster view asks it directly, with
# no fence behind it to catch a wrong verdict (the open below would be
# refused by B's fence check even if the watch were wrong).
STALE="$(sed -n 's/^node 1: .* stale=\([a-z]*\).*/\1/p' "$(ct_procdir "$DEV")/cluster")"
[ "$STALE" = no ] && pass "A: the watch reads the row as alive (stale=no)" ||
    fail "A: the watch judged node 1 stale at a beat of another incarnation (stale='$STALE')"
MARK="$(dmesg_mark)"
wopen "$MNT/f" "$IMG.rc" "$IMG.err"
[ "$(cat "$IMG.rc")" != 0 ] && grep -q "Text file busy" "$IMG.err" &&
    pass "A: the open was refused -- a row with a new incarnation is a live holder (ETXTBSY)" ||
    fail "A: the open went ahead (rc=$(cat "$IMG.rc"): $(cat "$IMG.err")) -- node 1 was judged stale at a beat of another incarnation"
[ "$(epoch)" = "$E0" ] && pass "A: node 1's lease was not revoked" ||
    fail "A: node 1's lease was revoked: fence_epoch $E0 -> $(epoch)"
! dmesg_since "$MARK" | grep -q "came back since it was judged stale" &&
    pass "A: and no verdict reached the fence -- the watch refused, not B's backstop" ||
    fail "A: the open reached a stale verdict and only the fence refused it"

# ------------------------------------------------------------------- B
log "B: the incarnation changes between an open's stale verdict and its fence"
wait_out_stale_window
# The stall must be SHORTER than the stale window: the row then stands
# still under its new incarnation, and a stall longer than the window
# lets a tick reach a fresh -- and correct -- stale verdict on THAT
# incarnation before the fence runs (fence_vs_reattach.sh keeps its row
# beating for the same reason; beating would move hb_seq here).
STALL_MS=$((TEST_STALE_SECS * 1000 / 2))
ct_param_set fence_stall_ms "$STALL_MS"
MARK="$(dmesg_mark)"
wopen "$MNT/g" "$IMG.rc" "$IMG.err" &
OPID=$!
for _ in $(seq 1 60); do [ "$(cat /sys/module/cetrafs/parameters/fence_stall_ms)" = 0 ] && break; sleep 0.1; done
if [ "$(cat /sys/module/cetrafs/parameters/fence_stall_ms)" != 0 ]; then
    fail "setup: B: the open never judged node 1 stale"
    ct_param_set fence_stall_ms 0
    wait "$OPID" || true
    ct_exit
fi
"$NPOKE" "$IMG" 1 --inc 333 >/dev/null
wait "$OPID" || true
[ "$(hbseq)" = "$H0" ] || { fail "setup: B: hb_seq moved ($H0 -> $(hbseq)) -- B would test a beat, not an incarnation"; ct_exit; }
[ "$(cat "$IMG.rc")" != 0 ] && grep -q "Text file busy" "$IMG.err" &&
    pass "B: the open was refused at its fence" ||
    fail "B: the open went ahead (rc=$(cat "$IMG.rc"): $(cat "$IMG.err")) -- the fence landed on another incarnation"
dmesg_since "$MARK" | grep -q "node 1 came back since it was judged stale" && pass "B: and the fence said why" ||
    fail "B: no 'came back' line: $(dmesg_since "$MARK" | grep -m1 fence || echo none)"
[ "$(epoch)" = "$E0" ] && pass "B: node 1's lease was not revoked" ||
    fail "B: node 1's lease was revoked: fence_epoch $E0 -> $(epoch)"
grep -q "owner=1 mode=1" <<<"$("$LPOKE" "$IMG" "$GI")" && pass "B: and g's lock is still node 1's" ||
    fail "B: g's lock was taken from a live node: $("$LPOKE" "$IMG" "$GI")"

# ------------------------------------------------------------------- C
log "C: control -- node 1's row left alone for a whole window"
{ : >>"$MNT/f"; } 2>/dev/null && { fail "setup: C: f opened before node 1 went stale"; ct_exit; } # sample incarnation 333
wait_out_stale_window
wopen "$MNT/f" "$IMG.rc" "$IMG.err"
[ "$(cat "$IMG.rc")" = 0 ] && pass "C: control: the same open reclaims once the row truly stood still" ||
    fail "setup: C: even an unchanged row was not reclaimed (rc=$(cat "$IMG.rc"): $(cat "$IMG.err")) -- A and B prove nothing"
[ "$(epoch)" != "$E0" ] && pass "C: control: and node 1's lease was revoked ($E0 -> $(epoch))" ||
    fail "setup: C: the reclaim revoked nothing -- A and B prove nothing"
ct_umount "$MNT"
reset_stale_window

# ------------------------------------------------------------------- D
log "D: the tools' probe -- a silent row whose incarnation changes while fsck watches"
"$NPOKE" "$DEV" 1 1 bb "$(date +%s)" >/dev/null
"$NPOKE" "$DEV" 1 --beat >/dev/null
"$NPOKE" "$DEV" 1 --inc 444 >/dev/null
blockdev --flushbufs "$DEV"
export CETRAFS_PEER_PROBE_SECS=3
( sleep 1; "$NPOKE" "$DEV" 1 --inc 555 >/dev/null 2>&1 ) &
POKER=$!
OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || true
wait "$POKER" 2>/dev/null || true
grep -q "is mounted by another node (registry row 1" <<<"$OUT" &&
    pass "D: fsck refused -- a row with a new incarnation is a node that got in" ||
    fail "D: fsck called the volume free while row 1 changed incarnation under its watch: $(tail -1 <<<"$OUT")"
log "D: control -- the same row, left alone through the window"
OUT="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || true
unset CETRAFS_PEER_PROBE_SECS
! grep -q "is mounted by another node" <<<"$OUT" && pass "D: control: an unchanged silent row is gone, fsck runs" ||
    fail "setup: D: fsck refused even an unchanged silent row -- D proves nothing"
"$NPOKE" "$DEV" 1 0 00 0 >/dev/null
ct_exit
