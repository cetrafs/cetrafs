#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a Block Group whose cached bitmap cannot be dropped is never allocated from
#
# Claiming a Zone Group drops this node's cached view of every member
# Block Group, so the allocator reads what the previous owner really
# left. The drop needs the descriptor (it says where the bitmap is), and
# when that read failed the drop returned early -- the error ignored by
# every caller -- and the node allocated from a bitmap cached from an
# earlier look, which can read a peer's allocations as free (audit
# 2026-11-14 A7). A group whose drop fails is now left out of reach.
#
# Baseline: a fresh volume, mounted, a file written; the Block Group the
# allocator chose is G. Then again with G's drop failing at the claim:
#   1. no block of the file lands in G;
#   2. the file still reads back.
#
# DISCRIMINATION: bg_invalidate_fail_ignored ignores the failure, as
# before; the file then lands in G.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for k in bg_invalidate_fail_bg bg_invalidate_fail_ignored; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done
MAP="$(ct_helper bg_map)"
MNT="$(ct_mnt bgif)"
ct_track mnt "$MNT"
ct_param_set bg_invalidate_fail_bg 0
ct_param_set bg_invalidate_fail_ignored 0
P=/sys/module/cetrafs/parameters

# <fail_bg> <ignored> -> "<bg:used-blocks ...> <file ok|bad>"
probe() {
    local img dev before after ok sum
    img="$(ct_image 1200 "bgif$1$2")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    before="$("$MAP" "$img" | awk '$1 == "bg" { split($5, f, "[=/]"); print $2, f[2] }')"
    echo "$1" >$P/bg_invalidate_fail_bg
    echo "$2" >$P/bg_invalidate_fail_ignored
    ct_mount "$dev" "$MNT"
    echo 0 >$P/bg_invalidate_fail_bg
    echo 0 >$P/bg_invalidate_fail_ignored
    dd if=/dev/urandom of="$MNT/f" bs=1M count=8 status=none
    sync
    sum="$(md5sum <"$MNT/f" | cut -d' ' -f1)"
    ct_umount "$MNT"
    ct_mount "$dev" "$MNT"
    [ "$(md5sum <"$MNT/f" | cut -d' ' -f1)" = "$sum" ] && ok=ok || ok=bad
    ct_umount "$MNT"
    after="$("$MAP" "$img" | awk '$1 == "bg" { split($5, f, "[=/]"); print $2, f[2] }')"
    # Blocks each group lost to the file: free before minus free after.
    join <(echo "$before") <(echo "$after") | awk '$2 != $3 { printf "%s:%d ", $1, $2 - $3 }'
    echo "$ok"
}

BASE="$(probe 0 0)"
log "baseline: $BASE"
G="$(echo "$BASE" | tr ' ' '\n' | grep : | sort -t: -k2 -n | tail -1 | cut -d: -f1)"
[ -n "$G" ] || { fail "setup: the file landed in no Block Group"; ct_exit; }
R="$(probe $((G + 1)) 0)"
log "BG $G's drop failing: $R"
case " $R " in
*" $G:"*) fail "1: the file landed in BG $G, whose cached bitmap was never dropped ($R)" ;;
*) pass "1: nothing was allocated from BG $G, whose cached bitmap could not be dropped" ;;
esac
[ "${R##* }" = ok ] && pass "2: the file reads back" || fail "2: the file does not read back"
R0="$(probe $((G + 1)) 1)"
log "control (failure ignored): $R0"
case " $R0 " in
*" $G:"*) pass "control: ignoring the failure allocates from BG $G -- the suite discriminates" ;;
*) fail "control: BG $G was not used even with the failure ignored -- the suite cannot tell" ;;
esac
ct_exit
