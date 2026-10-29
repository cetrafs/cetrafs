// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * alloc.c -- allocation primitives over the on-disk bitmaps: the global
 * inode bitmap, and per-BG data bitmaps. Replaces the old bitmap.h, which
 * referenced an sb_info design that no longer exists in this tree.
 *
 * No locking yet: callers must serialize their own calls (e.g. with the
 * parent directory's inode lock) until proper per-BG locking exists. Fine
 * for today's single-threaded self-test; revisit before anything in
 * a later change calls these concurrently.
 *
 * The BG descriptor's cached cetrafs_block_group_t.free_data_blocks is kept
 * in sync here (see cetrafs_bg_adjust_free_blocks() below); the in-memory
 * free-inode count in cetrafs_sb_info is kept in sync via
 * cetrafs_sb_adjust_free_inodes() in fs.c. The owning ZG's own aggregate
 * (cetrafs_zone_group_t.free_data_blocks) is also kept in sync as of
 * via zonegroup.c's cetrafs_zg_adjust_free_blocks() --
 * cetrafs_bg_adjust_free_blocks() below rolls every BG-level delta up
 * into the owning ZG using the BG descriptor's own owner_zg field.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/buffer_head.h>
#include <linux/crc32c.h>
#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/moduleparam.h>

#include "kmod.h"

/* Times a Block Group chosen by its CACHED free count turned out to
 * have a full bitmap, and was recounted. Free counts ARE caches -- they
 * are reconciled from the bitmaps only when a ZG's ownership transfers
 * or at mount re-attach -- so this drift is permitted by the design,
 * but it has never been seen. Counted rather than assumed: if it stays
 * zero across real cluster time, the retry below is dead code and
 * should go; if it does not, this is the number that says so. */
static atomic64_t cetrafs_bg_recounts = ATOMIC64_INIT(0);

u64 cetrafs_bg_recount_count(void)
{
    return (u64) atomic64_read(&cetrafs_bg_recounts);
}


/* Test-only: send every data-block free down the FOREIGN path, so the
 * pending-free queue and its drop handling can be exercised on a single
 * node. A real foreign free needs a second node owning the ZG. */
bool cetrafs_pf_force_foreign;
module_param_named(pf_force_foreign, cetrafs_pf_force_foreign, bool, 0644);
MODULE_PARM_DESC(pf_force_foreign, "test-only: route every block free through the foreign pending-free queue");

/*
 * Scan a dense, byte-wise LSB-first bitmap (the same convention mkfs.c
 * writes) spanning 'nblocks' consecutive blocks starting at absolute LBA
 * 'bmap_lba', for the first clear bit among the first 'nbits' bits. On
 * success, sets that bit and writes the modified block back to disk.
 * Returns the bit index (>= 0), or a negative errno (-ENOSPC if none free,
 * -EIO on a read failure).
 */
/*
 * 'sync' matters: the global inode bitmap is shared cross-node (the
 * cluster mutex is the only thing closing that race, see
 * cetrafs_inode_bitmap_lock()'s own comment) -- the claim must be
 * physically durable on the real device *before* that mutex releases,
 * or the next claimant's own forced-fresh read could still see the old,
 * unclaimed bit. A per-BG data bitmap has no such requirement: only the
 * owning node ever touches it, so there is no peer whose read ordering
 * depends on this write's durability -- see cetrafs_alloc_data_block()'s
 * caller passing sync=false. Found via real two-node testing,
 * this was unconditionally sync_dirty_buffer()'d regardless
 * of caller, so a multi-block write paid for one *synchronous* real
 * device round trip per block just for bitmap bookkeeping that no other
 * node could ever race against -- directly reported as "still too
 * slow" even after fixing cetrafs_alloc_pick_bg()'s separate O(blocks x
 * zone_groups) bug.
 */
static long cetrafs_bitmap_alloc_bit(struct super_block *sb, u64 bmap_lba, u64 nblocks, u64 nbits, bool sync)
{
    u64 blk;

    for (blk = 0; blk < nblocks; blk++) {
        struct buffer_head *bh = sb_bread(sb, bmap_lba + blk);
        unsigned int byte;

        if (!bh)
            return -EIO;

        for (byte = 0; byte < CETRAFS_BLOCK_SIZE; byte++) {
            u8 *b = (u8 *) bh->b_data + byte;
            unsigned int bit;

            if (*b == 0xFF)
                continue; /* fully used byte */

            for (bit = 0; bit < 8; bit++) {
                u64 idx = blk * CETRAFS_BITS_PER_BLOCK + byte * 8 + bit;

                if (idx >= nbits)
                    goto out_full;

                if (!(*b & (1u << bit))) {
                    /* Buffer lock across the modification -- see
                     * cetrafs_bitmap_free_bit(). Note sync_dirty_buffer()
                     * takes the lock itself, so it must come after
                     * end_update(), never inside the region. */
                    cetrafs_bh_begin_update(bh);
                    *b |= (u8) (1u << bit);
                    cetrafs_bh_end_update(bh);
                    if (sync)
                        sync_dirty_buffer(bh);
                    brelse(bh);
                    return (long) idx;
                }
            }
        }

        brelse(bh);
    }

out_full:
    return -ENOSPC;
}

/*
 * Find the first FREE bit that starts a free run of at least 'run_min'
 * bits (clamped to the bitmap's tail), and allocate just that first bit.
 * Allocation-time defragmentation strategy:
 *: plain first-fit places a new extent's first block in the
 * first hole left by past churn -- usually a tiny one -- guaranteeing the
 * growing file fragments again immediately. Placing it at the head of a
 * run long enough to matter lets the existing cetrafs_alloc_data_block_
 * near() contiguity hint keep extending the same extent block after
 * block from there. Only this FIRST block of a new extent needs the run
 * search; the rest follow the hint.
 *
 * Returns the bit index, -ENOSPC if no run of that length exists (the
 * caller retries with a smaller target), -EIO on read failure. The scan
 * is the same O(bits) walk alloc_bit does; run lengths are counted
 * across block boundaries via 'run' carrying over.
 */
static int cetrafs_bitmap_try_alloc_exact(struct super_block *sb,
                                          u64 bmap_lba,
                                          u64 nblocks,
                                          u64 nbits,
                                          u64 bit,
                                          bool sync);
static int cetrafs_bitmap_test_bit(struct super_block *sb, u64 bmap_lba, u64 nblocks, u64 bit, bool *out_set);

static long cetrafs_bitmap_alloc_run_start(struct super_block *sb,
                                           u64 bmap_lba,
                                           u64 nblocks,
                                           u64 nbits,
                                           u64 run_min,
                                           bool sync)
{
    u64 blk, run = 0, run_start = 0;

    if (run_min <= 1)
        return cetrafs_bitmap_alloc_bit(sb, bmap_lba, nblocks, nbits, sync);

    for (blk = 0; blk < nblocks; blk++) {
        struct buffer_head *bh = sb_bread(sb, bmap_lba + blk);
        unsigned int byte;

        if (!bh)
            return -EIO;

        for (byte = 0; byte < CETRAFS_BLOCK_SIZE; byte++) {
            const u8 *b = (const u8 *) bh->b_data + byte;
            unsigned int bit;

            if (*b == 0xFF) {
                run = 0;
                continue;
            }
            if (*b == 0x00 && run && (blk * CETRAFS_BITS_PER_BLOCK + byte * 8 + 8) <= nbits) {
                /* whole byte free mid-run: fast-forward */
                run += 8;
                if (run >= run_min)
                    goto found;
                continue;
            }

            for (bit = 0; bit < 8; bit++) {
                u64 idx = blk * CETRAFS_BITS_PER_BLOCK + byte * 8 + bit;

                if (idx >= nbits) {
                    brelse(bh);
                    goto out_nospc;
                }

                if (*b & (1u << bit)) {
                    run = 0;
                } else {
                    if (run == 0)
                        run_start = idx;
                    run++;
                    if (run >= run_min)
                        goto found;
                }
            }
        }

        brelse(bh);
        continue;

    found:
        brelse(bh);
        /* Allocate the run's FIRST bit via the exact-claim helper (it
         * re-reads the bit's own block; the run's head can't have been
         * taken meanwhile -- callers hold the node-local alloc mutex,
         * and this node is the BG's only allocator). */
        {
            int rc = cetrafs_bitmap_try_alloc_exact(sb, bmap_lba, nblocks, nbits, run_start, sync);

            if (rc == 0)
                return (long) run_start;
            /* Propagate the real reason. Collapsing everything to
             * -ENOSPC here made a device read error during allocation
             * surface to userspace as "no space left" on a filesystem
             * with gigabytes free -- a diagnosis that sends whoever hits
             * it looking in entirely the wrong place. Only -ENOSPC means
             * no space. */
            return rc;
        }
    }

out_nospc:
    return -ENOSPC;
}

/* Clear bit 'bit' in the same kind of bitmap described above. Same
 * 'sync' reasoning as cetrafs_bitmap_alloc_bit() above. */
static int cetrafs_bitmap_free_bit(struct super_block *sb, u64 bmap_lba, u64 nblocks, u64 bit, bool sync)
{
    u64 blk = bit / CETRAFS_BITS_PER_BLOCK;
    u32 bit_in_block = bit % CETRAFS_BITS_PER_BLOCK;
    u32 byte = bit_in_block / 8;
    u32 bit_in_byte = bit_in_block % 8;
    struct buffer_head *bh;

    if (blk >= nblocks)
        return -EINVAL;

    bh = sb_bread(sb, bmap_lba + blk);
    if (!bh)
        return -EIO;

    /* Buffer lock across the modification, same protocol as every
     * other in-place update: without it a forced-fresh reader can clear
     * uptodate between the byte write and the mark-dirty and re-read the
     * old byte straight over it, losing the bit. A bitmap block has no
     * checksum, so there is no torn-image half of the hazard here -- but
     * the lost-update half is the same one that cost 12 of 292 directory
     * entries. */
    cetrafs_bh_begin_update(bh);
    *((u8 *) bh->b_data + byte) &= (u8) ~(1u << bit_in_byte);
    cetrafs_bh_end_update(bh);
    if (sync)
        sync_dirty_buffer(bh);
    brelse(bh);

    return 0;
}

/*
 * Claim one *specific* bit if it's currently free, instead of scanning for
 * the first free one -- the locality-preferring counterpart to
 * cetrafs_bitmap_alloc_bit() above, used by cetrafs_alloc_data_block_near()
 * to try "the block right after this file's last extent" before falling
 * back to a plain first-fit scan. Returns 0 on success, -ENOSPC if 'bit'
 * is out of range or already taken (the caller's cue to fall back), -EIO
 * on a read failure.
 */
static int cetrafs_bitmap_try_alloc_exact(struct super_block *sb,
                                          u64 bmap_lba,
                                          u64 nblocks,
                                          u64 nbits,
                                          u64 bit,
                                          bool sync)
{
    u64 blk = bit / CETRAFS_BITS_PER_BLOCK;
    u32 bit_in_block = bit % CETRAFS_BITS_PER_BLOCK;
    u32 byte = bit_in_block / 8;
    u32 bit_in_byte = bit_in_block % 8;
    struct buffer_head *bh;
    u8 *b;

    if (bit >= nbits || blk >= nblocks)
        return -ENOSPC;

    bh = sb_bread(sb, bmap_lba + blk);
    if (!bh)
        return -EIO;

    b = (u8 *) bh->b_data + byte;
    if (*b & (1u << bit_in_byte)) {
        brelse(bh);
        return -ENOSPC; /* already taken -- caller falls back to first-fit */
    }

    cetrafs_bh_begin_update(bh);
    *b |= (u8) (1u << bit_in_byte);
    cetrafs_bh_end_update(bh);
    if (sync)
        sync_dirty_buffer(bh);
    brelse(bh);

    return 0;
}

/*
 * Count the clear (free) bits among the first 'nbits' bits of the same
 * kind of bitmap described above. This is the authoritative (but O(bits))
 * way to compute a free count; used to seed/cross-check the cached
 * counters that avoid needing to call this on every statfs.
 */
static long cetrafs_bitmap_count_free(struct super_block *sb, u64 bmap_lba, u64 nblocks, u64 nbits)
{
    u64 blk;
    u64 free = 0;

    for (blk = 0; blk < nblocks; blk++) {
        struct buffer_head *bh = sb_bread(sb, bmap_lba + blk);
        unsigned int byte;

        if (!bh)
            return -EIO;

        for (byte = 0; byte < CETRAFS_BLOCK_SIZE; byte++) {
            const u8 *b = (const u8 *) bh->b_data + byte;
            unsigned int bit;

            if (*b == 0xFF)
                continue; /* fully used byte */

            for (bit = 0; bit < 8; bit++) {
                u64 idx = blk * CETRAFS_BITS_PER_BLOCK + byte * 8 + bit;

                if (idx >= nbits) {
                    brelse(bh);
                    return (long) free;
                }
                if (!(*b & (1u << bit)))
                    free++;
            }
        }

        brelse(bh);
    }

    return (long) free;
}

/* The global inode bitmap used to be bracketed by the device-wide
 * cluster mutex here (it is the one allocator every node shares, unlike
 * the per-node-partitioned ZGs and their data bitmaps). A compare-and-swap
 * replaced that with the lock-free path below, so the
 * mutex helpers and the bitmap-wide invalidate they needed are gone --
 * a CAS reads each region fresh on its own and re-reads on contention.
 *
 * The per-BG DATA bitmaps deliberately keep the plain cached path: only
 * a BG's owning node ever writes one, so
 * they are single-writer and need no atomic swap -- just the node-local
 * alloc mutex against this node's own threads.
 */

/* ---- global inode bitmap: lock-free allocation via CAS -------------
 *
 * The global inode bitmap is the one allocator every node shares (ZGs
 * and their data bitmaps are partitioned per-node by design), so it used
 * to be bracketed by the device-wide cluster mutex on every create and
 * every delete -- the single most contended claim in the filesystem.
 * A compare-and-swap of the 512-byte bitmap region holding the bit
 * replaces that.
 *
 * The mutator searches for a free bit in the image it is handed rather
 * than being told which bit to take: when a peer wins the region and the
 * swap miscompares, cetrafs_cas_record()'s retry re-reads and re-invokes
 * it, so it simply picks a different still-free bit in the refreshed
 * image. Scanning needs no lock at all -- a stale read can only cost a
 * retry, never a double allocation, because the swap is what actually
 * claims the bit.
 */
struct cetrafs_bmap_cas_ctx {
    u64 valid_bits; /* bits of this region that are inside the bitmap's real extent */
    u64 bit;        /* in: bit to clear (free); out: bit claimed (alloc), relative to the region */
    bool alloc;
    /* free only: the WINNING swap actually cleared the bit. The CAS layer
     * maps a mutate's "nothing to do" (>0) to plain success, so the return
     * value cannot carry "it was already free" -- and for the evict
     * arbiter that distinction is the entire point: a caller told
     * "success" when the bit was already clear believes it WON and frees
     * the inode's blocks a second time. That silent flattening made every
     * evict an arbiter winner and produced the cross-node double frees
     * behind fsck's "block referenced by an inode but marked FREE"
     * (ns-fuzz). Same pattern as pf_drain's ctx->consumed. */
    bool cleared;
};

static int cetrafs_bmap_cas_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_bmap_cas_ctx *ctx = priv;
    u8 *bytes = image;
    u64 limit = min_t(u64, ctx->valid_bits, (u64) len * 8);

    if (ctx->alloc) {
        u64 b;

        for (b = 0; b < limit; b++) {
            if (!(bytes[b >> 3] & (1u << (b & 7)))) {
                bytes[b >> 3] |= (u8) (1u << (b & 7));
                ctx->bit = b;
                return 0;
            }
        }
        return -ENOSPC; /* this region is full -- caller moves to the next */
    }

    /* Reset per attempt: a lost CAS re-runs this on a fresh image, and
     * what the caller may act on is only what the WINNING run did. */
    ctx->cleared = false;
    if (ctx->bit >= limit)
        return -EINVAL;
    if (!(bytes[ctx->bit >> 3] & (1u << (ctx->bit & 7))))
        return 1; /* already free -- flattened to success by the CAS layer;
                   * the caller must read ctx->cleared, not this */
    bytes[ctx->bit >> 3] &= (u8) ~(1u << (ctx->bit & 7));
    ctx->cleared = true;
    return 0;
}

/* Walk the global inode bitmap region by region, trying to claim a free
 * bit in each via CAS. Returns the global bit index, or -ENOSPC. */
static long cetrafs_inode_bitmap_cas_alloc(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    unsigned int region = cetrafs_cas_region_size(sb);
    unsigned int regions_per_block = CETRAFS_BLOCK_SIZE / region;
    u64 start = le64_to_cpu(raw_sb->inode_bmap_start);
    u64 nblocks = le64_to_cpu(raw_sb->inode_bmap_blocks);
    u64 nbits = le32_to_cpu(raw_sb->inodes_count);
    u64 blk;

    for (blk = 0; blk < nblocks; blk++) {
        unsigned int r;

        for (r = 0; r < regions_per_block; r++) {
            u64 base = blk * CETRAFS_BITS_PER_BLOCK + (u64) r * region * 8;
            struct cetrafs_bmap_cas_ctx ctx = {.alloc = true};
            int ret;

            if (base >= nbits)
                return -ENOSPC;
            ctx.valid_bits = min_t(u64, (u64) region * 8, nbits - base);

            ret = cetrafs_cas_region(sb, start + blk, r, cetrafs_bmap_cas_mutate, &ctx);
            if (ret == 0)
                return (long) (base + ctx.bit);
            if (ret == -ENOSPC)
                continue; /* region full */
            return ret;   /* real error (incl. -EBUSY after exhausting retries) */
        }
    }

    return -ENOSPC;
}

static int cetrafs_inode_bitmap_cas_free(struct super_block *sb, u64 bit)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    unsigned int region = cetrafs_cas_region_size(sb);
    u64 blk = bit / CETRAFS_BITS_PER_BLOCK;
    u64 bit_in_block = bit % CETRAFS_BITS_PER_BLOCK;
    unsigned int r = (unsigned int) (bit_in_block / (region * 8));
    u64 base = blk * CETRAFS_BITS_PER_BLOCK + (u64) r * region * 8;
    u64 nbits = le32_to_cpu(raw_sb->inodes_count);
    struct cetrafs_bmap_cas_ctx ctx = {.alloc = false};
    int ret;

    if (blk >= le64_to_cpu(raw_sb->inode_bmap_blocks))
        return -EINVAL;

    ctx.bit = bit_in_block - (u64) r * region * 8;
    ctx.valid_bits = min_t(u64, (u64) region * 8, nbits > base ? nbits - base : 0);

    ret = cetrafs_cas_region(sb, le64_to_cpu(raw_sb->inode_bmap_start) + blk, r, cetrafs_bmap_cas_mutate, &ctx);
    /* The CAS layer maps the mutate's "already free" (>0) to success, so
     * recover the arbiter verdict from the ctx: success without clearing
     * means someone else freed this number first and THEY own the blocks.
     * Before this check every caller was told it won, each freed the
     * dead inode's blocks independently, and the second free landed on
     * (or queued against) a block the allocator had since handed to a
     * live file -- fsck's "referenced by an inode but marked FREE"
     * (ns-fuzz seed 6003; ctest's ns-fuzz now fails on the
     * "double free of extent" warning this printed in every clean run). */
    if (ret == 0 && !ctx.cleared)
        ret = 1;
    /* Losing this CAS is NORMAL: concurrent evicts of the same dead
     * inode are by design (any node that watched nlink hit 0 tries),
     * and the whole point of the arbiter is that losers exist and free
     * nothing. Debug, not warn -- at warn level every cross-node delete
     * of a file cached on 2+ nodes would log, and ctest's double-free
     * oracle keys on the BLOCK-level "double free of extent" message,
     * which since the ctx.cleared fix means an actual bug again. */
    if (ret > 0)
        pr_debug("inode bitmap: bit %llu was already free (lost the free arbitration)\n", (unsigned long long) bit);
    /* ret > 0 ("was already free") is deliberately passed through rather
     * than flattened to success: the caller must not credit the
     * free-inode count for a bit that was already clear, or a double
     * free inflates it by one each time -- the same shape as the data
     * free path's double-credit, in the inode half. */
    return ret;
}

/* Allocate a free inode number (1-based) from the global inode bitmap. */
int cetrafs_alloc_inode(struct super_block *sb, u64 *out_ino)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    long bit;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced */
    if (!raw_sb)
        return -EINVAL;

    bit = cetrafs_inode_bitmap_cas_alloc(sb);
    if (bit < 0)
        return (int) bit;

    *out_ino = (u64) bit + 1; /* bit is 0-based, ino is 1-based */
    ctrace("INOALLOC ino=%llu\n", (unsigned long long) *out_ino);

    /*
     * The bitmap said this number was free. Ask the RECORD whether it
     * agrees: the bit and the record are two independent pieces of
     * state, and only their agreement makes a number safe to reuse.
     * A record still claiming links belongs to a LIVE file, and handing
     * that number to a second owner is how a populated directory gets
     * reinitialised by somebody else's mkdir -- every name in it
     * orphaned, its blocks unreachable, the files simply gone.
     *
     * cetrafs_free_inode() zeroes nlink precisely so this means
     * something: a properly freed record claims nothing, so nlink != 0
     * here is not stale residue.
     *
     * Per the correctness bar a detected collision is never silently
     * accepted. Losing one number is a leak the scrub reclaims; handing
     * it out twice is data loss.
     */
    {
        cetrafs_inode_t raw;
        bool have = false;

        /* Read the record ONCE, raw. cetrafs_read_raw_inode() is wrong
         * here twice over: a VIRGIN number -- never allocated since
         * mkfs -- has an all-zero record, which fails the checksum, so
         * that reader burns its whole retry budget and then logs
         * 'corrupted, not just a torn concurrent read' for every first
         * allocation of every number. Storms of those messages (and
         * +1.5ms per create) were chased as filesystem corruption for
         * half a morning. All-zero IS the expected shape
         * of a free record; only a checksummed record claiming links
         * means the number is in use. */
        {
            struct buffer_head *bh;

            cetrafs_invalidate_raw_inode(sb, *out_ino);
            bh = cetrafs_bread_retry(sb, cetrafs_inode_lba(sb, *out_ino));
            if (bh) {
                cetrafs_bh_copy_stable(bh, &raw, sizeof(raw));
                brelse(bh);
                have = cetrafs_inode_crcs_ok(&raw);
            }
        }
        if (have && cetrafs_le32(raw.nlink) != 0) {
            pr_err(
                "alloc_inode: the bitmap handed out ino=%llu but its record still claims %u link(s) "
                "(generation=%llu mode=0%o size=%llu) -- refusing to hand a LIVE inode to a second owner\n",
                (unsigned long long) *out_ino, (unsigned int) cetrafs_le32(raw.nlink),
                (unsigned long long) cetrafs_le64(raw.generation), (unsigned int) cetrafs_le32(raw.mode),
                (unsigned long long) cetrafs_le64(raw.size));
            *out_ino = 0;
            return -EIO;
        }
    }

    /* Mark the number mid-birth BEFORE returning it: from here until the
     * first name is published, the on-disk record cannot prove this node
     * owns the number (the dead previous record is still what a scanner
     * reads), so the orphan scrub keys off this registry instead. */
    cetrafs_sb_birth_begin(sb, *out_ino);
    cetrafs_sb_adjust_free_inodes(sb, -1);
    return 0;
}

/* Release an inode number back to the global inode bitmap. */
int cetrafs_free_inode(struct super_block *sb, u64 ino)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced */
    if (!raw_sb || !ino)
        return -EINVAL;

    /* Any free ends the number's gestation: every create error path
     * funnels through here, so the birth registry cannot leak. */
    cetrafs_sb_birth_end(sb, ino);

    /*
     * Zero the record's nlink before the bit goes back. Until now a
     * freed inode's record kept whatever it last said -- the comment in
     * cetrafs_evict_inode() notes the record is never zeroed -- so
     * "does this record claim links?" could not distinguish a live
     * inode from a dead one, and nothing could check that the bitmap
     * and the record agree before handing a number out.
     *
     * A record that outlives its bit and still claims links is also
     * what fsck reports as "allocated but NO directory entry names it"
     * once the number is reused, so this makes the on-disk state honest
     * as well as checkable.
     */
    {
        cetrafs_inode_t raw;

        cetrafs_invalidate_raw_inode(sb, ino);
        if (cetrafs_read_raw_inode(sb, ino, &raw) == 0) {
            ctrace("INOFREE ino=%llu nlink_on_disk=%u size=%llu from=%pS\n", (unsigned long long) ino,
                   (unsigned int) cetrafs_le32(raw.nlink), (unsigned long long) cetrafs_le64(raw.size),
                   __builtin_return_address(0));
            if (cetrafs_le32(raw.nlink) != 0)
                (void) cetrafs_inode_ns_zero_nlink(sb, ino, &raw);
        }
    }

    ret = cetrafs_inode_bitmap_cas_free(sb, ino - 1);
    if (ret > 0)
        return 1; /* ALREADY free: someone else's free won the CAS. Distinct
                   * from 0 so a caller arbitrating "who frees the dead
                   * file's BLOCKS" (evict_inode) can tell winner from
                   * loser -- two nodes evicting the same dead inode both
                   * freeing its blocks double-frees them (one pending-free
                   * entry per evict; the second apply lands after the
                   * owner reallocated the block). */
    if (!ret)
        cetrafs_sb_adjust_free_inodes(sb, 1);
    return ret;
}

/*
 * The orphan scrub's conditioned free. cetrafs_free_inode() trusts its
 * caller's verdict; the scrub's verdict can go stale in MICROSECONDS (a
 * create can reuse the number between the verdict read and the free --
 * caught live: INOFREE with nlink_on_disk=1, 378us after the INOALLOC,
 * two files then sharing one inode; 2026-10-29). Re-read the record
 * FRESH immediately before the free and require it to still be the dead
 * record the verdict saw: nlink==0 AND the same generation (every
 * rebirth stamps a new generation, so a reborn number can never match).
 * A mismatch returns -ESTALE and frees nothing. The residual window
 * (create wrote its record after this re-read) is closed by the birth
 * registry, which the scrub checks before ever reaching here.
 */
int cetrafs_free_inode_if_dead(struct super_block *sb, u64 ino, u64 generation)
{
    cetrafs_inode_t raw;
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    if (!ino)
        return -EINVAL;

    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_read_raw_inode(sb, ino, &raw);
    if (ret)
        return ret; /* cannot vouch -- free nothing */
    if (cetrafs_le32(raw.nlink) != 0 || cetrafs_le64(raw.generation) != generation)
        return -ESTALE; /* reborn under the verdict -- not ours to free */

    ret = cetrafs_inode_bitmap_cas_free(sb, ino - 1);
    if (ret > 0)
        return 1;
    if (!ret)
        cetrafs_sb_adjust_free_inodes(sb, 1);
    return ret;
}

/* The on-disk cetrafs_block_group_t is ~4KB, almost all reserved padding;
 * copying the whole thing onto the stack is both wasteful and a real
 * kernel-stack-overflow risk. Extract just the handful of fields callers
 * need instead. BG descriptor fields are stored plain-native (no __le
 * wrapping), same convention userspace/fsck.c already relies on. */
struct cetrafs_bg_geom {
    u64 start_block;
    u32 off_data_bmap;
    u32 off_data_region;
    u64 data_block_count;
    u64 free_data_blocks; /* cached count, as of the last read */
    u64 reconcile_seq;    /* the count's ownership epoch, as of the last read */
    u32 owner_zg;         /* ZG this BG belongs to */
};

/* CRC32C over a BG descriptor block with its checksum field treated as
 * zero -- three-segment, same reasoning as zonegroup.c's
 * cetrafs_zg_crc_verify() (the struct is a full block; no stack copy). */
static u32 cetrafs_bg_crc_verify(const void *raw)
{
    static const u8 zero[8] = {0};
    size_t off = offsetof(cetrafs_block_group_t, checksum);
    size_t clen = sizeof(((cetrafs_block_group_t *) 0)->checksum);
    u32 crc = ~0U;

    BUILD_BUG_ON(sizeof(zero) != clen);

    crc = crc32c(crc, raw, off);
    crc = crc32c(crc, zero, clen);
    crc = crc32c(crc, (const u8 *) raw + off + clen, sizeof(cetrafs_block_group_t) - off - clen);
    return ~crc;
}

/* Calls to cetrafs_read_bg_geom(). The lookup that answers "which Block
 * Group holds this LBA" used to scan the whole table -- 2047 of these
 * per call on the deployment LUN, 1.3-2.7 ms measured. O(1) arithmetic
 * replaced it; this counter is how a test can tell the difference. */
static atomic64_t cetrafs_bg_geom_reads = ATOMIC64_INIT(0);

u64 cetrafs_bg_geom_read_count(void)
{
    return (u64) atomic64_read(&cetrafs_bg_geom_reads);
}

/* CLAUDE.md cross-node review rules): the kernel used to
 * trust BG descriptors without ever verifying their checksum -- and a
 * cross-node reader (a peer's statfs, a foreign free resolving
 * owner_zg) can observe the owning node's in-flight counter write torn.
 * Verify + retry with a forced-fresh re-read, same shape as every other
 * checksummed-record reader; only a persistent mismatch is -EUCLEAN. */
static int cetrafs_read_bg_geom(struct super_block *sb, u32 bg_id, struct cetrafs_bg_geom *out)
{
    atomic64_inc(&cetrafs_bg_geom_reads);
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 blk;
    int attempt;

    if (!raw_sb)
        return -EINVAL;
    if (bg_id >= le32_to_cpu(raw_sb->block_group_count))
        return -EINVAL;

    blk = cetrafs_sb_bg_desc_lba(sb, bg_id);

    for (attempt = 0; attempt < 5; attempt++) {
        const cetrafs_block_group_t *bg;
        struct buffer_head *bh;

        /* First attempt stays on the cached fast path (this is the
         * per-allocation hot path for a BG's own owner, whose cache is
         * authoritative); retries force a real re-read. */
        /* PERF(6): attempt 0 stays cached -- docs/PERFORMANCE.md */
        if (attempt > 0)
            cetrafs_invalidate_block(sb, blk);

        bh = sb_bread(sb, blk);
        if (!bh)
            return -EIO;

        bg = (const cetrafs_block_group_t *) bh->b_data;
        if (cetrafs_bg_crc_verify(bh->b_data) == (u32) cetrafs_le64(bg->checksum)) {
            out->start_block = cetrafs_le64(bg->start_block);
            out->off_data_bmap = cetrafs_le32(bg->off_data_bmap);
            out->off_data_region = cetrafs_le32(bg->off_data_region);
            out->data_block_count = cetrafs_le64(bg->data_block_count);
            out->free_data_blocks = cetrafs_le64(bg->free_data_blocks);
            out->reconcile_seq = cetrafs_le64(bg->reconcile_seq);
            out->owner_zg = cetrafs_le16(bg->owner_zg);
            brelse(bh);
            return 0;
        }
        brelse(bh);

        /* Back off, like every other checksummed-record reader: a
         * mismatch here is a peer's in-flight counter write seen torn,
         * and a peer's write takes milliseconds. (This is the FIFTH such
         * reader -- the P5 pass that added the backoff to the inode
         * record, node row and ZG record enumerated four and missed this
         * one, which lives in alloc.c rather than with the others.) */
        usleep_range(100, 400);
    }

    pr_err("BG %u failed its descriptor checksum repeatedly -- corrupted, not just a torn concurrent read\n", bg_id);
    return -EUCLEAN;
}

/*
 * Drop any cached copy of BG #bg_id's descriptor and bitmap blocks --
 * called by zonegroup.c right after a Zone Group is freshly claimed or
 * reclaimed, never on the routine "already ours,
 * re-attaching" path. A node's view of a BG it does *not* currently own
 * can go stale in an ordinary, non-edge-case way: procfs's "info" dump
 * reads every BG's descriptor regardless of ownership,
 * which alone is enough to populate this node's cache with another
 * node's BG the first time anyone cat's /proc/fs/cetrafs/<dev>/info. Once
 * this node actually claims that BG's owning ZG, it must see what the
 * previous owner really left (free_data_blocks, every bit of the data
 * bitmap), not whatever happened to be cached from that earlier read.
 * Lazy, like cetrafs_invalidate_block() itself -- no I/O here, just
 * forces the next real cetrafs_read_bg_geom()/cetrafs_bitmap_*() call on
 * this BG to go back to the device.
 */
/*
 * Counters behind procfs's bg_desc_kept / bg_desc_refreshed -- the only
 * way from userspace to see that the whole-volume descriptor sweeps
 * below are leaving this node's OWN hot descriptors alone. Module-wide
 * like cas_ops, so tests must assert on a delta.
 */
static atomic64_t cetrafs_bg_desc_kept = ATOMIC64_INIT(0);
static atomic64_t cetrafs_bg_desc_refreshed = ATOMIC64_INIT(0);

u64 cetrafs_bg_desc_kept_count(void)
{
    return (u64) atomic64_read(&cetrafs_bg_desc_kept);
}

u64 cetrafs_bg_desc_refreshed_count(void)
{
    return (u64) atomic64_read(&cetrafs_bg_desc_refreshed);
}

/*
 * Prepare BG #bg_id's descriptor for one of the whole-volume read-only
 * sweeps (super_ops.c's statfs, procfs's "info"), which must see a
 * PEER's writes and so cannot trust a cached copy of a BG that peer
 * owns.
 *
 * A BG THIS node owns is the exception, and it has to be: this node is
 * the only writer of that count, cetrafs_bg_data_block_stats() already
 * folds in the accrued-but-unapplied delta, so the forced read tells us
 * nothing new -- while dropping the cached descriptor throws away the
 * exact block cetrafs_alloc_pick_bg() re-reads, for every owned BG, on
 * EVERY single block allocation.
 *
 * That was harmless until v0x0004. Before it, cetrafs_bg_adjust_free_
 * blocks() read-modify-wrote the descriptor in the buffer cache, so a
 * BG this node was actively allocating from had a DIRTY descriptor --
 * and cetrafs_invalidate_block() deliberately refuses to drop a dirty
 * buffer, so the hot ones were silently skipped and the sweep cost the
 * allocator nothing. v0x0004 stopped dirtying it (a dirty buffer is
 * flushable by background writeback at any moment, which let a stale
 * node clobber a stealing peer's reconcile), leaving every descriptor
 * clean -- and this sweep, unchanged, began succeeding on the hot BGs
 * too. On a Proxmox host, where pvestatd polls statfs on every storage
 * every ~10s, that wipes the allocator's descriptor cache mid-stream,
 * over and over. Measured on the real LUN as streaming writes dropping
 * from ~200 MB/s to ~120 MB/s and degrading further as the file grew
 * (a filling node claims more ZGs, so each wipe costs more descriptors
 * to re-fetch). Same mechanism, different trigger, as the per-tick
 * epoch seeding cured in zonegroup.c's cetrafs_zg_try_claim_one().
 */
/* PERF(3): must skip BGs this node owns -- docs/PERFORMANCE.md */
void cetrafs_bg_desc_refresh_foreign(struct super_block *sb, u32 bg_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);

    if (!raw_sb)
        return;

    if (cetrafs_sb_bg_is_ours(sb, bg_id)) {
        atomic64_inc(&cetrafs_bg_desc_kept);
        return;
    }

    cetrafs_invalidate_block(sb, cetrafs_sb_bg_desc_lba(sb, bg_id));
    atomic64_inc(&cetrafs_bg_desc_refreshed);
}

int cetrafs_bg_invalidate_cache(struct super_block *sb, u32 bg_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct cetrafs_bg_geom bg;
    u64 bmap_lba, bmap_blocks, blk;
    int ret;

    if (!raw_sb)
        return -EINVAL;

    cetrafs_invalidate_block(sb, cetrafs_sb_bg_desc_lba(sb, bg_id));

    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;

    bmap_lba = bg.start_block + bg.off_data_bmap;
    bmap_blocks = bg.off_data_region - bg.off_data_bmap;
    for (blk = 0; blk < bmap_blocks; blk++)
        cetrafs_invalidate_block(sb, bmap_lba + blk);

    return 0;
}

/*
 * Adjust BG #bg_id's free_data_blocks by 'delta' (-1 on alloc, +1 on
 * free): ACCRUE it in memory (fs.c's per-BG delta array) and let
 * cetrafs_flush_dirty_free_counts() apply it with one compare-and-swap
 * per dirty BG at the durability boundaries (a file-lock close, a
 * namespace-lock release, evict, sync_fs, unmount).
 *
 * v0x0004: this used to read-modify-write the descriptor in the buffer
 * cache and leave the block dirty for those same boundaries to sync --
 * batched for the same per-allocation-round-trip reason (a per-call sync
 * once made a 2s write take 40s on the real LUN). But a dirty buffer is
 * also flushable by ORDINARY BACKGROUND WRITEBACK at any moment, and
 * the one legitimate foreign writer of this descriptor is a stealing
 * peer's reconcile after it declared us stale: our stale cached image
 * landing after its recount silently reverted the truth it had just
 * derived from the bitmaps, with a correctly restamped checksum nothing
 * could detect. Exactly the clobber the ZG aggregate already had (see
 * fs.c's zg_free_delta comment); same cure -- nothing of ours ever sits
 * dirty in the page cache for a record a peer may legitimately rewrite,
 * and the apply detects a lost ownership race instead of overwriting
 * (cetrafs_bg_count_mutate() below).
 *
 * Also rolls the same delta up into the owning ZG's aggregate
 * (fsck cross-checks "ZG == sum of its BGs", and the roll-up
 * was once missing entirely).
 *
 * owner_zg USED to be immutable after mkfs, which is what justified
 * serving it from the cached descriptor here. It is not any more: a
 * Block Group owned by nobody can be claimed while the volume runs
 * (docs/internal/BG-OWNERSHIP-DESIGN.md). The cached read stays --
 * invalidating per allocation is exactly the per-block device round
 * trip PERFORMANCE.md forbids -- and the claim path invalidates the
 * descriptor itself, so the next read here sees the new owner. What
 * this must not do is trust a stale FREE: rolling a delta into Zone
 * Group 0xFFFF would index past every per-ZG array, so it is checked
 * below rather than assumed away.
 *
 * A roll-up failure is loud but doesn't fail the alloc/free itself:
 * the operation this was called from already succeeded, matching every
 * caller (which ignore this return).
 */
static int cetrafs_bg_adjust_free_blocks(struct super_block *sb, u32 bg_id, s64 delta)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    const cetrafs_block_group_t *bg;
    struct buffer_head *bh;
    u32 owner_zg;
    int ret;

    if (!raw_sb)
        return -EINVAL;
    if (bg_id >= le32_to_cpu(raw_sb->block_group_count))
        return -EINVAL;

    bh = sb_bread(sb, cetrafs_sb_bg_desc_lba(sb, bg_id));
    if (!bh)
        return -EIO;
    bg = (const cetrafs_block_group_t *) bh->b_data;
    owner_zg = cetrafs_le16(bg->owner_zg);
    brelse(bh);

    /* PERF(4): accrue only -- a sync here is one device round trip per
     * allocated block (1 MiB write: 2s -> 40s). docs/PERFORMANCE.md */
    cetrafs_sb_accrue_bg_free(sb, bg_id, delta);

    /* Nobody's Block Group has nobody's aggregate to roll into, and
     * CETRAFS_BG_OWNER_FREE as an index would run off every per-ZG
     * array. Reaching here with a free owner means this node allocated
     * from a Block Group it has not claimed, which is a bug worth
     * saying out loud rather than papering over. */
    if (owner_zg == CETRAFS_BG_OWNER_FREE) {
        pr_err("BG %u free-count adjust: the Block Group is owned by nobody -- allocated from unclaimed space\n",
               bg_id);
        return 0;
    }

    ret = cetrafs_zg_adjust_free_blocks(sb, owner_zg, delta);
    if (ret)
        pr_err("BG %u free-count adjust: failed to roll up into owning ZG %u: %d\n", bg_id, owner_zg, ret);
    return 0;
}

/*
 * The compare-and-swap that actually writes a BG descriptor's count.
 *
 * The CAS unit is the block's first sector, but the descriptor's
 * checksum covers the whole 4 KiB block -- whose tail past the fields is
 * zero by construction (the descriptor is alone in its block, mkfs
 * zero-fills it, and no writer ever touches the tail). So the image CRC
 * here is: the in-sector fields with the checksum treated as zero, then
 * (CETRAFS_BLOCK_SIZE - len) zero bytes folded in.
 */
static u32 cetrafs_bg_image_crc(const void *image, unsigned int len)
{
    static const u8 zero[8] = {0};
    size_t off = offsetof(cetrafs_block_group_t, checksum);
    size_t clen = sizeof(((cetrafs_block_group_t *) 0)->checksum);
    u32 crc = ~0U;
    unsigned int left = CETRAFS_BLOCK_SIZE - len;

    crc = crc32c(crc, image, off);
    crc = crc32c(crc, zero, clen);
    crc = crc32c(crc, (const u8 *) image + off + clen, len - off - clen);
    while (left) {
        unsigned int n = min_t(unsigned int, left, PAGE_SIZE);

        crc = crc32c(crc, page_address(ZERO_PAGE(0)), n);
        left -= n;
    }
    return ~crc;
}

struct cetrafs_bg_count_ctx {
    bool absolute;  /* reconcile: count = value and the epoch advances */
    s64 value;      /* the delta, or (absolute) the bitmap truth */
    u64 expect_seq; /* delta mode: the epoch the delta was accrued under */
    u64 out_seq;    /* the epoch in the image the swap committed */
    u32 bg_id;      /* for the log lines */
    bool refused;   /* delta mode: the image could not take it (underflow) */
};

static int cetrafs_bg_count_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_bg_count_ctx *ctx = priv;
    cetrafs_block_group_t *bg = (cetrafs_block_group_t *) image;
    s64 want;

    /* Re-run from scratch on every CAS attempt: a miscompare retry gets
     * a fresh image, so a verdict from the previous attempt must not
     * survive into this one. */
    ctx->refused = false;

    if (ctx->absolute) {
        /* A reconcile: the new owner writing the bitmap truth. Advances
         * the epoch, so every delta accrued under the previous owner's
         * epoch -- already included in this recount where it was durable
         * -- is refused below from here on. Last writer wins by design:
         * only an owner reconciles, and ownership transfer is what
         * orders reconciles. */
        bg->free_data_blocks = cetrafs_cpu_to_le64((u64) ctx->value);
        bg->reconcile_seq = cetrafs_cpu_to_le64(cetrafs_le64(bg->reconcile_seq) + 1);
    } else {
        /*
         * A delta is only meaningful within the ownership epoch it was
         * accrued under. An image whose epoch moved was reconciled by a
         * NEW owner (a peer that declared this node stale and stole the
         * covering Zone Group) -- its recount already includes this
         * delta's durable effects, so applying it would double count.
         * Detecting the rewrite by value would not work: a recount can
         * be byte-identical to what this node expects. The epoch cannot.
         */
        if (cetrafs_le64(bg->reconcile_seq) != ctx->expect_seq) {
            pr_warn(
                "BG %u free delta %lld dropped: the count was reconciled by a new owner (epoch %llu, ours was %llu)\n",
                ctx->bg_id, (long long) ctx->value, (unsigned long long) cetrafs_le64(bg->reconcile_seq),
                (unsigned long long) ctx->expect_seq);
            ctx->out_seq = cetrafs_le64(bg->reconcile_seq);
            return 1; /* dropped, loudly -- not an error */
        }
        want = (s64) cetrafs_le64(bg->free_data_blocks) + ctx->value;
        if (want < 0) {
            /* A count, never negative -- same refusal as the ZG
             * aggregate's mutator: fsck cross-checks these.
             *
             * Flagged rather than returned as a plain error, because
             * the two are not the same thing to the caller: an I/O
             * error is worth retrying the delta on, while a delta that
             * does not FIT never will. Re-accruing one of those is an
             * endless loop -- the heartbeat re-flushes every tick, logs
             * the same pair of lines, and the surplus-ZG release that
             * flushes first can never complete. Observed in the field
             * for hours; the delta is dropped here instead. */
            pr_err("BG %u free delta %lld would take the count below zero (%llu)\n", ctx->bg_id, (long long) ctx->value,
                   (unsigned long long) cetrafs_le64(bg->free_data_blocks));
            ctx->refused = true;
            return -EINVAL;
        }
        bg->free_data_blocks = cetrafs_cpu_to_le64((u64) want);
    }

    ctx->out_seq = cetrafs_le64(bg->reconcile_seq);
    /* Normalize the in-sector tail past the real fields to zero (the
     * zero-by-construction invariant cetrafs_bg_image_crc() rests on),
     * same as every node-row mutator does for its region. */
    memset((u8 *) image + offsetof(cetrafs_block_group_t, pad), 0, len - offsetof(cetrafs_block_group_t, pad));
    bg->checksum = 0;
    bg->checksum = cetrafs_cpu_to_le64(cetrafs_bg_image_crc(image, len));
    return 0;
}

/*
 * Apply one accrued free-count delta to BG #bg_id's descriptor, as a
 * compare-and-swap guarded by the ownership epoch the delta was accrued
 * under (fs.c tracks it per BG; the covering ZG's claim paths seed it).
 * Called from cetrafs_flush_dirty_free_counts(). Returns 0 whether the
 * delta applied or was (loudly) dropped as stale -- both consume it --
 * and a negative errno only for real I/O trouble, where the caller
 * re-accrues the delta rather than losing it.
 */
int cetrafs_bg_apply_free_delta(struct super_block *sb, u32 bg_id, s64 delta)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct cetrafs_bg_count_ctx ctx = {.value = delta, .bg_id = bg_id};
    int ret;

    if (!raw_sb)
        return -EINVAL;
    if (bg_id >= le32_to_cpu(raw_sb->block_group_count))
        return -EINVAL;

    ctx.expect_seq = cetrafs_sb_bg_epoch(sb, bg_id);

    /* The SEEDED record CAS, fed from the cached block: the descriptor is
     * a record block (one record in region 0, zero tail), we are its only
     * legitimate writer while we own the covering ZG, and the seeded path
     * refreshes the cache with each committed image (caw.c) -- so the
     * steady-state apply is exactly one sector CAW: no pre-read, no
     * post-read, and cetrafs_read_bg_geom()'s cached fast path (the
     * owner's per-allocation hot path) stays warm and CORRECT. Measured
     * the other way first: the generic cetrafs_cas_record() (uncached
     * pre-read + post-CAS invalidate) cost real wall clock across every
     * close boundary of a two-node suite run. A stale seed -- a thief's
     * reconcile landed, or the cache was simply cold -- just MISCOMPAREs
     * and the retry re-reads fresh, where the epoch guard decides. */
    {
        struct buffer_head *bh = sb_bread(sb, cetrafs_sb_bg_desc_lba(sb, bg_id));

        ret = cetrafs_cas_record_seeded(sb, cetrafs_sb_bg_desc_lba(sb, bg_id), bh ? bh->b_data : NULL,
                                        bh ? cetrafs_cas_region_size(sb) : 0, cetrafs_bg_count_mutate, &ctx);
        if (bh)
            brelse(bh);
    }

    /* A delta the descriptor cannot take is CONSUMED, like a dropped
     * stale one: it is not a transient failure and no number of retries
     * turns it into a fit. Our count for this BG is out of step with
     * its bitmap; the bitmap is the truth and the next reconcile of
     * this Block Group (its ownership entering this node) repairs the
     * descriptor from it. fsck cross-checks the same pair meanwhile. */
    if (ctx.refused) {
        pr_err("BG %u: dropping the delta -- this node's free count for it is out of step with its bitmap, "
               "which a reconcile (or fsck) repairs\n",
               bg_id);
        return 0;
    }
    return ret;
}

/*
 * Seed this node's in-memory count epochs from the device, for a ZG
 * whose ownership entered the cache WITHOUT a reconcile -- the heartbeat
 * tick's "already ours, re-attaching" path. Reconcile seeds the epoch
 * itself everywhere it runs; a ZG cached without one would accrue every
 * delta under epoch 0, all to be dropped at the first flush.
 */
int cetrafs_bg_seed_count_epochs(struct super_block *sb, u32 zg_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 b, nbg;
    int ret;

    if (!raw_sb)
        return -EINVAL;

    nbg = le32_to_cpu(raw_sb->block_group_count);

    /* Every Block Group this Zone Group owns, asked of the Block
     * Groups themselves rather than of a contiguous range
     * (docs/internal/BG-OWNERSHIP-DESIGN.md). Runs on a Zone Group
     * claim, not per block, so the scan over every Block Group is
     * affordable where it would not be on the allocation path. */
    for (b = 0; b < nbg; b++) {
        struct cetrafs_bg_geom bg;

        if (cetrafs_sb_bg_owner(sb, b) != zg_id)
            continue;

        /* Fresh: a cached descriptor can predate an epoch advanced by
         * whoever last reconciled this BG. */
        cetrafs_invalidate_block(sb, cetrafs_sb_bg_desc_lba(sb, b));
        ret = cetrafs_read_bg_geom(sb, b, &bg);
        if (ret)
            return ret;
        cetrafs_sb_set_bg_epoch(sb, b, bg.reconcile_seq);
    }
    return 0;
}

/* Allocate a free data block (as an absolute LBA) from BG #bg_id's data
 * bitmap. The node-local alloc mutex (fs.c) serializes this against every
 * other local data-bitmap/counter RMW -- two local threads growing two
 * different files used to race plain |=/&= byte updates on the same
 * cached bitmap block with nothing covering them at all. */
/*
 * Refuse to allocate from a Block Group this node does not own.
 *
 * Writing another node's data bitmap is the single most damaging thing
 * this module can do: the owner is concurrently allocating from the same
 * bitmap with no cross-node exclusion (none is needed -- Zone Group
 * ownership is what partitions it), so a stray write there hands the
 * same physical block to two files on two nodes. That is the delegated-free
 * corruption class, and the FREE path already guards against it by
 * routing a foreign block to the owner's pending-free queue instead of
 * touching its bitmap. The ALLOC path had no equivalent check at all --
 * it trusted whatever bg_id its caller passed.
 *
 * Today the only caller is cetrafs_alloc_pick_bg(), which scans owned
 * ZGs. The guard is not about that caller being wrong now; it is about
 * the next one. This project has already been bitten once by a safety
 * property that held only because one function happened to compute it
 * correctly (a stale "is a mutex available?" test standing in for "can
 * this volume have more than one node?"), and the cost of being wrong
 * here is silent cross-node data corruption. One cached bitmap test per
 * allocation turns it into a loud refusal.
 */
/*
 * Test-only: make the ownership check above see every BG as foreign.
 * The guard cannot otherwise be reached -- the sole caller only ever
 * passes BGs in owned zone groups, which is exactly the property under
 * test -- and a guard nothing ever runs is a guard nobody knows works.
 */
static bool cetrafs_alloc_force_foreign;
module_param_named(alloc_force_foreign, cetrafs_alloc_force_foreign, bool, 0644);
MODULE_PARM_DESC(alloc_force_foreign, "test-only: treat every Block Group as owned by another node");

static int cetrafs_alloc_check_owned(struct super_block *sb, u32 bg_id, const struct cetrafs_bg_geom *bg)
{
    if (cetrafs_alloc_force_foreign)
        goto not_ours;
    if (cetrafs_sb_zg_owned_cached(sb, bg->owner_zg))
        return 0;

not_ours:
    pr_err("alloc: refusing to allocate from BG %u -- its zone group %u is not owned by this node\n", bg_id,
           bg->owner_zg);
    return -EPERM;
}

int cetrafs_alloc_data_block(struct super_block *sb, u32 bg_id, u64 *out_lba)
{
    struct cetrafs_bg_geom bg;
    long bit;
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced */

    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;
    ret = cetrafs_alloc_check_owned(sb, bg_id, &bg);
    if (ret)
        return ret;

    cetrafs_sb_alloc_lock(sb);
    /* Run-aware placement: try to start the new extent at
     * the head of a decent free run -- 4 MiB, then 1 MiB, then 128 KiB --
     * before degrading to plain first-fit. The contiguity hint
     * (cetrafs_alloc_data_block_near()) then extends from wherever this
     * lands, so one good placement here saves a whole extent-per-hole
     * cascade later. */
    {
        static const u64 run_targets[] = {1024, 256, 32, 1};
        unsigned int t;

        bit = -ENOSPC;
        for (t = 0; t < ARRAY_SIZE(run_targets) && bit == -ENOSPC; t++)
            bit = cetrafs_bitmap_alloc_run_start(sb, bg.start_block + bg.off_data_bmap,
                                                 bg.off_data_region - bg.off_data_bmap, bg.data_block_count,
                                                 run_targets[t], /*sync=*/false);
    }
    if (bit >= 0) {
        cetrafs_bg_adjust_free_blocks(sb, bg_id, -1);
        cetrafs_sb_note_bmap_alloc(sb, bg_id);
    }
    cetrafs_sb_alloc_unlock(sb);

    if (bit < 0)
        return (int) bit;

    *out_lba = bg.start_block + bg.off_data_region + (u64) bit;
    cetrafs_shadow_set(sb, *out_lba, 1, "alloc_data_block");
    ctrace("BLKALLOC lba=%llu bg=%u from=%pS\n", (unsigned long long) *out_lba, bg_id, __builtin_return_address(0));
    return 0;
}

/*
 * Like cetrafs_alloc_data_block(), but tries 'preferred_lba' first (if it's
 * a real LBA -- 0 means "no preference", since LBA 0 is always the
 * superblock, never a valid data block) before falling back to the normal
 * first-fit scan. The locality optimization for the fragmentation fix:
 * callers growing a file contiguously pass the block right
 * after the file's current last extent, so a sequential write keeps
 * landing in one extent instead of first-fit scattering each new block
 * across whatever a BG's free bitmap happens to look like after unrelated
 * churn. Doesn't retroactively heal an already-fragmented BG -- it just
 * stops a *new*, otherwise-contiguous write from fragmenting further.
 *
 * A miss (preferred_lba out of this BG's range, or already taken) is not
 * an error -- it's the expected, correct outcome whenever there's no
 * locality to exploit (a brand-new file's first block, a hole-filling
 * write, or this BG having moved on without the caller knowing), and
 * falling back to the unconditional first-fit scan is exactly right.
 */
/*
 * Allocate ONE data block from wherever this node can, retrying past a
 * Block Group whose cached free count lies.
 *
 * pick_bg chooses by the cached count, which can report space in a BG
 * whose bitmap is full; the allocation then fails ENOSPC and the caller
 * gives up, even though the volume has terabytes free. Every caller that
 * does pick_bg + alloc_data_block by hand has that hole -- which is how
 * the extent-tree growth paths (a new leaf or interior block) kept
 * returning ENOSPC out through cetrafs_get_block() long after the
 * block-allocation path itself had been fixed. A guest write failed only
 * when the tree needed to GROW, so plain dd to the same filesystem ran
 * at full speed while a VM paused on "nospace".
 *
 * Recounting the lying BG from its bitmap is what bounds the loop: the
 * corrected count reads zero, so pick_bg stops choosing it.
 */
int cetrafs_alloc_block_anywhere(struct super_block *sb, u32 *out_bg, u64 *out_lba)
{
    unsigned int attempt;
    int ret = -ENOSPC;

    for (attempt = 0; attempt < CETRAFS_ALLOC_PICK_RETRIES; attempt++) {
        u32 bg;
        s64 delta = 0;

        ret = cetrafs_alloc_pick_bg(sb, &bg);
        if (ret)
            return ret;

        ret = cetrafs_alloc_data_block(sb, bg, out_lba);
        if (ret == 0) {
            if (out_bg)
                *out_bg = bg;
            return 0;
        }
        if (ret != -ENOSPC)
            return ret;

        if (cetrafs_bg_reconcile_free_count(sb, bg, &delta) != 0)
            return ret;
        atomic64_inc(&cetrafs_bg_recounts);
        pr_warn_ratelimited("alloc: BG %u reported free space but its bitmap is full -- recounted (delta %lld)\n", bg,
                            (long long) delta);
    }
    return ret;
}

int cetrafs_alloc_data_block_near(struct super_block *sb, u32 bg_id, u64 preferred_lba, u64 *out_lba)
{
    struct cetrafs_bg_geom bg;
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced */

    if (preferred_lba) {
        ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
        if (ret)
            return ret;
        ret = cetrafs_alloc_check_owned(sb, bg_id, &bg);
        if (ret)
            return ret;

        if (preferred_lba >= bg.start_block + bg.off_data_region) {
            u64 bit = preferred_lba - bg.start_block - bg.off_data_region;

            cetrafs_sb_alloc_lock(sb);
            ret = cetrafs_bitmap_try_alloc_exact(sb, bg.start_block + bg.off_data_bmap,
                                                 bg.off_data_region - bg.off_data_bmap, bg.data_block_count, bit,
                                                 /*sync=*/false);
            if (ret == 0) {
                cetrafs_bg_adjust_free_blocks(sb, bg_id, -1);
                cetrafs_sb_note_bmap_alloc(sb, bg_id);
            }
            cetrafs_sb_alloc_unlock(sb);

            if (ret == 0) {
                *out_lba = preferred_lba;
                cetrafs_shadow_set(sb, *out_lba, 1, "alloc_near_exact");
                ctrace("BLKALLOC lba=%llu bg=%u from=%pS\n", (unsigned long long) *out_lba, bg_id,
                       __builtin_return_address(0));
                return 0;
            }
            if (ret != -ENOSPC)
                return ret; /* a real I/O error, not just "miss" -- don't paper over it */
        }
    }

    return cetrafs_alloc_data_block(sb, bg_id, out_lba);
}

/*
 * Allocate 'count' CONTIGUOUS data blocks from BG #bg_id, or -ENOSPC if
 * no free run that long exists there. The defrag target allocator
 *: all-or-nothing by design -- a partial run would just
 * recreate the fragmentation being healed. Scans for the run under the
 * node-local alloc mutex and sets every bit before releasing it, so a
 * concurrent local allocation can't bite a hole in the middle of the
 * claimed run. sync=false like every own-BG bitmap write (this node is
 * the BG's only writer; durability comes at the caller's own boundary).
 */
/*
 * Claim up to 'max' blocks running CONSECUTIVELY from 'start_lba',
 * stopping at the first one already taken. Returns how many were
 * claimed (0 is normal and not an error).
 *
 * This exists because cetrafs_alloc_data_run() must NOT be used on the
 * allocation hot path: it searches for a free run by testing the bitmap
 * one bit at a time from bit 0, so a 512 MiB Block Group costs up to
 * 131,072 iterations per call -- and on a volume with no free run that
 * long it pays all of them and then fails. It is the defrag target
 * allocator, sized for occasional use.
 *
 * Extending from a block we have just allocated needs no search at all:
 * test-and-set the next LBAs and stop when one is taken. Cost is
 * proportional to what we actually get, not to the size of the group.
 */
u32 cetrafs_alloc_run_after(struct super_block *sb, u32 bg_id, u64 start_lba, u32 max)
{
    struct cetrafs_bg_geom bg;
    u64 bmap_lba, bmap_blocks, first_bit;
    u32 got = 0;

    if (!max || cetrafs_sb_is_fenced(sb))
        return 0;
    if (cetrafs_read_bg_geom(sb, bg_id, &bg))
        return 0;
    if (cetrafs_alloc_check_owned(sb, bg_id, &bg))
        return 0;
    if (start_lba < bg.start_block + bg.off_data_region)
        return 0;

    bmap_lba = bg.start_block + bg.off_data_bmap;
    bmap_blocks = bg.off_data_region - bg.off_data_bmap;
    first_bit = start_lba - bg.start_block - bg.off_data_region;

    cetrafs_sb_alloc_lock(sb);
    while (got < max && first_bit + got < bg.data_block_count) {
        if (cetrafs_bitmap_try_alloc_exact(sb, bmap_lba, bmap_blocks, bg.data_block_count, first_bit + got,
                                           /*sync=*/false))
            break;
        got++;
    }
    if (got) {
        cetrafs_bg_adjust_free_blocks(sb, bg_id, -(s64) got);
        cetrafs_sb_note_bmap_alloc(sb, bg_id);
        cetrafs_shadow_set(sb, start_lba, got, "alloc_run_after");
    }
    cetrafs_sb_alloc_unlock(sb);

    return got;
}

int cetrafs_alloc_data_run(struct super_block *sb, u32 bg_id, u64 count, u64 *out_lba)
{
    return cetrafs_alloc_data_run_resv(sb, bg_id, count, out_lba, NULL);
}

/*
 * As above, but when 'span' is given it is PUBLISHED on the reservation
 * list inside the same alloc_mutex section that sets the bits. The two
 * becoming visible atomically (w.r.t. the scrub's free, which rechecks
 * the list under the same mutex) is the whole point: publish-after-
 * return left a window in which the run was bitmap-set, referenced by
 * nothing and covered by nothing, and a loaded full-gate run watched
 * the scrub walk off with the first 322 blocks of a live defrag
 * destination -- fsck then said "referenced by an inode but marked
 * FREE" about the finished move (2026-10-29, rule 5: a block must be
 * protected at the moment it becomes stealable).
 */
int cetrafs_alloc_data_run_resv(struct super_block *sb, u32 bg_id, u64 count, u64 *out_lba,
                                struct cetrafs_resv_span *span)
{
    struct cetrafs_bg_geom bg;
    u64 bmap_lba, bmap_blocks, bit, run = 0, run_start = 0, b;
    bool found = false;
    int ret;

    if (!count)
        return -EINVAL;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;

    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;
    ret = cetrafs_alloc_check_owned(sb, bg_id, &bg);
    if (ret)
        return ret;
    if (count > bg.data_block_count)
        return -ENOSPC;

    bmap_lba = bg.start_block + bg.off_data_bmap;
    bmap_blocks = bg.off_data_region - bg.off_data_bmap;

    cetrafs_sb_alloc_lock(sb);

    for (bit = 0; bit < bg.data_block_count && !found; bit++) {
        bool set = false;

        ret = cetrafs_bitmap_test_bit(sb, bmap_lba, bmap_blocks, bit, &set);
        if (ret)
            goto out_unlock;

        if (set) {
            run = 0;
        } else {
            if (run == 0)
                run_start = bit;
            if (++run >= count)
                found = true;
        }
    }

    if (!found) {
        ret = -ENOSPC;
        goto out_unlock;
    }

    for (b = 0; b < count; b++) {
        ret = cetrafs_bitmap_try_alloc_exact(sb, bmap_lba, bmap_blocks, bg.data_block_count, run_start + b,
                                             /*sync=*/false);
        if (ret) {
            /* can't happen while we hold the alloc mutex (sole local
             * allocator, sole owner of the BG) -- but if it somehow
             * does, roll back what we took and fail loudly. */
            pr_err("defrag run alloc: bit %llu of a scanned-free run was taken?!\n",
                   (unsigned long long) (run_start + b));
            while (b--)
                cetrafs_bitmap_free_bit(sb, bmap_lba, bmap_blocks, run_start + b, false);
            ret = -ENOSPC;
            goto out_unlock;
        }
    }

    cetrafs_bg_adjust_free_blocks(sb, bg_id, -(s64) count);
    cetrafs_sb_note_bmap_alloc(sb, bg_id);
    *out_lba = bg.start_block + bg.off_data_region + run_start;
    cetrafs_shadow_set(sb, *out_lba, count, "alloc_data_run(defrag)");
    if (span)
        cetrafs_resv_publish(sb, span, *out_lba, (u32) min_t(u64, count, U32_MAX));
    ctrace("BLKRUNALLOC lba=%llu count=%llu bg=%u resv=%d from=%pS\n", (unsigned long long) *out_lba,
           (unsigned long long) count, bg_id, span ? 1 : 0, __builtin_return_address(0));
    ret = 0;

out_unlock:
    cetrafs_sb_alloc_unlock(sb);
    return ret;
}

/*
 * Resolve which BG owns a given absolute data-block LBA, by scanning the
 * BG table and checking each BG's own start_block/data_block_count
 * (the real ground truth mkfs writes per BG, not a global bg_size_blocks
 * arithmetic shortcut -- even though today mkfs always makes every BG a
 * uniform size, nothing here should assume that won't change). O(B)
 * per call; fine for B in the tens this project targets today, and each
 * BG descriptor block stays hot in the buffer cache after the first
 * touch.
 */
/*
 * TEST ONLY (alloc_shadow=1): seed the in-core allocation shadow from the
 * on-disk data bitmaps, so a mount mid-test does not restart the shadow
 * EMPTY -- an empty shadow makes every free of a pre-mount allocation
 * scream FREE-OF-UNTRACKED, and (worse) it is blind to a double
 * allocation whose first owner allocated before the mount. Mount-time
 * cost only, and only when the shadow is armed.
 */
void cetrafs_shadow_seed(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 bg_count, bg_id;

    if (!cetrafs_shadow_active(sb) || !raw_sb)
        return;
    bg_count = le32_to_cpu(raw_sb->block_group_count);
    for (bg_id = 0; bg_id < bg_count; bg_id++) {
        struct cetrafs_bg_geom bg;
        u64 blk, bit = 0;

        if (cetrafs_read_bg_geom(sb, bg_id, &bg))
            continue;
        for (blk = 0; blk < bg.off_data_region - bg.off_data_bmap; blk++) {
            struct buffer_head *bh = sb_bread(sb, bg.start_block + bg.off_data_bmap + blk);
            u64 i;

            if (!bh)
                break;
            for (i = 0; i < CETRAFS_BLOCK_SIZE * 8 && bit < bg.data_block_count; i++, bit++)
                if (bh->b_data[i >> 3] & (1 << (i & 7)))
                    cetrafs_shadow_set(sb, bg.start_block + bg.off_data_region + bit, 1, "seed");
            brelse(bh);
        }
    }
}

static int cetrafs_bg_id_for_lba(struct super_block *sb, u64 lba, u32 *out_bg_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 bg_count, bg_id;

    if (!raw_sb)
        return -EINVAL;

    bg_count = le32_to_cpu(raw_sb->block_group_count);

    /*
     * Block Groups start at uniform offsets, so the one covering an LBA
     * is arithmetic -- compute it and VERIFY, instead of scanning.
     *
     * The scan below reads (and CRC32Cs) every BG descriptor in the
     * volume. On the 2 TB deployment LUN that is 2047 descriptors, and
     * it was measured at 1.3-2.7 MILLISECONDS per call by
     * function_graph -- on the free path, several times per 4 KiB
     * write. Random 4 KiB writes into preallocated space ran at 48 IOPS
     * against 1558 for the same writes into already-allocated space:
     * same device, same everything, 32x apart, and this was the gap
     *. docs/PERFORMANCE.md invariant 1 says a single CRC
     * per owned BG per block saturates a core; this did the whole
     * table.
     *
     * The fallback stays for anything the arithmetic cannot predict (a
     * short last BG, a layout that is not uniform): correct, just slow,
     * and it should never run.
     */
    {
        u64 regions_start = le64_to_cpu(raw_sb->bg_regions_start);
        u64 span = le64_to_cpu(raw_sb->bg_size_blocks);

        if (span && lba >= regions_start) {
            u64 cand = (lba - regions_start) / span;

            if (cand < bg_count) {
                struct cetrafs_bg_geom bg;

                if (cetrafs_read_bg_geom(sb, (u32) cand, &bg) == 0) {
                    u64 ds = bg.start_block + bg.off_data_region;

                    if (lba >= ds && lba < ds + bg.data_block_count) {
                        *out_bg_id = (u32) cand;
                        return 0;
                    }
                }
            }
        }
    }

    for (bg_id = 0; bg_id < bg_count; bg_id++) {
        struct cetrafs_bg_geom bg;
        u64 data_start, data_end;
        int ret = cetrafs_read_bg_geom(sb, bg_id, &bg);

        if (ret)
            return ret;

        data_start = bg.start_block + bg.off_data_region;
        data_end = data_start + bg.data_block_count;

        if (lba >= data_start && lba < data_end) {
            *out_bg_id = bg_id;
            return 0;
        }
    }

    return -EINVAL;
}

/*
 * Which ZG owns the BG that absolute LBA 'lba' lives in -- journal.c
 * needs this to know whose journal a given metadata
 * block write belongs to. Thin wrapper around cetrafs_bg_id_for_lba()
 * plus the BG descriptor's own owner_zg field, exposed since both of
 * those stay static/private to this file otherwise.
 */
int cetrafs_bg_owner_zg_for_lba(struct super_block *sb, u64 lba, u32 *out_zg_id)
{
    struct cetrafs_bg_geom bg;
    u32 bg_id;
    int ret;

    ret = cetrafs_bg_id_for_lba(sb, lba, &bg_id);
    if (ret)
        return ret;

    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;

    *out_zg_id = bg.owner_zg;
    return 0;
}

/* Is bit #bit of the same kind of bitmap currently set? */
static int cetrafs_bitmap_test_bit(struct super_block *sb, u64 bmap_lba, u64 nblocks, u64 bit, bool *out_set)
{
    u64 blk = bit / CETRAFS_BITS_PER_BLOCK;
    u32 bit_in_block = bit % CETRAFS_BITS_PER_BLOCK;
    u32 byte = bit_in_block / 8;
    u32 bit_in_byte = bit_in_block % 8;
    struct buffer_head *bh;

    if (blk >= nblocks)
        return -EINVAL;

    bh = sb_bread(sb, bmap_lba + blk);
    if (!bh)
        return -EIO;

    *out_set = (*((const u8 *) bh->b_data + byte) & (1u << bit_in_byte)) != 0;
    brelse(bh);
    return 0;
}

/*
 * Release a contiguous extent of data blocks back to its owning BG's data
 * bitmap -- which BG that is gets resolved from the LBA itself
 * (cetrafs_bg_id_for_lba()) rather than taken on faith from the caller.
 * An extent never crosses a BG (allocation is strictly per-BG), so one
 * resolution covers the whole range; a range that would cross is a
 * caller bug and is rejected loudly.
 *
 * Delegated frees: a node must NEVER touch the bitmap/counters
 * of a BG whose owning ZG belongs to a different node. Freeing is the
 * path that used to violate the "only the owner writes a BG's state"
 * model -- any node can unlink a file whose blocks live in someone
 * else's ZG, and the resulting unsynchronized cross-node RMW of the
 * bitmap block could silently revert the owner's concurrent allocations
 * (double-allocating those blocks to a second file later: hard, silent
 * corruption). So: blocks in a ZG this node owns (or any ZG, on a volume
 * with no cluster mutex -- the mount gate already guarantees single-node
 * there) are freed directly; blocks in anyone else's (or an unowned) ZG
 * are instead appended to that ZG's on-disk pending-free queue
 * (zonegroup.c, under the cluster mutex), for its owner to apply to its
 * own bitmaps on its next heartbeat tick / at claim time.
 */
/*
 * Is inode number 'ino' (1-based) currently ALLOCATED in the global inode
 * bitmap? The scrub needs this because cetrafs_free_inode() clears only the
 * bitmap bit and leaves the stale record (extents and all) in place -- so a
 * freed inode's record still "references" the very blocks a delete leaked.
 * Walking only allocated inodes is what lets the scrub see those blocks as
 * unreferenced and reclaim them.
 */
/*
 * Birth re-verify (dir.c, after the newborn record's first write): is the
 * bit this create allocated STILL set, read fresh off the device? A
 * PEER's orphan scrub can free a mid-birth number -- its verdict read
 * the previous incarnation's dead record, and our birth registry is
 * node-local so it cannot see our gestation. Detecting the theft here
 * and failing the create LOUDLY is the correctness bar's requirement
 * for a race we cannot yet exclude cross-node; silently proceeding is
 * how two files end up sharing one inode (2026-10-29, single-node
 * variant, closed by the registry + the conditioned free).
 */
int cetrafs_alloc_inode_still_owned(struct super_block *sb, u64 ino, bool *out_set)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 bit, blk;
    u32 bit_in_block, byte, bit_in_byte;
    struct buffer_head *bh;

    *out_set = false;
    if (!raw_sb || !ino || ino > le32_to_cpu(raw_sb->inodes_count))
        return -EINVAL;
    bit = ino - 1;
    blk = bit / CETRAFS_BITS_PER_BLOCK;
    bit_in_block = bit % CETRAFS_BITS_PER_BLOCK;
    byte = bit_in_block / 8;
    bit_in_byte = bit_in_block % 8;
    if (blk >= le64_to_cpu(raw_sb->inode_bmap_blocks))
        return -EINVAL;
    bh = cetrafs_bread_uncached_retry(sb, le64_to_cpu(raw_sb->inode_bmap_start) + blk);
    if (!bh)
        return -EIO;
    *out_set = (*((const u8 *) bh->b_data + byte) & (1u << bit_in_byte)) != 0;
    brelse(bh);
    return 0;
}

int cetrafs_inode_is_allocated(struct super_block *sb, u64 ino, bool *out_set)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);

    if (!raw_sb || !ino || ino > le32_to_cpu(raw_sb->inodes_count)) {
        *out_set = false;
        return 0;
    }
    return cetrafs_bitmap_test_bit(sb, le64_to_cpu(raw_sb->inode_bmap_start), le64_to_cpu(raw_sb->inode_bmap_blocks),
                                   ino - 1, out_set);
}

/*
 * Make this node's allocation bits durable.
 *
 * Called at every durability boundary BEFORE the write that publishes a
 * reference to the newly allocated blocks -- the close-time record
 * stamp, fsync, sync_fs. Without it the reference reaches the device
 * while the allocation does not, and a node that dies in between leaves
 * blocks referenced by an inode but reading FREE to everyone, including
 * the allocator that hands them out next (see cetrafs_sb_info's
 * bmap_alloc_dirty for the full account).
 *
 * Costs one bitmap write per BG allocated from since the last boundary,
 * NOT one per block: the per-block synchronous bitmap write is exactly
 * the cost PERFORMANCE.md forbids, and this is why the allocator can go
 * on using sync=false.
 */
static int cetrafs_sync_one_block(struct super_block *sb, u64 lba)
{
    struct buffer_head *bh = sb_find_get_block(sb, lba);
    int ret = 0;

    /* find, not read: a block we never cached cannot be dirty, and
     * reading it in just to discover that would turn a flush into I/O
     * over the whole bitmap. */
    if (bh) {
        if (buffer_dirty(bh))
            ret = sync_dirty_buffer(bh);
        brelse(bh);
    }
    return ret;
}

int cetrafs_alloc_flush_bitmaps(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 bg_count, bg_id;
    int ret = 0;

    if (!raw_sb)
        return 0;
    bg_count = le32_to_cpu(raw_sb->block_group_count);

    for (bg_id = 0; bg_id < bg_count; bg_id++) {
        struct cetrafs_bg_geom bg;
        u64 b, nblocks;
        int r;

        if (!cetrafs_sb_take_bmap_alloc_dirty(sb, bg_id))
            continue;
        if (cetrafs_read_bg_geom(sb, bg_id, &bg) != 0)
            continue;

        nblocks = bg.off_data_region - bg.off_data_bmap;
        for (b = 0; b < nblocks; b++) {
            r = cetrafs_sync_one_block(sb, bg.start_block + bg.off_data_bmap + b);
            if (r && !ret)
                ret = r;
        }
        cond_resched();
    }
    return ret;
}

/*
 * A BG's data-region and data-bitmap LBA ranges, for the background scrub
 * (scrub.c): it reads the bitmap blocks directly to find allocated bits and
 * cross-checks them against the referenced-block set it builds from the
 * inode table. Plain geometry, no bitmap access of its own.
 */
int cetrafs_bg_data_layout(struct super_block *sb,
                           u32 bg_id,
                           u64 *out_data_start,
                           u64 *out_data_count,
                           u64 *out_bmap_lba,
                           u64 *out_bmap_blocks)
{
    struct cetrafs_bg_geom bg;
    int ret = cetrafs_read_bg_geom(sb, bg_id, &bg);

    if (ret)
        return ret;
    if (out_data_start)
        *out_data_start = bg.start_block + bg.off_data_region;
    if (out_data_count)
        *out_data_count = bg.data_block_count;
    if (out_bmap_lba)
        *out_bmap_lba = bg.start_block + bg.off_data_bmap;
    if (out_bmap_blocks)
        *out_bmap_blocks = bg.off_data_region - bg.off_data_bmap;
    return 0;
}

/* Extents dropped because a live owner's pending-free queue was full:
 * space leaked on purpose, reclaimed by the scrub or fsck -r. Never a
 * caller-visible error -- see the -ENOSPC branch below for what
 * reporting it cost. */
static atomic64_t cetrafs_foreign_free_leaks = ATOMIC64_INIT(0);

u64 cetrafs_foreign_free_leak_count(void)
{
    return (u64) atomic64_read(&cetrafs_foreign_free_leaks);
}

static int __cetrafs_free_data_extent(struct super_block *sb, u64 lba, u32 count, bool unless_reserved);

int cetrafs_free_data_extent(struct super_block *sb, u64 lba, u32 count)
{
    return __cetrafs_free_data_extent(sb, lba, count, false);
}

/*
 * The scrub's free: identical, except the reservation list is rechecked
 * UNDER alloc_mutex before any bit is cleared. The scrub's own check at
 * decision time is only a fast path -- between it and this free, a
 * defrag can allocate-and-publish a destination run over these very
 * bits (both sides of that now happen under this same mutex), and
 * freeing them then is the referenced-but-FREE corruption the full-gate
 * run produced. Owner paths keep the plain variant: the reservation
 * DROP deliberately frees blocks its own span still covers.
 */
int cetrafs_free_data_extent_unless_reserved(struct super_block *sb, u64 lba, u32 count)
{
    return __cetrafs_free_data_extent(sb, lba, count, true);
}

static int __cetrafs_free_data_extent(struct super_block *sb, u64 lba, u32 count, bool unless_reserved)
{
    struct cetrafs_bg_geom bg;
    u64 data_start, bit, b, freed = 0;
    u32 bg_id;
    int ret;

    if (!count)
        return 0;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced */

    ret = cetrafs_bg_id_for_lba(sb, lba, &bg_id);
    if (ret) {
        pr_err_ratelimited("free: extent [%llu +%u): no BG for the LBA (%d) -- leaked\n", (unsigned long long) lba,
                           count, ret);
        return ret;
    }

    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret) {
        pr_err_ratelimited("free: extent [%llu +%u): BG %u geometry unreadable (%d) -- leaked\n",
                           (unsigned long long) lba, count, bg_id, ret);
        return ret;
    }

    data_start = bg.start_block + bg.off_data_region;
    if (lba + count > data_start + bg.data_block_count) {
        pr_err("free extent [%llu +%u) crosses out of BG %u -- refusing\n", (unsigned long long) lba, count, bg_id);
        return -EINVAL;
    }

    /*
     * A block in a ZG this node does NOT own must never be freed
     * directly: that is an unsynchronized cross-node read-modify-write
     * of the owner's bitmap and counters, which is exactly how blocks
     * get double-allocated. It goes on the owner's
     * pending-free queue instead.
     *
     * The guard is "can this volume have more than one node at a time?",
     * which is now exactly "does the device have atomic CAW?" -- the
     * same condition fs.c's mount gate enforces. A volume without it
     * admits only a single mounter, so there is no foreign owner to
     * queue for and the direct free is correct (this is also what keeps
     * the loop harness on the fast path).
     */
    if (cetrafs_sb_caw_available(sb) || cetrafs_pf_force_foreign) {
        if (cetrafs_pf_force_foreign || !cetrafs_sb_zg_owned_cached(sb, bg.owner_zg)) {
            ret = cetrafs_zg_queue_foreign_free(sb, bg.owner_zg, lba, count);
            ctrace("BLKQUEUE lba=%llu count=%u zg=%u ret=%d from=%pS\n", (unsigned long long) lba, count,
                   (unsigned int) bg.owner_zg, ret, __builtin_return_address(0));
            /*
             * -EAGAIN: the queue was full and the owner had gone stale, so
             * queue_foreign_free() reclaimed the ZG for us. It is ours now
             * -- fall through to the direct free below.
             *
             * -ENOSPC: the queue was full and the owner is ALIVE, so the
             * extent was deliberately LEAKED (logged, reclaimed later by
             * the scrub or fsck -r). That is a bounded, recoverable loss
             * of SPACE -- it is not a failure of the caller's operation,
             * and it must never be reported as one. Returning it failed
             * the guest's I/O on a punch-hole: qemu latched
             * "I/O status: nospace" and Proxmox paused the VM, while the
             * volume had 2 TB free. A caller asked us to
             * stop referencing these blocks and we did; whether the
             * owner got to reuse them yet is our problem, not theirs.
             */
            if (ret == -ENOSPC) {
                atomic64_inc(&cetrafs_foreign_free_leaks);
                return 0;
            }
            if (ret != -EAGAIN)
                return ret;
        }
    }

    bit = lba - data_start;

    /*
     * Test each bit before clearing it, and count only the ones that
     * were actually set -- the same way cetrafs_apply_pending_free()
     * does, and for a reason the direct path needs just as badly.
     *
     * Clearing an already-clear bit changes nothing, but crediting the
     * free count for it does: the bitmap stays right while the cached
     * counter drifts upward by one per double-freed block. That counter
     * is what statfs reports and what cetrafs_alloc_pick_bg() uses to
     * choose where to write, so the filesystem starts claiming space it
     * does not have -- and the drift is invisible, because the only
     * cross-check that existed compared the ZG aggregate against the sum
     * of the BG counters, i.e. two cached numbers against each other.
     * (fsck now compares each BG's counter against its own bitmap too.)
     *
     * A bit that was already free also means something freed this extent
     * twice, which is worth saying out loud rather than absorbing.
     */
    cetrafs_sb_alloc_lock(sb);
    for (b = 0; b < count; b++) {
        bool set = false;

        if (unless_reserved && cetrafs_resv_covers(sb, lba + b))
            continue; /* a live reservation claimed it since the caller decided -- not ours to free */

        ret = cetrafs_bitmap_test_bit(sb, bg.start_block + bg.off_data_bmap, bg.off_data_region - bg.off_data_bmap,
                                      bit + b, &set);
        if (ret)
            break;
        if (!set) {
            pr_warn_ratelimited("free: block %llu was already free (double free of extent [%llu +%u))\n",
                                (unsigned long long) (lba + b), (unsigned long long) lba, count);
            continue;
        }

        ret = cetrafs_bitmap_free_bit(sb, bg.start_block + bg.off_data_bmap, bg.off_data_region - bg.off_data_bmap,
                                      bit + b, /*sync=*/false);
        if (ret)
            break;
        cetrafs_shadow_clear(sb, lba + b, 1, "free_data_extent");
        freed++;
    }
    if (freed)
        cetrafs_bg_adjust_free_blocks(sb, bg_id, (s64) freed);
    cetrafs_sb_alloc_unlock(sb);

    /*
     * Say so if it went wrong. Every caller of this function ignores the
     * return value -- deliberately, matching the convention that a
     * free-path failure must not fail the operation that triggered it --
     * which means an error here would otherwise be a completely silent
     * block leak. The queue path on the other side of this function
     * already logs its own failure loudly; this half did not.
     */
    if (ret)
        pr_err("free: extent [%llu +%u) failed after %llu block(s): %d -- those blocks are leaked\n",
               (unsigned long long) lba, count, (unsigned long long) freed, ret);

    ctrace("BLKFREE lba=%llu count=%u freed=%llu ret=%d from=%pS\n", (unsigned long long) lba, count,
           (unsigned long long) freed, ret, __builtin_return_address(0));
    return ret;
}

/*
 * Apply one pending-free queue entry to this node's OWN bitmaps -- the
 * drain-side half of the delegation above, called by zonegroup.c for a
 * ZG this node owns. Idempotent by construction: each block's bit is
 * tested first and only a genuinely-set bit is cleared and counted, so
 * a crash between applying and consuming the queue entry just means the
 * next drain re-applies it as a no-op instead of double-incrementing
 * the free counters. expect_zg guards against a corrupted/garbage queue
 * entry naming a block outside the queue's own ZG.
 */
int cetrafs_apply_pending_free(struct super_block *sb, u64 lba, u32 count, u32 expect_zg)
{
    struct cetrafs_bg_geom bg;
    u64 data_start, bit, b, freed = 0;
    u32 bg_id;
    int ret;


    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced */

    ret = cetrafs_bg_id_for_lba(sb, lba, &bg_id);
    if (ret)
        return ret;

    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;

    if (bg.owner_zg != expect_zg) {
        pr_err("pending free [%llu +%u) names BG %u (ZG %u), but came from ZG %u's queue -- skipping\n",
               (unsigned long long) lba, count, bg_id, bg.owner_zg, expect_zg);
        return -EINVAL;
    }

    data_start = bg.start_block + bg.off_data_region;
    if (lba + count > data_start + bg.data_block_count) {
        pr_err("pending free [%llu +%u) crosses out of BG %u -- skipping\n", (unsigned long long) lba, count, bg_id);
        return -EINVAL;
    }

    bit = lba - data_start;

    cetrafs_sb_alloc_lock(sb);
    for (b = 0; b < count; b++) {
        bool set = false;

        ret = cetrafs_bitmap_test_bit(sb, bg.start_block + bg.off_data_bmap, bg.off_data_region - bg.off_data_bmap,
                                      bit + b, &set);
        if (ret)
            break;
        if (!set)
            continue; /* already free: re-applied entry, or double-queued -- skip the count too */

        ret = cetrafs_bitmap_free_bit(sb, bg.start_block + bg.off_data_bmap, bg.off_data_region - bg.off_data_bmap,
                                      bit + b, /*sync=*/false);
        if (ret)
            break;
        cetrafs_shadow_clear(sb, lba + b, 1, "free_data_extent");
        freed++;
    }
    if (freed)
        cetrafs_bg_adjust_free_blocks(sb, bg_id, (s64) freed);
    cetrafs_sb_alloc_unlock(sb);

    ctrace("BLKAPPLY lba=%llu count=%u freed=%llu zg=%u\n", (unsigned long long) lba, count, (unsigned long long) freed,
           expect_zg);
    return ret;
}

/* Count free inodes in the global inode bitmap, for statfs. */
int cetrafs_count_free_inodes(struct super_block *sb, u64 *out_free)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    long free;

    if (!raw_sb)
        return -EINVAL;

    free = cetrafs_bitmap_count_free(sb, le64_to_cpu(raw_sb->inode_bmap_start), le64_to_cpu(raw_sb->inode_bmap_blocks),
                                     le32_to_cpu(raw_sb->inodes_count));
    if (free < 0)
        return (int) free;

    *out_free = (u64) free;
    return 0;
}

/*
 * Report BG #bg_id's total and free data block counts, for statfs. Reads
 * the cached free_data_blocks straight off the BG descriptor (one block
 * read) instead of scanning the whole data bitmap, now that
 * cetrafs_alloc_data_block()/cetrafs_free_data_block() keep it in sync.
 */
/*
 * Recompute a Block Group's cached free-block count from its own data
 * bitmap, and correct the descriptor if the two disagree.
 *
 * Every free-space number this filesystem uses at runtime is a CACHE:
 * seeded once (by mkfs, or by one scan at mount for inodes) and
 * maintained purely by increment and decrement from then on. Nothing
 * ever recomputed one from the bitmap that is the actual truth, so an
 * unclean crash -- which loses whatever deltas had accrued but not yet
 * been applied -- left it permanently wrong. Permanently matters here:
 * `statfs` keeps reporting the wrong figure for the life of the volume,
 * and cetrafs_alloc_pick_bg() CHOOSES which Block Group to write into
 * on these numbers. P16 found the sharp end of it -- a Zone Group whose
 * aggregate had drifted to 0 was skipped by every node's claim
 * preference, so nobody ever claimed it, so nobody ever discovered the
 * number was wrong, and the space was lost to the whole cluster.
 *
 * Reconciling is cheap and bounded: a 1 GiB BG's bitmap is 8 blocks.
 * The caller decides WHEN (see cetrafs_zg_reconcile_free_counts()), and
 * the answer is only trustworthy at a moment when this node provably
 * owns the Block Group and no peer can be mutating its bitmap.
 *
 * *out_delta receives (truth - cached) so the caller can correct the
 * owning Zone Group's aggregate without scanning it a second time.
 */
int cetrafs_bg_reconcile_free_count(struct super_block *sb, u32 bg_id, s64 *out_delta)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct cetrafs_bg_geom bg;
    u64 bmap_lba, bmap_blocks;
    long truth;
    s64 delta;
    int ret;

    if (out_delta)
        *out_delta = 0;
    if (!raw_sb)
        return -EINVAL;

    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;

    bmap_lba = bg.start_block + bg.off_data_bmap;
    bmap_blocks = bg.off_data_region - bg.off_data_bmap;
    truth = cetrafs_bitmap_count_free(sb, bmap_lba, bmap_blocks, bg.data_block_count);
    if (truth < 0)
        return (int) truth;

    delta = (s64) truth - (s64) bg.free_data_blocks;
    if (delta)
        /* Loud: this is a real inconsistency being repaired, not routine
         * bookkeeping, and the size of the drift is the only evidence
         * left of what the crash cost. */
        pr_warn("BG %u: cached free_data_blocks=%llu but its bitmap says %ld -- correcting (drift %lld)\n", bg_id,
                bg.free_data_blocks, truth, delta);

    /*
     * Written as a compare-and-swap that also ADVANCES the ownership
     * epoch (reconcile_seq) -- even when the count itself needs no
     * correction. Reconcile runs exactly when ownership enters this
     * node (see the caller), and advancing the epoch is what
     * invalidates every delta the PREVIOUS owner may still have
     * accrued but not applied: its late apply then sees a foreign
     * epoch and drops, instead of double counting a recount that
     * already includes its durable effects. See
     * cetrafs_bg_count_mutate(); the v0x0004 change there retired the
     * cached read-modify-write this used to share with the adjust
     * path, which left a dirty buffer that background writeback could
     * land on top of a NEW owner's reconcile at any moment.
     */
    {
        struct cetrafs_bg_count_ctx ctx = {.absolute = true, .value = (s64) truth, .bg_id = bg_id};

        /* Seeded/record form for the same reason as the apply path below
         * (one sector CAW, cache left warm and correct) -- unseeded here:
         * reconcile runs at ownership transfer, where the cache is being
         * repopulated anyway. */
        ret = cetrafs_cas_record_seeded(sb, cetrafs_sb_bg_desc_lba(sb, bg_id), NULL, 0, cetrafs_bg_count_mutate, &ctx);
        if (ret)
            return ret;
        /* Deltas accrued from here on belong to this fresh epoch. */
        cetrafs_sb_set_bg_epoch(sb, bg_id, ctx.out_seq);
    }

    if (out_delta)
        *out_delta = delta;
    return 0;
}

/*
 * One descriptor read answering both questions the mount-time scan
 * asks: how much capacity this Block Group has, and which Zone Group
 * owns it.
 *
 * The owner is what makes per-Block-Group ownership possible
 * (docs/internal/BG-OWNERSHIP-DESIGN.md). Recording it once at mount is
 * what keeps the answer free afterwards: "do I own this Block Group"
 * becomes a bit test, with no device read on a path that runs tens of
 * thousands of times a second. Combined with the capacity read rather
 * than added beside it, so mount still makes exactly one pass.
 */
/* Claim one unowned Block Group into zg_id: the CAS mutate. */
struct cetrafs_bg_claim_ctx {
    u32 zg_id;
    u32 bg_id;
};

static int cetrafs_bg_claim_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_bg_claim_ctx *ctx = priv;
    cetrafs_block_group_t *bg = (cetrafs_block_group_t *) image;

    /* Re-read inside the swap. Between the scan that picked this Block
     * Group and this callback, a peer may have claimed it -- the whole
     * point of doing this as one compare-and-swap rather than a
     * read-then-write. Refusing here is how the loser of that race
     * finds out, and it leaves the record exactly as the winner wrote
     * it. */
    if (cetrafs_le16(bg->owner_zg) != CETRAFS_BG_OWNER_FREE)
        return -EAGAIN;

    bg->owner_zg = cetrafs_cpu_to_le16((u16) ctx->zg_id);
    /* Same normalise-then-checksum as cetrafs_bg_count_mutate(): the
     * in-sector tail past the real fields is zero by construction, and
     * cetrafs_bg_image_crc() rests on that. */
    memset((u8 *) image + offsetof(cetrafs_block_group_t, pad), 0, len - offsetof(cetrafs_block_group_t, pad));
    bg->checksum = 0;
    bg->checksum = cetrafs_cpu_to_le64(cetrafs_bg_image_crc(image, len));
    return 0;
}

/*
 * Find a Block Group nobody owns and claim it into one of this node's
 * Zone Groups.
 *
 * Called only when every Block Group this node already owns is full,
 * so the scan over the Block Group table is paid once per exhaustion,
 * not per block -- the same budget rule that keeps
 * cetrafs_alloc_pick_bg()'s own scan rare (PERFORMANCE.md rule 1).
 *
 * The claim is ONE compare-and-swap on the Block Group's own record,
 * the same primitive used for a Zone Group claim, an inode, or a file
 * lock -- the record's live fields end at byte 68 and its checksum sits
 * at 52, so the whole thing is inside one 512-byte sector. Two nodes
 * reaching for the same free Block Group resolve to exactly one
 * winner; the loser gets -EAGAIN from the mutate and tries the next
 * one.
 */
/*
 * TEST-ONLY. Claim with a blind write instead of a compare-and-swap.
 *
 * The negative control for the claim: with this set, two claimers that
 * both saw the Block Group free both "win", both roll its capacity
 * into their Zone Group's aggregate, and fsck reports the aggregate as
 * double-counted. Without a way to turn the swap off, "the swap is
 * what excludes them" is an assertion nobody has measured
 * (tests/README.md).
 */
bool cetrafs_bg_claim_blind;
module_param_named(bg_claim_blind, cetrafs_bg_claim_blind, bool, 0644);
MODULE_PARM_DESC(bg_claim_blind, "test-only: claim a free Block Group with a blind write, not a compare-and-swap");

extern bool cetrafs_bg_release_skip_empty_check;

/* Hand one Block Group back: the CAS mutate. */
struct cetrafs_bg_release_ctx {
    u32 zg_id;
};

static int cetrafs_bg_release_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_bg_release_ctx *ctx = priv;
    cetrafs_block_group_t *bg = (cetrafs_block_group_t *) image;

    /*
     * Both conditions re-checked INSIDE the swap, against the image the
     * device is about to compare.
     *
     * Still ours: if the Zone Group was reclaimed from under us the
     * release is not ours to make.
     *
     * Still empty: this is the one that matters. Releasing is the
     * dangerous direction -- a Block Group handed back while anything
     * lives in it gets allocated over by whoever takes it next -- so
     * the emptiness is confirmed here, not merely at the caller's scan
     * (rule 6: a cached read feeding a DESTRUCTIVE decision; an older
     * free count reads MORE free than reality, which is exactly the
     * wrong direction).
     */
    (void) len;
    if (cetrafs_le16(bg->owner_zg) != ctx->zg_id)
        return -EAGAIN;
    if (cetrafs_le64(bg->free_data_blocks) != cetrafs_le64(bg->data_block_count) &&
        !cetrafs_bg_release_skip_empty_check)
        return -EAGAIN;

    bg->owner_zg = cetrafs_cpu_to_le16((u16) CETRAFS_BG_OWNER_FREE);
    memset((u8 *) image + offsetof(cetrafs_block_group_t, pad), 0, len - offsetof(cetrafs_block_group_t, pad));
    bg->checksum = 0;
    bg->checksum = cetrafs_cpu_to_le64(cetrafs_bg_image_crc(image, len));
    return 0;
}

/*
 * Hand back every Block Group of zg_id that has gone completely empty,
 * keeping any that still holds data.
 *
 * This is the hoarding fix. cetrafs_zg_release_surplus() gives back a
 * Zone Group only when ALL of it is empty, so a node with two used
 * Block Groups out of a hundred gives back nothing and its peers see a
 * full volume. Same rule -- only what is provably empty -- one level
 * down.
 *
 * The node keeps the Zone Group and keeps allocating from it, so the
 * window this opens is its OWN allocator taking a block between the
 * emptiness check and the swap. That is same-node, and it is closed by
 * clearing the Block Group from owned_bgs BEFORE looking: the allocator
 * consults nothing else, so from that moment it cannot pick this Block
 * Group. If the release then fails, the bit goes back.
 */
/*
 * TEST-ONLY. Hand a Block Group back without confirming it is empty.
 *
 * The negative control for the one rule this whole path rests on. With
 * it set, a Block Group holding live data is released, somebody else
 * claims it and allocates over the data -- which is exactly the
 * outcome the emptiness check exists to prevent, and until it can be
 * produced on demand, "only what is provably empty" is an assertion
 * nobody has measured.
 */
bool cetrafs_bg_release_skip_empty_check;
module_param_named(bg_release_skip_empty_check, cetrafs_bg_release_skip_empty_check, bool, 0644);
MODULE_PARM_DESC(bg_release_skip_empty_check, "test-only: hand back a Block Group without checking it is empty");

int cetrafs_bg_release_empty(struct super_block *sb, u32 zg_id, u32 *out_released)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 b, nbg, released = 0;

    if (!raw_sb)
        return -EINVAL;
    nbg = le32_to_cpu(raw_sb->block_group_count);

    for (b = 0; b < nbg; b++) {
        struct cetrafs_bg_release_ctx ctx = {.zg_id = zg_id};
        u64 total = 0, free = 0;
        int ret;

        if (cetrafs_sb_bg_owner(sb, b) != zg_id)
            continue;
        if (!cetrafs_sb_bg_is_ours(sb, b))
            continue;

        /*
         * Cheap pre-check BEFORE draining: skip any Block Group whose
         * cached count already says it holds data.
         *
         * Draining clears the owned bit, so between the drain below and
         * the undrain further down this node does not own this Block
         * Group -- and on a volume with only one, it owns NOTHING. That
         * window spans a free-count flush, a descriptor invalidate and
         * a full bitmap scan, and anything allocating inside it fails:
         * cetrafs_alloc_pick_run() walks the owned set and returns
         * -ENOSPC with the volume 99.9% free, so the online defragmenter
         * declined ("no contiguous run large enough in the zone groups
         * this node owns") on an almost empty filesystem. Every heartbeat
         * tick opened that window once per owned Block Group.
         *
         * A stale count errs the safe way: it can only make us SKIP a
         * Block Group that turned out to be empty, deferring its release
         * to a later tick. It can never make us release one that is in
         * use -- the authoritative bitmap scan below still decides that,
         * and still runs under the drain.
         */
        if (!cetrafs_bg_release_skip_empty_check) {
            struct cetrafs_bg_geom pre;

            if (cetrafs_read_bg_geom(sb, b, &pre) == 0 && pre.free_data_blocks != pre.data_block_count)
                continue; /* obviously in use -- never take it out of reach */
        }

        /* Take it out of the allocator's reach first, then look. The
         * other order leaves a window in which this node allocates into
         * a Block Group it is in the middle of giving away. */
        cetrafs_sb_drain_bg(sb, b);

        /* Our own accrued delta has to reach the descriptor before its
         * free count can be believed -- otherwise "empty" is a count
         * that predates this node's own frees. */
        cetrafs_flush_dirty_free_counts(sb);
        cetrafs_bg_invalidate_cache(sb, b);

        if (cetrafs_bg_data_block_stats(sb, b, &total, &free) != 0 || total == 0 ||
            (free != total && !cetrafs_bg_release_skip_empty_check)) {
            cetrafs_sb_undrain_bg(sb, b); /* still in use -- keep it */
            continue;
        }

        ret = cetrafs_cas_record(sb, cetrafs_sb_bg_desc_lba(sb, b), cetrafs_bg_release_mutate, &ctx);
        if (ret) {
            cetrafs_sb_undrain_bg(sb, b);
            continue; /* somebody changed it under us; leave it alone */
        }

        cetrafs_bg_invalidate_cache(sb, b);
        cetrafs_sb_set_bg_owner(sb, b, CETRAFS_BG_OWNER_FREE);
        /* BOTH counter moves go by immediate CAS, debit before credit.
         * The pool write is cluster-visible the moment it lands, so
         * pairing it with a LAZY local accrual let every peer's statfs
         * see one half of the move until this node's next durability
         * boundary -- a df dip/bump of a whole Block Group, caught by
         * the cross-node xattrs scenario (2026-10-29). Claim and
         * release are heartbeat-paced; one CAS each is nothing. The
         * debit-first order keeps any crash window UNDERSTATING. */
        if (cetrafs_zg_apply_free_delta(sb, zg_id, -(s64) total))
            cetrafs_zg_adjust_free_blocks(sb, zg_id, -(s64) total); /* lazy fallback: never lose the move */
        if (cetrafs_zg_adjust_pool_blocks(sb, b, (s64) total))
            pr_warn("BG %u: released but its pool shard credit failed -- df will understate until fsck\n", b);
        released++;
        pr_info("BG %u handed back from ZG %u (empty, %llu blocks)\n", b, zg_id, (unsigned long long) total);
    }

    if (out_released)
        *out_released = released;
    return 0;
}

int cetrafs_bg_claim_free(struct super_block *sb, u32 zg_id, u32 *out_bg_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 b, nbg;

    if (!raw_sb)
        return -EINVAL;
    nbg = le32_to_cpu(raw_sb->block_group_count);

    for (b = 0; b < nbg; b++) {
        struct cetrafs_bg_claim_ctx ctx = {.zg_id = zg_id, .bg_id = b};
        struct cetrafs_bg_geom geom;
        int ret;

        /* Forced fresh: the cached copy can predate a peer's claim, and
         * a stale FREE here is exactly the read that makes two nodes
         * reach for the same Block Group (rule 1). The swap would still
         * refuse, but scanning on fresh data finds a real candidate
         * sooner. */
        cetrafs_invalidate_block(sb, cetrafs_sb_bg_desc_lba(sb, b));
        if (cetrafs_read_bg_geom(sb, b, &geom) != 0)
            continue;
        if (geom.owner_zg != CETRAFS_BG_OWNER_FREE)
            continue;

        if (cetrafs_bg_claim_blind) {
            /* test-only: read, decide, write -- no exclusion at all */
            struct buffer_head *wbh = sb_bread(sb, cetrafs_sb_bg_desc_lba(sb, b));

            if (!wbh)
                continue;
            /* Through the buffer-update protocol, not a bare
             * mark_buffer_dirty(): this knob exists to remove the
             * COMPARE-AND-SWAP, not to break buffer handling as well --
             * a control that injects two faults at once cannot say
             * which one it measured. image/source_invariants.sh
             * enforces the protocol and caught exactly that here. */
            cetrafs_bh_begin_update(wbh);
            cetrafs_bg_claim_mutate(wbh->b_data, CETRAFS_BLOCK_SIZE, &ctx);
            cetrafs_bh_end_update(wbh);
            sync_dirty_buffer(wbh);
            brelse(wbh);
            ret = 0;
        } else {
            ret = cetrafs_cas_record(sb, cetrafs_sb_bg_desc_lba(sb, b), cetrafs_bg_claim_mutate, &ctx);
        }
        if (ret == -EAGAIN)
            continue; /* a peer got there first */
        if (ret)
            return ret;

        /* The descriptor just changed owner, so anything holding the
         * old one must not serve it -- see
         * cetrafs_bg_adjust_free_blocks(), which reads owner_zg from
         * the cache on the allocation path. */
        cetrafs_bg_invalidate_cache(sb, b);
        cetrafs_sb_set_bg_owner(sb, b, zg_id);

        /*
         * The Zone Group just gained this Block Group's free space, and
         * its aggregate has to say so -- fsck cross-checks "a Zone
         * Group's aggregate equals the sum over its Block Groups", and
         * the allocator ranks Zone Groups by it. Read fresh: the
         * descriptor was just invalidated above precisely because the
         * cached copy is the pre-claim one.
         */
        {
            u64 total = 0, free = 0;

            if (cetrafs_bg_data_block_stats(sb, b, &total, &free) == 0 && free) {
                /* Debit the pool BEFORE crediting the aggregate, both by
                 * immediate CAS -- see the release path for why a lazy
                 * accrual here made peers' statfs dip by this whole
                 * Block Group, and why debit-first keeps a crash window
                 * understating rather than inventing space. */
                if (cetrafs_zg_adjust_pool_blocks(sb, b, -(s64) free))
                    pr_warn("BG %u: claimed but its pool shard debit failed -- df will overstate until fsck\n", b);
                if (cetrafs_zg_apply_free_delta(sb, zg_id, (s64) free))
                    cetrafs_zg_adjust_free_blocks(sb, zg_id, (s64) free); /* lazy fallback: never lose the move */
            }
        }

        pr_info("BG %u claimed into ZG %u (was owned by nobody, %llu blocks free)\n", b, zg_id, (unsigned long long) 0);
        if (out_bg_id)
            *out_bg_id = b;
        return 0;
    }
    return -ENOSPC;
}

int cetrafs_bg_mount_info(struct super_block *sb, u32 bg_id, u64 *out_total, u32 *out_owner)
{
    struct cetrafs_bg_geom bg;
    int ret = cetrafs_read_bg_geom(sb, bg_id, &bg);

    if (ret)
        return ret;
    if (out_total)
        *out_total = bg.data_block_count;
    if (out_owner)
        *out_owner = bg.owner_zg;
    return 0;
}

int cetrafs_bg_data_block_stats(struct super_block *sb, u32 bg_id, u64 *out_total, u64 *out_free)
{
    struct cetrafs_bg_geom bg;
    s64 free;
    int ret;

    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;

    /* Include this node's own accrued-but-unapplied delta (v0x0004: the
     * on-disk count no longer carries it between durability boundaries),
     * so the owner's own statfs and cetrafs_alloc_pick_bg() ranking see
     * their allocations immediately, exactly as the old dirty-buffer
     * read did. Zero for every BG this node does not own. */
    free = (s64) bg.free_data_blocks + cetrafs_sb_bg_pending_delta(sb, bg_id);
    *out_total = bg.data_block_count;
    *out_free = free > 0 ? (u64) free : 0;
    return 0;
}
