# cetrafs tests

Four layers, in increasing cost and decreasing reach.  Everything below
`tests/` is one of: a **suite** (an executable `.sh` that asserts things),
a **helper** (a small C tool that corrupts or inspects a raw image), or
the **harness** they share.

```
tests/
  run.sh                 run one suite, or a whole group
  Makefile               the targets CI and humans use
  README.md              this file
  lib/harness.sh         reporting, resources, preconditions, cleanup
  helpers/               *.c poke tools + their own README
  image/                 no kernel module, nothing mounted  -- seconds
  kernel/                loaded module + loop-backed mount  -- minutes
  device/                a REAL device, DESTRUCTIVE         -- opt-in
  stress/                long mixed-workload runs           -- opt-in
```

## Running

```
make check                     # image + kernel: the regression set (root)
make -C tests image            # image-level only, seconds, no module
make -C tests kernel           # everything needing the module
make -C tests list             # every suite with its one-line purpose
make check-one SUITE=kernel/nslock.sh
./tests/run.sh kernel/nslock.sh kernel/dir_growth.sh

make check-caw DEV=/dev/sdX    # DESTRUCTIVE: reformats that device
make check-slow                # slow sparse/s_maxbytes test (loop-backed)
make soak ROUNDS=20            # module must already be loaded
```

`make check` is the single CI entry point.  It exits nonzero if any
assertion failed **or** if any suite aborted without failing one -- the
mode that otherwise prints no summary and reads exactly like success.

Needs root, `linux-headers-$(uname -r)`, and a few loop devices.  The
runner builds the tree and loads the module once for the batch; a suite
run on its own does both itself, so either works.

`device/` and `stress/` are never part of a group run: they take
arguments, and one of them reformats whatever you name.

## What is where

**`image/`** -- mkfs writes the structures, a helper corrupts one, fsck
must notice.  No module, nothing mounted, runs in seconds.  This is the
right home for any check that does not need a live filesystem.

**`kernel/`** -- a loaded module and a loop-backed mount.  One concern per
suite, each with its own image, its own mount and its own cleanup.  The
file names are the index: `make -C tests list`.

**`device/`** -- needs real hardware.  `caw_compare_and_write.sh` is the
only thing that exercises the atomic COMPARE AND WRITE itself: a loop
device has no CAW, so `cetrafs_cas_region()` takes its plain fallback
there and the primitive every claim path rests on is never really run.

**`stress/`** -- slow, opt-in, loop-backed.  `soak.sh` is a mixed
workload with a full fsck after every round (deliberately does not
insmod, so it exercises whatever build you point it at);
`sparse_bigfile.sh` builds a multi-GiB volume to check `s_maxbytes`
enforcement and a near-max sparse file surviving a remount.

**`ctest/`** (not under `tests/`) -- the two-node suite against a shared
LUN.  The only thing that exercises cross-node paths at all; several
classes of bug in this codebase are structurally unreachable without it.

## The rules

These are not style preferences.  Each one is here because this project
shipped a green run over broken code when it was violated.

**A test that cannot fail is worse than no test.**  Three separate times
a run reported success while never touching the filesystem: the module
was not loaded and the "mount" wrote to the host fs; an `mkfs` failure
was ignored and a stale image mounted; a `set -e` abort skipped every
remaining assertion and printed no summary.  Hence
`require_cetrafs_mount`, hence the runner's ABORT verdict, hence the
summary printed from the cleanup trap rather than the end of the script.

**Prove the assertion discriminates.**  Before claiming anything is
tested, revert the fix (or disable the check) and watch *that* assertion
fail.  Record which ones discriminate and which pass either way -- an
assertion whose discriminating power you have not measured is a guess.

**Beware the thing that catches the fault first.**  The fence-lease tests
asserted that a revoked lease gets noticed, and it always was -- by the
heartbeat's pre-check, which runs before the renew and jumps straight to
the reschedule.  The renew's own blind write, the code that actually held
the bug, was never reached: seven green assertions, zero coverage.  The
fix is to make the code under test the SOLE path to the observable, with
a test-only module param if something else short-circuits it
(`fence_skip_precheck` is the precedent).

**Distinguish three outcomes, not two.**  "clean", "failed for the wrong
reason", and "caught it".  Disabling fsck's cross-ZG pending-free check
left fsck still exiting nonzero -- the bitmap pass flags the same block --
so a control that only checked the exit code would have proven nothing.
The same bit cross-node: an `mkfs` that refuses a live peer's volume must
be checked to refuse *for that reason*, not merely to fail.

**A suite must fail, not abort.**  Under `set -e` an unguarded command
that returns nonzero ends the run with no FAIL line and no summary.
Guard anything expected to fail, and assert on its output.

**Set up what you depend on.**  Every suite starts from its own fresh
image.  A suite that needs a dead peer in row 1 must *create* one: an
absent row also reads as stale, so the assertions would pass for
entirely the wrong reason.

## Adding a suite

```sh
#!/usr/bin/env bash
# one line: what this proves          <-- `make -C tests list` prints this
#
# A paragraph on why it exists: the bug it guards against, what breaks if
# it regresses, and anything subtle about why it is written this way.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/harness.sh"
require_root
require_module                       # kernel/ suites only

DEV="$(ct_dev 560 mysuite)"          # tracked image + loop device
MNT="$(ct_mnt mysuite)"              # tracked mountpoint
ct_mkfs_small "$DEV" >/dev/null
ct_mount "$DEV" "$MNT"
require_cetrafs_mount "$MNT"         # never assert against a host directory

log "checking the thing"
... && pass "the thing holds" || fail "the thing did not hold: $detail"

ct_exit
```

The harness gives you:

| | |
|---|---|
| `log` `pass` `fail` `skip` | reporting; `skip` is not a pass and is printed |
| `ct_image` `ct_loop` `ct_dev` `ct_mnt` `ct_tmp` | resources, auto-removed in reverse on **every** exit path |
| `ct_mkfs` `ct_mkfs_small` `ct_fsck` `ct_mount` | the tools |
| `ct_helper <name>` | compiles `helpers/<name>.c` on demand, cached in `.build/` |
| `require_root` `require_module` `require_cetrafs_mount` | preconditions |
| `dmesg_mark` `dmesg_since` | timestamp-based, immune to ring-buffer wrap |
| `set_stale_window` `poke_dead_peer` `wait_out_stale_window` `reset_stale_window` | node liveness |
| `ct_exit` | exit 1 if anything failed, whatever the last command returned |

Every suite automatically checks dmesg for `BUG:`/`Oops`/`Call trace`/
`WARNING:` over its own run and reports it as an assertion.  A suite that
legitimately provokes a kernel warning sets `CT_ALLOW_DMESG_WARN=1` and
says why.

**Never `rmmod -f`.**  Forcing removal while a superblock object is still
alive leaves a dangling shrinker entry that Oopses on a later reclaim
pass and corrupts the running kernel until reboot -- reproduced firsthand
on this project's VM.  The harness never forces, and neither should you.

## Known gaps

Stated here so nobody infers coverage that does not exist:

- **Cross-node anything.**  A single kernel cannot reproduce a real
  two-node race: reader and writer share one buffer cache and serialise
  on the buffer lock.  The `kernel/` suites that carry cross-node names
  (`inode_record_staleness`, `extent_leaf_staleness`,
  `dirent_tail_checksum`, `inode_generation`) simulate a peer by poking
  the raw image; they are regression guards, never proof.  `ctest/` is
  the proof.
- **The pending-free append side** is unreachable here: with one node
  every ZG is owned locally, so every free is correctly direct.
- No suite covers `.mmap`, `.llseek`, `.sync_fs`, or `.write_inode`
  reached through VFS writeback.
