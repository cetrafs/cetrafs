// SPDX-License-Identifier: GPL-2.0-or-later
// fs.c — CETRAFS mount/umount with full superblock validation
// Tested against Linux 7.1+ headers (fs_context-only mount API)
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/sched/mm.h>
#include <linux/bitmap.h>
#include <linux/blkdev.h>
#include <linux/buffer_head.h>
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
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/stddef.h>
#include <linux/string.h>
#include <linux/xarray.h>
#include <linux/xattr.h>

#include <linux/overflow.h>
#include "kmod.h" /* on-disk layout; uses __le* when __KERNEL__ is set */

/* Forward decls for exported symbols to silence -Wmissing-prototypes */
int cetrafs_init_fs_context(struct fs_context *fc);
void cetrafs_kill_sb(struct super_block *sb);
void cetrafs_free_sb_info(struct super_block *sb);
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
void cetrafs_sb_owned_bgs(struct super_block *sb, const unsigned long **out_bits, u32 *out_nbits);

/* ------ private superblock info kept in s_fs_info ------ */
struct cetrafs_lba_range {
    u64 start, end; /* [start, end) */
};

struct cetrafs_sb_info {
    u32 block_size;   /* bytes (expected 4096) */
    u64 total_blocks; /* from SB; sanity-checked against device */
    u32 zg_count;
    u32 bg_count;
    u64 bg_size_blocks;
    u64 bg_regions_start;

    /* Total data-block capacity, summed once at mount from every BG
     * descriptor. Fixed at mkfs time and never changes, so statfs reads
     * it from here instead of re-deriving it per call (see
     * cetrafs_statfs()'s comment for what that used to cost). */
    u64 total_data_blocks;
    cetrafs_superblock_t *raw_sb; /* exact on-disk image (for debug) */

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
     * corruption, but it is a lost update either way and it never
     * self-corrects: the count is seeded by one scan at mount and only
     * adjusted from then on. */
    atomic64_t free_inodes;

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
        u64 hb_seq;            /* last hb_seq we saw on this row */
        /* Which machine that hb_seq belongs to. hb_seq restarts at 1 when
         * a row is registered afresh, so on its own an old sample could
         * match a NEW node's first beats -- and a live, just-registered
         * node was judged stale at once, from a sample of its predecessor
         * (audit 2026-11-05, class 28). Not the fence_epoch: our own
         * reclaim bumps it, and a watch reset there would call the peer
         * alive again between its fence and the reclaims that follow. */
        u8 uuid[CETRAFS_NODE_UUID_LEN];
        unsigned long seen_at; /* local jiffies when it last CHANGED */
        bool valid;            /* have we ever sampled this row? */
        /* The hb_seq of the last STALE verdict: what a reclaim acting
         * on that verdict must still find (the fence, node.c). Not
         * hb_seq above, which the next tick re-samples. */
        u64 judged_seq;
        bool judged;
        /* The hb_seq the last fence of this row landed on: what every
         * reclaim CAS that follows the fence must still find on the row
         * AFTER it lands (cetrafs_node_reattached_since_fence()). */
        u64 fenced_seq;
        bool fenced;
    } *peers;
    u32 peer_count;

    /* This node's Node Registry row's fence_epoch as it stood when we
     * registered. The heartbeat compares the live value against this
     * every tick: a difference means a peer declared us dead and took
     * something of ours, so we must fence (this is the replacement for the
     * old SCSI PR registration lease). */
    u64 fence_epoch;

    /* True only once cetrafs_node_register() has actually succeeded for
     * this mount -- node_id alone can't tell cetrafs_free_sb_info()
     * that, since it's a plain kzalloc()'d u32 that reads as 0 (a real,
     * claimable row index) even when registration was never reached or
     * itself failed. Guards cetrafs_node_unregister() below: calling it
     * on an sbi that never actually registered would try to release
     * some *other* node's row 0 right out from under it. */
    bool node_registered;

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

    /* errors= and corruption= (mount options, fixed for the mount's
     * life). See cetrafs_sb_fatal() and cetrafs_sb_corrupt(). */
    bool errors_panic;
    bool corruption_stop;
    /* Integrity errors seen on this mount (nonzero: the volume needs
     * fsck), and the inode numbers they were found in: every write to
     * one of those is refused until a remount. In memory only -- the
     * on-disk format has no field for it. */
    atomic_t corruptions;
    struct xarray bad_inos;

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
     * ordinary self-fence. Armed by the first successful renewal, and
     * only on a mount that can have peers (CAW). See
     * cetrafs_sb_lease_renewed().
     */
    struct super_block *sb; /* for lease_work */
    bool lease_active;
    unsigned long lease_until;
    unsigned long lease_lost; /* bit 0: expired, latched */
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
     * stop self-fences after three intervals, before the stale window
     * a peer must wait out (cetrafs_sb_lease_renewed()); and one that
     * WAS judged stale -- wrongly or not -- sees its epoch move on its
     * next heartbeat tick and fences. So a ZG can be taken from under
     * this cache, and this node can go on allocating from it until that
     * tick at the latest; every write after it is refused
     * (tests/kernel/zg_steal_victim_fences.sh). Nothing here re-reads
     * the ZG record: that would be a device round trip per block. */
    DECLARE_BITMAP(owned_zgs, CETRAFS_MAX_ZONE_GROUPS);


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

    /* Which BGs have a free_data_blocks adjustment sitting dirty-but-
     * not-yet-synced -- see alloc.c's cetrafs_bg_adjust_free_blocks()
     * and cetrafs_flush_dirty_free_counts(). Sized to bg_count at
     * mount time (bg_count has no fixed upper bound unlike
     * CETRAFS_MAX_ZONE_GROUPS, so this can't be a static array like
     * owned_zgs above) and freed in cetrafs_free_sb_info(). */
    unsigned long *bg_free_dirty;

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
     * Both are sized to bg_count at mount and never reallocated, so a
     * lockless reader can never see a freed array.
     */
    u16 *bg_owner_zg;
    unsigned long *owned_bgs;

    /*
     * Where each Block Group's DESCRIPTOR lives.
     *
     * It used to be bg_table_start + bg_id, full stop. The table is a
     * chain now (cetrafs_bg_segment_t): the first segment is still that
     * contiguous run, and growing appends segments elsewhere rather
     * than moving anything. Resolving an id therefore means knowing
     * which segment holds it.
     *
     * Kept as a flat array, built once at mount, because this is read
     * on the per-block allocation path and a walk of the chain there
     * would be a lookup where there used to be an addition
     * (PERFORMANCE.md rule 1). One u64 per Block Group: 512 KiB for a
     * 64 TiB volume, which buys an O(1) answer with no device read.
     */
    u64 *bg_desc_lba;

    /*
     * Every APPENDED Block Group table segment, [header, last
     * descriptor], kept from the mount's chain walk. A grow puts each in
     * a reserve past the data area, and the next grow leaves that
     * reserve as a hole INSIDE [bg_regions_start, bg_data_end): live
     * descriptors the address guard must refuse
     * (cetrafs_sb_lba_run_hits_bg_table()). Empty on a never-grown
     * volume; growing is offline, so it never changes while mounted.
     */
    struct cetrafs_lba_range *bg_segs;
    u32 bg_nsegs;

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
    unsigned long *bmap_alloc_dirty;

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
    atomic64_t *bg_free_delta;
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
    atomic64_t *bg_alloc_seq;
    unsigned long bg_sweep_last; /* jiffies of the last foreign-descriptor sweep */
    unsigned long pf_drain_last; /* jiffies of the last on-demand pending-free drain */

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

    /* Each BG count's ownership epoch (cetrafs_block_group_t.
     * reconcile_seq) as of OUR reconcile -- the epoch our accrued
     * deltas were born under. The delta-apply CAS refuses an image
     * whose epoch moved (a new owner reconciled; our deltas' durable
     * effects are already in its recount). Written on the ownership
     * paths (alloc.c's reconcile, zonegroup.c's re-attach seeding),
     * read at flush. Moving it DROPS any delta still accrued for that
     * BG (cetrafs_sb_set_bg_epoch()): the epoch only moves on a
     * recount, and a recount already includes it. */
    u64 *bg_count_epoch;

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
};

/* Mount-option state, carried on fc->fs_private from parse time to
 * fill_super(). Only one option so far: file_lock (default on). */
static void cetrafs_sb_stop_work(struct work_struct *w);

struct cetrafs_fc_info {
    bool file_lock;
    bool errors_panic;    /* errors=panic */
    bool corruption_stop; /* corruption=stop */
    /* Which of the above were STATED, rather than defaulted: only a
     * stated option can be "asked for and not in force". */
    bool file_lock_set, errors_set, corruption_set;
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

#define CETRAFS_MOUNT_FAIL_POINT(stage)                                                  \
    do {                                                                                 \
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
static u32 cetrafs_bgseg_crc(const cetrafs_bg_segment_t *seg)
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

    r[n++] = (struct cetrafs_region) {"superblock", 0, 1};
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

    ondisk = (cetrafs_superblock_t *) bh->b_data;

    /* Basic identity checks (LE on disk) */
    if (le32_to_cpu(ondisk->magic) != CETRAFS_MAGIC) {
        if (!(fc->sb_flags & SB_SILENT))
            pr_err("bad magic: 0x%08x\n", le32_to_cpu(ondisk->magic));
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
        sbi->bg_count = bg_cnt;
        sbi->bg_size_blocks = bg_size_blocks;
        sbi->bg_regions_start = bg_regions_start;
        /* On unless an operator turns them off -- see the field
         * comments. Never persisted: a switch that survived a remount
         * would be a mount option or an on-disk flag, and this is
         * neither. */
        sbi->defrag_enabled = true;
        sbi->auto_defrag_enabled = true;
        xa_init(&sbi->bad_inos);
        sbi->sb = sb;
        INIT_WORK(&sbi->stop_work, cetrafs_sb_stop_work);
        {
            const struct cetrafs_fc_info *fci = fc ? fc->fs_private : NULL;

            sbi->errors_panic = fci ? fci->errors_panic : false;
            sbi->corruption_stop = fci ? fci->corruption_stop : false;

            /* The operator's REQUESTED mode. May be overridden below by the
             * cluster's mode (the first mounter leads); the authoritative
             * announcement is emitted there, once the effective mode is
             * known. */
            sbi->file_lock_enabled = fci ? fci->file_lock : true;
            sbi->file_lock_requested = sbi->file_lock_enabled;
        }
        sbi->hb_interval_secs = cetrafs_param_hb_interval_secs();
        sbi->stale_secs = cetrafs_param_stale_secs();

        /* Per-peer liveness watch (see the struct's own comment). One
         * entry per Node Registry row. Its allocation failing used to be
         * accepted: cetrafs_node_is_stale() then answers "cannot judge,
         * assume alive" for every peer, for the life of the mount -- no
         * dead peer's Zone Groups, locks or journal ever reclaimed, and
         * nothing said why (audit L30). Refused with the rest below. */
        spin_lock_init(&sbi->resv_list_lock);
        spin_lock_init(&sbi->nsrel_lock);
        spin_lock_init(&sbi->flrel_lock);
        spin_lock_init(&sbi->prrel_lock);
        spin_lock_init(&sbi->rcrel_lock);
        mutex_init(&sbi->nsrel_mutex);
        INIT_LIST_HEAD(&sbi->resv_list);

        spin_lock_init(&sbi->peer_lock);
        sbi->peer_count = le32_to_cpu(ondisk->node_table_count);
        if (sbi->peer_count)
            sbi->peers = kcalloc(sbi->peer_count, sizeof(*sbi->peers), GFP_KERNEL);
        mutex_init(&sbi->alloc_mutex);
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

        sbi->bmap_alloc_dirty = bitmap_zalloc(bg_cnt, GFP_KERNEL);
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
        sbi->bg_free_dirty = bitmap_zalloc(bg_cnt, GFP_KERNEL);
        sbi->bg_free_delta = kcalloc(bg_cnt, sizeof(*sbi->bg_free_delta), GFP_KERNEL);
        sbi->bg_alloc_seq = kcalloc(bg_cnt, sizeof(*sbi->bg_alloc_seq), GFP_KERNEL);
        sbi->bg_count_epoch = kcalloc(bg_cnt, sizeof(*sbi->bg_count_epoch), GFP_KERNEL);
        sbi->bg_owner_zg = kcalloc(bg_cnt, sizeof(*sbi->bg_owner_zg), GFP_KERNEL);
        sbi->owned_bgs = bitmap_zalloc(bg_cnt, GFP_KERNEL);
        sbi->bg_desc_lba = kcalloc(bg_cnt, sizeof(*sbi->bg_desc_lba), GFP_KERNEL);
        if (!sbi->bg_free_dirty || !sbi->bg_free_delta || !sbi->bg_alloc_seq || !sbi->bg_count_epoch ||
            !sbi->bmap_alloc_dirty || !sbi->bg_owner_zg || !sbi->owned_bgs || !sbi->bg_desc_lba || !sbi->inode_birth) {
            kfree(sbi->bg_desc_lba);
            bitmap_free(sbi->owned_bgs);
            kfree(sbi->bg_owner_zg);
            kfree(sbi->bg_count_epoch);
            kfree(sbi->bg_free_delta);
            kfree(sbi->bg_alloc_seq);
            bitmap_free(sbi->bmap_alloc_dirty);
            bitmap_free(sbi->alloc_shadow);
    kvfree(sbi->inode_birth);
            bitmap_free(sbi->bg_free_dirty);
            kfree(sbi->zg_pf_drop_blocks);
            kfree(sbi->zg_pf_drop_runs);
            kfree(sbi->zg_pf_full_until);
            kfree(sbi->peers);
            kfree(sbi);
            brelse(bh);
            return -ENOMEM;
        }

        sbi->raw_sb = kmemdup(ondisk, sizeof(*ondisk), GFP_KERNEL); /* every path reads it (cetrafs_sb_raw()) */
        if (!sbi->raw_sb) {
            kfree(sbi->bg_desc_lba);
            bitmap_free(sbi->owned_bgs);
            kfree(sbi->bg_owner_zg);
            kfree(sbi->bg_count_epoch);
            kfree(sbi->bg_free_delta);
            kfree(sbi->bg_alloc_seq);
            bitmap_free(sbi->bmap_alloc_dirty);
            bitmap_free(sbi->alloc_shadow);
    kvfree(sbi->inode_birth);
            bitmap_free(sbi->bg_free_dirty);
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
        sbi->cold_wq = alloc_workqueue("cetrafs_cold", WQ_MEM_RECLAIM, 0);
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
                           sb->s_id, who[0] ? (int) strlen(who) : 17, who[0] ? who : "an offline tool");
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

                rc = cetrafs_node_cluster_file_lock_mode(sb, my_uuid, &cluster_mode);
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

        /* Capacity, once: statfs needs a total, and it is the one part
         * of the old per-BG sweep that cannot come from the ZG
         * aggregates (they carry free, not total). It never changes. */
        {
            u32 nbg = le32_to_cpu(ondisk->block_group_count), b;

            /*
             * Resolve every Block Group's descriptor address BEFORE
             * reading any of them -- cetrafs_bg_mount_info() below
             * needs the map it is helping to build. Walks the chain
             * once: the implicit first segment at bg_table_start, then
             * each appended segment's header
             * (docs/internal/BG-OWNERSHIP-DESIGN.md).
             */
            /* Every appended segment's [header, last descriptor] run,
             * checked against the Block Groups once their descriptors
             * have been read (below). */
            struct cetrafs_lba_range *segs = NULL;
            u32 nsegs = 0;
            {
                u64 first = le64_to_cpu(ondisk->bg_table_first_count);
                u64 seg_lba = le64_to_cpu(ondisk->bg_table_next);
                u64 tbl = le64_to_cpu(ondisk->bg_table_start);
                u32 filled = 0, guard = 0;

                /* Zero on a volume that has never been grown: the table
                 * is the contiguous run it has always been. */
                if (!first || first > nbg)
                    first = nbg;
                for (b = 0; b < first && b < nbg; b++)
                    sbi->bg_desc_lba[b] = tbl + b;
                filled = (u32) first;

                /* To the END of the chain, not just until enough
                 * descriptors are collected: stopping early never
                 * follows the tail's next, so a loop or a link into
                 * nowhere would mount clean. */
                while (seg_lba) {
                    struct buffer_head *sbh;

                    /* The link itself, before it is followed: a next
                     * pointing off the device is a corrupt chain, not an
                     * I/O error to puzzle over. */
                    if (seg_lba >= le64_to_cpu(ondisk->total_blocks)) {
                        pr_err("BG table chain links to block %llu, past the end of the device (%llu)\n",
                               (unsigned long long) seg_lba, (unsigned long long) le64_to_cpu(ondisk->total_blocks));
                        if (filled == nbg) /* what a grow that died before its publish leaves */
                            pr_err("a grow was interrupted before it published -- re-run growfs.cetra\n");
                        kfree(segs);
                        cetrafs_free_sb_info(sb);
                        brelse(bh);
                        return -EUCLEAN;
                    }
                    sbh = sb_bread(sb, seg_lba);
                    const cetrafs_bg_segment_t *seg;
                    u32 cnt, i;

                    /* A chain is a loop waiting to happen; bound it by
                     * the only number that can honestly bound it. */
                    if (++guard > nbg + 1) {
                        pr_err("BG table chain does not terminate -- refusing\n");
                        brelse(sbh);
                        kfree(segs);
                        cetrafs_free_sb_info(sb);
                        brelse(bh);
                        return -EUCLEAN;
                    }
                    if (!sbh) {
                        kfree(segs);
                        cetrafs_free_sb_info(sb);
                        brelse(bh);
                        return -EIO;
                    }
                    seg = (const cetrafs_bg_segment_t *) sbh->b_data;
                    if (le32_to_cpu(seg->magic) != CETRAFS_BGSEG_MAGIC) {
                        pr_err("BG table segment at %llu has no magic\n", (unsigned long long) seg_lba);
                        brelse(sbh);
                        kfree(segs);
                        cetrafs_free_sb_info(sb);
                        brelse(bh);
                        return -EUCLEAN;
                    }
                    /*
                     * The checksum this header CARRIES, which the mount
                     * path never looked at.
                     *
                     * growfs writes it and fsck verifies it; here only
                     * the magic was checked -- so a single flipped bit
                     * in count, first_bg_id or next was trusted
                     * completely, by the one reader that acts on them.
                     * The field exists for exactly this and was being
                     * ignored.
                     */
                    if (cetrafs_bgseg_crc(seg) != (u32) le64_to_cpu(seg->checksum)) {
                        pr_err("BG table segment at %llu fails its checksum\n", (unsigned long long) seg_lba);
                        brelse(sbh);
                        kfree(segs);
                        cetrafs_free_sb_info(sb);
                        brelse(bh);
                        return -EUCLEAN;
                    }

                    cnt = le32_to_cpu(seg->count);
                    /*
                     * Checked BEFORE the loop, not after it.
                     *
                     * 'cnt' comes off the device and 'filled' is a u32:
                     * a segment claiming four billion descriptors walked
                     * that many times, wrapped 'filled' past 2^32, and
                     * could land back on exactly nbg -- at which point
                     * both the test below and the "describes all of
                     * them" test further down PASS, with bg_desc_lba[]
                     * overwritten by whatever the last passes wrote.
                     * The loop also ran four billion times before any of
                     * that was noticed.
                     */
                    if (cnt > nbg - filled) {
                        pr_err("BG table segment at %llu claims %u descriptors; only %u are left of %u\n",
                               (unsigned long long) seg_lba, cnt, nbg - filled, nbg);
                        if (filled == nbg) /* what a grow that died before its publish leaves */
                            pr_err("a grow was interrupted before it published -- re-run growfs.cetra\n");
                        brelse(sbh);
                        kfree(segs);
                        cetrafs_free_sb_info(sb);
                        brelse(bh);
                        return -EUCLEAN;
                    }
                    /*
                     * And the descriptors a segment points at have to be
                     * ON the device. Nothing bounded them, so a corrupt
                     * segment aimed every descriptor wherever it liked.
                     */
                    if (seg_lba + 1 + cnt > le64_to_cpu(ondisk->total_blocks)) {
                        pr_err("BG table segment at %llu describes blocks past the end of the device (%llu)\n",
                               (unsigned long long) seg_lba, (unsigned long long) le64_to_cpu(ondisk->total_blocks));
                        brelse(sbh);
                        kfree(segs);
                        cetrafs_free_sb_info(sb);
                        brelse(bh);
                        return -EUCLEAN;
                    }
                    /*
                     * And WHERE it is. Only the first segment went through
                     * cetrafs_validate_layout(); an appended one could sit
                     * on the inode table and pass, and every descriptor
                     * update after that -- a free-count CAS, an ownership
                     * change -- is a write into whatever is really there.
                     * A grow only ever puts a segment in a tail reserve,
                     * past every fixed table, so nothing below
                     * bg_regions_start is legal; overlap with a Block
                     * Group is checked once their descriptors are read.
                     * And a segment must continue the numbering exactly.
                     */
                    if (seg_lba < le64_to_cpu(ondisk->bg_regions_start) || le32_to_cpu(seg->first_bg_id) != filled) {
                        pr_err("BG table segment at %llu (first_bg_id %u, expected %u) lies among the fixed tables "
                               "below %llu or breaks the numbering -- refusing\n",
                               (unsigned long long) seg_lba, le32_to_cpu(seg->first_bg_id), filled,
                               (unsigned long long) le64_to_cpu(ondisk->bg_regions_start));
                        brelse(sbh);
                        kfree(segs);
                        cetrafs_free_sb_info(sb);
                        brelse(bh);
                        return -EUCLEAN;
                    }
                    {
                        void *n = krealloc(segs, (nsegs + 1) * sizeof(*segs), GFP_KERNEL);

                        if (!n) {
                            brelse(sbh);
                            kfree(segs);
                            cetrafs_free_sb_info(sb);
                            brelse(bh);
                            return -ENOMEM;
                        }
                        segs = n;
                        segs[nsegs].start = seg_lba;
                        segs[nsegs].end = seg_lba + 1 + cnt;
                        nsegs++;
                    }
                    for (i = 0; i < cnt; i++, filled++)
                        sbi->bg_desc_lba[filled] = seg_lba + 1 + i;
                    seg_lba = le64_to_cpu(seg->next);
                    brelse(sbh);
                }

                if (filled != nbg) {
                    pr_err("BG table chain describes %u of %u Block Groups\n", filled, nbg);
                    kfree(segs);
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return -EUCLEAN;
                }
            }

            sbi->total_data_blocks = 0;
            for (b = 0; b < nbg; b++) {
                u64 t = 0;
                u32 owner = CETRAFS_NODE_ID_NONE;
                int brc;

                /* Same single pass now also records which Zone Group
                 * owns each Block Group, which is what lets ownership
                 * be answered from memory from here on. */
                u64 bstart = 0, blen = 0;
                u32 si;

                brc = cetrafs_bg_mount_info(sb, b, &t, &owner, &bstart, &blen);
                /* A descriptor segment inside a Block Group is a table
                 * the allocator will write data over, and data a
                 * descriptor update will write over. */
                for (si = 0; !brc && si < nsegs; si++) {
                    if (segs[si].start < bstart + blen && bstart < segs[si].end) {
                        pr_err("BG table segment [%llu,%llu) overlaps Block Group %u [%llu,+%llu) -- refusing\n",
                               (unsigned long long) segs[si].start, (unsigned long long) segs[si].end, b,
                               (unsigned long long) bstart, (unsigned long long) blen);
                        brc = -EUCLEAN;
                    }
                }
                if (brc) {
                    /*
                     * The result used to be DISCARDED on failure, and
                     * the mount carried on.
                     *
                     * cetrafs_read_bg_geom() has already retried a
                     * checksum mismatch, so an error here means the
                     * descriptor really does not verify -- and skipping
                     * it does not leave that Block Group unknown, it
                     * leaves it WRONG: bg_owner_zg[] is kcalloc'd, so
                     * the group silently reads as owned by Zone Group
                     * 0, and total_data_blocks is short by its
                     * capacity. The allocator then works from both.
                     *
                     * Found by the fuzzer's fsck-versus-mount oracle
                     * the first time it could see this class at all.
                     */
                    pr_err("Block Group %u's descriptor does not verify (%d) -- refusing to mount\n", b, brc);
                    kfree(segs);
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return brc == -EIO ? -EIO : -EUCLEAN;
                }
                sbi->total_data_blocks += t;
                sbi->bg_owner_zg[b] = (u16) owner;
            }
            sbi->bg_segs = segs;
            sbi->bg_nsegs = nsegs;
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

        /* Find/claim this node's Node Registry row. */
        {
            u8 node_uuid[CETRAFS_NODE_UUID_LEN];
            int rc = cetrafs_node_register(sb, sbi->file_lock_enabled ? CETRAFS_FLOCK_MODE_ON : CETRAFS_FLOCK_MODE_OFF,
                                           &sbi->node_id, node_uuid);

            if (rc) {
                pr_err("node registration failed: %d\n", rc);
                cetrafs_free_sb_info(sb);
                brelse(bh);
                return rc;
            }
            sbi->node_registered = true;
            memcpy(sbi->node_uuid, node_uuid, CETRAFS_NODE_UUID_LEN);
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
                               sb->s_id, who[0] ? (int) strlen(who) : 17, who[0] ? who : "an offline tool");
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
             * any more. Nothing writes block 0 under a mount (growfs is
             * offline and holds a repair claim), so any difference is
             * a rewrite. */
            if (sbi->raw_sb) {
                struct buffer_head *sbh = cetrafs_bread_uncached(sb, CETRAFS_SB_BLOCK_NR);

                if (!sbh || memcmp(sbh->b_data, sbi->raw_sb, sizeof(*sbi->raw_sb)) != 0) {
                    if (sbh)
                        pr_err("%s: the superblock was rewritten while this mount was in flight (mkfs?) -- "
                               "refusing to mount\n",
                               sb->s_id);
                    else
                        pr_err("mount: post-registration superblock re-read failed\n");
                    brelse(sbh);
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return sbh ? -EBUSY : -EIO;
                }
                brelse(sbh);
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
                    cetrafs_free_sb_info(sb);
                    brelse(bh);
                    return rc;
                }
            }
            rc = cetrafs_journal_attach_node(sb, sbi->node_id);
            if (rc) {
                pr_err("own journal replay/attach failed: %d\n", rc);
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
                rc = cetrafs_zg_drain_pending_frees(sb);
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
    /* s_maxbytes used to be the plain VFS default
     * (MAX_LFS_FILESIZE, ~8 EiB -- no relation to this volume's real
     * capacity at all). It's now the worst-case guaranteed amount of ZG
     * capacity this/any node could ever claim -- see zonegroup.c's
     * cetrafs_compute_max_file_size() for the exact formula and why it
     * has to be a fixed-for-the-mount's-life constant. The VFS enforces
     * this automatically (setattr_prepare(), already called by
     * cetrafs_setattr(), rejects ATTR_SIZE growth past s_maxbytes with
     * -EFBIG) -- no extra check needed in file.c. A failure here isn't
     * fatal to the mount: fall back to the old unbounded default rather
     * than refusing to mount over what's fundamentally an informational
     * cap, but it IS logged loudly, since silently keeping the
     * unbounded default would quietly undo the whole point of this. */
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

    /* The fallback is the FORMAT ceiling, not MAX_LFS_FILESIZE: a file
     * longer than 2^32 blocks cannot be addressed by
     * cetrafs_extent_t.ee_block at all, so an unbounded fallback would
     * let an error path reopen the aliasing hole the clamp exists to
     * close. Falling back to a cap that is merely too generous for this
     * volume's capacity is fine -- the allocator returns -ENOSPC. */
    sb->s_maxbytes = min_t(loff_t, MAX_LFS_FILESIZE, (loff_t) (CETRAFS_MAX_FILE_BLOCKS * CETRAFS_BLOCK_SIZE));
    /* link() and mkdir() refuse past this (EMLINK). Far below the u32
     * the record stores, so links added by peers at once -- each checked
     * against its own in-core count -- still cannot reach the wrap; the
     * apply saturates as well (cetrafs_ns_apply_delta()). */
    sb->s_max_links = CETRAFS_MAX_LINKS;
    {
        loff_t max_file_size;
        int rc = cetrafs_compute_max_file_size(sb, &max_file_size);

        if (rc)
            pr_err("failed to compute max file size, falling back to the format ceiling: %d\n", rc);
        else
            sb->s_maxbytes = max_file_size;
    }
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

    brelse(bh);
    pr_info("mounted OK: Z=%u, B=%u, bg_size=%llu blocks, data@%llu, node_id=%u\n", sbi->zg_count, sbi->bg_count,
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
    u64 hb_seq = cetrafs_le64(ne->hb_seq);
    u32 peer_hb_interval = cetrafs_le32(ne->hb_interval_secs);
    bool stale;

    if (!sbi || !sbi->peers || node_id >= sbi->peer_count)
        return false; /* cannot judge -> never reclaim */

    spin_lock(&sbi->peer_lock);
    w = &sbi->peers[node_id];
    /* A new sample whenever the counter moved OR another machine holds
     * the row. The safe direction -- a reset only delays a verdict. A row
     * seen not REGISTERED is forgotten (cetrafs_sb_peer_watch_forget()).
     * Not covered without a format change: the SAME machine re-registering
     * a retired row we never saw retired, at exactly the hb_seq we last
     * sampled -- a registration nonce in the row (docs/internal/TODO.md). */
    if (!w->valid || w->hb_seq != hb_seq || memcmp(w->uuid, ne->node_uuid, CETRAFS_NODE_UUID_LEN) != 0) {
        w->valid = true;
        w->hb_seq = hb_seq;
        memcpy(w->uuid, ne->node_uuid, CETRAFS_NODE_UUID_LEN);
        w->seen_at = now;
        stale = false;
    } else {
        /*
         * The window is ours, but it is floored at four of the PEER's
         * own advertised beats.
         *
         * Our stale_secs says how long WE are willing to wait; it says
         * nothing about how often the other node actually ticks. If that
         * node runs a longer interval than we expect -- a different
         * build, a tuned deployment, or simply a test that compressed
         * the parameters on one node and not the other -- then a
         * perfectly healthy peer stops looking alive between its beats,
         * and we go on to break its locks and fence it. Flooring at
         * 4x its own rate makes the decision depend on the peer's real
         * behaviour rather than on our configuration matching its.
         *
         * A row written before hb_interval_secs existed advertises 0,
         * and then our own window is all there is to go on.
         */
        unsigned long window = (unsigned long) cetrafs_sb_stale_secs(sb) * HZ;
        /* Clamp the PEER's advertised interval: a hostile or corrupt
         * (checksum-valid) node row can carry any hb_interval_secs, and an
         * unclamped *4 would both floor this window arbitrarily high (an
         * un-reclaimable peer) and overflow. A real node's interval is
         * bounded by the operator controls to CETRAFS_HB_INTERVAL_MAX_SECS. */
        u32 pi = min_t(u32, peer_hb_interval, CETRAFS_HB_INTERVAL_MAX_SECS);
        unsigned long peer_floor = (unsigned long) pi * 4 * HZ;

        if (pi && peer_floor > window)
            window = peer_floor;
        stale = time_after(now, w->seen_at + window);
        if (stale) {
            w->judged_seq = hb_seq;
            w->judged = true;
        }
    }
    spin_unlock(&sbi->peer_lock);
    return stale;
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

/* The hb_seq of the last stale verdict on a peer's row, or false if it
 * was never judged stale by progress. For the fence (node.c), which must
 * refuse to act on a verdict about an incarnation that has since
 * re-attached. The judged value, not the last sample: a tick between
 * the verdict and the fence re-samples the moved row, and comparing
 * against that let the fence through (fence_vs_reattach.sh). */
bool cetrafs_sb_peer_watched_seq(struct super_block *sb, u32 node_id, u64 *out)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool valid = false;

    if (!sbi || !sbi->peers || node_id >= sbi->peer_count)
        return false;
    spin_lock(&sbi->peer_lock);
    if (sbi->peers[node_id].judged) {
        *out = sbi->peers[node_id].judged_seq;
        valid = true;
    }
    spin_unlock(&sbi->peer_lock);
    return valid;
}

/* Record / fetch the hb_seq a fence of this peer's row landed on. */
void cetrafs_sb_peer_note_fenced(struct super_block *sb, u32 node_id, u64 seq)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || !sbi->peers || node_id >= sbi->peer_count)
        return;
    spin_lock(&sbi->peer_lock);
    sbi->peers[node_id].fenced_seq = seq;
    sbi->peers[node_id].fenced = true;
    spin_unlock(&sbi->peer_lock);
}

bool cetrafs_sb_peer_fenced_seq(struct super_block *sb, u32 node_id, u64 *out)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    bool valid = false;

    if (!sbi || !sbi->peers || node_id >= sbi->peer_count)
        return false;
    spin_lock(&sbi->peer_lock);
    if (sbi->peers[node_id].fenced) {
        *out = sbi->peers[node_id].fenced_seq;
        valid = true;
    }
    spin_unlock(&sbi->peer_lock);
    return valid;
}

void cetrafs_free_sb_info(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    int flush_err = 0, r;
    u32 unreleased;

    if (!sbi)
        return;

    /* First, while everything below is still standing: a reconcile still
     * queued (a failed mount never ran kill_sb's flush) may hold the last
     * reference to an inode, and its iput() can evict it. */
    cetrafs_sb_cold_close(sb);
    if (sbi->cold_wq) {
        destroy_workqueue(sbi->cold_wq);
        sbi->cold_wq = NULL;
    }

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

    cetrafs_heartbeat_stop(sbi->hb);
    /* Park the journal flag and push the accrued free-space counters
     * out BEFORE announcing the departure below. See the sync there. */
    cetrafs_journal_shutdown(sb);
    /* Allocation bits first, then the counters that summarise them --
     * the same order as sync_fs. sync_fs already ran in
     * generic_shutdown_super(), but the VFS ignores its result there, so
     * this is the only place a failure can still change anything. */
    flush_err = cetrafs_alloc_flush_bitmaps(sb);
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
    /* Signal this node's deliberate departure on the way out -- clean
     * unmount (or a later-failing mount attempt after registration
     * already succeeded) used to leave this node's row looking exactly
     * like a merely-slow one, so a peer couldn't reclaim its ZGs/locks
     * until the full stale timeout elapsed even though this node is
     * definitively gone. See node.c's cetrafs_node_mark_offline() for
     * why this backdates last_seen rather than freeing the row outright
     * (freeing it would break this node's own re-attach on its next
     * mount). Must run after heartbeat_stop() above (a concurrent tick
     * could otherwise re-renew this row via cetrafs_node_renew_
     * heartbeat() right after we backdate it) and is guarded by
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
     * its previous life to sweep (a row with last_seen 0 is a clean
     * one), and the claims read live again the moment it beats. Left
     * unannounced, the row goes stale: peers reclaim them as a dead
     * node's, and the next mount sweeps whatever is left. */
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
    kfree(sbi->raw_sb);
    kfree(sbi->bg_desc_lba);
    kfree(sbi->bg_segs);
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
    xa_destroy(&sbi->bad_inos);
    bitmap_free(sbi->owned_bgs);
    kfree(sbi->bg_owner_zg);
    kfree(sbi->bg_count_epoch);
    kfree(sbi->bg_free_delta);
    kfree(sbi->bg_alloc_seq);
    bitmap_free(sbi->bg_free_dirty);
    bitmap_free(sbi->bmap_alloc_dirty);
    bitmap_free(sbi->alloc_shadow);
    kvfree(sbi->inode_birth);
    kfree(sbi->zg_pf_drop_blocks);
    kfree(sbi->zg_pf_drop_runs);
    kfree(sbi->zg_pf_full_until);
    kfree(sbi->peers);
    kfree(sbi);
    sb->s_fs_info = NULL;
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

/* Record a dropped run. Returns true the FIRST time in a burst, which
 * is when the caller does the expensive diagnostic. */
bool cetrafs_sb_zg_pf_note_drop(struct super_block *sb, u32 zg_id, u32 count, unsigned int backoff_ms)
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
    WRITE_ONCE(sbi->zg_pf_drop_runs[zg_id], READ_ONCE(sbi->zg_pf_drop_runs[zg_id]) + 1);
    WRITE_ONCE(sbi->zg_pf_drop_blocks[zg_id], READ_ONCE(sbi->zg_pf_drop_blocks[zg_id]) + count);
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
 * Does [lba, lba+count) touch an appended Block Group table segment?
 * The half of cetrafs_lba_run_is_data() that needs the mount's chain
 * walk. O(grows) with no I/O; zero iterations on a never-grown volume.
 */
bool cetrafs_sb_lba_run_hits_bg_table(struct super_block *sb, u64 lba, u64 count)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u32 i;

    if (!sbi)
        return true;
    for (i = 0; i < sbi->bg_nsegs; i++)
        if (lba < sbi->bg_segs[i].end && sbi->bg_segs[i].start < lba + count)
            return true;
    return false;
}

const cetrafs_superblock_t *cetrafs_sb_raw(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? sbi->raw_sb : NULL;
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

/* Read back the cached free-inode count, for statfs. */
int cetrafs_sb_get_free_inodes(struct super_block *sb, u64 *out)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return -EINVAL;
    *out = (u64) atomic64_read(&sbi->free_inodes);
    return 0;
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
    if (!list_empty(&span->link) && (span->start != start || span->count != count))
        sbi->resv_seq++; /* re-pointed: the old run's blocks left the registry */
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
 * A nanosecond stamp for file_seq and inode generations: the real clock
 * as it read at mount, advanced by the MONOTONIC clock, and strictly
 * increasing per mount. The real clock alone can step backward (NTP, an
 * operator), and a node's own stamps are ORDERED, not just compared
 * (cetrafs_sb_own_seq_older()): a step back made a newer publish look
 * superseded and a needed refresh was declined. Anchored to the real
 * clock so a remount does not restart near values it handed out before.
 *
 * Monotonic per MOUNT only. Each mount re-anchors to the real clock, so
 * a backward step between an unmount and the next mount -- larger than
 * half the 48-bit wrap, ~1.6 days, for file_seq ordering to invert --
 * puts new stamps behind old ones on the device. The ordering compare
 * only ever runs against a note taken in the current mount, so that
 * needs one of this mount's publishes to have been lost as well. Not
 * guarded; nothing tests it.
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
 * Is own file_seq stamp `a` older than own stamp `b`? Both carry this
 * mount's stamp clock in their low 48 bits, which wrap every ~3.26
 * days. Ordering them modulo the wrap alone (as this used to) is right
 * only while they are less than HALF a wrap apart: a file
 * whose last noted publish was ~1.63 days before a newer local one had
 * the newer one judged older and refused, and its in-core state went
 * stale until close (audit L25) -- a VM image stays open that long.
 * Both stamps are in the past of this clock, so each is unwrapped as
 * its age against now, which orders any two inside a FULL wrap; a note
 * older than that cannot be placed, and is not trusted to refuse
 * anything (`noted_at` is the clock when it was taken).
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

/* Held across cetrafs_cas_region()'s no-CAW read-decide-write only; a
 * leaf lock (no CAS mutator acquires anything). */
void cetrafs_sb_cas_lock(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    mutex_lock(&sbi->cas_mutex);
}

void cetrafs_sb_cas_unlock(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    mutex_unlock(&sbi->cas_mutex);
}

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
    /* After the flag, so nothing re-dirties behind the sweep through an
     * entry point that already checks it. */
    schedule_work(&sbi->stop_work);
}

static void cetrafs_sb_stop_work(struct work_struct *w)
{
    struct cetrafs_sb_info *sbi = container_of(w, struct cetrafs_sb_info, stop_work);
    struct super_block *sb = sbi->sb;

    if (sb && sb->s_bdev) {
        unsigned long n = cetrafs_drop_dirty_metadata(sb);

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

void cetrafs_sb_corrupt_inode(struct inode *inode)
{
    cetrafs_sb_corrupt_gen(inode->i_sb, inode->i_ino, cetrafs_bad_gen(cetrafs_inode_get_generation(inode)));
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
 * TEST ONLY. Arm the lease on a mount without CAW, where no peer can
 * exist and it is otherwise off -- the loop harness has no CAW, and this
 * is how tests/kernel/lease_expiry.sh reaches it.
 */
static bool cetrafs_lease_force;
cetrafs_test_param(lease_force, cetrafs_lease_force, bool, 0644);
MODULE_PARM_DESC(lease_force, "TEST ONLY: arm the in-core lease on a mount without CAW");

static void cetrafs_sb_lease_work(struct work_struct *w)
{
    struct cetrafs_sb_info *sbi = container_of(w, struct cetrafs_sb_info, lease_work);

    cetrafs_sb_stop(sbi->sb, CETRAFS_STOP_LEASE,
                    "this node's lease expired -- no heartbeat renewal reached the device in time, so peers may "
                    "already treat it as dead");
}

/*
 * A renewal that STARTED at jiffies 't0' advertising 'interval_secs'
 * reached the device: extend the lease. The first one arms it. Nothing
 * extends a lease that has lapsed -- by then a peer may have reclaimed
 * from us, and the only way back is a remount.
 */
void cetrafs_sb_lease_renewed(struct super_block *sb, unsigned long t0, unsigned int interval_secs)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || !interval_secs || test_bit(0, &sbi->lease_lost))
        return;
    if (!READ_ONCE(sbi->lease_active)) {
        if (!cetrafs_sb_mount_has_caw(sb) && !cetrafs_lease_force)
            return; /* no peer can exist, so nobody can reclaim from us */
        if (!sbi->lease_work_ready) {
            sbi->sb = sb;
            INIT_WORK(&sbi->lease_work, cetrafs_sb_lease_work);
            sbi->lease_work_ready = true;
        }
    }
    WRITE_ONCE(sbi->lease_until, t0 + (unsigned long) interval_secs * 3 * HZ);
    smp_wmb(); /* the deadline before the flag that makes it count */
    WRITE_ONCE(sbi->lease_active, true);
}

/*
 * Renew this node's row from a long phase of the MOUNT, before the
 * heartbeat exists (audit R19). Registration lands one beat and the
 * heartbeat's first tick is the next, and between the two the mount can
 * wait minutes for a peer's replay claim to clear -- long enough for
 * every peer to judge this node stale and fence it before it has done
 * anything at all. Called from those waits; renews at most once per
 * heartbeat interval. The lease is not armed here: a mount phase that
 * stalls elsewhere must not stop itself, it is still beating no later
 * than a tick would.
 *
 * Returns -EPERM / -EOWNERDEAD if the row says this node was fenced or
 * displaced meanwhile: the mount must fail, not go on.
 */
int cetrafs_sb_mount_beat(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    int ret;

    if (!sbi || !sbi->node_registered || sbi->hb)
        return 0; /* not registered yet, or the heartbeat beats for us */
    if (sbi->mount_beat_next && time_before(jiffies, sbi->mount_beat_next))
        return 0;
    sbi->mount_beat_next = jiffies + (unsigned long) cetrafs_heartbeat_interval_secs(sb) * HZ;
    if (!sbi->mount_beat_next)
        sbi->mount_beat_next = 1;
    ret = cetrafs_node_renew_heartbeat(sb, sbi->node_id);
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

bool cetrafs_sb_is_fenced(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi)
        return false;
    if (READ_ONCE(sbi->fenced) || test_bit(0, &sbi->lease_lost))
        return true;
    if (READ_ONCE(sbi->lease_active)) {
        smp_rmb();
        if (time_after(jiffies, READ_ONCE(sbi->lease_until))) {
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

    if (!sbi)
        return;
    spin_lock(&sbi->cold_lock);
    sbi->cold_closing = true;
    spin_unlock(&sbi->cold_lock);
    if (sbi->cold_wq)
        flush_workqueue(sbi->cold_wq);
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

/* May the BACKGROUND janitor run? A manual defrag.cetra is unaffected
 * by this one; cetrafs_sb_defrag_enabled() is what covers both. */
bool cetrafs_sb_auto_defrag_enabled(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi && READ_ONCE(sbi->auto_defrag_enabled);
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
 * for every suite (a 1 s beat and 3 s window; a 3600 s beat to keep a
 * tick out of a test) and nowhere near an overflow.
 */
#define CETRAFS_PARAM_HB_MAX_SECS    3600u
#define CETRAFS_PARAM_STALE_MIN_SECS 3u
#define CETRAFS_PARAM_STALE_MAX_SECS 86400u

unsigned int cetrafs_param_hb_interval_secs(void)
{
    return clamp_t(unsigned int, READ_ONCE(cetrafs_hb_interval_secs), 1u, CETRAFS_PARAM_HB_MAX_SECS);
}

/* Bounded alone AND against the beat, as the controls file bounds an
 * operator's write: a window under CETRAFS_STALE_MIN_BEATS beats has
 * peers call this node dead while it still holds a lease of three beats
 * (hb_interval_secs=3600 with the default 120 s window: dead after two
 * minutes, leased for three hours). The window is raised to fit the beat;
 * 3 x CETRAFS_PARAM_HB_MAX_SECS is still under the cap. */
unsigned int cetrafs_param_stale_secs(void)
{
    unsigned int v = clamp_t(unsigned int, READ_ONCE(cetrafs_stale_secs), CETRAFS_PARAM_STALE_MIN_SECS,
                             CETRAFS_PARAM_STALE_MAX_SECS);

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
    if (sbi->bg_owner_zg && sbi->owned_bgs) {
        u32 b;

        for (b = 0; b < sbi->bg_count; b++)
            if (sbi->bg_owner_zg[b] == (u16) zg_id)
                set_bit(b, sbi->owned_bgs);
    }
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

    if (sbi->bg_owner_zg && sbi->owned_bgs) {
        u32 b;

        for (b = 0; b < sbi->bg_count; b++)
            if (sbi->bg_owner_zg[b] == (u16) zg_id)
                clear_bit(b, sbi->owned_bgs);
    }
}

/* The hot-path counterpart: true (with first_bg_id/bg_count filled in)
 * if this node's cache already knows it owns zg_id, false otherwise --
 * zero disk I/O either way. cetrafs_alloc_pick_bg() (zonegroup.c) is
 * the reason this exists: it used to call cetrafs_read_zg() (always a
 * forced-uncached, real device round trip) for every ZG on every single
 * new block a write needed. */
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
void cetrafs_sb_drain_bg(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    if (!sbi || !sbi->owned_bgs || bg_id >= sbi->bg_count)
        return;
    mutex_lock(&sbi->alloc_mutex);
    clear_bit(bg_id, sbi->owned_bgs);
    mutex_unlock(&sbi->alloc_mutex);
}

void cetrafs_sb_undrain_bg(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    if (!sbi || !sbi->owned_bgs || bg_id >= sbi->bg_count)
        return;
    mutex_lock(&sbi->alloc_mutex);
    if (sbi->bg_owner_zg && sbi->bg_owner_zg[bg_id] < CETRAFS_MAX_ZONE_GROUPS &&
        test_bit(sbi->bg_owner_zg[bg_id], sbi->owned_zgs))
        set_bit(bg_id, sbi->owned_bgs);
    mutex_unlock(&sbi->alloc_mutex);
}

void cetrafs_sb_set_bg_owner(struct super_block *sb, u32 bg_id, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    if (!sbi || !sbi->bg_owner_zg || bg_id >= sbi->bg_count)
        return;

    sbi->bg_owner_zg[bg_id] = (u16) zg_id;
    if (sbi->owned_bgs) {
        if (zg_id < CETRAFS_MAX_ZONE_GROUPS && test_bit(zg_id, sbi->owned_zgs))
            set_bit(bg_id, sbi->owned_bgs);
        else
            clear_bit(bg_id, sbi->owned_bgs);
    }
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

    if (!sbi || !sbi->bg_desc_lba || bg_id >= sbi->bg_count)
        return 0;
    return sbi->bg_desc_lba[bg_id];
}

u32 cetrafs_sb_bg_owner(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    if (!sbi || !sbi->bg_owner_zg || bg_id >= sbi->bg_count)
        return CETRAFS_NODE_ID_NONE;
    return sbi->bg_owner_zg[bg_id];
}

void cetrafs_sb_owned_bgs(struct super_block *sb, const unsigned long **out_bits, u32 *out_nbits)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    *out_bits = sbi ? sbi->owned_bgs : NULL;
    *out_nbits = sbi ? sbi->bg_count : 0;
}

bool cetrafs_sb_bg_is_ours(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || !sbi->owned_bgs || bg_id >= sbi->bg_count)
        return false;

    /* One bit test. This used to walk every owned Zone Group comparing
     * the Block Group id against a contiguous range; the answer is the
     * same, but it no longer depends on membership BEING contiguous,
     * which is what has to stop being true
     * (docs/internal/BG-OWNERSHIP-DESIGN.md). */
    return test_bit(bg_id, sbi->owned_bgs);
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
 * dirty BG -- see sbi->bg_free_delta's comment for why nothing is ever
 * left dirty in the buffer cache instead. */
/* Mark a BG as having un-durable allocation bits; see bmap_alloc_dirty. */
void cetrafs_sb_note_bmap_alloc(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi && sbi->bmap_alloc_dirty && bg_id < sbi->bg_count)
        set_bit(bg_id, sbi->bmap_alloc_dirty);
}

/* Does any BG have allocation bits not yet on the device? O(words), no
 * atomics -- the tree-edit gate asks this once per mapped block. */
bool cetrafs_sb_bmap_alloc_any_dirty(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || !sbi->bmap_alloc_dirty)
        return false;
    return find_first_bit(sbi->bmap_alloc_dirty, sbi->bg_count) < sbi->bg_count;
}

/* Take and clear the set, for the flush. Clearing first means a racing
 * allocation re-marks its BG rather than having its mark dropped by a
 * flush that did not cover it. */
bool cetrafs_sb_take_bmap_alloc_dirty(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || !sbi->bmap_alloc_dirty || bg_id >= sbi->bg_count)
        return false;
    return test_and_clear_bit(bg_id, sbi->bmap_alloc_dirty);
}

/* Allocations only -- see cetrafs_sb_info.bg_alloc_seq. */
u64 cetrafs_sb_bg_alloc_seq(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || !sbi->bg_alloc_seq || bg_id >= sbi->bg_count)
        return 0;
    return (u64) atomic64_read(&sbi->bg_alloc_seq[bg_id]);
}

void cetrafs_sb_accrue_bg_free(struct super_block *sb, u32 bg_id, s64 delta)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (sbi && bg_id < sbi->bg_count) {
        atomic64_add(delta, &sbi->bg_free_delta[bg_id]);
        set_bit(bg_id, sbi->bg_free_dirty);
        /* A negative delta IS an allocation. One uncontended atomic on
         * the per-block path -- no device I/O, so PERFORMANCE.md's
         * per-block budget is untouched. */
        if (delta < 0 && sbi->bg_alloc_seq)
            atomic64_inc(&sbi->bg_alloc_seq[bg_id]);
    }
}

/* This node's accrued-but-unapplied delta for one BG -- what the on-disk
 * count is missing from the owner's own point of view. */
unsigned long cetrafs_sb_pf_drain_last(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    return sbi ? READ_ONCE(sbi->pf_drain_last) : 0;
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

s64 cetrafs_sb_bg_pending_delta(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || bg_id >= sbi->bg_count)
        return 0;
    return atomic64_read(&sbi->bg_free_delta[bg_id]);
}

/* The BG count's ownership epoch (see sbi->bg_count_epoch). */
u64 cetrafs_sb_bg_epoch(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;

    if (!sbi || bg_id >= sbi->bg_count)
        return 0;
    return READ_ONCE(sbi->bg_count_epoch[bg_id]);
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
void cetrafs_sb_set_bg_epoch(struct super_block *sb, u32 bg_id, u64 seq)
{
    struct cetrafs_sb_info *sbi = sb->s_fs_info;
    u64 prev;
    s64 stale;

    if (!sbi || bg_id >= sbi->bg_count)
        return;

    prev = READ_ONCE(sbi->bg_count_epoch[bg_id]);
    WRITE_ONCE(sbi->bg_count_epoch[bg_id], seq);
    if (prev == seq)
        return; /* re-attach with nobody having reconciled: our deltas stand */

    stale = atomic64_xchg(&sbi->bg_free_delta[bg_id], 0);
    clear_bit(bg_id, sbi->bg_free_dirty);
    if (stale)
        pr_warn("BG %u: dropping an accrued free delta of %lld -- the count was recounted (epoch %llu -> %llu)\n", bg_id,
                (long long) stale, (unsigned long long) prev, (unsigned long long) seq);
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
    sbi->nsrel_count = 0;
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

/* This node's accrued-but-unapplied ZG free delta, the aggregate twin of
 * cetrafs_sb_bg_pending_delta(). statfs folds it in so the owner sees its
 * own allocations immediately, exactly as the per-BG path already did. */
u64 cetrafs_sb_total_data_blocks(struct super_block *sb)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    return sbi ? sbi->total_data_blocks : 0;
}

s64 cetrafs_sb_zg_pending_delta(struct super_block *sb, u32 zg_id)
{
    struct cetrafs_sb_info *sbi = sb ? sb->s_fs_info : NULL;

    if (!sbi || zg_id >= sbi->zg_count)
        return 0;
    return atomic64_read(&sbi->zg_free_delta[zg_id]);
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

    for_each_set_bit (bg_id, sbi->bg_free_dirty, sbi->bg_count) {
        /* Take the whole accrued delta in one go -- same reasoning as
         * the ZG loop below. */
        s64 delta;
        int rc;

        clear_bit(bg_id, sbi->bg_free_dirty);
        delta = atomic64_xchg(&sbi->bg_free_delta[bg_id], 0);
        if (!delta)
            continue;

        rc = cetrafs_bg_apply_free_delta(sb, bg_id, delta);
        if (rc < 0) {
            /* Real I/O trouble (a DROPPED stale delta is consumed inside
             * the apply, loudly): put the delta back rather than lose
             * real accounting to a transient error -- and say so, since
             * a delta stuck in memory is invisible in every other way. */
            pr_err_ratelimited("BG %u free delta %lld could not be applied (%d) -- re-accrued for the next flush\n",
                               bg_id, (long long) delta, rc);
            atomic64_add(delta, &sbi->bg_free_delta[bg_id]);
            set_bit(bg_id, sbi->bg_free_dirty);
            if (!ret)
                ret = rc;
        }
    }

    for (zg_id = 0; zg_id < sbi->zg_count; zg_id++) {
        /* Take the whole accrued delta in one go, so concurrent
         * allocations keep accruing against a fresh zero rather than
         * having their change applied twice or dropped. */
        s64 delta = atomic64_xchg(&sbi->zg_free_delta[zg_id], 0);
        int rc;

        if (!delta)
            continue;

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
            continue;
        }

        rc = cetrafs_zg_apply_free_delta(sb, zg_id, delta);
        if (rc) {
            /* Put it back rather than lose it: the aggregate is
             * cross-checked against the member BGs by fsck, so a
             * silently dropped delta shows up later as corruption. */
            atomic64_add(delta, &sbi->zg_free_delta[zg_id]);
            pr_err("ZG %u: could not apply free-count delta %lld: %d\n", zg_id, (long long) delta, rc);
            if (!ret)
                ret = rc;
        }
    }

    return ret;
}

/* ------ mount options ------ */

enum cetrafs_param { Opt_nofilelock, Opt_errors, Opt_corruption };

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
static int cetrafs_check_second_mount(struct fs_context *fc)
{
    const struct cetrafs_fc_info *fci = fc->fs_private;
    struct super_block *sb = fc->root->d_sb;
    const struct cetrafs_sb_info *sbi = sb->s_fs_info;
    const char *what;

    if (!fci || fci->filled || !sbi || !cetrafs_opts_unmet(fci, sbi, &what))
        return 0;
    pr_err("%s is already mounted without %s -- refusing a second mount that asks for it\n", sb->s_id, what);
    dput(fc->root);
    fc->root = NULL;
    deactivate_locked_super(sb);
    return -EBUSY;
}

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

    if (!!(fc->sb_flags & SB_RDONLY) != !!sb_rdonly(sb)) {
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
void cetrafs_kill_sb(struct super_block *sb)
{
    pr_debug("kill_sb()\n");
    /* Before kill_block_super(): its evict_inodes() skips an inode a
     * queued reconcile still pins, and that reconcile's iput() would
     * then evict it after put_super. */
    cetrafs_sb_cold_close(sb);
    /* kill_block_super() will invoke ->put_super() where we free sbi */
    kill_block_super(sb);
    pr_info("unmounted\n");
}
