#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck --live checks a volume this very host has mounted, after syncing that mount
#
# fsck refused any device mounted on this host, --live included, so a
# live check could only run from a host that did not mount the volume --
# and the sync a live walk does of this host's own mounts
# (fsck_live_sync_local()) could never run (audit 2026-11-22 N-39). A
# --live walk is read-only and claims nothing; it now runs on a locally
# mounted device too.
#
#   1. --live on the device this host has mounted, the volume healthy
#      and quiet: 0;
#   2. the same right after a burst of namespace and tree edits, with
#      no sync of our own: 0, and the walk synced the local mount (its
#      cetrafs_sync_fs is logged) -- whether this rig's held state would
#      have read as damage unsynced is not what is asserted: it did not,
#      measured (2026-11-23), so the sync is shown to RUN, not to matter;
#   3. plain fsck still refuses the mounted device (3).
#
# DISCRIMINATION: CETRAFS_TEST_FSCK_LIVE_REFUSE_LOCAL=1 (as before):
# --live refuses the locally mounted device (3).
# CETRAFS_TEST_FSCK_LIVE_NO_SYNC=1: no sync of the local mount is logged.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
export CETRAFS_PEER_PROBE_SECS=3
require_root
require_module
FSCK="$ROOT/userspace/fsck.cetra"
DEV="$(ct_dev 1200 fsklocal)"
MNT="$(ct_mnt fsklocal)"
ct_mkfs "$DEV" -z 2 -b 512 -J 1 -M 4 -N 4096 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
for i in $(seq 20); do echo "$i" >"$MNT/f$i"; done
mkdir "$MNT/d"
sync

rc=0
out="$(CETRAFS_TEST_FSCK_LIVE_REFUSE_LOCAL=1 "$FSCK" --live "$DEV" 2>&1)" || rc=$?
[ "$rc" = 3 ] && grep -q "is mounted on" <<<"$out" &&
    pass "control: refusing local mounts, --live refuses this host's own (3)" ||
    fail "control: --live gave $rc with the old refusal -- the device does not look mounted here: $(tail -2 <<<"$out")"

rc=0
out="$("$FSCK" --live "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && grep -q "found nothing" <<<"$out" &&
    pass "1: --live on the volume this host has mounted: clean" ||
    fail "1: --live gave $rc: $(grep -E '^ERR|cetrafs fsck --live' <<<"$out" | head -4)"

# A burst of edits, nothing synced by us: what this mount holds back is
# its own to flush, and the walk asks it to.
for i in $(seq 40); do echo "x$i" >"$MNT/d/g$i"; done
python3 -I - "$MNT/frag" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(40):
    os.pwrite(fd, b'f' * 4096, i * 2 * 4096)
os.close(fd)
PY
rm -f "$MNT/f3" "$MNT/f4"
rc=0
mark="$(dmesg_mark)"
out="$("$FSCK" --live "$DEV" 2>&1)" || rc=$?
synced="$(dmesg_since "$mark" | grep -c 'cetrafs_sync_fs' || true)"
[ "$rc" = 0 ] && [ "$synced" -ge 1 ] &&
    pass "2: right after a burst of edits, --live synced the local mount and found it clean" ||
    fail "2: --live gave $rc, local syncs logged: $synced: $(grep -E '^ERR|cetrafs fsck --live' <<<"$out" | head -4)"
mark="$(dmesg_mark)"
CETRAFS_TEST_FSCK_LIVE_NO_SYNC=1 "$FSCK" --live "$DEV" >/dev/null 2>&1 || true
synced="$(dmesg_since "$mark" | grep -c 'cetrafs_sync_fs' || true)"
[ "$synced" = 0 ] && pass "control 2: with the local sync skipped, none is logged" ||
    fail "control 2: $synced sync(s) logged with the local sync skipped -- something else syncs, check 2 proves nothing"

rc=0
"$FSCK" "$DEV" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && pass "3: plain fsck still refuses the mounted device (3)" || fail "3: plain fsck gave $rc"

ct_umount "$MNT"
ct_exit
