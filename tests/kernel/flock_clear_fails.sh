#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a flock release whose clear fails is reported or retried, never forgotten
#
# Under nofilelock the whole-file lock exists only while a flock(2)
# holder holds it -- the live-migration handoff. flock(LOCK_UN) and the
# holder's close cleared it with a CAS whose result was discarded, and
# forgot the holder either way. A clear that failed left the lock on the
# device, owned by this live, heartbeating node: every peer open refused,
# and this node's own LOCK_EX answered -ETXTBSY to itself, for ever.
#
# Now LOCK_UN returns the error and keeps the holder, so a retry works;
# and a close queues the clear for the heartbeat, which finishes it even
# with the VM's writer fd still open.
#
# DISCRIMINATION: with the old (void) clears, round A's LOCK_UN returns 0
# with the lock still on the device and the next LOCK_EX is refused
# (EAGAIN to this node's own request); and round B's lock is still held
# after the heartbeat has had its chances. ->flock discarded the release's
# result as well, so it must pass the error up for round A to see it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/flock_clear_fail_once ] || { skip "flock_clear_fail_once is missing"; ct_exit; }
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 flockclr)"
MNT="$(ct_mnt flockclr)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set hb_interval_secs 2
ct_track mnt "$MNT"
mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
NID="$(sed -n "s/^this_node_id: //p" "$(ct_procdir "$DEV")/info")"
echo image >"$MNT/vm.img"
INO="$(stat -c %i "$MNT/vm.img")"
sync
dump() { "$LOCK_POKE" "$DEV" "$INO"; }

# --- A: LOCK_UN whose clear fails
RES="$(python3 - "$MNT/vm.img" <<'PY'
import fcntl, os, sys
p = sys.argv[1]
vm = os.open(p, os.O_RDWR)            # the VM's own writer, open throughout
fd = os.open(p, os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
open("/sys/module/cetrafs/parameters/flock_clear_fail_once", "w").write("1")
try:
    fcntl.flock(fd, fcntl.LOCK_UN); first = "ok"
except OSError as e:
    first = "errno%d" % e.errno
try:
    fcntl.flock(fd, fcntl.LOCK_UN); second = "ok"
except OSError as e:
    second = "errno%d" % e.errno
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); again = "ok"
    fcntl.flock(fd, fcntl.LOCK_UN)
except OSError as e:
    again = "errno%d" % e.errno
os.close(fd); os.close(vm)
print(first, second, again)
PY
)"
log "A: LOCK_UN with a failing clear, LOCK_UN again, LOCK_EX again: $RES"
read -r FIRST SECOND AGAIN <<<"$RES"
[ "$FIRST" != ok ] && pass "A: the failed release was reported ($FIRST)" ||
    fail "A: LOCK_UN returned success with its clear failed"
[ "$SECOND" = ok ] && [ "$AGAIN" = ok ] && pass "A: a retried LOCK_UN released it, and LOCK_EX works again" ||
    fail "A: after the failed release: LOCK_UN $SECOND, LOCK_EX $AGAIN -- the holder was forgotten"
dump | grep -q 'mode=0' && pass "A: the device shows no lock ($(dump))" || fail "A: the lock is still on the device: $(dump)"

# --- B: the holder's close fails to clear, with the VM's writer still open
exec 8<>"$MNT/vm.img"
if python3 - "$MNT/vm.img" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError as e:
    sys.exit("setup: LOCK_EX refused (errno %d) -- round A left the lock held" % e.errno)
open("/sys/module/cetrafs/parameters/flock_clear_fail_once", "w").write("1")
os.close(fd)
PY
then
    [ "$(cat /sys/module/cetrafs/parameters/flock_clear_fail_once)" = N ] ||
        fail "setup: the close's clear was not the one that failed"
    log "B: the holder closed with its clear failing; waiting for the heartbeat"
    OK=0
    for _ in $(seq 1 15); do dump | grep -q 'mode=0' && { OK=1; break; }; sleep 1; done
    [ "$OK" = 1 ] && pass "B: the heartbeat cleared the lock with the writer still open ($(dump))" ||
        fail "B: the lock is still held 15 s after its holder closed: $(dump)"
else
    fail "B: could not take the lock to set up the round"
fi
exec 8<&-

ct_umount "$MNT"
ct_exit
