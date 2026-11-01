#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a crash inside link() or rename() never leaves a file with more names than its link count
#
# link() and rename() each change two things that are durable on their
# own -- a dirent and the target's nlink -- and the journal does not
# make the pair atomic. A crash between them keeps whichever came first,
# and the two orders fail in opposite directions:
#
#  - name first (what both did): a second name under nlink=1. Unlinking
#    either name later drops nlink to 0 and frees the blocks the other
#    name still points at -- silent, and only after the fact.
#  - count first: nlink one too high. A leak fsck repairs; nothing reads
#    it as license to free.
#
# The test holds each operation between its two steps (test-only
# ns_step_gap_ms), copies the device as a crash would leave it, and asks
# fsck which way the count and the names disagree.
#
# DISCRIMINATION (measured on the unfixed code): the snapshot of link
# shows nlink=1 with two names, and the snapshot of rename the same.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 lrcrash)"
BACK="$(losetup -l -n -O BACK-FILE "$DEV")"
MNT="$(ct_mnt lrcrash)"
SNAP="$(ct_tmp)"
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"

mkdir "$MNT/a" "$MNT/b"
echo data >"$MNT/a/lnsrc_q7"
echo data >"$MNT/a/rnsrc_q7"
echo data >"$MNT/a/rpsrc_q7"
echo victim >"$MNT/b/rpdst_q7"
sync
LINO="$(stat -c %i "$MNT/a/lnsrc_q7")"
RINO="$(stat -c %i "$MNT/a/rnsrc_q7")"
PINO="$(stat -c %i "$MNT/a/rpsrc_q7")"

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
        fail "$label: the operation was not inside its gap for the whole copy -- nothing measured"
        return
    fi
    local sdev out line
    sdev="$(ct_loop "$SNAP")"
    out="$(ct_fsck "$sdev" 2>&1 || true)"
    losetup -d "$sdev" 2>/dev/null || true
    line="$(grep -E "^ERR: inode $ino has nlink=[0-9]+ but [0-9]+ directory entries name it" <<<"$out" || true)"
    if [ -z "$line" ]; then
        pass "$label: at the crash point the count and the names agree"
        return
    fi
    local n r
    n="$(sed -E 's/.*nlink=([0-9]+) but ([0-9]+).*/\1/' <<<"$line")"
    r="$(sed -E 's/.*nlink=([0-9]+) but ([0-9]+).*/\2/' <<<"$line")"
    if [ "$n" -ge "$r" ]; then
        pass "$label: at the crash point nlink=$n covers its $r name(s) -- at worst a leak"
    else
        fail "$label: a crash here leaves nlink=$n under $r names -- unlinking one frees the other's blocks"
    fi
}

crash_in_gap "link" "$LINO" ln "$MNT/a/lnsrc_q7" "$MNT/b/lndst_q7"
crash_in_gap "rename" "$RINO" mv "$MNT/a/rnsrc_q7" "$MNT/b/rndst_q7"
crash_in_gap "rename over a file" "$PINO" mv "$MNT/a/rpsrc_q7" "$MNT/b/rpdst_q7"

# And the live volume, with every operation finished: exact.
[ "$(stat -c %h "$MNT/a/lnsrc_q7")" = 2 ] && [ -e "$MNT/b/lndst_q7" ] && [ -e "$MNT/b/rndst_q7" ] &&
    [ ! -e "$MNT/a/rnsrc_q7" ] && [ "$(cat "$MNT/b/rpdst_q7")" = data ] &&
    pass "every operation completed with the expected names and counts" ||
    fail "the operations did not complete as expected"
ct_umount "$MNT"
rc=0
out="$(ct_fsck "$DEV" 2>&1)" || rc=$?
[ "$rc" = 0 ] && ! grep -q '^ERR' <<<"$out" && pass "fsck clean afterwards" ||
    fail "fsck rc=$rc: $(grep '^ERR' <<<"$out" | head -3)"

ct_exit
