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
#include <linux/sched/mm.h>
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
     * replays only after judging us stale, which takes at least the
     * window our row advertises (cetrafs_peer_window_floor_secs(), in
     * cetrafs_sb_peer_progress_stale()), while our lease stops this
     * mount one beat sooner (cetrafs_sb_lease_secs()) -- so no entry of
     * ours can be committed under a flag a peer has parked CLEAN -- on a
     * mount without CAW too, where the peer is a successor the gate
     * admitted once we looked dead. Re-derived at every attach,
     * which replays our own area first.
     */
    bool flag_dirty;
    /* The area's park_seq this session's entries belong to: read at
     * attach, advanced by our own park (cetrafs_node_journal_hdr_t). */
    u64 park_seq;
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
    /* One multi-slot batch at a time (cetrafs_journal_write_deferred()):
     * a batch waits for slots while holding some, which is safe only if
     * no other batch is doing the same -- single writers take one slot
     * and never wait while holding it. */
    struct mutex batch_mutex;
    /*
     * The last held-back batch's entries, written and waited for, whose
     * TARGETS have not been flushed yet: the entries stay live (busy, and
     * replayable) until the next batch's first flush -- issued after
     * those targets completed -- has run, and only then are they zeroed
     * (cetrafs_journal_drain_locked()). Under batch_mutex. Sized to the
     * journal's slots, as busy and stuck_lba are.
     */
    u64 *retire_slot;
    u64 *retire_lba;
    u64 retire_n;
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
static int cetrafs_journal_read_flag_seq(struct super_block *sb, u64 area_start, bool *out_dirty, u64 *out_seq)
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
    if (out_seq)
        *out_seq = cetrafs_le32(hdr->magic) == CETRAFS_NODE_JOURNAL_MAGIC ? cetrafs_le64(hdr->park_seq) : 0;
    brelse(bh);
    return 0;
}

static int cetrafs_journal_read_flag(struct super_block *sb, u64 area_start, bool *out_dirty)
{
    return cetrafs_journal_read_flag_seq(sb, area_start, out_dirty, NULL);
}

/*
 * The owner's own flag flips, by compare-and-write. DIRTY requires the
 * area CLEAN, unclaimed and still at the park_seq this session learned;
 * CLEAN (our unmount) requires it DIRTY at that park_seq, and parks it:
 * park_seq + 1. Either one finding anything else means a peer has
 * parked our area since -- it fenced us -- and the flip must not land:
 * a DIRTY landing over that park would make the next replay scan
 * entries of a session already settled (M10). A blind write queued past
 * the fence could not be refused; the device's compare can.
 */
struct cetrafs_journal_flag_ctx {
    bool dirty;
    u64 expect_seq;
    u64 new_seq; /* out */
};

static int cetrafs_journal_flag_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_journal_flag_ctx *ctx = priv;
    cetrafs_node_journal_hdr_t *hdr = image;
    bool magic = cetrafs_le32(hdr->magic) == CETRAFS_NODE_JOURNAL_MAGIC;
    u32 state = magic ? cetrafs_le32(hdr->state) : CETRAFS_NODE_JOURNAL_CLEAN;
    u32 owner = magic ? cetrafs_le32(hdr->replay_owner) : CETRAFS_NODE_ID_NONE;
    u64 seq = magic ? cetrafs_le64(hdr->park_seq) : 0;

    (void) len;
    if (!magic && cetrafs_le32(hdr->magic) != 0)
        return -EUCLEAN; /* neither zero-filled nor ours: not a flag block */
    if (seq != ctx->expect_seq || owner != CETRAFS_NODE_ID_NONE ||
        state != (ctx->dirty ? CETRAFS_NODE_JOURNAL_CLEAN : CETRAFS_NODE_JOURNAL_DIRTY))
        return -ESTALE;
    if (!magic) {
        memset(hdr, 0, len < sizeof(*hdr) ? len : sizeof(*hdr));
        hdr->magic = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_MAGIC);
    }
    hdr->state = cetrafs_cpu_to_le32(ctx->dirty ? CETRAFS_NODE_JOURNAL_DIRTY : CETRAFS_NODE_JOURNAL_CLEAN);
    hdr->replay_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE); /* 0 is a real node id -- be explicit */
    hdr->replay_incarnation = cetrafs_cpu_to_le32(0);
    ctx->new_seq = ctx->dirty ? seq : seq + 1;
    hdr->park_seq = cetrafs_cpu_to_le64(ctx->new_seq);
    return 0;
}

static int cetrafs_journal_write_flag(struct super_block *sb, struct cetrafs_journal *j, bool dirty)
{
    struct cetrafs_journal_flag_ctx ctx = {.dirty = dirty, .expect_seq = j->park_seq};
    int ret;

    /* The flag is the whole point of this block: committing entries
     * while the on-disk state still reads CLEAN means the next replay
     * of this area skips them, so a failed write here must reach the
     * caller. */
    ret = cetrafs_cas_record_nointr(sb, j->area_start, cetrafs_journal_flag_mutate, &ctx);
    if (ret > 0)
        ret = -ESTALE;
    if (ret == -ESTALE)
        pr_err("journal: our area at %llu was parked by a peer since this session began (park_seq %llu) -- "
               "refusing to mark it %s\n",
               (unsigned long long) j->area_start, (unsigned long long) j->park_seq, dirty ? "DIRTY" : "CLEAN");
    else if (ret)
        pr_err("journal: could not write the %s flag at %llu (%d)\n", dirty ? "DIRTY" : "CLEAN",
               (unsigned long long) j->area_start, ret);
    else
        j->park_seq = ctx.new_seq;
    return ret;
}

/*
 * A fence closes the fenced incarnation's journal session: a CLEAN area
 * is parked again (park_seq + 1), so a DIRTY flip it had queued to the
 * device past the fence miscompares and never lands, and an entry that
 * lands anyway is from before the park. A DIRTY area is left alone --
 * the replay that every reclaim runs next parks it when it is done.
 */
struct cetrafs_journal_fence_park_ctx {
    bool parked; /* out */
};

static int cetrafs_journal_fence_park_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_journal_fence_park_ctx *ctx = priv;
    cetrafs_node_journal_hdr_t *hdr = image;
    bool magic = cetrafs_le32(hdr->magic) == CETRAFS_NODE_JOURNAL_MAGIC;

    ctx->parked = false;
    if (!magic && cetrafs_le32(hdr->magic) != 0)
        return -EUCLEAN;
    if (magic && cetrafs_le32(hdr->state) == CETRAFS_NODE_JOURNAL_DIRTY)
        return 1; /* the replay parks it */
    if (!magic) {
        memset(hdr, 0, len < sizeof(*hdr) ? len : sizeof(*hdr));
        hdr->magic = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_MAGIC);
        hdr->state = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_CLEAN);
        hdr->replay_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
    }
    hdr->park_seq = cetrafs_cpu_to_le64(cetrafs_le64(hdr->park_seq) + 1);
    ctx->parked = true;
    return 0;
}

/* TEST ONLY: a fence leaves the fenced node's area as it was (the
 * control of tests/kernel/journal_park_stamp.sh). */
static bool cetrafs_journal_fence_park_skip;
cetrafs_test_param(journal_fence_park_skip, cetrafs_journal_fence_park_skip, bool, 0644);
MODULE_PARM_DESC(journal_fence_park_skip, "TEST ONLY: a fence does not park the fenced node's journal area");

int cetrafs_journal_fence_park(struct super_block *sb, u32 node_id)
{
    struct cetrafs_journal_fence_park_ctx ctx = {};
    u64 area_start, slots;
    int ret;

    if (cetrafs_journal_fence_park_skip)
        return 0;
    ret = cetrafs_journal_node_area(sb, node_id, &area_start, &slots);
    if (ret || !area_start)
        return ret; /* journaling off: nothing to park */
    ret = cetrafs_cas_record_nointr(sb, area_start, cetrafs_journal_fence_park_mutate, &ctx);
    if (ret < 0) {
        pr_err_ratelimited("journal: could not park fenced node %u's area (%d)\n", node_id, ret);
        return ret;
    }
    return 0;
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
    u32 steal_incarnation; /* claim: ... at the incarnation judged (F10) */
    u32 my_incarnation;    /* claim: stamped; release: old_only compares */
    bool old_only;         /* release: only an EARLIER incarnation's claim */
};

static int cetrafs_journal_claim_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_journal_claim_ctx *ctx = priv;
    cetrafs_node_journal_hdr_t *hdr = image;

    (void) len;

    if (cetrafs_le32(hdr->magic) != CETRAFS_NODE_JOURNAL_MAGIC)
        return -EEXIST; /* never written, or not ours to touch */

    if (ctx->release) {
        if (cetrafs_le32(hdr->replay_owner) != ctx->my_node_id)
            return 1; /* not ours any more -- nothing to hand back */
        if (ctx->old_only && cetrafs_le32(hdr->replay_incarnation) == ctx->my_incarnation)
            return 1; /* this mount's own replay's */
        hdr->replay_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
        hdr->replay_incarnation = cetrafs_cpu_to_le32(0);
        hdr->replay_claimed = cetrafs_cpu_to_le64(0);
        if (ctx->set_clean) {
            /* A park: entries still in the slots, or landing late, are
             * from before it (cetrafs_node_journal_hdr_t.park_seq). */
            hdr->state = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_CLEAN);
            hdr->park_seq = cetrafs_cpu_to_le64(cetrafs_le64(hdr->park_seq) + 1);
        }
        return 0;
    }

    if (cetrafs_le32(hdr->state) != CETRAFS_NODE_JOURNAL_DIRTY)
        return -EEXIST; /* someone replayed it out from under us */

    if (cetrafs_le32(hdr->replay_owner) != CETRAFS_NODE_ID_NONE && cetrafs_le32(hdr->replay_owner) != ctx->my_node_id &&
        !(ctx->steal && cetrafs_le32(hdr->replay_owner) == ctx->steal_from &&
          cetrafs_le32(hdr->replay_incarnation) == ctx->steal_incarnation))
        return -EEXIST; /* a live replayer owns it (or the judged one came back and re-took it) */

    hdr->replay_owner = cetrafs_cpu_to_le32(ctx->my_node_id);
    hdr->replay_incarnation = cetrafs_cpu_to_le32(ctx->my_incarnation);
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
    struct cetrafs_journal_claim_ctx ctx = {.my_node_id = my_node_id, .my_incarnation = cetrafs_sb_incarnation(sb)};
    struct buffer_head *bh;
    const cetrafs_node_journal_hdr_t *hdr;
    u32 owner, owner_inc;
    int ret;

    bh = cetrafs_bread_uncached_retry(sb, area_start);
    if (!bh)
        return -EIO;
    hdr = (const cetrafs_node_journal_hdr_t *) bh->b_data;
    owner = cetrafs_le32(hdr->replay_owner);
    owner_inc = cetrafs_le32(hdr->replay_incarnation);
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
        ctx.steal_incarnation = owner_inc;
        cetrafs_node_test_stall_before_swap();
    }

    ret = cetrafs_cas_record(sb, area_start, cetrafs_journal_claim_mutate, &ctx);
    /* The swap compares the replayer's incarnation as well as its row:
     * one that re-attached and claimed the area again is live, and the
     * claim answers -EEXIST, leaving the area to it (F10). */
    return ret;
}

/* TEST ONLY: fail the next replay-claim release, as a CAS the device
 * refused would (tests/kernel/journal_release_retry.sh). */
static bool cetrafs_journal_release_fail_once;
cetrafs_test_param(journal_release_fail_once, cetrafs_journal_release_fail_once, bool, 0644);
MODULE_PARM_DESC(journal_release_fail_once, "TEST ONLY: fail the next journal replay-claim release with -EIO");

/* TEST ONLY: attach leaves a failed release of our own area to the
 * heartbeat, as before B-5 (tests/kernel/journal_release_own_area.sh). */
static bool cetrafs_journal_attach_release_async;
cetrafs_test_param(journal_attach_release_async, cetrafs_journal_attach_release_async, bool, 0644);
MODULE_PARM_DESC(journal_attach_release_async, "TEST ONLY: a failed own-area release at attach is left to the heartbeat");

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
    mutex_init(&j->batch_mutex);
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
    kvfree(j->retire_slot);
    kvfree(j->retire_lba);
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
    struct cetrafs_journal_claim_ctx ctx = {
        .my_node_id = my_node_id,
        .release = true,
        .old_only = true,
        .my_incarnation = cetrafs_sb_incarnation(sb),
    };
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
    j->retire_slot = kvcalloc(j->slots, sizeof(*j->retire_slot), GFP_KERNEL);
    j->retire_lba = kvcalloc(j->slots, sizeof(*j->retire_lba), GFP_KERNEL);
    if (!j->busy || !j->stuck_lba || !j->retire_slot || !j->retire_lba) {
        kvfree(j->busy);
        kvfree(j->stuck_lba);
        kvfree(j->retire_slot);
        kvfree(j->retire_lba);
        j->busy = NULL;
        j->stuck_lba = NULL;
        j->retire_slot = NULL;
        j->retire_lba = NULL;
        j->area_start = 0;
        j->slots = 0;
        return -ENOMEM;
    }

    ret = cetrafs_journal_replay_node(sb, node_id, /*wait_for_claim=*/true);
    if (ret)
        return ret;
    /*
     * Our own area's release -- the swap that parks it CLEAN and drops
     * the replay claim -- may have failed and been queued for the
     * heartbeat. The park_seq read below is then the claimed one, and
     * when the heartbeat's retry lands the area is one park later: every
     * DIRTY flip of this session fails -ESTALE for the life of the mount,
     * creates, unlinks and every tree boundary with it, while the node
     * keeps beating (audit 2026-11-14 B-5). Retried here, a few times;
     * still pending, the mount fails rather than run like that.
     */
    if (node_id < 64 && !READ_ONCE(cetrafs_journal_attach_release_async)) {
        u32 my_node_id;
        int tries;

        if (cetrafs_sb_get_node_id(sb, &my_node_id))
            my_node_id = node_id;
        for (tries = 0; test_bit(node_id, j->rel_pending) && tries < 5; tries++) {
            msleep(200);
            mutex_lock(&j->rel_mutex);
            if (test_bit(node_id, j->rel_pending))
                cetrafs_journal_release_replay(sb, node_id, j->area_start, my_node_id,
                                               test_bit(node_id, j->rel_clean));
            mutex_unlock(&j->rel_mutex);
        }
        if (test_bit(node_id, j->rel_pending)) {
            pr_err("journal: our own area at %llu could not be parked after its replay -- refusing the mount\n",
                   (unsigned long long) j->area_start);
            return -EIO;
        }
    }
    {
        u64 area, all;

        /* Every slot the area has, not this mount's journal_slots_max. */
        ret = cetrafs_journal_node_area(sb, node_id, &area, &all);
        if (!ret && !cetrafs_journal_keep_leftovers)
            ret = cetrafs_journal_retire_leftovers(sb, area, all);
        if (ret)
            return ret;
    }

    /* class 55: replay runs before any writer of this journal exists. */
    j->flag_dirty = false; /* replay always ends with the flag clean */
    j->next_txn_id = 0;
    {
        bool dirty;

        /* The park this session's entries will belong to. */
        ret = cetrafs_journal_read_flag_seq(sb, j->area_start, &dirty, &j->park_seq);
        if (ret)
            return ret;
    }
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
 * eleven call sites, every one of which called cetrafs_bh_end_update(sb, )
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
/* TEST ONLY: redo without the owner check and without advancing the
 * owner's change stamp -- the behaviour before L9 (the control of
 * tests/kernel/journal_replay_owner.sh). */
/* TEST ONLY: pause between the owner check and the redo's last re-read,
 * and skip that re-read (the control) -- tests/kernel/journal_replay_owner_gap.sh. */
static unsigned int cetrafs_journal_owner_pause_ms;
cetrafs_test_param(journal_owner_pause_ms, cetrafs_journal_owner_pause_ms, uint, 0644);
MODULE_PARM_DESC(journal_owner_pause_ms, "TEST ONLY: pause after a redo's owner check");
static bool cetrafs_journal_no_last_read;
cetrafs_test_param(journal_no_last_read, cetrafs_journal_no_last_read, bool, 0644);
MODULE_PARM_DESC(journal_no_last_read, "TEST ONLY: redo without re-reading the target after the owner check");

static bool cetrafs_journal_ignore_owner;
cetrafs_test_param(journal_ignore_owner, cetrafs_journal_ignore_owner, bool, 0644);
MODULE_PARM_DESC(journal_ignore_owner, "test-only: replay neither checks an entry's owner nor advances its stamp");

/* TEST ONLY: the next N replay region checks answer -EINVAL after the
 * lookup accepted the target (tests/kernel/journal_replay_no_region.sh). */
static unsigned int cetrafs_journal_alloc_region_fail;
cetrafs_test_param(journal_alloc_region_fail, cetrafs_journal_alloc_region_fail, uint, 0644);
MODULE_PARM_DESC(journal_alloc_region_fail, "TEST ONLY: the next N journal replay region checks answer -EINVAL");

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
    cetrafs_bh_end_update(sb, jbh);
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
                                     u64 *out_slot, u64 *txn_id, bool *out_reused)
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
        int ret = cetrafs_journal_write_flag(sb, j, true);

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
    if (out_reused)
        *out_reused = reused;
    return 0;
}

/*
 * Fill an entry header -- the ONE place one is written, for the
 * single-block path and the deferred batch alike. The batch once filled
 * its own and missed a field added here (the park stamp): its entries
 * read as from another park and replay discarded them, a torn leaf left
 * unrepaired (CLAUDE.md rule 12). A field every entry needs goes here.
 */
static void cetrafs_journal_stamp_header(struct cetrafs_journal *j, struct buffer_head *hbh, u32 flags, u64 txn_id,
                                         u64 target_lba, u32 prev_crc, u32 payload_crc,
                                         struct cetrafs_journal_owner owner)
{
    cetrafs_journal_header_t *hdr = (cetrafs_journal_header_t *) hbh->b_data;

    memset(hbh->b_data, 0, CETRAFS_BLOCK_SIZE);
    hdr->magic = cetrafs_cpu_to_le32(CETRAFS_JOURNAL_MAGIC);
    hdr->flags = cetrafs_cpu_to_le32(flags);
    hdr->txn_id = cetrafs_cpu_to_le64(txn_id);
    hdr->target_lba = cetrafs_cpu_to_le64(target_lba);
    hdr->prev_checksum = cetrafs_cpu_to_le32(prev_crc);
    /* The session this entry belongs to: replay discards it once the
     * area has been parked since (cetrafs_node_journal_hdr_t). */
    hdr->park_seq = cetrafs_cpu_to_le64(READ_ONCE(j->park_seq));
    /* Whose block it is: replay requires it still to be theirs (L9). */
    hdr->owner_ino = cetrafs_cpu_to_le64(owner.ino);
    hdr->owner_generation = cetrafs_cpu_to_le64(owner.generation);
    hdr->payload_checksum = cetrafs_cpu_to_le32(payload_crc);
    hdr->header_checksum = cetrafs_cpu_to_le32(cetrafs_journal_header_crc(hbh->b_data));
}

/*
 * A directory-entry or xattr block (its tail magic): the namespace and
 * xattr operations that write one undo themselves when the write fails,
 * so a DEFINITE refusal of it -- a thin pool out of space -- fails that
 * operation with ENOSPC instead of stopping the mount (audit 2026-11-14
 * A-4, the part the user chose). Records, extent-tree blocks and bitmaps
 * still stop: their changes span several blocks.
 */
static bool cetrafs_journal_nospc_stops;
cetrafs_test_param(journal_nospc_stops, cetrafs_journal_nospc_stops, bool, 0644);
MODULE_PARM_DESC(journal_nospc_stops, "TEST ONLY: a refused dirent/xattr write stops the mount, as before A-4");

static atomic64_t cetrafs_journal_op_refusals = ATOMIC64_INIT(0);

u64 cetrafs_journal_op_refusal_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_op_refusals);
}

static bool cetrafs_journal_op_refusable(struct buffer_head *bh)
{
    if (READ_ONCE(cetrafs_journal_nospc_stops))
        return false;
    return cetrafs_blk_struct_ok_magic(bh, CETRAFS_DIRENT_TAIL_MAGIC) ||
           cetrafs_blk_struct_ok_magic(bh, CETRAFS_XATTR_TAIL_MAGIC);
}

static int cetrafs_journal_write_block_flags(struct super_block *sb, struct buffer_head *bh, u32 flags, u32 prev_crc,
                                             struct cetrafs_journal_owner owner)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);

    /* The device's word too, not only the clock's (F-8): one small read
     * beside the three cache flushes this write costs. */
    if (cetrafs_sb_fence_witnessed_f8(sb)) {
        /* Self-fenced: no metadata may be written at all. Abort rather
         * than end the update -- publishing a change this node is no
         * longer entitled to make is the whole thing being prevented. */
        cetrafs_bh_abort_update(bh);
        return -EIO;
    }

    u64 slot, txn_id, header_lba, payload_lba;
    struct buffer_head *pbh, *hbh;
    bool journaled = false;
    bool entry_refused = false; /* the device refused the entry write itself */
    /* A directory-entry or xattr block: an operation whose refused write
     * can fail cleanly (cetrafs_journal_op_refusable()). */
    bool op_block = cetrafs_journal_op_refusable(bh);
    int est[2] = {0, 0}; /* what the device answered the entry's payload and header */
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
        int tret = cetrafs_journal_take_slot(sb, j, bh->b_blocknr, false, &slot, &txn_id, NULL);

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
        cetrafs_blk_tail_settle(bh); /* a held-back block's last edit, if it left the tail stale */
        memcpy(pbh->b_data, bh->b_data, CETRAFS_BLOCK_SIZE);
        cetrafs_bh_end_update(sb, pbh);

        hbh = cetrafs_getblk_overwrite(sb, header_lba);
        if (!hbh) {
            brelse(pbh);
            goto journal_failed;
        }
        /* What the target held BEFORE this modification: replay compares
         * it against the device to prove nobody else has written the
         * block since (see cetrafs_journal_header_t). The payload CRC is
         * over the caller's buffer, which is the image just copied into
         * the payload block and cannot change meanwhile: it is locked. */
        cetrafs_journal_stamp_header(j, hbh, flags, txn_id, bh->b_blocknr, prev_crc,
                                     ~crc32c(~0U, bh->b_data, CETRAFS_BLOCK_SIZE), owner);
        cetrafs_bh_end_update(sb, hbh);

        {
            struct blk_plug plug;
            bool ok;

            /* PERF(9): both out together, one wait -- docs/PERFORMANCE.md.
             * Each with the device's own answer (A-4). */
            struct buffer_head *pair[2] = {pbh, hbh};

            (void) plug;
            cetrafs_write_bhs_status(sb, pair, 2, est);
            ok = !est[0] && !est[1] && !cetrafs_journal_fail_entry_write;
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

    cetrafs_bh_end_update(sb, bh);
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
        int werr = op_block ? cetrafs_sync_buffer_op_refusable(sb, bh) : cetrafs_sync_buffer(sb, bh);

        if (!werr && was_deferred)
            cetrafs_bh_deferred_unlist(sb, bh, false);
        if (cetrafs_refusal_definite(werr) && op_block) {
            /*
             * Refused before anything was written (A-4): the device still
             * holds the block's old image, and the operation fails with
             * ENOSPC rather than the mount. The entry -- durable, holding
             * the image that never landed -- must go first: a later replay
             * would otherwise redo an operation its caller was told
             * failed. Retired, or the mount stops as it always did; then
             * the cached after-image is forgotten, so the next read is the
             * device's.
             */
            if (journaled) {
                mutex_lock(&j->lock);
                if (cetrafs_journal_zero_header(sb, header_lba)) {
                    cetrafs_journal_hold_slot(j, slot, bh->b_blocknr);
                    mutex_unlock(&j->lock);
                    cetrafs_sb_fatal(sb, "journal: block %llu refused (%d) and its entry could not be retired",
                                     (unsigned long long) bh->b_blocknr, werr);
                    return -EIO;
                }
                clear_bit(slot, j->busy);
                mutex_unlock(&j->lock);
                wake_up(&j->slot_wq);
            }
            cetrafs_forget_block(sb, bh->b_blocknr);
            atomic64_inc(&cetrafs_journal_op_refusals);
            pr_warn_ratelimited("%s: the device refused the write of %s block %llu (%d, no space) -- the operation "
                                "fails with ENOSPC; the mount runs on\n",
                                sb->s_id, cetrafs_block_role(sb, bh->b_blocknr), (unsigned long long) bh->b_blocknr,
                                werr);
            return -ENOSPC;
        }
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
    /* The entry refused before any of it was written -- or with its
     * header refused, which is what makes an entry -- for an operation
     * that can fail cleanly (A-4): nothing to retire, ENOSPC, the mount
     * lives. A payload refused under a header that landed still needs
     * the header retired below first. */
    if (entry_refused && op_block && !READ_ONCE(cetrafs_journal_nospc_stops) &&
        (est[0] || est[1]) && (!est[0] || cetrafs_refusal_definite(est[0])) &&
        (!est[1] || cetrafs_refusal_definite(est[1]))) {
        cetrafs_bh_abort_update(bh);
        mutex_lock(&j->lock);
        if (est[1] || !cetrafs_journal_zero_header(sb, header_lba)) {
            clear_bit(slot, j->busy);
            mutex_unlock(&j->lock);
            wake_up(&j->slot_wq);
            atomic64_inc(&cetrafs_journal_op_refusals);
            pr_warn_ratelimited("%s: the device refused the journal entry for block %llu (no space) -- the "
                                "operation fails with ENOSPC; the mount runs on\n",
                                sb->s_id, (unsigned long long) bh->b_blocknr);
            return -ENOSPC;
        }
        cetrafs_journal_hold_slot(j, slot, bh->b_blocknr);
        mutex_unlock(&j->lock);
        cetrafs_sb_fatal(sb, "journal: the entry for block %llu was refused and could not be retired",
                         (unsigned long long) bh->b_blocknr);
        return -EIO;
    }
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

/* Held-back tree batches written, and the device cache flushes they
 * issued (procfs deferred_batches / deferred_batch_flushes). A batch's
 * flushes are what a write into a preallocated image pays for; the
 * flushes per batch are the number tests/kernel/deferred_batch_flushes.sh
 * reads. */
static atomic64_t cetrafs_batch_count = ATOMIC64_INIT(0);
static atomic64_t cetrafs_batch_flush_count = ATOMIC64_INIT(0);

u64 cetrafs_deferred_batch_count(void)
{
    return (u64) atomic64_read(&cetrafs_batch_count);
}

u64 cetrafs_deferred_batch_flush_count(void)
{
    return (u64) atomic64_read(&cetrafs_batch_flush_count);
}

static int cetrafs_batch_flush(struct super_block *sb)
{
    atomic64_inc(&cetrafs_batch_flush_count);
    return blkdev_issue_flush(sb->s_bdev);
}

/* TEST ONLY: a held-back batch issues the flush after its targets, as it
 * did before the flush moved into the next batch's step 0 (the negative
 * control of tests/kernel/deferred_batch_flushes.sh). */
static bool cetrafs_batch_after_flush;
cetrafs_test_param(deferred_batch_after_flush, cetrafs_batch_after_flush, bool, 0644);
MODULE_PARM_DESC(deferred_batch_after_flush, "TEST ONLY: a held-back tree batch flushes after its targets too");

/* TEST ONLY: every batch of held-back tree blocks fails to write, cap
 * flushes and boundaries alike, as a device refusing the journal's
 * writes would (tests/kernel/deferred_room.sh). An oversized batch is
 * still refused as that first. */
static bool cetrafs_journal_batch_fail;
cetrafs_test_param(journal_batch_fail, cetrafs_journal_batch_fail, bool, 0644);
MODULE_PARM_DESC(journal_batch_fail, "TEST ONLY: every held-back tree-block batch write fails");

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

/* TEST ONLY: a held-back batch spends its entries right after their
 * targets, with no flush in between -- the order the retiring flush
 * exists to forbid. The negative control of tests/crash/batch_retire_order.sh. */
static bool cetrafs_journal_retire_early;
cetrafs_test_param(journal_batch_retire_early, cetrafs_journal_retire_early, bool, 0644);
MODULE_PARM_DESC(journal_batch_retire_early, "TEST ONLY: a held-back batch spends its entries before its targets are flushed");

#define CETRAFS_RETIRE_CHUNK 16

/*
 * Spend the retiring entries of the last batch: zero their headers, in
 * chunks of one write round each, and give their slots back. A header
 * that will not zero is held, live for replay. Called with batch_mutex
 * held, and only after a cache flush that was issued after those
 * batches' targets completed -- so a zeroed entry never outlives a
 * target that is still volatile.
 */
static void cetrafs_journal_drain_locked(struct super_block *sb, struct cetrafs_journal *j)
{
    bool fenced = cetrafs_sb_is_fenced(sb);
    unsigned int base;

    for (base = 0; base < j->retire_n; base += CETRAFS_RETIRE_CHUNK) {
        unsigned int m = min_t(unsigned int, j->retire_n - base, CETRAFS_RETIRE_CHUNK);
        struct buffer_head *hb[CETRAFS_RETIRE_CHUNK] = {NULL};
        int zerr[CETRAFS_RETIRE_CHUNK];
        struct blk_plug plug;
        unsigned int i;

        blk_start_plug(&plug);
        for (i = 0; i < m; i++) {
            if (fenced)
                continue;
            hb[i] = cetrafs_getblk_overwrite(sb, cetrafs_journal_header_lba(j, j->retire_slot[base + i]));
            if (!hb[i])
                continue;
            memset(hb[i]->b_data, 0, CETRAFS_BLOCK_SIZE);
            cetrafs_bh_end_update(sb, hb[i]);
            cetrafs_write_pending_buffer(sb, hb[i], REQ_SYNC);
        }
        blk_finish_plug(&plug);
        for (i = 0; i < m; i++) {
            zerr[i] = -EIO;
            if (hb[i]) {
                zerr[i] = cetrafs_wait_meta_write(sb, hb[i]);
                brelse(hb[i]);
            }
        }
        mutex_lock(&j->lock);
        for (i = 0; i < m; i++) {
            u64 slot = j->retire_slot[base + i];

            if (zerr[i]) /* live and harmless: see the single write */
                cetrafs_journal_hold_slot(j, slot, j->retire_lba[base + i]);
            else
                clear_bit(slot, j->busy);
        }
        mutex_unlock(&j->lock);
    }
    j->retire_n = 0;
    wake_up(&j->slot_wq);
}

/*
 * The sync and unmount point (cetrafs_deferred_flush_all()): flush, then
 * spend what the last batch left live. Nothing else needs it -- the next
 * batch does this itself, and a crash replays the live entries.
 */
int cetrafs_journal_drain_retiring(struct super_block *sb)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);
    int ret = 0;

    if (!j || !j->area_start)
        return 0;
    mutex_lock(&j->batch_mutex);
    if (j->retire_n) {
        ret = blkdev_issue_flush(sb->s_bdev);
        if (!ret)
            cetrafs_journal_drain_locked(sb, j);
    }
    mutex_unlock(&j->batch_mutex);
    return ret;
}

/* TEST ONLY: a hand-back leaves this node's live entries for its blocks
 * as they are -- the control of tests/kernel/release_journal_settled.sh. */
static bool cetrafs_release_journal_unsettled;
cetrafs_test_param(release_journal_unsettled, cetrafs_release_journal_unsettled, bool, 0644);
MODULE_PARM_DESC(release_journal_unsettled, "TEST ONLY: hand back blocks with live journal entries for them");

/* Hand-backs that spent the last batch's entries first (procfs info). */
static atomic64_t cetrafs_release_journal_drains = ATOMIC64_INIT(0);

u64 cetrafs_release_journal_drain_count(void)
{
    return (u64) atomic64_read(&cetrafs_release_journal_drains);
}

static bool cetrafs_lba_in(u64 lba, u64 first, u64 count)
{
    return lba >= first && lba - first < count;
}

/*
 * Before blocks [first, first + count) leave this node -- a Block Group
 * handed back, alone or with its Zone Group: no entry of ours may stay
 * live for one of them.
 *
 * A peer's replay of our journal is safe because no peer reuses this
 * node's blocks before replaying it: a reused block is the one redo the
 * prev_checksum judge cannot refuse when the peer's own write of it is
 * in flight (torn, it reads as "ours, torn by the crash"). A hand-back
 * is exactly where a peer starts reusing our blocks with no replay in
 * between, and a held-back batch's entries stay live after the batch
 * completed -- for a tree block of a file deleted since, in a group that
 * is now empty. So the last batch's retiring entries are spent here as
 * at a sync (flush, then zero), when any of them names the range; and a
 * HELD entry for a block in it (its zero or its target write failed)
 * keeps the range, as does a hold that names no block, and a batch in
 * progress (batch_mutex busy: it may be retiring entries right now).
 *
 * Returns 0 when nothing of ours is live for the range, -EBUSY to keep
 * it for a later pass, or the flush's error.
 */
int cetrafs_journal_settle_range(struct super_block *sb, u64 first, u64 count)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);
    u64 i, named = 0;
    bool hit = false;
    int ret = 0;

    if (!j || !j->area_start || READ_ONCE(cetrafs_release_journal_unsettled))
        return 0;
    if (!mutex_trylock(&j->batch_mutex))
        return -EBUSY;
    for (i = 0; i < j->retire_n && !hit; i++)
        hit = cetrafs_lba_in(j->retire_lba[i], first, count);
    if (hit) {
        ret = blkdev_issue_flush(sb->s_bdev);
        if (!ret) {
            cetrafs_journal_drain_locked(sb, j);
            atomic64_inc(&cetrafs_release_journal_drains);
        }
    }
    if (!ret) {
        mutex_lock(&j->lock);
        for (i = 0; i < j->slots && !ret; i++) {
            if (!j->stuck_lba[i])
                continue;
            named++;
            if (cetrafs_lba_in(j->stuck_lba[i], first, count))
                ret = -EBUSY;
        }
        if (j->held > named)
            ret = -EBUSY; /* a hold that names no block: it could be any */
        mutex_unlock(&j->lock);
    }
    mutex_unlock(&j->batch_mutex);
    return ret;
}

/* A whole deferred batch: k entries in k slots already taken. */
static int cetrafs_journal_batch_chunk(struct super_block *sb, struct cetrafs_journal *j,
                                       struct buffer_head **bhs, const struct cetrafs_journal_owner *owners,
                                       const u32 *disk_crc, unsigned int k,
                                       const u64 *slots, const u64 *txn, bool *written, u32 *wcrc,
                                       struct buffer_head **pb, struct buffer_head **hb)
{
    unsigned int i, nw = 0;
    bool ok = true;
    int ret = 0, ferr;

    /* 1. Every entry: payload and header, all out together, waited for
     * once. Each payload is the block's current image, copied under its
     * lock; nothing modifies it meanwhile (the caller's invalidate_lock). */
    for (i = 0; i < k; i++) {
        u64 hlba = cetrafs_journal_header_lba(j, slots[i]);
        u32 pcrc;

        pb[i] = cetrafs_getblk_overwrite(sb, hlba + 1);
        hb[i] = pb[i] ? cetrafs_getblk_overwrite(sb, hlba) : NULL;
        if (!pb[i] || !hb[i]) {
            if (pb[i])
                cetrafs_bh_abort_update(pb[i]);
            ok = false;
            break;
        }
        cetrafs_bh_copy_settled(bhs[i], pb[i]->b_data);
        pcrc = ~crc32c(~0U, pb[i]->b_data, CETRAFS_BLOCK_SIZE);
        cetrafs_bh_end_update(sb, pb[i]);

        /* prev: the DEVICE's image, recorded when the block was first held
         * back -- not the in-core one before the last edit, which never
         * reached the device and which a replay would never find. */
        cetrafs_journal_stamp_header(j, hb[i], CETRAFS_JRNL_F_GUARDED, txn[i], bhs[i]->b_blocknr, disk_crc[i], pcrc,
                                     owners[i]);
        cetrafs_bh_end_update(sb, hb[i]);
    }
    if (ok) {
        struct blk_plug plug;

        blk_start_plug(&plug);
        for (i = 0; i < k; i++) {
            cetrafs_write_pending_buffer(sb, pb[i], REQ_SYNC);
            cetrafs_write_pending_buffer(sb, hb[i], REQ_SYNC);
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
    ferr = cetrafs_batch_flush(sb);
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
    /* 4. The targets: all in flight at once, then waited for. Nothing
     * orders them among themselves -- the flushes either side do the
     * ordering -- and one at a time was a device round trip per block
     * of the batch, the cost of a write into preallocated space. 'hb'
     * (released in 1.) carries which ones were submitted. */
    {
        struct blk_plug plug;

        blk_start_plug(&plug);
        for (i = 0; i < k; i++) {
            int sret = cetrafs_submit_deferred_target(sb, bhs[i], &wcrc[i]);

            hb[i] = sret == 0 ? bhs[i] : NULL;
            pb[i] = ERR_PTR(sret > 0 ? 0 : sret); /* the result when not submitted */
        }
        blk_finish_plug(&plug);
    }
    for (i = 0; i < k; i++) {
        int werr = hb[i] ? cetrafs_wait_deferred_target(sb, bhs[i]) : (int) PTR_ERR(pb[i]);

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

    if (!nw)
        return ret;

    /* Retiring: the targets are written and waited for, and their entries
     * are spent only after a cache flush issued after this point. The
     * next batch's first flush does that (cetrafs_journal_write_deferred(),
     * cetrafs_journal_drain_locked()); until then the entries stay busy,
     * so a crash replays them and a target that landed is skipped
     * (judge: LANDED). A batch too large to keep its entries past itself
     * (over half the journal, which the single writers must still get
     * slots from) and the controls below flush now, as before. */
    {
        bool now = READ_ONCE(cetrafs_batch_after_flush) || k > j->slots / 2;

        if (now) {
            /* 4. The targets on the platter before their entries are spent. */
            ferr = cetrafs_batch_flush(sb);
            if (ferr) {
                cetrafs_sb_fatal(sb, "journal: cache flush after a batch of %u tree-block writes failed (%d)", nw,
                                 ferr);
                mutex_lock(&j->lock);
                for (i = 0; i < k; i++)
                    if (written[i])
                        cetrafs_journal_hold_slot(j, slots[i], bhs[i]->b_blocknr);
                mutex_unlock(&j->lock);
                for (i = 0; i < k; i++)
                    written[i] = false; /* not shown durable: stays held back */
                return ferr;
            }
        }
        for (i = 0; i < k; i++) {
            if (!written[i])
                continue;
            j->retire_slot[j->retire_n] = slots[i];
            j->retire_lba[j->retire_n] = bhs[i]->b_blocknr;
            j->retire_n++;
        }
        if (!now && !READ_ONCE(cetrafs_journal_retire_early))
            return ret;
        /* The consume now: after the flush above, or (the control) with
         * none at all -- the order a crash must not be allowed to see. */
        cetrafs_journal_drain_locked(sb, j);
    }
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
 *  4. Nothing flushes here. The entries stay live -- busy, replayable --
 *     until the NEXT batch's step 0, whose flush is issued after these
 *     targets completed; then they are zeroed (cetrafs_journal_drain_locked()).
 *     A replay meeting a target that landed finds it LANDED and skips it,
 *     so a crash anywhere in between is the redo it always was. The
 *     sync and unmount points spend what is left (cetrafs_journal_drain_retiring()).
 *     A batch over half the journal, and the controls, flush and spend
 *     at once instead, as before.
 *
 * Two flushes per boundary in steady state (steps 0 and 2), whatever the
 * number of blocks -- not per block, which is what made per-write
 * journaling unusable. ONE batch,
 * every slot taken before any entry is written
 * (cetrafs_journal_take_batch()), so every entry is durable before any
 * target: a boundary is atomic as a whole. It used to go in chunks of
 * 16, atomic only within each, and a split leaf's destination could
 * land a chunk ahead of its source -- which every split of a full leaf
 * then paid a whole extra batch to prevent
 * (cetrafs_convert_source_durable()). A batch larger than the journal
 * is refused, never split: leafdefer.c keeps an inode's set under half
 * of it.
 *
 * The caller guarantees nobody modifies the blocks meanwhile. written[i]
 * says which reached the device; the rest stay held back for a retry.
 * mkfs -J 0 has no journal: step 0, then the targets in place.
 */
/* Give back the first k slots of a batch that will not be written: a
 * kept entry's slot it had taken over is held again, as its entry is
 * still live on the device (cetrafs_journal_untake_kept()). */
static void cetrafs_journal_untake_batch(struct cetrafs_journal *j, struct buffer_head **bhs, const u64 *slots,
                                         const bool *reused, unsigned int k)
{
    unsigned int i;

    if (!k)
        return;
    mutex_lock(&j->lock);
    for (i = 0; i < k; i++) {
        clear_bit(slots[i], j->busy);
        cetrafs_journal_untake_kept(j, slots[i], bhs[i]->b_blocknr, reused[i]);
    }
    mutex_unlock(&j->lock);
    wake_up(&j->slot_wq);
}

/* Slots a batch could ever get: all but those held by kept entries it
 * cannot take over -- a kept entry of one of its own blocks is taken
 * over by that block's new entry (cetrafs_journal_take_slot()); one of
 * another block, or kept on purpose, is not. j->lock held. */
static u64 cetrafs_journal_batch_room(struct cetrafs_journal *j, struct buffer_head **bhs, unsigned int n)
{
    u64 slot, ours = 0;
    unsigned int i;

    if (!j->held)
        return j->slots;
    for (slot = 0; slot < j->slots; slot++) {
        if (!j->stuck_lba[slot])
            continue;
        for (i = 0; i < n; i++)
            if (bhs[i]->b_blocknr == j->stuck_lba[slot]) {
                ours++;
                break;
            }
    }
    return j->slots - (j->held - min_t(u64, ours, j->held));
}

/*
 * Take a slot for every block of a batch, before any entry is written --
 * so all of them are durable before any target, however many there are:
 * the atomicity the old 16-entry chunks lacked across chunks. Only this
 * batch takes several slots (batch_mutex), so waiting for one while
 * holding others cannot deadlock against another batch; single writers
 * hold one and never wait. What can still stop it is a journal whose
 * slots are held by kept entries of OTHER blocks: checked before each
 * wait, and the batch refused (-EIO) rather than waiting for slots that
 * will not come. *taken says how many it holds on failure.
 */
/* TEST ONLY: a batch waiting for a slot gives up on a fatal signal, as
 * it once did -- the control of tests/kernel/close_killed_slots.sh. */
static bool cetrafs_journal_batch_eintr;
cetrafs_test_param(journal_batch_eintr, cetrafs_journal_batch_eintr, bool, 0644);
MODULE_PARM_DESC(journal_batch_eintr, "TEST ONLY: a batch waiting for journal slots fails -EINTR on a fatal signal");

/* TEST ONLY: the next batch finds every slot in flight for this many ms
 * (one-shot) -- tests/kernel/close_killed_slots.sh. */
static unsigned int cetrafs_journal_batch_noslot_ms;
cetrafs_test_param(journal_batch_noslot_ms, cetrafs_journal_batch_noslot_ms, uint, 0644);
MODULE_PARM_DESC(journal_batch_noslot_ms, "TEST ONLY: the next tree-block batch finds no free journal slot for N ms");

static int cetrafs_journal_take_batch(struct super_block *sb, struct cetrafs_journal *j, struct buffer_head **bhs,
                                      unsigned int n, u64 *slots, u64 *txn, bool *reused, unsigned int *taken)
{
    unsigned int k = 0;
    unsigned int noslot_ms = READ_ONCE(cetrafs_journal_batch_noslot_ms) ? xchg(&cetrafs_journal_batch_noslot_ms, 0) : 0;
    unsigned long noslot_until = jiffies + msecs_to_jiffies(noslot_ms);

    *taken = 0;
    while (k < n) {
        u64 room;
        int t = noslot_ms && time_before(jiffies, noslot_until) /* test-only; see the parameter */
                    ? -EAGAIN
                    : cetrafs_journal_take_slot(sb, j, bhs[k]->b_blocknr, true, &slots[k], &txn[k], &reused[k]);

        if (!t) {
            *taken = ++k;
            continue;
        }
        if (t != -EAGAIN)
            return t;
        mutex_lock(&j->lock);
        room = cetrafs_journal_batch_room(j, bhs, n);
        mutex_unlock(&j->lock);
        if (room < n) {
            pr_err_ratelimited("journal: a batch of %u tree blocks cannot get its slots -- %llu of %llu are kept "
                               "by failed writes of other blocks; refused\n",
                               n, (unsigned long long) (j->slots - room), (unsigned long long) j->slots);
            return -EIO;
        }
        /* Every other slot is in flight with a single writer, which
         * holds no lock we hold and gives it back. Bounded wait so a
         * slot kept meanwhile is re-checked above. Not cut short by a
         * fatal signal: a killed writer's close is one of the callers,
         * and failing it there kept the file locked until the
         * heartbeat retried the release -- the VM image a host killed
         * stayed unopenable elsewhere for an interval. The wait ends
         * when an in-flight write does. */
        if (READ_ONCE(cetrafs_journal_batch_eintr) && fatal_signal_pending(current))
            return -EINTR; /* test-only; see the parameter */
        wait_event_timeout(j->slot_wq, cetrafs_journal_slot_or_none(j), HZ / 10);
    }
    return 0;
}

/* The most blocks one batch can carry: every slot of this node's area.
 * 0 with no journal (mkfs -J 0), where nothing is atomic. */
unsigned int cetrafs_journal_batch_capacity(struct super_block *sb)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);

    return (j && j->area_start) ? (unsigned int) min_t(u64, j->slots, UINT_MAX) : 0;
}

/* TEST ONLY: a deferred batch skips step 0's cache flush -- the negative
 * control for tests/crash/leaf_batch_order.sh. */
static bool cetrafs_journal_batch_skip_flush;
cetrafs_test_param(journal_batch_skip_flush, cetrafs_journal_batch_skip_flush, bool, 0644);
MODULE_PARM_DESC(journal_batch_skip_flush, "TEST ONLY: a held-back leaf batch does not flush the cache first");

int cetrafs_journal_write_deferred(struct super_block *sb, struct buffer_head **bhs,
                                   const struct cetrafs_journal_owner *owners, const u32 *disk_crc, unsigned int n,
                                   bool *written, u32 *wcrc)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);
    unsigned int i;
    int ret;

    for (i = 0; i < n; i++)
        written[i] = false;
    if (!n)
        return 0;
    if (cetrafs_sb_fence_witnessed_f8(sb)) /* the device's word, not only the clock's (F-8) */
        return -EIO;
    atomic64_inc(&cetrafs_batch_count);

    if (!j || !j->area_start) {
        ret = cetrafs_alloc_flush_bitmaps(sb);
        if (ret)
            return ret;
        ret = READ_ONCE(cetrafs_journal_batch_skip_flush) ? 0 : cetrafs_batch_flush(sb);
        if (ret)
            return ret; /* nothing written: the blocks stay held back */
        for (i = 0; i < n; i++) {
            int werr = cetrafs_deferred_write_target(sb, bhs[i], &wcrc[i]);

            if (!werr)
                written[i] = true;
            else if (!ret)
                ret = werr;
        }
        return ret;
    }

    if (n > j->slots) {
        /* Cannot be one batch: the cap that keeps an inode's held-back
         * set under half the journal (cetrafs_deferred_capped()) did not
         * hold. Refused rather than split -- a split batch is not atomic,
         * and a split leaf's destination could land without its source
         * (cetrafs_convert_source_durable()). The blocks stay held back. */
        pr_err_ratelimited("journal: a batch of %u tree blocks does not fit the journal's %llu slots -- refused\n",
                           n, (unsigned long long) j->slots);
        return -EIO;
    }
    if (READ_ONCE(cetrafs_journal_batch_fail))
        return -EIO; /* test-only; see the parameter */
    {
        u64 *slots = kvmalloc_array(n, sizeof(*slots), GFP_NOFS);
        u64 *txn = kvmalloc_array(n, sizeof(*txn), GFP_NOFS);
        bool *reused = kvcalloc(n, sizeof(*reused), GFP_NOFS);
        struct buffer_head **pb = kvcalloc(n, sizeof(*pb), GFP_NOFS);
        struct buffer_head **hb = kvcalloc(n, sizeof(*hb), GFP_NOFS);

        ret = slots && txn && reused && pb && hb ? 0 : -ENOMEM;
        if (!ret) {
            unsigned int k = 0;

            mutex_lock(&j->batch_mutex);
            /* 0. What the blocks name reaches the device first: the
             * allocation bits, and the data written back so far (a
             * leaf marking a block written must never be durable ahead
             * of that block's data or bit -- C2). The same flush is what
             * makes the PREVIOUS batch's targets durable, so its entries
             * are spent right after it (cetrafs_journal_drain_locked()). */
            ret = cetrafs_alloc_flush_bitmaps(sb);
            if (!ret)
                ret = READ_ONCE(cetrafs_journal_batch_skip_flush) ? 0 : cetrafs_batch_flush(sb);
            if (!ret)
                cetrafs_journal_drain_locked(sb, j);
            if (!ret) {
                ret = cetrafs_journal_take_batch(sb, j, bhs, n, slots, txn, reused, &k);
                if (ret)
                    cetrafs_journal_untake_batch(j, bhs, slots, reused, k);
                else
                    ret = cetrafs_journal_batch_chunk(sb, j, bhs, owners, disk_crc, n, slots, txn, written, wcrc,
                                                      pb, hb);
            }
            mutex_unlock(&j->batch_mutex);
        }
        kvfree(slots);
        kvfree(txn);
        kvfree(reused);
        kvfree(pb);
        kvfree(hb);
        return ret;
    }
}

/*
 * Journal a block that was READ and then modified. prev_crc is the CRC32C
 * of the image as it stood before the modification -- take it from
 * cetrafs_bh_begin_update_crc(), which locks the buffer and snapshots it
 * in one call so the two cannot drift apart.
 */
int cetrafs_journal_write_block(struct super_block *sb, struct cetrafs_journal_owner owner, struct buffer_head *bh,
                                u32 prev_crc)
{
    return cetrafs_journal_write_block_flags(sb, bh, CETRAFS_JRNL_F_GUARDED, prev_crc, owner);
}

struct cetrafs_journal_owner cetrafs_journal_owner_of(struct inode *inode)
{
    struct cetrafs_journal_owner o = {.ino = inode->i_ino, .generation = cetrafs_inode_get_generation(inode)};

    return o;
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

    cetrafs_bh_end_update(sb, bh);
    /* The result from the write itself, never from BH_Uptodate -- a
     * forced-fresh reader may clear that concurrently (ioutil.c). A
     * definite ENOSPC is the operation's, not the mount's: nothing
     * references this block yet (cetrafs_sync_new_buffer()). */
    return cetrafs_sync_new_buffer(sb, bh);
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
        /* class 55: cleared after the write landed, under j->lock. */
        else if (cetrafs_journal_write_flag(sb, j, false) == 0)
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
    bool before_park; /* from a session the area was parked after */
    bool undecided; /* the scan could not judge it: kept, never applied */
    u64 owner_ino, owner_generation; /* whose block the target is (L9) */
    bool live_kept; /* kept only because a live node has its file open */
};

/* Replay's verdict on each entry, per replay call. */
enum {
    CETRAFS_JR_PENDING = 0,
    CETRAFS_JR_DONE,     /* redone or refused, and consumed */
    CETRAFS_JR_KEPT,     /* undecidable this time: kept, the area stays DIRTY */
    CETRAFS_JR_DEFERRED, /* waits for the next pass */
};

/* TEST ONLY: an undecidable entry aborts the whole area, as before
 * (tests/kernel/journal_replay_kept.sh's negative control). */
static bool cetrafs_journal_kept_aborts;
cetrafs_test_param(journal_kept_aborts, cetrafs_journal_kept_aborts, bool, 0644);
MODULE_PARM_DESC(journal_kept_aborts, "TEST ONLY: one undecidable replay entry aborts the whole area (the old behaviour)");

/* TEST ONLY: judge an entry although an older entry for the same block
 * waits or is kept (journal_replay_kept.sh's other control). */
static bool cetrafs_journal_unordered;
cetrafs_test_param(journal_unordered, cetrafs_journal_unordered, bool, 0644);
MODULE_PARM_DESC(journal_unordered, "TEST ONLY: judge a replay entry past an older undecided one for the same block");

/*
 * Does an OLDER entry for the same block still wait (DEFERRED) or stay
 * undecided (KEPT)? Then this one may not be judged yet: the guard
 * judges an entry against the block as it is NOW, and the block does not
 * yet hold the image the older entry would put there -- the newer entry
 * reads CHANGED, is consumed unapplied, and when the older one is redone
 * the block is left at the older image, the newer write lost for good.
 * Entries are sorted by txn id, so "older" is "earlier in the array".
 */
static int cetrafs_journal_blocked_by_older(const struct cetrafs_journal_replay_entry *entries, const u8 *st,
                                            u64 s)
{
    u64 j;

    if (READ_ONCE(cetrafs_journal_unordered))
        return CETRAFS_JR_PENDING;
    for (j = s; j-- > 0;) {
        if (entries[j].target_lba != entries[s].target_lba)
            continue;
        if (st[j] == CETRAFS_JR_KEPT || st[j] == CETRAFS_JR_DEFERRED)
            return st[j];
    }
    return CETRAFS_JR_PENDING;
}

/*
 * Is the entry's target still a metadata block of the inode it was
 * written for? Read fresh, immediately before the redo (rule 15). 1:
 * yes; 0: no -- the owner is gone, reused, or no longer references the
 * block, which has been freed and reallocated since with bytes that
 * happen to pass the guard; -EIO: its record or tree could not be read.
 * '*is_dir' is set whenever the record was read.
 */
/* TEST ONLY: the next N owner-record reads fail as an unreadable record
 * would (tests/kernel/journal_replay_owner_unreadable.sh). */
static unsigned int cetrafs_journal_owner_read_fail;
cetrafs_test_param(journal_owner_read_fail, cetrafs_journal_owner_read_fail, uint, 0644);
MODULE_PARM_DESC(journal_owner_read_fail, "TEST ONLY: fail the next N journal replay owner-record reads with -EIO");

/* TEST ONLY: the old fail-open verdict -- an owner that cannot be read
 * leaves the entry to the guard alone. The control for the suite above. */
static bool cetrafs_journal_owner_fail_open;
cetrafs_test_param(journal_owner_fail_open, cetrafs_journal_owner_fail_open, bool, 0644);
MODULE_PARM_DESC(journal_owner_fail_open, "TEST ONLY: judge an unreadable owner by the guard alone (the old behaviour)");

static int cetrafs_journal_owner_holds(struct super_block *sb, const struct cetrafs_journal_replay_entry *e,
                                       bool *is_dir)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    cetrafs_inode_t raw;
    bool held = false;
    int ret;

    *is_dir = false;
    if (!e->owner_ino || !raw_sb || e->owner_ino > le32_to_cpu(raw_sb->inodes_count))
        return 0; /* no writer of this format names no owner */
    cetrafs_invalidate_raw_inode(sb, e->owner_ino);
    if (READ_ONCE(cetrafs_journal_owner_read_fail)) {
        WRITE_ONCE(cetrafs_journal_owner_read_fail, cetrafs_journal_owner_read_fail - 1);
        return -EIO; /* TEST ONLY */
    }
    ret = cetrafs_read_raw_inode(sb, e->owner_ino, &raw);
    if (ret)
        return -EIO;
    *is_dir = S_ISDIR(cetrafs_le32(raw.mode));
    if (cetrafs_le64(raw.generation) != e->owner_generation)
        return 0; /* the number belongs to another file now */
    ret = cetrafs_raw_inode_holds_meta_block(sb, &raw, e->target_lba, &held);
    if (ret)
        return -EIO;
    return held ? 1 : 0;
}

/* TEST ONLY: redo an entry whatever peer has its file open, as before
 * (tests/kernel/journal_replay_live_opener.sh). */
static bool cetrafs_journal_live_opener_off;
cetrafs_test_param(journal_live_opener_off, cetrafs_journal_live_opener_off, bool, 0644);
MODULE_PARM_DESC(journal_live_opener_off, "TEST ONLY: replay redoes an entry whose file a live peer has open");

/*
 * nofilelock: may this entry's redo run now? Its target is a block of a
 * regular file, and under nofilelock no lock stops a live node that has
 * the file open from writing that block -- between replay's last read
 * of it and the redo landing, the dead node's older image would land
 * on top of the live write (audit 2026-11-15 M-20). So:
 *
 *   - a LIVE foreign node (not the dead one, not stale) has it open:
 *     1, kept -- the area stays dirty, and the redo waits for that
 *     opener to close (or for its own replay of it, below);
 *   - THIS node has it open: its writers mutate the tree under
 *     invalidate_lock, held exclusively here across the last read and
 *     the redo (*out, to be released by the caller); taken only by
 *     trylock -- replay runs from paths holding other locks -- and kept
 *     for the next attempt when busy;
 *   - nobody live: 0, redo as before.
 *
 * Any read that fails is -EIO: kept, never guessed.
 */
static int cetrafs_journal_live_opener(struct super_block *sb, const struct cetrafs_journal_replay_entry *e, u32 dead,
                                       struct inode **out)
{
    cetrafs_inode_t raw;
    u64 others;
    u32 me;

    *out = NULL;
    if (cetrafs_sb_file_lock_enabled(sb) || READ_ONCE(cetrafs_journal_live_opener_off))
        return 0;
    if (cetrafs_sb_get_node_id(sb, &me))
        return -EIO;
    cetrafs_invalidate_raw_inode(sb, e->owner_ino);
    if (cetrafs_read_raw_inode(sb, e->owner_ino, &raw))
        return -EIO;
    if (cetrafs_le64(raw.generation) != e->owner_generation)
        return 0; /* not the entry's file: the owner check refuses it */
    others = (cetrafs_le64(raw.read_open_nodes) | cetrafs_le64(raw.suspended_writer_nodes)) &
             ~(1ULL << (dead % CETRAFS_MAX_READER_NODES));
    if (others & (1ULL << (me % CETRAFS_MAX_READER_NODES))) {
        struct inode *inode = ilookup(sb, e->owner_ino);

        others &= ~(1ULL << (me % CETRAFS_MAX_READER_NODES));
        if (inode && cetrafs_inode_get_generation(inode) == e->owner_generation) {
            if (!down_write_trylock(&inode->i_mapping->invalidate_lock)) {
                iput(inode);
                return 1;
            }
            *out = inode;
        } else if (inode) {
            iput(inode);
        }
    }
    while (others) {
        u32 n = (u32) __ffs64(others);
        bool stale = false;
        int ret;

        others &= ~(1ULL << n);
        ret = cetrafs_node_is_stale(sb, n, &stale);
        if (ret || !stale) {
            if (*out) {
                up_write(&(*out)->i_mapping->invalidate_lock);
                iput(*out);
                *out = NULL;
            }
            return ret ? -EIO : 1;
        }
    }
    return 0;
}

static void cetrafs_journal_opener_put(struct inode **oi)
{
    if (*oi) {
        up_write(&(*oi)->i_mapping->invalidate_lock);
        iput(*oi);
        *oi = NULL;
    }
}

static int cetrafs_journal_replay_cmp(const void *a, const void *b)
{
    const struct cetrafs_journal_replay_entry *ea = a, *eb = b;

    return cmp_int(ea->txn_id, eb->txn_id);
}

/* Entries replay applied because the target was TORN -- the journal
 * doing the one job it exists for. Distinct from a plain apply so a
 * test can tell "it repaired a tear" from "it redid a lost write". */
static atomic64_t cetrafs_journal_replay_torn = ATOMIC64_INIT(0);

/* Entries kept because a live node had their file open (nofilelock). */
static atomic64_t cetrafs_journal_replay_live_kept = ATOMIC64_INIT(0);

u64 cetrafs_journal_replay_live_kept_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_replay_live_kept);
}

/* Replays that kept entries for live openers yet let their caller on. */
static atomic64_t cetrafs_journal_replay_scoped_ok = ATOMIC64_INIT(0);

u64 cetrafs_journal_replay_scoped_ok_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_replay_scoped_ok);
}

/* Redos run under this node's own opener's invalidate_lock. */
static atomic64_t cetrafs_journal_replay_own_opener = ATOMIC64_INIT(0);

u64 cetrafs_journal_replay_own_opener_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_replay_own_opener);
}

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
 * A caller that does not wait gets -EEXIST and must take nothing: the
 * heartbeat sweep, which takes nothing anyway, and the heartbeat's Zone
 * Group takeover, which leaves the group for its next tick. That
 * plus the flag check serializes concurrent replayers, and replaying
 * twice is idempotent regardless. Reads of the flag and slot
 * headers are uncached: this area belongs to a different node whose
 * writes our cache has never seen.
 */
static int __cetrafs_journal_replay_node(struct super_block *sb, u32 node_id, bool wait_for_claim, u64 scope);

/* TEST ONLY: this node replays no peer's journal while set (-EBUSY), so
 * a two-node scenario can choose which node claims a dead node's area
 * first (ctest sweep-vs-open-replay). */
static bool cetrafs_journal_replay_refuse;
cetrafs_test_param(journal_replay_refuse, cetrafs_journal_replay_refuse, bool, 0644);
MODULE_PARM_DESC(journal_replay_refuse, "TEST ONLY: refuse to replay any journal area");

/* TEST ONLY: a caller that does not wait for a replay claim waits for
 * the area's mutex anyway -- the old sweep, the control of ctest
 * sweep-vs-open-replay. */
static bool cetrafs_journal_sweep_waits;
cetrafs_test_param(journal_sweep_waits, cetrafs_journal_sweep_waits, bool, 0644);
MODULE_PARM_DESC(journal_sweep_waits, "TEST ONLY: a non-waiting replay still waits for the area mutex");

/* TEST ONLY: every kept entry fails every replay, as before audit
 * 2026-11-15 F-37 (tests/kernel/journal_replay_scope.sh). */
static bool cetrafs_journal_scope_off;
cetrafs_test_param(journal_scope_off, cetrafs_journal_scope_off, bool, 0644);
MODULE_PARM_DESC(journal_scope_off, "TEST ONLY: an entry kept for a live opener fails every replay");

int cetrafs_journal_replay_node(struct super_block *sb, u32 node_id, bool wait_for_claim)
{
    return cetrafs_journal_replay_node_scoped(sb, node_id, wait_for_claim, CETRAFS_REPLAY_STRICT);
}

/*
 * A replay whose caller waits on one thing (audit 2026-11-15 F-37). An
 * entry kept only because a live node has its file open (cetrafs_
 * journal_live_opener()) used to fail every replay of the area, and so
 * everything waiting on the dead node: HA restarting its OTHER VMs, a
 * namespace-lock break, the claim of its Zone Groups -- for as long as
 * that one file stayed open. 'scope' says what the caller waits on:
 *
 *   CETRAFS_REPLAY_STRICT  anything kept fails it, as before (our own
 *                          area at mount, whose slots are reused next;
 *                          the scrub's finish of a stale free);
 *   0                      no file: entries kept for live openers do
 *                          not fail it (a namespace-lock break -- such
 *                          entries are regular files' -- a Zone Group
 *                          claim, the sweep);
 *   an inode number        only such an entry of THAT file fails it
 *                          (an open of it, its lock reclaims, its free).
 *
 * Whatever is kept, the area stays DIRTY and is never parked CLEAN, so
 * the entry waits for the next replay; and while a stale node's area is
 * dirty no scrub cycle frees (scrub.c), which covers blocks only a kept
 * entry's payload names in Zone Groups claimed meanwhile.
 */
int cetrafs_journal_replay_node_scoped(struct super_block *sb, u32 node_id, bool wait_for_claim, u64 scope)
{
    struct cetrafs_journal *j = cetrafs_sb_get_journal(sb);
    int ret;

    if (READ_ONCE(cetrafs_journal_scope_off))
        scope = CETRAFS_REPLAY_STRICT;
    if (READ_ONCE(cetrafs_journal_replay_refuse))
        return -EBUSY; /* test-only; see the parameter */
    if (!j || node_id >= 64)
        return __cetrafs_journal_replay_node(sb, node_id, wait_for_claim, scope);
    /*
     * A caller that does not wait for a replay claim does not wait for
     * this mutex either: its holder is a local replay of the same area,
     * which may run for the claim cap (several stale windows) behind a
     * peer's. That caller is the heartbeat sweep, which takes nothing
     * from the dead node and whose tick must not stall behind an open's
     * replay (audit F9). -EEXIST is its "someone is at it" already.
     */
    if (!wait_for_claim && !READ_ONCE(cetrafs_journal_sweep_waits)) {
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
        struct cetrafs_row_mark fenced;

        if (cetrafs_sb_peer_fenced_mark(sb, node_id, &fenced) && cetrafs_node_reattached_since_fence(sb, node_id)) {
            pr_info("journal: node %u came back while its journal waited to be replayed -- not replaying it\n",
                    node_id);
            ret = -EBUSY;
        } else {
            /* No allocation in here may recurse into this filesystem:
             * reclaim evicting an inode can reach a stale holder's
             * branch that replays this same node, behind the mutex this
             * task holds (audit 2026-11-15 BM-35). */
            unsigned int nofs = memalloc_nofs_save();

            ret = __cetrafs_journal_replay_node(sb, node_id, wait_for_claim, scope);
            memalloc_nofs_restore(nofs);
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

/* TEST ONLY: a failed consume falls through to the park as it used to,
 * leaving the area CLEAN with the entry in its slot -- the control of
 * ctest replay-after-truncate. */
static bool cetrafs_journal_consume_fail_park;
cetrafs_test_param(journal_consume_fail_park, cetrafs_journal_consume_fail_park, bool, 0644);
MODULE_PARM_DESC(journal_consume_fail_park, "TEST ONLY: park the area clean after a failed consume");

/* Entries a replay kept undecided (procfs journal_replay_kept). */
static atomic64_t cetrafs_journal_replay_kept = ATOMIC64_INIT(0);

u64 cetrafs_journal_replay_kept_count(void)
{
    return (u64) atomic64_read(&cetrafs_journal_replay_kept);
}

/* An entry the scan could not judge: what it names is all it records. */
static void cetrafs_journal_entry_undecided(struct cetrafs_journal_replay_entry *e,
                                            const cetrafs_journal_header_t *hdr, u64 header_lba)
{
    memset(e, 0, sizeof(*e));
    e->txn_id = cetrafs_le64(hdr->txn_id);
    e->target_lba = cetrafs_le64(hdr->target_lba);
    e->header_lba = header_lba;
    e->undecided = true;
}

static int __cetrafs_journal_replay_node(struct super_block *sb, u32 node_id, bool wait_for_claim, u64 scope)
{
    u64 area_start, slots, s, park_seq = 0;
    struct cetrafs_journal_replay_entry *entries;
    u32 count = 0, applied = 0, my_node_id = 0;
    u8 *st = NULL;
    bool final_pass = false;
    unsigned int pass = 0, kept = 0;
    int kept_ret = 0;
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
            /* A caller that does not wait walking away from a replay a
             * peer is doing: the heartbeat sweep, or the heartbeat's Zone
             * Group takeover. -EEXIST, never 0: the takeover would read 0
             * as "replayed" and take the group while the peer is still
             * writing its owner's blocks. Counted, not just tolerated:
             * it is the only evidence that the race happened at all. */
            atomic64_inc(&cetrafs_journal_replay_declines);
            return -EEXIST;
        }
        return ret;
    }
    claimed = true;
    atomic64_inc(&cetrafs_journal_replays);

    /* Re-read under the claim: the pre-check above was unsynchronised,
     * so a peer may have replayed the whole area in between. Its
     * park_seq is the session every entry worth redoing belongs to. */
    ret = cetrafs_journal_read_flag_seq(sb, area_start, &dirty, &park_seq);
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

        /* From a session the area was parked after: its operation was
         * settled by that park -- replayed, or failed on a fenced node
         * whose entry write landed late. Consumed, never applied (M10). */
        if (cetrafs_le64(hdr->park_seq) != park_seq) {
            memset(&entries[count], 0, sizeof(entries[count]));
            entries[count].txn_id = cetrafs_le64(hdr->txn_id);
            entries[count].target_lba = cetrafs_le64(hdr->target_lba);
            entries[count].header_lba = header_lba;
            entries[count].before_park = true;
            pr_warn("journal replay: node %u slot %llu (txn %llu) is from park %llu, the area is at park %llu -- "
                    "not applying it\n",
                    node_id, (unsigned long long) s, (unsigned long long) cetrafs_le64(hdr->txn_id),
                    (unsigned long long) cetrafs_le64(hdr->park_seq), (unsigned long long) park_seq);
            count++;
            brelse(hbh);
            continue;
        }

        pbh = cetrafs_bread_uncached_retry(sb, header_lba + 1);
        if (!pbh) {
            /* Its target is known, so the entry is kept -- and every
             * newer entry for that block waits behind it -- while the
             * rest of the area is replayed. */
            pr_err("journal replay: node %u slot %llu: payload unreadable -- entry kept, area stays dirty\n",
                   node_id, (unsigned long long) s);
            cetrafs_journal_entry_undecided(&entries[count++], hdr, header_lba);
            brelse(hbh);
            if (READ_ONCE(cetrafs_journal_kept_aborts)) {
                ret = -EIO;
                goto out_free;
            }
            kept_ret = kept_ret ?: -EIO;
            continue;
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
         * keeps the entry with the area DIRTY, as a payload read
         * failure does; the next replay asks again.
         *
         * A target past the end of THIS node's layout is the same "not
         * knowing" on a volume grown live: a peer can grow, write there
         * and die before our next heartbeat. The lookup refreshes the
         * layout first and answers -EINVAL only against a current one;
         * when it cannot tell (-EAGAIN) the area stays DIRTY too
         * (GROWFS-LIVE-REVIEW H1; tests/kernel/grow_live_replay.sh).
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
                       "entry kept, leaving the area dirty for the next replay\n",
                       node_id, (unsigned long long) s, (unsigned long long) cetrafs_le64(hdr->target_lba), lret);
                cetrafs_journal_entry_undecided(&entries[count++], hdr, header_lba);
                brelse(hbh);
                if (READ_ONCE(cetrafs_journal_kept_aborts)) {
                    ret = lret;
                    goto out_free;
                }
                kept_ret = kept_ret ?: lret;
                continue;
            }
        }

        entries[count].txn_id = cetrafs_le64(hdr->txn_id);
        entries[count].target_lba = cetrafs_le64(hdr->target_lba);
        entries[count].header_lba = header_lba;
        entries[count].payload_lba = header_lba + 1;
        entries[count].flags = cetrafs_le32(hdr->flags);
        entries[count].prev_checksum = cetrafs_le32(hdr->prev_checksum);
        entries[count].payload_checksum = cetrafs_le32(hdr->payload_checksum);
        entries[count].before_park = false;
        entries[count].undecided = false;
        entries[count].owner_ino = cetrafs_le64(hdr->owner_ino);
        entries[count].owner_generation = cetrafs_le64(hdr->owner_generation);
        count++;
        brelse(hbh);
    }

    if (count)
        sort(entries, count, sizeof(*entries), cetrafs_journal_replay_cmp, NULL);

    /*
     * In passes. A boundary is ONE atomic batch (cetrafs_journal_write_
     * deferred()), and it can hold a NEW tree block together with the
     * index entry that makes it reachable: the owner check of the new
     * block then fails until that index is redone, whatever order the
     * txn ids put them in. Refused on the first look, the batch was
     * applied in part -- an index naming leaves never written -- and the
     * writes those leaves mapped were gone after a crash at the worst
     * point (tests/kernel/convert_split_no_flush.sh, part 4). So an entry
     * refused ONLY by the owner check waits for the next pass, and passes
     * repeat while one of them redoes something; once one redoes nothing,
     * what is still refused is refused as before. Every look is fresh.
     */
    st = count ? kvcalloc(count, sizeof(*st), GFP_KERNEL) : NULL;
    if (count && !st) {
        ret = -ENOMEM;
        goto out_free;
    }
    for (s = 0; s < count; s++) {
        if (entries[s].undecided) {
            st[s] = CETRAFS_JR_KEPT;
            kept++;
        }
    }
    for (;;) {
    unsigned int deferred = 0, applied_before = applied;

    for (s = 0; s < count; s++) {
        struct buffer_head *pbh, *tbh, *hbh;
        struct inode *oi = NULL; /* this node's opener, its invalidate_lock held across the redo */
        bool apply, owner_dir = false, owner_known = false;
        u32 judged_crc = 0;
        int blocked;

        if (st[s] == CETRAFS_JR_DEFERRED)
            st[s] = CETRAFS_JR_PENDING; /* a new pass looks again */
        if (st[s] != CETRAFS_JR_PENDING)
            continue;

        blocked = cetrafs_journal_blocked_by_older(entries, st, s);
        if (blocked == CETRAFS_JR_DEFERRED) {
            st[s] = CETRAFS_JR_DEFERRED;
            deferred++;
            continue;
        }
        if (blocked == CETRAFS_JR_KEPT) {
            u64 o;

            pr_warn("journal replay: node %u txn %llu: an older entry for target block %llu is kept -- "
                    "keeping this one behind it\n",
                    node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].target_lba);
            /* Behind a live opener's entry, it waits on that opener too. */
            for (o = s; o-- > 0;)
                if (entries[o].target_lba == entries[s].target_lba && st[o] == CETRAFS_JR_KEPT) {
                    entries[s].live_kept = entries[o].live_kept;
                    break;
                }
            ret = entries[s].live_kept ? -EBUSY : -EIO;
            goto keep;
        }

        if (entries[s].before_park) {
            atomic64_inc(&cetrafs_journal_replay_skipped);
            goto consume;
        }

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

            if (!aret && READ_ONCE(cetrafs_journal_alloc_region_fail)) {
                WRITE_ONCE(cetrafs_journal_alloc_region_fail, cetrafs_journal_alloc_region_fail - 1);
                aret = -EINVAL; /* TEST ONLY: as a region the lookup accepted, then lost */
            }
            if (aret == -EINVAL) {
                /* Outside every data region (a group's header, its
                 * bitmaps, the tables): no entry this format writes
                 * targets one, so the redo would scribble on metadata.
                 * Refuse it and consume it, as a stale target is. */
                atomic64_inc(&cetrafs_journal_replay_refused);
                pr_err("journal replay: node %u txn %llu target block %llu lies in no data region -- NOT "
                       "applying the entry\n",
                       node_id, (unsigned long long) entries[s].txn_id,
                       (unsigned long long) entries[s].target_lba);
                goto consume;
            }
            if (aret) {
                /* Could not decide: the entry is kept, the area stays dirty. */
                pr_err("journal replay: node %u txn %llu: could not tell whether target block %llu is "
                       "allocated (%d) -- entry kept, area stays dirty\n",
                       node_id, (unsigned long long) entries[s].txn_id,
                       (unsigned long long) entries[s].target_lba, aret);
                ret = aret == -ENOMEM ? aret : -EIO;
                goto keep;
            }
            if (!live) {
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
            goto keep;
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
                        goto keep;
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

                if (unlikely(cetrafs_journal_replay_apply_pause_ms) && !pass) { /* once per entry */
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
                    goto keep;
                }
                if (~crc32c(~0U, tbh->b_data, CETRAFS_BLOCK_SIZE) == tcrc)
                    break;
                if (++moved > CETRAFS_JOURNAL_MOVED_RETRIES) {
                    v = CETRAFS_JV_MOVING;
                    break;
                }
            }

            judged_crc = tcrc;
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

        /* The owner check (rule 15; the target is read again after it):
         * the bytes passed the guard, but a block freed and reallocated
         * since can carry the same bytes -- an empty dirent block looks
         * like any other. It must still be the entry's owner's (L9). An
         * owner whose record or tree cannot be read is deferred to the
         * next pass, and refused -- the area left DIRTY -- once a pass
         * redoes nothing (below); fsck --discard-journal is the way out
         * of an area that stays undecidable. */
        owner_dir = false;
        owner_known = false;
        if (apply && !cetrafs_journal_ignore_owner) {
            int held = -EIO;
            unsigned int otry;

            /* An owner that cannot be read is retried with backoff: a
             * record read fails for transient reasons (a path failover),
             * and the verdict must not depend on one unlucky read. Still
             * unreadable after that, the entry is refused and the area
             * stays dirty -- the guard alone is not enough to redo a
             * block whose owner we could not check (rule 6: a redo onto
             * a reused block is the corruption this check exists for). */
            for (otry = 0; otry < 5; otry++) {
                held = cetrafs_journal_owner_holds(sb, &entries[s], &owner_dir);
                if (held >= 0)
                    break;
                msleep(10U << otry);
            }
            if (held < 0 && READ_ONCE(cetrafs_journal_owner_fail_open)) {
                held = 1; /* TEST ONLY: the old verdict */
                pr_warn("journal replay: node %u txn %llu: owner ino %llu unreadable -- judging by the guard alone "
                        "(test control)\n",
                        node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].owner_ino);
            } else if (held < 0 && !final_pass) {
                /*
                 * Unreadable now, perhaps not after the rest is redone:
                 * the owner path of a leaf entry crosses an interior
                 * that is very likely ANOTHER entry of the same batch,
                 * torn by the crash, and a batch puts a re-edited block
                 * at its tail, so the leaf's entry often comes first.
                 * Aborting here aborted the whole area on every attempt
                 * -- the node could never mount and no peer could
                 * reclaim it (audit 2026-11-14 A-10). Deferred like an
                 * unreachable owner; refused below once a pass redoes
                 * nothing.
                 */
                pr_warn("journal replay: node %u txn %llu: owner ino %llu unreadable -- deferred to the next pass\n",
                        node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].owner_ino);
                st[s] = CETRAFS_JR_DEFERRED;
                deferred++;
                brelse(tbh);
                brelse(pbh);
                continue;
            } else if (held < 0) {
                atomic64_inc(&cetrafs_journal_replay_refused);
                pr_err("journal replay: node %u txn %llu: could not read owner ino %llu to confirm target block "
                       "%llu is still its after retries -- entry kept, area stays dirty\n",
                       node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].owner_ino,
                       (unsigned long long) entries[s].target_lba);
                brelse(tbh);
                brelse(pbh);
                ret = -EIO;
                goto keep;
            }
            owner_known = held >= 0;
            if (held == 0 && !final_pass) {
                st[s] = CETRAFS_JR_DEFERRED;
                deferred++; /* perhaps reachable once the rest is redone */
                brelse(tbh);
                brelse(pbh);
                continue;
            }
            if (held == 0) {
                apply = false;
                atomic64_inc(&cetrafs_journal_replay_refused);
                pr_err("journal replay: node %u txn %llu target block %llu is no longer a block of its owner "
                       "(ino %llu, generation %llu) -- freed and reused since; NOT applying the entry\n",
                       node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].target_lba,
                       (unsigned long long) entries[s].owner_ino, (unsigned long long) entries[s].owner_generation);
            }
        }

        /* The owner check read the owner's record and tree from the
         * device, after the re-read above: under nofilelock a live peer
         * can rewrite this extent leaf in that gap, and the dead node's
         * image then lands on top of it (audit 2026-11-14 C1, rule 15).
         * So the target is read once more, LAST, and must still be what
         * was judged. */
        if (apply && owner_known && !owner_dir) {
            int lo = cetrafs_journal_live_opener(sb, &entries[s], node_id, &oi);

            if (lo) {
                pr_warn_ratelimited("journal replay: node %u txn %llu: ino %llu is open on a live node -- %s; the "
                                    "redo waits\n",
                                    node_id, (unsigned long long) entries[s].txn_id,
                                    (unsigned long long) entries[s].owner_ino,
                                    lo < 0 ? "its record could not be read" : "it could be writing the block");
                atomic64_inc(&cetrafs_journal_replay_live_kept);
                entries[s].live_kept = lo > 0;
                brelse(tbh);
                brelse(pbh);
                ret = lo < 0 ? lo : -EBUSY;
                goto keep;
            }
        }
        if (apply && unlikely(cetrafs_journal_owner_pause_ms)) {
            pr_info("journal replay: pausing %ums after the owner check of target %llu\n",
                    cetrafs_journal_owner_pause_ms, (unsigned long long) entries[s].target_lba);
            msleep(cetrafs_journal_owner_pause_ms);
        }
        if (apply && !READ_ONCE(cetrafs_journal_no_last_read)) {
            brelse(tbh);
            tbh = cetrafs_bread_uncached_retry(sb, entries[s].target_lba);
            if (!tbh) {
                brelse(pbh);
                ret = -EIO;
                goto keep;
            }
            if (~crc32c(~0U, tbh->b_data, CETRAFS_BLOCK_SIZE) != judged_crc) {
                apply = false;
                atomic64_inc(&cetrafs_journal_replay_refused);
                pr_err("journal replay: node %u txn %llu target block %llu changed after its owner was checked -- "
                       "a live node is writing it; NOT applying the entry\n",
                       node_id, (unsigned long long) entries[s].txn_id,
                       (unsigned long long) entries[s].target_lba);
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
            cetrafs_bh_end_update(sb, tbh);
            werr = cetrafs_sync_buffer_refusable(sb, tbh);
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
                goto keep;
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
                goto keep;
            }
            atomic64_inc(&cetrafs_journal_replay_applied);
            if (oi)
                atomic64_inc(&cetrafs_journal_replay_own_opener);
            applied++;
            /* A redo changed bytes no stamp announced: advance the
             * owner's, so a node caching the block reads it again (L9)
             * -- this one included: the stamp names the node whose
             * write the redo is, never us.
             * Failing leaves peers on the old copy until the owner's
             * next change -- said, not fatal: the block itself is
             * right. */
            if (owner_known && !cetrafs_journal_ignore_owner) {
                int tret = cetrafs_inode_advance_change_stamp(sb, entries[s].owner_ino,
                                                              entries[s].owner_generation, owner_dir, node_id);

                if (tret)
                    pr_warn("journal replay: node %u txn %llu: could not advance ino %llu's change stamp after "
                            "the redo (%d) -- peers may keep a cached copy of block %llu\n",
                            node_id, (unsigned long long) entries[s].txn_id,
                            (unsigned long long) entries[s].owner_ino, tret,
                            (unsigned long long) entries[s].target_lba);
            }
        }
        cetrafs_journal_opener_put(&oi);
        brelse(tbh);
        brelse(pbh);

consume:
        hbh = cetrafs_bread_retry(sb, entries[s].header_lba);
        if (!hbh) {
            ret = -EIO;
            goto keep;
        }
        if (READ_ONCE(cetrafs_journal_consume_fail_once) && xchg(&cetrafs_journal_consume_fail_once, false)) {
            werr_consume = -EIO; /* TEST ONLY: as a header write the device refused */
        } else {
            cetrafs_bh_begin_update(hbh);
            memset(hbh->b_data, 0, CETRAFS_BLOCK_SIZE);
            cetrafs_bh_end_update(sb, hbh);
            werr_consume = cetrafs_sync_buffer_refusable(sb, hbh);
        }
        brelse(hbh);
        if (werr_consume && READ_ONCE(cetrafs_journal_consume_fail_park)) {
            pr_err("journal replay: node %u could not consume txn %llu (%d) -- TEST: parking anyway\n", node_id,
                   (unsigned long long) entries[s].txn_id, werr_consume);
            werr_consume = 0; /* test-only; see the parameter */
        }
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
            goto keep;
        }
        st[s] = CETRAFS_JR_DONE;
        continue;

keep:
        cetrafs_journal_opener_put(&oi);
        /*
         * This entry cannot be decided now: keep it, and with it the
         * area's DIRTY flag, and go on with the rest. One unreadable
         * owner or refused write used to abort the whole area, so every
         * other block it would have repaired stayed torn until that one
         * entry could be decided (audit 2026-11-15 A-10, B-6). Newer
         * entries for the same block stay behind it
         * (cetrafs_journal_blocked_by_older()).
         */
        if (READ_ONCE(cetrafs_journal_kept_aborts))
            goto out_free;
        st[s] = CETRAFS_JR_KEPT;
        kept++;
        kept_ret = kept_ret ?: ret;
        ret = 0;
    }
    if (!deferred)
        break;
    if (applied == applied_before)
        final_pass = true; /* nothing new is reachable: refuse the rest */
    pass++;
    }

    if (kept) {
        bool blocks = false;

        for (s = 0; s < count && !blocks; s++)
            if (st[s] == CETRAFS_JR_KEPT)
                blocks = !entries[s].live_kept || scope == CETRAFS_REPLAY_STRICT ||
                         (scope && entries[s].owner_ino == scope);
        atomic64_add(kept, &cetrafs_journal_replay_kept);
        if (!blocks) {
            /* Every one waits on a live opener of a file this caller is
             * not waiting on. The area stays dirty for the next replay;
             * the caller goes on. */
            pr_warn_ratelimited("journal replay: node %u replayed %u entr%s; %u kept for live openers of other "
                                "files -- the area stays dirty, the caller goes on\n",
                                node_id, applied, applied == 1 ? "y" : "ies", kept);
            atomic64_inc(&cetrafs_journal_replay_scoped_ok);
            ret = 0;
            goto out_free;
        }
        pr_err("journal replay: node %u replayed %u entr%s; %u kept undecided -- the area stays dirty for the "
               "next replay\n",
               node_id, applied, applied == 1 ? "y" : "ies", kept);
        ret = kept_ret ?: -EIO;
        goto out_free;
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
    kvfree(st);
    kvfree(entries);
out_release:
    if (claimed)
        cetrafs_journal_release_replay(sb, node_id, area_start, my_node_id, /*set_clean=*/false);
    return ret;
}

/* TEST ONLY: the scrub frees while a stale node's journal is dirty, as
 * before audit 2026-11-15 F-37 (tests/kernel/journal_replay_scope.sh). */
static bool cetrafs_scrub_ignores_dead_journal;
cetrafs_test_param(scrub_ignores_dead_journal, cetrafs_scrub_ignores_dead_journal, bool, 0644);
MODULE_PARM_DESC(scrub_ignores_dead_journal, "TEST ONLY: the scrub frees while a stale node's journal is dirty");

/*
 * Is a stale node's journal still DIRTY? Its entries can name, in their
 * payloads, blocks nothing on the device references yet -- a dead
 * node's last tree write, kept for a live opener and redone later
 * (cetrafs_journal_replay_node_scoped()). Its Zone Groups may be ours by
 * then, and a scrub that judged those blocks leaked would free what the
 * redo then publishes. So no scrub cycle frees while one is (scrub.c).
 * A read that fails answers yes.
 */
bool cetrafs_journal_dead_dirty(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 n, count, me;

    if (READ_ONCE(cetrafs_scrub_ignores_dead_journal))
        return false;
    if (!raw_sb || cetrafs_sb_get_node_id(sb, &me))
        return true;
    count = le32_to_cpu(raw_sb->node_table_count);
    for (n = 0; n < count; n++) {
        bool dirty = false, stale = false;

        if (n == me)
            continue;
        if (cetrafs_journal_node_is_dirty(sb, n, &dirty))
            return true;
        if (!dirty)
            continue;
        if (cetrafs_node_is_stale(sb, n, &stale) || stale)
            return true;
    }
    return false;
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
