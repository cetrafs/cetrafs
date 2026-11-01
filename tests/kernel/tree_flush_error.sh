#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a close or fsync whose extent-tree flush failed neither publishes over it nor reports success
#
# A spilled file's extent leaves are left dirty by allocation and pushed
# to the device at the durability boundaries -- fsync and the last
# writer's close -- right before the record. Both dropped the result:
#  - close published the record anyway (a CAS: durable at once) and
#    cleared the lock, so the next opener -- on any node -- mapped the
#    file through on-disk leaves that lacked this writer's extents;
#  - fsync skipped the tree silently when the record could not be read
#    or an interior block was unreadable (not reachable here: the knob
#    fails the flush itself, which fsync already reported -- its
#    assertion below is a regression guard, not a discriminator).
# Rule 8: a reference may not become durable before what it refers to.
#
# DISCRIMINATION (measured on the unfixed code): the close logs nothing
# and clears the on-disk lock.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
IPOKE="$(ct_helper inode_block_poke)"
LOCK_POKE="$(ct_helper inode_lock_poke)"

DEV="$(ct_dev 560 treeflush)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt treeflush)"
ct_mkfs_small "$DEV" >/dev/null
ct_param_set alloc_run_blocks 0 # one block per allocation: a spilled tree on demand
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

# F past the inline slots: its blocks interleave with H's.
python3 - "$MNT" <<'PY'
import os, sys
m = sys.argv[1]
f = os.open(m + "/F", os.O_RDWR | os.O_CREAT, 0o644)
h = os.open(m + "/H", os.O_RDWR | os.O_CREAT, 0o644)
for i in range(12):
    os.pwrite(f, b'F' * 4096, i * 4096); os.fsync(f)
    os.pwrite(h, b'H' * 4096, i * 4096); os.fsync(h)
os.close(f); os.close(h)
PY
sync
FINO="$(stat -c %i "$MNT/F")"
"$IPOKE" "$BACK" extents "$FINO" | grep -q '^leaf=' && pass "setup: F's extent map has spilled into a leaf" ||
    { fail "setup: F is still depth 0 -- there is no tree to flush"; ct_exit; }
lockmode() { "$LOCK_POKE" "$DEV" "$FINO" | sed -n 's/.* mode=\([0-9]*\).*/\1/p'; }

log "close"
MARK="$(dmesg_mark)"
exec 8>>"$MNT/F"
printf 'Z%.0s' $(seq 4096) >&8
ct_param_set tree_flush_fail_once 1
exec 8>&-
ct_param_set tree_flush_fail_once 0
dmesg_since "$MARK" | grep -q "extent-tree blocks not durable" && pass "close: the failed tree flush was reported" ||
    fail "close: nothing reported the failed tree flush"
[ "$(lockmode)" = 1 ] && pass "close: the lock stayed held -- nothing was handed over on top of the lost leaves" ||
    fail "close: the lock was cleared (mode=$(lockmode)) over a tree that never reached the device"

# The next ordinary close publishes and lets go.
exec 8>>"$MNT/F"
exec 8>&-
[ "$(lockmode)" = 0 ] && pass "close: the next close published and released" ||
    fail "close: the lock is stuck (mode=$(lockmode)) after a clean close"

log "fsync"
rc=0
out="$(python3 - "$MNT/F" "$(ct_procdir "$DEV")" <<'PY' 2>&1
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND)
os.write(fd, b'Y' * 4096)
with open('/sys/module/cetrafs/parameters/tree_flush_fail_once', 'w') as k:
    k.write('1')
try:
    os.fsync(fd)
    print("fsync=ok")
except OSError as e:
    print("fsync=%s" % e.strerror)
with open('/sys/module/cetrafs/parameters/tree_flush_fail_once', 'w') as k:
    k.write('0')
os.fsync(fd)
os.close(fd)
PY
)" || rc=$?
grep -q '^fsync=ok' <<<"$out" && fail "fsync: returned success although the extent tree was not flushed" ||
    { grep -q '^fsync=' <<<"$out" && pass "fsync: reported the failed tree flush ($(sed -n 's/^fsync=//p' <<<"$out"))" ||
        fail "fsync: the probe did not run: $out"; }

ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && pass "fsck clean" || fail "fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -3)"
ct_exit
