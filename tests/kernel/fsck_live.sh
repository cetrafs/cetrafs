#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck --live checks a volume another node has mounted, and reports only what every walk repeats
#
# The documented check of a stopped node -- unmount, read-only fsck,
# mount -- could not run while the cluster did: fsck refuses whenever a
# peer is beating, and a verdict over a volume being changed means
# nothing (audit 2026-11-15 M-38). --live walks it anyway, read-only and
# claiming nothing, up to three times: the first clean walk ends it, a
# finding is an ERR line every walk printed alike, and findings that
# never repeat give no verdict (3).
#
# "Another node" is a second loop device over the same image: the local
# mount check knows only the first, the registry probe sees the mount
# beating -- exactly what a stopped node sees of its peers.
#   1. control: plain fsck refuses (3), as before;
#   2. --live on the healthy mounted volume: 0;
#   3. --live -r: a usage error -- it never writes;
#   4. an inode record nobody touches, damaged: 1, and that ERR reported;
#   5. under heavy metadata churn --live never says 1 (no invented
#      damage); control: one walk (CETRAFS_TEST_LIVE_PASSES=1) over the
#      same churn does -- the repetition is what keeps it out;
#   6. a real dangling entry -- a file nobody touches, its inode bit
#      cleared on the device -- is still reported: the live re-checks a
#      finding gets (fsck_live_dangling_holds(): the generation and the
#      bit read again around the entry) filter a churn, not damage.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
require_module
POKE="$(ct_helper csum_poke)"
SBPOKE="$(ct_helper sb_poke)"
BMP="$(ct_helper bmap_poke)"
FSCK="$ROOT/userspace/fsck.cetra"
IMG="$(ct_image 1200 fsklive)"
A="$(ct_loop "$IMG")"
B="$(ct_loop "$IMG")"
MNT="$(ct_mnt fsklive)"
STOP="$(ct_tmp)"
ct_mkfs "$A" -z 2 -b 512 -J 1 -M 4 -N 4096 -f >/dev/null
ct_mount "$A" "$MNT"
require_cetrafs_mount "$MNT"
for i in $(seq 30); do echo "$i" >"$MNT/f$i"; done
mkdir "$MNT/d"
echo victim >"$MNT/victim"
VINO="$(stat -c %i "$MNT/victim")"
echo dangler >"$MNT/dangler"
DINO="$(stat -c %i "$MNT/dangler")"
sync
sleep 1

rc=0
"$FSCK" "$B" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && pass "1 control: plain fsck refuses a volume a node has mounted (3)" ||
    fail "1 control: plain fsck gave $rc -- the setup does not look mounted to it"

rc=0
out="$("$FSCK" --live "$B" 2>&1)" || rc=$?
[ "$rc" = 0 ] && grep -q "found nothing" <<<"$out" && pass "2: --live on the healthy mounted volume: clean" ||
    fail "2: rc=$rc: $(grep -E '^ERR|--live' <<<"$out" | head -3 | tr '\n' ' ')"

rc=0
"$FSCK" --live -r "$B" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && pass "3: --live with -r is refused as a usage error" || fail "3: --live -r gave $rc"

# 5 before 4: the churn wants an undamaged volume.
churn() {
    rm -f "$STOP"
    while [ ! -e "$STOP" ]; do
        for i in $(seq 20); do echo x >"$MNT/d/x$i"; done
        rm -f "$MNT"/d/x1*
        dd if=/dev/urandom of="$MNT/w$((RANDOM % 5))" bs=64k count=20 status=none
    done
}
churn &
CP=$!
sleep 2
# One walk can fall in a quiet moment: up to five tries to see one fail.
rc1=0
for _ in 1 2 3 4 5; do
    rc1=0
    CETRAFS_TEST_LIVE_PASSES=1 "$FSCK" --live "$B" >/dev/null 2>&1 || rc1=$?
    [ "$rc1" = 1 ] && break
done
rc3=0
out="$("$FSCK" --live "$B" 2>&1)" || rc3=$?
touch "$STOP"
wait "$CP"
[ "$rc3" = 0 ] || [ "$rc3" = 3 ] && pass "5: under churn --live claims no damage (rc=$rc3)" ||
    fail "5: under churn --live reported damage: $(grep -E '^ERR' <<<"$out" | head -3 | tr '\n' ' ')"
[ "$rc1" = 1 ] && pass "5 control: one walk over the same churn reports problems -- the repetition filters them" ||
    fail "5 control: one walk gave $rc1 -- the churn shows the check nothing to filter"

ct_umount "$MNT"
"$POKE" "$B" inode "$VINO" >/dev/null
blockdev --flushbufs "$B"
blockdev --flushbufs "$A"
ct_mount "$A" "$MNT"
sleep 1
rc=0
out="$("$FSCK" --live "$B" 2>&1)" || rc=$?
[ "$rc" = 1 ] && grep -q "every walk repeated" <<<"$out" && grep -qE "^ERR: .*inode $VINO\b" <<<"$out" &&
    pass "4: a damaged inode record is reported by every walk, and named" ||
    fail "4: rc=$rc: $(grep -E '^ERR|--live' <<<"$out" | head -4 | tr '\n' ' ')"
ct_umount "$MNT"
IBM="$("$SBPOKE" "$IMG" | sed -n 's/^inode_bmap_start=//p')"
[ -n "$IBM" ] || { fail "setup: no inode_bmap_start"; ct_exit; }
[ "$("$BMP" "$IMG" "$IBM" $((DINO - 1)))" = 1 ] || { fail "setup: the dangler's bit is not set"; ct_exit; }
"$BMP" "$IMG" "$IBM" $((DINO - 1)) 0
blockdev --flushbufs "$B"
blockdev --flushbufs "$A"
ct_mount "$A" "$MNT"
sleep 1
rc=0
out="$("$FSCK" --live "$B" 2>&1)" || rc=$?
[ "$rc" = 1 ] && grep -q "names inode $DINO, which is marked FREE -- dangling entry" <<<"$out" &&
    pass "6: a real dangling entry is reported by every walk through the live re-check" ||
    fail "6: rc=$rc: $(grep -E '^ERR|--live' <<<"$out" | head -4 | tr '\n' ' ')"
ct_umount "$MNT"
ct_exit
