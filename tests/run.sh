#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# tests/run.sh -- run one or more cetrafs test suites and judge the result.
#
#   ./tests/run.sh image            every image-level suite (no module, seconds)
#   ./tests/run.sh image kernel     the full regression set (what `make check` runs)
#   ./tests/run.sh kernel/nslock.sh one suite
#   ./tests/run.sh -l               list every suite with its one-line purpose
#
# Groups are directory names under tests/: image, kernel, device, stress.
# device/ and stress/ are opt-in -- they are destructive or slow and take
# arguments, so they are never part of a group run.
#
# Each suite is an independent process with its own image, mount and
# cleanup. The module is loaded once here for a whole batch (and unloaded
# at the end); a suite run on its own loads it itself.
set -uo pipefail

CT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CT_DIR"

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

list_suites() {
    local f
    for f in image/*.sh kernel/*.sh device/*.sh stress/*.sh; do
        [ -f "$f" ] || continue
        printf '  %-42s %s\n' "$f" "$(sed -n '2s/^# \?//p' "$f")"
    done
}

fmt_dur() {
    local s=$1
    if [ "$s" -lt 60 ]; then echo "${s}s"; else printf '%dm%02ds\n' $((s / 60)) $((s % 60)); fi
}

[ $# -eq 0 ] && usage 1
case "${1:-}" in
-l | --list)
    list_suites
    exit 0
    ;;
-h | --help) usage 0 ;;
esac

SUITES=()
for arg in "$@"; do
    if [ -d "$arg" ]; then
        for f in "$arg"/*.sh; do [ -f "$f" ] && SUITES+=("$f"); done
    elif [ -f "$arg" ]; then
        SUITES+=("$arg")
    else
        echo "run.sh: no such suite or group: $arg" >&2
        exit 2
    fi
done
[ ${#SUITES[@]} -eq 0 ] && {
    echo "run.sh: nothing to run" >&2
    exit 2
}

[ "$(id -u)" = "0" ] || {
    echo "must run as root" >&2
    exit 2
}

# What the batch needs decides what gets built. image/ suites never load
# the module -- they corrupt a structure mkfs wrote and require fsck to
# report that fault -- so building it for them demands kernel headers a
# packaging or CI host has no reason to carry.
NEED_MODULE=0
for s in "${SUITES[@]}"; do case "$s" in kernel/* | device/* | stress/*) NEED_MODULE=1 ;; esac; done

# Tell the per-suite builder too: a suite invoked directly (not through
# this runner) decides for itself, but inside a batch the batch decides.
export CT_NEED_MODULE="$NEED_MODULE"

# Build once for the whole batch rather than once per suite.
if [ "$NEED_MODULE" = "1" ]; then
    make -C "$CT_DIR/.." all >/dev/null || exit 2
else
    make -C "$CT_DIR/.." userspace >/dev/null || exit 2
fi

# Load the module once if any kernel-level suite is in the batch. Each
# suite still calls require_module, which is a no-op when it is already
# loaded -- so a suite stays runnable on its own.
CT_QUIET=1   # the runner is not a suite: no summary, no dmesg verdict of its own
. "$CT_DIR/lib/harness.sh"
# Fails fast and loudly: require_module exits 2 with the kernel's own
# message. A module that cannot be loaded at all is a property of the
# machine, and no suite below would tell us anything about the
# filesystem.
[ "$NEED_MODULE" = "1" ] && require_module

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SUITES=()
RESULTS=()
BATCH_START=$SECONDS

for s in "${SUITES[@]}"; do
    echo
    echo "========== $s =========="
    START=$SECONDS
    # Every suite runs under a timeout, because the characteristic
    # failure of the buffer-update protocol is a HANG, not an error: a
    # begin_update that never reaches end/abort leaves the buffer locked,
    # and every later access to that block blocks forever. Without a
    # deadline that is a suite with no FAIL line, no summary and no exit
    # -- indistinguishable from "still running", and in CI it just hangs.
    # The slowest real suite is ~26s; CT_SUITE_TIMEOUT overrides.
    OUT="$(timeout -k 10 "${CT_SUITE_TIMEOUT:-300}" bash "$s" 2>&1)"
    RC=$?
    echo "$OUT"
    TOOK=$((SECONDS - START))
    P="$(grep -c '^PASS:' <<<"$OUT")"
    F="$(grep -c '^FAIL:' <<<"$OUT")"
    TOTAL_PASS=$((TOTAL_PASS + P))
    TOTAL_FAIL=$((TOTAL_FAIL + F))
    # A nonzero exit with no FAIL line means the suite ABORTED rather than
    # failed an assertion -- the failure mode that prints no summary and
    # reads exactly like success if only the FAIL lines are counted.
    VERDICT=PASS
    if [ "$RC" = "124" ] || [ "$RC" = "137" ]; then
        # timeout(1) reports 124 (or 137 after its -k kill). A hung suite
        # is a failure, and naming it TIMEOUT rather than FAIL says where
        # to look: something is waiting on a lock that is never released.
        echo "FAIL: $s did not finish within ${CT_SUITE_TIMEOUT:-300}s -- killed (a wedged buffer lock looks like this)"
        VERDICT=TIMEOUT
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    elif [ "$F" -gt 0 ]; then
        VERDICT=FAIL
    elif [ "$RC" != "0" ]; then
        VERDICT=ABORT
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi

    # A suite that could not load the module tells us nothing about the
    # filesystem, and the NEXT one will fail identically -- the module is
    # stuck for the machine, not for this suite. Stop the batch instead
    # of burning the per-suite retry 112 more times.
    #
    # Measured: a module left in "Dying" state (gone from lsmod, still
    # present to insmod, which says "File exists") made every one of 112
    # kernel suites wait out the full retry -- 57 minutes to report
    # nothing. An hour of waiting for a result the first suite already
    # had.
    if grep -q '^insmod failed' <<<"$OUT"; then
        echo
        echo "ABORTING THE BATCH: the module could not be loaded."
        grep -m1 '^insmod failed' <<<"$OUT" | sed 's/^/    /'
        echo
        echo "    Every remaining suite would fail the same way. Check:"
        echo "      lsmod | grep cetrafs            # loaded?"
        echo "      ls -d /sys/module/cetrafs       # present but DYING? (absent from lsmod)"
        echo "      awk '\$3 == \"cetrafs\"' /proc/self/mounts   # still mounted?"
        echo "    A dying module clears on its own once whatever holds it lets go."
        MODULE_STUCK=1
        break
    fi
    # A suite that leaves a cetrafs mount or a loop device behind is a
    # failure of that suite, named here rather than surfacing later as an
    # unexplained "Module cetrafs is in use" at the end of the batch.
    LEFT_MNT="$(awk '$3 == "cetrafs" { print $2 }' /proc/self/mounts | tr '\n' ' ')"
    if [ -n "$LEFT_MNT" ]; then
        echo "FAIL: $s left a cetrafs mount behind: $LEFT_MNT"
        for m in $LEFT_MNT; do umount "$m" 2>/dev/null; done
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        VERDICT=FAIL
    fi

    [ "$VERDICT" = PASS ] || FAILED_SUITES+=("$s ($VERDICT)")
    RESULTS+=("$(printf '%-44s %-5s %4d passed %4d failed %8s' "$s" "$VERDICT" "$P" "$F" "$(fmt_dur $TOOK)")")
done

# Unloading the module is an assertion too, and it belongs to the batch
# rather than to any one suite: a leaked reference from suite N only
# surfaces here.
if [ "${CT_MODULE_LOADED:-0}" = "1" ]; then
    PASSES=0
    FAILURES=0
    ct_unload_module
    TOTAL_PASS=$((TOTAL_PASS + PASSES))
    TOTAL_FAIL=$((TOTAL_FAIL + FAILURES))
    [ "$FAILURES" -gt 0 ] && FAILED_SUITES+=("module unload")
fi

echo
echo "===== results ====="
printf '%s\n' "${RESULTS[@]}"
echo "-------------------"
printf '%-44s %-5s %4d passed %4d failed %8s\n' "TOTAL" "" "$TOTAL_PASS" "$TOTAL_FAIL" "$(fmt_dur $((SECONDS - BATCH_START)))"

if [ "${MODULE_STUCK:-0}" = 1 ]; then
    echo
    echo "NOT A RESULT: the batch stopped because the module would not load."
    echo "Nothing here says anything about the filesystem -- fix the machine and re-run."
    exit 2
fi

if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo
    echo "FAILED: ${FAILED_SUITES[*]}"
    exit 1
fi
echo
echo "ALL CHECKS PASSED"
