#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mkfs gives every volume its own UUID
#
# The superblock has a 16-byte UUID that identifies the volume, and mkfs
# never wrote it: every volume read as the all-zero UUID, so nothing could
# tell two volumes apart by it (audit 2026-11-14 U11).
#
# The suite formats two volumes and reads their UUIDs back through
# sb_poke. Each must be a version-4 UUID (the variant and version bits
# set as RFC 4122 requires) that is not all zeros, and the two must differ.
#
# DISCRIMINATION (measured on the unfixed code): both read
# 00000000000000000000000000000000.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
SBPOKE="$(ct_helper sb_poke)"

# Formats a fresh volume and sets UUID_OUT to its UUID (no subshell: the
# loop device is tracked for cleanup by this shell).
format_and_read() {
    local img dev
    img="$(ct_image 560 "uuid-$1")"
    dev="$(ct_loop "$img")"
    ct_mkfs "$dev" -z 1 -b 512 -J 0 -N 1024 -f >/dev/null
    UUID_OUT="$("$SBPOKE" "$dev" | sed -n 's/^uuid=//p')"
    losetup -d "$dev"
}

format_and_read a
A="$UUID_OUT"
format_and_read b
B="$UUID_OUT"
log "uuid A: $A"
log "uuid B: $B"

case "$A" in *[1-9a-f]*) pass "the volume carries a UUID, not all zeros" ;;
    *) fail "the volume's UUID is all zeros ($A)" ;; esac
[[ "$A" =~ ^.{12}4.{3}[89ab].{15}$ ]] && pass "and it is a version-4 UUID" ||
    fail "the UUID is not version 4 ($A)"
[ "$A" != "$B" ] && pass "two volumes formatted apart carry different UUIDs" ||
    fail "two volumes carry the same UUID ($A)"
ct_exit
