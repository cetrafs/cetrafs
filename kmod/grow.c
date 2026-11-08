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
 *      capacity no superblock counts: df too high, a claim finding
 *      nothing to take, fsck reporting the shard and -r recounting it.
 *      Same window and same direction as a release that dies between
 *      its credit and its descriptor swap.
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
    u32 old_count;
    u64 new_seg_lba;
};

/* The old tail's next, pointed at the new segment. Re-checked on the
 * image the swap compares against: it must still be the tail of the
 * Block Groups the published superblock counts. A next that is already
 * set can only be an interrupted grow's link (mount and fsck accept it
 * as such), and is replaced, as offline growfs replaces it. */
static int cetrafs_grow_link_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_grow_link_ctx *ctx = priv;
    cetrafs_bg_segment_t *seg = image;

    if (len < sizeof(*seg))
        return -EINVAL;
    if (le32_to_cpu(seg->magic) != CETRAFS_BGSEG_MAGIC || cetrafs_bgseg_crc(seg) != (u32) le64_to_cpu(seg->checksum))
        return -EUCLEAN;
    if ((u64) le32_to_cpu(seg->first_bg_id) + le32_to_cpu(seg->count) != ctx->old_count)
        return -ESTALE;
    if (le64_to_cpu(seg->next) == ctx->new_seg_lba)
        return 1; /* already linked: an earlier attempt landed */
    seg->next = cpu_to_le64(ctx->new_seg_lba);
    seg->checksum = cpu_to_le64(0);
    seg->checksum = cpu_to_le64((u64) cetrafs_bgseg_crc(seg));
    return 0;
}

struct cetrafs_grow_sb_ctx {
    const cetrafs_superblock_t *cur, *nw;
};

/* Block 0: replaced only if it is still byte for byte the superblock
 * this grow was checked against. The bytes past the structure are left
 * as they are. */
static int cetrafs_grow_sb_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_grow_sb_ctx *ctx = priv;

    if (len < sizeof(*ctx->nw))
        return -EINVAL;
    if (!memcmp(image, ctx->nw, sizeof(*ctx->nw)))
        return 1; /* already published: an earlier attempt landed */
    if (memcmp(image, ctx->cur, sizeof(*ctx->cur)))
        return -ESTALE;
    memcpy(image, ctx->nw, sizeof(*ctx->nw));
    return 0;
}

/* Take back the credits of shards [0, upto). Best effort: what cannot
 * be taken back leaves the pool overstating, which fsck reports and -r
 * recounts -- the direction step 1's comment describes. */
static void cetrafs_grow_uncredit(struct super_block *sb, const struct cetrafs_grow_plan *plan, u32 upto)
{
    u32 z;

    for (z = 0; z < upto; z++)
        if (plan->shard_credit[z] && cetrafs_zg_adjust_pool_blocks(sb, z, -(s64) plan->shard_credit[z]))
            pr_warn("grow: pool shard %u keeps a credit of %llu it should not -- df will overstate until fsck -r\n",
                    z, (unsigned long long) plan->shard_credit[z]);
}

int cetrafs_grow_commit(struct super_block *sb, const struct cetrafs_grow_plan *plan)
{
    struct cetrafs_grow_sb_ctx sctx = {.cur = plan->cur, .nw = plan->nw};
    unsigned int stop = xchg(&cetrafs_grow_stop_after, 0);
    u32 z;
    int rc;

    /* 1. The pool, shard by shard. A shard is a Zone Group record, keyed
     * by bg_id % zone_group_count, so shard z is reached through any
     * Block Group id with that remainder -- z itself. */
    for (z = 0; z < plan->nshards; z++) {
        if (!plan->shard_credit[z])
            continue;
        rc = cetrafs_zg_adjust_pool_blocks(sb, z, (s64) plan->shard_credit[z]);
        if (rc) {
            pr_err("grow: crediting pool shard %u failed (%d) -- nothing published\n", z, rc);
            cetrafs_grow_uncredit(sb, plan, z);
            return rc;
        }
    }
    if (stop == 1) {
        pr_warn("grow: stopping after the pool credits (test)\n");
        return -EIO;
    }

    /* 2. The link, on a second or later grow. */
    if (plan->tail_lba) {
        struct cetrafs_grow_link_ctx lctx = {.old_count = plan->old_count, .new_seg_lba = plan->new_seg_lba};

        rc = cetrafs_cas_record(sb, plan->tail_lba, cetrafs_grow_link_mutate, &lctx);
        if (rc == 1)
            rc = 0;
        if (rc == -ETIMEDOUT || rc == -EIO) {
            /* Unknown: the link may be on the device. A link with no
             * publish is a state mount accepts, and the credits are
             * kept rather than risk taking back ones a publish needs. */
            pr_err("grow: the table link's outcome is unknown (%d) -- run growfs again\n", rc);
            return -EIO;
        }
        if (rc) {
            pr_err("grow: linking the new segment from block %llu failed (%d) -- nothing published\n",
                   (unsigned long long) plan->tail_lba, rc);
            cetrafs_grow_uncredit(sb, plan, plan->nshards);
            return rc == -ESTALE ? -ESTALE : rc;
        }
    }
    if (stop == 2) {
        pr_warn("grow: stopping after the table link (test)\n");
        return -EIO;
    }

    /* 3. The superblock. */
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
        cetrafs_grow_uncredit(sb, plan, plan->nshards);
        return rc;
    }
    return 0;
}

long cetrafs_grow_ioctl(struct file *file, const cetrafs_superblock_t __user *arg)
{
    struct super_block *sb = file_inode(file)->i_sb;
    cetrafs_superblock_t *nw;
    long rc;

    if (!capable(CAP_SYS_ADMIN))
        return -EPERM;
    if (sb_rdonly(sb))
        return -EROFS;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
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
    nw = memdup_user(arg, sizeof(*nw));
    if (IS_ERR(nw))
        return PTR_ERR(nw);
    rc = cetrafs_sb_layout_grow(sb, nw);
    kfree(nw);
    return rc;
}
