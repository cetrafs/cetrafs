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
#include <linux/uaccess.h>

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
static atomic64_t cetrafs_discard_handback_deferred = ATOMIC64_INIT(0);

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

/* TEST ONLY: hold a claimed run this long before its discard, so a
 * writer allocates while the UNMAP is still to come
 * (tests/kernel/fstrim_claim.sh). */
static unsigned int cetrafs_trim_discard_stall_ms;
cetrafs_test_param(trim_discard_stall_ms, cetrafs_trim_discard_stall_ms, uint, 0644);
MODULE_PARM_DESC(trim_discard_stall_ms, "TEST ONLY: pause between a FITRIM claim and its discard");

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
static int cetrafs_discard_issue(struct super_block *sb, u32 bg_id, u64 lba, u64 count)
{
    u64 data_start, data_count;
    u32 owner, first_bg, last_bg;
    int ret;

    if (!count)
        return 0;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    ret = cetrafs_bg_data_region(sb, bg_id, &data_start, &data_count, &owner);
    if (ret)
        return ret;
    if (lba < data_start || lba + count > data_start + data_count || lba + count < lba ||
        cetrafs_bg_id_of_lba(sb, lba, &first_bg) || cetrafs_bg_id_of_lba(sb, lba + count - 1, &last_bg) ||
        first_bg != bg_id || last_bg != bg_id) {
        atomic64_inc(&cetrafs_discard_refused);
        pr_err("%s: discard [%llu +%llu) is not inside BG %u's data region [%llu +%llu) -- refused\n", sb->s_id,
               (unsigned long long) lba, (unsigned long long) count, bg_id, (unsigned long long) data_start,
               (unsigned long long) data_count);
        return -EUCLEAN;
    }

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
 * The hand-back half, from cetrafs_bg_release_empty() with BG 'bg_id'
 * drained and its bitmap proven empty on the device. 0: release it (the
 * region was discarded, or discard is off, unsupported or failed).
 * -EBUSY: this pass's budget is spent -- keep the group and release it
 * on a later tick, so the space it holds is never handed back
 * untrimmed while discard is on. The first group of every pass is
 * always attempted (it starts the clock), so each pass makes progress.
 * Also -EBUSY when the discard failed with an UNKNOWN outcome: it may
 * still execute, and once the group reads FREE a peer can claim it and
 * write into it first. Kept, it is discarded again on a later tick;
 * nothing allocates in an empty group this node is releasing.
 */
int cetrafs_discard_handback(struct super_block *sb, u32 bg_id, unsigned long *pass_started)
{
    unsigned int budget = READ_ONCE(cetrafs_handback_budget_ms);
    u64 data_start, data_count;
    u32 owner;
    int ret;

    if (!cetrafs_sb_discard_enabled(sb) || !cetrafs_discard_supported(sb) || cetrafs_sb_is_fenced(sb))
        return 0;
    if (!budget)
        budget = CETRAFS_HANDBACK_TRIM_BUDGET_MS;
    if (!*pass_started) {
        *pass_started = jiffies ? jiffies : 1;
    } else if (time_after(jiffies, *pass_started + msecs_to_jiffies(budget))) {
        atomic64_inc(&cetrafs_discard_handback_deferred);
        return -EBUSY;
    }
    if (cetrafs_bg_data_region(sb, bg_id, &data_start, &data_count, &owner))
        return 0;
    ret = cetrafs_discard_issue(sb, bg_id, data_start, data_count);
    if (!ret)
        atomic64_inc(&cetrafs_discard_handback_bgs);
    else if (!cetrafs_discard_outcome_known(ret))
        return -EBUSY;
    return 0;
}

/*
 * FITRIM. The range is in bytes, as fstrim(8) passes it; on return
 * range.len is the number of bytes discarded.
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
    mutex_unlock(cetrafs_sb_trim_mutex(sb));

    if (ret)
        return ret;
    range.len = trimmed * CETRAFS_BLOCK_SIZE;
    if (copy_to_user(arg, &range, sizeof(range)))
        return -EFAULT;
    return 0;
}
