# UNMAP / discard: giving space back to a thin LUN

**Status (2026-11-13): steps 1, 2 and 3 are built** (`kmod/discard.c`),
together with a hand-back discard this design did not originally have
(see "As built" at the end). Step 2, inline `-o discard`, is the
section "Inline discard" there.

Before this, cetrafs issued no discard of any kind: space freed in the
filesystem stayed mapped in the array's thin pool for the life of the
volume, so a datastore that had ever been full stayed full as far as the
array was concerned.

For the target deployment -- VM images on a shared thin-provisioned LUN
-- that is a real operational problem, not a nicety: the whole point of
thin provisioning is that deleting a VM returns its capacity to the
pool, and today it does not.

This describes what to build, in what order, and the two things that
make it dangerous.

---

## The chain that has to work end to end

```
guest TRIM/UNMAP
  -> qemu  (discard=unmap)
    -> fallocate(PUNCH_HOLE) on the image file
      -> cetrafs frees the blocks
        -> UNMAP to the array        <-- this link does not exist
```

Note the link before ours is usually broken too: Proxmox defaults a disk
to `discard=ignore`, so guest TRIM never reaches the file. Anyone
measuring the chain must set `discard=on` on the disk AND have the guest
actually issue TRIM (`fstrim` or `discard` in the guest's fstab).

---

## Two mechanisms, one implementation

ext4 settles this question and it is worth following, because the shape
it arrives at is forced rather than chosen (verified against 6.12
`fs/ext4/mballoc.c`):

* **`FITRIM`** -- what `fstrim` calls. `ext4_trim_extent()` runs
  **synchronously in the caller's process**: `ext4_issue_discard()` is
  `sb_issue_discard(..., GFP_NOFS, 0)`, the waiting variant.

* **`-o discard`** -- inline, and the important part is that it does
  **not** discard on the free path. Freed blocks are attached to the
  journal transaction; only after the commit are they spliced onto
  `s_discard_list` and a work item queued on `system_unbound_wq`. The
  worker then calls `ext4_try_to_trim_range()` -- *the same function
  `FITRIM` uses*.

So these are not two features. Build the batch path with its protection,
and the inline option becomes a queue that feeds the same code after a
durability boundary.

---

## The protocol: claim the run, discard it, free it

The hard part is not issuing the command, it is that a run read as free
can be handed to a file while the UNMAP is in flight. Holding the
allocation mutex across the discard is not an option -- an UNMAP is
milliseconds and allocation would stall behind it.

ext4's answer, with its own comment:

```c
/*
 * Mark blocks used, so no one can reuse them while
 * being trimmed.
 */
mb_mark_used(e4b, &ex);
ext4_unlock_group(sb, group);
ret = ext4_issue_discard(sb, group, start, count);
ext4_lock_group(sb, group);
mb_free_blocks(NULL, e4b, start, ex.fe_len);
```

For cetrafs that reads: under `alloc_mutex`, set the run's bits in the
Block Group's data bitmap exactly as an allocation does; drop the mutex;
issue the discard; retake the mutex and free the run.

While the bits are set the allocator cannot take the run, and a peer
cannot either (it does not allocate from a Zone Group it does not own).
**The scrub is the exception, and this paragraph used to say otherwise**
("the scrub skips anything that reads allocated"): the scrub's whole job
is freeing blocks that read allocated and that nothing references, which
is exactly what a claimed run is. Two more things are needed, and both
are built:

* the claim is published on the live-reservation list in the same
  `alloc_mutex` section that sets its bits, as a defrag destination
  run is, so the scrub's free (which rechecks that list under the same
  mutex) leaves it alone;
* both free paths -- the local one and the pending-free apply -- treat
  a block inside the claimed run as already free. A double free, or a
  peer's queued copy of one, otherwise clears the trim's bit, the block
  is handed out, and the UNMAP still in flight destroys the new owner's
  data (`cetrafs_sb_trim_holds()`).

A crash
in the middle leaves the bits set: blocks leaked, which the scrub
reclaims. That is the safe direction, and the same one the rest of the
allocator already chooses -- a lost free leaks a block, it never shares
one.

---

## What makes this different from ext4: ownership

ext4's worker never has to ask whether the block group is still its own.
We do, and it is the first gate, not an afterthought.

A node allocates only from Zone Groups it owns, and `alloc.c` is blunt
about the other direction:

> Writing another node's data bitmap is the single most damaging thing
> this module can do: the owner is concurrently allocating from the same
> bitmap with no cross-node exclusion (none is needed -- Zone Group
> ownership is what partitions it).

So:

1. **Trim only Block Groups whose covering Zone Group this node owns.**
   This is the same argument the allocator itself rests on, and it is
   also why the cached bitmap is authoritative here: we are its only
   writer. A peer freeing blocks inside our Zone Group does not touch
   our bitmap -- it queues them in the pending-free queue and we apply
   them.

2. **A steal can land mid-pass.** A peer that declares us stale takes
   the Zone Group, reconciles it, and starts allocating -- while we hold
   a list of runs computed before the steal. Two defences: check
   `cetrafs_sb_is_fenced()` before every batch and abandon the pass, and
   keep batches small.

3. **Never clear bits without re-verifying ownership.** If the Zone
   Group is gone, leave the claimed run's bits SET and walk away. Space
   is leaked and the scrub reclaims it. Clearing them would be writing a
   peer's bitmap, which is the one thing the quote above forbids.

---

## The asymmetry that must not be waved away

"We trust the bitmap, exactly as the allocator does" is true about the
input and false about the consequence, and the difference is the whole
reason this needs more care than allocation does.

If a bit is wrongly free:

| | the allocator does | FITRIM does |
|---|---|---|
| effect | hands the block to a second file | **destroys the data on it** |
| detection | `fsck` sees two owners | nothing; the file just reads wrong |

Same staleness, opposite sign. The rule this project learned the
expensive way: of every input to a destructive decision, ask *if this
read returns an OLDER value, does the decision become safer or more
destructive?* Adding a reference is safe when stale; FREEING is not,
because older means fewer references, which means more things look
unused. Discard is a destructive decision fed by a cached read -- the
same shape as a background-scrub defect that once freed live data.

So FITRIM must be **more** conservative than the allocator, not equally
conservative. The material already exists:

* `cetrafs_sb_bg_alloc_seq()` -- bumped by allocations and deliberately
  NOT by frees, which is precisely "someone allocated here while I was
  looking". The scrub already snapshots it and abandons a Block Group
  whose value moved; a trim pass must do the same.
* `cetrafs_free_inode_if_dead()` -- the model for acting on a verdict
  only through a CAS that lands on exactly the state judged (it claims
  the record before clearing the bit; a fresh re-read alone was not
  adjacent enough).
* The live-reservation registry -- a speculative allocation run reads
  as allocated, so it is skipped for free. Nothing to add.

---

## Order of work

**1. `FITRIM` first.** All of the value, almost none of the risk. It is
rare, so it can afford to re-verify, to work in small batches, and to
give up whenever anything looks off.

It also *coalesces for free*, which is the strongest argument for doing
it first: a trim walks the **bitmap**, which does not remember how
fragmented the file was. After a delete it finds maximal contiguous free
runs -- few and large -- whatever shape the file had. Measured on the
reference rig: deleting a 1 GiB file with 8221 extents would be 8221
inline commands, but the same space trims as a handful of runs.

**2. `-o discard` second**, behind a mount option, feeding the same code
from a queue drained after a durability boundary (our equivalent of
ext4's post-commit splice is the last writer's close, where the free
counters are already flushed).

Two details worth copying from ext4's worker:

* **It gives up under pressure.** If the filesystem is unmounting, out
  of memory, or has allocations waiting on space, it abandons the
  discard and frees the blocks immediately. Discarding is best effort;
  allocating is not. Without this an ENOSPC can end up waiting on the
  array to digest thousands of UNMAPs.
* **It batches per group**, loading one group's metadata and draining
  every pending range in it before moving on.

**3. Device limits**, throughout: honour `discard_granularity` and
`discard_max_bytes`, return `-EOPNOTSUPP` where the device has no
discard at all, and never discard outside a Block Group's data region --
not the superblock, the Zone Group or Block Group tables, the inode
bitmap or table, the Node Registry, the journals, the pending-free
queues, nor a Block Group's own header and bitmap.

Worth reading per device: `max_unmap_block_desc_count` says how many
ranges fit in one UNMAP command. The LIO simulation rig reports 1; real
arrays often accept many, which collapses thousands of ranges into tens
of commands. `sg_vpd --page=bl <dev>` prints it.

---

## What it costs

Measured on the simulation rig (loopback iSCSI, so a *floor* -- a real
array is slower; this is one of the numbers worth collecting from real
hardware):

| run size | per command |
|---|---|
| 4 KiB | 0.018 ms |
| 64 KiB | 0.018 ms |
| 1 MiB | 0.103 ms |
| 16 MiB | 0.076 ms |

Flat with size: **the cost is per command, not per byte.** What matters
is how many ranges are emitted, which is why batch wins and why
`max_unmap_block_desc_count` matters.

Note this is the FREE path, not `cetrafs_get_block()`, so none of
`docs/PERFORMANCE.md`'s per-block budget applies. But an `unlink` or a
punch that blocks for seconds is still a visible regression, and inline
discard on a heavily fragmented image is exactly that.

---

## Testing

The harness can cover this properly, which is **not** true of every
device feature -- unlike atomic CAW, a loop device implements discard
and really punches holes in its backing file. Verified:

```
50 MiB written to the loop device     -> 50M occupied
blkdiscard 40 MiB                     -> 10M occupied
```

So `du` on the backing image is a direct oracle: *did the space actually
come back?* A suite can write, delete, `fstrim`, and assert the image
shrank.

The real SCSI path is covered by the iSCSI rig: a LIO fileio backstore
with `emulate_tpu=1` and `emulate_tpws=1`, where the same `du` oracle
applies to the exported file. Verified end to end: 201M occupied,
`blkdiscard` of 150 MiB, 51M occupied.

Two gotchas found standing it up, both of which cost a cycle:

* The `sd` driver reads the logical-block-provisioning VPD **only at
  probe**. Changing `emulate_tpu`/`emulate_tpws` and rescanning leaves
  `provisioning_mode` at `disabled`; it needs a full iSCSI logout and
  login.
* With `emulate_tpws=0` Linux does not fall back to UNMAP, it simply
  reports `discard_max_bytes: 0`. Enable both, and give
  `max_write_same_len` a sane value or a large request fails with
  `Invalid field in cdb`.

### The assertions that matter

1. **Space actually returns** -- `du` on the backing file falls after a
   delete plus `fstrim`. Without this the whole feature can be a no-op
   and every other test still passes.
2. **No live block is ever discarded.** The content oracle
   (`churn_oracle.sh`) running across a trim pass, which knows what
   every byte of every file must be. This is the assertion the feature
   lives or dies on.
3. **A trim never writes a Block Group this node does not own** -- the
   cross-node half, which only `ctest` can reach.
4. **Metadata is never in a discarded range.** Easiest as a direct
   check: every range the implementation emits must fall inside some
   Block Group's data region.

### Negative controls

Each of the above needs the fault injected, or it proves nothing:

* Disable the ownership gate, run two nodes allocating in the same Zone
  Group while one trims, and corruption MUST appear. If it does not, the
  gate was not protecting anything and assertion 3 is decoration.
* Skip the claim (discard without marking the run used) under concurrent
  allocation, and the content oracle MUST fail. This is the one that
  proves the protocol, not just the plumbing.
* Point the trim at a metadata range deliberately and watch assertion 4
  fire.

The first version of `tests/kernel/cas_region_wide.sh` passed its own
negative control twice before it was right -- once because the key check
was not the primary defence, once because the assertion skipped the only
offset where the fault is visible. Expect the same here and budget for
it.

---

## As built (2026-11-10)

### The hand-back discard: the part this design was missing

`cetrafs_bg_release_empty()` hands an emptied Block Group back to the
unowned pool on the next heartbeat tick. So the space a deleted VM image
frees usually leaves this node's ownership within seconds -- long before
anyone runs `fstrim` -- and the "trim only what you own" rule above means
nobody would ever trim it. FITRIM alone would have returned almost none
of the space that matters.

The release therefore discards the Block Group's whole data region on
the way out, at the one moment that is safest for it: the group already
drained out of this node's allocator, its bitmap proven empty **on the
device** (`cetrafs_bg_release_bitmap_ready()`), and its descriptor not
yet FREE, so no peer can claim it. After the swap to FREE a discard
could land on a peer's first writes; before the drain, on ours. While
discard is on, space in the pool is then space already given back.

A group handed back while discard is OFF (`nodiscard`, or `discard=off`
in `controls`) reaches the pool undiscarded. FITRIM therefore has a pool
pass: it claims each pool group not marked `CETRAFS_BG_FLAG_DISCARDED`
(a CAS, so no peer can take it meanwhile) and hands it straight back
through the ordinary release, which drains it, proves it empty, discards
it and sets the mark. A marked group is skipped, so a pool is trimmed
once, not on every fstrim; a claim clears the mark, and so does a
release that did not discard. Only groups wholly inside the fstrim range
are taken. Before the pass existed, 200 GiB freed with discard off came
back as 1 GiB on an FC array (docs/internal/UNMAP-BENCHMARK.md);
`tests/kernel/fstrim_pool.sh`.

It is one command per Block Group (the block layer splits it at the
device's limit) and runs inside the heartbeat, so a pass may spend at
most a second starting discards. A group past the budget is kept, and
released (and discarded) on a later tick, and a Zone Group with such a
group is not given back whole that tick, so nothing reaches the pool
untrimmed while discard is on. One discard that hangs still holds the
tick for as long as the device takes -- the same exposure as any other
heartbeat I/O. On by default where the device supports discard;
`nodiscard` at mount or `discard=off` in `controls` turns it off.

### What happens on a device without UNMAP

* `discard_max_bytes` is 0: FITRIM returns `-EOPNOTSUPP` (fstrim says
  "the discard operation is not supported"), and the hand-back releases
  without a discard. `controls` shows `discard_supported: no`.
* The device takes discards but the target refuses one (`-EREMOTEIO`):
  counted (`discard_errors` in `info`), logged, and the blocks are freed
  regardless. Discarding is best effort; freeing is not.
* A discard whose outcome is UNKNOWN -- a timeout, a path or transport
  failure, a plain I/O error -- may still execute on the array, and an
  UNMAP landing after the blocks were handed out destroys the new data
  (bug class 30). Such a FITRIM run stays allocated (counted in
  `trim_leaked_blocks`), held from the scrub for `trim_quarantine_secs`
  (default 600; `trim_quarantined` in `info`) and reclaimed by it
  after that. The hold is in memory: a node that takes the run's Zone
  Group from an owner -- a peer after an unmount, a crash or a fence,
  or the same node re-attaching at mount -- keeps the scrub out of the
  whole group for its own `trim_quarantine_secs`
  (`trim_held_zone_groups`), since it cannot tell which leaks are such
  runs. Its bits are
  synced to the device before fstrim returns (a fence before writeback
  would otherwise hand a peer a bitmap reading FREE), and the pass
  stops. A hand-back keeps its Block Group DRAINED -- out of this node's
  allocator as well as out of the pool -- and marks it pending
  (`discard_pending_bgs`); every later pass discards it again, whatever
  `discard` is set to (turning it off does not cancel a command already
  sent), and only a discard whose outcome is known releases it. Its Zone
  Group is not given back meanwhile. The first time a group is kept
  this way the kernel says so, unratelimited, naming `discard=off` as
  the way to stop further groups being kept on a path that keeps
  failing (`discard_handback_unknown` counts the failures,
  `discard_handback_deferred` only the budget). The pending mark is on
  the device: `CETRAFS_BG_FLAG_DISCARD_PENDING` in the group's
  descriptor, set by compare-and-swap before the hand-back gives up on
  the group and cleared only by the release swap that follows a
  known-outcome discard. The mount and every Zone Group claim load it
  before deriving which groups may be allocated from, so an unmount, a
  crash or a node taking the Zone Group over keeps the group out of use
  and re-issues its discard (`tests/kernel/discard_pending_durable.sh`).
  A flagged group is proven empty before every re-issue; fsck notes a
  flagged group, and reports one holding data or in the pool. What the
  flag cannot do is fence the array: a command queued at a failed path
  can still land late, on a group the flag has since let go after a
  later discard succeeded -- the standing advisory-fence caveat
  (`docs/LOCKING.md`). It stops this filesystem handing the group out;
  it does not stop the array.
* Nodes on different paths decide for themselves: each checks its own
  view of the device.
* Nothing may rely on a discarded block reading zero. An unwritten file
  range reads zero because its extent is uninitialised, never because
  of what the device returns.

### Inline discard (`-o discard`, step 2; 2026-11-13)

Off by default; `mount -o discard` turns it on (the name ext4 and XFS
use for the same thing), `inline_discard=on|off` in `controls` switches
it per mount, and it is in force only while `discard` (the hand-back
switch) is on too -- `nodiscard` or `discard=off` stops both. The last
of `discard` and `nodiscard` on a command line wins.

* **Noted, never issued, on the free path.** A run freed in a Block
  Group this node owns -- the local free and the pending-free drain
  alike -- is appended to a per-mount queue (4096 ranges, preallocated;
  adjacent frees merge) under a spinlock: no I/O, no allocation, inside
  whatever locks the free holds. A full queue drops the range, counted:
  the blocks are free already, only the discard is lost, and fstrim
  still finds them.
* **A worker discards them a moment later** (one second after the
  first note, on the unbound workqueue), sorted and coalesced per
  Block Group, through fstrim's own cycle: under `trim_mutex`, claim
  the bits that read free NOW (`cetrafs_trim_claim_next()`, at most
  32 MiB a claim and never past the noted range), discard through
  `cetrafs_discard_issue()`, give back (`cetrafs_trim_release()`). A
  block reallocated since its free reads allocated and is not claimed,
  so it is not discarded; a group drained for hand-back or no longer
  ours refuses the claim. There is no second discard path.
* **Why no durability wait.** ext4 discards only after the journal
  commit that makes the free durable. Here every free in a group this
  node owns follows the publish that stopped referencing the blocks,
  and that publish is already on the device (rule 21) -- the same
  footing that lets fstrim discard any free bit at any moment. The
  delay is for batching only. fstrim ran rarely enough to hide a free that came
  before its publish; one second does not, so the premise is enforced
  rather than assumed: `source_invariants.sh` lists every function that
  feeds the queue (and every freeing pass of the tree helpers) with why
  its blocks are unreferenced on the device, and a new one fails until
  someone says so (2026-11-13: truncate and punch after the record CAS,
  evict after its claim on a dead record, reservation remainders and a
  defrag's uncommitted tail never referenced, the scrub's re-read
  blocks, a peer's pending free).
* **It gives up** -- drops what is queued, counted and logged with the
  reason -- when the mount is closing, stopped or read-only, when
  discard is turned off, and for five seconds after an allocation
  found every owned Block Group full (`cetrafs_inline_discard_pressure()`
  in the allocator's no-space path): its claims are space a writer
  cannot have, and an ENOSPC must not wait on the array.
* **Unknown and refused outcomes** are fstrim's: an unknown one keeps
  the run allocated, its bits synced, for the scrub once its quarantine
  is over (`trim_leaked_blocks`, see above) and ends the pass; a refused one frees the run
  and goes on. A run kept for an unknown outcome is freed later by the scrub, and
  that free is noted again: on a transport that keeps failing, the same
  run is retried at scrub cadence -- bounded, counted, never shared.
* **Lifetime (rule 20).** `cetrafs_inline_discard_close()`, from
  `cetrafs_free_sb_info()` on unmount and on every `fill_super`
  failure, after the heartbeat, scrub and defrag have stopped: it marks
  the queue closed under the lock a note queues the work under, then
  cancels the work synchronously, so nothing queues after it and no
  worker outlives the mount. A worker mid-pass stops after the range in
  hand.
* `info` counts `inline_discard_queued`, `_dropped` (full queue),
  `_gave_up`, `_cmds` and `_blocks`.

### Limits

* A FITRIM claim is at most 256 MiB; the run is out of the allocator's
  reach for the length of its UNMAP, so on a nearly full volume an
  allocation can see ENOSPC during an fstrim (ext4 has the same
  property).
* Every range is re-checked against its Block Group's data region in
  `cetrafs_discard_issue()`, the one function that issues a discard,
  and refused (`discard_refused`) rather than clipped.
* FITRIM trims the Block Groups this node owns: to trim a whole
  datastore, run it on every node.

### Tests

`tests/kernel/discard_unknown_outcome.sh` (unknown vs refused, for both
paths, each with its contrast; a write while a hand-back's discard is
unknown placed outside the kept group, which discard=off does not
release; a kept FITRIM run's bits read from the device),
`tests/kernel/discard_handback.sh` (the `du` oracle on the image, a
discard-off control, a device without discard, a FITRIM claim racing
the release of an emptied group),
`tests/kernel/fstrim.sh` (holes inside a group in use, kept files
checksummed from the device, a range-check control aimed at the bitmap
and into the data), `tests/kernel/fstrim_claim.sh` (a writer inside the
claim's window with a no-claim control that destroys its data; queued
and local double frees inside the window with no-hold controls that stop
the mount). Inline discard: `tests/kernel/inline_discard.sh` (the `du` oracle
with a no-option control, the two switches, a second mount stating
`discard`), `inline_discard_claim.sh` (a writer inside the worker's
claim window, with the no-claim control destroying its data),
`inline_discard_unknown.sh` (unknown keeps the run, refused frees it),
`inline_discard_give_up.sh` (space pressure and unmount, each with a
never-give-up control; a pending queue at unmount). The two-node
assertion -- a trim never writes a Block Group this node no longer owns
-- is still owed to `ctest/`, and so is the cost per command on a real
array.
