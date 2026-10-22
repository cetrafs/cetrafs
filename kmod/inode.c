// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/buffer_head.h>
#include <linux/crc32c.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/minmax.h>
#include <linux/stat.h>
#include <linux/string.h>
#include <linux/uidgid.h>

#include "kmod.h"

/* Record writes performed. One 4 KiB device write each when synchronous,
 * and on the LUN a write is ~38 ms. Counted so a test
 * can assert how many an operation costs, which /sys/block cannot show
 * (it cannot tell a record write from any other) and which a loop
 * device cannot show either (its CAS fallback is itself a write, so
 * folding a write into a CAS nets to zero there). */
static atomic64_t cetrafs_record_writes = ATOMIC64_INIT(0);

u64 cetrafs_record_write_count(void)
{
    return (u64) atomic64_read(&cetrafs_record_writes);
}

static void cetrafs_record_write_counted(void)
{
    atomic64_inc(&cetrafs_record_writes);
}

/*
 * v0x0005: the record is TWO independently-checksummed 512-byte sectors
 * (see cetrafs.h's layout comment for the write-ownership split). Each
 * CRC is CRC32C over its own sector with its own checksum field zeroed,
 * plain-native like the BG descriptor/header checksums, same init/final
 * XOR convention as mkfs/fsck.
 */
/*
 * 'live' holds live_len bytes of a 512-byte sector; the rest of the
 * sector is the zero tail the record does not carry (see the trailing
 * -pad note in cetrafs.h). Streamed rather than copied, so no sector
 * -sized temporary lands on the stack -- the whole point of dropping
 * the pad was to get these frames back under the kernel's limit.
 *
 * The value is identical to a CRC over the assembled 512-byte image,
 * which is what makes the format byte-compatible across this change.
 */
static u32 cetrafs_sector_crc(const u8 *live, unsigned int live_len, unsigned int csum_off)
{
    static const u8 zeros[CETRAFS_INODE_FD_BYTES]; /* .bss, never a stack buffer */
    u32 c = ~0U;

    c = crc32c(c, live, csum_off);
    c = crc32c(c, zeros, 8); /* the checksum field itself, as zeros */
    c = crc32c(c, live + csum_off + 8, live_len - csum_off - 8);
    c = crc32c(c, zeros, CETRAFS_INODE_NS_BYTES - live_len); /* the on-disk tail */
    return ~c;
}

u32 cetrafs_inode_crc_ns(const cetrafs_inode_t *in)
{
    /* Sector 0 is carried whole (its pad is structural). */
    return cetrafs_sector_crc((const u8 *) in, CETRAFS_INODE_NS_BYTES, offsetof(cetrafs_inode_t, ns_checksum));
}

u32 cetrafs_inode_crc_fd(const cetrafs_inode_t *in)
{
    return cetrafs_sector_crc((const u8 *) in + CETRAFS_INODE_FD_OFF, CETRAFS_INODE_FD_LIVE,
                              offsetof(cetrafs_inode_t, fd_checksum) - CETRAFS_INODE_FD_OFF);
}

/* Both sectors valid AND agreeing on identity: an echo mismatch is a
 * half-landed whole-record write, transient on a live volume (the retry
 * loop in cetrafs_read_raw_inode() rides it out). */
bool cetrafs_inode_crcs_ok(const cetrafs_inode_t *in)
{
    return cetrafs_inode_crc_ns(in) == (u32) cetrafs_le64(in->ns_checksum) &&
           cetrafs_inode_crc_fd(in) == (u32) cetrafs_le64(in->fd_checksum) && in->fd_ino == in->ino &&
           in->fd_generation == in->generation;
}

/* The block holding inode #ino's record (one record per block since
 * v0x0007), and the record's checksum -- exposed so lock.c can build a
 * CAS image of an inode record without duplicating either rule. */
u64 cetrafs_inode_lba(struct super_block *sb, u64 ino)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);

    if (!raw_sb || !ino || ino > le32_to_cpu(raw_sb->inodes_count))
        return 0;
    return le64_to_cpu(raw_sb->inode_table_start) + (ino - 1);
}

/* Stamp a WHOLE record: identity echoes plus both sector CRCs. Only for
 * writers entitled to the whole record (create/free/journal-less paths
 * where nothing shares it) and for staged images later split across the
 * two-step publish. */
void cetrafs_inode_stamp_crc(struct super_block *sb, cetrafs_inode_t *in)
{
    in->ns_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_ns(in));
    cetrafs_inode_stamp_crc_fd(sb, in);
}

/* Sector-scoped stamps, for the writers that own only one domain: the
 * namespace CAS mutates (sector 0) and the file-path publish (sector 1). */
void cetrafs_inode_stamp_crc_ns(cetrafs_inode_t *in)
{
    in->ns_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_ns(in));
}

/*
 * Every publish of the FILE sector re-stamps file_seq. Doing it HERE
 * rather than at the call sites is the point: the stamp is what lets a
 * peer detect "this file's layout changed since I cached it", so a
 * writer that forgot to bump it would hand that peer a silently stale
 * extent tree. There is exactly one way to publish this sector, and it
 * stamps. (Over-stamping -- a publish that changed nothing -- only
 * costs a peer one extra fresh read, which is the safe direction.)
 */
/* A file_seq carrying WHO stamped it -- see the layout comment on the
 * field. The node id must survive intact, so it is placed, not xor'd:
 * cetrafs_inode_new_generation() xors the id into the high byte, which
 * is fine for a value only ever compared for equality but cannot be
 * decoded back. */
u64 cetrafs_file_seq_new(struct super_block *sb)
{
    u32 node_id = 0;
    u64 val;

    (void) cetrafs_sb_get_node_id(sb, &node_id);
    val = (u64) ktime_get_real_ns() & CETRAFS_FILE_SEQ_VAL_MASK;
    if (!val)
        val = 1;
    return ((u64) (node_id & 0xFFFFu) << CETRAFS_FILE_SEQ_NODE_SHIFT) | val;
}

void cetrafs_inode_stamp_crc_fd(struct super_block *sb, cetrafs_inode_t *in)
{
    in->fd_ino = in->ino;
    in->fd_generation = in->generation;
    in->file_seq = cetrafs_cpu_to_le64(cetrafs_file_seq_new(sb));
    in->fd_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_fd(in));
}

/*
 * Read inode #ino's raw record out of the global inode table. As of
 * v0x0007 every record occupies its own whole block --
 * block-mates were how one node's record write could clobber a record
 * another node owned in the same shared block -- so this is one block
 * read at a fixed offset, no straddle handling.
 */
/* A checksum mismatch is retried a few times with a forced-fresh
 * re-read before being treated as real corruption: readers of an inode
 * record deliberately take no lock (lookup/stat must stay cheap), so a
 * reader can observe a PEER's in-flight 4 KiB record write torn --
 * v0x0007's blind full-block record writes made that window realistic,
 * caught via ctest's xattrs scenario racing one node's first lookup of
 * a file against the other node's xattr-set write of its record. The
 * writer always syncs under its own lock, so a torn observation
 * converges on re-read; only a persistent mismatch is -EUCLEAN. Same
 * shape as dir.c's dirent-tail retry. */
#define CETRAFS_RAW_INODE_READ_RETRIES 5

int cetrafs_read_raw_inode(struct super_block *sb, u64 ino, cetrafs_inode_t *out)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 blk;
    int attempt;

    if (!raw_sb)
        return -EINVAL;

    if (!ino || ino > le32_to_cpu(raw_sb->inodes_count))
        return -EINVAL;

    blk = le64_to_cpu(raw_sb->inode_table_start) + (ino - 1);

    for (attempt = 0; attempt < CETRAFS_RAW_INODE_READ_RETRIES; attempt++) {
        struct buffer_head *bh;

        /* First attempt stays on the normal cached path (the hot paths'
         * whole point); every retry forces a real device re-read, since
         * the mismatched bytes may be a stale/torn cached view. */
        if (attempt > 0)
            cetrafs_invalidate_block(sb, blk);

        bh = cetrafs_bread_retry(sb, blk);
        if (!bh)
            return -EIO;

        /* Copy under the buffer lock. Every record writer modifies this
         * buffer under lock_buffer() (ioutil.c's update protocol), and
         * an unlocked memcpy can copy MID-MODIFICATION: a torn in-memory
         * view that fails the checksum below even though the device and
         * the writer are both perfectly fine. Under load the same
         * record is rewritten constantly, so the retry loop can lose
         * this race every attempt and declare 'corrupted, not just a
         * torn concurrent read' against a healthy filesystem -- records
         * dumped off the LUN seconds later verified VALID.
         * The dirent reader has always blocked on the buffer lock for
         * exactly this reason; the record reader never did. */
        cetrafs_bh_copy_stable(bh, out, sizeof(*out));
        brelse(bh);

        if (cetrafs_inode_crcs_ok(out))
            return 0;

        /* Back off between attempts. A mismatch here is a peer's
         * in-flight record write seen torn, and a peer's write takes
         * milliseconds -- without a pause the whole retry budget is a
         * few microseconds of re-reads and a perfectly transient tear
         * is reported as -EUCLEAN. dir.c's dirent reader has always
         * done this and says why; the record readers did not. */
        usleep_range(100, 400);
    }

#ifdef CETRAFS_TRACE
    {
        /* What are the bad bytes, and what state is the buffer in?
         * Device dumps kept coming back VALID while the kernel saw
         * garbage -- this shows the kernel's view at failure time. */
        struct buffer_head *_b = sb_find_get_block(sb, blk);

        ctrace("EUCLEANDUMP ino=%llu stored=0x%llx calc=0x%x bhstate=%s%s%s bytes=%*ph\n",
               (unsigned long long) ino,
               (unsigned long long) cetrafs_le64(out->ns_checksum),
               cetrafs_inode_crc_ns(out),
               _b && buffer_uptodate(_b) ? "U" : "-",
               _b && buffer_dirty(_b) ? "D" : "-",
               _b && buffer_locked(_b) ? "L" : "-",
               64, (const u8 *) out);
        if (_b)
            brelse(_b);
    }
#endif
    pr_err("ino=%llu failed its record checksum %d times -- corrupted, not just a torn concurrent read\n",
           (unsigned long long) ino, CETRAFS_RAW_INODE_READ_RETRIES);
    return -EUCLEAN;
}

/*
 * Drop any cached copy of inode #ino's backing block(s) -- called by
 * lock.c right before the one read that decides whether to grant or
 * reject a cross-node open, and by dir.c's foreign-lock check before an
 * unlink/rename that's about to free a target's data. Everywhere else
 * (cetrafs_get_block(), cetrafs_setattr(), dir.c's ordinary dirent scans,
 * ...) keeps reading this table through the normal buffer cache: once a
 * node holds a file's exclusive lock, nothing else can be writing to its
 * inode record, so there is no one else's write to go stale against.
 * The lock-claim decision itself is the one moment that genuinely needs
 * a fresh look, matching zonegroup.c's cetrafs_bg_invalidate_cache() for
 * the equivalent ZG-ownership-transfer moment. One record per block as
 * of v0x0007, so this touches nobody else's cache (clean-cache-only,
 * same dirty-buffer safety as ioutil.c's other helpers).
 */

void cetrafs_invalidate_raw_inode(struct super_block *sb, u64 ino)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    struct buffer_head *bh;
    sector_t blk;

    if (!raw_sb || !ino || ino > le32_to_cpu(raw_sb->inodes_count))
        return;

    blk = le64_to_cpu(raw_sb->inode_table_start) + (ino - 1);

    /*
     * A DIRTY record buffer makes the invalidate below a silent no-op.
     *
     * cetrafs_invalidate_block() only clears uptodate when the buffer
     * is clean, and cetrafs_bread_uncached() likewise leaves a dirty
     * buffer alone -- both for the same good reason: a dirty buffer
     * holds a write that has not reached the device, and discarding or
     * reading over it would lose that write.
     *
     * The consequence was never drawn: while such a buffer exists there
     * is NO way to obtain a fresh read of that record, and every caller
     * of this function is a read-decide-write that believes it just
     * forced one (CLAUDE.md cross-node rule 1). It is served this
     * node's own stale copy instead, silently, and decides on it. A
     * 3-node storm logged 2815 refused invalidations in two minutes
     *, so this is the normal case under load, not a corner.
     *
     * Writing our pending record out first is what makes the re-read
     * real. It is also the only safe order: the dirt is this node's own
     * intended write, so flushing it publishes what we meant to publish
     * and loses nothing, whereas dropping it would discard a real
     * update and leaving it would keep serving a stale one. Records are
     * one-per-block, so this syncs exactly this inode and nothing else.
     */
    bh = sb_find_get_block(sb, blk);
    if (bh) {
        if (buffer_dirty(bh)) {
            /* DEBUG: a dirty record buffer here means the sync below
             * PUBLISHES this node's cached record image -- over
             * whatever a peer's CAS put on the device since. Who
             * dirtied it, and is it a directory? */
            const cetrafs_inode_t *_r = (const cetrafs_inode_t *) bh->b_data;

            (void) _r;
            ctrace("DIRTYREC ino=%llu mode=0%o size=%llu -- syncing a DIRTY record at invalidate\n",
                    (unsigned long long) ino, (unsigned int) cetrafs_le32(_r->mode),
                    (unsigned long long) cetrafs_le64(_r->size));
            sync_dirty_buffer(bh);
        }
        brelse(bh);
    }

    cetrafs_invalidate_block(sb, blk);
}

/*
 * Write inode #ino's raw record into its own whole block (v0x0007,
 * one record per block). This is a BLIND full-block
 * write, no read-modify-write at all: this record is the only thing
 * living in its block, and every legitimate writer of a given record is
 * already serialized by that record's own protocol (the file's
 * exclusive lock for data growth/truncate, the namespace cluster mutex
 * for create/unlink/rename/xattr, the PR mutex + verify-readback for
 * lock claims), so there is nothing in the block to preserve and nobody
 * concurrent to merge with. That eliminates both halves of the packed-
 * block corruption: the unbounded-staleness and concurrent-RMW issues
 * are structurally inexpressible now -- and the uncached-read-before-
 * every-write round trip that was required as a workaround on file.c's
 * per-new-block hot path is gone with them (sb_getblk() takes no device
 * read at all).
 *
 * 'sync' controls whether this forces a real device round trip
 * (sync_dirty_buffer()) or just dirties the buffer for ordinary
 * writeback -- file.c's per-new-block growth path passes false (its
 * durability boundary is lock.c's close-time flush); every infrequent
 * one-shot metadata op passes true. (See git history for the real-
 * hardware measurements behind that split.)
 */
/* ---- v0x0005 sector-scoped record mutation --------------------------
 *
 * After mkfs/create, a LIVE record's namespace sector changes only by
 * COMPARE-AND-SWAP (so concurrent claims, presence bits and nlink deltas
 * compose), and its file sector changes only through the fd publish
 * below (so the file hot path can never take the namespace sector
 * backwards). cetrafs_write_raw_inode() -- the whole-record buffered
 * write -- remains ONLY for records nothing shares: a just-allocated
 * number (create/mkdir/symlink and their unwinds) and offline tools.
 */

struct cetrafs_ns_cas_ctx {
    u64 generation;
    void (*apply)(cetrafs_inode_t *rec, void *arg);
    void *arg;
};

static int cetrafs_ns_cas_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_ns_cas_ctx *ctx = priv;
    cetrafs_inode_t rec;

    if (len < CETRAFS_INODE_NS_BYTES)
        return -EINVAL;
    memset(&rec, 0, sizeof(rec));
    memcpy(&rec, image, CETRAFS_INODE_NS_BYTES);

    if (cetrafs_le64(rec.generation) != ctx->generation)
        return -ESTALE; /* the number was reused for a different file */

    ctx->apply(&rec, ctx->arg);

    cetrafs_inode_stamp_crc_ns(&rec);
    memcpy(image, &rec, CETRAFS_INODE_NS_BYTES);
    return 0;
}

/*
 * Apply a namespace-domain update to the LIVE sector-0 image, atomically.
 * 'apply' runs on the bytes the swap will actually land on (and re-runs
 * on every internal retry), so it must be written as a function of the
 * current image -- "nlink = nlink - 1", never "nlink = my precomputed
 * value". 'seed' is the caller's own fresh read (or NULL to read inside).
 */
int cetrafs_inode_ns_cas(struct super_block *sb,
                         u64 ino,
                         u64 generation,
                         const cetrafs_inode_t *seed,
                         void (*apply)(cetrafs_inode_t *rec, void *arg),
                         void *arg)
{
    struct cetrafs_ns_cas_ctx ctx = {.generation = generation, .apply = apply, .arg = arg};
    u64 lba = cetrafs_inode_lba(sb, ino);

    if (!lba)
        return -EINVAL;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    {
        int ret = cetrafs_cas_record_seeded(sb, lba, seed, seed ? CETRAFS_INODE_NS_BYTES : 0, cetrafs_ns_cas_mutate,
                                            &ctx);

        if (ret == 0)
            cetrafs_record_write_counted();
        return ret;
    }
}

static void cetrafs_ns_apply_zero_nlink(cetrafs_inode_t *rec, void *arg)
{
    (void) arg;
    rec->nlink = 0;
}

/* Zero a record's nlink by sector-0 CAS -- the free path's "make the
 * on-disk state honest" write, now unable to clobber anything else. */
int cetrafs_inode_ns_zero_nlink(struct super_block *sb, u64 ino, const cetrafs_inode_t *seed)
{
    return cetrafs_inode_ns_cas(sb, ino, cetrafs_le64(seed->generation), seed, cetrafs_ns_apply_zero_nlink, NULL);
}

struct cetrafs_fd_write_ctx {
    const cetrafs_inode_t *src;
    struct super_block *sb;
    u64 stamped_seq; /* what we wrote, so the caller can keep its own cache valid */
};

static int cetrafs_fd_write_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_fd_write_ctx *ctx = priv;
    cetrafs_inode_t rec;

    if (len < CETRAFS_INODE_FD_BYTES)
        return -EINVAL;
    memset(&rec, 0, sizeof(rec));
    cetrafs_inode_fd_from_image(&rec, image);

    /* The fd sector carries the identity ECHO, which is this sector's
     * own reuse guard: a device echo that no longer matches the record
     * we are publishing means the number was freed and reused since --
     * writing would stamp a dead file's extents over a stranger's. */
    if (rec.fd_generation != ctx->src->generation || rec.fd_ino != ctx->src->ino)
        return -ESTALE;

    cetrafs_inode_fd_copy(&rec, ctx->src);
    rec.ino = ctx->src->ino;               /* for the echo stamp below */
    rec.generation = ctx->src->generation;
    cetrafs_inode_stamp_crc_fd(ctx->sb, &rec);
    ctx->stamped_seq = cetrafs_le64(rec.file_seq);
    cetrafs_inode_fd_to_image(image, &rec);
    return 0;
}

/*
 * Publish a record's FILE-domain sector: size, blocks, atime/mtime,
 * flags and the extent root, from 'src' (whose ns half carries the
 * identity the echo is checked against). Last-writer-wins by design --
 * the file domain has one legitimate writer at a time (the opener, or a
 * presence-gated truncate/defrag) -- but it still goes through the CAS
 * so a reuse of the number can never be written over, and so the
 * namespace sector is physically untouched.
 */
int cetrafs_write_raw_inode_fd(struct super_block *sb, u64 ino, const cetrafs_inode_t *src, struct inode *self)
{
    struct cetrafs_fd_write_ctx ctx = {.src = src, .sb = sb};
    u64 lba = cetrafs_inode_lba(sb, ino);

    if (!lba)
        return -EINVAL;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    /* The fd sector publishes extents: the blocks they name must be
     * durably allocated first (rule 8's choke point, same as the whole
     * -record writer's). */
    cetrafs_alloc_flush_bitmaps(sb);
    {
        int ret = cetrafs_cas_record_fd_seeded(sb, lba, NULL, 0, cetrafs_fd_write_mutate, &ctx);

        if (ret == 0) {
            cetrafs_record_write_counted();
            /* Our own stamp: adopt it, or the freshness gate would read
             * the change we just made as a peer's and throw away a cache
             * that is correct by construction -- once per second, on the
             * growing-file hot path. */
            if (self)
                cetrafs_inode_note_local_file_seq(self, ctx.stamped_seq);
        }
        return ret;
    }
}

int cetrafs_write_raw_inode(struct super_block *sb, u64 ino, const cetrafs_inode_t *in, bool sync)
{
    if (S_ISDIR(cetrafs_le32(in->mode)))
        ctrace("DRECW ino=%llu size=%llu eh=%u depth=%u from=%pS\n",
                (unsigned long long) ino, (unsigned long long) cetrafs_le64(in->size),
                (unsigned int) cetrafs_le16(in->eh.eh_entries),
                (unsigned int) cetrafs_le16(in->eh.eh_depth), __builtin_return_address(0));

    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    cetrafs_inode_t stamped = *in;
    struct buffer_head *bh;

    /*
     * A SYNCHRONOUS record write publishes this inode's extents to every
     * other node, durably. The blocks those extents name must be durably
     * ALLOCATED first, or a node dying here leaves them referenced by
     * this record while the bitmap still reads FREE -- the allocator
     * hands them out again and two files share them.
     *
     * The choke point is here rather than at each caller because every
     * publisher passes through it: dir.c alone has eleven sync=true
     * writes (create, mkdir, link, rename, ...), each able to publish a
     * dirent block allocated moments earlier. A rule every caller must
     * remember is one some caller will forget -- and the directory's own
     * block was among the six this bug corrupted.
     *
     * Free when nothing was allocated since the last boundary: the dirty
     * set is empty and the scan finds no marked BG.
     */
    if (sync)
        cetrafs_alloc_flush_bitmaps(sb);

    if (!raw_sb)
        return -EINVAL;

    if (!ino || ino > le32_to_cpu(raw_sb->inodes_count))
        return -EINVAL;

    if (cetrafs_sb_is_fenced(sb))
        return -EIO; /* self-fenced: no record writes */

    cetrafs_inode_stamp_crc(sb, &stamped);

    /*
     * Serialise against cetrafs_cas_region()'s no-CAW fallback, which
     * read-modify-writes this very record (the read-presence bitmask and
     * the namespace lock both live in it) with no compare to protect it.
     * Without this, a CAS can read the record, a blind write like this
     * one can land, and the CAS then writes its pre-write image back --
     * silently reverting the record write. Measured on a loop device: 5
     * lost chmods across three runs of 1200 files with the CAS window
     * widened, 0 after.
     *
     * Only on a device WITHOUT atomic CAW. With one, the CAS compares
     * against the device, so a write that lands in between makes it
     * MISCOMPARE and retry against the new image -- which is the whole
     * point of having it, and serialising there would throw it away.
     */
    bool serialise = !cetrafs_sb_caw_available(sb);

    if (serialise)
        cetrafs_sb_cas_lock(sb);

    bh = sb_getblk(sb, le64_to_cpu(raw_sb->inode_table_start) + (ino - 1));
    if (!bh) {
        if (serialise)
            cetrafs_sb_cas_unlock(sb);
        return -EIO;
    }

    /* The helpers, not a hand-rolled equivalent: cetrafs_bh_end_update()
     * marks the buffer dirty BEFORE unlocking it, and that order is the
     * whole point. Dirtying after the unlock leaves a window in which
     * the buffer is uptodate, clean, and holding an image that exists
     * only in memory -- and a concurrent forced-fresh reader takes the
     * lock in exactly that state, clears uptodate and re-reads the OLD
     * bytes from the device straight over it. The record write is then
     * marked dirty on reverted content and synced, silently losing it.
     * (This is hazard 1 in ioutil.c's own comment -- the one measured as
     * 12 of 292 directory entries lost -- reintroduced by not using the
     * helper that exists to prevent it.) */
    cetrafs_bh_begin_update(bh);
    memcpy(bh->b_data, &stamped, sizeof(stamped));
    memset(bh->b_data + sizeof(stamped), 0, CETRAFS_BLOCK_SIZE - sizeof(stamped));
    cetrafs_bh_end_update(bh);
    if (sync) {
        cetrafs_record_write_counted();
        sync_dirty_buffer(bh);
    }
    brelse(bh);

    if (serialise)
        cetrafs_sb_cas_unlock(sb);
    return 0;
}

/*
 * Read inode #ino from the global inode table and populate a VFS inode
 * from it.
 */
/*
 * A fresh generation for a newly-ALLOCATED inode (v0x0008; see
 * cetrafs.h's field comment for the cross-node reuse type-confusion this
 * detects). Only needs to differ between successive lives of the same
 * inode number: wall-clock nanoseconds XOR'd with the allocating node's
 * id comfortably provides that (allocation is cluster-mutexed and
 * multi-nanosecond, so two lives can't share a timestamp; the node id
 * guards the pathological clock-skew case). Never returns 0 -- that's
 * the reserved "unset" value.
 */
u64 cetrafs_inode_new_generation(struct super_block *sb)
{
    u32 node_id = 0;
    u64 gen;

    (void) cetrafs_sb_get_node_id(sb, &node_id);
    gen = ktime_get_real_ns() ^ ((u64) node_id << 56);
    return gen ? gen : 1;
}

struct inode *cetrafs_iget(struct super_block *sb, u64 ino)
{
    cetrafs_inode_t raw;
    struct inode *inode;
    int ret;

    fs_debug(info, "cetrafs_iget(ino=%llu)", (unsigned long long) ino);

retry:
    inode = iget_locked(sb, ino);
    if (!inode)
        return ERR_PTR(-ENOMEM);

    if (!(inode_state_read_once(inode) & I_NEW)) {
        /*
         * Cache hit: this node already has a resident VFS inode object
         * for 'ino', seeded by an earlier, unrelated lookup (e.g. this
         * same file's original name, before a peer hardlinked a second
         * name onto it). iget_locked() returning an already-initialized
         * object skips the "first fill" path below entirely -- nothing
         * else was refreshing it for a dentry that's never been looked
         * up (and so never been through dir.c's cetrafs_d_revalidate())
         * before. Found via a real two-node repro: a reader's *first*
         * lookup of a freshly-created hardlink's name returned the
         * stale pre-link nlink, while the *original* name (already
         * cached, going through d_revalidate on every lookup) correctly
         * showed the new value -- same inode, same underlying bug class
         * as d_revalidate's own staleness fix, just reached by a
         * different path (a brand new dentry has nothing to revalidate
         * yet). Safe by the same rule as everywhere else: skip while
         * this node itself holds the write lock.
         */
        ret = cetrafs_refresh_vfs_inode_if_newer(inode);
        if (ret == -ESTALE) {
            /* v0x0008: same inode NUMBER, different FILE -- a peer
             * deleted whatever this cached object was and reused its
             * number for something new (possibly of a different type,
             * whose i_op/i_fop this object would wrongly keep: the
             * caught-in-the-wild case was a symlink object reused for a
             * regular file, making the VFS walk the new file's DATA as
             * a link target). The refresh already unhashed the stale
             * object; drop our ref and instantiate a fresh one. Any
             * still-open local fds keep the old object alive privately,
             * correctly frozen on the dead file they were opened on. */
            iput(inode);
            goto retry;
        }
        return inode;
    }

    /* This is the first time *this node's kernel* has ever instantiated a
     * VFS inode object for 'ino' (or the last one was evicted) -- once
     * filled in below, every field here becomes this node's cached truth
     * until something explicitly refreshes it (lock.c's open-boundary
     * refresh; see its own comment). A peer node may have created or
     * already written this inode arbitrarily recently, so the one read
     * that seeds that cache must not be allowed to come back stale --
     * same reasoning as every other first-look-at-shared-state read in
     * this codebase (node.c/zonegroup.c/dir.c). Caught via a real
     * two-node repro: a file written and closed on one node showed up as
     * 0 bytes on the other because this read landed on an inode-table
     * block that node had cached for an unrelated reason before the
     * write ever happened. */
    cetrafs_invalidate_raw_inode(sb, ino);

    ret = cetrafs_read_raw_inode(sb, ino, &raw);
    if (ret) {
        iget_failed(inode);
        return ERR_PTR(ret);
    }

    /*
     * nlink == 0 means this record describes a DELETED file.
     *
     * cetrafs_unlink_locked() persists nlink = 0 and leaves the record
     * otherwise intact; cetrafs_free_inode() then clears only the
     * bitmap bit, never the record. So a dirent that still names such an
     * inode -- the "dangling entry" fsck reports, and what a stale
     * cached dirent block produces across nodes -- would otherwise
     * instantiate the dead file verbatim: its mode, its size, and its
     * EXTENTS, which point at blocks that are back in the allocator and
     * may already belong to a different file. Measured before this
     * check: a name whose record was set to nlink=0 still stat'd and
     * still returned the dead file's contents.
     *
     * Fill path only. A locally unlinked-but-still-open inode is
     * legitimately nlink == 0 in core, but it is never re-instantiated
     * from disk -- no dirent names it -- so this cannot reach it. Same
     * rule ext4 applies in ext4_iget().
     */
    if (raw.nlink == 0) {
        pr_warn_ratelimited(
            "ino=%llu is named by a directory entry but its record says nlink=0 -- "
            "refusing to hand out a deleted file's blocks\n",
            (unsigned long long) ino);
        iget_failed(inode);
        return ERR_PTR(-ESTALE);
    }

    inode->i_mode = cetrafs_le32(raw.mode);
    i_uid_write(inode, cetrafs_le32(raw.uid));
    i_gid_write(inode, cetrafs_le32(raw.gid));
    set_nlink(inode, cetrafs_le32(raw.nlink));
    inode->i_size = cetrafs_le64(raw.size);
    inode->i_blocks = cetrafs_le64(raw.blocks);
    cetrafs_inode_set_generation(inode, cetrafs_le64(raw.generation));

    inode_set_atime(inode, (time64_t) cetrafs_le64(raw.atime), 0);
    inode_set_mtime(inode, (time64_t) cetrafs_le64(raw.mtime), 0);
    inode_set_ctime(inode, (time64_t) cetrafs_le64(raw.ctime), 0);

    /* The in-core stat block now matches the record exactly: that is
     * ->write_inode's baseline for telling our own changes from a
     * peer's. Both sites that fill stat from a record set it. */
    cetrafs_inode_stat_baseline_set(inode, &raw);

    if (S_ISDIR(inode->i_mode)) {
        inode->i_op = &cetrafs_inode_ops;
        inode->i_fop = &cetrafs_dir_ops;
    } else if (S_ISLNK(inode->i_mode)) {
        /* page_symlink_inode_operations (.get_link = page_get_link) reads
         * the target back out of the page cache via our own .read_folio,
         * the same machinery regular file reads use -- a symlink target
         * is just a tiny regular file's worth of data.
         *
         * inode_nohighmem() is required here: __page_get_link() calls
         * page_address() directly (no kmap()), and BUG_ON()s if the
         * mapping's gfp mask includes __GFP_HIGHMEM -- which it does by
         * default (GFP_HIGHUSER_MOVABLE). Omitting this crashed the
         * kernel (BUG_ON) on the very first readlink() of a fresh
         * symlink, reproduced and fixed this session. Every real
         * filesystem using page_symlink_inode_operations (ext2, minix,
         * ...) calls this for exactly this reason. */
        inode_nohighmem(inode);
        inode->i_op = &cetrafs_symlink_iops;
        inode->i_mapping->a_ops = &cetrafs_aops;
    } else if (S_ISREG(inode->i_mode)) {
        inode->i_op = &cetrafs_inode_ops;
        inode->i_fop = &cetrafs_file_ops;
        inode->i_mapping->a_ops = &cetrafs_aops;
    } else {
        /*
         * A type this build cannot represent.
         *
         * The format defines FIFO, socket and device entries and
         * cetrafs_dirent_type() maps them, but there is no .mknod, so
         * nothing here can create one -- which means a record carrying
         * such a mode is either corruption or another implementation's
         * work. This used to fall into the regular-file branch above and
         * get cetrafs_file_ops and cetrafs_aops, so a device node would
         * be read as a file: its extent tree walked and whatever blocks
         * it names served up as contents, silently.
         *
         * Refusing says so instead. If .mknod is ever implemented, this
         * is where init_special_inode() goes, and this branch is the
         * reminder.
         */
        pr_err("ino=%llu has an unsupported file type (mode 0%o) -- refusing to instantiate it\n",
               (unsigned long long) ino, inode->i_mode);
        iget_failed(inode);
        return ERR_PTR(-EUCLEAN);
    }

    unlock_new_inode(inode);

    return inode;
}

/* CAS context for cetrafs_write_vfs_inode()'s stat publish -- see the
 * commentary at its call site. 'written' carries the image the swap
 * actually landed, for the baseline update. */
struct cetrafs_vfs_stat_cas_ctx {
    struct inode *inode;
    u64 generation;   /* in-core identity; checked against the fd echo */
    __le64 ino_le;    /* in-core ino, for the echo check */
    bool have_shadow; /* publish the hot path's pending extent state too */
    cetrafs_inode_t *shadow;
    struct cetrafs_stat_baseline base;
    cetrafs_inode_t *written;
};

/*
 * The FILE-sector publish (CAS region 1). This is writeback's and
 * close's one record write, and the only path that ever persists a
 * regular file's size/blocks/times/extent-root outside truncate/defrag.
 * It cannot touch the namespace sector at all -- which is the whole
 * v0x0005 point: however stale this node's view, a peer's nlink delta,
 * lock claim or presence bit is physically out of reach.
 */
static int cetrafs_vfs_stat_cas_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_vfs_stat_cas_ctx *ctx = priv;
    struct inode *inode = ctx->inode;
    cetrafs_inode_t rec;

    if (len < CETRAFS_INODE_FD_BYTES)
        return -EINVAL;
    memset(&rec, 0, sizeof(rec));
    cetrafs_inode_fd_from_image(&rec, image);

    /* The fd sector's identity echo is this sector's reuse guard. */
    if (cetrafs_le64(rec.fd_generation) != ctx->generation || rec.fd_ino != ctx->ino_le)
        return -ESTALE;

    /* The hot path's pending extent state supersedes the device's: it is
     * strictly newer (this node is the file's writer). */
    if (ctx->have_shadow) {
        rec.eh = ctx->shadow->eh;
        rec.et = ctx->shadow->et;
    }

    /* Three-way merge of the stat fields against the baseline, run on
     * the image the swap actually lands on (and re-run on every internal
     * retry) -- so a peer's concurrent publish (a nofilelock handoff's
     * double close) is merged, never reverted. Size/blocks take the
     * maximum (shrinking past a peer's extents orphans the tail; the one
     * legitimate shrinker, truncate, publishes through its own path
     * under the namespace lock with foreign users refused); times take
     * the later. */
#define CETRAFS_FD_MERGE64(field, ours_expr, write_ours)                                                               \
    do {                                                                                                               \
        u64 ours = (u64) (ours_expr);                                                                                  \
        u64 theirs = cetrafs_le64(rec.field);                                                                          \
        u64 b = (u64) (ctx->base.field);                                                                               \
        u64 v = theirs;                                                                                                \
                                                                                                                       \
        if (ours != b && theirs != b)                                                                                  \
            v = max(ours, theirs);                                                                                     \
        else if (ours != b)                                                                                            \
            v = ours;                                                                                                  \
        rec.field = cetrafs_cpu_to_le64(v);                                                                            \
        write_ours(v);                                                                                                 \
    } while (0)

#define CETRAFS_FD_SET_SIZE(v)   i_size_write(inode, (loff_t) (v))
#define CETRAFS_FD_SET_BLOCKS(v) (inode->i_blocks = (blkcnt_t) (v))
#define CETRAFS_FD_SET_ATIME(v)  inode_set_atime(inode, (time64_t) (v), 0)
#define CETRAFS_FD_SET_MTIME(v)  inode_set_mtime(inode, (time64_t) (v), 0)

    CETRAFS_FD_MERGE64(size, i_size_read(inode), CETRAFS_FD_SET_SIZE);
    CETRAFS_FD_MERGE64(blocks, inode->i_blocks, CETRAFS_FD_SET_BLOCKS);
    CETRAFS_FD_MERGE64(atime, (u64) inode_get_atime_sec(inode), CETRAFS_FD_SET_ATIME);
    CETRAFS_FD_MERGE64(mtime, (u64) inode_get_mtime_sec(inode), CETRAFS_FD_SET_MTIME);

#undef CETRAFS_FD_SET_SIZE
#undef CETRAFS_FD_SET_BLOCKS
#undef CETRAFS_FD_SET_ATIME
#undef CETRAFS_FD_SET_MTIME
#undef CETRAFS_FD_MERGE64

    /* But a shadow's size/blocks never merge DOWN: they are the newest
     * truth this node has. (max() above already guarantees it for the
     * common grow case; this is the belt for a quiet shadow.) */
    if (ctx->have_shadow) {
        if (cetrafs_le64(ctx->shadow->size) > cetrafs_le64(rec.size))
            rec.size = ctx->shadow->size;
        if (cetrafs_le64(ctx->shadow->blocks) > cetrafs_le64(rec.blocks))
            rec.blocks = ctx->shadow->blocks;
    }

    /* The echoes come from the VERIFIED image identity (the local ns
     * half here is zeroed scratch -- stamping from it wrote fd_ino=0
     * and broke every later read's echo check; caught by the very first
     * smoke test of the split). */
    rec.ino = ctx->ino_le;
    rec.generation = cetrafs_cpu_to_le64(ctx->generation);
    cetrafs_inode_stamp_crc_fd(inode->i_sb, &rec);
    memcpy(ctx->written, &rec, sizeof(rec));
    cetrafs_inode_fd_to_image(image, &rec);
    return 0;
}

/*
 * Publish an in-core inode's FILE-domain state (and any pending hot-path
 * shadow) to its record's file sector -- the write-side counterpart to
 * cetrafs_iget() for everything the file data path owns. Called from
 * super_ops.c's ->write_inode on the VFS's writeback schedule, from the
 * close boundary, and from fsync -- this is what makes a write()'s
 * updated i_size and extents durable across a remount.
 *
 * The namespace sector is deliberately out of reach here: writeback owns
 * none of it. mode/uid/gid are persisted by setattr's own namespace-
 * sector CAS; nlink by the namespace operations; in-core copies of those
 * are ADOPTED from the fresh read below so a stale local view re-syncs.
 */
int cetrafs_write_vfs_inode(struct inode *inode)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_vfs_stat_cas_ctx *ctx;
    cetrafs_inode_t *bufs; /* [0]=raw, [1]=shadow, [2]=written -- heap: 3 KiB of records */
    u32 my_node_id = 0;
    int ret;

    bufs = kmalloc(3 * sizeof(*bufs), GFP_NOFS);
    ctx = kzalloc(sizeof(*ctx), GFP_NOFS);
    if (!bufs || !ctx) {
        kfree(bufs);
        kfree(ctx);
        return -ENOMEM;
    }

    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &bufs[0]);
    if (ret)
        goto out;

    if (cetrafs_le64(bufs[0].generation) != cetrafs_inode_get_generation(inode)) {
        ret = -ESTALE; /* dead object for a reused number -- nothing of ours to write */
        goto out;
    }

    /* A record a LIVE other node holds exclusively locked is that node's
     * file domain to write -- our stat dirt predates its claim. */
    (void) cetrafs_sb_get_node_id(sb, &my_node_id);
    if (cetrafs_le32(bufs[0].lock_mode) == CETRAFS_LOCK_EXCLUSIVE && cetrafs_le32(bufs[0].lock_owner_node) != my_node_id) {
        bool stale = false;

        ret = cetrafs_node_is_stale(sb, cetrafs_le32(bufs[0].lock_owner_node), &stale);
        if (ret)
            goto out;
        if (!stale) {
            ret = 0; /* drop our dirt */
            goto out;
        }
    }

    /* Adopt the namespace-domain truth in core (never write it): nlink
     * is the accumulator only ns ops move; mode/uid/gid may have been
     * chmod/chowned by a peer. */
    set_nlink(inode, cetrafs_le32(bufs[0].nlink));
    {
        struct cetrafs_stat_baseline b;

        if (cetrafs_inode_stat_baseline_get(inode, &b)) {
            if ((u32) inode->i_mode == b.mode)
                inode->i_mode = (umode_t) cetrafs_le32(bufs[0].mode);
            if (i_uid_read(inode) == b.uid)
                i_uid_write(inode, cetrafs_le32(bufs[0].uid));
            if (i_gid_read(inode) == b.gid)
                i_gid_write(inode, cetrafs_le32(bufs[0].gid));
            ctx->base = b;
        } else {
            pr_warn_ratelimited("ino=%llu: no stat baseline at writeback -- dropping dirt rather than guessing\n",
                                (unsigned long long) inode->i_ino);
            ret = 0;
            goto out;
        }
    }

    ctx->inode = inode;
    ctx->generation = cetrafs_inode_get_generation(inode);
    ctx->ino_le = bufs[0].ino;
    ctx->shadow = &bufs[1];
    ctx->written = &bufs[2];
    ctx->have_shadow = cetrafs_inode_fd_take(inode, &bufs[1]);

    /* Nothing to publish? A no-op CAS still costs a device round trip
     * (and showed up as "a punch that frees nothing published 10 record
     * writes" -- the VFS dirties the inode for timestamps the merge then
     * finds unchanged). Skip when there is no shadow and every merged
     * field already matches the baseline this node last published. */
    if (!ctx->have_shadow && (u64) i_size_read(inode) == ctx->base.size && (u64) inode->i_blocks == ctx->base.blocks &&
        (u64) inode_get_atime_sec(inode) == ctx->base.atime && (u64) inode_get_mtime_sec(inode) == ctx->base.mtime) {
        ret = 0;
        goto out;
    }

    ret = cetrafs_cas_record_fd_seeded(sb, cetrafs_inode_lba(sb, inode->i_ino),
                                       (const u8 *) &bufs[0] + CETRAFS_INODE_FD_OFF, CETRAFS_INODE_FD_LIVE,
                                       cetrafs_vfs_stat_cas_mutate, ctx);
    if (ret == 0) {
        cetrafs_record_write_counted();
        cetrafs_inode_stat_baseline_set(inode, ctx->written);
        /* Adopt what we just stamped. The decode in lock.c already stops
         * this node mistaking its own publish for a peer's; this keeps
         * the cached value exact so the common path never even has to
         * ask. */
        cetrafs_inode_note_local_file_seq(inode, cetrafs_le64(ctx->written->file_seq));
    } else if (ctx->have_shadow) {
        /* The publish did not land; the pending extent state must not be
         * lost -- put it back for the next boundary. (-ESTALE means the
         * file is GONE under us: nothing to re-stage onto.) */
        if (ret != -ESTALE)
            cetrafs_inode_fd_stage(inode, &bufs[1]);
    }
    if (ret == -ESTALE)
        ret = 0; /* reused number: our dirt is for a dead file -- dropped by design */

out:
    kfree(ctx);
    kfree(bufs);
    return ret;
}



/*
 * Read an inode's external extent-leaf block.
 *
 * Whether the cached copy can be trusted follows directly from this
 * filesystem's own clustering model: if this node holds the file's
 * exclusive write lock, no peer can be modifying its extent tree at all,
 * so the ordinary cached read is correct -- and that is the hot path
 * (a growing file maps one block at a time, always holding its own write
 * lock). Without that lock a peer may have rewritten the tree under us
 * -- truncate, hole-punch, or a defrag relocation that leaves size and
 * block count identical -- so the leaf must come from the device.
 *
 * A directory never has a write lock, so directory leaf reads always go
 * fresh: one extra round trip per namespace operation, which is in line
 * with the forced-fresh record read each of them already does, and
 * exactly where correctness matters most.
 */
/* Extent-tree block reads (leaf or interior). A lookup used to read
 * every leaf until it hit, so this scaled with the file's fragmentation
 * and was paid per mapped block; ei_block_end makes it O(1). A test
 * watching this ratio is the only thing that can tell the difference --
 * throughput alone looks like SAN noise until the file is huge. */
static atomic64_t cetrafs_tree_reads = ATOMIC64_INIT(0);

u64 cetrafs_tree_read_count(void)
{
    return (u64) atomic64_read(&cetrafs_tree_reads);
}

struct buffer_head *cetrafs_read_tree_bh(struct inode *inode, u64 lba, u32 tail_magic, const char *what)
{
    atomic64_inc(&cetrafs_tree_reads);
    /* Holding the file's exclusive lock means no peer can be rewriting
     * this tree, so the cached copy is authoritative AND cannot be
     * torn -- this is the growing-file hot path and must stay off the
     * wire. */
    if (cetrafs_lock_held_for_write_locally(inode))
        return cetrafs_bread_retry(inode->i_sb, lba);

    /* Without it, a peer may be mid-write. A DIRECTORY is always in
     * this case: it never holds a file lock, so every peer walking a
     * spilled directory reads its leaf unsynchronised. Verify the tail
     * and retry a mismatch, which is a torn write far more often than
     * it is corruption. */
    return cetrafs_blk_tail_bread(inode->i_sb, lba, tail_magic, what);
}

struct buffer_head *cetrafs_read_leaf_bh(struct inode *inode, u64 lba)
{
    return cetrafs_read_tree_bh(inode, lba, CETRAFS_LEAF_TAIL_MAGIC, "extent leaf");
}

/*
 * A DIRECTORY's extent-tree leaf, read with an explicit freshness the
 * caller derives from the dirent_seq gate (cetrafs_dir_needs_fresh()) --
 * NOT from cetrafs_lock_held_for_write_locally() the way
 * cetrafs_read_tree_bh() does.
 *
 * That predicate is wrong for a directory under nofilelock: it reads
 * "we are the sole node with this file OPEN", but a peer mutates a
 * directory through namespace ops (create/mkdir/unlink/rmdir under its
 * namespace lock), never by opening it, so the predicate stays true and
 * the leaf is served from this node's stale cache. A spilled directory
 * then misses a peer's growth block: the nodes diverge on the tree's
 * shape, a locked scan walks the wrong blocks, and two mkdir()s of one
 * name both succeed -- 328/401 duplicate directories in a 3-node run,
 * cascading into INVISIBLE / orphaned / unreachable entries.
 *
 * The dirent_seq gate is the correct signal: it is bumped by every
 * cross-node mutation, so "changed since I last read" forces the leaf
 * fresh, while an unchanged directory (the single-writer steady state)
 * keeps the cached leaf and stays O(1). When fresh, verify the tail and
 * retry a torn concurrent write exactly as cetrafs_read_tree_bh() does.
 */
struct buffer_head *cetrafs_read_dir_leaf_bh(struct inode *inode, u64 lba, bool fresh)
{
    if (!fresh)
        return cetrafs_bread_retry(inode->i_sb, lba);
    return cetrafs_blk_tail_bread(inode->i_sb, lba, CETRAFS_LEAF_TAIL_MAGIC, "extent leaf");
}

/* v2: an interior index block, same freshness rules, its own tail magic
 * so a block of the wrong KIND is caught rather than mis-parsed. */
struct buffer_head *cetrafs_read_index_bh(struct inode *inode, u64 lba)
{
    return cetrafs_read_tree_bh(inode, lba, CETRAFS_INDEX_TAIL_MAGIC, "extent index");
}

/*
 * The opposite direction of cetrafs_write_vfs_inode(): stamp a freshly-read
 * raw record's stat fields onto an already-resident in-core inode, plus
 * drop any now-stale page-cache content. Callers (lock.c's open-boundary
 * refresh, dir.c's d_revalidate for an already-cached positive dentry)
 * are each responsible for deciding *when* this is safe to call -- see
 * cetrafs_refresh_vfs_inode_if_newer() below for the one safe rule both
 * of them actually use.
 */
/* page_get_link for the target text (a symlink's data is a tiny regular
 * file's worth of page cache), PLUS our setattr: lchown/utimensat on a
 * symlink mutate its record's namespace sector, which only our setattr's
 * sector-0 CAS may write (v0x0005). The generic
 * page_symlink_inode_operations has no .setattr, so a symlink chown used
 * to reach the device only through writeback's whole-record merge --
 * which no longer writes the namespace sector, and the owner silently
 * stayed 0:0 (caught by unsupported_ops.sh the first run after the
 * split). */
const struct inode_operations cetrafs_symlink_iops = {
    .get_link = page_get_link,
    .setattr = cetrafs_setattr,
};

int cetrafs_apply_raw_to_vfs_inode(struct inode *inode, const cetrafs_inode_t *raw)
{
    int ret;
    bool dirty;

    /*
     * Not a DIFFERENT FILE. Inode numbers are reused, and stamping a new
     * file's stat fields onto an object instantiated from the old one
     * leaves it wearing the OLD type's i_op/i_fop -- the caught-in-the-
     * wild case was a cached symlink object reused for a regular file,
     * after which the VFS walked the new file's DATA as a link target.
     *
     * This check used to live only in cetrafs_refresh_vfs_inode_if_
     * newer(), and lock.c's open-boundary refresh calls THIS function
     * directly, comparing only mtime -- so a number reused between a
     * lookup's revalidate and the open's refresh went straight past the
     * v0x0008 protection. Same lesson as the dirty guard below: a rule
     * every caller has to re-derive is a rule one of them will get
     * wrong. The caller that needs to react (unhash and report -ESTALE)
     * still does; this just makes sure nobody can skip it.
     */
    if (cetrafs_inode_get_generation(inode) != cetrafs_le64(raw->generation))
        return -ESTALE;

    /*
     * And never a different TYPE. With the generation check above this
     * should be unreachable -- a type change means delete-and-recreate,
     * which changes the generation -- which is exactly why it is worth
     * saying out loud if it ever happens: i_op/i_fop/a_ops are chosen
     * once, in cetrafs_iget(), and a refresh that silently moved i_mode
     * to a different S_IFMT would leave the VFS calling one type's
     * operations on another's.
     */
    /*
     * And never a file the namespace no longer has.
     *
     * nlink == 0 on disk means deleted: cetrafs_unlink_locked() persists
     * it and leaves the record otherwise intact. N1 stopped iget's FILL
     * path from instantiating such a record, but the far likelier route
     * is this one -- the node with a cached dentry and a cached in-core
     * object is exactly the node whose dirent block may still name the
     * file. Without this, a peer's unlink left the name resolving, stat
     * cheerfully reporting nlink=0, and reads still served out of
     * extents the allocator has taken back. Measured.
     *
     * A file unlinked LOCALLY while still open is nlink == 0 in core
     * too, and is unaffected: it cannot be reached by name, so no
     * refresh path runs for it.
     */
    if (raw->nlink == 0)
        return -ESTALE;

    if (((inode->i_mode ^ cetrafs_le32(raw->mode)) & S_IFMT) != 0) {
        pr_err("ino=%llu: refusing a refresh that would change its type (0%o -> 0%o) with the same generation\n",
               (unsigned long long) inode->i_ino, inode->i_mode & S_IFMT, cetrafs_le32(raw->mode) & S_IFMT);
        return -EUCLEAN;
    }

    /*
     * Never stamp disk state over UNWRITTEN LOCAL CHANGES.
     *
     * chmod(2), truncate(2) and utimes(2) set stat fields in the in-core
     * inode and mark it dirty; the record write that persists them can
     * still be in flight. A refresh landing in that window reverts the
     * change in memory, and the next write-back then persists the
     * REVERTED value -- the chmod is lost, and lost durably: it is the
     * wrong value that reaches the disk.
     *
     * The guard lives HERE, in the operation, rather than in each
     * caller. It was a caller's responsibility before ("callers are each
     * responsible for deciding when this is safe"), and the predictable
     * happened: cetrafs_refresh_vfs_inode_if_newer() checked one
     * condition, lock.c's open-boundary refresh checked a different one,
     * and neither checked this. Same lesson as the buffer-update
     * protocol -- a rule that every caller has to re-derive is a rule
     * one of them will get wrong.
     *
     * Dirty means this node holds the newer copy, so there is nothing on
     * disk worth stamping on top of it. i_state is read under i_lock,
     * the way the VFS does.
     */
    spin_lock(&inode->i_lock);
    dirty = (inode_state_read(inode) & I_DIRTY_ALL) != 0;
    spin_unlock(&inode->i_lock);
    if (dirty)
        return 0;

    inode->i_mode = cetrafs_le32(raw->mode);
    i_uid_write(inode, cetrafs_le32(raw->uid));
    i_gid_write(inode, cetrafs_le32(raw->gid));
    set_nlink(inode, cetrafs_le32(raw->nlink));
    i_size_write(inode, cetrafs_le64(raw->size));
    inode->i_blocks = cetrafs_le64(raw->blocks);
    inode_set_atime(inode, (time64_t) cetrafs_le64(raw->atime), 0);
    inode_set_mtime(inode, (time64_t) cetrafs_le64(raw->mtime), 0);
    inode_set_ctime(inode, (time64_t) cetrafs_le64(raw->ctime), 0);
    cetrafs_inode_stat_baseline_set(inode, raw);

    /* Dropping the page cache below forces the
     * next read back through cetrafs_get_block() -- but for a depth-1
     * (spilled) file, get_block walks the EXTERNAL extent-leaf block,
     * and a reader holding a stale cached leaf maps logical blocks
     * through it to physical blocks that may since have been freed and
     * reallocated to a different file.
     *
     * This used to call cetrafs_invalidate_block() on that leaf right
     * here. That was a cross-thread poke at a buffer other threads are
     * concurrently reading, and it broke them: __bread_slow() re-checks
     * buffer_uptodate AFTER its read completes and returns NULL if the
     * bit has been cleared in the meantime, which callers reported as
     * -EIO. Since this refresh runs on EVERY dentry revalidate, any
     * directory busy enough to be looked up while being read hit it
     * constantly -- measured at several spurious open()
     * EIOs per 300 creates with an `ls` running alongside.
     *
     * The leaf is refreshed in the READING thread's own context instead
     * (cetrafs_read_leaf_bh() below), where the clear-and-reread is one
     * atomic operation under the buffer lock rather than two threads
     * fighting over the same buffer's flags. */

    ret = invalidate_inode_pages2(inode->i_mapping);
    if (ret)
        pr_warn("ino=%llu could not fully drop stale page cache on refresh: %d\n", (unsigned long long) inode->i_ino,
                ret);
    return 0;
}

/*
 * Found via real two-node testing: chmod/xattr/truncate/
 * rename/hardlink/symlink changes made by one node stayed invisible to a
 * peer that had already resolved this same inode once before (its VFS
 * inode object just sat in icache, never refreshed again by a plain
 * stat()/getattr() -- only cetrafs_lock_open() ever refreshed anything,
 * and only across an actual open() call). dir.c's cetrafs_d_revalidate()
 * calls this for every already-cached *positive* dentry it encounters, so
 * a peer's change becomes visible on the next path lookup, not only on
 * the next open().
 *
 * Does its own invalidate-then-read (ioutil.c's forced-fresh pattern) and
 * only applies it when this node isn't itself the live holder of this
 * inode's write lock (lock.c's cetrafs_lock_held_for_write_locally()) --
 * that's the only case where refreshing could regress this node's own
 * in-flight write with a stale-by-comparison on-disk snapshot.
 *
 * this used to gate on "raw.mtime is strictly
 * newer than what's cached" instead, mirroring lock.c's own open-path
 * refresh at the time. Found wrong via a real two-node repro covering
 * chmod/truncate-shrink/hardlink specifically: none of those bump mtime
 * (chmod/link only ever touch ctime; this codebase's own
 * cetrafs_truncate_shrink() doesn't touch either), so a peer's chmod or
 * truncate never looked "newer" by this test and the refresh silently
 * never fired -- confirmed exactly matching the reported failures
 * ("chmod: reader sees new mode bits -- want 0640, got 0644" etc).
 * Switching the gate to "do I locally hold the write lock" instead of a
 * timestamp comparison sidesteps the whole mtime-blind-operation class:
 * it's tied to the actual invariant (is there a local writer whose
 * progress could be regressed), not to whether a particular field
 * happens to get touched by a particular op.
 */
int cetrafs_refresh_vfs_inode_if_newer(struct inode *inode)
{
    struct super_block *sb = inode->i_sb;
    cetrafs_inode_t raw;
    int ret;

    /* IDENTITY, not content -- see cetrafs_lock_identity_cache_trusted().
     * This gate also guards the generation check below, so it must not
     * be satisfied by a file nobody has open. */
    if (cetrafs_lock_identity_cache_trusted(inode))
        return 0;

    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret)
        return ret;

    /* v0x0008 reuse detection: a different generation means this is not
     * the same file this object was instantiated from -- a peer deleted
     * it and reused the number. Refreshing stat fields onto an object
     * wearing the OLD file's i_op/i_fop would type-confuse the VFS (the
     * caught case: a cached symlink object reused for a regular file,
     * whose data then got walked as a link target). Unhash the stale
     * object so the next iget instantiates a fresh one, and tell the
     * caller (-ESTALE): d_revalidate reacts by invalidating the dentry,
     * iget's cache-hit path by dropping its ref and retrying. */
    if (cetrafs_inode_get_generation(inode) != cetrafs_le64(raw.generation)) {
        remove_inode_hash(inode);
        return -ESTALE;
    }

    ret = cetrafs_apply_raw_to_vfs_inode(inode, &raw);
    if (ret == -ESTALE) {
        /* apply() says the record describes a deleted file (the
         * generation case was handled above). Unhash for the same
         * reason: cetrafs_iget()'s cache-hit path reacts to -ESTALE by
         * dropping its reference and retrying, and a retry that found
         * this same object still hashed would refresh it, get -ESTALE
         * again, and spin forever. Unhashed, the retry takes the fill
         * path, which refuses it once and for all. */
        remove_inode_hash(inode);
    }
    return ret;
}
