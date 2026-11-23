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
#include <linux/sched/signal.h>

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
cetrafs_test_param(pf_force_foreign, cetrafs_pf_force_foreign, bool, 0644);
MODULE_PARM_DESC(pf_force_foreign, "test-only: route every block free through the foreign pending-free queue");

/*
 * Scan a dense, byte-wise LSB-first bitmap (the same convention mkfs.c
 * writes) spanning 'nblocks' consecutive blocks starting at absolute LBA
 * 'bmap_lba', for the first clear bit among the first 'nbits' bits. On
 * success, sets that bit and writes the modified block back to disk.
 * Returns the bit index (>= 0), or a negative errno (-ENOSPC if none free,
 * -EIO on a read failure).
 */
/* TEST ONLY: the old behaviour on both sides of audit 2026-11-14 A-3 --
 * a free that clears no bit still dirties its bitmap block, and a
 * hand-back leaves a dirty bitmap block in the cache
 * (tests/kernel/release_noop_free_clean.sh). */
static bool cetrafs_noop_free_dirties;
cetrafs_test_param(noop_free_dirties, cetrafs_noop_free_dirties, bool, 0644);
MODULE_PARM_DESC(noop_free_dirties, "TEST ONLY: a no-op free dirties the bitmap and a hand-back keeps it dirty");

/* ---- bitmap sectors: each carries its own CRC (CETRAFS_BMAP_SECTOR) ---- */

atomic64_t cetrafs_bmap_crc_bad = ATOMIC64_INIT(0);


u64 cetrafs_bmap_crc_bad_count(void)
{
    return (u64) atomic64_read(&cetrafs_bmap_crc_bad);
}

u32 cetrafs_bmap_sector_crc(const void *sector)
{
    return ~crc32c(~0U, sector, CETRAFS_BMAP_CRC_LEN);
}

/* Restamp the sector of 'image' that holds bit offset 'off' -- after
 * every change to it, in the same buffer-lock bracket (or CAS image) as
 * the change, so no reader can see the two disagree. One 512-byte CRC
 * per allocated block (PERFORMANCE.md rule 1). */
void cetrafs_bmap_restamp(void *image, u64 off)
{
    const u64 i = off / (CETRAFS_BMAP_SECTOR * 8ULL);

    cetrafs_bmap_trailer(image, i)->crc =
        cpu_to_le32(cetrafs_bmap_sector_crc((const u8 *) image + i * CETRAFS_BMAP_SECTOR));
}

/* Sectors [first, first + n) of 'image' all carry their own CRC. */
bool cetrafs_bmap_sectors_ok(const void *image, u64 first, u64 n)
{
    u64 i;

    for (i = first; i < first + n; i++)
        if (le32_to_cpu(cetrafs_bmap_trailer((void *) image, i)->crc) !=
            cetrafs_bmap_sector_crc((const u8 *) image + i * CETRAFS_BMAP_SECTOR))
            return false;
    return true;
}

/* A bitmap block with no bit set, every sector carrying its CRC: what
 * mkfs and growfs lay down. */
bool cetrafs_bmap_block_empty(const void *block)
{
    u64 i;

    for (i = 0; i < CETRAFS_BMAP_SECTORS; i++)
        if (memchr_inv((const u8 *) block + i * CETRAFS_BMAP_SECTOR, 0, CETRAFS_BMAP_SECTOR - CETRAFS_BMAP_TRAILER) ||
            cetrafs_bmap_trailer((void *) block, i)->pad)
            return false; /* the trailer's G-6 stamp aside */
    return cetrafs_bmap_sectors_ok(block, 0, CETRAFS_BMAP_SECTORS);
}

/* The CAS image of an inode-bitmap unit: refuse to decide anything from
 * a damaged one. A unit is whole sectors, written in one swap, so a
 * mismatch is damage, not a tear. */
static int cetrafs_bmap_image_check(const void *image, unsigned int len, u64 lba)
{
    if (cetrafs_bmap_sectors_ok(image, 0, len / CETRAFS_BMAP_SECTOR))
        return 0;
    atomic64_inc(&cetrafs_bmap_crc_bad);
    pr_err_ratelimited("inode bitmap block %llu: a sector fails its checksum -- the unit is not used\n",
                       (unsigned long long) lba);
    return -EUCLEAN;
}

/* Every data-bitmap update ends here: held from writeback until a gated
 * flush (cetrafs_bh_end_update_held(), audit 2026-11-14 A-15), and left
 * clean when it changed nothing (A-3). */
static void cetrafs_bmap_end_update(struct super_block *sb, struct buffer_head *bh, bool changed)
{
    if (READ_ONCE(cetrafs_noop_free_dirties)) {
        cetrafs_bh_end_update(sb, bh); /* test-only: dirty, whatever changed */
        return;
    }
    set_buffer_cetra_bmap(bh);
    cetrafs_bh_end_update_held(sb, bh, changed);
}
/* The first bit offset at or after 'off' in a bitmap buffer of 'size'
 * bit offsets (whole sectors) whose bit is 'set', the trailers skipped;
 * 'size' if none. */
u64 cetrafs_bmap_next(const void *buf, u64 size, u64 off, bool set)
{
    const u64 sbits = CETRAFS_BMAP_SECTOR * 8ULL;

    while (off < size) {
        const u64 start = off / sbits * sbits, end = start + CETRAFS_BMAP_SECTOR_BITS;

        if (off < end) {
            u64 r = set ? find_next_bit_le(buf, end, off) : find_next_zero_bit_le(buf, end, off);

            if (r < end)
                return r;
        }
        off = start + sbits;
    }
    return size;
}

/* A bitmap block with every bit set: what a walk that must not miss a
 * set bit reads in place of a damaged block -- it visits every number,
 * and judges each one's record itself. */
const unsigned long cetrafs_bmap_all_set[CETRAFS_BLOCK_SIZE / sizeof(long)] = {
    [0 ... CETRAFS_BLOCK_SIZE / sizeof(long) - 1] = ~0UL};

/* Restamp every sector of a bitmap block named in 'touched' (bit i:
 * sector i): for an update that changes several bits under one hold. */
static void cetrafs_bmap_restamp_touched(void *buf, unsigned long touched)
{
    unsigned long i;

    for_each_set_bit(i, &touched, CETRAFS_BMAP_SECTORS)
        cetrafs_bmap_restamp(buf, i * CETRAFS_BMAP_SECTOR * 8ULL);
}

/* Set or clear the bit at buffer offset 'off', and restamp its sector:
 * every in-place bitmap change, under the buffer lock. */
static void cetrafs_bmap_change(struct super_block *sb, struct buffer_head *bh, u64 off, bool set)
{
    cetrafs_bh_begin_update(bh);
    if (set)
        __set_bit_le(off, bh->b_data);
    else
        __clear_bit_le(off, bh->b_data);
    cetrafs_bmap_restamp(bh->b_data, off);
    cetrafs_bmap_end_update(sb, bh, true);
}

/*
 * One bitmap block held for update while a loop changes several of its
 * bits: one lookup and one buffer-lock hold per block, not per bit
 * (audit 2026-11-14 P2). The sectors it changed are restamped, and the
 * block left clean if it changed none (A-3), when the hold moves to
 * another block or ends -- which every holder does before it sleeps on
 * I/O or lets alloc_mutex go.
 */
struct cetrafs_bmap_hold {
    struct buffer_head *bh;
    u64 blk;
    unsigned long touched; /* bit i: sector i changed */
};

static void cetrafs_bmap_hold_end(struct super_block *sb, struct cetrafs_bmap_hold *h)
{
    if (!h->bh)
        return;
    cetrafs_bmap_restamp_touched(h->bh->b_data, h->touched);
    cetrafs_bmap_end_update(sb, h->bh, h->touched != 0);
    brelse(h->bh);
    h->bh = NULL;
}

/* Hold the block of the bitmap at 'bmap_lba' (nblocks long) that has bit
 * 'bit', ending a hold on any other; *off is the bit's buffer offset.
 * *looked_up is incremented when a block had to be read. */
static int cetrafs_bmap_hold_at(struct super_block *sb, struct cetrafs_bmap_hold *h, u64 bmap_lba, u64 nblocks,
                                u64 bit, u64 *off, atomic64_t *looked_up)
{
    const u64 blk = cetrafs_bmap_blk(bit);
    int err;

    *off = cetrafs_bmap_off(bit);
    if (h->bh && h->blk == blk)
        return 0;
    cetrafs_bmap_hold_end(sb, h);
    if (blk >= nblocks)
        return -EINVAL;
    h->bh = cetrafs_bmap_bread(sb, bmap_lba + blk, 0, CETRAFS_BMAP_BUF_BITS, &err);
    if (!h->bh)
        return err;
    if (looked_up)
        atomic64_inc(looked_up);
    cetrafs_bh_begin_update(h->bh); /* held: cetrafs_bmap_hold_end() ends it */
    h->blk = blk;
    h->touched = 0;
    return 0;
}

/* Change the held bit at buffer offset 'off' to 'set'; false if it
 * already was. */
static bool cetrafs_bmap_hold_flip(struct cetrafs_bmap_hold *h, u64 off, bool set)
{
    if (test_bit_le(off, h->bh->b_data) == set)
        return false;
    if (set)
        __set_bit_le(off, h->bh->b_data);
    else
        __clear_bit_le(off, h->bh->b_data);
    __set_bit(off / (CETRAFS_BMAP_SECTOR * 8ULL), &h->touched);
    return true;
}

/*
 * The first run of at least 'minlen' free bits at or after 'from', and
 * its whole length: a run is counted to its real end, in bit numbers, so
 * it carries across sector and block boundaries and a long run is never
 * mistaken for a short one. Returns 0 with the run, -ENOSPC if there is
 * none, or the read's error. Word-wise through find_next_bit: a 1 GiB
 * Block Group is 32 KiB of bitmap.
 */
static int cetrafs_bitmap_find_run(struct super_block *sb, u64 bmap_lba, u64 nblocks, u64 nbits, u64 from,
                                   u64 minlen, u64 *out_start, u64 *out_len)
{
    u64 blk = cetrafs_bmap_blk(from), off = cetrafs_bmap_off(from), run_start = 0;
    bool in_run = false;

    for (; blk < nblocks && blk * CETRAFS_BMAP_BLOCK_BITS < nbits; blk++, off = 0) {
        struct buffer_head *bh;
        int err;

        /* A whole-bitmap walk, under alloc_mutex: on a large Block
         * Group that is seconds of CPU per pass (audit R18). */
        cond_resched();
        bh = cetrafs_bmap_bread_scan(sb, bmap_lba + blk, off, CETRAFS_BMAP_BUF_BITS, &err);
        if (!bh && err == -EUCLEAN) {
            in_run = false; /* damaged: no run is found in it, nor across it */
            continue;
        }
        if (!bh)
            return err;
        for (;;) {
            u64 end, stop;

            if (!in_run) {
                off = cetrafs_bmap_next(bh->b_data, CETRAFS_BMAP_BUF_BITS, off, false);
                if (off >= CETRAFS_BMAP_BUF_BITS)
                    break; /* no free bit left in this block */
                run_start = cetrafs_bmap_bit(blk, off);
                if (run_start >= nbits) {
                    brelse(bh);
                    return -ENOSPC;
                }
                in_run = true;
            }
            /* The run ends at the next set bit or the bitmap's tail;
             * free to the end of the block, it runs on into the next. */
            end = cetrafs_bmap_next(bh->b_data, CETRAFS_BMAP_BUF_BITS, off, true);
            stop = min(end < CETRAFS_BMAP_BUF_BITS ? cetrafs_bmap_bit(blk, end) : (blk + 1) * CETRAFS_BMAP_BLOCK_BITS,
                       nbits);
            if (end >= CETRAFS_BMAP_BUF_BITS && stop < nbits)
                break;
            if (stop - run_start >= minlen) {
                brelse(bh);
                *out_start = run_start;
                *out_len = stop - run_start;
                return 0;
            }
            in_run = false;
            if (stop >= nbits) {
                brelse(bh);
                return -ENOSPC;
            }
            off = end;
        }
        brelse(bh);
    }
    return -ENOSPC;
}

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

    for (blk = 0; blk < nblocks && blk * CETRAFS_BMAP_BLOCK_BITS < nbits; blk++) {
        struct buffer_head *bh;
        u64 off, idx;
        int err;

        /* A whole-bitmap walk, under alloc_mutex: on a large Block
         * Group that is seconds of CPU per pass (audit R18). */
        cond_resched();
        bh = cetrafs_bmap_bread_scan(sb, bmap_lba + blk, 0, CETRAFS_BMAP_BUF_BITS, &err);
        if (!bh && err == -EUCLEAN)
            continue; /* damaged: a bit it calls free may not be -- never handed out */
        if (!bh)
            return err;
        off = cetrafs_bmap_next(bh->b_data, CETRAFS_BMAP_BUF_BITS, 0, false);
        idx = off < CETRAFS_BMAP_BUF_BITS ? cetrafs_bmap_bit(blk, off) : nbits;
        if (idx < nbits) {
            /* Buffer lock across the modification -- see
             * cetrafs_bitmap_free_bit(). Note sync_dirty_buffer() takes
             * the lock itself, so it must come after the update, never
             * inside it. */
            cetrafs_bmap_change(sb, bh, off, true);
            if (sync) /* no caller passes true today */
                (void) cetrafs_sync_buffer(sb, bh);
            brelse(bh);
            return (long) idx;
        }
        brelse(bh);
    }
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
 * is the same O(bits) walk alloc_bit does; a run is counted in bit
 * numbers, so it carries across sector and block boundaries.
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
    u64 start, len;
    int err;

    if (run_min <= 1)
        return cetrafs_bitmap_alloc_bit(sb, bmap_lba, nblocks, nbits, sync);
    err = cetrafs_bitmap_find_run(sb, bmap_lba, nblocks, nbits, 0, run_min, &start, &len);
    /* Allocate the run's FIRST bit via the exact-claim helper (it
     * re-reads the bit's own block; the run's head can't have been taken
     * meanwhile -- callers hold the node-local alloc mutex, and this node
     * is the BG's only allocator). Its error is the real reason:
     * collapsing everything to -ENOSPC once made a device read error
     * read as "no space left" with gigabytes free. */
    if (!err)
        err = cetrafs_bitmap_try_alloc_exact(sb, bmap_lba, nblocks, nbits, start, sync);
    return err ? err : (long) start;
}

/* Clear bit 'bit' in the same kind of bitmap described above. Same
 * 'sync' reasoning as cetrafs_bitmap_alloc_bit() above. */
static int cetrafs_bitmap_free_bit(struct super_block *sb, u64 bmap_lba, u64 nblocks, u64 bit, bool sync)
{
    const u64 blk = cetrafs_bmap_blk(bit), off = cetrafs_bmap_off(bit);
    struct buffer_head *bh;
    int err;

    if (blk >= nblocks)
        return -EINVAL;

    bh = cetrafs_bmap_bread(sb, bmap_lba + blk, off, off + 1, &err);
    if (!bh)
        return err;

    /* Buffer lock across the modification, same protocol as every
     * other in-place update: without it a forced-fresh reader can clear
     * uptodate between the bit write and the mark-dirty and re-read the
     * old sector straight over it, losing the bit -- the lost-update
     * half of the hazard that cost 12 of 292 directory entries. The
     * sector's checksum is restamped inside the same bracket. */
    cetrafs_bmap_change(sb, bh, off, false);
    if (sync) /* no caller passes true today */
        (void) cetrafs_sync_buffer(sb, bh);
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
    const u64 blk = cetrafs_bmap_blk(bit), off = cetrafs_bmap_off(bit);
    struct buffer_head *bh;
    int err;

    if (bit >= nbits || blk >= nblocks)
        return -ENOSPC;

    bh = cetrafs_bmap_bread(sb, bmap_lba + blk, off, off + 1, &err);
    if (!bh)
        return err;

    if (test_bit_le(off, bh->b_data)) {
        brelse(bh);
        return -ENOSPC; /* already taken -- caller falls back to first-fit */
    }
    cetrafs_bmap_change(sb, bh, off, true);
    if (sync) /* no caller passes true today */
        (void) cetrafs_sync_buffer(sb, bh);
    brelse(bh);

    return 0;
}

/* The set bits among the first 'nbits' bits of a bitmap block's buffer,
 * word-wise: a 64-bit population count per word, not a test per bit
 * (audit 2026-11-14 P3). The bitmap is little-endian bit order -- bit i
 * is bit i%8 of byte i/8 -- which is bit i of the little-endian 64-bit
 * word, on any host; a sector's bits are a whole number of words. */
u64 cetrafs_bmap_weight(const void *buf, u64 nbits)
{
    u64 used = 0, i;

    BUILD_BUG_ON(CETRAFS_BMAP_SECTOR_BITS % 64);
    for (i = 0; nbits; i++) {
        const __le64 *w = (const __le64 *) ((const u8 *) buf + i * CETRAFS_BMAP_SECTOR);
        const u64 m = min_t(u64, nbits, CETRAFS_BMAP_SECTOR_BITS);
        u64 k;

        for (k = 0; k < m / 64; k++)
            used += hweight64(le64_to_cpu(w[k]));
        for (k = m / 64 * 64; k < m; k++)
            used += test_bit_le(i * CETRAFS_BMAP_SECTOR * 8ULL + k, buf);
        nbits -= m;
    }
    return used;
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

    for (blk = 0; blk < nblocks && blk * CETRAFS_BMAP_BLOCK_BITS < nbits; blk++) {
        const u64 nb = min_t(u64, CETRAFS_BMAP_BLOCK_BITS, nbits - blk * CETRAFS_BMAP_BLOCK_BITS);
        struct buffer_head *bh;
        int err;

        /* A whole-bitmap walk, under alloc_mutex: on a large Block
         * Group that is seconds of CPU per pass (audit R18). */
        cond_resched();
        bh = cetrafs_bmap_bread_scan(sb, bmap_lba + blk, 0, cetrafs_bmap_off(nb - 1) + 1, &err);
        if (!bh && err == -EUCLEAN)
            continue; /* damaged: nothing in it is handed out, so none of it counts as free */
        if (!bh)
            return err;
        /* Under the buffer lock: a CAS publish copies into this buffer
         * under it, and a weight across that copy mixes two images. */
        cetrafs_bh_read_lock(bh);
        free += nb - cetrafs_bmap_weight(bh->b_data, nb);
        cetrafs_bh_read_unlock(bh);
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
    u64 lba;        /* the unit's block, for the damage report */
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

/* The bits a CAS unit of 'len' bytes holds: whole sectors, each less its
 * trailer. */
static u64 cetrafs_bmap_unit_bits(u64 len)
{
    return len / CETRAFS_BMAP_SECTOR * CETRAFS_BMAP_SECTOR_BITS;
}

static int cetrafs_bmap_cas_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_bmap_cas_ctx *ctx = priv;
    const u64 limit = min_t(u64, ctx->valid_bits, cetrafs_bmap_unit_bits(len));
    u64 off;
    int rc;

    /* Reset per attempt: a lost CAS re-runs this on a fresh image, and
     * what the caller may act on is only what the WINNING run did. */
    ctx->cleared = false;
    rc = cetrafs_bmap_image_check(image, len, ctx->lba);
    if (rc)
        return rc;
    if (ctx->alloc) {
        u64 b;

        /* A unit is at most one block, so its bits map as a block's do. */
        off = cetrafs_bmap_next(image, (u64) len * 8, 0, false);
        b = off < (u64) len * 8 ? cetrafs_bmap_bit(0, off) : limit;
        if (b >= limit)
            return -ENOSPC; /* this region is full -- caller moves to the next */
        __set_bit_le(off, image);
        cetrafs_bmap_restamp(image, off);
        ctx->bit = b;
        return 0;
    }

    if (ctx->bit >= limit)
        return -EINVAL;
    off = cetrafs_bmap_off(ctx->bit);
    if (!test_bit_le(off, image))
        return 1; /* already free -- flattened to success by the CAS layer;
                   * the caller must read ctx->cleared, not this */
    __clear_bit_le(off, image);
    cetrafs_bmap_restamp(image, off);
    ctx->cleared = true;
    return 0;
}

/* TEST ONLY: take a bit claimed by a swap of unknown outcome as ours,
 * as before B-4 (tests/kernel/ibmap_cas_image_only.sh). */
static bool cetrafs_ibmap_trust_image;
cetrafs_test_param(ibmap_trust_image, cetrafs_ibmap_trust_image, bool, 0644);
MODULE_PARM_DESC(ibmap_trust_image, "TEST ONLY: an inode number claimed by an unknown-outcome swap is used");

static atomic64_t cetrafs_ibmap_abandoned = ATOMIC64_INIT(0);

/* TEST ONLY: an abandoned number keeps its never-written record, and a
 * virgin create claims nothing, as before review F-11. */
static bool cetrafs_ibmap_abandon_no_stamp;
cetrafs_test_param(ibmap_abandon_no_stamp, cetrafs_ibmap_abandon_no_stamp, bool, 0644);
MODULE_PARM_DESC(ibmap_abandon_no_stamp, "TEST ONLY: an abandoned inode number is not stamped dead");

u64 cetrafs_ibmap_abandoned_count(void)
{
    return (u64) atomic64_read(&cetrafs_ibmap_abandoned);
}

/* TEST ONLY: the inode allocator starts where this node id would
 * (-1: this node's own), so one host can show where a peer starts
 * (tests/kernel/ibmap_spread.sh). */
static int cetrafs_ibmap_start_as_node = -1;
cetrafs_test_param(ibmap_start_as_node, cetrafs_ibmap_start_as_node, int, 0644);
MODULE_PARM_DESC(ibmap_start_as_node, "TEST ONLY: the inode allocator starts where this node id would (-1: own)");

/* TEST ONLY: inode bitmap regions (bit n = region n, the first 64) whose
 * swap reports contention without being tried -- a region peers keep
 * winning (tests/kernel/ibmap_spread.sh). */
static unsigned long long cetrafs_ibmap_busy_regions;
cetrafs_test_param(ibmap_busy_regions, cetrafs_ibmap_busy_regions, ullong, 0644);
MODULE_PARM_DESC(ibmap_busy_regions, "TEST ONLY: bitmask of inode bitmap regions that report contention");

/* TEST ONLY: start every node at region 0 and fail a contended region
 * EBUSY, as before audit M-4 -- the control of ibmap_spread.sh. */
static bool cetrafs_ibmap_spread_off;
cetrafs_test_param(ibmap_spread_off, cetrafs_ibmap_spread_off, bool, 0644);
MODULE_PARM_DESC(ibmap_spread_off, "TEST ONLY: every node starts at region 0 and a contended region fails EBUSY");

static atomic64_t cetrafs_ibmap_busy_skips = ATOMIC64_INIT(0);

u64 cetrafs_ibmap_busy_skip_count(void)
{
    return (u64) atomic64_read(&cetrafs_ibmap_busy_skips);
}

/* Passes over every region, all of them contended, before a create gives
 * up: each contended region already lost its swap 16 times in a row, so
 * this many passes is not contention but a device that never lets a swap
 * through. */
#define CETRAFS_IBMAP_BUSY_PASSES 32

/*
 * Walk the global inode bitmap region by region, trying to claim a free
 * bit in each via CAS. Returns the global bit index, -ENOSPC when every
 * region is full, -EINTR on a fatal signal, or another error.
 *
 * Each node starts at its own region, spread over the bitmap by node id,
 * and wraps: every node starting at region 0 made every create in the
 * cluster swap the same 512 bytes, and a node that lost that region 16
 * times returned EBUSY from creat(2), which it never returns (audit
 * 2026-11-14 M-4). A region lost that many times is now passed over for
 * the next; only when a whole pass found nothing free and some region
 * contended does it wait a moment and go round again. Node 0 starts at
 * region 0, as every node did.
 */
/*
 * One swap unit of the inode bitmap: its block, its index in the block,
 * the inode its bit 0 stands for and how many of its bits are inodes.
 * Units are counted across the table's segments in inode order, so
 * every unit lies wholly inside one segment's bitmap.
 */
struct cetrafs_ibmap_unit {
    u64 lba;
    u64 r;
    u64 first_ino;
    u64 bits;
};

/* Unit 'idx' of the table 's' (n segments), or false: there is none --
 * and then *count, if asked for, is how many there are. */
static bool cetrafs_ibmap_unit(const struct cetrafs_iseg *s, u32 n, unsigned int region, u64 idx,
                               struct cetrafs_ibmap_unit *u, u64 *count)
{
    const u64 rbits = cetrafs_bmap_unit_bits(region), per_block = CETRAFS_BLOCK_SIZE / region;
    u64 total = 0;
    u32 i;

    for (i = 0; i < n; i++) {
        u64 nr = DIV_ROUND_UP(s[i].count, rbits);

        if (idx - total < nr) {
            u64 k = idx - total, blk = div64_u64(k, per_block);

            u->lba = s[i].bmap + blk;
            u->r = k - blk * per_block;
            u->first_ino = s[i].first + k * rbits;
            u->bits = min_t(u64, rbits, s[i].count - k * rbits);
            return true;
        }
        total += nr;
    }
    if (count)
        *count = total;
    return false;
}

/* The unit holding inode 'ino''s bit, and the bit in it. */
static bool cetrafs_ibmap_unit_of(const struct cetrafs_iseg *s, u32 n, unsigned int region, u64 ino,
                                  struct cetrafs_ibmap_unit *u, u64 *bit)
{
    const struct cetrafs_iseg *g = cetrafs_iseg_find(s, n, ino);
    const u64 rbits = cetrafs_bmap_unit_bits(region);
    u64 k;

    if (!g)
        return false;
    k = div64_u64(ino - g->first, rbits);
    *bit = ino - g->first - k * rbits;
    return cetrafs_ibmap_unit(g, 1, region, k, u, NULL);
}

/*
 * Bitmap block 'k' of the inode table, counted across its segments in
 * inode order: its address, the inode its bit 0 stands for, and how many
 * of its bits are inodes. false: there is no block k.
 */
bool cetrafs_ibmap_block(struct super_block *sb, u64 k, u64 *lba, u64 *first, u64 *nbits)
{
    u32 n, i;
    const struct cetrafs_iseg *s = cetrafs_sb_isegs(sb, &n);

    for (i = 0; s && i < n; i++) {
        u64 nb = cetrafs_iseg_bmap_blocks(&s[i]);

        if (k < nb) {
            *lba = s[i].bmap + k;
            *first = s[i].first + k * CETRAFS_BMAP_BLOCK_BITS;
            *nbits = min_t(u64, CETRAFS_BMAP_BLOCK_BITS, s[i].count - k * CETRAFS_BMAP_BLOCK_BITS);
            return true;
        }
        k -= nb;
    }
    return false;
}

/* Every inode-bitmap block dropped from this node's cache: the next
 * read of each is the device's. */
void cetrafs_ibmap_invalidate(struct super_block *sb)
{
    u64 k, lba, first, nbits;

    for (k = 0; cetrafs_ibmap_block(sb, k, &lba, &first, &nbits); k++) {
        cetrafs_invalidate_block(sb, lba);
        cond_resched(); /* rule 14: a walk over a disk-read count */
    }
}

static long cetrafs_inode_bitmap_cas_alloc(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    unsigned int region = cetrafs_cas_region_size(sb);
    u32 nseg;
    const struct cetrafs_iseg *seg = cetrafs_sb_isegs(sb, &nseg);
    struct cetrafs_ibmap_unit u;
    u64 nregions = 0;
    u32 nodes = max_t(u32, le32_to_cpu(raw_sb->node_table_count), 1);
    bool spread = !READ_ONCE(cetrafs_ibmap_spread_off);
    u64 first = 0, k;
    unsigned int pass;
    u32 me = 0;

    cetrafs_ibmap_unit(seg, nseg, region, U64_MAX, &u, &nregions);
    if (!nregions)
        return -EIO; /* refused at mount (cetrafs_validate_layout()) */
    if (spread) {
        int as = READ_ONCE(cetrafs_ibmap_start_as_node);

        if (as >= 0)
            me = (u32) as;
        else if (cetrafs_sb_get_node_id(sb, &me))
            me = 0;
        first = div64_u64((u64) (me % nodes) * nregions, nodes);
    }

    for (pass = 0; pass < CETRAFS_IBMAP_BUSY_PASSES; pass++) {
        bool busy = false;

        if (pass) {
            if (fatal_signal_pending(current))
                return -EINTR;
            if (cetrafs_sb_is_fenced(sb))
                return -EIO;
            usleep_range(1000 << min(pass, 4u), 2000 << min(pass, 4u));
        }
        for (k = 0; k < nregions; k++) {
            u64 idx = (first + k) % nregions;
            struct cetrafs_bmap_cas_ctx ctx = {.alloc = true};
            bool image_only;
            int ret;

            cond_resched();
            if (!cetrafs_ibmap_unit(seg, nseg, region, idx, &u, NULL))
                return -EIO; /* counted above from the same list */
            ctx.valid_bits = u.bits;
            ctx.lba = u.lba;

        again:
            if (idx < 64 && (READ_ONCE(cetrafs_ibmap_busy_regions) & (1ULL << idx)))
                ret = -EBUSY; /* test-only; see the parameter */
            else
                ret = cetrafs_cas_region_judged(sb, u.lba, u.r, cetrafs_bmap_cas_mutate, &ctx, &image_only);
            if (ret == 0 && image_only && !READ_ONCE(cetrafs_ibmap_trust_image)) {
                /* Decided from the image alone: the bit is set, but a
                 * peer that read the same region built the same bytes,
                 * and may be the one that set it -- two creators with one
                 * virgin number, two names on one record (audit
                 * 2026-11-14 B-4). Not ours to use: it stays set and the
                 * next free bit is tried. Its record, never written, is
                 * stamped dead -- unless a peer's birth claim got there
                 * first -- so the orphan pass reclaims the number; left
                 * zeros, no walk may take it as owning nothing, and every
                 * scrub cycle would free nothing (review F-11). */
                atomic64_inc(&cetrafs_ibmap_abandoned);
                if (!READ_ONCE(cetrafs_ibmap_abandon_no_stamp)) {
                    int sret = cetrafs_inode_stamp_unborn(sb, u.first_ino + ctx.bit);

                    if (sret < 0)
                        pr_warn("inode bitmap: ino=%llu could not be stamped dead (%d) -- it stays allocated until "
                                "fsck -r frees it, and the scrub frees nothing while it is unwritten\n",
                                (unsigned long long) (u.first_ino + ctx.bit), sret);
                }
                pr_warn("inode bitmap: bit %llu was claimed by a swap whose outcome was unknown -- not "
                        "taken; another number is used\n",
                        (unsigned long long) (u.first_ino + ctx.bit - 1));
                goto again;
            }
            if (ret == 0)
                return (long) (u.first_ino + ctx.bit - 1);
            if (ret == -ENOSPC || ret == -EUCLEAN)
                continue; /* region full, or damaged (never handed out) */
            if (ret == -EBUSY && spread) {
                /* Lost 16 swaps in a row: peers are creating here. */
                atomic64_inc(&cetrafs_ibmap_busy_skips);
                busy = true;
                continue;
            }
            return ret; /* a transport error, a fence, or (control) -EBUSY */
        }
        if (!busy)
            return -ENOSPC;
    }
    pr_warn_ratelimited("inode bitmap: every region with a free number lost its swap %u passes running -- "
                        "failing the create\n",
                        CETRAFS_IBMAP_BUSY_PASSES);
    return -EIO;
}

static int cetrafs_inode_bitmap_cas_free(struct super_block *sb, u64 ino)
{
    u32 nseg;
    const struct cetrafs_iseg *seg = cetrafs_sb_isegs(sb, &nseg);
    struct cetrafs_bmap_cas_ctx ctx = {.alloc = false};
    struct cetrafs_ibmap_unit u;
    int ret;

    if (!seg || !cetrafs_ibmap_unit_of(seg, nseg, cetrafs_cas_region_size(sb), ino, &u, &ctx.bit))
        return -EINVAL;
    ctx.valid_bits = u.bits;
    ctx.lba = u.lba;

    ret = cetrafs_cas_region(sb, u.lba, u.r, cetrafs_bmap_cas_mutate, &ctx);
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
        pr_debug("inode bitmap: bit %llu was already free (lost the free arbitration)\n", (unsigned long long) (ino - 1));
    /* ret > 0 ("was already free") is deliberately passed through rather
     * than flattened to success: the caller must not credit the
     * free-inode count for a bit that was already clear, or a double
     * free inflates it by one each time -- the same shape as the data
     * free path's double-credit, in the inode half. */
    return ret;
}

/* Test-only: fail the next N reclaim-claim give-backs (RELEASE or
 * BIRTH_ABORT) with -EIO, as a CAS the device refused would.
 * tests/kernel/reclaim_giveback_retry.sh. */
static unsigned int cetrafs_reclaim_giveback_fail;
cetrafs_test_param(reclaim_giveback_fail, cetrafs_reclaim_giveback_fail, uint, 0644);
MODULE_PARM_DESC(reclaim_giveback_fail, "test-only: fail the next N inode reclaim-claim give-backs with -EIO");

/*
 * Give back an inode-number reclaim claim -- a RELEASE after a reclaim,
 * or a failed create's BIRTH_ABORT. Kept, the record stays locked by
 * this node: every scrub skips it and every peer that draws the number
 * abandons it, and nothing reclaims a live node's claim. So a give-back
 * that does not land is queued for the heartbeat, never forgotten.
 * -ESTALE means the record is no longer what we claimed (reborn, or a
 * creator's birth claim moved its stamp): nothing of ours to give back.
 */
static void cetrafs_reclaim_give_back(struct super_block *sb, u64 ino, u64 generation, int mode, u64 seq)
{
    struct cetrafs_reclaim_pending p = {.ino = ino, .generation = generation, .seq = seq, .mode = mode};
    int ret;

    if (READ_ONCE(cetrafs_reclaim_giveback_fail)) {
        WRITE_ONCE(cetrafs_reclaim_giveback_fail, cetrafs_reclaim_giveback_fail - 1);
        ret = -EIO;
    } else {
        ret = cetrafs_inode_reclaim_claim(sb, ino, generation, mode, &seq);
    }
    if (ret && ret != -ESTALE) {
        pr_warn_ratelimited("inode ino=%llu: reclaim claim not given back (%d) -- queued for the heartbeat\n",
                            (unsigned long long) ino, ret);
        cetrafs_sb_reclaim_defer(sb, &p);
    }
}

/* The heartbeat's half of cetrafs_reclaim_give_back(). */
void cetrafs_alloc_retry_reclaim(struct super_block *sb)
{
    /* Up to eight per heartbeat: the whole queue is too big for a kernel
     * stack frame, and an entry that fails again goes to the back. */
    struct cetrafs_reclaim_pending pend[8];
    u32 n, i;

    n = cetrafs_sb_reclaim_take_deferred(sb, pend, ARRAY_SIZE(pend));
    for (i = 0; i < n; i++) {
        u64 seq = pend[i].seq;
        int ret;

        if (pend[i].mode == CETRAFS_RECLAIM_FINISH) {
            /* The number first, the claim after -- never the reverse
             * (cetrafs_free_inode_finish()). It requeues itself. */
            if (cetrafs_free_inode_finish(sb, pend[i].ino, pend[i].generation, seq) >= 0)
                pr_info("inode ino=%llu: an evict's number free finished by the heartbeat\n",
                        (unsigned long long) pend[i].ino);
            continue;
        }
        ret = cetrafs_inode_reclaim_claim(sb, pend[i].ino, pend[i].generation, pend[i].mode, &seq);

        if (!ret || ret == -ESTALE)
            pr_info("inode ino=%llu: reclaim claim given back by the heartbeat%s\n",
                    (unsigned long long) pend[i].ino, ret ? " (no longer ours)" : "");
        else
            cetrafs_sb_reclaim_defer(sb, &pend[i]);
    }
}

/* Allocate a free inode number (1-based) from the global inode bitmap. */
/*
 * Test-only: pause an inode allocation between taking the bit and
 * claiming the record -- the window in which the number's on-disk record
 * is still the dead previous one, which is all a peer's orphan scrub can
 * see. tests/kernel/scrub_vs_birth.sh plays that scrub inside it.
 */
static unsigned int cetrafs_birth_gap_ms;
cetrafs_test_param(birth_gap_ms, cetrafs_birth_gap_ms, uint, 0644);
MODULE_PARM_DESC(birth_gap_ms, "test-only: delay between an inode allocation's bit CAS and its birth claim");
/* Test-only: the same pause, but BEFORE the record is read -- the window
 * in which a peer's whole claim-clear-release can land and leave the
 * creator reading the RELEASED record. tests/kernel/scrub_birth_handover.sh. */
static unsigned int cetrafs_birth_read_gap_ms;
cetrafs_test_param(birth_read_gap_ms, cetrafs_birth_read_gap_ms, uint, 0644);
MODULE_PARM_DESC(birth_read_gap_ms, "test-only: delay between an inode allocation's bit CAS and its record read");
/* Test-only: fail the next N record reads of cetrafs_free_inode(), as a
 * device read error would. tests/kernel/free_inode_keeps_bit.sh. */
static unsigned int cetrafs_free_inode_read_fail;
cetrafs_test_param(free_inode_read_fail, cetrafs_free_inode_read_fail, uint, 0644);
MODULE_PARM_DESC(free_inode_read_fail, "test-only: fail the next N record reads of an inode free with -EIO");

/* Test-only: fail the next N post-claim bit checks of an inode allocation
 * with -EIO, as a device read error would, without reading.
 * tests/kernel/birth_check_error.sh. */
static unsigned int cetrafs_birth_check_fail;
cetrafs_test_param(birth_check_fail, cetrafs_birth_check_fail, uint, 0644);
MODULE_PARM_DESC(birth_check_fail, "test-only: fail the next N post-claim inode-bit checks with -EIO");

/* One forced-fresh read of an inode record, raw: see the comment at its
 * first use in cetrafs_alloc_inode() for why not cetrafs_read_raw_inode().
 * *have is whether the record verifies. */
/* TEST ONLY: the next birth claim's seed reads torn once, as a peer's
 * record write caught mid-flight would (tests/kernel/birth_seed_checked.sh). */
static bool cetrafs_birth_seed_tear_once;
cetrafs_test_param(birth_seed_tear_once, cetrafs_birth_seed_tear_once, bool, 0644);
MODULE_PARM_DESC(birth_seed_tear_once, "TEST ONLY: the next birth claim's seed reads torn once");

/* TEST ONLY: every birth finds its record held by a peer's reclaim for
 * this many ms, so the create waits in cetrafs_birth_await_release() for
 * that long (tests/kernel/birth_wait_killable.sh). Staging a real peer's
 * reclaim on the number a create will pick is not deterministic. */
static unsigned int cetrafs_birth_hold_ms;
cetrafs_test_param(birth_hold_ms, cetrafs_birth_hold_ms, uint, 0644);
MODULE_PARM_DESC(birth_hold_ms, "TEST ONLY: every birth waits as if a peer's reclaim held its record for this many ms");
/* TEST ONLY: the birth wait sleeps uninterruptibly -- the code before
 * the fatal-signal check (its negative control). */
static bool cetrafs_birth_wait_uninterruptible;
cetrafs_test_param(birth_wait_uninterruptible, cetrafs_birth_wait_uninterruptible, bool, 0644);
MODULE_PARM_DESC(birth_wait_uninterruptible, "TEST ONLY: the birth wait for a peer's reclaim ignores SIGKILL");

static int cetrafs_birth_read(struct super_block *sb, u64 ino, cetrafs_inode_t *raw, bool *have)
{
    struct buffer_head *bh;

    cetrafs_invalidate_raw_inode(sb, ino);
    bh = cetrafs_bread_retry(sb, cetrafs_inode_lba(sb, ino));
    if (!bh)
        return -EIO;
    cetrafs_bh_copy_stable(bh, raw, sizeof(*raw));
    brelse(bh);
    /* A half-born record is a claim's sector with its file sector still
     * to come: its owner arbitrates like any checksummed record's. */
    *have = cetrafs_inode_crcs_ok(raw) || cetrafs_inode_half_born(raw, ino);
    return 0;
}

/* Is inode number 'ino''s bit set ON THE DEVICE? A peer's clear never
 * reaches this node's copy of the bitmap block, and the question below
 * is precisely whether a peer cleared it. The block is never left dirty
 * here (the inode bitmap is written by CAS only), so the drop sticks. */
static int cetrafs_inode_is_allocated_fresh(struct super_block *sb, u64 ino, bool *out_set)
{
    u64 bit, lba = cetrafs_ino_bit(sb, ino, &bit);

    if (lba)
        cetrafs_invalidate_block(sb, lba);
    return cetrafs_inode_is_allocated(sb, ino, out_set);
}

/*
 * The creator took a number's bit and found a PEER's reclaim holding its
 * record. A reclaim claims the record, clears the bit, then releases --
 * so the bit this creator just set was clear, and there are two ways
 * that happens:
 *
 *   a) the reclaim had ALREADY cleared it. Nobody will clear it again:
 *      the reclaim clears once. Walking away here -- what this used to
 *      do, "the bit belongs to the reclaim" -- left the number allocated
 *      under a dead record whose extents name blocks the same scrub
 *      cycle had just freed and the allocator then handed to other
 *      files. fsck reported each as "referenced by more than one inode",
 *      and an evict of that number would have freed live data. A
 *      three-node hypervisor-storm run produced it twice in two runs.
 *   b) the reclaim judged OUR freshly set bit an orphan (the window
 *      between our bit CAS and our read) and will clear it, or has.
 *
 * The creator cannot tell the two apart while the claim is held, and
 * after the release it does not need to: the reclaim's clear has then
 * happened either way, so the bit on the device says who has it. Clear:
 * (b), the number is free and not ours. Set: the bit is ours (a), or a
 * second creator took it after the clear -- and then the birth claim the
 * caller makes next, against the released record, picks exactly one of
 * us. A reclaim claims for one bitmap CAS, so the wait is milliseconds;
 * one that never releases (its node died mid-claim) runs the budget out
 * and the number is left as before -- set, locked, for the next scrub
 * and fsck -- which is logged, not silent.
 *
 * Returns 0 with *lost false and *raw the released record to claim
 * against; 0 with *lost true to take another number; <0 on I/O error.
 */
#define CETRAFS_BIRTH_WAIT_MS 2000
static int cetrafs_birth_await_release(struct super_block *sb, u64 ino, cetrafs_inode_t *raw, u32 me, bool *lost)
{
    unsigned int waited = 0, step = 1;

    *lost = true;
    while (waited < CETRAFS_BIRTH_WAIT_MS) {
        bool have = false, set = false;
        u32 owner;
        int ret;

        /* Killable (audit L21): a create stuck behind a peer's reclaim
         * may be abandoned. The caller leaves the bit set on an error --
         * a leaked number, never one handed out twice (the scrub
         * reclaims it once its record is a dead one; one whose record
         * was never written waits for fsck -r, and stops the scrub's
         * frees until then -- see cetrafs_read_raw_inode_walk()). */
        if (READ_ONCE(cetrafs_birth_wait_uninterruptible)) {
            msleep(step); /* TEST ONLY: see the parameter */
        } else if (schedule_timeout_killable(msecs_to_jiffies(step)) && fatal_signal_pending(current)) {
            return -EINTR;
        }
        waited += step;
        step = min(step * 2, 64U);
        if (waited <= READ_ONCE(cetrafs_birth_hold_ms))
            continue; /* TEST ONLY: still held (see the parameter) */

        ret = cetrafs_birth_read(sb, ino, raw, &have);
        if (ret)
            return ret;
        if (!have)
            continue; /* torn mid-swap: read it again */
        owner = cetrafs_le32(raw->ns_lock_owner);
        if (owner != CETRAFS_NODE_ID_NONE && owner != me)
            continue; /* still held (or claimed again) */
        if (cetrafs_le32(raw->nlink) != 0)
            return 0; /* a second creator won it: not ours */
        ret = cetrafs_inode_is_allocated_fresh(sb, ino, &set);
        if (ret)
            return ret;
        if (set)
            *lost = false; /* ours, or contested by a claim the caller makes */
        return 0;
    }
    pr_warn_ratelimited("alloc_inode: ino=%llu is still held by node %u's reclaim after %u ms -- leaving the number "
                        "allocated for the next scrub\n",
                        (unsigned long long) ino, (unsigned int) cetrafs_le32(raw->ns_lock_owner), waited);
    return 0;
}

int cetrafs_alloc_inode(struct super_block *sb, u64 *out_ino)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    unsigned int attempt;
    u32 me;
    long bit;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced */
    if (!raw_sb)
        return -EINVAL;
    if (cetrafs_sb_get_node_id(sb, &me))
        return -EIO;

    /* Bounded: each lost number is one a scrub is reclaiming right now,
     * and the bitmap scan moves on past it. */
    for (attempt = 0; attempt < 8; attempt++) {
        cetrafs_inode_t raw;
        bool have = false, lost = false;
        u32 owner;
        int ret;

        bool claimed = false;
        unsigned int nofs;

        /* Take the bit and enter the birth registry as one step against
         * this node's own reclaims (cetrafs_sb_info.birth_rwsem). The
         * gate is a NOFS scope: the CAS allocates, and reclaim recursing
         * into an evict here would take the same rwsem for write. */
        nofs = cetrafs_sb_birth_gate(sb, false);
        bit = cetrafs_inode_bitmap_cas_alloc(sb);
        if (bit >= 0)
            cetrafs_sb_birth_begin(sb, (u64) bit + 1);
        cetrafs_sb_birth_ungate(sb, false, nofs);
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
         * accepted. Losing one number is a leak (fsck -r frees it); handing
         * it out twice is data loss.
         *
         * Read the record ONCE, raw. cetrafs_read_raw_inode() is wrong
         * here twice over: a VIRGIN number -- never allocated since mkfs
         * -- has an all-zero record, which fails the checksum, so that
         * reader burns its whole retry budget and then logs 'corrupted,
         * not just a torn concurrent read' for every first allocation of
         * every number. All-zero IS the expected shape of a free record;
         * only a checksummed record claiming links means the number is in
         * use. This read is also the image the birth claim below is
         * compared against.
         */
        if (cetrafs_birth_read_gap_ms)
            msleep(cetrafs_birth_read_gap_ms); /* test-only; see the parameter */
        if (cetrafs_birth_read(sb, *out_ino, &raw, &have)) {
            cetrafs_sb_birth_end(sb, *out_ino);
            *out_ino = 0;
            return -EIO; /* the bit stays set: a leak, never a second owner */
        }
        if (cetrafs_birth_gap_ms)
            msleep(cetrafs_birth_gap_ms); /* test-only; see the parameter */
        if (have && cetrafs_le32(raw.nlink) != 0) {
            pr_err(
                "alloc_inode: the bitmap handed out ino=%llu but its record still claims %u link(s) "
                "(generation=%llu mode=0%o size=%llu) -- refusing to hand a LIVE inode to a second owner\n",
                (unsigned long long) *out_ino, (unsigned int) cetrafs_le32(raw.nlink),
                (unsigned long long) cetrafs_le64(raw.generation), (unsigned int) cetrafs_le32(raw.mode),
                (unsigned long long) cetrafs_le64(raw.size));
            cetrafs_sb_birth_end(sb, *out_ino);
            *out_ino = 0;
            return -EIO;
        }

        /* A record a PEER holds the namespace lock of is mid-reclaim by
         * its scrub (nothing else locks a dead number). Whether the bit
         * we just took is still ours is only knowable once that reclaim
         * lets go -- see cetrafs_birth_await_release(). Ours (a scrub of
         * this node finished, or a create of ours failed after its
         * claim) is safe to take over -- this node's own scrub never
         * touches a number mid-birth here. */
        owner = cetrafs_le32(raw.ns_lock_owner);
        if ((have && owner != CETRAFS_NODE_ID_NONE && owner != me) || READ_ONCE(cetrafs_birth_hold_ms)) {
            ret = cetrafs_birth_await_release(sb, *out_ino, &raw, me, &lost);
            if (!ret && !lost) {
                ret = cetrafs_inode_birth_claim(sb, *out_ino, &raw, &lost);
                claimed = !ret && !lost;
            }
        } else if (!memchr_inv(&raw, 0, CETRAFS_INODE_NS_BYTES) && READ_ONCE(cetrafs_ibmap_abandon_no_stamp)) {
            ret = 0; /* TEST ONLY: unclaimed, as before F-11 */
        } else if (!memchr_inv(&raw, 0, CETRAFS_INODE_NS_BYTES)) {
            /* Virgin: claimed against the zeros, like any other birth.
             * No reclaim judges an unchecksummed record, but the
             * allocator's stamp of a number it abandoned does
             * (cetrafs_inode_stamp_unborn()), and of the two only one
             * may land (review F-11). One write per first use. */
            ret = cetrafs_inode_birth_claim(sb, *out_ino, &raw, &lost);
            claimed = !ret && !lost;
        } else {
            /* The claim's seed must be a checksummed record: the claim
             * stamps a fresh checksum over whatever it is handed, so a
             * damaged one came out VALID (audit 2026-11-06 L11). A peer's
             * write seen torn converges on a re-read; one that does not
             * is damage, and this number is not handed out. */
            int tries;

            ret = 0;
            if (READ_ONCE(cetrafs_birth_seed_tear_once) && xchg(&cetrafs_birth_seed_tear_once, false))
                raw.mode ^= cetrafs_cpu_to_le32(1); /* TEST ONLY: see the parameter */
            for (tries = 0; tries < 5 && cetrafs_inode_crc_ns(&raw) != (u32) cetrafs_le64(raw.ns_checksum); tries++) {
                usleep_range(200, 800);
                if (cetrafs_birth_read(sb, *out_ino, &raw, &have)) {
                    ret = -EIO;
                    break;
                }
            }
            if (!ret && cetrafs_inode_crc_ns(&raw) != (u32) cetrafs_le64(raw.ns_checksum)) {
                /* Kept set, like a number lost to a reclaim: a leak fsck
                 * names, and the create takes another number. */
                pr_err("alloc_inode: ino=%llu is free but its record fails its checksum -- leaving it allocated "
                       "for fsck and taking another number\n",
                       (unsigned long long) *out_ino);
                cetrafs_sb_birth_end(sb, *out_ino);
                cetrafs_sb_adjust_free_inodes(sb, -1);
                continue;
            }
            if (!ret) {
                ret = cetrafs_inode_birth_claim(sb, *out_ino, &raw, &lost);
                claimed = !ret && !lost;
            }
        }
        if (ret) {
            cetrafs_sb_birth_end(sb, *out_ino);
            *out_ino = 0;
            return ret; /* bit left set: a leaked number, freed by fsck -r if its record was never written */
        }

        /*
         * Holding the birth claim, no reclaim can claim this record any
         * more -- every one (scrub and evict alike) goes through
         * cetrafs_free_inode_if_dead()'s claim, which needs it unlocked.
         * So the bit read now is final, and it must still be set: a peer
         * reclaim can judge our freshly set bit an orphan and run its
         * whole claim-clear-release between our bit CAS and our record
         * read, and then the record we claimed is the RELEASED one --
         * the claim lands, on a number whose bit is clear and which the
         * next allocator anywhere will take as well. Give the claim back
         * and take another number.
         */
        if (claimed) {
            bool set = false;

            if (READ_ONCE(cetrafs_birth_check_fail)) {
                WRITE_ONCE(cetrafs_birth_check_fail, cetrafs_birth_check_fail - 1);
                ret = -EIO; /* test-only; see the parameter */
            } else {
                ret = cetrafs_inode_is_allocated_fresh(sb, *out_ino, &set);
            }
            if (ret) {
                /* Give the claim back. Kept, it made the number nobody's
                 * forever: bit set, record dead and locked by this node,
                 * so every scrub skipped it, while its extents still
                 * named the blocks the previous life's evict had freed
                 * -- fsck read those as shared with whichever files got
                 * them next. Released, the record is an ordinary dead
                 * one: the scrub reclaims the number if the bit is set,
                 * and if a peer cleared it the number is simply free. */
                cetrafs_reclaim_give_back(sb, *out_ino, cetrafs_le64(raw.generation), CETRAFS_RECLAIM_BIRTH_ABORT,
                                          0);
                cetrafs_sb_birth_end(sb, *out_ino);
                *out_ino = 0;
                return ret;
            }
            if (!set) {
                cetrafs_reclaim_give_back(sb, *out_ino, cetrafs_le64(raw.generation), CETRAFS_RECLAIM_BIRTH_ABORT,
                                          0);
                lost = true;
            }
        }
        if (lost) {
            /* Abandon. Whatever the bit says now is not ours to change:
             * a reclaim cleared it, or a birth claim that beat ours owns
             * it, and clearing it would clobber that arbitration. Count
             * it used -- this node set it -- and take another number. */
            pr_info_ratelimited("alloc_inode: ino=%llu is being reclaimed by a scrub -- taking another number\n",
                                (unsigned long long) *out_ino);
            cetrafs_sb_birth_end(sb, *out_ino);
            cetrafs_sb_adjust_free_inodes(sb, -1);
            continue;
        }

        /* The number stays in the birth registry (entered with the bit,
         * above) until its first name is published: until then the
         * on-disk record cannot prove this node owns it (the dead
         * previous record is still what a scanner reads), so the orphan
         * scrub keys off the registry instead. */
        cetrafs_sb_adjust_free_inodes(sb, -1);
        cetrafs_sb_ino_reborn(sb, *out_ino);
        return 0;
    }
    *out_ino = 0;
    return -EAGAIN;
}

/* Release an inode number back to the global inode bitmap. */
int cetrafs_free_inode(struct super_block *sb, u64 ino)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    bool mid_birth;
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced */
    if (cetrafs_sb_ro_refuses(sb, "an inode number free"))
        return -EROFS;
    if (!raw_sb || !ino)
        return -EINVAL;

    /* Any free ends the number's gestation: every create error path
     * funnels through here, so the birth registry cannot leak. */
    mid_birth = cetrafs_sb_birth_active(sb, ino);
    cetrafs_sb_birth_end(sb, ino);

    /*
     * Zero the record's nlink before the bit goes back. Until now a
     * freed inode's record kept whatever it last said -- the comment in
     * cetrafs_evict_inode() notes the record is never zeroed -- so
     * "does this record claim links?" could not distinguish a live
     * inode from a dead one, and nothing could check that the bitmap
     * and the record agree before handing a number out.
     *
     * And the bit goes back ONLY once the record is dead. It used to be
     * cleared whatever happened here: a record read that failed, or a
     * zeroing CAS that did, put the bit back under a record still
     * claiming links -- which the next allocator to draw it refuses with
     * -EIO (a create failing for nothing) and then keeps, as an unnamed
     * inode fsck can only call a lost name. Kept set instead, it is a
     * leak, the safe direction.
     *
     * Read raw, as the allocator does (cetrafs_birth_read()): a create
     * that failed before its record write leaves an all-zero record,
     * which is the expected shape of a never-used number, not damage.
     * cetrafs_read_raw_inode() burned its retries on it and reported it
     * as corruption -- counted, logged "run fsck", and the number marked
     * damaged; under corruption=stop, an ordinary ENOSPC mkdir stopped
     * the mount.
     */
    {
        cetrafs_inode_t raw;
        bool have = false, dead = false;

        if (cetrafs_free_inode_read_fail) {
            cetrafs_free_inode_read_fail--; /* test-only; see the parameter */
        } else if (cetrafs_birth_read(sb, ino, &raw, &have) == 0) {
            ctrace("INOFREE ino=%llu have=%d nlink_on_disk=%u size=%llu from=%pS\n", (unsigned long long) ino, have,
                   have ? (unsigned int) cetrafs_le32(raw.nlink) : 0U,
                   have ? (unsigned long long) cetrafs_le64(raw.size) : 0ULL, __builtin_return_address(0));
            if (!have) {
                /* Never written: names nothing. Anything else that does
                 * not verify cannot be judged, and keeps its bit. */
                dead = !memchr_inv(&raw, 0, sizeof(raw));
            } else if (cetrafs_le32(raw.nlink) != 0) {
                dead = cetrafs_inode_ns_zero_nlink(sb, ino, &raw) == 0;
            } else {
                dead = true;
                /* A create that failed before its record write still
                 * holds its birth claim: give it back, or every peer
                 * that later draws this number reads a foreign lock and
                 * abandons it. */
                if (mid_birth && cetrafs_le32(raw.ns_lock_owner) != CETRAFS_NODE_ID_NONE)
                    cetrafs_reclaim_give_back(sb, ino, cetrafs_le64(raw.generation), CETRAFS_RECLAIM_BIRTH_ABORT, 0);
            }
        }
        if (!dead) {
            pr_warn_ratelimited("free_inode: ino=%llu: its record could not be made dead -- leaving the number "
                                "allocated (fsck reports it)\n",
                                (unsigned long long) ino);
            return -EIO;
        }
    }

    ret = cetrafs_inode_bitmap_cas_free(sb, ino);
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
 * A mismatch returns -ESTALE and frees nothing.
 *
 * A re-read is not enough on its own, though: it said nothing about a
 * PEER whose create took the bit and has not written its record yet --
 * the birth registry that covers that window is per-node. So the
 * "re-read" is a claim CAS on the record, which a creator's own birth
 * claim excludes; see cetrafs_inode_birth_claim().
 */
int cetrafs_free_inode_if_dead(struct super_block *sb, u64 ino, u64 generation, u64 verdict_seq)
{
    u64 seq = 0;
    int ret = cetrafs_free_inode_begin(sb, ino, generation, verdict_seq, &seq);

    return ret ? ret : cetrafs_free_inode_finish(sb, ino, generation, seq);
}

/*
 * The two halves of the free, for a caller with blocks to give back in
 * between (evict). _begin() claims the dead record and checks, under the
 * claim, that the number is still allocated: 0 means this caller owns
 * the free, and the number STAYS allocated, the claim held, until
 * _finish() clears the bit and releases it -- or _abort() releases it
 * and leaves the number for the orphan scrub.
 *
 * Why the number is freed last. Evict used to free it FIRST and the
 * extents after, one by one -- for a fragmented image tens of thousands
 * of frees and seconds to minutes. In that window the record was a freed
 * slot, which the block scrub does not walk ("its stale record must NOT
 * protect blocks"), and the extents not yet freed were set and named by
 * nothing: candidates. The owner's scrub freed them, its allocator
 * reused them, and the evict's own free (or its queued one, for a
 * foreign owner) then cleared the bit under the new file (audit
 * 2026-11-06 H1; tests/kernel/scrub_vs_evict_free.sh). With the number
 * allocated and the record intact the scrub reads every extent as
 * referenced until the last free has landed.
 *
 * The claim is what arbitrates: a second evict, the orphan scrub and a
 * create all refuse a claimed record, and a claim must match the
 * namespace stamp its verdict read ('verdict_seq', the record's
 * dirent_seq), which every claim and release advances -- so a verdict
 * taken before another free of this record never acts after it. Before
 * the number goes, _finish() also empties the record of every block
 * reference (cetrafs_inode_forget_tree()): a verdict read after that
 * free finds nothing to give back. A crash with the claim held leaves
 * an allocated, dead, claimed record naming blocks some of which are
 * free: the claimant's own-claim sweep at re-attach releases it, the
 * orphan scrub then frees the number only (never blocks), and the block
 * scrub reclaims what was still set. fsck already ranks a deleted
 * record's references below any live one's and leaves the blocks only
 * it names free.
 */
int cetrafs_free_inode_begin(struct super_block *sb, u64 ino, u64 generation, u64 verdict_seq, u64 *seq)
{
    unsigned int nofs;
    bool set = false;
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    if (cetrafs_sb_ro_refuses(sb, "an inode number free"))
        return -EROFS;
    if (!ino)
        return -EINVAL;

    /* The verdict is acted on through the record itself: claim it --
     * a CAS that lands only on the dead, unlocked record of generation
     * 'generation' the verdict saw. A creator that took the bit meanwhile
     * either beat the claim (its own birth claim changed the record: ours
     * refuses) or loses to it and abandons the number. See inode.c's
     * cetrafs_inode_birth_claim(). A re-read alone could not be adjacent
     * enough to the free; only this is. */
    nofs = cetrafs_sb_birth_gate(sb, true);
    *seq = 0;
    ret = cetrafs_inode_reclaim_claim_at(sb, ino, generation, CETRAFS_RECLAIM_CLAIM, seq, verdict_seq,
                                         CETRAFS_NODE_ID_NONE);
    if (ret) {
        cetrafs_sb_birth_ungate(sb, true, nofs);
        return ret; /* reborn, locked, or unreadable: free nothing */
    }

    /* A create of THIS node took the number after our verdict read --
     * the bit we judged is its bit now. Under the gate the registry is
     * exact (cetrafs_sb_info.birth_rwsem): give the record back and free
     * nothing. Otherwise the bit, read fresh under the claim: nothing can
     * clear it while we hold the claim, so "free" means an earlier free
     * of this same file has already run -- its blocks are gone too. */
    if (cetrafs_sb_birth_active(sb, ino))
        ret = -EAGAIN;
    else if (!(ret = cetrafs_inode_is_allocated_fresh(sb, ino, &set)) && !set)
        ret = 1;
    if (ret)
        cetrafs_reclaim_give_back(sb, ino, generation, CETRAFS_RECLAIM_RELEASE, *seq);
    cetrafs_sb_birth_ungate(sb, true, nofs);
    return ret;
}

/* Clear the bit of a number whose dead record this node holds claimed
 * (an evict's free, or a claim found at re-attach). 0 when this call
 * cleared it, 1 when it was already clear. */
int cetrafs_free_inode_number_claimed(struct super_block *sb, u64 ino)
{
    unsigned int nofs = cetrafs_sb_birth_gate(sb, true);
    int ret;

    /* The bit has been ours since the claim: no create can have taken
     * it, so the birth registry has nothing to say about it. */
    ret = cetrafs_inode_bitmap_cas_free(sb, ino);
    if (!ret)
        cetrafs_sb_adjust_free_inodes(sb, 1);
    cetrafs_sb_birth_ungate(sb, true, nofs);
    return ret > 0 ? 1 : ret;
}

/*
 * The bit, then the claim. 0 when this call cleared the bit.
 *
 * Never the claim without the bit: once blocks have been freed, a
 * released claim over a still-allocated number lets the next evict of
 * the same file -- a peer's in-core copy of it -- win the claim, find the
 * bit set and free the same blocks again, after their owner may have
 * handed them to another file. A bit that could not be cleared keeps the
 * claim and goes to the heartbeat (CETRAFS_RECLAIM_FINISH); a fenced
 * mount keeps it for the own-claim sweep at re-attach, which completes
 * the free the same way (cetrafs_lock_sweep_own_claims()).
 */
/* TEST ONLY: the next N evict number frees fail as a refused bitmap CAS
 * would (tests/kernel/evict_free_keeps_claim.sh). */
static unsigned int cetrafs_evict_number_free_fail;
cetrafs_test_param(evict_number_free_fail, cetrafs_evict_number_free_fail, uint, 0644);
MODULE_PARM_DESC(evict_number_free_fail, "TEST ONLY: fail the next N evict number frees with -EIO");

int cetrafs_free_inode_finish(struct super_block *sb, u64 ino, u64 generation, u64 seq)
{
    struct cetrafs_reclaim_pending p = {.ino = ino, .generation = generation, .seq = seq,
                                        .mode = CETRAFS_RECLAIM_FINISH};
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    /* Every block reference out of the record first, then the number:
     * after the bit is clear nothing may find blocks to free in it. */
    ret = cetrafs_inode_forget_tree(sb, ino, generation, &seq);
    if (ret == -ESTALE) {
        /* Reborn, or the claim is no longer ours: nothing of ours to
         * free, and nothing to retry -- requeued, it failed every beat. */
        pr_info("inode ino=%llu: the free is no longer this node's to finish (reborn, or its claim taken over)\n",
                (unsigned long long) ino);
        return ret;
    }
    if (ret < 0) {
        p.seq = seq;
        pr_warn_ratelimited("inode ino=%llu: its record's block references could not be dropped (%d) -- the "
                            "heartbeat finishes the free\n",
                            (unsigned long long) ino, ret);
        cetrafs_sb_reclaim_defer(sb, &p);
        return ret;
    }
    p.seq = seq;
    if (READ_ONCE(cetrafs_evict_number_free_fail)) {
        WRITE_ONCE(cetrafs_evict_number_free_fail, cetrafs_evict_number_free_fail - 1);
        ret = -EIO; /* test-only */
    } else {
        ret = cetrafs_free_inode_number_claimed(sb, ino);
    }
    if (ret < 0) {
        pr_warn_ratelimited("inode ino=%llu: blocks freed, number not (%d) -- the heartbeat finishes it\n",
                            (unsigned long long) ino, ret);
        cetrafs_sb_reclaim_defer(sb, &p);
        return ret;
    }
    cetrafs_reclaim_give_back(sb, ino, generation, CETRAFS_RECLAIM_RELEASE, seq);
    return ret;
}

/*
 * The orphan scrub's half for a free whose claimant went stale holding
 * it: 'from' has been judged stale and fenced, and its journal replayed,
 * by the caller; 'verdict_seq' is the stamp the judgement read. Take the
 * claim over and finish the free -- the number only, and the record's
 * block references dropped first: some of the blocks it names may be
 * free or another file's by now, and the rest are the block scrub's.
 * Otherwise the number and those blocks stayed allocated until the
 * claimant came back, and for good if it never did.
 */
int cetrafs_free_inode_steal(struct super_block *sb, u64 ino, u64 generation, u64 verdict_seq, u32 from)
{
    unsigned int nofs;
    bool set = false;
    u64 seq = 0;
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    nofs = cetrafs_sb_birth_gate(sb, true);
    ret = cetrafs_inode_reclaim_claim_at(sb, ino, generation, CETRAFS_RECLAIM_STEAL, &seq, verdict_seq, from);
    if (!ret) {
        /* Under a claim the bit cannot change; one read clear means the
         * claimant's own free got that far before it stopped. */
        ret = cetrafs_inode_is_allocated_fresh(sb, ino, &set);
        if (!ret && !set)
            ret = 1;
        if (ret)
            cetrafs_reclaim_give_back(sb, ino, generation, CETRAFS_RECLAIM_RELEASE, seq);
    }
    cetrafs_sb_birth_ungate(sb, true, nofs);
    return ret ? ret : cetrafs_free_inode_finish(sb, ino, generation, seq);
}

/* Give the claim back and leave the number allocated: a dead, unclaimed
 * record, which the orphan scrub frees (number only). */
void cetrafs_free_inode_abort(struct super_block *sb, u64 ino, u64 generation, u64 seq)
{
    cetrafs_reclaim_give_back(sb, ino, generation, CETRAFS_RECLAIM_RELEASE, seq);
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
    u64 length_blocks;
    u64 free_data_blocks; /* cached count, as of the last read */
    u64 reconcile_seq;    /* the count's ownership epoch, as of the last read */
    u64 free_gen;         /* the pending-free stamp (cetrafs_block_group_t.free_gen) */
    u32 owner_zg;         /* ZG this BG belongs to */
    u16 flags;            /* CETRAFS_BG_FLAG_* */
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
/*
 * A descriptor whose checksum passes still has to describe a Block Group
 * that can exist (rule 19). Its offsets AIM I/O: the allocator and the
 * bitmap flush address bitmap blocks from start_block + off_data_bmap,
 * the flush walks off_data_region - off_data_bmap of them in u32 (an
 * inverted pair wrapped to ~4 billion blocks under sync(2)), and the
 * scrub sizes its buffer from data_block_count. cetrafs.h said these
 * were "checked when read"; until now only the checksum was.
 *
 * Every field is checked against the superblock's data area, never
 * against a computed position: a grown volume's Block Groups are not
 * contiguous (cetrafs_superblock_t.bg_data_end).
 */
/* TEST ONLY: accept any in-bounds layout, as before audit 2026-11-15
 * BL-33 (tests/kernel/bg_layout_exact.sh). */
static bool cetrafs_bg_layout_any;
cetrafs_test_param(bg_layout_any, cetrafs_bg_layout_any, bool, 0644);
MODULE_PARM_DESC(bg_layout_any, "TEST ONLY: accept a Block Group descriptor whose layout is in bounds but not the computed one");

static bool cetrafs_bg_geom_sane(const cetrafs_superblock_t *raw_sb, u32 bg_id, const cetrafs_block_group_t *bg)
{
    u64 regions = le64_to_cpu(raw_sb->bg_regions_start);
    u64 data_end = le64_to_cpu(raw_sb->bg_data_end);
    u64 total = le64_to_cpu(raw_sb->total_blocks);
    u64 start = cetrafs_le64(bg->start_block);
    u64 len = cetrafs_le64(bg->length_blocks);
    u64 bmap = cetrafs_le32(bg->off_data_bmap);
    u64 region = cetrafs_le32(bg->off_data_region);
    u64 count = cetrafs_le64(bg->data_block_count);
    u32 want_bmap, want_region;
    u64 want_count;

    if (!data_end)
        data_end = regions + (u64) le32_to_cpu(raw_sb->block_group_count) * le64_to_cpu(raw_sb->bg_size_blocks);
    if (data_end > total)
        data_end = total;

    /* len is also bounded by the format's ceiling, not only by the data
     * area: a block offset inside a BG is a u32 (audit L10). */
    if (!(cetrafs_le32(bg->bg_id) == bg_id && start >= regions && len && len <= CETRAFS_MAX_BG_SIZE_BLOCKS &&
          len <= data_end - regions && start <= data_end - len && bmap >= 1 && bmap < region && region <= len &&
          count <= len - region && count <= (region - bmap) * CETRAFS_BMAP_BLOCK_BITS))
        return false;
    /*
     * ...and exactly the layout its length gives: the one definition
     * mkfs, growfs and fsck use (cetrafs_calc_bg_layout()). In bounds is
     * not enough -- a bitmap moved by a block reads the group's
     * allocations off by a block's worth of bits, and fsck refused what
     * the mount served (audit 2026-11-15 BL-33). Two divisions, beside
     * the descriptor's checksum.
     */
    cetrafs_calc_bg_layout(len, le32_to_cpu(raw_sb->data_align_blocks), &want_bmap, &want_region, &want_count);
    return READ_ONCE(cetrafs_bg_layout_any) ||
           (bmap == want_bmap && region == want_region && count == want_count);
}

/*
 * Read and check one descriptor against an EXPLICIT layout: the
 * superblock copy it is judged by and the address it lives at. The
 * mount and a live layout refresh call this with a layout that is not
 * published yet -- the published one does not know these Block Groups
 * -- and 'fresh' forces even the first read past the cache, since a
 * refresh is the first look at blocks a peer has just written.
 */
static int cetrafs_read_bg_geom_at(struct super_block *sb, const cetrafs_superblock_t *raw_sb, u32 bg_id, u64 blk,
                                   bool fresh, struct cetrafs_bg_geom *out)
{
    int attempt;

    atomic64_inc(&cetrafs_bg_geom_reads);
    if (!raw_sb || !blk)
        return -EINVAL;
    if (bg_id >= le32_to_cpu(raw_sb->block_group_count))
        return -EINVAL;

    for (attempt = 0; attempt < CETRAFS_RECORD_READ_RETRIES; attempt++) {
        const cetrafs_block_group_t *bg;
        struct buffer_head *bh;

        /* First attempt stays on the cached fast path (this is the
         * per-allocation hot path for a BG's own owner, whose cache is
         * authoritative); retries force a real re-read. */
        /* PERF(6): attempt 0 stays cached -- docs/PERFORMANCE.md */
        if (attempt > 0 || fresh)
            cetrafs_invalidate_block(sb, blk);

        bh = cetrafs_bread_retry(sb, blk);
        if (!bh)
            return -EIO;

        bg = (const cetrafs_block_group_t *) bh->b_data;
        /* Under the buffer lock, as cetrafs_read_zg(): the free count is
         * patched in place on this very buffer (audit L15). */
        cetrafs_bh_read_lock(bh);
        if (likely(!cetrafs_record_tear_injected("BG descriptor")) &&
            cetrafs_bg_crc_verify(bh->b_data) == (u32) cetrafs_le64(bg->checksum)) {
            if (!cetrafs_bg_geom_sane(raw_sb, bg_id, bg)) {
                pr_err_ratelimited("BG %u descriptor describes an impossible Block Group (start %llu len %llu "
                                   "bitmap +%u data +%u count %llu) -- refusing it (fsck)\n",
                                   bg_id, (unsigned long long) cetrafs_le64(bg->start_block),
                                   (unsigned long long) cetrafs_le64(bg->length_blocks),
                                   cetrafs_le32(bg->off_data_bmap), cetrafs_le32(bg->off_data_region),
                                   (unsigned long long) cetrafs_le64(bg->data_block_count));
                cetrafs_bh_read_unlock(bh);
                cetrafs_sb_corrupt(sb, 0);
                brelse(bh);
                return -EUCLEAN;
            }
            out->start_block = cetrafs_le64(bg->start_block);
            out->off_data_bmap = cetrafs_le32(bg->off_data_bmap);
            out->off_data_region = cetrafs_le32(bg->off_data_region);
            out->data_block_count = cetrafs_le64(bg->data_block_count);
            out->length_blocks = cetrafs_le64(bg->length_blocks);
            out->free_data_blocks = cetrafs_le64(bg->free_data_blocks);
            out->reconcile_seq = cetrafs_le64(bg->reconcile_seq);
            out->free_gen = cetrafs_le64(bg->free_gen);
            out->owner_zg = cetrafs_le16(bg->owner_zg);
            out->flags = cetrafs_le16(bg->flags);
            cetrafs_bh_read_unlock(bh);
            brelse(bh);
            return 0;
        }
        cetrafs_bh_read_unlock(bh);
        brelse(bh);

        /* Back off, like every other checksummed-record reader: a
         * mismatch here is a peer's in-flight counter write seen torn,
         * and a peer's write takes milliseconds -- so the budget is
         * cetrafs_tear_backoff()'s, the one X1 gave the block readers; the
         * fixed 100-400 us it had spent the whole budget in about a
         * millisecond (review E2). (This is the FIFTH such reader -- the
         * P5 pass that added the backoff to the inode record, node row
         * and ZG record enumerated four and missed this one, which lives
         * in alloc.c rather than with the others.) */
        if (attempt + 1 < CETRAFS_RECORD_READ_RETRIES)
            cetrafs_tear_backoff(attempt);
    }

    pr_err("BG %u failed its descriptor checksum repeatedly -- corrupted, not just a torn concurrent read\n", bg_id);
    /* Counted and marked for fsck, as an impossible geometry above is:
     * damaged metadata found on a read (ERRORS.md, kind 2). It went
     * uncounted, and nothing told the operator fsck.cetra -r rebuilds
     * it (found by tests/kernel/alloc_skips_damaged_bg.sh). */
    cetrafs_sb_corrupt(sb, 0);
    return -EUCLEAN;
}

static int cetrafs_read_bg_geom(struct super_block *sb, u32 bg_id, struct cetrafs_bg_geom *out)
{
    /* One snapshot for both: the copy the descriptor is judged by and
     * the address map are the same published layout (fs.c). */
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);

    if (!raw_sb || bg_id >= le32_to_cpu(raw_sb->block_group_count))
        return -EINVAL;
    return cetrafs_read_bg_geom_at(sb, raw_sb, bg_id, cetrafs_sb_bg_desc_lba(sb, bg_id), false, out);
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

/* TEST ONLY: the invalidate of Block Group (value - 1) fails, as a
 * descriptor read refused by the device would (audit 2026-11-14 A7;
 * tests/kernel/bg_invalidate_fail.sh). 0 = off. */
static unsigned int cetrafs_bg_invalidate_fail_bg;
cetrafs_test_param(bg_invalidate_fail_bg, cetrafs_bg_invalidate_fail_bg, uint, 0644);
MODULE_PARM_DESC(bg_invalidate_fail_bg, "TEST ONLY: 1 + the Block Group whose cache drop fails");
/* TEST ONLY: the callers ignore a failed cache drop, as before A7 --
 * the control of the same suite. */
bool cetrafs_bg_invalidate_fail_ignored;
cetrafs_test_param(bg_invalidate_fail_ignored, cetrafs_bg_invalidate_fail_ignored, bool, 0644);
MODULE_PARM_DESC(bg_invalidate_fail_ignored, "TEST ONLY: a failed Block Group cache drop is ignored");

/*
 * Returns nonzero when the bitmap blocks could NOT be dropped (their
 * place is in the descriptor, and it did not read): the cached bitmap
 * may then be an earlier look, which reads a peer's allocations as
 * free. A caller about to make the group allocatable must not.
 */
int cetrafs_bg_invalidate_cache(struct super_block *sb, u32 bg_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct cetrafs_bg_geom bg;
    u64 bmap_lba, bmap_blocks, blk;
    int ret;

    if (!raw_sb)
        return -EINVAL;

    cetrafs_invalidate_block(sb, cetrafs_sb_bg_desc_lba(sb, bg_id));

    if (unlikely(READ_ONCE(cetrafs_bg_invalidate_fail_bg) == bg_id + 1))
        return -EIO; /* test-only: see the parameter */
    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;

    bmap_lba = bg.start_block + bg.off_data_bmap;
    bmap_blocks = bg.off_data_region - bg.off_data_bmap;
    for (blk = 0; blk < bmap_blocks; blk++) {
        cond_resched();
        cetrafs_invalidate_block(sb, bmap_lba + blk);
    }

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
/* TEST ONLY: the next N adjusts find their descriptor unreadable; and
 * the old order -- a failed read returned before the delta was accrued
 * (tests/kernel/bg_adjust_read_fail.sh, its control). */
static unsigned int cetrafs_bg_adjust_read_fail;
cetrafs_test_param(bg_adjust_read_fail, cetrafs_bg_adjust_read_fail, uint, 0644);
MODULE_PARM_DESC(bg_adjust_read_fail, "TEST ONLY: the next N free-count adjusts cannot read their descriptor");
static bool cetrafs_bg_adjust_old_order;
cetrafs_test_param(bg_adjust_old_order, cetrafs_bg_adjust_old_order, bool, 0644);
MODULE_PARM_DESC(bg_adjust_old_order, "TEST ONLY: a failed descriptor read drops the delta (the old order)");

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

    /* PERF(4): accrue only -- a sync here is one device round trip per
     * allocated block (1 MiB write: 2s -> 40s). docs/PERFORMANCE.md
     *
     * FIRST, before anything that can fail: every caller has already
     * moved the bitmap and ignores this return, so a delta not accrued
     * here is lost for good -- an allocation the count never hears of
     * is a full group reading free, the state class 52 is about. It
     * used to come after the descriptor read below, and a failed read
     * dropped it. */
    {
        bool fail = false;

        if (READ_ONCE(cetrafs_bg_adjust_read_fail)) {
            WRITE_ONCE(cetrafs_bg_adjust_read_fail, cetrafs_bg_adjust_read_fail - 1);
            fail = true; /* test-only; see the parameter */
            if (READ_ONCE(cetrafs_bg_adjust_old_order))
                return -EIO; /* the old order: nothing accrued */
        }
        cetrafs_sb_accrue_bg_free(sb, bg_id, delta);

        /* The owner, for the roll-up: from the cached descriptor, or --
         * if that cannot be read -- from the in-memory map every claim
         * and release keeps, so the aggregate's half is not lost either. */
        bh = fail ? NULL : cetrafs_bread_retry(sb, cetrafs_sb_bg_desc_lba(sb, bg_id));
    }
    if (bh) {
        bg = (const cetrafs_block_group_t *) bh->b_data;
        owner_zg = cetrafs_le16(bg->owner_zg);
        brelse(bh);
    } else {
        owner_zg = cetrafs_sb_bg_owner(sb, bg_id);
        pr_warn_ratelimited("BG %u free-count adjust: descriptor unreadable -- rolling up into ZG %u from memory\n",
                            bg_id, owner_zg);
    }

    /* Nobody's Block Group has nobody's aggregate to roll into, and
     * CETRAFS_BG_OWNER_FREE as an index would run off every per-ZG
     * array. Reaching here with a free owner means this node allocated
     * from a Block Group it has not claimed, which is a bug worth
     * saying out loud rather than papering over. */
    if (owner_zg == CETRAFS_BG_OWNER_FREE) {
        /* An ALLOCATION here took blocks from space nobody owns, which a
         * peer may claim and allocate from too: what this node believes
         * it owns and what the device says disagree (kind 3,
         * docs/internal/ERRORS.md). A free into it is the separate,
         * known leak. */
        if (delta < 0)
            cetrafs_sb_fatal(sb, "BG %u: allocated from a Block Group no Zone Group owns", bg_id);
        else
            pr_err("BG %u free-count adjust: the Block Group is owned by nobody -- freed into unclaimed space\n",
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
u32 cetrafs_bg_image_crc(const void *image, unsigned int len)
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

/* The three descriptor mutators keep the fields they do not change and
 * stamp a fresh checksum: over an image that fails its own, that blesses
 * a tear or damage (inode.c's namespace mutator has the same refusal). */
/* TEST ONLY: the BG descriptor mutators restamp a descriptor that fails
 * its checksum (the negative control of tests/kernel/cas_refuses_bad_image_mutators.sh). */
static bool cetrafs_bg_cas_skip_crc;
cetrafs_test_param(bg_cas_skip_crc, cetrafs_bg_cas_skip_crc, bool, 0644);
MODULE_PARM_DESC(bg_cas_skip_crc, "TEST ONLY: the BG descriptor mutators do not refuse a descriptor failing its checksum");

static bool cetrafs_bg_image_ok(const void *image, unsigned int len)
{
    const cetrafs_block_group_t *bg = image;

    if (cetrafs_bg_image_crc(image, len) == (u32) cetrafs_le64(bg->checksum) || READ_ONCE(cetrafs_bg_cas_skip_crc))
        return true;
    pr_warn_ratelimited("BG CAS: the descriptor on the device fails its checksum -- refusing to stamp a fresh one\n");
    return false;
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
    if (!cetrafs_bg_image_ok(image, len))
        return -EUCLEAN;

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
        /* class 34: no other actor moves this count. Only the owner
         * applies deltas (a peer's frees reach it through the
         * pending-free queue, applied by the owner), and a new owner
         * reconciles under a new epoch that refuses the old one's
         * deltas above -- so no legal interleaving passes through
         * zero, and a refusal here is divergence, not a race. */
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
    bg->checksum = cetrafs_cpu_to_le64(0);
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
/* TEST ONLY: hold the copy of the free-delta CAS's seed open halfway
 * (tests/kernel/bg_seed_torn.sh), and take that copy without the buffer
 * lock as the code used to (its negative control). */
static unsigned int cetrafs_bg_seed_copy_stall_ms;
cetrafs_test_param(bg_seed_copy_stall_ms, cetrafs_bg_seed_copy_stall_ms, uint, 0644);
MODULE_PARM_DESC(bg_seed_copy_stall_ms, "TEST ONLY: pause halfway through copying the BG free-delta seed");
static bool cetrafs_bg_seed_unlocked;
cetrafs_test_param(bg_seed_unlocked, cetrafs_bg_seed_unlocked, bool, 0644);
MODULE_PARM_DESC(bg_seed_unlocked, "TEST ONLY: copy the BG free-delta seed without the buffer lock");

/* TEST ONLY: the next free-count flush pauses this long between taking
 * a Block Group's delta and its CAS -- a slow SAN's round trip, held
 * open (tests/kernel/bg_flush_inflight_count.sh). */
static unsigned int cetrafs_bg_flush_stall_ms;
cetrafs_test_param(bg_flush_stall_ms, cetrafs_bg_flush_stall_ms, uint, 0644);
MODULE_PARM_DESC(bg_flush_stall_ms, "TEST ONLY: one BG free-count flush pauses between taking its delta and its CAS");

int cetrafs_bg_apply_free_delta(struct super_block *sb, u32 bg_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct cetrafs_bg_count_ctx ctx = {.bg_id = bg_id};
    struct cetrafs_bg_geom geom;
    s64 delta;
    int ret;

    if (!raw_sb)
        return -EINVAL;
    if (bg_id >= le32_to_cpu(raw_sb->block_group_count))
        return -EINVAL;

    /* One flush of this Block Group at a time, and the count it starts
     * from read under that right: readers see that count plus the delta
     * for as long as the CAS is out (cetrafs_bg_chunk.bg_flight_gen).
     * Neither failure has taken anything: the delta stays accrued, and
     * is marked for the next flush (the caller cleared the mark). */
    ret = cetrafs_sb_bg_flush_lock(sb, bg_id);
    if (ret) {
        cetrafs_sb_accrue_bg_free(sb, bg_id, 0);
        return ret;
    }
    ret = cetrafs_read_bg_geom(sb, bg_id, &geom);
    if (ret) {
        cetrafs_sb_bg_flush_unlock(sb, bg_id);
        cetrafs_sb_accrue_bg_free(sb, bg_id, 0);
        return ret;
    }
    delta = cetrafs_sb_bg_flight_begin(sb, bg_id, (s64) geom.free_data_blocks);
    if (!delta)
        return 0;
    ctx.value = delta;
    {
        unsigned int pause = xchg(&cetrafs_bg_flush_stall_ms, 0);

        if (pause) {
            pr_info("BG %u: free-count flush of %lld in flight, pausing %u ms (test)\n", bg_id, (long long) delta,
                    pause);
            msleep(pause); /* test-only; see the parameter */
        }
    }

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
    /*
     * The seed is a SNAPSHOT, taken under the buffer lock. Handing the
     * CAS bh->b_data itself let it memcpy the live cached block while
     * another thread of this node patched it after its own landed CAS
     * (cetrafs_cache_region_after_cas(), under lock_buffer). A half-old,
     * half-new seed fails the mutator's checksum guard, the CAW is never
     * sent, and the refusal is counted as damage: a spurious
     * "corruptions:" and, under corruption=stop, a stopped node, for a
     * race inside one node (audit R15). A stale but WHOLE seed is fine:
     * it miscompares and the retry reads fresh.
     *
     * Two flushes of this descriptor (a close, an fsync, a drain) no
     * longer race here -- the flush right above serialises them -- but a
     * recount's absolute CAS (cetrafs_reconcile_locked()) still patches
     * the same buffer without it, so the locked copy stays. The torn-seed
     * suite reaches the tear by lifting the serialisation
     * (bg_flush_unserialised) along with the lock (bg_seed_unlocked).
     */
    {
        unsigned int region = cetrafs_cas_region_size(sb);
        struct buffer_head *bh = cetrafs_bread_retry(sb, cetrafs_sb_bg_desc_lba(sb, bg_id));
        u8 *seed = bh ? kmalloc(region, GFP_NOFS) : NULL;

        /* Split between the count and the checksum that covers it, so
         * the test stall can hold a tear open there. */
        if (seed)
            cetrafs_bh_snapshot(bh, seed, region, offsetof(cetrafs_block_group_t, checksum),
                                READ_ONCE(cetrafs_bg_seed_copy_stall_ms), READ_ONCE(cetrafs_bg_seed_unlocked));
        ret = cetrafs_cas_record_seeded(sb, cetrafs_sb_bg_desc_lba(sb, bg_id), seed, seed ? region : 0,
                                        cetrafs_bg_count_mutate, &ctx);
        kfree(seed);
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
        cetrafs_sb_bg_flight_end(sb, bg_id, 0);
        return 0;
    }
    if (ret < 0) {
        /* Real I/O trouble (a DROPPED stale delta is consumed inside
         * the mutator, loudly): put the delta back rather than lose real
         * accounting to a transient error -- and say so, since a delta
         * stuck in memory is invisible in every other way. */
        pr_err_ratelimited("BG %u free delta %lld could not be applied (%d) -- re-accrued for the next flush\n", bg_id,
                           (long long) delta, ret);
        cetrafs_sb_bg_flight_end(sb, bg_id, delta);
        return ret;
    }
    cetrafs_sb_bg_flight_end(sb, bg_id, 0);
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
cetrafs_test_param(alloc_force_foreign, cetrafs_alloc_force_foreign, bool, 0644);
MODULE_PARM_DESC(alloc_force_foreign, "test-only: treat every Block Group as owned by another node");

/*
 * TEST-ONLY, one-shot: sleep this many ms after the next allocation's
 * ownership check and before it takes alloc_mutex -- the window in which
 * a Block Group release can hand the chosen group away
 * (tests/kernel/alloc_vs_bg_release.sh). Cleared by the pause it causes.
 */
static unsigned int cetrafs_alloc_pause_before_lock_ms;
cetrafs_test_param(alloc_pause_before_lock_ms, cetrafs_alloc_pause_before_lock_ms, uint, 0644);
MODULE_PARM_DESC(alloc_pause_before_lock_ms, "TEST ONLY: one-shot pause between an allocation's ownership check and alloc_mutex");

/*
 * Called with alloc_mutex held, before any bit is set: has this Block
 * Group left owned_bgs since the caller chose it?
 *
 * The choice (cetrafs_alloc_pick_bg() and friends) and the ownership
 * check above both run BEFORE alloc_mutex, so they are a verdict, not a
 * guarantee. A Block Group release drains the group by clearing its
 * owned_bgs bit under this same mutex and then scans, syncs and hands it
 * back without holding it -- so an allocation that chose the group, then
 * waited for the mutex (behind a long punch, a run search, a retried
 * descriptor read, or simply preemption), used to set its bit in a group
 * already given away: the next owner read that block FREE and handed it
 * out again, and our later writeback put our bitmap block over theirs.
 *
 * Re-tested here, under the mutex the drain takes, the two are ordered:
 * either the bit lands before the drain and the release's bitmap scan
 * sees it, or the drain comes first and the allocation gets -EAGAIN and
 * chooses again. One bit test, no I/O (PERFORMANCE.md rule 1).
 * tests/kernel/alloc_vs_bg_release.sh.
 */
static bool cetrafs_alloc_bg_gone(struct super_block *sb, u32 bg_id)
{
    return !cetrafs_sb_bg_is_ours(sb, bg_id);
}

static int cetrafs_alloc_check_owned(struct super_block *sb, u32 bg_id, const struct cetrafs_bg_geom *bg)
{
    unsigned int pause = xchg(&cetrafs_alloc_pause_before_lock_ms, 0);

    if (pause)
        msleep(pause);
    if (cetrafs_alloc_force_foreign)
        goto not_ours;
    if (cetrafs_sb_zg_owned_cached(sb, bg->owner_zg))
        return 0;
    /* Released between the pick and the descriptor read: the descriptor
     * names its new owner (or none), and the group is no longer in
     * owned_bgs. That is the race the re-check under alloc_mutex answers
     * with -EAGAIN a moment later; answered -EPERM here, the write
     * failed instead of choosing again (N-23). */
    if (cetrafs_alloc_bg_gone(sb, bg_id))
        return -EAGAIN;

not_ours:
    pr_err("alloc: refusing to allocate from BG %u -- its zone group %u is not owned by this node\n", bg_id,
           bg->owner_zg);
    return -EPERM;
}

/* TEST ONLY: the next contiguous-run allocation fails its SECOND bit with
 * -EIO, as a bitmap read error would, so both the error path and the
 * give-back of the first bit run (tests/kernel/run_alloc_io_error.sh). */
static bool cetrafs_run_alloc_fail_once;
cetrafs_test_param(run_alloc_fail_once, cetrafs_run_alloc_fail_once, bool, 0644);
MODULE_PARM_DESC(run_alloc_fail_once, "TEST ONLY: fail the second bit of the next run allocation with -EIO, once");

/* TEST ONLY: the next data allocation reports ENOSPC once, which sends
 * its caller down the recount path. */
static bool cetrafs_alloc_force_enospc_once;
cetrafs_test_param(alloc_force_enospc_once, cetrafs_alloc_force_enospc_once, bool, 0644);
/* TEST ONLY: the next allocation's Block Group gets this many blocks
 * of free count it does not have, aggregate included, and then finds
 * itself full: the ENOSPC recount of tests/kernel/enospc_recount_aggregate.sh. */
static unsigned int cetrafs_alloc_inflate_once;
cetrafs_test_param(alloc_inflate_once, cetrafs_alloc_inflate_once, uint, 0644);
MODULE_PARM_DESC(alloc_inflate_once, "TEST ONLY: inflate the next allocation's group count, then fail it ENOSPC");

static bool cetrafs_alloc_test_enospc(struct super_block *sb, u32 bg_id)
{
    unsigned int n;

    if (READ_ONCE(cetrafs_alloc_force_enospc_once) && xchg(&cetrafs_alloc_force_enospc_once, false))
        return true;
    n = READ_ONCE(cetrafs_alloc_inflate_once) ? xchg(&cetrafs_alloc_inflate_once, 0) : 0;
    if (!n)
        return false;
    /* A count that lies, aggregate included, on a group then found full. */
    cetrafs_sb_alloc_lock(sb);
    cetrafs_bg_adjust_free_blocks(sb, bg_id, (s64) n);
    cetrafs_sb_alloc_unlock(sb);
    return true;
}
MODULE_PARM_DESC(alloc_force_enospc_once, "TEST ONLY: fail the next data allocation with ENOSPC, once");

/* TEST ONLY: one-shot pause between an allocation's pick of a Block
 * Group and its descriptor read (tests/kernel/alloc_bg_released_before_read.sh). */
static unsigned int cetrafs_alloc_pause_before_geom_ms;
cetrafs_test_param(alloc_pause_before_geom_ms, cetrafs_alloc_pause_before_geom_ms, uint, 0644);
MODULE_PARM_DESC(alloc_pause_before_geom_ms, "TEST ONLY: one-shot pause before an allocation reads its group's descriptor");

int cetrafs_alloc_data_block(struct super_block *sb, u32 bg_id, u64 *out_lba)
{
    struct cetrafs_bg_geom bg;
    long bit;
    int ret;

    if (unlikely(cetrafs_alloc_test_enospc(sb, bg_id)))
        return -ENOSPC; /* test-only; see the parameters */
    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced */
    if (unlikely(READ_ONCE(cetrafs_alloc_pause_before_geom_ms))) {
        unsigned int pause = xchg(&cetrafs_alloc_pause_before_geom_ms, 0);

        if (pause)
            msleep(pause); /* TEST ONLY: see the parameter */
    }

    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;
    ret = cetrafs_alloc_check_owned(sb, bg_id, &bg);
    if (ret)
        return ret;

    cetrafs_sb_alloc_lock(sb);
    if (cetrafs_alloc_bg_gone(sb, bg_id)) {
        cetrafs_sb_alloc_unlock(sb);
        return -EAGAIN;
    }
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
        if (ret == -EAGAIN) /* released since the pick: choose again, nothing to recount */
            continue;
        if (ret != -ENOSPC)
            return ret;

        if (cetrafs_bg_recount_after_enospc(sb, bg, &delta) != 0)
            return ret;
        atomic64_inc(&cetrafs_bg_recounts);
        pr_warn_ratelimited("alloc: BG %u reported free space but its bitmap is full -- recounted (delta %lld)\n", bg,
                            (long long) delta);
    }
    return ret == -EAGAIN ? -ENOSPC : ret;
}

int cetrafs_alloc_data_block_near(struct super_block *sb, u32 bg_id, u64 preferred_lba, u64 *out_lba)
{
    struct cetrafs_bg_geom bg;
    int ret;

    if (unlikely(cetrafs_alloc_test_enospc(sb, bg_id)))
        return -ENOSPC; /* test-only; see the parameters */
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
            if (cetrafs_alloc_bg_gone(sb, bg_id)) {
                cetrafs_sb_alloc_unlock(sb);
                return -EAGAIN;
            }
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
            /* -EUCLEAN: the hint's bitmap sector is damaged -- a miss
             * like a taken block; the allocator below skips the damage. */
            if (ret != -ENOSPC && ret != -EUCLEAN)
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
/* TEST ONLY: a run claim looks the bitmap block up per bit, as before --
 * the control of tests/kernel/run_claim_bmap_lookups.sh. */
static bool cetrafs_run_claim_per_bit;
cetrafs_test_param(run_claim_per_bit, cetrafs_run_claim_per_bit, bool, 0644);
MODULE_PARM_DESC(run_claim_per_bit, "TEST ONLY: a speculative run claim looks the bitmap block up per bit");
static atomic64_t cetrafs_run_claim_bmap_lookups = ATOMIC64_INIT(0);
u64 cetrafs_run_claim_bmap_lookup_count(void)
{
    return (u64) atomic64_read(&cetrafs_run_claim_bmap_lookups);
}

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
    if (cetrafs_alloc_bg_gone(sb, bg_id)) {
        cetrafs_sb_alloc_unlock(sb);
        return 0; /* best effort: no run from a group we no longer own */
    }
    if (READ_ONCE(cetrafs_run_claim_per_bit)) { /* test-only: the old per-bit claims */
        while (got < max && first_bit + got < bg.data_block_count) {
            atomic64_inc(&cetrafs_run_claim_bmap_lookups);
            if (cetrafs_bitmap_try_alloc_exact(sb, bmap_lba, bmap_blocks, bg.data_block_count, first_bit + got,
                                               /*sync=*/false))
                break;
            got++;
        }
    } else {
        /* One lookup and one buffer-lock hold per bitmap block, not one
         * lookup per bit: up to 4096 of them under alloc_mutex per run
         * (audit 2026-11-14 P2). The test and the set are under the
         * buffer lock, as cetrafs_bitmap_try_alloc_exact()'s set is;
         * nothing here sleeps on I/O while it is held. */
        struct cetrafs_bmap_hold h = {0};

        while (got < max && first_bit + got < bg.data_block_count) {
            u64 off;

            if (cetrafs_bmap_hold_at(sb, &h, bmap_lba, bmap_blocks, first_bit + got, &off,
                                     &cetrafs_run_claim_bmap_lookups))
                break; /* best effort: what was claimed stands */
            if (!cetrafs_bmap_hold_flip(&h, off, true))
                break;
            got++;
        }
        cetrafs_bmap_hold_end(sb, &h);
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
    if (cetrafs_alloc_bg_gone(sb, bg_id)) {
        ret = -EAGAIN;
        goto out_unlock;
    }

    for (bit = 0; bit < bg.data_block_count && !found; bit++) {
        bool set = false;

        if (!(bit & 4095))
            cond_resched(); /* up to 2^32 bits, under the mutex (class 13) */
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
        if (!(b & 4095))
            cond_resched(); /* class 13 */
        if (b == 1 && READ_ONCE(cetrafs_run_alloc_fail_once) && xchg(&cetrafs_run_alloc_fail_once, false))
            ret = -EIO; /* test-only; see the parameter */
        else
            ret = cetrafs_bitmap_try_alloc_exact(sb, bmap_lba, bmap_blocks, bg.data_block_count, run_start + b,
                                                 /*sync=*/false);
        if (ret) {
            int err = ret;

            /* -ENOSPC: a bit this scan found free was taken. That cannot
             * happen while we hold the alloc mutex (sole local allocator,
             * sole owner of the BG), so memory and disk disagree: stop
             * (docs/internal/ERRORS.md). Anything else is the device
             * failing the read, which is the caller's error to see as it
             * is -- it used to be stopped as the impossible case and
             * reported as ENOSPC, sending the defragmenter to look for
             * space instead of reporting a failing disk. */
            if (err == -ENOSPC) {
                cetrafs_sb_fatal(sb,
                                 "defrag run alloc: bit %llu of a scanned-free run was taken under the alloc mutex",
                                 (unsigned long long) (run_start + b));
                err = -EIO;
            }
            /* Give back what we took. A give-back that fails leaves the
             * bit set: a leak the scrub reclaims, never a block shared --
             * but it is said, not swallowed. */
            while (b--) {
                int rc;

                if (!(b & 4095))
                    cond_resched();
                rc = cetrafs_bitmap_free_bit(sb, bmap_lba, bmap_blocks, run_start + b, false);

                if (rc)
                    pr_err_ratelimited("defrag run alloc: could not give back bit %llu of BG %u (%d) -- left "
                                       "allocated for the scrub\n",
                                       (unsigned long long) (run_start + b), bg_id, rc);
            }
            ret = err;
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
        for (blk = 0; blk < bg.off_data_region - bg.off_data_bmap && bit < bg.data_block_count; blk++) {
            const u64 nb = min_t(u64, CETRAFS_BMAP_BLOCK_BITS, bg.data_block_count - bit);
            struct buffer_head *bh;
            u64 off, i;
            int err;

            cond_resched();
            bh = cetrafs_bmap_bread(sb, bg.start_block + bg.off_data_bmap + blk, 0, CETRAFS_BMAP_BUF_BITS, &err);
            if (!bh)
                break;
            cetrafs_bmap_for_each_set(bh->b_data, off, i, nb)
                cetrafs_shadow_set(sb, bg.start_block + bg.off_data_region + bit + i, 1, "seed");
            bit += nb;
            brelse(bh);
        }
    }
}

/* Descriptor reads made by cetrafs_bg_id_for_lba() after its arithmetic
 * missed: O(log BGs) per miss now, a whole table before (audit L20). */
static atomic64_t cetrafs_bg_lookup_reads = ATOMIC64_INIT(0);

u64 cetrafs_bg_lookup_reads_count(void)
{
    return (u64) atomic64_read(&cetrafs_bg_lookup_reads);
}

static int cetrafs_bg_id_for_lba_once(struct super_block *sb, u64 lba, u32 *out_bg_id)
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
     * The arithmetic misses on a grown volume: each grow leaves a hole
     * where the previous tail reserve was (cetrafs.h, bg_data_end), so
     * every Block Group past it starts later than b * bg_size_blocks
     * predicts. It also misses for an LBA in no data region at all --
     * an extent on a hostile image. Both used to fall back to a walk of
     * the whole table, one walk per freed extent (audit L20). Starts are
     * ordered (mkfs and growfs append, fsck refuses a descriptor that
     * overlaps its predecessor), so the fallback is a binary search on
     * start_block: O(log n) descriptor reads, and the answer is verified
     * against the descriptor like the arithmetic one. A hostile table
     * that is not ordered can only make the search miss, and a miss is
     * -EINVAL: the caller refuses the free, which leaks (scrub, fsck)
     * and never shares a block.
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
        if (lba < regions_start)
            return -EINVAL;
    }

    {
        u32 lo = 0, hi = bg_count; /* the answer, if any, is in [lo, hi) */
        struct cetrafs_bg_geom bg;
        u64 data_start;
        int ret;

        if (!bg_count)
            return -EINVAL;
        while (hi - lo > 1) {
            u32 mid = lo + (hi - lo) / 2;

            atomic64_inc(&cetrafs_bg_lookup_reads);
            ret = cetrafs_read_bg_geom(sb, mid, &bg);
            if (ret)
                return ret;
            if (bg.start_block <= lba)
                lo = mid;
            else
                hi = mid;
        }
        bg_id = lo;
        atomic64_inc(&cetrafs_bg_lookup_reads);
        ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
        if (ret)
            return ret;
        data_start = bg.start_block + bg.off_data_region;
        if (lba >= data_start && lba < data_start + bg.data_block_count) {
            *out_bg_id = bg_id;
            return 0;
        }
    }

    return -EINVAL;
}

/*
 * The Block Group holding 'lba', or:
 *   -EINVAL  it is in no data region -- of a layout KNOWN to be current;
 *   -EAGAIN  it lies past the end of this node's layout and this node
 *            could not learn whether a grow put it there (the
 *            superblock unreadable, refused, or bigger than our device);
 *   other    a descriptor could not be read.
 *
 * "Past the end of the layout I have" is not "outside every data
 * region" on a volume another node may have grown live: a peer can
 * publish a grow, allocate in the new space, journal a write there and
 * die, all before this node's next heartbeat. Before the refresh below,
 * a replay here skipped that entry as a bad target and parked the area
 * CLEAN over it, and a free there leaked (GROWFS-LIVE-REVIEW H1, M3).
 * A grow only ever appends past the published total_blocks, so an LBA
 * below it is answered definitively without the device; only one past
 * it costs a read of block 0, and only when the cheap lookup missed.
 * Callers that act destructively on -EINVAL must not act on -EAGAIN:
 * not knowing leaks or waits, it never drops.
 */
static int cetrafs_bg_id_for_lba(struct super_block *sb, u64 lba, u32 *out_bg_id)
{
    int ret, tries;

    for (tries = 0; tries < 4; tries++) {
        const cetrafs_superblock_t *raw_sb;
        int r;

        ret = cetrafs_bg_id_for_lba_once(sb, lba, out_bg_id);
        if (ret != -EINVAL)
            return ret;
        raw_sb = cetrafs_sb_raw(sb);
        if (!raw_sb || lba < le64_to_cpu(raw_sb->total_blocks))
            return -EINVAL; /* inside the published volume: no grow can change the answer */
        r = cetrafs_sb_layout_refresh(sb);
        if (r < 0)
            return -EAGAIN;
        if (r == 0)
            return -EINVAL; /* the layout is current, and the LBA is past its end */
        /* r == 1: a grow was published; ask again against it */
    }
    return -EAGAIN;
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

/* Is the bit at buffer offset 'off' of bitmap block 'lba' set? */
static int cetrafs_bmap_test_off(struct super_block *sb, u64 lba, u64 off, bool *out_set)
{
    struct buffer_head *bh;
    int err;

    /* Retrying: cetrafs_inode_is_allocated_fresh() drops this block
     * before every read, and with several creators doing that at once a
     * plain sb_bread() racing another's drop comes back NULL -- a
     * spurious -EIO (see cetrafs_bread_retry()). */
    bh = cetrafs_bmap_bread(sb, lba, off, off + 1, &err);
    if (!bh)
        return err;

    *out_set = test_bit_le(off, bh->b_data);
    brelse(bh);
    return 0;
}

/* Is bit #bit of the same kind of bitmap currently set? */
static int cetrafs_bitmap_test_bit(struct super_block *sb, u64 bmap_lba, u64 nblocks, u64 bit, bool *out_set)
{
    if (cetrafs_bmap_blk(bit) >= nblocks)
        return -EINVAL;
    return cetrafs_bmap_test_off(sb, bmap_lba + cetrafs_bmap_blk(bit), cetrafs_bmap_off(bit), out_set);
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
int cetrafs_inode_is_allocated(struct super_block *sb, u64 ino, bool *out_set)
{
    u64 off, lba = cetrafs_ino_bit(sb, ino, &off); /* the bit's block, and its offset in that block */

    /* Outside this node's layout is "cannot tell", not "free": a peer's
     * grow may have added the segment (class 36). */
    if (!lba) {
        *out_set = false;
        return -ERANGE;
    }
    return cetrafs_bmap_test_off(sb, lba, off, out_set);
}

/*
 * Is data block 'lba' allocated in its Block Group's bitmap, as the
 * device has it? For journal replay (audit L9): a redo onto a block
 * that has been freed since repairs nothing -- nothing published refers
 * to it, because a reference never becomes durable before its bit
 * (CLAUDE.md rule 8) -- and writing it lands on a block the allocator
 * may be handing out.
 *
 * Staleness direction (rule 6): "free" is the verdict that SKIPS a
 * redo, so a stale copy saying free about a block the dead node did
 * allocate would leave a torn block unrepaired. The bitmap block is
 * therefore read fresh -- unless this node owns the Block Group, where
 * the cache is the only up-to-date copy and dropping it is not allowed
 * (docs/PERFORMANCE.md, invariant 3; a dirty block is never dropped).
 * -EINVAL: the LBA is in no data region.
 */
int cetrafs_data_block_is_allocated(struct super_block *sb, u64 lba, bool *out_set)
{
    struct cetrafs_bg_geom bg;
    u64 data_start, bit, nblocks;
    u32 bg_id;
    int ret;

    ret = cetrafs_bg_id_for_lba(sb, lba, &bg_id);
    if (ret)
        return ret;
    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;
    data_start = bg.start_block + bg.off_data_region;
    if (lba < data_start || lba >= data_start + bg.data_block_count)
        return -EINVAL;
    bit = lba - data_start;
    nblocks = bg.off_data_region - bg.off_data_bmap;
    if (bg.owner_zg == CETRAFS_BG_OWNER_FREE || !cetrafs_sb_zg_owned_cached(sb, bg.owner_zg))
        cetrafs_invalidate_block(sb, bg.start_block + bg.off_data_bmap + cetrafs_bmap_blk(bit));
    return cetrafs_bitmap_test_bit(sb, bg.start_block + bg.off_data_bmap, nblocks, bit, out_set);
}

/*
 * Make this node's allocation bits durable.
 *
 * Called at every durability boundary BEFORE the write that publishes a
 * reference to the newly allocated blocks -- the close-time record
 * stamp, fsync, sync_fs. Without it the reference reaches the device
 * while the allocation does not, and a node that dies in between leaves
 * blocks referenced by an inode but reading FREE to everyone, including
 * the allocator that hands them out next (see cetrafs_bg_chunk's
 * bmap_alloc_dirty for the full account).
 *
 * Costs one bitmap write per BG allocated from since the last boundary,
 * NOT one per block: the per-block synchronous bitmap write is exactly
 * the cost PERFORMANCE.md forbids, and this is why the allocator can go
 * on using sync=false.
 */
/*
 * Test-only: fail every bitmap-block sync at the durability boundary
 * with -EIO, without writing, as a device write error would. The block
 * stays dirty, which is the state a failed write must leave it in for a
 * retry to be possible at all. tests/kernel/bitmap_flush_error.sh.
 */
static bool cetrafs_alloc_flush_fail;
cetrafs_test_param(alloc_flush_fail, cetrafs_alloc_flush_fail, bool, 0644);
MODULE_PARM_DESC(alloc_flush_fail, "test-only: fail allocation-bitmap syncs at durability boundaries with -EIO");

static int cetrafs_sync_one_block(struct super_block *sb, u64 lba)
{
    struct buffer_head *bh = sb_find_get_block(sb, lba);
    int ret;

    /* find, not read: a block we never cached cannot be dirty, and
     * reading it in just to discover that would turn a flush into I/O
     * over the whole bitmap. */
    if (!bh)
        return 0;

    if (unlikely(READ_ONCE(cetrafs_alloc_flush_fail)) && (buffer_dirty(bh) || buffer_cetra_held(bh))) {
        brelse(bh);
        return -EIO; /* as a failed write leaves it: still pending */
    }
    /* _keep: on a failed write these bytes are the only record of the
     * bits that did not land -- see ioutil.c. */
    ret = cetrafs_sync_buffer_keep(sb, bh);
    brelse(bh);
    return ret;
}

/* TEST ONLY: the boundary flush does nothing -- a publish can reach the
 * device ahead of the bits it names. The negative control of
 * tests/crash/crash_residue.sh: without the flush a cut must find a
 * block referenced but free, or the census cannot see that class. */
static bool cetrafs_alloc_flush_skip;
cetrafs_test_param(alloc_flush_skip, cetrafs_alloc_flush_skip, bool, 0644);
MODULE_PARM_DESC(alloc_flush_skip, "TEST ONLY: skip the allocation-bitmap flush at durability boundaries");

/* TEST ONLY: the next flush that takes a group's mark stalls this many
 * ms before writing it -- the window tests/kernel/bmap_flush_concurrent.sh
 * opens for a second flusher. */
static unsigned int cetrafs_alloc_flush_stall_ms;
cetrafs_test_param(alloc_flush_stall_ms, cetrafs_alloc_flush_stall_ms, uint, 0644);
MODULE_PARM_DESC(alloc_flush_stall_ms, "TEST ONLY: the next bitmap flush stalls N ms after taking a group's mark");

/* TEST ONLY: flushes are not serialised (the pre-fix behaviour). */
static bool cetrafs_alloc_flush_unserialised;
cetrafs_test_param(alloc_flush_unserialised, cetrafs_alloc_flush_unserialised, bool, 0644);
MODULE_PARM_DESC(alloc_flush_unserialised, "TEST ONLY: concurrent bitmap flushes do not wait for each other");

static int __cetrafs_alloc_flush_bitmaps(struct super_block *sb);

/*
 * One flush at a time (audit 2026-11-14 A1). The flush takes each
 * group's mark BEFORE it writes the group's bitmap blocks, so a second
 * flusher arriving while the first one's write is out finds the mark
 * clear, skips the group, returns 0 -- and its caller publishes extents
 * whose bits are in a write that has not completed. A device cache
 * flush after the publish does not order a write still in flight. So
 * the second waits for the first: what the first took, the second's
 * caller needs on the device too.
 */
int cetrafs_alloc_flush_bitmaps(struct super_block *sb)
{
    bool serial = !READ_ONCE(cetrafs_alloc_flush_unserialised);
    int ret;

    /* A mount that failed before its sb_info existed, or after it went,
     * still reaches here from kill_sb's sync_fs: nothing to flush, and
     * no mutex to take. */
    if (!sb->s_fs_info || !cetrafs_sb_raw(sb))
        return 0;
    if (serial && cetrafs_sb_bmap_flush_begin(sb))
        return -EINTR;
    ret = __cetrafs_alloc_flush_bitmaps(sb);
    if (serial)
        cetrafs_sb_bmap_flush_end(sb);
    return ret;
}

/* TEST ONLY: the bitmap flush writes the bits but issues no cache flush
 * after them, as before audit 2026-11-14 A2 -- the control of
 * tests/kernel/bmap_flush_cache_flush.sh. */
static bool cetrafs_bmap_flush_no_cache_flush;
cetrafs_test_param(bmap_flush_no_cache_flush, cetrafs_bmap_flush_no_cache_flush, bool, 0644);
MODULE_PARM_DESC(bmap_flush_no_cache_flush, "TEST ONLY: no device cache flush after the allocation bitmaps");

/* TEST ONLY: the flush visits every Block Group, as before audit
 * 2026-11-14 P7 -- the control of tests/kernel/bmap_flush_visits.sh. */
static bool cetrafs_bmap_flush_scan_all;
cetrafs_test_param(bmap_flush_scan_all, cetrafs_bmap_flush_scan_all, bool, 0644);
MODULE_PARM_DESC(bmap_flush_scan_all, "TEST ONLY: the bitmap flush tests every Block Group's mark");
static atomic64_t cetrafs_bmap_flush_visits = ATOMIC64_INIT(0);
u64 cetrafs_bmap_flush_visit_count(void)
{
    return (u64) atomic64_read(&cetrafs_bmap_flush_visits);
}

static u32 cetrafs_bmap_flush_first(struct super_block *sb, u32 from, u32 bg_count)
{
    u32 b;

    if (from >= bg_count)
        return bg_count;
    if (READ_ONCE(cetrafs_bmap_flush_scan_all))
        return from;
    b = cetrafs_sb_next_bmap_alloc_dirty(sb, from);
    return b < bg_count ? b : bg_count;
}

/* TEST ONLY: the boundary flush writes one bitmap block at a time, each
 * waited for (before audit 2026-11-15 B-29; bmap_flush_batched.sh). */
static bool cetrafs_bmap_flush_serial;
cetrafs_test_param(bmap_flush_serial, cetrafs_bmap_flush_serial, bool, 0644);
MODULE_PARM_DESC(bmap_flush_serial, "TEST ONLY: the boundary bitmap flush writes one block at a time");

static atomic64_t cetrafs_bmap_flush_batches = ATOMIC64_INIT(0);
u64 cetrafs_bmap_flush_batch_count(void)
{
    return (u64) atomic64_read(&cetrafs_bmap_flush_batches);
}

#define CETRAFS_BMAP_FLUSH_BATCH 256

/* The bitmap blocks a flush collected, sent and waited for together. */
struct cetrafs_bmap_flush_q {
    struct buffer_head *bh[CETRAFS_BMAP_FLUSH_BATCH];
    u32 bg[CETRAFS_BMAP_FLUSH_BATCH];
    int res[CETRAFS_BMAP_FLUSH_BATCH];
    unsigned int n, cap;
    int err; /* the device's reason, if every failure was a kept refusal (-ENOSPC); else -EIO */
};

/* Write what is queued; a failed block fails its group. */
static void cetrafs_bmap_flush_q_run(struct super_block *sb, struct cetrafs_bmap_flush_q *q, unsigned long *failed)
{
    unsigned int i;
    int r;

    if (!q->n)
        return;
    atomic64_inc(&cetrafs_bmap_flush_batches);
    r = cetrafs_sync_buffers_keep(sb, q->bh, q->n, q->res);
    for (i = 0; i < q->n; i++) {
        /* fenced: nothing was sent, every group fails */
        if (r == -EIO && cetrafs_sb_is_fenced(sb))
            q->res[i] = -EIO;
        if (q->res[i]) {
            __set_bit(q->bg[i], failed);
            /* A kept refusal is the thin pool's answer, and the caller's
             * (qemu pauses the guest on ENOSPC); anything else is EIO. */
            if (q->res[i] != -ENOSPC)
                q->err = -EIO;
            else if (!q->err)
                q->err = -ENOSPC;
        }
        brelse(q->bh[i]);
    }
    q->n = 0;
}

/* TEST ONLY: the boundary flush fails a group whose descriptor does not
 * read, as before audit 2026-11-22 N-44 -- the control of
 * tests/kernel/bmap_flush_desc_unreadable.sh. */
static bool cetrafs_bmap_flush_needs_desc;
cetrafs_test_param(bmap_flush_needs_desc, cetrafs_bmap_flush_needs_desc, bool, 0644);
MODULE_PARM_DESC(bmap_flush_needs_desc, "TEST ONLY: the bitmap flush fails a group whose descriptor does not read");

static int __cetrafs_alloc_flush_bitmaps(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct cetrafs_bmap_flush_q *q = NULL;
    u32 bg_count, bg_id;
    unsigned long *wrote = NULL, *taken = NULL, *failed = NULL;
    unsigned int stall;
    int ret = 0;

    if (!raw_sb || unlikely(READ_ONCE(cetrafs_alloc_flush_skip)))
        return 0;
    bg_count = le32_to_cpu(raw_sb->block_group_count);

    /* Only the marked groups: a test of every group's mark made each
     * flush O(Block Groups), several per fdatasync (audit 2026-11-14 P7). */
    /* Something to write: the device's word on the fence first (B-18). */
    bg_id = cetrafs_bmap_flush_first(sb, 0, bg_count);
    if (bg_id >= bg_count)
        return 0;
    if (cetrafs_sb_fence_witnessed(sb))
        return -EIO;
    /* Before any mark is taken: a mark taken must be written or put back. */
    q = kvmalloc(sizeof(*q), GFP_NOFS);
    /* kvcalloc: a huge Block Group table must not turn an fsync into a
     * failed high-order allocation (audit 2026-11-15 F-21) */
    taken = kvcalloc(BITS_TO_LONGS(bg_count), sizeof(long), GFP_NOFS);
    failed = kvcalloc(BITS_TO_LONGS(bg_count), sizeof(long), GFP_NOFS);
    wrote = kvcalloc(BITS_TO_LONGS(bg_count), sizeof(long), GFP_NOFS);
    if (!q || !taken || !failed || !wrote) {
        ret = -ENOMEM;
        goto out;
    }
    q->n = 0;
    q->err = 0;
    q->cap = READ_ONCE(cetrafs_bmap_flush_serial) ? 1 : CETRAFS_BMAP_FLUSH_BATCH;
    for (; bg_id < bg_count; bg_id = cetrafs_bmap_flush_first(sb, bg_id + 1, bg_count)) {
        struct cetrafs_bg_geom bg;
        u64 b, nblocks, bmap_lba;

        atomic64_inc(&cetrafs_bmap_flush_visits);
        if (!cetrafs_sb_take_bmap_alloc_dirty(sb, bg_id))
            continue;
        /* Taken, so from here every failure must put the mark BACK: a
         * BG whose bits did not reach the device and is no longer marked
         * is never synced by any later boundary, and that boundary then
         * reports success and publishes extents naming those blocks. */
        __set_bit(bg_id, taken);
        stall = READ_ONCE(cetrafs_alloc_flush_stall_ms) ? xchg(&cetrafs_alloc_flush_stall_ms, 0) : 0;
        if (stall)
            msleep(stall); /* test-only; see the parameter */
        if (!cetrafs_read_bg_geom(sb, bg_id, &bg)) {
            bmap_lba = bg.start_block + bg.off_data_bmap;
            nblocks = bg.off_data_region - bg.off_data_bmap;
        } else if (READ_ONCE(cetrafs_bmap_flush_needs_desc) ||
                   !cetrafs_sb_bg_bmap_span(sb, bg_id, &bmap_lba, &nblocks)) {
            __set_bit(bg_id, failed);
            q->err = -EIO;
            continue;
        }
        /* else: the descriptor does not read now, but where the bitmap is
         * was fixed when the mount verified it. Failing here failed
         * every publish of every file on the node, each finding the same
         * mark put back (N-44); the descriptor's own damage is counted by
         * the read and answered where it is used. */
        for (b = 0; b < nblocks; b++) {
            /* find, not read: a block we never cached cannot be dirty,
             * and reading it in just to discover that would turn a flush
             * into I/O over the whole bitmap. */
            struct buffer_head *bh = sb_find_get_block(sb, bmap_lba + b);

            if (!bh)
                continue;
            if (unlikely(READ_ONCE(cetrafs_alloc_flush_fail)) && (buffer_dirty(bh) || buffer_cetra_held(bh))) {
                brelse(bh); /* as a failed write leaves it: still pending */
                __set_bit(bg_id, failed);
                q->err = -EIO;
                continue;
            }
            q->bh[q->n] = bh;
            q->bg[q->n] = bg_id;
            if (++q->n >= q->cap)
                cetrafs_bmap_flush_q_run(sb, q, failed);
        }
        cond_resched();
    }
    cetrafs_bmap_flush_q_run(sb, q, failed);
    for_each_set_bit(bg_id, taken, bg_count) {
        if (test_bit(bg_id, failed)) {
            cetrafs_sb_note_bmap_alloc(sb, bg_id);
            pr_err_ratelimited("BG %u: allocation bitmap not made durable -- refusing to publish extents\n", bg_id);
            if (!ret)
                ret = q->err ?: -EIO; /* a geometry read or a test failure set no reason: EIO */
        } else {
            /* Written: remembered, so a refused cache flush below can
             * put its mark back. */
            __set_bit(bg_id, wrote);
        }
    }
    if (bitmap_empty(wrote, bg_count)) {
        kvfree(wrote);
        wrote = NULL;
    }
    /*
     * Written is not durable. Every caller publishes next -- a whole
     * record, a namespace CAS, an fd sector -- and on a write-back LUN
     * the publish and these bits reach the media in either order: a
     * power cut between leaves a directory or xattr block referenced
     * and FREE (audit 2026-11-14 A2; rule 8). One cache flush here, only
     * when bits were written, covers every caller; an idle call stays
     * free. Refused, the marks go back and the caller refuses to publish.
     */
    if (wrote && !READ_ONCE(cetrafs_bmap_flush_no_cache_flush)) {
        int fret = cetrafs_publish_flush(sb);

        if (fret) {
            for_each_set_bit(bg_id, wrote, bg_count)
                cetrafs_sb_note_bmap_alloc(sb, bg_id);
            pr_err_ratelimited("allocation bitmaps written but the device cache flush failed (%d) -- refusing to "
                               "publish extents\n",
                               fret);
            if (!ret)
                ret = fret;
        }
    }
out:
    kvfree(wrote);
    kvfree(failed);
    kvfree(taken);
    kvfree(q);
    return ret;
}

/*
 * cetrafs_alloc_flush_bitmaps(), but nearly free when there is nothing to
 * flush -- for the extent-tree edit gate in file.c, which runs once per
 * mapped block (cetrafs_tree_append()). With speculative runs the bits
 * of a whole run are set at once, so the sync it does costs one bitmap
 * write per run, not per block.
 */
/* Gate calls that found something to flush: the same workload must enter
 * as often with the dirty count as with the chunk walk it replaced
 * (tests/kernel/bmap_gate_cost.sh). */
static atomic64_t cetrafs_bmap_gate_entries = ATOMIC64_INIT(0);
u64 cetrafs_bmap_gate_entry_count(void)
{
    return (u64) atomic64_read(&cetrafs_bmap_gate_entries);
}

int cetrafs_alloc_flush_bitmaps_if_dirty(struct super_block *sb)
{
    /* No mark is not enough: a flush in flight has taken marks whose
     * writes may not have completed (see cetrafs_alloc_flush_bitmaps()). */
    if (!cetrafs_sb_bmap_alloc_any_dirty(sb) &&
        (READ_ONCE(cetrafs_alloc_flush_unserialised) || !cetrafs_sb_bmap_flush_inflight(sb)))
        return 0;
    atomic64_inc(&cetrafs_bmap_gate_entries);
    return cetrafs_alloc_flush_bitmaps(sb);
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

/* TEST ONLY: the free loop looks the bitmap block up twice per bit, as
 * before audit 2026-11-14 P2 -- the control of
 * tests/kernel/free_bmap_lookups.sh. */
static bool cetrafs_free_per_bit;
cetrafs_test_param(free_per_bit, cetrafs_free_per_bit, bool, 0644);
MODULE_PARM_DESC(free_per_bit, "TEST ONLY: a data free looks the bitmap block up per bit");
static atomic64_t cetrafs_free_bmap_lookups = ATOMIC64_INIT(0);
u64 cetrafs_free_bmap_lookup_count(void)
{
    return (u64) atomic64_read(&cetrafs_free_bmap_lookups);
}

/* TEST ONLY: at most this many entries per pending-free swap (0 = the batch's
 * full size; 1 = one swap per extent, the control of
 * tests/kernel/pf_batch_cas.sh). */
static unsigned int cetrafs_pf_batch_size;
cetrafs_test_param(pf_batch_size, cetrafs_pf_batch_size, uint, 0644);
MODULE_PARM_DESC(pf_batch_size, "TEST ONLY: most entries one pending-free swap carries (0 = full batch, 1 = one per swap)");

static unsigned int cetrafs_pf_batch_limit(void)
{
    unsigned int v = READ_ONCE(cetrafs_pf_batch_size);

    return (!v || v > CETRAFS_FREE_BATCH) ? CETRAFS_FREE_BATCH : v;
}

/* Queue what fb holds, one owner's Zone Group at a time. Every entry leaves
 * fb here, queued or leaked: a batch is never carried past its operation. */
int cetrafs_free_batch_flush(struct super_block *sb, struct cetrafs_free_batch *fb)
{
    u32 dropped = 0;
    int ret;

    if (!fb->n)
        return 0;
    ret = cetrafs_zg_queue_foreign_frees(sb, fb->zg, fb->ents, fb->n, &dropped);
    ctrace("BLKQUEUE zg=%u n=%u dropped=%u ret=%d\n", (unsigned int) fb->zg, (unsigned int) fb->n, dropped, ret);
    /* Dropped extents are the deliberate leak the caller never hears of --
     * see cetrafs_zg_queue_foreign_frees(). */
    if (dropped)
        atomic64_add(dropped, &cetrafs_foreign_free_leaks);
    fb->n = 0;
    return ret;
}

/* Hold one foreign extent in fb, flushing first when it is for another
 * Zone Group or the batch is at its limit. */
static int cetrafs_free_batch_add(struct super_block *sb,
                                  struct cetrafs_free_batch *fb,
                                  u32 zg_id,
                                  const struct cetrafs_pf_ent *ent)
{
    int ret = 0;

    if (fb->n && (fb->zg != zg_id || fb->n >= cetrafs_pf_batch_limit()))
        ret = cetrafs_free_batch_flush(sb, fb);
    fb->zg = zg_id;
    fb->ents[fb->n++] = *ent;
    return ret;
}

static int __cetrafs_free_data_extent(struct super_block *sb,
                                      u64 lba,
                                      u32 count,
                                      const u64 *resv_seq,
                                      const u64 *alloc_seq,
                                      u64 *out_freed,
                                      struct cetrafs_free_batch *fb);

int cetrafs_free_data_extent(struct super_block *sb, u64 lba, u32 count)
{
    return __cetrafs_free_data_extent(sb, lba, count, NULL, NULL, NULL, NULL);
}

int cetrafs_free_data_extent_batched(struct super_block *sb, u64 lba, u32 count, struct cetrafs_free_batch *fb)
{
    return __cetrafs_free_data_extent(sb, lba, count, NULL, NULL, NULL, fb);
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
/*
 * alloc_seq (NULL = unchecked): the Block Group's allocation count from
 * before the scrub's evidence, rechecked under alloc_mutex with each bit
 * (cetrafs_sb_bg_alloc_seq()). The scrub's own check runs outside the
 * mutex, and a block it judged leaked can be cleared and handed out again
 * between that check and this free: a pending-free copy of it, applied
 * by the drain in that gap -- legitimately, its stamp still current --
 * frees it, and the allocator may give it to a new file at once. Tested
 * here, with the bit, nothing can move between the verdict's last word
 * and the clear.
 */
/*
 * And the group must still be the one the scrub judged. Its check runs
 * before this call and a CAS (the free_gen bump) before it, outside the
 * mutex: a group that left this node in between used to turn the free
 * into a foreign one, queued to the new owner with a stamp read after
 * the scrub's own bump -- which that owner's drain accepts, freeing what
 * it has since allocated there (audit 2026-11-15 BC-17). The scrub's free
 * never queues, and the owner is re-asked under alloc_mutex with the
 * first bit.
 */
static bool cetrafs_scrub_free_owner_unchecked;
cetrafs_test_param(scrub_free_owner_unchecked, cetrafs_scrub_free_owner_unchecked, bool, 0644);
MODULE_PARM_DESC(scrub_free_owner_unchecked, "TEST ONLY: the scrub's free queues to a foreign owner and does not re-ask the owner under the mutex, as before audit BC-17");

int cetrafs_free_data_extent_unless_reserved(struct super_block *sb, u64 lba, u32 count, u64 resv_seq,
                                             const u64 *alloc_seq, u64 *out_freed)
{
    return __cetrafs_free_data_extent(sb, lba, count, &resv_seq, alloc_seq, out_freed, NULL);
}

/*
 * Does [lba, lba+count) lie in one Block Group this node owns -- the
 * blocks the free path below would clear in our own bitmap rather than
 * queue to a peer? Asked by a freeing operation before its publish
 * (cetrafs_frees_begin()): blocks only in our own groups are judged by
 * no peer's scrub, so the operation need not stop theirs.
 *
 * The cached descriptor is the right read here, and not only for speed:
 * a group this node owns is written by this node alone and leaves it
 * only by our own release (which takes only an EMPTY group, and these
 * blocks are allocated) or by a peer's steal, which comes only after our
 * one-way lease has lapsed (a premise, see cetrafs_frees_begin()) -- and
 * a free reaches the device only as a held bitmap block written by a
 * gated flush, not by writeback (tests/kernel/fence_writeback_race.sh;
 * audit BC-8), short of a freeze between a gate and its send. Every
 * other answer -- a foreign or unowned
 * group, an unreadable descriptor, a run past the data region -- is
 * "not ours", which announces: the safe direction.
 */
bool cetrafs_lba_run_is_ours(struct super_block *sb, u64 lba, u64 count)
{
    struct cetrafs_bg_geom bg;
    u64 data_start;
    u32 bg_id;

    if (!count)
        return true;
    if (cetrafs_bg_id_for_lba(sb, lba, &bg_id) || cetrafs_read_bg_geom(sb, bg_id, &bg))
        return false;
    if (bg.owner_zg == CETRAFS_BG_OWNER_FREE || !cetrafs_sb_zg_owned_cached(sb, bg.owner_zg))
        return false;
    data_start = bg.start_block + bg.off_data_region;
    return lba >= data_start && lba + count <= data_start + bg.data_block_count;
}

/* resv_seq: NULL for an owner's free; the scrub passes the registry's
 * release count from before its evidence (cetrafs_sb_resv_seq()). */
/* out_freed: the blocks this call cleared (only the direct path clears any). */
/* TEST ONLY: a one-shot stall where the direct free lets go of
 * alloc_mutex between chunks, and the old loop that asked nothing after
 * it (tests/kernel/free_chunk_fence.sh). */
static unsigned int cetrafs_free_chunk_stall_ms;
cetrafs_test_param(free_chunk_stall_ms, cetrafs_free_chunk_stall_ms, uint, 0644);
static bool cetrafs_free_chunk_recheck_off;
cetrafs_test_param(free_chunk_recheck_off, cetrafs_free_chunk_recheck_off, bool, 0644);

/* TEST ONLY: a free drops held-back tree edits in its range before it
 * validates the extent, as before audit 2026-11-15 BL-13
 * (tests/kernel/free_refused_keeps_edits.sh). */
static bool cetrafs_free_forget_first;
cetrafs_test_param(free_forget_first, cetrafs_free_forget_first, bool, 0644);
MODULE_PARM_DESC(free_forget_first, "TEST ONLY: drop held-back tree edits in a freed range before validating it");

static int __cetrafs_free_data_extent(struct super_block *sb, u64 lba, u32 count, const u64 *resv_seq, const u64 *alloc_seq, u64 *out_freed, struct cetrafs_free_batch *fb)
{
    struct cetrafs_bmap_hold fh = {0}; /* the bitmap block the loop holds */
    struct cetrafs_bg_geom bg;
    u64 data_start, bit, b, freed = 0, credited = 0;
    u32 bg_id;
    int ret;

    if (out_freed)
        *out_freed = 0;
    if (!count)
        return 0;
    if (cetrafs_sb_ro_refuses(sb, "a data block free"))
        return -EROFS;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced */

    if (READ_ONCE(cetrafs_free_forget_first))
        cetrafs_deferred_forget_range(sb, lba, count); /* test-only: the old order; see the parameter */

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

    /*
     * Both verdicts below are destructive -- FREE is declared damage,
     * and a foreign owner gets the extent on its queue -- and both read
     * the owner from a descriptor that is cached on the first attempt.
     * A Block Group this node last saw FREE (a statfs sweep), then
     * claimed and filled by a peer, read FREE here and a live file's
     * free was refused as corruption, under corruption=stop stopping
     * the mount. Re-read before either: a rare path, and
     * cetrafs_bg_desc_refresh_foreign() never touches a BG this node
     * owns (docs/PERFORMANCE.md, invariant 3).
     */
    if (bg.owner_zg == CETRAFS_BG_OWNER_FREE || !cetrafs_sb_zg_owned_cached(sb, bg.owner_zg)) {
        cetrafs_bg_desc_refresh_foreign(sb, bg_id);
        ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
        if (ret) {
            pr_err_ratelimited("free: extent [%llu +%u): BG %u geometry unreadable (%d) -- leaked\n",
                               (unsigned long long) lba, count, bg_id, ret);
            return ret;
        }
    }

    data_start = bg.start_block + bg.off_data_region;
    if (lba + count > data_start + bg.data_block_count) {
        pr_err("free extent [%llu +%u) crosses out of BG %u -- refusing\n", (unsigned long long) lba, count, bg_id);
        cetrafs_sb_corrupt(sb, 0);
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
    /* A Block Group goes back to the unowned pool only once it is EMPTY
     * (cetrafs_bg_release_empty()), so an extent that points into one
     * describes blocks nobody allocated: damage, not a free. Its bitmap
     * is nobody's to change -- the next claimer owns it -- and there is
     * no queue to send it to. This used to fail inside the queue lookup
     * with -EINVAL, unlogged, and every caller drops a free's error. */
    /* The scrub's free judged a group of ours, its bits set: a group
     * now FREE or another's was released or taken since -- its verdict
     * is stale, not the volume damaged, and nothing of it is ours to
     * change or queue, nor its held-back edits to drop (audit BC-17). */
    if (resv_seq && !READ_ONCE(cetrafs_scrub_free_owner_unchecked) &&
        (bg.owner_zg == CETRAFS_BG_OWNER_FREE || cetrafs_pf_force_foreign ||
         (cetrafs_sb_caw_available(sb) && !cetrafs_sb_zg_owned_cached(sb, bg.owner_zg)))) {
        pr_info("scrub: BG %u is not this node's any more -- not freeing [%llu +%u]\n", bg_id,
                (unsigned long long) lba, count);
        return -EAGAIN;
    }
    if (bg.owner_zg == CETRAFS_BG_OWNER_FREE) {
        pr_err_ratelimited("free: extent [%llu +%u) is in BG %u, which no Zone Group owns -- a reference to "
                           "unallocated blocks; not freeing (fsck)\n",
                           (unsigned long long) lba, count, bg_id);
        cetrafs_sb_corrupt(sb, 0);
        return -EUCLEAN;
    }

    /* A tree block of ours held back for a boundary (leafdefer.c) and
     * freed before it: its edit belongs to a tree that no longer names
     * it, and written later it would land on the block's next owner.
     * Dropped here, once the extent is known to be a free and not
     * damage: refused above, nothing changes hands, and a range a
     * corrupt extent names may hold ANOTHER file's held-back leaf, whose
     * edit was dropped with no free to justify it (audit 2026-11-15
     * BL-13). A free that leaks below keeps its blocks allocated, so an
     * edit written later lands on nobody's. */
    /* The scrub's free drops nothing: blocks it judged leaked are no
     * tree's, so one held back here was allocated since the verdict --
     * refused, and one allocated after this look moves the allocation
     * count the mutex check below refuses on. Dropping it here, outside
     * that check, threw away a live file's edit (audit BC-17). */
    if (resv_seq && !READ_ONCE(cetrafs_scrub_free_owner_unchecked)) {
        if (cetrafs_deferred_any_in_range(sb, lba, count))
            return -EAGAIN;
    } else if (!READ_ONCE(cetrafs_free_forget_first)) {
        cetrafs_deferred_forget_range(sb, lba, count);
    }

    if (cetrafs_sb_caw_available(sb) || cetrafs_pf_force_foreign) {
        if (cetrafs_pf_force_foreign || !cetrafs_sb_zg_owned_cached(sb, bg.owner_zg)) {
            /* The stamp is the descriptor as read above -- refreshed,
             * for a group we do not own. Read older than the device it
             * can only make the drain drop this entry: a leak, the safe
             * direction (rule 6). */
            /*
             * The extent joins a batch. A full queue leaks what it cannot
             * place -- its owner behind, or dead and flagged for the
             * heartbeat to adopt (never adopted here: this runs inside the
             * caller's locks; audit 2026-11-06 M6) -- deliberately, logged,
             * and reclaimed later by the scrub or fsck -r. That is a
             * bounded, recoverable loss of SPACE, never a failure of the
             * caller's operation: returning it failed the guest's I/O on a
             * punch-hole, qemu latched "I/O status: nospace" and Proxmox
             * paused the VM, while the volume had 2 TB free. The flush
             * counts such leaks (cetrafs_free_batch_flush()) and returns
             * only a hard error. A caller asked us to stop referencing
             * these blocks and we did; whether the owner got to reuse them
             * yet is our problem, not theirs.
             *
             * The stamp is the descriptor as read above -- refreshed, for a
             * group we do not own. Read older than the device it can only
             * make the drain drop this entry: a leak, the safe direction
             * (rule 6). Each entry keeps its own, since one batch can span
             * Block Groups.
             */
            {
                struct cetrafs_pf_ent ent = {.lba = lba, .count = count, .stamp = bg.free_gen};
                u32 dropped = 0;

                if (fb)
                    return cetrafs_free_batch_add(sb, fb, bg.owner_zg, &ent);
                /* One extent: the swap a batch of one makes, without a
                 * whole batch on the stack -- this frame sits under the
                 * leaf punch's, which holds one already. */
                ret = cetrafs_zg_queue_foreign_frees(sb, bg.owner_zg, &ent, 1, &dropped);
                ctrace("BLKQUEUE zg=%u n=1 dropped=%u ret=%d\n", (unsigned int) bg.owner_zg, dropped, ret);
                if (dropped)
                    atomic64_add(dropped, &cetrafs_foreign_free_leaks); /* see cetrafs_free_batch_flush() */
                return ret;
            }
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
    /* The scrub's: the group is still ours, asked under the mutex every
     * free of it takes, next to the allocation-count check (BC-17). The
     * owned bit is the one a release clears (cetrafs_sb_drain_bg()) under
     * this mutex BEFORE its descriptor swap, so a release either drained
     * it first and this refuses, or comes after this hold and finds the
     * bits still set. The chunk re-checks below cover a long extent. */
    if (resv_seq && !READ_ONCE(cetrafs_scrub_free_owner_unchecked) &&
        (cetrafs_sb_is_fenced(sb) || !cetrafs_sb_bg_is_ours(sb, bg_id) || cetrafs_sb_bg_owner(sb, bg_id) != bg.owner_zg ||
         (cetrafs_sb_caw_available(sb) && !cetrafs_sb_zg_owned_cached(sb, bg.owner_zg)))) {
        cetrafs_sb_alloc_unlock(sb);
        pr_info("scrub: BG %u left this node before its free -- not freeing [%llu +%u]\n", bg_id,
                (unsigned long long) lba, count);
        return -EAGAIN;
    }
    for (b = 0; b < count; b++) {
        bool set = false;

        /* An extent is up to a whole Block Group -- 2^32 blocks at the
         * format's limit -- and holding alloc_mutex across all of it
         * stopped every allocation on this node for the duration: about
         * a tenth of a second per default 1 GiB group, minutes at the
         * limit (audit 2026-11-06 L26). Let go between chunks, the
         * chunk's credit taken first. Nothing here relies on the extent
         * going in one hold: the bits not yet freed stay set, so no
         * allocation can reach them and the group cannot be released
         * (that needs its bitmap empty), and the reservation checks
         * below are per block, under the lock, as before. */
        if (b && !(b & 4095)) {
            cetrafs_bmap_hold_end(sb, &fh); /* never held across the unlock */
            if (freed > credited) {
                cetrafs_bg_adjust_free_blocks(sb, bg_id, (s64) (freed - credited));
                credited = freed;
            }
            cetrafs_sb_alloc_unlock(sb);
            cond_resched();
            {
                unsigned int ms = xchg(&cetrafs_free_chunk_stall_ms, 0);

                if (ms) {
                    pr_info("free: chunk stall at block %llu of extent [%llu +%u], %u ms\n",
                            (unsigned long long) b, (unsigned long long) lba, count, ms);
                    msleep(ms); /* TEST ONLY: see the parameter */
                }
            }
            cetrafs_sb_alloc_lock(sb);
            /* Re-asked after every let-go, as the pending-free apply
             * does: a fence or a Zone Group given up meanwhile makes the
             * rest of this bitmap someone else's to change. The bits not
             * yet cleared stay set -- a leak the scrub reclaims, never a
             * block freed under its next owner (audit 2026-11-14 M-2). */
            if (!READ_ONCE(cetrafs_free_chunk_recheck_off) &&
                (cetrafs_sb_is_fenced(sb) ||
                 (cetrafs_sb_caw_available(sb) && !cetrafs_sb_zg_owned_cached(sb, bg.owner_zg)))) {
                ret = -EIO;
                break;
            }
        }
        if (resv_seq && cetrafs_resv_covers(sb, lba + b))
            continue; /* a live reservation claimed it since the caller decided -- not ours to free */
        /* Not covered NOW -- but a run released since the verdict was
         * covered then and is somebody's data now. Order matters: the
         * count is read AFTER the coverage test, so "unchanged" means no
         * span held this block at any point since the verdict. */
        if (resv_seq && cetrafs_sb_resv_seq(sb) != *resv_seq) {
            ret = -EAGAIN;
            break;
        }
        if (alloc_seq && cetrafs_sb_bg_alloc_seq(sb, bg_id) != *alloc_seq) {
            ret = -EAGAIN; /* allocated in since the verdict: the evidence is stale */
            break;
        }

        /* Inside a run a FITRIM has claimed: the bit is the trim's, and
         * this block was free before it was claimed -- a double free.
         * Clearing it would hand the block out under the UNMAP still in
         * flight (see cetrafs_trim_claim_next()). */
        if (cetrafs_sb_trim_holds(sb, lba + b)) {
            pr_warn_ratelimited("free: block %llu is being trimmed, so it was already free (double free of extent "
                                "[%llu +%u))\n",
                                (unsigned long long) (lba + b), (unsigned long long) lba, count);
            continue;
        }
        if (READ_ONCE(cetrafs_free_per_bit)) { /* test-only: the old per-bit lookups */
            ret = cetrafs_bitmap_test_bit(sb, bg.start_block + bg.off_data_bmap,
                                          bg.off_data_region - bg.off_data_bmap, bit + b, &set);
            if (ret)
                break;
            atomic64_inc(&cetrafs_free_bmap_lookups);
            if (!set) {
                pr_warn_ratelimited("free: block %llu was already free (double free of extent [%llu +%u))\n",
                                    (unsigned long long) (lba + b), (unsigned long long) lba, count);
                continue;
            }
            ret = cetrafs_bitmap_free_bit(sb, bg.start_block + bg.off_data_bmap,
                                          bg.off_data_region - bg.off_data_bmap, bit + b, /*sync=*/false);
            if (ret)
                break;
            atomic64_inc(&cetrafs_free_bmap_lookups);
        } else {
            /*
             * One lookup and one buffer-lock hold per bitmap block, not
             * two lookups and a lock round per bit: unlinking a 100 GiB
             * image made 52 M of them (audit 2026-11-14 P2). The test
             * and the clear are under the buffer lock, as
             * cetrafs_bitmap_free_bit()'s are; nothing in this loop
             * sleeps on I/O while it is held, and the hold ends at every
             * block change and before alloc_mutex is let go.
             */
            u64 off;

            ret = cetrafs_bmap_hold_at(sb, &fh, bg.start_block + bg.off_data_bmap,
                                       bg.off_data_region - bg.off_data_bmap, bit + b, &off, &cetrafs_free_bmap_lookups);
            if (ret)
                break;
            if (!cetrafs_bmap_hold_flip(&fh, off, false)) {
                pr_warn_ratelimited("free: block %llu was already free (double free of extent [%llu +%u))\n",
                                    (unsigned long long) (lba + b), (unsigned long long) lba, count);
                continue;
            }
        }
        cetrafs_shadow_clear(sb, lba + b, 1, "free_data_extent");
        freed++;
    }
    cetrafs_bmap_hold_end(sb, &fh);
    if (freed > credited)
        cetrafs_bg_adjust_free_blocks(sb, bg_id, (s64) (freed - credited));
    cetrafs_sb_alloc_unlock(sb);
    if (out_freed)
        *out_freed = freed;
    if (freed)
        cetrafs_inline_discard_note(sb, bg_id, lba, count); /* -o discard: queued, never issued here */

    /*
     * Say so if it went wrong. Every caller of this function ignores the
     * return value -- deliberately, matching the convention that a
     * free-path failure must not fail the operation that triggered it --
     * which means an error here would otherwise be a completely silent
     * block leak. The queue path on the other side of this function
     * already logs its own failure loudly; this half did not.
     */
    if (ret && ret != -EAGAIN) /* -EAGAIN: the scrub's verdict went stale; it keeps the blocks */
        pr_err("free: extent [%llu +%u) failed after %llu block(s): %d -- those blocks are leaked\n",
               (unsigned long long) lba, count, (unsigned long long) freed, ret);

    ctrace("BLKFREE lba=%llu count=%u freed=%llu ret=%d from=%pS\n", (unsigned long long) lba, count,
           (unsigned long long) freed, ret, __builtin_return_address(0));
    return ret;
}

/* Pending-free entries the drain dropped because their stamp is not the
 * Block Group's free_gen any more: a copy from before a scrub reclaim. */
static atomic64_t cetrafs_pf_stale_drops = ATOMIC64_INIT(0);

u64 cetrafs_pf_stale_drop_count(void)
{
    return (u64) atomic64_read(&cetrafs_pf_stale_drops);
}

/* TEST ONLY: the drain applies an entry whatever its stamp -- the
 * negative control of tests/kernel/pf_late_copy_after_reclaim.sh. */
static bool cetrafs_pf_ignore_stamp;
cetrafs_test_param(pf_ignore_stamp, cetrafs_pf_ignore_stamp, bool, 0644);
MODULE_PARM_DESC(pf_ignore_stamp, "TEST ONLY: the pending-free drain does not check an entry's free_gen stamp");

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
/*
 * stamp: the entry's free_gen. The entry is applied only while it equals
 * the group's, compared under alloc_mutex together with the bit clears:
 * the scrub raises free_gen (cetrafs_bg_bump_free_gen()) before it frees
 * anything here, and its frees take this same mutex after, so an apply
 * either runs wholly before the scrub's first free -- its blocks were
 * still the leak the copy names, and the scrub's own free then finds the
 * bit clear, or allocated again (its alloc_seq guard) -- or sees the new
 * value and drops the entry. Returns 1 for a dropped entry: its blocks
 * stay set, a leak the next scrub cycle reclaims.
 *
 * The cached descriptor is the authoritative one here: free_gen is
 * written only by this group's owner (and by fsck -r, with no node
 * mounted), and every way a group becomes ours swaps its descriptor
 * fresh -- the claim from the pool, the Zone Group claim's recount, the
 * mount's walk.
 */
/* TEST ONLY: apply a pending free in one hold of alloc_mutex, as before
 * audit 2026-11-14 P1 -- the control of tests/kernel/pf_apply_lock_chunks.sh. */
static bool cetrafs_pf_apply_one_hold;
cetrafs_test_param(pf_apply_one_hold, cetrafs_pf_apply_one_hold, bool, 0644);
MODULE_PARM_DESC(pf_apply_one_hold, "TEST ONLY: apply a pending free under one alloc_mutex hold");

/* TEST ONLY: the pending-free apply looks the bitmap block up twice per
 * bit, as before -- the control of tests/kernel/pf_apply_bmap_lookups.sh. */
static bool cetrafs_pf_apply_per_bit;
cetrafs_test_param(pf_apply_per_bit, cetrafs_pf_apply_per_bit, bool, 0644);
MODULE_PARM_DESC(pf_apply_per_bit, "TEST ONLY: a pending-free apply looks the bitmap block up per bit");
static atomic64_t cetrafs_pf_apply_bmap_lookups = ATOMIC64_INIT(0);
u64 cetrafs_pf_apply_bmap_lookup_count(void)
{
    return (u64) atomic64_read(&cetrafs_pf_apply_bmap_lookups);
}

/* TEST ONLY: a late copy for a group that left the Zone Group counts as
 * corruption, as before audit 2026-11-15 M-7 (tests/kernel/pf_late_copy_not_corrupt.sh). */
static bool cetrafs_pf_late_copy_corrupt;
cetrafs_test_param(pf_late_copy_corrupt, cetrafs_pf_late_copy_corrupt, bool, 0644);
MODULE_PARM_DESC(pf_late_copy_corrupt, "TEST ONLY: a late pending-free copy for a departed group counts as corruption");

/* TEST ONLY: apply a pending free without asking, under alloc_mutex,
 * whether its group and Zone Group are still this node's, as before
 * audit 2026-11-22 N-60 (tests/kernel/pf_apply_foreign_group.sh). */
static bool cetrafs_pf_apply_owner_unchecked;
cetrafs_test_param(pf_apply_owner_unchecked, cetrafs_pf_apply_owner_unchecked, bool, 0644);
MODULE_PARM_DESC(pf_apply_owner_unchecked, "TEST ONLY: a pending-free apply skips its ownership check under alloc_mutex");
static atomic64_t cetrafs_pf_apply_left_drops = ATOMIC64_INIT(0);

u64 cetrafs_pf_apply_left_drop_count(void)
{
    return atomic64_read(&cetrafs_pf_apply_left_drops);
}

/*
 * Still this node's to free in, asked under alloc_mutex: the question the
 * direct free asks there (__cetrafs_free_data_extent()). The apply read
 * the group's owner before taking the mutex and judged only free_gen
 * under it, and a Zone Group handed off whole keeps both -- its groups
 * stay its members and nobody's claim moves their generation. A copy
 * applied after that hand-off cleared a bit in the new owner's bitmap
 * (audit 2026-11-22, N-60). The owned bit and the cached Zone Group are
 * cleared under this mutex by a release, so a release either came first
 * and this refuses, or comes after and finds the bits this left set.
 * Dropped like a stale stamp: the entry was consumed, its blocks stay
 * allocated for the scrub.
 */
static bool cetrafs_pf_apply_still_ours(struct super_block *sb, u32 bg_id, u32 expect_zg, u64 lba, u32 count)
{
    if (READ_ONCE(cetrafs_pf_apply_owner_unchecked))
        return true;
    if (cetrafs_sb_bg_is_ours(sb, bg_id) && cetrafs_sb_bg_owner(sb, bg_id) == expect_zg &&
        (!cetrafs_sb_caw_available(sb) || cetrafs_sb_zg_owned_cached(sb, expect_zg)))
        return true;
    atomic64_inc(&cetrafs_pf_stale_drops);
    atomic64_inc(&cetrafs_pf_apply_left_drops);
    pr_warn_ratelimited("pending free [%llu +%u): BG %u or its ZG %u left this node before the apply -- dropped, "
                        "its blocks stay allocated for the scrub\n",
                        (unsigned long long) lba, count, bg_id, expect_zg);
    return false;
}

int cetrafs_apply_pending_free(struct super_block *sb, u64 lba, u32 count, u32 expect_zg, u64 stamp)
{
    struct cetrafs_bg_geom bg;
    u64 data_start, bit, b, freed = 0, total = 0;
    struct cetrafs_bmap_hold fh = {0}; /* the bitmap block the loop holds */
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

    /* Another Zone Group's group, or nobody's: decided on the device's
     * descriptor, not a cached copy of a group this node does not own. */
    if (bg.owner_zg != expect_zg) {
        ret = cetrafs_read_bg_geom_at(sb, cetrafs_sb_raw(sb), bg_id, cetrafs_sb_bg_desc_lba(sb, bg_id), true, &bg);
        if (ret)
            return ret;
    }
    if (bg.owner_zg != expect_zg) {
        /* A late copy, not damage: the group left this Zone Group since
         * the free was queued. Released, it had no bit set (a release
         * needs it empty); claimed again, by any Zone Group, its claim
         * raised free_gen past the stamp. Either way the blocks named
         * are not this queue's to free -- dropped, as a stale stamp is
         * below. Counting it as corruption raised needs-fsck and, under
         * corruption=stop, stopped the node (audit 2026-11-15 M-7/BM-1).
         * Only a copy stamped with the current owner's own tenure is a
         * free no queue of ours could hold. */
        if (!READ_ONCE(cetrafs_pf_late_copy_corrupt) &&
            (bg.owner_zg == CETRAFS_BG_OWNER_FREE || bg.free_gen != stamp)) {
            atomic64_inc(&cetrafs_pf_stale_drops);
            pr_warn_ratelimited("pending free [%llu +%u) from ZG %u's queue names BG %u, now %s (stamp %llu, "
                                "group at %llu): a late copy from before it left -- dropped\n",
                                (unsigned long long) lba, count, expect_zg, bg_id,
                                bg.owner_zg == CETRAFS_BG_OWNER_FREE ? "unowned" : "another Zone Group's",
                                (unsigned long long) stamp, (unsigned long long) bg.free_gen);
            return 1;
        }
        pr_err("pending free [%llu +%u) names BG %u (ZG %u), but came from ZG %u's queue -- skipping\n",
               (unsigned long long) lba, count, bg_id, bg.owner_zg, expect_zg);
        cetrafs_sb_corrupt(sb, 0);
        return -EINVAL;
    }

    data_start = bg.start_block + bg.off_data_region;
    if (lba + count > data_start + bg.data_block_count) {
        pr_err("pending free [%llu +%u) crosses out of BG %u -- skipping\n", (unsigned long long) lba, count, bg_id);
        cetrafs_sb_corrupt(sb, 0);
        return -EINVAL;
    }

    bit = lba - data_start;

    cetrafs_sb_alloc_lock(sb);
    if (cetrafs_sb_is_fenced(sb)) {
        cetrafs_sb_alloc_unlock(sb);
        return -EIO;
    }
    if (!cetrafs_pf_apply_still_ours(sb, bg_id, expect_zg, lba, count)) {
        cetrafs_sb_alloc_unlock(sb);
        return 1;
    }
    {
        struct cetrafs_bg_geom now;

        ret = cetrafs_read_bg_geom(sb, bg_id, &now);
        if (ret) {
            cetrafs_sb_alloc_unlock(sb);
            return ret;
        }
        if (now.free_gen != stamp && !READ_ONCE(cetrafs_pf_ignore_stamp)) {
            cetrafs_sb_alloc_unlock(sb);
            atomic64_inc(&cetrafs_pf_stale_drops);
            pr_warn_ratelimited("pending free [%llu +%u) is stamped %llu, BG %u is at %llu: a copy from before a "
                                "reclaim there -- dropped, its blocks stay allocated for the scrub\n",
                                (unsigned long long) lba, count, (unsigned long long) stamp, bg_id,
                                (unsigned long long) now.free_gen);
            ctrace("PFSTALE lba=%llu count=%u stamp=%llu gen=%llu\n", (unsigned long long) lba, count,
                   (unsigned long long) stamp, (unsigned long long) now.free_gen);
            return 1;
        }
    }
    for (b = 0; b < count; b++) {
        bool set = false;

        /* An entry is one freed extent, up to a whole Block Group, and
         * one hold of alloc_mutex across it stalled every allocating
         * write on this node for the whole apply -- 100 ms per 1 GiB
         * entry, back to back through a drain (audit 2026-11-14 P1).
         * Let go between chunks, as the direct free does, the chunk's
         * credit taken first. After relocking, the stamp and the owner
         * are re-checked: the scrub raises free_gen before it frees
         * here, so an apply that finds it moved stops, and the bits not
         * yet cleared stay set -- a leak the scrub reclaims, never a
         * block freed twice. Nothing else can reach them meanwhile: set
         * bits are not allocated, and a group with set bits is not
         * released. */
        if (b && !(b & 4095) && !READ_ONCE(cetrafs_pf_apply_one_hold)) {
            struct cetrafs_bg_geom now;

            cetrafs_bmap_hold_end(sb, &fh); /* never held across the unlock */
            if (freed) {
                cetrafs_bg_adjust_free_blocks(sb, bg_id, (s64) freed);
                total += freed;
                freed = 0;
            }
            cetrafs_sb_alloc_unlock(sb);
            cond_resched();
            cetrafs_sb_alloc_lock(sb);
            if (cetrafs_sb_is_fenced(sb)) {
                ret = -EIO;
                break;
            }
            if (!cetrafs_pf_apply_still_ours(sb, bg_id, expect_zg, lba, count)) {
                ret = 1;
                break;
            }
            ret = cetrafs_read_bg_geom(sb, bg_id, &now);
            if (ret)
                break;
            if (now.owner_zg != expect_zg ||
                (now.free_gen != stamp && !READ_ONCE(cetrafs_pf_ignore_stamp))) {
                atomic64_inc(&cetrafs_pf_stale_drops);
                pr_warn_ratelimited("pending free [%llu +%u): BG %u changed under the apply (owner ZG %u, gen "
                                    "%llu) -- the rest dropped, its blocks stay allocated for the scrub\n",
                                    (unsigned long long) lba, count, bg_id, now.owner_zg,
                                    (unsigned long long) now.free_gen);
                ret = 1;
                break;
            }
        } else if (!(b & 4095)) {
            cond_resched(); /* class 13 */
        }
        if (cetrafs_sb_trim_holds(sb, lba + b))
            continue; /* free before a FITRIM claimed it: as already free (cetrafs_trim_claim_next()) */
        if (READ_ONCE(cetrafs_pf_apply_per_bit)) { /* test-only: the old per-bit lookups */
            ret = cetrafs_bitmap_test_bit(sb, bg.start_block + bg.off_data_bmap,
                                          bg.off_data_region - bg.off_data_bmap, bit + b, &set);
            if (ret)
                break;
            atomic64_inc(&cetrafs_pf_apply_bmap_lookups);
            if (!set)
                continue; /* already free: re-applied entry, or double-queued -- skip the count too */
            ret = cetrafs_bitmap_free_bit(sb, bg.start_block + bg.off_data_bmap,
                                          bg.off_data_region - bg.off_data_bmap, bit + b, /*sync=*/false);
            if (ret)
                break;
            atomic64_inc(&cetrafs_pf_apply_bmap_lookups);
        } else {
            /* One lookup and one buffer-lock hold per bitmap block, as
             * the direct free (__cetrafs_free_data_extent(), audit P2):
             * the test and the clear under the buffer lock, nothing in
             * the loop sleeping on I/O while it is held, the hold ended
             * at every block change and before alloc_mutex is let go. */
            u64 off;

            ret = cetrafs_bmap_hold_at(sb, &fh, bg.start_block + bg.off_data_bmap,
                                       bg.off_data_region - bg.off_data_bmap, bit + b, &off,
                                       &cetrafs_pf_apply_bmap_lookups);
            if (ret)
                break;
            if (!cetrafs_bmap_hold_flip(&fh, off, false))
                continue; /* already free: re-applied entry, or double-queued -- skip the count too */
        }
        cetrafs_shadow_clear(sb, lba + b, 1, "free_data_extent");
        freed++;
    }
    cetrafs_bmap_hold_end(sb, &fh);
    if (freed)
        cetrafs_bg_adjust_free_blocks(sb, bg_id, (s64) freed);
    total += freed;
    cetrafs_sb_alloc_unlock(sb);
    if (total)
        cetrafs_inline_discard_note(sb, bg_id, lba, count); /* -o discard: queued, never issued here */

    ctrace("BLKAPPLY lba=%llu count=%u freed=%llu zg=%u\n", (unsigned long long) lba, count, (unsigned long long) total,
           expect_zg);
    return ret;
}

struct cetrafs_bg_gen_ctx {
    u64 out_gen; /* the value the committed image carries */
    u32 expect_zg; /* the owner the caller judged the group by */
};

static int cetrafs_bg_gen_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_bg_gen_ctx *ctx = priv;
    cetrafs_block_group_t *bg = (cetrafs_block_group_t *) image;

    if (!cetrafs_bg_image_ok(image, len))
        return -EUCLEAN;
    /* Not the group the caller judged any more: its new owner's
     * descriptor is not ours to touch (audit BC-17). */
    if (le16_to_cpu(bg->owner_zg) != ctx->expect_zg)
        return -EAGAIN;
    bg->free_gen = cetrafs_cpu_to_le64(cetrafs_le64(bg->free_gen) + 1);
    ctx->out_gen = cetrafs_le64(bg->free_gen);
    memset((u8 *) image + offsetof(cetrafs_block_group_t, pad), 0, len - offsetof(cetrafs_block_group_t, pad));
    bg->checksum = cetrafs_cpu_to_le64(0);
    bg->checksum = cetrafs_cpu_to_le64(cetrafs_bg_image_crc(image, len));
    return 0;
}

/* TEST ONLY: the scrub reclaims without raising free_gen first. */
static bool cetrafs_scrub_skip_gen_bump;
cetrafs_test_param(scrub_skip_gen_bump, cetrafs_scrub_skip_gen_bump, bool, 0644);
MODULE_PARM_DESC(scrub_skip_gen_bump, "TEST ONLY: the scrub frees leaks without bumping the group's free_gen");

static atomic64_t cetrafs_bg_gen_bumps = ATOMIC64_INIT(0);

u64 cetrafs_bg_gen_bump_count(void)
{
    return (u64) atomic64_read(&cetrafs_bg_gen_bumps);
}

/*
 * Raise Block Group bg_id's free_gen, before the scrub reclaims a leak in
 * it (rule 21: the publish first, then the free). Every pending-free
 * entry stamped before this lands is dropped by the drain from here on
 * -- which is what makes a copy whose swap reaches the device late, after
 * the reclaim and the block's next allocation, harmless. The same seeded
 * record swap the free-count flush uses: it commits by COMPARE AND WRITE
 * and refreshes this node's cached descriptor with the image it wrote,
 * so the drain's check (cetrafs_apply_pending_free()) reads the new value
 * the moment this returns. An outcome that is not known is an error: the
 * caller frees nothing.
 */
int cetrafs_bg_bump_free_gen(struct super_block *sb, u32 bg_id, u32 expect_zg)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct cetrafs_bg_gen_ctx ctx = {.expect_zg = expect_zg};
    unsigned int region;
    struct buffer_head *bh;
    u8 *seed;
    int ret;

    if (!raw_sb || bg_id >= le32_to_cpu(raw_sb->block_group_count))
        return -EINVAL;
    if (READ_ONCE(cetrafs_scrub_skip_gen_bump))
        return 0; /* TEST ONLY: see the parameter */
    region = cetrafs_cas_region_size(sb);
    bh = cetrafs_bread_retry(sb, cetrafs_sb_bg_desc_lba(sb, bg_id));
    seed = bh ? kmalloc(region, GFP_NOFS) : NULL;
    if (seed)
        cetrafs_bh_snapshot(bh, seed, region, offsetof(cetrafs_block_group_t, checksum), 0, false);
    ret = cetrafs_cas_record_seeded(sb, cetrafs_sb_bg_desc_lba(sb, bg_id), seed, seed ? region : 0,
                                    cetrafs_bg_gen_mutate, &ctx);
    kfree(seed);
    if (bh)
        brelse(bh);
    if (ret < 0)
        return ret;
    atomic64_inc(&cetrafs_bg_gen_bumps);
    ctrace("BGGEN bg=%u gen=%llu\n", bg_id, (unsigned long long) ctx.out_gen);
    return 0;
}

/* Count free inodes in the global inode bitmap, for statfs. */
int cetrafs_count_free_inodes(struct super_block *sb, u64 *out_free)
{
    u32 n, i;
    const struct cetrafs_iseg *s = cetrafs_sb_isegs(sb, &n);

    if (!s)
        return -EINVAL;
    *out_free = 0;
    for (i = 0; i < n; i++) {
        long free = cetrafs_bitmap_count_free(sb, s[i].bmap, cetrafs_iseg_bmap_blocks(&s[i]), s[i].count);

        if (free < 0)
            return (int) free;
        *out_free += free;
    }
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
/* TEST ONLY: one-shot pause between a reconcile's recount and its write,
 * so a free or an allocation can be driven into that window
 * (tests/kernel/reconcile_vs_free.sh). */
static unsigned int cetrafs_reconcile_pause_ms;
cetrafs_test_param(reconcile_pause_ms, cetrafs_reconcile_pause_ms, uint, 0644);
MODULE_PARM_DESC(reconcile_pause_ms, "TEST ONLY: one-shot pause between a free-count recount and its write");

/* TEST ONLY: a recount pauses once its write has landed, before the
 * accrued delta it replaces is gone (tests/kernel/bg_flush_inflight_count.sh);
 * and the recount runs without its flight -- the old order, the control. */
static unsigned int cetrafs_reconcile_written_stall_ms;
cetrafs_test_param(reconcile_written_stall_ms, cetrafs_reconcile_written_stall_ms, uint, 0644);
MODULE_PARM_DESC(reconcile_written_stall_ms, "TEST ONLY: one recount pauses after its write, before its delta drop");
static bool cetrafs_reconcile_flight_off;
cetrafs_test_param(reconcile_flight_off, cetrafs_reconcile_flight_off, bool, 0644);
MODULE_PARM_DESC(reconcile_flight_off, "TEST ONLY: a recount writes without a flight (the old order)");

/* TEST ONLY: a Zone Group recount reads each bitmap block alone and holds
 * alloc_mutex, as before audit 2026-11-14 P3 -- the control of
 * tests/kernel/zg_reconcile_batched.sh. */
static bool cetrafs_reconcile_serial;
cetrafs_test_param(reconcile_serial, cetrafs_reconcile_serial, bool, 0644);
MODULE_PARM_DESC(reconcile_serial, "TEST ONLY: a Zone Group recount reads its bitmaps one block at a time");

/*
 * Read Block Group 'bg_id's data bitmap forced-fresh as ONE batch
 * (cetrafs_bread_uncached_batch()), leaving it in the cache for the
 * recount that follows: one device round trip instead of one per bitmap
 * block. The recount at a Zone Group claim paid eight serial reads per
 * group, ~3 minutes per Zone Group at 64 TiB (audit 2026-11-14 P3).
 * Best effort: on any failure the recount reads the blocks itself.
 */
void cetrafs_bg_prefetch_bitmap(struct super_block *sb, u32 bg_id)
{
    struct cetrafs_bg_geom bg;
    struct buffer_head **bhs;
    u32 n, i;

    if (READ_ONCE(cetrafs_reconcile_serial) || cetrafs_read_bg_geom(sb, bg_id, &bg))
        return;
    n = (u32) min_t(u64, bg.off_data_region - bg.off_data_bmap, 4096);
    bhs = kvcalloc(n, sizeof(*bhs), GFP_KERNEL);
    if (!bhs)
        return;
    if (!cetrafs_bread_uncached_batch(sb, bg.start_block + bg.off_data_bmap, n, bhs))
        for (i = 0; i < n; i++)
            brelse(bhs[i]);
    kvfree(bhs);
}

static int cetrafs_reconcile_locked(struct super_block *sb, u32 bg_id, s64 *out_delta, bool keep_epoch);

/*
 * The recount of a member of a Zone Group this node has not cached yet
 * (a claim, a steal, the mount's re-attach): nothing allocates from it,
 * frees into it go to its queue, the drain and the scrub skip it -- all
 * of them ask cetrafs_sb_zg_owned_cached() -- so nothing accrues a delta
 * for it, and alloc_mutex, which every other recount holds against
 * exactly those, would only stall this node's allocating writes for the
 * CAW's round trip (audit 2026-11-14 P3). Refused, as a programming
 * error, if the Zone Group IS cached.
 */
int cetrafs_bg_reconcile_free_count_uncached(struct super_block *sb, u32 bg_id, u32 zg_id, s64 *out_delta,
                                             bool keep_epoch)
{
    if (out_delta)
        *out_delta = 0;
    if (READ_ONCE(cetrafs_reconcile_serial))
        return cetrafs_bg_reconcile_free_count(sb, bg_id, out_delta, keep_epoch);
    if (WARN_ON_ONCE(cetrafs_sb_zg_owned_cached(sb, zg_id)))
        return cetrafs_bg_reconcile_free_count(sb, bg_id, out_delta, keep_epoch);
    return cetrafs_reconcile_locked(sb, bg_id, out_delta, keep_epoch);
}

int cetrafs_bg_reconcile_free_count(struct super_block *sb, u32 bg_id, s64 *out_delta, bool keep_epoch)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    int ret;

    if (out_delta)
        *out_delta = 0;
    if (!raw_sb)
        return -EINVAL;

    /* Under alloc_mutex, from the recount to the epoch reset. Every
     * local bitmap change and the delta it accrues happen under it
     * (cetrafs_bg_adjust_free_blocks()'s callers), and the epoch reset
     * below DROPS whatever delta has accrued: an allocation landing
     * between the recount and the reset was in neither, and the count
     * stayed off by it for good. The callers run at ownership transfer
     * and after an ENOSPC, never on the per-block path. */
    cetrafs_sb_alloc_lock(sb);
    ret = cetrafs_reconcile_locked(sb, bg_id, out_delta, keep_epoch);
    cetrafs_sb_alloc_unlock(sb);
    return ret;
}

static int __cetrafs_reconcile_locked(struct super_block *sb, u32 bg_id, s64 *out_delta, bool keep_epoch);

/* Recounts that kept a matching count's epoch without a swap (procfs
 * info reconcile_epoch_kept). */
static atomic64_t cetrafs_reconcile_epoch_kept = ATOMIC64_INIT(0);

u64 cetrafs_reconcile_epoch_kept_count(void)
{
    return (u64) atomic64_read(&cetrafs_reconcile_epoch_kept);
}

/* Under the flush right: the recount's write is a flight like a flush's
 * (cetrafs_bg_chunk.bg_flight_gen) -- see the swap below -- and two
 * writers of one descriptor's count never overlap. */
static int cetrafs_reconcile_locked(struct super_block *sb, u32 bg_id, s64 *out_delta, bool keep_epoch)
{
    int ret = cetrafs_sb_bg_flush_lock(sb, bg_id);

    if (ret)
        return ret;
    ret = __cetrafs_reconcile_locked(sb, bg_id, out_delta, keep_epoch);
    cetrafs_sb_bg_flush_unlock(sb, bg_id);
    return ret;
}

/* TEST ONLY: the ENOSPC recount corrects the Block Group and leaves its
 * Zone Group's aggregate alone, as before audit 2026-11-14 A6 -- the
 * control of tests/kernel/enospc_recount_aggregate.sh. */
static bool cetrafs_recount_agg_off;
cetrafs_test_param(recount_agg_off, cetrafs_recount_agg_off, bool, 0644);
MODULE_PARM_DESC(recount_agg_off, "TEST ONLY: an ENOSPC recount does not correct the Zone Group aggregate");

/* TEST ONLY: the ENOSPC recount holds alloc_mutex across its descriptor
 * write, as before the flight narrowing (audit 2026-11-14 A6, remainder):
 * the control of tests/kernel/enospc_recount_concurrent.sh. */
static bool cetrafs_recount_hold_alloc;
cetrafs_test_param(recount_hold_alloc, cetrafs_recount_hold_alloc, bool, 0644);
MODULE_PARM_DESC(recount_hold_alloc, "TEST ONLY: an ENOSPC recount holds alloc_mutex across its descriptor write");
/* TEST ONLY: an ENOSPC recount's epoch move drops the delta accrued
 * during its flight, as the move did before: the negative control of
 * the same suite -- the exactness check must catch the loss. */
static bool cetrafs_recount_inflight_drop;
cetrafs_test_param(recount_inflight_drop, cetrafs_recount_inflight_drop, bool, 0644);
MODULE_PARM_DESC(recount_inflight_drop, "TEST ONLY: an ENOSPC recount drops the delta accrued during its flight");

/*
 * The recount after an allocation found a Block Group full that its
 * count called free. The aggregate of its Zone Group summed the same
 * wrong count, and is corrected by the same amount: the truth less what
 * the group's count stood at, its taken accrual included (that was in
 * the aggregate too). fsck's aggregate check failed until the next
 * ownership transfer otherwise (audit 2026-11-14 A6).
 *
 * alloc_mutex covers the count and the take of the delta the count
 * already holds -- the two must see the same bitmap -- and nothing
 * else. The descriptor write runs as a flight (class 52) with the
 * flush right held and the mutex dropped: an allocation or a free
 * landing meanwhile moves the bitmap after the count, so it accrues
 * into the delta that is still there, and the epoch move keeps it
 * (cetrafs_sb_set_bg_epoch_keep()). Dropping it would leave the
 * descriptor short of the bitmap by that much -- the negative control.
 */
int cetrafs_bg_recount_after_enospc(struct super_block *sb, u32 bg_id, s64 *out_delta)
{
    struct cetrafs_bg_geom bg;
    struct cetrafs_bg_count_ctx ctx = {.absolute = true, .bg_id = bg_id};
    u64 bmap_lba, bmap_blocks;
    bool alloc_held = true, flight, hold, drop;
    long truth;
    s64 delta = 0, taken = 0, dropped = 0, agg = 0;
    u32 zg;
    int ret;

    if (out_delta)
        *out_delta = 0;
    if (!cetrafs_sb_raw(sb))
        return -EINVAL;

    cetrafs_sb_alloc_lock(sb);
    ret = cetrafs_sb_bg_flush_lock(sb, bg_id);
    if (ret)
        goto unlock_alloc;
    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        goto put_flush;
    bmap_lba = bg.start_block + bg.off_data_bmap;
    bmap_blocks = bg.off_data_region - bg.off_data_bmap;
    truth = cetrafs_bitmap_count_free(sb, bmap_lba, bmap_blocks, bg.data_block_count);
    if (truth < 0) {
        ret = (int) truth;
        goto put_flush;
    }
    delta = (s64) truth - (s64) bg.free_data_blocks;
    if (delta)
        /* Loud: this is a real inconsistency being repaired, not routine
         * bookkeeping, and the size of the drift is the only evidence
         * left of what the crash cost. */
        pr_warn("BG %u: cached free_data_blocks=%llu but its bitmap says %ld -- correcting (drift %lld)\n", bg_id,
                bg.free_data_blocks, truth, delta);

    /* class 52: the count and the delta it already holds are taken
     * together, under the mutex that makes every accrual. From here the
     * accrued delta is in the flight's value, and anything accrued after
     * it is in the delta still. */
    flight = !READ_ONCE(cetrafs_reconcile_flight_off);
    hold = !flight || READ_ONCE(cetrafs_recount_hold_alloc);
    drop = !flight || READ_ONCE(cetrafs_recount_inflight_drop);
    if (flight)
        taken = cetrafs_sb_bg_flight_begin_value(sb, bg_id, (s64) truth);
    if (!hold) {
        cetrafs_sb_alloc_unlock(sb);
        alloc_held = false;
    }
    {
        unsigned int pause = xchg(&cetrafs_reconcile_pause_ms, 0);

        if (pause) {
            pr_info("reconcile: BG %u recounted, pausing %u ms (test)\n", bg_id, pause);
            msleep(pause); /* test-only; see the parameter */
        }
    }

    /* The write: a compare-and-swap that also ADVANCES the ownership
     * epoch (see cetrafs_bg_count_mutate()). */
    ctx.value = truth;
    ret = cetrafs_cas_record_seeded(sb, cetrafs_sb_bg_desc_lba(sb, bg_id), NULL, 0, cetrafs_bg_count_mutate, &ctx);
    if (ret) {
        if (flight)
            cetrafs_sb_bg_flight_settle_end(sb, bg_id, taken); /* not recounted: the delta still stands */
        goto put_flush;
    }
    {
        unsigned int pause = xchg(&cetrafs_reconcile_written_stall_ms, 0);

        if (pause) {
            pr_info("reconcile: BG %u written, pausing %u ms (test)\n", bg_id, pause);
            msleep(pause); /* test-only; see the parameter */
        }
    }
    if (taken && drop)
        pr_warn("BG %u: dropping an accrued free delta of %lld -- the count was recounted (epoch -> %llu)\n", bg_id,
                (long long) taken, (unsigned long long) ctx.out_seq);
    /* Deltas accrued from here on belong to the fresh epoch. The move
     * drops what is still accrued only when it has to (no flight: the
     * mutex was held throughout, so nothing else is in it, and the
     * control keeps the drop). */
    if (drop)
        dropped = cetrafs_sb_set_bg_epoch(sb, bg_id, ctx.out_seq);
    else
        cetrafs_sb_set_bg_epoch_keep(sb, bg_id, ctx.out_seq);
    if (flight)
        cetrafs_sb_bg_flight_settle_end(sb, bg_id, 0);
    /* What the aggregate summed for this group moved by the truth less
     * what the count stood at, its taken accrual included, and less any
     * accrual dropped by the move. */
    agg = delta - taken - dropped;

put_flush:
    cetrafs_sb_bg_flush_unlock(sb, bg_id);
    if (ret)
        goto unlock_alloc;
    /* The aggregate is corrected under the mutex: the owner must not
     * change between reading it and accruing into it. */
    if (!alloc_held) {
        cetrafs_sb_alloc_lock(sb);
        alloc_held = true;
    }
    if (delta > 0)
        cetrafs_sb_set_release_check(sb, bg_id, true); /* recounted up: it may be empty */
    if (agg && !READ_ONCE(cetrafs_recount_agg_off)) {
        zg = cetrafs_sb_bg_owner(sb, bg_id);
        if (zg != CETRAFS_BG_OWNER_FREE)
            cetrafs_zg_adjust_free_blocks(sb, zg, agg);
    }
    if (out_delta)
        *out_delta = delta;

unlock_alloc:
    if (alloc_held)
        cetrafs_sb_alloc_unlock(sb);
    return ret;
}

static int __cetrafs_reconcile_locked(struct super_block *sb, u32 bg_id, s64 *out_delta, bool keep_epoch)
{
    struct cetrafs_bg_geom bg;
    u64 bmap_lba, bmap_blocks;
    long truth;
    s64 delta;
    int ret;

    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;

    bmap_lba = bg.start_block + bg.off_data_bmap;
    bmap_blocks = bg.off_data_region - bg.off_data_bmap;
    truth = cetrafs_bitmap_count_free(sb, bmap_lba, bmap_blocks, bg.data_block_count);
    if (truth < 0)
        return (int) truth;
    {
        unsigned int pause = xchg(&cetrafs_reconcile_pause_ms, 0);

        if (pause) {
            pr_info("reconcile: BG %u recounted, pausing %u ms (test)\n", bg_id, pause);
            msleep(pause); /* test-only; see the parameter */
        }
    }

    delta = (s64) truth - (s64) bg.free_data_blocks;
    if (delta)
        /* Loud: this is a real inconsistency being repaired, not routine
         * bookkeeping, and the size of the drift is the only evidence
         * left of what the crash cost. */
        pr_warn("BG %u: cached free_data_blocks=%llu but its bitmap says %ld -- correcting (drift %lld)\n", bg_id,
                bg.free_data_blocks, truth, delta);

    /* The previous owner flushed every delta before it gave this group
     * up (a clean departure, or a release, which refuses while one is
     * outstanding -- the caller decides): nothing can arrive late, so a
     * count that matches its bitmap keeps its epoch, and costs no swap.
     * One CAW per Block Group was ~2.5 min per Zone Group on a 64 TiB
     * re-attach (P3). Nothing of ours is accrued for a group not yet
     * cached; if anything is, the swap below runs as before. */
    if (keep_epoch && !delta && !cetrafs_sb_bg_delta_pending(sb, bg_id)) {
        atomic64_inc(&cetrafs_reconcile_epoch_kept);
        cetrafs_sb_set_bg_epoch(sb, bg_id, bg.reconcile_seq);
        if (out_delta)
            *out_delta = 0;
        return 0;
    }

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
        s64 taken;

        /* class 52: the accrued delta is already in the truth, and the
         * cached descriptor takes the truth when the swap lands -- so the
         * delta must leave memory in that same instant, or a reader adds
         * it twice and the group reads fuller than it is. As a flight:
         * readers take the truth from here until the swap is back, and
         * the delta is gone from memory from here too. Nothing accrues
         * meanwhile: the caller holds alloc_mutex, under which every
         * accrual happens. */
        bool flight = !READ_ONCE(cetrafs_reconcile_flight_off);

        taken = flight ? cetrafs_sb_bg_flight_begin_value(sb, bg_id, (s64) truth) : 0;
        ret = cetrafs_cas_record_seeded(sb, cetrafs_sb_bg_desc_lba(sb, bg_id), NULL, 0, cetrafs_bg_count_mutate, &ctx);
        if (ret) {
            if (flight)
                cetrafs_sb_bg_flight_settle_end(sb, bg_id, taken); /* not recounted: the delta still stands */
            return ret;
        }
        {
            unsigned int pause = xchg(&cetrafs_reconcile_written_stall_ms, 0);

            if (pause) {
                pr_info("reconcile: BG %u written, pausing %u ms (test)\n", bg_id, pause);
                msleep(pause); /* test-only; see the parameter */
            }
        }
        if (taken)
            pr_warn("BG %u: dropping an accrued free delta of %lld -- the count was recounted (epoch -> %llu)\n",
                    bg_id, (long long) taken, (unsigned long long) ctx.out_seq);
        /* Deltas accrued from here on belong to this fresh epoch. What
         * the aggregate summed for this group was the count plus the
         * accrual dropped: taken by the flight, or (no flight) by this
         * epoch move. */
        cetrafs_sb_set_bg_epoch(sb, bg_id, ctx.out_seq);
        if (flight)
            cetrafs_sb_bg_flight_settle_end(sb, bg_id, 0);
        if (delta > 0)
            cetrafs_sb_set_release_check(sb, bg_id, true); /* recounted up: it may be empty */
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
/* TEST ONLY: a claim leaves free_gen alone, as before audit 2026-11-14
 * A8 -- the control of tests/kernel/bg_claim_free_gen.sh. */
static bool cetrafs_bg_claim_keeps_free_gen;
cetrafs_test_param(bg_claim_keeps_free_gen, cetrafs_bg_claim_keeps_free_gen, bool, 0644);
MODULE_PARM_DESC(bg_claim_keeps_free_gen, "TEST ONLY: claiming a free Block Group does not raise its free_gen");

/* Claim one unowned Block Group into zg_id: the CAS mutate. */
struct cetrafs_bg_claim_ctx {
    u32 zg_id;
    u32 bg_id;
    u64 seq;        /* the count's ownership epoch on the image the claim landed on */
    u16 old_flags;  /* the flags before the claim, for its undo */
};

/* Give back a claim that landed but cannot be used: owner back to the
 * pool, and the discard knowledge the claim cleared restored. Only over
 * our own claim -- anything else is not ours to undo. free_gen keeps its
 * bump: a stamp that drops more late copies is the safe direction. */
static int cetrafs_bg_unclaim_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_bg_claim_ctx *ctx = priv;
    cetrafs_block_group_t *bg = (cetrafs_block_group_t *) image;

    if (!cetrafs_bg_image_ok(image, len))
        return -EUCLEAN;
    if (cetrafs_le16(bg->owner_zg) != ctx->zg_id)
        return -EAGAIN;
    bg->owner_zg = cetrafs_cpu_to_le16(CETRAFS_BG_OWNER_FREE);
    bg->flags = cetrafs_cpu_to_le16(cetrafs_le16(bg->flags) | (ctx->old_flags & CETRAFS_BG_FLAG_DISCARDED));
    memset((u8 *) image + offsetof(cetrafs_block_group_t, pad), 0, len - offsetof(cetrafs_block_group_t, pad));
    bg->checksum = cetrafs_cpu_to_le64(0);
    bg->checksum = cetrafs_cpu_to_le64(cetrafs_bg_image_crc(image, len));
    return 0;
}

/* TEST ONLY: a claim whose bitmap drop fails is kept, owned and out of
 * reach, as before -- the control of tests/kernel/pool_claim_drop_fail.sh. */
static bool cetrafs_pool_claim_undo_off;
cetrafs_test_param(pool_claim_undo_off, cetrafs_pool_claim_undo_off, bool, 0644);
MODULE_PARM_DESC(pool_claim_undo_off, "TEST ONLY: keep a pool claim whose bitmap drop failed instead of undoing it");

static int cetrafs_bg_claim_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_bg_claim_ctx *ctx = priv;
    cetrafs_block_group_t *bg = (cetrafs_block_group_t *) image;

    if (!cetrafs_bg_image_ok(image, len))
        return -EUCLEAN;
    /* Re-read inside the swap. Between the scan that picked this Block
     * Group and this callback, a peer may have claimed it -- the whole
     * point of doing this as one compare-and-swap rather than a
     * read-then-write. Refusing here is how the loser of that race
     * finds out, and it leaves the record exactly as the winner wrote
     * it. */
    if (cetrafs_le16(bg->owner_zg) != CETRAFS_BG_OWNER_FREE)
        return -EAGAIN;
    /* A group in the pool never carries an outstanding discard -- the
     * release that frees it is what clears the flag -- so this is damage;
     * refused all the same, since taking it would put data where an
     * UNMAP may still land. */
    if (cetrafs_le16(bg->flags) & CETRAFS_BG_FLAG_DISCARD_PENDING)
        return -EAGAIN;

    ctx->seq = cetrafs_le64(bg->reconcile_seq);
    ctx->old_flags = cetrafs_le16(bg->flags);
    bg->owner_zg = cetrafs_cpu_to_le16((u16) ctx->zg_id);
    /* A new tenure: a queued free stamped before it -- a late copy from
     * before the release, from the same Zone Group or any -- names
     * blocks this claim may hand out again, and must be dropped, not
     * applied (audit 2026-11-14 A8; cetrafs_apply_pending_free()). */
    if (!READ_ONCE(cetrafs_bg_claim_keeps_free_gen))
        bg->free_gen = cetrafs_cpu_to_le64(cetrafs_le64(bg->free_gen) + 1);
    /* Ours now, and we may write anywhere in it. */
    bg->flags = cetrafs_cpu_to_le16(cetrafs_le16(bg->flags) & ~CETRAFS_BG_FLAG_DISCARDED);
    /* Same normalise-then-checksum as cetrafs_bg_count_mutate(): the
     * in-sector tail past the real fields is zero by construction, and
     * cetrafs_bg_image_crc() rests on that. */
    memset((u8 *) image + offsetof(cetrafs_block_group_t, pad), 0, len - offsetof(cetrafs_block_group_t, pad));
    bg->checksum = cetrafs_cpu_to_le64(0);
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
cetrafs_test_param(bg_claim_blind, cetrafs_bg_claim_blind, bool, 0644);
MODULE_PARM_DESC(bg_claim_blind, "test-only: claim a free Block Group with a blind write, not a compare-and-swap");

extern bool cetrafs_bg_release_skip_empty_check;

/* Hand one Block Group back: the CAS mutate. */
struct cetrafs_bg_release_ctx {
    u32 zg_id;
    bool discarded; /* its hand-back discard succeeded: mark it DISCARDED */
};

static int cetrafs_bg_release_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_bg_release_ctx *ctx = priv;
    cetrafs_block_group_t *bg = (cetrafs_block_group_t *) image;

    if (!cetrafs_bg_image_ok(image, len))
        return -EUCLEAN;
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
    /* Only a discard whose outcome is known gets a group this far, so an
     * outstanding one is settled now, in the same swap that frees it. */
    bg->flags = cetrafs_cpu_to_le16(cetrafs_le16(bg->flags) & ~CETRAFS_BG_FLAG_DISCARD_PENDING);
    if (ctx->discarded)
        bg->flags = cetrafs_cpu_to_le16(cetrafs_le16(bg->flags) | CETRAFS_BG_FLAG_DISCARDED);
    else
        bg->flags = cetrafs_cpu_to_le16(cetrafs_le16(bg->flags) & ~CETRAFS_BG_FLAG_DISCARDED);
    memset((u8 *) image + offsetof(cetrafs_block_group_t, pad), 0, len - offsetof(cetrafs_block_group_t, pad));
    bg->checksum = cetrafs_cpu_to_le64(0);
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
 * clearing the Block Group from owned_bgs BEFORE looking. The allocator
 * CHOOSES from owned_bgs outside alloc_mutex, so clearing the bit alone
 * did not stop an allocation that had already chosen this group; what
 * does is that every allocator re-tests the bit under alloc_mutex, the
 * mutex the drain clears it under (cetrafs_alloc_bg_gone()). If the
 * release then fails, the bit goes back.
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
cetrafs_test_param(bg_release_skip_empty_check, cetrafs_bg_release_skip_empty_check, bool, 0644);
MODULE_PARM_DESC(bg_release_skip_empty_check, "test-only: hand back a Block Group without checking it is empty");

/*
 * Test-only: skip the release's bitmap scan, so a suite can show that
 * the count checks and the scan are each what refuses a Block Group with
 * data in it (bg_release_empty.sh turns both off; bg_release_safety.sh
 * only the count checks).
 */
static bool cetrafs_bg_release_skip_bitmap_scan;
cetrafs_test_param(bg_release_skip_bitmap_scan, cetrafs_bg_release_skip_bitmap_scan, bool, 0644);
MODULE_PARM_DESC(bg_release_skip_bitmap_scan, "test-only: hand back a Block Group without scanning its bitmap");

/*
 * The last word before a Block Group is handed back, run under the
 * drain (no local allocation can land in it).
 *
 * The BITMAP decides it is empty: the free count is a cache, and a cache
 * feeding the destructive direction of a decision is rule 6's case -- a
 * count one too high released live data to whoever claimed next.
 *
 * And the bitmap must be ON THE DEVICE before the release CAS: frees
 * clear bits with sync=false, so this node's cached block can be dirty,
 * and the claimer reads the device. Worse than a stale read, our later
 * writeback would put our image back over the claimer's allocations.
 * Synced here, the blocks are clean and can be dropped after the CAS
 * (cetrafs_bg_release_drop_bitmap()). tests/kernel/bg_release_safety.sh.
 *
 * And no entry of this node's journal may still be live for a block in
 * it (cetrafs_journal_settle_range(); release_journal_settled.sh).
 */
int cetrafs_bg_release_bitmap_ready(struct super_block *sb, u32 b)
{
    struct cetrafs_bg_geom bg;
    u64 lba, blk, nblocks;
    int ret;

    ret = cetrafs_read_bg_geom(sb, b, &bg);
    if (ret)
        return ret;
    if (bg.off_data_region <= bg.off_data_bmap)
        return -EUCLEAN;
    lba = bg.start_block + bg.off_data_bmap;
    nblocks = (u64) bg.off_data_region - bg.off_data_bmap;

    if (!READ_ONCE(cetrafs_bg_release_skip_bitmap_scan)) {
        long free = cetrafs_bitmap_count_free(sb, lba, nblocks, bg.data_block_count);

        if (free < 0)
            return (int) free;
        if ((u64) free != bg.data_block_count) {
            pr_warn_ratelimited("BG %u: count says empty, bitmap has %llu block(s) in use -- not released\n", b,
                                (unsigned long long) (bg.data_block_count - (u64) free));
            return -EBUSY;
        }
    }
    for (blk = 0; blk < nblocks; blk++) {
        cond_resched();
        ret = cetrafs_sync_one_block(sb, lba + blk);
        if (ret)
            return ret;
    }
    /* Nor may an entry of our journal stay live for a block of it: the
     * next owner reuses those blocks without replaying our journal. */
    return cetrafs_journal_settle_range(sb, bg.start_block, bg.length_blocks);
}

/* After the release CAS: our copy of a bitmap we no longer own must not
 * be served again -- a later claim would allocate from it, over whatever
 * the owner in between did. Clean (synced above), so droppable. */
void cetrafs_bg_release_drop_bitmap(struct super_block *sb, u32 b)
{
    struct cetrafs_bg_geom bg;
    u64 blk;

    if (cetrafs_read_bg_geom(sb, b, &bg) || bg.off_data_region <= bg.off_data_bmap)
        return;
    for (blk = 0; blk < (u64) bg.off_data_region - bg.off_data_bmap; blk++) {
        cond_resched();
        /*
         * Forgotten, dirty or not. The group is the next owner's from the
         * CAS on, and everything of ours in its bitmap was synced before
         * it (cetrafs_bg_release_bitmap_ready()): a block dirty NOW holds
         * nothing to keep, and invalidating refuses a dirty buffer --
         * which left it for writeback to lay over the next owner's
         * bitmap (audit 2026-11-14 A-3).
         */
        if (READ_ONCE(cetrafs_noop_free_dirties))
            cetrafs_invalidate_block(sb, bg.start_block + bg.off_data_bmap + blk); /* test-only: the old drop */
        else
            cetrafs_forget_block(sb, bg.start_block + bg.off_data_bmap + blk);
    }
}

/*
 * Test-only: no per-Block-Group release at all. It runs first on every
 * tick and hands back each empty member before the Zone Group release
 * looks, so the latter's own handover of member bitmaps is reachable in
 * a test only with this off (bg_release_safety.sh, part C).
 */
static bool cetrafs_bg_release_off;
cetrafs_test_param(bg_release_off, cetrafs_bg_release_off, bool, 0644);
MODULE_PARM_DESC(bg_release_off, "test-only: never hand back individual Block Groups");

/*
 * Test-only: hold a release after the Block Group reads FREE (on the
 * device and in-core) and before it returns -- the window a claimant's
 * pool debit lands in (bg_release_pool_order.sh). bg_release_credit_late
 * restores the old order, counters moved only after that window, as the
 * suite's control.
 */
/* TEST ONLY: the next Block Group release frees one already-free block
 * of the group after its bitmap is synced and before its CAS -- the
 * duplicate free audit 2026-11-14 A-3 is about, at the one moment it
 * matters (tests/kernel/release_noop_free_clean.sh). One-shot. */
static bool cetrafs_release_noop_free;
cetrafs_test_param(release_noop_free, cetrafs_release_noop_free, bool, 0644);
MODULE_PARM_DESC(release_noop_free, "TEST ONLY: the next Block Group release frees an already-free block before its CAS");

static unsigned int cetrafs_bg_release_stall_ms;
cetrafs_test_param(bg_release_stall_ms, cetrafs_bg_release_stall_ms, uint, 0644);
MODULE_PARM_DESC(bg_release_stall_ms, "test-only: stall a Block Group release after it reads FREE");
static bool cetrafs_bg_release_credit_late;
cetrafs_test_param(bg_release_credit_late, cetrafs_bg_release_credit_late, bool, 0644);
MODULE_PARM_DESC(bg_release_credit_late, "test-only: move the release's counters after the BG reads FREE (old order)");

/* The release's two counter moves: the owner's aggregate debit and the
 * unowned pool's credit, each by immediate CAS. `sign` -1 undoes them. */
static void cetrafs_bg_release_counters(struct super_block *sb, u32 zg_id, u32 b, u64 total, int sign)
{
    s64 d = sign * (s64) total;

    if (cetrafs_zg_apply_free_delta(sb, zg_id, -d))
        cetrafs_zg_adjust_free_blocks(sb, zg_id, -d); /* lazy fallback: never lose the move */
    if (cetrafs_zg_adjust_pool_blocks(sb, b, d))
        pr_warn("BG %u: pool shard %s failed -- df will %s until fsck\n", b, sign > 0 ? "credit" : "undo",
                sign > 0 ? "understate" : "overstate");
}

/* TEST ONLY: one release pauses with its Block Group drained, before it
 * decides (tests/kernel/release_drain_no_enospc.sh). */
static unsigned int cetrafs_bg_release_drain_stall_ms;
cetrafs_test_param(bg_release_drain_stall_ms, cetrafs_bg_release_drain_stall_ms, uint, 0644);
MODULE_PARM_DESC(bg_release_drain_stall_ms, "test-only: pause one Block Group release while it is drained");

/* TEST ONLY: the hand-back flags its group only after a discard failed,
 * as before (tests/kernel/discard_hold_durable_first.sh's control). */
static bool cetrafs_handback_flag_first_off;
cetrafs_test_param(handback_flag_first_off, cetrafs_handback_flag_first_off, bool, 0644);

struct cetrafs_bg_dpend_ctx {
    u32 zg_id; /* the group must still be this Zone Group's */
    bool on;
};

static int cetrafs_bg_dpend_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_bg_dpend_ctx *ctx = priv;
    cetrafs_block_group_t *bg = (cetrafs_block_group_t *) image;
    u16 f;

    if (!cetrafs_bg_image_ok(image, len))
        return -EUCLEAN;
    if (cetrafs_le16(bg->owner_zg) != ctx->zg_id)
        return -EAGAIN;
    f = cetrafs_le16(bg->flags);
    f = ctx->on ? (f | CETRAFS_BG_FLAG_DISCARD_PENDING) : (f & ~CETRAFS_BG_FLAG_DISCARD_PENDING);
    if (f == cetrafs_le16(bg->flags))
        return 1; /* already so */
    bg->flags = cetrafs_cpu_to_le16(f);
    memset((u8 *) image + offsetof(cetrafs_block_group_t, pad), 0, len - offsetof(cetrafs_block_group_t, pad));
    bg->checksum = cetrafs_cpu_to_le64(0);
    bg->checksum = cetrafs_cpu_to_le64(cetrafs_bg_image_crc(image, len));
    return 0;
}

/* Record (on) or settle Block Group b's outstanding discard on the
 * device, by compare-and-swap of its descriptor. */
static int cetrafs_bg_set_discard_pending_flag(struct super_block *sb, u32 zg_id, u32 b, bool on)
{
    struct cetrafs_bg_dpend_ctx ctx = {.zg_id = zg_id, .on = on};
    int ret;

    ret = cetrafs_cas_record(sb, cetrafs_sb_bg_desc_lba(sb, b), cetrafs_bg_dpend_mutate, &ctx);
    return ret < 0 ? ret : 0;
}

/*
 * Hand back one Block Group of zg_id if it is provably empty: the body of
 * cetrafs_bg_release_empty(), and of FITRIM's pool pass. Returns 1 when
 * it went back to the pool, 0 when it was kept, -EBUSY when it was kept
 * for a later pass (discard budget, or a discard of unknown outcome).
 */
static int cetrafs_bg_release_one(struct super_block *sb, u32 zg_id, u32 b, unsigned long *pass_started, bool force,
                                  bool *out_discarded)
{
    struct cetrafs_bg_release_ctx ctx = {.zg_id = zg_id};
    bool settling = false, flagged;
    u64 total = 0, free = 0;
    int ret;

    /*
     * A group whose hand-back discard had an UNKNOWN outcome (review
     * U1), recorded on the device (CETRAFS_BG_FLAG_DISCARD_PENDING), so
     * this may be a discard this node inherited -- from its own last
     * mount, or from the peer whose Zone Group it took over. It has stayed
     * out of every allocator since, and it was proven empty when the
     * flag was set. Proven empty again BEFORE the discard is re-issued:
     * a flagged group holding data would be destroyed by the re-issue,
     * and that can only be damage, so it is left alone and said.
     * Discard it again; only an outcome we know releases it. It reads as
     * not ours (drained), so it is looked for first.
     */
    if (cetrafs_sb_bg_discard_pending(sb, b)) {
        if (cetrafs_bg_data_block_stats(sb, b, &total, &free) != 0 || total == 0 || free != total ||
            cetrafs_bg_release_bitmap_ready(sb, b)) {
            pr_err_ratelimited("BG %u: kept for an outstanding discard, but not provably empty -- not discarded, "
                               "kept out of use (fsck)\n",
                               b);
            return -EBUSY;
        }
        /* Waived by the operator (release_discards=now): no earlier
         * UNMAP can still land, so none is sent again -- the way out for
         * a device that stopped taking discards (BM-48). */
        if (cetrafs_sb_bg_discard_waived(sb, b)) {
            settling = true;
            pr_warn("BG %u: its outstanding discard is waived by the operator -- releasing it untrimmed\n", b);
            goto release;
        }
        ret = cetrafs_discard_handback(sb, b, pass_started, true, force, &ctx.discarded);
        if (ret) {
            return -EBUSY; /* kept for a later pass */
        }
        /* Settled by the release swap itself (it clears the flag), and
         * forgotten here only once that swap has landed. */
        settling = true;
        pr_info("BG %u: its outstanding discard is settled -- releasing it\n", b);
        goto release;
    }
    if (!cetrafs_sb_bg_is_ours(sb, b))
        return 0;

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
     * A stale count errs the safe way HERE: it can only make us SKIP
     * a Block Group that turned out to be empty, deferring its
     * release to a later tick. In the other direction -- a count
     * saying empty over a bitmap that is not -- the bitmap scan in
     * cetrafs_bg_release_bitmap_ready() decides, under the drain.
     */
    if (!cetrafs_bg_release_skip_empty_check) {
        /* With our accrued delta: a FITRIM claim's debit is one, and
         * the raw descriptor count does not show it -- the group
         * was drained under the claim, and the claim, finding it
         * gone, leaked its whole run (review U4). */
        if (cetrafs_bg_data_block_stats(sb, b, &total, &free) == 0 && free != total)
            return 0; /* obviously in use -- never take it out of reach */
    }

    /* Take it out of the allocator's reach first, then look. The
     * other order leaves a window in which this node allocates into
     * a Block Group it is in the middle of giving away. */
    if (!cetrafs_sb_drain_bg(sb, b))
        return 0; /* a FITRIM holds a run in it: not empty, keep it */
    {
        unsigned int pause = xchg(&cetrafs_bg_release_drain_stall_ms, 0);

        if (pause) {
            pr_info("BG %u release: drained, pausing %u ms (test)\n", b, pause);
            msleep(pause); /* test-only; see the parameter */
        }
    }

    /* Our own accrued delta has to reach the descriptor before its
     * free count can be believed -- otherwise "empty" is a count
     * that predates this node's own frees. */
    cetrafs_flush_dirty_free_counts(sb);
    /* A bitmap not dropped is an earlier look: not proof of empty. */
    if (cetrafs_bg_invalidate_cache(sb, b) != 0 && !cetrafs_bg_invalidate_fail_ignored) {
        cetrafs_sb_undrain_bg(sb, b);
        return 0;
    }

    if (cetrafs_bg_data_block_stats(sb, b, &total, &free) != 0 || total == 0 ||
        (free != total && !cetrafs_bg_release_skip_empty_check)) {
        cetrafs_sb_undrain_bg(sb, b); /* still in use -- keep it */
        return 0;
    }
    if (cetrafs_bg_release_bitmap_ready(sb, b)) {
        cetrafs_sb_undrain_bg(sb, b); /* not provably empty, or not durable: keep it */
        return 0;
    }
    if (xchg(&cetrafs_release_noop_free, 0)) { /* TEST ONLY: see the parameter */
        struct cetrafs_bg_geom g;

        if (!cetrafs_read_bg_geom(sb, b, &g)) {
            pr_info("BG %u release: a free of already-free block %llu inside the hand-back (test)\n", b,
                    (unsigned long long) (g.start_block + g.off_data_region));
            cetrafs_free_data_extent(sb, g.start_block + g.off_data_region, 1);
        }
    }

    /*
     * UNMAP the whole data region before it leaves us (discard.c).
     * Here and nowhere later: drained, nothing of ours can allocate
     * in it; proven empty on the device, nothing references it; not
     * yet FREE, nobody else can claim it. After the CAS below it is
     * the pool's, and a discard then could land on a peer's first
     * writes. Over budget, the group stays ours for a later tick
     * rather than going back untrimmed.
     */
    /*
     * Flagged on the device BEFORE the UNMAP is sent, not only once it
     * failed. A command that hangs in a multipath queue past this node's
     * lease outlives the node: a peer takes the Zone Group, recounts,
     * finds the group empty and unflagged, and allocates it -- and the
     * queued UNMAP lands on its data with fsck clean (audit 2026-11-15
     * B-21). Flagged, the peer keeps the group out of use until a discard
     * of it has a known outcome. The release swap below clears it.
     */
    flagged = false;
    if (cetrafs_discard_handback_would_send(sb, force) && !READ_ONCE(cetrafs_handback_flag_first_off)) {
        if (cetrafs_bg_set_discard_pending_flag(sb, zg_id, b, true)) {
            cetrafs_sb_undrain_bg(sb, b); /* nothing sent: kept, tried again later */
            return -EBUSY;
        }
        flagged = true;
    }
    ret = cetrafs_discard_handback(sb, b, pass_started, false, force, &ctx.discarded);
    if (ret == -EAGAIN) {
        /* The UNMAP may still execute: the group stays drained --
         * not ours to allocate in, not the pool's -- until a discard
         * of it has a known outcome (review U1). Said once per group,
         * unratelimited: a path that keeps failing discards keeps
         * every emptied group, and with it every Zone Group release
         * (U3). */
        /* On the device first (rule 8): an unmount, a crash or a node
         * taking the Zone Group over must find the group kept, and only
         * the descriptor survives them. The mark below is its in-core
         * mirror. A record that cannot be made is a state this mount
         * cannot keep: it stops, as an unstorable mark does. */
        ret = flagged ? 0 : cetrafs_bg_set_discard_pending_flag(sb, zg_id, b, true);
        if (ret) {
            cetrafs_sb_fatal(sb, "BG %u: cannot record its outstanding discard on the device (%d)", b, ret);
            return -EBUSY;
        }
        if (cetrafs_sb_set_bg_discard_pending(sb, b, true))
            pr_warn("%s: BG %u: its hand-back discard failed and may still execute -- the group is kept out "
                    "of use until a discard of it succeeds or is refused. If this device cannot discard "
                    "reliably, turn discard off (controls: discard=off) so no further group is kept.\n",
                    sb->s_id, b);
        return -EBUSY; /* kept for a later pass */
    }
    if (ret) {
        /* Over budget: nothing was sent. The flag comes off again; if
         * that swap fails it stays, and the group is settled as one
         * with an outstanding discard -- kept, never shared. */
        if (flagged && cetrafs_bg_set_discard_pending_flag(sb, zg_id, b, false)) {
            cetrafs_sb_set_bg_discard_pending(sb, b, true);
            return -EBUSY;
        }
        cetrafs_sb_undrain_bg(sb, b);
        return -EBUSY; /* kept for a later pass */
    }
    if (flagged)
        settling = true; /* the release swap clears the flag; refused, the group stays flagged and kept */

release:

    /*
     * Both counter moves, by immediate CAS, BEFORE the descriptor
     * reads FREE. The pool write is cluster-visible the moment it
     * lands, so pairing it with a LAZY local accrual let every
     * peer's statfs see one half of the move until this node's next
     * durability boundary (the cross-node xattrs scenario,
     * 2026-10-29).
     *
     * And before, not after: a peer may claim the Block Group the
     * instant it reads FREE, and its claim debits the pool shard. A
     * credit still in flight then is refused as "below zero", the
     * credit lands afterwards, and the shard overstates by a whole
     * Block Group for good -- an ERR for fsck from two legal moves
     * (audit R25). Credited first, a claimant's debit always finds
     * it there. The aggregate goes first of the two, so a crash
     * anywhere before the CAS leaves it UNDERSTATING (the next
     * ownership reconcile recounts it); the pool can overstate by
     * one Block Group only for a crash between its credit and the
     * CAS, never for an interleaving. A refused CAS takes both back.
     */
    if (!cetrafs_bg_release_credit_late)
        cetrafs_bg_release_counters(sb, zg_id, b, total, +1);
    ret = cetrafs_cas_record(sb, cetrafs_sb_bg_desc_lba(sb, b), cetrafs_bg_release_mutate, &ctx);
    if (ret) {
        if (!cetrafs_bg_release_credit_late)
            cetrafs_bg_release_counters(sb, zg_id, b, total, -1);
        if (settling) {
            cetrafs_sb_set_bg_discard_pending(sb, b, true); /* still flagged on the device: kept, tried again */
            return -EBUSY;
        }
        cetrafs_sb_undrain_bg(sb, b);
        return 0; /* somebody changed it under us; leave it alone */
    }
    if (settling)
        cetrafs_sb_set_bg_discard_pending(sb, b, false); /* the swap cleared the flag */

    cetrafs_bg_release_drop_bitmap(sb, b);
    /* Not ours any more. The bitmap blocks were forgotten above, dirty
     * or held, so nothing of ours goes out over the next owner's bits.
     * The descriptor cache is dropped here; a claimant reads it fresh. */
    (void) cetrafs_bg_invalidate_cache(sb, b);
    cetrafs_sb_set_bg_owner(sb, b, CETRAFS_BG_OWNER_FREE);
    if (cetrafs_bg_release_stall_ms) {
        pr_info("BG %u: release stalled %u ms after it reads FREE (test)\n", b, cetrafs_bg_release_stall_ms);
        msleep(cetrafs_bg_release_stall_ms); /* test-only; see the parameter */
    }
    if (cetrafs_bg_release_credit_late)
        cetrafs_bg_release_counters(sb, zg_id, b, total, +1); /* test-only: the old order */
    pr_info("BG %u handed back from ZG %u (empty, %llu blocks)\n", b, zg_id, (unsigned long long) total);
    if (out_discarded)
        *out_discarded = ctx.discarded;
    return 1;
}

/* TEST ONLY: the empty-group release walks the whole table, as before
 * audit 2026-11-14 P13 -- the control of tests/kernel/release_walk_marked.sh. */
static bool cetrafs_release_walk_all;
cetrafs_test_param(release_walk_all, cetrafs_release_walk_all, bool, 0644);
MODULE_PARM_DESC(release_walk_all, "TEST ONLY: the per-tick empty-group release walks every Block Group");
static atomic64_t cetrafs_release_visits = ATOMIC64_INIT(0);
u64 cetrafs_release_visit_count(void)
{
    return (u64) atomic64_read(&cetrafs_release_visits);
}

int cetrafs_bg_release_empty(struct super_block *sb, u32 zg_id, u32 *out_released, u32 *out_deferred,
                             unsigned long *pass_started)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 b, nbg, released = 0, deferred = 0;

    if (!raw_sb)
        return -EINVAL;
    if (out_deferred)
        *out_deferred = 0;
    if (READ_ONCE(cetrafs_bg_release_off)) {
        if (out_released)
            *out_released = 0;
        return 0;
    }
    nbg = le32_to_cpu(raw_sb->block_group_count);

    /*
     * Only the groups that may have become empty since they were last
     * seen holding data (release_check), plus every group with an
     * outstanding discard: the walk used to be the whole table per
     * owned Zone Group per tick, and a descriptor CRC per owned group
     * (audit 2026-11-14 P13). The mark is cleared only where the look
     * below finds the group in use; a later credit sets it again.
     */
    for (b = READ_ONCE(cetrafs_release_walk_all) ? 0 : cetrafs_sb_next_release_check(sb, 0); b < nbg;
         b = READ_ONCE(cetrafs_release_walk_all) ? b + 1 : cetrafs_sb_next_release_check(sb, b + 1)) {
        u64 total, free;
        int ret;

        atomic64_inc(&cetrafs_release_visits);
        if (cetrafs_sb_bg_owner(sb, b) != zg_id) {
            u32 o = cetrafs_sb_bg_owner(sb, b);

            if (o < CETRAFS_MAX_ZONE_GROUPS && cetrafs_sb_zg_owned_cached(sb, o))
                continue; /* another of our Zone Groups: its own pass */
            /* Not ours (handed back, or never): nothing to release. A
             * claim that makes it ours marks it again after this. */
            cetrafs_sb_set_release_check(sb, b, false);
            o = cetrafs_sb_bg_owner(sb, b);
            if (o < CETRAFS_MAX_ZONE_GROUPS && cetrafs_sb_zg_owned_cached(sb, o))
                cetrafs_sb_set_release_check(sb, b, true);
            continue;
        }
        if (cetrafs_sb_bg_discard_pending(sb, b))
            continue; /* the loop below */
        {
            if (!cetrafs_sb_bg_is_ours(sb, b))
                continue;
            if (!cetrafs_bg_release_skip_empty_check && cetrafs_bg_data_block_stats(sb, b, &total, &free) == 0 &&
                free != total) {
                cetrafs_sb_set_release_check(sb, b, false);
                /* A credit between the stats and the clear set it
                 * again before we cleared it: look once more. */
                if (cetrafs_bg_data_block_stats(sb, b, &total, &free) != 0 || free == total)
                    cetrafs_sb_set_release_check(sb, b, true);
                continue;
            }
        }
        ret = cetrafs_bg_release_one(sb, zg_id, b, pass_started, false, NULL);
        if (ret > 0)
            released++;
        else if (ret == -EBUSY)
            deferred++;
        if ((b & 1023) == 1023)
            cond_resched();
    }
    /* Outstanding discards are not ours (drained) and may carry no mark. */
    for (b = cetrafs_sb_next_discard_pending(sb, 0); b < nbg; b = cetrafs_sb_next_discard_pending(sb, b + 1)) {
        int ret;

        if (cetrafs_sb_bg_owner(sb, b) != zg_id)
            continue;
        ret = cetrafs_bg_release_one(sb, zg_id, b, pass_started, false, NULL);
        if (ret > 0)
            released++;
        else if (ret == -EBUSY)
            deferred++;
    }

    if (out_released)
        *out_released = released;
    if (out_deferred)
        *out_deferred = deferred;
    return 0;
}

/*
 * Bring the in-core Block Group -> Zone Group map up to date with the
 * descriptors. Called when a Zone Group is about to ENTER this node's
 * ownership, before its members are derived from the map.
 *
 * The map is read at mount, and peers move Block Groups after that: an
 * owner hands an empty one back, another node claims it into its own
 * Zone Group. Taking a Zone Group over -- reclaiming a dead peer's is
 * the common case -- from the mount-time map made this node treat a
 * Block Group that had moved to another node as its own: the allocator
 * refused it with -EPERM, and the scrub, which takes its targets from
 * the same map, judged the other node's blocks leaked and FREED them
 * (tests/kernel/bg_owner_map_refresh.sh: all 131067 of them).
 *
 * Fresh reads, skipping the Block Groups this node already owns: it is
 * their only writer (PERF(3), docs/PERFORMANCE.md). Read ahead first, so
 * a large table is one batch rather than a round trip per descriptor.
 * Runs once per Zone Group claim -- never per tick (PERF(5)).
 *
 * A descriptor that cannot be read is taken OUT of the map's reach
 * (marked free here): this node must not allocate from or scrub a Block
 * Group it cannot show it owns. claim_free re-reads before using one.
 */
void cetrafs_bg_refresh_owner_map(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 b, nbg, moved = 0;

    if (!raw_sb)
        return;
    nbg = le32_to_cpu(raw_sb->block_group_count);

    for (b = 0; b < nbg; b++) {
        u64 lba;

        if (cetrafs_sb_bg_is_ours(sb, b))
            continue;
        lba = cetrafs_sb_bg_desc_lba(sb, b);
        cetrafs_invalidate_block(sb, lba);
        sb_breadahead(sb, lba);
    }
    for (b = 0; b < nbg; b++) {
        struct cetrafs_bg_geom geom;
        u32 owner;

        if (cetrafs_sb_bg_is_ours(sb, b))
            continue;
        if (cetrafs_read_bg_geom(sb, b, &geom) != 0) {
            pr_warn("BG %u: descriptor unreadable while refreshing ownership -- leaving it out of reach\n", b);
            owner = CETRAFS_BG_OWNER_FREE;
        } else if (geom.owner_zg != cetrafs_sb_bg_owner(sb, b) && geom.owner_zg < CETRAFS_BG_OWNER_FREE &&
                   cetrafs_sb_zg_owned_cached(sb, geom.owner_zg) && cetrafs_bg_invalidate_cache(sb, b) != 0 &&
                   !cetrafs_bg_invalidate_fail_ignored) {
            /* Entering a Zone Group this node allocates from: what it
             * cached of the bitmap must go first, and did not (A7). */
            pr_warn("BG %u: its cached bitmap could not be dropped -- leaving it out of reach\n", b);
            owner = CETRAFS_BG_OWNER_FREE;
        } else {
            owner = geom.owner_zg;
            /* An outstanding discard a peer recorded -- one that died
             * with it, most likely: known BEFORE the claim derives this
             * group's owned bit, so it is never handed to our allocator
             * (CETRAFS_BG_FLAG_DISCARD_PENDING). And one the peer has
             * since settled is forgotten. */
            cetrafs_sb_set_bg_discard_pending(sb, b, !!(geom.flags & CETRAFS_BG_FLAG_DISCARD_PENDING));
        }
        if (owner != cetrafs_sb_bg_owner(sb, b)) {
            cetrafs_sb_set_bg_owner(sb, b, owner);
            moved++;
        }
        if ((b & 1023) == 1023)
            cond_resched();
    }
    if (moved)
        pr_info("%u Block Group(s) changed owner since this node last looked\n", moved);
}

/* TEST ONLY: one claim pauses once the Block Group is allocatable, so a
 * concurrent writer allocates from it while the claim is still in
 * flight (tests/kernel/zg_aggregate_drift.sh). */
static unsigned int cetrafs_bg_claim_stall_ms;
cetrafs_test_param(bg_claim_stall_ms, cetrafs_bg_claim_stall_ms, uint, 0644);
MODULE_PARM_DESC(bg_claim_stall_ms, "test-only: pause one Block Group claim once the group is allocatable");

/*
 * Claim Block Group b, if it is FREE, into zg_id: the body of
 * cetrafs_bg_claim_free(), and of FITRIM's pool pass. 0 when claimed,
 * -EAGAIN when it is not free (or a peer won it), any other error as is.
 */
static int __cetrafs_bg_claim_one(struct super_block *sb, u32 zg_id, u32 b, bool prefetched);

static int cetrafs_bg_claim_one(struct super_block *sb, u32 zg_id, u32 b)
{
    return __cetrafs_bg_claim_one(sb, zg_id, b, false);
}

/* TEST ONLY: one claim pauses between its two pool-count moves, logging
 * it (tests/kernel/bg_claim_pool_order.sh). */
static unsigned int cetrafs_bg_claim_pool_stall_ms;
cetrafs_test_param(bg_claim_pool_stall_ms, cetrafs_bg_claim_pool_stall_ms, uint, 0644);
MODULE_PARM_DESC(bg_claim_pool_stall_ms, "TEST ONLY: one Block Group claim pauses between its swap and the pool debit");
/* TEST ONLY: the claim debits the pool after its swap, as before audit
 * 2026-11-22 N-15 -- the control of the same suite. */
static bool cetrafs_bg_claim_debit_late;
cetrafs_test_param(bg_claim_debit_late, cetrafs_bg_claim_debit_late, bool, 0644);
MODULE_PARM_DESC(bg_claim_debit_late, "TEST ONLY: a Block Group claim debits the pool after its swap (old order)");

static void cetrafs_bg_claim_pool_stall(u32 b)
{
    unsigned int pause = READ_ONCE(cetrafs_bg_claim_pool_stall_ms) ? xchg(&cetrafs_bg_claim_pool_stall_ms, 0) : 0;

    if (pause) {
        pr_info("BG %u claim: between its counter moves, pausing %u ms (test)\n", b, pause);
        msleep(pause);
    }
}

static int __cetrafs_bg_claim_one(struct super_block *sb, u32 zg_id, u32 b, bool prefetched)
{
    struct cetrafs_bg_claim_ctx ctx = {.zg_id = zg_id, .bg_id = b};
    struct cetrafs_bg_geom geom;
    u64 total = 0, free = 0, debited = 0;
    bool late = READ_ONCE(cetrafs_bg_claim_debit_late);
    int ret;

    /* Forced fresh: the cached copy can predate a peer's claim, and
     * a stale FREE here is exactly the read that makes two nodes
     * reach for the same Block Group (rule 1). The swap would still
     * refuse, but scanning on fresh data finds a real candidate
     * sooner.
     *
     * Not ours, though: a Block Group this node owns is never FREE,
     * and its descriptor is the one the allocator reads per block --
     * dropping it on every claim attempt (each ENOSPC on a full
     * volume makes one) is PERFORMANCE.md invariant 3 broken (audit
     * 2026-11-06 L26). 'prefetched': the caller's batch just read it
     * fresh (cetrafs_bg_claim_free()). */
    if (!prefetched)
        cetrafs_invalidate_block(sb, cetrafs_sb_bg_desc_lba(sb, b));
    if (cetrafs_read_bg_geom(sb, b, &geom) != 0)
        return -EAGAIN;
    if (geom.owner_zg != CETRAFS_BG_OWNER_FREE)
        return -EAGAIN;

    /*
     * The pool shard first, from the count of the very image the swap
     * below compares. Swapped first and debited after, a crash between
     * left the group owned AND counted in the pool: statfs overstated by
     * a whole Block Group until fsck -r (audit 2026-11-22 N-15). Debited
     * first, the same crash understates -- the release's order, which
     * credits the shard before its descriptor reads FREE. A refused swap
     * gives the debit back; an unknown outcome keeps it (understating).
     */
    if (!late && geom.free_data_blocks) {
        if (cetrafs_zg_adjust_pool_blocks(sb, b, -(s64) geom.free_data_blocks))
            pr_warn("BG %u: its pool shard debit failed before the claim -- df will overstate until fsck\n", b);
        else
            debited = geom.free_data_blocks;
        cetrafs_bg_claim_pool_stall(b);
    }

    if (cetrafs_bg_claim_blind) {
        /* test-only: read, decide, write -- no exclusion at all */
        struct buffer_head *wbh = cetrafs_bread_retry(sb, cetrafs_sb_bg_desc_lba(sb, b));

        if (!wbh)
            return -EAGAIN;
        /* Through the buffer-update protocol, not a bare
         * mark_buffer_dirty(): this knob exists to remove the
         * COMPARE-AND-SWAP, not to break buffer handling as well --
         * a control that injects two faults at once cannot say
         * which one it measured. image/source_invariants.sh
         * enforces the protocol and caught exactly that here. */
        cetrafs_bh_begin_update(wbh);
        cetrafs_bg_claim_mutate(wbh->b_data, CETRAFS_BLOCK_SIZE, &ctx);
        cetrafs_bh_end_update(sb, wbh);
        (void) cetrafs_sync_buffer(sb, wbh); /* test-only path */
        brelse(wbh);
        ret = 0;
    } else {
        ret = cetrafs_cas_record(sb, cetrafs_sb_bg_desc_lba(sb, b), cetrafs_bg_claim_mutate, &ctx);
    }
    if (ret == -EAGAIN) {
        /* A peer got there first: refused, so certainly not ours. */
        if (debited && cetrafs_zg_adjust_pool_blocks(sb, b, (s64) debited))
            pr_warn("BG %u: a lost claim could not give its pool debit back -- df will understate until fsck\n",
                    b);
        return -EAGAIN;
    }
    if (ret)
        return ret; /* not known: the debit stays, the safe direction */

    /* The descriptor just changed owner, so anything holding the
     * old one must not serve it -- see
     * cetrafs_bg_adjust_free_blocks(), which reads owner_zg from
     * the cache on the allocation path. If its bitmap could not be
     * dropped, the group is ours on the device but stays out of the
     * map's reach: the cached bitmap may predate the previous owner's
     * last allocations (audit 2026-11-14 A7). Kept like that, it was
     * owned on the device, out of every node's reach and not debited
     * from the pool -- df overstated until a Zone Group claim or a
     * remount (re-audit of the fixes). The claim is undone instead:
     * back to the pool, nothing allocated from it, and the caller
     * looks for another group. An undo that cannot land is a CAS
     * failure, which stops the mount as every undecidable one does. */
    ret = cetrafs_bg_invalidate_cache(sb, b);
    if (ret && !cetrafs_bg_invalidate_fail_ignored) {
        int uret;

        if (READ_ONCE(cetrafs_pool_claim_undo_off)) {
            pr_warn("BG %u: claimed, but its cached bitmap could not be dropped (%d) -- left out of reach\n", b,
                    ret);
            return ret;
        }
        uret = cetrafs_cas_record(sb, cetrafs_sb_bg_desc_lba(sb, b), cetrafs_bg_unclaim_mutate, &ctx);
        if (uret < 0) {
            pr_err("BG %u: claimed, its cached bitmap could not be dropped (%d), and the claim could not be undone "
                   "(%d) -- owned and out of reach until a remount\n",
                   b, ret, uret);
            return ret;
        }
        pr_warn("BG %u: claimed, but its cached bitmap could not be dropped (%d) -- given back to the pool\n", b,
                ret);
        if (debited && cetrafs_zg_adjust_pool_blocks(sb, b, (s64) debited))
            pr_warn("BG %u: the undone claim could not give its pool debit back -- df will understate until fsck\n",
                    b);
        return -EAGAIN; /* try another group */
    }
    /* Ownership is entering this node's cache, so its count epoch
     * must too -- BEFORE set_bg_owner() makes the Block Group
     * allocatable, or the first deltas accrue under whatever epoch
     * the array held (0 since mount) and every one is refused as a
     * stale owner's: the count then stays "all free" while the Block
     * Group fills, and the empty-release path takes it at its word
     * (tests/kernel/bg_claim_epoch.sh). The ZG claim reconciles and
     * the re-attach seeds; this path did neither. */
    cetrafs_sb_set_bg_epoch(sb, b, ctx.seq);
    /*
     * The Zone Group just gained this Block Group's free space, and
     * its aggregate has to say so -- fsck cross-checks "a Zone
     * Group's aggregate equals the sum over its Block Groups", and
     * the allocator ranks Zone Groups by it. Read fresh: the
     * descriptor was just invalidated above precisely because the
     * cached copy is the pre-claim one.
     *
     * Read AND credited before set_bg_owner() makes the group
     * allocatable (audit 2026-11-06 M4). Read after, an allocation
     * in between both lowered the count read here and accrued its
     * own debit: counted twice. Credited after, the debits of
     * allocations made in between could reach the device first, on
     * an aggregate that did not hold this group yet -- below zero,
     * refused, and dropped (cetrafs_zg_apply_free_delta()).
     */
    if (cetrafs_bg_data_block_stats(sb, b, &total, &free) == 0 && free) {
        /* The pool was debited before the swap (above), so crediting
         * the aggregate now cannot count the group twice; both moves
         * are immediate CASes -- see the release path for why a lazy
         * accrual made peers' statfs dip by this whole Block Group. */
        if (late) {
            cetrafs_bg_claim_pool_stall(b); /* test-only: the old order's window */
            if (cetrafs_zg_adjust_pool_blocks(sb, b, -(s64) free))
                pr_warn("BG %u: claimed but its pool shard debit failed -- df will overstate until fsck\n", b);
        }
        if (cetrafs_zg_apply_free_delta(sb, zg_id, (s64) free))
            cetrafs_zg_adjust_free_blocks(sb, zg_id, (s64) free); /* lazy fallback: never lose the move */
    }
    /* The swap refused a flagged group, so its discard is settled: an
     * in-core mark left from when a peer still had it outstanding goes,
     * or the group would be ours and never allocatable. */
    cetrafs_sb_set_bg_discard_pending(sb, b, false);
    cetrafs_sb_set_bg_owner(sb, b, zg_id);
    {
        unsigned int pause = xchg(&cetrafs_bg_claim_stall_ms, 0);

        if (pause) {
            pr_info("BG %u claim: allocatable, pausing %u ms (test)\n", b, pause);
            msleep(pause); /* test-only; see the parameter */
        }
    }

    pr_info("BG %u claimed into ZG %u (was owned by nobody, %llu blocks free)\n", b, zg_id,
            (unsigned long long) free);
    return 0;
}

int cetrafs_bg_claim_free(struct super_block *sb, u32 zg_id, u32 *out_bg_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    bool prefetched;
    u32 b, nbg;

    if (!raw_sb)
        return -EINVAL;
    nbg = le32_to_cpu(raw_sb->block_group_count);

    /* Every descriptor that is not ours dropped and read ahead first, as
     * one batch: an ENOSPC paid a serial forced-fresh read per Block
     * Group here, under the writer's locks (audit 2026-11-14 A4). The
     * claim swap decides; this only finds the candidate. */
    prefetched = !READ_ONCE(cetrafs_zg_prefetch_off);
    if (prefetched) {
        for (b = 0; b < nbg; b++) {
            u64 lba;

            if (cetrafs_sb_bg_is_ours(sb, b))
                continue;
            lba = cetrafs_sb_bg_desc_lba(sb, b);
            cetrafs_invalidate_block(sb, lba);
            sb_breadahead(sb, lba);
        }
    }
    for (b = 0; b < nbg; b++) {
        int ret;

        if (cetrafs_sb_bg_is_ours(sb, b))
            continue;
        if ((b & 1023) == 1023)
            cond_resched();
        ret = __cetrafs_bg_claim_one(sb, zg_id, b, prefetched);
        if (ret == -EAGAIN)
            continue;
        if (ret)
            return ret;
        if (out_bg_id)
            *out_bg_id = b;
        return 0;
    }
    return -ENOSPC;
}

/* TEST ONLY: the next pool-pass group pauses between its claim and its
 * release, so a heartbeat release of the same group can be caught trying
 * to run in between (tests/kernel/fstrim_pool.sh). */
static unsigned int cetrafs_fitrim_pool_stall_ms;
cetrafs_test_param(fitrim_pool_stall_ms, cetrafs_fitrim_pool_stall_ms, uint, 0644);
MODULE_PARM_DESC(fitrim_pool_stall_ms, "TEST ONLY: pause one FITRIM pool-pass group between claim and release");

/*
 * FITRIM's pool pass, for one Block Group. A group handed back while
 * discard was off (`nodiscard`, or the control) went to the pool with
 * its data region still mapped, and nothing else ever looks at the pool:
 * the hand-back discards on the way OUT, FITRIM walks only owned groups.
 * So the space a delete freed then stayed mapped on the array for good.
 *
 * Trimmed the only way the ownership rule allows: claim it (one CAS, so
 * no peer can claim it meanwhile), then hand it straight back through
 * the ordinary release, which drains it, proves it empty on the device,
 * discards its data region and marks it DISCARDED as it goes back. If
 * our own allocator put a block in it between the two, the release
 * keeps it -- nothing is lost, it is just not trimmed. A group already
 * marked DISCARDED is skipped, so a pool is trimmed once, not on every
 * fstrim.
 *
 * All of it under release_rwsem for write, like the heartbeat's surplus
 * release (cetrafs_zg_release_surplus()), which is the only other caller
 * of the release body. Without it the claimed group -- owned and empty --
 * is exactly what that release looks for: two releases of one group
 * interleaved, and the loser's undrain could re-mark as ours a group the
 * winner had already published FREE, so the allocator took a block in a
 * group a peer could claim. The same lock keeps the target Zone Group
 * ours from the pick to the release (a ZG release runs under it too).
 * Per group, so an allocator waiting in cetrafs_sb_release_wait() waits
 * for one discard, as it does for the heartbeat; nothing under the lock
 * takes trim_mutex.
 *
 * Returns the blocks discarded in *out_blocks; -EIO when the discard's
 * outcome is unknown (the group then stays drained and pending, as for
 * any hand-back); -ENOENT when this node owns no Zone Group to claim
 * into.
 */
int cetrafs_bg_trim_pool_one(struct super_block *sb, u32 b, u64 *out_blocks)
{
    struct cetrafs_bg_geom geom;
    unsigned long started = 0; /* one group, one discard: never over budget */
    bool discarded = false;
    unsigned int pause;
    u32 zg_id;
    int ret = 0;

    *out_blocks = 0;
    cetrafs_sb_release_lock(sb);
    if (cetrafs_sb_bg_is_ours(sb, b))
        goto out;
    cetrafs_invalidate_block(sb, cetrafs_sb_bg_desc_lba(sb, b));
    if (cetrafs_read_bg_geom(sb, b, &geom) != 0)
        goto out;
    if (geom.owner_zg != CETRAFS_BG_OWNER_FREE || (geom.flags & CETRAFS_BG_FLAG_DISCARDED))
        goto out;
    if (cetrafs_sb_first_owned_zg(sb, &zg_id)) {
        ret = -ENOENT;
        goto out;
    }
    ret = cetrafs_bg_claim_one(sb, zg_id, b);
    if (ret == -EAGAIN) {
        ret = 0; /* a peer has it now: its own hand-back will discard it */
        goto out;
    }
    if (ret)
        goto out;
    pause = xchg(&cetrafs_fitrim_pool_stall_ms, 0);
    if (pause) {
        pr_info("fitrim pool: BG %u claimed, pausing %u ms (test)\n", b, pause);
        msleep(pause); /* test-only; see the parameter */
        pr_info("fitrim pool: BG %u resuming (test)\n", b);
    }
    ret = cetrafs_bg_release_one(sb, zg_id, b, &started, true, &discarded);
    if (ret == -EBUSY) {
        ret = -EIO;
        goto out;
    }
    if (ret > 0 && discarded)
        *out_blocks = geom.data_block_count;
    ret = 0;
out:
    cetrafs_sb_release_unlock(sb);
    return ret;
}

int cetrafs_bg_mount_info(struct super_block *sb, const cetrafs_superblock_t *raw_sb, u32 bg_id, u64 desc_lba,
                          bool fresh, u64 *out_total, u32 *out_owner, u64 *out_start, u64 *out_len, u16 *out_flags,
                          u64 *out_data_start)
{
    struct cetrafs_bg_geom bg;
    int ret = cetrafs_read_bg_geom_at(sb, raw_sb, bg_id, desc_lba, fresh, &bg);

    if (ret)
        return ret;
    if (out_start)
        *out_start = bg.start_block;
    if (out_len)
        *out_len = bg.length_blocks;
    if (out_total)
        *out_total = bg.data_block_count;
    if (out_owner)
        *out_owner = bg.owner_zg;
    if (out_flags)
        *out_flags = bg.flags;
    if (out_data_start)
        *out_data_start = bg.start_block + bg.off_data_region;
    return 0;
}

int cetrafs_bg_data_block_stats(struct super_block *sb, u32 bg_id, u64 *out_total, u64 *out_free)
{
    struct cetrafs_bg_geom bg;
    s64 free;
    int ret;

    /* Include this node's own accrued-but-unapplied delta (v0x0004: the
     * on-disk count no longer carries it between durability boundaries),
     * so the owner's own statfs and cetrafs_alloc_pick_bg() ranking see
     * their allocations immediately, exactly as the old dirty-buffer
     * read did. Zero for every BG this node does not own.
     *
     * And a delta on its way to the descriptor is in neither place: the
     * settle takes the count that flush is writing instead, and sends us
     * back to the descriptor if a flush began or ended while we read it
     * (cetrafs_bg_chunk.bg_flight_gen). Two lock-free loads and one
     * uncontended spinlock on the per-block path, no I/O. */
    for (;;) {
        u32 gen = cetrafs_sb_bg_flight_gen(sb, bg_id);

        ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
        if (ret)
            return ret;
        if (cetrafs_sb_bg_free_settle(sb, bg_id, gen, (s64) bg.free_data_blocks, &free))
            break;
        cond_resched();
    }
    *out_total = bg.data_block_count;
    *out_free = free > 0 ? (u64) free : 0;
    return 0;
}

/* ------------------------------------------------------------------ */
/* FITRIM claims (discard.c drives them).
 *
 * A run is discarded only while it is CLAIMED: its bits set exactly as
 * an allocation sets them, so nothing can be handed it while the UNMAP
 * is in flight -- and that alone is not enough, because two things in
 * this module clear bits that read allocated:
 *
 *  - the scrub frees allocated blocks nothing references, which is what
 *    a claimed run is. The claim is published on the reservation list
 *    in the same alloc_mutex section that sets the bits, as a defrag
 *    destination run is (cetrafs_alloc_data_run_resv()), and the
 *    scrub's free rechecks that list under the same mutex.
 *  - a double free -- ours, or a peer's queued one -- clears whatever
 *    bit it finds set. Over a claimed run that bit is the TRIM's, and
 *    clearing it hands the block out while its discard is in flight:
 *    the new owner's data is destroyed. Both free paths therefore treat
 *    a block inside the claim as already free (cetrafs_sb_trim_holds()).
 *
 * Only a Block Group this node owns: its bitmap is ours alone, and the
 * cached copy is authoritative for the same reason the allocator's is.
 * docs/DISCARD-DESIGN.md.
 */

/* TEST ONLY: find the run but do not claim it -- the negative control
 * for the claim itself (tests/kernel/fstrim_claim.sh). */
static bool cetrafs_trim_skip_claim;
cetrafs_test_param(trim_skip_claim, cetrafs_trim_skip_claim, bool, 0644);
MODULE_PARM_DESC(trim_skip_claim, "TEST ONLY: FITRIM discards free runs without claiming them first");

static atomic64_t cetrafs_trim_leaked_blocks = ATOMIC64_INIT(0);

u64 cetrafs_trim_leaked_count(void)
{
    return (u64) atomic64_read(&cetrafs_trim_leaked_blocks);
}

/* The first run of at least 'minlen' free bits at or after 'from', its
 * length capped at 'maxlen' after it is counted to its real end, so a
 * long run is not mistaken for a short one; the caller resumes after
 * what it claimed (cetrafs_bitmap_find_run()). */
static int cetrafs_bitmap_find_free_run(struct super_block *sb, u64 bmap_lba, u64 nblocks, u64 nbits, u64 from,
                                        u64 minlen, u64 maxlen, u64 *out_start, u64 *out_len)
{
    int err = cetrafs_bitmap_find_run(sb, bmap_lba, nblocks, nbits, from, max_t(u64, minlen, 1), out_start, out_len);

    if (!err)
        *out_len = min(*out_len, maxlen);
    return err;
}

/*
 * Set or clear bits [bit, bit + count), every one expected to be in the
 * other state. Returns the number that were not (0 is the only answer a
 * correct caller sees), or a negative errno on a read failure, in which
 * case the bits before the failing block have been changed. Per bitmap
 * block, under the buffer-update protocol (cetrafs_bitmap_free_bit()).
 */
static long cetrafs_bitmap_flip_range(struct super_block *sb, u64 bmap_lba, u64 nblocks, u64 bit, u64 count,
                                      bool set)
{
    struct cetrafs_bmap_hold h = {0};
    const u64 end = bit + count;
    long wrong = 0;
    int err = 0;

    for (; bit < end; bit++) {
        u64 off;

        if (!(bit % CETRAFS_BMAP_BLOCK_BITS))
            cond_resched();
        err = cetrafs_bmap_hold_at(sb, &h, bmap_lba, nblocks, bit, &off, NULL);
        if (err)
            break;
        if (!cetrafs_bmap_hold_flip(&h, off, set))
            wrong++;
    }
    cetrafs_bmap_hold_end(sb, &h);
    return err ? err : wrong;
}

/*
 * Claim the next free run of BG 'bg_id' at or after bit *cursor: at
 * least 'minlen' blocks, at most 'maxlen'. On success the run is in
 * 'run', its bits are set and it is held against every free path, and
 * *cursor is past it. -ENOSPC: no further run in this Block Group.
 * -EAGAIN / -EPERM: the Block Group is not ours (any more). -EIO: fenced,
 * or the bitmap could not be read.
 */
int cetrafs_trim_claim_next(struct super_block *sb, u32 bg_id, u64 *cursor, u64 minlen, u64 maxlen,
                            struct cetrafs_trim_run *run)
{
    struct cetrafs_bg_geom bg;
    u64 bmap_lba, bmap_blocks, start = 0, len = 0;
    long wrong;
    int ret;

    run->count = 0;
    run->claimed = false;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    ret = cetrafs_read_bg_geom(sb, bg_id, &bg);
    if (ret)
        return ret;
    if (bg.owner_zg == CETRAFS_BG_OWNER_FREE || !cetrafs_sb_zg_owned_cached(sb, bg.owner_zg))
        return -EPERM;
    bmap_lba = bg.start_block + bg.off_data_bmap;
    bmap_blocks = bg.off_data_region - bg.off_data_bmap;

    cetrafs_sb_alloc_lock(sb);
    if (cetrafs_alloc_bg_gone(sb, bg_id)) {
        ret = -EAGAIN;
        goto out;
    }
    ret = cetrafs_bitmap_find_free_run(sb, bmap_lba, bmap_blocks, bg.data_block_count, *cursor, minlen, maxlen,
                                       &start, &len);
    if (ret) {
        if (ret == -ENOSPC)
            *cursor = bg.data_block_count;
        goto out;
    }

    run->bg_id = bg_id;
    run->owner_zg = bg.owner_zg;
    run->lba = bg.start_block + bg.off_data_region + start;
    run->count = len;
    *cursor = start + len;

    if (READ_ONCE(cetrafs_trim_skip_claim))
        goto out; /* test-only: discarded with nothing holding it */

    wrong = cetrafs_bitmap_flip_range(sb, bmap_lba, bmap_blocks, start, len, true);
    if (wrong < 0) {
        /* A bitmap block would not read, part way: the bits before it
         * are set. Every bit of the run read clear a moment ago under
         * this mutex, so clearing the whole run again undoes exactly
         * what was set (a clear bit stays clear). Nothing is discarded. */
        long undo = cetrafs_bitmap_flip_range(sb, bmap_lba, bmap_blocks, start, len, false);

        /* An undo that fails leaves bits set: a leak the scrub reclaims. */
        pr_err_ratelimited("trim claim: BG %u bitmap unreadable (%ld) -- skipped%s\n", bg_id, wrong,
                           undo < 0 ? "; the claim could not be undone, its blocks leak until the scrub" : "");
        run->count = 0;
        ret = (int) wrong;
        goto out;
    }
    if (wrong) {
        /* The scan just read these clear under the mutex the only other
         * setter takes: memory and disk disagree (ERRORS.md, kind 3).
         * Nothing is discarded; what was set stays set (a leak). */
        cetrafs_sb_fatal(sb, "trim claim: %ld bit(s) of a run scanned free in BG %u were set under the alloc mutex",
                         wrong, bg_id);
        run->count = 0;
        ret = -EIO;
        goto out;
    }
    /* Debited like an allocation, so the count never shows space the
     * allocator cannot have. NOT marked for the bitmap flush
     * (cetrafs_sb_note_bmap_alloc()): that flush exists so an extent
     * never reaches the device before the bits it names (rule 8), and
     * nothing will ever name these -- marking them would only make the
     * next writer's tree edit pay a synchronous bitmap write per claim.
     * A crash with the debit on the device and the bits not leaves the
     * count understating, which the next recount corrects. */
    cetrafs_bg_adjust_free_blocks(sb, bg_id, -(s64) len);
    cetrafs_shadow_set(sb, run->lba, len, "trim_claim");
    cetrafs_resv_publish(sb, &run->span, run->lba, (u32) len);
    cetrafs_sb_set_trim_claim(sb, bg_id, run->lba, len);
    run->claimed = true;
out:
    cetrafs_sb_alloc_unlock(sb);
    return ret;
}

/*
 * Give a claimed run back once its discard is done (or failed): clear
 * the bits, credit the count, end the hold. Only while the Block Group
 * is still ours and this mount is not fenced -- otherwise the bitmap may
 * be somebody else's by now, and writing it is the single most damaging
 * thing this module can do. The bits then stay set: a leak, which the
 * scrub (ours, or the next owner's) reclaims. Never shared.
 */
void cetrafs_trim_release(struct super_block *sb, struct cetrafs_trim_run *run, bool keep)
{
    struct cetrafs_bg_geom bg;
    bool sync_kept = false;
    long wrong;
    int ret;

    if (!run->claimed)
        return;

    ret = cetrafs_read_bg_geom(sb, run->bg_id, &bg);
    cetrafs_sb_alloc_lock(sb);
    if (keep) {
        /* The discard's outcome is unknown (cetrafs_discard_outcome_known()):
         * it may still execute. Handed out now, the block could take a
         * file's data before that UNMAP lands on it -- so the run stays
         * allocated, as a publish of unknown outcome frees nothing (rule
         * 21). Off the reservation list below, so the scrub reclaims it,
         * minutes from now. */
        atomic64_add((s64) run->count, &cetrafs_trim_leaked_blocks);
        /* ...and held from the scrub too, for longer than a command can
         * outlive its path: the scrub would otherwise reclaim the run in
         * minutes and the allocator hand it out under the UNMAP still
         * queued (N-24). Published before the run's own span goes below,
         * so the registry never lets go of it in between. */
        if (cetrafs_trim_quarantine_add(sb, run->lba, run->count))
            pr_warn_ratelimited("trim: the discard of [%llu +%llu) may still land -- left allocated, and kept from "
                                "the scrub for %u s\n",
                                (unsigned long long) run->lba, (unsigned long long) run->count,
                                cetrafs_trim_quarantine_secs_get());
        else
            pr_warn_ratelimited("trim: the discard of [%llu +%llu) may still land -- left allocated for the scrub "
                                "(no memory to hold it from the scrub)\n",
                                (unsigned long long) run->lba, (unsigned long long) run->count);
        sync_kept = true;
        goto out;
    }
    if (ret || cetrafs_sb_is_fenced(sb) || cetrafs_alloc_bg_gone(sb, run->bg_id) ||
        !cetrafs_sb_zg_owned_cached(sb, run->owner_zg)) {
        atomic64_add((s64) run->count, &cetrafs_trim_leaked_blocks);
        pr_warn_ratelimited("trim: BG %u left this node during a trim -- [%llu +%llu) stays allocated for the "
                            "scrub\n",
                            run->bg_id, (unsigned long long) run->lba, (unsigned long long) run->count);
        goto out;
    }
    wrong = cetrafs_bitmap_flip_range(sb, bg.start_block + bg.off_data_bmap, bg.off_data_region - bg.off_data_bmap,
                                      run->lba - bg.start_block - bg.off_data_region, run->count, false);
    if (wrong < 0) {
        /* Partly given back: the rest stays set, and the count is not
         * credited at all -- it understates until the next recount, the
         * safe direction. */
        atomic64_add((s64) run->count, &cetrafs_trim_leaked_blocks);
        pr_err("trim: could not give back [%llu +%llu) in BG %u (%ld) -- left for the scrub\n",
               (unsigned long long) run->lba, (unsigned long long) run->count, run->bg_id, wrong);
        goto out;
    }
    if (wrong) {
        /* Something cleared a bit the hold refuses to every free path. */
        cetrafs_sb_fatal(sb, "trim release: %ld bit(s) of the claimed run [%llu +%llu) were already clear", wrong,
                         (unsigned long long) run->lba, (unsigned long long) run->count);
        goto out;
    }
    cetrafs_bg_adjust_free_blocks(sb, run->bg_id, (s64) run->count);
    cetrafs_shadow_clear(sb, run->lba, run->count, "trim_release");
out:
    cetrafs_sb_set_trim_claim(sb, 0, 0, 0);
    cetrafs_resv_unpublish(sb, &run->span);
    run->claimed = false;
    cetrafs_sb_alloc_unlock(sb);

    /*
     * A kept run is held by its bits alone, and the claim set them in
     * the buffer cache: dirty, not synced, and not noted for
     * cetrafs_alloc_flush_bitmaps(). A fence or crash before writeback
     * -- a transport failure is exactly when one is likely -- hands the
     * Zone Group to a peer whose recount reads them FREE, and it
     * allocates under the command that may still land (review U2). So
     * the hold reaches the device before the failure is reported, or
     * the mount can promise nothing about that run and stops.
     */
    if (sync_kept) {
        u64 first, last, blk;
        int sret = ret;

        if (!sret) {
            first = cetrafs_bmap_blk(run->lba - bg.start_block - bg.off_data_region);
            last = cetrafs_bmap_blk(run->lba + run->count - 1 - bg.start_block - bg.off_data_region);
            for (blk = first; blk <= last && !sret; blk++)
                sret = cetrafs_sync_one_block(sb, bg.start_block + bg.off_data_bmap + blk);
        }
        if (sret)
            cetrafs_sb_fatal(sb, "trim: could not make the hold on [%llu +%llu) durable (%d) -- a discard of it "
                                 "may still land",
                             (unsigned long long) run->lba, (unsigned long long) run->count, sret);
    }
}

/*
 * A claimed run's bits, on the device, before its discard is sent. The
 * claim sets them in the cache only; a discard that then hangs in a
 * multipath queue past this node's lease leaves the run reading FREE to
 * the peer that takes the Zone Group over, which allocates it -- and the
 * queued UNMAP lands on that data, fsck clean (audit 2026-11-15 B-21,
 * B-37). One synchronous bitmap write per run, against an UNMAP that
 * costs as much. Nonzero: not durable, so nothing may be discarded.
 */
static bool cetrafs_trim_hold_sync_off;
cetrafs_test_param(trim_hold_sync_off, cetrafs_trim_hold_sync_off, bool, 0644);
MODULE_PARM_DESC(trim_hold_sync_off, "TEST ONLY: a trim claim's hold is not made durable before its discard");

int cetrafs_trim_hold_durable(struct super_block *sb, const struct cetrafs_trim_run *run)
{
    struct cetrafs_bg_geom bg;
    u64 first, last, blk;
    int ret;

    if (!run->claimed || READ_ONCE(cetrafs_trim_hold_sync_off))
        return 0;
    ret = cetrafs_read_bg_geom(sb, run->bg_id, &bg);
    if (ret)
        return ret;
    first = cetrafs_bmap_blk(run->lba - bg.start_block - bg.off_data_region);
    last = cetrafs_bmap_blk(run->lba + run->count - 1 - bg.start_block - bg.off_data_region);
    for (blk = first; blk <= last && !ret; blk++)
        ret = cetrafs_sync_one_block(sb, bg.start_block + bg.off_data_bmap + blk);
    return ret;
}

/* A Block Group's data region, for a discard to check itself against. */
int cetrafs_bg_data_region(struct super_block *sb, u32 bg_id, u64 *out_start, u64 *out_count, u32 *out_owner_zg)
{
    struct cetrafs_bg_geom bg;
    int ret = cetrafs_read_bg_geom(sb, bg_id, &bg);

    if (ret)
        return ret;
    *out_start = bg.start_block + bg.off_data_region;
    *out_count = bg.data_block_count;
    *out_owner_zg = bg.owner_zg;
    return 0;
}

int cetrafs_bg_id_of_lba(struct super_block *sb, u64 lba, u32 *out_bg_id)
{
    return cetrafs_bg_id_for_lba(sb, lba, out_bg_id);
}
