#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fsck's layout and bounds checks really fire
#
# M2 added these because a checksum proves the BYTES, not the MAP: a
# correctly-checksummed superblock saying `inode_table_start = 1` makes
# every file creation overwrite a Zone Group record, and saying 0 makes
# it overwrite the superblock itself. Every region start is used
# directly as a write target, so a wrong-but-valid map is not a reading
# error, it is a formatting gun.
#
# None of those checks had a control. sb_poke is the right tool because
# it RE-CHECKSUMS after setting a field -- producing exactly the
# dangerous shape, a superblock that passes its CRC and lies about the
# layout.
#
# No module, nothing mounted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
POKE="$(ct_helper sb_poke)"

IMG="$(ct_image 560 layout)"
DEV="$(ct_loop "$IMG")"

build() { ct_mkfs "$DEV" -z 1 -b 512 -J 1 -M 4 -N 1024 -f >/dev/null; }

# <label> <expected regex> <field> <value>
expect_caught() {
    local label="$1" want="$2" field="$3" value="$4"
    build
    # Poke the LOOP DEVICE, not the backing file: mkfs (build, above)
    # wrote through the loop's block-device page cache, and a poke to the
    # backing file lands in a DIFFERENT cache -- so the flushbufs below
    # could sync mkfs's still-dirty loop pages back OVER the poke before
    # fsck read it, and the fault vanished intermittently. Poking $DEV
    # puts mkfs, the poke and fsck in one cache; the flush then just
    # guarantees a clean re-read.
    "$POKE" "$DEV" "$field" "$value" >/dev/null
    blockdev --flushbufs "$DEV"
    local out rc=0
    out="$("$ROOT/userspace/fsck.cetra" "$DEV" 2>&1)" || rc=$?
    if [ "$rc" = "0" ]; then
        fail "$label: fsck called the volume CLEAN with $field=$value"
    elif echo "$out" | grep -qE "$want"; then
        pass "$label: detected"
    else
        fail "$label: fsck failed, but not for this reason -- wanted /$want/, got: $(echo "$out" | grep -E '^(ERR|WARN)' | head -2 | tr '\n' ' ')"
    fi
}

log "a healthy volume passes first"
build
"$ROOT/userspace/fsck.cetra" "$DEV" >/dev/null 2>&1 &&
    pass "the control image is clean before anything is poked" ||
    fail "a freshly-made image is already reported corrupt"

log "a region start that would make writes land on another structure"
# These are the ones with teeth: every one of them is used directly as
# a write target, so accepting it means the filesystem formats itself.
expect_caught "inode table over the superblock"  "inode_table_start|region|overlap|layout" inode_table_start 0
expect_caught "inode table over the ZG table"    "inode_table_start|region|overlap|layout" inode_table_start 1
expect_caught "node table over the BG regions"   "node_table|region|overlap|layout"        node_table_start 1
expect_caught "inode bitmap over the SB"         "inode_bmap|region|overlap|layout"        inode_bmap_start 0
expect_caught "journal over the inode table"     "journal|region|overlap|layout"           node_journal_start 1
expect_caught "pending-free over the SB"         "pending_free|region|overlap|layout"      pending_free_start 0

log "a region that runs off the end of the device"
expect_caught "inode table past the device end"  "region|total_blocks|beyond|layout|range"  inode_table_start 99999999
expect_caught "bg_regions_start past the end"    "region|total_blocks|beyond|layout|range"  bg_regions_start 99999999

log "a count that does not fit the region holding it"
expect_caught "more inodes than the table holds" "inodes_count|bitmap|table|fit"            inodes_count 99999999
expect_caught "more node rows than the table"    "node_table_count|fit|layout"              node_table_count 99999
expect_caught "a cluster wider than the mask"    "node_table_count|64|reader"               node_table_count 65

log "the fields a reader trusts blindly"
expect_caught "wrong sb_bytes"                   "sb_bytes"                                 sb_bytes 123
expect_caught "wrong inode_size"                 "inode_size|layout"                        inode_size 99
expect_caught "root_ino out of range"            "root_ino|inode|range"                     root_ino 999999

ct_exit
