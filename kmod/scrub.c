// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * scrub.c -- automatic background reclaim of LEAKED data blocks.
 *
 * A data block is leaked when its bitmap bit is set but no inode's
 * extent tree references it -- usually a foreign free that could not be
 * delivered (peer offline, pending-free queue full) and was dropped.
 * fsck -r reclaims these offline; this does it online.
 *
 * Freeing a "leaked" block on a LIVE filesystem is safe only because:
 *
 *  1. SCOPE TO OWNED ZGs. Only a ZG's owner allocates from it, so the
 *     in-flight allocations in a ZG this node owns are its own, and
 *     every free re-checks ownership (cached lookup) before it acts.
 *     Collectively the volume is still covered. This does NOT cover a
 *     previous owner that is alive but slow: its in-flight allocation
 *     predates the transfer, and nothing in this node's counters sees
 *     it. Adoption (zonegroup.c's cetrafs_zg_scrub_adopt_one_stale())
 *     takes a ZG only once the registry says its owner is stale, and
 *     that is a timing judgement, not a proof -- see the note after
 *     this list.
 *
 *  2. TWO PASSES WITH A GAP. A block mid-allocation (bit durable,
 *     extent not yet) looks leaked. The gap (scrub_gap_secs, 15 s by
 *     default) lets an allocation commit its extent, so pass 2 sees it
 *     as referenced. That is a margin, not a guarantee: it holds only
 *     while the allocation commits within the gap. A real allocation
 *     normally commits within one get_block(), but a stalled writer
 *     can take longer, and the gap does not bound it.
 *
 * THE PREVIOUS OWNER. Points 1 and 2 leave one case open: an owner that
 * is alive but slow, whose allocation is still in flight when its ZG is
 * adopted. The protection there is the registry lease, not the gap. The
 * peer is adopted only after its heartbeat has not advanced for the
 * staleness window; the adoption bumps its fence_epoch, and it self-fences
 * (refuses every metadata write) on its next tick, or once its own lease
 * is three intervals old. Fencing is advisory: an I/O already queued at
 * the device still lands, so a stalled owner's write can reach a block
 * this scrub has freed. That residual window is bounded by the device
 * queue, not by anything in this file.
 *
 *  3. LIVE RESERVATIONS ARE EXEMPT. Point 2 does not cover the
 *     speculative run behind the written block: lock.c claims a run
 *     ahead of need, bitmap-set, referenced by no extent, held for as
 *     long as the file is OPEN. Those are published on the mount's
 *     resv_list and scrub_free_confirmed() consults it at the moment of
 *     the free; otherwise the scrub reclaims a run its owner is still
 *     handing out and two files share blocks. The general rule:
 *     anything that leaves a block bitmap-allocated for longer than one
 *     get_block() without committing an extent MUST appear there.
 *
 *  4. FREES IN FLIGHT ARE EXEMPT. Truncate, punch, preallocation's tree
 *     rebuild, a defrag step and xattr removal publish a record that
 *     drops blocks and free them
 *     after (rule 21), and in between the blocks look exactly like
 *     point 3's runs. When a peer owns them the frees are one queue CAS
 *     per extent -- seconds to minutes for a fragmented image -- so a
 *     cycle could free them first and the drain free them again. Each
 *     such operation counts itself first, and announces itself in its
 *     registry row when any block it drops is outside its own groups
 *     (cetrafs_frees_begin()); a cycle in which this node, or any live
 *     node's row, had frees in flight, or began some, frees nothing
 *     (cetrafs_frees_quiet(); tests/kernel/scrub_spares_inflight_free.sh).
 *
 * The reference set is built from ALLOCATED inodes only. cetrafs_free_
 * inode() leaves a freed record's extents in place, so a deleted file's
 * stale record still names the blocks its delete leaked; walking only
 * allocated inodes is what makes them visible.
 *
 * THE DECIDING PASS READS FRESH. Staleness here means FEWER references,
 * never more: a stale inode-bitmap block that still reads "free" for an
 * inode a peer has since allocated makes the walk skip that inode, so
 * every block its extents name looks leaked and is freed under a live
 * file. A stale record does the same for extents added since. The
 * two-pass gap cannot help -- both passes read the same stale cache and
 * agree -- and nothing invalidates this node's copy of a peer's inode
 * table, so the window is unbounded.
 *
 * So pass 1 stays cached (it only proposes candidates, and a false
 * candidate costs nothing) and pass 2, whose verdict actually frees,
 * forces a device read of the inode bitmap and of every allocated
 * record: one uncached read per inode IN USE, once per 30-minute cycle.
 */
#include <linux/bitmap.h>
#include <linux/buffer_head.h>
#include <linux/dcache.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/workqueue.h>
#include "kmod.h"

static bool cetrafs_scrub_enabled = true;
module_param_named(scrub, cetrafs_scrub_enabled, bool, 0644);
MODULE_PARM_DESC(scrub, "automatic background reclaim of leaked data blocks (default on)");

/*
 * Bounded at the write, so the value the module holds (and reads back
 * from sysfs) is the one it uses (audit L3). Unbounded, a gap near 2^32
 * made `gap * 10` wrap in the confirmation loop -- a gap of 429496730
 * waited 4 passes, not 4 s -- and an enormous gap parked the cycle for
 * days. The gap's floor is 1 s: the suites drive it to 1-2 s for speed.
 */
#define CETRAFS_SCRUB_INTERVAL_MAX_SECS 86400U /* a day */
#define CETRAFS_SCRUB_GAP_MAX_SECS 3600U       /* an hour */
/* The gap is a safety window -- it must outlast any allocation's commit
 * window -- so it has a floor root cannot go below: the default. A 1 s
 * gap was accepted from sysfs (audit 2026-11-14 L3, class 39). */
#define CETRAFS_SCRUB_GAP_MIN_SECS 15U

/* TEST ONLY: the gap's floor. The suites drive the gap to 1-2 s for
 * speed and lower this first; as a test parameter, setting it says so. */
static unsigned int cetrafs_scrub_gap_floor_secs = CETRAFS_SCRUB_GAP_MIN_SECS;
cetrafs_test_param(scrub_gap_floor_secs, cetrafs_scrub_gap_floor_secs, uint, 0644);
MODULE_PARM_DESC(scrub_gap_floor_secs, "TEST ONLY: the lowest scrub_gap_secs accepted (default 15)");

static int cetrafs_scrub_secs_set(const char *val, const struct kernel_param *kp, unsigned int min, unsigned int max)
{
    unsigned int v;
    int ret = kstrtouint(val, 0, &v);

    if (ret)
        return ret;
    *(unsigned int *) kp->arg = clamp_t(unsigned int, v, min, max);
    return 0;
}

static int cetrafs_scrub_interval_set(const char *val, const struct kernel_param *kp)
{
    return cetrafs_scrub_secs_set(val, kp, 1U, CETRAFS_SCRUB_INTERVAL_MAX_SECS);
}

static int cetrafs_scrub_gap_set(const char *val, const struct kernel_param *kp)
{
    unsigned int floor = clamp_t(unsigned int, READ_ONCE(cetrafs_scrub_gap_floor_secs), 1U, CETRAFS_SCRUB_GAP_MIN_SECS);

    return cetrafs_scrub_secs_set(val, kp, floor, CETRAFS_SCRUB_GAP_MAX_SECS);
}

static const struct kernel_param_ops cetrafs_scrub_interval_ops = {
    .set = cetrafs_scrub_interval_set,
    .get = param_get_uint,
};
static const struct kernel_param_ops cetrafs_scrub_gap_ops = {
    .set = cetrafs_scrub_gap_set,
    .get = param_get_uint,
};

static unsigned int cetrafs_scrub_interval_secs = 1800; /* 30 min */
module_param_cb(scrub_interval_secs, &cetrafs_scrub_interval_ops, &cetrafs_scrub_interval_secs, 0644);
MODULE_PARM_DESC(scrub_interval_secs, "seconds between scrub cycles (1..86400)");

static unsigned int cetrafs_scrub_gap_secs = 15;
module_param_cb(scrub_gap_secs, &cetrafs_scrub_gap_ops, &cetrafs_scrub_gap_secs, 0644);
MODULE_PARM_DESC(scrub_gap_secs,
                 "two-pass confirmation gap in seconds, 15..3600 (must exceed any allocation's commit window)");

/* TEST ONLY: decide from the on-disk record alone, ignoring the in-core
 * shadow -- the negative control for the overlay in scrub_build_refset().
 * With it the scrub frees blocks out from under a file that is being
 * written, which is what it used to do unconditionally. */
static bool cetrafs_scrub_ignore_shadow;
cetrafs_test_param(scrub_ignore_shadow, cetrafs_scrub_ignore_shadow, bool, 0644);
MODULE_PARM_DESC(scrub_ignore_shadow,
                 "TEST ONLY: build the scrub reference set from the on-disk records only (frees live blocks)");

/* TEST ONLY: act on the verdict even though the Block Group has been
 * allocated from since the evidence was gathered -- the negative control
 * for cetrafs_bg_chunk.bg_alloc_seq. With it, a concurrent workload gets
 * blocks freed out from under files that were just given them.
 * tests/kernel/churn_oracle.sh is what measures the difference. */
/* TEST ONLY: hold the scrub between its verdict (pass 2) and its frees,
 * so a test can release a run inside that window. */
static unsigned int cetrafs_scrub_verdict_stall_ms;
cetrafs_test_param(scrub_verdict_stall_ms, cetrafs_scrub_verdict_stall_ms, uint, 0644);
MODULE_PARM_DESC(scrub_verdict_stall_ms, "TEST ONLY: ms to hold between the scrub's verdict and its frees");

static bool cetrafs_scrub_ignore_alloc_seq;
cetrafs_test_param(scrub_ignore_alloc_seq, cetrafs_scrub_ignore_alloc_seq, bool, 0644);
/* TEST ONLY: at the next free's ownership check, the Block Group reads as
 * released to the pool, as a mid-cycle release leaves it
 * (tests/kernel/scrub_bg_moved.sh). */
static bool cetrafs_scrub_bg_moved_once;
cetrafs_test_param(scrub_bg_moved_once, cetrafs_scrub_bg_moved_once, bool, 0644);
MODULE_PARM_DESC(scrub_bg_moved_once, "TEST ONLY: the scrub's next free finds its Block Group released");
/* TEST ONLY, one-shot: the group leaves AFTER the scrub's checks, just
 * before its free -- 1: its in-core owner reads FREE; 2: the free is
 * routed as one to a foreign owner (pf_force_foreign for that one free:
 * a loop device has no CAW, so a real foreign owner cannot be staged on
 * one node); 3: drained, as a release does first, under the mutex.
 * tests/kernel/scrub_bg_moved.sh, audit BC-17. */
static unsigned int cetrafs_scrub_bg_moved_late;
cetrafs_test_param(scrub_bg_moved_late, cetrafs_scrub_bg_moved_late, uint, 0644);
MODULE_PARM_DESC(scrub_bg_moved_late, "TEST ONLY: the scrub's next free finds its Block Group gone after the checks (1 owner FREE, 2 foreign, 3 drained)");
MODULE_PARM_DESC(scrub_ignore_alloc_seq,
                 "TEST ONLY: free on a verdict older than the last allocation in the Block Group");

/*
 * Memory and I/O shape of a cycle (audit 2026-11-14 M3, L1, L2). The
 * reference set is built a batch of Block Groups at a time under this
 * budget, and kept past pass 1 only for groups that have a candidate;
 * candidates are allocated only where one exists. Holding both sets for
 * every owned group for the whole cycle cost 64 KiB per owned GiB.
 */
static unsigned int cetrafs_scrub_ref_budget_kb = 65536;
cetrafs_test_param(scrub_ref_budget_kb, cetrafs_scrub_ref_budget_kb, uint, 0644);
MODULE_PARM_DESC(scrub_ref_budget_kb, "TEST ONLY: the scrub's reference-set budget per batch, KiB");
/*
 * Candidates are kept as runs of consecutive bits, not as a bitmap of the
 * whole group: a group with a few leaks holds a few runs (audit M3). The
 * runs of a cycle share one budget, and a group whose runs would exceed
 * it keeps none this cycle -- it reclaims less, and the next cycle asks
 * again -- so the budget can only make the scrub free less, never more.
 * TEST ONLY: scrub_cand_bitmap restores the bitmap a group with a
 * candidate held for the whole cycle (the control of
 * tests/kernel/scrub_cand_runs.sh).
 */
static unsigned int cetrafs_scrub_cand_budget_kb = 4096;
cetrafs_test_param(scrub_cand_budget_kb, cetrafs_scrub_cand_budget_kb, uint, 0644);
MODULE_PARM_DESC(scrub_cand_budget_kb, "TEST ONLY: the scrub's candidate-run budget per cycle, KiB");
static bool cetrafs_scrub_cand_bitmap;
cetrafs_test_param(scrub_cand_bitmap, cetrafs_scrub_cand_bitmap, bool, 0644);
MODULE_PARM_DESC(scrub_cand_bitmap, "TEST ONLY: the scrub holds a candidate bitmap per group with a candidate, all cycle");
static atomic64_t cetrafs_scrub_cand_deferred = ATOMIC64_INIT(0);
u64 cetrafs_scrub_cand_deferred_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_cand_deferred);
}
/* TEST ONLY: the old shape -- every set for every group for the whole
 * cycle, one free per block, every inode block read ahead -- the control
 * of tests/kernel/scrub_shape.sh. */
static bool cetrafs_scrub_old_shape;
cetrafs_test_param(scrub_old_shape, cetrafs_scrub_old_shape, bool, 0644);
MODULE_PARM_DESC(scrub_old_shape, "TEST ONLY: the scrub holds every set, frees per block and reads every inode ahead");
static atomic64_t cetrafs_scrub_set_bytes_peak = ATOMIC64_INIT(0);
static atomic64_t cetrafs_scrub_free_calls = ATOMIC64_INIT(0);
static atomic64_t cetrafs_scrub_inode_ra = ATOMIC64_INIT(0);
static atomic64_t cetrafs_scrub_unknown_records = ATOMIC64_INIT(0);
u64 cetrafs_scrub_unknown_record_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_unknown_records);
}
u64 cetrafs_scrub_set_bytes_peak_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_set_bytes_peak);
}
u64 cetrafs_scrub_free_call_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_free_calls);
}
u64 cetrafs_scrub_inode_ra_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_inode_ra);
}

static atomic64_t cetrafs_scrub_reclaimed = ATOMIC64_INIT(0);
u64 cetrafs_scrub_reclaimed_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_reclaimed);
}

/* Orphan INODES reclaimed (allocated, nlink=0, in use by nobody) -- the
 * companion to the block counter above, and what a test polls to know the
 * orphan phase has acted. */
static atomic64_t cetrafs_scrub_orphans = ATOMIC64_INIT(0);
u64 cetrafs_scrub_orphans_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_orphans);
}

/*
 * Completed cycles: incremented only once a cycle has run BOTH passes
 * and the free loop, i.e. once it has had every opportunity to reclaim.
 * Operationally it answers "is the scrub actually running?"; for the
 * test suite it is what keeps "nothing was reclaimed" from being
 * vacuously true because no cycle ever ran.
 */
static atomic64_t cetrafs_scrub_cycles = ATOMIC64_INIT(0);
u64 cetrafs_scrub_cycle_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_cycles);
}

/* Cycles that stopped before freeing anything because some node had
 * frees in flight (cetrafs_frees_quiet()). A cycle that reclaims
 * nothing for this reason is not one that looked and found nothing --
 * the suites need to tell the two apart. */
static atomic64_t cetrafs_scrub_inflight_skips = ATOMIC64_INIT(0);
u64 cetrafs_scrub_inflight_skip_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_inflight_skips);
}

/* Cycles skipped because a stale node's dirty journal could not be read
 * (or, under scrub_dead_journal_whole, was dirty at all). */
static atomic64_t cetrafs_scrub_dead_journal_skips = ATOMIC64_INIT(0);
u64 cetrafs_scrub_dead_journal_skip_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_dead_journal_skips);
}

/* Verdicts that ran keeping the blocks a stale node's dirty journal
 * names (cetrafs_journal_dead_refs()). */
static atomic64_t cetrafs_scrub_dead_journal_kept = ATOMIC64_INIT(0);
u64 cetrafs_scrub_dead_journal_kept_count(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_dead_journal_kept);
}

/* When the last cycle STARTED (unix seconds, 0 = never since module
 * load) and how long it took. "Did the scrub run during that window,
 * and could a cycle have straddled it?" kept coming up in post-mortems
 * with only dmesg to answer it -- procfs 'info' now answers directly.
 * A cycle in progress shows its start time with the previous duration. */
static atomic64_t cetrafs_scrub_last_start; /* unix secs */
static atomic64_t cetrafs_scrub_last_ms;    /* duration of the last completed cycle */
u64 cetrafs_scrub_last_start_unix(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_last_start);
}
u64 cetrafs_scrub_last_duration_ms(void)
{
    return (u64) atomic64_read(&cetrafs_scrub_last_ms);
}

struct cetrafs_scrub {
    struct super_block *sb;
    struct delayed_work work;
    bool draining;
};

/* One Block Group being scrubbed this cycle. */
struct scrub_bg {
    u32 bg_id;
    u32 zg_id;           /* the ZG that owned it when this cycle collected it */
    u64 data_start;      /* first data-block LBA */
    u64 data_count;      /* data blocks in the BG */
    u64 bmap_lba;        /* data-bitmap first LBA */
    u64 bmap_blocks;     /* data-bitmap length in blocks */
    unsigned long *ref;  /* referenced set, data_count bits (indexed block - data_start) */
    unsigned long *cand; /* TEST ONLY (scrub_cand_bitmap): pass-1 candidate bitmap */
    struct scrub_run *runs; /* pass-1 candidates: runs of consecutive block indices */
    u32 nruns, capruns;
    u32 rcur;            /* pass 2's cursor into runs[]: it asks ascending bits */
    u64 alloc_seq;       /* allocations in this BG when the evidence was taken */
    u64 resv_seq;        /* reservation releases when the evidence was taken */
};

/* Consecutive candidates [start, start+len), block indices into the BG. */
struct scrub_run {
    u32 start;
    u32 len;
};

struct scrub_ctx {
    struct scrub_bg *bgs;
    u32 nbgs;
    /* bgs[] data ranges strictly ascending and disjoint, checked when
     * the list is built: scrub_mark_ref() may then binary-search it. */
    bool ordered;
    u64 cand_bytes;      /* bytes of candidate runs held this cycle, against the budget */
};

/* The for_each_extent callback: mark every block of [phys, phys+len) that
 * falls in a scrubbed BG as referenced. Per-extent (range), not per-block. */
static void scrub_mark_ref(void *ctxp, u64 phys, u32 len)
{
    struct scrub_ctx *ctx = ctxp;
    u32 i = 0;

    if (!len)
        return;
    /*
     * Once per extent of every allocated inode: a scan of every owned
     * Block Group here made the walk O(extents x BGs) (audit L19). On an
     * ordered list, start at the first BG whose data does not end at or
     * before phys. The order is CHECKED, not assumed (cetrafs_scrub
     * collects by bg_id, and a hostile descriptor table need not ascend):
     * a reference this misses is a block the scrub frees while a file
     * names it, so an unordered list keeps the full scan.
     */
    if (ctx->ordered) {
        u32 lo = 0, hi = ctx->nbgs;

        while (lo < hi) {
            u32 mid = lo + (hi - lo) / 2;
            struct scrub_bg *b = &ctx->bgs[mid];

            if (b->data_start + b->data_count <= phys)
                lo = mid + 1;
            else
                hi = mid;
        }
        i = lo;
    }
    for (; i < ctx->nbgs; i++) {
        struct scrub_bg *b = &ctx->bgs[i];
        u64 lo = max(phys, b->data_start);
        u64 hi = min(phys + len, b->data_start + b->data_count);

        if (ctx->ordered && b->data_start >= phys + len)
            break;
        if (lo < hi)
            bitmap_set(b->ref, (unsigned int) (lo - b->data_start), (unsigned int) (hi - lo));
    }
}

/* Clear every ref set, then walk all ALLOCATED inodes marking referenced
 * blocks. Returns -EIO if any allocated inode's record or extent tree can't
 * be read -- its references are then UNKNOWN and the whole cycle must free
 * nothing. */
static int scrub_build_refset(struct cetrafs_scrub *s, struct scrub_ctx *ctx, bool fresh)
{
    struct super_block *sb = s->sb;
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    DECLARE_BITMAP(dropped, 128); /* this window's records dropped ahead */
    struct inode *vfs_inode;
    u64 ninodes, ino;
    u32 i;

    if (!raw_sb)
        return -EINVAL;
    /* The bound from the device's layout: an inode in a segment a peer's
     * grow added and this node has not caught up with would protect
     * nothing, and its blocks would read as leaked (rule 6). */
    if (cetrafs_sb_layout_refresh(sb) < 0)
        return -EAGAIN;
    ninodes = cetrafs_sb_inodes(sb);

    /* The inode bitmap first, and as a whole: it is a handful of blocks
     * and every "is this inode allocated?" below reads it. A stale copy
     * of it is what makes a peer's live inode invisible. */
    if (fresh)
        cetrafs_ibmap_invalidate(sb);

    for (i = 0; i < ctx->nbgs; i++)
        bitmap_zero(ctx->bgs[i].ref, (unsigned int) ctx->bgs[i].data_count);

    bitmap_zero(dropped, 128);
    for (ino = 1; ino <= ninodes; ino++) {
        cetrafs_inode_t raw;
        bool allocated = false;
        int ret;

        if (READ_ONCE(s->draining))
            return -EINTR;
        if ((ino & 127) == 1) {
            u64 k;

            /* Ahead only for allocated numbers, and on the fresh pass
             * dropped BEFORE the read ahead rather than after it: every
             * block was read ahead and then thrown away again by the
             * invalidate below (audit 2026-11-14 L2). A number the read
             * below finds allocated and this did not is dropped there. */
            bitmap_zero(dropped, 128);
            for (k = ino; k < ino + 128 && k <= ninodes; k++) {
                bool a = true;

                if (!READ_ONCE(cetrafs_scrub_old_shape)) {
                    if (cetrafs_inode_is_allocated(sb, k, &a) != 0 || !a)
                        continue;
                    if (fresh) {
                        cetrafs_invalidate_raw_inode(sb, k);
                        __set_bit((unsigned int) (k - ino), dropped);
                    }
                }
                sb_breadahead(sb, cetrafs_inode_lba(sb, k));
                atomic64_inc(&cetrafs_scrub_inode_ra);
            }
            cond_resched();
        }

        if (cetrafs_inode_is_allocated(sb, ino, &allocated) != 0)
            return -EIO; /* can't read the inode bitmap -> unknown -> bail */
        if (!allocated)
            continue; /* freed slot: its stale record must NOT protect blocks */

        /* An allocated inode's record decides which blocks are spoken
         * for. On the deciding pass that answer must come from the
         * device, not from whatever this node last happened to cache of
         * a table every node writes. */
        if (fresh && !test_bit((unsigned int) ((ino - 1) & 127), dropped))
            cetrafs_invalidate_raw_inode(sb, ino);

        /*
         * ...AND from the in-core shadow when there is one.
         *
         * The on-disk record is not the whole truth about which blocks
         * an inode owns. The hot write path stages extent state in
         * cetrafs_inode_info.fd_shadow and publishes it only at a
         * durability boundary, so a file being written RIGHT NOW owns
         * blocks that are bitmap-allocated and named by nothing on the
         * device. cetrafs_inode_fd_overlay() says "every file-path read
         * of extent state goes through this" -- this read did not, and
         * it is the one whose verdict FREES.
         *
         * The exemption list in this file's header covers the
         * speculative run behind the written block, and point 2 argues
         * that a real allocation commits its extent "within one
         * get_block() -- milliseconds", which the two-pass gap then
         * dwarfs. That was true before the shadow existed. With it, a
         * single large write holds tens of thousands of blocks
         * unpublished for as long as the writer goes without syncing,
         * and the scrub freed them under a live file: the allocator
         * handed them out again (cross-file overlap) and the owner's
         * eventual free hit blocks that were already free.
         *
         * ilookup() never reads from the device -- it answers only for
         * an inode already in core, which is exactly the set that can
         * have an unpublished shadow -- so the common case costs one
         * hash lookup per allocated inode per cycle.
         */
        vfs_inode = ilookup(sb, ino);
        if (vfs_inode) {
            ret = cetrafs_read_raw_inode_overlaid(sb, vfs_inode, &raw);
            if (cetrafs_scrub_ignore_shadow) /* TEST ONLY: the negative control */
                ret = cetrafs_read_raw_inode(sb, ino, &raw);
        } else {
            ret = cetrafs_read_raw_inode_walk(sb, ino, &raw);
            if (ret == -ENODATA && cetrafs_walk_zero_owns_nothing_test())
                continue; /* TEST ONLY: owns nothing, as F-7 had it */
            if (ret == -ENODATA) {
                /* Never written -- or a live record read back as zeros:
                 * the same bytes. What it owns is unknown, so nothing is
                 * freed this cycle (review F-11). Not damage either: a
                 * peer's create can be on its way. */
                atomic64_inc(&cetrafs_scrub_unknown_records);
                pr_info_ratelimited("scrub: ino=%llu is allocated but its record was never written -- no leaked "
                                    "block is freed while it is (fsck -r frees the number)\n",
                                    (unsigned long long) ino);
                return -EAGAIN;
            }
        }
        if (!ret)
            ret = cetrafs_raw_inode_for_each_owned_block(sb, &raw, scrub_mark_ref, ctx, fresh);
        /* One exit for the ilookup() reference: the record-read failure
         * below returns too, and dropping it only on the success path
         * pinned an inode for the life of the mount. */
        if (vfs_inode)
            iput(vfs_inode);
        if (ret)
            return -EIO; /* unreadable record or tree -> references unknown -> bail */
    }

    /*
     * A block with a free already QUEUED against it is not a leak, even
     * though it looks exactly like one: its owner dropped the extent
     * (hence unreferenced) and handed the free to us (hence still set).
     * Freeing it ourselves clears the bit early, our allocator reuses
     * the block, and the next drain then applies that queued free to a
     * block that is live again.
     *
     * Marking them referenced is the fix. An entry queued BEFORE pass 1
     * is seen by this walk. An entry queued DURING the cycle required its
     * peer to drop the extent first -- so the block was still referenced
     * at pass 1 and never became a candidate at all.
     *
     * One entry escapes both: an append whose CAW outcome was UNDECIDED
     * stops its node's mount (caw.c), and the command can still land on
     * the device afterwards, at an instant unrelated to when its extent
     * was dropped -- after pass 2 freed the block as a leak and the
     * block was handed out again. That copy is stopped by its stamp,
     * not here: scrub_free_confirmed() raises the group's free_gen
     * before its first free, and the drain drops an entry stamped
     * before that (cetrafs_apply_pending_free();
     * tests/kernel/pf_late_copy_after_reclaim.sh).
     *
     * One queue read per owned ZG per pass. Targets are collected in
     * Block Group order, and ownership is round-robin (BG b of ZG
     * b % Z), so consecutive targets alternate Zone Groups: "same as the
     * last" re-read a queue for every owned BG (audit 2026-11-06 L26).
     * A set of the ZGs already read, then -- the reads all happen here,
     * back to back, before any free, so one per queue loses nothing.
     */
    {
        DECLARE_BITMAP(seen, CETRAFS_MAX_ZONE_GROUPS);

        bitmap_zero(seen, CETRAFS_MAX_ZONE_GROUPS);
        for (i = 0; i < ctx->nbgs; i++) {
            u32 z = ctx->bgs[i].zg_id;

            if (z < CETRAFS_MAX_ZONE_GROUPS) {
                if (test_bit(z, seen))
                    continue;
                __set_bit(z, seen);
            }
            if (cetrafs_zg_pending_free_for_each(sb, z, scrub_mark_ref, ctx) != 0)
                return -EIO; /* queue unreadable -> cannot vouch -> free nothing */
        }
    }

    return 0;
}

/* Read a BG's whole data bitmap, block after block, into a freshly
 * allocated buffer -- each block checked (cetrafs_bmap_bread()), its
 * trailers kept in place: scrub_bit_set() maps a bit as on the device.
 * Caller frees. */
static u8 *scrub_read_bitmap(struct super_block *sb, const struct scrub_bg *b)
{
    u8 *buf = kvmalloc(b->bmap_blocks * CETRAFS_BLOCK_SIZE, GFP_NOFS);
    u64 i;

    if (!buf)
        return NULL;
    for (i = 0; i < b->bmap_blocks; i++) {
        int err;
        struct buffer_head *bh = cetrafs_bmap_bread(sb, b->bmap_lba + i, 0, CETRAFS_BMAP_BUF_BITS, &err);

        if (!bh) {
            kvfree(buf);
            return NULL;
        }
        memcpy(buf + i * CETRAFS_BLOCK_SIZE, bh->b_data, CETRAFS_BLOCK_SIZE);
        brelse(bh);
    }
    return buf;
}

static inline bool scrub_bit_set(const u8 *buf, u64 bit)
{
    return test_bit_le(cetrafs_bmap_blk(bit) * CETRAFS_BMAP_BUF_BITS + cetrafs_bmap_off(bit), buf);
}

/* Drop a group's candidates for this cycle, and their share of the budget. */
static void scrub_cand_release(struct scrub_ctx *ctx, struct scrub_bg *b)
{
    ctx->cand_bytes -= (u64) b->capruns * sizeof(struct scrub_run);
    kvfree(b->runs);
    b->runs = NULL;
    b->nruns = b->capruns = 0;
    kvfree(b->cand);
    b->cand = NULL;
}

/* Append candidate 'bit' to the group's runs. 1 added, 0 over the budget
 * (the group keeps none this cycle), -ENOMEM. */
static int scrub_cand_add(struct scrub_ctx *ctx, struct scrub_bg *b, u64 bit)
{
    u64 budget = (u64) max(READ_ONCE(cetrafs_scrub_cand_budget_kb), 1U) * 1024;
    struct scrub_run *r;

    if (b->nruns && (u64) b->runs[b->nruns - 1].start + b->runs[b->nruns - 1].len == bit) {
        b->runs[b->nruns - 1].len++;
        return 1;
    }
    if (b->nruns == b->capruns) {
        u32 ncap = b->capruns ? b->capruns * 2 : 16;
        u64 grow = (u64) (ncap - b->capruns) * sizeof(*r);

        if (ctx->cand_bytes + grow > budget)
            return 0;
        r = kvmalloc_array(ncap, sizeof(*r), GFP_NOFS);
        if (!r)
            return -ENOMEM;
        if (b->nruns)
            memcpy(r, b->runs, (size_t) b->nruns * sizeof(*r));
        kvfree(b->runs);
        b->runs = r;
        b->capruns = ncap;
        ctx->cand_bytes += grow;
    }
    b->runs[b->nruns].start = (u32) bit;
    b->runs[b->nruns].len = 1;
    b->nruns++;
    return 1;
}

/* Pass 1: a candidate is an allocated bitmap bit referenced by nothing. */
static int scrub_mark_candidates(struct super_block *sb, struct scrub_ctx *ctx, struct scrub_bg *b)
{
    u8 *bmap = scrub_read_bitmap(sb, b);
    bool over = false;
    u64 bit;
    int ret = 0;

    if (!bmap)
        return -EIO;
    if (b->cand)
        bitmap_zero(b->cand, (unsigned int) b->data_count);
    for (bit = 0; bit < b->data_count && !over; bit++) {
        if (scrub_bit_set(bmap, bit) && !test_bit((unsigned int) bit, b->ref)) {
            if (!b->cand && READ_ONCE(cetrafs_scrub_cand_bitmap)) { /* TEST ONLY: the old shape */
                b->cand = kvcalloc(BITS_TO_LONGS(b->data_count), sizeof(long), GFP_NOFS);
                if (!b->cand) {
                    ret = -ENOMEM;
                    break;
                }
            }
            if (b->cand)
                __set_bit((unsigned int) bit, b->cand);
            ret = scrub_cand_add(ctx, b, bit);
            if (ret == 0) {
                /* Over the cycle's budget: this group keeps none. */
                scrub_cand_release(ctx, b);
                atomic64_inc(&cetrafs_scrub_cand_deferred);
                over = true;
                ret = 0;
            } else if (ret < 0) {
                break;
            }
        }
        if (!(bit & 0xffff))
            cond_resched(); /* data_count is disk geometry: up to 2^32 */
    }
    kvfree(bmap);
    return ret < 0 ? ret : 0;
}

/* Pass 2's test of one block index. It asks ascending indices, so the
 * cursor only moves forward. */
static bool scrub_is_cand(struct scrub_bg *b, u64 bit)
{
    if (b->cand)
        return test_bit((unsigned int) bit, b->cand);
    while (b->rcur < b->nruns && (u64) b->runs[b->rcur].start + b->runs[b->rcur].len <= bit)
        b->rcur++;
    return b->rcur < b->nruns && b->runs[b->rcur].start <= bit;
}

/* Pass 2: a candidate still allocated AND still unreferenced after the gap is
 * confirmed leaked. Free it (owned ZG -> direct free). */
static int scrub_free_confirmed(struct cetrafs_scrub *s, struct scrub_bg *b, u64 *out_freed)
{
    struct super_block *sb = s->sb;
    u8 *bmap = scrub_read_bitmap(sb, b);
    bool gen_raised = false;
    u64 bit;
    int ret;

    if (!bmap)
        return -EIO;
    b->rcur = 0;
    for (bit = 0; bit < b->data_count; bit++) {
        if (READ_ONCE(s->draining))
            break;
        if (!(bit & 0xffff))
            cond_resched(); /* data_count is disk geometry: up to 2^32 */
        /*
         * Anything allocated in this Block Group since the evidence was
         * taken invalidates the whole verdict for it: the allocator
         * hands out blocks that were free when the reference set was
         * built, and "referenced by nothing" was true of them THEN.
         * Freeing one now takes it from the file that has just been
         * given it -- which is how two inodes came to map one block.
         *
         * Abandoning the Block Group (rather than skipping one bit) is
         * the conservative answer: the reference set is equally stale
         * for every candidate in it. A busy volume therefore reclaims
         * little or nothing, which is correct for a background pass --
         * a leak costs space, and freeing a live block costs data.
         */
        if (!cetrafs_scrub_ignore_alloc_seq && cetrafs_sb_bg_alloc_seq(sb, b->bg_id) != b->alloc_seq) {
            pr_debug("scrub: BG %u saw an allocation since the deciding pass -- abandoning it this cycle\n", b->bg_id);
            break;
        }
        if (!scrub_is_cand(b, bit))
            continue;

        /*
         * Still ours? Ownership can move mid-cycle -- we release a ZG
         * that went empty, or a peer steals one from us -- and this
         * cycle's candidates were chosen while we still owned it.
         *
         * Being FENCED is already handled: cetrafs_free_data_extent()
         * refuses with -EIO. Losing the ZG while NOT fenced is the
         * dangerous one, and it is dangerous in a non-obvious way: the
         * free does not fail, it silently becomes a foreign free QUEUED
         * to the new owner, who then applies it to a block it has since
         * allocated for itself. Cached lookup, the same one the
         * per-block allocation path trusts.
         */
        if (!cetrafs_sb_zg_owned_cached(sb, b->zg_id)) {
            pr_info("scrub: ZG %u stopped being ours mid-cycle -- abandoning BG %u\n", b->zg_id, b->bg_id);
            break;
        }
        /* ...and the Block Group still the Zone Group's: groups are
         * released and claimed one at a time, so the ZG can stay ours
         * while this BG went back to the pool and on to a peer -- the
         * same silent foreign free (audit 2026-11-06 L18). */
        if (READ_ONCE(cetrafs_scrub_bg_moved_once) && xchg(&cetrafs_scrub_bg_moved_once, false))
            cetrafs_sb_set_bg_owner(sb, b->bg_id, CETRAFS_BG_OWNER_FREE); /* TEST ONLY: see the parameter */
        if (cetrafs_sb_bg_owner(sb, b->bg_id) != b->zg_id) {
            pr_info("scrub: BG %u left ZG %u mid-cycle -- abandoning it\n", b->bg_id, b->zg_id);
            break;
        }
        if (scrub_bit_set(bmap, bit) && !test_bit((unsigned int) bit, b->ref)) {
            bool reserved;

            /*
             * Last gate: a LIVE speculative allocation run (lock.c) is
             * bitmap-set and referenced by no extent -- indistinguishable
             * from a leak by every test above, and held for as long as
             * the file stays open rather than for the one get_block()
             * this scrub's two-pass argument assumes. Freeing one hands
             * its blocks to the next allocation while their owner still
             * means to use them.
             *
             * Checked HERE, at the instant of the free, rather than
             * folded into the reference set: the set is built before the
             * gap and before this loop, and a run installed in between
             * would not be in it.
             */
            u32 run = 1, got_run;
            u64 got = 0;

            reserved = cetrafs_resv_covers(sb, b->data_start + bit);
            if (reserved)
                continue;
            /* The confirmed blocks that follow go in the same call: one
             * free per block re-resolved the group and took the mutex
             * every time (audit 2026-11-14 L1). The free re-checks the
             * reservations and the allocation count per block, under the
             * mutex, as it did for one. */
            if (!READ_ONCE(cetrafs_scrub_old_shape))
                while (run < 4096 && bit + run < b->data_count && scrub_is_cand(b, bit + run) &&
                       scrub_bit_set(bmap, bit + run) && !test_bit((unsigned int) (bit + run), b->ref))
                    run++;
            got_run = run;

            /*
             * Before the first free in this group, raise its free_gen
             * (cetrafs_bg_bump_free_gen()). A peer's pending-free entry
             * for a block judged leaked here may still reach the queue
             * after this reclaim -- an append whose outcome its node
             * never learned, landing after the node stopped -- and by
             * then the block can belong to a new file. Stamped before
             * this, such an entry is dropped by the drain instead of
             * freeing that file's block. Not raised, nothing is freed.
             */
            if (!gen_raised) {
                ret = cetrafs_bg_bump_free_gen(sb, b->bg_id, b->zg_id);
                if (ret) {
                    pr_warn_ratelimited("scrub: BG %u: could not raise its free generation (%d) -- freeing "
                                        "nothing there this cycle\n",
                                        b->bg_id, ret);
                    break;
                }
                gen_raised = true;
            }
            {
                unsigned int late = READ_ONCE(cetrafs_scrub_bg_moved_late) ? xchg(&cetrafs_scrub_bg_moved_late, 0) : 0;

                if (late == 1)
                    cetrafs_sb_set_bg_owner(sb, b->bg_id, CETRAFS_BG_OWNER_FREE); /* TEST ONLY */
                if (late == 2)
                    WRITE_ONCE(cetrafs_pf_force_foreign, true); /* TEST ONLY */
                if (late == 3 && !cetrafs_sb_drain_bg(sb, b->bg_id))
                    late = 0; /* TEST ONLY: a trim holds a run; not staged */
                ret = cetrafs_free_data_extent_unless_reserved(sb, b->data_start + bit, got_run, b->resv_seq,
                                                               cetrafs_scrub_ignore_alloc_seq ? NULL : &b->alloc_seq,
                                                               &got);
                if (late == 2)
                    WRITE_ONCE(cetrafs_pf_force_foreign, false);
                if (late == 3)
                    cetrafs_sb_undrain_bg(sb, b->bg_id);
            }
            atomic64_inc(&cetrafs_scrub_free_calls);
            if (ret == -EAGAIN) {
                /* A run was released since the verdict: it is somebody's
                 * data now, and the evidence predates it. Same answer as
                 * a moved allocation count -- abandon, retry next cycle. */
                pr_debug("scrub: a reservation was released since the verdict -- abandoning BG %u\n", b->bg_id);
                break;
            }
            if (ret == 0) {
                ctrace("SCRUBFREE lba=%llu +%u bg=%u\n", (unsigned long long) (b->data_start + bit), got_run,
                       b->bg_id);
                *out_freed += got;
                atomic64_add((s64) got, &cetrafs_scrub_reclaimed);
            }
            bit += got_run - 1; /* the loop's ++ steps past the run */
        }
        if ((bit & 4095) == 0)
            cond_resched();
    }
    kvfree(bmap);
    return 0;
}

/* Build the scrub target list: every Block Group this node owns. */
static int scrub_collect_targets(struct super_block *sb, struct scrub_ctx *ctx)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 n = 0, cap = 0;
    struct scrub_bg *bgs = NULL;

    if (!raw_sb)
        return -EINVAL;

    /*
     * Every Block Group this node owns, flat. The nested walk this
     * replaces -- for each owned Zone Group, for each Block Group in
     * its contiguous range -- reached the same set only while
     * membership was a range (docs/internal/BG-OWNERSHIP-DESIGN.md).
     * The owning Zone Group is still recorded per entry, because the
     * mid-cycle "is this still ours" check below is asked of the Zone
     * Group.
     */
    {
        u32 bgid;

        for (bgid = cetrafs_sb_next_owned_bg(sb, 0); bgid != U32_MAX;
             bgid = cetrafs_sb_next_owned_bg(sb, bgid + 1)) {
            struct scrub_bg *b;

            if (n == cap) {
                u32 ncap = cap ? cap * 2 : 16;
                struct scrub_bg *nb = krealloc(bgs, (size_t) ncap * sizeof(*nb), GFP_NOFS);

                if (!nb)
                    goto oom;
                bgs = nb;
                cap = ncap;
            }
            b = &bgs[n];
            memset(b, 0, sizeof(*b));
            b->bg_id = bgid;
            b->zg_id = cetrafs_sb_bg_owner(sb, bgid);
            if (cetrafs_bg_data_layout(sb, b->bg_id, &b->data_start, &b->data_count, &b->bmap_lba, &b->bmap_blocks) !=
                0)
                continue; /* skip an unreadable BG rather than fail the cycle */
            if (READ_ONCE(cetrafs_scrub_old_shape)) { /* test-only: both sets, every group, all cycle */
                b->ref = kvcalloc(BITS_TO_LONGS(b->data_count), sizeof(long), GFP_NOFS);
                b->cand = kvcalloc(BITS_TO_LONGS(b->data_count), sizeof(long), GFP_NOFS);
                if (!b->ref || !b->cand) {
                    kvfree(b->ref);
                    kvfree(b->cand);
                    goto oom;
                }
            }
            n++;
        }
    }
    ctx->bgs = bgs;
    ctx->nbgs = n;
    ctx->ordered = true;
    for (u32 k = 1; k < n; k++)
        if (bgs[k].data_start < bgs[k - 1].data_start + bgs[k - 1].data_count)
            ctx->ordered = false;
    return 0;
oom:
    while (n--) {
        kvfree(bgs[n].ref);
        kvfree(bgs[n].cand);
    }
    kfree(bgs);
    return -ENOMEM;
}

static void scrub_free_targets(struct scrub_ctx *ctx)
{
    u32 i;

    for (i = 0; i < ctx->nbgs; i++) {
        kvfree(ctx->bgs[i].ref);
        kvfree(ctx->bgs[i].cand);
        kvfree(ctx->bgs[i].runs);
    }
    kfree(ctx->bgs);
    ctx->bgs = NULL;
    ctx->nbgs = 0;
    ctx->cand_bytes = 0;
}

/*
 * Reclaim ORPHAN INODES: allocated in the global bitmap, nlink=0 on a
 * forced-fresh read, and in use by nobody. NOT the normal result of a
 * cross-node delete: unlink refuses a file any live peer has open
 * (-ETXTBSY, cetrafs_lock_foreign_user_exists()). It arises when that
 * check and a peer's open raced, when the opener that blocked the free
 * died with it open, or when a read or CAS error left the free undone --
 * cetrafs_evict_inode() then refuses to free an inode a peer still holds
 * (its read-presence bit), and the number and its blocks stay allocated
 * with nothing left to free them. fsck reports exactly this as
 * "allocated (nlink=0) ... deleted but not yet reclaimed".
 *
 * Only the inode NUMBER is freed here (one bitmap CAS). The orphan's data
 * blocks are then no longer protected by an allocated record, so the
 * ordinary block-reclaim passes of this very cycle see them as
 * unreferenced and free them with all their existing safety (owned-ZG
 * scoping, the two-pass gap, the reservation registry) -- no second block
 * -freeing path to audit.
 *
 * Why freeing on these checks is safe (rule 6 -- every input's staleness
 * direction, and what revives the state):
 *  - nlink=0 is TERMINAL for an allocated number. link() refuses a target
 *    with no names left; iget's fill path refuses to instantiate a
 *    deleted record, so no new open can reach it; create() needs the
 *    bitmap bit FREE, which it is not. Nothing transitions it back.
 *  - read_open_nodes/lock/ns-lock are read FRESH; a peer with the file
 *    open keeps its presence bit until close, so any node still reading
 *    the dead file skips it this cycle and its own close converges it.
 *  - a LOCAL in-core object (ilookup) means our own unlinked-but-open
 *    file, a live eviction, or a file a peer deleted that this node
 *    still caches; its evict owns the free -- skip, after making sure it
 *    knows the file is dead (scrub_adopt_local_death(), BL-87).
 *  - a concurrent evict or peer scrub freeing the same number: the
 *    bitmap free is a CAS, one winner; the blocks go through the block
 *    -reclaim machinery that already arbitrates those frees.
 */
/*
 * A record with links whose namespace lock a STOPPED node still holds:
 * that node died inside an operation on it, after the entry write and
 * before the release that publishes its count. For a directory or a
 * named file the next operation on it breaks the lock and recounts
 * (cetrafs_nslock_try(), cetrafs_ns_reconcile()). An unlinked file is
 * neither: its name is gone, nlink still says 1, and nothing can reach
 * it to operate on -- it held its blocks until an offline fsck -r. So
 * the scrub takes the lock the way an operation would, which fences the
 * dead node, replays its journal and recounts; a file no name reaches
 * comes out of that with nlink 0, and its own eviction frees it.
 * A record flagged CETRAFS_INODE_COUNT_UNVERIFIED -- a recount owed and
 * failed -- is taken the same way: the acquire recounts it.
 * One acquire per such record per cycle: they exist only after a crash.
 */
static void scrub_reconcile_stopped_op(struct cetrafs_scrub *s, u64 ino, const cetrafs_inode_t *raw, u32 my_node_id)
{
    struct super_block *sb = s->sb;
    u32 from = cetrafs_le32(raw->ns_lock_owner);
    struct inode *inode;
    bool stale = false;

    if (from == my_node_id)
        return; /* one of ours: its operation releases it */
    if (from == CETRAFS_NODE_ID_NONE) {
        /* Unlocked: only a record whose recount was owed and failed
         * (CETRAFS_INODE_COUNT_UNVERIFIED) is this pass's -- an unlinked
         * file flagged so is reached by no name, so no operation would
         * ever recount it. */
        if (!(cetrafs_le32(raw->flags) & CETRAFS_INODE_COUNT_UNVERIFIED))
            return;
    } else if (cetrafs_node_is_stale(sb, from, &stale) || !stale) {
        return; /* a live holder's operation is still running */
    }
    inode = cetrafs_iget(sb, ino);
    if (IS_ERR(inode))
        return;
    if (cetrafs_inode_get_generation(inode) == cetrafs_le64(raw->generation) && !cetrafs_nslock_acquire(inode))
        cetrafs_nslock_release(inode);
    iput(inode); /* recounted to 0: this is its eviction, and the free */
}

/* TEST ONLY: leave a local in-core object of a dead record as it is, as
 * before audit 2026-11-15 BL-87 (tests/kernel/scrub_adopts_peer_unlink.sh). */
static bool cetrafs_scrub_local_no_adopt;
cetrafs_test_param(scrub_local_no_adopt, cetrafs_scrub_local_no_adopt, bool, 0644);
MODULE_PARM_DESC(scrub_local_no_adopt, "TEST ONLY: skip a dead record this node holds in core without adopting its death");

/*
 * A dead record this node still holds in core. The skip below assumed
 * that object's eviction owns the free, and it does only when the
 * object knows the file died: evict frees on the in-core link count. A
 * PEER's unlink never moves that count here -- a file this node had
 * open when a peer deleted it (the peer's evict leaves it to the
 * opener) keeps i_nlink 1 after the close, its eviction frees nothing,
 * and the skip spared it for as long as the object stayed cached
 * (audit 2026-11-15 BL-87). So adopt the death the way writeback adopts
 * nlink (cetrafs_write_vfs_inode()): under inode_lock, which every
 * local namespace operation on it holds, from a read made after taking
 * it, of the same generation and type. Then drop the dentries nobody
 * uses: with no opener left the caller's iput is the last, and the
 * eviction frees it with every check it makes (foreign openers, the
 * claim). Busy (the lock taken): the next cycle.
 */
static void scrub_adopt_local_death(struct super_block *sb, struct inode *local, u64 generation)
{
    cetrafs_inode_t *now;
    int ret;

    if (READ_ONCE(cetrafs_scrub_local_no_adopt) || cetrafs_inode_get_generation(local) != generation)
        return;
    /*
     * Not under nofilelock. The eviction this hands the free to judges
     * other users by read presence and the file lock; there an open
     * writer publishes presence, but a path-based truncate or setxattr
     * on a third node holds no open file and leaves no mark (audit
     * F-42), and would have its blocks freed. Left cached, as before:
     * not lost, only late -- once the object leaves the cache (memory
     * pressure, the unmount) it is an orphan this walk reclaims. The
     * same F-42 writer meets this node's own unlink the same way.
     */
    if (!cetrafs_sb_file_lock_enabled(sb))
        return;
    /* Adopted in an earlier cycle: only the prune is left. A dentry in
     * use then (an open file, a working directory) kept it cached, and
     * it is tried again on every cycle until the last one goes. */
    if (!local->i_nlink)
        goto prune;
    now = kmalloc(sizeof(*now), GFP_NOFS); /* 652 bytes: not on the scrub's stack beside the walk's own */
    if (!now)
        return;
    if (!inode_trylock(local)) {
        kfree(now);
        return; /* busy: the next cycle */
    }
    cetrafs_invalidate_raw_inode(sb, local->i_ino);
    ret = cetrafs_read_raw_inode(sb, local->i_ino, now);
    /* Adopted only on a read that says so; an error adopts nothing. Not
     * a free: a peer that opened the file since the caller's verdict is
     * judged by the eviction, which re-reads presence and the lock
     * fresh before its own free and frees nothing past one (-ETXTBSY,
     * tests/kernel/evict_foreign_open.sh). */
    if (!ret && local->i_nlink && cetrafs_le64(now->generation) == generation &&
        cetrafs_le32(now->nlink) == 0 && ((local->i_mode ^ cetrafs_le32(now->mode)) & S_IFMT) == 0) {
        set_nlink(local, 0);
        pr_info("scrub: ino=%llu: deleted by another node while cached here -- its eviction frees it\n",
                (unsigned long long) local->i_ino);
    }
    inode_unlock(local);
    kfree(now);
    if (local->i_nlink)
        return;
prune:
    d_prune_aliases(local);
}

static void scrub_reclaim_orphan_inodes(struct cetrafs_scrub *s)
{
    struct super_block *sb = s->sb;
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 ninodes, ino, freed = 0;
    u32 my_node_id;

    if (!raw_sb || cetrafs_sb_get_node_id(sb, &my_node_id))
        return;
    ninodes = cetrafs_sb_inodes(sb);

    for (ino = 2; ino <= ninodes; ino++) { /* 1 is the root, never an orphan */
        cetrafs_inode_t raw;
        struct inode *local;
        bool allocated = false;

        if (READ_ONCE(s->draining))
            return;
        if ((ino & 255) == 0)
            cond_resched();

        if (cetrafs_inode_is_allocated(sb, ino, &allocated) != 0 || !allocated)
            continue;
        if (cetrafs_sb_birth_active(sb, ino))
            continue; /* mid-birth on this node: its record is not yet
                       * written, so the dead previous record would pass
                       * every check below -- and freeing it hands the
                       * number to a second owner (2026-10-29). */

        /* The verdict read: fresh, never this node's cache. */
        cetrafs_invalidate_raw_inode(sb, ino);
        if (cetrafs_read_raw_inode_walk(sb, ino, &raw) != 0)
            continue; /* unreadable, or never written (F-11): cannot vouch -- not this number's free */

        if (cetrafs_le32(raw.nlink) != 0) {
            scrub_reconcile_stopped_op(s, ino, &raw, my_node_id);
            continue; /* live file */
        }
        if (cetrafs_le64(raw.read_open_nodes) != 0 || cetrafs_le32(raw.lock_mode) != CETRAFS_LOCK_NONE) {
            /* A live opener's close converges; a DEAD one's never does
             * -- its bit or lock stayed and the file leaked for good.
             * Clear the dead ones, then judge the record afresh. */
            if (cetrafs_lock_clear_dead_claims(sb, ino, my_node_id))
                continue;
            cetrafs_invalidate_raw_inode(sb, ino);
            if (cetrafs_read_raw_inode(sb, ino, &raw) != 0 || cetrafs_le32(raw.nlink) != 0 ||
                cetrafs_le64(raw.read_open_nodes) != 0 || cetrafs_le32(raw.lock_mode) != CETRAFS_LOCK_NONE)
                continue;
        }
        if (cetrafs_le32(raw.ns_lock_owner) != CETRAFS_NODE_ID_NONE) {
            u32 from = cetrafs_le32(raw.ns_lock_owner);
            bool stale = false;

            /*
             * A namespace operation or a free is mid-flight on this
             * record -- or was, on a node that stopped. An evict holds
             * its claim from before its first block free until after the
             * number's (cetrafs_free_inode_begin()), so a claimant that
             * died there left the number and the blocks not yet freed
             * allocated until it came back, and for good if it never
             * did. Ours are this node's own retry queue's. A stale one's
             * is taken over -- after the fence and the replay, as a
             * namespace lock's is (cetrafs_nslock_try()) -- and the free
             * finished: the number only, the blocks to the block scrub.
             */
            if (from == my_node_id || cetrafs_node_is_stale(sb, from, &stale) || !stale)
                continue;
            if (cetrafs_node_fence_peer(sb, from, "an unfinished inode free") ||
                cetrafs_journal_replay_node(sb, from, /*wait_for_claim=*/true))
                continue;
            cetrafs_invalidate_raw_inode(sb, ino);
            if (cetrafs_read_raw_inode(sb, ino, &raw) != 0 || cetrafs_le32(raw.nlink) != 0 ||
                cetrafs_le32(raw.ns_lock_owner) != from || cetrafs_le64(raw.read_open_nodes) != 0 ||
                cetrafs_le32(raw.lock_mode) != CETRAFS_LOCK_NONE)
                continue;
            if (cetrafs_free_inode_steal(sb, ino, cetrafs_le64(raw.generation), cetrafs_le64(raw.dirent_seq), from) ==
                0) {
                pr_info("scrub: ino=%llu: finished a free stale node %u had claimed\n", (unsigned long long) ino,
                        from);
                freed++;
                atomic64_inc(&cetrafs_scrub_orphans);
            }
            continue;
        }

        local = ilookup(sb, ino);
        if (local) {
            /* Our own object: its eviction owns the free -- once it
             * knows the file is dead (scrub_adopt_local_death()). */
            scrub_adopt_local_death(sb, local, cetrafs_le64(raw.generation));
            iput(local);
            continue;
        }

        if (cetrafs_free_inode_if_dead(sb, ino, cetrafs_le64(raw.generation), cetrafs_le64(raw.dirent_seq)) == 0) {
            freed++;
            atomic64_inc(&cetrafs_scrub_orphans);
        }
    }

    if (freed)
        pr_info("scrub: reclaimed %llu orphan inode(s) (deleted while a peer held them open)\n",
                (unsigned long long) freed);
}

static u64 scrub_set_bytes(const struct scrub_bg *b)
{
    return (u64) BITS_TO_LONGS(b->data_count) * sizeof(long);
}

/* The groups [from, end) whose reference sets fit the budget; at least one. */
static u32 scrub_batch_end(const struct scrub_ctx *ctx, u32 from)
{
    u64 budget = (u64) max(READ_ONCE(cetrafs_scrub_ref_budget_kb), 1U) * 1024, used = 0;
    u32 i = from;

    do {
        used += scrub_set_bytes(&ctx->bgs[i]);
        i++;
    } while (i < ctx->nbgs && used + scrub_set_bytes(&ctx->bgs[i]) <= budget);
    return i;
}

static int scrub_refs_alloc(struct scrub_ctx *ctx, u32 from, u32 to)
{
    u32 i;

    for (i = from; i < to; i++) {
        if (ctx->bgs[i].ref)
            continue;
        ctx->bgs[i].ref = kvcalloc(BITS_TO_LONGS(ctx->bgs[i].data_count), sizeof(long), GFP_NOFS);
        if (!ctx->bgs[i].ref)
            return -ENOMEM;
    }
    return 0;
}

static void scrub_refs_drop(struct scrub_ctx *ctx, u32 from, u32 to)
{
    u32 i;

    for (i = from; i < to; i++) {
        kvfree(ctx->bgs[i].ref);
        ctx->bgs[i].ref = NULL;
    }
}

/* [from, to) as a context of its own: an ordered list stays ordered. */
static struct scrub_ctx scrub_sub(const struct scrub_ctx *ctx, u32 from, u32 to)
{
    struct scrub_ctx sub = {.bgs = ctx->bgs + from, .nbgs = to - from, .ordered = ctx->ordered};

    return sub;
}

/* The sets held right now, for the peak the suite reads. */
static void scrub_note_peak(const struct scrub_ctx *ctx)
{
    u64 held = 0, peak;
    u32 i;

    for (i = 0; i < ctx->nbgs; i++)
        held += (ctx->bgs[i].ref ? scrub_set_bytes(&ctx->bgs[i]) : 0) +
                (ctx->bgs[i].cand ? scrub_set_bytes(&ctx->bgs[i]) : 0) +
                (u64) ctx->bgs[i].capruns * sizeof(struct scrub_run);
    peak = (u64) atomic64_read(&cetrafs_scrub_set_bytes_peak);
    while (held > peak && atomic64_cmpxchg(&cetrafs_scrub_set_bytes_peak, (s64) peak, (s64) held) != (s64) peak)
        peak = (u64) atomic64_read(&cetrafs_scrub_set_bytes_peak);
}

static void cetrafs_scrub_cycle(struct cetrafs_scrub *s)
{
    struct super_block *sb = s->sb;
    struct scrub_ctx ctx = {0};
    struct cetrafs_frees_snap frees;
    struct cetrafs_journal_refs jrefs = {0};
    u64 freed = 0;
    u32 i, gap, from, to;
    bool old;
    int ret;
    ktime_t t0 = ktime_get();

    atomic64_set(&cetrafs_scrub_last_start, (s64) ktime_get_real_seconds());
    atomic64_set(&cetrafs_scrub_set_bytes_peak, 0); /* this cycle's, from here */

    if (cetrafs_sb_is_fenced(sb))
        return; /* a fenced mount writes nothing */

    /* Adopt one ZG owned by a dead peer FIRST, so it is included in this
     * cycle's targets -- nobody else scrubs an abandoned ZG, and that is
     * where dropped-free leaks pile up. One per cycle (see the helper). */
    {
        bool adopted = false;

        if (cetrafs_zg_scrub_adopt_one_stale(sb, &adopted) == 0 && adopted)
            pr_info("scrub: adopted a stale peer's zone group to reclaim its leaks\n");
    }

    /* Orphan inodes first, so this same cycle's block passes see a freed
     * orphan's blocks as unreferenced and reclaim them too. */
    scrub_reclaim_orphan_inodes(s);

    ret = scrub_collect_targets(sb, &ctx);
    if (ret || ctx.nbgs == 0)
        goto done;
    old = READ_ONCE(cetrafs_scrub_old_shape);

    /* Pass 1: reference set from all allocated inodes, then candidates.
     * Cached -- it only proposes, and proposing too much costs nothing.
     * A batch of groups at a time under the budget, each batch's set
     * dropped once its candidates are taken (M3). */
    for (from = 0; from < ctx.nbgs; from = to) {
        struct scrub_ctx sub;

        to = old ? ctx.nbgs : scrub_batch_end(&ctx, from);
        if (scrub_refs_alloc(&ctx, from, to) != 0)
            goto done;
        sub = scrub_sub(&ctx, from, to);
        if (scrub_build_refset(s, &sub, /*fresh=*/false) != 0)
            goto done; /* any read failure -> free nothing this cycle */
        for (i = from; i < to; i++)
            if (scrub_mark_candidates(sb, &ctx, &ctx.bgs[i]) != 0)
                goto done;
        scrub_note_peak(&ctx);
        if (!old)
            scrub_refs_drop(&ctx, from, to);
    }
    /* Only a group with a candidate has anything to confirm. */
    if (!old) {
        u32 j = 0;

        for (i = 0; i < ctx.nbgs; i++)
            if (ctx.bgs[i].cand || ctx.bgs[i].nruns)
                ctx.bgs[j++] = ctx.bgs[i];
        ctx.nbgs = j;
    }

    /* The gap: let any in-flight allocation commit its extent. Bail early
     * if unmounting. */
    gap = cetrafs_scrub_gap_secs ? cetrafs_scrub_gap_secs : 1;
    for (i = 0; i < gap * 10 && !READ_ONCE(s->draining); i++)
        msleep(100);
    if (READ_ONCE(s->draining))
        goto done;

    if (ctx.nbgs == 0) {
        /* Nothing proposed: no verdict to take, so no fresh walk. The
         * in-flight check still answers for the cycle, as it did. */
        if (cetrafs_frees_quiet(sb, &frees, false)) {
            atomic64_inc(&cetrafs_scrub_inflight_skips);
            goto done;
        }
        atomic64_inc(&cetrafs_scrub_cycles);
        goto done;
    }

    /* Pass 2, a batch at a time, each batch its own verdict: snapshot,
     * in-flight check, fresh evidence, in-flight check again, free. */
    for (from = 0; from < ctx.nbgs && !READ_ONCE(s->draining); from = to) {
        struct scrub_ctx sub;

        to = old ? ctx.nbgs : scrub_batch_end(&ctx, from);

        /* Snapshot each BG's allocation count BEFORE the evidence is
         * gathered, not after: the refset build below reads one uncached
         * record per allocated inode and is itself slow, so an allocation
         * during it would otherwise go unnoticed by a verdict that claims to
         * describe the state afterwards. */
        for (i = from; i < to; i++) {
            ctx.bgs[i].alloc_seq = cetrafs_sb_bg_alloc_seq(sb, ctx.bgs[i].bg_id);
            ctx.bgs[i].resv_seq = cetrafs_sb_resv_seq(sb);
        }

        /* Frees in flight anywhere (cetrafs_frees_quiet()): a block an
         * operation has published away and not yet freed -- here, or as a
         * queue append still to come from a peer -- reads leaked to both
         * passes, and freeing it means it is freed twice. Asked again just
         * before the frees. */
        if (cetrafs_frees_quiet(sb, &frees, false)) {
            pr_debug("scrub: frees in flight on some node -- skipping this cycle\n");
            atomic64_inc(&cetrafs_scrub_inflight_skips);
            goto done;
        }
        /* A stale node's journal still dirty: its entries can name
         * blocks no tree references yet. Collected now, BEFORE the trees
         * are read, and counted as referenced after
         * (cetrafs_journal_dead_refs()); a cycle that cannot read them
         * frees nothing. */
        {
            bool any = false;

            cetrafs_journal_refs_free(&jrefs);
            if (cetrafs_journal_dead_refs(sb, &jrefs, &any)) {
                pr_debug("scrub: a stale node's journal could not be read -- skipping this cycle\n");
                atomic64_inc(&cetrafs_scrub_dead_journal_skips);
                goto done;
            }
            if (any)
                atomic64_inc(&cetrafs_scrub_dead_journal_kept);
        }

        /* Rebuild the reference set FRESH, confirm, free. This is the
         * verdict that frees blocks, so it may not rest on a cached view
         * of a table other nodes write. */
        if (scrub_refs_alloc(&ctx, from, to) != 0)
            goto done;
        sub = scrub_sub(&ctx, from, to);
        if (scrub_build_refset(s, &sub, /*fresh=*/true) != 0)
            goto done;
        for (i = 0; i < jrefs.n; i++) {
            u64 p = jrefs.v[i].phys, left = jrefs.v[i].len;

            while (left) {
                u32 step = (u32) min_t(u64, left, U32_MAX);

                scrub_mark_ref(&sub, p, step);
                p += step;
                left -= step;
            }
        }
        scrub_note_peak(&ctx);
        if (cetrafs_scrub_verdict_stall_ms) { /* TEST ONLY */
            unsigned int ms;

            pr_info("scrub: holding the verdict %u ms (test)\n", cetrafs_scrub_verdict_stall_ms);
            for (ms = 0; ms < cetrafs_scrub_verdict_stall_ms && !READ_ONCE(s->draining); ms += 100)
                msleep(100);
            pr_info("scrub: verdict released (test)\n");
        }
        if (cetrafs_frees_quiet(sb, &frees, true)) {
            pr_debug("scrub: frees began or were in flight during the verdict -- skipping this cycle\n");
            atomic64_inc(&cetrafs_scrub_inflight_skips);
            goto done;
        }
        for (i = from; i < to && !READ_ONCE(s->draining); i++)
            if (scrub_free_confirmed(s, &ctx.bgs[i], &freed) != 0)
                goto done;
        if (!old)
            scrub_refs_drop(&ctx, from, to);
    }
    if (READ_ONCE(s->draining))
        goto done;

    atomic64_inc(&cetrafs_scrub_cycles);

    if (freed)
        pr_info("scrub: reclaimed %llu leaked data block(s) across %u owned BG(s)\n", (unsigned long long) freed,
                ctx.nbgs);
done:
    cetrafs_journal_refs_free(&jrefs);
    scrub_free_targets(&ctx);
    atomic64_set(&cetrafs_scrub_last_ms, ktime_ms_delta(ktime_get(), t0));
}

static void cetrafs_scrub_work(struct work_struct *w)
{
    struct cetrafs_scrub *s = container_of(to_delayed_work(w), struct cetrafs_scrub, work);

    if (!READ_ONCE(s->draining) && cetrafs_scrub_enabled)
        cetrafs_scrub_cycle(s);

    if (!READ_ONCE(s->draining)) {
        unsigned int secs = cetrafs_scrub_interval_secs ? cetrafs_scrub_interval_secs : 1800;

        queue_delayed_work(system_long_wq, &s->work, msecs_to_jiffies((unsigned long) secs * 1000));
    }
}

int cetrafs_scrub_start(struct super_block *sb, struct cetrafs_scrub **out_s)
{
    struct cetrafs_scrub *s = kzalloc(sizeof(*s), GFP_KERNEL);
    unsigned int secs;

    if (!s)
        return -ENOMEM;
    s->sb = sb;
    WRITE_ONCE(s->draining, false);
    INIT_DELAYED_WORK(&s->work, cetrafs_scrub_work);
    /* First cycle one interval out, not at mount: a fresh mount has nothing
     * to reclaim and this keeps the mount path cheap. */
    secs = cetrafs_scrub_interval_secs ? cetrafs_scrub_interval_secs : 1800;
    queue_delayed_work(system_long_wq, &s->work, msecs_to_jiffies((unsigned long) secs * 1000));
    *out_s = s;
    return 0;
}

void cetrafs_scrub_stop(struct cetrafs_scrub *s)
{
    if (!s)
        return;
    WRITE_ONCE(s->draining, true); /* read by a running cycle, which stops at its next check */
    cancel_delayed_work_sync(&s->work);
    kfree(s);
}
