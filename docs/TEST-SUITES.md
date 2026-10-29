# How cetrafs is tested

cetrafs is a clustered filesystem. A bug here does not crash a program
-- it silently returns the wrong bytes, months later, on somebody's VM
disk. So the test effort is deliberately larger than the feature work,
and it is layered: each tier catches a class the tier above it
structurally cannot.

This document is a map of that effort -- the AUTOMATED suites that run
against every change.

Two neighbours, so you land on the right one:

- `docs/TESTING.md` is the DEPLOYMENT test plan: how to validate a real
  installation layer by layer (SAN, hypervisor, single node, cluster,
  full stack) and isolate which layer a fault came from.
- `tests/README.md` is the harness API and the rules for writing a
  suite.

---

## The one command

```
make check
```

That is the gate. It runs every suite under `tests/image/` and
`tests/kernel/` -- **164 suites, about 1757 individual assertions** --
against a loop-backed volume, and exits nonzero if any assertion fails
OR if any suite aborts without failing one. Nothing ships on a red gate.

It needs root and matching kernel headers. `make -C tests list` prints
every suite; `make check-one SUITE=kernel/<name>.sh` runs one.

Before starting, `run.sh` verifies free disk space: `tests/kernel/` needs
~7 GiB in the working directory, and `CT_MIN_FREE_MB` (default 7168) can
override the threshold. A full run aborts immediately if the space is not
available, rather than wasting 20+ minutes building a large image only to
fail at the last suite on ENOSPC.

### `tests/image/` -- the tools, with no kernel involved

17 suites. No module is loaded and nothing is mounted: `mkfs.cetra`
writes the structures, a poke helper corrupts exactly one of them, and
`fsck.cetra` must report *that* fault and exit nonzero.

This is where the on-disk format is pinned down -- superblock
validation, geometry, the version window that lets a previous release's
volume be grown rather than rebuilt, and the ~99 distinct faults
`fsck.cetra` can name.

### `tests/kernel/` -- the regression suite proper

147 suites, one concern each, against a loaded module and a real mount.
Roughly by area:

| area | what it covers |
|---|---|
| mount / superblock | validation, refusal of damaged or foreign volumes, remount |
| inode / dirent / dir | the namespace, directory growth past inline extents, cross-node reuse |
| file / extent / punch | the extent tree at depth 0/1/2, truncate, hole punch, sparse files, `fiemap`/`SEEK` |
| alloc / bg / zg | allocation, Block Group and Zone Group ownership, free accounting |
| lock / nslock | the whole-file exclusive lock, `flock(2)`, the per-inode namespace lock |
| journal | redo journalling and replay, including a dead node's journal |
| scrub / defrag | the background reclaim and the online defragmenter |
| growfs | growing a live volume |
| xattr | `user.*` / `trusted.*` / `security.*` and LSM labelling |

---

## The content oracle: `churn_oracle.sh`

Every suite above proves one *named* behaviour. That leaves a gap:
nobody writes a suite for a bug nobody has imagined. `churn_oracle.sh`
closes it.

Several processes hammer one volume at once with a weighted random mix
of creates, appends, overwrites, sparse writes, `O_DIRECT` writes,
truncates, hole punches, `fallocate`, renames, hard links, xattrs,
`fsync`, deletes and defrag calls -- while a separate thread drives
`sync` and drops the page cache underneath them, and the volume is run
to ENOSPC and released to force the allocator to hand the same blocks
out again.

What makes it more than a soak is that **every 4 KiB block is
self-identifying**. Content is a pure function of
`(seed, file id, generation, block index)`, and the first 32 bytes of
each block spell that tuple out. So a mismatch does not report
"corruption" -- it reports which *kind*:

| what the block says | what it means |
|---|---|
| another file's id | cross-file block overlap |
| this file, older generation | a lost publish or a stale extent |
| all zeros where data belongs | a dropped extent -- data loss |
| right tag, wrong payload | a torn write |
| data where a hole belongs | a punched or preallocated range serving stale blocks |
| no tag at all | a wild write |

Multiple gates run after each round: every file byte-exact warm, byte-exact
after `drop_caches`, byte-exact after an unmount and remount, `fsck` clean,
the background scrub's behaviour in quiet windows, orphan reclamation,
and the kernel log free of the allocator's own detectors. Specifically:

- Gate 1–3: content oracle — byte-exact on warm, cold (post-drop_caches), and after remount
- Gate 4: the scrub ran (not whether it reclaimed exactly zero — deleting a file can leave allocated nlink=0 inodes whose reclamation is deliberately deferred to the scrub)
- Gate 4b: no orphan inode survives two quiet scrub cycles (orphans are temporary by design)
- Gate 5: `fsck` clean
- Gate 5b: `fsck`'s own leaked-block count is zero (the only detector that counts unreachable orphan blocks, so this catches genuine leaks that gate 4 misses)

It is a net, not a proof -- a corruption that shows up in one fill in
fifteen needs more than one run. Tuning knobs (all optional; defaults run all):

- `CHURN_SEED`, `CHURN_ACTORS`, `CHURN_SECS`, `CHURN_ROUNDS`, `CHURN_FILES`, `CHURN_MAXBLK`: workload parameters
- `CHURN_SCRUB=0`: run without the background scrub (bisection handle)
- `CHURN_DEFRAG=0`: run without the online defragmenter (bisection handle)
- `CHURN_PRESSURE=0`: drop the concurrent sync/drop_caches loop (bisection handle)
- `CHURN_SCRUB=2`: arm the scrub only in the final quiet window (specific tuning)
- `CHURN_SETTLE`: idle before the final unmount (test the scrub's quiet window)
- `CHURN_SNAP`: snapshot the image at the remount boundary (evidence keeping)
- `CHURN_FSCK_MID`: run `fsck` at the snapshot point (evidence keeping)

---

## Bugs at one-in-millions odds, and what it takes to catch them

The 0.9 cycle is the proof of why this layering exists. Three real
data-corruption bugs shipped out of it, and none of them could have been
found by review, by a conventional regression suite, or by `fsck` --
their windows are measured in microseconds and their per-operation odds
in the millions.

**The orphan-scrub rebirth race.** The background scrub's orphan-inode
reclaim read a number's record, saw the PREVIOUS incarnation's dead
`nlink=0`, and freed the bitmap bit -- while a create was reusing the
number. The window between the verdict read and the free was measured
at **378 microseconds** on the tape that caught it; hitting it takes a
create landing on a just-recycled number in exactly that window, under
an orphan scan that happens to be passing that number. No deliberate
test provokes that. The randomized churn -- weighted random ops, many
actors, cache pressure, ENOSPC cycles -- compressed those odds to about
one failure in three seeded runs on a 112-core box, and because every
4 KiB block is self-identifying, the failure did not say "corruption":
it said *this block holds file 196619's block 0, and we are file 1* --
two files, one inode, and the forensic trail was already half-written.

**The recycled-identity latch.** A per-inode field initialized only by
the slab constructor -- which never runs on object recycle -- let a dead
file's defrag-dedup latch leak into whatever file next landed on that
slab slot, silently disabling its auto-defrag forever, and the same
class of inherited state (freshness caches, staged-write sequence
numbers) was one step from corrupting data. Stochastic by slab reuse
pattern: it surfaced only under full-gate load on amd64 boxes, never in
any isolated run, and wandered between five different suites before the
trace framework pinned it.

**The negative control that was itself a 1-in-256 flake.** The fsck
journal-payload check "altered" a random payload by writing a constant
byte -- which matched the random byte already there one run in 256,
making the alteration a no-op and the control a false failure. It took
dozens of full release matrices before it fired once.

What actually catches this class, in order of load-bearing:

1. **Randomized workloads with a content oracle.** The churn does not
   test a behaviour; it samples the interleaving space, and the
   self-identifying blocks convert "something is wrong" into a typed,
   attributed finding. A failure ships with its seed, its op rings and
   the volume image, so a one-in-N event becomes a replayable one.
2. **The compiled-in probe tape** (`CETRAFS_TRACE=1`, `ctrace()`): the
   dirent/inode/block lifecycle probes that located the 2026-10
   cross-node bugs stay in the source, and they are what turned the
   rebirth race from a statistical mismatch into a five-line indictment
   with the guilty caller in it. One discipline matters: hunt with
   `trace_printk` semantics, never `printk` -- a printk in the window
   closes it, and this cycle watched the same bug vanish for 12
   straight runs under printk probes and reappear under ftrace ones.
3. **Hostile-input fuzzing** (`tests/fuzz/`): mutated images against
   both `fsck` and the mount path. It is the only tier whose inputs are
   adversarial rather than probable, which is what keeps "a corrupt
   disk" from being an undefined behaviour.
4. **Negative controls on the detectors themselves** -- and the 0.9
   cycle's counter-example: two xattr "refusal" assertions had passed
   vacuously for months on every box missing the `attr` package
   (`setfattr: command not found`, stderr suppressed, read as
   "refused"). The one box that had the tool was the only one running
   the assertion. A test that cannot fail is worse than no test, and
   that includes failing to run.

The honest arithmetic: a race with a microsecond window inside a
millisecond operation has per-hit odds around 10^-6 even when the
workload is trying. Nothing that runs once per release finds it.
Repetition under randomized load, evidence kept on failure, and a tape
that was already recording are not optional extras -- they are the only
instruments on which these bugs register at all.

---

## Opt-in tiers

These are not in `make check` -- they are slow, destructive, or need
hardware the gate cannot assume.

**`make soak`** (`tests/stress/`) -- mixed-workload hammering with a
full `fsck` after every round, plus a scrub-versus-allocator race and a
sparse-bigfile exercise.

**`tests/crash/`** -- crash consistency for real: `dm-log-writes` records
every write, `dm-flakey` cuts the device at an arbitrary point, and the
log is replayed to that point and checked. The filesystem must come back
consistent from any cut, not just a tidy one.

**`tests/fuzz/`** -- hostile images. Fields are mutated across the
superblock and the metadata, and both `fsck.cetra` and the *mount path*
must refuse them without crashing. A filesystem must survive a corrupt
disk being handed to it deliberately.

**`tests/device/`** -- DESTRUCTIVE, real hardware, explicitly opt-in.
The only tier that exercises the real SCSI COMPARE AND WRITE primitive:
a loop device has none, so everything else runs the serialised fallback.

---

## `ctest/` -- the multi-node cluster suite

A "node" in cetrafs is a kernel instance with its own machine UUID, so
real cross-node behaviour cannot be simulated with two processes on one
box. `ctest/` is a Go master/slave harness driving **two or more real
machines against one shared LUN**, with about 67 scenarios. The suite requires
at least two machines; a second three-node rig on an FC multipath LUN
exercises scalability beyond the testing minimum.

What only this tier can reach:

- the whole-file exclusive open lock, contended from two nodes at once,
  and the `nofilelock` mode used for live migration
- Zone Group ownership: claiming, fairness, stealing from a node
  declared stale, and the fencing lease that stops the victim writing
- the per-inode namespace lock under concurrent create / mkdir / rename
  / unlink storms from both sides
- cross-node cache coherency -- dirent caches, extent-leaf staleness,
  inode number reuse, record-write races
- a peer replaying a dead node's journal, and the pending-free queue
  that hands frees to another node's Zone Group
- the real CAW primitive under contention, and what happens when a node
  has none

Several classes of bug in this filesystem's history were **structurally
unreachable** without it -- which is why the project rule is that a code
review is the first filter and never the proof.

---

## What we are actually hunting

The checks exist because each of these has happened:

| class | how it is caught |
|---|---|
| cross-file block overlap | `fsck`, and the oracle names both files |
| blocks in use but marked free | `fsck`, and the allocator's shadow detector |
| leaked blocks (allocated, referenced by nothing) | `fsck`, and the background scrub in a quiet window |
| a hole or preallocated range serving stale data | the content oracle -- `fsck` cannot see it |
| lost writes / dropped extents | the oracle, warm, cold, and after a remount |
| torn reads of a record under concurrent publish | checksums plus the oracle's per-block tags |
| stale cache across nodes | `ctest` only |
| counters drifting from the bitmaps | `fsck` cross-checks every cached count |
| unreachable inodes, dangling entries, nlink errors | `fsck`'s namespace pass |
| crash leaving a half-finished operation | journal replay plus `tests/crash/` |
| a corrupt or hostile image | `tests/fuzz/` against both `fsck` and mount |
| an inode number freed while being reborn | the oracle names both files sharing it; the probe tape names the freer |

The important line in that table is the fourth. A filesystem can be
perfectly **consistent** and still **wrong**: every block owned by
exactly one file, every count matching, `fsck` clean -- and the bytes
handed back are not the bytes that were written. Only a content oracle
catches that, which is why `churn_oracle.sh` exists alongside `fsck`.

---

## The rules the suites are held to

Learned the expensive way, and enforced by `image/source_invariants.sh`:

1. **A test that cannot fail is worse than no test.** Every detection a
   tool claims has a negative control that injects the fault and
   requires it to be caught. Test-only module parameters exist for
   exactly this -- each one removes a single protection so the suite can
   prove *that* protection is what prevents the damage.
2. **The code under test must be the only path to the observable.** A
   suite can otherwise pass because something else caught the fault
   first.
3. **A suite that proves nothing must say so**, not pass quietly. Suites
   that depend on a race landing assert that the race actually occurred.
4. **A green run of a low-probability test is not evidence.** Those are
   run repeatedly when the code they cover is touched.
5. **`make check` and nothing less** validates a change to `kmod/` or
   `userspace/` -- the userspace tools are not a smaller blast radius,
   because almost every kernel suite calls `mkfs` or `fsck`.
