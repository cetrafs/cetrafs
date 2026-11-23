#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a short pool shard never strands an unowned Block Group
#
# A claim debits the unowned pool's shard before its swap, and the shard
# refuses a debit that would take it below zero. A shard can be short on
# purpose: a crash between a claim's debit and its swap keeps the debit,
# so does a swap of unknown outcome that did not land, and a dead grow's
# takeback clamps the shard at zero -- each leaves a group FREE that the
# shard does not hold. A claim that backed off on every refused debit
# could never take such a group: space the volume has, refused with
# ENOSPC until fsck -r. A claim now goes on and owes the debit
# (cetrafs_pool_owed_settle()); here it never lands and is dropped at
# unmount, and the shortage ends with the group: nothing left unowned
# that the shard should hold.
#
# The state a crash inside a claim leaves, made with the pokers: two
# Block Groups, the second unowned, its shard stamped 0. Then a writer
# fills past the first Block Group:
#   1. it wrote past the first group: the second was claimed;
#   2. the owed debit was dropped at unmount, as refused;
#   3. fsck clean.
#
# DISCRIMINATION: bg_claim_refused_backoff=1 (back off on a refused
# debit): the writer stops inside the first group, the second stays
# unowned (1 fails).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/bg_claim_refused_backoff ] || { skip "bg_claim_refused_backoff is missing"; ct_exit; }
ct_param_set bg_claim_refused_backoff 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
FREE_MARK=65535
POKE="$(ct_helper bg_poke)"
MAP="$(ct_helper bg_map)"
MNT="$(ct_mnt bgcss)"
ct_track mnt "$MNT"

# round <tag> <backoff 0|1> -> RES "<MiB written> <owner of BG 1> <dropped> <fsck ERR>"
round() {
    local dev mark i=0 owner dropped err out
    dev="$(ct_dev 1200 "bgcss$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    [ "$("$MAP" "$dev" | sed -n 's/^counts [0-9]* //p')" = 2 ] || { RES="setup-2bg"; return; }
    "$POKE" "$dev" 1 --owner "$FREE_MARK" >/dev/null
    "$POKE" "$dev" zg-pool 0 0 >/dev/null
    out="$(ct_fsck "$dev" 2>&1 || true)" # captured: grep -q under pipefail would SIGPIPE fsck
    grep -q 'pool_free_blocks 0 != ' <<<"$out" || { RES="setup-noshort"; return; }
    ct_param_set bg_claim_refused_backoff "$2"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    require_cetrafs_mount "$MNT"
    while dd if=/dev/zero of="$MNT/f$i" bs=1M count=16 conv=fsync status=none 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -gt 50 ] && break
    done
    ct_umount "$MNT"
    ct_param_set bg_claim_refused_backoff 0
    owner="$("$MAP" "$dev" | awk '/^bg 1 /{split($3,a,"="); print a[2]}')"
    dropped="$(dmesg_since "$mark" | grep -c "BG 1: the claim's owed pool debit of [0-9]* is dropped" || true)"
    err="$(ct_fsck "$dev" 2>&1 | grep -c '^ERR' || true)"
    RES="$((i * 16)) $owner $dropped $err"
}

round f 0
read -r FW FO FD FE <<<"$RES"
log "fixed: written ${FW} MiB, BG 1 owner=$FO, owed debits dropped=$FD, fsck ERR=$FE"
round c 1
read -r CW CO CD CE <<<"$RES"
log "control (back off): written ${CW} MiB, BG 1 owner=$CO, fsck ERR=$CE"
case "$FW" in setup-*) fail "setup: $FW"; ct_exit ;; esac
case "$CW" in setup-*) fail "control setup: $CW"; ct_exit ;; esac
[ "$FW" -gt 600 ] && [ "$FO" != "$FREE_MARK" ] &&
    pass "1: the writer went past the first Block Group: the second was claimed (${FW} MiB)" ||
    fail "1: ${FW} MiB written, BG 1 owner=$FO -- the short shard stranded it"
[ "$FD" -ge 1 ] && pass "2: the owed debit was dropped at unmount, refused by the short shard" ||
    fail "2: no owed debit was dropped"
[ "$FE" = 0 ] && pass "3: fsck clean -- the shortage ended with the group" || fail "3: fsck reports $FE error(s)"
[ "$CW" -le 600 ] && [ "$CO" = "$FREE_MARK" ] &&
    pass "control: backing off, the writer stopped inside the first group and the second stayed unowned (${CW} MiB)" ||
    fail "control: ${CW} MiB, BG 1 owner=$CO -- the staging proves nothing"
ct_exit
