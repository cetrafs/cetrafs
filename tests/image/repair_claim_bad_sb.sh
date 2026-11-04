#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a repairer never writes its registry claim where a damaged superblock points
#
# fsck -r and growfs claim a Node Registry row for their whole run, at
# node_table_start + row, and the release writes a row of zeros there.
# fsck claimed after checking only the magic; growfs after the CRC and
# the geometry it computes with. A superblock whose node_table_start was
# wrong -- with a valid checksum, so the bytes are the ones written --
# aimed the claim and its zeros at whatever block it named: on exactly
# the damaged volume fsck was run on, file data.
#
# Staged: node_table_start pointed at the inode table (the root's
# record), valid CRC. fsck -r and growfs must both refuse, and the
# inode table must be byte-for-byte what it was.
#
# DISCRIMINATION: with the claim made before the checks, fsck -r writes
# its row into the inode table (the hash changes) and growfs completes
# the grow. growfs's claim lands on a zeroed row here and its release
# writes zeros back, so for growfs the refusal is the observable.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"

field() { "$SBPOKE" "$1" | sed -n "s/^$2=//p"; }
# The whole span the misplaced registry covers: a claim can take any row.
itab_hash() { dd if="$1" bs=4096 skip="$ITAB" count="$NTB" status=none | sha256sum | cut -d' ' -f1; }

IMG="$(ct_image 600 claimsb)"
DEV="$(ct_loop "$IMG")"
ct_mkfs "$DEV" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
ITAB="$(field "$DEV" inode_table_start)"
NTB="$(field "$DEV" node_table_blocks)"
[ -n "$ITAB" ] && [ -n "$NTB" ] || { fail "setup: no inode_table_start"; ct_exit; }
"$SBPOKE" "$DEV" node_table_start "$ITAB" >/dev/null
[ "$(field "$DEV" node_table_start)" = "$ITAB" ] || { fail "setup: node_table_start was not planted"; ct_exit; }
pass "setup: node_table_start points at the inode table (block $ITAB), valid CRC"

# --- fsck -r
H0="$(itab_hash "$DEV")"
rc=0; out="$(ct_fsck_repair "$DEV" 2>&1)" || rc=$?
H1="$(itab_hash "$DEV")"
[ "$rc" != 0 ] && pass "fsck -r refused the volume (rc=$rc)" || fail "fsck -r accepted it"
[ "$H0" = "$H1" ] && pass "fsck -r wrote nothing into the inode table" ||
    fail "fsck -r wrote into the inode table -- its registry claim went where the damaged superblock pointed"

# --- growfs (needs room to grow)
losetup -d "$DEV"
truncate -s 1200M "$IMG"
DEV="$(ct_loop "$IMG")"
H0="$(itab_hash "$DEV")"
rc=0; out="$("$ROOT/userspace/growfs.cetra" "$DEV" 2>&1)" || rc=$?
H1="$(itab_hash "$DEV")"
[ "$rc" != 0 ] && pass "growfs refused the volume (rc=$rc)" || fail "growfs accepted it: $(tail -1 <<<"$out")"
[ "$H0" = "$H1" ] && pass "growfs wrote nothing into the inode table" ||
    fail "growfs wrote into the inode table -- its registry claim went where the damaged superblock pointed"
ct_exit
