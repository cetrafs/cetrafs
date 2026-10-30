# cetrafs — Technical Documentation


A clustered, shared-disk filesystem for Linux (positioned as "an alternative to
VMFS"). This document describes the on-disk format as defined in
`include/cetrafs.h`, and the actual state of the userspace tools and kernel
module as of this writing. This file is the format/overview reference;
`CLAUDE.md` in the repo root carries the engineering rules and invariants,
and `docs/` the long-form detail.

## Status at a glance

| Area | State | Notes |
|---|---|---|
| On-disk format (`include/cetrafs.h`) | Functional | `CETRAFS_VERSION` is bumped freely and never migrated; reformat to move between versions. Little-endian on-disk, portable across host byte order (every field `__le*`, guarded by `make endian-check`); tested on little-endian hosts (arm64, amd64) |
| `mkfs.cetra` | Functional | Full geometry, auto-tuned BG/journal sizing, `-z` clamped to the real BG count, `-N`/`-M` bounded by what the format can represent |
| `fsck.cetra` | Functional, repairs a defined subset | Four passes (structural, cluster metadata, content, namespace), plus reachability from the root and a `/lost+found`. `-r` repairs only what has one derivable answer and refuses entirely on anything ambiguous |
| Mount / umount | Functional | Validates the whole region map, not just the checksum; `-o ro` is a real read-only cluster observer; a device with no atomic CAW is refused if any peer is mounted |
| Namespace | Functional | create, mkdir, unlink, rmdir, rename, link, symlink, readdir, `user.*`/`trusted.*`/`security.*` xattrs. Directories grow through the same extent machinery as files |
| File data | Functional | depth-2 extent tree, up to 16 TiB/file; read/write/truncate/fallocate/punch-hole/fsync/mmap/`O_DIRECT`/`SEEK_HOLE`-`DATA`/`FIEMAP` |
| Allocation | Functional | Run-aware placement, per-BG and per-ZG cached free counts kept in sync and reconciled against the bitmaps whenever a node takes ownership of a Zone Group; a block in a peer's ZG is freed by queueing it to that peer, never by touching its bitmap |
| Zone Group ownership | Functional | Claim the minimum needed, one more on demand, release a surplus that has emptied, steal from a stale peer |
| Cross-node exclusion | Functional | Atomic COMPARE AND WRITE only. Per-inode namespace lock, whole-file exclusive open lock, read-presence bitmask, Node Registry rows, ZG ownership and the pending-free queue are all compare-and-swap on a single ≤512-byte record |
| Node liveness | Functional, best-effort | Heartbeat + staleness timeout, judged against the peer's own advertised tick rate; `fence_epoch` is the lease and a fenced node fails every write with `-EIO` until remount. Timeout-based, not consensus — the split-brain caveat below still applies |
| Journal | Functional | Per-**node** physical/redo log for dirent, xattr and extent-tree blocks; write-ahead, consumed within its own operation, replayed at mount, at reclaim, and by a heartbeat sweep |
| Integrity | Functional | CRC32C on every record and on the block tails of dirent, extent (leaf/interior) and xattr blocks (v0x000F), kernel-enforced on read with transient-tear retry; per-inode generation detects cross-node inode-number reuse |
| Introspection | Functional | `/proc/fs/cetrafs/<device>/{info,properties,cluster,controls}` (`controls` is writable: per-mount defrag toggles and bounded cluster timing) |
| Sparse-file APIs | Functional | `SEEK_HOLE`/`SEEK_DATA` and `FS_IOC_FIEMAP`, so `cp --sparse=auto`, `tar -S`, `qemu-img convert` and `filefrag` all work on a thin image |
| Discard / `UNMAP` | **Not built** | No `FITRIM`, no `discard` mount option. Space freed in the filesystem stays mapped in a thin pool for the life of the volume. Designed, not implemented: `docs/DISCARD-DESIGN.md` |
| Growing a volume | Functional, **OFFLINE only** | `growfs.cetra` extends the Block Group chain into space the device already has. It refuses while the volume is mounted anywhere, and that refusal is load-bearing: the tool relocates the Block Group table, which every mounted node reads from its cached superblock on the allocation path with no lock held. Growing without unmounting needs an RCU'd superblock swap, a `layout_gen` check on the heartbeat, and a node-registry capability gate; the registry half is in place (`live_grow_ready` in procfs), the other two are not |
| Not built | — | Multi-extent (spanned-across-LUNs) volumes, snapshot/clone resignaturing, VAAI-style offload beyond ATS (no `XCOPY`, no `WRITE SAME`), special files (`mknod`), `O_TMPFILE`, POSIX ACLs |

What is deferred and why -- along with the deployment requirements a
cluster must satisfy -- is documented at cetrafs.com.

## Design decisions (from `cetrafs.h` header)

- Default Block Group (BG) size: 1 GiB (mkfs can override)
- Global inode space: one inode bitmap + one inode table for the whole volume
  (not per-group, unlike ext2/3/4)
- Journals are per-**node**, not per-ZG (the per-ZG layout was multi-writer and
  unsound; changed since)
- Dense bitmaps: global inode bitmap and per-BG data bitmaps have no padding
  between bits
- Fixed-size directory entries (no variable-length dirent packing), each dirent
  block carrying a `{magic,crc}` tail in its slack
- Extents use an ext4-style tree: header + inline leaves/index, depth 0/1/2
- Cross-node exclusion is atomic COMPARE AND WRITE only; the SCSI Persistent
  Reservation backend was deleted in format v0x000E, along with the
  superblock's `lock_backend` field and the `PR_AWARE` feature. A record that
  is updated by compare-and-swap lives entirely in the first `CETRAFS_HOT_SECTOR`
  (512) bytes of its block, which is the atomic unit (one logical sector).

The Zone Group / Block Group split is the clustering primitive: a ZG is "owned"
by one cluster node at a time (`owner_node_id`) and owns a span of BGs that hold
the actual data. A node claims the ZG(s) it needs, one more on demand, releases
a surplus it has emptied, and steals a stale peer's.

## On-disk layout

All values are block LBAs, block size fixed at 4096 bytes. `Z` = zone group
count, `B` = block group count (both mkfs-time choices), `N` = Node Registry
capacity (`-M`).

```
LBA  0                  Superblock (1 block)
LBA  1 .. Z             Zone Group table (1 block per ZG)
LBA  1+Z .. Z+B         Block Group table (1 block per BG)
     ...                Global inode bitmap (inode_bmap_blocks)
     ...                Global inode table (inode_table_blocks, densely packed)
     ...                Node Registry (node_table_blocks, densely packed)
     ...                Per-ZG pending-free queues (pending_free_blocks_per_zg each)
     ...                Per-node journal area (N slices, node_journal_blocks each)
     ...                bg_regions_start → first Block Group region
     ...                BG region 1 .. B  (see below)
```

Every offset above is also stored explicitly in the superblock
(`zg_table_start`, `bg_table_start`, `inode_bmap_start`, `inode_table_start`,
`node_table_start`, `pending_free_start`, `node_journal_start`,
`bg_regions_start`, …), so nothing is hardcoded by position alone — a reader
only needs the superblock to find everything else. Mount validates the whole
map (every region start past block 0, no wrap, inside `total_blocks`, no
overlap, each count fitting its region), not just the superblock checksum.

### Block Group region layout

Each BG is a self-contained region: a header block, its own data bitmap, then
its data blocks. The bitmap is "self-describing" — it also has to account for
the blocks it occupies itself:

```
BG region (length_blocks total)
+--------------------+----------------------+--------------------------+
| header (1 block)   | data bitmap          | data blocks              |
| off 0              | off 1 .. 1+dbm-1     | off 1+dbm .. end         |
+--------------------+----------------------+--------------------------+
```

`dbm` (data-bitmap blocks) solves `L = length_blocks - 1` (header excluded)
against `BITS_PER_BLOCK = 4096*8 = 32768` bits/block:

```
dbm = ceil(L / (BITS_PER_BLOCK + 1))
```

Worked example, default 1 GiB BG (`length_blocks = 262144`):

```
L   = 262143
dbm = ceil(262143 / 32769) = 8
off_data_bmap   = 1
off_data_region = 9
data_block_count = 262144 - 9 = 262135   (~1023.96 MiB usable)
```

### Global inode table

Inodes are stored **one record per 4096-byte block**: a
record uses only ~204 of the block, the rest is zero padding. This is
deliberate — it makes a cross-node clobber of a block-mate record structurally
impossible (a cross-node data-loss class that packed records suffered). The
default inode count is 1 per 4 MiB, capped at 65536, so the 4 KiB stride does
not bloat a large device; `-N` overrides. The Node Registry packs densely by
contrast (128 bytes/row, many rows per block) — there are far fewer nodes than
inodes.

## On-disk structures

Sizes below are `sizeof()` on a `CETRA_PACKED` (byte-packed) struct — no
compiler-inserted padding. Every multi-byte field is `__le16/__le32/__le64`
and must be accessed through `cetrafs_le*()`/`cetrafs_cpu_to_le*()`; see
**Endianness** below.

### Superblock — `cetrafs_superblock_t` (424 bytes, block 0)

| Field | Type | Meaning |
|---|---|---|
| magic | `__le32` | `0xC4553770` |
| version | `__le16` | `CETRAFS_VERSION` — currently `0x0009`; bumped freely, never migrated. v0x0008..0x0009 is a temporary compatibility window: a volume from the previous release (0x0008) can be grown in place without reformatting; `growfs` stamps 0x0009 on any grown volume to gate older builds from attempting to mount it |
| sb_bytes | `__le16` | `sizeof(superblock)`, sanity check |
| block_size | `__le32` | fixed 4096 |
| total_blocks | `__le64` | device size in blocks |
| zone_group_count / block_group_count | `__le32` | Z / B |
| zg_table_start / bg_table_start | `__le64` | LBAs of the two descriptor tables |
| inode_bmap_start / inode_bmap_blocks | `__le64` | global inode bitmap |
| inode_table_start / inode_table_blocks | `__le64` | global inode table |
| bg_regions_start | `__le64` | LBA of first BG region |
| root_ino | `__le64` | inode # of `/` (always 1 today) |
| inode_size / inodes_count | `__le32` | on-disk inode size, total inode slots |
| bg_size_blocks | `__le64` | target BG span |
| cluster_id | `__le32` | arbitrary cluster identifier |
| node_table_start / node_table_blocks | `__le64` | Node Registry LBA + block count |
| node_table_count | `__le32` | Node Registry capacity (mkfs `-M`, default 64, ≤ `CETRAFS_MAX_READER_NODES`) |
| node_entry_size | `__le32` | `sizeof(cetrafs_node_entry_t)` on-disk |
| pending_free_start | `__le64` | LBA of the per-ZG pending-free queue region |
| pending_free_blocks_per_zg | `__le32` | queue blocks per ZG (`CETRAFS_PENDING_FREE_BLOCKS_PER_ZG`) |
| node_journal_start | `__le64` | LBA of the per-node journal area |
| node_journal_blocks | `__le32` | blocks per node (flag block + slots) |
| layout_gen | `__le64` | layout generation counter: incremented each time `growfs` relocates on-disk structures. Gates which nodes may mount a live volume during a grow (only nodes that understand `layout_gen` via `CETRAFS_NODE_CAP_LIVE_GROW`) |
| features_compat/incompat/ro_compat | `__le64` | feature bitmasks |
| checksum | `__le64` | CRC32C over the struct with this field zeroed (low 32 bits used) |
| uuid[16] | `u8[]` | filesystem UUID |
| reserved[144] | `u8[]` | padding to keep the struct growable |

### Zone Group Descriptor — `cetrafs_zone_group_t` (1 block per ZG)

Split into a **hot sector** (the first `CETRAFS_HOT_SECTOR` = 512 bytes, the
atomic compare-and-swap unit — ownership and the free-count aggregate live
here) and a **cold** remainder (mkfs-time-fixed and historical fields), each with its own
checksum.

| Field | Section | Meaning |
|---|---|---|
| zg_id | hot | 0..Z-1 (also validates the sector) |
| owner_node_id | hot | Node Registry row index of the owner, or `CETRAFS_NODE_ID_NONE` (`0xFFFF`) if unclaimed. Claimed/released/stolen by CAS at runtime |
| free_data_blocks | hot | cached aggregate of its member BGs' free counts; kept in sync by the owner and reconciled from the bitmaps whenever ownership arrives |
| hb_seq | hot | heartbeat seq from the owner |
| hot_checksum | hot | CRC32C over `[0, HOT_SECTOR)` with this field zeroed |
| pool_free_blocks | hot | capacity (free blocks) of unowned Block Groups sharded to this ZG (shard key: `bg_id % zone_group_count`, the same mapping `mkfs` uses for initial assignment). Maintained by CAS at claim (debit) and release (credit), both ordered so a crash between the two records understates free space. `fsck` cross-checks each shard against the actual unowned members. Placed after `hot_checksum` so pre-0x0009 volumes read it as zero (correct: every BG starts owned) |
| first_bg_id, bg_count | cold | **UNUSED** (v0x0009+). Block Group ownership is now stored in each BG's `owner_zg` field, not in the ZG's span — this lets a grow add Block Groups without touching any existing ZG record |
| cold_checksum | cold | CRC32C over the cold region with this field zeroed |

> **Note:** `mkfs.cetra` distributes BGs across ZGs ROUND-ROBIN (BG `b`
> belongs to ZG `b % Z`), not as contiguous spans: each BG names its own
> owner, so membership needs no contiguity, and interleaving spreads
> capacity across every ZG instead of giving each one a single run at
> one end of the device. Since v0x0009,
> BG ownership is carried by each Block Group itself (`cetrafs_block_group_t.owner_zg`),
> which also enables a node to hand back empty Block Groups and lets a grow add new ones
> without mutating existing ZG records. `owner_node_id` is left at `CETRAFS_NODE_ID_NONE` at
> mkfs time; a real node claims it at runtime. Journals are per-node (below).

### Node Registry — `cetrafs_node_entry_t` (128 bytes/entry, global table)

Packed densely (many rows per block). Maps a node's stable 128-bit machine UUID
to a compact row index — *that index*, not the UUID, is what `owner_node_id`
and the inode lock fields store elsewhere.

| Field | Meaning |
|---|---|
| node_uuid[16] | the node's stable machine UUID (`uuid.c`), raw 128-bit |
| state | `CETRAFS_NODE_STATE_FREE` (0) or `_REGISTERED` (1) |
| hb_seq | heartbeat sequence, bumped every heartbeat tick while mounted |
| last_seen | unix seconds of the last heartbeat write (backdated to the epoch on a clean unmount, so peers see the departure immediately) |
| label[32] | informational hostname, NUL-terminated; not used for identity |
| checksum | CRC32C over the row with this field zeroed |
| fence_epoch | the node's lease: bumped by whoever reclaims this row's claims; the owner self-fences when it changes |
| hb_interval_secs | this node's own tick rate, so a peer judges staleness against the rate the node actually beats at, not the observer's setting |
| caps | `__le32` bitmask of node capabilities (e.g., `CETRAFS_NODE_CAP_LIVE_GROW`), set by the node at registration. Gates features that require understanding new on-disk structures or sematics; a 0.8.x node without the bit cannot mount during a live grow |

`CETRAFS_NODE_ID_NONE` (`0xFFFF`) is the "no node" sentinel, capping real
registrations at 0xFFFE rows — but the read-presence bitmask (below) caps a
cluster at `CETRAFS_MAX_READER_NODES` (64), which `mkfs -M` enforces. `mkfs`
creates the table all-zero (every row `FREE`); `fsck` validates each non-`FREE`
row's state and checksum.

At mount (`kmod/node.c`'s `cetrafs_node_register()`, from `fs.c`'s
`fill_super()`), the module parses its own UUID and scans the table: a row
already carrying that UUID is re-attached (`hb_seq`/`last_seen` refreshed);
otherwise the first `FREE` row is claimed by CAS, read back to confirm, and
retried on a lost race. `kmod/heartbeat.c`'s periodic tick renews the row and
checks the fence epoch; `cetrafs_node_is_stale()` is the single place that
decides whether *another* node's row still counts as a live claim.

### Per-node journal — `cetrafs_node_journal_hdr_t` (flag block) + `cetrafs_journal_header_t` (per slot)

Each Node Registry row owns a private journal slice at
`node_journal_start + node_id * node_journal_blocks`: one
`cetrafs_node_journal_hdr_t` flag block (its `state` is CLEAN/DIRTY, and
`replay_owner` is CAS-claimed so exactly one node replays a dead peer's area)
followed by 2-block slots. Because a node only ever logs to its own slice, each
area is single-writer by construction.

A slot is a `cetrafs_journal_header_t` (a full block) followed by one payload
block holding the literal post-image of `target_lba`:

| Field | Meaning |
|---|---|
| magic | `CETRAFS_JOURNAL_MAGIC`; anything else = no valid entry |
| txn_id | monotonic per-node-session sequence; replay applies in this order |
| target_lba | the block this entry's payload is the full post-image of |
| payload_checksum | CRC32C of the payload block that follows |
| header_checksum | CRC32C over this header with this field zeroed |

**Write-ahead:** `cetrafs_journal_write_block()` (used by `dir.c`/`xattr.c`/`file.c`)
takes the target buffer *locked and not-yet-dirty*, writes+syncs the payload,
then writes+syncs this header as the commit marker, then lets the real in-place
write proceed and immediately **consumes** the entry (zeroes the header), so a
surviving entry always means its writer crashed mid-operation.

**Replay verifies before it redoes.** `prev_checksum` records what the target
held *before* the modification, and an entry is applied only while the target
still reads that way; if it holds the payload already the entry is skipped, and
if it holds neither, somebody has rewritten the block since and replay **refuses**
it loudly (`journal_replay_refused` in procfs). `F_FRESH` marks entries whose
target was a newly allocated block — nothing referenced it at crash time, so
there is nothing to repair and replay skips them outright. This used to be an
unconditional redo, justified by "the writer crashed while still holding that
operation's lock, so nobody else can have touched the target" — which is false
under `nofilelock`, where extent leaves have no cross-node lock at all, and cost
a corrupted VM image after an HA failover. Replay runs
at ownership boundaries only: a node's own area at mount, a stale peer's area at
the moment its ZG/lock is reclaimed, plus a heartbeat sweep for crashed nodes
nothing else touched. Only BG-data-region content is journaled (dirent, xattr,
extent leaf/interior blocks); the global tables are not.

### Pending-free queue — `cetrafs_pending_free_t` (16 bytes/entry)

A fixed-slot array per ZG (at `pending_free_start`). When a node frees a block
that lives in **another** node's ZG, it does not touch that ZG's bitmap; it
appends a `{lba, count, magic}` entry (one per extent) by CAS, and the owner
drains and applies it (idempotently) at mount, on every heartbeat tick, and
after an on-demand claim. Append and drain are both lock-free compare-and-swap.

### Block Group Descriptor — `cetrafs_block_group_t` (1 block per BG, in the BG table)

| Field | Meaning |
|---|---|
| bg_id | global BG id |
| owner_zg | owning ZG, per the span `mkfs` assigned it |
| start_block, length_blocks | absolute LBA + span of the BG region |
| off_bg_header/data_bmap/data_region | intra-BG offsets, relative to `start_block` |
| data_block_count, free_data_blocks | usable blocks, cached free count — deltas accrue in the owner's memory on every data-block alloc/free (also rolled up into the owning ZG's aggregate) and are applied by one epoch-guarded compare-and-swap per dirty BG at the durability boundaries |
| checksum | `__le64` CRC32C, computed by `mkfs`, verified by `fsck` and by the kernel's `cetrafs_read_bg_geom()` |
| reconcile_seq | v0x0004: the count's ownership EPOCH — advanced by every reconcile (a Zone Group ownership transfer rewriting the count from the bitmap truth), so a previous owner's late delta-apply detects the rewrite and drops instead of double counting, even when the recomputed count is byte-identical to what it expects |

### BG Header — `cetrafs_bg_header_t` (first block of each BG region)

Mirrors the Block Group Descriptor's layout fields plus a `gen` counter (bumped
on resize/repair, currently never incremented). `checksum` is likewise `__le64`
CRC32C, computed by `mkfs` and verified by `fsck`.

### Inode — `cetrafs_inode_t` (204 bytes, one record per block)

| Field | Meaning |
|---|---|
| ino | global inode number |
| mode, uid, gid, nlink | standard stat fields |
| size, blocks | bytes / 512B sectors |
| atime, mtime, ctime | timestamps |
| flags | `CETRAFS_INODE_*` (EXTENTS always set; XATTR set when an xattr block exists; SNAPSHOT/COMPRESSED reserved) |
| eh + et (union) | embedded extent-tree root: a header plus 4 inline leaf extents (depth 0) or 4 inline index entries (depth 1/2). `kmod/file.c`'s extent machinery walks all depths; see "Extents" |
| xattr_block | external xattr block, or 0. Lazily allocated by `kmod/xattr.c` on the first set; freed and reset to 0 when the last entry is removed. One block, no chaining |
| lock_owner_node, lock_mode | whole-file cross-node exclusive open lock (`kmod/lock.c`): `lock_owner_node` is a Node Registry row index (`CETRAFS_NODE_ID_NONE` while unlocked), `lock_mode` is `_NONE`/`_EXCLUSIVE`. A write-open claims it; any open from a *live* different node while locked gets `-ETXTBSY`; a stale holder's lock is reclaimed. Whole-file (VMFS-style), not POSIX byte-range. Reclaim keys off the owner's Node Registry row, so a long-held write-open never ages out on its own |
| ns_lock_owner | per-inode namespace lock (`kmod/nslock.c`): a *held* cross-node mutex scoping one namespace operation to the record(s) it mutates, CAS'd on the inode's own hot sector. `CETRAFS_NODE_ID_NONE` when unlocked (note: `0xFFFF`, not 0 — every creation site sets it explicitly) |
| read_open_nodes | presence bitmask (bit N = Node Registry row N has it open for read); set by CAS on a node's first read-open, cleared on its last. Lets unlink/rename refuse to destroy a file a live peer is still reading (`-ETXTBSY`). Caps the cluster at `CETRAFS_MAX_READER_NODES` |
| dirent_seq | directories only: bumped by every dirent-block mutation, so a reader can tell cheaply that nothing changed and reuse its cached blocks |
| generation | stamped once at allocation, preserved by every rewrite; detects cross-node inode-number reuse (a cached object of the wrong incarnation is unhashed and re-instantiated) |
| inode_checksum | `__le64` CRC32C; computed/verified by the kernel on every inode on every read/write (and by `mkfs`/`fsck` for the root) |

### Extents (format v2)

```
cetrafs_extent_hdr_t   (12 bytes: magic, entries, max, depth, generation)
cetrafs_extent_t       (16 bytes: logical block, 31-bit length [+uninit bit], phys hi/lo)
cetrafs_extent_idx_t   (12 bytes: logical block, leaf/interior phys hi/lo)
```

One extent spans up to 2^31 blocks (8 TiB), so a contiguous multi-TB image is a
handful of extents. The tree is up to **depth 2**: inode root (4 inline slots)
→ interior index blocks → leaf blocks → extents, ~344k extents, enough that a
dense file reaches the 16 TiB logical ceiling (the remaining hard limit is the
32-bit `ee_block`). Arrays are **append-only and unordered** at every depth — a
new block always has the highest offset, so growth is a single-block edit with
no sorted-insert/split/rebalance; readers (fiemap, SEEK, truncate/punch)
flatten and tolerate the unordered order. Leaf and interior blocks carry a
`cetrafs_blk_tail_t` `{magic,crc}` tail (v0x000F). Directories use the same
machinery but stay ≤ depth 1. `mkfs` writes only the trivial case (root as one
depth-0 extent); everything deeper is kernel-built, and `fsck` walks all depths.

### Directory entry — `cetrafs_dirent_t` (266 bytes, fixed size)

`inode (u64) + name_len (u16) + file_type (u8) + name[255]`. 15 entries fit per
4096-byte block, which also carries a `cetrafs_dirent_tail_t` `{magic,crc}` tail
in its slack. A lock-free reader that catches a peer's in-flight 4 KiB
write torn retries on the tail mismatch rather than mis-parsing.

### XAttr entry — `cetrafs_xattr_entry_t` (322 bytes)

`key[64] + value_len (u16) + value[256]`. The `xattr_block` is a dense array of
these (≈ 12 at 4096 bytes, with a `cetrafs_blk_tail_t` tail), an empty
`key[0]=='\0'` marking a free slot. `key` holds the full namespaced name.
`kmod/xattr.c` implements `user.*`, `trusted.*` (listed only to `CAP_SYS_ADMIN`)
and `security.*` (so SELinux labelling and overlayfs-as-lower work);
`security_inode_init_security()` stamps a new inode's label at creation. No
POSIX ACLs. `mkfs`/`fsck` do not create or walk this block.

## Checksums

CRC32C (Castagnoli), computed as `~crc32c(~0, buf)` over the region with its own
`checksum` field zeroed first (userspace: `userspace/crc32c.h`; kernel:
`linux/crc32c.h`, same init/final XOR convention so the two sides agree). The
CRC result is stored `cpu_to_le64(crc)`, so a volume written by a little-endian
node verifies identically on a big-endian one.

The kernel verifies checksums on read for: the superblock (at mount), Zone Group
descriptors (hot and cold), Block Group descriptors, Node Registry rows, every
inode, and the dirent / extent-leaf-or-interior / xattr block tails. All of
these are forced-fresh on the paths where staleness would matter, and a
transient mismatch (a peer's in-flight write seen torn) is retried a few times
with backoff before being declared real corruption.

## Feature flags

| Flag | Bit | Set by mkfs | Enforced |
|---|---|---|---|
| `INCOMPAT_EXTENTS` | 0 | yes | accepted at mount |
| `INCOMPAT_GLOBAL_ITBL` | 1 | yes | accepted at mount |
| `INCOMPAT_BIT2_UNUSED` | 2 | no | was `PR_AWARE`, removed with SCSI PR (v0x000E) |
| `INCOMPAT_NODE_REGISTRY` | 3 | yes | accepted at mount; gates the `node_table_*` SB fields |
| `ROCOMPAT_SPARSE` | 0 | no | — |

`cetrafs_fill_super()` refuses any incompat bit outside `CETRAFS_KNOWN_INCOMPAT`
(so an unknown-incompat volume will not mount), and mounts read-only on any
ro_compat bit outside `CETRAFS_KNOWN_RO_COMPAT`. `fsck` carries copies of both
known sets and reports an unknown bit, since whatever stops a mount must be
something the checker can name.

## Tools

### `mkfs.cetra <blockdev> [-z ZGs] [-b BG_MiB] [-N inodes] [-J MiB] [-M nodes] [-n] [-f]`

- `-z`: zone groups, 1..255, default 16 (clamped down to the real BG count)
- `-b`: BG size in MiB, min 512, default 1024 (auto-shrunk to 512 when omitted on a small device — see below)
- `-N`: total inodes, default 1 per 4 MiB capped at 65536, bounded by what the superblock's `__le32` can hold
- `-J`: per-**node** journal size in MiB, default 2, 0 disables (capped so the total across all `-M` node slots stays ~5% of the device)
- `-M`: Node Registry capacity (max cluster nodes), default 64, ≤ `CETRAFS_MAX_READER_NODES` (the read-presence mask width)
- `-n`: dry-run (compute & print layout only)
- `-f`: force (overwrite even if the device looks non-empty)

Solves `B` from the remaining space after fixed metadata (SB + ZG table + inode
bitmap/table + Node Registry + pending-free queues + journals), lays out and
zero-initializes every structure, writes SB/ZG/BG-descriptor/BG-header
checksums, creates the root directory block and inode (with its tail/checksum),
distributes BGs across ZGs, and prints a summary. `-z` is clamped to `B` in a
bounded two-pass solve; exit code is 0 on success, 2 on usage error.

**Auto-tuning (when `-b`/`-J` are omitted):** there is no fractional trailing
BG, so a device whose size isn't a clean multiple of the BG size loses its tail
to rounding — on a small device the flat 1024 MiB default can waste a large
fraction. `cetrafs_solve_bg_count()` falls back 1024 → 512 MiB when 1024 would
waste > ~10%; the journal default caps the *total* reservation at ~5% of the
device. Both are no-ops on normal/large devices and bypassed by passing `-b`/`-J`.

### `fsck.cetra [-r] <blockdev>`

Four passes: **structural** (SB/ZG/BG/root checksums and the region map, ZG↔BG
ownership contiguity, Node Registry rows), **cluster metadata** (per-node
journal flags and slots, pending-free queue entries), **content** (inode bitmap
vs the extent trees in both directions, cross-file overlap, counts vs bitmaps),
**namespace** (every directory's dirents and tails, nlink vs referring entries,
`.`/`..`, reachability from the root). It refuses to run on a volume that is
mounted locally or carries a live Node Registry row.

`-r` repairs only what is mechanically derivable with one right answer — a
leaked or double-claimed bitmap bit, a drifted free count, an nlink, an orphan
with a lost dirent (linked into `/lost+found`), a reclaimable `nlink==0` inode —
and **refuses entirely, loudly**, on anything ambiguous (cross-file overlap, an
unreadable record), where guessing could turn a contained fault into cross-file
corruption. Exit codes: 0 clean, 1 problems found, 2 usage, 3 could not examine.

## Endianness

The on-disk format is little-endian and **portable across host byte order**.
Every multi-byte field is `__le16/__le32/__le64` and is accessed only through
`cetrafs_le*()`/`cetrafs_cpu_to_le*()` — never raw. `make endian-check` runs
sparse (≥ 0.6.5) over the kernel module, the userspace tools and the test poke
helpers and must report 0: a raw `__le` access or a wrong-direction conversion
is a type error. On a little-endian host the format is byte-identical to its
pre-portability state (no reformat needed).

## Kernel module (`kmod/`)

| File | Role |
|---|---|
| `kmod.c` | module init/exit; registers the `file_system_type`, the inode cache and the procfs root |
| `fs.c` | `mount`/`fill_super`/`kill_sb`, the private `cetrafs_sb_info`, and the mount-time safety gate. Validates magic, version, block size, device size, SB CRC32C, feature bits and the full region map before accepting a volume |
| `inode.c` | the inode I/O choke point: `cetrafs_iget()`, `cetrafs_read_raw_inode()`/`_write_raw_inode()`, `cetrafs_apply_raw_to_vfs_inode()` and the refresh guards (generation, type, dirty, `nlink == 0`) every cross-node refresh path inherits |
| `dir.c` | directories and the whole namespace surface: lookup, readdir, create, mkdir, unlink, rmdir, rename, link, symlink, the dirent helpers and the dirent-block tail checksum |
| `nslock.c` | the per-inode namespace lock — acquired over the set of records an operation mutates, in ascending inode order |
| `file.c` | file data: the depth-2 extent tree, `cetrafs_get_block()`/`cetrafs_inode_map_block()`, truncate, fallocate, fsync, `O_DIRECT`, `SEEK_HOLE`/`DATA`, `FIEMAP`, and the defrag ioctl |
| `defrag.c` | online, incremental defragmentation — whole-extent-aligned steps under the file's own cross-node lock, plus the background janitor |
| `xattr.c` | `user.*`/`trusted.*`/`security.*` extended attributes over the inode's one lazily-allocated xattr block |
| `alloc.c` | allocation primitives: global inode bitmap and per-BG data bitmaps, run-aware placement, the cached free counters and their reconcile, and the delegated (pending-free) path for a block in another node's ZG |
| `zonegroup.c` | Zone Group ownership: claim the minimum, one more on demand, release a surplus, steal from a stale peer, drain the pending-free queues, reconcile free counts when ownership arrives |
| `lock.c` | the whole-file cross-node exclusive open lock, the read-presence bitmask, and the per-inode in-core state (`cetrafs_inode_info`) |
| `node.c` | Node Registry rows: registration by stable UUID, heartbeat renewal, staleness, the fence epoch, and clean-departure marking |
| `caw.c` | atomic COMPARE AND WRITE (SCSI opcode `0x89`) and the compare-and-swap built on it — `cetrafs_cas_region()`/`_record()`/`_record_seeded()`, plus capability discovery |
| `journal.c` | the per-node physical/redo journal: write-ahead commit, replay, and the CAS replay claim |
| `heartbeat.c` | the periodic tick: self-fence check, row renewal, stale-ZG reclaim, pending-free drain, surplus release, stale-peer journal sweep |
| `ioutil.c` | forced-fresh reads, block invalidation, the buffer-update protocol, and the whole-block tail checksum |
| `super_ops.c` | `put_super`/`write_inode`/`sync_fs`/`statfs`/`evict_inode` and `reconfigure` |
| `procfs.c` | the read-only `info`/`properties`/`cluster` and the writable `controls` files under `/proc/fs/cetrafs/<device>/` |
| `uuid.c` | the stable per-machine UUID that identifies this node in the registry |

## Other notes

- **Never `rmmod -f` cetrafs.** Forcing removal bypasses the in-use refcount
  check and can yank the module's code out from under a superblock object whose
  per-sb shrinker is still registered, leaving a dangling entry in the kernel's
  global shrinker list. That Oopses on the next memory-reclaim pass and persists
  until reboot. Plain `rmmod` refuses with "Module cetrafs is in use"; umount
  cleanly first.
- `make check` is the test suite and uses loop-backed images only.
  `tests/device/` and `ctest/` are the opt-in, destructive, real-hardware
  suites — they name the device explicitly and never default to one.
  `tests/fuzz/` fuzzes the mount/fsck parse boundary.
- Several `reserved[]`/`pad[]` fields (`cetrafs_superblock_t`,
  `cetrafs_zone_group_t`, `cetrafs_inode_t`, `cetrafs_node_entry_t`) are
  deliberate reserve: new fields have been taken from them more than once
  without a format bump, since a zero-filled reserve reads as the correct
  default (e.g. `fence_epoch`/`hb_interval_secs` came from the Node Registry's).
