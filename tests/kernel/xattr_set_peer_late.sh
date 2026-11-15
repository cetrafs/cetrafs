#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a setxattr asks "is a peer using this file?" again right before it publishes, not only at its start
#
# setxattr refuses (ETXTBSY) when a live peer has the file locked or
# open: rewriting its metadata under a peer that has it open breaks the
# one-writer rule. It asked once, at the start, then allocated, wrote
# and flushed a block before publishing -- and a peer's open, which takes
# no namespace lock, landing in between was not seen (audit 2026-11-11
# X2). It now asks again before the publish -- and that second ask was
# still one or more device round trips before it, and nothing at all
# preceded a remove-last's publish (audit 2026-11-15 BM N-74). What the
# asks judged is now asked once more inside the publishing swap, and a
# regular file's block is replaced rather than edited in place, so the
# swap is the only publish.
#
#  1. a live peer opens the file while setxattr is past its first check
#     (both the new-block and the in-place path): ETXTBSY, and the
#     attribute is not changed.
#  2. CONTROL: with no peer, the same held setxattr succeeds.
#  3. a live peer opens the file AFTER the second ask, right before the
#     publish (xattr_pre_publish_stall_ms): new block, replace, and
#     removal of the last attribute are each refused, nothing changed.
#
# DISCRIMINATION (2026-11-11, the second check removed): 1 succeeds.
# xattr_swap_unguarded=1 (no ask inside the swap, the block edited in
# place): every case of 3 goes ahead.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/xattr_set_stall_ms ] || { skip "xattr_set_stall_ms is missing"; ct_exit; }
command -v python3 >/dev/null || { skip "no python3"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"
NODE_POKE="$(ct_helper node_poke)"

IMG="$(ct_image 560 xlate)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt xlate)"
ct_mkfs_small "$DEV" -M 4 >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
sx() { python3 -c 'import os, sys; os.setxattr(sys.argv[1], "user.k", sys.argv[2].encode())' "$1" "$2"; }
gx() { python3 -c 'import os, sys; print(os.getxattr(sys.argv[1], "user.k").decode())' "$1" 2>/dev/null || echo none; }

rx() { python3 -c 'import os, sys; os.removexattr(sys.argv[1], "user.k")' "$1"; }

# held <file> <value|-> <peer: 1|0> [stall knob]: setxattr (or, for '-',
# removexattr) held past its first check -- or, with
# xattr_pre_publish_stall_ms, past its second; with peer=1 a live node 1
# opens the file meanwhile. Sets RC.
held() {
    local ino p knob="${4:-xattr_set_stall_ms}"
    ino="$(stat -c %i "$1")"
    ct_param_set "$knob" 1500
    if [ "$2" = - ]; then rx "$1" 2>/dev/null & else sx "$1" "$2" 2>/dev/null & fi
    p=$!
    sleep 0.5
    if [ "$3" = 1 ]; then
        "$NODE_POKE" "$DEV" 1 1 cc "$(date +%s)" >/dev/null # a row nobody has watched: alive
        "$LOCK_POKE" "$DEV" "$ino" --reader 1 >/dev/null
    fi
    RC=0
    wait "$p" || RC=$?
    LEFT="$(cat "/sys/module/cetrafs/parameters/$knob")"
    ct_param_set "$knob" 0
    if [ "$3" = 1 ]; then
        "$LOCK_POKE" "$DEV" "$ino" --unreader 1 >/dev/null
        "$NODE_POKE" "$DEV" 1 0 00 0 >/dev/null
    fi
}

log "2: CONTROL -- no peer"
: >"$MNT/c"
held "$MNT/c" v1 0
[ "$RC" = 0 ] && [ "$(gx "$MNT/c")" = v1 ] && pass "2: the held setxattr succeeded" || fail "2: it failed with no peer ($RC)"

log "1a: a peer opens the file, new-block path"
: >"$MNT/a"
held "$MNT/a" v1 1
[ "$RC" != 0 ] && [ "$(gx "$MNT/a")" = none ] && pass "1a: refused, and no attribute was set" ||
    fail "1a: setxattr went ahead (rc $RC, value $(gx "$MNT/a")) though a peer opened the file under it"

log "1b: a peer opens the file, in-place path"
: >"$MNT/b"
sx "$MNT/b" old
held "$MNT/b" new 1
[ "$RC" != 0 ] && [ "$(gx "$MNT/b")" = old ] && pass "1b: refused, and the attribute is unchanged" ||
    fail "1b: setxattr went ahead (rc $RC, value $(gx "$MNT/b")) though a peer opened the file under it"

# 3: after the second ask. <tag> -> R3 "new=.. replace=.. remove=.." (rc/value)
late() {
    local t="$1"
    : >"$MNT/${t}n"
    held "$MNT/${t}n" v1 1 xattr_pre_publish_stall_ms
    [ "$LEFT" = 0 ] || { fail "setup: the pre-publish stall was not reached ($t new)"; ct_exit; }
    R3="new=$RC/$(gx "$MNT/${t}n")"
    : >"$MNT/${t}r"
    sx "$MNT/${t}r" old
    held "$MNT/${t}r" new 1 xattr_pre_publish_stall_ms
    [ "$LEFT" = 0 ] || { fail "setup: the pre-publish stall was not reached ($t replace)"; ct_exit; }
    R3="$R3 replace=$RC/$(gx "$MNT/${t}r")"
    : >"$MNT/${t}d"
    sx "$MNT/${t}d" old
    held "$MNT/${t}d" - 1 xattr_pre_publish_stall_ms
    [ "$LEFT" = 0 ] || { fail "setup: the pre-publish stall was not reached ($t remove)"; ct_exit; }
    R3="$R3 remove=$RC/$(gx "$MNT/${t}d")"
}
if [ -w /sys/module/cetrafs/parameters/xattr_pre_publish_stall_ms ]; then
    ct_param_set xattr_swap_unguarded 1
    late c
    ct_param_set xattr_swap_unguarded 0
    C3="$R3"
    log "3 control (no ask inside the swap): $C3"
    late f
    log "3: $R3"
    case "$R3" in
    "new=0/"* | *" replace=0/"* | *" remove=0/"*) fail "3: a publish went ahead under a peer's open ($R3)" ;;
    *)
        [ "${R3#*new=*/}" != "$R3" ] && grep -q 'new=[1-9][0-9]*/none replace=[1-9][0-9]*/old remove=[1-9][0-9]*/old' <<<"$R3" &&
            pass "3: refused after the second ask -- new block, replace and remove; nothing changed" ||
            fail "3: $R3"
        ;;
    esac
    grep -q 'new=0/v1 replace=0/new remove=0/none' <<<"$C3" &&
        pass "3 control: without the ask inside the swap all three went ahead under the peer" ||
        fail "3 control: the old order did not let them through ($C3) -- the suite does not reach the window"
else
    skip "xattr_pre_publish_stall_ms is missing: 3 not run"
fi
ct_umount "$MNT"
ct_exit
