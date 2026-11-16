#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# block 0 has a copy at block 2048, and fsck -r restores it from there
# ct-timeout: 480
#
# One stray write to block 0 -- a partition tool, a label, a dd -- made
# the volume unmountable on every node with all of its data intact
# (audit 2026-11-15 A-7). mkfs and growfs now keep a copy of block 0 at
# CETRAFS_SB_REPLICA_NR (8 MiB in, where those miss, at a place that
# never moves):
#   1. mkfs writes it, equal to block 0; info says sb_copy: ok;
#   2. block 0 zeroed: the mount refuses, naming the copy; fsck says so;
#      fsck -r restores block 0; the volume mounts with its data;
#   3. block 0 failing its checksum: the same;
#   4. the copy zeroed: the mount goes ahead and says so (sb_copy: bad);
#      fsck reports it, fsck -r rewrites it;
#   5. an offline grow carries the copy along: fsck clean after it;
#   6. so does a live one: the next mount reads the copy as current.
#
# DISCRIMINATION: 2 with the copy zeroed as well -- nothing restores
# block 0 (fsck: bad magic); 5 with CETRAFS_GROWFS_TEST_NO_SB_COPY=1 --
# fsck reports the copy describing a different layout; 6 with the same
# knob -- the next mount says sb_copy: stale.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
DEV="$(ct_big_dev 1600 sbcopy)"
MNT="$(ct_mnt sbcopy)"
ct_track mnt "$MNT"
REP=2048
fresh() { ct_mkfs "$DEV" -s 700M -f >/dev/null; }
blk() { dd if="$DEV" bs=4096 skip="$1" count=1 status=none | md5sum | cut -d' ' -f1; }
zero_blk() { dd if=/dev/zero of="$DEV" bs=4096 seek="$1" count=1 conv=notrunc,fsync status=none; blockdev --flushbufs "$DEV"; }
info() { sed -n "s/^$1: //p" "$(ct_procdir "$DEV")/info"; }
fill() {
    ct_mount "$DEV" "$MNT"
    dd if=/dev/urandom of="$MNT/f" bs=1M count=4 status=none
    SUM="$(md5sum <"$MNT/f")"
    ct_umount "$MNT"
}
# -> RES: mount refusal, hint, fsck verdict, restore, data after
damaged_block0() {
    local mark rc=0 out
    mark="$(dmesg_mark)"
    mount -t cetrafs "$DEV" "$MNT" 2>/dev/null && { umount "$MNT"; RES="mounted=yes"; } || RES="mounted=no"
    out="$(dmesg_since "$mark")"
    grep -q "its copy at block $REP does" <<<"$out" && RES="$RES hint=yes" || RES="$RES hint=no"
    out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
    grep -q "checking the volume through its copy" <<<"$out" && RES="$RES fsck_said=yes" || RES="$RES fsck_said=no"
    RES="$RES fsck_rc=$rc"
    "$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || true
    out="$(ct_fsck "$DEV" 2>&1)" && RES="$RES after=clean" || RES="$RES after=dirty"
    if ct_mount "$DEV" "$MNT" 2>/dev/null; then
        [ "$(md5sum <"$MNT/f")" = "$SUM" ] && RES="$RES data=ok" || RES="$RES data=bad"
        ct_umount "$MNT"
    else
        RES="$RES data=nomount"
    fi
}
field() { tr ' ' '\n' <<<"$2" | sed -n "s/^$1=//p" | head -1; }

# 1
fresh
[ "$(blk 0)" = "$(blk $REP)" ] && pass "1: mkfs writes block 0's copy at block $REP" || fail "1: the copy differs from block 0"
ct_mount "$DEV" "$MNT"
[ "$(info sb_copy)" = ok ] && pass "1: info says sb_copy: ok" || fail "1: sb_copy: $(info sb_copy)"
ct_umount "$MNT"

# 2
fresh; fill; zero_blk 0
damaged_block0
R2="$RES"
[ "$(field mounted "$R2")" = no ] && [ "$(field hint "$R2")" = yes ] && [ "$(field fsck_said "$R2")" = yes ] &&
    [ "$(field fsck_rc "$R2")" != 0 ] && pass "2: block 0 zeroed: refused, naming the copy, and fsck says so ($R2)" ||
    fail "2: $R2"
[ "$(field after "$R2")" = clean ] && [ "$(field data "$R2")" = ok ] &&
    pass "2: fsck -r restored block 0, and the volume mounts with its data ($R2)" || fail "2: $R2"

# 2 control: no copy either
fresh; fill; zero_blk 0; zero_blk $REP
out="$("$ROOT/userspace/fsck.cetra" -r "$DEV" 2>&1 || true)"
grep -q "bad magic" <<<"$out" && pass "2 control: with the copy gone too, nothing restores block 0" ||
    fail "2 control: $(head -3 <<<"$out")"

# 3
fresh; fill
printf '\xff' | dd of="$DEV" bs=1 seek=100 count=1 conv=notrunc,fsync status=none # inside the struct
blockdev --flushbufs "$DEV"
damaged_block0
R3="$RES"
[ "$(field mounted "$R3")" = no ] && [ "$(field hint "$R3")" = yes ] && [ "$(field after "$R3")" = clean ] &&
    [ "$(field data "$R3")" = ok ] && pass "3: block 0 failing its checksum: the same ($R3)" || fail "3: $R3"

# 4
fresh; fill; zero_blk $REP
mark="$(dmesg_mark)"
ct_mount "$DEV" "$MNT"
S4="$(info sb_copy)"
ct_umount "$MNT"
out="$(dmesg_since "$mark")"
grep -q "copy of block 0 at block $REP does not verify" <<<"$out" && W4=yes || W4=no
O4="$(ct_fsck "$DEV" 2>&1 || true)"
"$ROOT/userspace/fsck.cetra" -r "$DEV" >/dev/null 2>&1 || true
[ "$S4" = bad ] && [ "$W4" = yes ] && grep -q "copy of block 0 at block $REP does not verify" <<<"$O4" &&
    ct_fsck "$DEV" >/dev/null 2>&1 &&
    pass "4: a lost copy mounts, is reported by the mount and fsck, and fsck -r rewrites it" ||
    fail "4: sb_copy=$S4 warned=$W4 fsck: $(grep ERR <<<"$O4" | head -2)"

# 5
fresh
ct_growfs "$DEV" -s 1400M >/dev/null 2>&1 || fail "5: growfs failed"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "5: an offline grow carries the copy along: fsck clean" ||
    fail "5: $(ct_fsck "$DEV" 2>&1 | grep ERR | head -2)"
fresh
CETRAFS_GROWFS_TEST_NO_SB_COPY=1 ct_growfs "$DEV" -s 1400M >/dev/null 2>&1 || true
O5="$(ct_fsck "$DEV" 2>&1 || true)"
grep -q "describes a different layout" <<<"$O5" &&
    pass "5 control: a grow that leaves the copy behind is reported" ||
    fail "5 control: fsck did not see the stale copy"

# 6: a live grow (the volume mounted) carries it too; a mount after it
# reads the copy as current. Control: the knob leaves it stale.
# -> RES
live_grow() {
    local o
    fresh
    ct_mount "$DEV" "$MNT"
    if [ "$1" = 1 ]; then
        o="$(CETRAFS_GROWFS_TEST_NO_SB_COPY=1 ct_growfs "$DEV" -s 1400M 2>&1)" || RES="grow=fail"
    else
        o="$(ct_growfs "$DEV" -s 1400M 2>&1)" || RES="grow=fail"
    fi
    RES="${RES:-grow=ok} gen=$(info layout_gen)"
    ct_umount "$MNT"
    ct_mount "$DEV" "$MNT"
    RES="$RES copy=$(info sb_copy)"
    ct_umount "$MNT"
}
RES=""; live_grow 0; R6="$RES"
RES=""; live_grow 1; C6="$RES"
log "live grow: $R6; control (copy left behind): $C6"
[ "$(field grow "$R6")" = ok ] && [ "$(field gen "$R6")" = 1 ] && [ "$(field copy "$R6")" = ok ] &&
    pass "6: a live grow carries the copy along ($R6)" || fail "6: $R6"
[ "$(field gen "$C6")" = 1 ] && [ "$(field copy "$C6")" = stale ] &&
    pass "6 control: a live grow that leaves the copy behind is seen at the next mount ($C6)" ||
    fail "6 control: $C6"
ct_exit
