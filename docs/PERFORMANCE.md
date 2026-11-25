# Performance invariants

Every entry here is a **caching or batching decision on a path that runs
once per 4 KiB block, or once per heartbeat tick, or once per metadata
operation.** Each one has already been broken at least once and measured
on real hardware; each is restated as a rule, with the number it cost and
the test that now guards it.

The reason this file exists: none of these show up on the loop-device
suite. A loop device serves an "uncached" read out of the host page cache
for free and has no atomic CAW, so every one of these regressions
benchmarks as *zero* in `make check` and only appears on a real iSCSI/FC
LUN. `make check` proves correctness; it cannot prove speed.

Grep `PERF:` in the tree to find the guarded sites.

### The shape of the hot path

A streaming write at 150 MB/s allocates **~36,000 blocks per second**, and
`cetrafs_get_block()` runs per block. Anything added to it — a device
read, a CRC over a block, a lock, a round trip — is multiplied by 36,000.
A CRC32C over one 4 KiB descriptor is ~0.5 us, so **one such CRC per
owned BG per block saturates a core at a few tens of owned BGs.** That is
the budget. Treat any new per-block work as a regression until measured.

---

## 1. `cetrafs_alloc_pick_bg()` must not re-derive ZG ownership from disk

Ownership comes from `cetrafs_sb_zg_owned_cached()` (fs.c), populated when
the claim path confirms ownership. It is not an optimistic guess: a ZG
this node holds cannot change owner while it stays alive and mounted (a
peer only ever reclaims a *stale* owner's ZG).

**Broken once:** it called `cetrafs_read_zg()` — forced-uncached by design
— for every ZG on every call, so every block of a write paid
`zone_group_count` real device round trips. Reported as the whole
filesystem being "extremely slow".

## 2. `cetrafs_alloc_pick_bg()` must answer from the allocation cursor

The full scan reads every owned BG descriptor, each costing a CRC32C over
a full 4096-byte block. `sbi->alloc_bg_cursor` makes the steady state one
descriptor read instead of N.

This does not weaken the scan's best-fit rule, it realises it: best-fit
exists to keep filling a partly-used BG rather than spread, which is what
staying put does. It also keeps `cetrafs_alloc_data_block_near()`'s
contiguity hint landing — see 7.

**Cost of removing it:** O(owned BGs) per 4 KiB block, *growing* as a
filling node claims more ZGs — so throughput decays as a large file
progresses ("the 32 GiB copy gets slower as it goes"). A 64 MiB write does
16384 cursor hits and 0 scans; without it, 16384 full scans.

**Guarded by:** `tests/kernel/alloc_cursor.sh`

## 3. Whole-volume descriptor sweeps must not invalidate BGs this node owns

procfs `info` forces every BG descriptor fresh so a node sees a *peer's*
writes (`cetrafs_statfs()` did too, before it read the Zone Group records
instead -- see 21). It goes through
`cetrafs_bg_desc_refresh_foreign()` (alloc.c), which skips a BG in a ZG
this node owns: this node is its only writer, and
`cetrafs_bg_data_block_stats()` already folds in the accrued-but-unapplied
delta, so the forced read tells us nothing — while dropping the cached
descriptor throws away the exact block `cetrafs_alloc_pick_bg()` reads for
every owned BG on every allocation.

**This one was invisible for a release.** It was harmless until v0x0004
*by accident*: `cetrafs_bg_adjust_free_blocks()` used to read-modify-write
the descriptor in the buffer cache, so a BG being allocated from was
DIRTY — and `cetrafs_invalidate_block()` deliberately refuses to drop a
dirty buffer, so the sweep silently skipped exactly the hot ones. v0x0004
stopped dirtying it (see 4), leaving every descriptor clean, and the
unchanged sweep began succeeding on them too.

**Cost:** on a Proxmox host, `pvestatd` polls statfs on every storage
every ~10 s, wiping the allocator's cache mid-stream, repeatedly.
Measured ~200 MB/s -> ~120 MB/s, degrading further as the file grew.

**Guarded by:** `tests/kernel/statfs_keeps_bg_cache.sh`

**The general lesson:** a cheap cache-invalidation sweep may be cheap only
because something elsewhere happens to make it a no-op. Removing the
dirtying was correct; nothing connected it to the sweep that depended on
it. When you stop dirtying a buffer, go find who was relying on
`cetrafs_invalidate_block()` not being able to drop it.

## 4. Free-count updates must accrue in memory, never sync per allocation

`cetrafs_bg_adjust_free_blocks()` accrues into `sbi->bg_free_delta[]` and
sets a dirty bit; `cetrafs_flush_dirty_free_counts()` applies them with
one CAS per dirty BG at durability boundaries (file-lock close, namespace
lock release, evict, sync_fs, unmount).

**Broken once:** syncing unconditionally per call reintroduced one real
device round trip per block allocation — a 1 MiB write went from ~2 s to
~40 s.

Note the flush must keep clearing its dirty bits and `atomic64_xchg`-ing
the delta, so a flush stays O(BGs dirtied since the last one). Re-walking
every BG ever touched makes it quadratic over a long write.

## 4b. Allocation bitmap bits sync at the BOUNDARY, never per allocation

`cetrafs_bitmap_alloc_bit()` keeps `sync=false`; the BG is marked in
`bmap_alloc_dirty` (per-BG state in `struct cetrafs_bg_chunk`) and `cetrafs_alloc_flush_bitmaps()` writes those
bitmap blocks at the same durability boundaries as invariant 4 (close,
fsync, sync_fs, and the whole-record write (`__cetrafs_write_raw_inode()`)). One bitmap
write per BG allocated from since the last boundary, NOT one per block —
the per-block version is the same ~2 s → ~40 s regression invariant 4
describes, for the same reason.

**It is not optional.** The flush exists because a reference may not
become durable before what it refers to: close stamps the inode record
with a CAS that reaches the device immediately, and a node dying with
the bitmap still cached leaves blocks referenced by an inode and reading
FREE to every node, allocator included. See CLAUDE.md invariant 8 and
`tests/crash/` phase 6, which reproduces it in one shot when the flush is
removed. Moving it off the boundary to "save" the write re-opens a
data-corruption bug, not a performance trade.

**Measured, on the deployment LUN** (3 GiB O_DIRECT, 2 runs
each, pre-fix module vs fixed, same session):

| | write MB/s | read MB/s | write/read |
|---|---|---|---|
| without the flush | 517 | 705 | 0.733 |
| with the flush | 466 | 637 | 0.731 |

Both columns fell ~10%, *including reads, whose path this change does not
touch* — that is the SAN's other tenants, not the barrier. The ratio is
the control, and it moved 0.4%, well inside its own 0.714–0.760 spread.
No write-specific cost is resolvable. Use the read path the same way when
measuring anything else on this LUN: absolute numbers here drift with
production load, ratios do not.

## 5. The heartbeat re-attach path must not reconcile or re-seed every tick

In `cetrafs_zg_try_claim_one()` (zonegroup.c), the "already ours,
re-attaching" branch runs on **every heartbeat tick**.
`cetrafs_zg_reconcile_free_counts()` belongs to mount only, and
`cetrafs_bg_seed_count_epochs()` only when ownership ENTERS the cache
(`!was_cached`).

**Broken once:** seeding on every tick invalidated and re-read every BG
descriptor of every owned ZG — ~128 synchronous reads per tick on a 2 TB
volume — *and* threw away the descriptor cache the per-block allocation
path depends on. Measured as a ~40% loss of streaming write bandwidth.

Same mechanism as 3, different trigger. Anything that runs per tick and
touches the BG table is in this category.

The live-grow layout check (`cetrafs_sb_layout_refresh()`, called from
the heartbeat) is the one per-tick read of a global structure: block 0,
forced fresh, compared and dropped unless `layout_gen` moved. It never
touches the BG table on a tick where nothing grew; only an actual grow
reads the NEW Block Groups' descriptors, once.

## 5b. Zone Group claim/release updates both halves with immediate paired CAS

Zone Group ownership changes and Block Group handback move both the per-ZG
aggregate (`free_data_blocks`) and the per-ZG shard of unowned capacity
(`pool_free_blocks`) by one CAS each, debit before credit so any window in
between understates free space (never phantom space). They are **not** lazy
accruals applied later — both CAS writes land at claim/release time, running
on every heartbeat tick during the final quiesce window, and are thus
heartbeat-paced rather than per-block. The per-tick cost is bounded by ZG
count (typically 16), not block count — so the invariant stands. Lazy
accrual remains as a fallback if a CAS fails; late beats lost.

**Why this is not a hot path:** claim/release are not per-block — they happen
at mount and whenever ownership must transfer (typically seconds apart or at
explicit heartbeat rebalance), not 36,000 times a second. On a real device,
the two CAS writes (each a 512-byte atomic operation) are serialised by the
array's own atomicity and cost far less than the magnitude of the blocks they
move, so the CAS overhead is invisible against the durability boundary.

## 6. `cetrafs_read_bg_geom()`'s first attempt must stay on the cached path

Only the checksum-mismatch retries force a fresh read
(`cetrafs_invalidate_block()` then re-read). The first attempt is the
per-allocation hot path for a BG's own owner, whose cache is
authoritative.

## 7. The contiguity hint must keep landing

`cetrafs_alloc_data_block_near(preferred_lba)` starts each new block right
after the file's last extent. When it misses,
`cetrafs_alloc_data_block()` degrades to the four-pass run scan
(1024 -> 256 -> 32 -> 1 blocks), which gets slower as a BG fills.

It compounds: a miss means a new extent, a new extent means an
extent-tree leaf update, and a leaf update is a **journalled** write —
2 `blkdev_issue_flush` plus 3 synchronous waits, on a LUN where a
synchronous write is ~38 ms. Anything that makes `pick_bg` return a BG
other than the one holding the file's last extent pays all of that.

## 8. CAS must flush the target block before the CAW, and repopulate after

In `cetrafs_cas_region_seeded_impl()` (caw.c):

- `cetrafs_cas_flush_block()` before the CAW is **not optional**, even
  when seeding. A CAW compares against what is physically on the device;
  a dirty cached copy means the compare image is wrong and every first
  attempt miscompares. Skipping it took an empty create from 297 ms to
  550 ms on the real LUN — a wasted CAW *plus* the re-read and CAW it was
  trying to avoid.
- On success, a `sole_region` block is repopulated via
  `cetrafs_cache_region_after_cas()`, not dropped. Invalidating turns
  every swap into a later device read of a block about to be wanted again.

## 9. The journal's payload and header go out together

`cetrafs_journal_write_block()` issues both under one `blk_start_plug` and
waits once. They are adjacent LBAs, so the block layer usually merges
them. Ordering them (header last) is redundant — replay already verifies
`hdr->payload_checksum` and skips a torn payload — and costs a second
round trip on every create, mkdir and unlink.

## 10. `SB_NOATIME` is forced at mount

So reads stop generating inode-record dirt. This is a correctness
convenience and a performance one; don't make atime configurable without
accounting for the record writes.

## 11. `cetrafs_get_block()` must report contiguous runs

`map_bh()` hard-sets `b_size` to one block. A `get_block()` that stops
there forces every caller back once per 4 KiB however contiguous the file
is. `blockdev_direct_IO()`, `mpage_writepages()` and `mpage_readahead()`
pass a `b_size` covering the whole remaining request and use what we return to learn how
much got mapped, so reporting the run collapses the callback count.

**Measured:** an O_DIRECT read of 2048 contiguous blocks went from 2048
`get_block()` calls to **1**. O_DIRECT has no page cache to amortise the
callback, and qemu `cache=none` -- Proxmox's default for shared storage
-- is exactly O_DIRECT.

The run is **clamped to the caller's requested `b_size`, and that is
required for correctness, not just politeness**: `__block_write_begin()`
and `block_read_full_folio()` hand in a REAL `buffer_head` belonging to a
folio, sized to one block, and widening it past what they asked for
corrupts it. They ask for one block and must keep getting one. Same
contract as ext4's `_ext4_get_block()`.

Only within ONE extent: the extent arrays are append-only and unordered
at every depth, so physically adjacent extents are not necessarily
adjacent in the array and merging would cost a scan per lookup.

**Guarded by:** `tests/kernel/get_block_runs.sh` -- which asserts both
directions (runs for O_DIRECT and readahead, 1:1 for `read_folio`), so a
change that widens a folio's own buffer fails too.

## 12. A repeat lookup must not re-walk the extent tree

Invariant 11 collapses the callback count for the callers that offer a
window. The BUFFERED path is not one of them -- it hands in a real
`buffer_head` sized to one block and must keep getting one block -- so
every 4 KiB of a buffered write walks the tree from the record down.

On a compact file that walk is free: up to four extents live inline in
the record (depth 0), and the walk reads no block at all. Past that, only
interior index entries carry ranges (lo + span); the root slots' are
always unknown. The filter degenerates with fragmentation,
because the arrays are append-only and unordered, so a file written in
place for months ends up with leaves whose ranges are wide and nearly
empty -- "may hold this block" becomes true for most of them and the
walk reads most of them.

`cetrafs_inode_info.ext_*` remembers the last extent a walk resolved
(ext4's old `i_cached_extent`). Consecutive blocks fall inside it, so
the walk happens once per extent instead of once per block.

**Measured** on the reference FC array, 1 GiB rewritten at 64 KiB over a
file whose blocks were already allocated:

| | compact (2 extents) | fragmented, no cache | fragmented, cached |
|---|---|---|---|
| throughput | 1173 MB/s | 710 MB/s | **1091 MB/s** |
| per `get_block` | 1.16 us | 3.24 us | **1.44 us** |
| leaf+index reads per lookup | 0.00 | 4.39 | **0.12** |
| tree reads, whole run | — | 1,150,546 | **32,109** |

It is **keyed on the record it came from** (depth, entry count, block
count), so a mutation that changed the map misses instead of needing
every writer to remember to invalidate -- and it is only consulted where
`cetrafs_lock_held_for_write_locally()` already says a CACHED leaf may be
trusted, so it never widens that window. A preallocated extent is never
remembered: clearing its uninit flag rewrites a leaf without touching
any of the three keyed fields.

**Guarded by:** `tests/kernel/extent_cache.sh` -- which asserts the hit
counter moves AND runs its own negative control, because a content check
that skips the punched range passes whether the entry was invalidated or
not (the first version of that suite did exactly that).

## 13. A READ must not re-read the record per block

`cetrafs_get_block()` re-reads the inode record from the device whenever
the cache predicate says "not trusted". For a writer that predicate is
the write lock, and it must stay that strict: a writer mapping through a
stale tree allocates over a peer's extents. A READER asked the same
question and got the same answer -- not trusted, because a read-only
open holds no lock -- so every 4 KiB it mapped, holes included, cost a
synchronous device round trip.

The read paths (`read_folio`, `readahead`, an O_DIRECT lookup) ask
`cetrafs_lock_read_cache_trusted()` instead. A reader may trust its cache
because nothing it maps through can be freed under it: its open is
published in `read_open_nodes`, and every block-freeing path refuses
while a live peer is there -- defrag included, since 0.9.3. A peer can
only write blocks the file already has or add new ones, so a stale map
reads old contents or zeroes. Staleness is bounded by `file_seq`,
re-checked once a second and at the first read after every open; a
peer's stamp sends the reader fresh until the reconcile has dropped the
old tree. The function gives the write lock's answer whenever this node
has the file open for write, which is what makes it safe on the paths
that can write.

**Measured** on the reference FC array, 2 GiB data / 8 GiB sparse,
`read()` in 1 MiB:

| read-only open | before | after |
|---|---|---|
| default mount, sparse | 18 MB/s | **2051 MB/s** |
| default mount, data | 18 MB/s | **2361 MB/s** |
| nofilelock, file also open on a second node | 17 MB/s | **2393 MB/s** |

`.readahead` (it had none, so every page was its own 4 KiB bio) came in
the same change and lifted the read-WRITE data path too, 1834 to 2730
MB/s on the default mount.

A defrag pass THIS node runs on the file is no reason to distrust it
either. Each step relocates and edits the tree holding `inode_lock` and
`invalidate_lock` exclusively, and every reader's mapping holds one of
them; between steps the cache is this node's own newest tree. The pin
used to send every reader to the device, and the cost was not linear:
the tree was walked off the disk per 4 KiB, while readahead held
`invalidate_lock` shared across that walk -- the lock the pass needed
for its next step. A buffered read of a fragmented 1 GiB image during a
background pass had not finished after ten minutes. `tree_reads_fresh`
in procfs counts the tree reads the trust still withholds.

**Guarded by:** `tests/kernel/read_cache_trust.sh` -- device reads per
cold read-only pass, a held read-only fd keeping its map, a peer's stamp
still sending it fresh, and defrag refusing a file a peer has open; each
with the knob that breaks it. `tests/kernel/read_trust_defrag_pin.sh` --
a full read of a 4096-extent file during a paced pass takes 0 fresh tree
reads, against 7,974 with `read_trust_defrag_defers`.

## 14. An O_DIRECT write into a hole or preallocated space stays direct

`blockdev_direct_IO()` passes `DIO_SKIP_HOLES`, which maps a write inside
i_size with `create == 0`. A hole or a preallocated block came back
unmapped, the DIO code gave up on it (`-ENOTBLK`) and the VFS finished
the write through the page cache plus a synchronous flush -- under
`inode_lock`, so every such write ran at queue depth 1 whatever the
caller asked for. That is the first write to every block of a sparse
or fallocated VM image, and the `rand-write-4k-sparse` line of the
2026-11-03 host benchmarks: 1,232-1,510 IOPS against ~22,000 for
overwrites on the same arrays.

`cetrafs_direct_IO()` now passes `DIO_LOCKING` only, and a DIO write maps
with `create == 1`: a preallocated block as it is, a hole allocated
PREALLOCATED; the write's completion (`cetrafs_dio_end_io()`, deferred to
the DIO workqueue) converts the range once the data is on the device.
Until then the blocks read as zeros, so nothing -- a reader, a peer, a
crash -- can see what they held before. Three things came with it,
each found by measuring:

- **No allocation hint for a direct write**: it takes the next block of
  the file's reserved run. The buffered hint (end of the last array
  entry) went arbitrary once completions reordered the array; the run
  was refused, a new one claimed, and the next tree edit flushed the
  bitmap synchronously under `invalidate_lock` -- one write in four. A
  hint from the LOGICAL predecessor fixed that but cost a tree lookup
  per allocation, which on a randomly filled file is a walk of every
  leaf (below).
- **In-leaf coalescing** (`cetrafs_leaf_array_coalesce()`): a converted
  run grows an adjacent written extent instead of adding one. Without it
  a sequential fill converted out of order fragmented (4-5 extents per
  256 MiB, ~190 with the old hint as well); with it, 1.
- **Auto-defrag quiet period** (`auto_defrag_quiet_secs`): a declined
  file was re-queued on every new extent, i.e. on every random write
  into a hole -- 0.6 forced record reads per write.

`dio_fill_holes=0` restores the fallback (A/B and escape hatch);
`dio_fallbacks` in procfs `info` counts O_DIRECT writes that still go
through the page cache, and should stay at zero.

**Measured** on a 2 ms dm-delay device (loop-backed, 256 MiB file):

| 4 KiB O_DIRECT writes, QD32 | fallback | direct |
|---|---|---|
| random, into a hole | 243 IOPS | **5,688** |
| sequential, into a hole | 247 IOPS | **7,798** (1 extent) |
| random, into fallocated space | 143 IOPS | 288 |
| random overwrite (reference) | 7,907 | 7,907 |

**Measured** on a 1 Gbit iSCSI node (143 GB LUN, 8 GiB file, QD as
fio's `rand-write-4k-sparse`; two runs each, same module, A/B by knob):

| O_DIRECT writes | fallback | direct |
|---|---|---|
| random 4 KiB into a hole, QD32 | 1,357-1,371 IOPS | 1,578-1,597 |
| sequential 1 MiB into a hole, QD16 | 72 MiB/s | 94-95 (link-bound) |
| random 4 KiB into fallocated space, QD32 | 960-965 IOPS | 1,291-1,296 |
| random 4 KiB overwrite (reference) | | 21,019-21,226 |

Random writes into a hole on a real file stay bounded by the extent
tree, not the device: a file filled in random order has leaves whose
index ranges all span the whole file, so the lookup of a hole visits
most of them -- ~89 leaf reads per 4 KiB write at 62k extents (ftrace
profile on the 1 Gbit iSCSI node), with the submitting thread at 94%
system CPU. That cost predates this change (the buffered path did the
same lookup); making a missed lookup sub-linear is a design change.

A conversion inside a FULL extent leaf moves the converted block to
another leaf, and the source and the destination must reach the device
together. That used to cost a whole journal batch -- three cache
flushes -- per such write (`cetrafs_convert_source_durable()`), because
a boundary went in chunks of 16 that were atomic only one at a time. A
boundary is now one atomic batch, every entry durable before any
target, and an inode's held-back set is kept under half the journal so
it always fits (`cetrafs_deferred_capped()`); the extra batch is paid
only with no journal or one under 8 slots. Counted on a loop device: 79
cache flushes for 1500 random writes into a fallocated image with the
old writes, 13 without (`tests/kernel/convert_split_no_flush.sh`,
`convert_source_flushes` in procfs). On the FC array (2026-11-12,
`docs/internal/UNMAP-BENCHMARK.md`): 738 IOPS into a fresh fallocated
image as built, 174 with every tree edit journalled at once.

A direct write that does not cover whole blocks (a 512-byte guest
sector, say) is serialised: it waits for the file's in-flight direct
I/O before it starts and for its own before it returns, as in ext4.
Into a new block it must -- the DIO code zeroes the rest of that block,
and two such writes in flight zero each other's data
(`tests/kernel/dio_unaligned_race.sh`). Block-aligned writes, all that
a 4 KiB guest issues, keep their queue depth.

**Guarded by:** `tests/kernel/dio_no_fallback.sh` -- the fallback
counter, QD16 against QD1 on a 3 ms device, a sequential fill's extent
count, fio verify at QD32, and punches beside in-flight writes; with
`dio_fill_holes=0`, `dio_skip_convert=1` and the coalescing removed as
controls.

## 15. Buffered writes into preallocated space pay at fsync and close

**Cost, NOT MEASURED.** A buffered write into a preallocated extent
leaves the block "reads as zeros" on disk until its data is there
(rule 8); the blocks wait in the inode's pending set. At every fsync
and every close with a non-empty set, `cetrafs_convert_pending_locked()`
writes back the set's SPAN -- its first to its last pending block --
waits for it, and issues one device cache flush before the first
conversion. Until 2026-11-08 it wrote back the whole file, so an
O_DSYNC write of one block paid for every dirty page of a large image;
every caller already writes its own range back first (->flush, the last
close, fsync's range). A file with an empty set -- every O_DIRECT
writer, and any file not fallocated -- pays one emptiness check and
nothing else.

What this costs a workload that fsyncs a large, buffered, fallocated
file often has not been measured on real hardware; a loop device makes
the flush free. A set whose span covers most of the file still writes
most of it back.

**Guarded by:** `tests/kernel/buffered_pending_reads.sh`,
`pending_wb_cursor.sh` (correctness), `pending_convert_span.sh` (the
span: an O_DSYNC write leaves unrelated dirty pages alone).

## 16. Per-BG state is reached through the published layout, with no lock

Every per-BG accessor (`cetrafs_bgc()` in fs.c) does two acquire loads
-- the layout pointer and its count come from one snapshot -- and one
extra pointer step into a fixed chunk. That is the whole cost a live
grow adds to the per-block path. Do not put a lock, an RCU read
section or a reference count there: the layout is replaced by pointer
and old ones live until unmount precisely so readers need none. And an
address the validator would refuse as past the end refreshes the layout
first (`cetrafs_lba_run_past_end()`) -- off the per-block budget only
because a valid address never gets there; never call the refresh on a
path that valid I/O takes.

## 17. A pending-free drain sweeps its whole queue only when it has work, and in one read

A drain runs on every heartbeat tick for every owned Zone Group, and
rate limited from the allocation path. On a quiet tick it must cost what
the queue's occupancy costs: appends fill from the front, so it reads
from block 0 and stops at `CETRAFS_PF_DRAIN_EMPTY_RUN` (2) empty blocks
-- two uncached reads. Only a drain that finds an entry reads the whole
queue (`CETRAFS_PENDING_FREE_BLOCKS_PER_ZG`, 512 blocks, 2 MiB), which
correctness needs: a copy of a free past an empty run, left behind by a
drain that applied the other copy, freed a reallocated block (L19,
`cetrafs_zg_drain_one()`).

That sweep must be ONE batched read (`cetrafs_bread_uncached_batch()`:
every forced-fresh read submitted under one plug, then waited for), not
one serial read per block. Measured, at the 256-block queue of the time, on the deployment array (2026-11-10, two nodes,
one owned Zone Group, one node deleting the other's files; three
interleaved runs of each build, drain passes timed with ftrace):

| | before | after |
|---|---|---|
| quiet tick, median pass | 0.44 -- 0.52 ms | 0.37 -- 0.49 ms |
| the 1 MiB sweep read | -- | 1.09 -- 1.21 ms median, 2.0 ms max |
| 2000-file delete: all drain passes | 167 -- 185 ms | 223 -- 242 ms |
| the deleting node's 2000 `rm`s | 135 -- 151 s | 147 -- 157 s (noise) |

One serial uncached read costs ~0.25 ms there, so an unbatched sweep is
~64 ms per owned Zone Group per pass with work -- on every tick, once
UNMAP makes foreign frees continuous. Per owned Zone Group that has
entries, the batched sweep adds about 1.2 ms per pass; quiet ones add
nothing. A drain that consumed anything then reads the whole queue a
second time, after consuming (a copy appended meanwhile into a region
the first read found empty is held, not left for a later drain to
apply): one more batched read, so about 2.4 ms per pass with work --
unmeasured on the array, estimated from the row above.

The head is not the whole story, though: an entry a drain left behind
(a held copy, a busy region) or a peer's append that landed after the
sweep that emptied the head sits past it, and with only the head read,
nothing ever brought a drain back for it -- its blocks stayed allocated
(audit 2026-11-15 BM-3). So a queue whose last drain left something is
swept whole on every heartbeat drain until it does not, and every owned
queue is swept whole by the mount's drain and then one heartbeat drain
in `CETRAFS_PF_FULL_SWEEP_TICKS` (20): one batched 2 MiB read per owned
Zone Group every five minutes at the 15 s beat, about 1.2 ms each by the
row above. The allocation path's drain never does either. Counted by
procfs `pf_whole_sweeps`; `tests/kernel/pf_residue_found.sh`.

A busy region (a consume that keeps losing to appenders) is retried
with a back-off of 1 .. 128 ms, about a quarter of a second, only by a
drain that may wait: the heartbeat's and the mount's. A drain from the
allocation path runs inside a write, under its inode_lock and
invalidate_lock, so it tries a busy region once and holds its entries
for the next pass -- correct because of the hold, and a quarter second
per busy region off the write. Guarded by procfs `pf_drain_busy_waits`
and `tests/kernel/pf_alloc_drain_no_wait.sh`.

**Guarded by:** procfs `pf_drain_blocks` / `pf_drain_sweeps` (a quiet
volume's blocks per drain stay ~2 per owned ZG, beside the scheduled
`pf_whole_sweeps`; `tests/kernel/pending_free_backoff.sh`);
`tests/kernel/pf_stale_copy_later_drain.sh` (correctness). Neither
measures time -- a loop device serves the reads from the page cache.

## 18. A full extent leaf is split by range, never appended past

Random writes into a preallocated image split an uninit extent on
every write. Once the leaf holding the preallocation is full, a convert
that cannot fit its leaf must SPLIT it by logical range
(`cetrafs_tree_split_leaf()`): the lower half of its entries moves to a
new leaf and both get the exact range they hold. Appending the moved
pieces to the tree's last leaf instead -- what it used to do -- gave
every leaf filled that way a range spanning the file, and a lookup read
about half the leaves. And a depth-2 lookup finds its candidate leaves
in an interior under ONE hold of its buffer lock, not one per entry.

Measured on a loop device (4 GiB fallocated file, 4k random O_DIRECT
writes, qd16, fdatasync every 32): `cetrafs_tree_lookup()` 94 us -> 3.9
us per call, tree reads per mapped write 23 -> ~6, 1854 -> 5314 IOPS.
Before the journal batch change (d823296) the same run did 1290.

**Guarded by:** `tests/kernel/prealloc_random_lookup.sh` (tree reads
per lookup after random writes into a fallocated file; control
`leaf_split_off` restores the append) and procfs `leaf_splits` /
`convert_leaf_full` (the second should stay small next to the first).

A split leaves both halves part full, so on its own it would bring a
fragmented image to the tree's limit (four interiors) with fewer
extents than an append-only tree, which fills every leaf. At that limit
the append fills ANY leaf with a free slot instead
(`cetrafs_tree_insert_any_leaf()`, procfs `tree_any_leaf_inserts`),
giving it an unknown range: capacity is at least the append-only
tree's, and only lookups past the limit pay for it.
`tests/kernel/tree_full_any_leaf.sh` measures it on a capped tree
(control `tree_any_leaf_off`).

## 19. fiemap and SEEK_DATA/SEEK_HOLE pay for the map once, not per call

Both report a file's map, which for a depth-2 tree means flattening up
to ~258k extents out of ~1,000 tree blocks and sorting them. They did
both on EVERY call, and asked the write lock's freshness question while
doing it, so a node not holding the file for write read every tree
block from the device each time. filefrag makes hundreds of FIEMAP
calls and qemu's block status is one lseek pair per request -- all of
it under the inode lock, so the file's writers wait.

Now the tree is read under the reader rule
(`cetrafs_lock_read_cache_trusted()`, as invariant 13), and the sorted
map is kept on the inode while the file is open, reused while the
tree's identity is unchanged (`cetrafs_inode_sorted_runs()`: every
tree block's address, `eh_generation` and tail CRC, recomputed at each
use from cached headers). The close-time defrag nudge counts extents
under the reader rule too.

**Measured** on the reference FC array, a 16 GiB fallocated image after
60 s of 4k random writes (258,064 extents, 1,021 tree blocks):

| | before | reader rule | + kept map |
|---|---|---|---|
| filefrag | 285 s, 901,680 device reads | 42 s, 1,156 | **0.63 s**, ~1,000 |
| 300 SEEK_DATA/SEEK_HOLE pairs | minutes | 28.5 s | **0.52 s** |

The ~1,000 device reads left are one read of the tree per open (the
open is where a handoff lands), not per call.

The kept map has a memory budget of 1M runs (32 MiB). A tree past it
(a depth-3 tree holds 65.5M extents) is answered by windows: the 1M
runs of lowest start past the block asked about, found by one walk of
the tree, kept and reused while the caller moves forward inside it. A
full filefrag or `qemu-img` pass therefore costs one tree walk per 1M
runs, never a 2 GiB copy.

**Guarded by:** `tests/kernel/fiemap_reader_cache.sh` (device reads for
filefrag, a seek walk and a close; control `read_trust_off`),
`tests/kernel/seek_map_cache.sh` (one build per filefrag, and a held
fd's SEEK_DATA after an in-place convert; control `smap_trust_stale`),
`tests/kernel/seek_map_budget.sh` (windowed answers equal the whole
map's; control `smap_unbounded`), procfs `smap_hits` / `smap_builds` /
`smap_windows`.

## 20. A nofilelock open does not wait on a live peer's heartbeat

A nofilelock open of a file a not-yet-stale peer has open, while that
peer's journal is dirty, must not run past a DEAD node's unreplayed
journal (M-20). It learned that by watching the peer's row for its next
heartbeat -- and a live writer's journal is always dirty (held-back
batch entries stay live until the next batch retires them), so every
open of a migration source's image waited most of a beat: 8-15 s per
open, several per `qemu-img info`, and longer still when the wait lost
beats to the heartbeat tick (bug class 59).

Now the open first asks the journal itself
(`cetrafs_journal_node_redo_pending()`: every slot header in batches,
each current entry's target judged as replay judges it). When a replay
would redo nothing there is nothing to run past, alive or dead, and the
open goes on. Only an entry still to redo -- a dead node's, or a live
writer's caught between its journal flush and its target write, asked
again over ~70 ms first -- falls back to the wait, which now ends at the
peer's next beat.

**Measured** on the reference FC array, a 2 GiB image under 20 MB/s of
64k O_DIRECT writes on one node, opened on the other:

| | before | after |
|---|---|---|
| first open | 9 s (once 330 s) | 0.85 s |
| each later open / `qemu-img info` | up to a beat (15 s) each | 20-30 ms / 40-70 ms |

**Guarded by:** `tests/kernel/nofilelock_open_peer_fast.sh` (three opens
under 800 ms with a live peer's settled journal; control
`open_journal_peek_off`), procfs `open_peer_settled` /
`open_peer_waits`.

## 21. statfs reads the Zone Group table fresh at most once a second

`cetrafs_statfs()` reads the free counts from the Zone Group records,
forced fresh so a peer's allocations show, as one batched read of the
table (`cetrafs_zg_prefetch_all()`). That read is made at most once per
`statfs_fresh_ms` (1 s), one caller at a time
(`cetrafs_sb_statfs_fill_begin()`); in between, every record comes from
the buffer cache it filled. This node's own records are current there
(its CAS installs what it wrote), and a peer's are at most a second old.

**Cost of removing it:** statfs is callable by any user, as often as
they like. Per call, one fresh read of the table on the LUN every node
shares: a `df` loop in a container was read load on every node's
storage (audit M-32). Measured on a loop device, 3 s of an unprivileged
statfs loop: about 294,000 calls cost 5 read requests with the window,
one request per call without it.

**Guarded by:** `tests/kernel/statfs_fresh_once.sh` (control:
`statfs_fresh_ms=0`); the cost of one fresh read by
`tests/kernel/statfs_zg_batched.sh`.

## 22. A hole is looked up once, not once per block

A lookup that misses proves a hole, and in an unordered tree that means
reading every leaf whose range covers the block: its cost grows with the
file's extent count. A VM image is exactly a large, sparse, fragmented
file -- a qcow2 with metadata preallocation is all holes until the guest
writes -- and two paths paid that walk for every 4 KiB block of a hole:

- **An O_DIRECT write into a hole** allocated one block per get_block
  call, so the DIO code came back 256 times for a 1 MiB write. Now the
  blocks after the first, as far as the request, the hole and the file's
  reservation (`cetrafs_inode_take_reserved_run()`) all reach, go into
  the same extent and the same mapping, allocated preallocated and
  tracked for the completion together like any widened DIO mapping.
- **A read of a hole** (O_DIRECT or buffered): the DIO code and
  readahead ask for a hole one block at a time. Now the miss also works
  out where the hole ends -- from the leaves it read and the starts of
  the children it skipped, no extra I/O -- and the extent cache
  remembers the hole under its usual key. What fills a hole allocates,
  which moves the key's block count, and every conversion drops the
  cache besides; a remembered hole answers READS only, so a mapping that
  may allocate always walks for itself (`cetrafs_inode_ext_cache_lookup_hole()`).

The write side reuses the hole end its own lookup computed, so it walks
once per request, not twice.

**Measured** on an FC array, 1 GiB, in a file of ~49,000 extents against
one with none:

| | before | after | no extents |
|---|---|---|---|
| O_DIRECT 1 MiB write into a hole | 241-243 MB/s | 709-748 | 616-696 |
| O_DIRECT 1 MiB read of a hole | 829 MB/s | 13.0 GB/s | 14.1-15.8 GB/s |
| buffered read of a hole | 587 MB/s | 2.0 GB/s | 2.0-2.1 GB/s |

Lookup misses per GiB: 264,195 -> ~3,200 for the write, 262,144 -> 1
for the read. Inside a guest on a qcow2 of ~32,800 extents, a fresh
write ran at 175-234 MB/s depending on qemu's aio mode, against 455-510
on a near-empty image.

Not covered: a BUFFERED write into a hole still looks it up per block --
each page's allocation moves the key, so the hole is never reused
(`docs/internal/TODO.md`).

`dio_hole_runs` / `dio_hole_run_blocks` and `hole_cache_hits` in procfs
`info` count both.

**Guarded by:** `tests/kernel/dio_hole_run.sh` (control
`dio_hole_run_off=1`) and `tests/kernel/hole_cache.sh` (controls
`hole_cache_off=1`; `ext_key_no_blocks=1` with `ext_cache_skip_drop=1`,
under which a remembered hole hides writes, and `ext_cache_skip_drop=1`
alone, under which the key by itself keeps them visible).

## Measured baseline

On the reference hardware -- an enterprise FC array over 32GFC multipath (two
active/optimised paths under ALUA), arm64 Proxmox nodes, cetrafs 0.6+
with the allocator and statfs work below in place:

| workload | cetrafs |
|---|---|
| `dd bs=1M oflag=direct` (in-place rewrite) | **613-710 MB/s** |
| `dd bs=1M iflag=direct` (read) | **1.0-1.2 GB/s** |
| `dd bs=1M oflag=sync` | 340-424 MB/s |

The cetrafs direct figures are the range across 8 runs spread over three
nodes. **Quote the range, never a single number**: one node alone
produced 622, 707 and 624 MB/s on consecutive runs, so the spread within
a node is as wide as the spread between nodes.

For scale against the work recorded below: the same test measured
120 MB/s when the statfs-sweep regression was found, and the 0x0003
baseline it was compared against was about 200 MB/s.

What these numbers are NOT: a controlled benchmark. See the noise floor
in the measurement notes at the end.

**Always measure the raw device in the same session before concluding
anything about cetrafs.** The array is shared, and its own figure moves:
on 2026-10-29 the same LUN measured 564 MB/s at `bs=1M oflag=direct`
with no filesystem in the path at all, while cetrafs on it measured
470-543 -- 83-96% of a ceiling that was itself below this table's range.
A session that skips the raw control reads that as a 30% regression in
cetrafs. The same session A/B'd 0.9 against 0.8.2 on a freshly made
volume and found them within the run-to-run spread (0.9: 436 then 461;
0.8.2: 510 then 470), which is what the range above is warning about.

---

## Before changing any of this

- Loop-backed `make check` will **not** catch a regression in this file.
  Re-measure on real hardware, or on `ctest/`.
- A second write to the *same* filename overwrites already-allocated
  blocks and never calls `cetrafs_alloc_pick_bg()` at all. Benchmarking
  allocation needs a fresh filename every run; comparing an overwrite
  against an allocation has produced a wrong conclusion in this repo more
  than once.
- **The SAN is shared with production load, so throughput is not a
  controlled variable.** The same `dd` on the same build has measured
  505 MB/s and 695 MB/s on different nodes at different times. Any A/B
  taken minutes apart, or on two different nodes, is confounded by
  whatever else is hitting the array. Interleave the two configurations
  (A, B, A, B) and treat a difference smaller than the spread between
  repeats of the SAME configuration as noise.

  **That spread has been measured, and it is large.** Two back-to-back
  runs of the identical command on one node, same build, same file:
  678 vs 576 MB/s written (18% apart) and 1.1 GB/s vs 859 MB/s read
  (28% apart). So a single-run A/B showing less than ~30% difference
  measures nothing. A conclusion was drawn here from a 9.58 vs 10.33 s
  pair -- 8%, comfortably inside the noise -- and it was wrong.
- `/proc/fs/cetrafs/<dev>/info` exposes the counters that make these
  visible without a profiler: `bg_pick_cursor` / `bg_pick_scan` (is the
  per-block path scanning?), `bg_desc_kept` / `bg_desc_refreshed` (are
  sweeps wiping our own cache?), and `cas_ops` / `cas_miscompares`.
