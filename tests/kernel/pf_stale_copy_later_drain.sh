#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# no drain leaves a copy of a free it applied: a later drain cannot free the block's next owner
#
# A free can be queued twice (a tolerated double free, an append retried
# after it had in fact landed). One drain applies a range once however
# many copies it consumes (pf_duplicate_applied_once.sh) -- but a copy it
# never consumed was applied by a LATER drain, after the block had been
# handed to a new file: a live block reading FREE, and handed out again
# (L19). A drain missed a copy three ways:
#
#  1. past an empty run: the scan stopped after two empty queue blocks,
#     so a copy behind them stayed queued;
#  2. in a busy region: a consume that kept losing to appenders was
#     skipped, and the copy in it applied by the next drain;
#  3. appended between the drain's read of a region and its swap: the
#     swap consumed only what the read had listed;
#  4. appended during the drain into a region its read found EMPTY,
#     which it therefore never swapped for (review F3).
#
# Now a drain that finds anything reads the whole queue, consumes every
# entry each swap finds, reads the whole queue AGAIN once consuming is
# over, and applies a range only if no copy of it is still queued -- a
# held copy keeps its blocks allocated, so the later drain that applies
# it frees nothing anyone was given.
#
# Staged as a peer's queued free really is: block L allocated and
# referenced by nothing (data_leak_poke), two copies of [L +1) queued.
# Each case then gets L reallocated to a file after the first drain and
# runs another drain over whatever is still queued; fsck must then find
# every referenced block allocated.
#
# CONTROLS, in the tree (pf_drain_weaken): each case runs again with its
# part of the rule switched off and must then end with a block freed
# under its owner. The re-read backs up the sweep and the consume-all --
# a copy either one misses is still queued at the re-read, and held -- so
# cases 1 and 3 switch off their part AND the re-read; case 2 switches
# off the hold, case 4 the re-read alone.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in pf_drain_busy_region pf_drain_consume_stall_ms pf_drain_min_ms pf_drain_weaken; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
PP="$(ct_helper pending_poke)"
LEAK="$(ct_helper data_leak_poke)"
BGPOKE="$(ct_helper bg_poke)"

IMG="$(ct_image 560 pfstale)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt pfstale)"
ct_mkfs_small "$DEV" -z 1 >/dev/null
ct_track mnt "$MNT"
ct_param_set auto_defrag 0
ct_param_set scrub 0                # it would reclaim the staged "queued" block
ct_param_set pf_drain_min_ms 600000 # drains only where a case asks for one

ext() { "$PP" "$IMG" extent "$(stat -c %i "$1")" | awk '{ print $1 }'; }
queued() { "$PP" "$IMG" dump 0 | grep -c "^$1 1\$" || true; }

# bg_index <lba>: "<bg> <index in its data region>"
bg_index() {
    local b d st off cnt
    for b in $(seq 0 63); do
        d="$("$BGPOKE" "$IMG" "$b" --dump 2>/dev/null)" || break
        st="$(sed -n 's/.*start_block=\([0-9]*\).*/\1/p' <<<"$d")"
        off="$(sed -n 's/.*off_data_region=\([0-9]*\).*/\1/p' <<<"$d")"
        cnt="$(sed -n 's/.*data_block_count=\([0-9]*\).*/\1/p' <<<"$d")"
        if [ "$1" -ge $((st + off)) ] && [ "$1" -lt $((st + off + cnt)) ]; then
            echo "$b $(($1 - st - off))"
            return 0
        fi
    done
    return 1
}

# stage <tag>: a one-block file's block L, freed, then marked allocated
# and unreferenced again -- a free a peer queued. Echoes L. Unmounted on
# return.
stage() {
    local L bi
    ct_mount "$DEV" "$MNT"
    dd if=/dev/urandom of="$MNT/f1$1" bs=4096 count=1 conv=fsync status=none
    sync
    L="$(ext "$MNT/f1$1")"
    rm -f "$MNT/f1$1"
    sync
    ct_umount "$MNT"
    bi="$(bg_index "$L")" || { fail "$1 setup: block $L is in no Block Group"; return 1; }
    "$LEAK" "$IMG" ${bi} 1 >/dev/null
    echo "$L"
}

# grab <tag> <L>: write one-block files until one is given L; echoes its
# name. Allocation is a drain point (pf_drain_min_ms 0), so this is also
# what runs the drain that applies the first copy.
grab() {
    local i f
    for i in $(seq 1 64); do
        f="$MNT/g$1-$i"
        dd if=/dev/urandom of="$f" bs=4096 count=1 conv=fsync status=none
        [ "$(ext "$f")" = "$2" ] && { echo "$f"; return 0; }
    done
    return 1
}

# later_drain: plant three filler frees in queue blocks 0..2 (blocks
# already free, so applying them changes nothing) -- the front the old
# scan needed to reach block 3 -- and run a drain.
later_drain() {
    local i
    for i in 0 1 2; do "$PP" "$IMG" put 0 "$i" 5 "$((FILLER + i))" 1 >/dev/null; done
    ct_param_set pf_drain_min_ms 0
    dd if=/dev/urandom of="$MNT/later$1" bs=4096 count=1 conv=fsync status=none
    ct_param_set pf_drain_min_ms 600000
}

# verdict <tag> <file> <block>: the file still owns its block, nobody
# else was given it, and fsck finds the volume consistent (it says a
# freed-under-its-owner block either way: "marked FREE" while nobody has
# it, "referenced by more than one inode" once the next writer got it).
# Under a control (CTRL=1) it only records the outcome in BROKEN, for
# control() to judge.
verdict() {
    local L="$3" got later
    sync
    got="$(ext "$2")"
    later="$(ext "$MNT/later$4")"
    ct_umount "$MNT"
    OUT="$(ct_fsck "$DEV" 2>&1)" && RC=0 || RC=$?
    BROKEN=0
    if [ "$RC" != 0 ] || grep -qiE "marked FREE|more than one inode|in use but marked free" <<<"$OUT"; then
        BROKEN=1
        [ "$CTRL" = 1 ] || fail "$1: a later drain freed block $L under its owner (fsck rc=$RC): $(grep -E -m2 '^ERR' <<<"$OUT")"
    else
        [ "$CTRL" = 1 ] || pass "$1: block $L is still allocated to its owner alone after the later drain (fsck clean)"
    fi
    [ "$CTRL" = 1 ] && return 0
    [ "$got" = "$L" ] || fail "$1: $2 no longer maps $L (now $got)"
    [ "$later" != "$L" ] || fail "$1: the later drain's writer was handed $L as well"
}

# ok <msg> / bad <msg>: a case's own assertions; silent under a control,
# which judges only the end state.
ok() { [ "$CTRL" = 1 ] || pass "$*"; }
bad() { [ "$CTRL" = 1 ] || fail "$*"; }

# control <tag> <bits> <case>: run the case with those parts of the rule
# off; it must end with a block freed under its owner.
control() {
    CTRL=1
    ct_param_set pf_drain_weaken "$2"
    BROKEN=0
    "$3"
    ct_param_set pf_drain_weaken 0
    CTRL=0
    [ "$BROKEN" = 1 ] && pass "$1 CONTROL (pf_drain_weaken=$2): a later drain freed a block under its owner" ||
        fail "$1 CONTROL (pf_drain_weaken=$2): the volume stayed consistent with the rule off -- the case proves nothing"
}
CTRL=0


# A block well past anything these cases allocate, free, for the fillers.
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
dd if=/dev/urandom of="$MNT/probe" bs=4096 count=1 conv=fsync status=none
FILLER=$(($(ext "$MNT/probe") + 3000))
rm -f "$MNT/probe"
ct_umount "$MNT"

# ------------------------------------------------------------------- 1
case1() {
    log "1: a copy past an empty run"
    L="$(stage c1)" || { fail "1 setup: could not stage a queued free"; ct_exit; }
    "$PP" "$IMG" put 0 0 0 "$L" 1 >/dev/null
    "$PP" "$IMG" put 0 3 0 "$L" 1 >/dev/null # blocks 1 and 2 empty
    ct_mount "$DEV" "$MNT"
    ct_param_set pf_drain_min_ms 0
    F="$(grab c1 "$L")" || { fail "1 setup: no file was given the freed block $L"; ct_umount "$MNT"; ct_exit; }
    ct_param_set pf_drain_min_ms 600000
    ok "1 setup: the first drain freed $L and $F was given it"
    [ "$(queued "$L")" = 0 ] && ok "1: no copy of the applied free is left queued" ||
        bad "1: a copy of the free for $L is still queued behind the empty run"
    later_drain c1
    verdict 1 "$F" "$L" c1
}

# ------------------------------------------------------------------- 2
case2() {
    log "2: a copy in a region whose consume keeps losing"
    L="$(stage c2)" || { fail "2 setup: could not stage a queued free"; ct_exit; }
    "$PP" "$IMG" put 0 0 0 "$L" 1 >/dev/null  # region 0: busy
    "$PP" "$IMG" put 0 0 32 "$L" 1 >/dev/null # region 1: consumed
    ct_param_set pf_drain_busy_region 1
    MARK="$(dmesg_mark)"
    ct_mount "$DEV" "$MNT" # the mount's drain: region 0 busy throughout
    # One allocation, the first since the mount: with the cursor at the
    # front it is given L if L is free -- which it must not be while a
    # copy of its free is held.
    dd if=/dev/urandom of="$MNT/k2" bs=4096 count=1 conv=fsync status=none
    K="$(ext "$MNT/k2")"
    [ "$K" != "$L" ] && ok "2: while a copy is held, $L stays allocated (the next file got $K)" ||
        bad "2: $L was handed to a new file while a copy of its free was still queued"
    dmesg_since "$MARK" | grep -q "lba=$L count=1 has a copy still queued" && ok "2: and the hold was reported" ||
        bad "2: no 'copy still queued' line"
    [ "$(queued "$L")" = 1 ] || fail "2 setup: expected exactly the busy region's copy queued, found $(queued "$L")"
    ct_umount "$MNT"
    ct_param_set pf_drain_busy_region 0
    ct_mount "$DEV" "$MNT" # its drain consumes the held copy: the free completes
    [ "$(queued "$L")" = 0 ] && ok "2: the held copy was consumed once its region could be" ||
        bad "2: a copy of the free for $L is still queued after its region came free"
    later_drain c2
    # k2 is the file a wrongly applied copy would have been handed L as;
    # the held copy completing the free must not have touched it either.
    verdict 2 "$MNT/k2" "$K" c2
}

# late_copy <tag> <block> <slot>: a drain of the one queued copy of L,
# stalled between its read and its consumes, and a second copy put at
# <block> <slot> in that window. Leaves the trigger file's name in TRIG.
late_copy() {
    ct_mount "$DEV" "$MNT"
    "$PP" "$IMG" put 0 0 0 "$L" 1 >/dev/null
    ct_param_set pf_drain_consume_stall_ms 2000
    ct_param_set pf_drain_min_ms 0
    TRIG="$MNT/trigger$1"
    dd if=/dev/urandom of="$TRIG" bs=4096 count=1 conv=fsync status=none &
    TPID=$!
    for _ in $(seq 1 60); do [ "$(cat /sys/module/cetrafs/parameters/pf_drain_consume_stall_ms)" = 0 ] && break; sleep 0.05; done
    if [ "$(cat /sys/module/cetrafs/parameters/pf_drain_consume_stall_ms)" != 0 ]; then
        fail "$1 setup: no drain reached its consume"
        ct_param_set pf_drain_consume_stall_ms 0
        wait "$TPID" || true
        ct_umount "$MNT"
        ct_exit
    fi
    "$PP" "$IMG" put 0 "$2" "$3" "$L" 1 >/dev/null
    wait "$TPID"
    ct_param_set pf_drain_min_ms 600000
}

# ------------------------------------------------------------------- 3
case3() {
    log "3: a copy appended between a drain's read and its swap"
    L="$(stage c3)" || { fail "3 setup: could not stage a queued free"; ct_exit; }
    late_copy 3 0 1 # the same region, after the read
    # The trigger's own allocation follows the drain it ran, so it is the
    # first candidate for L.
    ct_param_set pf_drain_min_ms 0
    if [ "$(ext "$TRIG")" = "$L" ]; then
        F="$TRIG"
    else
        F="$(grab c3 "$L")" || { fail "3 setup: no file was given the freed block $L"; ct_umount "$MNT"; ct_exit; }
    fi
    ct_param_set pf_drain_min_ms 600000
    ok "3 setup: the drain freed $L and $F was given it"
    [ "$(queued "$L")" = 0 ] && ok "3: the copy appended during the drain was consumed with the one it read" ||
        bad "3: a copy of the free for $L is still queued after the drain that applied it"
    later_drain c3
    verdict 3 "$F" "$L" c3
}

# ------------------------------------------------------------------- 4
case4() {
    log "4: a copy appended during a drain into a region its read found empty"
    L="$(stage c4)" || { fail "4 setup: could not stage a queued free"; ct_exit; }
    MARK="$(dmesg_mark)"
    late_copy 4 1 0 # queue block 1, region 0: empty at the read, never swapped
    if [ "$CTRL" = 1 ]; then
        # Unheld, the first copy was applied: L is free, and a file gets it.
        ct_param_set pf_drain_min_ms 0
        if [ "$(ext "$TRIG")" = "$L" ]; then
            F="$TRIG"
        else
            F="$(grab c4 "$L")" || { fail "4 CONTROL setup: no file was given the freed block $L"; ct_umount "$MNT"; ct_exit; }
        fi
        ct_param_set pf_drain_min_ms 600000
    else
        [ "$(queued "$L")" = 1 ] || fail "4 setup: expected the late copy alone queued, found $(queued "$L")"
        dmesg_since "$MARK" | grep -q "lba=$L count=1 has a copy still queued" &&
            pass "4: the re-read after consuming found the late copy and held the free" ||
            fail "4: the drain applied $L with a copy of its free still queued in a region it never swapped"
        # While held, L stays allocated: the next file goes elsewhere.
        dd if=/dev/urandom of="$MNT/k4" bs=4096 count=1 conv=fsync status=none
        [ "$(ext "$MNT/k4")" != "$L" ] && pass "4: and $L was not handed out meanwhile" ||
            fail "4: $L was handed to a new file while a copy of its free was still queued"
        F="$MNT/k4"
    fi
    later_drain c4 # consumes the late copy: with the hold, frees L, which nobody has
    if [ "$CTRL" = 1 ]; then
        verdict 4 "$F" "$L" c4
    else
        verdict 4 "$F" "$(ext "$F")" c4
    fi
}

case1
case2
case3
case4
control 1 9 case1
control 2 4 case2
control 3 10 case3
control 4 8 case4
ct_exit
