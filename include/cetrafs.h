/* SPDX-License-Identifier: GPL-2.0-or-later OR AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary */
/*
 * cetrafs.h — on-disk structures & constants.
 *
 * The single source of truth for the on-disk format, shared verbatim by
 * the kernel module and the userspace tools. CETRAFS_VERSION (below) is
 * the format version; it is bumped freely and never migrated (pre-1.0,
 * no backward compatibility -- reformat to move between versions).
 *
 * Shape of the format:
 *  - Default Block Group (BG) size 1 GiB (mkfs can override).
 *  - Global inode space: one global inode bitmap + one global inode table.
 *  - Per-NODE journals (one private slice per Node Registry row); BGs and
 *    ZGs do not have their own journals.
 *  - Dense bitmaps (global inode bitmap; per-BG data bitmaps).
 *  - Fixed-size dirents.
 *  - ext4-style extent tree (header + leaves/index, depth 0-2).
 *  - Cross-node mutual exclusion is atomic COMPARE AND WRITE (caw.c); a
 *    device without it can only be mounted single-node (the mount gate
 *    enforces that). The earlier SCSI PR backend was removed.
 *
 * ENDIANNESS: the on-disk format is little-endian and PORTABLE across
 * host byte order. Every multi-byte field is __le16/__le32/__le64 and
 * MUST be accessed through the cetrafs_le*()/cetrafs_cpu_to_le*() helpers
 * below -- never read or written raw. `make endian-check` runs sparse
 * (>= 0.6.5) over the kernel module, the userspace tools AND the test
 * poke helpers, flagging any raw __le access or wrong-direction
 * conversion as a type error; it is 0 and must stay 0. (The all-__le
 * migration from the earlier __le/plain-native mix is complete -- see
 * git history.) checksums are stored cpu_to_le of the CRC, so a volume
 * written by a little-endian node verifies identically on a big-endian
 * one and vice versa.
 */

#ifndef CETRAFS_LAYOUT_H
#define CETRAFS_LAYOUT_H

#ifdef __KERNEL__
# include <linux/types.h>
# include <linux/stddef.h> /* offsetof, for the record-layout asserts */
# define CETRA_PACKED __packed
#else
# include <stddef.h> /* offsetof, for the record-layout asserts */
  /* Userspace: try to use the __le* from the linux headers if available
   * altrimenti fai fallback. */
# ifdef __CHECKER__
   /* sparse does not implement __has_include, and skips the plain
    * fallback typedefs below so raw __le access is flagged -- so it must
    * get the real __bitwise __le* from here. Pull them explicitly (the
    * header has its own include guard, so a file that also includes a
    * linux header is unaffected). */
#  include <linux/types.h>
#  define CETRA_HAVE_LINUX_LE_TYPES 1
# elif defined(__has_include)
#  if __has_include(<linux/types.h>)
#   include <linux/types.h>              /* porta __le16/__le32/__le64 */
#   define CETRA_HAVE_LINUX_LE_TYPES 1
#  endif
# endif
# include <stdint.h>
  typedef uint8_t  u8;
  typedef uint16_t u16;
  typedef uint32_t u32;
  typedef uint64_t u64;
  /* Under sparse (__CHECKER__), <linux/types.h>'s __le* are __bitwise and
   * must be the ones in scope so raw access is flagged; defining our own
   * plain typedefs then would both lose the check and clash. So the
   * fallback is only for a plain compiler that genuinely lacks them. */
# if !defined(CETRA_HAVE_LINUX_LE_TYPES) && !defined(__CHECKER__)
  typedef u16 __le16;
  typedef u32 __le32;
  typedef u64 __le64;
# endif
# define CETRA_PACKED __attribute__((packed))
# include <endian.h>
# include <string.h>   /* the shared inline record helpers below */
#endif

/* Portable little-endian field access, so the shared inline helpers below
 * convert correctly in both the kernel and the userspace tools. */
#ifdef __KERNEL__
# define cetrafs_le16(x)        le16_to_cpu(x)
# define cetrafs_le32(x)        le32_to_cpu(x)
# define cetrafs_le64(x)        le64_to_cpu(x)
# define cetrafs_cpu_to_le16(x) cpu_to_le16(x)
# define cetrafs_cpu_to_le32(x) cpu_to_le32(x)
# define cetrafs_cpu_to_le64(x) cpu_to_le64(x)
#elif defined(__CHECKER__)
/* Under sparse, glibc's le16toh() is a plain-int macro that would neither
 * strip nor require the __le __bitwise type -- so it cannot validate the
 * userspace tools the way le16_to_cpu()'s __force casts validate the
 * kernel. These __force variants give sparse the same checking for
 * userspace (a raw __le access is flagged, a wrong-direction conversion
 * is a type error); the real glibc path below is what actually compiles. */
# ifndef __force
#  define __force __attribute__((force))
# endif
# define cetrafs_le16(x)        ((__force u16) (x))
# define cetrafs_le32(x)        ((__force u32) (x))
# define cetrafs_le64(x)        ((__force u64) (x))
# define cetrafs_cpu_to_le16(x) ((__force __le16) (u16) (x))
# define cetrafs_cpu_to_le32(x) ((__force __le32) (u32) (x))
# define cetrafs_cpu_to_le64(x) ((__force __le64) (u64) (x))
#else
# define cetrafs_le16(x)        le16toh(x)
# define cetrafs_le32(x)        le32toh(x)
# define cetrafs_le64(x)        le64toh(x)
# define cetrafs_cpu_to_le16(x) htole16(x)
# define cetrafs_cpu_to_le32(x) htole32(x)
# define cetrafs_cpu_to_le64(x) htole64(x)
#endif

/* --------------------------- */
/* ---- General constants ---- */
/* --------------------------- */

#define CETRAFS_NAME                 "cetrafs"
#define CETRAFS_MAGIC                0xC4553770
/* Reset to 1: the 0x0001..0x000F run was development
 * churn, every step reformatted per the no-compat policy, so the
 * numbers carried no information worth keeping. Historical write-ups
 * (CLAUDE.md, docs) still say "format v0x000B" etc. about that era. */
#define CETRAFS_VERSION              0x0008
#define CETRAFS_BLOCK_SIZE           4096U

/* CAS granularity (v0x0009): the smallest region an
 * atomic COMPARE AND WRITE can cover on any device we support is ONE
 * logical block, and the real deployment target reports 512 bytes with a
 * 1-block maximum (probed: "class=scsi logical_block_size=512
 * max_caw_blocks=1"). So any record that must be atomically
 * compare-and-swapped keeps its mutable ("hot") fields AND the checksum
 * covering them entirely within the first CETRAFS_HOT_SECTOR bytes of
 * its own block -- that whole sector is the CAS unit, supplied verbatim
 * as the compare image.
 *
 * Which records this applies to, and why the others don't need it:
 *  - inode record (188 B) and Node Registry row (128 B): already alone
 *    at offset 0 of their own block since v0x0007, with a zero-filled
 *    remainder, so their first sector is already a deterministic,
 *    self-checksummed CAS unit. No layout change was needed.
 *  - Zone Group record: multi-writer (ANY node claims/releases a ZG,
 *    and the owner rolls free-block deltas into it), 4096 B with one
 *    whole-struct checksum -- so it IS split below.
 *  - Block Group descriptor: NOT split, but its count writes ARE a CAS
 *    as of v0x0004. "Only the owner writes it" held per instant but not
 *    across an ownership transfer: a node declared stale while alive
 *    still flushed its counts over the counts the stealing peer's
 *    reconcile had just rewritten. All real fields sit inside the first
 *    sector (the CAS unit) and the rest of the block is zero by
 *    construction, which is what lets the whole-block checksum be
 *    recomputed from the sector image alone (alloc.c's
 *    cetrafs_bg_image_crc()).
 */
#define CETRAFS_HOT_SECTOR           512U

#define CETRAFS_FILENAME_MAX         255

#define CETRAFS_XATTR_KEY_MAX        64
#define CETRAFS_XATTR_VALUE_MAX      256
#define CETRAFS_MAX_XATTRS           16

#define CETRAFS_MAX_ZONE_GROUPS      255U

/* Default BG sizing (mkfs can override sb.bg_size_blocks) */
#define CETRAFS_DEFAULT_BG_SIZE_BYTES  (1ULL << 30) /* 1 GiB */

/* Derived sizing helpers (mkfs can override policies) */
#define CETRAFS_BITS_PER_BLOCK      (CETRAFS_BLOCK_SIZE * 8ULL)
#define CETRAFS_DIV_ROUND_UP(n,d)   ( ((u64)(n) + (u64)(d) - 1ULL) / (u64)(d) )

/* BG fixed geometry */
#define CETRAFS_BG_HEADER_BLOCKS    1ULL   /* first block is the BG header */

/* mkfs defaults (policy-level, not ABI): bytes-per-inode ratio */
/* One inode slot per 4 MiB of device (v0x0007: each slot is a whole
 * block now -- see cetrafs_calc_inode_table_blocks() -- so the old
 * ext4-ish 1-per-256KiB default would spend ~1.6% of the device on the
 * table; this project's target workload is a handful of huge VM disk
 * images, not many small files). Floor/cap in
 * cetrafs_default_inodes_for_bytes() below; -N overrides as always. */
#define CETRAFS_DEFAULT_INODE_RATIO (4ULL * 1024ULL * 1024ULL)
#define CETRAFS_DEFAULT_INODES_MAX  65536ULL

/* ---- Superblock (block 0) ---- */
typedef struct {
    /* Identity */
    __le32 magic;                 /* CETRAFS_MAGIC */
    __le16 version;               /* structure version */
    __le16 sb_bytes;              /* sizeof(superblock) for sanity */

    /* Geometry */
    __le32 block_size;            /* bytes; 4096 for now */
    __le32 pad0;
    __le64 total_blocks;          /* device size in blocks */

    /* Topology counts */
    __le32 zone_group_count;      /* Z (<= CETRAFS_MAX_ZONE_GROUPS) */
    __le32 block_group_count;     /* B */

    /* Global directory offsets (LBA in filesystem blocks) */
    __le64 zg_table_start;        /* = 1 */
    __le64 bg_table_start;        /* = 1 + Z */

    /* Global inode structures (contiguous ranges) */
    __le64 inode_bmap_start;      /* start block of global inode bitmap (LBA) */
    __le64 inode_bmap_blocks;     /* number of blocks for inode bitmap */
    __le64 inode_table_start;     /* start block of global inode table (LBA) */
    __le64 inode_table_blocks;    /* number of blocks occupied by inode table */

    /* Where BG DATA regions begin (first BG region's start LBA) */
    __le64 bg_regions_start;

    /* Global inode numbering */
    __le64 root_ino;              /* inode # of / */
    __le32 inode_size;            /* sizeof(cetrafs_inode_t) (on‑disk) */
    __le32 inodes_count;          /* total inodes in the global table */

    /* BG geometry policy */
    __le64 bg_size_blocks;        /* default/target BG span in blocks (mkfs‑set) */

    /* Cluster */
    __le32 cluster_id;            /* arbitrary cluster identifier */
    __le32 pad_cluster;           /* alignment */

    /* Node Registry (global table; see cetrafs_node_entry_t below). No
     * backward compatibility is maintained for this format (pre-1.0,
     * mkfs/fsck/kmod are always rebuilt together) -- CETRAFS_VERSION was
     * bumped when this was added instead of trying to make it optional. */
    __le64 node_table_start;      /* LBA */
    __le64 node_table_blocks;     /* block count */
    __le32 node_table_count;      /* capacity (max registered nodes) */
    __le32 node_entry_size;       /* sizeof(cetrafs_node_entry_t) on-disk */

    /* Per-ZG pending-free queues (version 0x0006): a node
     * freeing a data block that lives in a Block Group whose owning ZG
     * belongs to a DIFFERENT node must never touch that BG's bitmap or
     * counters itself (an unsynchronized cross-node read-modify-write of
     * those blocks is exactly how blocks get double-allocated) -- it
     * appends a cetrafs_pending_free_t entry to the owning ZG's queue
     * here instead, under the cluster mutex, and the ZG's owner applies
     * it to its own bitmaps on its next heartbeat tick / at claim time.
     * Region: zone_group_count contiguous slices of
     * pending_free_blocks_per_zg blocks each, zero-filled by mkfs. */
    __le64 pending_free_start;        /* LBA */
    __le32 pending_free_blocks_per_zg;
    __le32 pad1;

    /* Per-NODE journals (version 0x0006): replaces the
     * removed per-ZG journals, whose one journal area was shared by
     * every node that mutated metadata in that ZG's data region --
     * multiple writers with independent in-memory slot/txn counters,
     * which collide. Each Node Registry row index gets its own private
     * slice here: 1 flag block (cetrafs_node_journal_hdr_t) followed by
     * slots of CETRAFS_JOURNAL_SLOT_BLOCKS blocks each. Region:
     * node_table_count contiguous slices of node_journal_blocks blocks
     * each. node_journal_blocks == 0 disables journaling volume-wide
     * (mkfs -J 0). */
    __le64 node_journal_start;        /* LBA */
    __le32 node_journal_blocks;       /* blocks per node, incl. the flag block */
    __le32 pad2;

    /* Features & checksum */
    __le64 features_compat;
    __le64 features_incompat;
    __le64 features_ro_compat;
    __le64 checksum;              /* CRC32C over struct with this field zeroed; low 32 bits used */

    u8  uuid[16];
    u8  reserved[200];
} CETRA_PACKED cetrafs_superblock_t;

/* Pending-free queue entry (see cetrafs_superblock_t.pending_free_start
 * above). Plain-native fields: only the kernel module ever writes these
 * (mkfs just zero-fills the region, and lba == 0 -- the superblock's own
 * LBA, never a freeable data block -- already means "empty slot" with no
 * special-casing). magic guards against a torn/garbage block being
 * mistaken for real entries; an entry is only valid when magic matches
 * AND lba is nonzero. */
#define CETRAFS_PENDING_FREE_MAGIC 0x50454646u /* "PEFF" */

typedef struct {
    __le64 lba;   /* first data block to free; 0 = empty slot */
    __le32 count; /* contiguous blocks (an extent never crosses a BG) */
    __le32 magic; /* CETRAFS_PENDING_FREE_MAGIC */
} CETRA_PACKED cetrafs_pending_free_t;

#define CETRAFS_PENDING_FREE_PER_BLOCK (CETRAFS_BLOCK_SIZE / sizeof(cetrafs_pending_free_t))
/* Per-ZG pending-free queue, in blocks. This is the size mkfs aims
 * for; the real size is sb.pending_free_blocks_per_zg, which mkfs
 * shrinks on a device too small to spare it, and every reader takes it
 * from there.
 *
 * 256 blocks is 65,536 queued runs per ZG. The queue holds one entry
 * per freed EXTENT, and a node deleting a large VM image can produce
 * tens of thousands at once: at the previous 4 blocks (1024 entries) a
 * single 32 GiB image overflowed the queue roughly fiftyfold, and
 * everything past the first 1024 was dropped and leaked until the
 * owner's scrub reclaimed it.
 *
 * The cost is 1 MiB per Zone Group -- 0.01% of a 140 GB LUN, and at
 * worst ~0.2% of the smallest volume mkfs will build, because a ZG
 * needs a Block Group and the smallest BG is 512 MiB. */
#define CETRAFS_PENDING_FREE_BLOCKS_PER_ZG 256

/* Consecutive empty queue blocks that end a drain pass. Appends fill
 * from the front, so empties cluster at the tail; more than one is
 * cheap insurance against a hole left by a lost append race. */
#define CETRAFS_PF_DRAIN_EMPTY_RUN 2

/* Per-node journal flag block -- the first block of each node's journal
 * slice (see cetrafs_superblock_t.node_journal_start above). The single
 * writer is the node itself (or, once that node is STALE, whichever peer
 * replays its journal under the cluster mutex). A fresh zero-filled
 * block (magic == 0) reads as CLEAN -- correct for a fresh mkfs, and
 * safe afterward because the write path durably flips this to DIRTY
 * *before* committing its first journal entry of a session, so entries
 * can never exist under a flag that still reads CLEAN. */
#define CETRAFS_NODE_JOURNAL_MAGIC 0x4e4a524cu /* "NJRL" */
#define CETRAFS_NODE_JOURNAL_CLEAN 0
#define CETRAFS_NODE_JOURNAL_DIRTY 1

typedef struct {
    __le32 magic; /* CETRAFS_NODE_JOURNAL_MAGIC */
    __le32 state; /* CETRAFS_NODE_JOURNAL_CLEAN / _DIRTY */

    /* Which node is replaying this area right now, or
     * CETRAFS_NODE_ID_NONE. Replaying a dead node's journal used to be
     * serialized by the device-wide cluster mutex; this field replaces
     * it with a compare-and-swap claim on this very block, so no mutex
     * is involved at all.
     *
     * Concurrent replay is not in itself harmful -- two nodes copying
     * the same payload over the same target produce the same bytes --
     * but the moment one of them finishes, declares the area CLEAN and
     * lets the dead node's Zone Groups be reclaimed, a second replayer
     * still mid-flight would write a STALE payload over whatever the
     * new owner has since written there. That is what the claim
     * prevents.
     *
     * A replayer that itself dies leaves the claim set, so a waiter
     * that finds the owner stale (node.c) steals it -- same reclaim
     * posture as every other held claim in this format. Only meaningful
     * while state == DIRTY; a zero-filled (never-written) flag block
     * reads as CLEAN, so the 0 there is never mistaken for node 0. */
    __le32 replay_owner;
    u32 pad_a;
    __le64 replay_claimed; /* unix seconds, for forensics */

    u8  pad[CETRAFS_BLOCK_SIZE - 24];
} CETRA_PACKED cetrafs_node_journal_hdr_t;

/* Cross-node mutual exclusion is atomic COMPARE AND WRITE, full stop
 * (kmod/caw.c). There is no backend choice and no on-disk field selecting
 * one: a device either reports a usable atomic CAW length or it does not,
 * and one that does not can only ever be mounted by a single node at a
 * time -- which fs.c's foreign-claim mount gate enforces directly.
 *
 * SCSI Persistent Reservations used to provide a device-wide fallback
 * mutex here, selected per volume. It was removed once every claim path
 * moved to CAS: on hardware with CAW it was never used, on hardware
 * without it nothing exercised it, and carrying a second exclusion
 * mechanism meant every change had to be reasoned about twice. */

/* ---- ioctls ----
 *
 * CETRAFS_IOC_DEFRAG relocates the WHOLE file into one physically
 * contiguous run (split into multiple extent entries only where the
 * on-disk extent length field caps out) and frees the old blocks.
 * Requires a write-open fd: the cross-node whole-file exclusive lock
 * that open already claimed is exactly what makes online defrag safe
 * here -- no other NODE can even open the file meanwhile, and local
 * writers serialize on the inode lock held across the move. Explicitly
 * user-triggered (userspace/defrag.cetra), never automatic. */
struct cetrafs_defrag_stats {
    u64 extents_before;
    u64 extents_after;
    u64 blocks_moved;
};

#define CETRAFS_IOC_DEFRAG _IOR('C', 0x01, struct cetrafs_defrag_stats)

/*
 * The userspace-driven whole-file exclusive lock is the standard flock(2)
 * interface (file_operations.flock, kmod/lock.c), not a custom ioctl --
 * flock(LOCK_EX)/flock(LOCK_UN) IS a whole-file advisory exclusive lock
 * with exactly this lock's fd-scoped lifetime. Meaningful only under the
 * `nofilelock` mount; under the default mount the lock is automatic and
 * flock returns -EOPNOTSUPP. See the operations guide at cetrafs.com.
 */

#define CETRAFS_SB_BLOCK_NR        0ULL

/* ---- Zone Group Descriptor (1 block per ZG) ---- */
/*
 * Split into a HOT sector and a COLD remainder as of v0x0009, each with
 * its own checksum (see CETRAFS_HOT_SECTOR above).
 *
 * HOT holds every field a running cluster mutates -- ownership, the
 * free-block aggregate, the heartbeat/lease stamps -- inside the first
 * 512 bytes, so a ZG claim/release/counter-update is one atomic
 * COMPARE AND WRITE of that single sector instead of a PR-mutexed
 * read-modify-write of the whole 4096-byte record. Keeping the hot
 * checksum inside the hot sector is what makes the sector
 * self-validating and therefore CAS-able on its own.
 *
 * COLD holds the mkfs-time geometry (which BGs this ZG owns). Nothing
 * rewrites it after mkfs, so it is never part of a CAS and carries its
 * own separate checksum -- a hot-sector swap must not invalidate it.
 *
 * The deprecated per-ZG journal fields (journal_start/journal_size/
 * journal_clean, dead since the v0x0006 per-node journal redesign) are
 * dropped here rather than carried as permanent always-zero padding --
 * this project keeps no backward compatibility.
 */

typedef struct {
    /* ===== HOT: bytes [0, CETRAFS_HOT_SECTOR) -- the CAS unit ===== */
    __le16 zg_id;                 /* 0..zone_group_count-1 (also validates the sector) */
    __le16 owner_node_id;         /* node currently responsible */
    __le64 free_data_blocks;      /* sum of free blocks across member BGs */
    __le64 hb_seq;                /* heartbeat seq from owner */
    __le64 hot_checksum;          /* CRC32C over [0, CETRAFS_HOT_SECTOR) with this field zeroed */
    u8     hot_pad[CETRAFS_HOT_SECTOR - 28];

    /* ===== COLD: bytes [CETRAFS_HOT_SECTOR, CETRAFS_BLOCK_SIZE) ===== */
    __le32 first_bg_id;           /* first BG id mapped to this ZG */
    __le32 bg_count;              /* number of BGs for this ZG */
    __le64 cold_checksum;         /* CRC32C over the cold region with this field zeroed */
    u8     cold_pad[CETRAFS_BLOCK_SIZE - CETRAFS_HOT_SECTOR - 16];
} CETRA_PACKED cetrafs_zone_group_t;

/* Byte ranges of the two independently-checksummed halves, and each
 * checksum's offset WITHIN its own half -- shared by mkfs/fsck
 * (crc32c_struct) and the kernel so neither can drift. */
#define CETRAFS_ZG_HOT_OFF    0U
#define CETRAFS_ZG_HOT_LEN    CETRAFS_HOT_SECTOR
#define CETRAFS_ZG_COLD_OFF   CETRAFS_HOT_SECTOR
#define CETRAFS_ZG_COLD_LEN   (CETRAFS_BLOCK_SIZE - CETRAFS_HOT_SECTOR)

/* ---- Per-NODE journal record ----
 *
 * Redo logging of BG-data-region metadata: dirent blocks, xattr blocks,
 * external extent leaf/index blocks. The global tables are not journaled
 * -- they change by atomic CAS of the record itself.
 *
 * A slot is two consecutive blocks: this header, then one payload block
 * holding the post-image of target_lba. The payload is written and
 * synced FIRST and the header last, so a valid, correctly checksummed
 * header is itself the commit marker. Redo is a blind copy of the
 * payload onto target_lba: whether or not the real write landed, the
 * result is byte-identical, so there is no undo path.
 *
 * An entry is CONSUMED (header zeroed, synced) by its writer once the
 * target write is synced, so a surviving entry means its writer crashed
 * mid-operation.
 *
 * That alone does NOT make redo safe. The old argument -- the writer
 * still held that operation's lock, so nobody else can have touched the
 * target -- is false under `nofilelock`, where extent leaves have no
 * cross-node lock at all. A dead node's entry replayed over a peer's
 * newer leaf reverts the extent map to something valid and CRC-correct,
 * so fsck sees nothing and only the guest's data is wrong.
 *
 * So replay VERIFIES. prev_checksum records what the target held before
 * the modification: apply when the target still holds that image (the
 * write never landed), skip when it already holds the payload (it did),
 * and refuse when it holds neither -- someone else owns this block now.
 * A target that fails its own tail checksum is TORN rather than
 * rewritten, and is redone: that is the case the journal exists for.
 * F_FRESH marks entries with no prior image because the block was newly
 * allocated; nothing referenced those at crash time, so replay skips
 * them.
 *
 * Plain-native fields (not __le*), like every struct here that only the
 * kernel module writes. mkfs zero-fills the region, so magic == 0 on a
 * fresh filesystem already means "no entry".
 */
typedef struct {
    __le32 magic;                /* CETRAFS_JOURNAL_MAGIC; anything else = no valid entry in this slot */
    __le32 flags;                 /* CETRAFS_JRNL_F_*; 0 from a writer that predates the replay guard */
    __le64 txn_id;                /* monotonic per-node-session sequence; replay applies entries in this order */
    __le64 target_lba;            /* on-disk block this entry's payload (the next block) replaces */
    __le32 payload_checksum;      /* CRC32C of the exact payload block that follows this header */
    __le32 header_checksum;       /* CRC32C over this header with this field zeroed */
    __le32 prev_checksum;         /* CRC32C of target_lba as it read BEFORE the modification --
                                   * replay's proof that nothing else has written the block
                                   * since. Meaningful only with CETRAFS_JRNL_F_GUARDED. */
    u8  pad[CETRAFS_BLOCK_SIZE - 36];
} CETRA_PACKED cetrafs_journal_header_t;

/* Both new fields live in what used to be `reserved32` and the head of
 * `pad`, and header_checksum keeps its offset (28) -- deliberately, so a
 * module that predates them computes a byte-identical header CRC and the
 * two interoperate during a rolling upgrade. No format bump. An old
 * writer's entry reads back as flags == 0, which is exactly "unguarded",
 * and replay falls back to its old unconditional behaviour for it. */
#define CETRAFS_JRNL_F_GUARDED 0x00000001u /* prev_checksum is meaningful */
#define CETRAFS_JRNL_F_FRESH                                                                                           \
    0x00000002u /* target was claimed without reading (a freshly                                                       \
                 * allocated block): it has no prior image, and                                                        \
                 * nothing referenced it at crash time, so there is                                                    \
                 * nothing for replay to repair. */

#define CETRAFS_JOURNAL_MAGIC 0x4C4E524Au /* "JRNL" */

/* One journal slot is a header block followed by the literal post-image
 * of the target block. On-disk geometry, so it lives here rather than in
 * kmod/journal.c -- fsck walks these slots too. */
#define CETRAFS_JOURNAL_SLOT_BLOCKS 2

/* ---- Node Registry (global table; dense packed entries, like the inode
 * table -- NOT one block per entry like the ZG/BG tables, since there are
 * far fewer nodes than BGs and a whole block each would be wasteful) ----
 *
 * A node's only durable identity is its stable machine UUID (uuid.c), which
 * at 128 bits is too wide to stuff into the places that need to reference
 * "which node" cheaply (cetrafs_zone_group_t.owner_node_id is 16 bits,
 * sized for exactly this). This table maps a UUID to a small integer node
 * id -- the row index -- which is what those other fields actually store.
 * A node finds its own row (or claims a free one) by UUID at registration
 * time; see the design notes.
 */
#define CETRAFS_NODE_UUID_LEN   16
#define CETRAFS_NODE_LABEL_LEN  32

#define CETRAFS_NODE_STATE_FREE       0 /* slot never used, or released */
#define CETRAFS_NODE_STATE_REGISTERED 1 /* claimed by the node in node_uuid */

/* Sentinel "no node" / "unassigned" -- matches the width of
 * cetrafs_zone_group_t.owner_node_id (__le16), the narrowest field that
 * stores a node id; caps real registrations at 0xFFFE rows, far beyond any
 * plausible cluster size. */
/*
 * The same 8-byte tail, for the other two whole-block structures a
 * LOCK-FREE reader can catch mid-write (format v0x000F).
 *
 * g7 gave dirent blocks a tail because a peer walking a directory takes
 * no lock and so can observe a 4 KiB write torn -- which was a silent
 * mis-parse, and was seen in the field. Extent-leaf and xattr blocks
 * have exactly the same exposure and had no detection at all:
 *
 *   - An external extent LEAF is read through cetrafs_read_leaf_bh(),
 *     which reads FRESH whenever this node does not hold the file's
 *     exclusive lock -- and a DIRECTORY never holds one, so every peer
 *     walking a spilled directory reads its leaf unsynchronised while
 *     another node may be appending to it. A torn leaf is a garbage
 *     extent array: blocks belonging to some other file, served as this
 *     one's.
 *   - An XATTR block is written under the namespace mutex but read
 *     without it, so a peer's getxattr/listxattr can catch a setxattr
 *     mid-write.
 *
 * Unlike a record (which lives wholly inside one 512-byte logical
 * sector and therefore cannot tear), these span all 8
 * sectors of their block, so the tear is real and the tail is the only
 * thing that can tell a reader to re-read.
 *
 * Same shape and offset as cetrafs_dirent_tail_t, with its own magic so
 * a block of the wrong KIND is caught rather than mis-parsed.
 */
typedef struct {
    __le32 magic;
    __le32 crc; /* CRC32C of the block's first CETRAFS_BLK_TAIL_OFF bytes */
} CETRA_PACKED cetrafs_blk_tail_t;

#define CETRAFS_BLK_TAIL_OFF    (CETRAFS_BLOCK_SIZE - sizeof(cetrafs_blk_tail_t))
#define CETRAFS_LEAF_TAIL_MAGIC 0x4c424c4bu /* "LBLK" */
#define CETRAFS_XATTR_TAIL_MAGIC 0x58424c4bu /* "XBLK" */
#define CETRAFS_INDEX_TAIL_MAGIC 0x49424c4bu /* "IBLK" -- v2 interior extent-index block */

/* An external extent leaf block (used once a file's 4 inline slots are
 * full) is a cetrafs_extent_hdr_t followed by as many cetrafs_extent_t
 * as fit in the rest of the block. Part of the on-disk format, so the
 * kernel and fsck must agree on it exactly. */
/* One fewer than it used to hold (340 -> 339): the last 8 bytes are now
 * the tail checksum. An xattr block loses nothing -- 12 entries of 322
 * bytes leave 232 bytes of slack, and the tail fits inside it. */
#define CETRAFS_EXT_BLOCK_MAX_LEAVES \
    ((CETRAFS_BLK_TAIL_OFF - sizeof(cetrafs_extent_hdr_t)) / sizeof(cetrafs_extent_t))

/* v2: an INTERIOR index block -- same shape as a leaf (header, dense
 * array, tail checksum) but holding cetrafs_extent_idx_t entries that
 * each point at one leaf block. The tree is at most depth 2: the
 * inode's 4 root slots -> up to 4 interior blocks -> leaves. Capacity
 * 4 * ~254 * ~254 extents (~258k, down from ~344k since the index
 * entry grew a range bound), so extent-count exhaustion stops
 * being reachable: a dense 16 TiB file (the ee_block u32 ceiling)
 * survives down to an average extent of ~48 KiB. Arrays stay
 * APPEND-ONLY and unordered, exactly like depth 1: appends only ever
 * touch the LAST leaf, a full leaf appends an idx to the last interior,
 * a full interior moves to the next root slot. */
#define CETRAFS_EXT_BLOCK_MAX_IDX \
    ((CETRAFS_BLK_TAIL_OFF - sizeof(cetrafs_extent_hdr_t)) / sizeof(cetrafs_extent_idx_t))
#define CETRAFS_EXT_MAX_DEPTH 2

#define CETRAFS_NODE_ID_NONE 0xFFFFu

/* Node liveness timing. Shared rather than kernel-private because the
 * userspace tools need the same answer the kernel would give: mkfs and
 * fsck decide whether a registry row belongs to a node that is still
 * mounted RIGHT NOW, on some other machine, and "still mounted" has to
 * mean exactly what cetrafs_node_is_stale() means. */
#define CETRAFS_HEARTBEAT_INTERVAL_SECS 15
/*
 * 8 beats = 120 s. It was 4 beats (60 s), which is wrong against real
 * multipath storage, and the reason is worth keeping here because it is
 * not a filesystem-internal argument at all.
 *
 * When every path to a node fails, dm-multipath QUEUES the I/O rather
 * than failing it, and keeps queueing for no_path_retry x
 * polling_interval seconds before it gives up and returns -EIO. The
 * stock multipath-tools entry for an HPE 3PAR, as one concrete
 * example, is no_path_retry 18 at a 5 s poll -- 90 s. A node in
 * that state cannot heartbeat either, because its heartbeat write is
 * queued behind the same dead paths.
 *
 * So with a 60 s window the ordering was inverted: peers declared the
 * node dead and reclaimed its Zone Groups and locks at 60 s, a full
 * 30 s BEFORE its own I/O had even failed. Whatever was queued then
 * flushed into regions another node already owned.
 *
 * The invariant is therefore: a node must give up on failed I/O before
 * its peers give up on it -- path-failure timeout < stale window. 120 s
 * clears a stock 90 s path retry with 30 s to spare. An operator whose
 * multipath is tuned differently must re-check that inequality rather
 * than assume this number fits; see the operations guide at cetrafs.com.
 */
#define CETRAFS_NODE_STALE_SECS         (8 * CETRAFS_HEARTBEAT_INTERVAL_SECS)

/* Bounds the OPERATOR may set the per-mount cluster timing to, via the
 * procfs 'controls' file. Both sides matter: too low declares a node
 * that merely paused (GC, an I/O stall, scheduling jitter) dead and lets
 * a peer reclaim its claims while it is still alive; too high leaves a
 * genuinely crashed node's claims locked up for far longer than a VM
 * datastore can tolerate. The window must also be at least a few beats,
 * or one missed tick is fatal -- hence the ratio.
 *
 * These bound only the operator controls file, NOT the hb_interval_secs/
 * stale_secs MODULE PARAMS, which are unbounded test knobs (the loop
 * suites compress timing through them). Higher-level fencing -- deciding
 * a slow-but-alive node must be forcibly stopped -- is the cluster
 * manager's job, not the filesystem's; see docs/LOCKING.md. */
#define CETRAFS_HB_INTERVAL_MIN_SECS 5
#define CETRAFS_HB_INTERVAL_MAX_SECS 30
#define CETRAFS_STALE_MIN_SECS       15
/* 240, not 120: the DEFAULT is 120 (8 beats), and a default sitting
 * exactly on the ceiling leaves an operator able to lower the window but
 * never raise it -- which is the wrong direction, since the reason to
 * change it is a fabric whose path-retry timeout is LONGER than ours.
 * Two beats of headroom above the default. */
#define CETRAFS_STALE_MAX_SECS       240
#define CETRAFS_STALE_MIN_BEATS      3 /* stale_secs >= this * hb_interval_secs */

/* How long a userspace tool (mkfs/fsck) watches a Node Registry row
 * before concluding nobody is heartbeating on it. Must exceed one full
 * heartbeat interval so a live node is guaranteed at least one bump,
 * with margin for a node whose tick is running late under load. The
 * kernel does not use this: a mounted node watches its peers
 * continuously and has no reason to block. */
#define CETRAFS_PEER_PROBE_SECS (CETRAFS_HEARTBEAT_INTERVAL_SECS + 5)

/* Hard cap on registry rows, set by cetrafs_inode_t.read_open_nodes being
 * a 64-bit presence mask. Enforced by mkfs on -M, so the mask can never
 * silently fail to represent a reader. Far beyond the handful of hosts
 * this filesystem targets. */
#define CETRAFS_MAX_READER_NODES 64u

typedef struct {
    u8   node_uuid[CETRAFS_NODE_UUID_LEN]; /* raw stable machine UUID */
    __le32  state;                           /* CETRAFS_NODE_STATE_* */
    __le64  hb_seq;                          /* heartbeat seq, bumped while mounted */
    __le64  last_seen;                       /* unix seconds of the last heartbeat write */
    char label[CETRAFS_NODE_LABEL_LEN];   /* informational hostname; NUL-terminated */
    __le64  checksum;                        /* CRC32C, plain-native like BG/inode checksums */

    /* Bumped by any node that reclaims something from THIS node after
     * deciding it is stale -- its Zone Groups, a file lock, a namespace
     * lock, its journal area. This is the lease that replaces SCSI PR
     * registration.
     *
     * A node caches this value when it registers and re-reads its own
     * row every heartbeat tick: if the epoch has moved, somebody has
     * already declared it dead and taken its state, so it must fence
     * itself rather than carry on writing. A merely-slow
     * node waking from a long pause is indistinguishable from a dead
     * one to its peers, and this is how it finds out.
     *
     * Taken from the zero-filled reserved area, so 0 is the natural
     * starting value and no format bump is needed: a freshly registered
     * node caches 0 and fences the first time it differs.
     *
     * Advisory, not target-enforced: unlike a PR preempt, the victim
     * only notices at its next check, so writes already in flight still
     * land. That window exists with PR too -- this filesystem's PR is a
     * brief mutex, never a held reservation, so it never fenced in-
     * flight writes either. Closing it to zero needs hardware fencing. */
    __le64  fence_epoch;

    /* This node's own heartbeat period, in seconds, as it is actually
     * running right now.
     *
     * Liveness is decided by watching a peer's hb_seq stop advancing for
     * some window -- and that window has to be longer than the peer's
     * tick, or a perfectly healthy node looks dead between beats. The
     * observer used to use ITS OWN configured window against a peer
     * whose rate it had no way to know: two nodes built or tuned
     * differently (and the test suite compresses both parameters on the
     * node under test) and one would start declaring the other dead,
     * breaking its locks and fencing it. A liveness protocol must not
     * depend on a number only the other side can see.
     *
     * Published here so an observer can floor its window at several of
     * the PEER's own beats. Taken from the zero-filled reserved area
     * like fence_epoch above, so 0 means "not advertised" (a row written
     * before this existed) and the observer falls back to its own
     * configured window. */
    __le32  hb_interval_secs;

    /* The cluster-wide file-lock mode this node is running, as established
     * by whichever node mounted FIRST (the "lead"). A node joining a
     * cluster with a live peer ADOPTS that peer's mode rather than its own
     * mount option, so a mixed on/off cluster -- which has no coherent
     * cross-node mutual exclusion and silently corrupts -- cannot form (a
     * node that explicitly asked for the opposite is refused at mount
     * instead). One of CETRAFS_FLOCK_MODE_*. Taken from the zero-filled
     * reserved area like fence_epoch/hb_interval_secs above, so 0
     * (CETRAFS_FLOCK_MODE_UNSET) is a row that predates this or has no
     * opinion, and a peer reading it skips it. */
    __le32  file_lock_mode;

    u8   reserved[36];
} CETRA_PACKED cetrafs_node_entry_t; /* 128 bytes */

/* cetrafs_node_entry_t.file_lock_mode values. */
#define CETRAFS_FLOCK_MODE_UNSET 0 /* no opinion (old/FREE row) -- ignore */
#define CETRAFS_FLOCK_MODE_ON    1 /* automatic whole-file lock (default mount) */
#define CETRAFS_FLOCK_MODE_OFF   2 /* nofilelock */

/* Table ranges (derived helpers) */
#define CETRAFS_ZG_TABLE_START(sb)      ((sb)->zg_table_start)
#define CETRAFS_BG_TABLE_START(sb)      ((sb)->bg_table_start)
#define CETRAFS_BG_REGIONS_START(sb)    ((sb)->bg_regions_start)

/* ---- Block Group Descriptor (global table; 1 block per BG) ---- */
/*  Describes a contiguous DATA region owned by a ZG. No journals here. */

typedef struct {
    __le32 bg_id;                 /* global BG id */
    __le16 owner_zg;              /* ZG that owns this BG */
    __le16 flags;                 /* future use */

    __le64 start_block;           /* absolute LBA of the BG region start */
    __le64 length_blocks;         /* span size in blocks */

    /* Intra‑BG offsets (relative to start_block) */
    __le32 off_bg_header;         /* usually 0 */
    __le32 off_data_bmap;         /* data bitmap blocks start */
    __le32 off_data_region;       /* first data block usable */

    /* Counts (cached) */
    __le64 data_block_count;      /* usable data blocks in this BG */
    __le64 free_data_blocks;      /* cached free blocks */

    __le64 checksum;

    /* The count's OWNERSHIP EPOCH (v0x0004). Bumped by every reconcile --
     * the moment a Zone Group ownership transfer rewrites this
     * descriptor's count from the bitmap truth. A free-count delta is
     * only meaningful within the epoch it was accrued under (the new
     * owner's recount already includes the durable effects the delta
     * describes), so the delta-apply CAS refuses when the image's epoch
     * is not the one the delta was born in -- which is what makes a
     * stale previous owner's late flush DETECTABLE even when the
     * recomputed count happens to be byte-identical to what it expects.
     * See alloc.c's cetrafs_bg_count_mutate(). */
    __le64 reconcile_seq;
    /* pad sized against the *real* preceding field total (60 bytes).
     * Found: this was previously "- 64", as if 64 bytes of
     * real fields preceded it, making sizeof(cetrafs_block_group_t)
     * 4092, not CETRAFS_BLOCK_SIZE (4096) as every comment/caller assumes
     * -- harmless everywhere mkfs.c/fsck.c's own sizeof()-based
     * crc32c_struct() calls were the only readers (self-consistent, just
     * 4 bytes short of a real block), but kmod/alloc.c's
     * cetrafs_bg_adjust_free_blocks() hashes the literal CETRAFS_BLOCK_
     * SIZE (4096) on every data-block alloc/free -- a 4-byte length
     * mismatch against fsck's check that produced a genuine, 100%-
     * reproducible checksum mismatch the first time anything exercised
     * enough kernel-side frees (fallocate's punch-hole) ahead of an
     * fsck run. Fixing the pad to match reality makes both sides hash
     * the same CETRAFS_BLOCK_SIZE bytes without touching either call
     * site. (68 as of v0x0004: reconcile_seq above.) */
    u8  pad[CETRAFS_BLOCK_SIZE - 68];
} CETRA_PACKED cetrafs_block_group_t;

/* ---- Intra‑BG Header (first block of region) ---- */

typedef struct {
    __le32 bg_id;
    __le16 owner_zg;
    __le16 flags;

    __le64 length_blocks;         /* includes header + bitmap + data */

    __le32 off_data_bmap;         /* bitmap start (rel to BG.start) */
    __le32 off_data_region;       /* data region start (rel to BG.start) */

    __le64 data_block_count;

    __le64 gen;                   /* increments on resize/repair */
    __le64 checksum;

    /* pad sized against the *real* preceding field total (48 bytes), not
     * the "-64" guess this had previously -- same bug as
     * cetrafs_block_group_t above, 16 bytes off here. Not currently a
     * live checksum mismatch (only mkfs.c/fsck.c ever touch this
     * struct's checksum, both via sizeof(), so they were at least
     * self-consistent) but it meant sizeof(cetrafs_bg_header_t) was
     * 4080, not CETRAFS_BLOCK_SIZE as every comment claims -- fixed for
     * the same reason, before anything else starts trusting that. */
    u8  pad[CETRAFS_BLOCK_SIZE - 48];
} CETRA_PACKED cetrafs_bg_header_t;

/* ---- Extents: ext4‑style tree ---- */
/*  Header is followed by either leaves (cetrafs_extent) when eh_depth == 0,
 *  or index entries (cetrafs_extent_idx) when eh_depth > 0. On‑disk extent
 *  blocks start with the same header.
 */

#define CETRAFS_EXT_MAGIC          0xC3E7

typedef struct {
    __le16 eh_magic;           /* CETRAFS_EXT_MAGIC */
    __le16 eh_entries;         /* number of valid entries after header */
    __le16 eh_max;             /* max entries that fit after header */
    __le16 eh_depth;           /* 0 = leaf, >0 = index */
    __le32 eh_generation;      /* for tree split/merge */
} CETRA_PACKED cetrafs_extent_hdr_t;

typedef struct {
    __le32 ee_block;           /* first logical block covered */
    __le32 ee_len;             /* number of blocks (high bit for uninit opt).
                                * v2 widened this from u16: at 15 length bits
                                * one extent capped at 128 MiB, so one leaf
                                * block's 339 entries capped a DENSE file at
                                * ~42 GiB however much the volume held. 31
                                * bits = up to 8 TiB per extent. */
    __le32 ee_start_lo;        /* low 32 bits of physical start */
    __le16 ee_start_hi;        /* high 16 bits of physical start */
    __le16 ee_pad;             /* reserved, keep 0 */
} CETRA_PACKED cetrafs_extent_t; /* 16 bytes */

typedef struct {
    /*
     * The logical range this entry's child covers, [ei_block,
     * ei_block_end). A CONSERVATIVE bound: it only ever widens, never
     * shrinks, so a lookup that skips on it can never skip a child that
     * holds the block -- at worst it reads one it did not need to.
     *
     * ei_block alone used to be "covers blocks >= ei_block" and nothing
     * bounded the top, so a depth-2 lookup had to read EVERY leaf until
     * it hit. The arrays are append-only and unordered, so there was no
     * other way. On a 32 GiB VM image that had fragmented to 28,659
     * extents -- about 113 leaves -- an average lookup read ~56 of them,
     * and it paid that on every single mapped block. Measured against
     * the same file early in its life (443 extents): 480 MB/s then,
     * 90 MB/s at 28k.
     *
     * Nor was ei_block a true minimum: writes into a sparse file land
     * at an arbitrary logical offset and are appended to the LAST leaf,
     * so a leaf can acquire a block below the one it was created with.
     * Both ends are maintained now.
     */
    __le32 ei_block;           /* lowest logical block in the child (inclusive) */
    __le32 ei_block_end;       /* highest + 1 (exclusive); 0 means "unknown, must read" */
    __le32 ei_leaf_lo;         /* low 32 bits of leaf physical block */
    __le16 ei_leaf_hi;         /* high 16 bits of leaf physical block */
    __le16 ei_pad;             /* reserved, keep 0 */
} CETRA_PACKED cetrafs_extent_idx_t; /* 16 bytes */

/* ---- Inode (GLOBAL) ---- */

/*
 * The record is split into TWO 512-byte sectors by WRITE OWNERSHIP
 * (v0x0005), because its two writer families cannot otherwise avoid
 * reverting each other's fields:
 *
 *  - SECTOR 0, the NAMESPACE DOMAIN: everything the namespace/lock
 *    machinery owns -- identity, stat-identity (mode/uid/gid), the nlink
 *    accumulator, ctime, the xattr pointer, both cross-node locks, read
 *    presence, dirent_seq, generation. After mkfs/create (which write
 *    the whole free record) this sector changes ONLY BY COMPARE-AND-SWAP:
 *    every live mutation -- ns-lock acquire/release with its piggybacked
 *    updates, file-lock claim/release, presence bits, link/unlink's
 *    nlink, setattr's mode -- is a CAW of this one sector, so concurrent
 *    mutations compose instead of clobbering (a blind rewrite here once
 *    reverted peers' presence bits and nlink deltas -- the *    ns-fuzz corruption family).
 *
 *  - SECTOR 1, the FILE DOMAIN: what the file DATA path owns -- size,
 *    blocks, atime/mtime, flags, and the extent-tree root. The per-block
 *    hot path (cetrafs_get_block()) accumulates its updates in core and
 *    publishes them at durability boundaries as writes of THIS sector
 *    only, so however stale the image it eventually flushes is, it
 *    physically cannot take a peer's sector-0 state backwards. Identity
 *    (ino, generation) is echoed here so each sector validates alone and
 *    a reader can detect a half-landed whole-record write (echo mismatch
 *    == transient, retried like a torn read).
 *
 * Each sector carries its own CRC32C. Directories are ns-owned end to
 * end (their "file data" is dirents, mutated only under the namespace
 *_lock), so directory code may write both sectors under that lock; the
 * sector-1-then-sector-0 publish order makes dirent_seq (sector 0) the
 * barrier a peer's freshness gate observes.
 */
#define CETRAFS_INODE_NS_BYTES 512U
#define CETRAFS_INODE_FD_OFF   512U
#define CETRAFS_INODE_FD_BYTES 512U

/* The record's size ON DISK: two sectors, always, whatever the in-core
 * struct happens to measure (see the trailing-pad note on the struct).
 * This is the format constant -- the superblock's inode_size field and
 * every layout calculation use it, never sizeof(). */
#define CETRAFS_INODE_ONDISK_SIZE (CETRAFS_INODE_NS_BYTES + CETRAFS_INODE_FD_BYTES)

typedef struct {
    /* ===== SECTOR 0: the NAMESPACE DOMAIN (CAS unit) ===== */
    __le64 ino;                   /* global inode number */

    __le32 mode;                  /* S_IF* | perms (setattr holds the ns lock) */
    __le32 uid;
    __le32 gid;

    /* nlink is a cross-node ACCUMULATOR: mutated only under the
     * namespace lock, published as a CAS so concurrent deltas compose.
     * Nothing outside the namespace machinery may write it. */
    __le32 nlink;

    /* ctime is namespace-owned (link/unlink/rename/chmod stamp it).
     * A write(2)'s ctime bump lives in-core on the writing node and
     * reaches the record at that node's next namespace-side update;
     * mtime (sector 1) is the cross-node-fresh "data changed" signal. */
    __le64 ctime;

    /* External xattr block (0 if none); setxattr holds the ns lock. */
    __le64 xattr_block;

    /* CETRAFS_INODE_*: written at create and by setxattr (XATTR bit),
     * both namespace-side; the file path only reads it. */
    __le32 flags;
    u32 flags_reserved; /* keep 0 */

    /* Cluster-wide exclusive open lock: whole-file, VMFS-style --
     * lock_owner_node is a Node Registry row (CETRAFS_NODE_ID_NONE when
     * unlocked); a crashed holder is reclaimed by its row going stale,
     * never by a per-lock timer. */
    __le32 lock_owner_node;
    __le32 lock_mode;             /* CETRAFS_LOCK_* */

    /* Namespace lock (v0x000A): a HELD cross-node mutex scoping
     * namespace mutation to the object actually mutated. Acquired and
     * released by CAS of this sector; a dead holder's lock is broken by
     * a waiter that finds its registry row stale (journal replayed
     * first). CETRAFS_NODE_ID_NONE (0xFFFF, NOT 0) means unlocked. */
    __le32 ns_lock_owner;
    u32 ns_lock_reserved;         /* alignment, keep 0 */

    /* Which nodes hold this file open FOR READ (bit N = registry row N).
     * One CAW on a node's first read-open / last read-close; what stops
     * a peer destroying a file another node is reading. */
    __le64 read_open_nodes;

    /* Bumped by every mutation of this directory's dirent blocks --
     * the freshness gate that lets a reader trust its cached dirent
     * blocks (one fresh record read instead of one per block).
     * Directories only. */
    __le64 dirent_seq;

    /* Generation (v0x0008): stamped once at allocation, preserved by
     * every later update; how a reused inode NUMBER is told apart from
     * the same file updated. 0 is reserved as invalid. */
    __le64 generation;

    __le64 ns_checksum;           /* CRC32C over [0, 512) with this field zeroed */
    u8 ns_pad[CETRAFS_INODE_NS_BYTES - 96];

    /* ===== SECTOR 1: the FILE DOMAIN ===== */
    __le64 fd_ino;                /* identity echo of .ino */
    __le64 fd_generation;         /* identity echo of .generation */

    __le64 size;                  /* bytes */
    __le64 blocks;                /* 512B sectors for stat(2) */

    __le64 atime;
    __le64 mtime;

    /* Extent tree embedded root (ext4-style): up to 4 extents (depth 0)
     * or 4 index entries (depth 1/2) inline; past that it spills into
     * external leaf/interior blocks referenced by et.idx[]. */
    cetrafs_extent_hdr_t eh;
    union {
        cetrafs_extent_t    leaf[4]; /* depth==0: up to 4 inline extents */
        cetrafs_extent_idx_t idx[4]; /* depth>0: up to 4 inline indexes */
    } CETRA_PACKED et;

    /* The FILE-domain analogue of dirent_seq: a unique stamp written by
     * every publish of this sector, so a peer can tell "this file's
     * size/extent tree changed since I cached it" from one record read
     * instead of re-reading the tree per block.
     *
     * Needed because the predicate that used to gate that cache --
     * "no peer has this file OPEN right now" -- answers a different
     * question than the one asked of it. A peer that WROTE the file and
     * CLOSED it is not open, so the predicate says "trust your cache"
     * about a cache filled before those writes. A survivor then maps a
     * VM image through an extent tree frozen at whenever it last looked,
     * and qemu cannot open the disk, while a freshly-mounted node reads
     * it perfectly. Exactly the bug dirent_seq was added
     * for; regular files were left on the old predicate.
     *
     * Like dirent_seq this is a STAMP, not a counter: only equality is
     * ever asked, so it needs to be unique per write rather than
     * ordered -- two nodes incrementing from the same base would both
     * write the same value for different content. Same generator.
     */
    __le64 file_seq;
/* file_seq layout: the publishing node's registry row in the top 16
 * bits, a nanosecond clock in the low 48.
 *
 * SELF-IDENTIFYING ON PURPOSE. The reader has to tell its OWN publish
 * from a peer's, and it cannot do that by bookkeeping: every path that
 * writes the file sector stamps, and one that forgot to record what it
 * stamped would make the node treat its own writeback as a peer's
 * change -- dropping that file's extent tree AND its whole page cache,
 * once a second, forever. That is exactly what shipped: a running VM's
 * I/O fell to re-reading the LUN continuously, with nothing in dmesg
 * because nothing was failing (found in testing).
 *
 * Decodability is what makes the property structural instead of a rule
 * every future writer has to remember.
 *
 * Still unique per write, which is the requirement dirent_seq's comment
 * explains: two nodes can never collide (different high bits), and one
 * node's clock does not repeat. Only equality is ever asked of it. */
#define CETRAFS_FILE_SEQ_NODE_SHIFT 48
#define CETRAFS_FILE_SEQ_VAL_MASK   ((1ULL << CETRAFS_FILE_SEQ_NODE_SHIFT) - 1)
#define CETRAFS_FILE_SEQ_NODE(seq)  ((u32) ((seq) >> CETRAFS_FILE_SEQ_NODE_SHIFT))

    __le64 fd_checksum;           /* CRC32C over [512, 1024) with this field zeroed */

    /*
     * NO TRAILING PAD -- deliberately. The FILE sector's on-disk tail
     * (everything past fd_checksum, out to 1024) is dead space that is
     * always written as ZERO, so carrying it in the struct bought
     * nothing and cost 380 bytes on every stack frame holding a record.
     *
     * That was not cosmetic: v0x0005 grew this struct from 204 to 1024
     * bytes, which put 49 functions over the kernel's 1 KiB
     * -Wframe-larger-than limit. Measured with the stack tracer on a
     * plain create(2): cetrafs_create_locked (1128) ->
     * cetrafs_dir_add_entry (1216) -> cetrafs_inode_stage_record
     * (1080) = 3.4 KiB of a 7.1 KiB peak, on a 16 KiB stack that still
     * has dm-multipath, SCSI and the IOMMU to go underneath it.
     *
     * The SECTOR 0 pad above stays: it is structural, pinning fd_ino to
     * offset 512 so a record still overlays the on-disk image directly.
     * The file sector's live bytes are CETRAFS_INODE_FD_LIVE; the tail
     * is reconstructed as zeros when an image is built or checksummed
     * (cetrafs_inode_fd_to_image(), cetrafs_sector_crc()).
     */
} CETRA_PACKED cetrafs_inode_t;

/* Live (in-core) bytes of the FILE sector -- what a record actually
 * carries, as opposed to the CETRAFS_INODE_FD_BYTES it occupies on
 * disk. Everything in between is the zero tail described above. */
#define CETRAFS_INODE_FD_LIVE ((unsigned int) (sizeof(cetrafs_inode_t) - CETRAFS_INODE_FD_OFF))

/* The two-sector contract is load-bearing: sector-granular CAS and the
 * sector-only write primitives depend on these exact offsets. The
 * record still overlays sector 0 and the head of sector 1 byte for
 * byte; only the file sector's zero tail is absent. */
typedef char cetrafs_inode_fd_domain_starts_at_512[(offsetof(cetrafs_inode_t, fd_ino) == 512) ? 1 : -1];
typedef char cetrafs_inode_ns_sector_is_whole[(offsetof(cetrafs_inode_t, fd_ino) == CETRAFS_INODE_NS_BYTES) ? 1 : -1];
typedef char cetrafs_inode_fd_live_fits_its_sector[(sizeof(cetrafs_inode_t) <= CETRAFS_INODE_ONDISK_SIZE) ? 1 : -1];
/* fd_checksum is the last live field: the tail starts right after it. */
typedef char cetrafs_inode_fd_checksum_is_last[(offsetof(cetrafs_inode_t, fd_checksum) + 8 == sizeof(cetrafs_inode_t))
                                                   ? 1
                                                   : -1];

/*
 * The FILE sector, record <-> on-disk image. The image is always a full
 * CETRAFS_INODE_FD_BYTES; the record holds only the live head, so the
 * tail is zero-filled on the way out and ignored on the way in. Every
 * sector-granular writer goes through these rather than hand-rolling
 * the geometry (which is how the pad came to be load-bearing at all).
 */
static inline void cetrafs_inode_fd_to_image(void *image, const cetrafs_inode_t *rec)
{
    memcpy(image, (const u8 *) rec + CETRAFS_INODE_FD_OFF, CETRAFS_INODE_FD_LIVE);
    memset((u8 *) image + CETRAFS_INODE_FD_LIVE, 0, CETRAFS_INODE_FD_BYTES - CETRAFS_INODE_FD_LIVE);
}

static inline void cetrafs_inode_fd_from_image(cetrafs_inode_t *rec, const void *image)
{
    memcpy((u8 *) rec + CETRAFS_INODE_FD_OFF, image, CETRAFS_INODE_FD_LIVE);
}

/* Record-to-record copy of the file domain (the in-core shadow). */
static inline void cetrafs_inode_fd_copy(cetrafs_inode_t *dst, const cetrafs_inode_t *src)
{
    memcpy((u8 *) dst + CETRAFS_INODE_FD_OFF, (const u8 *) src + CETRAFS_INODE_FD_OFF, CETRAFS_INODE_FD_LIVE);
}

/* Inode flags */
#define CETRAFS_INODE_EXTENTS      0x00000001  /* inode uses extents (always true here) */
#define CETRAFS_INODE_SNAPSHOT     0x00000002
#define CETRAFS_INODE_COMPRESSED   0x00000004
#define CETRAFS_INODE_XATTR        0x00000008

/* Inode open-lock modes (lock_owner_node/lock_mode above) */
#define CETRAFS_LOCK_NONE          0 /* unlocked */
#define CETRAFS_LOCK_EXCLUSIVE     1 /* held by lock_owner_node; blocks opens from any other node */

/* ---- Directory entries (fixed‑size) ---- */

typedef enum {
    CETRAFS_FT_UNKNOWN = 0,
    CETRAFS_FT_REG     = 1,
    CETRAFS_FT_DIR     = 2,
    CETRAFS_FT_LNK     = 3,
    CETRAFS_FT_CHR     = 4,
    CETRAFS_FT_BLK     = 5,
    CETRAFS_FT_FIFO    = 6,
    CETRAFS_FT_SOCK    = 7,
} cetrafs_filetype_t;

typedef struct {
    __le64 inode;              /* target inode */
    __le16 name_len;           /* strlen(name) */
    u8  file_type;             /* cetrafs_filetype_t */
    char name[CETRAFS_FILENAME_MAX];
} CETRA_PACKED cetrafs_dirent_t;

/* Dirent-block tail checksum (v0x0007): lookups/readdir
 * deliberately take no cluster mutex, so a reader can observe a peer's
 * in-flight dirent-block write torn (a 4 KiB write is not atomic against
 * a concurrent read on a real transport). Without a checksum a torn read
 * mis-parses silently; with one, the reader detects it and simply
 * re-reads (the writer syncs under the ns mutex, so a retry converges).
 * The tail lives in the block's natural slack -- 15 dirents * 266 bytes
 * = 3990, leaving 106 bytes free -- so it costs no dirent capacity. crc
 * covers bytes [0, CETRAFS_DIRENT_TAIL_OFF) of the block, same CRC32C
 * convention as everything else; magic distinguishes a stamped block
 * from a legacy/garbage one (reformat-only format change, so in practice
 * every block is stamped -- the magic is a parse guard, not a compat
 * shim). */
#define CETRAFS_DIRENT_TAIL_MAGIC 0x44424c4bu /* "DBLK" */

typedef struct {
    __le32 magic; /* CETRAFS_DIRENT_TAIL_MAGIC */
    __le32 crc;   /* CRC32C of the block's first CETRAFS_DIRENT_TAIL_OFF bytes */
} CETRA_PACKED cetrafs_dirent_tail_t;

#define CETRAFS_DIRENT_TAIL_OFF (CETRAFS_BLOCK_SIZE - sizeof(cetrafs_dirent_tail_t))
/* How many dirents fit before the tail -- (4096-8)/266 = 15, the same 15
 * that fit before the tail existed (the tail lives in what was slack). */
#define CETRAFS_DIRENTS_PER_BLOCK ((CETRAFS_DIRENT_TAIL_OFF) / sizeof(cetrafs_dirent_t))


/* ---- XAttrs (simple fixed array per inode, optional external block later) ---- */

typedef struct {
    char key[CETRAFS_XATTR_KEY_MAX];
    __le16  value_len;
    u8   value[CETRAFS_XATTR_VALUE_MAX];
} CETRA_PACKED cetrafs_xattr_entry_t;

/* ---- Feature bits ---- */
#define CETRAFS_FEAT_COMPAT_NONE       0ULL

#define CETRAFS_FEAT_INCOMPAT_EXTENTS      (1ULL << 0)
#define CETRAFS_FEAT_INCOMPAT_GLOBAL_ITBL  (1ULL << 1) /* single global inode table */
#define CETRAFS_FEAT_INCOMPAT_BIT2_UNUSED  (1ULL << 2) /* was PR_AWARE, removed with SCSI PR */
#define CETRAFS_FEAT_INCOMPAT_NODE_REGISTRY (1ULL << 3) /* node_table_* SB fields are valid */

#define CETRAFS_FEAT_ROCOMPAT_SPARSE       (1ULL << 0)



/* ------------------------------------------ */
/* ---- Layout math helpers (mkfs/mount) ---- */
/* ------------------------------------------ */

/*
 * Global inode structures
 */
static inline u64 cetrafs_calc_inode_bmap_blocks(u64 inodes_count)
{ return CETRAFS_DIV_ROUND_UP(inodes_count, CETRAFS_BITS_PER_BLOCK); }

static inline u64 cetrafs_calc_inode_table_blocks(u64 inodes_count, u32 inode_size)
{
    /* v0x0007: ONE record per block, not densely packed.
     * Packing ~22 inodes (or 32 Node Registry rows) per block made every
     * record write a read-modify-write of a block shared with records
     * OTHER nodes own and update -- two kernels concurrently RMW-ing the
     * same block clobber each other's in-flight updates no matter how
     * fresh their reads are (item f's fix closed the unbounded-staleness
     * case; this closes the concurrency case structurally). Each record
     * still occupies only inode_size/node_entry_size bytes at the start
     * of its block (the rest is dead space); record_size stays what the
     * checksum covers. Costs table space (bounded by the new inode-count
     * default above), buys: no block-mates, so no cross-record clobber
     * is even expressible. */
    (void) inode_size;
    return inodes_count;
}

static inline u64 cetrafs_default_inodes_for_bytes(u64 bytes_total)
{
    /* heuristic for mkfs when user does not specify -N */
    u64 n = bytes_total / CETRAFS_DEFAULT_INODE_RATIO;

    if (n < 1024)
        return 1024; /* minimum floor to keep / and a few files */
    if (n > CETRAFS_DEFAULT_INODES_MAX)
        return CETRAFS_DEFAULT_INODES_MAX;
    return n;
}

/*
 * Block Group (BG) internal layout math
 * Given a BG length in blocks, compute:
 *  - number of data-bitmap blocks (dense)
 *  - offsets for bitmap and data region
 *  - total usable data blocks
 *
 * Derivation: Let L = length_blocks - 1 (exclude header). Each bitmap block
 * maps CETRAFS_BITS_PER_BLOCK data blocks and itself consumes 1 block.
 * Minimal bitmap blocks x is ceil(L / (BITS_PER_BLOCK + 1)).
 */
static inline u64 cetrafs_calc_bg_dbm_blocks(u64 bg_length_blocks)
{
    if (bg_length_blocks <= CETRAFS_BG_HEADER_BLOCKS)
        return 0; /* invalid BG; sanity check elsewhere */
    u64 L = bg_length_blocks - CETRAFS_BG_HEADER_BLOCKS;
    return CETRAFS_DIV_ROUND_UP(L, CETRAFS_BITS_PER_BLOCK + 1ULL);
}

static inline void cetrafs_calc_bg_layout(u64 bg_length_blocks,
                                          u32 *off_data_bmap,
                                          u32 *off_data_region,
                                          u64 *data_block_count)
{
    u64 dbm = cetrafs_calc_bg_dbm_blocks(bg_length_blocks);
    u64 off_bmap = CETRAFS_BG_HEADER_BLOCKS;          /* header at 0 */
    u64 off_data = off_bmap + dbm;
    u64 data_cnt = (bg_length_blocks > off_data) ? (bg_length_blocks - off_data) : 0;

    if (off_data_bmap)   *off_data_bmap   = (u32)off_bmap;
    if (off_data_region) *off_data_region = (u32)off_data;
    if (data_block_count)*data_block_count= data_cnt;
}

/* Convenience: absolute LBA of first BG region */
static inline u64 cetrafs_first_bg_region_lba(const cetrafs_superblock_t *sb)
{ return sb->bg_regions_start; }

static inline u64 cetrafs_bg_region_lba(const cetrafs_block_group_t *bg)
{ return bg->start_block; }

/* ---- Extent helpers (ext4-compatible layout semantics) ---- */
/* A file's logical blocks are addressed by cetrafs_extent_t.ee_block,
 * which is 32 bits wide -- so no file can be longer than 2^32 blocks
 * (16 TiB at 4 KiB), however much capacity the volume has. This is a
 * FORMAT limit, not a policy one: a write past it truncates the logical
 * block number silently and aliases a low offset in the same file.
 * fs.c clamps s_maxbytes by it and file.c refuses past it. */
#define CETRAFS_MAX_FILE_BLOCKS 0x100000000ULL

#define CETRAFS_EXT_LEN_MASK   0x7FFFFFFFu
#define CETRAFS_EXT_UNINIT     0x80000000u

static inline u32 cetrafs_extent_len(__le32 ee_len)
{ return cetrafs_le32(ee_len) & CETRAFS_EXT_LEN_MASK; }

static inline int cetrafs_extent_is_uninit(__le32 ee_len)
{ return (cetrafs_le32(ee_len) & CETRAFS_EXT_UNINIT) != 0; }

static inline __le32 cetrafs_extent_pack_len(u32 len, int uninit)
{
    if (len > CETRAFS_EXT_LEN_MASK) len = CETRAFS_EXT_LEN_MASK;
    return cetrafs_cpu_to_le32(len | (uninit ? CETRAFS_EXT_UNINIT : 0));
}

static inline u64 cetrafs_extent_phys_from_hilo(__le16 hi, __le32 lo)
{ return ((u64) cetrafs_le16(hi) << 32) | (u64) cetrafs_le32(lo); }

static inline void cetrafs_extent_phys_to_hilo(u64 phys, __le16 *hi, __le32 *lo)
{
    if (hi) *hi = cetrafs_cpu_to_le16((u16)(phys >> 32));
    if (lo) *lo = cetrafs_cpu_to_le32((u32)(phys & 0xFFFFFFFFu));
}

/* ---- Invariants & guardrails (non-fatal hints; real checks in _sane() funcs) ---- */
#define CETRAFS_INVAR_BG_OFFSETS_VALID(bg) \
    ((bg).off_bg_header == 0 && \
     (bg).off_data_bmap >= CETRAFS_BG_HEADER_BLOCKS && \
     (bg).off_data_region > (bg).off_data_bmap)

/* ---- Sanity-check helpers (signatures; implement in .c) ---- */
int cetrafs_sb_sane(const cetrafs_superblock_t *sb);
int cetrafs_zg_sane(const cetrafs_zone_group_t *zg);
int cetrafs_bg_sane(const cetrafs_block_group_t *bg);
int cetrafs_inode_sane(const cetrafs_inode_t *in);

#endif /* CETRAFS_LAYOUT_H */
