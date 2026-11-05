#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a setattr whose publish is refused leaves the inode as it was
#
# setattr copies the new mode, owner and times into the in-core inode,
# then publishes them by a CAS of the record's namespace sector. When the
# CAS was refused the call failed -- and the in-core inode kept the new
# values: the failed chmod showed through the descriptor, and the next
# setattr of anything else on it (a futimens) published the in-core mode
# with it, making the chmod that reported failure durable (audit L36).
#
# setattr_ns_fail_once refuses one publish, as a device error would.
#
# DISCRIMINATION: without the rollback the failed chmod shows through
# the descriptor, and a futimens on it makes the mode durable.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/setattr_ns_fail_once ] || { skip "setattr_ns_fail_once is missing"; ct_exit; }

DEV="$(ct_dev 560 setrb)"
MNT="$(ct_mnt setrb)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
echo x >"$MNT/f"
chmod 644 "$MNT/f"
[ "$(stat -c %a "$MNT/f")" = 644 ] || { fail "setup: the file is not mode 644"; ct_exit; }

# All through ONE descriptor, with no lookup in between: a path lookup
# revalidates the inode from its record and would hide the stale mode.
ct_param_set setattr_ns_fail_once 1
R="$(python3 - "$MNT/f" <<'PY'
import os, stat, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fchmod(fd, 0o600)
    print("chmod-succeeded")
except OSError:
    pass
print("incore=%o" % stat.S_IMODE(os.fstat(fd).st_mode))
os.utime(fd)          # futimens: a setattr of the times only
os.close(fd)
PY
)"
ct_param_set setattr_ns_fail_once 0
grep -q chmod-succeeded <<<"$R" && { fail "setup: the fchmod succeeded although its publish was to be refused"; ct_exit; }
log "after the refused fchmod: $(grep incore <<<"$R")"
grep -q "incore=644" <<<"$R" && pass "a chmod whose publish was refused leaves the mode at 644" ||
    fail "the failed chmod shows in-core: $(grep incore <<<"$R")"

ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
M="$(stat -c %a "$MNT/f")"
[ "$M" = 644 ] && pass "and a later futimens did not publish it (mode 644 after a remount)" ||
    fail "the failed chmod became durable through a later futimens: mode $M after a remount"
ct_umount "$MNT"
OUT="$(ct_fsck "$DEV" 2>&1 || true)"
grep -qE '^ERR' <<<"$OUT" && fail "fsck: $(grep '^ERR' <<<"$OUT" | head -3)" || pass "fsck clean"
ct_exit
