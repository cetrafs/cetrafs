#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a crash inside a directory rename never leaves the directory with two names
#
# rename() of a directory adds the new name and removes the old one, two
# dirent writes each durable on its own. A crash between them kept both:
# a directory with two names, which no link count can cover the way it
# covers a file's (link_rename_crash_order.sh). rmdir through either name
# then frees the directory while the other name still points at its
# number, and the next file to take that number appears there.
#
# Now the old name goes first. The test holds each rename between its two
# writes (ns_step_gap_ms), copies the device as a crash would leave it,
# and asks fsck -- which now reports a directory named twice -- about the
# copy. The crash may leave the directory unnamed (fsck links it into
# /lost+found); it must never leave it named twice.
#
#  A. into another directory;   B. within its own directory;
#  C. over an empty directory;  D. a failed new-name write gives the old
#     name back (rename_name_fail_once).
#
# DISCRIMINATION (measured on the unfixed code): the snapshots of A, B
# and C show the directory named by 2 entries. D guards the new unwind,
# not the crash window: on the old order the failed add changed nothing,
# so D passes there as well.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
# fsck runs on crash snapshots -- copies of a mounted device -- whose
# registry row looks live and that nothing will ever beat. The tools
# watch such a row for the kernel's whole stale window (120 s), several
# times over per suite; the test knob shortens the watch to two beats.
export CETRAFS_PEER_PROBE_SECS=1
for k in ns_step_gap_ms rename_name_fail_once; do
    [ -w "/sys/module/cetrafs/parameters/$k" ] || { skip "$k is missing"; ct_exit; }
done

DEV="$(ct_dev 560 rdcrash)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt rdcrash)"
SNAP="$(ct_tmp)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir -p "$MNT/a/mv1_q7" "$MNT/b" "$MNT/a/mv2_q7" "$MNT/a/mv3_q7" "$MNT/b/empty_q7"
echo keep >"$MNT/a/mv1_q7/inside"
echo keep >"$MNT/a/mv2_q7/inside"
echo keep >"$MNT/a/mv3_q7/inside"
sync
I1="$(stat -c %i "$MNT/a/mv1_q7")"
I2="$(stat -c %i "$MNT/a/mv2_q7")"
I3="$(stat -c %i "$MNT/a/mv3_q7")"

# <label> <ino> <command...>: run it in the gap, snapshot, fsck the copy.
crash_in_gap() {
    local label="$1" ino="$2"
    shift 2
    ct_param_set ns_step_gap_ms 3000
    ("$@") &
    local op=$!
    sleep 1.5
    local alive_before=0 alive_after=0
    kill -0 "$op" 2>/dev/null && alive_before=1
    cp --sparse=always "$BACK" "$SNAP"
    kill -0 "$op" 2>/dev/null && alive_after=1
    wait "$op" || true
    ct_param_set ns_step_gap_ms 0
    if [ "$alive_before$alive_after" != 11 ]; then
        fail "$label: the rename was not inside its gap for the whole copy -- nothing measured"
        return
    fi
    local sdev out
    sdev="$(ct_loop "$SNAP")"
    out="$(ct_fsck "$sdev" 2>&1 || true)"
    losetup -d "$sdev" 2>/dev/null || true
    if grep -qE "^ERR: directory inode $ino is named by [0-9]+ directory entries" <<<"$out"; then
        fail "$label: a crash here leaves directory $ino with two names"
    else
        pass "$label: at the crash point directory $ino has at most one name"
    fi
}

crash_in_gap "A (into another directory)" "$I1" mv "$MNT/a/mv1_q7" "$MNT/b/mv1_q7"
crash_in_gap "B (within its directory)" "$I2" mv "$MNT/a/mv2_q7" "$MNT/a/mv2r_q7"
crash_in_gap "C (over an empty directory)" "$I3" mv -T "$MNT/a/mv3_q7" "$MNT/b/empty_q7"

[ -e "$MNT/b/mv1_q7/inside" ] && [ ! -e "$MNT/a/mv1_q7" ] && [ -e "$MNT/a/mv2r_q7/inside" ] &&
    [ ! -e "$MNT/a/mv2_q7" ] && [ -e "$MNT/b/empty_q7/inside" ] && [ ! -e "$MNT/a/mv3_q7" ] &&
    pass "every rename completed with the expected names" ||
    fail "the renames did not complete as expected"

# D: the new name cannot be written -- the directory keeps its old one.
mkdir "$MNT/a/mv4_q7"
echo keep >"$MNT/a/mv4_q7/inside"
ct_param_set rename_name_fail_once 1
if mv "$MNT/a/mv4_q7" "$MNT/b/mv4_q7" 2>/dev/null; then
    fail "D: the rename succeeded although its new-name write was failed"
fi
ct_param_set rename_name_fail_once 0
[ -e "$MNT/a/mv4_q7/inside" ] && [ ! -e "$MNT/b/mv4_q7" ] &&
    pass "D: a failed rename leaves the directory under its old name" ||
    fail "D: after a failed rename the directory is at old=$([ -e "$MNT/a/mv4_q7" ] && echo yes || echo no) new=$([ -e "$MNT/b/mv4_q7" ] && echo yes || echo no)"
mv "$MNT/a/mv4_q7" "$MNT/b/mv4_q7" && [ -e "$MNT/b/mv4_q7/inside" ] &&
    pass "D: and can be renamed normally afterwards" || fail "D: the directory cannot be renamed afterwards"

ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && ! grep -q '^ERR' <<<"$out" && pass "fsck clean afterwards" ||
    fail "fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -3)"
ct_exit
