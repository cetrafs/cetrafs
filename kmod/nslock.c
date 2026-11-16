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
 * simple because the others are not held across one: journal replay
 * serialises on its per-area claim and the pending-free drain on the
 * queue region's CAS, neither while holding a namespace lock, and
 * nothing takes a namespace lock while inside either.
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
#include <linux/jiffies.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/task_work.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/string.h>
#include <linux/timekeeping.h>

#include <linux/moduleparam.h>
#include <asm/syscall.h>

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
static atomic64_t cetrafs_nslock_restarts = ATOMIC64_INIT(0);

u64 cetrafs_nslock_restart_count(void)
{
    return (u64) atomic64_read(&cetrafs_nslock_restarts);
}

/* Budgets a silent holder extended instead of ending in EBUSY (M-17). */
static atomic64_t cetrafs_nslock_silent_extends = ATOMIC64_INIT(0);

u64 cetrafs_nslock_silent_extend_count(void)
{
    return (u64) atomic64_read(&cetrafs_nslock_silent_extends);
}

#define CETRAFS_NSLOCK_SET_TRIES 8
#define CETRAFS_NSLOCK_SET_ROUNDS 40

struct cetrafs_nslock_ctx {
    u32 my_node_id;
    u64 generation;
    bool acquire;
    bool steal; /* acquire: allowed to displace steal_from */
    u32 steal_from;
    u32 steal_incarnation; /* acquire: ... at the incarnation judged (F10) */
    u32 my_incarnation;    /* acquire: what the lock is stamped with */
    bool took_over;        /* acquire: the swap took a lock that was SET -- a dead peer's, an
                            * earlier incarnation's, or a release of ours that never committed */
    bool owed;             /* acquire: the record carries CETRAFS_INODE_COUNT_UNVERIFIED */
    u32 clobbered; /* release: who held it, when it was no longer ours */
    bool not_ours; /* release: it was no longer ours -- the verdict. Not
                    * clobbered != NONE: a lock found CLEARED has
                    * clobbered == NONE, which read as "fine". */
    u64 dbg_ino;   /* DEBUG: for the DSHRINK probe below */

    /* The operation's final update to this record, published by the
     * same compare-and-swap that clears the lock rather than by a
     * separate synchronous write. NULL when the operation had nothing
     * to update (a read-only check, or a record it did not touch). */
    const cetrafs_inode_t *staged;
    u32 staged_nlink_base; /* device nlink when 'staged' was captured; publish applies (staged.nlink - base) as a delta */
    struct super_block *sb; /* for fresh dirent_seq stamps at publish */
};

/*
 * Test-only: make the namespace-lock release fail to commit, as a
 * transient device error would. The consequence -- a live node holding
 * a lock nobody else can take -- is not otherwise reachable.
 */
static bool cetrafs_nslock_release_fail;
cetrafs_test_param(nslock_release_fail, cetrafs_nslock_release_fail, bool, 0644);
MODULE_PARM_DESC(nslock_release_fail, "TEST ONLY: namespace-lock releases do not commit");

/*
 * Test-only: hold every namespace lock this long after acquiring it, so
 * a test can make the heartbeat's deferred-release retry fire while a
 * local operation holds the lock.
 */
/*
 * Test-only: every read of the record inside a release fails, as a
 * device error would. The deferred retry then has only what the
 * release knew before it read anything.
 */
static bool cetrafs_nslock_release_read_fail;
cetrafs_test_param(nslock_release_read_fail, cetrafs_nslock_release_read_fail, bool, 0644);
MODULE_PARM_DESC(nslock_release_read_fail, "TEST ONLY: a namespace-lock release cannot read the record");

/* TEST ONLY: hold a deferred-release retry pass this long inside its
 * bracket, so a local acquire waits on it (tests/kernel/retry_and_claim_waits.sh). */
static unsigned int cetrafs_nslock_retry_stall_ms;
cetrafs_test_param(nslock_retry_stall_ms, cetrafs_nslock_retry_stall_ms, uint, 0644);
MODULE_PARM_DESC(nslock_retry_stall_ms, "TEST ONLY: stall a namespace-lock release retry pass while it holds its bracket");

/* TEST ONLY: a lock taken over from a stopped holder is not followed by
 * the recount -- the negative control of tests/kernel/ns_count_reconcile.sh. */
static bool cetrafs_nslock_reconcile_off;
cetrafs_test_param(nslock_reconcile_off, cetrafs_nslock_reconcile_off, bool, 0644);
MODULE_PARM_DESC(nslock_reconcile_off, "TEST ONLY: no recount after taking over a namespace lock");

/* TEST ONLY, the negative controls of tests/kernel/ns_recount_fail_retry.sh
 * (the failure itself is dir.c's nslock_recount_fail). With recount_fail_release a
 * failed recount takes the path it took before the flag: the inode
 * marked damaged and the lock released over a count nobody re-derives;
 * with unverified_ignore an acquirer does not honour the flag. The
 * suite's two negative controls. */
static bool cetrafs_nslock_recount_fail_release;
cetrafs_test_param(nslock_recount_fail_release, cetrafs_nslock_recount_fail_release, bool, 0644);
MODULE_PARM_DESC(nslock_recount_fail_release, "TEST ONLY: a failed recount marks the inode damaged and releases");
static bool cetrafs_nslock_unverified_ignore;
cetrafs_test_param(nslock_unverified_ignore, cetrafs_nslock_unverified_ignore, bool, 0644);
MODULE_PARM_DESC(nslock_unverified_ignore, "TEST ONLY: an acquire does not recount a record flagged unverified");

static void cetrafs_ns_apply_unverified(cetrafs_inode_t *rec, void *arg)
{
    u32 f = cetrafs_le32(rec->flags);

    rec->flags = cetrafs_cpu_to_le32(*(const bool *) arg ? f | CETRAFS_INODE_COUNT_UNVERIFIED
                                                         : f & ~CETRAFS_INODE_COUNT_UNVERIFIED);
}

/* Set or clear CETRAFS_INODE_COUNT_UNVERIFIED; the caller holds the lock. */
int cetrafs_ns_set_unverified(struct super_block *sb, u64 ino, u64 generation, bool set)
{
    return cetrafs_inode_ns_cas(sb, ino, generation, NULL, cetrafs_ns_apply_unverified, &set);
}

/*
 * The recount, with a short retry for the failures that resolve by
 * themselves: a grow this node has not caught up with (-EAGAIN: catch
 * up, then count) and an allocation (-ENOMEM: once more after a pause).
 * Anything else, or one that outlives the attempts, is returned.
 */
/* TEST ONLY: each recount takes this long, as a large directory's does
 * (tests/kernel/nslock_settle_outside_vfs.sh). */
static unsigned int cetrafs_nslock_recount_stall_ms;
cetrafs_test_param(nslock_recount_stall_ms, cetrafs_nslock_recount_stall_ms, uint, 0644);
MODULE_PARM_DESC(nslock_recount_stall_ms, "TEST ONLY: each namespace recount sleeps this many ms first");

static int cetrafs_nslock_recount(struct super_block *sb, u64 ino, u64 generation, struct inode *self)
{
    int attempt, ret = 0;

    if (READ_ONCE(cetrafs_nslock_recount_stall_ms))
        msleep(READ_ONCE(cetrafs_nslock_recount_stall_ms)); /* test-only; see the parameter */

    for (attempt = 0; attempt < 3; attempt++) {
        ret = cetrafs_ns_reconcile(sb, ino, generation, self);
        if (ret == -EAGAIN)
            cetrafs_sb_layout_refresh(sb);
        else if (ret == -ENOMEM)
            msleep(20);
        else
            break;
    }
    return ret;
}

/* TEST ONLY: publish the staged file sector without first checking the
 * lock is still ours, as before audit 2026-11-14 L-F2 -- the control of
 * tests/kernel/nslock_fd_publish_stolen.sh. */
static bool cetrafs_nslock_fd_precheck_off;
cetrafs_test_param(nslock_fd_precheck_off, cetrafs_nslock_fd_precheck_off, bool, 0644);
MODULE_PARM_DESC(nslock_fd_precheck_off, "TEST ONLY: a release publishes its file sector without checking ownership");

static unsigned int cetrafs_nslock_release_stall_ms;
cetrafs_test_param(nslock_release_stall_ms, cetrafs_nslock_release_stall_ms, uint, 0644);
MODULE_PARM_DESC(nslock_release_stall_ms, "TEST ONLY: sleep before publishing a staged record at release");

static unsigned int cetrafs_nslock_hold_ms;
cetrafs_test_param(nslock_hold_ms, cetrafs_nslock_hold_ms, uint, 0644);
MODULE_PARM_DESC(nslock_hold_ms, "TEST ONLY: sleep this long holding each namespace lock just acquired");

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
    if (!ctx->acquire && cetrafs_nslock_release_fail)
        return -EIO; /* test-only, see the knob */
    memset(&rec, 0, sizeof(rec));
    memcpy(&rec, image, CETRAFS_INODE_NS_BYTES);

    /* The sector as it is ON THE DEVICE, verified before any field of
     * it is believed. Keeping the fields we do not change and stamping
     * a fresh checksum over a torn or corrupt record makes it valid
     * from then on -- the same hazard inode.c's namespace mutator
     * guards, and this writes the same sector. */
    if (cetrafs_inode_crc_ns(&rec) != (u32) cetrafs_le64(rec.ns_checksum)) {
        pr_warn_ratelimited("nslock: ino=%llu sector fails its checksum -- refusing to stamp a fresh one\n",
                            (unsigned long long) cetrafs_le64(rec.ino));
        return -EUCLEAN;
    }

    if (cetrafs_le64(rec.generation) != ctx->generation)
        return -ESTALE; /* inode number reused for a different file */

    if (ctx->acquire) {
        bool free_now = (cetrafs_le32(rec.ns_lock_owner) == CETRAFS_NODE_ID_NONE);
        bool mine_already = (cetrafs_le32(rec.ns_lock_owner) == ctx->my_node_id);
        /* The judged holder at the judged incarnation: a lock it took
         * again after re-attaching is a live holder's (F10). */
        bool stealable = ctx->steal && cetrafs_le32(rec.ns_lock_owner) == ctx->steal_from &&
                         cetrafs_le32(rec.ns_lock_incarnation) == ctx->steal_incarnation;

        /* "Already ours" is leftover state: from a previous
         * incarnation of this node (we crashed holding it and remounted
         * onto the same registry row), or from a release of ours that
         * did not commit. The per-inode local mutex guarantees no live
         * local holder, and the acquire has already dropped any
         * deferred retry of that release (cetrafs_sb_nslock_forget()),
         * which would otherwise clear the lock under the holder this
         * makes. Taking it back is correct and is what keeps a
         * self-crash from wedging us out of our own directories
         * forever. */
        if (!free_now && !mine_already && !stealable)
            return -EBUSY;
        ctx->took_over = !free_now; /* this attempt's image decides, not an earlier one's */
        ctx->owed = !!(cetrafs_le32(rec.flags) & CETRAFS_INODE_COUNT_UNVERIFIED);

        /* Taken from a previous holder -- a dead peer, or a release of
         * ours that never committed -- a DIRECTORY's entries may have
         * changed under a dirent_seq that did not: that holder's journal
         * just replayed, or its entries were written and its publish
         * lost. Peers whose cached stamp still equals the record's would
         * go on serving the old directory until somebody's next change
         * to it. A fresh stamp makes every one of them read it again:
         * the safe direction, one extra re-read. Directories only: on a
         * file record the field is the reclaim claim's stamp
         * (cetrafs_inode_reclaim_claim()). */
        if (!free_now && ctx->sb && S_ISDIR(cetrafs_le32(rec.mode)))
            rec.dirent_seq = cetrafs_cpu_to_le64(cetrafs_inode_new_generation(ctx->sb));

        rec.ns_lock_owner = cetrafs_cpu_to_le32(ctx->my_node_id);
        rec.ns_lock_incarnation = cetrafs_cpu_to_le32(ctx->my_incarnation);
    } else {
        if (cetrafs_le32(rec.ns_lock_owner) != ctx->my_node_id) {
            /* Anomalous: the generation still matches, so this is the
             * same live record we locked, yet the lock is no longer
             * ours -- a peer wrongly judged us stale and stole it. Say
             * so loudly rather than treating it as a quiet no-op. */
            ctx->clobbered = cetrafs_le32(rec.ns_lock_owner);
            ctx->not_ours = true;
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
        rec.ns_lock_incarnation = cetrafs_cpu_to_le32(0);
    }

    cetrafs_inode_stamp_crc_ns(&rec);
    memcpy(image, &rec, CETRAFS_INODE_NS_BYTES);
    return 0;
}

/*
 * One retry pass over the namespace locks whose release did not
 * commit. Called from the heartbeat tick.
 *
 * A pure lock-clear: no staged record goes with it. Whatever the
 * failed release was also trying to publish is already lost and was
 * logged as lost at the time -- the point here is only to stop holding
 * a lock nobody else can take.
 *
 * An entry is settled and dropped when the swap commits, when the
 * record says the lock is no longer ours, or when the identity has
 * changed (-ESTALE: the number was reused, so the lock is not ours to
 * clear). Anything else goes back on the queue for the next tick.
 */
void cetrafs_nslock_retry_deferred(struct super_block *sb)
{
    struct cetrafs_nsrel_pending pend[CETRAFS_NSLOCK_DEFERRED_MAX];
    u32 n, i;
    u32 my_node_id;

    /* Begin/end bracket the pass so a local acquire of one of these
     * inodes waits it out (cetrafs_sb_nslock_forget()). */
    cetrafs_sb_nslock_retry_begin(sb);
    n = cetrafs_sb_nslock_take_deferred(sb, pend, ARRAY_SIZE(pend));
    if (!n)
        goto out;
    if (cetrafs_nslock_retry_stall_ms) {
        pr_info("nslock: release retry pass stalled %u ms (test)\n", cetrafs_nslock_retry_stall_ms);
        msleep(cetrafs_nslock_retry_stall_ms); /* test-only; see the parameter */
    }
    if (cetrafs_sb_is_fenced(sb) || cetrafs_sb_get_node_id(sb, &my_node_id) != 0) {
        /* Nothing we may write right now; keep them for later. */
        for (i = 0; i < n; i++)
            cetrafs_sb_nslock_defer(sb, pend[i].ino, pend[i].generation);
        goto out;
    }

    for (i = 0; i < n; i++) {
        struct cetrafs_nslock_ctx ctx = {
            .my_node_id = my_node_id,
            .generation = pend[i].generation,
            .acquire = false,
            .staged = NULL,
            .clobbered = CETRAFS_NODE_ID_NONE,
        };
        int ret = cetrafs_cas_record(sb, cetrafs_inode_lba(sb, pend[i].ino), cetrafs_nslock_mutate, &ctx);

        /*
         * The VERDICT comes from the ctx, never from ret.
         *
         * cetrafs_cas_record() flattens a mutator's >0 ("nothing to
         * do") to 0, and says so in a comment that names this exact
         * trap -- so `ret == 1` below could not fire, and a release
         * whose lock a peer had already taken was logged as committed.
         * The mutator records who holds it in ctx.clobbered; that is
         * the channel the comment prescribes.
         */
        if (ret == 0 && !ctx.not_ours) {
            pr_info("nslock: ino=%llu release committed on retry\n", (unsigned long long) pend[i].ino);
        } else if (ret == 0 || ret == -ESTALE) {
            pr_info("nslock: ino=%llu no longer ours to release (%d) -- dropping the retry\n",
                    (unsigned long long) pend[i].ino, ret);
        } else {
            cetrafs_sb_nslock_defer(sb, pend[i].ino, pend[i].generation);
        }
    }
out:
    cetrafs_sb_nslock_retry_end(sb);
}


/* TEST ONLY: an operation called under the VFS's locks waits there for
 * another node's replay of a dead holder, as before audit 2026-11-15
 * BM-27 (tests/kernel/nslock_replay_claim_outside_vfs.sh). */
static bool cetrafs_nslock_replay_waits_in_vfs;
cetrafs_test_param(nslock_replay_waits_in_vfs, cetrafs_nslock_replay_waits_in_vfs, bool, 0644);
MODULE_PARM_DESC(nslock_replay_waits_in_vfs, "TEST ONLY: a VFS-locked namespace operation waits for a peer's replay claim");

/* One acquire attempt. Returns 0 on success, -EBUSY if a live peer holds
 * it, or another errno. vfs: the caller holds the VFS's locks and can
 * restart (cetrafs_nslock_acquire_set_vfs()). */
static int cetrafs_nslock_try(struct inode *inode, u32 my_node_id, bool *took_over, bool *owed, bool vfs)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_nslock_ctx ctx = {
        .my_node_id = my_node_id,
        .my_incarnation = cetrafs_sb_incarnation(inode->i_sb),
        .acquire = true,
        .sb = inode->i_sb,
    };
    cetrafs_inode_t raw;
    int ret;

    /* Read fresh: the holder may be any node, so a cached copy says
     * nothing (CLAUDE.md cross-node review rule #1). */
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        return ret;

    /*
     * The generation THIS object is, not the record's: a stale in-core
     * object for a reused number -- kept alive by an open fd -- has its
     * own local mutex, so "the lock is already ours" can be the fresh
     * object's operation holding it. Taking the record's generation let
     * the stale one adopt that lock, fail its own generation check and
     * release it under the operation (audit 2026-11-06 L5). Bound to
     * ours, the swap refuses it (-ESTALE) before looking at the owner.
     */
    ctx.generation = cetrafs_inode_get_generation(inode);
    if (!ctx.generation)
        ctx.generation = cetrafs_le64(raw.generation);
    if (cetrafs_le64(raw.generation) != ctx.generation)
        return -ESTALE;

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
        if (cetrafs_node_fence_peer(sb, cetrafs_le32(raw.ns_lock_owner), "a namespace lock"))
            return -EBUSY; /* not revoked: wait and try again, as for a live holder */
        /*
         * Under the VFS's locks, not waiting for another node's replay
         * of the holder: that wait has no bound of its own, and every
         * task queued on the directory -- an ls, a lookup -- waited with
         * it (audit 2026-11-15 BM-27). The operation restarts instead,
         * outside them, and finds the journal replayed. Its own pass
         * over the journal stays here: it is bounded by the journal's
         * size, as the recount below is by the directory's.
         */
        ret = cetrafs_journal_replay_node_scoped(sb, cetrafs_le32(raw.ns_lock_owner),
                                                 /*wait_for_claim=*/!vfs || READ_ONCE(cetrafs_nslock_replay_waits_in_vfs),
                                                 0);
        if (ret == -EEXIST && vfs)
            return -EBUSY; /* a peer is replaying it: restart and look again */
        if (ret)
            return ret;

        pr_warn("nslock: ino=%llu breaking a namespace lock held by stale node %u\n", (unsigned long long) inode->i_ino,
                raw.ns_lock_owner);
        ctx.steal = true;
        ctx.steal_from = cetrafs_le32(raw.ns_lock_owner);
        ctx.steal_incarnation = cetrafs_le32(raw.ns_lock_incarnation);
    }

    /* The CAS is the acquire: it only lands if the record still shows
     * exactly the state this decision was made against. */
    /* Seeded with the copy just read above -- saves re-reading the
     * same record inside the CAS (cetrafs_cas_region_seeded()). */
    if (ctx.steal)
        cetrafs_node_test_stall_before_swap();
    ret = cetrafs_cas_record_seeded(sb, cetrafs_inode_lba(sb, inode->i_ino), &raw, CETRAFS_INODE_NS_BYTES,
                                    cetrafs_nslock_mutate, &ctx);
    *took_over = !ret && ctx.took_over;
    *owed = !ret && ctx.owed;
    /* A broken lock is the judged incarnation's or nothing: the swap
     * compares the holder's incarnation, so one that re-attached and
     * took this lock again answers -EBUSY above, a live holder, and
     * there is nothing to give back (F10). */
    return ret;
}

/* Work deferred outside the VFS's locks (BM-27), defined further down. */
enum { CETRAFS_SETTLE_RECOUNT = 1, CETRAFS_SETTLE_USERS };
static int cetrafs_nslock_defer(struct inode *inode, int what);

/*
 * Take the namespace lock on 'inode' with a caller-chosen try budget.
 * Returns 0 holding both the local mutex and the on-disk lock; -EBUSY
 * (holding neither) if the budget ran out while a live peer held it; or
 * another errno (holding neither). The -EBUSY case is SILENT -- the
 * caller decides whether exhaustion is terminal (a single acquire) or a
 * cue to back off and retry the whole set (acquire_set).
 */
static int cetrafs_nslock_acquire_tries(struct inode *inode, int max_tries, bool vfs)
{
    struct super_block *sb = inode->i_sb;
    u64 deferred_gen = 0;
    bool had_deferred;
    u32 my_node_id;
    int attempt, ret;

    /* Stopped: no namespace mutation at all (-EIO). Damaged metadata in
     * this inode: none of it either (-EUCLEAN) -- every namespace and
     * xattr mutation takes this lock on each inode it changes, so this
     * is the one place that covers them all (docs/internal/ERRORS.md). */
    ret = cetrafs_write_gate(inode);
    if (ret)
        return ret;

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret)
        return ret;

    ret = cetrafs_inode_ns_mutex_lock(inode);
    if (ret)
        return ret; /* killed while another local operation held it */
    /* Before the acquire can make us the live holder: a deferred retry
     * of an earlier release of ours would clear the lock under us. */
    ret = cetrafs_sb_nslock_forget(sb, inode->i_ino, &deferred_gen);
    if (ret < 0) {
        cetrafs_inode_ns_mutex_unlock(inode);
        return ret; /* killed waiting out a release-retry pass */
    }
    had_deferred = ret;

    for (attempt = 0; attempt < max_tries; attempt++) {
        bool took_over = false, owed = false;

        ret = cetrafs_nslock_try(inode, my_node_id, &took_over, &owed, vfs);
        if (ret != -EBUSY) {
            if (!ret) {
                ctrace("NSHOLD ino=%llu ACQ\n", (unsigned long long) inode->i_ino);
                cetrafs_inode_ns_holder_set(inode, true);
                if (cetrafs_nslock_hold_ms)
                    msleep(cetrafs_nslock_hold_ms); /* test-only, see the knob */
            }
            if (ret)
                goto fail;
            /*
             * The lock was SET when we took it: whoever held it stopped
             * inside an operation, and every operation writes its entry
             * before the release that publishes the count of it. Recount
             * before building on that count. Held, so the recount is
             * exact (cetrafs_dir_reconcile_counts()).
             */
            if (READ_ONCE(cetrafs_nslock_unverified_ignore))
                owed = false; /* test-only, see the knob */
            if ((took_over || owed) && !READ_ONCE(cetrafs_nslock_reconcile_off)) {
                u64 gen = cetrafs_inode_get_generation(inode);

                /* Under the VFS's locks: recount outside them instead,
                 * the record flagged so that acquire does (BM-27). A
                 * lock taken over carries no flag yet; it gets one
                 * while still held, or the recount stays here. */
                if (vfs && (owed || !cetrafs_ns_set_unverified(sb, inode->i_ino, gen, true)) &&
                    !cetrafs_nslock_defer(inode, CETRAFS_SETTLE_RECOUNT)) {
                    cetrafs_nslock_release(inode);
                    return -ERESTARTNOINTR;
                }

                ret = cetrafs_nslock_recount(sb, inode->i_ino, gen, inode);
                if (!ret && owed && cetrafs_ns_set_unverified(sb, inode->i_ino, gen, false))
                    pr_warn("nslock: ino=%llu recounted, but its unverified flag could not be cleared -- the next "
                            "acquirer recounts again\n",
                            (unsigned long long) inode->i_ino);
                if (ret == -ESTALE) { /* a reused number: nothing of ours to count */
                    cetrafs_nslock_release(inode);
                    return ret;
                }
                if (ret && READ_ONCE(cetrafs_nslock_recount_fail_release)) {
                    /* test-only: the old path, see the knob */
                    cetrafs_sb_corrupt(sb, inode->i_ino);
                    cetrafs_nslock_release(inode);
                    return -EUCLEAN;
                }
                if (ret) {
                    /*
                     * The counts are unknown. Releasing the lock alone
                     * would leave nothing to say so, and keeping it would
                     * stop every node; the record says it instead, so the
                     * next acquirer -- on any node, in its own context --
                     * recounts before building on them. Set while we
                     * still hold the lock; a swap that cannot land here
                     * ends in the state a crash leaves (the lock set,
                     * which the next holder recounts under). Only a
                     * recount that found damage marks the inode (kind 2,
                     * docs/internal/ERRORS.md).
                     */
                    int set = cetrafs_ns_set_unverified(sb, inode->i_ino, gen, true);

                    pr_err("nslock: ino=%llu: could not recount what a stopped operation left (%d) -- %s\n",
                           (unsigned long long) inode->i_ino, ret,
                           set ? "and could not flag it" : "flagged for the next acquirer");
                    if (set && set != -ESTALE)
                        cetrafs_sb_fatal(sb, "nslock: ino=%llu: its counts are unverified and the flag that says "
                                             "so could not be set (%d)",
                                         (unsigned long long) inode->i_ino, set);
                    if (ret == -EUCLEAN)
                        cetrafs_sb_corrupt(sb, inode->i_ino);
                    cetrafs_nslock_release(inode);
                    return ret == -EAGAIN ? -EIO : ret;
                }
            }
            return ret;
        }
        /* The budget is seconds of sleeping against a peer's lock:
         * let a fatal signal end it. Nothing has been changed yet. */
        if (fatal_signal_pending(current)) {
            ret = -EINTR;
            goto fail;
        }
        if (attempt + 1 < max_tries)
            msleep(CETRAFS_NSLOCK_SLEEP_MS);
    }
    ret = -EBUSY;
fail:
    /* Not the holder after all: whatever the dropped retry was for is
     * still owed. */
    if (had_deferred)
        cetrafs_sb_nslock_defer(sb, inode->i_ino, deferred_gen);
    cetrafs_inode_ns_mutex_unlock(inode);
    return ret;
}

/*
 * Take the namespace lock on a single 'inode'. Blocks (sleeping) while a
 * live peer holds it, for the full retry budget. Returns 0 holding both
 * the local mutex and the on-disk lock, or an errno holding neither.
 */
int cetrafs_nslock_acquire(struct inode *inode)
{
    int ret = cetrafs_nslock_acquire_tries(inode, CETRAFS_NSLOCK_RETRIES, false);

    if (ret == -EBUSY)
        pr_err("nslock: ino=%llu could not acquire the namespace lock (holder not releasing and not stale)\n",
               (unsigned long long) inode->i_ino);
    return ret;
}

/* TEST ONLY: fail this many staged file-sector publishes at release, as
 * a device error would. */
/* TEST ONLY: the next N reads of the namespace sector before a staged
 * file-sector publish fail (tests/kernel/nslock_fd_precheck_read.sh);
 * _quiet makes one failure withhold the publish and go on, as before --
 * that suite's control. */
static unsigned int cetrafs_nslock_fd_precheck_read_fail;
cetrafs_test_param(nslock_fd_precheck_read_fail, cetrafs_nslock_fd_precheck_read_fail, uint, 0644);
MODULE_PARM_DESC(nslock_fd_precheck_read_fail, "TEST ONLY: fail the next N release prechecks' namespace-sector reads");
static bool cetrafs_nslock_fd_precheck_quiet;
cetrafs_test_param(nslock_fd_precheck_quiet, cetrafs_nslock_fd_precheck_quiet, bool, 0644);
MODULE_PARM_DESC(nslock_fd_precheck_quiet, "TEST ONLY: a failed release precheck read withholds the publish and goes on");

static unsigned int cetrafs_nslock_fd_publish_fail;
cetrafs_test_param(nslock_fd_publish_fail, cetrafs_nslock_fd_publish_fail, uint, 0644);
MODULE_PARM_DESC(nslock_fd_publish_fail, "TEST ONLY: fail the next N staged file-sector publishes at release");

/* TEST ONLY: publish the staged file sector WITHOUT fd_pub_mutex -- the
 * unordered publish that let a refresh apply a superseded read. The
 * negative control for tests/kernel/refresh_superseded_own_seq.sh. */
static bool cetrafs_nslock_fd_publish_unlocked;
cetrafs_test_param(nslock_fd_publish_unlocked, cetrafs_nslock_fd_publish_unlocked, bool, 0644);
MODULE_PARM_DESC(nslock_fd_publish_unlocked, "TEST ONLY: publish the staged file sector without fd_pub_mutex");

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

    /* The identity the lock was taken on, for the deferred retry when
     * nothing below gets as far as a fresh read of it. Deferring with 0
     * made the retry's swap see a "reused number" (-ESTALE) and drop the
     * entry -- leaving the lock on the record of a node that keeps
     * beating, which stale-reclaim never touches. */
    ctx.generation = cetrafs_inode_get_generation(inode);

    recs = kmalloc(2 * sizeof(*recs), GFP_NOFS);
    if (!recs) {
        /* Not "for stale-reclaim": that never comes while we beat. The
         * retry is a pure lock-clear, so the staged update is lost --
         * dropped here rather than published by some later release. */
        cetrafs_inode_drop_staged_record(inode);
        cetrafs_sb_nslock_defer(sb, inode->i_ino, ctx.generation);
        /* The entries this operation wrote are on the device and the
         * record that counts them is not: a link count left low is a
         * file freed while still named. Kind 3 (docs/internal/ERRORS.md). */
        cetrafs_sb_fatal(sb, "nslock: ino=%llu release: out of memory -- its staged record update is lost",
                         (unsigned long long) inode->i_ino);
        cetrafs_inode_ns_mutex_unlock(inode);
        return;
    }

    have_staged = cetrafs_inode_take_staged_record(inode, &recs[1], &staged_fd);
    /* TEST ONLY: the window between an operation's entry write and the
     * publish of its count, held open so a suite can copy the device as
     * a crash there leaves it (tests/kernel/ns_count_reconcile.sh). */
    if (have_staged && READ_ONCE(cetrafs_nslock_release_stall_ms))
        msleep(min_t(unsigned int, READ_ONCE(cetrafs_nslock_release_stall_ms), 30000));
    if (have_staged) {
        ctx.staged = &recs[1];
        ctx.staged_nlink_base = cetrafs_inode_staged_nlink_base(inode);
    }
    ctx.sb = sb;

    ret = cetrafs_sb_get_node_id(sb, &ctx.my_node_id);
    if (ret) {
        /* Cannot even identify ourselves -- cannot safely touch the
         * record now. The retry pass asks again before it writes; the
         * staged update is lost either way (see the OOM case above). */
        if (have_staged)
            cetrafs_sb_fatal(sb, "nslock: ino=%llu release: no node id -- its staged record update is lost",
                             (unsigned long long) inode->i_ino);
        cetrafs_sb_nslock_defer(sb, inode->i_ino, ctx.generation);
        pr_err("nslock: ino=%llu release: no node id (%d) -- queued for retry\n", (unsigned long long) inode->i_ino,
               ret);
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
    /* "While we still hold the lock" is a claim the swap below is the
     * first to check: a peer that judged us stale and took the lock
     * meanwhile would get our file sector -- size, extent root -- written
     * over its own, before we learn it is no longer ours (audit
     * 2026-11-14 L-F2). One fresh read of the namespace sector first:
     * not ours, and the staged update is forfeit, as the swap would
     * decide. A steal needs our lease gone, so what remains between this
     * read and the write is the lease's window, not a new one. */
    if (have_staged && staged_fd && !READ_ONCE(cetrafs_nslock_fd_precheck_off)) {
        cetrafs_inode_t now;
        int rret;

        for (attempt = 0; attempt < CETRAFS_NSLOCK_RELEASE_RETRIES; attempt++) {
            cetrafs_invalidate_raw_inode(sb, inode->i_ino);
            if (cetrafs_nslock_fd_precheck_read_fail) {
                cetrafs_nslock_fd_precheck_read_fail--; /* test-only, see the knob */
                rret = -EIO;
            } else {
                rret = cetrafs_read_raw_inode(sb, inode->i_ino, &now);
            }
            if (!rret || READ_ONCE(cetrafs_nslock_fd_precheck_quiet))
                break;
            msleep(CETRAFS_NSLOCK_SLEEP_MS);
        }
        /* A check that could not run is not a pass -- and not a lost
         * lock either. Withholding the file sector and going on let the
         * sector-0 swap below publish dirent_seq over a size that never
         * landed, and the directory kept the wrong size for good
         * (re-audit of the 2026-11-14 fixes). Transient read errors are
         * retried, as the publish is; one that persists stops the mount,
         * which also refuses that swap. */
        if (rret && READ_ONCE(cetrafs_nslock_fd_precheck_quiet)) {
            pr_err("nslock: ino=%llu release: the namespace sector could not be read (%d) -- its staged file "
                   "sector is not published\n",
                   (unsigned long long) inode->i_ino, rret);
            staged_fd = false;
        } else if (rret) {
            cetrafs_sb_fatal(sb, "nslock: ino=%llu release: the namespace sector could not be read in %d "
                                 "attempts (%d) -- its staged update cannot be published",
                             (unsigned long long) inode->i_ino, CETRAFS_NSLOCK_RELEASE_RETRIES, rret);
            staged_fd = false;
        } else if (cetrafs_le64(now.generation) != ctx.generation ||
                   cetrafs_le32(now.ns_lock_owner) != ctx.my_node_id) {
            pr_warn("nslock: ino=%llu release: the lock is no longer ours -- its staged file sector is not "
                    "published\n",
                    (unsigned long long) inode->i_ino);
            staged_fd = false;
        }
    }
    if (have_staged && staged_fd) {
        /* Retried like the swap below, and for the same reason: the lock
         * is ours, so a failure here is transient or the device is
         * failing. It used to give up at once -- and the size it carries
         * is never re-derived: every later create or unlink adjusts the
         * value it reads from the device, so one lost publish left the
         * directory's size wrong for good
         * (tests/kernel/nslock_fd_publish_error.sh). Only the size is at
         * stake: growth commits the extents synchronously, before the
         * entry is written. */
        for (attempt = 0; attempt < CETRAFS_NSLOCK_RELEASE_RETRIES; attempt++) {
            if (cetrafs_nslock_fd_publish_fail) {
                cetrafs_nslock_fd_publish_fail--; /* test-only, see the knob */
                ret = -EIO;
            } else {
                /* Every file-sector publisher holds fd_pub_mutex across its
                 * CAS and its note (BUG-CLASSES class 29): a refresh that
                 * read the record before this publish must either finish
                 * before it or see it, never apply the older record after
                 * it. Lock order here is the namespace lock, then fd_pub
                 * (lock.c). */
                bool locked = !READ_ONCE(cetrafs_nslock_fd_publish_unlocked); /* test-only: see the knob */

                if (locked)
                    cetrafs_inode_fd_pub_lock(inode);
                ret = cetrafs_write_raw_inode_fd(sb, inode->i_ino, &recs[1], inode);
                if (locked)
                    cetrafs_inode_fd_pub_unlock(inode);
            }
            if (!ret || ret == -ESTALE)
                break;
            msleep(CETRAFS_NSLOCK_SLEEP_MS);
        }
        if (ret && ret != -ESTALE)
            /* Stopping here also keeps the sector-0 swap below -- the
             * dirent_seq barrier -- from going out over a file sector
             * that did not: on a stopped mount the swap is refused. */
            cetrafs_sb_fatal(sb, "nslock: ino=%llu staged file-sector publish failed %d times (%d)",
                             (unsigned long long) inode->i_ino, CETRAFS_NSLOCK_RELEASE_RETRIES, ret);
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
        ret = cetrafs_nslock_release_read_fail ? -EIO /* test-only, see the knob */
                                               : cetrafs_read_raw_inode(sb, inode->i_ino, &recs[0]);
        if (!ret) {
            ctx.generation = cetrafs_le64(recs[0].generation);
            ctx.clobbered = CETRAFS_NODE_ID_NONE;
            ctx.not_ours = false;
            ret = cetrafs_cas_record_seeded(sb, cetrafs_inode_lba(sb, inode->i_ino), &recs[0], CETRAFS_INODE_NS_BYTES,
                                            cetrafs_nslock_mutate, &ctx);
        }
        /* 0: published and lock cleared. -ESTALE: the inode's number was
         * reused for a different file, so there is nothing of ours left
         * to clear (the normal outcome when the bracketed op deleted this
         * very inode). 1: the lock is no longer ours -- a peer judged us
         * stale and stole it; our staged update is forfeit, which is
         * correct because that peer has already replayed our journal. */
        if (ret == 0 || ret == -ESTALE)
            break; /* ret > 0 cannot reach here: the CAS layer flattens it */
        msleep(CETRAFS_NSLOCK_SLEEP_MS);
    }

    if (ctx.not_ours && ctx.clobbered == CETRAFS_NODE_ID_NONE)
        pr_warn(
            "nslock: ino=%llu namespace lock was found CLEARED at release -- something released it while this "
            "operation held it\n",
            (unsigned long long) inode->i_ino);
    else if (ctx.not_ours)
        pr_warn("nslock: ino=%llu namespace lock was no longer ours at release (now %u) -- a peer judged us stale and "
                "took it\n",
                (unsigned long long) inode->i_ino, ctx.clobbered);
    else if (ret < 0 && ret != -ESTALE) {
        /* The staged update -- the directory's dirent_seq, size, nlink
         * -- is lost with this swap: the deferred retry below only clears
         * the lock. The entries are on the device and the record that
         * describes them is not, so peers keep serving the old directory
         * and a link count may be left low. Kind 3, like the
         * out-of-memory case above (docs/internal/ERRORS.md); whoever
         * breaks this lock afterwards stamps a fresh dirent_seq. */
        if (have_staged)
            cetrafs_sb_fatal(sb, "nslock: ino=%llu release: the swap that publishes its staged record update "
                                 "did not commit after %d attempts (%d)",
                             (unsigned long long) inode->i_ino, CETRAFS_NSLOCK_RELEASE_RETRIES, ret);
        /* Remember it and retry on the heartbeat. "Leaving it for
         * stale-reclaim" describes what used to happen accurately and
         * is a poor outcome: stale reclaim only fires for a node that
         * stopped heartbeating, and this one has not. The lock would
         * have sat there until we died or unmounted, with every
         * namespace operation on this inode -- from any node --
         * exhausting its retry budget and returning -EBUSY. */
        cetrafs_sb_nslock_defer(sb, inode->i_ino, ctx.generation);
        pr_err("nslock: ino=%llu release did not commit after %d attempts (%d) -- queued for retry "
               "rather than clobbering the record\n",
               (unsigned long long) inode->i_ino, CETRAFS_NSLOCK_RELEASE_RETRIES, ret);
    }

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
static int __cetrafs_nslock_acquire_set(struct inode **inodes, int n, int rounds, int tries, bool vfs)
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

    /* Insertion sort by inode number: count is at most CETRAFS_NSLOCK_MAX_SET. */
    for (i = 1; i < count; i++) {
        struct inode *key = ordered[i];

        for (j = i - 1; j >= 0 && ordered[j]->i_ino > key->i_ino; j--)
            ordered[j + 1] = ordered[j];
        ordered[j + 1] = key;
    }

    for (round = 0; round < rounds; round++) {
        for (i = 0; i < count; i++) {
            /* Short per-lock budget: a contended later lock must not pin
             * the earlier ones (hold-and-wait). */
            ret = cetrafs_nslock_acquire_tries(ordered[i], tries, vfs);
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
            return ret; /* a hard error (fenced, read failure, killed) -- do not spin */
        if (fatal_signal_pending(current))
            return -EINTR;

        /* Contended: back off and retry the whole ordered set, holding
         * nothing in the meantime. */
        if (round + 1 < rounds)
            msleep(CETRAFS_NSLOCK_SLEEP_MS);
    }
    return -EBUSY;
}

int cetrafs_nslock_acquire_set(struct inode **inodes, int n)
{
    int ret = __cetrafs_nslock_acquire_set(inodes, n, CETRAFS_NSLOCK_SET_ROUNDS, CETRAFS_NSLOCK_SET_TRIES, false);

    if (ret == -EBUSY)
        pr_err("nslock: could not acquire a %d-inode namespace set after %d rounds -- heavy directory contention\n",
               n, CETRAFS_NSLOCK_SET_ROUNDS);
    return ret;
}

/*
 * Waiting for a peer's namespace lock OUTSIDE the VFS's locks.
 *
 * Every namespace operation is called with the parent's i_rwsem held
 * (and s_vfs_rename_mutex for a cross-directory rename). Waiting out a
 * peer's lock in there -- up to the whole budget, ~12 s -- made every
 * task queued on that VFS lock wait too: an `ls` of the directory, a
 * lookup of any uncached name in it, every other create, uninterruptibly
 * behind one operation that was itself merely waiting. So an operation
 * called with those locks tries ONCE (no sleep while holding them); if a
 * peer holds a lock it needs, it has changed nothing, and it returns
 * -ERESTARTNOINTR with a task_work queued. The task_work runs as the
 * task returns to user space, with no VFS lock held, and sleeps one
 * retry interval (killable); the kernel then restarts the system call
 * -- -ERESTARTNOINTR with no signal delivered is a restart -- which takes
 * the VFS locks afresh and tries again. Only the caller waits.
 *
 * The budget is unchanged: a per-task deadline, kept across the
 * restarts, ends it with EBUSY exactly where the in-lock wait gave up.
 *
 * Only a task that returns to user space through a system call that
 * restarts can be handed this. Kernel threads and io-wq/user workers
 * (nfsd, io_uring's forced-async fs ops) never get there, and an exiting
 * or dumping task must not be restarted: those keep the in-lock wait.
 * So does any caller that did not opt in (cetrafs_nslock_acquire_set()):
 * setattr from file_remove_privs() in a write, whose AIO and io_uring
 * completions turn a restart code into EINTR, and a security.* xattr
 * that IMA/EVM sets from __fput(), whose return nobody reads.
 *
 * The task_work's code is in this module: it holds a module reference
 * from task_work_add() until its last statement (the drain rule 20
 * asks for); the task's own return to user space is what runs it,
 * microseconds after the system call left this filesystem. The return
 * after that last statement is still this module's text, which unload
 * waits out with a tasks-RCU grace period (cetrafs_nslock_exit()).
 */
static bool cetrafs_nslock_restart_off;
cetrafs_test_param(nslock_restart_off, cetrafs_nslock_restart_off, bool, 0644);
MODULE_PARM_DESC(nslock_restart_off, "TEST ONLY: wait for a peer's namespace lock inside the VFS's locks, as before");

#define CETRAFS_NSLOCK_BUDGET_MS (CETRAFS_NSLOCK_RETRIES * CETRAFS_NSLOCK_SLEEP_MS)

/* Keyed by the task AND its start time: a task killed while it waited
 * leaves its entry behind, and a new task can be given the same
 * task_struct -- with the address alone it would inherit an expired
 * deadline and be refused EBUSY on its first wait. */
/*
 * And by the SYSTEM CALL it is the wait of: its number and arguments,
 * which a restart re-executes unchanged. A restarted call that failed
 * before it got back here -- its path gone, a permission changed --
 * leaves the entry behind, and the task's next contended operation, a
 * different call, inherited the spent deadline: EBUSY at once, with no
 * wait at all (audit 2026-11-15 M-18). The arguments alone cannot tell:
 * a program making the same call again from the same place passes the
 * same values, a path buffer at a reused address included. So 'last'
 * decides too: a restart asks again one retry interval after the last
 * ask, plus the path walk, so an entry idle for longer than
 * CETRAFS_NSWAIT_IDLE_MS is an orphan. Mistaking a chain for a new one
 * -- a restarted call held that long on the way back -- only waits
 * longer, never refuses sooner.
 */
#define CETRAFS_NSWAIT_IDLE_MS 2000
struct cetrafs_nswait_deadline {
    struct list_head node;
    const struct task_struct *task; /* compared, never dereferenced */
    u64 start_time;
    unsigned long deadline;
    unsigned long started; /* when this chain of restarts began */
    unsigned long last;    /* when it was last asked */
    long nr;
    unsigned long args[6];
};

/* TEST ONLY: an entry is the task's whatever call asks, as before audit
 * 2026-11-15 M-18 (tests/kernel/nslock_restart_deadline_orphan.sh). */
static bool cetrafs_nswait_any_call;
cetrafs_test_param(nswait_any_call, cetrafs_nswait_any_call, bool, 0644);
MODULE_PARM_DESC(nswait_any_call, "TEST ONLY: a namespace-lock wait deadline is the task's, whatever call asks");

static void cetrafs_nswait_call(long *nr, unsigned long args[6])
{
    struct pt_regs *regs = task_pt_regs(current);

    *nr = syscall_get_nr(current, regs);
    syscall_get_arguments(current, regs, args);
}

static bool cetrafs_nswait_is_current(const struct cetrafs_nswait_deadline *d)
{
    return d->task == current && d->start_time == current->start_time;
}
static LIST_HEAD(cetrafs_nswait_list);
static DEFINE_SPINLOCK(cetrafs_nswait_lock);

/* Remove current's deadline, and any left by a task that never came back
 * (killed while it waited) once it is a whole budget past due. */
static void cetrafs_nswait_forget(void)
{
    struct cetrafs_nswait_deadline *d, *tmp;
    unsigned long old = msecs_to_jiffies(CETRAFS_NSLOCK_BUDGET_MS);
    LIST_HEAD(dead);

    spin_lock(&cetrafs_nswait_lock);
    list_for_each_entry_safe(d, tmp, &cetrafs_nswait_list, node)
        if (cetrafs_nswait_is_current(d) || time_after(jiffies, d->deadline + old))
            list_move(&d->node, &dead);
    spin_unlock(&cetrafs_nswait_lock);
    list_for_each_entry_safe(d, tmp, &dead, node)
        kfree(d);
}

/* current's deadline, started now if it has none (or has an orphan's,
 * see above). 0: still within it; -EBUSY: past it; -ENOMEM. *started:
 * when this call's wait began. */
static int cetrafs_nswait_within(unsigned long *started)
{
    struct cetrafs_nswait_deadline *d, *fresh = kmalloc(sizeof(*fresh), GFP_NOFS);
    unsigned long now = jiffies, budget = msecs_to_jiffies(CETRAFS_NSLOCK_BUDGET_MS);
    unsigned long args[6];
    long nr;
    int ret = 0;

    cetrafs_nswait_call(&nr, args);
    spin_lock(&cetrafs_nswait_lock);
    list_for_each_entry(d, &cetrafs_nswait_list, node)
        if (cetrafs_nswait_is_current(d))
            break;
    if (&d->node != &cetrafs_nswait_list && !READ_ONCE(cetrafs_nswait_any_call) &&
        (d->nr != nr || memcmp(d->args, args, sizeof(args)) ||
         time_after(now, d->last + msecs_to_jiffies(CETRAFS_NSWAIT_IDLE_MS)))) {
        /* An orphan: this call's wait starts now. */
        d->deadline = now + budget;
        d->started = now;
        d->nr = nr;
        memcpy(d->args, args, sizeof(args));
    }
    if (&d->node != &cetrafs_nswait_list) {
        d->last = now;
        *started = d->started;
        if (time_after(now, d->deadline))
            ret = -EBUSY;
    } else if (fresh) {
        fresh->task = current;
        fresh->start_time = current->start_time;
        fresh->deadline = now + budget;
        fresh->started = fresh->last = now;
        fresh->nr = nr;
        memcpy(fresh->args, args, sizeof(args));
        *started = now;
        list_add(&fresh->node, &cetrafs_nswait_list);
        fresh = NULL;
    } else {
        ret = -ENOMEM;
    }
    spin_unlock(&cetrafs_nswait_lock);
    kfree(fresh);
    return ret;
}

/* Another budget for current's wait (a silent holder, M-17). */
static void cetrafs_nswait_extend(void)
{
    struct cetrafs_nswait_deadline *d;

    spin_lock(&cetrafs_nswait_lock);
    list_for_each_entry(d, &cetrafs_nswait_list, node)
        if (cetrafs_nswait_is_current(d)) {
            d->deadline = jiffies + msecs_to_jiffies(CETRAFS_NSLOCK_BUDGET_MS);
            break;
        }
    spin_unlock(&cetrafs_nswait_lock);
}

/* TEST ONLY: a silent holder's budget ends in EBUSY as a live one's does,
 * as before audit 2026-11-15 M-17 (tests/kernel/nslock_silent_holder.sh). */
static bool cetrafs_nslock_silent_extend_off;
cetrafs_test_param(nslock_silent_extend_off, cetrafs_nslock_silent_extend_off, bool, 0644);
MODULE_PARM_DESC(nslock_silent_extend_off, "TEST ONLY: a silent namespace-lock holder ends the wait in EBUSY");

/*
 * Is every foreign holder of a lock in this set SILENT -- its row not
 * moved since 'started', when this wait began? Such a holder is dead
 * most likely, and goes stale within the window, when the acquire
 * fences it, replays its journal and takes the lock. Ending the wait in
 * EBUSY there -- an errno creat, unlink and rename do not define -- made
 * HA restarting a VM into a directory the dead node was creating in fail
 * for the whole window (audit 2026-11-15 M-17). A holder that moved is
 * alive and holding: the budget ends as before. Read fresh; anything
 * unreadable, or never watched, is not silent.
 */
static bool cetrafs_nslock_set_holder_silent(struct inode **inodes, int n, unsigned long started)
{
    bool any = false;
    u32 me;
    int i;

    if (READ_ONCE(cetrafs_nslock_silent_extend_off) || !n || !inodes[0] ||
        cetrafs_sb_get_node_id(inodes[0]->i_sb, &me))
        return false;
    for (i = 0; i < n; i++) {
        struct super_block *sb;
        cetrafs_node_entry_t ne;
        cetrafs_inode_t raw;
        unsigned long since;
        bool first;
        u32 owner;

        if (!inodes[i])
            continue;
        sb = inodes[i]->i_sb;
        cetrafs_invalidate_raw_inode(sb, inodes[i]->i_ino);
        if (cetrafs_read_raw_inode(sb, inodes[i]->i_ino, &raw))
            return false;
        owner = cetrafs_le32(raw.ns_lock_owner);
        if (owner == CETRAFS_NODE_ID_NONE || owner == me)
            continue;
        if (cetrafs_node_get_entry(sb, owner, &ne) || cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED)
            return false;
        if (cetrafs_sb_peer_sample(sb, owner, &ne, &first, &since) || first || time_after(since, started))
            return false; /* moved since the wait began: alive */
        any = true;
    }
    return any;
}

void cetrafs_nslock_exit(void)
{
    struct cetrafs_nswait_deadline *d, *tmp;

    /* The restart wait's last statement drops the module reference, and
     * its return still executes in this module's text: an unload in
     * between freed the code under it (audit 2026-11-14 L-F6). A
     * tasks-RCU grace period ends only once every task has switched
     * voluntarily or returned to user space -- past that return. Only
     * then is the text ours to free. */
#ifdef CONFIG_TASKS_RCU
    synchronize_rcu_tasks();
#endif

    list_for_each_entry_safe(d, tmp, &cetrafs_nswait_list, node) {
        list_del(&d->node);
        kfree(d);
    }
}

static bool cetrafs_nslock_can_restart(void)
{
    unsigned int no = PF_KTHREAD | PF_IO_WORKER | PF_EXITING | PF_DUMPCORE;

#ifdef PF_USER_WORKER
    no |= PF_USER_WORKER;
#endif
    /* Without tasks RCU, unload cannot wait out the task_work's tail
     * (cetrafs_nslock_exit()): such a build keeps the in-lock wait. */
    return IS_ENABLED(CONFIG_TASKS_RCU) && !(current->flags & no) && !fatal_signal_pending(current) &&
           !READ_ONCE(cetrafs_nslock_restart_off);
}

struct cetrafs_nswait_work {
    struct callback_head cb;
};

static void cetrafs_nswait_run(struct callback_head *cb)
{
    kfree(container_of(cb, struct cetrafs_nswait_work, cb));
    schedule_timeout_killable(msecs_to_jiffies(CETRAFS_NSLOCK_SLEEP_MS));
    module_put(THIS_MODULE);
}

/* 0: queued, return -ERESTARTNOINTR. Anything else: wait in the lock. */
static int cetrafs_nswait_queue(void)
{
    struct cetrafs_nswait_work *w = kmalloc(sizeof(*w), GFP_NOFS);

    if (!w)
        return -ENOMEM;
    if (!try_module_get(THIS_MODULE)) {
        kfree(w);
        return -ENODEV;
    }
    init_task_work(&w->cb, cetrafs_nswait_run);
    if (task_work_add(current, &w->cb, TWA_SIGNAL)) {
        module_put(THIS_MODULE);
        kfree(w);
        return -ESRCH;
    }
    return 0;
}

/*
 * Work an operation called under the VFS's locks and its namespace set
 * would otherwise WAIT for in there (audit 2026-11-15 BM-27): the
 * recount of a namespace lock taken over from a dead holder, and the
 * settle of a file's foreign users (a stale holder's fence and replay, a
 * peer's mover asked back). Both can run for seconds or minutes, and
 * every task queued on the directory waited with them, as did every
 * peer wanting any lock of the set. Instead the operation, having
 * changed nothing, releases everything and returns -ERESTARTNOINTR with
 * a task_work that does the work with no lock of the operation held --
 * the recount under that one inode's namespace lock alone -- and the
 * system call restarts, as for a peer's lock (cetrafs_nswait_queue()).
 *
 * Once per call: a restart marks the call (task, start time, syscall
 * and arguments, as the deadlines are keyed), and a call that comes
 * back marked does the work where it is, as before -- so a settle that
 * keeps finding new work cannot restart forever.
 */
static bool cetrafs_nslock_settle_in_vfs;
cetrafs_test_param(nslock_settle_in_vfs, cetrafs_nslock_settle_in_vfs, bool, 0644);
MODULE_PARM_DESC(nslock_settle_in_vfs, "TEST ONLY: recounts and foreign-user settles run under the VFS and set locks");

static atomic64_t cetrafs_nslock_settle_deferred = ATOMIC64_INIT(0);
u64 cetrafs_nslock_settle_deferred_count(void)
{
    return (u64) atomic64_read(&cetrafs_nslock_settle_deferred);
}

struct cetrafs_settle_mark {
    struct list_head node;
    const struct task_struct *task; /* compared, never dereferenced */
    u64 start_time;
    long nr;
    unsigned long args[6];
    unsigned long at;
};
static LIST_HEAD(cetrafs_settle_marks);

/* Was this call already restarted for a settle? Consumes the mark, and
 * drops any older than CETRAFS_NSWAIT_IDLE_MS (a call that never came
 * back). */
static bool cetrafs_settle_marked(void)
{
    struct cetrafs_settle_mark *m, *tmp;
    unsigned long args[6];
    bool found = false;
    LIST_HEAD(dead);
    long nr;

    cetrafs_nswait_call(&nr, args);
    spin_lock(&cetrafs_nswait_lock);
    list_for_each_entry_safe(m, tmp, &cetrafs_settle_marks, node) {
        bool mine = m->task == current && m->start_time == current->start_time;

        if (mine && m->nr == nr && !memcmp(m->args, args, sizeof(args)) &&
            !time_after(jiffies, m->at + msecs_to_jiffies(CETRAFS_NSWAIT_IDLE_MS)))
            found = true;
        if (mine || time_after(jiffies, m->at + msecs_to_jiffies(CETRAFS_NSWAIT_IDLE_MS)))
            list_move(&m->node, &dead);
    }
    spin_unlock(&cetrafs_nswait_lock);
    list_for_each_entry_safe(m, tmp, &dead, node)
        kfree(m);
    return found;
}

struct cetrafs_settle_work {
    struct callback_head cb;
    struct inode *inode;
    bool sb_pinned;
    int kills; /* cetrafs_sb_kills when queued, for the unpinned test */
    int what;
};

/* TEST ONLY: the deferred settle holds its inode but not the superblock,
 * as before (tests/kernel/nslock_settle_unmount.sh). So the control can
 * run anywhere, a work that finds a superblock torn down since it was
 * queued says so and touches nothing -- before, it went on into freed
 * memory. */
static bool cetrafs_nslock_defer_unpinned;
cetrafs_test_param(nslock_defer_unpinned, cetrafs_nslock_defer_unpinned, bool, 0644);
MODULE_PARM_DESC(nslock_defer_unpinned, "TEST ONLY: a deferred namespace settle does not pin the superblock");

/* TEST ONLY: a deferred settle sleeps this many ms before its work. */
static unsigned int cetrafs_nslock_settle_stall_ms;
cetrafs_test_param(nslock_settle_stall_ms, cetrafs_nslock_settle_stall_ms, uint, 0644);
MODULE_PARM_DESC(nslock_settle_stall_ms, "TEST ONLY: a deferred namespace settle sleeps this many ms first");

static void cetrafs_settle_run(struct callback_head *cb)
{
    struct cetrafs_settle_work *w = container_of(cb, struct cetrafs_settle_work, cb);
    struct inode *inode = w->inode;
    struct super_block *sb = inode->i_sb;
    u32 me;

    if (READ_ONCE(cetrafs_nslock_settle_stall_ms))
        msleep(READ_ONCE(cetrafs_nslock_settle_stall_ms));
    if (!w->sb_pinned && atomic_read(&cetrafs_sb_kills) != w->kills) {
        /* TEST ONLY (nslock_defer_unpinned): the inode is leaked. */
        pr_err("nslock: a deferred settle outlived its superblock (nslock_defer_unpinned)\n");
        kfree(w);
        module_put(THIS_MODULE);
        return;
    }
    if (w->what == CETRAFS_SETTLE_RECOUNT) {
        /* Alone and outside the VFS: the acquire recounts what the dead
         * holder left (the record is flagged) and clears the flag. */
        if (!cetrafs_nslock_acquire(inode)) {
            cetrafs_nslock_release(inode);
            cetrafs_flush_dirty_free_counts(inode->i_sb);
        }
    } else if (!cetrafs_sb_get_node_id(inode->i_sb, &me)) {
        bool blocked, reader;

        (void) cetrafs_lock_foreign_user_settled(inode, me, &blocked, &reader, NULL, NULL);
    }
    /* The restart is now: its mark ages from here, not from when the
     * work was queued -- a settle longer than the idle window would
     * otherwise send the call round again. */
    {
        struct cetrafs_settle_mark *m;

        spin_lock(&cetrafs_nswait_lock);
        list_for_each_entry(m, &cetrafs_settle_marks, node)
            if (m->task == current && m->start_time == current->start_time)
                m->at = jiffies;
        spin_unlock(&cetrafs_nswait_lock);
    }
    iput(inode);
    if (w->sb_pinned)
        deactivate_super(sb); /* may be the last: unmount finishes here */
    kfree(w);
    module_put(THIS_MODULE);
}

/* 0: queued, the caller releases everything and returns -ERESTARTNOINTR.
 * Anything else: do the work in place. */
static int cetrafs_nslock_defer(struct inode *inode, int what)
{
    struct cetrafs_settle_work *w;
    struct cetrafs_settle_mark *m;

    if (READ_ONCE(cetrafs_nslock_settle_in_vfs) || !cetrafs_nslock_can_restart() || cetrafs_settle_marked())
        return -EALREADY;
    w = kmalloc(sizeof(*w), GFP_NOFS);
    m = kmalloc(sizeof(*m), GFP_NOFS);
    if (!w || !m)
        goto nomem;
    if (!try_module_get(THIS_MODULE))
        goto nomem;
    /*
     * The work outlives the call: it runs as the task returns to user
     * space, AFTER the call has dropped its path. Task work runs newest
     * first, and a lazy unmount's last mntput queues the superblock's
     * teardown exactly there -- or runs it in the umount itself while
     * this work stalls. An inode reference alone left kill_sb to find
     * the inode busy, put_super to free sb_info, and this work's
     * acquire and iput() to run on it (rule 20). An active reference
     * keeps the superblock whole until the work has dropped the inode;
     * the caller holds a path on it, so it is active now.
     */
    w->sb_pinned = !READ_ONCE(cetrafs_nslock_defer_unpinned);
    if (w->sb_pinned)
        atomic_inc(&inode->i_sb->s_active);
    w->kills = atomic_read(&cetrafs_sb_kills);
    ihold(inode);
    w->inode = inode;
    w->what = what;
    init_task_work(&w->cb, cetrafs_settle_run);
    if (task_work_add(current, &w->cb, TWA_SIGNAL)) {
        iput(inode);
        if (w->sb_pinned)
            deactivate_super(inode->i_sb);
        module_put(THIS_MODULE);
        goto nomem;
    }
    m->task = current;
    m->start_time = current->start_time;
    cetrafs_nswait_call(&m->nr, m->args);
    m->at = jiffies;
    spin_lock(&cetrafs_nswait_lock);
    list_add(&m->node, &cetrafs_settle_marks);
    spin_unlock(&cetrafs_nswait_lock);
    atomic64_inc(&cetrafs_nslock_settle_deferred);
    pr_info_ratelimited("nslock: ino=%llu: %s outside the directory's locks, restarting the call\n",
                        (unsigned long long) inode->i_ino,
                        what == CETRAFS_SETTLE_RECOUNT ? "recounting" : "settling its foreign users");
    return 0;
nomem:
    kfree(w);
    kfree(m);
    return -ENOMEM;
}

/* For dir.c and xattr.c: the foreign-user settle, deferred. Only from an
 * operation that holds its set through cetrafs_nslock_acquire_set_vfs()
 * and has changed nothing yet. */
int cetrafs_nslock_defer_settle(struct inode *inode)
{
    return cetrafs_nslock_defer(inode, CETRAFS_SETTLE_USERS);
}

/*
 * cetrafs_nslock_acquire_set() for an operation the VFS called with its
 * own locks held, whose error the system call returns as it is: see
 * above. Called before the operation changes anything.
 */
int cetrafs_nslock_acquire_set_vfs(struct inode **inodes, int n)
{
    unsigned long started = 0;
    int ret;

    if (!cetrafs_nslock_can_restart())
        return cetrafs_nslock_acquire_set(inodes, n);
    ret = __cetrafs_nslock_acquire_set(inodes, n, 1, 1, true);
    if (ret != -EBUSY) {
        cetrafs_nswait_forget();
        return ret;
    }
    ret = cetrafs_nswait_within(&started);
    if (ret == -EBUSY && cetrafs_nslock_set_holder_silent(inodes, n, started)) {
        /* Silent since the wait began: another budget, restarting. */
        cetrafs_nswait_extend();
        atomic64_inc(&cetrafs_nslock_silent_extends);
        pr_warn_ratelimited("nslock: a %d-inode namespace set is held by a node that has stopped beating -- "
                            "waiting for it to go stale\n",
                            n);
        ret = 0;
    }
    if (ret == -EBUSY) {
        cetrafs_nswait_forget();
        pr_err("nslock: could not acquire a %d-inode namespace set within %u ms -- the holder is not releasing\n",
               n, CETRAFS_NSLOCK_BUDGET_MS);
        return -EBUSY;
    }
    if (ret || cetrafs_nswait_queue()) {
        cetrafs_nswait_forget();
        return cetrafs_nslock_acquire_set(inodes, n);
    }
    atomic64_inc(&cetrafs_nslock_restarts);
    return -ERESTARTNOINTR;
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
