#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a released group takes no live journal entry of ours with it
#
# A peer replays a dead node's journal safely because no peer reuses
# that node's blocks before replaying it: a reused block whose new
# owner's write is in flight reads torn, and torn is the one case the
# prev_checksum judge redoes. A hand-back -- a Block Group, alone or with
# its Zone Group -- is where a peer starts reusing our blocks with no
# replay in between, and a held-back tree batch's entries stay live
# after the batch completed (af3a561), until the next batch or a sync.
# Delete the file and its tree blocks' group can go empty and be handed
# back with those entries still live. The hand-back now spends them
# first (cetrafs_journal_settle_range(), from
# cetrafs_bg_release_bitmap_ready()).
#
# Staged on one node with the journal on: Zone Group 0 full, so a
# fragmented file's data and tree blocks land in Zone Group 1; its fsync
# writes the tree as a batch whose entries stay live; the file is
# deleted with no sync; the surplus pass then releases Zone Group 1.
#   setup: live entries name blocks of Zone Group 1 before the release;
#   1. after the release none does, and release_journal_drains counted it;
#   2. fsck clean.
#
# DISCRIMINATION: release_journal_unsettled=1: the release leaves them live.
# ct-timeout: 300
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in release_journal_unsettled zg_release_hold bg_release_off journal_aged_drain_off; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
BG_POKE="$(ct_helper bg_poke)"
BG_MAP="$(ct_helper bg_map)"
JPOKE="$(ct_helper journal_poke)"
MNT="$(ct_mnt rjs)"
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set release_journal_unsettled 0
ct_param_set bg_release_off 1 # the Zone Group's own hand-back is the path staged
ct_param_set zg_release_hold 1
# The release is the path under test: the heartbeat's spend of entries a
# beat old (cetrafs_journal_drain_aged()) would get to them first.
ct_param_set journal_aged_drain_off 1

# live <dev> <starts file> <zg1 bgs file> -> live entries naming a block of Zone Group 1
live() {
    "$JPOKE" "$1" "$2" --live | awk -v S="$3" -v Z="$4" '
        BEGIN { while ((getline l < S) > 0) { split(l, a, " "); n++; id[n] = a[1]; st[n] = a[2] }
                while ((getline l < Z) > 0) z[l] = 1 }
        { t = $4; best = -1; for (i = 1; i <= n; i++) if (st[i] + 0 <= t + 0 && (best < 0 || st[i] + 0 > st[best] + 0)) best = i
          if (best >= 0 && (id[best] in z)) c++ }
        END { print c + 0 }'
}

# <unsettled 0|1> -> "<live in ZG1 before> <after> <released> <drains> <fsck>"
round() {
    local dev proc me starts zg1 b0 a1 rel=no d0 d1 out
    dev="$(ct_loop "$(ct_image 1400 "rjs$1")")"
    ct_mkfs "$dev" -z 2 -b 512 -J 4 -N 1024 -f >/dev/null
    for bg in $(ct_bgs_of_zg "$dev" 0); do "$BG_POKE" "$dev" "$bg" 0 fill-bitmap >/dev/null; done
    starts="$(ct_tmp "rjs-starts$1")"
    zg1="$(ct_tmp "rjs-zg1$1")"
    "$BG_MAP" "$dev" | awk '/^bg /{split($4, a, "="); print $2, a[2]}' >"$starts"
    ct_bgs_of_zg "$dev" 1 >"$zg1"
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    me="$(sed -n 's/^this_node_id: //p' "$proc/info")"
    python3 - "$MNT/f" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(1500):
    os.pwrite(fd, b"x" * 4096, 2 * i * 4096)
os.fsync(fd)
os.close(fd)
PY
    rm -f "$MNT/f"
    b0="$(live "$dev" "$me" "$starts" "$zg1")"
    d0="$(sed -n 's/^release_journal_drains: //p' "$proc/info")"
    echo "$1" >/sys/module/cetrafs/parameters/release_journal_unsettled
    echo 0 >/sys/module/cetrafs/parameters/zg_release_hold
    echo "hb_interval_secs=5" >"$proc/controls"
    for _ in $(seq 1 40); do
        grep -qP "^\s+zg 1: owner=none" "$proc/info" && { rel=yes; break; }
        sleep 1
    done
    a1="$(live "$dev" "$me" "$starts" "$zg1")"
    d1="$(sed -n 's/^release_journal_drains: //p' "$proc/info")"
    echo 0 >/sys/module/cetrafs/parameters/release_journal_unsettled
    echo 1 >/sys/module/cetrafs/parameters/zg_release_hold
    ct_umount "$MNT"
    out="$(ct_fsck "$dev" 2>&1 || true)"
    # Zone Group 0's bitmap was filled by hand: leaked by construction.
    out="$(grep -v 'data block(s) marked in use but referenced by no inode (leaked)' <<<"$out" || true)"
    if grep -qE '^(ERR|WARN)' <<<"$out"; then
        log "fsck ($1): $(grep -E '^(ERR|WARN)' <<<"$out" | head -2 | tr '\n' ' ')" >&2
        out=ERR
    else
        out=clean
    fi
    echo "$b0 $a1 $rel $((d1 - d0)) $out"
}

read -r B A R D F <<<"$(round 0)"
log "settled: $B live entries in Zone Group 1 before the release, $A after; released $R; drains $D; fsck $F"
read -r CB CA CR CD CF <<<"$(round 1)"
log "control (unsettled): $CB before, $CA after; released $CR"
[ "$B" -gt 0 ] && [ "$CB" -gt 0 ] ||
    { fail "setup: no live entry named Zone Group 1 before the release ($B, $CB) -- nothing to settle"; ct_exit; }
[ "$R" = yes ] && [ "$CR" = yes ] || { fail "setup: Zone Group 1 was not released ($R, $CR)"; ct_exit; }
pass "setup: $B live entries named Zone Group 1's blocks, and it was released"
[ "$A" = 0 ] && [ "$D" -ge 1 ] && pass "1: after the release no live entry names it (spent by $D drain(s))" ||
    fail "1: $A live entries name the released group, drains $D"
[ "$F" = clean ] && pass "2: fsck clean" || fail "2: fsck not clean"
[ "$CA" -gt 0 ] && pass "control: unsettled, $CA entries stay live for the released group" ||
    fail "control: unsettled left $CA -- something else spent them; the test does not discriminate"
ct_exit
