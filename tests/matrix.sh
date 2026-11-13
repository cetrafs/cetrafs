#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# tests/matrix.sh -- run a slice of the kernel suites under each mount-option and mkfs-geometry configuration
#
#   tests/matrix.sh                  every configuration, the default slice
#   tests/matrix.sh nofilelock bg1g  named configurations only
#   MATRIX_SUITES="kernel/a.sh kernel/b.sh" tests/matrix.sh zg4
#
# Configurations (each is a set of harness overrides, see tests/README.md):
#   base        the geometry and options the gate itself uses
#   nofilelock  -o nofilelock on every ct_mount: the lock-free cluster mode
#   bg1g        -b 1024 (1 GiB Block Groups) on images of at least 2300 MiB,
#               so the volume holds two Block Groups and BG-boundary
#               arithmetic is exercised
#   zg4         -z 4 on images of at least 2300 MiB: four Zone Groups over
#               four Block Groups, one each
#   journal8    -J 8 (an 8 MiB journal per node slot) on images of at least
#               2300 MiB: the slots reserve ~512 MiB, which the suites'
#               560 MiB images cannot hold
#
# The slice is deliberately small: a configuration exists to show that the
# suites which mean something under it still pass there, not to re-run the
# gate. Under nofilelock the slice is the mode-neutral subset (see
# NOFILELOCK_SUITES below for the two suites that are not). Each configuration's run log goes to $CT_MATRIX_DIR (default
# ${CT_BIG_DIR:-/root}/cetrafs-matrix), not /tmp: the logs are large and
# the images are disk-backed. Exit 1 if any configuration fails a suite.
#
# Needs root and a loaded or loadable module, like the kernel/ suites.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_CONFIGS="base nofilelock bg1g zg4 journal8"
DEFAULT_SUITES="kernel/matrix_geometry.sh kernel/fsx_model.sh kernel/fsstress_namespace.sh kernel/punch_hole.sh kernel/zero_range_inplace.sh kernel/direct_io.sh kernel/extent_tree_depth2.sh"
# nofilelock turns the cross-node file lock OFF and the defragmenter with
# it, by design. direct_io.sh asserts the lock is taken for an O_DIRECT
# open and extent_tree_depth2.sh needs defrag, so neither says anything
# about a nofilelock mount and both are left out of its slice. (Measured:
# both fail there for exactly those reasons.)
NOFILELOCK_SUITES="kernel/matrix_geometry.sh kernel/fsx_model.sh kernel/fsstress_namespace.sh kernel/punch_hole.sh kernel/zero_range_inplace.sh"
CONFIGS="${*:-$ALL_CONFIGS}"
OUT="${CT_MATRIX_DIR:-${CT_BIG_DIR:-/root}/cetrafs-matrix}"
mkdir -p "$OUT" || exit 2

# Set the harness overrides for one configuration. Everything is unset
# first so one configuration cannot leak into the next.
config_env() {
    unset CT_MOUNT_OPTS CT_MKFS_EXTRA CT_IMG_MIN_MB
    case "$1" in
    base) ;;
    nofilelock) export CT_MOUNT_OPTS=nofilelock ;;
    bg1g) export CT_MKFS_EXTRA="-b 1024" CT_IMG_MIN_MB=2300 ;;
    zg4) export CT_MKFS_EXTRA="-z 4" CT_IMG_MIN_MB=2300 ;;
    # -J is MiB per node slot, and mkfs reserves a slot for each of up to
    # 64 nodes: ~512 MiB of journal, so the 560 MiB images the suites use
    # cannot hold a Block Group at all. The floor makes room for it.
    journal8) export CT_MKFS_EXTRA="-J 8" CT_IMG_MIN_MB=2300 ;;
    *) return 1 ;;
    esac
}

# Validate every name before running anything: a typo in the last one
# must not cost the whole matrix.
for c in $CONFIGS; do
    config_env "$c" || {
        echo "matrix: unknown configuration '$c' (known: $ALL_CONFIGS)" >&2
        exit 2
    }
done

FAILED=""
for c in $CONFIGS; do
    config_env "$c"
    SUITES="${MATRIX_SUITES:-$DEFAULT_SUITES}"
    [ "$c" = nofilelock ] && [ -z "${MATRIX_SUITES:-}" ] && SUITES="$NOFILELOCK_SUITES"
    log="$OUT/$c.log"
    echo "== configuration $c: MOUNT_OPTS='${CT_MOUNT_OPTS:-}' MKFS_EXTRA='${CT_MKFS_EXTRA:-}' IMG_MIN_MB='${CT_IMG_MIN_MB:-}'"
    # shellcheck disable=SC2086
    "$HERE/run.sh" $SUITES >"$log" 2>&1
    rc=$?
    grep -E '^(kernel|image|stress|device)/|^TOTAL' "$log" | sed 's/^/     /'
    if [ "$rc" = 0 ]; then
        echo "   $c: PASS (log $log)"
    else
        echo "   $c: FAIL rc=$rc (log $log)"
        FAILED="$FAILED $c"
    fi
done

echo
if [ -n "$FAILED" ]; then
    echo "MATRIX FAILED:$FAILED"
    exit 1
fi
echo "MATRIX PASSED: $CONFIGS"
