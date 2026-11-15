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
# DISCRIMINATION: CETRAFS_TEST_NO_TRANSPORT_HOLD=1 (the hold left out, as
# before): 1, 3 and 6 mount.
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

# stage <disk> iscsi <recovery_tmo> | fc <fast_io_fail_tmo|off> <dev_loss_tmo>
stage() {
    local disk=$1 dir
    rm -rf "$SYS"
    case "$2" in
    iscsi)
        dir="$SYS/devices/platform/host3/session7/target3:0:0/3:0:0:0"
        mkdir -p "$SYS/class/iscsi_session/session7"
        echo "$3" >"$SYS/class/iscsi_session/session7/recovery_tmo"
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
    CETRAFS_TEST_NO_TRANSPORT_HOLD="$off" CETRAFS_SYSFS="$SYS" PATH="$path" "$HELPER" "$DEV" "$MNT" ${3:+-o "$3"} \
        2>"$ERR" || rc=$?
    mountpoint -q "$MNT" && { m=yes; umount "$MNT"; }
    echo "rc=$rc mounted=$m"
}
[ $((30 + 120)) -gt "$LEASE" ] && [ $((30 + 5)) -le "$LEASE" ] && [ $((12 * 5)) -le "$LEASE" ] ||
    { fail "setup: the lease (${LEASE}s) does not separate the cases"; ct_exit; }

stage "$NAME" iscsi 120
R="$(try new)"
[ "$R" = "rc=32 mounted=no" ] && grep -q "recovery_tmo 120s" "$ERR" &&
    pass "1: iSCSI holding 150 s, over the ${LEASE}s lease: refused, and said why" || fail "1: $R: $(cat "$ERR")"
C1="$(try old)"
stage "$NAME" iscsi 5
R="$(try new)"
[ "$R" = "rc=0 mounted=yes" ] && pass "2: iSCSI holding 35 s: mounted" || fail "2: $R: $(cat "$ERR")"
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
ct_exit
