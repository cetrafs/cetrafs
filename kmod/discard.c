// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * discard.c -- UNMAP: giving freed space back to a thin LUN.
 *
 * Two ways in, one way out (cetrafs_discard_issue()):
 *
 *  - HAND-BACK. A Block Group that has gone empty is handed back to the
 *    unowned pool by the heartbeat (cetrafs_bg_release_empty()), usually
 *    within a tick of the delete that emptied it -- so most freed space
 *    leaves this node's ownership long before anyone runs fstrim, and a
 *    trim limited to owned Block Groups would never see it. The release
 *    therefore discards the whole data region at the one moment that is
 *    safest for it: the group already drained out of the allocator's
 *    reach, its bitmap already proven empty ON THE DEVICE, and nobody
 *    else able to claim it until the descriptor reads FREE. Space in the
 *    pool is then always space already given back. On by default where
 *    the device supports discard; `nodiscard` / the `discard` control
 *    turn it off. Time-budgeted per pass, so a slow array defers the
 *    rest of the releases to the next tick instead of holding the
 *    heartbeat (which renews the lease) for as long as the array takes.
 *
 *  - FITRIM (fstrim). For the space freed inside Block Groups that stay
 *    in use: a guest's TRIM punching holes in a VM image. Each free run
 *    of a Block Group this node owns is CLAIMED first -- bits set as an
 *    allocation sets them, held against the scrub and against every free
 *    path (cetrafs_trim_claim_next()) -- then discarded with no lock
 *    held, then given back. A Block Group that left this node mid-pass
 *    keeps the claimed bits set (a leak for the scrub), never has them
 *    cleared by us.
 *
 * Nothing in this module may ever rely on a discarded block reading
 * back as zero: arrays differ, and Linux dropped that guarantee. An
 * unwritten file range reads as zero because its extent is marked
 * uninitialised, never because of what the device returns.
 *
 * A device without discard is not an error anywhere but FITRIM, which
 * says -EOPNOTSUPP: the hand-back simply releases without one. A
 * discard the target REFUSED is counted and the blocks are freed
 * regardless -- discarding is best effort; freeing is not. One whose
 * outcome is unknown (a timeout, a path failure) may still execute, so
 * its blocks are not handed out: a FITRIM run stays allocated for the
 * scrub, a hand-back keeps its Block Group for a later tick
 * (cetrafs_discard_outcome_known()).
 *
 * docs/DISCARD-DESIGN.md.
 */
#include <linux/blkdev.h>
#include <linux/capability.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/jiffies.h>
#include <linux/sched/signal.h>
#include <linux/sort.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>
#include <linux/workqueue.h>

#include "kmod.h"

/* A FITRIM claim is at most this many blocks (256 MiB): the cost of an
 * UNMAP is per command, not per byte, so big is cheap -- but the run is
 * out of the allocator's reach for as long as its discard takes, and on
 * a nearly full volume that is space a writer may be waiting for. */
#define CETRAFS_TRIM_MAX_RUN_BLOCKS (1ULL << 16)

/* How long one hand-back pass may spend starting discards. */
#define CETRAFS_HANDBACK_TRIM_BUDGET_MS 1000

static atomic64_t cetrafs_discard_cmds = ATOMIC64_INIT(0);
static atomic64_t cetrafs_discard_blocks = ATOMIC64_INIT(0);
static atomic64_t cetrafs_discard_errors = ATOMIC64_INIT(0);
static atomic64_t cetrafs_discard_refused = ATOMIC64_INIT(0);
static atomic64_t cetrafs_discard_handback_bgs = ATOMIC64_INIT(0);
static atomic64_t cetrafs_discard_handback_deferred = ATOMIC64_INIT(0); /* over budget */
static atomic64_t cetrafs_discard_handback_unknown = ATOMIC64_INIT(0);  /* outcome unknown: kept */

u64 cetrafs_discard_cmds_count(void)
{
    return (u64) atomic64_read(&cetrafs_discard_cmds);
}
u64 cetrafs_discard_blocks_count(void)
{
    return (u64) atomic64_read(&cetrafs_discard_blocks);
}
u64 cetrafs_discard_errors_count(void)
{
    return (u64) atomic64_read(&cetrafs_discard_errors);
}
u64 cetrafs_discard_refused_count(void)
{
    return (u64) atomic64_read(&cetrafs_discard_refused);
}
u64 cetrafs_discard_handback_count(void)
{
    return (u64) atomic64_read(&cetrafs_discard_handback_bgs);
}
u64 cetrafs_discard_handback_deferred_count(void)
{
    return (u64) atomic64_read(&cetrafs_discard_handback_deferred);
}
u64 cetrafs_discard_handback_unknown_count(void)
{
    return (u64) atomic64_read(&cetrafs_discard_handback_unknown);
}

/* TEST ONLY: hold a claimed run this long before its discard, so a
 * writer allocates while the UNMAP is still to come
 * (tests/kernel/fstrim_claim.sh). */
static unsigned int cetrafs_trim_discard_stall_ms;
cetrafs_test_param(trim_discard_stall_ms, cetrafs_trim_discard_stall_ms, uint, 0644);
MODULE_PARM_DESC(trim_discard_stall_ms, "TEST ONLY: pause between a FITRIM claim and its discard");

/* TEST ONLY: FITRIM skips the unowned pool, as it did before it had a
 * pool pass -- the negative control of tests/kernel/fstrim_pool.sh. */
static bool cetrafs_fitrim_skip_pool;
cetrafs_test_param(fitrim_skip_pool, cetrafs_fitrim_skip_pool, bool, 0644);
MODULE_PARM_DESC(fitrim_skip_pool, "TEST ONLY: FITRIM leaves the unowned Block Group pool alone");

/* TEST ONLY: aim the next FITRIM discard at the Block Group's own
 * bitmap instead of its run -- the negative control for the range check
 * below (tests/kernel/fstrim.sh). One-shot. */
static bool cetrafs_discard_aim_at_bitmap;
cetrafs_test_param(discard_aim_at_bitmap, cetrafs_discard_aim_at_bitmap, bool, 0644);
MODULE_PARM_DESC(discard_aim_at_bitmap, "TEST ONLY: point the next FITRIM discard at metadata, once");

/* TEST ONLY: one hand-back pass's budget, in ms (0: the default). */
static unsigned int cetrafs_handback_budget_ms;
cetrafs_test_param(handback_budget_ms, cetrafs_handback_budget_ms, uint, 0644);
MODULE_PARM_DESC(handback_budget_ms, "TEST ONLY: the hand-back discard budget per pass, in ms");

/* TEST ONLY: the next discards fail as a transport error would, with no
 * command sent -- an outcome the caller cannot know
 * (tests/kernel/discard_unknown_outcome.sh). A count, decremented per
 * discard. */
static unsigned int cetrafs_discard_fail_unknown;
cetrafs_test_param(discard_fail_unknown, cetrafs_discard_fail_unknown, uint, 0644);
MODULE_PARM_DESC(discard_fail_unknown, "TEST ONLY: fail this many discards with -EIO, as a transport error");

/* TEST ONLY: the next discards are refused as a target refuses one
 * (-EREMOTEIO, BLK_STS_TARGET): a failure whose outcome IS known -- the
 * contrast to discard_fail_unknown. A count. */
static unsigned int cetrafs_discard_fail_definite;
cetrafs_test_param(discard_fail_definite, cetrafs_discard_fail_definite, uint, 0644);
MODULE_PARM_DESC(discard_fail_definite, "TEST ONLY: refuse this many discards with -EREMOTEIO, as a target would");

/*
 * Did a failed discard certainly NOT execute? Only when the request
 * never left the host or the target answered it: refused by our own
 * range check (-EUCLEAN), unsupported, invalid, or refused by the target
 * (BLK_STS_NOTSUPP, _INVAL, _TARGET). Anything
 * else -- a timeout, a transport or path failure, a plain I/O error --
 * may be a command the array has, or will, run anyway, and an UNMAP that
 * lands after the blocks were handed out destroys the new data (class
 * 30). Those are treated as "it will still happen".
 */
static bool cetrafs_discard_outcome_known(int err)
{
    return !err || err == -EUCLEAN || err == -EOPNOTSUPP || err == -EINVAL || err == -EREMOTEIO;
}

bool cetrafs_discard_supported(struct super_block *sb)
{
    return sb->s_bdev && bdev_max_discard_sectors(sb->s_bdev) != 0;
}

/*
 * The one place a discard reaches the device. The range must lie inside
 * the data region of the Block Group it names, resolved again here from
 * the LBA and from the descriptor -- not taken from the caller: a
 * discard is a write of nothing, and aimed at the superblock, a table,
 * the registry, a journal, a queue or a Block Group's own header and
 * bitmap it destroys the volume for every node. Refused loudly, never
 * clipped: a caller computing such a range is wrong about something
 * else too.
 */
/* The range check both issuers make: [lba, +count) inside the data
 * region of Block Group bg_id, both ends resolving to it. */
static int cetrafs_issue_range_ok(struct super_block *sb, const char *what, u32 bg_id, u64 lba, u64 count)
{
    u64 data_start, data_count;
    u32 owner, first_bg, last_bg;
    int ret;

    ret = cetrafs_bg_data_region(sb, bg_id, &data_start, &data_count, &owner);
    if (ret)
        return ret;
    if (lba < data_start || lba + count > data_start + data_count || lba + count < lba ||
        cetrafs_bg_id_of_lba(sb, lba, &first_bg) || cetrafs_bg_id_of_lba(sb, lba + count - 1, &last_bg) ||
        first_bg != bg_id || last_bg != bg_id) {
        atomic64_inc(&cetrafs_discard_refused);
        pr_err("%s: %s [%llu +%llu) is not inside BG %u's data region [%llu +%llu) -- refused\n", sb->s_id, what,
               (unsigned long long) lba, (unsigned long long) count, bg_id, (unsigned long long) data_start,
               (unsigned long long) data_count);
        return -EUCLEAN;
    }
    return 0;
}

/* TEST ONLY: every discard pauses this long before it is sent, so a
 * suite can look at the device while one is about to go out
 * (tests/kernel/discard_hold_durable_first.sh). */
static unsigned int cetrafs_discard_issue_stall_ms;
cetrafs_test_param(discard_issue_stall_ms, cetrafs_discard_issue_stall_ms, uint, 0644);
MODULE_PARM_DESC(discard_issue_stall_ms, "TEST ONLY: pause before every discard is sent");

static int cetrafs_discard_issue(struct super_block *sb, u32 bg_id, u64 lba, u64 count)
{
    int ret;

    if (!count)
        return 0;
    if (READ_ONCE(cetrafs_discard_issue_stall_ms)) {
        pr_info("%s: discard [%llu +%llu) of BG %u: pausing %u ms before it is sent (test)\n", sb->s_id,
                (unsigned long long) lba, (unsigned long long) count, bg_id, cetrafs_discard_issue_stall_ms);
        msleep(READ_ONCE(cetrafs_discard_issue_stall_ms));
    }
    if (cetrafs_sb_fence_witnessed(sb)) /* the device's word, not only the clock's (B-18) */
        return -EIO;
    ret = cetrafs_issue_range_ok(sb, "discard", bg_id, lba, count);
    if (ret)
        return ret;

    if (READ_ONCE(cetrafs_discard_fail_unknown) || READ_ONCE(cetrafs_discard_fail_definite)) {
        unsigned int n = READ_ONCE(cetrafs_discard_fail_unknown);

        ret = 0; /* test-only, both; see the parameters */
        if (n && cmpxchg(&cetrafs_discard_fail_unknown, n, n - 1) == n)
            ret = -EIO;
        n = READ_ONCE(cetrafs_discard_fail_definite);
        if (!ret && n && cmpxchg(&cetrafs_discard_fail_definite, n, n - 1) == n)
            ret = -EREMOTEIO;
        if (ret)
            goto failed;
    }
    ret = blkdev_issue_discard(sb->s_bdev, (sector_t) lba * (CETRAFS_BLOCK_SIZE >> SECTOR_SHIFT),
                               (sector_t) count * (CETRAFS_BLOCK_SIZE >> SECTOR_SHIFT), GFP_NOFS);
failed:
    if (ret) {
        atomic64_inc(&cetrafs_discard_errors);
        pr_warn_ratelimited("%s: discard [%llu +%llu) failed (%d) -- the blocks are freed regardless\n", sb->s_id,
                            (unsigned long long) lba, (unsigned long long) count, ret);
        return ret;
    }
    atomic64_inc(&cetrafs_discard_cmds);
    atomic64_add((s64) count, &cetrafs_discard_blocks);
    return 0;
}

/*
 * Ask the device whether it refuses writes for space: a failed O_DIRECT
 * write's completion, whose own status the old O_DIRECT code flattened
 * to EIO (audit BM-15, cetrafs_dio_nospc_probe()). Returns -ENOSPC when
 * the device refused the probe for space, 0 when it did not say so.
 *
 * WHERE it asks is the whole point (F-57). A thin pool provisions whole
 * chunks (dm-thin 64 KiB and up, arrays 16 KiB to tens of MiB), so a
 * probe in a chunk that already holds live data -- the head of a free
 * run is, by construction, right after a live block -- is taken while
 * the pool is full, and the guest gets EIO anyway. So the probe goes in
 * the middle of a claimed free run, on a chunk boundary (the device's
 * discard granularity, at least 64 KiB), with the whole chunk inside the
 * claim: nothing live shares it. Space freed without a discard (a
 * deleted image before FITRIM) is provisioned too, so a probe the
 * device takes is followed by a discard of that chunk -- the claim
 * holds every block of it, as FITRIM's does -- and a second probe in
 * the chunk just given back: refused, the pool is full; taken again, it
 * has space. With no discard (or one refused) the next group is tried,
 * up to CETRAFS_SPACE_PROBE_TRIES; a device that does not unprovision
 * on a discard takes the second write and the answer stays EIO.
 *
 * FITRIM's protocol throughout (cetrafs_trim_claim_next(),
 * cetrafs_trim_hold_durable(), cetrafs_trim_release()): the run's bits
 * are set and durable before anything is written or discarded, a crash
 * leaks at most the run, and a discard whose outcome is unknown keeps
 * it. Never waits for the trim mutex: a FITRIM in progress answers
 * "not known", and the write stays EIO.
 */
#define CETRAFS_SPACE_PROBE_TRIES 3
#define CETRAFS_SPACE_PROBE_SPAN 8192 /* blocks claimed around a probe: 32 MiB */

static bool cetrafs_space_probe_at_head; /* TEST ONLY: see the parameter */
cetrafs_test_param(space_probe_at_head, cetrafs_space_probe_at_head, bool, 0644);
MODULE_PARM_DESC(space_probe_at_head,
                 "TEST ONLY: the space probe writes the head of one free run, no discard (BM-15 before F-57)");

static int cetrafs_space_probe_write(struct super_block *sb, u64 lba)
{
    struct page *page = alloc_page(GFP_NOFS);
    struct bio *bio;
    int ret;

    if (!page)
        return -ENOMEM;
    /* not zeros: an array that detects them would not allocate */
    memset(page_address(page), 0xc5, PAGE_SIZE);
    bio = bio_alloc(sb->s_bdev, 1, REQ_OP_WRITE | REQ_SYNC, GFP_NOFS);
    bio->bi_iter.bi_sector = lba * (CETRAFS_BLOCK_SIZE >> SECTOR_SHIFT);
    __bio_add_page(bio, page, CETRAFS_BLOCK_SIZE, 0);
    ret = submit_bio_wait(bio);
    bio_put(bio);
    __free_page(page);
    return ret;
}

int cetrafs_discard_space_probe(struct super_block *sb, unsigned int *tries)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    bool at_head = READ_ONCE(cetrafs_space_probe_at_head);
    u64 gran, off, need;
    u32 b, nbg;
    int ret = 0;

    *tries = 0;
    if (!raw_sb || cetrafs_sb_is_fenced(sb))
        return 0;
    gran = max_t(u64, DIV_ROUND_UP((u64) bdev_discard_granularity(sb->s_bdev), CETRAFS_BLOCK_SIZE),
                 SZ_64K / CETRAFS_BLOCK_SIZE);
    off = ((u64) bdev_discard_alignment(sb->s_bdev) / CETRAFS_BLOCK_SIZE) % gran;
    need = at_head ? 1 : 2 * gran - 1; /* the least run that holds one whole aligned chunk */
    if (!mutex_trylock(cetrafs_sb_trim_mutex(sb)))
        return 0;
    nbg = le32_to_cpu(raw_sb->block_group_count);
    for (b = 0; b < nbg && *tries < (at_head ? 1 : CETRAFS_SPACE_PROBE_TRIES); b++) {
        struct cetrafs_trim_run run = {.span = {.link = LIST_HEAD_INIT(run.span.link)}};
        u64 cursor = 0, lba, first, nchunks;
        bool again = false;
        int rc, w, d = 0;

        if (!cetrafs_sb_bg_is_ours(sb, b))
            continue;
        rc = cetrafs_trim_claim_next(sb, b, &cursor, need, max_t(u64, need, CETRAFS_SPACE_PROBE_SPAN), &run);
        if (rc == -ENOSPC || rc == -EAGAIN || rc == -EPERM)
            continue; /* no run that long here, or not ours any more */
        if (rc)
            break;
        if (at_head) {
            lba = run.lba;
        } else {
            first = DIV64_U64_ROUND_UP(run.lba + gran - off, gran) * gran + off - gran;
            nchunks = (run.lba + run.count - first) / gran; /* >= 1: the run is 2 * gran - 1 long */
            lba = first + (nchunks / 2) * gran;
        }
        rc = cetrafs_trim_hold_durable(sb, &run);
        if (rc) {
            cetrafs_trim_release(sb, &run, false); /* nothing written */
            break;
        }
        (*tries)++;
        w = cetrafs_space_probe_write(sb, lba);
        if (!w && !at_head && cetrafs_discard_supported(sb)) {
            d = cetrafs_discard_issue(sb, b, lba, gran); /* give back what the probe provisioned */
            if (!d) {
                /* The chunk is unprovisioned now, whatever it was: ask
                 * again in it. Taken twice, the device has the space. */
                (*tries)++;
                again = true;
                w = cetrafs_space_probe_write(sb, lba);
                if (!w)
                    d = cetrafs_discard_issue(sb, b, lba, gran);
            }
        }
        cetrafs_trim_release(sb, &run, d && !cetrafs_discard_outcome_known(d));
        if (w) {
            ret = w == -ENOSPC ? w : 0; /* any other failure says nothing about space */
            break;
        }
        if (again)
            break;
    }
    mutex_unlock(cetrafs_sb_trim_mutex(sb));
    return ret;
}

/*
 * The device zeroes [lba, +count) in place (REQ_OP_WRITE_ZEROES), for
 * ZERO_RANGE (cetrafs_zero_range_inplace()). A write of zeros is as
 * destructive as a discard when it is aimed wrong, and with unmap
 * allowed it IS a discard on a thin array, so it goes through the same
 * range check: the run must lie inside one Block Group's data region,
 * resolved here from the LBA (class 50). The caller gives a run of one
 * extent; an extent never crosses a group, so a run that does is refused
 * as -EUCLEAN, never split. -EOPNOTSUPP: the device cannot zero in place.
 */
int cetrafs_zeroout_issue(struct super_block *sb, u64 lba, u64 count, bool unmap)
{
    u32 bg_id;
    int ret;

    if (!count)
        return 0;
    if (cetrafs_sb_fence_witnessed(sb)) /* B-18, as a discard's */
        return -EIO;
    if (cetrafs_bg_id_of_lba(sb, lba, &bg_id))
        return -EUCLEAN;
    ret = cetrafs_issue_range_ok(sb, "zeroout", bg_id, lba, count);
    if (ret)
        return ret;
    return blkdev_issue_zeroout(sb->s_bdev, (sector_t) lba * (CETRAFS_BLOCK_SIZE >> SECTOR_SHIFT),
                                (sector_t) count * (CETRAFS_BLOCK_SIZE >> SECTOR_SHIFT), GFP_NOFS,
                                BLKDEV_ZERO_NOFALLBACK | (unmap ? 0 : BLKDEV_ZERO_NOUNMAP));
}

/*
 * The hand-back half, from cetrafs_bg_release_empty() with BG 'bg_id'
 * drained and its bitmap proven empty on the device. 0: release it (the
 * region was discarded, or discard is off, unsupported or refused).
 * -EBUSY: this pass's budget is spent -- keep the group and release it
 * on a later tick, so the space it holds is never handed back
 * untrimmed while discard is on. The first group of every pass is
 * always attempted (it starts the clock), so each pass makes progress.
 * -EAGAIN: the discard failed with an UNKNOWN outcome. It may still
 * execute, so the group must not take data -- not a peer's after it
 * reads FREE, and not ours either: the caller keeps it DRAINED and marks
 * it pending (review U1), and only a later discard whose outcome is
 * known lets it go anywhere.
 *
 * 'pending': the group already carries such a discard. The switch and
 * fencing do not cancel a command already sent, so it is re-issued
 * whatever discard is set to, and a device that no longer takes
 * discards, or a fenced mount, keeps it pending.
 */
/* Would cetrafs_discard_handback(pending=false) send anything? */
bool cetrafs_discard_handback_would_send(struct super_block *sb, bool force)
{
    return (force || cetrafs_sb_discard_enabled(sb)) && cetrafs_discard_supported(sb) && !cetrafs_sb_is_fenced(sb);
}

int cetrafs_discard_handback(struct super_block *sb, u32 bg_id, unsigned long *pass_started, bool pending,
                             bool force, bool *discarded)
{
    unsigned int budget = READ_ONCE(cetrafs_handback_budget_ms);
    u64 data_start, data_count;
    u32 owner;
    int ret;

    *discarded = false;
    if (pending) {
        if (!cetrafs_discard_supported(sb) || cetrafs_sb_is_fenced(sb))
            return -EAGAIN;
    } else if ((!force && !cetrafs_sb_discard_enabled(sb)) || !cetrafs_discard_supported(sb) ||
               cetrafs_sb_is_fenced(sb)) {
        return 0;
    }
    if (!budget)
        budget = CETRAFS_HANDBACK_TRIM_BUDGET_MS;
    if (!*pass_started) {
        *pass_started = jiffies ? jiffies : 1;
    } else if (time_after(jiffies, *pass_started + msecs_to_jiffies(budget))) {
        atomic64_inc(&cetrafs_discard_handback_deferred);
        return -EBUSY;
    }
    if (cetrafs_bg_data_region(sb, bg_id, &data_start, &data_count, &owner))
        return pending ? -EAGAIN : 0;
    ret = cetrafs_discard_issue(sb, bg_id, data_start, data_count);
    if (!ret) {
        atomic64_inc(&cetrafs_discard_handback_bgs);
        *discarded = true; /* the release marks the group DISCARDED */
    } else if (!cetrafs_discard_outcome_known(ret)) {
        atomic64_inc(&cetrafs_discard_handback_unknown);
        return -EAGAIN;
    }
    return 0;
}

/* TEST ONLY: FITRIM trims on a mount whose discard switch is off, as
 * before audit 2026-11-15 B-37 (tests/kernel/fstrim_nodiscard.sh). */
static bool cetrafs_fitrim_ignores_nodiscard;
cetrafs_test_param(fitrim_ignores_nodiscard, cetrafs_fitrim_ignores_nodiscard, bool, 0644);
MODULE_PARM_DESC(fitrim_ignores_nodiscard, "TEST ONLY: FITRIM trims with the discard switch off");

/*
 * FITRIM. The range is in bytes, as fstrim(8) passes it; on return
 * range.len is the number of bytes discarded.
 *
 * Not while the mount's discard switch is off (`nodiscard`, or
 * `discard=off` in controls): the switch is what an operator turns off
 * on an array whose UNMAP is slow, and a distribution's weekly
 * fstrim.timer runs `fstrim -a` on every node unasked -- long UNMAPs
 * in flight on every node at once, on exactly the arrays they were
 * turned off for (audit 2026-11-15 B-37). EOPNOTSUPP is what fstrim(8)
 * reports as "not supported" and skips. An operator who means it turns
 * `discard=on` in controls first.
 */
long cetrafs_fitrim_ioctl(struct file *file, struct fstrim_range __user *arg)
{
    struct super_block *sb = file_inode(file)->i_sb;
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct fstrim_range range;
    u64 start, end, minlen, maxlen, gran, trimmed = 0;
    u32 b, nbg;
    int ret = 0;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;
    if (!raw_sb)
        return -EINVAL;
    if (!cetrafs_discard_supported(sb))
        return -EOPNOTSUPP;
    if (!cetrafs_sb_discard_enabled(sb) && !READ_ONCE(cetrafs_fitrim_ignores_nodiscard)) {
        pr_info_ratelimited("%s: fstrim refused: discard is off on this mount (nodiscard, or discard=off in "
                            "controls); turn discard=on in controls to trim\n",
                            sb->s_id);
        return -EOPNOTSUPP;
    }
    if (sb_rdonly(sb))
        return -EROFS;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    if (copy_from_user(&range, arg, sizeof(range)))
        return -EFAULT;

    if (range.minlen > (u64) le64_to_cpu(raw_sb->total_blocks) * CETRAFS_BLOCK_SIZE)
        return -EINVAL;
    start = range.start / CETRAFS_BLOCK_SIZE;
    end = range.len >= U64_MAX - range.start ? U64_MAX : (range.start + range.len) / CETRAFS_BLOCK_SIZE;
    gran = DIV_ROUND_UP((u64) bdev_discard_granularity(sb->s_bdev), CETRAFS_BLOCK_SIZE);
    minlen = max3(DIV_ROUND_UP(range.minlen, CETRAFS_BLOCK_SIZE), gran, 1ULL);
    maxlen = min_t(u64, bdev_max_discard_sectors(sb->s_bdev) / (CETRAFS_BLOCK_SIZE >> SECTOR_SHIFT),
                   CETRAFS_TRIM_MAX_RUN_BLOCKS);
    if (!maxlen)
        maxlen = 1;
    if (maxlen < minlen)
        maxlen = minlen;

    if (mutex_lock_killable(cetrafs_sb_trim_mutex(sb)))
        return -EINTR;

    nbg = le32_to_cpu(raw_sb->block_group_count);
    for (b = 0; b < nbg && !ret; b++) {
        u64 data_start, data_count, cursor;
        u32 owner;

        if (!cetrafs_sb_bg_is_ours(sb, b))
            continue;
        if (cetrafs_bg_data_region(sb, b, &data_start, &data_count, &owner))
            continue;
        if (data_start + data_count <= start || data_start >= end)
            continue;
        cursor = start > data_start ? start - data_start : 0;

        while (cursor < data_count) {
            struct cetrafs_trim_run run = {.span = {.link = LIST_HEAD_INIT(run.span.link)}};
            u64 lba, count;
            int rc;

            if (fatal_signal_pending(current)) {
                ret = -EINTR;
                break;
            }
            rc = cetrafs_trim_claim_next(sb, b, &cursor, minlen, maxlen, &run);
            if (rc == -ENOSPC || rc == -EAGAIN || rc == -EPERM)
                break; /* nothing more here, or the group is not ours any more */
            if (rc) {
                ret = rc;
                break;
            }
            if (run.lba >= end) {
                cetrafs_trim_release(sb, &run, false);
                break;
            }
            lba = run.lba;
            count = min(run.count, end - run.lba);

            if (cetrafs_trim_discard_stall_ms)
                msleep(cetrafs_trim_discard_stall_ms); /* test-only; see the parameter */
            if (READ_ONCE(cetrafs_discard_aim_at_bitmap) && xchg(&cetrafs_discard_aim_at_bitmap, false)) {
                u64 bmap_lba = 0;

                /* test-only: from the group's FIRST bitmap block -- the one
                 * mapping its live files -- on into the data. */
                if (!cetrafs_bg_data_layout(sb, b, NULL, NULL, &bmap_lba, NULL)) {
                    lba = bmap_lba;
                    count = data_start - bmap_lba + 256;
                }
            }

            rc = cetrafs_trim_hold_durable(sb, &run);
            if (rc) {
                cetrafs_trim_release(sb, &run, false); /* nothing sent */
                ret = rc;
                break;
            }
            rc = cetrafs_discard_issue(sb, b, lba, count);
            cetrafs_trim_release(sb, &run, !cetrafs_discard_outcome_known(rc));
            if (rc == -EOPNOTSUPP || !cetrafs_discard_outcome_known(rc)) {
                /* The device stopped taking them, we are fenced, or the
                 * path is failing: no more this pass. */
                ret = rc;
                break;
            }
            if (!rc)
                trimmed += count;
            cond_resched();
        }
    }

    /*
     * The unowned pool: groups handed back while discard was off went
     * there still mapped, and are trimmed here, once each
     * (cetrafs_bg_trim_pool_one()). Only groups wholly inside the range:
     * trimming less than was asked is allowed, more is not.
     */
    if (!ret && !READ_ONCE(cetrafs_fitrim_skip_pool)) {
        for (b = 0; b < nbg && !ret; b++) {
            u64 data_start, data_count, blocks;
            u32 owner;

            if (fatal_signal_pending(current)) {
                ret = -EINTR;
                break;
            }
            if (cetrafs_sb_bg_is_ours(sb, b))
                continue;
            if (cetrafs_bg_data_region(sb, b, &data_start, &data_count, &owner))
                continue;
            /* Its owner is judged fresh in cetrafs_bg_trim_pool_one(): a
             * cached copy could say "a peer's" of a group in the pool
             * for as long as nothing here re-reads it. */
            if (data_start < start || data_start + data_count > end)
                continue;
            ret = cetrafs_bg_trim_pool_one(sb, b, &blocks);
            if (ret == -ENOENT) {
                ret = 0; /* no Zone Group of ours to claim into: nothing to do */
                break;
            }
            trimmed += blocks;
            cond_resched();
        }
    }
    mutex_unlock(cetrafs_sb_trim_mutex(sb));

    if (ret)
        return ret;
    range.len = trimmed * CETRAFS_BLOCK_SIZE;
    if (copy_to_user(arg, &range, sizeof(range)))
        return -EFAULT;
    return 0;
}

/* ------------------------------------------------------------------ */
/*
 * INLINE DISCARD (`-o discard`, docs/DISCARD-DESIGN.md step 2).
 *
 * Space freed inside a Block Group that STAYS this node's -- a guest's
 * TRIM punching holes in a VM image -- is otherwise given back only when
 * someone runs fstrim. With `discard` on, every run freed in a group
 * this node owns is noted here, and a worker gives it back a moment
 * later, batched.
 *
 * Never on the free path itself: one UNMAP costs a fixed ~25 ms on an
 * array (docs/internal/UNMAP-BENCHMARK.md), a punch of a fragmented
 * range frees thousands of extents, and the free runs under the
 * caller's invalidate_lock. The free path only appends a range to a
 * bounded in-memory queue, under a spinlock, with no allocation and no
 * I/O (cetrafs_inline_discard_note()).
 *
 * The worker is FITRIM, aimed: for each noted range it takes trim_mutex
 * and runs the very claim -> discard -> give-back cycle fstrim runs
 * (cetrafs_trim_claim_next(), cetrafs_discard_issue(),
 * cetrafs_trim_release()), over the bits that read free NOW. A block
 * reallocated since its free reads allocated and is not claimed, so it
 * is not discarded; a block claimed is held against the allocator, the
 * scrub and every free path exactly as fstrim's run is. There is no
 * second discard path to get wrong.
 *
 * When. ext4 waits for the journal commit that makes a free durable
 * before discarding it. Here a free in a group this node owns comes
 * after the publish that stopped referencing the blocks has reached the
 * device (rule 21), so the free is already past that boundary -- which
 * is what lets fstrim discard any free bit at any time, and the worker
 * stands on exactly fstrim's footing. The delay only batches: a burst
 * of frees becomes one sorted, coalesced pass.
 *
 * Best effort, as discarding is everywhere here; freeing never waits on
 * it. A full queue drops the new range (the blocks are free already;
 * only their discard is lost, and fstrim still finds them). The worker
 * gives up -- drops what is queued, counted -- when the mount is
 * closing, stopped or read-only, when discard has been turned off, and
 * when an allocation has just found every owned group full
 * (cetrafs_inline_discard_pressure()): a claimed run is space a writer
 * cannot have, and an ENOSPC must never wait on the array digesting
 * UNMAPs. The queue is preallocated at mount, so memory pressure never
 * reaches the free path through it, and the worker allocates nothing.
 *
 * A discard of UNKNOWN outcome keeps its run allocated for the scrub,
 * its bits synced, and ends the pass (fstrim's handling, in
 * cetrafs_trim_release()); a refused one frees the run and carries on.
 *
 * Lifetime (rule 20): the queue and its delayed work live from mount to
 * cetrafs_inline_discard_close(), which cetrafs_free_sb_info() calls on
 * unmount and on every fill_super failure, after the heartbeat, the
 * scrub and defrag (the other freers) have stopped and before anything
 * the worker reads is torn down. It marks the queue closed under the
 * same spinlock a note queues the work under, then cancels the work
 * synchronously: nothing can queue after it.
 */

/* Ranges the queue holds before it drops new ones. 16 bytes each, two
 * arrays (one filling while the worker owns the other): 128 KiB. */
#define CETRAFS_IDQ_CAP 4096
/* A worker claim is at most this many blocks (32 MiB): the run is out
 * of the allocator's reach while its UNMAP runs. */
#define CETRAFS_IDQ_MAX_RUN_BLOCKS (1ULL << 13)
/* How long after a no-space verdict the worker keeps giving up. */
#define CETRAFS_IDQ_PRESSURE_SECS 5
#define CETRAFS_IDQ_DELAY_MS 1000

struct cetrafs_idq_ent {
    u64 lba;
    u32 count;
    u32 bg;
};

struct cetrafs_inline_discard {
    struct super_block *sb;
    spinlock_t lock;
    struct cetrafs_idq_ent *fill; /* notes append here, under 'lock' */
    struct cetrafs_idq_ent *work; /* the worker's batch (one worker runs at a time) */
    u32 n;
    bool on;                   /* the `discard` mount option / `inline_discard` control */
    bool closed;               /* cetrafs_inline_discard_close() began: nothing queues */
    unsigned long pressure_at; /* jiffies of the last no-space verdict; 0: none */
    struct delayed_work dwork;
    atomic64_t queued;  /* ranges noted */
    atomic64_t dropped; /* ranges lost to a full queue */
    atomic64_t gave_up; /* ranges the worker dropped: pressure, closing, off, a failing path */
    atomic64_t cmds;    /* discards the worker issued */
    atomic64_t blocks;  /* the blocks they covered */
};

/* TEST ONLY: the worker's batching delay, in ms (0: the default). */
static unsigned int cetrafs_inline_discard_delay_ms;
cetrafs_test_param(inline_discard_delay_ms, cetrafs_inline_discard_delay_ms, uint, 0644);
MODULE_PARM_DESC(inline_discard_delay_ms, "TEST ONLY: the inline-discard worker's batching delay, in ms");

/* TEST ONLY: hold the worker this long between a claim and its discard,
 * so a writer allocates while the UNMAP is still to come
 * (tests/kernel/inline_discard_claim.sh). The claim itself is disabled
 * with trim_skip_claim, fstrim's control, since it is the same claim. */
static unsigned int cetrafs_inline_discard_stall_ms;
cetrafs_test_param(inline_discard_stall_ms, cetrafs_inline_discard_stall_ms, uint, 0644);
MODULE_PARM_DESC(inline_discard_stall_ms, "TEST ONLY: pause between an inline-discard claim and its discard");

/* TEST ONLY: the worker ignores space pressure and a closing mount --
 * the negative control for the give-up
 * (tests/kernel/inline_discard_give_up.sh). */
static bool cetrafs_inline_discard_never_give_up;
cetrafs_test_param(inline_discard_never_give_up, cetrafs_inline_discard_never_give_up, bool, 0644);
MODULE_PARM_DESC(inline_discard_never_give_up, "TEST ONLY: the inline-discard worker ignores pressure and unmount");

static void cetrafs_inline_discard_work(struct work_struct *w);

struct cetrafs_inline_discard *cetrafs_inline_discard_create(struct super_block *sb, bool on)
{
    struct cetrafs_inline_discard *d = kzalloc(sizeof(*d), GFP_KERNEL);

    if (!d)
        return NULL;
    d->fill = kvcalloc(CETRAFS_IDQ_CAP, sizeof(*d->fill), GFP_KERNEL);
    d->work = kvcalloc(CETRAFS_IDQ_CAP, sizeof(*d->work), GFP_KERNEL);
    if (!d->fill || !d->work) {
        kvfree(d->fill);
        kvfree(d->work);
        kfree(d);
        return NULL;
    }
    d->sb = sb;
    d->on = on;
    spin_lock_init(&d->lock);
    INIT_DELAYED_WORK(&d->dwork, cetrafs_inline_discard_work);
    return d;
}

/*
 * The drain (rule 20). Once it returns no work is pending or running,
 * and none can be queued: a note tests 'closed' and queues the work
 * under the lock this sets it under. What was queued is dropped (counted
 * as given up). The memory stays until _destroy().
 */
void cetrafs_inline_discard_close(struct cetrafs_inline_discard *d)
{
    u32 n;

    if (!d)
        return;
    spin_lock(&d->lock);
    d->closed = true;
    spin_unlock(&d->lock);
    cancel_delayed_work_sync(&d->dwork);
    spin_lock(&d->lock);
    n = d->n;
    atomic64_add(n, &d->gave_up);
    d->n = 0;
    spin_unlock(&d->lock);
    if (n)
        pr_info("%s: inline discard: dropped %u queued range(s) (unmount)\n", d->sb->s_id, n);
}

void cetrafs_inline_discard_destroy(struct cetrafs_inline_discard *d)
{
    if (!d)
        return;
    cetrafs_inline_discard_close(d); /* idempotent */
    kvfree(d->fill);
    kvfree(d->work);
    kfree(d);
}

bool cetrafs_inline_discard_on(struct super_block *sb)
{
    struct cetrafs_inline_discard *d = cetrafs_sb_inline_discard(sb);

    return d && READ_ONCE(d->on);
}

void cetrafs_inline_discard_set(struct super_block *sb, bool on)
{
    struct cetrafs_inline_discard *d = cetrafs_sb_inline_discard(sb);

    if (d)
        WRITE_ONCE(d->on, on);
}

/* An allocation found every owned group full (zonegroup.c): the worker
 * stops claiming space for a while. */
void cetrafs_inline_discard_pressure(struct super_block *sb)
{
    struct cetrafs_inline_discard *d = cetrafs_sb_inline_discard(sb);

    if (d)
        WRITE_ONCE(d->pressure_at, jiffies ? jiffies : 1);
}

/*
 * From the free paths, once bits of [lba, +count) in Block Group 'bg' --
 * one this node owns -- have been cleared. Under the caller's locks: a
 * spinlock, an append or a merge into the last entry, never I/O and
 * never an allocation.
 */
void cetrafs_inline_discard_note(struct super_block *sb, u32 bg, u64 lba, u32 count)
{
    struct cetrafs_inline_discard *d = cetrafs_sb_inline_discard(sb);
    unsigned int delay;
    struct cetrafs_idq_ent *last;

    if (!d || !count || !READ_ONCE(d->on) || !cetrafs_sb_discard_enabled(sb))
        return;
    delay = READ_ONCE(cetrafs_inline_discard_delay_ms);
    if (!delay)
        delay = CETRAFS_IDQ_DELAY_MS;
    spin_lock(&d->lock);
    if (d->closed) {
        spin_unlock(&d->lock);
        return;
    }
    last = d->n ? &d->fill[d->n - 1] : NULL;
    if (last && last->bg == bg && last->lba + last->count == lba && (u64) last->count + count <= U32_MAX) {
        last->count += count; /* the common case: a punch frees its extents in order */
    } else if (d->n < CETRAFS_IDQ_CAP) {
        d->fill[d->n].lba = lba;
        d->fill[d->n].count = count;
        d->fill[d->n].bg = bg;
        d->n++;
    } else {
        atomic64_inc(&d->dropped);
        spin_unlock(&d->lock);
        return; /* free already; only the discard is lost */
    }
    atomic64_inc(&d->queued);
    /* Under the lock, so close() cannot fall between the test of
     * 'closed' and this (rule 20). A no-op while already pending. */
    queue_delayed_work(system_unbound_wq, &d->dwork, msecs_to_jiffies(delay));
    spin_unlock(&d->lock);
}

static int cetrafs_idq_cmp(const void *a, const void *b)
{
    const struct cetrafs_idq_ent *x = a, *y = b;

    return x->lba < y->lba ? -1 : x->lba > y->lba;
}

/* Why the worker must stop now, or NULL. */
static const char *cetrafs_idq_give_up(struct cetrafs_inline_discard *d)
{
    struct super_block *sb = d->sb;
    unsigned long p = READ_ONCE(d->pressure_at);

    if (READ_ONCE(cetrafs_inline_discard_never_give_up))
        return NULL; /* test-only; see the parameter */
    if (READ_ONCE(d->closed))
        return "unmount";
    if (cetrafs_sb_is_fenced(sb))
        return "stopped";
    if (sb_rdonly(sb))
        return "read-only";
    if (!READ_ONCE(d->on) || !cetrafs_sb_discard_enabled(sb) || !cetrafs_discard_supported(sb))
        return "off";
    if (p && time_before(jiffies, p + CETRAFS_IDQ_PRESSURE_SECS * HZ))
        return "no space";
    return NULL;
}

/*
 * One noted range, through fstrim's cycle. 0: done, go on. 1: the
 * worker must give up (cetrafs_idq_give_up()), part way through this
 * range. Negative: the discard's error, and the pass ends (unsupported,
 * stopped, unknown outcome).
 */
static int cetrafs_idq_range(struct cetrafs_inline_discard *d, const struct cetrafs_idq_ent *e, u64 minlen,
                             u64 maxlen)
{
    struct super_block *sb = d->sb;
    u64 data_start, data_count, cursor, end_bit, end_lba;
    u32 owner;

    if (cetrafs_bg_data_region(sb, e->bg, &data_start, &data_count, &owner))
        return 0;
    if (e->lba < data_start || e->lba + e->count > data_start + data_count)
        return 0; /* not this group's data: the discard's own check would refuse it */
    cursor = e->lba - data_start;
    end_bit = cursor + e->count;
    end_lba = e->lba + e->count;

    while (cursor < end_bit) {
        struct cetrafs_trim_run run = {.span = {.link = LIST_HEAD_INIT(run.span.link)}};
        u64 count;
        int rc;

        if (cetrafs_idq_give_up(d))
            return 1;
        rc = cetrafs_trim_claim_next(sb, e->bg, &cursor, minlen, max(min(maxlen, end_bit - cursor), minlen), &run);
        if (rc)
            return 0; /* nothing free here any more, or the group is not ours (drained, released) */
        if (run.lba >= end_lba) {
            cetrafs_trim_release(sb, &run, false);
            return 0;
        }
        count = min(run.count, end_lba - run.lba);
        if (cetrafs_inline_discard_stall_ms) {
            /* test-only; see the parameter */
            pr_info("%s: inline discard: claimed [%llu +%llu), pausing %u ms (test)\n", sb->s_id,
                    (unsigned long long) run.lba, (unsigned long long) count, cetrafs_inline_discard_stall_ms);
            msleep(cetrafs_inline_discard_stall_ms);
        }
        rc = cetrafs_trim_hold_durable(sb, &run);
        if (rc) {
            cetrafs_trim_release(sb, &run, false); /* nothing sent */
            return rc;
        }
        rc = cetrafs_discard_issue(sb, e->bg, run.lba, count);
        cetrafs_trim_release(sb, &run, !cetrafs_discard_outcome_known(rc));
        if (rc == -EOPNOTSUPP || !cetrafs_discard_outcome_known(rc))
            return rc; /* the device stopped taking them, we are stopped, or the path is failing */
        if (!rc) {
            atomic64_inc(&d->cmds);
            atomic64_add((s64) count, &d->blocks);
        }
        cond_resched();
    }
    return 0;
}

static void cetrafs_inline_discard_work(struct work_struct *w)
{
    struct cetrafs_inline_discard *d = container_of(to_delayed_work(w), struct cetrafs_inline_discard, dwork);
    struct super_block *sb = d->sb;
    struct cetrafs_idq_ent *batch;
    const char *why;
    u64 gran, minlen, maxlen;
    u32 n, i, m;

    /* Take the filled array; notes go on into the other one. A work
     * item never runs concurrently with itself, so 'work' is ours
     * until we return. */
    spin_lock(&d->lock);
    batch = d->fill;
    d->fill = d->work;
    d->work = batch;
    n = d->n;
    d->n = 0;
    spin_unlock(&d->lock);
    if (!n)
        return;

    /* Sorted and coalesced: frees from many files and many moments
     * become the fewest ranges -- an UNMAP costs per command. */
    sort(batch, n, sizeof(*batch), cetrafs_idq_cmp, NULL);
    for (i = 1, m = 0; i < n; i++) {
        struct cetrafs_idq_ent *p = &batch[m];

        if (batch[i].bg == p->bg && batch[i].lba <= p->lba + p->count) {
            u64 e = max(p->lba + p->count, batch[i].lba + batch[i].count);

            if (e - p->lba <= U32_MAX) {
                p->count = (u32) (e - p->lba);
                continue;
            }
        }
        batch[++m] = batch[i];
    }
    n = m + 1;

    gran = DIV_ROUND_UP((u64) bdev_discard_granularity(sb->s_bdev), CETRAFS_BLOCK_SIZE);
    minlen = max(gran, 1ULL);
    maxlen = min_t(u64, bdev_max_discard_sectors(sb->s_bdev) / (CETRAFS_BLOCK_SIZE >> SECTOR_SHIFT),
                   CETRAFS_IDQ_MAX_RUN_BLOCKS);
    if (maxlen < minlen)
        maxlen = minlen;

    i = 0;
    why = cetrafs_idq_give_up(d);
    if (!why) {
        mutex_lock(cetrafs_sb_trim_mutex(sb)); /* one claim at a time, fstrim's included */
        for (; i < n; i++) {
            int rc;

            why = cetrafs_idq_give_up(d);
            if (why)
                break;
            rc = cetrafs_idq_range(d, &batch[i], minlen, maxlen);
            if (rc > 0) {
                why = cetrafs_idq_give_up(d) ?: "gave up";
                break; /* stopped part way: counted with the rest */
            }
            if (rc < 0) {
                why = "a discard failed";
                i++; /* that range went as far as it could */
                break;
            }
        }
        mutex_unlock(cetrafs_sb_trim_mutex(sb));
    }
    if (why && i < n) {
        atomic64_add(n - i, &d->gave_up);
        pr_info_ratelimited("%s: inline discard: dropped %u queued range(s) (%s)\n", sb->s_id, n - i, why);
    }
}

void cetrafs_inline_discard_counts(struct super_block *sb, u64 *queued, u64 *dropped, u64 *gave_up, u64 *cmds,
                                   u64 *blocks)
{
    struct cetrafs_inline_discard *d = cetrafs_sb_inline_discard(sb);

    *queued = d ? (u64) atomic64_read(&d->queued) : 0;
    *dropped = d ? (u64) atomic64_read(&d->dropped) : 0;
    *gave_up = d ? (u64) atomic64_read(&d->gave_up) : 0;
    *cmds = d ? (u64) atomic64_read(&d->cmds) : 0;
    *blocks = d ? (u64) atomic64_read(&d->blocks) : 0;
}
