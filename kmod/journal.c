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
 * All go through cetrafs_journal_replay_node(), serialized by the
 * cluster mutex and the per-area flag; replaying twice is idempotent.
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
    bool flag_dirty;     /* our on-disk flag's current state -- truthful, since we're its only writer */
    unsigned long *busy; /* logged-but-not-yet-consumed slots (in-flight operations) */
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

    if (!bh)
        return -EIO;

    memset(bh->b_data, 0, CETRAFS_BLOCK_SIZE);
    hdr = (cetrafs_node_journal_hdr_t *) bh->b_data;
    hdr->magic = cetrafs_cpu_to_le32(CETRAFS_NODE_JOURNAL_MAGIC);
    hdr->state = cetrafs_cpu_to_le32(dirty ? CETRAFS_NODE_JOURNAL_DIRTY : CETRAFS_NODE_JOURNAL_CLEAN);
    hdr->replay_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE); /* 0 is a real node id -- be explicit */
    cetrafs_bh_end_update(bh);
    sync_dirty_buffer(bh);
    brelse(bh);
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
module_param_named(force_live_replay_claim, cetrafs_force_live_replay_claim, bool, 0644);
MODULE_PARM_DESC(force_live_replay_claim, "TEST ONLY: a foreign journal replay claim always reads as live");

/* 0 = claimed, -EEXIST = someone else is handling it (or nothing to do). */
static int cetrafs_journal_claim_replay(struct super_block *sb, u64 area_start, u32 my_node_id)
{
    struct cetrafs_journal_claim_ctx ctx = {.my_node_id = my_node_id};
    struct buffer_head *bh;
    const cetrafs_node_journal_hdr_t *hdr;
    u32 owner;

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
        cetrafs_node_fence_peer(sb, owner, "a journal replay claim");
        ctx.steal = true;
        ctx.steal_from = owner;
    }

    return cetrafs_cas_record(sb, area_start, cetrafs_journal_claim_mutate, &ctx);
}

static void cetrafs_journal_release_replay(struct super_block *sb, u64 area_start, u32 my_node_id, bool set_clean)
{
    struct cetrafs_journal_claim_ctx ctx = {.my_node_id = my_node_id, .release = true, .set_clean = set_clean};
    int ret = cetrafs_cas_record(sb, area_start, cetrafs_journal_claim_mutate, &ctx);

    if (ret < 0)
        pr_err("journal: failed to release the replay claim on area %llu: %d\n", (unsigned long long) area_start, ret);
}

int cetrafs_journal_init(struct super_block *sb, struct cetrafs_journal **out_j)
{
    struct cetrafs_journal *j = kzalloc(sizeof(*j), GFP_KERNEL);

    if (!j)
        return -ENOMEM;

    mutex_init(&j->lock);
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
    kfree(j->busy);
    kfree(j);
}

/*
 * Bind this mount's journal to its freshly-registered node id and replay
 * our own previous session's crash leftovers, if any. Called from
 * fill_super() immediately after cetrafs_node_register() succeeds --
 * before ZG claiming, before anything can possibly write. A failed own-
 * replay fails the mount: writing on top of unrecovered state is exactly
 * what the journal exists to prevent.
 */
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

    j->busy = kcalloc(BITS_TO_LONGS(j->slots), sizeof(unsigned long), GFP_KERNEL);
    if (!j->busy) {
        j->area_start = 0;
        j->slots = 0;
        return -ENOMEM;
    }

    ret = cetrafs_journal_replay_node(sb, node_id, /*wait_for_claim=*/true);
    if (ret)
        return ret;

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
module_param_named(journal_skip_consume, cetrafs_journal_skip_consume, bool, 0644);
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
module_param_named(journal_skip_target_write, cetrafs_journal_skip_target_write, bool, 0644);
MODULE_PARM_DESC(journal_skip_target_write, "test-only: journal the entry but do not write the target in place");

static bool cetrafs_journal_ignore_guard;
module_param_named(journal_ignore_guard, cetrafs_journal_ignore_guard, bool, 0644);
MODULE_PARM_DESC(journal_ignore_guard, "test-only: replay without the prev_checksum guard (reproduces the pre-fix bug)");

/* Test-only: treat a TORN target as "changed since" and refuse it -- the
 * behaviour 0.7.3 shipped, where a block caught mid-write was never
 * repaired because it matched neither the entry's before- nor its
 * after-image. This is the negative control for the torn branch: with it
 * set, the crash rig's phase 5 must FAIL. Never set in production. */
static bool cetrafs_journal_ignore_torn;
module_param_named(journal_ignore_torn, cetrafs_journal_ignore_torn, bool, 0644);
MODULE_PARM_DESC(journal_ignore_torn, "test-only: refuse to redo a torn target (reproduces the 0.7.3 bug)");

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
    struct buffer_head *jbh;
    struct buffer_head *pbh, *hbh;
    cetrafs_journal_header_t *hdr;
    bool journaled = false;
    bool degraded = false; /* fell back to an unjournaled write on a journaling volume */

    if (j && j->area_start) {
        mutex_lock(&j->lock);

        slot = find_first_zero_bit(j->busy, j->slots);
        if (slot >= j->slots) {
            /* Every slot is held by a concurrently in-flight operation
             * -- effectively impossible at realistic slot counts, and
             * journaling is best-effort by design (mkfs -J 0 is a
             * supported configuration), so warn loudly and fall through
             * to an unjournaled-but-still-synced write rather than
             * failing the operation. */
            pr_warn_ratelimited("journal: all %llu slots in flight, writing block %llu unjournaled\n",
                                (unsigned long long) j->slots, (unsigned long long) bh->b_blocknr);
            mutex_unlock(&j->lock);
            degraded = true;
            goto write_target;
        }

        /* First entry of this session: durably flip our flag to DIRTY
         * *before* committing anything, so a crash after the commit is
         * guaranteed to be caught by the next replay of our area. */
        if (!j->flag_dirty) {
            int ret = cetrafs_journal_write_flag(sb, j->area_start, true);

            if (ret) {
                /* Same degradation as the all-slots-busy path below:
                 * journaling is best-effort by design, and the target
                 * still gets a synchronous write. Returning here instead
                 * would leave the caller's modification locked in memory
                 * with nothing to publish it. */
                pr_warn_ratelimited("journal: could not mark our area dirty (%d), writing block %llu unjournaled\n",
                                    ret, (unsigned long long) bh->b_blocknr);
                mutex_unlock(&j->lock);
                degraded = true;
                goto write_target;
            }
            j->flag_dirty = true;
        }

        set_bit(slot, j->busy);
        txn_id = ++j->next_txn_id;
        mutex_unlock(&j->lock);

        header_lba = j->area_start + 1 + slot * CETRAFS_JOURNAL_SLOT_BLOCKS;
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
            ok = buffer_uptodate(pbh) && buffer_uptodate(hbh);
            brelse(pbh);
            brelse(hbh);
            if (!ok)
                goto journal_failed;
        }

        journaled = true;
        atomic64_inc(&cetrafs_journal_writes);
        fs_debug(info, "journal: txn %llu slot %llu target_lba=%llu", (unsigned long long) txn_id,
                 (unsigned long long) slot, (unsigned long long) bh->b_blocknr);
    }

write_target:
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
     * The DEGRADED (unjournaled fallback) case flushes too, for the
     * mirror-image reason: a consume below only syncs its zeroed header,
     * so the zero can still be sitting in the device cache -- ordinarily
     * harmless, because the next JOURNALED write's flush here lands it
     * before any covered block changes again, and re-applying a consumed
     * entry over an unchanged target is idempotent. An unjournaled write
     * is the one writer of a covered block with no entry of its own and,
     * without this flush, no barrier: a reordering cache could persist it
     * while losing an earlier consume's zero, and a crash then has replay
     * resurrect the consumed entry and roll this very write back. The
     * flush makes every prior zero durable BEFORE this write can be.
     * Only the degraded fallbacks pay it (loud error paths already);
     * a volume with journaling off (mkfs -J 0) has no entries to order
     * against and skips it. */
    if (journaled && cetrafs_journal_skip_target_write) {
        blkdev_issue_flush(sb->s_bdev);
        /* Abort rather than end the update: the modification is dropped
         * and the buffer unlocked without being dirtied, so the target
         * keeps its prior image exactly as a crash here would leave it.
         * The slot is deliberately retained (see skip_consume). */
        cetrafs_bh_abort_update(bh);
        pr_warn_ratelimited("journal: journal_skip_target_write set -- txn %llu committed, target %llu NOT written\n",
                            (unsigned long long) txn_id, (unsigned long long) bh->b_blocknr);
        return 0;
    }

    if (journaled || degraded)
        blkdev_issue_flush(sb->s_bdev);
    /* end_update marks it dirty and releases it; the sync must follow,
     * never precede, because sync_dirty_buffer() takes the buffer lock. */
    cetrafs_bh_end_update(bh);
    sync_dirty_buffer(bh);

    /* 4. Consume: the target is durable, so the entry is spent. Leaving
     * it live would let a later replay of our area (after our crash in
     * some UNRELATED, much later operation) re-apply this stale image
     * over whatever newer content this block holds by then. */
    if (journaled && cetrafs_journal_skip_consume) {
        /* Deliberately do NOT release the slot: a released slot is
         * immediately reused, and the next entry would overwrite this
         * header -- leaving only ONE live entry at crash time, which is
         * not the state a real crash produces. Entries accumulate until
         * the area fills (then the ordinary all-slots-busy degradation
         * takes over, loudly). */
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
         * entry that could have redone it. */
        blkdev_issue_flush(sb->s_bdev);
        jbh = cetrafs_getblk_overwrite(sb, header_lba);
        if (jbh) {
            memset(jbh->b_data, 0, CETRAFS_BLOCK_SIZE);
            cetrafs_bh_end_update(jbh);
            sync_dirty_buffer(jbh);
            brelse(jbh);
        } else {
            /* Failing to consume is safe, just loud: the entry stays
             * live, and replay now verifies prev_checksum against the
             * device before applying anything -- so by the time this
             * block has legitimately changed again (by us or by a peer)
             * the entry no longer matches and is skipped. It used to be
             * safe only "while we hold this op's lock", which under
             * nofilelock is no lock at all. */
            pr_err("journal: failed to consume slot %llu (entry stays; replay of it is harmless)\n",
                   (unsigned long long) slot);
            return 0;
        }

        mutex_lock(&j->lock);
        clear_bit(slot, j->busy);
        mutex_unlock(&j->lock);
    }

    return 0;

journal_failed:
    /* Could not write the entry. Degrade to an unjournaled-but-synced
     * write rather than returning with the caller's modification stranded
     * in a locked buffer -- same choice as the all-slots-busy path, and
     * the same bounded loss of crash protection. Loud, never silent. */
    mutex_lock(&j->lock);
    clear_bit(slot, j->busy);
    mutex_unlock(&j->lock);
    pr_err("journal: could not write an entry for block %llu -- writing it unjournaled\n",
           (unsigned long long) bh->b_blocknr);
    journaled = false;
    degraded = true;
    goto write_target;
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
    sync_dirty_buffer(bh);
    if (!buffer_uptodate(bh))
        return -EIO;
    return 0;
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
 * Callers replaying a STALE node's area on a multi-node volume must hold
 * the cluster mutex (pass cluster_mutex_held=true if already holding it,
 * e.g. zonegroup.c's claim path; false to have this take and release it)
 * -- that plus the flag check serializes concurrent replayers, and
 * replaying twice is idempotent regardless. Reads of the flag and slot
 * headers are uncached: this area belongs to a different node whose
 * writes our cache has never seen.
 */
int cetrafs_journal_replay_node(struct super_block *sb, u32 node_id, bool wait_for_claim)
{
    u64 area_start, slots, s;
    struct cetrafs_journal_replay_entry *entries;
    u32 count = 0, applied = 0, my_node_id = 0;
    bool dirty = false, claimed = false;
    int ret;

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

    /* Claim the right to replay this area. -EEXIST means another node is
     * already on it (or beat us to it entirely) -- not an error: whoever
     * holds the claim finishes the job, exactly as the contended mutex
     * used to mean. */
    ret = cetrafs_journal_claim_replay(sb, area_start, my_node_id);
    if (ret == -EEXIST && wait_for_claim) {
        /* OUR OWN area, at mount-attach, with a live peer mid-replaying
         * our previous session's leftovers (it declared us dead and is
         * reclaiming). "Whoever holds the claim finishes the job" is the
         * right answer for a THIRD node's area, but walking away from our
         * own would let this mount start writing while the replayer is
         * still working it: new entries into slots whose headers its
         * consume pass is about to zero (destroying their write-ahead
         * protection), and new data over blocks it is about to blindly
         * rewrite with our old images. Wait it out instead -- the claim
         * clears in seconds (the area is a fixed handful of slots), or
         * the replayer itself goes stale and the re-claim below steals
         * it. Bounded so a wedged claim fails the mount loudly rather
         * than hanging it forever. */
        unsigned int waited_ms = 0;
        const unsigned int cap_ms = (cetrafs_sb_stale_secs(sb) * 3 + 30) * 1000;

        pr_info("journal: a peer is replaying this node's own area %llu -- waiting for it to finish\n",
                (unsigned long long) area_start);
        while (ret == -EEXIST) {
            if (waited_ms >= cap_ms) {
                pr_err("journal: replay claim on our own area %llu still held after %ums -- refusing the mount\n",
                       (unsigned long long) area_start, waited_ms);
                return -EBUSY;
            }
            msleep(500);
            waited_ms += 500;
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
            /* Counted, not just tolerated: this is the loser of the
             * race walking away, and it is the only evidence that the
             * race happened at all. */
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

    entries = kmalloc_array(slots, sizeof(*entries), GFP_KERNEL);
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
        {
            u32 tgt_zg;

            if (cetrafs_bg_owner_zg_for_lba(sb, cetrafs_le64(hdr->target_lba), &tgt_zg) != 0) {
                pr_err(
                    "journal replay: node %u slot %llu names target block %llu, which is outside every BG data "
                    "region -- refusing to apply it\n",
                    node_id, (unsigned long long) s, (unsigned long long) cetrafs_le64(hdr->target_lba));
                brelse(hbh);
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

        pbh = cetrafs_bread_uncached_retry(sb, entries[s].payload_lba);
        if (!pbh) {
            ret = -EIO;
            goto out_free;
        }

        /* FORCED-FRESH, not sb_bread(): the whole point of the read is
         * to see what is on the DEVICE right now, including writes a
         * peer made that this node has never had reason to re-read.
         * A cached copy would answer the question we are not asking. */
        tbh = cetrafs_bread_uncached_retry(sb, entries[s].target_lba);
        if (!tbh) {
            brelse(pbh);
            ret = -EIO;
            goto out_free;
        }

        {
            u32 tcrc = ~crc32c(~0U, tbh->b_data, CETRAFS_BLOCK_SIZE);

            if (cetrafs_journal_ignore_guard) {
                apply = true;
            } else if (tcrc == entries[s].payload_checksum) {
                /* The target write landed before the crash; only the
                 * consume was lost. Applying would be byte-identical,
                 * so skip the I/O. */
                apply = false;
                atomic64_inc(&cetrafs_journal_replay_skipped);
            } else if (!(entries[s].flags & CETRAFS_JRNL_F_GUARDED)) {
                /* Written by a module that predates prev_checksum. It
                 * carries no proof either way, so behave as that module
                 * did -- apply -- but say so: during a rolling upgrade
                 * this is the window where the old hazard still exists. */
                apply = true;
                pr_warn("journal replay: node %u txn %llu (target %llu) predates the replay guard -- "
                        "applying unverified\n",
                        node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].target_lba);
            } else if (tcrc == entries[s].prev_checksum) {
                /* Untouched since the entry was written: the target
                 * write never landed, and redo is exactly right. */
                apply = true;
            } else if (!cetrafs_journal_ignore_torn && !cetrafs_journal_target_intact(tbh)) {
                /* TORN. Not a peer's newer write -- not a whole block at
                 * all. Redo it: this is the case the journal exists for,
                 * and refusing here leaves the block unreadable forever. */
                apply = true;
                atomic64_inc(&cetrafs_journal_replay_torn);
                pr_warn("journal replay: node %u txn %llu target block %llu is TORN (fails its own tail "
                        "checksum) -- redoing it\n",
                        node_id, (unsigned long long) entries[s].txn_id,
                        (unsigned long long) entries[s].target_lba);
            } else {
                /* A COMPLETE image that is neither the before nor the
                 * after. Somebody has legitimately written this block
                 * since -- under nofilelock, typically the node HA moved
                 * the VM to.
                 * Applying here is the corruption this guard exists to
                 * stop: a valid, CRC-correct, WRONG extent leaf that
                 * fsck cannot see. */
                apply = false;
                atomic64_inc(&cetrafs_journal_replay_refused);
                pr_err("journal replay: node %u txn %llu target block %llu has changed since the entry was "
                       "written (crc %08x, expected %08x before / %08x after) -- NOT applying it. The block "
                       "has been rewritten since: by a peer that took the file over (the nofilelock case this "
                       "guard exists for), or by a later local operation whose consume was lost\n",
                       node_id, (unsigned long long) entries[s].txn_id, (unsigned long long) entries[s].target_lba,
                       tcrc, entries[s].prev_checksum, entries[s].payload_checksum);
            }
        }

        if (apply) {
            memcpy(tbh->b_data, pbh->b_data, CETRAFS_BLOCK_SIZE);
            mark_buffer_dirty(tbh);
            sync_dirty_buffer(tbh);
            atomic64_inc(&cetrafs_journal_replay_applied);
            applied++;
        }
        brelse(tbh);
        brelse(pbh);

consume:
        hbh = sb_bread(sb, entries[s].header_lba);
        if (!hbh) {
            ret = -EIO;
            goto out_free;
        }
        memset(hbh->b_data, 0, CETRAFS_BLOCK_SIZE);
        mark_buffer_dirty(hbh);
        sync_dirty_buffer(hbh);
        brelse(hbh);
    }

    pr_info("journal replay: node %u replayed %u valid entr%s\n", node_id, applied, applied == 1 ? "y" : "ies");

    /* Park the flag at CLEAN and drop the claim in ONE compare-and-swap:
     * leaving it DIRTY-but-unclaimed, or CLEAN-but-still-claimed, would
     * each strand the area for a tick. */
    cetrafs_journal_release_replay(sb, area_start, my_node_id, /*set_clean=*/true);
    claimed = false;

out_free:
    kfree(entries);
out_release:
    if (claimed)
        cetrafs_journal_release_replay(sb, area_start, my_node_id, /*set_clean=*/false);
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
