#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a corrupt Node Registry row / Zone Group record is reported and CONTAINED
#
# inode_record_io.sh proves the inode-record reader refuses a bad
# checksum instead of serving the bytes. The other two checksummed-record
# readers -- node.c's row reader and zonegroup.c's ZG reader -- had no
# such test at all, and both are read constantly at runtime (every
# staleness decision, every cluster view, every claim scan). Two
# properties per reader:
#
#  * a record whose checksum persistently fails is REPORTED (the cluster
#    view prints the row as unreadable, the info view prints the ZG as
#    unavailable), never served as plausible bytes;
#  * it is CONTAINED: one bad row must not take down the whole procfs
#    file, the other rows, or the mount's ability to do work.
#
# The restore controls at the end of each half are the discrimination
# argument: only the checksum is ever touched, so a kernel that stopped
# verifying checksums would keep printing the row normally and fail the
# "unreadable"/"unavailable" assertion -- while the restored row reading
# back proves the poke broke nothing but the checksum.
#
# Pokes go to the LOOP DEVICE (not the backing file), the same pattern as
# fence_lease.sh: the helper's write and the kernel's forced-fresh read
# then share one bdev cache, so no flush dance is needed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NPOKE="$(ct_helper node_poke)"
ZPOKE="$(ct_helper zg_poke)"

DEV="$(ct_dev 1200 crc)"
MNT="$(ct_mnt crc)"
# Two Zone Groups, so there is an UNOWNED one to corrupt: this node
# claims exactly one at mount, and corrupting a ZG it owns would be
# testing a different (self-inflicted) failure than a peer's torn record.
ct_mkfs "$DEV" -z 2 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
PROC="/proc/fs/cetrafs/$(basename "$DEV")"

log "a corrupt peer Node Registry row is reported per-row, not served"
# Fabricate a live REGISTERED peer on row 5 -- AFTER the mount, or the
# no-CAW mount gate would (correctly) wait out its liveness window
# before admitting us, which mount_gate_no_caw.sh already covers.
NOW="$(date +%s)"
"$NPOKE" "$DEV" 5 1 aa "$NOW" >/dev/null
grep -q "^node 5: state=REGISTERED" "$PROC/cluster" &&
    pass "control: the fabricated peer row reads back as REGISTERED" ||
    fail "the fabricated row never became visible: $(grep '^node 5' "$PROC/cluster" || echo '<absent>')"

"$NPOKE" "$DEV" 5 --badsum >/dev/null
grep -q "^node 5: unreadable" "$PROC/cluster" &&
    pass "a checksum-corrupt row is reported unreadable, not served" ||
    fail "corrupt row 5 was served as if valid: $(grep '^node 5' "$PROC/cluster" || echo '<absent>')"
grep -q "(this node)" "$PROC/cluster" &&
    pass "containment: this node's own row still prints" ||
    fail "one corrupt row made the whole cluster view unusable"
echo probe-1 >"$MNT/alive" && [ "$(cat "$MNT/alive")" = "probe-1" ] &&
    pass "containment: the mount still does real work" ||
    fail "a corrupt peer row blocked unrelated work"

# Restore control: rewrite the row (any write mode restamps a correct
# checksum) and it must read again -- the poke broke only the checksum.
"$NPOKE" "$DEV" 5 1 aa "$NOW" >/dev/null
grep -q "^node 5: state=REGISTERED" "$PROC/cluster" &&
    pass "control: the restored row reads normally again" ||
    fail "row 5 did not recover after the checksum was restored"

log "a corrupt unowned Zone Group record is reported per-row, not served"
grep -q "zg 1: owner=none" "$PROC/info" &&
    pass "control: ZG 1 reads back, unowned" ||
    fail "ZG 1 is not in the expected state: $(grep 'zg 1' "$PROC/info" || echo '<absent>')"

"$ZPOKE" "$DEV" 1 badsum >/dev/null
grep -q "zg 1: unavailable" "$PROC/info" &&
    pass "a checksum-corrupt ZG is reported unavailable, not served" ||
    fail "corrupt ZG 1 was served as if valid: $(grep 'zg 1' "$PROC/info" || echo '<absent>')"
grep -q "zg 0: owner=" "$PROC/info" &&
    pass "containment: the owned ZG still prints" ||
    fail "one corrupt ZG made the whole info view unusable"
echo probe-2 >"$MNT/alive2" && [ "$(cat "$MNT/alive2")" = "probe-2" ] &&
    pass "containment: allocation from the owned ZG still works" ||
    fail "a corrupt unowned ZG blocked allocation from the owned one"

"$ZPOKE" "$DEV" 1 65535 >/dev/null # owner = NONE, restamps the checksum
grep -q "zg 1: owner=none" "$PROC/info" &&
    pass "control: the restored ZG reads normally again" ||
    fail "ZG 1 did not recover after the checksum was restored"

# The fabricated peer must not look live (or corrupt) to fsck below: park
# the row FREE, whose checksum is by design never checked.
"$NPOKE" "$DEV" 5 0 00 0 >/dev/null

ct_umount "$MNT"
FSCK_OUT="$(ct_fsck "$DEV" 2>&1)" && pass "fsck clean afterwards" ||
    fail "fsck: $(printf '%s\n' "$FSCK_OUT" | grep -iE 'err|warn' | head -3)"
ct_exit
