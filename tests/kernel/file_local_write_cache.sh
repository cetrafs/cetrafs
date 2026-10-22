#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# A node writing its OWN file must not throw its own cache away.
#
# file_seq gates whether a cached extent tree can be trusted: a stamp
# different from the one our cache was reconciled at means somebody
# republished the file. Our OWN writeback republishes it on every
# durability boundary -- so unless the gate can tell our publish from a
# peer's, a plain local write loop makes the node drop that file's
# extent tree AND its entire page cache about once a second, forever.
#
# Nothing fails, so dmesg stays silent; the only symptom is that I/O
# collapses into re-reading the device continuously. That shipped, and
# a VM's disk went to "I/O error" in Proxmox the moment a snapshot
# started. Every test in the suite passed, because they
# all asked whether a PEER's change was seen and none asked whether our
# own change was mistaken for one.
#
# The stamp carries the publishing node in its top 16 bits precisely so
# this is decidable without bookkeeping; file_cache_drops counts the
# times the gate decided a peer had changed the file.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_image 560 locwr)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt locwr)"
PD="$(basename "$DEV")"
ct_mkfs "$DEV" -z 1 -b 512 -J 4 -M 4 -N 1024 -f >/dev/null

drops() { sed -n 's/^file_cache_drops: //p' "/proc/fs/cetrafs/$PD/info"; }

# A write workload that publishes the file sector over and over: each
# append is fsync'd, and alloc_run_blocks=1 keeps the extents from
# merging so the tree really grows.
workload() {
    python3 - "$1" <<'PY'
import os, sys
d = sys.argv[1]
a = os.open(d + "/victim", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
b = os.open(d + "/spacer", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
for i in range(60):
    os.write(a, bytes([i % 251]) * 4096); os.fsync(a)
    os.write(b, bytes([i % 241]) * 4096); os.fsync(b)
os.close(a); os.close(b)
PY
}

mount -t cetrafs -o nofilelock "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
grep -q "file_lock: off" "/proc/fs/cetrafs/$PD/info" ||
    fail "local write cache: the mount is not in nofilelock mode, which is where this gate lives"
ct_param_set alloc_run_blocks 1
ct_param_set file_seq_ignore_owner 0

log "a purely local write workload must not drop its own cache"
D0="$(drops)"
workload "$MNT"
sync
# Reading it back is what consults the gate on the data path.
md5sum "$MNT/victim" >/dev/null
D1="$(drops)"
EXT="$(filefrag "$MNT/victim" | grep -o '[0-9]* extents' | cut -d' ' -f1)"
[ "${EXT:-0}" -gt 4 ] && pass "local write cache: the file spilled into external leaves ($EXT extents), so the tree is really in play" ||
    fail "local write cache: only ${EXT:-0} extents -- the test never exercised an external leaf"
[ "$((D1 - D0))" -eq 0 ] &&
    pass "local write cache: our own publishes dropped the cache 0 times (delta=$((D1 - D0)))" ||
    fail "local write cache: the node dropped its OWN cache $((D1 - D0)) times -- every local writeback is being read as a peer's change"

# The assertion above is satisfied by TWO independent mechanisms: the
# publisher records its own stamp, and the gate can decode who stamped
# it. The recorded value alone makes the comparison match, so the decode
# -- the part that protects a publish path which FORGOT to record, which
# is the bug that shipped -- would go untested. Disable the recording to
# test it on its own.
log "a publish path that forgets to record its stamp must still not self-invalidate"
ct_param_set file_seq_skip_note 1
D2="$(drops)"
workload "$MNT"
sync
md5sum "$MNT/victim" >/dev/null
D3="$(drops)"
[ "$((D3 - D2))" -eq 0 ] &&
    pass "local write cache: the owner decode alone held it at 0 drops (delta=$((D3 - D2)))" ||
    fail "local write cache: with recording off the node dropped its own cache $((D3 - D2)) times -- the decode is not protecting a forgetful publisher"

# ------------------------------------------------- negative control
# Both mechanisms off: this is the build that shipped, and it must fail
# the assertions above. Without this the whole suite would pass against
# a gate that never fires at all.
log "negative control: with BOTH off, the same workload must drop its own cache"
ct_param_set file_seq_ignore_owner 1
D4="$(drops)"
workload "$MNT"
sync
md5sum "$MNT/victim" >/dev/null
D5="$(drops)"
ct_param_set file_seq_ignore_owner 0
ct_param_set file_seq_skip_note 0
[ "$((D5 - D4))" -gt 0 ] &&
    pass "local write cache: negative control reproduced the self-invalidation (delta=$((D5 - D4)))" ||
    fail "local write cache: negative control dropped nothing -- every assertion above proves nothing"

# ----------------------------------------- the cold path must END
# A drop puts the inode on the forced-fresh path, which is a device
# round trip per tree read. That is correct but it has to be a brief
# window: when it was cleared only by the next open(), a running VM --
# which never reopens its disk -- stayed there for its whole life, at
# 28068 forced-fresh reads to 229 cached in five seconds while plain dd
# to the same filesystem ran at 600 MB/s. Every drop must be followed by
# a reconcile.
log "every cache drop must be reconciled, not left pinned to the slow path"
recon() { sed -n 's/^file_cache_reconciles: //p' "/proc/fs/cetrafs/$PD/info"; }
ct_param_set file_seq_ignore_owner 1
workload "$MNT"; sync; md5sum "$MNT/victim" >/dev/null
ct_param_set file_seq_ignore_owner 0
D="$(drops)"
for _ in $(seq 1 30); do [ "$(recon)" -ge "$D" ] && break; sleep 1; done
R="$(recon)"
ct_umount "$MNT"
[ "$R" -ge "$D" ] &&
    pass "local write cache: every drop was reconciled (drops=$D reconciles=$R)" ||
    fail "local write cache: $((D - R)) inode(s) left cold -- they stay on a device round trip per tree read"

ct_exit
