// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * nslock.c -- the per-inode namespace lock.
 *
 * Replaces the device-wide cluster mutex that used to bracket every
 * namespace mutation. That mutex was correct but maximally coarse: one
 * node creating a file in directory A blocked another node renaming
 * something in unrelated directory B, for the duration -- and on real
 * hardware each acquire/release pair cost two SCSI round trips (~95 ms
 * measured). This lock is instead taken on the single inode whose
 * record/dirents the operation actually mutates, so unrelated operations
 * never contend at all, and it is taken by one atomic compare-and-swap
 * of that inode's own CAS sector.
 *
 * Scope rule (who gets locked):
 *   create/mkdir/symlink/link/unlink/rmdir -> the PARENT DIRECTORY
 *   rename                                 -> BOTH parents
 *   setattr / setxattr                     -> the FILE ITSELF
 * i.e. always the inode whose on-disk state the operation changes.
 *
 * Deadlock freedom: the only multi-lock operation is rename, and
 * cetrafs_nslock_acquire_two() always takes the lower inode number
 * first, so no two nodes (or threads) can hold one and want the other in
 * opposite order. Lock ordering against the other cluster primitives is
 * "namespace lock first, cluster mutex second" -- journal replay and the
 * pending-free drain take the PR mutex while holding no namespace lock,
 * and nothing takes a namespace lock while holding the PR mutex.
 *
 * Crash recovery: this is a HELD lock, so a node that dies mid-operation
 * leaves it set. A waiter that finds the holder's Node Registry row
 * stale (node.c) replays that node's journal -- repairing whatever it
 * was mid-writing, exactly as the ZG-steal and file-lock-reclaim paths
 * do -- and only then CASes the lock away from it. A merely-slow holder
 * is the same documented split-brain window as every other stale-based
 * reclaim here, mitigated by self-fencing.
 *
 * Local serialization: the on-disk lock arbitrates between NODES. Two
 * threads on THIS node are serialized first by a per-inode local mutex,
 * so they never fight over the same on-disk cell.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/string.h>
#include <linux/timekeeping.h>

#include "kmod.h"

/* How long to keep trying before declaring the holder wedged. A
 * namespace operation is short (a few metadata writes), so a healthy
 * holder releases well inside this; exceeding it means either a dead
 * holder (handled by the staleness check below, which runs on every
 * attempt) or genuinely heavy contention on one directory. */
#define CETRAFS_NSLOCK_RETRIES 600
#define CETRAFS_NSLOCK_SLEEP_MS 20

/* Release retry budget. With cetrafs_write_vfs_inode() now dropping its
 * dirt on a record whose namespace lock we hold, nothing should touch
 * this record while we hold it, so the release compare-and-swap commits
 * on the first try; this is only a bound on the pathological case so a
 * genuinely wedged record cannot block a releasing thread indefinitely.
 * On exhaustion we leave the lock for stale-reclaim (recoverable) rather
 * than clobber the record (silent corruption). */
#define CETRAFS_NSLOCK_RELEASE_RETRIES 100

/* No-hold-and-wait budget for multi-lock sets (acquire_set). A node
 * taking several locks must not block on a contended LATER lock while
 * pinning the EARLIER ones: with the root directory in nearly every
 * set, that let one contended inode hold root for the whole single-lock
 * budget (~12s), stalling every node's namespace work and surfacing as
 * "could not acquire ... holder not releasing". So each lock gets a
 * SHORT per-round budget; on contention we release everything, back off,
 * and retry the whole ordered set, so no lock is held more than
 * SET_TRIES*SLEEP_MS (~160ms) while we wait on another. The total across
 * rounds is on the order of the single-lock budget, so genuine
 * contention still resolves before the operation gives up. */
#define CETRAFS_NSLOCK_SET_TRIES 8
#define CETRAFS_NSLOCK_SET_ROUNDS 40

struct cetrafs_nslock_ctx {
    u32 my_node_id;
    u64 generation;
    bool acquire;
    bool steal; /* acquire: allowed to displace steal_from */
    u32 steal_from;
    u32 clobbered; /* release: set if the lock was no longer ours */
    u64 dbg_ino;   /* DEBUG: for the DSHRINK probe below */

    /* The operation's final update to this record, published by the
     * same compare-and-swap that clears the lock rather than by a
     * separate synchronous write. NULL when the operation had nothing
     * to update (a read-only check, or a record it did not touch). */
    const cetrafs_inode_t *staged;
    u32 staged_nlink_base; /* device nlink when 'staged' was captured; publish applies (staged.nlink - base) as a delta */
    struct super_block *sb; /* for fresh dirent_seq stamps at publish */
};

static int cetrafs_nslock_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_nslock_ctx *ctx = priv;
    cetrafs_inode_t rec;

    /* v0x0005: the image is the record's NAMESPACE SECTOR (512 bytes),
     * the CAS unit. The file sector is out of reach by construction --
     * a staged record's file-domain half is published by the release's
     * sector-1 write BEFORE this swap (see cetrafs_nslock_release()),
     * making the dirent_seq this swap lands the publish barrier. */
    if (len < CETRAFS_INODE_NS_BYTES)
        return -EINVAL;
    memset(&rec, 0, sizeof(rec));
    memcpy(&rec, image, CETRAFS_INODE_NS_BYTES);

    if (cetrafs_le64(rec.generation) != ctx->generation)
        return -ESTALE; /* inode number reused for a different file */

    if (ctx->acquire) {
        bool free_now = (cetrafs_le32(rec.ns_lock_owner) == CETRAFS_NODE_ID_NONE);
        bool mine_already = (cetrafs_le32(rec.ns_lock_owner) == ctx->my_node_id);
        bool stealable = ctx->steal && cetrafs_le32(rec.ns_lock_owner) == ctx->steal_from;

        /* "Already ours" is reachable only as leftover state from a
         * previous incarnation of this node (we crashed holding it and
         * remounted onto the same registry row): the per-inode local
         * mutex guarantees no live local holder. Taking it back is
         * correct and is what keeps a self-crash from wedging us out of
         * our own directories forever. */
        if (!free_now && !mine_already && !stealable)
            return -EBUSY;

        rec.ns_lock_owner = cetrafs_cpu_to_le32(ctx->my_node_id);
    } else {
        if (cetrafs_le32(rec.ns_lock_owner) != ctx->my_node_id) {
            /* Anomalous: the generation still matches, so this is the
             * same live record we locked, yet the lock is no longer
             * ours -- a peer wrongly judged us stale and stole it. Say
             * so loudly rather than treating it as a quiet no-op. */
            ctx->clobbered = cetrafs_le32(rec.ns_lock_owner);
            return 1;
        }
        /* Publish the operation's own NAMESPACE-sector updates in this
         * same swap. The staged copy's ns fields win over 'image' --
         * we hold the lock, so no OTHER namespace operation may have
         * touched them -- with two exceptions applied against the LIVE
         * image precisely because their writers do NOT hold this lock:
         *
         *  - nlink is a cross-node accumulator: apply the staged change
         *    as a DELTA to the image's current value (a peer's delta
         *    since we staged lives there and must survive);
         *  - the file-lock fields and read-presence bits belong to
         *    lock.c's own CAS traffic, which runs without the namespace
         *    lock -- keep the image's.
         */
        if (ctx->staged) {
            long delta = (long) cetrafs_le32(ctx->staged->nlink) - (long) ctx->staged_nlink_base;
            long live = (long) cetrafs_le32(rec.nlink) + delta;

            if (live < 0)
                live = 0;
            rec.mode = ctx->staged->mode;
            rec.uid = ctx->staged->uid;
            rec.gid = ctx->staged->gid;
            rec.ctime = ctx->staged->ctime;
            rec.xattr_block = ctx->staged->xattr_block;
            /* The staged dirent_seq is published as-is: it is only ever
             * written under THIS directory's namespace lock, which we
             * hold from acquire through this release, so no peer can
             * have bumped it since we staged -- and publishing our own
             * cached value is what keeps the single-writer O(1) steady
             * state (tests/kernel/create_scaling.sh). */
            rec.dirent_seq = ctx->staged->dirent_seq;
            rec.nlink = cetrafs_cpu_to_le32((u32) live);
        }
        rec.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
    }

    cetrafs_inode_stamp_crc_ns(&rec);
    memcpy(image, &rec, CETRAFS_INODE_NS_BYTES);
    return 0;
}

/* One acquire attempt. Returns 0 on success, -EBUSY if a live peer holds
 * it, or another errno. */
static int cetrafs_nslock_try(struct inode *inode, u32 my_node_id)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_nslock_ctx ctx = {.my_node_id = my_node_id, .acquire = true};
    cetrafs_inode_t raw;
    int ret;

    /* Read fresh: the holder may be any node, so a cached copy says
     * nothing (CLAUDE.md cross-node review rule #1). */
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        return ret;

    ctx.generation = cetrafs_le64(raw.generation);

    if (cetrafs_le32(raw.ns_lock_owner) != CETRAFS_NODE_ID_NONE && cetrafs_le32(raw.ns_lock_owner) != my_node_id) {
        bool stale = false;

        ret = cetrafs_node_is_stale(sb, cetrafs_le32(raw.ns_lock_owner), &stale);
        if (ret || !stale) {
            /* Either a live holder, or we could not tell. Both mean
             * "wait and try again" -- never fail the caller's operation.
             * Failing here turned a transient read error into a plain
             * create() returning EIO, and only on whichever node LOST
             * the lock race, since this path is reached exactly when
             * some OTHER node holds the lock. */
            return -EBUSY;
        }

        /* Dead holder: repair whatever it was mid-writing BEFORE taking
         * the lock, so nobody builds on a half-finished operation. */
        cetrafs_node_fence_peer(sb, cetrafs_le32(raw.ns_lock_owner), "a namespace lock");
        ret = cetrafs_journal_replay_node(sb, cetrafs_le32(raw.ns_lock_owner), /*wait_for_claim=*/false);
        if (ret)
            return ret;

        pr_warn("nslock: ino=%llu breaking a namespace lock held by stale node %u\n", (unsigned long long) inode->i_ino,
                raw.ns_lock_owner);
        ctx.steal = true;
        ctx.steal_from = cetrafs_le32(raw.ns_lock_owner);
    }

    /* The CAS is the acquire: it only lands if the record still shows
     * exactly the state this decision was made against. */
    /* Seeded with the copy just read above -- saves re-reading the
     * same record inside the CAS (cetrafs_cas_region_seeded()). */
    return cetrafs_cas_record_seeded(sb, cetrafs_inode_lba(sb, inode->i_ino), &raw, CETRAFS_INODE_NS_BYTES, cetrafs_nslock_mutate,
                                     &ctx);
}

/*
 * Take the namespace lock on 'inode' with a caller-chosen try budget.
 * Returns 0 holding both the local mutex and the on-disk lock; -EBUSY
 * (holding neither) if the budget ran out while a live peer held it; or
 * another errno (holding neither). The -EBUSY case is SILENT -- the
 * caller decides whether exhaustion is terminal (a single acquire) or a
 * cue to back off and retry the whole set (acquire_set).
 */
static int cetrafs_nslock_acquire_tries(struct inode *inode, int max_tries)
{
    struct super_block *sb = inode->i_sb;
    u32 my_node_id;
    int attempt, ret;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced: no namespace mutation at all */

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret)
        return ret;

    cetrafs_inode_ns_mutex_lock(inode);

    for (attempt = 0; attempt < max_tries; attempt++) {
        ret = cetrafs_nslock_try(inode, my_node_id);
        if (ret != -EBUSY) {
            if (!ret) {
                ctrace("NSHOLD ino=%llu ACQ\n", (unsigned long long) inode->i_ino);
                cetrafs_inode_ns_holder_set(inode, true);
            }
            if (ret)
                cetrafs_inode_ns_mutex_unlock(inode);
            return ret;
        }
        msleep(CETRAFS_NSLOCK_SLEEP_MS);
    }
    cetrafs_inode_ns_mutex_unlock(inode);
    return -EBUSY;
}

/*
 * Take the namespace lock on a single 'inode'. Blocks (sleeping) while a
 * live peer holds it, for the full retry budget. Returns 0 holding both
 * the local mutex and the on-disk lock, or an errno holding neither.
 */
int cetrafs_nslock_acquire(struct inode *inode)
{
    int ret = cetrafs_nslock_acquire_tries(inode, CETRAFS_NSLOCK_RETRIES);

    if (ret == -EBUSY)
        pr_err("nslock: ino=%llu could not acquire the namespace lock (holder not releasing and not stale)\n",
               (unsigned long long) inode->i_ino);
    return ret;
}

void cetrafs_nslock_release(struct inode *inode)
{
    ctrace("NSHOLD ino=%llu REL\n", (unsigned long long) inode->i_ino);
    cetrafs_inode_ns_holder_set(inode, false);
    struct super_block *sb = inode->i_sb;
    struct cetrafs_nslock_ctx ctx = {.acquire = false, .clobbered = CETRAFS_NODE_ID_NONE};
    ctx.dbg_ino = inode->i_ino;
    cetrafs_inode_t *recs; /* [0]=raw, [1]=staged: 2 KiB, off the stack */
    bool have_staged, staged_fd = false;
    int ret, attempt;

    recs = kmalloc(2 * sizeof(*recs), GFP_NOFS);
    if (!recs) {
        pr_err("nslock: ino=%llu release: out of memory -- leaving the lock for stale-reclaim\n",
               (unsigned long long) inode->i_ino);
        cetrafs_inode_ns_mutex_unlock(inode);
        return;
    }

    have_staged = cetrafs_inode_take_staged_record(inode, &recs[1], &staged_fd);
    if (have_staged) {
        ctx.staged = &recs[1];
        ctx.staged_nlink_base = cetrafs_inode_staged_nlink_base(inode);
    }
    ctx.sb = sb;

    ret = cetrafs_sb_get_node_id(sb, &ctx.my_node_id);
    if (ret) {
        /* Cannot even identify ourselves -- cannot safely touch the
         * record. Leave the lock for stale-reclaim rather than guess. */
        pr_err("nslock: ino=%llu release: no node id (%d) -- leaving lock\n", (unsigned long long) inode->i_ino, ret);
        cetrafs_inode_ns_mutex_unlock(inode);
        kfree(recs);
        return;
    }

    /*
     * Step 1 of the two-step publish (v0x0005): a staged record that
     * changed FILE-domain fields -- a directory grown or shrunk by this
     * operation -- lands its file sector FIRST, while we still hold the
     * lock. The sector-0 swap below then publishes dirent_seq, which is
     * the freshness barrier peers gate on: nobody trusts the new dirent
     * state before the sector that describes it is on the device.
     */
    if (have_staged && staged_fd) {
        ret = cetrafs_write_raw_inode_fd(sb, inode->i_ino, &recs[1], inode);
        if (ret)
            pr_err("nslock: ino=%llu staged file-sector publish failed (%d) -- size/extents lag the dirents "
                   "(fsck-visible, repaired by -r)\n",
                   (unsigned long long) inode->i_ino, ret);
    }

    /*
     * Retry the delta-CAS until it COMMITS. The lock is ours, so the
     * only reasons the swap does not land are transient -- a concurrent
     * writeback rewriting size/mtime on this same record (a miscompare)
     * or a device hiccup -- and re-reading fresh and re-applying the
     * DELTA to whatever the device now holds converges on the right
     * value.
     *
     * There is deliberately NO blind-absolute-write fallback. The old
     * one wrote the staged record whole on CAS failure, which was two
     * bugs in one: (1) staged.nlink is this operation's ABSOLUTE
     * pre-delta value, so writing it discarded any accumulator change a
     * peer made meanwhile -- an inode left nlink one too high, surfacing
     * as "allocated but no directory entry names it"; and (2) the staged
     * image still carries ns_lock_owner == us, so the write re-published
     * our ownership and RE-ORPHANED the very lock the release exists to
     * clear -- "could not acquire ... holder not releasing". Both caught
     * on a 3-node nofilelock run. Retrying the CAS clears the
     * lock and publishes the delta exactly once; on genuine exhaustion we
     * leave the lock (reclaimable once our registry row goes stale) and
     * the dirent already on disk (reconciled by fsck/scrub) -- both
     * recoverable, which silent nlink corruption is not.
     */
    for (attempt = 0; attempt < CETRAFS_NSLOCK_RELEASE_RETRIES; attempt++) {
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
        ret = cetrafs_read_raw_inode(sb, inode->i_ino, &recs[0]);
        if (!ret) {
            ctx.generation = cetrafs_le64(recs[0].generation);
            ctx.clobbered = CETRAFS_NODE_ID_NONE;
            ret = cetrafs_cas_record_seeded(sb, cetrafs_inode_lba(sb, inode->i_ino), &recs[0], CETRAFS_INODE_NS_BYTES,
                                            cetrafs_nslock_mutate, &ctx);
        }
        /* 0: published and lock cleared. -ESTALE: the inode's number was
         * reused for a different file, so there is nothing of ours left
         * to clear (the normal outcome when the bracketed op deleted this
         * very inode). 1: the lock is no longer ours -- a peer judged us
         * stale and stole it; our staged update is forfeit, which is
         * correct because that peer has already replayed our journal. */
        if (ret == 0 || ret == -ESTALE || ret == 1)
            break;
        msleep(CETRAFS_NSLOCK_SLEEP_MS);
    }

    if (ret == 1 && ctx.clobbered != CETRAFS_NODE_ID_NONE)
        pr_warn("nslock: ino=%llu namespace lock was no longer ours at release (now %u) -- a peer judged us stale and "
                "took it\n",
                (unsigned long long) inode->i_ino, ctx.clobbered);
    else if (ret < 0 && ret != -ESTALE)
        pr_err("nslock: ino=%llu release did not commit after %d attempts (%d) -- leaving the lock for stale-reclaim "
               "rather than clobbering the record\n",
               (unsigned long long) inode->i_ino, CETRAFS_NSLOCK_RELEASE_RETRIES, ret);

    cetrafs_inode_ns_mutex_unlock(inode);
    kfree(recs);
}

/*
 * Acquire the namespace lock on a SET of inodes -- every inode whose
 * on-disk record the operation is about to mutate.
 *
 * Locking only the parent directory would not be enough. Several
 * namespace operations modify a second record too, and two nodes can
 * reach the same second record through different parents:
 *   - unlink: parent dirents AND the child's nlink. Two nodes unlinking
 *     two hardlinks of one file, from two different directories, would
 *     lock different parents and both read-modify-write that file's
 *     nlink -- a lost update, meaning a file freed while a name still
 *     points at it, or one that never gets freed.
 *   - rmdir: the victim directory is itself a lockable parent, so a peer
 *     can be mid-create inside the very directory we are freeing.
 *   - rename: both parents, the moved inode (its '..'), and a replaced
 *     target.
 * The device-wide mutex this replaces covered all of that for free by
 * covering everything; the scoped lock has to name the set explicitly.
 *
 * Deadlock freedom comes from a total order: always acquire by
 * ascending inode number. Duplicates (the same inode named twice, e.g.
 * a rename within one directory) are skipped -- taking one twice would
 * self-deadlock on the local mutex.
 */
int cetrafs_nslock_acquire_set(struct inode **inodes, int n)
{
    struct inode *ordered[CETRAFS_NSLOCK_MAX_SET];
    int count = 0, i, j, ret, round;

    if (n > CETRAFS_NSLOCK_MAX_SET)
        return -EINVAL;

    for (i = 0; i < n; i++) {
        if (!inodes[i])
            continue;
        for (j = 0; j < count; j++)
            if (ordered[j]->i_ino == inodes[i]->i_ino)
                break;
        if (j == count)
            ordered[count++] = inodes[i];
    }

    /* Insertion sort by inode number: count is at most 4. */
    for (i = 1; i < count; i++) {
        struct inode *key = ordered[i];

        for (j = i - 1; j >= 0 && ordered[j]->i_ino > key->i_ino; j--)
            ordered[j + 1] = ordered[j];
        ordered[j + 1] = key;
    }

    for (round = 0; round < CETRAFS_NSLOCK_SET_ROUNDS; round++) {
        for (i = 0; i < count; i++) {
            /* Short per-lock budget: a contended later lock must not pin
             * the earlier ones (hold-and-wait). */
            ret = cetrafs_nslock_acquire_tries(ordered[i], CETRAFS_NSLOCK_SET_TRIES);
            if (ret)
                break;
        }
        if (i == count)
            return 0; /* got the whole set */

        /* Release everything we did get (ordered[0 .. i-1]); the lock at
         * ordered[i] was not acquired. */
        while (--i >= 0)
            cetrafs_nslock_release(ordered[i]);

        if (ret != -EBUSY)
            return ret; /* a hard error (fenced, read failure) -- do not spin */

        /* Contended: back off and retry the whole ordered set, holding
         * nothing in the meantime. */
        msleep(CETRAFS_NSLOCK_SLEEP_MS);
    }

    pr_err("nslock: could not acquire a %d-inode namespace set after %d rounds -- heavy directory contention\n", count,
           CETRAFS_NSLOCK_SET_ROUNDS);
    return -EBUSY;
}

void cetrafs_nslock_release_set(struct inode **inodes, int n)
{
    struct inode *ordered[CETRAFS_NSLOCK_MAX_SET];
    int count = 0, i, j;

    if (n > CETRAFS_NSLOCK_MAX_SET)
        return;

    for (i = 0; i < n; i++) {
        if (!inodes[i])
            continue;
        for (j = 0; j < count; j++)
            if (ordered[j]->i_ino == inodes[i]->i_ino)
                break;
        if (j == count)
            ordered[count++] = inodes[i];
    }

    for (i = 1; i < count; i++) {
        struct inode *key = ordered[i];

        for (j = i - 1; j >= 0 && ordered[j]->i_ino > key->i_ino; j--)
            ordered[j + 1] = ordered[j];
        ordered[j + 1] = key;
    }

    /* Reverse order, mirroring acquire. */
    for (i = count - 1; i >= 0; i--)
        cetrafs_nslock_release(ordered[i]);

    /* Free-count deltas batched by this operation (alloc.c/zonegroup.c)
     * are made durable here -- the namespace operation's durability
     * boundary, exactly as the old cetrafs_ns_unlock() was.
     *
     * Once per OPERATION, not once per lock: each flush is a synchronous
     * write of every dirty BG descriptor and ZG record, which on a real
     * LUN is tens of milliseconds. Doing it inside
     * cetrafs_nslock_release() meant unlink paid it twice (parent +
     * victim) and rename up to four times, for deltas that are identical
     * by the end of the operation anyway. */
    if (count)
        cetrafs_flush_dirty_free_counts(ordered[0]->i_sb);
}
