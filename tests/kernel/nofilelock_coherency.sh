#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# nofilelock reads file metadata FRESH only while a PEER also has the file
# open (a migration handoff); a sole opener reads CACHED (fast).
#
# The first nofilelock coherency fix read metadata fresh ALWAYS, which turned
# a VM's every block I/O into a device read of the extent tree (an 18 MB/s
# read storm under a pure write workload). The real requirement is narrower:
# a stale cached map only corrupts when a PEER is changing the file, i.e.
# during the brief window both nodes have it open. So freshness is gated on
# cross-node open-presence (read_open_nodes): sole opener -> cached/fast;
# peer present -> fresh/correct.
#
# Both paths are exercised by holding ONE O_DIRECT fd across a peer's
# extent-map poke (qemu's situation -- no re-open, so no d_revalidate refresh
# to mask it). The peer's PRESENCE itself can't be simulated on the loop
# harness -- poking a foreign bit into read_open_nodes is overwritten by this
# node's own open publishing its bit, and detecting a real live foreign
# opener is covered by read_presence.sh -- so CASE B forces the verdict with
# a test-only knob (force_foreign_opener), the nocaw_force_live_peer pattern.
# The two cases discriminate opposite regressions: revert to always-fresh and
# CASE A fails; make nofilelock ignore a present peer's change and CASE B fails.
#
# Since audit 2026-11-15 B-12 a node with the file open trusts its map
# between CHANGE STAMPS (rule 10), as a reader does, so CASE B's peer
# publishes its file_seq the way every real peer's tree change does; a
# poke that publishes nothing is a change no peer makes. CASE C is B's
# control: the same change without the stamp is not seen, so B passes
# because of the stamp and the map is not re-read per I/O.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

POKE="$(ct_helper leaf_poke)"
LPOKE="$(ct_helper inode_lock_poke)"
EXTENT_POKE="$(ct_helper pending_poke)"
PROBE="$(ct_helper odirect_probe)"

IMG="$(mktemp /tmp/cetrafs-nflc-XXXXXX.img)"
truncate -s 560M "$IMG"
DEV="$(losetup --find --show "$IMG")"
MNT="$(mktemp -d /tmp/cetrafs-nflc-mnt-XXXXXX)"
PROC_DEV="$(basename "$DEV")"
"$ROOT/userspace/mkfs.cetra" "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null

# Build a depth-1 (spilled) file whose block 0 we can repoint at a donor,
# same technique as extent_leaf_staleness.sh. $1 = filename.
DONOR_PHYS=""
build_victim() {
    local name="$1" i
    for i in 0 1 2 3 4; do
        printf 'VICTIM%04d' "$i" | dd of="$MNT/$name" bs=4096 seek="$i" count=1 conv=notrunc 2>/dev/null
        [ "$i" -lt 4 ] && printf x >"$MNT/${name}_f$i"
    done
    sync "$MNT/$name"
}

# Hold an O_DIRECT fd on $1, repoint its block 0 at the donor (poking the
# BACKING FILE, which forced-fresh reads see but cached reads do not) while
# the fd stays open; report the two reads via PROBE_READ1/PROBE_READ2.
# $2 = 1: the peer also publishes its change stamp (file_seq), as every
# real peer's tree change does (CLAUDE.md rule 10). A reader -- and, since
# audit 2026-11-15 B-12, a node with the file open for write -- trusts its
# cached map between stamps, so a poke that publishes nothing is a change
# no real peer makes.
probe_once() {
    local file="$1" stamp="${2:-0}" ino ready go out pid i
    ino="$(stat -c '%i' "$MNT/$file")"
    ready="$(mktemp -u /tmp/cetrafs-nflc-ready-XXXXXX)"
    go="$(mktemp -u /tmp/cetrafs-nflc-go-XXXXXX)"
    out="$(mktemp /tmp/cetrafs-nflc-out-XXXXXX)"
    "$PROBE" "$MNT/$file" "$ready" "$go" >"$out" 2>&1 &
    pid=$!
    for i in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.1; done
    "$POKE" "$IMG" setphys "$ino" 0 "$DONOR_PHYS" >/dev/null
    if [ "$stamp" = 1 ]; then
        "$LPOKE" "$IMG" --peer-size "$ino" "$(stat -c %s "$MNT/$file")" 1 >/dev/null
    fi
    : >"$go"
    wait "$pid" 2>/dev/null || true
    PROBE_READ1="$(sed -n 's/^read1 //p' "$out")"
    PROBE_READ2="$(sed -n 's/^read2 //p' "$out")"
    rm -f "$ready" "$go" "$out"
}

mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
grep -q '^file_lock: off$' "/proc/fs/cetrafs/$PROC_DEV/info" \
    && pass "nofilelock mount: procfs reports file_lock: off" || fail "procfs did not report file_lock off"

printf 'DONORDONOR' >"$MNT/donor"
sync "$MNT/donor"
DONOR_PHYS="$("$EXTENT_POKE" "$IMG" extent "$(stat -c '%i' "$MNT/donor")" | cut -d' ' -f1)"

log "CASE A -- SOLE opener: metadata stays CACHED, a peer's poke is NOT seen (the perf fix)"
ct_param_set force_foreign_opener 0
build_victim victimA
probe_once victimA
[ "$PROBE_READ1" = "VICTIM0000" ] || fail "setup: first read was '$PROBE_READ1', expected VICTIM0000"
if [ "$PROBE_READ2" = "VICTIM0000" ]; then
    pass "sole opener kept its cached extent map (poke not seen) -- no per-I/O device read"
else
    fail "sole opener read '$PROBE_READ2' -- it re-read the map fresh though no peer is present (the slowdown is back)"
fi

log "CASE B -- a PEER also has it open: metadata is read FRESH, the poke IS seen (correctness)"
ct_param_set force_foreign_opener 1
build_victim victimB
probe_once victimB 1
[ "$PROBE_READ1" = "VICTIM0000" ] || fail "setup B: first read was '$PROBE_READ1', expected VICTIM0000"
if [ "$PROBE_READ2" = "DONORDONOR" ]; then
    pass "peer present: the held open re-mapped block 0 fresh and read the donor's content"
else
    fail "peer present: read '$PROBE_READ2' through a STALE cached map, expected DONORDONOR (handoff coherency broken)"
fi
ct_param_set force_foreign_opener 0

log "CASE C -- control for B: the same peer change WITHOUT its stamp is not seen"
# What makes B pass is the stamp, not the presence alone: a node with the
# file open trusts its map between stamps (B-12). Seen here, the held
# open would be re-reading the map per I/O again.
ct_param_set force_foreign_opener 1
build_victim victimC
probe_once victimC 0
if [ "$PROBE_READ2" = "VICTIM0000" ]; then
    pass "control: with no stamp published the held open kept its map -- B is seen through the stamp"
else
    fail "control: '$PROBE_READ2' read with no stamp published -- the map is re-read per I/O, or B passes for another reason"
fi
ct_param_set force_foreign_opener 0

umount "$MNT"
losetup -d "$DEV"
rmdir "$MNT"
rm -f "$IMG" "$POKE" "$EXTENT_POKE" "$PROBE"

ct_exit
