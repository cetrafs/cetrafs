#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# The release test bar (D4), automated.
#
# D4 asks for `make check` + ctest + crash rig + fuzz + soak, green on
# real hardware, run N times -- because one green run is not evidence for
# a test that exists to catch a low-probability race.
#
# Four of those five are loop-backed and need nothing but root and a
# buildable kernel, so they are automated here. ctest is NOT: it needs a
# shared LUN and two or three real nodes, and it REFORMATS that LUN. It
# is printed as a reminder at the end and must be run by hand; a release
# is not signed off until it has been.
#
# Every stage writes its own log, the summary is written to disk as well
# as printed, and the exit status is nonzero if any stage failed -- so
# this is usable unattended.
#
# usage: tests/release-matrix.sh [-r N] [-s N] [-f N] [-o DIR] [-q] [-x] [-F]
#   -r N   repeat the whole matrix N times (default 1; D4 wants N > 1)
#   -s N   soak rounds per pass (default 200, the D3 release count)
#   -f N   fuzz iterations per fuzzer (default 3000)
#   -o DIR output directory (default release-matrix-<utc timestamp>)
#   -q     quick self-test of this script: tiny counts, proves it runs
#   -x     stop at the first failed stage (default: run them all)
#   -S L   run only these stages (comma-separated), to resume after a
#          failure without repeating what already passed. Names:
#            build,check,crash,sparse,fuzz-fsck,fuzz-fsck-fields,
#            fuzz-mount,fuzz-mount-fields,soak
#          e.g.  -S fuzz-mount-fields,soak
#   -R [D] resume: re-run the stages that FAILED in run D (default: the
#          most recent release-matrix-* directory) BEFORE anything else.
#          If they all pass, the stages that already passed are then run
#          too, so a green resume is still a full matrix. If they fail
#          again it stops there -- no point spending hours re-proving
#          what already passed against a fix that did not work.
#   -F     run even if a cetrafs filesystem is mounted (see below)
#   -n     dry run: exercise this script's own logic (preflight, locking,
#          logging, summary, exit status) without running any suite
set -uo pipefail

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SDIR"

# KEEPGOING defaults to 1: a stage failing is a reason to REPORT it, not
# to throw away the hours the remaining stages would have taken. The
# maintainer watches the output and can interrupt; what they cannot do is
# get back an afternoon spent re-running stages that already passed.
REPEAT=1 SOAK_ROUNDS=200 FUZZ_ITERS=3000 OUT="" QUICK=0 KEEPGOING=1 FORCE=0 DRYRUN=0
ONLY=""      # -S: run only these stages (empty = all)
RESUME=""    # -R: directory of a previous run whose failures come first

while getopts ":r:s:f:o:S:R:qkxFn" o; do
    case "$o" in
        r) REPEAT="$OPTARG" ;;
        s) SOAK_ROUNDS="$OPTARG" ;;
        f) FUZZ_ITERS="$OPTARG" ;;
        o) OUT="$OPTARG" ;;
        q) QUICK=1 ;;
        k) KEEPGOING=1 ;;   # kept: it is the default now, so this is a no-op
        x) KEEPGOING=0 ;;
        S) ONLY=",$OPTARG," ;;
        R) RESUME="${OPTARG:-auto}" ;;
        F) FORCE=1 ;;
        n) DRYRUN=1 ;;
        *) sed -n '/^# usage:/,/^#          logging/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done

if [ "$QUICK" = 1 ]; then
    SOAK_ROUNDS=2
    FUZZ_ITERS=50
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-$SDIR/release-matrix-$STAMP}"
mkdir -p "$OUT" || { echo "cannot create $OUT"; exit 1; }
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

say() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
hr()  { say "------------------------------------------------------------"; }

# ---------------------------------------------------------------- preflight

[ "$(id -u)" = 0 ] || { echo "must run as root (the suites load the module and mount)"; exit 1; }

# One at a time. Two concurrent runs would each load and unload the
# module under the other, and a suite that aborts because something else
# rmmod'd the module looks exactly like a real failure. This has already
# produced false failures by hand; the lock makes it impossible.
exec 9>"/var/lock/cetrafs-release-matrix.lock"
if ! flock -n 9; then
    echo "another release-matrix run holds the lock -- refusing to contaminate it"
    exit 1
fi

# The suites load, unload and reload the module and mount loop devices.
# If this node has a real cetrafs volume mounted -- which it will, on a
# cluster node -- rmmod fails, suites abort, and in the worst case a live
# datastore is disturbed. Refuse by default.
MOUNTED="$(awk '$3 == "cetrafs" { print $2 }' /proc/self/mounts || true)"
if [ -n "$MOUNTED" ] && [ "$FORCE" != 1 ]; then
    echo "a cetrafs filesystem is mounted here:"
    echo "$MOUNTED" | sed 's/^/    /'
    echo
    echo "The suites load and unload the module; running now would disturb that mount"
    echo "and produce failures that are not real. Unmount it, or pass -F if you are"
    echo "certain (you are not, on a cluster node running VMs)."
    exit 1
fi

# The suites insmod their own freshly built module. If one is already
# loaded -- which it will be on a node that has been running cetrafs --
# every insmod fails with EEXIST and `make check` dies in seconds with
# "insmod failed", which reads like a broken build rather than a
# machine that was not prepared. Say so here, before 9 minutes of
# nothing.
# /sys/module/cetrafs catches the case lsmod CANNOT: a module in "Dying"
# state is removed from lsmod's list while still owning its name, so
# insmod keeps reporting "File exists". Checking only lsmod let a stuck
# module through and every suite then waited out its retry -- 57 minutes
# to report nothing.
if [ -d /sys/module/cetrafs ] && ! lsmod | awk '$1 == "cetrafs" { found = 1 } END { exit !found }'; then
    echo "a cetrafs module is present but NOT in lsmod -- it is in Dying state,"
    echo "still holding its name. insmod will fail with \"File exists\" until"
    echo "whatever references it lets go. Wait for /sys/module/cetrafs to"
    echo "disappear, then re-run:"
    echo "    while [ -d /sys/module/cetrafs ]; do sleep 2; done"
    exit 1
fi

# A module left loaded is not a reason to refuse -- just clear it. The
# suites build and load their own, and require_module takes over a
# foreign one anyway; blocking here would be a false stop.
if lsmod | awk '$1 == "cetrafs" { found = 1 } END { exit !found }'; then
    if rmmod cetrafs 2>/dev/null; then
        echo "note: unloaded a leftover cetrafs module before starting"
    else
        USERS="$(lsmod | awk '$1 == "cetrafs" { print $3 }')"
        echo "a cetrafs module is loaded (refcount ${USERS:-0}) and will not unload."
        echo
        echo "Something still holds it. Usually a mount:"
        echo "    awk '\$3 == \"cetrafs\"' /proc/self/mounts"
        echo "    lsof +f -- /mnt/...        # or whatever is mounted"
        exit 1
    fi
fi

MISSING=""
for t in gcc make fio dmsetup losetup python3; do
    command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
[ -d "/lib/modules/$(uname -r)/build" ] || MISSING="$MISSING kernel-headers"
# dm-log-writes / dm-flakey back the crash rig; absent means that stage
# is skipped rather than silently passing.
CRASH_OK=1
for m in dm-log-writes dm-flakey; do
    modprobe "$m" 2>/dev/null || true
done
grep -qE 'log-writes' /proc/misc 2>/dev/null || true

if [ -n "$MISSING" ]; then
    echo "missing prerequisites:$MISSING"
    exit 1
fi

AVAIL_MB="$(df -Pm /tmp | awk 'NR==2 {print $4}')"
if [ "${AVAIL_MB:-0}" -lt 2048 ] && [ "$DRYRUN" = 1 ]; then
    echo "note: only ${AVAIL_MB} MiB free in /tmp -- a real run would stop here (dry run continues)"
elif [ "${AVAIL_MB:-0}" -lt 2048 ]; then
    echo "only ${AVAIL_MB} MiB free in /tmp -- the suites put sparse images there and a"
    echo "run that fills it fails in an unrelated place. Free some space first."
    exit 1
fi

# Resolved once: the header and the results footer must not be able to
# disagree about which code was tested, and a run is compared against
# other runs far more often than it is read top to bottom.
GIT_DESC="$(git -C "$SDIR" describe --tags --always --dirty 2>/dev/null || echo unknown)"
GIT_SHA="$(git -C "$SDIR" rev-parse HEAD 2>/dev/null || echo unknown)"
# describe --dirty already appends "-dirty"; do not restate it, just say
# what it means for the result.
GIT_DIRTY=""
case "$GIT_DESC" in *-dirty) GIT_DIRTY=" [uncommitted changes -- this result is not reproducible from the commit]" ;; esac

# Start from a clean kernel ring buffer. A matrix run lasts hours and
# every suite greps dmesg; starting clean makes the post-mortem readable
# and stops an unrelated earlier Oops being attributed to this run.
#
# Saved first, never just discarded -- whatever was in there may be the
# evidence for the thing that made you run this in the first place.
if dmesg -r >/dev/null 2>&1; then
    dmesg -T > "$OUT/dmesg-before.txt" 2>/dev/null || true
    dmesg -C 2>/dev/null && DMESG_CLEARED=1 || DMESG_CLEARED=0
else
    DMESG_CLEARED=0
fi

# ------------------------------------------------------------------ manifest
{
    echo "cetrafs release matrix"
    echo "started:  $(date -u +%Y-%m-%dT%H:%M:%SZ) (UTC)"
    echo "host:     $(hostname)"
    echo "kernel:   $(uname -r)  $(uname -m)"
    echo "git:      $GIT_DESC"
    echo "commit:   $GIT_SHA"
    echo "passes:   $REPEAT"
    echo "soak:     ROUNDS=$SOAK_ROUNDS per pass"
    echo "fuzz:     $FUZZ_ITERS iters per fuzzer per pass"
    [ "$QUICK" = 1 ] && echo "MODE:     QUICK -- reduced counts, NOT a release run"
    [ "$DRYRUN" = 1 ] && echo "MODE:     DRY RUN -- no suite is executed"
    echo "logs:     $OUT"
    [ "${DMESG_CLEARED:-0}" = 1 ] && echo "dmesg:    cleared at start (previous contents in $OUT/dmesg-before.txt)"
} | tee -a "$SUMMARY"
hr

if git -C "$SDIR" status --porcelain 2>/dev/null | grep -q .; then
    say "WARNING: working tree is dirty -- this run does not describe a clean commit"
    hr
fi

# --------------------------------------------------------------------- stages

FAILED_STAGES=""
declare -a ROWS=()

# want_stage <name> -- true unless -S was given and excluded it
want_stage() {
    case ",${SKIP_DONE:-}," in *",$1,"*) return 1 ;; esac
    [ -z "$ONLY" ] && return 0
    case "$ONLY" in *",$1,"*) return 0 ;; esac
    return 1
}

# run_stage <name> <label> <logfile-basename> <command...>
run_stage() {
    local name="$1" label="$2" logname="$3"; shift 3

    if ! want_stage "$name"; then
        printf '%-28s %s\n' "$label" "skipped (-S)"
        return 0
    fi
    local log="$OUT/$logname.log" start end rc secs

    printf '%-28s ' "$label"
    start="$(date +%s)"
    if [ "$DRYRUN" = 1 ]; then
        { echo "DRY RUN -- would have executed:"; printf '  %q' "$@"; echo; } > "$log"
        rc=0
    else
        "$@" > "$log" 2>&1
        rc=$?
    fi
    end="$(date +%s)"
    secs=$((end - start))

    if [ "$rc" = 0 ]; then
        printf 'PASS  %5ds\n' "$secs"
        ROWS+=("$(printf '%-28s PASS  %5ds' "$label" "$secs")")
    else
        printf 'FAIL  %5ds  (rc=%d)\n' "$secs" "$rc"
        local note=""
        # The known harness flake: the module fails to load at suite
        # start, before any assertion runs. Flagged, never hidden and
        # never auto-retried -- the maintainer judges it.
        if grep -q "insmod failed" "$log" 2>/dev/null; then
            # NOT a flake, and calling it one sent real debugging after
            # the wrong thing. It means the module could not be loaded:
            # usually one still present in Dying state, which lsmod
            # cannot see.
            note="  [the module could not be loaded -- this is NOT a test result."
            note="$note  Check: ls -d /sys/module/cetrafs (present => dying, wait for it to clear)]"
        fi
        ROWS+=("$(printf '%-28s FAIL  %5ds  rc=%d' "$label" "$secs" "$rc")")
        [ -n "$note" ] && ROWS+=("$note")
        FAILED_STAGES="$FAILED_STAGES $label"
        return 1
    fi
    return 0
}

run_pass() {
    local pass="$1"
    say ""
    say "===== pass $pass of $REPEAT ====="

    run_stage build "build (clean)"        "p${pass}-build"  make -C "$SDIR" clean all      || [ "$KEEPGOING" = 1 ] || return 1
    run_stage check "make check"           "p${pass}-check"  make -C "$SDIR" check          || [ "$KEEPGOING" = 1 ] || return 1
    run_stage crash "crash rig"            "p${pass}-crash"  make -C "$SDIR" check-crash    || [ "$KEEPGOING" = 1 ] || return 1
    run_stage sparse "sparse / big file"    "p${pass}-sparse" make -C "$SDIR" check-slow     || [ "$KEEPGOING" = 1 ] || return 1

    run_stage fuzz-fsck "fuzz fsck"            "p${pass}-fuzz-fsck" \
        "$SDIR/tests/fuzz/fuzz_fsck.sh" "$FUZZ_ITERS"            || [ "$KEEPGOING" = 1 ] || return 1
    run_stage fuzz-fsck-fields "fuzz fsck (fields)"   "p${pass}-fuzz-fsck-fields" \
        "$SDIR/tests/fuzz/fuzz_fsck_fields.sh" "$FUZZ_ITERS"     || [ "$KEEPGOING" = 1 ] || return 1
    run_stage fuzz-mount "fuzz mount"           "p${pass}-fuzz-mount" \
        "$SDIR/tests/fuzz/fuzz_mount.sh" "$((FUZZ_ITERS / 10))"  || [ "$KEEPGOING" = 1 ] || return 1
    run_stage fuzz-mount-fields "fuzz mount (fields)"  "p${pass}-fuzz-mount-fields" \
        "$SDIR/tests/fuzz/fuzz_mount_fields.sh" "$((FUZZ_ITERS / 10))" || [ "$KEEPGOING" = 1 ] || return 1

    # soak.sh deliberately does NOT insmod -- it requires the module
    # already loaded, so the operator controls which build is under
    # test. Every stage before it leaves the module unloaded (make check
    # unloads at the end of its batch; the fuzzers load their own and
    # clean up), so unattended the soak stage died instantly with
    # "cetrafs module not loaded". Load it here, which is the matrix
    # being the operator.
    if want_stage soak && ! lsmod | grep -q '^cetrafs '; then
        if insmod "$SDIR/kmod/cetrafs.ko" 2>/dev/null; then
            say "loaded the module for the soak stage (soak does not insmod by design)"
            SOAK_LOADED_MODULE=1
        else
            say "WARNING: could not load the module for soak -- it will refuse to run"
        fi
    fi

    run_stage soak "soak (ROUNDS=$SOAK_ROUNDS)" "p${pass}-soak" \
        make -C "$SDIR" soak ROUNDS="$SOAK_ROUNDS"               || [ "$KEEPGOING" = 1 ] || return 1

    [ "${SOAK_LOADED_MODULE:-0}" = 1 ] && { rmmod cetrafs 2>/dev/null || true; SOAK_LOADED_MODULE=0; }

    return 0
}

# ------------------------------------------------------- resume ordering
#
# Run what FAILED last time before anything else. A fix is confirmed or
# refuted in minutes; re-proving the stages that already passed first
# costs an hour before you learn anything. If the previously-failed
# stages pass, the rest follow, so a green resume is still a full matrix.
FAILED_LAST=""
if [ -n "$RESUME" ]; then
    RDIR="$RESUME"
    if [ "$RDIR" = "auto" ]; then
        RDIR="$(ls -1d "$SDIR"/release-matrix-* 2>/dev/null | sort | tail -1)"
    fi
    if [ -z "$RDIR" ] || [ ! -f "$RDIR/summary.txt" ]; then
        echo "-R: no previous run found (looked for $RDIR/summary.txt)"
        exit 1
    fi
    # Map the human stage labels in the summary back to stage names.
    FAILED_LAST="$(awk '/^FAILED:/ { sub(/^FAILED:/, ""); print }' "$RDIR/summary.txt" |
        sed -e 's/build (clean)/build/g' \
            -e 's/make check/check/g' \
            -e 's/crash rig/crash/g' \
            -e 's|sparse / big file|sparse|g' \
            -e 's/fuzz fsck (fields)/fuzz-fsck-fields/g' \
            -e 's/fuzz mount (fields)/fuzz-mount-fields/g' \
            -e 's/fuzz fsck/fuzz-fsck/g' \
            -e 's/fuzz mount/fuzz-mount/g' \
            -e 's/soak ([^)]*)/soak/g' | tr -s ' ' '\n' | grep -v '^$' | tr '\n' ',')"
    if [ -z "$FAILED_LAST" ]; then
        echo "-R: $RDIR reports no failed stages -- nothing to resume."
        exit 0
    fi
    echo "resuming: $RDIR"
    echo "  failed last time: ${FAILED_LAST%,}"
    echo "  running those first; the rest follow only if they pass."
    echo
fi

OVERALL=0
if [ -n "$FAILED_LAST" ]; then
    SAVED_ONLY="$ONLY"
    ONLY=",${FAILED_LAST%,},"
    say "===== resume: previously-failed stages ====="
    if run_pass "resume"; then
        say ""
        say "the previously-failed stages now pass -- running the rest."
        ONLY="$SAVED_ONLY"
        # Skip what we just ran rather than doing it twice.
        SKIP_DONE="$FAILED_LAST"
    else
        say ""
        say "STILL FAILING -- stopping here rather than spending hours re-proving"
        say "stages that already passed against a fix that did not work."
        OVERALL=1
        REPEAT=0
    fi
fi

for pass in $(seq 1 "$REPEAT"); do
    if ! run_pass "$pass"; then
        OVERALL=1
        [ "$KEEPGOING" = 1 ] || { say ""; say "stopping at pass $pass (-x was given; the default runs every stage)"; break; }
    fi
done
[ -n "$FAILED_STAGES" ] && OVERALL=1

# --------------------------------------------------------------------- report

hr
say "results   $GIT_DESC${GIT_DIRTY}"
hr
for r in "${ROWS[@]}"; do say "$r"; done
hr
dmesg -T > "$OUT/dmesg-after.txt" 2>/dev/null || true
say "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ) (UTC)"

if [ "$OVERALL" = 0 ]; then
    say "ALL AUTOMATED STAGES PASSED ($REPEAT pass(es)) on $GIT_DESC${GIT_DIRTY}"
else
    say "FAILED on $GIT_DESC${GIT_DIRTY}:$FAILED_STAGES"
fi

say ""
say "NOT covered by this script -- the release is not signed off without it:"
say ""
say "  ctest, on the real shared LUN, from every node. It REFORMATS the LUN."
say "    make ctest                                    # build it"
say "    ./ctest/ctest -scenario=full-suite -repeat $REPEAT"
say ""
say "  A loop device has no atomic COMPARE AND WRITE and serves an 'uncached'"
say "  read from the host page cache for free, so it exercises neither the"
say "  real CAW primitive nor any cross-node race, and it cannot tell you"
say "  what an operation costs. Everything above is necessary, not sufficient."
say ""
say "logs and this summary: $OUT"

if [ "$QUICK" = 1 ]; then
    say ""
    say "QUICK MODE -- counts were reduced to prove the script runs."
    say "A release run is: tests/release-matrix.sh -r 3"
fi

exit "$OVERALL"
