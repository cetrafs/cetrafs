// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/buffer_head.h>
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
};

static void cetrafs_ns_apply_xattr(cetrafs_inode_t *rec, void *arg)
{
    struct cetrafs_xattr_ns_update *u = arg;

    rec->xattr_block = u->xattr_block;
    if (u->set_flag)
        rec->flags = cetrafs_cpu_to_le32(cetrafs_le32(rec->flags) | CETRAFS_INODE_XATTR);
    else
        rec->flags = cetrafs_cpu_to_le32(cetrafs_le32(rec->flags) & ~CETRAFS_INODE_XATTR);
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
 * Core getxattr: 'name' already has its namespace prefix (e.g. "user.foo"),
 * reconstructed by the caller via xattr_full_name(). size==0 is a size
 * query (buffer may be NULL); otherwise returns -ERANGE if buffer is too
 * small. Returns the value length on success, like vfs_getxattr().
 */
static int cetrafs_xattr_get(struct inode *inode, const char *name, void *buffer, size_t size)
{
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    struct buffer_head *bh;
    const cetrafs_xattr_entry_t *arr;
    int idx, ret;
    u16 vlen;

    /* Another node may have (de)allocated this inode's xattr block at
     * any moment -- xattr ops never go through .open, so no lock pins
     * the record between our reads. Force the one read that locates the
     * xattr block to be fresh (same reasoning as every other
     * read-shared-state-first path in this codebase). */
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
    if (!raw.xattr_block)
        return -ENODATA;

    bh = cetrafs_blk_tail_bread(sb, cetrafs_le64(raw.xattr_block), CETRAFS_XATTR_TAIL_MAGIC, "xattr");
    if (!bh)
        return -EIO;
    arr = (const cetrafs_xattr_entry_t *) bh->b_data;

    idx = cetrafs_xattr_find_slot(arr, name);
    if (idx < 0) {
        brelse(bh);
        return idx;
    }

    vlen = cetrafs_le16(arr[idx].value_len);
    if (size == 0) {
        brelse(bh);
        return vlen;
    }
    if (size < vlen) {
        brelse(bh);
        return -ERANGE;
    }
    memcpy(buffer, arr[idx].value, vlen);
    brelse(bh);
    return vlen;
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
static int cetrafs_xattr_set_locked(struct inode *inode, const char *name, const void *value, size_t size, int flags)
{
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    struct buffer_head *bh;
    cetrafs_xattr_entry_t *arr;
    size_t name_len = strlen(name);
    unsigned int i;
    int idx, ret;
    bool any_left;

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
    if (S_ISREG(inode->i_mode)) {
        u32 my_node_id = 0;
        bool blocked = false;

        ret = cetrafs_sb_get_node_id(sb, &my_node_id);
        if (ret)
            return ret;
        /* The LOCK is not the only mark a live writer leaves. A node
         * that has SUSPENDED this file's automatic lock (lock.c, the
         * handoff window) is still writing it through an open fd and
         * publishes itself only in read_open_nodes -- so asking about
         * the lock alone lets this xattr set rewrite the record out from
         * under exactly the in-flight updates described above. Refuse on
         * a peer READER too, as unlink, rename, link and truncate
         * already do: rewriting a whole record is not something to do
         * under any peer that has the file open. */
        bool reader = false;

        ret = cetrafs_lock_foreign_user_exists(sb, inode->i_ino, my_node_id, &blocked, &reader);
        if (ret)
            return ret;
        if (blocked || reader)
            return -ETXTBSY;
    }

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
        u64 lba;
        u32 bg_id;

        if (!value || (flags & XATTR_REPLACE))
            return -ENODATA;

        ret = cetrafs_alloc_block_anywhere(sb, &bg_id, &lba);
        if (ret)
            return ret;
        bh = cetrafs_getblk_overwrite(sb, lba);
        if (!bh) {
            cetrafs_free_data_block(sb, lba);
            return -EIO;
        }
        memset(bh->b_data, 0, CETRAFS_BLOCK_SIZE);
        arr = (cetrafs_xattr_entry_t *) bh->b_data;
        strscpy(arr[0].key, name, CETRAFS_XATTR_KEY_MAX);
        arr[0].value_len = cetrafs_cpu_to_le16((u16) size);
        if (size)
            memcpy(arr[0].value, value, size);

        cetrafs_blk_tail_stamp(bh, CETRAFS_XATTR_TAIL_MAGIC);
        ret = cetrafs_journal_write_new_block(sb, bh);
        brelse(bh);
        if (ret) {
            cetrafs_free_data_block(sb, lba);
            return ret;
        }

        {
            struct cetrafs_xattr_ns_update u = {.xattr_block = cetrafs_cpu_to_le64(lba), .set_flag = true};

            ret = cetrafs_inode_ns_cas(sb, inode->i_ino, cetrafs_le64(raw.generation), &raw,
                                       cetrafs_ns_apply_xattr, &u);
        }
        if (ret) {
            cetrafs_free_data_block(sb, lba);
            return ret;
        }
        return 0;
    }

    bh = cetrafs_blk_tail_bread(sb, cetrafs_le64(raw.xattr_block), CETRAFS_XATTR_TAIL_MAGIC, "xattr");
    if (!bh)
        return -EIO;
    /* Claim it before touching any entry -- see ioutil.c. (On the
     * -EEXIST path below nothing is modified and the buffer is simply
     * rewritten with identical content, which is harmless.) */
    const u32 prev_crc = cetrafs_bh_begin_update_crc(bh);
    arr = (cetrafs_xattr_entry_t *) bh->b_data;

    idx = cetrafs_xattr_find_slot(arr, name);
    if (idx >= 0) {
        if (!value) {
            memset(&arr[idx], 0, sizeof(arr[idx]));
        } else if (flags & XATTR_CREATE) {
            cetrafs_bh_abort_update(bh);
            brelse(bh);
            return -EEXIST;
        } else {
            memset(&arr[idx], 0, sizeof(arr[idx]));
            strscpy(arr[idx].key, name, CETRAFS_XATTR_KEY_MAX);
            arr[idx].value_len = cetrafs_cpu_to_le16((u16) size);
            if (size)
                memcpy(arr[idx].value, value, size);
        }
    } else {
        int free_idx = -1;

        if (!value) {
            cetrafs_bh_abort_update(bh);
            brelse(bh);
            return -ENODATA;
        }
        if (flags & XATTR_REPLACE) {
            cetrafs_bh_abort_update(bh);
            brelse(bh);
            return -ENODATA;
        }
        for (i = 0; i < CETRAFS_XATTR_ENTRIES_PER_BLOCK; i++) {
            if (cetrafs_xattr_slot_free(&arr[i])) {
                free_idx = (int) i;
                break;
            }
        }
        if (free_idx < 0) {
            cetrafs_bh_abort_update(bh);
            brelse(bh);
            return -ENOSPC;
        }
        strscpy(arr[free_idx].key, name, CETRAFS_XATTR_KEY_MAX);
        arr[free_idx].value_len = cetrafs_cpu_to_le16((u16) size);
        if (size)
            memcpy(arr[free_idx].value, value, size);
    }

    any_left = false;
    for (i = 0; i < CETRAFS_XATTR_ENTRIES_PER_BLOCK; i++) {
        if (!cetrafs_xattr_slot_free(&arr[i])) {
            any_left = true;
            break;
        }
    }

    if (!any_left) {
        u64 old_lba = cetrafs_le64(raw.xattr_block);

        /* The block is about to be freed, so there is nothing worth
         * publishing -- just give up the claim. */
        cetrafs_bh_abort_update(bh);
        brelse(bh);
        {
            struct cetrafs_xattr_ns_update u = {.xattr_block = 0, .set_flag = false};

            ret = cetrafs_inode_ns_cas(sb, inode->i_ino, cetrafs_le64(raw.generation), &raw,
                                       cetrafs_ns_apply_xattr, &u);
        }
        if (ret)
            return ret;
        cetrafs_free_data_block(sb, old_lba);
        return 0;
    }

    cetrafs_blk_tail_stamp(bh, CETRAFS_XATTR_TAIL_MAGIC);
    ret = cetrafs_journal_write_block(sb, bh, prev_crc);
    brelse(bh);
    return ret;
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
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    struct buffer_head *bh;
    const cetrafs_xattr_entry_t *arr;
    size_t total = 0;
    unsigned int i;
    int ret;

    cetrafs_invalidate_raw_inode(sb, inode->i_ino); /* same freshness rule as xattr_get above */
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        return ret;
    if (!raw.xattr_block)
        return 0;

    bh = cetrafs_blk_tail_bread(sb, cetrafs_le64(raw.xattr_block), CETRAFS_XATTR_TAIL_MAGIC, "xattr");
    if (!bh)
        return -EIO;
    arr = (const cetrafs_xattr_entry_t *) bh->b_data;

    for (i = 0; i < CETRAFS_XATTR_ENTRIES_PER_BLOCK; i++) {
        size_t len;

        if (cetrafs_xattr_slot_free(&arr[i]))
            continue;
        if (!xattr_handler_can_list(cetrafs_xattr_match_handler(arr[i].key), dentry))
            continue;
        len = strlen(arr[i].key) + 1; /* NUL included */
        if (list && size) {
            if (total + len > size) {
                brelse(bh);
                return -ERANGE;
            }
            memcpy(list + total, arr[i].key, len);
        }
        total += len;
    }
    brelse(bh);
    return (ssize_t) total;
}

static int cetrafs_xattr_handler_get(const struct xattr_handler *handler,
                                     struct dentry *dentry,
                                     struct inode *inode,
                                     const char *name,
                                     void *buffer,
                                     size_t size)
{
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
static int cetrafs_xattr_set(struct inode *inode, const char *name, const void *value, size_t size, int flags)
{
    struct inode *set[] = {inode}; /* the inode's own record + its xattr block */
    int ret = cetrafs_nslock_acquire_set(set, ARRAY_SIZE(set));

    if (ret)
        return ret;

    ret = cetrafs_xattr_set_locked(inode, name, value, size, flags);
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
        ret = cetrafs_xattr_set_locked(inode, name, xattr->value, xattr->value_len, 0);
        if (ret)
            break;
    }
    return ret;
}

int cetrafs_init_security(struct inode *inode, struct inode *dir, const struct qstr *qstr)
{
    return security_inode_init_security(inode, dir, qstr, &cetrafs_initxattrs, NULL);
}
