#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# rename retries when a peer changes the destination under it
#
# Found by ctest's concurrent-rename on real two-node hardware: a and b
# each renamed a different source onto the same brand-new name at the
# same instant. a won; b failed with EBUSY and its source was left in
# place. EBUSY is not an outcome rename(2) is allowed to have -- POSIX
# requires a rename over an existing name to succeed, and nothing in
# userspace handles EBUSY from one.
#
# The destination has to be in the namespace lock set (its nlink is
# mutated, its blocks may be freed), so it must be identified BEFORE the
# locks are taken -- lock-free, and therefore possibly stale. The
# re-check under the locks was right to refuse to proceed on a stale
# answer; it was wrong to surface that as the syscall's result. It now
# re-discovers and tries again.
#
# A single kernel cannot produce the race: the VFS holds both parents'
# inode locks across rename and resolves the destination itself. The
# test-only `rename_force_retry` param is therefore the SOLE route to
# the retry path -- without it these assertions would pass against a
# build that never retries at all.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

PARAM=/sys/module/cetrafs/parameters/rename_force_retry
[ -w "$PARAM" ] || fail "rename_force_retry param is missing -- the retry path has no test route"
# ct_param_set, not a hand-rolled trap: a `trap ... EXIT` in a suite
# REPLACES the harness's own cleanup trap, so its loop devices and
# mounts would never be torn down, and it restores after ct_exit has
# already checked. The setter restores inside ct_exit, before the check.
force() { ct_param_set rename_force_retry "$1"; }

IMG="$(ct_image 560 renrace)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt renrace)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mk() { printf '%s' "$2" >"$MNT/$1"; }

log "control: an ordinary rename over an existing name still works"
force 0
mk src "SOURCE"; mk dst "DEST"
mv "$MNT/src" "$MNT/dst" && pass "a plain replacing rename succeeds" || fail "a plain rename failed"
[ ! -e "$MNT/src" ] && pass "the source name is gone" || fail "the source name survived"
[ "$(cat "$MNT/dst")" = "SOURCE" ] && pass "the destination holds the source's content" ||
    fail "the destination holds $(cat "$MNT/dst")"

log "one lost race: the rename must still SUCCEED, not report EBUSY"
# This is the assertion the real bug fails. With the retry removed the
# mv below exits nonzero with "Device or resource busy" -- exactly what
# node b saw on the two-node run.
mk s1 "ONE"; mk d1 "OLD1"
force 1
if OUT="$(mv "$MNT/s1" "$MNT/d1" 2>&1)"; then
    pass "a rename whose destination changed under it succeeds on the retry"
else
    fail "the rename failed instead of retrying: $OUT"
fi
force 0
[ ! -e "$MNT/s1" ] && pass "...and its source name is gone (the rename really happened)" ||
    fail "the source name survived a 'successful' rename"
[ "$(cat "$MNT/d1")" = "ONE" ] && pass "...and the destination holds the source's content" ||
    fail "the destination holds $(cat "$MNT/d1")"

log "a rename ONTO A NEW NAME loses the same race (ctest's exact shape)"
# b's destination did not pre-exist: it locked for "no target" and then
# found a's target under the lock. Same code path, different starting
# point, and the one the hardware actually hit.
mk s2 "TWO"
force 1
if OUT="$(mv "$MNT/s2" "$MNT/d2" 2>&1)"; then
    pass "a rename onto a previously-absent name succeeds on the retry"
else
    fail "the rename failed instead of retrying: $OUT"
fi
force 0
[ "$(cat "$MNT/d2")" = "TWO" ] && pass "...with the right content at the new name" ||
    fail "d2 holds $(cat "$MNT/d2")"

log "several lost races in a row are still absorbed"
mk s3 "THREE"; mk d3 "OLD3"
force 3
mv "$MNT/s3" "$MNT/d3" 2>/dev/null && pass "3 consecutive lost races still end in a successful rename" ||
    fail "the rename gave up before its attempt budget was spent"
force 0
[ "$(cat "$MNT/d3")" = "THREE" ] && pass "...and the content is correct" || fail "d3 holds $(cat "$MNT/d3")"

log "an exhausted budget fails loudly AND changes nothing"
# Giving up is correct for a genuine livelock. What must not happen is a
# half-done rename -- the source must still be there and the
# destination untouched, or the loud failure is worse than the silent
# one it replaced.
mk s4 "FOUR"; mk d4 "OLD4"
MARK="$(dmesg_mark)"   # timestamp-based: a line count breaks when the ring buffer wraps
force 99
if mv "$MNT/s4" "$MNT/d4" 2>/dev/null; then
    fail "the rename succeeded despite every attempt losing the race"
else
    pass "a rename that loses every attempt fails rather than looping forever"
fi
force 0
[ -e "$MNT/s4" ] && pass "...the source is left intact" || fail "the source was removed by a failed rename"
[ "$(cat "$MNT/s4")" = "FOUR" ] && pass "...with its content unchanged" || fail "the source's content changed"
[ "$(cat "$MNT/d4")" = "OLD4" ] && pass "...and the destination is untouched" ||
    fail "the destination now holds $(cat "$MNT/d4")"
dmesg_since "$MARK" | grep -q "giving up" &&
    pass "...and the give-up is logged, not silent" || fail "nothing was logged when the rename gave up"

log "the filesystem is still healthy afterwards"
force 0
mk s5 "FIVE"
mv "$MNT/s5" "$MNT/d5" && pass "renames work normally again once the race stops" || fail "a later rename failed"
ls "$MNT" >/dev/null && pass "the directory still reads" || fail "readdir failed"

ct_umount "$MNT"
ct_fsck "$DEV" >/dev/null 2>&1 && pass "fsck clean" ||
    fail "fsck: $(ct_fsck "$DEV" 2>&1 | grep -i err | head -3)"
ct_exit
