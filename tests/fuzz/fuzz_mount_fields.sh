#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Stage-2 (field-aware) fuzz of the KERNEL mount/read paths: mutate one
# checksummed structure, restamp it, mount and exercise. A finding can
# Oops or wedge the HOST -- run on a disposable machine; stops at the
# first kernel splat. Usage: fuzz_mount_fields.sh [iters] [seed]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/fuzz"
WORK="${CETRAFS_FUZZ_DIR:-/tmp/cetrafs-fuzz}"
mkdir -p "$WORK"
ITERS="${1:-300}"
SEED="${2:-$RANDOM$RANDOM}"
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 2; }
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$WORK/fuzz_restamp" "$HERE/fuzz_restamp.c"
if [ ! -f "$WORK/golden.img" ] || [ "$ROOT/include/cetrafs.h" -nt "$WORK/golden.img" ] \
   || [ "$ROOT/userspace/mkfs.c" -nt "$WORK/golden.img" ]; then
    "$HERE/mkgolden.sh" "$WORK/golden.img"
fi
modprobe libcrc32c 2>/dev/null || true
modprobe scsi_mod 2>/dev/null || true
if ! lsmod | grep -q '^cetrafs '; then
    make -s -C "$ROOT" mod >/dev/null
    insmod "$ROOT/kmod/cetrafs.ko" auto_defrag=0
    trap 'rmmod cetrafs 2>/dev/null || true' EXIT
fi
python3 "$HERE/fuzz.py" mount-fields "$WORK/golden.img" --iters "$ITERS" --seed "$SEED" \
    --restamp "$WORK/fuzz_restamp" --findings "$WORK/findings-mount-fields" --mnt "$WORK/mnt"
