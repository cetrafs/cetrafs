// SPDX-License-Identifier: GPL-2.0-or-later
// fs.c — CETRAFS mount/umount with full superblock validation
// Tested against Linux 7.1+ headers (fs_context-only mount API)
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/sched/mm.h>
#include <linux/bitmap.h>
#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/version.h>
#include <linux/byteorder/generic.h>
#include <linux/crc32c.h>
#include <linux/delay.h>
#include <linux/dcache.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/fs_context.h>
#include <linux/fs_parser.h>
#include <linux/kernel.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/slab.h>
#include <linux/sort.h>
#include <linux/spinlock.h>
#include <linux/stddef.h>
#include <linux/string.h>
#include <linux/xarray.h>
#include <linux/xattr.h>

#include <linux/overflow.h>
#include "kmod.h" /* on-disk layout; uses __le* when __KERNEL__ is set */

/* Forward decls for exported symbols to silence -Wmissing-prototypes */
int cetrafs_init_fs_context(struct fs_context *fc);
static void cetrafs_sb_resweep_work(struct work_struct *w);
static unsigned int cetrafs_own_claim_resweep_secs;
void cetrafs_kill_sb(struct super_block *sb);
bool cetrafs_free_sb_info(struct super_block *sb);
/* TEST ONLY: sync_fs and unmount sync the device without asking the
 * fence again after their flushes (B-30's control). */
bool cetrafs_sync_regate_off;
cetrafs_test_param(sync_regate_off, cetrafs_sync_regate_off, bool, 0644);
const cetrafs_superblock_t *cetrafs_sb_raw(struct super_block *sb);
int cetrafs_sb_adjust_free_inodes(struct super_block *sb, s64 delta);
int cetrafs_sb_get_free_inodes(struct super_block *sb, u64 *out);
int cetrafs_sb_get_node_id(struct super_block *sb, u32 *out);
int cetrafs_sb_get_node_uuid(struct super_block *sb, u8 out[CETRAFS_NODE_UUID_LEN]);
struct cetrafs_journal *cetrafs_sb_get_journal(struct super_block *sb);
void cetrafs_sb_cache_zg_ownership(struct super_block *sb, u32 zg_id);
bool cetrafs_sb_zg_owned_cached(struct super_block *sb, u32 zg_id);
u32 cetrafs_sb_bg_owner(struct super_block *sb, u32 bg_id);
void cetrafs_sb_set_bg_owner(struct super_block *sb, u32 bg_id, u32 zg_id);
u32 cetrafs_sb_next_owned_bg(struct super_block *sb, u32 from);
struct cetrafs_sb_info;
static bool cetrafs_sb_bg_discard_pending_ignored(struct cetrafs_sb_info *sbi, u32 bg_id);

/* ------ private superblock info kept in s_fs_info ------ */
struct cetrafs_lba_range {
    u64 start, end; /* [start, end) */
};

static int cetrafs_lba_range_cmp(const void *a, const void *b)
{
    const struct cetrafs_lba_range *x = a, *y = b;

    return x->start < y->start ? -1 : x->start > y->start;
}

/* Does [lba, lba+count) touch any of n ranges SORTED by start and not
 * overlapping each other? O(log n). */
static bool cetrafs_lba_ranges_hit(const struct cetrafs_lba_range *r, u32 n, u64 lba, u64 count)
{
    u32 lo = 0, hi = n;

    /* the first range ending past lba */
    while (lo < hi) {
        u32 mid = lo + (hi - lo) / 2;

        if (r[mid].end <= lba)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < n && r[lo].start < lba + count;
}

/*
 * The Block Group layout: everything that describes WHICH Block Groups
 * exist, published as one object so a reader can never see a mix of an
 * old count and a new array, or a new superblock copy and an old
 * address map.
 *
 * Why one object. A live grow (growfs.cetra on a mounted volume, or a
 * peer's grow this node learns about from layout_gen) changes
 * block_group_count, total_blocks, bg_data_end and the table chain
 * together. Readers take none of them under a lock -- the per-block
 * allocation path cannot afford one (PERFORMANCE.md rule 1) -- so the
 * fields must change by REPLACING a pointer, never in place: a loop
 * bounded by the new count indexing an array sized for the old one is
 * an out-of-bounds read, and a validator judging an address against a
 * half-updated end is a wrong verdict.
 *
 * So the superblock copy, the count derived from it, the capacity, the
 * appended table segments and the per-Block-Group state all hang off
 * one cetrafs_bg_layout, published with smp_store_release() and read
 * with smp_load_acquire() (cetrafs_sb_layout()). Every snapshot is
 * self-consistent; a newer one only ever ADDS Block Groups.
 *
 * Superseded layouts are kept on a list until unmount and never freed
 * earlier. Their readers hold no reference and many sleep while they
 * hold the pointer (a loop over block_group_count reading descriptors),
 * so there is no grace period to wait for -- RCU would need them not to
 * sleep, and a reference count would need every one of ~80 callers to
 * pair a get with a put. A layout without its chunks is a few hundred
 * bytes plus one pointer per chunk, and only a grow makes one.
 *
 * The per-Block-Group state lives in fixed-size CHUNKS that are never
 * moved or reallocated: a newer layout points at the same chunks plus
 * new ones. That matters more than the memory. The free-count deltas,
 * the allocation sequence and the dirty bits are updated concurrently
 * and without a lock; copying them into a bigger array would lose every
 * update that landed on the old copy after it was read. A chunk is
 * shared, so there is no copy and no window.
 */
#define CETRAFS_BGC_SHIFT 10
#define CETRAFS_BGC_SIZE (1u << CETRAFS_BGC_SHIFT)
#define CETRAFS_BGC_MASK (CETRAFS_BGC_SIZE - 1)

struct cetrafs_bg_chunk {
    /* Which BGs have a free_data_blocks adjustment sitting dirty-but-
     * not-yet-synced -- see alloc.c's cetrafs_bg_adjust_free_blocks()
     * and cetrafs_flush_dirty_free_counts(). */
    DECLARE_BITMAP(bg_free_dirty, CETRAFS_BGC_SIZE);

    /*
     * Per-Block-Group ownership, the replacement for the Zone Group's
     * contiguous range (docs/internal/BG-OWNERSHIP-DESIGN.md).
     *
     * bg_owner_zg[] is every Block Group's owning Zone Group, read once
     * at mount from the descriptors. owned_bgs is the derived answer to
     * the only question the hot paths ask -- "may this node allocate
     * here?" -- recomputed whenever a Zone Group is claimed or
     * released, which is rare, so the per-block cost is one bit test
     * and no device read.
     *
     * Neither is ever reallocated (see struct cetrafs_bg_chunk), so a
     * lockless reader can never see a freed array.
     */
    u16 bg_owner_zg[CETRAFS_BGC_SIZE];
    DECLARE_BITMAP(owned_bgs, CETRAFS_BGC_SIZE);

    /*
     * Where each Block Group's DESCRIPTOR lives.
     *
     * It used to be bg_table_start + bg_id, full stop. The table is a
     * chain now (cetrafs_bg_segment_t): the first segment is still that
     * contiguous run, and growing appends segments elsewhere rather
     * than moving anything. Resolving an id therefore means knowing
     * which segment holds it.
     *
     * Kept as an array (built at mount, extended by a layout refresh
     * for Block Groups a grow added), because this is read
     * on the per-block allocation path and a walk of the chain there
     * would be a lookup where there used to be an addition
     * (PERFORMANCE.md rule 1). One u64 per Block Group: 512 KiB for a
     * 64 TiB volume, which buys an O(1) answer with no device read.
     */
    u64 bg_desc_lba[CETRAFS_BGC_SIZE];

    /*
     * Each Block Group's DATA region, [bg_data_start, +bg_data_count),
     * read with the descriptor by the mount's walk (and a refresh's, for
     * the groups a grow added) and never changed after. The per-block
     * address check needs it: a group's header and bitmap sit between
     * two data regions, inside the box [bg_regions_start, bg_data_end)
     * the cheap check used to stop at, and an extent aimed at a bitmap
     * turned a file write into "these live blocks are free" (audit
     * 2026-11-14 M-40). Written before the layout that counts the group
     * is published, so a reader bounded by bg_count sees it set.
     */
    u64 bg_data_start[CETRAFS_BGC_SIZE];
    u64 bg_data_count[CETRAFS_BGC_SIZE];

    /*
     * BGs whose DATA BITMAP carries allocation bits this node has not
     * made durable yet.
     *
     * An allocation sets its bit with sync=false (one synchronous
     * bitmap write per block is the per-block cost PERFORMANCE.md
     * forbids), so the bit lives in the buffer cache until writeback.
     * That is fine while the extent referencing the block is equally
     * un-durable -- a crash loses both and the result is consistent.
     *
     * It stops being fine at a DURABILITY BOUNDARY, where the record or
     * extent-leaf IS forced to the device (close stamps the record with
     * a CAS, which goes straight there; fsync syncs it). Then the
     * reference is durable and the allocation is not, and a node that
     * dies afterwards leaves blocks that every other node reads as FREE
     * while an inode still names them -- they get handed out again and
     * two files share them. Reproduced on the cluster by ctest's
     * replay-race in a single round.
     *
     * So the boundary must flush these first. Tracked per BG and
     * cleared on flush, so the cost is one bitmap write per BG actually
     * allocated from since the last boundary -- not one per block.
     *
     * Only ALLOCATIONS are tracked. A lost FREE leaves the bit set,
     * which leaks a block rather than sharing one, and the scrub
     * reclaims it; that direction needs no barrier.
     */
    DECLARE_BITMAP(bmap_alloc_dirty, CETRAFS_BGC_SIZE);

    /* Block Groups the per-tick empty-group release must look at: set
     * whenever one may have BECOME empty -- a credit to its free count,
     * ownership entering this node, an outstanding discard -- and
     * cleared only when a look found it holding data. The release used
     * to walk the whole table once per owned Zone Group per tick and
     * CRC every owned descriptor (audit 2026-11-14 P13; PERFORMANCE.md
     * invariant 5). A missed mark keeps a group, never gives one away. */
    DECLARE_BITMAP(release_check, CETRAFS_BGC_SIZE);

    /* The BG deltas themselves, ACCRUED per BG and applied by one
     * compare-and-swap per dirty BG at the same durability boundaries
     * (v0x0004; bg_free_dirty above is the iteration filter). The BG
     * descriptor used to be read-modify-written in the buffer cache
     * instead -- but a dirty buffer is flushable by ordinary background
     * writeback at ANY moment (self-fencing does not stop it either:
     * writeback bypasses the FS entry points), so a node declared stale
     * could land its stale counts on top of the recount a stealing peer
     * had just derived from the bitmaps, correctly checksummed and
     * undetectable. Same clobber, same cure as zg_free_delta below. */
    atomic64_t bg_free_delta[CETRAFS_BGC_SIZE];

    /*
     * A delta on its way to the descriptor. The flush takes it out of
     * bg_free_delta before its CAS and the cached descriptor carries it
     * only once the CAS is back, so for the length of one device round
     * trip neither held it: a full Block Group read as free as its
     * descriptor last said. The allocator picked it, found its bitmap
     * full and recounted; a flush walking the owned groups kept one step
     * ahead of a 1 TiB fallocate and spent every one of its retries, and
     * it failed ENOSPC with half the volume free (UNMAP benchmark,
     * 2026-11-12).
     *
     * So while a flush is in flight the readers take the count it is
     * writing (bg_flight_free) instead of the descriptor. bg_flight_gen
     * is odd for exactly that span, and a reader that sees it move while
     * it reads the descriptor reads again. bg_flush_busy keeps one
     * flush per Block Group at a time -- a second would start from the
     * descriptor the first has not yet replaced.
     * cetrafs_sb_bg_flight_begin()/_end()/_settle().
     */
    spinlock_t flight_lock;
    u32 bg_flight_gen[CETRAFS_BGC_SIZE];
    s64 bg_flight_free[CETRAFS_BGC_SIZE];
    DECLARE_BITMAP(bg_flush_busy, CETRAFS_BGC_SIZE);

    /*
     * Per-BG count of ALLOCATIONS (never frees). The background scrub's
     * verdict -- "this block is bitmap-set and referenced by nothing" --
     * is gathered by a pass that reads one uncached record per allocated
     * inode and so takes a long time under load, and is acted on later
     * still, block by block. A block that was genuinely free when the
     * evidence was taken can be handed to a new file inside that window,
     * and freeing it then takes a block away from its brand-new owner:
     * two inodes end up mapping it.
     *
     * The scrub snapshots this before gathering evidence and abandons a
     * Block Group whose count moved. Frees deliberately do NOT bump it,
     * so the scrub's own reclaims don't invalidate the rest of its pass.
     */
    atomic64_t bg_alloc_seq[CETRAFS_BGC_SIZE];

    /* Each BG count's ownership epoch (cetrafs_block_group_t.
     * reconcile_seq) as of OUR reconcile -- the epoch our accrued
     * deltas were born under. The delta-apply CAS refuses an image
     * whose epoch moved (a new owner reconciled; our deltas' durable
     * effects are already in its recount). Written on the ownership
     * paths (alloc.c's reconcile, zonegroup.c's re-attach seeding),
     * read at flush. Moving it DROPS any delta still accrued for that
     * BG (cetrafs_sb_set_bg_epoch()): the epoch only moves on a
     * recount, and a recount already includes it. */
    u64 bg_count_epoch[CETRAFS_BGC_SIZE];
};

struct cetrafs_bg_layout {
    /* exact on-disk image this layout was built from (cetrafs_sb_raw()) */
    cetrafs_superblock_t raw;
    u32 bg_count; /* == raw.block_group_count; the bound for every per-BG access */

    /* Total data-block capacity, summed from every BG descriptor when
     * the layout was built, so statfs reads it from here instead of
     * re-deriving it per call (see cetrafs_statfs()'s comment for what
     * that used to cost). Changes only with the layout. */
    u64 total_data_blocks;

    /* Where the last Block Group ends: a refresh checks the Block Groups
     * a grow added against it, the way the mount checks each one
     * against the one before. */
    u64 last_bg_end;

    /*
     * Every APPENDED Block Group table segment, [header, last
     * descriptor], kept from the mount's chain walk. A grow puts each in
     * a reserve past the data area, and the next grow leaves that
     * reserve as a hole INSIDE [bg_regions_start, bg_data_end): live
     * descriptors the address guard must refuse
     * (cetrafs_sb_lba_run_hits_bg_table()). Empty on a never-grown
     * volume. A live grow appends one: a refresh publishes a new layout
     * carrying the longer list, never edits this one.
     */
    struct cetrafs_lba_range *bg_segs;
    u32 bg_nsegs;

    struct cetrafs_bg_layout *older; /* superseded, freed at unmount */
    u32 nchunks;
    struct cetrafs_bg_chunk *chunk[];
};

struct cetrafs_sb_info {
    u32 block_size;   /* bytes (expected 4096) */
    u64 total_blocks; /* from SB; sanity-checked against device */
    u32 zg_count;
    u64 bg_size_blocks;
    u64 bg_regions_start;

    /* The published Block Group layout (struct cetrafs_bg_layout): read
     * only through cetrafs_sb_layout(), replaced only by
     * cetrafs_sb_layout_publish() under layout_mutex. */
    struct cetrafs_bg_layout *layout;
    struct mutex layout_mutex; /* one refresh at a time */
    /* jiffies (|1) of the last refresh that found the volume grown past
     * this node's device; 0 when not behind. Written under layout_mutex. */
    unsigned long layout_behind_at;
    spinlock_t owned_lock;     /* owned_bgs derivation vs a publish (cetrafs_sb_owned_bgs_derive()) */

    /* In-memory-only cached free-inode count: there is no on-disk field
     * for this (unlike the BG descriptor's free_data_blocks), so it's
     * seeded by a bitmap scan at mount time and kept in sync from then on
     * by cetrafs_alloc_inode()/cetrafs_free_inode() -- see the design notes.
     */
    /* Cached free-inode count for statfs. ATOMIC because it is adjusted
     * from every create and every unlink with no lock held: the bitmap
     * itself is serialised (a CAS, or the cas_mutex fallback) but this
     * counter sits outside that, and a plain u64 += from two concurrent
     * creates in different directories loses one of them. Nothing
     * *decides* on this value -- allocation scans the bitmap and returns
     * -ENOSPC on its own -- so a drift is a lying `df -i` rather than
     * corruption. It is adjusted by THIS node's creates and unlinks only,
     * so a peer's allocations never reach it: cetrafs_sb_get_free_inodes()
     * recounts the bitmap, fresh, when the value is older than
     * CETRAFS_FREE_INODES_RECOUNT_JIFFIES, and sets it from the count
     * (audit O9). */
    atomic64_t free_inodes;
    unsigned long free_inodes_next; /* jiffies: the next recount is due at or after this */

    /* This node's own Node Registry row index, found/claimed by
     * cetrafs_node_register() at mount time. Needed by
     * later phases (ZG claiming stamps this into owner_node_id). */
    u32 node_id;

    /*
     * Per-peer liveness, observed LOCALLY (node.c's
     * cetrafs_node_is_stale()).
     *
     * Staleness used to be `ktime_get_real_seconds() - row.last_seen >
     * CETRAFS_NODE_STALE_SECS` -- our wall clock minus a timestamp
     * written by the PEER's wall clock. That is only a liveness test if
     * every node's clock agrees, and nothing anywhere required or
     * checked that. Two real nodes 1h55m apart made the node that was
     * AHEAD see its live peer as permanently stale: it broke that
     * peer's namespace lock on a shared directory, both nodes then
     * mutated the same dirent blocks with no mutual exclusion, and a
     * 200-file run lost 85 directory entries, leaked 85 inodes and
     * 13885 blocks. (The skew is one-directional, which is why only one
     * node ever fenced the other: the node BEHIND computes a negative
     * age and never finds anyone stale.)
     *
     * Now only ONE clock is involved in any decision: ours. A peer is
     * alive if its own hb_seq counter -- which only it ever bumps --
     * has changed within CETRAFS_NODE_STALE_SECS measured in our local
     * jiffies. Clock skew cannot affect that, because no cross-node
     * timestamp comparison happens at all.
     */
    spinlock_t peer_lock;
    struct cetrafs_peer_watch {
        /* The last sample of this row: its hb_seq, and which machine
         * (node_uuid) and which mount session (incarnation) beat it.
         * hb_seq restarts at 1 when a row is registered afresh, so on
         * its own an old sample could match a NEW holder's beats -- and
         * a live, just-registered node was judged stale at once, from a
         * sample of its predecessor (audit 2026-11-05, class 28). The
         * uuid closed that for another machine; the incarnation closes
         * it for the SAME machine re-registering a row we never saw
         * retired. Not the fence_epoch: our own reclaim bumps it, and a
         * watch reset there would call the peer alive again between its
         * fence and the reclaims that follow. */
        struct cetrafs_row_mark mark;
        unsigned long seen_at; /* local jiffies when it last CHANGED */
        bool valid;            /* have we ever sampled this row? */
        /* The mark of the last STALE verdict: what a reclaim acting on
         * that verdict must still find (the fence, node.c). Not mark
         * above, which the next tick re-samples. */
        struct cetrafs_row_mark judged_mark;
        bool judged;
        /* The mark the last fence of this row landed on: what every
         * reclaim CAS that follows the fence must still find on the row
         * AFTER it lands (cetrafs_node_reattached_since_fence()). */
        struct cetrafs_row_mark fenced_mark;
        bool fenced;
    } *peers;
    u32 peer_count;

    /* This node's Node Registry row's fence_epoch as it stood when we
     * registered. The heartbeat compares the live value against this
     * every tick: a difference means a peer declared us dead and took
     * something of ours, so we must fence (this is the replacement for the
     * old SCSI PR registration lease). */
    u64 fence_epoch;
    u32 incarnation; /* this mount's, as stamped in the row (cetrafs_sb_incarnation()) */

    /* True only once cetrafs_node_register() has actually succeeded for
     * this mount -- node_id alone can't tell cetrafs_free_sb_info()
     * that, since it's a plain kzalloc()'d u32 that reads as 0 (a real,
     * claimable row index) even when registration was never reached or
     * itself failed. Guards cetrafs_node_unregister() below: calling it
     * on an sbi that never actually registered would try to release
     * some *other* node's row 0 right out from under it. */
    bool node_registered;
    /* The mount failed before this node's own journal area was replayed
     * (or its claims swept): the teardown must not announce a clean
     * departure over it (audit 2026-11-14 B-6). */
    bool own_area_unsettled;

    /* This node's own parsed UUID, cached alongside node_id -- needed
     * again by heartbeat.c's periodic tick to derive
     * a PR key when re-running zonegroup.c's claim pass, the same way
     * fs.c's own one-time mount-path call already does with the local
     * variable cetrafs_node_register() filled in. */
    u8 node_uuid[CETRAFS_NODE_UUID_LEN];

    /* Periodic heartbeat renewal + stale ZG reclaim.
     * NULL until cetrafs_heartbeat_start() succeeds near the end of
     * fill_super(); cetrafs_heartbeat_stop() tolerates NULL, so every
     * earlier failure path through cetrafs_free_sb_info() is safe. */
    struct cetrafs_heartbeat *hb;

    /* jiffies before which cetrafs_sb_mount_beat() need not renew. */
    unsigned long mount_beat_next;

    /* Per-ZG journal state: opaque to fs.c, owned
     * entirely by journal.c. NULL until cetrafs_journal_init() succeeds;
     * cetrafs_journal_free() tolerates NULL the same way cetrafs_
     * heartbeat_stop() does. */
    struct cetrafs_journal *journal;

    /* Automatic background defrag (defrag.c): opaque, NULL until
     * cetrafs_defrag_init() succeeds; cetrafs_defrag_stop() tolerates
     * NULL like every other optional subsystem here. */
    struct cetrafs_defrag *defrag;

    /* Automatic background leaked-block scrub (scrub.c): opaque, NULL until
     * cetrafs_scrub_start() succeeds; cetrafs_scrub_stop() tolerates NULL
     * like every other optional subsystem here. */
    struct cetrafs_scrub *scrub;

    /* /proc/fs/cetrafs/<device>/ introspection:
     * opaque to fs.c, owned entirely by procfs.c. NULL until
     * cetrafs_proc_mount_init() succeeds; cetrafs_proc_mount_exit()
     * tolerates NULL the same way cetrafs_heartbeat_stop() does. */
    struct cetrafs_proc_mount *proc_mount;
    bool proc_closing; /* unmount: procfs sweeps stop (cetrafs_proc_sweep_stop()) */
    u64 shrink_seen;   /* the short device size the last tick saw, 0 none (cetrafs_sb_check_device_size()) */


    /* Node-LOCAL serialization of data-bitmap / free-counter
     * read-modify-writes:
     * two local threads growing two different files concurrently both
     * RMW the same BG bitmap byte through the same cached buffer with
     * plain |=/&= -- a torn-update race nothing else covers, since
     * data-block alloc/free deliberately take no cross-node claim at
     * all (see alloc.c). The inode bitmap doesn't need this: its
     * alloc/free go through cetrafs_cas_record(), which serialises
     * local threads itself -- see cas_mutex below. */
    struct mutex alloc_mutex;
    /* cetrafs_sb_stamp_ns(): the real clock at mount, minus the
     * monotonic clock then, and the last value handed out. */
    s64 stamp_base;
    atomic64_t stamp_last;
    /* Set by cetrafs_sb_alloc_lock(), for the holder only: the NOFS
     * scope it opened and who holds it (cetrafs_sb_in_reclaim_lock()). */
    unsigned int alloc_nofs;
    struct task_struct *alloc_owner;
    /* cetrafs_sb_zg_claim_lock(): one Zone Group claim or re-attach at a
     * time on this node, so a tick's re-attach cannot cache a Zone Group
     * another thread is still recounting (audit 2026-11-06 M4). */
    struct mutex zg_claim_mutex;
    struct task_struct *zg_claim_owner;
    /* Zone Groups claimed on the device and not cached yet: their
     * claim is recounting outside zg_claim_mutex (zonegroup.c, BM-39). */
    DECLARE_BITMAP(zg_claiming, CETRAFS_MAX_ZONE_GROUPS);
    wait_queue_head_t zg_claiming_wq;
    /* Held for write by the surplus release while it has Block Groups
     * drained out of the allocator's reach; an allocator that found no
     * space waits on it once before saying ENOSPC
     * (cetrafs_sb_release_wait()). */
    struct rw_semaphore release_rwsem;
    /* Releases ended this mount: an allocator at ENOSPC looks again
     * after waiting only if one ended since it began (audit A4). */
    atomic_t release_seq;
    /* One allocation-bitmap flush at a time (cetrafs_alloc_flush_bitmaps()),
     * and how many are in flight: a flusher that finds a group's mark
     * already taken must wait for the one that took it, or it publishes
     * extents while their bits are still on the way to the device. */
    struct mutex bmap_flush_mutex;
    atomic_t bmap_flush_inflight;
    /* How many bmap_alloc_dirty marks are set -- never fewer: raised
     * before a mark is set, lowered after one is cleared. The per-block
     * tree-edit gate reads it instead of walking every chunk (audit P7). */
    atomic_t bmap_dirty_n;

    /* Node-LOCAL serialization of cetrafs_cas_region()'s no-CAW
     * fallback. On a device with atomic COMPARE AND WRITE this is never
     * taken: the device makes the swap atomic against peers and local
     * threads alike. Without one the fallback is a plain read / decide /
     * write, and two local threads racing it both blind-write the whole
     * region -- last writer wins and the other update vanishes. That is
     * not theoretical: it put two files on one inode number (see
     * caw.c's no-CAW branch for the measurements). The SCSI PR mutex
     * this path used to take covered same-node exclusion as well as
     * cross-node; this restores that half. */
    struct mutex cas_mutex;

    /* Self-fence latch: set once -- never
     * cleared for the mount's lifetime -- when this node discovers its
     * own Node Registry row is gone, i.e. a peer judged it dead
     * (and removed its registration) and has already
     * begun reclaiming its ZGs/locks. From that instant this node has
     * no legitimate claim to write ANYTHING: every mutating path checks
     * this and fails with -EIO (reads too, see below), and the admin recovers
     * by unmounting and remounting (which re-registers and re-joins the
     * cluster fresh). Plain bool + READ_ONCE/WRITE_ONCE: it only ever
     * transitions false->true, and a racing reader seeing the old value
     * for one more operation is within the unavoidable residual window
     * anyway (see heartbeat.c's split-brain note -- this fence shrinks
     * that window from "forever" to "until the zombie's next tick or
     * mutex attempt", it cannot make it zero without hardware fencing).
     *
     * The same latch is the STOPPED state of the error policy
     * (cetrafs_sb_stop(), docs/internal/ERRORS.md): a node that can no
     * longer trust what it knows about the volume stops exactly the way
     * a fenced one does, and since then reads are refused too -- once a
     * peer has reclaimed this node's files it may be writing them, and
     * our cache of them is no longer a copy of anything. */
    bool fenced;
    /* Registration re-attached a row its previous incarnation left
     * without unmounting (cetrafs_lock_sweep_own_claims()). */
    bool reattached_unclean;
    int stop_cause; /* enum cetrafs_stop_cause, set once just before 'fenced' */
    /* The stop's sweep of dirty metadata. Deferred: cetrafs_sb_stop() is
     * called from inside failing operations that hold buffer and folio
     * locks the sweep takes. */
    struct work_struct stop_work;

    /* Where an inode's cold-tree reconcile runs (lock.c). The work holds
     * an igrab() reference, so it must never outlive the mount: on the
     * system workqueue it could still be queued when unmount's
     * evict_inodes() skipped the inode it pinned, and its iput() then
     * evicted -- and freed the blocks of -- a deleted file after
     * put_super had torn this structure down. kill_sb closes the queue
     * (cold_closing, under cold_lock) and flushes it while the mount is
     * still whole; free_sb_info destroys it before anything else. */
    struct workqueue_struct *cold_wq;
    spinlock_t cold_lock;
    bool cold_closing;
    /* The late pass of the own-claim sweep after an unclean re-attach
     * (cetrafs_lock_resweep_own_claims()). On cold_wq and cancelled by
     * cetrafs_sb_cold_close() with it: it igets and iputs inodes, so it
     * must be gone before unmount's evict_inodes(), and a delayed work
     * whose timer has not fired is not flushed by destroying the queue. */
    struct delayed_work resweep_work;
    /* Reconciles that could not read their record, each holding its
     * inode reference, waiting for the heartbeat tick (under cold_lock).
     * cold_retry_mutex brackets a tick's pass, so close can wait out a
     * pass that has taken entries off the list. Every link and unlink
     * of an entry, on this list or on a pass's private one, is under
     * cold_lock: a parked inode's work is not pending, so a new mark can
     * run it again while it is parked, and that run must see it is. */
    struct list_head cold_parked;
    unsigned int cold_parked_n; /* entries on cold_parked; procfs info */
    struct mutex cold_retry_mutex;

    /* errors= and corruption= (mount options, fixed for the mount's
     * life). See cetrafs_sb_fatal() and cetrafs_sb_corrupt(). */
    bool errors_panic;
    bool corruption_stop;
    /* localposixlocks: fcntl/OFD locks granted node-local instead of
     * refused (cetrafs_posix_lock_refuse()). Fixed for the mount's life. */
    bool posix_lock_local;
    /* Integrity errors seen on this mount (nonzero: the volume needs
     * fsck), and the inode numbers they were found in: every write to
     * one of those is refused until a remount. The SET is in memory
     * only; that the volume needs fsck goes on the device too
     * (fsck_needed_since below). */
    atomic_t corruptions;
    struct xarray bad_inos;
    /* ino -> when this node first saw it half-landed with no creator
     * named (cetrafs_sb_half_landed_aged()); values, never pointers. */
    struct xarray half_landed;
    /* The superblock's lasting "needs fsck" mark as this node last read
     * it (mount, every heartbeat's block-0 read), and whether this mount
     * has put its own damage there yet (cetrafs_sb_record_damage()). */
    u64 fsck_needed_since;
    /* What block CETRAFS_SB_REPLICA_NR held at mount (A-7): one of
     * CETRAFS_SB_COPY_*. Said in info; a copy that is not OK is the
     * operator's to fix with fsck -r, never a reason to refuse. */
    int sb_copy_state;
    u32 fsck_needed_node;
    bool damage_recorded;
    /* A regular file's extent-tree blocks held back from writeback until
     * a durability boundary, by LBA (leafdefer.c). */
    struct xarray deferred;
    struct xarray held; /* allocation-bitmap buffers held from writeback, by block (ioutil.c) */
    /* Held-back blocks of inodes evicted with blocks still listed; under
     * the deferred xarray's lock (leafdefer.c). */
    struct list_head deferred_orphans;

    /*
     * The in-core lease: until when this node may keep writing on the
     * strength of its last heartbeat renewal. A peer calls us dead only
     * after watching our hb_seq sit still for at least four of our
     * advertised intervals (cetrafs_sb_peer_progress_stale()); this
     * expires one interval sooner, counted from when that renewal
     * STARTED, so writes stop before anybody can have reclaimed what
     * they write into.
     *
     * The fence above is only ever found by the heartbeat tick -- and a
     * tick stuck behind a hung device finds nothing, while every other
     * thread keeps writing the moment I/O returns. The lease needs no
     * I/O to check: cetrafs_sb_is_fenced() compares jiffies, and on
     * expiry latches lease_lost for good and has lease_work run the
     * ordinary self-fence. Armed by the first successful renewal, on
     * every mount: without CAW a successor is admitted once we look
     * dead. See cetrafs_sb_lease_renewed().
     */
    struct super_block *sb; /* for lease_work */
    /* jiffies our last renewal landed, and when renewals last resumed
     * after an overdue gap (cetrafs_sb_note_renewal()). */
    unsigned long renew_ok_at;
    unsigned long renew_resumed_at;
    bool lease_active;
    u64 lease_until; /* cetrafs_lease_clock() ns */
    unsigned long lease_lost; /* bit 0: expired, latched */
    /* Device witnesses of our own row (cetrafs_sb_fence_witnessed()):
     * reads started, and the latest one that completed. A count, never a
     * clock -- the clock is what a paused node cannot trust (F-8). */
    u64 witness_started;
    u64 witness_done;
    unsigned long witness_at; /* jiffies, for fence_witness_f8_off only */
    struct mutex witness_mutex;
    struct work_struct lease_work;
    bool lease_work_ready;

    /* Atomic COMPARE AND WRITE capability of the backing device,
     * discovered ONCE at mount (the SCSI path issues a VPD INQUIRY, so
     * it must not be re-probed per operation) and cached here. Decides
     * per-mount whether the device provides atomic CAW at all; without it the
     * volume can only be mounted single-node (the mount gate enforces it). */
    struct cetrafs_caw_info caw;

    /* Set just before the defrag workqueue is drained at unmount, so an
     * in-flight incremental move stops at its next chunk boundary (every
     * boundary leaves a fully consistent tree) instead of making the
     * unmount wait out a multi-GB relocation. */
    bool defrag_draining;

    /* Per-mount defragmentation switches, written through procfs
     * (procfs.c's 'controls' file). Both default to on, so an operator
     * who says nothing gets the behaviour that was always there.
     *
     * They exist because the defragmenter pins the file's cross-node
     * EXCLUSIVE lock while it relocates, so a peer is refused any open
     * -- reads included -- for the duration. That is accepted for a VM
     * datastore, where one node owns an image anyway, and wrong for a
     * volume where it is not, so it has to be switchable without
     * rebuilding or remounting. Per MOUNT rather than per module (the
     * auto_defrag module param is module-wide): one node may own the
     * images on this volume while another only reads them.
     *
     * defrag_enabled gates defragmentation ENTIRELY, the ioctl
     * included -- the only setting under which nothing on this mount
     * ever pins that lock for an optimisation. auto_defrag_enabled
     * gates the background janitor alone. */
    bool defrag_enabled;
    bool auto_defrag_enabled;

    /* UNMAP (discard.c). discard_enabled is the per-mount switch for the
     * automatic part -- a Block Group's data region discarded as it goes
     * back to the pool. On by default, off with the `nodiscard` mount
     * option or the `discard` control. FITRIM is the operator asking and
     * ignores it.
     *
     * trim_mutex: one FITRIM pass at a time. trim_lba/trim_count: the
     * run that pass has claimed and is discarding right now (0/0 for
     * none), under alloc_mutex -- the free paths refuse to clear a bit
     * inside it (cetrafs_sb_trim_holds()), and a release refuses to
     * drain trim_bg while it is held (cetrafs_sb_drain_bg()). */
    bool discard_enabled;
    struct mutex trim_mutex;
    u64 trim_lba;
    u64 trim_count;
    /* Rows a watch of this mount saw stand still for a whole window,
     * with the mark they stood at (node.c; audit 2026-11-15 BM-22). One
     * per registry row, allocated by the first verdict. */
    struct cetrafs_row_mark *row_silent;
    unsigned long *row_silent_valid;
    u32 trim_bg;
    /* discard_pending: Block Groups whose hand-back discard failed with
     * an UNKNOWN outcome -- it may still execute. Each stays drained
     * (out of this node's allocator: cetrafs_sb_undrain_bg() refuses
     * it) and out of every release until a discard of it is known to
     * have run or been refused (cetrafs_bg_release_empty()). The
     * in-core mirror of CETRAFS_BG_FLAG_DISCARD_PENDING (format
     * 0x000A), which is what survives an unmount, a crash or a
     * takeover: loaded from the descriptors at mount and whenever a
     * Zone Group is about to enter this node's ownership
     * (cetrafs_bg_refresh_owner_map()). Keyed by BG id. */
    struct xarray discard_pending;
    atomic_t discard_pending_count;
    /* Inline discard (`-o discard`, discard.c): the queue of runs freed
     * in our own groups and the worker that discards them. From mount
     * to cetrafs_inline_discard_close() in cetrafs_free_sb_info(). */
    struct cetrafs_inline_discard *inline_discard;

    /* The cross-node whole-file EXCLUSIVE open lock (lock.c): on by
     * default, turned off at mount time with the `nofilelock` option.
     *
     * Off is for a datastore whose upper layer coordinates sharing itself
     * -- notably Proxmox/qemu LIVE migration, which must open the image on
     * BOTH nodes during the handoff and gets -ETXTBSY from our exclusive
     * lock otherwise. With it off, cetrafs claims no lock and refuses no
     * open; the caller (qemu + the cluster manager) owns "don't double
     * write", the same bet VMFS makes. Mount-time only (a remount cannot
     * flip it), per-MOUNT, exposed read-only in procfs. Defrag is forced
     * off alongside it: the defragmenter's safety RESTS on pinning this
     * lock, so relocating a file nobody is locked out of could corrupt a
     * peer's concurrent write. */
    bool file_lock_enabled;
    /* What THIS mount asked for (before the cluster's mode was adopted):
     * a second mount of the device is compared against it, not against
     * the adopted value (cetrafs_get_tree()). */
    bool file_lock_requested;

    /* Cluster timing, per MOUNT, written through procfs like the defrag
     * switches above. The module params are the defaults.
     *
     * Per-mount because a test has to be able to compress them without
     * reloading the module or disturbing anything else on the host: the
     * real windows are ~60 s, which is a minute of waiting in every
     * scenario that needs a node to time out. They are the one pair of
     * numbers that changes what "dead" means, so they are also the one
     * pair worth being able to see and set on a live mount. */
    unsigned int hb_interval_secs;
    unsigned int stale_secs;

    /* Cached "which ZGs does this node own, and which BGs do they span"
     * -- see cetrafs_sb_cache_zg_ownership()/_zg_owned_cached() below.
     * Found via real two-node testing: zonegroup.c's
     * cetrafs_alloc_pick_bg() -- called on every single new block a
     * write needs -- used to re-derive ownership from scratch on every
     * call by scanning *every* ZG via cetrafs_read_zg(), which is always
     * a forced-uncached (real device round trip) read by design. On the
     * loop-device test harness that's nearly free, so it went unnoticed;
     * on real iSCSI hardware it meant every block of a write paying for
     * zone_group_count real network round trips, reported as the whole
     * filesystem being "extremely slow".
     *
     * What makes the cache safe is the LEASE, not that ownership cannot
     * move. A peer takes a ZG only from an owner it has judged stale,
     * and it bumps that owner's fence_epoch first. A live owner whose
     * renewals keep landing is never judged stale; one whose renewals
     * stop self-fences one beat before the soonest window any peer may
     * use on it (cetrafs_sb_lease_secs()); and one that
     * WAS judged stale -- wrongly or not -- sees its epoch move on its
     * next heartbeat tick and fences. So a ZG can be taken from under
     * this cache, and this node can go on allocating from it until that
     * tick at the latest; every write after it is refused
     * (tests/kernel/zg_steal_victim_fences.sh). Nothing here re-reads
     * the ZG record: that would be a device round trip per block. */
    DECLARE_BITMAP(owned_zgs, CETRAFS_MAX_ZONE_GROUPS);
    /* Zone Group records found unreadable (cetrafs_sb_zg_note_unreadable()):
     * reported once each, then left out of every claim. */
    DECLARE_BITMAP(zg_unreadable, CETRAFS_MAX_ZONE_GROUPS);
    /* Zone Groups a free found full under a dead owner: the heartbeat
     * adopts them (cetrafs_zg_adopt_wanted()), never the freeing thread,
     * which may hold inode_lock/invalidate_lock or run from reclaim. */
    DECLARE_BITMAP(zg_adopt_wanted, CETRAFS_MAX_ZONE_GROUPS);
    /* Woken when the heartbeat has tried one of zg_adopt_wanted: an
     * allocator that deferred a steal waits here (cetrafs_sb_zg_adopt_wait()). */
    wait_queue_head_t zg_adopt_wq;


    /*
     * The Block Group cetrafs_alloc_pick_bg() last handed out -- the
     * allocation cursor, and the whole reason that function is not
     * O(owned BGs) per allocated block any more.
     *
     * pick_bg runs ONCE PER 4 KiB BLOCK a write allocates, and its scan
     * reads every owned BG's descriptor, each costing a CRC32C over the
     * full 4096-byte block. At a few tens of owned BGs that is a core's
     * worth of CRC per second of streaming write, and it GROWS: a
     * filling node claims more ZGs, so each block costs more than the
     * last. ("The throughput gets slower as the file progresses.")
     *
     * Sticking to the BG we are already filling is also strictly better
     * packing than re-deciding every block -- the scan's best-fit rule
     * exists to fill a partly-used BG rather than spread, which is what
     * staying put does by construction -- and it keeps the contiguity
     * hint landing, so a sequential write stays one extent instead of
     * fragmenting into a leaf update (and a journalled write) per block.
     *
     * Advisory, so it needs no lock: a torn or stale read just yields a
     * BG that the scan would not have picked. What it must not do is
     * name a BG we gave up, and cetrafs_sb_bg_is_ours() and
     * cetrafs_alloc_check_owned() both catch that -- against this
     * node's CACHED ownership, the same belief as everything else on
     * the per-block path (see owned_zgs above for why that is safe and
     * what bounds it). A full BG simply falls through to the scan.
     * Needs no "unset" sentinel: zero-initialised it names BG 0, which
     * is either ours and usable (a perfectly good hint) or not ours and
     * rejected by the first check.
     */
    u32 alloc_bg_cursor;






    /* TEST ONLY (alloc_shadow=1): in-core shadow of every data-block
     * allocate/free this node performs, indexed by absolute LBA. A
     * second SET of a still-set bit is a double allocation caught at
     * the exact moment with a stack -- immune to any buffer-cache
     * staleness, which is the point: it arbitrates between "the bitmap
     * buffer lied" and "two allocators really were handed one block". */
    unsigned long *alloc_shadow;
    /* Inode numbers mid-BIRTH on this node: set by cetrafs_alloc_inode(),
     * cleared once the first name is published (or by any free). The
     * scrub's orphan reclaim must skip these: a newborn's record is not
     * yet written, so to a scanner it is indistinguishable from the
     * previous incarnation's dead record -- the scrub freed exactly such
     * a number 378us after its rebirth and two files ended up sharing
     * one inode (2026-10-29, full-probe churn tape). */
    unsigned long *inode_birth;
    /* Orders this node's inode allocations against its own orphan
     * reclaims. An allocation holds it shared from its bit CAS until the
     * number is in inode_birth; a reclaim holds it exclusive from its
     * claim through its release, and re-checks inode_birth inside. Without
     * it a local reclaim could judge a bit this node had just set -- the
     * registry entry not made yet -- and clear it after the creator's
     * birth claim had already landed on its own claim (a peer's reclaim
     * cannot: its claim needs an unlocked record). */
    struct rw_semaphore birth_rwsem;
    struct task_struct *birth_writer; /* the reclaim holding it for write */

    /* Per-ZG pending-free backoff.
     *
     * A free aimed at a ZG this node does not own is appended to that
     * ZG's queue, and the append SCANS every slot: qblocks * regions
     * compare-and-swaps, each a device round trip. When the queue is
     * full that whole scan is paid per extent and finds nothing --
     * deleting one large image is tens of thousands of extents, so the
     * futile scanning, not the leak, is what makes the filesystem feel
     * stopped.
     *
     * So a full queue is REMEMBERED for pf_full_backoff_ms: subsequent
     * frees for that ZG drop immediately without scanning, and the
     * drops are counted so one summary can replace tens of thousands of
     * identical messages. The owner drains on its own tick, and the
     * first append after the backoff expires finds the space.
     *
     * Dropping leaks the blocks, which is the safe direction (rule 8):
     * the bit stays set, so nothing is shared, and the owner's scrub or
     * fsck -r reclaims it. */
    unsigned long *zg_pf_full_until; /* jiffies; 0 = not known full */
    u64 *zg_pf_drop_runs;            /* dropped since the burst began */
    u64 *zg_pf_drop_blocks;

    unsigned long bg_sweep_last; /* jiffies of the last foreign-descriptor sweep */
    unsigned long pf_drain_last; /* jiffies of the last on-demand pending-free drain */
    struct mutex pf_drain_mutex; /* one pending-free drain at a time (cetrafs_zg_drain_pending_frees()) */

    /*
     * Namespace locks this node took and could not give back.
     *
     * The release is a compare-and-swap and it can fail -- a transient
     * device error, memory pressure. The code logged "leaving the lock
     * for stale-reclaim", which is an accurate description of what
     * happens and a poor outcome: stale reclaim only fires when a node
     * stops heartbeating, and this one is alive. The lock would sit
     * there until the node died or unmounted, and every namespace
     * operation on that inode, from any node, would exhaust its retry
     * budget and return -EBUSY. Not a hang -- the waiters do give up --
     * but the inode is unusable cluster-wide for as long as we live.
     *
     * So a failed release is remembered and retried on the heartbeat.
     * Bounded: past this many the oldest is dropped and reported, which
     * is no worse than the behaviour this replaces.
     */
    spinlock_t nsrel_lock;
    /* Held by a retry pass from taking the set to putting back what it
     * could not settle; nsrel_active says one is in flight (under
     * nsrel_lock). A local acquire waits it out before dropping its own
     * inode's entry -- see cetrafs_sb_nslock_forget(). */
    struct mutex nsrel_mutex;
    bool nsrel_active;
    u32 nsrel_count;
    struct cetrafs_nsrel_pending nsrel[CETRAFS_NSLOCK_DEFERRED_MAX];

    /* File locks whose last close could not publish or clear them (see
     * cetrafs_lock_retry_deferred()). Kept as (ino, generation), never
     * as an inode reference, so nothing here can hold up an unmount.
     * Under flrel_lock. */
    spinlock_t flrel_lock;
    u32 flrel_count;
    struct cetrafs_nsrel_pending flrel[CETRAFS_FLOCK_DEFERRED_MAX];

    /* This node's presence bits whose withdraw did not land (see
     * cetrafs_lock_retry_presence()). Same shape and reason as flrel:
     * nobody reclaims a live node's bit. Under prrel_lock. */
    spinlock_t prrel_lock;
    u32 prrel_count;
    struct cetrafs_nsrel_pending prrel[CETRAFS_PRESENCE_DEFERRED_MAX];

    /* Inode-number reclaim claims whose give-back did not land (see
     * cetrafs_reclaim_pending in kmod.h). Under rcrel_lock. */
    spinlock_t rcrel_lock;
    u32 rcrel_count;
    struct cetrafs_reclaim_pending rcrel[CETRAFS_RECLAIM_DEFERRED_MAX];


    /* The ZG free_data_blocks aggregate is ACCRUED here and applied by
     * one compare-and-swap per ZG at a durability boundary, rather than
     * written into a cached copy of the ZG block the way the BG half
     * above is.
     *
     * The difference is forced: free_data_blocks shares the ZG record's
     * HOT SECTOR -- the 512-byte CAS unit -- with owner_node_id. A
     * cached read-modify-write dirties the whole 4096-byte block, so
     * whenever that buffer is written back it republishes the ownership
     * bytes as they were when it was read. A peer that claimed the ZG in
     * between (a stale-owner steal, say) has its claim silently reverted
     * by what looks like an unrelated counter update -- with a correctly
     * recomputed hot checksum, so nothing detects it -- and both nodes
     * then allocate from the same Zone Group.
     *
     * Accruing in memory and applying with a CAS keeps the batching
     * (nothing reaches the device per block) while making the only
     * writer of that sector the compare-and-swap. It is also strictly
     * less work than before: one 512-byte swap per boundary instead of
     * a 4096-byte block write plus a CRC over the sector per block. */
    atomic64_t zg_free_delta[CETRAFS_MAX_ZONE_GROUPS];

    /*
     * A delta on its way to the aggregate: the BG side's in-flight
     * count (cetrafs_bg_chunk.bg_flight_gen), for the same window --
     * the flush took the delta out of zg_free_delta before its CAS, and
     * statfs, which reads the record uncached, counted the blocks free
     * for one device round trip. Odd zg_flight_gen while a flush is out;
     * zg_flight_free is the count its CAS writes, known once the mutator
     * has seen the image (before any write is sent: until then the
     * record a reader got is the old one, and it adds zg_flight_delta).
     * zg_flush_busy serialises EVERY local writer of the aggregate, the
     * direct applies too (a claim's credit, a release's debit, a
     * reconcile), so nothing of ours moves the record under a flight.
     */
    spinlock_t zg_flight_lock;
    u32 zg_flight_gen[CETRAFS_MAX_ZONE_GROUPS];
    s64 zg_flight_delta[CETRAFS_MAX_ZONE_GROUPS];
    s64 zg_flight_free[CETRAFS_MAX_ZONE_GROUPS];
    bool zg_flight_known[CETRAFS_MAX_ZONE_GROUPS];
    DECLARE_BITMAP(zg_flush_busy, CETRAFS_MAX_ZONE_GROUPS);

    /*
     * Every LIVE speculative allocation run on this mount, so the
     * background scrub can see them.
     *
     * A reservation (lock.c) is a contiguous run MARKED IN THE BITMAP
     * and referenced by NO extent, held for as long as the file stays
     * open. That is bit-for-bit the scrub's definition of a leaked
     * block -- and the scrub's safety argument explicitly rests on
     * "a real allocation commits its extent within the two-pass gap,
     * so it is referenced by the second pass" (scrub.c, point 2), which
     * a reservation does not. Without this list the scrub frees a run
     * out from under
     * its owner, the owner hands those blocks out anyway, and two files
     * end up sharing them.
     *
     * One entry per open regular file that is being written, embedded
     * in cetrafs_inode_info (no allocation), so the list is short and
     * the scrub's per-candidate walk is cheap -- candidates are rare by
     * construction.
     */
    spinlock_t resv_list_lock;
    struct list_head resv_list;
    /* Bumped, under resv_list_lock, every time blocks LEAVE the
     * registry: a span unpublished or re-pointed. A released run has
     * become somebody's data (written and closed, committed by a
     * defrag), so a scrub verdict taken before the release may not free
     * on it -- see cetrafs_sb_resv_seq(). */
    u64 resv_seq;

    /* Frees in flight: operations between a publish that dropped blocks
     * and the frees of those blocks (cetrafs_frees_begin()). The count
     * and seq are what this node's own scrub asks; frees_foreign counts
     * those with a block outside our own Block Groups, the only ones a
     * peer's scrub judges, and frees_row_flag is whether our registry
     * row says so to everyone else's. All under frees_mutex, which is
     * held across the row CAS so a begin cannot be overtaken by the
     * heartbeat's clear. */
    struct mutex frees_mutex;
    unsigned int frees_count;
    unsigned int frees_foreign;
    bool frees_row_flag;
    u64 frees_local_seq;
};

static inline struct cetrafs_bg_layout *cetrafs_sb_layout_of(struct cetrafs_sb_info *sbi)
{
    /* Pairs with the release in cetrafs_sb_layout_publish(): whatever
     * this returns was fully built before it became visible. */
    return sbi ? smp_load_acquire(&sbi->layout) : NULL;
}

/* The chunk holding bg_id in the current layout, and its index there;
 * NULL for an id the layout does not have. The bound and the chunk come
 * from ONE snapshot, so a valid id always lands in a chunk that exists. */
static inline struct cetrafs_bg_chunk *cetrafs_bgc(struct cetrafs_sb_info *sbi, u32 bg_id, u32 *idx)
{
    struct cetrafs_bg_layout *l = cetrafs_sb_layout_of(sbi);

    if (!l || bg_id >= l->bg_count)
        return NULL;
    *idx = bg_id & CETRAFS_BGC_MASK;
    return l->chunk[bg_id >> CETRAFS_BGC_SHIFT];
}

/* The next Block Group at or after 'from' whose bit is set in the
 * per-chunk bitmap at offset 'off' of struct cetrafs_bg_chunk, or
 * U32_MAX. A chunk's bits past bg_count are never set (every setter is
 * bounded by the layout), so the last chunk needs no special case
 * beyond its limit. */
static u32 cetrafs_bgc_next_bit(struct cetrafs_sb_info *sbi, size_t off, u32 from)
{
    struct cetrafs_bg_layout *l = cetrafs_sb_layout_of(sbi);
    u32 n = l ? l->bg_count : 0;

    while (from < n) {
        u32 ci = from >> CETRAFS_BGC_SHIFT, base = ci << CETRAFS_BGC_SHIFT;
        u32 lim = min_t(u32, n - base, CETRAFS_BGC_SIZE);
        const unsigned long *bits = (const unsigned long *) ((const char *) l->chunk[ci] + off);
        u32 i = (u32) find_next_bit(bits, lim, from - base);

        if (i < lim)
            return base + i;
        from = base + CETRAFS_BGC_SIZE;
    }
    return U32_MAX;
}



/*
 * A layout for 'raw', sharing every chunk 'prev' has and adding zeroed
 * ones for the Block Groups beyond it. prev == NULL is the mount's first
 * layout. The capacity, last end and segment list are carried over for
 * the caller to extend; the caller fills in what the new Block Groups
 * need and publishes, or hands it to cetrafs_layout_discard().
 */
static struct cetrafs_bg_layout *cetrafs_layout_alloc(const cetrafs_superblock_t *raw,
                                                      const struct cetrafs_bg_layout *prev)
{
    u32 nbg = le32_to_cpu(raw->block_group_count);
    u32 nchunks = DIV_ROUND_UP(nbg, CETRAFS_BGC_SIZE);
    u32 have = prev ? prev->nchunks : 0, ci;
    struct cetrafs_bg_layout *l;

    if (prev && nbg < prev->bg_count)
        return NULL; /* a layout never loses Block Groups; the caller refuses first */
    if (nbg > CETRAFS_MAX_BLOCK_GROUPS)
        return NULL; /* every path that sizes a layout by the count: the mount refuses it first (F4) */
    l = kvzalloc(struct_size(l, chunk, nchunks), GFP_KERNEL);
    if (!l)
        return NULL;
    memcpy(&l->raw, raw, sizeof(*raw));
    l->bg_count = nbg;
    l->nchunks = nchunks;
    for (ci = 0; ci < nchunks; ci++) {
        if (ci < have) {
            l->chunk[ci] = prev->chunk[ci];
            continue;
        }
        l->chunk[ci] = kvzalloc(sizeof(struct cetrafs_bg_chunk), GFP_KERNEL);
        if (!l->chunk[ci]) {
            while (ci-- > have)
                kvfree(l->chunk[ci]);
            kvfree(l);
            return NULL;
        }
        spin_lock_init(&l->chunk[ci]->flight_lock);
    }
    if (prev) {
        l->total_data_blocks = prev->total_data_blocks;
        l->last_bg_end = prev->last_bg_end;
    }
    return l;
}

/* An unpublished layout that will not be used: only what it added is
 * its own -- the chunks it shares with 'prev' are prev's. */
static void cetrafs_layout_discard(struct cetrafs_bg_layout *l, const struct cetrafs_bg_layout *prev)
{
    u32 ci;

    if (!l)
        return;
    for (ci = prev ? prev->nchunks : 0; ci < l->nchunks; ci++)
        kvfree(l->chunk[ci]);
    kfree(l->bg_segs);
    kvfree(l);
}

/*
 * Record Block Group b's descriptor address in a layout being built.
 * Below 'from' the address is already known -- the chunk is shared with
 * the published layout -- and must come out the same: a grow only ever
 * APPENDS to the chain, so a walk that resolves an existing Block Group
 * somewhere else is reading a chain that was rewritten, not grown.
 */
static int cetrafs_layout_note_desc(struct cetrafs_bg_layout *l, u32 b, u32 from, u64 lba)
{
    struct cetrafs_bg_chunk *c = l->chunk[b >> CETRAFS_BGC_SHIFT];
    u32 i = b & CETRAFS_BGC_MASK;

    if (b >= from) {
        c->bg_desc_lba[i] = lba;
        return 0;
    }
    if (c->bg_desc_lba[i] == lba)
        return 0;
    pr_err("Block Group %u's descriptor moved from %llu to %llu -- the table chain was rewritten, not grown; "
           "refusing the new layout\n",
           b, (unsigned long long) c->bg_desc_lba[i], (unsigned long long) lba);
    return -EUCLEAN;
}

/*
 * The segment a grow has LINKED but not yet PUBLISHED, or a link into
 * nowhere.
 *
 * growfs writes the new segment, then the previous tail's next, then
 * the superblock that counts the new Block Groups. Between the last two
 * -- for as long as a live grow runs, or forever if it died there --
 * the chain has one segment more than the count, and every mount and
 * refresh in that window used to refuse the volume. That state is
 * legitimate exactly when the extra segment is what the next grow
 * would have written: past the published end and on the device,
 * intact, continuing the numbering where the count stops, and the end
 * of the chain. Anything else is
 * still refused, with the message the mount always gave.
 */
static int cetrafs_layout_pending_link(struct super_block *sb, const cetrafs_superblock_t *raw, u64 seg_lba, u32 nbg)
{
    u64 dev_blocks = bdev_nr_bytes(sb->s_bdev) / CETRAFS_BLOCK_SIZE;
    const cetrafs_bg_segment_t *seg;
    struct buffer_head *sbh;
    int rc = -EUCLEAN;

    if (seg_lba >= dev_blocks) {
        pr_err("BG table chain links to block %llu, past the end of the device (%llu)\n",
               (unsigned long long) seg_lba, (unsigned long long) dev_blocks);
        return -EUCLEAN;
    }
    /* A grow writes its segment past the end the superblock publishes;
     * a link to anywhere inside the volume is not one. */
    if (seg_lba < le64_to_cpu(raw->total_blocks)) {
        pr_err("BG table chain links a segment at %llu past the %u Block Groups the superblock counts, inside "
               "the volume -- refusing\n",
               (unsigned long long) seg_lba, nbg);
        return -EUCLEAN;
    }
    cetrafs_invalidate_block(sb, seg_lba);
    sbh = sb_bread(sb, seg_lba);
    if (!sbh)
        return -EIO;
    seg = (const cetrafs_bg_segment_t *) sbh->b_data;
    if (le32_to_cpu(seg->magic) == CETRAFS_BGSEG_MAGIC && cetrafs_bgseg_crc(seg) == (u32) le64_to_cpu(seg->checksum) &&
        le32_to_cpu(seg->first_bg_id) == nbg && le32_to_cpu(seg->count) &&
        seg_lba + 1 + le32_to_cpu(seg->count) <= dev_blocks && !le64_to_cpu(seg->next)) {
        pr_notice("BG table chain links a segment at %llu for Block Groups %u.. that the superblock does not count "
                  "yet -- a grow in progress, or one that never published; not used until it does\n",
                  (unsigned long long) seg_lba, nbg);
        rc = 0;
    } else {
        pr_err("BG table chain links a segment at %llu past the %u Block Groups the superblock counts, and it is "
               "not a grow's next segment\n",
               (unsigned long long) seg_lba, nbg);
        pr_err("a grow was interrupted before it published -- re-run growfs.cetra\n");
    }
    brelse(sbh);
    return rc;
}

/* TEST ONLY: the walk skips the new Block Groups' header check, so
 * tests/crash/growfs_live_crash.sh's control can still record a grow
 * that publishes over regions nobody initialised. */
static bool cetrafs_grow_hdr_check_off;
cetrafs_test_param(grow_hdr_check_off, cetrafs_grow_hdr_check_off, bool, 0644);
MODULE_PARM_DESC(grow_hdr_check_off, "TEST ONLY: a live grow does not verify its new Block Groups' headers");

/*
 * Walk the Block Group table chain of l->raw and fill in what the
 * layout needs: every descriptor address, the appended segments, and
 * for each Block Group from 'prev' on (all of them at mount) its owner
 * and capacity, read and checked.
 *
 * prev is the published layout when a live refresh builds a longer one;
 * its Block Groups were checked when it was built and are not re-read,
 * but their addresses must come out of the walk unchanged
 * (cetrafs_layout_note_desc()), and a segment the grow added must lie
 * past every one of them. Reads are forced fresh on a refresh: the
 * blocks are a peer's, written moments ago.
 */
/* TEST ONLY: the layout walk reads each descriptor on its own, as before
 * audit 2026-11-14 P4 -- the control of tests/kernel/mount_bg_readahead.sh. */
static bool cetrafs_mount_bg_ra_off;
cetrafs_test_param(mount_bg_ra_off, cetrafs_mount_bg_ra_off, bool, 0644);
MODULE_PARM_DESC(mount_bg_ra_off, "TEST ONLY: the mount reads each Block Group descriptor on its own");
#define CETRAFS_MOUNT_BG_RA 256

static int cetrafs_layout_walk(struct super_block *sb, struct cetrafs_bg_layout *l,
                               const struct cetrafs_bg_layout *prev, struct cetrafs_grow_plan *gp)
{
    const cetrafs_superblock_t *ondisk = &l->raw;
    const u64 total = le64_to_cpu(ondisk->total_blocks);
    const u32 nbg = l->bg_count, from = prev ? prev->bg_count : 0;
    const bool fresh = prev != NULL;
    const bool ra = !READ_ONCE(cetrafs_mount_bg_ra_off); /* once per walk */
    struct cetrafs_lba_range *segs = NULL;
    u32 nsegs = 0, b;
    u64 prev_end = prev ? prev->last_bg_end : 0; /* where the previous Block Group ended */
    u64 total_data = prev ? prev->total_data_blocks : 0;
    int rc = 0;

    /*
     * Resolve every Block Group's descriptor address BEFORE reading any
     * of them. Walks the chain once: the implicit first segment at
     * bg_table_start, then each appended segment's header
     * (docs/internal/BG-OWNERSHIP-DESIGN.md).
     */
    {
        u64 first = le64_to_cpu(ondisk->bg_table_first_count);
        u64 seg_lba = le64_to_cpu(ondisk->bg_table_next);
        u64 tbl = le64_to_cpu(ondisk->bg_table_start);
        u32 filled = 0, guard = 0, cap = 0;

        /* Zero on a volume that has never been grown: the table is the
         * contiguous run it has always been. */
        if (!first || first > nbg)
            first = nbg;
        for (b = 0; b < first && b < nbg; b++) {
            rc = cetrafs_layout_note_desc(l, b, from, tbl + b);
            if (rc)
                goto out;
        }
        filled = (u32) first;

        /* To the END of the chain, not just until enough descriptors
         * are collected: stopping early never follows the tail's next,
         * so a loop or a link into nowhere would mount clean. */
        while (seg_lba) {
            struct buffer_head *sbh;
            const cetrafs_bg_segment_t *seg;
            u32 cnt, i;

            /* Every Block Group counted, and still a link: a grow's
             * unpublished segment, or corruption. */
            if (filled == nbg) {
                rc = cetrafs_layout_pending_link(sb, ondisk, seg_lba, nbg);
                goto walked;
            }

            /* The link itself, before it is followed: a next pointing
             * off the device is a corrupt chain, not an I/O error to
             * puzzle over. */
            if (seg_lba >= total) {
                pr_err("BG table chain links to block %llu, past the end of the device (%llu)\n",
                       (unsigned long long) seg_lba, (unsigned long long) total);
                rc = -EUCLEAN;
                goto out;
            }
            /* A chain is a loop waiting to happen; bound it by the only
             * number that can honestly bound it. */
            if (++guard > nbg + 1) {
                pr_err("BG table chain does not terminate -- refusing\n");
                rc = -EUCLEAN;
                goto out;
            }
            /* One read per segment, up to a million on a hostile chain:
             * killable, and never a soft lockup (audit 2026-11-14 M-31,
             * BM-19). */
            if (fatal_signal_pending(current)) {
                rc = -EINTR;
                goto out;
            }
            cond_resched();
            if (fresh)
                cetrafs_invalidate_block(sb, seg_lba);
            sbh = sb_bread(sb, seg_lba);
            if (!sbh) {
                rc = -EIO;
                goto out;
            }
            seg = (const cetrafs_bg_segment_t *) sbh->b_data;
            if (le32_to_cpu(seg->magic) != CETRAFS_BGSEG_MAGIC) {
                pr_err("BG table segment at %llu has no magic\n", (unsigned long long) seg_lba);
                brelse(sbh);
                rc = -EUCLEAN;
                goto out;
            }
            /*
             * The checksum this header CARRIES, which the mount path
             * once never looked at: growfs writes it and fsck verifies
             * it, and a single flipped bit in count, first_bg_id or next
             * was trusted completely by the one reader that acts on
             * them.
             */
            if (cetrafs_bgseg_crc(seg) != (u32) le64_to_cpu(seg->checksum)) {
                pr_err("BG table segment at %llu fails its checksum\n", (unsigned long long) seg_lba);
                brelse(sbh);
                rc = -EUCLEAN;
                goto out;
            }

            cnt = le32_to_cpu(seg->count);
            /* A grow adds at least one Block Group, so a segment with
             * none is damage -- and it is what let a chain grow to a
             * million segments without describing a single group. */
            if (!cnt) {
                pr_err("BG table segment at %llu describes no Block Group\n", (unsigned long long) seg_lba);
                brelse(sbh);
                rc = -EUCLEAN;
                goto out;
            }
            /*
             * Checked BEFORE the loop, not after it. 'cnt' comes off the
             * device and 'filled' is a u32: a segment claiming four
             * billion descriptors walked that many times, wrapped
             * 'filled' past 2^32, and could land back on exactly nbg --
             * passing both this test and the final tally.
             */
            if (cnt > nbg - filled) {
                pr_err("BG table segment at %llu claims %u descriptors; only %u are left of %u\n",
                       (unsigned long long) seg_lba, cnt, nbg - filled, nbg);
                brelse(sbh);
                rc = -EUCLEAN;
                goto out;
            }
            /* And the descriptors a segment points at have to be ON the
             * device. */
            if (seg_lba + 1 + cnt > total) {
                pr_err("BG table segment at %llu describes blocks past the end of the device (%llu)\n",
                       (unsigned long long) seg_lba, (unsigned long long) total);
                brelse(sbh);
                rc = -EUCLEAN;
                goto out;
            }
            /*
             * And WHERE it is. Only the first segment went through
             * cetrafs_validate_layout(); an appended one could sit on
             * the inode table and pass, and every descriptor update
             * after that is a write into whatever is really there. A
             * grow only ever puts a segment in a tail reserve, past
             * every fixed table, so nothing below bg_regions_start is
             * legal; overlap with a Block Group is checked once their
             * descriptors are read. And a segment must continue the
             * numbering exactly.
             */
            if (seg_lba < le64_to_cpu(ondisk->bg_regions_start) || le32_to_cpu(seg->first_bg_id) != filled) {
                pr_err("BG table segment at %llu (first_bg_id %u, expected %u) lies among the fixed tables "
                       "below %llu or breaks the numbering -- refusing\n",
                       (unsigned long long) seg_lba, le32_to_cpu(seg->first_bg_id), filled,
                       (unsigned long long) le64_to_cpu(ondisk->bg_regions_start));
                brelse(sbh);
                rc = -EUCLEAN;
                goto out;
            }
            /* A segment a live grow added sits past every Block Group
             * that already existed: the grow puts it after the ones it
             * adds. The new Block Groups are checked against it below;
             * the old ones were never read again, so this is the check
             * that keeps it off them. */
            if (prev && filled >= from && seg_lba < prev->last_bg_end) {
                pr_err("BG table segment at %llu lies inside the Block Groups that existed before the grow "
                       "(they end at %llu) -- refusing the new layout\n",
                       (unsigned long long) seg_lba, (unsigned long long) prev->last_bg_end);
                brelse(sbh);
                rc = -EUCLEAN;
                goto out;
            }
            if (nsegs == cap) {
                u32 ncap = cap ? cap * 2 : 8;
                void *n = krealloc_array(segs, ncap, sizeof(*segs), GFP_KERNEL);

                if (!n) {
                    brelse(sbh);
                    rc = -ENOMEM;
                    goto out;
                }
                segs = n;
                cap = ncap;
            }
            {
                segs[nsegs].start = seg_lba;
                segs[nsegs].end = seg_lba + 1 + cnt;
                nsegs++;
            }
            for (i = 0; i < cnt; i++, filled++) {
                rc = cetrafs_layout_note_desc(l, filled, from, seg_lba + 1 + i);
                if (rc) {
                    brelse(sbh);
                    goto out;
                }
            }
            /* A grow being validated before it is linked: the old tail
             * still says next = 0 on the device, and the walk follows
             * the link the grow is about to write instead. */
            if (gp && filled == from && gp->new_seg_lba) {
                gp->tail_lba = segs[nsegs - 1].start;
                seg_lba = gp->new_seg_lba;
            } else {
                seg_lba = le64_to_cpu(seg->next);
            }
            brelse(sbh);
        }
walked:
        if (rc)
            goto out;
        if (filled != nbg) {
            pr_err("BG table chain describes %u of %u Block Groups\n", filled, nbg);
            rc = -EUCLEAN;
            goto out;
        }
    }

    /*
     * Two table segments over one block: each descriptor update then
     * writes the other's. Checked against the fixed tables and the Block
     * Groups only, never each other (audit 2026-11-06 M2).
     */
    /* Sorted, so each pair is the neighbours: O(n log n) where the
     * pairwise compare was O(n^2) -- 10^12 compares on a hostile chain,
     * in mount context, unkillable (M-31). The Block Group checks below
     * and cetrafs_sb_lba_run_hits_bg_table() search it. */
    {
        u32 a;

        sort(segs, nsegs, sizeof(*segs), cetrafs_lba_range_cmp, NULL);
        for (a = 1; a < nsegs; a++)
            if (segs[a].start < segs[a - 1].end) {
                pr_err("BG table segments [%llu,%llu) and [%llu,%llu) overlap -- refusing\n",
                       (unsigned long long) segs[a - 1].start, (unsigned long long) segs[a - 1].end,
                       (unsigned long long) segs[a].start, (unsigned long long) segs[a].end);
                rc = -EUCLEAN;
                goto out;
            }
    }

    for (b = from; b < nbg; b++) {
        struct cetrafs_bg_chunk *c = l->chunk[b >> CETRAFS_BGC_SHIFT];
        u32 ci = b & CETRAFS_BGC_MASK;
        u64 t = 0, bstart = 0, blen = 0, dstart = 0;
        u32 owner = CETRAFS_NODE_ID_NONE;
        u16 bflags = 0;
        int brc;

        /* Read the next window ahead, as one plugged batch: one
         * synchronous round trip per descriptor made a 64 TiB mount
         * 65,536 serial reads before anything else (audit 2026-11-14
         * P4). Dropped first when this walk must read fresh, so what
         * lands is the device's; each read below still verifies, and
         * retries a tear forced-fresh. */
        if (ra && (b - from) % CETRAFS_MOUNT_BG_RA == 0) {
            struct blk_plug plug;
            u32 r, rend = min_t(u32, nbg, b + CETRAFS_MOUNT_BG_RA);

            blk_start_plug(&plug);
            for (r = b; r < rend; r++) {
                u64 rl = l->chunk[r >> CETRAFS_BGC_SHIFT]->bg_desc_lba[r & CETRAFS_BGC_MASK];

                if (fresh)
                    cetrafs_invalidate_block(sb, rl);
                sb_breadahead(sb, rl);
            }
            blk_finish_plug(&plug);
            cond_resched();
            if (fatal_signal_pending(current)) {
                rc = -EINTR; /* a mount reading a million descriptors stays killable */
                goto out;
            }
        }
        /* Same single pass also records which Zone Group owns each
         * Block Group, which is what lets ownership be answered from
         * memory from here on. Fresh was served by the drop above. */
        brc = cetrafs_bg_mount_info(sb, &l->raw, b, c->bg_desc_lba[ci], fresh && !ra, &t, &owner, &bstart, &blen,
                                    &bflags, &dstart);
        /* The data region inside the group, or the address check would
         * accept a run the group cannot hold. */
        if (!brc && (dstart < bstart || t > blen || dstart - bstart > blen - t)) {
            pr_err("Block Group %u's data region [%llu,+%llu) is not inside the group [%llu,+%llu) -- refusing\n", b,
                   (unsigned long long) dstart, (unsigned long long) t, (unsigned long long) bstart,
                   (unsigned long long) blen);
            brc = -EUCLEAN;
        }
        /*
         * Block Groups in order, none over the one before. Each
         * descriptor was checked alone, so two checksum-valid
         * descriptors naming the same blocks mounted, and both bitmaps
         * handed those blocks out -- two files on one block. fsck
         * refuses exactly this; the mount did not (audit 2026-11-06 M2;
         * tests/kernel/bg_overlap_refused.sh).
         */
        if (!brc && bstart < prev_end) {
            pr_err("Block Group %u [%llu,+%llu) starts before the previous one ends (%llu) -- refusing\n", b,
                   (unsigned long long) bstart, (unsigned long long) blen, (unsigned long long) prev_end);
            brc = -EUCLEAN;
        }
        if (!brc)
            prev_end = bstart + blen;
        /* A descriptor segment inside a Block Group is a table the
         * allocator will write data over, and data a descriptor update
         * will write over. */
        if (!brc && blen && cetrafs_lba_ranges_hit(segs, nsegs, bstart, blen)) {
            pr_err("a BG table segment overlaps Block Group %u [%llu,+%llu) -- refusing\n", b,
                   (unsigned long long) bstart, (unsigned long long) blen);
            brc = -EUCLEAN;
        }
        if (brc) {
            /*
             * The result used to be DISCARDED on failure, and the mount
             * carried on -- leaving the group not unknown but WRONG:
             * owned by Zone Group 0 (zeroed state) and missing from the
             * capacity. cetrafs_read_bg_geom() has already retried a
             * checksum mismatch, so an error here means the descriptor
             * really does not verify. Found by the fuzzer's
             * fsck-versus-mount oracle.
             */
            pr_err("Block Group %u's descriptor does not verify (%d) -- refusing to %s\n", b, brc,
                   prev ? "use the grown layout" : "mount");
            rc = brc == -EIO ? -EIO : -EUCLEAN;
            goto out;
        }
        /* A live grow adds its Block Groups to the pool and nowhere
         * else, and credits each pool shard with what it adds
         * (cetrafs_grow_commit()). */
        if (gp && owner != CETRAFS_BG_OWNER_FREE) {
            pr_err("Block Group %u of the grow names owner %u -- a live grow adds Block Groups to the pool only\n", b,
                   owner);
            rc = -EINVAL;
            goto out;
        }
        if (gp) {
            /* The descriptor verified; the region it names must too, or
             * the grow publishes groups nobody initialised. */
            rc = READ_ONCE(cetrafs_grow_hdr_check_off) ? 0 : cetrafs_grow_check_bg_header(sb, b, bstart, blen);
            if (rc)
                goto out;
            gp->shard_credit[b % gp->nshards] += t;
        }
        total_data += t;
        /* A discard outstanding on the device (CETRAFS_BG_FLAG_DISCARD_
         * PENDING): known before any Zone Group claim derives this
         * group's owned bit, so no allocator here ever sees it free. */
        if (bflags & CETRAFS_BG_FLAG_DISCARD_PENDING)
            cetrafs_sb_set_bg_discard_pending(sb, b, true);
        WRITE_ONCE(c->bg_owner_zg[ci], (u16) owner);
        WRITE_ONCE(c->bg_data_start[ci], dstart);
        WRITE_ONCE(c->bg_data_count[ci], t);
    }

    l->total_data_blocks = total_data;
    l->last_bg_end = prev_end;
    l->bg_segs = segs;
    l->bg_nsegs = nsegs;
    return 0;
out:
    kfree(segs);
    return rc;
}

/* Unmount (or a failed mount): the newest layout holds every chunk any
 * layout ever had, so its chunks are freed once and the superseded ones
 * give back only themselves. */
static void cetrafs_layout_free_chain(struct cetrafs_bg_layout *l)
{
    u32 ci;

    if (!l)
        return;
    for (ci = 0; ci < l->nchunks; ci++)
        kvfree(l->chunk[ci]);
    while (l) {
        struct cetrafs_bg_layout *older = l->older;

        kfree(l->bg_segs);
        kvfree(l);
        l = older;
    }
}

/* TEST ONLY: hold the next layout publish inside owned_lock, after it
 * has marked the Block Groups it adds and before the layout is
 * published, for this many ms (one-shot, at most 5000; a busy wait --
 * the lock is a spinlock). A Zone Group claim or release landing in it
 * must wait for the publish and then see the new layout
 * (tests/kernel/grow_live_owned_race.sh). */
static unsigned int cetrafs_layout_publish_hold_ms;
cetrafs_test_param(layout_publish_hold_ms, cetrafs_layout_publish_hold_ms, uint, 0644);
MODULE_PARM_DESC(layout_publish_hold_ms, "TEST ONLY: hold the next layout publish inside owned_lock for N ms");

/* TEST ONLY: the derive takes no owned_lock -- the negative control for
 * the lock (the same suite). */
static bool cetrafs_owned_derive_unlocked;
cetrafs_test_param(owned_derive_unlocked, cetrafs_owned_derive_unlocked, bool, 0644);
MODULE_PARM_DESC(owned_derive_unlocked, "TEST ONLY: derive owned_bgs without owned_lock");

/* A publish is being held (above), and how many derives started while
 * it was: the suite's proof that its claim or release really landed in
 * the window. */
static atomic_t cetrafs_publish_holding = ATOMIC_INIT(0);
static atomic64_t cetrafs_owned_derive_overlaps = ATOMIC64_INIT(0);

u64 cetrafs_owned_derive_overlap_count(void)
{
    return (u64) atomic64_read(&cetrafs_owned_derive_overlaps);
}

/*
 * Set or clear owned_bgs for every Block Group zg_id owns, after
 * owned_zgs changed. Under owned_lock, against the layout as it stands
 * INSIDE the lock: a refresh publishes a longer layout and derives the
 * new Block Groups' bits under the same lock, so of the two one runs
 * second and sees what the other did. Without it a release that walked
 * the old layout would leave a just-added Block Group of the released
 * Zone Group marked ours -- the allocator then writing into a group this
 * node has given away. O(bg_count) in memory, on a path taken only when
 * ownership changes.
 */
static void cetrafs_sb_owned_bgs_derive(struct cetrafs_sb_info *sbi, u32 zg_id, bool own)
{
    bool locked = !READ_ONCE(cetrafs_owned_derive_unlocked);
    struct cetrafs_bg_layout *l;
    u32 b;

    if (atomic_read(&cetrafs_publish_holding))
        atomic64_inc(&cetrafs_owned_derive_overlaps);
    if (locked)
        spin_lock(&sbi->owned_lock);
    l = cetrafs_sb_layout_of(sbi);
    for (b = 0; l && b < l->bg_count; b++) {
        struct cetrafs_bg_chunk *c = l->chunk[b >> CETRAFS_BGC_SHIFT];
        u32 i = b & CETRAFS_BGC_MASK;

        if (READ_ONCE(c->bg_owner_zg[i]) != (u16) zg_id)
            continue;
        /* A group with a discard outstanding is never allocatable,
         * whoever owns it (CETRAFS_BG_FLAG_DISCARD_PENDING). */
        if (own && !cetrafs_sb_bg_discard_pending_ignored(sbi, b))
            set_bit(i, c->owned_bgs), set_bit(i, c->release_check);
        else
            clear_bit(i, c->owned_bgs);
    }
    if (locked)
        spin_unlock(&sbi->owned_lock);
}

/*
 * The invariant owned_lock keeps: a Block Group is marked ours exactly
 * when the Zone Group it belongs to is. 'stray' counts marked groups of
 * a Zone Group this node does not own -- the allocator would write into
 * a group given away -- and 'missing' unmarked groups of one it does.
 * Under owned_lock, so it never sees a derive or publish half done; a
 * claim or release between its owned_zgs bit and its derive can still
 * show for that instant, so read it quiet. O(bg_count), procfs only.
 */
void cetrafs_sb_owned_bgs_check(struct super_block *sb, u32 *stray, u32 *missing)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    struct cetrafs_bg_layout *l;
    u32 b;

    *stray = *missing = 0;
    spin_lock(&sbi->owned_lock);
    l = cetrafs_sb_layout_of(sbi);
    for (b = 0; l && b < l->bg_count; b++) {
        struct cetrafs_bg_chunk *c = l->chunk[b >> CETRAFS_BGC_SHIFT];
        u32 i = b & CETRAFS_BGC_MASK;
        u16 z = READ_ONCE(c->bg_owner_zg[i]);
        bool should = z < CETRAFS_MAX_ZONE_GROUPS && test_bit(z, sbi->owned_zgs);
        bool is = test_bit(i, c->owned_bgs);

        if (is && !should)
            (*stray)++;
        else if (!is && should)
            (*missing)++;
    }
    spin_unlock(&sbi->owned_lock);
}

/* Mount-option state, carried on fc->fs_private from parse time to
 * fill_super(). Only one option so far: file_lock (default on). */
static void cetrafs_sb_stop_work(struct work_struct *w);

struct cetrafs_fc_info {
    bool file_lock;
    bool errors_panic;    /* errors=panic */
    bool corruption_stop; /* corruption=stop */
    bool nodiscard;       /* nodiscard */
    bool inline_discard;  /* discard */
    bool posix_lock_local; /* localposixlocks */
    /* Which of the above were STATED, rather than defaulted: only a
     * stated option can be "asked for and not in force". */
    bool file_lock_set, errors_set, corruption_set, nodiscard_set, discard_set, posix_lock_local_set;
    bool filled; /* fill_super ran: a new mount, not a second one of a mounted device */
};

/* TEST ONLY: fail the per-peer liveness allocation (audit L30). */
static bool cetrafs_fill_fail_peers_alloc;
cetrafs_test_param(fill_fail_peers_alloc, cetrafs_fill_fail_peers_alloc, bool, 0644);
MODULE_PARM_DESC(fill_fail_peers_alloc, "TEST ONLY: the mount's per-peer liveness allocation fails");

/*
 * TEST ONLY: fail fill_super() at a chosen stage, so each unwind path
 * can actually be exercised.
 *
 * fill_super() builds a mount out of a dozen subsystems and has as many
 * early returns, every one of which has to undo exactly what was built
 * so far -- on a clustered filesystem that means more than freeing
 * memory: a registry row has been claimed on the shared LUN, and a peer
 * that never sees it released waits out a staleness window before it
 * can reclaim anything that row owns. None of those paths had any
 * coverage, because none of them can be reached by any input a test can
 * supply (they are ENOMEM and device-error paths). Hence the param.
 *
 * Inert at 0, which is what production always runs.
 */
static unsigned int cetrafs_mount_fail_at;
cetrafs_test_param(mount_fail_at, cetrafs_mount_fail_at, uint, 0644);
MODULE_PARM_DESC(mount_fail_at,
                 "TEST ONLY: fail the mount after stage N (1=register 2=gate 3=journal 4=zg-claim "
                 "5=heartbeat 6=defrag 7=root-dentry 8=procfs); 0 disables");

/* TEST ONLY: a mount failing after an unclean re-attach and before its
 * claim sweep announces a clean departure, as before audit 2026-11-15
 * BM-16 (tests/kernel/mount_fail_unswept.sh). */
static bool cetrafs_mount_unswept_clean;
cetrafs_test_param(mount_unswept_clean, cetrafs_mount_unswept_clean, bool, 0644);
MODULE_PARM_DESC(mount_unswept_clean, "TEST ONLY: a mount failing before its own-claim sweep departs clean");

/* TEST ONLY: a fatal error (cetrafs_sb_fatal()) at fail point N, the
 * mount carrying on as a phase that only logs its failure would
 * (tests/kernel/mount_stopped_refused.sh). */
static unsigned int cetrafs_mount_fatal_at;
cetrafs_test_param(mount_fatal_at, cetrafs_mount_fatal_at, uint, 0644);
MODULE_PARM_DESC(mount_fatal_at, "TEST ONLY: stop the mount with a fatal error at fail point N and carry on");

/* TEST ONLY: a mount that stopped while mounting reports success, as
 * before audit 2026-11-15 BM-20. */
static bool cetrafs_mount_stopped_ok;
cetrafs_test_param(mount_stopped_ok, cetrafs_mount_stopped_ok, bool, 0644);
MODULE_PARM_DESC(mount_stopped_ok, "TEST ONLY: a mount that stopped while mounting still succeeds");

#define CETRAFS_MOUNT_FAIL_POINT(stage)                                                  \
    do {                                                                                 \
        if (unlikely(cetrafs_mount_fatal_at == (stage)))                                 \
            cetrafs_sb_fatal(sb, "TEST: fatal error at mount stage %u", (unsigned int) (stage)); \
        if (unlikely(cetrafs_mount_fail_at == (stage))) {                                \
            pr_warn("TEST: failing the mount after stage %u\n", (unsigned int) (stage)); \
            cetrafs_free_sb_info(sb);                                                    \
            brelse(bh);                                                                  \
            return -EIO;                                                                 \
        }                                                                                \
    } while (0)

/* Supported incompatible feature bits (reject unknown) */
#define CETRAFS_KNOWN_INCOMPAT \
    (CETRAFS_FEAT_INCOMPAT_EXTENTS | CETRAFS_FEAT_INCOMPAT_GLOBAL_ITBL | CETRAFS_FEAT_INCOMPAT_NODE_REGISTRY)

/* Supported read-only-compatible feature bits. Deliberately NONE: no
 * ro_compat feature is implemented, so any bit set describes a volume
 * this build does not fully understand but can still safely read. Such
 * a volume mounts read-only and is refused read-write -- which is what
 * the whole ro_compat class is for, and which was simply never checked
 * (the field was read by procfs and by nothing else). */
#define CETRAFS_KNOWN_RO_COMPAT 0ULL

/*
 * Every region the superblock describes, checked against each other and
 * against the device.
 *
 * Each of these starts is used directly as a WRITE target -- an inode
 * record is a blind full-block write at inode_table_start + (ino - 1), a
 * ZG claim is a compare-and-swap at zg_table_start + zg_id, and so on.
 * Nothing downstream re-derives any of them, so a superblock saying
 * inode_table_start = 1 means every file creation overwrites a Zone
 * Group record, and one saying 0 means it overwrites the superblock.
 *
 * The CRC does not help here: it proves the bytes are the bytes that
 * were written, not that the map they describe is sane. This project
 * already drew that distinction for journal entries -- fsck and
 * journal.c both bounds-check an entry's target precisely because a
 * correctly-checksummed entry naming block 0 destroys the superblock
 * when replay applies it. The superblock's own region map had no
 * equivalent check at all.
 */
struct cetrafs_region {
    const char *name;
    u64 start;
    u64 count;
};

/* CRC32C over a BG table segment header with its checksum field treated
 * as zero -- the convention growfs stamps with and fsck verifies, three
 * segments like alloc.c's cetrafs_bg_crc_verify(). */
/*
 * The same CRC over a PREFIX of the header -- the CAS region a swap hands
 * its mutator (kmod/grow.c) -- with the rest of the block taken as the
 * zeros it holds: everything past the first 32 bytes is padding, written
 * zero, and the one-sector assertion in cetrafs.h keeps every field
 * inside the region. A prefix whose stored checksum verifies this way
 * therefore came from a block whose padding really is zero.
 */
u32 cetrafs_bgseg_crc_prefix(const void *img, unsigned int len)
{
    static const u8 zero[256] = {0};
    size_t off = offsetof(cetrafs_bg_segment_t, checksum);
    size_t clen = sizeof(((cetrafs_bg_segment_t *) NULL)->checksum);
    size_t left;
    u32 crc = ~0U;

    if (len > sizeof(cetrafs_bg_segment_t))
        len = sizeof(cetrafs_bg_segment_t);
    if (len < off + clen)
        return 0; /* cannot hold the fields; never matches a real checksum by design of the caller */
    crc = crc32c(crc, img, off);
    crc = crc32c(crc, zero, clen);
    crc = crc32c(crc, (const u8 *) img + off + clen, len - off - clen);
    for (left = sizeof(cetrafs_bg_segment_t) - len; left; left -= min_t(size_t, left, sizeof(zero)))
        crc = crc32c(crc, zero, min_t(size_t, left, sizeof(zero)));
    return ~crc;
}

u32 cetrafs_bgseg_crc(const cetrafs_bg_segment_t *seg)
{
    static const u8 zero[8] = {0};
    size_t off = offsetof(cetrafs_bg_segment_t, checksum);
    size_t clen = sizeof(seg->checksum);
    u32 crc = ~0U;

    BUILD_BUG_ON(sizeof(zero) != sizeof(seg->checksum));

    crc = crc32c(crc, seg, off);
    crc = crc32c(crc, zero, clen);
    crc = crc32c(crc, (const u8 *) seg + off + clen, sizeof(*seg) - off - clen);
    return ~crc;
}

static int cetrafs_validate_layout(const cetrafs_superblock_t *sb, u64 total_blocks)
{
    struct cetrafs_region r[10];
    unsigned int n = 0, i, j;
    u64 zg_cnt = le32_to_cpu(sb->zone_group_count);
    u64 bg_cnt = le32_to_cpu(sb->block_group_count);

    /* A zero-sized pending-free queue gives every cross-node free
     * nowhere to go: each one leaks. fsck refuses the volume for it; the
     * mount used to accept it (audit L11). */
    if (!le32_to_cpu(sb->pending_free_blocks_per_zg)) {
        pr_err("superblock: the pending-free queue has zero blocks per Zone Group\n");
        return -EINVAL;
    }
    if (le32_to_cpu(sb->node_journal_blocks) > CETRAFS_JOURNAL_MAX_BLOCKS) {
        pr_err("superblock: per-node journal of %u blocks exceeds the format's %u\n",
               le32_to_cpu(sb->node_journal_blocks), CETRAFS_JOURNAL_MAX_BLOCKS);
        return -EINVAL;
    }

    r[n++] = (struct cetrafs_region) {"superblock and its copy", 0, CETRAFS_SB_AREA_BLOCKS};
    r[n++] = (struct cetrafs_region) {"zone group table", le64_to_cpu(sb->zg_table_start), zg_cnt};
    /* the FIRST SEGMENT only. The Block Group table is a chain: the run at
     * bg_table_start holds bg_table_first_count descriptors and the rest
     * live in appended segments elsewhere, so block_group_count stopped
     * being this region's length the moment a volume was grown
     * (docs/internal/BG-OWNERSHIP-DESIGN.md). */
    {
        u64 first = le64_to_cpu(sb->bg_table_first_count);

        if (!first || first > bg_cnt)
            first = bg_cnt; /* never grown: the table is the whole run */
        r[n++] = (struct cetrafs_region) {"block group table", le64_to_cpu(sb->bg_table_start), first};
    }
    r[n++] =
        (struct cetrafs_region) {"inode bitmap", le64_to_cpu(sb->inode_bmap_start), le64_to_cpu(sb->inode_bmap_blocks)};
    r[n++] = (struct cetrafs_region) {"inode table", le64_to_cpu(sb->inode_table_start),
                                      le64_to_cpu(sb->inode_table_blocks)};
    r[n++] = (struct cetrafs_region) {"node registry", le64_to_cpu(sb->node_table_start),
                                      le64_to_cpu(sb->node_table_blocks)};
    r[n++] = (struct cetrafs_region) {"pending-free queues", le64_to_cpu(sb->pending_free_start),
                                      zg_cnt * le32_to_cpu(sb->pending_free_blocks_per_zg)};
    r[n++] = (struct cetrafs_region) {"per-node journals", le64_to_cpu(sb->node_journal_start),
                                      (u64) le32_to_cpu(sb->node_table_count) * le32_to_cpu(sb->node_journal_blocks)};
    /* The data area is a BOUNDING BOX when bg_data_end is set: a grown
     * volume has a hole where a superseded tail reserve used to be, so
     * bg_cnt * bg_size_blocks is no longer its extent (cetrafs.h). A
     * never-grown volume keeps the exact computed span. */
    /* Refused before the layout is sized by it: the mount allocates per
     * Block Group before it reads any descriptor (audit F4). */
    if (bg_cnt > CETRAFS_MAX_BLOCK_GROUPS) {
        pr_err("superblock: %llu Block Groups exceeds the format's %u\n", (unsigned long long) bg_cnt,
               CETRAFS_MAX_BLOCK_GROUPS);
        return -EINVAL;
    }
    {
        u64 data_start = le64_to_cpu(sb->bg_regions_start);
        u64 data_end = le64_to_cpu(sb->bg_data_end);
        u64 bg_size = le64_to_cpu(sb->bg_size_blocks);
        u64 span;

        /*
         * The cap moved UP here, ahead of the multiplication it bounds.
         * It used to sit after both uses of bg_cnt * bg_size_blocks --
         * so the product it exists to keep sane was computed twice
         * before anyone had checked either factor.
         */
        if (bg_size > CETRAFS_MAX_BG_SIZE_BLOCKS) {
            pr_err("superblock: Block Group size %llu blocks exceeds the largest that can be indexed (%llu)\n",
                   (unsigned long long) bg_size, (unsigned long long) CETRAFS_MAX_BG_SIZE_BLOCKS);
            return -EINVAL;
        }

        /*
         * And the product itself is checked, not assumed. Both factors
         * come off the device: bg_cnt * bg_size overflows u64 long
         * before either field runs out of range, and a wrapped span is
         * SMALL -- which makes the "is the data area big enough"
         * test below pass for a geometry that does not fit at all.
         */
        if (check_mul_overflow(bg_cnt, bg_size, &span)) {
            pr_err("superblock: %llu Block Groups of %llu blocks overflow a 64-bit span\n",
                   (unsigned long long) bg_cnt, (unsigned long long) bg_size);
            return -EINVAL;
        }

        if (!data_end && check_add_overflow(data_start, span, &data_end)) {
            pr_err("superblock: data area starting at %llu plus %llu blocks overflows\n",
                   (unsigned long long) data_start, (unsigned long long) span);
            return -EINVAL;
        }
        if (data_end < data_start) {
            pr_err("superblock: bg_data_end (%llu) precedes bg_regions_start (%llu)\n", (unsigned long long) data_end,
                   (unsigned long long) data_start);
            return -EINVAL;
        }

        /*
         * The box must be at least big enough to HOLD its Block Groups.
         *
         * This is what the old contiguous-span model gave for free and
         * the bounding box silently gave up: with the span, a carve
         * placed one BG too low made the computed span reach past the
         * tables and the overlap test caught it. The box is derived
         * from the same carve, so a low carve just produces a smaller
         * box that still "contains" its overlapping BGs -- and mounts.
         * A grow test injecting exactly that found this.
         *
         * A hole only ever makes the box LARGER than the sum of its
         * BGs, never smaller, so >= is the honest invariant. O(1), from
         * the superblock alone: no BG table scan on the mount path.
         */
        /*
         * A Block Group's blocks are tracked in core by the kernel's
         * bitmap API, whose indices are `unsigned int`. A group bigger
         * than that cannot be addressed by them: the scrub's reference
         * set cast the offset down and marked the WRONG blocks as
         * referenced, which makes it free live ones. mkfs refuses such
         * a geometry; this refuses the image, because the superblock is
         * a file on a shared device and nothing stops it being written
         * by something else.
         */
        if (data_end - data_start < span) {
            pr_err("superblock: data area [%llu,%llu) is too small for %llu Block Group(s) of %llu blocks\n",
                   (unsigned long long) data_start, (unsigned long long) data_end, (unsigned long long) bg_cnt,
                   (unsigned long long) bg_size);
            return -EINVAL;
        }
        r[n++] = (struct cetrafs_region) {"block group regions", data_start, data_end - data_start};
    }

    /* Drop the regions that are legitimately absent (a zero-sized
     * journal, no pending-free reservation) rather than treating a zero
     * start as an overlap with the superblock. */
    for (i = 0; i < n;) {
        if (r[i].count == 0) {
            r[i] = r[--n];
            continue;
        }
        if (r[i].start == 0 && i != 0) {
            pr_err("superblock: %s starts at block 0 (the superblock itself)\n", r[i].name);
            return -EINVAL;
        }
        /* start + count must not wrap, and must stay on the device. */
        if (r[i].count > total_blocks || r[i].start > total_blocks - r[i].count) {
            pr_err("superblock: %s [%llu,+%llu) does not fit in total_blocks=%llu\n", r[i].name,
                   (unsigned long long) r[i].start, (unsigned long long) r[i].count, (unsigned long long) total_blocks);
            return -EINVAL;
        }
        i++;
    }

    /* Insertion sort by start -- ten entries, and it keeps the overlap
     * test to one linear pass. */
    for (i = 1; i < n; i++) {
        struct cetrafs_region key = r[i];

        for (j = i; j > 0 && r[j - 1].start > key.start; j--)
            r[j] = r[j - 1];
        r[j] = key;
    }

    for (i = 1; i < n; i++) {
        if (r[i].start < r[i - 1].start + r[i - 1].count) {
            pr_err("superblock: %s [%llu,+%llu) overlaps %s [%llu,+%llu)\n", r[i].name, (unsigned long long) r[i].start,
                   (unsigned long long) r[i].count, r[i - 1].name, (unsigned long long) r[i - 1].start,
                   (unsigned long long) r[i - 1].count);
            return -EINVAL;
        }
    }

    return 0;
}

/* ------ helpers ------ */
/* TEST ONLY: once the mount has validated the superblock, change the
 * live buffer under it (tests/kernel/sb_copy_validated.sh). */
static bool cetrafs_sb_scribble_once;
cetrafs_test_param(sb_scribble_once, cetrafs_sb_scribble_once, bool, 0644);
MODULE_PARM_DESC(sb_scribble_once, "TEST ONLY: zero the cached superblock's root_ino after the mount validated it");

static int cetrafs_check_sb_crc(const void *buf, size_t len, __le64 stored)
{
    u32 want = (u32) le64_to_cpu(stored);
    void *tmp = kmemdup(buf, len, GFP_KERNEL);
    u32 crc;

    if (!tmp)
        return -ENOMEM;

    /* zero the checksum field before computing, like mkfs/fsck */
    *(__le64 *) ((u8 *) tmp + offsetof(cetrafs_superblock_t, checksum)) = cpu_to_le64(0);

    crc = ~crc32c(~0U, tmp, len); /* same init/final xor as userspace */
    kfree(tmp);
    return (crc == want) ? 0 : -EUCLEAN;
}

/* Restamp a superblock image's checksum after editing it. */
static void cetrafs_sb_restamp(cetrafs_superblock_t *s)
{
    s->checksum = cpu_to_le64(0);
    s->checksum = cpu_to_le64((u64) ~crc32c(~0U, s, sizeof(*s)));
}

/*
 * The superblock's STATUS fields -- the lasting "needs fsck" mark --
 * from 'src' into 'dst'. Neither says where anything is, so every check
 * that block 0 still describes the volume a node mounted compares
 * around them, and a grow publishes over whatever mark the device has.
 */
void cetrafs_sb_copy_status(cetrafs_superblock_t *dst, const cetrafs_superblock_t *src)
{
    dst->fsck_needed_since = src->fsck_needed_since;
    dst->fsck_needed_node = src->fsck_needed_node;
    dst->fsck_needed_pad = src->fsck_needed_pad;
}

/* Do 'a' and 'b' describe the same volume, status fields aside? */
static bool cetrafs_sb_same_layout(const cetrafs_superblock_t *a, const cetrafs_superblock_t *b)
{
    cetrafs_superblock_t x = *a, y = *b;

    cetrafs_sb_copy_status(&y, &x);
    y.checksum = x.checksum;
    return !memcmp(&x, &y, sizeof(x));
}

/*
 * The copy of block 0 (CETRAFS_SB_REPLICA_NR, A-7), read off the device.
 * 0 and *out filled: a superblock that verifies. -EUCLEAN: anything else
 * (no magic, a bad checksum). -EIO: unreadable. Reported only: nothing
 * mounts from the copy, since each node choosing between two copies on
 * its own is how a shared volume ends up with two layouts.
 */
static int cetrafs_sb_copy_read(struct super_block *sb, cetrafs_superblock_t *out)
{
    struct buffer_head *bh = cetrafs_bread_uncached(sb, CETRAFS_SB_REPLICA_NR);

    if (!bh)
        return -EIO;
    cetrafs_bh_copy_stable(bh, out, sizeof(*out));
    brelse(bh);
    if (le32_to_cpu(out->magic) != CETRAFS_MAGIC || cetrafs_check_sb_crc(out, sizeof(*out), out->checksum))
        return -EUCLEAN;
    return 0;
}

/* Say what block 0's copy offers when block 0 itself does not verify. */
static void cetrafs_sb_copy_hint(struct super_block *sb)
{
    cetrafs_superblock_t copy;

    if (!cetrafs_sb_copy_read(sb, &copy))
        pr_err("%s: block 0 does not verify, but its copy at block %llu does -- unmount every node and run "
               "fsck.cetra -r, which restores block 0 from it\n",
               sb->s_id, (unsigned long long) CETRAFS_SB_REPLICA_NR);
}

/* Remember the mark as last read off the device. */
static void cetrafs_sb_note_status(struct cetrafs_sb_info *sbi, const cetrafs_superblock_t *s)
{
    WRITE_ONCE(sbi->fsck_needed_node, le32_to_cpu(s->fsck_needed_node));
    WRITE_ONCE(sbi->fsck_needed_since, le64_to_cpu(s->fsck_needed_since));
}

/*
 * Is 'nw' a grow of 'cur' and nothing else?
 *
 * A grow changes the fields that say how big the volume is and where
 * its newest table segment is -- and nothing else. Every other field
 * names something this mount has been using for its whole life (the
 * inode table, the journals, the Node Registry, the Zone Group count,
 * the Block Group size); a superblock that moved one of those is not
 * a grow, it is a different filesystem or a damaged one, and the only
 * safe answer is to keep the layout we have and say so.
 */
static bool cetrafs_layout_is_grow_of(const cetrafs_superblock_t *cur, const cetrafs_superblock_t *nw)
{
    cetrafs_superblock_t a = *cur, b = *nw;

    if (le32_to_cpu(nw->block_group_count) < le32_to_cpu(cur->block_group_count) ||
        le64_to_cpu(nw->total_blocks) < le64_to_cpu(cur->total_blocks) ||
        le64_to_cpu(nw->layout_gen) <= le64_to_cpu(cur->layout_gen))
        return false;
    /* What a grow may change; everything else must match byte for byte. */
    b.total_blocks = a.total_blocks;
    b.block_group_count = a.block_group_count;
    b.layout_gen = a.layout_gen;
    b.tail_reserve_start = a.tail_reserve_start;
    b.tail_reserve_blocks = a.tail_reserve_blocks;
    b.orphan_blocks = a.orphan_blocks;
    b.bg_data_end = a.bg_data_end;
    b.bg_table_next = a.bg_table_next;
    b.bg_table_first_count = a.bg_table_first_count;
    b.checksum = a.checksum;
    cetrafs_sb_copy_status(&b, &a); /* status, not layout: a mark may come and go */
    return !memcmp(&a, &b, sizeof(a));
}

/* TEST ONLY: refuse the next refresh's new layout after it was built,
 * as if a descriptor had not verified -- the negative control for "a
 * refused refresh leaves the old layout in force". */
static bool cetrafs_layout_refresh_fail_once;
cetrafs_test_param(layout_refresh_fail_once, cetrafs_layout_refresh_fail_once, bool, 0644);
MODULE_PARM_DESC(layout_refresh_fail_once, "TEST ONLY: discard the next refreshed layout as if it did not verify");

/* TEST ONLY: the next live grow commits to the device but this node does
 * not switch to the new layout -- it is then exactly a peer that has not
 * caught up, which is the only way one host can exercise the refresh
 * paths (tests/kernel/grow_live_refresh.sh). */
static bool cetrafs_grow_skip_local_publish;
cetrafs_test_param(grow_skip_local_publish, cetrafs_grow_skip_local_publish, bool, 0644);
MODULE_PARM_DESC(grow_skip_local_publish, "TEST ONLY: the next live grow is not published to this node's own layout");

/* TEST ONLY: an address past the known end is refused without first
 * catching up -- the negative control for the on-demand refresh. */
static bool cetrafs_layout_past_end_no_refresh;
cetrafs_test_param(layout_past_end_no_refresh, cetrafs_layout_past_end_no_refresh, bool, 0644);

/* TEST ONLY: the address check stops at the box, as before M-40 -- the
 * negative control of tests/kernel/extent_aims_bitmap.sh. */
static bool cetrafs_lba_bg_check_off;
cetrafs_test_param(lba_bg_check_off, cetrafs_lba_bg_check_off, bool, 0644);
MODULE_PARM_DESC(layout_past_end_no_refresh, "TEST ONLY: refuse past-the-end addresses without refreshing the layout");

static atomic64_t cetrafs_layout_refreshes = ATOMIC64_INIT(0);
static atomic64_t cetrafs_layout_refresh_refused = ATOMIC64_INIT(0);

u64 cetrafs_layout_refresh_count(void)
{
    return (u64) atomic64_read(&cetrafs_layout_refreshes);
}

u64 cetrafs_layout_refresh_refused_count(void)
{
    return (u64) atomic64_read(&cetrafs_layout_refresh_refused);
}

/*
 * Catch up with a grow: re-read the superblock and, if its layout_gen
 * moved, build and publish a layout that knows the new Block Groups.
 *
 * Who calls it: the heartbeat, every tick (one block read, compared and
 * dropped when nothing changed), and any path about to refuse something
 * as beyond the end of the volume it knows -- a peer that grew the
 * volume and then wrote into the new space is not corruption, it is a
 * layout this node has not caught up with.
 *
 * The superblock is read forced-fresh, and retried on a checksum
 * mismatch: the grower writes it with a plain write, and a read can see
 * it torn (rule 3). What is published was checked as a grow of the
 * current layout and walked like a mount walks it; anything short of
 * that keeps the current layout and returns the error -- this node then
 * goes on refusing what lies past its end, which is the safe direction.
 *
 * Returns 1 when a new layout was published, 0 when there was nothing
 * to do, negative on error.
 */
/*
 * Make 'nl' (built on 'cur' and walked) the published layout. Under
 * owned_lock, together with the owned bits of the Block Groups it adds:
 * a Zone Group claim or release derives owned_bgs from the layout it
 * finds under the same lock (cetrafs_sb_owned_bgs_derive()), so
 * whichever runs second sees the other's work. A grow adds Block Groups
 * to the pool, so these are normally unowned -- but a peer may already
 * have claimed one into a Zone Group, and if that Zone Group is ours,
 * so is it. Caller holds layout_mutex.
 */
static void cetrafs_layout_publish(struct super_block *sb, struct cetrafs_bg_layout *cur, struct cetrafs_bg_layout *nl)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u32 b;

    nl->older = cur;
    spin_lock(&sbi->owned_lock);
    for (b = cur->bg_count; b < nl->bg_count; b++) {
        struct cetrafs_bg_chunk *c = nl->chunk[b >> CETRAFS_BGC_SHIFT];
        u32 i = b & CETRAFS_BGC_MASK;
        u16 z = READ_ONCE(c->bg_owner_zg[i]);

        if (z < CETRAFS_MAX_ZONE_GROUPS && test_bit(z, sbi->owned_zgs) &&
            !cetrafs_sb_bg_discard_pending_ignored(sbi, b))
            set_bit(i, c->owned_bgs), set_bit(i, c->release_check);
    }
    if (READ_ONCE(cetrafs_layout_publish_hold_ms)) {
        unsigned int ms = min_t(unsigned int, xchg(&cetrafs_layout_publish_hold_ms, 0), 5000);

        atomic_set(&cetrafs_publish_holding, 1);
        mdelay(ms); /* test-only; see the parameter */
        atomic_set(&cetrafs_publish_holding, 0);
    }
    smp_store_release(&sbi->layout, nl);
    spin_unlock(&sbi->owned_lock);
    atomic64_inc(&cetrafs_layout_refreshes);
    pr_info("%s: layout now %u Block Groups (was %u), %llu blocks (was %llu), layout_gen %llu\n", sb->s_id,
            nl->bg_count, cur->bg_count, (unsigned long long) le64_to_cpu(nl->raw.total_blocks),
            (unsigned long long) le64_to_cpu(cur->raw.total_blocks), (unsigned long long) le64_to_cpu(nl->raw.layout_gen));
}

/*
 * The bounds a grown superblock must keep, beyond what the walk checks
 * Block Group by Block Group (GROWFS-LIVE-REVIEW L1). The mount runs
 * cetrafs_validate_layout() over the whole superblock; a refresh and a
 * live grow adopt a new one too, and checked only the chain. Every
 * address check on the data path (cetrafs_lba_run_check()) trusts
 * bg_data_end and total_blocks, so they are checked before they are
 * published, not after:
 *   - the regions still do not overlap (cetrafs_validate_layout());
 *   - every Block Group ends inside the data box: last_bg_end <=
 *     bg_data_end <= total_blocks;
 *   - the tail reserve lies between the box and the end of the volume.
 * 'nl' has been walked.
 */
static int cetrafs_layout_bounds_check(struct super_block *sb, const struct cetrafs_bg_layout *nl)
{
    const cetrafs_superblock_t *raw = &nl->raw;
    u64 total = le64_to_cpu(raw->total_blocks);
    u64 data_end = le64_to_cpu(raw->bg_data_end);
    u64 ts = le64_to_cpu(raw->tail_reserve_start), tb = le64_to_cpu(raw->tail_reserve_blocks), te;

    if (cetrafs_validate_layout(raw, total))
        return -EUCLEAN;
    if (data_end && (nl->last_bg_end > data_end || data_end > total)) {
        pr_err("%s: layout_gen %llu: data box ends at %llu, but its Block Groups end at %llu and the volume at "
               "%llu\n",
               sb->s_id, (unsigned long long) le64_to_cpu(raw->layout_gen), (unsigned long long) data_end,
               (unsigned long long) nl->last_bg_end, (unsigned long long) total);
        return -EUCLEAN;
    }
    if (ts && (check_add_overflow(ts, tb, &te) || ts < (data_end ? data_end : nl->last_bg_end) || te > total)) {
        pr_err("%s: layout_gen %llu: tail reserve [%llu +%llu) is not between the data area and the end of the "
               "volume (%llu)\n",
               sb->s_id, (unsigned long long) le64_to_cpu(raw->layout_gen), (unsigned long long) ts,
               (unsigned long long) tb, (unsigned long long) total);
        return -EUCLEAN;
    }
    return 0;
}

/* cetrafs_sb_layout_refresh() with layout_mutex held. */
static int cetrafs_layout_refresh_locked(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    struct cetrafs_bg_layout *cur = cetrafs_sb_layout_of(sbi), *nl;
    cetrafs_superblock_t *raw;
    int rc = 0, attempt;

    raw = kmalloc(sizeof(*raw), GFP_KERNEL);
    if (!raw)
        return -ENOMEM;
    for (attempt = 0; attempt < 5; attempt++) {
        struct buffer_head *bh = cetrafs_bread_uncached(sb, CETRAFS_SB_BLOCK_NR);

        if (!bh) {
            rc = -EIO;
            goto out;
        }
        memcpy(raw, bh->b_data, sizeof(*raw));
        brelse(bh);
        if (raw->layout_gen == cur->raw.layout_gen) {
            /* The mark only from a read that verifies: a torn one is
             * re-read on the next beat. */
            if (!cetrafs_check_sb_crc(raw, sizeof(*raw), raw->checksum))
                cetrafs_sb_note_status(sbi, raw);
            rc = 0; /* even after a torn read: what is there now is ours */
            goto up_to_date; /* the common case: nothing moved */
        }
        rc = cetrafs_check_sb_crc(raw, sizeof(*raw), raw->checksum);
        if (rc != -EUCLEAN)
            break;
        usleep_range(1000, 4000); /* a grower's write in flight, seen torn */
    }
    if (rc) {
        pr_err_ratelimited("%s: the superblock's layout_gen moved but it does not verify (%d) -- keeping the "
                           "current layout\n",
                           sb->s_id, rc);
        goto refused;
    }
    if (le32_to_cpu(raw->magic) != CETRAFS_MAGIC || !cetrafs_layout_is_grow_of(&cur->raw, raw)) {
        /* Not torn (the checksum verifies), not ours, not a grow: the
         * volume this node holds is no longer the one on the device --
         * mkfs under a mount, a tool writing block 0 behind every
         * claim. Every further write would land on a layout nobody else
         * has. Kind 3 of docs/internal/ERRORS.md, the state a crash
         * leaves (GROWFS-LIVE-REVIEW L5): it used to log and carry on. */
        cetrafs_sb_fatal(sb, "the superblock changed (layout_gen %llu -> %llu) in a way a grow does not",
                         (unsigned long long) le64_to_cpu(cur->raw.layout_gen),
                         (unsigned long long) le64_to_cpu(raw->layout_gen));
        rc = -EUCLEAN;
        goto refused;
    }
    if (le64_to_cpu(raw->total_blocks) > bdev_nr_bytes(sb->s_bdev) / CETRAFS_BLOCK_SIZE) {
        /* The LUN was resized on the grower's host and not (yet) on
         * ours. Not corruption: retried on the next tick, and every
         * address past our end is "cannot tell" until then
         * (cetrafs_lba_run_check()). Said once per episode. */
        if (!sbi->layout_behind_at)
            pr_warn("%s: the volume grew to %llu blocks but this node's device has %llu -- rescan it; keeping "
                    "the current layout until then, and refusing I/O past it without calling it damage\n",
                    sb->s_id, (unsigned long long) le64_to_cpu(raw->total_blocks),
                    (unsigned long long) (bdev_nr_bytes(sb->s_bdev) / CETRAFS_BLOCK_SIZE));
        WRITE_ONCE(sbi->layout_behind_at, jiffies | 1);
        rc = -EAGAIN;
        goto out;
    }

    nl = cetrafs_layout_alloc(raw, cur);
    if (!nl) {
        rc = -ENOMEM;
        goto out;
    }
    rc = cetrafs_layout_walk(sb, nl, cur, NULL);
    if (!rc)
        rc = cetrafs_layout_bounds_check(sb, nl);
    if (!rc && xchg(&cetrafs_layout_refresh_fail_once, false))
        rc = -EUCLEAN; /* test-only; see the parameter */
    if (rc) {
        cetrafs_layout_discard(nl, cur);
        goto refused;
    }
    cetrafs_layout_publish(sb, cur, nl);
    rc = 1;
up_to_date:
    if (sbi->layout_behind_at) {
        pr_info("%s: this node's device now holds the published volume\n", sb->s_id);
        WRITE_ONCE(sbi->layout_behind_at, 0);
    }
    goto out;
refused:
    atomic64_inc(&cetrafs_layout_refresh_refused);
out:
    kfree(raw);
    return rc;
}

int cetrafs_sb_layout_refresh(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;
    unsigned int nofs;
    int rc;

    if (!sbi || !sbi->layout)
        return -EINVAL;
    /* Reached from writeback (get_block's address check): nothing this
     * allocates may recurse into the filesystem for reclaim. */
    nofs = memalloc_nofs_save();
    mutex_lock(&sbi->layout_mutex);
    rc = cetrafs_layout_refresh_locked(sb);
    mutex_unlock(&sbi->layout_mutex);
    memalloc_nofs_restore(nofs);
    return rc;
}

/*
 * The kernel half of a live grow (CETRAFS_IOC_GROW, grow.c): growfs.cetra
 * has written the new Block Groups and their table segment while
 * holding the volume's repair claim, and hands over the superblock that
 * would publish them. Nothing it says is taken on trust: the superblock
 * must be a grow of the layout this node has just caught up with, and
 * the layout it describes is walked and checked exactly as a mount
 * would -- the segment, every new descriptor, every overlap -- BEFORE
 * anything is written. Only then does cetrafs_grow_commit() credit the
 * pool, link the segment and publish the superblock; and only once
 * that has landed does this node switch to the new layout.
 *
 * -ESTALE: the volume is not where growfs found it (someone else grew
 * it, or it was rewritten); nothing was written, run growfs again.
 */
int cetrafs_sb_layout_grow(struct super_block *sb, const cetrafs_superblock_t *nw, const cetrafs_grow_arg_t *claim)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    struct cetrafs_bg_layout *cur, *nl = NULL;
    struct cetrafs_grow_plan plan = {0};
    unsigned int nofs;
    int rc;

    nofs = memalloc_nofs_save();
    mutex_lock(&sbi->layout_mutex);
    rc = cetrafs_layout_refresh_locked(sb);
    if (rc < 0) {
        pr_err("%s: grow refused -- this node cannot bring its own layout up to date (%d)\n", sb->s_id, rc);
        goto out;
    }
    cur = cetrafs_sb_layout_of(sbi);
    rc = -EINVAL;
    if (cetrafs_check_sb_crc(nw, sizeof(*nw), nw->checksum) || le32_to_cpu(nw->magic) != CETRAFS_MAGIC) {
        pr_err("%s: grow refused -- the superblock handed in does not verify\n", sb->s_id);
        goto out;
    }
    if (le64_to_cpu(nw->layout_gen) != le64_to_cpu(cur->raw.layout_gen) + 1 ||
        !cetrafs_layout_is_grow_of(&cur->raw, nw)) {
        pr_err("%s: grow refused -- the volume is no longer the one growfs read (layout_gen %llu, the grow "
               "expects %llu); run it again\n",
               sb->s_id, (unsigned long long) le64_to_cpu(cur->raw.layout_gen),
               (unsigned long long) le64_to_cpu(nw->layout_gen) - 1);
        rc = -ESTALE;
        goto out;
    }
    if (le32_to_cpu(nw->block_group_count) <= cur->bg_count ||
        le64_to_cpu(nw->total_blocks) > bdev_nr_bytes(sb->s_bdev) / CETRAFS_BLOCK_SIZE) {
        pr_err("%s: grow refused -- it adds no Block Group, or this node's device is smaller than %llu blocks\n",
               sb->s_id, (unsigned long long) le64_to_cpu(nw->total_blocks));
        goto out;
    }
    /* Where the new segment is. The superblock links it itself only on
     * a first grow; later grows link it from the old tail and leave the
     * head alone. Either way it sits at the start of the new reserve. */
    plan.new_seg_lba = le64_to_cpu(nw->tail_reserve_start);
    if (!plan.new_seg_lba ||
        (cur->bg_nsegs ? nw->bg_table_next != cur->raw.bg_table_next ||
                             nw->bg_table_first_count != cur->raw.bg_table_first_count
                       : le64_to_cpu(nw->bg_table_next) != plan.new_seg_lba ||
                             le64_to_cpu(nw->bg_table_first_count) != cur->bg_count)) {
        pr_err("%s: grow refused -- its table chain does not append exactly one segment at the new reserve\n",
               sb->s_id);
        goto out;
    }
    plan.cur = &cur->raw;
    plan.nw = nw;
    plan.claim = claim;
    plan.old_count = cur->bg_count;
    plan.new_count = le32_to_cpu(nw->block_group_count);
    plan.nshards = le32_to_cpu(nw->zone_group_count);
    plan.shard_credit = kcalloc(plan.nshards, sizeof(*plan.shard_credit), GFP_KERNEL);
    nl = plan.shard_credit ? cetrafs_layout_alloc(nw, cur) : NULL;
    if (!nl) {
        rc = -ENOMEM;
        goto out;
    }
    rc = cetrafs_layout_walk(sb, nl, cur, &plan);
    if (!rc && cur->bg_nsegs && !plan.tail_lba)
        rc = -EUCLEAN; /* cannot happen: the walk ends short without the override */
    if (!rc)
        rc = cetrafs_layout_bounds_check(sb, nl);
    if (rc) {
        pr_err("%s: grow refused -- the layout it describes does not verify (%d); nothing was written\n", sb->s_id,
               rc);
        goto out;
    }
    rc = cetrafs_grow_commit(sb, &plan);
    if (rc)
        goto out;
    if (xchg(&cetrafs_grow_skip_local_publish, false)) {
        pr_info("%s: grow committed; not switching this node's layout (test)\n", sb->s_id);
        goto out; /* test-only; see the parameter */
    }
    cetrafs_layout_publish(sb, cur, nl);
    nl = NULL;
out:
    if (nl)
        cetrafs_layout_discard(nl, cetrafs_sb_layout_of(sbi));
    kfree(plan.shard_credit);
    mutex_unlock(&sbi->layout_mutex);
    memalloc_nofs_restore(nofs);
    return rc;
}

u64 cetrafs_sb_get_fence_epoch(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? sbi->fence_epoch : 0;
}

void cetrafs_sb_set_fence_epoch(struct super_block *sb, u64 epoch)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi)
        sbi->fence_epoch = epoch;
}

/* This mount's incarnation (cetrafs_node_entry_t.incarnation): what every
 * claim it stamps carries. Set once, at registration. */
void cetrafs_sb_set_incarnation(struct super_block *sb, u32 inc)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi)
        WRITE_ONCE(sbi->incarnation, inc);
}

u32 cetrafs_sb_incarnation(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? READ_ONCE(sbi->incarnation) : 0;
}

struct cetrafs_defrag *cetrafs_sb_get_defrag(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? sbi->defrag : NULL;
}

/* ------ fill_super (mount-time verification) ------ */

/* TEST ONLY, one-shot: hold a mount between its pre-registration gate and
 * its registration, where an offline repairer can claim the volume
 * (tests/kernel/repair_claim_mid_mount.sh). */
static unsigned int cetrafs_mount_register_stall_ms;
cetrafs_test_param(mount_register_stall_ms, cetrafs_mount_register_stall_ms, uint, 0644);
MODULE_PARM_DESC(mount_register_stall_ms, "TEST ONLY: one-shot pause between the mount gate and registration");

/* TEST ONLY, one-shot: hold a mount right after its registration, as a
 * slow claim sweep or recount would (tests/kernel/mount_lease.sh). */
static unsigned int cetrafs_mount_post_register_stall_ms;
cetrafs_test_param(mount_post_register_stall_ms, cetrafs_mount_post_register_stall_ms, uint, 0644);
MODULE_PARM_DESC(mount_post_register_stall_ms, "TEST ONLY: one-shot pause right after the mount registers");

/* TEST ONLY: pretend the kernel runs with this page size, so the
 * refusal below can be reached on the 4 KiB hosts this project has
 * (tests/kernel/page_size_report.sh). 0: the real PAGE_SIZE. */
static unsigned int cetrafs_assume_page_size;
cetrafs_test_param(assume_page_size, cetrafs_assume_page_size, uint, 0644);
MODULE_PARM_DESC(assume_page_size, "TEST ONLY: the page size the mount-time check sees (0 = real)");

int cetrafs_fill_super(struct super_block *sb, struct fs_context *fc)
{
    struct buffer_head *bh = NULL;
    cetrafs_superblock_t *ondisk;
    cetrafs_superblock_t sb_copy;
    u64 dev_bytes, dev_blocks;
    u64 zg_cnt, bg_cnt, bg_regions_start, bg_size_blocks;
    u64 features_incompat;

    pr_debug("fill_super()\n");
    if (fc && fc->fs_private)
        ((struct cetrafs_fc_info *) fc->fs_private)->filled = true;

    /*
     * One page, one block. The code converts between block and page
     * indices in places that are only right when the two are the same
     * size, and the size-extension and punch paths do not handle a block
     * smaller than its folio (no pagecache_isize_extended(); a block-
     * aligned punch that is not folio-aligned). None of it can be tested
     * on the hosts this project runs on, and on a 16K or 64K kernel it
     * would fail silently -- so it is refused, loudly, until it can be.
     */
    {
        unsigned long page = cetrafs_assume_page_size ? cetrafs_assume_page_size : PAGE_SIZE;

        if (page != CETRAFS_BLOCK_SIZE) {
            pr_err("refusing to mount: this kernel's page size is %lu bytes, and cetrafs supports only "
                   "%u-byte pages (one page per block) -- larger pages are untested and not safe yet\n",
                   page, CETRAFS_BLOCK_SIZE);
            return -EINVAL;
        }
    }

    /* We use fixed 4 KiB on-disk blocks; reject devices that can't do this. */
    if (!sb_set_blocksize(sb, CETRAFS_BLOCK_SIZE)) {
        pr_err("unsupported blocksize on device (need %u)\n", CETRAFS_BLOCK_SIZE);
        return -EINVAL;
    }

    bh = sb_bread(sb, CETRAFS_SB_BLOCK_NR); /* block 0 */
    if (!bh) {
        pr_err("unable to read superblock (block 0)\n");
        return -EIO;
    }

    /*
     * One private copy, taken under the buffer lock, is what every check
     * below validates and every later step reads. Validated in the live
     * buffer and copied afterwards (into raw_sb), the copy was never
     * checked, and the reads after that still went to the buffer --
     * which a forced-fresh re-read, or a peer's growfs, can replace
     * between any two of them (audit 2026-11-06 L14).
     */
    cetrafs_bh_copy_stable(bh, &sb_copy, sizeof(sb_copy));
    ondisk = &sb_copy;

    /* Basic identity checks (LE on disk) */
    if (le32_to_cpu(ondisk->magic) != CETRAFS_MAGIC) {
        if (!(fc->sb_flags & SB_SILENT)) {
            pr_err("bad magic: 0x%08x\n", le32_to_cpu(ondisk->magic));
            cetrafs_sb_copy_hint(sb);
        }
        brelse(bh);
        return -EINVAL;
    }
    {
        u16 v = le16_to_cpu(ondisk->version);

        /* A RANGE, not an equality: CETRAFS_VERSION_MIN (cetrafs.h)
         * keeps volumes from the previous release mountable so they can
         * be grown in place rather than reformatted. Transitional. */
        if (v < CETRAFS_VERSION_MIN || v > CETRAFS_VERSION) {
            pr_err("unsupported version: 0x%04x (this build accepts 0x%04x..0x%04x)\n", v, CETRAFS_VERSION_MIN,
                   CETRAFS_VERSION);
            brelse(bh);
            return -EOPNOTSUPP;
        }
    }
    if (le32_to_cpu(ondisk->block_size) != CETRAFS_BLOCK_SIZE) {
        pr_err("on-disk block size %u != %u\n", le32_to_cpu(ondisk->block_size), CETRAFS_BLOCK_SIZE);
        brelse(bh);
        return -EINVAL;
    }

    /* Device capacity sanity vs on-disk 'total_blocks' */
    dev_bytes = bdev_nr_bytes(sb->s_bdev);
    dev_blocks = div_u64(dev_bytes, CETRAFS_BLOCK_SIZE);
    if (dev_blocks == 0) {
        pr_err("device too small\n");
        brelse(bh);
        return -EINVAL;
    }
    if (le64_to_cpu(ondisk->total_blocks) > dev_blocks) {
        pr_err("SB total_blocks (%llu) > device blocks (%llu)\n",
               (unsigned long long) le64_to_cpu(ondisk->total_blocks), (unsigned long long) dev_blocks);
        brelse(bh);
        return -EINVAL;
    }

    /* CRC32C over the whole struct with checksum field zeroed */
    {
        int rc = cetrafs_check_sb_crc(ondisk, sizeof(*ondisk), ondisk->checksum);
        if (rc) {
            pr_err("superblock CRC32C mismatch\n");
            cetrafs_sb_copy_hint(sb);
            brelse(bh);
            return rc;
        }
    }

    /* Feature flags */
    features_incompat = le64_to_cpu(ondisk->features_incompat);
    if (features_incompat & ~CETRAFS_KNOWN_INCOMPAT) {
        pr_err("unsupported INCOMPAT features set: 0x%llx\n", (unsigned long long) features_incompat);
        brelse(bh);
        return -EOPNOTSUPP;
    }
    if (le64_to_cpu(ondisk->features_ro_compat) & ~CETRAFS_KNOWN_RO_COMPAT) {
        /* A feature this build does not implement but which does not
         * stop it reading the volume: mountable read-only, refused
         * read-write. Enforceable only since read-only became a real
         * mode -- before that "mount it ro" would have been unenforceable advice
         * to do exactly the thing that writes. */
        if (!sb_rdonly(sb)) {
            pr_err("unsupported RO_COMPAT features set: 0x%llx -- mount this volume read-only\n",
                   (unsigned long long) le64_to_cpu(ondisk->features_ro_compat));
            brelse(bh);
            return -EOPNOTSUPP;
        }
        pr_warn("unsupported RO_COMPAT features set: 0x%llx -- mounting read-only\n",
                (unsigned long long) le64_to_cpu(ondisk->features_ro_compat));
    }

    /* Topology sanity */
    zg_cnt = le32_to_cpu(ondisk->zone_group_count);
    bg_cnt = le32_to_cpu(ondisk->block_group_count);
    bg_regions_start = le64_to_cpu(ondisk->bg_regions_start);
    bg_size_blocks = le64_to_cpu(ondisk->bg_size_blocks);

    if (!zg_cnt || zg_cnt > CETRAFS_MAX_ZONE_GROUPS) {
        pr_err("invalid zone_group_count=%llu\n", (unsigned long long) zg_cnt);
        brelse(bh);
        return -EINVAL;
    }
    if (!bg_cnt) {
        pr_err("invalid block_group_count=0\n");
        brelse(bh);
        return -EINVAL;
    }
    if (!bg_size_blocks || bg_size_blocks < 64) {
        pr_err("bg_size_blocks too small: %llu\n", (unsigned long long) bg_size_blocks);
        brelse(bh);
        return -EINVAL;
    }

    /*
     * There used to be a `bg_regions_start >= 1 + Z + B` check here.
     * It encoded the mkfs-time layout -- both descriptor tables sitting
     * in the prefix, immediately below the regions -- as if it were an
     * invariant of the format. It is not: every table's location is a
     * superblock field, and a GROWN volume has relocated its ZG table,
     * BG table and pending-free region into a reserve at the END of the
     * device (docs/internal/EXTENDFS-DESIGN.md). B then outgrows the
     * original prefix and a perfectly valid volume fails to mount: a
     * 64 TiB grow puts 1+Z+B at ~65k blocks, past a 1 TiB volume's
     * bg_regions_start.
     *
     * Nothing is lost by dropping it. cetrafs_validate_layout() below
     * sorts every region and tests them pairwise for overlap, which is
     * strictly stronger than one ordering constraint between two of
     * them -- and unlike this check it holds wherever the tables are.
     */

    /* inode structure sanity */
    if (!le64_to_cpu(ondisk->inode_bmap_blocks) || !le64_to_cpu(ondisk->inode_table_blocks)) {
        pr_err("inode bitmap/table blocks are zero\n");
        brelse(bh);
        return -EINVAL;
    }
    /* The ON-DISK record size, not sizeof(): the in-core struct omits
     * the file sector's zero tail (cetrafs.h), so sizeof() is smaller
     * than what a record occupies on the device. */
    if (le32_to_cpu(ondisk->inode_size) < CETRAFS_INODE_ONDISK_SIZE) {
        pr_err("inode_size %u < expected %u\n", le32_to_cpu(ondisk->inode_size), CETRAFS_INODE_ONDISK_SIZE);
        brelse(bh);
        return -EINVAL;
    }
    /* sb_bytes is documented in the struct as "sizeof(superblock) for
     * sanity" and was checked nowhere. */
    if (le16_to_cpu(ondisk->sb_bytes) != sizeof(cetrafs_superblock_t)) {
        pr_err("sb_bytes %u != sizeof(superblock) %zu\n", le16_to_cpu(ondisk->sb_bytes), sizeof(cetrafs_superblock_t));
        brelse(bh);
        return -EINVAL;
    }
    /* inodes_count bounds every inode LBA (inode.c) and every bitmap
     * scan (alloc.c). One inode record per block since v0x0007, one bit
     * per inode in the bitmap -- both regions must actually be big
     * enough for the count that indexes them. */
    {
        u64 inodes = le32_to_cpu(ondisk->inodes_count);
        u64 bmap_bits = le64_to_cpu(ondisk->inode_bmap_blocks) * CETRAFS_BLOCK_SIZE * 8;

        /* < U32_MAX: the birth map below has inodes_count + 1 bits, and
         * that +1 must not wrap to a zero-size map set_bit() overruns. */
        if (!inodes || inodes >= U32_MAX || inodes > bmap_bits || inodes > le64_to_cpu(ondisk->inode_table_blocks)) {
            pr_err("inodes_count=%llu does not fit its bitmap (%llu bits) / table (%llu blocks)\n",
                   (unsigned long long) inodes, (unsigned long long) bmap_bits,
                   (unsigned long long) le64_to_cpu(ondisk->inode_table_blocks));
            brelse(bh);
            return -EINVAL;
        }
    }
    /* Same for the Node Registry: one row per block, and the row index
     * is what owner_node_id / lock_owner_node store. */
    if (!le32_to_cpu(ondisk->node_table_count) ||
        le32_to_cpu(ondisk->node_table_count) > le64_to_cpu(ondisk->node_table_blocks)) {
        pr_err("node_table_count=%u does not fit node_table_blocks=%llu\n", le32_to_cpu(ondisk->node_table_count),
               (unsigned long long) le64_to_cpu(ondisk->node_table_blocks));
        brelse(bh);
        return -EINVAL;
    }
    if (le32_to_cpu(ondisk->node_entry_size) < sizeof(cetrafs_node_entry_t)) {
        pr_err("node_entry_size %u < expected %zu\n", le32_to_cpu(ondisk->node_entry_size),
               sizeof(cetrafs_node_entry_t));
        brelse(bh);
        return -EINVAL;
    }
    /* A node whose row index is >= CETRAFS_MAX_READER_NODES cannot be
     * represented in cetrafs_inode_t.read_open_nodes -- the presence
     * mask that is the only thing stopping a peer unlinking a file this
     * node is reading. Worse than unrepresentable: the bit
     * is taken modulo the mask width, so row 64 ALIASES row 0. Node 64's
     * read would be mistaken by node 0 for its own, ignored, and the
     * file freed underneath it; node 0's last close would clear node
     * 64's presence. mkfs refuses -M above this, which is where the
     * check has lived -- but the kernel is what the mask protects, and
     * it trusted the formatter. */
    if (le32_to_cpu(ondisk->node_table_count) > CETRAFS_MAX_READER_NODES) {
        pr_err(
            "node_table_count=%u exceeds CETRAFS_MAX_READER_NODES=%u: row indices would alias in the "
            "read-presence mask\n",
            le32_to_cpu(ondisk->node_table_count), CETRAFS_MAX_READER_NODES);
        brelse(bh);
        return -EINVAL;
    }

    /* The whole region map, checked against itself and the device. */
    {
        int rc = cetrafs_validate_layout(ondisk, le64_to_cpu(ondisk->total_blocks));

        if (rc) {
            brelse(bh);
            return rc;
        }
    }
    if (READ_ONCE(cetrafs_sb_scribble_once) && xchg(&cetrafs_sb_scribble_once, false)) {
        /* TEST ONLY: the buffer changed after validation, as a re-read
         * would change it -- left clean, so nothing writes it back. No
         * lock: fill_super is this buffer's only user here, and the
         * buffer protocol keeps lock_buffer() to ioutil.c. */
        ((cetrafs_superblock_t *) bh->b_data)->root_ino = 0;
    }

    /* Allocate private SB info and stash things we need */
    struct cetrafs_sb_info *sbi = NULL;

    {
        sbi = kzalloc(sizeof(*sbi), GFP_KERNEL);
        if (!sbi) {
            brelse(bh);
            return -ENOMEM;
        }
        sbi->block_size = le32_to_cpu(ondisk->block_size);
        sbi->total_blocks = le64_to_cpu(ondisk->total_blocks);
        sbi->zg_count = zg_cnt;
        sbi->bg_size_blocks = bg_size_blocks;
        sbi->bg_regions_start = bg_regions_start;
        /* On unless an operator turns them off -- see the field
         * comments. Never persisted: a switch that survived a remount
         * would be a mount option or an on-disk flag, and this is
         * neither. */
        sbi->defrag_enabled = true;
        sbi->auto_defrag_enabled = true;
        xa_init(&sbi->bad_inos);
        xa_init(&sbi->half_landed);
        xa_init(&sbi->deferred);
        xa_init(&sbi->held);
        xa_init(&sbi->discard_pending);
        INIT_LIST_HEAD(&sbi->deferred_orphans);
        sbi->sb = sb;
        INIT_WORK(&sbi->stop_work, cetrafs_sb_stop_work);
        {
            const struct cetrafs_fc_info *fci = fc ? fc->fs_private : NULL;

            sbi->errors_panic = fci ? fci->errors_panic : false;
            sbi->corruption_stop = fci ? fci->corruption_stop : false;
            sbi->posix_lock_local = fci && fci->posix_lock_local;
            sbi->discard_enabled = !(fci && fci->nodiscard);

            /* The operator's REQUESTED mode. May be overridden below by the
             * cluster's mode (the first mounter leads); the authoritative
             * announcement is emitted there, once the effective mode is
             * known. */
            sbi->file_lock_enabled = fci ? fci->file_lock : true;
            sbi->file_lock_requested = sbi->file_lock_enabled;
        }
        sbi->hb_interval_secs = cetrafs_param_hb_interval_secs();
        sbi->stale_secs = cetrafs_param_stale_secs();

        /* The lasting needs-fsck mark: say it at every mount until fsck
         * clears it. The mount goes ahead -- damage refuses writes where
         * it is found, it does not take the volume down. */
        cetrafs_sb_note_status(sbi, ondisk);
        {
            cetrafs_superblock_t copy;
            int crc = cetrafs_sb_copy_read(sb, &copy);

            sbi->sb_copy_state = crc ? CETRAFS_SB_COPY_BAD
                                 : cetrafs_sb_same_layout(&copy, ondisk) ? CETRAFS_SB_COPY_OK
                                                                         : CETRAFS_SB_COPY_STALE;
            if (sbi->sb_copy_state != CETRAFS_SB_COPY_OK)
                pr_warn("%s: the copy of block 0 at block %llu %s -- fsck.cetra -r rewrites it from block 0\n",
                        sb->s_id, (unsigned long long) CETRAFS_SB_REPLICA_NR,
                        sbi->sb_copy_state == CETRAFS_SB_COPY_BAD ? "does not verify"
                                                                  : "describes a different layout");
        }
        if (sbi->fsck_needed_since)
            pr_err("%s: this volume needs fsck: damaged metadata was found by registry row %u at %llu (unix "
                   "time) -- unmount it on every node and run fsck.cetra -r\n",
                   sb->s_id, sbi->fsck_needed_node, (unsigned long long) sbi->fsck_needed_since);

        /* Per-peer liveness watch (see the struct's own comment). One
         * entry per Node Registry row. Its allocation failing used to be
         * accepted: cetrafs_node_is_stale() then answers "cannot judge,
         * assume alive" for every peer, for the life of the mount -- no
         * dead peer's Zone Groups, locks or journal ever reclaimed, and
         * nothing said why (audit L30). Refused with the rest below. */
        spin_lock_init(&sbi->resv_list_lock);
        spin_lock_init(&sbi->zg_flight_lock);
        spin_lock_init(&sbi->owned_lock);
        mutex_init(&sbi->layout_mutex);
        spin_lock_init(&sbi->nsrel_lock);
        spin_lock_init(&sbi->flrel_lock);
        spin_lock_init(&sbi->prrel_lock);
        spin_lock_init(&sbi->rcrel_lock);
        mutex_init(&sbi->nsrel_mutex);
        mutex_init(&sbi->frees_mutex);
        mutex_init(&sbi->witness_mutex);
        INIT_LIST_HEAD(&sbi->resv_list);

        spin_lock_init(&sbi->peer_lock);
        sbi->peer_count = le32_to_cpu(ondisk->node_table_count);
        if (sbi->peer_count)
            sbi->peers = kcalloc(sbi->peer_count, sizeof(*sbi->peers), GFP_KERNEL);
        mutex_init(&sbi->alloc_mutex);
        mutex_init(&sbi->trim_mutex);
        mutex_init(&sbi->pf_drain_mutex);
        mutex_init(&sbi->zg_claim_mutex);
        init_waitqueue_head(&sbi->zg_claiming_wq);
        init_rwsem(&sbi->release_rwsem);
        atomic_set(&sbi->release_seq, 0);
        mutex_init(&sbi->bmap_flush_mutex);
        atomic_set(&sbi->bmap_flush_inflight, 0);
        atomic_set(&sbi->bmap_dirty_n, 0);
        init_waitqueue_head(&sbi->zg_adopt_wq);
        sbi->stamp_base = (s64) ktime_get_real_ns() - (s64) ktime_get_ns();
        atomic64_set(&sbi->stamp_last, 0);
        init_rwsem(&sbi->birth_rwsem);
        mutex_init(&sbi->cas_mutex);

        sbi->zg_pf_full_until = kcalloc(zg_cnt, sizeof(*sbi->zg_pf_full_until), GFP_KERNEL);
        sbi->zg_pf_drop_runs = kcalloc(zg_cnt, sizeof(*sbi->zg_pf_drop_runs), GFP_KERNEL);
        sbi->zg_pf_drop_blocks = kcalloc(zg_cnt, sizeof(*sbi->zg_pf_drop_blocks), GFP_KERNEL);
        if (!sbi->zg_pf_full_until || !sbi->zg_pf_drop_runs || !sbi->zg_pf_drop_blocks ||
            (sbi->peer_count && !sbi->peers) || cetrafs_fill_fail_peers_alloc) {
            kfree(sbi->zg_pf_drop_blocks);
            kfree(sbi->zg_pf_drop_runs);
            kfree(sbi->zg_pf_full_until);
            kfree(sbi->peers);
            kfree(sbi);
            brelse(bh);
            return -ENOMEM;
        }

        if (cetrafs_alloc_shadow_enabled && sbi->total_blocks <= UINT_MAX)
            sbi->alloc_shadow =
                bitmap_zalloc((unsigned int) sbi->total_blocks, GFP_KERNEL); /* test-only; NULL is fine */
        /* kv-: a volume with millions of inodes asks for a contiguous
         * megabyte, which kmalloc can refuse on a fragmented host -- and
         * a NULL here used to be accepted, silently switching off the
         * birth guard the scrub relies on not to reclaim a file mid-
         * create (cetrafs_sb_birth_active()). */
        sbi->inode_birth = kvcalloc(BITS_TO_LONGS(le32_to_cpu(ondisk->inodes_count) + 1), sizeof(unsigned long),
                                    GFP_KERNEL);
        /* The first layout: the superblock copy every path reads
         * (cetrafs_sb_raw()) and zeroed per-Block-Group state, which the
         * chain walk below fills in place before anything asks for a
         * descriptor address -- the same order the separate arrays
         * this replaces were filled in. Published at once because the
         * copy is needed from here on. */
        sbi->layout = cetrafs_layout_alloc(ondisk, NULL);
        /* Before anything that can free a block runs; drained in
         * cetrafs_free_sb_info() (rule 20). */
        {
            const struct cetrafs_fc_info *fci = fc ? fc->fs_private : NULL;

            sbi->inline_discard = cetrafs_inline_discard_create(sb, fci && fci->inline_discard);
        }
        if (!sbi->layout || !sbi->inode_birth || !sbi->inline_discard) {
            cetrafs_inline_discard_destroy(sbi->inline_discard);
            cetrafs_layout_free_chain(sbi->layout);
            bitmap_free(sbi->alloc_shadow);
            kvfree(sbi->inode_birth);
            kfree(sbi->zg_pf_drop_blocks);
            kfree(sbi->zg_pf_drop_runs);
            kfree(sbi->zg_pf_full_until);
            kfree(sbi->peers);
            kfree(sbi);
            brelse(bh);
            return -ENOMEM;
        }

        sb->s_fs_info = sbi;

        spin_lock_init(&sbi->cold_lock);
        INIT_LIST_HEAD(&sbi->cold_parked);
        mutex_init(&sbi->cold_retry_mutex);
        INIT_DELAYED_WORK(&sbi->resweep_work, cetrafs_sb_resweep_work);
        /* Per-CPU, as before; 7.2 warns at mount when a workqueue names
         * neither WQ_PERCPU nor WQ_UNBOUND. WQ_PERCPU is checked present
         * from 7.0. */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)
        sbi->cold_wq = alloc_workqueue("cetrafs_cold", WQ_MEM_RECLAIM | WQ_PERCPU, 0);
#else
        sbi->cold_wq = alloc_workqueue("cetrafs_cold", WQ_MEM_RECLAIM, 0);
#endif
        if (!sbi->cold_wq) {
            cetrafs_free_sb_info(sb);
            brelse(bh);
            return -ENOMEM;
        }

        /* Probe the device's atomic COMPARE AND WRITE capability once.
         * A device without CAW is still mountable, by one node: every
         * claim then takes the node-local fallback (cetrafs_cas_nocaw())
         * and the mount gate refuses a second node. */
        {
            int rc = cetrafs_caw_discover(sb->s_bdev, &sbi->caw);

            if (rc) {
                /* Refuse the mount rather than guess. A failed probe
                 * leaves caw zeroed, which reads as "no atomic CAW" --
                 * and that is not a safe default on a device that may
                 * well have one: this node would use the no-CAW
                 * fallback, with no cross-node atomicity at all, while a
                 * peer whose probe succeeded uses real compare-and-swap
                 * and believes the volume is protected. Both nodes then
                 * write the same records under incompatible exclusion.
                 *
                 * "Could not determine" is a reason to stop, not a
                 * reason to assume the weaker model. (The old code
                 * warned and carried on, with a message that still
                 * claimed coordination fell back to the PR mutex --
                 * deleted in v0x000E.) */
                pr_err(
                    "CAW discovery failed (%d) -- refusing the mount rather than "
                    "silently assuming this device has no atomic CAW\n",
                    rc);
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return rc;
            }
            pr_info("CAW: class=%s logical_block_size=%u max_caw_blocks=%u -> atomic CAS %s\n",
                    cetrafs_caw_class_name(sbi->caw.klass), sbi->caw.logical_block_size, sbi->caw.max_caw_blocks,
                    cetrafs_sb_caw_available(sb) ? "available" : "unavailable");
        }

        /* No-CAW mount gate, asked BEFORE this node writes ANYTHING.
         *
         * A device with no atomic CAW has no cross-node mutual exclusion,
         * so it may be mounted by exactly one node at a time. Read the Node
         * Registry and refuse if a live FOREIGN node is already mounted --
         * WITHOUT registering, so a node that will be refused never touches
         * the shared registry. The invariant a no-CAW volume rests on is
         * "only one node ever writes to it"; that has to hold from the first
         * write, which means the check comes before registration, not after.
         * (It used to run after cetrafs_node_register(), which left a
         * phantom row visible on the live peer for a full stale window
         * before the refusal, and -- worse with concurrent mounters --
         * raced a free-row claim with no primitive to arbitrate it.)
         *
         * "Self" is excluded by UUID: pre-registration we have no row index.
         * A CAW-capable device skips this -- coexistence is its normal case. */
        /* This node's UUID, resolved once: the no-CAW gate and the cluster
         * file-lock-mode inheritance both need it, both before registration. */
        {
            u8 my_uuid[CETRAFS_NODE_UUID_LEN];
            int rc = cetrafs_node_my_uuid(my_uuid);

            if (rc) {
                pr_err("mount: cannot determine this node's UUID: %d\n", rc);
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return rc;
            }

            /* An offline repairer -- fsck -r, growfs -- rewrites the
             * structures this mount is about to allocate out of. It
             * holds a registry row for the duration; refusing while
             * that row is alive is the other half of those tools
             * refusing to run against a mounted volume. Checked before
             * the CAW question, because it applies on every device. */
            {
                bool repairing = false;
                char who[CETRAFS_NODE_LABEL_LEN] = {0};

                rc = cetrafs_node_repair_claim_exists(sb, &repairing, who, sizeof(who));
                if (rc) {
                    pr_err("mount: cannot read the Node Registry to check for a repair in progress: %d\n", rc);
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return rc;
                }
                if (repairing) {
                    pr_err("%s is being repaired right now (%*pE) -- refusing to mount; wait for it to finish, "
                           "or for its lease to expire if it died\n",
                           sb->s_id, (int) strlen(who[0] ? who : "an offline tool"), who[0] ? who : "an offline tool");
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return -EBUSY;
                }
            }

            if (cetrafs_sb_mount_has_caw(sb)) {
                /* The other order: WE have CAW, and a live peer may be
                 * running the no-CAW fallback, which refused nobody when
                 * it mounted alone. See cetrafs_node_nocaw_peer_exists(). */
                bool nocaw = false;

                rc = cetrafs_node_nocaw_peer_exists(sb, my_uuid, &nocaw);
                if (rc || nocaw) {
                    if (nocaw)
                        pr_err("a live node runs this volume without atomic CAW -- refusing to mount "
                               "(no registry row claimed); unmount it first\n");
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return rc ? rc : -EBUSY;
                }
            }

            if (!cetrafs_sb_mount_has_caw(sb)) {
                bool foreign = false;

                rc = cetrafs_node_live_peer_exists(sb, my_uuid, &foreign);
                if (rc) {
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return rc;
                }
                if (foreign) {
                    pr_err(
                        "device has no atomic CAW and another node is already mounted on it "
                        "-- refusing to mount (no registry row claimed)\n");
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return -EBUSY;
                }
            }

            /* Cluster file-lock mode: the FIRST mounter leads, every node
             * after it INHERITS that mode (ignoring its own default), so a
             * mixed on/off cluster -- which has no coherent cross-node
             * locking and silently corrupts -- cannot form. A node that
             * EXPLICITLY asked for the opposite (-o nofilelock against a
             * lock-on cluster) is refused rather than silently overridden. */
            {
                u32 cluster_mode = CETRAFS_FLOCK_MODE_UNSET;
                bool local_off = !sbi->file_lock_enabled; /* operator passed nofilelock */

                rc = cetrafs_node_cluster_file_lock_mode(
                    sb, my_uuid, local_off ? CETRAFS_FLOCK_MODE_OFF : CETRAFS_FLOCK_MODE_ON, &cluster_mode);
                if (rc) {
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return rc;
                }
                if (cluster_mode != CETRAFS_FLOCK_MODE_UNSET) {
                    bool cluster_off = (cluster_mode == CETRAFS_FLOCK_MODE_OFF);

                    if (local_off && !cluster_off) {
                        pr_err(
                            "mount: -o nofilelock conflicts with this cluster -- the first "
                            "mounter established the file lock ON, and a mixed cluster has no "
                            "coherent cross-node locking. Refusing. Unmount every node to "
                            "change the mode, or drop nofilelock to inherit it.\n");
                        cetrafs_free_sb_info(sb);
                        brelse(bh);
                        return -EINVAL;
                    }
                    if (cluster_off != local_off)
                        pr_info(
                            "mount: inheriting file_lock=%s from the cluster (set by the "
                            "first mounter), overriding this node's default\n",
                            cluster_off ? "off" : "on");
                    sbi->file_lock_enabled = !cluster_off;
                } else if (sb_rdonly(sb) && !READ_ONCE(cetrafs_ro_mount_leads)) {
                    pr_info("mount: no live peer -- read-only, so this node sets no mode for the cluster "
                            "(file_lock=%s here)\n",
                            sbi->file_lock_enabled ? "on" : "off");
                } else {
                    pr_info(
                        "mount: no live peer -- this node leads the cluster with "
                        "file_lock=%s\n",
                        sbi->file_lock_enabled ? "on" : "off");
                }

                if (!sbi->file_lock_enabled)
                    pr_info(
                        "file lock OFF (nofilelock): this node claims no exclusive open "
                        "lock and refuses no open -- the upper layer must prevent "
                        "concurrent writers. Defragmentation is off too.\n");
            }
        }

        /* Seed the in-memory free-inode cache via one bitmap scan; from
         * here on alloc.c keeps it in sync incrementally. */
        {
            u64 seeded = 0;
            int rc = cetrafs_count_free_inodes(sb, &seeded);

            atomic64_set(&sbi->free_inodes, (s64) seeded);
            if (rc) {
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return rc;
            }
        }

        /* Capacity, the descriptor address map and every Block Group's
         * owner, from one walk of the table chain -- the same walk a live
         * layout refresh runs over the Block Groups a grow added. */
        {
            int rc = cetrafs_layout_walk(sb, sbi->layout, NULL, NULL);

            if (rc) {
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return rc;
            }
        }

        /* an earlier phase: allocate this mount's journal state. It
         * stays detached (every log call a silent no-op) until
         * cetrafs_journal_attach_node() binds it to our Node Registry
         * row below -- journals are per-node. */
        {
            int rc = cetrafs_journal_init(sb, &sbi->journal);
            if (rc) {
                pr_err("journal init failed: %d\n", rc);
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return rc;
            }
        }

        if (cetrafs_mount_register_stall_ms) /* TEST ONLY, one-shot */
            msleep(xchg(&cetrafs_mount_register_stall_ms, 0));

        /* A device that cannot be written cannot carry this node's
         * membership: registering, the heartbeat and recovery all write
         * it. ext4 refuses a read-only device that needs recovery the
         * same way ("write access unavailable"). */
        if (bdev_read_only(sb->s_bdev)) {
            pr_err("%s: the device is read-only -- a cetrafs mount, read-only included, writes its registry row, "
                   "heartbeat and recovery to it; refusing\n",
                   sb->s_id);
            cetrafs_free_sb_info(sb);
            brelse(bh);
            return -EACCES;
        }

        /* Find/claim this node's Node Registry row. A read-only mount
         * advertises no mode: an observer follows the cluster's mode and
         * never sets it. Its row said ON, so a first mounter that only
         * looked fixed the mode for every node after it and refused
         * every nofilelock writer (audit 2026-11-15 BM-42). It is safe
         * in either mode itself: it never holds a write, so every cache
         * it trusts is gated on a change stamp or read fresh. */
        {
            u8 node_uuid[CETRAFS_NODE_UUID_LEN];
            u32 adv = sbi->file_lock_enabled ? CETRAFS_FLOCK_MODE_ON : CETRAFS_FLOCK_MODE_OFF;
            int rc;

            if (sb_rdonly(sb) && !READ_ONCE(cetrafs_ro_mount_leads))
                adv = CETRAFS_FLOCK_MODE_UNSET;
            rc = cetrafs_node_register(sb, adv, &sbi->node_id, node_uuid);

            if (rc) {
                pr_err("node registration failed: %d\n", rc);
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return rc;
            }
            sbi->node_registered = true;
            memcpy(sbi->node_uuid, node_uuid, CETRAFS_NODE_UUID_LEN);
            /* Back from a crash: until the sweeps below have run, the
             * previous incarnation's claims and journal are still ours to
             * settle, and a mount failing before then must not announce
             * a clean departure -- the next mount would read it, skip
             * the sweeps, and every claim of that incarnation would read
             * live for good (audit 2026-11-15 BM-16). Cleared once the
             * claim sweep has run. */
            if (cetrafs_sb_unclean_reattach(sb) && !READ_ONCE(cetrafs_mount_unswept_clean))
                sbi->own_area_unsettled = true;
            /* The path identity a wiped block 0 cannot give (dmpath.c, B-15). */
            cetrafs_dmpath_set_anchor(sb->s_bdev, cetrafs_node_row_lba(sb, sbi->node_id) * CETRAFS_BLOCK_SIZE,
                                      node_uuid);
            /* The lease runs from here, not from the heartbeat's first
             * tick. Every mount phase until then -- the claim sweep, the
             * Zone Group claim and recount, the drain -- writes, and can
             * take minutes on a large volume; past the peers' window they
             * reclaim from us while we go on (audit 2026-11-14 F1). From
             * a renewal of its own, timed from just before it: the
             * registration can include a watch of the row minutes long,
             * and a lease counted from before that is already over. The
             * work it arms is drained with sb_info on every failure path
             * below (cetrafs_free_sb_info()). */
            rc = cetrafs_sb_mount_beat(sb);
            if (rc) {
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return rc;
            }
            if (cetrafs_mount_post_register_stall_ms) /* TEST ONLY, one-shot */
                msleep(xchg(&cetrafs_mount_post_register_stall_ms, 0));
            CETRAFS_MOUNT_FAIL_POINT(1);

            /* Post-registration single-mounter re-check (no-CAW only). The
             * gate above ran BEFORE registration -- it must, since a refused
             * node may not write to the volume -- so two nodes mounting at
             * the same instant can each pass it before the other's row
             * exists, and on a device with no atomic CAW nothing arbitrates
             * the two registrations (the row claim degrades to a node-LOCAL
             * mutex). Both would come up writing to a volume with no
             * cross-node mutual exclusion at all. Now that our row is
             * committed a racer is visible: if ANY live foreign row exists,
             * unwind and refuse. Both racers may refuse -- safe, a retry
             * elects a winner -- but no interleaving lets both proceed (see
             * cetrafs_node_single_mounter_conflict()). Sequential mounts
             * never trip this: the gate already refused a live peer. */
            if (cetrafs_sb_mount_has_caw(sb)) {
                /* And the no-CAW peer that registered while we did. */
                bool nocaw = false;
                int crc = cetrafs_node_nocaw_peer_exists(sb, sbi->node_uuid, &nocaw);

                if (crc || nocaw) {
                    if (nocaw)
                        pr_err("mount: a node without atomic CAW registered on this volume while this "
                               "mount was in flight -- refusing; retry once it is gone\n");
                    else
                        pr_err("mount: post-registration CAW-mode re-check failed: %d\n", crc);
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return crc ? crc : -EBUSY;
                }
            }
            if (!cetrafs_sb_mount_has_caw(sb)) {
                bool foreign = false;
                int crc = cetrafs_node_single_mounter_conflict(sb, sbi->node_uuid, &foreign);

                if (crc || foreign) {
                    if (foreign)
                        pr_err(
                            "mount: lost a simultaneous-mount race -- another node registered on "
                            "this no-CAW volume while this mount was in flight, and only one node "
                            "may mount it. Refusing; retry the mount.\n");
                    else
                        pr_err("mount: post-registration single-mounter re-check failed: %d\n", crc);
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return crc ? crc : -EBUSY;
                }
            }

            /* Post-registration repair-claim re-check. The gate above
             * looked for an offline repairer BEFORE registering -- it
             * must, a refused node may not write -- and that check can
             * take seconds of registry and bitmap reads to reach this
             * point. fsck -r or growfs claiming in between saw no
             * registered node (ours did not exist yet) and went ahead;
             * this mount then came up allocating out of the structures
             * the repair was rewriting. Our row is committed now, so a
             * repairer that starts after this sees it and refuses, and
             * one that started before is visible here. */
            {
                bool repairing = false;
                char who[CETRAFS_NODE_LABEL_LEN] = {0};
                int crc = cetrafs_node_repair_claim_exists(sb, &repairing, who, sizeof(who));

                if (crc || repairing) {
                    if (repairing)
                        pr_err("%s: a repair (%*pE) started while this mount was in flight -- refusing to "
                               "mount; wait for it to finish\n",
                               sb->s_id, (int) strlen(who[0] ? who : "an offline tool"), who[0] ? who : "an offline tool");
                    else
                        pr_err("mount: post-registration repair-claim re-check failed: %d\n", crc);
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return crc ? crc : -EBUSY;
                }
            }

            /* Post-registration superblock re-check. mkfs zeroes block 0
             * first, then watches the registry for a live node: a mount
             * that read the old superblock before the zero and registers
             * only after mkfs stopped watching would come up on a volume
             * being formatted under it. Its row is committed now, so a
             * still-watching mkfs sees it; and if block 0 is no longer
             * the superblock this mount validated, nobody is watching
             * any more.
             *
             * One rewrite is legitimate under mounts: a live grow
             * (grow.c), which can publish between our first read and
             * here -- its claim is gone by now, so the check above did
             * not see it. That one is adopted through the same refresh
             * every mounted node runs; anything else is still refused
             * (GROWFS-LIVE-REVIEW L2). */
            {
                const cetrafs_superblock_t *mine = cetrafs_sb_raw(sb);
                struct buffer_head *sbh = cetrafs_bread_uncached(sb, CETRAFS_SB_BLOCK_NR);
                int why = sbh ? 0 : -EIO;

                if (sbh && memcmp(sbh->b_data, mine, sizeof(*mine)) != 0 &&
                    !(!cetrafs_check_sb_crc(sbh->b_data, sizeof(*mine),
                                            ((const cetrafs_superblock_t *) sbh->b_data)->checksum) &&
                      cetrafs_sb_same_layout(mine, (const cetrafs_superblock_t *) sbh->b_data))) {
                    /* Only the needs-fsck mark moving is not a rewrite: a
                     * peer that found damage records it while we mount. */
                    const cetrafs_superblock_t *ns = (const cetrafs_superblock_t *) sbh->b_data;
                    bool grow = !cetrafs_check_sb_crc(ns, sizeof(*ns), ns->checksum) &&
                                le32_to_cpu(ns->magic) == CETRAFS_MAGIC && cetrafs_layout_is_grow_of(mine, ns);

                    why = -EBUSY;
                    if (grow) {
                        int r = cetrafs_sb_layout_refresh(sb);

                        if (r == 1) {
                            pr_info("%s: the volume was grown live while this mount was in flight -- mounting "
                                    "at layout_gen %llu\n",
                                    sb->s_id, (unsigned long long) le64_to_cpu(cetrafs_sb_raw(sb)->layout_gen));
                            why = 0;
                        } else {
                            pr_err("%s: the volume was grown while this mount was in flight, and this node "
                                   "cannot adopt the grow (%d) -- refusing to mount; retry\n",
                                   sb->s_id, r);
                            why = r < 0 ? r : -EBUSY;
                        }
                    } else {
                        pr_err("%s: the superblock was rewritten while this mount was in flight (mkfs?) -- "
                               "refusing to mount\n",
                               sb->s_id);
                    }
                } else if (!sbh) {
                    pr_err("mount: post-registration superblock re-read failed\n");
                }
                brelse(sbh);
                if (why) {
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return why;
                }
            }

            /* Post-registration file-lock-mode re-check. The inherit/refuse
             * decision above read committed rows BEFORE we registered, so a
             * node mounting at the same instant could have been invisible to
             * it (and we to its scan) -- both would then come up as leads
             * with possibly-divergent modes, re-forming the mixed cluster
             * the inherit prevents. Now that our row is committed a racing
             * peer is visible: if any live peer disagrees with the mode we
             * just registered, we lost the race -- unwind and refuse rather
             * than run divergent. (cetrafs_free_sb_info() below releases the
             * row we just claimed, same as every other post-registration
             * unwind.) Sequential mounts never trip this: the joiner already
             * inherited the matching mode. */
            {
                bool conflict = false;
                u32 my_mode = sbi->file_lock_enabled ? CETRAFS_FLOCK_MODE_ON : CETRAFS_FLOCK_MODE_OFF;
                int crc = cetrafs_node_file_lock_mode_conflict(sb, sbi->node_uuid, my_mode, &conflict);

                if (crc || conflict) {
                    if (conflict)
                        pr_err(
                            "mount: lost a simultaneous-mount race -- a live peer runs a "
                            "different file-lock mode than this node registered (file_lock=%s). "
                            "Refusing rather than forming a mixed cluster; retry the mount.\n",
                            sbi->file_lock_enabled ? "on" : "off");
                    else
                        pr_err("mount: post-registration mode re-check failed: %d\n", crc);
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return crc ? crc : -EINVAL;
                }
            }

            /* Say so if this cluster's clocks disagree. Nothing depends
             * on them any more, but file timestamps still come from
             * whichever node wrote them. */
            cetrafs_node_report_clock_skew(sb);

            /* Start every peer's staleness clock now, so a node that
             * died before we mounted becomes reclaimable a window after
             * mount rather than a window after something first asks. */
            cetrafs_node_seed_peer_watch(sb);

            /* The no-CAW mount gate ran BEFORE this registration (a refused
             * node must never claim a row), and the single-mounter re-check
             * just above closes the window the gate cannot see: a peer that
             * registered between the gate's scan and ours. */

            CETRAFS_MOUNT_FAIL_POINT(2);

            /* CAS primitive self-test, opt-in via the
             * cas_selftest module param. Here specifically: after
             * registration (so we own a row) and before the heartbeat
             * starts (so nothing rewrites that row underneath it). */
            cetrafs_cas_selftest(sb, sbi->node_id);

            /* Same window, same reasoning: the concurrent-CAS stress
             * (cas_stress param) races N threads on that same row block,
             * which only means anything before the heartbeat starts
             * rewriting it. */
            cetrafs_cas_stress(sb, sbi->node_id);

            /* Bind the per-node journal to our freshly-registered row
             * and replay our own previous session's crash leftovers --
             * before ZG claiming, before anything can possibly write
             *. A failed own-replay fails the
             * mount: writing on top of unrecovered state is exactly
             * what the journal exists to prevent.
             *
             * A read-only mount does this too, as ext4 and XFS recover
             * their logs on a read-only mount: read-only is what the
             * mount offers its users, not a promise that mounting never
             * writes -- it registers, heartbeats and publishes presence
             * already. It used to skip replay ("an observer must not
             * write"), and with it the claim sweep below, which needs
             * the replay first: a node that crashed and came back
             * read-only re-attached its row and beat, and every claim of
             * its previous incarnation read live for as long as it stayed
             * mounted -- ETXTBSY on that node's files everywhere else.
             *
             * Except where this build cannot vouch for what it would
             * write: an unknown RO_COMPAT feature is mountable read-only
             * precisely because this build must not write the volume, so
             * replaying into it is refused -- with a node that left
             * cleanly there is nothing to replay and it mounts. */
            if (sb_rdonly(sb) && (le64_to_cpu(ondisk->features_ro_compat) & ~CETRAFS_KNOWN_RO_COMPAT) &&
                cetrafs_sb_unclean_reattach(sb)) {
                pr_err("%s: this node went down with work outstanding, and this build does not know every "
                       "feature of the volume (RO_COMPAT 0x%llx), so it cannot recover it -- mount with a build "
                       "that does\n",
                       sb->s_id, (unsigned long long) le64_to_cpu(ondisk->features_ro_compat));
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return -EOPNOTSUPP;
            }
            /* Before replaying anything: a replay claim naming this row
             * is the previous incarnation's, and would read live now. */
            if (cetrafs_sb_unclean_reattach(sb)) {
                rc = cetrafs_journal_sweep_own_claims(sb, sbi->node_id);
                if (rc) {
                    pr_err("could not hand back the replay claims this node held before it went down: %d\n", rc);
                    sbi->own_area_unsettled = true;
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return rc;
                }
            }
            rc = cetrafs_journal_attach_node(sb, sbi->node_id);
            if (rc) {
                pr_err("own journal replay/attach failed: %d\n", rc);
                sbi->own_area_unsettled = true;
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return rc;
            }
            /* After the replay, which repairs what those claims were
             * protecting, and before anything here can open a file. */
            if (cetrafs_sb_unclean_reattach(sb)) {
                rc = cetrafs_lock_sweep_own_claims(sb, sbi->node_id);
                if (rc) {
                    pr_err("could not clear the claims this node held before it went down: %d\n", rc);
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return rc;
                }
                sbi->own_area_unsettled = false; /* replayed and swept: see the registration */
            }
            CETRAFS_MOUNT_FAIL_POINT(3);

            /* Our own journal was
             * already replayed by cetrafs_journal_attach_node() above;
             * a stale previous owner's journal is replayed inside the
             * claim path itself (cetrafs_zg_try_claim_one()'s stale
             * branch) before its ZG is taken, so by the time this
             * returns every ZG this node owns is safe to read/write. */
            /* Both of these are skipped on a read-only mount. Claiming
             * a Zone Group writes its record and, worse, takes write
             * capacity away from the live nodes that need it -- an
             * observer wants none and must take none. Draining a
             * pending-free queue writes a peer's bitmap. */
            if (!sb_rdonly(sb)) {
                rc = cetrafs_zg_claim_unowned(sb, sbi->node_id, node_uuid, /*at_mount=*/true);
                if (rc) {
                    pr_err("ZG claim failed: %d\n", rc);
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return rc;
                }

                /* Apply any frees other nodes queued against ZGs we own
                 * while we were away -- not fatal if it
                 * fails, the heartbeat tick retries every interval. */
                rc = cetrafs_zg_drain_pending_frees(sb, true);
                if (rc)
                    pr_warn("pending-free drain at mount failed (heartbeat will retry): %d\n", rc);
            } else {
                /* ...and an observer gives back what its row still owns
                 * from before (cetrafs_zg_release_all_rdonly()). */
                rc = cetrafs_zg_release_all_rdonly(sb, sbi->node_id);
                if (rc) {
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return rc;
                }
            }
            CETRAFS_MOUNT_FAIL_POINT(4);

            /* an earlier phase: start the periodic heartbeat-renewal /
             * stale-ZG-reclaim tick. If this can't even start (ENOMEM),
             * refuse the mount rather than silently running without it
             * -- this node's own Node Registry row would eventually go
             * stale while it's still alive, letting a peer wrongly
             * reclaim its ZGs/locks out from under it. */
            rc = cetrafs_heartbeat_start(sb, &sbi->hb);
            if (rc) {
                pr_err("failed to start heartbeat: %d\n", rc);
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return rc;
            }
            CETRAFS_MOUNT_FAIL_POINT(5);

            /* an earlier phase: /proc/fs/cetrafs/<device>/{info,
             * properties,cluster} introspection. Everything the three
             * show() functions read (node_id, ZG ownership, journal
             * state) is already established by this point in
             * fill_super() -- not required for a usable mount, but a
             * failure here still isn't swallowed silently, same posture
             * as heartbeat's -ENOMEM above. */
            /* Automatic background defrag. Failure to set
             * it up is logged, not fatal: the filesystem is fully
             * functional without the janitor, and the explicit ioctl
             * path doesn't depend on it. */
            if (!sb_rdonly(sb)) {
                rc = cetrafs_defrag_init(sb, &sbi->defrag);
                if (rc) {
                    pr_warn("auto-defrag unavailable for this mount: %d\n", rc);
                    sbi->defrag = NULL;
                }
                /* Automatic background leaked-block scrub. Writes (frees
                 * blocks), so read-write mounts only; non-fatal on failure
                 * like the defrag janitor. */
                rc = cetrafs_scrub_start(sb, &sbi->scrub);
                if (rc) {
                    pr_warn("background scrub unavailable for this mount: %d\n", rc);
                    sbi->scrub = NULL;
                }
            }
            CETRAFS_MOUNT_FAIL_POINT(6);
        }
    }

    /* Populate VFS super_block */
    sb->s_magic = CETRAFS_MAGIC;
    /* s_maxbytes is the FORMAT ceiling (2^32 blocks), which never moves;
     * the VFS enforces it in setattr_prepare(), generic_write_checks()
     * and vfs_fallocate(). The volume's CAPACITY, which a live grow
     * raises, is enforced by cetrafs_sb_capacity_for() in write_iter,
     * setattr and fallocate instead: the VFS checks s_maxbytes before
     * ->fallocate is called, so a capacity kept there would refuse a
     * node that has not yet adopted a peer's grow with nothing able to
     * catch it up first (class 43). */
    /* noatime, unconditionally: a VM-image datastore gains
     * nothing from access times, and every atime update is a dirtied
     * in-core inode whose eventual VFS writeback blind-writes the raw
     * record with NO cross-node lock held -- the exact "unlocked record
     * writer" class the write_vfs_inode() hardening (inode.c) guards
     * against. Killing atime removes that path's main trigger at the
     * source instead of only catching it downstream. */
    /* PERF(10): reads must not generate inode-record dirt.
     * docs/PERFORMANCE.md */
    sb->s_flags |= SB_NOATIME;

    sb->s_maxbytes = cetrafs_max_file_size_for(U64_MAX);
    /* link() and mkdir() refuse past this (EMLINK). Far below the u32
     * the record stores, so links added by peers at once -- each checked
     * against its own in-core count -- still cannot reach the wrap; the
     * apply saturates as well (cetrafs_ns_apply_delta()). */
    sb->s_max_links = CETRAFS_MAX_LINKS;
    sb->s_op = &cetrafs_super_ops;
    sb->s_xattr = cetrafs_xattr_handlers;
    /* Every dentry (root included, since it's allocated below) must
     * never be trusted across a cross-node mutation -- see dir.c's
     * cetrafs_d_revalidate() for why. This kernel keeps s_d_op behind
     * set_default_d_op() (linux/fs/super_types.h: s_d_op is '__s_d_op',
     * not directly settable), unlike older kernels' plain field. */
    set_default_d_op(sb, &cetrafs_dentry_ops);

    /* Build the root dentry from the real on-disk root inode record. */
    {
        struct inode *rooti = cetrafs_iget(sb, le64_to_cpu(ondisk->root_ino));
        if (IS_ERR(rooti)) {
            pr_err("failed to read root inode: %ld\n", PTR_ERR(rooti));
            cetrafs_free_sb_info(sb);
            brelse(bh);
            return PTR_ERR(rooti);
        }

        /*
         * And it has to BE a directory.
         *
         * d_make_root() on a regular file produces a root dentry the
         * VFS will happily walk into, and every path operation then
         * works against an object whose ops are not a directory's. The
         * record comes off a shared device and nothing else on this
         * path asks the question.
         */
        if (!S_ISDIR(rooti->i_mode)) {
            pr_err("root inode %llu is not a directory (mode 0%o) -- refusing to mount\n",
                   (unsigned long long) le64_to_cpu(ondisk->root_ino), rooti->i_mode);
            iput(rooti);
            cetrafs_free_sb_info(sb);
            brelse(bh);
            return -EUCLEAN;
        }

        /* d_make_root() already does iput(rooti) on failure; don't double it. */
        sb->s_root = d_make_root(rooti);
        if (!sb->s_root) {
            pr_err("failed to make root dentry\n");
            cetrafs_free_sb_info(sb);
            brelse(bh);
            return -ENOMEM;
        }
    }
    CETRAFS_MOUNT_FAIL_POINT(7);

    /* an earlier phase: /proc/fs/cetrafs/<device>/{info,properties,
     * cluster} introspection, published LAST. Its show() functions read
     * live superblock fields -- s_maxbytes among them -- so publishing
     * it mid-construction (where it used to be, before the heartbeat
     * even) let a reader observe a half-built mount: max_file_size_bytes
     * reported the VFS's own default because cetrafs_compute_max_file_
     * size() had not run yet. Nothing may be readable until everything
     * it reads is final. */
    {
        int rc = cetrafs_proc_mount_init(sb, &sbi->proc_mount);

        if (rc) {
            pr_err("failed to create /proc/fs/cetrafs/%s: %d\n", sb->s_id, rc);
            cetrafs_free_sb_info(sb);
            brelse(bh);
            return rc;
        }
    }
    CETRAFS_MOUNT_FAIL_POINT(8);

    /* TEST ONLY (alloc_shadow=1): seed the shadow from the on-disk
     * bitmaps, so a remount mid-test keeps double-alloc detection armed
     * against pre-mount owners instead of restarting blind. */
    cetrafs_shadow_seed(sb);

    /* Last, after every failure point: a re-attach after an unclean
     * departure sweeps its claims once more, after any claim the old
     * incarnation queued past its fence has had time to land
     * (cetrafs_lock_resweep_own_claims()). */
    if (cetrafs_sb_unclean_reattach(sb) && !sb_rdonly(sb) && cetrafs_own_claim_resweep_secs) {
        spin_lock(&sbi->cold_lock);
        if (!sbi->cold_closing)
            queue_delayed_work(sbi->cold_wq, &sbi->resweep_work,
                               (unsigned long) cetrafs_own_claim_resweep_secs * HZ);
        spin_unlock(&sbi->cold_lock);
    }

    /* After every failure point: a live grow that died between its pool
     * credit and its publish left capacity in the pool that no layout
     * has; take it back (grow.c). Not fatal: what is not taken back
     * stays named on the device for the next mount or grow. */
    if (!sb_rdonly(sb)) {
        int hrc = cetrafs_grow_heal_pool(sb);

        if (hrc)
            pr_warn("%s: could not check the pool for a dead grow's credit (%d) -- the next mount or grow will\n",
                    sb->s_id, hrc);
    }

    /* What the device says about UNMAP, once, where an operator looks
     * first. The block layer's limits are the probe: a SCSI disk's come
     * from its Block Limits VPD page, read when the disk was attached. */
    if (cetrafs_discard_supported(sb))
        pr_info("%s: UNMAP supported: up to %u KiB per command, granularity %u KiB; hand-back discard %s\n",
                sb->s_id, (unsigned int) (bdev_max_discard_sectors(sb->s_bdev) >> 1),
                bdev_discard_granularity(sb->s_bdev) >> 10, cetrafs_sb_discard_enabled(sb) ? "on" : "off");
    else
        pr_info("%s: UNMAP not supported by the device: no discard at hand-back or fstrim\n", sb->s_id);

    /*
     * A phase that only logs its own failure may still have stopped the
     * mount on the way (a refused metadata write, an undecidable swap:
     * cetrafs_sb_fatal()), and a lease that ran out latches the same
     * way. Reporting success then handed the caller a mount that fails
     * every I/O with EIO, and dropped the reason it stopped (audit
     * 2026-11-15 BM-20): refuse it, as any other failure here.
     */
    if (READ_ONCE(sbi->fenced) || test_bit(0, &sbi->lease_lost)) {
        if (READ_ONCE(cetrafs_mount_stopped_ok)) {
            pr_warn("%s: TEST mount_stopped_ok -- reporting a stopped mount (%s) as mounted\n", sb->s_id,
                    cetrafs_sb_stop_cause_name(sb));
        } else {
            pr_err("%s: the mount stopped while mounting (%s) -- refusing it\n", sb->s_id,
                   cetrafs_sb_stop_cause_name(sb));
            cetrafs_free_sb_info(sb);
            brelse(bh);
            return -EIO;
        }
    }
    brelse(bh);
    pr_info("mounted OK: Z=%u, B=%u, bg_size=%llu blocks, data@%llu, node_id=%u\n", sbi->zg_count, sbi->layout->bg_count,
            (unsigned long long) sbi->bg_size_blocks, (unsigned long long) sbi->bg_regions_start, sbi->node_id);
    return 0;
}

/* Release the private superblock info allocated in cetrafs_fill_super().
 * Safe to call with sb->s_fs_info already NULL (no-op).
 *
 * Stops the heartbeat tick synchronously before
 * freeing anything else -- cetrafs_heartbeat_stop() tolerates a NULL
 * sbi->hb, true on every failure path through fill_super() that runs
 * before cetrafs_heartbeat_start() is ever reached. super_ops.c's
 * cetrafs_put_super() deliberately calls this *before* syncing/
 * invalidating the backing device, so no tick can race with that.
 *
 * Tears down the /proc/fs/cetrafs/<device>/ introspection directory
 * first, before anything else -- proc_remove() blocks
 * until any reader mid-read against one of its files has finished, so
 * nothing below can be concurrently read out from under its teardown.
 */
/*
 * The soonest any peer may call dead a node whose row advertises
 * 'interval_secs' and 'stale_secs': four of its beats (the interval
 * clamped as every observer clamps it), or its own stale window when
 * that is a legal one. An illegal advertised window -- a corrupt row, or
 * a loop suite's compressed one -- counts for nothing, on both sides.
 *
 * Every observer's window is at least this (cetrafs_sb_peer_progress_stale()),
 * and this node's lease is this less one beat (cetrafs_sb_lease_secs()):
 * one formula for both, so the lease can never outlive the window
 * (audit 2026-11-14 O1, C2).
 */
u32 cetrafs_peer_window_floor_secs(u32 interval_secs, u32 stale_secs)
{
    u32 w = min_t(u32, interval_secs, CETRAFS_HB_INTERVAL_MAX_SECS) * 4;

    if (stale_secs >= CETRAFS_STALE_MIN_SECS && stale_secs <= CETRAFS_STALE_MAX_SECS && stale_secs > w)
        w = stale_secs;
    return w;
}

/* TEST ONLY: count a peer's silence across our own renewal gap -- the
 * behaviour before audit 2026-11-14 O2, the control of
 * tests/kernel/peer_watch_observer_gap.sh. */
static bool cetrafs_peer_watch_no_restart;
cetrafs_test_param(peer_watch_no_restart, cetrafs_peer_watch_no_restart, bool, 0644);
MODULE_PARM_DESC(peer_watch_no_restart, "TEST ONLY: count the observer's own absence as the peer's silence");

/*
 * Whether this node's own heartbeat renewals are overdue -- more than
 * three of its beats since the last one landed -- and when they last
 * resumed after such a gap (0: never). Judged only once the heartbeat
 * runs: a mount phase renews when it can (cetrafs_sb_mount_beat()) and
 * must still be able to judge a peer it is waiting on.
 */
static bool cetrafs_sb_own_renewal_overdue(struct cetrafs_sb_info *sbi, unsigned long now, unsigned long *resumed)
{
    unsigned long ok = READ_ONCE(sbi->renew_ok_at);

    *resumed = READ_ONCE(sbi->renew_resumed_at);
    if (!sbi->hb || !ok)
        return false;
    return time_after(now, ok + (unsigned long) cetrafs_sb_hb_interval_secs(sbi->sb) * 3 * HZ);
}

/* A renewal of this node's row reached the device. */
static void cetrafs_sb_note_renewal(struct cetrafs_sb_info *sbi)
{
    unsigned long now = jiffies, ok = READ_ONCE(sbi->renew_ok_at);

    if (ok && time_after(now, ok + (unsigned long) cetrafs_sb_hb_interval_secs(sbi->sb) * 3 * HZ))
        WRITE_ONCE(sbi->renew_resumed_at, now ? now : 1);
    WRITE_ONCE(sbi->renew_ok_at, now ? now : 1);
}

/*
 * Observe a peer's heartbeat counter and say whether it has stopped
 * advancing for longer than CETRAFS_NODE_STALE_SECS of OUR OWN clock.
 *
 * The only clock involved is this node's jiffies; hb_seq is a plain
 * counter the peer bumps itself. No cross-node timestamp comparison
 * happens anywhere, so clock skew between nodes -- which silently broke
 * every staleness decision in this filesystem previously -- cannot
 * influence the answer.
 *
 * A row we have never sampled is reported ALIVE, and sampled now: with
 * one observation there is nothing to compare against, and the safe
 * direction is to not reclaim. The cost is that a peer which died before
 * we mounted is only declared stale CETRAFS_NODE_STALE_SECS after we
 * first look at it, rather than immediately.
 */
bool cetrafs_sb_peer_progress_stale(struct super_block *sb, u32 node_id, const cetrafs_node_entry_t *ne)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    struct cetrafs_peer_watch *w;
    unsigned long now = jiffies;
    u32 peer_hb_interval = cetrafs_le32(ne->hb_interval_secs);
    bool stale;

    if (!sbi || !sbi->peers || node_id >= sbi->peer_count)
        return false; /* cannot judge -> never reclaim */

    spin_lock(&sbi->peer_lock);
    w = &sbi->peers[node_id];
    /* A new sample whenever the counter moved, another machine holds
     * the row, or the same machine holds it in another mount session
     * (cetrafs_row_mark). The safe direction -- a reset only delays a
     * verdict. A row seen not REGISTERED is forgotten as well
     * (cetrafs_sb_peer_watch_forget()). */
    if (!w->valid || !cetrafs_row_mark_same(&w->mark, ne)) {
        w->valid = true;
        cetrafs_row_mark_of(&w->mark, ne);
        w->seen_at = now;
        stale = false;
    } else {
        /*
         * The window is ours, floored at what the PEER advertises: four
         * of its own beats, and its own stale window when that is a
         * legal one (cetrafs_peer_window_floor_secs()).
         *
         * Our stale_secs says how long WE are willing to wait; it says
         * nothing about how often the other node actually ticks, nor
         * how long its lease runs. A peer running a longer interval
         * than we expect stops looking alive between its beats, and a
         * peer whose lease is sized from its own longer window
         * (cetrafs_sb_lease_renewed()) is still writing when a window
         * of ours would call it dead. The floor makes the decision
         * depend on what the peer published, never on our
         * configuration matching its.
         *
         * Both advertised values are clamped inside the helper: a
         * hostile or corrupt (checksum-valid) row can carry anything,
         * and must neither make the peer un-reclaimable nor overflow.
         */
        unsigned long window = (unsigned long) cetrafs_sb_stale_secs(sb) * HZ;
        unsigned long peer_floor = (unsigned long) cetrafs_peer_window_floor_secs(
                                       peer_hb_interval, cetrafs_le32(ne->stale_secs)) * HZ;

        unsigned long from = w->seen_at;

        if (peer_floor > window)
            window = peer_floor;
        /* Our OWN renewals say whether we could see the device. While
         * ours are overdue the peer's silence may be the same outage,
         * and its renewal queued behind it as ours is: no verdict. Once
         * ours land again the watch counts from then, not from before
         * the outage -- the observer's absence is not the peer's
         * silence (audit 2026-11-14 O2). A restart only delays. */
        if (!READ_ONCE(cetrafs_peer_watch_no_restart)) {
            unsigned long resumed;

            if (cetrafs_sb_own_renewal_overdue(sbi, now, &resumed))
                from = now + window; /* not stale; seen_at untouched */
            else if (resumed && time_after(resumed, from))
                from = resumed;
        }
        stale = time_after(now, from + window);
        if (stale) {
            w->judged_mark = w->mark;
            w->judged = true;
        }
    }
    spin_unlock(&sbi->peer_lock);
    return stale;
}

/*
 * Sample a peer's row into the same watch the stale verdict uses, for a
 * caller that needs "is it beating NOW?" rather than "is it dead?"
 * (cetrafs_node_peer_beating()). Returns true when the row moved since
 * the last sample; *first is set when there was none (no move can be
 * inferred), and *since is when the current mark was first seen -- no
 * earlier than the beat itself, so a silence measured from it is never
 * overstated.
 */
bool cetrafs_sb_peer_sample(struct super_block *sb, u32 node_id, const cetrafs_node_entry_t *ne, bool *first,
                            unsigned long *since)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    struct cetrafs_peer_watch *w;
    bool moved = false;

    *first = true;
    *since = jiffies;
    if (!sbi || !sbi->peers || node_id >= sbi->peer_count)
        return false;
    spin_lock(&sbi->peer_lock);
    w = &sbi->peers[node_id];
    if (!w->valid || !cetrafs_row_mark_same(&w->mark, ne)) {
        *first = !w->valid;
        moved = w->valid;
        w->valid = true;
        cetrafs_row_mark_of(&w->mark, ne);
        w->seen_at = jiffies;
    } else {
        *first = false;
    }
    *since = w->seen_at;
    spin_unlock(&sbi->peer_lock);
    return moved;
}

/* The row is not REGISTERED: whatever we sampled was a previous
 * incarnation, and the next one starts a new watch. */
void cetrafs_sb_peer_watch_forget(struct super_block *sb, u32 node_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || !sbi->peers || node_id >= sbi->peer_count)
        return;
    spin_lock(&sbi->peer_lock);
    sbi->peers[node_id].valid = false;
    spin_unlock(&sbi->peer_lock);
}

/* The mark of the last stale verdict on a peer's row, or false if it
 * was never judged stale by progress. For the fence (node.c), which must
 * refuse to act on a verdict about a holder that has since re-attached
 * or re-registered. The judged value, not the last sample: a tick
 * between the verdict and the fence re-samples the moved row, and
 * comparing against that let the fence through (fence_vs_reattach.sh). */
bool cetrafs_sb_peer_judged_mark(struct super_block *sb, u32 node_id, struct cetrafs_row_mark *out)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool valid = false;

    if (!sbi || !sbi->peers || node_id >= sbi->peer_count)
        return false;
    spin_lock(&sbi->peer_lock);
    if (sbi->peers[node_id].judged) {
        *out = sbi->peers[node_id].judged_mark;
        valid = true;
    }
    spin_unlock(&sbi->peer_lock);
    return valid;
}

/* Record / fetch the mark a fence of this peer's row landed on. */
void cetrafs_sb_peer_note_fenced(struct super_block *sb, u32 node_id, const struct cetrafs_row_mark *m)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || !sbi->peers || node_id >= sbi->peer_count)
        return;
    spin_lock(&sbi->peer_lock);
    sbi->peers[node_id].fenced_mark = *m;
    sbi->peers[node_id].fenced = true;
    spin_unlock(&sbi->peer_lock);
}

bool cetrafs_sb_peer_fenced_mark(struct super_block *sb, u32 node_id, struct cetrafs_row_mark *out)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool valid = false;

    if (!sbi || !sbi->peers || node_id >= sbi->peer_count)
        return false;
    spin_lock(&sbi->peer_lock);
    if (sbi->peers[node_id].fenced) {
        *out = sbi->peers[node_id].fenced_mark;
        valid = true;
    }
    spin_unlock(&sbi->peer_lock);
    return valid;
}

/* TEST ONLY: unmount's flush of held-back extent-tree blocks reports
 * -EIO after it ran (tests/kernel/umount_flush_err_kept.sh). */
static bool cetrafs_umount_tree_flush_fail;
cetrafs_test_param(umount_tree_flush_fail, cetrafs_umount_tree_flush_fail, bool, 0644);
MODULE_PARM_DESC(umount_tree_flush_fail, "TEST ONLY: unmount's extent-tree flush reports -EIO");

bool cetrafs_free_sb_info(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    int flush_err = 0, r;
    u32 unreleased;
    bool stopped = false, left_stopped;

    if (!sbi)
        return false;

    /* First, while everything below is still standing: a reconcile still
     * queued (a failed mount never ran kill_sb's flush) may hold the last
     * reference to an inode, and its iput() can evict it. */
    cetrafs_sb_cold_close(sb);
    if (sbi->cold_wq) {
        destroy_workqueue(sbi->cold_wq);
        sbi->cold_wq = NULL;
    }

    /* A reader mid-sweep stops at its next read: proc_remove() waits
     * for it (audit 2026-11-15 BM-52). */
    WRITE_ONCE(sbi->proc_closing, true);
    cetrafs_proc_mount_exit(sbi->proc_mount);
    /* Stop the heartbeat *before* doing any of our own final flush work
     * below, not after: heartbeat.c's periodic tick calls zonegroup.c's
     * cetrafs_zg_claim_unowned() every CETRAFS_HEARTBEAT_INTERVAL_SECS,
     * which takes the same cluster mutex the journal/BG flush below also
     * needs. With heartbeat_stop() running last (the old order), a real
     * two-node unmount showed ticks still firing -- and taking the
     * mutex -- for 40+ seconds *after* put_super() had already started,
     * because the flush below kept contending with the next tick's own
     * claim scan for the same mutex, over and over. cancel_delayed_
     * work_sync() guarantees no further tick can run once this returns,
     * so moving it first makes the flush below run uncontended. */
    /* Drain background defrag FIRST: its worker uses the journal, the
     * cluster mutex, and this node's registration -- all torn down
     * below. destroy_workqueue() inside flushes queued+running work;
     * the draining flag makes an in-flight incremental move stop at its
     * next chunk boundary rather than stalling the unmount. */
    WRITE_ONCE(sbi->defrag_draining, true);
    cetrafs_defrag_stop(sbi->defrag);
    sbi->defrag = NULL;

    /* Stop the background scrub before the alloc/ownership state it reads
     * and the device are torn down; its draining flag makes an in-flight
     * cycle bail at its next inode/block boundary rather than stall. */
    cetrafs_scrub_stop(sbi->scrub);
    sbi->scrub = NULL;

    /* Unpublish the heartbeat before it is freed: cetrafs_heartbeat_stop()
     * frees it, and sbi->hb must not name the freed object afterwards.
     * The readers (cetrafs_sb_zg_adopt_wait, cetrafs_sb_has_heartbeat)
     * load it with READ_ONCE and treat NULL as "no heartbeat" (audit F2). */
    {
        struct cetrafs_heartbeat *hb = sbi->hb;

        WRITE_ONCE(sbi->hb, NULL);
        cetrafs_heartbeat_stop(hb);
    }
    /* The inline-discard worker claims through the allocator and reads
     * the layout, both torn down below; the frees that feed it came from
     * the evictions, the scrub, defrag and the heartbeat's queue drain,
     * all finished by now. Nothing queues after this (rule 20). */
    cetrafs_inline_discard_close(sbi->inline_discard);
    /*
     * A stopped mount -- fenced, its lease lost, a fatal error -- writes
     * NOTHING on the way out (docs/internal/ERRORS.md). The journal park
     * below dirtied the header block, its own sync was refused under the
     * fence and left it dirty, and the two sync_blockdev()s then wrote it
     * anyway: a blind whole-block write of this node's journal header as
     * CLEAN, after a peer may have claimed the area and be replaying it.
     * Anything else dirtied after the stop sweep went out the same way
     * (audit 2026-11-06 M1; tests/kernel/stopped_unmount_writes_nothing.sh).
     * Drop it instead, as the stop sweep does.
     */
    stopped = cetrafs_sb_is_fenced(sb);
    if (stopped) {
        cancel_work_sync(&sbi->stop_work); /* its sweep, finished; ours covers what came after */
        if (sb->s_bdev) {
            unsigned long n = cetrafs_drop_dirty_metadata(sb) + cetrafs_deferred_drop_all(sb) + cetrafs_held_drop_all(sb);

            if (n)
                pr_err("%s: unmount of a stopped mount: discarded %lu dirty metadata buffer(s) without "
                       "writing them\n",
                       sb->s_id, n);
        }
        flush_err = -EIO;
        goto departed;
    }
    /* Tree blocks still held back -- a mapping written through after
     * the last close, a boundary that failed -- go through the journal
     * while it is still attached. */
    r = cetrafs_deferred_flush_all(sb);
    if (!r && READ_ONCE(cetrafs_umount_tree_flush_fail))
        r = -EIO; /* TEST ONLY: see the knob */
    if (r) {
        pr_err("%s: unmount: deferred extent-tree blocks could not be written (%d)\n", sb->s_id, r);
        flush_err = r;
    }
    /* Park the journal flag and push the accrued free-space counters
     * out BEFORE announcing the departure below. See the sync there.
     * Not over a failed tree flush: entries of ours may be all that
     * holds those blocks, and a clean flag says there is nothing to
     * replay (audit 2026-11-14 A-9). */
    if (!flush_err)
        cetrafs_journal_shutdown(sb);
    else
        pr_err("%s: unmount: journal left dirty for replay after the failed flush\n", sb->s_id);
    /* Allocation bits first, then the counters that summarise them --
     * the same order as sync_fs. sync_fs already ran in
     * generic_shutdown_super(), but the VFS ignores its result there, so
     * this is the only place a failure can still change anything. */
    /* Kept, never overwritten: a failed tree flush above followed by a
     * bitmap flush with nothing to do used to read as a clean departure
     * (audit 2026-11-14 A-9; tests/kernel/umount_flush_err_kept.sh). */
    r = cetrafs_alloc_flush_bitmaps(sb);
    if (r && !flush_err)
        flush_err = r;
    r = cetrafs_held_flush(sb); /* the frees still held: unmarked, so not in the flush above */
    if (r && !flush_err)
        flush_err = r;
    r = cetrafs_flush_dirty_free_counts(sb);
    if (r && !flush_err)
        flush_err = r;
    /* Everything this node had to say must be ON THE DEVICE before it
     * says it is gone.
     *
     * mark_offline makes our row immediately reclaimable: a peer can
     * steal our Zone Groups and start allocating out of them the moment
     * it lands. Anything of ours still sitting dirty at that point --
     * and put_super's own sync_blockdev() used to run *after* this --
     * is a write aimed at blocks somebody else now owns. The order was
     * announce, then flush; it is flush, then announce.
     *
     * Not reproducible on one kernel (the peer is the other half), so
     * this is reasoned rather than measured -- ctest owns the proof. */
    /* Stopped DURING the flushes above -- a lease that ran out in a
     * slow bitmap write: what they were refused is still dirty, and the
     * sync below would write it after peers took over (audit 2026-11-15
     * B-30). Asked again here, last; dropped as the stop branch drops. */
    if (cetrafs_sb_is_fenced(sb) && !READ_ONCE(cetrafs_sync_regate_off)) {
        if (sb->s_bdev)
            (void) (cetrafs_drop_dirty_metadata(sb) + cetrafs_deferred_drop_all(sb) + cetrafs_held_drop_all(sb));
        flush_err = -EIO;
        stopped = true;
        goto departed;
    }
    if (sb->s_bdev) {
        r = sync_blockdev(sb->s_bdev);
        if (r && !flush_err)
            flush_err = r;
        /* ...and out of the device's write cache: "on the device" for a
         * peer means durable, and a volatile cache keeps what a power cut
         * loses. sync_fs flushed already; this covers what put_super
         * itself wrote since (the journal park, the free counts). */
        r = blkdev_issue_flush(sb->s_bdev);
        if (r && !flush_err)
            flush_err = r;
    }
departed:
    /* Signal this node's deliberate departure on the way out -- clean
     * unmount (or a later-failing mount attempt after registration
     * already succeeded) used to leave this node's row looking exactly
     * like a merely-slow one, so a peer couldn't reclaim its ZGs/locks
     * until the full stale timeout elapsed even though this node is
     * definitively gone. See node.c's cetrafs_node_mark_offline() for
     * why this records the departure rather than freeing the row outright
     * (freeing it would break this node's own re-attach on its next
     * mount). Must run after heartbeat_stop() above (a concurrent tick
     * could otherwise re-renew this row via cetrafs_node_renew_
     * heartbeat() right after we record it) and is guarded by
     * node_registered since sbi->node_id alone can't tell a never-
     * registered mount attempt apart from a real claim on row 0. Logged
     * on failure, not treated as fatal: cetrafs_put_super()'s caller
     * (generic_shutdown_super()) has no way to fail unmount over this,
     * and leaving the row to time out via the ordinary stale path is
     * still safe, just slower. */
    /* Claims still queued for the heartbeat's retry -- a namespace or
     * file lock, a presence bit, an inode-number claim, a peer's replay
     * claim -- are on the device under our id, and the heartbeat that
     * would have released them has stopped. A departure announced over
     * them tells the next mount of this node that there is nothing of
     * its previous life to sweep (the row's departure reads
     * CETRAFS_NODE_DEPART_CLEAN), and the claims read live again the
     * moment it beats. Left unannounced, the row goes stale: peers
     * reclaim them as a dead node's, and the next mount sweeps whatever
     * is left. */
    /* A mount refused over an unreplayed own area announces nothing: a
     * clean departure lets peers take the row's Zone Groups at once and
     * skip what a crashed node's sweep would do, and the next mount of
     * this node its own-claim sweeps -- over entries never replayed. */
    if (sbi->own_area_unsettled && !flush_err) {
        pr_err("%s: own journal area or claims left unsettled -- not announcing a clean departure\n", sb->s_id);
        flush_err = -EIO;
    }
    unreleased = READ_ONCE(sbi->nsrel_count) + READ_ONCE(sbi->flrel_count) + READ_ONCE(sbi->prrel_count) +
                 READ_ONCE(sbi->rcrel_count) + (cetrafs_journal_release_pending(sb) ? 1 : 0);
    if (sbi->node_registered && !READ_ONCE(sbi->fenced) && !flush_err && unreleased) {
        pr_err("unmount: %u claim release(s) still queued -- not announcing a clean departure; row %u will go "
               "stale and the next mount sweeps them\n",
               unreleased, sbi->node_id);
    } else if (sbi->node_registered && !READ_ONCE(sbi->fenced) && flush_err) {
        /* Something of ours did not reach the device, so this is not a
         * clean departure and must not be announced as one: a peer
         * would take our Zone Groups at once, reconciling from bitmaps
         * that miss our allocations. Left un-announced, the row goes
         * stale and peers reclaim it as a crashed node's -- fenced,
         * journal replayed -- which is what it is. */
        pr_err("unmount: final flush failed (%d) -- not announcing a clean departure; row %u will go stale and "
               "be reclaimed as a crashed node's\n",
               flush_err, sbi->node_id);
    } else if (sbi->node_registered && !READ_ONCE(sbi->fenced)) {
        /* A fenced node writes NOTHING, its own row included -- peers
         * already treat it as dead, and the row is already stale from
         * the stopped heartbeat that got it fenced in the first place. */
        int rc = cetrafs_node_mark_offline(sb, sbi->node_id);
        if (rc)
            pr_err("node mark-offline failed (row %u will time out instead): %d\n", sbi->node_id, rc);
    }
    /* Park this node's own per-node journal flag at CLEAN (every entry
     * was already consumed inside its own operation, so there's nothing
     * to flush -- this just spares the next mount the slot scan). */
    cetrafs_journal_free(sbi->journal);
    cetrafs_dmpath_forget(sb->s_bdev); /* stop holding a path device open */
    /* The lease stays armed through the final flushes above -- the
     * heartbeat stopped first, so they are exactly the writes it must
     * bound. Disarm it only now, then wait out a fence it may have
     * queued: nothing can queue another once lease_active is false. */
    if (sbi->lease_work_ready) {
        WRITE_ONCE(sbi->lease_active, false);
        smp_mb();
        cancel_work_sync(&sbi->lease_work);
    }
    cancel_work_sync(&sbi->stop_work);
    {
        /* Nothing may stay pinned past the mount (rule 20): whatever a
         * failed flush left is released, unwritten. */
        unsigned long n = cetrafs_deferred_drop_all(sb);

        if (n)
            pr_err("%s: released %lu extent-tree block(s) that never reached the device\n", sb->s_id, n);
        /* Held bitmap blocks likewise: a clean unmount flushed them
         * (cetrafs_alloc_flush_bitmaps() + cetrafs_held_flush()); this
         * only gives the pins back -- and drops what a stopped mount or
         * a failed flush still holds. */
        n = cetrafs_held_drop_all(sb);
        if (n)
            pr_err("%s: released %lu allocation-bitmap block(s) that never reached the device\n", sb->s_id, n);
    }
    xa_destroy(&sbi->deferred);
    xa_destroy(&sbi->held);
    xa_destroy(&sbi->bad_inos);
    xa_destroy(&sbi->half_landed);
    xa_destroy(&sbi->discard_pending);
    cetrafs_inline_discard_destroy(sbi->inline_discard); /* closed above; a late free found it closed */
    sbi->inline_discard = NULL;
    /* Last: every work item that could read the layout is drained above
     * (rule 20). The raw copy used to be freed before lease_work and
     * stop_work were cancelled. */
    cetrafs_layout_free_chain(sbi->layout);
    sbi->layout = NULL;
    bitmap_free(sbi->alloc_shadow);
    kvfree(sbi->inode_birth);
    kfree(sbi->zg_pf_drop_blocks);
    kfree(sbi->zg_pf_drop_runs);
    kfree(sbi->zg_pf_full_until);
    kfree(sbi->peers);
    kfree(sbi->row_silent);
    bitmap_free(sbi->row_silent_valid);
    left_stopped = stopped || READ_ONCE(sbi->fenced) || test_bit(0, &sbi->lease_lost);
    kfree(sbi);
    sb->s_fs_info = NULL;
    return left_stopped;
}

/* Pending-free backoff state, for zonegroup.c. See the field comments
 * on zg_pf_full_until above.
 *
 * All three are advisory hints on a path that already leaks on failure:
 * a lost update makes this node scan once more than it needed to, or
 * log one extra line. Not worth a lock on a path whose whole purpose is
 * to stop doing expensive things.
 */
bool cetrafs_sb_zg_pf_backoff_active(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    unsigned long until;

    if (!sbi || !sbi->zg_pf_full_until || zg_id >= sbi->zg_count)
        return false;
    until = READ_ONCE(sbi->zg_pf_full_until[zg_id]);
    return until && time_before(jiffies, until);
}

/* Record dropped runs (extents) and their blocks. Returns true the FIRST
 * time in a burst, which is when the caller does the expensive diagnostic. */
bool cetrafs_sb_zg_pf_note_drop(struct super_block *sb, u32 zg_id, u32 runs, u64 blocks, unsigned int backoff_ms)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool first;

    if (!sbi || !sbi->zg_pf_full_until || zg_id >= sbi->zg_count)
        return true;

    first = !cetrafs_sb_zg_pf_backoff_active(sb, zg_id);
    if (first) {
        WRITE_ONCE(sbi->zg_pf_drop_runs[zg_id], 0);
        WRITE_ONCE(sbi->zg_pf_drop_blocks[zg_id], 0);
    }
    WRITE_ONCE(sbi->zg_pf_drop_runs[zg_id], READ_ONCE(sbi->zg_pf_drop_runs[zg_id]) + runs);
    WRITE_ONCE(sbi->zg_pf_drop_blocks[zg_id], READ_ONCE(sbi->zg_pf_drop_blocks[zg_id]) + blocks);
    /* 0 means "do not remember at all" -- the negative control. Setting
     * jiffies+1 instead would still suppress every scan inside the same
     * tick, which is most of a burst, and the control would measure
     * nothing. */
    WRITE_ONCE(sbi->zg_pf_full_until[zg_id], backoff_ms ? jiffies + msecs_to_jiffies(backoff_ms) + 1 : 0);
    return first;
}

/* End a burst: report what was dropped and clear it. Returns false if
 * there was nothing to report. */
bool cetrafs_sb_zg_pf_take_drops(struct super_block *sb, u32 zg_id, u64 *runs, u64 *blocks)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || !sbi->zg_pf_full_until || zg_id >= sbi->zg_count)
        return false;
    *runs = READ_ONCE(sbi->zg_pf_drop_runs[zg_id]);
    *blocks = READ_ONCE(sbi->zg_pf_drop_blocks[zg_id]);
    if (!*runs)
        return false;
    WRITE_ONCE(sbi->zg_pf_drop_runs[zg_id], 0);
    WRITE_ONCE(sbi->zg_pf_drop_blocks[zg_id], 0);
    WRITE_ONCE(sbi->zg_pf_full_until[zg_id], 0);
    return true;
}

/* Exposes the exact on-disk superblock image to other files (inode.c) that
 * need its layout fields, without exposing the private cetrafs_sb_info
 * struct itself. */
/*
 * cetrafs_lba_run_is_data() found the run past the end of the layout
 * this node has. That is corruption only if the layout is current, so
 * catch up first: a grow publishes its superblock before any node can
 * allocate in the new space, so a reference into it is never visible
 * before the superblock that makes it legal (rule 8's order, which the
 * grow keeps). Then judge again against what was published. Each
 * recursion follows a refresh that published, so it ends.
 *
 * Costs one forced read of block 0 when the address really is bad --
 * the path that refuses a corrupt extent, not a hot one.
 */
int cetrafs_lba_run_past_end(struct super_block *sb, u64 lba, u64 count)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    unsigned long behind;
    int r;

    might_sleep(); /* a forced read and layout_mutex (GROWFS-LIVE-REVIEW L3) */
    if (READ_ONCE(cetrafs_layout_past_end_no_refresh))
        return -EUCLEAN; /* test-only; see the parameter */
    /* Behind the device as of less than a second ago: still "cannot
     * tell", without another read of block 0 for every block a file
     * in the new space is asked about. Only the answer that marks
     * NOTHING is reused this way -- reusing "current" would turn a grow
     * published within that second into damage (L4). */
    behind = READ_ONCE(sbi->layout_behind_at);
    if (behind && time_before(jiffies, behind + HZ))
        return -EAGAIN;
    r = cetrafs_sb_layout_refresh(sb);
    if (r == 1)
        return cetrafs_lba_run_check(sb, lba, count);
    if (r < 0) {
        pr_warn_ratelimited("%s: blocks %llu+%llu lie past this node's layout, and it cannot learn whether a "
                            "grow put them there (%d) -- refusing the I/O, marking nothing\n",
                            sb->s_id, (unsigned long long) lba, (unsigned long long) count, r);
        return -EAGAIN;
    }
    return -EUCLEAN;
}

/*
 * Does [lba, lba+count) touch an appended Block Group table segment?
 * The half of cetrafs_lba_run_is_data() that needs the mount's chain
 * walk. O(grows) with no I/O; zero iterations on a never-grown volume.
 */
/* Is [lba, lba+count) inside Block Group b's data region? */
static bool cetrafs_layout_run_in_bg(const struct cetrafs_bg_layout *l, u32 b, u64 lba, u64 count)
{
    const struct cetrafs_bg_chunk *c = l->chunk[b >> CETRAFS_BGC_SHIFT];
    u32 i = b & CETRAFS_BGC_MASK;
    u64 s = READ_ONCE(c->bg_data_start[i]), n = READ_ONCE(c->bg_data_count[i]);

    return lba >= s && count <= n && lba - s <= n - count;
}

/*
 * Does [lba, lba+count) lie inside ONE Block Group's data region? What
 * fsck asks of every extent (fsck_run_bg()), and what the allocator
 * guarantees: a run comes from one group's bitmap. The other half of
 * cetrafs_lba_run_check(), past its box test: a header or bitmap sits
 * between two data regions, inside the box (M-40).
 *
 * No I/O. On a never-grown volume the group is arithmetic -- one
 * division and two loads on the per-block path; a grown one, whose
 * later groups start past the holes earlier grows left, or an address
 * in a header, falls to a binary search over the starts in memory
 * (ordered: the mount refuses a group that starts before the previous
 * one ends).
 */
bool cetrafs_sb_lba_run_in_bg_data(struct super_block *sb, u64 lba, u64 count)
{
    const struct cetrafs_bg_layout *l = cetrafs_sb_layout_of(sb->s_fs_info);
    u64 rs, span;
    u32 lo, hi;

    if (!l || !l->bg_count || !count)
        return false;
    if (READ_ONCE(cetrafs_lba_bg_check_off))
        return !cetrafs_sb_lba_run_hits_bg_table(sb, lba, count); /* TEST ONLY: the box alone */
    rs = le64_to_cpu(l->raw.bg_regions_start);
    span = le64_to_cpu(l->raw.bg_size_blocks);
    if (span && lba >= rs) {
        u64 cand = div64_u64(lba - rs, span);

        if (cand < l->bg_count && cetrafs_layout_run_in_bg(l, (u32) cand, lba, count))
            return true;
    }
    lo = 0;
    hi = l->bg_count;
    while (hi - lo > 1) {
        u32 mid = lo + (hi - lo) / 2;
        const struct cetrafs_bg_chunk *c = l->chunk[mid >> CETRAFS_BGC_SHIFT];

        if (READ_ONCE(c->bg_data_start[mid & CETRAFS_BGC_MASK]) <= lba)
            lo = mid;
        else
            hi = mid;
    }
    return cetrafs_layout_run_in_bg(l, lo, lba, count);
}

bool cetrafs_sb_lba_run_hits_bg_table(struct super_block *sb, u64 lba, u64 count)
{
    struct cetrafs_bg_layout *l = cetrafs_sb_layout_of(sb->s_fs_info);

    if (!l)
        return true;
    return cetrafs_lba_ranges_hit(l->bg_segs, l->bg_nsegs, lba, count);
}

const cetrafs_superblock_t *cetrafs_sb_raw(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    struct cetrafs_bg_layout *l = cetrafs_sb_layout_of(sbi);

    return l ? &l->raw : NULL;
}

/* Adjust the in-memory cached free-inode count by 'delta' (+1 on free,
 * -1 on alloc). Called by alloc.c; never persisted (see struct
 * cetrafs_sb_info above). */
int cetrafs_sb_adjust_free_inodes(struct super_block *sb, s64 delta)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return -EINVAL;
    atomic64_add(delta, &sbi->free_inodes);
    return 0;
}

/*
 * How often statfs recounts the inode bitmap. A recount reads every inode
 * bitmap block, so it is not done per call (pvestatd polls every ~10 s).
 */
#define CETRAFS_FREE_INODES_RECOUNT_JIFFIES (10 * HZ)

/*
 * Recount the free inodes from the bitmap as the device has it. The
 * blocks are dropped first (clean ones only, as cetrafs_invalidate_block()
 * always does): a cached copy is what a peer's allocations leave behind.
 */
static int cetrafs_sb_recount_free_inodes(struct super_block *sb, u64 *out)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 bmap, nblocks, i;

    if (!raw_sb)
        return -EINVAL;
    bmap = le64_to_cpu(raw_sb->inode_bmap_start);
    nblocks = le64_to_cpu(raw_sb->inode_bmap_blocks);
    for (i = 0; i < nblocks; i++)
        cetrafs_invalidate_block(sb, bmap + i);
    return cetrafs_count_free_inodes(sb, out);
}

/*
 * Read the free-inode count, for statfs. Recounted from the bitmap when
 * due (audit O9): a peer's creates and unlinks never reached this node's
 * own adjustments, so the count drifted without bound. A failed recount
 * reports the cached value rather than failing statfs.
 *
 * A recount can overlap this node's own in-flight create or unlink (the
 * bitmap bit is set before the adjustment lands), so the value can be off
 * by those few operations until the next recount. That is a lying df for
 * a moment, never an allocation decision, and it does not accumulate.
 */
int cetrafs_sb_get_free_inodes(struct super_block *sb, u64 *out)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return -EINVAL;
    if (time_after_eq(jiffies, READ_ONCE(sbi->free_inodes_next))) {
        u64 n = 0;

        if (!cetrafs_sb_recount_free_inodes(sb, &n)) {
            atomic64_set(&sbi->free_inodes, (s64) n);
            WRITE_ONCE(sbi->free_inodes_next, jiffies + CETRAFS_FREE_INODES_RECOUNT_JIFFIES);
        }
    }
    *out = (u64) atomic64_read(&sbi->free_inodes);
    return 0;
}

/* Has this mount registered its own Node Registry row? A fence taken
 * before that (the no-CAW mount gate) has no fencer row to name. */
bool cetrafs_sb_node_registered(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && sbi->node_registered;
}

/* This node's own Node Registry row index, claimed at mount time by
 * cetrafs_node_register() -- needed by later phases (ZG claiming). */
int cetrafs_sb_get_node_id(struct super_block *sb, u32 *out)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return -EINVAL;
    *out = sbi->node_id;
    return 0;
}

/* This node's own parsed UUID, cached alongside node_id -- needed by
 * heartbeat.c's periodic tick to derive a PR key
 * when re-running zonegroup.c's claim pass outside the one-time
 * mount path, which already has it as a local variable. */
int cetrafs_sb_get_node_uuid(struct super_block *sb, u8 out[CETRAFS_NODE_UUID_LEN])
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return -EINVAL;
    memcpy(out, sbi->node_uuid, CETRAFS_NODE_UUID_LEN);
    return 0;
}

/* This mount's live per-ZG journal write-path state,
 * opaque to fs.c -- owned and interpreted entirely by journal.c. NULL
 * is a valid, meaningful return (sbi itself missing); journal.c's own
 * callers already treat a journal of NULL/absent the same as "nothing
 * to log against", so no separate error path is needed here. */
struct cetrafs_journal *cetrafs_sb_get_journal(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? sbi->journal : NULL;
}

struct list_head *cetrafs_sb_deferred_orphans(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? &sbi->deferred_orphans : NULL;
}

struct xarray *cetrafs_sb_held(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? &sbi->held : NULL;
}

struct xarray *cetrafs_sb_deferred(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? &sbi->deferred : NULL;
}

/*
 * The live-reservation registry (see cetrafs_sb_info.resv_list). lock.c
 * owns the embedded spans; scrub.c is the only consumer.
 *
 * Every entry point takes the lock itself and tolerates s_fs_info being
 * NULL. That is not defensive padding: when fill_super() fails, the
 * unwind frees sb_info and THEN evicts the inodes it had instantiated,
 * so ->evict_inode runs against a superblock with no sb_info at all.
 * An unconditional spin_lock here oopsed on exactly that path -- inside
 * the lock, so the dying task left the super lock held and every later
 * mount hung on it forever.
 */
void cetrafs_resv_publish(struct super_block *sb, struct cetrafs_resv_span *span, u64 start, u32 count)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return;

    spin_lock(&sbi->resv_list_lock);
    /* Re-pointed: the old run's blocks left the registry -- unless the
     * new run contains the old one, as a span that only grows does
     * (fallocate's, cetrafs_do_allocate()): then nothing left, and a
     * bump would only stop every scrub free for as long as it grows. */
    if (!list_empty(&span->link) &&
        !(start <= span->start && start + count >= span->start + span->count))
        sbi->resv_seq++;
    span->start = start;
    span->count = count;
    if (list_empty(&span->link))
        list_add(&span->link, &sbi->resv_list);
    spin_unlock(&sbi->resv_list_lock);
}

void cetrafs_resv_unpublish(struct super_block *sb, struct cetrafs_resv_span *span)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi) {
        /* No list to be on: fill_super never got far enough to make one,
         * or it is already gone. The span was never published, so
         * clearing it is all that is owed. */
        span->start = 0;
        span->count = 0;
        INIT_LIST_HEAD(&span->link);
        return;
    }

    spin_lock(&sbi->resv_list_lock);
    if (!list_empty(&span->link)) {
        list_del_init(&span->link);
        sbi->resv_seq++;
    }
    span->start = 0;
    span->count = 0;
    spin_unlock(&sbi->resv_list_lock);
}

/*
 * How many times blocks have left the reservation registry. The scrub
 * takes it before the reference set its frees rest on, and frees a block
 * only if, at that instant, the block is covered by no span AND this has
 * not moved: then no span held the block at any point since the evidence
 * was taken, so no released run can have turned it into data the
 * evidence does not show (tests/kernel/scrub_vs_released_run.sh).
 */
u64 cetrafs_sb_resv_seq(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u64 v;

    if (!sbi)
        return 0;
    spin_lock(&sbi->resv_list_lock);
    v = sbi->resv_seq;
    spin_unlock(&sbi->resv_list_lock);
    return v;
}

/*
* Frees in flight (cetrafs_node_entry_t.frees_inflight; audit 2026-11-06,
 * N2 sweep finding A).
 *
 * cetrafs_frees_begin() goes BEFORE a publish that drops blocks this
 * operation then frees, cetrafs_frees_end() after the last of those
 * frees (or after deciding to leave them to the scrub). Between the two
 * the blocks are named by nothing and not yet free, and the scrub -- this
 * node's, and the owning peer's -- must not judge them leaked.
 *
 * 'foreign': some dropped block lies outside the Block Groups this node
 * owns (cetrafs_lba_run_is_ours()). Only then can a PEER's scrub judge
 * one, so only then does the operation say so in our registry row, which
 * every peer's scrub reads and abandons its cycle over. Announcing every
 * free stopped every scrub in the cluster whenever any node punched a
 * hole in its own image -- a guest discard -- and a node that does that
 * every heartbeat never let one finish (class 46). Our own scrub
 * still counts every free (frees_count). The verdict is safe in both
 * directions it can be wrong in: a group this node owns is authoritative
 * in its own cache -- it leaves only by our release, which takes only an
 * empty group, or by a peer's steal, which fences us first and our frees
 * then never land -- and anything unreadable or unowned reads foreign.
 *
 * The row flag is written durably before begin returns; a node that
 * cannot write it (fenced, its row lost) must not publish at all, so the
 * error goes back to the operation. The flag is cleared lazily, by the
 * heartbeat, once nothing foreign is in flight.
 */
/* TEST ONLY: every free is announced in the registry row, as before the
 * scoping -- the control of scrub_spares_inflight_free's own-group part,
 * and on one node (where every group is ours) the way to put the row in
 * play at all. */
static bool cetrafs_frees_announce_all;
cetrafs_test_param(frees_announce_all, cetrafs_frees_announce_all, bool, 0644);
MODULE_PARM_DESC(frees_announce_all, "TEST ONLY: announce every free in flight in the registry row, ours or not");

static atomic64_t cetrafs_frees_announced = ATOMIC64_INIT(0);

u64 cetrafs_frees_announced_count(void)
{
    return (u64) atomic64_read(&cetrafs_frees_announced);
}

/* *foreign: in, the operation's verdict; out, what this begin counted --
 * the value its cetrafs_frees_end() must be given. */
int cetrafs_frees_begin(struct super_block *sb, bool *foreign_io)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool foreign = *foreign_io;
    int ret = 0;

    if (!sbi)
        return -EINVAL;
    if (READ_ONCE(cetrafs_frees_announce_all))
        foreign = true; /* test-only; see the parameter */
    *foreign_io = foreign;
    mutex_lock(&sbi->frees_mutex);
    if (foreign && !sbi->frees_row_flag) {
        ret = cetrafs_node_set_frees(sb, sbi->node_id, true);
        if (ret) {
            mutex_unlock(&sbi->frees_mutex);
            pr_err_ratelimited("could not announce frees in flight in our registry row (%d) -- refusing the "
                               "operation before its publish\n",
                               ret);
            /* The same two answers the heartbeat's renewal fences on: a
             * peer revoked our lease, or the row is no longer ours. They
             * are the fence's signal whoever reads them first; refusing
             * this one operation and writing on until the next tick
             * would leave the mount allocating from Zone Groups it may
             * no longer own (zg_steal_victim_fences). */
            if (ret == -EPERM)
                cetrafs_sb_fence(sb, "our Node Registry lease was revoked, found while announcing frees in flight");
            else if (ret == -EOWNERDEAD)
                cetrafs_sb_fence(sb, "our Node Registry row is no longer ours, found while announcing frees in flight");
            return ret == -EPERM || ret == -EOWNERDEAD ? -EIO : ret;
        }
        sbi->frees_row_flag = true;
    }
    if (foreign) {
        sbi->frees_foreign++;
        atomic64_inc(&cetrafs_frees_announced);
    }
    sbi->frees_count++;
    sbi->frees_local_seq++;
    mutex_unlock(&sbi->frees_mutex);
    return 0;
}

/* 'foreign' as the begin it ends left it. */
void cetrafs_frees_end(struct super_block *sb, bool foreign)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return;
    mutex_lock(&sbi->frees_mutex);
    if (!WARN_ON_ONCE(!sbi->frees_count))
        sbi->frees_count--;
    if (foreign && !WARN_ON_ONCE(!sbi->frees_foreign))
        sbi->frees_foreign--;
    mutex_unlock(&sbi->frees_mutex);
}

/* Heartbeat tick: clear our row's flag once nothing foreign is in
 * flight. A failure leaves it set -- peers' scrubs keep waiting, which
 * is safe. */
void cetrafs_frees_heartbeat(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return;
    mutex_lock(&sbi->frees_mutex);
    if (!sbi->frees_foreign && sbi->frees_row_flag && !cetrafs_node_set_frees(sb, sbi->node_id, false))
        sbi->frees_row_flag = false;
    mutex_unlock(&sbi->frees_mutex);
}

/* TEST ONLY: the scrub ignores this node's in-memory count and reads its
 * own registry row instead, as a PEER's scrub does -- so one node can
 * show that the row alone keeps the blocks. */
static bool cetrafs_scrub_ignore_local_frees;
cetrafs_test_param(scrub_ignore_local_frees, cetrafs_scrub_ignore_local_frees, bool, 0644);
MODULE_PARM_DESC(scrub_ignore_local_frees,
                 "TEST ONLY: the scrub judges this node's frees in flight from its registry row only");

/*
 * The scrub's question, asked twice per cycle: before its deciding pass
 * (compare=false, fills *snap) and again before it frees (compare=true).
 * 0 when no node had frees in flight at either moment and no node began
 * any in between; -EBUSY otherwise. Why both: an operation that
 * published before pass 1 and has not finished freeing is in flight at
 * the first look; one that publishes after the first look dropped blocks
 * pass 1 still saw named, which are never candidates -- unless it also
 * finishes before the second, which the seq catches. One that begins
 * after the second look dropped blocks the deciding pass saw named.
 */
int cetrafs_frees_quiet(struct super_block *sb, struct cetrafs_frees_snap *snap, bool compare)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool self_row = READ_ONCE(cetrafs_scrub_ignore_local_frees);
    u32 seqs[CETRAFS_MAX_READER_NODES];
    bool busy = false;
    u64 local;
    int ret;

    if (!sbi)
        return -EINVAL;
    mutex_lock(&sbi->frees_mutex);
    if (sbi->frees_count && !self_row)
        busy = true;
    local = self_row ? 0 : sbi->frees_local_seq;
    mutex_unlock(&sbi->frees_mutex);

    {
        bool rows_busy = false;

        ret = cetrafs_node_frees_snapshot(sb, sbi->node_id, self_row, seqs, &rows_busy);
        if (ret)
            return ret;
        busy |= rows_busy;
    }
    if (busy)
        return -EBUSY;
    if (compare)
        return snap->local == local && !memcmp(snap->seqs, seqs, sizeof(seqs)) ? 0 : -EBUSY;
    snap->local = local;
    memcpy(snap->seqs, seqs, sizeof(seqs));
    return 0;
}

bool cetrafs_resv_covers(struct super_block *sb, u64 lba)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    struct cetrafs_resv_span *span;
    bool hit = false;

    if (!sbi)
        return false;

    spin_lock(&sbi->resv_list_lock);
    list_for_each_entry(span, &sbi->resv_list, link)
    {
        if (span->count && lba >= span->start && lba < span->start + span->count) {
            hit = true;
            break;
        }
    }
    spin_unlock(&sbi->resv_list_lock);
    return hit;
}

/*
 * alloc_mutex and birth_rwsem are both taken on the way to freeing:
 * evict of an unlinked inode frees its blocks under alloc_mutex and
 * its number under birth_rwsem for write. Direct reclaim prunes this
 * filesystem's unreferenced inodes, so an allocation that enters
 * reclaim while holding either can wait on itself. Each holder runs in
 * a NOFS scope, opened here so no caller has to remember it; the CAS
 * allocator WARNs if it finds a holder outside one
 * (cetrafs_sb_in_reclaim_lock()).
 */
void cetrafs_sb_alloc_lock(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    mutex_lock(&sbi->alloc_mutex);
    sbi->alloc_nofs = memalloc_nofs_save();
    WRITE_ONCE(sbi->alloc_owner, current);
}

void cetrafs_sb_alloc_unlock(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    WRITE_ONCE(sbi->alloc_owner, NULL);
    memalloc_nofs_restore(sbi->alloc_nofs);
    mutex_unlock(&sbi->alloc_mutex);
}

/*
 * Serialise this node's Zone Group claims and re-attaches. Returns false
 * when the caller already holds it -- a claim whose steal frees into a
 * full queue reaches the claim again -- and the caller then must not
 * unlock. NOFS for the same reason as alloc_mutex: an evict under
 * memory reclaim can free into a full queue, which claims.
 */
bool cetrafs_sb_zg_claim_lock(struct super_block *sb, unsigned int *nofs)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (READ_ONCE(sbi->zg_claim_owner) == current)
        return false;
    *nofs = memalloc_nofs_save();
    mutex_lock(&sbi->zg_claim_mutex);
    WRITE_ONCE(sbi->zg_claim_owner, current);
    return true;
}

/* Killable: 1 taken, 0 the caller already holds it, -EINTR. */
int cetrafs_sb_zg_claim_lock_killable(struct super_block *sb, unsigned int *nofs)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (READ_ONCE(sbi->zg_claim_owner) == current)
        return 0;
    *nofs = memalloc_nofs_save();
    if (mutex_lock_killable(&sbi->zg_claim_mutex)) {
        memalloc_nofs_restore(*nofs);
        return -EINTR;
    }
    WRITE_ONCE(sbi->zg_claim_owner, current);
    return 1;
}

bool cetrafs_sb_proc_closing(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return !sbi || READ_ONCE(sbi->proc_closing);
}

/* Is the claim mutex held by anyone? (A test probe.) */
bool cetrafs_sb_zg_claim_busy(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return mutex_is_locked(&sbi->zg_claim_mutex);
}

/* Does the calling task hold the claim mutex? */
/* A Zone Group claimed on the device whose claim is finishing outside
 * the claim mutex (zonegroup.c). */
void cetrafs_sb_zg_claiming_set(struct super_block *sb, u32 zg_id, bool on)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (zg_id >= CETRAFS_MAX_ZONE_GROUPS)
        return;
    if (on) {
        set_bit(zg_id, sbi->zg_claiming);
    } else {
        clear_bit(zg_id, sbi->zg_claiming);
        wake_up_all(&sbi->zg_claiming_wq);
    }
}

bool cetrafs_sb_zg_claiming(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return zg_id < CETRAFS_MAX_ZONE_GROUPS && test_bit(zg_id, sbi->zg_claiming);
}

bool cetrafs_sb_zg_any_claiming(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return !bitmap_empty(sbi->zg_claiming, CETRAFS_MAX_ZONE_GROUPS);
}

/* Wait, killable, for every claim finishing outside the mutex. */
int cetrafs_sb_zg_claiming_wait(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return wait_event_killable(sbi->zg_claiming_wq, bitmap_empty(sbi->zg_claiming, CETRAFS_MAX_ZONE_GROUPS))
               ? -EINTR
               : 0;
}

bool cetrafs_sb_zg_claim_held(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return READ_ONCE(sbi->zg_claim_owner) == current;
}

void cetrafs_sb_zg_claim_unlock(struct super_block *sb, unsigned int nofs)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    WRITE_ONCE(sbi->zg_claim_owner, NULL);
    mutex_unlock(&sbi->zg_claim_mutex);
    memalloc_nofs_restore(nofs);
}

void cetrafs_sb_zg_want_adopt(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi && zg_id < CETRAFS_MAX_ZONE_GROUPS)
        set_bit(zg_id, sbi->zg_adopt_wanted);
}

bool cetrafs_sb_zg_adopt_is_wanted(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && zg_id < CETRAFS_MAX_ZONE_GROUPS && test_bit(zg_id, sbi->zg_adopt_wanted);
}

/* The heartbeat has made its attempt at zg_id, whatever the outcome. */
void cetrafs_sb_zg_adopt_done(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || zg_id >= CETRAFS_MAX_ZONE_GROUPS)
        return;
    clear_bit(zg_id, sbi->zg_adopt_wanted);
    wake_up_all(&sbi->zg_adopt_wq);
}

/* Is there a heartbeat to hand a takeover to? Not before fill_super()
 * starts it: a claim made during mount runs in the mount, which holds no
 * file's locks and may take a dead owner's Zone Group itself. */
bool cetrafs_sb_has_heartbeat(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && READ_ONCE(sbi->hb);
}

/*
 * An allocator that found its only space in a dead peer's Zone Group
 * asks the heartbeat to take it over now rather than on its next tick,
 * and waits for the attempt. Killable, and bounded by the takeover's
 * own worst case (the journal replay's claim wait, plus the recount);
 * a fence ends it too, since a fenced mount's maintenance pass does
 * nothing. Returns true once the attempt was made, false otherwise.
 * The heartbeat is stopped only in put_super, after every writer that
 * could allocate is gone.
 */
bool cetrafs_sb_zg_adopt_wait(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    struct cetrafs_heartbeat *hb = sbi ? READ_ONCE(sbi->hb) : NULL;
    unsigned long t0 = jiffies, cap;

    if (!hb)
        return false;
    mod_delayed_work(system_unbound_wq, &hb->maint, 0); /* the queue heartbeat.c uses */
    cap = (unsigned long) (cetrafs_sb_stale_secs(sb) * 3 + 60) * HZ;
    /* In one-second slices: a fence wakes nobody here. */
    while (test_bit(zg_id, sbi->zg_adopt_wanted)) {
        if (cetrafs_sb_is_fenced(sb) || fatal_signal_pending(current) || time_after(jiffies, t0 + cap))
            return false;
        if (wait_event_killable_timeout(sbi->zg_adopt_wq, !test_bit(zg_id, sbi->zg_adopt_wanted), HZ) < 0)
            return false;
    }
    return true;
}

/*
 * The surplus release takes space out of reach while it decides whether
 * to give it back. That is a moment, not an answer: an allocator that
 * finds nothing while it runs must wait for it and look again, not
 * report ENOSPC for space that comes back an instant later.
 */
void cetrafs_sb_release_lock(struct super_block *sb)
{
    down_write(&((struct cetrafs_sb_info *) sb->s_fs_info)->release_rwsem);
}

void cetrafs_sb_release_unlock(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    atomic_inc(&sbi->release_seq); /* before the unlock: a waiter that gets in sees it */
    up_write(&sbi->release_rwsem);
}

/* TEST ONLY: the allocator's wait for a release is the old plain
 * down_read(), which SIGKILL cannot end (release_drain_no_enospc.sh's
 * control). */
static bool cetrafs_release_wait_unkillable;
cetrafs_test_param(release_wait_unkillable, cetrafs_release_wait_unkillable, bool, 0644);
MODULE_PARM_DESC(release_wait_unkillable, "TEST ONLY: the allocator waits for a release uninterruptibly (the old wait)");

/* A stamp for cetrafs_sb_release_ended_since(). */
int cetrafs_sb_release_seq(struct super_block *sb)
{
    return atomic_read(&((struct cetrafs_sb_info *) sb->s_fs_info)->release_seq);
}

/* Did a release end after 'seq' was taken? Any release that overlapped
 * the caller's scans either ended before this call or was waited for by
 * cetrafs_sb_release_wait() and ended then. */
bool cetrafs_sb_release_ended_since(struct super_block *sb, int seq)
{
    return cetrafs_sb_release_seq(sb) != seq;
}

/* Hold off every release while a Block Group is claimed into a Zone
 * Group this node owns (zonegroup.c). Killable; -EINTR when killed.
 * TEST ONLY release_claim_unlocked: the old, unlocked claim. */
static bool cetrafs_release_claim_unlocked;
cetrafs_test_param(release_claim_unlocked, cetrafs_release_claim_unlocked, bool, 0644);
MODULE_PARM_DESC(release_claim_unlocked, "TEST ONLY: a pool claim does not wait out a Zone Group release");

int cetrafs_sb_release_read_lock(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (READ_ONCE(cetrafs_release_claim_unlocked))
        return 0;
    if (READ_ONCE(cetrafs_release_wait_unkillable)) {
        down_read(&sbi->release_rwsem); /* test-only: the old, unkillable wait */
        return 0;
    }
    /* Killable (class 20), like cetrafs_sb_release_wait(): a release can
     * hold the lock across a discard. */
    return down_read_killable(&sbi->release_rwsem) ? -EINTR : 0;
}

void cetrafs_sb_release_read_unlock(struct super_block *sb)
{
    if (READ_ONCE(cetrafs_release_claim_unlocked))
        return;
    up_read(&((struct cetrafs_sb_info *) sb->s_fs_info)->release_rwsem);
}

void cetrafs_sb_release_wait(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (READ_ONCE(cetrafs_release_wait_unkillable)) {
        down_read(&sbi->release_rwsem); /* test-only; see the parameter */
        up_read(&sbi->release_rwsem);
        return;
    }

    /* Killable (class 20): a release pass can hold this across a Block
     * Group's discard, a second or more, and the waiter is a writer about
     * to answer ENOSPC. A killed one has nobody to answer: it skips the
     * wait, and its allocation ends as it would have without one. */
    if (down_read_killable(&sbi->release_rwsem))
        return;
    up_read(&sbi->release_rwsem);
}

/*
 * A nanosecond stamp for file_seq and inode generations: the real clock
 * as it read at mount, advanced by the MONOTONIC clock, and strictly
 * increasing per mount. The real clock alone can step backward (NTP, an
 * operator); the monotonic advance keeps one mount's stamps unique and
 * increasing. Anchored to the real clock so a remount does not restart
 * near values it handed out before.
 *
 * Stamps are compared for EQUALITY only -- is this the record we last
 * saw? Nothing orders them. The refresh used to age-order its own stamps
 * against this clock; a 48-bit clock wraps every ~3.26 days, so an old
 * stamp could look newer than a note, and the refresh now re-reads and
 * compares for equality instead (cetrafs_refresh_settle()).
 *
 * Monotonic per MOUNT only. Each mount re-anchors to the real clock, so
 * a backward step between mounts can give a new stamp a value an older
 * one already carries. That is only a collision if the clock reproduces
 * the same nanosecond exactly; it is not guarded against.
 */
u64 cetrafs_sb_stamp_ns(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;
    s64 now, old, next;

    if (!sbi)
        return ktime_get_real_ns();
    now = sbi->stamp_base + (s64) ktime_get_ns();
    old = atomic64_read(&sbi->stamp_last);
    do {
        next = now > old ? now : old + 1;
    } while (!atomic64_try_cmpxchg(&sbi->stamp_last, &old, next));
    return (u64) next;
}

/* This mount's stamp clock now: never below a stamp already issued. */
u64 cetrafs_sb_stamp_now(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;
    s64 now, last;

    if (!sbi)
        return ktime_get_real_ns();
    now = sbi->stamp_base + (s64) ktime_get_ns();
    last = atomic64_read(&sbi->stamp_last);
    return (u64) (now > last ? now : last);
}

/*
 * TEST ONLY control: the age-ordered compare the refresh used to make
 * between an own file_seq stamp and the note of this node's last publish.
 * Kept only for refresh_seq_age_compare, so the suite can reproduce the
 * in-core revert it caused. Production never orders stamps. Ordering two
 * stamps by their age against this clock is right only inside one full
 * wrap (~3.26 days); a note older than that cannot be placed, and
 * `noted_at` is the clock when it was taken.
 */
bool cetrafs_sb_own_seq_older(struct super_block *sb, u64 a, u64 b, u64 noted_at)
{
    u64 now = cetrafs_sb_stamp_now(sb);

    if (now - noted_at >= CETRAFS_FILE_SEQ_VAL_MASK)
        return false;
    return ((now - a) & CETRAFS_FILE_SEQ_VAL_MASK) > ((now - b) & CETRAFS_FILE_SEQ_VAL_MASK);
}

/* Does the current task hold alloc_mutex (through the wrappers) or
 * birth_rwsem for write? The read side is not tracked. */
bool cetrafs_sb_in_reclaim_lock(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    return sbi && (READ_ONCE(sbi->alloc_owner) == current || READ_ONCE(sbi->birth_writer) == current);
}

/* TEST ONLY -- see cetrafs_sb_info.alloc_shadow. */
bool cetrafs_alloc_shadow_enabled;
cetrafs_test_param(alloc_shadow, cetrafs_alloc_shadow_enabled, bool, 0644);
MODULE_PARM_DESC(alloc_shadow, "TEST ONLY: shadow-track every data alloc/free; scream on double alloc");

void cetrafs_sb_birth_begin(struct super_block *sb, u64 ino)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi && sbi->inode_birth)
        set_bit((unsigned int) ino, sbi->inode_birth);
}

void cetrafs_sb_birth_end(struct super_block *sb, u64 ino)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi && sbi->inode_birth)
        clear_bit((unsigned int) ino, sbi->inode_birth);
}

bool cetrafs_sb_birth_active(struct super_block *sb, u64 ino)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && sbi->inode_birth && test_bit((unsigned int) ino, sbi->inode_birth);
}

/* See cetrafs_sb_info.birth_rwsem. */
/* Returns the NOFS scope it opened (see cetrafs_sb_alloc_lock()), for
 * cetrafs_sb_birth_ungate(): either side, a reader included, can be
 * waited on by an evict that reclaim started. */
unsigned int cetrafs_sb_birth_gate(struct super_block *sb, bool reclaim)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    unsigned int nofs;

    if (reclaim)
        down_write(&sbi->birth_rwsem);
    else
        down_read(&sbi->birth_rwsem);
    nofs = memalloc_nofs_save();
    if (reclaim)
        WRITE_ONCE(sbi->birth_writer, current);
    return nofs;
}

void cetrafs_sb_birth_ungate(struct super_block *sb, bool reclaim, unsigned int nofs)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (reclaim)
        WRITE_ONCE(sbi->birth_writer, NULL);
    memalloc_nofs_restore(nofs);
    if (reclaim)
        up_write(&sbi->birth_rwsem);
    else
        up_read(&sbi->birth_rwsem);
}

bool cetrafs_shadow_active(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && sbi->alloc_shadow;
}

void cetrafs_shadow_set(struct super_block *sb, u64 lba, u64 count, const char *who)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u64 k;

    if (!sbi || !sbi->alloc_shadow)
        return;
    for (k = 0; k < count; k++) {
        if (lba + k >= sbi->total_blocks)
            return;
        if (test_and_set_bit((unsigned int) (lba + k), sbi->alloc_shadow)) {
            pr_err("SHADOW DOUBLE-ALLOC lba=%llu by %s (bit already set)\n", (unsigned long long) (lba + k), who);
            dump_stack();
        }
    }
}

void cetrafs_shadow_clear(struct super_block *sb, u64 lba, u64 count, const char *who)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u64 k;

    if (!sbi || !sbi->alloc_shadow)
        return;
    for (k = 0; k < count; k++) {
        if (lba + k >= sbi->total_blocks)
            return;
        if (!test_and_clear_bit((unsigned int) (lba + k), sbi->alloc_shadow))
            pr_warn("SHADOW FREE-OF-UNTRACKED lba=%llu by %s\n", (unsigned long long) (lba + k), who);
    }
}

/*
 * Held across the no-CAW fallback's read-decide-write
 * (cetrafs_cas_region_seeded_impl()) and across a raw inode record write
 * on a no-CAW device (cetrafs_write_raw_inode(), which must not land
 * between a CAS's read and its write). A leaf lock: no CAS mutator and
 * nothing inside the record write acquires anything.
 *
 * Both hold it across DEVICE I/O -- a forced-fresh read and a synced
 * write -- so a stalled device leaves every other local CAS waiting on
 * it. The CAS side waits killably when its caller may be interrupted
 * (cetrafs_sb_cas_lock_killable()); it used to be uninterruptible
 * whatever the caller, and this comment named only one holder (audit
 * 2026-11-11 C4, tests/kernel/cas_nocaw_wait_killable.sh).
 */
void cetrafs_sb_cas_lock(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    mutex_lock(&sbi->cas_mutex);
}

int cetrafs_sb_cas_lock_killable(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return mutex_lock_killable(&sbi->cas_mutex);
}

void cetrafs_sb_cas_unlock(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    mutex_unlock(&sbi->cas_mutex);
}

/* TEST ONLY: errors=panic logs "would panic" on a fence, lease or
 * device-gone stop instead of panicking (tests/kernel/errors_panic_stops.sh). */
static bool cetrafs_panic_dry_run;
cetrafs_test_param(panic_dry_run, cetrafs_panic_dry_run, bool, 0644);
MODULE_PARM_DESC(panic_dry_run, "TEST ONLY: errors=panic on a fence/lease/device-gone stop logs instead of panicking");

static const char *const cetrafs_stop_cause_names[] = {
    [CETRAFS_STOP_NONE] = "none",
    [CETRAFS_STOP_FENCED] = "fenced",
    [CETRAFS_STOP_LEASE] = "lease",
    [CETRAFS_STOP_ERROR] = "error",
    [CETRAFS_STOP_CORRUPTION] = "corruption",
    [CETRAFS_STOP_MANUAL] = "manual",
    [CETRAFS_STOP_DEVICE_GONE] = "device_gone",
};

const char *cetrafs_sb_stop_cause_name(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    int c;

    if (!sbi)
        return "none";
    /* The lease latches before its work item runs the stop. */
    if (!READ_ONCE(sbi->fenced))
        return test_bit(0, &sbi->lease_lost) ? "lease" : "none";
    c = READ_ONCE(sbi->stop_cause);
    if (c < 0 || c >= ARRAY_SIZE(cetrafs_stop_cause_names) || !cetrafs_stop_cause_names[c])
        return "?";
    return cetrafs_stop_cause_names[c];
}

/*
 * Stop this mount: from here on it writes nothing and reads nothing,
 * and its heartbeat no longer renews, so after the staleness window its
 * peers do what they do for a node that crashed -- replay its journal,
 * take its Zone Groups, break its locks. The way back is unmount and
 * mount.
 *
 * Every cause ends in the same state on purpose. A crash is the case
 * the cluster is built to recover from, and the only one tested
 * end-to-end; a node that keeps going after it stopped knowing what is
 * on the device is a writer acting on guesses.
 *
 * Nothing here does I/O, and nothing may: the dirty metadata is DROPPED,
 * not written (the blocks may already belong to a peer, or be the very
 * write that failed). Callable from any context that may sleep.
 */
void cetrafs_sb_stop(struct super_block *sb, enum cetrafs_stop_cause cause, const char *reason)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || READ_ONCE(sbi->fenced))
        return;
    if (cmpxchg(&sbi->stop_cause, CETRAFS_STOP_NONE, cause) != CETRAFS_STOP_NONE)
        return; /* another cause got here first; it does the rest */
    smp_wmb(); /* the cause before the flag that publishes it */
    WRITE_ONCE(sbi->fenced, true);

    if (cause == CETRAFS_STOP_FENCED || cause == CETRAFS_STOP_LEASE)
        pr_err("%s: SELF-FENCED: %s -- a peer has declared this node dead or may do so at any moment; "
               "all I/O on this mount now fails with EIO. Unmount and remount to rejoin the cluster.\n",
               sb->s_id, reason);
    else
        pr_err("%s: STOPPED (%s): %s -- all I/O on this mount now fails with EIO and the heartbeat no "
               "longer renews, so peers recover this node's work as after a crash. Unmount, check the "
               "volume, and mount again.\n",
               sb->s_id, cetrafs_stop_cause_names[cause], reason);
    /*
     * errors=panic is the pairing for a node a watchdog reboots, and the
     * stops a storage outage produces are exactly these three: a peer
     * fenced us, our own lease ran out, the device went away. Stopping
     * instead left the host up and "healthy" to the cluster manager with
     * every guest in EIO, so HA never acted (audit 2026-11-14 A-5). A
     * MANUAL stop was asked for and does not panic; ERROR and CORRUPTION
     * panic before they get here (cetrafs_sb_fatal(), cetrafs_sb_corrupt()).
     */
    if (sbi->errors_panic &&
        (cause == CETRAFS_STOP_FENCED || cause == CETRAFS_STOP_LEASE || cause == CETRAFS_STOP_DEVICE_GONE)) {
        if (READ_ONCE(cetrafs_panic_dry_run))
            pr_err("%s: errors=panic: would panic now (%s) -- panic_dry_run, test\n", sb->s_id,
                   cetrafs_stop_cause_names[cause]);
        else
            panic("cetrafs %s: %s: %s (errors=panic)\n", sb->s_id, cetrafs_stop_cause_names[cause], reason);
    }
    /* After the flag, so nothing re-dirties behind the sweep through an
     * entry point that already checks it. */
    schedule_work(&sbi->stop_work);
}

/* TEST ONLY: the stop's sweep of dirty metadata starts N ms late -- the
 * window a node resuming from a freeze gives the block layer's own
 * writeback before the sweep runs (tests/kernel/fence_writeback_race.sh). */
static unsigned int cetrafs_stop_sweep_delay_ms;
cetrafs_test_param(stop_sweep_delay_ms, cetrafs_stop_sweep_delay_ms, uint, 0644);
MODULE_PARM_DESC(stop_sweep_delay_ms, "TEST ONLY: delay the self-fence's sweep of dirty metadata by N ms");

static void cetrafs_sb_stop_work(struct work_struct *w)
{
    struct cetrafs_sb_info *sbi = container_of(w, struct cetrafs_sb_info, stop_work);
    struct super_block *sb = sbi->sb;

    if (sb && sb->s_bdev) {
        unsigned long n;

        if (READ_ONCE(cetrafs_stop_sweep_delay_ms))
            msleep(READ_ONCE(cetrafs_stop_sweep_delay_ms)); /* test-only; see the parameter */
        n = cetrafs_drop_dirty_metadata(sb) + cetrafs_deferred_drop_all(sb) + cetrafs_held_drop_all(sb);

        if (n)
            pr_err("%s: SELF-FENCED: discarded %lu dirty metadata buffer(s) without writing them -- the "
                   "blocks they describe may already belong to a peer\n",
                   sb->s_id, n);
    }
}

void cetrafs_sb_fence(struct super_block *sb, const char *reason)
{
    cetrafs_sb_stop(sb, CETRAFS_STOP_FENCED, reason);
}

/*
 * TEST ONLY. Report a fatal error and carry on, as before the error
 * policy existed -- the negative control of every suite that proves a
 * fatal error stops the mount.
 */
static bool cetrafs_error_policy_off;
cetrafs_test_param(error_policy_off, cetrafs_error_policy_off, bool, 0644);
MODULE_PARM_DESC(error_policy_off, "TEST ONLY: log fatal errors and corruption without acting on them");

/*
 * Kind 3 of docs/internal/ERRORS.md: this node no longer knows what is
 * on the device -- a metadata write the device refused, a swap whose
 * outcome cannot be decided, a contradiction between what it holds and
 * what it reads. Every write after this would be built on a guess, so
 * the mount stops (errors=stop, the default) or the machine panics
 * (errors=panic, for a cluster that reboots a node by watchdog).
 */
void cetrafs_sb_fatal(struct super_block *sb, const char *fmt, ...)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    char msg[192];
    va_list args;

    va_start(args, fmt);
    vsnprintf(msg, sizeof(msg), fmt, args);
    va_end(args);

    if (cetrafs_error_policy_off) {
        pr_err("%s: fatal error IGNORED (error_policy_off): %s\n", sb->s_id, msg);
        return;
    }
    if (sbi && sbi->errors_panic)
        panic("cetrafs %s: %s (errors=panic)\n", sb->s_id, msg);
    cetrafs_sb_stop(sb, CETRAFS_STOP_ERROR, msg);
}

/*
 * Kind 2 of docs/internal/ERRORS.md: a structure read off the device
 * failed its checksum or its bounds, every retry included. Nothing was
 * built from it -- the read that found it refused it -- so the damage
 * has not spread, and stopping would not stop it: the block is on the
 * shared device, and every node HA moves the work to would read it too.
 *
 * So, by default: count it (procfs `corruptions:`), say once that the
 * volume needs fsck, and refuse every later WRITE to the inode it was
 * found in, if one is known ('ino' 0: none) -- above all the ones that
 * would FREE blocks on the strength of a damaged tree. Reads of that
 * inode go on failing by themselves, on the bad block, and only there.
 *
 * corruption=stop makes it kind 3 instead.
 *
 * The mark is per INCARNATION, not per number (CLAUDE.md rule 2): inode
 * numbers are reused, and a mark keyed by the number alone refused every
 * write to whatever file was handed that number next. It carries the
 * damaged record's generation when the caller has the inode
 * (cetrafs_sb_corrupt_inode()); a bare number is stored as "generation
 * unknown", which matches any incarnation. Either is dropped when this
 * node allocates the number again (cetrafs_sb_ino_reborn()): the new
 * record is written whole, so the damage was the old one's. An unknown
 * mark on a number a PEER re-allocates stays until remount -- refusing a
 * healthy file's writes, the conservative side, on a volume already
 * reported as needing fsck.
 */
#define CETRAFS_BAD_GEN_UNKNOWN 0UL
static unsigned long cetrafs_bad_gen(u64 generation)
{
    return (unsigned long) (generation & LONG_MAX);
}

static void cetrafs_sb_corrupt_gen(struct super_block *sb, u64 ino, unsigned long gen);

static bool cetrafs_bad_mark_covers(void *stored, unsigned long gen)
{
    return stored && (xa_to_value(stored) == CETRAFS_BAD_GEN_UNKNOWN || xa_to_value(stored) == gen);
}

void cetrafs_sb_corrupt(struct super_block *sb, u64 ino)
{
    cetrafs_sb_corrupt_gen(sb, ino, CETRAFS_BAD_GEN_UNKNOWN);
}

/* TEST ONLY: store every mark as "generation unknown", i.e. keyed by
 * the number alone -- ctest damage-incarnation's negative control. */
static bool cetrafs_damage_mark_any_gen;
cetrafs_test_param(damage_mark_any_gen, cetrafs_damage_mark_any_gen, bool, 0644);
MODULE_PARM_DESC(damage_mark_any_gen, "TEST ONLY: a damage mark covers every incarnation of the number");

void cetrafs_sb_corrupt_inode(struct inode *inode)
{
    cetrafs_sb_corrupt_owner(inode->i_sb, inode->i_ino, cetrafs_inode_get_generation(inode));
}

/* A block owned by file 'ino' at 'generation' is damaged: the mark that
 * refuses its writes. Generation 0 is unknown and covers every one. */
void cetrafs_sb_corrupt_owner(struct super_block *sb, u64 ino, u64 generation)
{
    cetrafs_sb_corrupt_gen(sb, ino,
                           READ_ONCE(cetrafs_damage_mark_any_gen) ? CETRAFS_BAD_GEN_UNKNOWN
                                                                  : cetrafs_bad_gen(generation));
}

static void cetrafs_sb_corrupt_gen(struct super_block *sb, u64 ino, unsigned long gen)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return;
    if (cetrafs_error_policy_off) {
        pr_err("%s: corruption in ino=%llu IGNORED (error_policy_off)\n", sb->s_id, (unsigned long long) ino);
        return;
    }
    if (atomic_inc_return(&sbi->corruptions) == 1)
        pr_err("%s: this volume has damaged metadata -- unmount it on every node and run fsck.cetra\n",
               sb->s_id);
    /* Stored unless the mark already there covers this incarnation: an
     * unknown generation covers every one, a known one only itself. A
     * mark left by an earlier incarnation -- a peer deleted the file and
     * reused the number, which this node never allocates so
     * cetrafs_sb_ino_reborn() never erased it -- is replaced; keeping it
     * let unlink, truncate and evict through on a file just found
     * damaged. */
    if (ino && ino <= ULONG_MAX && !cetrafs_bad_mark_covers(xa_load(&sbi->bad_inos, (unsigned long) ino), gen)) {
        /* GFP_NOFS: found on read paths that may hold fs locks. If the
         * entry cannot be stored the write gate cannot see it, so say
         * so rather than imply a protection that is not there. */
        if (xa_err(xa_store(&sbi->bad_inos, (unsigned long) ino, xa_mk_value(gen), GFP_NOFS)))
            pr_err("%s: ino=%llu is damaged but could not be recorded -- writes to it are NOT refused\n",
                   sb->s_id, (unsigned long long) ino);
        else
            pr_err("%s: ino=%llu is damaged -- refusing every write to it until it is repaired\n", sb->s_id,
                   (unsigned long long) ino);
    }
    if (sbi->corruption_stop) {
        if (sbi->errors_panic)
            panic("cetrafs %s: damaged metadata in ino=%llu (corruption=stop, errors=panic)\n", sb->s_id,
                  (unsigned long long) ino);
        cetrafs_sb_stop(sb, CETRAFS_STOP_CORRUPTION, "damaged metadata found (corruption=stop)");
    }
}

unsigned int cetrafs_sb_corruptions(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? (unsigned int) atomic_read(&sbi->corruptions) : 0;
}

/* TEST ONLY: the heartbeat does not put this mount's damage on the device
 * -- the negative control for the lasting mark. */
static bool cetrafs_damage_record_off;
cetrafs_test_param(damage_record_off, cetrafs_damage_record_off, bool, 0644);
MODULE_PARM_DESC(damage_record_off, "TEST ONLY: never record damage in the superblock's needs-fsck mark");

struct cetrafs_damage_ctx {
    u64 now;
    u32 node;
    bool already;
};

static int cetrafs_damage_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_damage_ctx *c = priv;
    cetrafs_superblock_t *s = image;

    if (len < sizeof(*s))
        return -EINVAL;
    /* Edit only a superblock that verifies: anything else is torn (the
     * next beat tries again) or not ours to stamp. */
    if (le32_to_cpu(s->magic) != CETRAFS_MAGIC || cetrafs_check_sb_crc(s, sizeof(*s), s->checksum))
        return -EUCLEAN;
    if (s->fsck_needed_since) {
        c->already = true;
        return 1; /* somebody recorded damage first; theirs stands */
    }
    s->fsck_needed_since = cpu_to_le64(c->now);
    s->fsck_needed_node = cpu_to_le32(c->node);
    cetrafs_sb_restamp(s);
    return 0;
}

/*
 * Put this mount's damage on the device, once: the lasting "needs fsck"
 * mark in the superblock (cetrafs_superblock_t.fsck_needed_since). Called
 * by the heartbeat, which is sleepable, drained at unmount and the one
 * place every mount already reads block 0 from -- never from
 * cetrafs_sb_corrupt() itself, which runs on read paths holding fs locks
 * and inside compare-and-write mutators. A failed swap is tried again on
 * the next beat. A mount that STOPS on damage (corruption=stop) writes
 * nothing after the stop, so the mark comes from whichever node meets
 * the damage next, or from fsck.
 */
void cetrafs_sb_record_damage(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    struct cetrafs_damage_ctx ctx = {.now = (u64) ktime_get_real_seconds()};
    int rc;

    if (!sbi || READ_ONCE(sbi->damage_recorded) || !atomic_read(&sbi->corruptions) ||
        READ_ONCE(cetrafs_damage_record_off) || cetrafs_sb_is_fenced(sb))
        return;
    if (cetrafs_sb_get_node_id(sb, &ctx.node))
        return;
    rc = cetrafs_cas_record(sb, CETRAFS_SB_BLOCK_NR, cetrafs_damage_mutate, &ctx);
    if (rc) {
        pr_warn_ratelimited("%s: could not record on the volume that it needs fsck (%d) -- trying again on the "
                            "next heartbeat\n",
                            sb->s_id, rc);
        return;
    }
    WRITE_ONCE(sbi->damage_recorded, true);
    if (ctx.already)
        return;
    WRITE_ONCE(sbi->fsck_needed_node, ctx.node);
    WRITE_ONCE(sbi->fsck_needed_since, ctx.now);
    pr_err("%s: recorded on the volume that it needs fsck -- every node will report it until fsck.cetra -r "
           "finds it clean\n",
           sb->s_id);
}

/* The lasting mark as this node last read it: 0 = none. */
u64 cetrafs_sb_fsck_needed(struct super_block *sb, u32 *out_node)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return 0;
    if (out_node)
        *out_node = READ_ONCE(sbi->fsck_needed_node);
    return READ_ONCE(sbi->fsck_needed_since);
}

/* Was damage found in THIS incarnation of the inode (or in one of its
 * number whose generation was unknown)? */
bool cetrafs_sb_inode_damaged(struct inode *inode)
{
    struct cetrafs_sb_info *sbi = inode->i_sb->s_fs_info;
    unsigned long gen;
    void *v;

    if (!sbi || inode->i_ino > ULONG_MAX)
        return false;
    v = xa_load(&sbi->bad_inos, (unsigned long) inode->i_ino);
    if (!v)
        return false;
    gen = xa_to_value(v);
    return gen == CETRAFS_BAD_GEN_UNKNOWN || gen == cetrafs_bad_gen(cetrafs_inode_get_generation(inode));
}

/* This node is giving 'ino' a new record: whatever was damaged was the
 * old incarnation's. */
void cetrafs_sb_ino_reborn(struct super_block *sb, u64 ino)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi && ino && ino <= ULONG_MAX)
        xa_erase(&sbi->bad_inos, (unsigned long) ino);
}

bool cetrafs_sb_errors_panic(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && sbi->errors_panic;
}

bool cetrafs_sb_corruption_stop(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && sbi->corruption_stop;
}

bool cetrafs_sb_posix_lock_local(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && sbi->posix_lock_local;
}

/*
 * FS_IOC_SHUTDOWN, the call `xfs_io -x -c shutdown` and a cluster
 * manager's software fence make: stop this mount now
 * (cetrafs_sb_stop()). NOLOGFLUSH stops at once, as a crash would.
 * DEFAULT and LOGFLUSH first sync the mount, the one moment its own
 * writes are still trusted; cetrafs has no log separate from its
 * metadata, so the two are the same.
 */
long cetrafs_shutdown_ioctl(struct super_block *sb, u32 __user *argp)
{
    u32 flags;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;
    if (get_user(flags, argp))
        return -EFAULT;
    if (flags > FS_SHUTDOWN_FLAGS_NOLOGFLUSH)
        return -EINVAL;
    if (flags != FS_SHUTDOWN_FLAGS_NOLOGFLUSH && !cetrafs_sb_is_fenced(sb)) {
        down_read(&sb->s_umount);
        sync_filesystem(sb);
        up_read(&sb->s_umount);
    }
    cetrafs_sb_stop(sb, CETRAFS_STOP_MANUAL,
                    flags == FS_SHUTDOWN_FLAGS_NOLOGFLUSH ? "FS_IOC_SHUTDOWN (no flush)" : "FS_IOC_SHUTDOWN");
    return 0;
}

/*
 * The VFS entry points' answers. A stopped mount refuses every access
 * (-EIO); a damaged inode refuses writes (-EUCLEAN, "structure needs
 * cleaning", which is what it says).
 */
int cetrafs_read_gate(struct super_block *sb)
{
    return cetrafs_sb_is_fenced(sb) ? -EIO : 0;
}

int cetrafs_write_gate(struct inode *inode)
{
    if (cetrafs_sb_is_fenced(inode->i_sb))
        return -EIO;
    if (cetrafs_sb_inode_damaged(inode))
        return -EUCLEAN;
    return 0;
}

/*
 * TEST ONLY. Do not arm the lease: the control of
 * tests/kernel/lease_expiry.sh, the behaviour before the lease existed.
 */
static bool cetrafs_lease_disable;
cetrafs_test_param(lease_disable, cetrafs_lease_disable, bool, 0644);
MODULE_PARM_DESC(lease_disable, "TEST ONLY: never arm the in-core lease");

/*
 * The clock a lease is judged by: boottime, in ns. jiffies stop across a
 * suspend and a stunned guest's catch up only as its ticks are
 * replayed, so a lease judged by them read as still running for exactly
 * the time a peer's watch -- on a clock that did not stop -- counted it
 * as lapsed (audit 2026-11-15 A-15). Boottime counts every second.
 *
 * TEST ONLY: lease_clock_skew_secs is added to it -- seconds this node
 * "slept", which boottime sees and jiffies do not -- so a suite can wake
 * it past its lease without suspending the box.
 */
static unsigned int cetrafs_lease_clock_skew_secs;
cetrafs_test_param(lease_clock_skew_secs, cetrafs_lease_clock_skew_secs, uint, 0644);
MODULE_PARM_DESC(lease_clock_skew_secs, "TEST ONLY: seconds added to the clock leases are judged by");

/* TEST ONLY: judge leases by jiffies, as before -- which do not see the
 * skew above, as they do not see a suspend (lease_clock_boottime.sh's
 * control). Read once per mount's life: set it before mounting. */
static bool cetrafs_lease_clock_jiffies;
cetrafs_test_param(lease_clock_jiffies, cetrafs_lease_clock_jiffies, bool, 0644);

u64 cetrafs_lease_clock(void)
{
    if (READ_ONCE(cetrafs_lease_clock_jiffies))
        return jiffies_to_nsecs(get_jiffies_64() - INITIAL_JIFFIES);
    return ktime_get_boottime_ns() + (u64) READ_ONCE(cetrafs_lease_clock_skew_secs) * NSEC_PER_SEC;
}

/* TEST ONLY: the lease is three beats whatever the window, as before
 * audit 2026-11-14 O1 -- the control of tests/kernel/lease_window.sh. */
static bool cetrafs_lease_three_beats;
cetrafs_test_param(lease_three_beats, cetrafs_lease_three_beats, bool, 0644);
MODULE_PARM_DESC(lease_three_beats, "TEST ONLY: size the lease at three beats, not from the stale window");

static void cetrafs_sb_lease_work(struct work_struct *w)
{
    struct cetrafs_sb_info *sbi = container_of(w, struct cetrafs_sb_info, lease_work);

    cetrafs_sb_stop(sbi->sb, CETRAFS_STOP_LEASE,
                    "this node's lease expired -- no heartbeat renewal reached the device in time, so peers may "
                    "already treat it as dead");
}

/*
 * A renewal that STARTED at jiffies 't0' reached the device: extend the
 * lease to 'lease_secs' from t0 (cetrafs_sb_lease_secs()). The first one
 * arms it. Nothing
 * extends a lease that has lapsed -- by then a peer may have reclaimed
 * from us, and the only way back is a remount.
 */
/*
 * The lease a renewal earns, in seconds: the soonest any peer may call
 * this node dead (cetrafs_peer_window_floor_secs() of what the row
 * advertises), less one beat of margin for I/O already issued when the
 * lease runs out. 'imin'/'smin' are the smallest interval and window
 * the renewal could have advertised, 'imax' the longest beat it could
 * have run at. With the default 15 s beat and 120 s window that is
 * 105 s: a controller failover or a queued multipath stall up to that
 * long is ridden out. It used to be three beats whatever the window
 * (45 s), so every node of a cluster stopped together on a 60 s stall
 * nobody could have reclaimed anything in (audit 2026-11-14 O1).
 */
unsigned int cetrafs_sb_lease_secs(unsigned int imin, unsigned int imax, unsigned int smin)
{
    u32 w = cetrafs_peer_window_floor_secs(imin, smin);

    if (READ_ONCE(cetrafs_lease_three_beats))
        return imin * 3;
    return w > imax ? w - imax : w / 2;
}

void cetrafs_sb_lease_renewed(struct super_block *sb, u64 t0, unsigned int lease_secs)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return;
    cetrafs_sb_note_renewal(sbi);
    if (!lease_secs || test_bit(0, &sbi->lease_lost))
        return;
    if (!READ_ONCE(sbi->lease_active)) {
        /* Every mount, CAW or not. Without CAW the gate admits no peer
         * BESIDE us, but it admits one AFTER us the moment we look dead
         * (a serial hand-over), and if we only stalled we must stop
         * before we write again -- the premise every "a stale node's
         * writes never land" rests on (review E1). */
        if (cetrafs_lease_disable)
            return;
        if (!sbi->lease_work_ready) {
            sbi->sb = sb;
            INIT_WORK(&sbi->lease_work, cetrafs_sb_lease_work);
            sbi->lease_work_ready = true;
        }
    }
    WRITE_ONCE(sbi->lease_until, t0 + (u64) lease_secs * NSEC_PER_SEC);
    smp_wmb(); /* the deadline before the flag that makes it count */
    WRITE_ONCE(sbi->lease_active, true);
}

/*
 * Renew this node's row from a long phase of the MOUNT, before the
 * heartbeat exists (audit R19). Registration lands one beat and the
 * heartbeat's first tick is the next, and between the two the mount can
 * wait minutes for a peer's replay claim to clear -- long enough for
 * every peer to judge this node stale and fence it before it has done
 * anything at all. Called from those waits and from every phase that
 * scales with the volume (the claim sweep, the recount, the drain);
 * renews at most once per heartbeat interval. Each renewal extends the
 * lease, which registration armed: a mount phase that stalls past it
 * stops the mount, because peers may reclaim from it by then (audit
 * 2026-11-14 F1).
 *
 * Returns -EPERM / -EOWNERDEAD if the row says this node was fenced or
 * displaced meanwhile: the mount must fail, not go on.
 */
/* A renewal from the mount, started at 't0', landed: arm or extend the
 * lease as a heartbeat renewal does. */
void cetrafs_sb_mount_lease(struct super_block *sb, u64 t0)
{
    unsigned int i = cetrafs_heartbeat_interval_secs(sb);

    cetrafs_sb_lease_renewed(sb, t0, cetrafs_sb_lease_secs(i, i, cetrafs_sb_stale_secs(sb)));
}

int cetrafs_sb_mount_beat(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    unsigned long t0;
    u64 lt0;
    int ret;

    if (!sbi || !sbi->node_registered || sbi->hb)
        return 0; /* not registered yet, or the heartbeat beats for us */
    if (sbi->mount_beat_next && time_before(jiffies, sbi->mount_beat_next))
        return 0;
    t0 = jiffies;
    lt0 = cetrafs_lease_clock();
    sbi->mount_beat_next = t0 + (unsigned long) cetrafs_heartbeat_interval_secs(sb) * HZ;
    if (!sbi->mount_beat_next)
        sbi->mount_beat_next = 1;
    ret = cetrafs_node_renew_heartbeat(sb, sbi->node_id);
    if (ret == 0)
        cetrafs_sb_mount_lease(sb, lt0);
    if (ret == -EPERM || ret == -EOWNERDEAD) {
        pr_err("%s: this node was fenced while it was still mounting -- refusing the mount\n", sb->s_id);
        return ret;
    }
    if (ret)
        pr_warn("%s: could not renew this node's row while mounting: %d\n", sb->s_id, ret);
    return 0;
}

void cetrafs_sb_note_unclean_reattach(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi)
        sbi->reattached_unclean = true;
}

bool cetrafs_sb_unclean_reattach(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && sbi->reattached_unclean;
}

/*
 * A read-only mount writes nothing to the volume through the free path:
 * no bitmap bit, no peer's pending-free queue (audit 2026-11-06 L15).
 * The deciders say so first (evict); this is the backstop at the choke
 * points, so a path nobody thought of fails loudly instead of writing.
 */
bool cetrafs_sb_ro_refuses(struct super_block *sb, const char *what)
{
    if (!sb_rdonly(sb))
        return false;
    pr_err_ratelimited("%s: read-only mount -- refusing %s; a read-only mount writes nothing\n", sb->s_id, what);
    return true;
}

/* TEST ONLY: boundaries trust the local lease clock alone (B-18's control). */
static bool cetrafs_fence_witness_off;
cetrafs_test_param(fence_witness_off, cetrafs_fence_witness_off, bool, 0644);
static atomic64_t cetrafs_fence_witness_reads = ATOMIC64_INIT(0);
/* TEST ONLY: as before review F-8 -- a witness under a second old by
 * jiffies is trusted, and the journal, tree-batch and record-publish
 * gates ask the clock alone (cetrafs_sb_fence_witnessed_f8()). */
bool cetrafs_fence_witness_f8_off;
cetrafs_test_param(fence_witness_f8_off, cetrafs_fence_witness_f8_off, bool, 0644);

/*
 * cetrafs_sb_is_fenced(), and the device's word on it before a boundary
 * writes shared state. The lease is judged on jiffies, and a node a
 * hypervisor paused may resume with that clock where it stopped: a
 * peer's verdict and fence_epoch bump are then invisible to every gate
 * here until the next heartbeat tick -- up to a whole beat in which the
 * boundary flush writes bitmap blocks and the discard workers UNMAP runs
 * a peer may own now (audit 2026-11-15 B-18). So a boundary reads this
 * node's row forced-fresh first (cetrafs_node_self_fence_check()) and
 * fences on a moved epoch.
 * Not rate-limited by time: a "last read under a second ago" judged on
 * jiffies is the same clock, and the first second after a resume trusted
 * it (review F-8). Callers arriving together share ONE read -- one that
 * STARTED after they arrived; a read already under way when a caller came
 * may predate its pause. Boundaries only, never the per-block path.
 * A read that fails is not evidence: the clock's answer stands.
 */
bool cetrafs_sb_fence_witnessed(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool fenced = false;
    u32 my_node_id;
    u64 since;

    if (!sbi)
        return false;
    if (cetrafs_sb_is_fenced(sb))
        return true;
    if (READ_ONCE(cetrafs_fence_witness_off))
        return false;
    if (cetrafs_sb_get_node_id(sb, &my_node_id))
        return false;
    if (READ_ONCE(cetrafs_fence_witness_f8_off) && sbi->witness_done &&
        !time_after(jiffies, READ_ONCE(sbi->witness_at) + HZ))
        return false; /* test-only: the old clock-judged skip */
    since = READ_ONCE(sbi->witness_started);
    mutex_lock(&sbi->witness_mutex);
    if (sbi->witness_done <= since) {
        u64 gen = sbi->witness_started + 1;

        WRITE_ONCE(sbi->witness_started, gen);
        atomic64_inc(&cetrafs_fence_witness_reads);
        if (cetrafs_node_self_fence_check(sb, my_node_id, &fenced) == 0) {
            sbi->witness_done = gen;
            WRITE_ONCE(sbi->witness_at, jiffies);
            if (fenced) {
                cetrafs_node_log_fencer(sb, my_node_id);
                cetrafs_sb_fence(sb, "our Node Registry lease was revoked by a peer (seen at a boundary)");
            }
        }
    }
    mutex_unlock(&sbi->witness_mutex);
    return cetrafs_sb_is_fenced(sb);
}

/* The gates review F-8 added: the journal, tree batches, the record publish. */
bool cetrafs_sb_fence_witnessed_f8(struct super_block *sb)
{
    if (READ_ONCE(cetrafs_fence_witness_f8_off))
        return cetrafs_sb_is_fenced(sb);
    return cetrafs_sb_fence_witnessed(sb);
}

u64 cetrafs_sb_fence_witness_reads(void)
{
    return (u64) atomic64_read(&cetrafs_fence_witness_reads);
}

/* TEST ONLY: a device smaller than the volume goes unnoticed, as before
 * audit 2026-11-15 M-45 (tests/kernel/device_shrink_stops.sh). */
static bool cetrafs_device_shrink_ignored;
cetrafs_test_param(device_shrink_ignored, cetrafs_device_shrink_ignored, bool, 0644);
MODULE_PARM_DESC(device_shrink_ignored, "TEST ONLY: a LUN shrunk under the mount is not noticed");

/* TEST ONLY: the next N device-size samples read device_size_fake_blocks
 * instead of the device's size -- a revalidate in flight, which a loop
 * device cannot show without losing its data. */
static int cetrafs_device_size_fake_ticks;
cetrafs_test_param(device_size_fake_ticks, cetrafs_device_size_fake_ticks, int, 0644);
MODULE_PARM_DESC(device_size_fake_ticks, "TEST ONLY: the next N device-size samples read device_size_fake_blocks");
static unsigned long long cetrafs_device_size_fake_blocks;
cetrafs_test_param(device_size_fake_blocks, cetrafs_device_size_fake_blocks, ullong, 0644);
MODULE_PARM_DESC(device_size_fake_blocks, "TEST ONLY: the device size a faked sample reads, in blocks");

/* TEST ONLY: one smaller sample, zero included, stops the mount, as
 * 28a22bf did (tests/kernel/device_shrink_stops.sh's F-39 control). */
static bool cetrafs_device_shrink_one_sample;
cetrafs_test_param(device_shrink_one_sample, cetrafs_device_shrink_one_sample, bool, 0644);
MODULE_PARM_DESC(device_shrink_one_sample, "TEST ONLY: a single short device-size sample, zero included, stops the mount");

/*
 * Is the device still as large as the volume? Checked at mount and when
 * a peer's grow is adopted, and nowhere else: a LUN shrunk under a live
 * mount was never noticed (audit 2026-11-15 M-45), and every block past
 * the new end -- data, Block Group bitmaps, a grow's reserve -- read and
 * wrote as an I/O error one at a time, each judged on its own. A volume
 * whose device lost its tail is not one this node knows any more: stop,
 * as for any contradiction between memory and disk. A field read and a
 * compare, once per heartbeat tick.
 */
void cetrafs_sb_check_device_size(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    struct cetrafs_bg_layout *l = cetrafs_sb_layout_of(sbi);
    u64 have, need;

    if (!l || !sb->s_bdev || READ_ONCE(cetrafs_device_shrink_ignored))
        return;
    have = bdev_nr_bytes(sb->s_bdev) / CETRAFS_BLOCK_SIZE;
    need = le64_to_cpu(l->raw.total_blocks);
    if (READ_ONCE(cetrafs_device_size_fake_ticks) > 0) {
        /* TEST ONLY: this sample reads as the fake size (see the parameter) */
        WRITE_ONCE(cetrafs_device_size_fake_ticks, cetrafs_device_size_fake_ticks - 1);
        have = READ_ONCE(cetrafs_device_size_fake_blocks);
        pr_info("%s: TEST device size sample faked: %llu blocks\n", sb->s_id, (unsigned long long) have);
    }
    /*
     * Zero is no size at all: a plain sd device whose READ CAPACITY
     * fails during a controller failover or a LUN reset reads 0 until
     * its next good revalidate, and is back at full size seconds later.
     * A device really gone is the removal hook's (CETRAFS_STOP_DEVICE_GONE).
     * And a shortfall must hold for two ticks in a row: one sample
     * stopped -- under errors=panic, panicked -- a host whose LUN was
     * only being revalidated (audit 2026-11-15 F-39).
     */
    if (have >= need || (have == 0 && !READ_ONCE(cetrafs_device_shrink_one_sample))) {
        WRITE_ONCE(sbi->shrink_seen, 0);
        return;
    }
    if (!READ_ONCE(cetrafs_device_shrink_one_sample) && READ_ONCE(sbi->shrink_seen) != have) {
        pr_warn("%s: the device reads %llu blocks, the volume needs %llu -- stopping if it still does at the next "
                "beat\n",
                sb->s_id, (unsigned long long) have, (unsigned long long) need);
        WRITE_ONCE(sbi->shrink_seen, have);
        return;
    }
    cetrafs_sb_fatal(sb, "the device shrank under the mount: %llu blocks, the volume needs %llu",
                     (unsigned long long) have, (unsigned long long) need);
}

bool cetrafs_sb_is_fenced(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return false;
    if (READ_ONCE(sbi->fenced) || test_bit(0, &sbi->lease_lost))
        return true;
    if (READ_ONCE(sbi->lease_active)) {
        smp_rmb();
        if (cetrafs_lease_clock() > READ_ONCE(sbi->lease_until)) {
            /* One-way: a renewal that lands later must not reopen
             * what a peer may already have reclaimed. */
            if (!test_and_set_bit(0, &sbi->lease_lost))
                schedule_work(&sbi->lease_work);
            return true;
        }
    }
    return false;
}

const struct cetrafs_caw_info *cetrafs_sb_caw(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? &sbi->caw : NULL;
}

/* True when this mount can use atomic compare-and-swap for cluster
 * coordination; false means a single-node mount whose claims take the
 * node-local fallback (cetrafs_cas_nocaw()). */
/*
 * TEST ONLY. Make the MOUNT decisions of a node with atomic CAW on a
 * device without it: skip the single-mounter gate, advertise no
 * CETRAFS_NODE_CAP_NO_CAW, and refuse a live peer that does advertise it.
 * The swaps themselves still take the no-CAW fallback. On a shared device
 * this lets two nodes mount with nothing arbitrating them -- it exists only
 * so tests/kernel/caw_mixed_cluster.sh can reach the CAW side's check on a
 * loop device.
 */
static bool cetrafs_mount_assume_caw;
cetrafs_test_param(mount_assume_caw, cetrafs_mount_assume_caw, bool, 0644);
MODULE_PARM_DESC(mount_assume_caw, "TEST ONLY: mount gating behaves as on a device with atomic CAW");

/* The mount's view: does this node join the cluster as one with atomic
 * CAW? Equal to cetrafs_sb_caw_available() outside tests. */
bool cetrafs_sb_mount_has_caw(struct super_block *sb)
{
    return cetrafs_sb_caw_available(sb) || READ_ONCE(cetrafs_mount_assume_caw);
}

bool cetrafs_sb_caw_available(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && sbi->caw.max_caw_blocks > 0 && sbi->caw.logical_block_size > 0 &&
           CETRAFS_BLOCK_SIZE % sbi->caw.logical_block_size == 0;
}

/* Seconds after an unclean re-attach before the own-claim sweep runs a
 * second time; 0 turns it off. Past the longest steal-to-give-back a
 * peer's reclaim can take (a fence and a journal replay). */
static unsigned int cetrafs_own_claim_resweep_secs = 600;
module_param_named(own_claim_resweep_secs, cetrafs_own_claim_resweep_secs, uint, 0644);
MODULE_PARM_DESC(own_claim_resweep_secs,
                 "seconds after an unclean re-attach before this node's claims are swept again (0 = off, default 600)");

static bool cetrafs_sb_resweep_stop(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return READ_ONCE(sbi->cold_closing);
}

static void cetrafs_sb_resweep_work(struct work_struct *w)
{
    struct cetrafs_sb_info *sbi = container_of(to_delayed_work(w), struct cetrafs_sb_info, resweep_work);
    struct super_block *sb = sbi->sb;
    int n;

    n = cetrafs_lock_resweep_own_claims(sb, sbi->node_id, cetrafs_sb_resweep_stop);
    if (n < 0)
        pr_warn("the late sweep of this node's claims could not finish: %d\n", n);
    else
        pr_info("late sweep of this node's claims: %d cleared\n", n);
}

/* Queue an inode's cold-tree reconcile. False when it was not queued --
 * already pending, or the mount is closing -- and the caller then drops
 * the reference it took for the work. */
bool cetrafs_sb_queue_cold(struct super_block *sb, struct work_struct *w)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool queued = false;

    if (!sbi)
        return false;
    spin_lock(&sbi->cold_lock);
    if (!sbi->cold_closing && sbi->cold_wq)
        queued = queue_work(sbi->cold_wq, w);
    spin_unlock(&sbi->cold_lock);
    return queued;
}

/* Stop queueing reconciles and run the ones already queued. After this
 * no reconcile holds an inode reference. Called by kill_sb before the
 * VFS evicts the inode cache, while the mount is still fully up, so an
 * iput() here that evicts a deleted file does it with everything a free
 * needs. A tree left cold stays untrusted, which only means forced-fresh
 * reads for the rest of the unmount. */
void cetrafs_sb_cold_close(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    LIST_HEAD(parked);

    if (!sbi)
        return;
    spin_lock(&sbi->cold_lock);
    sbi->cold_closing = true;
    spin_unlock(&sbi->cold_lock);
    /* Nothing queues it after cold_closing (fill_super checks under
     * cold_lock); a pass in progress sees cold_closing and stops early. */
    if (sbi->cold_wq)
        cancel_delayed_work_sync(&sbi->resweep_work);
    /* A tick's pass may hold entries it took off the park: let it finish
     * (its queueing is refused now, and it drops those references). Then
     * nothing can park again, and what is parked is ours to drop. */
    mutex_lock(&sbi->cold_retry_mutex);
    spin_lock(&sbi->cold_lock);
    list_splice_init(&sbi->cold_parked, &parked);
    sbi->cold_parked_n = 0;
    spin_unlock(&sbi->cold_lock);
    mutex_unlock(&sbi->cold_retry_mutex);
    cetrafs_lock_cold_drop_parked(sb, &parked);
    if (sbi->cold_wq)
        flush_workqueue(sbi->cold_wq);
}

/* Park a reconcile that could not read its record, with its reference,
 * for the heartbeat tick. False when the mount is closing, or when the
 * entry is parked already -- a new mark ran the work while it waited,
 * and the park still holds the reference it was parked with -- or sits
 * on a pass's private list about to be queued: the caller drops the
 * reference it ran with. Linking it twice corrupted the list and leaked
 * one reference (tests/kernel/cold_reconcile_retries.sh). */
bool cetrafs_sb_cold_park(struct super_block *sb, struct list_head *e)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool parked = false;

    if (!sbi)
        return false;
    spin_lock(&sbi->cold_lock);
    if (!sbi->cold_closing && list_empty(e)) {
        list_add_tail(e, &sbi->cold_parked);
        sbi->cold_parked_n++;
        parked = true;
    }
    spin_unlock(&sbi->cold_lock);
    return parked;
}

/* False when there is nothing to do (no mount, or nothing parked). */
bool cetrafs_sb_cold_retry_begin(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || list_empty_careful(&sbi->cold_parked))
        return false;
    mutex_lock(&sbi->cold_retry_mutex);
    return true;
}

void cetrafs_sb_cold_retry_end(struct super_block *sb)
{
    mutex_unlock(&((struct cetrafs_sb_info *) sb->s_fs_info)->cold_retry_mutex);
}

/* The whole park, for one pass between _retry_begin() and _end(). */
void cetrafs_sb_cold_take(struct super_block *sb, struct list_head *out)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    spin_lock(&sbi->cold_lock);
    list_splice_init(&sbi->cold_parked, out);
    sbi->cold_parked_n = 0;
    spin_unlock(&sbi->cold_lock);
}

/* Take one entry off a list _take() or close returned, under the lock a
 * concurrent _park() reads it with. */
void cetrafs_sb_cold_unpark(struct super_block *sb, struct list_head *e)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return;
    spin_lock(&sbi->cold_lock);
    list_del_init(e);
    spin_unlock(&sbi->cold_lock);
}

unsigned int cetrafs_sb_cold_parked_count(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    unsigned int n;

    if (!sbi)
        return 0;
    spin_lock(&sbi->cold_lock);
    n = sbi->cold_parked_n;
    spin_unlock(&sbi->cold_lock);
    return n;
}

bool cetrafs_sb_defrag_draining(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && READ_ONCE(sbi->defrag_draining);
}

/* May this mount defragment at all? False stops the janitor AND the
 * ioctl, so nothing here pins a file's exclusive lock for an
 * optimisation and no peer is ever refused a read because of one. */
bool cetrafs_sb_defrag_enabled(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && READ_ONCE(sbi->defrag_enabled);
}

/* The cross-node exclusive open lock (lock.c). Set once at mount from the
 * nofilelock option; never changes for the life of the mount. */
bool cetrafs_sb_file_lock_enabled(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return !sbi || sbi->file_lock_enabled; /* default on if somehow unset */
}

/* TEST ONLY: every mount-time watch watches a row again, as before
 * BM-22 (tests/kernel/mount_watch_once.sh). */
static bool cetrafs_row_silent_forget;
cetrafs_test_param(row_silent_forget, cetrafs_row_silent_forget, bool, 0644);
MODULE_PARM_DESC(row_silent_forget, "TEST ONLY: a mount watches a row again that it already watched stand still");

/*
 * A row this mount watched stand still for a whole window. Its verdict
 * holds for as long as the row still reads at that mark: silent from the
 * watch's start until now, which is longer than the window. Three
 * consecutive watches of the same dead row -- the mode walk, the
 * re-attach, the post-registration re-check -- cost a mount six minutes
 * (audit 2026-11-15 BM-22). Mount-time only: one task, before the
 * heartbeat.
 */
void cetrafs_sb_row_silent_note(struct super_block *sb, u32 idx, const cetrafs_node_entry_t *ne)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 count = raw_sb ? le32_to_cpu(raw_sb->node_table_count) : 0;

    if (!sbi || idx >= count)
        return;
    if (!sbi->row_silent) {
        sbi->row_silent = kcalloc(count, sizeof(*sbi->row_silent), GFP_KERNEL);
        sbi->row_silent_valid = bitmap_zalloc(count, GFP_KERNEL);
        if (!sbi->row_silent || !sbi->row_silent_valid) {
            kfree(sbi->row_silent);
            bitmap_free(sbi->row_silent_valid);
            sbi->row_silent = NULL;
            sbi->row_silent_valid = NULL;
            return; /* only the saving is lost: the next watch watches */
        }
    }
    cetrafs_row_mark_of(&sbi->row_silent[idx], ne);
    set_bit(idx, sbi->row_silent_valid);
}

bool cetrafs_sb_row_silent(struct super_block *sb, u32 idx, const cetrafs_node_entry_t *ne)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);

    if (!sbi || !sbi->row_silent || READ_ONCE(cetrafs_row_silent_forget) || !raw_sb ||
        idx >= le32_to_cpu(raw_sb->node_table_count) || !test_bit(idx, sbi->row_silent_valid))
        return false;
    return cetrafs_row_mark_same(&sbi->row_silent[idx], ne);
}

const char *cetrafs_sb_copy_state_name(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return "unknown";
    return sbi->sb_copy_state == CETRAFS_SB_COPY_OK      ? "ok"
           : sbi->sb_copy_state == CETRAFS_SB_COPY_STALE ? "stale"
                                                         : "bad";
}

/* May the BACKGROUND janitor run? A manual defrag.cetra is unaffected
 * by this one; cetrafs_sb_defrag_enabled() is what covers both. */
bool cetrafs_sb_auto_defrag_enabled(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && READ_ONCE(sbi->auto_defrag_enabled);
}

bool cetrafs_sb_discard_enabled(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && READ_ONCE(sbi->discard_enabled);
}

struct cetrafs_inline_discard *cetrafs_sb_inline_discard(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    return sbi ? sbi->inline_discard : NULL;
}

void cetrafs_sb_set_discard_enabled(struct super_block *sb, bool on)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi)
        WRITE_ONCE(sbi->discard_enabled, on);
}

struct mutex *cetrafs_sb_trim_mutex(struct super_block *sb)
{
    return &((struct cetrafs_sb_info *) sb->s_fs_info)->trim_mutex;
}

/* TEST ONLY: the free paths ignore a FITRIM's hold -- the negative
 * control for it (tests/kernel/fstrim_claim.sh). */
static bool cetrafs_trim_hold_off;
cetrafs_test_param(trim_hold_off, cetrafs_trim_hold_off, bool, 0644);
MODULE_PARM_DESC(trim_hold_off, "TEST ONLY: free paths may clear bits a FITRIM has claimed");

/* Under alloc_mutex, both. */
void cetrafs_sb_set_trim_claim(struct super_block *sb, u32 bg_id, u64 lba, u64 count)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    lockdep_assert_held(&sbi->alloc_mutex);
    sbi->trim_bg = bg_id;
    sbi->trim_lba = lba;
    sbi->trim_count = count;
}

bool cetrafs_sb_trim_holds(struct super_block *sb, u64 lba)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    lockdep_assert_held(&sbi->alloc_mutex);
    if (READ_ONCE(cetrafs_trim_hold_off))
        return false; /* test-only; see the parameter */
    return sbi->trim_count && lba >= sbi->trim_lba && lba < sbi->trim_lba + sbi->trim_count;
}

bool cetrafs_sb_bg_discard_pending(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    return sbi && xa_load(&sbi->discard_pending, bg_id);
}

/* TEST ONLY: the owned-bit derivation ignores an outstanding discard --
 * the negative control of tests/kernel/discard_pending_durable.sh. */
static bool cetrafs_discard_pending_ignore;
cetrafs_test_param(discard_pending_ignore, cetrafs_discard_pending_ignore, bool, 0644);
MODULE_PARM_DESC(discard_pending_ignore, "TEST ONLY: a group with a discard outstanding may still be allocated from");

/* For the owned-bit derivations, which run under owned_lock (a spinlock;
 * xa_load is RCU). */
static bool cetrafs_sb_bg_discard_pending_ignored(struct cetrafs_sb_info *sbi, u32 bg_id)
{
    return !READ_ONCE(cetrafs_discard_pending_ignore) && xa_load(&sbi->discard_pending, bg_id);
}

/* TEST ONLY: the next store of a pending discard mark fails (review U5). */
static bool cetrafs_discard_pending_store_fail;
cetrafs_test_param(discard_pending_store_fail, cetrafs_discard_pending_store_fail, bool, 0644);
MODULE_PARM_DESC(discard_pending_store_fail, "TEST ONLY: the next pending-discard mark cannot be stored");

/* Mark (on) or clear a Block Group's outstanding discard. Returns true
 * when the call changed it.
 *
 * The mark is the only thing keeping an UNMAP that may still land out of
 * every allocator: unmarked, the drained group reads as neither ours nor
 * pending, no release pass revisits it, and its Zone Group can go to the
 * pool with it inside. So a mark that cannot be stored is a state this
 * mount cannot record, and stops it (ERRORS.md; review U5). */
bool cetrafs_sb_set_bg_discard_pending(struct super_block *sb, u32 bg_id, bool on)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (on) {
        int ret;

        if (cetrafs_discard_pending_store_fail) {
            cetrafs_discard_pending_store_fail = false;
            ret = -ENOMEM;
        } else {
            ret = xa_insert(&sbi->discard_pending, bg_id, xa_mk_value(1), GFP_NOFS);
        }
        if (ret == -EBUSY)
            return false;
        if (ret) {
            cetrafs_sb_fatal(sb, "BG %u: cannot record its outstanding discard (%d)", bg_id, ret);
            return false;
        }
        atomic_inc(&sbi->discard_pending_count);
        return true;
    }
    if (!xa_erase(&sbi->discard_pending, bg_id))
        return false;
    atomic_dec(&sbi->discard_pending_count);
    return true;
}

/* The first Block Group at or after 'from' with an outstanding
 * discard, or U32_MAX. */
u32 cetrafs_sb_next_discard_pending(struct super_block *sb, u32 from)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;
    unsigned long idx = from;

    if (!sbi || !atomic_read(&sbi->discard_pending_count))
        return U32_MAX;
    return xa_find(&sbi->discard_pending, &idx, U32_MAX - 1, XA_PRESENT) ? (u32) idx : U32_MAX;
}

unsigned int cetrafs_sb_discard_pending_count(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    return sbi ? (unsigned int) atomic_read(&sbi->discard_pending_count) : 0;
}

void cetrafs_sb_set_defrag_enabled(struct super_block *sb, bool on)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi)
        WRITE_ONCE(sbi->defrag_enabled, on);
}

void cetrafs_sb_set_auto_defrag_enabled(struct super_block *sb, bool on)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi)
        WRITE_ONCE(sbi->auto_defrag_enabled, on);
}

/*
 * The module-wide defaults, as a mount may take them. The parameters are
 * TEST ONLY knobs -- suites compress the timing far below what the
 * controls file allows an operator (5 s beat, 15 s window) -- but no
 * value written to them may reach a mount unbounded: a stale window of
 * 0 judged every peer dead at the floor of its advertised interval (a
 * split-brain lever), and a large beat overflowed `secs * 1000` and
 * `secs * 3 * HZ` (audit 2026-11-05, N5). The bounds are wide enough
 * for every suite (a 1 s beat and 3 s window) and nowhere near an
 * overflow. The beat stops at the 30 s every observer clamps an
 * advertised one to: a longer beat had peers call the node dead before
 * its lease ran out (audit 2026-11-14 C2).
 */
#define CETRAFS_PARAM_HB_MAX_SECS    CETRAFS_HB_INTERVAL_MAX_SECS /* what observers clamp a beat to (audit C2) */
#define CETRAFS_PARAM_STALE_MIN_SECS 3u

unsigned int cetrafs_param_hb_interval_secs(void)
{
    return clamp_t(unsigned int, READ_ONCE(cetrafs_hb_interval_secs), 1u, CETRAFS_PARAM_HB_MAX_SECS);
}

/* Bounded alone AND against the beat, as the controls file bounds an
 * operator's write: a window under CETRAFS_STALE_MIN_BEATS beats has
 * peers call this node dead while it still holds a lease of three beats
 * (hb_interval_secs=3600 with the default 120 s window was dead after
 * two minutes and leased for three hours, before the beat was capped). The window is raised to fit the beat;
 * 3 x CETRAFS_PARAM_HB_MAX_SECS is still under the cap. */
unsigned int cetrafs_param_stale_secs(void)
{
    /* Never above what peers honour (audit 2026-11-15 BM-41): the
     * parameter refuses it, and this keeps a mount from taking one. */
    unsigned int hi = READ_ONCE(cetrafs_stale_param_unbounded) ? 86400u : CETRAFS_STALE_MAX_SECS;
    unsigned int v = clamp_t(unsigned int, READ_ONCE(cetrafs_stale_secs), CETRAFS_PARAM_STALE_MIN_SECS, hi);

    return max_t(unsigned int, v, CETRAFS_STALE_MIN_BEATS * cetrafs_param_hb_interval_secs());
}

/* This mount's heartbeat period and staleness window. Both fall back to
 * the module-wide default when the mount is gone or the value is zero,
 * so no caller has to handle a nonsense interval. */
unsigned int cetrafs_sb_hb_interval_secs(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;
    unsigned int v = sbi ? READ_ONCE(sbi->hb_interval_secs) : 0;

    return v ? v : cetrafs_param_hb_interval_secs();
}

/* TEST ONLY: how long a creatorless half-landed record must stay so
 * before it is settled, in place of the stale window (-1: the window). */
static int cetrafs_half_landed_wait_secs = -1;
cetrafs_test_param(half_landed_wait_secs, cetrafs_half_landed_wait_secs, int, 0644);
MODULE_PARM_DESC(half_landed_wait_secs, "TEST ONLY: settle a creatorless half-landed record after this long (-1: stale window)");

/*
 * A half-landed record whose new namespace sector landed names no
 * creator: the create's record write releases its birth claim in that
 * same sector. Its creator is then judged by time instead: a live one's
 * synced write completes, or fails and stops its mount, well inside a
 * stale window, so a record still half-landed a whole window after this
 * node first saw it is a crashed create's. Keyed by the namespace
 * sector's checksum as well, so a later, different stop of the same
 * number starts its own clock. True once that much time has passed.
 */
bool cetrafs_sb_half_landed_aged(struct super_block *sb, u64 ino, u32 ns_crc)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u64 now = (u64) ktime_get_boottime_seconds() & 0x7fffffffULL;
    int wait = READ_ONCE(cetrafs_half_landed_wait_secs);
    void *e;

    if (!sbi || ino > ULONG_MAX)
        return false;
    e = xa_load(&sbi->half_landed, (unsigned long) ino);
    if (e && (u32) (xa_to_value(e) >> 31) == ns_crc) {
        u64 first = xa_to_value(e) & 0x7fffffffULL;

        return ((now - first) & 0x7fffffffULL) >= (u64) (wait >= 0 ? wait : (int) cetrafs_sb_stale_secs(sb));
    }
    /* First sight (or a different stop): start the clock. A store that
     * fails only means the clock starts on a later walk. */
    xa_store(&sbi->half_landed, (unsigned long) ino, xa_mk_value(((unsigned long) ns_crc << 31) | (unsigned long) now),
             GFP_NOFS);
    return false;
}

/* The number reads as something else now: its clock, if any, is over. */
void cetrafs_sb_half_landed_forget(struct super_block *sb, u64 ino)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi && ino <= ULONG_MAX && !xa_empty(&sbi->half_landed))
        xa_erase(&sbi->half_landed, (unsigned long) ino);
}

unsigned int cetrafs_sb_stale_secs(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;
    unsigned int v = sbi ? READ_ONCE(sbi->stale_secs) : 0;

    return v ? v : cetrafs_param_stale_secs();
}

void cetrafs_sb_set_hb_interval_secs(struct super_block *sb, unsigned int v)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return;
    /* Takes effect at the next tick, which was scheduled at the OLD
     * rate -- so a lowered interval is not advertised for up to one old
     * period, and peers floor their staleness window on what is
     * advertised. Firing the tick immediately from here was tried and
     * reverted: it raced module unload. A caller that needs the new
     * rate to be visible should wait for the advertisement. */
    WRITE_ONCE(sbi->hb_interval_secs, v);
}

void cetrafs_sb_set_stale_secs(struct super_block *sb, unsigned int v)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi)
        WRITE_ONCE(sbi->stale_secs, v);
}


/*
 * Record that this node now owns zg_id, confirmed via zonegroup.c's
 * claim path (a fresh claim, a stale-peer reclaim, or a plain re-attach
 * to a ZG it already owned) -- see the cetrafs_sb_info field comment
 * for why this is safe to cache rather than re-derive from disk on
 * every call. first_bg_id/bg_count are mkfs-time-fixed and never change
 * post-format, so caching them alongside costs nothing in correctness.
 * Idempotent: safe to call again for a ZG already marked owned (the
 * re-attach-at-every-mount/heartbeat-tick path does exactly that).
 */
void cetrafs_sb_cache_zg_ownership(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (zg_id >= CETRAFS_MAX_ZONE_GROUPS)
        return;

    set_bit(zg_id, sbi->owned_zgs);

    /* Derive "which Block Groups may this node allocate from" from the
     * owners recorded at mount, rather than from the Zone Group's
     * range. Same answer today -- the two describe the same mapping --
     * but it is the Block Group that will still be able to answer once
     * the range is gone (docs/internal/BG-OWNERSHIP-DESIGN.md), and it
     * stays correct when membership is no longer a contiguous run.
     * O(bg_count) in memory, on a path taken only when ownership
     * changes. */
    cetrafs_sb_owned_bgs_derive(sbi, zg_id, true);
}

/*
 * The release-side counterpart to cetrafs_sb_cache_zg_ownership() above
 * -- clears zg_id from this node's owned-ZG cache the moment a
 * voluntary release (zonegroup.c's cetrafs_zg_release_surplus()) is
 * confirmed to have stuck, so cetrafs_alloc_pick_bg()'s cached-only
 * ownership scan stops offering this ZG for new allocations
 * immediately, without waiting for anything to re-derive ownership
 * from disk. Idempotent: a no-op if zg_id wasn't marked owned.
 */
void cetrafs_sb_uncache_zg_ownership(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (zg_id >= CETRAFS_MAX_ZONE_GROUPS)
        return;

    clear_bit(zg_id, sbi->owned_zgs);

    cetrafs_sb_owned_bgs_derive(sbi, zg_id, false);
}

/* The hot-path counterpart: true (with first_bg_id/bg_count filled in)
 * if this node's cache already knows it owns zg_id, false otherwise --
 * zero disk I/O either way. cetrafs_alloc_pick_bg() (zonegroup.c) is
 * the reason this exists: it used to call cetrafs_read_zg() (always a
 * forced-uncached, real device round trip) for every ZG on every single
 * new block a write needed. */
/* A Zone Group record failed its checksum on every read: true the first
 * time for 'zg_id', so it is reported once per mount, not per tick. */
bool cetrafs_sb_zg_note_unreadable(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && zg_id < CETRAFS_MAX_ZONE_GROUPS && !test_and_set_bit(zg_id, sbi->zg_unreadable);
}

u32 cetrafs_sb_zg_unreadable_count(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? bitmap_weight(sbi->zg_unreadable, CETRAFS_MAX_ZONE_GROUPS) : 0;
}

bool cetrafs_sb_zg_owned_cached(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    /* Just the ownership answer. It used to also hand back the Zone
     * Group's contiguous range of Block Groups, and most callers passed
     * two variables they then ignored -- two were literally named
     * unused_first_bg/unused_bg_count. Membership is the Block Group's
     * business now (cetrafs_sb_bg_owner()). */
    return zg_id < CETRAFS_MAX_ZONE_GROUPS && test_bit(zg_id, sbi->owned_zgs);
}

/*
 * Does BG #bg_id belong to a Zone Group this node currently owns?
 * Zero disk I/O -- answered entirely from the same ownership cache
 * cetrafs_sb_zg_owned_cached() above maintains.
 *
 * This exists for the cache-invalidation decision in super_ops.c's
 * statfs (and procfs's "info"), which force every BG descriptor fresh
 * so a node can see a PEER's writes. For a BG this node owns that read
 * is not just unnecessary, it is harmful: this node is the only writer
 * of that count, cetrafs_bg_data_block_stats() already folds in the
 * accrued-but-unapplied delta, and dropping the cached descriptor
 * throws away the exact block cetrafs_alloc_pick_bg() re-reads for
 * EVERY owned BG on EVERY single block allocation.
 *
 * That was harmless until v0x0004. Before it, cetrafs_bg_adjust_free_
 * blocks() read-modify-wrote the descriptor in the buffer cache, so a
 * BG this node was actively allocating from had a DIRTY descriptor --
 * and cetrafs_invalidate_block() deliberately refuses to drop a dirty
 * buffer, so the hot ones were silently skipped. v0x0004 stopped
 * dirtying it (a dirty buffer is flushable by background writeback at
 * any moment, which let a stale node clobber a stealing peer's
 * reconcile), which left every descriptor clean -- and the invalidate
 * loop, unchanged, started succeeding on the hot BGs too. On a Proxmox
 * host, where pvestatd polls statfs on every storage every ~10s, that
 * wipes the allocator's descriptor cache mid-stream, over and over.
 * Measured on the real LUN as streaming writes dropping from ~200 MB/s
 * to ~120 MB/s, degrading further as the file grew (the node claims
 * more ZGs as it fills, so there are more descriptors to re-fetch after
 * each wipe). Same mechanism, different trigger, as the per-tick epoch
 * seeding cured in zonegroup.c's cetrafs_zg_try_claim_one().
 */
/*
 * Record that a Block Group has changed owner, in core.
 *
 * Called after a claim's compare-and-swap has STUCK, so the on-disk
 * record already says this -- and the in-core map must follow or the
 * allocator will not look at the Block Group it just won. Updating
 * owned_bgs is what makes it allocatable; nothing else consults it.
 */
/*
 * Take a Block Group out of this node's allocator reach, and put it
 * back.
 *
 * The allocator picks exclusively from owned_bgs, so clearing the bit
 * is all it takes -- and doing it BEFORE checking the Block Group is
 * empty is what closes the only window the per-Block-Group release
 * opens: this node allocating into something it is halfway through
 * giving away. Under alloc_mutex, which is what serialises this node's
 * own bitmap read-modify-writes, so a concurrent allocation either
 * sees the bit or does not and never straddles it.
 *
 * Nothing persists: a node that dies while draining simply still owns
 * the Block Group on disk, which is the safe direction.
 */
/*
 * Take a Block Group out of the allocator's reach for a release. Refused
 * (false) while a FITRIM claim lies inside it: the claim's give-back
 * finds a drained group "gone" and leaves its run allocated, so a
 * release that drained, looked, saw the claim and undrained leaked a
 * whole run of a group that never left (review U4's second half). A
 * claim cannot start in a drained group (cetrafs_trim_claim_next()
 * re-tests under this mutex), so the two exclude each other.
 */
bool cetrafs_sb_drain_bg(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;
    struct cetrafs_bg_chunk *c;
    bool drained = false;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    if (!c)
        return true; /* not a group we track: nothing to take away */
    mutex_lock(&sbi->alloc_mutex);
    if (!sbi->trim_count || sbi->trim_bg != bg_id) {
        clear_bit(i, c->owned_bgs);
        drained = true;
    }
    mutex_unlock(&sbi->alloc_mutex);
    return drained;
}

void cetrafs_sb_undrain_bg(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    struct cetrafs_bg_chunk *c;
    u32 i;

    /* A discard of unknown outcome may still land on it: it stays out of
     * reach whoever asks, until a known-outcome discard clears the mark
     * (cetrafs_bg_release_empty()). This is the one place a drained
     * group comes back, so the one place to refuse. */
    if (cetrafs_sb_bg_discard_pending(sb, bg_id) && !READ_ONCE(cetrafs_discard_pending_ignore))
        return;
    c = cetrafs_bgc(sbi, bg_id, &i);
    if (!c)
        return;
    mutex_lock(&sbi->alloc_mutex);
    if (c->bg_owner_zg[i] < CETRAFS_MAX_ZONE_GROUPS && test_bit(c->bg_owner_zg[i], sbi->owned_zgs))
        set_bit(i, c->owned_bgs), set_bit(i, c->release_check);
    mutex_unlock(&sbi->alloc_mutex);
}

void cetrafs_sb_set_bg_owner(struct super_block *sb, u32 bg_id, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    if (!c)
        return;

    /* Under owned_lock, like the derive (cetrafs_sb_owned_bgs_derive()):
     * otherwise a release's derive could run between this test of
     * owned_zgs and the set_bit, and the group stayed marked ours in a
     * Zone Group given away (audit 2026-11-14 A-2). */
    spin_lock(&sbi->owned_lock);
    WRITE_ONCE(c->bg_owner_zg[i], (u16) zg_id);
    if (zg_id < CETRAFS_MAX_ZONE_GROUPS && test_bit(zg_id, sbi->owned_zgs) &&
        !cetrafs_sb_bg_discard_pending_ignored(sbi, bg_id))
        set_bit(i, c->owned_bgs), set_bit(i, c->release_check);
    else
        clear_bit(i, c->owned_bgs);
    spin_unlock(&sbi->owned_lock);
}

/* Any Zone Group this node owns, for claiming a free Block Group into.
 * -ENOENT if it owns none. */
int cetrafs_sb_first_owned_zg(struct super_block *sb, u32 *out_zg)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;
    u32 z;

    if (!sbi)
        return -EINVAL;
    z = (u32) find_first_bit(sbi->owned_zgs, CETRAFS_MAX_ZONE_GROUPS);
    if (z >= CETRAFS_MAX_ZONE_GROUPS)
        return -ENOENT;
    if (out_zg)
        *out_zg = z;
    return 0;
}

/*
 * Where Block Group bg_id's descriptor lives.
 *
 * Replaces `bg_table_start + bg_id`, which stopped being true once the
 * table became a chain -- correct only for the ids in the implicit
 * first segment. Resolved from the map built at mount, so this is an
 * array read with no device I/O, which is what the per-block budget
 * requires (PERFORMANCE.md rule 1).
 *
 * Returns 0 for an out-of-range id; 0 is the superblock's own block and
 * can never hold a descriptor, so a caller that ignores the check
 * writes somewhere obviously wrong rather than somewhere plausible.
 */
u64 cetrafs_sb_bg_desc_lba(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    return c ? c->bg_desc_lba[i] : 0;
}

u32 cetrafs_sb_bg_owner(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    return c ? READ_ONCE(c->bg_owner_zg[i]) : CETRAFS_NODE_ID_NONE;
}

/* The first Block Group at or after 'from' this node may allocate from,
 * or U32_MAX. The loop shape every walk of the owned set uses:
 *   for (b = cetrafs_sb_next_owned_bg(sb, 0); b != U32_MAX;
 *        b = cetrafs_sb_next_owned_bg(sb, b + 1))
 * Each step re-reads the layout, so a walk that spans a refresh simply
 * carries on into the Block Groups it added. */
u32 cetrafs_sb_next_owned_bg(struct super_block *sb, u32 from)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    return cetrafs_bgc_next_bit(sbi, offsetof(struct cetrafs_bg_chunk, owned_bgs), from);
}

bool cetrafs_sb_bg_is_ours(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    if (!c)
        return false;

    /* One bit test. This used to walk every owned Zone Group comparing
     * the Block Group id against a contiguous range; the answer is the
     * same, but it no longer depends on membership BEING contiguous,
     * which is what has to stop being true
     * (docs/internal/BG-OWNERSHIP-DESIGN.md). */
    return test_bit(i, c->owned_bgs);
}

/* The allocation cursor (see its field comment). Advisory: plain
 * READ_ONCE/WRITE_ONCE, no lock -- every guarantee is re-checked
 * downstream by the caller. */
u32 cetrafs_sb_alloc_cursor(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? READ_ONCE(sbi->alloc_bg_cursor) : 0;
}

void cetrafs_sb_set_alloc_cursor(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi)
        WRITE_ONCE(sbi->alloc_bg_cursor, bg_id);
}

/*
 * Is this node currently write-ready -- does it own at least one Zone
 * Group to allocate new blocks from? mounting with
 * zero owned ZGs (every ZG already claimed by a live peer) is normal,
 * expected clustering behavior, not a mount failure (see zonegroup.c's
 * cetrafs_zg_claim_unowned()) -- but that degraded state was previously
 * invisible from outside dmesg. procfs.c's "info" file now surfaces
 * this directly, rather than leaving an operator to infer "mounted but
 * can't write anything yet" from a failed write. Zero disk I/O: just a
 * bitmap-empty check on the same cache cetrafs_sb_zg_owned_cached()
 * above already maintains.
 */
bool cetrafs_sb_owns_any_zg(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && !bitmap_empty(sbi->owned_zgs, CETRAFS_MAX_ZONE_GROUPS);
}



/* Record that BG #bg_id's free_data_blocks has a change sitting dirty-
 * but-not-yet-synced -- called by alloc.c's cetrafs_bg_adjust_free_
 * blocks() instead of syncing on every single call. See
 * cetrafs_flush_dirty_free_counts() below for where this actually
 * gets flushed. */
/* Accrue a pending change to a BG's free count. Applied to the
 * descriptor by cetrafs_flush_dirty_free_counts() below, as one CAS per
 * dirty BG -- see cetrafs_bg_chunk.bg_free_delta's comment for why nothing is ever
 * left dirty in the buffer cache instead. */
/* Mark a BG as having un-durable allocation bits; see bmap_alloc_dirty. */
void cetrafs_sb_note_bmap_alloc(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    if (!c)
        return;
    /* Raised first: the gate must never read 0 while a mark is set, or
     * an extent is published over bits still only in memory (rule 8). */
    atomic_inc(&sbi->bmap_dirty_n);
    if (test_and_set_bit(i, c->bmap_alloc_dirty))
        atomic_dec(&sbi->bmap_dirty_n); /* already counted */
}

/* TEST ONLY: the gate walks every chunk, as before -- the control of
 * tests/kernel/bmap_gate_cost.sh. */
static bool cetrafs_bmap_gate_walk;
cetrafs_test_param(bmap_gate_walk, cetrafs_bmap_gate_walk, bool, 0644);
MODULE_PARM_DESC(bmap_gate_walk, "TEST ONLY: the dirty-bitmap gate walks every Block Group chunk");
static atomic64_t cetrafs_bmap_gate_walks = ATOMIC64_INIT(0);
u64 cetrafs_bmap_gate_walks_count(void)
{
    return (u64) atomic64_read(&cetrafs_bmap_gate_walks);
}

/* Does any BG have allocation bits not yet on the device? One atomic
 * read -- the tree-edit gate asks this once per mapped block, and a walk
 * of every chunk was ~0.5 ms at 64 TiB (audit P7). The count is never
 * below the marks; above them only for the instant around a set or a
 * take, which costs one needless flush call. */
bool cetrafs_sb_bmap_alloc_any_dirty(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (unlikely(READ_ONCE(cetrafs_bmap_gate_walk))) {
        atomic64_inc(&cetrafs_bmap_gate_walks);
        return cetrafs_bgc_next_bit(sbi, offsetof(struct cetrafs_bg_chunk, bmap_alloc_dirty), 0) != U32_MAX;
    }
    return atomic_read(&sbi->bmap_dirty_n) != 0;
}

/* The release_check set (see its field). */
u32 cetrafs_sb_next_release_check(struct super_block *sb, u32 from)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return cetrafs_bgc_next_bit(sbi, offsetof(struct cetrafs_bg_chunk, release_check), from);
}

void cetrafs_sb_set_release_check(struct super_block *sb, u32 bg_id, bool on)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    if (!c)
        return;
    if (on) {
        set_bit(i, c->release_check);
    } else {
        clear_bit(i, c->release_check);
        smp_mb__after_atomic(); /* before the caller's re-look at the count */
    }
}

/* The first BG at or after 'from' with allocation bits not yet on the
 * device, U32_MAX when none: the flush visits only those (audit
 * 2026-11-14 P7). */
u32 cetrafs_sb_next_bmap_alloc_dirty(struct super_block *sb, u32 from)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return cetrafs_bgc_next_bit(sbi, offsetof(struct cetrafs_bg_chunk, bmap_alloc_dirty), from);
}

/* Enter and leave the one allocation-bitmap flush. The in-flight count
 * is raised BEFORE the lock and before any mark is taken, so a reader
 * that sees no marks also sees the flush that took them. */
/* TEST ONLY: the flush mutex is taken unkillably, as before (the
 * control of tests/kernel/bmap_flush_batched.sh). */
static bool cetrafs_bmap_flush_unkillable;
cetrafs_test_param(bmap_flush_unkillable, cetrafs_bmap_flush_unkillable, bool, 0644);
MODULE_PARM_DESC(bmap_flush_unkillable, "TEST ONLY: a bitmap flush waits for the one in flight unkillably");

/* Killable: a caller queued behind a long flush -- a large
 * preallocation's thousands of bitmap blocks -- was unkillable in D state
 * for as long as it took (audit 2026-11-15 B-29). -EINTR: not entered;
 * the caller publishes nothing. */
int cetrafs_sb_bmap_flush_begin(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    atomic_inc(&sbi->bmap_flush_inflight);
    smp_mb__after_atomic();
    /* An exiting task's closes run with the kill already pending: a
     * killable wait would fail every one of them at once and leave its
     * lock release to the heartbeat (audit 2026-11-15 F-21). It is
     * leaving anyway; let it wait. */
    if (READ_ONCE(cetrafs_bmap_flush_unkillable) || (current->flags & PF_EXITING)) {
        mutex_lock(&sbi->bmap_flush_mutex);
        return 0;
    }
    if (mutex_lock_killable(&sbi->bmap_flush_mutex)) {
        smp_mb__before_atomic();
        atomic_dec(&sbi->bmap_flush_inflight);
        return -EINTR;
    }
    return 0;
}

void cetrafs_sb_bmap_flush_end(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    mutex_unlock(&sbi->bmap_flush_mutex);
    smp_mb__before_atomic();
    atomic_dec(&sbi->bmap_flush_inflight);
}

bool cetrafs_sb_bmap_flush_inflight(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return false;
    smp_rmb(); /* after the caller's look at the marks */
    return atomic_read(&sbi->bmap_flush_inflight) != 0;
}

/* Take and clear the set, for the flush. Clearing first means a racing
 * allocation re-marks its BG rather than having its mark dropped by a
 * flush that did not cover it. */
bool cetrafs_sb_take_bmap_alloc_dirty(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    /* class 55: a flusher that finds this mark clear while another's
     * bitmap write is out must not publish on it: flushes run one at a
     * time and the per-block gate enters while one is in flight
     * (cetrafs_alloc_flush_bitmaps(), audit A1). */
    if (!c || !test_and_clear_bit(i, c->bmap_alloc_dirty))
        return false;
    atomic_dec(&sbi->bmap_dirty_n); /* lowered after the clear: never below the marks */
    return true;
}

/* Allocations only -- see cetrafs_bg_chunk.bg_alloc_seq. */
u64 cetrafs_sb_bg_alloc_seq(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    return c ? (u64) atomic64_read(&c->bg_alloc_seq[i]) : 0;
}

void cetrafs_sb_accrue_bg_free(struct super_block *sb, u32 bg_id, s64 delta)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    if (c) {
        atomic64_add(delta, &c->bg_free_delta[i]);
        set_bit(i, c->bg_free_dirty);
        if (delta > 0)
            set_bit(i, c->release_check); /* it may be empty now */
        /* A negative delta IS an allocation. One uncontended atomic on
         * the per-block path -- no device I/O, so PERFORMANCE.md's
         * per-block budget is untouched. */
        if (delta < 0)
            atomic64_inc(&c->bg_alloc_seq[i]);
    }
}

unsigned long cetrafs_sb_pf_drain_last(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? READ_ONCE(sbi->pf_drain_last) : 0;
}

struct mutex *cetrafs_sb_pf_drain_mutex(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? &sbi->pf_drain_mutex : NULL;
}

void cetrafs_sb_set_pf_drain_last(struct super_block *sb, unsigned long when)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi)
        WRITE_ONCE(sbi->pf_drain_last, when ? when : 1);
}

unsigned long cetrafs_sb_bg_sweep_last(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? READ_ONCE(sbi->bg_sweep_last) : 0;
}

void cetrafs_sb_set_bg_sweep_last(struct super_block *sb, unsigned long when)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi)
        WRITE_ONCE(sbi->bg_sweep_last, when ? when : 1);
}


/* TEST ONLY: readers ignore a flush in flight and add only the delta
 * still accrued -- the old view, the negative control for
 * tests/kernel/bg_flush_inflight_count.sh. */
static bool cetrafs_bg_flight_ignored;
cetrafs_test_param(bg_flight_ignored, cetrafs_bg_flight_ignored, bool, 0644);
MODULE_PARM_DESC(bg_flight_ignored, "TEST ONLY: a BG count read ignores a flush in flight (the old view)");

/* The flight generation to pass to cetrafs_sb_bg_free_settle(), read
 * BEFORE the descriptor. */
u32 cetrafs_sb_bg_flight_gen(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sb->s_fs_info, bg_id, &i);
    return c ? smp_load_acquire(&c->bg_flight_gen[i]) : 0;
}

/*
 * This node's view of BG #bg_id's free count, given the count 'desc' its
 * descriptor said after cetrafs_sb_bg_flight_gen() returned 'gen': the
 * descriptor plus what is still accrued -- or, while a flush is in
 * flight, the count that flush is writing plus what is still accrued.
 * false when a flush began or ended in between: read the descriptor
 * again. See cetrafs_bg_chunk.bg_flight_gen.
 */
bool cetrafs_sb_bg_free_settle(struct super_block *sb, u32 bg_id, u32 gen, s64 desc, s64 *out)
{
    struct cetrafs_bg_chunk *c;
    u32 i;
    bool ok = true;

    c = cetrafs_bgc(sb->s_fs_info, bg_id, &i);
    if (!c) {
        *out = desc;
        return true;
    }
    /* PERF(1): the per-block path, so no lock when no flush is in
     * flight -- the almost-always case. A begin makes the generation odd
     * BEFORE its xchg takes the delta (the xchg is fully ordered): a
     * read of the delta that missed it is followed by a re-read of the
     * generation that sees the change. docs/PERFORMANCE.md */
    if (!(gen & 1)) {
        s64 v = desc + atomic64_read(&c->bg_free_delta[i]);

        smp_rmb();
        if (READ_ONCE(c->bg_flight_gen[i]) != gen)
            return false;
        *out = v;
        return true;
    }
    spin_lock(&c->flight_lock);
    if (c->bg_flight_gen[i] != gen)
        ok = false;
    else if ((gen & 1) && !READ_ONCE(cetrafs_bg_flight_ignored))
        *out = c->bg_flight_free[i] + atomic64_read(&c->bg_free_delta[i]);
    else
        *out = desc + atomic64_read(&c->bg_free_delta[i]);
    spin_unlock(&c->flight_lock);
    return ok;
}

/* Has BG #bg_id accrued a delta not yet flushed? Presence only: a
 * reader that wants the count goes through cetrafs_sb_bg_free_settle(). */
bool cetrafs_sb_bg_delta_pending(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sb->s_fs_info, bg_id, &i);
    return c && atomic64_read(&c->bg_free_delta[i]) != 0;
}

/*
 * Begin flushing BG #bg_id's accrued delta: wait out another flush of
 * it, then take the delta and publish the count it will make, 'desc'
 * being the count the descriptor holds now. Returns the delta taken; 0
 * means nothing to flush and no flight to end.
 */
s64 cetrafs_sb_bg_flight_begin(struct super_block *sb, u32 bg_id, s64 desc)
{
    struct cetrafs_bg_chunk *c;
    s64 delta;
    u32 i;

    c = cetrafs_bgc(sb->s_fs_info, bg_id, &i);
    if (!c)
        return 0;
    spin_lock(&c->flight_lock);
    /* class 52: taken into a flight -- readers count bg_flight_free until
     * the swap is back.
     * Odd first, then take the delta: see cetrafs_sb_bg_free_settle()'s
     * lock-free path. A reader that sees odd takes this lock, so it never
     * sees the flight half set up; nothing taken, the flight is undone
     * before the lock drops. */
    WRITE_ONCE(c->bg_flight_gen[i], c->bg_flight_gen[i] + 1);
    delta = atomic64_xchg(&c->bg_free_delta[i], 0);
    if (delta)
        c->bg_flight_free[i] = desc + delta;
    else
        smp_store_release(&c->bg_flight_gen[i], c->bg_flight_gen[i] + 1);
    spin_unlock(&c->flight_lock);
    if (!delta)
        cetrafs_sb_bg_flush_unlock(sb, bg_id);
    return delta;
}

/* TEST ONLY: flushes of one Block Group are not serialised. The seed
 * copy's buffer lock is then the only thing between two of them, which
 * is what tests/kernel/bg_seed_torn.sh's control needs to reach; the
 * flight bookkeeping is not meant to survive it. */
static bool cetrafs_bg_flush_unserialised;
cetrafs_test_param(bg_flush_unserialised, cetrafs_bg_flush_unserialised, bool, 0644);
MODULE_PARM_DESC(bg_flush_unserialised, "TEST ONLY: two flushes of one BG's free count may run at once");

/*
 * A recount's flight: as cetrafs_sb_bg_flight_begin(), but readers take
 * 'value' -- the count the recount writes -- and the accrued delta it
 * already holds leaves memory now. Returns that delta (dropped, or put
 * back by cetrafs_sb_bg_flight_settle_end() if the write fails). The
 * caller holds the flush right; the flight is always begun.
 */
s64 cetrafs_sb_bg_flight_begin_value(struct super_block *sb, u32 bg_id, s64 value)
{
    struct cetrafs_bg_chunk *c;
    s64 taken;
    u32 i;

    c = cetrafs_bgc(sb->s_fs_info, bg_id, &i);
    if (!c)
        return 0;
    spin_lock(&c->flight_lock);
    /* class 52: taken into a flight whose value already holds it. */
    WRITE_ONCE(c->bg_flight_gen[i], c->bg_flight_gen[i] + 1); /* before the xchg: see the settle */
    taken = atomic64_xchg(&c->bg_free_delta[i], 0);
    c->bg_flight_free[i] = value;
    spin_unlock(&c->flight_lock);
    return taken;
}

/* End a recount's flight, putting 'requeue' back; the flush right stays
 * with the caller. */
void cetrafs_sb_bg_flight_settle_end(struct super_block *sb, u32 bg_id, s64 requeue)
{
    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sb->s_fs_info, bg_id, &i);
    if (!c)
        return;
    spin_lock(&c->flight_lock);
    if (requeue) {
        atomic64_add(requeue, &c->bg_free_delta[i]);
        set_bit(i, c->bg_free_dirty);
    }
    smp_store_release(&c->bg_flight_gen[i], c->bg_flight_gen[i] + 1);
    spin_unlock(&c->flight_lock);
}

/* Wait for, and take, the right to flush BG #bg_id. Not interruptible:
 * the holder is one CAS away from letting go, and that CAS is bounded by
 * its own timeout -- while an -EINTR here would be a new way for a
 * recount or a flush to fail. Always 0. */
int cetrafs_sb_bg_flush_lock(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sb->s_fs_info, bg_id, &i);
    if (!c || READ_ONCE(cetrafs_bg_flush_unserialised))
        return 0;
    wait_on_bit_lock(c->bg_flush_busy, i, TASK_UNINTERRUPTIBLE);
    return 0;
}

/* Give the flush right back without having begun (the descriptor could
 * not be read). */
void cetrafs_sb_bg_flush_unlock(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sb->s_fs_info, bg_id, &i);
    if (!c)
        return;
    clear_bit_unlock(i, c->bg_flush_busy);
    smp_mb__after_atomic();
    wake_up_bit(c->bg_flush_busy, i);
}

/*
 * End the flight cetrafs_sb_bg_flight_begin() started, once the CAS is
 * back and the cached descriptor holds whatever it committed. 'requeue'
 * is a delta that did not reach the device and goes back to be flushed
 * again; it is put back in the same step that ends the flight, so no
 * reader sees it in neither place.
 */
void cetrafs_sb_bg_flight_end(struct super_block *sb, u32 bg_id, s64 requeue)
{
    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sb->s_fs_info, bg_id, &i);
    if (!c)
        return;
    spin_lock(&c->flight_lock);
    if (requeue) {
        atomic64_add(requeue, &c->bg_free_delta[i]);
        set_bit(i, c->bg_free_dirty);
    }
    smp_store_release(&c->bg_flight_gen[i], c->bg_flight_gen[i] + 1);
    spin_unlock(&c->flight_lock);
    cetrafs_sb_bg_flush_unlock(sb, bg_id);
}

/* The BG count's ownership epoch (see struct cetrafs_bg_chunk.bg_count_epoch). */
u64 cetrafs_sb_bg_epoch(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    return c ? READ_ONCE(c->bg_count_epoch[i]) : 0;
}

/*
 * Move a BG count's epoch -- and DISCARD whatever delta this node still
 * has accrued for it, because the epoch only ever moves when somebody
 * recounted that Block Group's bitmap, and a recount already includes
 * every durable effect our pending delta describes.
 *
 * The guard in cetrafs_bg_count_mutate() reads this epoch at FLUSH
 * time, not at accrual time, so it cannot tell "our delta is older than
 * this reconcile" from "our delta belongs to it": re-seeding here while
 * a delta sat pending made the stale delta look current and it applied
 * on top of the recount. Seen in the field as a count driven below zero
 * (a long-lived writer -- a VM image held open for days -- accrues for
 * as long as it stays open, so a delta easily outlives an ownership
 * event), and that refusal is only the LOUD half: a delta small enough
 * to still fit would have silently corrupted the count instead.
 *
 * Dropping is the conservative direction and the same one the apply
 * path already takes for a foreign epoch: the member bitmaps are the
 * truth, the recount just read them, and nothing of ours is lost that
 * the recount did not already record.
 */
/* Returns the accrued delta the move dropped (0 if none). */
s64 cetrafs_sb_set_bg_epoch(struct super_block *sb, u32 bg_id, u64 seq)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u64 prev;
    s64 stale;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    if (!c)
        return 0;

    prev = READ_ONCE(c->bg_count_epoch[i]);
    WRITE_ONCE(c->bg_count_epoch[i], seq);
    if (prev == seq)
        return 0; /* re-attach with nobody having reconciled: our deltas stand */

    /* class 52: a recount of ours took the delta in its own flight
     * (__cetrafs_reconcile_locked()), so nothing is left here; on a
     * re-attach (cetrafs_bg_seed_count_epochs()) the epoch moved only by
     * another owner's recount, whose count -- already read fresh into
     * the cache -- holds every durable effect of what is dropped. */
    stale = atomic64_xchg(&c->bg_free_delta[i], 0);
    /* class 55: nothing is written behind this mark -- the delta it
     * stood for is dropped here, not flushed. */
    clear_bit(i, c->bg_free_dirty);
    if (stale)
        pr_warn("BG %u: dropping an accrued free delta of %lld -- the count was recounted (epoch %llu -> %llu)\n", bg_id,
                (long long) stale, (unsigned long long) prev, (unsigned long long) seq);
    return stale;
}

/*
 * As cetrafs_sb_set_bg_epoch(), but the delta accrued so far STAYS. For a
 * recount whose flight already took the delta its count holds: what is
 * still accrued happened after that count was read, so it is not in the
 * count and belongs to the new epoch. Its caller holds the flush right,
 * so no flush can apply the delta under the old epoch meanwhile.
 */
void cetrafs_sb_set_bg_epoch_keep(struct super_block *sb, u32 bg_id, u64 seq)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    struct cetrafs_bg_chunk *c;
    u32 i;

    c = cetrafs_bgc(sbi, bg_id, &i);
    if (c)
        WRITE_ONCE(c->bg_count_epoch[i], seq);
}

/* Same idea as cetrafs_sb_mark_bg_free_dirty() above, for a ZG's own
 * free_data_blocks aggregate -- called by zonegroup.c's cetrafs_zg_
 * adjust_free_blocks(). */
/* Accrue a pending change to a ZG's free-block aggregate. Applied to the
 * record by cetrafs_flush_dirty_free_counts() below, as one CAS. */
/*
 * A release queue is full: this node holds a claim on the device -- a
 * namespace lock, a file lock, a presence bit -- that it could not give
 * back and can no longer remember to. Nobody reclaims a live node's
 * claims, so dropping the entry left it held until something here
 * happened to touch that file again: every peer refused, indefinitely.
 * The queues hold 32 each; filling one means the device is refusing
 * swaps broadly. End in the state a crash leaves (docs/internal/
 * ERRORS.md): stop, so the lease lapses and the peers' stale reclaim
 * clears every claim this node held.
 */
static void cetrafs_sb_defer_overflow(struct super_block *sb, const char *what, u64 ino, unsigned int max)
{
    cetrafs_sb_fatal(sb, "%s release for ino=%llu could not be queued: %u already pending", what,
                     (unsigned long long) ino, max);
}

/* Remember a namespace lock whose release did not commit, for the
 * heartbeat to retry. See cetrafs_sb_info.nsrel. */
void cetrafs_sb_nslock_defer(struct super_block *sb, u64 ino, u64 generation)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u32 i;

    if (!sbi)
        return;

    spin_lock(&sbi->nsrel_lock);
    for (i = 0; i < sbi->nsrel_count; i++)
        if (sbi->nsrel[i].ino == ino) { /* already queued; keep the newer identity */
            sbi->nsrel[i].generation = generation;
            spin_unlock(&sbi->nsrel_lock);
            return;
        }
    if (sbi->nsrel_count == CETRAFS_NSLOCK_DEFERRED_MAX) {
        spin_unlock(&sbi->nsrel_lock);
        cetrafs_sb_defer_overflow(sb, "namespace lock", ino, CETRAFS_NSLOCK_DEFERRED_MAX);
        return;
    }
    sbi->nsrel[sbi->nsrel_count].ino = ino;
    sbi->nsrel[sbi->nsrel_count].generation = generation;
    sbi->nsrel_count++;
    spin_unlock(&sbi->nsrel_lock);
}

/* Remember a file lock whose last close did not finish, for the
 * heartbeat. See cetrafs_lock_retry_deferred(). */
void cetrafs_sb_flock_defer(struct super_block *sb, u64 ino, u64 generation)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u32 i;

    if (!sbi)
        return;
    spin_lock(&sbi->flrel_lock);
    for (i = 0; i < sbi->flrel_count; i++)
        if (sbi->flrel[i].ino == ino) {
            sbi->flrel[i].generation = generation;
            spin_unlock(&sbi->flrel_lock);
            return;
        }
    if (sbi->flrel_count == CETRAFS_FLOCK_DEFERRED_MAX) {
        spin_unlock(&sbi->flrel_lock);
        cetrafs_sb_defer_overflow(sb, "file lock", ino, CETRAFS_FLOCK_DEFERRED_MAX);
        return;
    }
    sbi->flrel[sbi->flrel_count].ino = ino;
    sbi->flrel[sbi->flrel_count].generation = generation;
    sbi->flrel_count++;
    spin_unlock(&sbi->flrel_lock);
}

/* Remember a presence bit whose withdraw did not land, for the heartbeat.
 * See cetrafs_lock_retry_presence(). */
void cetrafs_sb_presence_defer(struct super_block *sb, u64 ino, u64 generation)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u32 i;

    if (!sbi)
        return;
    spin_lock(&sbi->prrel_lock);
    for (i = 0; i < sbi->prrel_count; i++)
        if (sbi->prrel[i].ino == ino) {
            sbi->prrel[i].generation = generation;
            spin_unlock(&sbi->prrel_lock);
            return;
        }
    if (sbi->prrel_count == CETRAFS_PRESENCE_DEFERRED_MAX) {
        spin_unlock(&sbi->prrel_lock);
        cetrafs_sb_defer_overflow(sb, "presence", ino, CETRAFS_PRESENCE_DEFERRED_MAX);
        return;
    }
    sbi->prrel[sbi->prrel_count].ino = ino;
    sbi->prrel[sbi->prrel_count].generation = generation;
    sbi->prrel_count++;
    spin_unlock(&sbi->prrel_lock);
}

u32 cetrafs_sb_presence_take_deferred(struct super_block *sb, struct cetrafs_nsrel_pending *out, u32 max)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u32 n;

    if (!sbi)
        return 0;
    spin_lock(&sbi->prrel_lock);
    n = min(sbi->prrel_count, max);
    memcpy(out, sbi->prrel, n * sizeof(*out));
    memmove(sbi->prrel, sbi->prrel + n, (sbi->prrel_count - n) * sizeof(*out));
    sbi->prrel_count -= n;
    spin_unlock(&sbi->prrel_lock);
    return n;
}

void cetrafs_sb_reclaim_defer(struct super_block *sb, const struct cetrafs_reclaim_pending *p)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u32 i;

    if (!sbi)
        return;
    spin_lock(&sbi->rcrel_lock);
    for (i = 0; i < sbi->rcrel_count; i++)
        if (sbi->rcrel[i].ino == p->ino) {
            sbi->rcrel[i] = *p;
            spin_unlock(&sbi->rcrel_lock);
            return;
        }
    if (sbi->rcrel_count == CETRAFS_RECLAIM_DEFERRED_MAX) {
        spin_unlock(&sbi->rcrel_lock);
        cetrafs_sb_defer_overflow(sb, "inode reclaim claim", p->ino, CETRAFS_RECLAIM_DEFERRED_MAX);
        return;
    }
    sbi->rcrel[sbi->rcrel_count++] = *p;
    spin_unlock(&sbi->rcrel_lock);
}

u32 cetrafs_sb_reclaim_take_deferred(struct super_block *sb, struct cetrafs_reclaim_pending *out, u32 max)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u32 n;

    if (!sbi)
        return 0;
    spin_lock(&sbi->rcrel_lock);
    n = min(sbi->rcrel_count, max);
    memcpy(out, sbi->rcrel, n * sizeof(*out));
    memmove(sbi->rcrel, sbi->rcrel + n, (sbi->rcrel_count - n) * sizeof(*out));
    sbi->rcrel_count -= n;
    spin_unlock(&sbi->rcrel_lock);
    return n;
}

u32 cetrafs_sb_flock_take_deferred(struct super_block *sb, struct cetrafs_nsrel_pending *out, u32 max)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u32 n;

    if (!sbi)
        return 0;
    spin_lock(&sbi->flrel_lock);
    n = min(sbi->flrel_count, max);
    memcpy(out, sbi->flrel, n * sizeof(*out));
    memmove(sbi->flrel, sbi->flrel + n, (sbi->flrel_count - n) * sizeof(*out));
    sbi->flrel_count -= n;
    spin_unlock(&sbi->flrel_lock);
    return n;
}

/* Take the whole pending set, for one retry pass. Entries the pass
 * cannot settle are put back by it. The pass runs between
 * cetrafs_sb_nslock_retry_begin() and _end(), which this requires. */
u32 cetrafs_sb_nslock_take_deferred(struct super_block *sb, struct cetrafs_nsrel_pending *out, u32 max)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u32 n;

    if (!sbi)
        return 0;

    spin_lock(&sbi->nsrel_lock);
    n = min(sbi->nsrel_count, max);
    memcpy(out, sbi->nsrel, n * sizeof(*out));
    /* What was not taken stays queued, as the flock and rcrel takes
     * keep it: zeroing the count dropped every entry past 'max' -- a
     * namespace lock nobody would ever release. Unreachable while the
     * one caller's buffer is CETRAFS_NSLOCK_DEFERRED_MAX long (audit
     * 2026-11-06 L26). */
    memmove(sbi->nsrel, sbi->nsrel + n, (sbi->nsrel_count - n) * sizeof(*out));
    sbi->nsrel_count -= n;
    sbi->nsrel_active = n != 0;
    spin_unlock(&sbi->nsrel_lock);
    return n;
}

void cetrafs_sb_nslock_retry_begin(struct super_block *sb)
{
    mutex_lock(&((struct cetrafs_sb_info *) sb->s_fs_info)->nsrel_mutex);
}

void cetrafs_sb_nslock_retry_end(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    spin_lock(&sbi->nsrel_lock);
    sbi->nsrel_active = false;
    spin_unlock(&sbi->nsrel_lock);
    mutex_unlock(&sbi->nsrel_mutex);
}

/*
 * A local acquire of 'ino' is about to make this node the lock's live
 * holder: drop any deferred release of it, so the heartbeat's retry
 * cannot clear the lock out from under that holder. (The retry's CAS
 * cannot tell the difference -- the record says "ours" either way.)
 *
 * Called under the inode's ns_mutex, which is what makes the fast path
 * sound: only a release of this inode enqueues it, and a release runs
 * under that same mutex, so if nothing is queued and no pass is in
 * flight now, nothing for 'ino' can appear until we release. Otherwise
 * wait out any pass in flight, then remove the entry.
 *
 * Returns 1 and fills *generation if an entry was dropped: if the
 * acquire then fails, the caller must put it back
 * (cetrafs_sb_nslock_defer()), or the leftover lock is retried by
 * nobody. 0 if there was none. -EINTR if the caller was killed waiting
 * out a retry pass -- which can run 32 CASes on a failing device while
 * this caller holds the inode's ns_mutex and the VFS directory lock
 * (audit R21); nothing was dropped then.
 */
int cetrafs_sb_nslock_forget(struct super_block *sb, u64 ino, u64 *generation)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool busy;
    int found = 0;
    u32 i;

    if (!sbi)
        return 0;

    spin_lock(&sbi->nsrel_lock);
    busy = sbi->nsrel_count || sbi->nsrel_active;
    spin_unlock(&sbi->nsrel_lock);
    if (!busy)
        return 0;

    if (mutex_lock_killable(&sbi->nsrel_mutex))
        return -EINTR;
    spin_lock(&sbi->nsrel_lock);
    for (i = 0; i < sbi->nsrel_count; i++)
        if (sbi->nsrel[i].ino == ino) {
            *generation = sbi->nsrel[i].generation;
            sbi->nsrel[i] = sbi->nsrel[--sbi->nsrel_count];
            found = 1;
            break;
        }
    spin_unlock(&sbi->nsrel_lock);
    mutex_unlock(&sbi->nsrel_mutex);
    return found;
}

void cetrafs_sb_accrue_zg_free(struct super_block *sb, u32 zg_id, s64 delta)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi && zg_id < sbi->zg_count)
        atomic64_add(delta, &sbi->zg_free_delta[zg_id]);
}

/* Take and clear a ZG's accrued aggregate delta -- for a caller that is
 * about to replace the aggregate with a recount of the member bitmaps,
 * which already includes everything the delta describes. */
s64 cetrafs_sb_take_zg_free_delta(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || zg_id >= sbi->zg_count)
        return 0;
    /* class 52: only at a claim or a mount, before the group can be
     * allocated from; what is taken is a leftover of an earlier
     * ownership (the flush drops deltas for groups not ours), noise
     * beside the record the recount corrects. */
    return atomic64_xchg(&sbi->zg_free_delta[zg_id], 0);
}

/*
 * Sync every BG descriptor and ZG descriptor currently marked dirty by
 * cetrafs_sb_mark_bg_free_dirty()/cetrafs_sb_mark_zg_free_dirty() above,
 * then clear their bits.
 *
 * (BG half) alongside restoring the sync in cetrafs_bg_
 * adjust_free_blocks() (needed so statfs's cross-node free-block count is
 * promptly correct, not just eventually-via-ordinary-writeback) --
 * syncing on every single block allocation reintroduced one real device
 * round trip per block (confirmed via real two-node testing: a 1 MiB
 * write that previously took ~2s took ~40s again). Batching lets a
 * whole write session pay for exactly one sync per BG/ZG it actually
 * touched instead of one per block. Called from lock.c's
 * cetrafs_lock_release() on the last local writer's close -- the same
 * durability boundary this file's own data and inode state already get
 * flushed at -- and once more from cetrafs_free_sb_info() as a belt-
 * and-suspenders catch-all for anything that was never closed before
 * unmount.
 *
 * ZG half added (cetrafs_zg_adjust_free_blocks(), same
 * batching rationale -- a ZG's aggregate changes on every single BG
 * free-count change too, so unconditionally syncing it there would
 * reintroduce the exact same one-round-trip-per-block regression this
 * function already exists to avoid for the BG side).
 *
 * Finds each dirty descriptor's buffer_head via sb_find_get_block() (a
 * cache lookup, not a fresh read -- the content is already correct and
 * sitting in that buffer from the adjust function's own
 * mark_buffer_dirty(), this just needs to push it to the real device)
 * rather than re-reading and re-stamping the block, which would be
 * redundant work for a value that's already right in memory.
 */
/*
 * How many Zone Groups have a free-count delta accrued but not yet
 * applied.
 *
 * Exposed because it is otherwise unobservable: any attempt to read the
 * on-disk aggregate from userspace goes through sync(2) or BLKFLSBUF,
 * both of which reach ->sync_fs and flush the very deltas being looked
 * for. A test that measured it that way destroyed the state it was
 * measuring and passed against a broken build.
 *
 * It is also the invariant worth watching in production: a delta must
 * never outlive this node's ownership of the Zone Group it belongs to.
 */
u32 cetrafs_sb_pending_zg_deltas(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;
    u32 zg_id, n = 0;

    if (!sbi)
        return 0;
    for (zg_id = 0; zg_id < sbi->zg_count; zg_id++)
        if (atomic64_read(&sbi->zg_free_delta[zg_id]))
            n++;
    return n;
}

u64 cetrafs_sb_total_data_blocks(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    struct cetrafs_bg_layout *l = cetrafs_sb_layout_of(sbi);

    return l ? l->total_data_blocks : 0;
}

/*
 * TEST ONLY: cap a file at the volume's capacity, as before audit F6. The
 * default is the format's ceiling alone -- a sparse file may be larger than
 * the volume, as on ext4, xfs and VMFS; a write that finds no room ends in
 * ENOSPC from the allocator. The knob keeps the old refusal so tests can
 * show the cap was real and reach the same checks (write, fallocate,
 * truncate) that the lifted policy goes through.
 */
static bool cetrafs_cap_file_to_volume;
cetrafs_test_param(cap_file_to_volume, cetrafs_cap_file_to_volume, bool, 0644);
MODULE_PARM_DESC(cap_file_to_volume, "TEST ONLY: refuse a file past the volume's capacity (EFBIG), as before F6");

/* The largest a file may be: the format's ceiling, or under the TEST ONLY
 * knob the capacity of the layout this node holds. */
loff_t cetrafs_sb_max_file_size(struct super_block *sb)
{
    if (!READ_ONCE(cetrafs_cap_file_to_volume))
        return cetrafs_max_file_size_for(U64_MAX);
    return cetrafs_max_file_size_for(cetrafs_sb_total_data_blocks(sb));
}

/*
 * The capacity a file may grow to, caught up with a peer's live grow
 * when 'end' passes the one this node holds: a node that has not yet
 * adopted the grow would otherwise refuse with EFBIG what every node
 * that has accepts (class 43). Returns 0 with *cap set, or the refresh's
 * error when this node cannot tell -- never EFBIG on a guess. Sleeps.
 */
int cetrafs_sb_capacity_for(struct super_block *sb, loff_t end, loff_t *cap)
{
    *cap = cetrafs_sb_max_file_size(sb);
    /* The format ceiling never moves, so only the TEST ONLY capacity cap
     * can be behind a peer's grow. */
    if (end > *cap && READ_ONCE(cetrafs_cap_file_to_volume)) {
        int r = cetrafs_sb_layout_refresh(sb);

        if (r < 0)
            return r;
        *cap = cetrafs_sb_max_file_size(sb);
    }
    return 0;
}

/* TEST ONLY: a ZG aggregate read ignores a flush in flight -- the old
 * view, the negative control for tests/kernel/bg_flush_inflight_count.sh. */
static bool cetrafs_zg_flight_ignored;
cetrafs_test_param(zg_flight_ignored, cetrafs_zg_flight_ignored, bool, 0644);
MODULE_PARM_DESC(zg_flight_ignored, "TEST ONLY: a ZG aggregate read ignores a flush in flight (the old view)");

/* TEST ONLY: the next aggregate flush pauses this long between taking
 * the delta and its CAS. */
static unsigned int cetrafs_zg_flush_stall_ms;
cetrafs_test_param(zg_flush_stall_ms, cetrafs_zg_flush_stall_ms, uint, 0644);
MODULE_PARM_DESC(zg_flush_stall_ms, "TEST ONLY: one ZG aggregate flush pauses between taking its delta and its CAS");

/* As cetrafs_sb_bg_flight_gen(), for Zone Group zg_id's aggregate. */
u32 cetrafs_sb_zg_flight_gen(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    if (!sbi || zg_id >= sbi->zg_count)
        return 0;
    return smp_load_acquire(&sbi->zg_flight_gen[zg_id]);
}

/*
 * This node's view of Zone Group zg_id's free aggregate, given the count
 * 'rec' its record said after cetrafs_sb_zg_flight_gen() returned 'gen'.
 * As cetrafs_sb_bg_free_settle(); see cetrafs_sb_info.zg_flight_gen.
 */
bool cetrafs_sb_zg_free_settle(struct super_block *sb, u32 zg_id, u32 gen, s64 rec, s64 *out)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;
    bool ok = true;

    if (!sbi || zg_id >= sbi->zg_count) {
        *out = rec;
        return true;
    }
    if (!(gen & 1)) {
        s64 v = rec + atomic64_read(&sbi->zg_free_delta[zg_id]);

        smp_rmb();
        if (READ_ONCE(sbi->zg_flight_gen[zg_id]) != gen)
            return false;
        *out = v;
        return true;
    }
    spin_lock(&sbi->zg_flight_lock);
    if (sbi->zg_flight_gen[zg_id] != gen)
        ok = false;
    else if (READ_ONCE(cetrafs_zg_flight_ignored))
        *out = rec + atomic64_read(&sbi->zg_free_delta[zg_id]);
    else if (sbi->zg_flight_known[zg_id])
        *out = sbi->zg_flight_free[zg_id] + atomic64_read(&sbi->zg_free_delta[zg_id]);
    else
        *out = rec + sbi->zg_flight_delta[zg_id] + atomic64_read(&sbi->zg_free_delta[zg_id]);
    spin_unlock(&sbi->zg_flight_lock);
    return ok;
}

/* The right to write Zone Group zg_id's aggregate (zg_flush_busy). Not
 * interruptible, as cetrafs_sb_bg_flush_lock(): a claim's credit or a
 * reconcile's correction must not gain a way to fail. Always 0. */
int cetrafs_sb_zg_write_lock(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    if (!sbi || zg_id >= sbi->zg_count)
        return 0;
    wait_on_bit_lock(sbi->zg_flush_busy, zg_id, TASK_UNINTERRUPTIBLE);
    return 0;
}

void cetrafs_sb_zg_write_unlock(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    if (!sbi || zg_id >= sbi->zg_count)
        return;
    clear_bit_unlock(zg_id, sbi->zg_flush_busy);
    smp_mb__after_atomic();
    wake_up_bit(sbi->zg_flush_busy, zg_id);
}

/* The flush's mutator has the image its swap starts from: the count the
 * swap writes is now known (called before every attempt's write). */
void cetrafs_sb_zg_flight_image(struct super_block *sb, u32 zg_id, s64 cur)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    if (!sbi || zg_id >= sbi->zg_count)
        return;
    spin_lock(&sbi->zg_flight_lock);
    sbi->zg_flight_free[zg_id] = cur + sbi->zg_flight_delta[zg_id];
    sbi->zg_flight_known[zg_id] = true;
    spin_unlock(&sbi->zg_flight_lock);
}

/* Take the accrued delta into a flight; 0 when there was none (no
 * flight to end). The caller holds the write right. */
static s64 cetrafs_sb_zg_flight_begin(struct cetrafs_sb_info *sbi, u32 zg_id)
{
    s64 delta;

    spin_lock(&sbi->zg_flight_lock);
    /* class 52: taken into a flight -- statfs counts it until the swap is back. */
    WRITE_ONCE(sbi->zg_flight_gen[zg_id], sbi->zg_flight_gen[zg_id] + 1); /* before the xchg: see the settle */
    delta = atomic64_xchg(&sbi->zg_free_delta[zg_id], 0);
    if (delta) {
        sbi->zg_flight_delta[zg_id] = delta;
        sbi->zg_flight_known[zg_id] = false;
    } else {
        smp_store_release(&sbi->zg_flight_gen[zg_id], sbi->zg_flight_gen[zg_id] + 1);
    }
    spin_unlock(&sbi->zg_flight_lock);
    return delta;
}

/* End the flight, putting back 'requeue' in the same step. */
static void cetrafs_sb_zg_flight_end(struct cetrafs_sb_info *sbi, u32 zg_id, s64 requeue)
{
    spin_lock(&sbi->zg_flight_lock);
    if (requeue)
        atomic64_add(requeue, &sbi->zg_free_delta[zg_id]);
    smp_store_release(&sbi->zg_flight_gen[zg_id], sbi->zg_flight_gen[zg_id] + 1);
    spin_unlock(&sbi->zg_flight_lock);
}

bool cetrafs_sb_zg_delta_pending(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    if (!sbi || zg_id >= sbi->zg_count)
        return false;
    return atomic64_read(&sbi->zg_free_delta[zg_id]) != 0;
}

int cetrafs_flush_dirty_free_counts(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    const cetrafs_superblock_t *raw_sb;
    u32 bg_id, zg_id;
    int ret = 0;

    if (!sbi)
        return 0;

    raw_sb = cetrafs_sb_raw(sb);
    if (!raw_sb)
        return -EINVAL;

    for (bg_id = cetrafs_bgc_next_bit(sbi, offsetof(struct cetrafs_bg_chunk, bg_free_dirty), 0); bg_id != U32_MAX;
         bg_id = cetrafs_bgc_next_bit(sbi, offsetof(struct cetrafs_bg_chunk, bg_free_dirty), bg_id + 1)) {
        /* The apply takes the whole accrued delta in one go -- same
         * reasoning as the ZG loop below -- and on real I/O trouble puts
         * it back for the next flush (cetrafs_sb_bg_flight_end()). */
        struct cetrafs_bg_chunk *c;
        u32 i;
        int rc;

        c = cetrafs_bgc(sbi, bg_id, &i);
        /* class 55: a second flusher finding this clear returns before
         * the CAS below lands, and nothing is published on that premise:
         * the counts are caches recounted at every claim (rule 8 is about
         * the bitmap), and readers take the value in flight (class 52). */
        clear_bit(i, c->bg_free_dirty);
        if (!atomic64_read(&c->bg_free_delta[i]))
            continue;

        rc = cetrafs_bg_apply_free_delta(sb, bg_id);
        if (rc < 0 && !ret)
            ret = rc;
    }

    for (zg_id = 0; zg_id < sbi->zg_count; zg_id++) {
        /* Take the whole accrued delta in one go, so concurrent
         * allocations keep accruing against a fresh zero rather than
         * having their change applied twice or dropped -- as a flight,
         * so statfs counts it until the swap is back
         * (cetrafs_sb_info.zg_flight_gen). */
        s64 delta;
        int rc;

        if (!atomic64_read(&sbi->zg_free_delta[zg_id]))
            continue;
        rc = cetrafs_sb_zg_write_lock(sb, zg_id);
        if (rc) {
            if (!ret)
                ret = rc;
            continue; /* still accrued: the next flush takes it */
        }
        delta = cetrafs_sb_zg_flight_begin(sbi, zg_id);
        if (!delta) {
            cetrafs_sb_zg_write_unlock(sb, zg_id);
            continue;
        }
        {
            unsigned int pause = xchg(&cetrafs_zg_flush_stall_ms, 0);

            if (pause) {
                pr_info("ZG %u: aggregate flush of %lld in flight, pausing %u ms (test)\n", zg_id,
                        (long long) delta, pause);
                msleep(pause); /* test-only; see the parameter */
            }
        }

        /*
         * Never write a free-count delta into a Zone Group this node no
         * longer owns. The release path flushes before giving one back,
         * so reaching here means ownership was lost some other way --
         * stolen by a peer that found us stale, say.
         *
         * Dropping it is correct, not lossy: the member Block Groups'
         * own counters and bitmaps were updated while we still owned
         * them, and whoever claims the ZG next reconciles the aggregate
         * from those bitmaps. Applying it on top of that reconciliation
         * is what double-counts -- and this aggregate is what statfs
         * reports and what cetrafs_zg_claim_one_more() ranks candidates
         * on.
         *
         * A member BG whose apply failed above has its delta re-accrued
         * and not yet durable, and this ZG delta is applied regardless,
         * so the aggregate can briefly include changes a member's count
         * does not. That is the better of the two states, not a hazard:
         * the aggregate is judged against the BITMAPS (fsck, and the
         * claim's reconcile, which recounts members and sums them
         * absolutely), and the bitmaps already hold the change. Holding
         * this delta back would leave both counts stale instead of one.
         */
        if (!cetrafs_sb_zg_owned_cached(sb, zg_id)) {
            pr_warn("ZG %u: dropping a free-count delta of %lld for a zone group this node no longer owns\n", zg_id,
                    (long long) delta);
            cetrafs_sb_zg_flight_end(sbi, zg_id, 0);
            cetrafs_sb_zg_write_unlock(sb, zg_id);
            continue;
        }

        rc = cetrafs_zg_flush_free_delta(sb, zg_id, delta);
        if (rc) {
            /* Put it back rather than lose it: the aggregate is
             * cross-checked against the member BGs by fsck, so a
             * silently dropped delta shows up later as corruption. */
            pr_err("ZG %u: could not apply free-count delta %lld: %d\n", zg_id, (long long) delta, rc);
            if (!ret)
                ret = rc;
        }
        cetrafs_sb_zg_flight_end(sbi, zg_id, rc ? delta : 0);
        cetrafs_sb_zg_write_unlock(sb, zg_id);
    }

    return ret;
}

/* ------ mount options ------ */

enum cetrafs_param {
    Opt_nofilelock,
    Opt_errors,
    Opt_corruption,
    Opt_nodiscard,
    Opt_discard,
    Opt_localposixlocks,
};

/* errors=: what a fatal error does (docs/internal/ERRORS.md, kind 3).
 * There is deliberately no "continue". */
static const struct constant_table cetrafs_param_errors[] = {
    {"stop", 0},
    {"panic", 1},
    {}};

/* corruption=: what damaged metadata does (kind 2). */
static const struct constant_table cetrafs_param_corruption[] = {
    {"isolate", 0},
    {"stop", 1},
    {}};

static const struct fs_parameter_spec cetrafs_fs_parameters[] = {
    /* Turn the cross-node exclusive open lock off (default: on). Mount-time
     * only -- a remount cannot change it; see cetrafs_reconfigure(). */
    fsparam_flag("nofilelock", Opt_nofilelock),
    /* Both mount-time only, like nofilelock. */
    fsparam_enum("errors", Opt_errors, cetrafs_param_errors),
    fsparam_enum("corruption", Opt_corruption, cetrafs_param_corruption),
    /* No automatic UNMAP (discard.c). Sets the starting value of the
     * per-mount `discard` control, which can still turn it back on. */
    fsparam_flag("nodiscard", Opt_nodiscard),
    /* Inline discard as well (discard.c): runs freed inside the Block
     * Groups this node keeps are discarded a moment later, batched --
     * what `-o discard` means on ext4 and XFS. Off by default. Sets the
     * starting value of the `inline_discard` control. The last of
     * `discard` and `nodiscard` wins, as on ext4. */
    fsparam_flag("discard", Opt_discard),
    /* Grant fcntl/OFD byte-range locks on this node only, as a local
     * filesystem would, instead of refusing them with ENOLCK
     * (cetrafs_posix_lock_refuse()) -- for a qemu whose image locking
     * is on. Per node, mount-time only. A nofilelock mount grants them
     * so anyway. */
    fsparam_flag("localposixlocks", Opt_localposixlocks),
    {}};

static int cetrafs_parse_param(struct fs_context *fc, struct fs_parameter *param)
{
    struct cetrafs_fc_info *fci = fc->fs_private;
    struct fs_parse_result result;
    int opt = fs_parse(fc, cetrafs_fs_parameters, param, &result);

    if (opt < 0)
        return opt; /* unknown option -> the mount is refused, as before */

    switch (opt) {
    case Opt_nofilelock:
        fci->file_lock = false;
        fci->file_lock_set = true;
        break;
    case Opt_errors:
        fci->errors_panic = result.uint_32 == 1;
        fci->errors_set = true;
        break;
    case Opt_corruption:
        fci->corruption_stop = result.uint_32 == 1;
        fci->corruption_set = true;
        break;
    case Opt_nodiscard:
        fci->nodiscard = true;
        fci->nodiscard_set = true;
        fci->inline_discard = false;
        fci->discard_set = false;
        break;
    case Opt_localposixlocks:
        fci->posix_lock_local = true;
        fci->posix_lock_local_set = true;
        break;
    case Opt_discard:
        fci->inline_discard = true;
        fci->discard_set = true;
        fci->nodiscard = false;
        fci->nodiscard_set = false;
        break;
    }
    return 0;
}

static void cetrafs_free_fc(struct fs_context *fc)
{
    kfree(fc->fs_private);
}

/* ------ exported mount/umount entry points (used by kmod.c) ------ */

/*
 * Does a mount request STATE an option the superblock does not have?
 * Fills `what` with the first one. A defaulted option asks for nothing.
 */
static bool cetrafs_opts_unmet(const struct cetrafs_fc_info *fci, const struct cetrafs_sb_info *sbi, const char **what)
{
    if (fci->file_lock_set && fci->file_lock != sbi->file_lock_requested)
        *what = "nofilelock";
    else if (fci->errors_set && fci->errors_panic != sbi->errors_panic)
        *what = fci->errors_panic ? "errors=panic" : "errors=stop";
    else if (fci->corruption_set && fci->corruption_stop != sbi->corruption_stop)
        *what = fci->corruption_stop ? "corruption=stop" : "corruption=isolate";
    else if (fci->nodiscard_set && READ_ONCE(sbi->discard_enabled))
        *what = "nodiscard";
    else if (fci->discard_set && !(READ_ONCE(sbi->discard_enabled) && cetrafs_inline_discard_on(sbi->sb)))
        *what = "discard";
    else if (fci->posix_lock_local_set && !sbi->posix_lock_local)
        *what = "localposixlocks";
    else
        return false;
    return true;
}

/*
 * A second mount of a device that is already mounted gets the existing
 * superblock, and its options were dropped without a word: `nofilelock`,
 * `errors=` and `corruption=` all accepted and none in force (audit
 * L29). The VFS refuses a second mount that disagrees about read-only;
 * these change the mount's safety as much, so one that STATES a value
 * the mount does not have is refused the same way. Compared against
 * what the first mount ASKED for, since its effective file-lock mode may
 * be the cluster's.
 */
/* TEST ONLY: a mount may be handed a stopped superblock, as before audit
 * 2026-11-15 BM-44 (tests/kernel/mount_stopped_not_reused.sh). */
static bool cetrafs_mount_reuse_stopped;
cetrafs_test_param(mount_reuse_stopped, cetrafs_mount_reuse_stopped, bool, 0644);
MODULE_PARM_DESC(mount_reuse_stopped, "TEST ONLY: a new mount reuses a stopped, lazily unmounted superblock");

static int cetrafs_check_second_mount(struct fs_context *fc)
{
    const struct cetrafs_fc_info *fci = fc->fs_private;
    struct super_block *sb = fc->root->d_sb;
    const struct cetrafs_sb_info *sbi = sb->s_fs_info;
    const char *what;

    if (!fci || fci->filled || !sbi)
        return 0;
    /*
     * The superblock found is a STOPPED one -- typically a lazy unmount
     * (umount -l) of a stopped mount, kept alive by the files still open
     * on it. Handing it out again logged a mount success for a mount
     * that fails every I/O with EIO and never rejoins the cluster (audit
     * 2026-11-15 BM-44). Rejoining needs a fresh superblock, which exists
     * only once the last file on the old one is closed.
     */
    if ((READ_ONCE(sbi->fenced) || test_bit(0, &sbi->lease_lost)) && !READ_ONCE(cetrafs_mount_reuse_stopped)) {
        pr_err("%s: this node's previous mount of the volume is stopped (%s) and still in use -- refusing to "
               "mount it again; close what is open on it (a lazy unmount waits for that), then mount\n",
               sb->s_id, cetrafs_sb_stop_cause_name(sb));
        dput(fc->root);
        fc->root = NULL;
        deactivate_locked_super(sb);
        return -EBUSY;
    }
    if (!cetrafs_opts_unmet(fci, sbi, &what))
        return 0;
    pr_err("%s is already mounted without %s -- refusing a second mount that asks for it\n", sb->s_id, what);
    dput(fc->root);
    fc->root = NULL;
    deactivate_locked_super(sb);
    return -EBUSY;
}

/* TEST ONLY: a read-only mount advertises its file-lock mode like any
 * other, as before BM-42 (tests/kernel/ro_mount_no_lead.sh). */
bool cetrafs_ro_mount_leads;
cetrafs_test_param(ro_mount_leads, cetrafs_ro_mount_leads, bool, 0644);
MODULE_PARM_DESC(ro_mount_leads, "TEST ONLY: a read-only mount sets the cluster's file-lock mode, as before");

static int cetrafs_get_tree(struct fs_context *fc)
{
    int ret = get_tree_bdev(fc, cetrafs_fill_super);

    if (!ret)
        ret = cetrafs_check_second_mount(fc);
    if (ret)
        pr_err("'%s' mount failure: %d\n", fc->source ?: "<?>", ret);
    else
        pr_info("'%s' mount success\n", fc->source ?: "<?>");

    return ret;
}

/*
 * mount -o remount,...
 *
 * cetrafs's one option (nofilelock) is mount-time only: a remount parses
 * it but reconfigure does not apply it (the lock state is fixed for the
 * mount's life), so there is nothing to do with options here. But leaving
 * .reconfigure NULL is NOT the same as having nothing to say: the VFS
 * then flips sb->s_flags itself and the filesystem never finds out.
 * That silently created two states it cannot honour.
 *
 *   rw -> ro   The read-only decisions are all made in fill_super():
 *              whether to replay the journal, claim Zone Groups, drain
 *              pending frees, start the defrag janitor. A mount that
 *              started rw has already done all four, still owns Zone
 *              Groups, and still has a janitor relocating file data in
 *              the background. Flipping the flag stops user writes and
 *              nothing else -- "read-only" that keeps writing.
 *
 *   ro -> rw   The mirror image: nothing replayed, nothing claimed, no
 *              janitor -- a mount with no write capacity at all, now
 *              accepting writes.
 *
 * Both are refused. Doing them properly means tearing down and
 * rebuilding half of fill_super() under a live mount, which is a
 * feature, not a flag flip; until it exists, saying so is better than
 * pretending.
 */
static int cetrafs_reconfigure(struct fs_context *fc)
{
    struct super_block *sb = fc->root->d_sb;
    const struct cetrafs_fc_info *fci = fc->fs_private;
    const char *what;

    /* Mount-time only, so a remount cannot apply them -- but it must not
     * accept one in silence either (audit L29). Warned, not refused: a
     * remount that restates the options it was given carries no change,
     * and tooling replays a mount's options on every remount. */
    if (fci && sb->s_fs_info && cetrafs_opts_unmet(fci, sb->s_fs_info, &what))
        pr_warn("%s: remount asked for %s, which is fixed at mount time -- NOT applied; unmount and mount again\n",
                sb->s_id, what);

    /* Only a flag the reconfigure names can change: the VFS applies
     * sb_flags under sb_flags_mask. fspick(2) builds the context with
     * both zero, so a new-API reconfigure that never mentions ro or rw
     * carries no SB_RDONLY -- and read, unmasked, as a flip to
     * read-write on a read-only mount (audit 2026-11-06 L26). */
    if ((fc->sb_flags_mask & SB_RDONLY) && !!(fc->sb_flags & SB_RDONLY) != !!sb_rdonly(sb)) {
        pr_err(
            "remount %s is not supported: cluster participation (journal replay, "
            "Zone Group ownership, the defrag janitor) is established at mount time. "
            "Unmount and mount again.\n",
            (fc->sb_flags & SB_RDONLY) ? "read-write -> read-only" : "read-only -> read-write");
        return -EINVAL;
    }

    return 0;
}

static const struct fs_context_operations cetrafs_context_ops = {
    .parse_param = cetrafs_parse_param,
    .get_tree = cetrafs_get_tree,
    .reconfigure = cetrafs_reconfigure,
    .free = cetrafs_free_fc,
};

/* Set up an fs_context for a cetrafs mount (called by file_system_type in kmod.c) */
int cetrafs_init_fs_context(struct fs_context *fc)
{
    struct cetrafs_fc_info *fci = kzalloc(sizeof(*fci), GFP_KERNEL);

    if (!fci)
        return -ENOMEM;
    fci->file_lock = true; /* default: the exclusive open lock is ON */
    fc->fs_private = fci;
    fc->ops = &cetrafs_context_ops;
    return 0;
}

/* Unmount a cetrafs partition */
/* Superblocks torn down since load: lets a TEST ONLY path tell that the
 * one it did not pin is gone (nslock.c, nslock_defer_unpinned). */
atomic_t cetrafs_sb_kills = ATOMIC_INIT(0);

void cetrafs_kill_sb(struct super_block *sb)
{
    atomic_inc(&cetrafs_sb_kills);
    pr_debug("kill_sb()\n");
    /* Before kill_block_super(): its evict_inodes() skips an inode a
     * queued reconcile still pins, and that reconcile's iput() would
     * then evict it after put_super. */
    cetrafs_sb_cold_close(sb);
    /* kill_block_super() will invoke ->put_super() where we free sbi */
    kill_block_super(sb);
    pr_info("unmounted\n");
}
