#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a node that hands its write lock over (flock LOCK_UN) stops writing the file
#
# flock(LOCK_UN) on a default mount gives this node's automatic lock
# back so a peer can claim the file. Nothing stopped this node's own
# writers: write(2), a store through a mapping, truncate and fallocate
# all went on while the peer the file was handed to wrote it too -- two
# writers, which the access rule forbids (docs/internal/BASICS.md), each
# allocating from its own Zone Groups and publishing its own extent
# tree onto the one record.
#
# While suspended every local write path now fails (ETXTBSY; SIGBUS for
# a store through a mapping), and flock(LOCK_EX) lets them through again.
#
# DISCRIMINATION: lock_suspend_skip_gate restores the old behaviour, and
# the same write must then succeed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v flock >/dev/null || { skip "flock(1) not installed"; ct_exit; }
[ -w /sys/module/cetrafs/parameters/lock_suspend_skip_gate ] || { skip "lock_suspend_skip_gate is missing"; ct_exit; }

DEV="$(ct_dev 560 lsw)"
MNT="$(ct_mnt lsw)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
grep -q nofilelock /proc/mounts && { skip "nofilelock mount: no automatic lock to suspend"; ct_exit; }

dd if=/dev/zero bs=4096 count=4 2>/dev/null | tr '\0' 'A' >"$MNT/f"
sync
SUM="$(sha256sum <"$MNT/f" | cut -d' ' -f1)"

# The mapping is made BEFORE the suspend and dirtied once, the way a
# running guest's would be: the suspend's flush cleans it, and the next
# store must come back through page_mkwrite.
MAP_GO="$(ct_tmp)"
rm -f "$MAP_GO"
MAP_OUT="$(ct_tmp)"
python3 -I - "$MNT/f" "$MAP_GO" >"$MAP_OUT" 2>&1 <<'PY' &
import mmap, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
m = mmap.mmap(fd, 16384)
m[0:1] = b"A"
print("mapped", flush=True)
while not os.path.exists(sys.argv[2]):
    time.sleep(0.02)
m[100:101] = b"M"      # SIGBUS here kills us before the next line
m.flush()
print("stored", flush=True)
PY
MAPPER=$!
for _ in $(seq 1 100); do grep -q mapped "$MAP_OUT" && break; sleep 0.05; done
grep -q mapped "$MAP_OUT" || { fail "setup: the mapper did not start"; ct_exit; }

exec 9>>"$MNT/f"
flock -u 9 || { fail "setup: flock(LOCK_UN) failed"; ct_exit; }
pass "setup: the automatic lock is suspended, the fd still open"

refused() { # <label> <command...>
    local label="$1" out rc=0
    shift
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" != 0 ] && grep -qi "text file busy" <<<"$out"; then
        pass "suspended: $label is refused (ETXTBSY)"
    elif [ "$rc" != 0 ]; then
        fail "suspended: $label failed, but not with ETXTBSY: $out"
    else
        fail "suspended: $label went through -- this node writes a file it handed to a peer"
    fi
}
refused "write(2) on the held fd" bash -c 'printf B >&9' 9>&9
refused "write(2) on a new fd" bash -c "printf B >>'$MNT/f'"
refused "O_DIRECT write" dd if=/dev/zero of="$MNT/f" bs=4096 count=1 oflag=direct conv=notrunc status=none
refused "truncate(2)" truncate -s 4096 "$MNT/f"
refused "fallocate punch" fallocate -p -o 0 -l 4096 "$MNT/f"
refused "fallocate" fallocate -n -o 65536 -l 4096 "$MNT/f"

: >"$MAP_GO"
rc=0
wait "$MAPPER" || rc=$?
if [ "$rc" = 135 ] || [ "$rc" = 7 ]; then
    pass "suspended: a store through an existing mapping faults (SIGBUS)"
elif grep -q stored "$MAP_OUT"; then
    fail "suspended: a store through an existing mapping went through"
else
    fail "suspended: the mapper died with rc=$rc: $(cat "$MAP_OUT")"
fi

[ "$(sha256sum <"$MNT/f" | cut -d' ' -f1)" = "$SUM" ] &&
    pass "suspended: the file is exactly as it was handed over" ||
    fail "suspended: the file changed while this node did not hold its lock"

flock -x 9 || fail "resume: flock(LOCK_EX) failed"
if printf 'C' >&9; then
    pass "resumed: writes go through again"
else
    fail "resumed: a write after flock(LOCK_EX) failed"
fi

# NEGATIVE CONTROL: with the gate off the same write goes through while
# suspended -- the assertion above is about the gate, not about something
# else refusing the write.
ct_param_set lock_suspend_skip_gate 1
flock -u 9 || fail "control: flock(LOCK_UN) failed"
if printf 'D' >&9; then
    pass "control: with lock_suspend_skip_gate the suspended write goes through (the test discriminates)"
else
    fail "control: the write was refused even with the gate off -- the assertions above prove nothing"
fi
ct_param_set lock_suspend_skip_gate 0
flock -x 9 || true
exec 9>&-
ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" || fail "fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -3)"
ct_exit
