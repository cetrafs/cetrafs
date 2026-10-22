#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mount, root inode, procfs, node registration, first ZG claim
#
# The mount path end to end on a freshly mkfs'd volume: the superblock
# validation gate, the root inode exactly as mkfs wrote it, all three
# /proc/fs/cetrafs/<dev>/ files, this node claiming a Node Registry row
# (and re-attaching to the SAME row on remount rather than burning a new
# one), and the first ZG claim. Ends by checking the procfs directory is
# removed again on umount.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
# The harness marks dmesg when it loads the module; the assertions below
# slice from that same point.
DMESG_MARK="$CT_DMESG_MARK"

# The standard small volume: 1 ZG, one 512 MiB BG, no journal, 1024 inodes.
IMG="$(ct_image 560 main)"
LOOPDEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt main)"
ct_mkfs_small "$LOOPDEV" >/dev/null
ct_track mnt "$MNT"   # so an abort mid-suite still unmounts

log "mounting"
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

# --- assertions ----------------------------------------------------------

if mountpoint -q "$MNT"; then
    pass "mount succeeded"
else
    fail "mount did not take effect"
fi

# Checked HERE, immediately after the mount that ran it: this suite emits
# enough debug output to wrap the dmesg ring buffer within a few sections,
# so a later scan can miss the line entirely (seen for real).
if dmesg_since "$DMESG_MARK" | grep -q 'CAS selftest: PASSED'; then
    pass "CAS: cetrafs_cas_record() round-trip passed (no-CAW fallback path)"
else
    fail "CAS: selftest did not pass: $(dmesg_since "$DMESG_MARK" | grep -i 'CAS selftest')"
fi

MODE="$(stat -c '%a' "$MNT")"
[ "$MODE" = "755" ] && pass "root mode is 0755 (matches what mkfs wrote)" ||
    fail "root mode is $MODE, expected 755"

TYPE="$(stat -c '%F' "$MNT")"
[ "$TYPE" = "directory" ] && pass "root reports as a directory" ||
    fail "root reports as '$TYPE', expected directory"

NLINK="$(stat -c '%h' "$MNT")"
[ "$NLINK" = "2" ] && pass "root nlink is 2 (matches what mkfs wrote)" ||
    fail "root nlink is $NLINK, expected 2"

LS_OUT="$(ls -a "$MNT" | sort)"
EXPECTED="$(printf '.\n..\n' | sort)"
[ "$LS_OUT" = "$EXPECTED" ] && pass "ls shows exactly '.' and '..' read from disk" ||
    fail "ls shows unexpected entries: $LS_OUT"

if stat "$MNT/." >/dev/null 2>&1 && stat "$MNT/.." >/dev/null 2>&1; then
    pass "lookup resolves '.' and '..'"
else
    fail "lookup failed to resolve '.' or '..'"
fi

if stat "$MNT/this-does-not-exist" >/dev/null 2>&1; then
    fail "lookup of a nonexistent name unexpectedly succeeded"
else
    pass "lookup of a nonexistent name correctly fails (negative dentry)"
fi

ALLOC_LOG="$(dmesg_since "$DMESG_MARK")"

log "checking /proc/fs/cetrafs/<device>/ introspection"
PROC_DEV="$(basename "$LOOPDEV")"
PROC_DIR="/proc/fs/cetrafs/$PROC_DEV"

if [ -d "$PROC_DIR" ]; then
    pass "proc: /proc/fs/cetrafs/$PROC_DEV/ exists while mounted"
else
    fail "proc: /proc/fs/cetrafs/$PROC_DEV/ does not exist while mounted"
fi

INFO_OUT="$(cat "$PROC_DIR/info" 2>&1)"
echo "$INFO_OUT" | grep -q '^block_size: 4096$' && pass "proc info: block_size matches" ||
    fail "proc info: block_size line missing/wrong: $INFO_OUT"
echo "$INFO_OUT" | grep -q '^this_node_id: 0$' && pass "proc info: this_node_id is 0 (the only node claiming on this harness)" ||
    fail "proc info: this_node_id line missing/wrong: $INFO_OUT"
echo "$INFO_OUT" | grep -qP '^\s+zg 0: owner=0 \(this node\)' && pass "proc info: ZG 0 reports owned by this node" ||
    fail "proc info: ZG 0 ownership line missing/wrong: $INFO_OUT"

grep -q '^fenced: no$' "/proc/fs/cetrafs/$PROC_DEV/info" &&
    pass "proc info: node reports fenced: no in normal operation" ||
    fail "proc info: missing/unexpected fenced line"

# cas_miscompares: how many compare-and-swaps the device rejected
# because the image changed underneath, each then retried against a
# fresh read. Zero here is correct and expected -- a loop device has no
# atomic CAW at all, so nothing can miscompare. What this assertion
# protects is the LINE: ctest's procsnap.go parses it to prove its
# two-node contention actually happened, and a silent format change
# would turn that proof into a permanently-zero reading nobody notices.
grep -q '^cas_miscompares: [0-9]\+$' "/proc/fs/cetrafs/$PROC_DEV/info" &&
    pass "proc info: cas_miscompares line present and numeric" ||
    fail "proc info: missing/malformed cas_miscompares line -- ctest's contention proof parses this"

# journal_replays / journal_replay_declines: the same argument as
# cas_miscompares. The LOSER of a contended replay claim returns success
# and does nothing, so the decline counter is the only evidence two
# nodes ever met over one dead node's journal area -- which is exactly
# what ctest's replay-race scenario asserts on. Zero here is correct
# (one node, nothing to contend); what is protected is the line.
for CTR in journal_replays journal_replay_declines; do
    grep -q "^$CTR: [0-9]\+$" "/proc/fs/cetrafs/$PROC_DEV/info" &&
        pass "proc info: $CTR line present and numeric" ||
        fail "proc info: missing/malformed $CTR line -- ctest's replay-race proof parses this"
done

# pending_free_appends: a foreign free appended to a peer's queue. Zero
# here is correct AND unavoidable -- the append path is unreachable on a
# single-node volume (no foreign owner to queue for), so this counter rising
# is the only confirmation the path runs at all, and ctest's dir-storm
# asserts it moved. The line is what that two-node proof parses.
grep -q '^pending_free_appends: [0-9]\+$' "/proc/fs/cetrafs/$PROC_DEV/info" &&
    pass "proc info: pending_free_appends line present and numeric" ||
    fail "proc info: missing/malformed pending_free_appends line -- ctest's foreign-free proof parses this"

# The writable controls file carries the cluster timing, which ctest
# compresses so a staleness test does not spend a minute idle.
CTRL_OUT="$(cat "$PROC_DIR/controls" 2>&1)"
echo "$CTRL_OUT" | grep -q '^hb_interval_secs: [0-9]\+$' &&
    echo "$CTRL_OUT" | grep -q '^stale_secs: [0-9]\+$' &&
    pass "proc controls: cluster timing present and numeric" ||
    fail "proc controls: missing hb_interval_secs/stale_secs -- ctest sets these: $CTRL_OUT"

PROPS_OUT="$(cat "$PROC_DIR/properties" 2>&1)"
echo "$PROPS_OUT" | grep -q '^caw: class=.* available=' &&
    pass "proc properties: CAW capability line present (loop device: $(echo "$PROPS_OUT" | grep -o 'caw: .*'))" ||
    fail "proc properties: missing caw capability line: $PROPS_OUT"
# Derived from the header, not hardcoded: a carried literal silently
# stops testing anything the day the version moves (it did -- the reset
# to 1 failed this line while the kernel was perfectly right).
WANT_VER="$(printf '0x%04x' "$(grep -oP '#define CETRAFS_VERSION\s+\K0x[0-9A-Fa-f]+' "$ROOT/include/cetrafs.h")")"
echo "$PROPS_OUT" | grep -q "^version: $WANT_VER\$" && pass "proc properties: version matches CETRAFS_VERSION ($WANT_VER)" ||
    fail "proc properties: version line missing/wrong (want $WANT_VER): $PROPS_OUT"
echo "$PROPS_OUT" | grep -q 'NODE_REGISTRY' && pass "proc properties: feature list names NODE_REGISTRY" ||
    fail "proc properties: feature list missing NODE_REGISTRY: $PROPS_OUT"
echo "$PROPS_OUT" | grep -q '^caw: .*available=no$' &&
    pass "proc properties: atomic CAW correctly reported unavailable on a loop device" ||
    fail "proc properties: caw availability line missing/wrong: $PROPS_OUT"

CLUSTER_OUT="$(cat "$PROC_DIR/cluster" 2>&1)"
echo "$CLUSTER_OUT" | grep -q '^node 0: state=REGISTERED' && pass "proc cluster: this node's row shows REGISTERED" ||
    fail "proc cluster: node 0 row missing/wrong: $CLUSTER_OUT"
echo "$CLUSTER_OUT" | grep -q '(this node)$' && pass "proc cluster: this node's own row is marked '(this node)'" ||
    fail "proc cluster: no row marked '(this node)': $CLUSTER_OUT"

log "checking node registration: first mount claims a row, remount reuses it"
CLAIM_ROW="$(echo "$ALLOC_LOG" | grep -oP 'node registration: claimed row \K[0-9]+' | head -1)"
if [ -n "$CLAIM_ROW" ]; then
    pass "node registration: first-ever mount claimed a Node Registry row ($CLAIM_ROW)"
else
    fail "node registration: no 'claimed row' line found in dmesg on first mount"
fi

log "checking ZG claiming: first mount eagerly claims the one unowned ZG"
if echo "$ALLOC_LOG" | grep -q 'ZG claim: own 1 of 1 zone group(s)'; then
    pass "ZG claim: first mount claimed the one ZG in this image"
else
    fail "ZG claim: expected 'own 1 of 1 zone group(s)' in dmesg, got: $(echo "$ALLOC_LOG" | grep 'ZG claim:')"
fi

umount "$MNT"
MOUNTED=0
DMESG_MARK2="$(dmesg_mark)"
mount -t cetrafs "$LOOPDEV" "$MNT"
MOUNTED=1

REATTACH_LOG="$(dmesg_since "$DMESG_MARK2")"
REATTACH_ROW="$(echo "$REATTACH_LOG" | grep -oP 'node registration: re-attached row \K[0-9]+' | head -1)"
if [ "$REATTACH_ROW" = "$CLAIM_ROW" ]; then
    pass "node registration: remount re-attached the same row ($REATTACH_ROW) instead of claiming a new one"
else
    fail "node registration: remount re-attached row '$REATTACH_ROW', expected '$CLAIM_ROW'"
fi

# the "own N of M" dmesg line now reports this node's total
# current ownership (re-attached + newly claimed this call), not just
# what got newly claimed in this one pass -- on remount that's still 1
# (the ZG owned from the first mount, re-attached to without claiming
# anything new), not 0. See zonegroup.c's cetrafs_zg_claim_unowned()
# comment: a node that already owns at least one ZG deliberately does
# NOT try to claim more here -- only cetrafs_alloc_pick_bg() does that,
# on demand.
if echo "$REATTACH_LOG" | grep -q 'ZG claim: own 1 of 1 zone group(s)'; then
    pass "ZG claim: remount re-attached its one already-owned ZG, claimed nothing new"
else
    fail "ZG claim: expected 'own 1 of 1 zone group(s)' on remount, got: $(echo "$REATTACH_LOG" | grep 'ZG claim:')"
fi

log "unmounting"
umount "$MNT"
MOUNTED=0
pass "umount succeeded"

if [ -d "$PROC_DIR" ]; then
    fail "proc: /proc/fs/cetrafs/$PROC_DEV/ still exists after umount"
else
    pass "proc: /proc/fs/cetrafs/$PROC_DEV/ was removed on umount"
fi

ct_exit
