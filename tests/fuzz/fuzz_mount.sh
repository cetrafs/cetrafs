#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fuzz the KERNEL's mount/read paths with mutated images. A finding here
# can Oops or wedge the HOST (that is the point) -- run it on a
# disposable machine, bounded, and it stops at the first kernel splat.
# Usage: fuzz_mount.sh [iters] [seed]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/fuzz"
WORK="${CETRAFS_FUZZ_DIR:-/tmp/cetrafs-fuzz}"
mkdir -p "$WORK"
ITERS="${1:-300}"
SEED="${2:-$RANDOM$RANDOM}"
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 2; }
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$WORK/sb_restamp" "$HERE/sb_restamp.c"
# Rebuild the golden if it is missing OR older than the on-disk format or
# mkfs -- a cached golden from a prior layout silently fuzzes stale offsets
# (measured: a v2->v3 field shift left node_table_start reading garbage).
if [ ! -f "$WORK/golden.img" ] || [ "$ROOT/include/cetrafs.h" -nt "$WORK/golden.img" ] \
   || [ "$ROOT/userspace/mkfs.c" -nt "$WORK/golden.img" ]; then
    "$HERE/mkgolden.sh" "$WORK/golden.img"
fi
modprobe libcrc32c 2>/dev/null || true
modprobe scsi_mod 2>/dev/null || true
if ! lsmod | grep -q '^cetrafs '; then
    make -s -C "$ROOT" mod >/dev/null
    insmod "$ROOT/kmod/cetrafs.ko" auto_defrag=0
    # Unload what WE loaded: a module left behind without cas_selftest=1
    # makes the next `make check`'s require_module -- which never reloads
    # an already-loaded module -- silently skip the CAS selftest and fail
    # its assertion (measured, not hypothetical).
    trap 'rmmod cetrafs 2>/dev/null || true' EXIT
fi
python3 "$HERE/fuzz.py" mount "$WORK/golden.img" --iters "$ITERS" --seed "$SEED" \
    --restamp "$WORK/sb_restamp" --findings "$WORK/findings-mount" --mnt "$WORK/mnt"
