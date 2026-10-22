#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs and fsck refuse a volume another NODE has mounted
#
# There is nothing local to see: the device is a shared LUN and the
# peer's mount is invisible except through the on-disk Node Registry, so
# both tools have to read it and find a live row. Reformatting a LUN
# another hypervisor is running VMs off is the catastrophe this prevents.
#
# Both halves are controls: a peer that has stopped heartbeating must NOT
# block either tool, and the refusal must be FOR THAT REASON -- an
# assertion that only checked for a nonzero exit would also pass on
# mkfs's unrelated "refusing to overwrite existing cetrafs" gate.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module
NODE_POKE="$(ct_helper node_poke)"

log "checking mkfs/fsck refuse a volume another NODE has mounted"
# cetrafs_device_mounted() only sees THIS system's mount table, which on
# a shared LUN misses the case that matters: a peer having the volume
# mounted right now. The peers record themselves in the Node Registry,
# so the device itself can be asked -- a REGISTERED row whose last_seen
# is inside CETRAFS_NODE_STALE_SECS is a node that is live.
PEER_IMG="$(mktemp /tmp/cetrafs-peer-XXXXXX.img)"
truncate -s 560M "$PEER_IMG"
PEER_LOOPDEV="$(losetup --find --show "$PEER_IMG")"
"$ROOT/userspace/mkfs.cetra" "$PEER_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

# No peer yet: neither tool may object, or the check is useless.
"$ROOT/userspace/mkfs.cetra" "$PEER_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>&1 &&
    pass "peer check: mkfs proceeds when no node is mounted" ||
    fail "peer check: mkfs wrongly refused a volume nobody has mounted"
"$ROOT/userspace/fsck.cetra" "$PEER_LOOPDEV" >/dev/null 2>&1 &&
    pass "peer check: fsck proceeds when no node is mounted" ||
    fail "peer check: fsck wrongly refused a volume nobody has mounted"

# A peer registered and ACTIVELY HEARTBEATING. The tools decide this by
# watching hb_seq move, not by reading a timestamp, so impersonating a
# live node means actually bumping the counter while they watch.
export CETRAFS_PEER_PROBE_SECS=4
"$NODE_POKE" "$PEER_LOOPDEV" 1 1 cc "$(date +%s)" >/dev/null
beat_peer_during_probe() {
    for _ in 1 2 3 4 5 6 7 8; do
        "$NODE_POKE" "$PEER_LOOPDEV" 1 --beat >/dev/null 2>&1 || true
        sleep 1
    done
}
beat_peer_during_probe &
BEATER=$!
# Match on WHY each tool refused, not merely that it did. mkfs has
# several ways to fail (an existing filesystem, bad geometry, a busy
# device) and every one of them would satisfy an exit-code-only
# assertion while the peer check did nothing -- which is exactly how
# ctest's own guard came to report PASS when mkfs was really stopping at
# "Refusing to overwrite existing cetrafs".
PEER_MKFS_OUT="$("$ROOT/userspace/mkfs.cetra" "$PEER_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f 2>&1 || true)"
if echo "$PEER_MKFS_OUT" | grep -q "is mounted by another node"; then
    pass "peer check: mkfs refuses a volume a live node has mounted (even with -f)"
elif echo "$PEER_MKFS_OUT" | grep -q "completed"; then
    fail "peer check: mkfs formatted a volume a live node has mounted"
else
    fail "peer check: mkfs failed, but not because of the peer: $(echo "$PEER_MKFS_OUT" | tail -1)"
fi
PEER_FSCK_OUT="$("$ROOT/userspace/fsck.cetra" "$PEER_LOOPDEV" 2>&1 || true)"
if echo "$PEER_FSCK_OUT" | grep -q "is mounted by another node"; then
    pass "peer check: fsck refuses a volume a live node has mounted"
elif echo "$PEER_FSCK_OUT" | grep -q "cetrafs fsck: OK"; then
    fail "peer check: fsck walked a volume a live node is mutating"
else
    fail "peer check: fsck failed, but not because of the peer: $(echo "$PEER_FSCK_OUT" | tail -1)"
fi
wait "$BEATER" 2>/dev/null || true

# The same row, now nobody bumping it: registered but dead. A dead node
# must not block the volume forever.
#
# Note this is the control that gives the two assertions above their
# meaning: the ONLY difference between them is whether something was
# advancing hb_seq, so a tool that just always refused (or always
# allowed) cannot pass both.
"$ROOT/userspace/fsck.cetra" "$PEER_LOOPDEV" >/dev/null 2>&1 &&
    pass "peer check: a peer that stopped heartbeating does not block fsck" ||
    fail "peer check: a dead peer blocked fsck forever"
"$ROOT/userspace/mkfs.cetra" "$PEER_LOOPDEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null 2>&1 &&
    pass "peer check: a peer that stopped heartbeating does not block mkfs" ||
    fail "peer check: a dead peer blocked mkfs forever"
unset CETRAFS_PEER_PROBE_SECS

losetup -d "$PEER_LOOPDEV"
rm -f "$PEER_IMG"


ct_exit
