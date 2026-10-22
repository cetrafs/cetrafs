#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Stage-2 (field-aware) fuzz of fsck.cetra: mutate one checksummed
# structure at a time and restamp it (fuzz_restamp) so the mutation
# reaches the parser behind its checksum. Safe -- userspace only -- so
# run it in the thousands. Usage: fuzz_fsck_fields.sh [iters] [seed]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tests/fuzz"
WORK="${CETRAFS_FUZZ_DIR:-/tmp/cetrafs-fuzz}"
mkdir -p "$WORK"
ITERS="${1:-2000}"
SEED="${2:-$RANDOM$RANDOM}"
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" -O2 -std=gnu99 \
    -o "$WORK/fuzz_restamp" "$HERE/fuzz_restamp.c"
cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -O1 -g -std=gnu99 \
    -fsanitize=address,undefined -fno-sanitize-recover=all \
    -o "$WORK/fsck.asan" "$ROOT/userspace/fsck.c"
if [ ! -f "$WORK/golden.img" ] || [ "$ROOT/include/cetrafs.h" -nt "$WORK/golden.img" ] \
   || [ "$ROOT/userspace/mkfs.c" -nt "$WORK/golden.img" ]; then
    "$HERE/mkgolden.sh" "$WORK/golden.img"
fi
python3 "$HERE/fuzz.py" fsck-fields "$WORK/golden.img" --iters "$ITERS" --seed "$SEED" \
    --fsck "$WORK/fsck.asan" --restamp "$WORK/fuzz_restamp" --findings "$WORK/findings-fsck-fields"
