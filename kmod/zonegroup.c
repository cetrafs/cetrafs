// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * zonegroup.c -- Zone Group ownership, and the allocation policy that
 * depends on it.
 *
 * Each node holds only the ZGs it needs: one when it has none (at mount,
 * or lazily from heartbeat.c's tick), and one more only when it actually
 * runs out of space in what it owns (cetrafs_alloc_pick_bg()). Claiming
 * every unowned ZG at mount instead would let the first node to touch a
 * fresh volume own the entire disk and starve every later mounter. With
 * N zone groups at most N nodes can hold write access at once, and that
 * holds only because each takes the minimum.
 *
 * The allocation policy lives here rather than in alloc.c because all it
 * needs is which ZGs this node owns; alloc.c stays ignorant of ZGs and
 * allocates from whatever bg_id it is handed.
 *
 * A claim is one atomic CAS of the ZG's hot sector, not a held lock.
 * Losing the race is normal clustering behaviour, not a mount failure:
 * we simply own fewer ZGs than we tried for. cetrafs_zg_claim_unowned()
 * also steals a ZG whose owner's heartbeat has gone stale, and
 * heartbeat.c calls it every tick, so a dead peer's ZGs come back
 * without anyone remounting.
 *
 * On a device with no atomic CAW, fs.c refuses the mount outright if any
 * peer is live -- see node.c's cetrafs_node_live_peer_exists(). That
 * question goes to the Node Registry, not to ZG ownership: a mounted
 * node may own no Zone Group at all.
 *
 * The ZG record's journal fields are deprecated and always zero;
 * journals are per-node areas owned by journal.c.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/buffer_head.h>
#include <linux/crc32c.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/stddef.h>
#include <linux/timekeeping.h>

#include "kmod.h"

/*
 * CRC32C over one half of a ZG block with that half's own checksum field
 * treated as zero -- processed in three pieces (head, 8 literal zero
 * bytes standing in for the field, tail) rather than copying the 4096-
 * byte struct onto the stack to zero it in place (it is a full block;
 * see alloc.c's comment on why that copy would be unsafe). Read-only.
 *
 * v0x0009 splits the record into an independently-checksummed HOT sector
 * (the CAS unit: ownership, free-block aggregate, lease stamps) and a
 * COLD remainder (mkfs-time BG geometry) -- see cetrafs.h. Two halves,
 * two checksums, so an atomic compare-and-swap of the hot sector alone
 * leaves the cold half's checksum valid.
 *
 * NOTE: simply *skipping* the checksum field's bytes is NOT equivalent
 * to zeroing it -- CRC32C's running state still advances on a zero byte,
 * it just advances differently than on the field's real value. Omitting
 * the explicit zero bytes produced a checksum that could never match
 * mkfs's, surfacing as every ZG read failing -EUCLEAN (caught during
 * phase 10's own testing).
 */
static u32 cetrafs_zg_crc_half(const void *blk, size_t half_off, size_t half_len, size_t csum_off)
{
    static const u8 zero[8] = {0};
    const u8 *p = (const u8 *) blk + half_off;
    size_t rel = csum_off - half_off; /* checksum's offset within its own half */
    u32 crc = ~0U;

    crc = crc32c(crc, p, rel);
    crc = crc32c(crc, zero, sizeof(zero));
    crc = crc32c(crc, p + rel + sizeof(zero), half_len - rel - sizeof(zero));
    return ~crc;
}

static u32 cetrafs_zg_hot_crc(const void *blk)
{
    return cetrafs_zg_crc_half(blk, CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                               offsetof(cetrafs_zone_group_t, hot_checksum));
}

static u32 cetrafs_zg_cold_crc(const void *blk)
{
    return cetrafs_zg_crc_half(blk, CETRAFS_ZG_COLD_OFF, CETRAFS_ZG_COLD_LEN,
                               offsetof(cetrafs_zone_group_t, cold_checksum));
}


static int cetrafs_read_zg(struct super_block *sb, u32 zg_id, cetrafs_zone_group_t *out)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct buffer_head *bh;
    const cetrafs_zone_group_t *zg;
    u32 want, got;

    if (!raw_sb)
        return -EINVAL;
    if (zg_id >= le32_to_cpu(raw_sb->zone_group_count))
        return -EINVAL;

    /* Checksum-mismatch retries: ZG records are written
     * synced under the cluster mutex (claims/releases) or by their owner
     * (counter rollups), but READERS of them -- claim-eligibility scans,
     * procfs, cetrafs_zg_get_info() -- are deliberately lockless, so a
     * reader can observe a peer's in-flight 4 KiB record write torn. A
     * torn observation converges on re-read; only a persistent mismatch
     * is real corruption. Same shape as inode.c/node.c/dir.c's retries. */
    {
        int attempt;

        for (attempt = 0; attempt < 5; attempt++) {
            bh = cetrafs_bread_uncached_retry(sb, le64_to_cpu(raw_sb->zg_table_start) + zg_id);
            if (!bh)
                return -EIO;

            zg = (const cetrafs_zone_group_t *) bh->b_data;
            want = (u32) le64_to_cpu(zg->hot_checksum);
            got = cetrafs_zg_hot_crc(bh->b_data);
            if (got == want && (u32) le64_to_cpu(zg->cold_checksum) == cetrafs_zg_cold_crc(bh->b_data)) {
                if (le16_to_cpu(zg->zg_id) != (u16) zg_id) {
                    brelse(bh);
                    return -EINVAL;
                }
                memcpy(out, zg, sizeof(*out));
                brelse(bh);
                return 0;
            }
            brelse(bh);

            /* Same backoff as the inode-record and node-row readers: a
             * checksum tear here is a peer's in-flight write, which
             * takes milliseconds, not microseconds. */
            usleep_range(100, 400);
        }
    }

    pr_err("ZG %u failed its checksum repeatedly -- corrupted, not just a torn concurrent read\n", zg_id);
    return -EUCLEAN;
}

/* No whole-record ZG writer remains at runtime: ownership
 * changes go through cetrafs_zg_cas() on the hot sector, the free-block
 * aggregate through cetrafs_zg_adjust_free_blocks()'s batched cached
 * update, and the cold half is written only by mkfs. */


/* ---- ZG ownership as an atomic compare-and-swap --------------------
 *
 * owner_node_id lives in the ZG record's HOT sector (v0x0009), so a
 * claim or release is one CAS of that 512-byte region --
 * replacing the PR-mutexed read / decide / write / read-back-to-check
 * dance. The swap only lands if the sector is byte-for-byte what the
 * decision was made against, so losing the race is detected by the
 * device rather than inferred from a verify-read that could itself be
 * stale.
 *
 * Staleness of the current owner needs I/O (Node Registry) and so is
 * decided by the caller before the swap; the mutator is told the exact
 * owner id it may displace and rejects anything else.
 *
 * The free-block aggregate goes through the SAME compare-and-swap, once
 * per durability boundary rather than once per block. It used to be a
 * batched cached read-modify-write, on the reasoning that only a ZG's
 * own owner ever adjusts it -- true of
 * the FIELD, and beside the point: free_data_blocks shares the hot
 * sector with owner_node_id, and a cached update dirties the whole
 * 4096-byte block, so its write-back republishes whatever ownership
 * bytes were there when it was read. A peer that claimed the ZG in
 * between would have its claim reverted by an unrelated counter update,
 * hot checksum correctly recomputed, nothing to detect it, and both
 * nodes then allocating from one Zone Group.
 *
 * Deltas are accrued in memory (cetrafs_sb_accrue_zg_free()) and applied
 * by cetrafs_zg_apply_free_delta() below, so per-block allocation still
 * never touches the wire.
 */
struct cetrafs_zg_cas_ctx {
    u32 my_node_id;
    bool claim; /* true: take ownership; false: give it back */
    bool allow_steal;
    u32 steal_from; /* meaningful only when allow_steal */
};

static int cetrafs_zg_cas_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_zg_cas_ctx *ctx = priv;
    cetrafs_zone_group_t *zg = (cetrafs_zone_group_t *) image; /* hot fields only */
    u16 owner = le16_to_cpu(zg->owner_node_id);

    (void) len;

    if (ctx->claim) {
        bool unowned = (owner == CETRAFS_NODE_ID_NONE);
        bool stealable = ctx->allow_steal && owner == (u16) ctx->steal_from;

        if (owner == (u16) ctx->my_node_id)
            return 1; /* already ours -- nothing to swap */
        if (!unowned && !stealable)
            return -EBUSY; /* a live peer owns it (or took it since we looked) */

        zg->owner_node_id = cpu_to_le16((u16) ctx->my_node_id);
    } else {
        if (owner != (u16) ctx->my_node_id)
            return 1; /* not ours any more -- nothing to release */
        zg->owner_node_id = cpu_to_le16(CETRAFS_NODE_ID_NONE);
    }

    zg->hb_seq = cpu_to_le64(le64_to_cpu(zg->hb_seq) + 1);

    /* Only the hot half changed; the cold half (and its checksum) is
     * untouched and still valid. */
    zg->hot_checksum = cpu_to_le64(0);
    zg->hot_checksum = cpu_to_le64((u64) cetrafs_zg_hot_crc(image));
    return 0;
}

static int cetrafs_zg_cas(struct super_block *sb, u32 zg_id, struct cetrafs_zg_cas_ctx *ctx)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);

    if (!raw_sb)
        return -EINVAL;
    return cetrafs_cas_record(sb, le64_to_cpu(raw_sb->zg_table_start) + zg_id, cetrafs_zg_cas_mutate, ctx);
}

/*
 * Read-only ZG summary for procfs.c's "info" dump: ownership, BG span,
 * cached free-block aggregate, and journal span, all converted out of
 * their on-disk __le* form. Not used by any claiming/allocation logic
 * above -- those read cetrafs_zone_group_t fields directly, each for
 * its own narrow purpose.
 */
int cetrafs_zg_get_info(struct super_block *sb, u32 zg_id, struct cetrafs_zg_info *out)
{
    cetrafs_zone_group_t *zg = kmalloc(sizeof(*zg), GFP_KERNEL); /* heap, not stack -- see above */
    int ret;

    if (!zg)
        return -ENOMEM;

    ret = cetrafs_read_zg(sb, zg_id, zg);
    if (!ret) {
        out->owner_node_id = le16_to_cpu(zg->owner_node_id);
        out->first_bg_id = le32_to_cpu(zg->first_bg_id);
        out->bg_count = le32_to_cpu(zg->bg_count);
        out->free_data_blocks = le64_to_cpu(zg->free_data_blocks);
    }

    kfree(zg);
    return ret;
}

/*
 * Adjust ZG #zg_id's cached free_data_blocks aggregate by 'delta' and
 * restamp its checksum -- the ZG-level counterpart to alloc.c's
 * cetrafs_bg_adjust_free_blocks(), called from there (via bg->owner_zg,
 * already in hand after reading the BG descriptor) every time a BG's
 * own free_data_blocks changes.
 *
 * to close a real gap that a real
 * fallocate(FALLOC_FL_PUNCH_HOLE) test
 * concretely demonstrated via fsck: a partial punch correctly updated
 * BG0's free_data_blocks but left ZG0's own aggregate frozen at its
 * pristine mkfs-time value, so fsck's "ZG free_data_blocks == sum of
 * its BGs'" cross-check failed the moment a real net space change
 * happened (not just a write immediately undone by a matching unlink,
 * which nets to zero and never exposed this).
 *
 * Mutates bh->b_data in place (no stack copy of the full block -- same
 * reasoning as cetrafs_bg_adjust_free_blocks() and this file's own
 * cetrafs_zg_crc_verify() above) and only *marks* this ZG dirty
 * (cetrafs_sb_mark_zg_free_dirty()), deferring the actual sync to
 * cetrafs_flush_dirty_free_counts() at the same durability boundaries
 * the BG side already uses. This is not optional batching -- a plain
 * sb_bread() + unconditional sync_dirty_buffer() here (matching this
 * file's own cetrafs_write_zg(), which *does* sync every call, for its
 * much rarer ownership-change callers) would reintroduce exactly the
 * one-real-device-round-trip-per-block regression alloc.c's own
 * comment already documents having had to fix once.
 *
 * free_data_blocks is __le64 here (unlike cetrafs_block_group_t's
 * plain-native field), matching this struct's existing __le* fields
 * throughout -- see cetrafs_write_zg() for the same convention.
 */
int cetrafs_zg_adjust_free_blocks(struct super_block *sb, u32 zg_id, s64 delta)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);

    if (!raw_sb)
        return -EINVAL;
    if (zg_id >= le32_to_cpu(raw_sb->zone_group_count))
        return -EINVAL;

    /* In memory only -- see the CAS design note above for why this must
     * not dirty the ZG block. cetrafs_flush_dirty_free_counts() applies
     * the accrued total at the next durability boundary. */
    cetrafs_sb_accrue_zg_free(sb, zg_id, delta);
    return 0;
}

struct cetrafs_zg_delta_ctx {
    s64 delta;
    u32 my_node_id;
};

static int cetrafs_zg_delta_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_zg_delta_ctx *ctx = priv;
    cetrafs_zone_group_t *zg = (cetrafs_zone_group_t *) image; /* hot fields only */
    s64 cur = (s64) le64_to_cpu(zg->free_data_blocks);
    s64 want = cur + ctx->delta;

    (void) len;

    if (!ctx->delta)
        return 1; /* nothing to do */

    /*
     * Ownership, checked against the IMAGE rather than this node's
     * cached belief, and inside the compare-and-swap so the answer
     * cannot go stale between the check and the write.
     *
     * The cached check in cetrafs_flush_dirty_free_counts() catches a
     * zone group we gave up ourselves. It cannot catch one a peer TOOK:
     * a node that was declared stale still has its own ownership bit
     * set locally and has no idea the ZG has moved. Applying the delta
     * then lands on an aggregate the new owner has just reconciled from
     * the bitmaps -- which already includes these frees, because the
     * bitmaps were updated while we still owned them -- so it double
     * counts the lot.
     *
     * Dropping it is correct rather than lossy, for that same reason:
     * the member Block Groups' counters and bitmaps are durable, and
     * the new owner's reconciliation is derived from them.
     */
    if (le16_to_cpu(zg->owner_node_id) != ctx->my_node_id) {
        pr_warn("ZG free delta %lld dropped: this zone group now belongs to node %u\n", (long long) ctx->delta,
                (unsigned) le16_to_cpu(zg->owner_node_id));
        return 1;
    }
    if (want < 0) {
        /* The aggregate is a count, never negative. Getting here means
         * the deltas and the member BGs have already diverged, which
         * fsck cross-checks -- refuse rather than write a wrapped
         * u64 that would read as ~16 exabytes free. */
        pr_err("ZG free delta %lld would take the aggregate below zero (%lld)\n", (long long) ctx->delta,
               (long long) cur);
        return -EINVAL;
    }

    zg->free_data_blocks = cpu_to_le64((u64) want);
    /* free_data_blocks is a HOT field: restamp only the hot checksum.
     * The cold half is outside this CAS region entirely. */
    zg->hot_checksum = cpu_to_le64(0);
    zg->hot_checksum = cpu_to_le64((u64) cetrafs_zg_hot_crc(image));
    return 0;
}

/*
 * Apply an accrued free-block delta to a ZG record with one
 * compare-and-swap of its hot sector. Called only from
 * cetrafs_flush_dirty_free_counts().
 *
 * A CAS rather than a write because the hot sector is also where
 * ownership lives: the swap is rejected if anything (a peer's claim, a
 * concurrent release) changed the sector since the read, and the retry
 * re-applies the delta to the new image -- so a counter update can never
 * republish stale ownership.
 */
int cetrafs_zg_apply_free_delta(struct super_block *sb, u32 zg_id, s64 delta)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct cetrafs_zg_delta_ctx ctx = {.delta = delta};
    int ret;

    if (!raw_sb)
        return -EINVAL;
    if (zg_id >= le32_to_cpu(raw_sb->zone_group_count))
        return -EINVAL;
    ret = cetrafs_sb_get_node_id(sb, &ctx.my_node_id);
    if (ret)
        return ret;

    return cetrafs_cas_record(sb, le64_to_cpu(raw_sb->zg_table_start) + zg_id, cetrafs_zg_delta_mutate, &ctx);
}

/*
 * The largest size any *single* file can ever grow to (via a sparse
 * ftruncate/truncate, before a single byte of real data backs most of
 * it) -- min(MAX_LFS_FILESIZE, the total real data capacity of every
 * Zone Group on the volume).
 *
 * design correction: this used to be a deliberately
 * pessimistic *per-node* worst case -- assume the Node Registry is
 * completely full and every other possible node holds only its minimum
 * one-ZG claim, so this node is guaranteed at most the smallest
 * leftover `k` ZGs. Found, by direct report against a real two-node
 * volume (9 ZGs, 2 live nodes, the mkfs default node_table_count=64
 * registry capacity), to be not just pessimistic but *wrong*: `k`
 * collapsed to 1 regardless of how many ZGs actually existed, so a
 * 9-ZG volume with only two real nodes using it reported the same
 * max_file_size_bytes as if it had only ever had room for one. That
 * per-node "worst case" was never actually a safety requirement --
 * cetrafs_zg_claim_unowned()/cetrafs_alloc_pick_bg()'s "claim one more
 * ZG on demand, only once the ones you own are full" policy means any
 * single node really can end up owning every ZG on the volume over its
 * own mount lifetime, if no peer needs them (the single-node case is
 * the clearest example: nothing stops it from eventually claiming
 * all of them). s_maxbytes's actual job is a structural ceiling on
 * what this volume's format could ever represent, not a per-node
 * fairness guarantee -- real allocation failure when ZGs are
 * genuinely owned elsewhere is already correctly handled by the
 * ordinary block allocator returning -ENOSPC, the same as any other
 * out-of-space condition, not by this value. Total ZG capacity is also
 * simply a more honest answer to "what's the biggest this file could
 * ever become": a node that never reaches that size isn't being lied
 * to by this ceiling, it's just not needed to grow that far.
 *
 * Entirely computable from fields that are fixed at mkfs time and
 * never change at runtime (zone_group_count, each ZG's first_bg_id/
 * bg_count span, each BG's data_block_count) -- never from current
 * ownership or free-space state. That's required, not just convenient:
 * the VFS treats sb->s_maxbytes (the caller, fs.c's fill_super()) as a
 * fixed-for-the-life-of-the-mount constant, and this value must be
 * identical on every node mounting the same volume.
 *
 * O(zone_group_count + block_group_count) block reads -- fine to pay
 * once at mount time, not something any hot path calls.
 */
int cetrafs_compute_max_file_size(struct super_block *sb, loff_t *out_max)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 sum = 0, max_blocks;
    u32 zg_count, z;
    int ret;

    if (!raw_sb)
        return -EINVAL;

    zg_count = le32_to_cpu(raw_sb->zone_group_count);

    if (zg_count == 0) {
        *out_max = 0; /* degenerate: shouldn't happen in practice (mkfs
                       * always reserves >=1 ZG), but "no capacity" is
                       * the only safe answer here. */
        return 0;
    }

    for (z = 0; z < zg_count; z++) {
        struct cetrafs_zg_info info;
        u32 b;

        ret = cetrafs_zg_get_info(sb, z, &info);
        if (ret)
            return ret;

        for (b = info.first_bg_id; b < info.first_bg_id + info.bg_count; b++) {
            u64 bg_total, bg_free;

            ret = cetrafs_bg_data_block_stats(sb, b, &bg_total, &bg_free);
            if (ret)
                return ret;

            sum += bg_total;
        }
    }

    /* Clamp in block units before converting to bytes, to avoid
     * overflowing loff_t on the multiply -- real capacities are nowhere
     * near this, but MAX_LFS_FILESIZE itself is the contract either way.
     *
     * The second ceiling is the one that bites at real SAN sizes:
     * cetrafs_extent_t.ee_block is 32 bits, so the extent tree cannot
     * address a logical block past 2^32 -- 16 TiB -- no matter how much
     * capacity the volume has. Without this clamp a 17 TiB volume
     * reported 16.9 TiB, the VFS let a write through at offset 16 TiB,
     * and the logical block number truncated into the u32 and ALIASED
     * offset 0 of the same file: measured, bytes written at 16 TiB read
     * back at offset 0, with i_size happily claiming both. */
    max_blocks = (u64) MAX_LFS_FILESIZE / CETRAFS_BLOCK_SIZE;
    if (max_blocks > CETRAFS_MAX_FILE_BLOCKS)
        max_blocks = CETRAFS_MAX_FILE_BLOCKS;
    if (sum > max_blocks)
        sum = max_blocks;

    *out_max = min_t(loff_t, (loff_t) (sum * CETRAFS_BLOCK_SIZE), MAX_LFS_FILESIZE);
    return 0;
}

/*
 * Does any ZG already carry a claim belonging to a *live* node other
 * than 'my_node_id'? Used by fs.c's mount-time gate: on a device with
 * no PR support, a live foreign claim here means we have no mutex to
 * safely coexist with it, so the caller refuses the whole mount rather
 * than guessing. 'my_node_id' must be this node's real,
 * already-registered row index (not CETRAFS_NODE_ID_NONE).
 *
 * an earlier phase: a foreign claim from a node whose heartbeat has
 * gone stale does *not* count here -- there's no live owner to unsafely
 * coexist with, and treating it as one would mean a no-PR device could
 * never recover a ZG abandoned by a crashed peer without physically
 * re-partitioning the device, permanently defeating phase 13's whole
 * point for exactly the devices that need its reclaim path most (the
 * ones with no PR mutex to fall back on). A stale claim here is instead
 * left for cetrafs_zg_claim_unowned() (below) to actually reclaim, right
 * after this gate passes.
 */

/*
 * Try to claim ZG #zg_id for 'my_node_id'. Eligible if it's currently
 * unowned, or if it's owned by a *different* node whose Node Registry
 * heartbeat has gone stale for what "stale" means and its caveats).
 * Not an error if it's ineligible (owned by a node that's still alive)
 * -- *out_claimed just stays false, and this ZG's BG-data content is
 * never touched.
 *
 * Journal interaction: journals are
 * per-NODE now, so there is no per-ZG journal to replay at claim time
 * anymore. What remains is the ordering obligation on the stale-steal
 * branch: before claiming a ZG away from a stale node, that node's own
 * per-node journal is replayed (cetrafs_journal_replay_node(), under
 * this same cluster mutex) -- a surviving entry means it crashed
 * mid-operation, possibly mid-write of a metadata block in this very
 * ZG's data region, and that must be repaired before anyone builds on
 * those blocks. One-shot in practice: the dead node's journal flag goes
 * clean after the first successful replay, so stealing several of its
 * ZGs in a row pays for the scan once.
 *
 * Race safety of the claim itself: write-then-verify-readback under the
 * brief PR mutex, same as node.c's row claim -- only the node whose id
 * is confirmed present after the write ever sets *out_claimed.
 */
/*
 * Reconcile a Zone Group's free-space accounting against the bitmaps
 * that are the actual truth: every member Block Group's
 * cached count, then the ZG's own aggregate.
 *
 * WHEN this runs is the whole design. It is only correct at a moment
 * when this node provably owns the ZG and no peer can be mutating its
 * bitmaps -- which is exactly the instant ownership transfers to us,
 * and nowhere else. So it is called from cetrafs_zg_try_claim_one() on
 * a fresh claim or a steal from a stale peer, and on the re-attach path
 * ONLY at mount (a node re-attaching to its own ZG after its own crash
 * is precisely the case that needs it). It deliberately does NOT run on
 * the heartbeat tick's re-attach: that would scan every owned bitmap
 * every 15 seconds to repair something that cannot change while we hold
 * the ZG.
 *
 * The aggregate is corrected through cetrafs_zg_apply_free_delta(), a
 * compare-and-swap -- never a cached read-modify-write of the record.
 * The ZG's hot sector holds owner_node_id, maintained by CAS, and P1
 * showed that a cached update of any field in that block republishes
 * the ownership bytes as of its own read, silently reverting a peer's
 * steal with a correctly recomputed checksum. The accrued in-memory
 * delta for this ZG is zero here by construction (we have not allocated
 * from a ZG we have only just acquired), so the CAS sets it to truth.
 */
static int cetrafs_zg_reconcile_free_counts(struct super_block *sb, u32 zg_id, u32 first_bg, u32 bg_count)
{
    u64 truth = 0;
    u32 b;
    int ret;

    for (b = 0; b < bg_count; b++) {
        u64 total, free;
        s64 delta;

        ret = cetrafs_bg_reconcile_free_count(sb, first_bg + b, &delta);
        if (ret) {
            /* Never fails the claim: a ZG with an unreadable BG is
             * still better owned than left to nobody, and the ordinary
             * allocator reports the real error when it gets there. */
            pr_err("ZG %u reconcile: BG %u could not be reconciled (%d)\n", zg_id, first_bg + b, ret);
            return ret;
        }
        ret = cetrafs_bg_data_block_stats(sb, first_bg + b, &total, &free);
        if (ret)
            return ret;
        truth += free;
    }

    {
        struct cetrafs_zg_info info;
        s64 delta;

        ret = cetrafs_zg_get_info(sb, zg_id, &info);
        if (ret)
            return ret;

        delta = (s64) truth - (s64) info.free_data_blocks;
        if (delta == 0)
            return 0;

        pr_warn("ZG %u: aggregate free_data_blocks=%llu but its Block Groups hold %llu -- correcting (drift %lld)\n",
                zg_id, info.free_data_blocks, truth, delta);
        return cetrafs_zg_apply_free_delta(sb, zg_id, delta);
    }
}

static int cetrafs_zg_try_claim_one(struct super_block *sb, u32 zg_id, u32 my_node_id, bool at_mount, bool *out_claimed)
{
    cetrafs_zone_group_t *zg; /* heap, not stack -- see the comment above */
    u16 owner;
    int ret;

    *out_claimed = false;

    zg = kmalloc(sizeof(*zg), GFP_KERNEL);
    if (!zg)
        return -ENOMEM;

    /* No PR mutex around any of this any more: the claim
     * below is a single atomic compare-and-swap of the ZG's hot sector,
     * which supplies its own cross-node atomicity. The reads and the
     * staleness verdict leading up to it are advisory -- a wrong guess
     * simply makes the swap fail, never corrupt. On no-CAW hardware
     * cetrafs_cas_record() takes the cluster mutex internally for
     * exactly the old critical section. */

    ret = cetrafs_read_zg(sb, zg_id, zg);
    if (ret)
        goto out_unlock;

    owner = le16_to_cpu(zg->owner_node_id);
    if (owner == (u16) my_node_id) {
        /* re-attaching to a ZG we already owned */
        u32 cached_first, cached_count;
        bool was_cached = cetrafs_sb_zg_owned_cached(sb, zg_id, &cached_first, &cached_count);

        cetrafs_sb_cache_zg_ownership(sb, zg_id, le32_to_cpu(zg->first_bg_id), le32_to_cpu(zg->bg_count));
        ret = 0;
        /* At MOUNT this is the "our own crash" case: whatever deltas
         * this node had accrued but not applied died with it, so the
         * cached counts are the thing that needs repairing.
         * On a heartbeat tick it is just our own ZG, which nobody
         * else can have touched -- scanning every owned bitmap every
         * 15s to find nothing would be pure waste.
         *
         * The count EPOCHS need seeding when ownership ENTERS this
         * node's cache (a ZG the tick claims lazily, or one re-cached
         * after an uncache): a delta accrued under an unseeded epoch
         * would be dropped at its first flush. Only then, though --
         * exactly the argument above. Seeding on EVERY tick invalidated
         * and re-read every BG descriptor of every owned ZG, which on a
         * 2 TB volume is ~128 synchronous device reads per tick AND
         * throws away the descriptor cache that
         * cetrafs_alloc_pick_bg()/cetrafs_bg_adjust_free_blocks() read
         * on every single block allocation. Measured as a ~40% loss of
         * streaming write bandwidth on a real LUN. */
        /* PERF(5): this branch runs every heartbeat tick -- neither call
         * may become unconditional. docs/PERFORMANCE.md */
        if (at_mount)
            cetrafs_zg_reconcile_free_counts(sb, zg_id, le32_to_cpu(zg->first_bg_id), le32_to_cpu(zg->bg_count));
        else if (!was_cached)
            cetrafs_bg_seed_count_epochs(sb, le32_to_cpu(zg->first_bg_id), le32_to_cpu(zg->bg_count));
        goto out_unlock;
    }
    if (owner != CETRAFS_NODE_ID_NONE) {
        bool stale = false;

        ret = cetrafs_node_is_stale(sb, owner, &stale);
        if (ret)
            goto out_unlock;
        if (!stale) {
            ret = 0; /* owned by a node that's still alive: leave it alone */
            goto out_unlock;
        }
        pr_warn("ZG claim: reclaiming ZG %u from stale node %u\n", zg_id, owner);

        /* Before building anything on this ZG's blocks, replay the stale
         * owner's per-node journal: a surviving
         * entry means it crashed mid-operation, possibly mid-write of a
         * metadata block in this very ZG's data region -- repair that
         * first, while we already hold the cluster mutex that serializes
         * every replayer. Idempotent and one-shot (the area's own flag
         * goes clean after the first successful replay), so reclaiming
         * several of its ZGs in a row only ever pays for this once. */
        /* Revoke the stale owner's lease first: from here on we are
         * taking its state, so if it is merely slow rather than dead it
         * must fence itself the moment it notices (node.c). */
        cetrafs_node_fence_peer(sb, owner, "a zone group");

        /* We hold no cluster mutex here any more -- replay claims the
         * area itself, which is what serializes concurrent replayers. */
        ret = cetrafs_journal_replay_node(sb, owner, /*wait_for_claim=*/false);
        if (ret) {
            pr_err("ZG claim: replaying stale node %u's journal failed (%d), not claiming ZG %u\n", owner, ret, zg_id);
            goto out_unlock;
        }
    }

    {
        struct cetrafs_zg_cas_ctx ctx = {
            .my_node_id = my_node_id,
            .claim = true,
            .allow_steal = (owner != CETRAFS_NODE_ID_NONE),
            .steal_from = owner,
        };

        ret = cetrafs_zg_cas(sb, zg_id, &ctx);
        if (ret == -EBUSY) {
            pr_warn("ZG claim: lost race for ZG %u\n", zg_id);
            ret = 0;
            goto out_unlock;
        }
        if (ret)
            goto out_unlock;
    }

    *out_claimed = true;

    /* Ownership just changed hands (freshly claimed, or reclaimed from a
     * stale peer): drop any cached view this node had of this ZG's BGs
     * before trusting cetrafs_alloc_pick_bg()/alloc.c's normal cached
     * reads of them -- see cetrafs_bg_invalidate_cache()'s own comment.
     * Never reached on the "already_ours" re-attach path above, where
     * nothing could have changed since this node's own last write. Also
     * record this ZG as ours in the in-memory ownership cache, same as
     * the already_ours branch above. */
    {
        u32 first_bg = le32_to_cpu(zg->first_bg_id);
        u32 bg_count = le32_to_cpu(zg->bg_count);
        u32 b;

        for (b = 0; b < bg_count; b++)
            cetrafs_bg_invalidate_cache(sb, first_bg + b);

        cetrafs_sb_cache_zg_ownership(sb, zg_id, first_bg, bg_count);

        /* Ownership has just transferred, which is the one moment this
         * ZG's bitmaps are provably ours and provably quiet -- so it is
         * the only correct moment to check the cached free counts
         * against them. Doubly so when it was STOLEN from
         * a stale peer: that peer died with accrued deltas unapplied,
         * so its numbers are exactly the ones expected to be wrong.
         * After the invalidate above, deliberately, so the scan reads
         * the device rather than this node's stale cache. */
        cetrafs_zg_reconcile_free_counts(sb, zg_id, first_bg, bg_count);
    }

out_unlock:
    kfree(zg);

    /* No per-ZG journal replay here anymore:
     * journals are per-NODE now. This node's own area was replayed once
     * at mount (fs.c -> cetrafs_journal_attach_node()); a stale previous
     * owner's area was replayed above, before the claim write. The
     * `already_ours` re-attach path needs nothing at all -- which also
     * removes the old design's every-15s replay-and-set-clean tick that
     * silently defeated the dirty-flag protocol for the rest of the
     * session. */
    return ret;
}

/*
 * Try to claim exactly one *additional* ZG for this node -- any ZG that's
 * currently unowned or owned by a now-stale node -- stopping at the
 * first successful claim rather than taking every eligible one. This is
 * the "ask for one more only when actually needed" building block both
 * callers below are built from: a node should only ever hold as many ZGs
 * as it actually needs, so that at most zone_group_count nodes can ever
 * have write access to the volume at once, however many of them mount.
 */
/*
 * picks the *best* eligible candidate (unowned, or owned by
 * a now-stale node) to claim -- the one with the LEAST free_data_blocks,
 * i.e. already the most used-up -- rather than just the first eligible
 * one by id. This is the claim-side half of a deliberate "pack tight,
 * don't spread" policy requested alongside cetrafs_zg_release_surplus()
 * below: claiming an already-mostly-full ZG drives it to completely
 * full sooner, while any other eligible-but-emptier ZG is left alone
 * for a peer (or this same node, later) to claim instead -- the
 * opposite choice would spread this node's usage across more ZGs,
 * working directly against "keep usage concentrated, keep the rest
 * releasable." A plain read of each candidate's own cached
 * free_data_blocks (cetrafs_zg_get_info(), kept in sync by alloc.c's
 * rollup) is all this costs -- no extra writes, and only one real claim
 * attempt (the mutex-protected read-decide-write-verify in
 * cetrafs_zg_try_claim_one()) is ever made, against the chosen best
 * candidate only.
 *
 * Excludes a candidate with free_data_blocks == 0 entirely, rather
 * than treating "least free" as "most preferred" unconditionally:
 * claiming an already-completely-exhausted ZG would give this node no
 * actual capacity at all, just a wasted ownership slot and an
 * immediate repeat trip through this same on-demand-claim path for
 * nothing. Only arises from a stale node's ZG that it filled
 * completely before going stale (this policy's own release side,
 * cetrafs_zg_release_surplus(), never gives back anything but a
 * genuinely empty ZG, so a 0-free *unowned* ZG can't come from a
 * voluntary release). If literally every eligible candidate is at 0,
 * *out_claimed correctly stays false, which is what lets the caller
 * (cetrafs_alloc_pick_bg()) fall through to the real -ENOSPC this
 * cluster-wide exhaustion actually is, instead of "succeeding" at a
 * claim that solves nothing.
 */
static int cetrafs_zg_claim_one_more(struct super_block *sb,
                                     const cetrafs_superblock_t *raw_sb,
                                     u32 my_node_id,
                                     bool *out_claimed)
{
    u32 count, z, best_z = 0;
    u64 best_free = 0;
    bool have_best = false;
    int ret;

    *out_claimed = false;
    count = le32_to_cpu(raw_sb->zone_group_count);

    for (z = 0; z < count; z++) {
        struct cetrafs_zg_info info;
        bool stale;

        ret = cetrafs_zg_get_info(sb, z, &info);
        if (ret)
            return ret;

        if (info.owner_node_id == my_node_id)
            continue; /* already ours -- not a claim candidate */

        if (info.owner_node_id != CETRAFS_NODE_ID_NONE) {
            ret = cetrafs_node_is_stale(sb, info.owner_node_id, &stale);
            if (ret)
                return ret;
            if (!stale)
                continue; /* live foreign owner: not eligible */
        }

        /*
         * Prefer the candidate with the least free space -- concentrating
         * usage is what lets cetrafs_zg_release_surplus() ever find a ZG
         * that has drained completely empty.
         *
         * A candidate whose aggregate reads ZERO used to be skipped
         * outright, on the grounds that claiming it would gain nothing.
         * That aggregate is not authoritative enough to exclude on: it is
         * accrued and flushed at durability boundaries, so a node that
         * freed blocks and then crashed leaves it understating the ZG's
         * real free space -- possibly as 0 while every member BG is in
         * fact empty. Excluded forever, that space becomes permanently
         * unreachable by any node. It is now ranked LAST instead, so it
         * is still avoided whenever anything better exists, and
         * cetrafs_alloc_pick_bg()'s own BG scan after the claim settles
         * what is really there.
         */
        if (!have_best || (info.free_data_blocks > 0 && best_free == 0) ||
            (info.free_data_blocks < best_free && !(best_free > 0 && info.free_data_blocks == 0))) {
            best_z = z;
            best_free = info.free_data_blocks;
            have_best = true;
        }
    }

    if (!have_best)
        return 0;

    return cetrafs_zg_try_claim_one(sb, best_z, my_node_id, /*at_mount=*/false, out_claimed);
}

/*
 * this used to eagerly claim *every* ZG this
 * node was eligible for (unowned, or stale-owned) in one pass -- correct
 * in isolation, but wrong for the actual clustering model this project
 * targets. The intent (per CLAUDE.md) is that each node holds only the
 * ZG(s) it actually needs as its own write-allocation pool, claiming one
 * more only once it runs low -- not however many happen to be unclaimed
 * the instant it first mounts. The old behavior meant the very first
 * node to ever mount a fresh volume (or the first to remount after every
 * ZG went stale) walked away owning the *entire* disk, permanently
 * starving every node that mounted after it of any write-allocation
 * capacity at all -- observed directly via /proc/fs/cetrafs/<dev>/info
 * showing one node owning 100% of a multi-ZG volume.
 *
 * Fixed with two passes:
 *
 *   1. Re-attach to every ZG this node *already* owns (unconditional,
 *      every call) -- this never claims anything new, but still has to
 *      run cetrafs_zg_try_claim_one()'s "already_ours" branch for each,
 *      since that's what triggers journal replay for a ZG this node
 *      owned across its own crash/remount. Skipping
 *      this pass would silently stop recovering an already-owned ZG's
 *      outstanding journal entries on remount.
 *
 *   2. Only if this node ends pass 1 owning *zero* ZGs -- a brand-new
 *      node joining the cluster, or one that mounted when every ZG
 *      happened to be live-owned by others -- claim exactly *one* more
 *      via cetrafs_zg_claim_one_more() above. Never more than one here,
 *      and never attempted at all if this node already owns at least
 *      one: holding more than the current minimum is now exclusively an
 *      on-demand decision, made by cetrafs_alloc_pick_bg() below when it
 *      actually runs out of space in what this node already owns, not a
 *      speculative land-grab at mount/heartbeat time.
 *
 * Called once at mount (fs.c) and again on every heartbeat.c tick while
 * mounted -- the repeated calls are what let a node that joined owning
 * zero ZGs eventually pick one up once a peer's abandoned ZG goes stale,
 * without needing to remount to retry. Never fails over a lost per-ZG
 * race or an ineligible ZG -- that's all normal clustering behavior --
 * only a hard I/O/CRC error propagates.
 */
/*
 * For the background scrub (scrub.c): find ONE ZG owned by a STALE (dead)
 * peer and adopt it, so the next owned-ZG scrub pass covers it. Such ZGs are
 * where dropped-free leaks accumulate yet nobody is scrubbing -- the normal
 * reclaim (cetrafs_zg_claim_unowned) only takes a stale ZG when this node
 * owns zero, so a node with its own ZG never touches a dead peer's.
 *
 * UNOWNED (owner=none) ZGs are deliberately skipped: a ZG carrying a leak is
 * never empty, so it is never released to unowned -- unowned ZGs are leak-
 * free, and claiming one would just hoard capacity for nothing.
 *
 * One per call bounds churn and, more importantly, spurious fencing: adopting
 * a stale ZG fences its owner (cetrafs_zg_try_claim_one), and a merely-slow
 * (not dead) peer looks stale -- the same split-brain caveat every reclaim
 * here carries. Doing at most one per scrub cycle (30 min apart by default)
 * keeps the scrub from aggressively fencing a peer that is just slow.
 */
int cetrafs_zg_scrub_adopt_one_stale(struct super_block *sb, bool *out_adopted)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 zg_count, z, my_id;

    *out_adopted = false;
    if (!raw_sb)
        return -EINVAL;
    if (cetrafs_sb_get_node_id(sb, &my_id) != 0)
        return -EINVAL;
    zg_count = le32_to_cpu(raw_sb->zone_group_count);

    for (z = 0; z < zg_count; z++) {
        struct cetrafs_zg_info info;
        bool stale = false, claimed = false;
        u32 fb, bc;

        if (cetrafs_sb_zg_owned_cached(sb, z, &fb, &bc))
            continue; /* already ours -- the owned-ZG pass covers it */
        if (cetrafs_zg_get_info(sb, z, &info) != 0)
            continue;
        if (info.owner_node_id == CETRAFS_NODE_ID_NONE || info.owner_node_id == my_id)
            continue; /* unowned (leak-free) or us */
        if (cetrafs_node_is_stale(sb, info.owner_node_id, &stale) != 0 || !stale)
            continue; /* a LIVE peer owns it -- its own scrub covers it */

        if (cetrafs_zg_try_claim_one(sb, z, my_id, /*at_mount=*/false, &claimed) == 0 && claimed) {
            *out_adopted = true;
            return 0;
        }
    }
    return 0;
}

int cetrafs_zg_claim_unowned(struct super_block *sb,
                             u32 my_node_id,
                             const u8 my_uuid[CETRAFS_NODE_UUID_LEN],
                             bool at_mount)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    cetrafs_zone_group_t *zg;
    u32 count, z, owned = 0, claimed_new = 0;
    int ret;

    (void) my_uuid; /* no cluster-mutex key needed: claims are CAS now */

    if (!raw_sb)
        return -EINVAL;

    count = le32_to_cpu(raw_sb->zone_group_count);

    zg = kmalloc(sizeof(*zg), GFP_KERNEL); /* heap, not stack -- see above */
    if (!zg)
        return -ENOMEM;

    /* Pass 1: re-attach to (and replay) every ZG we already own; claims
     * nothing new.
     *
     * skip the real disk read + cluster-mutex dance entirely
     * for a ZG this node's in-memory cache already confirms it owns --
     * found via real two-node testing, timing instrumentation showing
     * heartbeat.c's periodic tick (every CETRAFS_HEARTBEAT_INTERVAL_SECS,
     * calling this same function) paying for a device round trip per
     * owned ZG, every single tick, purely to reconfirm something that
     * cannot have changed: a live node's ZG ownership cannot be taken by
     * a peer (only a *stale* node's can), so there is nothing to
     * discover for a ZG already in the cache. Only a ZG *not yet* in the
     * cache (first call ever, after a crash/remount, or genuinely
     * unowned/stale) still needs the real read -- that path is
     * unchanged, and still populates the cache on success so every
     * later tick for that same ZG takes this fast path too. */
    for (z = 0; z < count; z++) {
        bool did_claim;
        u32 unused_first_bg, unused_bg_count;

        if (cetrafs_sb_zg_owned_cached(sb, z, &unused_first_bg, &unused_bg_count)) {
            owned++;
            continue;
        }

        ret = cetrafs_read_zg(sb, z, zg);
        if (ret)
            goto out;

        if (le16_to_cpu(zg->owner_node_id) != (u16) my_node_id)
            continue;

        owned++;

        ret = cetrafs_zg_try_claim_one(sb, z, my_node_id, at_mount, &did_claim);
        if (ret)
            goto out;
        /* did_claim is always false here (already ours); replay already
         * ran inside cetrafs_zg_try_claim_one()'s already_ours branch. */
    }

    /* Pass 2: only if we own nothing at all yet, claim exactly one. */
    if (owned == 0) {
        bool did_claim = false;

        ret = cetrafs_zg_claim_one_more(sb, raw_sb, my_node_id, &did_claim);
        if (ret)
            goto out;
        if (did_claim)
            claimed_new = 1;
    }

    /* Once per mount this is lifecycle information, and a NEW claim is a
     * real cluster event (a steal logs its own fence line besides) -- but
     * repeating the unchanged count on every heartbeat tick was one dmesg
     * line per 15s for the life of every mount. */
    if (at_mount || claimed_new)
        pr_info("ZG claim: own %u of %u zone group(s) (%s)\n", owned + claimed_new, count,
                cetrafs_sb_caw_available(sb) ? "atomic CAS" : "no-CAW fallback");
    else
        pr_debug("ZG claim: own %u of %u zone group(s)\n", owned + claimed_new, count);
    ret = 0;

out:
    kfree(zg);
    return ret;
}

/* Is every member BG of a ZG spanning [first_bg, first_bg+bg_count)
 * completely empty (free_data_blocks == data_block_count, i.e. zero
 * live data anywhere in it)? Shared by cetrafs_zg_release_surplus()'s
 * scan and cetrafs_zg_try_release_one()'s own re-check immediately
 * before writing. */
static int cetrafs_zg_is_fully_empty(struct super_block *sb, u32 first_bg, u32 bg_count, bool *out_empty)
{
    u32 bg;

    *out_empty = true;
    for (bg = first_bg; bg < first_bg + bg_count; bg++) {
        u64 total, free;
        int ret = cetrafs_bg_data_block_stats(sb, bg, &total, &free);

        if (ret)
            return ret;
        if (free != total) {
            *out_empty = false;
            return 0;
        }
    }
    return 0;
}

/*
 * Try to release ZG #zg_id -- the release-side mirror of
 * cetrafs_zg_try_claim_one() above. Re-verifies both that it's still
 * owned by 'my_node_id' and still completely empty immediately before
 * writing (the same "decide right before you act" shape the claim path
 * already uses) -- not an error if either has changed since the
 * caller's own check (already released, reclaimed by someone else, or
 * a local allocation landed in it in the meantime); *out_released just
 * stays false.
 */
static int cetrafs_zg_try_release_one(struct super_block *sb, u32 zg_id, u32 my_node_id, bool *out_released)
{
    cetrafs_zone_group_t *zg; /* heap, not stack -- see the comment above */
    bool empty;
    int ret;

    *out_released = false;

    zg = kmalloc(sizeof(*zg), GFP_KERNEL);
    if (!zg)
        return -ENOMEM;

    /* No PR mutex around any of this any more: the claim
     * below is a single atomic compare-and-swap of the ZG's hot sector,
     * which supplies its own cross-node atomicity. The reads and the
     * staleness verdict leading up to it are advisory -- a wrong guess
     * simply makes the swap fail, never corrupt. On no-CAW hardware
     * cetrafs_cas_record() takes the cluster mutex internally for
     * exactly the old critical section. */

    ret = cetrafs_read_zg(sb, zg_id, zg);
    if (ret)
        goto out_unlock;

    if (le16_to_cpu(zg->owner_node_id) != (u16) my_node_id) {
        ret = 0; /* no longer ours -- nothing to release */
        goto out_unlock;
    }

    ret = cetrafs_zg_is_fully_empty(sb, le32_to_cpu(zg->first_bg_id), le32_to_cpu(zg->bg_count), &empty);
    if (ret)
        goto out_unlock;
    if (!empty) {
        ret = 0; /* a local allocation landed here since the caller checked */
        goto out_unlock;
    }

    {
        /* One CAS gives it back: it only lands while the record still
         * shows OUR ownership, so a ZG reclaimed from us meanwhile (a
         * stale-peer steal) is left alone rather than blindly cleared. */
        struct cetrafs_zg_cas_ctx ctx = {.my_node_id = my_node_id, .claim = false};

        ret = cetrafs_zg_cas(sb, zg_id, &ctx);
        if (ret) {
            pr_warn("ZG release: ZG %u not released (%d)\n", zg_id, ret);
            ret = 0;
            goto out_unlock;
        }
    }

    *out_released = true;
    pr_info("ZG release: gave back ZG %u (empty, surplus to this node's needs)\n", zg_id);
    cetrafs_sb_uncache_zg_ownership(sb, zg_id);

out_unlock:
    kfree(zg);
    return ret;
}

/*
 * The release-side counterpart to cetrafs_zg_claim_one_more(), added
 * at direct request once this project's "claim the minimum,
 * grow on demand" policy made it obvious a node could also end up
 * holding more ZGs than it still needs -- e.g. after deleting whatever
 * made it claim extra capacity in the first place. Gives back every
 * currently-owned ZG that's completely empty, down to but never below
 * one: a node must never voluntarily end up owning zero ZGs.
 *
 * Only actually reachable in practice because of the companion "pack
 * tight, don't spread" changes made alongside it: cetrafs_alloc_pick_
 * bg() now prefers the owned BG with the LEAST free space (not the
 * first with any), and cetrafs_zg_claim_one_more() now prefers the
 * eligible claim candidate with the LEAST free space too. Both exist
 * so a node's own usage concentrates into as few ZGs as possible --
 * without that, ordinary even spreading across every owned ZG would
 * mean none of them ever goes back to fully empty after its first use,
 * and this function would have nothing to do.
 *
 * Releasing doesn't endanger any data: ownership only gates which ZG a
 * node may allocate *new* blocks from -- reading, writing, or freeing
 * an existing block never checks current ownership (alloc.c's
 * cetrafs_free_data_block() resolves a block's BG purely from its
 * LBA). This only ever releases a ZG with zero live data anyway, both
 * because that's the only state this policy is confident is truly
 * surplus and because it sidesteps the question of "is releasing a ZG
 * with live data in it actually safe" entirely.
 *
 * Called from heartbeat.c's tick, right after cetrafs_zg_claim_
 * unowned() -- same cadence as the claim side. Unlike the claim side's
 * "at most one new ZG per call" (claiming speculatively was the actual
 * bug cetrafs_zg_claim_unowned()'s own design-correction fixed --
 * starving other nodes of scarce shared capacity), this may release
 * more than one ZG per call: giving back everything genuinely surplus
 * has no equivalent fairness risk, and releasing sooner is strictly
 * better for a peer that actually needs the capacity.
 */
int cetrafs_zg_release_surplus(struct super_block *sb, u32 my_node_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 zg_count, z, owned_count = 0;
    int ret;

    if (!raw_sb)
        return -EINVAL;

    zg_count = le32_to_cpu(raw_sb->zone_group_count);

    for (z = 0; z < zg_count; z++) {
        u32 first_bg, bg_count;

        if (cetrafs_sb_zg_owned_cached(sb, z, &first_bg, &bg_count))
            owned_count++;
    }

    if (owned_count <= 1)
        return 0; /* nothing surplus to give back */

    /*
     * Flush before giving anything back.
     *
     * Emptiness is judged from the member Block Groups' counters, which
     * are updated in the buffer the moment blocks are freed -- so a ZG
     * reads fully empty while its own aggregate delta is still accrued
     * in memory. Releasing there leaves that delta to be applied later,
     * by cetrafs_flush_dirty_free_counts(), to a Zone Group this node no
     * longer owns: harmless on one node, and on a cluster a double
     * count, because whoever claimed it in the meantime reconciled the
     * aggregate from the bitmaps -- which already include these frees.
     */
    ret = cetrafs_flush_dirty_free_counts(sb);
    if (ret)
        return ret;

    for (z = 0; z < zg_count && owned_count > 1; z++) {
        u32 first_bg, bg_count;
        bool empty, did_release;

        if (!cetrafs_sb_zg_owned_cached(sb, z, &first_bg, &bg_count))
            continue;

        ret = cetrafs_zg_is_fully_empty(sb, first_bg, bg_count, &empty);
        if (ret)
            return ret;
        if (!empty)
            continue;

        /* A delta accrued since the flush above: another thread freed
         * into this ZG while we were looking at it. Leave it owned and
         * release it on a later tick, rather than stranding the delta. */
        if (cetrafs_sb_zg_delta_pending(sb, z))
            continue;

        ret = cetrafs_zg_try_release_one(sb, z, my_node_id, &did_release);
        if (ret)
            return ret;

        if (did_release)
            owned_count--;
    }

    return 0;
}

/* --- Pending-free queues ---------------------
 *
 * A node freeing a data block whose BG belongs to someone else's ZG (or
 * to no one) must never RMW that BG's bitmap/counters itself -- the
 * owner may be concurrently allocating from the very same bitmap block,
 * and whichever node's write-back lands last silently reverts the
 * other's bit flips (the owner's lost allocations then get handed out
 * AGAIN to a different file later: silent cross-file corruption; see
 * see alloc.c for the full analysis). Instead the freeing node appends
 * a {lba, count} entry to the owning ZG's small on-disk queue
 * (sb.pending_free_start, CETRAFS_PENDING_FREE_BLOCKS_PER_ZG blocks per
 * ZG, zero-filled by mkfs) under the cluster mutex, and the owner
 * applies it to its own bitmaps -- at mount, at claim, and on every
 * heartbeat tick. The queue block itself is only ever RMW'd under the
 * cluster mutex (appenders and the draining owner alike), so it has no
 * concurrent-writer problem of its own; reads of it are always uncached
 * for the same reason as every other cross-node-shared structure.
 *
 * Crash safety: an appender syncs the entry before returning (a crash
 * before that loses the free -- a bounded leak, same class as crashing
 * before evict ever ran). The drain applies entries BEFORE zeroing the
 * queue block, and applying is idempotent (alloc.c's
 * cetrafs_apply_pending_free() only clears+counts a bit that's actually
 * set), so a crash between apply and consume re-applies harmlessly.
 */

static int cetrafs_zg_queue_span(struct super_block *sb, u32 zg_id, u64 *out_start, u32 *out_blocks)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);

    if (!raw_sb)
        return -EINVAL;
    if (zg_id >= le32_to_cpu(raw_sb->zone_group_count))
        return -EINVAL;

    *out_blocks = le32_to_cpu(raw_sb->pending_free_blocks_per_zg);
    *out_start = le64_to_cpu(raw_sb->pending_free_start) + (u64) zg_id * *out_blocks;
    return 0;
}

/* --- the queue as CAS-able slot arrays --------------------------------
 *
 * A pending-free entry is a fixed-size {lba, count, magic} record in a
 * fixed slot array, which is precisely the shape a compare-and-swap
 * wants: appending is "swap an empty slot for a filled one" and
 * consuming is "swap a filled slot back to empty". So neither side needs
 * the device-wide mutex any more.
 *
 * That mutex was the last PR consumer on a hot path, and it was an
 * expensive one: dir-storm has each node unlink the PEER's files, whose
 * blocks live in the peer's ZG, so EVERY free is a foreign free. On the
 * real LUN that measured ~48 ms to lock plus ~48 ms to unlock per
 * extent -- about 96 ms per unlink, which was essentially the whole
 * teardown phase.
 *
 * A CAS covers one region (cetrafs_cas_region_size(), a logical block --
 * 512 B on the real LUN, so 32 slots), not the whole 4 KiB block, so the
 * queue is walked region by region.
 */
#define CETRAFS_PF_PER_REGION(sb) (cetrafs_cas_region_size(sb) / sizeof(cetrafs_pending_free_t))

struct cetrafs_pf_append_ctx {
    u64 lba;
    u32 count;
};

static int cetrafs_pf_append_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_pf_append_ctx *ctx = priv;
    cetrafs_pending_free_t *ent = image;
    unsigned int slots = len / sizeof(*ent);
    unsigned int e;

    /* Re-finds a free slot in whatever image the CAS hands back, so a
     * lost race simply lands in a different slot on the retry -- the
     * same shape as alloc.c's bitmap CAS. */
    for (e = 0; e < slots; e++) {
        if (ent[e].lba != 0)
            continue;
        ent[e].lba = cetrafs_cpu_to_le64(ctx->lba);
        ent[e].count = cetrafs_cpu_to_le32(ctx->count);
        ent[e].magic = cetrafs_cpu_to_le32(CETRAFS_PENDING_FREE_MAGIC);
        return 0;
    }
    return -EEXIST; /* this region is full; the caller tries the next */
}

/* How many times a foreign free was appended to a peer's pending-free
 * queue. This path is UNREACHABLE on the single-node loop harness by
 * construction (a volume with no atomic CAW admits one mounter, so there is
 * no foreign owner to queue for -- every free takes the direct fast path),
 * so this counter is the only thing that confirms the append path runs at
 * all: it rises only on a real multi-node volume. ctest's dir-storm, where
 * each node unlinks the files the OTHER node created, drives it. Exposed in
 * procfs 'info' so a two-node run can assert it moved. */
static atomic64_t cetrafs_pending_appends = ATOMIC64_INIT(0);
u64 cetrafs_pending_free_append_count(void)
{
    return (u64) atomic64_read(&cetrafs_pending_appends);
}

/*
 * Freeze the forensic state of a foreign-free leak in the log. By the time
 * anyone inspects a recovered cluster, the owner that was not draining may
 * be back online and look perfectly healthy -- so capture, at THIS instant,
 * who owns the ZG, whether it was stale, its last heartbeat, and how long
 * ago that was. Without this the only evidence is "owner not draining?" and
 * a node that has since recovered.
 */
static void cetrafs_zg_log_foreign_free_leak(struct super_block *sb, u32 zg_id, u64 lba, u32 count)
{
    struct cetrafs_zg_info zi;
    cetrafs_node_entry_t row;
    bool stale = false;
    u32 my_id = CETRAFS_NODE_ID_NONE, owner = CETRAFS_NODE_ID_NONE;
    s64 now = ktime_get_real_seconds();

    cetrafs_sb_get_node_id(sb, &my_id);
    if (cetrafs_zg_get_info(sb, zg_id, &zi) == 0)
        owner = zi.owner_node_id;
    cetrafs_node_is_stale(sb, owner, &stale);

    if (owner != CETRAFS_NODE_ID_NONE && cetrafs_node_get_entry(sb, owner, &row) == 0)
        pr_err(
            "pending free LEAK: ZG %u queue full, DROPPING [%llu +%u). owner=node %u "
            "state=%u hb_seq=%llu last_seen=%lld (%llds ago, now=%lld) stale=%s; this=node %u. "
            "Blocks stay allocated until the owner drains or fsck -r reclaims them.\n",
            zg_id, (unsigned long long) lba, count, owner, cetrafs_le32(row.state),
            (unsigned long long) cetrafs_le64(row.hb_seq), (long long) cetrafs_le64(row.last_seen),
            (long long) (now - (s64) cetrafs_le64(row.last_seen)), (long long) now, stale ? "YES" : "no", my_id);
    else
        pr_err(
            "pending free LEAK: ZG %u queue full, DROPPING [%llu +%u). owner=node %u (row unreadable) "
            "stale=%s; this=node %u.\n",
            zg_id, (unsigned long long) lba, count, owner, stale ? "YES" : "no", my_id);
}

/* How long a ZG's queue is remembered as full before another append is
 * allowed to scan it. The owner drains on its own heartbeat tick, so
 * nothing is lost by not looking in between -- and looking costs
 * qblocks * regions device round trips per extent. 0 disables the
 * memory entirely, which is the negative control the test uses. */
static unsigned int cetrafs_pf_full_backoff_ms = 1000;
module_param_named(pf_full_backoff_ms, cetrafs_pf_full_backoff_ms, uint, 0644);
MODULE_PARM_DESC(pf_full_backoff_ms, "ms to skip scanning a pending-free queue known to be full (0 = always scan)");

/* Test-only: behave as if every foreign queue were full, so the drop
 * path can be exercised without a second node filling the queue. */
static bool cetrafs_pf_force_queue_full;
module_param_named(pf_force_queue_full, cetrafs_pf_force_queue_full, bool, 0644);
MODULE_PARM_DESC(pf_force_queue_full, "test-only: treat every pending-free queue as full");

static atomic64_t cetrafs_pf_full_scans = ATOMIC64_INIT(0);
/* Queue blocks actually read by drain passes. The drain runs on every
 * heartbeat tick for every owned ZG, so this is the number that must
 * stay proportional to how full the queue is, not to how big it is. */
static atomic64_t cetrafs_pf_drain_blocks = ATOMIC64_INIT(0);
static atomic64_t cetrafs_pf_drop_runs = ATOMIC64_INIT(0);
static atomic64_t cetrafs_pf_drop_blocks = ATOMIC64_INIT(0);

u64 cetrafs_pf_full_scans_count(void)
{
    return (u64) atomic64_read(&cetrafs_pf_full_scans);
}
u64 cetrafs_pf_drain_blocks_count(void)
{
    return (u64) atomic64_read(&cetrafs_pf_drain_blocks);
}
u64 cetrafs_pf_drop_runs_count(void)
{
    return (u64) atomic64_read(&cetrafs_pf_drop_runs);
}
u64 cetrafs_pf_drop_blocks_count(void)
{
    return (u64) atomic64_read(&cetrafs_pf_drop_blocks);
}

int cetrafs_zg_queue_foreign_free(struct super_block *sb, u32 zg_id, u64 lba, u32 count)
{
    struct cetrafs_pf_append_ctx ctx = {.lba = lba, .count = count};
    unsigned int regions = CETRAFS_BLOCK_SIZE / cetrafs_cas_region_size(sb);
    u64 qstart;
    u32 qblocks, qb;
    int ret;

    ret = cetrafs_zg_queue_span(sb, zg_id, &qstart, &qblocks);
    if (ret)
        return ret;

    /* Known full: do not scan. The scan is qblocks * regions device
     * round trips and it just failed; the owner drains on its own tick,
     * not because we looked again. Deleting one large image is tens of
     * thousands of extents, and paying the full scan for each is what
     * makes the filesystem feel stopped. */
    if (cetrafs_sb_zg_pf_backoff_active(sb, zg_id))
        goto queue_full;

    for (qb = 0; qb < qblocks; qb++) {
        unsigned int r;

        for (r = 0; r < regions; r++) {
            /* Test-only: behave as a full region. Deliberately inside
             * the loop, so the SCAN still happens and is counted --
             * modelling a queue that is full, not one that is skipped.
             * The CAS is not issued, so the test does not pay for I/O
             * it is only counting. */
            if (cetrafs_pf_force_queue_full)
                continue;
            ret = cetrafs_cas_region(sb, qstart + qb, r, cetrafs_pf_append_mutate, &ctx);
            if (ret == 0) {
                u64 runs, blocks;

                atomic64_inc(&cetrafs_pending_appends);
                /* Space again: say what the burst cost, once. */
                if (cetrafs_sb_zg_pf_take_drops(sb, zg_id, &runs, &blocks))
                    pr_warn("pending free: ZG %u queue drained; %llu run(s)/%llu block(s) "
                            "were dropped while it was full and stay allocated until the "
                            "owner's scrub or fsck -r reclaims them\n",
                            zg_id, (unsigned long long) runs, (unsigned long long) blocks);
                return 0;
            }
            if (ret == -EEXIST || ret == -EBUSY)
                continue; /* region full, or lost the race too often: move on */
            return ret;
        }
    }

    /* One scan of every slot in the ZG's queue, completed without
     * finding space. This is the cost the backoff exists to stop
     * repeating: qblocks * regions device round trips, per extent. */
    atomic64_inc(&cetrafs_pf_full_scans);

queue_full:
    /*
     * Every slot across the ZG's queue is taken. The owner drains every
     * heartbeat tick, so the queue is only full because the owner is
     * STALE (offline/crashed -- its queue will never drain) or a delete
     * burst briefly outran the 15 s drain.
     *
     * If the owner is stale, reclaim the ZG: cetrafs_zg_try_claim_one()
     * only steals a stale (or unowned) owner's ZG, so this is a no-op
     * against a live owner. Reclaiming makes this node the owner, so the
     * backlog drains on our next tick and the caller can free DIRECTLY
     * (we signal that with -EAGAIN). This is exactly the case that bit a
     * real cluster: an owner powered off, a peer deleted its files, and
     * every free past the first 1024 leaked for the whole outage.
     */
    {
        u32 my_node_id, fb, bc;
        bool claimed = false;

        /* pf_force_queue_full models the PRODUCTION case: a full queue
         * whose owner is alive and simply has not drained yet. The
         * reclaim below only succeeds against a stale or unowned ZG --
         * which on a single-node harness is always -- so without this
         * the drop path is unreachable and the test silently measures
         * the direct free instead. */
        if (!cetrafs_pf_force_queue_full && cetrafs_sb_get_node_id(sb, &my_node_id) == 0) {
            cetrafs_zg_try_claim_one(sb, zg_id, my_node_id, /*at_mount=*/false, &claimed);
            if (cetrafs_sb_zg_owned_cached(sb, zg_id, &fb, &bc))
                return -EAGAIN; /* reclaimed -- caller frees directly */
        }
    }

    /*
     * Owner is alive but not draining fast enough (a burst). A loud,
     * bounded leak -- the blocks stay marked allocated, never a silent
     * loss -- with the owner's state frozen in the log, since by the
     * time anyone inspects it the owner may have recovered.
     */
    /* Count every drop; do the EXPENSIVE diagnostic only on the first of
     * a burst. The full message reads the ZG record and the owner's
     * registry row -- two device round trips -- and is worth it once,
     * to name who was not draining and whether they were alive. Tens of
     * thousands of copies of it are just a console storm on a path that
     * is already failing. The rest are summarised when the queue drains
     * (see the append path above) or at unmount. */
    atomic64_inc(&cetrafs_pf_drop_runs);
    atomic64_add(count, &cetrafs_pf_drop_blocks);
    if (cetrafs_sb_zg_pf_note_drop(sb, zg_id, count, cetrafs_pf_full_backoff_ms))
        cetrafs_zg_log_foreign_free_leak(sb, zg_id, lba, count);
    return -ENOSPC;
}

/* What one drain pass is consuming from a single region. 'consumed[i]'
 * is filled by the mutate -- reset on every attempt, so after the CAS
 * lands it reflects what the WINNING swap actually removed from the
 * queue: only those entries may be applied. (The CAS impl maps a
 * mutate's "nothing to do" to plain success, so the return value cannot
 * distinguish "I consumed these" from "another drain beat me to them" --
 * and applying the latter is the double-apply this ordering exists to
 * prevent.) */
struct cetrafs_pf_drain_ctx {
    u32 n;
    struct {
        u64 lba;
        u32 count;
    } done[CETRAFS_PENDING_FREE_PER_BLOCK];
    bool consumed[CETRAFS_PENDING_FREE_PER_BLOCK];
};

static int cetrafs_pf_drain_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_pf_drain_ctx *ctx = priv;
    cetrafs_pending_free_t *ent = image;
    unsigned int slots = len / sizeof(*ent);
    unsigned int e, i;
    bool changed = false;

    /* Reset per attempt: a retry runs on a FRESH image, and what this
     * swap consumes is only what it finds there. */
    memset(ctx->consumed, 0, sizeof(ctx->consumed));

    for (e = 0; e < slots; e++) {
        if (ent[e].lba == 0)
            continue;

        /* Garbage is cleared on sight -- leaving it would wedge the
         * queue forever, since nothing can ever apply it. */
        if (cetrafs_le32(ent[e].magic) != CETRAFS_PENDING_FREE_MAGIC || cetrafs_le32(ent[e].count) == 0) {
            memset(&ent[e], 0, sizeof(ent[e]));
            changed = true;
            continue;
        }

        /* Clear only what this pass set out to consume. An entry a PEER
         * appended between our read and this CAS is left completely
         * alone -- consuming it here would lose a free outright. Each
         * ctx entry pairs with at most ONE image slot (skip the already
         * -consumed), so DUPLICATE queue entries -- same lba, same count,
         * legal and produced by double frees this layer tolerates -- each
         * consume their own slot and each get their (idempotent) apply. */
        for (i = 0; i < ctx->n; i++) {
            if (!ctx->consumed[i] && ctx->done[i].lba == cetrafs_le64(ent[e].lba) &&
                ctx->done[i].count == cetrafs_le32(ent[e].count)) {
                memset(&ent[e], 0, sizeof(ent[e]));
                ctx->consumed[i] = true;
                changed = true;
                break;
            }
        }
    }

    return changed ? 0 : 1; /* 1 = nothing to do, not an error */
}

/*
 * Drain one ZG's queue: CAS the entries OUT of the queue first, then
 * apply exactly what that swap consumed. Lock-free -- see the append
 * path's comment.
 *
 * The CONSUME-before-apply order is deliberate, and it REVERSES the
 * original design. Apply-first rested on "applying is idempotent
 * (the apply tests each bit before clearing it), so a crash between the
 * two just re-applies" -- which is true per drain and FALSE across a
 * reallocation: when the consume CAS loses its race (concurrent
 * appenders rewriting the same 512-byte region kept it -EBUSY under
 * load), the already-applied entries survived in the queue, the owner
 * reallocated the freed block to a live file, and the next drain's
 * "idempotent" re-apply cleared a LIVE block's bit. Caught by ns-fuzz
 * on the 3-node cluster: fsck's "block referenced by an
 * inode but marked FREE" was exactly one applied-but-unconsumed entry.
 *
 * Consume-first makes the failure mode a LEAK instead: a crash (or a
 * lost CAS) between consuming and applying leaves the blocks bitmap-set
 * and referenced by nothing, which the background scrub reclaims --
 * rule 8's safe direction. A lost consume CAS now simply applies
 * nothing and leaves the entries for the next pass.
 */
static int cetrafs_zg_drain_one(struct super_block *sb, u32 zg_id)
{
    unsigned int region_sz = cetrafs_cas_region_size(sb);
    unsigned int regions = CETRAFS_BLOCK_SIZE / region_sz;
    unsigned int slots = region_sz / sizeof(cetrafs_pending_free_t);
    struct cetrafs_pf_drain_ctx *ctx;
    u64 qstart;
    u32 qblocks, qb, applied = 0, empty_run = 0;
    int ret;

    ret = cetrafs_zg_queue_span(sb, zg_id, &qstart, &qblocks);
    if (ret)
        return ret;

    ctx = kmalloc(sizeof(*ctx), GFP_NOFS);
    if (!ctx)
        return -ENOMEM;

    /* Cost must follow OCCUPANCY, not capacity. This runs on every
     * heartbeat tick for every owned ZG, and the queue is large enough
     * to absorb a whole image's worth of frees -- scanning all of it
     * every tick is the per-tick whole-table sweep PERFORMANCE.md
     * invariant 5 forbids, and it starves the rest of the tick.
     *
     * Appends fill from the front (cetrafs_zg_queue_foreign_free scans
     * block 0 upward for the first free slot), so occupancy is
     * front-loaded and a run of empty blocks means the rest is empty
     * too. Stop after CETRAFS_PF_DRAIN_EMPTY_RUN of them. An entry
     * appended behind the stop point, or missed because a region was
     * busy, is drained on the next tick -- a delay, never a lost free.
     */
    for (qb = 0; qb < qblocks && !ret; qb++) {
        struct buffer_head *bh;
        bool block_had_entries = false;
        unsigned int r;

        /* ONE forced read per block, not one per region: the block was
         * being re-read `regions` times over, so the whole queue cost
         * qblocks * regions device round trips per tick. The CAS below
         * re-reads the region itself anyway -- this read only decides
         * whether a region is worth a swap. */
        bh = cetrafs_bread_uncached_retry(sb, qstart + qb);
        atomic64_inc(&cetrafs_pf_drain_blocks);
        if (!bh) {
            ret = -EIO;
            break;
        }

        for (r = 0; r < regions; r++) {
            const cetrafs_pending_free_t *ent;
            unsigned int e;

            ent = (const cetrafs_pending_free_t *) (bh->b_data + r * region_sz);
            ctx->n = 0;
            for (e = 0; e < slots; e++) {
                if (ent[e].lba == 0)
                    continue;
                if (cetrafs_le32(ent[e].magic) != CETRAFS_PENDING_FREE_MAGIC || cetrafs_le32(ent[e].count) == 0) {
                    pr_err("pending free: ZG %u queue block %u entry %u is garbage (magic=0x%x count=%u) -- dropping\n",
                           zg_id, qb, e, ent[e].magic, ent[e].count);
                    continue; /* the CAS below clears it */
                }
                ctx->done[ctx->n].lba = cetrafs_le64(ent[e].lba);
                ctx->done[ctx->n].count = cetrafs_le32(ent[e].count);
                ctx->n++;
            }

            if (!ctx->n)
                continue; /* empty region (any garbage is cleared on the next pass with company) */
            block_had_entries = true;

            /* CONSUME first. Only entries this swap actually removed from
             * the queue may be applied -- see the function comment. */
            ret = cetrafs_cas_region(sb, qstart + qb, r, cetrafs_pf_drain_mutate, ctx);
            if (ret == -EBUSY) {
                /* Lost the consume race repeatedly (concurrent appenders).
                 * NOTHING was applied, so the entries simply stay queued
                 * for the next tick -- no lost free, no double free. */
                pr_debug("pending free: ZG %u queue block %u region %u busy, leaving %u entr%s for the next pass\n",
                         zg_id, qb, r, ctx->n, ctx->n == 1 ? "y" : "ies");
                ret = 0;
                continue;
            }
            if (ret)
                break;

            /* Apply ONLY what the winning swap consumed (ctx->consumed,
             * set by the mutate's final run). An entry that vanished
             * before our swap was another drain's to apply -- applying it
             * here would be the double-apply this ordering prevents. One
             * that cannot be applied (wrong ZG, torn count) leaves its
             * blocks bitmap-set and unreferenced -- a leak the scrub
             * reclaims, never a double free. */
            for (e = 0; e < ctx->n; e++) {
                ctrace("PFDRAIN zg=%u lba=%llu count=%u consumed=%d\n", zg_id,
                       (unsigned long long) ctx->done[e].lba, ctx->done[e].count, (int) ctx->consumed[e]);
                if (ctx->consumed[e] &&
                    cetrafs_apply_pending_free(sb, ctx->done[e].lba, ctx->done[e].count, zg_id) == 0)
                    applied++;
            }
        }

        brelse(bh);

        if (block_had_entries)
            empty_run = 0;
        else if (++empty_run >= CETRAFS_PF_DRAIN_EMPTY_RUN)
            break;
    }

    kfree(ctx);

    if (applied) {
        pr_debug("pending free: ZG %u drained %u entr%s\n", zg_id, applied, applied == 1 ? "y" : "ies");
        /* The applies above only marked the BG/ZG free counters dirty --
         * make them durable at this same boundary, so a peer's statfs
         * (and this ZG's own next release-surplus check) see the
         * reclaimed space. */
        cetrafs_flush_dirty_free_counts(sb);
    }

    return ret;
}

/* Drain the pending-free queue of every ZG this node currently owns --
 * called at mount (right after the claim pass), from heartbeat.c's tick,
 * and after an on-demand claim in cetrafs_alloc_pick_bg(). */
/*
 * Walk a ZG's pending-free queue read-only, handing every valid entry to
 * cb(). Nothing is applied and nothing is cleared -- this exists so the
 * background scrub can see frees a peer has QUEUED but that have not
 * been drained yet.
 *
 * Why the scrub needs it: a queued entry names a block whose extent its
 * owner has already dropped, so the block reads as bitmap-set and
 * referenced by nothing -- indistinguishable from a leak. If the scrub
 * frees it, the bit clears early, this node's allocator hands the block
 * to a new file, and the next drain then applies the queued free to a
 * block that is live again. Note the hazard exists ONLY because of the
 * scrub: nothing else can clear that bit before the drain does, so the
 * allocator could never have handed the block out early.
 *
 * Uncached, like the drain: these queues are written by peers.
 */
int cetrafs_zg_pending_free_for_each(struct super_block *sb, u32 zg_id, void (*cb)(void *, u64, u32), void *ctx)
{
    unsigned int region_sz = cetrafs_cas_region_size(sb);
    unsigned int regions = CETRAFS_BLOCK_SIZE / region_sz;
    unsigned int slots = region_sz / sizeof(cetrafs_pending_free_t);
    u64 qstart;
    u32 qblocks, qb;
    int ret;

    ret = cetrafs_zg_queue_span(sb, zg_id, &qstart, &qblocks);
    if (ret)
        return ret;

    for (qb = 0; qb < qblocks; qb++) {
        struct buffer_head *bh = cetrafs_bread_uncached_retry(sb, qstart + qb);
        unsigned int r;

        if (!bh)
            return -EIO;

        for (r = 0; r < regions; r++) {
            const cetrafs_pending_free_t *ent = (const cetrafs_pending_free_t *) (bh->b_data + r * region_sz);
            unsigned int e;

            for (e = 0; e < slots; e++) {
                if (ent[e].lba == 0)
                    continue;
                /* Garbage is the drain's problem to report and clear; here
                 * it is simply not a block we can vouch for. */
                if (cetrafs_le32(ent[e].magic) != CETRAFS_PENDING_FREE_MAGIC || cetrafs_le32(ent[e].count) == 0)
                    continue;
                cb(ctx, cetrafs_le64(ent[e].lba), cetrafs_le32(ent[e].count));
            }
        }
        brelse(bh);
        cond_resched();
    }

    return 0;
}

/* Pending-free DRAIN passes. Draining only on the heartbeat (15s) let a
 * burst of cross-ZG frees overflow the queue and stay overflowed; the
 * allocation path now drains on demand. A test watches this move. */
/* Minimum gap between on-demand drains. Tunable so a test can pin it:
 * at 0 every allocation drains (the assertion that the hook is on the
 * allocation path at all), and at a large value none does (the
 * negative control that proves the assertion can fail). */
static unsigned int cetrafs_pf_drain_min_ms = CETRAFS_PF_DRAIN_MIN_MS;
module_param_named(pf_drain_min_ms, cetrafs_pf_drain_min_ms, uint, 0644);
MODULE_PARM_DESC(pf_drain_min_ms, "minimum ms between on-demand pending-free drains (0 = every allocation)");

static atomic64_t cetrafs_pf_drains = ATOMIC64_INIT(0);

u64 cetrafs_pf_drain_count(void)
{
    return (u64) atomic64_read(&cetrafs_pf_drains);
}

int cetrafs_zg_drain_pending_frees(struct super_block *sb)
{
    atomic64_inc(&cetrafs_pf_drains);
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 zg_count, z;
    int ret = 0;

    if (!raw_sb)
        return -EINVAL;

    zg_count = le32_to_cpu(raw_sb->zone_group_count);
    for (z = 0; z < zg_count; z++) {
        u32 first_bg, bg_count;
        int rc;

        if (!cetrafs_sb_zg_owned_cached(sb, z, &first_bg, &bg_count))
            continue;

        rc = cetrafs_zg_drain_one(sb, z);
        if (rc && !ret)
            ret = rc;
    }

    return ret;
}

/*
 * Allocate 'count' contiguous blocks from ANY BG this node owns -- the
 * ZG-aware wrapper over alloc.c's cetrafs_alloc_data_run(), used by
 * file.c's defrag ioctl to find the relocation target.
 * Tries owned BGs in order and takes the first that has a long-enough
 * run; deliberately does NOT claim additional ZGs on demand for this --
 * defrag is an optimization pass, not a capacity need, and grabbing
 * more of the volume to shuffle blocks around would fight the
 * minimum-claim policy for no user-visible gain (-ENOSPC just means
 * "cannot defrag right now").
 */
int cetrafs_alloc_pick_run(struct super_block *sb, u64 count, u64 *out_lba)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 zg_count, z;

    if (!raw_sb)
        return -EINVAL;

    zg_count = le32_to_cpu(raw_sb->zone_group_count);
    for (z = 0; z < zg_count; z++) {
        u32 first_bg, bg_count, bgi;

        if (!cetrafs_sb_zg_owned_cached(sb, z, &first_bg, &bg_count))
            continue;

        for (bgi = first_bg; bgi < first_bg + bg_count; bgi++) {
            int ret = cetrafs_alloc_data_run(sb, bgi, count, out_lba);

            if (ret == 0)
                return 0;
            if (ret != -ENOSPC)
                return ret;
        }
    }

    return -ENOSPC;
}

/*
 * an earlier phase: pick a Block Group to allocate a new data block
 * from -- a BG with free space, drawn only from a ZG this node owns.
 * This is what actually makes "a node only allocates from its own
 * zones" true; every real data-block allocation call site (file growth,
 * a new directory's data block, a lazily-allocated xattr block, ...)
 * goes through this instead of the historical hardcoded bg_id = 0.
 *
 * Scans every owned ZG's member BGs and picks the one with the LEAST
 * free_data_blocks (but > 0) -- i.e. already the most used-up -- rather
 * than just the first with any free space. This "pack
 * tight, don't spread" choice is deliberate, not an arbitrary
 * tiebreak: it drives whichever BG is already fullest towards
 * completely full, leaving any other owned-but-emptier BG/ZG
 * untouched -- which is what makes cetrafs_zg_release_surplus() (below)
 * able to find a genuinely, completely empty ZG to give back at all.
 * Spreading new writes evenly across every owned ZG instead would mean
 * none of them ever goes back to fully empty after its first use. Same
 * I/O cost either way: cetrafs_bg_data_block_stats() already reads
 * every owned BG descriptor up to the first free match; this just
 * keeps going through the rest of them too (the normal, cached, fast
 * path per ioutil.c -- not a new real device round trip).
 *
 * this is now also the *only* place a node ever grows beyond
 * its current minimum ZG holding (see cetrafs_zg_claim_unowned()'s
 * comment above for the mount/heartbeat side of this same policy
 * change). If every BG in every ZG this node owns is full, that's not
 * yet -ENOSPC -- it's "running low," so this claims exactly one more
 * eligible ZG (cetrafs_zg_claim_one_more()) and retries the scan once
 * before actually giving up. This is the on-demand half the design always intended, paired
 * with the mount-time side's "claim just the minimum" fix -- a node
 * should ask for more exactly when it needs more, never speculatively.
 */
/* How often cetrafs_alloc_pick_bg() answered from the allocation cursor
 * vs had to run the full owned-BG scan. Exposed in procfs so a test (and
 * an operator chasing write throughput) can see that the per-block
 * allocation path is NOT scanning every owned BG descriptor. Module-wide
 * like cas_ops, so assert on a delta. */
static atomic64_t cetrafs_bg_pick_cursor = ATOMIC64_INIT(0);
static atomic64_t cetrafs_bg_pick_scan = ATOMIC64_INIT(0);

u64 cetrafs_bg_pick_cursor_count(void)
{
    return (u64) atomic64_read(&cetrafs_bg_pick_cursor);
}

u64 cetrafs_bg_pick_scan_count(void)
{
    return (u64) atomic64_read(&cetrafs_bg_pick_scan);
}

int cetrafs_alloc_pick_bg(struct super_block *sb, u32 *out_bg_id)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 my_node_id, zg_count, z;
    bool tried_claim_more = false;
    int ret;

    if (!raw_sb)
        return -EINVAL;

    ret = cetrafs_sb_get_node_id(sb, &my_node_id);
    if (ret)
        return ret;

    zg_count = le32_to_cpu(raw_sb->zone_group_count);

    /*
     * Drain our own pending-free queues on the way through, at most
     * every CETRAFS_PF_DRAIN_MIN_MS.
     *
     * A peer freeing blocks that live in OUR Zone Group cannot touch
     * our bitmap; it queues them and we apply them. That drain ran only
     * at mount and on the heartbeat tick -- every 15 seconds -- while a
     * bulk delete or a preallocation give-back produces thousands of
     * frees in one second. The queue overflowed immediately and then
     * STAYED overflowed, so every subsequent free was dropped and
     * leaked, each costing a full queue-full retry: measured on the
     * deployment cluster at ~6.5 ms per extent, hundreds in a row,
     * "pending free LEAK: ZG 0 queue full, DROPPING" filling the log
     * while the owner sat one second from its next tick.
     *
     * Here is the right place for it: a node that is allocating is
     * active, and an active node is exactly the one whose peers are
     * filling its queue. The rate limit keeps it off the per-block
     * path's budget -- twice a second, not once per allocation.
     */
    {
        unsigned long now = jiffies;
        unsigned long last = cetrafs_sb_pf_drain_last(sb);

        if (!last || !cetrafs_pf_drain_min_ms ||
            time_after(now, last + msecs_to_jiffies(cetrafs_pf_drain_min_ms))) {
            cetrafs_sb_set_pf_drain_last(sb, now);
            (void) cetrafs_zg_drain_pending_frees(sb);
        }
    }

    /*
     * The cursor first: the BG this node is already filling. pick_bg is
     * called ONCE PER 4 KiB BLOCK a write allocates, and the scan below
     * reads every owned BG's descriptor -- each a CRC32C over a full
     * 4096-byte block -- so at a few tens of owned BGs it costs a core's
     * worth of CRC per second of streaming write, growing as a filling
     * node claims more ZGs. This turns the steady state into one
     * descriptor read instead of N.
     *
     * It does not weaken the scan's best-fit rule, it realises it:
     * best-fit exists to keep filling a partly-used BG rather than
     * spread across many, and staying put does exactly that while also
     * keeping cetrafs_alloc_data_block_near()'s contiguity hint landing
     * (a sequential write stays one extent instead of fragmenting into
     * an extent-tree leaf update, and a journalled write, per block).
     *
     * Advisory and unlocked -- a stale cursor can only name a BG the
     * scan would not have chosen. Ownership is re-checked here and again
     * in cetrafs_alloc_check_owned(); a BG that has filled up reports
     * free == 0 and falls through to the scan, which then re-seats it.
     */
    /* PERF(2): the cursor keeps this O(1); without it every 4 KiB block
     * rescans every owned BG descriptor. docs/PERFORMANCE.md */
    {
        u32 cursor = cetrafs_sb_alloc_cursor(sb);
        u64 total, free;

        if (cetrafs_sb_bg_is_ours(sb, cursor) && !cetrafs_bg_data_block_stats(sb, cursor, &total, &free) &&
            free > 0) {
            atomic64_inc(&cetrafs_bg_pick_cursor);
            *out_bg_id = cursor;
            return 0;
        }
    }

retry_scan:
    /*
     * this used to call cetrafs_read_zg() -- always a
     * forced-uncached, real device round trip by design -- for *every*
     * ZG on *every* call, i.e. once per new block a write needs. On the
     * loop-device test harness an uncached read is nearly free, so this
     * went unnoticed there; on real iSCSI hardware it meant every block
     * of a write paying for zone_group_count real network round trips,
     * reported directly as the whole filesystem being "extremely slow".
     * Ownership of a ZG this node holds cannot change out from under it
     * while it stays alive and mounted (a peer only ever reclaims a
     * *stale* owner's ZG), so cetrafs_sb_zg_owned_cached() -- populated
     * once, at the moment zonegroup.c's claim path actually confirms
     * ownership -- is always safe here and costs zero disk I/O. */
    {
        u32 best_bg = 0;
        u64 best_free = 0;
        bool have_best = false;

        for (z = 0; z < zg_count; z++) {
            u32 bg, first_bg, bg_count;

            /* PERF(1): cached ownership, never cetrafs_read_zg() -- this
             * runs per allocated block. docs/PERFORMANCE.md */
            if (!cetrafs_sb_zg_owned_cached(sb, z, &first_bg, &bg_count))
                continue;

            for (bg = first_bg; bg < first_bg + bg_count; bg++) {
                u64 total, free;

                ret = cetrafs_bg_data_block_stats(sb, bg, &total, &free);
                if (ret)
                    return ret;

                if (free > 0 && (!have_best || free < best_free)) {
                    best_bg = bg;
                    best_free = free;
                    have_best = true;
                }
            }
        }

        if (have_best) {
            *out_bg_id = best_bg;
            /* Re-seat the cursor, so the next block skips this scan. */
            cetrafs_sb_set_alloc_cursor(sb, best_bg);
            atomic64_inc(&cetrafs_bg_pick_scan);
            return 0;
        }
    }

    if (!tried_claim_more) {
        bool did_claim = false;

        tried_claim_more = true;

        ret = cetrafs_zg_claim_one_more(sb, raw_sb, my_node_id, &did_claim);
        if (ret)
            return ret;

        if (did_claim) {
            pr_info("alloc: ran out of space in owned zone group(s), claimed one more\n");
            /* The just-claimed ZG may carry pending frees queued against
             * its previous owner (or while unowned) -- apply them now,
             * since they may be exactly the free space this allocation
             * is here looking for. */
            cetrafs_zg_drain_pending_frees(sb);
            goto retry_scan;
        }
    }

    /* Either this node owns no ZGs and none were claimable just now, or
     * every BG it owns (including anything just claimed above) is full,
     * and there was nothing left to claim. Either way, it genuinely
     * cannot allocate -- not a bug, just out of (its own, now-exhausted)
     * space. */
    return -ENOSPC;
}
