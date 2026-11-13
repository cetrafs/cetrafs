#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a refresh never applies a record that a local publish has superseded
#
# The refresh behind stat and lookup reads a record under the publish
# mutex. A publish that lands after that read must not be undone by
# applying the read. A directory's create publishes its file sector from
# the namespace lock's release. That publish now takes the same mutex as
# every other file-sector publisher (BUG-CLASSES class 29), so the create
# WAITS for a stalled refresh and lands after it. The control knobs put
# the old unlocked publish back, and the old age-ordered verdict.
#
# Staged on one directory D, per round:
#   1. D's device record is stamped X = now + 3 s, this node's own, with
#      no note (file_seq_skip_note): a stamp in the FUTURE of this mount's
#      clock, so it is younger than any publish made within those 3 s.
#   2. A background stat of D's path starts a refresh. It reads X and
#      stalls (refresh_compare_stall_ms) with the publish mutex held.
#   3. Through a descriptor on D, so no path lookup re-enters the refresh,
#      create a file. Its nslock release publishes D with a stamp N and
#      notes it.
#   4. The verdict runs after the stall. It must NOT apply a record the
#      create superseded: the in-core size of D must match what the
#      refresh read, and after the create completes, the device.
#
# Rounds (lock = the release takes fd_pub; legacy = the age verdict):
#   main          lock on,  legacy off: the create WAITS for the verdict, which
#                 applies X (the device as it stood), then the create lands.
#   ctl_settle    lock off, legacy off: the create lands during the stall; the
#                 verdict's re-read settles on N. The defence in depth.
#   ctl_age       lock off, legacy on:  the create lands during the stall and
#                 the old age verdict applies X -- in-core reverts. The bug.
#   ctl_age_lock  lock on,  legacy on:  no revert: the lock alone closes it.
#
# Setup checks fail on their own line: the refresh must reach the stall,
# the create must wait (lock) or land (no lock), the superseded branch
# must be taken, and the stamps must be in the order the staging needs.
# NOT COVERED: a regular file. Its publishers take fd_pub_mutex too, so
# none can land in the stall; this suite stages the directory path only.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in refresh_compare_stall_ms refresh_seq_age_compare file_seq_force_val file_seq_skip_note nslock_fd_publish_unlocked; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 refsup)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt refsup)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NODE="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
INFO="$(ct_procdir "$DEV")/info"

MASK=$(( (1 << 48) - 1 ))
FUTURE_NS=3000000000   # X sits this far ahead of the staging clock
STALL_MS=6000          # the verdict runs after X is in the past

counter() { sed -n "s/^$1: //p" "$INFO"; }

# stamp_of <inode>: "low48 node" of the device record's file_seq.
stamp_of() {
    local hex node
    read -r hex node <<<"$("$POKE" "$IMG" seq "$1" 2>&1 | head -1)"
    echo "$(( 0x$hex & MASK )) $node"
}

# in_core <dir>: the size the open descriptor's inode reports. -L: a
# plain stat of a /proc magic link reports the link (64), not the file.
in_core() { stat -L -c %s /proc/$$/fd/3; }

declare -A FINAL=()

# round <name> <legacy 0|1> <unlocked 0|1>: one directory, staged as above.
round() {
    local name="$1" legacy="$2" unlocked="$3" D="$MNT/d.$1" ino now x st stnode sn dn
    local pre dev_pre dev_during dev_mid dev_final post bg cpid crc rc=0
    local stalls0 cands0 refused0 stalls1 cands1 refused1 creating_during verdict_during
    local VERDICT_OUT CREATE_RC

    mkdir "$D"
    touch "$D/seed"
    sync
    ino="$(stat -c %i "$D")"
    exec 3<"$D" # a descriptor on D: creates through it do not re-enter D's refresh

    now=$(date +%s%N)
    x=$(( (now + FUTURE_NS) & MASK ))
    ct_param_set file_seq_force_val "$x"
    ct_param_set file_seq_skip_note 1
    touch "$D/staged"
    ct_param_set file_seq_force_val 0
    ct_param_set file_seq_skip_note 0

    read -r st stnode <<<"$(stamp_of "$ino")"
    if [ "$st" != "$x" ] || [ "$stnode" != "$NODE" ]; then
        fail "$name setup: the staged publish did not stamp X=$x as own node $NODE (device: $st node $stnode)"
        exec 3<&-
        return 1
    fi

    pre=$(in_core)
    dev_pre=$("$POKE" "$IMG" size "$ino" 2>&1 | head -1)
    stalls0=$(counter refresh_stalls)
    cands0=$(counter refresh_seq_candidates)
    refused0=$(counter refresh_seq_refused)
    ct_param_set nslock_fd_publish_unlocked "$unlocked"
    ct_param_set refresh_seq_age_compare "$legacy"
    ct_param_set refresh_compare_stall_ms "$STALL_MS"

    VERDICT_OUT="$(ct_tmp)"
    CREATE_RC="$(ct_tmp)"
    stat -c %s "$D" >"$VERDICT_OUT" 2>/dev/null &
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
        fail "$name setup: the refresh never reached its stall -- nothing was held open to race"
        return 1
    fi

    (timeout 30 touch /proc/$$/fd/3/late; echo $? >"$CREATE_RC") &
    cpid=$!
    dev_mid=; creating_during=no; verdict_during=no
    if [ "$unlocked" = 0 ]; then
        # The create must be HELD by the refresh: still running a second
        # into the stall, nothing on the device yet, and the verdict too.
        sleep 1
        kill -0 "$cpid" 2>/dev/null && creating_during=yes
        dev_during=$("$POKE" "$IMG" size "$ino" 2>&1 | head -1)
        kill -0 "$bg" 2>/dev/null && verdict_during=yes
        wait "$bg" 2>/dev/null || true
        wait "$cpid" 2>/dev/null || true
    else
        # No publish mutex: the create lands while the refresh is stalled.
        wait "$cpid" 2>/dev/null || true
        dev_mid=$("$POKE" "$IMG" size "$ino" 2>&1 | head -1)
        wait "$bg" 2>/dev/null || true
    fi
    ct_param_set refresh_compare_stall_ms 0
    post=$(cat "$VERDICT_OUT")
    crc=$(cat "$CREATE_RC" 2>/dev/null || echo missing)
    stalls1=$(counter refresh_stalls)
    cands1=$(counter refresh_seq_candidates)
    refused1=$(counter refresh_seq_refused)
    dev_final=$("$POKE" "$IMG" size "$ino" 2>&1 | head -1)
    read -r sn _ <<<"$(stamp_of "$ino")"
    dn=$(( (sn - now) & MASK ))
    ic_final=$(in_core)
    exec 3<&-
    ct_param_set refresh_seq_age_compare 0
    ct_param_set nslock_fd_publish_unlocked 0
    FINAL[$name]="$dev_final"

    log "$name: device size before the stall $dev_pre; during the stall ${dev_during:-n/a}, after the create ${dev_mid:-n/a}; final device $dev_final (create rc $crc); in-core before $pre, at the verdict $post, after the create $ic_final (X=$x, N=$sn, N is ${dn} ns after staging)"
    log "$name: stalls +$((stalls1 - stalls0)), superseded candidates +$((cands1 - cands0)), refused +$((refused1 - refused0))"

    # Setup: the refresh reached the stalled verdict and judged X.
    if [ "$((cands1 - cands0))" -lt 1 ]; then
        fail "$name setup: the refresh took no superseded branch -- X was never judged against the note"
        return 1
    fi
    if [ "$unlocked" = 0 ]; then
        if [ "$creating_during" != yes ] || [ "$dev_during" != "$dev_pre" ]; then
            fail "$name setup: the create was not held by the refresh (still running: $creating_during; device $dev_pre -> ${dev_during:-?} during the stall)"
            return 1
        fi
        if [ "$verdict_during" != yes ]; then
            fail "$name setup: the verdict had already finished when the create was checked -- the stall was not held"
            return 1
        fi
    else
        if [ "$dev_mid" = "$dev_pre" ]; then
            fail "$name setup: the create did not land on the device during the stall (size $dev_pre -> $dev_mid)"
            return 1
        fi
        if [ "$dn" -ge "$FUTURE_NS" ] || [ "$dn" -le 0 ]; then
            fail "$name setup: the create's stamp is not inside the 3 s before X (+${dn} ns) -- the race is not staged"
            return 1
        fi
    fi

    if [ "$crc" != 0 ]; then
        fail "$name: the create did not complete (rc $crc)"
        return 0
    fi
    # With the publish mutex the verdict either applies X (the device as it
    # read it) or declines and leaves in-core as the create set it: the
    # create's own in-core size goes ahead of its publish, and the verdict
    # declined in the observed run (the reason is not traced). What it
    # must never do is apply X AFTER the create published: that would
    # leave in-core at X with the device at the post-create size.
    if [ "$unlocked" = 0 ]; then
        how=""
        [ "$post" = "$dev_pre" ] && how="the verdict applied X before the create's publish"
        [ "$post" = "$dev_final" ] && how="the verdict declined; in-core kept the create's own size"
        if [ "$((refused1 - refused0))" -ne 0 ] && [ "$legacy" = 0 ]; then
            fail "$name: the settle refused the refresh ($((refused1 - refused0)) time(s)) -- in-core was left stale"
        elif [ -z "$how" ]; then
            fail "$name: the verdict saw size $post, neither X ($dev_pre) nor the post-create size ($dev_final) -- a superseded record was applied"
        elif [ "$ic_final" != "$dev_final" ]; then
            fail "$name: in-core after the create is $ic_final, the device holds $dev_final"
        elif [ "$legacy" = 0 ]; then
            pass "$name: the create waited for the refresh and landed after it; $how (in-core and device $dev_final)"
        else
            pass "$name control: with the publish mutex the create waits even under the old age verdict; $how (device $dev_final)"
        fi
    elif [ "$legacy" = 0 ]; then
        if [ "$((refused1 - refused0))" -ne 0 ]; then
            fail "$name control: the settle refused the refresh -- in-core was left stale"
        elif [ "$post" = "$dev_mid" ]; then
            pass "$name control: with the publish unlocked, the re-read settle caught the create (verdict $post = the device after the create)"
        else
            fail "$name control: verdict $post, the device held $dev_mid after the create -- the settle missed a publish it could see"
        fi
    else
        if [ "$post" = "$dev_pre" ] && [ "$dev_mid" != "$dev_pre" ] && [ "$((refused1 - refused0))" -eq 0 ]; then
            pass "$name control: unlocked publish + old age verdict applied X and reverted in-core to $post (device $dev_mid) -- the bug reproduced"
        else
            fail "$name control: the old age compare did not revert (X size $dev_pre, device $dev_mid, in-core $post, refused +$((refused1 - refused0))) -- the race is not discriminating"
        fi
    fi
}

round main 0 0
round ctl_settle 0 1
round ctl_age 1 1
round ctl_age_lock 1 0

# The device must agree with memory after a remount, and fsck must be clean.
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for name in main ctl_settle ctl_age ctl_age_lock; do
    have="$(ls -A "$MNT/d.$name" | sort | tr '\n' ' ')"
    got="$(stat -c %s "$MNT/d.$name")"
    [ "$have" = "late seed staged " ] && [ "$got" = "${FINAL[$name]}" ] &&
        pass "$name: after a remount the directory lists late seed staged at size $got" ||
        fail "$name: after a remount the directory is ($have) at size $got, want the device size ${FINAL[$name]}"
done
ct_umount "$MNT"
rc=0
FO="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck is clean after the rounds" || fail "fsck failed (rc $rc): $FO"
ct_exit
