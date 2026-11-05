#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fallocate drops setuid/setgid and moves mtime, as a write does
#
# A hole punch changes a file's contents and a preallocation its layout
# and size; ext4 and XFS treat both as a write -- file_modified(): the
# setuid/setgid bits are dropped for a caller without CAP_FSETID, and
# mtime/ctime move. cetrafs called it nowhere, so a setuid file writable
# by a group kept its bit after a member punched its contents (audit
# 2026-11-05, class 23; a security fault).
#
# Run as an unprivileged user (nobody) on a world-writable root-owned
# 6777 file: a PUNCH and an ALLOCATE must each leave it 0777. Control: a
# plain write(2) by the same user strips it too, so the setup can strip
# at all.
#
# DISCRIMINATION: proven 2026-11-05 with cetrafs_fallocate_modified()
# returning 0 without calling file_modified(): both modes keep 6777.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v setpriv >/dev/null && command -v fallocate >/dev/null || { skip "needs setpriv and fallocate (util-linux)"; ct_exit; }

DEV="$(ct_dev 560 fasuid)"
MNT="$(ct_mnt fasuid)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_param_set auto_defrag 0
chmod 0755 "$MNT"
as_nobody() { setpriv --reuid=65534 --regid=65534 --clear-groups --inh-caps=-all -- "$@"; }

mk() { # <name>: a root-owned, world-writable setuid+setgid file with data
    dd if=/dev/urandom of="$MNT/$1" bs=4096 count=4 conv=fsync status=none
    chmod 6777 "$MNT/$1"
    [ "$(stat -c %a "$MNT/$1")" = 6777 ] || { fail "setup: $1 is $(stat -c %a "$MNT/$1"), not 6777"; ct_exit; }
}

mk ctl
as_nobody dd if=/dev/zero of="$MNT/ctl" bs=4096 count=1 conv=notrunc status=none ||
    { fail "setup: nobody cannot write the file at all"; ct_exit; }
[ "$(stat -c %a "$MNT/ctl")" = 777 ] && pass "control: a write(2) by an unprivileged user strips setuid/setgid" ||
    { fail "setup: even write(2) left $(stat -c %a "$MNT/ctl") -- this setup cannot strip"; ct_exit; }

mk punch
M0="$(stat -c %Y "$MNT/punch")"
sleep 1.1
as_nobody fallocate -p -o 4096 -l 4096 "$MNT/punch" || { fail "setup: the unprivileged punch failed"; ct_exit; }
[ "$(stat -c %a "$MNT/punch")" = 777 ] && pass "a hole punch strips setuid/setgid" ||
    fail "a hole punch by an unprivileged user left mode $(stat -c %a "$MNT/punch")"
[ "$(stat -c %Y "$MNT/punch")" -gt "$M0" ] && pass "and moves mtime" || fail "the punch did not move mtime"

mk alloc
as_nobody fallocate -o 16384 -l 65536 "$MNT/alloc" || { fail "setup: the unprivileged preallocation failed"; ct_exit; }
[ "$(stat -c %s "$MNT/alloc")" = 81920 ] || fail "setup: the preallocation did not extend the file ($(stat -c %s "$MNT/alloc"))"
[ "$(stat -c %a "$MNT/alloc")" = 777 ] && pass "a preallocation strips setuid/setgid" ||
    fail "a preallocation by an unprivileged user left mode $(stat -c %a "$MNT/alloc")"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(stat -c %a "$MNT/punch") $(stat -c %a "$MNT/alloc")" = "777 777" ] &&
    pass "both stripped modes are on the device" ||
    fail "after a remount: punch $(stat -c %a "$MNT/punch"), alloc $(stat -c %a "$MNT/alloc")"
ct_umount "$MNT"
frc=0
fo="$(ct_fsck "$DEV" 2>&1)" || frc=$?
[ "$frc" = 0 ] && pass "fsck clean" || fail "fsck rc=$frc: $(grep '^ERR' <<<"$fo" | head -2)"
ct_exit
