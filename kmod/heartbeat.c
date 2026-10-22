// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * heartbeat.c -- periodic heartbeat renewal + stale ZG reclaim.
 *
 * Phase 9's node heartbeat and phase 12's open-file lock are each only
 * ever written once (at claim time), with nothing refreshing or
 * re-checking them afterward -- so a node that crashes while holding a
 * ZG or a file lock strands it permanently. This file adds the missing
 * periodic side: a self-rearming delayed_work, started in fs.c's
 * fill_super() and stopped synchronously in super_ops.c's put_super()
 * (via cetrafs_free_sb_info(), before the backing device is touched),
 * that on every tick:
 *
 *   1. renews this node's own Node Registry row (node.c's
 *      cetrafs_node_renew_heartbeat()), so peers watching it don't
 *      mistake a merely-busy node for a dead one;
 *   2. re-runs zonegroup.c's cetrafs_zg_claim_unowned() -- the same
 *      claim pass fs.c already does once at mount, now also eligible
 *      to steal a ZG from a node whose heartbeat has gone stale
 *      (node.c's cetrafs_node_is_stale());
 *   3. runs zonegroup.c's cetrafs_zg_release_surplus() --
 *      the release-side mirror of (2): gives back any owned ZG that's
 *      gone completely empty since it was claimed, keeping at least
 *      one, so a node that no longer needs the extra capacity it once
 *      claimed doesn't sit on it forever and starve a peer that does;
 *   4. sweeps for stale peers whose per-node
 *      journal still reads dirty and replays them -- the catch-all for
 *      a crashed node nothing else (ZG steal, lock reclaim) has had a
 *      reason to replay yet.
 *

 * A crashed node's *file* lock is reclaimed lazily instead, at the
 * point another node's open() actually needs it (lock.c) -- walking
 * every inode on every tick just to notice a handful of locked files
 * would be wasteful, and nothing needs to know about a stale file lock
 * except whoever next tries to open that file.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/fs.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/moduleparam.h>
#include <linux/slab.h>
#include <linux/workqueue.h>

#include "kmod.h"

/*
 * Test-only: suppress the fence pre-check so the RENEW becomes the sole
 * detector of a revoked lease.
 *
 * The pre-check and the renew detect the same condition, but only the
 * renew does it atomically -- and the gap between them is exactly where
 * the bug lived that this exists to test. The renew used to be a
 * read / modify / blind-write, so a peer revoking in that gap had its
 * fence_epoch bump silently REVERTED, after which the node never fenced
 * again. That window is microseconds wide and cannot be hit by poking
 * the row from userspace, which is why the original fence test passed
 * just as happily against the broken code. Taking the pre-check out of
 * the way makes the renew's own behaviour observable, and the test
 * deterministic.
 *
 * Off by default; nothing in normal operation touches it.
 */
/*
 * Heartbeat period. A module param for the same reason stale_secs is
 * (node.c): staleness assertions otherwise cost a real minute each, and
 * a reclaim only happens on a tick. Keep it well below stale_secs --
 * several ticks must fit inside the stale window, or ordinary jitter
 * starts looking like a dead node.
 */
unsigned int cetrafs_hb_interval_secs = CETRAFS_HEARTBEAT_INTERVAL_SECS;
module_param_named(hb_interval_secs, cetrafs_hb_interval_secs, uint, 0644);
MODULE_PARM_DESC(
    hb_interval_secs,
    "seconds between heartbeat ticks (UNBOUNDED test knob; operator limits are on the per-mount controls file)");

static bool cetrafs_fence_skip_precheck;
module_param_named(fence_skip_precheck, cetrafs_fence_skip_precheck, bool, 0644);
MODULE_PARM_DESC(fence_skip_precheck,
                 "test-only: skip the heartbeat's fence pre-check so the renew alone detects a revoked lease");

static void cetrafs_heartbeat_tick(struct work_struct *work)
{
    struct cetrafs_heartbeat *hb = container_of(work, struct cetrafs_heartbeat, work.work);
    struct super_block *sb = hb->sb;
    u32 my_node_id;
    u8 my_uuid[CETRAFS_NODE_UUID_LEN];
    int ret;

    /* Self-fence latch: a fenced node's tick does NOTHING
     * -- renewing our row would make us look alive again and fight the
     * very reclaim that fenced us; claims/drains/releases are writes we
     * no longer have any right to make. Keep rescheduling only so the
     * log reminder below stays alive in long-running setups. */
    if (cetrafs_sb_is_fenced(sb))
        goto reschedule;

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret) {
        pr_warn("heartbeat: failed to get our own node id: %d\n", ret);
        goto reschedule;
    }

    /* The registry lease: any peer that reclaimed
     * something of ours after deciding we were stale bumped our row's
     * fence_epoch. Checked BEFORE renewing: renewing would re-assert a
     * liveness we are no longer entitled to, and fight the reclaim.
     *
     * This replaced watching our own SCSI PR registration:
     * that worked only because the dead-holder recovery removed a
     * stale-looking node's registration, and it went away with PR. */
    if (!cetrafs_fence_skip_precheck) {
        bool fenced = false;

        if (cetrafs_node_self_fence_check(sb, my_node_id, &fenced) == 0 && fenced) {
            cetrafs_sb_fence(sb, "our Node Registry lease was revoked by a peer");
            goto reschedule;
        }
    }

    ret = cetrafs_node_renew_heartbeat(sb, my_node_id);
    if (ret == -EPERM) {
        /* The renew itself found our lease revoked. This is the
         * authoritative detection -- the check above races, since a peer
         * can revoke between it and here, whereas the renew tests and
         * renews in one compare-and-swap. */
        cetrafs_sb_fence(sb, "our Node Registry lease was revoked, found while renewing it");
        goto reschedule;
    }
    if (ret)
        pr_warn("heartbeat: failed to renew our own row: %d\n", ret);

    /* Everything past the renewal WRITES to shared state: it claims and
     * releases Zone Groups, applies peers' queued frees to their
     * bitmaps, and replays dead peers' journals into their data
     * regions. A read-only mount does none of it -- it renews its own
     * registry row (so peers see it as alive and honour the read-
     * presence bits it publishes) and nothing else. */
    if (sb_rdonly(sb))
        goto reschedule;

    ret = cetrafs_sb_get_node_uuid(sb, my_uuid);
    if (ret) {
        pr_warn("heartbeat: failed to get our own node uuid: %d\n", ret);
        goto reschedule;
    }

    ret = cetrafs_zg_claim_unowned(sb, my_node_id, my_uuid, /*at_mount=*/false);
    if (ret)
        pr_warn("heartbeat: stale ZG reclaim pass failed: %d\n", ret);

    /* Apply any frees other nodes queued against ZGs we own
     * before the release-surplus pass below, so a ZG these frees
     * just emptied can be given back on this same tick. */
    ret = cetrafs_zg_drain_pending_frees(sb);
    if (ret)
        pr_warn("heartbeat: pending-free drain pass failed: %d\n", ret);

    ret = cetrafs_zg_release_surplus(sb, my_node_id);
    if (ret)
        pr_warn("heartbeat: surplus ZG release pass failed: %d\n", ret);

    /* 4. sweep for stale peers whose per-node journal flag
     * still reads dirty and replay them -- the catch-all for a crashed
     * node that owned no ZG and held no lock anyone has since asked
     * about (the ZG-claim and lock-reclaim paths already replay a stale
     * node's journal themselves, promptly, at the moment it matters;
     * this sweep just makes sure nobody is missed entirely). The cheap
     * flag read gates the expensive mutex+scan, so a quiet cluster pays
     * one uncached block read per registered peer per tick. */
    {
        const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
        u32 count = raw_sb ? le32_to_cpu(raw_sb->node_table_count) : 0;
        u32 n;

        for (n = 0; n < count; n++) {
            cetrafs_node_entry_t ne;
            bool stale = false, dirty = false;

            if (n == my_node_id)
                continue;
            ret = cetrafs_node_get_entry(sb, n, &ne);
            /* A device error means every remaining row will fail the
             * same way, so stop rather than grinding through all 64 --
             * each costs a full retry budget against a device that is
             * simply not there. Measured as the bulk of a ~500-line
             * log flood in eight seconds when the LUN went away. A
             * per-row error (a bad checksum on one row) is different
             * and still just skips that row. */
            if (ret == -EIO)
                break;
            if (ret || ne.state == CETRAFS_NODE_STATE_FREE)
                continue;
            if (cetrafs_node_is_stale(sb, n, &stale) || !stale)
                continue;
            if (cetrafs_journal_node_is_dirty(sb, n, &dirty) || !dirty)
                continue;

            /* Revoke its lease BEFORE replaying, exactly as the ZG-steal
             * and lock-reclaim paths do (zonegroup.c, lock.c). This was
             * the one replay site that did not, and it is the site where
             * nothing else has fenced the peer -- it exists precisely
             * for a node nobody has taken a ZG or a lock from.
             *
             * A dirty journal on a node that is merely SLOW rather than
             * dead means it is mid-operation, still holding that
             * operation's lock. Replaying blind-writes its recorded
             * block images over blocks it is still working, and zeroes
             * the slot headers it is still writing into -- destroying
             * the write-ahead protection of the very operation in
             * flight. That is the hazard journal.c's attach path
             * already names and waits out for our OWN area; here the
             * fence is what makes the peer stop.
             *
             * Only on the dirty path: fencing a stale-but-clean peer
             * every tick would force a remount on a node that is slow
             * and doing nothing wrong. We fence when we take its state,
             * which is what the other callers do too. */
            cetrafs_node_fence_peer(sb, n, "a stale node's dirty journal");

            ret = cetrafs_journal_replay_node(sb, n, /*wait_for_claim=*/false);
            if (ret)
                pr_warn("heartbeat: replay of stale node %u's journal failed: %d\n", n, ret);
        }
    }

reschedule:
    queue_delayed_work(system_long_wq, &hb->work, msecs_to_jiffies(cetrafs_sb_hb_interval_secs(sb) * 1000));
}

/* This node's heartbeat period, for publishing in its registry row so
 * peers can floor their staleness window at several of OUR beats rather
 * than guessing from their own configuration. */
unsigned int cetrafs_heartbeat_interval_secs(struct super_block *sb)
{
    return cetrafs_sb_hb_interval_secs(sb);
}

int cetrafs_heartbeat_start(struct super_block *sb, struct cetrafs_heartbeat **out_hb)
{
    struct cetrafs_heartbeat *hb = kzalloc(sizeof(*hb), GFP_KERNEL);

    if (!hb)
        return -ENOMEM;

    hb->sb = sb;
    INIT_DELAYED_WORK(&hb->work, cetrafs_heartbeat_tick);
    queue_delayed_work(system_long_wq, &hb->work, msecs_to_jiffies(cetrafs_sb_hb_interval_secs(sb) * 1000));

    *out_hb = hb;
    return 0;
}

/*
 * cancel_delayed_work_sync() correctly handles a delayed_work that
 * re-arms itself from inside its own callback (it keeps retrying the
 * cancel until no further requeue beats it) -- no separate "stop"
 * flag needed. Safe to call with hb == NULL (every cetrafs_free_sb_info()
 * call site before fill_super() reaches cetrafs_heartbeat_start()).
 */
void cetrafs_heartbeat_stop(struct cetrafs_heartbeat *hb)
{
    if (!hb)
        return;

    cancel_delayed_work_sync(&hb->work);
    kfree(hb);
}
