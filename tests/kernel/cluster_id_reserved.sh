#!/usr/bin/env bash
# superblock cluster_id is reported as reserved, and mkfs leaves it zero
#
# cluster_id is in the superblock, but nothing writes it except mkfs (0)
# and nothing checks it: cluster membership is the Node Registry's job.
# The field is reserved, and procfs says so instead of presenting it as
# a live identifier (audit O12). No format change: the field and its
# value are unchanged.
#
# This is a label-level check. The field has no behaviour to test, so
# what can be asserted is what procfs reports and what mkfs wrote.
#
# DISCRIMINATION: with the pre-fix label ("cluster_id: N") the first
# assertion fails.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module

DEV="$(ct_dev 560 clusterid)"
MNT="$(ct_mnt clusterid)"
ct_mkfs_small "$DEV" >/dev/null
ct_track mnt "$MNT"
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"
INFO="$(ct_procdir "$DEV")/properties"
LINE="$(grep '^cluster_id' "$INFO" || true)"
[ "$LINE" = "cluster_id (reserved): 0" ] &&
    pass "procfs reports cluster_id as reserved, and it is zero" ||
    fail "procfs reports: '$LINE'"
ct_umount "$MNT"
ct_exit
