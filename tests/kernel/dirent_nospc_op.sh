#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a directory or xattr write refused for space fails that operation with ENOSPC; the mount runs on
#
# Any refused metadata write stopped the mount -- a thin pool full, a
# snapshot's copy-on-write with no space left -- so every VM on the node
# went to EIO and freeing space on the array brought nothing back (audit
# 2026-11-14 A-4). A directory-entry or xattr block refused BEFORE
# anything was written now fails just its operation with ENOSPC: the
# journal entry is retired, the cached image forgotten, the operation's
# own undo runs. Records, tree blocks and bitmaps still stop.
#
# On a directory `d`, its entry block found from the journal's log:
#   T. the block itself refused (meta_write_nospc_block): the create
#      fails ENOSPC, the mount runs on, and the next create works;
#   P. the journal entry's payload refused, its header landed
#      (journal_entry_nospc=1): the same, the header retired;
#   H. payload and header both refused (journal_entry_nospc=2): the same;
#   X. setxattr on a directory (edited in place) whose xattr block is
#      refused: ENOSPC;
#   after a remount only the names that were reported created exist,
#   the attribute is as it was, and fsck is clean.
#
# DISCRIMINATION: journal_nospc_stops=1 (as before): T stops the mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in journal_nospc_stops journal_entry_nospc meta_write_nospc_block; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt dno)"
ct_track mnt "$MNT"
ct_param_set journal_nospc_stops 0
ct_param_set journal_entry_nospc 0
ct_param_set meta_write_nospc_block 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
# The journal's debug line has no newline, so the log holds it open for
# a continuation until the next message: write one before reading.
first_target() {
    dmesg_mark >/dev/null
    dmesg_since "$1" | grep -oP 'journal: txn [0-9]+ slot [0-9]+ target_lba=\K[0-9]+' | head -1 || true
}
# mk <path>: "0" created, "ENOSPC"/"EIO"/... otherwise
mk() { python3 -I -c '
import errno, os, sys
try:
    os.close(os.open(sys.argv[1], os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)); print(0)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$1"; }
sx() { python3 -I -c '
import errno, os, sys
try:
    os.setxattr(sys.argv[1], "user.k", sys.argv[2].encode()); print(0)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$1" "$2"; }

# <tag> <stops 0|1> -> RES
round() {
    local img dev mark lba xlba proc t p h x n
    img="$(ct_image 560 "dno$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    mkdir "$MNT/d"
    mkdir "$MNT/xd" # a directory's xattr block is edited in place, journaled
    python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], "user.k", b"old")' "$MNT/xd"
    mark="$(dmesg_mark)"
    : >"$MNT/d/a0"
    lba="$(first_target "$mark")"
    mark="$(dmesg_mark)"
    python3 -I -c 'import os,sys; os.setxattr(sys.argv[1], "user.k", b"old2")' "$MNT/xd"
    xlba="$(first_target "$mark")"
    [ -n "$lba" ] && [ -n "$xlba" ] || { fail "setup: no journal target logged (dir=$lba xattr=$xlba)"; ct_exit; }
    n="$(sed -n 's/^journal_op_refusals: //p' "$proc/info")"
    echo "$2" >$P/journal_nospc_stops
    mark="$(dmesg_mark)"
    echo "$lba" >$P/meta_write_nospc_block
    t="$(mk "$MNT/d/t1")"
    echo 0 >$P/meta_write_nospc_block
    echo 1 >$P/journal_entry_nospc
    p="$(mk "$MNT/d/p1")"
    echo 2 >$P/journal_entry_nospc
    h="$(mk "$MNT/d/h1")"
    echo 0 >$P/journal_entry_nospc
    echo "$xlba" >$P/meta_write_nospc_block
    x="$(sx "$MNT/xd" new)"
    echo 0 >$P/meta_write_nospc_block
    echo 0 >$P/journal_nospc_stops
    RES="t=$t p=$p h=$h x=$x after=$(mk "$MNT/d/a1")"
    RES="$RES refusals=$(($(sed -n 's/^journal_op_refusals: //p' "$proc/info") - n))"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    if [ "$(get stopped "$RES")" = 0 ]; then
        ct_mount "$dev" "$MNT"
        RES="$RES names=$(ls "$MNT/d" | tr '\n' ',') xattr=$(python3 -I -c 'import os,sys; print(os.getxattr(sys.argv[1], "user.k").decode())' "$MNT/xd")"
        ct_umount "$MNT"
        RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
    fi
}

round c 1
C="$RES"
log "control (a refusal stops): $C"
round f 0
R="$RES"
log "fixed: $R"
[ "$(get t "$R")" = ENOSPC ] && [ "$(get stopped "$R")" = 0 ] &&
    pass "T: the directory block refused: the create failed ENOSPC, the mount ran on" || fail "T: $R"
[ "$(get p "$R")" = ENOSPC ] && pass "P: the entry's payload refused: ENOSPC" || fail "P: $R"
[ "$(get h "$R")" = ENOSPC ] && pass "H: payload and header refused: ENOSPC" || fail "H: $R"
[ "$(get x "$R")" = ENOSPC ] && pass "X: the xattr block refused: setxattr failed ENOSPC" || fail "X: $R"
[ "$(get after "$R")" = 0 ] && [ "$(get refusals "$R")" = 4 ] &&
    pass "the next create worked; four refusals counted" || fail "after: $R"
[ "$(get names "$R")" = "a0,a1," ] && [ "$(get xattr "$R")" = old2 ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "after a remount: only the created names, the attribute unchanged, fsck clean" || fail "remount: $R"
[ "$(get stopped "$C")" -ge 1 ] && pass "control: with refusals stopping, the mount stopped ($C)" ||
    fail "control: $C -- the injection does not reach the write"
ct_exit
