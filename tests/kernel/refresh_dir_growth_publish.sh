#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a refresh never applies a directory's pre-growth record over its growth
#
# A create that needs a new dirent block grows the directory. The growth
# publishes the directory's whole record, its file sector included, from
# the block-map write (__cetrafs_get_block -> cetrafs_write_raw_inode_self).
# That write runs under the directory's fd publish mutex (BUG-CLASSES
# class 29), so a refresh that read the record before the growth waits,
# or applies its read before the growth publish lands. The directory's
# extent tree is what a revert would undo: the new block would vanish
# from in-core until the next refresh.
#
# Staged on one directory D (a fresh directory grows on its 13th file):
#   1. seed, ten files, then 'staged' (the 12th file, still one block) are
#      created. 'staged' is stamped X = now (this node's own, no note:
#      file_seq_force_val + file_seq_skip_note), so it is a candidate the
#      verdict must judge. In-core blocks = device blocks = B0.
#   2. A background stat of D starts a refresh: it reads X and stalls
#      (refresh_compare_stall_ms) with the publish mutex held.
#   3. Through a descriptor on D, create 'late' -- the 13th file, which
#      grows D from one block to two (device blocks B0 -> B1).
#   4. The verdict must not apply the pre-growth record after the growth
#      published.
#
# Two publishers in that create can be unlocked by knob: the whole-record
# growth (record_publish_unlocked) and the namespace release that publishes
# the size (nslock_fd_publish_unlocked, which runs after the growth).
#
# Rounds (rec / rel = the two publishers unlocked; legacy = age verdict):
#   main        rec 0 rel 0 legacy 0: the growth waits for the verdict; the
#               verdict sees B0 (applied before) or B1 (declined). Never B0
#               after B1 was published.
#   ctl_settle  rec 1 rel 1 legacy 0: the growth and the create land in the
#               stall; the re-read settle catches them and reads B1.
#   ctl_age     rec 1 rel 1 legacy 1: the create completes in the stall with
#               its in-core state clean, and the age verdict applies X -- in
#               core reverts to B0. The bug.
#   ctl_age_lock rec 0 rel 0 legacy 1: no revert: the lock alone closes it.
#   ctl_rec_lock rec 0 rel 1 legacy 1: the release is unlocked, but the growth
#               waits first, so the create never publishes in the stall: no
#               revert. The whole-record lock alone is what closes it.
#   ctl_guard   rec 1 rel 0 legacy 1: the growth lands in the stall but the
#               create's release is still locked, so the create's own
#               unpublished in-core size is there and the verdict DECLINES
#               (the dirty guard). Not a revert, and the guard's reason.
#
# Setup checks fail on their own line: the growth really happened, the
# growth was held (rec 0) or landed (rec 1), and the verdict judged X.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in refresh_compare_stall_ms refresh_seq_age_compare file_seq_force_val file_seq_skip_note \
    record_publish_unlocked nslock_fd_publish_unlocked; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 grow)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt grow)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NODE="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
INFO="$(ct_procdir "$DEV")/info"

MASK=$(( (1 << 48) - 1 ))
STALL_MS=6000
FUTURE_NS=3000000000
counter() { sed -n "s/^$1: //p" "$INFO"; }

# dev_blocks <ino>: the device's block count, the sum of the extent
# lengths (poke "extents" prints one len= per extent, in 4 KiB blocks).
dev_blocks() {
    "$POKE" "$IMG" extents "$1" 2>&1 | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^len=/) { split($i, a, "="); s += a[2] } } END { print s + 0 }'
}
# stat reports %b in 512-byte units; a cetrafs block is 4 KiB (8 units).
in_core_blocks() { echo $(( $(stat -L -c %b /proc/$$/fd/3) / 8 )); }
in_core_size() { stat -L -c %s /proc/$$/fd/3; }

declare -A FINAL=()
declare -A FINAL_SIZE=()

# round <name> <rec 0|1> <rel 0|1> <legacy 0|1>
round() {
    local name="$1" rec="$2" rel="$3" legacy="$4" D="$MNT/g.$1" ino i
    local b0 b_during b_final pre_ic post_ic post_size post_units bg cpid crc
    local stalls0 cands0 refused0 stalls1 cands1 refused1 creating_during verdict_during
    local VERDICT_OUT CREATE_RC now x hex node how ic_final size_final

    mkdir "$D"
    touch "$D/seed"
    for i in 1 2 3 4 5 6 7 8 9 10 11; do : >"$D/f$i"; done
    sync
    ino="$(stat -c %i "$D")"
    exec 3<"$D"

    now=$(date +%s%N)
    x=$(( (now + FUTURE_NS) & MASK ))   # X is in the future of the note the create makes: the age verdict misjudges it
    ct_param_set file_seq_force_val "$x"
    ct_param_set file_seq_skip_note 1
    : >"/proc/$$/fd/3/staged"
    ct_param_set file_seq_force_val 0
    ct_param_set file_seq_skip_note 0
    read -r hex node <<<"$("$POKE" "$IMG" seq "$ino" 2>&1 | head -1)"
    if [ "$(( 0x$hex & MASK ))" != "$x" ] || [ "$node" != "$NODE" ]; then
        fail "$name setup: the staged publish did not stamp own seq $x (device: $hex node $node)"
        exec 3<&-
        return 1
    fi
    b0=$(dev_blocks "$ino")
    pre_ic=$(in_core_blocks)
    if [ "$b0" != "$pre_ic" ]; then
        fail "$name setup: in-core blocks $pre_ic and device blocks $b0 differ before the stall"
        exec 3<&-
        return 1
    fi

    stalls0=$(counter refresh_stalls)
    cands0=$(counter refresh_seq_candidates)
    refused0=$(counter refresh_seq_refused)
    ct_param_set record_publish_unlocked "$rec"
    ct_param_set nslock_fd_publish_unlocked "$rel"
    ct_param_set refresh_seq_age_compare "$legacy"
    ct_param_set refresh_compare_stall_ms "$STALL_MS"

    VERDICT_OUT="$(ct_tmp)"
    CREATE_RC="$(ct_tmp)"
    stat -c '%s %b' "$D" >"$VERDICT_OUT" 2>/dev/null &
    bg=$!
    for _ in $(seq 1 150); do
        [ "$(counter refresh_stalls)" -gt "$stalls0" ] && break
        sleep 0.1
    done
    if [ "$(counter refresh_stalls)" -le "$stalls0" ]; then
        ct_param_set refresh_compare_stall_ms 0
        kill "$bg" 2>/dev/null || true
        wait "$bg" 2>/dev/null || true
        exec 3<&-
        fail "$name setup: the refresh never reached its stall"
        return 1
    fi

    (timeout 30 touch /proc/$$/fd/3/late; echo $? >"$CREATE_RC") &
    cpid=$!
    # Sampled a second into the stall (it holds for 6 s).
    sleep 1
    creating_during=no; kill -0 "$cpid" 2>/dev/null && creating_during=yes
    verdict_during=no; kill -0 "$bg" 2>/dev/null && verdict_during=yes
    b_during=$(dev_blocks "$ino")
    wait "$bg" 2>/dev/null || true
    wait "$cpid" 2>/dev/null || true
    ct_param_set refresh_compare_stall_ms 0
    read -r post_size post_units <<<"$(cat "$VERDICT_OUT")"
    post_ic=$(( post_units / 8 ))
    crc=$(cat "$CREATE_RC" 2>/dev/null || echo missing)
    stalls1=$(counter refresh_stalls)
    cands1=$(counter refresh_seq_candidates)
    refused1=$(counter refresh_seq_refused)
    b_final=$(dev_blocks "$ino")
    ic_final=$(in_core_blocks)
    size_final=$("$POKE" "$IMG" size "$ino" 2>&1 | head -1)   # the device, not in-core: a revert is in-core only
    exec 3<&-
    ct_param_set refresh_seq_age_compare 0
    ct_param_set nslock_fd_publish_unlocked 0
    ct_param_set record_publish_unlocked 0
    FINAL[$name]="$b_final"
    FINAL_SIZE[$name]="$size_final"

    log "$name: device blocks before the stall $b0; one second into the stall: create running $creating_during, device $b_during, verdict running $verdict_during; final $b_final (create rc $crc); verdict blocks $post_ic (size $post_size), in-core after the create $ic_final"
    log "$name: stalls +$((stalls1 - stalls0)), superseded candidates +$((cands1 - cands0)), refused +$((refused1 - refused0))"

    if [ "$((cands1 - cands0))" -lt 1 ]; then
        fail "$name setup: the refresh took no superseded branch -- X was never judged against the note"
        return 1
    fi
    if [ "$crc" != 0 ]; then
        fail "$name: the create did not complete (rc $crc)"
        return 0
    fi
    if [ "$b_final" = "$b0" ]; then
        fail "$name setup: the create did not grow the directory (blocks stayed $b0)"
        return 1
    fi
    if [ "$verdict_during" != yes ]; then
        fail "$name setup: the verdict had already finished one second into the stall"
        return 1
    fi
    if [ "$rec" = 0 ]; then
        if [ "$creating_during" != yes ] || [ "$b_during" != "$b0" ]; then
            fail "$name setup: the growth was not held by the refresh (create running: $creating_during; device blocks $b0 -> $b_during)"
            return 1
        fi
    elif [ "$b_during" = "$b0" ]; then
        fail "$name setup: the unlocked growth did not publish during the stall (device blocks $b0)"
        return 1
    fi

    if [ "$((refused1 - refused0))" -ne 0 ] && [ "$legacy" = 0 ]; then
        fail "$name: the settle refused the refresh -- in-core was left stale"
    elif [ "$rec" = 0 ]; then
        how=""
        [ "$post_ic" = "$b0" ] && how="the verdict applied X before the growth's publish"
        [ "$post_ic" = "$b_final" ] && how="the verdict declined; in-core kept the growth's own blocks"
        if [ -z "$how" ]; then
            fail "$name: the verdict saw $post_ic blocks, neither B0 ($b0) nor the grown record ($b_final) -- a superseded record was applied"
        elif [ "$ic_final" != "$b_final" ]; then
            fail "$name: in-core blocks after the create are $ic_final, the device holds $b_final"
        elif [ "$legacy" = 0 ]; then
            pass "$name: the growth waited for the refresh and published after it; $how (in-core and device $b_final blocks)"
        else
            pass "$name control: with the publish mutex the growth waits even under the old age verdict; $how"
        fi
    elif [ "$rel" = 1 ] && [ "$legacy" = 0 ]; then
        if [ "$post_ic" = "$b_during" ]; then
            pass "$name control: unlocked publishes, the re-read settle caught the growth (verdict $post_ic blocks = the device during the stall)"
        else
            fail "$name control: the verdict saw $post_ic blocks, the device held $b_during -- the settle missed a publish it could see"
        fi
    elif [ "$rel" = 1 ]; then
        if [ "$post_ic" = "$b0" ] && [ "$b_during" != "$b0" ]; then
            pass "$name control: unlocked publishes + old age verdict applied X and reverted in-core to $post_ic blocks (device $b_during) -- the bug reproduced"
        else
            fail "$name control: the old age compare did not revert (verdict $post_ic blocks, device $b_during) -- the race is not discriminating"
        fi
    else
        if [ "$post_ic" = "$b_final" ] && [ "$ic_final" = "$b_final" ]; then
            pass "$name control: the growth is unlocked but the create's release is held, so the verdict declined on the create's unpublished size (verdict $post_ic blocks, no revert)"
        else
            fail "$name control: the verdict saw $post_ic blocks (device $b_during, final $b_final) -- the dirty guard did not hold the verdict off"
        fi
    fi
}

round main 0 0 0
round ctl_settle 1 1 0
round ctl_age 1 1 1
round ctl_age_lock 0 0 1
round ctl_guard 1 0 1
round ctl_rec_lock 0 1 1

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
want="f1 f10 f11 f2 f3 f4 f5 f6 f7 f8 f9 late seed staged "
for name in main ctl_settle ctl_age ctl_age_lock ctl_guard ctl_rec_lock; do
    have="$(ls -A "$MNT/g.$name" | sort | tr '\n' ' ')"
    got="$(stat -c %s "$MNT/g.$name")"
    [ "$have" = "$want" ] && [ "$got" = "${FINAL_SIZE[$name]}" ] &&
        pass "$name: after a remount the directory lists all 13 entries at size $got" ||
        fail "$name: after a remount the directory is ($have) at size $got, want size ${FINAL_SIZE[$name]}"
done
ct_umount "$MNT"
rc=0
FO="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck is clean after the rounds" || fail "fsck failed (rc $rc): $FO"
ct_exit
