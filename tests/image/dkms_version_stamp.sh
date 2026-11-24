#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# a module built from the packaged DKMS source names its release
#
# The module's version stamp (/sys/module/cetrafs/version, modinfo) came
# from `git describe`, and the DKMS source a package installs under
# /usr/src/cetrafs-<ver> has no git: every packaged module reported
# "unknown+src.<hash>", the release nowhere in it. debian/rules now writes
# the changelog's version into the packaged kmod/VERSION, and the module's
# Makefile reads it when there is no git to describe.
#
# The packaged tree is rebuilt here the way debian/rules does it -- kmod
# and include copied out of git, VERSION written by the rule's own
# command line -- and the Makefile asked for the stamp it would build:
#   1. it starts with the changelog's version and keeps the "+src." hash;
#   2. the hash is the one the checkout's own build carries: VERSION is
#      not part of the source ctest compares.
#
# DISCRIMINATION: the same tree without kmod/VERSION reads "unknown+src.".
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
VER="$(cd "$ROOT" && dpkg-parsechangelog -SVersion 2>/dev/null)" || { skip "dpkg-parsechangelog is missing"; ct_exit; }
RULE="$(grep -E "^[[:space:]]+echo '\\\$\(VERSION\)' > debian/cetrafs-dkms/usr/src/cetrafs-\\\$\(VERSION\)/kmod/VERSION" "$ROOT/debian/rules" || true)"
[ -n "$RULE" ] && pass "setup: debian/rules writes the version into the packaged kmod/VERSION" ||
    { fail "setup: debian/rules does not write kmod/VERSION"; ct_exit; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cp -a "$ROOT/kmod" "$ROOT/include" "$T/"
find "$T/kmod" \( -name '*.o' -o -name '*.ko' -o -name '.*.cmd' -o -name '*.mod' -o -name '*.mod.c' \) -delete
git -C "$T/kmod" rev-parse 2>/dev/null && { fail "setup: the copy is inside a git tree"; ct_exit; }

# The rule's own command line, run as make would run it.
D="$T/pkg"
mkdir -p "$D/debian/cetrafs-dkms/usr/src/cetrafs-$VER"
mv "$T/kmod" "$T/include" "$D/debian/cetrafs-dkms/usr/src/cetrafs-$VER/"
# make expands $(VERSION) before the shell runs the line; so does this.
(cd "$D" && sh -c "${RULE//\$(VERSION)/$VER}")
K="$D/debian/cetrafs-dkms/usr/src/cetrafs-$VER/kmod"
pkg="$(make -s -C "$K" print-version)"
own="$(make -s -C "$ROOT/kmod" print-version)"
rm -f "$K/VERSION"
bare="$(make -s -C "$K" print-version)"
log "packaged: $pkg; checkout: $own; without VERSION: $bare"

case "$pkg" in "$VER+src."*) pass "1: the packaged source stamps the release ($pkg)" ;;
    *) fail "1: the packaged source stamps $pkg, not $VER+src.*" ;; esac
[ "${pkg#*+src.}" = "${own#*+src.}" ] && pass "2: the source hash is the checkout's (${pkg#*+src.})" ||
    fail "2: the source hash differs: ${pkg#*+src.} vs ${own#*+src.}"
case "$bare" in "unknown+src."*) pass "control: without kmod/VERSION it is \"unknown\" ($bare)" ;;
    *) fail "control: without kmod/VERSION the stamp reads $bare -- the check proves nothing" ;; esac
ct_exit
