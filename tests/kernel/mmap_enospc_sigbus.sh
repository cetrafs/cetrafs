#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a store into a mapped hole on a full volume must raise SIGBUS
#
# A shared writable mapping is the one write path that never calls
# .write_begin. With generic_file_mmap's vm_ops nothing in cetrafs ran
# at the store at all: the folio was simply dirtied, and the first
# cetrafs_get_block() for it happened in WRITEBACK -- in a flusher
# thread, long after the storing process moved on. An -ENOSPC there has
# nobody to return to. The process is told only if it calls msync() or
# fsync() and checks the result; a process that just stores and exits
# loses the data with no indication whatsoever.
#
# POSIX is explicit that this is SIGBUS at the store, and SIGBUS is what
# a .page_mkwrite that allocates (block_page_mkwrite + get_block)
# produces -- the allocation happens while the faulting process is still
# on the stack.
#
# Filling by SPACE, not by file count: a volume whose 1024 inodes are
# exhausted still has most of its blocks free, and the first version of
# this suite "passed" against the unfixed kernel for exactly that reason
# -- the store had somewhere to go. free_data_blocks is asserted to be 0
# before the store, so the test cannot quietly stop testing anything.
#
# Discrimination: route cetrafs_page_mkwrite() to filemap_page_mkwrite()
# (the old behaviour) and the store is accepted; the failure surfaces
# only as an ENOSPC from the msync() below, which is precisely the
# report a real workload never asks for.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 mmapnospc)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt mmapnospc)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

RC=0
python3 - "$MNT" <<'PY' || RC=$?
import glob, mmap, os, signal, sys

mnt = sys.argv[1]
SZ = 1 << 20

f = os.open(mnt + "/sparse", os.O_RDWR | os.O_CREAT, 0o644)
os.ftruncate(f, SZ)                       # all holes: nothing allocated yet

# One file grown until the device refuses, so what stops us is blocks and
# not the inode table.
fd = os.open(mnt + "/filler", os.O_WRONLY | os.O_CREAT, 0o644)
try:
    while True:
        os.write(fd, b'F' * (1 << 20))
except OSError:
    pass
os.fsync(fd)
os.close(fd)
os.sync()

free = None
for info in glob.glob("/proc/fs/cetrafs/*/info"):
    for line in open(info):
        if line.startswith("free_data_blocks"):
            free = int(line.split()[-1])
print("free_data_blocks before the store: %s" % free)
if free != 0:
    print("the volume is not full -- this test would prove nothing")
    sys.stdout.flush()
    os._exit(2)

m = mmap.mmap(f, SZ, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
pid = os.fork()
if pid == 0:
    for off in range(0, SZ, 4096):
        m[off] = 0xEE                     # no block can back this
    os._exit(0)
_, st = os.waitpid(pid, 0)
if os.WIFSIGNALED(st) and os.WTERMSIG(st) == signal.SIGBUS:
    print("the store raised SIGBUS")
    sys.stdout.flush()
    os._exit(0)

# No SIGBUS: say what the process was told instead, which is the point.
told = "nothing"
try:
    m.flush()
except OSError as e:
    told = "an %s from msync(), which it had to ask for" % e.strerror
print("the store was accepted on a full volume; the process was told %s" % told)
sys.stdout.flush()
os._exit(1)
PY

[ "$RC" = 0 ] &&
    pass "a store with no block to back it raises SIGBUS at the store" ||
    { [ "$RC" = 2 ] &&
        fail "setup did not fill the volume -- the assertion could not be made" ||
        fail "the store was accepted on a full volume: the data is lost and only an explicit msync() would have said so"; }

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null || fail "fsck found faults after the refused stores"
pass "fsck clean"

ct_exit
