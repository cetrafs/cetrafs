#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a create, mkdir or symlink whose new record is refused for space fails ENOSPC; the mount runs on
#
# Any refused metadata write stopped the mount -- a thin pool full, a
# snapshot's copy-on-write with no space left (audit 2026-11-14 A-4).
# The first write of a just-allocated inode record is one block that
# nothing names yet: refused BEFORE anything landed, the device still
# holds the number's birth claim, so the create fails with ENOSPC and
# frees the number, and the mount runs on.
#
# The record's own write refused (new_record_nospc=1, which aims a
# one-shot BLK_STS_NOSPC at that block in the device-write path):
#   F. create: ENOSPC;  D. mkdir: ENOSPC;  S. symlink: ENOSPC;
#   the mount runs on, the next create works, three refusals counted;
#   after a remount only the names that were reported created exist,
#   and fsck is clean -- no number leaked, none left half-born.
#
# DISCRIMINATION: new_record_refusal_stops=1 with space_wait_stops=1
# (as before -- an overwrite now waits for space): F stops the
# mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in new_record_refusal_stops new_record_nospc; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt rnc)"
ct_track mnt "$MNT"
ct_param_set new_record_refusal_stops 0
ct_param_set space_wait_stops 0
ct_param_set new_record_nospc 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }
# op <kind> <path>: "0" done, the errno name otherwise
op() { python3 -I -c '
import errno, os, sys
k, p = sys.argv[1], sys.argv[2]
try:
    if k == "f": os.close(os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644))
    elif k == "d": os.mkdir(p)
    else: os.symlink("target-text", p)
    print(0)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))' "$1" "$2"; }

# <tag> <stops 0|1> -> RES
round() {
    local img dev mark proc f d s n
    img="$(ct_image 560 "rnc$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    proc="$(ct_procdir "$dev")"
    : >"$MNT/a0"
    n="$(sed -n 's/^record_op_refusals: //p' "$proc/info")"
    echo "$2" >$P/new_record_refusal_stops
    echo "$2" >$P/space_wait_stops # and the overwrite path stops too, as before A-4's wait
    mark="$(dmesg_mark)"
    echo 1 >$P/new_record_nospc
    f="$(op f "$MNT/f1")"
    echo 1 >$P/new_record_nospc
    d="$(op d "$MNT/d1")"
    echo 1 >$P/new_record_nospc
    s="$(op s "$MNT/s1")"
    echo 0 >$P/new_record_nospc
    echo 0 >$P/new_record_refusal_stops
    echo 0 >$P/space_wait_stops
    RES="f=$f d=$d s=$s after=$(op f "$MNT/a1")"
    RES="$RES refusals=$(($(sed -n 's/^record_op_refusals: //p' "$proc/info") - n))"
    RES="$RES stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    if [ "$(get stopped "$RES")" = 0 ]; then
        ct_mount "$dev" "$MNT"
        RES="$RES names=$(ls "$MNT" | tr '\n' ',')"
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
[ "$(get f "$R")" = ENOSPC ] && [ "$(get stopped "$R")" = 0 ] &&
    pass "F: the new file's record refused: the create failed ENOSPC, the mount ran on" || fail "F: $R"
[ "$(get d "$R")" = ENOSPC ] && pass "D: the new directory's record refused: mkdir failed ENOSPC" || fail "D: $R"
[ "$(get s "$R")" = ENOSPC ] && pass "S: the new symlink's record refused: symlink failed ENOSPC" || fail "S: $R"
[ "$(get after "$R")" = 0 ] && [ "$(get refusals "$R")" = 3 ] &&
    pass "the next create worked; three refusals counted" || fail "after: $R"
[ "$(get names "$R")" = "a0,a1," ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "after a remount: only the created names, fsck clean (nothing leaked)" || fail "remount: $R"
[ "$(get stopped "$C")" -ge 1 ] && pass "control: with refusals stopping, the mount stopped ($C)" ||
    fail "control: $C -- the injection does not reach the write"
ct_exit
