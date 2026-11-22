// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * grow.c -- the kernel half of growing a MOUNTED volume.
 *
 * growfs.cetra does the bulk of a grow from userspace, as it always
 * did: it computes the new geometry, writes the new Block Groups'
 * headers and zeroed bitmaps and the table segment that describes them,
 * all into space past the end of the published volume where nothing
 * can reach it, and syncs them. Offline it then wrote the superblock
 * itself. On a mounted volume it cannot: the superblock, the Zone Group
 * records and the table chain are records the mounted nodes
 * compare-and-swap, and a plain write from userspace is a lost update
 * waiting for the next one. So it hands the superblock it would have
 * written to CETRAFS_IOC_GROW, and the kernel publishes it -- after
 * checking all of it (fs.c's cetrafs_sb_layout_grow()).
 *
 * Exclusion. Two growers would compute the same new space from the
 * same superblock and write their Block Groups over each other's; the
 * second could do it after the first had published and nodes had begun
 * to allocate there. growfs therefore holds the volume's repair claim
 * (a Node Registry row in REPAIR, the lease fsck -r takes) from before
 * it reads the superblock it computes from until after this returns,
 * and a second grower or a repair refuses while it is held. The publish
 * below is a compare-and-swap against the superblock this node has, so
 * a grower that somehow worked from an older one is refused (-ESTALE)
 * rather than published -- but the claim is what keeps its WRITES off a
 * live volume, and nothing here can undo those.
 *
 * Order, and what a crash at each point leaves:
 *
 *   1. Credit each pool shard with the capacity it gains. The new Block
 *      Groups read FREE, and a claim debits its shard -- so the credit
 *      lands first, the same rule a Block Group release follows (a
 *      debit always follows the credit it consumes; class 34). A crash
 *      after this and before 3 leaves the pool OVERSTATING free space by
 *      capacity no superblock counts -- so each credit is NAMED in its
 *      shard (pool_grow_gen/id/credit, cetrafs_zone_group_t), and a
 *      named credit above the published layout_gen with no growfs claim
 *      held is taken back by id: by the next grow's step 1, by this
 *      grow's own failure path, and at every mount
 *      (cetrafs_grow_heal_pool()). A re-run replaces the dead credit
 *      rather than stacking a second one on it.
 *   2. Link the new segment from the old tail (a second or later grow;
 *      a first grow's link IS the superblock). A crash here leaves a
 *      chain one segment longer than the count, which mount and fsck
 *      accept as a grow that never published (fs.c,
 *      cetrafs_layout_pending_link()).
 *   3. Publish the superblock. From here the volume is the new size,
 *      and every node catches up on its next heartbeat or the first
 *      time it meets an address past its old end.
 *
 * New Block Groups go to the POOL (owner FREE), not to a Zone Group:
 * a Zone Group's free aggregate belongs to whoever owns it and is
 * accrued in memory on that node, so writing it from here would race
 * the owner's own flush. Capacity in the pool reaches every node through
 * the ordinary claim path.
 */
#include <linux/delay.h>
#include <linux/crc32c.h>
#include <linux/capability.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include "kmod.h"

/* TEST ONLY: stop a grow after this many of its writes (1 = after the
 * pool credits, 2 = after the link), returning -EIO as if the node had
 * died there -- the states tests/kernel/grow_live_crash.sh mounts. */
static unsigned int cetrafs_grow_stop_after;
cetrafs_test_param(grow_stop_after, cetrafs_grow_stop_after, uint, 0644);
MODULE_PARM_DESC(grow_stop_after, "TEST ONLY: abandon the next live grow after N of its writes (1 credit, 2 link)");

struct cetrafs_grow_link_ctx {
    u32 magic; /* which chain: CETRAFS_BGSEG_MAGIC or CETRAFS_INOSEG_MAGIC */
    u64 old_count;
    u64 new_seg_lba;
};

/* The old tail's next, pointed at the new segment. Re-checked on the
 * image the swap compares against: it must still be the tail of the
 * Block Groups the published superblock counts. A next that is already
 * set is replaced, as offline growfs replaces it: with a growfs claim
 * held (cetrafs_grow_claim_held(), checked before anything here) no
 * other grower can be between its link and its publish, so it can only
 * be an interrupted grow's link -- which mount and fsck accept as such
 * (cetrafs_layout_pending_link()). */
static int cetrafs_grow_link_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_grow_link_ctx *ctx = priv;
    cetrafs_seg_hdr_t *seg = image; /* the first CAS region of the block only: every field, no padding */

    if (len < offsetof(cetrafs_seg_hdr_t, pad))
        return -EINVAL;
    if (le32_to_cpu(seg->magic) != ctx->magic ||
        cetrafs_seg_crc_prefix(image, len) != (u32) le64_to_cpu(seg->checksum))
        return -EUCLEAN;
    if ((u64) le32_to_cpu(seg->first_id) + le32_to_cpu(seg->count) != ctx->old_count)
        return -ESTALE;
    if (le64_to_cpu(seg->next) == ctx->new_seg_lba)
        return 1; /* already linked: an earlier attempt landed */
    seg->next = cpu_to_le64(ctx->new_seg_lba);
    seg->checksum = cpu_to_le64(0);
    seg->checksum = cpu_to_le64((u64) cetrafs_seg_crc_prefix(image, len));
    return 0;
}

/*
 * A Block Group the grow adds becomes reachable the moment the grow
 * publishes: the pool hands it to a claim and the allocator reads its
 * bitmap. growfs writes each new group's in-region header and zeroes its
 * bitmap, syncs both, and only then asks for the commit -- so a header
 * that does not verify here means the region was never initialised, or
 * not durably (rule 5). Until now only fsck read these headers, after
 * the grow had already published over them.
 *
 * Grow only, one forced-fresh read per new group. The header and the
 * bitmap zeroing reach the device under the same sync in growfs, so a
 * durable header is also the witness for the bitmap.
 * tests/kernel/grow_live_bg_header.sh.
 */
int cetrafs_grow_check_bg_header(struct super_block *sb, u32 bg_id, u64 start, u64 len)
{
    static const u8 zero[8] = {0};
    const size_t off = offsetof(cetrafs_bg_header_t, checksum);
    const size_t clen = sizeof(((cetrafs_bg_header_t *) NULL)->checksum);
    const cetrafs_bg_header_t *h;
    struct buffer_head *bh;
    u32 bmap, data, crc = ~0U;
    u64 cnt, i;
    int rc = 0;

    BUILD_BUG_ON(sizeof(zero) != clen);
    BUILD_BUG_ON(sizeof(cetrafs_bg_header_t) != CETRAFS_BLOCK_SIZE);

    bh = cetrafs_bread_uncached(sb, start);
    if (!bh)
        return -EIO;
    h = (const cetrafs_bg_header_t *) bh->b_data;
    crc = crc32c(crc, h, off);
    crc = crc32c(crc, zero, clen);
    crc = crc32c(crc, (const u8 *) h + off + clen, sizeof(*h) - off - clen);
    cetrafs_calc_bg_layout(len, le32_to_cpu(cetrafs_sb_raw(sb)->data_align_blocks), &bmap, &data, &cnt);
    if ((u64) ~crc != le64_to_cpu(h->checksum) || le32_to_cpu(h->bg_id) != bg_id ||
        le64_to_cpu(h->length_blocks) != len || le32_to_cpu(h->off_data_bmap) != bmap ||
        le32_to_cpu(h->off_data_region) != data || le64_to_cpu(h->data_block_count) != cnt) {
        pr_err("%s: Block Group %u's header at %llu does not verify (id %u, crc %s) -- its region was not "
               "initialised on the device\n",
               sb->s_id, bg_id, (unsigned long long) start, le32_to_cpu(h->bg_id),
               (u64) ~crc == le64_to_cpu(h->checksum) ? "ok" : "bad");
        rc = -EUCLEAN;
    }
    brelse(bh);

    /*
     * Its data bitmap, as the device has it, must be empty -- no bit set,
     * every sector carrying its checksum: the allocator reads it the
     * moment the group is handed out, and a region that held an earlier
     * group's bitmap would read that group's allocations as this group's
     * (audit L8). growfs writes it under the same sync as the header; a
     * region that was never written is refused here, the same as a
     * header that does not verify. Forced-fresh, one block at a time.
     */
    for (i = 0; !rc && i < data - bmap; i++) {
        struct buffer_head *bbh = cetrafs_bread_uncached(sb, start + bmap + i);

        if (!bbh) {
            rc = -EIO;
            break;
        }
        if (!cetrafs_bmap_block_empty(bbh->b_data)) {
            pr_err("%s: Block Group %u's bitmap block at %llu is not an empty bitmap -- its region was not "
                   "initialised on the device\n",
                   sb->s_id, bg_id, (unsigned long long) (start + bmap + i));
            rc = -EUCLEAN;
        }
        brelse(bbh);
    }
    return rc;
}

/*
 * The inode table segment a grow adds: its bitmap, as the device has it,
 * must be empty. The allocator reads it the moment the grow publishes,
 * and a region that held an earlier table's bitmap would read numbers
 * as in use -- or, set bits with live-looking records under them, as
 * inodes nobody created. growfs empties and syncs it before the commit;
 * only its header was ever read here (audit 2026-11-15 F-64). The records
 * are not read: a free bit makes a slot's record unborn whatever it
 * holds, and a grow may add millions of them. Forced-fresh, one block
 * at a time. tests/kernel/grow_live_iseg_bitmap.sh.
 */
int cetrafs_grow_check_iseg_bitmap(struct super_block *sb, u64 seg_lba, u64 count)
{
    u64 i, n = cetrafs_calc_inode_bmap_blocks(count);
    int rc = 0;

    for (i = 0; !rc && i < n; i++) {
        struct buffer_head *bh = cetrafs_bread_uncached(sb, seg_lba + 1 + i);

        if (!bh)
            return -EIO;
        if (!cetrafs_bmap_block_empty(bh->b_data)) {
            pr_err("%s: the new inode table segment's bitmap block at %llu is not an empty bitmap -- its region "
                   "was not initialised on the device\n",
                   sb->s_id, (unsigned long long) (seg_lba + 1 + i));
            rc = -EUCLEAN;
        }
        brelse(bh);
    }
    return rc;
}

struct cetrafs_grow_sb_ctx {
    const cetrafs_superblock_t *cur, *nw;
};

/* Block 0: replaced only if it is still byte for byte the superblock
 * this grow was checked against. The bytes past the structure are left
 * as they are. */
static void cetrafs_grow_sb_restamp(cetrafs_superblock_t *s)
{
    s->checksum = cpu_to_le64(0);
    s->checksum = cpu_to_le64((u64) ~crc32c(~0U, s, sizeof(*s)));
}

static int cetrafs_grow_sb_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_grow_sb_ctx *ctx = priv;

    cetrafs_superblock_t want_cur, want_nw;

    if (len < sizeof(*ctx->nw))
        return -EINVAL;
    /* Compared around the needs-fsck mark, which a peer may set at any
     * time and which is status, not layout: a grow keeps whatever mark
     * the device has (cetrafs_sb_copy_status()). Both images are
     * restamped with it, so the comparison is byte for byte otherwise. */
    want_cur = *ctx->cur;
    want_nw = *ctx->nw;
    cetrafs_sb_copy_status(&want_cur, image);
    cetrafs_sb_copy_status(&want_nw, image);
    cetrafs_grow_sb_restamp(&want_cur);
    cetrafs_grow_sb_restamp(&want_nw);
    if (!memcmp(image, &want_nw, sizeof(want_nw)))
        return 1; /* already published: an earlier attempt landed */
    if (memcmp(image, &want_cur, sizeof(want_cur)))
        return -ESTALE;
    memcpy(image, &want_nw, sizeof(want_nw));
    return 0;
}

/* Take back this grow's credits, by its id: a shard that no longer
 * names it is left alone. What cannot be taken back now (the CAS
 * failed) is still named on the device, and the next grow or mount
 * takes it back (cetrafs_grow_heal_pool()). */
static void cetrafs_grow_uncredit(struct super_block *sb, const struct cetrafs_grow_plan *plan, u64 id)
{
    u64 gen = le64_to_cpu(plan->nw->layout_gen), took;
    u32 z;

    for (z = 0; z < plan->nshards; z++)
        if (plan->shard_credit[z] && cetrafs_zg_pool_grow_takeback(sb, z, gen, id, &took))
            pr_warn("grow: pool shard %u keeps this grow's credit for now -- the next grow or mount takes it back\n",
                    z);
}

/* TEST ONLY: hold a grow just before its publish, and skip the claim
 * re-check there (tests/kernel/grow_claim_lost.sh and its control). */
static unsigned int cetrafs_grow_publish_stall_ms;
cetrafs_test_param(grow_publish_stall_ms, cetrafs_grow_publish_stall_ms, uint, 0644);
MODULE_PARM_DESC(grow_publish_stall_ms, "TEST ONLY: pause a live grow just before its superblock publish");
static bool cetrafs_grow_publish_recheck_off;
cetrafs_test_param(grow_publish_recheck_off, cetrafs_grow_publish_recheck_off, bool, 0644);
MODULE_PARM_DESC(grow_publish_recheck_off, "TEST ONLY: publish a live grow without re-checking its claim");

/* Point the old tail at a new segment of the 'magic' chain; nothing to
 * do when the superblock names it (the table's first grow, tail 0). */
static int cetrafs_grow_link(struct super_block *sb, const struct cetrafs_grow_plan *plan, u64 id, u64 tail,
                             u32 magic, u64 old_count, u64 new_lba)
{
    struct cetrafs_grow_link_ctx lctx = {.magic = magic, .old_count = old_count, .new_seg_lba = new_lba};
    int rc;

    if (!tail)
        return 0;
    rc = cetrafs_cas_record(sb, tail, cetrafs_grow_link_mutate, &lctx);
    if (rc == 1)
        rc = 0;
    if (rc == -ETIMEDOUT || rc == -EIO) {
        /* Unknown: the link may be on the device. A link with no
         * publish is a state mount accepts, and the credits are kept
         * rather than risk taking back ones a publish needs. */
        pr_err("grow: the table link's outcome is unknown (%d) -- run growfs again\n", rc);
        return -EIO;
    }
    if (rc) {
        pr_err("grow: linking the new segment from block %llu failed (%d) -- nothing published\n",
               (unsigned long long) tail, rc);
        cetrafs_grow_uncredit(sb, plan, id);
    }
    return rc;
}

int cetrafs_grow_commit(struct super_block *sb, const struct cetrafs_grow_plan *plan)
{
    struct cetrafs_grow_sb_ctx sctx = {.cur = plan->cur, .nw = plan->nw};
    unsigned int stop = xchg(&cetrafs_grow_stop_after, 0);
    u64 published = le64_to_cpu(plan->cur->layout_gen), gen = le64_to_cpu(plan->nw->layout_gen);
    u64 id = get_random_u64() | 1, took;
    u32 z;
    int rc;

    /* 1. The pool, shard by shard -- EVERY shard, not only those this
     * grow credits: under the growfs claim no other grow is live, so a
     * marker above the published layout_gen is a grow that died before
     * publishing, and its credit comes back out in the same swap. A
     * shard is a Zone Group record, keyed by cetrafs_sb_zg_shard(), so
     * shard z is reached through any Block Group id with that
     * remainder -- z itself. 'published' is the superblock this node
     * refreshed to under the claim, which only a grow moves. */
    for (z = 0; z < plan->nshards; z++) {
        rc = cetrafs_zg_pool_grow_credit(sb, z, published, gen, id, plan->shard_credit[z], &took);
        if (rc) {
            pr_err("grow: crediting pool shard %u failed (%d) -- nothing published\n", z, rc);
            cetrafs_grow_uncredit(sb, plan, id);
            return rc;
        }
        if (took)
            pr_warn("grow: pool shard %u held %llu blocks of a grow that never published -- taken back\n", z,
                    (unsigned long long) took);
    }
    if (stop == 1) {
        pr_warn("grow: stopping after the pool credits (test)\n");
        return -EIO;
    }

    /* 2. The links, on a table's second or later grow: the Block Group
     * table's, then the inode table's if the grow adds inodes. */
    rc = cetrafs_grow_link(sb, plan, id, plan->tail_lba, CETRAFS_BGSEG_MAGIC, plan->old_count, plan->new_seg_lba);
    if (!rc && plan->new_iseg_lba)
        rc = cetrafs_grow_link(sb, plan, id, plan->tail_ilba, CETRAFS_INOSEG_MAGIC, plan->old_inodes,
                               plan->new_iseg_lba);
    /* No inodes added, and an earlier grow's link left on the inode tail:
     * cleared, before the publish lays Block Groups over where it points
     * (cetrafs_layout_walk_inodes()). */
    if (!rc && plan->stale_itail)
        rc = cetrafs_grow_link(sb, plan, id, plan->stale_itail, CETRAFS_INOSEG_MAGIC, plan->old_inodes, 0);
    if (rc)
        return rc;
    if (stop == 2) {
        pr_warn("grow: stopping after the table link (test)\n");
        return -EIO;
    }

    /* 3. The superblock -- still under the caller's claim. It was judged
     * at the ioctl's entry, and the credits, the table writes and the
     * link have run since: a claim lost in between (reaped, retaken by
     * another grower) would publish under nobody's (audit 2026-11-14
     * L8, rule 15). Not published: the link stays, as below. */
    if (READ_ONCE(cetrafs_grow_publish_stall_ms)) {
        unsigned int ms = min_t(unsigned int, xchg(&cetrafs_grow_publish_stall_ms, 0), 10000);

        pr_info("grow: pausing %u ms before the publish (test)\n", ms);
        msleep(ms); /* test-only; see the parameter */
    }
    if (plan->claim && !READ_ONCE(cetrafs_grow_publish_recheck_off)) {
        rc = cetrafs_grow_claim_held(sb, plan->claim);
        if (rc) {
            pr_err("grow: the growfs claim was lost before the publish (%d) -- nothing published\n", rc);
            return rc;
        }
    }
    rc = cetrafs_cas_record(sb, CETRAFS_SB_BLOCK_NR, cetrafs_grow_sb_mutate, &sctx);
    if (rc == 1)
        rc = 0;
    if (rc == -ETIMEDOUT || rc == -EIO) {
        /* Unknown, and possibly published: nothing is taken back. The
         * next refresh reads what is really there. */
        pr_err("grow: the superblock publish's outcome is unknown (%d) -- the next heartbeat will tell\n", rc);
        return -EIO;
    }
    if (rc) {
        pr_err("grow: publishing the superblock failed (%d)%s\n", rc,
               rc == -ESTALE ? " -- it changed under the grow; run growfs again" : "");
        /* Definitely not published. The link, if any, stays: a chain
         * one segment past the count is a grow that never published,
         * which mount accepts and the next grow replaces. */
        cetrafs_grow_uncredit(sb, plan, id);
        return rc;
    }
    return 0;
}

/*
 * Is a growfs claim -- a Node Registry row in REPAIR labelled "growfs"
 * -- on the device? 0 if so, -EBUSY if not, -EIO if the registry cannot
 * be read (not knowing is not "none").
 *
 * PRESENCE, not liveness: the mount gate's check
 * (cetrafs_node_repair_claim_exists()) watches the claim's heartbeat
 * move, sleeping up to a stale window, and the caller here is the very
 * process whose renewal timer moves it -- its SIGALRM interrupted that
 * sleep and every grow failed with EINTR. A grower that loses its row
 * stops itself (its timer finds the row taken); what this adds is that
 * nothing publishes while NO growfs claim is held. A dead growfs's row
 * would satisfy it, and also blocks every mount until it goes stale.
 */
/* 0 when a growfs claim is on the device, -EBUSY when none is, -EIO
 * when the registry cannot be read (not knowing is not "none"). Asked
 * by the mount's heal only: it says whether SOME grow is live, which
 * is all the heal needs (a claim it leaves alone costs nothing). The
 * ioctl asks the caller's own claim, cetrafs_grow_claim_owned(). */
static int cetrafs_grow_claim_present(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    cetrafs_node_entry_t ne;
    u32 count, idx;

    if (!raw_sb)
        return -EIO;
    count = le32_to_cpu(raw_sb->node_table_count);
    for (idx = 0; idx < count && idx < CETRAFS_MAX_READER_NODES; idx++) {
        int r = cetrafs_node_get_entry(sb, idx, &ne);

        if (r == -EIO)
            return -EIO;
        if (r || le32_to_cpu(ne.state) != CETRAFS_NODE_STATE_REPAIR)
            continue; /* a bad row is not a claim */
        if (!strncmp(ne.label, "growfs", sizeof(ne.label)))
            return 0;
    }
    return -EBUSY;
}

/* TEST ONLY: the ioctl accepts ANY growfs row in REPAIR, as it did
 * before the claim was carried in the argument. grow_claim_owner.sh's
 * control: a grow under someone else's claim is then published. */
static bool cetrafs_grow_claim_any;
cetrafs_test_param(grow_claim_any, cetrafs_grow_claim_any, bool, 0644);
MODULE_PARM_DESC(grow_claim_any, "TEST ONLY: a live grow is accepted under ANY growfs claim, not the caller's own");

/*
 * Is the caller's claim -- Node Registry row `row`, in REPAIR, labelled
 * "growfs", carrying `nonce` as its node_uuid -- still on the device?
 * 0 if so, -EBUSY if not (a row that is not that claim, a row out of
 * range, or a stale claim that was taken away), -EIO if the registry
 * cannot be read.
 *
 * The claim is growfs's: it wrote the nonce into the row when it took
 * the claim and keeps it for the whole grow. A row that is a growfs
 * claim belonging to someone else is refused here (audit L8).
 */
static int cetrafs_grow_claim_owned(struct super_block *sb, u32 row, const u8 *nonce)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    cetrafs_node_entry_t ne;
    int r;

    BUILD_BUG_ON(sizeof(((cetrafs_grow_arg_t *) NULL)->claim_nonce) != sizeof(ne.node_uuid));
    if (!raw_sb)
        return -EIO;
    if (row >= le32_to_cpu(raw_sb->node_table_count) || row >= CETRAFS_MAX_READER_NODES)
        return -EBUSY;
    r = cetrafs_node_get_entry(sb, row, &ne);
    if (r == -EIO)
        return -EIO;
    if (r || le32_to_cpu(ne.state) != CETRAFS_NODE_STATE_REPAIR ||
        strncmp(ne.label, "growfs", sizeof(ne.label)) || memcmp(ne.node_uuid, nonce, sizeof(ne.node_uuid)))
        return -EBUSY;
    return 0;
}

int cetrafs_grow_claim_held(struct super_block *sb, const cetrafs_grow_arg_t *arg)
{
    int rc;

    if (READ_ONCE(cetrafs_grow_claim_any))
        rc = cetrafs_grow_claim_present(sb);
    else
        rc = cetrafs_grow_claim_owned(sb, le32_to_cpu(arg->claim_row), arg->claim_nonce);
    if (rc == -EBUSY)
        pr_err("grow: no growfs claim of this caller is on the volume -- refusing to publish\n");
    return rc;
}

/* TEST ONLY: the mount's heal skips the pool (grow_live_crash.sh's
 * control: the dead credit stays). */
static bool cetrafs_grow_heal_off;
cetrafs_test_param(grow_heal_off, cetrafs_grow_heal_off, bool, 0644);
MODULE_PARM_DESC(grow_heal_off, "TEST ONLY: the mount does not take back a dead live grow's pool credit");

/*
 * Take back the pool credit of a live grow that died before publishing
 * (cetrafs_grow_commit(), step 1). Run at mount, outside any grow.
 *
 * The verdict "dead" is three reads, in this order, and the order is
 * the argument: the markers first; then no growfs claim present; then
 * the superblock, fresh, below the marker's gen. A grower holds its
 * claim from before it writes its marker until after its publish has
 * landed or failed, so a marker seen BEFORE a look that finds no claim
 * belongs to a grow that has finished -- and one whose gen the
 * superblock read AFTER that has not reached never published. The
 * take-back is then a CAS requiring the same id, so a grow that started
 * since (a new claim, a new id) is never touched: it either replaced
 * the marker first, and ours does nothing, or finds it gone and
 * credits afresh. A superblock publish whose outcome its grower could
 * not tell (a timed-out CAS) that lands only later leaves the pool
 * UNDERSTATING -- the direction that never hands a block out twice.
 */
int cetrafs_grow_heal_pool(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 *gen, *id, published, took;
    u32 nz, z, dead = 0;
    int rc;

    if (!raw_sb)
        return -EINVAL;
    if (READ_ONCE(cetrafs_grow_heal_off))
        return 0;
    nz = le32_to_cpu(raw_sb->zone_group_count);
    gen = kcalloc(nz, sizeof(*gen), GFP_KERNEL);
    id = kcalloc(nz, sizeof(*id), GFP_KERNEL);
    rc = gen && id ? 0 : -ENOMEM;
    for (z = 0; !rc && z < nz; z++) {
        rc = cetrafs_zg_pool_grow_marker(sb, z, &gen[z], &id[z]);
        if (!rc && gen[z] > le64_to_cpu(raw_sb->layout_gen))
            dead++;
    }
    if (rc || !dead)
        goto out;
    rc = cetrafs_grow_claim_present(sb);
    if (!rc) {
        pr_info("%s: a pool credit names a grow that has not published, and a growfs claim is held -- leaving it\n",
                sb->s_id);
        goto out;
    }
    if (rc != -EBUSY)
        goto out;
    rc = cetrafs_sb_layout_refresh(sb);
    if (rc < 0)
        goto out;
    rc = 0;
    published = le64_to_cpu(cetrafs_sb_raw(sb)->layout_gen);
    for (z = 0; z < nz; z++) {
        int r;

        if (gen[z] <= published)
            continue;
        r = cetrafs_zg_pool_grow_takeback(sb, z, gen[z], id[z], &took);
        if (r)
            rc = r;
        else if (took)
            pr_warn("%s: pool shard %u held %llu blocks of a live grow that never published -- taken back\n",
                    sb->s_id, z, (unsigned long long) took);
    }
out:
    kfree(gen);
    kfree(id);
    return rc;
}

long cetrafs_grow_ioctl(struct file *file, const cetrafs_grow_arg_t __user *arg)
{
    struct super_block *sb = file_inode(file)->i_sb;
    cetrafs_grow_arg_t *ga;
    long rc;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;
    if (sb_rdonly(sb))
        return -EROFS;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    /* A grow over a structure this build does not know -- even a
     * compatible one, which the mount itself ignores -- may grow past or
     * over it (cetrafs.h, the feature rules); growfs refuses it too. */
    if (le64_to_cpu(cetrafs_sb_raw(sb)->features_compat) & ~CETRAFS_FEAT_COMPAT_SUPP) {
        pr_err("grow: the volume has COMPAT feature bits this build does not know (0x%llx) -- not grown\n",
               (unsigned long long) le64_to_cpu(cetrafs_sb_raw(sb)->features_compat));
        return -EOPNOTSUPP;
    }
    /*
     * Every node must re-read the layout when it moves. One that does
     * not -- a build from before live grow -- would go on judging the
     * new space as corruption and never allocate there; and a row that
     * cannot be read is not known to be safe.
     */
    if (!cetrafs_cluster_all_advertise(sb, CETRAFS_NODE_CAP_LIVE_GROW)) {
        pr_err("grow: a registered node does not advertise live-grow support -- grow it offline\n");
        return -EOPNOTSUPP;
    }
    /*
     * The claim is what keeps two growers' Block Group writes apart, and
     * what makes the link below safe to overwrite an existing next (only
     * an interrupted grow under an earlier claim can have set it). That
     * was a premise about the CALLER -- growfs takes it -- and nothing
     * here checked it, so any CAP_SYS_ADMIN program could publish a
     * superblock with no claim held (GROWFS-LIVE-REVIEW M2).
     */
    ga = memdup_user(arg, sizeof(*ga));
    if (IS_ERR(ga))
        return PTR_ERR(ga);
    rc = cetrafs_grow_claim_held(sb, ga);
    if (!rc)
        rc = cetrafs_sb_layout_grow(sb, &ga->sb, ga);
    kfree(ga);
    return rc;
}
