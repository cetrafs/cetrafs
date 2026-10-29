#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# growfs names the nodes whose module cannot mount what it is about to make
#
# Growing stamps the volume CETRAFS_VERSION, and a module that predates
# the grow feature REFUSES that volume -- deliberately, because it would
# otherwise call a healthy grown volume damaged. So growing strands any
# node still on an older module, and the operator needs to know WHICH
# before committing to a one-way door.
#
# cetrafs_node_entry_t.caps is the evidence: each node writes the
# capabilities its own module advertises when it registers, so a row
# reading 0 was written by a build that predates them. growfs reports
# every REGISTERED row, not just heartbeating ones -- the node that
# matters here is the one that is merely unmounted and coming back.
#
# Discrimination: the same volume, with row 0's caps cleared, must flip
# the verdict. Without that this suite would pass on any output at all.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

IMG="$(ct_big_image 1800 gwcaps)"
DEV="$(ct_loop "$IMG")"
MNT="$(ct_mnt gwcaps)"

ct_mkfs "$DEV" -s 600M -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
ct_umount "$MNT" # registers row 0 with this build's capabilities

OUT="$("$ROOT/userspace/growfs.cetra" "$DEV" -n 2>&1)"
grep -q "NOTICE -- growing stamps this volume format" <<<"$OUT" &&
    pass "growfs warns that growing requires a newer module cluster-wide" ||
    fail "growfs printed no upgrade notice"
grep -qE "row 0 .*ready \(module understands" <<<"$OUT" &&
    pass "a node running this build is reported ready" ||
    fail "this build's own node was not reported ready: $(grep -m1 'row 0' <<<"$OUT")"
grep -q "loaded module:" <<<"$OUT" &&
    pass "and it reports the module loaded on this machine" ||
    fail "growfs did not report the local module"

# ---------------- the control: a node whose module predates the grow
log "clearing row 0's advertised capabilities -- a node still on an older module"
python3 - "$IMG" <<'PY'
import struct, sys
# node_table_start is a superblock field; caps sits at a fixed offset in
# the 128-byte row. Both come from include/cetrafs.h, not from guessing.
f = open(sys.argv[1], "r+b")
sb = f.read(4096)
nts = struct.unpack_from("<Q", sb, 0x78)[0]   # offsetof(superblock, node_table_start)
CAPS = 92
f.seek(nts * 4096 + CAPS)
f.write(struct.pack("<I", 0))
f.close()
PY
OUT2="$("$ROOT/userspace/growfs.cetra" "$DEV" -n 2>&1)"
grep -q "NOT READY" <<<"$OUT2" &&
    pass "a node whose module predates the grow is named as NOT READY" ||
    fail "growfs still called an old-module node ready -- the caps check is not what decides"
grep -q "will NOT mount this volume after the grow" <<<"$OUT2" &&
    pass "and the count of stranded nodes is reported" ||
    fail "no stranded-node summary"

ct_exit
