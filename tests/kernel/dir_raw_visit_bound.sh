#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the recount's directory scan refuses an over-long directory by its count
#
# A directory never grows past CETRAFS_DIR_MAX_BLOCKS (2^18) blocks and
# every namespace scan refuses a record naming more (dir_extent_len_bound.sh).
# The recount a lock takeover runs (cetrafs_ns_reconcile() through
# cetrafs_dir_raw_visit()) has its own reader and only answered a fatal
# signal: a record naming 2^31 blocks was 2^31 forced-fresh reads under
# the namespace lock (re-audit of the 2026-11-14 fixes, rule 12).
#
# A directory's inline extent is set to 300,000 blocks (inside the data
# area, so the address check passes), and a file elsewhere has its
# namespace lock held by a node that was never registered. A link of
# that file takes the lock over and recounts its names across every
# directory -- the over-long one included, never looked up, so no other
# scan has refused it first. The recount must refuse it by its count.
#
# DISCRIMINATION: dir_len_unbounded lifts the cap; the recount then
# scans until the first unreadable block and names no count.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
[ -w /sys/module/cetrafs/parameters/dir_len_unbounded ] || { skip "dir_len_unbounded is missing"; ct_exit; }
IPOKE="$(ct_helper inode_block_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
MNT="$(ct_mnt drvb)"
ct_track mnt "$MNT"
ct_param_set dir_len_unbounded 0

# <unbounded 0|1> -> "<takeover seen yes|no> <recount refused by count yes|no>"
probe() {
    local img dev ino fino mark out
    img="$(ct_image 2048 "drvb$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -J 0 -N 1024 -f >/dev/null
    ct_mount "$dev" "$MNT"
    mkdir "$MNT/d"
    : >"$MNT/d/a"
    : >"$MNT/f"
    sync
    ino="$(stat -c %i "$MNT/d")"
    fino="$(stat -c %i "$MNT/f")"
    ct_umount "$MNT"
    "$IPOKE" "$img" extset "$ino" 0 len 300000 >/dev/null
    "$LPOKE" "$img" "$fino" --ns 1 >/dev/null
    echo "$1" >/sys/module/cetrafs/parameters/dir_len_unbounded
    ct_mount "$dev" "$MNT"
    mark="$(dmesg_mark)"
    timeout 60 ln "$MNT/f" "$MNT/g" 2>/dev/null || true
    echo 0 >/sys/module/cetrafs/parameters/dir_len_unbounded
    umount "$MNT" 2>/dev/null || umount -l "$MNT"
    out="$(dmesg_since "$mark")"
    printf '%s %s\n' "$(grep -q "breaking a namespace lock\|recount" <<<"$out" && echo yes || echo no)" \
        "$(grep -q "not scanned" <<<"$out" && echo yes || echo no)"
}
read -r T R <<<"$(probe 0)"
log "fixed: takeover $T, refused by count $R"
[ "$T" = yes ] || { fail "setup: the create did not take the lock over and recount"; ct_exit; }
[ "$R" = yes ] && pass "the recount refused the 300,000-block directory by its count" ||
    fail "the recount scanned the over-long directory instead of refusing it"
read -r T0 R0 <<<"$(probe 1)"
[ "$T0" = yes ] && [ "$R0" = no ] &&
    pass "control: with the cap lifted the recount scans it -- the suite discriminates" ||
    fail "control: takeover $T0, refused $R0 -- the suite cannot tell"
ct_exit
