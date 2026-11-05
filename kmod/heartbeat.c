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

#include <linux/delay.h>
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

/* TEST ONLY: fail every heartbeat renewal without touching the device,
 * as a hung or unreachable LUN would (tests/kernel/lease_expiry.sh). */
static bool cetrafs_hb_renew_fail;
cetrafs_test_param(hb_renew_fail, cetrafs_hb_renew_fail, bool, 0644);
MODULE_PARM_DESC(hb_renew_fail, "TEST ONLY: fail every heartbeat renewal");

static bool cetrafs_fence_skip_precheck;
cetrafs_test_param(fence_skip_precheck, cetrafs_fence_skip_precheck, bool, 0644);
MODULE_PARM_DESC(fence_skip_precheck,
                 "test-only: skip the heartbeat's fence pre-check so the renew alone detects a revoked lease");

/*
 * Test-only: drop one Zone Group out of this node's OWNERSHIP CACHE,
 * leaving the on-disk record untouched.
 *
 * That is the state a ZG is in between leaving this node and coming
 * back -- and the next tick's re-attach then re-seeds its Block Groups'
 * count epochs, which is the exact seam a delta accrued before the
 * handover must not survive (tests/kernel/bg_delta_vs_reattach.sh).
 * Reaching it for real needs a second node taking the ZG and dying;
 * single-node, there is no other way in. Consumed on use, so one write
 * arms exactly one re-attach.
 */
static int cetrafs_test_uncache_zg = -1;
cetrafs_test_param(test_uncache_zg, cetrafs_test_uncache_zg, int, 0644);
MODULE_PARM_DESC(test_uncache_zg, "TEST ONLY: forget owning this zone group, so the next tick re-attaches to it");

/*
 * TEST ONLY: make the maintenance pass take this long.
 *
 * Its real duration is a dead peer's journal replay, a whole-registry
 * scan or a pending-free drain against a device that is answering
 * slowly -- none of which a single-node rig can produce on demand, and
 * all of which used to push the next lease renewal out by exactly that
 * much. See tests/kernel/heartbeat_renew_cadence.sh.
 */
static unsigned int cetrafs_hb_maint_delay_ms;
/* Completed stale-journal sweeps (the end of the maintenance pass): a
 * pass parked behind a lock stops this counter. */
static atomic64_t cetrafs_hb_sweeps = ATOMIC64_INIT(0);
cetrafs_test_param(hb_maint_delay_ms, cetrafs_hb_maint_delay_ms, uint, 0644);
MODULE_PARM_DESC(hb_maint_delay_ms, "TEST ONLY: milliseconds the heartbeat's maintenance pass takes");

static void cetrafs_heartbeat_tick(struct work_struct *work)
{
    struct cetrafs_heartbeat *hb = container_of(work, struct cetrafs_heartbeat, work.work);
    struct super_block *sb = hb->sb;
    u32 my_node_id;
    unsigned long lease_t0;
    unsigned int lease_interval;
    int ret;

    /*
     * Re-arm BEFORE doing anything, not after.
     *
     * A peer decides we are dead by watching our hb_seq stop advancing
     * for longer than its window (timed on the peer's own clock), so
     * the renewal's period is the only number that window is measured
     * against. Arming at the END of the tick made that period
     * "interval PLUS however long this tick took" -- and the tick also
     * claimed Zone Groups, drained peers' queued frees and replayed a
     * dead node's journal, none of which has a bound. A slow device
     * turned a 10-second heartbeat into minutes and a live node into a
     * fenced one.
     *
     * The work item cannot run twice at once, so arming first costs
     * nothing when a tick overruns: the next one simply starts as soon
     * as this returns.
     */
    queue_delayed_work(system_long_wq, &hb->work, msecs_to_jiffies(cetrafs_sb_hb_interval_secs(sb) * 1000));

    if (cetrafs_test_uncache_zg >= 0) {
        u32 zg = (u32) cetrafs_test_uncache_zg;

        cetrafs_test_uncache_zg = -1;
        pr_info("heartbeat: TEST: forgetting ownership of ZG %u in cache\n", zg);
        cetrafs_sb_uncache_zg_ownership(sb, zg);
    }

    /* Self-fence latch: a fenced node's tick does NOTHING
     * -- renewing our row would make us look alive again and fight the
     * very reclaim that fenced us; claims/drains/releases are writes we
     * no longer have any right to make.
     *
     * It does one thing with no I/O: discard metadata dirtied since the
     * stop by an operation that had already passed its gate, before the
     * block device's own writeback gets to it (30 s by default; a tick
     * is at most 15). sync_fs does the same at unmount. */
    if (cetrafs_sb_is_fenced(sb)) {
        if (sb->s_bdev) {
            unsigned long n = cetrafs_drop_dirty_metadata(sb);

            if (n)
                pr_err("%s: stopped mount: discarded %lu metadata buffer(s) dirtied after the stop\n", sb->s_id,
                       n);
        }
        goto reschedule;
    }

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

    /* The lease is counted from BEFORE the renewal: a peer starts its
     * watch no earlier than when the new hb_seq lands, which is later. */
    lease_t0 = jiffies;
    lease_interval = cetrafs_heartbeat_interval_secs(sb);
    ret = cetrafs_hb_renew_fail ? -EIO /* test-only, see the parameter */
                                : cetrafs_node_renew_heartbeat(sb, my_node_id);
    if (ret == 0)
        /* The smaller of the intervals before and after: the row
         * advertises one of them, and controls may have moved it. */
        cetrafs_sb_lease_renewed(sb, lease_t0, min(lease_interval, cetrafs_heartbeat_interval_secs(sb)));
    if (ret == -EPERM) {
        /* The renew itself found our lease revoked. This is the
         * authoritative detection -- the check above races, since a peer
         * can revoke between it and here, whereas the renew tests and
         * renews in one compare-and-swap. */
        cetrafs_sb_fence(sb, "our Node Registry lease was revoked, found while renewing it");
        goto reschedule;
    }
    if (ret == -EOWNERDEAD) {
        cetrafs_sb_fence(sb, "our Node Registry row is no longer ours (freed, or taken by another node or a repairer)");
        goto reschedule;
    }
    if (ret)
        pr_warn("heartbeat: failed to renew our own row: %d\n", ret);

    /* The heavy half runs as its OWN work item -- see
     * cetrafs_heartbeat_maint(). A read-only mount queues it too, for
     * the one retry it owes: see there. */
    queue_delayed_work(system_long_wq, &hb->maint, 0);

reschedule:
    return;
}


/*
 * Everything the tick does that is NOT the lease renewal: claim and
 * release Zone Groups, retry deferred namespace-lock releases, apply
 * peers' queued frees, replay a dead peer's journal.
 *
 * All of it writes to shared state, all of it can block on the device
 * for as long as the device feels like, and none of it has a deadline
 * -- which is exactly why it must not share a work item with the one
 * thing that does.
 */
static void cetrafs_heartbeat_maint(struct work_struct *work)
{
    struct cetrafs_heartbeat *hb = container_of(work, struct cetrafs_heartbeat, maint.work);
    struct super_block *sb = hb->sb;
    u32 my_node_id;
    u8 my_uuid[CETRAFS_NODE_UUID_LEN];
    int ret;

    if (cetrafs_hb_maint_delay_ms)
        msleep(cetrafs_hb_maint_delay_ms); /* test-only; see the parameter */

    /* Re-checked here, not inherited from the renewal that queued us:
     * a peer may have fenced us in between, and these are all writes we
     * would no longer have any right to make. */
    if (cetrafs_sb_is_fenced(sb))
        return;

    /* Everything below WRITES to shared state: it claims and releases
     * Zone Groups, applies peers' queued frees to their bitmaps, and
     * replays dead peers' journals into their data regions. A read-only
     * mount does none of it. It does publish read-presence bits, though
     * -- that is what stops a peer destroying a file it is reading --
     * and a withdraw that failed is cleared by nobody else while this
     * node beats: every peer write-open, unlink and truncate of that file
     * got ETXTBSY for the life of the observer mount. So that retry, and
     * nothing else. */
    if (sb_rdonly(sb)) {
        cetrafs_lock_retry_presence(sb);
        return;
    }

    if (cetrafs_sb_get_node_id(sb, &my_node_id))
        return;

    ret = cetrafs_sb_get_node_uuid(sb, my_uuid);
    if (ret) {
        pr_warn("heartbeat: failed to get our own node uuid: %d\n", ret);
        return;
    }

    ret = cetrafs_zg_claim_unowned(sb, my_node_id, my_uuid, /*at_mount=*/false);
    if (ret)
        pr_warn("heartbeat: stale ZG reclaim pass failed: %d\n", ret);

    /* Apply any frees other nodes queued against ZGs we own
     * before the release-surplus pass below, so a ZG these frees
     * just emptied can be given back on this same tick. */
    /* Namespace locks we took and could not give back. Stale reclaim
     * will not come for them -- it fires for a node that stopped
     * heartbeating, and we are the one beating. */
    cetrafs_nslock_retry_deferred(sb);
    /* Same, for file locks: a lock this node kept because its last close
     * could not finish is reclaimed by nobody while we keep beating. */
    cetrafs_lock_retry_deferred(sb);
    /* And presence bits: a live node's bit is cleared by nobody else. */
    cetrafs_lock_retry_presence(sb);
    /* And inode-number reclaim claims, for the same reason. */
    cetrafs_alloc_retry_reclaim(sb);
    /* And dead peers' journal areas whose replay claim we could not
     * release: their owner cannot mount past a live replayer. */
    cetrafs_journal_retry_release(sb);

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
            /* Only a NODE can have crashed mid-operation. A row in
             * CETRAFS_NODE_STATE_REPAIR belongs to an offline tool that
             * owns no journal slice; treating it as a dead peer would
             * mean fencing and replaying on behalf of something that
             * was never writing through the journal at all. */
            if (ret || cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED)
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
            if (cetrafs_node_fence_peer(sb, n, "a stale node's dirty journal"))
                continue; /* not revoked: replaying now is the hazard above; next tick tries again */

            ret = cetrafs_journal_replay_node(sb, n, /*wait_for_claim=*/false);
            if (ret && ret != -EEXIST) /* -EEXIST: another replay is at it; next tick */
                pr_warn("heartbeat: replay of stale node %u's journal failed: %d\n", n, ret);
        }
    }
    atomic64_inc(&cetrafs_hb_sweeps);
}

u64 cetrafs_hb_sweep_count(void)
{
    return (u64) atomic64_read(&cetrafs_hb_sweeps);
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
    INIT_DELAYED_WORK(&hb->maint, cetrafs_heartbeat_maint);
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

    /* The renewal first: it is the one that queues the other, so
     * cancelling it first means the maintenance cancel below cannot be
     * raced by a fresh queue_delayed_work() from a tick still running. */
    cancel_delayed_work_sync(&hb->work);
    cancel_delayed_work_sync(&hb->maint);
    kfree(hb);
}
