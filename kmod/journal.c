// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * journal.c -- the per-node redo journal: write path and replay.
 *
 * Physical/redo logging of BG-data-region metadata: dirent blocks
 * (dir.c), xattr blocks (xattr.c), external extent-leaf blocks
 * (file.c). The global tables are out of scope; cetrafs.h reserves a
 * separate, still-unused global journal for those.
 *
 * PER-NODE, not per-ZG. Each Node Registry row owns a private slice
 * (sb.node_journal_start + node_id * node_journal_blocks: one
 * cetrafs_node_journal_hdr_t flag block, then slots of
 * CETRAFS_JOURNAL_SLOT_BLOCKS each), which makes the area
 * single-writer by construction. A per-ZG journal is written by
 * whichever nodes touch metadata in that ZG -- and the namespace is
 * shared, so every node creating a file in root journaled into one
 * area with its own private slot and txn counters: entries overwrote
 * each other, txn_ids interleaved meaninglessly, and replay's sort
 * could apply an older image over a newer one.
 *
 * Entries are CONSUMED (header zeroed + synced) by their own writer as
 * soon as the target write is synced; cetrafs_journal_write_block()
 * bundles log -> dirty -> sync -> consume so no call site can reorder
 * it. A surviving entry therefore means its writer crashed
 * mid-operation. Without immediate consume, an entry whose target
 * landed long ago gets re-applied at reclaim and rolls back everything
 * peers did to that block since.
 *
 * Consume does NOT by itself make redo safe. The old argument was that
 * the writer crashed holding that operation's lock, so nobody else
 * could have touched the target -- false under `nofilelock`, where
 * extent leaves have no cross-node lock at all. A dead node's entry
 * replayed over a peer's newer leaf leaves a valid, CRC-correct, wrong
 * extent map that fsck cannot see.
 *
 * So the apply loop VERIFIES: see the prev_checksum/F_FRESH handling in
 * cetrafs_journal_replay_node(). That check must separate "a peer
 * rewrote this" from "this was caught mid-write", since neither matches
 * the entry's images. Conflating them refuses to repair a torn target
 * -- the one case the journal exists for -- and the block stays
 * unreadable forever. A torn block fails its own tail checksum; a
 * peer's newer write does not. cetrafs_journal_target_intact() is that
 * test; journal_ignore_torn is its negative control.
 *
 * Replay runs for exactly one node's area, at three moments: this
 * node's own at mount (fs.c, after registration, before anything can
 * write); a stale node's at reclaim (zonegroup.c before stealing a ZG,
 * lock.c/dir.c before taking its file lock); and a stale node's from
 * heartbeat.c's sweep, which catches a crashed node holding neither.
 * All go through cetrafs_journal_replay_node(): across nodes the replay
 * claim (a CAS on the area's header) serialises them, and on one node a
 * per-area mutex does, because the claim accepts its own owner
 * re-entering. A replayer that waited checks the node has not come back
 * since its fence. Replaying a CLEAN area twice is a no-op; replaying a
 * live node's area is not, which is what those two guard.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/crc32c.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/minmax.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/sort.h>
#include <linux/stddef.h>
#include <linux/string.h>

#include "kmod.h"

/* One journal "slot" is this header block immediately followed by one
 * full payload block. */

struct cetrafs_journal {
    struct mutex lock; /* serializes this node's own log/consume/flag state */
    u64 area_start;    /* this node's own slice's flag-block LBA; 0 = not attached / journaling off */
    u64 slots;
    u64 next_txn_id;
    /*
     * Our on-disk flag's state as we last wrote it. NOT because we are
     * its only writer: a peer replaying our area releases it CLEAN
     * (cetrafs_journal_claim_mutate()). It stays truthful because a peer
     * replays only after judging us stale, which takes at least four of
     * our advertised heartbeat intervals without progress
     * (cetrafs_sb_peer_progress_stale()), while our lease stops this
     * mount after three (cetrafs_sb_lease_renewed()) -- so no entry of
     * ours can be committed under a flag a peer has parked CLEAN. On a
     * mount without CAW there is no peer. Re-derived at every attach,
     * which replays our own area first.
     */
    bool flag_dirty;
    /*
     * Dead peers' areas whose replay-claim release did not land, by node
     * id, and whether that release was to park the flag CLEAN. Retried
     * every heartbeat (cetrafs_journal_retry_release()). Not left to the
     * dead-peer sweep: it re-enters only while that node is STALE, and a
     * node that came back meanwhile finds our claim live, waits it out,
     * fails its mount -- and, beating again, is never swept.
     */
    DECLARE_BITMAP(rel_pending, 64);
    DECLARE_BITMAP(rel_clean, 64);
    /* Replays of each node's area running on this node now. A retry must
     * not release a claim one of them re-entered (owner == me) and is
     * still applying under. rel_mutex orders the two: the retry holds it
     * across its check and release, a replay takes it only to count
     * itself in. */
    struct mutex rel_mutex;
    atomic_t replaying[64];
    /* One replay of each node's area at a time on this node. The claim
     * accepts its owner re-entering (replay_owner == me), so two local
     * contexts -- an open's lock reclaim and the heartbeat sweep, say --
     * could both replay one dead node's area: the first parks it CLEAN
     * and releases, the node remounts and logs again, and the second is
     * still applying entries by slot (audit R14). */
    struct mutex replay_mutex[64];
    unsigned long *busy; /* logged-but-not-yet-consumed slots (in-flight operations) */
    /*
     * Slots held past their operation: a target write that failed keeps
     * its entry live for replay (stuck_lba[slot] = its target, so the
     * next write of that block takes the slot over), and the test knobs
     * that retain entries on purpose. 'held' counts both; when every slot
     * is held, a writer fails instead of waiting for one to come free.
     */
    u64 *stuck_lba;
    u64 held;
    wait_queue_head_t slot_wq; /* a slot was given back */
};

/* Resolve node #node_id's journal slice. *out_start = 0 means journaling
 * is disabled volume-wide (mkfs -J 0). */
static int cetrafs_journal_node_area(struct super_block *sb, u32 node_id, u64 *out_start, u64 *out_slots)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 start;
    u32 per_node;

    if (!raw_sb)
        return -EINVAL;
    if (node_id >= le32_to_cpu(raw_sb->node_table_count))
        return -EINVAL;

    start = le64_to_cpu(raw_sb->node_journal_start);
    per_node = le32_to_cpu(raw_sb->node_journal_blocks);

    if (!start || per_node < 1 + CETRAFS_JOURNAL_SLOT_BLOCKS) {
        *out_start = 0;
        *out_slots = 0;
        return 0;
    }
    if (per_node > CETRAFS_JOURNAL_MAX_BLOCKS)
        return -EINVAL; /* refused at mount too; the per-slot arrays are sized from it */

    *out_start = start + (u64) node_id * per_node;
    *out_slots = (per_node - 1) / CETRAFS_JOURNAL_SLOT_BLOCKS;
    return 0;
}

/*
 * CRC32C over a journal header block with header_checksum treated as
 * zero -- works directly over b_data rather than copying a full block
 * onto the stack (a real stack-frame-size problem hit twice before in
 * this codebase; see alloc.c's and zonegroup.c's comments).
 */
static u32 cetrafs_journal_header_crc(const void *raw)
{
    static const u8 zero[4] = {0}; /* header_checksum is u32 */
    size_t off = offsetof(cetrafs_journal_header_t, header_checksum);
    size_t clen = sizeof(((cetrafs_journal_header_t *) 0)->header_checksum);
    u32 crc = ~0U;

    BUILD_BUG_ON(sizeof(zero) != clen);

    crc = crc32c(crc, raw, off);
    crc = crc32c(crc, zero, clen);
    crc = crc32c(crc, (const u8 *) raw + off + clen, sizeof(cetrafs_journal_header_t) - off - clen);
    return ~crc;
}

/* Read a node's flag block (always uncached -- another node may have
 * replayed/cleaned it) and report whether it says DIRTY. */
static int cetrafs_journal_read_flag(struct super_block *sb, u64 area_start, bool *out_dirty)
{
    struct buffer_head *bh = cetrafs_bread_uncached_retry(sb, area_start);
    const cetrafs_node_journal_hdr_t *hdr;

    if (!bh)
        return -EIO;

    hdr = (const cetrafs_node_journal_hdr_t *) bh->b_data;
    /* A fresh zero-filled block (magic 0) reads as CLEAN -- correct for
     * a fresh mkfs, and safe afterward because the write path durably
     * flips this to DIRTY before committing its first entry. */
    *out_dirty = (cetrafs_le32(hdr->magic) == CETRAFS_NODE_JOURNAL_MAGIC &&
                  cetrafs_le32(hdr->state) == CETRAFS_NODE_JOURNAL_DIRTY);
    brelse(bh);
    return 0;
}

static int cetrafs_journal_write_flag(struct super_block *sb, u64 area_start, bool dirty)
{
    struct buffer_head *bh = cetrafs_getblk_overwrite(sb, area_start);
    cetrafs_node_journal_hdr_t *hdr;
    int ret;

    if (!bh)
        return -EIO;

    memset(bh->b_data, 0, CETRAFS_BLOCK_SIZE);
    hdr = (cetrafs_node_journal_hdr_t *) bh->b_data;
    hdr->magic = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_MAGIC);
    hdr->state = cetrafs_cpu_to_le32(dirty ? CETRAFS_NODE_JOURNAL_DIRTY : CETRAFS_NODE_JOURNAL_CLEAN);
    hdr->replay_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE); /* 0 is a real node id -- be explicit */
    cetrafs_bh_end_update(bh);
    /* The flag is the whole point of this block: committing entries
     * while the on-disk state still reads CLEAN means the next replay
     * of this area skips them, so a failed write here must reach the
     * caller. Both callers already check -- it was this function that
     * reported success unconditionally. */
    ret = cetrafs_sync_buffer(sb, bh);
    if (ret)
        pr_err("journal: could not write the %s flag at %llu (%d)\n", dirty ? "DIRTY" : "CLEAN",
               (unsigned long long) area_start, ret);
    brelse(bh);
    return ret;
}

/* --- replay claim (replaces the cluster mutex) -------
 *
 * One compare-and-swap on the area's own flag block decides who replays
 * it. See cetrafs_node_journal_hdr_t.replay_owner for why exclusion is
 * needed at all (it is not the concurrent applies -- it is the race
 * between one replayer finishing and releasing the area for reuse and
 * another still writing a stale payload into it).
 */
struct cetrafs_journal_claim_ctx {
    u32 my_node_id;
    bool release;   /* release: hand the claim back */
    bool set_clean; /* release: also park the flag at CLEAN */
    bool steal;     /* claim: allowed to displace steal_from */
    u32 steal_from;
    bool displaced; /* claim, out: the swap took it FROM steal_from */
    bool give_back; /* hand a claim we just took back to steal_from */
};

static int cetrafs_journal_claim_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_journal_claim_ctx *ctx = priv;
    cetrafs_node_journal_hdr_t *hdr = image;

    (void) len;

    if (cetrafs_le32(hdr->magic) != CETRAFS_NODE_JOURNAL_MAGIC)
        return -EEXIST; /* never written, or not ours to touch */

    if (ctx->give_back) {
        if (cetrafs_le32(hdr->replay_owner) != ctx->my_node_id)
            return 1; /* moved on since: nothing of ours to undo */
        hdr->replay_owner = cetrafs_cpu_to_le32(ctx->steal_from);
        return 0;
    }

    if (ctx->release) {
        if (cetrafs_le32(hdr->replay_owner) != ctx->my_node_id)
            return 1; /* not ours any more -- nothing to hand back */
        hdr->replay_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
        hdr->replay_claimed = 0;
        if (ctx->set_clean)
            hdr->state = CETRAFS_NODE_JOURNAL_CLEAN;
        return 0;
    }

    if (cetrafs_le32(hdr->state) != CETRAFS_NODE_JOURNAL_DIRTY)
        return -EEXIST; /* someone replayed it out from under us */

    if (cetrafs_le32(hdr->replay_owner) != CETRAFS_NODE_ID_NONE && cetrafs_le32(hdr->replay_owner) != ctx->my_node_id &&
        !(ctx->steal && cetrafs_le32(hdr->replay_owner) == ctx->steal_from))
        return -EEXIST; /* a live replayer owns it */

    /* Per attempt: the image that lands is the last one mutated. */
    ctx->displaced = ctx->steal && cetrafs_le32(hdr->replay_owner) == ctx->steal_from;
    hdr->replay_owner = cetrafs_cpu_to_le32(ctx->my_node_id);
    hdr->replay_claimed = cetrafs_cpu_to_le64((u64) ktime_get_real_seconds());
    return 0;
}

/*
 * Replay-claim outcomes, counted for the same reason cas_miscompares is:
 * the losing side of this race returns success and does nothing, so
 * without a counter a run in which two nodes never actually met is
 * indistinguishable from one in which the loser correctly walked away.
 * A contention test that cannot tell those apart is asserting nothing.
 */
/* Journal ENTRIES committed. Each costs three device cache flushes and
 * two synchronous writes, so this is the number that says whether a
 * write path is paying for the journal per block. */
static atomic64_t cetrafs_journal_writes = ATOMIC64_INIT(0);

u64 cetrafs_journal_write_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_writes);
}

static atomic64_t cetrafs_journal_replays = ATOMIC64_INIT(0);
static atomic64_t cetrafs_journal_replay_declines = ATOMIC64_INIT(0);
/* Entries replay REFUSED to apply because the target no longer held the
 * image the entry was written against -- i.e. somebody else has written
 * the block since. Every one of these is a cross-node corruption that
 * did not happen; a nonzero value is worth alerting on. */
static atomic64_t cetrafs_journal_replay_refused = ATOMIC64_INIT(0);
/* Entries skipped as already-applied or as F_FRESH: routine, not a fault. */
static atomic64_t cetrafs_journal_replay_skipped = ATOMIC64_INIT(0);
/* Entries replay actually APPLIED (a genuine redo of a write that never
 * reached the device). */
static atomic64_t cetrafs_journal_replay_applied = ATOMIC64_INIT(0);

u64 cetrafs_journal_replay_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_replays);
}

u64 cetrafs_journal_replay_decline_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_replay_declines);
}

u64 cetrafs_journal_replay_refused_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_replay_refused);
}

u64 cetrafs_journal_replay_skipped_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_replay_skipped);
}

u64 cetrafs_journal_replay_applied_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_replay_applied);
}

/* TEST ONLY: treat a foreign replay claim as held by a LIVE node. A
 * genuinely live peer mid-replaying an area cannot be fabricated on the
 * single-node loop harness (a poked registry row never heartbeats, and the
 * no-CAW mount gate fences it before the attach even runs), so this forces
 * the "owner is alive -- leave it" verdict to prove the attach-time wait
 * actually waits. Off in production. */
static bool cetrafs_force_live_replay_claim;
cetrafs_test_param(force_live_replay_claim, cetrafs_force_live_replay_claim, bool, 0644);
MODULE_PARM_DESC(force_live_replay_claim, "TEST ONLY: a foreign journal replay claim always reads as live");

/* TEST ONLY: skip cetrafs_journal_sweep_own_claims() (the control of
 * tests/kernel/replay_claim_reattach.sh). */
static bool cetrafs_journal_sweep_skip;
cetrafs_test_param(journal_sweep_skip, cetrafs_journal_sweep_skip, bool, 0644);
MODULE_PARM_DESC(journal_sweep_skip, "TEST ONLY: leave the replay claims a previous incarnation held");

/* 0 = claimed, -EEXIST = someone else is handling it (or nothing to do). */
static int cetrafs_journal_claim_replay(struct super_block *sb, u64 area_start, u32 my_node_id)
{
    struct cetrafs_journal_claim_ctx ctx = {.my_node_id = my_node_id};
    struct buffer_head *bh;
    const cetrafs_node_journal_hdr_t *hdr;
    u32 owner;
    int ret;

    bh = cetrafs_bread_uncached_retry(sb, area_start);
    if (!bh)
        return -EIO;
    hdr = (const cetrafs_node_journal_hdr_t *) bh->b_data;
    owner = cetrafs_le32(hdr->replay_owner);
    brelse(bh);

    if (owner != CETRAFS_NODE_ID_NONE && owner != my_node_id) {
        bool stale = false;

        if (cetrafs_force_live_replay_claim) /* test knob, see its MODULE_PARM_DESC */
            return -EEXIST;
        if (cetrafs_node_is_stale(sb, owner, &stale) || !stale)
            return -EEXIST; /* live replayer, or we cannot tell: leave it */
        pr_warn("journal: taking over replay of area %llu from stale node %u\n", (unsigned long long) area_start,
                owner);
        {
            int fret = cetrafs_node_fence_peer(sb, owner, "a journal replay claim");

            if (fret)
                return fret;
        }
        ctx.steal = true;
        ctx.steal_from = owner;
        cetrafs_node_test_stall_before_swap();
    }

    ret = cetrafs_cas_record(sb, area_start, cetrafs_journal_claim_mutate, &ctx);
    /*
     * Was the replayer we displaced still the incarnation the fence
     * revoked? The swap compares its row NUMBER only, and a replayer that
     * re-attached and took this claim again wrote the very bytes it
     * compares -- two replayers of one area, which is what the claim
     * exists to prevent. Give it back and leave the area to it, as for
     * any live replayer; a give-back that does not land leaves two, so
     * the mount stops. Only a displacement is undone: a claim the
     * re-attach's sweep had already handed back was free to take
     * (lock.c's cetrafs_lock_undo_steal() has the full account).
     */
    if (ret == 0 && ctx.displaced && cetrafs_node_reattached_since_fence(sb, owner)) {
        struct cetrafs_journal_claim_ctx g = {.my_node_id = my_node_id, .give_back = true, .steal_from = owner};
        int gret = cetrafs_cas_record_nointr(sb, area_start, cetrafs_journal_claim_mutate, &g);

        if (gret < 0)
            cetrafs_sb_fatal(sb, "journal: area %llu: node %u came back while its replay claim was being taken, "
                             "and the claim could not be given back (%d)",
                             (unsigned long long) area_start, owner, gret);
        else
            pr_warn("journal: area %llu: node %u came back while its replay claim was being taken -- gave it back\n",
                    (unsigned long long) area_start, owner);
        return -EEXIST;
    }
    return ret;
}

/* TEST ONLY: fail the next replay-claim release, as a CAS the device
 * refused would (tests/kernel/journal_release_retry.sh). */
static bool cetrafs_journal_release_fail_once;
cetrafs_test_param(journal_release_fail_once, cetrafs_journal_release_fail_once, bool, 0644);
MODULE_PARM_DESC(journal_release_fail_once, "TEST ONLY: fail the next journal replay-claim release with -EIO");

static void cetrafs_journal_release_replay(struct super_block *sb, u32 node_id, u64 area_start, u32 my_node_id,
                                           bool set_clean)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);
    struct cetrafs_journal_claim_ctx ctx = {.my_node_id = my_node_id, .release = true, .set_clean = set_clean};
    int ret;

    if (READ_ONCE(cetrafs_journal_release_fail_once) && xchg(&cetrafs_journal_release_fail_once, false))
        ret = -EIO;
    else
        ret = cetrafs_cas_record(sb, area_start, cetrafs_journal_claim_mutate, &ctx);

    if (ret < 0) {
        pr_err("journal: failed to release the replay claim on area %llu (node %u): %d -- queued for the "
               "heartbeat\n",
               (unsigned long long) area_start, node_id, ret);
        if (j && node_id < 64) {
            if (set_clean)
                set_bit(node_id, j->rel_clean);
            else
                clear_bit(node_id, j->rel_clean);
            set_bit(node_id, j->rel_pending);
        }
    } else if (j && node_id < 64) {
        clear_bit(node_id, j->rel_pending);
    }
}

/* Replay claims on peers' areas this node still holds for a retry. */
bool cetrafs_journal_release_pending(struct super_block *sb)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);

    return j && !bitmap_empty(j->rel_pending, 64);
}

/* The heartbeat's half of cetrafs_journal_release_replay(). The release
 * mutator hands back only a claim that is still ours, so a retry after
 * someone else took the area over is a no-op. */
void cetrafs_journal_retry_release(struct super_block *sb)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);
    u64 area_start, slots;
    u32 my_node_id;
    unsigned int n;

    if (!j || bitmap_empty(j->rel_pending, 64) || cetrafs_sb_get_node_id(sb, &my_node_id))
        return;
    mutex_lock(&j->rel_mutex);
    for_each_set_bit(n, j->rel_pending, 64) {
        if (atomic_read(&j->replaying[n]))
            continue; /* that replay releases for itself */
        if (cetrafs_journal_node_area(sb, n, &area_start, &slots) || !area_start) {
            clear_bit(n, j->rel_pending);
            continue;
        }
        cetrafs_journal_release_replay(sb, n, area_start, my_node_id, test_bit(n, j->rel_clean));
    }
    mutex_unlock(&j->rel_mutex);
}

int cetrafs_journal_init(struct super_block *sb, struct cetrafs_journal **out_j)
{
    struct cetrafs_journal *j = kzalloc(sizeof(*j), GFP_KERNEL);
    unsigned int i;

    if (!j)
        return -ENOMEM;

    mutex_init(&j->lock);
    mutex_init(&j->rel_mutex);
    for (i = 0; i < ARRAY_SIZE(j->replay_mutex); i++)
        mutex_init(&j->replay_mutex[i]);
    init_waitqueue_head(&j->slot_wq);
    /* area_start/slots stay 0 until cetrafs_journal_attach_node() --
     * fill_super() calls cetrafs_journal_init() before node registration
     * has produced a node id, and until attached every log call is a
     * silent no-op (nothing can write that early anyway). */
    *out_j = j;
    return 0;
}

void cetrafs_journal_free(struct cetrafs_journal *j)
{
    if (!j)
        return;
    kvfree(j->busy);
    kvfree(j->stuck_lba);
    kfree(j);
}

/*
 * Hand back every replay claim our previous incarnation left on the
 * device (audit R19). A node that crashed mid-replay and re-attached
 * holds no claim in memory -- it has not replayed anything yet -- but
 * the area still names its row, and a row that beats again reads as a
 * LIVE replayer: the area's owner then waited 3*stale+30 s on a claim
 * nobody would ever release, and its mount failed -EBUSY. Called at an
 * unclean re-attach, before this mount replays anything, so every claim
 * naming us is a dead incarnation's. The area stays DIRTY: the replay
 * it protected may be half done, and whoever claims it next redoes it.
 */
int cetrafs_journal_sweep_own_claims(struct super_block *sb, u32 my_node_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct cetrafs_journal_claim_ctx ctx = {.my_node_id = my_node_id, .release = true};
    u32 n, count;

    if (!raw_sb)
        return -EINVAL;
    count = le32_to_cpu(raw_sb->node_table_count);
    for (n = 0; n < count; n++) {
        u64 area_start, slots;
        struct buffer_head *bh;
        u32 owner;
        bool magic;
        int ret;

        if (cetrafs_journal_node_area(sb, n, &area_start, &slots) || !area_start)
            continue;
        bh = cetrafs_bread_uncached_retry(sb, area_start);
        if (!bh)
            return -EIO;
        magic = cetrafs_le32(((const cetrafs_node_journal_hdr_t *) bh->b_data)->magic) == CETRAFS_NODE_JOURNAL_MAGIC;
        owner = cetrafs_le32(((const cetrafs_node_journal_hdr_t *) bh->b_data)->replay_owner);
        brelse(bh);
        if (!magic || owner != my_node_id || cetrafs_journal_sweep_skip)
            continue;
        ret = cetrafs_cas_record(sb, area_start, cetrafs_journal_claim_mutate, &ctx);
        if (ret < 0)
            return ret;
        if (ret == 0)
            pr_info("journal: handed back the replay claim on node %u's area our previous incarnation held\n", n);
        cond_resched();
    }
    return 0;
}

/*
 * Bind this mount's journal to its freshly-registered node id and replay
 * our own previous session's crash leftovers, if any. Called from
 * fill_super() immediately after cetrafs_node_register() succeeds --
 * before ZG claiming, before anything can possibly write. A failed own-
 * replay fails the mount: writing on top of unrecovered state is exactly
 * what the journal exists to prevent.
 */
/* TEST ONLY: mounts made while set use at most this many of their area's
 * slots, so a suite can fill them; and a journaled write pauses between
 * its entry and its target write, holding its slot. */
static unsigned int cetrafs_journal_slots_max;
cetrafs_test_param(journal_slots_max, cetrafs_journal_slots_max, uint, 0644);
MODULE_PARM_DESC(journal_slots_max, "TEST ONLY: cap the journal slots a mount made while set uses");
static unsigned int cetrafs_journal_target_stall_ms;
cetrafs_test_param(journal_target_stall_ms, cetrafs_journal_target_stall_ms, uint, 0644);
MODULE_PARM_DESC(journal_target_stall_ms, "TEST ONLY: pause a journaled write between its entry and its target write");

static int cetrafs_journal_zero_header(struct super_block *sb, u64 header_lba);

/* TEST ONLY: attach leaves leftover entries in place, as it did before
 * cetrafs_journal_retire_leftovers() (tests/kernel/journal_attach_retires.sh). */
static bool cetrafs_journal_keep_leftovers;
cetrafs_test_param(journal_keep_leftovers, cetrafs_journal_keep_leftovers, bool, 0644);
MODULE_PARM_DESC(journal_keep_leftovers, "TEST ONLY: attach keeps entries found under a clean flag");

/*
 * Retire every live entry in our own area, whatever its flag says. Run at
 * attach, after the replay the flag asked for (or none, if CLEAN).
 *
 * A clean flag says nothing about the slots. A node wedged by a storage
 * outage can have an entry write queued past its fence; a peer judges it
 * stale, replays, parks the area CLEAN -- and then the entry lands.
 * Attach and replay skip the slot scan on a CLEAN area, so it waits there:
 * the node remounts, journals something (DIRTY), crashes, and the next
 * replay finds the old entry, whose guard still matches because its
 * target write was refused -- a dirent for an operation that returned
 * -EIO comes back (audit 2026-11-06 M10). Nothing this mount writes can
 * be in a slot yet, so every live header here is such a leftover.
 *
 * Reads every header fresh; writes only the live ones, so a cleanly
 * parked area costs reads alone.
 */
static int cetrafs_journal_retire_leftovers(struct super_block *sb, u64 area_start, u64 slots)
{
    u64 s, n = 0;

    for (s = 0; s < slots; s++) {
        u64 header_lba = area_start + 1 + s * CETRAFS_JOURNAL_SLOT_BLOCKS;
        struct buffer_head *hbh = cetrafs_bread_uncached_retry(sb, header_lba);
        bool live;
        int ret;

        if (!hbh)
            return -EIO;
        live = cetrafs_le32(((const cetrafs_journal_header_t *) hbh->b_data)->magic) == CETRAFS_JOURNAL_MAGIC;
        brelse(hbh);
        if (!live)
            continue;
        ret = cetrafs_journal_zero_header(sb, header_lba);
        if (ret)
            return ret;
        n++;
        if ((s & 255) == 255)
            cond_resched();
    }
    if (n)
        pr_warn("journal: retired %llu entr%s left in this node's area under a clean flag\n",
                (unsigned long long) n, n == 1 ? "y" : "ies");
    return 0;
}

int cetrafs_journal_attach_node(struct super_block *sb, u32 node_id)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);
    int ret;

    if (!j)
        return -EINVAL;

    ret = cetrafs_journal_node_area(sb, node_id, &j->area_start, &j->slots);
    if (ret)
        return ret;
    if (!j->area_start)
        return 0; /* journaling disabled volume-wide (mkfs -J 0) */
    if (cetrafs_journal_slots_max && j->slots > cetrafs_journal_slots_max)
        j->slots = cetrafs_journal_slots_max; /* test-only: this mount writes fewer; replay still reads them all */

    j->busy = kvcalloc(BITS_TO_LONGS(j->slots), sizeof(unsigned long), GFP_KERNEL);
    j->stuck_lba = kvcalloc(j->slots, sizeof(*j->stuck_lba), GFP_KERNEL);
    if (!j->busy || !j->stuck_lba) {
        kvfree(j->busy);
        kvfree(j->stuck_lba);
        j->busy = NULL;
        j->stuck_lba = NULL;
        j->area_start = 0;
        j->slots = 0;
        return -ENOMEM;
    }

    ret = cetrafs_journal_replay_node(sb, node_id, /*wait_for_claim=*/true);
    if (ret)
        return ret;
    {
        u64 area, all;

        /* Every slot the area has, not this mount's journal_slots_max. */
        ret = cetrafs_journal_node_area(sb, node_id, &area, &all);
        if (!ret && !cetrafs_journal_keep_leftovers)
            ret = cetrafs_journal_retire_leftovers(sb, area, all);
        if (ret)
            return ret;
    }

    j->flag_dirty = false; /* replay always ends with the flag clean */
    j->next_txn_id = 0;
    return 0;
}

/*
 * Log 'bh' (its current b_data, exactly one block) as the new post-image
 * of its own block, then mark it dirty, sync it, and consume the journal
 * entry -- the full write-ahead sequence as one call, so no call site
 * can reorder it. On a volume with journaling disabled this degrades to
 * plain mark_buffer_dirty() + sync_dirty_buffer().
 *
 * CONTRACT: 'bh' arrives LOCKED (the caller holds it via
 * cetrafs_bh_begin_update()) and NOT yet dirty, and this function owns
 * ending that update on every path.
 *
 * Both halves are load-bearing, and the previous contract -- "the caller
 * must not have marked the buffer dirty yet" -- was violated by all
 * eleven call sites, every one of which called cetrafs_bh_end_update()
 * (which marks it dirty) immediately before. That defeats write-ahead
 * logging: a dirty buffer can be flushed by ordinary background
 * writeback at any moment, so the target block could reach the device
 * before the journal entry committed. A crash tearing that early flush
 * leaves a half-written dirent block with no entry to repair it from --
 * precisely what the journal exists to prevent.
 *
 * Holding the buffer LOCK instead closes it completely: writeback takes
 * that lock to flush, so while this function holds it the target
 * physically cannot reach the device, and the entry is guaranteed
 * durable first. It also keeps forced-fresh readers out for the same
 * window, which marking it dirty up front would not (see ioutil.c's
 * comment on why that earlier approach was wrong in the other
 * direction).
 */
/* Test-only: leave the entry LIVE instead of consuming it, simulating a
 * crash in the window between the target write landing and the consume.
 * Reaching that window by racing a real crash takes many attempts; the
 * hazard it exposes (a peer replaying the entry after someone else has
 * rewritten the target) is the real code path either way. */
static bool cetrafs_journal_skip_consume;
cetrafs_test_param(journal_skip_consume, cetrafs_journal_skip_consume, bool, 0644);
MODULE_PARM_DESC(journal_skip_consume, "test-only: do not consume journal entries after the target write");

/* Test-only: replay as it behaved BEFORE the prev_checksum guard --
 * apply every valid entry unconditionally. This is the negative control
 * for tests/ctest scenarios that assert the guard works: with it set the
 * assertion must FAIL (the corruption reproduces), which is the only
 * proof the assertion is testing anything. Never set in production. */
/* Test-only: commit the entry but SKIP the in-place target write, leaving
 * the target holding its prior image -- the state a crash between the
 * journal commit and the target write produces. This is the POSITIVE
 * control: replay must APPLY these entries (prev_checksum matches the
 * device), proving the guard still repairs what it is supposed to
 * repair rather than merely refusing everything. */
static bool cetrafs_journal_skip_target_write;
cetrafs_test_param(journal_skip_target_write, cetrafs_journal_skip_target_write, bool, 0644);
MODULE_PARM_DESC(journal_skip_target_write, "test-only: journal the entry but do not write the target in place");

/*
 * Test-only: make the target's synchronous write REPORT FAILURE.
 *
 * Distinct from journal_skip_target_write above, which models a crash:
 * it suppresses the write and deliberately returns SUCCESS, because a
 * crashed writer never returns at all. This one models a device that
 * REFUSES the write: the target keeps its prior image, exactly as it
 * would, and the caller -- still alive -- has to be told.
 *
 * Both halves matter. An injection that let the write land and only
 * reported failure would leave the target NEWER than the entry, and
 * replay's prev_checksum guard would then (rightly) refuse to apply it
 * -- so the suite would watch the entry survive and still conclude
 * nothing about whether it was usable.
 */
static bool cetrafs_journal_fail_target_write;
cetrafs_test_param(journal_fail_target_write, cetrafs_journal_fail_target_write, bool, 0644);
MODULE_PARM_DESC(journal_fail_target_write, "test-only: the target's write fails (the entry must stay live)");

/*
 * Test-only: make writing the journal ENTRY itself (payload + header)
 * report failure. Nothing a test can supply makes that write fail, and
 * the question it reaches is what the caller's modification does when
 * it cannot be protected: it must fail, never go out unjournaled.
 */
static bool cetrafs_journal_fail_entry_write;
cetrafs_test_param(journal_fail_entry_write, cetrafs_journal_fail_entry_write, bool, 0644);
MODULE_PARM_DESC(journal_fail_entry_write, "test-only: the journal entry's own write fails");

/*
 * Test-only: pause replay between its verdict on a target and the redo,
 * logging the pause -- where a live writer's own write of the block can
 * land (tests/kernel/journal_replay_live_writer.sh).
 */
static unsigned int cetrafs_journal_replay_apply_pause_ms;
cetrafs_test_param(journal_replay_apply_pause_ms, cetrafs_journal_replay_apply_pause_ms, uint, 0644);
MODULE_PARM_DESC(journal_replay_apply_pause_ms, "test-only: pause between replay's verdict and its redo");

static bool cetrafs_journal_ignore_guard;
cetrafs_test_param(journal_ignore_guard, cetrafs_journal_ignore_guard, bool, 0644);
MODULE_PARM_DESC(journal_ignore_guard, "test-only: replay without the prev_checksum guard (reproduces the pre-fix bug)");

/* Test-only: treat a TORN target as "changed since" and refuse it -- the
 * behaviour 0.7.3 shipped, where a block caught mid-write was never
 * repaired because it matched neither the entry's before- nor its
 * after-image. This is the negative control for the torn branch: with it
 * set, the crash rig's phase 5 must FAIL. Never set in production. */
static bool cetrafs_journal_ignore_torn;
cetrafs_test_param(journal_ignore_torn, cetrafs_journal_ignore_torn, bool, 0644);
MODULE_PARM_DESC(journal_ignore_torn, "test-only: refuse to redo a torn target (reproduces the 0.7.3 bug)");

static bool cetrafs_journal_ignore_kind;
cetrafs_test_param(journal_ignore_kind, cetrafs_journal_ignore_kind, bool, 0644);
MODULE_PARM_DESC(journal_ignore_kind, "test-only: redo a 'torn' target even when it is no longer a block of the entry's kind");

static u64 cetrafs_journal_header_lba(const struct cetrafs_journal *j, u64 slot)
{
    return j->area_start + 1 + slot * CETRAFS_JOURNAL_SLOT_BLOCKS;
}

/* Overwrite a slot's header with zeroes and wait for it: the entry is
 * spent. Nonzero if that cannot be shown to have reached the device. */
static int cetrafs_journal_zero_header(struct super_block *sb, u64 header_lba)
{
    struct buffer_head *jbh = cetrafs_getblk_overwrite(sb, header_lba);
    int ret;

    if (!jbh)
        return -EIO;
    memset(jbh->b_data, 0, CETRAFS_BLOCK_SIZE);
    cetrafs_bh_end_update(jbh);
    ret = cetrafs_sync_buffer(sb, jbh);
    brelse(jbh);
    return ret;
}

/* Hold 'slot' past its operation. Called with j->lock held. A nonzero
 * 'lba' names the target whose next write takes the slot over.
 *
 * Wakes the slot waiters: their condition is "a slot is free OR every
 * slot is held", and this is the write that can make the second half
 * true. Without the wake, a writer waiting when the last in-flight slot
 * became held slept for ever, uninterruptibly and holding its buffer's
 * update lock, instead of getting the -EIO the condition exists to
 * deliver (audit 2026-11-05, N2; tests/kernel/journal_slot_held_wakes.sh). */
static void cetrafs_journal_hold_slot(struct cetrafs_journal *j, u64 slot, u64 lba)
{
    j->stuck_lba[slot] = lba;
    j->held++;
    wake_up(&j->slot_wq);
}

/*
 * A take that reused a kept entry's slot and then gave up before writing
 * anything: the kept entry is still live on the device -- it is for a
 * target whose write failed, the one entry replay would need -- so its
 * slot is held again. Released instead, the next entry would take the
 * slot and overwrite it (leafdefer review 2026-11-08, item 4). j->lock held.
 */
static void cetrafs_journal_untake_kept(struct cetrafs_journal *j, u64 slot, u64 lba, bool reused)
{
    if (!reused)
        return;
    set_bit(slot, j->busy);
    cetrafs_journal_hold_slot(j, slot, lba);
}

/* Lockless: only a wake-up condition, re-checked under j->lock. */
static bool cetrafs_journal_slot_or_none(struct cetrafs_journal *j)
{
    return find_first_zero_bit(j->busy, j->slots) < j->slots || READ_ONCE(j->held) >= j->slots;
}

u64 cetrafs_journal_held_slots(struct super_block *sb)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);

    return (j && j->area_start) ? READ_ONCE(j->held) : 0;
}

/*
 * Take a free journal slot for an entry about to be written for 'lba'
 * (a slot a failed write of the same block kept is taken over), marking
 * our area DIRTY first if this is the session's first entry. On success
 * the slot is busy and *txn_id is its sequence number.
 *
 * nowait: return -EAGAIN instead of waiting when every slot is in
 * flight -- for a caller that already holds slots, which must not wait
 * for one while holding others (cetrafs_journal_write_deferred()).
 */
/* TEST ONLY: the next slot take finds the mount fenced at its last
 * check, after the slot was chosen (tests/kernel/journal_kept_slot_kept.sh). */
static bool cetrafs_journal_take_fenced_once;
cetrafs_test_param(journal_take_fenced_once, cetrafs_journal_take_fenced_once, bool, 0644);
MODULE_PARM_DESC(journal_take_fenced_once, "TEST ONLY: the next journal slot take fails its fence check");

static int cetrafs_journal_take_slot(struct super_block *sb, struct cetrafs_journal *j, u64 lba, bool nowait,
                                     u64 *out_slot, u64 *txn_id)
{
    bool reused = false;
    u64 slot;

    mutex_lock(&j->lock);

    for (;;) {
        /* An entry a failed write of THIS block kept is superseded by
         * the one about to be written -- built from the block as it
         * was re-read after that failure -- so its slot is ours to
         * reuse. Without this, a full set of kept entries refused the
         * very write that would have retired them. */
        if (j->held) {
            for (slot = 0; slot < j->slots; slot++)
                if (j->stuck_lba[slot] == lba)
                    break;
            if (slot < j->slots) {
                j->stuck_lba[slot] = 0;
                j->held--;
                clear_bit(slot, j->busy); /* re-set below, still under j->lock */
                reused = true;
                break;
            }
        }
        slot = find_first_zero_bit(j->busy, j->slots);
        if (slot < j->slots)
            break;
        if (j->held >= j->slots) {
            /* Nothing in flight will free one: every slot is held
             * by an entry a failed write kept. */
            mutex_unlock(&j->lock);
            pr_err_ratelimited("journal: all %llu slots are held by kept entries -- refusing to write block "
                               "%llu unjournaled\n",
                               (unsigned long long) j->slots, (unsigned long long) lba);
            return -EIO;
        }
        if (nowait) {
            mutex_unlock(&j->lock);
            return -EAGAIN;
        }
        /* Every free slot is in flight: those operations hold no lock
         * we hold and only do their own I/O, so one comes back. */
        mutex_unlock(&j->lock);
        wait_event(j->slot_wq, cetrafs_journal_slot_or_none(j));
        mutex_lock(&j->lock);
    }

    /* First entry of this session: durably flip our flag to DIRTY
     * *before* committing anything, so a crash after the commit is
     * guaranteed to be caught by the next replay of our area. */
    if (!j->flag_dirty) {
        int ret = cetrafs_journal_write_flag(sb, j->area_start, true);

        if (ret) {
            cetrafs_journal_untake_kept(j, slot, lba, reused);
            mutex_unlock(&j->lock);
            pr_err_ratelimited("journal: could not mark our area dirty (%d) -- refusing to write block %llu "
                               "unjournaled\n",
                               ret, (unsigned long long) lba);
            return ret;
        }
        j->flag_dirty = true;
    }

    /* Again here: the slot wait and the flag write above can block
     * for as long as the device does, and a fence landing meanwhile
     * must stop the entry, not let it commit after a peer parked our
     * area (audit 2026-11-06 M10). I/O already queued still lands;
     * the attach-time retire covers what gets past this. */
    if (cetrafs_sb_is_fenced(sb) ||
        (READ_ONCE(cetrafs_journal_take_fenced_once) && xchg(&cetrafs_journal_take_fenced_once, false))) {
        cetrafs_journal_untake_kept(j, slot, lba, reused);
        mutex_unlock(&j->lock);
        return -EIO;
    }
    set_bit(slot, j->busy);
    *txn_id = ++j->next_txn_id;
    mutex_unlock(&j->lock);
    *out_slot = slot;
    return 0;
}

static int cetrafs_journal_write_block_flags(struct super_block *sb, struct buffer_head *bh, u32 flags, u32 prev_crc)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);

    if (cetrafs_sb_is_fenced(sb)) {
        /* Self-fenced: no metadata may be written at all. Abort rather
         * than end the update -- publishing a change this node is no
         * longer entitled to make is the whole thing being prevented. */
        cetrafs_bh_abort_update(bh);
        return -EIO;
    }

    u64 slot, txn_id, header_lba, payload_lba;
    struct buffer_head *pbh, *hbh;
    cetrafs_journal_header_t *hdr;
    bool journaled = false;
    bool entry_refused = false; /* the device refused the entry write itself */
    /* A held-back tree block (leafdefer.c) is written at its boundary,
     * in a batch whose first step makes what it names durable; nothing
     * should journal one here. If something does, its guard is the
     * DEVICE's image, and once written it is held back no longer. */
    bool was_deferred = buffer_cetra_deferred(bh);

    if (WARN_ON_ONCE(was_deferred) && (flags & CETRAFS_JRNL_F_GUARDED))
        prev_crc = cetrafs_deferred_disk_crc(sb, bh, prev_crc);

    /*
     * On a journaling volume, a block the journal cannot protect is NOT
     * written. Every failure below -- no slot, the area flag, the entry
     * itself -- used to fall back to an unjournaled write with a
     * ratelimited warning and report success, so a crash inside that
     * write left a torn dirent/xattr/leaf block with nothing to redo it
     * from. Now the update is aborted (the buffer drops its unpublished
     * image, see cetrafs_bh_abort_update()) and the caller gets the
     * error, the same contract as a failed target write below.
     * mkfs -J 0 is a different thing: no journal at all, by choice.
     */
    if (j && j->area_start) {
        int tret = cetrafs_journal_take_slot(sb, j, bh->b_blocknr, false, &slot, &txn_id);

        if (tret) {
            cetrafs_bh_abort_update(bh);
            return tret;
        }

        header_lba = cetrafs_journal_header_lba(j, slot);
        payload_lba = header_lba + 1;

        /* 1+2. Payload and header, issued TOGETHER and waited for once.
         *
         * These used to be two separate synchronous writes, header last,
         * so that the payload was provably durable before the header
         * claimed it. That ordering is redundant: replay already
         * verifies hdr->payload_checksum and skips an entry whose
         * header committed but whose payload is torn, which is the
         * exact state the ordering existed to prevent. With the
         * checksum doing the proving, the two blocks -- adjacent LBAs,
         * so the block layer will usually merge them -- can go out
         * together, turning two device round trips into one. On the
         * real LUN a synchronous write is ~38 ms, and this happens on
         * every create, mkdir and unlink.
         *
         * Both are claimed without reading: every byte of each is
         * overwritten below. */
        pbh = cetrafs_getblk_overwrite(sb, payload_lba);
        if (!pbh)
            goto journal_failed;
        memcpy(pbh->b_data, bh->b_data, CETRAFS_BLOCK_SIZE);
        cetrafs_bh_end_update(pbh);

        hbh = cetrafs_getblk_overwrite(sb, header_lba);
        if (!hbh) {
            brelse(pbh);
            goto journal_failed;
        }
        memset(hbh->b_data, 0, CETRAFS_BLOCK_SIZE);
        hdr = (cetrafs_journal_header_t *) hbh->b_data;
        hdr->magic = cetrafs_cpu_to_le32(CETRAFS_JOURNAL_MAGIC);
        hdr->flags = cetrafs_cpu_to_le32(flags);
        hdr->txn_id = cetrafs_cpu_to_le64(txn_id);
        hdr->target_lba = cetrafs_cpu_to_le64(bh->b_blocknr);
        /* What the target held BEFORE this modification. Replay compares
         * it against the device to prove nobody else has written the
         * block since -- without it, redo silently reverts a peer's
         * newer write (see cetrafs_journal_header_t). */
        hdr->prev_checksum = cetrafs_cpu_to_le32(prev_crc);
        /* Over the caller's buffer, which is the image just copied into
         * the payload block and cannot change meanwhile: it is locked. */
        hdr->payload_checksum = cetrafs_cpu_to_le32(~crc32c(~0U, bh->b_data, CETRAFS_BLOCK_SIZE));
        hdr->header_checksum = cetrafs_cpu_to_le32(cetrafs_journal_header_crc(hbh->b_data));
        cetrafs_bh_end_update(hbh);

        {
            struct blk_plug plug;
            bool ok;

            /* PERF(9): both out together, one wait -- docs/PERFORMANCE.md */
            blk_start_plug(&plug);
            write_dirty_buffer(pbh, REQ_SYNC);
            write_dirty_buffer(hbh, REQ_SYNC);
            blk_finish_plug(&plug);

            wait_on_buffer(pbh);
            wait_on_buffer(hbh);
            ok = buffer_uptodate(pbh) && buffer_uptodate(hbh) && !cetrafs_journal_fail_entry_write;
            brelse(pbh);
            brelse(hbh);
            if (!ok) {
                entry_refused = true;
                goto journal_failed;
            }
        }

        journaled = true;
        atomic64_inc(&cetrafs_journal_writes);
        fs_debug(info, "journal: txn %llu slot %llu target_lba=%llu", (unsigned long long) txn_id,
                 (unsigned long long) slot, (unsigned long long) bh->b_blocknr);
    }

    /* 3. The real in-place write. The journal entry (if any) must be
     * durable before this may legally reach the device -- which is why the
     * buffer was held locked until here. But the wait_on_buffer() above
     * only means the journal WRITE completed, and on a volatile write
     * cache (the deployment LUN reports write-back) completed is not
     * durable: a reordering cache could land this in-place write and lose
     * the journal entry across a crash, leaving a torn target with nothing
     * to redo it. Flush the cache so the entry is genuinely on the platter
     * first. Free on a write-through / NV-cache device.
     *
     * A volume with journaling off (mkfs -J 0) has no entries to order
     * against and skips it; on a journaling volume nothing reaches here
     * unjournaled any more. */
    if (journaled && cetrafs_journal_skip_target_write) {
        blkdev_issue_flush(sb->s_bdev);
        /* Abort rather than end the update: the modification is dropped
         * and the buffer unlocked without being dirtied, so the target
         * keeps its prior image exactly as a crash here would leave it.
         * The slot is deliberately retained (see skip_consume). */
        cetrafs_bh_abort_update(bh);
        mutex_lock(&j->lock);
        cetrafs_journal_hold_slot(j, slot, 0); /* kept on purpose: never superseded */
        mutex_unlock(&j->lock);
        pr_warn_ratelimited("journal: journal_skip_target_write set -- txn %llu committed, target %llu NOT written\n",
                            (unsigned long long) txn_id, (unsigned long long) bh->b_blocknr);
        return 0;
    }

    if (journaled) {
        int ferr = blkdev_issue_flush(sb->s_bdev);

        if (ferr) {
            /* The entry may still be in a volatile cache: writing the
             * target now is the torn-target-with-no-redo the flush
             * exists to prevent. Stop instead; the entry stays live. */
            cetrafs_sb_fatal(sb, "journal: cache flush before the write of block %llu failed (%d)",
                             (unsigned long long) bh->b_blocknr, ferr);
            cetrafs_bh_abort_update(bh);
            mutex_lock(&j->lock);
            cetrafs_journal_hold_slot(j, slot, bh->b_blocknr);
            mutex_unlock(&j->lock);
            return ferr;
        }
    }
    if (journaled && cetrafs_journal_target_stall_ms)
        msleep(cetrafs_journal_target_stall_ms); /* test-only; see the parameter */
    /* end_update marks it dirty and releases it; the sync must follow,
     * never precede, because sync_dirty_buffer() takes the buffer lock. */
    if (cetrafs_journal_fail_target_write) {
        /* Test-only: the device refuses it. Abort rather than end the
         * update, so the target keeps the image a refused write would
         * have left, then fail exactly as a real error does below. */
        cetrafs_bh_abort_update(bh);
        if (journaled) {
            mutex_lock(&j->lock);
            cetrafs_journal_hold_slot(j, slot, bh->b_blocknr);
            mutex_unlock(&j->lock);
        }
        pr_err("journal: journal_fail_target_write set -- target %llu refused, txn %llu stays LIVE for replay\n",
               (unsigned long long) bh->b_blocknr, (unsigned long long) txn_id);
        return -EIO;
    }

    cetrafs_bh_end_update(bh);
    {
        /*
         * CHECK it. "The target is durable" below was asserted, never
         * tested: on a failed write the entry was consumed anyway,
         * destroying the only copy that could have redone it. Keeping
         * the entry live is the whole reason the journal exists, and
         * the operation must fail rather than report a write that did
         * not land.
         *
         * Keeping the slot busy is deliberate and matches the
         * skip_consume path: a released slot is reused immediately, and
         * the next entry would overwrite this header. It is held only
         * until the next write of the same block, which takes the slot
         * over (see the slot search above).
         */
        int werr = cetrafs_sync_buffer(sb, bh);

        if (!werr && was_deferred)
            cetrafs_bh_deferred_unlist(sb, bh, false);
        if (werr) {
            if (journaled) {
                mutex_lock(&j->lock);
                cetrafs_journal_hold_slot(j, slot, bh->b_blocknr);
                mutex_unlock(&j->lock);
            }
            pr_err("journal: target %llu failed to write (%d) -- txn %llu stays LIVE for replay\n",
                   (unsigned long long) bh->b_blocknr, werr, (unsigned long long) txn_id);
            return werr;
        }
    }

    /* 4. Consume: the target is durable, so the entry is spent. Leaving
     * it live would let a later replay of our area (after our crash in
     * some UNRELATED, much later operation) re-apply this stale image
     * over whatever newer content this block holds by then. */
    if (journaled && cetrafs_journal_skip_consume) {
        /* Deliberately do NOT release the slot: a released slot is
         * immediately reused, and the next entry would overwrite this
         * header -- leaving only ONE live entry at crash time, which is
         * not the state a real crash produces. Entries accumulate until
         * the area fills, and then writes fail. */
        mutex_lock(&j->lock);
        cetrafs_journal_hold_slot(j, slot, 0); /* kept on purpose: never superseded */
        mutex_unlock(&j->lock);
        pr_warn_ratelimited("journal: journal_skip_consume set -- leaving txn %llu (target %llu) LIVE in slot %llu\n",
                            (unsigned long long) txn_id, (unsigned long long) bh->b_blocknr,
                            (unsigned long long) slot);
        return 0;
    }

    if (journaled) {
        /* Same volatile-cache reasoning as the flush above: sync_dirty_buffer
         * only completed the target write. Flush so it is durable BEFORE the
         * entry is consumed -- otherwise a reordering cache could persist the
         * consume (zeroed header) but lose the torn target, erasing the one
         * entry that could have redone it. A failed flush stops the mount
         * (the cache's contents are unknown) and keeps the entry. */
        int ferr = blkdev_issue_flush(sb->s_bdev);

        if (ferr)
            cetrafs_sb_fatal(sb, "journal: cache flush after the write of block %llu failed (%d)",
                             (unsigned long long) bh->b_blocknr, ferr);
        if (ferr || cetrafs_journal_zero_header(sb, header_lba)) {
            /* Not consumed: the entry stays live, which the replay guard
             * makes harmless -- the target is durable, so a replay finds
             * the after-image (or, once the block has legitimately changed
             * again, a complete image that is neither) and skips it. It
             * used to be safe only "while we hold this op's lock", which
             * under nofilelock is no lock at all. The slot is held, as a
             * kept entry's is, until a later write of the block retires
             * it (by taking the slot over): released now, it could be
             * reused while the zero might still land late over the new
             * entry's header. */
            pr_err("journal: consume of slot %llu did not reach the device (entry stays; replay of it is "
                   "harmless)\n",
                   (unsigned long long) slot);
            mutex_lock(&j->lock);
            cetrafs_journal_hold_slot(j, slot, bh->b_blocknr);
            mutex_unlock(&j->lock);
            return 0;
        }

        mutex_lock(&j->lock);
        clear_bit(slot, j->busy);
        mutex_unlock(&j->lock);
        wake_up(&j->slot_wq);
    }

    return 0;

journal_failed:
    /* Could not write the entry: the target is not written either (see
     * the top of this function). What did reach the device may be a
     * complete entry -- both writes can land and still be reported
     * failed -- so retire it before giving the slot back; if even that
     * cannot be shown, hold the slot as a kept entry's is held. */
    cetrafs_bh_abort_update(bh);
    mutex_lock(&j->lock);
    if (cetrafs_journal_zero_header(sb, header_lba)) {
        cetrafs_journal_hold_slot(j, slot, bh->b_blocknr);
        mutex_unlock(&j->lock);
    } else {
        clear_bit(slot, j->busy);
        mutex_unlock(&j->lock);
        wake_up(&j->slot_wq);
    }
    pr_err_ratelimited("journal: could not write an entry for block %llu -- refusing to write it unjournaled\n",
                       (unsigned long long) bh->b_blocknr);
    /* A refused entry write is kind 3 of docs/internal/ERRORS.md -- the
     * entry may be on the device complete, torn, or not at all. Stop
     * only now, AFTER the retire above: the caller is told the
     * operation did not happen, and a stop first would refuse the
     * zeroing write too, leaving a complete entry for the next mount's
     * replay to redo (tests/kernel/journal_fails_loudly.sh, part 1). */
    if (entry_refused)
        cetrafs_sb_fatal(sb, "journal: the device refused the entry for block %llu",
                         (unsigned long long) bh->b_blocknr);
    return -EIO;
}

/*
 * TEST ONLY: the next deferred batch stops the mount the moment its
 * entries are durable, before any target is written -- a crash at the
 * worst point of the boundary, with the journal holding the only copy
 * of the new tree blocks (tests/kernel/leaf_boundary_journaled.sh).
 */
static bool cetrafs_journal_batch_crash_before_targets;
cetrafs_test_param(journal_batch_crash_before_targets, cetrafs_journal_batch_crash_before_targets, bool, 0644);
MODULE_PARM_DESC(journal_batch_crash_before_targets,
                 "TEST ONLY: the next deferred tree-block batch stops the mount after its entries, before its targets");

/* Write a deferred block's current image to its own LBA and wait. A
 * block freed since it was collected is skipped (and counts as done: its
 * entry is spent with the rest). */
static int cetrafs_deferred_write_target(struct super_block *sb, struct buffer_head *bh, u32 *wcrc)
{
    int ret = cetrafs_write_deferred_target(sb, bh, wcrc);

    return ret > 0 ? 0 : ret;
}

/* Give a batch's slots back after its entries were retired (or hold the
 * ones whose retire could not be shown, as a kept entry's are held). */
static void cetrafs_journal_batch_retire(struct super_block *sb, struct cetrafs_journal *j, const u64 *slots,
                                         struct buffer_head **bhs, unsigned int k)
{
    unsigned int i;

    for (i = 0; i < k; i++) {
        bool zero_failed = cetrafs_journal_zero_header(sb, cetrafs_journal_header_lba(j, slots[i])) != 0;

        mutex_lock(&j->lock);
        if (zero_failed)
            cetrafs_journal_hold_slot(j, slots[i], bhs[i]->b_blocknr);
        else
            clear_bit(slots[i], j->busy);
        mutex_unlock(&j->lock);
    }
    wake_up(&j->slot_wq);
}

#define CETRAFS_JRNL_BATCH 16

/* One chunk of a deferred batch: k entries in k slots already taken. */
static int cetrafs_journal_batch_chunk(struct super_block *sb, struct cetrafs_journal *j,
                                       struct buffer_head **bhs, const u32 *disk_crc, unsigned int k,
                                       const u64 *slots, const u64 *txn, bool *written, u32 *wcrc)
{
    struct buffer_head *pb[CETRAFS_JRNL_BATCH] = {}, *hb[CETRAFS_JRNL_BATCH] = {};
    unsigned int i, nw = 0;
    bool ok = true;
    int ret = 0, ferr;

    /* 1. Every entry: payload and header, all out together, waited for
     * once. Each payload is the block's current image, copied under its
     * lock; nothing modifies it meanwhile (the caller's invalidate_lock). */
    for (i = 0; i < k; i++) {
        u64 hlba = cetrafs_journal_header_lba(j, slots[i]);
        cetrafs_journal_header_t *hdr;
        u32 pcrc;

        pb[i] = cetrafs_getblk_overwrite(sb, hlba + 1);
        hb[i] = pb[i] ? cetrafs_getblk_overwrite(sb, hlba) : NULL;
        if (!pb[i] || !hb[i]) {
            if (pb[i])
                cetrafs_bh_abort_update(pb[i]);
            ok = false;
            break;
        }
        cetrafs_bh_copy_stable(bhs[i], pb[i]->b_data, CETRAFS_BLOCK_SIZE);
        pcrc = ~crc32c(~0U, pb[i]->b_data, CETRAFS_BLOCK_SIZE);
        cetrafs_bh_end_update(pb[i]);

        memset(hb[i]->b_data, 0, CETRAFS_BLOCK_SIZE);
        hdr = (cetrafs_journal_header_t *) hb[i]->b_data;
        hdr->magic = cetrafs_cpu_to_le32(CETRAFS_JOURNAL_MAGIC);
        hdr->flags = cetrafs_cpu_to_le32(CETRAFS_JRNL_F_GUARDED);
        hdr->txn_id = cetrafs_cpu_to_le64(txn[i]);
        hdr->target_lba = cetrafs_cpu_to_le64(bhs[i]->b_blocknr);
        /* The DEVICE's image, recorded when the block was first held back
         * -- not the in-core one before the last edit, which never
         * reached the device and which a replay would never find. */
        hdr->prev_checksum = cetrafs_cpu_to_le32(disk_crc[i]);
        hdr->payload_checksum = cetrafs_cpu_to_le32(pcrc);
        hdr->header_checksum = cetrafs_cpu_to_le32(cetrafs_journal_header_crc(hb[i]->b_data));
        cetrafs_bh_end_update(hb[i]);
    }
    if (ok) {
        struct blk_plug plug;

        blk_start_plug(&plug);
        for (i = 0; i < k; i++) {
            write_dirty_buffer(pb[i], REQ_SYNC);
            write_dirty_buffer(hb[i], REQ_SYNC);
        }
        blk_finish_plug(&plug);
    }
    for (i = 0; i < k; i++) {
        if (pb[i]) {
            wait_on_buffer(pb[i]);
            if (ok && !buffer_uptodate(pb[i]))
                ok = false;
            brelse(pb[i]);
        }
        if (hb[i]) {
            wait_on_buffer(hb[i]);
            if (ok && !buffer_uptodate(hb[i]))
                ok = false;
            brelse(hb[i]);
        }
    }
    if (!ok) {
        /* As the single write's journal_failed: retire what may have
         * landed, refuse, and stop -- the entries' state is unknown. */
        cetrafs_journal_batch_retire(sb, j, slots, bhs, k);
        cetrafs_sb_fatal(sb, "journal: the device refused a batch of %u tree-block entries", k);
        return -EIO;
    }
    atomic64_add(k, &cetrafs_journal_writes);

    /* 2. The entries on the platter before any target can be. */
    ferr = blkdev_issue_flush(sb->s_bdev);
    if (ferr) {
        cetrafs_sb_fatal(sb, "journal: cache flush after a batch of %u entries failed (%d)", k, ferr);
        mutex_lock(&j->lock);
        for (i = 0; i < k; i++)
            cetrafs_journal_hold_slot(j, slots[i], bhs[i]->b_blocknr);
        mutex_unlock(&j->lock);
        return ferr;
    }
    if (cetrafs_journal_batch_crash_before_targets) {
        cetrafs_journal_batch_crash_before_targets = false;
        mutex_lock(&j->lock);
        for (i = 0; i < k; i++)
            cetrafs_journal_hold_slot(j, slots[i], 0); /* kept on purpose: the replay's */
        mutex_unlock(&j->lock);
        cetrafs_sb_fatal(sb, "journal: TEST stop after %u entries, before their targets", k);
        return -EIO;
    }

    /* 3. The targets. One that fails keeps its entry live for replay. */
    for (i = 0; i < k; i++) {
        int werr = cetrafs_deferred_write_target(sb, bhs[i], &wcrc[i]);

        if (werr) {
            mutex_lock(&j->lock);
            cetrafs_journal_hold_slot(j, slots[i], bhs[i]->b_blocknr);
            mutex_unlock(&j->lock);
            pr_err("journal: tree block %llu failed to write (%d) -- its entry stays live for replay\n",
                   (unsigned long long) bhs[i]->b_blocknr, werr);
            if (!ret)
                ret = werr;
            continue;
        }
        written[i] = true;
        nw++;
    }
    if (!nw)
        return ret;

    /* 4. The targets on the platter before their entries are spent. */
    ferr = blkdev_issue_flush(sb->s_bdev);
    if (ferr) {
        cetrafs_sb_fatal(sb, "journal: cache flush after a batch of %u tree-block writes failed (%d)", nw, ferr);
        mutex_lock(&j->lock);
        for (i = 0; i < k; i++)
            if (written[i])
                cetrafs_journal_hold_slot(j, slots[i], bhs[i]->b_blocknr);
        mutex_unlock(&j->lock);
        for (i = 0; i < k; i++)
            written[i] = false; /* not shown durable: stays held back */
        return ferr;
    }

    /* 5. Consume. */
    for (i = 0; i < k; i++) {
        if (!written[i])
            continue;
        if (cetrafs_journal_zero_header(sb, cetrafs_journal_header_lba(j, slots[i]))) {
            mutex_lock(&j->lock);
            cetrafs_journal_hold_slot(j, slots[i], bhs[i]->b_blocknr); /* live and harmless: see the single write */
            mutex_unlock(&j->lock);
        } else {
            mutex_lock(&j->lock);
            clear_bit(slots[i], j->busy);
            mutex_unlock(&j->lock);
        }
    }
    wake_up(&j->slot_wq);
    return ret;
}

/*
 * Write a set of deferred extent-tree blocks (leafdefer.c) through the
 * journal (crash review 2026-11-08, C1 and C2).
 *
 *  0. What the blocks name reaches the device first: the allocation bits
 *     (cetrafs_alloc_flush_bitmaps()) and a cache flush, which also makes
 *     the data written back so far durable. A leaf marking a block
 *     written must never be durable ahead of that block's data or bit --
 *     and once its entry is, replay would publish it (C2).
 *  1. One entry per block (one slot each, the format's), all written at
 *     once; prev_checksum is the device's image of the block.
 *  2. Flush: every entry durable before any target is touched.
 *  3. The targets, in place. A crash here leaves each one old, new or
 *     torn, and replay redoes the torn and the old (C1).
 *  4. Flush, then 5. consume.
 *
 * Three flushes per boundary, whatever the number of blocks -- not per
 * block, which is what made per-write journaling unusable. In chunks of
 * CETRAFS_JRNL_BATCH slots, taken without waiting once one is held (no
 * hold-and-wait between two batches).
 *
 * The caller guarantees nobody modifies the blocks meanwhile. written[i]
 * says which reached the device; the rest stay held back for a retry.
 * mkfs -J 0 has no journal: step 0, then the targets in place.
 */
int cetrafs_journal_write_deferred(struct super_block *sb, struct buffer_head **bhs, const u32 *disk_crc,
                                   unsigned int n, bool *written, u32 *wcrc)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);
    unsigned int i, done = 0;
    int ret;

    for (i = 0; i < n; i++)
        written[i] = false;
    if (!n)
        return 0;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;

    ret = cetrafs_alloc_flush_bitmaps(sb);
    if (ret)
        return ret;
    ret = blkdev_issue_flush(sb->s_bdev);
    if (ret)
        return ret; /* nothing written: the blocks stay held back */

    if (!j || !j->area_start) {
        for (i = 0; i < n; i++) {
            int werr = cetrafs_deferred_write_target(sb, bhs[i], &wcrc[i]);

            if (!werr)
                written[i] = true;
            else if (!ret)
                ret = werr;
        }
        return ret;
    }

    while (done < n) {
        u64 slots[CETRAFS_JRNL_BATCH], txn[CETRAFS_JRNL_BATCH];
        unsigned int k = 0;

        while (k < CETRAFS_JRNL_BATCH && done + k < n) {
            int t = cetrafs_journal_take_slot(sb, j, bhs[done + k]->b_blocknr, k > 0, &slots[k], &txn[k]);

            if (t == -EAGAIN)
                break; /* all in flight: go with what we hold */
            if (t) {
                if (k) {
                    mutex_lock(&j->lock);
                    for (i = 0; i < k; i++)
                        clear_bit(slots[i], j->busy);
                    mutex_unlock(&j->lock);
                    wake_up(&j->slot_wq);
                }
                return t;
            }
            k++;
        }
        ret = cetrafs_journal_batch_chunk(sb, j, bhs + done, disk_crc + done, k, slots, txn, written + done,
                                          wcrc + done);
        if (ret)
            return ret;
        done += k;
    }
    return 0;
}

/*
 * Journal a block that was READ and then modified. prev_crc is the CRC32C
 * of the image as it stood before the modification -- take it from
 * cetrafs_bh_begin_update_crc(), which locks the buffer and snapshots it
 * in one call so the two cannot drift apart.
 */
int cetrafs_journal_write_block(struct super_block *sb, struct buffer_head *bh, u32 prev_crc)
{
    return cetrafs_journal_write_block_flags(sb, bh, CETRAFS_JRNL_F_GUARDED, prev_crc);
}

/*
 * Journal a block claimed WITHOUT reading -- a freshly allocated block
 * being initialised in full (a new extent leaf/index, a new xattr block).
 * It has no prior image, so there is nothing for prev_checksum to say.
 *
 * Replay skips these entirely, and loses nothing by it. An entry only
 * survives if its writer died inside cetrafs_journal_write_block_flags(),
 * before it returned -- so the caller never got to install the block's
 * LBA into its parent, and nothing referenced the block at crash time. A
 * torn image in an unreferenced block harms no one and the scrub
 * reclaims it. Replaying it, on the other hand, is a live hazard: the
 * block may since have been reclaimed, reallocated to another node and
 * filled with real data, which the payload would overwrite.
 */
int cetrafs_journal_write_new_block(struct super_block *sb, struct buffer_head *bh)
{
    /*
     * NOT journalled -- written and synced only.
     *
     * Replay SKIPS a fresh-block entry by design (CETRAFS_JRNL_F_FRESH,
     * above): the block is unreferenced at crash time, because the
     * caller had not yet installed its LBA into any parent, so a torn
     * image in it harms nobody and the scrub reclaims it. The entry
     * could never be applied -- and writing one cost three device cache
     * flushes and two synchronous writes per block.
     *
     * On a preallocated VM image that was the dominant cost of the
     * entire filesystem: every 4 KiB guest write converts a block out
     * of an uninit extent, which appends to the tree, which writes new
     * leaf blocks. Measured on the deployment SAN at 1891 of 1907 cache
     * flushes for twenty 4 KiB writes -- 95 flushes per write, every
     * one of them for an entry replay would have thrown away.
     *
     * The SYNC stays, and is the part that matters: rule 8 says a
     * reference may not become durable before what it refers to, and
     * the caller publishes that reference afterwards.
     */
    if (cetrafs_sb_is_fenced(sb)) {
        cetrafs_bh_abort_update(bh);
        return -EIO;
    }

    cetrafs_bh_end_update(bh);
    /* The result from the write itself, never from BH_Uptodate -- a
     * forced-fresh reader may clear that concurrently (ioutil.c). */
    return cetrafs_sync_buffer(sb, bh);
}

/*
 * Clean-unmount path: nothing can be outstanding (every entry is
 * consumed within its own operation), so just park our flag at CLEAN so
 * the next mount's own-replay can skip the slot scan.
 */
void cetrafs_journal_shutdown(struct super_block *sb)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);

    if (!j || !j->area_start)
        return;

    mutex_lock(&j->lock);
    if (j->flag_dirty) {
        if (!bitmap_empty(j->busy, j->slots))
            pr_err("journal: shutdown with in-flight slots still busy -- leaving flag dirty\n");
        else if (cetrafs_journal_write_flag(sb, j->area_start, false) == 0)
            j->flag_dirty = false;
    }
    mutex_unlock(&j->lock);
}

/* TEST ONLY: the next N replay target lookups fail as an unreadable
 * descriptor would (tests/kernel/journal_replay_lookup_error.sh). */
static unsigned int cetrafs_journal_replay_lookup_fail;
cetrafs_test_param(journal_replay_lookup_fail, cetrafs_journal_replay_lookup_fail, uint, 0644);
MODULE_PARM_DESC(journal_replay_lookup_fail, "TEST ONLY: fail the next N journal replay target lookups with -EIO");

struct cetrafs_journal_replay_entry {
    u64 txn_id;
    u64 target_lba;
    u64 header_lba;
    u64 payload_lba;
    u32 flags;
    u32 prev_checksum;
    u32 payload_checksum;
};

static int cetrafs_journal_replay_cmp(const void *a, const void *b)
{
    const struct cetrafs_journal_replay_entry *ea = a, *eb = b;

    return cmp_int(ea->txn_id, eb->txn_id);
}

/* Entries replay applied because the target was TORN -- the journal
 * doing the one job it exists for. Distinct from a plain apply so a
 * test can tell "it repaired a tear" from "it redid a lost write". */
static atomic64_t cetrafs_journal_replay_torn = ATOMIC64_INIT(0);

u64 cetrafs_journal_replay_torn_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_replay_torn);
}

/*
 * Is this target a COMPLETE image, whoever wrote it?
 *
 * Every block the journal covers -- extent leaf, interior, xattr,
 * dirent -- ends in a {magic, crc} tail over the preceding bytes, at
 * the same offset and in the same shape. Checking the crc against the
 * content is therefore magic-agnostic: it answers "is this a whole
 * block" without knowing which kind it is.
 *
 * That distinction is the whole point. prev_checksum tells redo whether
 * the target still holds the image the entry was written against, which
 * correctly refuses to roll back a PEER's newer write. But a TORN
 * target matches neither checksum either, and redoing a torn block is
 * precisely what the journal is for. Without this the guard refused to
 * repair tears: the crash rig's phase 5 left 60 of 60 torn xattr blocks
 * unrecovered, reading -EIO forever.
 */
static bool cetrafs_journal_target_intact(const struct buffer_head *bh)
{
    const cetrafs_blk_tail_t *tail = (const cetrafs_blk_tail_t *) (bh->b_data + CETRAFS_BLK_TAIL_OFF);

    return cetrafs_le32(tail->crc) == ~crc32c(~0U, bh->b_data, CETRAFS_BLK_TAIL_OFF);
}

enum cetrafs_journal_verdict {
    CETRAFS_JV_APPLY,           /* target still holds the before-image: redo */
    CETRAFS_JV_UNGUARDED,       /* entry carries no before-image to check: refused */
    CETRAFS_JV_TORN,            /* target fails its own tail checksum */
    CETRAFS_JV_LANDED,          /* target already holds the after-image */
    CETRAFS_JV_CHANGED,         /* a complete image that is neither: rewritten since */
    CETRAFS_JV_REUSED,          /* not a block of the entry's kind at all: freed and reused */
    CETRAFS_JV_MOVING,          /* kept changing between verdict and redo */
};

/* Torn re-reads (10 ms doubling: ~2.5 s in all) and how often the block
 * may move between the verdict and the redo before it is refused. */
#define CETRAFS_JOURNAL_TORN_RETRIES 8
#define CETRAFS_JOURNAL_MOVED_RETRIES 3

/*
 * Is the target still a block of the entry's KIND? A guarded entry is
 * only ever written for a block that was read and modified in place, so
 * its before- and after-images carry the same tail magic, and a tear --
 * old sectors and new ones -- leaves that magic in the tail sector
 * whichever of the two it holds. A block whose tail magic is anything
 * else was freed and reused (as file data, as zeroes after a discard, as
 * another kind of metadata), and "fails its tail checksum" says nothing
 * about a tear there: data has no tail at all. Judged TORN, it was
 * overwritten with the dead node's metadata image -- a peer's file data
 * replaced silently, and fsck has no checksum on data to notice.
 */
static bool cetrafs_journal_same_kind(const struct buffer_head *tbh, const struct buffer_head *pbh)
{
    const cetrafs_blk_tail_t *tt = (const cetrafs_blk_tail_t *) (tbh->b_data + CETRAFS_BLK_TAIL_OFF);
    const cetrafs_blk_tail_t *pt = (const cetrafs_blk_tail_t *) (pbh->b_data + CETRAFS_BLK_TAIL_OFF);

    return tt->magic == pt->magic;
}

static enum cetrafs_journal_verdict cetrafs_journal_judge(const struct cetrafs_journal_replay_entry *e,
                                                          const struct buffer_head *tbh,
                                                          const struct buffer_head *pbh,
                                                          u32 tcrc)
{
    if (cetrafs_journal_ignore_guard)
        return CETRAFS_JV_APPLY;
    if (tcrc == e->payload_checksum)
        return CETRAFS_JV_LANDED; /* only the consume was lost */
    /* Every entry this format writes is GUARDED (or FRESH, skipped
     * before here). One that is neither was written by a module that
     * predates the guard -- which cannot mount this format -- or is
     * damaged or crafted, and its redo would be a blind 4 KiB write
     * nothing can check (audit L7). */
    if (!(e->flags & CETRAFS_JRNL_F_GUARDED))
        return CETRAFS_JV_UNGUARDED;
    if (tcrc == e->prev_checksum)
        return CETRAFS_JV_APPLY; /* the target write never landed */
    if (!cetrafs_journal_ignore_torn && !cetrafs_journal_target_intact(tbh)) {
        if (!cetrafs_journal_ignore_kind && !cetrafs_journal_same_kind(tbh, pbh))
            return CETRAFS_JV_REUSED;
        return CETRAFS_JV_TORN;
    }
    return CETRAFS_JV_CHANGED;
}

/*
 * Replay node #node_id's journal area: if its flag says DIRTY, scan its
 * slots for valid entries (header magic + header CRC + payload CRC all
 * verified -- the payload check matters, since a torn payload write with
 * an already-committed header must not be applied as if whole... though
 * the header is only ever synced AFTER the payload, so in practice a
 * valid header implies a durable payload; the check is belt and
 * suspenders), sort by txn_id, apply each (copy payload over
 * target_lba), consume them, and park the flag at CLEAN.
 *
 * Replay serializes on the per-area replay claim (CAS), not a mutex:
 * a node that loses the claim gets -EEXIST. With wait_for_claim it waits
 * for the holder to finish instead, and every caller that goes on to
 * TAKE something from the dead node must pass it: its own area at
 * mount-attach, and every lock, namespace-lock and Zone Group reclaim.
 * Only the heartbeat sweep, which takes nothing, may walk away. That
 * plus the flag check serializes concurrent replayers, and replaying
 * twice is idempotent regardless. Reads of the flag and slot
 * headers are uncached: this area belongs to a different node whose
 * writes our cache has never seen.
 */
static int __cetrafs_journal_replay_node(struct super_block *sb, u32 node_id, bool wait_for_claim);

int cetrafs_journal_replay_node(struct super_block *sb, u32 node_id, bool wait_for_claim)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);
    int ret;

    if (!j || node_id >= 64)
        return __cetrafs_journal_replay_node(sb, node_id, wait_for_claim);
    /*
     * A caller that does not wait for a replay claim does not wait for
     * this mutex either: its holder is a local replay of the same area,
     * which may run for the claim cap (several stale windows) behind a
     * peer's. That caller is the heartbeat sweep, which takes nothing
     * from the dead node and whose tick must not stall behind an open's
     * replay (audit F9). -EEXIST is its "someone is at it" already.
     */
    if (!wait_for_claim) {
        if (!mutex_trylock(&j->replay_mutex[node_id]))
            return -EEXIST;
    } else if (mutex_lock_killable(&j->replay_mutex[node_id])) {
        return -EINTR;
    }
    mutex_lock(&j->rel_mutex);
    atomic_inc(&j->replaying[node_id]);
    mutex_unlock(&j->rel_mutex);
    /* Waited behind another replay of the same area: the node it was
     * fenced as may have come back meanwhile, and its journal is then a
     * live one. Only a reclaim fences, so only a reclaim is asked; this
     * node replaying its own area at mount has no fence on record. */
    {
        u64 fenced;

        if (cetrafs_sb_peer_fenced_seq(sb, node_id, &fenced) && cetrafs_node_reattached_since_fence(sb, node_id)) {
            pr_info("journal: node %u came back while its journal waited to be replayed -- not replaying it\n",
                    node_id);
            ret = -EBUSY;
        } else {
            ret = __cetrafs_journal_replay_node(sb, node_id, wait_for_claim);
        }
    }
    atomic_dec(&j->replaying[node_id]);
    mutex_unlock(&j->replay_mutex[node_id]);
    return ret;
}

/* TEST ONLY: fail the next replay consume (the header zeroing), as a
 * write the device refused would (tests/kernel/journal_consume_fail.sh). */
static bool cetrafs_journal_consume_fail_once;
cetrafs_test_param(journal_consume_fail_once, cetrafs_journal_consume_fail_once, bool, 0644);
MODULE_PARM_DESC(journal_consume_fail_once, "TEST ONLY: fail the next journal replay consume with -EIO");

static int __cetrafs_journal_replay_node(struct super_block *sb, u32 node_id, bool wait_for_claim)
{
    u64 area_start, slots, s;
    struct cetrafs_journal_replay_entry *entries;
    u32 count = 0, applied = 0, my_node_id = 0;
    bool dirty = false, claimed = false;
    int ret, werr_consume;

    /* No such row, so no such journal: nothing to replay
     * (cetrafs_node_fence_peer_full()). */
    if (cetrafs_sb_raw(sb) && node_id >= le32_to_cpu(cetrafs_sb_raw(sb)->node_table_count))
        return 0;
    ret = cetrafs_journal_node_area(sb, node_id, &area_start, &slots);
    if (ret)
        return ret;
    if (!area_start)
        return 0;

    /* Cheap pre-check: the overwhelmingly common case is a clean area,
     * and that costs one read rather than a CAS. */
    ret = cetrafs_journal_read_flag(sb, area_start, &dirty);
    if (ret || !dirty)
        return ret;

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret)
        return ret;

    /* Replay writes the data region, and a self-fenced node writes
     * nothing -- whichever path brought it here (cetrafs_node_fence_peer()
     * refuses too; this is the same rule where the writes happen). */
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;

    /* Claim the right to replay this area. -EEXIST means another node is
     * already on it (or beat us to it entirely). */
    ret = cetrafs_journal_claim_replay(sb, area_start, my_node_id);
    if (ret == -EEXIST && wait_for_claim) {
        /*
         * A live peer is mid-replay, and this caller is about to build
         * on the result -- so it waits for the result.
         *
         * Our OWN area at mount-attach: walking away would let this
         * mount start writing while the replayer is still working it --
         * new entries into slots whose headers its consume pass is about
         * to zero, new data over blocks it is about to rewrite with our
         * old images.
         *
         * A dead node's area, from a caller about to take its lock, its
         * namespace lock or its Zone Group: walking away used to return
         * success here, and the caller then stole the claim and wrote
         * the very blocks the replayer was judging. Its verdict on an
         * entry is then wrong either way: it refuses the entry as
         * changed (a half-done rename stays half done) or, having judged
         * it already, writes the old image over the caller's.
         *
         * The claim clears in seconds (the area is a handful of slots),
         * or the replayer itself goes stale and the re-claim below
         * steals it. Bounded so a wedged claim fails loudly rather than
         * hangs, and killable.
         */
        /* Elapsed time by the clock, not by counting sleeps: any
         * pending NON-fatal signal makes msleep_interruptible() return
         * at once, and a count of 500 ms per pass burned the whole cap
         * in a burst of claim CASes and refused with a false "still
         * held after 210000 ms" (audit R21). */
        const unsigned long t0 = jiffies;
        const unsigned long cap = (unsigned long) (cetrafs_sb_stale_secs(sb) * 3 + 30) * HZ;

        pr_info("journal: a peer is replaying node %u's area %llu -- waiting for it to finish\n", node_id,
                (unsigned long long) area_start);
        while (ret == -EEXIST) {
            if (time_after_eq(jiffies, t0 + cap)) {
                pr_err("journal: replay claim on node %u's area %llu still held after %ums -- refusing\n", node_id,
                       (unsigned long long) area_start, jiffies_to_msecs(jiffies - t0));
                return -EBUSY;
            }
            /* Killable, not interruptible: a pending non-fatal signal
             * must not turn the sleep into a spin. */
            schedule_timeout_killable(msecs_to_jiffies(500));
            if (fatal_signal_pending(current))
                return -EINTR;
            /* A mount waiting here has no heartbeat yet: beat, or every
             * peer judges it stale while it waits (audit R19). */
            ret = cetrafs_sb_mount_beat(sb);
            if (ret)
                return ret;
            ret = cetrafs_journal_read_flag(sb, area_start, &dirty);
            if (ret)
                return ret;
            if (!dirty)
                return 0; /* the replayer finished the job and parked it clean */
            ret = cetrafs_journal_claim_replay(sb, area_start, my_node_id);
        }
    }
    if (ret) {
        if (ret == -EEXIST) {
            /* The heartbeat sweep, which takes nothing from the dead
             * node, walking away from a replay a peer is doing. Counted,
             * not just tolerated: it is the only evidence that the race
             * happened at all. */
            atomic64_inc(&cetrafs_journal_replay_declines);
            return 0;
        }
        return ret;
    }
    claimed = true;
    atomic64_inc(&cetrafs_journal_replays);

    /* Re-read under the claim: the pre-check above was unsynchronised,
     * so a peer may have replayed the whole area in between. */
    ret = cetrafs_journal_read_flag(sb, area_start, &dirty);
    if (ret || !dirty)
        goto out_release;

    entries = kvmalloc_array(slots, sizeof(*entries), GFP_KERNEL);
    if (!entries) {
        ret = -ENOMEM;
        goto out_release;
    }

    for (s = 0; s < slots; s++) {
        u64 header_lba = area_start + 1 + s * CETRAFS_JOURNAL_SLOT_BLOCKS;
        struct buffer_head *hbh, *pbh;
        const cetrafs_journal_header_t *hdr;
        u32 payload_crc;

        hbh = cetrafs_bread_uncached_retry(sb, header_lba);
        if (!hbh) {
            ret = -EIO;
            goto out_free;
        }
        hdr = (const cetrafs_journal_header_t *) hbh->b_data;

        if (cetrafs_le32(hdr->magic) != CETRAFS_JOURNAL_MAGIC ||
            cetrafs_journal_header_crc(hbh->b_data) != cetrafs_le32(hdr->header_checksum)) {
            brelse(hbh);
            continue;
        }

        pbh = cetrafs_bread_uncached_retry(sb, header_lba + 1);
        if (!pbh) {
            brelse(hbh);
            ret = -EIO;
            goto out_free;
        }
        payload_crc = ~crc32c(~0U, pbh->b_data, CETRAFS_BLOCK_SIZE);
        brelse(pbh);

        if (payload_crc != cetrafs_le32(hdr->payload_checksum)) {
            pr_warn("journal replay: node %u slot %llu has a committed header but torn payload -- skipping\n", node_id,
                    (unsigned long long) s);
            brelse(hbh);
            continue;
        }

        /*
         * Sanity-check the target before trusting it. The header's CRC
         * proves the entry is self-CONSISTENT, not that it is SANE --
         * and replay's next act is a blind 4 KiB memcpy to whatever LBA
         * this field names. Journaling's scope is deliberately narrow:
         * only BG-data-region content (dirent blocks, xattr blocks,
         * extent-leaf blocks) is ever logged. A target outside that is
         * definitionally a corrupt entry, and applying it would write
         * over the superblock, the inode table, or another node's
         * journal -- turning one bad block into a destroyed filesystem.
         * Refuse loudly instead; the entry is dropped with the rest of
         * the area when the flag is parked clean.
         */
        /*
         * "Outside every data region" is one answer the lookup gives
         * (-EINVAL); a descriptor it could not read is another, and it
         * was taken for the first: a cold descriptor read failing during
         * a path failover dropped a valid entry, and the area was then
         * parked CLEAN over it -- the torn block it would have repaired
         * stayed torn for good (audit 2026-11-06 M3;
         * tests/kernel/journal_replay_lookup_error.sh). Not knowing
         * aborts with the area DIRTY, as a payload read failure does;
         * the next replay asks again.
         */
        {
            u32 tgt_zg;
            int lret = cetrafs_bg_owner_zg_for_lba(sb, cetrafs_le64(hdr->target_lba), &tgt_zg);

            if (!lret && READ_ONCE(cetrafs_journal_replay_lookup_fail)) {
                WRITE_ONCE(cetrafs_journal_replay_lookup_fail, cetrafs_journal_replay_lookup_fail - 1);
                lret = -EIO; /* test-only */
            }
            if (lret == -EINVAL) {
                pr_err(
                    "journal replay: node %u slot %llu names target block %llu, which is outside every BG data "
                    "region -- refusing to apply it\n",
                    node_id, (unsigned long long) s, (unsigned long long) cetrafs_le64(hdr->target_lba));
                brelse(hbh);
                continue;
            }
            if (lret) {
                pr_err("journal replay: node %u slot %llu: could not tell where target block %llu lies (%d) -- "
                       "leaving the area dirty for the next replay\n",
                       node_id, (unsigned long long) s, (unsigned long long) cetrafs_le64(hdr->target_lba), lret);
                brelse(hbh);
                ret = lret;
                goto out_free;
            }
        }

        entries[count].txn_id = cetrafs_le64(hdr->txn_id);
        entries[count].target_lba = cetrafs_le64(hdr->target_lba);
        entries[count].header_lba = header_lba;
        entries[count].payload_lba = header_lba + 1;
        entries[count].flags = cetrafs_le32(hdr->flags);
        entries[count].prev_checksum = cetrafs_le32(hdr->prev_checksum);
        entries[count].payload_checksum = cetrafs_le32(hdr->payload_checksum);
        count++;
        brelse(hbh);
    }

    if (count)
        sort(entries, count, sizeof(*entries), cetrafs_journal_replay_cmp, NULL);

    for (s = 0; s < count; s++) {
        struct buffer_head *pbh, *tbh, *hbh;
        bool apply;

        /* A freshly-allocated block's entry: nothing referenced the
         * block when its writer died, so there is nothing to repair --
         * and the block may since have been reclaimed and handed to
         * somebody else. Never apply one. */
        if ((entries[s].flags & CETRAFS_JRNL_F_FRESH) && !cetrafs_journal_ignore_guard) {
            atomic64_inc(&cetrafs_journal_replay_skipped);
            pr_debug("journal replay: node %u txn %llu targets freshly-allocated block %llu -- nothing to repair\n",
                     node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].target_lba);
            goto consume;
        }

        /* A target freed since the entry was written is nobody's block:
         * nothing published names it (a reference is never durable
         * before its bit), so there is nothing to repair -- and writing
         * it lands on a block the allocator may be handing out. The
         * prev_checksum guard cannot see this: freeing changes no byte
         * of the block (audit L9). Read fresh unless the BG is ours
         * (cetrafs_data_block_is_allocated()). A block allocated to
         * somebody else after this look is either written by its new
         * owner -- which the guard below then refuses -- or written
         * over by it whatever the redo put there. */
        if (!cetrafs_journal_ignore_guard) {
            bool live = true;
            int aret = cetrafs_data_block_is_allocated(sb, entries[s].target_lba, &live);

            if (aret == -EIO) {
                ret = aret;
                goto out_free;
            }
            if (!aret && !live) {
                atomic64_inc(&cetrafs_journal_replay_skipped);
                pr_info("journal replay: node %u txn %llu target block %llu has been freed since -- nothing to "
                        "repair, not writing it\n",
                        node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].target_lba);
                goto consume;
            }
        }

        pbh = cetrafs_bread_uncached_retry(sb, entries[s].payload_lba);
        if (!pbh) {
            ret = -EIO;
            goto out_free;
        }

        /* FORCED-FRESH, not sb_bread(): the whole point of the read is
         * to see what is on the DEVICE right now, including writes a
         * peer made that this node has never had reason to re-read.
         * A cached copy would answer the question we are not asking. */
        tbh = NULL;
        apply = false;
        {
            enum cetrafs_journal_verdict v;
            unsigned int torn_tries = 0, moved = 0;
            u32 tcrc;

            for (;;) {
                if (!tbh) {
                    tbh = cetrafs_bread_uncached_retry(sb, entries[s].target_lba);
                    if (!tbh) {
                        brelse(pbh);
                        ret = -EIO;
                        goto out_free;
                    }
                }
                tcrc = ~crc32c(~0U, tbh->b_data, CETRAFS_BLOCK_SIZE);
                v = cetrafs_journal_judge(&entries[s], tbh, pbh, tcrc);

                /*
                 * TORN is a crash's tear -- or a LIVE writer's write in
                 * flight, which a forced-fresh read of a 4 KiB block can
                 * catch half-landed. Under nofilelock a live node may be
                 * writing the dead one's blocks (the VM was restarted
                 * there), and redoing then puts the dead node's image over
                 * the live write. A write in flight converges in
                 * milliseconds and a crash's tear never does: re-read with
                 * backoff (~2.5 s in all) before believing it.
                 */
                if (v == CETRAFS_JV_TORN && torn_tries < CETRAFS_JOURNAL_TORN_RETRIES) {
                    if (!torn_tries)
                        pr_info("journal replay: node %u txn %llu target block %llu reads torn -- re-reading in "
                                "case a live writer is mid-write\n",
                                node_id, (unsigned long long) entries[s].txn_id,
                                (unsigned long long) entries[s].target_lba);
                    brelse(tbh);
                    tbh = NULL;
                    msleep(10U << torn_tries);
                    torn_tries++;
                    continue;
                }
                if (v != CETRAFS_JV_APPLY && v != CETRAFS_JV_TORN)
                    break;

                if (unlikely(cetrafs_journal_replay_apply_pause_ms)) {
                    pr_info("journal replay: pausing %ums before redoing target %llu\n",
                            cetrafs_journal_replay_apply_pause_ms, (unsigned long long) entries[s].target_lba);
                    msleep(cetrafs_journal_replay_apply_pause_ms);
                }

                /* CLAUDE.md rule 15: the verdict is only as good as its
                 * distance from the act. Re-read immediately before the
                 * redo and require the block to be what was judged; if it
                 * moved, somebody is writing it -- judge again. A block
                 * that keeps moving is being written by a live node and is
                 * refused. (This narrows the gap; a 4 KiB block has no CAS
                 * to close it.) */
                brelse(tbh);
                tbh = cetrafs_bread_uncached_retry(sb, entries[s].target_lba);
                if (!tbh) {
                    brelse(pbh);
                    ret = -EIO;
                    goto out_free;
                }
                if (~crc32c(~0U, tbh->b_data, CETRAFS_BLOCK_SIZE) == tcrc)
                    break;
                if (++moved > CETRAFS_JOURNAL_MOVED_RETRIES) {
                    v = CETRAFS_JV_MOVING;
                    break;
                }
            }

            switch (v) {
            case CETRAFS_JV_APPLY:
                apply = true;
                break;
            case CETRAFS_JV_UNGUARDED:
                atomic64_inc(&cetrafs_journal_replay_refused);
                pr_err("journal replay: node %u txn %llu (target %llu) carries no replay guard, which no writer of "
                       "this format emits -- NOT applying it\n",
                       node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].target_lba);
                break;
            case CETRAFS_JV_TORN:
                /* Still torn after the re-reads: not a peer's newer
                 * write -- not a whole block at all. Redo it: this is the
                 * case the journal exists for, and refusing here leaves
                 * the block unreadable forever. */
                apply = true;
                atomic64_inc(&cetrafs_journal_replay_torn);
                pr_warn("journal replay: node %u txn %llu target block %llu is TORN (fails its own tail "
                        "checksum) -- redoing it\n",
                        node_id, (unsigned long long) entries[s].txn_id,
                        (unsigned long long) entries[s].target_lba);
                break;
            case CETRAFS_JV_LANDED:
                atomic64_inc(&cetrafs_journal_replay_skipped);
                break;
            case CETRAFS_JV_REUSED:
                atomic64_inc(&cetrafs_journal_replay_refused);
                pr_err("journal replay: node %u txn %llu target block %llu is no longer a block of the entry's "
                       "kind -- freed and reused since; NOT applying the entry\n",
                       node_id, (unsigned long long) entries[s].txn_id,
                       (unsigned long long) entries[s].target_lba);
                break;
            case CETRAFS_JV_MOVING:
                atomic64_inc(&cetrafs_journal_replay_refused);
                pr_err("journal replay: node %u txn %llu target block %llu kept changing while replay looked at "
                       "it -- a live node is writing it; NOT applying the entry\n",
                       node_id, (unsigned long long) entries[s].txn_id,
                       (unsigned long long) entries[s].target_lba);
                break;
            case CETRAFS_JV_CHANGED:
                /* A COMPLETE image that is neither the before nor the
                 * after. Somebody has legitimately written this block
                 * since -- under nofilelock, typically the node HA moved
                 * the VM to.
                 * Applying here is the corruption this guard exists to
                 * stop: a valid, CRC-correct, WRONG extent leaf that
                 * fsck cannot see. */
                atomic64_inc(&cetrafs_journal_replay_refused);
                pr_err("journal replay: node %u txn %llu target block %llu has changed since the entry was "
                       "written (crc %08x, expected %08x before / %08x after) -- NOT applying it. The block "
                       "has been rewritten since: by a peer that took the file over (the nofilelock case this "
                       "guard exists for), or by a later local operation whose consume was lost\n",
                       node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].target_lba,
                       tcrc, entries[s].prev_checksum, entries[s].payload_checksum);
                break;
            }
        }

        if (apply) {
            int werr;

            /* Through the update protocol, not a bare mark_buffer_dirty:
             * it takes the buffer lock and asserts uptodate, so a
             * concurrent reader cannot observe this block half-replaced.
             * Every other writer in the tree goes through it. */
            cetrafs_bh_begin_update(tbh);
            memcpy(tbh->b_data, pbh->b_data, CETRAFS_BLOCK_SIZE);
            cetrafs_bh_end_update(tbh);
            werr = cetrafs_sync_buffer(sb, tbh);
            if (werr) {
                /* Do NOT consume this entry and do NOT park the area
                 * CLEAN: the redo did not land, and the entry is the
                 * only thing that can still repair the target. Leaving
                 * the area DIRTY is what brings a later sweep back to
                 * it. Entries already applied and consumed above stay
                 * consumed, which is correct -- they succeeded. */
                pr_err("journal replay: node %u txn %llu failed to redo target %llu (%d) -- "
                       "entry kept, area stays dirty for a later attempt\n",
                       node_id, (unsigned long long) entries[s].txn_id,
                       (unsigned long long) entries[s].target_lba, werr);
                brelse(tbh);
                brelse(pbh);
                ret = werr;
                goto out_free;
            }
            /* Durable, not just completed, before the consume below --
             * the write path's own rule: a volatile cache can otherwise
             * persist the zeroed header and lose the redo, erasing the
             * only thing that could still repair the target. Replay is
             * rare; one flush per redo is nothing. */
            werr = blkdev_issue_flush(sb->s_bdev);
            if (werr) {
                pr_err("journal replay: node %u txn %llu flush after redo of target %llu failed (%d) -- "
                       "entry kept, area stays dirty for a later attempt\n",
                       node_id, (unsigned long long) entries[s].txn_id,
                       (unsigned long long) entries[s].target_lba, werr);
                brelse(tbh);
                brelse(pbh);
                ret = werr;
                goto out_free;
            }
            atomic64_inc(&cetrafs_journal_replay_applied);
            applied++;
        }
        brelse(tbh);
        brelse(pbh);

consume:
        hbh = cetrafs_bread_retry(sb, entries[s].header_lba);
        if (!hbh) {
            ret = -EIO;
            goto out_free;
        }
        if (READ_ONCE(cetrafs_journal_consume_fail_once) && xchg(&cetrafs_journal_consume_fail_once, false)) {
            werr_consume = -EIO; /* TEST ONLY: as a header write the device refused */
        } else {
            cetrafs_bh_begin_update(hbh);
            memset(hbh->b_data, 0, CETRAFS_BLOCK_SIZE);
            cetrafs_bh_end_update(hbh);
            werr_consume = cetrafs_sync_buffer(sb, hbh);
        }
        brelse(hbh);
        if (werr_consume) {
            /*
             * The entry stays, and so must the area's DIRTY flag. Parked
             * CLEAN, the leftover header is no longer anybody's to
             * replay: it waits in its slot to be judged by a 32-bit CRC
             * alone, which a later header can legitimately recur (audit
             * L8). Left DIRTY, the next replay meets it, finds the redo
             * already on the target and skips it. A replay that cannot
             * consume fails like one that cannot redo: this node's own
             * area at mount fails the mount, a peer's waits for the next
             * sweep.
             */
            pr_err("journal replay: node %u could not consume txn %llu (%d) -- entry kept, area stays dirty "
                   "for a later attempt\n",
                   node_id, (unsigned long long) entries[s].txn_id, werr_consume);
            ret = werr_consume;
            goto out_free;
        }
    }

    pr_info("journal replay: node %u replayed %u valid entr%s\n", node_id, applied, applied == 1 ? "y" : "ies");

    /* Park the flag at CLEAN and drop the claim in ONE compare-and-swap:
     * leaving it DIRTY-but-unclaimed, or CLEAN-but-still-claimed, would
     * each strand the area for a tick. A failed park is queued for the
     * heartbeat (cetrafs_journal_retry_release()) -- it must not wait
     * for a trigger that may never come -- and it must not be
     * SILENT: a three-node run counted the resulting same-node double
     * replay as two writers and a release scenario failed on it before
     * anyone knew parks could fail at all (2026-10-29). */
    cetrafs_journal_release_replay(sb, node_id, area_start, my_node_id, /*set_clean=*/true);
    claimed = false;

out_free:
    kvfree(entries);
out_release:
    if (claimed)
        cetrafs_journal_release_replay(sb, node_id, area_start, my_node_id, /*set_clean=*/false);
    return ret;
}

/* Is node #node_id's journal flag currently DIRTY? Used by heartbeat.c's
 * periodic sweep to decide whether a stale node's area needs a replay at
 * all without paying for the mutex + scan on the (overwhelmingly common)
 * clean case. */
int cetrafs_journal_node_is_dirty(struct super_block *sb, u32 node_id, bool *out_dirty)
{
    u64 area_start, slots;
    int ret;

    *out_dirty = false;
    ret = cetrafs_journal_node_area(sb, node_id, &area_start, &slots);
    if (ret)
        return ret;
    if (!area_start)
        return 0;

    return cetrafs_journal_read_flag(sb, area_start, out_dirty);
}
