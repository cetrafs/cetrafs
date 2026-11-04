// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * node.c -- Node Registry row management.
 *
 * At mount, a node finds its own row in the global Node Registry by its
 * stable machine UUID (uuid.c) -- a re-attach across reboots -- or claims
 * a free row on a first-ever mount (or after a deliberately wiped node).
 * Either way the row is left CETRAFS_NODE_STATE_REGISTERED with a fresh
 * heartbeat, and the caller (fs.c) stashes the claimed row index in
 * cetrafs_sb_info for later phases (ZG claiming stamps it into
 * cetrafs_zone_group_t.owner_node_id).
 *
 * The free-row claim is one atomic compare-and-swap of the row: the
 * mutator runs only on a FREE row, and the swap lands only if the sector
 * is still byte-for-byte what the mutator was shown. A lost race is
 * detected by the CAS itself (MISCOMPARE, re-read, the next free row is
 * tried), so two nodes cannot share one row. There is no separate
 * write-then-read-back. After the claim, cetrafs_node_twin_row() scans
 * the other rows for this machine's UUID, so a clone that claimed a row
 * at the same moment is refused rather than silently sharing identity.
 *
 * Also implements the node-liveness half: periodic
 * self-renewal (cetrafs_node_renew_heartbeat(), driven by heartbeat.c's
 * delayed_work) and the staleness test everything else's reclaim logic
 * is built on (cetrafs_node_is_stale()).
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/buffer_head.h>
#include <linux/crc32c.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/minmax.h>
#include <linux/string.h>
#include <linux/timekeeping.h>
#include <linux/utsname.h>
#include <linux/uuid.h>

#include "kmod.h"

/* checksum is plain-native, same convention as the inode/BG checksums:
 * CRC32C over the whole record with the checksum field zeroed. */
static u32 cetrafs_node_crc(const cetrafs_node_entry_t *ne)
{
    cetrafs_node_entry_t tmp = *ne;

    tmp.checksum = 0;
    return ~crc32c(~0U, &tmp, sizeof(tmp));
}

/*
 * Read node registry row #idx (one whole block per row as of v0x0007).
 *
 * Like fsck's validation pass, a FREE row's checksum is never stamped by
 * mkfs (the whole table starts zero-filled) -- only REGISTERED rows are
 * checksum-verified.
 */
static int cetrafs_read_node_entry(struct super_block *sb, u32 idx, cetrafs_node_entry_t *out)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct buffer_head *bh;

    if (!raw_sb)
        return -EINVAL;
    if (idx >= le32_to_cpu(raw_sb->node_table_count))
        return -EINVAL;

    /* v0x0007: one row per block. Packed rows shared a
     * block across nodes, and even though each row has exactly one
     * legitimate writer (its own node), the un-mutexed heartbeat
     * renewals' whole-block RMWs could revert a block-mate's concurrent
     * update -- including a PR-locked row CLAIM, after its verify
     * readback had already passed. Uncached read as before: this row may
     * have been written by any peer at any moment.
     *
     * Checksum-mismatch retries: a peer renews its own row
     * every heartbeat tick with a blind 4 KiB row write, and readers
     * (staleness checks, procfs's cluster dump, this very function) are
     * deliberately lockless -- so a reader can observe that write torn.
     * The writer always syncs, so a torn observation converges on
     * re-read; only a persistent mismatch is real corruption. Same shape
     * as inode.c's record-read retry and dir.c's dirent-tail retry. */
    {
        int attempt;

        for (attempt = 0; attempt < 5; attempt++) {
            /* Retrying read: a NULL here is usually not an I/O error
             * but a concurrent forced-fresh read of the same block
             * clearing uptodate under us. Bailing out turned that into
             * a hard -EIO -- and this function is on the namespace-lock
             * path (cetrafs_node_is_stale() of a foreign holder), so it
             * failed a plain create() on whichever node LOST the lock
             * race, which is exactly the asymmetry seen on real two-node
             * hardware. */
            bh = cetrafs_bread_uncached_retry(sb, le64_to_cpu(raw_sb->node_table_start) + idx);
            if (!bh)
                return -EIO;

            memcpy(out, bh->b_data, sizeof(*out));
            brelse(bh);

            if (cetrafs_le32(out->state) == CETRAFS_NODE_STATE_FREE ||
                cetrafs_node_crc(out) == (u32) cetrafs_le64(out->checksum))
                return 0;

            /* Same backoff as the inode-record reader: a tear is a
             * peer's in-flight write, which takes milliseconds. */
            usleep_range(100, 400);
        }
    }

    pr_err("node row %u failed its checksum repeatedly -- corrupted, not just a torn concurrent read\n", idx);
    cetrafs_sb_corrupt(sb, 0);
    return -EUCLEAN;
}

/* There is no blind row writer any more, and that is the point: a Node
 * Registry row is only ever changed by one compare-and-swap of its own
 * sector (cetrafs_cas_record). The last blind full-row write was
 * mark-offline's, and it could revert a peer's fence_epoch bump -- see
 * cetrafs_node_depart_mutate(). */

/*
 * Read-only passthrough for procfs.c's "cluster" dump -- every other file in this codebase that needs a specific row
 * already lives in this file, so this is the one place that needed a
 * public door into the private, static cetrafs_read_node_entry() above.
 */
int cetrafs_node_get_entry(struct super_block *sb, u32 idx, cetrafs_node_entry_t *out)
{
    return cetrafs_read_node_entry(sb, idx, out);
}

/* LBA of the block holding Node Registry row #idx (one row per block
 * since v0x0007). Exposed for caw.c's CAS self-test, which needs a block
 * this node exclusively owns to exercise the primitive against. */
u64 cetrafs_node_row_lba(struct super_block *sb, u32 idx)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);

    if (!raw_sb || idx >= le32_to_cpu(raw_sb->node_table_count))
        return 0;
    return le64_to_cpu(raw_sb->node_table_start) + idx;
}

/* Stamp 'ne' and write it back as the CAS image: checksum, copy, and
 * zero-fill the rest of the region, so every row writer produces the
 * byte-identical image -- which is what lets any one writer's output
 * serve as another's compare image (cetrafs_write_node_entry()
 * blind-writes the whole block zero-filled for the same reason). */
static void cetrafs_node_image_commit(void *image, unsigned int len, cetrafs_node_entry_t *ne)
{
    ne->checksum = cetrafs_cpu_to_le64(cetrafs_node_crc(ne));
    memcpy(image, ne, sizeof(*ne));
    if (len > sizeof(*ne))
        memset((u8 *) image + sizeof(*ne), 0, len - sizeof(*ne));
}

/* Context + mutator for the CAS-based free-row claim below. */
/*
 * What this mount advertises in its row's caps: LIVE_GROW for any node on
 * this code, and NO_CAW when it runs the no-CAW single-mounter fallback --
 * which is what lets a CAW node joining later refuse instead of forming a
 * cluster whose two halves exclude nothing from each other
 * (cetrafs_node_nocaw_peer_exists()).
 */
static u32 cetrafs_node_my_caps(struct super_block *sb)
{
    return CETRAFS_NODE_CAP_LIVE_GROW | (cetrafs_sb_mount_has_caw(sb) ? 0 : CETRAFS_NODE_CAP_NO_CAW);
}

struct cetrafs_node_claim_ctx {
    const u8 *uuid;
    /* The mutator runs inside the compare-and-swap and has no super_block
     * to ask, so this mount's advertised beat rate is passed in. */
    unsigned int hb_interval;
    /* The cluster file-lock mode to advertise in our row (already resolved
     * by fill_super: adopted from the lead, or our own if we ARE the lead). */
    u32 file_lock_mode;
    u32 caps; /* CETRAFS_NODE_CAP_* this mount advertises */
};

static int cetrafs_node_claim_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_node_claim_ctx *ctx = priv;
    cetrafs_node_entry_t ne;

    memcpy(&ne, image, sizeof(ne));

    /* Only FREE rows are claimable. mkfs leaves the whole table
     * zero-filled and never stamps a FREE row's checksum, so state is
     * the only field that may be trusted here -- exactly as
     * cetrafs_read_node_entry() documents. */
    if (ne.state != CETRAFS_NODE_STATE_FREE)
        return -EEXIST;

    memset(&ne, 0, sizeof(ne));
    memcpy(ne.node_uuid, ctx->uuid, CETRAFS_NODE_UUID_LEN);
    ne.state = cetrafs_cpu_to_le32(CETRAFS_NODE_STATE_REGISTERED);
    ne.hb_seq = cetrafs_cpu_to_le64(1);
    ne.last_seen = cetrafs_cpu_to_le64(ktime_get_real_seconds());
    /* Advertise our tick rate so peers can floor their staleness window
     * at several of OUR beats, rather than at whatever they happen to be
     * configured with. */
    ne.hb_interval_secs = cetrafs_cpu_to_le32(ctx->hb_interval);
    ne.file_lock_mode = cetrafs_cpu_to_le32(ctx->file_lock_mode);
    /* Advertise what this build understands. A constant for the running
     * module -- any node on this code is live-grow-safe; a node without
     * it leaves 0 here and a grow excludes it. */
    ne.caps = cetrafs_cpu_to_le32(ctx->caps);
    strscpy(ne.label, init_utsname()->nodename, sizeof(ne.label));

    cetrafs_node_image_commit(image, len, &ne);
    return 0;
}

/*
 * Context + mutator for the CAS-based re-attach (registration pass 1): a
 * row already carries our UUID from a previous incarnation of this node,
 * and we take it back -- preserving everything that happened to it while
 * we were away, fence_epoch above all.
 *
 * this replaced a blind cetrafs_write_node_entry() of a row
 * read moments earlier. The blind write raced the one legitimate foreign
 * writer of our row -- a peer's fence_epoch bump, which is a CAS -- and a
 * bump landing between our read and our write was silently REVERTED, with
 * the local lease then baselined from the same stale read. The peer would
 * go on replaying our journal and stealing our ZGs believing us fenced,
 * while we came up live, unfenced, and writing: its blind redo of our old
 * block images racing our new writes. The CAS makes the bump un-losable:
 * it either lands before us (the retry re-reads and PRESERVES it, and we
 * baseline it as a pre-join bump) or after us (our next heartbeat check
 * sees the epoch move and self-fences).
 */
struct cetrafs_node_reattach_ctx {
    const u8 *uuid;
    unsigned int hb_interval;
    u32 file_lock_mode;
    u32 caps;          /* CETRAFS_NODE_CAP_* this mount advertises */
    u64 expect_hb_seq; /* the beat count the row had when it was judged ours */
    bool twin;         /* out: the row beat since -- another machine took it */
    u64 fence_epoch;   /* out: the epoch in the image the swap committed */
    u64 hb_seq;        /* out: for the caller's log line */
};

static int cetrafs_node_reattach_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_node_reattach_ctx *ctx = priv;
    cetrafs_node_entry_t ne;

    memcpy(&ne, image, sizeof(ne));

    /* The row must still be OURS at the moment the swap lands: one freed
     * or re-claimed by someone else between the scan that found it and
     * this CAS is not re-attachable, and the caller moves on. */
    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED ||
        memcmp(ne.node_uuid, ctx->uuid, CETRAFS_NODE_UUID_LEN) != 0)
        return -EEXIST;

    /* And it must not have beaten since it was judged ours. Only the
     * row's owner moves hb_seq (a peer's fence bump touches fence_epoch),
     * and our previous incarnation is gone -- so a beat in between is a
     * machine with our identity re-attaching or renewing first. Two
     * clones of a cleanly unmounted VM both skip the watch (last_seen 0)
     * and would otherwise both land here, on one row. */
    if (cetrafs_le64(ne.hb_seq) != ctx->expect_hb_seq) {
        ctx->twin = true;
        return -EEXIST;
    }

    ne.hb_seq = cetrafs_cpu_to_le64(cetrafs_le64(ne.hb_seq) + 1);
    ne.last_seen = cetrafs_cpu_to_le64(ktime_get_real_seconds());
    ne.hb_interval_secs = cetrafs_cpu_to_le32(ctx->hb_interval);
    /* Re-stamp the cluster file-lock mode: a returning node conforms to
     * whatever the cluster is now, not whatever it ran last time. */
    ne.file_lock_mode = cetrafs_cpu_to_le32(ctx->file_lock_mode);
    /* And re-advertise this build's capabilities: an upgraded module
     * re-attaching to its old row must publish what it now supports. */
    ne.caps = cetrafs_cpu_to_le32(ctx->caps);

    /* fence_epoch (and everything else) rides through untouched, and the
     * value reported back to the caller is the one in the image this swap
     * actually commits -- never an earlier read's. */
    ctx->fence_epoch = cetrafs_le64(ne.fence_epoch);
    ctx->hb_seq = cetrafs_le64(ne.hb_seq);

    cetrafs_node_image_commit(image, len, &ne);
    return 0;
}

/* --- the fence lease --------------------------------
 *
 * Replaces SCSI PR registration as the signal "a peer has declared me
 * dead". Any node that reclaims something from a stale peer bumps that
 * peer's fence_epoch; the peer notices on its next heartbeat tick and
 * fences itself. See cetrafs_node_entry_t.fence_epoch.
 */
struct cetrafs_node_fence_ctx {
    u64 seen_epoch;     /* out: the epoch after the bump */
    bool mark_departed; /* also stamp the clean-departure sentinel */
};

static int cetrafs_node_fence_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_node_fence_ctx *ctx = priv;
    cetrafs_node_entry_t ne;

    memcpy(&ne, image, sizeof(ne));

    /* Only a REGISTERED row carries a lease worth revoking. A row that
     * has already gone FREE has no owner left to fence. */
    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED)
        return 1; /* nothing to do -- not an error */

    ne.fence_epoch = cetrafs_cpu_to_le64(cetrafs_le64(ne.fence_epoch) + 1);
    ctx->seen_epoch = cetrafs_le64(ne.fence_epoch);
    /* Record the verdict as well as revoking the lease: last_seen = 0 is
     * this format's "left deliberately" sentinel, and writing it means
     * the next observer costs one block read instead of another full
     * watch window. Only the mount gate asks for this, because only the
     * mount gate has actually WATCHED the row long enough to conclude
     * it. (The row stays REGISTERED so the owner can still re-attach by
     * UUID on its next mount -- freeing it would cost that node its own
     * identity, which is the bug cetrafs_node_mark_offline() was written
     * around.) */
    if (ctx->mark_departed)
        ne.last_seen = 0;

    cetrafs_node_image_commit(image, len, &ne);
    return 0;
}

/*
 * Leave: clear our own last_seen, the "departed deliberately" sentinel,
 * and touch nothing else.
 *
 * As a CAS, not a read-modify-write. The blind write this replaces
 * carried a comment claiming "a concurrent fence_epoch bump is carried
 * through rather than reverted" -- which is exactly backwards: the
 * whole row goes back from a copy read before the bump, so the bump is
 * what gets reverted. A peer that fenced us while we were unmounting
 * had its revocation quietly undone, and this node's next incarnation
 * re-attached by UUID and cached an epoch that no longer reflected
 * reality.
 *
 * CLAUDE.md rule 7: a comment asserting a safety property is a claim,
 * not a premise. This one named its own hazard and got the direction
 * wrong.
 */
static int cetrafs_node_depart_mutate(void *image, unsigned int len, void *priv)
{
    cetrafs_node_entry_t ne;

    (void) priv;
    memcpy(&ne, image, sizeof(ne));

    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED)
        return 1; /* already gone: nothing to do, and not an error */
    if (ne.last_seen == 0)
        return 1; /* somebody already recorded our departure */

    ne.last_seen = 0;
    cetrafs_node_image_commit(image, len, &ne);
    return 0;
}

/*
 * TEST ONLY: make revoking a peer's lease fail, as a device error on its
 * registry row would. Nothing a single-node test can arrange makes that
 * CAS fail on its own.
 */
static bool cetrafs_fence_peer_fail;
module_param_named(fence_peer_fail, cetrafs_fence_peer_fail, bool, 0644);
MODULE_PARM_DESC(fence_peer_fail, "TEST ONLY: revoking a stale peer's lease fails");

/*
 * Revoke a stale peer's lease, because we are about to take something
 * that was his. Call this at the moment of reclaim, not merely on
 * noticing staleness -- a staleness CHECK is not a reclaim, and fencing
 * a node nobody has actually taken anything from would be wrong.
 *
 * NOT best-effort. It used to be: the error was logged and swallowed and
 * the caller went on to replay the peer's journal or take its lock or
 * Zone Group -- the one moment the revocation exists for. A peer that is
 * slow rather than dead then never learns it was declared dead, keeps
 * writing, and the replay blind-writes its recorded images over blocks
 * it is still working. Staleness alone is a guess; the lease is what
 * makes it safe to act on. So a caller that is about to take something
 * must stop when this fails, and try again later.
 *
 * 0 also when there is no lease left to revoke (the row is no longer
 * REGISTERED: nobody holds it to keep writing under).
 */
static int cetrafs_node_fence_peer_full(struct super_block *sb, u32 node_id, const char *what, bool mark_departed)
{
    struct cetrafs_node_fence_ctx ctx = {.mark_departed = mark_departed};
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    int ret;

    if (!raw_sb)
        return -EINVAL;
    /* An id past the registry was never handed out (cetrafs_node_is_stale()
     * already calls it stale): there is no lease to revoke, and nothing
     * that could still be using what it names. Refusing here made every
     * caller read "not revoked" and keep the claim for good -- a lock, a
     * presence bit, a ZG nothing could ever take back. */
    if (node_id >= le32_to_cpu(raw_sb->node_table_count)) {
        pr_warn_ratelimited("fence: a claim names node %u, outside the registry (%u rows) -- nothing to revoke, "
                            "reclaiming %s\n",
                            node_id, le32_to_cpu(raw_sb->node_table_count), what);
        return 0;
    }

    ret = cetrafs_cas_record(sb, cetrafs_node_row_lba(sb, node_id), cetrafs_node_fence_mutate, &ctx);
    if (ret < 0) {
        pr_err_ratelimited("fence: could not revoke stale node %u's lease (%d) -- not reclaiming %s\n", node_id, ret,
                           what);
        return ret;
    }
    if (ctx.seen_epoch)
        pr_info("fence: revoked stale node %u's lease (epoch %llu) while reclaiming %s\n", node_id,
                (unsigned long long) ctx.seen_epoch, what);
    return 0;
}

int cetrafs_node_fence_peer(struct super_block *sb, u32 node_id, const char *what)
{
    /*
     * A node whose own lease was revoked takes nothing from anybody:
     * its peers have declared it dead and are reclaiming from it. Every
     * caller is about to reclaim, and several are reachable without a
     * write (a read-only open past a stale lock), which is where the
     * per-path fence checks did not look.
     */
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    /* The reclaim paths only: the no-CAW mount gate's own verdict goes
     * through _full() and is not what the knob is for. */
    if (unlikely(cetrafs_fence_peer_fail)) {
        pr_err_ratelimited("fence: could not revoke stale node %u's lease (%d) -- not reclaiming %s\n", node_id, -EIO,
                           what);
        return -EIO;
    }
    return cetrafs_node_fence_peer_full(sb, node_id, what, false);
}

/*
 * Has a peer declared US dead? Reads this node's own row fresh and
 * compares it against what we registered with.
 *
 * Three ways to fail, all meaning the same thing -- our claim on this
 * row is no longer ours:
 *   - the epoch moved: a peer reclaimed something of ours;
 *   - the row is no longer REGISTERED: someone released it;
 *   - the UUID changed: the row was freed and handed to another node.
 */
int cetrafs_node_self_fence_check(struct super_block *sb, u32 my_node_id, bool *out_fenced)
{
    cetrafs_node_entry_t ne;
    u8 my_uuid[CETRAFS_NODE_UUID_LEN];
    int ret;

    *out_fenced = false;

    ret = cetrafs_sb_get_node_uuid(sb, my_uuid);
    if (ret)
        return ret;

    ret = cetrafs_read_node_entry(sb, my_node_id, &ne);
    if (ret)
        return ret; /* transient read trouble is not evidence of a fence */

    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED ||
        memcmp(ne.node_uuid, my_uuid, CETRAFS_NODE_UUID_LEN) != 0 ||
        cetrafs_le64(ne.fence_epoch) != cetrafs_sb_get_fence_epoch(sb))
        *out_fenced = true;

    return 0;
}

/*
 * Find or claim this node's row. On success, *out_node_id is the row
 * index (what owner_node_id and the inode lock fields will reference in
 * later phases), the row is REGISTERED with a bumped heartbeat, and
 * out_uuid carries this node's parsed 16-byte UUID (so callers like
 * fs.c don't need to re-parse get_stable_machine_uuid() themselves --
 * e.g. to derive a PR key for zonegroup.c's ZG claiming).
 */
/* TEST ONLY: just before the re-attach swap, bump this node's OWN
 * fence_epoch the way a concurrently-reclaiming peer would -- i.e. inject
 * the peer's CAS into the exact window between the registration scan's
 * read and the re-attach write. With the CAS re-attach the bump survives
 * (preserved and baselined); with the blind write it reverted to the
 * stale read's value, silently un-fencing a node a peer was mid-reclaim
 * of. A real peer cannot be timed into a window this narrow from a test
 * script, same reasoning as every other force knob here. Off in
 * production. */
static bool cetrafs_reattach_race_bump;
module_param_named(reattach_race_bump, cetrafs_reattach_race_bump, bool, 0644);
MODULE_PARM_DESC(reattach_race_bump, "TEST ONLY: bump our own fence_epoch mid re-attach, as a racing reclaimer would");

/* TEST ONLY: play a second machine with this machine's identity mounting
 * at the same instant -- its re-attach landing between our scan and our
 * re-attach swap, or its claim of another free row landing just after
 * ours. Two clones booting together cannot be timed from a script on one
 * machine. Off in production. */
static bool cetrafs_register_twin_race;
module_param_named(register_twin_race, cetrafs_register_twin_race, bool, 0644);
MODULE_PARM_DESC(register_twin_race, "TEST ONLY: a machine with our identity registers in the middle of our registration");

static int cetrafs_node_test_beat_mutate(void *image, unsigned int len, void *priv)
{
    cetrafs_node_entry_t ne;

    memcpy(&ne, image, sizeof(ne));
    ne.hb_seq = cetrafs_cpu_to_le64(cetrafs_le64(ne.hb_seq) + 1);
    ne.last_seen = cetrafs_cpu_to_le64(ktime_get_real_seconds());
    cetrafs_node_image_commit(image, len, &ne);
    return 0;
}

/* Give back a row this mount claimed moments ago and must not keep:
 * only while it is still exactly the fresh claim (ours, never beaten). */
static int cetrafs_node_unclaim_mutate(void *image, unsigned int len, void *priv)
{
    const u8 *uuid = priv;
    cetrafs_node_entry_t ne;

    memcpy(&ne, image, sizeof(ne));
    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED ||
        memcmp(ne.node_uuid, uuid, CETRAFS_NODE_UUID_LEN) != 0 || cetrafs_le64(ne.hb_seq) != 1)
        return -EEXIST;
    memset(image, 0, len);
    return 0;
}

static void cetrafs_node_refuse_twin(u32 idx)
{
    pr_err("node registration: row %u carries this machine's identity and another machine is registering with "
           "it -- a node with the same node UUID (a cloned VM, or firmware without a unique one). Refusing to "
           "mount as the same node; give one of them its own with cetrafs.node_uuid=<uuid>\n",
           idx);
}

/*
 * After claiming a fresh row: is any OTHER row registered with our
 * identity? Pass 1 re-attaches every such row it can see, so one found
 * now appeared during this registration -- a twin that claimed its own
 * row at the same time. Both claims are durable CASes before either scan,
 * so of two twins at least the later scanner sees the other and refuses;
 * if both see each other, both refuse. Loud and safe either way.
 */
static int cetrafs_node_twin_row(struct super_block *sb, u32 mine, const u8 *uuid, u32 *out_idx)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 count = le32_to_cpu(raw_sb->node_table_count), idx;
    cetrafs_node_entry_t ne;
    int ret;

    for (idx = 0; idx < count; idx++) {
        if (idx == mine)
            continue;
        ret = cetrafs_read_node_entry(sb, idx, &ne);
        if (ret)
            return ret;
        if (cetrafs_le32(ne.state) == CETRAFS_NODE_STATE_REGISTERED &&
            !memcmp(ne.node_uuid, uuid, CETRAFS_NODE_UUID_LEN)) {
            *out_idx = idx;
            return 1;
        }
    }
    return 0;
}

/*
 * Watch row 'idx' (as read into 'ne') for long enough that a node
 * beating at its advertised interval must move hb_seq at least once:
 * 0 if it did not, -EBUSY if it did. Two beats plus margin, the same
 * window the userspace tools use (devutil.h's cetrafs_probe_window());
 * the advertised interval is clamped so a corrupt row cannot park the
 * mount for days.
 */
static int cetrafs_node_row_quiet(struct super_block *sb, u32 idx, const cetrafs_node_entry_t *ne)
{
    u32 pi = min_t(u32, cetrafs_le32(ne->hb_interval_secs), CETRAFS_HB_INTERVAL_MAX_SECS);
    cetrafs_node_entry_t now;
    u32 window;
    int ret;

    if (!pi)
        pi = CETRAFS_HEARTBEAT_INTERVAL_SECS;
    window = 2 * pi + 5;
    pr_info(
        "node registration: row %u carries this machine's identity and was not left cleanly -- watching it "
        "%us to be sure no other machine is using it\n",
        idx, window);
    if (msleep_interruptible(window * 1000))
        return -EINTR;
    ret = cetrafs_read_node_entry(sb, idx, &now);
    if (ret)
        return ret;
    return now.hb_seq == ne->hb_seq ? 0 : -EBUSY;
}

int cetrafs_node_register(struct super_block *sb,
                          u32 file_lock_mode,
                          u32 *out_node_id,
                          u8 out_uuid[CETRAFS_NODE_UUID_LEN])
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    const char *uuid_str;
    uuid_t my_uuid;
    cetrafs_node_entry_t ne;
    u32 count, idx;
    bool any_free = false, lost_race = false;
    int ret;

    if (!raw_sb)
        return -EINVAL;

    if (!(le64_to_cpu(raw_sb->features_incompat) & CETRAFS_FEAT_INCOMPAT_NODE_REGISTRY))
        return -EOPNOTSUPP;

    uuid_str = get_stable_machine_uuid();
    if (!uuid_str)
        return -EIO;

    ret = uuid_parse(uuid_str, &my_uuid);
    if (ret)
        return ret;

    memcpy(out_uuid, my_uuid.b, CETRAFS_NODE_UUID_LEN);

    count = le32_to_cpu(raw_sb->node_table_count);

    /* Pass 1: re-attach if a row already carries our UUID. */
    for (idx = 0; idx < count; idx++) {
        ret = cetrafs_read_node_entry(sb, idx, &ne);
        if (ret)
            return ret;

        if (ne.state == CETRAFS_NODE_STATE_FREE) {
            any_free = true;
            continue;
        }

        if (cetrafs_le32(ne.state) == CETRAFS_NODE_STATE_REGISTERED &&
            !memcmp(ne.node_uuid, my_uuid.b, CETRAFS_NODE_UUID_LEN)) {
            struct cetrafs_node_reattach_ctx ctx = {.uuid = my_uuid.b,
                                                    .hb_interval = cetrafs_heartbeat_interval_secs(sb),
                                                    .file_lock_mode = file_lock_mode,
                                                    .caps = cetrafs_node_my_caps(sb),
                                                    .expect_hb_seq = cetrafs_le64(ne.hb_seq)};

            /* Is the row ours because we LEFT it, or because another
             * machine with our identity is using it right now? A clean
             * departure (last_seen == 0) answers itself. Otherwise watch
             * it: a previous incarnation of this machine that crashed
             * never beats again, a live twin does. Taking a live twin's
             * row makes two machines one node -- same Zone Groups, same
             * allocations -- which nothing downstream can detect. Paid
             * only on a mount after an unclean shutdown. */
            if (ne.last_seen != 0) {
                ret = cetrafs_node_row_quiet(sb, idx, &ne);
                if (ret == -EBUSY) {
                    pr_err(
                        "node registration: row %u carries this machine's identity and is still heartbeating -- "
                        "another machine has the same node UUID (a cloned VM, or firmware without a unique "
                        "one). Refusing to mount as the same node; give one of them its own with "
                        "cetrafs.node_uuid=<uuid>\n",
                        idx);
                    return ret;
                }
                if (ret)
                    return ret;
            }

            if (cetrafs_register_twin_race) /* test knob, see its MODULE_PARM_DESC */
                (void) cetrafs_cas_record(sb, cetrafs_node_row_lba(sb, idx), cetrafs_node_test_beat_mutate, NULL);
            if (cetrafs_reattach_race_bump) /* test knob, see its MODULE_PARM_DESC */
                (void) cetrafs_node_fence_peer_full(sb, idx, "a test-forced concurrent reclaim (reattach_race_bump)", false);

            /* The take-back is a CAS, never a blind write of the row read
             * above -- see cetrafs_node_reattach_mutate() for the fence
             * bump that blind write could silently revert. */
            ret = cetrafs_cas_record(sb, cetrafs_node_row_lba(sb, idx), cetrafs_node_reattach_mutate, &ctx);
            if (ret == -EEXIST && ctx.twin) {
                cetrafs_node_refuse_twin(idx);
                return -EBUSY;
            }
            if (ret == -EEXIST)
                continue; /* stopped being ours between the read and the swap */
            if (ret)
                return ret;

            pr_info("node registration: re-attached row %u (hb_seq=%llu)\n", idx, (unsigned long long) ctx.hb_seq);
            /* Left without unmounting: every claim the previous
             * incarnation stamped with this row is still on the device,
             * and re-attaching makes them read as LIVE again -- nobody
             * reclaims from a node that beats. The mount sweeps them
             * (cetrafs_lock_sweep_own_claims()). */
            if (ne.last_seen != 0)
                cetrafs_sb_note_unclean_reattach(sb);
            /* Baseline the fence lease at the epoch in the image the swap
             * COMMITTED -- including epochs bumped while we were away (a
             * previous incarnation being fenced must not fence this fresh
             * join) and one bumped during the swap itself (a MISCOMPARE
             * retry re-reads and preserves it). A bump landing after the
             * swap is the ordinary case the next heartbeat check catches. */
            cetrafs_sb_set_fence_epoch(sb, ctx.fence_epoch);
            *out_node_id = idx;
            return 0;
        }
    }

    if (!any_free) {
        pr_err("node registration: registry full (%u rows)\n", count);
        return -ENOSPC;
    }

    /* Pass 2: no existing row -- claim a free one, as ONE atomic
     * compare-and-swap of the row's own sector.
     *
     * This replaces the old lock / read / check / write / read-back /
     * unlock dance. The CAS *is* the check-and-claim: the mutator below
     * only produces a new image if it still sees a FREE row, and the
     * swap only lands if the sector is byte-for-byte what the mutator
     * was shown. A peer claiming the same row in between makes the
     * device reject the swap (MISCOMPARE), cetrafs_cas_record() re-reads
     * and re-invokes the mutator, which now sees a taken row and says so
     * -- so a lost race is detected by construction rather than by a
     * verify-read that could itself be stale. On hardware without atomic
     * CAW this degrades inside cetrafs_cas_record() to exactly the old
     * behavior (cluster mutex around a fresh read-modify-write). */
    for (idx = 0; idx < count; idx++) {
        struct cetrafs_node_claim_ctx ctx = {
            .uuid = my_uuid.b,
            .hb_interval = cetrafs_heartbeat_interval_secs(sb),
            .file_lock_mode = file_lock_mode,
            .caps = cetrafs_node_my_caps(sb),
        };

        ret = cetrafs_cas_record(sb, cetrafs_node_row_lba(sb, idx), cetrafs_node_claim_mutate, &ctx);
        if (ret == 0) {
            u32 twin, j;
            int tret;

            if (cetrafs_register_twin_race) { /* test knob, see its MODULE_PARM_DESC */
                for (j = idx + 1; j < count; j++)
                    if (!cetrafs_cas_record(sb, cetrafs_node_row_lba(sb, j), cetrafs_node_claim_mutate, &ctx))
                        break;
            }
            tret = cetrafs_node_twin_row(sb, idx, my_uuid.b, &twin);
            if (tret) {
                if (tret > 0)
                    cetrafs_node_refuse_twin(twin);
                if (cetrafs_cas_record(sb, cetrafs_node_row_lba(sb, idx), cetrafs_node_unclaim_mutate, my_uuid.b))
                    pr_warn("node registration: could not give back row %u\n", idx);
                return tret > 0 ? -EBUSY : tret;
            }
            pr_info("node registration: claimed row %u (%s)\n", idx,
                    cetrafs_sb_caw_available(sb) ? "atomic CAS" : "no-CAW fallback");
            cetrafs_sb_set_fence_epoch(sb, 0); /* the mutator zeroes the row */
            *out_node_id = idx;
            return 0;
        }
        if (ret == -EEXIST)
            continue; /* row not free (any more) -- try the next one */
        if (ret == -EBUSY) {
            pr_warn("node registration: lost the race for row %u, trying the next free row\n", idx);
            lost_race = true;
            continue;
        }
        return ret; /* real I/O error */
    }

    pr_err("node registration: %s claiming a row (%u rows)\n", lost_race ? "lost every race" : "found none free",
           count);
    return lost_race ? -EBUSY : -ENOSPC;
}

/*
 * Periodic self-renewal (called from heartbeat.c's
 * delayed_work): bump our own row's hb_seq/last_seen so other nodes
 * watching it don't mistake a merely-slow node for a dead one.
 *
 * No separate lock here -- unlike the contested free-row claim above,
 * nobody else should ever be writing to our own row while we hold it,
 * so this is routine upkeep, not a race to arbitrate. It is one CAS of
 * the row's sector, which fails (and the mutator refuses) if the row is
 * no longer ours; there is no read-back after it.
 */
struct cetrafs_node_renew_ctx {
    u64 expect_epoch; /* the lease we registered with */
    bool fenced;      /* out: the epoch moved -- a peer revoked us */
    u8 my_uuid[CETRAFS_NODE_UUID_LEN];
    bool lost;        /* out: the row is not ours any more (freed, a repairer's, another node's) */
    /* This mount's advertised beat rate: the mutator runs inside the
     * compare-and-swap and has no super_block to ask. */
    unsigned int hb_interval;
};

static int cetrafs_node_renew_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_node_renew_ctx *ctx = priv;
    cetrafs_node_entry_t ne;

    memcpy(&ne, image, sizeof(ne));

    /* Not REGISTERED, or registered to someone else: whoever changed it
     * decided this row is no longer ours -- a peer that freed it, an
     * offline repairer that took it, a node that registered into it.
     * That is a revoked lease in every way that matters, and writing
     * our heartbeat into it would fight whoever holds it now. It used to
     * be -EINVAL, which the tick only logged before going on to claim,
     * drain and replay as a node nobody believes exists. */
    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED ||
        memcmp(ne.node_uuid, ctx->my_uuid, CETRAFS_NODE_UUID_LEN) != 0) {
        ctx->lost = true;
        return 1; /* write nothing */
    }

    /* The whole point of doing this as a compare-and-swap: renewing used
     * to be read / modify / blind-write-the-whole-row, so a peer that
     * revoked our lease between the read and the write had its
     * fence_epoch bump REVERTED by us -- silently, since the read-back
     * only compared hb_seq. The node then kept renewing, kept comparing
     * against a rolled-back epoch, and never fenced: exactly the
     * split-brain the lease exists to prevent, on a path that runs every
     * 15 seconds. Inside the CAS the test and the renewal are one
     * operation, and the image is whatever the peer actually left. */
    if (cetrafs_le64(ne.fence_epoch) != ctx->expect_epoch) {
        ctx->fenced = true;
        return 1; /* do not renew: write nothing at all */
    }

    ne.hb_seq = cetrafs_cpu_to_le64(cetrafs_le64(ne.hb_seq) + 1);
    ne.last_seen = cetrafs_cpu_to_le64((u64) ktime_get_real_seconds());
    /* Re-published every tick: the rate is a runtime-writable module
     * parameter, so a peer must see the value we are ACTUALLY running
     * at, not the one we registered with. */
    ne.hb_interval_secs = cetrafs_cpu_to_le32(ctx->hb_interval);
    ne.checksum = cetrafs_cpu_to_le64(cetrafs_node_crc(&ne));

    memcpy(image, &ne, sizeof(ne));
    if (len > sizeof(ne))
        memset((u8 *) image + sizeof(ne), 0, len - sizeof(ne));
    return 0;
}

/*
 * Renew this node's own row. Returns -EPERM if a peer has revoked our
 * lease, -EOWNERDEAD if the row is no longer ours at all; the caller
 * must treat both as "fence yourself", never as a transient error.
 */
int cetrafs_node_renew_heartbeat(struct super_block *sb, u32 my_node_id)
{
    struct cetrafs_node_renew_ctx ctx = {.expect_epoch = cetrafs_sb_get_fence_epoch(sb),
                                         .hb_interval = cetrafs_heartbeat_interval_secs(sb)};
    int ret = cetrafs_sb_get_node_uuid(sb, ctx.my_uuid);

    if (ret)
        return ret;
    ret = cetrafs_cas_record(sb, cetrafs_node_row_lba(sb, my_node_id), cetrafs_node_renew_mutate, &ctx);

    if (ctx.lost)
        return -EOWNERDEAD;
    if (ctx.fenced)
        return -EPERM;
    return ret < 0 ? ret : 0;
}

/*
 * Clean unmount (or a later-failing mount attempt after registration
 * already succeeded -- see fs.c's cetrafs_free_sb_info()) signals that
 * this node is deliberately leaving, so a peer doesn't have to wait out
 * the full CETRAFS_NODE_STALE_SECS heartbeat timeout before reclaiming
 * this node's ZGs/locks -- caught via a real two-node report: after
 * unmounting one node, its row kept reading state=REGISTERED, stale=no
 * for the whole timeout window, exactly as if it had merely gone quiet
 * rather than actually left.
 *
 * An earlier version of this function freed the row outright (state ->
 * FREE), which is wrong: this node's own re-attach on its *next* mount
 * (cetrafs_node_register()'s pass 1) depends on finding this exact row
 * still REGISTERED under its UUID. Freeing it here would make every
 * ordinary unmount/remount cycle -- not just a genuine departure --
 * cost this node its own identity and (via owner_node_id on every ZG it
 * owns) its own ZG ownership, indistinguishable from a crash. Caught by
 * tests/mount_test.sh's own remount-reattach check before this ever
 * shipped.
 *
 * Instead, this backdates last_seen to the epoch -- the one input
 * cetrafs_node_is_stale() actually uses for a REGISTERED row -- so
 * staleness reads as immediate to every peer without disturbing
 * state/node_uuid/hb_seq at all: zonegroup.c's reclaim and lock.c's
 * lazy reclaim both see this node's former claims as free for the
 * taking right away, no explicit per-ZG/per-lock release needed (the
 * existing stale-owner reclaim path already handles "owner_node_id
 * points at a stale row", and now it fires immediately instead of
 * after a timeout). The next real mount re-attaches to this same row
 * exactly as before and simply bumps last_seen back to "now".
 *
 * No PR lock here, matching cetrafs_node_renew_heartbeat()'s reasoning:
 * this is our own row, already confirmed REGISTERED to us, and nobody
 * else should be concurrently writing to it. The read-back afterward is
 * still worth doing (same "never trust a write silently" posture as
 * everywhere else in this codebase), but a mismatch here means real
 * corruption, not a lost race against another node.
 */
/*
 * TEST ONLY: pause inside mark-offline, between reading our row and
 * recording the departure.
 *
 * That gap is where a peer's fence_epoch bump used to be lost: the row
 * was written back whole from the copy read before it. The window is
 * microseconds wide in production, which is why the blind write
 * survived review -- and why a test needs it held open. See
 * tests/kernel/node_offline_fence.sh.
 */
static unsigned int cetrafs_node_offline_delay_ms;
module_param_named(node_offline_delay_ms, cetrafs_node_offline_delay_ms, uint, 0644);
MODULE_PARM_DESC(node_offline_delay_ms, "TEST ONLY: pause inside mark-offline before recording the departure");

int cetrafs_node_mark_offline(struct super_block *sb, u32 my_node_id)
{
    cetrafs_node_entry_t ne, check;
    int ret;

    ret = cetrafs_read_node_entry(sb, my_node_id, &ne);
    if (ret)
        return ret;

    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED) {
        pr_err("node mark-offline: row %u is not REGISTERED (state=%u)\n", my_node_id, ne.state);
        return -EINVAL;
    }

    if (cetrafs_node_offline_delay_ms)
        msleep(cetrafs_node_offline_delay_ms); /* test-only; see the parameter */

    /* One CAS of the row's own sector -- see cetrafs_node_depart_mutate().
     * Renewal has always done it this way; this path blind-wrote the
     * whole row and could revert a peer's fence_epoch bump. */
    ret = cetrafs_cas_record(sb, cetrafs_node_row_lba(sb, my_node_id), cetrafs_node_depart_mutate, NULL);
    if (ret < 0)
        return ret;

    ret = cetrafs_read_node_entry(sb, my_node_id, &check);
    if (ret)
        return ret;

    if (check.last_seen != 0) {
        pr_err("node mark-offline: row %u didn't read back with last_seen cleared\n", my_node_id);
        return -EIO;
    }

    pr_info("node mark-offline: row %u backdated, now immediately reclaimable by a peer\n", my_node_id);
    return 0;
}

/*
 * Is Node Registry row 'node_id' stale -- either not a live claim at
 * all, or REGISTERED but its heartbeat hasn't been renewed in over
 * CETRAFS_NODE_STALE_SECS? Used by zonegroup.c (periodic ZG reclaim)
 * and lock.c (lazy, at-open-time file-lock reclaim) to tell "this
 * node's claim is just old" apart from "this node is gone, its claims
 * are up for grabs" -- the entire basis for an earlier phase's
 * timeout-based reclaim.
 *
 * This is advisory, not a guarantee: a node that's merely slow (GC
 * pause, scheduling jitter, a saturated disk) rather than actually dead
 * looks identical to a crashed one here, and reclaiming its ZG/lock
 * while it's still alive and still writing is a genuine split-brain
 * risk this function cannot rule out by itself. The atomic
 * compare-and-swap makes the *moment* of reclaiming a ZG safe (same as
 * any other claim), but doesn't fence the original owner's *ongoing*
 * writes to blocks it still believes are its own; true safety against a
 * false-positive stale reading needs real node fencing, which is the
 * cluster manager's job, not the filesystem's (see docs/LOCKING.md).
 */
/*
 * How long a peer's hb_seq may sit unchanged before we call it dead.
 *
 * A module param purely so tests can compress it: the default is four
 * heartbeat intervals, and a test that had to wait a real minute for
 * every staleness assertion would not get written. Changing it on a live
 * cluster is a way to cause split brain, not a tuning knob -- too small
 * and an ordinarily slow node gets reclaimed out from under itself.
 */
unsigned int cetrafs_stale_secs = CETRAFS_NODE_STALE_SECS;
module_param_named(stale_secs, cetrafs_stale_secs, uint, 0644);
MODULE_PARM_DESC(stale_secs,
                 "seconds a peer may stall before treated as dead (UNBOUNDED test knob; operator limits are on the "
                 "per-mount controls file)");

/* TEST ONLY: make the no-CAW mount gate's live-peer check report a live
 * foreign peer unconditionally, skipping the heartbeat watch. On the loop
 * harness a userspace beater's writes race the kernel's uncached reads, so
 * "a peer is alive" cannot be simulated reliably through the registry; this
 * forces the verdict so nocaw_mount_gate.sh can assert deterministically
 * that a refused mount claims no row. Off in production. */
static bool cetrafs_nocaw_force_live_peer;
module_param_named(nocaw_force_live_peer, cetrafs_nocaw_force_live_peer, bool, 0644);
MODULE_PARM_DESC(nocaw_force_live_peer, "TEST ONLY: no-CAW gate always sees a live peer");

/* TEST ONLY: force the observed cluster file-lock mode, -1 = off (real
 * scan). See cetrafs_node_cluster_file_lock_mode(). */
static int cetrafs_force_cluster_flock_mode = -1;
module_param_named(force_cluster_flock_mode, cetrafs_force_cluster_flock_mode, int, 0644);
MODULE_PARM_DESC(force_cluster_flock_mode,
                 "TEST ONLY: force cluster file-lock mode (0 unset,1 on,2 off; -1 real scan)");

/* TEST ONLY: force the post-registration mode-conflict re-scan to report a
 * conflict, so the simultaneous-mount unwind can be exercised single-node
 * (a real divergent peer cannot be made to appear on a loop device). See
 * cetrafs_node_file_lock_mode_conflict(). */
static bool cetrafs_force_mode_conflict;
module_param_named(force_mode_conflict, cetrafs_force_mode_conflict, bool, 0644);
MODULE_PARM_DESC(force_mode_conflict, "TEST ONLY: post-registration mode re-scan always reports a conflict");

/* TEST ONLY: make the post-registration no-CAW single-mounter re-check
 * (cetrafs_node_single_mounter_conflict()) report a live foreign row
 * unconditionally. Two nodes genuinely racing one mount cannot be simulated
 * on the single-node loop harness, so this forces the lost-race verdict to
 * prove the re-check refuses, unwinds, and leaves the volume mountable.
 * Off in production. */
static bool cetrafs_nocaw_force_postreg_peer;
module_param_named(nocaw_force_postreg_peer, cetrafs_nocaw_force_postreg_peer, bool, 0644);
MODULE_PARM_DESC(nocaw_force_postreg_peer, "TEST ONLY: no-CAW post-registration re-check always sees a live peer");

/*
 * Is any OTHER node currently mounted on this volume?
 *
 * This is the no-CAW mount gate's question (fs.c). A device with no
 * atomic COMPARE AND WRITE has no cross-node mutual exclusion at all,
 * so it can only ever have one mounter, and the mount is refused if
 * there already is one.
 *
 * It replaced "does any other node own a Zone Group?", which was the
 * wrong question in three separate ways:
 *
 *   1. A mounted node need own no Zone Group at all. A read-only mount
 *      claims none by design (it still registers, heartbeats and
 *      publishes read-presence bits -- all writes, all needing the
 *      atomicity this device does not have), and was therefore
 *      completely invisible to a ZG scan.
 *   2. The window it waited was the OBSERVER's stale_secs, which says
 *      how long we are willing to wait and nothing about how often the
 *      peer actually beats -- P17's finding, fixed in
 *      cetrafs_node_is_stale() and not here, because the enumeration
 *      was by function rather than by property. A peer beating slower
 *      than our window reads as dead, and the gate then admits a SECOND
 *      mounter to a volume with no cross-node atomicity: precisely the
 *      catastrophe it exists to prevent.
 *   3. It probed one owner at a time, sleeping a whole window for each,
 *      so a volume whose Zone Groups were owned by several crashed
 *      nodes cost one window per ZG -- minutes of apparently-hung mount,
 *      a failure mode this project has already been bitten by once.
 *
 * So: one snapshot of every row, one sleep, one re-read. The window is
 * floored at four of the slowest candidate's own advertised beats
 * (hb_interval_secs; a row advertising 0 predates the field and
 * contributes nothing, falling back to our stale_secs).
 *
 * BLOCKING, unlike every other staleness check here: it runs during
 * fill_super, before this mount has observed a single peer heartbeat,
 * so the ordinary progress-based test has no history and would have to
 * answer "alive" -- refusing the mount forever after a peer crashed.
 * Every other caller can simply try again on a later heartbeat tick; a
 * mount cannot.
 */
/* Parse this node's stable machine UUID into raw 16-byte form -- the same
 * value cetrafs_node_register() claims a row with. Hoisted so fs.c's no-CAW
 * mount gate can identify a live FOREIGN peer (any UUID but ours) and refuse
 * BEFORE this node writes anything -- a device with no atomic CAW must not
 * register (a cross-node write) only to then discover it may not mount. */
int cetrafs_node_my_uuid(u8 out[CETRAFS_NODE_UUID_LEN])
{
    const char *uuid_str = get_stable_machine_uuid();
    uuid_t my_uuid;
    int ret;

    if (!uuid_str)
        return -EIO;
    ret = uuid_parse(uuid_str, &my_uuid);
    if (ret)
        return ret;
    memcpy(out, my_uuid.b, CETRAFS_NODE_UUID_LEN);
    return 0;
}

/* Excludes this node's own row(s) by UUID, not by row index: the no-CAW
 * mount gate calls this BEFORE registration, when this node has no row index
 * yet, so "self" can only be told by UUID. (The post-registration caller
 * passes its own UUID too, which excludes the row it just claimed just the
 * same.) */
/*
 * Is an offline repairer holding this volume?
 *
 * `fsck -r` and growfs refuse to touch a volume a node has mounted, but
 * nothing stopped a node mounting halfway through a repair: the
 * repairer claimed nothing a mount could see, and a repair pass is
 * minutes of blind full-block writes to the inode table, the bitmaps
 * and the dirent blocks. The tools now hold a registry row in
 * CETRAFS_NODE_STATE_REPAIR for the duration, which this reports and
 * fill_super() refuses to mount past.
 *
 * A LEASE, not a flag: the repairer renews hb_seq on a timer, so a
 * repairer that was killed stops blocking the volume as soon as a probe
 * sees its row stand still. A row whose checksum does not
 * verify is ignored -- garbage must not be able to make a volume
 * unmountable.
 *
 * Fails CLOSED on an I/O error: not being able to read the registry is
 * not the same as there being no repairer in it.
 */
int cetrafs_node_repair_claim_exists(struct super_block *sb, bool *out_exists, char *out_label, size_t label_sz)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    cetrafs_node_entry_t ne;
    u64 *seq_before;
    u32 count, idx, claims = 0;
    int ret = 0;

    *out_exists = false;
    if (!raw_sb)
        return -EIO;
    count = cetrafs_le32(raw_sb->node_table_count);
    if (!count || count > CETRAFS_MAX_READER_NODES)
        return 0;
    seq_before = kcalloc(count, sizeof(*seq_before), GFP_KERNEL);
    if (!seq_before)
        return -ENOMEM;

    /*
     * Live is decided by WATCHING hb_seq, which a repairer renews on a
     * timer (CETRAFS_REPAIR_RENEW_SECS), never by comparing last_seen
     * with this node's clock. That comparison let a node whose clock ran
     * ahead of the repairer's by more than the staleness window mount in
     * the middle of a repair, and kept a dead repairer's claim blocking
     * every mount for as long as its last_seen lay in our future. The
     * wait is paid only when a claim exists at all.
     */
    for (idx = 0; idx < count; idx++) {
        int r = cetrafs_node_get_entry(sb, idx, &ne);

        if (r == -EIO) {
            ret = r;
            goto out; /* cannot verify: see the contract above */
        }
        if (r || cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REPAIR)
            continue;                                  /* a bad row is not a claim */
        seq_before[idx] = cetrafs_le64(ne.hb_seq) + 1; /* 0 means "not a claim" */
        claims++;
    }
    if (!claims)
        goto out;

    pr_info("a repair claim is registered on this volume -- watching it %us to see whether its repairer is alive\n",
            (unsigned int) CETRAFS_REPAIR_PROBE_SECS);
    if (msleep_interruptible(CETRAFS_REPAIR_PROBE_SECS * 1000)) {
        ret = -EINTR;
        goto out;
    }
    for (idx = 0; idx < count; idx++) {
        if (!seq_before[idx])
            continue;
        int r = cetrafs_node_get_entry(sb, idx, &ne);

        if (r == -EIO) {
            ret = r;
            goto out;
        }
        if (r || cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REPAIR || cetrafs_le64(ne.hb_seq) + 1 == seq_before[idx])
            continue; /* released, or not renewed: its repairer is gone */
        if (out_label && label_sz) {
            strscpy(out_label, ne.label, min(label_sz, sizeof(ne.label)));
            out_label[label_sz - 1] = 0;
        }
        *out_exists = true;
        break;
    }
out:
    kfree(seq_before);
    return ret;
}

int cetrafs_node_live_peer_exists(struct super_block *sb, const u8 *my_uuid, bool *out_exists)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    cetrafs_node_entry_t ne;
    u64 *hb_before;
    u32 count, idx, candidates = 0, window = cetrafs_sb_stale_secs(sb);
    int ret = 0;

    *out_exists = false;
    if (!raw_sb)
        return -EINVAL;

    if (cetrafs_nocaw_force_live_peer) { /* test knob, see its MODULE_PARM_DESC */
        *out_exists = true;
        return 0;
    }

    count = le32_to_cpu(raw_sb->node_table_count);
    hb_before = kcalloc(count, sizeof(*hb_before), GFP_KERNEL);
    if (!hb_before)
        return -ENOMEM;

    /* Snapshot. A row that is FREE, or REGISTERED with last_seen == 0
     * (the clean-departure sentinel), is nobody -- no sleep needed for
     * it and no chance of it waking up during one. */
    for (idx = 0; idx < count; idx++) {
        ret = cetrafs_read_node_entry(sb, idx, &ne);
        if (ret)
            goto out;
        if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED || cetrafs_le64(ne.last_seen) == 0)
            continue;
        /* Our OWN row (a prior incarnation of this node) is not a peer.
         * A clean-departed own row is already skipped (last_seen == 0);
         * this excludes an own row still REGISTERED after our own crash,
         * within the stale window -- which a remount must not refuse
         * itself over. */
        if (my_uuid && !memcmp(ne.node_uuid, my_uuid, CETRAFS_NODE_UUID_LEN))
            continue;
        hb_before[idx] = cetrafs_le64(ne.hb_seq) ? cetrafs_le64(ne.hb_seq) : 1; /* 0 means "not a candidate" */
        candidates++;
        /* Clamp the peer's advertised interval before flooring the wait on
         * it -- a hostile/corrupt (checksum-valid) row with a huge
         * hb_interval_secs would otherwise ssleep() for days (and *4 can
         * overflow). Bounded by the operator-enforced max. */
        u32 pi = min_t(u32, cetrafs_le32(ne.hb_interval_secs), CETRAFS_HB_INTERVAL_MAX_SECS);

        if (pi && pi * 4 > window)
            window = pi * 4;
    }

    if (!candidates)
        goto out;

    pr_info(
        "waiting %us to see whether %u other node(s) are still heartbeating "
        "(this device has no atomic CAW, so only one node may mount it)\n",
        window, candidates);
    ssleep(window);

    for (idx = 0; idx < count; idx++) {
        if (!hb_before[idx])
            continue;
        ret = cetrafs_read_node_entry(sb, idx, &ne);
        if (ret)
            goto out;
        if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED || cetrafs_le64(ne.last_seen) == 0)
            continue; /* left, or was freed, while we watched */
        if (cetrafs_le64(ne.hb_seq) != hb_before[idx]) {
            pr_err("node %u is alive and mounted on this volume\n", idx);
            *out_exists = true;
            break;
        }
        /* Concluded dead, after actually watching it for a window --
         * which is a reclaim-grade verdict on a volume only one node may
         * mount, so it fences the peer exactly as every other reclaim
         * path does, and records the verdict so the next mount does not
         * have to watch all over again. Without this a single crashed
         * peer costs every later mount of the volume a full window,
         * forever: nothing else ever clears that row.
         *
         * A failure is only reported: this takes nothing from the peer
         * by itself, and every path that later does (its Zone Groups,
         * locks, journal) revokes the lease again and stops if it
         * cannot. */
        (void) cetrafs_node_fence_peer_full(sb, idx, "this volume (no atomic CAW: one mounter only)", true);
    }

out:
    kfree(hb_before);
    return ret;
}

/*
 * Call 'visit' for every LIVE foreign Node Registry row: REGISTERED, not
 * cleanly departed (last_seen != 0), not ours (by UUID -- a caller may have
 * no row index yet, and excluding by UUID also skips the row it just
 * claimed), and not stale. "Live" is the ordinary lazy staleness check
 * (cetrafs_node_is_stale), never fencing and never sleeping -- NOT the
 * mount gate's blocking watch-a-window verdict, which stays its own code
 * (cetrafs_node_live_peer_exists()) because it must sleep and fence.
 *
 * 'visit' returns 0 to keep scanning, >0 to stop (not an error), <0 to
 * abort with that error -- the same contract as dir.c's dirent walker.
 */
static int cetrafs_for_each_live_peer(struct super_block *sb,
                                      const u8 *my_uuid,
                                      int (*visit)(u32 idx, const cetrafs_node_entry_t *ne, void *priv),
                                      void *priv)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    cetrafs_node_entry_t ne;
    u32 count, idx;

    if (!raw_sb)
        return -EINVAL;

    count = le32_to_cpu(raw_sb->node_table_count);
    for (idx = 0; idx < count; idx++) {
        bool stale = false;
        int ret = cetrafs_read_node_entry(sb, idx, &ne);

        if (ret)
            return ret;
        if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED || cetrafs_le64(ne.last_seen) == 0)
            continue; /* FREE, or cleanly departed */
        if (my_uuid && !memcmp(ne.node_uuid, my_uuid, CETRAFS_NODE_UUID_LEN))
            continue; /* our own row / a prior incarnation of us */
        if (cetrafs_node_is_stale(sb, idx, &stale) == 0 && stale)
            continue; /* dead but not yet reclaimed -- imposes nothing */
        ret = visit(idx, &ne, priv);
        if (ret)
            return ret < 0 ? ret : 0;
    }
    return 0;
}

/*
 * The cluster's file-lock mode, as advertised by a LIVE peer -- i.e. the
 * mode the first mounter (the lead) established. Returns the first live
 * foreign peer's file_lock_mode, or CETRAFS_FLOCK_MODE_UNSET if this node
 * is the only one here (so it leads with its own option). A stale (dead or
 * cleanly-departed) peer imposes nothing -- its mode is skipped -- so an
 * empty or all-dead cluster correctly lets the next mounter lead.
 */
static int cetrafs_cluster_mode_visit(u32 idx, const cetrafs_node_entry_t *ne, void *priv)
{
    u32 *out_mode = priv;
    u32 mode = cetrafs_le32(ne->file_lock_mode);

    (void) idx;
    if (mode != CETRAFS_FLOCK_MODE_ON && mode != CETRAFS_FLOCK_MODE_OFF)
        return 0;     /* row predates this field / no opinion */
    *out_mode = mode; /* a live peer: this is the cluster's mode */
    return 1;
}

int cetrafs_node_cluster_file_lock_mode(struct super_block *sb, const u8 *my_uuid, u32 *out_mode)
{
    *out_mode = CETRAFS_FLOCK_MODE_UNSET;

    /* Test knob: on a no-CAW loop device the mount gate refuses a live
     * foreign peer outright, so the "inherit a live peer's mode" branches
     * are only reachable on real CAW hardware (ctest). This forces an
     * observed cluster mode so the inherit/refuse decision in fs.c can be
     * exercised single-node. Same approach as nocaw_force_live_peer. */
    if (cetrafs_force_cluster_flock_mode >= 0) {
        *out_mode = (u32) cetrafs_force_cluster_flock_mode;
        return 0;
    }

    return cetrafs_for_each_live_peer(sb, my_uuid, cetrafs_cluster_mode_visit, out_mode);
}

/*
 * Does any LIVE peer run a DIFFERENT file-lock mode than my_mode?
 *
 * The pre-registration inherit/refuse decision reads committed rows BEFORE
 * this node registers, so two nodes mounting at the same instant can each
 * finish their scan before the other's row exists, both conclude "no peer,
 * I lead", and come up with divergent modes -- exactly the mixed cluster
 * the inherit is meant to prevent. This is the post-REGISTRATION re-check
 * that closes that window: by now our own row is committed, so a peer that
 * raced us is visible, and if it disagrees we lost the race and refuse the
 * mount rather than run divergent. Scans ALL live peers (not just the
 * first), since a 3+-node simultaneous start could have one agree and
 * another disagree. Excludes our own row(s) by UUID.
 */
struct cetrafs_mode_conflict_ctx {
    u32 my_mode;
    bool conflict;
};

static int cetrafs_mode_conflict_visit(u32 idx, const cetrafs_node_entry_t *ne, void *priv)
{
    struct cetrafs_mode_conflict_ctx *ctx = priv;
    u32 mode = cetrafs_le32(ne->file_lock_mode);

    (void) idx;
    if (mode != CETRAFS_FLOCK_MODE_ON && mode != CETRAFS_FLOCK_MODE_OFF)
        return 0; /* no opinion */
    if (mode == ctx->my_mode)
        return 0;         /* agrees -- the ordinary case */
    ctx->conflict = true; /* a live peer disagrees: we lost a simultaneous-mount race */
    return 1;
}

int cetrafs_node_file_lock_mode_conflict(struct super_block *sb, const u8 *my_uuid, u32 my_mode, bool *out_conflict)
{
    struct cetrafs_mode_conflict_ctx ctx = {.my_mode = my_mode, .conflict = false};
    int ret;

    *out_conflict = false;

    if (cetrafs_force_mode_conflict) { /* test knob, see its MODULE_PARM_DESC */
        *out_conflict = true;
        return 0;
    }

    ret = cetrafs_for_each_live_peer(sb, my_uuid, cetrafs_mode_conflict_visit, &ctx);
    *out_conflict = ctx.conflict;
    return ret;
}

/*
 * Is ANY live foreign node registered at all? The no-CAW single-mounter
 * re-check: fs.c's mount gate answers this BEFORE registration (it must --
 * a refused node may not write to the volume), but on a device with no
 * atomic CAW nothing arbitrates two nodes registering at the same instant,
 * so both can pass the gate before either's row exists and both come up
 * writing to a volume with no cross-node mutual exclusion whatsoever. This
 * is the post-REGISTRATION re-check that closes that window, the same shape
 * as cetrafs_node_file_lock_mode_conflict() above: our own row is committed
 * by now, so a racer is visible, and seeing ANY live foreign row means the
 * single-mounter invariant is not provably ours -- refuse and unwind.
 *
 * Both racers may each see the other and both refuse; that is safe (a
 * retried mount finds the registry quiet and wins), whereas any tie-break
 * clever enough to elect a winner in-line can be shown to let BOTH proceed
 * when one node's re-check ran before the other's row landed. Sequential
 * mounts never trip this: the gate already refused a live peer.
 */
static int cetrafs_single_mounter_visit(u32 idx, const cetrafs_node_entry_t *ne, void *priv)
{
    bool *out_conflict = priv;

    (void) ne;
    pr_err("node %u registered on this no-CAW volume while this mount was in flight\n", idx);
    *out_conflict = true;
    return 1;
}

int cetrafs_node_single_mounter_conflict(struct super_block *sb, const u8 *my_uuid, bool *out_conflict)
{
    *out_conflict = false;

    if (cetrafs_nocaw_force_postreg_peer) { /* test knob, see its MODULE_PARM_DESC */
        *out_conflict = true;
        return 0;
    }

    return cetrafs_for_each_live_peer(sb, my_uuid, cetrafs_single_mounter_visit, out_conflict);
}

/*
 * Is a LIVE peer running WITHOUT atomic CAW? Asked by a node that HAS it,
 * before registering and again after (the same two-step as the file-lock
 * mode: a peer mounting at the same instant is visible only to the second
 * look).
 *
 * The no-CAW side refuses any live peer at mount, but only at ITS mount:
 * a no-CAW node that mounted first -- alone, legitimately, or because a
 * transient failure of the Block Limits VPD probe made a CAW-capable LUN
 * look like one without -- was never seen by a CAW node joining later.
 * The joiner swapped with real COMPARE AND WRITE while the first node did
 * read-modify-write under a mutex only it could see, and every lock,
 * claim and bitmap bit could be won by both. The first node advertises
 * CETRAFS_NODE_CAP_NO_CAW in its row; this refuses on it.
 */
static int cetrafs_nocaw_peer_visit(u32 idx, const cetrafs_node_entry_t *ne, void *priv)
{
    bool *out = priv;

    if (!(cetrafs_le32(ne->caps) & CETRAFS_NODE_CAP_NO_CAW))
        return 0;
    pr_err("node %u is mounted on this volume WITHOUT atomic CAW (single-mounter fallback)\n", idx);
    *out = true;
    return 1;
}

int cetrafs_node_nocaw_peer_exists(struct super_block *sb, const u8 *my_uuid, bool *out_exists)
{
    *out_exists = false;
    return cetrafs_for_each_live_peer(sb, my_uuid, cetrafs_nocaw_peer_visit, out_exists);
}

/*
 * Does EVERY registered node advertise capability bit 'cap'?
 *
 * The gate a live grow stands on (cetrafs_node_entry_t.caps): the layout
 * is about to move under every mounted node's cached, lockless table
 * offsets, and only a node that understands CETRAFS_NODE_CAP_LIVE_GROW
 * re-reads them when layout_gen bumps. A node that does not -- an old
 * build, or any row written before caps existed (caps == 0) -- would
 * keep compare-and-swapping Block Group descriptors at superseded LBAs.
 *
 * Checks EVERY REGISTERED row, not just the non-stale ones: a stale row
 * is a node that is merely paused (slow, swapped out, mid-reboot), and
 * if it is an OLD build it will resume on the old layout with no idea
 * the tables moved. Stale-reclaim does not free a row: no kernel path
 * takes a REGISTERED row to FREE, so a truly dead node's row stays
 * REGISTERED and keeps counting here until an operator clears it
 * offline. A row that lacks the capability therefore blocks the grow
 * for as long as it stays REGISTERED, dead or alive (a live old node
 * blocks it for as long as it is mounted). Our own row is included and
 * trivially passes
 * (we stamped it). Returns false on any read error -- unknown is unsafe.
 *
 * One record read per row, bounded by the table's mkfs capacity; called
 * only from the grow path, never on a hot path.
 */
bool cetrafs_cluster_all_advertise(struct super_block *sb, u32 cap)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 count, idx;

    if (!raw_sb)
        return false;
    count = le32_to_cpu(raw_sb->node_table_count);

    for (idx = 0; idx < count; idx++) {
        cetrafs_node_entry_t ne;

        if (cetrafs_read_node_entry(sb, idx, &ne) != 0)
            return false; /* cannot read a row -> cannot vouch for the cluster */
        if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED)
            continue; /* FREE or departed: not a live participant */
        if ((cetrafs_le32(ne.caps) & cap) != cap) {
            pr_warn("cluster capability gate: node row %u advertises caps 0x%x, missing 0x%x\n", idx,
                    cetrafs_le32(ne.caps), cap);
            return false;
        }
    }
    return true;
}

/*
 * Sample every peer's hb_seq once, at mount.
 *
 * Without this the staleness clock for a given peer only starts the
 * first time something happens to ask about it -- so the first open of a
 * file locked by a long-dead node is always refused, and only a second
 * attempt a full window later succeeds. Seeding here starts every
 * peer's clock at mount instead, which is also what an operator expects:
 * "it has been dead since before I mounted" should become actionable a
 * window after mounting, not a window after someone happens to trip
 * over it.
 *
 * Cheap and done once: one record read per registry row, bounded by the
 * table's mkfs-time capacity.
 */
void cetrafs_node_seed_peer_watch(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u32 count, idx, me;

    if (!raw_sb || cetrafs_sb_get_node_id(sb, &me) != 0)
        return;
    count = le32_to_cpu(raw_sb->node_table_count);

    for (idx = 0; idx < count; idx++) {
        cetrafs_node_entry_t ne;

        if (idx == me || cetrafs_read_node_entry(sb, idx, &ne) != 0)
            continue;
        if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED || cetrafs_le64(ne.last_seen) == 0)
            continue;
        /* Discard the verdict: the point is only to record "this is what
         * its counter read at mount time, and this is when we looked". */
        (void) cetrafs_sb_peer_progress_stale(sb, idx, cetrafs_le64(ne.hb_seq), cetrafs_le32(ne.hb_interval_secs));
    }
}

/*
 * Report how far this node's wall clock is from its peers'.
 *
 * Liveness no longer depends on clock agreement (see
 * cetrafs_node_is_stale), but skew is still worth saying out loud: file
 * timestamps come from whichever node wrote them, so a badly skewed
 * cluster produces files dated in the future, mtime comparisons that
 * disagree between nodes, and `make`-style tools behaving differently
 * depending on which host they run on.
 *
 * Informational only -- it never fails a mount. A node is not entitled
 * to refuse service because a PEER's clock is wrong, and the filesystem
 * is now correct either way.
 */
void cetrafs_node_report_clock_skew(struct super_block *sb)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    time64_t now = ktime_get_real_seconds();
    s64 worst = 0;
    u32 worst_row = 0;
    u32 count, idx, me;

    if (!raw_sb || cetrafs_sb_get_node_id(sb, &me) != 0)
        return;
    count = le32_to_cpu(raw_sb->node_table_count);

    for (idx = 0; idx < count; idx++) {
        cetrafs_node_entry_t ne;
        s64 delta;

        if (idx == me || cetrafs_read_node_entry(sb, idx, &ne) != 0)
            continue;
        if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED || cetrafs_le64(ne.last_seen) == 0)
            continue; /* free, or cleanly departed: its stamp is not a clock reading */

        delta = (s64) now - (s64) cetrafs_le64(ne.last_seen);
        if (abs(delta) > abs(worst)) {
            worst = delta;
            worst_row = idx;
        }
    }

    /* A peer's last_seen is at most one heartbeat interval old even with
     * perfect clocks, so only complain well past that. */
    if (abs(worst) > 4 * CETRAFS_HEARTBEAT_INTERVAL_SECS)
        pr_warn_ratelimited(
            "clock skew: our clock is %llds %s node %u's -- file timestamps will disagree across "
            "nodes; run NTP on every host (liveness is unaffected, it no longer uses wall clocks)\n",
            (long long) abs(worst), worst >= 0 ? "AHEAD of" : "BEHIND", worst_row);
}

int cetrafs_node_is_stale(struct super_block *sb, u32 node_id, bool *out_stale)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    cetrafs_node_entry_t ne;
    int ret;

    if (!raw_sb)
        return -EINVAL;

    /* An id outside the Node Registry's current bounds can never have
     * been handed out by cetrafs_node_register() -- not a live claim,
     * so unambiguously reclaimable rather than something to error out
     * over. This also matches how an owner_node_id/lock_owner_node
     * value is already treated everywhere else in this codebase: never
     * bounds-checked against the Node Registry, just compared for
     * equality (CRC32C on the ZG/inode record itself is what actually
     * guards against this field being corrupted, not a range check
     * here). */
    if (node_id >= le32_to_cpu(raw_sb->node_table_count)) {
        *out_stale = true;
        return 0;
    }

    ret = cetrafs_read_node_entry(sb, node_id, &ne);
    if (ret)
        return ret;

    if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED) {
        *out_stale = true; /* not a live claim at all */
        return 0;
    }

    /*
     * A cleanly departed node backdates its own last_seen to 0
     * (cetrafs_node_mark_offline), so a peer can reclaim from it at once
     * instead of waiting out the timeout. That sentinel is a single
     * exact value, not a duration, so it needs no clock at all and stays
     * exactly as reliable as it ever was.
     */
    if (ne.last_seen == 0) {
        *out_stale = true;
        return 0;
    }

    /*
     * Everything else is decided by watching the peer's own hb_seq
     * advance, timed on OUR clock -- never by subtracting a timestamp
     * the peer wrote with ITS clock from the current time on ours.
     *
     * That subtraction is what this line used to do, and it is only a
     * liveness test if every node's clock agrees. Nothing required that,
     * nothing checked it, and two real nodes 1h55m apart turned it into
     * a corruption: the node whose clock was AHEAD saw its live peer as
     * permanently stale, broke that peer's namespace lock on a shared
     * directory, and the resulting unsynchronised dirent writes lost 85
     * of 200 entries in one run. last_seen is still written and still
     * shown in procfs, but nothing decides anything with it any more.
     */
    *out_stale =
        cetrafs_sb_peer_progress_stale(sb, node_id, cetrafs_le64(ne.hb_seq), cetrafs_le32(ne.hb_interval_secs));
    return 0;
}
