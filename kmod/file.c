// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/delay.h>
#include <linux/falloc.h>
#include <linux/fiemap.h>
#include <linux/bsearch.h>
#include <linux/sort.h>
#include <linux/fs.h>
#include <linux/highmem.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/minmax.h>
#include <linux/mpage.h>
#include <linux/writeback.h>
#include <linux/pagemap.h>
/* struct folio_batch moved out of pagevec.h (7.1); build against either,
 * as ioutil.c does. A version test, not __has_include(): sparse cannot
 * parse that, falls through to pagevec.h, and endian-check stops. */
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)
#include <linux/folio_batch.h>
#else
#include <linux/pagevec.h>
#endif
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
/* The convert would have to append through the tree, and the caller has
 * not reserved the blocks for that yet (cetrafs_tree_resv_fill()): nothing
 * was modified. Internal, like CETRAFS_CONVERT_APPEND. */
#define CETRAFS_CONVERT_NEED_ROOM 2

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
/*
 * BUF is a BUFFERED write into a regular file (write_begin, page_mkwrite,
 * and the partial-block zeroing that goes through them), and it is DIO's
 * rule for the same reason. The data sits in this file's page cache; the
 * extent edit sits in a block-device buffer (a leaf) or the record's
 * shadow -- two address spaces, two writeback queues, no order between
 * them. Mapped as written data, a block could have its extent durable
 * first, and a crash in between left a file reading its previous owner's
 * bytes (audit R12). So BUF maps a preallocated block as it is and
 * allocates a hole PREALLOCATED, exactly as DIO does, and adds the block
 * to the inode's pending set (cetrafs_pending_add()); every lookup on
 * this node maps a pending block as data, so the writer reads what it
 * wrote. CONVERT_PENDING marks the set written at the durability
 * boundaries -- fsync, close, sync -- after its data is on the device
 * (cetrafs_convert_pending_locked()); unlike CONVERT it accepts a hole,
 * which a racing punch cannot leave behind but costs nothing to allow.
 */
enum cetrafs_gb_mode {
    CETRAFS_GB_PLAIN = 0,
    CETRAFS_GB_DIO,
    CETRAFS_GB_CONVERT,
    CETRAFS_GB_BUF,
    CETRAFS_GB_CONVERT_PENDING,
    /*
     * OVERWRITE is an O_DIRECT write under the SHARED inode_lock
     * (cetrafs_dio_overwrite_write()). It maps a WRITTEN block and
     * nothing else: it converts nothing and allocates nothing, because
     * no exclusive lock is held to allocate under. A block that is not
     * written is a hole to the reader (create == 0: unmapped, so the
     * caller falls back) and a contradiction to the writer (create == 1:
     * -EIO, never an allocation).
     */
    CETRAFS_GB_OVERWRITE,
};

/* TEST ONLY, and the negative control of the above: a buffered write
 * marks its blocks written at once, as it used to
 * (tests/crash/buffered_extent_order.sh). */
static bool cetrafs_buf_convert_early;
cetrafs_test_param(buf_convert_early, cetrafs_buf_convert_early, bool, 0644);
MODULE_PARM_DESC(buf_convert_early, "TEST ONLY: buffered writes mark their extents written at write time");

/* TEST ONLY, and the negative control of the durability-boundary
 * conversion of buffered and mapped stores (tests/kernel/mmap_prealloc_content.sh):
 * the blocks are flushed and dropped from the pending set, but their
 * extents are never marked written, so they read back as zeros. */
static bool cetrafs_buf_convert_skip;
cetrafs_test_param(buf_convert_skip, cetrafs_buf_convert_skip, bool, 0644);
MODULE_PARM_DESC(buf_convert_skip, "TEST ONLY: durability boundaries drop buffered and mapped blocks without marking them written");

/* b_private of a DIO mapping that left preallocated blocks for the
 * completion to convert: the write's tracker (lock.c,
 * cetrafs_dio_track_add()). The DIO code copies b_private into the dio
 * after EVERY get_block call and never clears it -- nor resets it before
 * the next call -- so once one segment sets it, every later segment adds
 * to the same tracker and the completion receives it. */

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
cetrafs_test_param(dio_skip_convert, cetrafs_dio_skip_convert, bool, 0644);
MODULE_PARM_DESC(dio_skip_convert, "TEST ONLY: leave an O_DIRECT write's preallocated blocks unconverted");

/* Shared-lock O_DIRECT overwrites (cetrafs_dio_overwrite_write()). Off
 * restores the exclusive path for every O_DIRECT write: the A/B control
 * of the concurrency suite. */
static bool cetrafs_dio_shared_overwrite = true;
cetrafs_test_param(dio_shared_overwrite, cetrafs_dio_shared_overwrite, bool, 0644);
MODULE_PARM_DESC(dio_shared_overwrite,
                 "TEST ONLY: an aligned O_DIRECT overwrite of written blocks runs under the shared inode_lock (0 = exclusive)");

/* TEST ONLY: pause a shared-lock overwrite after its mapping is checked,
 * still inside the shared section -- the window the race suite aims a
 * punch, truncate or defrag into. */
static unsigned int cetrafs_dio_overwrite_gap_ms;
cetrafs_test_param(dio_overwrite_gap_ms, cetrafs_dio_overwrite_gap_ms, uint, 0644);
MODULE_PARM_DESC(dio_overwrite_gap_ms, "TEST ONLY: pause a shared-lock overwrite between its check and its I/O");

/* TEST ONLY, the negative control of the shared section: the overwrite
 * takes no inode_lock at all, so the verdict is taken with nothing
 * holding off a punch, truncate or defrag. */
static bool cetrafs_dio_overwrite_nolock;
cetrafs_test_param(dio_overwrite_nolock, cetrafs_dio_overwrite_nolock, bool, 0644);
MODULE_PARM_DESC(dio_overwrite_nolock, "TEST ONLY: a shared-lock overwrite takes no inode_lock (negative control)");

/* Overwrites that ran in the shared section (procfs dio_overwrites). */
static atomic64_t cetrafs_dio_overwrites = ATOMIC64_INIT(0);

u64 cetrafs_dio_overwrite_count(void)
{
    return (u64) atomic64_read(&cetrafs_dio_overwrites);
}

/* Test-only: fail an O_DIRECT write right after it allocated a block
 * (cetrafs_dio_get_block()), leaving that block allocated and unwritten. */
static bool cetrafs_dio_fail_after_alloc_once;
cetrafs_test_param(dio_fail_after_alloc_once, cetrafs_dio_fail_after_alloc_once, bool, 0644);
MODULE_PARM_DESC(dio_fail_after_alloc_once, "TEST ONLY: fail the next O_DIRECT write after it allocates a block");

/* TEST ONLY: stall halfway through the copy that drops a fully
 * converted preallocated extent from an extent array. */
static unsigned int cetrafs_leaf_drop_copy_stall_ms;
cetrafs_test_param(leaf_drop_copy_stall_ms, cetrafs_leaf_drop_copy_stall_ms, uint, 0644);
MODULE_PARM_DESC(leaf_drop_copy_stall_ms, "TEST ONLY: stall halfway through an extent-array drop copy");

/* TEST ONLY: stall halfway through a FRONT shrink of an in-place leaf
 * edit -- the logical start and length are new, the physical start is
 * still the old one (the scrub walk's probe, tests/kernel/scrub_walk_torn.sh). */
static unsigned int cetrafs_leaf_front_shrink_stall_ms;
cetrafs_test_param(leaf_front_shrink_stall_ms, cetrafs_leaf_front_shrink_stall_ms, uint, 0644);
MODULE_PARM_DESC(leaf_front_shrink_stall_ms, "TEST ONLY: stall halfway through a front shrink of an extent entry");

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
static int cetrafs_dio_mark_convert(struct inode *inode, struct buffer_head *bh, sector_t iblock)
{
    void *t = cetrafs_dio_track_add(inode, bh->b_private, (u32) iblock, (u32) (bh->b_size >> inode->i_blkbits));

    if (!t)
        return -ENOMEM; /* untracked, a unit convert could zero its landed data */
    set_buffer_new(bh);
    set_buffer_defer_completion(bh);
    bh->b_private = t;
    return 0;
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
     *
     * Killable: the holder may be a punch or truncate doing device I/O
     * for seconds, and a store that cannot be killed behind it pins the
     * process in D state (audit L21). A fatal signal fails the fault
     * with SIGBUS -- the task is dying, and a kernel-mode access (a
     * copy_from_user into this mapping) gets -EFAULT instead of a fault
     * retried forever.
     */
    if (down_write_killable(&inode->i_mapping->invalidate_lock)) {
        sb_end_pagefault(inode->i_sb);
        return VM_FAULT_SIGBUS;
    }
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
    int ret, ret2;

    if (!(file->f_mode & FMODE_WRITE))
        return 0;
    ret = file_write_and_wait(file);
    /* And the blocks those writes went to, so close(2) hears it if they
     * cannot be marked written (enum cetrafs_gb_mode, BUF). */
    ret2 = cetrafs_convert_pending(file_inode(file));
    return ret ? ret : ret2;
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

/*
 * Zero what lies past the old EOF in its folio, before the size grows
 * over it.
 *
 * A store through a shared mapping may land anywhere in the folio that
 * holds EOF, past EOF included; the kernel keeps it, and writeback
 * zeroes it only while it still lies past i_size. Grow the size first
 * and it becomes file contents: ftruncate, fallocate, or a write that
 * starts past EOF published bytes nobody ever wrote to the file -- and
 * on a shared LUN wrote them to the device for every node
 * (tests/kernel/mmap_eof_extend.sh; ext4 returns zeros).
 * pagecache_isize_extended() does nothing for a block the size of a
 * page, so it is no help here.
 *
 * Caller holds invalidate_lock EXCLUSIVELY, and moves the size before
 * dropping it. The folio's mappings are zapped first, so a later store
 * faults, and the fault's page_mkwrite waits on that lock -- by when the
 * size has moved and the store is a write inside the file. A store that
 * finished before this call is erased; one that races it is ordered
 * after the extension, which a concurrent caller cannot tell apart.
 *
 * Only a non-zero tail is dirtied: those bytes came from a store that
 * went through page_mkwrite, or from the device, so the block behind
 * them is allocated and writeback has nothing to allocate.
 */
static void cetrafs_zero_post_eof(struct inode *inode, loff_t old_size, loff_t new_size)
{
    struct address_space *mapping = inode->i_mapping;
    struct folio *folio;
    size_t from, to;

    lockdep_assert_held_write(&mapping->invalidate_lock);
    if (new_size <= old_size || !(old_size & (PAGE_SIZE - 1)))
        return;
    if (cetrafs_sb_is_fenced(inode->i_sb))
        return; /* stopped: nothing new reaches the device */

    folio = filemap_lock_folio(mapping, old_size >> PAGE_SHIFT);
    if (!IS_ERR(folio)) {
        folio_unlock(folio);
    } else {
        /* Not cached. Writeback zeroes a tail on its way out, but the
         * DEVICE can still hold one: truncate publishes the smaller size
         * before it zeroes, and a crash between leaves the file's old
         * bytes there (audit 2026-11-06 L22). Read it and zero it like a
         * cached one; a hole or unwritten block reads as zeros and is
         * left alone. A read that fails leaves it, as before. */
        folio = read_mapping_folio(mapping, old_size >> PAGE_SHIFT, NULL);
        if (IS_ERR(folio))
            return;
    }
    if (folio_mapped(folio))
        unmap_mapping_range(mapping, folio_pos(folio), folio_size(folio), 0);
    folio_lock(folio);
    if (folio->mapping == mapping) {
        from = offset_in_folio(folio, old_size);
        to = folio_size(folio);
        if (new_size - folio_pos(folio) < (loff_t) to)
            to = (size_t) (new_size - folio_pos(folio));
        if (from < to) {
            void *kaddr = kmap_local_folio(folio, from);
            bool dirty = memchr_inv(kaddr, 0, to - from) != NULL;

            kunmap_local(kaddr);
            if (dirty) {
                folio_zero_segment(folio, from, to);
                folio_mark_dirty(folio);
            }
        }
    }
    folio_unlock(folio);
    folio_put(folio);
}

/*
 * The volume's capacity, which sb->s_maxbytes no longer carries (fs.c's
 * fill_super()): refused or shortened exactly as generic_write_checks()
 * does at s_maxbytes, after catching up with a peer's grow. Returns the
 * count to write or an error.
 */
static ssize_t cetrafs_write_capacity(struct kiocb *iocb, struct iov_iter *from)
{
    struct super_block *sb = file_inode(iocb->ki_filp)->i_sb;
    loff_t pos = iocb->ki_pos, cap;
    size_t count = iov_iter_count(from);
    int r;

    if (pos + (loff_t) count <= cetrafs_sb_max_file_size(sb))
        return count;
    if (iocb->ki_flags & IOCB_NOWAIT)
        return -EAGAIN; /* the catch-up reads the device */
    r = cetrafs_sb_capacity_for(sb, pos + count, &cap);
    if (r)
        return r;
    if (pos >= cap)
        return -EFBIG;
    if (pos + (loff_t) count > cap)
        iov_iter_truncate(from, cap - pos);
    return iov_iter_count(from);
}

/*
 * Would this write strip a privilege? file_remove_privs() is a notify_change()
 * into cetrafs_setattr(), which needs the exclusive lock, so such a write takes
 * the exclusive path. The test is the VFS's own (dentry_needs_remove_privs()):
 * a setuid or setgid bit, or a security.capability xattr (the capability LSM's
 * need_killpriv). An xattr error other than "absent" counts as "may strip".
 */
/* TEST ONLY: the shared path ignores S_NOSEC and asks every write, as
 * before -- the control of tests/kernel/dio_overwrite_nosec.sh. */
static bool cetrafs_dio_privs_nosec_off;
cetrafs_test_param(dio_privs_nosec_off, cetrafs_dio_privs_nosec_off, bool, 0644);
MODULE_PARM_DESC(dio_privs_nosec_off, "TEST ONLY: the shared O_DIRECT path asks for a capability on every write");
static atomic64_t cetrafs_dio_privs_xattr_reads = ATOMIC64_INIT(0);
u64 cetrafs_dio_privs_xattr_reads_count(void)
{
    return (u64) atomic64_read(&cetrafs_dio_privs_xattr_reads);
}

static bool cetrafs_dio_may_strip_privs(struct file *file)
{
    struct inode *inode = file_inode(file);
    struct super_block *sb = inode->i_sb;
    bool nosec_ok = !READ_ONCE(cetrafs_dio_privs_nosec_off);
    cetrafs_inode_t *raw;
    bool no_xattr;
    int r;

    /* The VFS's own answer, as file_remove_privs() takes it: set after a
     * write found nothing to strip (SB_NOSEC, from get_tree_bdev()),
     * cleared by a local chmod +s or security.* setxattr and by the
     * adoption of a peer's identity (cetrafs_inode_adopt_identity()).
     * Without it every write paid the forced-fresh capability lookup
     * below -- two device reads -- on the path that exists to be fast. */
    if (nosec_ok && IS_NOSEC(inode))
        return false;
    if (inode->i_mode & (S_ISUID | S_ISGID))
        return true;
    /* The xattr block is in the record, and the record is read as the
     * mapping reads it (the same trust gate as __cetrafs_get_block()). A
     * file with no xattr block has no capability to strip, and this costs
     * one record read -- not the xattr read below, which forces a fresh
     * record and the xattr block on every call. A record that is not this
     * file's, or cannot be read, takes the exclusive path, which asks again. */
    raw = kmalloc(sizeof(*raw), GFP_NOFS);
    if (!raw)
        return true;
    if (!cetrafs_lock_held_for_write_locally(inode))
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    r = cetrafs_read_raw_inode_overlaid(sb, inode, raw);
    if (r || cetrafs_le64(raw->generation) != cetrafs_inode_get_generation(inode)) {
        kfree(raw);
        return true;
    }
    no_xattr = !cetrafs_le64(raw->xattr_block);
    kfree(raw);
    if (!no_xattr) {
        atomic64_inc(&cetrafs_dio_privs_xattr_reads);
        r = cetrafs_xattr_caps_size(inode);
        if (r > 0 || (r < 0 && r != -ENODATA && r != -EOPNOTSUPP))
            return true;
    }
    /* Nothing to strip: say so as the VFS does (inode_has_no_xattr(),
     * which checks setuid/setgid and SB_NOSEC itself). i_flags is
     * otherwise written under i_rwsem held exclusively; here it is held
     * shared, and every writer that can run beside us sets this same bit. */
    if (nosec_ok)
        inode_has_no_xattr(inode);
    return false;
}

/*
 * Is every block of [pos, pos + count) written? 1 yes, 0 no (a hole, a
 * preallocated block, or a pending one: take the exclusive path), < 0 an
 * error. Caller holds inode_lock shared. Walks by the run each lookup
 * reports, and never steps by less than one block: a run of zero would be
 * a loop that never ends (CLAUDE.md rule 14).
 */
static int cetrafs_dio_overwrite_probe(struct inode *inode, loff_t pos, size_t count)
{
    unsigned int bits = inode->i_blkbits;
    sector_t b = (sector_t) (pos >> bits);
    sector_t end = (sector_t) ((pos + (loff_t) count) >> bits);

    while (b < end) {
        struct buffer_head bh = { 0 };
        u64 step;
        int ret;

        bh.b_size = (size_t) ((end - b) << bits);
        if (down_read_killable(&inode->i_mapping->invalidate_lock))
            return -EINTR;
        ret = __cetrafs_get_block(inode, b, &bh, 0, false, CETRAFS_GB_OVERWRITE);
        up_read(&inode->i_mapping->invalidate_lock);
        if (ret)
            return ret;
        if (!buffer_mapped(&bh))
            return 0;
        step = bh.b_size >> bits;
        if (!step)
            return 0;
        b += min_t(u64, step, end - b);
        cond_resched();
    }
    return 1;
}

/*
 * An aligned O_DIRECT overwrite of WRITTEN blocks inside i_size, run under
 * the SHARED inode_lock. ext4 and XFS take the same shared lock for it.
 *
 * Why the shared lock is enough. Every change that can free or remap a
 * written block holds inode_lock EXCLUSIVELY: truncate (VFS, i_rwsem), punch
 * and the other fallocate modes (inode_lock), the defrag mover
 * (cetrafs_defrag_inode_lock_drained(), which also drains direct I/O), and
 * the lock suspend (inode_lock, then inode_dio_wait). While this write holds
 * the shared lock -- the mapping check, the submission, and for a synchronous
 * write the completion -- none of them runs, and a new one waits for it. The
 * DIO count (inode_dio_begin) also stays up until the completion, so a
 * freeing path that drains direct I/O waits for an async write in flight.
 * The paths that hold invalidate_lock but not inode_lock never free or remap
 * a WRITTEN block: a fault and writeback allocate only holes, a DIO completion
 * and the fsync-time conversion touch only preallocated blocks, and the pending
 * set is preallocated too. Two shared writers may run together: each maps
 * written blocks and writes them, and neither edits the tree.
 *
 * The verdict is not carried across the I/O on trust. The probe below checks
 * every block of the range under invalidate_lock (shared), and the DIO's
 * get_block checks each block again in CETRAFS_GB_OVERWRITE mode, which
 * refuses rather than allocates. Under nofilelock a PEER can change the file
 * outside this lock, as it can under the exclusive path: the same extent-cache
 * freshness gate decides what this node reads, and a block a peer took away
 * fails the write with -EIO instead of being allocated under a lock it does
 * not hold.
 *
 * Only what the lock covers qualifies, and everything else takes the
 * exclusive path unchanged: a direct write that is not block aligned (its
 * partial blocks are zeroed through the convert machinery, which needs the
 * exclusive section), NOWAIT, O_APPEND, a write reaching past i_size (a
 * hole or preallocated block, or a size change), a write that would strip a
 * privilege (cetrafs_dio_may_strip_privs(): stripping is a setattr, which
 * needs the exclusive lock), or a range with any block that is not
 * written (a hole, a preallocated block, or a buffered write still pending).
 *
 * The DIO is run through generic_file_direct_write(), not
 * __generic_file_write_iter(): the latter falls back to a buffered write for
 * a short direct write, and a write_begin under the shared lock would
 * allocate. A short direct write is returned as the short count it is.
 *
 * Regression suite: tests/kernel/dio_overwrite_shared.sh (classification,
 * concurrency, the exclusive control, and the race against punch, truncate
 * and defrag with the window knob and its nolock negative control).
 */
/* TEST ONLY: the next N shared-path direct writes find a cached page that
 * will not invalidate (generic_file_direct_write() returns 0);
 * _zero_ok returns that 0 to the caller, as before -- the control of
 * tests/kernel/dio_overwrite_busy.sh. */
static unsigned int cetrafs_dio_overwrite_busy;
cetrafs_test_param(dio_overwrite_busy, cetrafs_dio_overwrite_busy, uint, 0644);
MODULE_PARM_DESC(dio_overwrite_busy, "TEST ONLY: the next N shared-path direct writes report a page that will not invalidate");
static bool cetrafs_dio_overwrite_zero_ok;
cetrafs_test_param(dio_overwrite_zero_ok, cetrafs_dio_overwrite_zero_ok, bool, 0644);
MODULE_PARM_DESC(dio_overwrite_zero_ok, "TEST ONLY: a shared-path direct write that wrote nothing returns 0");

static ssize_t cetrafs_dio_overwrite_write(struct kiocb *iocb, struct iov_iter *from, bool *took)
{
    struct file *file = iocb->ki_filp;
    struct inode *inode = file_inode(file);
    bool locked = !READ_ONCE(cetrafs_dio_overwrite_nolock);
    unsigned int gap;
    ssize_t ret;
    int probe;

    *took = false;
    if (!READ_ONCE(cetrafs_dio_shared_overwrite) || !(iocb->ki_flags & IOCB_DIRECT) ||
        (iocb->ki_flags & (IOCB_NOWAIT | IOCB_APPEND)))
        return 0;

    if (locked)
        inode_lock_shared(inode);
    ret = cetrafs_lock_write_gate(inode);
    if (ret) {
        *took = true;
        goto out;
    }
    ret = generic_write_checks(iocb, from);
    if (ret <= 0) {
        *took = ret < 0;
        goto out;
    }
    if (cetrafs_dio_unaligned(inode, iocb, from) || iocb->ki_pos + (loff_t) ret > i_size_read(inode) ||
        cetrafs_dio_may_strip_privs(file)) {
        ret = 0;
        goto out;
    }

    probe = cetrafs_dio_overwrite_probe(inode, iocb->ki_pos, iov_iter_count(from));
    if (probe <= 0) {
        ret = probe; /* 0: not all written, the exclusive path; < 0: failed */
        *took = probe < 0;
        goto out;
    }
    *took = true;

    cetrafs_inode_shared_dio_adjust(inode, 1);
    ret = file_update_time(file);
    if (!ret) {
        gap = READ_ONCE(cetrafs_dio_overwrite_gap_ms);
        if (unlikely(gap))
            msleep(gap);
        if (cetrafs_dio_overwrite_busy) {
            cetrafs_dio_overwrite_busy--; /* test-only: as a page that would not invalidate */
            ret = 0;
        } else {
            ret = generic_file_direct_write(iocb, from);
        }
        if (ret > 0 || ret == -EIOCBQUEUED)
            atomic64_inc(&cetrafs_dio_overwrites);
        /* 0 is generic_file_direct_write()'s "a cached page would not
         * invalidate: fall back to a buffered write" (mm/filemap.c), with
         * nothing written and the iterator untouched. The fallback needs
         * the exclusive lock, so the exclusive path takes the write from
         * the start -- returning the 0 made write(2) report nothing
         * written for a nonempty request. */
        if (ret == 0 && !READ_ONCE(cetrafs_dio_overwrite_zero_ok))
            *took = false;
    }
    cetrafs_inode_shared_dio_adjust(inode, -1);
out:
    if (locked)
        inode_unlock_shared(inode);
    if (*took && ret > 0)
        ret = generic_write_sync(iocb, ret);
    return ret;
}

static ssize_t cetrafs_file_write_iter(struct kiocb *iocb, struct iov_iter *from)
{
    struct inode *inode = file_inode(iocb->ki_filp);
    ssize_t ret;
    bool took;

    ret = cetrafs_dio_overwrite_write(iocb, from, &took);
    if (took)
        return ret;

    if (iocb->ki_flags & IOCB_NOWAIT) {
        if (!inode_trylock(inode))
            return -EAGAIN;
    } else {
        inode_lock(inode);
    }
    ret = cetrafs_lock_write_gate(inode);
    if (!ret) {
        ret = generic_write_checks(iocb, from);
        if (ret > 0)
            ret = cetrafs_write_capacity(iocb, from);
        /* A write starting past EOF grows the size over the old EOF
         * folio's tail: zero it first (cetrafs_zero_post_eof()). The
         * size moves in write_end, after the lock is dropped -- a store
         * faulting in between is concurrent with this write and may be
         * ordered after it; one made before is gone. */
        if (ret > 0 && iocb->ki_pos > i_size_read(inode)) {
            if (iocb->ki_flags & IOCB_NOWAIT) {
                if (!down_write_trylock(&inode->i_mapping->invalidate_lock))
                    ret = -EAGAIN;
            } else {
                filemap_invalidate_lock(inode->i_mapping);
            }
            if (ret > 0) {
                cetrafs_zero_post_eof(inode, i_size_read(inode), iocb->ki_pos);
                filemap_invalidate_unlock(inode->i_mapping);
            }
        }
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
    /*
     * sendfile(2), splice(2) and copy_file_range()'s fallback. Without
     * both, since 6.5 they fail with EINVAL. The read side goes through
     * ->read_iter (copy_splice_read) rather than straight to the page
     * cache (filemap_splice_read), so that every check a read makes --
     * today the fenced/stopped refusal in cetrafs_file_read_iter() --
     * lives on one path. Not a known hole: a stop also drops the page
     * cache, and tests/kernel/splice_ops.sh measured filemap_splice_read
     * refusing a stopped mount as well. The write side already ends in
     * ->write_iter.
     */
    .splice_read = copy_splice_read,
    .splice_write = iter_file_splice_write,
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
    /* fcntl/OFD byte-range locks: refused, never node-local (lock.c). */
    .lock = cetrafs_posix_lock_refuse,
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
/* TEST ONLY: the gate once per call only (the old writeback and DIO). */
static bool cetrafs_fence_per_block_off;
cetrafs_test_param(fence_per_block_off, cetrafs_fence_per_block_off, bool, 0644);

/*
 * The fence, asked again for every block a bulk write maps. writepages
 * and a DIO are gated once, when they start; a WB_SYNC_ALL pass over GiB
 * of dirty pages, or one large O_DIRECT, outlives that answer by
 * minutes, and the pages mapped after a lease ran out landed on blocks a
 * peer had taken over by then (audit 2026-11-15 B-17). Two reads and a
 * jiffies compare, against a get_block that walks the tree.
 */
static inline bool cetrafs_bulk_fenced(struct inode *inode)
{
    return !READ_ONCE(cetrafs_fence_per_block_off) && cetrafs_sb_is_fenced(inode->i_sb);
}

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
    if (cetrafs_bulk_fenced(inode))
        return -EIO; /* per block, not per call (B-17) */
    /* Killable, as page_mkwrite (audit L21): this runs in the
     * submitter's context and may queue behind a fault or the defrag
     * mover doing device I/O. A fatal signal fails the write before
     * this block is mapped -- nothing is allocated. The completion
     * (cetrafs_dio_end_io()) stays uninterruptible: its data is on the
     * device, and giving up there leaves it reading as zeros. */
    if (down_write_killable(&inode->i_mapping->invalidate_lock))
        return -EINTR;
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
 * The DIO get_block of a shared-lock overwrite (cetrafs_dio_overwrite_write()).
 * It holds invalidate_lock SHARED, not exclusive: it maps a written block
 * and nothing else, so there is no tree edit for the exclusive lock to
 * exclude -- the shared lock excludes only a mover (a split, a move, a
 * convert in another range) that would make this lookup miss. Taken per
 * call, not across the whole DIO, for the reason cetrafs_dio_get_block()
 * gives: the DIO code pins user pages between calls.
 */
static int cetrafs_dio_get_block_overwrite(struct inode *inode, sector_t iblock, struct buffer_head *bh_result,
                                           int create)
{
    int ret;

    if (!create)
        return cetrafs_get_block_read(inode, iblock, bh_result, 0);
    if (cetrafs_bulk_fenced(inode))
        return -EIO; /* per block, not per call (B-17) */
    if (down_read_killable(&inode->i_mapping->invalidate_lock))
        return -EINTR;
    ret = __cetrafs_get_block(inode, iblock, bh_result, create, false, CETRAFS_GB_OVERWRITE);
    up_read(&inode->i_mapping->invalidate_lock);
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
/* TEST ONLY: the next O_DIRECT completion waits this long before it
 * converts (one-shot) -- a write whose data has landed, unconverted,
 * while others complete (tests/kernel/convert_unit.sh). */
static unsigned int cetrafs_dio_end_io_stall_ms;
cetrafs_test_param(dio_end_io_stall_ms, cetrafs_dio_end_io_stall_ms, uint, 0644);
MODULE_PARM_DESC(dio_end_io_stall_ms, "TEST ONLY: the next O_DIRECT completion stalls before converting (one-shot)");

static int cetrafs_dio_end_io(struct kiocb *iocb, loff_t offset, ssize_t size, void *private)
{
    struct inode *inode = file_inode(iocb->ki_filp);
    unsigned int bits = inode->i_blkbits;
    sector_t b, last;
    int ret = 0;

    if (!cetrafs_dio_is_track(private))
        return 0;
    if (unlikely(READ_ONCE(cetrafs_dio_end_io_stall_ms)))
        msleep(xchg(&cetrafs_dio_end_io_stall_ms, 0)); /* TEST ONLY, one-shot */
    if (size <= 0 || cetrafs_dio_skip_convert) { /* skip: test-only, see the knob */
        cetrafs_dio_track_done(inode, private); /* nothing landed to convert, or kept preallocated */
        return 0;
    }

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
    /* Its blocks are converted (or reading as zeros, reported below):
     * no longer in flight to a unit convert -- under the lock, so none
     * judges them between the two. */
    cetrafs_dio_track_done(inode, private);
    filemap_invalidate_unlock(inode->i_mapping);

    if (ret)
        pr_err_ratelimited("ino=%llu: O_DIRECT write at %lld+%zd landed but block %llu could not be marked written "
                           "(%d) -- it reads as zeros, the write fails\n",
                           (unsigned long long) inode->i_ino, (long long) offset, size, (unsigned long long) b, ret);
    else
        atomic64_inc(&cetrafs_dio_converts);
    return ret;
}

/*
 * Mark a regular file's pending buffered-write blocks written (enum
 * cetrafs_gb_mode, BUF). Rule 8 is the whole job: the extent that says
 * "written" may not become durable before the data -- so the data is
 * written back, the writeback checked for errors, and the device cache
 * flushed BEFORE the first conversion dirties a leaf or the shadow.
 *
 * A writeback error since the set began means some of its blocks may
 * never have received their data, and which ones is not recorded: none
 * is converted, the set is dropped, and those blocks keep reading as
 * zeros -- a loss the caller reports, never a disclosure.
 *
 * Caller holds invalidate_lock EXCLUSIVELY (the set's writers, and the
 * tree's mutators, rule 18) and keeps write(2) out -- inode_lock, or by
 * construction (the last writer's close). A write between its
 * write_begin and write_end holds neither invalidate_lock nor a dirty
 * page, so the writeback below would miss it and the conversion would
 * declare a block whose data has not even been copied yet.
 */
/* TEST ONLY: the cache flush before a pending conversion fails, as a
 * refused SYNCHRONIZE CACHE would (tests/kernel/pending_flush_error.sh). */
static bool cetrafs_pending_flush_fail;
cetrafs_test_param(pending_flush_fail, cetrafs_pending_flush_fail, bool, 0644);

/* TEST ONLY: the conversion's device flush runs under inode_lock and
 * invalidate_lock, as it did before the flush moved out of them (the
 * negative control of tests/kernel/fsync_convert_stall.sh). */
static bool cetrafs_convert_flush_under_lock;
cetrafs_test_param(convert_flush_under_lock, cetrafs_convert_flush_under_lock, bool, 0644);
MODULE_PARM_DESC(convert_flush_under_lock, "TEST ONLY: an fsync's conversion flushes the device under the file's locks");
MODULE_PARM_DESC(pending_flush_fail, "TEST ONLY: the device cache flush before a pending conversion fails");

/*
 * The conversion core, under inode_lock and invalidate_lock (held by the
 * caller). It writes the set's span back and marks it written; *flipped
 * says whether any flip was attempted. It does NOT flush: the caller
 * flushes once the locks are released (cetrafs_convert_pending()), or
 * under them (cetrafs_convert_pending_locked()).
 */
static int __cetrafs_convert_pending(struct inode *inode, bool *flipped)
{
    struct address_space *m = inode->i_mapping;
    unsigned int bits = inode->i_blkbits;
    u32 first, last;
    u64 from = 0, cur = 0;
    int ret;

    lockdep_assert_held_write(&m->invalidate_lock);
    *flipped = false;
    if (!S_ISREG(inode->i_mode) || !cetrafs_pending_any(inode))
        return 0;

    /*
     * The verdict is the set's own errseq cursor, nothing else.
     * filemap_write_and_wait() also reports the mapping's legacy AS_EIO
     * flag -- set by ANY earlier failed writeback of this file, one the
     * set never touched -- and acting on it dropped blocks whose data
     * had reached the device (audit F8). So: start the writeback (its
     * own submission error is ours), wait without consuming the flags
     * (they stay for fsync/close to report), and judge by the cursor.
     */
    /*
     * Only the set's span needs its data down before the conversion: its
     * blocks are what the flips declare written. The rest of the file's
     * dirty pages are each caller's own business, and every caller writes
     * them first (->flush, the last close, fsync's range) -- a whole-file
     * writeback here made an fsync of one small range pay for every dirty
     * page of a large image.
     */
    {
        u64 lo = U64_MAX, hi = 0, at = 0;

        while (at <= U32_MAX && !cetrafs_pending_next(inode, (u32) at, &first, &last)) {
            lo = min_t(u64, lo, first);
            hi = max_t(u64, hi, last);
            at = (u64) last + 1;
        }
        if (lo == U64_MAX)
            return 0;
        ret = filemap_fdatawrite_range(m, (loff_t) (lo << bits), (loff_t) (((hi + 1) << bits) - 1));
        if (!ret) {
            (void) filemap_fdatawait_range_keep_errors(m, (loff_t) (lo << bits), (loff_t) (((hi + 1) << bits) - 1));
            if (cetrafs_pending_wb_failed(inode))
                ret = -EIO;
        }
    }
    if (ret) {
        pr_err_ratelimited("ino=%llu: buffered data did not reach the device (%d) -- the blocks it was written to "
                           "stay unwritten and read as zeros\n",
                           (unsigned long long) inode->i_ino, ret);
        cetrafs_pending_drop_all(inode);
        return ret;
    }
    /* The writes completed (the wait above), so their data is in the
     * device's cache and the flip below may be published: the flush that
     * makes them durable is the caller's, once the locks are released.
     * What must not happen is a DURABLE publish of the flipped extents
     * before that flush -- and every publisher of an extent or a tree
     * block flushes before it publishes (CLAUDE.md rule 8; the audit is
     * at cetrafs_convert_pending()). */
    *flipped = true;

    while (from <= U32_MAX && !cetrafs_pending_next(inode, (u32) from, &first, &last)) {
        for (cur = first; cur <= last;) {
            struct buffer_head map = {0};
            u64 n;

            if (unlikely(READ_ONCE(cetrafs_buf_convert_skip))) {
                cur = (u64) last + 1; /* TEST ONLY: see the parameter */
                break;
            }
            map.b_size = (size_t) min_t(u64, (u64) last - cur + 1, (u64) U32_MAX >> bits) << bits;
            ret = __cetrafs_get_block(inode, (sector_t) cur, &map, 1, false, CETRAFS_GB_CONVERT_PENDING);
            if (ret)
                goto fail;
            /* Never trust the answer for progress (rule 14). */
            n = buffer_mapped(&map) ? clamp_t(u64, map.b_size >> bits, 1, (u64) last - cur + 1) : 1;
            cur += n;
        }
        /* The flips above visible before the set lets go of them: a
         * mapper that misses in the set looks again (__cetrafs_get_block()). */
        smp_wmb();
        cetrafs_pending_clear(inode, first, last);
        from = (u64) last + 1;
        cond_resched();
    }
    return 0;

fail:
    /* What was converted is out of the set; the rest stays pending, for
     * the next boundary to try again. */
    if (cur > first) {
        smp_wmb();
        cetrafs_pending_clear(inode, first, (u32) (cur - 1));
    }
    pr_err_ratelimited("ino=%llu: could not mark buffered block %llu written (%d) -- it reads as zeros until a later "
                       "fsync or close converts it\n",
                       (unsigned long long) inode->i_ino, (unsigned long long) cur, ret);
    return ret;
}

/*
 * The device cache flush that makes a conversion's data durable before
 * anything publishes the flipped extents.
 *
 * Who publishes a flipped extent or a tree block that names one, and what
 * flushes before it does (the audit of FD-7; a new publisher must be
 * added here):
 *  - a held-back tree batch (leafdefer.c): its first flush
 *    (cetrafs_journal_write_deferred(), step 0) follows the flip -- the
 *    flip edits the cached tree under invalidate_lock, which the batch
 *    holds too -- and the bitmaps are flushed with it;
 *  - the record publishes of a shadow or fd sector (inode.c:
 *    cetrafs_write_raw_inode_fd(), the shadow CAS in cetrafs_write_vfs_inode):
 *    each takes the shadow AFTER the flip and flushes before its CAS;
 *  - the close's record publish (lock.c cetrafs_lock_release()): flushes
 *    before its CAS, and the tree it publishes is a batch's, flushed above;
 *  - the sync and unmount points: they run the fsync path, which ends in
 *    a flush.
 * So a flip is never durable ahead of its data, whichever of these runs
 * first, and the flush issued here after the flip is what makes the data
 * durable for a crash that comes before any of them.
 *
 * TEST ONLY: convert_flush_under_lock (tests/kernel/fsync_convert_stall.sh)
 * puts that flush back under the locks, as it was.
 */
static int cetrafs_convert_flush(struct super_block *sb, struct inode *inode)
{
    int ret = READ_ONCE(cetrafs_pending_flush_fail) ? -EIO : cetrafs_publish_flush(sb);

    if (ret)
        pr_err_ratelimited("ino=%llu: the device cache flush after marking buffered blocks written failed (%d) -- "
                           "the next fsync, close or sync publishes them, and flushes before it does\n",
                           (unsigned long long) inode->i_ino, ret);
    return ret;
}

/* Lock-held callers (lock.c's suspension): the flush is under their lock. */
int cetrafs_convert_pending_locked(struct inode *inode)
{
    bool flipped = false;
    int ret;

    lockdep_assert_held_write(&inode->i_mapping->invalidate_lock);
    ret = __cetrafs_convert_pending(inode, &flipped);
    if (!ret && flipped) {
        ret = cetrafs_convert_flush(inode->i_sb, inode);
        cetrafs_conv_unflushed_set(inode, ret != 0);
    }
    return ret;
}

/*
 * The set's span written back before the locks are taken, so the locked
 * pass finds nothing dirty in it, normally. A write that races this is
 * written back again under the lock (__cetrafs_convert_pending()): the
 * result is the same, and only a race pays for its own I/O under the
 * locks. Its errors are not judged here -- the locked pass judges the
 * set's own errseq cursor, which keeps them.
 */
static void cetrafs_convert_prewrite(struct inode *inode)
{
    struct address_space *m = inode->i_mapping;
    unsigned int bits = inode->i_blkbits;
    u64 lo = U64_MAX, hi = 0, at = 0;
    u32 first, last;

    while (at <= U32_MAX && !cetrafs_pending_next(inode, (u32) at, &first, &last)) {
        lo = min_t(u64, lo, first);
        hi = max_t(u64, hi, last);
        at = (u64) last + 1;
    }
    if (lo == U64_MAX)
        return;
    (void) filemap_fdatawrite_range(m, (loff_t) (lo << bits), (loff_t) (((hi + 1) << bits) - 1));
    (void) filemap_fdatawait_range_keep_errors(m, (loff_t) (lo << bits), (loff_t) (((hi + 1) << bits) - 1));
}

int cetrafs_convert_pending(struct inode *inode)
{
    struct super_block *sb = inode->i_sb;
    bool flipped = false, did_flush = false;
    int ret = 0, fret = 0;

    if (!S_ISREG(inode->i_mode))
        return 0;
    if (!cetrafs_pending_any(inode)) {
        /* Nothing to convert, but an earlier conversion's flush may still
         * be owed (a refused one, retried here). */
        if (!cetrafs_conv_unflushed(inode))
            return 0;
        ret = cetrafs_convert_flush(sb, inode);
        cetrafs_conv_unflushed_set(inode, ret != 0);
        return ret;
    }
    cetrafs_convert_prewrite(inode);
    inode_lock(inode);
    filemap_invalidate_lock(inode->i_mapping);
    ret = __cetrafs_convert_pending(inode, &flipped);
    if (!ret && flipped && READ_ONCE(cetrafs_convert_flush_under_lock)) {
        fret = cetrafs_convert_flush(sb, inode); /* TEST ONLY: the old place */
        did_flush = true;
    }
    filemap_invalidate_unlock(inode->i_mapping);
    inode_unlock(inode);
    if (!ret && flipped && !READ_ONCE(cetrafs_convert_flush_under_lock)) {
        fret = cetrafs_convert_flush(sb, inode);
        did_flush = true;
    }
    if (did_flush)
        cetrafs_conv_unflushed_set(inode, fret != 0);
    return ret ? ret : fret;
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
     * completion that converts it is passed either way.
     *
     * A write while a shared-lock overwrite is in its section can only be
     * that overwrite: the exclusive i_rwsem and the shared one exclude each
     * other, so the count is non-zero only for the writer that raised it. */
    return __blockdev_direct_IO(iocb, inode, inode->i_sb->s_bdev, iter,
                                cetrafs_inode_shared_dio_active(inode) ? cetrafs_dio_get_block_overwrite :
                                                                         cetrafs_dio_get_block,
                                cetrafs_dio_end_io,
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

        /* Disk-read addresses (rule 19): a damaged root aims neither a
         * forced read nor an invalidation outside the data regions. The
         * tree's real readers refuse the same block. */
        if (!cetrafs_lba_run_is_data(sb, ilba, 1))
            continue;
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

                for (li = 0; li < iln; li++) {
                    u64 llba = cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo);

                    if (cetrafs_lba_run_is_data(sb, llba, 1))
                        cetrafs_invalidate_block(sb, llba);
                }
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
 * structural maximum.
 *
 * 'reader': the caller only reports the map (fiemap, SEEK_DATA/HOLE)
 * and frees or writes nothing on the strength of it, so its blocks are
 * read under the data read path's trust rule
 * (cetrafs_lock_read_cache_trusted()), not the write lock's. Asking the
 * write lock's question sent every block of the tree to the device on
 * every call whenever this node did not hold the file for write: a
 * filefrag of one fallocated 16 GiB image on an FC array made ~880
 * FIEMAP calls, re-read its 1,021 tree blocks on each, and held the
 * inode lock for 285 s. */
/* TEST ONLY: a whole-tree walk reads its index and leaf blocks one at a
 * time, as before P12 -- the control of tests/kernel/tree_walk_readahead.sh
 * and tests/kernel/evict_walk_batched.sh. */
static bool cetrafs_flatten_prefetch_off;
cetrafs_test_param(flatten_prefetch_off, cetrafs_flatten_prefetch_off, bool, 0644);
MODULE_PARM_DESC(flatten_prefetch_off, "TEST ONLY: a tree walk reads its extent blocks one at a time");

/*
 * P12: the blocks a walk needs are read as ONE batch, whichever way the
 * walk reads them. A walk used to read each extent leaf in turn, one device
 * round trip apiece, and only a TRUSTED walk at depth 2 had any read-ahead
 * (sb_breadahead, one index block at a time). An UNTRUSTED walk -- an evict
 * of a closed file, a scrub, a reporter whose file a peer has open -- had
 * none, so an unlink of a fragmented file paid ~1000 serial reads before it
 * freed anything (audit 2026-11-14 P12). Every block the walk does not
 * already hold is submitted under one plug and waited for once.
 *
 * A block is accepted here exactly when the per-block reader would accept
 * it -- a trusted cached copy that is uptodate, or a fresh read whose tail
 * verifies -- and its counts check. Everything else (a refused address, a
 * torn or damaged block, a failed read) is left NULL, and the caller reads
 * that one block through cetrafs_read_tree_bh_for(), which retries, refuses
 * and reports exactly as before.
 */
static void cetrafs_tree_batch_fast(struct inode *inode, const sector_t *lbas, u32 n, u32 magic, bool reader,
                                    struct buffer_head **bhs)
{
    struct super_block *sb = inode->i_sb;
    sector_t *nl = NULL;
    struct buffer_head **nb = NULL;
    u32 *na = NULL;
    bool trusted;
    u32 i, j, k = 0;

    for (i = 0; i < n; i++) {
        /* An address the reader would refuse, or cannot judge yet: the
         * per-block reader decides, so nothing here is read. */
        int rc = cetrafs_lba_run_check(sb, lbas[i], 1);

        /* -EAGAIN (cannot judge the layout yet) or a refusal: the per-block
         * reader decides, so nothing here is read. */
        if (rc == -EAGAIN || rc)
            return;
    }
    nl = kvmalloc_array(n, sizeof(*nl), GFP_NOFS);
    na = kvmalloc_array(n, sizeof(*na), GFP_NOFS);
    nb = kvcalloc(n, sizeof(*nb), GFP_NOFS);
    if (!nl || !na || !nb)
        goto out; /* not an error: every block goes through the per-block reader */

    trusted = reader ? cetrafs_lock_read_cache_trusted(inode) : cetrafs_lock_held_for_write_locally(inode);
    for (i = 0; i < n; i++) {
        struct buffer_head *bh = trusted ? sb_getblk(sb, lbas[i]) : NULL;

        if (bh && buffer_uptodate(bh) && cetrafs_blk_struct_ok_magic(bh, magic)) {
            bhs[i] = bh;
            continue;
        }
        brelse(bh);
        nl[k] = lbas[i];
        na[k++] = i;
    }
    if (k && !cetrafs_bread_uncached_list(sb, nl, k, nb)) {
        for (j = 0; j < k; j++) {
            struct buffer_head *bh = nb[j];

            /* The per-block reader's test for a fresh read, plus the counts. */
            if (bh && cetrafs_blk_read_accepts(bh, magic) && cetrafs_blk_struct_ok_magic(bh, magic))
                bhs[na[j]] = bh;
            else
                brelse(bh);
        }
    }
out:
    kvfree(nb);
    kvfree(na);
    kvfree(nl);
}

/*
 * Reads lbas[0..n) into bhs[0..n): as one batch where the batch takes the
 * block, and one at a time through the tree reader for every block it did
 * not take. bhs[i] is NULL only where that reader failed; the caller
 * releases every non-NULL entry.
 */
static void cetrafs_tree_read_batch(struct inode *inode, const sector_t *lbas, u32 n, u32 magic, const char *what,
                                    bool reader, struct buffer_head **bhs)
{
    u32 i;

    for (i = 0; i < n; i++)
        bhs[i] = NULL;
    if (n >= 2 && !READ_ONCE(cetrafs_flatten_prefetch_off))
        cetrafs_tree_batch_fast(inode, lbas, n, magic, reader, bhs);
    for (i = 0; i < n; i++) {
        if (!bhs[i])
            bhs[i] = cetrafs_read_tree_bh_for(inode, lbas[i], magic, what, reader);
    }
}

static int cetrafs_tree_flatten_for(struct inode *inode, const cetrafs_inode_t *raw, cetrafs_extent_t **out_arr,
                                    u32 *out_n, bool reader)
{
    cetrafs_extent_t *arr = NULL;
    struct buffer_head *ibhs[ARRAY_SIZE(raw->et.idx)] = {NULL};
    sector_t ilbas[ARRAY_SIZE(raw->et.idx)];
    u32 cap = 0, n = 0, ni, nin;
    int ret = 0;

    /* P12: the root's interior blocks are read as one batch, then each
     * one's leaves as one batch. Blocks not taken by the batch are read
     * one at a time by cetrafs_tree_read_batch(), which checks them. */
    nin = min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.idx));
    for (ni = 0; ni < nin; ni++)
        ilbas[ni] = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
    cetrafs_tree_read_batch(inode, ilbas, nin, CETRAFS_INDEX_TAIL_MAGIC, "extent index", reader, ibhs);

    for (ni = 0; ni < nin && !ret; ni++) {
        const cetrafs_extent_hdr_t *ihdr;
        const cetrafs_extent_idx_t *iarr;
        sector_t *llbas = NULL;
        struct buffer_head **lbhs = NULL;
        u32 li, iln;

        if (!ibhs[ni]) {
            ret = -EIO;
            break;
        }
        ihdr = (const cetrafs_extent_hdr_t *) ibhs[ni]->b_data;
        iarr = (const cetrafs_extent_idx_t *) (ibhs[ni]->b_data + sizeof(*ihdr));
        iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);

        llbas = kvmalloc_array(iln ? iln : 1, sizeof(*llbas), GFP_NOFS);
        lbhs = kvcalloc(iln ? iln : 1, sizeof(*lbhs), GFP_NOFS);
        if (!llbas || !lbhs) {
            ret = -ENOMEM;
        } else {
            for (li = 0; li < iln; li++)
                llbas[li] = cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo);
            cetrafs_tree_read_batch(inode, llbas, iln, CETRAFS_LEAF_TAIL_MAGIC, "extent leaf", reader, lbhs);

            for (li = 0; li < iln && !ret; li++) {
                const cetrafs_extent_hdr_t *lhdr;
                u32 ln;

                if (!lbhs[li]) {
                    ret = -EIO;
                    break;
                }
                lhdr = (const cetrafs_extent_hdr_t *) lbhs[li]->b_data;
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
                        ret = -ENOMEM;
                        break;
                    }
                    arr = narr;
                    cap = ncap;
                }
                memcpy(arr + n, lbhs[li]->b_data + sizeof(*lhdr), (size_t) ln * sizeof(*arr));
                n += ln;
            }
        }
        for (li = 0; lbhs && li < iln; li++)
            brelse(lbhs[li]);
        kvfree(lbhs);
        kvfree(llbas);
        brelse(ibhs[ni]);
        ibhs[ni] = NULL;
    }

    if (ret)
        goto fail;
    *out_arr = arr;
    *out_n = n;
    return 0;

fail:
    for (ni = 0; ni < nin; ni++)
        brelse(ibhs[ni]); /* NULL-safe; the ones already released are NULL */
    kvfree(arr);
    return ret;
}

int cetrafs_tree_flatten(struct inode *inode, const cetrafs_inode_t *raw, cetrafs_extent_t **out_arr, u32 *out_n)
{
    return cetrafs_tree_flatten_for(inode, raw, out_arr, out_n, false);
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
/*
 * An extent-tree edit that MOVES entries between tree blocks, against
 * the readers that hold no invalidate_lock.
 *
 * Writeback and an O_DIRECT read map blocks lock-free: they walk a
 * depth-2 interior one entry at a time (copy it under the buffer lock,
 * release, read that leaf, go on from the next slot). A range split puts
 * the new leaf at a slot the walk may already have passed -- the slot
 * before the last, or another interior -- and then removes the moved
 * entries from the old leaf. A walk that copied the old leaf's entry
 * before the insert and reads that leaf after the removal finds the
 * extent in neither: an O_DIRECT read returns zeros for data, and
 * writeback maps a dirty page over an "unmapped" block and allocates it
 * again, naming the block twice. A full leaf's convert has the same
 * shape: it shrinks the extent in the leaf and appends the piece
 * elsewhere, through a new root the walk only sees once the record is
 * staged.
 *
 * So every such edit runs bracketed: cetrafs_tree_move_begin() makes the
 * inode's move sequence odd before the first edit, cetrafs_tree_move_end()
 * even again once the destination is reachable (after the record is
 * staged). Both are under invalidate_lock held exclusively, which every
 * tree writer holds, so the moves of one inode are serialised. A lookup
 * samples the sequence before it reads the record, and a MISS with the
 * sequence odd then or changed since is not believed: it reads the
 * record again and re-walks (__cetrafs_get_block()), a bounded number of
 * times, and then fails with -EIO rather than answer "hole". A hit needs
 * no check: a moved extent is the same extent wherever it is found.
 *
 * Walkers with no inode in hand (the scrub's, cetrafs_raw_inode_for_each_
 * owned_block()) use the module-wide begun/ended counts the same way.
 */
static atomic_t cetrafs_tree_moves_begun = ATOMIC_INIT(0);
static atomic_t cetrafs_tree_moves_ended = ATOMIC_INIT(0);
static atomic64_t cetrafs_tree_move_reruns = ATOMIC64_INIT(0);

u64 cetrafs_tree_move_rerun_count(void)
{
    return (u64) atomic64_read(&cetrafs_tree_move_reruns);
}

/* TEST ONLY: a miss during a move is believed -- the negative control of
 * tests/kernel/split_hides_extent.sh. */
static bool cetrafs_tree_move_rerun_off;
cetrafs_test_param(tree_move_rerun_off, cetrafs_tree_move_rerun_off, bool, 0644);
MODULE_PARM_DESC(tree_move_rerun_off, "TEST ONLY: a lookup that misses during a tree move does not re-run");

#define CETRAFS_TREE_MOVE_RERUNS 200

static void cetrafs_tree_move_begin(struct inode *inode, bool *moving)
{
    unsigned int *seq;

    if (*moving)
        return;
    seq = cetrafs_inode_tree_move_seq(inode);
    atomic_inc(&cetrafs_tree_moves_begun);
    smp_mb__after_atomic();
    WRITE_ONCE(*seq, *seq + 1); /* odd: a move is in progress */
    smp_wmb();                  /* ...before any edit it brackets */
    *moving = true;
}

static void cetrafs_tree_move_end(struct inode *inode, bool *moving)
{
    unsigned int *seq;

    if (!*moving)
        return;
    seq = cetrafs_inode_tree_move_seq(inode);
    smp_wmb(); /* every edit of the move before the sequence moves on */
    WRITE_ONCE(*seq, *seq + 1);
    smp_mb__before_atomic();
    atomic_inc(&cetrafs_tree_moves_ended);
    *moving = false;
}

static unsigned int cetrafs_tree_move_sample(struct inode *inode)
{
    unsigned int s = READ_ONCE(*cetrafs_inode_tree_move_seq(inode));

    smp_rmb(); /* sampled before the reads it guards */
    return s;
}

/* Did a move overlap the walk that started at sample 's0'? */
static bool cetrafs_tree_move_overlapped(struct inode *inode, unsigned int s0)
{
    if (READ_ONCE(cetrafs_tree_move_rerun_off))
        return false; /* test-only: see the knob */
    smp_rmb();
    return (s0 & 1) || READ_ONCE(*cetrafs_inode_tree_move_seq(inode)) != s0;
}

/* A re-run's pause: a move holds the lock for microseconds unless it had
 * to write a block, so a short sleep, then a re-read. */
static void cetrafs_tree_move_backoff(void)
{
    atomic64_inc(&cetrafs_tree_move_reruns);
    usleep_range(20, 100);
}

/* TEST ONLY: stall one lookup of block 'lookup_stall_block' of inode
 * 'lookup_stall_ino', between copying a depth-2 interior entry and
 * reading its leaf (split_hides_extent.sh). One-shot. */
static unsigned long long cetrafs_lookup_stall_ino;
cetrafs_test_param(lookup_stall_ino, cetrafs_lookup_stall_ino, ullong, 0644);
MODULE_PARM_DESC(lookup_stall_ino, "TEST ONLY: the inode whose next lookup stalls (lookup_stall_ms)");
static unsigned int cetrafs_lookup_stall_block;
cetrafs_test_param(lookup_stall_block, cetrafs_lookup_stall_block, uint, 0644);
MODULE_PARM_DESC(lookup_stall_block, "TEST ONLY: the block whose next lookup stalls (lookup_stall_ms)");
static unsigned int cetrafs_lookup_stall_ms;
cetrafs_test_param(lookup_stall_ms, cetrafs_lookup_stall_ms, uint, 0644);
MODULE_PARM_DESC(lookup_stall_ms, "TEST ONLY: stall one depth-2 lookup before it reads a leaf, once");

static void cetrafs_lookup_stall(struct inode *inode, u32 iblock)
{
    unsigned int ms;

    if (likely(!READ_ONCE(cetrafs_lookup_stall_ms)) || inode->i_ino != READ_ONCE(cetrafs_lookup_stall_ino) ||
        iblock != READ_ONCE(cetrafs_lookup_stall_block))
        return;
    ms = xchg(&cetrafs_lookup_stall_ms, 0);
    if (ms)
        msleep(min_t(unsigned int, ms, 10000)); /* test-only; see the knob */
}

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
            bool ok;

            cetrafs_bh_read_lock(bh);
            ok = cetrafs_blk_tail_valid(bh, magic);
            cetrafs_bh_read_unlock(bh);
            if (ok)
                return bh;
            brelse(bh);
        }
        if (attempt + 1 < CETRAFS_BLK_TAIL_READ_RETRIES)
            cetrafs_tear_backoff(attempt); /* a peer's write in flight (X1) */
    }
    return NULL;
}

/* TEST ONLY, the scrub walk's knobs (tests/kernel/scrub_walk_torn.sh):
 * a pause between the leaf's read and the walk's buffer lock -- the
 * window an in-place edit has to start in; the control that walks with
 * no lock at all; and a probe that prints the sum of the extent lengths
 * a walk reports, against the value the test expects (a torn entry sums
 * to less). */
static unsigned int cetrafs_scrub_walk_pause_ms;
cetrafs_test_param(scrub_walk_pause_ms, cetrafs_scrub_walk_pause_ms, uint, 0644);
MODULE_PARM_DESC(scrub_walk_pause_ms, "TEST ONLY: pause in the scrub's leaf walk between the read and the lock");
static bool cetrafs_scrub_walk_unlocked;
cetrafs_test_param(scrub_walk_unlocked, cetrafs_scrub_walk_unlocked, bool, 0644);
MODULE_PARM_DESC(scrub_walk_unlocked, "TEST ONLY: the scrub's leaf walk reads the leaf without the buffer lock");
static unsigned int cetrafs_scrub_walk_expect_sum;
cetrafs_test_param(scrub_walk_expect_sum, cetrafs_scrub_walk_expect_sum, uint, 0644);
MODULE_PARM_DESC(scrub_walk_expect_sum, "TEST ONLY: print the extent-length sum of each leaf walk against this value");

/* Walk one external leaf block's extents (read by LBA). */
static int
cetrafs_scrub_walk_leaf(struct super_block *sb, u64 lba, void (*cb)(void *, u64, u32), void *ctx, bool fresh)
{
    struct buffer_head *bh = cetrafs_scrub_tree_bread(sb, lba, CETRAFS_LEAF_TAIL_MAGIC, fresh);
    const cetrafs_extent_hdr_t *hdr;
    const cetrafs_extent_t *arr;
    u32 ln, i;
    u64 sum = 0;
    bool locked;

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
    /*
     * Under the buffer lock. Cached or freshly re-read, this is the
     * memory this node's extent-tree writers edit in place
     * (cetrafs_tree_lookup_unchecked()), and a half-done edit can name
     * a shifted range -- leaving a live block unreported, which is
     * exactly what this walk's caller frees.
     */
    if (unlikely(READ_ONCE(cetrafs_scrub_walk_pause_ms)))
        msleep(READ_ONCE(cetrafs_scrub_walk_pause_ms)); /* TEST ONLY: see the parameter */
    /* The knob is read ONCE: flipped between the lock and the unlock,
     * two reads would unbalance the buffer lock. */
    locked = likely(!READ_ONCE(cetrafs_scrub_walk_unlocked));
    if (locked)
        cetrafs_bh_read_lock(bh);
    ln = min_t(u32, cetrafs_le16(hdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);
    for (i = 0; i < ln; i++) {
        u32 len = cetrafs_extent_len(arr[i].ee_len);

        sum += len;
        cb(ctx, cetrafs_extent_phys_from_hilo(arr[i].ee_start_hi, arr[i].ee_start_lo), len);
    }
    if (locked)
        cetrafs_bh_read_unlock(bh);
    if (unlikely(READ_ONCE(cetrafs_scrub_walk_expect_sum)))
        pr_info("scrub walk probe: leaf %llu sums to %llu, expected %u\n", (unsigned long long) lba, sum,
                READ_ONCE(cetrafs_scrub_walk_expect_sum));
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
static int __cetrafs_raw_inode_for_each_owned_block(struct super_block *sb,
                                                    const cetrafs_inode_t *raw,
                                                    void (*cb)(void *ctx, u64 phys, u32 len),
                                                    void *ctx,
                                                    bool fresh);

/*
 * The walk's verdicts FREE (the scrub, rule 6), and it walks this node's
 * own in-core tree with no invalidate_lock: a held-back leaf is never
 * dropped, so even a fresh read returns this node's image mid-edit. An
 * extent-tree move (cetrafs_tree_move_begin()) can hide entries from a
 * walk that overlaps it, and a hidden data block reads as unreferenced.
 * So a walk that any move overlapped -- module-wide: the walk has no
 * inode in hand -- runs again, and after CETRAFS_TREE_MOVE_RERUNS tries
 * answers -EIO, which every caller takes as "references unknown" (the
 * scrub bails; nothing is freed). Re-running is harmless: the callbacks
 * only ADD a reference (scrub_mark_ref(), cetrafs_holds_cb()).
 */
int cetrafs_raw_inode_for_each_owned_block(struct super_block *sb,
                                           const cetrafs_inode_t *raw,
                                           void (*cb)(void *ctx, u64 phys, u32 len),
                                           void *ctx,
                                           bool fresh)
{
    int tries, ret = 0;

    for (tries = 0; tries <= CETRAFS_TREE_MOVE_RERUNS; tries++) {
        int b0 = atomic_read(&cetrafs_tree_moves_begun);
        int e0;

        smp_rmb();
        e0 = atomic_read(&cetrafs_tree_moves_ended);
        smp_rmb();
        ret = __cetrafs_raw_inode_for_each_owned_block(sb, raw, cb, ctx, fresh);
        smp_rmb();
        if (READ_ONCE(cetrafs_tree_move_rerun_off) ||
            (b0 == e0 && atomic_read(&cetrafs_tree_moves_begun) == b0))
            return ret;
        cetrafs_tree_move_backoff();
    }
    pr_err_ratelimited("owned-block walk: every pass overlapped an extent-tree move -- references unknown\n");
    return -EIO;
}

static int __cetrafs_raw_inode_for_each_owned_block(struct super_block *sb,
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
            for (li = 0;; li++) {
                u64 llba;

                /* One entry at a time under the buffer lock, released
                 * before the leaf's is taken (as in the lookup). */
                cetrafs_bh_read_lock(ibh);
                iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);
                llba = li < iln ? cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo) : 0;
                cetrafs_bh_read_unlock(ibh);
                if (li >= iln)
                    break;

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

struct cetrafs_holds_ctx {
    u64 lba;
    bool found;
};

static void cetrafs_holds_cb(void *p, u64 phys, u32 len)
{
    struct cetrafs_holds_ctx *h = p;

    if (h->lba >= phys && h->lba - phys < len)
        h->found = true;
}

/*
 * Does this record still reference 'lba' as one of its metadata blocks
 * -- its xattr block, an extent-tree leaf or index block, or (a
 * directory) a dirent block? The journal replay's owner check (L9): an
 * entry is redone only onto a block its owner still holds.
 *
 * Tree-block addresses are matched from the PARENT, before anything
 * reads the block: the target may be the torn leaf the replay exists to
 * repair, which no validating read would return. Interior blocks and a
 * directory's leaves are read forced-fresh. 0 with *held set or clear;
 * -EIO when a block on the way could not be read and the answer is not
 * known.
 */
int cetrafs_raw_inode_holds_meta_block(struct super_block *sb, const cetrafs_inode_t *raw, u64 lba, bool *held)
{
    struct cetrafs_holds_ctx h = {.lba = lba};
    bool unknown = false;
    u16 depth;
    u32 i, n;

    *held = false;
    if (raw->xattr_block && cetrafs_le64(raw->xattr_block) == lba) {
        *held = true;
        return 0;
    }
    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC)
        return -EIO;
    depth = cetrafs_le16(raw->eh.eh_depth);
    if (depth > CETRAFS_EXT_MAX_DEPTH)
        return -EIO;

    if (depth >= 1) {
        n = min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.idx));
        for (i = 0; i < n; i++) {
            u64 child = cetrafs_extent_phys_from_hilo(raw->et.idx[i].ei_leaf_hi, raw->et.idx[i].ei_leaf_lo);
            struct buffer_head *ibh;
            const cetrafs_extent_hdr_t *ihdr;
            const cetrafs_extent_idx_t *iarr;
            u32 li, iln;

            if (child == lba) {
                *held = true;
                return 0;
            }
            if (depth < 2)
                continue;
            ibh = cetrafs_scrub_tree_bread(sb, child, CETRAFS_INDEX_TAIL_MAGIC, true);
            if (!ibh) {
                unknown = true;
                continue;
            }
            ihdr = (const cetrafs_extent_hdr_t *) ibh->b_data;
            iarr = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));
            cetrafs_bh_read_lock(ibh);
            iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);
            for (li = 0; li < iln; li++)
                if (cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo) == lba)
                    h.found = true;
            cetrafs_bh_read_unlock(ibh);
            brelse(ibh);
            if (h.found) {
                *held = true;
                return 0;
            }
            cond_resched();
        }
    }

    /* A directory's dirent blocks are its data: walk its extents (a
     * directory's tree is at most one level deep). A regular file's
     * data is never journaled, so its extents are not looked at. */
    if (S_ISDIR(cetrafs_le32(raw->mode))) {
        int ret = cetrafs_raw_inode_for_each_owned_block(sb, raw, cetrafs_holds_cb, &h, true);

        if (h.found) {
            *held = true;
            return 0;
        }
        if (ret)
            unknown = true;
    }
    return unknown ? -EIO : 0;
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
cetrafs_test_param(extents_fetch_fail_once, cetrafs_extents_fetch_fail_once, bool, 0644);
MODULE_PARM_DESC(extents_fetch_fail_once, "TEST ONLY: the next extent-list fetch fails");

/* 'reader': see cetrafs_tree_flatten_for(). Only for a caller that
 * reports the map -- never one that frees, moves or writes by it. */
static int cetrafs_inode_extents_get_for(struct inode *inode, const cetrafs_inode_t *raw,
                                         struct cetrafs_inode_extents *ex, bool reader)
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

    if (cetrafs_le16(raw->eh.eh_depth) == 0) {
        ex->arr = raw->et.leaf;
        ex->entries = min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf));
        return 0;
    }

    if (cetrafs_le16(raw->eh.eh_depth) == 2) {
        int ret = cetrafs_tree_flatten_for(inode, raw, &ex->heap, &ex->entries, reader);

        if (ret)
            return ret;
        ex->arr = ex->heap;
        return 0;
    }

    leaf_lba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
    ex->leaf_bh = cetrafs_read_leaf_bh_for(inode, leaf_lba, reader);
    if (!ex->leaf_bh)
        return -EIO;

    ex->arr = (const cetrafs_extent_t *) (ex->leaf_bh->b_data + sizeof(cetrafs_extent_hdr_t));
    ex->entries = min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) ex->leaf_bh->b_data)->eh_entries),
                        CETRAFS_EXT_BLOCK_MAX_LEAVES);
    return 0;
}

int cetrafs_inode_extents_get(struct inode *inode, const cetrafs_inode_t *raw, struct cetrafs_inode_extents *ex)
{
    return cetrafs_inode_extents_get_for(inode, raw, ex, false);
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
 * not in logical order. Both walks therefore work on a sorted copy
 * (cetrafs_inode_sorted_runs() below), which also drops zero-length
 * (damaged) entries SEEK_DATA used to report as data. Assuming order in the array itself
 * would give confidently wrong answers on exactly the files (randomly
 * written VM images) this exists to serve.
 */
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
static int cetrafs_ext_run_cmp(const void *a, const void *b)
{
    const struct cetrafs_ext_run *x = a, *y = b;

    return x->start < y->start ? -1 : x->start > y->start;
}

static bool cetrafs_runs_overlap(const struct cetrafs_ext_run *r, u32 n);

/* Sorted maps reused from the inode, and built (procfs). */
static atomic64_t cetrafs_smap_hits = ATOMIC64_INIT(0);
static atomic64_t cetrafs_smap_builds = ATOMIC64_INIT(0);

u64 cetrafs_smap_hit_count(void)
{
    return (u64) atomic64_read(&cetrafs_smap_hits);
}

u64 cetrafs_smap_build_count(void)
{
    return (u64) atomic64_read(&cetrafs_smap_builds);
}

/* One tree block's term in cetrafs_tree_identity(): its eh_generation
 * and tail CRC beside its address, through an odd multiplier, so two
 * blocks' terms differ exactly when one of the three does. */
static u64 cetrafs_tree_block_identity(const struct buffer_head *bh, u64 lba)
{
    const cetrafs_blk_tail_t *t = (const cetrafs_blk_tail_t *) (bh->b_data + CETRAFS_BLK_TAIL_OFF);
    u64 stamp = ((u64) cetrafs_le32(((const cetrafs_extent_hdr_t *) bh->b_data)->eh_generation) << 32) |
                cetrafs_le32(t->crc);

    return (stamp ^ (lba * 0x9E3779B97F4A7C15ULL)) * 0xC2B2AE3D27D4EB4FULL;
}

void cetrafs_smap_put(struct cetrafs_smap *m)
{
    if (m && refcount_dec_and_test(&m->ref))
        kvfree(m);
}

/*
 * The identity of a depth-2 tree as this node can read it now: a fold of
 * every interior and leaf block's address, eh_generation and tail CRC.
 * Every edit of a tree block restamps both before the buffer is unlocked
 * (cetrafs_blk_tail_stamp(), under invalidate_lock held exclusively), a
 * block written elsewhere carries its writer's, and a block re-read from
 * the device carries what the device holds -- so a different tree gives
 * a different key unless a random 32-bit generation AND the CRC both
 * repeat. Read under the reader rule, like the walk it stands in for:
 * from cache when that is trusted, else from the device. The caller
 * holds invalidate_lock (shared at least), which keeps every editor out
 * while the headers are read (class 27).
 *
 * -EAGAIN for a tree that is not depth 2: small enough to sort per call.
 */
static int cetrafs_tree_identity(struct inode *inode, const cetrafs_inode_t *raw, u64 *out_key)
{
    u64 key = 0x5eed;
    u32 ni;

    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(raw->eh.eh_depth) != 2)
        return -EAGAIN;
    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh_for(inode, ilba, true);
        const cetrafs_extent_idx_t *iarr;
        u32 li, iln;

        if (!ibh)
            return -EIO;
        key ^= cetrafs_tree_block_identity(ibh, ilba);
        iarr = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(cetrafs_extent_hdr_t));
        iln = min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) ibh->b_data)->eh_entries),
                    CETRAFS_EXT_BLOCK_MAX_IDX);
        for (li = 0; li < iln; li++) {
            u64 llba = cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo);
            struct buffer_head *lbh = cetrafs_read_leaf_bh_for(inode, llba, true);

            if (!lbh) {
                brelse(ibh);
                return -EIO;
            }
            key ^= cetrafs_tree_block_identity(lbh, llba);
            brelse(lbh);
        }
        brelse(ibh);
    }
    *out_key = key;
    return 0;
}

/*
 * The extents of 'raw' in logical order, as a reference the caller puts
 * (cetrafs_smap_put()). Caller holds invalidate_lock, shared at least.
 *
 * A depth-2 tree's map is kept on the inode between calls and reused
 * while the tree's identity is unchanged (cetrafs_tree_identity()):
 * sorting a fragmented image's ~258k extents took ~47 ms, and filefrag
 * makes hundreds of FIEMAP calls, each of which sorted again -- 42 s of
 * CPU under the inode lock. Smaller trees are sorted per call.
 */
static int cetrafs_inode_sorted_runs(struct inode *inode, const cetrafs_inode_t *raw, struct cetrafs_smap **out)
{
    struct cetrafs_inode_extents ex;
    struct cetrafs_smap *m;
    struct cetrafs_ext_run *r;
    bool keyed;
    u64 key = 0;
    u32 i, n = 0;
    int ret;

    keyed = cetrafs_tree_identity(inode, raw, &key) == 0;
    if (keyed) {
        m = cetrafs_inode_smap_get(inode, key);
        if (m) {
            atomic64_inc(&cetrafs_smap_hits);
            *out = m;
            return 0;
        }
    }
    ret = cetrafs_inode_extents_get_for(inode, raw, &ex, true); /* reports the map only */
    if (ret)
        return ret;
    m = kvmalloc(struct_size(m, runs, max_t(u32, ex.entries, 1)), GFP_NOFS);
    if (!m) {
        cetrafs_inode_extents_put(&ex);
        return -ENOMEM;
    }
    refcount_set(&m->ref, 1);
    r = m->runs;
    for (i = 0; i < ex.entries; i++) {
        u64 l = cetrafs_extent_len(ex.arr[i].ee_len);

        if (!l) {
            pr_err_ratelimited("ino=%llu: extent at block %llu has zero length -- skipping it (fsck)\n",
                               (unsigned long long) inode->i_ino,
                               (unsigned long long) cetrafs_le32(ex.arr[i].ee_block));
            cetrafs_sb_corrupt_inode(inode);
            continue;
        }
        r[n].start = cetrafs_le32(ex.arr[i].ee_block);
        r[n].len = l;
        r[n].phys = cetrafs_extent_phys_from_hilo(ex.arr[i].ee_start_hi, ex.arr[i].ee_start_lo);
        r[n].uninit = cetrafs_extent_is_uninit(ex.arr[i].ee_len);
        n++;
    }
    cetrafs_inode_extents_put(&ex);
    sort(r, n, sizeof(*r), cetrafs_ext_run_cmp, NULL);
    m->n = n;
    m->overlap = cetrafs_runs_overlap(r, n);
    m->key = key;
    if (keyed)
        cetrafs_inode_smap_store(inode, m);
    atomic64_inc(&cetrafs_smap_builds);
    *out = m;
    return 0;
}

/*
 * PREALLOCATED extents (fallocate, `qemu-img create -o
 * preallocation=falloc`) read as zeros until written, so they are holes
 * to SEEK_DATA/SEEK_HOLE -- as on ext4 and XFS -- or a preallocated VM
 * image looks fully allocated to every sparse-aware copy (audit R22).
 *
 * Except where the page cache holds data for them. Calling DATA a hole
 * is the destructive direction: `cp --sparse` skips the range and the
 * copy loses it. So any cached folio over an uninit block makes that
 * block data -- even a clean one holding zeros (a needless copy, never a
 * lost one) -- and a tree whose runs overlap (damage; fsck) is answered
 * with every run treated as data, as before. A block converted by a
 * write is no longer uninit in the overlaid record we walk.
 */
#define CETRAFS_BLKS_PER_PAGE_SHIFT (PAGE_SHIFT - 12) /* CETRAFS_BLOCK_SIZE == 4096 */

/* First block in [from, end) whose page is in the page cache, or `end`. */
static noinline_for_stack u64 cetrafs_cached_first(struct address_space *m, u64 from, u64 end)
{
    pgoff_t idx = (pgoff_t) (from >> CETRAFS_BLKS_PER_PAGE_SHIFT);
    pgoff_t last = (pgoff_t) ((end - 1) >> CETRAFS_BLKS_PER_PAGE_SHIFT);
    struct folio_batch fb;
    u64 b = end;

    folio_batch_init(&fb);
    if (filemap_get_folios(m, &idx, last, &fb)) {
        b = max_t(u64, from, (u64) folio_pos(fb.folios[0]) / CETRAFS_BLOCK_SIZE);
        folio_batch_release(&fb);
    }
    return min(b, end);
}

/* First block in [from, end) whose page is NOT in the page cache, or `end`.
 * Walked by hand: page_cache_next_miss() returns 0 for "wrapped", which
 * is also the answer for a present page at index 0. */
static noinline_for_stack u64 cetrafs_cached_first_miss(struct address_space *m, u64 from, u64 end)
{
    pgoff_t idx = (pgoff_t) (from >> CETRAFS_BLKS_PER_PAGE_SHIFT);
    pgoff_t last = (pgoff_t) ((end - 1) >> CETRAFS_BLKS_PER_PAGE_SHIFT);
    pgoff_t want = idx;
    struct folio_batch fb;
    unsigned int n, i;

    folio_batch_init(&fb);
    while (want <= last && (n = filemap_get_folios(m, &idx, last, &fb))) {
        for (i = 0; i < n; i++) {
            struct folio *f = fb.folios[i];

            if (f->index > want)
                break; /* a gap before this folio */
            want = max_t(pgoff_t, want, f->index + folio_nr_pages(f));
        }
        folio_batch_release(&fb);
        if (i < n)
            break;
        cond_resched();
    }
    if (want > last)
        return end; /* every page in the range is cached */
    return min(max_t(u64, from, (u64) want << CETRAFS_BLKS_PER_PAGE_SHIFT), end);
}

/* First block in [from, end) in the pending set -- a buffered write's,
 * data though the tree still says preallocated (enum cetrafs_gb_mode)
 * -- or `end`. */
static u64 cetrafs_pending_first(struct inode *inode, u64 from, u64 end)
{
    u32 f, l;

    if (from > U32_MAX || cetrafs_pending_next(inode, (u32) from, &f, &l))
        return end;
    return min_t(u64, f, end);
}

/* First block in [from, end) that is neither cached nor pending, or `end`. */
static u64 cetrafs_unwritten_first(struct address_space *m, u64 from, u64 end)
{
    u64 h = from;

    for (;;) {
        u32 prun;

        h = cetrafs_cached_first_miss(m, h, end);
        if (h >= end || h > U32_MAX)
            return min(h, end);
        prun = cetrafs_pending_run(m->host, (u32) h);
        if (!prun)
            return h;
        h += prun; /* at least one: progress whatever the set says */
        cond_resched();
    }
}

/* Do any of the sorted runs overlap? (A damaged tree.) */
static bool cetrafs_runs_overlap(const struct cetrafs_ext_run *r, u32 n)
{
    u64 reach = 0;
    u32 i;

    for (i = 0; i < n; i++) {
        if (i && r[i].start < reach)
            return true;
        reach = max(reach, r[i].start + r[i].len);
    }
    return false;
}

/* First data block at or after `from`, over the sorted runs, or U64_MAX
 * if there is none. Disjoint and sorted, so the first answer is the
 * least; on overlapping runs `as_data` holds and the first run reaching
 * past `from` has the least start. */
static u64 cetrafs_next_data_block(struct address_space *m, const struct cetrafs_ext_run *r, u32 n, u64 from,
                                   bool as_data)
{
    u32 i;

    for (i = 0; i < n; i++) {
        u64 end = r[i].start + r[i].len, s, c;

        if (end <= from)
            continue; /* entirely behind us */
        s = max(r[i].start, from);
        if (!r[i].uninit || as_data)
            return s;
        c = min(cetrafs_cached_first(m, s, end), cetrafs_pending_first(m->host, s, end));
        if (c < end)
            return c;
        cond_resched();
    }
    return U64_MAX;
}

/* First hole block at or after `from`, over the sorted runs: one pass,
 * extending `from` across every run that covers it (runs may overlap on
 * a damaged tree, hence the max -- and `as_data`, so an uninit run's
 * cached tail is never skipped by an overlapping neighbour). */
static u64 cetrafs_next_hole_block(struct address_space *m, const struct cetrafs_ext_run *r, u32 n, u64 from,
                                   u64 nblocks, bool as_data)
{
    u32 i;

    for (i = 0; i < n && from < nblocks; i++) {
        u64 end = r[i].start + r[i].len;

        if (end <= from)
            continue; /* entirely behind us */
        if (r[i].start > from)
            break; /* a gap before the next run: `from` is the hole */
        if (r[i].uninit && !as_data) {
            u64 h = cetrafs_unwritten_first(m, from, end);

            if (h < end) {
                from = h; /* runs are disjoint: nothing else covers it */
                break;
            }
        }
        from = max(from, end);
        cond_resched();
    }
    return from < nblocks ? from : nblocks; /* EOF itself is the hole */
}

/*
 * The record and the map it names, read as one snapshot for SEEK_HOLE,
 * SEEK_DATA and FIEMAP (audit 2026-11-14 FD-4). Returns with
 * invalidate_lock held shared on success.
 *
 * The record must be read UNDER the lock: a convert that splits a full
 * leaf publishes a new root (a new leaf or interior under it) inside its
 * exclusive hold. A record read before the lock can name the old leaf,
 * which the convert has already shrunk, so the block it moved reads as
 * a hole. The lookup path is safe the same way (its tree-move sequence
 * re-runs). cetrafs_map_read_late restores the old order for the control
 * of tests/kernel/map_read_under_lock.sh.
 */
static bool cetrafs_map_read_late;
cetrafs_test_param(map_read_late, cetrafs_map_read_late, bool, 0644);
MODULE_PARM_DESC(map_read_late, "TEST ONLY: SEEK_HOLE/SEEK_DATA/FIEMAP read the record before taking invalidate_lock, as before FD-4");

static unsigned int cetrafs_map_read_pause_ms;
cetrafs_test_param(map_read_pause_ms, cetrafs_map_read_pause_ms, uint, 0644);
MODULE_PARM_DESC(map_read_pause_ms, "TEST ONLY: a SEEK_HOLE/SEEK_DATA/FIEMAP call sleeps this long between its record read and its walk");

static int cetrafs_map_snapshot_begin(struct inode *inode, cetrafs_inode_t *raw)
{
    struct address_space *m = inode->i_mapping;
    int ret;

    if (READ_ONCE(cetrafs_map_read_late)) {
        ret = cetrafs_read_raw_inode_overlaid(inode->i_sb, inode, raw); /* torn-read-safe vs a concurrent publish */
        if (ret)
            return ret;
        if (READ_ONCE(cetrafs_map_read_pause_ms))
            msleep(READ_ONCE(cetrafs_map_read_pause_ms));
        filemap_invalidate_lock_shared(m);
        return 0;
    }
    filemap_invalidate_lock_shared(m);
    ret = cetrafs_read_raw_inode_overlaid(inode->i_sb, inode, raw); /* torn-read-safe vs a concurrent publish */
    if (ret) {
        filemap_invalidate_unlock_shared(m);
        return ret;
    }
    if (READ_ONCE(cetrafs_map_read_pause_ms))
        msleep(READ_ONCE(cetrafs_map_read_pause_ms));
    return 0;
}

static loff_t cetrafs_seek_hole_data(struct file *file, loff_t offset, int whence)
{
    struct inode *inode = file->f_mapping->host;
    struct cetrafs_smap *m;
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

    /* The record and the leaves are read under invalidate_lock, shared
     * (cetrafs_map_snapshot_begin()); held across the walk too: it asks
     * the page cache about uninit blocks, which a concurrent convert
     * would change under it. */
    ret = cetrafs_map_snapshot_begin(inode, &raw);
    if (ret)
        goto out;
    ret = cetrafs_inode_sorted_runs(inode, &raw, &m);
    if (ret) {
        filemap_invalidate_unlock_shared(inode->i_mapping);
        goto out;
    }

    iblock = (u64) offset / CETRAFS_BLOCK_SIZE;
    nblocks = ((u64) isize + CETRAFS_BLOCK_SIZE - 1) / CETRAFS_BLOCK_SIZE;

    if (whence == SEEK_DATA) {
        found = cetrafs_next_data_block(inode->i_mapping, m->runs, m->n, iblock, m->overlap);
        if (found == U64_MAX || found >= nblocks)
            ret = -ENXIO; /* nothing but hole between here and EOF */
        else /* staying inside the block we were already in means the
              * answer is the caller's own offset, not the block boundary
              * below it */
            ret = (found == iblock) ? offset : (loff_t) (found * CETRAFS_BLOCK_SIZE);
    } else {
        found = cetrafs_next_hole_block(inode->i_mapping, m->runs, m->n, iblock, nblocks, m->overlap);
        ret = (found == iblock) ? offset : (loff_t) (found * CETRAFS_BLOCK_SIZE);
        if (ret > isize)
            ret = isize; /* EOF is a hole, but never report past it */
    }
    cetrafs_smap_put(m);
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
 * sorted once (cetrafs_inode_sorted_runs()) and walked. It used to be
 * rescanned per emitted extent, under a comment calling that "O(n^2) on
 * at most 343 entries" -- true of a depth-1 tree, not of a depth-2 one,
 * which holds ~258k.
 */
int cetrafs_fiemap(struct inode *inode, struct fiemap_extent_info *fi, u64 start, u64 len)
{
    const struct cetrafs_ext_run *runs;
    struct cetrafs_smap *m;
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

    /* The leaf is read in place, and its writers edit it under
     * invalidate_lock (cetrafs_tree_lookup_unchecked()). Held only
     * while the sorted map is fetched: the loop below copies to user
     * memory, which can fault on a mapping of this file. The map is
     * our own reference -- immutable, and freed only when its last
     * holder lets go -- so it needs no lock while it is walked. */
    ret = cetrafs_map_snapshot_begin(inode, &raw);
    if (ret)
        goto out;
    ret = cetrafs_inode_sorted_runs(inode, &raw, &m);
    filemap_invalidate_unlock_shared(inode->i_mapping);
    if (ret)
        goto out;
    runs = m->runs;
    nruns = m->n;

    /* In logical order (see cetrafs_inode_sorted_runs()): each step
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
        cond_resched(); /* O(extents) per call; ~258k on a fragmented image */

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
        if (r->uninit && cetrafs_pending_first(inode, r->start, r->start + r->len) >= r->start + r->len)
            flags |= FIEMAP_EXTENT_UNWRITTEN; /* a pending block in it: report data, never a hole */

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
    cetrafs_smap_put(m);

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
    struct cetrafs_free_batch fb;
    u16 i;

    /* Whole-extent frees, not per-block: besides fewer bitmap RMWs, a
     * free aimed at another node's ZG becomes ONE pending-free queue
     * entry per extent instead of one per block, and the batch packs
     * those entries into as few queue swaps as the queue takes -- see
     * cetrafs_free_data_extent_batched(). */
    cetrafs_free_batch_init(&fb);
    for (i = 0; i < entries; i++) {
        u64 phys = cetrafs_extent_phys_from_hilo(arr[i].ee_start_hi, arr[i].ee_start_lo);
        u32 len = cetrafs_extent_len(arr[i].ee_len);

        cetrafs_free_data_extent_batched(sb, phys, len, &fb);
    }
    cetrafs_free_batch_flush(sb, &fb);
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
    struct cetrafs_free_batch fb;
    u32 i;

    /* A large image is tens of thousands of extents: batched, so one queue
     * swap carries many of them when its owner is another node. */
    cetrafs_free_batch_init(&fb);
    for (i = 0; i < ex->entries; i++)
        cetrafs_free_data_extent_batched(sb, cetrafs_extent_phys_from_hilo(ex->arr[i].ee_start_hi, ex->arr[i].ee_start_lo),
                                         cetrafs_extent_len(ex->arr[i].ee_len), &fb);
    cetrafs_free_batch_flush(sb, &fb);
    if (cetrafs_le16(raw->eh.eh_depth) != 0)
        cetrafs_tree_free_meta(dir, raw);
}

void cetrafs_free_inline_extents(struct inode *dir, const cetrafs_inode_t *raw)
{
    struct super_block *sb = dir->i_sb;

    if (cetrafs_le16(raw->eh.eh_depth) == 0) {
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
            struct cetrafs_free_batch fb;
            u32 i;

            cetrafs_free_batch_init(&fb);
            for (i = 0; i < ex.entries; i++)
                cetrafs_free_data_extent_batched(sb,
                                                 cetrafs_extent_phys_from_hilo(ex.arr[i].ee_start_hi, ex.arr[i].ee_start_lo),
                                                 cetrafs_extent_len(ex.arr[i].ee_len), &fb);
            cetrafs_free_batch_flush(sb, &fb);
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
/* TEST ONLY: hold a walk between its leaf read and its store, so a suite
 * can drop the cache there (tests/kernel/ext_cache_fill_fenced.sh). */
static unsigned int cetrafs_ext_fill_stall_ms;
cetrafs_test_param(ext_fill_stall_ms, cetrafs_ext_fill_stall_ms, uint, 0644);
MODULE_PARM_DESC(ext_fill_stall_ms, "TEST ONLY: pause an extent walk between its leaf read and its cache store");

static void cetrafs_tree_remember(struct inode *inode, const cetrafs_inode_t *raw, const struct cetrafs_ext_span *span,
                                  u32 gen)
{
    if (span->uninit || !span->len)
        return;
    if (unlikely(cetrafs_ext_fill_stall_ms)) {
        pr_info("ino=%llu: TEST pause of %ums before an extent-cache store\n", (unsigned long long) inode->i_ino,
                cetrafs_ext_fill_stall_ms);
        msleep(cetrafs_ext_fill_stall_ms);
    }
    cetrafs_inode_ext_cache_store(inode, raw, span->block, span->len, span->lba, false, gen);
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
/* TEST ONLY: shrink a full leaf before the append's blocks are reserved,
 * as before audit 2026-11-14 FD-1 -- the control of
 * tests/kernel/convert_append_nospc.sh. */
static bool cetrafs_tree_resv_off;
cetrafs_test_param(tree_resv_off, cetrafs_tree_resv_off, bool, 0644);
MODULE_PARM_DESC(tree_resv_off, "TEST ONLY: a convert shrinks a full leaf without reserving the append's blocks");

struct cetrafs_convert_tail {
    u32 block;
    u64 lba;
    u32 len;
    bool may_append; /* the tree blocks for an append are reserved */
    struct inode *ino; /* the file being converted: a damaged extent marks it */
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
        /* Past the end THIS node knows of is first a question for the
         * layout: a peer may have grown the volume and allocated there
         * (cetrafs_sb_layout_refresh()). */
        if (len && phys + len > total_blocks) {
            int r = cetrafs_sb_layout_refresh(sb);

            if (r < 0 && (u64) eb + len <= CETRAFS_MAX_FILE_BLOCKS) {
                /* Cannot tell (GROWFS-LIVE-REVIEW H2): refused, not marked. */
                pr_warn_ratelimited("extent [block %u +%u] at lba %llu lies past this node's layout, which it "
                                    "cannot bring up to date (%d) -- refusing it, marking nothing\n",
                                    eb, len, (unsigned long long) phys, r);
                return -EIO;
            }
            if (r == 1) {
                raw_sb = cetrafs_sb_raw(sb);
                total_blocks = le64_to_cpu(raw_sb->total_blocks);
            }
        }
        if (len == 0 || (u64) eb + len > CETRAFS_MAX_FILE_BLOCKS || phys + len > total_blocks) {
            pr_err_ratelimited("extent [block %u +%u] at lba %llu does not fit the volume (%llu blocks) -- corrupt\n",
                               eb, len, (unsigned long long) phys, (unsigned long long) total_blocks);
            /* The inode, not the volume: its later writes are refused
             * (the write gate reads the mark), as for every other damaged
             * extent. A volume-only mark let the same file keep appending
             * through its damaged map (audit FD-9). */
            cetrafs_sb_corrupt_inode(tail_out->ino);
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
            count = 1;
            tail = len - head - 1;
            /* Every branch below but the first appends through the tree:
             * its blocks reserved before anything here is touched. */
            if (len != 1 && !tail_out->may_append && !READ_ONCE(cetrafs_tree_resv_off))
                return CETRAFS_CONVERT_NEED_ROOM;
            atomic64_inc(&cetrafs_convert_leaf_full);

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

            if (n + 2 > max && !tail_out->may_append && !READ_ONCE(cetrafs_tree_resv_off))
                return CETRAFS_CONVERT_NEED_ROOM; /* the append below, reserved first */
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
            int p, q;

            cetrafs_leaf_array_neighbours(arr, n, iblock, lba, count, &p, &q);
            if (len == count && p < 0 && q < 0) {
                /* The whole extent, and no written neighbour to grow:
                 * flip the flag where it stands. Dropping it and
                 * appending the written run moved the last entry into
                 * its slot -- and a buffered write converts every
                 * extent it made this way at the next fsync or close,
                 * so a file written in order came out of it scrambled,
                 * which the defrag mover reads as holes and declines. */
                arr[i].ee_len = cetrafs_extent_pack_len(len, false);
                *done = count;
                return 0;
            }
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
                if (unlikely(READ_ONCE(cetrafs_leaf_front_shrink_stall_ms))) {
                    /* TEST ONLY: the entry is half moved -- see the parameter. */
                    msleep(READ_ONCE(cetrafs_leaf_front_shrink_stall_ms));
                }
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
    struct cetrafs_free_batch fb;
    u32 i, kept = 0;
    u32 freed = 0;

    cetrafs_free_batch_init(&fb);
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
                cetrafs_free_data_extent_batched(sb, phys, len, &fb);
            freed += len;
            continue; /* drop the entry entirely */
        }

        if (end > new_block_count) {
            u32 new_len = (u32) (new_block_count - start);

            if (do_free)
                cetrafs_free_data_extent_batched(sb, phys + new_len, len - new_len, &fb);
            freed += len - new_len;
            arr[i].ee_len = cetrafs_extent_pack_len(new_len, uninit_entry);
        }

        if (kept != i)
            arr[kept] = arr[i];
        kept++;
    }
    /* The frees of this trim, queued before its caller's frees_end(). */
    cetrafs_free_batch_flush(sb, &fb);

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
    struct cetrafs_free_batch fb;
    u32 i, w, count = *entries;
    u32 freed = 0;
    u32 splits = 0;

    cetrafs_free_batch_init(&fb);

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
            cetrafs_free_data_extent_batched(sb, phys + (hs - estart), (u32) (he - hs), &fb);
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
                cetrafs_free_batch_flush(sb, &fb);
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
    /* The punch's frees, queued before its caller's frees_end(). */
    cetrafs_free_batch_flush(sb, &fb);

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
    hdr->eh_depth = cetrafs_cpu_to_le16(0);
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
    e->ei_pad = cetrafs_cpu_to_le16(0);
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
        e->ei_block_end = cetrafs_cpu_to_le32(0);
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
cetrafs_test_param(idx_range_ignore, cetrafs_idx_range_ignore, bool, 0644);
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
    u32 ni, egen;

    *found = false;
    if (out_uninit)
        *out_uninit = false;
    if (out_run)
        *out_run = 1;

    if (cetrafs_le16(raw->eh.eh_depth) == 0) {
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
    /* Sampled before the tree is read: a drop from here on refuses the
     * store below (class 41). */
    egen = cetrafs_inode_ext_cache_gen(inode);

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
            cetrafs_tree_remember(inode, raw, &span, egen);
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

        for (li = 0;;) {
            u64 llba;
            struct buffer_head *lbh;
            const cetrafs_extent_hdr_t *lhdr;
            cetrafs_extent_idx_t ie;

            /* The next entry whose range may hold the block, found under
             * ONE hold of the interior's buffer lock and copied out; the
             * lock is released before the leaf is locked: never two at
             * once. Taking the lock per entry was ~160 lock round trips
             * per lookup on a fragmented image -- most of its cost once
             * the ranges let it read about one leaf.
             *
             * THE point of ei_block_end: a leaf whose range excludes
             * this block is never read. Without it the walk read every
             * leaf until it hit -- ~56 of 113 on a fragmented VM image,
             * per mapped block. */
            cetrafs_bh_read_lock(ibh);
            iln = min_t(u32, cetrafs_le16(ihdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);
            while (li < iln && !cetrafs_idx_may_hold(&iarr[li], iblock))
                li++;
            if (li < iln)
                ie = iarr[li];
            cetrafs_bh_read_unlock(ibh);
            if (li >= iln)
                break;
            li++;
            cetrafs_lookup_stall(inode, iblock); /* test-only; see the knob */
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
                cetrafs_tree_remember(inode, raw, &span, egen);
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

    ret = cetrafs_lba_run_check(inode->i_sb, *out_lba, out_run ? *out_run : 1);
    if (ret == -EAGAIN) {
        *found = false;
        return -EIO; /* past a layout this node cannot catch up with: not damage */
    }
    if (ret) {
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

    if (cetrafs_le16(raw->eh.eh_depth) == 0)
        return cetrafs_leaf_array_next_contig_lba(
            raw->et.leaf, min_t(u16, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf)));
    if (cetrafs_le16(raw->eh.eh_entries) == 0)
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
        if (cetrafs_le16(h->eh_entries) == 0) {
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

/*
 * For cetrafs_frees_begin(): is every block cetrafs_tree_free_meta()
 * would free for 'raw' in a Block Group this node owns? The same walk:
 * depth 1 is the one leaf, depth 2 the interiors and every leaf they
 * name. An interior that cannot be read reads "not ours" -- the safe
 * answer, the one that announces.
 */
bool cetrafs_tree_meta_is_ours(struct inode *inode, const cetrafs_inode_t *raw)
{
    struct super_block *sb = inode->i_sb;
    u32 ni;

    if (cetrafs_le16(raw->eh.eh_depth) == 1)
        return cetrafs_lba_run_is_ours(
            sb, cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo), 1);
    if (cetrafs_le16(raw->eh.eh_depth) != 2)
        return true;

    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        struct buffer_head *ibh;
        const cetrafs_extent_hdr_t *h;
        const cetrafs_extent_idx_t *ia;
        u32 li, n;
        bool ours = true;

        if (!cetrafs_lba_run_is_ours(sb, ilba, 1))
            return false;
        ibh = cetrafs_read_index_bh(inode, ilba);
        if (!ibh)
            return false;
        h = (const cetrafs_extent_hdr_t *) ibh->b_data;
        ia = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*h));
        n = min_t(u32, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);
        for (li = 0; li < n && ours; li++)
            ours = cetrafs_lba_run_is_ours(sb, cetrafs_extent_phys_from_hilo(ia[li].ei_leaf_hi, ia[li].ei_leaf_lo), 1);
        brelse(ibh);
        if (!ours)
            return false;
    }
    return true;
}

/*
 * For cetrafs_frees_begin(): is every block 'arr' maps at logical
 * offsets [from, to) in a Block Group this node owns? The data a
 * truncate (to = U64_MAX) or a punch drops. Only the extents that
 * overlap are looked up, so a punch in a large image costs a few
 * descriptor reads, not one per extent.
 */
bool cetrafs_flat_range_is_ours(struct super_block *sb, const cetrafs_extent_t *arr, u32 n, u64 from, u64 to)
{
    u32 i;

    for (i = 0; i < n; i++) {
        u64 start = cetrafs_le32(arr[i].ee_block);
        u64 end = start + cetrafs_extent_len(arr[i].ee_len);
        u64 s, e;

        if (end <= from || start >= to)
            continue;
        s = max(start, from);
        e = min(end, to);
        if (!cetrafs_lba_run_is_ours(
                sb, cetrafs_extent_phys_from_hilo(arr[i].ee_start_hi, arr[i].ee_start_lo) + (s - start), e - s))
            return false;
    }
    return true;
}

/* Total extent count across all depths -- reads interior/leaf HEADERS
 * only (no extent copy), so the defrag trigger and close-time nudge can
 * feed cetrafs_frag_index_pct() the real number for a depth-2 file.
 *
 * 'reader': the count only decides whether to QUEUE a defrag, which
 * reads the tree again under its own lock -- so it may trust the cache
 * as a reader does (cetrafs_tree_flatten_for()). The close-time nudge
 * runs after the write lock is cleared, and under the write lock's
 * question it read every tree block from the device on every close of
 * a fragmented file. */
u32 cetrafs_tree_extent_count_for(struct inode *inode, const cetrafs_inode_t *raw, bool reader)
{
    u32 ni, total = 0;

    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC)
        return 0;
    if (cetrafs_le16(raw->eh.eh_depth) == 0)
        return min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.leaf));
    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        u64 llba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
        struct buffer_head *lbh = cetrafs_read_leaf_bh_for(inode, llba, reader);

        if (lbh) {
            total = min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) lbh->b_data)->eh_entries),
                          CETRAFS_EXT_BLOCK_MAX_LEAVES);
            brelse(lbh);
        }
        return total;
    }
    for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh_for(inode, ilba, reader);

        if (ibh) {
            const cetrafs_extent_hdr_t *h = (const cetrafs_extent_hdr_t *) ibh->b_data;
            const cetrafs_extent_idx_t *ia = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*h));
            u32 li, n = min_t(u32, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);

            for (li = 0; li < n; li++) {
                u64 llba = cetrafs_extent_phys_from_hilo(ia[li].ei_leaf_hi, ia[li].ei_leaf_lo);
                struct buffer_head *lbh = cetrafs_read_leaf_bh_for(inode, llba, reader);

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

u32 cetrafs_tree_extent_count(struct inode *inode, const cetrafs_inode_t *raw)
{
    return cetrafs_tree_extent_count_for(inode, raw, false);
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
/*
 * The most extents the depth-2 tree can hold: the inode's root slots,
 * each an interior block of leaf pointers, each leaf full. One number for
 * the builder that refuses past it and the planner that must stop before
 * it (cetrafs_do_allocate()). TEST ONLY tree_extent_cap lowers it, so a
 * suite can reach it on a loop device a fraction of the size.
 */
static unsigned int cetrafs_tree_extent_cap;
cetrafs_test_param(tree_extent_cap, cetrafs_tree_extent_cap, uint, 0644);
MODULE_PARM_DESC(tree_extent_cap, "TEST ONLY: treat the extent tree as full at this many extents");

static u32 cetrafs_tree_max_extents(void)
{
    u64 cap = (u64) ARRAY_SIZE(((cetrafs_inode_t *) NULL)->et.idx) * CETRAFS_EXT_BLOCK_MAX_IDX *
              CETRAFS_EXT_BLOCK_MAX_LEAVES;
    unsigned int knob = READ_ONCE(cetrafs_tree_extent_cap);

    if (knob && knob < cap)
        cap = knob;
    return (u32) min_t(u64, cap, U32_MAX);
}

/* TEST ONLY: depth-2 rebuilds pack every leaf full, as before G-3's slack
 * (tests/kernel/rebuild_leaf_slack.sh). */
static bool cetrafs_tree_build_full;
cetrafs_test_param(tree_build_full, cetrafs_tree_build_full, bool, 0644);
MODULE_PARM_DESC(tree_build_full, "TEST ONLY: tree rebuilds pack every leaf full (no slack)");

int cetrafs_tree_build(struct inode *inode, const cetrafs_extent_t *flat, u32 n, cetrafs_inode_t *raw, u64 *out_meta)
{
    /* The whole map is being rewritten. This is also the choke point
     * that covers a defrag RELOCATION -- the one mutation that can
     * leave depth, entry count and block count all identical while
     * every extent moves, so the key alone would not catch it. */
    cetrafs_inode_ext_cache_drop(inode);

    struct super_block *sb = inode->i_sb;
    u32 nleaves, ninter, bg, i, j, off, leaf_fill;
    u64 *blk = NULL; /* [0..nleaves) leaves, [nleaves..) interiors */
    u32 allocated = 0, total;
    int ret;

    *out_meta = 0;
    if (n > cetrafs_tree_max_extents())
        return -ENOSPC;

    if (n <= ARRAY_SIZE(raw->et.leaf)) {
        memset(&raw->et, 0, sizeof(raw->et));
        raw->eh.eh_depth = cetrafs_cpu_to_le16(0);
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

            ret = cetrafs_tree_block_anywhere(sb, &bg, &lba);
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

    /*
     * depth 2. Leaves are filled to three quarters, not to the brim: a
     * convert that splits an extent inside a FULL leaf shrinks it there
     * and appends the rest to the tree's last leaf, so a rebuild that
     * packed every leaf full turned the next scatter of first writes
     * into a split per write (audit 2026-11-15 G-3). The slack goes
     * only as far as the tree's capacity allows: a map too large for
     * three-quarter leaves gets the fill it needs to fit.
     */
    {
        u32 fill = CETRAFS_EXT_BLOCK_MAX_LEAVES;

        if (!READ_ONCE(cetrafs_tree_build_full)) {
            u32 cap_leaves = (u32) ARRAY_SIZE(raw->et.idx) * CETRAFS_EXT_BLOCK_MAX_IDX;

            fill = max_t(u32, CETRAFS_EXT_BLOCK_MAX_LEAVES * 3 / 4, (u32) CETRAFS_DIV_ROUND_UP(n, cap_leaves));
            fill = min_t(u32, fill, CETRAFS_EXT_BLOCK_MAX_LEAVES);
        }
        leaf_fill = fill;
        nleaves = (u32) CETRAFS_DIV_ROUND_UP(n, fill);
    }
    ninter = (u32) CETRAFS_DIV_ROUND_UP(nleaves, CETRAFS_EXT_BLOCK_MAX_IDX);
    if (ninter > ARRAY_SIZE(raw->et.idx))
        return -ENOSPC;
    total = nleaves + ninter;

    blk = kvmalloc_array(total, sizeof(*blk), GFP_NOFS);
    if (!blk)
        return -ENOMEM;

    for (allocated = 0; allocated < total; allocated++) {
        ret = cetrafs_tree_block_anywhere(sb, &bg, &blk[allocated]);
        if (ret)
            goto fail;
    }

    /* write leaves */
    off = 0;
    for (i = 0; i < nleaves; i++) {
        u32 cnt = min_t(u32, n - off, leaf_fill);

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
                u32 fe = lf * leaf_fill; /* first extent in that leaf */

                {
                    u32 cnt_in_leaf = min_t(u32, n - fe, leaf_fill);
                    u32 lo, hi;

                    cetrafs_leaf_array_range(flat + fe, (u16) cnt_in_leaf, &lo, &hi);
                    /* The tree's last leaf is the one appends go to:
                     * unknown, never a range a later append must widen
                     * (cetrafs_tree_append()). */
                    if (lf == nleaves - 1)
                        lo = hi = 0;
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
 * Remove [start, end) from a depth-2 tree by copying only what changes
 * (audit 2026-11-15 A-11, G-2). cetrafs_tree_build() writes every leaf
 * and interior of the file for a punch or a truncate, so one guest
 * discard on a fragmented image cost hundreds of synchronous writes with
 * the file's every I/O waiting. Here a leaf the range does not touch is
 * kept as it is, by reference; a touched leaf is written as a NEW block
 * holding its edited array (or dropped when nothing is left in it); an
 * interior naming a new or dropped leaf is written new too; the root
 * names the result. Copy-on-write, exactly as the rebuild: the old tree
 * is intact on the device until the caller publishes, and its blocks the
 * new one no longer names go only after (cetrafs_tree_free_meta_except()).
 *
 * What it reuses must be ON THE DEVICE before a record naming it is
 * (rule 8): this inode's held-back tree blocks are written first, in the
 * boundary's own journal batch.
 *
 * 0: raw's root names the new tree, *out_meta its leaf + interior count.
 * -EAGAIN: not a case for a patch (not depth 2, small enough that a
 * rebuild is one block, a split in a full leaf, nothing left); the caller
 * rebuilds, nothing was allocated. Other: failed, nothing allocated
 * survives, raw untouched. want_n / want_data are the caller's flattened
 * answer; a patch that disagrees is refused (-EAGAIN, and a WARN).
 */
static bool cetrafs_tree_patch_off;
cetrafs_test_param(tree_patch_off, cetrafs_tree_patch_off, bool, 0644);
MODULE_PARM_DESC(tree_patch_off, "TEST ONLY: punch, truncate and fallocate rebuild the whole extent tree, as before G-2");

/* TEST ONLY: the patch reuses held-back blocks without writing them
 * first (tests/kernel/punch_tree_patch.sh's control). */
static bool cetrafs_tree_patch_no_flush;
cetrafs_test_param(tree_patch_no_flush, cetrafs_tree_patch_no_flush, bool, 0644);
MODULE_PARM_DESC(tree_patch_no_flush, "TEST ONLY: a tree patch does not write the inode's held-back tree blocks first");

static atomic64_t cetrafs_tree_patches = ATOMIC64_INIT(0);
static atomic64_t cetrafs_tree_patch_writes = ATOMIC64_INIT(0);

u64 cetrafs_tree_patch_count(void)
{
    return (u64) atomic64_read(&cetrafs_tree_patches);
}

u64 cetrafs_tree_patch_write_count(void)
{
    return (u64) atomic64_read(&cetrafs_tree_patch_writes);
}

static bool cetrafs_tree_idx_has_room(u32 entries); /* the append's own cap (TEST ONLY tree_idx_cap) */

struct cetrafs_tree_patch_ws {
    cetrafs_extent_idx_t idx[4][CETRAFS_EXT_BLOCK_MAX_IDX]; /* each interior's entries, edited */
    cetrafs_extent_t leaf[CETRAFS_EXT_BLOCK_MAX_LEAVES];
};

int cetrafs_tree_patch(struct inode *inode, cetrafs_inode_t *raw, u64 start, u64 end, const cetrafs_extent_t *add,
                       u32 add_n, u32 want_n, u64 want_data, u64 *out_meta)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_tree_patch_ws *ws = NULL;
    u32 icnt[4] = {0}, nroot, nr, r, kept_roots = 0, bg;
    bool ichanged[4] = {false};
    u64 newint[4] = {0};
    u64 *newblk = NULL, meta = 0, total_data = 0, total_n = 0;
    u32 nnew = 0, cap = 0, i, joined = 0;
    int ret;

    BUILD_BUG_ON(ARRAY_SIZE(raw->et.idx) != 4);
    *out_meta = 0;
    /* want_n U32_MAX: the caller cannot say how many entries result
     * (defrag: whether its pieces merge with what the tree holds); the
     * data-block total is still checked, and a full root still refuses. */
    if (READ_ONCE(cetrafs_tree_patch_off) || !S_ISREG(inode->i_mode) || cetrafs_le16(raw->eh.eh_depth) != 2 ||
        (want_n != U32_MAX && (want_n <= CETRAFS_EXT_BLOCK_MAX_LEAVES || want_n > cetrafs_tree_max_extents())))
        return -EAGAIN;
    nroot = cetrafs_le16(raw->eh.eh_entries);
    if (nroot == 0 || nroot > ARRAY_SIZE(raw->et.idx))
        return -EAGAIN;
    lockdep_assert_held_write(&inode->i_mapping->invalidate_lock);

    if (!READ_ONCE(cetrafs_tree_patch_no_flush) && cetrafs_deferred_inode_pending(inode)) {
        ret = cetrafs_deferred_flush_inode(inode, true);
        if (ret)
            return ret;
    }
    cetrafs_inode_ext_cache_drop(inode);

    ws = kvmalloc(sizeof(*ws), GFP_NOFS);
    if (!ws)
        return -ENOMEM;
    for (r = 0; r < nroot; r++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[r].ei_leaf_hi, raw->et.idx[r].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh(inode, ilba);
        const cetrafs_extent_hdr_t *h;

        if (!ibh) {
            ret = -EIO;
            goto fail;
        }
        h = (const cetrafs_extent_hdr_t *) ibh->b_data;
        icnt[r] = min_t(u32, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);
        memcpy(ws->idx[r], ibh->b_data + sizeof(*h), (size_t) icnt[r] * sizeof(ws->idx[r][0]));
        brelse(ibh);
        cap += icnt[r];
    }
    /* Every leaf rewritten, the appends' leaves, every interior. */
    cap += 1 + add_n / (CETRAFS_EXT_BLOCK_MAX_LEAVES / 2) + 1 + ARRAY_SIZE(raw->et.idx);
    newblk = kvmalloc_array(cap, sizeof(*newblk), GFP_NOFS);
    if (!newblk) {
        ret = -ENOMEM;
        goto fail;
    }

    for (r = 0; r < nroot; r++) {
        u32 li, w = 0;

        for (li = 0; li < icnt[r]; li++) {
            u64 llba = cetrafs_extent_phys_from_hilo(ws->idx[r][li].ei_leaf_hi, ws->idx[r][li].ei_leaf_lo);
            struct buffer_head *lbh = cetrafs_read_leaf_bh(inode, llba);
            const cetrafs_extent_hdr_t *h;
            u32 cnt, n2, freed = 0, lo, hi;
            u64 nl;

            if (!lbh) {
                ret = -EIO;
                goto fail;
            }
            h = (const cetrafs_extent_hdr_t *) lbh->b_data;
            cnt = min_t(u32, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);
            memcpy(ws->leaf, lbh->b_data + sizeof(*h), (size_t) cnt * sizeof(ws->leaf[0]));
            brelse(lbh);
            n2 = cnt;
            ret = cetrafs_leaf_array_punch(sb, ws->leaf, &n2, CETRAFS_EXT_BLOCK_MAX_LEAVES, start, end, &freed,
                                           /*do_free=*/false);
            if (ret == -ENOSPC) {
                ret = -EAGAIN; /* a split with no slot in its leaf: the rebuild redistributes */
                goto fail;
            }
            if (ret)
                goto fail;
            total_n += n2;
            total_data += cetrafs_flat_data_blocks(ws->leaf, n2);
            /* Nothing overlapped: freed counts every block the range took
             * out, and a split always takes one. */
            if (!freed) {
                ws->idx[r][w++] = ws->idx[r][li];
                meta++;
                continue;
            }
            ichanged[r] = true;
            if (!n2)
                continue; /* emptied: its interior no longer names it */
            ret = cetrafs_tree_block_anywhere(sb, &bg, &nl);
            if (ret)
                goto fail;
            newblk[nnew++] = nl;
            ret = cetrafs_write_new_leaf(sb, nl, ws->leaf, (u16) n2);
            if (ret)
                goto fail;
            cetrafs_leaf_array_range(ws->leaf, (u16) n2, &lo, &hi);
            cetrafs_idx_set(&ws->idx[r][w++], lo, hi, nl);
            meta++;
            cond_resched();
        }
        icnt[r] = w;
    }

    if (WARN_ON_ONCE((want_n != U32_MAX && total_n + add_n != want_n) ||
                     total_data + cetrafs_flat_data_blocks(add, add_n) != want_data)) {
        pr_err("ino=%llu: the tree's leaves hold %llu extent(s) / %llu block(s) after the edit, the flattened map "
               "%u / %llu -- rebuilding from the map\n",
               (unsigned long long) inode->i_ino, total_n + add_n, total_data + cetrafs_flat_data_blocks(add, add_n),
               want_n, want_data);
        ret = -EAGAIN;
        goto fail;
    }

    /*
     * Appends go where cetrafs_tree_append() puts them: the free slots of
     * the tree's last leaf (a copy of it), then new leaves after it --
     * filled as a rebuild fills them, a quarter free -- in the last
     * interior, or a new one when that is full. The last leaf's range is
     * UNKNOWN, as every last leaf's is; a leaf that stops being last
     * keeps the range it had, which is either exact or unknown.
     */
    nr = nroot;
    if (add_n) {
        u32 rl = nroot, ai = 0, fill = CETRAFS_EXT_BLOCK_MAX_LEAVES;

        if (!READ_ONCE(cetrafs_tree_build_full))
            fill = CETRAFS_EXT_BLOCK_MAX_LEAVES * 3 / 4;
        while (rl > 0 && !icnt[rl - 1])
            rl--;
        if (!rl) {
            ret = -EAGAIN;
            goto fail;
        }
        rl--;
        {
            cetrafs_extent_idx_t *last = &ws->idx[rl][icnt[rl] - 1];
            u64 llba = cetrafs_extent_phys_from_hilo(last->ei_leaf_hi, last->ei_leaf_lo);
            struct buffer_head *lbh = cetrafs_read_leaf_bh(inode, llba);
            const cetrafs_extent_hdr_t *h;
            u32 cnt, take, merged = 0;
            u64 nl;

            if (!lbh) {
                ret = -EIO;
                goto fail;
            }
            h = (const cetrafs_extent_hdr_t *) lbh->b_data;
            cnt = min_t(u32, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);
            memcpy(ws->leaf, lbh->b_data + sizeof(*h), (size_t) cnt * sizeof(ws->leaf[0]));
            brelse(lbh);
            /* The first append continuing the leaf's last entry --
             * logically, physically and in kind -- extends it: defrag's
             * steps each add the next piece of one run. */
            if (cnt) {
                cetrafs_extent_t *le = &ws->leaf[cnt - 1];
                u32 llen = cetrafs_extent_len(le->ee_len), alen = cetrafs_extent_len(add[0].ee_len);
                bool un = cetrafs_extent_is_uninit(le->ee_len);

                if ((u64) cetrafs_le32(le->ee_block) + llen == cetrafs_le32(add[0].ee_block) &&
                    cetrafs_extent_phys_from_hilo(le->ee_start_hi, le->ee_start_lo) + llen ==
                        cetrafs_extent_phys_from_hilo(add[0].ee_start_hi, add[0].ee_start_lo) &&
                    un == cetrafs_extent_is_uninit(add[0].ee_len) && (u64) llen + alen <= CETRAFS_EXT_LEN_MASK) {
                    le->ee_len = cetrafs_extent_pack_len(llen + alen, un);
                    merged = 1;
                    joined = 1;
                }
            }
            take = min_t(u32, CETRAFS_EXT_BLOCK_MAX_LEAVES - cnt, add_n - merged);
            if (take || merged) {
                memcpy(ws->leaf + cnt, add + merged, (size_t) take * sizeof(ws->leaf[0]));
                ret = cetrafs_tree_block_anywhere(sb, &bg, &nl);
                if (ret)
                    goto fail;
                newblk[nnew++] = nl;
                ret = cetrafs_write_new_leaf(sb, nl, ws->leaf, (u16) (cnt + take));
                if (ret)
                    goto fail;
                /* A last leaf this call already rewrote (the removal
                 * above) is replaced again: that copy was never named by
                 * anything published, so it goes back now. */
                for (i = 0; i + 1 < nnew; i++)
                    if (newblk[i] == llba) {
                        cetrafs_free_data_block(sb, llba);
                        newblk[i] = newblk[--nnew - 1];
                        newblk[nnew - 1] = nl;
                        break;
                    }
                cetrafs_idx_set(last, 0, 0 /* the last leaf: unknown */, nl);
                ichanged[rl] = true;
                ai = merged + take;
            }
        }
        while (ai < add_n) {
            u32 cnt = min_t(u32, fill, add_n - ai), lo, hi;
            u64 nl;

            if (icnt[rl] >= CETRAFS_EXT_BLOCK_MAX_IDX || !cetrafs_tree_idx_has_room(icnt[rl])) {
                if (nr >= ARRAY_SIZE(raw->et.idx)) {
                    ret = -EAGAIN; /* no root slot: the rebuild repacks */
                    goto fail;
                }
                rl = nr++;
                icnt[rl] = 0;
            }
            ret = cetrafs_tree_block_anywhere(sb, &bg, &nl);
            if (ret)
                goto fail;
            newblk[nnew++] = nl;
            ret = cetrafs_write_new_leaf(sb, nl, add + ai, (u16) cnt);
            if (ret)
                goto fail;
            cetrafs_leaf_array_range(add + ai, (u16) cnt, &lo, &hi);
            cetrafs_idx_set(&ws->idx[rl][icnt[rl]++], lo, hi, nl);
            ichanged[rl] = true;
            meta++;
            ai += cnt;
            cond_resched();
        }
        ws->idx[rl][icnt[rl] - 1].ei_block = cetrafs_cpu_to_le32(0);
        ws->idx[rl][icnt[rl] - 1].ei_block_end = cetrafs_cpu_to_le32(0); /* the last leaf: unknown */
        ichanged[rl] = true;
    }

    /* Small enough for one leaf or the record: the rebuild gives it the
     * depth it needs (a defragmented file ends as one extent, not a
     * depth-2 tree holding one). */
    if (total_n + add_n - joined <= CETRAFS_EXT_BLOCK_MAX_LEAVES) {
        ret = -EAGAIN;
        goto fail;
    }

    for (r = 0; r < nr; r++) {
        if (!icnt[r])
            continue; /* every leaf of it emptied: the root no longer names it */
        kept_roots++;
        meta++;
        if (!ichanged[r])
            continue;
        ret = cetrafs_tree_block_anywhere(sb, &bg, &newint[r]);
        if (ret)
            goto fail;
        newblk[nnew++] = newint[r];
        ret = cetrafs_write_new_index(sb, newint[r], ws->idx[r], (u16) icnt[r]);
        if (ret)
            goto fail;
    }
    if (!kept_roots) {
        ret = -EAGAIN;
        goto fail;
    }

    {
        cetrafs_extent_idx_t root[4];
        u32 k = 0;

        for (r = 0; r < nr; r++) {
            if (!icnt[r])
                continue;
            if (ichanged[r])
                cetrafs_idx_set(&root[k], 0, 0 /* root: unknown */, newint[r]);
            else
                root[k] = raw->et.idx[r];
            k++;
        }
        memset(&raw->et, 0, sizeof(raw->et));
        memcpy(raw->et.idx, root, (size_t) k * sizeof(root[0]));
        raw->eh.eh_entries = cetrafs_cpu_to_le16((u16) k);
    }
    atomic64_inc(&cetrafs_tree_patches);
    atomic64_add(nnew, &cetrafs_tree_patch_writes);
    *out_meta = meta;
    kvfree(newblk);
    kvfree(ws);
    return 0;

fail:
    /* Written, never named by anything published: back to the allocator. */
    for (i = 0; i < nnew; i++)
        cetrafs_free_data_block(sb, newblk[i]);
    kvfree(newblk);
    kvfree(ws);
    return ret;
}

static int cetrafs_u64_cmp(const void *a, const void *b)
{
    u64 x = *(const u64 *) a, y = *(const u64 *) b;

    return x < y ? -1 : x > y;
}

/* The leaf and interior blocks of a depth-1/2 tree, sorted. */
static int cetrafs_tree_meta_set(struct inode *inode, const cetrafs_inode_t *raw, u64 **out, u32 *out_n)
{
    u32 ni, n = 0, cap = 1 + ARRAY_SIZE(raw->et.idx) * (1 + CETRAFS_EXT_BLOCK_MAX_IDX);
    u64 *set;

    *out = NULL;
    *out_n = 0;
    set = kvmalloc_array(cap, sizeof(*set), GFP_NOFS);
    if (!set)
        return -ENOMEM;
    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        set[n++] = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
    } else if (cetrafs_le16(raw->eh.eh_depth) == 2) {
        for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx); ni++) {
            u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
            struct buffer_head *ibh = cetrafs_read_index_bh(inode, ilba);
            const cetrafs_extent_hdr_t *h;
            const cetrafs_extent_idx_t *ia;
            u32 li, in;

            if (!ibh) {
                kvfree(set);
                return -EIO;
            }
            h = (const cetrafs_extent_hdr_t *) ibh->b_data;
            ia = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*h));
            in = min_t(u32, cetrafs_le16(h->eh_entries), CETRAFS_EXT_BLOCK_MAX_IDX);
            set[n++] = ilba;
            for (li = 0; li < in; li++)
                set[n++] = cetrafs_extent_phys_from_hilo(ia[li].ei_leaf_hi, ia[li].ei_leaf_lo);
            brelse(ibh);
        }
    }
    sort(set, n, sizeof(*set), cetrafs_u64_cmp, NULL);
    *out = set;
    *out_n = n;
    return 0;
}

/*
 * Free the tree meta of 'raw' that 'keep' does not also name: the old
 * tree after a patch was published (keep = the new one), or a patch's new
 * blocks when its publish failed (keep = the old one). For a rebuild the
 * two share nothing and this is cetrafs_tree_free_meta(). When 'keep'
 * cannot be read, nothing is freed: a leak the scrub reclaims, never a
 * block a published tree still names.
 */
void cetrafs_tree_free_meta_except(struct inode *inode, const cetrafs_inode_t *raw, const cetrafs_inode_t *keep)
{
    struct super_block *sb = inode->i_sb;
    u64 *ks, *rs;
    u32 kn, rn, i;

    if (cetrafs_tree_meta_set(inode, keep, &ks, &kn)) {
        pr_warn_ratelimited("ino=%llu: the kept extent tree could not be read -- its old blocks are left for the "
                            "scrub\n",
                            (unsigned long long) inode->i_ino);
        return;
    }
    if (!kn) {
        kvfree(ks);
        cetrafs_tree_free_meta(inode, raw);
        return;
    }
    if (cetrafs_tree_meta_set(inode, raw, &rs, &rn)) {
        kvfree(ks);
        pr_warn_ratelimited("ino=%llu: the replaced extent tree could not be read -- its blocks are left for the "
                            "scrub\n",
                            (unsigned long long) inode->i_ino);
        return;
    }
    for (i = 0; i < rn; i++)
        if (!bsearch(&rs[i], ks, kn, sizeof(*ks), cetrafs_u64_cmp))
            cetrafs_free_data_block(sb, rs[i]);
    kvfree(rs);
    kvfree(ks);
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
/* Converts whose leaf had no room for the split: the piece went to the
 * tree's last leaf instead (G-3: what a rebuild's slack saves). */
static atomic64_t cetrafs_convert_spills = ATOMIC64_INIT(0);

u64 cetrafs_convert_spill_count(void)
{
    return (u64) atomic64_read(&cetrafs_convert_spills);
}

static int cetrafs_tree_convert_append(struct inode *inode,
                                       cetrafs_inode_t *raw,
                                       u32 iblock,
                                       u64 lba,
                                       const struct cetrafs_convert_tail *tail)
{
    bool merged = false;
    u32 leaf_count = 0;
    int ret, tret = 0;

    atomic64_inc(&cetrafs_convert_spills);
    cetrafs_tree_mark_convert_append(inode, true);
    ret = cetrafs_tree_append(inode, raw, iblock, lba, 1, /*uninit=*/false, &merged, &leaf_count);
    cetrafs_tree_mark_convert_append(inode, false);
    if (!ret && tail->len)
        tret = cetrafs_tree_append(inode, raw, tail->block, tail->lba, tail->len, /*uninit=*/true, &merged,
                                   &leaf_count);
    /* The shrink before this may already be on the device
     * (cetrafs_convert_source_durable()), and a refused append leaves the
     * written block, and any tail, in no extent. ENOSPC is not a refusal
     * that can happen here: the room was checked and the tree blocks
     * reserved -- and written, so a thin pool said no before the edit
     * (cetrafs_tree_resv_provision()). If it does, the state is not what
     * this node believes, and that is a stop, not a hole (B-2). */
    if ((ret == -ENOSPC || tret == -ENOSPC) && !READ_ONCE(cetrafs_convert_append_nospc))
        cetrafs_sb_fatal(inode->i_sb, "ino=%llu: a convert's append was refused ENOSPC after its leaf was shrunk",
                         (unsigned long long) inode->i_ino);
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
 * A regular file's extent-tree block, edited under its update lock, is
 * held back for the next durability boundary (leafdefer.c) instead of
 * being dirtied: writeback must never write it in place, and the
 * boundary writes it through the journal. Unlocks the buffer.
 */
/* 'outer': the caller has no other block mid-update, so the inode's
 * held-back set may be written here if it reached its cap
 * (cetrafs_deferred_capped()). A caller still updating another block
 * passes false -- the write would wait on that block's lock. */
static int cetrafs_tree_hold_back(struct inode *inode, struct buffer_head *bh, u32 prev_crc, bool outer)
{
    if (!cetrafs_bh_defer_update(inode, bh, prev_crc)) {
        if (outer)
            cetrafs_deferred_capped(inode);
        return 0;
    }
    return cetrafs_journal_write_block(inode->i_sb, cetrafs_journal_owner_of(inode), bh, prev_crc); /* no registry: the mount is going */
}

/*
 * A split that hands part of an extent to ANOTHER leaf (the converted
 * block, the preallocated tail) shrank this leaf first. The destination
 * reaching the device without this one leaves the device's tree naming
 * the moved blocks TWICE, and a later delete frees them twice -- the
 * second time from under whichever file was given them in between
 * (tests/kernel/convert_leaf_order.sh). The other order is safe: a crash
 * between leaves those blocks named by nothing, a leak the scrub
 * reclaims (rule 8).
 *
 * Held-back blocks reach the device only in a boundary's journal batch,
 * and a batch is ONE atomic unit: every entry durable before any target
 * (cetrafs_journal_write_deferred()), and an inode's held-back set kept
 * under half the journal so it is always one batch
 * (cetrafs_deferred_capped()). The source and the destination of a
 * split are in the same set, so they land together or not at all, and
 * nothing need be written here. It was not always so: a batch went in
 * chunks of 16, atomic only within each, the destination could land a
 * chunk ahead of this leaf, and every split of a FULL leaf paid a whole
 * extra batch -- three cache flushes -- here to prevent it. Random
 * writes into a fallocated file fill the leaf holding the preallocated
 * extent and nothing empties it, so that was close to one batch per
 * guest write (docs/PERFORMANCE.md 14).
 *
 * Still written here when a batch cannot be atomic: no journal (mkfs
 * -J 0), whose boundary writes targets in place one by one, or one too
 * small for the cap to leave room (CETRAFS_CONVERT_ATOMIC_MIN slots).
 * Then everything held back so far, this leaf included, goes NOW, before
 * the moved piece is appended anywhere -- every block of the inode with
 * it, since a leaf may never reach the device ahead of the index that
 * ranges over it.
 *
 * The caller holds invalidate_lock. On failure the blocks stay held
 * back -- the cached leaf is the only copy of the shrunk state -- and
 * the caller appends nothing.
 */
#define CETRAFS_CONVERT_ATOMIC_MIN 8

/* TEST ONLY: write a split's source now even when the boundary is atomic
 * -- the old cost, for measuring against (convert_split_no_flush.sh). */
static bool cetrafs_convert_flush_always;
cetrafs_test_param(convert_flush_always, cetrafs_convert_flush_always, bool, 0644);
MODULE_PARM_DESC(convert_flush_always, "TEST ONLY: a split of a full leaf writes its source at once, as before");

static atomic64_t cetrafs_convert_source_flushes = ATOMIC64_INIT(0);

u64 cetrafs_convert_source_flush_count(void)
{
    return (u64) atomic64_read(&cetrafs_convert_source_flushes);
}

static int cetrafs_convert_source_durable(struct inode *inode, struct buffer_head *lbh)
{
    int ret;

    if (cetrafs_journal_batch_capacity(inode->i_sb) >= CETRAFS_CONVERT_ATOMIC_MIN && !READ_ONCE(cetrafs_convert_flush_always))
        return 0;
    atomic64_inc(&cetrafs_convert_source_flushes);
    ret = cetrafs_deferred_flush_inode(inode, true);

    if (ret)
        pr_err_ratelimited("ino=%llu: extent leaf %llu could not be written before its split moved on (%d)\n",
                           (unsigned long long) inode->i_ino, (unsigned long long) lbh->b_blocknr, ret);
    return ret;
}

/*
 * Split a FULL depth-2 leaf by logical range before a convert edits it.
 *
 * A convert that meets a full leaf used to shrink the extent in place and
 * append the converted block (and the preallocated tail) through the
 * tree, to the last leaf. Random writes into a fallocated image fill the
 * leaf holding the preallocation at once and nothing ever empties it, so
 * from then on EVERY convert went to the append leaf, and every leaf that
 * filled that way ended up with a range spanning the whole file: a lookup
 * read about half the leaves (~94 us per lookup on a 4 GiB image, against
 * ~1 us in a written one).
 *
 * Instead the leaf's lower half, by ee_block, moves to a new leaf, and
 * both get the exact range of what they hold, so leaf ranges stay
 * disjoint and a lookup reads about one leaf.
 *
 * Order, in memory: the new leaf is written whole first; then ONE edit of
 * the interior adds its entry and tightens the old leaf's range (a
 * lookup for a moved block now finds it in the new leaf); only then are
 * the moved entries removed from the old leaf. A reader without
 * invalidate_lock (writeback, an O_DIRECT read) finds every extent in at
 * least one of the two at every instant, never in neither. On the
 * device: the new leaf is written synchronously before anything names it
 * (rule 8), and the interior and the old leaf go out in the inode's
 * boundary batch, which is atomic -- so a split runs only when it is
 * (cetrafs_journal_batch_capacity(), as cetrafs_convert_source_durable()).
 * Either crash outcome is consistent: before the batch, the old leaf
 * still holds everything and the new leaf is a leak the scrub reclaims;
 * after it, the split.
 *
 * The interior's last entry stays the leaf it was, so the leaf appends go
 * to (cetrafs_tree_append(), always UNKNOWN) does not change, and its
 * range stays unknown if it is the one split.
 *
 * -ENOSPC: not split (interior full, batch not atomic, the knob) -- the
 * caller goes on to the append path, as before.
 */
/* TEST ONLY: cap the depth-2 tree's interiors (root entries) and leaves
 * per interior below the format's 4 and CETRAFS_EXT_BLOCK_MAX_IDX, so a
 * suite reaches the tree's limit in thousands of writes, not hundreds of
 * thousands (tests/kernel/tree_full_any_leaf.sh). 0: no cap. */
static unsigned int cetrafs_tree_root_cap;
cetrafs_test_param(tree_root_cap, cetrafs_tree_root_cap, uint, 0644);
MODULE_PARM_DESC(tree_root_cap, "TEST ONLY: at most N interiors in a depth-2 tree (0: the format's 4)");
static unsigned int cetrafs_tree_idx_cap;
cetrafs_test_param(tree_idx_cap, cetrafs_tree_idx_cap, uint, 0644);
MODULE_PARM_DESC(tree_idx_cap, "TEST ONLY: at most N leaves per interior (0: the format's maximum)");

static bool cetrafs_tree_root_has_room(const cetrafs_inode_t *raw)
{
    u32 cap = READ_ONCE(cetrafs_tree_root_cap);
    u32 max = cap && cap < ARRAY_SIZE(raw->et.idx) ? cap : ARRAY_SIZE(raw->et.idx);

    return cetrafs_le16(raw->eh.eh_entries) < max;
}

static bool cetrafs_tree_idx_has_room(u32 entries)
{
    u32 cap = READ_ONCE(cetrafs_tree_idx_cap);
    u32 max = cap && cap < CETRAFS_EXT_BLOCK_MAX_IDX ? cap : CETRAFS_EXT_BLOCK_MAX_IDX;

    return entries < max;
}

/*
 * A file's extent tree has a fixed ceiling (cetrafs_tree_max_extents(),
 * docs/internal/LIMITATIONS.md), and a guest's scattered first writes
 * walk it up one entry each. Reaching it fails writes ENOSPC with the
 * volume free, so the way there is announced: once a depth-2 tree has
 * used more than half its leaf blocks, a warning and the info counter
 * tree_half_full (audit 2026-11-14 A-1). Leaves are what run out -- an
 * interior is full before the next one is added -- so the count is the
 * full interiors before the last plus the last one's entries. Until at
 * least half the interiors exist it reads nothing.
 */
static atomic64_t cetrafs_tree_half_full = ATOMIC64_INIT(0);

u64 cetrafs_tree_half_full_count(void)
{
    return (u64) atomic64_read(&cetrafs_tree_half_full);
}

/* Leaf blocks a depth-2 tree uses, or 0 while it cannot be past half. */
static u32 cetrafs_tree_leaves_if_half(struct inode *inode, const cetrafs_inode_t *raw, u32 *max)
{
    u32 rc = READ_ONCE(cetrafs_tree_root_cap), ic = READ_ONCE(cetrafs_tree_idx_cap);
    u32 rmax = rc && rc < ARRAY_SIZE(raw->et.idx) ? rc : ARRAY_SIZE(raw->et.idx);
    u32 idx_max = ic && ic < CETRAFS_EXT_BLOCK_MAX_IDX ? ic : CETRAFS_EXT_BLOCK_MAX_IDX;
    u32 nroot, n;
    struct buffer_head *ibh;
    u64 ilba;

    *max = rmax * idx_max;
    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(raw->eh.eh_depth) != 2)
        return 0;
    nroot = min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.idx));
    if (!nroot || (u64) nroot * idx_max * 2 <= *max)
        return 0;
    ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[nroot - 1].ei_leaf_hi, raw->et.idx[nroot - 1].ei_leaf_lo);
    ibh = cetrafs_read_index_bh(inode, ilba);
    if (!ibh)
        return 0;
    n = min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) ibh->b_data)->eh_entries), idx_max);
    brelse(ibh);
    return (nroot - 1) * idx_max + n;
}

static void cetrafs_tree_note_capacity(struct inode *inode, const cetrafs_inode_t *raw, u32 before)
{
    u32 max, after = cetrafs_tree_leaves_if_half(inode, raw, &max);

    if ((u64) after * 2 > max && (u64) before * 2 <= max) {
        atomic64_inc(&cetrafs_tree_half_full);
        pr_warn("%s: ino=%llu: extent tree past half full (%u of %u leaf blocks, at most %u extents): "
                "scattered first writes fail ENOSPC at the limit whatever the volume has free -- "
                "copy the file to lay it out again\n",
                inode->i_sb->s_id, (unsigned long long) inode->i_ino, after, max, cetrafs_tree_max_extents());
    }
}


static bool cetrafs_leaf_split_off;
/* TEST ONLY (split_hides_extent.sh): the next convert splits its leaf
 * however full it is, and a split puts the new leaf in the interior's
 * FIRST slot -- behind any walk in progress, where a real split's slot
 * lands when the old leaf was last in its interior or the new leaf goes
 * to an interior already walked. */
static bool cetrafs_leaf_split_force;
cetrafs_test_param(leaf_split_force, cetrafs_leaf_split_force, bool, 0644);
MODULE_PARM_DESC(leaf_split_force, "TEST ONLY: the next convert splits its leaf whatever its fill, once");
static bool cetrafs_leaf_split_place_first;
cetrafs_test_param(leaf_split_place_first, cetrafs_leaf_split_place_first, bool, 0644);
MODULE_PARM_DESC(leaf_split_place_first, "TEST ONLY: a split's new leaf takes its interior's first slot");
cetrafs_test_param(leaf_split_off, cetrafs_leaf_split_off, bool, 0644);
MODULE_PARM_DESC(leaf_split_off, "TEST ONLY: a full leaf a convert meets is not split (appends through the tree, as before)");

/* TEST ONLY: hold one split after its new leaf is written and before any
 * entry moves, so a suite can start a lookup ahead of the move
 * (split_hides_extent.sh). One-shot. */
static unsigned int cetrafs_leaf_split_stall_ms;
cetrafs_test_param(leaf_split_stall_ms, cetrafs_leaf_split_stall_ms, uint, 0644);
MODULE_PARM_DESC(leaf_split_stall_ms, "TEST ONLY: stall the next leaf split before its entries move, once");

static atomic64_t cetrafs_leaf_splits = ATOMIC64_INIT(0);

u64 cetrafs_leaf_split_count(void)
{
    return (u64) atomic64_read(&cetrafs_leaf_splits);
}

static int cetrafs_u32_cmp(const void *a, const void *b)
{
    u32 x = *(const u32 *) a, y = *(const u32 *) b;

    return x < y ? -1 : x > y;
}

/* Would a convert in this leaf need more room than it has (a middle split
 * takes two slots)? */
static bool cetrafs_leaf_split_wanted(struct inode *inode, struct buffer_head *lbh)
{
    u16 n;

    if (READ_ONCE(cetrafs_leaf_split_off) || !S_ISREG(inode->i_mode))
        return false;
    cetrafs_bh_read_lock(lbh);
    n = cetrafs_le16(((const cetrafs_extent_hdr_t *) lbh->b_data)->eh_entries);
    cetrafs_bh_read_unlock(lbh);
    if (READ_ONCE(cetrafs_leaf_split_force) && n >= 4 && xchg(&cetrafs_leaf_split_force, false))
        return true; /* test-only; see the knob */
    return n + 2 > CETRAFS_EXT_BLOCK_MAX_LEAVES;
}

/* Could a convert in this leaf shrink an extent here and append its
 * piece elsewhere (CETRAFS_CONVERT_APPEND)? Only when it lacks room for a
 * middle split. */
static bool cetrafs_leaf_nearly_full(struct buffer_head *lbh)
{
    u16 n;

    cetrafs_bh_read_lock(lbh);
    n = cetrafs_le16(((const cetrafs_extent_hdr_t *) lbh->b_data)->eh_entries);
    cetrafs_bh_read_unlock(lbh);
    return n + 2 > CETRAFS_EXT_BLOCK_MAX_LEAVES;
}

/* Add leaf 'nleaf' [lo, hi) to interior 'dbh', keeping its last entry
 * last (the append target, if this is the last interior). Returns the
 * position the previous last entry moved to through *moved_to. */
static int cetrafs_idx_insert_keep_last(struct inode *inode, struct buffer_head *dbh, u32 lo, u32 hi, u64 nleaf)
{
    cetrafs_extent_hdr_t *h = (cetrafs_extent_hdr_t *) dbh->b_data;
    cetrafs_extent_idx_t *a = (cetrafs_extent_idx_t *) (dbh->b_data + sizeof(*h));
    const u32 prev = cetrafs_bh_begin_update_crc(dbh);
    u16 ient = cetrafs_le16(h->eh_entries);

    a[ient] = a[ient - 1];
    cetrafs_idx_set(&a[ient - 1], lo, hi, nleaf);
    h->eh_entries = cetrafs_cpu_to_le16(ient + 1);
    cetrafs_blk_tail_stamp(dbh, CETRAFS_INDEX_TAIL_MAGIC);
    return cetrafs_tree_hold_back(inode, dbh, prev, false);
}

/*
 * Returns 0 (split: walk again), CETRAFS_SPLIT_NONE (nothing changed: the
 * caller converts in place, or appends the piece elsewhere) or an error.
 * "Not split" is not an errno: once step 1 has edited an interior, any
 * failure is an error the caller must return, and an -ENOSPC from there
 * read as "not split" would convert on into a leaf whose moved entries
 * the new one names too.
 */
#define CETRAFS_SPLIT_NONE 1

static int cetrafs_tree_split_leaf(struct inode *inode,
                                   cetrafs_inode_t *raw,
                                   struct buffer_head *ibh,
                                   u32 li,
                                   struct buffer_head *lbh,
                                   bool append_target,
                                   bool *moving)
{
    struct super_block *sb = inode->i_sb;
    cetrafs_extent_hdr_t *ihdr = (cetrafs_extent_hdr_t *) ibh->b_data;
    cetrafs_extent_idx_t *iarr = (cetrafs_extent_idx_t *) (ibh->b_data + sizeof(*ihdr));
    cetrafs_extent_hdr_t *lhdr = (cetrafs_extent_hdr_t *) lbh->b_data;
    cetrafs_extent_t *larr = (cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr));
    struct buffer_head *dbh = NULL; /* the interior that takes the new leaf */
    cetrafs_extent_t *part = NULL;
    u32 *keys = NULL;
    u16 n, nl = 0, k, i, ient;
    u32 pivot, blo, bhi, ulo, uhi, bg, ni;
    u64 nleaf;
    int ret;

    lockdep_assert_held_write(&inode->i_mapping->invalidate_lock);
    if (cetrafs_journal_batch_capacity(sb) < CETRAFS_CONVERT_ATOMIC_MIN)
        return CETRAFS_SPLIT_NONE; /* not atomic at the boundary: see above */
    ient = cetrafs_le16(ihdr->eh_entries);
    if (ient == 0 || li >= ient)
        return CETRAFS_SPLIT_NONE;

    /* Where the new leaf goes: this interior if it has room, else any
     * other one that has (root entries carry no range, so a leaf may sit
     * under any of them). None: not split -- the append path then grows
     * a new interior, and the next split has room there. */
    if (cetrafs_tree_idx_has_room(ient)) {
        get_bh(ibh);
        dbh = ibh;
    } else {
        for (ni = 0; ni < cetrafs_le16(raw->eh.eh_entries) && ni < ARRAY_SIZE(raw->et.idx) && !dbh; ni++) {
            u64 dl = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
            struct buffer_head *b;
            u16 de;

            if (dl == ibh->b_blocknr)
                continue;
            b = cetrafs_read_index_bh(inode, dl);
            if (!b)
                return -EIO;
            de = cetrafs_le16(((cetrafs_extent_hdr_t *) b->b_data)->eh_entries);
            if (de && cetrafs_tree_idx_has_room(de))
                dbh = b;
            else
                brelse(b);
        }
        if (!dbh)
            return CETRAFS_SPLIT_NONE;
    }

    n = min_t(u16, cetrafs_le16(lhdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);
    ret = CETRAFS_SPLIT_NONE;
    if (n < 4)
        goto out;
    part = kmalloc_array(n, sizeof(*part), GFP_NOFS);
    keys = kmalloc_array(n, sizeof(*keys), GFP_NOFS);
    ret = -ENOMEM;
    if (!part || !keys)
        goto out;
    /* The caller holds invalidate_lock: no writer edits the leaf. */
    for (i = 0; i < n; i++)
        keys[i] = cetrafs_le32(larr[i].ee_block);
    sort(keys, n, sizeof(*keys), cetrafs_u32_cmp, NULL);
    pivot = keys[n / 2];
    for (i = 0; i < n; i++)
        if (cetrafs_le32(larr[i].ee_block) < pivot)
            part[nl++] = larr[i];
    ret = CETRAFS_SPLIT_NONE;
    if (!nl || nl == n)
        goto out;

    ret = cetrafs_tree_block_anywhere(sb, &bg, &nleaf);
    if (ret == -ENOSPC)
        ret = CETRAFS_SPLIT_NONE; /* the volume is full: the convert's own append answers */
    if (ret)
        goto out;
    /* Named below from an interior edited in place: its bit first. */
    ret = cetrafs_alloc_flush_bitmaps_if_dirty(sb);
    if (!ret)
        ret = cetrafs_write_new_leaf(sb, nleaf, part, nl);
    if (ret) {
        cetrafs_free_data_block(sb, nleaf);
        goto out;
    }
    cetrafs_leaf_array_range(part, nl, &blo, &bhi);

    /* What the old leaf keeps: the upper part, and its exact range. */
    for (i = 0, k = 0; i < n; i++)
        if (cetrafs_le32(larr[i].ee_block) >= pivot)
            part[k++] = larr[i];
    cetrafs_leaf_array_range(part, k, &ulo, &uhi);

    if (unlikely(READ_ONCE(cetrafs_leaf_split_stall_ms))) {
        unsigned int ms = xchg(&cetrafs_leaf_split_stall_ms, 0);

        if (ms)
            msleep(min_t(unsigned int, ms, 10000)); /* test-only; see the knob */
    }
    /* From here entries move: a lockless walk may pass where they go. */
    cetrafs_tree_move_begin(inode, moving);

    /* 1. The new leaf into its interior. A lookup for a moved block now
     * finds it there; the old leaf still holds it too. */
    if (dbh == ibh) {
        /* One update: the new leaf in, and the old leaf's range
         * tightened, which only narrows to what the new leaf took over. */
        const u32 iprev = cetrafs_bh_begin_update_crc(ibh);
        u32 lpos = li == (u32) ient - 1 ? ient : li;
        u32 npos = ient - 1;

        iarr[ient] = iarr[ient - 1];
        if (READ_ONCE(cetrafs_leaf_split_place_first) && ient > 1) {
            /* test-only; see the knob. The last entry stays last. */
            iarr[ient - 1] = iarr[0];
            if (li == 0)
                lpos = ient - 1;
            npos = 0;
        }
        cetrafs_idx_set(&iarr[npos], blo, bhi, nleaf);
        if (!(append_target && lpos == ient)) {
            iarr[lpos].ei_block = cetrafs_cpu_to_le32(ulo);
            iarr[lpos].ei_block_end = cetrafs_cpu_to_le32(uhi);
        }
        ihdr->eh_entries = cetrafs_cpu_to_le16(ient + 1);
        cetrafs_blk_tail_stamp(ibh, CETRAFS_INDEX_TAIL_MAGIC);
        ret = cetrafs_tree_hold_back(inode, ibh, iprev, false);
    } else {
        ret = cetrafs_idx_insert_keep_last(inode, dbh, blo, bhi, nleaf);
        /* 1b. Then the old leaf's range in its own interior. */
        if (!ret && !append_target) {
            const u32 iprev = cetrafs_bh_begin_update_crc(ibh);

            iarr[li].ei_block = cetrafs_cpu_to_le32(ulo);
            iarr[li].ei_block_end = cetrafs_cpu_to_le32(uhi);
            cetrafs_blk_tail_stamp(ibh, CETRAFS_INDEX_TAIL_MAGIC);
            ret = cetrafs_tree_hold_back(inode, ibh, iprev, false);
        }
    }
    raw->blocks = cetrafs_cpu_to_le64(cetrafs_le64(raw->blocks) + (CETRAFS_BLOCK_SIZE / 512)); /* the new leaf */
    if (ret)
        goto out; /* the new leaf is named in core: it stays */

    /* 2. Only now the moved entries out of the old leaf. */
    {
        const u32 lprev = cetrafs_bh_begin_update_crc(lbh);

        for (i = 0, k = 0; i < n; i++)
            if (cetrafs_le32(larr[i].ee_block) >= pivot)
                larr[k++] = larr[i];
        memset(&larr[k], 0, (size_t) (n - k) * sizeof(*larr));
        lhdr->eh_entries = cetrafs_cpu_to_le16(k);
        cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
        ret = cetrafs_tree_hold_back(inode, lbh, lprev, false);
    }
    if (!ret)
        atomic64_inc(&cetrafs_leaf_splits);
out:
    kfree(part);
    kfree(keys);
    brelse(dbh);
    return ret;
}

static bool cetrafs_tree_any_leaf_off;
static bool cetrafs_tree_append_room_off;
cetrafs_test_param(tree_append_room_off, cetrafs_tree_append_room_off, bool, 0644);
MODULE_PARM_DESC(tree_append_room_off,
                 "TEST ONLY: a convert at the tree's limit shrinks its leaf without first checking the append has room");

/*
 * Can the tree take two more extents through cetrafs_tree_append(),
 * merging nothing? Asked BEFORE a convert shrinks a full leaf and hands
 * its pieces -- the converted block and the preallocated tail, at most
 * two extents -- to the append (CETRAFS_CONVERT_APPEND). At the tree's
 * limit that append fails only AFTER the shrink is held back: the
 * written block drops out of the map (allocated, referenced by nothing)
 * and the rest of the preallocation is given back, for a write that
 * then fails ENOSPC anyway (audit 2026-11-14 A-1). Refused here, the
 * write fails ENOSPC with nothing modified and the preallocation kept.
 *
 * Where an append can put an extent: the last leaf, a new leaf (room in
 * the last interior or the root), or -- at the limit -- any leaf with a
 * free slot (cetrafs_tree_insert_any_leaf()). Depth 0 and 1 can always
 * grow a level. The walk reads every leaf, but only at the limit, where
 * the append would walk them all too.
 *
 * 0: room. -ENOSPC: none. -EIO: a tree block could not be read.
 */
static int cetrafs_tree_append_room(struct inode *inode, const cetrafs_inode_t *raw)
{
    const u32 need = 2;
    u32 ni, nroot, avail = 0;

    if (READ_ONCE(cetrafs_tree_append_room_off))
        return 0; /* TEST ONLY: the old order */
    if (cetrafs_le16(raw->eh.eh_depth) < 2 || cetrafs_tree_root_has_room(raw))
        return 0;
    nroot = min_t(u32, cetrafs_le16(raw->eh.eh_entries), ARRAY_SIZE(raw->et.idx));
    for (ni = 0; ni < nroot; ni++) {
        u64 ilba = cetrafs_extent_phys_from_hilo(raw->et.idx[ni].ei_leaf_hi, raw->et.idx[ni].ei_leaf_lo);
        struct buffer_head *ibh = cetrafs_read_index_bh(inode, ilba);
        const cetrafs_extent_idx_t *iarr;
        u32 li, iln;
        bool last = ni + 1 == nroot;

        if (!ibh)
            return -EIO;
        iln = min_t(u32, cetrafs_le16(((const cetrafs_extent_hdr_t *) ibh->b_data)->eh_entries),
                    CETRAFS_EXT_BLOCK_MAX_IDX);
        if (last && cetrafs_tree_idx_has_room(iln)) {
            brelse(ibh);
            return 0; /* a new leaf takes them */
        }
        iarr = (const cetrafs_extent_idx_t *) (ibh->b_data + sizeof(cetrafs_extent_hdr_t));
        for (li = 0; li < iln; li++) {
            struct buffer_head *lbh;
            u16 n;

            /* Without the any-leaf fallback only the last leaf takes appends. */
            if ((READ_ONCE(cetrafs_tree_any_leaf_off) || !S_ISREG(inode->i_mode)) && !(last && li + 1 == iln))
                continue;
            lbh = cetrafs_read_leaf_bh(inode,
                                       cetrafs_extent_phys_from_hilo(iarr[li].ei_leaf_hi, iarr[li].ei_leaf_lo));
            if (!lbh) {
                brelse(ibh);
                return -EIO;
            }
            cetrafs_bh_read_lock(lbh);
            n = cetrafs_le16(((const cetrafs_extent_hdr_t *) lbh->b_data)->eh_entries);
            cetrafs_bh_read_unlock(lbh);
            brelse(lbh);
            if (n < CETRAFS_EXT_BLOCK_MAX_LEAVES)
                avail += CETRAFS_EXT_BLOCK_MAX_LEAVES - n;
            if (avail >= need) {
                brelse(ibh);
                return 0;
            }
        }
        brelse(ibh);
    }
    return -ENOSPC;
}

/* A convert that needs room: the append's slots checked, then its blocks
 * reserved -- both before anything is edited. */
static int cetrafs_tree_convert_need_room(struct inode *inode, const cetrafs_inode_t *raw)
{
    int ret = cetrafs_tree_append_room(inode, raw);

    if (ret == -ENOSPC)
        pr_warn_ratelimited("ino=%llu: extent tree full (%u extents at most): a write into preallocated space "
                            "fails ENOSPC, nothing changed\n",
                            (unsigned long long) inode->i_ino, cetrafs_tree_max_extents());
    return ret ? ret : cetrafs_tree_resv_fill(inode);
}

static int cetrafs_tree_convert_inner(struct inode *inode,
                                      cetrafs_inode_t *raw,
                                      u32 iblock,
                                      u64 lba,
                                      u32 want,
                                      u32 *done,
                                      bool *moving)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_convert_tail tail = { 0 };
    u32 ni;
    int ret, splits = 0;

    tail.ino = inode;

    if (cetrafs_le16(raw->eh.eh_depth) == 0) {
        ret = cetrafs_leaf_array_convert(sb, raw->et.leaf, &raw->eh.eh_entries, (u16) ARRAY_SIZE(raw->et.leaf), iblock,
                                         lba, want, done, &tail);
        if (ret == CETRAFS_CONVERT_NEED_ROOM) {
            ret = cetrafs_tree_convert_need_room(inode, raw);
            if (ret)
                return ret;
            tail.may_append = true;
            ret = cetrafs_leaf_array_convert(sb, raw->et.leaf, &raw->eh.eh_entries, (u16) ARRAY_SIZE(raw->et.leaf),
                                             iblock, lba, want, done, &tail);
        }
        if (ret == CETRAFS_CONVERT_APPEND)
            return cetrafs_tree_convert_append(inode, raw, (u32) iblock, lba, &tail);
        return ret;
    }

    if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        u64 llba = cetrafs_extent_phys_from_hilo(raw->et.idx[0].ei_leaf_hi, raw->et.idx[0].ei_leaf_lo);
        struct buffer_head *lbh;
        cetrafs_extent_hdr_t *lhdr;

retry1:
        lbh = cetrafs_read_leaf_bh(inode, llba);
        if (!lbh)
            return -EIO;
        /* Full enough that the convert may shrink here and append the
         * piece elsewhere: a move (cetrafs_tree_move_begin()). */
        if (cetrafs_leaf_nearly_full(lbh))
            cetrafs_tree_move_begin(inode, moving);
        const u32 prev_crc = cetrafs_bh_begin_update_crc(lbh);
        lhdr = (cetrafs_extent_hdr_t *) lbh->b_data;
        ret = cetrafs_leaf_array_convert(sb, (cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)), &lhdr->eh_entries,
                                         CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, want, done, &tail);
        if (ret == CETRAFS_CONVERT_NEED_ROOM) {
            cetrafs_bh_abort_update(lbh);
            brelse(lbh);
            ret = cetrafs_tree_convert_need_room(inode, raw);
            if (ret)
                return ret;
            tail.may_append = true;
            goto retry1;
        }
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
            int wret = cetrafs_tree_hold_back(inode, lbh, prev_crc, true);

            if (!wret && ret == CETRAFS_CONVERT_APPEND)
                wret = cetrafs_convert_source_durable(inode, lbh);
            if (wret) {
                brelse(lbh);
                return wret;
            }
            brelse(lbh);
        } else {
            /* A directory: no boundary, so journaled now. */
            int wret = cetrafs_journal_write_block(sb, cetrafs_journal_owner_of(inode), lbh, prev_crc);

            brelse(lbh);
            if (wret)
                return wret;
        }
        if (ret == CETRAFS_CONVERT_APPEND)
            return cetrafs_tree_convert_append(inode, raw, (u32) iblock, lba, &tail);
        return 0;
    }

again:
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
            /* Full: split it by range and walk again -- the half that
             * holds the block has room now. */
            if (splits < 2 && cetrafs_leaf_split_wanted(inode, lbh)) {
                bool tail_leaf = ni + 1 == cetrafs_le16(raw->eh.eh_entries) && li + 1 == iln;
                u32 cmax, cbefore = cetrafs_tree_leaves_if_half(inode, raw, &cmax);
                int sret = cetrafs_tree_split_leaf(inode, raw, ibh, li, lbh, tail_leaf, moving);

                if (!sret)
                    cetrafs_tree_note_capacity(inode, raw, cbefore);

                if (sret != CETRAFS_SPLIT_NONE) {
                    brelse(lbh);
                    brelse(ibh);
                    if (sret)
                        return sret;
                    splits++;
                    goto again;
                }
            }
            /* Not split, and full enough to append its piece elsewhere: a
             * move (cetrafs_tree_move_begin()). */
            if (cetrafs_leaf_nearly_full(lbh))
                cetrafs_tree_move_begin(inode, moving);
            const u32 prev_crc = cetrafs_bh_begin_update_crc(lbh);
            lhdr = (cetrafs_extent_hdr_t *) lbh->b_data;
            ret = cetrafs_leaf_array_convert(sb, (cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)), &lhdr->eh_entries,
                                             CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, want, done, &tail);
            if (ret == -ENOENT) {
                cetrafs_bh_abort_update(lbh);
                brelse(lbh);
                continue; /* not in this leaf; try the next */
            }
            if (ret == CETRAFS_CONVERT_NEED_ROOM) {
                cetrafs_bh_abort_update(lbh);
                brelse(lbh);
                brelse(ibh);
                ret = cetrafs_tree_convert_need_room(inode, raw);
                if (ret)
                    return ret;
                tail.may_append = true;
                goto again;
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
                int hret = cetrafs_tree_hold_back(inode, lbh, prev_crc, true);

                if (hret) {
                    brelse(lbh);
                    brelse(ibh);
                    return hret;
                }
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
                            const u32 nprev = cetrafs_bh_begin_update_crc(ibh);
                            int nret;

                            iarr[li].ei_block = cetrafs_cpu_to_le32(lo);
                            iarr[li].ei_block_end = cetrafs_cpu_to_le32(hi);
                            cetrafs_blk_tail_stamp(ibh, CETRAFS_INDEX_TAIL_MAGIC);
                            nret = cetrafs_tree_hold_back(inode, ibh, nprev, false);
                            if (nret) {
                                brelse(lbh);
                                brelse(ibh);
                                return nret;
                            }
                        }
                    }
                }
                brelse(lbh);
                brelse(ibh);
            } else {
                /* Depth 2 is regular files only; journaled as everywhere else. */
                int wret = cetrafs_journal_write_block(sb, cetrafs_journal_owner_of(inode), lbh, prev_crc);

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
/* 'moving': set when the convert moved entries (cetrafs_tree_move_begin());
 * the caller ends the move once the new record is staged. */
/* TEST ONLY: the reserve goes back after every convert, as before
 * (tests/kernel/tree_resv_kept.sh's control). */
static bool cetrafs_tree_resv_keep_off;
cetrafs_test_param(tree_resv_keep_off, cetrafs_tree_resv_keep_off, bool, 0644);
MODULE_PARM_DESC(tree_resv_keep_off, "TEST ONLY: a convert's unused tree reserve is freed after every convert");

static int cetrafs_tree_convert(struct inode *inode, cetrafs_inode_t *raw, u32 iblock, u64 lba, u32 want, u32 *done,
                                bool *moving)
{
    /* A split rewrites a LEAF and can leave the record's depth, entry
     * count and block count untouched -- the key cannot see it. */
    cetrafs_inode_ext_cache_drop(inode);

    int ret;

    *done = 0;
    ret = cetrafs_deferred_room(inode); /* before anything is edited */
    if (ret)
        return ret;
    ret = cetrafs_tree_convert_inner(inode, raw, iblock, lba, want, done, moving);
    /* What an append did not take stays for the next convert (F-5),
     * given back at the write close; a refused convert gives it back
     * now, so an ENOSPC leaves the volume as it found it. */
    if (ret < 0 || READ_ONCE(cetrafs_tree_resv_keep_off))
        cetrafs_tree_resv_release(inode);
    if (WARN_ON_ONCE(ret == CETRAFS_CONVERT_NEED_ROOM))
        ret = -EIO;
    if (ret == 0 && *done == 0)
        *done = 1; /* belt: a path that converted without saying so */

    if (WARN_ON_ONCE(ret == CETRAFS_CONVERT_APPEND)) {
        pr_err("tree convert: a leaf-full signal escaped unhandled for ino=%llu block %u -- please report\n",
               (unsigned long long) inode->i_ino, iblock);
        return -EIO;
    }
    return ret;
}

/*
 * The depth-2 tree is at its limit -- every interior full and no root
 * slot for another -- but leaves below it are not: a range split
 * (cetrafs_tree_split_leaf()) leaves both halves part full. The append
 * then fills ANY leaf with a free slot, so the tree holds at least as
 * many extents as an append-only one, whose leaves all filled. A lookup
 * pays for it only at the limit: the leaf taken over gets an UNKNOWN
 * range, read by every lookup from then on.
 *
 * UNKNOWN, not widened, and the interior held back BEFORE the leaf: the
 * rule of the append to the last leaf (cetrafs_tree_append()), so a
 * boundary that is not atomic -- one written in place, block by block --
 * never puts the leaf on the device under a range that skips the new
 * extent. Root entries carry no range.
 *
 * -ENOSPC: every leaf is full too -- the tree really is.
 */
cetrafs_test_param(tree_any_leaf_off, cetrafs_tree_any_leaf_off, bool, 0644);
MODULE_PARM_DESC(tree_any_leaf_off, "TEST ONLY: a full depth-2 tree returns ENOSPC instead of filling free leaf slots");

static atomic64_t cetrafs_tree_any_leaf_inserts = ATOMIC64_INIT(0);

u64 cetrafs_tree_any_leaf_count(void)
{
    return (u64) atomic64_read(&cetrafs_tree_any_leaf_inserts);
}

static int cetrafs_tree_insert_any_leaf(struct inode *inode,
                                        cetrafs_inode_t *raw,
                                        u32 iblock,
                                        u64 lba,
                                        u32 count,
                                        bool uninit,
                                        bool *merged,
                                        u32 *leaf_count)
{
    struct super_block *sb = inode->i_sb;
    u32 ni;

    if (READ_ONCE(cetrafs_tree_any_leaf_off) || !S_ISREG(inode->i_mode))
        return -ENOSPC;
    lockdep_assert_held_write(&inode->i_mapping->invalidate_lock);
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
            struct buffer_head *lbh = cetrafs_read_leaf_bh(inode, llba);
            cetrafs_extent_hdr_t *lhdr;
            u16 before;
            int ret;

            if (!lbh) {
                brelse(ibh);
                return -EIO;
            }
            lhdr = (cetrafs_extent_hdr_t *) lbh->b_data;
            /* The caller holds invalidate_lock: no writer edits it. */
            before = cetrafs_le16(lhdr->eh_entries);
            if (before >= CETRAFS_EXT_BLOCK_MAX_LEAVES) {
                brelse(lbh);
                continue;
            }
            /* 1. The interior: this leaf's range UNKNOWN, held back first. */
            if (cetrafs_le32(iarr[li].ei_block_end)) {
                const u32 iprev = cetrafs_bh_begin_update_crc(ibh);

                iarr[li].ei_block_end = cetrafs_cpu_to_le32(0);
                cetrafs_blk_tail_stamp(ibh, CETRAFS_INDEX_TAIL_MAGIC);
                ret = cetrafs_tree_hold_back(inode, ibh, iprev, false);
                if (ret) {
                    brelse(lbh);
                    brelse(ibh);
                    return ret;
                }
            }
            /* 2. The extent into the leaf. */
            {
                const u32 lprev = cetrafs_bh_begin_update_crc(lbh);

                ret = cetrafs_leaf_array_insert((cetrafs_extent_t *) (lbh->b_data + sizeof(*lhdr)), &lhdr->eh_entries,
                                                CETRAFS_EXT_BLOCK_MAX_LEAVES, iblock, lba, count, uninit);
                if (ret) {
                    cetrafs_bh_abort_update(lbh);
                    brelse(lbh);
                    if (ret == -ENOSPC)
                        continue;
                    brelse(ibh);
                    return ret;
                }
                *merged = cetrafs_le16(lhdr->eh_entries) == before;
                *leaf_count = cetrafs_le16(lhdr->eh_entries);
                cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
                ret = cetrafs_tree_hold_back(inode, lbh, lprev, true);
            }
            brelse(lbh);
            brelse(ibh);
            if (!ret)
                atomic64_inc(&cetrafs_tree_any_leaf_inserts);
            return ret;
        }
        brelse(ibh);
    }
    (void) sb;
    return -ENOSPC;
}

static int cetrafs_tree_append_inner(struct inode *inode,
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
    if (cetrafs_le16(raw->eh.eh_depth) == 0) {
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

            ret = cetrafs_tree_alloc_block(inode, &ext_bg, &new_leaf);
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
                ret = cetrafs_tree_hold_back(inode, lbh, prev_crc, true);
                brelse(lbh);
                return ret;
            }
            /* Same trade as the convert path: a regular file's leaf is republished
             * at the next durability boundary (close, fsync, writeback), so it does
             * not need three device cache flushes per insert. A DIRECTORY has no
             * such boundary and must still journal. Missing this here is why the
             * convert fix alone left 1996 journal entries per 2000 splitting
             * writes -- the splits land in tree_append, not tree_convert. */
            if (S_ISREG(inode->i_mode)) {
                cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
                ret = cetrafs_tree_hold_back(inode, lbh, prev_crc, true);
            } else {
                ret = cetrafs_journal_write_block(sb, cetrafs_journal_owner_of(inode), lbh, prev_crc);
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
            one.ee_pad = cetrafs_cpu_to_le16(0);
            one.ee_len = cetrafs_extent_pack_len(count, uninit);
            cetrafs_extent_phys_to_hilo(lba, &one.ee_start_hi, &one.ee_start_lo);

            ret = cetrafs_tree_alloc_block(inode, &bg, &new_leaf);
            if (ret)
                return ret;
            ret = cetrafs_tree_alloc_block(inode, &bg, &new_idx);
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
            cetrafs_idx_set(&idx[1], 0, 0 /* the appended-to leaf: unknown */, new_leaf);
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
        u32 full_lo = 0, full_hi = 0; /* the full last leaf's range, if it is replaced */

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

                    if (S_ISREG(inode->i_mode)) {
                        /*
                         * A regular file's leaf and interior are both
                         * left dirty for writeback, which orders
                         * nothing: the leaf can reach the device with
                         * this extent while the interior still holds
                         * the old range, and a node dying in between
                         * leaves an extent every lookup skips -- the
                         * block reads as a hole, is written again under
                         * a second extent, and the first resurfaces if
                         * the range ever widens. Two-node hypervisor
                         * storm, a node's device pulled mid-write: 251
                         * such extents in one image.
                         *
                         * So the leaf appends go to never carries a
                         * range at all (cetrafs_tree_append() creates
                         * it UNKNOWN), and one that still does -- a
                         * volume written before this, or a rebuild --
                         * becomes UNKNOWN here, on the device BEFORE
                         * the leaf can be: once per leaf, not per
                         * block.
                         */
                        int iw;

                        iarr[ient - 1].ei_block_end = cetrafs_cpu_to_le32(0);
                        cetrafs_blk_tail_stamp(ibh, CETRAFS_INDEX_TAIL_MAGIC);
                        /* Held back with the leaf: one boundary batch
                         * writes both, entries first, so neither can
                         * reach the device without the other being
                         * redoable (leafdefer.c). */
                        iw = cetrafs_tree_hold_back(inode, ibh, iprev, false);
                        if (iw) {
                            cetrafs_bh_abort_update(lbh);
                            brelse(lbh);
                            brelse(ibh);
                            return iw;
                        }
                    } else {
                        int iw;

                        cetrafs_idx_widen(&iarr[ient - 1], iblock, cetrafs_idx_end(iblock, count));
                        cetrafs_blk_tail_stamp(ibh, CETRAFS_INDEX_TAIL_MAGIC);
                        iw = cetrafs_journal_write_block(sb, cetrafs_journal_owner_of(inode), ibh, iprev);
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
                ret = cetrafs_tree_hold_back(inode, lbh, prev_crc, true);
                brelse(lbh);
                brelse(ibh);
                return ret;
            }
            /* Same trade as the convert path: a regular file's leaf is republished
             * at the next durability boundary (close, fsync, writeback), so it does
             * not need three device cache flushes per insert. A DIRECTORY has no
             * such boundary and must still journal. Missing this here is why the
             * convert fix alone left 1996 journal entries per 2000 splitting
             * writes -- the splits land in tree_append, not tree_convert. */
            if (S_ISREG(inode->i_mode)) {
                cetrafs_blk_tail_stamp(lbh, CETRAFS_LEAF_TAIL_MAGIC);
                ret = cetrafs_tree_hold_back(inode, lbh, prev_crc, true);
            } else {
                ret = cetrafs_journal_write_block(sb, cetrafs_journal_owner_of(inode), lbh, prev_crc);
            }
            brelse(lbh);
            brelse(ibh);
            return ret;
        }
        /* The full leaf's range, while its array is in hand: it stops
         * taking appends below, so it can be given an exact one. */
        cetrafs_leaf_array_range(larr, min_t(u16, cetrafs_le16(lhdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES),
                                 &full_lo, &full_hi);
        cetrafs_bh_abort_update(lbh);
        brelse(lbh);
        if (ret != -ENOSPC) {
            brelse(ibh);
            return ret;
        }

        /* The tree cannot take another leaf: no room in the last
         * interior and none for another interior. Then any leaf with a
         * free slot takes the extent (cetrafs_tree_insert_any_leaf()). */
        if (!cetrafs_tree_idx_has_room(cetrafs_le16(ihdr->eh_entries)) && !cetrafs_tree_root_has_room(raw)) {
            brelse(ibh);
            return cetrafs_tree_insert_any_leaf(inode, raw, iblock, lba, count, uninit, merged, leaf_count);
        }

        /* Last leaf full: a fresh leaf, appended to this interior. */
        {
            u32 bg;
            u64 new_leaf;
            cetrafs_extent_t one;

            one.ee_block = cetrafs_cpu_to_le32(iblock);
            one.ee_pad = cetrafs_cpu_to_le16(0);
            one.ee_len = cetrafs_extent_pack_len(count, uninit);
            cetrafs_extent_phys_to_hilo(lba, &one.ee_start_hi, &one.ee_start_lo);

            ret = cetrafs_tree_alloc_block(inode, &bg, &new_leaf);
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

            if (cetrafs_tree_idx_has_room(cetrafs_le16(ihdr->eh_entries))) {
                /* room in the last interior for one more leaf pointer */
                const u32 prev_crc = cetrafs_bh_begin_update_crc(ibh);
                u16 ient = cetrafs_le16(ihdr->eh_entries);

                /* The new leaf is the one appends go to: UNKNOWN (see the
                 * last-leaf path above). The full one it replaces stops
                 * growing, so it gets its exact range -- computed from
                 * this node's copy, which is everything the device's can
                 * hold, so the range can only over-advertise. */
                if (S_ISREG(inode->i_mode) && ient) {
                    iarr[ient - 1].ei_block = cetrafs_cpu_to_le32(full_lo);
                    iarr[ient - 1].ei_block_end = cetrafs_cpu_to_le32(full_hi);
                }
                cetrafs_idx_set(&iarr[ient], 0, 0 /* the appended-to leaf: unknown */, new_leaf);
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
                    ret = cetrafs_tree_hold_back(inode, ibh, prev_crc, false);
                } else {
                    ret = cetrafs_journal_write_block(sb, cetrafs_journal_owner_of(inode), ibh, prev_crc);
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
            if (!cetrafs_tree_root_has_room(raw)) {
                cetrafs_free_data_block(sb, new_leaf);
                return -ENOSPC; /* not reached: the any-leaf fallback above runs first */
            }
            {
                u64 new_idx;
                cetrafs_extent_idx_t idx1;

                ret = cetrafs_tree_alloc_block(inode, &bg, &new_idx);
                if (ret) {
                    cetrafs_free_data_block(sb, new_leaf);
                    return ret;
                }
                /* The appended-to leaf: unknown. The previous interior's
                 * last leaf keeps the unknown it had (at most three such
                 * across the root's four interiors). */
                cetrafs_idx_set(&idx1, 0, 0, new_leaf);
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

static int cetrafs_tree_append(struct inode *inode,
                               cetrafs_inode_t *raw,
                               u32 iblock,
                               u64 lba,
                               u32 count,
                               bool uninit,
                               bool *merged,
                               u32 *leaf_count)
{
    u32 max, before = cetrafs_tree_leaves_if_half(inode, raw, &max);
    int ret = cetrafs_tree_append_inner(inode, raw, iblock, lba, count, uninit, merged, leaf_count);

    if (!ret)
        cetrafs_tree_note_capacity(inode, raw, before);
    return ret;
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

/* TEST ONLY: stall a mapping that found an unwritten block between the
 * tree read and its verdict, so a conversion lands in between
 * (tests/kernel/buffered_pending_race.sh). */
static unsigned int cetrafs_pending_race_delay_ms;
cetrafs_test_param(pending_race_delay_ms, cetrafs_pending_race_delay_ms, uint, 0644);
MODULE_PARM_DESC(pending_race_delay_ms, "TEST ONLY: stall get_block after the tree says unwritten");

/*
 * G-1: convert preallocated space a UNIT at a time, not a block at a
 * time. Every first write into a preallocated extent split it -- one
 * extent, or two for a middle block, per 4 KiB -- so scattered first
 * writes reached the per-file extent ceiling (A-1) after about a GiB of
 * scatter. Converting the aligned unit around the write (64 KiB by
 * default) leaves the next writes into that unit nothing to convert, and
 * written units merge with their written neighbours.
 *
 * The unit's other blocks were never written: they are zeroed on the
 * device first (WRITE ZEROES; a device without it gets no widening), and
 * only then is the whole unit marked written -- the same order as the
 * data the convert is for (rule 8). Never a block someone else is
 * writing:
 *   - one an O_DIRECT write in flight has mapped: its data may have
 *     landed, its completion not yet run -- the unit is left alone
 *     (cetrafs_unit_dio_busy());
 *   - one pending (a buffered or mapped write a boundary converts): at
 *     the boundary itself (CONVERT_PENDING) its data was written back
 *     with the whole set before any flip, so it is marked written with
 *     the unit and NOT zeroed; anywhere else its data may still be in a
 *     page, and the unit is left alone.
 * Both are added under invalidate_lock, held here exclusively. And only
 * within the one preallocated extent the written block is in.
 */
static unsigned int cetrafs_convert_unit_blocks = 16;
cetrafs_test_param(convert_unit_blocks, cetrafs_convert_unit_blocks, uint, 0644);
MODULE_PARM_DESC(convert_unit_blocks,
                 "blocks marked written together on a first write into preallocated space (power of two, 1-256; 1 = off)");

static atomic64_t cetrafs_convert_widened = ATOMIC64_INIT(0);
static atomic64_t cetrafs_convert_unit_busy = ATOMIC64_INIT(0);

u64 cetrafs_convert_widened_count(void)
{
    return (u64) atomic64_read(&cetrafs_convert_widened);
}

u64 cetrafs_convert_unit_busy_count(void)
{
    return (u64) atomic64_read(&cetrafs_convert_unit_busy);
}

static int cetrafs_convert_zero(struct super_block *sb, u64 lba, u64 count)
{
    /* Through the range-checked issuer (class 50): inside one Block
     * Group's data region, behind the witnessed fence, and NOUNMAP -- a
     * thin array must keep the space a preallocation reserved. */
    return cetrafs_zeroout_issue(sb, lba, count, false);
}

/* Zero the blocks of [first, first + count) (at 'plba') that are not
 * pending; pending ones are skipped, their data landed (the caller's
 * mode says so) -- or, with !pending_landed, any pending one is -EBUSY. */
static int cetrafs_convert_zero_side(struct inode *inode, u32 first, u64 plba, u32 count, bool pending_landed)
{
    u64 b = first, end = (u64) first + count;
    u32 pf, pl;

    while (b < end) {
        u64 stop = end;

        if (!cetrafs_pending_next(inode, (u32) b, &pf, &pl) && pf < end) {
            if (!pending_landed)
                return -EBUSY;
            stop = pf;
        }
        if (stop > b) {
            int ret = cetrafs_convert_zero(inode->i_sb, plba + (b - first), stop - b);

            if (ret)
                return ret;
        }
        if (stop == end)
            break;
        b = (u64) pl + 1; /* past the pending run: its data is on the device */
    }
    return 0;
}

/* [iblock, iblock + want) at lba is about to be converted: widen it to
 * the aligned unit when the unit is free to take. */
static void cetrafs_convert_widen(struct inode *inode, const cetrafs_inode_t *raw, u32 iblock, u64 lba, u32 want,
                                  bool pending_landed, u32 *cv_iblock, u64 *cv_lba, u32 *cv_want)
{
    u32 unit = READ_ONCE(cetrafs_convert_unit_blocks), run = 0;
    u64 ws, we, lws = 0;
    bool uninit = false, found = false;

    if (unit <= 1 || unit > 256 || !is_power_of_2(unit) || !want)
        return;
    ws = iblock & ~(u64) (unit - 1);
    we = round_up((u64) iblock + want, (u64) unit);
    if (we > U32_MAX || we - ws == want)
        return;
    /* The whole unit in the written block's own preallocated extent:
     * the block at its start is uninit, at the matching address, with
     * the run reaching the unit's end. */
    if (cetrafs_tree_lookup(inode, raw, (u32) ws, &lws, &run, &uninit, &found, false) || !found || !uninit ||
        lws + (iblock - ws) != lba || run < we - ws)
        return;
    if (cetrafs_unit_dio_busy(inode, (u32) ws, (u32) (iblock - ws)) ||
        cetrafs_unit_dio_busy(inode, iblock + want, (u32) (we - iblock - want))) {
        atomic64_inc(&cetrafs_convert_unit_busy);
        return;
    }
    {
        int zret = cetrafs_convert_zero_side(inode, (u32) ws, lws, (u32) (iblock - ws), pending_landed);

        if (!zret)
            zret = cetrafs_convert_zero_side(inode, iblock + want, lba + want, (u32) (we - iblock - want),
                                             pending_landed);
        if (zret == -EBUSY)
            atomic64_inc(&cetrafs_convert_unit_busy);
        if (zret)
            return; /* not all zeroed: the unit is not marked written; the block alone is */
    }
    *cv_iblock = (u32) ws;
    *cv_lba = lws;
    *cv_want = (u32) (we - ws);
    atomic64_inc(&cetrafs_convert_widened);
}

static int __cetrafs_get_block(struct inode *inode,
                               sector_t iblock,
                               struct buffer_head *bh_result,
                               int create,
                               bool reader,
                               enum cetrafs_gb_mode mode)
{
    u32 want = 1, converted = 1, ahead = 0;
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    u64 lba;
    u32 bg_id;
    u32 run = 1; /* contiguous blocks mappable from iblock (see below) */
    bool found, merged, uninit = false;
    bool dio_prealloc = false;
    u32 prun = 0; /* pending blocks from iblock (see the lookup below) */
    bool relooked = false;
    unsigned int move_seq;
    int move_reruns = 0;
    bool moving = false;
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

relookup:
    move_seq = cetrafs_tree_move_sample(inode); /* before the record: a move may stage a new root */
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
    /* A miss while a tree move ran is not believed: the walk may have
     * passed where the extent went (cetrafs_tree_move_begin()). Read the
     * record again and walk again; never answer "hole" from a walk a move
     * overlapped -- at the bound, fail. A writer holds invalidate_lock,
     * so no move overlaps its walk and this never fires for it. */
    if (!found && cetrafs_tree_move_overlapped(inode, move_seq)) {
        if (++move_reruns > CETRAFS_TREE_MOVE_RERUNS) {
            pr_err_ratelimited("ino=%llu: block %llu: every lookup overlapped an extent-tree move (%d tries) -- "
                               "refusing to answer\n",
                               (unsigned long long) inode->i_ino, (unsigned long long) iblock, move_reruns - 1);
            return -EIO;
        }
        cetrafs_tree_move_backoff();
        goto relookup;
    }
    /* A shared-lock overwrite maps written blocks only (enum
     * cetrafs_gb_mode, OVERWRITE). A pending block is uninit in the tree,
     * so it is refused here too, before the pending-set mapping below
     * could make it data for this write. */
    if (mode == CETRAFS_GB_OVERWRITE && (!found || uninit)) {
        if (!create)
            return 0; /* not written: the caller takes the exclusive path */
        pr_err_ratelimited("ino=%llu: block %llu is not written under a shared-lock overwrite -- refusing to allocate\n",
                           (unsigned long long) inode->i_ino, (unsigned long long) iblock);
        return -EIO;
    }
    /* A buffered write's block, not yet converted: data to this node
     * (enum cetrafs_gb_mode) -- to a reader, a DIO, writeback, a second
     * write into the block -- and never re-zeroed as new. */
    if (found && uninit && mode != CETRAFS_GB_CONVERT && mode != CETRAFS_GB_CONVERT_PENDING &&
        S_ISREG(inode->i_mode)) {
        if (unlikely(cetrafs_pending_race_delay_ms))
            msleep(cetrafs_pending_race_delay_ms);
        prun = cetrafs_pending_run(inode, (u32) iblock);
        if (prun) {
            uninit = false;
            run = min_t(u32, run ? run : 1, prun);
        } else if (!relooked) {
            /*
             * Conversion marks the block written, THEN drops it from
             * the set (cetrafs_convert_pending_locked()). Landing
             * between the tree read above and this miss, it leaves
             * "unwritten" and "not pending" -- zeros over written
             * data. A miss caused by the conversion's clear is ordered
             * after its flip, so one more lookup sees the block
             * written. Only an unwritten block pays for it.
             *
             * Not reachable today -- every mapper is serialised
             * against conversion: O_DIRECT reads by i_rwsem, buffered
             * reads and faults by invalidate_lock, writeback by the
             * conversion's own flush (buffered_pending_race.sh shows
             * the first three). Here for the first one that is not.
             */
            relooked = true;
            smp_rmb(); /* pairs with the smp_wmb() before cetrafs_pending_clear() */
            goto relookup;
        }
    }
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
        ret = cetrafs_dio_mark_convert(inode, bh_result, iblock);
        if (ret)
            return ret;
        atomic64_inc(&cetrafs_map_calls);
        atomic64_add(bh_result->b_size >> inode->i_blkbits, &cetrafs_map_blocks);
        return 0;
    }
    if (found && uninit && mode == CETRAFS_GB_BUF) {
        /* Mapped as it is and remembered; converted at the next
         * durability boundary, once its data is on the device. New:
         * whatever the write does not cover is zeroed in the page. */
        u64 w = bh_result->b_size >> inode->i_blkbits;
        u32 n = (u32) ((w > 1 && run > 1) ? min_t(u64, w, run) : 1);

        ret = cetrafs_pending_add(inode, (u32) iblock, n);
        if (ret)
            return ret;
        map_bh(bh_result, sb, lba);
        bh_result->b_size = (size_t) n << inode->i_blkbits;
        set_buffer_new(bh_result);
        atomic64_inc(&cetrafs_map_calls);
        atomic64_add(n, &cetrafs_map_blocks);
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
        {
            u32 cv_iblock = (u32) iblock, cv_want = want;
            u64 cv_lba = lba;

            if (mode == CETRAFS_GB_CONVERT || mode == CETRAFS_GB_CONVERT_PENDING)
                cetrafs_convert_widen(inode, &raw, (u32) iblock, lba, want, mode == CETRAFS_GB_CONVERT_PENDING,
                                      &cv_iblock, &cv_lba, &cv_want);
            ahead = (u32) iblock - cv_iblock;
            ret = cetrafs_tree_convert(inode, &raw, cv_iblock, cv_lba, cv_want, &converted, &moving);
            /* A convert may stop short (a split with one free slot hands
             * the rest back), possibly before iblock: go on from where it
             * stopped until the caller's block is in. Counted from the
             * unit's start, so the blocks before iblock are not this
             * call's to report, and no more than the caller asked for. */
            while (!ret && converted <= ahead) {
                u32 more = 0;

                if (WARN_ON_ONCE(converted >= cv_want)) {
                    ret = -EIO;
                    break;
                }
                ret = cetrafs_tree_convert(inode, &raw, cv_iblock + converted, cv_lba + converted, cv_want - converted,
                                           &more, &moving);
                converted += more;
            }
            if (!ret)
                converted = min_t(u32, converted - ahead, want);
        }
        if (ret)
            cetrafs_tree_move_end(inode, &moving); /* nothing below stages it: what moved stays in core */
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
            ret = cetrafs_write_raw_inode_self(inode, &raw, /*sync=*/true);
            cetrafs_tree_move_end(inode, &moving);
            if (ret)
                return ret;
        } else {
            cetrafs_inode_fd_stage(inode, &raw);
            mark_inode_dirty(inode);
            /* The new record -- a root the move may have grown -- is now
             * what a lookup reads: the move is over. */
            cetrafs_tree_move_end(inode, &moving);
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
    if (mode == CETRAFS_GB_CONVERT_PENDING) {
        /* A pending block is one a buffered write put data in, and
         * truncate and punch take theirs out of the set: a hole here is
         * a block the map lost. Clearing it as "nothing to convert" made
         * the next fsync report success over data that reads as zeros
         * (audit 2026-11-14 FD-1). Said, and kept pending. */
        pr_err_ratelimited("ino=%llu: buffered block %llu is in no extent -- its data cannot be reached\n",
                           (unsigned long long) inode->i_ino, (unsigned long long) iblock);
        return -EIO;
    }
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
    dio_prealloc = mode == CETRAFS_GB_DIO || mode == CETRAFS_GB_BUF;
    /* Room for the tree change before a block is allocated for it
     * (cetrafs_deferred_room()). */
    ret = cetrafs_deferred_room(inode);
    if (ret)
        return ret;

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

                    if (cetrafs_bg_recount_after_enospc(sb, bg_id, &delta) != 0)
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
            bool keep;

            ret = cetrafs_dirent_block_init(sb, lba, &keep);
            if (ret) {
                /* keep: a live directory still lists it, or its owner
                 * could not be read -- the bit we just set may be the
                 * truth, so it stays set (a leak, never a share). */
                if (!keep)
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
        ret = cetrafs_write_raw_inode_self(inode, &raw, /*sync=*/true);
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
    /* After the stage above, so a failure leaves the block where the
     * tree says it is: preallocated, reading as zeros. */
    if (mode == CETRAFS_GB_BUF) {
        ret = cetrafs_pending_add(inode, (u32) iblock, 1);
        if (ret)
            return ret;
    }
    map_bh(bh_result, sb, lba);
    set_buffer_new(bh_result);
    if (mode == CETRAFS_GB_DIO) {
        ret = cetrafs_dio_mark_convert(inode, bh_result, iblock);
        if (ret)
            return ret; /* the block stays preallocated, reading as zeros */
    }

    /* A growing OPEN regular file that just added a NEW extent (not a
     * merge) to its external tree is the moment fragmentation happens;
     * nudge the background defragmenter so always-open files (VM images)
     * get healed in flight, not only at close. The frag-index gate is in
     * consider(); it recomputes the exact index under lock. */
    if (!merged && leaf_count && S_ISREG(inode->i_mode) && !cetrafs_lock_defrag_quiet(inode))
        cetrafs_defrag_consider(inode, leaf_count, (u64) iblock + 1);

    return 0;
}

/* A regular file's buffered write is BUF (enum cetrafs_gb_mode); a
 * directory or a symlink keeps PLAIN -- its blocks are written
 * synchronously, under the lock that publishes them. */
static int cetrafs_get_block(struct inode *inode, sector_t iblock, struct buffer_head *bh_result, int create)
{
    enum cetrafs_gb_mode mode =
        S_ISREG(inode->i_mode) && !READ_ONCE(cetrafs_buf_convert_early) ? CETRAFS_GB_BUF : CETRAFS_GB_PLAIN;

    return __cetrafs_get_block(inode, iblock, bh_result, create, false, mode);
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
    int ret;

    if (cetrafs_bulk_fenced(inode))
        return -EIO;
    /* PLAIN: writeback holds no invalidate_lock, so it may not add to
     * the pending set. It never maps anything new anyway (below). */
    ret = __cetrafs_get_block(inode, iblock, bh, create, false, CETRAFS_GB_PLAIN);

    if (!ret && buffer_new(bh)) {
        pr_err_ratelimited("ino=%llu: writeback allocated/converted block %llu -- every block should be mapped "
                           "before its page is dirtied\n",
                           (unsigned long long) inode->i_ino, (unsigned long long) iblock);
        WARN_ON_ONCE(1);
    }
    return ret;
}

/* TEST ONLY: after this many writeback chunks, one stall of wb_stall_ms
 * -- the middle of a writepages pass, where a lease can run out
 * (tests/kernel/writepages_fence_midloop.sh). */
static unsigned int cetrafs_wb_stall_ms, cetrafs_wb_stall_after;
cetrafs_test_param(wb_stall_ms, cetrafs_wb_stall_ms, uint, 0644);
cetrafs_test_param(wb_stall_after, cetrafs_wb_stall_after, uint, 0644);

/* Pages per writeback chunk: the fence is asked between chunks. 8 MiB
 * keeps mpage's merged bios whole on a streaming file. */
#define CETRAFS_WB_CHUNK_PAGES 2048UL

/* Fenced now? Asked between chunks; the test stall sits in front of it. */
static bool cetrafs_wb_chunk_fenced(struct inode *inode)
{
    if (unlikely(READ_ONCE(cetrafs_wb_stall_ms)) && READ_ONCE(cetrafs_wb_stall_after) && !--cetrafs_wb_stall_after)
        msleep(xchg(&cetrafs_wb_stall_ms, 0));
    return cetrafs_bulk_fenced(inode);
}

/*
 * Writeback, a chunk at a time, the fence asked before each (B-17). One
 * gate at the start covered the whole pass, and a WB_SYNC_ALL pass over
 * GiB of dirty pages outlives it by minutes: the pages written after the
 * lease ran out landed on blocks a peer owned by then. The get_block
 * callback cannot ask -- a page whose buffers are mapped, which is every
 * page of an image, never reaches it.
 *
 * A ranged pass (fsync, sync, WB_SYNC_ALL) walks its range in windows,
 * jumping over the clean stretches by the dirty tag; a cyclic one (the
 * flusher) hands mpage its quota a chunk at a time, mapping's
 * writeback_index carrying the position.
 */
static int cetrafs_writepages(struct address_space *mapping, struct writeback_control *wbc)
{
    struct inode *inode = mapping->host;
    int ret = 0;

    if (cetrafs_sb_is_fenced(inode->i_sb))
        return -EIO; /* self-fenced: dirty data never reaches the device */
    if (READ_ONCE(cetrafs_fence_per_block_off)) {
        (void) cetrafs_wb_chunk_fenced(inode); /* the test stall only: the old pass asks no more */
        return mpage_writepages(mapping, wbc, cetrafs_get_block_writeback);
    }

    if (!wbc->range_cyclic) {
        loff_t start = wbc->range_start, end = wbc->range_end;
        pgoff_t idx = start >> PAGE_SHIFT, last = end >> PAGE_SHIFT;

        while (idx <= last) {
            pgoff_t stop;

            rcu_read_lock();
            if (!xa_find(&mapping->i_pages, &idx, last, PAGECACHE_TAG_DIRTY))
                idx = last + 1;
            rcu_read_unlock();
            if (idx > last)
                break;
            if (cetrafs_wb_chunk_fenced(inode)) {
                ret = -EIO;
                break;
            }
            stop = idx + CETRAFS_WB_CHUNK_PAGES - 1;
            if (stop < idx || stop > last)
                stop = last;
            wbc->range_start = (loff_t) idx << PAGE_SHIFT;
            wbc->range_end = stop == last ? end : ((loff_t) (stop + 1) << PAGE_SHIFT) - 1;
            ret = mpage_writepages(mapping, wbc, cetrafs_get_block_writeback);
            if (ret || stop == last)
                break;
            if (wbc->sync_mode == WB_SYNC_NONE && wbc->nr_to_write <= 0)
                break;
            idx = stop + 1;
        }
        wbc->range_start = start;
        wbc->range_end = end;
        return ret;
    }

    {
        long left = wbc->nr_to_write;

        while (left > 0) {
            long chunk = min_t(long, left, CETRAFS_WB_CHUNK_PAGES);

            if (cetrafs_wb_chunk_fenced(inode)) {
                ret = -EIO;
                break;
            }
            wbc->nr_to_write = chunk;
            ret = mpage_writepages(mapping, wbc, cetrafs_get_block_writeback);
            left -= chunk - wbc->nr_to_write;
            if (ret || wbc->nr_to_write > 0)
                break; /* an error, or nothing more to write */
        }
        wbc->nr_to_write = left;
    }
    return ret;
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
cetrafs_test_param(punch_pagecache_delay_ms, cetrafs_punch_pagecache_delay_ms, uint, 0644);
MODULE_PARM_DESC(punch_pagecache_delay_ms, "TEST ONLY: pause inside punch between the page-cache drop and the free");

/* TEST ONLY: pause a punch or truncate just before (_pre) or just after
 * (_post) its last "is a peer using this file?" check before the
 * publish. tests/kernel/punch_peer_late.sh. */
static unsigned int cetrafs_truncate_free_stall_ms;
cetrafs_test_param(truncate_free_stall_ms, cetrafs_truncate_free_stall_ms, uint, 0644);
MODULE_PARM_DESC(truncate_free_stall_ms, "TEST ONLY: pause a truncate between its publish and its frees");
static unsigned int cetrafs_rebuild_stall_pre_ms, cetrafs_rebuild_stall_post_ms;
cetrafs_test_param(rebuild_stall_pre_ms, cetrafs_rebuild_stall_pre_ms, uint, 0644);
MODULE_PARM_DESC(rebuild_stall_pre_ms, "TEST ONLY: pause a punch/truncate before its pre-publish peer check");
cetrafs_test_param(rebuild_stall_post_ms, cetrafs_rebuild_stall_post_ms, uint, 0644);
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
 *
 * A peer's defrag pin counts as yes too, and is NOT waited out
 * (cetrafs_lock_foreign_user_settled()): the second ask runs after the
 * new map was computed, and a move committed meanwhile made it stale.
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

/* TEST ONLY: the old answers to a peer-open file -- preallocation
 * -ETXTBSY, a same-size truncate -ETXTBSY (B-11). */
static bool cetrafs_falloc_foreign_etxtbsy;
cetrafs_test_param(falloc_foreign_etxtbsy, cetrafs_falloc_foreign_etxtbsy, bool, 0644);

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
cetrafs_test_param(fail_extent_record_write, cetrafs_fail_extent_record_write, bool, 0644);
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
    bool foreign; /* a dropped block outside our own groups (cetrafs_frees_begin()) */
    int ret, zret;

    recs = kmalloc(2 * sizeof(*recs), GFP_NOFS);
    if (!recs)
        return -ENOMEM;
    /* The leaves read below decide what is freed: not through a verdict
     * cached a second ago (cetrafs_lock_expire_verdicts(), audit L6). */
    cetrafs_lock_expire_verdicts(inode);

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
    ret = cetrafs_tree_patch(inode, &raw, new_block_count, U64_MAX, NULL, 0, kept,
                             cetrafs_flat_data_blocks(new_flat, kept), &meta_blocks);
    if (ret == -EAGAIN)
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
     * (the old one is still the durable truth) and bail.
     *
     * From the publish until the frees below the dropped blocks are named
     * by nothing and not yet free: announced first, so no scrub -- ours
     * or the owning peer's -- takes them for leaked (cetrafs_frees_begin()). */
    foreign = !(cetrafs_flat_range_is_ours(sb, old_flat, old_n, new_block_count, U64_MAX) &&
                cetrafs_tree_meta_is_ours(inode, &old_raw));
    ret = cetrafs_frees_begin(sb, &foreign);
    if (ret) {
        cetrafs_tree_free_meta_except(inode, &raw, &old_raw);
        kvfree(new_flat);
        kvfree(old_flat);
        kfree(recs);
        return ret;
    }
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
                                                         : cetrafs_write_raw_inode_fd_planned(sb, inode->i_ino, &raw, inode,
                                                                                              cetrafs_le64(old_raw.file_seq));
        if (!ret) {
            cetrafs_inode_fd_published(inode, fd_seq); /* this publish supersedes the overlaid shadow */
            i_size_write(inode, new_size);
        }
        cetrafs_inode_fd_pub_unlock(inode);
    }
    if (ret) {
        cetrafs_frees_end(sb, foreign);
        cetrafs_tree_free_meta_except(inode, &raw, &old_raw);
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
    /* The dropped blocks leave the pending set with the tree: a stale
     * entry would make a NEW preallocated block at that offset read as
     * data (enum cetrafs_gb_mode). */
    {
        u64 keep = CETRAFS_DIV_ROUND_UP((u64) new_size, CETRAFS_BLOCK_SIZE);

        if (keep <= U32_MAX)
            cetrafs_pending_clear(inode, (u32) keep, U32_MAX);
    }
    if (cetrafs_truncate_free_stall_ms)
        msleep(cetrafs_truncate_free_stall_ms); /* TEST ONLY: see the parameter */

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
        cetrafs_tree_free_meta_except(inode, &old_raw, &raw);
        cetrafs_leaf_array_trim(sb, old_flat, old_n, new_block_count, &discard, /*do_free=*/true);
    }
    cetrafs_frees_end(sb, foreign);

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
 * combination besides plain preallocation, cetrafs_do_allocate(), that
 * this project's fallocate(2) support claims; ZERO_RANGE is the two in
 * sequence). COLLAPSE_RANGE and INSERT_RANGE are not implemented.
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
/* Run allocation for fallocate (audit FD-8): a block that needs backing
 * claims the next run of consecutive blocks in one allocator call
 * (cetrafs_alloc_run_after()), instead of one allocator call per block
 * under both exclusive locks. Blocks claimed and not used are given back
 * at the end. TEST ONLY falloc_run_off restores one allocator call per
 * block (the control of tests/kernel/fallocate_runs.sh). */
#define CETRAFS_FALLOC_RUN 256u
static bool cetrafs_falloc_run_off;
cetrafs_test_param(falloc_run_off, cetrafs_falloc_run_off, bool, 0644);
MODULE_PARM_DESC(falloc_run_off, "TEST ONLY: fallocate allocates one block per allocator call, as before FD-8");
static atomic_long_t cetrafs_falloc_alloc_calls = ATOMIC_LONG_INIT(0);
/* Read by procfs info (fallocate_alloc_calls). */
long cetrafs_falloc_alloc_call_count(void)
{
    return atomic_long_read(&cetrafs_falloc_alloc_calls);
}

/* FD-8: the planner walks the old tree's extent map (cetrafs_falloc_map)
 * instead of looking every block up in it. TEST ONLY falloc_lookup_per_block
 * restores the per-block tree lookup (the control of
 * tests/kernel/fallocate_map_walk.sh). fallocate_tree_lookups counts the
 * lookups the planner made, which is what that suite measures. */
static bool cetrafs_falloc_lookup_per_block;
cetrafs_test_param(falloc_lookup_per_block, cetrafs_falloc_lookup_per_block, bool, 0644);
MODULE_PARM_DESC(falloc_lookup_per_block, "TEST ONLY: fallocate looks every block up in the tree, as before FD-8");
static atomic_long_t cetrafs_falloc_tree_lookups = ATOMIC_LONG_INIT(0);
long cetrafs_falloc_tree_lookup_count(void)
{
    return atomic_long_read(&cetrafs_falloc_tree_lookups);
}

/*
 * Test-only: slow the per-block allocation loop down.
 *
 * Killability cannot be tested by asking for a huge range: the loop
 * ends at ENOSPC, which on any image a test can afford arrives in well
 * under a second. This makes the loop long without making the device
 * big, so a SIGKILL has something to land in.
 */
static unsigned int cetrafs_fallocate_block_delay_us;
cetrafs_test_param(fallocate_block_delay_us, cetrafs_fallocate_block_delay_us, uint, 0644);

MODULE_PARM_DESC(fallocate_block_delay_us, "TEST ONLY: microseconds to spend per preallocated block");

/*
 * The blocks a preallocation holds before its one publish, registered
 * with the scrub (cetrafs_resv_publish()). Until the publish they are
 * bitmap-allocated and named by nothing on the device -- exactly what
 * the scrub frees -- and a large fallocate holds them for many seconds,
 * far past the two-pass gap the scrub's argument rests on. A Block
 * Group the call has finished with keeps a still allocation count, so
 * nothing else stopped the scrub freeing them; the allocator then
 * handed them to another file and the publish named them too (audit
 * 2026-11-06 H2; tests/kernel/fallocate_scrub_spares.sh).
 *
 * One span per Block Group touched, widened to cover each block as it
 * is allocated (plus some slack, so it is not re-published per block).
 * A span may cover blocks that are not ours; the scrub only keeps those
 * longer. A group is at most U32_MAX blocks, so a span's count fits.
 * Spans are allocated one by one: a published span's link must not move.
 */
#define CETRAFS_FALLOC_RESV_SLACK 1024u
struct cetrafs_falloc_span {
    struct cetrafs_resv_span span;
    u32 bg_id;
};
struct cetrafs_falloc_resv {
    struct cetrafs_falloc_span **v;
    u32 n, cap;
};

static int cetrafs_falloc_resv_cover(struct super_block *sb, struct cetrafs_falloc_resv *r, u32 bg_id, u64 lba)
{
    struct cetrafs_falloc_span *fs = NULL;
    u64 start, end;
    u32 i;

    for (i = r->n; i-- > 0;)
        if (r->v[i]->bg_id == bg_id) {
            fs = r->v[i];
            break;
        }
    if (!fs) {
        if (r->n == r->cap) {
            u32 ncap = r->cap ? r->cap * 2 : 8;
            struct cetrafs_falloc_span **nv = kvmalloc_array(ncap, sizeof(*nv), GFP_NOFS);

            if (!nv)
                return -ENOMEM;
            if (r->n)
                memcpy(nv, r->v, (size_t) r->n * sizeof(*nv));
            kvfree(r->v);
            r->v = nv;
            r->cap = ncap;
        }
        fs = kmalloc(sizeof(*fs), GFP_NOFS);
        if (!fs)
            return -ENOMEM;
        INIT_LIST_HEAD(&fs->span.link);
        fs->span.start = 0;
        fs->span.count = 0;
        fs->bg_id = bg_id;
        r->v[r->n++] = fs;
    }
    if (fs->span.count && lba >= fs->span.start && lba < fs->span.start + fs->span.count)
        return 0;
    start = fs->span.count ? min(fs->span.start, lba) : lba;
    end = fs->span.count ? max(fs->span.start + fs->span.count, lba + 1) : lba + 1;
    end = max(end, lba + 1 + CETRAFS_FALLOC_RESV_SLACK);
    if (end - start > U32_MAX)
        end = start + U32_MAX; /* still covers lba: one group is <= U32_MAX blocks */
    cetrafs_resv_publish(sb, &fs->span, start, (u32) (end - start));
    return 0;
}

/* After the publish, or after the blocks were given back. */
static void cetrafs_falloc_resv_drop(struct super_block *sb, struct cetrafs_falloc_resv *r)
{
    u32 i;

    for (i = 0; i < r->n; i++) {
        cetrafs_resv_unpublish(sb, &r->v[i]->span);
        kfree(r->v[i]);
    }
    kvfree(r->v);
    r->v = NULL;
    r->n = r->cap = 0;
}

/* Blocks of a claimed run this call never used: one free for the span.
 * Never published, and held in the reservation registry until here (H2). */
static void cetrafs_falloc_run_give_back_span(struct super_block *sb, u64 lba, u32 n)
{
    if (n)
        (void) cetrafs_free_data_extent(sb, lba, n);
}

/*
 * FD-8: the old tree's mapped extents inside the call's range, sorted by
 * logical block and read ONCE per call. The planner used to look each
 * block up in the tree -- a leaf scan under the buffer lock, per block --
 * and a run claimed 255 blocks past each new one whether or not a mapped
 * block cut it short, the overhang then given back. With the map, a hole
 * is walked from its start to the next mapped block and a run never
 * crosses one. The tree is not changed until the publish, so the snapshot
 * stays true for the whole plan. Each entry is checked as the lookup
 * checked a found block (cetrafs_tree_lookup()).
 */
struct cetrafs_falloc_map {
    cetrafs_extent_t *v;
    u32 n;
};

static int cetrafs_falloc_map_cmp(const void *a, const void *b)
{
    u32 ea = cetrafs_le32(((const cetrafs_extent_t *) a)->ee_block);
    u32 eb = cetrafs_le32(((const cetrafs_extent_t *) b)->ee_block);

    return ea < eb ? -1 : ea > eb;
}

static u64 cetrafs_falloc_map_start(const cetrafs_extent_t *e)
{
    return cetrafs_le32(e->ee_block);
}

static u64 cetrafs_falloc_map_end(const cetrafs_extent_t *e)
{
    return cetrafs_le32(e->ee_block) + cetrafs_extent_len(e->ee_len);
}

static void cetrafs_falloc_map_free(struct cetrafs_falloc_map *m)
{
    kvfree(m->v);
    m->v = NULL;
    m->n = 0;
}

static int cetrafs_falloc_map_build(struct inode *inode, const cetrafs_inode_t *raw, u64 start_block, u64 end_block,
                                    struct cetrafs_falloc_map *m)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_inode_extents ex;
    u32 i, k = 0;
    int ret;

    m->v = NULL;
    m->n = 0;
    ret = cetrafs_inode_extents_get(inode, raw, &ex);
    if (ret)
        return ret;
    m->v = kvmalloc_array(ex.entries ? ex.entries : 1, sizeof(*m->v), GFP_NOFS);
    if (!m->v) {
        cetrafs_inode_extents_put(&ex);
        return -ENOMEM;
    }
    for (i = 0; i < ex.entries; i++) {
        const cetrafs_extent_t *e = &ex.arr[i];
        u64 lba = cetrafs_extent_phys_from_hilo(e->ee_start_hi, e->ee_start_lo);
        u64 run = cetrafs_extent_len(e->ee_len);

        if (!run || cetrafs_falloc_map_end(e) <= start_block || cetrafs_falloc_map_start(e) >= end_block)
            continue;
        /* The same check cetrafs_tree_lookup() makes of a block it found. */
        ret = cetrafs_lba_run_check(sb, lba, run);
        if (ret == -EAGAIN) {
            ret = -EIO; /* past a layout this node cannot catch up with: not damage */
            goto out;
        }
        if (ret) {
            pr_err_ratelimited("ino=%llu: extent [%llu,+%llu) maps to [%llu,+%llu), which is not a data address -- refusing it (fsck)\n",
                               (unsigned long long) inode->i_ino, (unsigned long long) cetrafs_falloc_map_start(e),
                               (unsigned long long) run, (unsigned long long) lba, (unsigned long long) run);
            cetrafs_sb_corrupt_inode(inode);
            ret = -EUCLEAN;
            goto out;
        }
        m->v[k++] = *e;
    }
    m->n = k;
    sort(m->v, k, sizeof(*m->v), cetrafs_falloc_map_cmp, NULL);
    ret = 0;
out:
    cetrafs_inode_extents_put(&ex);
    if (ret)
        cetrafs_falloc_map_free(m);
    return ret;
}

static void cetrafs_falloc_run_give_back(struct super_block *sb, u64 *lba, u32 *left)
{
    cetrafs_falloc_run_give_back_span(sb, *lba, *left);
    *left = 0;
}

/* TEST ONLY: preallocation's rebuild stalls between its publish and the
 * old tree's frees; and the frees go unannounced, as before B-31
 * (tests/kernel/fallocate_free_announced.sh). */
static unsigned int cetrafs_falloc_free_stall_ms;
cetrafs_test_param(falloc_free_stall_ms, cetrafs_falloc_free_stall_ms, uint, 0644);
MODULE_PARM_DESC(falloc_free_stall_ms, "TEST ONLY: stall preallocation between its publish and the old tree's frees");
static bool cetrafs_falloc_frees_unannounced;
cetrafs_test_param(falloc_frees_unannounced, cetrafs_falloc_frees_unannounced, bool, 0644);
MODULE_PARM_DESC(falloc_frees_unannounced, "TEST ONLY: preallocation frees its old tree with no frees-in-flight announcement");

static int cetrafs_do_allocate(struct inode *inode, loff_t offset, loff_t len, bool keep_size)
{
    struct cetrafs_falloc_resv resv = {};
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t *recs; /* [0]=raw, [1]=old_raw -- off the stack */
#define raw (recs[0])
#define old_raw (recs[1])
    u64 b, start_block, end_block, hint = 0;
    u64 added = 0, meta_blocks = 0, plan_seq;
    bool foreign = false, announced = false; /* the old tree's meta is a peer's (cetrafs_frees_begin()) */
    loff_t end = offset + len;
    cetrafs_extent_t *add = NULL, *flat = NULL;
    u32 add_n = 0, add_cap = 0, flat_n = 0;
    u32 tree_have, tree_cap;
    bool built = false;
    int ret, loop_ret = 0;

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

    /*
     * The record this call plans from: fresh unless the cache is
     * provably this node's, the gate get_block() and truncate apply
     * (CLAUDE.md rule 1). Its file_seq is the plan's stamp.
     *
     * Built into a COPY, as truncate and punch are: the new extents go
     * into a flat array, a fresh tree is built from old + new, and it
     * is published only if no other node has stamped the file since the
     * read -- otherwise every block this call allocated is freed and it
     * fails ETXTBSY, with the old tree untouched. Appending in place
     * edited live leaves through a loop measured at 11 s, so a peer
     * that opened the file in that window (nofilelock) had its extents
     * published over, with nothing left to refuse at the publish.
     */
    recs = kmalloc(2 * sizeof(*recs), GFP_NOFS);
    if (!recs)
        return -ENOMEM;
    if (!cetrafs_lock_held_for_write_locally(inode))
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode_overlaid(sb, inode, &raw); /* torn-read-safe vs a concurrent publish */
    if (ret)
        goto out_free;
    /* The same three bounds get_block applies before it indexes the
     * inline array by eh_entries (audit L12). */
    if (cetrafs_le16(raw.eh.eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(raw.eh.eh_depth) > CETRAFS_EXT_MAX_DEPTH ||
        cetrafs_le16(raw.eh.eh_entries) > ARRAY_SIZE(raw.et.leaf)) {
        ret = -EIO;
        goto out_free;
    }
    plan_seq = cetrafs_le64(raw.file_seq);
    old_raw = raw; /* its eh/et name the OLD tree, freed after the publish */
    /*
     * The tree holds a bounded number of extents, and on a fragmented
     * volume every block of a preallocation can be one. The plan used to
     * run to the end of the range regardless -- allocating, and growing
     * 'add' -- and only cetrafs_tree_build() refused, after all of it,
     * throwing the whole preallocation away (audit 2026-11-05, class
     * 13/12). Stop planning where the tree is full instead: what fits is
     * published and the call reports -ENOSPC, as a stop part-way does.
     * tests/kernel/fallocate_tree_full.sh.
     */
    tree_have = cetrafs_tree_extent_count(inode, &raw);
    tree_cap = cetrafs_tree_max_extents();
    u64 run_lba = 0; /* blocks claimed for a run and not yet used */
    u32 run_left = 0, run_bg = 0;
    bool per_block = READ_ONCE(cetrafs_falloc_lookup_per_block);
    struct cetrafs_falloc_map map = {0};
    u32 mi = 0; /* the first map entry that does not end before b */

    if (!per_block) {
        ret = cetrafs_falloc_map_build(inode, &raw, start_block, end_block, &map);
        if (ret)
            goto out_free;
    }

    for (b = start_block; b < end_block; b++) {
        bool found = false, un = false;
        u64 hole_end = end_block; /* the hole at b ends here: next mapped block or range end */
        u32 bg_id;
        u64 lba;

        /*
         * One block per iteration, up to CETRAFS_MAX_FILE_BLOCKS of
         * them, under inode_lock -- a 16 TiB request is billions of
         * passes. Without these two lines it could neither be
         * scheduled away from nor killed: fallocate(2) on a large
         * range became an uninterruptible occupation of the CPU and
         * the inode.
         *
         * Stopping early leaves the range PARTIALLY preallocated,
         * which is allowed and is what the other filesystems do: what
         * was allocated so far is still built and published below.
         */
        if (fatal_signal_pending(current)) {
            loop_ret = -EINTR;
            break;
        }
        cond_resched();
        if (cetrafs_fallocate_block_delay_us)
            usleep_range(cetrafs_fallocate_block_delay_us, cetrafs_fallocate_block_delay_us * 2);

        /* Looked up in the OLD tree, which nothing here changes. */
        if (per_block) {
            loop_ret = cetrafs_tree_lookup(inode, &raw, (u32) b, &lba, NULL, &un, &found, false);
            if (loop_ret)
                break;
            atomic_long_inc(&cetrafs_falloc_tree_lookups);
        } else {
            while (mi < map.n && cetrafs_falloc_map_end(&map.v[mi]) <= b)
                mi++;
            if (mi < map.n && cetrafs_falloc_map_start(&map.v[mi]) <= b) {
                found = true;
                /* Its whole extent is backed: nothing in it needs a look. */
                b = cetrafs_falloc_map_end(&map.v[mi]) - 1;
            } else if (mi < map.n) {
                hole_end = min_t(u64, end_block, cetrafs_falloc_map_start(&map.v[mi]));
            }
        }
        if (found) {
            /* A run claimed past this block cannot be used across it. */
            cetrafs_falloc_run_give_back(sb, &run_lba, &run_left);
            continue; /* already backed (written or preallocated) */
        }

        if (!hint)
            hint = cetrafs_tree_last_contig_lba(inode, &raw);

        if (run_left) {
            lba = run_lba++; /* the next block of the run claimed for it */
            bg_id = run_bg;
            run_left--;
        } else {
            atomic_long_inc(&cetrafs_falloc_alloc_calls);
            loop_ret = cetrafs_alloc_pick_bg(sb, &bg_id);
            if (loop_ret)
                break;
            atomic_long_inc(&cetrafs_falloc_alloc_calls);
            loop_ret = cetrafs_alloc_data_block_near(sb, bg_id, hint, &lba);
            if (loop_ret == -ENOSPC || loop_ret == -EAGAIN) { /* count lying, or group released since the pick -- see the helper */
                atomic_long_inc(&cetrafs_falloc_alloc_calls);
                loop_ret = cetrafs_alloc_block_anywhere(sb, &bg_id, &lba);
            }
            if (loop_ret)
                break;
            /* The run stays in this hole: a mapped block after b ends it. */
            if (!READ_ONCE(cetrafs_falloc_run_off) && hole_end - b > 1) {
                u32 want = (u32) min_t(u64, CETRAFS_FALLOC_RUN - 1, hole_end - b - 1);
                u32 got;

                atomic_long_inc(&cetrafs_falloc_alloc_calls);
                got = cetrafs_alloc_run_after(sb, bg_id, lba + 1, want);
                if (got) {
                    /* Covered at once: claimed blocks nothing references
                     * must not be unprotected from the scrub until used. */
                    loop_ret = cetrafs_falloc_resv_cover(sb, &resv, bg_id, lba + got);
                    if (loop_ret) {
                        cetrafs_free_data_block(sb, lba); /* not used either */
                        cetrafs_falloc_run_give_back_span(sb, lba + 1, got);
                        break;
                    }
                    run_bg = bg_id;
                    run_lba = lba + 1;
                    run_left = got;
                }
            }
        }
        /* Before anything else can take long: from here until the
         * publish, the registry is all that tells the scrub it is ours. */
        loop_ret = cetrafs_falloc_resv_cover(sb, &resv, bg_id, lba);
        if (loop_ret) {
            cetrafs_free_data_block(sb, lba);
            break;
        }

        /* Extend the last new extent when both runs continue, else
         * start one. */
        if (add_n && cetrafs_le32(add[add_n - 1].ee_block) + cetrafs_extent_len(add[add_n - 1].ee_len) == b &&
            cetrafs_extent_phys_from_hilo(add[add_n - 1].ee_start_hi, add[add_n - 1].ee_start_lo) +
                    cetrafs_extent_len(add[add_n - 1].ee_len) ==
                lba &&
            cetrafs_extent_len(add[add_n - 1].ee_len) < CETRAFS_EXT_LEN_MASK) {
            add[add_n - 1].ee_len = cetrafs_extent_pack_len(cetrafs_extent_len(add[add_n - 1].ee_len) + 1, 1);
        } else {
            if ((u64) tree_have + add_n + 1 > tree_cap) {
                cetrafs_free_data_block(sb, lba);
                loop_ret = -ENOSPC; /* the tree is full: publish what fits */
                break;
            }
            if (add_n == add_cap) {
                u32 ncap = add_cap ? add_cap * 2 : 16;
                cetrafs_extent_t *na = kvmalloc_array(ncap, sizeof(*na), GFP_NOFS);

                if (!na) {
                    cetrafs_free_data_block(sb, lba);
                    loop_ret = -ENOMEM;
                    break;
                }
                if (add_n)
                    memcpy(na, add, (size_t) add_n * sizeof(*na));
                kvfree(add);
                add = na;
                add_cap = ncap;
            }
            memset(&add[add_n], 0, sizeof(add[add_n]));
            add[add_n].ee_block = cetrafs_cpu_to_le32((u32) b);
            add[add_n].ee_len = cetrafs_extent_pack_len(1, 1);
            cetrafs_extent_phys_to_hilo(lba, &add[add_n].ee_start_hi, &add[add_n].ee_start_lo);
            add_n++;
        }
        hint = lba + 1; /* keep the run contiguous so it stays ONE extent */
        added++;
    }

    /* Blocks claimed for a run and not used are referenced by nothing:
     * give them back before anything is published. */
    cetrafs_falloc_run_give_back(sb, &run_lba, &run_left);

    /* Nothing allocated and nothing to grow -- or nothing allocated and
     * the loop stopped on an error: nothing to publish. A plain
     * fallocate that failed before its first block published the new
     * size anyway and then returned the error (audit 2026-11-06 M14). */
    if (!added && (keep_size || end <= i_size_read(inode) || loop_ret)) {
        ret = loop_ret;
        goto out_free;
    }
    /* Stopped part-way: grow the size only over what was allocated. */
    if (loop_ret) {
        loff_t got = 0;
        u32 k;

        for (k = 0; k < add_n; k++) {
            loff_t e = ((loff_t) cetrafs_le32(add[k].ee_block) + cetrafs_extent_len(add[k].ee_len)) * CETRAFS_BLOCK_SIZE;

            if (e > got)
                got = e;
        }
        if (got < end)
            end = got;
    }

    if (added) {
        struct cetrafs_inode_extents ex;
        u32 old_n;

        ret = cetrafs_inode_extents_get(inode, &raw, &ex);
        if (ret)
            goto out_free_added;
        old_n = ex.entries;
        if ((u64) old_n + add_n > U32_MAX) {
            cetrafs_inode_extents_put(&ex);
            ret = -EFBIG;
            goto out_free_added;
        }
        flat = kvmalloc_array((size_t) old_n + add_n, sizeof(*flat), GFP_NOFS);
        if (!flat) {
            cetrafs_inode_extents_put(&ex);
            ret = -ENOMEM;
            goto out_free_added;
        }
        if (old_n)
            memcpy(flat, ex.arr, (size_t) old_n * sizeof(*flat));
        cetrafs_inode_extents_put(&ex);
        memcpy(flat + old_n, add, (size_t) add_n * sizeof(*flat));
        flat_n = old_n + add_n;

        /* The old tree with the new extents appended, copying only the
         * blocks that change, or a fresh tree; the old one stays intact
         * until the publish. */
        ret = cetrafs_tree_patch(inode, &raw, 0, 0, add, add_n, flat_n, cetrafs_flat_data_blocks(flat, flat_n),
                                 &meta_blocks);
        if (ret == -EAGAIN)
            ret = cetrafs_tree_build(inode, flat, flat_n, &raw, &meta_blocks);
        if (ret)
            goto out_free_added;
        built = true;
        raw.blocks = cetrafs_cpu_to_le64((cetrafs_flat_data_blocks(flat, flat_n) + meta_blocks) *
                                         (CETRAFS_BLOCK_SIZE / 512));
    }

    if (!keep_size && end > i_size_read(inode)) {
        cetrafs_zero_post_eof(inode, i_size_read(inode), end); /* invalidate_lock: the caller's */
        raw.size = cetrafs_cpu_to_le64((u64) end);
    }

    /*
     * From the publish until the frees below, the old tree's leaves and
     * interiors are named by nothing and not yet free -- a leak to any
     * scrub that looks, ours or the owning peer's, and a peer's are freed
     * one queue CAS each, long enough for its scrub to free them first
     * and its drain to free them again over a live block (audit
     * 2026-11-15 B-31). Announced before the publish, as truncate and
     * punch do.
     */
    if (built && !READ_ONCE(cetrafs_falloc_frees_unannounced)) {
        foreign = !cetrafs_tree_meta_is_ours(inode, &old_raw);
        ret = cetrafs_frees_begin(sb, &foreign);
        if (ret) {
            cetrafs_tree_free_meta_except(inode, &raw, &old_raw);
            goto out_free_added;
        }
        announced = true;
    }
    ret = cetrafs_rebuild_recheck(inode, "fallocate");
    if (!ret) {
        u64 fd_seq;

        cetrafs_inode_fd_pub_lock(inode);
        fd_seq = cetrafs_inode_fd_seq(inode);
        ret = cetrafs_write_raw_inode_fd_planned(sb, inode->i_ino, &raw, inode, plan_seq);
        if (!ret)
            cetrafs_inode_fd_published(inode, fd_seq); /* this publish supersedes the overlaid shadow */
        cetrafs_inode_fd_pub_unlock(inode);
    }
    if (ret) {
        if (announced)
            cetrafs_frees_end(sb, foreign);
        if (built)
            cetrafs_tree_free_meta_except(inode, &raw, &old_raw);
        goto out_free_added;
    }

    /* Published: the old tree's meta goes back -- unless a peer arrived
     * after the last check, as in truncate and punch, when what it may
     * still name is left for the scrub. */
    if (built) {
        if (cetrafs_falloc_free_stall_ms)
            msleep(cetrafs_falloc_free_stall_ms); /* TEST ONLY: see the parameter */
        if (cetrafs_rebuild_peer_present(inode))
            pr_warn("fallocate: ino=%llu was opened on another node during the publish -- leaving the old "
                    "map's blocks allocated for the scrub\n",
                    (unsigned long long) inode->i_ino);
        else
            cetrafs_tree_free_meta_except(inode, &old_raw, &raw);
    }
    if (announced)
        cetrafs_frees_end(sb, foreign);

    inode->i_blocks = cetrafs_le64(raw.blocks);
    if (!keep_size && end > i_size_read(inode))
        i_size_write(inode, end);
    inode_set_ctime(inode, ktime_get_real_seconds(), 0);
    inode_set_mtime_to_ts(inode, inode_get_ctime(inode));
    mark_inode_dirty(inode);
    ret = loop_ret; /* a stop part-way (signal, ENOSPC) still reports why */
    goto out_free;

out_free_added:
    /* Never published, so nothing names them: give every block this
     * call allocated back. */
    {
        u32 i;

        for (i = 0; i < add_n; i++) {
            u64 p = cetrafs_extent_phys_from_hilo(add[i].ee_start_hi, add[i].ee_start_lo);
            u32 l = cetrafs_extent_len(add[i].ee_len), k;

            for (k = 0; k < l; k++)
                cetrafs_free_data_block(sb, p + k);
        }
    }
out_free:
    /* Published (the record names them) or given back (above): either
     * way the registry has nothing left to hold for the scrub. */
    cetrafs_falloc_resv_drop(sb, &resv);
    cetrafs_falloc_map_free(&map);
    kvfree(flat);
    kvfree(add);
    kfree(recs);
    return ret;
#undef raw
#undef old_raw
}

/*
 * fallocate changes the file the way a write does, so it drops the
 * setuid/setgid bits and moves mtime/ctime the way a write does:
 * file_modified(), as ext4 and XFS call it. It was called nowhere in
 * the module, so a group-writable setuid file kept its bit after its
 * contents were punched (audit 2026-11-05, class 23;
 * tests/kernel/fallocate_strips_suid.sh). Under inode_lock, which
 * file_remove_privs() requires, and BEFORE invalidate_lock: removing the
 * bits is a notify_change() into cetrafs_setattr().
 */
static int cetrafs_fallocate_modified(struct file *file)
{
    return file_modified(file);
}

/*
 * ZERO_RANGE in place: the written blocks of the range are zeroed where
 * they are, by the device (REQ_OP_WRITE_ZEROES), and the extent map is
 * not touched.
 *
 * The alternative, a punch then a preallocation, frees every whole block
 * and allocates a new one somewhere else. On an FC array a qemu-style
 * stream of 1 MiB write-zeroes over a written image ran at 40 ops/s that
 * way and took the image from 9 extents to 6264; zeroed in place the
 * same stream is ~800 ops/s and the layout does not move
 * (docs/internal/ZERO-RANGE-BENCHMARK.md).
 *
 * Preallocated (uninit) extents already read as zeros and are skipped;
 * holes are left to the preallocation the caller runs next; the partial
 * blocks at the edges are zeroed through the page cache, as punch does.
 *
 * Writing into blocks the file owns is what write(2) does, so this takes
 * what a write takes and what punch takes on top: inode_lock (write(2),
 * truncate, punch, defrag's steps), the direct-I/O drain, invalidate_lock
 * EXCLUSIVELY (faults and readahead cannot bring a block of the range
 * back into the cache while the device rewrites it), the write gate, and
 * punch's refusal of a file a peer has open. Before the device writes,
 * the range's cached pages are dropped and its pending conversions
 * cancelled (below): a dirty page written back after the zeroing, or a
 * conversion published after it, would put the old contents back.
 *
 * Returns -EOPNOTSUPP, having changed at most part of the range, when the
 * device cannot zero in place; the caller then runs the punch, which is
 * correct over a range in any state. *out_mapped says whether every
 * whole block of the range was found mapped, so the caller may skip the
 * preallocation.
 */
static atomic64_t cetrafs_zero_inplace_blocks = ATOMIC64_INIT(0);

u64 cetrafs_zero_inplace_block_count(void)
{
    return (u64) atomic64_read(&cetrafs_zero_inplace_blocks);
}

/* TEST ONLY: ZERO_RANGE takes the punch + preallocation path, as on a
 * device without WRITE ZEROES (tests/kernel/zero_range_inplace.sh). */
static bool cetrafs_zero_inplace_off;
cetrafs_test_param(zero_inplace_off, cetrafs_zero_inplace_off, bool, 0644);
MODULE_PARM_DESC(zero_inplace_off, "TEST ONLY: ZERO_RANGE punches and preallocates instead of zeroing in place");

static long cetrafs_zero_range_inplace(struct file *file, loff_t offset, loff_t len, bool *out_mapped)
{
    struct inode *inode = file_inode(file);
    struct super_block *sb = inode->i_sb;
    struct block_device *bdev = sb->s_bdev;
    struct cetrafs_inode_extents ex;
    cetrafs_inode_t *raw = NULL;
    u64 start_block, end_block, mapped = 0, zeroed = 0;
    loff_t isize, end, head_end, tail_start;
    bool unmap;
    u32 i, my_node_id;
    int ret;

    *out_mapped = false;
    if (READ_ONCE(cetrafs_zero_inplace_off) || !bdev_write_zeroes_sectors(bdev))
        return -EOPNOTSUPP;
    raw = kmalloc(sizeof(*raw), GFP_NOFS);
    if (!raw)
        return -ENOMEM;

    inode_lock(inode);
    ret = cetrafs_fallocate_modified(file);
    if (ret) {
        inode_unlock(inode);
        kfree(raw);
        return ret;
    }
    inode_dio_wait(inode); /* before invalidate_lock: a DIO completion takes it */
    filemap_invalidate_lock(inode->i_mapping);
    cetrafs_lock_expire_verdicts(inode);
    ret = cetrafs_sb_is_fenced(sb) ? -EIO : cetrafs_lock_write_gate(inode);
    if (ret)
        goto out;
    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret)
        goto out;
    {
        bool blocked = false, reader = false;

        ret = cetrafs_lock_foreign_user_settled(inode, my_node_id, &blocked, &reader, NULL, NULL);
        if (ret)
            goto out;
        if (blocked || reader) {
            pr_warn_ratelimited("zero range: ino=%llu is open on another node -- refusing to zero it\n",
                                (unsigned long long) inode->i_ino);
            ret = -ETXTBSY; /* the caller makes it EOPNOTSUPP, as a punch's (A-12) */
            goto out;
        }
    }

    isize = i_size_read(inode);
    end = offset + len;
    if (end > isize)
        end = isize; /* past EOF there is no data: the preallocation's part */
    if (end <= offset) {
        ret = 0;
        goto out;
    }
    start_block = CETRAFS_DIV_ROUND_UP((u64) offset, CETRAFS_BLOCK_SIZE);
    end_block = (u64) end / CETRAFS_BLOCK_SIZE;

    if (start_block < end_block) {
        /* Unmaps and drops the folios of the whole blocks, dirty ones
         * included -- their data is about to be zeros, so writing it back
         * first would only be undone -- and waits out any writeback
         * already in flight on them, which would otherwise land after
         * the zeroing. A store through a mapping now faults, and the
         * fault waits on invalidate_lock. */
        truncate_pagecache_range(inode, (loff_t) start_block * CETRAFS_BLOCK_SIZE,
                                 (loff_t) end_block * CETRAFS_BLOCK_SIZE - 1);
        /* And, as punch does, the blocks leave the pending set: a buffered
         * write into preallocated space whose conversion is still pending
         * would otherwise be flipped to written at the next close or
         * fsync, over the zeros -- publishing what was on the device. Left
         * uninit, they read as zeros, which is the point. */
        if (start_block <= U32_MAX)
            cetrafs_pending_clear(inode, (u32) start_block, (u32) min_t(u64, end_block - 1, U32_MAX));

        ret = cetrafs_read_raw_inode_overlaid(sb, inode, raw);
        if (ret)
            goto out;
        ret = cetrafs_inode_extents_get(inode, raw, &ex);
        if (ret)
            goto out;
        unmap = cetrafs_sb_discard_enabled(sb);
        for (i = 0; i < ex.entries && !ret; i++) {
            const cetrafs_extent_t *e = &ex.arr[i];
            u64 eb = cetrafs_le32(e->ee_block);
            u64 elen = cetrafs_extent_len(e->ee_len);
            u64 lo = max_t(u64, eb, start_block), hi = min_t(u64, eb + elen, end_block);
            u64 plba;

            if (lo >= hi)
                continue;
            mapped += hi - lo;
            if (cetrafs_extent_is_uninit(e->ee_len))
                continue; /* reads as zeros already */
            plba = cetrafs_extent_phys_from_hilo(e->ee_start_hi, e->ee_start_lo) + (lo - eb);
            /* An address read off the disk, about to aim a write (rule
             * 19): the same check every mapping gets. */
            ret = cetrafs_lba_run_check(sb, plba, hi - lo);
            if (ret) {
                if (ret == -EAGAIN) {
                    ret = -EIO;
                } else {
                    pr_err_ratelimited("ino=%llu: extent [block %llu +%llu] at lba %llu is not a data address -- "
                                       "refusing to zero it (fsck)\n",
                                       (unsigned long long) inode->i_ino, eb, elen, (unsigned long long) plba);
                    cetrafs_sb_corrupt_inode(inode);
                    ret = -EUCLEAN;
                }
                break;
            }
            ret = cetrafs_zeroout_issue(sb, plba, hi - lo, unmap);
            if (!ret)
                zeroed += hi - lo;
            cond_resched();
        }
        cetrafs_inode_extents_put(&ex);
        atomic64_add(zeroed, &cetrafs_zero_inplace_blocks);
        if (ret)
            goto out;
    }

    /*
     * The edges: a block only partly inside [offset, end) keeps the rest
     * of its data, so only its in-range part is zeroed, through the
     * write path -- one piece per block, never crossing a block boundary
     * (the punch's straddle bug, rule 11). head is [offset, the first
     * boundary or end); tail is [the last boundary, end), when that is
     * not inside head.
     */
    head_end = min_t(loff_t, end, (loff_t) start_block * CETRAFS_BLOCK_SIZE);
    tail_start = max_t(loff_t, offset, (loff_t) (end & ~(loff_t) (CETRAFS_BLOCK_SIZE - 1)));
    if (offset < head_end)
        ret = cetrafs_zero_range(inode->i_mapping, offset, (size_t) (head_end - offset));
    if (!ret && tail_start < end && tail_start >= head_end)
        ret = cetrafs_zero_range(inode->i_mapping, tail_start, (size_t) (end - tail_start));
    if (!ret) {
        inode_set_mtime_to_ts(inode, inode_set_ctime_current(inode));
        mark_inode_dirty(inode);
        *out_mapped = (u64) offset + (u64) len <= (u64) isize && mapped == end_block - min(start_block, end_block);
    }
out:
    filemap_invalidate_unlock(inode->i_mapping);
    inode_unlock(inode);
    kfree(raw);
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
    bool zeroed = false;    /* a boundary block was partly zeroed: the contents changed */
    bool foreign;           /* a punched block outside our own groups (cetrafs_frees_begin()) */
    int ret;

    /* The capacity check vfs_fallocate() makes at s_maxbytes, against
     * the volume's capacity instead (cetrafs_write_capacity()). */
    if (offset + len > cetrafs_sb_max_file_size(sb)) {
        loff_t cap;

        ret = cetrafs_sb_capacity_for(sb, offset + len, &cap);
        if (ret)
            return ret;
        if (offset + len > cap)
            return -EFBIG;
    }

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

    /*
     * ZERO_RANGE: zeroed in place where the device can
     * (cetrafs_zero_range_inplace()), then a preallocation of the range
     * for its holes and i_size -- skipped when every block was mapped and
     * nothing lies past EOF. Where the device cannot zero in place: a
     * punch, then the preallocation, as follows.
     *
     * The punch frees every whole block and zeroes the partial ones at the
     * edges; the preallocation fills the holes it left with uninit
     * extents, which read as zeroes, and moves i_size unless KEEP_SIZE.
     * Each step is the vetted path with its own locks, foreign-open
     * refusal and file_modified(). Between the two, and after a crash
     * there, the range is holes -- already zero -- so the only thing
     * ever visible is zeroes. A write landing between the steps keeps its
     * block (the preallocation skips mapped blocks): a write after the
     * zeroing, which is an order the caller could have had anyway. An
     * ENOSPC from the second step leaves the range zeroed, not allocated.
     * qemu's write-zeroes uses this; without it qemu wrote the zeroes.
     */
    if (mode == FALLOC_FL_ZERO_RANGE || mode == (FALLOC_FL_ZERO_RANGE | FALLOC_FL_KEEP_SIZE)) {
        bool mapped = false;
        long zrc;

        kfree(recs);
        zrc = cetrafs_zero_range_inplace(file, offset, len, &mapped);
        if (zrc == -EOPNOTSUPP)
            zrc = cetrafs_fallocate(file, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, offset, len);
        else if (!zrc && mapped)
            return 0;
        if (!zrc)
            zrc = cetrafs_fallocate(file, mode & FALLOC_FL_KEEP_SIZE, offset, len);
        /* A peer has the file open (any of the steps): EOPNOTSUPP, so
         * qemu writes the zeroes itself rather than failing the guest's
         * request -- see the punch's refusal (audit 2026-11-14 A-12). */
        if (zrc == -ETXTBSY)
            zrc = -EOPNOTSUPP;
        return zrc;
    }

    /* ALLOCATE: mode 0, or KEEP_SIZE alone. */
    if (mode == 0 || mode == FALLOC_FL_KEEP_SIZE) {
        long arc;

        inode_lock(inode);
        /* Strip setuid/setgid and move the times, as every write does --
         * see cetrafs_fallocate_modified(). */
        arc = cetrafs_fallocate_modified(file);
        if (arc) {
            inode_unlock(inode);
            kfree(recs);
            return arc;
        }
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
         * Same refusal, same reason, and punch's errno: EOPNOTSUPP, which
         * qemu's write-zeroes fallback past EOF and glibc's
         * posix_fallocate() read as "not here" and write the zeros
         * themselves; ETXTBSY was a guest I/O error for the whole
         * pre-copy of a migration (audit 2026-11-15 B-11,
         * tests/kernel/fallocate_foreign_open.sh).
         */
        if (!arc) {
            u32 my_node_id;
            bool blocked = false, reader = false;

            arc = cetrafs_sb_get_node_id(sb, &my_node_id);
            if (!arc)
                arc = cetrafs_lock_foreign_user_settled(inode, my_node_id, &blocked, &reader, NULL, NULL);
            if (!arc && (blocked || reader)) {
                pr_warn_ratelimited("fallocate: ino=%llu is open on another node -- refusing to rewrite its map\n",
                                    (unsigned long long) inode->i_ino);
                arc = READ_ONCE(cetrafs_falloc_foreign_etxtbsy) ? -ETXTBSY : -EOPNOTSUPP;
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
    ret = cetrafs_fallocate_modified(file);
    if (ret) {
        inode_unlock(inode);
        kfree(recs);
        return ret;
    }
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

    /* The leaves the punch walks decide what is freed: not through a
     * verdict cached a second ago (cetrafs_lock_expire_verdicts()). */
    cetrafs_lock_expire_verdicts(inode);
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

            ret = cetrafs_lock_foreign_user_settled(inode, my_node_id, &blocked, &reader, NULL, NULL);
            if (ret)
                goto out;
            if (blocked || reader) {
                pr_warn_ratelimited("punch: ino=%llu is open on another node -- refusing to free its blocks\n",
                                    (unsigned long long) inode->i_ino);
                /*
                 * EOPNOTSUPP, not ETXTBSY. A punch is how a guest's
                 * discard and write-zeroes reach the image, and during a
                 * live migration under nofilelock the destination holds
                 * it open for the whole precopy. qemu turns any other
                 * errno into a guest I/O error; this one it reads as
                 * "not here": a discard is skipped (advisory anyway) and
                 * write-zeroes falls back to writing zeros -- correct
                 * data, nothing freed under the peer (audit 2026-11-14
                 * A-12).
                 */
                ret = -EOPNOTSUPP;
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
        if (!ret) { /* the contents changed: mtime with ctime (audit L24) */
            inode_set_mtime_to_ts(inode, inode_set_ctime_current(inode));
            mark_inode_dirty(inode);
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

    /* Copy what the hole touches, or build a fresh tree; the old one
     * stays intact until we publish. */
    ret = cetrafs_tree_patch(inode, &raw, start_block, end_block, NULL, 0, new_n,
                             cetrafs_flat_data_blocks(new_flat, new_n), &meta_blocks);
    if (ret == -EAGAIN)
        ret = cetrafs_tree_build(inode, new_flat, new_n, &raw, &meta_blocks);
    if (ret) {
        kvfree(new_flat);
        kvfree(old_flat);
        goto out;
    }

    raw.blocks =
        cetrafs_cpu_to_le64((cetrafs_flat_data_blocks(new_flat, new_n) + meta_blocks) * (CETRAFS_BLOCK_SIZE / 512));

    /* As truncate: announced before the publish, ended after the frees. */
    foreign = !(cetrafs_flat_range_is_ours(sb, old_flat, old_n, start_block, end_block) &&
                cetrafs_tree_meta_is_ours(inode, &old_raw));
    ret = cetrafs_frees_begin(sb, &foreign);
    if (ret) {
        cetrafs_tree_free_meta_except(inode, &raw, &old_raw);
        kvfree(new_flat);
        kvfree(old_flat);
        goto out;
    }
    ret = cetrafs_rebuild_recheck(inode, "punch");
    if (ret == -ETXTBSY)
        ret = -EOPNOTSUPP; /* a peer opened it meanwhile: as the check above (A-12) */
    if (!ret) {
        u64 fd_seq;

        cetrafs_inode_fd_pub_lock(inode);
        fd_seq = cetrafs_inode_fd_seq(inode);
        ret = unlikely(cetrafs_fail_extent_record_write) ? -EIO
                                                         : cetrafs_write_raw_inode_fd_planned(sb, inode->i_ino, &raw, inode,
                                                                                              cetrafs_le64(old_raw.file_seq));
        if (!ret)
            cetrafs_inode_fd_published(inode, fd_seq); /* this publish supersedes the overlaid shadow */
        cetrafs_inode_fd_pub_unlock(inode);
    }
    if (ret) {
        cetrafs_frees_end(sb, foreign);
        cetrafs_tree_free_meta_except(inode, &raw, &old_raw);
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
    /* As truncate: the punched blocks leave the pending set. */
    if (start_block <= U32_MAX)
        cetrafs_pending_clear(inode, (u32) start_block, (u32) min_t(u64, end_block - 1, U32_MAX));

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

        cetrafs_tree_free_meta_except(inode, &old_raw, &raw);
        fret = cetrafs_leaf_array_punch(sb, old_flat, &discard_entries, old_n + 2, start_block, end_block, &discard,
                                            /*do_free=*/true);
        if (fret)
            pr_err("punch: freeing the old blocks failed (%d) -- %u block(s) may have leaked\n", fret, freed);
    }
    cetrafs_frees_end(sb, foreign);
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
        zeroed = true;
    }
    if (!ret && (end & (CETRAFS_BLOCK_SIZE - 1))) {
        loff_t block_start = (loff_t) end_block * CETRAFS_BLOCK_SIZE;

        ret = cetrafs_zero_range(inode->i_mapping, block_start, (size_t) (end - block_start));
        zeroed = true;
    }
    /* A punch changes the file's contents: mtime moves with ctime, as
     * on ext4 and XFS (audit L24) -- a backup or sync tool that trusts
     * mtime otherwise never sees the hole. */
    if (!published) {
        if (zeroed) {
            inode_set_mtime_to_ts(inode, inode_set_ctime_current(inode));
            mark_inode_dirty(inode);
        }
        goto out; /* the map did not change: nothing below applies */
    }

    inode->i_blocks = cetrafs_le64(raw.blocks);
    inode_set_ctime(inode, ktime_get_real_seconds(), 0);
    inode_set_mtime_to_ts(inode, inode_get_ctime(inode));
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
    unsigned int ia_valid; /* which of mode/uid/gid this setattr changes */
    u32 kill;              /* S_ISUID/S_ISGID a privilege kill drops, else 0 */
    /* Regular files: what the foreign-user check judged, and whether the
     * swap found someone it did not (then nothing is applied). */
    bool guard;
    u32 my_node_id;
    u32 judged_owner;
    u64 judged_readers;
    bool refused;
    __le32 mode;
    __le32 uid;
    __le32 gid;
    __le64 ctime;
};

static void cetrafs_ns_apply_setattr(cetrafs_inode_t *rec, void *arg)
{
    struct cetrafs_setattr_ns *u = arg;

    /*
     * The foreign-user check ran before this swap, and a peer can open
     * the file in between: its lock or presence lands, it reads the
     * record for its cached mode, and this chmod lands after -- the peer
     * then writes with a mode that has lost the setuid bit set here, and
     * the kill its write owes never happens (or, the other way, keeps a
     * bit this call dropped). Both live in this sector, so they are
     * re-asked inside the swap: a lock or presence the check did not
     * judge refuses the whole setattr. Per attempt -- a retry re-reads.
     */
    u->refused = false;
    if (u->guard) {
        u64 mine = 1ULL << (u->my_node_id % CETRAFS_MAX_READER_NODES);
        u32 owner = cetrafs_le32(rec->lock_owner_node);

        if (cetrafs_lock_mode_held(cetrafs_le32(rec->lock_mode)) && owner != u->my_node_id &&
            owner != u->judged_owner)
            u->refused = true;
        if (cetrafs_le64(rec->read_open_nodes) & ~mine & ~u->judged_readers)
            u->refused = true;
        if (u->refused)
            return; /* nothing of ours: the image goes back as it is */
    }

    /*
     * Only what THIS setattr changes. The values come from the in-core
     * inode, which nothing refreshes once the namespace lock is held
     * (an fd-based futimens/ftruncate never even looks the file up):
     * writing all three back reverted a peer's chmod/chown committed
     * since this node last read the record. The rest stays as the
     * fresh image has it. ctime moves on every setattr.
     * tests/kernel/setattr_keeps_peer_mode.sh.
     *
     * A privilege kill is a change TO the mode, not a mode: a write,
     * fallocate or chown by an unprivileged caller asks to drop
     * setuid/setgid, and notify_change() turns that into ATTR_MODE with
     * the CACHED mode minus the bits. Written whole, it put back every
     * other bit a peer's chmod had changed -- a chmod o-rwx undone by
     * the next write. Only the dropped bits are cleared in the fresh
     * record.
     */
    if (u->kill)
        rec->mode = cetrafs_cpu_to_le32(cetrafs_le32(rec->mode) & ~u->kill);
    else if (u->ia_valid & ATTR_MODE)
        rec->mode = u->mode;
    if (u->ia_valid & ATTR_UID)
        rec->uid = u->uid;
    if (u->ia_valid & ATTR_GID)
        rec->gid = u->gid;
    rec->ctime = u->ctime;
}

/* TEST ONLY: pause a regular file's setattr between its foreign-user
 * check and its swap, where a peer's open can land
 * (tests/kernel/setattr_kill_fresh_mode.sh). */
static unsigned int cetrafs_setattr_guard_stall_ms;
cetrafs_test_param(setattr_guard_stall_ms, cetrafs_setattr_guard_stall_ms, uint, 0644);
MODULE_PARM_DESC(setattr_guard_stall_ms, "TEST ONLY: pause a setattr between its foreign-user check and its swap");

/* TEST ONLY: refuse setattr's next namespace publish, as a CAS the
 * device refused would (tests/kernel/setattr_rollback.sh). */
static bool cetrafs_setattr_ns_fail_once;
cetrafs_test_param(setattr_ns_fail_once, cetrafs_setattr_ns_fail_once, bool, 0644);
MODULE_PARM_DESC(setattr_ns_fail_once, "TEST ONLY: fail setattr's next namespace-sector publish with -EIO");

static int cetrafs_setattr_locked(struct mnt_idmap *idmap, struct dentry *dentry, struct iattr *attr)
{
    struct {
        umode_t mode;
        kuid_t uid;
        kgid_t gid;
        struct timespec64 atime, mtime, ctime;
    } saved;
    struct inode *inode = d_inode(dentry);
    u32 judged_owner = CETRAFS_NODE_ID_NONE, guard_node = 0;
    u64 judged_readers = 0;
    bool guard = false;
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

            ret = cetrafs_lock_foreign_user_settled(inode, my_node_id, &blocked, &reader, NULL, NULL);
            if (ret)
                return ret;
            /* A resize to the size the file has frees and reshapes
             * nothing: done, not refused -- qemu's resize to the current
             * length under a migration's open destination was an error
             * to the guest (B-11). Its time update is what is skipped. */
            if ((blocked || reader) && attr->ia_size == i_size_read(inode) &&
                !READ_ONCE(cetrafs_falloc_foreign_etxtbsy))
                return 0;
            if (blocked || reader)
                return -ETXTBSY;
        } else {
            /* Same reasoning as the size branch above: a peer that has
             * SUSPENDED this file's automatic lock (lock.c, the handoff
             * window) is still writing it and is published only as
             * presence, so the lock alone no longer answers "is a live
             * writer here?". chmod/chown rewrite the record. What it
             * judged is re-asked inside the swap below
             * (cetrafs_ns_apply_setattr()). Not for a size change: its
             * shrink has published before that swap, and refusing there
             * would report a truncate that happened as failed. */
            bool reader = false;

            ret = cetrafs_lock_foreign_user_settled(inode, my_node_id, &blocked, &reader, &judged_owner,
                                                    &judged_readers);
            if (ret)
                return ret;
            if (blocked || reader)
                return -ETXTBSY;
            guard = true;
        }
        guard_node = my_node_id;
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
            else {
                cetrafs_zero_post_eof(inode, i_size_read(inode), attr->ia_size);
                truncate_setsize(inode, attr->ia_size);
            }
        }
        filemap_invalidate_unlock(inode->i_mapping);

        if (ret)
            return ret;
    }

    /* What setattr_copy() is about to change in-core, kept so a refused
     * publish can put it back: left in place, a chmod that FAILED stays
     * in the inode, and the next setattr of anything else publishes it
     * (audit L36). */
    {
        saved.mode = inode->i_mode;
        saved.uid = inode->i_uid;
        saved.gid = inode->i_gid;
        saved.atime = inode_get_atime(inode);
        saved.mtime = inode_get_mtime(inode);
        saved.ctime = inode_get_ctime(inode);
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
            .ia_valid = attr->ia_valid,
            /* ATTR_KILL_* survive notify_change()'s conversion, so they
             * tell a kill from a chmod; what it dropped is the
             * difference setattr_copy() just made. */
            .kill = (attr->ia_valid & (ATTR_KILL_SUID | ATTR_KILL_SGID)) && (attr->ia_valid & ATTR_MODE)
                        ? (u32) (saved.mode & ~inode->i_mode & (S_ISUID | S_ISGID))
                        : 0,
            .guard = guard,
            .my_node_id = guard_node,
            .judged_owner = judged_owner,
            .judged_readers = judged_readers,
            .mode = cetrafs_cpu_to_le32(inode->i_mode),
            .uid = cetrafs_cpu_to_le32(i_uid_read(inode)),
            .gid = cetrafs_cpu_to_le32(i_gid_read(inode)),
            .ctime = cetrafs_cpu_to_le64((u64) inode_get_ctime_sec(inode)),
        };
        cetrafs_inode_t nsraw;

        cetrafs_invalidate_raw_inode(inode->i_sb, inode->i_ino);
        ret = cetrafs_read_raw_inode(inode->i_sb, inode->i_ino, &nsraw);
        if (!ret && READ_ONCE(cetrafs_setattr_ns_fail_once) && xchg(&cetrafs_setattr_ns_fail_once, false))
            ret = -EIO; /* test-only; see the parameter */
        if (!ret && cetrafs_setattr_guard_stall_ms && guard) {
            msleep(cetrafs_setattr_guard_stall_ms); /* test-only; see the parameter */
            cetrafs_invalidate_raw_inode(inode->i_sb, inode->i_ino);
            ret = cetrafs_read_raw_inode(inode->i_sb, inode->i_ino, &nsraw);
        }
        if (!ret)
            ret = cetrafs_inode_ns_cas(inode->i_sb, inode->i_ino, cetrafs_le64(nsraw.generation), &nsraw,
                                       cetrafs_ns_apply_setattr, &u);
        if (!ret && u.refused)
            ret = -ETXTBSY; /* a peer opened it since the check */
        if (ret) {
            inode->i_mode = saved.mode;
            inode->i_uid = saved.uid;
            inode->i_gid = saved.gid;
            inode_set_atime_to_ts(inode, saved.atime);
            inode_set_mtime_to_ts(inode, saved.mtime);
            inode_set_ctime_to_ts(inode, saved.ctime);
            return ret;
        }
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
    int ret;

    /* The capacity check inode_newsize_ok() makes at s_maxbytes, against
     * the volume's capacity instead (cetrafs_write_capacity()). */
    if ((attr->ia_valid & ATTR_SIZE) && S_ISREG(set[0]->i_mode) &&
        attr->ia_size > cetrafs_sb_max_file_size(set[0]->i_sb)) {
        loff_t cap;

        ret = cetrafs_sb_capacity_for(set[0]->i_sb, attr->ia_size, &cap);
        if (ret)
            return ret;
        if (attr->ia_size > cap)
            return -EFBIG;
    }

    /* Two callers wait in the lock instead of restarting (nslock.c):
     * file_remove_privs() from a write, whose AIO and io_uring
     * completions turn a restart into EINTR; and an open's O_TRUNC
     * (ATTR_OPEN), which runs AFTER the open may have created the file --
     * restarted, open(O_CREAT|O_EXCL|O_TRUNC) would then fail EEXIST on
     * its own file. It holds no parent lock, so waiting costs no one. */
    ret = (attr->ia_valid & (ATTR_KILL_SUID | ATTR_KILL_SGID | ATTR_KILL_PRIV | ATTR_OPEN))
              ? cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set))
              : cetrafs_nslock_acquire_set_vfs(set, ARRAY_SIZE(set));
    if (ret)
        return ret;

    ret = cetrafs_setattr_locked(idmap, dentry, attr);
    cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
    return ret;
}

/* generic_file_open() first (standard large-file/maxbytes check), then
 * the cross-node exclusive lock gate (lock.c, an earlier phase). */
/*
 * The tree blocks of a regular file wait in core for the boundary
 * (leafdefer.c) and are written here, through the journal, in one batch.
 * 'mapping_locked': the caller already holds invalidate_lock. 'raw' is
 * no longer walked -- the deferred-block registry knows which blocks are
 * this inode's -- and stays in the signature for the callers that
 * already read it.
 */
int cetrafs_flush_tree_blocks(struct inode *inode, const cetrafs_inode_t *raw, bool mapping_locked)
{
    (void) raw;
    return cetrafs_deferred_flush_inode(inode, mapping_locked);
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
/*
 * Everything of fsync past the data writeback of its range: the pending
 * buffered blocks, then the allocation bits, the tree blocks, the record
 * and the device cache. `locked`: the caller already holds inode_lock and
 * invalidate_lock (exclusively) -- the lock suspension does.
 */
/* TEST ONLY: fsync_meta's final cache flush is skipped -- the negative
 * control of tests/crash/fsync_volatile.sh. Only that flush, not the
 * ones inside the metadata publishes, so the rig must show what the
 * final flush alone was covering. */
static bool cetrafs_fsync_flush_skip;
cetrafs_test_param(fsync_flush_skip, cetrafs_fsync_flush_skip, bool, 0644);
MODULE_PARM_DESC(fsync_flush_skip, "TEST ONLY: fsync does not issue its final device cache flush");

/* TEST ONLY: a datasync fsync publishes the record as a full fsync does,
 * times included -- the control of tests/kernel/fdatasync_overwrite.sh. */
static bool cetrafs_datasync_full;
cetrafs_test_param(datasync_full, cetrafs_datasync_full, bool, 0644);
MODULE_PARM_DESC(datasync_full, "TEST ONLY: fdatasync publishes the record's timestamps too");

/*
 * The metadata sync of an fdatasync. It is the VFS path, so the inode's
 * dirty state is cleared afterwards (cetrafs_apply_raw_to_vfs_inode()
 * refuses to refresh a dirty inode, the trap the comment in
 * cetrafs_fsync_meta() describes). What differs is the scope: while it
 * runs, a cetrafs_dsync_scope names this task and this inode, and
 * cetrafs_write_vfs_inode() then leaves time-only dirt unpublished (see
 * inode.c). The scope is task-local: a writeback or another task's sync
 * of the same inode never sees it, so their times are still published.
 *
 * WHY THE SKIP IS SAFE. The record publish is skipped only when there is
 * no shadow and size and blocks are unchanged, so it can only drop a
 * change that touches neither. Every change to a regular file's extent
 * state reaches the device one of two ways, and neither depends on this
 * sync:
 *   - staged in the shadow (cetrafs_inode_fd_stage(), file.c get_block:
 *     a new block; the uninit-to-written conversion of a preallocated
 *     block, whether from write(2) via convert_pending, an O_DIRECT
 *     completion, or the buffered path). A staged shadow sets fd_dirty,
 *     so have_shadow is true and the record is published with it. The
 *     conversion keeps blocks unchanged, which is why the blocks check
 *     alone would NOT catch it: the shadow is what carries it.
 *   - published synchronously by the operation that made it (truncate,
 *     punch, fallocate, defrag, the namespace paths, via the _fd
 *     publishers, under fd_pub_mutex). It is on the device before that
 *     operation returns, so it is not left for this sync to publish.
 * The one thing that can still change in core without either is the
 * times, and those are what the scope drops. A datasync that finds
 * nothing staged therefore has nothing to make durable beyond the data
 * and the leaves, which fsync_meta flushes before this call. The
 * dropped times are not lost: the scope re-dirties the inode after the
 * VFS clears it, so writeback or the next full sync publishes them, and
 * a clean unmount still does. tests/kernel/fdatasync_overwrite.sh counts
 * the publishes, and tests/crash/fsync_volatile.sh checks the cuts.
 */
static int cetrafs_sync_inode_meta(struct inode *inode, bool datasync)
{
    struct cetrafs_dsync_scope scope = {.inode = inode};
    int ret;

    if (!datasync || READ_ONCE(cetrafs_datasync_full))
        return sync_inode_metadata(inode, 1);
    cetrafs_dsync_enter(&scope);
    ret = sync_inode_metadata(inode, 1);
    cetrafs_dsync_exit(&scope);
    if (scope.times_dropped)
        mark_inode_dirty_sync(inode);
    return ret;
}

static int cetrafs_fsync_meta(struct inode *inode, int ret, bool locked, bool datasync)
{
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    int ret2;

    /* Before the bitmaps: converting can split a leaf, which allocates. */
    ret2 = locked ? cetrafs_convert_pending_locked(inode) : cetrafs_convert_pending(inode);
    if (ret2 && !ret)
        ret = ret2;

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
        ret2 = cetrafs_flush_tree_blocks(inode, &raw, locked);
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
    ret2 = cetrafs_sync_inode_meta(inode, datasync);
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
    ret2 = READ_ONCE(cetrafs_fsync_flush_skip) ? 0 : blkdev_issue_flush(sb->s_bdev);
    if (ret2 && !ret)
        ret = ret2;

    return ret;
}

static int __cetrafs_fsync(struct file *file, loff_t start, loff_t end, bool locked, bool datasync)
{
    int ret = file_write_and_wait_range(file, start, end);

    if (ret)
        return ret;
    return cetrafs_fsync_meta(file_inode(file), 0, locked, datasync);
}

static int cetrafs_fsync(struct file *file, loff_t start, loff_t end, int datasync)
{
    /* The extents are needed to FIND the data either way: a datasync
     * still publishes every structural change; it skips only time-only
     * dirt (cetrafs_sync_inode_meta()). */
    return __cetrafs_fsync(file, start, end, false, datasync);
}

/* sync(2)/syncfs(2): what fsync would do, for an inode with buffered
 * blocks still to mark written (super_ops.c's cetrafs_sync_fs()). Its
 * data was written back before ->sync_fs(wait) runs. */
int cetrafs_inode_sync_pending(struct inode *inode)
{
    if (!cetrafs_pending_any(inode))
        return 0;
    return cetrafs_fsync_meta(inode, 0, false, false);
}

/*
 * Everything the last-writer close makes durable, for a file that is
 * STAYING open. lock.c's suspension path calls it before handing this
 * file's exclusive lock to a peer: data, extent-tree blocks, allocation
 * bitmaps and the record must all be on the device before the peer can
 * open, exactly as at close.
 */
int cetrafs_file_make_durable(struct file *file, bool locked)
{
    return __cetrafs_fsync(file, 0, LLONG_MAX, locked, false);
}

/* TEST ONLY: pause a regular file's write-open before it publishes its
 * lock or presence -- after the lookup refreshed the inode, where a
 * peer's chmod can land (tests/kernel/setattr_kill_fresh_mode.sh). */
static unsigned int cetrafs_open_publish_stall_ms;
cetrafs_test_param(open_publish_stall_ms, cetrafs_open_publish_stall_ms, uint, 0644);
MODULE_PARM_DESC(open_publish_stall_ms, "TEST ONLY: pause a write-open before it publishes its lock or presence");

/*
 * A write-open adopts the record's mode, owner and group as they are
 * AFTER its lock or presence is on the device.
 *
 * The VFS decides a write's setuid/setgid kill from the in-core mode,
 * and nothing refreshes that while the file is open -- a peer's chmod
 * is refused from then on (cetrafs_setattr_locked() and the re-check in
 * its swap). What is left is the chmod that landed BEFORE the publish
 * and after the lookup's refresh: a peer's chmod +s there left this
 * node's mode without the bit, and an unprivileged write here kept it.
 * Read after the publish, under inode_lock so no local setattr is half
 * applied, the record has it.
 */
static int cetrafs_open_adopt_identity(struct inode *inode)
{
    cetrafs_inode_t *raw = kmalloc(sizeof(*raw), GFP_NOFS);
    int ret;

    if (!raw)
        return -ENOMEM;
    inode_lock(inode);
    cetrafs_invalidate_raw_inode(inode->i_sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(inode->i_sb, inode->i_ino, raw);
    if (!ret && cetrafs_le64(raw->generation) != cetrafs_inode_get_generation(inode))
        ret = -ESTALE; /* the number is another file's now */
    if (!ret && ((inode->i_mode ^ cetrafs_le32(raw->mode)) & S_IFMT) == 0)
        cetrafs_inode_adopt_identity(inode, raw);
    inode_unlock(inode);
    kfree(raw);
    return ret;
}

static int cetrafs_open(struct inode *inode, struct file *file)
{
    int ret = cetrafs_read_gate(inode->i_sb);

    if (ret)
        return ret;
    ret = generic_file_open(inode, file);

    if (ret)
        return ret;
    if (S_ISREG(inode->i_mode) && (file->f_mode & FMODE_WRITE) && READ_ONCE(cetrafs_open_publish_stall_ms))
        msleep(xchg(&cetrafs_open_publish_stall_ms, 0)); /* test-only, one-shot; see the parameter */
    ret = cetrafs_lock_open(inode, file);
    if (ret || !S_ISREG(inode->i_mode) || !(file->f_mode & FMODE_WRITE))
        return ret;
    ret = cetrafs_open_adopt_identity(inode);
    if (ret)
        cetrafs_release(inode, file); /* ->release is not called for a failed open */
    return ret;
}

static int cetrafs_release(struct inode *inode, struct file *file)
{
    /* Hand back any unused speculative run BEFORE the lock release
     * flushes free counts, so the returned blocks are included in that
     * flush instead of sitting reserved-but-unreferenced until the
     * scrub notices. */
    cetrafs_inode_drop_reservation(inode);
    if (file->f_mode & FMODE_WRITE)
        cetrafs_tree_resv_drop(inode); /* the converts' kept tree reserve (F-5) */
    /* A fragmented file's sorted map is megabytes: kept only while the
     * file is open (cetrafs_inode_sorted_runs()). */
    cetrafs_inode_smap_drop(inode);
    return cetrafs_lock_release(inode, file);
}

/* The defrag core lives in defrag.c (per-file relocation + the automatic
 * background worker); this file only owns the ioctl entry point, since
 * the fd-based trigger is file-ops territory. */
/* TEST ONLY: mark this inode damaged as the defrag ioctl starts, the
 * way a read that found damage while the fd was open would have
 * (tests/kernel/defrag_damaged_refused.sh). */
static unsigned long long cetrafs_defrag_damage_ino;
cetrafs_test_param(defrag_damage_ino, cetrafs_defrag_damage_ino, ullong, 0644);
MODULE_PARM_DESC(defrag_damage_ino, "TEST ONLY: mark this inode damaged as a defrag ioctl on it starts");

static long cetrafs_defrag_ioctl(struct file *file, struct cetrafs_defrag_stats __user *uarg)
{
    struct inode *inode = file_inode(file);
    struct cetrafs_defrag_stats stats = {0};
    long ret;

    if (!(file->f_mode & FMODE_WRITE))
        return -EBADF; /* the write-open IS the cross-node exclusivity */
    if (READ_ONCE(cetrafs_defrag_damage_ino) && cetrafs_defrag_damage_ino == inode->i_ino) {
        WRITE_ONCE(cetrafs_defrag_damage_ino, 0);
        cetrafs_sb_corrupt_inode(inode); /* TEST ONLY */
    }

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
