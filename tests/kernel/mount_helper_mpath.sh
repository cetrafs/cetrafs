#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mount.cetrafs refuses a multipath map whose queueing can outlast the lease
#
# A node that loses its paths self-fences when its lease runs out, and its
# peers then take its Zone Groups over. Writes it had already submitted
# are not recalled: dm-multipath queueing them while no path is up hands
# them to the array when the paths come back -- over blocks a peer now
# owns. Nothing checked the queueing policy (audit 2026-11-14 A-6). The
# mount helper now does: queue_if_no_path with no bound, or a
# no_path_retry x polling_interval longer than the lease, is refused
# unless -o x-cetrafs.mpath-queue-ok says the cluster fences in hardware.
#
# dmsetup and multipathd are stand-ins on PATH (a loop device posing as a
# multipath map): the real ones on a test box serve the box's own LUNs
# and are not to be touched. The lease is the module's stale window less
# one heartbeat.
#   1. no queueing (features 0): mounts;
#   2. queueing bounded under the lease: mounts;
#   3. queueing with no bound (no_path_retry queue): refused, exit 32, not mounted;
#   4. queueing bounded OVER the lease: refused;
#   5. queueing, and no multipathd to say what bounds it: refused;
#   6. 3 with -o x-cetrafs.mpath-queue-ok: mounts, with a warning;
#   7. not a multipath map: mounts;
#   8. queueing, and multipathd reporting no_path_retry "-" (not set): refused.
#
# DISCRIMINATION: without the helper (mount -i, the kernel alone) 3 mounts.
# A helper taking "-" as "fails at once": 8 mounts.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
HELPER="$ROOT/userspace/mount.cetrafs"
[ -x "$HELPER" ] || { fail "setup: $HELPER is missing"; ct_exit; }
DEV="$(ct_dev 560 mhm)"
MNT="$(ct_mnt mhm)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
FAKE="$(ct_tmp mhm-bin)"
rm -f "$FAKE"; mkdir -p "$FAKE"
cat >"$FAKE/dmsetup" <<'EOF'
#!/bin/sh
case "$1" in
info) [ -n "${FAKE_NOT_DM:-}" ] && exit 1; echo "mpath-cetratest|cetratest" ;;
table) echo "0 1146880 multipath $FAKE_FEATURES 0 1 1 round-robin 0 1 1 7:0 1" ;;
*) exit 1 ;;
esac
EOF
cat >"$FAKE/multipathd" <<'EOF'
#!/bin/sh
[ -n "${FAKE_NO_MPD:-}" ] && exit 1
case "$*" in
"show maps raw format"*) echo "cetratest|$FAKE_Q" ;;
"show config") printf '\tpolling_interval 5\n' ;;
esac
EOF
chmod +x "$FAKE/dmsetup" "$FAKE/multipathd"
LEASE=$(($(cat /sys/module/cetrafs/parameters/stale_secs) - $(cat /sys/module/cetrafs/parameters/hb_interval_secs)))
SHORT=1                     # 5 s
LONG=$((LEASE / 5 + 2))     # past the lease

# try <features> <no_path_retry> [mount options] -> "rc=<n> mounted=<yes|no>"; stderr kept in $ERR
ERR="$(ct_tmp mhm-err)"
try() {
    local rc=0 m=no
    FAKE_FEATURES="$1" FAKE_Q="$2" PATH="$FAKE:$PATH" "$HELPER" "$DEV" "$MNT" ${3:+-o "$3"} 2>"$ERR" || rc=$?
    mountpoint -q "$MNT" && { m=yes; umount "$MNT"; }
    echo "rc=$rc mounted=$m"
}

R="$(try "0" "off")"
[ "$R" = "rc=0 mounted=yes" ] && pass "1: no queueing: mounted" || fail "1: no queueing: $R: $(cat "$ERR")"
R="$(try "1 queue_if_no_path" "$SHORT chk")"
[ "$R" = "rc=0 mounted=yes" ] && pass "2: queueing for $((SHORT * 5))s, under the ${LEASE}s lease: mounted" ||
    fail "2: bounded queueing under the lease: $R: $(cat "$ERR")"
R="$(try "1 queue_if_no_path" "on")"
[ "$R" = "rc=32 mounted=no" ] && grep -q "with no limit" "$ERR" && pass "3: unbounded queueing: refused, and said why" ||
    fail "3: unbounded queueing: $R: $(cat "$ERR")"
R="$(try "1 queue_if_no_path" "$LONG chk")"
[ "$R" = "rc=32 mounted=no" ] && grep -q "longer than this node's lease" "$ERR" &&
    pass "4: queueing for $((LONG * 5))s, past the ${LEASE}s lease: refused" || fail "4: queueing past the lease: $R: $(cat "$ERR")"
R="$(FAKE_NO_MPD=1 try "1 queue_if_no_path" "$SHORT chk")"
[ "$R" = "rc=32 mounted=no" ] && pass "5: queueing with no multipathd to bound it: refused" || fail "5: $R: $(cat "$ERR")"
R="$(try "1 queue_if_no_path" "on" "x-cetrafs.mpath-queue-ok")"
[ "$R" = "rc=0 mounted=yes" ] && grep -q "mounting anyway" "$ERR" && pass "6: the override mounts it, with a warning" ||
    fail "6: the override: $R: $(cat "$ERR")"
R="$(FAKE_NOT_DM=1 try "1 queue_if_no_path" "on")"
[ "$R" = "rc=0 mounted=yes" ] && pass "7: not a multipath map: mounted" || fail "7: $R: $(cat "$ERR")"
R="$(try "1 queue_if_no_path" "-")"
[ "$R" = "rc=32 mounted=no" ] && grep -q "with no limit" "$ERR" && pass "8: queueing with no_path_retry not set: refused" ||
    fail "8: no_path_retry '-': $R: $(cat "$ERR")"

rc=0
mount -i -t cetrafs "$DEV" "$MNT" 2>/dev/null || rc=$?
mountpoint -q "$MNT" && { umount "$MNT"; pass "control: the kernel alone mounts what 3 refused -- the check is the helper's"; } ||
    fail "control: the kernel alone did not mount ($rc)"
ct_exit
