#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fuzz fsck.cetra (ASAN+UBSAN build) with mutated images. Safe --
# userspace only -- so run it in the thousands. Usage:
#   fuzz_fsck.sh [iters] [seed]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/fuzz"
WORK="${CETRAFS_FUZZ_DIR:-/tmp/cetrafs-fuzz}"
mkdir -p "$WORK"
ITERS="${1:-2000}"
SEED="${2:-$RANDOM$RANDOM}"
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$WORK/sb_restamp" "$HERE/sb_restamp.c"
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -O1 -g -std=gnu99 \
    -fsanitize=address,undefined -fno-sanitize-recover=all \
    -o "$WORK/fsck.asan" "$ROOT/userspace/fsck.c"
# Rebuild the golden if it is missing OR older than the on-disk format or
# mkfs -- a cached golden from a prior layout silently fuzzes stale offsets
# (measured: a v2->v3 field shift left node_table_start reading garbage).
if [ ! -f "$WORK/golden.img" ] || [ "$ROOT/include/cetrafs.h" -nt "$WORK/golden.img" ] \
   || [ "$ROOT/userspace/mkfs.c" -nt "$WORK/golden.img" ]; then
    "$HERE/mkgolden.sh" "$WORK/golden.img"
fi
python3 "$HERE/fuzz.py" fsck "$WORK/golden.img" --iters "$ITERS" --seed "$SEED" \
    --fsck "$WORK/fsck.asan" --restamp "$WORK/sb_restamp" --findings "$WORK/findings-fsck"
