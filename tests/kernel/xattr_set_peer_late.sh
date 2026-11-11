#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a setxattr asks "is a peer using this file?" again right before it publishes, not only at its start
#
# setxattr refuses (ETXTBSY) when a live peer has the file locked or
# open: rewriting its metadata under a peer that has it open breaks the
# one-writer rule. It asked once, at the start, then allocated, wrote
# and flushed a block before publishing -- and a peer's open, which takes
# no namespace lock, landing in between was not seen (audit 2026-11-11
# X2). It now asks again immediately before each publish.
#
#  1. a live peer opens the file while setxattr is past its first check
#     (both the new-block and the in-place path): ETXTBSY, and the
#     attribute is not changed.
#  2. CONTROL: with no peer, the same held setxattr succeeds.
#
# DISCRIMINATION (2026-11-11, the second check removed): 1 succeeds.
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

# held <file> <value> <peer: 1|0>: setxattr held past its first check;
# with peer=1 a live node 1 opens the file meanwhile. Sets RC.
held() {
    local ino p
    ino="$(stat -c %i "$1")"
    ct_param_set xattr_set_stall_ms 1500
    sx "$1" "$2" 2>/dev/null &
    p=$!
    sleep 0.5
    if [ "$3" = 1 ]; then
        "$NODE_POKE" "$DEV" 1 1 cc "$(date +%s)" >/dev/null # a row nobody has watched: alive
        "$LOCK_POKE" "$DEV" "$ino" --reader 1 >/dev/null
    fi
    RC=0
    wait "$p" || RC=$?
    ct_param_set xattr_set_stall_ms 0
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
ct_umount "$MNT"
ct_exit
