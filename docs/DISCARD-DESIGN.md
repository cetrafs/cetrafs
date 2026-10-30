# UNMAP / discard: giving space back to a thin LUN (design, pre-implementation)

cetrafs issues no discard of any kind today. There is no `FITRIM`, no
`blkdev_issue_discard` call, no `discard` mount option. Space freed in
the filesystem stays mapped in the array's thin pool for the life of the
volume, so a datastore that has ever been full stays full as far as the
array is concerned.

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

While the bits are set nothing can take the run -- not the allocator,
not the scrub (which skips anything that reads allocated), not a peer
(which cannot allocate from a Zone Group it does not own). A crash
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
* `cetrafs_alloc_inode_still_owned()` -- the model for a fresh,
  narrow re-verification immediately before acting.
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
