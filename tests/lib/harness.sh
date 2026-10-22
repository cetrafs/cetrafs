# SPDX-License-Identifier: GPL-2.0-or-later
# tests/lib/harness.sh -- shared scaffolding for every cetrafs test suite.
#
# Sourced, never executed. Provides:
#
#   reporting        log / pass / fail / skip, a per-suite summary and the
#                    exit code the runner judges by
#   preconditions    require_root, require_module, require_cetrafs_mount
#   resources        ct_image / ct_loop / ct_mnt / ct_tmp, all auto-cleaned
#                    in reverse order on EVERY exit path
#   tools            ct_helper (compiles tests/helpers/*.c on demand),
#                    ct_mkfs / ct_fsck / ct_mount / ct_umount
#   staleness        set_stale_window / poke_dead_peer /
#                    wait_out_stale_window / reset_stale_window
#   kernel log       dmesg_mark / dmesg_since (timestamp-based, immune to
#                    ring-buffer wrap)
#
# The short names (log/pass/fail/dmesg_mark) are deliberate: suites read
# as prose, and the names match what this project's tests have always
# used.
#
# RULES FOR SUITES (see tests/README.md for the long version):
#   - a suite must be runnable on its own: own image, own mount, own
#     cleanup. Nothing may depend on another suite having run first.
#   - a suite must FAIL, not abort, when an assertion does not hold.
#     `set -e` plus an unguarded command is how a run ends with no FAIL
#     line and no summary -- which reads exactly like success.
#   - every detection a suite claims needs a negative control: break the
#     thing and watch THAT assertion fail. A test that cannot fail is
#     worse than no test.

[ -n "${CT_HARNESS_LOADED:-}" ] && return 0
CT_HARNESS_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CT_TESTS="$ROOT/tests"
CT_BUILD="${CT_BUILD:-$CT_TESTS/.build}"
CT_SUITE="$(basename "${0%.sh}")"

PASSES=0
FAILURES=0

log() { echo "== $*"; }
pass() {
    echo "PASS: $*"
    PASSES=$((PASSES + 1))
}
fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}
# A skip is NOT a pass. It is printed so a run that silently stopped
# covering something is visible in the log rather than inferred from a
# shrinking total.
skip() { echo "SKIP: $*"; }

# ---------------------------------------------------------------- dmesg
#
# A line-count-based "mark, then slice from mark+1" breaks the moment the
# kernel ring buffer wraps between the mark and the slice: older entries
# are evicted, every later line shifts, and "+N+1" silently points past
# the line being looked for. CETRAFS_DEBUG's per-lookup lines can wrap
# the buffer well within one run -- this caused a real false failure
# ("alloc selftest did not run") when the line had in fact printed.
# Filtering by the kernel's own monotonic timestamp is immune: a line's
# timestamp never changes however many older lines are dropped.
dmesg_mark() { dmesg | tail -1 | sed -n 's/^\[\s*\([0-9.]\+\)\].*/\1/p'; }
dmesg_since() {
    local mark="${1:-0}"
    dmesg | awk -v mark="$mark" '{
        ts = $0
        sub(/^\[[ \t]*/, "", ts)
        sub(/\].*/, "", ts)
        if ((ts + 0) > (mark + 0)) print
    }'
}

# ----------------------------------------------------------- resources
#
# Tracked in a REGISTRY FILE, not in shell arrays, and unwound in reverse
# on exit.
#
# The file matters: the natural API here is `DEV="$(ct_loop "$IMG")"`,
# and command substitution runs in a SUBSHELL -- so an array append
# inside ct_loop would be made in a child and lost in the parent, leaving
# the cleanup trap with nothing to unwind while looking completely
# correct. That is exactly what happened: a run left ten loop devices
# attached and a filesystem still mounted, and the only reason anything
# got cleaned up was the suites' own inline teardown. A file is shared
# across the subshell boundary; arrays are not.
#
# Every expansion in the trap is :- guarded. The trap runs on EVERY exit,
# including an abort partway through setup, and under `set -u` an
# unassigned variable kills the TRAP itself -- replacing the real failure
# with "FOO: unbound variable" and skipping the rest of the cleanup.
CT_REG="$(mktemp /tmp/cetrafs-reg-XXXXXX)"
CT_MODULE_LOADED=0

# ct_track <mnt|loop|dir|file> <path>
ct_track() { echo "$1 $2" >>"$CT_REG"; }

ct_cleanup() {
    set +e
    local kind path
    # Mounts first, then the loop devices under them, then the module,
    # then directories, then files -- each category in reverse order of
    # creation.
    # Mounts, then the loop devices under them. Each gets a couple of
    # retries: a umount can lose a race with a heartbeat tick or a
    # just-issued sync, and a loop device cannot be detached until the
    # filesystem on it is gone.
    #
    # A resource still present after the retries is an ASSERTION FAILURE,
    # not something to swallow: a leaked mount is what makes the module
    # unload at the end of a batch fail, and chasing that back to the
    # suite that caused it is impossible if cleanup is silent.
    local try
    # dm devices sit between the mount and the loop device backing their
    # COW, so they unwind in that order.
    for kind in mnt dm loop; do
        while read -r k path; do
            [ "$k" = "$kind" ] || continue
            # 3 tries at 1s was not enough. After a suite writes to a
            # loop device, udev/blkid rescans it and holds a reference
            # for a moment, so losetup -d returns EBUSY -- seen in a
            # release run where image/fsck_count_convergence passed all
            # three of its real assertions and then failed cleanup on
            # "loop device /dev/loop0 could not be detached"; the device
            # was free seconds later. The assertion is right -- a leaked
            # loop device IS a problem -- it just had to outlast the
            # scan.
            for try in $(seq 1 15); do
                case "$k" in
                mnt)
                    mountpoint -q "$path" 2>/dev/null || break
                    umount "$path" 2>/dev/null && break
                    ;;
                loop)
                    losetup -d "$path" 2>/dev/null && break
                    losetup -a 2>/dev/null | grep -q "^$path:" || break
                    ;;
                dm)
                    dmsetup remove "$path" 2>/dev/null && break
                    dmsetup info "$path" >/dev/null 2>&1 || break
                    ;;
                esac
                # Short waits first (udev settles in well under a
                # second), lengthening only if it really is stuck.
                [ "$try" -le 5 ] && sleep 0.2 || sleep 1
            done
            case "$k" in
            mnt) mountpoint -q "$path" 2>/dev/null &&
                fail "cleanup: $path is still mounted after three umount attempts" ;;
            loop) losetup -a 2>/dev/null | grep -q "^$path:" &&
                fail "cleanup: loop device $path could not be detached" ;;
            dm) dmsetup info "$path" >/dev/null 2>&1 &&
                fail "cleanup: device-mapper device $path could not be removed" ;;
            esac
        done < <(tac "$CT_REG" 2>/dev/null)
    done
    ct_unload_module
    for kind in dir file; do
        tac "$CT_REG" 2>/dev/null | while read -r k path; do
            [ "$k" = "$kind" ] || continue
            case "$k" in
            dir) rmdir "$path" 2>/dev/null ;;
            file) rm -f "$path" 2>/dev/null ;;
            esac
        done
    done
    rm -f "$CT_REG" 2>/dev/null
    ct_check_dmesg
    ct_summary
}

# Unloading is an ASSERTION, not housekeeping. `rmmod` correctly refuses
# with "Module cetrafs is in use" when something still holds a reference,
# and that is exactly how a leaked module reference shows up -- a
# cas_stress kthread that outlived its run leaked one for real. A silent
# `rmmod ... 2>/dev/null` would have hidden it.
#
# Never -f. Forcing removal while a superblock object is still alive
# leaves a dangling shrinker entry that Oopses on a later reclaim pass.
ct_unload_module() {
    [ "${CT_MODULE_LOADED:-0}" = "1" ] || return 0
    CT_MODULE_LOADED=0
    if rmmod cetrafs 2>/dev/null; then
        pass "rmmod succeeded (nothing leaked a module reference)"
        # delete_module() can return before the module is fully out of the
        # kernel's list, so the NEXT suite's insmod races a half-finished
        # unload and aborts with "File exists" (seen under load). Do not
        # exit this suite until the module is genuinely gone -- that closes
        # the window at the source, since the harness runs suites in
        # sequence. Bounded (~10s); if it never clears that is a real
        # problem, not this function's to diagnose.
        # Wait on /sys/module/cetrafs, NOT lsmod. A module in "Dying"
        # state is already out of lsmod's list while still owning its
        # name, so an lsmod probe clears the instant rmmod returns and
        # the next insmod still gets "File exists". That is precisely
        # the window this loop exists to close, and watching lsmod
        # missed it entirely. 60s, because a node that has had a real
        # LUN mounted has taken over 30.
        for _ in $(seq 1 300); do
            [ -d /sys/module/cetrafs ] || break
            sleep 0.2
        done
    else
        fail "rmmod refused: $(rmmod cetrafs 2>&1 | head -1) -- something still holds a reference"
    fi
}

# Printed by the cleanup trap, so it is emitted even when the suite dies
# partway through -- a run that ends with no summary is indistinguishable
# from one that passed, and this project has been bitten by exactly that.
ct_summary() {
    # The runner sources this file too (to load the module once for a
    # batch); it is not a suite and must not print a suite's summary.
    [ -n "${CT_QUIET:-}" ] && return 0
    if [ "${FAILURES:-0}" -gt 0 ]; then
        echo "---- $CT_SUITE: $PASSES passed, $FAILURES FAILED"
    else
        echo "---- $CT_SUITE: $PASSES passed"
    fi
}

ct_check_dmesg() {
    [ -n "${CT_QUIET:-}" ] && return 0
    [ -z "${CT_DMESG_MARK:-}" ] && return 0
    [ -n "${CT_ALLOW_DMESG_WARN:-}" ] && return 0
    if dmesg_since "$CT_DMESG_MARK" | grep -qiE 'BUG:|Oops|Call trace|WARNING:'; then
        fail "dmesg shows a BUG/Oops/WARNING during this suite"
        # Print the FRAMES, not just the banner. Grepping for the
        # matching lines alone keeps "WARNING: ... at foo+0x138" and
        # "Call trace:" and throws away every frame under them -- which
        # is the only part that says whose code was running. A guard
        # that detects a fault and discards the evidence turns a
        # reproducible failure into a mystery, and these faults are
        # often load-dependent and do not reproduce on demand.
        dmesg_since "$CT_DMESG_MARK" | grep -iE -A 30 'BUG:|Oops|WARNING:' | head -80
    else
        pass "no BUG/Oops/WARNING in dmesg during this suite"
    fi
}

# Exit code: nonzero if anything failed, whatever the last command did.
ct_exit() {
    ct_param_restore_all
    ct_check_params
    exit $([ "${FAILURES:-0}" -gt 0 ] && echo 1 || echo 0)
}

trap ct_cleanup EXIT

# ct_tmp [template] -> path to a tracked temporary FILE
ct_tmp() {
    local p
    p="$(mktemp "/tmp/cetrafs-${1:-tmp}-XXXXXX")"
    ct_track file "$p"
    echo "$p"
}

# ct_image <size_mb> [name] -> path to a tracked sparse image file
ct_image() {
    local p avail
    # /tmp is a tmpfs here and every suite puts a half-gigabyte image in
    # it. The images are sparse, so the cost is what gets WRITTEN, and a
    # run that fills /tmp does not fail where the space ran out -- it
    # fails later, in some unrelated suite, looking like flakiness.
    # Three suites failed intermittently in one session before anyone
    # asked how much room was left. Say so here instead.
    avail="$(df -Pm /tmp | awk 'NR==2 {print $4}')"
    if [ -n "$avail" ] && [ "$avail" -lt 200 ]; then
        fail "only ${avail} MiB free in /tmp -- a suite that runs out of space fails somewhere else entirely"
    fi
    p="$(mktemp "/tmp/cetrafs-${2:-img}-XXXXXX.img")"
    truncate -s "${1}M" "$p"
    ct_track file "$p"
    echo "$p"
}

# ct_loop <image> -> loop device, tracked for detach
ct_loop() {
    local d
    d="$(losetup --find --show "$1")"
    ct_track loop "$d"
    echo "$d"
}

# ct_mnt [name] -> tracked empty mountpoint directory
ct_mnt() {
    local p
    p="$(mktemp -d "/tmp/cetrafs-${1:-mnt}-XXXXXX")"
    ct_track dir "$p"
    echo "$p"
}

# ct_huge_dev <terabytes> [name] -> a block device of that nominal size,
# backed by a small COW file: a dm "zero" target (reads zeros, writes
# discarded) with a dm "snapshot" over it, so only what is actually
# written costs real space.
#
# Needed because the one limit that matters at SAN scale cannot be
# reached any other way: ext4 cannot hold a sparse file larger than
# 16 TiB, which is exactly the size the test has to exceed. Returns the
# empty string if device-mapper is unavailable, so a suite can skip.
ct_huge_dev() {
    local tb="$1" name="${2:-huge}" sectors cow cowdev base big
    command -v dmsetup >/dev/null 2>&1 || return 0
    modprobe dm-snapshot 2>/dev/null || true
    modprobe dm-zero 2>/dev/null || true
    sectors=$((tb * 1024 * 1024 * 1024 * 1024 / 512))
    # The COW lives outside /tmp: it really does hold everything mkfs
    # writes (~550 MiB for 17 TiB), which a 1 GiB tmpfs will not.
    cow="$(mktemp "${CT_BIG_DIR:-/root}/cetrafs-cow-XXXXXX.img")"
    ct_track file "$cow"
    truncate -s 2G "$cow"
    cowdev="$(ct_loop "$cow")"
    base="ct${name}base$$"
    big="ct${name}$$"
    dmsetup create "$base" --table "0 $sectors zero" 2>/dev/null || return 0
    ct_track dm "$base"
    if ! dmsetup create "$big" --table "0 $sectors snapshot /dev/mapper/$base $cowdev P 8" 2>/dev/null; then
        return 0
    fi
    ct_track dm "$big"
    echo "/dev/mapper/$big"
}

# ct_failable_dev <size_mb> [name] -> a block device whose I/O can be
# made to fail and then restored, for testing what the filesystem does
# when its LUN goes away under a live mount.
#
# A dm "linear" mapping over a loop device. ct_dev_fail swaps the table
# for an "error" target, which fails every read and write exactly as an
# offline SCSI device does; ct_dev_restore puts the linear mapping back.
# Nothing else can reach this case: a loop device has no device state to
# offline, and the real LUN is the one thing a `make check` suite must
# never touch.
#
# Returns the empty string if device-mapper is unavailable, so a suite
# can skip rather than fail.
ct_failable_dev() {
    local mb="$1" name="${2:-fail}" base sectors img loopdev
    command -v dmsetup >/dev/null 2>&1 || return 0
    img="$(ct_image "$mb" "$name")"
    loopdev="$(ct_loop "$img")"
    sectors=$(blockdev --getsz "$loopdev")
    base="ctf${name}$$"
    dmsetup create "$base" --table "0 $sectors linear $loopdev 0" 2>/dev/null || return 0
    ct_track dm "$base"
    echo "/dev/mapper/$base"
}

# ct_dev_fail <dev> / ct_dev_restore <dev>: make every I/O to a
# ct_failable_dev device fail, and put it back.
#
# The table is read back from device-mapper rather than remembered in a
# variable: ct_failable_dev runs in a command substitution, so anything
# it assigns is lost with the subshell -- which is how the first version
# of this got an unbound-variable abort instead of a test.
#
# suspend --noflush --nolockfs: flushing would block on the very writes
# that are about to start failing.
ct_dev_fail() {
    local name sectors
    name="$(basename "$1")"
    dmsetup table "$name" >"/tmp/ct-dmtable.$name"
    sectors="$(awk '{print $2}' "/tmp/ct-dmtable.$name")"
    dmsetup suspend --noflush --nolockfs "$name"
    dmsetup load "$name" --table "0 $sectors error"
    dmsetup resume "$name"
}
ct_dev_restore() {
    local name
    name="$(basename "$1")"
    dmsetup suspend --noflush --nolockfs "$name"
    dmsetup load "$name" --table "$(cat "/tmp/ct-dmtable.$name")"
    dmsetup resume "$name"
}

# ct_procdir <device> -> /proc/fs/cetrafs/<s_id> for that device.
#
# The directory is named after sb->s_id, which is the kernel's name for
# the block device -- "dm-1" for a device-mapper device, not the
# /dev/mapper/ alias it was created under. basename of the resolved
# symlink is what the kernel uses.
ct_procdir() { echo "/proc/fs/cetrafs/$(basename "$(readlink -f "$1")")"; }

# ct_dev <size_mb> [name] -> a loop device over a fresh sparse image.
# The common case: one call instead of three.
ct_dev() { ct_loop "$(ct_image "$1" "${2:-img}")"; }

# --------------------------------------------------------------- tools
ct_build() {
    [ -n "${CT_BUILT:-}" ] && return 0
    log "building"
    make -C "$ROOT" all >/dev/null
    CT_BUILT=1
}

# ct_helper <name> -> path to the compiled tests/helpers/<name>.c
#
# Cached in tests/.build and rebuilt only when the source (or the on-disk
# format header it reuses) is newer, so a suite costs one cc at most and
# a whole run costs nine.
ct_helper() {
    local name="$1"
    local src="$CT_TESTS/helpers/$name.c"
    local bin="$CT_BUILD/$name"

    [ -f "$src" ] || {
        echo "harness: no such helper: $src" >&2
        return 2
    }
    mkdir -p "$CT_BUILD"
    if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ] || [ "$ROOT/include/cetrafs.h" -nt "$bin" ]; then
        cc -D_FILE_OFFSET_BITS=64 -I "$ROOT/include" -I "$ROOT/userspace" \
            -O2 -std=gnu99 -o "$bin" "$src" || return 1
    fi
    echo "$bin"
}

ct_mkfs() {
    local dev="$1"
    shift
    "$ROOT/userspace/mkfs.cetra" "$dev" "$@"
}
ct_fsck() { "$ROOT/userspace/fsck.cetra" "$1"; }
# fsck in REPAIR mode. Separate from ct_fsck on purpose: every other
# caller in this suite must stay read-only, so a suite cannot start
# repairing the fault it is asserting by accident.
ct_fsck_repair() { "$ROOT/userspace/fsck.cetra" -r "$1"; }

ct_mount() {
    mount -t cetrafs "$1" "$2" || return $?
    ct_track mnt "$2"
}
ct_umount() { umount "$1"; }

# The standard small test volume: one ZG, one 512 MiB BG, no journal,
# 1024 inodes. Most suites want exactly this.
ct_mkfs_small() { ct_mkfs "$1" -z 1 -b 512 -J 0 -N 1024 -f "${@:2}"; }

# -------------------------------------------------------- preconditions
require_root() {
    [ "$(id -u)" = "0" ] || {
        echo "must run as root" >&2
        exit 2
    }
}

# Loads the module if it is not already loaded, and unloads it at exit
# ONLY if this suite is what loaded it -- so a suite is runnable on its
# own, and the runner can also load once for a whole batch.
#
# Never rmmod -f: forcing removal while a superblock object is still
# alive leaves a dangling shrinker entry that Oopses on a later reclaim
# pass and corrupts the running kernel until reboot.
require_module() {
    # "|| true": crc32c may be built into vmlinux rather than a module, and
    # scsi_mod may already be resident. Neither is a reason to abort, and
    # under `set -e` an unguarded modprobe kills the suite before its
    # first assertion -- which prints no FAIL and no reason.
    modprobe libcrc32c 2>/dev/null || true
    modprobe scsi_mod 2>/dev/null || true
    # A module that is already present was loaded by someone else and
    # therefore does NOT carry the parameters the suites need -- notably
    # cas_selftest, which is armed at load and which
    # mount_and_superblock.sh asserts on. Silently adopting it (what
    # this did before) makes that suite fail for a reason that has
    # nothing to do with the filesystem. Take it over instead; adopt
    # only if it will not unload.
    # ...unless the BATCH RUNNER loaded it. run.sh loads once for the
    # whole batch, with these same parameters, and exports
    # CT_BATCH_MODULE so suites know to leave it alone. Taking that one
    # over would unload the module out from under run.sh's own
    # bookkeeping, which then reports "rmmod: not currently loaded" at
    # the end of the batch.
    if [ "${CT_BATCH_MODULE:-0}" != "1" ] && { lsmod | grep -q '^cetrafs ' || [ -d /sys/module/cetrafs ]; }; then
        if rmmod cetrafs 2>/dev/null; then
            for _w in $(seq 1 300); do
                [ -d /sys/module/cetrafs ] || break
                sleep 0.2
            done
        else
            echo "note: a cetrafs module is loaded and will not unload; running against it." >&2
            echo "      insmod parameters are NOT applied, so parameter-dependent suites may fail." >&2
        fi
    fi

    if ! lsmod | grep -q '^cetrafs ' && [ ! -d /sys/module/cetrafs ]; then
        ct_build
        # cas_selftest=1: exercise cetrafs_cas_record() once per mount. On a
        # loop device there is no atomic CAW, so this covers the no-CAW
        # fallback -- the path real hardware never takes, and therefore the
        # one nothing else exercises.
        if ! insmod "$ROOT/kmod/cetrafs.ko" cas_selftest=1 "$@" 2>/dev/null; then
            # "File exists" here is the previous suite's rmmod still
            # settling: delete_module can return before the module is fully
            # out of the kernel's list, so this insmod races it. Wait for
            # the module to be genuinely GONE, then load it ourselves --
            # do NOT adopt a module we did not load (two suites each
            # unloading one instance is how "rmmod: not currently loaded"
            # happens). If it never clears, it is a real leftover and
            # loading is correctly fatal.
            # ct_unload_module() already waits for the module to clear before
            # a suite exits, so this consumer-side backstop should rarely
            # spin -- a real leftover that outlasts it is correctly fatal.
            # 30s, not 10. A module can sit in "Dying" -- gone from
            # lsmod but still present to insmod, which reports "File
            # exists" -- for as long as its teardown takes, and on a
            # node that has had a real LUN mounted (many cached inodes,
            # a slow rcu_barrier on a big machine) that is well past
            # 10s. Measured on a production node: every one of 112
            # kernel suites aborted this way in a release run, which
            # read as a build failure rather than a busy machine.
            loaded=0
            why=""
            for _try in $(seq 1 30); do
                lsmod | grep -q '^cetrafs ' && { sleep 1; continue; }
                why="$(insmod "$ROOT/kmod/cetrafs.ko" cas_selftest=1 "$@" 2>&1)" && { loaded=1; break; }
                # "File exists" is not a failure to diagnose, it is the
                # kernel telling us a module of this name IS present --
                # whatever lsmod says. ADOPT it: proceed, and leave
                # CT_MODULE_LOADED unset so we do not unload something we
                # did not load.
                #
                # This is why 112 suites aborted in a release run: the
                # module was loaded the whole time (the batch's final
                # rmmod succeeded), yet each suite's lsmod probe said
                # otherwise and each then burned the full retry. Trust
                # the kernel's answer over the probe's.
                case "$why" in
                    *"File exists"*)
                        # A module of this name IS present, whatever
                        # lsmod says. PREFER taking it over: unload it
                        # and load ours, so the suite actually gets the
                        # insmod parameters it asked for -- a suite run
                        # under parameters it did not get is a test that
                        # proves nothing (cas_selftest is asserted on,
                        # and it is armed at load).
                        if rmmod cetrafs 2>/dev/null; then
                            for _w in $(seq 1 300); do
                                [ -d /sys/module/cetrafs ] || break
                                sleep 0.2
                            done
                            why="$(insmod "$ROOT/kmod/cetrafs.ko" cas_selftest=1 "$@" 2>&1)" &&
                                { loaded=1; break; }
                        fi
                        # Could not take it over (in use, or it will not
                        # unload): adopt it rather than hang, and the
                        # caller is told its parameters were not applied.
                        loaded=2
                        break
                        ;;
                esac
                sleep 1
            done
            # Say WHY. A bare "insmod failed" sent a day of debugging
            # after the wrong thing; the kernel's own message
            # distinguishes a stuck module ("File exists") from a bad
            # build ("version magic", "Unknown symbol") instantly.
            # NOT a return: everything below this block -- dynamic
            # debug, the auto_defrag default, CT_DMESG_MARK -- still has
            # to run. Returning early here skipped it and every suite
            # died on "CT_DMESG_MARK: unbound variable" under set -u.
            # Adopting a module means we did not LOAD it, nothing more.
            [ "$loaded" = 1 ] || [ "$loaded" = 2 ] || {
                echo "insmod failed after 30s: ${why:-(no message)}" >&2
                echo "  module still present? $(lsmod | grep -c '^cetrafs ') in lsmod," \
                     "/sys/module/cetrafs $([ -d /sys/module/cetrafs ] && echo exists || echo gone)" >&2
                exit 2
            }
        fi
        # Only when WE loaded it -- an adopted module ("File exists",
        # loaded by someone else) must not be unloaded by our ct_exit.
        if [ "${loaded:-1}" = 2 ]; then
            # An adopted module did not get our insmod parameters, so
            # apply the ones that matter through sysfs. cas_selftest is
            # the one a suite actually asserts on (mount_and_superblock
            # checks the selftest ran), and it is writable 0644 because
            # it is consulted per mount rather than at load.
            echo 1 >/sys/module/cetrafs/parameters/cas_selftest 2>/dev/null || true
            # Anything else the caller asked for cannot be applied to a
            # module we did not load -- say so rather than run a suite
            # under parameters it did not get.
            [ "$#" -gt 0 ] && echo "note: adopted an already-loaded module; insmod args ignored: $*" >&2
        else
            CT_MODULE_LOADED=1
            # Tell suites spawned by this shell that the module is ours
            # and already carries the right parameters.
            export CT_BATCH_MODULE=1
        fi
    fi
    # Several suites assert on trace lines that are pr_debug() in
    # production (auto-defrag per-file lines, "pending free: ... drained",
    # the per-tick ZG claim count): enable the module's dynamic debug so
    # they land in dmesg for the suite's lifetime. Cleared automatically
    # when the module unloads; "|| true" because a kernel without
    # CONFIG_DYNAMIC_DEBUG has no control file -- there pr_debug is
    # compiled out and the suites that need those lines fail loudly,
    # which is the honest outcome rather than a silent skip.
    echo 'module cetrafs +p' >/sys/kernel/debug/dynamic_debug/control 2>/dev/null || true
    # Auto-defrag is on by default in production but must be OFF for the
    # suites at large: many build deliberately fragmented files for
    # unrelated reasons, and the background janitor would relocate them
    # mid-test. The defrag suites turn it on locally and off again.
    [ -w /sys/module/cetrafs/parameters/auto_defrag ] &&
        echo 0 >/sys/module/cetrafs/parameters/auto_defrag
    CT_DMESG_MARK="${CT_DMESG_MARK:-$(dmesg_mark)}"
    ct_snapshot_params
    return 0
}

# ---------------------------------------------------- module parameters
#
# Several suites turn a module parameter on or off for a section and are
# expected to put it back -- the failure-injection knobs, the heartbeat
# interval, auto_defrag. A suite that forgets leaves that state for
# every LATER suite sharing the module load, and the symptom is not an
# error: it is a later suite quietly testing something other than what
# it says. `make check` masks this because each suite rmmods at exit,
# which is exactly why it would go unnoticed until someone ran suites by
# hand against one load.
#
# Checked rather than left to each suite's own discipline. Restoring
# silently was the other option and is worse: a suite that leaks has a
# bug in it, and the point is to be told.
ct_snapshot_params() {
    CT_PARAM_SNAPSHOT="$(ct_param_state)"
}

ct_param_state() {
    local f
    for f in /sys/module/cetrafs/parameters/*; do
        [ -r "$f" ] || continue
        echo "$(basename "$f")=$(cat "$f" 2>/dev/null)"
    done
    # Explicit: a for loop returns its last command's status, so a final
    # unreadable (write-only) parameter file made this return 1 -- and
    # under `set -e` the caller's `now="$(ct_param_state)"` then killed
    # the suite silently, mid-check, with no output at all. That is the
    # same shape as the hang P4 added a timeout for: a check that
    # disappears is worse than one that fails.
    return 0
}

# Change a module parameter for the life of this suite, restoring it at
# exit. Use this rather than writing to /sys directly: a suite that
# forgets to restore leaves the state for every later suite sharing the
# module load, and ct_check_params() below will fail it.
ct_param_set() { # <name> <value>
    local f="/sys/module/cetrafs/parameters/$1"
    [ -w "$f" ] || { fail "module parameter $1 is not writable"; return 1; }
    if [ -z "${CT_PARAM_RESTORE_SET:-}" ] || ! printf '%s' "$CT_PARAM_RESTORE_SET" | grep -q "^$1\$"; then
        CT_PARAM_RESTORE="${CT_PARAM_RESTORE:-}$1 $(cat "$f")
"
        CT_PARAM_RESTORE_SET="${CT_PARAM_RESTORE_SET:-}$1
"
    fi
    echo "$2" >"$f"
}

ct_param_restore_all() {
    [ -n "${CT_PARAM_RESTORE:-}" ] || return 0
    [ -d /sys/module/cetrafs/parameters ] || return 0
    local name val
    while read -r name val; do
        [ -n "$name" ] || continue
        [ -w "/sys/module/cetrafs/parameters/$name" ] && echo "$val" >"/sys/module/cetrafs/parameters/$name"
    done <<EOF
$CT_PARAM_RESTORE
EOF
    return 0
}

ct_check_params() {
    [ -n "${CT_PARAM_SNAPSHOT:-}" ] || return 0
    [ -d /sys/module/cetrafs/parameters ] || return 0
    local now changed
    now="$(ct_param_state)"
    if [ "$now" = "$CT_PARAM_SNAPSHOT" ]; then
        pass "no module parameter was left changed"
        return 0
    fi
    # `|| true`: diff exits 1 when the inputs differ, which is precisely
    # the case being reported, and under `set -o pipefail` that status
    # propagates and `set -e` then kills the suite -- silently, right
    # after computing the answer. Third time this project has been bitten
    # by a tool whose nonzero exit IS the finding (both earlier cases were fsck).
    changed="$( (diff <(echo "$CT_PARAM_SNAPSHOT") <(echo "$now") || true) | grep '^>' | sed 's/^> //' | tr '\n' ' ')"
    fail "module parameters left changed: $changed-- restore them, or a later suite inherits the state"
}

# Assert a path really is on a cetrafs mount before asserting anything
# about its contents. Three times in this project's history a run
# reported success while writing to the HOST filesystem through a
# mountpoint that was just an ordinary directory.
require_cetrafs_mount() {
    local mnt="$1"
    awk -v m="$mnt" '$2 == m && $3 == "cetrafs" { found = 1 } END { exit !found }' \
        /proc/self/mounts || {
        echo "harness: $mnt is not a cetrafs mount -- refusing to assert against it" >&2
        exit 2
    }
}

# ----------------------------------------------------------- staleness
#
# Staleness is NOT "last_seen is old by MY clock" any more. That compared
# two machines' wall clocks and, on a real pair 1h55m apart, made the
# node that was ahead treat its LIVE peer as dead, break its namespace
# lock and lose 85 of 200 directory entries. A peer is stale when its own
# hb_seq stops advancing for stale_secs of the OBSERVER's clock.
#
# So a test cannot fake staleness with a timestamp: it has to leave a
# row's hb_seq still and let the window pass. Both the window and the
# tick are module params so that costs seconds, not a minute.
CETRAFS_STALE_PARAM=/sys/module/cetrafs/parameters/stale_secs
CETRAFS_HB_PARAM=/sys/module/cetrafs/parameters/hb_interval_secs
# Both windows are compressed hard. The real values (60s stale, 15s
# tick) would make this suite spend minutes asleep: before these were
# used consistently, two suites waiting on the DEFAULT 15s tick
# (`sleep 25`, `sleep 18`) were 35 of the suite's 210 seconds on their
# own. Nothing here needs the production numbers -- what is under test
# is "a tick observes it", not how long a tick takes.
TEST_STALE_SECS=3
TEST_HB_SECS=1

# Compress the heartbeat tick AND the staleness window together. Call it
# in any suite that waits for a tick to do something; call
# reset_stale_window() when done, since both are module-global.
compress_timing() { set_stale_window "$TEST_STALE_SECS"; }

set_stale_window() {
    # Through ct_param_set so both are restored at ct_exit: these are
    # module-global, and a suite that compressed them and did not reset
    # left every later suite on a 1s tick and a 3s staleness window --
    # which is not a failure, just a different filesystem than the one
    # those suites meant to test.
    ct_param_set stale_secs "$1"
    ct_param_set hb_interval_secs "$TEST_HB_SECS"
    return 0
}

# Park a row as a peer that registered and then died: REGISTERED, a
# nonzero last_seen (0 means "left cleanly", a different path), and an
# hb_seq nobody will ever bump again.
poke_dead_peer() {
    "$(ct_helper node_poke)" "$1" "$2" 1 "$3" "$(date +%s)" >/dev/null
}

wait_out_stale_window() { sleep $((TEST_STALE_SECS + 2)); }

# Put the window back. The params are module-global, so leaving them
# compressed would quietly rot any later section that poses a row as a
# LIVE peer: such rows have a frozen hb_seq and would turn stale partway
# through the assertion that depends on them being alive.
reset_stale_window() {
    [ -w "$CETRAFS_STALE_PARAM" ] && echo 60 >"$CETRAFS_STALE_PARAM"
    [ -w "$CETRAFS_HB_PARAM" ] && echo 15 >"$CETRAFS_HB_PARAM"
    return 0
}
