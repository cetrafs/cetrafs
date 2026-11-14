#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# the userspace tools are built with the packager's CFLAGS and LDFLAGS
#
# The tools parse hostile images as root. A distribution builds packages
# with its hardening flags in CFLAGS and LDFLAGS (dpkg-buildflags:
# stack protector, RELRO, fortify, PIE), and the userspace Makefile's
# recipes named only their own flags, so none of that reached mkfs, fsck,
# defrag or growfs (audit 2026-11-14 U10).
#
# The suite asks make what it would run -- nothing is compiled -- with a
# marker in CFLAGS and LDFLAGS, and requires every tool's compile and link
# line to carry them.
#
# DISCRIMINATION (measured on the unfixed code): the marker appears in
# none of the lines.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root

OUT="$(CFLAGS='-fstack-protector-strong -DCT_FLAGS_MARK' LDFLAGS='-Wl,-z,relro,-z,now' make -n -B -C "$ROOT/userspace" 2>&1)" || true
for tool in mkfs fsck defrag growfs; do
    line="$(grep -- "-o $tool.cetra" <<<"$OUT" | head -1 || true)"
    if [ -z "$line" ]; then
        fail "$tool: make printed no build line: $(head -2 <<<"$OUT" | tr '\n' ' ')"
        continue
    fi
    case "$line" in *-DCT_FLAGS_MARK*) pass "$tool: compiled with the packager's CFLAGS" ;;
        *) fail "$tool: its compile line does not carry CFLAGS" ;; esac
    case "$line" in *"-z,now"*) pass "$tool: linked with the packager's LDFLAGS" ;;
        *) fail "$tool: its link line does not carry LDFLAGS" ;; esac
done
ct_exit
