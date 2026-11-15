#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mount.cetrafs counts how long a path's transport holds a write, single path or multipath
#
# A node that loses its paths self-fences when its lease runs out, and a
# write it had already submitted is not recalled. The helper refused a
# multipath map that queues past the lease, but a path holds a write
# before any queueing: the SCSI command timeout, plus an iSCSI session's
# recovery_tmo (replacement_timeout, 120 s by default -- the stale window
# itself) or an FC port's fast_io_fail_tmo, dev_loss_tmo when that is
# off. A single-path session was not checked at all, and a map's bound
# left the hold out (audit 2026-11-15 B-20).
#
# The transport is a fabricated sysfs tree (CETRAFS_SYSFS), a loop device
# posing as its disk; dmsetup/multipathd are stand-ins for the map case.
#   1. iSCSI, 30 + 120 s, over the lease: refused, exit 32, says why;
#   2. iSCSI, 30 + 5 s: mounts;
#   3. FC, fast_io_fail off, dev_loss 600 s: refused;
#   4. FC, fast_io_fail 5 s: mounts;
#   5. 1 with -o x-cetrafs.queue-ok: mounts, with a warning;
#   6. a multipath map queueing 12 x 5 s over an iSCSI path holding 150 s:
#      refused (60 s alone is under the lease).
#
#   7. iSCSI recovery_tmo -1 (an infinite hold): refused;
#   8. a disk whose command timeout cannot be read: refused;
#   9. a device-mapper node that is not a multipath map (LVM, crypt, a
#      kpartx partition) over a path holding 160 s: refused, through its
#      slaves;
#  10. the packaged copy (TEST_HOOKS=0) ignores CETRAFS_SYSFS: the staged
#      refusing tree of 1 does not reach it (audit 2026-11-15 F-23);
#  11. iSCSI noticing the loss by NOP-out after 30 + 30 s, then 30 s of
#      recovery: refused (B-20: detection was not counted);
#  12. iSCSI whose NOP-out timers cannot be read: refused.
# Every iSCSI stage but 11 and 12 has NOP-out at 5 + 5 s.
#
# DISCRIMINATION: CETRAFS_TEST_NO_TRANSPORT_HOLD=1 (the hold left out, as
# before): 1, 3 and 6 mount. CETRAFS_TEST_TIMER_FAILS_OPEN=1 (an unknown
# timer read as 0): 7 and 8 mount. CETRAFS_TEST_NO_STACK=1: 9 mounts.
# CETRAFS_TEST_NO_DETECT=1 (detection left out): 11 and 12 mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
HELPER="$ROOT/userspace/mount.cetrafs"
DEV="$(ct_dev 560 mhth)"
NAME="$(basename "$(readlink -f "$DEV")")"
MNT="$(ct_mnt mhth)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
LEASE=$(($(cat /sys/module/cetrafs/parameters/stale_secs) - $(cat /sys/module/cetrafs/parameters/hb_interval_secs)))
SYS="$(ct_tmp mhth-sys)"

# stage <disk> iscsi <recovery_tmo> [<noop interval> <noop timeout>|none]
#     | fc <fast_io_fail_tmo|off> <dev_loss_tmo>
stage() {
    local disk=$1 dir
    rm -rf "$SYS"
    case "$2" in
    iscsi)
        dir="$SYS/devices/platform/host3/session7/target3:0:0/3:0:0:0"
        mkdir -p "$SYS/class/iscsi_session/session7"
        echo "$3" >"$SYS/class/iscsi_session/session7/recovery_tmo"
        if [ "${4:-}" != none ]; then
            mkdir -p "$SYS/class/iscsi_connection/connection7:0"
            echo "${4:-5}" >"$SYS/class/iscsi_connection/connection7:0/recv_tmo"
            echo "${5:-5}" >"$SYS/class/iscsi_connection/connection7:0/ping_tmo"
        fi
        ;;
    fc)
        dir="$SYS/devices/pci0000:00/host4/rport-4:0-2/target4:0:0/4:0:0:0"
        mkdir -p "$SYS/class/fc_remote_ports/rport-4:0-2"
        echo "$3" >"$SYS/class/fc_remote_ports/rport-4:0-2/fast_io_fail_tmo"
        echo "$4" >"$SYS/class/fc_remote_ports/rport-4:0-2/dev_loss_tmo"
        ;;
    esac
    mkdir -p "$dir" "$SYS/block/$disk"
    echo 30 >"$dir/timeout"
    ln -s "$dir" "$SYS/block/$disk/device"
    mkdir -p "$SYS/dev/block"
    ln -s "$SYS/block/$disk" "$SYS/dev/block/7:0"
}

FAKE="$(ct_tmp mhth-bin)"
rm -rf "$FAKE"; mkdir -p "$FAKE"
cat >"$FAKE/dmsetup" <<'EOS'
#!/bin/sh
case "$1" in
info) echo "mpath-cetratest|cetratest" ;;
table) echo "0 1146880 multipath 1 queue_if_no_path 0 1 1 round-robin 0 1 1 7:0 1" ;;
*) exit 1 ;;
esac
EOS
cat >"$FAKE/multipathd" <<'EOS'
#!/bin/sh
case "$*" in
"show maps raw format"*) echo "cetratest|12 chk" ;;
"show config") printf '\tpolling_interval 5\n' ;;
esac
EOS
chmod +x "$FAKE/dmsetup" "$FAKE/multipathd"

ERR="$(ct_tmp mhth-err)"
# try <new|old> [mpath] [options] -> "rc=<n> mounted=<yes|no>"
try() {
    local rc=0 m=no off="" path=$PATH
    [ "$1" = old ] && off=1
    [ "${2:-}" = mpath ] && path="$FAKE:$PATH"
    CETRAFS_TEST_NO_TRANSPORT_HOLD="$off" CETRAFS_SYSFS="$SYS" PATH="$path" CETRAFS_TEST_TIMER_FAILS_OPEN="${OPEN:-}" \
        CETRAFS_TEST_NO_STACK="${NOSTACK:-}" CETRAFS_TEST_NO_DETECT="${NODETECT:-}" "${H:-$HELPER}" "$DEV" "$MNT" ${3:+-o "$3"} 2>"$ERR" || rc=$?
    mountpoint -q "$MNT" && { m=yes; umount "$MNT"; }
    echo "rc=$rc mounted=$m"
}
[ $((30 + 120)) -gt "$LEASE" ] && [ $((30 + 10 + 5)) -lt "$LEASE" ] && [ $((12 * 5)) -le "$LEASE" ] &&
    [ $((30 + 60 + 30)) -ge "$LEASE" ] && [ $((30 + 30)) -lt "$LEASE" ] ||
    { fail "setup: the lease (${LEASE}s) does not separate the cases"; ct_exit; }

stage "$NAME" iscsi 120
R="$(try new)"
[ "$R" = "rc=32 mounted=no" ] && grep -q "recovery_tmo 120s" "$ERR" &&
    pass "1: iSCSI holding 150 s, over the ${LEASE}s lease: refused, and said why" || fail "1: $R: $(cat "$ERR")"
C1="$(try old)"
stage "$NAME" iscsi 5
R="$(try new)"
[ "$R" = "rc=0 mounted=yes" ] && pass "2: iSCSI holding 45 s (NOP-out 5 + 5 s): mounted" || fail "2: $R: $(cat "$ERR")"
stage "$NAME" fc off 600
R="$(try new)"
[ "$R" = "rc=32 mounted=no" ] && grep -q "dev_loss_tmo 600s" "$ERR" &&
    pass "3: FC with fast_io_fail off and dev_loss 600 s: refused" || fail "3: $R: $(cat "$ERR")"
C3="$(try old)"
stage "$NAME" fc 5 600
R="$(try new)"
[ "$R" = "rc=0 mounted=yes" ] && pass "4: FC failing I/O fast after 5 s: mounted" || fail "4: $R: $(cat "$ERR")"
stage "$NAME" iscsi 120
R="$(try new "" x-cetrafs.queue-ok)"
[ "$R" = "rc=0 mounted=yes" ] && grep -q "mounting anyway" "$ERR" &&
    pass "5: with x-cetrafs.queue-ok: mounted, with a warning" || fail "5: $R: $(cat "$ERR")"
stage sdz iscsi 120
R="$(try new mpath)"
[ "$R" = "rc=32 mounted=no" ] && grep -q "for a path to fail them" "$ERR" &&
    pass "6: a map queueing 60 s behind a path holding 150 s: refused" || fail "6: $R: $(cat "$ERR")"
C6="$(try old mpath)"
[ "$C1" = "rc=0 mounted=yes" ] && [ "$C3" = "rc=0 mounted=yes" ] && [ "$C6" = "rc=0 mounted=yes" ] &&
    pass "control: with the hold left out, 1, 3 and 6 mounted" || fail "control: 1 $C1, 3 $C3, 6 $C6"

stage "$NAME" iscsi -1
R="$(try new)"
[ "$R" = "rc=32 mounted=no" ] && grep -q "cannot tell" "$ERR" &&
    pass "7: recovery_tmo -1 (an infinite hold): refused" || fail "7: $R: $(cat "$ERR")"
C7="$(OPEN=1 try new)"
stage "$NAME" iscsi 5
rm -f "$(readlink -f "$SYS/block/$NAME/device")/timeout"
R="$(try new)"
[ "$R" = "rc=32 mounted=no" ] && grep -q "cannot tell" "$ERR" &&
    pass "8: a command timeout that cannot be read: refused" || fail "8: $R: $(cat "$ERR")"
C8="$(OPEN=1 try new)"
# 9: the device is a dm node (not a map) over sdz, which holds 160 s
stage sdz iscsi 120
mkdir -p "$SYS/block/$NAME/dm" "$SYS/block/$NAME/slaves"
echo "LVM-cetratest" >"$SYS/block/$NAME/dm/uuid"
ln -s "$SYS/block/sdz" "$SYS/block/$NAME/slaves/sdz"
R="$(try new)"
[ "$R" = "rc=32 mounted=no" ] && grep -q "sdz holds a write for up to 160s" "$ERR" &&
    pass "9: a stacked dm node over a path holding 160 s: refused through its slaves" || fail "9: $R: $(cat "$ERR")"
C9="$(NOSTACK=1 try new)"
[ "$C7" = "rc=0 mounted=yes" ] && [ "$C8" = "rc=0 mounted=yes" ] && [ "$C9" = "rc=0 mounted=yes" ] &&
    pass "control: an unknown timer read as 0 mounted 7 and 8; unchecked stacking mounted 9" ||
    fail "control: 7 $C7, 8 $C8, 9 $C9"
# 11: NOP-out 30 + 30 s ahead of a 30 s recovery_tmo: 120 s, over the lease
stage "$NAME" iscsi 30 30 30
R="$(try new)"
[ "$R" = "rc=32 mounted=no" ] && grep -q "NOP-out interval 30s + timeout 30s" "$ERR" &&
    pass "11: a session that takes 60 s to notice the loss, then 30 s to fail: refused" || fail "11: $R: $(cat "$ERR")"
C11="$(NODETECT=1 try new)"
# 12: the session's connection timers cannot be read
stage "$NAME" iscsi 5 none
R="$(try new)"
[ "$R" = "rc=32 mounted=no" ] && grep -q "cannot be read" "$ERR" &&
    pass "12: NOP-out timers that cannot be read: refused" || fail "12: $R: $(cat "$ERR")"
C12="$(NODETECT=1 try new)"
[ "$C11" = "rc=0 mounted=yes" ] && [ "$C12" = "rc=0 mounted=yes" ] &&
    pass "control: with detection left out, 11 and 12 mounted" || fail "control: 11 $C11, 12 $C12"
PKG="$(ct_tmp mhth-pkg)"
sed 's/^TEST_HOOKS=1$/TEST_HOOKS=0/' "$HELPER" >"$PKG"
chmod +x "$PKG"
grep -q '^TEST_HOOKS=0$' "$PKG" || { fail "setup: the packaged copy was not made"; ct_exit; }
stage "$NAME" iscsi 120
R="$(H="$PKG" try new)"
[ "$R" = "rc=0 mounted=yes" ] && [ "$(try new)" = "rc=32 mounted=no" ] &&
    pass "10: the packaged copy ignored CETRAFS_SYSFS (the staged refusal reached only the test copy)" ||
    fail "10: packaged $R: $(cat "$ERR")"
ct_exit
