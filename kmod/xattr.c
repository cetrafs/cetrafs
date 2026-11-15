// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/buffer_head.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/stat.h>
#include <linux/string.h>
#include <linux/security.h>
#include <linux/xattr.h>

#include "kmod.h"

/* setxattr holds the file's namespace lock; the xattr pointer and flag
 * live in the record's namespace sector and are published by sector-0
 * CAS (v0x0005), composing with lock.c's concurrent presence traffic. */
struct cetrafs_xattr_ns_update {
    __le64 xattr_block;
    bool set_flag;
    u64 ctime;
    u64 seq; /* xattr_seq: drawn once, before the CAS, so a retry writes the same */
};

static void cetrafs_ns_apply_xattr(cetrafs_inode_t *rec, void *arg)
{
    struct cetrafs_xattr_ns_update *u = arg;

    rec->xattr_block = u->xattr_block;
    rec->xattr_seq = cetrafs_cpu_to_le64(u->seq);
    if (u->set_flag)
        rec->flags = cetrafs_cpu_to_le32(cetrafs_le32(rec->flags) | CETRAFS_INODE_XATTR);
    else
        rec->flags = cetrafs_cpu_to_le32(cetrafs_le32(rec->flags) & ~CETRAFS_INODE_XATTR);
    if (u->ctime)
        rec->ctime = cetrafs_cpu_to_le64(u->ctime);
}

/* An xattr change is a change of the inode: POSIX moves ctime, and
 * backup and sync tools (rsync -X, tar --xattrs, incremental dumps)
 * find changed files by it. A change that rewrote the xattr block in
 * place touched no record at all, so it moved nothing. */
static void cetrafs_ns_apply_ctime(cetrafs_inode_t *rec, void *arg)
{
    rec->ctime = cetrafs_cpu_to_le64(*(u64 *) arg);
}

/*
 * An xattr block is just a dense array of cetrafs_xattr_entry_t -- no
 * header needed, since (like cetrafs_dirent_t's inode==0) an empty
 * key[0]=='\0' already marks a free slot.
 */
#define CETRAFS_XATTR_ENTRIES_PER_BLOCK (CETRAFS_BLOCK_SIZE / sizeof(cetrafs_xattr_entry_t))

/*
 * True if this xattr block slot is unused -- an empty key, exactly like a
 * dirent with inode==0.
 */
static bool cetrafs_xattr_slot_free(const cetrafs_xattr_entry_t *e)
{
    return e->key[0] == '\0';
}

/* Linear scan of an xattr block's array for 'name' (already NUL-terminated,
 * < CETRAFS_XATTR_KEY_MAX long). Returns the slot index, or -ENODATA. */
static int cetrafs_xattr_find_slot(const cetrafs_xattr_entry_t *arr, const char *name)
{
    unsigned int i;

    for (i = 0; i < CETRAFS_XATTR_ENTRIES_PER_BLOCK; i++) {
        if (!cetrafs_xattr_slot_free(&arr[i]) && !strcmp(arr[i].key, name))
            return (int) i;
    }
    return -ENODATA;
}

/*
 * TEST ONLY: pause a lockless xattr read (get or list) between its read
 * of the record and its read of the xattr block the record names --
 * where a peer can free that block and another file can take it
 * (tests/kernel/xattr_read_vs_reuse.sh).
 */
static unsigned int cetrafs_xattr_read_pause_ms;
/* TEST ONLY: tear the next private copy of an xattr block, as a forced
 * -fresh re-read between the validation and the copy would
 * (tests/kernel/xattr_copy_revalidated.sh). */
static bool cetrafs_xattr_tear_copy_once;
cetrafs_test_param(xattr_tear_copy_once, cetrafs_xattr_tear_copy_once, bool, 0644);
MODULE_PARM_DESC(xattr_tear_copy_once, "TEST ONLY: tear the next private copy of an xattr block");

/* TEST ONLY: tear the next N private copies -- a block that never
 * converges (tests/kernel/xattr_read_giveup_time.sh). */
static int cetrafs_xattr_tear_copies;
cetrafs_test_param(xattr_tear_copies, cetrafs_xattr_tear_copies, int, 0644);
MODULE_PARM_DESC(xattr_tear_copies, "TEST ONLY: tear the next N private copies of an xattr block");
cetrafs_test_param(xattr_read_pause_ms, cetrafs_xattr_read_pause_ms, uint, 0644);
MODULE_PARM_DESC(xattr_read_pause_ms, "TEST ONLY: pause between an xattr read's record read and its block read");
/* TEST ONLY: the same, between the copy and the record re-read that
 * judges it (tests/kernel/xattr_read_seq_gate.sh). First attempt only. */
static unsigned int cetrafs_xattr_recheck_pause_ms;
cetrafs_test_param(xattr_recheck_pause_ms, cetrafs_xattr_recheck_pause_ms, uint, 0644);
MODULE_PARM_DESC(xattr_recheck_pause_ms, "TEST ONLY: pause between an xattr read's block copy and its record re-read");

/* TEST ONLY: a getxattr copies the block with no buffer lock -- the
 * negative control of tests/kernel/xattr_copy_torn.sh. */
static bool cetrafs_xattr_copy_unlocked;
cetrafs_test_param(xattr_copy_unlocked, cetrafs_xattr_copy_unlocked, bool, 0644);
MODULE_PARM_DESC(xattr_copy_unlocked, "TEST ONLY: a lockless xattr read copies its block with no buffer lock");
/* TEST ONLY: log every private copy of an xattr block that fails its
 * checksum for real (not an injected tear), so a test can count the
 * copies the buffer lock let through torn. */
static bool cetrafs_xattr_copy_probe;
cetrafs_test_param(xattr_copy_probe, cetrafs_xattr_copy_probe, bool, 0644);
MODULE_PARM_DESC(xattr_copy_probe, "TEST ONLY: log each xattr block copy that fails its checksum");
/* TEST ONLY: the first attempt of a lockless xattr read pauses between
 * validating the block and copying it -- the window an edit must start
 * in (tests/kernel/xattr_copy_torn.sh). */
static unsigned int cetrafs_xattr_copy_pause_ms;
cetrafs_test_param(xattr_copy_pause_ms, cetrafs_xattr_copy_pause_ms, uint, 0644);
MODULE_PARM_DESC(xattr_copy_pause_ms, "TEST ONLY: pause between an xattr read's validation and its copy");

static void cetrafs_xattr_read_pause(u64 ino)
{
    if (likely(!cetrafs_xattr_read_pause_ms))
        return;
    pr_info("xattr: ino=%llu pausing %ums between the record and the block\n", (unsigned long long) ino,
            cetrafs_xattr_read_pause_ms);
    msleep(cetrafs_xattr_read_pause_ms);
}

/*
 * The xattr block for a LOCKLESS reader (getxattr, listxattr), as a
 * private copy the caller kfree()s; *out stays NULL when the file has
 * none.
 *
 * Reading the record and then the block it names proves nothing about
 * the second read: a peer that removed this file's last xattr freed the
 * block in between, another file's setxattr could take it, and the
 * block read then finds a perfectly valid xattr block -- magic and
 * checksum intact -- that is somebody else's. So the record is read
 * fresh AGAIN after the block, and the copy is used only if the record
 * still names that block for this same file; otherwise start over.
 */
#define CETRAFS_XATTR_READ_RETRIES CETRAFS_BLK_TAIL_READ_RETRIES

/* TEST ONLY: setxattr's ctime stamp after an in-place block write fails. */
static bool cetrafs_xattr_ctime_cas_fail;
cetrafs_test_param(xattr_ctime_cas_fail, cetrafs_xattr_ctime_cas_fail, bool, 0644);
MODULE_PARM_DESC(xattr_ctime_cas_fail, "TEST ONLY: the ctime stamp after an in-place xattr write fails");

static int cetrafs_xattr_read_block(struct inode *inode, void **out)
{
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    void *copy = NULL;
    int attempt, ret;

    *out = NULL;
    for (attempt = 0; attempt < CETRAFS_XATTR_READ_RETRIES; attempt++) {
        struct buffer_head *bh;
        bool locked;
        u64 lba, seq;

        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
        ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
        if (ret)
            goto out;
        /* Fresh is not the same as MINE: a peer that unlinked the name
         * freed the number and the next create took it. Same check
         * unlink, rmdir, rename and link make. */
        if (cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(inode)) {
            pr_warn_ratelimited("xattr on ino=%llu refused: that number is a DIFFERENT file now (generation disk=%llu core=%llu)\n",
                                (unsigned long long) inode->i_ino,
                                (unsigned long long) cetrafs_le64(raw.generation),
                                (unsigned long long) cetrafs_inode_get_generation(inode));
            ret = -ESTALE;
            goto out;
        }
        lba = cetrafs_le64(raw.xattr_block);
        seq = cetrafs_le64(raw.xattr_seq);
        if (!lba) {
            ret = 0;
            goto out;
        }

        if (!attempt)
            cetrafs_xattr_read_pause(inode->i_ino);
        bh = cetrafs_blk_tail_bread(sb, lba, CETRAFS_XATTR_TAIL_MAGIC, "xattr");
        if (!bh) {
            ret = -EIO;
            goto out;
        }
        if (!copy) {
            copy = kmalloc(CETRAFS_BLOCK_SIZE, GFP_NOFS);
            if (!copy) {
                brelse(bh);
                ret = -ENOMEM;
                goto out;
            }
        }
        if (!attempt && READ_ONCE(cetrafs_xattr_copy_pause_ms))
            msleep(READ_ONCE(cetrafs_xattr_copy_pause_ms)); /* TEST ONLY: see the parameter */
        /* A whole image: this node's own xattr writers edit the cached
         * block in place under the buffer lock (cetrafs_bh_read_lock()). */
        /* The knob is read once: two reads could unbalance the lock. */
        locked = likely(!READ_ONCE(cetrafs_xattr_copy_unlocked));
        if (locked)
            cetrafs_bh_read_lock(bh);
        memcpy(copy, bh->b_data, CETRAFS_BLOCK_SIZE);
        if (locked)
            cetrafs_bh_read_unlock(bh);
        brelse(bh);
        /* The buffer was validated, then copied: another reader's
         * forced-fresh re-read of the same block can land in between and
         * put a peer's half-written image in the buffer. The copy is
         * what gets parsed, so the copy is what is checked (audit
         * 2026-11-06 L3); a torn one is retried like any other tear. */
        if (unlikely(cetrafs_xattr_tear_copy_once) && xchg(&cetrafs_xattr_tear_copy_once, false))
            ((u8 *) copy)[offsetof(cetrafs_xattr_entry_t, value)] ^= 0xff; /* TEST ONLY: see the parameter */
        if (unlikely(READ_ONCE(cetrafs_xattr_tear_copies) > 0)) {
            WRITE_ONCE(cetrafs_xattr_tear_copies, cetrafs_xattr_tear_copies - 1);
            ((u8 *) copy)[offsetof(cetrafs_xattr_entry_t, value)] ^= 0xff; /* TEST ONLY: see the parameter */
        }
        if (unlikely(READ_ONCE(cetrafs_xattr_copy_probe)) && !cetrafs_blk_image_valid(copy, CETRAFS_XATTR_TAIL_MAGIC))
            pr_info("xattr copy probe: block %llu copied torn\n", (unsigned long long) lba);
        if (cetrafs_tear_injected() || !cetrafs_blk_image_valid(copy, CETRAFS_XATTR_TAIL_MAGIC)) {
            if (attempt + 1 < CETRAFS_XATTR_READ_RETRIES) /* no sleep after the last */
                cetrafs_tear_backoff(attempt); /* a peer's write in flight: milliseconds (X1) */
            continue;
        }

        if (!attempt && READ_ONCE(cetrafs_xattr_recheck_pause_ms))
            msleep(READ_ONCE(cetrafs_xattr_recheck_pause_ms));
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
        ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
        if (ret)
            goto out;
        /* The stamp as well as the number: the number cycles (X4). */
        if (cetrafs_le64(raw.generation) == cetrafs_inode_get_generation(inode) &&
            cetrafs_le64(raw.xattr_block) == lba && cetrafs_le64(raw.xattr_seq) == seq) {
            *out = copy;
            return 0;
        }
        /* The record moved under the read: the copy may be anybody's.
         * A peer's setxattr in flight; give it the time it takes. */
        if (attempt + 1 < CETRAFS_XATTR_READ_RETRIES)
            cetrafs_tear_backoff(attempt);
    }
    pr_err_ratelimited("xattr on ino=%llu: its xattr block kept changing under %d reads -- giving up\n",
                       (unsigned long long) inode->i_ino, CETRAFS_XATTR_READ_RETRIES);
    ret = -EIO;
out:
    kfree(copy);
    return ret;
}

/*
 * Core getxattr: 'name' already has its namespace prefix (e.g. "user.foo"),
 * reconstructed by the caller via xattr_full_name(). size==0 is a size
 * query (buffer may be NULL); otherwise returns -ERANGE if buffer is too
 * small. Returns the value length on success, like vfs_getxattr().
 */
static int cetrafs_xattr_get(struct inode *inode, const char *name, void *buffer, size_t size)
{
    const cetrafs_xattr_entry_t *arr;
    void *blk;
    int idx, ret;
    u16 vlen;

    /* Another node may have (de)allocated this inode's xattr block at
     * any moment -- xattr ops never go through .open, so no lock pins
     * the record between our reads. See cetrafs_xattr_read_block(). */
    ret = cetrafs_xattr_read_block(inode, &blk);
    if (ret)
        return ret;
    if (!blk)
        return -ENODATA;
    arr = (const cetrafs_xattr_entry_t *) blk;

    idx = cetrafs_xattr_find_slot(arr, name);
    if (idx < 0) {
        ret = idx;
        goto out;
    }

    vlen = cetrafs_le16(arr[idx].value_len);
    if (size == 0) {
        ret = vlen;
        goto out;
    }
    if (size < vlen) {
        ret = -ERANGE;
        goto out;
    }
    memcpy(buffer, arr[idx].value, vlen);
    ret = vlen;
out:
    kfree(blk);
    return ret;
}

/*
 * security.capability's size (file.c, cetrafs_dio_may_strip_privs()): what
 * the VFS asks before a write strips privileges. -ENODATA when absent.
 */
int cetrafs_xattr_caps_size(struct inode *inode)
{
    return cetrafs_xattr_get(inode, "security.capability", NULL, 0);
}

/*
 * Core setxattr/removexattr (value==NULL means remove, matching
 * vfs_removexattr's call into handler->set()). 'name' is already the full
 * namespaced name, as in cetrafs_xattr_get(). Allocates the inode's one
 * xattr block on first use; frees it again if removing the last entry
 * empties it -- the same "revert when empty" shape as the extent leaf
 * block's depth-1->0 reversion in cetrafs_truncate_shrink(). Only ever one
 * block (no chaining), so a block that's full returns -ENOSPC, same scope
 * limit as the external extent leaf block.
 */
/* TEST ONLY, one-shot: pause right after a new xattr block is published in
 * the record -- the instant a node dying would leave the device in
 * (tests/kernel/xattr_block_bitmap_order.sh). Cleared by the pause. */
static unsigned int cetrafs_xattr_pause_after_publish_ms;
cetrafs_test_param(xattr_pause_after_publish_ms, cetrafs_xattr_pause_after_publish_ms, uint, 0644);
MODULE_PARM_DESC(xattr_pause_after_publish_ms, "TEST ONLY: one-shot pause after a new xattr block is published");

/* TEST ONLY: an in-place replace of an xattr entry is held half done --
 * its key and length are new, its value is still the old one -- while
 * the buffer lock is held (tests/kernel/xattr_copy_torn.sh). */
static unsigned int cetrafs_xattr_edit_stall_ms;
cetrafs_test_param(xattr_edit_stall_ms, cetrafs_xattr_edit_stall_ms, uint, 0644);
MODULE_PARM_DESC(xattr_edit_stall_ms, "TEST ONLY: stall halfway through an in-place xattr replace");

/* TEST ONLY: hold a setxattr between its first peer-user check and the
 * rest of the operation (audit 2026-11-11 X2). */
static unsigned int cetrafs_xattr_set_stall_ms;
cetrafs_test_param(xattr_set_stall_ms, cetrafs_xattr_set_stall_ms, uint, 0644);
MODULE_PARM_DESC(xattr_set_stall_ms, "TEST ONLY: one-shot pause after setxattr's first peer-user check");

/* TEST ONLY: the old setxattr -- no guard inside the swap, a regular
 * file's block edited in place (xattr_set_peer_late.sh's control). */
static bool cetrafs_xattr_swap_unguarded;
cetrafs_test_param(xattr_swap_unguarded, cetrafs_xattr_swap_unguarded, bool, 0644);
MODULE_PARM_DESC(xattr_swap_unguarded, "TEST ONLY: setxattr's swap asks nothing and a file's block is edited in place");

/*
 * What setxattr judged about the file's peers (regular files only:
 * nothing else can be open for write on another node).
 */
struct cetrafs_xattr_guard {
    bool on;
    u32 my_node_id;
    u32 judged_owner;
    u64 judged_readers;
};

/*
 * -ETXTBSY if a live peer holds this file's lock or has it open; 0 if
 * not. Asked at the start of a setxattr -- 'settle': a peer's
 * background mover is asked to yield and waited out, as nothing has
 * been read yet -- and again, without waiting, before the publish
 * (audit 2026-11-11 X2; a wait there would hold an allocated, unnamed
 * block through it: audit 2026-11-15 BM N-74).
 *
 * Neither ask is the last word: a peer's open takes no namespace lock,
 * and the publish is one or more device round trips after the second
 * ask. What the asks judged is therefore asked once more INSIDE the
 * publishing swap (cetrafs_xattr_guard_refuses()): the lock and presence
 * fields live in the same sector as the xattr pointer, so a lock or
 * presence neither ask judged refuses the publish atomically -- as
 * setattr's swap does (cetrafs_ns_apply_setattr()).
 */
static int cetrafs_xattr_peer_user(struct inode *inode, struct cetrafs_xattr_guard *g, bool settle)
{
    struct super_block *sb = inode->i_sb;
    bool blocked = false, reader = false;
    int ret;

    g->on = false;
    if (!S_ISREG(inode->i_mode))
        return 0;
    ret = cetrafs_sb_get_node_id(sb, &g->my_node_id);
    if (ret)
        return ret;
    g->judged_owner = CETRAFS_NODE_ID_NONE;
    g->judged_readers = 0;
    if (settle)
        ret = cetrafs_lock_foreign_user_settled(inode, g->my_node_id, &blocked, &reader, &g->judged_owner,
                                                &g->judged_readers);
    else
        ret = cetrafs_lock_foreign_user_judged(sb, inode->i_ino, g->my_node_id, &blocked, &reader, &g->judged_owner,
                                               &g->judged_readers);
    if (ret)
        return ret;
    if (blocked || reader)
        return -ETXTBSY;
    g->on = !READ_ONCE(cetrafs_xattr_swap_unguarded);
    return 0;
}

/* Inside the swap: a lock or presence on the live image the asks did not
 * judge. Per attempt -- a retry re-reads the image. */
static bool cetrafs_xattr_guard_refuses(const struct cetrafs_xattr_guard *g, const cetrafs_inode_t *rec)
{
    u64 mine = 1ULL << (g->my_node_id % CETRAFS_MAX_READER_NODES);
    u32 owner = cetrafs_le32(rec->lock_owner_node);

    if (!g->on)
        return false;
    if (cetrafs_lock_mode_held(cetrafs_le32(rec->lock_mode)) && owner != g->my_node_id && owner != g->judged_owner)
        return true;
    return (cetrafs_le64(rec->read_open_nodes) & ~mine & ~g->judged_readers) != 0;
}

/* TEST ONLY: a regular file's copy finds no free block (F-20), and the
 * old answer to that -- the call fails ENOSPC (the suite's control). */
static bool cetrafs_xattr_cow_nospc;
cetrafs_test_param(xattr_cow_nospc, cetrafs_xattr_cow_nospc, bool, 0644);
MODULE_PARM_DESC(xattr_cow_nospc, "TEST ONLY: a regular file's xattr copy finds no free block");
static bool cetrafs_xattr_cow_nospc_fails;
cetrafs_test_param(xattr_cow_nospc_fails, cetrafs_xattr_cow_nospc_fails, bool, 0644);
MODULE_PARM_DESC(xattr_cow_nospc_fails, "TEST ONLY: no block for the xattr copy fails the call (before F-20)");
static atomic64_t cetrafs_xattr_inplace_fallbacks = ATOMIC64_INIT(0);

u64 cetrafs_xattr_inplace_fallback_count(void)
{
    return (u64) atomic64_read(&cetrafs_xattr_inplace_fallbacks);
}

/* TEST ONLY: hold a setxattr after its second peer-user ask, right before
 * its publish (tests/kernel/xattr_set_peer_late.sh, audit 2026-11-15
 * BM N-74). One-shot. */
static unsigned int cetrafs_xattr_pre_publish_stall_ms;
cetrafs_test_param(xattr_pre_publish_stall_ms, cetrafs_xattr_pre_publish_stall_ms, uint, 0644);
MODULE_PARM_DESC(xattr_pre_publish_stall_ms, "TEST ONLY: one-shot pause between setxattr's second ask and its publish");

static void cetrafs_xattr_pre_publish_stall(void)
{
    if (unlikely(READ_ONCE(cetrafs_xattr_pre_publish_stall_ms)))
        msleep(xchg(&cetrafs_xattr_pre_publish_stall_ms, 0)); /* TEST ONLY */
}

/* The xattr pointer swap: refused, nothing applied, when the guard finds
 * a peer it did not judge, or when the live pointer is no longer the one
 * this operation decided from (the namespace lock was lost). */
struct cetrafs_xattr_ns_publish {
    struct cetrafs_xattr_guard *g;
    struct cetrafs_xattr_ns_update u;
    __le64 expect_block;
    int refused; /* 0, -ETXTBSY or -ESTALE: per attempt */
};

static void cetrafs_ns_apply_xattr_guarded(cetrafs_inode_t *rec, void *arg)
{
    struct cetrafs_xattr_ns_publish *p = arg;

    p->refused = 0;
    if (cetrafs_xattr_guard_refuses(p->g, rec)) {
        p->refused = -ETXTBSY;
        return;
    }
    if (rec->xattr_block != p->expect_block) {
        p->refused = -ESTALE;
        return;
    }
    cetrafs_ns_apply_xattr(rec, &p->u);
}

/* Publish xattr_block = 'lba' (0: none) over 'expect', guarded. */
static int cetrafs_xattr_publish(struct inode *inode, cetrafs_inode_t *raw, struct cetrafs_xattr_guard *g, u64 lba,
                                 u64 now)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_xattr_ns_publish p = {
        .g = g,
        .u = {.xattr_block = cetrafs_cpu_to_le64(lba), .set_flag = lba != 0, .ctime = now,
              .seq = cetrafs_inode_new_generation(sb)},
        .expect_block = raw->xattr_block,
    };
    int ret;

    ret = cetrafs_inode_ns_cas(sb, inode->i_ino, cetrafs_le64(raw->generation), raw, cetrafs_ns_apply_xattr_guarded,
                               &p);
    if (!ret && p.refused) {
        if (p.refused == -ETXTBSY)
            pr_info_ratelimited("setxattr: ino=%llu: a peer opened the file during the change -- refused, "
                                "nothing applied\n",
                                (unsigned long long) inode->i_ino);
        else
            pr_warn("setxattr: ino=%llu: its xattr pointer changed under the namespace lock -- refused\n",
                    (unsigned long long) inode->i_ino);
        ret = p.refused;
    }
    return ret;
}

/* A new xattr block holding 'img', written and durable, named by nothing
 * yet. On success *out_lba names it; on failure it is given back. */
static int cetrafs_xattr_write_new(struct super_block *sb, const void *img, u64 *out_lba)
{
    struct buffer_head *bh;
    u32 bg_id;
    u64 lba;
    int ret;

    ret = cetrafs_alloc_block_anywhere(sb, &bg_id, &lba);
    if (ret)
        return ret;
    bh = cetrafs_getblk_overwrite(sb, lba);
    if (!bh) {
        cetrafs_free_data_block(sb, lba);
        return -EIO;
    }
    memcpy(bh->b_data, img, CETRAFS_BLOCK_SIZE);
    cetrafs_blk_tail_stamp(bh, CETRAFS_XATTR_TAIL_MAGIC);
    ret = cetrafs_journal_write_new_block(sb, bh);
    brelse(bh);
    /* Written is not durable: on a volatile cache the record naming
     * this block could survive a power cut without it (rule 8; audit
     * 2026-11-06 L2). Nothing names it yet, so a refused flush gives
     * it back. */
    if (!ret)
        ret = cetrafs_publish_flush(sb);
    if (ret) {
        cetrafs_free_data_block(sb, lba);
        return ret;
    }
    *out_lba = lba;
    return 0;
}

/*
 * Apply set/remove of 'name' to the entry array 'arr' (a whole block).
 * 0, or -EEXIST/-ENODATA/-ENOSPC with 'arr' unchanged. *any_left: an
 * entry remains.
 */
static int cetrafs_xattr_edit(cetrafs_xattr_entry_t *arr, const char *name, const void *value, size_t size,
                              int flags, bool *any_left)
{
    unsigned int i;
    int idx = cetrafs_xattr_find_slot(arr, name);

    if (idx >= 0) {
        if (value && (flags & XATTR_CREATE))
            return -EEXIST;
        memset(&arr[idx], 0, sizeof(arr[idx]));
        if (value) {
            strscpy(arr[idx].key, name, CETRAFS_XATTR_KEY_MAX);
            arr[idx].value_len = cetrafs_cpu_to_le16((u16) size);
            if (unlikely(READ_ONCE(cetrafs_xattr_edit_stall_ms)))
                msleep(READ_ONCE(cetrafs_xattr_edit_stall_ms)); /* TEST ONLY: see the parameter */
            if (size)
                memcpy(arr[idx].value, value, size);
        }
    } else {
        int free_idx = -1;

        if (!value || (flags & XATTR_REPLACE))
            return -ENODATA;
        for (i = 0; i < CETRAFS_XATTR_ENTRIES_PER_BLOCK; i++) {
            if (cetrafs_xattr_slot_free(&arr[i])) {
                free_idx = (int) i;
                break;
            }
        }
        if (free_idx < 0)
            return -ENOSPC;
        strscpy(arr[free_idx].key, name, CETRAFS_XATTR_KEY_MAX);
        arr[free_idx].value_len = cetrafs_cpu_to_le16((u16) size);
        if (size)
            memcpy(arr[free_idx].value, value, size);
    }
    *any_left = false;
    for (i = 0; i < CETRAFS_XATTR_ENTRIES_PER_BLOCK; i++) {
        if (!cetrafs_xattr_slot_free(&arr[i])) {
            *any_left = true;
            break;
        }
    }
    return 0;
}

/*
 * Replace or drop the block 'raw' names: publish 'new_lba' (0: none) in
 * its place, then free the old one. Between the publish and the free the
 * old block is named by nothing and not yet free: announced first
 * (cetrafs_frees_begin()). A failed publish gives 'new_lba' back.
 */
static int cetrafs_xattr_swap_block(struct inode *inode, cetrafs_inode_t *raw, struct cetrafs_xattr_guard *g,
                                    u64 new_lba, u64 now)
{
    struct super_block *sb = inode->i_sb;
    u64 old_lba = cetrafs_le64(raw->xattr_block);
    bool foreign = !cetrafs_lba_run_is_ours(sb, old_lba, 1);
    int ret;

    ret = cetrafs_frees_begin(sb, &foreign);
    if (!ret) {
        cetrafs_xattr_pre_publish_stall();
        ret = cetrafs_xattr_publish(inode, raw, g, new_lba, now);
        if (ret)
            cetrafs_frees_end(sb, foreign);
    }
    if (ret) {
        if (new_lba)
            cetrafs_free_data_block(sb, new_lba);
        return ret;
    }
    /* The free must not reach the device ahead of the publish that
     * stopped naming the block (rule 21; audit 2026-11-06 L2). A
     * refused flush leaks it to the scrub rather than freeing a block
     * the durable record may still name. */
    if (cetrafs_publish_flush(sb)) {
        pr_err("setxattr: ino=%llu: the device refused a cache flush -- leaving xattr block %llu allocated "
               "for the scrub\n",
               (unsigned long long) inode->i_ino, (unsigned long long) old_lba);
        cetrafs_frees_end(sb, foreign);
        return 0;
    }
    cetrafs_free_data_block(sb, old_lba);
    cetrafs_frees_end(sb, foreign);
    return 0;
}

/* 'now': the ctime to stamp, in seconds; 0 stamps none. */
static int cetrafs_xattr_set_locked(struct inode *inode, const char *name, const void *value, size_t size, int flags,
                                    u64 now)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_xattr_guard g;
    cetrafs_inode_t raw;
    struct buffer_head *bh;
    cetrafs_xattr_entry_t *arr;
    size_t name_len = strlen(name);
    bool any_left;
    int ret;

    if (name_len >= CETRAFS_XATTR_KEY_MAX)
        return -ENAMETOOLONG;
    if (size > CETRAFS_XATTR_VALUE_MAX)
        return -E2BIG;

    /* found via ctest's new xattrs scenario on the real
     * two-node hardware: holding the namespace lock
     * serializes two nodes' xattr mutations, but deciding from a STALE
     * cached read inside that mutex still loses the race it was meant
     * to close -- node B, reading its old cached copy of the record,
     * sees xattr_block == 0 even though node A (microseconds earlier,
     * under the same mutex) just allocated one, so B allocates a second
     * block and its blind record write erases A's pointer: A's
     * attributes silently vanish and A's block leaks. The mutex is only
     * as good as the freshness of the read it protects. */
    /* CLAUDE.md cross-node review rules): a record
     * exclusively locked by a LIVE other node is that node's to write --
     * an xattr set rewrites the whole record, racing the holder's own
     * in-flight size/extent updates. Same refusal (and same stale-holder
     * journal-replay-then-proceed posture) as unlink and setattr. */
    /* The LOCK is not the only mark a live writer leaves. A node that
     * has SUSPENDED this file's automatic lock (lock.c, the handoff
     * window) is still writing it through an open fd and publishes
     * itself only in read_open_nodes -- so asking about the lock alone
     * lets this xattr set rewrite the record out from under exactly the
     * in-flight updates described above. Refuse on a peer READER too, as
     * unlink, rename, link and truncate already do: rewriting a whole
     * record is not something to do under any peer that has the file
     * open. Asked again before the publish, and inside it
     * (cetrafs_xattr_peer_user()). */
    ret = cetrafs_xattr_peer_user(inode, &g, true);
    if (ret)
        return ret;
    if (READ_ONCE(cetrafs_xattr_set_stall_ms))
        msleep(xchg(&cetrafs_xattr_set_stall_ms, 0)); /* TEST ONLY: see the parameter */

    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        return ret;

    /* Fresh is not the same as MINE. The read above is accurate and the
     * foreign-lock check above refuses a record a live peer owns, but
     * neither asks whether this number still belongs to the file this
     * node resolved. A peer that unlinked the name freed the number and
     * the next create took it; writing here then attaches this xattr to
     * an unrelated file (and rewrites its record). Same check unlink,
     * rmdir, rename and link make. */
    if (cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(inode)) {
        pr_warn_ratelimited("xattr on ino=%llu refused: that number is a DIFFERENT file now (generation disk=%llu core=%llu)\n",
                            (unsigned long long) inode->i_ino,
                            (unsigned long long) cetrafs_le64(raw.generation),
                            (unsigned long long) cetrafs_inode_get_generation(inode));
        return -ESTALE;
    }

    if (!raw.xattr_block) {
        void *img;
        u64 lba;

        if (!value || (flags & XATTR_REPLACE))
            return -ENODATA;
        img = kzalloc(CETRAFS_BLOCK_SIZE, GFP_NOFS);
        if (!img)
            return -ENOMEM;
        arr = img;
        strscpy(arr[0].key, name, CETRAFS_XATTR_KEY_MAX);
        arr[0].value_len = cetrafs_cpu_to_le16((u16) size);
        if (size)
            memcpy(arr[0].value, value, size);
        /* Asked again -- waiting a peer's mover out, as nothing is held
         * yet -- before the block is allocated (audit 2026-11-15 F-21);
         * the swap asks the last time. */
        ret = cetrafs_xattr_peer_user(inode, &g, true);
        if (!ret)
            ret = cetrafs_xattr_write_new(sb, img, &lba);
        kfree(img);
        if (ret)
            return ret;
        cetrafs_xattr_pre_publish_stall();
        ret = cetrafs_xattr_publish(inode, &raw, &g, lba, now);
        if (ret) {
            cetrafs_free_data_block(sb, lba);
            return ret;
        }
        {
            unsigned int pause = xchg(&cetrafs_xattr_pause_after_publish_ms, 0);

            if (pause)
                msleep(pause); /* test-only: see the parameter */
        }
        return 0;
    }

    /*
     * A regular file's block is replaced, not edited in place: the new
     * image goes to a new block, and the pointer swap that names it is
     * the one publish -- guarded inside the swap like the others. The
     * in-place write could not be: a 4 KiB blind write with no swap to
     * ask in, a read, a journal entry and two flushes after the last
     * ask, so a peer's open landing there had the file's attributes
     * changed under it (audit 2026-11-15 BM N-74). Other kinds keep the
     * in-place edit: nothing opens them for write on another node.
     */
    if (S_ISREG(inode->i_mode) && !READ_ONCE(cetrafs_xattr_swap_unguarded)) {
        void *img;
        u64 lba = 0;

        bh = cetrafs_blk_tail_bread(sb, cetrafs_le64(raw.xattr_block), CETRAFS_XATTR_TAIL_MAGIC, "xattr");
        if (!bh)
            return -EIO;
        img = kmalloc(CETRAFS_BLOCK_SIZE, GFP_NOFS);
        if (img) {
            cetrafs_bh_read_lock(bh);
            memcpy(img, bh->b_data, CETRAFS_BLOCK_SIZE);
            cetrafs_bh_read_unlock(bh);
        }
        brelse(bh);
        if (!img)
            return -ENOMEM;
        ret = cetrafs_xattr_edit(img, name, value, size, flags, &any_left);
        if (!ret)
            ret = cetrafs_xattr_peer_user(inode, &g, true);
        if (!ret && any_left)
            ret = READ_ONCE(cetrafs_xattr_cow_nospc) ? -ENOSPC : cetrafs_xattr_write_new(sb, img, &lba);
        kfree(img);
        /*
         * No block for the copy -- a full volume, or no free block in
         * this node's groups: edit in place instead, as before the copy
         * (audit 2026-11-15 F-20). Removing an attribute is how an
         * operator makes room, and it must not need room itself. That
         * path's write is not inside a swap, so a peer's open landing
         * during it is not refused: the window N-74 closed, open again
         * for exactly this case and said when it is taken.
         */
        if (ret == -ENOSPC && !READ_ONCE(cetrafs_xattr_cow_nospc_fails)) {
            atomic64_inc(&cetrafs_xattr_inplace_fallbacks);
            pr_info_ratelimited("setxattr: ino=%llu: no free block for the copy -- editing the xattr block in "
                                "place\n",
                                (unsigned long long) inode->i_ino);
            goto in_place;
        }
        if (ret)
            return ret;
        return cetrafs_xattr_swap_block(inode, &raw, &g, lba, now);
    }

in_place:

    /* The ask again before the edit: other kinds have no peer user to
     * judge (a no-op), and the TEST ONLY old order asks it here. */
    ret = cetrafs_xattr_peer_user(inode, &g, false);
    if (ret)
        return ret;
    if (S_ISREG(inode->i_mode))
        cetrafs_xattr_pre_publish_stall(); /* the old order's window */
    bh = cetrafs_blk_tail_bread(sb, cetrafs_le64(raw.xattr_block), CETRAFS_XATTR_TAIL_MAGIC, "xattr");
    if (!bh)
        return -EIO;
    /* Claim it before touching any entry -- see ioutil.c. An early exit
     * (-EEXIST, -ENODATA, -ENOSPC) has modified nothing and gives the
     * claim up with cetrafs_bh_abort_update(): nothing is written. */
    {
        const u32 prev_crc = cetrafs_bh_begin_update_crc(bh);

        ret = cetrafs_xattr_edit((cetrafs_xattr_entry_t *) bh->b_data, name, value, size, flags, &any_left);
        if (ret || !any_left) {
            /* the last entry gone: the block is freed, nothing written */
            cetrafs_bh_abort_update(bh);
            brelse(bh);
            if (ret)
                return ret;
            return cetrafs_xattr_swap_block(inode, &raw, &g, 0, now);
        }
        cetrafs_blk_tail_stamp(bh, CETRAFS_XATTR_TAIL_MAGIC);
        ret = cetrafs_journal_write_block(sb, cetrafs_journal_owner_of(inode), bh, prev_crc);
    }
    brelse(bh);
    if (ret || !now)
        return ret;
    /*
     * The block is on the device: the attribute IS set. A ctime stamp
     * that fails now cannot take that back, and reporting the call as
     * failed told the caller the opposite of what every reader then saw
     * (audit 2026-11-11 X5). Not stamped first either: a peer that saw
     * ctime move before the block would refresh its security label from
     * the old block and keep it. So the change stands and the missed
     * stamp is said -- peers key their label refresh on ctime, and may
     * serve the old one until the next change to this file.
     */
    ret = READ_ONCE(cetrafs_xattr_ctime_cas_fail)
              ? -EIO
              : cetrafs_inode_ns_cas(sb, inode->i_ino, cetrafs_le64(raw.generation), &raw, cetrafs_ns_apply_ctime, &now);
    if (ret)
        pr_warn_ratelimited("setxattr: ino=%llu: the attribute is set, but its change time could not be stamped "
                            "(%d) -- a peer may keep a stale security label until the file next changes\n",
                            (unsigned long long) inode->i_ino, ret);
    return 0;
}

/*
 * .listxattr: generic_listxattr() can't be used here -- it only handles
 * handlers with a fixed exact name (ACLs, security labels), not a
 * prefix-matched handler representing an arbitrary number of different
 * user.* keys, which is exactly what this format stores. So, like
 * ext2/ext4's own custom listxattr, this walks the xattr block directly
 * and emits each NUL-terminated name (prefix included). size==0 (or a NULL
 * buffer) is a size query -- matches vfs_listxattr()'s convention.
 *
 * Visibility is the matching handler's call: each name is emitted only
 * if xattr_handler_can_list() allows it, which is how trusted.* stays
 * hidden from callers without CAP_SYS_ADMIN (ext4 does the same inside
 * its own listxattr walk). Before this the handlers' .list hooks were
 * dead code -- this walk never consulted them, so an unprivileged
 * getfattr saw trusted.* names while the handler comment claimed they
 * were hidden. tests/kernel/xattr_semantics.sh asserts both directions.
 */
static const struct xattr_handler *cetrafs_xattr_match_handler(const char *key)
{
    int i;

    for (i = 0; cetrafs_xattr_handlers[i]; i++) {
        const char *p = cetrafs_xattr_handlers[i]->prefix;

        if (!strncmp(key, p, strlen(p)))
            return cetrafs_xattr_handlers[i];
    }
    return NULL; /* unknown prefix: never listed (can_list(NULL) is false) */
}
ssize_t cetrafs_listxattr(struct dentry *dentry, char *list, size_t size)
{
    struct inode *inode = d_inode(dentry);
    const cetrafs_xattr_entry_t *arr;
    size_t total = 0;
    unsigned int i;

    if (cetrafs_sb_is_fenced(inode->i_sb))
        return -EIO;
    void *blk;
    int ret;

    ret = cetrafs_xattr_read_block(inode, &blk); /* same rules as xattr_get above */
    if (ret)
        return ret;
    if (!blk)
        return 0;
    arr = (const cetrafs_xattr_entry_t *) blk;

    for (i = 0; i < CETRAFS_XATTR_ENTRIES_PER_BLOCK; i++) {
        size_t len;

        if (cetrafs_xattr_slot_free(&arr[i]))
            continue;
        if (!xattr_handler_can_list(cetrafs_xattr_match_handler(arr[i].key), dentry))
            continue;
        len = strlen(arr[i].key) + 1; /* NUL included */
        if (list && size) {
            if (total + len > size) {
                kfree(blk);
                return -ERANGE;
            }
            memcpy(list + total, arr[i].key, len);
        }
        total += len;
    }
    kfree(blk);
    return (ssize_t) total;
}

static int cetrafs_xattr_handler_get(const struct xattr_handler *handler,
                                     struct dentry *dentry,
                                     struct inode *inode,
                                     const char *name,
                                     void *buffer,
                                     size_t size)
{
    if (cetrafs_sb_is_fenced(inode->i_sb))
        return -EIO;
    return cetrafs_xattr_get(inode, xattr_full_name(handler, name), buffer, size);
}

/*
 * Xattr mutation used to take NO cross-node
 * synchronization at all -- not dir.c's namespace cluster mutex (this
 * file never called it) and not lock.c's exclusive file lock either
 * (the VFS never calls .open for setxattr, so that lock can't cover
 * it). Two nodes setting xattrs on the same inode concurrently raced
 * each other on the lazily-allocated xattr_block pointer in the raw
 * inode (both allocate, one block leaks and one set of attributes
 * silently vanishes) and on the xattr entry-array block's own RMW.
 * Bracketed in the same per-inode namespace lock (nslock.c) every
 * dirent mutation already uses -- an xattr set is namespace-shaped
 * metadata mutation (rare, whole-op, cross-node contended), exactly what
 * that lock exists for; here it is held on the inode itself, which is
 * both the record carrying the xattr_block pointer and the object whose
 * xattr block is rewritten. Same-node concurrency is already serialized above
 * us by the VFS (vfs_setxattr holds the inode lock). This bracketing
 * is also what makes journaled xattr-block writes safe to replay from
 * a crashed node's journal: a surviving entry implies the crash
 * happened while holding this lock, so no one else can have modified
 * the block since (see journal.c's header comment).
 */
/* TEST ONLY: a nested xattr set acquires the namespace lock again, as it
 * did before the nesting check below -- the negative control of
 * tests/kernel/xattr_strip_nested.sh, which then hangs on itself. */
static bool cetrafs_xattr_nested_wait;
cetrafs_test_param(xattr_nested_wait, cetrafs_xattr_nested_wait, bool, 0644);
MODULE_PARM_DESC(xattr_nested_wait, "TEST ONLY: a xattr set nested in a setattr waits on the namespace lock it holds");

static int cetrafs_xattr_set(struct inode *inode, const char *name, const void *value, size_t size, int flags)
{
    struct inode *set[] = {inode}; /* the inode's own record + its xattr block */
    /* The caller may already hold this inode's namespace lock. A write that
     * strips security.capability reaches here from setattr_prepare()'s
     * killpriv, inside cetrafs_setattr(), which holds the lock; acquiring it
     * again waits on ourselves forever (the write hung in D state). The
     * outer operation holds the lock and persists the record it changes, so
     * the nested set runs under that lock and does not take it again. */
    bool nested = !READ_ONCE(cetrafs_xattr_nested_wait) && cetrafs_inode_ns_held_by_current(inode);
    /* security.* is also set by IMA/EVM from __fput(), whose return
     * nobody reads: that one waits in the lock (nslock.c). */
    int ret = 0;

    if (!nested) {
        ret = strncmp(name, XATTR_SECURITY_PREFIX, XATTR_SECURITY_PREFIX_LEN)
                  ? cetrafs_nslock_acquire_set_vfs(set, ARRAY_SIZE(set))
                  : cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set));
        if (ret)
            return ret;
    }

    {
        u64 now = (u64) ktime_get_real_seconds();

        ret = cetrafs_xattr_set_locked(inode, name, value, size, flags, now);
        if (!ret)
            inode_set_ctime(inode, (time64_t) now, 0);
    }
    if (!nested)
        cetrafs_nslock_release_set(set, ARRAY_SIZE(set));
    return ret;
}

static int cetrafs_xattr_handler_set(const struct xattr_handler *handler,
                                     struct mnt_idmap *idmap,
                                     struct dentry *dentry,
                                     struct inode *inode,
                                     const char *name,
                                     const void *value,
                                     size_t size,
                                     int flags)
{
    return cetrafs_xattr_set(inode, xattr_full_name(handler, name), value, size, flags);
}

/* user.* xattrs are only meaningful on regular files and directories -- same
 * restriction as ext2/ext4's xattr_user_handler. */
static bool cetrafs_xattr_user_list(struct dentry *dentry)
{
    umode_t mode = d_inode(dentry)->i_mode;

    return S_ISREG(mode) || S_ISDIR(mode);
}

static const struct xattr_handler cetrafs_xattr_user_handler = {
    .prefix = XATTR_USER_PREFIX,
    .list = cetrafs_xattr_user_list,
    .get = cetrafs_xattr_handler_get,
    .set = cetrafs_xattr_handler_set,
};

/*
 * trusted.* -- root only, enforced by the VFS's own xattr_permission()
 * before it ever reaches a handler. Listed only to a caller with
 * CAP_SYS_ADMIN, same as ext2/ext4, so an ordinary `getfattr -d` does
 * not advertise attributes it cannot read.
 *
 * Here because overlayfs will not use a filesystem as an UPPER layer
 * unless it can store trusted.overlay.*.
 */
static bool cetrafs_xattr_trusted_list(struct dentry *dentry)
{
    return capable(CAP_SYS_ADMIN);
}

static const struct xattr_handler cetrafs_xattr_trusted_handler = {
    .prefix = XATTR_TRUSTED_PREFIX,
    .list = cetrafs_xattr_trusted_list,
    .get = cetrafs_xattr_handler_get,
    .set = cetrafs_xattr_handler_set,
};

/*
 * security.* -- always listed; which callers may read or write one is
 * the LSM's decision, not this filesystem's.
 *
 * Here because a host running SELinux in ENFORCING mode labels files
 * through security.selinux. A filesystem that cannot store it leaves
 * every file with whatever an unlabelled filesystem's default policy
 * allows, which for a VM-image store is likely nothing -- so the
 * deployment had to run permissive or give the whole mount a blanket
 * context.
 */
static const struct xattr_handler cetrafs_xattr_security_handler = {
    .prefix = XATTR_SECURITY_PREFIX,
    .get = cetrafs_xattr_handler_get,
    .set = cetrafs_xattr_handler_set,
};

const struct xattr_handler *const cetrafs_xattr_handlers[] = {
    &cetrafs_xattr_user_handler,
    &cetrafs_xattr_trusted_handler,
    &cetrafs_xattr_security_handler,
    NULL,
};

/*
 * Let the active LSM stamp a newly created inode.
 *
 * Without this the hook never fires, so a new file lands with no
 * security label at all and only a later restorecon gives it one --
 * which on a shared VM-image store means every image is created
 * inaccessible until someone remembers. Called from dir.c's create,
 * mkdir and symlink once the new inode exists and BEFORE its name is
 * added to the parent, so a failure unwinds through the path those
 * already have.
 *
 * The attributes go in through cetrafs_xattr_set_locked() rather than
 * the locking wrapper: the inode is freshly allocated and not yet named
 * by any directory entry, so no peer can see it and there is nothing to
 * exclude. Taking its namespace lock would cost two compare-and-swaps
 * per create to protect an object no one else can reach.
 */
static int cetrafs_initxattrs(struct inode *inode, const struct xattr *xattr_array, void *fs_info)
{
    const struct xattr *xattr;
    int ret = 0;

    for (xattr = xattr_array; xattr->name != NULL; xattr++) {
        char name[CETRAFS_XATTR_KEY_MAX];

        if (snprintf(name, sizeof(name), "%s%s", XATTR_SECURITY_PREFIX, xattr->name) >= (int) sizeof(name))
            return -ERANGE;
        /* now = 0: a new inode's ctime is already its creation time,
         * and stamping it again would cost a swap per label. */
        ret = cetrafs_xattr_set_locked(inode, name, xattr->value, xattr->value_len, 0, 0);
        if (ret)
            break;
    }
    return ret;
}

int cetrafs_init_security(struct inode *inode, struct inode *dir, const struct qstr *qstr)
{
    return security_inode_init_security(inode, dir, qstr, &cetrafs_initxattrs, NULL);
}
