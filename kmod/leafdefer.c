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
    u32 disk_crc; /* CRC32C of the block as it reads on the device */
    /* On its inode's list, or on the mount's orphan list once the inode
     * was evicted; under the xarray's lock. A boundary walks only its
     * own inode's (leafdefer review 2026-11-08, item 3). */
    struct list_head node;
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

/* Is 'd' on 'head'? Under the xarray lock. Only for the adoption count:
 * an inode's list is its own handful of blocks. */
static bool cetrafs_deferred_on_list(struct cetrafs_deferred *d, struct list_head *head)
{
    struct cetrafs_deferred *e;

    list_for_each_entry(e, head, node)
        if (e == d)
            return true;
    return false;
}

int cetrafs_bh_defer_update(struct inode *inode, struct buffer_head *bh, u32 prev_crc)
{
    struct xarray *xa = cetrafs_sb_deferred(inode->i_sb);
    struct cetrafs_deferred *d, *old;

    if (!xa)
        return -EINVAL;
    if (buffer_cetra_deferred(bh)) {
        bool listed;

        /* The bit and the listing change together under the buffer
         * lock, which this update holds, so a set bit means listed --
         * with the device's image. Confirmed, not trusted: a bit without
         * its listing would leave this edit written by nothing. */
        xa_lock(xa);
        old = xa_load(xa, bh->b_blocknr);
        listed = old && old->bh == bh;
        /* ...and listed on THIS inode's list. An entry its inode's
         * eviction moved to the mount's orphans (a boundary that failed)
         * is written only at sync_fs or unmount, so this edit would miss
         * the reopened file's own fsync and close, and a split's shrunk
         * source leaf would miss the batch its destination goes in
         * (cetrafs_convert_source_durable()). Bring it home: unlist and
         * settle find it through the xarray from either list. */
        if (listed) {
            if (old->ino != inode->i_ino || !cetrafs_deferred_on_list(old, cetrafs_inode_deferred(inode)))
                atomic64_inc(&cetrafs_deferred_adopted);
            list_move_tail(&old->node, cetrafs_inode_deferred(inode));
            old->ino = inode->i_ino;
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
    WARN_ON_ONCE(buffer_dirty(bh));
    /* Cannot fail: a block not listed would have to be written now, and
     * a leaf written ahead of its index is the ordering this exists to
     * keep (cetrafs_convert_source_durable()). 24 bytes. */
    d = kmalloc(sizeof(*d), GFP_NOFS | __GFP_NOFAIL);
    d->bh = bh;
    d->ino = inode->i_ino;
    d->disk_crc = prev_crc;
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
                                    u32 **crcs, unsigned int *n)
{
    struct cetrafs_deferred *d;
    unsigned int cnt = 0, i = 0;

    *out = NULL;
    *crcs = NULL;
    *n = 0;
    xa_lock(xa);
    list_for_each_entry(d, head, node)
        cnt++;
    xa_unlock(xa);
    if (!cnt)
        return 0;
    *out = kvmalloc_array(cnt, sizeof(**out), GFP_NOFS);
    *crcs = kvmalloc_array(cnt, sizeof(**crcs), GFP_NOFS);
    if (!*out || !*crcs) {
        kvfree(*out);
        kvfree(*crcs);
        *out = NULL;
        *crcs = NULL;
        return -ENOMEM;
    }
    xa_lock(xa);
    list_for_each_entry(d, head, node) {
        if (i == cnt)
            break; /* listed since the count: the next boundary's */
        get_bh(d->bh);
        (*out)[i] = d->bh;
        (*crcs)[i] = d->disk_crc;
        i++;
    }
    xa_unlock(xa);
    *n = i;
    return 0;
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
    list_for_each_entry(d, cetrafs_inode_deferred(inode), node)
        n++;
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
static bool cetrafs_deferred_flush_no_inode;
cetrafs_test_param(deferred_flush_no_inode, cetrafs_deferred_flush_no_inode, bool, 0644);
MODULE_PARM_DESC(deferred_flush_no_inode, "TEST ONLY: flush held-back blocks without looking up their inode");

static int cetrafs_deferred_write_set(struct super_block *sb, struct buffer_head **bhs, u32 *crcs, unsigned int n,
                                      bool no_inode)
{
    bool *written;
    u32 *wcrc;
    unsigned int i;
    int ret;

    written = kvcalloc(n, sizeof(*written), GFP_NOFS);
    wcrc = kvcalloc(n, sizeof(*wcrc), GFP_NOFS);
    if (!written || !wcrc) {
        kvfree(written);
        kvfree(wcrc);
        return -ENOMEM;
    }
    ret = cetrafs_journal_write_deferred(sb, bhs, crcs, n, written, wcrc);
    if (unlikely(cetrafs_deferred_settle_stall_ms) && no_inode) {
        pr_info("deferred: TEST pause of %ums between the target writes and the settle (inode not in core)\n",
                cetrafs_deferred_settle_stall_ms);
        msleep(cetrafs_deferred_settle_stall_ms);
    }
    for (i = 0; i < n; i++)
        if (written[i])
            cetrafs_bh_deferred_settle(sb, bhs[i], wcrc[i]);
    kvfree(written);
    kvfree(wcrc);
    return ret;
}

/* TEST ONLY: an inode flush writes nothing and reports success, so its
 * close lets the inode go with blocks still held back and an eviction
 * orphans them (tests/kernel/deferred_orphan_adopted.sh). A failed flush
 * cannot stage that: the close that failed pins the inode until a retry
 * has flushed the tree. */
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
int cetrafs_deferred_flush_inode(struct inode *inode, bool mapping_locked)
{
    struct super_block *sb = inode->i_sb;
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct buffer_head **bhs;
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
    ret = cetrafs_deferred_collect(xa, cetrafs_inode_deferred(inode), &bhs, &crcs, &n);
    if (!ret && n)
        ret = cetrafs_deferred_write_set(sb, bhs, crcs, n, false);
    if (!mapping_locked)
        filemap_invalidate_unlock_shared(inode->i_mapping);
    for (i = 0; i < n; i++)
        brelse(bhs[i]);
    kvfree(bhs);
    kvfree(crcs);
    return ret;
}

static int cetrafs_deferred_flush_list(struct super_block *sb, struct list_head *head, bool no_inode)
{
    struct buffer_head **bhs;
    unsigned int n, i;
    u32 *crcs;
    int r;

    r = cetrafs_deferred_collect(cetrafs_sb_deferred(sb), head, &bhs, &crcs, &n);
    if (!r && n)
        r = cetrafs_deferred_write_set(sb, bhs, crcs, n, no_inode);
    for (i = 0; i < n; i++)
        brelse(bhs[i]);
    kvfree(bhs);
    kvfree(crcs);
    return r;
}

/*
 * sync_fs and unmount: every deferred block on the mount. The orphans of
 * evicted inodes first -- nothing in core can edit them but a reopen,
 * and a block edited after its write stays listed (the settle) -- then
 * each inode in core, under its own lock.
 */
int cetrafs_deferred_flush_all(struct super_block *sb)
{
    struct xarray *xa = cetrafs_sb_deferred(sb);
    struct list_head *orphans = cetrafs_sb_deferred_orphans(sb);
    unsigned long rounds = 0, limit = 0, idx;
    struct cetrafs_deferred *d;
    int ret = 0;

    if (!xa || !orphans)
        return 0;
    /* Bounded by what is listed now: a writer still deferring blocks
     * must not keep a sync going for ever. */
    xa_lock(xa);
    xa_for_each(xa, idx, d)
        limit++;
    xa_unlock(xa);
    while (!xa_empty(xa) && rounds++ <= limit) {
        unsigned long first = 0;
        struct inode *inode;
        bool orphan;
        u64 ino = 0;
        int r;

        xa_lock(xa);
        orphan = !list_empty(orphans);
        if (!orphan) {
            d = xa_find(xa, &first, ULONG_MAX, XA_PRESENT);
            ino = d ? d->ino : 0;
        }
        xa_unlock(xa);
        if (orphan) {
            r = cetrafs_deferred_flush_list(sb, orphans, true);
        } else if (!ino) {
            break;
        } else {
            /* Not an orphan, so in core -- unless it was evicted since,
             * and then it is an orphan on the next round. */
            inode = ilookup(sb, ino);
            if (!inode)
                continue;
            if (cetrafs_deferred_flush_no_inode)
                r = cetrafs_deferred_flush_list(sb, cetrafs_inode_deferred(inode), true); /* test-only */
            else
                r = cetrafs_deferred_flush_inode(inode, false);
            iput(inode);
        }
        if (r) {
            ret = r;
            break; /* left listed: the next sync, or unmount, retries */
        }
    }
    return ret;
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
