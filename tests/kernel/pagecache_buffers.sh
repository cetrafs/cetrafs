#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# buffer heads must be released when their folios are discarded
#
# cetrafs's folios carry BUFFER HEADS -- block_write_begin() and
# block_read_full_folio() attach them. The address_space_operations had
# no .invalidate_folio, so truncate_inode_pages_range() cancelled the
# FOLIO's dirty bit and left each attached buffer's own dirty bit set.
# try_to_free_buffers() refuses to free a dirty buffer, so the discarded
# folio could never be reclaimed.
#
# Nothing is corrupted by this and nothing is logged; it is a slow leak
# that only shows under a truncate-heavy workload -- which is exactly
# what a datastore of VM images is, and exactly the kind of thing a
# short functional test never sees. Measured on the broken build: 40
# cycles of dirtying 2 MB and truncating it away grew the buffer_head
# slab by ~20100 objects, about one per block written, and they did not
# come back at unmount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

bh_count() { grep -E "^buffer_head" /proc/slabinfo 2>/dev/null | awk '{print $2}'; }

IMG="$(ct_image 560 bufs)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt bufs)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

log "discarded folios give their buffer heads back"
if [ -z "$(bh_count)" ]; then
    skip "/proc/slabinfo does not report buffer_head on this kernel"
else
    # Settle first: an unrelated allocation spike would be read as growth.
    sync
    BEFORE="$(bh_count)"
    CYCLES=40
    MB=2
    python3 - "$MNT" "$CYCLES" "$MB" <<'PY'
import os, sys
mnt, cycles, mb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
for _ in range(cycles):
    f = os.open(mnt + "/v", os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
    os.pwrite(f, b"V" * (mb * 1024 * 1024), 0)   # dirty it
    os.ftruncate(f, 0)                            # ...and discard it dirty
    os.close(f)
PY
    sync
    AFTER="$(bh_count)"
    WRITTEN=$((CYCLES * MB * 1024 * 1024 / 4096))
    GROWTH=$((AFTER - BEFORE))
    # The broken build grows by about one buffer_head per block written.
    # A tenth of that is far above any plausible unrelated noise and far
    # below the leak.
    LIMIT=$((WRITTEN / 10))
    if [ "$GROWTH" -lt "$LIMIT" ]; then
        pass "buffer_head count grew by $GROWTH after discarding $WRITTEN dirty blocks (limit $LIMIT)"
    else
        fail "buffer_head count grew by $GROWTH after discarding $WRITTEN dirty blocks -- the folios' buffers were never freed"
    fi
fi

log "the data path still behaves"
dd if=/dev/urandom of="$MNT/rnd" bs=4096 count=256 status=none
SUM="$(md5sum <"$MNT/rnd")"
ct_umount "$MNT"
ct_mount "$DEV" "$MNT"
[ "$(md5sum <"$MNT/rnd")" = "$SUM" ] && pass "a 1 MB file survives a remount byte-for-byte" ||
    fail "the file changed across a remount"
truncate -s 100000 "$MNT/rnd"
[ "$(stat -c '%s' "$MNT/rnd")" = "100000" ] && pass "truncate to a non-block-aligned size works" ||
    fail "truncate to 100000 gave $(stat -c '%s' "$MNT/rnd")"
python3 -c "
import sys
d = open(sys.argv[1],'rb').read()
sys.exit(0 if len(d) == 100000 else 1)" "$MNT/rnd" && pass "the truncated file reads back at its new length" ||
    fail "the truncated file does not read back correctly"

log "O_DIRECT is accepted (.direct_IO is wired up)"
# This assertion used to require the OPPOSITE: with no .direct_IO the
# VFS rejected O_DIRECT at open, and F4 recorded that refusal as the
# supported behaviour while noting what it cost (a Proxmox guest
# configured cache=none -- the default -- could not open its image at
# all). .direct_IO exists now, so the same probe asserts acceptance.
# The behaviour itself is covered by kernel/direct_io.sh; what is
# checked here is only that it survives alongside the buffer-head
# accounting this suite exists for, since the two share an aops table.
OUT="$(python3 - "$MNT" <<'XPY'
import os, sys, errno
try:
    fd = os.open(sys.argv[1] + "/rnd", os.O_RDONLY | os.O_DIRECT)
    os.close(fd)
    print("opened")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
except AttributeError:
    print("no-O_DIRECT-constant")
XPY
)"
case "$OUT" in
opened) pass "O_DIRECT is accepted now that .direct_IO is implemented" ;;
*) fail "O_DIRECT was refused ($OUT) -- .direct_IO is registered but not working" ;;
esac

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" || fail "fsck: $(ct_fsck "$DEV" 2>&1 | tail -3)"
ct_exit
