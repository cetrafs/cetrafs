#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a second grow that died before its publish is finished by re-running it
#
# A second (or later) grow links its new Block Group table segment from
# the old tail segment, and that link reaches the device BEFORE the
# superblock is published. A grow that dies in between leaves the old
# superblock under a chain one segment longer than it counts: mount and
# fsck refuse it, correctly. The way out is to run growfs again -- and
# that retry, computing the same segment address, rewrote the segment
# with next=0, walked the chain to it as "the tail" and linked it to
# itself: a chain that never terminates, on the one path meant to
# repair the volume.
#
# Staged with CETRAFS_GROWFS_TEST_NO_PUBLISH, which stops right before
# the publish. Round A retries with the same size, round B with a
# bigger one (a different segment address).
#
# DISCRIMINATION: with the tail found as "the segment whose next is 0",
# round A's retry links its segment to itself (fsck meets it twice:
# "starts at id 2, expected 4") and round B's retry dies on the stale
# link, whose target its own new Block Groups have overwritten.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_big_dev 3000 growretry)"
MNT="$(ct_mnt growretry)"
ct_track mnt "$MNT"

round() {
    local tag="$1" retry="$2" out
    ct_mkfs "$DEV" -s 700M -b 512 -z 2 -J 0 -N 1024 -f >/dev/null
    ct_growfs "$DEV" -s 1400M >/dev/null 2>&1 || { fail "$tag: setup: the first grow failed"; return; }
    CETRAFS_GROWFS_TEST_NO_PUBLISH=1 ct_growfs "$DEV" -s 2100M >/dev/null 2>&1 || true
    out="$(ct_fsck "$DEV" 2>&1 || true)"
    grep -q 'grow was interrupted' <<<"$out" ||
        { fail "$tag: setup: the interrupted second grow did not leave its link ($(grep -m1 ERR <<<"$out"))"; return; }
    pass "$tag: setup: a second grow died after linking, before publishing; fsck says so"

    local mark; mark="$(dmesg_mark)"
    if mount -t cetrafs "$DEV" "$MNT" 2>/dev/null; then
        ct_umount "$MNT"; fail "$tag: the half-grown volume mounted"
    else
        dmesg_since "$mark" | grep -q 'grow was interrupted' &&
            pass "$tag: the mount refuses it and says how to finish" ||
            fail "$tag: the mount refused without naming the interrupted grow"
    fi

    out="$(ct_growfs "$DEV" -s "$retry" 2>&1)" || { fail "$tag: the retry failed: $(tail -1 <<<"$out")"; return; }
    out="$(ct_fsck "$DEV" 2>&1)" && pass "$tag: after re-running growfs (-s $retry) fsck is clean" ||
        { fail "$tag: after the retry fsck reports $(grep -m1 ERR <<<"$out")"; return; }
    ct_mount "$DEV" "$MNT" && { pass "$tag: and it mounts"; echo x >"$MNT/f"; ct_umount "$MNT"; } ||
        fail "$tag: the finished grow does not mount"
}

round A 2100M
round B 2800M
ct_exit
