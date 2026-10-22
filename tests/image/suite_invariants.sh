#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# properties every test suite must hold, checked rather than described
#
# These rules must be encoded in test code because their breakages are
# silent by nature -- nothing notices when a suite breaks one, and the breakages are silent by
# nature -- a suite whose cleanup never runs leaves loop devices and
# mounts behind for whatever runs NEXT, so the failure surfaces
# somewhere else entirely and looks like flakiness.
#
# Matched against CODE, never prose: an earlier hand-rolled version of
# the first check reported a suite whose only mention of a trap was a
# comment explaining why it does not use one. An audit that cries wolf
# is one people learn to ignore, at which point it has stopped being a
# check.
#
# No module, nothing mounted.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root

# Suites that use the harness. A standalone suite with its own cleanup
# and its own summary (tests/image/fsck_negative_controls.sh) is not
# bound by rules that are about the harness's machinery.
harness_suites() {
    grep -l "lib/harness.sh" "$ROOT"/tests/kernel/*.sh "$ROOT"/tests/image/*.sh 2>/dev/null
}

# Strip comments so every check below sees code only.
#
# Captured into a variable, never piped into `grep -q`. This file broke
# its own fourth rule: `code "$f" | grep -q X` under `set -o pipefail`
# reports FAILURE when grep matches, because grep -q exits at the first
# hit and sed dies of SIGPIPE -- so a match looked like a miss. It was
# intermittent (4 runs in 20) because it depends on whether sed finished
# writing before grep exited, and it was wrong in both directions: a
# false failure where the answer is "did it match", and a SILENT SKIP
# where the answer gates whether the file is examined at all.
code() { sed 's/#.*//' "$1"; }
# NO `grep -q`: it exits at the first match, so whatever feeds it dies
# of SIGPIPE and `set -o pipefail` turns a successful match into a
# failed pipeline. Plain grep with its output discarded reads to EOF,
# so the writer always finishes and the exit status means what it says.
has() { printf '%s\n' "$2" | grep -E "$1" >/dev/null; }

log "a harness suite must not install its own EXIT trap"
# It REPLACES the harness's cleanup trap outright, so this suite's loop
# devices and mounts are never torn down, and anything it restores runs
# AFTER ct_exit has already checked. ct_track and ct_param_set exist for
# exactly these two jobs.
BAD=""
for f in $(harness_suites); do
    SRC="$(code "$f")"
    has "^[[:space:]]*trap[[:space:]].*EXIT" "$SRC" && BAD="$BAD $(basename "$f")"
done
[ -z "$BAD" ] && pass "no harness suite overrides the cleanup trap" ||
    fail "these replace the harness cleanup trap, so their devices leak into the next suite:$BAD"

log "a harness suite must end at ct_exit"
# ct_exit is where the end-of-suite checks live: module parameters
# restored, the module actually unloadable, no BUG/Oops/WARNING in
# dmesg. A suite that returns without it reports its own assertions and
# silently skips all of those.
BAD=""
for f in $(harness_suites); do
    SRC="$(code "$f")"
    has "^[[:space:]]*ct_exit([[:space:]]|$)" "$SRC" || BAD="$BAD $(basename "$f")"
done
[ -z "$BAD" ] && pass "every harness suite reaches ct_exit" ||
    fail "these never run the end-of-suite checks:$BAD"

log "a suite that mounts must prove it is on a cetrafs mount"
# This project has been bitten three times by a run that reported
# success while never touching the filesystem -- the module was not
# loaded and the "mount" silently wrote to the host fs. Asserting
# anything before this check is asserting about the wrong filesystem.
BAD=""
for f in $(harness_suites); do
    SRC="$(code "$f")"
    has "ct_mount" "$SRC" || continue
    has "require_cetrafs_mount" "$SRC" || BAD="$BAD $(basename "$f")"
done
[ -z "$BAD" ] && pass "every suite that mounts checks what it mounted" ||
    fail "these mount without confirming it is cetrafs:$BAD"

log "a tool whose nonzero exit IS the finding must not be a pipeline condition"
# `set -o pipefail` makes a pipeline inherit the tool's status, and fsck
# exits nonzero exactly when it finds the fault being looked FOR -- so
# `fsck ... | grep -q "..."` as a condition fails however well grep
# matched. Capture first, grep after. This has bitten four times.
BAD=""
for f in $(harness_suites); do
    # A condition, not a message: the pipeline is followed by && or is
    # the subject of an `if`. Inside "$( ... )" it is building a failure
    # string and its status is already irrelevant.
    while IFS= read -r line; do
        case "$line" in *'$('*) continue ;; esac
        case "$line" in
            *ct_fsck*\|*grep*\&\&* | *fsck.cetra*\|*grep*\&\&* | if*ct_fsck*\|*grep* | if*fsck.cetra*\|*grep*)
                BAD="$BAD $(basename "$f")" ;;
        esac
    done <<<"$(code "$f")"
done
BAD="$(echo "$BAD" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
[ -z "${BAD// /}" ] && pass "no suite branches on a piped fsck result" ||
    fail "these branch on a pipeline whose status is fsck's own finding:$BAD"

ct_exit
