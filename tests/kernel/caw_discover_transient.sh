#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# CAW discovery refuses a mount it cannot decide, instead of reading "could not ask" as "no atomic CAW"
#
# Whether a volume has atomic COMPARE AND WRITE decides its whole safety
# model: without it, this node takes the node-local fallback and the
# mount gate allows one mounter. Discovery read two "could not ask"
# cases as "has none" (audit 2026-11-11 C1):
#   - the Block Limits VPD page failing to come back -- scsi_get_vpd_page()
#     says -EINVAL for every failure, a transient one included;
#   - a multipath LUN whose SCSI path could not be read at mount
#     (mid-failover): no path resolved looked exactly like "not SCSI".
# Either put a CAW-capable shared LUN on the fallback beside peers using
# real COMPARE AND WRITE. Now both refuse the mount; a device that truly
# lacks the page, and a dm map whose path is provably another device,
# still mount as before.
#
# Needs scsi_debug (a SCSI disk for the module to probe); skipped
# without it. multipathd with find_multipaths "strict" does not map it.
#
#  1. plain SCSI, the VPD page failing: refused, and says why.
#  2. CONTROL: the same disk, healthy: mounts, CAW class scsi.
#  3. a 1:1 dm map, its path failing its READ: refused.
#  4. CONTROL: the same map, healthy: mounts (CAW through the path).
#  5. CONTROL: a dm map that is NOT 1:1: mounts, no CAW -- a different
#     device is an answer, not a failure.
#
# DISCRIMINATION (2026-11-11, discovery as before): 1 and 3 mount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in caw_vpd_fail dmpath_read_fail; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
modinfo scsi_debug >/dev/null 2>&1 || { skip "no scsi_debug module"; ct_exit; }
lsmod | grep -q '^scsi_debug ' && { skip "scsi_debug is already loaded (someone else's)"; ct_exit; }
command -v dmsetup >/dev/null || { skip "no dmsetup"; ct_exit; }

modprobe scsi_debug dev_size_mb=600 sector_size=512 num_tgts=1 max_luns=1 || { skip "scsi_debug would not load"; ct_exit; }
unload_sdebug() { dmsetup remove ctcawd1 2>/dev/null || true; dmsetup remove ctcawd2 2>/dev/null || true; udevadm settle 2>/dev/null || true; modprobe -r scsi_debug 2>/dev/null || true; }
trap 'unload_sdebug' EXIT
udevadm settle 2>/dev/null || true
SD=""
for d in /sys/block/sd*; do
    grep -q scsi_debug "$d/device/model" 2>/dev/null && SD="/dev/$(basename "$d")"
done
[ -n "$SD" ] && [ -b "$SD" ] || { fail "setup: no scsi_debug disk appeared"; ct_exit; }
MNT="$(ct_mnt cawd)"
"$ROOT/userspace/mkfs.cetra" "$SD" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>&1 || { fail "setup: mkfs on $SD"; ct_exit; }

# try <dev>: mount and unmount. Sets OK (1 mounted) and LOG.
try() {
    local mark
    mark="$(dmesg_mark)"
    if mount -t cetrafs "$1" "$MNT" 2>/dev/null; then OK=1; umount "$MNT"; else OK=0; fi
    LOG="$(dmesg_since "$mark")"
}

# ------------------------------------------------------------------- 2
log "2: CONTROL -- the plain SCSI disk, healthy"
try "$SD"
[ "$OK" = 1 ] && grep -q "CAW: class=scsi" <<<"$LOG" && pass "2: mounts, probed as SCSI ($(grep -o 'max_caw_blocks=[0-9]*' <<<"$LOG"))" ||
    { fail "2 setup: the healthy disk did not mount as SCSI: $(grep CAW <<<"$LOG" | tail -2)"; ct_exit; }

# ------------------------------------------------------------------- 1
log "1: plain SCSI, the Block Limits page failing"
ct_param_set caw_vpd_fail 10
try "$SD"
ct_param_set caw_vpd_fail 0
[ "$OK" = 0 ] && pass "1: the mount was refused" || fail "1: mounted on a guess that the device has no atomic CAW"
grep -q "did not answer for its Block Limits VPD page" <<<"$LOG" && pass "1: and said why" ||
    fail "1: no reason given: $(grep CAW <<<"$LOG" | tail -2)"

# ------------------------------------------------------------------- 4
SECTORS="$(blockdev --getsz "$SD")"
dmsetup create ctcawd1 --table "0 $SECTORS linear $SD 0"
DM1=/dev/mapper/ctcawd1
log "4: CONTROL -- a 1:1 dm map over it, healthy"
try "$DM1"
[ "$OK" = 1 ] && grep -q "sending COMPARE AND WRITE via" <<<"$LOG" && pass "4: mounts, CAW through the path" ||
    { fail "4 setup: the 1:1 map did not resolve its path: $(grep -E 'CAW|dm path' <<<"$LOG" | tail -3)"; ct_exit; }

# ------------------------------------------------------------------- 3
log "3: the 1:1 map, its path failing its READ"
ct_param_set dmpath_read_fail 10
try "$DM1"
ct_param_set dmpath_read_fail 0
[ "$OK" = 0 ] && pass "3: the mount was refused" || fail "3: mounted as a volume with no atomic CAW while its path was down"
grep -q "could not be probed just now" <<<"$LOG" && pass "3: and said why" ||
    fail "3: no reason given: $(grep -E 'CAW|dm path' <<<"$LOG" | tail -3)"
dmsetup remove ctcawd1

# ------------------------------------------------------------------- 5
log "5: CONTROL -- a dm map that is not 1:1"
dmsetup create ctcawd2 --table "0 $((SECTORS - 2048)) linear $SD 2048"
DM2=/dev/mapper/ctcawd2
"$ROOT/userspace/mkfs.cetra" "$DM2" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>&1 || { fail "setup: mkfs on $DM2"; ct_exit; }
try "$DM2"
[ "$OK" = 1 ] && grep -q "atomic CAS unavailable" <<<"$LOG" && pass "5: mounts as a single-mounter volume, as before" ||
    fail "5: a map onto a different device was refused or given CAW: $(grep -E 'CAW|dm path' <<<"$LOG" | tail -3)"
dmsetup remove ctcawd2
ct_exit
