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

`cetrafs_statfs()` and procfs `info` force every BG descriptor fresh so a
node sees a *peer's* writes. Both go through
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
`sbi->bmap_alloc_dirty` and `cetrafs_alloc_flush_bitmaps()` writes those
bitmap blocks at the same durability boundaries as invariant 4 (close,
fsync, sync_fs, and `cetrafs_write_raw_inode(sync=true)`). One bitmap
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
is. `blockdev_direct_IO()` and `mpage_writepages()` pass a `b_size`
covering the whole remaining request and use what we return to learn how
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
directions, so a change that widens the buffered path fails too.

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
