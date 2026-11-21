# How cetrafs is tested

A clustered filesystem does not fail by crashing. It fails by handing back
the wrong bytes -- on another node, after a crash, months after the write --
on somebody's VM disk. Every layer of the effort below exists because that
failure is silent, and every check in it has been made to fail on purpose
before it was trusted.

This page is the summary. `docs/TEST-SUITES.md` is the full map, and
`docs/TESTING.md` is the plan for validating a real deployment.

---

## In numbers

| | |
|---|---|
| Automated regression suites (`make check`) | **868** -- 794 against a mounted kernel module, 74 against the tools alone |
| Assertions per full gate | **~6,900**, every one of which must pass; a suite that aborts without failing an assertion also fails the gate |
| Suites with a negative control | about **five in six** of the 794 kernel suites name the protection they test and prove the test fails without it |
| Test-only fault switches in the module | **699** -- each removes exactly one protection, so a suite can show *that* protection is what prevents the damage |
| Two-node scenarios on real shared storage (`ctest/`) | **70**; the release suite runs 48 of them, ~480 cross-node assertions, on Fibre Channel and iSCSI LUNs with real COMPARE AND WRITE |
| Mechanical checks on the source itself | **159** -- locking order, sleeping under spinlocks, allocator families, async drains, signal handlers, one per bug class where a grep can decide it |
| Bug classes on file | **59**, each with the question an audit must ask, a sweep of the tree, and a mechanical check or instrument |
| Distinct faults `fsck.cetra` names | **118** errors (131 findings with warnings); the image suites inject faults one at a time and require `fsck` to name the one injected |
| Fuzz campaigns per release | 4: hostile images against `fsck` and against the mount path, blind and field-aware |
| Crash-consistency scenarios | 8, replaying every write the filesystem made up to an arbitrary cut |
| Performance invariants | **22**, each measured on real SAN hardware and guarded by a test |
| Lines of test code | **~133,000** -- 1.4x the kernel module and tools combined |
| Known open defects | **none** (`docs/internal/OPEN-DEFECTS.md` is kept empty by fixing, not by moving things out of it) |

---

## What a change has to get through

1. **Its own suite, failing first.** A fix comes with the suite that
   reproduces the fault. The fix is then removed -- or its test-only switch
   flipped -- and the suite must fail. A check that has never been seen to
   fail is not counted as coverage.
2. **The full gate.** All 868 suites on loop-backed volumes, sharded across
   three machines. Nothing ships on a red gate, and a
   change to the userspace tools gets the whole gate too: almost every kernel
   suite runs `mkfs` and `fsck`.
3. **The source invariants.** `image/source_invariants.sh` reads the code,
   not its behaviour: 159 checks that hold the tree to rules learned from
   real bugs (below).
4. **The two-node suite on real hardware.** `ctest/` drives two or three
   machines against one shared LUN. It is the only tier that exercises the
   real SCSI COMPARE AND WRITE primitive, real cross-node cache coherency
   and real node death.
5. **The release matrix.** Crash rig, fuzzers, soak, a KASAN build, and the
   suites again under `nofilelock`, other geometries and a small journal.

---

## The tiers, and what only each one can see

| tier | what it is | what only it catches |
|---|---|---|
| `tests/image/` | the tools with no kernel: `mkfs` writes, a helper corrupts one structure, `fsck` must name *that* fault and exit nonzero | the on-disk format contract, and every fault `fsck` claims to find |
| `tests/kernel/` | one concern per suite, on a mounted volume | every named behaviour: namespace, extent tree, O_DIRECT, mmap, ENOSPC, grow, discard, journal replay, scrub, defrag, the locks |
| content oracle (`churn_oracle.sh`) | many processes, random weighted ops, page-cache pressure, ENOSPC cycles; every 4 KiB block encodes `(seed, file, generation, block)` | the bugs nobody wrote a suite for, reported by kind: *this block belongs to file 196619* is an overlap, *this block is an older generation* is a lost publish |
| model checkers | `fsx_model`, `fsstress_namespace`, `fio_verified_io` against in-memory models | a sequence of correct operations that adds up to a wrong file |
| `tests/crash/` | `dm-log-writes` records every write; the log is replayed to arbitrary cuts, including mid-flush | a durability-order bug: a reference that reached the platter before what it points at |
| `tests/fuzz/` | mutated images -- blind, and field-aware with the checksum restamped so the hostile value gets past validation | a disk value that aims an I/O, bounds a loop, or sizes a copy, used before it was judged |
| KASAN, clang, sparse | the module under a sanitizer, a second compiler, and an endianness checker | out-of-bounds and use-after-free in the module; a host-order value written to disk |
| `ctest/` | real nodes, one shared LUN, scripted interleavings, device cuts, node kills | everything cross-node: lock contention, stale caches, a peer replaying a dead node's journal, fencing, a node behind a live grow |

---

## Every check is proven to fail

The rule the whole tree is held to: **a test that cannot fail is worse than
no test**, because it reads as coverage. So:

- **Negative controls are part of the suite.** Most kernel suites carry
  one, naming the switch that removes the protection, and run it: with
  the protection the damage does not happen; without it the same suite
  must see the damage. A control that does not fail is
  itself reported as a failure.
- **The setup is asserted, not assumed.** "No freed block holds the marker"
  is green when the punch freed nothing. Every such suite has a separate
  failing exit for *the situation was not arranged*.
- **The concurrency is real.** A negative control for a race starts as many
  actors as the fix claims to serialise. One faulting process passed
  against a deliberately weak lock; two failed it in two rounds of three.
- **The code under test is the only path to the observable.** Test-only
  switches exist so that nothing else catches the fault first.
- **Blind spots are written down.** A fuzzer that only sees crashes cannot
  see an over-long read that returns adjacent memory. Where the tooling
  cannot observe a failure, the suite says so, and the missing instrument
  goes on a list -- it is not reported as covered.

---

## Bugs are filed by class

A fixed bug is one instance. The project keeps a registry of **59 bug
classes** (`docs/internal/BUG-CLASSES.md`), each phrased as the question
that would have found it:

- *Is every read inside a lock-bracketed read-decide-write forced fresh?*
- *Does a cache keyed by a reusable number carry a generation?*
- *Which direction does staleness push a destructive decision?*
- *What does `nofilelock` remove from this safety argument?*
- *What runs between the check and the act?*
- *Is a value read off the disk a count, a length, or an address -- and
  which paths validate it?*
- *Can this loop's step come from the disk, and what happens when it is
  zero?*
- *What drains this async work before what it uses is freed?*

An audit runs one pass per class, and its report has a line for every class:
findings, or what was enumerated and found clean. A bug that fits no class
becomes a new class before it is closed -- with a sweep of the tree for its
siblings and a mechanical check or instrument, so the next one is found by
a machine.

---

## The source is checked as well as the behaviour

Some properties are cheaper to prove from the code than to provoke. The
source-invariant suite holds the tree to them on every gate:

- no sleeping primitive under a spinlock, and every call made under one is
  a listed non-sleeper;
- no `inode_dio_wait()` reachable under `invalidate_lock` (it deadlocks
  against the direct-I/O completion);
- every work item, timer, `igrab()` and RCU callback is listed with what
  drains or releases it, and unmount closes each queue before the
  superblock goes;
- every loop in an allocator critical section reschedules;
- every read of a disk address goes through the one checked lookup;
- every cache whose name says it trusts state names the identity its key
  carries;
- every test-only switch logs and taints the kernel when set;
- no `vmalloc`'d pointer reaches `kfree()`.

Each check has its own control: a planted violation must be caught.

---

## What `fsck` cannot see, the oracle does

A filesystem can be perfectly consistent and still wrong. One owner per
block, every count matching the bitmaps, no leak, `fsck` clean -- and a
preallocated range serving a deleted file's contents. That happened, and
`fsck` reported OK throughout, because there was nothing inconsistent to
find.

So consistency is only half of the bar. The content oracle checks every
block it wrote, warm, after dropping the page cache, and after a remount; it
knows what each block was supposed to say. Its seeded replays caught a
race with a **378-microsecond** window at per-operation odds in
the millions -- not by provoking it once, but by sampling enough
interleavings that a one-in-a-million event happens, and by tagging every
block so the failure names the two files involved instead of reporting
"corruption".

---

## Two-node testing on real storage

A cetrafs node is a kernel instance with its own identity; real cross-node
behaviour cannot be simulated with two processes on one machine. `ctest/`
is a master/slave harness that drives real machines against one shared LUN
-- Fibre Channel multipath and iSCSI rigs, two and three nodes, arm64 and
amd64. It:

- races the whole-file lock, the per-inode namespace lock, Zone Group
  claims and the inode bitmap from both sides through real COMPARE AND
  WRITE;
- pulls a node's device mid-write and checks the survivor takes the file
  over, replays the dead node's journal, and reads back only whole writes;
- grows the volume on one node while the other is behind the grow;
- runs namespace storms, hypervisor-style mixed I/O with device-pull
  injection, and a randomized namespace fuzzer, from every node at once;
- checks every node is running a module built from the same source before
  it starts.

Several classes of bug in this project's history were structurally
unreachable without it. That is why a code review is the first filter and
never the proof.

---

## Performance is a tested property

A loop device serves an "uncached" read from the host page cache for free
and has no atomic CAW, so a per-block device round trip benchmarks as zero
in `make check`. `docs/PERFORMANCE.md` therefore lists **22 invariants** --
a CRC, a lock or a device read kept off a path that runs 36,000 times a
second -- each with the number it cost when it was broken and a test that
counts the operations rather than timing them.

---

## The last validation run

The 0.10.1 release tree, 2026-11-21:

| stage | result |
|---|---|
| full gate, 868 suites | **6,937 assertions passed, 0 failed** |
| two-node release suite, three nodes on an iSCSI LUN | 46 of 46 passed (one rerun on a fresh volume after the earlier scenarios had filled the small test LUN) |
| live grow, three nodes on an FC multipath LUN | `grow-twice` and `grow-unrescanned` passed |
| crash rig, every phase and its negative control | passed; every torn journaled block restored by replay |
| fuzz: `fsck` blind / field-aware | 3,000 / 3,000 iterations, 0 findings |
| fuzz: mount blind / field-aware | 300 / 300 hostile images, 0 findings, no kernel warning |
| soak, a full `fsck` after every round | 200 rounds clean; content oracle 6 rounds, every block byte-exact |
| sparse (endianness) | clean |
| KASAN build, full gate | 0 reports (on the 2026-11-19 tree; not repeated for this release) |

The run found no filesystem defect. Four test-harness faults it exposed
-- a timing window in one suite, two time limits sized too short, and a
crash-rig phase whose target no longer changes in place -- were fixed
and their stages run again.

---

## Where to read more

- `docs/TEST-SUITES.md` -- every tier in detail, the content oracle, the
  bugs that took randomized load to find
- `docs/TESTING.md` -- validating a real deployment, layer by layer
- `docs/PERFORMANCE.md` -- the hot-path invariants and their measurements
- `docs/internal/BUG-CLASSES.md` -- the class registry
- `tests/README.md` -- the harness API and the rules for writing a suite
