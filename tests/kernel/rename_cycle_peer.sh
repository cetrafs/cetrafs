#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory move never closes a loop with a peer's move -- the tree stays reachable
#
# Node A runs `mv P Q/` while node B runs `mv Q P/`. The VFS stops a
# rename that would put a directory inside itself, but it decides from
# THIS node's dentry cache, and node B's move is not in it: A's lookups
# ran before B's rename landed. Both renames then succeeded, P and Q
# each became the other's child, and both left the tree -- unreachable
# from the root, invisible to every node, with everything under them.
#
# Directory moves to another parent now take one cluster-wide lock (the
# root directory's namespace lock) and, holding it, walk '..' up from
# the destination with fresh reads, refusing a move whose destination
# lies under the directory being moved.
#
# Node B is played by dir_move_poke on the backing image, landed inside
# rename_prelock_stall_ms: after A's lookups, before A's locks -- where
# B's move lands in the real race.
#
# DISCRIMINATION (measured on the unfixed code): node A's rename
# succeeds, the root lists nothing, and fsck reports "directory 2 is in
# a parent CYCLE that never reaches the root".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
MOVE_POKE="$(ct_helper dir_move_poke)"

DEV="$(ct_dev 560 rncyc)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt rncyc)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/P" "$MNT/Q"
echo keep >"$MNT/Q/inside"
ROOT_INO="$(stat -c %i "$MNT")"
P_INO="$(stat -c %i "$MNT/P")"
sync
stat "$MNT/P" "$MNT/Q" >/dev/null # this node's dentries for both

ct_param_set rename_prelock_stall_ms 1500
OUT="$(ct_tmp rncyc-out)"
python3 -c '
import errno, os, sys
try:
    os.rename(sys.argv[1], sys.argv[2]); print("OK")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$MNT/P" "$MNT/Q/P" >"$OUT" &
MVPID=$!
sleep 0.5
"$MOVE_POKE" "$BACK" "$ROOT_INO" Q "$P_INO" >/dev/null # node B: mv Q P/
wait "$MVPID" || true
ct_param_set rename_prelock_stall_ms 0
res="$(cat "$OUT")"
log "node A's rename(P, Q/P): $res"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
log "the tree after both moves: $(cd "$MNT" && find . | sort | tr '\n' ' ')"
if [ -d "$MNT/P/Q" ] && [ "$(cat "$MNT/P/Q/inside" 2>/dev/null)" = keep ]; then
    pass "the tree is intact: P/Q/inside is reachable from the root"
else
    fail "P/Q/inside is not reachable from the root -- the two moves closed a loop"
fi
[ "$res" = EINVAL ] && pass "node A's move, which would have closed the loop, was refused with EINVAL" ||
    fail "node A's move returned $res, not EINVAL"

ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean" || fail "fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
