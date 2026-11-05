#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# A size extension does not publish mmap stores made past the old EOF
#
# A store through a shared mapping may land past EOF inside the folio
# that holds it; the bytes are not file contents, and writeback zeroes
# them while they stay past i_size. Growing the size over them made them
# contents: ftruncate, fallocate and a write starting past EOF (in a
# later page or the same one) all returned the stored bytes, cached and
# from the device after a cache drop (audit 2026-11-05; ext4 returns
# zeros). cetrafs_zero_post_eof() zeroes the tail before the size moves.
#
# Per extension: a 100-byte file, 0xaa stored over bytes 100..4095 of
# its mapping, the extension, then bytes 100..4095 read back -- all zero
# except, for the same-page write, the one byte it wrote. Setup check:
# the stores are visible through the mapping before the extension.
#
# DISCRIMINATION: proven 2026-11-05 with kmod/file.c reverted: every
# extension returns 3996 (2901 for the same-page write) stored bytes.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
command -v python3 >/dev/null || { skip "needs python3"; ct_exit; }

DEV="$(ct_dev 560 eofext)"
MNT="$(ct_mnt eofext)"
ct_track mnt "$MNT"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

OUT="$(python3 - "$MNT" <<'PY'
import os, sys, ctypes
libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
d = sys.argv[1]
def run(name, extend, expect):
    p = os.path.join(d, name)
    fd = os.open(p, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
    os.write(fd, b'x' * 100); os.fsync(fd)
    a = libc.mmap(None, 4096, 3, 1, fd, 0)      # PROT_READ|WRITE, MAP_SHARED
    if a in (None, ctypes.c_void_p(-1).value):
        print(f"SETUP {name} mmap failed"); return
    ctypes.memset(a + 100, 0xaa, 3996)          # past EOF, inside the page
    seen = ctypes.string_at(a + 100, 3996).count(b'\xaa')
    if seen != 3996:
        print(f"SETUP {name} only {seen} stores visible"); return
    extend(fd)
    nz = lambda b: len(b) - b.count(b'\0')  # a read stops at the new EOF
    cached = nz(os.pread(fd, 3996, 100)) - expect
    libc.munmap(a, 4096); os.fsync(fd); os.close(fd)
    with open('/proc/sys/vm/drop_caches', 'w') as f: f.write('3')
    fd = os.open(p, os.O_RDONLY)
    disk = nz(os.pread(fd, 3996, 100)) - expect
    os.close(fd)
    print(f"RES {name} {cached} {disk}", flush=True)
run('ftruncate', lambda fd: os.ftruncate(fd, 8192), 0)
run('fallocate', lambda fd: os.posix_fallocate(fd, 0, 8192), 0)
run('write_later_page', lambda fd: os.pwrite(fd, b'y', 8191), 0)
run('write_same_page', lambda fd: os.pwrite(fd, b'y', 3000), 1)
PY
)" || { fail "setup: the probe itself failed"; ct_exit; }

if grep -q '^SETUP' <<<"$OUT"; then
    fail "setup: $(grep '^SETUP' <<<"$OUT" | head -1)"
    ct_exit
fi
[ "$(grep -c '^RES' <<<"$OUT")" = 4 ] || { fail "setup: the probe ran $(grep -c '^RES' <<<"$OUT") of 4 cases"; ct_exit; }
while read -r _ name cached disk; do
    if [ "$cached" = 0 ] && [ "$disk" = 0 ]; then
        pass "$name: stores past the old EOF did not become file contents"
    else
        fail "$name: $cached stored bytes readable from cache, $disk from the device after the extension"
    fi
done < <(grep '^RES' <<<"$OUT")

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null && pass "fsck clean" || fail "fsck reported damage"
ct_exit
