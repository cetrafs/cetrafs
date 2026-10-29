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
 *     only in-flight allocations in a ZG this node owns are its own.
 *     Collectively the volume is still covered.
 *
 *  2. TWO PASSES WITH A GAP. A block mid-allocation (bit durable,
 *     extent not yet) looks leaked. A real allocation commits its
 *     extent within one get_block() -- milliseconds -- so it is
 *     referenced by pass 2. The gap dwarfs any get_block().
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

static unsigned int cetrafs_scrub_interval_secs = 1800; /* 30 min */
module_param_named(scrub_interval_secs, cetrafs_scrub_interval_secs, uint, 0644);
MODULE_PARM_DESC(scrub_interval_secs, "seconds between scrub cycles");

static unsigned int cetrafs_scrub_gap_secs = 15;
module_param_named(scrub_gap_secs, cetrafs_scrub_gap_secs, uint, 0644);
MODULE_PARM_DESC(scrub_gap_secs, "two-pass confirmation gap in seconds (must exceed any allocation's commit window)");

/* TEST ONLY: decide from the on-disk record alone, ignoring the in-core
 * shadow -- the negative control for the overlay in scrub_build_refset().
 * With it the scrub frees blocks out from under a file that is being
 * written, which is what it used to do unconditionally. */
static bool cetrafs_scrub_ignore_shadow;
module_param_named(scrub_ignore_shadow, cetrafs_scrub_ignore_shadow, bool, 0644);
MODULE_PARM_DESC(scrub_ignore_shadow,
                 "TEST ONLY: build the scrub reference set from the on-disk records only (frees live blocks)");

/* TEST ONLY: act on the verdict even though the Block Group has been
 * allocated from since the evidence was gathered -- the negative control
 * for cetrafs_sb_info.bg_alloc_seq. With it, a concurrent workload gets
 * blocks freed out from under files that were just given them.
 * tests/kernel/churn_oracle.sh is what measures the difference. */
static bool cetrafs_scrub_ignore_alloc_seq;
module_param_named(scrub_ignore_alloc_seq, cetrafs_scrub_ignore_alloc_seq, bool, 0644);
MODULE_PARM_DESC(scrub_ignore_alloc_seq,
                 "TEST ONLY: free on a verdict older than the last allocation in the Block Group");

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
    unsigned long *cand; /* pass-1 candidate set, data_count bits */
    u64 alloc_seq;       /* allocations in this BG when the evidence was taken */
};


struct scrub_ctx {
    struct scrub_bg *bgs;
    u32 nbgs;
};

/* The for_each_extent callback: mark every block of [phys, phys+len) that
 * falls in a scrubbed BG as referenced. Per-extent (range), not per-block. */
static void scrub_mark_ref(void *ctxp, u64 phys, u32 len)
{
    struct scrub_ctx *ctx = ctxp;
    u32 i;

    if (!len)
        return;
    for (i = 0; i < ctx->nbgs; i++) {
        struct scrub_bg *b = &ctx->bgs[i];
        u64 lo = max(phys, b->data_start);
        u64 hi = min(phys + len, b->data_start + b->data_count);

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
    struct inode *vfs_inode;
    u64 ninodes, ino;
    u32 i;

    if (!raw_sb)
        return -EINVAL;
    ninodes = le32_to_cpu(raw_sb->inodes_count);

    /* The inode bitmap first, and as a whole: it is a handful of blocks
     * and every "is this inode allocated?" below reads it. A stale copy
     * of it is what makes a peer's live inode invisible. */
    if (fresh) {
        u64 b, bmap_start = le64_to_cpu(raw_sb->inode_bmap_start);
        u64 bmap_blocks = le64_to_cpu(raw_sb->inode_bmap_blocks);

        for (b = 0; b < bmap_blocks; b++)
            cetrafs_invalidate_block(sb, bmap_start + b);
    }

    for (i = 0; i < ctx->nbgs; i++)
        bitmap_zero(ctx->bgs[i].ref, (unsigned int) ctx->bgs[i].data_count);

    for (ino = 1; ino <= ninodes; ino++) {
        cetrafs_inode_t raw;
        bool allocated = false;
        int ret;

        if (s->draining)
            return -EINTR;
        if ((ino & 127) == 1) {
            u64 k;

            for (k = ino; k < ino + 128 && k <= ninodes; k++)
                sb_breadahead(sb, cetrafs_inode_lba(sb, k));
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
        if (fresh)
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
            ret = cetrafs_read_raw_inode(sb, ino, &raw);
        }
        if (!ret)
            ret = cetrafs_raw_inode_for_each_owned_block(sb, &raw, scrub_mark_ref, ctx);
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
     * Marking them referenced is the fix, and it is airtight rather than
     * merely conservative. An entry queued BEFORE pass 1 is seen by this
     * walk. An entry queued DURING the cycle required its peer to drop
     * the extent first -- so the block was still referenced at pass 1
     * and never became a candidate at all. The two cases are disjoint.
     *
     * One queue read per owned ZG per pass; targets are collected
     * ZG-major, so tracking the last one is enough to visit each once.
     */
    {
        u32 last_zg = U32_MAX;

        for (i = 0; i < ctx->nbgs; i++) {
            if (ctx->bgs[i].zg_id == last_zg)
                continue;
            last_zg = ctx->bgs[i].zg_id;
            if (cetrafs_zg_pending_free_for_each(sb, last_zg, scrub_mark_ref, ctx) != 0)
                return -EIO; /* queue unreadable -> cannot vouch -> free nothing */
        }
    }

    return 0;
}

/* Read a BG's whole data bitmap into a freshly allocated byte buffer (dense,
 * LSB-first, the on-disk convention). Caller frees. */
static u8 *scrub_read_bitmap(struct super_block *sb, const struct scrub_bg *b)
{
    u8 *buf = kvmalloc(b->bmap_blocks * CETRAFS_BLOCK_SIZE, GFP_NOFS);
    u64 i;

    if (!buf)
        return NULL;
    for (i = 0; i < b->bmap_blocks; i++) {
        struct buffer_head *bh = sb_bread(sb, b->bmap_lba + i);

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
    return (buf[bit >> 3] >> (bit & 7)) & 1;
}

/* Pass 1: a candidate is an allocated bitmap bit referenced by nothing. */
static int scrub_mark_candidates(struct super_block *sb, struct scrub_bg *b)
{
    u8 *bmap = scrub_read_bitmap(sb, b);
    u64 bit;

    if (!bmap)
        return -EIO;
    bitmap_zero(b->cand, (unsigned int) b->data_count);
    for (bit = 0; bit < b->data_count; bit++)
        if (scrub_bit_set(bmap, bit) && !test_bit((unsigned int) bit, b->ref))
            __set_bit((unsigned int) bit, b->cand);
    kvfree(bmap);
    return 0;
}

/* Pass 2: a candidate still allocated AND still unreferenced after the gap is
 * confirmed leaked. Free it (owned ZG -> direct free). */
static int scrub_free_confirmed(struct cetrafs_scrub *s, struct scrub_bg *b, u64 *out_freed)
{
    struct super_block *sb = s->sb;
    u8 *bmap = scrub_read_bitmap(sb, b);
    u64 bit;

    if (!bmap)
        return -EIO;
    for (bit = 0; bit < b->data_count; bit++) {
        if (s->draining)
            break;
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
        if (!test_bit((unsigned int) bit, b->cand))
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
            reserved = cetrafs_resv_covers(sb, b->data_start + bit);
            if (reserved)
                continue;

            if (cetrafs_free_data_extent_unless_reserved(sb, b->data_start + bit, 1) == 0) {
                ctrace("SCRUBFREE lba=%llu bg=%u\n", (unsigned long long) (b->data_start + bit), b->bg_id);
                (*out_freed)++;
                atomic64_inc(&cetrafs_scrub_reclaimed);
            }
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
        const unsigned long *owned = NULL;
        u32 nbg = 0, bgid;

        cetrafs_sb_owned_bgs(sb, &owned, &nbg);
        if (!owned)
            nbg = 0;
        for (bgid = 0; owned && bgid < nbg; bgid++) {
            struct scrub_bg *b;

            if (!test_bit(bgid, owned))
                continue;

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
            b->ref = kvcalloc(BITS_TO_LONGS(b->data_count), sizeof(long), GFP_NOFS);
            b->cand = kvcalloc(BITS_TO_LONGS(b->data_count), sizeof(long), GFP_NOFS);
            if (!b->ref || !b->cand) {
                kvfree(b->ref);
                kvfree(b->cand);
                goto oom;
            }
            n++;
        }
    }
    ctx->bgs = bgs;
    ctx->nbgs = n;
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
    }
    kfree(ctx->bgs);
    ctx->bgs = NULL;
    ctx->nbgs = 0;
}

/*
 * Reclaim ORPHAN INODES: allocated in the global bitmap, nlink=0 on a
 * forced-fresh read, and in use by nobody. This is the designed residue of
 * a cross-node delete -- cetrafs_evict_inode() refuses to free an inode a
 * peer still holds open (its read-presence bit), and that peer's own
 * eviction cannot know the file died under it (its cached i_nlink never
 * learns of a deletion it did not perform) -- so the number and its blocks
 * stay allocated with nothing left to free them. fsck reports exactly this
 * as "allocated (nlink=0) ... deleted but not yet reclaimed".
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
 *    file or a live eviction; its evict owns the free -- skip.
 *  - a concurrent evict or peer scrub freeing the same number: the
 *    bitmap free is a CAS, one winner; the blocks go through the block
 *    -reclaim machinery that already arbitrates those frees.
 */
static void scrub_reclaim_orphan_inodes(struct cetrafs_scrub *s)
{
    struct super_block *sb = s->sb;
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 ninodes, ino, freed = 0;

    if (!raw_sb)
        return;
    ninodes = le32_to_cpu(raw_sb->inodes_count);

    for (ino = 2; ino <= ninodes; ino++) { /* 1 is the root, never an orphan */
        cetrafs_inode_t raw;
        struct inode *local;
        bool allocated = false;

        if (s->draining)
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
        if (cetrafs_read_raw_inode(sb, ino, &raw) != 0)
            continue; /* unreadable: cannot vouch -- leave it for fsck */

        if (cetrafs_le32(raw.nlink) != 0)
            continue; /* live file */
        if (cetrafs_le64(raw.read_open_nodes) != 0)
            continue; /* a peer still reads the dead file -- its close converges */
        if (cetrafs_le32(raw.lock_mode) != CETRAFS_LOCK_NONE)
            continue; /* writer lock still present (holder or stale) -- not ours to judge */
        if (cetrafs_le32(raw.ns_lock_owner) != CETRAFS_NODE_ID_NONE)
            continue; /* a namespace operation is mid-flight on this record */

        local = ilookup(sb, ino);
        if (local) {
            iput(local);
            continue; /* our own object is live -- its eviction owns the free */
        }

        if (cetrafs_free_inode_if_dead(sb, ino, cetrafs_le64(raw.generation)) == 0) {
            freed++;
            atomic64_inc(&cetrafs_scrub_orphans);
        }
    }

    if (freed)
        pr_info("scrub: reclaimed %llu orphan inode(s) (deleted while a peer held them open)\n",
                (unsigned long long) freed);
}

static void cetrafs_scrub_cycle(struct cetrafs_scrub *s)
{
    struct super_block *sb = s->sb;
    struct scrub_ctx ctx = {0};
    u64 freed = 0;
    u32 i, gap;
    int ret;
    ktime_t t0 = ktime_get();

    atomic64_set(&cetrafs_scrub_last_start, (s64) ktime_get_real_seconds());

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

    /* Pass 1: reference set from all allocated inodes, then candidates.
     * Cached -- it only proposes, and proposing too much costs nothing. */
    if (scrub_build_refset(s, &ctx, /*fresh=*/false) != 0)
        goto done; /* any read failure -> free nothing this cycle */
    for (i = 0; i < ctx.nbgs; i++)
        if (scrub_mark_candidates(sb, &ctx.bgs[i]) != 0)
            goto done;


    /* The gap: let any in-flight allocation commit its extent. Bail early
     * if unmounting. */
    gap = cetrafs_scrub_gap_secs ? cetrafs_scrub_gap_secs : 1;
    for (i = 0; i < gap * 10 && !s->draining; i++)
        msleep(100);
    if (s->draining)
        goto done;

    /* Snapshot each BG's allocation count BEFORE the evidence is
     * gathered, not after: the refset build below reads one uncached
     * record per allocated inode and is itself slow, so an allocation
     * during it would otherwise go unnoticed by a verdict that claims to
     * describe the state afterwards. */
    for (i = 0; i < ctx.nbgs; i++)
        ctx.bgs[i].alloc_seq = cetrafs_sb_bg_alloc_seq(sb, ctx.bgs[i].bg_id);

    /* Pass 2: rebuild the reference set FRESH, confirm, free. This is
     * the verdict that frees blocks, so it may not rest on a cached view
     * of a table other nodes write. */
    if (scrub_build_refset(s, &ctx, /*fresh=*/true) != 0)
        goto done;
    for (i = 0; i < ctx.nbgs && !s->draining; i++)
        if (scrub_free_confirmed(s, &ctx.bgs[i], &freed) != 0)
            break;

    atomic64_inc(&cetrafs_scrub_cycles);

    if (freed)
        pr_info("scrub: reclaimed %llu leaked data block(s) across %u owned BG(s)\n", (unsigned long long) freed,
                ctx.nbgs);
done:
    scrub_free_targets(&ctx);
    atomic64_set(&cetrafs_scrub_last_ms, ktime_ms_delta(ktime_get(), t0));
}

static void cetrafs_scrub_work(struct work_struct *w)
{
    struct cetrafs_scrub *s = container_of(to_delayed_work(w), struct cetrafs_scrub, work);

    if (!s->draining && cetrafs_scrub_enabled)
        cetrafs_scrub_cycle(s);

    if (!s->draining) {
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
    s->draining = false;
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
    s->draining = true;
    cancel_delayed_work_sync(&s->work);
    kfree(s);
}
