#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a refresh does not put back a local namespace publish that landed behind its read
#
# A refresh (a path lookup's d_revalidate) reads the record, then applies
# it to in-core state. A local namespace publish -- a link -- that swaps
# the record's namespace sector and sets the same field in core can land
# between that read and the apply. Applying the older read then put
# the in-core mode or link count back to a value the device no longer
# holds (BUG-CLASSES class 29). The apply now runs under every lock such
# a publisher holds, and re-reads the namespace sector when the record's
# publish epoch moved behind its read.
#
# Each round, on a file F held open read-only (so it is not "ours" and
# path lookups refresh it, while fd operations do no lookup):
#   1. A path stat of F starts a refresh that stalls between its read and
#      its apply (refresh_compare_stall_ms).
#   2. During the stall, through the fd: a link of F by
#      linkat(AT_EMPTY_PATH), which does not look F up, so does not wait
#      for the stalled refresh. (fchmod cannot be staged here: its record
#      publish waits for the refresh's fd_pub_mutex while holding
#      inode_lock, so the apply declines on its trylock -- setattr and
#      setxattr are serialised that way, not by the re-read.)
#   3. After it: fstat(fd) reads in-core (no refresh) and the poke helper
#      reads the device. They must agree.
# Control (refresh_ns_unguarded=1): the apply takes its read as is; the
# in-core value must be the one the device no longer holds, or the round
# proves nothing.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
for p in refresh_compare_stall_ms refresh_ns_unguarded; do
    [ -w "/sys/module/cetrafs/parameters/$p" ] || { skip "$p is missing"; ct_exit; }
done
command -v python3 >/dev/null || { skip "python3 is missing"; ct_exit; }
POKE="$(ct_helper inode_block_poke)"
# Under nofilelock a local open with no peer present is trusted as is
# (cetrafs_lock_identity_cache_trusted()), so the held fd would stop the
# refresh this suite stalls. The same race is live there whenever a peer
# has the file open too -- staged as such.
ct_nofilelock_run && ct_param_set force_foreign_opener 1

IMG="$(ct_image 560 nspub)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt nspub)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/info"
counter() { sed -n "s/^$1: //p" "$INFO"; }
STALL_MS=1500

# One round: prints "<in-core mode> <in-core nlink> <stalls> <rereads>".
# $1 = op (link), $2 = file, $3 = link name.
round() {
    python3 - "$1" "$2" "$3" "$INFO" "$STALL_MS" <<'PY'
import ctypes, os, sys, threading, time
op, path, lname, info, stall_ms = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
P = "/sys/module/cetrafs/parameters/refresh_compare_stall_ms"

def counter(name):
    with open(info) as f:
        for line in f:
            if line.startswith(name + ": "):
                return int(line.split(": ")[1])
    return 0

fd = os.open(path, os.O_RDONLY)
s0 = counter("refresh_stalls")
r0 = counter("refresh_ns_rereads")
with open(P, "w") as f:
    f.write(str(stall_ms))
t = threading.Thread(target=lambda: os.stat(path))
t.start()
deadline = time.time() + stall_ms / 1000.0 / 2
while counter("refresh_stalls") == s0 and time.time() < deadline:
    time.sleep(0.01)
entered = counter("refresh_stalls") > s0
libc = ctypes.CDLL(None, use_errno=True)
AT_FDCWD, AT_EMPTY_PATH = -100, 0x1000
if libc.linkat(fd, b"", AT_FDCWD, lname.encode(), AT_EMPTY_PATH) != 0:
    print("linkat failed", ctypes.get_errno(), file=sys.stderr)
    sys.exit(3)
op_done_in_stall = counter("refresh_stalls") > s0 and t.is_alive()
t.join()
with open(P, "w") as f:
    f.write("0")
st = os.fstat(fd)
os.close(fd)
print("%o %d %d %d %d" % (st.st_mode & 0o7777, st.st_nlink, int(entered and op_done_in_stall),
                          counter("refresh_ns_rereads") - r0, 0))
PY
}

check() { # <label> <op> <unguarded 0|1>
    local label="$1" op="$2" ung="$3" f="$MNT/$1" out mode nlink inside rereads _z ino dmode dnlink
    : >"$f"
    chmod 0644 "$f"
    sync
    ino="$(stat -c %i "$f")"
    stat "$f" >/dev/null
    ct_param_set refresh_ns_unguarded "$ung"
    out="$(round "$op" "$f" "$MNT/$label.lnk")" || { fail "$label: the round did not run"; return; }
    ct_param_set refresh_ns_unguarded 0
    read -r mode nlink inside rereads _z <<<"$out"
    sync
    read -r dmode dnlink <<<"$("$POKE" "$IMG" nsget "$ino" 2>/dev/null | head -1)"
    dmode=$(printf '%o' $(( 0$dmode & 07777 )))
    log "$label: in-core mode $mode nlink $nlink; device mode $dmode nlink $dnlink; op inside stall $inside; ns re-reads +$rereads"
    if [ "$inside" != 1 ]; then
        fail "$label: setup: the $op did not land while the refresh was stalled between its read and its apply"
        return
    fi
    local want_dev="644 2"
    if [ "$dmode $dnlink" != "$want_dev" ]; then
        fail "$label: setup: the device holds mode $dmode nlink $dnlink, want $want_dev -- the $op did not publish"
        return
    fi
    if [ "$ung" = 1 ]; then
        if [ "$mode $nlink" != "$dmode $dnlink" ]; then
            pass "$label (control, unguarded): the stale read was applied over the $op -- in-core $mode/$nlink, device $dmode/$dnlink"
        else
            fail "$label (control): unguarded, in-core still matches the device ($mode/$nlink) -- the race was not reproduced, the guarded round proves nothing"
        fi
    else
        if [ "$mode $nlink" = "$dmode $dnlink" ] && [ "$rereads" -ge 1 ]; then
            pass "$label: in-core kept the $op ($mode/$nlink); the apply re-read the namespace sector (+$rereads)"
        else
            fail "$label: in-core $mode/$nlink vs device $dmode/$dnlink, ns re-reads +$rereads -- the refresh reverted the $op"
        fi
    fi
}

check link_guarded link 0
check link_ctl link 1
check link_guarded2 link 0

# The control left in-core wrong on purpose; a fresh lookup puts it right.
n=$(stat -c %h "$MNT/link_ctl")
[ "$n" = 2 ] && pass "after the control, a lookup brings in-core back to the device (nlink 2)" ||
    fail "after the control, a lookup left in-core nlink at $n, want 2"

ct_umount "$MNT"
rc=0
FO="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck is clean" || fail "fsck failed (rc $rc): $FO"
ct_exit
