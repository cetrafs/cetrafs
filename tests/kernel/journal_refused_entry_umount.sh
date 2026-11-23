#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a journal entry write refused for space does not stop a later unmount
#
# A batch whose entry writes the device refused for space fails its
# boundary with ENOSPC and the mount runs on (A-4); the next boundary
# lands. But the refused buffers kept the buffer layer's write-error flag
# after the refusal had been handed back to the caller, and the next
# write of such a block through the keeping path read that stale flag as
# a new device error: the unmount stopped the mount -- a departure that
# looks like a crash, the next mount watching its own row for minutes
# and replaying the journal. And the close of the refused file had queued
# its lock's release for the heartbeat's retry, which the unmount never
# waited for: it declined a clean departure for that alone. The unmount
# now runs one maintenance pass for queued releases first.
#
# A preallocated file; an fsync whose entry writes are refused
# (journal_entry_nospc), then one that lands; then an unmount:
#   1. the refused fsync failed ENOSPC and the next one landed (setup);
#   2. nothing stopped the mount, through the unmount;
#   3. the remount finds the row left cleanly, and fsck is clean.
#
# DISCRIMINATION, one control per fix:
#   bhs_status_keep_eio=1: the unmount stops the mount on the refused
#   journal block;
#   umount_no_release_pass=1: the unmount says a release is still queued
#   and the remount finds the row not left cleanly.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in journal_entry_nospc bhs_status_keep_eio umount_no_release_pass tree_refusal_stops; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
P=/sys/module/cetrafs/parameters
MNT="$(ct_mnt jreu)"
ct_track mnt "$MNT"
ct_param_set journal_entry_nospc 0
ct_param_set bhs_status_keep_eio 0
ct_param_set umount_no_release_pass 0
ct_param_set tree_refusal_stops 0
ct_param_set scrub 0
ct_param_set auto_defrag 0
get() { grep -o "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2; }

# wsync <file> <from> <to>: write blocks from*4 .. (to-1)*4 and fsync; "0" or the errno name
wsync() { python3 -I - "$@" <<'EOF'
import errno, os, sys
f, a, b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    fd = os.open(f, os.O_RDWR)
    try:
        for i in range(a, b):
            os.pwrite(fd, (b"%08d" % (i * 4)) * 512, i * 4 * 4096)
        os.fsync(fd)
    finally:
        os.close(fd)
    print(0)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
EOF
}

# <tag> <keep_eio 0|1> <no_release_pass 0|1> -> RES
round() {
    local dev mark e a
    dev="$(ct_dev 560 "jreu$1")"
    ct_mkfs "$dev" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    fallocate -l 8M "$MNT/img"
    [ "$(wsync "$MNT/img" 0 16)" = 0 ] || { RES="first=failed"; ct_umount "$MNT"; return; }
    echo "$2" >$P/bhs_status_keep_eio
    echo "$3" >$P/umount_no_release_pass
    mark="$(dmesg_mark)"
    echo 100000 >$P/journal_entry_nospc
    e="$(wsync "$MNT/img" 16 24)"
    echo 0 >$P/journal_entry_nospc
    a="$(wsync "$MNT/img" 24 32)"
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    echo 0 >$P/bhs_status_keep_eio
    echo 0 >$P/umount_no_release_pass
    RES="first=0 refused=$e after=$a stopped=$(dmesg_since "$mark" | grep -c 'STOPPED' || true)"
    RES="$RES queued=$(dmesg_since "$mark" | grep -c 'claim release(s) still queued' || true)"
    mark="$(dmesg_mark)"
    ct_mount "$dev" "$MNT"
    RES="$RES unclean=$(dmesg_since "$mark" | grep -c 'was not left cleanly' || true)"
    ct_umount "$MNT"
    RES="$RES fsck_err=$(ct_fsck "$dev" 2>&1 | grep -cE '^ERR' || true)"
}

round f 0 0
R="$RES"
log "fixed: $R"
round c 1 0
C="$RES"
log "control (flag kept): $C"
round q 0 1
Q="$RES"
log "control (no release pass): $Q"
[ "$(get first "$R")" = 0 ] && [ "$(get refused "$R")" = ENOSPC ] && [ "$(get after "$R")" = 0 ] &&
    [ "$(get refused "$C")" = ENOSPC ] || { fail "setup: the refusal or the landing did not happen: $R / $C"; ct_exit; }
[ "$(get stopped "$R")" = 0 ] && pass "2: nothing stopped the mount, through the unmount" || fail "2: $R"
[ "$(get unclean "$R")" = 0 ] && [ "$(get queued "$R")" = 0 ] && [ "$(get fsck_err "$R")" = 0 ] &&
    pass "3: the remount found the row left cleanly; fsck clean" || fail "3: $R"
[ "$(get stopped "$C")" -ge 1 ] && pass "control: with the stale flag kept, the unmount stopped the mount ($C)" ||
    fail "control: $C -- the stale flag is not what stops it"
[ "$(get stopped "$Q")" = 0 ] && [ "$(get queued "$Q")" -ge 1 ] && [ "$(get unclean "$Q")" = 1 ] &&
    pass "control: with no release pass, a release was still queued and the departure unclean ($Q)" ||
    fail "control: $Q -- no release was queued at the unmount"
ct_exit
