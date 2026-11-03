#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a write-open refused with -ESTALE leaves no write lock behind on the reused record
#
# A write-open claims the whole-file lock by CAS, keyed on the generation
# it just read FRESH off the device. Only afterwards did it compare that
# record with the in-core inode -- and when a peer had deleted the file
# and reused its number, cetrafs_apply_raw_to_vfs_inode() said -ESTALE
# and the open failed, with the claim already on the device and nothing
# to take it back. The reused file then carried an EXCLUSIVE lock owned
# by a live node that had no fd on it: every peer -ETXTBSY until this
# node happened to reopen and close that number, or died.
#
# The reuse is what a peer leaves (inode_block_poke reuse: a new
# generation and a file_seq stamped by another node), poked into the
# backing file so this node only sees it by reading fresh. The open goes
# through an O_PATH fd and /proc/self/fd, which jumps to the cached
# dentry without d_revalidate -- otherwise the revalidate catches the
# reuse first and the open path is never reached (the window it closes
# is revalidate-then-open, which a single process cannot hit on demand).
#
# DISCRIMINATION (measured on the unfixed code): the open fails ESTALE,
# and the record is left lock_mode=EXCLUSIVE owned by this node.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IPOKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
DEV="$(ct_dev 560 claimstale)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt claimstale)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

echo data >"$MNT/f"
sync
INO="$(stat -c %i "$MNT/f")"
before="$("$LPOKE" "$BACK" "$INO")"
case "$before" in
*" mode=0 "*) pass "before: no lock on ino $INO ($before)" ;;
*) fail "before: expected no lock, got '$before' -- setup is not what this measures" ;;
esac

out="$(python3 - "$MNT/f" "$IPOKE" "$BACK" "$INO" <<'PY'
import errno, os, subprocess, sys
path, ipoke, back, ino = sys.argv[1:]
pfd = os.open(path, os.O_PATH)  # pins the dentry; not an open of the file
subprocess.run([ipoke, back, "reuse", ino, "0xfeedf00d", "7"], check=True, stderr=subprocess.DEVNULL)
try:
    fd = os.open("/proc/self/fd/%d" % pfd, os.O_WRONLY)
    os.close(fd)
    print("open=0")
except OSError as e:
    print("open=" + errno.errorcode.get(e.errno, str(e.errno)))
sys.stdout.flush()
PY
)"
log "$out"

# Setup proof: the open really met the reused record.
if grep -qx 'open=ESTALE' <<<"$out"; then
    pass "the write-open saw the reused number and failed ESTALE"
else
    fail "expected open=ESTALE, got '$out' -- the reuse was not seen by the open path"
fi

after="$("$LPOKE" "$BACK" "$INO")"
case "$after" in
*" mode=0 "*) pass "after the refused open the reused record carries no lock ($after)" ;;
*) fail "the refused open LEFT a lock on the reused record: $after" ;;
esac

# The SAME file, deleted by a peer (nlink 0, generation unchanged) --
# the other way the open-boundary refresh says -ESTALE after the claim.
# The claim's own CAS refuses a record that is dead to this node
# (cetrafs_lock_rec_dead_to_us()), so no claim may land on it at all.
log "a write-open of a file a peer deleted (same generation, nlink 0)"
echo data >"$MNT/g"
sync
GINO="$(stat -c %i "$MNT/g")"
out="$(python3 - "$MNT/g" "$IPOKE" "$BACK" "$GINO" <<'PY'
import errno, os, subprocess, sys
path, ipoke, back, ino = sys.argv[1:]
pfd = os.open(path, os.O_PATH)
subprocess.run([ipoke, back, "nlink", ino, "0"], check=True, stderr=subprocess.DEVNULL)
try:
    fd = os.open("/proc/self/fd/%d" % pfd, os.O_WRONLY)
    os.close(fd)
    print("open=0")
except OSError as e:
    print("open=" + errno.errorcode.get(e.errno, str(e.errno)))
sys.stdout.flush()
PY
)"
log "$out"
grep -qE '^open=(ESTALE|ENOENT)$' <<<"$out" &&
    pass "the write-open of the deleted file failed ($out)" ||
    fail "expected the open to fail, got '$out' -- the deletion was not seen by the open path"
after="$("$LPOKE" "$BACK" "$GINO")"
case "$after" in
*" mode=0 "*) pass "and the deleted record carries no lock ($after)" ;;
*) fail "the refused open LEFT a lock on the deleted record: $after" ;;
esac

ct_exit
