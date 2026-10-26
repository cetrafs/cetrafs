// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/falloc.h>
#include <linux/fiemap.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/highmem.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/minmax.h>
#include <linux/mpage.h>
#include <linux/pagemap.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/uio.h>

#include "kmod.h"

/*
 * Internal signal from cetrafs_leaf_array_convert(): "the leaf is full,
 * I shrunk the extent in place, you append the block through the tree".
 *
 * Deliberately NOT an errno. It was -EAGAIN, and the depth-2 site --
 * which is every large VM image -- did not handle it, so it escaped
 * through cetrafs_get_block() into block_write_begin(), where io_uring
 * reads -EAGAIN as "retry" and spun forever: a worker stuck in D state
 * and a migration that never finished.
 *
 * A positive value cannot be mistaken for an error by any caller, and
 * the wrapper below refuses to return it at all -- so a site I forget
 * to handle fails loudly here instead of silently becoming a VFS
 * return code. Every later convert path inherits that for free.
 */
#define CETRAFS_CONVERT_APPEND 1

/* Debug-only timing: the per-new-block allocation path below is
 * node-exclusive by design (zonegroup.c's cetrafs_alloc_pick_bg() and
 * alloc.c's cetrafs_alloc_data_block()), so nothing else instruments
 * this half of a write's cost -- added after real two-node testing
 * reported a 1 MiB write as "still too slow" even once the ZG-ownership
 * scan and the global-inode-bitmap sync bugs were fixed. */
#define CETRAFS_SLOW_ALLOC_US 20000 /* 20ms */

static int cetrafs_get_block(struct inode *inode, sector_t iblock, struct buffer_head *bh_result, int create);
static int cetrafs_read_folio(struct file *file, struct folio *folio);
static int cetrafs_write_begin(const struct kiocb *iocb,
                               struct address_space *mapping,
                               loff_t pos,
                               unsigned len,
                               struct folio **foliop,
                               void **fsdata);
static int cetrafs_writepages(struct address_space *mapping, struct writeback_control *wbc);
static int cetrafs_open(struct inode *inode, struct file *file);
static int cetrafs_release(struct inode *inode, struct file *file);
static int cetrafs_fsync(struct file *file, loff_t start, loff_t end, int datasync);
static long cetrafs_fallocate(struct file *file, int mode, loff_t offset, loff_t len);
static long cetrafs_ioctl(struct file *file, unsigned int cmd, unsigned long arg);

/*
 * .open/.release (lock.c) enforce the cross-node exclusive open lock
 * -- every other op here predates that and is
 * unaffected: this lock only ever gates open()/close(), not read/write
 * once a file descriptor already exists.
 */
static loff_t cetrafs_llseek(struct file *file, loff_t offset, int whence);

const struct file_operations cetrafs_file_ops = {
    .owner = THIS_MODULE,
    .open = cetrafs_open,
    .release = cetrafs_release,
    .llseek = cetrafs_llseek,
    .read_iter = generic_file_read_iter,
    .write_iter = generic_file_write_iter,
    .mmap = generic_file_mmap,
    .fsync = cetrafs_fsync,
    .fallocate = cetrafs_fallocate,
    /*
     * flock(2): the userspace-driven whole-file exclusive lock. Under
     * `nofilelock` (the automatic lock off) an orchestrator holds the lock
     * during normal operation and releases it only for a live-migration
     * handoff. flock's lifetime -- the open file description, released on
     * close -- is exactly this lock's. See lock.c.
     */
    .flock = cetrafs_flock,
    .unlocked_ioctl = cetrafs_ioctl,
    /*
     * Without this, a 32-bit userspace on a 64-bit kernel gets -ENOTTY
     * for CETRAFS_IOC_DEFRAG: the VFS has no compat handler to route it
     * through. compat_ptr_ioctl() is the right one-liner here because
     * the argument is a plain pointer and struct cetrafs_defrag_stats is
     * three u64s -- same size and alignment under either ABI, so no
     * translation is needed beyond the pointer itself.
     */
    .compat_ioctl = compat_ptr_ioctl,
};

/*
 * O_DIRECT.
 *
 * Without this the VFS refuses O_DIRECT at open with -EINVAL, which
 * means a qemu guest configured cache=none -- Proxmox VE's DEFAULT disk
 * cache mode, and the one recommended for shared storage -- cannot open
 * its image at all.
 *
 * The legacy get_block-based path is the right fit here: cetrafs
 * already has a get_block_t whose read side leaves a hole unmapped
 * (the DIO code then zeroes it), and the alternative, iomap, would mean
 * porting the whole extent mapping to iomap_begin/iomap_end for no
 * behaviour this filesystem needs yet.
 *
 * Durability is deliberately the standard contract and not more:
 * O_DIRECT means "do not cache", not "is on stable storage" -- the data
 * reaches the device, but the extent that maps a newly allocated block
 * becomes durable at fsync, which is what qemu's flush barriers issue
 * and what F7's fix made correct. ext4 behaves the same way.
 */
static ssize_t cetrafs_direct_IO(struct kiocb *iocb, struct iov_iter *iter)
{
    struct inode *inode = iocb->ki_filp->f_mapping->host;

    if (iov_iter_rw(iter) == WRITE && cetrafs_sb_is_fenced(inode->i_sb))
        return -EIO; /* self-fenced: no new writes */

    return blockdev_direct_IO(iocb, inode, iter, cetrafs_get_block);
}

/*
 * Resolve an inode's extent array, whichever depth it is at.
 *
 * Depth 0 points straight into the record's inline array; depth 1 holds
 * the external leaf's buffer, which the caller releases with
 * cetrafs_inode_extents_put(). The leaf read follows the usual
 * freshness rule (cetrafs_read_leaf_bh()): cached while this node holds
 * the file's exclusive lock, forced-fresh otherwise.
 *
 * dir.c has its own copy of this (cetrafs_dir_extents_get()), and
 * truncate/punch/defrag below each open-code the same depth-1 read.
 * They should all end up here -- extents are this file's business --
 * but that migration is not worth bundling into an unrelated change.
 */
struct cetrafs_inode_extents {
    struct buffer_head *leaf_bh; /* held for depth 1 (arr points into it); NULL otherwise */
    cetrafs_extent_t *heap;      /* depth 2: a flattened copy, freed by _put; NULL otherwise */
    const cetrafs_extent_t *arr;
    u32 entries;                 /* u32: a depth-2 tree can hold far more than 65535 extents */
};

/*
 * Drop every CACHED external block of this file's extent tree.
 *
 * ONLY safe from a context holding no buffer lock. cetrafs_invalidate_
 * block() takes lock_buffer() unconditionally, and the extent-tree
 * writers hold a leaf locked across their journal write by protocol --
 * so calling this from the per-block freshness gate deadlocked the task
 * against a buffer its own stack already held, in D state, with nothing
 * in dmesg. cetrafs_lock_open() is the one caller: open is
 * where a handoff lands, and nothing is locked there.
 *
 * The walk must be FRESH (rule 1): a cached interior would enumerate
 * the leaves of the tree we are trying to stop believing in.
 *
 * Bounded by the format: at most 4 root slots, each an interior of at
 * most CETRAFS_EXT_BLOCK_MAX_IDX leaves.
 */
void cetrafs_tree_invalidate_cached(struct inode *inode, const cetrafs_inode_t *raw)
{
    struct super_block *sb = inode->i_sb;
    u16 depth = cetrafs_le16(raw->eh.eh_depth);
    u32 ni;

    if (depth == 0)
        return; /* inline extents only: nothing external is cached */

    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);

        if (depth == 1) {
            cetrafs_invalidate_block(sb, ilba); /* root slots are leaves */
            continue;
        }
        {
            struct buffer_head *ibh = cetrafs_bread_uncached_retry(sb, ilba);

            if (ibh) {
                const cetrafs_extent_hdr_t *ihdr = (const cetrafs_extent_hdr_t *) ibh->b_data;
                const cetrafs_extent_idx_t *iarr =
                    (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));
                u32 iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);
                u32 li;

                for (li = 0; li < iln; li++)
                    cetrafs_invalidate_block(
                        sb, cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo));
                brelse(ibh);
            }
            cetrafs_invalidate_block(sb, ilba);
        }
    }
}

/* v2: flatten every extent of a depth-2 tree into one heap array. The
 * tree is inode's 4 root index slots -> interior index blocks -> leaf
 * blocks -> extents; arrays are unordered (append-only), so a full scan
 * is required and that is exactly what the read-side callers (seek,
 * fiemap) do. Single pass, growing the buffer, bounded by the format's
 * structural maximum. */
int cetrafs_tree_flatten(struct inode *inode, const cetrafs_inode_t *raw, cetrafs_extent_t **out_arr,
                         u32 *out_n)
{
    cetrafs_extent_t *arr = NULL;
    u32 cap = 0, n = 0, ni;
    int ret = 0;

    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh(inode, ilba);
        const cetrafs_extent_hdr_t *ihdr;
        const cetrafs_extent_idx_t *iarr;
        u32 li, iln;

        if (!ibh) {
            ret = -EIO;
            goto fail;
        }
        ihdr = (const cetrafs_extent_hdr_t *) ibh->b_data;
        iarr = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));
        iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);

        for (li = 0; li < iln; li++) {
            u64 llba = cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo);
            struct buffer_head *lbh = cetrafs_read_leaf_bh(inode, llba);
            const cetrafs_extent_hdr_t *lhdr;
            u32 ln;

            if (!lbh) {
                brelse(ibh);
                ret = -EIO;
                goto fail;
            }
            lhdr = (const cetrafs_extent_hdr_t *) lbh->b_data;
            ln = min_t(u32, cetrafs_le16(lhdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);

            if (n + ln > cap) {
                u32 ncap = max_t(u32, cap ? cap * 2 : 512, n + ln);
                cetrafs_extent_t *narr = krealloc(arr, (size_t) ncap * sizeof(*narr), GFP_NOFS);

                if (!narr) {
                    brelse(lbh);
                    brelse(ibh);
                    ret = -ENOMEM;
                    goto fail;
                }
                arr = narr;
                cap = ncap;
            }
            memcpy(arr + n, lbh->b_data + sizeof(*lhdr), (size_t) ln * sizeof(*arr));
            n += ln;
            brelse(lbh);
        }
        brelse(ibh);
    }

    *out_arr = arr;
    *out_n = n;
    return 0;

fail:
    kfree(arr);
    return ret;
}

/* Walk one external leaf block's extents (read by LBA, plain cached). */
static int cetrafs_scrub_walk_leaf(struct super_block *sb, u64 lba,
                                   void (*cb)(void *, u64, u32), void *ctx)
{
    struct buffer_head *bh = sb_bread(sb, lba);
    const cetrafs_extent_hdr_t *hdr;
    const cetrafs_extent_t *arr;
    u32 ln, i;

    if (!bh)
        return -EIO;
    /*
     * The leaf block ITSELF, before its contents. It is an ordinary
     * allocated data-region block, and this inode is what references it
     * -- so a reference walk that emitted only the extents INSIDE it
     * left it looking like nothing pointed at it at all.
     *
     * That is the scrub's exact definition of a leaked block, so the
     * scrub freed live extent-tree metadata: the block went back to the
     * allocator, the next file wrote data into it, and the owning
     * inode's pointer then read as "extent index/leaf block N failed its
     * tail checksum -- corrupted", permanently, taking the whole tree
     * (and the ability to free the data it described) with it. Found on
     * real hardware, on the first depth-2 file a running
     * scrub ever met; every file in the loop suite is depth 0, where
     * there is no external block to lose. fsck's own walk had this right
     * all along -- see fsck.c's "the leaf block itself".
     */
    cb(ctx, lba, 1);
    hdr = (const cetrafs_extent_hdr_t *) bh->b_data;
    arr = (const cetrafs_extent_t *) (bh->b_data + sizeof(*hdr));
    ln = min_t(u32, cetrafs_le16(hdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);
    for (i = 0; i < ln; i++)
        cb(ctx, cetrafs_extent_phys_from_hilo(arr[i].ee_start_hi, arr[i].ee_start_lo),
           cetrafs_extent_len(arr[i].ee_len));
    brelse(bh);
    return 0;
}

/*
 * Report EVERY data-region block this inode owns: its data extents, the
 * extent tree's own external leaf and interior index blocks, and its
 * xattr block. Reads external tree blocks by LBA with plain cached
 * reads -- the background scrub (scrub.c, the only caller) holds no
 * struct inode and reads conservatively. Returns -EIO on any
 * unreadable/invalid tree block so the caller treats this inode's
 * references as UNKNOWN and frees nothing (it must never risk a live
 * block over a bad read).
 *
 * THE CONTRACT IS COMPLETENESS, and it is load-bearing: the scrub frees
 * every allocated data-region block this walk does not report. Miss a
 * block type and the scrub hands live metadata back to the allocator,
 * which is silent corruption of whatever owned it.
 *
 * This was called ..._for_each_extent() and reported only the data
 * extents, which cost exactly that twice over: the tree's own leaf and
 * index blocks were freed under live files (seen on real hardware as
 * "extent index block N failed its tail checksum", permanently), and
 * the xattr block would have gone the same way on any file carrying an
 * xattr -- every file on an SELinux-enforcing host. The name says
 * "owned block" now, not "extent", because the question this answers is
 * what the inode OWNS, and the only safe way to add a new kind of
 * data-region block is to add it here too. The complete list of
 * allocators is the check: grep cetrafs_alloc_data_block() -- dir.c
 * (dirent blocks, reached through the extents), file.c (data, leaf,
 * index), xattr.c (the xattr block).
 */
int cetrafs_raw_inode_for_each_owned_block(struct super_block *sb, const cetrafs_inode_t *raw,
                                           void (*cb)(void *ctx, u64 phys, u32 len), void *ctx)
{
    u16 depth;
    u32 i, n;

    /* The xattr block is owned by the inode directly, not through the
     * extent tree, so it is reported before any tree walk -- and even
     * for a record whose tree is empty or malformed below. */
    if (raw->xattr_block)
        cb(ctx, cetrafs_le64(raw->xattr_block), 1);

    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC)
        return -EIO;
    depth = cetrafs_le16(raw->eh.eh_depth);
    if (depth > CETRAFS_EXT_MAX_DEPTH)
        return -EIO;

    if (depth == 0) {
        n = min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf));
        for (i = 0; i < n; i++)
            cb(ctx, cetrafs_extent_phys_from_hilo(raw->et.leaf[i].ee_start_hi, raw->et.leaf[i].ee_start_lo),
               cetrafs_extent_len(raw->et.leaf[i].ee_len));
        return 0;
    }

    n = min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.idx));
    for (i = 0; i < n; i++) {
        u64 lba = cetrafs_extent_phys_from_hilo(raw->et.idx[i].ei_leaf_hi, raw->et.idx[i].ei_leaf_lo);
        int ret;

        if (depth == 1) {
            ret = cetrafs_scrub_walk_leaf(sb, lba, cb, ctx);
            if (ret)
                return ret;
        } else {
            struct buffer_head *ibh = sb_bread(sb, lba);
            const cetrafs_extent_hdr_t *ihdr;
            const cetrafs_extent_idx_t *iarr;
            u32 li, iln;

            if (!ibh)
                return -EIO;
            cb(ctx, lba, 1); /* the interior block itself -- see above */
            ihdr = (const cetrafs_extent_hdr_t *) ibh->b_data;
            iarr = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));
            iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);
            for (li = 0; li < iln; li++) {
                u64 llba = cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo);

                ret = cetrafs_scrub_walk_leaf(sb, llba, cb, ctx);
                if (ret) {
                    brelse(ibh);
                    return ret;
                }
            }
            brelse(ibh);
        }
    }
    return 0;
}

static int cetrafs_inode_extents_get(struct inode *inode, const cetrafs_inode_t *raw, struct cetrafs_inode_extents *ex)
{
    u64 leaf_lba;

    ex->leaf_bh = NULL;
    ex->heap = NULL;
    ex->arr = NULL;
    ex->entries = 0;

    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(raw->eh.eh_depth) > CETRAFS_EXT_MAX_DEPTH)
        return -EIO;

    if (raw->eh.eh_depth == 0) {
        ex->arr = raw->et.leaf;
        ex->entries = min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf));
        return 0;
    }

    if (cetrafs_le16(raw->eh.eh_depth) == 2) {
        int ret = cetrafs_tree_flatten(inode, raw, &ex->heap, &ex->entries);

        if (ret)
            return ret;
        ex->arr = ex->heap;
        return 0;
    }

    leaf_lba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
    ex->leaf_bh = cetrafs_read_leaf_bh(inode, leaf_lba);
    if (!ex->leaf_bh)
        return -EIO;

    ex->arr = (const cetrafs_extent_t *) (ex->leaf_bh->b_data + sizeof(cetrafs_extent_hdr_t));
    ex->entries =
        min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) ex->leaf_bh->b_data)->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);
    return 0;
}

static void cetrafs_inode_extents_put(struct cetrafs_inode_extents *ex)
{
    if (ex->leaf_bh)
        brelse(ex->leaf_bh);
    kfree(ex->heap);
    ex->leaf_bh = NULL;
    ex->heap = NULL;
}

/*
 * SEEK_DATA/SEEK_HOLE.
 *
 * The filesystem has always supported sparse files -- a hole is an
 * unmapped logical block that reads as zeros -- but nothing could ask
 * WHERE the holes were, so `cp --sparse=auto`, `tar -S` and
 * `qemu-img convert` all copied them as zeros. A thin 500 GB VM image
 * became 500 GB on the way in or out, which is the single most visible
 * thing this filesystem got wrong for its own workload.
 *
 * **The extent array is NOT sorted.** cetrafs_leaf_array_insert()
 * appends and only ever merges with the LAST entry, so a file written
 * at descending offsets has its extents in the order they were created,
 * not in logical order. Both scans below therefore consider every entry
 * rather than stopping at the first match -- assuming order here would
 * give confidently wrong answers on exactly the files (randomly
 * written VM images) this exists to serve.
 */
static bool cetrafs_extent_covers(const cetrafs_extent_t *e, u64 iblock, u64 *out_end)
{
    u64 start = cetrafs_le32(e->ee_block);
    u64 end = start + cetrafs_extent_len(e->ee_len);

    if (out_end)
        *out_end = end;
    return iblock >= start && iblock < end;
}

/* First mapped block at or after `from`, or U64_MAX if there is none. */
static u64 cetrafs_next_data_block(const struct cetrafs_inode_extents *ex, u64 from)
{
    u64 best = U64_MAX;
    u32 i;

    for (i = 0; i < ex->entries; i++) {
        u64 start = cetrafs_le32(ex->arr[i].ee_block);
        u64 end = start + cetrafs_extent_len(ex->arr[i].ee_len);

        if (end <= from)
            continue; /* entirely behind us */
        if (start < from)
            return from; /* `from` itself is mapped -- cannot do better */
        if (start < best)
            best = start;
    }
    return best;
}

/* First unmapped block at or after `from`. Walks forward across
 * adjacent extents, since the next one may begin exactly where this one
 * ends -- and, the array being unsorted, that next one can be anywhere
 * in it. */
static u64 cetrafs_next_hole_block(const struct cetrafs_inode_extents *ex, u64 from, u64 nblocks)
{
    while (from < nblocks) {
        bool covered = false;
        u64 end = 0;
        u32 i;

        for (i = 0; i < ex->entries; i++) {
            u64 e;

            if (cetrafs_extent_covers(&ex->arr[i], from, &e)) {
                covered = true;
                end = e;
                break;
            }
        }
        if (!covered)
            return from;
        from = end;
    }
    return nblocks; /* everything to EOF is data; EOF itself is the hole */
}

static loff_t cetrafs_seek_hole_data(struct file *file, loff_t offset, int whence)
{
    struct inode *inode = file->f_mapping->host;
    struct cetrafs_inode_extents ex;
    cetrafs_inode_t raw;
    loff_t isize, ret;
    u64 iblock, found, nblocks;

    inode_lock_shared(inode);
    isize = i_size_read(inode);

    /* Both operations are undefined past EOF, and a negative offset is
     * never valid. ext4, tmpfs and xfs all answer -ENXIO here. */
    if (offset < 0 || offset >= isize) {
        inode_unlock_shared(inode);
        return -ENXIO;
    }

    ret = cetrafs_read_raw_inode(inode->i_sb, inode->i_ino, &raw);
    if (ret)
        goto out;
    cetrafs_inode_fd_overlay(inode, &raw); /* the hot path's pending extents (v0x0005) */

    ret = cetrafs_inode_extents_get(inode, &raw, &ex);
    if (ret)
        goto out;

    iblock = (u64) offset / CETRAFS_BLOCK_SIZE;
    nblocks = ((u64) isize + CETRAFS_BLOCK_SIZE - 1) / CETRAFS_BLOCK_SIZE;

    if (whence == SEEK_DATA) {
        found = cetrafs_next_data_block(&ex, iblock);
        if (found == U64_MAX || found >= nblocks) {
            cetrafs_inode_extents_put(&ex);
            ret = -ENXIO; /* nothing but hole between here and EOF */
            goto out;
        }
        /* Staying inside the block we were already in means the answer
         * is the caller's own offset, not the block boundary below it. */
        ret = (found == iblock) ? offset : (loff_t) (found * CETRAFS_BLOCK_SIZE);
    } else {
        found = cetrafs_next_hole_block(&ex, iblock, nblocks);
        ret = (found == iblock) ? offset : (loff_t) (found * CETRAFS_BLOCK_SIZE);
        if (ret > isize)
            ret = isize; /* EOF is a hole, but never report past it */
    }

    cetrafs_inode_extents_put(&ex);

out:
    inode_unlock_shared(inode);
    if (ret < 0)
        return ret;
    return vfs_setpos(file, ret, inode->i_sb->s_maxbytes);
}

/*
 * FS_IOC_FIEMAP.
 *
 * The other half of the sparse-file story. SEEK_HOLE/SEEK_DATA answers
 * what the copy tools ask; this answers what everything else asks --
 * `filefrag`, and anything wanting the layout rather than probing for
 * it. Without it this filesystem has a whole online defragmenter whose
 * work cannot be observed.
 *
 * Reuses the same accessor and the same unsorted-array rule as the seek
 * pair: cetrafs_leaf_array_insert() appends and merges only with the
 * last entry, so the array is in creation order. FIEMAP's contract is
 * that extents come back in increasing logical order, so this walks the
 * array once per emitted extent, taking the lowest ee_block still
 * ahead of the previous one -- O(n^2) on at most 343 entries, bounded
 * and paid only by a tool that asked for the map.
 */
int cetrafs_fiemap(struct inode *inode, struct fiemap_extent_info *fi, u64 start, u64 len)
{
    struct cetrafs_inode_extents ex;
    cetrafs_inode_t raw;
    u64 cursor, end;
    int ret;

    ret = fiemap_prep(inode, fi, start, &len, 0);
    if (ret)
        return ret;

    inode_lock_shared(inode);

    ret = cetrafs_read_raw_inode(inode->i_sb, inode->i_ino, &raw);
    if (ret)
        goto out;
    cetrafs_inode_fd_overlay(inode, &raw); /* the hot path's pending extents (v0x0005) */
    ret = cetrafs_inode_extents_get(inode, &raw, &ex);
    if (ret)
        goto out;

    end = start + len;
    cursor = 0; /* lowest ee_block not yet emitted */
    for (;;) {
        u64 best_start = U64_MAX, best_len = 0, best_phys = 0;
        u64 logical, phys, blen;
        u32 flags = 0;
        u32 i;

        for (i = 0; i < ex.entries; i++) {
            u64 s = cetrafs_le32(ex.arr[i].ee_block);

            if (s < cursor)
                continue;
            if (s < best_start) {
                best_start = s;
                best_len = cetrafs_extent_len(ex.arr[i].ee_len);
                best_phys = cetrafs_extent_phys_from_hilo(ex.arr[i].ee_start_hi, ex.arr[i].ee_start_lo);
            }
        }
        if (best_start == U64_MAX)
            break;

        cursor = best_start + best_len;
        logical = best_start * CETRAFS_BLOCK_SIZE;
        blen = best_len * CETRAFS_BLOCK_SIZE;
        phys = best_phys * CETRAFS_BLOCK_SIZE;

        if (logical >= end)
            break;
        if (logical + blen <= start)
            continue;

        /* LAST means "no extent begins after this one", which with an
         * unsorted array is a second scan, not a loop-position test. */
        {
            bool more = false;

            for (i = 0; i < ex.entries; i++) {
                if (cetrafs_le32(ex.arr[i].ee_block) >= cursor) {
                    more = true;
                    break;
                }
            }
            if (!more)
                flags |= FIEMAP_EXTENT_LAST;
        }

        ret = fiemap_fill_next_extent(fi, logical, phys, blen, flags);
        if (ret) {
            /* 1 means the caller's buffer is full: a complete answer
             * for what it asked for, not an error. */
            if (ret == 1)
                ret = 0;
            break;
        }
    }
    cetrafs_inode_extents_put(&ex);

out:
    inode_unlock_shared(inode);
    return ret;
}

static loff_t cetrafs_llseek(struct file *file, loff_t offset, int whence)
{
    if (whence == SEEK_DATA || whence == SEEK_HOLE)
        return cetrafs_seek_hole_data(file, offset, whence);
    return generic_file_llseek(file, offset, whence);
}

const struct address_space_operations cetrafs_aops = {
    .direct_IO = cetrafs_direct_IO,
    .read_folio = cetrafs_read_folio,
    .writepages = cetrafs_writepages,
    .write_begin = cetrafs_write_begin,
    .write_end = generic_write_end,
    /*
     * These folios carry buffer heads, so migration must move the
     * buffers with them. Without it compaction takes a generic path
     * that does not expect attached private data. NULL when
     * CONFIG_MIGRATION is off, which is why it needs no #ifdef.
     */
    .migrate_folio = buffer_migrate_folio,
    /*
     * Required because these folios carry BUFFER HEADS (block_write_
     * begin / block_read_full_folio attach them). Without
     * .invalidate_folio, truncate_inode_pages_range() cancels the
     * FOLIO's dirty bit but leaves each attached buffer's own dirty bit
     * set, and try_to_free_buffers() refuses to free a dirty buffer --
     * so the discarded folio can never be reclaimed. Measured: 40 cycles
     * of dirtying 2 MB and truncating it away grew the buffer_head slab
     * by ~20100 objects (about one per block written) and they did not
     * come back at unmount.
     *
     * (.release_folio is deliberately NOT set: this kernel exports no
     * block_release_folio, and filemap_release_folio() already falls
     * back to try_to_free_buffers() when it is absent, which is exactly
     * what that helper does.)
     */
    .invalidate_folio = block_invalidate_folio,
    /*
     * MANDATORY, and its absence was a kernel NULL-pointer dereference
     * reachable by any user.
     *
     * folio_mark_dirty() calls a_ops->dirty_folio with no NULL check.
     * The write path never reached it -- block_write_begin/
     * generic_write_end dirty the folio themselves -- but a SHARED
     * WRITABLE MAPPING does: the first store into a clean mapped page
     * faults to filemap_page_mkwrite(), which calls folio_mark_dirty().
     * With this NULL that is a jump to address 0. Measured: an mmap of
     * a file, one assignment, and the kernel Oopsed with
     * "pc : 0x0" under filemap_page_mkwrite(), twice, leaving the
     * faulting tasks unkillable in exit_mmap().
     *
     * block_dirty_folio is the buffer-head variant, which is what this
     * address space needs -- its folios carry buffers, and the generic
     * filemap_dirty_folio() would not mark them dirty.
     *
     * .mmap has been advertised in cetrafs_file_ops since the beginning
     * and nothing ever tested it.
     */
    .dirty_folio = block_dirty_folio,
};

/* Free every physical block listed in one leaf array (inline or external),
 * shared by cetrafs_free_inline_extents() below and by truncate's shrink
 * path's "drop the whole thing" case. */
static void cetrafs_free_leaf_array(struct super_block *sb, const cetrafs_extent_t *arr, u16 entries)
{
    u16 i;

    /* Whole-extent frees, not per-block: besides fewer bitmap RMWs, a
     * free aimed at another node's ZG becomes ONE pending-free queue
     * entry (one cluster-mutex cycle) per extent instead of one per
     * block -- see cetrafs_free_data_extent(). */
    for (i = 0; i < entries; i++) {
        u64 phys = cetrafs_extent_phys_from_hilo(arr[i].ee_start_hi, arr[i].ee_start_lo);
        u32 len = cetrafs_extent_len(arr[i].ee_len);

        cetrafs_free_data_extent(sb, phys, len);
    }
}

void cetrafs_tree_free_meta(struct inode *inode, const cetrafs_inode_t *raw);

/*
 * Free every data block owned by a file's extent list -- inline (depth-0),
 * or spilled into one external leaf block (depth-1, freed too) -- shared by
 * unlink (nlink reaches 0) and rmdir. Despite the 'dir' parameter name
 * (kept for its two existing callers), this works on any inode's raw
 * record: only dir->i_sb is used.
 */
void cetrafs_free_inline_extents(struct inode *dir, const cetrafs_inode_t *raw)
{
    struct super_block *sb = dir->i_sb;

    if (raw->eh.eh_depth == 0) {
        cetrafs_free_leaf_array(sb, raw->et.leaf, min_t(u16, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf)));
        return;
    }

    /* Depth 1 or 2: free every DATA extent, then every META block
     * (leaves + interiors). cetrafs_inode_extents_get() resolves ALL
     * depths (depth 1 reads the one leaf; depth 2 flattens) -- unlike
     * cetrafs_tree_flatten(), which assumes the depth-2 layout where the
     * root slots are interiors, and would misread a depth-1 directory's
     * direct leaf pointer. A read error here leaks rather than corrupts
     * (the best-effort posture the rest of evict_inode takes), logged. */
    {
        struct cetrafs_inode_extents ex;
        int ret = cetrafs_inode_extents_get(dir, raw, &ex);

        if (ret == 0) {
            u32 i;

            for (i = 0; i < ex.entries; i++)
                cetrafs_free_data_extent(sb,
                                         cetrafs_extent_phys_from_hilo(ex.arr[i].ee_start_hi, ex.arr[i].ee_start_lo),
                                         cetrafs_extent_len(ex.arr[i].ee_len));
            cetrafs_inode_extents_put(&ex);
        } else {
            pr_err("ino=%llu: could not read extent tree to free it (%d) -- data blocks leaked\n",
                   (unsigned long long) dir->i_ino, ret);
        }
        cetrafs_tree_free_meta(dir, raw);
    }
}

/* Find the extent covering 'iblock' in a leaf array (inline or external),
 * returning its physical LBA. Shared by both locations an extent array can
 * live in. */
/*
 * Find iblock's physical LBA, and report how many blocks of the covering
 * extent follow it CONTIGUOUSLY (*out_run, always >= 1 on a hit).
 *
 * The run is what lets cetrafs_get_block() answer a multi-block mapping
 * instead of one block at a time. map_bh() hard-sets b_size to a single
 * block, so without this every caller has to come back per 4 KiB -- for
 * O_DIRECT, which has no page cache to amortise it, that is one callback
 * per block of the whole request even when the file is a single extent.
 *
 * Only WITHIN one extent: the arrays are append-only and unordered at
 * every depth, so two extents that happen to be physically adjacent are
 * not necessarily adjacent in the array, and finding that out would cost
 * a scan per lookup. One extent's worth is the cheap, always-correct
 * answer, and a contiguous file is one extent anyway.
 */
static bool cetrafs_leaf_array_lookup(const cetrafs_extent_t *arr, u16 entries, u32 iblock, u64 *out_lba, u32 *out_run,
                                      bool *out_uninit)
{
    u16 i;

    for (i = 0; i < entries; i++) {
        u32 len = cetrafs_extent_len(arr[i].ee_len);
        u32 eb = cetrafs_le32(arr[i].ee_block);

        if (iblock >= eb && iblock < (u64) eb + len) {
            *out_lba = cetrafs_extent_phys_from_hilo(arr[i].ee_start_hi, arr[i].ee_start_lo) + (iblock - eb);
            if (out_run)
                *out_run = len - (iblock - eb);
            if (out_uninit)
                *out_uninit = cetrafs_extent_is_uninit(arr[i].ee_len);
            return true;
        }
    }
    return false;
}

/* The LBA right after a leaf array's last entry -- i.e. the block that
 * would let cetrafs_leaf_array_insert() below merge instead of appending
 * a new extent, if the next allocation lands exactly there. 0 ("no
 * preference") when the array is empty, since LBA 0 is always the
 * superblock and never a valid data block -- callers pass this straight
 * to cetrafs_alloc_data_block_near(), which treats 0 the same way. */
static u64 cetrafs_leaf_array_next_contig_lba(const cetrafs_extent_t *arr, u16 entries)
{
    const cetrafs_extent_t *last;
    u32 len;

    if (entries == 0)
        return 0;

    last = &arr[entries - 1];
    len = cetrafs_extent_len(last->ee_len);
    return cetrafs_extent_phys_from_hilo(last->ee_start_hi, last->ee_start_lo) + len;
}

/* Record a newly allocated block covering 'iblock' in a leaf array (inline
 * or external), merging it into the last entry if it lands immediately
 * after it both logically and physically, else appending a new entry.
 * Returns 0, or -ENOSPC if the array is full and the last entry can't be
 * extended. */
static int cetrafs_leaf_array_insert(cetrafs_extent_t *arr, __le16 *entries, u16 max, u32 iblock, u64 lba,
                                     u32 count, bool uninit);

/* Preallocated blocks RELEASED because an extent split had no room --
 * the give-back. It is a last resort: the middle split now puts the
 * tail in the free slot and grows the tree instead, so under a normal
 * workload this must stay at or near zero. It reached hundreds per
 * write on the deployment cluster, one free_data_block() each. */
static atomic64_t cetrafs_giveback_blocks = ATOMIC64_INIT(0);

u64 cetrafs_giveback_block_count(void)
{
    return (u64) atomic64_read(&cetrafs_giveback_blocks);
}

/*
 * Convert the single block 'iblock' of a PREALLOCATED (uninit) extent to
 * initialised, in one leaf array.
 *
 * fallocate(ALLOCATE) reserves blocks whose contents are undefined; the
 * first write to one of them must mark exactly that block initialised
 * and leave the rest preallocated. That means splitting the extent.
 *
 * The naive split is a disaster: one write per block turns a 1 GiB
 * preallocated extent into a quarter-million extents. What saves it is
 * that cetrafs_leaf_array_insert() merges into the LAST entry, so a
 * SEQUENTIAL write collapses -- shrink the uninit extent from the front
 * and append the initialised block, and the appended block merges into
 * the initialised extent the previous write left behind. A full
 * sequential overwrite of a preallocated file therefore ends at exactly
 * two entries, [initialised][preallocated remainder], however long it
 * is. Random writes genuinely do fragment; that is inherent.
 *
 * Three shapes, by where the block sits in the extent:
 *   front  shrink it forward (ee_block++, phys++, len--), drop at len 0
 *   back   shrink it (len--)
 *   middle keep the head, append the tail as a second uninit extent
 * then append the block itself as initialised.
 *
 * Needs up to 2 free slots (middle case). Returns -ENOSPC untouched if
 * they are not there, so the caller can fall back rather than leave a
 * half-split array: nothing is modified until the room is known.
 */
static int cetrafs_leaf_array_convert(struct super_block *sb, cetrafs_extent_t *arr, __le16 *entries, u16 max,
                                      u32 iblock, u64 lba, u32 want, u32 *done)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u16 n = cetrafs_le16(*entries), i;
    u64 total_blocks;

    if (n > max || !raw_sb)
        return -EIO;
    total_blocks = le64_to_cpu(raw_sb->total_blocks);

    for (i = 0; i < n; i++) {
        u32 len = cetrafs_extent_len(arr[i].ee_len);
        u32 eb = cetrafs_le32(arr[i].ee_block);
        u32 count;
        u64 phys = cetrafs_extent_phys_from_hilo(arr[i].ee_start_hi, arr[i].ee_start_lo);
        bool middle;

        if (!cetrafs_extent_is_uninit(arr[i].ee_len) || iblock < eb || iblock >= (u64) eb + len)
            continue;

        /*
         * A corrupt-but-checksum-VALID extent, the same class
         * cetrafs_leaf_array_insert() guards eh_entries against. The
         * fields fuzzer restamps the CRC, so the record passes every
         * integrity check and still says len = 1302593496 on a 560 MiB
         * image -- and the tail release below then calls
         * cetrafs_free_data_block() 1.3 BILLION times, which is the "op
         * hang" that fuzz mount-fields reported (iter121, seed
         * 68728367). The loop is bounded by a number the device cannot
         * back, so bound it by the device.
         *
         * Checked here rather than at the free: an extent whose range
         * does not fit the volume is garbage whichever branch we take,
         * and splitting it would publish that garbage.
         */
        if (len == 0 || (u64) eb + len > CETRAFS_MAX_FILE_BLOCKS || phys + len > total_blocks) {
            pr_err_ratelimited("extent [block %u +%u] at lba %llu does not fit the volume (%llu blocks) -- corrupt\n",
                               eb, len, (unsigned long long) phys, (unsigned long long) total_blocks);
            return -EUCLEAN;
        }

        /*
         * Convert the whole RUN the caller asked for, not one block.
         *
         * One block at a time meant a 1 MiB guest write became 256
         * get_block calls, each walking the tree and re-reading the
         * inode record: measured on the deployment SAN at 23281
         * get_block calls for 90 MB in ten seconds -- 9 MB/s, against
         * 480 MB/s for the same writes once the blocks were already
         * converted. That gap is why a VM's throughput looked random:
         * it depended entirely on whether the region had been written
         * before.
         */
        count = (u32) min_t(u64, want, (u64) eb + len - iblock);
        if (!count)
            count = 1;

        middle = (iblock > eb) && ((u64) iblock + count < (u64) eb + len);

        /*
         * Room check BEFORE any mutation.
         *
         * A FULL leaf used to fail here with -ENOSPC, silently. That is
         * the whole "VM pauses on nospace with terabytes free" bug: a
         * qcow2 preallocated by fallocate() is made of UNINIT extents,
         * every guest write into one has to split it, a split needs a
         * free slot, and once that leaf's array filled there was none.
         * Nothing grew the tree and nothing logged it -- the adjacent
         * "extent leaf full" message below covers only the case where
         * ONE slot was still free, which is why the logs stayed empty.
         * Found: by kretprobe, after the allocator had been
         * exonerated twice over.
         *
         * Do here what that case already does one level down: GIVE THE
         * PREALLOCATION BACK rather than fail a legal write. The blocks
         * around the written one have never been written, so releasing
         * them costs no data -- the range becomes an ordinary hole,
         * which reads as zeroes exactly as a preallocated extent does,
         * and a later write to it allocates normally. What is lost is
         * the fallocate() reservation over that range: a
         * quality-of-service property, not a correctness one. Loud,
         * because it means the reservation stopped being honoured.
         *
         * The entry is rewritten IN PLACE to cover exactly the written
         * block, so this needs no slot at all and cannot fail.
         */
        if (n + 1 > max) {
            /*
             * Leaf full. Earlier this failed the write outright with a
             * silent -ENOSPC (the VM-pauses-on-nospace bug), and then
             * briefly "solved" it by releasing every preallocated block
             * around the written one -- which kept the leaf full, so
             * EVERY later write took the same path, freeing blocks and
             * rewriting the entry. The guest went from stopped to
             * unusably slow.
             *
             * The leaf being full is not a reason to destroy the
             * preallocation; it is a reason to GROW THE TREE. Shrink
             * this extent in place so it no longer covers iblock --
             * that needs no slot and cannot fail -- and hand the
             * converted block back to the caller to append through the
             * tree, where a new leaf gets allocated as normal.
             */
            u32 head = iblock - eb;
            u32 tail;

            /* Rare path (leaf full). Stay single-block here: the run
             * optimisation below is what carries the common case, and
             * the append this hands back converts one block. */
            count = 1;
            tail = len - head - 1;

            if (len == 1) {
                /* The extent was only this block: dropping it FREES a
                 * slot, so the ordinary insert below fits after all.
                 * The array is unordered, so the last entry fills the
                 * gap. */
                arr[i] = arr[n - 1];
                *entries = cetrafs_cpu_to_le16(--n);
                *done = 1;
                return cetrafs_leaf_array_insert(arr, entries, max, iblock, lba, 1, /*uninit=*/false);
            }
            if (head == 0) {
                arr[i].ee_block = cetrafs_cpu_to_le32(eb + 1);
                arr[i].ee_len = cetrafs_extent_pack_len(len - 1, true);
                cetrafs_extent_phys_to_hilo(phys + 1, &arr[i].ee_start_hi, &arr[i].ee_start_lo);
            } else if (tail == 0) {
                arr[i].ee_len = cetrafs_extent_pack_len(head, true);
            } else {
                /* Split in the middle with no slot for the tail: keep
                 * the head, give the tail back. Same trade the
                 * one-slot-free case below already makes, and only the
                 * tail -- not everything around the block. */
                u32 k;

                arr[i].ee_len = cetrafs_extent_pack_len(head, true);
                pr_warn_ratelimited(
                    "extent leaf full splitting a preallocated extent: releasing %u block(s) at %llu "
                    "(they become a hole; no data is lost)\n",
                    tail, (unsigned long long) (phys + head + 1));
                for (k = 0; k < tail; k++)
                    cetrafs_free_data_block(sb, phys + head + 1 + k);
            }
            /* Leaf updated and the slot requirement is gone; the caller
             * appends the converted block through the tree. */
            *done = 1;
            return CETRAFS_CONVERT_APPEND;
        }

        if (middle) {
            u32 head = iblock - eb;

            arr[i].ee_len = cetrafs_extent_pack_len(head, true);

            if (n + 2 <= max) {
                arr[n].ee_block = cetrafs_cpu_to_le32(iblock + count);
                arr[n].ee_len = cetrafs_extent_pack_len(len - head - count, true);
                cetrafs_extent_phys_to_hilo(phys + head + count, &arr[n].ee_start_hi, &arr[n].ee_start_lo);
                *entries = cetrafs_cpu_to_le16(++n);
            } else if (n + 1 <= max) {
                /*
                 * One slot free, and a middle split wants two. Put the
                 * TAIL in it and send the CONVERTED block through the
                 * tree, where a new leaf is allocated as normal --
                 * nothing is given back and no block is freed.
                 *
                 * This used to release the tail instead, one
                 * cetrafs_free_data_block() per block, up to ~200 of
                 * them per write, each a BG lookup and a bitmap or
                 * foreign-queue update. On the deployment cluster that
                 * was ~55 ms per split with the log full of "extent
                 * leaf full splitting a preallocated extent", and it
                 * never stopped, because giving the tail back does
                 * nothing to free the SLOT the next split needs.
                 */
                arr[n].ee_block = cetrafs_cpu_to_le32(iblock + count);
                arr[n].ee_len = cetrafs_extent_pack_len(len - head - count, true);
                cetrafs_extent_phys_to_hilo(phys + head + count, &arr[n].ee_start_hi, &arr[n].ee_start_lo);
                *entries = cetrafs_cpu_to_le16(++n);
                *done = count;
                return CETRAFS_CONVERT_APPEND;
            } else {
                /*
                 * No slot at all. Rather than fail a perfectly
                 * legal write with -ENOSPC, GIVE THE TAIL BACK: those
                 * blocks are preallocated and have never been written,
                 * so releasing them costs no data -- the range becomes
                 * an ordinary hole, which reads as zeroes exactly as a
                 * preallocated extent did, and a later write to it
                 * allocates normally.
                 *
                 * All that is lost is the preallocation guarantee over
                 * that range, which is a quality-of-service property,
                 * not a correctness one. Loud, because it means a
                 * fallocate() reservation silently stopped being
                 * honoured.
                 */
                u32 tail = len - head - count;
                u64 tlba = phys + head + count;

                pr_warn_ratelimited(
                    "extent leaf full splitting a preallocated extent: releasing %u preallocated block(s) at %llu "
                    "(they become a hole; no data is lost)\n",
                    tail, (unsigned long long) tlba);
                /* One extent free, not 'tail' separate ones: each
                 * cetrafs_free_data_block() is a BG lookup plus a
                 * bitmap or foreign-queue update. */
                atomic64_add(tail, &cetrafs_giveback_blocks);
                (void) cetrafs_free_data_extent(sb, tlba, tail);
            }
        } else if (iblock == eb) {
            if (len == count) {
                /* The run covered the whole extent: drop it. The array
                 * is unordered, so the last entry fills the gap. */
                arr[i] = arr[n - 1];
                *entries = cetrafs_cpu_to_le16(--n);
            } else {
                arr[i].ee_block = cetrafs_cpu_to_le32(eb + count);
                arr[i].ee_len = cetrafs_extent_pack_len(len - count, true);
                cetrafs_extent_phys_to_hilo(phys + count, &arr[i].ee_start_hi, &arr[i].ee_start_lo);
            }
        } else {
            arr[i].ee_len = cetrafs_extent_pack_len(len - count, true);
        }

        *done = count;
        return cetrafs_leaf_array_insert(arr, entries, max, iblock, lba, count, /*uninit=*/false);
    }

    return -ENOENT; /* not covered by a preallocated extent here */
}

/*
 * Append one block at 'iblock' -> 'lba', merging into the last entry
 * when it is physically and logically contiguous.
 *
 * 'uninit' marks the new entry as PREALLOCATED-BUT-NEVER-WRITTEN
 * (fallocate(ALLOCATE)): the blocks are owned and on the bitmap, but
 * their contents are undefined and must read as zeroes.
 *
 * The merge must not cross that boundary IN EITHER DIRECTION, and that
 * is the whole reason this takes a flag. Folding an initialised block
 * into a preallocated extent would silently declare never-written
 * blocks initialised, and a reader would get whatever the previous
 * owner of those blocks left there -- a data leak, not merely stale
 * content. Folding the other way would lose real data behind a
 * reads-as-zero extent. Only like merges with like.
 */
static int cetrafs_leaf_array_insert(cetrafs_extent_t *arr, __le16 *entries, u16 max, u32 iblock, u64 lba,
                                     u32 count, bool uninit)
{
    u16 n = cetrafs_le16(*entries);

    if (!count)
        return -EINVAL;

    /* A corrupt-but-checksum-valid eh_entries far past the array capacity
     * (a stage-2 fuzz finding: a restamped inode with eh_entries=65535)
     * must be rejected BEFORE arr[n-1] below -- that merge read is an
     * out-of-bounds access that Oopsed the kernel, and because the Oops
     * unwound cetrafs_write_begin() without releasing its folio lock, the
     * next umount's evict_inode hung forever in truncate_inode_pages
     * waiting on that folio (an unkillable D-state wedge needing a reboot).
     * n can never legitimately exceed the array capacity; returning an
     * error here lets block_write_begin() unlock the folio normally. */
    if (n > max)
        return -EIO;

    if (n > 0) {
        cetrafs_extent_t *last = &arr[n - 1];
        u32 len = cetrafs_extent_len(last->ee_len);
        u64 last_phys = cetrafs_extent_phys_from_hilo(last->ee_start_hi, last->ee_start_lo);

        if ((u64) cetrafs_le32(last->ee_block) + len == iblock && last_phys + len == lba &&
            (u64) len + count <= CETRAFS_EXT_LEN_MASK && cetrafs_extent_is_uninit(last->ee_len) == (int) uninit) {
            last->ee_len = cetrafs_extent_pack_len(len + count, uninit);
            return 0;
        }
    }

    if (n >= max)
        return -ENOSPC;

    arr[n].ee_block = cetrafs_cpu_to_le32(iblock);
    arr[n].ee_len = cetrafs_extent_pack_len(count, uninit);
    cetrafs_extent_phys_to_hilo(lba, &arr[n].ee_start_hi, &arr[n].ee_start_lo);
    *entries = cetrafs_cpu_to_le16(n + 1);
    return 0;
}

/*
 * Drop every block at or past logical offset 'new_block_count' from a leaf
 * array (inline or external), freeing their physical blocks and trimming
 * (or dropping) the entries that covered them. The mirror of
 * cetrafs_leaf_array_insert(), used by truncate's shrink path. Returns the
 * number of entries left in the array, and reports the number of physical
 * blocks freed via *out_freed.
 */
/*
 * 'do_free' splits this into its two jobs, which must happen on
 * opposite sides of publishing the new map.
 *
 * It used to do both at once: rewrite the array AND hand the dropped
 * blocks back to the allocator. But the array it rewrites only becomes
 * durable when its record (or its leaf) is written, several steps later
 * -- and if that write fails, the on-disk map still names blocks the
 * allocator has already taken back and can hand to another file.
 * Measured with fail_extent_record_write: fsck reported "block 1102 is
 * referenced by an inode but marked FREE -- it can be handed out
 * again". P15's rule, which fixed exactly this for the punch-split
 * case, applies to the whole path: an operation that can fail must not
 * free anything before it knows it will succeed.
 *
 * So callers run it once with do_free = false to produce the new array,
 * publish that, and then run it again with do_free = true over a COPY
 * of the old array to do the freeing.
 */
static u16 cetrafs_leaf_array_trim(struct super_block *sb,
                                   cetrafs_extent_t *arr,
                                   u16 entries,
                                   u64 new_block_count,
                                   u32 *out_freed,
                                   bool do_free)
{
    u16 i, kept = 0;
    u32 freed = 0;

    for (i = 0; i < entries; i++) {
        u32 len = cetrafs_extent_len(arr[i].ee_len);
        u64 start = cetrafs_le32(arr[i].ee_block);
        u64 end = start + len; /* exclusive */
        u64 phys = cetrafs_extent_phys_from_hilo(arr[i].ee_start_hi, arr[i].ee_start_lo);

        if (start >= new_block_count) {
            if (do_free)
                cetrafs_free_data_extent(sb, phys, len);
            freed += len;
            continue; /* drop the entry entirely */
        }

        if (end > new_block_count) {
            u32 new_len = (u32) (new_block_count - start);

            if (do_free)
                cetrafs_free_data_extent(sb, phys + new_len, len - new_len);
            freed += len - new_len;
            arr[i].ee_len = cetrafs_extent_pack_len(new_len, 0);
        }

        if (kept != i)
            arr[kept] = arr[i];
        kept++;
    }

    *out_freed = freed;
    return kept;
}

/*
 * Remove the logical block range [start_block, end_block) from a leaf
 * array (inline or external) -- the FALLOCATE_FL_PUNCH_HOLE counterpart
 * to cetrafs_leaf_array_trim() above, which only ever drops/shrinks from
 * the *tail*. An arbitrary interior range instead needs three cases per
 * overlapping entry, not just one: the hole can eat an entry's front
 * (shrink forward, like trim's boundary case), eat its back (shrink
 * backward, identical to trim), or land entirely inside it -- which
 * *splits* one entry into two (front remnant + tail remnant), the one
 * case trim() never has to handle since it only ever touches the last
 * entries in logical order. Splitting can grow the array, so this can
 * fail with -ENOSPC (same failure mode as cetrafs_leaf_array_insert())
 * if there's no room for the new tail entry -- left as-is rather than
 * worked around, matching this codebase's existing "fragmentation can
 * cost you -ENOSPC" posture instead of adding chained
 * leaf blocks just for this.
 */
/* See cetrafs_leaf_array_trim() for what 'do_free' is for. */
static int cetrafs_leaf_array_punch(struct super_block *sb,
                                    cetrafs_extent_t *arr,
                                    u16 *entries,
                                    u16 max,
                                    u64 start_block,
                                    u64 end_block,
                                    u32 *out_freed,
                                    bool do_free)
{
    u16 i, count = *entries;
    u32 freed = 0;
    u16 splits = 0;

    /*
     * Dry run first: decide whether this punch can complete BEFORE a
     * single block is freed.
     *
     * The loop below frees an entry's overlapping blocks and only then
     * discovers, in the split case, that there is no room for the
     * split-off tail. Returning -ENOSPC there left the blocks freed on
     * disk, the array half-edited, and *entries / *out_freed never
     * written -- so the caller either published a half-edited array with
     * a stale entry count, or discarded the edit entirely and left the
     * on-disk leaf still referencing blocks the allocator had just taken
     * back. Both end the same way: one physical block reachable from two
     * files.
     *
     * An interior hole is the only case that grows the array, by exactly
     * one entry. Counting those up front costs one pass over at most a
     * few hundred in-memory entries and no I/O, and makes the whole
     * operation all-or-nothing -- which is also what lets the caller
     * safely abort its buffer update when this fails.
     */
    for (i = 0; i < count; i++) {
        u32 len = cetrafs_extent_len(arr[i].ee_len);
        u64 estart = cetrafs_le32(arr[i].ee_block);
        u64 eend = estart + len;
        u64 hs = max_t(u64, estart, start_block);
        u64 he = min_t(u64, eend, end_block);

        if (hs >= he)
            continue;
        if (hs > estart && he < eend)
            splits++;
    }
    if ((u32) count + splits > max)
        return -ENOSPC; /* nothing freed, nothing changed */

    for (i = 0; i < count; i++) {
        u32 len = cetrafs_extent_len(arr[i].ee_len);
        u64 estart = cetrafs_le32(arr[i].ee_block);
        u64 eend = estart + len; /* exclusive */
        u64 phys = cetrafs_extent_phys_from_hilo(arr[i].ee_start_hi, arr[i].ee_start_lo);
        u64 hs = max_t(u64, estart, start_block); /* [hs, he) is this entry's overlap with the hole */
        u64 he = min_t(u64, eend, end_block);

        if (hs >= he)
            continue; /* no overlap with the hole */

        if (do_free)
            cetrafs_free_data_extent(sb, phys + (hs - estart), (u32) (he - hs));
        freed += (u32) (he - hs);

        if (hs == estart && he == eend) {
            /* hole covers the whole entry: drop it, then re-examine
             * whatever just shifted down into this same slot. */
            memmove(&arr[i], &arr[i + 1], (count - i - 1) * sizeof(*arr));
            count--;
            i--;
        } else if (hs == estart) {
            /* hole eats the front */
            u32 new_len = (u32) (eend - he);

            arr[i].ee_block = cetrafs_cpu_to_le32((u32) he);
            cetrafs_extent_phys_to_hilo(phys + (he - estart), &arr[i].ee_start_hi, &arr[i].ee_start_lo);
            arr[i].ee_len = cetrafs_extent_pack_len(new_len, 0);
        } else if (he == eend) {
            /* hole eats the back (same shape as _trim()'s own case) */
            arr[i].ee_len = cetrafs_extent_pack_len((u32) (hs - estart), 0);
        } else {
            /* hole lands entirely inside: split into front + tail */
            cetrafs_extent_t tail;

            if (count >= max) {
                /* Unreachable: the dry run above already refused any
                 * punch that could get here. Kept as an assertion rather
                 * than deleted -- if it ever fires, the two loops have
                 * drifted apart and blocks have already been freed. */
                pr_err("punch: split would overflow the leaf after freeing %u block(s) -- dry run disagreed\n", freed);
                *entries = count;
                *out_freed = freed;
                return -ENOSPC;
            }

            tail.ee_block = cetrafs_cpu_to_le32((u32) he);
            cetrafs_extent_phys_to_hilo(phys + (he - estart), &tail.ee_start_hi, &tail.ee_start_lo);
            tail.ee_len = cetrafs_extent_pack_len((u32) (eend - he), 0);

            arr[i].ee_len = cetrafs_extent_pack_len((u32) (hs - estart), 0);

            memmove(&arr[i + 2], &arr[i + 1], (count - i - 1) * sizeof(*arr));
            arr[i + 1] = tail;
            count++;
            i++; /* skip the newly inserted tail entry -- it can't overlap the hole */
        }
    }

    *entries = count;
    *out_freed = freed;
    return 0;
}

/* ---------------------------------------------------------------------
 * v2 extent tree: inode root (4 inline slots) -> interior index blocks
 * -> leaf blocks -> extents. Depth 0 (inline <=4), depth 1 (one leaf),
 * depth 2 (interiors). Arrays are APPEND-ONLY and unordered: a new block
 * always has a higher logical offset, so it always lands at the END --
 * the last leaf of the last interior. That is what keeps growth a
 * single-block edit at any depth, and why lookups must scan everything.
 * ------------------------------------------------------------------- */

/* External extent-tree blocks written (new leaf or interior). Nonzero
 * means a file actually spilled out of its 4 inline slots -- which a
 * cost test must confirm before measuring anything about leaves, since
 * filefrag coalesces and cannot tell you. */
static atomic64_t cetrafs_tree_blocks = ATOMIC64_INIT(0);

u64 cetrafs_tree_block_count(void)
{
    return (u64) atomic64_read(&cetrafs_tree_blocks);
}

/* Write a brand-new leaf block holding 'n' extents (n>=1). The block is
 * claimed without reading (full overwrite), stamped, and journaled. */
static int cetrafs_write_new_leaf(struct super_block *sb, u64 lba, const cetrafs_extent_t *ext, u16 n)
{
    atomic64_inc(&cetrafs_tree_blocks);
    struct buffer_head *bh = cetrafs_getblk_overwrite(sb, lba);
    cetrafs_extent_hdr_t *hdr;

    if (!bh)
        return -EIO;
    memset(bh->b_data, 0, CETRAFS_BLOCK_SIZE);
    hdr = (cetrafs_extent_hdr_t *) bh->b_data;
    hdr->eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    hdr->eh_depth = 0;
    hdr->eh_max = cetrafs_cpu_to_le16(CETRAFS_EXT_BLOCK_MAX_LEAVES);
    hdr->eh_entries = cetrafs_cpu_to_le16(n);
    memcpy(bh->b_data + sizeof(*hdr), ext, (size_t) n * sizeof(*ext));
    cetrafs_blk_tail_stamp(bh, CETRAFS_LEAF_TAIL_MAGIC);
    {
        int ret = cetrafs_journal_write_new_block(sb, bh);

        brelse(bh);
        return ret;
    }
}

/* Write a brand-new interior index block holding 'n' index entries. */
static int cetrafs_write_new_index(struct super_block *sb, u64 lba, const cetrafs_extent_idx_t *idx, u16 n)
{
    atomic64_inc(&cetrafs_tree_blocks);
    struct buffer_head *bh = cetrafs_getblk_overwrite(sb, lba);
    cetrafs_extent_hdr_t *hdr;

    if (!bh)
        return -EIO;
    memset(bh->b_data, 0, CETRAFS_BLOCK_SIZE);
    hdr = (cetrafs_extent_hdr_t *) bh->b_data;
    hdr->eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    hdr->eh_depth = cetrafs_cpu_to_le16(1);
    hdr->eh_max = cetrafs_cpu_to_le16(CETRAFS_EXT_BLOCK_MAX_IDX);
    hdr->eh_entries = cetrafs_cpu_to_le16(n);
    memcpy(bh->b_data + sizeof(*hdr), idx, (size_t) n * sizeof(*idx));
    cetrafs_blk_tail_stamp(bh, CETRAFS_INDEX_TAIL_MAGIC);
    {
        int ret = cetrafs_journal_write_new_block(sb, bh);

        brelse(bh);
        return ret;
    }
}

/* The logical range a leaf array actually covers. */
static void cetrafs_leaf_array_range(const cetrafs_extent_t *arr, u16 n, u32 *out_lo, u32 *out_hi)
{
    u32 lo = U32_MAX, hi = 0;
    u16 i;

    for (i = 0; i < n; i++) {
        u32 eb = cetrafs_le32(arr[i].ee_block);
        u32 end = eb + cetrafs_extent_len(arr[i].ee_len);

        if (eb < lo)
            lo = eb;
        if (end > hi)
            hi = end;
    }
    if (lo == U32_MAX)
        lo = 0;
    *out_lo = lo;
    *out_hi = hi;
}

/*
 * ei_block_end == 0 means "I do not know this child's range, read it".
 * Always safe, never skips. Sites that genuinely know the range set it;
 * anything that does not can leave it unknown without being wrong --
 * which is the property that makes adding this bound to an append-only
 * tree tractable at all.
 */
static void cetrafs_idx_set(cetrafs_extent_idx_t *e, u32 block, u32 end, u64 lba)
{
    e->ei_block = cetrafs_cpu_to_le32(block);
    e->ei_block_end = cetrafs_cpu_to_le32(end);
    e->ei_pad = 0;
    cetrafs_extent_phys_to_hilo(lba, &e->ei_leaf_hi, &e->ei_leaf_lo);
}

/* Widen a child's range to include [block, end). Only ever widens, so a
 * lookup skipping on it can never skip a child that holds the block. An
 * UNKNOWN child stays unknown: we have not read it, so we cannot claim
 * a bound for what else is in there.
 *
 * Only entries that point at LEAVES carry a range. A root entry points
 * at an interior, and keeping ITS range right means widening it at
 * every site that extends that interior -- new leaf, new interior,
 * bulk rebuild. Missing one skips a whole interior and LOSES DATA,
 * which is what the first version of this did: extent_tree_depth2 and
 * uninit_convert_full_leaf both read blocks back wrong. There are at
 * most four root entries, so an exact range there saves four reads
 * against a per-leaf win of dozens. Not worth the exposure: roots are
 * always UNKNOWN. */
static void cetrafs_idx_widen(cetrafs_extent_idx_t *e, u32 block, u32 end)
{
    if (!cetrafs_le32(e->ei_block_end))
        return; /* unknown: leave it so */
    if (block < cetrafs_le32(e->ei_block))
        e->ei_block = cetrafs_cpu_to_le32(block);
    if (end > cetrafs_le32(e->ei_block_end))
        e->ei_block_end = cetrafs_cpu_to_le32(end);
}

/* Does this child possibly hold 'iblock'? Unknown range => yes. */
/* Test-only: ignore the range bound, restoring the pre-0x0007 walk that
 * read every child until it hit. The negative control for the
 * lookup-cost assertion -- with it set that assertion MUST fail, which
 * is the only thing proving it measures anything. */
static bool cetrafs_idx_range_ignore;
module_param_named(idx_range_ignore, cetrafs_idx_range_ignore, bool, 0644);
MODULE_PARM_DESC(idx_range_ignore, "TEST ONLY: ignore extent-index range bounds (restores the full scan)");

static bool cetrafs_idx_may_hold(const cetrafs_extent_idx_t *e, u32 iblock)
{
    u32 end = cetrafs_le32(e->ei_block_end);

    if (cetrafs_idx_range_ignore || !end)
        return true;
    return iblock >= cetrafs_le32(e->ei_block) && iblock < end;
}

/* Point query across depth 0/1/2. Early-returns on the first match, so
 * it never flattens the whole tree (the full-scan readers do that). */
static int cetrafs_tree_lookup(struct inode *inode, const cetrafs_inode_t *raw, u32 iblock, u64 *out_lba, u32 *out_run,
                               bool *out_uninit, bool *found)
{
    u32 ni;

    *found = false;
    if (out_uninit)
        *out_uninit = false;
    if (out_run)
        *out_run = 1;

    if (raw->eh.eh_depth == 0) {
        *found = cetrafs_leaf_array_lookup(raw->et.leaf, min_t(u16, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf)),
                                           iblock, out_lba, out_run, out_uninit);
        return 0;
    }

    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        u64 llba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
        struct buffer_head *lbh = cetrafs_read_leaf_bh(inode, llba);
        const cetrafs_extent_hdr_t *lhdr;

        if (!lbh)
            return -EIO;
        lhdr = (const cetrafs_extent_hdr_t *) lbh->b_data;
        *found = cetrafs_leaf_array_lookup((const cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)),
                                           min_t(u16, cetrafs_le16(lhdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES), iblock, out_lba, out_run, out_uninit);
        brelse(lbh);
        return 0;
    }

    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba;
        struct buffer_head *ibh;
        const cetrafs_extent_hdr_t *ihdr;
        const cetrafs_extent_idx_t *iarr;
        u32 li, iln;

        /* Skip a whole interior that provably cannot hold this block. */
        if (!cetrafs_idx_may_hold(&raw->et.idx[ni], iblock))
            continue;
        ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        ibh = cetrafs_read_index_bh(inode, ilba);

        if (!ibh)
            return -EIO;
        ihdr = (const cetrafs_extent_hdr_t *) ibh->b_data;
        iarr = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));
        iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);

        for (li = 0; li < iln; li++) {
            u64 llba;
            struct buffer_head *lbh;
            const cetrafs_extent_hdr_t *lhdr;

            /* THE point of ei_block_end: a leaf whose range excludes
             * this block is never read. Without it the walk read every
             * leaf until it hit -- ~56 of 113 on a fragmented VM image,
             * per mapped block. */
            if (!cetrafs_idx_may_hold(&iarr[li], iblock))
                continue;
            llba = cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo);
            lbh = cetrafs_read_leaf_bh(inode, llba);

            if (!lbh) {
                brelse(ibh);
                return -EIO;
            }
            lhdr = (const cetrafs_extent_hdr_t *) lbh->b_data;
            *found = cetrafs_leaf_array_lookup((const cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)),
                                               min_t(u16, cetrafs_le16(lhdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES), iblock,
                                               out_lba, out_run, out_uninit);
            brelse(lbh);
            if (*found) {
                brelse(ibh);
                return 0;
            }
        }
        brelse(ibh);
    }
    return 0;
}

/* The physical LBA just past the file's last extent -- the contiguity
 * hint for the next allocation (keeps an append contiguous). 0 if none. */
static u64 cetrafs_tree_last_contig_lba(struct inode *inode, const cetrafs_inode_t *raw)
{
    u64 ilba, llba, hint = 0;
    struct buffer_head *ibh, *lbh;
    const cetrafs_extent_hdr_t *h;

    if (raw->eh.eh_depth == 0)
        return cetrafs_leaf_array_next_contig_lba(raw->et.leaf, min_t(u16, cetrafs_le16(raw->eh.eh_entries),
                                                                      ARRAY_SIZE(raw->et.leaf)));
    if (raw->eh.eh_entries == 0)
        return 0;

    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        llba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
    } else {
        ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[cetrafs_le16(raw->eh.eh_entries) - 1].ei_leaf_hi,
                                             raw->et.idx[cetrafs_le16(raw->eh.eh_entries) - 1].ei_leaf_lo);
        ibh = cetrafs_read_index_bh(inode, ilba);
        if (!ibh)
            return 0;
        h = (const cetrafs_extent_hdr_t *) ibh->b_data;
        if (h->eh_entries == 0) {
            brelse(ibh);
            return 0;
        }
        {
            const cetrafs_extent_idx_t *ia =
                (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*h)) + (cetrafs_le16(h->eh_entries) - 1);
            llba = cetrafs_extent_phys_from_hilo(ia->ei_leaf_hi, ia->ei_leaf_lo);
        }
        brelse(ibh);
    }

    lbh = cetrafs_read_leaf_bh(inode, llba);
    if (!lbh)
        return 0;
    h = (const cetrafs_extent_hdr_t *) lbh->b_data;
    hint = cetrafs_leaf_array_next_contig_lba((const cetrafs_extent_t *) (lbh->b_data + sizeof(*h)),
                                              min_t(u16, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES));
    brelse(lbh);
    return hint;
}

/* Free every leaf and interior BLOCK of a tree (not the data blocks). */
void cetrafs_tree_free_meta(struct inode *inode, const cetrafs_inode_t *raw)
{
    struct super_block *sb = inode->i_sb;
    u32 ni;

    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        cetrafs_free_data_block(sb, cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo));
        return;
    }
    if (cetrafs_le16(raw->eh.eh_depth) != 2)
        return;

    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh(inode, ilba);

        if (ibh) {
            const cetrafs_extent_hdr_t *h = (const cetrafs_extent_hdr_t *) ibh->b_data;
            const cetrafs_extent_idx_t *ia = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*h));
            u32 li, n = min_t(u32, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);

            for (li = 0; li < n; li++)
                cetrafs_free_data_block(sb, cetrafs_extent_phys_from_hilo(ia[li].ei_leaf_hi, ia[li].ei_leaf_lo));
            brelse(ibh);
        }
        cetrafs_free_data_block(sb, ilba);
    }
}

/* Total extent count across all depths -- reads interior/leaf HEADERS
 * only (no extent copy), so the defrag trigger and close-time nudge can
 * feed cetrafs_frag_index_pct() the real number for a depth-2 file. */
u32 cetrafs_tree_extent_count(struct inode *inode, const cetrafs_inode_t *raw)
{
    u32 ni, total = 0;

    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC)
        return 0;
    if (raw->eh.eh_depth == 0)
        return min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf));
    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        u64 llba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
        struct buffer_head *lbh = cetrafs_read_leaf_bh(inode, llba);

        if (lbh) {
            total = min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) lbh->b_data)->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);
            brelse(lbh);
        }
        return total;
    }
    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh(inode, ilba);

        if (ibh) {
            const cetrafs_extent_hdr_t *h = (const cetrafs_extent_hdr_t *) ibh->b_data;
            const cetrafs_extent_idx_t *ia = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*h));
            u32 li, n = min_t(u32, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);

            for (li = 0; li < n; li++) {
                u64 llba = cetrafs_extent_phys_from_hilo(ia[li].ei_leaf_hi, ia[li].ei_leaf_lo);
                struct buffer_head *lbh = cetrafs_read_leaf_bh(inode, llba);

                if (lbh) {
                    total += min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) lbh->b_data)->eh_entries),
                                   CETRAFS_EXT_BLOCK_MAX_LEAVES);
                    brelse(lbh);
                }
            }
            brelse(ibh);
        }
    }
    return total;
}

u64 cetrafs_flat_data_blocks(const cetrafs_extent_t *flat, u32 n)
{
    u64 b = 0;
    u32 i;

    for (i = 0; i < n; i++)
        b += cetrafs_extent_len(flat[i].ee_len);
    return b;
}

/*
 * Build a FRESH extent tree holding flat[0..n), writing its leaf and
 * interior blocks and filling raw->eh/raw->et to point at it. Allocates
 * all meta blocks up front and frees them on any failure, so the caller's
 * OLD tree is never touched until this returns 0 -- which is what makes
 * truncate/punch crash-safe (publish the new root, only then free the
 * old). *out_meta is the number of leaf+interior blocks allocated, for
 * the caller's raw->blocks recompute. n==0 and n<=4 need no meta.
 */
int cetrafs_tree_build(struct inode *inode, const cetrafs_extent_t *flat, u32 n, cetrafs_inode_t *raw,
                       u64 *out_meta)
{
    struct super_block *sb = inode->i_sb;
    u32 nleaves, ninter, bg, i, j, off;
    u64 *blk = NULL; /* [0..nleaves) leaves, [nleaves..) interiors */
    u32 allocated = 0, total;
    int ret;

    *out_meta = 0;

    if (n <= ARRAY_SIZE(raw->et.leaf)) {
        memset(&raw->et, 0, sizeof(raw->et));
        raw->eh.eh_depth = 0;
        raw->eh.eh_entries = cetrafs_cpu_to_le16((u16) n);
        raw->eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw->et.leaf));
        if (n)
            memcpy(raw->et.leaf, flat, (size_t) n * sizeof(flat[0]));
        return 0;
    }

    nleaves = (u32) CETRAFS_DIV_ROUND_UP(n, CETRAFS_EXT_BLOCK_MAX_LEAVES);

    if (nleaves == 1) {
        /* depth 1: one leaf */
        {
            u64 lba;

            ret = cetrafs_alloc_block_anywhere(sb, &bg, &lba);
            if (ret)
                return ret;
            ret = cetrafs_write_new_leaf(sb, lba, flat, (u16) n);
            if (ret) {
                cetrafs_free_data_block(sb, lba);
                return ret;
            }
            memset(&raw->et, 0, sizeof(raw->et));
            raw->eh.eh_depth = cetrafs_cpu_to_le16(1);
            raw->eh.eh_entries = cetrafs_cpu_to_le16(1);
            raw->eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw->et.idx));
            {
                u32 lo, hi;

                cetrafs_leaf_array_range(flat, (u16) n, &lo, &hi);
                cetrafs_idx_set(&raw->et.idx[0], lo, hi, lba);
            }
            *out_meta = 1;
            return 0;
        }
    }

    /* depth 2 */
    ninter = (u32) CETRAFS_DIV_ROUND_UP(nleaves, CETRAFS_EXT_BLOCK_MAX_IDX);
    if (ninter > ARRAY_SIZE(raw->et.idx))
        return -ENOSPC;
    total = nleaves + ninter;

    blk = kmalloc_array(total, sizeof(*blk), GFP_NOFS);
    if (!blk)
        return -ENOMEM;

    for (allocated = 0; allocated < total; allocated++) {
        ret = cetrafs_alloc_block_anywhere(sb, &bg, &blk[allocated]);
        if (ret)
            goto fail;
    }

    /* write leaves */
    off = 0;
    for (i = 0; i < nleaves; i++) {
        u32 cnt = min_t(u32, n - off, CETRAFS_EXT_BLOCK_MAX_LEAVES);

        ret = cetrafs_write_new_leaf(sb, blk[i], flat + off, (u16) cnt);
        if (ret)
            goto fail;
        off += cnt;
    }

    /* write interiors, each pointing at its slice of leaves */
    {
        u32 leaf0 = 0;

        for (i = 0; i < ninter; i++) {
            u32 cnt = min_t(u32, nleaves - leaf0, CETRAFS_EXT_BLOCK_MAX_IDX);
            cetrafs_extent_idx_t *idx = kmalloc_array(cnt, sizeof(*idx), GFP_NOFS);

            if (!idx) {
                ret = -ENOMEM;
                goto fail;
            }
            for (j = 0; j < cnt; j++) {
                u32 lf = leaf0 + j;
                u32 fe = lf * CETRAFS_EXT_BLOCK_MAX_LEAVES; /* first extent in that leaf */

                {
                    u32 cnt_in_leaf = min_t(u32, n - fe, CETRAFS_EXT_BLOCK_MAX_LEAVES);
                    u32 lo, hi;

                    cetrafs_leaf_array_range(flat + fe, (u16) cnt_in_leaf, &lo, &hi);
                    cetrafs_idx_set(&idx[j], lo, hi, blk[lf]);
                }
            }
            ret = cetrafs_write_new_index(sb, blk[nleaves + i], idx, (u16) cnt);
            kfree(idx);
            if (ret)
                goto fail;
            leaf0 += cnt;
        }
    }

    memset(&raw->et, 0, sizeof(raw->et));
    raw->eh.eh_depth = cetrafs_cpu_to_le16(2);
    raw->eh.eh_entries = cetrafs_cpu_to_le16((u16) ninter);
    raw->eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw->et.idx));
    {
        u32 leaf0 = 0;

        for (i = 0; i < ninter; i++) {
            u32 cnt = min_t(u32, nleaves - leaf0, CETRAFS_EXT_BLOCK_MAX_IDX);

            cetrafs_idx_set(&raw->et.idx[i], 0, 0 /* root: unknown */, blk[nleaves + i]);
            leaf0 += cnt;
        }
    }
    *out_meta = total;
    kfree(blk);
    return 0;

fail:
    /* free whatever we claimed; the caller's old tree is untouched */
    for (i = 0; i < allocated; i++)
        cetrafs_free_data_block(sb, blk[i]);
    kfree(blk);
    return ret;
}

/*
 * Append one newly allocated block (iblock -> lba) to a file's extent
 * tree, growing the tree through its depths as needed. Append-only: the
 * block always has the highest logical offset so far, so it lands at the
 * tail. Updates 'raw' in-core (the caller writes the record) and writes
 * any leaf/interior blocks itself. *merged is true when the block folded
 * into the existing last extent (no new findable structure); *leaf_count
 * is the entry count of the leaf now holding it (for the defrag nudge),
 * 0 at depth 0. raw.blocks is bumped for any new META block allocated
 * here; the caller bumps it for the data block.
 */


/* Defined below: grows the tree (new leaf/interior) as needed. */
static int cetrafs_tree_append(struct inode *inode, cetrafs_inode_t *raw, u32 iblock, u64 lba, bool uninit,
                               bool *merged, u32 *leaf_count);

/*
 * The converted block could not fit its leaf, so the leaf was shrunk in
 * place and the block is appended through the tree instead -- which
 * allocates a new leaf (or interior) exactly as a growing file does.
 * This is what keeps a full leaf from turning every later write into a
 * preallocation give-back.
 */
static int cetrafs_tree_convert_append(struct inode *inode, cetrafs_inode_t *raw, u32 iblock, u64 lba)
{
    bool merged = false;
    u32 leaf_count = 0;

    return cetrafs_tree_append(inode, raw, iblock, lba, /*uninit=*/false, &merged, &leaf_count);
}


/*
 * Convert 'iblock' from preallocated to initialised, wherever in the
 * tree it lives. Mirrors cetrafs_tree_append()'s shape: the inline root
 * at depth 0, the single leaf at depth 1, the right leaf under the
 * matching interior at depth 2.
 *
 * External leaf blocks go out through the journal, exactly as the
 * append path does -- this rewrites a block the tree already points at,
 * so a torn write would corrupt a live leaf.
 *
 * -ENOENT means the block is not in a preallocated extent here (so the
 * caller's lookup and this disagree -- it falls back rather than
 * guessing). -ENOSPC means the split needs room the array has not got;
 * nothing was modified.
 */
static int cetrafs_tree_convert_inner(struct inode *inode, cetrafs_inode_t *raw, u32 iblock, u64 lba,
                                      u32 want, u32 *done)
{
    struct super_block *sb = inode->i_sb;
    u32 ni;
    int ret;

    if (raw->eh.eh_depth == 0) {
        ret = cetrafs_leaf_array_convert(sb, raw->et.leaf, &raw->eh.eh_entries, (u16) ARRAY_SIZE(raw->et.leaf),
                                         iblock, lba, want, done);
        if (ret == CETRAFS_CONVERT_APPEND)
            return cetrafs_tree_convert_append(inode, raw, (u32) iblock, lba);
        return ret;
    }

    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        u64 llba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
        struct buffer_head *lbh = cetrafs_read_leaf_bh(inode, llba);
        cetrafs_extent_hdr_t *lhdr;

        if (!lbh)
            return -EIO;
        const u32 prev_crc = cetrafs_bh_begin_update_crc(lbh);
        lhdr = (cetrafs_extent_hdr_t *) lbh->b_data;
        ret = cetrafs_leaf_array_convert(sb, (cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)), &lhdr->eh_entries,
                                         CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, want, done);
        if (ret && ret != CETRAFS_CONVERT_APPEND) {
            cetrafs_bh_abort_update(lbh);
            brelse(lbh);
            return ret;
        }
        /* -EAGAIN: the leaf WAS modified (the extent no longer covers
         * this block), so it must still be published before the block
         * is appended elsewhere in the tree. */
        /*
         * Publishing this leaf: journal it, or -- for a regular file --
         * leave it dirty for the close/fsync/writeback boundary.
         *
         * cetrafs_journal_write_block() costs THREE device cache
         * flushes plus two synchronous writes. A VM image preallocated
         * by fallocate() takes this path on EVERY 4 KiB guest write
         * (each one converts a block out of a preallocated extent), so
         * on a SAN that is ~147 ms per write: measured at 6.8 IOPS and
         * 148 flushes per 40 writes, which is the "unusably slow guest".
         *
         * The merge path a few hundred lines down already makes exactly
         * this trade, with the same reasoning: a regular file's leaf is
         * republished at the next durability boundary, and a crash
         * before then loses a write the guest was never told had
         * landed. A DIRECTORY has no such boundary -- no close, no
         * fsync -- so it must still journal, and does.
         */
        cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
        if (S_ISREG(inode->i_mode)) {
            cetrafs_bh_end_update(lbh);
            brelse(lbh);
        } else {
            int wret;
            
            /* Regular file: defer to the durability boundary (see above). */
            if (S_ISREG(inode->i_mode)) {
                cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
                cetrafs_bh_end_update(lbh);
                wret = 0;
            } else {
                wret = cetrafs_journal_write_block(sb, lbh, prev_crc);
            }

            brelse(lbh);
            if (wret)
                return wret;
        }
        if (ret == CETRAFS_CONVERT_APPEND)
            return cetrafs_tree_convert_append(inode, raw, (u32) iblock, lba);
        return 0;
    }

    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh(inode, ilba);
        const cetrafs_extent_hdr_t *ihdr;
        const cetrafs_extent_idx_t *iarr;
        u32 li, iln;

        if (!ibh)
            return -EIO;
        ihdr = (const cetrafs_extent_hdr_t *) ibh->b_data;
        iarr = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));
        iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);

        for (li = 0; li < iln; li++) {
            u64 llba = cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo);
            struct buffer_head *lbh = cetrafs_read_leaf_bh(inode, llba);
            cetrafs_extent_hdr_t *lhdr;

            if (!lbh) {
                brelse(ibh);
                return -EIO;
            }
            const u32 prev_crc = cetrafs_bh_begin_update_crc(lbh);
            lhdr = (cetrafs_extent_hdr_t *) lbh->b_data;
            ret = cetrafs_leaf_array_convert(sb, (cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)), &lhdr->eh_entries,
                                             CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, want, done);
            if (ret == -ENOENT) {
                cetrafs_bh_abort_update(lbh);
                brelse(lbh);
                continue; /* not in this leaf; try the next */
            }
            if (ret && ret != CETRAFS_CONVERT_APPEND) {
                cetrafs_bh_abort_update(lbh);
                brelse(lbh);
                brelse(ibh);
                return ret;
            }
            /* -EAGAIN: the leaf WAS modified, so publish it before the
             * block is appended elsewhere in the tree. Missing this on
             * THIS site (depth 2 -- which is every large VM image) let
             * -EAGAIN escape to block_write_begin, where io_uring reads
             * it as "retry" and span forever: a stuck worker in D state
             * and a migration that never completed. */
            /* Same trade as the depth-1 site above. */
            cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
            if (S_ISREG(inode->i_mode)) {
                cetrafs_bh_end_update(lbh);
                brelse(lbh);
                brelse(ibh);
            } else {
                int wret;
                
                /* Regular file: defer to the durability boundary (see above). */
                if (S_ISREG(inode->i_mode)) {
                    cetrafs_bh_end_update(lbh);
                    wret = 0;
                } else {
                    wret = cetrafs_journal_write_block(sb, lbh, prev_crc);
                }

                brelse(lbh);
                brelse(ibh);
                if (wret)
                    return wret;
            }
            if (ret == CETRAFS_CONVERT_APPEND)
                return cetrafs_tree_convert_append(inode, raw, (u32) iblock, lba);
            return 0;
        }
        brelse(ibh);
    }
    return -ENOENT;
}

/*
 * The only entry point. Guarantees CETRAFS_CONVERT_APPEND never reaches
 * a caller: any path inside that forgets to act on it is a bug here,
 * caught once and loudly, instead of an errno handed to the VFS.
 */
static int cetrafs_tree_convert(struct inode *inode, cetrafs_inode_t *raw, u32 iblock, u64 lba, u32 want, u32 *done)
{
    int ret;

    *done = 0;
    ret = cetrafs_tree_convert_inner(inode, raw, iblock, lba, want, done);
    if (ret == 0 && *done == 0)
        *done = 1; /* belt: a path that converted without saying so */

    if (WARN_ON_ONCE(ret == CETRAFS_CONVERT_APPEND)) {
        pr_err("tree convert: a leaf-full signal escaped unhandled for ino=%llu block %u -- please report\n",
               (unsigned long long) inode->i_ino, iblock);
        return -EIO;
    }
    return ret;
}

static int cetrafs_tree_append(struct inode *inode, cetrafs_inode_t *raw, u32 iblock, u64 lba, bool uninit,
                               bool *merged,
                               u32 *leaf_count)
{
    struct super_block *sb = inode->i_sb;
    int ret;

    *merged = false;
    *leaf_count = 0;

    /* ---- depth 0: inline array ---- */
    if (raw->eh.eh_depth == 0) {
        u16 before = cetrafs_le16(raw->eh.eh_entries);

        ret = cetrafs_leaf_array_insert(raw->et.leaf, &raw->eh.eh_entries, ARRAY_SIZE(raw->et.leaf), iblock, lba, 1, uninit);
        if (ret == 0) {
            *merged = (cetrafs_le16(raw->eh.eh_entries) == before);
            return 0;
        }
        if (ret != -ENOSPC)
            return ret;

        /* inline full: spill to depth 1 (one external leaf). */
        {
            u32 ext_bg;
            u64 new_leaf;
            cetrafs_extent_t tmp[ARRAY_SIZE(raw->et.leaf) + 1];
            u16 n = min_t(u16, before, ARRAY_SIZE(raw->et.leaf));

            ret = cetrafs_alloc_block_anywhere(sb, &ext_bg, &new_leaf);
            if (ret)
                return ret;

            __le16 ntmp;

            memcpy(tmp, raw->et.leaf, (size_t) n * sizeof(tmp[0]));
            ntmp = cetrafs_cpu_to_le16(n);
            ret = cetrafs_leaf_array_insert(tmp, &ntmp, ARRAY_SIZE(tmp), iblock, lba, 1, uninit);
            n = cetrafs_le16(ntmp);
            if (ret) { /* n+1 <= 5 always fits */
                cetrafs_free_data_block(sb, new_leaf);
                return ret;
            }
            ret = cetrafs_write_new_leaf(sb, new_leaf, tmp, n);
            if (ret) {
                cetrafs_free_data_block(sb, new_leaf);
                return ret;
            }
            memset(&raw->et, 0, sizeof(raw->et));
            raw->eh.eh_depth = cetrafs_cpu_to_le16(1);
            raw->eh.eh_entries = cetrafs_cpu_to_le16(1);
            raw->eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw->et.idx));
            cetrafs_idx_set(&raw->et.idx[0], 0, 0 /*unknown: depth 1 has one leaf*/, new_leaf);
            raw->blocks = cetrafs_cpu_to_le64(cetrafs_le64(raw->blocks) + (CETRAFS_BLOCK_SIZE / 512));
            *leaf_count = n;
            return 0;
        }
    }

    /* ---- depth 1: one external leaf ---- */
    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        u64 llba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
        struct buffer_head *lbh = cetrafs_read_leaf_bh(inode, llba);
        cetrafs_extent_hdr_t *lhdr;
        cetrafs_extent_t *larr;
        u16 before;

        if (!lbh)
            return -EIO;
        lhdr = (cetrafs_extent_hdr_t *) lbh->b_data;
        larr = (cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr));
        before = cetrafs_le16(lhdr->eh_entries);

        const u32 prev_crc = cetrafs_bh_begin_update_crc(lbh);
        ret = cetrafs_leaf_array_insert(larr, &lhdr->eh_entries, CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, 1, uninit);
        if (ret == 0) {
            *merged = (cetrafs_le16(lhdr->eh_entries) == before);
            *leaf_count = cetrafs_le16(lhdr->eh_entries);
            cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
            if (*merged && S_ISREG(inode->i_mode)) {
                /* A merge only lengthens the previous extent. For a
                 * regular file the dirty buffer may wait for the
                 * close-time flush (lock.c) or fsync -- this node holds
                 * the exclusive lock, and 256 merges/MiB make this the
                 * growing-file hot path. A DIRECTORY has no lock, no
                 * close and no flush: an unwritten merge left the
                 * DEVICE showing the shorter extent, so every peer's
                 * fresh read missed the extension and every file named
                 * in it was unreachable -- and a peer's own append then
                 * journal-wrote the short image, erasing the merge
                 *. So only S_ISREG may defer; directories
                 * fall through to the journal write below. */
                cetrafs_bh_end_update(lbh);
                brelse(lbh);
                return 0;
            }
            /* Same trade as the convert path: a regular file's leaf is republished
             * at the next durability boundary (close, fsync, writeback), so it does
             * not need three device cache flushes per insert. A DIRECTORY has no
             * such boundary and must still journal. Missing this here is why the
             * convert fix alone left 1996 journal entries per 2000 splitting
             * writes -- the splits land in tree_append, not tree_convert. */
            if (S_ISREG(inode->i_mode)) {
                cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
                cetrafs_bh_end_update(lbh);
                ret = 0;
            } else {
                ret = cetrafs_journal_write_block(sb, lbh, prev_crc);
            }
            brelse(lbh);
            return ret;
        }
        cetrafs_bh_abort_update(lbh);
        brelse(lbh);
        if (ret != -ENOSPC)
            return ret;

        /* The one leaf is full. A DIRECTORY stays at depth 1 (it never
         * fragments this far in practice); only regular files spill to
         * depth 2. */
        if (!S_ISREG(inode->i_mode))
            return -ENOSPC;

        {
            u32 bg;
            u64 new_leaf, new_idx;
            cetrafs_extent_t one;
            cetrafs_extent_idx_t idx[2];

            one.ee_block = cetrafs_cpu_to_le32(iblock);
            one.ee_pad = 0;
            one.ee_len = cetrafs_extent_pack_len(1, 0);
            cetrafs_extent_phys_to_hilo(lba, &one.ee_start_hi, &one.ee_start_lo);

            ret = cetrafs_alloc_block_anywhere(sb, &bg, &new_leaf);
            if (ret)
                return ret;
            ret = cetrafs_alloc_block_anywhere(sb, &bg, &new_idx);
            if (ret) {
                cetrafs_free_data_block(sb, new_leaf);
                return ret;
            }
            ret = cetrafs_write_new_leaf(sb, new_leaf, &one, 1);
            if (ret)
                goto d1_fail;
            /* The existing leaf's array is not in hand here, so leave it
             * UNKNOWN -- correct, just unskippable until a rebuild. */
            cetrafs_idx_set(&idx[0], 0, 0, llba);
            cetrafs_idx_set(&idx[1], iblock, iblock + 1, new_leaf);
            ret = cetrafs_write_new_index(sb, new_idx, idx, 2);
            if (ret)
                goto d1_fail;

            memset(&raw->et, 0, sizeof(raw->et));
            raw->eh.eh_depth = cetrafs_cpu_to_le16(2);
            raw->eh.eh_entries = cetrafs_cpu_to_le16(1);
            raw->eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw->et.idx));
            cetrafs_idx_set(&raw->et.idx[0], 0, 0 /* root: unknown by design, see below */, new_idx);
            raw->blocks = cetrafs_cpu_to_le64(cetrafs_le64(raw->blocks) + (2 * (CETRAFS_BLOCK_SIZE / 512))); /* new leaf + new interior */
            *leaf_count = 1;
            return 0;
d1_fail:
            cetrafs_free_data_block(sb, new_idx);
            cetrafs_free_data_block(sb, new_leaf);
            return ret;
        }
    }

    /* ---- depth 2: interiors ---- */
    {
        u32 last = cetrafs_le16(raw->eh.eh_entries) - 1;
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[last].ei_leaf_hi, raw->et.idx[last].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh(inode, ilba);
        cetrafs_extent_hdr_t *ihdr;
        cetrafs_extent_idx_t *iarr;
        u64 llba;
        struct buffer_head *lbh;
        cetrafs_extent_hdr_t *lhdr;
        cetrafs_extent_t *larr;
        u16 before;

        if (!ibh)
            return -EIO;
        ihdr = (cetrafs_extent_hdr_t *) ibh->b_data;
        iarr = (cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));
        llba = cetrafs_extent_phys_from_hilo(iarr[cetrafs_le16(ihdr->eh_entries) - 1].ei_leaf_hi,
                                             iarr[cetrafs_le16(ihdr->eh_entries) - 1].ei_leaf_lo);

        lbh = cetrafs_read_leaf_bh(inode, llba);
        if (!lbh) {
            brelse(ibh);
            return -EIO;
        }
        lhdr = (cetrafs_extent_hdr_t *) lbh->b_data;
        larr = (cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr));
        before = cetrafs_le16(lhdr->eh_entries);

        /* Try the last leaf first. */
        const u32 prev_crc = cetrafs_bh_begin_update_crc(lbh);
        ret = cetrafs_leaf_array_insert(larr, &lhdr->eh_entries, CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, 1, uninit);
        if (ret == 0) {
            /*
             * Widen this leaf's range in its parent, and the parent's in
             * the record. MUST happen on the merged path too: a merge
             * lengthens an existing extent, so the leaf's highest block
             * grows without the entry count changing, and a range left
             * behind would let a lookup SKIP a leaf that holds the
             * block -- a wrong answer, not just a slow one.
             */
            {
                u16 ient = cetrafs_le16(ihdr->eh_entries);
                u16 rent = cetrafs_le16(raw->eh.eh_entries);

                if (ient && !cetrafs_idx_may_hold(&iarr[ient - 1], iblock)) {
                    const u32 iprev = cetrafs_bh_begin_update_crc(ibh);

                    cetrafs_idx_widen(&iarr[ient - 1], iblock, iblock + 1);
                    cetrafs_blk_tail_stamp(ibh, CETRAFS_INDEX_TAIL_MAGIC);
                    if (S_ISREG(inode->i_mode)) {
                        cetrafs_bh_end_update(ibh);
                    } else {
                        int iw = cetrafs_journal_write_block(sb, ibh, iprev);

                        if (iw) {
                            cetrafs_bh_abort_update(lbh);
                            brelse(lbh);
                            brelse(ibh);
                            return iw;
                        }
                    }
                }
                (void) rent; /* root entries carry no range -- see below */
            }
            *merged = (cetrafs_le16(lhdr->eh_entries) == before);
            *leaf_count = cetrafs_le16(lhdr->eh_entries);
            cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
            if (*merged) {
                cetrafs_bh_end_update(lbh);
                brelse(lbh);
                brelse(ibh);
                return 0;
            }
            /* Same trade as the convert path: a regular file's leaf is republished
             * at the next durability boundary (close, fsync, writeback), so it does
             * not need three device cache flushes per insert. A DIRECTORY has no
             * such boundary and must still journal. Missing this here is why the
             * convert fix alone left 1996 journal entries per 2000 splitting
             * writes -- the splits land in tree_append, not tree_convert. */
            if (S_ISREG(inode->i_mode)) {
                cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
                cetrafs_bh_end_update(lbh);
                ret = 0;
            } else {
                ret = cetrafs_journal_write_block(sb, lbh, prev_crc);
            }
            brelse(lbh);
            brelse(ibh);
            return ret;
        }
        cetrafs_bh_abort_update(lbh);
        brelse(lbh);
        if (ret != -ENOSPC) {
            brelse(ibh);
            return ret;
        }

        /* Last leaf full: a fresh leaf, appended to this interior. */
        {
            u32 bg;
            u64 new_leaf;
            cetrafs_extent_t one;

            one.ee_block = cetrafs_cpu_to_le32(iblock);
            one.ee_pad = 0;
            one.ee_len = cetrafs_extent_pack_len(1, 0);
            cetrafs_extent_phys_to_hilo(lba, &one.ee_start_hi, &one.ee_start_lo);

            ret = cetrafs_alloc_block_anywhere(sb, &bg, &new_leaf);
            if (ret) {
                brelse(ibh);
                return ret;
            }
            ret = cetrafs_write_new_leaf(sb, new_leaf, &one, 1);
            if (ret) {
                cetrafs_free_data_block(sb, new_leaf);
                brelse(ibh);
                return ret;
            }
            *leaf_count = 1;

            if (cetrafs_le16(ihdr->eh_entries) < CETRAFS_EXT_BLOCK_MAX_IDX) {
                /* room in the last interior for one more leaf pointer */
                const u32 prev_crc = cetrafs_bh_begin_update_crc(ibh);
                cetrafs_idx_set(&iarr[cetrafs_le16(ihdr->eh_entries)], iblock, iblock + 1, new_leaf);
                ihdr->eh_entries = cetrafs_cpu_to_le16(cetrafs_le16(ihdr->eh_entries) + 1);
                cetrafs_blk_tail_stamp(ibh, CETRAFS_INDEX_TAIL_MAGIC);
                /* Same trade as the convert path: a regular file's leaf is republished
                 * at the next durability boundary (close, fsync, writeback), so it does
                 * not need three device cache flushes per insert. A DIRECTORY has no
                 * such boundary and must still journal. Missing this here is why the
                 * convert fix alone left 1996 journal entries per 2000 splitting
                 * writes -- the splits land in tree_append, not tree_convert. */
                if (S_ISREG(inode->i_mode)) {
                    cetrafs_blk_tail_stamp(ibh, CETRAFS_INDEX_TAIL_MAGIC);
                    cetrafs_bh_end_update(ibh);
                    ret = 0;
                } else {
                    ret = cetrafs_journal_write_block(sb, ibh, prev_crc);
                }
                brelse(ibh);
                if (ret) {
                    cetrafs_free_data_block(sb, new_leaf);
                    return ret;
                }
                raw->blocks = cetrafs_cpu_to_le64(cetrafs_le64(raw->blocks) + (CETRAFS_BLOCK_SIZE / 512)); /* new leaf */
                return 0;
            }

            /* Last interior full: need a new interior in a free root slot. */
            brelse(ibh);
            if (cetrafs_le16(raw->eh.eh_entries) >= ARRAY_SIZE(raw->et.idx)) {
                cetrafs_free_data_block(sb, new_leaf);
                return -ENOSPC; /* tree full: 4 interiors x max leaves x max extents */
            }
            {
                u64 new_idx;
                cetrafs_extent_idx_t idx1;

                ret = cetrafs_alloc_block_anywhere(sb, &bg, &new_idx);
                if (ret) {
                    cetrafs_free_data_block(sb, new_leaf);
                    return ret;
                }
                cetrafs_idx_set(&idx1, iblock, iblock + 1, new_leaf);
                ret = cetrafs_write_new_index(sb, new_idx, &idx1, 1);
                if (ret) {
                    cetrafs_free_data_block(sb, new_idx);
                    cetrafs_free_data_block(sb, new_leaf);
                    return ret;
                }
                cetrafs_idx_set(&raw->et.idx[cetrafs_le16(raw->eh.eh_entries)], 0, 0 /* root: unknown */, new_idx);
                raw->eh.eh_entries = cetrafs_cpu_to_le16(cetrafs_le16(raw->eh.eh_entries) + 1);
                raw->blocks = cetrafs_cpu_to_le64(cetrafs_le64(raw->blocks) + (2 * (CETRAFS_BLOCK_SIZE / 512))); /* new leaf + new interior */
                return 0;
            }
        }
    }
}

/*
 * Map logical block 'iblock' of a regular file's data to its physical LBA.
 * Depth-0 inodes keep up to 4 extents inline; once those fill up, 'create'
 * spills them into one external leaf block (an on-disk cetrafs_extent_hdr_t
 * + array, holding up to CETRAFS_EXT_BLOCK_MAX_LEAVES entries) referenced
 * by the inode's single et.idx[0], bumping eh_depth to 1. Only ever one
 * such leaf block is used -- a file needing more than
 * 4 + CETRAFS_EXT_BLOCK_MAX_LEAVES extents (i.e. this fragmented) returns
 * -ENOSPC; chaining further leaf/index blocks is a later increment if ever
 * needed. Depths beyond 1 aren't supported.
 */
/*
 * Map (or allocate) one logical block of an inode, returning its LBA --
 * cetrafs_get_block() for callers that want the block number rather than
 * a mapped buffer_head. dir.c uses it so directories grow through the
 * same extent machinery regular files do: contiguous blocks merge into
 * the previous extent, and a 5th extent spills into an external leaf
 * block instead of failing (the 58-entries-per-directory
 * cap). Returns -ENOENT if the block isn't mapped and create is false.
 */
int cetrafs_inode_map_block(struct inode *inode, u32 iblock, bool create, u64 *out_lba)
{
    struct buffer_head tmp;
    int ret;

    memset(&tmp, 0, sizeof(tmp));
    tmp.b_size = CETRAFS_BLOCK_SIZE;

    ret = cetrafs_get_block(inode, iblock, &tmp, create ? 1 : 0);
    if (ret)
        return ret;
    if (!buffer_mapped(&tmp)) {
        if (create)
            pr_warn_ratelimited("ino=%llu: logical block %u unmapped after create\n", (unsigned long long) inode->i_ino,
                                iblock);
        return create ? -EIO : -ENOENT;
    }

    *out_lba = tmp.b_blocknr;
    return 0;
}

/* Existing-block mappings handed back by cetrafs_get_block(), and the
 * blocks they covered. blocks == calls means every caller is being made
 * to come back per 4 KiB; blocks > calls means the contiguous-run
 * mapping is working. Exposed in procfs so a test can tell the
 * difference without a profiler. Module-wide, so assert on a delta. */

static atomic64_t cetrafs_map_calls = ATOMIC64_INIT(0);
static atomic64_t cetrafs_map_blocks = ATOMIC64_INIT(0);

u64 cetrafs_map_call_count(void)
{
    return (u64) atomic64_read(&cetrafs_map_calls);
}

u64 cetrafs_map_block_count(void)
{
    return (u64) atomic64_read(&cetrafs_map_blocks);
}

/* Blocks claimed per speculative run; 0 restores one allocator call per
 * block. 256 == 1 MiB. PERF: docs/PERFORMANCE.md */
static unsigned int cetrafs_alloc_run_blocks = 256;
module_param_named(alloc_run_blocks, cetrafs_alloc_run_blocks, uint, 0644);
MODULE_PARM_DESC(alloc_run_blocks, "blocks reserved per speculative allocation run (0 disables)");

static int cetrafs_get_block(struct inode *inode, sector_t iblock, struct buffer_head *bh_result, int create)
{
    u32 want = 1, converted = 1;
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    u64 lba;
    u32 bg_id;
    u32 run = 1; /* contiguous blocks mappable from iblock (see below) */
    bool found, merged, uninit = false;
    u32 leaf_count;
    int ret;

    /* The extent tree addresses logical blocks with a u32, so a block
     * number past 2^32 cannot be recorded -- it would truncate and
     * alias a low offset of the same file. sb->s_maxbytes is clamped by
     * the same ceiling so the VFS refuses these before they get here;
     * this is the backstop that makes the truncation impossible rather
     * than merely unreachable, and it costs one compare. */
    if ((u64) iblock >= CETRAFS_MAX_FILE_BLOCKS)
        return -EFBIG;

    /*
     * A DIRECTORY has no exclusive write lock -- any node may be
     * mutating it right now -- and cetrafs_write_raw_inode() is a blind
     * full-record write, so growing a directory from a stale cached
     * record silently REVERTS whatever a peer just changed in it: size,
     * mtime, nlink, and dirent_seq. Reverting dirent_seq is the
     * damaging one (a peer then trusts stale cached dirent blocks and
     * resurrects removed entries).
     *
     * A regular file is normally NOT exposed: this node holds its
     * cross-node write lock (default lock), or is the sole opener
     * (nofilelock), so no peer can be changing its record -- which is why
     * this read stays cached on the growing-file hot path. The exception
     * is a cross-node handoff: a peer rewriting this file's record (its
     * depth, leaf pointer, inline extents) while we map through a stale
     * cached copy sends the guest's I/O to the wrong physical blocks
     * (silent corruption). cetrafs_lock_held_for_write_locally() answers
     * "is the cache trustworthy": true while we hold the lock (default) or
     * are the sole opener (nofilelock), false the moment a peer also opens
     * the file -- the live-migration window -- in which case read fresh,
     * exactly as a directory always does. The extent tree itself is gated
     * identically in cetrafs_read_tree_bh(). This is the read half of what
     * makes nofilelock both safe across a handoff and fast when alone.
     */
    if (S_ISDIR(inode->i_mode) || !cetrafs_lock_held_for_write_locally(inode))
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);

    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        return ret;
    /* The device's file sector may lag this node's own in-flight writes:
     * overlay the pending shadow (v0x0005) so this mapping sees every
     * extent the hot path has already handed out. */
    cetrafs_inode_fd_overlay(inode, &raw);

    /* The inline root holds at most ARRAY_SIZE(leaf) (== ARRAY_SIZE(idx))
     * entries at every depth; a corrupt-but-checksum-valid eh_entries past
     * that must be rejected here, before the append path indexes the inline
     * array by it (see cetrafs_leaf_array_insert's own guard). */
    /*
     * IDENTITY before geometry. The read above is allowed to come from
     * the cache (that is the growing-file hot path, see the comment
     * over the invalidate), and a cached record can belong to a file
     * that no longer exists: a peer may have deleted it and reused the
     * inode NUMBER for something else. Mapping blocks from that record
     * sends this file's I/O to another file's extents, and the blind
     * cetrafs_write_raw_inode() further down would then publish the
     * dead file's tree. That is silent data corruption, not staleness.
     *
     * Costs one 64-bit compare and no I/O -- the record is already in
     * hand -- which is why it belongs here rather than behind a
     * forced-fresh read the per-block path cannot afford. The same
     * comparison already guards defrag.c:295 and three paths in
     * inode.c; get_block was the one place that mapped blocks without
     * it. -ESTALE makes the VFS retry through a fresh lookup, which
     * re-instantiates the inode (cetrafs_refresh_vfs_inode_if_newer()
     * unhashes it on exactly this mismatch).     *
     * DEFENCE IN DEPTH, and not demonstrable on one kernel -- said
     * plainly rather than implied. The lookup path repairs identity
     * FIRST: d_revalidate -> refresh_vfs_inode_if_newer() -> generation
     * mismatch -> remove_inode_hash(), so the next iget instantiates an
     * object already carrying the new generation and this compare
     * matches. Verified with inode_block_poke's "bumpgen" (changes the
     * generation and nothing else, so a directory does not fail ENOTDIR
     * at lookup first): the record is repaired before any mapping
     * happens and this branch never runs. It earns its place only where
     * an inode reaches here WITHOUT a lookup in front of it, which is
     * the two-node window -- so it belongs to ctest/, like the
     * write_inode gap documented in inode.c.
     */
    if (cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(inode)) {
        pr_warn_ratelimited("ino=%llu: record generation %llu != in-core %llu -- the number was reused; refusing to map\n",
                            (unsigned long long) inode->i_ino, (unsigned long long) cetrafs_le64(raw.generation),
                            (unsigned long long) cetrafs_inode_get_generation(inode));
        return -ESTALE;
    }

    if (cetrafs_le16(raw.eh.eh_magic) != CETRAFS_EXT_MAGIC ||
        cetrafs_le16(raw.eh.eh_depth) > CETRAFS_EXT_MAX_DEPTH ||
        cetrafs_le16(raw.eh.eh_entries) > ARRAY_SIZE(raw.et.leaf))
        return -EIO;

    ret = cetrafs_tree_lookup(inode, &raw, (u32) iblock, &lba, &run, &uninit, &found);
    if (ret)
        return ret;
    if (found && uninit && !create) {
        /*
         * Preallocated by fallocate(ALLOCATE) and never written: the
         * blocks are ours and on the bitmap, but their CONTENTS are
         * whatever the previous owner left. Leave the buffer unmapped
         * so the VFS serves zeroes, exactly as it does for a hole --
         * mapping it would hand the reader another file's deleted
         * data, which is a disclosure bug, not stale content.
         */
        return 0;
    }
    if (found && uninit) {
        /*
         * First write into a block fallocate(ALLOCATE) reserved. The
         * blocks are already ours and already on the bitmap, so nothing
         * is allocated here -- the extent is split so that just this
         * block reads as real data while the rest stays preallocated.
         *
         * The inode record is republished because the split changed the
         * map (at depth 0 it changed the record itself; deeper it
         * changed raw->blocks accounting only, but the leaf write is
         * already journalled above).
         */
        /* How many blocks may we answer with? b_size on the way in is
         * the caller's window; map_bh() overwrites it, so capture it
         * first. The run from the lookup bounds it to this extent. */
        want = (u32) min_t(u64, bh_result->b_size >> inode->i_blkbits, run ? run : 1);
        if (!want)
            want = 1;
        ret = cetrafs_tree_convert(inode, &raw, (u32) iblock, lba, want, &converted);
        if (ret == -ENOENT) {
            /* The lookup said preallocated and the tree says otherwise:
             * a disagreement we must not paper over by allocating a
             * second block for an already-mapped offset. */
            pr_err_ratelimited("ino=%llu: block %llu reported preallocated but no such extent found\n",
                               (unsigned long long) inode->i_ino, (unsigned long long) iblock);
            return -EIO;
        }
        if (ret)
            return ret;

        /* v0x0005: a regular file's updated map goes to the in-core
         * shadow (published at the next durability boundary); the device
         * record is never dirtied from here. A DIRECTORY, whose record
         * is namespace-owned end to end, publishes whole and sync under
         * the lock the caller holds. */
        if (S_ISDIR(inode->i_mode)) {
            ret = cetrafs_write_raw_inode(sb, inode->i_ino, &raw, /*sync=*/true);
            if (ret)
                return ret;
        } else {
            cetrafs_inode_fd_stage(inode, &raw);
            mark_inode_dirty(inode);
        }

        map_bh(bh_result, sb, lba);
        set_buffer_new(bh_result); /* undefined contents until this write lands */
        /* Report the whole converted run: map_bh() set b_size to one
         * block, so widen after it, exactly as the already-allocated
         * path below does. This is what stops a 1 MiB write becoming
         * 256 tree walks. */
        if (converted > 1)
            bh_result->b_size = (size_t) converted << inode->i_blkbits;
        /* Count this path too: it is a mapping like any other, and
         * map_blocks/map_calls is exactly the ratio that says whether
         * the convert is run-wise. Leaving it uncounted hid the
         * one-block-per-call behaviour from every counter we had. */
        atomic64_inc(&cetrafs_map_calls);
        atomic64_add(bh_result->b_size >> inode->i_blkbits, &cetrafs_map_blocks);
        return 0;
    }
    if (found) {
        /*
         * Report the whole contiguous run, clamped to what the caller
         * asked for. b_size on the way IN is the maximum the caller
         * wants mapped; map_bh() then overwrites it with exactly one
         * block, so the widening must come after it.
         *
         * Clamping is not an optimisation, it is required: the buffered
         * paths (__block_write_begin, block_read_full_folio) hand us a
         * REAL buffer_head belonging to a folio, sized to one block, and
         * widening that past what they asked for corrupts it. They ask
         * for one block, so they keep getting one. Only the callers that
         * actually offer a bigger window -- blockdev_direct_IO and
         * mpage_writepages -- see a bigger answer. Same contract as
         * ext4's _ext4_get_block(). PERF(11): docs/PERFORMANCE.md
         */
        u64 want = bh_result->b_size >> inode->i_blkbits;

        map_bh(bh_result, sb, lba);
        if (want > 1 && run > 1)
            bh_result->b_size = (size_t) min_t(u64, want, run) << inode->i_blkbits;

        atomic64_inc(&cetrafs_map_calls);
        atomic64_add(bh_result->b_size >> inode->i_blkbits, &cetrafs_map_blocks);
        return 0;
    }
    if (!create)
        return 0; /* hole: leave unmapped, reader sees zeros */

    {
        ktime_t t0 = ktime_get();
        s64 us;
        u64 preferred_lba = cetrafs_tree_last_contig_lba(inode, &raw);

        /*
         * Speculative run first. __block_write_begin() asks for exactly
         * ONE block, so without this every 4 KiB of a buffered write is
         * its own allocator call -- measured on the deployment LUN as
         * 588,415 calls for a 2.24 GiB qemu-img convert, with map_calls
         * at zero (every one of them an allocation).
         *
         * The reservation is handed out only when its next block IS the
         * contiguity hint, so taking it can never create an extent the
         * allocator would not have created anyway.
         */
        if (!cetrafs_inode_take_reserved(inode, preferred_lba, &lba)) {
            unsigned int attempt;

            /*
             * One pick is not enough. cetrafs_alloc_pick_bg() chooses a
             * Block Group by its CACHED free count, and that count is a
             * cache: it can say "space here" about a BG whose bitmap is
             * actually full. The cursor then hands back that same BG on
             * every call -- it is only re-seated when the count reads
             * zero -- so the allocation fails forever while the volume
             * has terabytes free, and the write returns ENOSPC. On a VM
             * image that is qemu latching "I/O status: nospace" and
             * Proxmox pausing the guest, with nothing in dmesg and a
             * plain dd to the same filesystem working fine (* caught by a kretprobe: cetrafs_get_block returning -28 to
             * __block_write_begin_int, with bg_pick_scan still at 0 --
             * proof the cursor never once fell through to the scan).
             *
             * So treat ENOSPC from a BG that claimed to have space as
             * what it is -- evidence the count is wrong -- and repair
             * it. cetrafs_bg_reconcile_free_count() recounts from the
             * bitmap, which is the truth and is cheap (8 blocks for a
             * 1 GiB BG); pick_bg only ever returns a BG we own, so no
             * peer can be mutating it. Once corrected the BG reports
             * zero and pick_bg stops choosing it, which is what makes
             * this loop terminate rather than spin. The same drift in
             * the opposite direction once cost the cluster a whole Zone
             * Group -- see cetrafs_bg_reconcile_free_count().
             */
            for (attempt = 0; attempt < CETRAFS_ALLOC_PICK_RETRIES; attempt++) {
                ret = cetrafs_alloc_pick_bg(sb, &bg_id);
                if (ret) {
                    pr_warn_ratelimited(
                        "alloc: ino=%llu iblock=%llu pick_bg failed: %d (no BG with free space in an owned ZG)\n",
                        (unsigned long long) inode->i_ino, (unsigned long long) iblock, ret);
                    return ret;
                }

                /* Land right after this file's last extent when we can (keeps a
                 * contiguous write contiguous); falls back to first-fit. */
                /* PERF(7): a hint MISS costs a new extent, hence a journalled
                 * extent-leaf write (~38 ms on the real LUN).
                 * docs/PERFORMANCE.md */
                ret = cetrafs_alloc_data_block_near(sb, bg_id, preferred_lba, &lba);
                if (ret != -ENOSPC)
                    break;

                {
                    s64 delta = 0;

                    if (cetrafs_bg_reconcile_free_count(sb, bg_id, &delta) != 0)
                        return ret; /* cannot even recount: report the original */
                    pr_warn_ratelimited(
                        "alloc: BG %u reported free space but its bitmap is full -- recounted (delta %lld)\n",
                        bg_id, (long long) delta);
                    /* Back off before re-picking: a recount is real I/O
                     * and a retry here is rare (only a BG whose cached
                     * count lied), so the cost is nil and it keeps this
                     * loop in line with every other retry loop here. */
                    usleep_range(50, 200);
                }
            }
            if (ret)
                return ret;

            /*
             * Claim a run for the blocks after this one. Best effort: if
             * no run that long is free the allocator says -ENOSPC and we
             * simply carry on one block at a time, which is what always
             * used to happen. Regular files only -- directories grow
             * through here too and are tiny.
             *
             * Extended from the block just taken, so it is contiguous
             * by construction -- no search, and no scan to waste when
             * the volume has no long free run left.
             */
            if (S_ISREG(inode->i_mode) && cetrafs_alloc_run_blocks) {
                u32 got = cetrafs_alloc_run_after(sb, bg_id, lba + 1, cetrafs_alloc_run_blocks);

                if (got)
                    cetrafs_inode_set_reservation(inode, lba + 1, got, bg_id);
            }
        }

        us = ktime_us_delta(ktime_get(), t0);
        if (us > CETRAFS_SLOW_ALLOC_US)
            pr_debug("slow block alloc: %lld us (bg=%u, ino=%llu)\n", (long long) us, bg_id,
                     (unsigned long long) inode->i_ino);

        /*
         * A DIRECTORY's block has to be a legal, stamped dirent block
         * before the extent below makes it reachable. Regular files need
         * nothing: their blocks carry no checksum and a reader of an
         * unwritten block legitimately sees old bytes only through this
         * same inode, which is write-locked to one node.
         */
        if (S_ISDIR(inode->i_mode)) {
            ret = cetrafs_dirent_block_init(sb, lba);
            if (ret) {
                cetrafs_free_data_block(sb, lba);
                return ret;
            }
        }
    }

    ret = cetrafs_tree_append(inode, &raw, (u32) iblock, lba, /*uninit=*/false, &merged, &leaf_count);
    if (ret) {
        cetrafs_free_data_block(sb, lba);
        return ret;
    }

    raw.blocks = cetrafs_cpu_to_le64(cetrafs_le64(raw.blocks) + (CETRAFS_BLOCK_SIZE / 512)); /* the newly allocated data block */

    /*
     * The hot per-allocated-block path (256 calls for a 1 MiB write).
     *
     * v0x0005: a REGULAR file's updated map goes to the in-core shadow
     * -- no device write, and crucially NO DIRTY RECORD BUFFER. The old
     * sync=false buffered write left the whole record (namespace sector
     * included) armed in the buffer cache, and whenever that was flushed
     * it republished those bytes over every peer CAS since -- the
     * residual corruption family. Durability for a just-
     * written file is handled at the close/fsync/writeback boundaries,
     * which publish the shadow with a file-sector CAS.
     *
     * A DIRECTORY publishes whole and sync here: its record is
     * namespace-owned end to end, the caller holds its namespace lock,
     * and directories grow once per ~15 entries, so this is not hot.
     */
    if (S_ISDIR(inode->i_mode)) {
        ret = cetrafs_write_raw_inode(sb, inode->i_ino, &raw, /*sync=*/true);
    } else {
        cetrafs_inode_fd_stage(inode, &raw);
        mark_inode_dirty(inode);
        ret = 0;
    }
    if (ret) {
        cetrafs_free_data_block(sb, lba);
        return ret;
    }

    inode->i_blocks = cetrafs_le64(raw.blocks);
    map_bh(bh_result, sb, lba);
    set_buffer_new(bh_result);

    /* A growing OPEN regular file that just added a NEW extent (not a
     * merge) to its external tree is the moment fragmentation happens;
     * nudge the background defragmenter so always-open files (VM images)
     * get healed in flight, not only at close. The frag-index gate is in
     * consider(); it recomputes the exact index under lock. */
    if (!merged && leaf_count && S_ISREG(inode->i_mode))
        cetrafs_defrag_consider(inode, leaf_count, (u64) iblock + 1);

    return 0;
}

static int cetrafs_read_folio(struct file *file, struct folio *folio)
{
    return block_read_full_folio(folio, cetrafs_get_block);
}

static int cetrafs_write_begin(const struct kiocb *iocb,
                               struct address_space *mapping,
                               loff_t pos,
                               unsigned len,
                               struct folio **foliop,
                               void **fsdata)
{
    if (cetrafs_sb_is_fenced(mapping->host->i_sb))
        return -EIO; /* self-fenced: no new dirty data */

    return block_write_begin(mapping, pos, len, foliop, cetrafs_get_block);
}

/*
 * Flush dirty page-cache pages to their already-allocated blocks. Without
 * this, dirtied pages from write_begin/write_end are never written back --
 * do_writepages() silently no-ops when .writepages is unset -- so data
 * would vanish on umount despite looking fine within the same mount.
 */
static int cetrafs_writepages(struct address_space *mapping, struct writeback_control *wbc)
{
    if (cetrafs_sb_is_fenced(mapping->host->i_sb))
        return -EIO; /* self-fenced: dirty data never reaches the device */

    return mpage_writepages(mapping, wbc, cetrafs_get_block);
}

/*
 * Shrink a regular file to 'new_size' (new_size < current i_size):
 * zero-fill the tail of the page still covering new_size, drop it from the
 * page cache, then trim/free whichever extent array currently holds the
 * file's blocks -- freeing the external leaf block too if it ends up
 * empty, reverting to depth-0. Growing a file needs none of this: holes
 * read as zero already via cetrafs_get_block(), so cetrafs_setattr() just
 * calls truncate_setsize() directly for that case.
 */
/*
 * TEST ONLY: fail the record write that publishes a truncate/punch, so
 * the unwind can be exercised. That write is what makes a freed
 * external extent leaf unreachable, and nothing a test can supply makes
 * it fail on its own.
 */
static bool cetrafs_fail_extent_record_write;
module_param_named(fail_extent_record_write, cetrafs_fail_extent_record_write, bool, 0644);
MODULE_PARM_DESC(fail_extent_record_write, "TEST ONLY: fail the record write in truncate/punch-hole");

static int cetrafs_truncate_shrink(struct inode *inode, loff_t new_size)
{
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t *recs; /* [0]=raw, [1]=old_raw -- 2 KiB, off the stack */
#define raw (recs[0])
#define old_raw (recs[1])
    u64 new_block_count = CETRAFS_DIV_ROUND_UP((u64) new_size, CETRAFS_BLOCK_SIZE);
    struct cetrafs_inode_extents ex;
    cetrafs_extent_t *old_flat = NULL, *new_flat = NULL;
    u32 old_n, kept;
    u32 freed_dummy, discard = 0;
    u64 meta_blocks = 0;
    int ret;

    recs = kmalloc(2 * sizeof(*recs), GFP_NOFS);
    if (!recs)
        return -ENOMEM;

    /*
     * Wait for any direct I/O already in flight against this inode before
     * a single block is freed: O_DIRECT bypasses the page cache, so
     * inode_lock does not exclude an already-submitted DIO whose bio is
     * aimed at a physical block this is about to hand back. (ext4 does
     * the same in ext4_setattr().)
     */
    inode_dio_wait(inode);

    ret = block_truncate_page(inode->i_mapping, new_size, cetrafs_get_block);
    if (ret) {
        kfree(recs);
        return ret;
    }

    truncate_setsize(inode, new_size);

    /*
     * Forced fresh, not cached. This runs under the inode's namespace
     * lock, and the extent list read here decides which physical blocks
     * get FREED -- truncate(2) is path-based (no exclusive lock), so a
     * peer that truncated the same file moments earlier (serialised by
     * the same namespace lock) may have changed the tree, and freeing
     * from a pre-peer list double-frees. CLAUDE.md rule 1.
     */
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret) {
        kfree(recs);
        return ret;
    }
    cetrafs_inode_fd_overlay(inode, &raw); /* include pending hot-path extents; claimed only on publish (v0x0005) */
    old_raw = raw; /* its et/eh still name the OLD tree, freed after publish */

    /* Flatten the whole tree into an independent copy (depth 0/1/2). */
    ret = cetrafs_inode_extents_get(inode, &raw, &ex);
    if (ret) {
        kfree(recs);
        return ret;
    }
    old_n = ex.entries;
    /* +2 slack: the do_free pass below re-runs the punch over this copy
     * purely to free the blocks, and an interior punch SPLITS an extent
     * (one more entry). Sized exactly old_n, cetrafs_leaf_array_punch()'s
     * dry run would see count+1 > max and refuse with -ENOSPC, freeing
     * NOTHING -- the punched blocks then leak (bitmap set, no extent).
     * The split write also needs the room. (new_flat gets the same +2.) */
    old_flat = kmalloc_array(old_n + 2, sizeof(*old_flat), GFP_NOFS);
    if (!old_flat) {
        cetrafs_inode_extents_put(&ex);
        return -ENOMEM;
    }
    if (old_n)
        memcpy(old_flat, ex.arr, (size_t) old_n * sizeof(*old_flat));
    cetrafs_inode_extents_put(&ex);

    /* Trim a COPY to the kept set. */
    new_flat = kmalloc_array(old_n ? old_n : 1, sizeof(*new_flat), GFP_NOFS);
    if (!new_flat) {
        kfree(old_flat);
        return -ENOMEM;
    }
    if (old_n)
        memcpy(new_flat, old_flat, (size_t) old_n * sizeof(*new_flat));
    kept = cetrafs_leaf_array_trim(sb, new_flat, old_n, new_block_count, &freed_dummy, /*do_free=*/false);

    /* Build a FRESH tree for the kept set, into raw's et/eh. The old
     * tree is still fully intact on disk until we publish below. */
    ret = cetrafs_tree_build(inode, new_flat, kept, &raw, &meta_blocks);
    if (ret) {
        kfree(new_flat);
        kfree(old_flat);
        kfree(recs);
        return ret;
    }

    raw.size = cetrafs_cpu_to_le64(new_size);
    raw.blocks = cetrafs_cpu_to_le64((cetrafs_flat_data_blocks(new_flat, kept) + meta_blocks) * (CETRAFS_BLOCK_SIZE / 512));

    /* The injection stands IN PLACE OF the write: a record that never
     * reached the device. On failure, free the NEW tree we just built
     * (the old one is still the durable truth) and bail. */
    ret = unlikely(cetrafs_fail_extent_record_write) ? -EIO
                                                     : cetrafs_write_raw_inode_fd(sb, inode->i_ino, &raw, inode);
    if (!ret)
        cetrafs_inode_fd_discard(inode); /* this publish supersedes the overlaid shadow */
    if (ret) {
        cetrafs_tree_free_meta(inode, &raw);
        kfree(new_flat);
        kfree(old_flat);
        kfree(recs);
        return ret;
    }

    /*
     * Published. Only now does anything go back to the allocator: the OLD
     * tree's meta blocks (leaves + interiors), then the dropped DATA
     * blocks (a do_free pass over the old flat array). New and old meta
     * are disjoint -- the new tree was allocated while the old was still
     * referenced -- and the kept data blocks appear in both trees, so
     * freeing the old meta and the dropped data never touches a block the
     * new tree still names. A crash after publish but before freeing is a
     * leaked block fsck names -- the trade made everywhere here.
     */
    cetrafs_tree_free_meta(inode, &old_raw);
    cetrafs_leaf_array_trim(sb, old_flat, old_n, new_block_count, &discard, /*do_free=*/true);

    kfree(new_flat);
    kfree(old_flat);
    inode->i_blocks = cetrafs_le64(raw.blocks);
    kfree(recs);
    return 0;
#undef raw
#undef old_raw
}

/*
 * FALLOCATE_FL_PUNCH_HOLE: deallocate [offset, offset+len) without
 * changing i_size (hence requiring FALLOC_FL_KEEP_SIZE -- the only
 * other combination this project's fallocate(2) support claims).
 * Nothing else (plain preallocation, ZERO_RANGE, COLLAPSE_RANGE,
 * INSERT_RANGE) is implemented; nothing
 * in this project's actual target workload (VM disk images) needs them
 * the way hole-punching does (thin-provisioning's TRIM/UNMAP path).
 *
 * Deliberately reuses cetrafs_truncate_shrink()'s own shape instead of a
 * parallel implementation: the same depth-0/depth-1 dispatch and revert-
 * to-depth-0-when-the-external-leaf-empties logic, and cetrafs_leaf_
 * array_punch() above as the interior-range sibling of _trim()'s tail-
 * only version. The boundary zero-fill can't reuse truncate's own
 * block_truncate_page(), though: that helper always zeroes from a given
 * offset *to the end of its block*, which is right for truncate's one
 * (trailing) boundary but wrong for a hole's *second* boundary, which
 * needs the opposite half zeroed (block-start up to 'end') -- using it
 * there would have zeroed past 'end' into data the hole is not supposed
 * to touch. cetrafs_zero_range() below is the symmetric version, built
 * from the exact same already-tested write path (cetrafs_write_begin()/
 * generic_write_end()) every ordinary write already goes through,
 * rather than hand-rolling buffer-head-level zeroing.
 */
static int cetrafs_zero_range(struct address_space *mapping, loff_t from, size_t len)
{
    struct folio *folio;
    void *fsdata;
    int ret;

    if (!len)
        return 0;

    ret = cetrafs_write_begin(NULL, mapping, from, len, &folio, &fsdata);
    if (ret)
        return ret;

    folio_zero_range(folio, offset_in_folio(folio, from), len);

    ret = generic_write_end(NULL, mapping, from, len, len, folio, fsdata);
    return ret < 0 ? ret : 0;
}

/*
 * fallocate(ALLOCATE): reserve blocks for [offset, offset+len) without
 * writing them. The extents go in marked CETRAFS_EXT_UNINIT -- owned
 * and on the bitmap, contents undefined -- so reads return zeroes and
 * the first write to each block converts it (cetrafs_tree_convert()).
 *
 * This is what qemu asks for when a qcow2 is created with
 * preallocation=metadata. Without it the request fails EOPNOTSUPP and
 * glibc's posix_fallocate falls back to WRITING ZEROES over the whole
 * range: measured on the deployment LUN as a 32 GiB image create
 * allocating 280,091 blocks (1.07 GiB) and taking 11 seconds.
 *
 * Blocks already mapped are skipped -- fallocate must not disturb data
 * that is already there, and must not double-allocate.
 */
static int cetrafs_do_allocate(struct inode *inode, loff_t offset, loff_t len, bool keep_size)
{
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    u64 b, start_block, end_block, hint = 0;
    u64 added = 0;
    loff_t end = offset + len;
    int ret;

    start_block = (u64) offset / CETRAFS_BLOCK_SIZE;
    end_block = CETRAFS_DIV_ROUND_UP((u64) end, CETRAFS_BLOCK_SIZE);
    if (end_block > CETRAFS_MAX_FILE_BLOCKS)
        return -EFBIG;

    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        return ret;
    cetrafs_inode_fd_overlay(inode, &raw); /* include pending hot-path extents; claimed only on publish (v0x0005) */
    if (cetrafs_le16(raw.eh.eh_magic) != CETRAFS_EXT_MAGIC)
        return -EIO;

    for (b = start_block; b < end_block; b++) {
        bool found = false, un = false;
        u32 bg_id;
        u64 lba;
        bool merged;
        u32 leaf_count;

        ret = cetrafs_tree_lookup(inode, &raw, (u32) b, &lba, NULL, &un, &found);
        if (ret)
            goto out;
        if (found)
            continue; /* already backed (written or preallocated) */

        if (!hint)
            hint = cetrafs_tree_last_contig_lba(inode, &raw);

        ret = cetrafs_alloc_pick_bg(sb, &bg_id);
        if (ret)
            goto out;
        ret = cetrafs_alloc_data_block_near(sb, bg_id, hint, &lba);
        if (ret == -ENOSPC) /* the BG's count may be lying -- see the helper */
            ret = cetrafs_alloc_block_anywhere(sb, &bg_id, &lba);
        if (ret)
            goto out;

        ret = cetrafs_tree_append(inode, &raw, (u32) b, lba, /*uninit=*/true, &merged, &leaf_count);
        if (ret) {
            cetrafs_free_data_block(sb, lba);
            goto out;
        }
        raw.blocks = cetrafs_cpu_to_le64(cetrafs_le64(raw.blocks) + (CETRAFS_BLOCK_SIZE / 512));
        hint = lba + 1; /* keep the run contiguous so it stays ONE extent */
        added++;
    }

    if (!keep_size && end > i_size_read(inode))
        raw.size = cetrafs_cpu_to_le64((u64) end);

    ret = cetrafs_write_raw_inode_fd(sb, inode->i_ino, &raw, inode);
    if (ret)
        goto out;
    cetrafs_inode_fd_discard(inode); /* this publish supersedes the overlaid shadow */

    inode->i_blocks = cetrafs_le64(raw.blocks);
    if (!keep_size && end > i_size_read(inode))
        i_size_write(inode, end);
    inode_set_ctime(inode, ktime_get_real_seconds(), 0);
    inode_set_mtime_to_ts(inode, inode_get_ctime(inode));
    mark_inode_dirty(inode);
    return 0;

out:
    /* Partial progress stays: the blocks added so far are real, on the
     * bitmap and referenced by the record we publish here. Leaving them
     * unpublished would leak every one of them. */
    if (added && cetrafs_write_raw_inode_fd(sb, inode->i_ino, &raw, inode) == 0)
        cetrafs_inode_fd_discard(inode);
    return ret;
}

static long cetrafs_fallocate(struct file *file, int mode, loff_t offset, loff_t len)
{
    struct inode *inode = file_inode(file);
    struct super_block *sb = inode->i_sb;
    loff_t isize, end;
    u64 start_block, end_block;
    cetrafs_inode_t *recs; /* [0]=raw, [1]=old_raw -- 2 KiB, off the stack */
#define raw (recs[0])
#define old_raw (recs[1])
    struct cetrafs_inode_extents ex;
    cetrafs_extent_t *old_flat = NULL, *new_flat = NULL;
    u32 old_n = 0, new_cap = 0;
    u16 new_n = 0;
    u64 meta_blocks = 0;
    u32 freed = 0, discard = 0;
    int ret;

    recs = kmalloc(2 * sizeof(*recs), GFP_NOFS);
    if (!recs)
        return -ENOMEM;

    if (offset < 0 || len <= 0) {
        kfree(recs);
        return -EINVAL;
    }

    /* ALLOCATE: mode 0, or KEEP_SIZE alone. */
    if (mode == 0 || mode == FALLOC_FL_KEEP_SIZE) {
        long arc;

        inode_lock(inode);
        arc = cetrafs_sb_is_fenced(sb) ? -EIO
                                       : cetrafs_do_allocate(inode, offset, len, mode & FALLOC_FL_KEEP_SIZE);
        inode_unlock(inode);
        kfree(recs);
        return arc;
    }

    if (mode != (FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE)) {
        kfree(recs);
        return -EOPNOTSUPP;
    }

    inode_lock(inode);
    /* Same reason as cetrafs_truncate_shrink(): a punch frees blocks,
     * and in-flight direct I/O is aimed at the physical ones. */
    inode_dio_wait(inode);

    isize = i_size_read(inode);
    end = offset + len;
    if (end > isize)
        end = isize; /* nothing to free past EOF -- not an error */
    if (end <= offset) {
        ret = 0;
        goto out;
    }

    start_block = CETRAFS_DIV_ROUND_UP((u64) offset, CETRAFS_BLOCK_SIZE);
    end_block = (u64) end / CETRAFS_BLOCK_SIZE; /* only whole blocks strictly inside [offset,end) get freed */

    if (start_block >= end_block) {
        /* The whole hole fits inside a single block (or doesn't cover
         * any whole block at all): zero exactly [offset, end) and free
         * nothing -- the general boundary handling below assumes the
         * two boundaries are in *different* blocks, which doesn't hold
         * here. */
        ret = cetrafs_zero_range(inode->i_mapping, offset, (size_t) (end - offset));
        goto out;
    }

    /* Boundary blocks that are only partially inside [offset, end) must
     * keep the data outside the hole: zero just the in-hole half of
     * each (the tail of offset's block, the head of end's block) before
     * anything below decides whole blocks are free to drop. */
    if (offset & (CETRAFS_BLOCK_SIZE - 1)) {
        loff_t block_end = (loff_t) start_block * CETRAFS_BLOCK_SIZE;

        ret = cetrafs_zero_range(inode->i_mapping, offset, (size_t) (block_end - offset));
        if (ret)
            goto out;
    }
    if (end & (CETRAFS_BLOCK_SIZE - 1)) {
        loff_t block_start = (loff_t) end_block * CETRAFS_BLOCK_SIZE;

        ret = cetrafs_zero_range(inode->i_mapping, block_start, (size_t) (end - block_start));
        if (ret)
            goto out;
    }

    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        goto out;
    cetrafs_inode_fd_overlay(inode, &raw); /* include pending hot-path extents; claimed only on publish (v0x0005) */
    old_raw = raw; /* names the OLD tree; freed after publish */

    /* Flatten the whole tree (depth 0/1/2) into an independent copy. */
    ret = cetrafs_inode_extents_get(inode, &raw, &ex);
    if (ret)
        goto out;
    old_n = ex.entries;
    /* +2 slack: the do_free pass below re-runs the punch over this copy
     * purely to free the blocks, and an interior punch SPLITS an extent
     * (one more entry). Sized exactly old_n, cetrafs_leaf_array_punch()'s
     * dry run would see count+1 > max and refuse with -ENOSPC, freeing
     * NOTHING -- the punched blocks then leak (bitmap set, no extent).
     * The split write also needs the room. (new_flat gets the same +2.) */
    old_flat = kmalloc_array(old_n + 2, sizeof(*old_flat), GFP_NOFS);
    if (!old_flat) {
        cetrafs_inode_extents_put(&ex);
        ret = -ENOMEM;
        goto out;
    }
    if (old_n)
        memcpy(old_flat, ex.arr, (size_t) old_n * sizeof(*old_flat));
    cetrafs_inode_extents_put(&ex);

    /* Punch a COPY. A single contiguous hole splits at most one extent,
     * so +2 slack is ample; cetrafs_leaf_array_punch() dry-runs and
     * refuses up front if it would not fit, changing nothing. */
    new_cap = old_n + 2;
    new_flat = kmalloc_array(new_cap, sizeof(*new_flat), GFP_NOFS);
    if (!new_flat) {
        kfree(old_flat);
        ret = -ENOMEM;
        goto out;
    }
    if (old_n)
        memcpy(new_flat, old_flat, (size_t) old_n * sizeof(*new_flat));
    new_n = (u16) old_n;
    ret = cetrafs_leaf_array_punch(sb, new_flat, &new_n, (u16) new_cap, start_block, end_block, &freed,
                                   /*do_free=*/false);
    if (ret) {
        kfree(new_flat);
        kfree(old_flat);
        goto out;
    }

    /*
     * Nothing to free and the map is byte-identical: this punch has no
     * effect, so publish NOTHING. Rebuilding and republishing an
     * identical tree costs journalled leaf/index writes -- two cache
     * flushes and three synchronous waits each -- for a no-op.
     *
     * This is the common case, not an edge case. qemu-img convert
     * through the `zeroinit:` driver turns writes-of-zeroes into
     * write_zeroes, which reaches us as PUNCH_HOLE; against a freshly
     * created (sparse) target most of those ranges are already holes.
     * Measured on the real LUN: 1739 such calls at 5.1 ms each -- 8.9 s
     * of synchronous metadata writes to change nothing -- which is what
     * made a UI-driven migration crawl while the same clone from the
     * CLI, which does not use zeroinit, ran at full speed.
     *
     * Checked by content, not just by the freed count, so a punch that
     * only RESHAPES the map (a split freeing nothing) still publishes.
     */
    if (freed == 0 && new_n == (u16) old_n &&
        (old_n == 0 || !memcmp(new_flat, old_flat, (size_t) old_n * sizeof(*new_flat)))) {
        kfree(new_flat);
        kfree(old_flat);
        ret = 0;
        goto out;
    }

    /* Only now that the punch is known to change something: drop the
     * cached folios over the hole. The blocks behind them are about to
     * be freed, and a stale cached copy would let a later read return
     * old data instead of the zero a hole must read as. Deliberately
     * after the no-op check above -- evicting a live file's page cache
     * on every no-op punch is both pointless and a throughput loss in
     * its own right. */
    truncate_pagecache_range(inode, offset, end - 1);

    /* Build the fresh tree; the old one stays intact until we publish. */
    ret = cetrafs_tree_build(inode, new_flat, new_n, &raw, &meta_blocks);
    if (ret) {
        kfree(new_flat);
        kfree(old_flat);
        goto out;
    }

    raw.blocks = cetrafs_cpu_to_le64((cetrafs_flat_data_blocks(new_flat, new_n) + meta_blocks) * (CETRAFS_BLOCK_SIZE / 512));

    ret = unlikely(cetrafs_fail_extent_record_write) ? -EIO
                                                     : cetrafs_write_raw_inode_fd(sb, inode->i_ino, &raw, inode);
    if (!ret)
        cetrafs_inode_fd_discard(inode); /* this publish supersedes the overlaid shadow */
    if (ret) {
        cetrafs_tree_free_meta(inode, &raw);
        kfree(new_flat);
        kfree(old_flat);
        goto out;
    }

    /* Published. Free the OLD tree's meta, then the punched DATA blocks
     * (a do_free pass over the old flat array) -- same two-pass,
     * publish-before-free shape as cetrafs_truncate_shrink(). */
    cetrafs_tree_free_meta(inode, &old_raw);
    {
        u16 discard_entries = (u16) old_n;
        int fret = cetrafs_leaf_array_punch(sb, old_flat, &discard_entries, (u16) (old_n + 2),
                                            start_block, end_block, &discard, /*do_free=*/true);
        if (fret)
            pr_err("punch: freeing the old blocks failed (%d) -- %u block(s) may have leaked\n", fret, freed);
    }
    kfree(new_flat);
    kfree(old_flat);

    inode->i_blocks = cetrafs_le64(raw.blocks);
    inode_set_ctime(inode, ktime_get_real_seconds(), 0);
    mark_inode_dirty(inode);
    /* The direct write persists it; the VFS call then clears the dirty
     * state so the inode can still accept cross-node refreshes. Both
     * halves are needed -- see cetrafs_setattr_locked()'s comment. */
    ret = cetrafs_write_vfs_inode(inode);
    if (!ret)
        ret = sync_inode_metadata(inode, 1);

out:
    inode_unlock(inode);
    kfree(recs);
    return ret;
#undef raw
#undef old_raw
}

struct cetrafs_setattr_ns {
    __le32 mode;
    __le32 uid;
    __le32 gid;
    __le64 ctime;
};

static void cetrafs_ns_apply_setattr(cetrafs_inode_t *rec, void *arg)
{
    struct cetrafs_setattr_ns *u = arg;

    rec->mode = u->mode;
    rec->uid = u->uid;
    rec->gid = u->gid;
    rec->ctime = u->ctime;
}

static int cetrafs_setattr_locked(struct mnt_idmap *idmap, struct dentry *dentry, struct iattr *attr)
{
    struct inode *inode = d_inode(dentry);
    int ret;

    ret = setattr_prepare(idmap, dentry, attr);
    if (ret)
        return ret;

    /* CLAUDE.md cross-node review rules): a record
     * exclusively locked by a LIVE other node is that node's to write --
     * path-based truncate(2)/chmod/chown never go through .open, so the
     * whole-file lock never gated them, letting one node shrink (and
     * FREE the blocks of!) a file another node was actively streaming
     * to. Same refusal unlink already applies, for the same reason; a
     * stale holder doesn't block (and its journal gets replayed first
     * inside the check, same as unlink's path). Directories/symlinks
     * never carry the lock, so this is a no-op for them. */
    if (S_ISREG(inode->i_mode)) {
        u32 my_node_id = 0;
        bool blocked = false;

        ret = cetrafs_sb_get_node_id(inode->i_sb, &my_node_id);
        if (ret)
            return ret;

        if (attr->ia_valid & ATTR_SIZE) {
            /*
             * A SIZE change frees or reshapes the file's extents, so the
             * claim check alone is not enough: under nofilelock no
             * exclusive claim ever exists (the check below is inert
             * there), yet a peer can have the file OPEN and be actively
             * writing it -- its per-block record updates are deferred
             * dirt (the hot-path budget), and a truncate/punch landing
             * under it both frees blocks the writer is still extending
             * into and gets its extent removal reverted by the writer's
             * eventual flush, leaving extents that reference FREE blocks.
             * unlink, rename-replace and eviction already refuse to free
             * under a live peer's open presence for exactly this reason
             * (ns-fuzz); truncate was the one block-freeing
             * path that did not. A peer with the file merely open is the
             * same refusal unlink gives (-ETXTBSY), and truncating a
             * file another host is writing is not a meaningful operation
             * on the VM-image workload this serves.
             */
            bool reader = false;

            ret = cetrafs_lock_foreign_user_exists(inode->i_sb, inode->i_ino, my_node_id, &blocked, &reader);
            if (ret)
                return ret;
            if (blocked || reader)
                return -ETXTBSY;
        } else {
            /* Same reasoning as the size branch above: a peer that has
             * SUSPENDED this file's automatic lock (lock.c, the handoff
             * window) is still writing it and is published only as
             * presence, so the lock alone no longer answers "is a live
             * writer here?". chmod/chown rewrite the record. */
            bool reader = false;

            ret = cetrafs_lock_foreign_user_exists(inode->i_sb, inode->i_ino, my_node_id, &blocked, &reader);
            if (ret)
                return ret;
            if (blocked || reader)
                return -ETXTBSY;
        }
    }

    if ((attr->ia_valid & ATTR_SIZE) && attr->ia_size != i_size_read(inode)) {
        if (attr->ia_size < i_size_read(inode))
            ret = cetrafs_truncate_shrink(inode, attr->ia_size);
        else
            truncate_setsize(inode, attr->ia_size);

        if (ret)
            return ret;
    }

    setattr_copy(idmap, inode, attr);
    mark_inode_dirty(inode);

    /*
     * mark_inode_dirty() only schedules this for the VFS's own (often
     * much-delayed) writeback -- nothing else calls .write_inode
     * synchronously here. Without persisting now, a peer node's
     * dir.c::cetrafs_d_revalidate() reading this inode fresh right
     * after chmod/chown/utimes/grow-truncate returns would still see
     * the pre-change on-disk record (mode bits, size, ...), since
     * nothing durable happened yet. Found via a real two-node repro:
     * chmod and truncate-grow changes never became visible to a reader
     * that had already resolved the file once before. Shrinking
     * already persists its own size/extent changes synchronously
     * inside cetrafs_truncate_shrink() -- this additionally re-persists
     * the (by-then-correct) full record, which is a harmless redundant
     * write, not worth special-casing around.
     *
     * BOTH halves are needed, and getting that wrong lost chmods.
     *
     * The direct write is what guarantees the record actually receives
     * this change: it is unconditional. sync_inode_metadata() is not --
     * it writes only if the VFS still believes there is dirt, so a
     * concurrent background writeback that cleared the dirty state and
     * then did not persist the new value leaves nothing to write and
     * the change is simply gone. Replacing the direct write with it
     * (the first version of this fix) lost 1-2 chmods per 1200 in three
     * runs out of five of record_write_vs_fresh_read.sh; with the
     * direct write restored, five runs out of five are clean.
     *
     * The sync_inode_metadata() call is still here because only the VFS
     * path CLEARS the dirty state, and a dirty inode is one
     * cetrafs_apply_raw_to_vfs_inode() refuses to refresh
     * -- so leaving it dirty blocks cross-node refreshes of this inode
     * until the VFS's own writeback gets round to it, on an inode that
     * has just been modified and is therefore exactly one under
     * contention. It costs a second record write when the inode is
     * still dirty, which setattr can afford (it is not the close path).
     */
    /* v0x0005: the identity half of the change -- mode/uid/gid, plus the
     * ctime POSIX owes every setattr -- lives in the NAMESPACE sector and
     * is published here by its CAS, under the namespace lock the wrapper
     * holds. The file half (size from a grow-truncate, times) goes
     * through write_vfs_inode()'s file-sector CAS below. Both direct and
     * unconditional, for the reason the comment above records: relying
     * on writeback lost 1-2 chmods per 1200. */
    {
        struct cetrafs_setattr_ns u = {
            .mode = cetrafs_cpu_to_le32(inode->i_mode),
            .uid = cetrafs_cpu_to_le32(i_uid_read(inode)),
            .gid = cetrafs_cpu_to_le32(i_gid_read(inode)),
            .ctime = cetrafs_cpu_to_le64((u64) inode_get_ctime_sec(inode)),
        };
        cetrafs_inode_t nsraw;

        cetrafs_invalidate_raw_inode(inode->i_sb, inode->i_ino);
        ret = cetrafs_read_raw_inode(inode->i_sb, inode->i_ino, &nsraw);
        if (!ret)
            ret = cetrafs_inode_ns_cas(inode->i_sb, inode->i_ino, cetrafs_le64(nsraw.generation), &nsraw,
                                       cetrafs_ns_apply_setattr, &u);
        if (ret)
            return ret;
    }

    ret = cetrafs_write_vfs_inode(inode);
    if (ret)
        return ret;
    return sync_inode_metadata(inode, 1);
}

/* bracketed in the same namespace cluster mutex every dirent
 * mutation and xattr set uses -- setattr is a whole-record metadata
 * mutation any node may issue on any file at any time (it never goes
 * through .open), and previously ran with no cross-node serialization at
 * all: its read-decide-write of the record raced every ns-mutexed
 * operation on the same record. Same wrapper shape as dir.c's
 * *_locked() workers. */
int cetrafs_setattr(struct mnt_idmap *idmap, struct dentry *dentry, struct iattr *attr)
{
    struct inode *set[] = {d_inode(dentry)}; /* the file's own record is what changes */
    int ret = cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set));

    if (ret)
        return ret;

    ret = cetrafs_setattr_locked(idmap, dentry, attr);
    cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
    return ret;
}

/* generic_file_open() first (standard large-file/maxbytes check), then
 * the cross-node exclusive lock gate (lock.c, an earlier phase). */
/* Sync one tree block if it is dirty in the buffer cache. */
static int cetrafs_fsync_one_block(struct super_block *sb, u64 lba)
{
    struct buffer_head *bh = sb_find_get_block(sb, lba);
    int ret = 0;

    if (bh) {
        if (buffer_dirty(bh))
            ret = sync_dirty_buffer(bh);
        brelse(bh);
    }
    return ret;
}

/* Flush every dirty leaf (depth 1) or leaf+interior (depth 2) block of a
 * file's extent tree. */
int cetrafs_flush_tree_blocks(struct inode *inode, const cetrafs_inode_t *raw)
{
    struct super_block *sb = inode->i_sb;
    int ret = 0, r;
    u32 ni;

    if (cetrafs_le16(raw->eh.eh_depth) == 1)
        return cetrafs_fsync_one_block(
            sb, cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo));

    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh(inode, ilba);

        if (ibh) {
            const cetrafs_extent_hdr_t *h = (const cetrafs_extent_hdr_t *) ibh->b_data;
            const cetrafs_extent_idx_t *ia = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*h));
            u32 li, n = min_t(u32, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);

            for (li = 0; li < n; li++) {
                r = cetrafs_fsync_one_block(sb, cetrafs_extent_phys_from_hilo(ia[li].ei_leaf_hi, ia[li].ei_leaf_lo));
                if (r && !ret)
                    ret = r;
            }
            brelse(ibh);
        }
        r = cetrafs_fsync_one_block(sb, ilba);
        if (r && !ret)
            ret = r;
    }
    return ret;
}

/*
 * fsync()/fdatasync().
 *
 * Data pages first (file_write_and_wait_range), then the extent-tree
 * blocks that FIND that data, then the inode record -- in that order.
 *
 * Once a file spills past four inline extents its map lives in external
 * leaf (and, at depth 2, interior) blocks, raw metadata outside the
 * inode's page-cache mapping, and a contiguous append only extends the
 * last extent's length in place without syncing it. So a flush that
 * skipped them could return with the data durable but the map that finds
 * it short -- data present on the device but unreachable and referenced
 * by nothing: a silent truncation plus leaked blocks after a crash. For
 * a datastore of VM images that is the guest's flush barrier being a lie.
 *
 * Order matters: the tree goes down BEFORE the record. A crash between
 * them then leaves a file whose size is short of its extents, which
 * reads correctly; the other order leaves a size that claims data the
 * extents cannot map.
 */
static int cetrafs_fsync(struct file *file, loff_t start, loff_t end, int datasync)
{
    struct inode *inode = file_inode(file);
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    int ret, ret2;

    (void) datasync; /* the extents are needed to FIND the data either way */

    ret = file_write_and_wait_range(file, start, end);
    if (ret)
        return ret;

    /*
     * A spilled file's extent map lives in external leaf (and, at depth
     * 2, interior) blocks that file_write_and_wait_range() never touches
     * -- raw metadata, not part of the inode's page-cache mapping. A
     * contiguous append only extends the last extent's length in place,
     * which cetrafs_get_block() deliberately does not sync, so without
     * this an fsync could return with the data on disk but the extents
     * that FIND it still short -- a silent truncation across a crash.
     */
    /* Allocation bits first, for the same reason as the close path: an
     * fsync that makes the extents durable while their bitmap bits are
     * not leaves blocks referenced-but-free if this node then dies. */
    ret2 = cetrafs_alloc_flush_bitmaps(sb);
    if (ret2 && !ret)
        ret = ret2;

    if (cetrafs_read_raw_inode(sb, inode->i_ino, &raw) == 0) {
        cetrafs_inode_fd_overlay(inode, &raw); /* the shadow's tree is the one to flush (v0x0005) */
        if (cetrafs_le16(raw.eh.eh_magic) == CETRAFS_EXT_MAGIC && cetrafs_le16(raw.eh.eh_depth) >= 1)
            ret2 = cetrafs_flush_tree_blocks(inode, &raw);
        else
            ret2 = 0;
        if (ret2 && !ret)
            ret = ret2;
    }

    /*
     * The record: i_size, i_blocks, and at depth 0 the extent list
     * itself.
     *
     * Through the VFS's sync_inode_metadata() rather than by calling
     * cetrafs_write_vfs_inode() directly, because only the VFS path
     * CLEARS the inode's dirty state afterwards. A first version called
     * the writer directly and left the inode dirty, which is not merely
     * untidy: cetrafs_apply_raw_to_vfs_inode() refuses to refresh a
     * dirty inode, so a refresh cannot revert unwritten local
     * changes), so an inode left dirty by every fsync would stop
     * accepting cross-node refreshes entirely -- its page cache never
     * dropped, a peer's rewrite never seen. Caught by
     * extent_leaf_staleness.sh, which went from pass to fail on exactly
     * that.
     */
    ret2 = sync_inode_metadata(inode, 1);
    if (ret2 && !ret)
        ret = ret2;

    /*
     * Flush the block device's volatile write cache. file_write_and_wait
     * and sync_inode_metadata only guarantee the writes COMPLETED, not
     * that they left any on-disk cache -- on hardware with a volatile
     * cache, fsync returning without this is a durability lie (the data
     * can be lost on power failure). cetrafs_dir_fsync() already does
     * this; a file fsync owes the same. On a device with no volatile
     * cache (a battery-backed LUN, the primary target) the block layer
     * makes it a no-op.
     */
    ret2 = blkdev_issue_flush(sb->s_bdev);
    if (ret2 && !ret)
        ret = ret2;

    return ret;
}

/*
 * Everything the last-writer close makes durable, for a file that is
 * STAYING open. lock.c's suspension path calls it before handing this
 * file's exclusive lock to a peer: data, extent-tree blocks, allocation
 * bitmaps and the record must all be on the device before the peer can
 * open, exactly as at close.
 */
int cetrafs_file_make_durable(struct file *file)
{
    return cetrafs_fsync(file, 0, LLONG_MAX, /*datasync=*/0);
}

static int cetrafs_open(struct inode *inode, struct file *file)
{
    int ret = generic_file_open(inode, file);

    if (ret)
        return ret;
    return cetrafs_lock_open(inode, file);
}

static int cetrafs_release(struct inode *inode, struct file *file)
{
    /* Hand back any unused speculative run BEFORE the lock release
     * flushes free counts, so the returned blocks are included in that
     * flush instead of sitting reserved-but-unreferenced until the
     * scrub notices. */
    cetrafs_inode_drop_reservation(inode);
    return cetrafs_lock_release(inode, file);
}

/* The defrag core lives in defrag.c (per-file relocation + the automatic
 * background worker); this file only owns the ioctl entry point, since
 * the fd-based trigger is file-ops territory. */
static long cetrafs_defrag_ioctl(struct file *file, struct cetrafs_defrag_stats __user *uarg)
{
    struct inode *inode = file_inode(file);
    struct cetrafs_defrag_stats stats = {0};
    long ret;

    if (!(file->f_mode & FMODE_WRITE))
        return -EBADF; /* the write-open IS the cross-node exclusivity */

    /* Turned off for this mount: refuse rather than silently doing
     * nothing, so an operator who disabled it and then ran
     * defrag.cetra is told why. This is the gate that makes "nothing on
     * this mount pins a file's exclusive lock for an optimisation" true
     * -- the janitor's own switch leaves this path open. */
    if (!cetrafs_sb_defrag_enabled(inode->i_sb))
        return -EOPNOTSUPP;

    /* Pin this node's exclusive lock for the pass (the caller's own
     * write-open already holds it, so this just marks it pinned and
     * defers its eventual release until the move finishes), then run the
     * same incremental mover the background path uses. */
    ret = cetrafs_lock_defrag_begin(inode);
    if (ret)
        return ret;
    ret = cetrafs_defrag_inode(inode, &stats);
    cetrafs_lock_defrag_end(inode);

    if (ret == 0 && uarg && copy_to_user(uarg, &stats, sizeof(stats)))
        ret = -EFAULT;
    return ret;
}

static long cetrafs_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    switch (cmd) {
    case CETRAFS_IOC_DEFRAG:
        return cetrafs_defrag_ioctl(file, (struct cetrafs_defrag_stats __user *) arg);
    default:
        return -ENOTTY;
    }
}
