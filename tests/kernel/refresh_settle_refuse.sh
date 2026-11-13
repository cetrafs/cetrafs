#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a settle that cannot agree with its re-read refuses and leaves in-core alone
#
# A refresh that reads a record stamped with this node's own file_seq,
# not the one our last publish noted, settles it by re-reading the record
# and the note (cetrafs_refresh_settle). When the re-reads never agree
# the settle gives up after CETRAFS_REFRESH_SETTLE_TRIES re-reads and
# refuses: in-core is left as it was, and the next refresh tries again.
# That path is otherwise unreachable on purpose, so the test knob
# refresh_settle_churn makes every re-read disagree.
#
# Staged on one directory D:
#   1. A publish stamps D with this node's own seq and skips the note
#      (file_seq_skip_note): a candidate the settle must judge.
#   2. A stat applies it (no churn): in-core takes the device size S1.
#   3. The device size is changed behind the mount to Z (setsize keeps the
#      stamp, so the record is still that same candidate).
#   4. churn ON:  a stat must refuse -- refused +1, four re-reads, and the
#      in-core size stays S1.
#   5. churn OFF (the control): the same stat applies the record, in-core
#      becomes Z, nothing is refused.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in refresh_settle_churn file_seq_force_val file_seq_skip_note; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
POKE="$(ct_helper inode_block_poke)"

IMG="$(ct_image 560 refuse)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt refuse)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NODE="$(sed -n 's/^this_node_id: //p' "$(ct_procdir "$DEV")/info")"
INFO="$(ct_procdir "$DEV")/info"
MASK=$(( (1 << 48) - 1 ))

counter() { sed -n "s/^$1: //p" "$INFO"; }
in_core() { stat -c %s "$MNT/d"; }   # path stat: refresh, then the in-core size

D="$MNT/d"
mkdir "$D"
touch "$D/seed"
sync
ino="$(stat -c %i "$D")"

x=$(( $(date +%s%N) & MASK ))
ct_param_set file_seq_force_val "$x"
ct_param_set file_seq_skip_note 1
touch "$D/staged"
ct_param_set file_seq_force_val 0
ct_param_set file_seq_skip_note 0
read -r hex node <<<"$("$POKE" "$IMG" seq "$ino" 2>&1 | head -1)"
if [ "$(( 0x$hex & MASK ))" != "$x" ] || [ "$node" != "$NODE" ]; then
    fail "setup: the staged publish did not stamp own seq $x (device: $hex node $node)"
    ct_exit
fi

# 2. Apply the candidate once, so in-core and the device agree on S1.
s1=$(in_core)
dev_s1=$("$POKE" "$IMG" size "$ino" 2>&1 | head -1)
[ "$s1" = "$dev_s1" ] || { fail "setup: the first stat did not apply the staged record (in-core $s1, device $dev_s1)"; ct_exit; }

# 3. A peer's size change behind the mount, under the same stamp.
Z=$(( s1 + 4096 ))
"$POKE" "$IMG" setsize "$ino" "$Z" >/dev/null 2>&1
[ "$("$POKE" "$IMG" size "$ino" 2>&1 | head -1)" = "$Z" ] || { fail "setup: the device size did not change to $Z"; ct_exit; }

# 4. churn ON: the settle cannot agree, so it refuses.
c0=$(counter refresh_seq_candidates); r0=$(counter refresh_seq_refused)
ct_param_set refresh_settle_churn 1
got="$(in_core)"
ct_param_set refresh_settle_churn 0
c1=$(counter refresh_seq_candidates); r1=$(counter refresh_seq_refused)
log "churn on: in-core reports $got (S1 $s1, device $Z); candidates +$((c1 - c0)), refused +$((r1 - r0))"
if [ "$((c1 - c0))" -ne 4 ]; then
    fail "churn on: the settle judged $((c1 - c0)) candidate(s), want exactly 4 re-reads -- the refresh did not reach the settle"
elif [ "$((r1 - r0))" -ne 1 ]; then
    fail "churn on: refused +$((r1 - r0)), want +1 -- the settle did not refuse after its re-reads"
elif [ "$got" = "$s1" ]; then
    pass "churn on: the settle ran its 4 re-reads and refused; in-core stayed at $s1 (device $Z)"
else
    fail "churn on: the refused refresh still changed in-core to $got (want $s1)"
fi

# 5. Control, knob off: the same record is applied.
r2=$(counter refresh_seq_refused)
got="$(in_core)"
r3=$(counter refresh_seq_refused)
if [ "$r3" -ne "$r2" ]; then
    fail "control: the knob-off refresh was refused (refused +$((r3 - r2)))"
elif [ "$got" = "$Z" ]; then
    pass "control: with the knob off the same record is applied; in-core is $Z"
else
    fail "control: with the knob off in-core is $got, want the device size $Z -- the refusal proved nothing"
fi

# Put the record's size back to what its entries add up to, so fsck
# judges the structure this suite did not touch, not the size it poked.
"$POKE" "$IMG" setsize "$ino" "$s1" >/dev/null 2>&1
[ "$(in_core)" = "$s1" ] || fail "cleanup: the restored device size $s1 did not reach in-core"

ct_umount "$MNT"
rc=0
FO="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck is clean" || fail "fsck failed (rc $rc): $FO"
ct_exit
