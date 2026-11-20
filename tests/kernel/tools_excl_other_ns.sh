#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs, growfs and fsck -r refuse a device mounted in ANOTHER mount namespace
#
# cetrafs_device_mounted() reads this namespace's /proc/self/mounts and
# matches by st_rdev. A volume mounted in a private mount namespace (a
# container, a sandbox, a mount another tool made there) is invisible to
# it, and the destructive tools went ahead. The kernel holds a mounted
# block device for its filesystem, so an exclusive open (O_EXCL) of the
# device is refused with EBUSY whichever namespace the mount lives in.
# The destructive opens now carry O_EXCL; a read-only fsck keeps its
# plain open, and a live growfs (the device mounted HERE) does too.
#
# Staged: a cetrafs mount made inside `unshare -m` that stays up for the
# whole suite, and whose mount table this namespace cannot see.
#
# DISCRIMINATION: the setup requires the mount to be absent from this
# namespace's table and an exclusive open of the device to be refused
# EBUSY -- so the refusal below is the kernel's, not the /proc check's.
# The control CETRAFS_TEST_TOOLS_NO_EXCL=1 skips the exclusive open
# (honoured on a loop device only): mkfs must then get past its open and
# stop at its Node Registry check, which shows the EBUSY refusal came from
# the open and nothing else. The test device is a scratch loop image.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v unshare >/dev/null 2>&1 || { skip "unshare not available"; ct_exit; }
command -v python3 >/dev/null 2>&1 || { skip "python3 not available"; ct_exit; }

MKFS="$ROOT/userspace/mkfs.cetra"
GROWFS="$ROOT/userspace/growfs.cetra"
FSCK="$ROOT/userspace/fsck.cetra"
EXCL_MSG="the exclusive open was refused (EBUSY)"

DEV="$(ct_dev 560 excl)"
ct_mkfs_small "$DEV" >/dev/null
MNT="$(ct_mnt excl)"
SCR="$(ct_mnt excl-scr)" # tracked directory for the holder's handshake files
READY="$SCR/ready"
STOP="$SCR/stop"
DONE="$SCR/done"

# Stops the holder and waits for its umount. Registered before the holder
# starts, so an aborting suite still lets go of the device.
ct_track cmd "touch '$STOP'; i=0; while [ ! -e '$DONE' ] && [ \$i -lt 50 ]; do sleep 0.2; i=\$((i+1)); done; true"

# The holder: a cetrafs mount in a private mount namespace, held until STOP.
unshare -m --propagation private sh -c "
    mount -t cetrafs '$DEV' '$MNT' || exit 3
    grep -qF ' $MNT cetrafs ' /proc/self/mounts || exit 4
    : > '$READY'
    while [ ! -e '$STOP' ]; do sleep 0.2; done
    umount '$MNT'
    : > '$DONE'
" &
HOLDER=$!

i=0
while [ ! -e "$READY" ] && kill -0 "$HOLDER" 2>/dev/null && [ "$i" -lt 150 ]; do
    sleep 0.2
    i=$((i + 1))
done
if [ ! -e "$READY" ]; then
    HRC=0
    wait "$HOLDER" 2>/dev/null || HRC=$?
    fail "setup: the holder did not mount the device in its namespace (rc $HRC)"
    ct_exit
fi

# Setup: the mount is NOT in this namespace's table. Otherwise the /proc
# check would refuse first and nothing below would test the open.
if grep -qF " $MNT " /proc/self/mounts; then
    fail "setup: the mount is visible in this namespace -- the test would only exercise /proc"
    ct_exit
fi

# Setup: the kernel refuses an exclusive open of the device. This is the
# whole mechanism; if it does not refuse, the assertions below prove nothing.
PROBE="$(python3 -I -c '
import os, sys
try:
    os.close(os.open(sys.argv[1], os.O_RDWR | os.O_EXCL))
    print("open-ok")
except OSError as e:
    print("errno=%d" % e.errno)
sys.stdout.flush()
' "$DEV" 2>&1 || true)"
if [ "$PROBE" != "errno=16" ]; then
    fail "setup: an exclusive open of the device while another namespace mounts it gave '$PROBE', not EBUSY"
    ct_exit
fi
log "setup: mounted in a private namespace, invisible here; exclusive open -> EBUSY"

# 1: mkfs -f refuses, names the device and the reason, and does not format.
OUT="$("$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f 2>&1)" && RC=0 || RC=$?
if [ "$RC" != 0 ] && grep -qF "$EXCL_MSG" <<<"$OUT" && grep -qF "$DEV" <<<"$OUT"; then
    pass "1: mkfs -f refuses a device mounted in another namespace, naming it and the reason"
else
    fail "1: mkfs -f rc=$RC: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
fi

# 2: fsck -r refuses the same way (exit 3: could not examine the device).
OUT="$("$FSCK" -r "$DEV" 2>&1)" && RC=0 || RC=$?
if [ "$RC" = 3 ] && grep -qF "$EXCL_MSG" <<<"$OUT"; then
    pass "2: fsck -r refuses a device mounted in another namespace (exit 3)"
else
    fail "2: fsck -r rc=$RC: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
fi

# 3: growfs (offline: this namespace has no mount to make it live) refuses.
OUT="$("$GROWFS" "$DEV" 2>&1)" && RC=0 || RC=$?
if [ "$RC" != 0 ] && grep -qF "$EXCL_MSG" <<<"$OUT"; then
    pass "3: growfs refuses a device mounted in another namespace"
else
    fail "3: growfs rc=$RC: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
fi

# 4: a read-only fsck is not an exclusive open and is not refused by it.
OUT="$("$FSCK" "$DEV" 2>&1 || true)"
if grep -qF "$EXCL_MSG" <<<"$OUT"; then
    fail "4: a read-only fsck was refused by the exclusive open: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
else
    pass "4: a read-only fsck takes no exclusive open"
fi

# 5: CONTROL. With the exclusive open skipped, mkfs gets past it, and the
# next refusal is the Node Registry's: the holder is still heartbeating.
# The refusal above was the open's, not something else's.
OUT="$(CETRAFS_TEST_TOOLS_NO_EXCL=1 "$MKFS" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f 2>&1)" && RC=0 || RC=$?
if grep -qF "$EXCL_MSG" <<<"$OUT"; then
    fail "5: control: with the exclusive open skipped the refusal still came -- the knob did not take"
elif grep -qF "is mounted by another node" <<<"$OUT"; then
    pass "5: control: with the exclusive open skipped, mkfs got past it and stopped at the Node Registry check"
else
    fail "5: control: rc=$RC, neither the open's refusal nor the registry's: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
fi

ct_exit
