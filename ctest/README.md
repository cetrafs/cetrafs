# ctest

Multi-node concurrency/race-condition tester for cetrafs. See
`docs/LOCKING.md` for the cross-node mechanisms this exercises.

A "node" in cetrafs terms is a kernel instance with its own stable machine
UUID, so testing real cross-node behavior needs **two or more real or
virtual machines with access to the same shared block device** — this
tool cannot simulate multiple nodes with multiple processes on one
machine (they'd all register as the same node and re-attach to the same
Node Registry row). A slave running on the same machine as the master
(e.g. via `-local-slave`) is still a distinct node only if that machine
genuinely has its own separate access path to the shared device alongside
other machines' slaves — running two slaves on literally one machine both
pointed at the same device tests the harness plumbing, not cetrafs's
cross-node correctness.

Assumes the shared device is **already formatted** with `mkfs.cetra` —
this tool never runs mkfs itself, so repeated runs accumulate state
(including whatever ZG/node ownership earlier runs left behind).
Scenarios are written to tolerate that rather than assume a pristine
volume.

## Build

```
cd ctest && go build -o ctest .
```

## Run

On each machine that will mount the shared device. The slave owns both
the device and the mountpoint; it creates the mountpoint if it does not
exist, and `-mkfs` is only needed for the `mkfs-guard` scenario (it
defaults to `../userspace/mkfs.cetra` next to the binary):

```
./ctest -mode=slave -addr=:9100 -device=/dev/sda [-mountpoint=/mnt/ctest]
```

On the machine driving the test (can be one of the above, or separate).
The master no longer takes `-device`/`-mountpoint`: it asks each slave
what it is configured with, prints that, and refuses to run if the
slaves do not agree on one shared device.

```
./ctest -mode=master \
    -slaves=nodeA=10.0.0.1:9100,nodeB=10.0.0.2:9100 \
    -scenario=zg-fairness
```

To also run a slave on the master's own machine in the same invocation
(`-device`/`-mountpoint` configure that in-process slave):

```
./ctest -mode=master \
    -local-slave=:9100 -slaves=local=127.0.0.1:9100,remote=10.0.0.2:9100 \
    -device=/dev/sda -scenario=lock-race -lock-path=ctest-lockfile
```

### Why the slave owns the mountpoint

It used to be the master that said where to mount, which meant a slave
started with one mountpoint could be driven to mount at another. When
the two disagreed nothing noticed, because an unmounted mountpoint is
still a perfectly good directory: a suite run wrote 50 MB to the host
root filesystem and passed every assertion it made along the way.

Two things prevent that now. The slave decides its own mountpoint, so
there is nothing to disagree about; and every filesystem op first asks
the kernel (`/proc/self/mounts`) whether that path is a live cetrafs
mount, refusing rather than writing to the host filesystem if it is not
-- including when the mount is pulled out from under a running scenario.

### Shutdown

The master unmounts every slave on the way out of any run -- normal
finish, scenario error, failed precondition, panic, or Ctrl-C. A slave
unmounts before exiting on SIGINT/SIGTERM/SIGHUP or an internal panic,
so a crashed node does not leave a shared LUN mounted behind it. The
`exit_uncleanly` op deliberately bypasses all of this: simulating a node
that dies *without* unmounting is how the stale-reclaim paths get
tested.

### Preconditions

Before any scenario that makes a cross-node claim, the master requires
every node to be running the same `cetrafs.ko` build, and aborts the run
(after unmounting) if they are not. Every assertion in this suite is a
statement about two peers implementing the same protocol; if they do
not, no result means anything, pass or fail. `diag` and `module-info`
are exempt, since those are the tools for diagnosing the mismatch.

## Scenarios (Stage 1)

- **`release-suite`**: `full-suite` plus the scenarios excluded from it
  for being slow -- `hypervisor-storm`, `ns-fuzz`,
  `concurrent-mkdir-storm`, `explicit-lock`, `cluster-lock-mode`. This
  is the pre-release gate; `full-suite` is the per-change one. It keeps
  going after a failure rather than stopping at the first, because a
  release wants the whole picture.

- **`mkfs-guard`**: checks `mkfs.cetra` refuses to reformat a mounted
  volume -- both when the mount is on the node running mkfs (a local
  `/proc/self/mounts` check) and when it is on a *different* node, which
  is invisible locally and has to come from the Node Registry walk in
  `userspace/devutil.h`. The cross-node case is the one that matters:
  reformatting a LUN another hypervisor is running VMs off is the
  catastrophe the check exists to prevent. Also confirms mkfs *succeeds*
  when nothing is mounted, so the refusals prove something, and matches
  on *why* mkfs refused rather than just on a nonzero exit. Runs first in
  `full-suite`, so each suite run starts from a pristine volume.

- **`zg-fairness`**: every slave `mount()`s the shared device at the same
  instant; asserts no two slaves ever report owning the same Zone Group
  afterward (`/proc/fs/cetrafs/<dev>/info`). Targets the minimum-claim fix in `kmod/zonegroup.c`.
- **`lock-race`**: every slave tries to open the same file for write at
  the same instant. **Exactly one success and the rest `-ETXTBSY` is the
  expected, passing outcome** — not an anomaly. More than one success
  means the cross-node open-lock claim race (fixed in
  `kmod/lock.c`) has regressed. Zero successes means something else is
  wrongly rejecting a claim that should have been free to take.
- **`explicit-lock`** (needs >= 2 clients): the userspace-driven
  whole-file lock via the standard **`flock(2)`** under `nofilelock`. Mounts
  both nodes `-o nofilelock`, then: confirms the baseline (an unlocked file
  opens on the peer -- what makes live migration work), has the holder
  `flock(LOCK_EX)` the file and asserts the peer is now refused ANY open,
  `flock(LOCK_UN)` (the handoff window -- peer opens again), re-locks
  (refused again), and finally closes the holder's fd with no explicit
  unlock to prove the fd-scoped release. The real cross-node proof of the
  feature that hands exclusion back to userspace on demand; the single-node
  mechanics are `tests/kernel/file_explicit_lock.sh`.
- **`cluster-lock-mode`** (needs >= 2 clients): the file-lock mode is
  cluster-wide and the first mounter leads. Part 1: `lead` mounts
  `-o nofilelock`, `join` mounts with NO option and must come up
  `file_lock: off` (inherited, not its own default on) -- a mixed cluster
  would be silently corrupting. Part 2: `lead` mounts default (lock on),
  `join` mounting `-o nofilelock` must be REFUSED at mount (an explicit
  conflicting option is rejected, not silently overridden). Reads each
  node's `file_lock:` from `/proc` via `proc_raw`. The real cross-node
  proof; the single-node decision logic is
  `tests/kernel/cluster_file_lock_mode.sh`.
- **`symlink-publish`** (needs >= 2 clients, in full-suite): one node
  creates symlinks one after another while the other races to resolve each
  name the instant it appears; a name must never resolve to anything but
  its complete target. Samples the publish-order window (the dirent used to
  land before the target text and security label were built) at RPC rate;
  the deterministic single-node proof of the ordering is
  `tests/kernel/create_publish_order.sh`.
- **`nocaw-mount-race`** (needs >= 2 clients): the no-CAW single-mounter
  invariant under a real simultaneous mount. Forces CAW discovery off on
  every node (the `caw_fail_discover` module param, via the `mod_param`
  op) and compresses the gate's watch window, then has all nodes mount the
  same volume at the same instant for several rounds: at most ONE may ever
  come up (a tied round where both refuse is legal, and a sequential retry
  must then win). Samples the real interleavings between the
  pre-registration gate and the post-registration re-check; the forced
  single-node mechanics are `tests/kernel/nocaw_mount_gate.sh` and
  `tests/kernel/nocaw_mount_race.sh`.
- **`sparse-bigfile`** (needs >= 2 clients): the genuine cross-node
  counterpart to `tests/device/sparse_bigfile.sh`'s single-kernel
  approximation of "another node" via unmount+remount. Reads
  `max_file_size_bytes`/`write_ready` from both nodes' own
  `/proc/fs/cetrafs/<dev>/info` (via the `proc_snapshot` op) and asserts
  they agree — a mkfs-time-fixed, volume-wide constant
  (`kmod/zonegroup.c`'s `cetrafs_compute_max_file_size()`) that two
  independent kernels must compute identically; then checks the boundary
  itself (growing one byte past the max fails, growing to exactly the
  max succeeds) and the full head/tail/hole shape the bash test asked
  for: one node writes stamped data into the first and last 1 MiB of
  the biggest sparse file the volume's worst-case ZG math allows and
  closes it, a genuinely different node opens it cold and reads both
  regions plus a mid-file hole sample back, comparing by sha256. Uses
  new `write_at`/`read_at` ops (pwrite/pread-style) rather than the
  plain `write`/`read` ops, since those materialize the whole file in
  memory -- unworkable at multi-GiB scale.
- **`xattrs`** (needs >= 2 clients): full user.* xattr lifecycle checked
  cross-node in both directions (set/overwrite/list/remove via new
  `xattr_list`/`xattr_remove` ops, plus the lazily-allocated xattr
  block's alloc/free visible in the OTHER node's statfs), then the race
  an earlier fix closed: every node sets a different key on a
  fresh file at the same instant (racing the one-xattr-block lazy
  allocation -- before that fix, one node's attribute silently vanished and a
  block leaked) and every attribute must land; finally a same-key race,
  where any single written value is a valid winner but a torn/mixed
  value or cross-node disagreement is a failure.
- **`scrub-transit`** (needs >= 2 clients): the background scrub must not
  reclaim a block that is IN TRANSIT between nodes. B deletes a file whose
  blocks live in A's zone group, so B cannot touch A's bitmap and queues
  the free instead; until A's drain applies it, the block is bitmap-set
  and referenced by no inode on any node — indistinguishable from a leak
  by every test A's scrub has. Freeing it clears the bit early, A's
  allocator reuses the block, and A's next drain then clears it again
  under whatever file owns it by then: two files, one block, with no
  error anywhere and a clean fsck at every instant in between.
  The window is held open by SLOWING A's heartbeat to 30s rather than
  stopping it — the drain rides the same tick as the lease renewal, so a
  node that stops ticking is one its peers declare stale and fence. Two
  guards keep the pass from being vacuous: `scrub_cycles` must show a
  full cycle ran, and the entry must still be queued when it did.
  The single-node form of the same question is
  `tests/kernel/scrub_spares_queued_free.sh`, which pokes the entry in
  directly; only here is the entry a real cross-node delegation.
- **`hypervisor-storm`** (needs >= 2 clients; NOT in `full-suite`): the
  whole machine under concurrent load shaped like the deployment, rather
  than one mechanism in isolation. Several nodes at once: VM-sized image
  files (1-50 GiB, sparse -- a truncate to size plus scattered pwrites,
  which is what a VM disk looks like and what makes the extent tree
  interesting without writing 50 GiB), each owned by exactly one node so
  the one-writer-per-disk rule holds; open/hold/close churn across the
  file-lock and durability boundaries; directory create/fill/empty/remove
  from every node; and the hostile case -- one node makes a directory, a
  second fills it and holds files OPEN inside, a third tries to `rmdir`
  it, which must fail without half-removing anything, and must then
  succeed once the directory is genuinely empty. A node's device is
  pulled and restored mid-storm so the load runs across a real
  reclaim/replay cycle.
  Every ~100s the storm quiesces, every node unmounts, and the volume is
  checked with the **fsck embedded in the ctest binary** -- so a node
  with no cetrafs checkout can still check the volume it stands on --
  then everyone remounts and carries on. A dirty fsck stops the run at
  once: the first corruption is the evidence, the hundredth is noise.
  `-storm-minutes` (default 6) and `-storm-seed` so a failure reproduces.
  Deliberately outside `full-suite`: it runs for minutes and is something
  to point at a cluster, not a per-commit gate.
  It carries an honesty gate -- a run that completed too few operations
  FAILS rather than reporting a confident pass on a storm that never blew.

  **Corruption can hide in memory, so fsck alone is not enough.** fsck
  only ever sees the device, and only while nothing is mounted: a
  divergence living in one node's page or buffer cache -- a stale size, a
  dirent set missing a name, a record refreshed onto the wrong identity
  -- is simply dropped at unmount, and fsck then finds a device that
  looks fine. So the storm also keeps WITNESSES: files written once and
  never touched again, which every node must therefore report
  identically. They are checked three ways, because they fail
  differently: all nodes agree with each other (one cache drifted), all
  agree with what was written (everyone drifted, or the write never
  landed), and the WARM answer matches the COLD one taken after a remount
  (the cache disagreed with the device -- the case fsck can never see).
  Warm checks run under load every 20s; the warm/cold pair brackets every
  fsck remount.

  **Every fault freezes its evidence to a file** (`ctest-evidence-*.txt`)
  at the moment it is found, not at the end of the run: each node's
  dmesg, `/proc` info and cluster view, ZG ownership, fenced state,
  pending-free queues, and -- the part that cannot be reconstructed
  afterwards -- every node's own readdir/stat of the paths involved. A
  cache that disagrees with its peers stops existing at the next
  remount, so a scenario that only prints a line has destroyed its own
  finding.
- **`dir-storm`** (needs >= 2 clients): one consolidated load scenario
  rather than another micro-test, because the failures it targets only
  appear with several mechanisms under pressure from both nodes at once.
  Two nodes fill ONE shared directory with `-dirstorm-files` files
  (default 200, i.e. 100 per node), half each, concurrently; both count it, each verifies a
  sample of the OTHER node's files by size and sha256, and teardown is
  cross-node too — each node unlinks the files its peer created. The
  directory's own inode (size and nlink) is compared across both nodes at
  every stage: empty, full, and emptied again.
  File sizes are random in `[1 byte, -dirstorm-max-kb]` (default 1 MiB)
  from a fixed seed (`-dirstorm-seed`, so a failure reproduces), which
  deliberately spans single-block files and multi-megabyte ones in the
  same directory — equal-sized files would exercise exactly one allocator
  path. Covers: directory growth far past one dirent block and past the 4
  inline extents into a depth-1 external leaf (the 58-entry cap fix) under real cross-node contention; the per-inode namespace
  lock serializing thousands of dirent writes into one directory;
  cross-node readdir completeness; cross-node content integrity; and full
  space/inode reclaim at the end. Building it is what surfaced the two
  buffer-cache races fixed in `kmod/ioutil.c` (silent loss of directory
  entries, and spurious EIO from a refresh-time invalidation racing a
  concurrent read).

## Stage 2/3 (not yet built)

- `open_hold`/`close`-based unlink-vs-open-lock race, and a
  concurrent-create-in-shared-directory namespace race (targets the
  `kmod/dir.c` fix).
- Sustained mixed read/write/rename/unlink load across all slaves,
  followed by an `fsck.cetra` + per-file checksum consistency pass.
- `exit_uncleanly` (already implemented in the slave) wired into a
  stale-reclaim-under-real-concurrency scenario.

Staleness/reclaim itself (a node going quiet and a peer reclaiming its
ZG/lock after the timeout) is deliberately *not* a priority for this tool
— it's a timestamp comparison already covered by the loop suite's
single-node poke-based tests. This tool's value is exercising the races
that genuinely need two *live* nodes acting at once, which a single
machine cannot simulate.
