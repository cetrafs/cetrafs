// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * leafdefer.c -- a regular file's extent-tree blocks, held back from the
 * device until a durability boundary and then written through the
 * journal.
 *
 * Every 4 KiB guest write into a preallocated image converts a block out
 * of an uninit extent, so its leaf changes on every write. Journaling each
 * change costs three device cache flushes, which is the "unusably slow
 * guest" (file.c, the convert path), so a regular file's leaf and
 * interior edits wait for the next boundary -- close, fsync, sync_fs,
 * unmount. Until 2026-11-08 "wait" meant "left dirty in the buffer
 * cache", and then:
 *
 *  - the boundary wrote them IN PLACE, unjournaled. A 4 KiB leaf on a
 *    512-byte-sector device written across a power cut tears, the tear
 *    destroys the old map with the new one, every read of the range it
 *    maps returns -EIO and fsck cannot repair it: the one way a dying
 *    hypervisor left an image that neither restarts nor repairs
 *    (crash review 2026-11-08, C1);
 *  - kernel writeback could write them at ANY moment, with no flush
 *    ahead of them, so a reordering cache could persist a leaf marking a
 *    block written while the block's data or allocation bit was still
 *    volatile (C2) -- and torn, as above;
 *  - nothing dropped a deferred leaf whose block a truncate or punch
 *    freed, so writeback later wrote the old leaf over the block's next
 *    owner.
 *
 * Now a deferred block is NOT dirty. It carries BH_CetraDeferred and a
 * reference that pins it in the cache, and it is listed here with the
 * checksum of the image still on the device (the journal entry's replay
 * guard) and its inode. Writeback never sees it. A boundary writes all
 * of an inode's deferred blocks in one journal batch
 * (cetrafs_journal_write_deferred(): data and bits flushed first, then
 * the entries, a flush, the targets), so a crash anywhere leaves either
 * the old map or one the journal redoes. A free of the block drops it.
 *
 * Everything that treated "dirty" as "this buffer holds a write the
 * device has not seen; do not discard it" now asks cetrafs_bh_pending().
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/delay.h>
#include <linux/crc32c.h>
#include <linux/fs.h>
#include <linux/pagemap.h>
#include <linux/slab.h>
#include <linux/xarray.h>

#include "kmod.h"

struct cetrafs_deferred {
    struct buffer_head *bh; /* pinned: one reference held while listed */
    u64 ino;
    u64 generation; /* with ino: the journal entry's owner (L9) */
    u32 disk_crc; /* CRC32C of the block as it reads on the device */
    /* On its inode's list, or on the mount's orphan list once the inode
     * was evicted; under the xarray's lock. A boundary walks only its
     * own inode's (leafdefer review 2026-11-08, item 3). */
    struct list_head node;
    /* On the mount's orphan list: kept with the list move, so "on this
     * inode's list" is two loads, not a walk of the list. */
    bool orphan;
};

/*
 * End an update by deferring the block instead of dirtying it. The
 * buffer must be locked in an update (cetrafs_bh_begin_update_crc()),
 * and prev_crc is what that returned: the image before THIS update,
 * which is the device's image the first time the block is deferred.
 *
 * 0: deferred, and the buffer is unlocked. Nonzero: nothing was done and
 * the buffer is STILL LOCKED -- the caller writes it now instead, through
 * cetrafs_journal_write_block() with the same prev_crc.
 */
/* Blocks handed to the orphan list by an eviction, and orphans an edit
 * brought back to their inode's list (procfs). */
static atomic64_t cetrafs_deferred_orphaned = ATOMIC64_INIT(0);
static atomic64_t cetrafs_deferred_adopted = ATOMIC64_INIT(0);

/* TEST ONLY: the update path as it was before the orphan flag -- it
 * walks the inode's list to decide adoption, and computes the
 * pre-image CRC of a block already held back (ioutil.c). The control
 * of tests/kernel/deferred_hold_cost.sh. */
static bool cetrafs_deferred_eager_knob;
cetrafs_test_param(deferred_hold_eager, cetrafs_deferred_eager_knob, bool, 0644);
MODULE_PARM_DESC(deferred_hold_eager, "TEST ONLY: re-hold a held-back block the old way (list walk, pre-image CRC)");

bool cetrafs_deferred_eager(void)
{
    return READ_ONCE(cetrafs_deferred_eager_knob);
}

static atomic64_t cetrafs_deferred_holds = ATOMIC64_INIT(0);
static atomic64_t cetrafs_deferred_list_steps = ATOMIC64_INIT(0);

u64 cetrafs_deferred_hold_count(void)
{
    return (u64) atomic64_read(&cetrafs_deferred_holds);
}

u64 cetrafs_deferred_list_step_count(void)
{
    return (u64) atomic64_read(&cetrafs_deferred_list_steps);
}

/* Is 'd' on 'head'? Under the xarray lock. Only the TEST ONLY eager
 * path calls it: the flag answers the same question in O(1). */
static bool cetrafs_deferred_on_list(struct cetrafs_deferred *d, struct list_head *head)
{
    struct cetrafs_deferred *e;
    u64 steps = 0;
    bool found = false;

    list_for_each_entry(e, head, node) {
        steps++;
        if (e == d) {
            found = true;
            break;
        }
    }
    atomic64_add(steps, &cetrafs_deferred_list_steps);
    return found;
}

/* TEST ONLY: decline every NEW deferral, so the caller writes the block
 * through the journal at once -- a tree edit reaches the device at
 * update time, as before deferral existed. Lets
 * tests/crash/buffered_extent_order.sh stage the old write order (an
 * extent marked written on the device before its data) and test the
 * buffered-write fix on its own, without this file's protection in the
 * way. A block already deferred stays deferred: declining it would
 * write it twice. */
static bool cetrafs_leaf_defer_off;
cetrafs_test_param(leaf_defer_off, cetrafs_leaf_defer_off, bool, 0644);
MODULE_PARM_DESC(leaf_defer_off, "TEST ONLY: write tree-block edits through the journal at update time instead of deferring them");

int cetrafs_bh_defer_update(struct inode *inode, struct buffer_head *bh, u32 prev_crc)
{
    struct xarray *xa = cetrafs_sb_deferred(inode->i_sb);
    struct cetrafs_deferred *d, *old;

    if (!xa)
        return -EINVAL;
    if (READ_ONCE(cetrafs_leaf_defer_off) && !buffer_cetra_deferred(bh))
        return -EAGAIN; /* test-only; see the parameter */
    if (buffer_cetra_deferred(bh)) {
        bool listed;

        /* The bit and the listing change together under the buffer
         * lock, which this update holds, so a set bit means listed --
         * with the device's image. Confirmed, not trusted: a bit without
         * its listing would leave this edit written by nothing. */
        xa_lock(xa);
        old = xa_load(xa, bh->b_blocknr);
        listed = old && old->bh == bh;
        if (listed)
            atomic64_inc(&cetrafs_deferred_holds);
        /* ...and listed on THIS inode's list. An entry its inode's
         * eviction moved to the mount's orphans (a boundary that failed)
         * is written only at sync_fs or unmount, so this edit would miss
         * the reopened file's own fsync and close, and a split's shrunk
         * source leaf would miss the batch its destination goes in
         * (cetrafs_convert_source_durable()). Bring it home: unlist and
         * settle find it through the xarray from either list. */
        if (listed) {
            bool home;

            if (cetrafs_deferred_eager())
                home = old->ino == inode->i_ino && cetrafs_deferred_on_list(old, cetrafs_inode_deferred(inode));
            else
                home = old->ino == inode->i_ino && !old->orphan;
            if (!home)
                atomic64_inc(&cetrafs_deferred_adopted);
            list_move_tail(&old->node, cetrafs_inode_deferred(inode));
            old->ino = inode->i_ino;
            old->orphan = false;
            old->generation = cetrafs_inode_get_generation(inode);
        }
        xa_unlock(xa);
        if (!WARN_ON_ONCE(!listed)) {
            cetrafs_bh_end_update_deferred(bh);
            return 0;
        }
        /* Listed again below, against this update's before-image: the
         * best evidence of the device's left. The pin is already held. */
    }
    /* Nothing leaves a tree block dirty any more: its pre-update image
     * would not be the device's, and the replay guard recorded from it
     * would refuse a torn target's redo. Say so; the boundary still
     * writes it. */
    WARN_ON_ONCE(buffer_dirty(bh) || buffer_cetra_held(bh)); /* held: written by the next tick, ahead of its journal */
    /* Cannot fail: a block not listed would have to be written now, and
     * a leaf written ahead of its index is the ordering this exists to
     * keep (cetrafs_convert_source_durable()). 24 bytes. */
    d = kmalloc(sizeof(*d), GFP_NOFS | __GFP_NOFAIL);
    d->bh = bh;
    d->ino = inode->i_ino;
    d->generation = cetrafs_inode_get_generation(inode);
    d->disk_crc = prev_crc;
    d->orphan = false;
    INIT_LIST_HEAD(&d->node);
    old = xa_store(xa, bh->b_blocknr, d, GFP_NOFS | __GFP_NOFAIL);
    xa_lock(xa);
    if (WARN_ON_ONCE(old)) {
        /* Listed without its bit: cannot happen while the pin holds the
         * buffer. Keep the older entry's device image, drop its pin. */
        d->disk_crc = old->disk_crc;
        list_del(&old->node);
    }
    /* Linked after the store, under the buffer lock this update holds:
     * an unlist takes the same lock, so it never finds the entry half
     * listed, and a boundary of this inode is excluded by
     * invalidate_lock. */
    list_add_tail(&d->node, cetrafs_inode_deferred(inode));
    xa_unlock(xa);
    if (old) {
        brelse(old->bh);
        kfree(old);
    }
    cetrafs_bh_end_update_deferred(bh); /* pins it, sets the bit, unlocks */
    return 0;
}

/* The device's checksum for a deferred block, or 'fallback' if it is not
 * deferred. */
u32 cetrafs_deferred_disk_crc(struct super_block *sb, struct buffer_head *bh, u32 fallback)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct cetrafs_deferred *d;
    u32 crc = fallback;

    if (!xa || !buffer_cetra_deferred(bh))
        return fallback;
    xa_lock(xa);
    d = xa_load(xa, bh->b_blocknr);
    if (d)
        crc = d->disk_crc;
    xa_unlock(xa);
    return crc;
}

/*
 * Unlist a held-back block. The caller holds the buffer LOCKED (ioutil.c,
 * cetrafs_bh_deferred_unlist()) and its own reference: the bit, the
 * listing and the pin go together, so an update -- which holds the same
 * lock -- sees either all of them or none. 'drop' also forgets the
 * cached image: a freed block, or a stopped mount's unwritten change.
 */
void cetrafs_deferred_unlist_locked(struct super_block *sb, struct buffer_head *bh, bool drop)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct cetrafs_deferred *d = NULL;
    bool pinned = buffer_cetra_deferred(bh);

    if (xa && pinned) {
        xa_lock(xa);
        d = xa_load(xa, bh->b_blocknr);
        if (d && d->bh == bh) {
            __xa_erase(xa, bh->b_blocknr);
            list_del(&d->node);
        } else {
            d = NULL;
        }
        xa_unlock(xa);
    }
    /* No longer held back: a cached image left in memory must carry a
     * valid tail for whoever reads or writes it next (P9). */
    if (!drop)
        cetrafs_blk_tail_settle(bh);
    clear_buffer_cetra_tail_stale(bh);
    clear_buffer_cetra_deferred(bh);
    if (drop) {
        clear_buffer_dirty(bh);
        clear_buffer_uptodate(bh);
    }
    if (pinned)
        put_bh(bh); /* the pin; the caller's reference keeps the buffer */
    kfree(d);
}

/*
 * A boundary wrote this block's image, checksum 'written_crc' (buffer
 * LOCKED, as above). If that is still the image in core, the block is
 * done with. If not, an update edited it after the write -- the batch
 * holds no lock against a file that was not in core when it started
 * (cetrafs_deferred_flush_all()) -- and it stays listed, now against
 * the image the device holds, so the next boundary's entry carries a
 * replay guard that matches the device.
 */
void cetrafs_deferred_settle_locked(struct super_block *sb, struct buffer_head *bh, u32 written_crc)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct cetrafs_deferred *d;

    if (!xa || !buffer_cetra_deferred(bh))
        return;
    if (~crc32c(~0U, bh->b_data, CETRAFS_BLOCK_SIZE) == written_crc) {
        cetrafs_deferred_unlist_locked(sb, bh, false);
        return;
    }
    xa_lock(xa);
    d = xa_load(xa, bh->b_blocknr);
    if (d && d->bh == bh)
        d->disk_crc = written_crc;
    xa_unlock(xa);
}

/* Up to 16 listed blocks in [*pos, last], each with a reference; *pos
 * moves past the last one taken. */
static unsigned int cetrafs_deferred_grab(struct xarray *xa, unsigned long *pos, unsigned long last,
                                          struct buffer_head **out)
{
    struct cetrafs_deferred *d;
    unsigned long idx;
    unsigned int n = 0;

    xa_lock(xa);
    xa_for_each_range(xa, idx, d, *pos, last) {
        get_bh(d->bh);
        out[n++] = d->bh;
        *pos = idx + 1;
        if (n == 16)
            break;
    }
    xa_unlock(xa);
    return n;
}

/* Unlist every listed block in [first, last]; returns how many. */
static unsigned long cetrafs_deferred_unlist_range(struct super_block *sb, unsigned long first, unsigned long last,
                                                   bool drop)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct buffer_head *bhs[16];
    unsigned long pos = first, total = 0;
    unsigned int n, i;

    if (!xa || xa_empty(xa))
        return 0;
    while (pos <= last && (n = cetrafs_deferred_grab(xa, &pos, last, bhs))) {
        for (i = 0; i < n; i++) {
            cetrafs_bh_deferred_unlist(sb, bhs[i], drop);
            brelse(bhs[i]);
        }
        total += n;
        if (!pos)
            break; /* wrapped past ULONG_MAX */
    }
    return total;
}

/*
 * Blocks [lba, lba + count) are being freed: a deferred copy of any of
 * them is an edit of a tree that no longer names it, and written later it
 * would land on the block's next owner. Dropped, image and all. Every
 * free goes through __cetrafs_free_data_extent(), which calls this.
 */
void cetrafs_deferred_forget_range(struct super_block *sb, u64 lba, u32 count)
{
    if (count)
        cetrafs_deferred_unlist_range(sb, (unsigned long) lba, (unsigned long) (lba + count - 1), true);
}

/* Snapshot the entries on one list -- an inode's, or the orphans --
 * with a reference each. *out is kvmalloc'd; the caller brelse()s and
 * kvfree()s. */
static int cetrafs_deferred_collect(struct xarray *xa, struct list_head *head, struct buffer_head ***out,
                                    u32 **crcs, struct cetrafs_journal_owner **owners, unsigned int *n)
{
    struct cetrafs_deferred *d;
    unsigned int cnt = 0, i = 0;

    *out = NULL;
    *crcs = NULL;
    *owners = NULL;
    *n = 0;
    xa_lock(xa);
    list_for_each_entry(d, head, node)
        cnt++;
    xa_unlock(xa);
    if (!cnt)
        return 0;
    *out = kvmalloc_array(cnt, sizeof(**out), GFP_NOFS);
    *crcs = kvmalloc_array(cnt, sizeof(**crcs), GFP_NOFS);
    *owners = kvmalloc_array(cnt, sizeof(**owners), GFP_NOFS);
    if (!*out || !*crcs || !*owners) {
        kvfree(*out);
        kvfree(*crcs);
        kvfree(*owners);
        *out = NULL;
        *crcs = NULL;
        *owners = NULL;
        return -ENOMEM;
    }
    xa_lock(xa);
    list_for_each_entry(d, head, node) {
        if (i == cnt)
            break; /* listed since the count: the next boundary's */
        get_bh(d->bh);
        (*out)[i] = d->bh;
        (*crcs)[i] = d->disk_crc;
        (*owners)[i].ino = d->ino;
        (*owners)[i].generation = d->generation;
        i++;
    }
    xa_unlock(xa);
    *n = i;
    return 0;
}

/*
 * Keep an inode's held-back set small enough to be ONE journal batch,
 * which is what makes a boundary atomic (cetrafs_journal_write_deferred()):
 * at half the journal, write it now. Called by a tree mutator after
 * holding a block back, at a point where it has no other block mid-
 * update, under invalidate_lock. Writing everything held back so far
 * there is what the journal did before blocks were held back at all --
 * every edit written at this same call, in program order -- so the
 * state it makes durable is one that model already made durable. A
 * failed write is not the caller's to undo: the blocks stay held back
 * for the boundary, which reports it.
 */
static atomic64_t cetrafs_deferred_cap_flushes = ATOMIC64_INIT(0);

u64 cetrafs_deferred_cap_flush_count(void)
{
    return (u64) atomic64_read(&cetrafs_deferred_cap_flushes);
}

/* TEST ONLY: the room check never refuses -- the old behaviour, the
 * control of tests/kernel/deferred_room.sh. */
static bool cetrafs_deferred_room_off;
cetrafs_test_param(deferred_room_off, cetrafs_deferred_room_off, bool, 0644);
MODULE_PARM_DESC(deferred_room_off, "TEST ONLY: never refuse a tree mutation for a held-back set at its cap");

static atomic64_t cetrafs_deferred_room_refusals = ATOMIC64_INIT(0);
/* Set once any cap flush has failed: until then the room check has
 * nothing to look at, and it runs on the per-block allocation path
 * (docs/PERFORMANCE.md 1). Never cleared -- after a failure the check
 * costs what the cap check after each mutation already costs. */
static atomic_t cetrafs_deferred_cap_failed = ATOMIC_INIT(0);

u64 cetrafs_deferred_room_refusal_count(void)
{
    return (u64) atomic64_read(&cetrafs_deferred_room_refusals);
}

/* Write the inode's held-back set if it reached half the journal. 0:
 * below the cap, or written; else the write's error, the set intact. */
static int __cetrafs_deferred_capped(struct inode *inode)
{
    struct xarray *xa = cetrafs_sb_deferred(inode->i_sb);
    unsigned int cap = cetrafs_journal_batch_capacity(inode->i_sb) / 2, cnt = 0;
    struct cetrafs_deferred *d;

    if (!xa || !cap || !S_ISREG(inode->i_mode))
        return 0;
    xa_lock(xa);
    list_for_each_entry(d, cetrafs_inode_deferred(inode), node)
        if (++cnt >= cap)
            break;
    xa_unlock(xa);
    if (cnt < cap)
        return 0;
    atomic64_inc(&cetrafs_deferred_cap_flushes);
    {
        int ret = cetrafs_deferred_flush_inode(inode, true);

        if (ret)
            atomic_set(&cetrafs_deferred_cap_failed, 1);
        return ret;
    }
}

void cetrafs_deferred_capped(struct inode *inode)
{
    if (__cetrafs_deferred_capped(inode))
        pr_warn_ratelimited("ino=%llu: held-back tree blocks reached half the journal and could not be written "
                            "yet -- the next change to the file's map retries, and fails if this still does\n",
                            (unsigned long long) inode->i_ino);
}

/*
 * Before a tree mutation edits anything: room for it in the held-back
 * set. A cap flush that failed (above) only warns -- the mutation it
 * ran after is done -- and the set stays at the cap. Each later
 * mutation would add its blocks on top, and once the set passed the
 * journal's size no boundary could ever write it: refused for good
 * (cetrafs_journal_write_deferred()), and unmount dropped it, losing
 * the extents those leaves mapped with the data on the device. So a
 * mutation that finds the set at the cap tries the write again first,
 * and if it still fails, fails itself -- the WRITE errors, not the
 * boundary. The set therefore never holds more than the cap plus one
 * mutation's blocks, which is the bound the cap already assumes.
 */
int cetrafs_deferred_room(struct inode *inode)
{
    int ret;

    if (likely(!atomic_read(&cetrafs_deferred_cap_failed)))
        return 0;
    ret = __cetrafs_deferred_capped(inode);

    if (!ret || READ_ONCE(cetrafs_deferred_room_off))
        return 0;
    atomic64_inc(&cetrafs_deferred_room_refusals);
    pr_warn_ratelimited("ino=%llu: held-back tree blocks are at half the journal and still cannot be written (%d) "
                        "-- refusing to change the file's map\n",
                        (unsigned long long) inode->i_ino, ret);
    return ret;
}

u64 cetrafs_deferred_orphaned_count(void)
{
    return (u64) atomic64_read(&cetrafs_deferred_orphaned);
}

u64 cetrafs_deferred_adopted_count(void)
{
    return (u64) atomic64_read(&cetrafs_deferred_adopted);
}

/* An inode leaves the cache with blocks still held back (a boundary that
 * failed): they move to the mount's orphan list, which sync_fs and
 * unmount write. */
void cetrafs_deferred_evict(struct inode *inode)
{
    struct xarray *xa = cetrafs_sb_deferred(inode->i_sb);
    struct list_head *orphans = cetrafs_sb_deferred_orphans(inode->i_sb);
    struct cetrafs_deferred *d;
    u64 n = 0;

    if (!xa || !orphans)
        return;
    xa_lock(xa);
    list_for_each_entry(d, cetrafs_inode_deferred(inode), node) {
        n++;
        d->orphan = true;
    }
    list_splice_tail_init(cetrafs_inode_deferred(inode), orphans);
    xa_unlock(xa);
    if (n)
        atomic64_add(n, &cetrafs_deferred_orphaned);
}

/* TEST ONLY: hold a batch between its target writes and the settle, so a
 * suite can edit a written block there (tests/kernel/deferred_settle_race.sh). */
static unsigned int cetrafs_deferred_settle_stall_ms;
cetrafs_test_param(deferred_settle_stall_ms, cetrafs_deferred_settle_stall_ms, uint, 0644);
MODULE_PARM_DESC(deferred_settle_stall_ms, "TEST ONLY: pause between a batch's target writes and its settle");

/* TEST ONLY: sync_fs/unmount flush every listed block as if its inode
 * were not in core -- with no lock against a writer of the file, the
 * condition deferred_settle_stall_ms exists to race. */
bool cetrafs_deferred_flush_no_inode;
cetrafs_test_param(deferred_flush_no_inode, cetrafs_deferred_flush_no_inode, bool, 0644);
MODULE_PARM_DESC(deferred_flush_no_inode, "TEST ONLY: flush held-back blocks without looking up their inode");

/* TEST ONLY: a held-back set is written without asking the device first,
 * as before audit 2026-11-15 BC-31 (ctest late-flush's control,
 * tests/kernel/late_flush_stale.sh). */
static bool cetrafs_late_flush_blind;
cetrafs_test_param(late_flush_blind, cetrafs_late_flush_blind, bool, 0644);
MODULE_PARM_DESC(late_flush_blind, "TEST ONLY: write held-back tree blocks without checking the device still holds what they replace");

static atomic64_t cetrafs_deferred_stale_sets = ATOMIC64_INIT(0);
static atomic64_t cetrafs_deferred_window_losses = ATOMIC64_INIT(0); /* F-71: a peer's write inside the window */

u64 cetrafs_deferred_stale_set_count(void)
{
    return (u64) atomic64_read(&cetrafs_deferred_stale_sets);
}

/*
 * Does the device still hold, for every block of the set, the image it
 * was held back against (d->disk_crc)? A held-back block is written in
 * place, blind, and nothing about a boundary says the device is still
 * ours to write: a close that failed is finished later by the heartbeat,
 * a sync or the unmount, and under nofilelock no lock stood between
 * that failure and a peer opening the file, writing it and publishing
 * its own map over the same leaves (audit 2026-11-15 BC-31; CLAUDE.md
 * rule 9). Read from the device itself, not the cache, which holds
 * our image. A peer's write in flight reads as a change too: either way
 * the set is no longer the file's. One 4 KiB read per held-back block
 * per boundary, beside the batch's three cache flushes.
 * 0: unchanged. -ESTALE: block *bad changed. Other: the read failed.
 */
static int cetrafs_deferred_set_current(struct buffer_head **bhs, const u32 *crcs, unsigned int n, unsigned int *bad)
{
    void *buf;
    unsigned int i;
    int ret = 0;

    /* In every mode. With the file lock on, "the lock is still ours"
     * should make this a no-op -- a failed close keeps it (B-7) -- but
     * that is an argument about every path that holds a block back, and
     * the read costs little beside the batch's flushes. */
    if (READ_ONCE(cetrafs_late_flush_blind))
        return 0; /* test-only; see the parameter */
    buf = kmalloc(CETRAFS_BLOCK_SIZE, GFP_NOFS);
    if (!buf)
        return -ENOMEM;
    for (i = 0; i < n; i++) {
        struct buffer_head *bh = bhs[i];

        if (bdev_rw_virt(bh->b_bdev, bh->b_blocknr * (bh->b_size >> SECTOR_SHIFT), buf, CETRAFS_BLOCK_SIZE,
                         REQ_OP_READ)) {
            ret = -EIO;
            break;
        }
        if (~crc32c(~0U, buf, CETRAFS_BLOCK_SIZE) != crcs[i]) {
            *bad = i;
            ret = -ESTALE;
            break;
        }
    }
    kfree(buf);
    return ret;
}

/* TEST ONLY: the late flush does not look for a peer's write inside its
 * own window, as before audit 2026-11-15 F-71 (the control of
 * tests/kernel/late_flush_window.sh). */
static bool cetrafs_late_flush_unverified;
cetrafs_test_param(late_flush_unverified, cetrafs_late_flush_unverified, bool, 0644);
MODULE_PARM_DESC(late_flush_unverified, "TEST ONLY: a late tree flush does not check its window for a peer's write");
/* TEST ONLY: a late flush waits this long between its device check and
 * its writes -- the window F-71 names. */
static unsigned int cetrafs_late_flush_window_ms;
cetrafs_test_param(late_flush_window_ms, cetrafs_late_flush_window_ms, uint, 0644);
MODULE_PARM_DESC(late_flush_window_ms, "TEST ONLY: a tree flush pauses this many ms between its check and its writes");

/* The record's file stamp, read from the device; 0 for a record of
 * another generation or one that cannot be read (never a valid stamp:
 * cetrafs_file_seq_new_as() never returns a zero value part). */
static u64 cetrafs_deferred_file_seq(struct super_block *sb, const struct cetrafs_journal_owner *o)
{
    cetrafs_inode_t *raw = kmalloc(sizeof(*raw), GFP_NOFS);
    u64 seq = 0;

    if (!raw)
        return 0;
    cetrafs_invalidate_raw_inode(sb, o->ino);
    if (!cetrafs_read_raw_inode(sb, o->ino, raw) && cetrafs_le64(raw->generation) == o->generation)
        seq = cetrafs_le64(raw->file_seq);
    kfree(raw);
    return seq;
}

/*
 * After the writes: did a peer write the file inside the window between
 * the device check and the writes (audit 2026-11-15 F-71)? The check
 * reads the set before the batch, and the batch's journal entries and
 * cache flushes run before the in-place writes -- under nofilelock
 * nothing keeps a peer from writing a leaf of the set in between, and
 * one of the two writes is then lost. Not preventable here without the
 * peer taking a lock it does not take; detected instead, and the file
 * is marked damaged rather than left silently wrong: a written block
 * that no longer reads as written (the peer wrote after us), or a
 * record stamp a peer published since the check (it wrote before us).
 * In every mode: a lock this node held can be handed to a peer (a
 * suspend) while a set is still held back, and the orphan flush runs
 * long after.
 *
 * What it does not see, said plainly: a peer that writes a leaf before
 * our write and publishes its record only after the read below -- its
 * leaf is gone and nothing here knows (the window is the batch, ms).
 * What it reports that is not a loss: any peer publish in the window,
 * even one touching none of the set (under nofilelock that is a
 * handoff, where both nodes writing is the misuse BASICS.md forbids);
 * and, on the orphan path, a reopened inode that adopted a block and
 * wrote it back in the same milliseconds. An unverifiable read counts
 * as a loss: the correctness bar is "say so", never "assume".
 */
static void cetrafs_deferred_window_check(struct super_block *sb, struct buffer_head **bhs, const bool *written,
                                          const u32 *wcrc, unsigned int n,
                                          const struct cetrafs_journal_owner *o, u64 seq_before)
{
    u64 seq_after;
    u32 me = 0;
    void *buf;
    unsigned int i;
    bool lost = false;

    if (READ_ONCE(cetrafs_late_flush_unverified) || cetrafs_sb_get_node_id(sb, &me))
        return;
    buf = kmalloc(CETRAFS_BLOCK_SIZE, GFP_NOFS);
    lost = !buf;
    for (i = 0; buf && i < n && !lost; i++) {
        struct buffer_head *bh = bhs[i];

        if (!written[i])
            continue;
        if (bdev_rw_virt(bh->b_bdev, bh->b_blocknr * (bh->b_size >> SECTOR_SHIFT), buf, CETRAFS_BLOCK_SIZE,
                         REQ_OP_READ) ||
            ~crc32c(~0U, buf, CETRAFS_BLOCK_SIZE) != wcrc[i])
            lost = true;
    }
    kfree(buf);
    /* The stamp only where the one before the batch was read: an
     * unknown "before" would make any peer's last stamp read as new. */
    if (!lost && seq_before) {
        seq_after = cetrafs_deferred_file_seq(sb, o);
        if (!seq_after || (seq_after != seq_before && CETRAFS_FILE_SEQ_NODE(seq_after) != (me & 0xFFFFu)))
            lost = true;
    }
    if (!lost)
        return;
    atomic64_inc(&cetrafs_deferred_window_losses);
    pr_err("ino=%llu: another node wrote the file while this node's tree flush was landing, or what landed could "
           "not be read back -- a write may be lost; the file is marked damaged (fsck.cetra)\n",
           (unsigned long long) o->ino);
    cetrafs_sb_corrupt_owner(sb, o->ino, o->generation);
}

/*
 * -ESTALE: the set was dropped, not written -- one inode's whole set,
 * which is one map state and must not be half applied. Each block's
 * cached image goes with it, so this node reads what the peer wrote.
 * The caller with the inode drops its record shadow too
 * (cetrafs_lock_tree_superseded()).
 */
static int cetrafs_deferred_write_set(struct super_block *sb, struct buffer_head **bhs, u32 *crcs,
                                      const struct cetrafs_journal_owner *owners, unsigned int n, bool no_inode)
{
    bool *written;
    u32 *wcrc;
    unsigned int i, bad = 0;
    u64 seq_before;
    int ret;

    /* Before the check: a peer's publish after it is in the window. */
    seq_before = cetrafs_deferred_file_seq(sb, &owners[0]);
    ret = cetrafs_deferred_set_current(bhs, crcs, n, &bad);
    if (ret == -ESTALE) {
        atomic64_inc(&cetrafs_deferred_stale_sets);
        pr_err("ino=%llu: tree block %llu changed on the device since this node held it back -- another node "
               "wrote the file after this node's last boundary failed; its %u unwritten tree block(s) are "
               "dropped, not written over that\n",
               (unsigned long long) owners[0].ino, (unsigned long long) bhs[bad]->b_blocknr, n);
        for (i = 0; i < n; i++)
            cetrafs_bh_deferred_unlist(sb, bhs[i], true);
        return ret;
    }
    if (ret)
        return ret; /* nothing written: the blocks stay held back */

    written = kvcalloc(n, sizeof(*written), GFP_NOFS);
    wcrc = kvcalloc(n, sizeof(*wcrc), GFP_NOFS);
    if (!written || !wcrc) {
        kvfree(written);
        kvfree(wcrc);
        return -ENOMEM;
    }
    if (unlikely(READ_ONCE(cetrafs_late_flush_window_ms))) {
        pr_info("deferred: ino=%llu: TEST pause of %ums between the check and the writes\n",
                (unsigned long long) owners[0].ino, cetrafs_late_flush_window_ms);
        msleep(xchg(&cetrafs_late_flush_window_ms, 0));
    }
    ret = cetrafs_journal_write_deferred(sb, bhs, owners, crcs, n, written, wcrc);
    if (unlikely(cetrafs_deferred_settle_stall_ms) && no_inode) {
        pr_info("deferred: TEST pause of %ums between the target writes and the settle (inode not in core)\n",
                cetrafs_deferred_settle_stall_ms);
        msleep(cetrafs_deferred_settle_stall_ms);
    }
    for (i = 0; i < n; i++)
        if (written[i])
            cetrafs_bh_deferred_settle(sb, bhs[i], wcrc[i]);
    cetrafs_deferred_window_check(sb, bhs, written, wcrc, n, &owners[0], seq_before);
    kvfree(written);
    kvfree(wcrc);
    return ret;
}

/* TEST ONLY: an inode flush writes nothing and reports success, so its
 * close lets the inode go with blocks still held back and an eviction
 * orphans them (tests/kernel/deferred_orphan_adopted.sh). A failed close
 * does NOT pin its inode -- it queues only (ino, generation) -- so it can
 * be evicted before the heartbeat finishes the close; the retry writes
 * the orphans first (cetrafs_deferred_flush_orphans_of(), B-7). */
static bool cetrafs_tree_flush_skip_all;
cetrafs_test_param(tree_flush_skip_all, cetrafs_tree_flush_skip_all, bool, 0644);
MODULE_PARM_DESC(tree_flush_skip_all, "TEST ONLY: extent-tree block flushes of an inode write nothing");

/* TEST ONLY: the next inode flush fails as a device error would. */
static bool cetrafs_tree_flush_fail_once;
cetrafs_test_param(tree_flush_fail_once, cetrafs_tree_flush_fail_once, bool, 0644);
MODULE_PARM_DESC(tree_flush_fail_once, "TEST ONLY: the next extent-tree block flush fails with -EIO");

/*
 * The boundary: write every deferred tree block of this inode, through
 * the journal, in one batch. Nothing may modify them meanwhile: the
 * caller holds invalidate_lock (mapping_locked) or this takes it shared
 * -- every tree mutator holds it exclusively (CLAUDE.md rule 18), the
 * O_DIRECT completion's conversion included.
 */
/* Does this inode have tree blocks held back right now? */
bool cetrafs_deferred_inode_pending(struct inode *inode)
{
    struct xarray *xa = cetrafs_sb_deferred(inode->i_sb);
    bool pending;

    if (!xa || xa_empty(xa))
        return false;
    xa_lock(xa);
    pending = !list_empty(cetrafs_inode_deferred(inode));
    xa_unlock(xa);
    return pending;
}

int cetrafs_deferred_flush_inode(struct inode *inode, bool mapping_locked)
{
    struct super_block *sb = inode->i_sb;
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct buffer_head **bhs;
    struct cetrafs_journal_owner *owners;
    unsigned int n, i;
    u32 *crcs;
    int ret;

    if (cetrafs_tree_flush_fail_once) {
        cetrafs_tree_flush_fail_once = false;
        return -EIO; /* test-only, see the knob */
    }
    if (cetrafs_tree_flush_skip_all)
        return 0; /* test-only, see the knob */
    if (!xa || xa_empty(xa))
        return 0;
    if (!mapping_locked)
        filemap_invalidate_lock_shared(inode->i_mapping);
    ret = cetrafs_deferred_collect(xa, cetrafs_inode_deferred(inode), &bhs, &crcs, &owners, &n);
    if (!ret && n)
        ret = cetrafs_deferred_write_set(sb, bhs, crcs, owners, n, false);
    if (ret == -ESTALE)
        cetrafs_lock_tree_superseded(inode);
    if (!mapping_locked)
        filemap_invalidate_unlock_shared(inode->i_mapping);
    for (i = 0; i < n; i++)
        brelse(bhs[i]);
    kvfree(bhs);
    kvfree(crcs);
    kvfree(owners);
    return ret;
}

/*
 * The orphans of several evicted inodes are written one INODE per batch:
 * a batch is atomic only up to the journal's size, and each inode's set
 * was kept under half of it while it was live (cetrafs_deferred_capped())
 * -- the orphans together are not.
 */
static int cetrafs_deferred_write_by_inode(struct super_block *sb, struct buffer_head **bhs, u32 *crcs,
                                           struct cetrafs_journal_owner *owners, unsigned int n, bool no_inode)
{
    struct buffer_head **gb = kvmalloc_array(n, sizeof(*gb), GFP_NOFS);
    u32 *gc = kvmalloc_array(n, sizeof(*gc), GFP_NOFS);
    struct cetrafs_journal_owner *go = kvmalloc_array(n, sizeof(*go), GFP_NOFS);
    bool *done = kvcalloc(n, sizeof(*done), GFP_NOFS);
    unsigned int i, k, m;
    int r = 0, w;

    if (!gb || !gc || !go || !done) {
        r = -ENOMEM;
        goto out;
    }
    for (i = 0; i < n; i++) {
        if (done[i])
            continue;
        for (k = i, m = 0; k < n; k++) {
            if (done[k] || owners[k].ino != owners[i].ino || owners[k].generation != owners[i].generation)
                continue;
            gb[m] = bhs[k];
            gc[m] = crcs[k];
            go[m] = owners[k];
            done[k] = true;
            m++;
        }
        w = cetrafs_deferred_write_set(sb, gb, gc, go, m, no_inode);
        /* -ESTALE: dropped, superseded by a peer -- nothing left to write
         * and no inode in core to tell; not a boundary that failed. */
        if (w && w != -ESTALE && !r)
            r = w;
    }
out:
    kvfree(gb);
    kvfree(gc);
    kvfree(go);
    kvfree(done);
    return r;
}

static int cetrafs_deferred_flush_list(struct super_block *sb, struct list_head *head, bool no_inode)
{
    struct buffer_head **bhs;
    struct cetrafs_journal_owner *owners;
    unsigned int n, i;
    u32 *crcs;
    int r;

    r = cetrafs_deferred_collect(cetrafs_sb_deferred(sb), head, &bhs, &crcs, &owners, &n);
    if (!r && n)
        r = cetrafs_deferred_write_by_inode(sb, bhs, crcs, owners, n, no_inode);
    for (i = 0; i < n; i++)
        brelse(bhs[i]);
    kvfree(bhs);
    kvfree(crcs);
    kvfree(owners);
    return r;
}

/* TEST ONLY: the close retry does not look at the orphans, as before
 * B-7 (tests/kernel/close_retry_orphans.sh). */
static bool cetrafs_retry_orphans_off;
cetrafs_test_param(retry_orphans_off, cetrafs_retry_orphans_off, bool, 0644);
MODULE_PARM_DESC(retry_orphans_off, "TEST ONLY: a close finished by the heartbeat ignores the inode's orphaned tree blocks");

/*
 * A close that failed is finished by the heartbeat on a fresh iget: if
 * the inode was evicted in between, its held-back tree blocks are on the
 * mount's orphan list and its own list is empty, so the retry's flush
 * wrote nothing, published the record and cleared the lock -- and the
 * orphan batch later wrote the old leaf over whatever a peer had made of
 * it since (audit 2026-11-14 B-7). They are written first. With the
 * lock on it is still ours, so they are still the file's latest state;
 * under nofilelock no lock says so, and the write checks the device
 * instead -- a set a peer has rewritten since is dropped, not written
 * (cetrafs_deferred_set_current(), BC-31). A failure keeps the close
 * unfinished.
 */
int cetrafs_deferred_flush_orphans_of(struct super_block *sb, u64 ino)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct list_head *orphans = cetrafs_sb_deferred_orphans(sb);
    struct cetrafs_deferred *d;
    bool any = false;

    if (!xa || !orphans || READ_ONCE(cetrafs_retry_orphans_off))
        return 0;
    xa_lock(xa);
    list_for_each_entry(d, orphans, node) {
        if (d->ino == ino) {
            any = true;
            break;
        }
    }
    xa_unlock(xa);
    return any ? cetrafs_deferred_flush_list(sb, orphans, true) : 0;
}

/*
 * sync_fs and unmount: every deferred block on the mount. The orphans of
 * evicted inodes first -- nothing in core can edit them but a reopen,
 * and a block edited after its write stays listed (the settle) -- then
 * each inode in core, under its own lock.
 */
/*
 * A listed set whose inode ilookup() does not give back. An eviction is
 * not that: ilookup() waits for an inode being freed, and the eviction
 * moves its set to the orphans before it ends. What is left is an
 * object UNHASHED while alive -- a peer deleted the file and reused the
 * number, and the refresh dropped the stale object from the hash
 * (inode.c, rule 2) while an fd still holds it: ilookup() then finds
 * nothing, or the new file under the same number with an empty list.
 * The walk skipped it, met the same entry on every round until its
 * bound ran out, and the sync returned success with that set -- and
 * every set after it -- still held (audit 2026-11-15 BL-23). Now the
 * sync fails: the set is the live object's to write, at its close or
 * once evicted, when it becomes an orphan. A short re-check first
 * covers an eviction that began just after the lookup.
 */
static bool cetrafs_flush_all_skip_unhashed;
cetrafs_test_param(flush_all_skip_unhashed, cetrafs_flush_all_skip_unhashed, bool, 0644);
MODULE_PARM_DESC(flush_all_skip_unhashed, "TEST ONLY: sync skips a set whose inode is unhashed, as before audit BL-23");

#define CETRAFS_FLUSH_ALL_UNHASHED_WAIT_MS 100

/* TEST ONLY: the walk stops at a set it cannot reach or write, as before audit
 * 2026-11-15 F-73 (tests/kernel/sync_unreachable_set.sh). */
static bool cetrafs_flush_all_stop_at_failure;
cetrafs_test_param(flush_all_stop_at_failure, cetrafs_flush_all_stop_at_failure, bool, 0644);
MODULE_PARM_DESC(flush_all_stop_at_failure, "TEST ONLY: sync stops at a held set it cannot reach or write");

/* TEST ONLY, one-shot: the next sync first unhashes this inode, as the
 * refresh does to an object it finds deleted or reused -- the state the
 * walk below meets (tests/kernel/sync_unreachable_set.sh). */
static unsigned long long cetrafs_flush_all_unhash_ino;
cetrafs_test_param(flush_all_unhash_ino, cetrafs_flush_all_unhash_ino, ullong, 0644);
MODULE_PARM_DESC(flush_all_unhash_ino, "TEST ONLY: the next sync first unhashes this inode number");

static int cetrafs_deferred_unreachable(struct xarray *xa, unsigned long idx, u64 ino, u64 generation)
{
    unsigned long until = jiffies + msecs_to_jiffies(CETRAFS_FLUSH_ALL_UNHASHED_WAIT_MS);
    struct cetrafs_deferred *d;
    bool still;

    for (;;) {
        xa_lock(xa);
        d = xa_load(xa, idx);
        still = d && d->ino == ino && d->generation == generation && !d->orphan;
        xa_unlock(xa);
        if (!still)
            return 0;
        if (time_after(jiffies, until)) {
            pr_warn("deferred: ino=%llu (generation %llx) holds tree blocks on an object no longer in the inode "
                    "cache -- deleted elsewhere while open here; this sync did not write them\n",
                    (unsigned long long) ino, (unsigned long long) generation);
            return -EBUSY;
        }
        msleep(1);
    }
}

/* An owner this walk has already failed to write: its other blocks are
 * passed over, not tried again (F-73). Grown as needed; the walk stops,
 * with its error, only if even that allocation fails. */
struct cetrafs_flush_skip {
    u64 *ent; /* ino, generation pairs */
    unsigned int n, cap;
};

static bool cetrafs_flush_skip_has(const struct cetrafs_flush_skip *sk, u64 ino, u64 gen)
{
    unsigned int k;

    for (k = 0; k < sk->n; k++)
        if (sk->ent[2 * k] == ino && sk->ent[2 * k + 1] == gen)
            return true;
    return false;
}

static bool cetrafs_flush_skip_add(struct cetrafs_flush_skip *sk, u64 ino, u64 gen)
{
    if (sk->n == sk->cap) {
        unsigned int cap = sk->cap ? sk->cap * 2 : 16;
        u64 *e = krealloc_array(sk->ent, (size_t) cap * 2, sizeof(*e), GFP_NOFS);

        if (!e)
            return false;
        sk->ent = e;
        sk->cap = cap;
    }
    sk->ent[2 * sk->n] = ino;
    sk->ent[2 * sk->n + 1] = gen;
    sk->n++;
    return true;
}

int cetrafs_deferred_flush_all(struct super_block *sb)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct list_head *orphans = cetrafs_sb_deferred_orphans(sb);
    unsigned long rounds = 0, orphan_rounds = 0, limit = 0, idx, cursor = 0;
    struct cetrafs_flush_skip skip = {0};
    bool wrapped = false, orphans_done = false;
    struct cetrafs_deferred *d;
    int ret = 0;

    if (!xa || !orphans)
        return cetrafs_journal_drain_retiring(sb);
    if (unlikely(READ_ONCE(cetrafs_flush_all_unhash_ino))) {
        struct inode *u = ilookup(sb, xchg(&cetrafs_flush_all_unhash_ino, 0));

        if (u) {
            remove_inode_hash(u); /* test-only: see the parameter */
            iput(u);
        }
    }
    /* Bounded by what is listed now: a writer still deferring blocks
     * must not keep a sync going for ever. */
    xa_lock(xa);
    xa_for_each(xa, idx, d)
        limit++;
    xa_unlock(xa);
    /*
     * One failing or unreachable set must not keep back every set after
     * it: the walk goes on past it from a cursor and returns the error at
     * the end (audit 2026-11-15 F-73). Passing over an owner already met
     * costs no round, so the bound counts only writes; the cursor goes
     * forward, and back to the start once, for a set listed behind it
     * meanwhile.
     */
    while (!xa_empty(xa) && rounds <= limit) {
        unsigned long first = cursor;
        struct inode *inode;
        bool orphan, is_orphan = false;
        u64 ino = 0, gen = 0;
        int r;

        /* A stopped mount writes nothing more, whatever the last set did. */
        if (cetrafs_sb_is_fenced(sb)) {
            if (!ret)
                ret = -EIO;
            break;
        }
        xa_lock(xa);
        orphan = !orphans_done && !list_empty(orphans);
        if (!orphan) {
            d = xa_find(xa, &first, ULONG_MAX, XA_PRESENT);
            if (!d && cursor && !wrapped) {
                wrapped = true;
                first = cursor = 0;
                d = xa_find(xa, &first, ULONG_MAX, XA_PRESENT);
            }
            ino = d ? d->ino : 0;
            gen = d ? d->generation : 0;
            is_orphan = d && d->orphan;
        }
        xa_unlock(xa);
        if (orphan) {
            /* The whole orphan list goes in one batch, owner by owner
             * (cetrafs_deferred_write_by_inode()). A failure there, or
             * a list that never empties, ends the orphan rounds; the
             * walk goes on over the live sets. */
            r = cetrafs_deferred_flush_list(sb, orphans, true);
            if (r) {
                if (!ret || ret == -EBUSY)
                    ret = r;
                orphans_done = true;
            } else if (++orphan_rounds > limit) {
                orphans_done = true;
            }
            continue;
        }
        if (!d)
            break;
        /* An orphan entry is on the list (both change under the lock
         * read above): the orphan rounds' to write, or over and left. */
        if (is_orphan || cetrafs_flush_skip_has(&skip, ino, gen)) {
            cursor = first + 1; /* left listed; go on past it */
            cond_resched();
            continue;
        }
        rounds++;
        /* Not an orphan, so in core -- unless it was evicted since,
         * and then it is an orphan on the next round. */
        inode = ilookup(sb, ino);
        if (inode && cetrafs_inode_get_generation(inode) != gen) {
            iput(inode); /* the number's new file: not this set's owner */
            inode = NULL;
        }
        if (!inode) {
            if (READ_ONCE(cetrafs_flush_all_skip_unhashed))
                continue; /* test-only: the old skip; see the parameter */
            r = cetrafs_deferred_unreachable(xa, first, ino, gen);
            if (!r)
                continue; /* orphaned meanwhile: the next round writes it */
            /* Left listed for its owner's close or eviction. The error is
             * the sync's answer, at the end. */
            if (!ret)
                ret = r;
            if (READ_ONCE(cetrafs_flush_all_stop_at_failure) || !cetrafs_flush_skip_add(&skip, ino, gen))
                break;
            cursor = first + 1;
            continue;
        }
        if (cetrafs_deferred_flush_no_inode)
            r = cetrafs_deferred_flush_list(sb, cetrafs_inode_deferred(inode), true); /* test-only */
        else
            r = cetrafs_deferred_flush_inode(inode, false);
        iput(inode);
        if (r == -ESTALE)
            r = 0; /* dropped: a peer's newer map, nothing of ours left to write */
        if (r) {
            /* Left listed: the next sync, or unmount, retries. */
            if (!ret || ret == -EBUSY)
                ret = r;
            if (READ_ONCE(cetrafs_flush_all_stop_at_failure) || !cetrafs_flush_skip_add(&skip, ino, gen))
                break;
            cursor = first + 1;
        }
    }
    kfree(skip.ent);
    /* Orphan rounds that ended with sets still on the list wrote none of
     * them: not a success. */
    if (!ret && orphans_done) {
        bool left;

        xa_lock(xa);
        left = !list_empty(orphans);
        xa_unlock(xa);
        if (left) {
            pr_warn("deferred: orphaned tree blocks stayed listed through this sync -- not written\n");
            ret = -EIO;
        }
    }
    /* The last batch's entries, live until a flush after their targets:
     * this point is where they are spent (journal.c). */
    {
        int dr = cetrafs_journal_drain_retiring(sb);

        if (ret && dr)
            pr_warn_ratelimited("deferred: the journal drain after a failed sync failed too (%d)\n", dr);
        return ret ? ret : dr;
    }
}

/*
 * A stopped mount writes nothing (docs/internal/ERRORS.md): its deferred
 * blocks are dropped, as its dirty ones are, and unmount releases what is
 * left the same way. Returns how many.
 */
unsigned long cetrafs_deferred_drop_all(struct super_block *sb)
{
    return cetrafs_deferred_unlist_range(sb, 0, ULONG_MAX, true);
}
