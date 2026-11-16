// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * ioutil.c -- the shared low-level read primitive for any on-disk
 * structure another cluster node might have just written.
 *
 * The Linux buffer cache assumes one kernel owns the device: once this
 * node has read a block and marked it uptodate, sb_bread() returns that
 * copy forever and never notices a peer overwriting the same LBA. That
 * undermines every "read the current cluster state" check here --
 * Node Registry rows, ZG descriptors, inode lock fields, dirent/xattr/
 * extent-leaf blocks, bitmap and BG state -- including the
 * write-then-verify-readback used to catch a lost race: the verify read
 * is satisfied by this node's own just-written buffer, so it can never
 * see what a peer wrote. On two-node hardware that showed up as a
 * heartbeat renewal invisible to the peer, and as both nodes winning the
 * same exclusive open-lock race.
 *
 * cetrafs_bread_uncached() is the drop-in replacement for those call
 * sites: discard what the buffer cache believes and read the device.
 * Deliberately not used everywhere -- journal replay and freshly
 * allocated, about-to-be-overwritten blocks stay on sb_bread(), since no
 * other node reads them before this one owns them, and forcing a device
 * round trip there buys nothing but mount-time latency.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/random.h>
#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/version.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/module.h>
#include <linux/pagemap.h>
/* struct folio_batch moved out of pagevec.h in 7.1; build against either.
 * A version test, not __has_include(): sparse cannot parse that. */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)
#include <linux/folio_batch.h>
#else
#include <linux/pagevec.h>
#endif

#include <linux/crc32c.h>

#include "kmod.h"

struct buffer_head *cetrafs_bread_uncached(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh = sb_getblk(sb, block);

    if (!bh)
        return NULL;

    /*
     * Only discard a *clean* cached copy before re-reading. A dirty
     * buffer holds a write that hasn't reached the device yet (e.g. this
     * node's own recent write, mid-flight before its own
     * sync_dirty_buffer()) -- forcing a read on top of it would fetch
     * whatever is still physically on the device and silently clobber
     * that pending write with stale content. Caught via a real
     * regression: a test helper's unsynced pwrite() direct to the block
     * device raced against an immediate remount, and this function's
     * first version discarded the test helper's not-yet-flushed write
     * every time, always reading back the previous content instead.
     * Dirty implies uptodate in this cache, so leaving a dirty buffer
     * alone here is always safe: bh_read() below will see it's already
     * uptodate and return immediately without touching it.
     */
    lock_buffer(bh);
    /* ...or deferred (leafdefer.c): the same pending write, kept out of
     * writeback rather than dirty. */
    if (buffer_uptodate(bh) && !cetrafs_bh_pending(bh))
        clear_buffer_uptodate(bh);
    unlock_buffer(bh);

    if (bh_read(bh, 0) < 0) {
        brelse(bh);
        return NULL;
    }

    return bh;
}

/*
 * sb_bread() with bounded retries, for any block another thread may be
 * invalidating underneath us.
 *
 * __bread_slow() re-checks buffer_uptodate AFTER its read completes and
 * returns NULL if the bit is no longer set -- so a perfectly healthy read
 * racing a cetrafs_invalidate_block() of the same block comes back NULL,
 * indistinguishable from a real device error. Callers turned that into
 * -EIO. It is reached constantly in practice: cetrafs_apply_raw_to_vfs_
 * inode() invalidates a depth-1 inode's external extent-leaf block on
 * EVERY dentry revalidate, so any directory busy enough to be looked up
 * while it is being read hits it. Confirmed: a thread creating
 * files in one directory while another ran `ls` over it saw open() fail
 * with EIO several times per 300 creates, with no device error anywhere.
 *
 * A failure caused by a racing invalidation is transient and converges on
 * re-read; a real I/O error persists. Retrying a bounded number of times
 * separates the two -- the same reasoning the checksummed-record readers
 * already use for torn reads (see cetrafs_read_raw_inode() and the dirent
 * tail check), applied to the layer below them.
 */
struct buffer_head *cetrafs_bread_retry(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh;
    int attempt;

    for (attempt = 0; attempt < CETRAFS_BREAD_RETRIES; attempt++) {
        bh = sb_bread(sb, block);
        if (bh)
            return bh;
        /* Back off rather than spin: the window is another thread's
         * invalidate, and retrying instantly just lands in the same
         * storm when that thread is invalidating in a loop (every
         * dentry revalidate does). */
        usleep_range(50, 200);
    }

    pr_err("block %llu unreadable after %d attempts\n", (unsigned long long) block, CETRAFS_BREAD_RETRIES);
    return NULL;
}

/* cetrafs_bread_uncached() with the same bounded retries as
 * cetrafs_bread_retry(), for the same reason: bh_read() reports failure
 * if the uptodate bit is gone by the time it re-checks, which a
 * concurrent forced-fresh read of the same block can cause. */
struct buffer_head *cetrafs_bread_uncached_retry(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh;
    int attempt;

    for (attempt = 0; attempt < CETRAFS_BREAD_RETRIES; attempt++) {
        bh = cetrafs_bread_uncached(sb, block);
        if (bh)
            return bh;
        usleep_range(50, 200);
    }

    /* Ratelimited: when the DEVICE is gone rather than a single block
     * being bad, every caller fails, and the heartbeat alone sweeps 64
     * registry rows per tick -- measured at ~500 of these lines in
     * eight seconds, which buries the one message that explains what
     * happened. The failure is still reported, just not once per
     * block. */
    pr_err_ratelimited("block %llu unreadable (forced-fresh) after %d attempts\n", (unsigned long long) block,
                       CETRAFS_BREAD_RETRIES);
    return NULL;
}

/*
 * cetrafs_bread_uncached() over a run of n contiguous blocks, as ONE
 * batch: each clean cached copy is dropped exactly as there (a dirty or
 * held-back buffer is a write of ours still in flight, kept), every read
 * is submitted under one plug so the block layer can merge the run into
 * a few large requests, and only then is each waited for. n serial
 * round trips become about one. A block whose batched read did not come
 * back uptodate -- a device error, or a concurrent forced-fresh reader
 * clearing the bit after the read landed (see cetrafs_bread_retry()) --
 * is read again alone through cetrafs_bread_uncached_retry().
 *
 * Fills bhs[0..n) with referenced buffers. On failure every buffer is
 * released, bhs[] is zeroed and -EIO is returned.
 */
static int __cetrafs_bread_uncached_batch(struct super_block *sb, sector_t start, const sector_t *list, u32 n,
                                          struct buffer_head **bhs);

int cetrafs_bread_uncached_batch(struct super_block *sb, sector_t start, u32 n, struct buffer_head **bhs)
{
    return __cetrafs_bread_uncached_batch(sb, start, NULL, n, bhs);
}

/* The same, over n blocks anywhere: list[i] is bhs[i]'s block. One plug,
 * one wait each, instead of one round trip per block. */
int cetrafs_bread_uncached_list(struct super_block *sb, const sector_t *list, u32 n, struct buffer_head **bhs)
{
    return __cetrafs_bread_uncached_batch(sb, 0, list, n, bhs);
}

static int __cetrafs_bread_uncached_batch(struct super_block *sb, sector_t start, const sector_t *list, u32 n,
                                          struct buffer_head **bhs)
{
    struct blk_plug plug;
    u32 i;

#define CETRAFS_BATCH_BLK(i) (list ? list[i] : start + (i))
    memset(bhs, 0, n * sizeof(*bhs)); /* the failure path releases every slot */
    for (i = 0; i < n; i++) {
        bhs[i] = sb_getblk(sb, CETRAFS_BATCH_BLK(i));
        if (!bhs[i])
            goto fail;
    }

    blk_start_plug(&plug);
    for (i = 0; i < n; i++) {
        struct buffer_head *bh = bhs[i];

        lock_buffer(bh);
        if (buffer_uptodate(bh) && !cetrafs_bh_pending(bh))
            clear_buffer_uptodate(bh);
        if (buffer_uptodate(bh)) {
            unlock_buffer(bh); /* our own pending write: what bh_read() would return too */
            continue;
        }
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
        /* As __bh_read() on 7.2: the bio completion unlocks the buffer and
         * takes no reference of its own (as the write paths below). */
        bh_submit(bh, REQ_OP_READ, bh_end_read);
#else
        /* As __bh_read(): the completion unlocks and drops this ref. */
        get_bh(bh);
        bh->b_end_io = end_buffer_read_sync;
        submit_bh(REQ_OP_READ, bh);
#endif
    }
    blk_finish_plug(&plug);

    for (i = 0; i < n; i++) {
        wait_on_buffer(bhs[i]);
        if (buffer_uptodate(bhs[i]))
            continue;
        brelse(bhs[i]);
        bhs[i] = cetrafs_bread_uncached_retry(sb, CETRAFS_BATCH_BLK(i));
        if (!bhs[i])
            goto fail;
    }
    return 0;
#undef CETRAFS_BATCH_BLK

fail:
    for (i = 0; i < n; i++) {
        brelse(bhs[i]); /* NULL-safe */
        bhs[i] = NULL;
    }
    return -EIO;
}

/*
 * Claim a cached buffer for modification; cetrafs_bh_end_update(sb, )
 * publishes the result. Only the buffer LOCK excludes both hazards:
 *
 *  1. The forced-fresh readers above clear uptodate and re-read into the
 *     buffer's memory. Against a buffer a local thread is partway
 *     through modifying, the modification is overwritten and then
 *     persisted over -- measured as 12 of 292 dirents silently lost.
 *     They take the lock before clearing, so holding it makes them wait.
 *
 *  2. Writeback can flush a DIRTY buffer at any moment, and a block
 *     modified but not yet restamped is not a legal image: a peer reads
 *     it and it fails its tail checksum until our sync lands. Writeback
 *     locks the buffer, so holding the lock across modify-and-restamp
 *     means only complete, checksummed images reach the device.
 *
 * Marking the buffer dirty up front instead closes (1) and causes (2).
 *
 * Between begin and end, call nothing that takes the buffer lock itself
 * (sync_dirty_buffer(), bh_read()). The one exception is
 * cetrafs_journal_write_block(), which REQUIRES the buffer still locked
 * and not yet dirty and owns ending the update on every path: a
 * journaled block is modify, restamp, journal -- never end_update in the
 * caller, which would dirty it before its entry commits and let
 * writeback flush the target ahead of the journal.
 */
void cetrafs_bh_begin_update(struct buffer_head *bh)
{
    lock_buffer(bh);
    /* The content at this instant is still the valid on-disk image, so
     * asserting uptodate is honest -- and it must be set before any
     * modification, since a reader may have cleared it. */
    set_buffer_uptodate(bh);
}

/*
 * cetrafs_bh_begin_update() for a block that is about to be JOURNALED,
 * returning the CRC32C of the pristine image it just locked.
 *
 * That CRC goes into the journal entry as prev_checksum, and is what
 * lets replay prove the target has not been rewritten by somebody else
 * since (see cetrafs_journal_header_t). Taking it here rather than at
 * the call site is the point: the lock and the snapshot come from one
 * call, so a caller cannot read the "prior" image a modification too
 * late. Costs one 4 KiB CRC (~0.5 us) on paths that are already doing a
 * synchronous device round trip (~38 ms on the deployment LUN), and
 * never runs on the per-block data path -- see docs/PERFORMANCE.md
 * invariant 1 before moving it anywhere else.
 */
static atomic64_t cetrafs_update_crcs = ATOMIC64_INIT(0);

u64 cetrafs_update_crc_count(void)
{
    return (u64) atomic64_read(&cetrafs_update_crcs);
}

u32 cetrafs_bh_begin_update_crc(struct buffer_head *bh)
{
    cetrafs_bh_begin_update(bh);
    /* A held-back block (leafdefer.c) skips the pre-image CRC. Its
     * device image is already in its listing (d->disk_crc), and every
     * consumer of this value ignores it for a listed block:
     *  - cetrafs_bh_defer_update(): a listed block returns before using
     *    prev_crc (the only use is the new-entry path, reached only for
     *    an unlisted block);
     *  - cetrafs_tree_hold_back()'s fallback: taken only when the defer
     *    declines, which it does only for an UNLISTED block;
     *  - cetrafs_journal_write_block_flags(): for a block whose bit is
     *    set, a GUARDED entry takes the listing's disk_crc instead;
     *  - the boundary: its entry's prev_checksum is d->disk_crc, from
     *    the listing, never this value.
     * The bit and the listing change together under the buffer lock this
     * call holds, so "bit set, unlisted" cannot be seen here (that WARN
     * path is the one place prev_crc would be used). The TEST ONLY
     * deferred_hold_eager control computes it anyway, as before. */
    if (buffer_cetra_deferred(bh) && !cetrafs_deferred_eager())
        return 0;
    atomic64_inc(&cetrafs_update_crcs);
    return ~crc32c(~0U, bh->b_data, CETRAFS_BLOCK_SIZE);
}

/*
 * Read a cached block's bytes while no in-place update is half done.
 *
 * The update protocol above holds the buffer lock across
 * modify-and-restamp, and a cached read verifies no checksum, so a
 * reader that holds none of the writer's other locks (writeback, an
 * O_DIRECT read: cetrafs_tree_lookup_unchecked()) takes the same lock
 * to see a whole image. Hold it only to COPY what is needed: an
 * update holds it across a journal round trip.
 */
void cetrafs_bh_read_lock(struct buffer_head *bh)
{
    lock_buffer(bh);
}

void cetrafs_bh_read_unlock(struct buffer_head *bh)
{
    unlock_buffer(bh);
}

/* The pre-A-15 publish: dirty, for the block layer's writeback. Only the
 * fallbacks below and TEST ONLY meta_writeback use it. */
static void cetrafs_bh_end_update_dirty(struct buffer_head *bh)
{
    cetrafs_blk_tail_settle(bh); /* dirty means writeback may write it: never with a stale tail */
    mark_buffer_dirty(bh);
    unlock_buffer(bh);
}

/* TEST ONLY: in-place metadata updates are left dirty for writeback, as
 * before A-15's second half (tests/kernel/fence_writeback_meta.sh). */
static bool cetrafs_meta_writeback;
cetrafs_test_param(meta_writeback, cetrafs_meta_writeback, bool, 0644);
MODULE_PARM_DESC(meta_writeback, "TEST ONLY: in-place metadata updates are left dirty for writeback (before A-15)");

/*
 * Publish a buffer modified under cetrafs_bh_begin_update(): it is a
 * complete, correctly-checksummed image from here on.
 *
 * HELD, not dirtied, as the allocation bitmaps are
 * (cetrafs_bh_end_update_held()): only cetrafs writes it -- the caller's
 * own gated write (cetrafs_sync_buffer(), cetrafs_write_pending_buffer()),
 * or the held flush at a heartbeat tick, sync_fs or unmount, each of
 * which refuses on a fenced mount. Dirty, it was the block layer's to
 * write too: a node frozen between this and its write -- or fenced
 * there, whose refused write left it dirty until the queued sweep ran --
 * had the flusher put the image on the device after its lease was gone,
 * over whatever a peer had written there since (audit 2026-11-15 A-15).
 */
void cetrafs_bh_end_update(struct super_block *sb, struct buffer_head *bh)
{
    if (READ_ONCE(cetrafs_meta_writeback)) {
        cetrafs_bh_end_update_dirty(bh); /* test-only; see the parameter */
        return;
    }
    cetrafs_blk_tail_settle(bh); /* held is written as it stands: never with a stale tail */
    cetrafs_bh_end_update_held(sb, bh, true);
}

/*
 * End an update of an allocation-bitmap block: HELD from the device, not
 * dirtied (BH_CetraHeld; kmod.h). Only cetrafs writes it, at its own
 * gated points -- a boundary's bitmap flush (cetrafs_alloc_flush_bitmaps(),
 * through cetrafs_sync_buffer_keep()), a heartbeat tick, sync_fs, unmount
 * (cetrafs_held_flush()) -- each of which refuses on a fenced mount. The
 * block layer's writeback never sees it, so a node that froze past its
 * lease cannot have writeback lay its stale bitmap over a peer's before
 * the self-fence drops it (audit 2026-11-14 A-15).
 *
 * 'changed' false: the update changed no bit, and the block is left as it
 * was -- dirtying an unchanged image is not free either: a bitmap block
 * dirtied by a free that cleared nothing outlived the hand-back of its
 * group and was written over the next owner's (audit 2026-11-14 A-3).
 *
 * Pinned (get_bh) while listed, so reclaim cannot drop the only copy.
 * Called with the buffer locked (cetrafs_bh_begin_update()); unlocks.
 */
static bool cetrafs_bitmap_writeback;
cetrafs_test_param(bitmap_writeback, cetrafs_bitmap_writeback, bool, 0644);
MODULE_PARM_DESC(bitmap_writeback, "TEST ONLY: allocation bitmaps are left dirty for writeback (before A-15)");

static int __cetrafs_keep_submit(struct super_block *sb, struct buffer_head *bh, bool *was_dirty, bool *was_held);
static int __cetrafs_keep_wait(struct buffer_head *bh, bool was_dirty, bool was_held);
static int cetrafs_meta_write_result(struct super_block *sb, struct buffer_head *bh, int ret);

static atomic64_t cetrafs_held_flushes = ATOMIC64_INIT(0);

u64 cetrafs_held_flush_count(void)
{
    return (u64) atomic64_read(&cetrafs_held_flushes);
}

void cetrafs_bh_end_update_held(struct super_block *sb, struct buffer_head *bh, bool changed)
{
    struct xarray *xa = cetrafs_sb_held(sb);
    void *old;

    if (!changed) {
        unlock_buffer(bh);
        return;
    }
    if (READ_ONCE(cetrafs_bitmap_writeback) || !xa) {
        cetrafs_bh_end_update_dirty(bh); /* test-only (or no sb_info): dirty, as before */
        return;
    }
    if (!test_set_buffer_cetra_held(bh)) {
        get_bh(bh);
        old = xa_store(xa, bh->b_blocknr, bh, GFP_NOFS);
        if (xa_is_err(old)) {
            /* No room to list it: dirty, as before -- writeback may
             * write it, which is the old exposure, not a lost bit. */
            clear_buffer_cetra_held(bh);
            put_bh(bh);
            cetrafs_bh_end_update_dirty(bh);
            return;
        }
        if (old)
            put_bh((struct buffer_head *) old); /* listed already: one pin per entry */
    }
    unlock_buffer(bh);
}

/*
 * Write every held bitmap block, and unlist what is no longer held. A
 * gated write: nothing on a fenced or stopped mount. On a failed write
 * the block stays held -- its bytes are the only record of bits that did
 * not land (cetrafs_sync_buffer_keep()) -- and the error is returned.
 */
/* TEST ONLY: write held blocks one at a time, each waited for before the
 * next is sent -- the flush before batching (tests/kernel/held_flush_batched.sh). */
static bool cetrafs_held_flush_serial;
cetrafs_test_param(held_flush_serial, cetrafs_held_flush_serial, bool, 0644);
MODULE_PARM_DESC(held_flush_serial, "TEST ONLY: the held-bitmap flush writes one block at a time");

static atomic64_t cetrafs_held_flush_batches = ATOMIC64_INIT(0);

u64 cetrafs_held_flush_batch_count(void)
{
    return (u64) atomic64_read(&cetrafs_held_flush_batches);
}

#define CETRAFS_HELD_BATCH 256

struct cetrafs_held_io {
    struct buffer_head *bh;
    unsigned long idx;
    int state; /* __cetrafs_keep_submit()'s answer */
    bool was_dirty, was_held;
};

/* Finish one entry: its write's verdict, and unlisted if no longer held. */
static int cetrafs_held_finish(struct super_block *sb, struct xarray *xa, struct cetrafs_held_io *io)
{
    struct buffer_head *bh = io->bh;
    int r = io->state == 1 ? __cetrafs_keep_wait(bh, io->was_dirty, io->was_held) : io->state;

    r = cetrafs_meta_write_result(sb, bh, r);
    lock_buffer(bh);
    if (!buffer_cetra_held(bh) && xa_load(xa, io->idx) == bh) {
        xa_erase(xa, io->idx);
        put_bh(bh); /* the list's pin */
    }
    unlock_buffer(bh);
    put_bh(bh);
    return r;
}

/*
 * Every held block is sent before any is waited for, a batch at a time
 * under one plug: one synchronous write per block, ~38 ms each on a SAN,
 * made deleting a 1 TiB image (~8,192 bitmap blocks) about five minutes
 * of serial writes that the pending-free drain, a Zone Group release and
 * every sync queued behind -- where writeback, before A-15, had sent them
 * together and merged neighbours.
 */
int cetrafs_held_flush(struct super_block *sb)
{
    struct xarray *xa = cetrafs_sb_held(sb);
    struct cetrafs_held_io one, *io;
    struct buffer_head *bh;
    unsigned long idx;
    unsigned int n = 0, cap, i;
    struct blk_plug plug;
    int ret = 0, r;

    if (!xa || xa_empty(xa))
        return 0;
    if (cetrafs_sb_fence_witnessed(sb)) /* the device's word, not only the clock's (B-18) */
        return -EIO;
    atomic64_inc(&cetrafs_held_flushes);
    io = READ_ONCE(cetrafs_held_flush_serial) ? NULL : kmalloc_array(CETRAFS_HELD_BATCH, sizeof(*io), GFP_NOFS);
    cap = io ? CETRAFS_HELD_BATCH : 1;
    if (!io)
        io = &one;
    blk_start_plug(&plug);
    xa_for_each(xa, idx, bh) {
        get_bh(bh);
        io[n].bh = bh;
        io[n].idx = idx;
        io[n].state = __cetrafs_keep_submit(sb, bh, &io[n].was_dirty, &io[n].was_held);
        if (++n < cap)
            continue;
        blk_finish_plug(&plug);
        atomic64_inc(&cetrafs_held_flush_batches);
        for (i = 0; i < n; i++) {
            r = cetrafs_held_finish(sb, xa, &io[i]);
            if (r && !ret)
                ret = r;
        }
        n = 0;
        cond_resched();
        blk_start_plug(&plug);
    }
    blk_finish_plug(&plug);
    if (n)
        atomic64_inc(&cetrafs_held_flush_batches);
    for (i = 0; i < n; i++) {
        r = cetrafs_held_finish(sb, xa, &io[i]);
        if (r && !ret)
            ret = r;
    }
    if (io != &one)
        kfree(io);
    return ret;
}

/*
 * Forget every held block unwritten: the self-fence's sweep, a stopped
 * mount's unmount, and the last teardown (where a clean unmount has
 * flushed them and this only gives the pins back). The bytes are
 * dropped (!uptodate): the next read is the device's. Returns how many
 * were still held.
 */
unsigned long cetrafs_held_drop_all(struct super_block *sb)
{
    struct xarray *xa = cetrafs_sb_held(sb);
    struct buffer_head *bh;
    unsigned long idx, dropped = 0;

    if (!xa)
        return 0;
    xa_for_each(xa, idx, bh) {
        lock_buffer(bh);
        if (test_clear_buffer_cetra_held(bh)) {
            dropped++;
            if (!buffer_dirty(bh))
                clear_buffer_uptodate(bh);
        }
        unlock_buffer(bh);
        xa_erase(xa, idx);
        put_bh(bh);
    }
    return dropped;
}

/*
 * Write a dirty buffer synchronously and say whether it reached the
 * device. Use this, not sync_dirty_buffer(), wherever the answer matters.
 *
 * sync_dirty_buffer() decides failure by looking at BH_Uptodate AFTER
 * the write completes. In this module that is a race, not an answer: a
 * forced-fresh reader (cetrafs_bread_uncached(), every stat/lookup)
 * takes the buffer lock the moment the write's completion drops it and
 * clears BH_Uptodate to re-read. The writer then sees !uptodate and
 * reports -EIO for a write that landed -- measured as creates failing
 * EIO while `ls -la` loops ran (dir_concurrency.sh), the moment the
 * record writers started honouring the result. BH_Write_EIO is set by
 * the write's own completion and nothing else clears it, so it is the
 * one honest witness.
 *
 * Not dirty: nothing to write -- after waiting out a write already in
 * flight (the buffer lock). That write carried OUR update too, and when
 * it was writeback's nobody else will ever look at its result: a failure
 * it left behind (BH_Write_EIO) is this caller's lost update and is
 * reported as one, exactly as __cetrafs_sync_buffer_keep() does (audit
 * 2026-11-05, class 16; tests/kernel/sync_buffer_sees_writeback_eio.sh).
 */
static unsigned int cetrafs_sync_writeback_eio;
cetrafs_test_param(sync_writeback_eio, cetrafs_sync_writeback_eio, uint, 0644);
MODULE_PARM_DESC(sync_writeback_eio,
                 "TEST ONLY: the next N synchronous metadata writes find the buffer written and failed by writeback");

/*
 * Write a locked buffer whose dirty bit the caller cleared, wait, unlock,
 * and return the block layer's OWN status as an errno. submit_bh()'s
 * completion is told only "uptodate or not", so a definite "space
 * allocation failed" from a thin LUN (BLK_STS_NOSPC: sd's DATA PROTECT
 * 27/07, dm-thin out of space) read exactly like a medium error, and the
 * mount stopped for it (audit 2026-11-14 A-4). On failure the buffer
 * ends as end_buffer_write_sync() leaves it: BH_Write_EIO, not uptodate.
 */
static unsigned int cetrafs_meta_write_nospc;
cetrafs_test_param(meta_write_nospc, cetrafs_meta_write_nospc, uint, 0644);
MODULE_PARM_DESC(meta_write_nospc, "TEST ONLY: the next N synchronous metadata writes return BLK_STS_NOSPC unsent");

/* TEST ONLY: every synchronous metadata write of this one block answers
 * BLK_STS_NOSPC unsent while it is set -- a block the array keeps
 * refusing, as a snapshot's copy-on-write with the pool full does
 * (tests/kernel/journal_replay_refused.sh). 0 = off. */
static unsigned long long cetrafs_meta_write_nospc_block;
cetrafs_test_param(meta_write_nospc_block, cetrafs_meta_write_nospc_block, ullong, 0644);

static int cetrafs_write_locked_bh(struct buffer_head *bh)
{
    struct bio *bio;
    int ret;

    if (READ_ONCE(cetrafs_meta_write_nospc_block) && bh->b_blocknr == READ_ONCE(cetrafs_meta_write_nospc_block)) {
        ret = -ENOSPC; /* test-only: see the parameter */
        goto done;
    }
    if (cetrafs_meta_write_nospc) {
        cetrafs_meta_write_nospc--;
        ret = -ENOSPC; /* test-only: what a full thin pool answers */
        goto done;
    }
    bio = bio_alloc(bh->b_bdev, 1, REQ_OP_WRITE | REQ_SYNC | REQ_META, GFP_NOIO);
    bio->bi_iter.bi_sector = bh->b_blocknr * (bh->b_size >> 9);
    /* The folio and the offset in it, as submit_bh() builds its bio: a
     * block device cache in large folios puts b_data past b_page's first
     * page, where the page form pointed at the wrong one. */
    bio_add_folio_nofail(bio, bh->b_folio, bh->b_size, offset_in_folio(bh->b_folio, bh->b_data));
    ret = submit_bio_wait(bio);
    bio_put(bio);
done:
    if (ret) {
        set_buffer_write_io_error(bh);
        clear_buffer_uptodate(bh);
    } else {
        set_buffer_uptodate(bh);
    }
    unlock_buffer(bh);
    return ret;
}

/*
 * The fence, asked again UNDER the buffer lock. Every writer asks before
 * it starts, and then takes lock_buffer() -- which waits out a write of
 * the same block already in flight, for as long as the device takes. A
 * node whose lease lapsed in that wait submitted its newer image anyway,
 * after a peer may have taken the block over (audit 2026-11-15 BM-24).
 * Asked here, nothing is submitted once the fence is known: the buffer
 * keeps its dirt for the fence's sweep to discard, and the caller gets
 * -ESHUTDOWN, which cetrafs_meta_write_result() reports as -EIO without
 * calling it a device error.
 */
static bool cetrafs_meta_gate_unlocked_only;
cetrafs_test_param(meta_gate_unlocked_only, cetrafs_meta_gate_unlocked_only, bool, 0644);
MODULE_PARM_DESC(meta_gate_unlocked_only, "TEST ONLY: metadata writes ask the fence only before the buffer lock");
static unsigned int cetrafs_meta_gate_stall_ms;
cetrafs_test_param(meta_gate_stall_ms, cetrafs_meta_gate_stall_ms, uint, 0644);
MODULE_PARM_DESC(meta_gate_stall_ms, "TEST ONLY: one-shot stall of the next synchronous metadata write, just after it locks its buffer");
static unsigned long long cetrafs_meta_gate_stall_block;
cetrafs_test_param(meta_gate_stall_block, cetrafs_meta_gate_stall_block, ullong, 0644);
MODULE_PARM_DESC(meta_gate_stall_block, "TEST ONLY: meta_gate_stall_ms holds only a write of this block (0 = any)");

static inline bool cetrafs_meta_gate_shut(struct super_block *sb)
{
    return sb && !READ_ONCE(cetrafs_meta_gate_unlocked_only) && cetrafs_sb_is_fenced(sb);
}

static int __cetrafs_sync_buffer(struct super_block *sb, struct buffer_head *bh)
{
    lock_buffer(bh);
    /* TEST ONLY: the lock won after a wait the fence landed in -- held
     * here, the fence's own sweep queues behind it as it would behind
     * the in-flight write this writer waited out. */
    if (unlikely(READ_ONCE(cetrafs_meta_gate_stall_ms)) &&
        (!READ_ONCE(cetrafs_meta_gate_stall_block) || bh->b_blocknr == READ_ONCE(cetrafs_meta_gate_stall_block))) {
        unsigned int ms = xchg(&cetrafs_meta_gate_stall_ms, 0);

        if (ms) {
            pr_info("meta_gate_stall: block %llu, %u ms\n", (unsigned long long) bh->b_blocknr, ms);
            msleep(ms);
        }
    }
    if (cetrafs_meta_gate_shut(sb)) {
        unlock_buffer(bh);
        return -ESHUTDOWN;
    }
    if (cetrafs_sync_writeback_eio && buffer_dirty(bh)) {
        /* what a failed flusher write leaves: clean, BH_Write_EIO */
        cetrafs_sync_writeback_eio--;
        clear_buffer_dirty(bh);
        set_buffer_write_io_error(bh);
    }
    if (!test_clear_buffer_dirty(bh) && !test_clear_buffer_cetra_held(bh)) {
        int ret = buffer_write_io_error(bh) ? -EIO : 0;

        clear_buffer_write_io_error(bh); /* reported once: the mount stops */
        unlock_buffer(bh);
        return ret;
    }
    clear_buffer_cetra_held(bh); /* written now, whichever it was */
    clear_buffer_write_io_error(bh);
    return cetrafs_write_locked_bh(bh);
}

/*
 * Completion for cetrafs_sync_buffer_keep(): unlike end_buffer_write_sync()
 * it never clears BH_Uptodate on an error -- see there.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
static void cetrafs_end_write_keep(struct bio *bio)
{
    struct buffer_head *bh;

    if (!bio_endio_bh(bio, &bh))
        set_buffer_write_io_error(bh);
    unlock_buffer(bh);
}
#else
static void cetrafs_end_write_keep(struct buffer_head *bh, int uptodate)
{
    if (!uptodate)
        set_buffer_write_io_error(bh);
    unlock_buffer(bh);
    put_bh(bh);
}
#endif

/*
 * cetrafs_sync_buffer() for a block whose cached bytes are the ONLY copy
 * of state the device does not have yet -- the allocation bitmaps. A
 * failed write must not discard them: a buffer left !uptodate is re-read
 * from the device by the next sb_bread(), which silently forgets
 * allocations of blocks already in use. So on failure the buffer stays
 * uptodate and is re-dirtied, and the next durability boundary retries.
 *
 * Also catches an EARLIER failed write of the same block (the flusher's,
 * whose completion does clear BH_Uptodate): while the bit is still clear
 * nobody has re-read the block over our bytes, so they are put back.
 */
/* The submit half: 1 submitted (finish with __cetrafs_keep_wait()), 0
 * nothing to write, -EIO an earlier failed write found and re-dirtied. */
static int __cetrafs_keep_submit(struct super_block *sb, struct buffer_head *bh, bool *was_dirty, bool *was_held)
{
    lock_buffer(bh); /* also waits out a writeback already in flight */
    if (cetrafs_meta_gate_shut(sb)) {
        unlock_buffer(bh);
        return -ESHUTDOWN;
    }
    if (buffer_write_io_error(bh)) {
        clear_buffer_write_io_error(bh);
        set_buffer_uptodate(bh);
        unlock_buffer(bh);
        mark_buffer_dirty(bh);
        return -EIO;
    }
    *was_dirty = test_clear_buffer_dirty(bh);
    *was_held = test_clear_buffer_cetra_held(bh);
    if (!*was_dirty && !*was_held) {
        unlock_buffer(bh);
        return 0;
    }
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
    bh_submit(bh, REQ_OP_WRITE | REQ_SYNC, cetrafs_end_write_keep);
#else
    get_bh(bh);
    bh->b_end_io = cetrafs_end_write_keep;
    submit_bh(REQ_OP_WRITE | REQ_SYNC, bh);
#endif
    return 1;
}

/* The completion half of a submitted keep-write. */
static int __cetrafs_keep_wait(struct buffer_head *bh, bool was_dirty, bool was_held)
{
    wait_on_buffer(bh);
    if (buffer_write_io_error(bh)) {
        clear_buffer_write_io_error(bh);
        /* still uptodate: the next boundary retries it -- held again
         * if it was held, never handed to writeback (A-15) */
        if (was_held && !was_dirty) {
            lock_buffer(bh);
            set_buffer_cetra_held(bh);
            unlock_buffer(bh);
        } else {
            mark_buffer_dirty(bh);
        }
        return -EIO;
    }
    return 0;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
static void cetrafs_end_write_pending(struct bio *bio)
{
    struct buffer_head *bh;

    if (bio_endio_bh(bio, &bh)) {
        set_buffer_uptodate(bh);
    } else {
        set_buffer_write_io_error(bh);
        clear_buffer_uptodate(bh);
    }
    unlock_buffer(bh);
}
#else
static void cetrafs_end_write_pending(struct buffer_head *bh, int uptodate)
{
    if (uptodate) {
        set_buffer_uptodate(bh);
    } else {
        set_buffer_write_io_error(bh);
        clear_buffer_uptodate(bh);
    }
    unlock_buffer(bh);
    put_bh(bh);
}
#endif

/*
 * write_dirty_buffer() for a buffer published by cetrafs_bh_end_update(sb, ):
 * held or dirty, it is submitted (no wait -- the caller waits, as it did
 * for write_dirty_buffer(), and judges uptodate); neither, nothing is.
 * Ends as end_buffer_write_sync() leaves a buffer.
 */
void cetrafs_write_pending_buffer(struct super_block *sb, struct buffer_head *bh, unsigned int op_flags)
{
    bool dirty, held;

    lock_buffer(bh);
    if (cetrafs_meta_gate_shut(sb)) {
        /* Not sent, and its caller judges by uptodate: as a failed
         * write leaves it. A fenced node writes none of its dirt. */
        clear_buffer_dirty(bh);
        clear_buffer_cetra_held(bh);
        set_buffer_write_io_error(bh);
        clear_buffer_uptodate(bh);
        unlock_buffer(bh);
        return;
    }
    dirty = test_clear_buffer_dirty(bh);
    held = test_clear_buffer_cetra_held(bh);
    if (!dirty && !held) {
        unlock_buffer(bh);
        return;
    }
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
    bh_submit(bh, REQ_OP_WRITE | op_flags, cetrafs_end_write_pending);
#else
    get_bh(bh);
    bh->b_end_io = cetrafs_end_write_pending;
    submit_bh(REQ_OP_WRITE | op_flags, bh);
#endif
}

static int __cetrafs_sync_buffer_keep(struct super_block *sb, struct buffer_head *bh)
{
    bool was_dirty, was_held;
    int ret = __cetrafs_keep_submit(sb, bh, &was_dirty, &was_held);

    return ret == 1 ? __cetrafs_keep_wait(bh, was_dirty, was_held) : ret;
}

/*
 * A metadata write the device refused is fatal to the mount
 * (docs/internal/ERRORS.md, kind 3). The caller has usually written
 * other blocks of the same operation already, and its unwind -- more
 * metadata writes -- would go to the device that just failed one; what
 * is on the device from here on is something this node can only guess
 * at. Stopping turns it into a crash at this point, which the journal
 * and the peers' reclaim already recover from. dm-multipath retries a
 * failed path before an error gets this far.
 *
 * The callers still see -EIO and unwind as before; on a stopped mount
 * every write they attempt is refused at its own gate, without I/O.
 */
/* TEST ONLY: a new block's definite NOSPC stops the mount, as before. */
static bool cetrafs_nospc_stops;
cetrafs_test_param(nospc_stops, cetrafs_nospc_stops, bool, 0644);
MODULE_PARM_DESC(nospc_stops, "TEST ONLY: a new metadata block refused for space stops the mount (the old verdict)");

static atomic64_t cetrafs_meta_nospc = ATOMIC64_INIT(0);

u64 cetrafs_meta_nospc_count(void)
{
    return (u64) atomic64_read(&cetrafs_meta_nospc);
}

static unsigned int cetrafs_meta_write_fail;
cetrafs_test_param(meta_write_fail, cetrafs_meta_write_fail, uint, 0644);
MODULE_PARM_DESC(meta_write_fail, "TEST ONLY: fail the next N synchronous metadata writes as the device would");

/* What a block of the volume IS, for the line that stops the mount over
 * it: an operator reading "block 81234" cannot tell a journal slot from
 * a directory (audit 2026-11-14 O3). Positional, from the superblock. */
const char *cetrafs_block_role(struct super_block *sb, u64 lba)
{
    const cetrafs_superblock_t *r = cetrafs_sb_raw(sb);
#define CETRAFS_IN(start, n) (lba >= (u64) (start) && lba - (u64) (start) < (u64) (n))

    if (!r)
        return "a block";
    if (lba == 0)
        return "the superblock";
    if (CETRAFS_IN(le64_to_cpu(r->zg_table_start), le32_to_cpu(r->zone_group_count)))
        return "a Zone Group record";
    if (CETRAFS_IN(le64_to_cpu(r->bg_table_start), le64_to_cpu(r->bg_table_first_count)))
        return "a Block Group descriptor";
    if (CETRAFS_IN(le64_to_cpu(r->inode_bmap_start), le64_to_cpu(r->inode_bmap_blocks)))
        return "the inode bitmap";
    if (CETRAFS_IN(le64_to_cpu(r->inode_table_start), le64_to_cpu(r->inode_table_blocks)))
        return "an inode record";
    if (CETRAFS_IN(le64_to_cpu(r->node_table_start), le64_to_cpu(r->node_table_blocks)))
        return "a Node Registry row";
    if (CETRAFS_IN(le64_to_cpu(r->node_journal_start),
                   (u64) le32_to_cpu(r->node_journal_blocks) * le32_to_cpu(r->node_table_count)))
        return "a node journal block";
    if (CETRAFS_IN(le64_to_cpu(r->pending_free_start),
                   (u64) le32_to_cpu(r->pending_free_blocks_per_zg) * le32_to_cpu(r->zone_group_count)))
        return "a pending-free queue block";
    if (lba >= le64_to_cpu(r->bg_regions_start))
        return "a Block Group header, bitmap, or tree or directory block";
    return "a reserved block";
#undef CETRAFS_IN
}

static int cetrafs_meta_write_result(struct super_block *sb, struct buffer_head *bh, int ret)
{
    if (ret == -ESHUTDOWN)
        return -EIO; /* the fence, asked under the buffer lock: nothing was sent */
    if (!ret && cetrafs_meta_write_fail) {
        cetrafs_meta_write_fail--;
        ret = -EIO;
    }
    /* Stop, whatever the cause: a buffer write reports only that it did
     * not complete, never whether anything landed, so "refused, nothing
     * written" cannot be told from a torn write here (O3; ERRORS.md). */
    if (ret)
        cetrafs_sb_fatal(sb, "the device refused a metadata write (%s, block %llu, %d)",
                         cetrafs_block_role(sb, bh->b_blocknr), (unsigned long long) bh->b_blocknr, ret);
    return ret;
}

/* A refusal the device made BEFORE writing anything: a thin pool out of
 * space (BLK_STS_NOSPC), a target refusing the command (BLK_STS_TARGET).
 * Anything else may have landed in part. */
bool cetrafs_refusal_definite(int err)
{
    return err == -ENOSPC || err == -EREMOTEIO;
}

/* TEST ONLY: the next N buffers cetrafs_write_bhs_status() writes -- a
 * journal entry's payload, then its header -- answer BLK_STS_NOSPC unsent
 * (tests/kernel/dirent_nospc_op.sh). */
static unsigned int cetrafs_journal_entry_nospc;
cetrafs_test_param(journal_entry_nospc, cetrafs_journal_entry_nospc, uint, 0644);
MODULE_PARM_DESC(journal_entry_nospc, "TEST ONLY: the next N journal entry blocks are refused for space");

struct cetrafs_status_bio {
    struct completion *all;
    atomic_t *left;
    int status;
};

static void cetrafs_status_bio_end(struct bio *bio)
{
    struct cetrafs_status_bio *io = bio->bi_private;

    io->status = blk_status_to_errno(bio->bi_status);
    bio_put(bio);
    if (atomic_dec_and_test(io->left))
        complete(io->all);
}

/*
 * Write up to two buffers published by cetrafs_bh_end_update() -- a
 * journal entry's payload and header -- together, and say for each what
 * the DEVICE answered (st[i], an errno): the buffer layer's own completion
 * keeps only "uptodate or not", and a definite "no space" must be told
 * from a write that may have landed (audit 2026-11-14 A-4). Ends each
 * buffer as end_buffer_write_sync() leaves it. A buffer with nothing to
 * write gets st 0.
 */
void cetrafs_write_bhs_status(struct super_block *sb, struct buffer_head **bhs, unsigned int n, int *st)
{
    DECLARE_COMPLETION_ONSTACK(all);
    struct cetrafs_status_bio io[2];
    bool sent[2] = {false, false};
    atomic_t left = ATOMIC_INIT(1);
    struct blk_plug plug;
    unsigned int i;

    if (WARN_ON_ONCE(n > 2))
        n = 2;
    blk_start_plug(&plug);
    for (i = 0; i < n; i++) {
        struct buffer_head *bh = bhs[i];
        bool dirty, held;
        struct bio *bio;

        st[i] = 0;
        lock_buffer(bh);
        if (cetrafs_meta_gate_shut(sb)) {
            st[i] = -ESHUTDOWN; /* not sent; the fence's sweep discards the dirt */
            unlock_buffer(bh);
            continue;
        }
        dirty = test_clear_buffer_dirty(bh);
        held = test_clear_buffer_cetra_held(bh);
        if (!dirty && !held) {
            unlock_buffer(bh);
            continue;
        }
        if ((READ_ONCE(cetrafs_meta_write_nospc_block) && bh->b_blocknr == READ_ONCE(cetrafs_meta_write_nospc_block)) ||
            (cetrafs_meta_write_nospc && cetrafs_meta_write_nospc--) ||
            (cetrafs_journal_entry_nospc && cetrafs_journal_entry_nospc--)) {
            st[i] = -ENOSPC; /* test-only: what a full thin pool answers */
            set_buffer_write_io_error(bh);
            clear_buffer_uptodate(bh);
            unlock_buffer(bh);
            continue;
        }
        io[i].all = &all;
        io[i].left = &left;
        io[i].status = 0;
        atomic_inc(&left);
        bio = bio_alloc(bh->b_bdev, 1, REQ_OP_WRITE | REQ_SYNC | REQ_META, GFP_NOIO);
        bio->bi_iter.bi_sector = bh->b_blocknr * (bh->b_size >> 9);
        bio_add_folio_nofail(bio, bh->b_folio, bh->b_size, offset_in_folio(bh->b_folio, bh->b_data));
        bio->bi_private = &io[i];
        bio->bi_end_io = cetrafs_status_bio_end;
        submit_bio(bio);
        sent[i] = true;
    }
    blk_finish_plug(&plug);
    if (!atomic_dec_and_test(&left))
        wait_for_completion_io(&all);
    for (i = 0; i < n; i++) {
        if (!sent[i])
            continue;
        st[i] = io[i].status;
        if (st[i]) {
            set_buffer_write_io_error(bhs[i]);
            clear_buffer_uptodate(bhs[i]);
        } else {
            set_buffer_uptodate(bhs[i]);
        }
        unlock_buffer(bhs[i]);
    }
}

/*
 * cetrafs_sync_buffer() for a block whose operation can fail cleanly: a
 * DEFINITE refusal (nothing was written) comes back as the error and the
 * mount lives; the caller undoes the operation. Anything else stops, as
 * cetrafs_sync_buffer() does: it may have landed.
 */
int cetrafs_sync_buffer_op_refusable(struct super_block *sb, struct buffer_head *bh)
{
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    ret = __cetrafs_sync_buffer(sb, bh);
    if (cetrafs_refusal_definite(ret))
        return ret;
    return cetrafs_meta_write_result(sb, bh, ret);
}

/* The wait half of a metadata write the caller submitted itself (with
 * write_dirty_buffer(), among others in one plug): same verdict as
 * cetrafs_sync_buffer(). */
int cetrafs_wait_meta_write(struct super_block *sb, struct buffer_head *bh)
{
    wait_on_buffer(bh);
    return cetrafs_meta_write_result(sb, bh, buffer_uptodate(bh) ? 0 : -EIO);
}

/* On a stopped mount nothing is written: the dirt stays for the next
 * sweep (cetrafs_drop_dirty_metadata()) to discard. */
int cetrafs_sync_buffer(struct super_block *sb, struct buffer_head *bh)
{
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    return cetrafs_meta_write_result(sb, bh, __cetrafs_sync_buffer(sb, bh));
}

/*
 * cetrafs_sync_buffer() for a journal replay's redo and consume: the
 * device's DEFINITE refusal -- a thin pool out of space (BLK_STS_NOSPC),
 * a target refusing the command (BLK_STS_TARGET: write protect, an
 * illegal request) -- comes back as an error, not a stop. Nothing landed;
 * the entry stays, the area stays DIRTY, and the replayer releases its
 * claim and lives. It stopped instead, and a block the array refuses
 * for everyone -- a snapshot's copy-on-write, a full pool -- stopped
 * every survivor that came to replay the dead node's area, one stale
 * window apart, and boot-looped one under errors=panic (audit 2026-11-15
 * B-25, B-34). The cached copy, which holds the bytes that did not land,
 * is forgotten. Any other error still stops: it may have landed.
 */
static bool cetrafs_replay_refusal_stops;
cetrafs_test_param(replay_refusal_stops, cetrafs_replay_refusal_stops, bool, 0644);
MODULE_PARM_DESC(replay_refusal_stops, "TEST ONLY: a replay write the device refuses stops the mount, as before");

int cetrafs_sync_buffer_refusable(struct super_block *sb, struct buffer_head *bh)
{
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    ret = __cetrafs_sync_buffer(sb, bh);
    if ((ret == -ENOSPC || ret == -EREMOTEIO) && !READ_ONCE(cetrafs_replay_refusal_stops)) {
        pr_warn_ratelimited("%s: the device refused a journal replay write (%s, block %llu, %d) -- not executed; "
                            "the entry is kept for a later replay\n",
                            sb->s_id, cetrafs_block_role(sb, bh->b_blocknr), (unsigned long long) bh->b_blocknr,
                            ret);
        cetrafs_forget_block(sb, bh->b_blocknr);
        return ret;
    }
    return cetrafs_meta_write_result(sb, bh, ret);
}

/*
 * cetrafs_sync_buffer() for a block allocated and initialised just now,
 * which nothing references yet: its caller publishes the reference only
 * after this returns 0 (rule 8), and on an error frees the block. That
 * makes a DEFINITE "no space" from the device -- a thin LUN whose pool is
 * full, the write not executed -- an ordinary ENOSPC for the operation,
 * not a stop: nothing was written, nothing refers to the block, and the
 * buffer is forgotten so no later writeback lays it over whoever gets
 * the block next. The guest sees ENOSPC (qemu pauses it) and the mount
 * stays up for the moment the array has space again. Every other error,
 * and every other metadata write, still stops the mount (audit
 * 2026-11-14 A-4; tests/kernel/thin_nospc_new_block.sh).
 */
/* TEST ONLY: the next N new-block writes find the thin pool full: the
 * write is not sent and answers ENOSPC (tests/kernel/thin_nospc_convert.sh).
 * Only new blocks, so the heartbeat's own writes are not the ones hit. */
static unsigned int cetrafs_new_block_nospc;
cetrafs_test_param(new_block_nospc, cetrafs_new_block_nospc, uint, 0644);
MODULE_PARM_DESC(new_block_nospc, "TEST ONLY: the next N new metadata block writes answer ENOSPC unsent");

int cetrafs_sync_new_buffer(struct super_block *sb, struct buffer_head *bh)
{
    int ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    if (READ_ONCE(cetrafs_new_block_nospc)) {
        WRITE_ONCE(cetrafs_new_block_nospc, cetrafs_new_block_nospc - 1);
        lock_buffer(bh);
        clear_buffer_dirty(bh);
        unlock_buffer(bh);
        ret = -ENOSPC; /* test-only: what a full pool answers */
    } else {
        ret = __cetrafs_sync_buffer(sb, bh);
    }
    if (ret == -ENOSPC && !READ_ONCE(cetrafs_nospc_stops)) {
        atomic64_inc(&cetrafs_meta_nospc);
        pr_warn_ratelimited("%s: the device has no space for a new metadata block (%llu): the operation fails "
                            "with ENOSPC -- a thin-provisioned LUN out of space?\n",
                            sb->s_id, (unsigned long long) bh->b_blocknr);
        cetrafs_forget_block(sb, bh->b_blocknr);
        return -ENOSPC;
    }
    return cetrafs_meta_write_result(sb, bh, ret);
}

/* One new block's write in a batch: cetrafs_sync_new_buffers(). */
struct cetrafs_new_io {
    struct completion *all;
    atomic_t *left;
    int status;
};

static void cetrafs_new_io_end(struct bio *bio)
{
    struct cetrafs_new_io *io = bio->bi_private;

    io->status = blk_status_to_errno(bio->bi_status);
    bio_put(bio);
    if (atomic_dec_and_test(io->left))
        complete(io->all);
}

/*
 * cetrafs_sync_new_buffer() for several new blocks at once: every write
 * submitted under one plug, then all waited for, each judged as that
 * function judges one (a full thin pool is the operation's ENOSPC, any
 * other failure the mount's). The tree reserve wrote its four blocks
 * one at a time, each waited for -- ~150 ms per convert that needs room
 * on a SAN (F-5). Returns the first error, ENOSPC before any other.
 */
int cetrafs_sync_new_buffers(struct super_block *sb, struct buffer_head **bhs, unsigned int n)
{
    struct cetrafs_new_io io[8];
    DECLARE_COMPLETION_ONSTACK(all);
    atomic_t left;
    struct blk_plug plug;
    unsigned int i;
    int ret = 0, r;

    if (n > ARRAY_SIZE(io) || READ_ONCE(cetrafs_new_block_nospc) || READ_ONCE(cetrafs_meta_write_nospc)) {
        /* larger sets, and the test injections, one at a time */
        for (i = 0; i < n; i++) {
            r = cetrafs_sync_new_buffer(sb, bhs[i]);
            if (r && (!ret || r == -ENOSPC))
                ret = r;
        }
        return ret;
    }
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    atomic_set(&left, n + 1);
    blk_start_plug(&plug);
    for (i = 0; i < n; i++) {
        struct buffer_head *bh = bhs[i];
        struct bio *bio;

        io[i].all = &all;
        io[i].left = &left;
        io[i].status = 0;
        lock_buffer(bh);
        if (cetrafs_meta_gate_shut(sb)) {
            /* not sent: completes as refused, never reaches the device */
            io[i].status = -ESHUTDOWN;
            if (atomic_dec_and_test(&left))
                complete(&all);
            continue;
        }
        clear_buffer_dirty(bh);
        clear_buffer_cetra_held(bh);
        clear_buffer_write_io_error(bh);
        bio = bio_alloc(bh->b_bdev, 1, REQ_OP_WRITE | REQ_SYNC | REQ_META, GFP_NOIO);
        bio->bi_iter.bi_sector = bh->b_blocknr * (bh->b_size >> 9);
        bio_add_folio_nofail(bio, bh->b_folio, bh->b_size, offset_in_folio(bh->b_folio, bh->b_data));
        bio->bi_end_io = cetrafs_new_io_end;
        bio->bi_private = &io[i];
        submit_bio(bio);
    }
    blk_finish_plug(&plug);
    if (!atomic_dec_and_test(&left))
        wait_for_completion_io(&all);
    for (i = 0; i < n; i++) {
        struct buffer_head *bh = bhs[i];

        r = io[i].status;
        if (r) {
            set_buffer_write_io_error(bh);
            clear_buffer_uptodate(bh);
        } else {
            set_buffer_uptodate(bh);
        }
        unlock_buffer(bh);
        if (r == -ENOSPC && !READ_ONCE(cetrafs_nospc_stops)) {
            atomic64_inc(&cetrafs_meta_nospc);
            pr_warn_ratelimited("%s: the device has no space for a new metadata block (%llu): the operation fails "
                                "with ENOSPC -- a thin-provisioned LUN out of space?\n",
                                sb->s_id, (unsigned long long) bh->b_blocknr);
            cetrafs_forget_block(sb, bh->b_blocknr);
        } else {
            r = cetrafs_meta_write_result(sb, bh, r);
        }
        if (r && (!ret || r == -ENOSPC))
            ret = r;
    }
    return ret;
}

int cetrafs_sync_buffer_keep(struct super_block *sb, struct buffer_head *bh)
{
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    return cetrafs_meta_write_result(sb, bh, __cetrafs_sync_buffer_keep(sb, bh));
}

/*
 * cetrafs_sync_buffer_keep() for several blocks: every write sent under
 * one plug, then all waited for; res[i] is each one's verdict. The
 * boundary bitmap flush wrote its blocks one synchronous write at a time
 * under the node's flush mutex -- ~38 ms a block on a SAN, minutes for
 * a large preallocation, every fsync and close of the node queued behind
 * it (audit 2026-11-15 B-29, M-8). Returns the first error.
 *
 * Each write's status is its own, carried by its bio, and the buffer
 * stays LOCKED from submit until its verdict is applied. The buffer's
 * BH_Write_EIO is shared: another bitmap writer locking the buffer
 * between the completion and our look would take the error as its own
 * and clear it, and this flush then called a write that failed a
 * success -- and its caller published extents over bits that never
 * reached the device (audit 2026-11-15 F-19).
 */
struct cetrafs_keep_bio {
    struct completion *all;
    atomic_t *left;
    int status;
};

static void cetrafs_keep_bio_end(struct bio *bio)
{
    struct cetrafs_keep_bio *io = bio->bi_private;

    io->status = blk_status_to_errno(bio->bi_status);
    bio_put(bio);
    if (atomic_dec_and_test(io->left))
        complete(io->all);
}

/* TEST ONLY: the next N batched keep-writes fail, as the device would
 * refuse them (tests/kernel/bmap_flush_batched.sh, F-19). */
static unsigned int cetrafs_keep_batch_fail;
cetrafs_test_param(keep_batch_fail, cetrafs_keep_batch_fail, uint, 0644);
MODULE_PARM_DESC(keep_batch_fail, "TEST ONLY: the next N batched bitmap writes fail");

/*
 * TEST ONLY: the batch as b1ad118 wrote it -- each write's error kept only
 * in the buffer's shared BH_Write_EIO, read after the whole batch -- and
 * a second knob that clears that flag between the completions and the
 * look, as another keep-writer taking the buffer lock there does
 * (tests/kernel/bmap_flush_batched.sh's F-19 control).
 */
static bool cetrafs_keep_batch_legacy;
cetrafs_test_param(keep_batch_legacy, cetrafs_keep_batch_legacy, bool, 0644);
MODULE_PARM_DESC(keep_batch_legacy, "TEST ONLY: batched bitmap writes judged by the shared buffer flag (F-19)");
static bool cetrafs_keep_flag_steal;
cetrafs_test_param(keep_flag_steal, cetrafs_keep_flag_steal, bool, 0644);
MODULE_PARM_DESC(keep_flag_steal, "TEST ONLY: with keep_batch_legacy, another writer clears the error flag first");

static int cetrafs_sync_buffers_keep_legacy(struct super_block *sb, struct buffer_head **bhs, unsigned int n,
                                            int *res)
{
    struct blk_plug plug;
    unsigned int i;
    int ret = 0, r;
    int *st = kmalloc_array(n, sizeof(*st), GFP_NOFS);
    bool *wd = kmalloc_array(n, sizeof(*wd), GFP_NOFS), *wh = kmalloc_array(n, sizeof(*wh), GFP_NOFS);

    if (!st || !wd || !wh) {
        kfree(st);
        kfree(wd);
        kfree(wh);
        return -ENOMEM;
    }
    blk_start_plug(&plug);
    for (i = 0; i < n; i++)
        st[i] = __cetrafs_keep_submit(sb, bhs[i], &wd[i], &wh[i]);
    blk_finish_plug(&plug);
    for (i = 0; i < n; i++) {
        if (st[i] != 1)
            continue;
        wait_on_buffer(bhs[i]);
        if (READ_ONCE(cetrafs_keep_batch_fail)) {
            WRITE_ONCE(cetrafs_keep_batch_fail, cetrafs_keep_batch_fail - 1);
            set_buffer_write_io_error(bhs[i]); /* as the completion records a failure */
        }
        if (READ_ONCE(cetrafs_keep_flag_steal))
            clear_buffer_write_io_error(bhs[i]); /* another party took it */
    }
    for (i = 0; i < n; i++) {
        r = st[i] == 1 ? __cetrafs_keep_wait(bhs[i], wd[i], wh[i]) : st[i];
        res[i] = cetrafs_meta_write_result(sb, bhs[i], r);
        if (res[i] && !ret)
            ret = res[i];
    }
    kfree(st);
    kfree(wd);
    kfree(wh);
    return ret;
}

int cetrafs_sync_buffers_keep(struct super_block *sb, struct buffer_head **bhs, unsigned int n, int *res)
{
    struct cetrafs_keep_io {
        struct cetrafs_keep_bio b;
        int state; /* 1 sent, 0 nothing to write, < 0 an earlier failure found */
        bool was_dirty, was_held;
    } *io;
    DECLARE_COMPLETION_ONSTACK(all);
    atomic_t left;
    struct blk_plug plug;
    unsigned int i;
    int ret = 0, r;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    if (READ_ONCE(cetrafs_keep_batch_legacy))
        return cetrafs_sync_buffers_keep_legacy(sb, bhs, n, res);
    io = kmalloc_array(n, sizeof(*io), GFP_NOFS);
    if (!io) {
        for (i = 0; i < n; i++) {
            res[i] = cetrafs_sync_buffer_keep(sb, bhs[i]);
            if (res[i] && !ret)
                ret = res[i];
        }
        return ret;
    }
    atomic_set(&left, 1);
    blk_start_plug(&plug);
    for (i = 0; i < n; i++) {
        struct buffer_head *bh = bhs[i];
        struct bio *bio;

        io[i].b.all = &all;
        io[i].b.left = &left;
        io[i].b.status = 0;
        lock_buffer(bh); /* also waits out a writeback already in flight */
        if (cetrafs_meta_gate_shut(sb)) {
            unlock_buffer(bh);
            io[i].state = -ESHUTDOWN;
            continue;
        }
        if (buffer_write_io_error(bh)) {
            /* an earlier write of these bytes failed: put them back */
            clear_buffer_write_io_error(bh);
            set_buffer_uptodate(bh);
            unlock_buffer(bh);
            mark_buffer_dirty(bh);
            io[i].state = -EIO;
            continue;
        }
        io[i].was_dirty = test_clear_buffer_dirty(bh);
        io[i].was_held = test_clear_buffer_cetra_held(bh);
        if (!io[i].was_dirty && !io[i].was_held) {
            unlock_buffer(bh);
            io[i].state = 0;
            continue;
        }
        io[i].state = 1;
        if (READ_ONCE(cetrafs_keep_batch_fail)) {
            WRITE_ONCE(cetrafs_keep_batch_fail, cetrafs_keep_batch_fail - 1);
            io[i].b.status = -EIO; /* TEST ONLY: refused, unsent */
            continue;
        }
        atomic_inc(&left);
        bio = bio_alloc(bh->b_bdev, 1, REQ_OP_WRITE | REQ_SYNC | REQ_META, GFP_NOIO);
        bio->bi_iter.bi_sector = bh->b_blocknr * (bh->b_size >> 9);
        bio_add_folio_nofail(bio, bh->b_folio, bh->b_size, offset_in_folio(bh->b_folio, bh->b_data));
        bio->bi_end_io = cetrafs_keep_bio_end;
        bio->bi_private = &io[i].b;
        submit_bio(bio);
    }
    blk_finish_plug(&plug);
    if (!atomic_dec_and_test(&left))
        wait_for_completion_io(&all);
    for (i = 0; i < n; i++) {
        struct buffer_head *bh = bhs[i];

        r = io[i].state;
        if (r == 1) {
            /* still locked: the verdict is applied before anyone else
             * can look at the buffer */
            r = io[i].b.status;
            if (r) {
                /* still uptodate: the next boundary retries it -- held
                 * again if it was held, never handed to writeback (A-15) */
                if (io[i].was_held && !io[i].was_dirty)
                    set_buffer_cetra_held(bh);
                else
                    mark_buffer_dirty(bh);
                r = -EIO;
            }
            unlock_buffer(bh);
        }
        res[i] = cetrafs_meta_write_result(sb, bh, r);
        if (res[i] && !ret)
            ret = res[i];
    }
    kfree(io);
    return ret;
}

/*
 * End an update WITHOUT dirtying the buffer: the edit is held back for
 * the next boundary (leafdefer.c), which writes it through the journal.
 * The first time, the buffer is pinned and marked; the caller has listed
 * it already. Writeback never sees it.
 */
void cetrafs_bh_end_update_deferred(struct buffer_head *bh)
{
    if (!buffer_cetra_deferred(bh)) {
        get_bh(bh); /* the pin, dropped when the block is unlisted */
        set_buffer_cetra_deferred(bh);
    }
    unlock_buffer(bh);
}

/*
 * A held-back block's bit and its listing change together, under the
 * buffer lock every update holds: an update that finds the bit can then
 * trust it is listed (leafdefer review 2026-11-08, item 1). These are the two ways a
 * listing ends.
 *
 * Unlist: the block was freed, or the mount stopped ('drop' also forgets
 * the cached image), or a single journal write wrote it. The caller holds
 * its own reference.
 */
void cetrafs_bh_deferred_unlist(struct super_block *sb, struct buffer_head *bh, bool drop)
{
    lock_buffer(bh);
    cetrafs_deferred_unlist_locked(sb, bh, drop);
    unlock_buffer(bh);
}

/* Settle: a boundary wrote the image whose checksum is 'written_crc'.
 * Unlisted if that is still the image in core; an edit made since stays
 * listed, against the image now on the device. */
void cetrafs_bh_deferred_settle(struct super_block *sb, struct buffer_head *bh, u32 written_crc)
{
    lock_buffer(bh);
    cetrafs_deferred_settle_locked(sb, bh, written_crc);
    unlock_buffer(bh);
}

/*
 * Write a held-back extent-tree block (leafdefer.c) in place -- but only
 * while it is still held back. The check and the submit are under one
 * buffer lock, and so is a free's drop (cetrafs_deferred_forget_range()),
 * so a block freed meanwhile -- an inode evicted while sync_fs flushes
 * its blocks -- is never written over its next owner. On failure the
 * cached image stays uptodate: it is the only copy of the edit.
 * 1: no longer held back, nothing written.
 */
/* The two halves of cetrafs_write_deferred_target(), so a batch can
 * have every target in flight at once: submit returns 1 (no longer held
 * back, nothing submitted), 0 (submitted: wait for it) or an error. */
int cetrafs_submit_deferred_target(struct super_block *sb, struct buffer_head *bh, u32 *wcrc)
{
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    lock_buffer(bh);
    if (cetrafs_meta_gate_shut(sb)) {
        unlock_buffer(bh);
        return -EIO; /* not sent: the fence's sweep discards it */
    }
    if (!buffer_cetra_deferred(bh)) {
        unlock_buffer(bh);
        return 1;
    }
    cetrafs_blk_tail_settle(bh); /* what reaches the device carries its CRC */
    *wcrc = ~crc32c(~0U, bh->b_data, CETRAFS_BLOCK_SIZE);
    clear_buffer_write_io_error(bh);
    clear_buffer_dirty(bh);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
    bh_submit(bh, REQ_OP_WRITE | REQ_SYNC, cetrafs_end_write_keep);
#else
    get_bh(bh);
    bh->b_end_io = cetrafs_end_write_keep;
    submit_bh(REQ_OP_WRITE | REQ_SYNC, bh);
#endif
    return 0;
}

int cetrafs_wait_deferred_target(struct super_block *sb, struct buffer_head *bh)
{
    wait_on_buffer(bh);
    if (buffer_write_io_error(bh)) {
        clear_buffer_write_io_error(bh);
        return cetrafs_meta_write_result(sb, bh, -EIO);
    }
    return cetrafs_meta_write_result(sb, bh, 0);
}

int cetrafs_write_deferred_target(struct super_block *sb, struct buffer_head *bh, u32 *wcrc)
{
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    lock_buffer(bh);
    if (cetrafs_meta_gate_shut(sb)) {
        unlock_buffer(bh);
        return -EIO; /* not sent: the fence's sweep discards it */
    }
    if (!buffer_cetra_deferred(bh)) {
        unlock_buffer(bh);
        return 1;
    }
    cetrafs_blk_tail_settle(bh); /* what reaches the device carries its CRC */
    /* What this write puts on the device: the settle afterwards compares
     * the image in core with it, under the same lock. */
    *wcrc = ~crc32c(~0U, bh->b_data, CETRAFS_BLOCK_SIZE);
    clear_buffer_write_io_error(bh);
    clear_buffer_dirty(bh);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 2, 0)
    bh_submit(bh, REQ_OP_WRITE | REQ_SYNC, cetrafs_end_write_keep);
#else
    get_bh(bh);
    bh->b_end_io = cetrafs_end_write_keep;
    submit_bh(REQ_OP_WRITE | REQ_SYNC, bh);
#endif
    wait_on_buffer(bh);
    if (buffer_write_io_error(bh)) {
        clear_buffer_write_io_error(bh);
        return cetrafs_meta_write_result(sb, bh, -EIO);
    }
    return cetrafs_meta_write_result(sb, bh, 0);
}

/*
 * Copy bytes out of a buffer a writer may be modifying RIGHT NOW under
 * the update protocol above. An unlocked memcpy can copy mid-
 * modification: a torn in-memory view that fails its checksum even
 * though the device and the writer are both fine. Readers that verify
 * a checksum over what they copy must copy under the same lock the
 * writers hold.
 */
void cetrafs_bh_copy_stable(struct buffer_head *bh, void *out, size_t len)
{
    cetrafs_bh_copy_stable_at(bh, 0, out, len);
}

/* The batch's payload copy of a held-back block: stamped first, so the
 * journal's image and the target write carry the same, valid tail. */
void cetrafs_bh_copy_settled(struct buffer_head *bh, void *out)
{
    lock_buffer(bh);
    cetrafs_blk_tail_settle(bh);
    memcpy(out, bh->b_data, CETRAFS_BLOCK_SIZE);
    unlock_buffer(bh);
}

/* The same, from an offset into the block: the CAS layer copies and
 * compares one record's region, and cetrafs_cache_region_after_cas()
 * patches exactly those bytes under the buffer lock -- a local CAS on the
 * same record could otherwise tear another's compare image into a false
 * checksum failure, recorded as damage (audit 2026-11-06 M13). */
void cetrafs_bh_copy_stable_at(struct buffer_head *bh, unsigned int off, void *out, size_t len)
{
    lock_buffer(bh);
    memcpy(out, bh->b_data + off, len);
    unlock_buffer(bh);
}

int cetrafs_bh_memcmp_stable_at(struct buffer_head *bh, unsigned int off, const void *buf, size_t len)
{
    int r;

    lock_buffer(bh);
    r = memcmp(bh->b_data + off, buf, len);
    unlock_buffer(bh);
    return r;
}

/*
 * Run a read-only test over a buffer's bytes under the buffer lock, for
 * a reader that must not see a writer's half-edited image -- and must
 * not CLAIM the buffer to get that guarantee: a claim released with
 * cetrafs_bh_abort_update() drops a clean buffer's cached image, which
 * on a lookup path means a device re-read every time (file.c's
 * cetrafs_leaf_bh_holds_uninit()).
 */
bool cetrafs_bh_test_stable(struct buffer_head *bh, bool (*test)(const void *data, void *arg), void *arg)
{
    bool r;

    lock_buffer(bh);
    r = test(bh->b_data, arg);
    unlock_buffer(bh);
    return r;
}

/* Release a buffer claimed by cetrafs_bh_begin_update() WITHOUT
 * publishing it: for a path that claimed the block and then decided it
 * had nothing to write after all, or that is about to free the block
 * outright. Every begin must reach exactly one of end/abort on every
 * path -- a buffer left locked wedges every later access to it. */
void cetrafs_bh_abort_update(struct buffer_head *bh)
{
    /* Nothing was published, so drop the uptodate claim -- unless the
     * buffer holds a pending write, where clearing it would discard a
     * write that has not reached the device yet.
     *
     * This matters for a buffer claimed by cetrafs_getblk_overwrite():
     * that one was never read, so its contents are whatever memory the
     * buffer came with, and begin_update has already declared them
     * uptodate. Leaving that behind would let the next CACHED read hand
     * out uninitialised memory as the block's real image. For a buffer
     * that really was read the clear is merely a wasted re-read on the
     * next access, and these are rare error paths. */
    if (!cetrafs_bh_pending(bh))
        clear_buffer_uptodate(bh);
    unlock_buffer(bh);
}

/*
 * Claim a block for a write that replaces ALL CETRAFS_BLOCK_SIZE bytes
 * of it.
 *
 * sb_bread() would fetch the old contents first -- a full device round
 * trip to read bytes the very next statement destroys. On a loop device
 * that is free, which is why it went unnoticed; on the shared LUN this
 * filesystem is for it is ~5 ms, and the journal pays it three times per
 * journaled block (payload, header, consume).
 *
 * sb_getblk() allocates the buffer without reading it, and
 * cetrafs_bh_begin_update() marks it uptodate -- honest only because the
 * caller overwrites every byte before cetrafs_bh_end_update(sb, ) publishes
 * it. Returns the buffer LOCKED: exactly one of cetrafs_bh_end_update(sb, )
 * / cetrafs_bh_abort_update() must follow on every path, as for
 * begin_update itself.
 *
 * ONLY for a complete overwrite. A partial update must read the block
 * first, or it publishes uninitialised memory as the untouched bytes.
 */
struct buffer_head *cetrafs_getblk_overwrite(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh = sb_getblk(sb, block);

    if (!bh)
        return NULL;

    cetrafs_bh_begin_update(bh);
    return bh;
}

/*
 * Patch a region of a cached block with content we KNOW is now on the
 * device, instead of dropping the cached copy.
 *
 * A successful compare-and-swap goes straight to the device behind the
 * buffer cache, so the cached copy has to stop being trusted -- but
 * invalidating it throws away a block that is about to be read again
 * (the record a namespace operation just updated is the record the next
 * lookup reads), turning each swap into a later device read. We know
 * the exact bytes the device now holds, so write them into the cached
 * buffer and leave it CLEAN: coherent, and still warm.
 *
 * Any uptodate buffer is patched, dirty or not. A dirty one holds a
 * write that has not reached the device; the swap was computed against
 * the device without it, so for THIS region the swap's bytes are the
 * newer truth, and the rest of the block keeps its pending write. What
 * must not happen is the old fallback, which cleared uptodate on a
 * dirty buffer: "dirty implies uptodate" is what every forced-fresh
 * read relies on to leave a pending write alone (cetrafs_bread_uncached
 * above), and without it the next read fetched the device over the
 * pending write and the write-back then put the old bytes back. A
 * buffer that is not uptodate has nothing stale to correct.
 */
/* TEST ONLY: a one-shot stall, held halfway through the next in-place patch
 * of a Zone Group table block. It is consumed (set back to 0) by that patch
 * and holds the buffer lock across the stall, so a reader that copies the
 * record without the lock sees the half-applied image. */
static unsigned int cetrafs_zg_patch_stall_ms;
cetrafs_test_param(zg_patch_stall_ms, cetrafs_zg_patch_stall_ms, uint, 0644);
MODULE_PARM_DESC(zg_patch_stall_ms, "TEST ONLY: stall halfway through the next in-place patch of a ZG table block");

static bool cetrafs_is_zg_table_block(struct super_block *sb, sector_t block)
{
    const cetrafs_superblock_t *raw = cetrafs_sb_raw(sb);
    u64 start;

    if (!raw)
        return false;
    start = le64_to_cpu(raw->zg_table_start);
    return block >= start && block < start + le32_to_cpu(raw->zone_group_count);
}

void cetrafs_cache_region_after_cas(struct super_block *sb, sector_t block, unsigned int off, const void *src,
                                    unsigned int len)
{
    struct buffer_head *bh;

    if (off + len > CETRAFS_BLOCK_SIZE)
        return;

    bh = sb_getblk(sb, block);
    if (!bh)
        return;

    lock_buffer(bh);
    if (buffer_uptodate(bh)) {
        unsigned int stall = 0;

        if (READ_ONCE(cetrafs_zg_patch_stall_ms) && cetrafs_is_zg_table_block(sb, block))
            stall = xchg(&cetrafs_zg_patch_stall_ms, 0);
        if (stall) {
            /* Split inside the bytes this patch changes, so that the
             * half-applied image differs from both the old and the new
             * one: between the first and the last differing byte. */
            u8 *dst = bh->b_data + off;
            const u8 *nw = src;
            unsigned int first = 0, last = len, split;

            while (first < len && dst[first] == nw[first])
                first++;
            while (last > first && dst[last - 1] == nw[last - 1])
                last--;
            split = first >= last ? len / 2 : first + (last - first) / 2;
            memcpy(dst, nw, split);
            msleep(stall);
            memcpy(dst + split, nw + split, len - split);
        } else {
            memcpy(bh->b_data + off, src, len);
        }
    }
    unlock_buffer(bh);
    brelse(bh);
}

/*
 * Drop a clean cached copy of 'block', if any, so the next read is forced
 * to go back to the device -- the complement to cetrafs_bread_uncached()
 * above, used when a caller knows a *specific* block's ownership just
 * changed hands (a Zone Group or inode just claimed/reclaimed) rather
 * than needing every read of it to always bypass the cache. Same
 * dirty-buffer safety as cetrafs_bread_uncached(): never discard a
 * pending unflushed write. Lazy -- doesn't perform any I/O itself, just
 * clears the uptodate bit so whoever next actually reads this block pays
 * for a real fetch.
 */
void cetrafs_invalidate_block(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh = sb_find_get_block(sb, block);

    if (!bh)
        return;

    lock_buffer(bh);
    if (buffer_uptodate(bh) && !cetrafs_bh_pending(bh))
        clear_buffer_uptodate(bh);
    unlock_buffer(bh);

    brelse(bh);
}

/*
 * A block is about to be FREED: drop this node's cached copy of it,
 * dirty or not. cetrafs_invalidate_block() above deliberately leaves a
 * dirty buffer alone -- right for a block we still own, whose pending
 * write is the newest content -- and exactly wrong for one we are
 * giving away: that pending write would land after the next owner's.
 * Taking the buffer lock waits out a write already in flight, which
 * lands while the block is still ours and is harmless.
 */
/*
 * Self-fence: discard every dirty metadata buffer this node holds, without
 * writing it.
 *
 * Fenced means a peer has declared this node dead and taken its Zone
 * Groups, locks and journal; from then on every image this node had
 * dirtied -- allocation bitmaps set with sync=false, tree blocks waiting
 * for a boundary -- is a write aimed at blocks somebody else now owns.
 * The entry points refuse new writes and writepages refuses file data,
 * but what was already dirty in the block device's cache went out with
 * ordinary writeback, over the new owner's bitmap
 * (tests/kernel/fence_drops_dirty_metadata.sh).
 *
 * Only the dirty state goes: buffers stay mapped and uptodate, because
 * this node still holds references to some of them and a cleared mapping
 * under a later submit_bh() is a BUG. Takes the folio lock, then each
 * buffer's lock (the order writeback uses); a write already in flight is
 * waited out -- it was issued before the fence was noticed, the window
 * the fence has always had. Call from process context with nothing held
 * (the heartbeat).
 */
unsigned long cetrafs_drop_dirty_metadata(struct super_block *sb)
{
    struct address_space *mapping = sb->s_bdev->bd_mapping;
    struct folio_batch fbatch;
    unsigned long dropped = 0;
    pgoff_t index = 0;
    unsigned int nr, i;

    folio_batch_init(&fbatch);
    while ((nr = filemap_get_folios_tag(mapping, &index, (pgoff_t) -1, PAGECACHE_TAG_DIRTY, &fbatch))) {
        for (i = 0; i < nr; i++) {
            struct folio *folio = fbatch.folios[i];
            struct buffer_head *head, *bh;

            folio_lock(folio);
            if (folio->mapping != mapping) {
                folio_unlock(folio);
                continue;
            }
            folio_wait_writeback(folio);
            head = folio_buffers(folio);
            if (head) {
                bh = head;
                do {
                    lock_buffer(bh);
                    if (test_clear_buffer_dirty(bh))
                        dropped++;
                    unlock_buffer(bh);
                    bh = bh->b_this_page;
                } while (bh != head);
            }
            folio_cancel_dirty(folio);
            folio_unlock(folio);
        }
        folio_batch_release(&fbatch);
        cond_resched();
    }
    return dropped;
}

void cetrafs_forget_block(struct super_block *sb, sector_t block)
{
    struct buffer_head *bh = sb_find_get_block(sb, block);

    if (!bh)
        return;

    lock_buffer(bh);
    clear_buffer_dirty(bh);
    clear_buffer_cetra_held(bh); /* unlisted by the next held flush or drop */
    clear_buffer_uptodate(bh);
    /* The caller has handled the write that failed: a BH_Write_EIO left
     * behind is reported again by the next sync of this block -- the
     * held flush still lists it -- and that stopped the mount a tick
     * after a refused replay redo had been survived. */
    clear_buffer_write_io_error(bh);
    unlock_buffer(bh);

    brelse(bh);
}

/*
 * The {magic, crc} tail that whole-block structures carry so a lock-free
 * reader can tell a torn concurrent write from real corruption
 * (format v0x000F).
 *
 * Generic because three structures need exactly the same thing and only
 * the magic differs: dirent blocks (which have their own implementation
 * in dir.c predating this), extent-leaf blocks and xattr blocks. Each magic is
 * distinct so a block of the wrong KIND is caught rather than parsed as
 * though it were the right one.
 *
 * A record does NOT need this: it lives wholly inside one 512-byte
 * logical sector and cannot tear. These span all eight
 * sectors of their block, so they can.
 */
/* TEST ONLY: leave an extent block's eh_generation as it is (the
 * control for tests/kernel/journal_redo_leaf_aba.sh). */
/* TEST ONLY: stamp every held-back edit's tail CRC at once, as before
 * P9 -- the control of tests/kernel/deferred_tail_lazy.sh. */
static bool cetrafs_tail_eager;
cetrafs_test_param(deferred_tail_eager, cetrafs_tail_eager, bool, 0644);
MODULE_PARM_DESC(deferred_tail_eager, "TEST ONLY: stamp a held-back tree block's tail CRC on every edit");

/* Edits of a held-back block whose tail CRC was left for the boundary. */
static atomic64_t cetrafs_tail_lazy = ATOMIC64_INIT(0);

u64 cetrafs_tail_lazy_count(void)
{
    return (u64) atomic64_read(&cetrafs_tail_lazy);
}

static bool cetrafs_ext_gen_stamp_off;
cetrafs_test_param(ext_gen_stamp_off, cetrafs_ext_gen_stamp_off, bool, 0644);
MODULE_PARM_DESC(ext_gen_stamp_off, "TEST ONLY: do not stamp a new eh_generation on each extent-block write");

void cetrafs_blk_tail_stamp(struct buffer_head *bh, u32 magic)
{
    cetrafs_blk_tail_t *tail = (cetrafs_blk_tail_t *) (bh->b_data + CETRAFS_BLK_TAIL_OFF);

    /*
     * An extent leaf or index block carries a fresh eh_generation every
     * time it is written, so its bytes never recur. Journal redo decides
     * "the target write never landed" by the target's CRC alone
     * (cetrafs_journal_judge()), and a tree rebuild writes a byte-
     * identical block elsewhere whenever the entries come out the same:
     * a leaf rebuilt into a block a dead node's entry still names read
     * as that entry's "before" image, and the redo put the dead node's
     * leaf over the live one -- an extent over blocks the survivor had
     * freed (audit 2026-11-11 J1). Random, not a counter: nothing to
     * persist, and no sequence a restart or a peer replays.
     */
    if ((magic == CETRAFS_LEAF_TAIL_MAGIC || magic == CETRAFS_INDEX_TAIL_MAGIC) && !READ_ONCE(cetrafs_ext_gen_stamp_off))
        ((cetrafs_extent_hdr_t *) bh->b_data)->eh_generation = cetrafs_cpu_to_le32(get_random_u32());

    tail->magic = cetrafs_cpu_to_le32(magic);
    /* A block already held back is not written until a boundary, and
     * every path that takes its image out of memory -- the batch's
     * payload copy, the target write, a single journal write, the end of
     * the hold -- stamps it first (cetrafs_blk_tail_settle()). So its CRC
     * waits for that, once, instead of costing a 4 KiB CRC per edit (audit
     * 2026-11-14 P9). The generation above still moves on every edit, and
     * is what the tree's cache identity tells edits apart by. */
    if (buffer_cetra_deferred(bh) && !READ_ONCE(cetrafs_tail_eager)) {
        set_buffer_cetra_tail_stale(bh);
        atomic64_inc(&cetrafs_tail_lazy);
        return;
    }
    clear_buffer_cetra_tail_stale(bh);
    atomic64_inc(&cetrafs_update_crcs);
    tail->crc = cetrafs_cpu_to_le32(~crc32c(~0U, bh->b_data, CETRAFS_BLK_TAIL_OFF));
}

/* Stamp a held-back block's tail if an edit left it stale. Under the
 * buffer lock; a no-op for a block whose tail is current. */
void cetrafs_blk_tail_settle(struct buffer_head *bh)
{
    cetrafs_blk_tail_t *tail = (cetrafs_blk_tail_t *) (bh->b_data + CETRAFS_BLK_TAIL_OFF);

    if (!test_clear_buffer_cetra_tail_stale(bh))
        return;
    atomic64_inc(&cetrafs_update_crcs);
    tail->crc = cetrafs_cpu_to_le32(~crc32c(~0U, bh->b_data, CETRAFS_BLK_TAIL_OFF));
}

/*
 * Structure sanity, which is NOT what the checksum proves.
 *
 * A CRC says the bytes are the ones that were written. It says nothing
 * about whether they make sense, and every field below was trusted the
 * moment the CRC passed: a dirent's name_len went straight to
 * dir_emit(), an xattr's value_len straight to a memcpy() aimed at
 * userspace, an extent header's entry count straight into an array
 * index. A peer running older or broken code, a crafted image, or a
 * flipped bit inside a correctly restamped block all produce exactly
 * that -- hostile values behind a valid checksum.
 *
 * Checked where the block is READ rather than at each use, because
 * eh_entries alone has 69 use sites and a rule that every one of them
 * must remember is a rule one of them will forget.
 *
 * Cost: for an extent leaf or index this is ONE comparison, because
 * that read is on the per-block mapping path and anything proportional
 * to the entry count would land in cetrafs_get_block()'s budget
 * (docs/PERFORMANCE.md). Dirent and xattr blocks are read by namespace
 * and xattr operations only, never per block of data, so there the scan
 * over the entries is affordable and is done.
 */
bool cetrafs_blk_struct_ok_magic(const struct buffer_head *bh, u32 magic)
{
    /* The rules live in cetrafs.h, shared with fsck. */
    return cetrafs_blk_struct_ok(bh->b_data, magic);
}

/* The same test over a private copy of a block: what a reader that
 * copied the buffer must re-check, since the buffer it validated can be
 * re-read under it before the copy is taken. */
bool cetrafs_blk_image_valid(const void *img, u32 magic)
{
    const cetrafs_blk_tail_t *tail = (const cetrafs_blk_tail_t *) ((const u8 *) img + CETRAFS_BLK_TAIL_OFF);

    if (cetrafs_le32(tail->magic) != magic)
        return false;
    if (cetrafs_le32(tail->crc) != ~crc32c(~0U, img, CETRAFS_BLK_TAIL_OFF))
        return false;
    /* Integrity first, then sense. Both failures take the same route --
     * retry fresh, then -EUCLEAN -- because a lockless reader can catch
     * a writer mid-update and see either. */
    return cetrafs_blk_struct_ok(img, magic);
}

bool cetrafs_blk_tail_valid(const struct buffer_head *bh, u32 magic)
{
    /* A held-back block with a stale tail is this node's own edit, still
     * in memory (an uncached read returns a held buffer as it is): its
     * CRC is stamped when it leaves memory. Its structure is checked as
     * any block's is. */
    if (buffer_cetra_tail_stale(bh)) {
        const cetrafs_blk_tail_t *tail = (const cetrafs_blk_tail_t *) (bh->b_data + CETRAFS_BLK_TAIL_OFF);

        return cetrafs_le32(tail->magic) == magic && cetrafs_blk_struct_ok(bh->b_data, magic);
    }
    return cetrafs_blk_image_valid(bh->b_data, magic);
}

/* The test cetrafs_blk_tail_bread() applies to a fresh read, for a caller
 * that batches its own reads (the tree walk's batch, file.c). */
bool cetrafs_blk_read_accepts(const struct buffer_head *bh, u32 magic)
{
    return !cetrafs_tear_injected() && cetrafs_blk_tail_valid(bh, magic);
}

/*
 * Forced-fresh read of a tail-checksummed block, retrying a mismatch.
 *
 * A mismatch is usually NOT corruption: it is a peer's in-flight 4 KiB
 * write seen torn, which converges as soon as that write completes. So
 * back off and re-read, with a budget measured in the time a peer's
 * write takes (milliseconds on a real LUN) rather than in microseconds
 * -- P5's rule, learned when three readers spent a five-attempt budget
 * in a few microseconds against a write that takes milliseconds.
 */
/* TEST ONLY: for this many ms after it is set, every tail-checksummed
 * image read reads torn -- a peer's write that takes that long to land. */
static unsigned int cetrafs_tail_tear_ms;
static unsigned long cetrafs_tail_tear_until;
static int cetrafs_tail_tear_set(const char *val, const struct kernel_param *kp)
{
    int ret = param_set_uint(val, kp);

    if (!ret)
        WRITE_ONCE(cetrafs_tail_tear_until, jiffies + msecs_to_jiffies(cetrafs_tail_tear_ms));
    return ret;
}
static const struct kernel_param_ops cetrafs_tail_tear_ops = {.set = cetrafs_tail_tear_set, .get = param_get_uint};
module_param_cb(tail_tear_ms, &cetrafs_tail_tear_ops, &cetrafs_tail_tear_ms, 0644);
MODULE_PARM_DESC(tail_tear_ms, "TEST ONLY: every tail-checksummed read reads torn for this many ms from now");

bool cetrafs_tear_injected(void)
{
    return READ_ONCE(cetrafs_tail_tear_ms) && time_before(jiffies, READ_ONCE(cetrafs_tail_tear_until));
}

/* TEST ONLY: the same for the checksummed RECORD readers -- inode record,
 * node row, ZG record, BG descriptor (tests/kernel/record_tear_converges.sh). */
static unsigned int cetrafs_record_tear_ms;
static unsigned long cetrafs_record_tear_until;
static int cetrafs_record_tear_set(const char *val, const struct kernel_param *kp)
{
    int ret = param_set_uint(val, kp);

    if (!ret)
        WRITE_ONCE(cetrafs_record_tear_until, jiffies + msecs_to_jiffies(cetrafs_record_tear_ms));
    return ret;
}
static const struct kernel_param_ops cetrafs_record_tear_ops = {.set = cetrafs_record_tear_set, .get = param_get_uint};
module_param_cb(record_tear_ms, &cetrafs_record_tear_ops, &cetrafs_record_tear_ms, 0644);
MODULE_PARM_DESC(record_tear_ms, "TEST ONLY: every checksummed record read reads torn for this many ms from now");

/* 'what' names the reader in the log: the test's proof that its
 * operation reached the reader it is about. Not ratelimited -- a
 * suppressed line would read as "never reached"; the window bounds it. */
bool cetrafs_record_tear_injected(const char *what)
{
    if (likely(!READ_ONCE(cetrafs_record_tear_ms)) || !time_before(jiffies, READ_ONCE(cetrafs_record_tear_until)))
        return false;
    pr_info("record_tear_ms: tore a %s read\n", what);
    return true;
}

void cetrafs_tear_backoff(int attempt)
{
    msleep(1U << min(attempt, 7));
}

struct buffer_head *cetrafs_blk_tail_bread(struct super_block *sb, u64 lba, u32 magic, const char *what)
{
    int attempt, nbad = 0, chk;

    /* Every block read here -- extent leaf, interior index, xattr -- is
     * reached through an address read off the device, and the xattr and
     * leaf writers journal and write back what they read. The tree
     * readers checked theirs before calling (inode.c); an inode's
     * xattr_block went straight here unchecked (rule 19's asymmetry), so
     * the one check now sits where all of them pass. */
    chk = cetrafs_lba_run_check(sb, lba, 1);
    if (chk == -EAGAIN)
        return NULL; /* past a layout this node cannot catch up with: refused, not damage */
    if (chk) {
        pr_err_ratelimited("%s block %llu is not a data address -- refusing it (fsck)\n", what,
                           (unsigned long long) lba);
        cetrafs_sb_corrupt(sb, 0);
        return NULL;
    }

    for (attempt = 0; attempt < CETRAFS_BLK_TAIL_READ_RETRIES; attempt++) {
        struct buffer_head *bh = cetrafs_bread_uncached(sb, lba);

        if (bh) {
            if (!cetrafs_tear_injected() && cetrafs_blk_tail_valid(bh, magic))
                return bh;
            brelse(bh);
            nbad++;
        }
        if (attempt + 1 < CETRAFS_BLK_TAIL_READ_RETRIES)
            cetrafs_tear_backoff(attempt);
    }

    /* Corrupt only if every attempt READ the block and every one failed
     * its checks. A read that failed is the device's error, not the
     * block's: counting it made a transient path error "run fsck" and,
     * under corruption=stop, a stopped mount (ERRORS.md kind 1). */
    if (nbad < CETRAFS_BLK_TAIL_READ_RETRIES) {
        pr_err_ratelimited("%s block %llu could not be read (%d of %d attempts failed) -- I/O error\n", what,
                           (unsigned long long) lba, CETRAFS_BLK_TAIL_READ_RETRIES - nbad,
                           CETRAFS_BLK_TAIL_READ_RETRIES);
        return NULL;
    }
    pr_err("%s block %llu failed its tail checksum %d times -- corrupted, not just a torn concurrent read\n", what,
           (unsigned long long) lba, CETRAFS_BLK_TAIL_READ_RETRIES);
    cetrafs_sb_corrupt(sb, 0);
    /* And do not leave it behind. The last attempt's buffer is still
     * cached and uptodate, and a reader that trusts its cache takes an
     * uptodate block as already verified -- so the read that this call
     * just refused would be served, unchecked, by the next one. */
    cetrafs_invalidate_block(sb, lba);
    return NULL;
}

/*
 * TEST ONLY: the publish-point cache flushes below become no-ops (the
 * pre-fix behaviour). tests/kernel/publish_flushes_cache.sh.
 */
static bool cetrafs_publish_flush_skip;
cetrafs_test_param(publish_flush_skip, cetrafs_publish_flush_skip, bool, 0644);
MODULE_PARM_DESC(publish_flush_skip, "TEST ONLY: skip the device cache flush at publish points");

/*
 * Make every write that has COMPLETED so far durable: a cache flush.
 *
 * Completed is not durable. On a volatile write cache -- and a
 * deployment LUN may well be write-back -- two writes that completed in
 * order can survive a power cut in either order, or one without the
 * other. Every publish is an ordering claim of that kind: the record
 * names blocks whose data, leaves and bitmap bits were written first
 * (rule 8), and a free that follows a publish relies on the publish
 * having reached the device (rule 21). Both halves need a flush between
 * them, not a completion. On a device without a volatile cache the block
 * layer completes the flush at once.
 */
/* TEST ONLY: every publish-point flush sleeps this long first, as a slow
 * array's cache flush would (tests/kernel/fsync_convert_stall.sh). */
static unsigned int cetrafs_publish_flush_stall_ms;
cetrafs_test_param(publish_flush_stall_ms, cetrafs_publish_flush_stall_ms, uint, 0644);
MODULE_PARM_DESC(publish_flush_stall_ms, "TEST ONLY: sleep this long before each publish-point cache flush");

int cetrafs_publish_flush(struct super_block *sb)
{
    if (READ_ONCE(cetrafs_publish_flush_skip) || !sb->s_bdev)
        return 0;
    if (READ_ONCE(cetrafs_publish_flush_stall_ms))
        msleep(READ_ONCE(cetrafs_publish_flush_stall_ms));
    return blkdev_issue_flush(sb->s_bdev);
}

/*
 * Copy 'len' bytes of a cached block out WHOLE: under the buffer lock,
 * which every in-place patch of a cached block takes
 * (cetrafs_cache_region_after_cas(), the update protocol). A plain
 * memcpy of b_data can interleave with such a patch and produce an
 * image that never existed. 'split', 'stall_ms' and 'unlocked' are for
 * tests: copy in two pieces with a pause between them, and optionally
 * without the lock (the pre-fix behaviour), so a tear can be held open.
 */
void cetrafs_bh_snapshot(struct buffer_head *bh, void *dst, unsigned int len, unsigned int split,
                         unsigned int stall_ms, bool unlocked)
{
    if (split > len)
        split = len;
    if (!unlocked)
        lock_buffer(bh);
    memcpy(dst, bh->b_data, split);
    if (stall_ms)
        msleep(stall_ms);
    memcpy((u8 *) dst + split, bh->b_data + split, len - split);
    if (!unlocked)
        unlock_buffer(bh);
}
