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
make soak ROUNDS=20            # module must already be loaded; see "Unattended soak"
make -C tests matrix           # a suite slice under each mount/geometry configuration

make mod KASAN=1               # build for a KASAN kernel, then run as usual
make mod LLVM=1                # build with clang (diagnostics; see below)
```

`make check` is the single CI entry point.  It exits nonzero if any
assertion failed **or** if any suite aborted without failing one -- the
mode that otherwise prints no summary and reads exactly like success.

Needs root, `linux-headers-$(uname -r)`, and a few loop devices.  The
runner builds the tree and loads the module once for the batch; a suite
run on its own does both itself, so either works.

Every suite runs under a 300 s deadline, because a wedged buffer lock
shows up as a hang, not as a failure. A suite that legitimately needs
longer says so in a `# ct-timeout: <seconds>` line of its own header
(only `kernel/growfs.sh` does); `CT_SUITE_TIMEOUT` overrides all of them.

`device/` and `stress/` are never part of a group run: they take
arguments, and one of them reformats whatever you name.

### Clean up after a killed run, before starting the next one

A gate that is interrupted does not unwind: it leaves its image, 2-3
GiB of it, plus possibly a mount, a loop device and the module. The
next run then starts with less room, dies earlier, and leaves another
one. Five accumulated images took a box from comfortable to 8004 MiB
free against the 7168 MiB floor, at which point every further run
aborted instantly -- and from the inside that reads as runs failing
for no reason, not as a disk problem.

```
pgrep -af 'run.sh|make check'            # nothing else running?
umount <any cetrafs mount>; rmmod cetrafs
losetup -D                               # free stray loop devices
rm -f /root/cetrafs-*.img /tmp/cetrafs-*.img
df -Pm /                                 # must clear CT_MIN_FREE_MB (7168)
```

### Running under KASAN

`make mod KASAN=1` and then the ordinary suites. The flag only raises
the pinned stack-frame budget to 2048 for that build: KASAN's redzones
sit between locals, so a function measuring 900 bytes in the build that
ships measures ~1300 under it, and the pin would reject a kernel it was
never written to describe. Nothing else about the module changes.

Worth doing: this build is what surfaced a four-deep recursion carrying
half a kilobyte per frame, which a per-frame budget cannot see.

**Do not expect it to cover field overreads.** KASAN instruments the
bounds of allocations, not of fields inside them. A dirent claiming a
4000-byte name is read out of a 255-byte field inside a 4096-byte
block: the read never leaves the allocation and there is no report.
Measured by removing the `name_len` validation and firing the poke from
`hostile_fields.sh` -- silence. Those fields are defended by the
explicit check at block-read time, and only by it.

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
`fence_witness_cost.sh` measures what the fence witness read costs per
operation (append, create, overwrite) with the witness on and off; a
loop device serves that read from the host page cache, so only an array
gives the real figure.

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

**A failing assertion must SAY why, and `os._exit()` loses it.**  A
suite's helper is usually a `python3 - <<'PY'` heredoc that prints what
went wrong and then exits non-zero.  `os._exit()` skips the exit
handlers, so a block-buffered stdout -- which it always is, piped to the
runner -- is discarded: the suite correctly reports FAIL and prints
nothing about it.  Call `sys.stdout.flush()` first, or use `sys.exit()`.
Four suites in this tree had it, including one that was silently
swallowing the reason for a SKIP.

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

**A poke must go through whatever is going to READ it.**  A loop device
and its backing file are the same bytes through two independent page
caches, and which one is right depends on the reader.  fsck reads the
device, so a fault fsck must see is poked into the device.  A mounted
kernel simulating a *peer's* write is the opposite: poking the file is
precisely how the change is made invisible until the node re-reads,
which is the only way to simulate a peer on a one-node harness -- every
"did it read fresh?" suite depends on it, and poking the device there
puts the change straight into the cache the filesystem's own buffers
are mapped onto, so the node sees it without re-reading and the
assertion passes while testing nothing.

The bug is a MISMATCH.  `kernel/fsck_repair.sh` poked the file where
fsck, reading the device, had to see it: fsck's own earlier reads left
pages cached on the device, the poke landed behind them, and fsck
checked the volume as it was before the fault was injected.  Only ever
under a full batch, because whether those pages were still resident
depended on what every other suite had done first.
`image/lint_poke_target.sh` flags that exact shape.

Two remedies, both valid: poke the device (direct, for a fault only fsck
needs to see), or keep poking the file and `blockdev --flushbufs "$DEV"`
before each read.  The second is the older house style and the reason is
written down in `image/fsck_negative_controls.sh`, which hit this while
`fsck_checksum_controls.sh` was being written -- "the same case passed
and failed across consecutive runs ... this suite has always had the
same exposure and passed on cache luck".  Keep the file poke wherever
the invisibility is the point.

The mismatch runs the other way too.  A WRITE through the device sits
dirty in its page cache, and writeback can land it on the backing file
at any later moment -- over a file poke made after it.
`kernel/zg_steal_vs_reattach.sh` set a Zone Group's owner through the
device, then played the owner's re-assert into the file; the stale
dirty page was written back over the re-assert, and the suite failed 3
runs in 5 with nothing wrong in the kernel.  Flush the device
(`blockdev --flushbufs`) between a device write and any later file
poke.  `lint_poke_target` cannot see this one: it cannot tell a helper
that writes the device from one that only dumps it.

**Capture, then match -- never `producer | grep -q` as a condition.**
Under `set -o pipefail` a pipeline carries the *producer's* exit status,
and several producers here exit non-zero BY DESIGN: `fsck` on a bad
image, `mkfs` printing usage, `growfs` refusing.  So
`if fsck "$DEV" | grep -q 'the error'; then` is non-zero whether or not
grep matched, and both branches can reach a pass -- a check that cannot
fail.  Write `out="$(fsck "$DEV" 2>&1 || true)"` and then
`grep -q 'the error' <<<"$out"` -- a HERESTRING, not a pipe.

**And `printf '%s' "$out" | grep -q ...` is the same bug wearing a
different hat.**  `grep -q` exits at the first match, the `printf`
feeding it takes SIGPIPE, and `pipefail` reports 141 -- so the pipeline
says FAILED about a match that succeeded.  It depends on whether
`printf` finishes before `grep` exits, so it passes on small output and
fails on large output or under load: measured at 0 failures on a short
string and **200 out of 200** on a 400 KB one.  Two suites flaked this
way inside the full gate while passing standalone, and the second cost
an hour of looking for a mechanism that was in the shell, not the
filesystem.

Note which way it breaks.  "Output must CONTAIN x" fails loudly and
gets noticed.  "Output must NOT contain x" **passes** -- so a check for
an error message that really is present reports clean.  Prefer
`grep -q PATTERN <<<"$var"` or `case "$var" in *x*)`; both measured at
0 failures.
This has been got wrong three separate times: `run_fsck` in
`image/fsck_negative_controls.sh`, the fsck-reason check in
`kernel/growfs.sh`, and `growfs_compat.sh`'s "is this really the old
mkfs?" guard -- which was then re-broken a second way (running `mkfs`
against `/dev/null`, where it dies before printing the usage text it
was being searched for).

**A green gate after a fully-explained failure buys nothing.**  The
gate's value is covering what you did NOT reason about.  When a run
produces one failure, you know its mechanism, and the fix is confined
to what failed, re-running all ~6,600 assertions re-verifies code that
already passed on that same tree -- 18 minutes to learn something you
were already told.  Run the affected suites instead.

The test is whether anything UNEXAMINED changed.  Re-run the gate when
the fix touched `kmod/` or `userspace/` (a change there is validated by
the full `make check` and nothing less -- CLAUDE.md), when you are not
certain why the thing failed, or when the fix was broad enough that you
cannot name what it could have disturbed.  Do not re-run it to feel
better about an assertion rewrite whose mechanism you have measured.

The failure mode this guards against is not wasted minutes, it is
attention: a gate you run reflexively is a gate you stop reading.

**Set up what you depend on.**  Every suite starts from its own fresh
image.  A suite that needs a dead peer in row 1 must *create* one: an
absent row also reads as stale, so the assertions would pass for
entirely the wrong reason.

## Randomized data and namespace suites

Four suites are driven by seeded random streams, each checked against a
model the tool keeps in memory. They are the tools that find what the
fixed-shape suites cannot, so they are part of `check` at a modest size.

| suite | tool | what it checks |
|---|---|---|
| `kernel/fsx_model.sh` | `helpers/fsx_cetra.c` | one file: buffered and mapped I/O, truncate, fallocate (allocate, keep-size, punch, zero-range), O_DIRECT, fsync, reopen; every read against the model; a remount compare |
| `kernel/fsstress_namespace.sh` | `helpers/fsstress_cetra.c` | several processes: create, link, symlink, rename (over, across directories), rmdir, xattrs, chmod; per-process model, a shared directory held to the errno contract; fsck |
| `kernel/fio_verified_io.sh` | `/usr/bin/fio` | a 1 GiB sparse file, buffered and O_DIRECT jobs on disjoint regions, in-run verify, verify-only after a remount; skips with a reason when fio is absent |

`fsx_cetra` and `fsstress_cetra` are our own C, built by `ct_helper`
like the poke tools. Neither is vendored from xfstests, and neither needs
it.

Every one has a **negative control** that corrupts the tool's model on
purpose and requires the run to fail for that reason:
`FSX_NEGATIVE=<op>` (fsx), `FSSTRESS_NEGATIVE=1` (fsstress), and a
corrupted data block on the device between the write and the verify
phases (fio). A checker that passes with a wrong model is not a checker.

A failure prints what replays it. fsx prints the seed, op index and the
last 16 ops; rerun with `FSX_SEED=<seed> FSX_OPS=<ops>`. fsstress prints
seed, process and op; rerun with `FSSTRESS_SEEDS=<seed>`.

**Long runs** stay out of `check`:

```
FSX_LONG=1 ./tests/run.sh kernel/fsx_model.sh          # 8 seeds x 40000 ops
FSSTRESS_LONG=1 ./tests/run.sh kernel/fsstress_namespace.sh   # 8 procs x 5000 ops
FSX_SEED=17 FSX_OPS=40000 ./tests/run.sh kernel/fsx_model.sh  # one seed, replay
```

`tests/helpers/fsx_cetra` also takes `FSX_DUMP=<path>` (model contents,
for an external byte compare) and `FSX_DROPCACHE=1` (drop the page cache
before each full check, as root).

## Configuration matrix

`tests/matrix.sh` runs a slice of the kernel suites under each of several
configurations. The configurations are mount options and mkfs geometry
that the gate itself does not vary:

| configuration | what it changes | why it matters |
|---|---|---|
| `base` | nothing | the gate's own geometry, for comparison |
| `nofilelock` | `-o nofilelock` on every `ct_mount` | the cluster lock mode is a change of semantics, not a tuning knob; it produced two bug families |
| `bg1g` | `-b 1024`, images at least 2300 MiB | two 1 GiB Block Groups: BG-boundary arithmetic |
| `zg4` | `-z 4`, images at least 2300 MiB | four Zone Groups over four Block Groups |
| `journal8` | `-J 8`, images at least 2300 MiB | an 8 MiB journal per node slot; mkfs reserves a slot for each of up to 64 nodes, about 512 MiB, which the 560 MiB images cannot hold |

```
make -C tests matrix                            # every configuration, the default slice
make -C tests matrix CONFIGS="nofilelock bg1g"
tests/matrix.sh zg4
MATRIX_SUITES="kernel/fsx_model.sh" tests/matrix.sh base  # any slice you name
```

The matrix drives the suites through three harness overrides, all unset
by default, so the gate is unchanged:

- `CT_MOUNT_OPTS` -- extra `-o` options for every `ct_mount`;
- `CT_MKFS_EXTRA` -- extra `mkfs.cetra` arguments, appended after the
  suite's own (mkfs reads options with `getopt`, so the last one wins);
- `CT_IMG_MIN_MB` -- a floor on the size of images the suites create, so
  a larger Block Group or more Zone Groups has room to exist.

A suite that mounts with its own `-o`, or that assumes one Block Group,
is not in the default slice, and a suite added to the slice must say so
in its header if it depends on the geometry. Logs go to `CT_MATRIX_DIR`
(default `${CT_BIG_DIR:-/root}/cetrafs-matrix`), one per configuration.
The matrix exits 1 if any configuration fails a suite.

## Unattended soak

`make soak` is runnable with no terminal and no operator. It is bounded,
it writes a report, and its exit status says whether it found anything.

```
make soak ROUNDS=200 SOAK_MAX_SECS=7200     # stop starting rounds after two hours
```

- `SOAK_MAX_SECS` -- stop starting new rounds after this many seconds
  (0, the default, means no limit). A round in progress is finished.
- `SOAK_DIR` -- scratch directory for images, the mountpoint, the mkfs
  log and the report (default `${CT_BIG_DIR:-/root}/cetrafs-soak`). Not
  `/tmp`: a 700 MiB image per round does not fit a tmpfs.
- `SOAK_REPORT` -- the report file (default `$SOAK_DIR/report.txt`). One
  line per round, then a `SUMMARY` line that is always last.
- `SOAK_RANDOM` -- 1 (default): after the mixed rounds, the randomized
  suites in their long modes with a fresh seed per cycle -- `fsx_model`
  (`FSX_LONG`), `fsstress_namespace` (`FSSTRESS_LONG`), `churn_oracle`
  (6 rounds of 60 s). One cycle always runs; more follow while the
  deadline allows. A failure is a report line naming the suite and seed,
  its output kept as `random-fail-N.log`. They run through `tests/run.sh`,
  which loads the tree's own build. 0 skips them. Control:
  `FSX_NEGATIVE=150` must make the soak exit 1 naming `fsx_model`.

Exit status: **0** every round that ran was clean and the run reached its
end (the round count or the deadline); **1** at least one round was
anomalous (an operation failed or fsck reported a problem) or aborted (mkfs
or mount failed) -- the failing image is kept as `mix-fail-N.img`; **2** a
precondition failed (module not loaded, scratch directory unusable), so
nothing ran. The module must be loaded before the run; the soak does not
load it.

The loop device and the mount are released on every exit, including an
interrupt, so one run never leaves a mount for the next.

**Scheduling** is left to the operator, and nothing in the tree installs
a unit. A cron entry that runs the soak nightly and keeps its output:

```
# /etc/cron.d/cetrafs-soak   (example; copy it, adjust the paths)
30 1 * * * root cd /path/to/cetrafs && SOAK_MAX_SECS=7200 make soak ROUNDS=500 >>/var/log/cetrafs-soak.log 2>&1
```

A systemd timer is the same command in a `.service` (`Type=oneshot`,
`ExecStart=/usr/bin/make -C /path/to/cetrafs soak ROUNDS=500`, with
`Environment=SOAK_MAX_SECS=7200`) and an `OnCalendar=*-*-* 01:30:00`
`.timer`. The oneshot unit's failure is the exit status, so an anomaly
shows as a failed unit; the report is in `SOAK_DIR`.

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
| `require_file_lock_mode <premise>` | skips, naming the premise, under `CT_MOUNT_OPTS=nofilelock` -- only for behaviour that does not exist in that mode; a hazard the mode reaches by another path is tested on that path |
| `ct_mode_own` | the suite sets each mount's mode itself (it compares the two), so `CT_MOUNT_OPTS` is ignored |
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
