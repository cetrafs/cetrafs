#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a volume filled to ENOSPC through each allocating path fails cleanly
#
# enospc_fill_no_leak fills the volume with one path and checks for leaks.
# Nothing else ran a DELIBERATE fill: ENOSPC reached the other allocating
# paths only by accident of a churn. Allocation failure part-way through
# a multi-step operation is a classic corruption source, so each path
# here fills the volume through itself until it refuses, then checks:
#
#   * the refusal is ENOSPC (no EIO/EUCLEAN, no silent success)
#   * no foreign data: every block of every file the path wrote is its
#     own data or zeros, never another file's or garbage
#   * a canary written before the fill is intact
#   * the directory / xattr / extent the path grew still reads back
#   * after unmount, fsck reports no error and no leaked block
#   * after the fillers are deleted the volume takes a new file, verified
#
# Paths: buffered write, O_DIRECT write, fallocate, directory growth,
# xattr growth, extent-tree growth (one extent per block on a full
# volume). The mmap fault path is mmap_enospc_sigbus.sh, and the defrag
# commit is defrag_controls / defrag_declines.
#
# Negative control: none of these paths has a knob that makes it leak or
# tear, so the content and fsck assertions are not themselves shown to
# discriminate here -- the leak instrument is proven by
# enospc_fill_no_leak.sh's fd_take_clears_dirty control, and the
# remaining assertions are regression checks for paths that today are
# clean. This is recorded in TEST-COVERAGE-GAPS.md (section 5).
# ct-timeout: 900
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
FILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helpers/enospc_fill.py"

# leaked / ERR counts from a fsck of an unmounted device.
fsck_report() { ct_fsck "$1" 2>&1 || true; }

run_mode() { # <mode>
    local mode="$1" IMG DEV MNT OUT LINE OUT2 LK ERRS SHA0 SHA1
    IMG="$(ct_image 560 enospc_$mode)"
    DEV="$(ct_loop "$IMG")"
    MNT="$(ct_mnt enospc_$mode)"
    ct_mkfs_small "$DEV" >/dev/null
    ct_param_set auto_defrag 0
    ct_track mnt "$MNT"
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"

    # A canary the path must not disturb.
    python3 -c 'import sys,hashlib; sys.stdout.buffer.write((hashlib.sha256(b"canary").digest() * 8192)[:262144])' >"$MNT/canary"
    sync
    SHA0="$(sha256sum "$MNT/canary" | cut -d' ' -f1)"

    OUT="$(python3 "$FILL" "$MNT" "$mode" 2>&1 || true)"
    LINE="$(head -1 <<<"$OUT")"
    if ! grep -q '^OK$' <<<"$OUT"; then
        fail "$mode: the fill did not end cleanly: $(tr '\n' ' ' <<<"$OUT" | cut -c1-300)"
        ct_umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
        return 0
    fi
    pass "$mode: the volume refused the path with ENOSPC and every file it wrote holds only its own data ($LINE)"

    # The canary and the fillers must still be what the path left.
    SHA1="$(sha256sum "$MNT/canary" | cut -d' ' -f1)"
    [ "$SHA0" = "$SHA1" ] && pass "$mode: the canary written before the fill is intact" ||
        fail "$mode: the canary changed during the fill"

    sync
    ct_umount "$MNT"
    OUT2="$(fsck_report "$DEV")"
    ERRS="$(grep -c '^ERR' <<<"$OUT2" || true)"
    LK="$(sed -n 's/^WARN: \([0-9]*\) data block(s) marked in use but referenced by no inode.*/\1/p' <<<"$OUT2" | head -1)"
    LK="${LK:-0}"
    [ "$ERRS" -eq 0 ] && pass "$mode: fsck reports no error after the ENOSPC" ||
        fail "$mode: fsck reports $ERRS error(s): $(grep '^ERR' <<<"$OUT2" | head -2 | tr '\n' ' ')"
    [ "$LK" -eq 0 ] && pass "$mode: no block leaked by the refused allocation" ||
        fail "$mode: $LK block(s) leaked by the refused allocation"

    # Space comes back: delete the fillers, then a new file takes the volume.
    ct_mount "$DEV" "$MNT"
    require_cetrafs_mount "$MNT"
    find "$MNT" -mindepth 1 -maxdepth 1 ! -name canary -exec rm -rf {} + 2>/dev/null || true
    python3 -c 'import sys,hashlib; sys.stdout.buffer.write((hashlib.sha256(b"after").digest() * 262144)[:8388608])' >"$MNT/after"
    sync
    if [ "$(sha256sum "$MNT/after" | cut -d' ' -f1)" = "$(python3 -c 'import sys,hashlib; sys.stdout.buffer.write((hashlib.sha256(b"after").digest() * 262144)[:8388608])' | sha256sum | cut -d' ' -f1)" ]; then
        pass "$mode: after the fillers are deleted an 8 MiB file takes the volume and reads back"
    else
        fail "$mode: the volume did not take a new 8 MiB file after the fillers were deleted"
    fi
    ct_umount "$MNT"
    OUT2="$(fsck_report "$DEV")"
    grep -q '^ERR' <<<"$OUT2" && fail "$mode: fsck after reuse: $(grep '^ERR' <<<"$OUT2" | head -2 | tr '\n' ' ')" ||
        pass "$mode: fsck is clean again after reuse"
}

for m in write odirect fallocate dir xattr extent; do
    log "$m"
    run_mode "$m"
done

ct_exit
