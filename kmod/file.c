// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/delay.h>
#include <linux/falloc.h>
#include <linux/fiemap.h>
#include <linux/sort.h>
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
static int cetrafs_get_block_read(struct inode *inode, sector_t iblock, struct buffer_head *bh_result, int create);

/*
 * What __cetrafs_get_block() does with a block it is asked to WRITE.
 *
 * PLAIN is every page-cache path: a preallocated block is converted and
 * a hole allocated as written data on the spot, because the folio that
 * will be written there is already in hand and nothing can read the
 * block before it.
 *
 * DIO is an O_DIRECT write. Its data reaches the device only when the
 * bio completes, so a block it maps must not read as data before then:
 * a preallocated block is mapped AS IS, and a hole -- inside i_size or
 * past it -- is allocated PREALLOCATED. Either way a reader, a peer, or a crash sees
 * zeros until CONVERT -- run from the DIO's completion, after the data
 * has landed -- marks the range written. That is what lets such a write
 * stay direct instead of falling back to a buffered write plus a
 * synchronous flush under inode_lock, which serialised every write into
 * a sparse or preallocated file to one at a time (tests/kernel/
 * dio_no_fallback.sh).
 *
 * CONVERT never allocates: by the time it runs, the write it completes
 * mapped every block of its range, and truncate and punch wait for it
 * (inode_dio_wait()) before freeing any of them.
 */
enum cetrafs_gb_mode {
    CETRAFS_GB_PLAIN = 0,
    CETRAFS_GB_DIO,
    CETRAFS_GB_CONVERT,
};

/* b_private of a DIO mapping that left preallocated blocks for the
 * completion to convert. The DIO code copies b_private into the dio
 * after EVERY get_block call and never clears it, so once one segment
 * sets it, the completion sees it. */
#define CETRAFS_DIO_CONVERT_MARK ((void *) 1)

/* Escape hatch and A/B control: off restores DIO_SKIP_HOLES, i.e. the
 * buffered fallback for every O_DIRECT write that is not an overwrite. */
static bool cetrafs_dio_fill_holes = true;
module_param_named(dio_fill_holes, cetrafs_dio_fill_holes, bool, 0644);
MODULE_PARM_DESC(dio_fill_holes,
                 "O_DIRECT writes into holes and preallocated space stay direct (default on; off = buffered fallback)");

/* Test-only: complete such a write without converting its range. The
 * data is on the device but the blocks still read as zeros -- what
 * dio_no_fallback.sh must catch, proving the conversion is what makes
 * the write visible. */
static bool cetrafs_dio_skip_convert;
module_param_named(dio_skip_convert, cetrafs_dio_skip_convert, bool, 0644);
MODULE_PARM_DESC(dio_skip_convert, "TEST ONLY: leave an O_DIRECT write's preallocated blocks unconverted");

/* Test-only: fail an O_DIRECT write right after it allocated a block
 * (cetrafs_dio_get_block()), leaving that block allocated and unwritten. */
static bool cetrafs_dio_fail_after_alloc_once;
module_param_named(dio_fail_after_alloc_once, cetrafs_dio_fail_after_alloc_once, bool, 0644);
MODULE_PARM_DESC(dio_fail_after_alloc_once, "TEST ONLY: fail the next O_DIRECT write after it allocates a block");

/* TEST ONLY: stall halfway through the copy that drops a fully
 * converted preallocated extent from an extent array. */
static unsigned int cetrafs_leaf_drop_copy_stall_ms;
module_param_named(leaf_drop_copy_stall_ms, cetrafs_leaf_drop_copy_stall_ms, uint, 0644);
MODULE_PARM_DESC(leaf_drop_copy_stall_ms, "TEST ONLY: stall halfway through an extent-array drop copy");

static atomic64_t cetrafs_dio_fallbacks = ATOMIC64_INIT(0);
static atomic64_t cetrafs_dio_converts = ATOMIC64_INIT(0);

/* O_DIRECT writes the DIO code handed back to the buffered path. */
u64 cetrafs_dio_fallback_count(void)
{
    return (u64) atomic64_read(&cetrafs_dio_fallbacks);
}

/* O_DIRECT write completions that converted preallocated blocks. */
u64 cetrafs_dio_convert_count(void)
{
    return (u64) atomic64_read(&cetrafs_dio_converts);
}

/* A DIO mapping whose blocks read as zeros until the completion converts
 * them. buffer_new makes the DIO code zero whatever part of a block the
 * write does not cover (the block's old contents become reachable the
 * moment it is converted); defer_completion runs the completion from a
 * workqueue, since converting takes locks and does I/O. */
static void cetrafs_dio_mark_convert(struct buffer_head *bh)
{
    set_buffer_new(bh);
    set_buffer_defer_completion(bh);
    bh->b_private = CETRAFS_DIO_CONVERT_MARK;
}

static int __cetrafs_get_block(struct inode *inode,
                               sector_t iblock,
                               struct buffer_head *bh_result,
                               int create,
                               bool reader,
                               enum cetrafs_gb_mode mode);

static int cetrafs_read_folio(struct file *file, struct folio *folio);
static void cetrafs_readahead(struct readahead_control *rac);
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
static int cetrafs_file_mmap(struct file *file, struct vm_area_struct *vma);

/*
 * .open/.release (lock.c) enforce the cross-node exclusive open lock
 * -- every other op here predates that and is
 * unaffected: this lock only ever gates open()/close(), not read/write
 * once a file descriptor already exists.
 */
static loff_t cetrafs_llseek(struct file *file, loff_t offset, int whence);

/*
 * A shared writable mapping is the one write path that never calls
 * .write_begin, so with generic_file_mmap's vm_ops it reached
 * cetrafs_get_block() for the first time in WRITEBACK: unlocked, in
 * kswapd or a flusher thread, long after the store. Two consequences,
 * both measured:
 *
 *  - a store over a hole allocated at writeback, so -ENOSPC arrived
 *    where nobody is left to tell. POSIX says a mapping whose backing
 *    store cannot be allocated raises SIGBUS at the store; cetrafs
 *    dropped the data and reported nothing to the storing process.
 *
 *  - the allocation mutated the extent tree with no inode_lock, while
 *    write(2)/fallocate/truncate mutate it holding one.
 *
 * Allocating here, at fault time, answers both: block_page_mkwrite()
 * calls get_block with create=1 while the folio is locked, so the
 * writeback that follows finds every buffer mapped, and an -ENOSPC
 * becomes the SIGBUS the caller can see.
 *
 * invalidate_lock is the other half, and this takes it EXCLUSIVELY --
 * see the note at the lock itself. punch/truncate/fallocate hold it
 * exclusively too, while they drop the page cache and free blocks.
 * Without it a fault lands between those two steps, re-instantiates the
 * folio over extents that are about to disappear, and its buffers keep
 * pointing at blocks the allocator has since handed to another file --
 * writeback then overwrites that file. Measured on a full volume:
 * 1048320 of 1048576 bytes of an unrelated file replaced.
 */
static vm_fault_t cetrafs_page_mkwrite(struct vm_fault *vmf)
{
    struct vm_area_struct *vma = vmf->vma;
    struct inode *inode = file_inode(vma->vm_file);
    int ret;

    if (cetrafs_sb_is_fenced(inode->i_sb))
        return VM_FAULT_SIGBUS; /* self-fenced: no new dirty data */

    sb_start_pagefault(inode->i_sb);
    file_update_time(vma->vm_file);

    /*
     * EXCLUSIVE, not shared, and the difference is data.
     *
     * This call ALLOCATES: get_block reads the record, appends an
     * extent and stages the result. Every other mutator of that tree
     * runs under inode_lock, which a fault cannot take -- so shared
     * here let an mmap store and a write(2) to the same file append
     * from the same starting record and one overwrite the other.
     * Measured over 512 blocks of a sparse file written both ways at
     * once: 56 blocks of write(2) data lost and 74 blocks leaked.
     *
     * Exclusive here plus the same lock around write_begin and the
     * punch/truncate/fallocate paths makes invalidate_lock the one
     * thing serialising extent-tree mutation, which is what the fault
     * path needed and inode_lock could never give it.
     */
    filemap_invalidate_lock(inode->i_mapping);
    /* Not while this node has handed the file to a peer: a store
     * through an old mapping is a write like any other
     * (cetrafs_lock_write_gate()). */
    ret = cetrafs_lock_write_gate(inode);
    if (!ret)
        ret = block_page_mkwrite(vma, vmf, cetrafs_get_block);
    filemap_invalidate_unlock(inode->i_mapping);

    sb_end_pagefault(inode->i_sb);
    return vmf_fs_error(ret); /* 0 -> VM_FAULT_LOCKED, -ENOSPC -> SIGBUS */
}

/*
 * Read faults on a stopped mount fail (SIGBUS), cached pages included:
 * once a peer has reclaimed this node's files it may be writing them.
 * map_pages maps cached pages without calling .fault, so it maps
 * nothing and leaves the fault to .fault. Pages ALREADY mapped stay
 * readable until unmapped -- the one read a stop does not reach
 * (docs/internal/ERRORS.md).
 */
static vm_fault_t cetrafs_filemap_fault(struct vm_fault *vmf)
{
    if (cetrafs_sb_is_fenced(file_inode(vmf->vma->vm_file)->i_sb))
        return VM_FAULT_SIGBUS;
    return filemap_fault(vmf);
}

static vm_fault_t cetrafs_filemap_map_pages(struct vm_fault *vmf, pgoff_t start_pgoff, pgoff_t end_pgoff)
{
    if (cetrafs_sb_is_fenced(file_inode(vmf->vma->vm_file)->i_sb))
        return 0;
    return filemap_map_pages(vmf, start_pgoff, end_pgoff);
}

static const struct vm_operations_struct cetrafs_file_vm_ops = {
    .fault = cetrafs_filemap_fault,
    .map_pages = cetrafs_filemap_map_pages,
    .page_mkwrite = cetrafs_page_mkwrite,
};

/* generic_file_mmap() still does the useful part (the readahead checks
 * and file_accessed); only the vm_ops need replacing. Kept on .mmap
 * rather than the newer .mmap_prepare so the module still builds
 * against the kernels this ships to. */
static int cetrafs_file_mmap(struct file *file, struct vm_area_struct *vma)
{
    int ret = generic_file_mmap(file, vma);

    if (!ret)
        vma->vm_ops = &cetrafs_file_vm_ops;
    return ret;
}

/*
 * ->flush: the only file operation whose return value close(2) passes
 * on. ->release runs after it, and its return is discarded.
 *
 * The last writer's close publishes size and extents and releases the
 * lock in ->release, after flushing the data. A data write that failed
 * there was logged and nothing else: the close returned 0 over extents
 * naming blocks that never got the data and read back whatever they held
 * before -- possibly another file's. It cannot be retried (a failed
 * writeback leaves the pages clean), so the behaviour chosen is ext4's
 * default: publish anyway, and REPORT. Flushing here makes the error
 * reach close(2); file_write_and_wait() reports through this fd's
 * errseq, so a write error from background writeback since the open (or
 * the last fsync) is reported too, not only one from this flush.
 *
 * Nothing dirty -- every read-only fd, and O_DIRECT writers like qemu
 * with cache=none -- costs a check of the mapping and nothing else.
 * tests/kernel/close_data_error.sh.
 */
static int cetrafs_file_flush(struct file *file, fl_owner_t id)
{
    (void) id;
    if (!(file->f_mode & FMODE_WRITE))
        return 0;
    return file_write_and_wait(file);
}

/*
 * generic_file_write_iter(), with the suspended-lock check inside its
 * inode_lock: write(2), direct I/O and splice all come through here, and
 * a check made before the lock could pass, lose to a suspend, and write
 * after the file was handed to a peer (cetrafs_lock_write_gate()).
 */
/*
 * An O_DIRECT write that does not cover whole blocks.
 *
 * Into a preallocated block, or a hole, the DIO code zeroes the part of
 * the block the write does not cover (cetrafs_dio_mark_convert() sets
 * buffer_new), and the block stays preallocated until the completion
 * converts it -- so a second such write to the same block, submitted
 * before the first completes, maps it as new too, and each one's zeros
 * land over the other's data. inode_lock serialises SUBMISSION only: an
 * async write (io_uring, Linux AIO; qemu's aio=native) drops it with the
 * bio in flight. Two 512-byte writes to the halves of one fresh block
 * lost one half (tests/kernel/dio_unaligned_race.sh).
 *
 * ext4 and XFS answer this the same way: an unaligned direct write
 * drains direct I/O before it starts and completes before inode_lock
 * goes, so no two of them -- nor one and any other direct write -- are
 * ever in flight against the same block. That serialises unaligned
 * direct writes on this inode; block-aligned ones, everything a 4 KiB
 * guest issues, are untouched.
 */
static bool cetrafs_dio_unaligned(const struct inode *inode, const struct kiocb *iocb, const struct iov_iter *from)
{
    return (iocb->ki_flags & IOCB_DIRECT) && ((iocb->ki_pos | iov_iter_count(from)) & (i_blocksize(inode) - 1));
}

static ssize_t cetrafs_file_write_iter(struct kiocb *iocb, struct iov_iter *from)
{
    struct inode *inode = file_inode(iocb->ki_filp);
    ssize_t ret;

    if (iocb->ki_flags & IOCB_NOWAIT) {
        if (!inode_trylock(inode))
            return -EAGAIN;
    } else {
        inode_lock(inode);
    }
    ret = cetrafs_lock_write_gate(inode);
    if (!ret) {
        ret = generic_write_checks(iocb, from);
        if (ret > 0 && cetrafs_dio_unaligned(inode, iocb, from)) {
            /* Both drains below may sleep on I/O. */
            if (iocb->ki_flags & IOCB_NOWAIT) {
                ret = -EAGAIN;
            } else {
                inode_dio_wait(inode);
                ret = __generic_file_write_iter(iocb, from);
                /* An async submission returned with its bio in flight
                 * (-EIOCBQUEUED); it completes, converting, before the
                 * next writer can map the block. */
                inode_dio_wait(inode);
            }
        } else if (ret > 0) {
            ret = __generic_file_write_iter(iocb, from);
        }
    }
    inode_unlock(inode);
    if (ret > 0)
        ret = generic_write_sync(iocb, ret);
    return ret;
}

/* Cached pages included: see cetrafs_filemap_fault(). */
static ssize_t cetrafs_file_read_iter(struct kiocb *iocb, struct iov_iter *to)
{
    if (cetrafs_sb_is_fenced(file_inode(iocb->ki_filp)->i_sb))
        return -EIO;
    return generic_file_read_iter(iocb, to);
}

const struct file_operations cetrafs_file_ops = {
    .owner = THIS_MODULE,
    .open = cetrafs_open,
    .flush = cetrafs_file_flush,
    .release = cetrafs_release,
    .llseek = cetrafs_llseek,
    .read_iter = cetrafs_file_read_iter,
    .write_iter = cetrafs_file_write_iter,
    .mmap = cetrafs_file_mmap,
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
/*
 * The DIO get_block. An allocating call mutates the extent tree, and
 * mapping->invalidate_lock, held EXCLUSIVELY, is what serialises that
 * against every other mutator -- a page fault in particular, which holds
 * no i_rwsem and never can. i_rwsem alone (all a direct write holds
 * here) let a fault and this append start from the same record and one
 * of the two extents was lost (tests/kernel/mmap_vs_odirect_alloc.sh).
 *
 * Taken around each get_block call and not around blockdev_direct_IO()
 * as a whole: the DIO code pins the user's pages between calls, and a
 * user buffer mmapped from this very file would fault, and a fault
 * takes invalidate_lock -- held across that, it deadlocks on itself.
 * Order is i_rwsem -> invalidate_lock, the same as fallocate. A lookup
 * (create == 0) mutates nothing and stays lockless: reads are the hot
 * side of a VM image, and they never took it.
 */
static int cetrafs_dio_get_block(struct inode *inode, sector_t iblock, struct buffer_head *bh_result, int create)
{
    int ret;

    if (!create)
        return cetrafs_get_block_read(inode, iblock, bh_result, 0);
    filemap_invalidate_lock(inode->i_mapping);
    ret = __cetrafs_get_block(inode, iblock, bh_result, create, false, CETRAFS_GB_DIO);
    filemap_invalidate_unlock(inode->i_mapping);
    /* TEST ONLY: the write fails with this block allocated and never
     * written (tests/kernel/dio_extend_fail.sh). */
    if (!ret && buffer_new(bh_result) && READ_ONCE(cetrafs_dio_fail_after_alloc_once) &&
        xchg(&cetrafs_dio_fail_after_alloc_once, false))
        ret = -EIO;
    return ret;
}

/*
 * Completion of an O_DIRECT write that mapped preallocated blocks:
 * every byte of [offset, offset + size) is now on the device, so the
 * blocks under it may read as data. Converted a run at a time through
 * the same path a buffered write converts with.
 *
 * Context: the submitter's (a synchronous DIO, under inode_lock), or the
 * superblock's DIO workqueue (cetrafs_dio_mark_convert() set
 * defer_completion), never interrupt context. invalidate_lock is taken
 * EXCLUSIVELY because this mutates the extent tree (CLAUDE.md rule 18).
 * It also means no path may wait for direct I/O while holding
 * invalidate_lock -- this would wait for it in turn. Truncate, punch,
 * defrag and the lock suspend all drain direct I/O BEFORE taking it.
 *
 * The DIO code calls inode_dio_end() only after this returns, so
 * truncate and punch, which inode_dio_wait(), cannot free these blocks
 * while it runs. It also invalidates the page cache over the range only
 * after this returns, so a buffered reader that cached zeros from the
 * preallocated blocks meanwhile loses them.
 *
 * A failure is the write's failure: its data is on the device but the
 * map still says preallocated, so the range reads as zeros, and the
 * caller is told.
 */
static int cetrafs_dio_end_io(struct kiocb *iocb, loff_t offset, ssize_t size, void *private)
{
    struct inode *inode = file_inode(iocb->ki_filp);
    unsigned int bits = inode->i_blkbits;
    sector_t b, last;
    int ret = 0;

    if (private != CETRAFS_DIO_CONVERT_MARK || size <= 0)
        return 0;
    if (cetrafs_dio_skip_convert)
        return 0; /* test-only, see the knob */

    b = offset >> bits;
    last = (offset + size - 1) >> bits;
    filemap_invalidate_lock(inode->i_mapping);
    while (b <= last) {
        struct buffer_head map = { 0 };
        u64 n;

        map.b_size = (size_t) min_t(u64, last - b + 1, (u64) U32_MAX >> bits) << bits;
        ret = __cetrafs_get_block(inode, b, &map, 1, false, CETRAFS_GB_CONVERT);
        if (ret)
            break;
        /* Never trust the answer for progress (rule 14): at least one
         * block, at most what was asked. */
        n = clamp_t(u64, map.b_size >> bits, 1, last - b + 1);
        b += n;
    }
    filemap_invalidate_unlock(inode->i_mapping);

    if (ret)
        pr_err_ratelimited("ino=%llu: O_DIRECT write at %lld+%zd landed but block %llu could not be marked written "
                           "(%d) -- it reads as zeros, the write fails\n",
                           (unsigned long long) inode->i_ino, (long long) offset, size, (unsigned long long) b, ret);
    else
        atomic64_inc(&cetrafs_dio_converts);
    return ret;
}

static ssize_t cetrafs_direct_IO(struct kiocb *iocb, struct iov_iter *iter)
{
    struct inode *inode = iocb->ki_filp->f_mapping->host;

    if (iov_iter_rw(iter) == READ)
        return blockdev_direct_IO(iocb, inode, iter, cetrafs_dio_get_block);

    if (cetrafs_sb_is_fenced(inode->i_sb))
        return -EIO; /* self-fenced: no new writes */

    /* Without DIO_SKIP_HOLES a write into a hole or preallocated space
     * maps with create == 1 and stays direct (enum cetrafs_gb_mode).
     * With it, those inside i_size fall back to buffered -- but a write
     * past i_size still maps here, preallocated like any other, so the
     * completion that converts it is passed either way. */
    return __blockdev_direct_IO(iocb, inode, inode->i_sb->s_bdev, iter, cetrafs_dio_get_block, cetrafs_dio_end_io,
                                DIO_LOCKING | (READ_ONCE(cetrafs_dio_fill_holes) ? 0 : DIO_SKIP_HOLES));
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
/* struct cetrafs_inode_extents now lives in kmod.h -- evict holds one
 * across the arbitration, see cetrafs_free_fetched_extents(). */

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

    /* The remembered extent was resolved out of the very blocks being
     * dropped here, so it goes with them -- before them, so no walk can
     * repopulate it from a block this function has already dropped. */
    cetrafs_inode_ext_cache_drop(inode);

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
                const cetrafs_extent_idx_t *iarr = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));
                u32 iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);
                u32 li;

                for (li = 0; li < iln; li++)
                    cetrafs_invalidate_block(sb,
                                             cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo));
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
int cetrafs_tree_flatten(struct inode *inode, const cetrafs_inode_t *raw, cetrafs_extent_t **out_arr, u32 *out_n)
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
                /*
                 * kv-, not k-. kmalloc wants PHYSICALLY CONTIGUOUS
                 * memory and gives up past KMALLOC_MAX_SIZE, which at
                 * 16 bytes per extent is 262144 of them -- a 1 GiB
                 * file whose every block is its own extent. The
                 * failure did not stop at "flatten returned -ENOMEM":
                 * evict frees the inode NUMBER and then asks this for
                 * the blocks to free, so the number went back and the
                 * file's blocks stayed allocated, referenced by
                 * nothing. A fragmented file big enough to matter is
                 * exactly the one a VM image becomes.
                 */
                cetrafs_extent_t *narr = kvrealloc(arr, (size_t) ncap * sizeof(*narr), GFP_NOFS);

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
    kvfree(arr);
    return ret;
}

/*
 * The scrub's read of an external tree block.
 *
 * On the deciding pass ('fresh') this is a device read, tail-checked and
 * retried like every lockless reader's: the scrub FREES what the walk
 * does not report, so an older leaf -- a peer appended extents to it in
 * place after this node cached it -- makes live blocks look leaked
 * (CLAUDE.md rule 6, the 2026-10-18 scrub bug one level down). The
 * record was already read fresh; the tree under it was not.
 * cetrafs_bread_uncached() keeps a DIRTY buffer, so a leaf this node is
 * itself still extending is read as this node has it, which is newer.
 *
 * A block that will not verify is "unknown", not corruption: the record
 * naming it may be a dead file whose leaf was since reused, which is
 * nobody's damage. The caller frees nothing on NULL.
 */
static struct buffer_head *cetrafs_scrub_tree_bread(struct super_block *sb, u64 lba, u32 magic, bool fresh)
{
    int attempt;

    if (!cetrafs_lba_run_is_data(sb, lba, 1))
        return NULL;
    if (!fresh)
        return cetrafs_bread_retry(sb, lba); /* pass 1 only proposes candidates */
    for (attempt = 0; attempt < CETRAFS_BLK_TAIL_READ_RETRIES; attempt++) {
        struct buffer_head *bh = cetrafs_bread_uncached(sb, lba);

        if (bh) {
            if (cetrafs_blk_tail_valid(bh, magic))
                return bh;
            brelse(bh);
        }
        usleep_range(100, 400);
    }
    return NULL;
}

/* Walk one external leaf block's extents (read by LBA). */
static int
cetrafs_scrub_walk_leaf(struct super_block *sb, u64 lba, void (*cb)(void *, u64, u32), void *ctx, bool fresh)
{
    struct buffer_head *bh = cetrafs_scrub_tree_bread(sb, lba, CETRAFS_LEAF_TAIL_MAGIC, fresh);
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
 * xattr block. Reads external tree blocks by LBA -- cached on the
 * scrub's proposing pass, forced fresh on its deciding one ('fresh'),
 * see cetrafs_scrub_tree_bread(). The background scrub (scrub.c, the
 * only caller) holds no struct inode. Returns -EIO on any
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
int cetrafs_raw_inode_for_each_owned_block(struct super_block *sb,
                                           const cetrafs_inode_t *raw,
                                           void (*cb)(void *ctx, u64 phys, u32 len),
                                           void *ctx,
                                           bool fresh)
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
            ret = cetrafs_scrub_walk_leaf(sb, lba, cb, ctx, fresh);
            if (ret)
                return ret;
        } else {
            struct buffer_head *ibh = cetrafs_scrub_tree_bread(sb, lba, CETRAFS_INDEX_TAIL_MAGIC, fresh);
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

                ret = cetrafs_scrub_walk_leaf(sb, llba, cb, ctx, fresh);
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

/*
 * Test-only: make the extent-list fetch fail once.
 *
 * The real failures are an I/O error on a leaf and an allocation
 * failure flattening a large tree -- neither is reachable on demand,
 * and the consequence (the inode number freed while its blocks stay
 * allocated and unnamed) is permanent, so it needs to be reachable.
 */
static bool cetrafs_extents_fetch_fail_once;
module_param_named(extents_fetch_fail_once, cetrafs_extents_fetch_fail_once, bool, 0644);
MODULE_PARM_DESC(extents_fetch_fail_once, "TEST ONLY: the next extent-list fetch fails");

int cetrafs_inode_extents_get(struct inode *inode, const cetrafs_inode_t *raw, struct cetrafs_inode_extents *ex)
{
    if (cetrafs_extents_fetch_fail_once) {
        cetrafs_extents_fetch_fail_once = false;
        return -ENOMEM; /* test-only, see the knob */
    }
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
    ex->entries = min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) ex->leaf_bh->b_data)->eh_entries),
                        CETRAFS_EXT_BLOCK_MAX_LEAVES);
    return 0;
}

void cetrafs_inode_extents_put(struct cetrafs_inode_extents *ex)
{
    if (ex->leaf_bh)
        brelse(ex->leaf_bh);
    kvfree(ex->heap);
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
 * not in logical order. SEEK_DATA's single pass therefore considers
 * every entry rather than stopping at the first match, and SEEK_HOLE --
 * which must follow runs that abut -- works on a sorted copy
 * (cetrafs_extents_sorted() below). Assuming order in the array itself
 * would give confidently wrong answers on exactly the files (randomly
 * written VM images) this exists to serve.
 */
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

/*
 * The extent array in logical order, for the two walks that need it.
 *
 * The array is unsorted (appends merge only with the last entry), and
 * both SEEK_HOLE and fiemap used to answer "what comes next?" with a
 * fresh scan per step: O(n^2). A depth-2 tree holds ~258k extents --
 * a fragmented VM image -- which made one lseek(SEEK_HOLE) tens of
 * seconds of CPU under inode_lock_shared with no signal check: the
 * file's writers blocked behind it and nothing could kill it. Sorted
 * once, both are linear. Zero-length entries are dropped here (they
 * are corruption, and a walk that steps by a length must never see
 * one -- rule 14).
 */
struct cetrafs_ext_run {
    u64 start, len, phys;
    bool uninit;
};

static int cetrafs_ext_run_cmp(const void *a, const void *b)
{
    const struct cetrafs_ext_run *x = a, *y = b;

    return x->start < y->start ? -1 : x->start > y->start;
}

static int cetrafs_extents_sorted(struct inode *inode, const struct cetrafs_inode_extents *ex,
                                  struct cetrafs_ext_run **out, u32 *out_n)
{
    struct cetrafs_ext_run *r;
    u32 i, n = 0;

    r = kvmalloc_array(max_t(u32, ex->entries, 1), sizeof(*r), GFP_KERNEL);
    if (!r)
        return -ENOMEM;
    for (i = 0; i < ex->entries; i++) {
        u64 l = cetrafs_extent_len(ex->arr[i].ee_len);

        if (!l) {
            pr_err_ratelimited("ino=%llu: extent at block %llu has zero length -- skipping it (fsck)\n",
                               (unsigned long long) inode->i_ino,
                               (unsigned long long) cetrafs_le32(ex->arr[i].ee_block));
            cetrafs_sb_corrupt_inode(inode);
            continue;
        }
        r[n].start = cetrafs_le32(ex->arr[i].ee_block);
        r[n].len = l;
        r[n].phys = cetrafs_extent_phys_from_hilo(ex->arr[i].ee_start_hi, ex->arr[i].ee_start_lo);
        r[n].uninit = cetrafs_extent_is_uninit(ex->arr[i].ee_len);
        n++;
    }
    sort(r, n, sizeof(*r), cetrafs_ext_run_cmp, NULL);
    *out = r;
    *out_n = n;
    return 0;
}

/* First unmapped block at or after `from`, over the sorted runs: one
 * pass, extending `from` across every run that covers it (runs may
 * overlap on a damaged tree, hence the max). */
static u64 cetrafs_next_hole_block(const struct cetrafs_ext_run *r, u32 n, u64 from, u64 nblocks)
{
    u32 i;

    for (i = 0; i < n && from < nblocks; i++) {
        if (r[i].start + r[i].len <= from)
            continue; /* entirely behind us */
        if (r[i].start > from)
            break; /* a gap before the next run: `from` is the hole */
        from = r[i].start + r[i].len;
    }
    return from < nblocks ? from : nblocks; /* EOF itself is the hole */
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

    ret = cetrafs_read_raw_inode_overlaid(inode->i_sb, inode, &raw); /* torn-read-safe vs a concurrent publish */
    if (ret)
        goto out;

    /* The leaf is read in place; its writers edit it under
     * invalidate_lock (cetrafs_tree_lookup_unchecked()). */
    filemap_invalidate_lock_shared(inode->i_mapping);
    ret = cetrafs_inode_extents_get(inode, &raw, &ex);
    if (ret) {
        filemap_invalidate_unlock_shared(inode->i_mapping);
        goto out;
    }

    iblock = (u64) offset / CETRAFS_BLOCK_SIZE;
    nblocks = ((u64) isize + CETRAFS_BLOCK_SIZE - 1) / CETRAFS_BLOCK_SIZE;

    if (whence == SEEK_DATA) {
        found = cetrafs_next_data_block(&ex, iblock);
        if (found == U64_MAX || found >= nblocks) {
            cetrafs_inode_extents_put(&ex);
            filemap_invalidate_unlock_shared(inode->i_mapping);
            ret = -ENXIO; /* nothing but hole between here and EOF */
            goto out;
        }
        /* Staying inside the block we were already in means the answer
         * is the caller's own offset, not the block boundary below it. */
        ret = (found == iblock) ? offset : (loff_t) (found * CETRAFS_BLOCK_SIZE);
    } else {
        struct cetrafs_ext_run *runs;
        u32 nruns;

        ret = cetrafs_extents_sorted(inode, &ex, &runs, &nruns);
        if (ret) {
            cetrafs_inode_extents_put(&ex);
            filemap_invalidate_unlock_shared(inode->i_mapping);
            goto out;
        }
        found = cetrafs_next_hole_block(runs, nruns, iblock, nblocks);
        kvfree(runs);
        ret = (found == iblock) ? offset : (loff_t) (found * CETRAFS_BLOCK_SIZE);
        if (ret > isize)
            ret = isize; /* EOF is a hole, but never report past it */
    }

    cetrafs_inode_extents_put(&ex);
    filemap_invalidate_unlock_shared(inode->i_mapping);

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
 * that extents come back in increasing logical order, so the array is
 * sorted once (cetrafs_extents_sorted()) and walked. It used to be
 * rescanned per emitted extent, under a comment calling that "O(n^2) on
 * at most 343 entries" -- true of a depth-1 tree, not of a depth-2 one,
 * which holds ~258k.
 */
int cetrafs_fiemap(struct inode *inode, struct fiemap_extent_info *fi, u64 start, u64 len)
{
    struct cetrafs_inode_extents ex;
    struct cetrafs_ext_run *runs;
    cetrafs_inode_t raw;
    u64 cursor, end;
    u32 nruns, i;
    int ret;

    if (cetrafs_sb_is_fenced(inode->i_sb))
        return -EIO;

    ret = fiemap_prep(inode, fi, start, &len, 0);
    if (ret)
        return ret;

    inode_lock_shared(inode);

    ret = cetrafs_read_raw_inode_overlaid(inode->i_sb, inode, &raw); /* torn-read-safe vs a concurrent publish */
    if (ret)
        goto out;
    /* The leaf is read in place, and its writers edit it under
     * invalidate_lock (cetrafs_tree_lookup_unchecked()). Held only
     * while the sorted private copy is built: the loop below copies to
     * user memory, which can fault on a mapping of this file. */
    filemap_invalidate_lock_shared(inode->i_mapping);
    ret = cetrafs_inode_extents_get(inode, &raw, &ex);
    if (ret) {
        filemap_invalidate_unlock_shared(inode->i_mapping);
        goto out;
    }

    ret = cetrafs_extents_sorted(inode, &ex, &runs, &nruns);
    cetrafs_inode_extents_put(&ex);
    filemap_invalidate_unlock_shared(inode->i_mapping);
    if (ret)
        goto out;

    /* In logical order, once (see cetrafs_extents_sorted()): each step
     * emits the lowest run starting at or after the cursor, exactly as
     * the per-step rescan did, and a run starting behind the cursor (an
     * overlap on a damaged tree) is skipped the same way. */
    end = start + len;
    cursor = 0; /* lowest block not yet emitted */
    i = 0;
    while (i < nruns) {
        const struct cetrafs_ext_run *r = &runs[i];
        u64 logical, phys, blen;
        u32 flags = 0, j;

        if (r->start < cursor) {
            i++;
            continue;
        }
        cursor = r->start + r->len;
        logical = r->start * CETRAFS_BLOCK_SIZE;
        blen = r->len * CETRAFS_BLOCK_SIZE;
        phys = r->phys * CETRAFS_BLOCK_SIZE;

        /* The next run that would be emitted, which is also the answer
         * to LAST ("no extent begins after this one"). */
        for (j = i + 1; j < nruns && runs[j].start < cursor; j++)
            ;

        if (logical >= end)
            break;
        if (logical + blen <= start) {
            i = j;
            continue;
        }

        if (j >= nruns)
            flags |= FIEMAP_EXTENT_LAST;
        /* Preallocated and never written: the blocks are real and
         * mapped, the CONTENT is not there yet. */
        if (r->uninit)
            flags |= FIEMAP_EXTENT_UNWRITTEN;

        ret = fiemap_fill_next_extent(fi, logical, phys, blen, flags);
        if (ret) {
            /* 1 means the caller's buffer is full: a complete answer
             * for what it asked for, not an error. */
            if (ret == 1)
                ret = 0;
            break;
        }
        i = j;
    }
    kvfree(runs);

out:
    inode_unlock_shared(inode);
    return ret;
}

static loff_t cetrafs_llseek(struct file *file, loff_t offset, int whence)
{
    if ((whence == SEEK_DATA || whence == SEEK_HOLE) && cetrafs_sb_is_fenced(file_inode(file)->i_sb))
        return -EIO;
    if (whence == SEEK_DATA || whence == SEEK_HOLE)
        return cetrafs_seek_hole_data(file, offset, whence);
    return generic_file_llseek(file, offset, whence);
}

const struct address_space_operations cetrafs_aops = {
    .direct_IO = cetrafs_direct_IO,
    .read_folio = cetrafs_read_folio,
    .readahead = cetrafs_readahead,
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
/*
 * Free the data extents of an ALREADY-FETCHED list, then the tree's
 * own meta blocks.
 *
 * Split from the fetch deliberately. Evict frees the inode NUMBER
 * first -- the bitmap CAS is what arbitrates between two evicts and
 * the scrub, so it has to come first -- and only then the blocks. If
 * the tree turned out to be unreadable at that point, the number was
 * already back in the pool and the blocks stayed allocated, referenced
 * by a record the next file to take the number would overwrite. A
 * permanent, untraceable leak.
 *
 * evict_inode says exactly this about a failed RECORD read, three
 * screens above where it frees: "the only evidence of which blocks
 * leaked disappears the moment some later file reuses the number." The
 * reasoning was right and covered one of the two ways the read can
 * fail. So the list is fetched BEFORE the arbitration now, and a fetch
 * that fails refuses the whole eviction rather than half of it.
 */
void cetrafs_free_fetched_extents(struct inode *dir, const cetrafs_inode_t *raw, struct cetrafs_inode_extents *ex)
{
    struct super_block *sb = dir->i_sb;
    u32 i;

    for (i = 0; i < ex->entries; i++)
        cetrafs_free_data_extent(sb, cetrafs_extent_phys_from_hilo(ex->arr[i].ee_start_hi, ex->arr[i].ee_start_lo),
                                 cetrafs_extent_len(ex->arr[i].ee_len));
    if (cetrafs_le16(raw->eh.eh_depth) != 0)
        cetrafs_tree_free_meta(dir, raw);
}

void cetrafs_free_inline_extents(struct inode *dir, const cetrafs_inode_t *raw)
{
    struct super_block *sb = dir->i_sb;

    if (raw->eh.eh_depth == 0) {
        cetrafs_free_leaf_array(sb, raw->et.leaf,
                                min_t(u16, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf)));
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

/*
 * Remember an extent a walk just resolved, so the next block of the same
 * write does not walk again.
 *
 * A PREALLOCATED extent is deliberately never remembered. Its uninit
 * flag is cleared by a split that rewrites a LEAF block while leaving
 * the record's depth, entry count and block count untouched -- the three
 * fields the entry is keyed on -- so a remembered uninit extent is the
 * one case the key cannot invalidate. Getting that wrong in either
 * direction is serious (serving a preallocated block as data hands the
 * reader a deleted file's contents), and preallocated extents are rare
 * enough that skipping them costs nothing.
 */
static void cetrafs_tree_remember(struct inode *inode, const cetrafs_inode_t *raw, const struct cetrafs_ext_span *span)
{
    if (span->uninit || !span->len)
        return;
    cetrafs_inode_ext_cache_store(inode, raw, span->block, span->len, span->lba, false);
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
static bool cetrafs_leaf_array_lookup(const cetrafs_extent_t *arr,
                                      u16 entries,
                                      u32 iblock,
                                      u64 *out_lba,
                                      u32 *out_run,
                                      bool *out_uninit,
                                      struct cetrafs_ext_span *out_span)
{
    u16 i;

    for (i = 0; i < entries; i++) {
        u32 len = cetrafs_extent_len(arr[i].ee_len);
        u32 eb = cetrafs_le32(arr[i].ee_block);

        if (iblock >= eb && iblock < (u64) eb + len) {
            u64 base = cetrafs_extent_phys_from_hilo(arr[i].ee_start_hi, arr[i].ee_start_lo);

            *out_lba = base + (iblock - eb);
            if (out_run)
                *out_run = len - (iblock - eb);
            if (out_uninit)
                *out_uninit = cetrafs_extent_is_uninit(arr[i].ee_len);
            /* The WHOLE extent, not just the tail from iblock: that is
             * what lets the caller remember it and answer the blocks
             * BEFORE iblock too, which a backwards or strided walk
             * asks for. */
            if (out_span) {
                out_span->block = eb;
                out_span->len = len;
                out_span->lba = base;
                out_span->uninit = cetrafs_extent_is_uninit(arr[i].ee_len);
            }
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
static int
cetrafs_leaf_array_insert(cetrafs_extent_t *arr, __le16 *entries, u16 max, u32 iblock, u64 lba, u32 count, bool uninit);

/* Preallocated blocks a split could not keep -- the give-back. Every
 * split now grows the tree instead, so this moves only when that growth
 * itself fails (cetrafs_tree_convert_append()). It reached hundreds per
 * write on the deployment cluster, one free_data_block() each. */
static atomic64_t cetrafs_giveback_blocks = ATOMIC64_INIT(0);

u64 cetrafs_giveback_block_count(void)
{
    return (u64) atomic64_read(&cetrafs_giveback_blocks);
}

/* Converts that met a FULL leaf and grew the tree instead: the evidence
 * that a test splitting preallocated extents reached that path at all. */
static atomic64_t cetrafs_convert_leaf_full = ATOMIC64_INIT(0);

u64 cetrafs_convert_leaf_full_count(void)
{
    return (u64) atomic64_read(&cetrafs_convert_leaf_full);
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
/*
 * Find the WRITTEN extents a just-converted run [iblock, +count) at 'lba'
 * would continue: 'pred' ends exactly where it starts, 'succ' starts
 * exactly where it ends, both logically AND physically. -1 = none.
 *
 * cetrafs_leaf_array_insert() merges only into the LAST entry, which is
 * right for a file written in order. A preallocated range converted out
 * of order -- O_DIRECT completions arrive in any order, sixteen 1 MiB
 * writes into one hole at a time -- left every piece its own extent:
 * a sequential fill of a 256 MiB hole ended at 232 extents where the
 * buffered path left 1, and the later overwrites paid for it.
 */
static void cetrafs_leaf_array_neighbours(const cetrafs_extent_t *arr,
                                          u16 n,
                                          u32 iblock,
                                          u64 lba,
                                          u32 count,
                                          int *pred,
                                          int *succ)
{
    u16 j;

    *pred = -1;
    *succ = -1;
    for (j = 0; j < n; j++) {
        u32 eb = cetrafs_le32(arr[j].ee_block);
        u32 len = cetrafs_extent_len(arr[j].ee_len);
        u64 phys = cetrafs_extent_phys_from_hilo(arr[j].ee_start_hi, arr[j].ee_start_lo);

        if (cetrafs_extent_is_uninit(arr[j].ee_len) || !len)
            continue;
        if ((u64) eb + len == iblock && phys + len == lba && (u64) len + count <= CETRAFS_EXT_LEN_MASK)
            *pred = j;
        else if ((u64) iblock + count == eb && lba + count == phys && (u64) len + count <= CETRAFS_EXT_LEN_MASK)
            *succ = j;
    }
}

/*
 * Record the converted run by growing a neighbour instead of adding an
 * entry: no slot needed, nothing leaves this leaf. Returns false (array
 * untouched) when there is no neighbour to grow.
 */
static bool cetrafs_leaf_array_coalesce(cetrafs_extent_t *arr, u16 *np, u32 iblock, u64 lba, u32 count)
{
    int p, q;

    cetrafs_leaf_array_neighbours(arr, *np, iblock, lba, count, &p, &q);
    if (p >= 0) {
        u32 plen = cetrafs_extent_len(arr[p].ee_len) + count;

        if (q >= 0 && (u64) plen + cetrafs_extent_len(arr[q].ee_len) <= CETRAFS_EXT_LEN_MASK) {
            /* Bridges the two: one extent, and the successor's slot goes.
             * The array is unordered, so the last entry fills the gap. */
            plen += cetrafs_extent_len(arr[q].ee_len);
            arr[p].ee_len = cetrafs_extent_pack_len(plen, false);
            arr[q] = arr[*np - 1];
            (*np)--;
            return true;
        }
        arr[p].ee_len = cetrafs_extent_pack_len(plen, false);
        return true;
    }
    if (q >= 0) {
        arr[q].ee_block = cetrafs_cpu_to_le32(iblock);
        arr[q].ee_len = cetrafs_extent_pack_len(cetrafs_extent_len(arr[q].ee_len) + count, false);
        cetrafs_extent_phys_to_hilo(lba, &arr[q].ee_start_hi, &arr[q].ee_start_lo);
        return true;
    }
    return false;
}

/* A preallocated remainder a full leaf could not keep: the caller
 * appends it through the tree as an uninit extent. len 0 = none. */
struct cetrafs_convert_tail {
    u32 block;
    u64 lba;
    u32 len;
};

static int cetrafs_leaf_array_convert(struct super_block *sb,
                                      cetrafs_extent_t *arr,
                                      __le16 *entries,
                                      u16 max,
                                      u32 iblock,
                                      u64 lba,
                                      u32 want,
                                      u32 *done,
                                      struct cetrafs_convert_tail *tail_out)
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
        bool middle, in_place;

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
            cetrafs_sb_corrupt(sb, 0);
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
        /* Needs no slot at all: the whole extent converts in place, or
         * an edge converts into a written neighbour that just grows. */
        {
            int p, q;

            cetrafs_leaf_array_neighbours(arr, n, iblock, lba, count, &p, &q);
            in_place = !middle && (count == len || p >= 0 || q >= 0);
        }

        /*
         * Room check BEFORE any mutation.
         *
         * A FULL leaf used to fail here with -ENOSPC, silently. That is
         * the whole "VM pauses on nospace with terabytes free" bug: a
         * qcow2 preallocated by fallocate() is made of UNINIT extents,
         * every guest write into one has to split it, a split needs a
         * free slot, and once that leaf's array filled there was none.
         * Nothing grew the tree and nothing logged it. Found: by
         * kretprobe, after the allocator had been exonerated twice
         * over. What happens now is below.
         */
        if (n + 1 > max && !in_place) {
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
            atomic64_inc(&cetrafs_convert_leaf_full);
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
                 * the head here and hand the tail to the caller, which
                 * appends it through the tree as a second uninit extent
                 * next to the converted block.
                 *
                 * This used to free the tail: the rest of the
                 * preallocation -- 24571 blocks of a 96 MiB file in
                 * write_path_cost.sh -- became a hole, so a VM image
                 * could later hit ENOSPC on space it had reserved. */
                arr[i].ee_len = cetrafs_extent_pack_len(head, true);
                tail_out->block = iblock + 1;
                tail_out->lba = phys + head + 1;
                tail_out->len = tail;
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
            } else {
                /*
                 * One slot free (a full leaf was handled above), and a
                 * middle split wants two. Put the
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
                 *
                 * Single-block, like the leaf-full branch above: the
                 * caller appends exactly ONE block
                 * (cetrafs_tree_convert_append()). This used to keep
                 * the run's count, report all of it done, and append
                 * one -- an O_DIRECT completion converts a whole run at
                 * once, and every block of it after the first ended up
                 * in no extent: its data on the device, the file
                 * reading zeros there (tests/kernel/dio_convert_split.sh).
                 * The rest of the run is left in the tail, still
                 * preallocated, for the caller's next call.
                 */
                count = 1;
                arr[n].ee_block = cetrafs_cpu_to_le32(iblock + count);
                arr[n].ee_len = cetrafs_extent_pack_len(len - head - count, true);
                cetrafs_extent_phys_to_hilo(phys + head + count, &arr[n].ee_start_hi, &arr[n].ee_start_lo);
                *entries = cetrafs_cpu_to_le16(++n);
                *done = count;
                return CETRAFS_CONVERT_APPEND;
            }
        } else if (iblock == eb) {
            if (len == count) {
                /* The run covered the whole extent: drop it. The array
                 * is unordered, so the last entry fills the gap. */
                if (unlikely(READ_ONCE(cetrafs_leaf_drop_copy_stall_ms)) && i != n - 1) {
                    /* TEST ONLY: the copy is several stores; hold it
                     * half done (tests/kernel/leaf_torn_lookup.sh). */
                    arr[i].ee_block = arr[n - 1].ee_block;
                    arr[i].ee_len = arr[n - 1].ee_len;
                    msleep(READ_ONCE(cetrafs_leaf_drop_copy_stall_ms));
                }
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
        if (cetrafs_leaf_array_coalesce(arr, &n, iblock, lba, count)) {
            *entries = cetrafs_cpu_to_le16(n);
            return 0;
        }
        /* in_place promised no slot was needed; the neighbour it saw is
         * judged on content the shrink above does not touch, so it must
         * still be there. If not, the array is already edited and has no
         * room: say so loudly rather than let the insert fail quietly. */
        WARN_ON_ONCE(in_place && count != len && n >= max);
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
static int
cetrafs_leaf_array_insert(cetrafs_extent_t *arr, __le16 *entries, u16 max, u32 iblock, u64 lba, u32 count, bool uninit)
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
static u32 cetrafs_leaf_array_trim(struct super_block *sb,
                                   cetrafs_extent_t *arr,
                                   u32 entries,
                                   u64 new_block_count,
                                   u32 *out_freed,
                                   bool do_free)
{
    u32 i, kept = 0;
    u32 freed = 0;

    for (i = 0; i < entries; i++) {
        u32 len = cetrafs_extent_len(arr[i].ee_len);
        /* Same rule as the punch's splits: a trimmed PREALLOCATED
         * extent stays preallocated. */
        int uninit_entry = cetrafs_extent_is_uninit(arr[i].ee_len);
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
            arr[i].ee_len = cetrafs_extent_pack_len(new_len, uninit_entry);
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
/* See cetrafs_leaf_array_trim() for what 'do_free' is for.
 *
 * Counts are u32 here and in cetrafs_leaf_array_trim(), as they are in
 * struct cetrafs_inode_extents: both edit the FLATTENED map of a whole
 * file, and a depth-2 tree holds far more than 65535 extents. They took
 * u16 once, so a file with 65536 + k extents was edited as if it had k
 * and rebuilt from those -- every other extent dropped from the map, its
 * blocks leaked (tests/kernel/extent_count_u16.sh). */
static int cetrafs_leaf_array_punch(struct super_block *sb,
                                    cetrafs_extent_t *arr,
                                    u32 *entries,
                                    u32 max,
                                    u64 start_block,
                                    u64 end_block,
                                    u32 *out_freed,
                                    bool do_free)
{
    u32 i, w, count = *entries;
    u32 freed = 0;
    u32 splits = 0;

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
    if ((u64) count + splits > max)
        return -ENOSPC; /* nothing freed, nothing changed */

    /*
     * One compaction pass: entries are read at i and kept at w <= i.
     * It used to memmove the whole remaining array for every dropped
     * entry, and the array is the FLATTENED tree -- up to ~258k entries
     * -- so punching a large range (a guest's TRIM of a VM image) was
     * O(dropped x n) of memmove under the exclusive invalidate_lock,
     * with no reschedule.
     */
    for (i = 0, w = 0; i < count; i++) {
        cetrafs_extent_t e = arr[i];
        u32 len = cetrafs_extent_len(e.ee_len);
        /*
         * Whether this entry is PREALLOCATED, carried through every
         * rewrite below. cetrafs_extent_pack_len() packs the flag into
         * the length's high bit, so passing 0 STRIPS it: punching part
         * of a fallocate(KEEP_SIZE) range used to turn the surviving
         * head/tail into ordinary data, and blocks that had never been
         * written stopped reading as zeros -- they served whatever
         * their previous owner had left in them.
         */
        int uninit_entry = cetrafs_extent_is_uninit(e.ee_len);
        u64 estart = cetrafs_le32(e.ee_block);
        u64 eend = estart + len; /* exclusive */
        u64 phys = cetrafs_extent_phys_from_hilo(e.ee_start_hi, e.ee_start_lo);
        u64 hs = max_t(u64, estart, start_block); /* [hs, he) is this entry's overlap with the hole */
        u64 he = min_t(u64, eend, end_block);

        if (hs >= he) {
            arr[w++] = e; /* no overlap with the hole */
            continue;
        }

        if (do_free)
            cetrafs_free_data_extent(sb, phys + (hs - estart), (u32) (he - hs));
        freed += (u32) (he - hs);

        if (hs == estart && he == eend) {
            /* hole covers the whole entry: drop it */
        } else if (hs == estart) {
            /* hole eats the front */
            e.ee_block = cetrafs_cpu_to_le32((u32) he);
            cetrafs_extent_phys_to_hilo(phys + (he - estart), &e.ee_start_hi, &e.ee_start_lo);
            e.ee_len = cetrafs_extent_pack_len((u32) (eend - he), uninit_entry);
            arr[w++] = e;
        } else if (he == eend) {
            /* hole eats the back (same shape as _trim()'s own case) */
            e.ee_len = cetrafs_extent_pack_len((u32) (hs - estart), uninit_entry);
            arr[w++] = e;
        } else {
            /* hole lands entirely inside: split into front + tail */
            cetrafs_extent_t tail;

            tail.ee_block = cetrafs_cpu_to_le32((u32) he);
            cetrafs_extent_phys_to_hilo(phys + (he - estart), &tail.ee_start_hi, &tail.ee_start_lo);
            tail.ee_len = cetrafs_extent_pack_len((u32) (eend - he), uninit_entry);
            e.ee_len = cetrafs_extent_pack_len((u32) (hs - estart), uninit_entry);

            if (w < i) {
                /* An earlier drop left room: both fit at or below i. */
                arr[w++] = e;
                arr[w++] = tail;
                continue;
            }
            /* w == i: nothing dropped yet, so the array grows here. A
             * punch is one range, so on a sound tree at most one entry
             * can contain it -- this shift runs once, not per entry. */
            if (count >= max) {
                /* Unreachable: the dry run above already refused any
                 * punch that could get here. Kept as an assertion rather
                 * than deleted -- if it ever fires, the two loops have
                 * drifted apart and blocks have already been freed. The
                 * array is intact here (w == i: nothing compacted). */
                pr_err("punch: split would overflow the leaf after freeing %u block(s) -- dry run disagreed\n", freed);
                *entries = count;
                *out_freed = freed;
                return -ENOSPC;
            }
            memmove(&arr[i + 2], &arr[i + 1], (count - i - 1) * sizeof(*arr));
            arr[i] = e;
            arr[i + 1] = tail;
            count++;
            i++; /* skip the newly inserted tail entry -- it can't overlap the hole */
            w = i + 1;
        }
    }
    count = w;

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
        u64 end = (u64) eb + cetrafs_extent_len(arr[i].ee_len);

        /*
         * In 64 bits, because the sum does not fit in 32.
         *
         * A legal block number runs to CETRAFS_MAX_FILE_BLOCKS - 1, so
         * an extent reaching the last block ends at exactly 2^32 and
         * wrapped this to 0 -- which is not merely wrong, it is wrong
         * in the UNSAFE direction: 0 does not raise 'hi', so a leaf
         * holding that extent plus any lower one advertises a range
         * that EXCLUDES it, and the walk then skips the leaf and reads
         * the block as a hole.
         *
         * An unrepresentable end becomes UNKNOWN (the 0 that means
         * "read this child anyway"), never a smaller number. Through
         * the VFS this is unreachable -- s_maxbytes stops one block
         * short, measured as EFBIG at block 2^32-1 -- so what it
         * defends against is a corrupt leaf steering the walk away from
         * blocks that are really there.
         */
        if (end > U32_MAX) {
            *out_lo = 0;
            *out_hi = 0; /* unknown: never skipped */
            return;
        }

        if (eb < lo)
            lo = eb;
        if (end > hi)
            hi = (u32) end;
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
    if (!end) { /* an end past 2^32 (cetrafs_idx_end()): becomes unknown */
        e->ei_block_end = 0;
        return;
    }
    if (block < cetrafs_le32(e->ei_block))
        e->ei_block = cetrafs_cpu_to_le32(block);
    if (end > cetrafs_le32(e->ei_block_end))
        e->ei_block_end = cetrafs_cpu_to_le32(end);
}

/* The end of [iblock, iblock + count) for a range bound: an end that
 * does not fit 32 bits is 0, UNKNOWN, never a wrapped smaller number --
 * see cetrafs_leaf_array_range(). */
static u32 cetrafs_idx_end(u32 iblock, u32 count)
{
    u64 end = (u64) iblock + count;

    return end > U32_MAX ? 0 : (u32) end;
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
 * it never flattens the whole tree (the full-scan readers do that).
 *
 * Leaf and index entries are read under the BUFFER lock. A cached tree
 * block is the same memory the extent-tree writers edit in place, under
 * the buffer lock (cetrafs_bh_begin_update()) and invalidate_lock --
 * and this runs from paths holding neither: writeback, an O_DIRECT
 * read, against a completion's or a fault's conversion. An entry is
 * several stores, and an unordered array is compacted by copying the
 * last entry over a dropped one, so an unlocked scan could match a
 * logical range against another extent's physical address and read or
 * WRITE the wrong blocks. The buffer lock, not invalidate_lock:
 * writeback can run inside a task already holding that one
 * (cetrafs_bh_read_lock()). */
static int cetrafs_tree_lookup_unchecked(struct inode *inode,
                                         const cetrafs_inode_t *raw,
                                         u32 iblock,
                                         u64 *out_lba,
                                         u32 *out_run,
                                         bool *out_uninit,
                                         bool *found,
                                         bool reader)
{
    struct cetrafs_ext_span span = {0};
    u32 ni;

    *found = false;
    if (out_uninit)
        *out_uninit = false;
    if (out_run)
        *out_run = 1;

    if (raw->eh.eh_depth == 0) {
        /* Inline extents live in the record the caller just read: the
         * scan is a handful of comparisons over at most 4 slots and
         * touches no block at all. Nothing to cache, and nothing a
         * cache could save. */
        *found = cetrafs_leaf_array_lookup(raw->et.leaf,
                                           min_t(u16, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf)),
                                           iblock, out_lba, out_run, out_uninit, NULL);
        return 0;
    }

    /*
     * Spilled tree: try the remembered extent first.
     *
     * Gated on exactly the predicate cetrafs_read_tree_bh() uses to
     * decide a CACHED leaf may be trusted -- this entry was built out
     * of those leaves, so it must not outlive their trust. Where that
     * predicate is false every leaf read goes to the device anyway, and
     * answering from memory there would be the frozen-extent-tree bug
     * with extra steps.
     */
    if ((reader ? cetrafs_lock_read_cache_trusted(inode) : cetrafs_lock_held_for_write_locally(inode)) &&
        cetrafs_inode_ext_cache_lookup(inode, raw, iblock, out_lba, out_run, out_uninit)) {
        *found = true;
        return 0;
    }

    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        u64 llba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
        struct buffer_head *lbh = cetrafs_read_leaf_bh_for(inode, llba, reader);
        const cetrafs_extent_hdr_t *lhdr;

        if (!lbh)
            return -EIO;
        lhdr = (const cetrafs_extent_hdr_t *) lbh->b_data;
        /* Under the buffer lock: see cetrafs_tree_lookup_unchecked(). */
        cetrafs_bh_read_lock(lbh);
        *found = cetrafs_leaf_array_lookup((const cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)),
                                           min_t(u16, cetrafs_le16(lhdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES),
                                           iblock, out_lba, out_run, out_uninit, &span);
        cetrafs_bh_read_unlock(lbh);
        brelse(lbh);
        if (*found)
            cetrafs_tree_remember(inode, raw, &span);
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
        ibh = cetrafs_read_index_bh_for(inode, ilba, reader);

        if (!ibh)
            return -EIO;
        ihdr = (const cetrafs_extent_hdr_t *) ibh->b_data;
        iarr = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));

        for (li = 0;; li++) {
            u64 llba;
            struct buffer_head *lbh;
            const cetrafs_extent_hdr_t *lhdr;
            cetrafs_extent_idx_t ie;

            /* One entry at a time, copied under the buffer lock and
             * released before the leaf is locked: never two at once. */
            cetrafs_bh_read_lock(ibh);
            iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);
            if (li < iln)
                ie = iarr[li];
            cetrafs_bh_read_unlock(ibh);
            if (li >= iln)
                break;

            /* THE point of ei_block_end: a leaf whose range excludes
             * this block is never read. Without it the walk read every
             * leaf until it hit -- ~56 of 113 on a fragmented VM image,
             * per mapped block. */
            if (!cetrafs_idx_may_hold(&ie, iblock))
                continue;
            llba = cetrafs_extent_phys_from_hilo(ie.ei_leaf_hi, ie.ei_leaf_lo);
            lbh = cetrafs_read_leaf_bh_for(inode, llba, reader);

            if (!lbh) {
                brelse(ibh);
                return -EIO;
            }
            lhdr = (const cetrafs_extent_hdr_t *) lbh->b_data;
            cetrafs_bh_read_lock(lbh);
            *found = cetrafs_leaf_array_lookup((const cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)),
                                               min_t(u16, cetrafs_le16(lhdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES),
                                               iblock, out_lba, out_run, out_uninit, &span);
            cetrafs_bh_read_unlock(lbh);
            brelse(lbh);
            if (*found) {
                brelse(ibh);
                cetrafs_tree_remember(inode, raw, &span);
                return 0;
            }
        }
        brelse(ibh);
    }
    return 0;
}

/*
 * The resolver above, with the one thing it never checked: that the
 * address it produced is one a file's blocks may occupy.
 *
 * ee_start_hi/lo is 48 bits read off the device, and every return path
 * above turns it straight into *out_lba. cetrafs_get_block() then hands
 * that to map_bh(), so an extent pointing at the inode table makes a
 * write(2) land on the inode table -- demonstrated on a 560 MiB image:
 * the records of inodes 1..4 overwritten by file data, fsck afterwards
 * reporting "root is not a dir". A read of the same file returned the
 * root inode's record as its contents.
 *
 * A wrapper rather than a check at each of the four return points,
 * because four places that must each remember is three that can forget
 * -- the same reasoning cetrafs_blk_struct_ok_magic() gives for
 * validating counts where the block is read. See
 * cetrafs_lba_run_is_data() for what this costs and what it cannot see.
 *
 * -EUCLEAN, not -EIO: the device answered perfectly, the record is
 * wrong. The mapping is refused rather than clamped -- there is no
 * nearby address that is the "right" one, and guessing would publish
 * the guess.
 */
static int cetrafs_tree_lookup(struct inode *inode,
                               const cetrafs_inode_t *raw,
                               u32 iblock,
                               u64 *out_lba,
                               u32 *out_run,
                               bool *out_uninit,
                               bool *found,
                               bool reader)
{
    int ret = cetrafs_tree_lookup_unchecked(inode, raw, iblock, out_lba, out_run, out_uninit, found, reader);

    if (ret || !*found)
        return ret;

    if (!cetrafs_lba_run_is_data(inode->i_sb, *out_lba, out_run ? *out_run : 1)) {
        pr_err_ratelimited("ino=%llu: logical block %u maps to [%llu,+%u), which is not a data address -- refusing it (fsck)\n",
                           (unsigned long long) inode->i_ino, iblock, (unsigned long long) *out_lba,
                           out_run ? *out_run : 1);
        cetrafs_sb_corrupt_inode(inode);
        *found = false;
        return -EUCLEAN;
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
        return cetrafs_leaf_array_next_contig_lba(
            raw->et.leaf, min_t(u16, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf)));
    if (raw->eh.eh_entries == 0)
        return 0;

    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        llba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
    } else {
        u16 n = cetrafs_le16(raw->eh.eh_entries);

        /* A count read off the disk indexes a 4-slot array: bound it
         * (rule 19). This is only an allocation hint, so a record that
         * makes no sense gets none; the paths that act on the tree
         * refuse it themselves. Nothing upstream checked it: fallocate
         * reaches here without __cetrafs_get_block()'s record check. */
        if (cetrafs_le16(raw->eh.eh_depth) != 2 || n > ARRAY_SIZE(raw->et.idx))
            return 0;
        ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[n - 1].ei_leaf_hi, raw->et.idx[n - 1].ei_leaf_lo);
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
                (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*h)) +
                (min_t(u16, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX) - 1);
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
        cetrafs_free_data_block(sb,
                                cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo));
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
            total = min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) lbh->b_data)->eh_entries),
                          CETRAFS_EXT_BLOCK_MAX_LEAVES);
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
int cetrafs_tree_build(struct inode *inode, const cetrafs_extent_t *flat, u32 n, cetrafs_inode_t *raw, u64 *out_meta)
{
    /* The whole map is being rewritten. This is also the choke point
     * that covers a defrag RELOCATION -- the one mutation that can
     * leave depth, entry count and block count all identical while
     * every extent moves, so the key alone would not catch it. */
    cetrafs_inode_ext_cache_drop(inode);

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

    blk = kvmalloc_array(total, sizeof(*blk), GFP_NOFS);
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
    kvfree(blk);
    return 0;

fail:
    /* free whatever we claimed; the caller's old tree is untouched */
    for (i = 0; i < allocated; i++)
        cetrafs_free_data_block(sb, blk[i]);
    kvfree(blk);
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
static int cetrafs_tree_append(struct inode *inode,
                               cetrafs_inode_t *raw,
                               u32 iblock,
                               u64 lba,
                               u32 count,
                               bool uninit,
                               bool *merged,
                               u32 *leaf_count);

/*
 * The converted block could not fit its leaf, so the leaf was shrunk in
 * place and the block is appended through the tree instead -- which
 * allocates a new leaf (or interior) exactly as a growing file does.
 * This is what keeps a full leaf from turning every later write into a
 * preallocation give-back.
 */
static int cetrafs_tree_convert_append(struct inode *inode,
                                       cetrafs_inode_t *raw,
                                       u32 iblock,
                                       u64 lba,
                                       const struct cetrafs_convert_tail *tail)
{
    bool merged = false;
    u32 leaf_count = 0;
    int ret, tret = 0;

    ret = cetrafs_tree_append(inode, raw, iblock, lba, 1, /*uninit=*/false, &merged, &leaf_count);
    if (!ret && tail->len)
        tret = cetrafs_tree_append(inode, raw, tail->block, tail->lba, tail->len, /*uninit=*/true, &merged,
                                   &leaf_count);
    if (tail->len && (ret || tret)) {
        /*
         * The tail is in no extent now. It is NOT freed: the leaf that
         * still names it on the device is only dirty in cache, and a
         * bit cleared before that leaf is rewritten would let a crash
         * leave a referenced block FREE (rule 8). Left allocated and
         * unreferenced, it is a leak the scrub reclaims -- the safe
         * direction. The file loses that much of its preallocation.
         */
        pr_warn_ratelimited("ino=%llu: could not keep %u preallocated block(s) at %llu splitting a full extent leaf "
                            "(%d): they become a hole, reclaimed later by the scrub; no data is lost\n",
                            (unsigned long long) inode->i_ino, tail->len, (unsigned long long) tail->lba,
                            ret ? ret : tret);
        atomic64_add(tail->len, &cetrafs_giveback_blocks);
        raw->blocks = cetrafs_cpu_to_le64(cetrafs_le64(raw->blocks) -
                                          min_t(u64, cetrafs_le64(raw->blocks),
                                                (u64) tail->len * (CETRAFS_BLOCK_SIZE / 512)));
    }
    return ret; /* the written block is mapped; a lost tail is not the write's failure */
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
static bool cetrafs_leaf_data_holds_uninit(const void *data, void *arg)
{
    const cetrafs_extent_hdr_t *lhdr = data;
    const cetrafs_extent_t *arr = (const cetrafs_extent_t *) ((const u8 *) data + sizeof(*lhdr));
    u32 iblock = *(const u32 *) arg;
    u16 n = min_t(u16, cetrafs_le16(lhdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES), i;

    for (i = 0; i < n; i++) {
        u32 eb = cetrafs_le32(arr[i].ee_block);

        if (cetrafs_extent_is_uninit(arr[i].ee_len) && iblock >= eb &&
            (u64) iblock < (u64) eb + cetrafs_extent_len(arr[i].ee_len))
            return true;
    }
    return false;
}

/* Does this leaf hold 'iblock' in a preallocated extent? Read-only,
 * under the buffer lock so it never sees a writer's half-edited array;
 * the extent-tree writers are excluded by invalidate_lock, which the
 * caller holds. */
static bool cetrafs_leaf_bh_holds_uninit(struct buffer_head *lbh, u32 iblock)
{
    return cetrafs_bh_test_stable(lbh, cetrafs_leaf_data_holds_uninit, &iblock);
}

/*
 * A split that hands part of an extent to ANOTHER leaf (the converted
 * block, the preallocated tail) shrank it here first, and both leaves
 * are regular-file tree blocks left dirty for the close/fsync boundary.
 * The block device writes dirty buffers in any order: the destination
 * reaching the device without this one leaves the device's tree naming
 * the moved blocks TWICE, and a later delete frees them twice -- the
 * second time from under whichever file was given them in between
 * (tests/kernel/convert_leaf_order.sh). So this leaf goes to the device
 * NOW, before anything else names what it gave up: a crash in between
 * leaves those blocks named by nothing, a leak the scrub reclaims (the
 * safe direction, rule 8). One synchronous write per split of a FULL
 * leaf -- and that is NOT rare: random writes into a fallocated file fill
 * the leaf that holds the preallocated extent (each middle split adds two
 * entries) and nothing ever empties it, so from then on nearly every
 * conversion lands here. Measured at 60-77% of 4 KiB writes into
 * fallocated space, which is what caps that case at device latency per
 * write (docs/PERFORMANCE.md 14). Not fixed yet.
 *
 * Kept dirty on failure: the cached leaf is the only copy of the shrunk
 * state, and the caller then appends nothing.
 */
static int cetrafs_convert_source_durable(struct inode *inode, struct buffer_head *lbh)
{
    int ret = cetrafs_sync_buffer_keep(inode->i_sb, lbh);

    if (ret)
        pr_err_ratelimited("ino=%llu: extent leaf %llu could not be written before its split moved on (%d)\n",
                           (unsigned long long) inode->i_ino, (unsigned long long) lbh->b_blocknr, ret);
    return ret;
}

static int cetrafs_tree_convert_inner(struct inode *inode,
                                      cetrafs_inode_t *raw,
                                      u32 iblock,
                                      u64 lba,
                                      u32 want,
                                      u32 *done)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_convert_tail tail = { 0 };
    u32 ni;
    int ret;

    if (raw->eh.eh_depth == 0) {
        ret = cetrafs_leaf_array_convert(sb, raw->et.leaf, &raw->eh.eh_entries, (u16) ARRAY_SIZE(raw->et.leaf), iblock,
                                         lba, want, done, &tail);
        if (ret == CETRAFS_CONVERT_APPEND)
            return cetrafs_tree_convert_append(inode, raw, (u32) iblock, lba, &tail);
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
                                         CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, want, done, &tail);
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
            if (ret == CETRAFS_CONVERT_APPEND) {
                int wret = cetrafs_convert_source_durable(inode, lbh);

                if (wret) {
                    brelse(lbh);
                    return wret;
                }
            }
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
            return cetrafs_tree_convert_append(inode, raw, (u32) iblock, lba, &tail);
        return 0;
    }

    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh(inode, ilba);
        cetrafs_extent_hdr_t *ihdr;
        cetrafs_extent_idx_t *iarr;
        u32 li, iln;

        if (!ibh)
            return -EIO;
        ihdr = (cetrafs_extent_hdr_t *) ibh->b_data;
        iarr = (cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));
        iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);

        for (li = 0; li < iln; li++) {
            u64 llba = cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo);
            struct buffer_head *lbh;
            cetrafs_extent_hdr_t *lhdr;

            if (!cetrafs_idx_may_hold(&iarr[li], iblock))
                continue; /* its range rules it out: not even read */
            lbh = cetrafs_read_leaf_bh(inode, llba);
            if (!lbh) {
                brelse(ibh);
                return -EIO;
            }
            /*
             * Look before claiming. The claim (begin_update) of a leaf
             * that turns out not to hold the block is released by
             * cetrafs_bh_abort_update(), which drops a CLEAN buffer's
             * cached image -- right for its error-path callers, and a
             * device re-read of every clean leaf this walk passed, on
             * every later lookup. Invisible while converted leaves stayed
             * dirty until fsync; once a split writes its source leaf
             * (cetrafs_convert_source_durable()) it cost 20x on
             * write_path_cost.sh: 34000 device reads instead of 52.
             */
            if (!cetrafs_leaf_bh_holds_uninit(lbh, iblock)) {
                brelse(lbh);
                continue; /* not in this leaf; try the next */
            }
            const u32 prev_crc = cetrafs_bh_begin_update_crc(lbh);
            lhdr = (cetrafs_extent_hdr_t *) lbh->b_data;
            ret = cetrafs_leaf_array_convert(sb, (cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)), &lhdr->eh_entries,
                                             CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, want, done, &tail);
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
                if (ret == CETRAFS_CONVERT_APPEND) {
                    int wret = cetrafs_convert_source_durable(inode, lbh);

                    if (wret) {
                        brelse(lbh);
                        brelse(ibh);
                        return wret;
                    }
                    /* Only now: a narrowed range on the device must
                     * never sit over a leaf the device still has
                     * unshrunk. */
                    /*
                     * Something LEFT this leaf (the converted block, the
                     * preallocated tail, or both go through the tree below), so
                     * its range in the interior may now be far too wide: ranges
                     * only ever widen, and a leaf that once held the tail of a
                     * preallocation advertises everything to the file's end.
                     * Left so, every leaf that ever held the tail is read by
                     * every later lookup past it -- write_path_cost.sh's lookup
                     * cost went from under 8 tree reads per lookup to 48. The
                     * leaf's whole array is in hand, so its exact range is
                     * known: narrow it. Regular files only (directories never
                     * reach depth 2).
                     */
                    if (cetrafs_le32(iarr[li].ei_block_end)) {
                        u32 lo, hi;

                        cetrafs_leaf_array_range((const cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)),
                                                 min_t(u16, cetrafs_le16(lhdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES), &lo,
                                                 &hi);
                        if (hi && (lo != cetrafs_le32(iarr[li].ei_block) || hi != cetrafs_le32(iarr[li].ei_block_end))) {
                            (void) cetrafs_bh_begin_update_crc(ibh);
                            iarr[li].ei_block = cetrafs_cpu_to_le32(lo);
                            iarr[li].ei_block_end = cetrafs_cpu_to_le32(hi);
                            cetrafs_blk_tail_stamp(ibh, CETRAFS_INDEX_TAIL_MAGIC);
                            cetrafs_bh_end_update(ibh);
                        }
                    }
                }
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
                return cetrafs_tree_convert_append(inode, raw, (u32) iblock, lba, &tail);
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
    /* A split rewrites a LEAF and can leave the record's depth, entry
     * count and block count untouched -- the key cannot see it. */
    cetrafs_inode_ext_cache_drop(inode);

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

static int cetrafs_tree_append(struct inode *inode,
                               cetrafs_inode_t *raw,
                               u32 iblock,
                               u64 lba,
                               u32 count,
                               bool uninit,
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

        ret = cetrafs_leaf_array_insert(raw->et.leaf, &raw->eh.eh_entries, ARRAY_SIZE(raw->et.leaf), iblock, lba,
                                        count, uninit);
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
            ret = cetrafs_leaf_array_insert(tmp, &ntmp, ARRAY_SIZE(tmp), iblock, lba, count, uninit);
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

    /*
     * Depth >= 1: from here the new reference goes into an EXTERNAL tree
     * block edited in place -- for a regular file left dirty in the block
     * device's cache until the close/fsync boundary, for a directory
     * journaled at once. Either way it can reach the device before the
     * allocation bitmap bit for the block it names: the block device's
     * own flusher writes dirty buffers in whatever order it likes, and
     * the bit was set with sync=false. A crash then leaves a tree naming
     * a block every node reads as FREE (rule 8;
     * tests/kernel/leaf_before_bitmap.sh, 3 of 3 rounds before this).
     * So no tree block is edited while any allocation bit is still only
     * in cache. Depth 0 needs nothing: its only reference is the record,
     * whose publish has the same flush as its choke point.
     */
    ret = cetrafs_alloc_flush_bitmaps_if_dirty(sb);
    if (ret)
        return ret;

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
        ret = cetrafs_leaf_array_insert(larr, &lhdr->eh_entries, CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, count,
                                        uninit);
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
            one.ee_len = cetrafs_extent_pack_len(count, uninit);
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
            cetrafs_idx_set(&idx[1], iblock, cetrafs_idx_end(iblock, count), new_leaf);
            ret = cetrafs_write_new_index(sb, new_idx, idx, 2);
            if (ret)
                goto d1_fail;

            memset(&raw->et, 0, sizeof(raw->et));
            raw->eh.eh_depth = cetrafs_cpu_to_le16(2);
            raw->eh.eh_entries = cetrafs_cpu_to_le16(1);
            raw->eh.eh_max = cetrafs_cpu_to_le16(ARRAY_SIZE(raw->et.idx));
            cetrafs_idx_set(&raw->et.idx[0], 0, 0 /* root: unknown by design, see below */, new_idx);
            raw->blocks = cetrafs_cpu_to_le64(cetrafs_le64(raw->blocks) +
                                              (2 * (CETRAFS_BLOCK_SIZE / 512))); /* new leaf + new interior */
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
        /* A depth-2 tree with no root slots is not a tree this code can
         * append to, and "last = entries - 1" on zero wraps to
         * 0xffffffff and indexes far outside the record. The upper
         * bound is enforced where the record is read; the lower one has
         * to be here, because an empty root is a legal intermediate
         * state rather than corruption. */
        u32 entries = cetrafs_le16(raw->eh.eh_entries);
        u32 last;
        u64 ilba;

        if (entries == 0 || entries > ARRAY_SIZE(raw->et.idx)) {
            pr_err_ratelimited("ino=%llu: depth-2 tree with %u root slot(s) -- refusing to append\n",
                               (unsigned long long) inode->i_ino, entries);
            cetrafs_sb_corrupt_inode(inode);
            return -EUCLEAN;
        }
        last = entries - 1;
        ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[last].ei_leaf_hi, raw->et.idx[last].ei_leaf_lo);
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
        /* Same wrap, one level down -- and unlike the sibling walk in
         * cetrafs_tree_last_contig_lba(), this one had no zero check. */
        if (cetrafs_le16(ihdr->eh_entries) == 0) {
            pr_err_ratelimited("ino=%llu: interior %llu has no entries -- refusing to append\n",
                               (unsigned long long) inode->i_ino, (unsigned long long) ilba);
            cetrafs_sb_corrupt_inode(inode);
            brelse(ibh);
            return -EUCLEAN;
        }
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
        ret = cetrafs_leaf_array_insert(larr, &lhdr->eh_entries, CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, count,
                                        uninit);
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

                if (ient && (!cetrafs_idx_may_hold(&iarr[ient - 1], iblock) ||
                             !cetrafs_idx_may_hold(&iarr[ient - 1], iblock + count - 1) ||
                             !cetrafs_idx_end(iblock, count))) {
                    const u32 iprev = cetrafs_bh_begin_update_crc(ibh);

                    cetrafs_idx_widen(&iarr[ient - 1], iblock, cetrafs_idx_end(iblock, count));
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
            one.ee_len = cetrafs_extent_pack_len(count, uninit);
            cetrafs_extent_phys_to_hilo(lba, &one.ee_start_hi, &one.ee_start_lo);

            ret = cetrafs_alloc_block_anywhere(sb, &bg, &new_leaf);
            if (ret) {
                brelse(ibh);
                return ret;
            }
            /* Linked below from an interior edited in place: its bit
             * first, same as the gate above. */
            ret = cetrafs_alloc_flush_bitmaps_if_dirty(sb);
            if (ret) {
                cetrafs_free_data_block(sb, new_leaf);
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
                cetrafs_idx_set(&iarr[cetrafs_le16(ihdr->eh_entries)], iblock, cetrafs_idx_end(iblock, count),
                                new_leaf);
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
                raw->blocks =
                    cetrafs_cpu_to_le64(cetrafs_le64(raw->blocks) + (CETRAFS_BLOCK_SIZE / 512)); /* new leaf */
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
                cetrafs_idx_set(&idx1, iblock, cetrafs_idx_end(iblock, count), new_leaf);
                ret = cetrafs_write_new_index(sb, new_idx, &idx1, 1);
                if (ret) {
                    cetrafs_free_data_block(sb, new_idx);
                    cetrafs_free_data_block(sb, new_leaf);
                    return ret;
                }
                cetrafs_idx_set(&raw->et.idx[cetrafs_le16(raw->eh.eh_entries)], 0, 0 /* root: unknown */, new_idx);
                raw->eh.eh_entries = cetrafs_cpu_to_le16(cetrafs_le16(raw->eh.eh_entries) + 1);
                raw->blocks = cetrafs_cpu_to_le64(cetrafs_le64(raw->blocks) +
                                                  (2 * (CETRAFS_BLOCK_SIZE / 512))); /* new leaf + new interior */
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

/* A streaming file's run doubles from alloc_run_blocks up to this --
 * see cetrafs_inode_next_run_len(). */
static unsigned int cetrafs_alloc_run_max_blocks = 4096;
module_param_named(alloc_run_max_blocks, cetrafs_alloc_run_max_blocks, uint, 0644);
MODULE_PARM_DESC(alloc_run_max_blocks, "largest speculative run a streaming file grows to, in blocks");

static int __cetrafs_get_block(struct inode *inode,
                               sector_t iblock,
                               struct buffer_head *bh_result,
                               int create,
                               bool reader,
                               enum cetrafs_gb_mode mode)
{
    u32 want = 1, converted = 1;
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    u64 lba;
    u32 bg_id;
    u32 run = 1; /* contiguous blocks mappable from iblock (see below) */
    bool found, merged, uninit = false;
    bool dio_prealloc = false;
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
    /* A pure READ asks a different question -- may a reader trust its
     * cache? -- answered by cetrafs_lock_read_cache_trusted(). */
    if (S_ISDIR(inode->i_mode) ||
        !(reader ? cetrafs_lock_read_cache_trusted(inode) : cetrafs_lock_held_for_write_locally(inode)))
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);

    ret = cetrafs_read_raw_inode_overlaid(sb, inode, &raw); /* torn-read-safe vs a concurrent publish */
    if (ret)
        return ret;
    /* The device's file sector may lag this node's own in-flight writes:
     * overlay the pending shadow (v0x0005) so this mapping sees every
     * extent the hot path has already handed out. */

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
        pr_warn_ratelimited(
            "ino=%llu: record generation %llu != in-core %llu -- the number was reused; refusing to map\n",
            (unsigned long long) inode->i_ino, (unsigned long long) cetrafs_le64(raw.generation),
            (unsigned long long) cetrafs_inode_get_generation(inode));
        return -ESTALE;
    }

    if (cetrafs_le16(raw.eh.eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(raw.eh.eh_depth) > CETRAFS_EXT_MAX_DEPTH ||
        cetrafs_le16(raw.eh.eh_entries) > ARRAY_SIZE(raw.et.leaf))
        return -EIO;

    ret = cetrafs_tree_lookup(inode, &raw, (u32) iblock, &lba, &run, &uninit, &found, reader);
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
    if (found && uninit && mode == CETRAFS_GB_DIO) {
        /* Mapped as it is; the completion converts it once the data is
         * on the device (enum cetrafs_gb_mode). Widened to the rest of
         * the preallocated extent like any other mapping. */
        u64 w = bh_result->b_size >> inode->i_blkbits;

        map_bh(bh_result, sb, lba);
        if (w > 1 && run > 1)
            bh_result->b_size = (size_t) min_t(u64, w, run) << inode->i_blkbits;
        cetrafs_dio_mark_convert(bh_result);
        atomic64_inc(&cetrafs_map_calls);
        atomic64_add(bh_result->b_size >> inode->i_blkbits, &cetrafs_map_blocks);
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
    if (mode == CETRAFS_GB_CONVERT) {
        /* The write being completed mapped this block, and nothing may
         * free it while that write is in flight. A hole here means the
         * map changed under an in-flight DIO: report it, never paper
         * over it by allocating. */
        pr_err_ratelimited("ino=%llu: block %llu of a completing O_DIRECT write is a hole -- not converting\n",
                           (unsigned long long) inode->i_ino, (unsigned long long) iblock);
        return -EIO;
    }
    /* An O_DIRECT write allocates PREALLOCATED, inside i_size and past
     * it alike (enum cetrafs_gb_mode); its completion converts what
     * landed. Past i_size it used to allocate written data, on the
     * grounds that i_size moves only after the write completes -- but a
     * write that FAILS leaves i_size where it was and the block in the
     * tree as data, holding the previous owner's bytes, for a later
     * truncate-up or a write further out to expose. Preallocated, it
     * reads as zeros until something writes it. */
    dio_prealloc = mode == CETRAFS_GB_DIO;

    {
        ktime_t t0 = ktime_get();
        s64 us;
        /*
         * An O_DIRECT write takes NO hint: the next block of the file's
         * reserved run, whatever it is. Submissions allocate in file
         * order under inode_lock, so a sequential writer still gets
         * consecutive blocks from the run; a random one gets them too,
         * which is what keeps it from claiming a run per write.
         *
         * The buffered hint -- the physical end of the LAST array entry --
         * assumes the array grows in file order. Completions convert out
         * of order and conversion reorders the array (a dropped entry is
         * replaced by the last one), so under concurrent direct writes it
         * pointed somewhere arbitrary: cetrafs_inode_take_reserved()
         * refused the run, a new one was claimed and the old remainder
         * given back, and the next tree edit flushed the bitmap
         * synchronously under invalidate_lock -- one write in four, on a
         * delay device; a sequential fill fragmented (~190 extents per
         * 256 MiB). A hint taken from the block LOGICALLY before fixed
         * that too, but cost a tree lookup per allocation, and a lookup
         * that misses walks every leaf of a randomly filled file.
         */
        u64 preferred_lba = mode == CETRAFS_GB_DIO ? 0 : cetrafs_tree_last_contig_lba(inode, &raw);

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
                if (ret == -EAGAIN) /* the group was released after we chose it: choose again */
                    continue;
                if (ret != -ENOSPC)
                    break;

                {
                    s64 delta = 0;

                    if (cetrafs_bg_reconcile_free_count(sb, bg_id, &delta) != 0)
                        return ret; /* cannot even recount: report the original */
                    pr_warn_ratelimited(
                        "alloc: BG %u reported free space but its bitmap is full -- recounted (delta %lld)\n", bg_id,
                        (long long) delta);
                    /* Back off before re-picking: a recount is real I/O
                     * and a retry here is rare (only a BG whose cached
                     * count lied), so the cost is nil and it keeps this
                     * loop in line with every other retry loop here. */
                    usleep_range(50, 200);
                }
            }
            if (ret == -EAGAIN) /* every attempt lost its group to a release: as out of retries */
                ret = -ENOSPC;
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
                u32 want = cetrafs_inode_next_run_len(inode, cetrafs_alloc_run_blocks, cetrafs_alloc_run_max_blocks);
                u32 got = cetrafs_alloc_run_after(sb, bg_id, lba + 1, want);

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
                /* -EUCLEAN: a live directory still lists it, so the bit
                 * we just set is the truth -- keep it. */
                if (ret != -EUCLEAN)
                    cetrafs_free_data_block(sb, lba);
                return ret;
            }
        }
    }

    ret = cetrafs_tree_append(inode, &raw, (u32) iblock, lba, 1, dio_prealloc, &merged, &leaf_count);
    if (ret) {
        /*
         * A DIRECTORY's tree blocks go out through the journal, and a
         * failed append may already have published 'lba': a target write
         * that failed leaves its entry LIVE for replay (journal.c), and a
         * replay puts the leaf naming 'lba' on the device. Freeing it here
         * handed the next allocation a block that leaf names. Kept
         * allocated instead -- a block nothing ends up naming is a leak
         * the scrub reclaims, the safe direction (rule 8: no free after a
         * publish whose outcome is unknown).
         * tests/kernel/dir_grow_fail_keeps_block.sh.
         */
        if (S_ISDIR(inode->i_mode))
            pr_err("dir ino=%llu: growth failed after its tree may have named block %llu (%d) -- keeping it "
                   "allocated\n",
                   (unsigned long long) inode->i_ino, (unsigned long long) lba, ret);
        else
            cetrafs_free_data_block(sb, lba);
        return ret;
    }

    raw.blocks =
        cetrafs_cpu_to_le64(cetrafs_le64(raw.blocks) + (CETRAFS_BLOCK_SIZE / 512)); /* the newly allocated data block */

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
        if (ret) {
            /* Same as above: the leaf (depth 1) is already on the device
             * or in the journal naming 'lba', and a failed record write's
             * own outcome is unknown. Keep the block. */
            pr_err("dir ino=%llu: record write failed after its tree named block %llu (%d) -- keeping it "
                   "allocated\n",
                   (unsigned long long) inode->i_ino, (unsigned long long) lba, ret);
            return ret;
        }
    } else {
        cetrafs_inode_fd_stage(inode, &raw);
        mark_inode_dirty(inode);
    }

    inode->i_blocks = cetrafs_le64(raw.blocks);
    ctrace("MAP ino=%llu lblk=%llu lba=%llu merged=%d\n", (unsigned long long) inode->i_ino,
           (unsigned long long) iblock, (unsigned long long) lba, (int) merged);
    map_bh(bh_result, sb, lba);
    set_buffer_new(bh_result);
    if (dio_prealloc)
        cetrafs_dio_mark_convert(bh_result);

    /* A growing OPEN regular file that just added a NEW extent (not a
     * merge) to its external tree is the moment fragmentation happens;
     * nudge the background defragmenter so always-open files (VM images)
     * get healed in flight, not only at close. The frag-index gate is in
     * consider(); it recomputes the exact index under lock. */
    if (!merged && leaf_count && S_ISREG(inode->i_mode) && !cetrafs_lock_defrag_quiet(inode))
        cetrafs_defrag_consider(inode, leaf_count, (u64) iblock + 1);

    return 0;
}

static int cetrafs_get_block(struct inode *inode, sector_t iblock, struct buffer_head *bh_result, int create)
{
    return __cetrafs_get_block(inode, iblock, bh_result, create, false, CETRAFS_GB_PLAIN);
}

/*
 * The get_block of the READ paths: read_folio, readahead and
 * blockdev_direct_IO's create == 0 lookups.
 *
 * create == 0 alone does not mean "read": block_truncate_page() maps
 * with it and then WRITES the block, which is why that path keeps
 * cetrafs_get_block(). Two of the callers here can write too -- a
 * shared writable mapping faults pages in through read_folio, and an
 * O_DIRECT write inside i_size maps with create == 0 (DIO_SKIP_HOLES)
 * -- but both need the file open for write on this node, and while it
 * is, cetrafs_lock_read_cache_trusted() gives exactly the write lock's
 * answer. Only a node with no writer gets the reader's cheaper one.
 */
static int cetrafs_get_block_read(struct inode *inode, sector_t iblock, struct buffer_head *bh_result, int create)
{
    if (WARN_ON_ONCE(create))
        return -EIO;
    return __cetrafs_get_block(inode, iblock, bh_result, 0, true, CETRAFS_GB_PLAIN);
}

static int cetrafs_read_folio(struct file *file, struct folio *folio)
{
    /* A stopped mount reads nothing (docs/internal/ERRORS.md). */
    if (cetrafs_sb_is_fenced(folio->mapping->host->i_sb)) {
        folio_unlock(folio);
        return -EIO;
    }
    return block_read_full_folio(folio, cetrafs_get_block_read);
}

/* Without it every page was read on its own, one 4 KiB bio at a time,
 * and a sequential reader could not get past one request in flight. */
static void cetrafs_readahead(struct readahead_control *rac)
{
    /* Stopped: read nothing ahead; whatever is then actually needed
     * comes through read_folio and fails there. */
    if (cetrafs_sb_is_fenced(rac->mapping->host->i_sb))
        return;
    mpage_readahead(rac, cetrafs_get_block_read);
}

/*
 * The body of .write_begin, for callers that ALREADY hold
 * mapping->invalidate_lock.
 *
 * invalidate_lock is not recursive, and cetrafs_zero_range() reaches
 * this from inside the punch path, which holds it for the whole
 * operation -- so routing that through the locking wrapper deadlocked
 * the caller against itself. Four fallocate(ZERO_RANGE) actors wedged
 * in D state, unkillable, taking the mount with them (churn_oracle.sh,
 * on the gate run of the commit that introduced it).
 *
 * The split is the fix and the documentation: a path that holds the
 * lock calls this, a path that does not calls cetrafs_write_begin().
 */
static int cetrafs_write_begin_held(struct address_space *mapping, loff_t pos, unsigned len, struct folio **foliop)
{
    if (cetrafs_sb_is_fenced(mapping->host->i_sb))
        return -EIO; /* self-fenced: no new dirty data */

    return block_write_begin(mapping, pos, len, foliop, cetrafs_get_block);
}

static int cetrafs_write_begin(const struct kiocb *iocb,
                               struct address_space *mapping,
                               loff_t pos,
                               unsigned len,
                               struct folio **foliop,
                               void **fsdata)
{
    int ret;

    /* An O_DIRECT write the DIO code could not take: it is finishing it
     * through the page cache, one synchronous flush per call. */
    if (iocb && (iocb->ki_flags & IOCB_DIRECT))
        atomic64_inc(&cetrafs_dio_fallbacks);

    /* block_write_begin() allocates through cetrafs_get_block(). The
     * caller holds inode_lock, which excludes the other write paths but
     * NOT a page fault -- see cetrafs_page_mkwrite(), which takes this
     * same lock for the same reason. Held across this call only: the
     * copy_from_user() that follows happens in the VFS, after we
     * return, and may itself fault. */
    filemap_invalidate_lock(mapping);
    ret = cetrafs_write_begin_held(mapping, pos, len, foliop);
    filemap_invalidate_unlock(mapping);
    return ret;
}

/*
 * Flush dirty page-cache pages to their already-allocated blocks. Without
 * this, dirtied pages from write_begin/write_end are never written back --
 * do_writepages() silently no-ops when .writepages is unset -- so data
 * would vanish on umount despite looking fine within the same mount.
 */
/*
 * Writeback maps with create=1 and holds neither inode_lock nor
 * invalidate_lock -- so it must never be the one that allocates or
 * converts: that would mutate the extent tree beside a fault or a write
 * that holds the lock (CLAUDE.md rules 17-18). It never should be:
 * write_begin and page_mkwrite allocate and convert every block of a
 * page, under invalidate_lock, before the page can be dirty. Asserted
 * here, not assumed. buffer_new() is set exactly when get_block
 * allocated or converted; refusing at that point would be worse than
 * going on (the block is already mapped, with undefined contents until
 * this write lands), so it is reported -- loudly, and as a WARN, which
 * fails every suite that reaches it.
 */
static int cetrafs_get_block_writeback(struct inode *inode, sector_t iblock, struct buffer_head *bh, int create)
{
    int ret = cetrafs_get_block(inode, iblock, bh, create);

    if (!ret && buffer_new(bh)) {
        pr_err_ratelimited("ino=%llu: writeback allocated/converted block %llu -- every block should be mapped "
                           "before its page is dirtied\n",
                           (unsigned long long) inode->i_ino, (unsigned long long) iblock);
        WARN_ON_ONCE(1);
    }
    return ret;
}

static int cetrafs_writepages(struct address_space *mapping, struct writeback_control *wbc)
{
    if (cetrafs_sb_is_fenced(mapping->host->i_sb))
        return -EIO; /* self-fenced: dirty data never reaches the device */

    return mpage_writepages(mapping, wbc, cetrafs_get_block_writeback);
}

/*
 * Shrink a regular file to 'new_size' (new_size < current i_size):
 * publish a record whose extent tree holds only the kept blocks, then
 * zero-fill the tail of the block still covering new_size, drop the page
 * cache past it, and only then free the dropped blocks -- the external
 * leaf block too if it ends up empty, reverting to depth-0. Growing a file needs none of this: holes
 * read as zero already via cetrafs_get_block(), so cetrafs_setattr() just
 * calls truncate_setsize() directly for that case.
 */
/*
 * TEST ONLY: fail the record write that publishes a truncate/punch, so
 * the unwind can be exercised. That write is what makes a freed
 * external extent leaf unreachable, and nothing a test can supply makes
 * it fail on its own.
 */
/*
 * TEST ONLY: hold the punch open after the page cache is dropped and
 * before the blocks behind it are freed.
 *
 * That gap is where a page fault must not be allowed to re-instantiate
 * a folio -- in production it is a tree build plus a synchronous record
 * write, so a real workload hits it; a test needs it held open to hit
 * it every time. See tests/kernel/mmap_vs_punch.sh.
 */
static unsigned int cetrafs_punch_pagecache_delay_ms;
module_param_named(punch_pagecache_delay_ms, cetrafs_punch_pagecache_delay_ms, uint, 0644);
MODULE_PARM_DESC(punch_pagecache_delay_ms, "TEST ONLY: pause inside punch between the page-cache drop and the free");

/* TEST ONLY: pause a punch or truncate just before (_pre) or just after
 * (_post) its last "is a peer using this file?" check before the
 * publish. tests/kernel/punch_peer_late.sh. */
static unsigned int cetrafs_rebuild_stall_pre_ms, cetrafs_rebuild_stall_post_ms;
module_param_named(rebuild_stall_pre_ms, cetrafs_rebuild_stall_pre_ms, uint, 0644);
MODULE_PARM_DESC(rebuild_stall_pre_ms, "TEST ONLY: pause a punch/truncate before its pre-publish peer check");
module_param_named(rebuild_stall_post_ms, cetrafs_rebuild_stall_post_ms, uint, 0644);
MODULE_PARM_DESC(rebuild_stall_post_ms, "TEST ONLY: pause a punch/truncate after its pre-publish peer check");

/*
 * Has a peer started using this file? The answer punch and truncate act
 * on (CLAUDE.md rule 15): they decide "nobody else has it open" at the
 * start, then build a whole new tree -- record reads, journalled leaf
 * writes, a bitmap flush, seconds on a large file -- and publish it
 * last-writer-wins and free what it dropped. A peer that opened in that
 * gap, under nofilelock, had its new extents published over and its
 * blocks freed. Asked again right before the publish (refuse) and right
 * after it (free nothing). The two checks are not one atomic act with
 * the publish -- presence lives in the other sector of the record -- so
 * the second one is what makes a peer arriving between them safe: what
 * it may still name is left allocated, a leak the scrub reclaims once
 * nothing names it. An error asking counts as yes.
 */
static bool cetrafs_rebuild_peer_present(struct inode *inode)
{
    struct super_block *sb = inode->i_sb;
    bool blocked = false, reader = false;
    u32 my_node_id;

    if (cetrafs_sb_get_node_id(sb, &my_node_id) ||
        cetrafs_lock_foreign_user_exists(sb, inode->i_ino, my_node_id, &blocked, &reader))
        return true;
    return blocked || reader;
}

/* The pre-publish half: -ETXTBSY if a peer has arrived since the start. */
static int cetrafs_rebuild_recheck(struct inode *inode, const char *what)
{
    if (cetrafs_rebuild_stall_pre_ms)
        msleep(cetrafs_rebuild_stall_pre_ms); /* TEST ONLY */
    if (cetrafs_rebuild_peer_present(inode)) {
        pr_warn_ratelimited("%s: ino=%llu was opened on another node meanwhile -- refusing\n", what,
                            (unsigned long long) inode->i_ino);
        return -ETXTBSY;
    }
    if (cetrafs_rebuild_stall_post_ms)
        msleep(cetrafs_rebuild_stall_post_ms); /* TEST ONLY */
    return 0;
}

static bool cetrafs_fail_extent_record_write;
module_param_named(fail_extent_record_write, cetrafs_fail_extent_record_write, bool, 0644);
MODULE_PARM_DESC(fail_extent_record_write, "TEST ONLY: fail the record write in truncate/punch-hole");

static int __cetrafs_truncate_shrink(struct inode *inode, loff_t new_size)
{
    /* Extents are about to go away under us. */
    cetrafs_inode_ext_cache_drop(inode);

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
    int ret, zret;

    recs = kmalloc(2 * sizeof(*recs), GFP_NOFS);
    if (!recs)
        return -ENOMEM;

    /*
     * Forced fresh, not cached. This runs under the inode's namespace
     * lock, and the extent list read here decides which physical blocks
     * get FREED -- truncate(2) is path-based (no exclusive lock), so a
     * peer that truncated the same file moments earlier (serialised by
     * the same namespace lock) may have changed the tree, and freeing
     * from a pre-peer list double-frees. CLAUDE.md rule 1.
     */
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode_overlaid(sb, inode, &raw); /* torn-read-safe vs a concurrent publish */
    if (ret) {
        kfree(recs);
        return ret;
    }
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
    old_flat = kvmalloc_array(old_n + 2, sizeof(*old_flat), GFP_NOFS);
    if (!old_flat) {
        cetrafs_inode_extents_put(&ex);
        kfree(recs); /* 2 KiB, leaked on this path and the next one */
        return -ENOMEM;
    }
    if (old_n)
        memcpy(old_flat, ex.arr, (size_t) old_n * sizeof(*old_flat));
    cetrafs_inode_extents_put(&ex);

    /* Trim a COPY to the kept set. */
    new_flat = kvmalloc_array(old_n ? old_n : 1, sizeof(*new_flat), GFP_NOFS);
    if (!new_flat) {
        kvfree(old_flat);
        kfree(recs);
        return -ENOMEM;
    }
    if (old_n)
        memcpy(new_flat, old_flat, (size_t) old_n * sizeof(*new_flat));
    kept = cetrafs_leaf_array_trim(sb, new_flat, old_n, new_block_count, &freed_dummy, /*do_free=*/false);

    /* Build a FRESH tree for the kept set, into raw's et/eh. The old
     * tree is still fully intact on disk until we publish below. */
    ret = cetrafs_tree_build(inode, new_flat, kept, &raw, &meta_blocks);
    if (ret) {
        kvfree(new_flat);
        kvfree(old_flat);
        kfree(recs);
        return ret;
    }

    raw.size = cetrafs_cpu_to_le64(new_size);
    raw.blocks =
        cetrafs_cpu_to_le64((cetrafs_flat_data_blocks(new_flat, kept) + meta_blocks) * (CETRAFS_BLOCK_SIZE / 512));

    /* The injection stands IN PLACE OF the write: a record that never
     * reached the device. On failure, free the NEW tree we just built
     * (the old one is still the durable truth) and bail. */
    ret = cetrafs_rebuild_recheck(inode, "truncate");
    if (!ret) {
        u64 fd_seq;

        cetrafs_inode_fd_pub_lock(inode);
        /* Times from the LIVE inode under the publish mutex, never from
         * the image this operation read earlier (the defrag step publish
         * has the same rule). The size is the one being set: the in-core
         * size moves to it under the same mutex, only once the record
         * says so -- a failed write leaves both where they were, and no
         * other publish can slip the old size in between. */
        raw.size = cetrafs_cpu_to_le64((u64) new_size);
        raw.atime = cetrafs_cpu_to_le64((u64) inode_get_atime_sec(inode));
        raw.mtime = cetrafs_cpu_to_le64((u64) inode_get_mtime_sec(inode));
        fd_seq = cetrafs_inode_fd_seq(inode);
        ret = unlikely(cetrafs_fail_extent_record_write) ? -EIO
                                                         : cetrafs_write_raw_inode_fd(sb, inode->i_ino, &raw, inode);
        if (!ret) {
            cetrafs_inode_fd_published(inode, fd_seq); /* this publish supersedes the overlaid shadow */
            i_size_write(inode, new_size);
        }
        cetrafs_inode_fd_pub_unlock(inode);
    }
    if (ret) {
        cetrafs_tree_free_meta(inode, &raw);
        kvfree(new_flat);
        kvfree(old_flat);
        kfree(recs);
        return ret;
    }

    /*
     * Published, and i_size already says so. The tail of the block at the
     * new end is zeroed (its folio was read before the publish, so this
     * does no I/O), and the page cache past it goes before any of its
     * blocks do -- ext2's order. A failure to zero comes back as the
     * error, but the truncate itself is done and durable: stopping here
     * would leak the dropped blocks without making the tail any better.
     */
    zret = block_truncate_page(inode->i_mapping, new_size, cetrafs_get_block);
    if (zret)
        pr_warn_ratelimited("cetrafs: inode %llu: truncated to %lld but its tail was not zeroed (%d)\n",
                            (unsigned long long) inode->i_ino, (long long) new_size, zret);
    truncate_pagecache(inode, new_size);

    /*
     * Only now does anything go back to the allocator: the OLD
     * tree's meta blocks (leaves + interiors), then the dropped DATA
     * blocks (a do_free pass over the old flat array). New and old meta
     * are disjoint -- the new tree was allocated while the old was still
     * referenced -- and the kept data blocks appear in both trees, so
     * freeing the old meta and the dropped data never touches a block the
     * new tree still names. A crash after publish but before freeing is a
     * leaked block fsck names -- the trade made everywhere here.
     */
    if (cetrafs_rebuild_peer_present(inode)) {
        /* A peer arrived after the last check: it may hold the old tree.
         * Free nothing it might still name (cetrafs_rebuild_recheck()). */
        pr_warn("truncate: ino=%llu was opened on another node during the publish -- leaving the dropped blocks "
                "allocated for the scrub\n",
                (unsigned long long) inode->i_ino);
    } else {
        cetrafs_tree_free_meta(inode, &old_raw);
        cetrafs_leaf_array_trim(sb, old_flat, old_n, new_block_count, &discard, /*do_free=*/true);
    }

    kvfree(new_flat);
    kvfree(old_flat);
    inode->i_blocks = cetrafs_le64(raw.blocks);
    kfree(recs);
    return zret;
#undef raw
#undef old_raw
}

static int cetrafs_truncate_shrink(struct inode *inode, loff_t new_size)
{
    struct folio *tail = NULL;
    int ret;

    /*
     * Direct I/O already in flight against this inode was drained by the
     * caller, before invalidate_lock (cetrafs_setattr_locked()): O_DIRECT
     * bypasses the page cache, so inode_lock does not exclude an
     * already-submitted DIO whose bio is aimed at a physical block this
     * is about to hand back. Waiting here, under invalidate_lock, is the
     * deadlock against cetrafs_dio_end_io(). (ext4 drains in
     * ext4_setattr() too.)
     */
    lockdep_assert_held(&inode->i_rwsem);

    /*
     * Nothing in core changes before the record write below succeeds:
     * not the size, not the page cache, not the tail of the block at the
     * new end. They used to change first, and a failed write put none of
     * them back -- the dropped dirty pages were simply gone, and ordinary
     * writeback then made the zeroed tail and the smaller size durable
     * over extents that still held every block. A truncate that returned
     * an error had truncated anyway (tests/kernel/truncate_fail_keeps_data.sh).
     *
     * Two things make the late page-cache drop safe. Dirty pages past
     * the new end are written back first: once the trimmed tree is
     * published, writeback of such a page would map it through a tree
     * that no longer has its block and ALLOCATE one. And nothing can
     * dirty them again meanwhile -- write(2) is excluded by inode_lock
     * and a fault by invalidate_lock, which the caller holds
     * exclusively and cetrafs_page_mkwrite() needs.
     *
     * The folio at the new end is read now, while failing is still
     * free, so block_truncate_page() after the publish finds it
     * uptodate and mapped and does no I/O of its own.
     */
    ret = filemap_write_and_wait_range(inode->i_mapping, new_size, LLONG_MAX);
    if (ret)
        return ret;
    if (new_size & (CETRAFS_BLOCK_SIZE - 1)) {
        tail = read_mapping_folio(inode->i_mapping, (pgoff_t) (new_size >> PAGE_SHIFT), NULL);
        if (IS_ERR(tail))
            return PTR_ERR(tail);
    }

    ret = __cetrafs_truncate_shrink(inode, new_size);
    if (tail)
        folio_put(tail);
    return ret;
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
    void *fsdata = NULL; /* block_write_begin() sets none; generic_write_end() ignores it here */
    int ret;

    if (!len)
        return 0;

    /* A hole, or a block fallocate reserved and nobody wrote, already
     * reads as zeroes, so there is nothing to zero -- and going through
     * write_begin ALLOCATED (or converted) it to write zeroes into it:
     * a punch, which only gives space back, failing with ENOSPC on a
     * full volume (a TRIM from a guest, say). Same create=0 answer the
     * read path serves; the caller holds invalidate_lock, so it cannot
     * change underneath. */
    {
        struct inode *inode = mapping->host;
        struct buffer_head probe = {.b_size = i_blocksize(inode)};

        ret = cetrafs_get_block_read(inode, from >> inode->i_blkbits, &probe, 0);
        if (ret)
            return ret;
        if (!buffer_mapped(&probe))
            return 0;
    }

    ret = cetrafs_write_begin_held(mapping, from, len, &folio); /* the punch holds invalidate_lock */
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
/*
 * Test-only: slow the per-block allocation loop down.
 *
 * Killability cannot be tested by asking for a huge range: the loop
 * ends at ENOSPC, which on any image a test can afford arrives in well
 * under a second. This makes the loop long without making the device
 * big, so a SIGKILL has something to land in.
 */
static unsigned int cetrafs_fallocate_block_delay_us;
module_param_named(fallocate_block_delay_us, cetrafs_fallocate_block_delay_us, uint, 0644);
MODULE_PARM_DESC(fallocate_block_delay_us, "TEST ONLY: microseconds to spend per preallocated block");

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

    /*
     * The format's ceiling is not the only one. Without KEEP_SIZE this
     * grows i_size, so it is a size change and RLIMIT_FSIZE applies --
     * inode_newsize_ok() is what enforces it (and raises SIGXFSZ), and
     * it was simply never asked. A process under a 1 MiB file-size
     * limit could preallocate terabytes.
     */
    if (!keep_size) {
        ret = inode_newsize_ok(inode, end);
        if (ret)
            return ret;
    }

    /* The record this whole call appends to and then publishes: fresh
     * unless the cache is provably this node's, the gate get_block()
     * and truncate apply (CLAUDE.md rule 1). */
    if (!cetrafs_lock_held_for_write_locally(inode))
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode_overlaid(sb, inode, &raw); /* torn-read-safe vs a concurrent publish */
    if (ret)
        return ret;
    if (cetrafs_le16(raw.eh.eh_magic) != CETRAFS_EXT_MAGIC)
        return -EIO;

    for (b = start_block; b < end_block; b++) {
        bool found = false, un = false;
        u32 bg_id;
        u64 lba;
        bool merged;

        /*
         * One block per iteration, up to CETRAFS_MAX_FILE_BLOCKS of
         * them, under inode_lock -- a 16 TiB request is billions of
         * passes. Without these two lines it could neither be
         * scheduled away from nor killed: fallocate(2) on a large
         * range became an uninterruptible occupation of the CPU and
         * the inode.
         *
         * Stopping early leaves the range PARTIALLY preallocated,
         * which is allowed and is what the other filesystems do: the
         * blocks already added are real, recorded and freeable. Losing
         * them silently would be the worse answer.
         */
        if (fatal_signal_pending(current)) {
            ret = -EINTR;
            goto out;
        }
        cond_resched();
        if (cetrafs_fallocate_block_delay_us)
            usleep_range(cetrafs_fallocate_block_delay_us, cetrafs_fallocate_block_delay_us * 2);
        u32 leaf_count;

        ret = cetrafs_tree_lookup(inode, &raw, (u32) b, &lba, NULL, &un, &found, false);
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
        if (ret == -ENOSPC || ret == -EAGAIN) /* count lying, or group released since the pick -- see the helper */
            ret = cetrafs_alloc_block_anywhere(sb, &bg_id, &lba);
        if (ret)
            goto out;

        ret = cetrafs_tree_append(inode, &raw, (u32) b, lba, 1, /*uninit=*/true, &merged, &leaf_count);
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

    cetrafs_inode_fd_pub_lock(inode);
    {
        u64 fd_seq = cetrafs_inode_fd_seq(inode);

        ret = cetrafs_write_raw_inode_fd(sb, inode->i_ino, &raw, inode);
        if (!ret)
            cetrafs_inode_fd_published(inode, fd_seq); /* this publish supersedes the overlaid shadow */
    }
    cetrafs_inode_fd_pub_unlock(inode);
    if (ret)
        goto out;

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
    if (added) {
        u64 fd_seq;

        cetrafs_inode_fd_pub_lock(inode);
        fd_seq = cetrafs_inode_fd_seq(inode);
        if (cetrafs_write_raw_inode_fd(sb, inode->i_ino, &raw, inode) == 0)
            cetrafs_inode_fd_published(inode, fd_seq);
        cetrafs_inode_fd_pub_unlock(inode);
    }
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
    u32 new_n = 0;
    u64 meta_blocks = 0;
    u32 freed = 0, discard = 0;
    bool published = false; /* the map changed: the tail of the punch updates blocks/ctime */
    int ret;

    recs = kmalloc(2 * sizeof(*recs), GFP_NOFS);
    if (!recs)
        return -ENOMEM;

    /* Punch frees extents and ALLOCATE creates preallocated ones; both
     * rewrite the map under whatever a walk last resolved. */
    cetrafs_inode_ext_cache_drop(inode);

    if (offset < 0 || len <= 0) {
        kfree(recs);
        return -EINVAL;
    }

    /* ALLOCATE: mode 0, or KEEP_SIZE alone. */
    if (mode == 0 || mode == FALLOC_FL_KEEP_SIZE) {
        long arc;

        inode_lock(inode);
        /*
         * Preallocation appends extents over what are holes right now,
         * and a write fault allocating the same offset would append a
         * second extent for it.
         *
         * HELD FOR THE WHOLE CALL, and that is the long one: a 1 GiB
         * preallocation walks block by block and has been measured at
         * 11 seconds, during which a page fault on this file waits.
         * inode_lock already blocked write(2) for that long; this
         * extends the wait to faults.
         *
         * Shortening it is not free. cetrafs_do_allocate() reads the
         * record ONCE and appends to that copy for the whole loop, so
         * releasing the lock part way means appending from a stale
         * image while a fault mutates the real one -- the exact lost
         * update this lock exists to prevent. A bounded hold would
         * require re-reading the record at every release, which puts a
         * record read back on a per-chunk path (docs/PERFORMANCE.md,
         * invariant 2). Worth doing with a chunk size large enough to
         * pay for it; not worth doing by simply moving the lock.
         */
        filemap_invalidate_lock(inode->i_mapping);
        arc = cetrafs_sb_is_fenced(sb) ? -EIO : cetrafs_lock_write_gate(inode);
        /*
         * The third operation with truncate's and punch's hazard (rule
         * 16): preallocation rewrites the extent map and publishes the
         * whole file sector, last writer wins, so under nofilelock a peer
         * writing the file meanwhile has its new extents published over.
         * Same refusal, same reason: a peer with the file open is
         * -ETXTBSY (tests/kernel/fallocate_foreign_open.sh).
         */
        if (!arc) {
            u32 my_node_id;
            bool blocked = false, reader = false;

            arc = cetrafs_sb_get_node_id(sb, &my_node_id);
            if (!arc)
                arc = cetrafs_lock_foreign_user_exists(sb, inode->i_ino, my_node_id, &blocked, &reader);
            if (!arc && (blocked || reader)) {
                pr_warn_ratelimited("fallocate: ino=%llu is open on another node -- refusing to rewrite its map\n",
                                    (unsigned long long) inode->i_ino);
                arc = -ETXTBSY;
            }
        }
        if (!arc)
            arc = cetrafs_do_allocate(inode, offset, len, mode & FALLOC_FL_KEEP_SIZE);
        filemap_invalidate_unlock(inode->i_mapping);
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
     * and in-flight direct I/O is aimed at the physical ones. Drained
     * BEFORE invalidate_lock: an O_DIRECT write's completion takes it to
     * convert what it wrote (cetrafs_dio_end_io()), so waiting for that
     * completion while holding it deadlocks. inode_lock, held from here
     * on, keeps a new direct write from starting after the drain. */
    inode_dio_wait(inode);
    /* And the same reason again for page faults, which hold no
     * inode_lock at all: this excludes them from the window between
     * dropping the cached folios below and freeing the blocks behind
     * them. Taken for the whole call, including the no-op fast path --
     * an uncontended rwsem is nothing next to the tree walk that
     * follows, and one exit point cannot forget to drop it. */
    filemap_invalidate_lock(inode->i_mapping);

    /* A punch changes the file: not while it is handed to a peer. */
    ret = cetrafs_lock_write_gate(inode);
    if (ret)
        goto out;

    /*
     * And the same refusal truncate gives, for the same reason -- which
     * cetrafs_setattr()'s own comment already states about BOTH of
     * them: "a truncate/punch landing under [a peer's open file] both
     * frees blocks the writer is still extending into and gets its
     * extent removal reverted by the writer's eventual flush, leaving
     * extents that reference FREE blocks."
     *
     * The reasoning covered punch; the guard was only ever added to
     * truncate. Under `nofilelock` -- the mount mode a VM datastore
     * actually runs in -- no exclusive claim exists for the claim check
     * to see, so a peer writing an image while this node punches a hole
     * in it was simply allowed.
     *
     * A peer with the file merely open is the same -ETXTBSY unlink
     * gives. Punching a hole in a file another host is writing is not a
     * meaningful operation on this workload.
     */
    {
        u32 my_node_id;

        ret = cetrafs_sb_get_node_id(sb, &my_node_id);
        if (ret)
            goto out;
        {
            bool blocked = false, reader = false;

            ret = cetrafs_lock_foreign_user_exists(sb, inode->i_ino, my_node_id, &blocked, &reader);
            if (ret)
                goto out;
            if (blocked || reader) {
                pr_warn_ratelimited("punch: ino=%llu is open on another node -- refusing to free its blocks\n",
                                    (unsigned long long) inode->i_ino);
                ret = -ETXTBSY;
                goto out;
            }
        }
    }

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
        /*
         * No WHOLE block lies inside [offset, end), so nothing is freed
         * here -- the general boundary handling below assumes the two
         * boundaries are in *different* blocks, which does not hold.
         *
         * But "covers no whole block" is NOT "lies within one block",
         * and conflating the two was a kernel BUG reachable by any user
         * with write access to a file: punching [PAGE_SIZE-1, +2)
         * straddles a block boundary while covering no whole block, and
         * the single zeroing below then handed block_write_begin() a
         * range crossing the end of the folio it was given --
         * `BUG_ON(to > folio_size)`, fs/buffer.c.
         *
         * Zeroing goes through the ordinary write path, which is given
         * one folio at a time, so every range handed to it must stay
         * inside one block. Split on the boundary. The two blocks are
         * adjacent by construction: a gap of two would put a whole
         * block inside the hole and we would not be here.
         */
        u64 first_block = (u64) offset / CETRAFS_BLOCK_SIZE;
        u64 last_block = (u64) (end - 1) / CETRAFS_BLOCK_SIZE;

        if (first_block == last_block) {
            ret = cetrafs_zero_range(inode->i_mapping, offset, (size_t) (end - offset));
        } else {
            loff_t split = (loff_t) last_block * CETRAFS_BLOCK_SIZE;

            ret = cetrafs_zero_range(inode->i_mapping, offset, (size_t) (split - offset));
            if (!ret)
                ret = cetrafs_zero_range(inode->i_mapping, split, (size_t) (end - split));
        }
        goto out;
    }

    /*
     * Nothing in core changes before the record is published: the same
     * order as truncate (cetrafs_truncate_shrink()). The page-cache drop
     * and the boundary zeroing used to come first, so a punch whose
     * record write failed had already thrown away dirty data inside the
     * hole -- the blocks stayed mapped and read back their older on-disk
     * contents, neither the data nor the zeroes -- and zeroed the
     * boundary halves through the ordinary write path, where writeback
     * made them durable. A failed punch must leave the file as it was.
     *
     * So write the range back first (ext4 does the same before a punch):
     * the dirty data then is the on-disk data, and a failure leaves the
     * file exactly as the caller last wrote it. Free when the range is
     * clean, which is what a discard over a sparse image mostly is.
     */
    ret = filemap_write_and_wait_range(inode->i_mapping, offset, end - 1);
    if (ret)
        goto out;

    ret = cetrafs_read_raw_inode_overlaid(sb, inode, &raw); /* torn-read-safe vs a concurrent publish */
    if (ret)
        goto out;
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
    old_flat = kvmalloc_array(old_n + 2, sizeof(*old_flat), GFP_NOFS);
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
    new_flat = kvmalloc_array(new_cap, sizeof(*new_flat), GFP_NOFS);
    if (!new_flat) {
        kvfree(old_flat);
        ret = -ENOMEM;
        goto out;
    }
    if (old_n)
        memcpy(new_flat, old_flat, (size_t) old_n * sizeof(*new_flat));
    new_n = old_n;
    ret = cetrafs_leaf_array_punch(sb, new_flat, &new_n, new_cap, start_block, end_block, &freed,
                                   /*do_free=*/false);
    if (ret) {
        kvfree(new_flat);
        kvfree(old_flat);
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
     *
     * Nothing to PUBLISH is not nothing to DO: the boundary blocks
     * partly inside the range still hold data that must read as zeros,
     * and the map says nothing about them. Skipping their zeroing here
     * left a hole reading back an older write
     * (tests/kernel/punch_noop_zeroes_boundary.sh).
     */
    if (freed == 0 && new_n == old_n &&
        (old_n == 0 || !memcmp(new_flat, old_flat, (size_t) old_n * sizeof(*new_flat)))) {
        kvfree(new_flat);
        kvfree(old_flat);
        ret = 0;
        goto zero_boundaries;
    }

    /* Build the fresh tree; the old one stays intact until we publish. */
    ret = cetrafs_tree_build(inode, new_flat, new_n, &raw, &meta_blocks);
    if (ret) {
        kvfree(new_flat);
        kvfree(old_flat);
        goto out;
    }

    raw.blocks =
        cetrafs_cpu_to_le64((cetrafs_flat_data_blocks(new_flat, new_n) + meta_blocks) * (CETRAFS_BLOCK_SIZE / 512));

    ret = cetrafs_rebuild_recheck(inode, "punch");
    if (!ret) {
        u64 fd_seq;

        cetrafs_inode_fd_pub_lock(inode);
        fd_seq = cetrafs_inode_fd_seq(inode);
        ret = unlikely(cetrafs_fail_extent_record_write) ? -EIO
                                                         : cetrafs_write_raw_inode_fd(sb, inode->i_ino, &raw, inode);
        if (!ret)
            cetrafs_inode_fd_published(inode, fd_seq); /* this publish supersedes the overlaid shadow */
        cetrafs_inode_fd_pub_unlock(inode);
    }
    if (ret) {
        cetrafs_tree_free_meta(inode, &raw);
        kvfree(new_flat);
        kvfree(old_flat);
        goto out;
    }

    /* Published. Only now drop the cached folios over the hole: the
     * blocks behind them are about to be freed, and a stale cached copy
     * would let a later read return old data instead of the zero a hole
     * must read as. Still before the free, and invalidate_lock (held
     * for the whole call) keeps a fault from re-instantiating one in
     * between. This also zeroes the cached halves of the boundary
     * blocks. Deliberately after the no-op check above -- evicting a
     * live file's page cache on every no-op punch is both pointless and
     * a throughput loss in its own right. */
    truncate_pagecache_range(inode, offset, end - 1);

    if (cetrafs_punch_pagecache_delay_ms)
        msleep(cetrafs_punch_pagecache_delay_ms); /* test-only; see the parameter */

    /* Free the OLD tree's meta, then the punched DATA blocks (a do_free
     * pass over the old flat array) -- same two-pass, publish-before-free
     * shape as cetrafs_truncate_shrink(). */
    if (cetrafs_rebuild_peer_present(inode)) {
        /* As in truncate: a peer arrived after the last check. */
        pr_warn("punch: ino=%llu was opened on another node during the publish -- leaving the punched blocks "
                "allocated for the scrub\n",
                (unsigned long long) inode->i_ino);
    } else {
        u32 discard_entries = old_n;
        int fret;

        cetrafs_tree_free_meta(inode, &old_raw);
        fret = cetrafs_leaf_array_punch(sb, old_flat, &discard_entries, old_n + 2, start_block, end_block, &discard,
                                            /*do_free=*/true);
        if (fret)
            pr_err("punch: freeing the old blocks failed (%d) -- %u block(s) may have leaked\n", fret, freed);
    }
    kvfree(new_flat);
    kvfree(old_flat);
    published = true;

zero_boundaries:
    /* Boundary blocks only partly inside [offset, end) keep the data
     * outside the hole: zero just the in-hole half of each (the tail of
     * offset's block, the head of end's block), through the ordinary
     * write path so the zeroes reach the device. After the publish, so a
     * failed punch never got here -- and also after a punch that had no
     * whole block to free, which still owes these zeroes. */
    if (offset & (CETRAFS_BLOCK_SIZE - 1)) {
        loff_t block_end = (loff_t) start_block * CETRAFS_BLOCK_SIZE;

        ret = cetrafs_zero_range(inode->i_mapping, offset, (size_t) (block_end - offset));
    }
    if (!ret && (end & (CETRAFS_BLOCK_SIZE - 1))) {
        loff_t block_start = (loff_t) end_block * CETRAFS_BLOCK_SIZE;

        ret = cetrafs_zero_range(inode->i_mapping, block_start, (size_t) (end - block_start));
    }
    if (!published)
        goto out; /* the map did not change: nothing below applies */

    inode->i_blocks = cetrafs_le64(raw.blocks);
    inode_set_ctime(inode, ktime_get_real_seconds(), 0);
    mark_inode_dirty(inode);
    /* The direct write persists it; the VFS call then clears the dirty
     * state so the inode can still accept cross-node refreshes. Both
     * halves are needed -- see cetrafs_setattr_locked()'s comment. */
    {
        int wret = cetrafs_write_vfs_inode(inode);

        if (!wret)
            wret = sync_inode_metadata(inode, 1);
        if (!ret)
            ret = wret;
    }

out:
    filemap_invalidate_unlock(inode->i_mapping);
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
        /* Shrinking frees blocks whose folios a concurrent fault would
         * otherwise re-instantiate; growing changes the map a fault may
         * be allocating into. Both exclude faults -- see
         * cetrafs_page_mkwrite(), which takes this EXCLUSIVELY. Shared
         * would exclude these two and not another fault, and two
         * faults allocating at once is the lost update that cost 56
         * blocks of a writer's data.
         *
         * A shrink first drains direct I/O, and must do it HERE, before
         * invalidate_lock: an O_DIRECT write's completion takes that
         * lock to convert what it wrote (cetrafs_dio_end_io()) before
         * its in-flight count drops, so waiting for it under the lock
         * hangs both sides uninterruptibly
         * (tests/kernel/dio_truncate_drain.sh). inode_lock, held by the
         * VFS, keeps a new direct write from starting after the drain. */
        if (attr->ia_size < i_size_read(inode))
            inode_dio_wait(inode);
        filemap_invalidate_lock(inode->i_mapping);
        /* Under inode_lock (the VFS holds it here): not while this node
         * has handed the file to a peer -- cetrafs_lock_write_gate(). */
        ret = cetrafs_lock_write_gate(inode);
        if (!ret) {
            if (attr->ia_size < i_size_read(inode))
                ret = cetrafs_truncate_shrink(inode, attr->ia_size);
            else
                truncate_setsize(inode, attr->ia_size);
        }
        filemap_invalidate_unlock(inode->i_mapping);

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
            ret = cetrafs_sync_buffer(sb, bh);
        brelse(bh);
    }
    return ret;
}

/* Flush every dirty leaf (depth 1) or leaf+interior (depth 2) block of a
 * file's extent tree. */
/*
 * Test-only: the next extent-tree flush fails, as a device write error
 * on a leaf would.
 */
static bool cetrafs_tree_flush_fail_once;
module_param_named(tree_flush_fail_once, cetrafs_tree_flush_fail_once, bool, 0644);
MODULE_PARM_DESC(tree_flush_fail_once, "TEST ONLY: the next extent-tree block flush fails with -EIO");

int cetrafs_flush_tree_blocks(struct inode *inode, const cetrafs_inode_t *raw)
{
    struct super_block *sb = inode->i_sb;
    int ret = 0, r;
    u32 ni;

    if (cetrafs_tree_flush_fail_once) {
        cetrafs_tree_flush_fail_once = false;
        return -EIO; /* test-only, see the knob */
    }

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
        } else if (!ret) {
            /* Its leaves cannot be found, so they cannot be flushed:
             * say so, or the caller publishes a record over leaves that
             * may never have reached the device. */
            ret = -EIO;
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

    /* Torn-read-safe vs a concurrent publish. A record that cannot be
     * read names leaves that cannot be flushed: an error, not a skip. */
    ret2 = cetrafs_read_raw_inode_overlaid(sb, inode, &raw);
    if (!ret2 && cetrafs_le16(raw.eh.eh_magic) == CETRAFS_EXT_MAGIC && cetrafs_le16(raw.eh.eh_depth) >= 1)
        ret2 = cetrafs_flush_tree_blocks(inode, &raw);
    if (ret2 && !ret)
        ret = ret2;

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
    int ret = cetrafs_read_gate(inode->i_sb);

    if (ret)
        return ret;
    ret = generic_file_open(inode, file);

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

    /*
     * An ioctl that writes has to ask the MOUNT for permission, not
     * just the file: FMODE_WRITE says this descriptor was opened for
     * writing, and says nothing about the mount still being writable
     * now. Every other write path here goes through the VFS, which
     * takes this for them; an ioctl is on its own.
     */
    ret = mnt_want_write_file(file);
    if (ret)
        return ret;

    /*
     * And the flags that mean "do not touch this file". Relocation does
     * not change a byte of content, but it rewrites the inode record
     * and moves every block -- which is exactly what an immutable or
     * append-only file is promised will not happen to it.
     *
     * NOT TESTED, and said plainly rather than left to look covered:
     * cetrafs implements no FS_IOC_SETFLAGS, so neither flag can be set
     * on one of its inodes from userspace at all, and nothing in the
     * harness can reach this branch. It is here because the day the
     * flag becomes settable is not the day anybody will remember to
     * come back for it.
     */
    if (IS_IMMUTABLE(inode) || IS_APPEND(inode)) {
        ret = -EPERM;
        goto out_drop_write;
    }

    /* Turned off for this mount: refuse rather than silently doing
     * nothing, so an operator who disabled it and then ran
     * defrag.cetra is told why. This is the gate that makes "nothing on
     * this mount pins a file's exclusive lock for an optimisation" true
     * -- the janitor's own switch leaves this path open. */
    if (!cetrafs_sb_defrag_enabled(inode->i_sb)) {
        ret = -EOPNOTSUPP;
        goto out_drop_write;
    }

    /* Pin this node's exclusive lock for the pass (the caller's own
     * write-open already holds it, so this just marks it pinned and
     * defers its eventual release until the move finishes), then run the
     * same incremental mover the background path uses. */
    ret = cetrafs_lock_defrag_begin(inode);
    if (ret)
        goto out_drop_write;
    ret = cetrafs_defrag_inode(inode, &stats);
    cetrafs_lock_defrag_end(inode);

    if (ret == 0 && uarg && copy_to_user(uarg, &stats, sizeof(stats)))
        ret = -EFAULT;

out_drop_write:
    mnt_drop_write_file(file);
    return ret;
}

static long cetrafs_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    switch (cmd) {
    case CETRAFS_IOC_DEFRAG:
        return cetrafs_defrag_ioctl(file, (struct cetrafs_defrag_stats __user *) arg);
    case FS_IOC_SHUTDOWN:
        return cetrafs_shutdown_ioctl(file_inode(file)->i_sb, (u32 __user *) arg);
    default:
        return -ENOTTY;
    }
}
