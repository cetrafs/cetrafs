// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/buffer_head.h>
#include <linux/crc32c.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/hash.h>
#include <linux/security.h>
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

/* The task-local scope of an fdatasync (file.c cetrafs_sync_inode_meta()):
 * the task's journal_info names it while the VFS sync of its inode runs.
 * True when the scope is for 'inode'; the caller is then leaving a
 * time-only change unpublished, and the scope records that so the sync
 * can re-dirty the inode (the times are still owed, just not by this
 * datasync). */
bool cetrafs_dsync_drop_times(struct inode *inode)
{
    struct cetrafs_dsync_scope *s = current->journal_info;

    if (!s || s->inode != inode)
        return false;
    s->times_dropped = true;
    return true;
}

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

/*
 * Record publish epochs (BUG-CLASSES class 29). A refresh reads a record
 * and applies it to in-core state later; a LOCAL publish that lands in
 * between, and whose writer then updates in-core state to match, would
 * be reverted by that apply. Every write of a record block -- each swap
 * (caw.c) and each whole-record write -- bumps the epoch of its block
 * once the device (or, unsynced, the buffer the forced-fresh read
 * returns) holds it. A refresh samples the epoch before its read and,
 * under the locks its apply holds, re-reads if it moved.
 *
 * Hashed, not per object: a publisher needs no in-core inode (eviction,
 * journal replay, a number we hold no object for), and a collision only
 * costs a re-read. Only inode records are sampled, so only they bump:
 * the other swaps -- free-count flushes, heartbeats, Zone Group claims --
 * are the busiest, and would turn every slot into a collision. 4096
 * slots (16 KiB) keep collisions between records rare; the re-reads they
 * cost are counted (refresh_ns_rereads in procfs info).
 */
#define CETRAFS_REC_EPOCH_BITS 12
static atomic_t cetrafs_rec_epoch[1U << CETRAFS_REC_EPOCH_BITS];

static atomic_t *cetrafs_rec_epoch_slot(struct super_block *sb, u64 lba)
{
    return &cetrafs_rec_epoch[hash_64(lba ^ (u64) (uintptr_t) sb, CETRAFS_REC_EPOCH_BITS)];
}

void cetrafs_rec_epoch_bump(struct super_block *sb, u64 lba)
{
    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    u64 first;

    /* Not an inode record: nothing samples it. Without a layout (mount
     * still building it) bump anyway -- a spare re-read, never a miss. */
    if (raw_sb) {
        first = le64_to_cpu(raw_sb->inode_table_start);
        if (lba < first || lba - first >= le32_to_cpu(raw_sb->inodes_count))
            return;
    }
    smp_mb__before_atomic(); /* the write is visible before the bump */
    atomic_inc(cetrafs_rec_epoch_slot(sb, lba));
    smp_mb__after_atomic();
}

u64 cetrafs_rec_epoch_sample(struct super_block *sb, u64 ino)
{
    u64 e = (u64) (u32) atomic_read(cetrafs_rec_epoch_slot(sb, cetrafs_inode_lba(sb, ino)));

    smp_rmb(); /* sampled before the read it guards */
    return e;
}

/* Stamp a WHOLE record: identity echoes plus both sector CRCs. Only for
 * writers entitled to the whole record (create/free/journal-less paths,
 * and directory records under their namespace lock) and for staged
 * images later split across the two-step publish. */
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
/* TEST ONLY: stamp every file_seq with this value (low 48 bits) instead
 * of the clock -- the top of the range, to stage the wrap
 * (tests/kernel/file_seq_wrap.sh). 0 = off. */
static unsigned long long cetrafs_file_seq_force_val;
cetrafs_test_param(file_seq_force_val, cetrafs_file_seq_force_val, ullong, 0644);
MODULE_PARM_DESC(file_seq_force_val, "TEST ONLY: stamp file_seq with this value instead of the clock (0 = off)");
/* TEST ONLY: stamp file_seq this many ns in the past of the clock -- a
 * publish noted long ago (tests/kernel/file_seq_wrap.sh). 0 = off. */
static unsigned long long cetrafs_file_seq_force_age_ns;
cetrafs_test_param(file_seq_force_age_ns, cetrafs_file_seq_force_age_ns, ullong, 0644);
MODULE_PARM_DESC(file_seq_force_age_ns, "TEST ONLY: stamp file_seq this many ns in the past (0 = off)");

/* A file_seq attributed to node_id: whose change it is, as every decoder
 * reads it (CETRAFS_FILE_SEQ_NODE()). Only journal replay names a node
 * other than this one -- the redo IS that node's write landing. */
static u64 cetrafs_file_seq_new_as(struct super_block *sb, u32 node_id)
{
    u64 val;

    val = READ_ONCE(cetrafs_file_seq_force_val);
    if (!val)
        val = cetrafs_sb_stamp_ns(sb) - READ_ONCE(cetrafs_file_seq_force_age_ns);
    val &= CETRAFS_FILE_SEQ_VAL_MASK;
    if (!val)
        val = 1;
    return ((u64) (node_id & 0xFFFFu) << CETRAFS_FILE_SEQ_NODE_SHIFT) | val;
}

u64 cetrafs_file_seq_new(struct super_block *sb)
{
    u32 node_id = 0;

    (void) cetrafs_sb_get_node_id(sb, &node_id);
    return cetrafs_file_seq_new_as(sb, node_id);
}

/* The one writer of fd_checksum (tests/image/source_invariants.sh):
 * every publish of the file sector stamps a new file_seq, named as
 * node_id's change. */
static void cetrafs_inode_stamp_crc_fd_as(struct super_block *sb, cetrafs_inode_t *in, u32 node_id)
{
    in->fd_ino = in->ino;
    in->fd_generation = in->generation;
    in->file_seq = cetrafs_cpu_to_le64(cetrafs_file_seq_new_as(sb, node_id));
    in->fd_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_fd(in));
}

void cetrafs_inode_stamp_crc_fd(struct super_block *sb, cetrafs_inode_t *in)
{
    u32 node_id = 0;

    (void) cetrafs_sb_get_node_id(sb, &node_id);
    cetrafs_inode_stamp_crc_fd_as(sb, in, node_id);
}

/*
 * Read inode #ino's raw record out of the global inode table. As of
 * v0x0007 every record occupies its own whole block --
 * block-mates were how one node's record write could clobber a record
 * another node owned in the same shared block -- so this is one block
 * read at a fixed offset, no straddle handling.
 */
/* TEST ONLY: accept an unknown lock_mode, as before audit L-F8 -- the
 * control of tests/kernel/lock_mode_unknown.sh. */
static bool cetrafs_lock_mode_check_off;
cetrafs_test_param(lock_mode_check_off, cetrafs_lock_mode_check_off, bool, 0644);
MODULE_PARM_DESC(lock_mode_check_off, "TEST ONLY: a record whose lock_mode is not a lock state is accepted");

static bool cetrafs_lock_mode_ok_test(u32 m)
{
    return READ_ONCE(cetrafs_lock_mode_check_off) || m <= CETRAFS_LOCK_YIELD;
}

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

        if (!cetrafs_record_tear_injected("inode record") && cetrafs_inode_crcs_ok(out)) {
            /* A valid record in the wrong slot -- a misdirected write,
             * or a record copied to where it does not belong -- is not
             * a torn read, and re-reading will not change it. Without
             * this, every caller took the other inode's mode, size and
             * EXTENTS as this one's. */
            if (cetrafs_le64(out->ino) != ino) {
                pr_err("ino=%llu: its slot holds a valid record for ino=%llu -- misplaced, refusing it\n",
                       (unsigned long long) ino, (unsigned long long) cetrafs_le64(out->ino));
                cetrafs_sb_corrupt(sb, ino);
                return -EUCLEAN;
            }
            /* The size is a length read off the device and becomes
             * i_size, a signed loff_t: past the format ceiling it names
             * blocks no extent can address, and past 2^63 it is
             * negative to every VFS path that reads it. A checksum
             * proves neither. */
            if (!cetrafs_size_sane(cetrafs_le64(out->size))) {
                pr_err("ino=%llu: its record's size %llu is past the format's %llu-byte ceiling -- refusing it\n",
                       (unsigned long long) ino, (unsigned long long) cetrafs_le64(out->size),
                       (unsigned long long) CETRAFS_MAX_FILE_BYTES);
                cetrafs_sb_corrupt(sb, ino);
                return -EUCLEAN;
            }
            /* lock_mode is an enum: an unknown value passes the checksum
             * and reads as "free" to the open path but "held" to the
             * CAS mutators (audit L-F8). Refused here, for every reader. */
            if (!cetrafs_lock_mode_ok_test(cetrafs_le32(out->lock_mode))) {
                pr_err("ino=%llu: its record's lock_mode %u is not a lock state -- refusing it\n",
                       (unsigned long long) ino, cetrafs_le32(out->lock_mode));
                cetrafs_sb_corrupt(sb, ino);
                return -EUCLEAN;
            }
            return 0;
        }

        /* Back off between attempts. A mismatch here is a peer's
         * in-flight record write seen torn, and a peer's write takes
         * milliseconds -- without a pause the whole retry budget is a
         * few microseconds of re-reads and a perfectly transient tear
         * is reported as -EUCLEAN. dir.c's dirent reader has always
         * done this and says why; the record readers did not. The
         * pause is cetrafs_tear_backoff()'s millisecond budget: a fixed
         * 100-400 us did not span the write it was waiting for (review
         * E2). */
        if (attempt + 1 < CETRAFS_RAW_INODE_READ_RETRIES)
            cetrafs_tear_backoff(attempt);
    }

#ifdef CETRAFS_TRACE
    {
        /* What are the bad bytes, and what state is the buffer in?
         * Device dumps kept coming back VALID while the kernel saw
         * garbage -- this shows the kernel's view at failure time. */
        struct buffer_head *_b = sb_find_get_block(sb, blk);

        ctrace("EUCLEANDUMP ino=%llu stored=0x%llx calc=0x%x bhstate=%s%s%s bytes=%*ph\n", (unsigned long long) ino,
               (unsigned long long) cetrafs_le64(out->ns_checksum), cetrafs_inode_crc_ns(out),
               _b && buffer_uptodate(_b) ? "U" : "-", _b && buffer_dirty(_b) ? "D" : "-",
               _b && buffer_locked(_b) ? "L" : "-", 64, (const u8 *) out);
        if (_b)
            brelse(_b);
    }
#endif
    pr_err("ino=%llu failed its record checksum %d times -- corrupted, not just a torn concurrent read\n",
           (unsigned long long) ino, CETRAFS_RAW_INODE_READ_RETRIES);
    cetrafs_sb_corrupt(sb, ino);
    return -EUCLEAN;
}

/* TEST ONLY: widen the window between the record read and the shadow
 * overlay to a size a test can reliably hit -- the race below needs a
 * writeback publish inside a few-instruction gap otherwise. */
static unsigned int cetrafs_fd_overlay_stall_ms;
cetrafs_test_param(fd_overlay_stall_ms, cetrafs_fd_overlay_stall_ms, uint, 0644);
MODULE_PARM_DESC(fd_overlay_stall_ms, "TEST ONLY: widen the record-read-to-overlay window to make the torn-read race hittable");

/*
 * cetrafs_read_raw_inode() + the hot path's shadow overlay, as ONE unit.
 *
 * The naive pair -- read the record, then overlay the shadow -- is torn
 * against a concurrent publisher (VFS writeback's CAS does not take
 * inode_lock): the read can return a record from BEFORE the publish and
 * the overlay can run AFTER its dirty-clear, leaving neither source
 * carrying the published extents. The shadow's dirty flag is therefore
 * sampled BEFORE the read; a clear that lands in between is detected by
 * cetrafs_inode_fd_overlay_checked() and answered with a re-read, which
 * then necessarily includes the publish (record write happens before
 * flag clear, both under fd_lock/pub_mutex ordering).
 *
 * The retry cap never triggers in practice (it needs a publish per
 * iteration); if it ever does, the publish mutex serializes the last
 * attempt outright.
 */
int cetrafs_read_raw_inode_overlaid(struct super_block *sb, struct inode *inode, cetrafs_inode_t *raw)
{
    int tries, ret;

    for (tries = 0; tries < 8; tries++) {
        bool pre = cetrafs_inode_fd_dirty_snap(inode);

        ret = cetrafs_read_raw_inode(sb, inode->i_ino, raw);
        if (ret)
            return ret;
        if (unlikely(cetrafs_fd_overlay_stall_ms))
            msleep(cetrafs_fd_overlay_stall_ms); /* TEST ONLY: hold the torn-read window open */
        if (cetrafs_inode_fd_overlay_checked(inode, raw, pre) == 0)
            return 0;
        /* a publish landed between the read and the check -- re-read */
    }

    cetrafs_inode_fd_pub_lock(inode);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, raw);
    if (!ret)
        cetrafs_inode_fd_overlay(inode, raw);
    cetrafs_inode_fd_pub_unlock(inode);
    return ret;
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
            if (cetrafs_sync_buffer(sb, bh))
                pr_err_ratelimited("ino=%llu: a dirty record could not be written back at invalidate\n",
                                   (unsigned long long) ino);
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
 * exclusive lock for data growth/truncate, the namespace lock for
 * create/unlink/rename/xattr, the lock.c CAS for lock claims), so there
 * is nothing in the block to preserve and nobody
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
 * write -- remains for records whose writer is entitled to all of them:
 * a just-allocated number (create/mkdir/symlink and their unwinds),
 * offline tools, and a directory record that rename() rewrites ('..',
 * or a retargeted name's dirent sequence). A directory record IS shared,
 * so those callers hold the directory's namespace lock across the blind
 * write, and read the record fresh inside it: the namespace lock is what
 * stops a peer publishing either sector in between.
 */

struct cetrafs_ns_cas_ctx {
    u64 generation;
    void (*apply)(cetrafs_inode_t *rec, void *arg);
    void *arg;
};

/*
 * A mutator that KEEPS fields from the image it was handed has to be
 * able to trust them.
 *
 * The image comes straight off the device, independently of whatever
 * the caller read and verified earlier -- a peer may have rewritten the
 * sector, or the read may have caught a write in flight. With no check,
 * a torn or corrupt sector has one field changed and a FRESH checksum
 * stamped over the rest: a transient tear, which a reader would have
 * retried through, becomes permanent corruption that no checker can
 * see any more.
 *
 * -EUCLEAN, not a retry: cetrafs_cas_region() re-reads and re-runs the
 * mutator on a MISCOMPARE, so a tear that settles is already handled
 * above this. Reaching here with a bad sum means the bytes really are
 * wrong.
 */
static int cetrafs_ns_image_trustworthy(const cetrafs_inode_t *rec)
{
    return cetrafs_inode_crc_ns(rec) == (u32) cetrafs_le64(rec->ns_checksum);
}

static int cetrafs_ns_cas_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_ns_cas_ctx *ctx = priv;
    cetrafs_inode_t rec;

    if (len < CETRAFS_INODE_NS_BYTES)
        return -EINVAL;
    memset(&rec, 0, sizeof(rec));
    memcpy(&rec, image, CETRAFS_INODE_NS_BYTES);

    if (!cetrafs_ns_image_trustworthy(&rec)) {
        pr_warn_ratelimited("ns CAS on ino=%llu: the sector on the device fails its checksum -- refusing to stamp a "
                            "fresh one over it\n",
                            (unsigned long long) cetrafs_le64(rec.ino));
        return -EUCLEAN;
    }

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
    /*
     * The allocation bits first, as in cetrafs_write_raw_inode() and for
     * the same reason (rule 8): this swap reaches the device at once, and
     * it can publish a block allocated moments ago -- setxattr's new
     * xattr block -- whose bit is still only in this node's cache. A node
     * dying in between left the record naming a block every allocator
     * reads as FREE (tests/kernel/xattr_block_bitmap_order.sh). Here
     * rather than at that one caller: every sector-0 publish passes
     * through, and the flush costs nothing when nothing was allocated.
     */
    {
        int fret = cetrafs_alloc_flush_bitmaps(sb);

        if (fret)
            return fret;
    }
    {
        int ret =
            cetrafs_cas_record_seeded(sb, lba, seed, seed ? CETRAFS_INODE_NS_BYTES : 0, cetrafs_ns_cas_mutate, &ctx);

        if (ret == 0)
            cetrafs_record_write_counted();
        return ret;
    }
}

static void cetrafs_ns_apply_zero_nlink(cetrafs_inode_t *rec, void *arg)
{
    (void) arg;
    rec->nlink = cetrafs_cpu_to_le32(0);
}

/*
 * Inode-number ownership is arbitrated on the RECORD, between a creator
 * and an orphan scrub (possibly a peer's) or an evict. The bitmap bit
 * alone cannot: between a creator's bit CAS and its record write the
 * record is still the dead previous one, and a scrub judging "bit set,
 * record dead" reclaims a number that is being born. The birth registry
 * stops this node's own scrub only. Both sides therefore CAS sector 0:
 *
 *   creator: bit CAS, read record R, BIRTH CLAIM = CAS(R -> R with
 *            ns_lock_owner=me). Miscompare: a reclaim (or a second
 *            creator) got there first -- abandon the number, bit
 *            untouched, take another. A foreign ns_lock_owner in R: a
 *            reclaim holds it, and may already have done its one clear
 *            -- wait for its release, then a fresh bit read decides
 *            (set: claim the released record; clear: walk away). Once
 *            the claim is held, read the bit fresh again: a reclaim's
 *            whole cycle can fit between our bit CAS and our read, and
 *            then our claim landed on a number whose bit is clear --
 *            give the claim back. See cetrafs_alloc_inode().
 *   reclaim: verdict on (bit set, record dead gen G, no lock), CLAIM =
 *            CAS(dead G, unlocked -> ns_lock_owner=me), clear the bit,
 *            RELEASE = CAS(exactly what the claim wrote -> unlocked).
 *
 * Every one of these swaps also advances dirent_seq, sector 0's change
 * stamp (unused on a dead record otherwise), and that is what keeps the
 * arbitration free of ABA: a claim-clear-release that put back exactly
 * the bytes a creator read would let that creator's birth CAS land on a
 * number whose bit had been cleared under it. Within one life of a
 * number the stamp only moves forward. A new life starts over: the
 * creator's whole-record write (create, mkdir, symlink) follows its
 * birth claim and writes dirent_seq back to zero along with the rest of
 * the record.
 *
 * NOT the generation: it is echoed into the file sector (fd_generation),
 * which none of these swaps writes, and a record whose two sectors
 * disagree on it is a half-landed write to every reader -- the kernel's
 * and fsck's ("marked in use but its checksum is wrong"). The previous
 * version of this bumped it, and churn_oracle caught it.
 *
 * A VIRGIN number (never allocated since mkfs: sector 0 all zero) needs
 * no birth claim: no reclaim judges a record that fails its checksum.
 * tests/kernel/scrub_vs_birth.sh.
 */
void cetrafs_ns_stamp_advance(cetrafs_inode_t *rec)
{
    rec->dirent_seq = cetrafs_cpu_to_le64(cetrafs_le64(rec->dirent_seq) + 1);
}

struct cetrafs_birth_ctx {
    const u8 *seed; /* sector 0 as the creator judged it */
    u32 me;
    u32 my_incarnation;
    bool lost; /* the verdict travels here: a >0 mutate return is flattened to success */
};

static int cetrafs_birth_claim_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_birth_ctx *ctx = priv;
    cetrafs_inode_t rec;

    if (len < CETRAFS_INODE_NS_BYTES)
        return -EINVAL;
    if (memcmp(image, ctx->seed, CETRAFS_INODE_NS_BYTES)) {
        ctx->lost = true;
        return 1; /* changed since the verdict: not ours to claim */
    }
    memset(&rec, 0, sizeof(rec));
    memcpy(&rec, image, CETRAFS_INODE_NS_BYTES);
    rec.ns_lock_owner = cetrafs_cpu_to_le32(ctx->me);
    rec.ns_lock_incarnation = cetrafs_cpu_to_le32(ctx->my_incarnation);
    cetrafs_ns_stamp_advance(&rec);
    cetrafs_inode_stamp_crc_ns(&rec);
    memcpy(image, &rec, CETRAFS_INODE_NS_BYTES);
    return 0;
}

/* The creator's half. 'seed' is the record read after the bit CAS, and
 * must be a checksummed record (a virgin one needs no claim). Sets
 * *out_lost when a reclaim got to the record first. */
int cetrafs_inode_birth_claim(struct super_block *sb, u64 ino, const cetrafs_inode_t *seed, bool *out_lost)
{
    struct cetrafs_birth_ctx ctx = {.seed = (const u8 *) seed, .my_incarnation = cetrafs_sb_incarnation(sb)};
    u64 lba = cetrafs_inode_lba(sb, ino);
    int ret;

    *out_lost = false;
    if (!lba)
        return -EINVAL;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    ret = cetrafs_sb_get_node_id(sb, &ctx.me);
    if (ret)
        return ret;
    ret = cetrafs_cas_record_seeded(sb, lba, seed, CETRAFS_INODE_NS_BYTES, cetrafs_birth_claim_mutate, &ctx);
    *out_lost = ctx.lost;
    if (ret == 0 && !ctx.lost)
        cetrafs_record_write_counted();
    return ret;
}

struct cetrafs_reclaim_ctx {
    u64 generation;
    u64 seq; /* claim: out, the stamp it wrote; release: in, the stamp required */
    u64 expect_seq; /* claim, steal: the stamp the verdict read */
    u32 me;
    u32 my_incarnation;
    u32 steal_from; /* steal: the claimant judged stale and fenced */
    int mode;
};

static int cetrafs_reclaim_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_reclaim_ctx *ctx = priv;
    cetrafs_inode_t rec;

    if (len < CETRAFS_INODE_NS_BYTES)
        return -EINVAL;
    memset(&rec, 0, sizeof(rec));
    memcpy(&rec, image, CETRAFS_INODE_NS_BYTES);
    if (!cetrafs_ns_image_trustworthy(&rec))
        return -EUCLEAN;
    if (cetrafs_le64(rec.generation) != ctx->generation)
        return -ESTALE; /* reborn */

    switch (ctx->mode) {
    case CETRAFS_RECLAIM_CLAIM:
        /* Still exactly the dead, unlocked record judged -- the same
         * namespace stamp included. Without the stamp a verdict read
         * before another free of this record (a peer's evict of its own
         * copy of the file, or the orphan scrub) matched the record
         * after it: dead, same generation, unclaimed again. If a peer's
         * create then held the number, the bit read set and the blocks
         * that free had given back were freed a second time. */
        if (cetrafs_le32(rec.nlink) != 0 || cetrafs_le32(rec.ns_lock_owner) != CETRAFS_NODE_ID_NONE ||
            cetrafs_le64(rec.dirent_seq) != ctx->expect_seq)
            return -ESTALE;
        rec.ns_lock_owner = cetrafs_cpu_to_le32(ctx->me);
        rec.ns_lock_incarnation = cetrafs_cpu_to_le32(ctx->my_incarnation);
        break;
    case CETRAFS_RECLAIM_STEAL:
        /* A free whose claimant went stale holding it, judged at this
         * stamp; the claimant has been fenced. */
        if (cetrafs_le32(rec.nlink) != 0 || cetrafs_le32(rec.ns_lock_owner) != ctx->steal_from ||
            cetrafs_le64(rec.dirent_seq) != ctx->expect_seq)
            return -ESTALE;
        rec.ns_lock_owner = cetrafs_cpu_to_le32(ctx->me);
        rec.ns_lock_incarnation = cetrafs_cpu_to_le32(ctx->my_incarnation);
        break;
    case CETRAFS_RECLAIM_FORGET:
        /* Our claim, as we left it: the record's last reference to a
         * block goes before its number does (cetrafs_inode_forget_tree()). */
        if (cetrafs_le32(rec.ns_lock_owner) != ctx->me || cetrafs_le64(rec.dirent_seq) != ctx->seq)
            return -ESTALE;
        rec.xattr_block = cetrafs_cpu_to_le64(0);
        break;
    case CETRAFS_RECLAIM_RELEASE:
        /* Exactly what our claim wrote: a creator's birth claim on the
         * same number (this node's creator also writes our id) has
         * advanced the stamp, and then the record is the creator's. */
        if (cetrafs_le32(rec.ns_lock_owner) != ctx->me || cetrafs_le64(rec.dirent_seq) != ctx->seq)
            return -ESTALE;
        rec.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
        rec.ns_lock_incarnation = cetrafs_cpu_to_le32(0);
        break;
    default: /* CETRAFS_RECLAIM_BIRTH_ABORT: a create that claimed and failed */
        if (cetrafs_le32(rec.ns_lock_owner) != ctx->me || cetrafs_le32(rec.nlink) != 0)
            return -ESTALE;
        rec.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
        rec.ns_lock_incarnation = cetrafs_cpu_to_le32(0);
        break;
    }
    cetrafs_ns_stamp_advance(&rec);
    ctx->seq = cetrafs_le64(rec.dirent_seq);
    cetrafs_inode_stamp_crc_ns(&rec);
    memcpy(image, &rec, CETRAFS_INODE_NS_BYTES);
    return 0;
}

/* The reclaim's halves -- claim the dead record judged (generation G),
 * and, after clearing the bit, release it -- plus a failed create's
 * undo of its birth claim. *seq carries the claim's stamp to the
 * release. */
int cetrafs_inode_reclaim_claim(struct super_block *sb, u64 ino, u64 generation, int mode, u64 *seq)
{
    return cetrafs_inode_reclaim_claim_at(sb, ino, generation, mode, seq, seq ? *seq : 0, CETRAFS_NODE_ID_NONE);
}

/* The same, for the modes that judge a stamp (claim, steal): 'expect' is
 * the dirent_seq the verdict read, 'from' the stale claimant (steal). */
int cetrafs_inode_reclaim_claim_at(struct super_block *sb, u64 ino, u64 generation, int mode, u64 *seq, u64 expect,
                                   u32 from)
{
    struct cetrafs_reclaim_ctx ctx = {.generation = generation, .mode = mode, .seq = seq ? *seq : 0,
                                      .expect_seq = expect, .steal_from = from,
                                      .my_incarnation = cetrafs_sb_incarnation(sb)};
    u64 lba = cetrafs_inode_lba(sb, ino);
    int ret;

    if (!lba)
        return -EINVAL;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    ret = cetrafs_sb_get_node_id(sb, &ctx.me);
    if (ret)
        return ret;
    ret = cetrafs_cas_record(sb, lba, cetrafs_reclaim_mutate, &ctx);
    if (ret == 0) {
        cetrafs_record_write_counted();
        if (seq)
            *seq = ctx.seq;
    }
    return ret;
}

/* Zero a record's nlink by sector-0 CAS -- the free path's "make the
 * on-disk state honest" write, now unable to clobber anything else. */
int cetrafs_inode_ns_zero_nlink(struct super_block *sb, u64 ino, const cetrafs_inode_t *seed)
{
    return cetrafs_inode_ns_cas(sb, ino, cetrafs_le64(seed->generation), seed, cetrafs_ns_apply_zero_nlink, NULL);
}

/*
 * After a journal replay rewrote one of this inode's metadata blocks,
 * advance its change stamp -- dirent_seq for a directory, file_seq for
 * anything else -- so a node caching the block (its dirents, its extent
 * tree) reads it again. A redo changes bytes no stamp announced: without
 * this, a peer that had cached the block before the writer died went on
 * trusting its copy (L9). Only the stamp moves, on the record the swap
 * finds, and only while the record is still the generation the entry
 * named.
 */
static void cetrafs_ns_apply_advance(cetrafs_inode_t *rec, void *arg)
{
    (void) arg;
    cetrafs_ns_stamp_advance(rec);
}

struct cetrafs_fd_touch_ctx {
    struct super_block *sb;
    u64 ino, generation;
    u32 as_node;
};

/* TEST ONLY: the replay's stamp names the replaying node, as it did
 * before review F1 (tests/kernel/journal_replay_owner.sh). */
static bool cetrafs_replay_stamp_as_self;
cetrafs_test_param(replay_stamp_as_self, cetrafs_replay_stamp_as_self, bool, 0644);
MODULE_PARM_DESC(replay_stamp_as_self, "TEST ONLY: a replay's file_seq advance names the replaying node");

static int cetrafs_fd_touch_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_fd_touch_ctx *ctx = priv;
    cetrafs_inode_t rec;

    if (len < CETRAFS_INODE_FD_BYTES)
        return -EINVAL;
    memset(&rec, 0, sizeof(rec));
    cetrafs_inode_fd_from_image(&rec, image);
    if (cetrafs_le64(rec.fd_ino) != ctx->ino || cetrafs_le64(rec.fd_generation) != ctx->generation)
        return -ESTALE; /* the number was reused: not the entry's file */
    if (cetrafs_inode_crc_fd(&rec) != (u32) cetrafs_le64(rec.fd_checksum))
        return -EUCLEAN; /* restamping would bless the damage */
    rec.ino = rec.fd_ino;
    rec.generation = rec.fd_generation;
    /* A new file_seq, and the CRC over it -- named as the DEAD node's
     * change. Named as ours, every gate that decodes the stamp read it
     * on the replaying node as its own writeback: a tree cached before
     * the redo stayed trusted, and a truncate or punch planned from it
     * was not refused -- on the node most likely to hold the file, the
     * one the VM was restarted on (review F1). */
    cetrafs_inode_stamp_crc_fd_as(ctx->sb, &rec, ctx->as_node);
    cetrafs_inode_fd_to_image(image, &rec);
    return 0;
}

int cetrafs_inode_advance_change_stamp(struct super_block *sb, u64 ino, u64 generation, bool dir, u32 as_node)
{
    struct cetrafs_fd_touch_ctx ctx = {.sb = sb, .ino = ino, .generation = generation, .as_node = as_node};

    if (READ_ONCE(cetrafs_replay_stamp_as_self))
        (void) cetrafs_sb_get_node_id(sb, &ctx.as_node);
    u64 lba = cetrafs_inode_lba(sb, ino);

    if (!lba)
        return -EINVAL;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    if (dir)
        return cetrafs_inode_ns_cas(sb, ino, generation, NULL, cetrafs_ns_apply_advance, NULL);
    /* No fd_pub here: no in-core object is taken (an ilookup waits on an
     * inode being evicted, and the replay can run inside that eviction).
     * The stamp names the dead owner, which no refresh of this node
     * judges as its own -- see BUG-CLASSES class 29. */
    return cetrafs_cas_record_fd_seeded(sb, lba, NULL, 0, cetrafs_fd_touch_mutate, &ctx);
}

struct cetrafs_fd_write_ctx {
    const cetrafs_inode_t *src;
    struct super_block *sb;
    u64 stamped_seq; /* what we wrote, so the caller can keep its own cache valid */
    bool check_plan;  /* refuse if a PEER stamped the sector since plan_seq */
    u64 plan_seq;     /* the file_seq of the record the caller's plan was built from */
    u32 me;
    u64 found_seq;    /* on a refusal: the peer's stamp found on the device */
};

/* TEST ONLY: publish a planned rebuild without its stamp check -- the
 * negative control for tests/kernel/rebuild_peer_stamp.sh. */
static bool cetrafs_rebuild_plan_unchecked;
cetrafs_test_param(rebuild_plan_unchecked, cetrafs_rebuild_plan_unchecked, bool, 0644);
MODULE_PARM_DESC(rebuild_plan_unchecked, "TEST ONLY: skip the truncate/punch publish's file_seq check");

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

    /* The plan's stamp (CLAUDE.md rule 10). A rebuild -- truncate,
     * punch -- built its new tree from a record read seconds ago, and
     * its "is a peer open now?" recheck is presence, not change: a peer
     * session that opened, appended and CLOSED inside that window left
     * nobody open and a different tree on the device. Publishing would
     * put the pre-peer tree back over the peer's extents and erase its
     * stamp. A stamp that moved and is not ours is that peer; our own
     * publishes in the window are serialised with this one locally. */
    if (ctx->check_plan && cetrafs_le64(rec.file_seq) != ctx->plan_seq &&
        CETRAFS_FILE_SEQ_NODE(cetrafs_le64(rec.file_seq)) != (ctx->me & 0xFFFFu)) {
        ctx->found_seq = cetrafs_le64(rec.file_seq);
        return -ETXTBSY;
    }

    cetrafs_inode_fd_copy(&rec, ctx->src);
    rec.ino = ctx->src->ino; /* for the echo stamp below */
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
static int __cetrafs_write_raw_inode_fd(struct super_block *sb, u64 ino, const cetrafs_inode_t *src,
                                       struct inode *self, const u64 *plan_seq)
{
    struct cetrafs_fd_write_ctx ctx = {.src = src, .sb = sb};
    u64 lba = cetrafs_inode_lba(sb, ino);

    if (!lba)
        return -EINVAL;
    if (cetrafs_sb_is_fenced(sb))
        return -EIO;
    if (plan_seq) {
        int ret = cetrafs_sb_get_node_id(sb, &ctx.me);

        if (ret)
            return ret;
        ctx.check_plan = !cetrafs_rebuild_plan_unchecked;
        ctx.plan_seq = *plan_seq;
    }
    /* The fd sector publishes extents: the blocks they name must be
     * durably allocated first (rule 8's choke point, same as the whole
     * -record writer's). If they are not, publish NOTHING: the shadow
     * stays in core and the next boundary retries both. */
    {
        int ret = cetrafs_alloc_flush_bitmaps(sb);

        /* ...and durably: the bitmap bits, the new tree's leaves, the
         * data a rebuild copied -- completed, every one, but completed
         * is not durable (cetrafs_publish_flush()). */
        if (!ret)
            ret = cetrafs_publish_flush(sb);
        if (ret)
            return ret;
        ret = cetrafs_cas_record_fd_seeded(sb, lba, NULL, 0, cetrafs_fd_write_mutate, &ctx);

        if (ret == 0) {
            int fret;

            /* Every caller frees something once this returns -- the old
             * tree's meta, the blocks a truncate or punch dropped, a
             * defrag's source run (rule 21). That free must not reach
             * the device before this publish does, and on a volatile
             * cache only a flush orders them. A flush the device refuses
             * here leaves the publish landed and its durability unknown:
             * the free that would follow is what must not happen, so the
             * mount stops (docs/internal/ERRORS.md) and refuses it. */
            fret = cetrafs_publish_flush(sb);
            if (fret)
                cetrafs_sb_fatal(sb, "inode %llu: the device refused a cache flush after a publish (%d)",
                                 (unsigned long long) ino, fret);
            cetrafs_record_write_counted();
            /* Our own stamp: adopt it, or the freshness gate would read
             * the change we just made as a peer's and throw away a cache
             * that is correct by construction -- once per second, on the
             * growing-file hot path. */
            if (self)
                cetrafs_inode_note_local_file_seq(self, ctx.stamped_seq);
            /* ...and make it the stat merge's baseline. Every caller is
             * a LOCAL rebuild (truncate, punch, fallocate, defrag, the
             * nslock release) that also brings core to these values.
             * Left at the previous publish, the next merge read this
             * publish as a change made ELSEWHERE: a defrag that dropped
             * the leaf's 8 sectors, then an append that added 8 back,
             * left core equal to the stale baseline -- "unchanged" --
             * and the merge adopted the defrag's count over the append
             * (tests/kernel/defrag_final_blocks.sh). */
            if (self)
                cetrafs_inode_stat_baseline_set(self, src);
        } else if (ret == -ETXTBSY && ctx.check_plan) {
            pr_warn_ratelimited("cetrafs: inode %llu: another node changed the file while this rebuild was "
                                "planned (stamp %llx, planned from %llx) -- refusing\n",
                                (unsigned long long) ino, (unsigned long long) ctx.found_seq,
                                (unsigned long long) ctx.plan_seq);
        }
        return ret;
    }
}

int cetrafs_write_raw_inode_fd(struct super_block *sb, u64 ino, const cetrafs_inode_t *src, struct inode *self)
{
    return __cetrafs_write_raw_inode_fd(sb, ino, src, self, NULL);
}

/*
 * A dead record whose number this node holds claimed and is about to
 * free: drop every block reference it still carries -- the extent root,
 * size and block count (file sector), the xattr pointer (namespace
 * sector, through the claim; *seq follows the stamp). Once the number is
 * free nothing may free those blocks again, and the record is what the
 * next evict of the same file -- a peer's stale in-core copy -- would
 * free them from: with a peer's create holding the bit at that moment it
 * found the number "still allocated" and freed them a second time.
 * Idempotent; the blocks themselves are already freed, or left to the
 * block scrub as a leak.
 */
int cetrafs_inode_forget_tree(struct super_block *sb, u64 ino, u64 generation, u64 *seq)
{
    cetrafs_inode_t *raw = kmalloc(sizeof(*raw), GFP_NOFS);
    int ret;

    if (!raw)
        return -ENOMEM;
    cetrafs_invalidate_raw_inode(sb, ino);
    ret = cetrafs_read_raw_inode(sb, ino, raw);
    if (!ret && (cetrafs_le64(raw->generation) != generation || cetrafs_le32(raw->nlink) != 0))
        ret = -ESTALE;
    if (!ret && (cetrafs_le16(raw->eh.eh_entries) || cetrafs_le16(raw->eh.eh_depth) || raw->size || raw->blocks)) {
        raw->eh.eh_entries = cetrafs_cpu_to_le16(0);
        raw->eh.eh_depth = cetrafs_cpu_to_le16(0);
        memset(&raw->et, 0, sizeof(raw->et));
        raw->size = cetrafs_cpu_to_le64(0);
        raw->blocks = cetrafs_cpu_to_le64(0);
        /* No fd_pub_mutex, deliberately: this runs inside the eviction of
         * the inode (ilookup would wait on that inode's own I_FREEING),
         * and on the claimed-free path a refresh needs a reference that a
         * dead, unopened number does not have (BUG-CLASSES class 29).
         * Not cetrafs_write_raw_inode_fd(): this publishes no extent,
         * so its bitmap and cache flushes ahead of the swap buy nothing.
         * The flush after it does: the number free that follows must not
         * reach the device first. A refused one is returned, and the
         * caller keeps its claim for a retry. */
        {
            struct cetrafs_fd_write_ctx ctx = {.src = raw, .sb = sb};

            ret = cetrafs_cas_record_fd_seeded(sb, cetrafs_inode_lba(sb, ino), NULL, 0, cetrafs_fd_write_mutate,
                                               &ctx);
            if (!ret) {
                cetrafs_record_write_counted();
                ret = cetrafs_publish_flush(sb);
            }
        }
    }
    if (!ret && raw->xattr_block)
        ret = cetrafs_inode_reclaim_claim(sb, ino, generation, CETRAFS_RECLAIM_FORGET, seq);
    kfree(raw);
    return ret;
}


/* The same publish, refused with -ETXTBSY if another node stamped the
 * file sector since 'plan_seq' -- for a caller that built what it
 * publishes from a record read earlier (truncate, punch). */
int cetrafs_write_raw_inode_fd_planned(struct super_block *sb, u64 ino, const cetrafs_inode_t *src,
                                       struct inode *self, u64 plan_seq)
{
    return __cetrafs_write_raw_inode_fd(sb, ino, src, self, &plan_seq);
}

static int __cetrafs_write_raw_inode(struct super_block *sb, u64 ino, const cetrafs_inode_t *in, bool sync)
{
    if (S_ISDIR(cetrafs_le32(in->mode)))
        ctrace("DRECW ino=%llu size=%llu eh=%u depth=%u from=%pS\n", (unsigned long long) ino,
               (unsigned long long) cetrafs_le64(in->size), (unsigned int) cetrafs_le16(in->eh.eh_entries),
               (unsigned int) cetrafs_le16(in->eh.eh_depth), __builtin_return_address(0));

    const cetrafs_superblock_t *raw_sb = cetrafs_sb_raw(sb);
    cetrafs_inode_t stamped = *in;
    struct buffer_head *bh;
    int ret = 0;

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
    if (sync) {
        int fret = cetrafs_alloc_flush_bitmaps(sb);

        if (fret)
            return fret; /* the record would name blocks still FREE on disk */
    }

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
    /* A forced-fresh read returns this buffer from here on (a dirty one
     * is never dropped): the record's epoch moves now. */
    cetrafs_rec_epoch_bump(sb, bh->b_blocknr);
    if (sync) {
        cetrafs_record_write_counted();
        /* The result IS the answer this function exists to give. A
         * failed sync leaves the buffer clean and !uptodate -- the
         * record image is gone -- and a 0 here let a create publish a
         * dirent naming it, or a directory that had just grown keep a
         * name in a block its record never mapped: reported created,
         * gone after a remount (tests/kernel/record_write_error.sh). */
        ret = cetrafs_sync_buffer(sb, bh);
    }
    brelse(bh);

    if (serialise)
        cetrafs_sb_cas_unlock(sb);
    return ret;
}

/*
 * The whole-record write for a number this node has NO in-core object
 * for: a just-allocated number (create, mkdir, symlink, and their
 * unwinds). A free number has no live object a refresh could be running
 * on -- a refresh needs a reference, and an object for a number is only
 * freed once that number is free -- so there is no fd publish mutex to
 * take. Callers that hold the inode use cetrafs_write_raw_inode_self(),
 * which takes it.
 */
int cetrafs_write_raw_inode(struct super_block *sb, u64 ino, const cetrafs_inode_t *in, bool sync)
{
    return __cetrafs_write_raw_inode(sb, ino, in, sync);
}

/*
 * The whole-record write for a record whose in-core object 'self' this
 * node holds (a directory's create/rename/link, an unlink's target, a
 * directory's size growth). It publishes the file sector too, without
 * a note, so a refresh of 'self' that read the record before this write
 * must not apply it over the write: fd_pub_mutex covers the write, the
 * same as every other file-sector publisher (BUG-CLASSES class 29).
 * Lock order: the caller's namespace lock or inode_lock, then fd_pub.
 */
/* TEST ONLY: the whole-record writer publishes without fd_pub_mutex --
 * the unordered publish, for tests/kernel/refresh_dir_growth_publish.sh. */
static bool cetrafs_record_publish_unlocked;
cetrafs_test_param(record_publish_unlocked, cetrafs_record_publish_unlocked, bool, 0644);
MODULE_PARM_DESC(record_publish_unlocked, "TEST ONLY: whole-record writes publish without fd_pub_mutex");

int cetrafs_write_raw_inode_self(struct inode *self, const cetrafs_inode_t *in, bool sync)
{
    bool locked = !READ_ONCE(cetrafs_record_publish_unlocked);
    int ret;

    if (locked)
        cetrafs_inode_fd_pub_lock(self);
    ret = __cetrafs_write_raw_inode(self->i_sb, self->i_ino, in, sync);
    if (locked)
        cetrafs_inode_fd_pub_unlock(self);
    return ret;
}

/*
 * Read inode #ino from the global inode table and populate a VFS inode
 * from it.
 */
/*
 * Take mode, owner and group from a record into an existing in-core
 * inode. Caller holds inode_lock and has checked generation and type.
 *
 * Clears S_NOSEC every time. The VFS sets it after a write finds no
 * setuid/setgid and no security xattr, and from then on skips the
 * privilege kill without looking; only its own notify_change() clears
 * it. A peer's chmod +s or security.capability arrives here instead,
 * so with the flag left set an unprivileged write kept the bit a peer
 * had just set (tests/kernel/setattr_kill_fresh_mode.sh). Cleared, the
 * next write asks once and sets it again if there is still nothing.
 */
void cetrafs_inode_adopt_identity(struct inode *inode, const cetrafs_inode_t *raw)
{
    inode->i_mode = (umode_t) cetrafs_le32(raw->mode);
    i_uid_write(inode, cetrafs_le32(raw->uid));
    i_gid_write(inode, cetrafs_le32(raw->gid));
    inode->i_flags &= ~S_NOSEC;
}

/*
 * A fresh generation for a newly-ALLOCATED inode (v0x0008; see
 * cetrafs.h's field comment for the cross-node reuse type-confusion this
 * detects). Only needs to differ between successive lives of the same
 * inode number: wall-clock nanoseconds (cetrafs_sb_stamp_ns(), which
 * never steps backward) XOR'd with the allocating node's id comfortably
 * provides that (allocation is cluster-mutexed and
 * multi-nanosecond, so two lives can't share a timestamp; the node id
 * guards the pathological clock-skew case). Never returns 0 -- that's
 * the reserved "unset" value.
 */
u64 cetrafs_inode_new_generation(struct super_block *sb)
{
    u32 node_id = 0;
    u64 gen;

    (void) cetrafs_sb_get_node_id(sb, &node_id);
    gen = cetrafs_sb_stamp_ns(sb) ^ ((u64) node_id << 56);
    return gen ? gen : 1;
}

/* Test-only: fail the next N record reads of an iget fill with -EIO, as
 * a device read error would. tests/kernel/free_inode_keeps_bit.sh. */
static unsigned int cetrafs_iget_read_fail;
cetrafs_test_param(iget_read_fail, cetrafs_iget_read_fail, uint, 0644);
MODULE_PARM_DESC(iget_read_fail, "test-only: fail the next N record reads of an inode fill with -EIO");

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
        if (ret) {
            /* -EUCLEAN (a record the refresh refused) or a device error:
             * nothing confirmed this object, so it is not ours to hand
             * out -- same answer as cetrafs_d_revalidate() gives. The
             * caller sees the errno; a later lookup re-reads. */
            iput(inode);
            return ERR_PTR(ret);
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

    /* A recycled slab object still carries the PREVIOUS file's
     * per-identity state (the slab ctor runs once per object, never on
     * recycle) -- including a defrag dedup latch a dead file left set,
     * which silently disabled auto-defrag for whatever file landed on
     * that slot next. New identity, clean slate. */
    cetrafs_inode_identity_init(inode);

    cetrafs_invalidate_raw_inode(sb, ino);

    if (cetrafs_iget_read_fail) {
        cetrafs_iget_read_fail--; /* test-only; see the parameter */
        ret = -EIO;
    } else {
        ret = cetrafs_read_raw_inode(sb, ino, &raw);
    }
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
    if (cetrafs_le32(raw.nlink) == 0) {
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
        cetrafs_sb_corrupt(sb, ino);
        iget_failed(inode);
        return ERR_PTR(-EUCLEAN);
    }

    unlock_new_inode(inode);

    return inode;
}

/* CAS context for cetrafs_write_vfs_inode()'s stat publish -- see the
 * commentary at its call site. 'written' carries the image the swap
 * actually landed, for the baseline update. */
/* TEST ONLY: stall the stat publish's merge between reading the in-core
 * size and acting on it, so a test can land a local extending write in
 * that gap. */
static unsigned int cetrafs_fd_merge_stall_ms;
cetrafs_test_param(fd_merge_stall_ms, cetrafs_fd_merge_stall_ms, uint, 0644);
MODULE_PARM_DESC(fd_merge_stall_ms, "TEST ONLY: widen the stat publish's read-to-merge window on i_size");

struct cetrafs_vfs_stat_cas_ctx {
    struct inode *inode;
    u64 generation;   /* in-core identity; checked against the fd echo */
    __le64 ino_le;    /* in-core ino, for the echo check */
    bool have_shadow; /* publish the hot path's pending extent state too */
    cetrafs_inode_t *shadow;
    struct cetrafs_stat_baseline base;
    cetrafs_inode_t *written;
    /* The in-core values the LAST mutate run merged from, and what the
     * merge made of them -- the adopt after a landed CAS works from
     * these, never from inside the CAS. Index: CETRAFS_FD_F_*. */
    u64 ours[4];
    u64 merged[4];
    u32 me;
    /* The image the swap landed on carried another node's stamp this
     * node had never seen -- see the end of the mutator. */
    bool overstamped;
    u64 overstamped_seq;
};

/* TEST ONLY: a stat publish forgets the peer stamp it overwrote (the
 * pre-fix behaviour). tests/kernel/stat_publish_peer_stamp.sh. */
static bool cetrafs_stat_publish_ignore_overstamp;
cetrafs_test_param(stat_publish_ignore_overstamp, cetrafs_stat_publish_ignore_overstamp, bool, 0644);
MODULE_PARM_DESC(stat_publish_ignore_overstamp, "TEST ONLY: a stat publish forgets the peer stamp it overwrote");

enum { CETRAFS_FD_F_SIZE, CETRAFS_FD_F_BLOCKS, CETRAFS_FD_F_ATIME, CETRAFS_FD_F_MTIME };

/*
 * The FILE-sector publish (CAS region 1). This is writeback's and
 * close's one record write, and the only path that ever persists a
 * regular file's size/blocks/times/extent-root outside truncate/defrag.
 * It cannot touch the namespace sector at all -- which is the whole
 * v0x0005 point: however stale this node's view, a peer's nlink delta,
 * lock claim or presence bit is physically out of reach.
 */
/* TEST ONLY, the stat-publish swap's refusal (tests/kernel/cas_refuses_bad_image_mutators.sh):
 * the next publish's mutator finds its image damaged -- the first reader
 * to see it, so no earlier reader refuses it -- and the control restamps
 * over the damage instead of refusing. */
static bool cetrafs_stat_mutate_damage_once;
cetrafs_test_param(stat_mutate_damage_once, cetrafs_stat_mutate_damage_once, bool, 0644);
MODULE_PARM_DESC(stat_mutate_damage_once, "TEST ONLY: the next stat publish's mutator finds its file sector damaged");
static bool cetrafs_stat_mutate_skip_crc;
cetrafs_test_param(stat_mutate_skip_crc, cetrafs_stat_mutate_skip_crc, bool, 0644);
MODULE_PARM_DESC(stat_mutate_skip_crc, "TEST ONLY: the stat publish's mutator restamps a file sector failing its checksum");

static int cetrafs_vfs_stat_cas_mutate(void *image, unsigned int len, void *priv)
{
    struct cetrafs_vfs_stat_cas_ctx *ctx = priv;
    struct inode *inode = ctx->inode;
    cetrafs_inode_t rec;

    if (len < CETRAFS_INODE_FD_BYTES)
        return -EINVAL;
    memset(&rec, 0, sizeof(rec));
    cetrafs_inode_fd_from_image(&rec, image);
    if (unlikely(READ_ONCE(cetrafs_stat_mutate_damage_once)) && xchg(&cetrafs_stat_mutate_damage_once, false))
        rec.fd_checksum ^= cpu_to_le64(1); /* TEST ONLY: damage in the mutator's own read */

    /* The fd sector's identity echo is this sector's reuse guard. */
    if (cetrafs_le64(rec.fd_generation) != ctx->generation || rec.fd_ino != ctx->ino_le)
        return -ESTALE;
    /* The merge below keeps the image's fields where ours did not move:
     * over a sector that fails its checksum, restamping blesses them
     * (the namespace mutator's refusal, cetrafs_ns_cas_mutate()). */
    if (cetrafs_inode_crc_fd(&rec) != (u32) cetrafs_le64(rec.fd_checksum) && !READ_ONCE(cetrafs_stat_mutate_skip_crc)) {
        pr_warn_ratelimited("stat publish on ino=%llu: the file sector on the device fails its checksum -- "
                            "refusing to stamp a fresh one\n",
                            (unsigned long long) inode->i_ino);
        return -EUCLEAN;
    }

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
     * the later.
     *
     * The merge does NOT write the result back into the in-core inode.
     * It used to, right here -- a value read from i_size a few
     * instructions earlier, stored back with no lock the write path
     * holds. An extending write landing in between was undone in core,
     * and the next publish carried the regressed size to the device:
     * the extent past it became a tail no size reaches (churn_oracle,
     * "SIZE MISMATCH", 2026-11-01; tests/kernel/stat_publish_size_race.sh).
     * cetrafs_vfs_stat_adopt() does it after the CAS lands, under the
     * lock each field's local writers hold. */
/* Times are signed seconds on disk: a time before 1970 is negative, and
 * as a u64 it won every max() -- "the later" was the earliest (audit
 * 2026-11-05, section 3; tests/kernel/merge_times_signed.sh). Sizes and
 * block counts compare unsigned. */
#define CETRAFS_FD_MERGE64(idx, field, ours_expr, is_time) \
    do {                                           \
        u64 ours = (u64) (ours_expr);              \
        u64 theirs, b, v;                          \
                                                   \
        if (cetrafs_fd_merge_stall_ms)             \
            mdelay(cetrafs_fd_merge_stall_ms);     \
        theirs = cetrafs_le64(rec.field);          \
        b = (u64) (ctx->base.field);               \
        v = theirs;                                \
        if (ours != b && theirs != b)              \
            v = (is_time) ? ((s64) ours > (s64) theirs ? ours : theirs) : max(ours, theirs); \
        else if (ours != b)                        \
            v = ours;                              \
        rec.field = cetrafs_cpu_to_le64(v);        \
        ctx->ours[idx] = ours;                     \
        ctx->merged[idx] = v;                      \
    } while (0)

    CETRAFS_FD_MERGE64(CETRAFS_FD_F_SIZE, size, i_size_read(inode), false);
    CETRAFS_FD_MERGE64(CETRAFS_FD_F_BLOCKS, blocks, inode->i_blocks, false);
    CETRAFS_FD_MERGE64(CETRAFS_FD_F_ATIME, atime, inode_get_atime_sec(inode), true);
    CETRAFS_FD_MERGE64(CETRAFS_FD_F_MTIME, mtime, inode_get_mtime_sec(inode), true);

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
    /* The restamp below replaces whatever stamp the device carries with
     * this node's. If that was ANOTHER node's, and not one this node
     * has seen, it was the only record of a change this node's caches
     * have not caught up with -- and afterwards every gate decoding
     * "stamp is mine" reads "my cache is current" over it (CLAUDE.md
     * rule 10). A stat-only publish reached from an fd, with no lookup
     * to re-read the record first, did exactly that: a reader held on
     * to a map a peer had changed. Remembered here, acted on once the
     * swap has landed. */
    {
        u64 dev = cetrafs_le64(rec.file_seq);

        ctx->overstamped = dev != cetrafs_inode_local_file_seq(inode) &&
                           CETRAFS_FILE_SEQ_NODE(dev) != (ctx->me & 0xFFFFu);
        ctx->overstamped_seq = dev;
    }
    cetrafs_inode_stamp_crc_fd(inode->i_sb, &rec);
    memcpy(ctx->written, &rec, sizeof(rec));
    cetrafs_inode_fd_to_image(image, &rec);
    return 0;
}

/*
 * After a landed stat publish: take into core what the merge brought in
 * from the device (a peer's size, blocks or times), and only that. A
 * field the merge left at the in-core value is not touched at all --
 * that store was the whole bug: a stale copy of i_size written back over
 * a concurrent extending write.
 *
 * Each adopt runs under the lock that field's local writers hold, as a
 * TRY: writeback cannot wait on them (fsync and close reach this with
 * inode_lock already held), and must not move a value someone changed
 * since the merge read it -- so it also requires the field to still be
 * what the merge read. All local i_size writers hold inode_lock
 * (write_end, truncate, fallocate, the O_DIRECT extension); i_blocks is
 * moved by get_block under the exclusive invalidate_lock (write_begin,
 * page_mkwrite, O_DIRECT, punch, defrag). Times: inode_lock covers
 * write(2)'s update; page_mkwrite's has no lock to take -- a second of
 * mtime, not data.
 *
 * A field NOT adopted keeps, as its baseline, the in-core value the
 * merge started from instead of the published one -- so the next merge
 * sees the device value as a change made elsewhere and keeps it (or the
 * max, for size/blocks), and never takes the in-core lag as a shrink.
 * That is done through 'written', which the caller then installs as the
 * baseline.
 */
static void cetrafs_vfs_stat_adopt(struct inode *inode, struct cetrafs_vfs_stat_cas_ctx *ctx)
{
    cetrafs_inode_t *w = ctx->written;
    bool need_ilock = false, need_blocks;
    bool have_ilock = false, have_inval = false;
    int i;

    for (i = 0; i < 4; i++)
        if (i != CETRAFS_FD_F_BLOCKS && ctx->merged[i] != ctx->ours[i])
            need_ilock = true;
    need_blocks = ctx->merged[CETRAFS_FD_F_BLOCKS] != ctx->ours[CETRAFS_FD_F_BLOCKS];

    if (need_ilock)
        have_ilock = inode_trylock(inode);
    if (need_blocks)
        have_inval = down_write_trylock(&inode->i_mapping->invalidate_lock);

    if (ctx->merged[CETRAFS_FD_F_SIZE] != ctx->ours[CETRAFS_FD_F_SIZE]) {
        /* Merged from a swap's image, not through the record reader's
         * size check -- so it is checked here too. */
        if (have_ilock && (u64) i_size_read(inode) == ctx->ours[CETRAFS_FD_F_SIZE] &&
            cetrafs_size_sane(ctx->merged[CETRAFS_FD_F_SIZE]))
            i_size_write(inode, (loff_t) ctx->merged[CETRAFS_FD_F_SIZE]);
        else
            w->size = cetrafs_cpu_to_le64(ctx->ours[CETRAFS_FD_F_SIZE]);
    }
    if (need_blocks) {
        if (have_inval && (u64) inode->i_blocks == ctx->ours[CETRAFS_FD_F_BLOCKS])
            inode->i_blocks = (blkcnt_t) ctx->merged[CETRAFS_FD_F_BLOCKS];
        else
            w->blocks = cetrafs_cpu_to_le64(ctx->ours[CETRAFS_FD_F_BLOCKS]);
    }
    if (ctx->merged[CETRAFS_FD_F_ATIME] != ctx->ours[CETRAFS_FD_F_ATIME]) {
        if (have_ilock && (u64) inode_get_atime_sec(inode) == ctx->ours[CETRAFS_FD_F_ATIME])
            inode_set_atime(inode, (time64_t) ctx->merged[CETRAFS_FD_F_ATIME], 0);
        else
            w->atime = cetrafs_cpu_to_le64(ctx->ours[CETRAFS_FD_F_ATIME]);
    }
    if (ctx->merged[CETRAFS_FD_F_MTIME] != ctx->ours[CETRAFS_FD_F_MTIME]) {
        if (have_ilock && (u64) inode_get_mtime_sec(inode) == ctx->ours[CETRAFS_FD_F_MTIME])
            inode_set_mtime(inode, (time64_t) ctx->merged[CETRAFS_FD_F_MTIME], 0);
        else
            w->mtime = cetrafs_cpu_to_le64(ctx->ours[CETRAFS_FD_F_MTIME]);
    }

    if (have_inval)
        up_write(&inode->i_mapping->invalidate_lock);
    if (have_ilock)
        inode_unlock(inode);
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
/* TEST ONLY: stall writeback's publish between its fresh record read and
 * everything it does with it. */
static unsigned int cetrafs_write_inode_read_stall_ms;
cetrafs_test_param(write_inode_read_stall_ms, cetrafs_write_inode_read_stall_ms, uint, 0644);
MODULE_PARM_DESC(write_inode_read_stall_ms, "TEST ONLY: widen the stat publish's read-to-adopt window");

int cetrafs_write_vfs_inode(struct inode *inode)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_vfs_stat_cas_ctx *ctx;
    cetrafs_inode_t *bufs; /* [0]=raw, [1]=shadow, [2]=written -- heap: 3 KiB of records */
    u32 my_node_id = 0;
    u64 fd_seq = 0;
    bool ilocked = false;
    int ret;

    bufs = kmalloc(3 * sizeof(*bufs), GFP_NOFS);
    ctx = kzalloc(sizeof(*ctx), GFP_NOFS);
    if (!bufs || !ctx) {
        kfree(bufs);
        kfree(ctx);
        return -ENOMEM;
    }

    /*
     * The namespace-domain fields this publish adopts below are moved
     * locally only by operations that hold this inode's inode_lock
     * (unlink/link/rmdir lock the victim, setattr runs under it, a
     * directory's own count moves under its lock as the parent). Taking
     * it BEFORE the fresh read makes the read include every one of them
     * that has completed and excludes any still in flight, so adopting
     * from it cannot put back a value one of them just changed. It
     * used to be adopted unlocked, from a read made before the stale-
     * owner check's I/O: an unlink in that gap had its nlink 0 put back
     * to 1 in core, evict then freed nothing, and the inode leaked
     * (tests/kernel/writeback_nlink_adopt.sh). TRY-lock: fsync and
     * close reach this holding it already, and writeback must never
     * wait on a writer -- without it the adopt is skipped, which only
     * delays seeing a peer's change.
     */
    ilocked = inode_trylock(inode);
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &bufs[0]);
    if (ret)
        goto out;
    if (cetrafs_write_inode_read_stall_ms)
        msleep(cetrafs_write_inode_read_stall_ms);

    if (cetrafs_le64(bufs[0].generation) != cetrafs_inode_get_generation(inode)) {
        ret = -ESTALE; /* dead object for a reused number -- nothing of ours to write */
        goto out;
    }

    /* Adopt the namespace-domain truth in core (never write it): nlink
     * is the accumulator only ns ops move; mode/uid/gid may have been
     * chmod/chowned by a peer. Only under the lock -- see above. (This
     * used to compare mode/uid/gid against the stat baseline first; the
     * baseline is installed from the file-sector image, whose namespace
     * fields are zero, so that compare had quietly stopped adopting
     * anything but a root owner's uid/gid.) A type change is never
     * adopted: apply() refuses it loudly, and this is no place for it. */
    if (ilocked) {
        if (((inode->i_mode ^ cetrafs_le32(bufs[0].mode)) & S_IFMT) == 0) {
            set_nlink(inode, cetrafs_le32(bufs[0].nlink));
            cetrafs_inode_adopt_identity(inode, &bufs[0]);
        }
        inode_unlock(inode);
        ilocked = false;
    }

    /* A record a LIVE other node holds exclusively locked is that node's
     * file domain to write -- our stat dirt predates its claim. */
    (void) cetrafs_sb_get_node_id(sb, &my_node_id);
    if (cetrafs_lock_mode_held(cetrafs_le32(bufs[0].lock_mode)) &&
        cetrafs_le32(bufs[0].lock_owner_node) != my_node_id) {
        bool stale = false;

        ret = cetrafs_node_is_stale(sb, cetrafs_le32(bufs[0].lock_owner_node), &stale);
        if (ret)
            goto out;
        if (!stale) {
            ret = 0; /* drop our dirt */
            goto out;
        }
    }

    {
        struct cetrafs_stat_baseline b;

        if (cetrafs_inode_stat_baseline_get(inode, &b)) {
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

    /* Snapshot-CAS-report runs under the per-inode publish mutex: a
     * rebuild path (truncate/punch/fallocate/defrag) publishing a fresh
     * tree and then freeing the old one must never interleave with this
     * CAS, or the pre-rebuild shadow lands on top of the fresh tree and
     * the device ends up referencing freed blocks. */
    cetrafs_inode_fd_pub_lock(inode);
    ctx->have_shadow = cetrafs_inode_fd_take(inode, &bufs[1], &fd_seq);

    /* The shadow carries this file's hot-path extents, and this CAS is
     * what publishes them: rule 8's flush belongs here exactly as in
     * cetrafs_write_raw_inode_fd(). This path used to have none, so it
     * was the one that published blocks whose bits never reached the
     * device -- every close and every writeback reaches it, and a fsync
     * that saw the flush fail went on to publish through it anyway
     * (tests/kernel/bitmap_flush_error.sh). After the take, so it covers
     * every allocation the shadow names; take does not clear the shadow,
     * so refusing leaves it pending for the next boundary. */
    if (ctx->have_shadow) {
        ret = cetrafs_alloc_flush_bitmaps(sb);
        /* Durably, before the extents that name them are published --
         * writeback reaches here with no close or fsync around it. */
        if (!ret)
            ret = cetrafs_publish_flush(sb);
        if (ret)
            goto out_pub;
    }

    /* Nothing to publish? A no-op CAS still costs a device round trip
     * (and showed up as "a punch that frees nothing published 10 record
     * writes" -- the VFS dirties the inode for timestamps the merge then
     * finds unchanged). Skip when there is no shadow and every merged
     * field already matches the baseline this node last published. */
    /* Inside an fdatasync's scope (file.c cetrafs_sync_inode_meta()) the
     * times are not part of what the datasync promises, so time-only dirt
     * is left unpublished here and the scope re-dirties the inode after
     * the VFS clears it. The stat baseline keeps the old times. The skip
     * is only ever taken with no shadow and unchanged size and blocks:
     * every extent change to a regular file is either staged in the
     * shadow (cetrafs_inode_fd_stage) or published synchronously by its
     * own _fd publisher, so nothing this datasync must make durable can
     * be waiting behind this skip. */
    if (!ctx->have_shadow && (u64) i_size_read(inode) == ctx->base.size && (u64) inode->i_blocks == ctx->base.blocks) {
        bool times_same = (u64) inode_get_atime_sec(inode) == ctx->base.atime &&
                          (u64) inode_get_mtime_sec(inode) == ctx->base.mtime;

        if (times_same || cetrafs_dsync_drop_times(inode)) {
            ret = 0;
            goto out_pub;
        }
    }

    ctx->me = my_node_id;
    ret = cetrafs_cas_record_fd_seeded(sb, cetrafs_inode_lba(sb, inode->i_ino),
                                       (const u8 *) &bufs[0] + CETRAFS_INODE_FD_OFF, CETRAFS_INODE_FD_LIVE,
                                       cetrafs_vfs_stat_cas_mutate, ctx);
    ctrace("FDPUB ino=%llu ret=%d shadow=%d blocks=%llu size=%llu seq=%llx\n", (unsigned long long) inode->i_ino,
           ret, (int) ctx->have_shadow, (unsigned long long) (ret == 0 ? cetrafs_le64(ctx->written->blocks) : 0),
           (unsigned long long) (ret == 0 ? cetrafs_le64(ctx->written->size) : 0),
           (unsigned long long) (ret == 0 ? cetrafs_le64(ctx->written->file_seq) : 0));
    if (ret == 0) {
        /* Landed: the state through fd_seq is durable. Anything staged
         * DURING the CAS bumped the seq and keeps the dirty flag -- the
         * old protocol cleared it at take time, and a get_block in this
         * window then rebuilt its tree from the lagging device record,
         * leaking every extent in flight (the ~15k-blocks-per-fill
         * leak, 2026-10-27). */
        cetrafs_inode_fd_published(inode, fd_seq);
        cetrafs_record_write_counted();
        cetrafs_vfs_stat_adopt(inode, ctx); /* may point 'written' fields back at core: baseline only */
        cetrafs_inode_stat_baseline_set(inode, ctx->written);
        /* Adopt what we just stamped. The decode in lock.c already stops
         * this node mistaking its own publish for a peer's; this keeps
         * the cached value exact so the common path never even has to
         * ask. */
        cetrafs_inode_note_local_file_seq(inode, cetrafs_le64(ctx->written->file_seq));
        /* ...unless it overwrote a peer's change we never saw: then do
         * what seeing it would have done, after the adopt above so the
         * cold mark is the last word. */
        if (ctx->overstamped && !cetrafs_stat_publish_ignore_overstamp) {
            pr_info_ratelimited("cetrafs: inode %llu: stat publish overwrote stamp %llx from node %u -- "
                                "refetching this node's extent map\n",
                                (unsigned long long) inode->i_ino, (unsigned long long) ctx->overstamped_seq,
                                (unsigned) CETRAFS_FILE_SEQ_NODE(ctx->overstamped_seq));
            cetrafs_inode_mark_tree_cold(inode);
        }
    }
    /* A failed publish needs no re-stage: take no longer clears the
     * shadow, so the pending state simply stays dirty for the next
     * boundary. */
    if (ret == -ESTALE) {
        /* Reused number: our dirt is for a dead file -- dropped by
         * design, including the shadow. */
        cetrafs_inode_fd_published(inode, fd_seq);
        ret = 0;
    }

out_pub:
    cetrafs_inode_fd_pub_unlock(inode);
out:
    if (ilocked)
        inode_unlock(inode);
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

/*
 * 'reader': the caller only READS through this block -- it maps a block
 * to serve a read and will write nothing on the strength of it -- so
 * the cache trust question is cetrafs_lock_read_cache_trusted()'s, not
 * the write lock's. See that function for why the two differ.
 */
struct buffer_head *cetrafs_read_tree_bh_for(struct inode *inode, u64 lba, u32 tail_magic, const char *what, bool reader)
{
    int chk;

    atomic64_inc(&cetrafs_tree_reads);

    /* ei_leaf_hi/lo is an address read off the device, exactly like the
     * ee_start the data path refuses in cetrafs_tree_lookup(). These
     * blocks are not only read: the extent-tree writers journal them
     * and write them back, so a leaf pointer aimed at the inode table
     * puts a tree update there. Checked at the one place both the leaf
     * and the interior reader funnel through. */
    chk = cetrafs_lba_run_check(inode->i_sb, lba, 1);
    if (chk == -EAGAIN)
        return NULL; /* past a layout this node cannot catch up with: refused, not damage */
    if (chk) {
        pr_err_ratelimited("ino=%llu: %s block %llu is not a data address -- refusing it (fsck)\n",
                           (unsigned long long) inode->i_ino, what, (unsigned long long) lba);
        cetrafs_sb_corrupt_inode(inode);
        return NULL;
    }

    /* Holding the file's exclusive lock means no peer can be rewriting
     * this tree, so the cached copy is authoritative AND cannot be
     * torn -- this is the growing-file hot path and must stay off the
     * wire. */
    if (reader ? cetrafs_lock_read_cache_trusted(inode) : cetrafs_lock_held_for_write_locally(inode)) {
        /* Cached, but still CHECKED for sense. The cached branch skips
         * the tail verification because nobody else can be mid-write --
         * which is an argument about CONCURRENCY and says nothing about
         * whether the block makes sense. The counts in this header are
         * indexed with, so a hostile or damaged one is an out-of-bounds
         * access however exclusively we hold the file. One comparison,
         * and this is the per-block mapping path. */
        struct buffer_head *bh = sb_getblk(inode->i_sb, lba);

        /* Trusting the cache is a statement about what is IN it. A block
         * that is not there yet is coming off the device, and that read
         * is where its tail checksum gets checked -- whoever is asking.
         * Skipping it here let a reader that trusts its cache parse a
         * corrupt leaf (blk_tail_checksum.sh), and had always let a
         * writer do the same on a cache miss. */
        if (bh && !buffer_uptodate(bh)) {
            brelse(bh);
            return cetrafs_blk_tail_bread(inode->i_sb, lba, tail_magic, what);
        }
        if (bh && !cetrafs_blk_struct_ok_magic(bh, tail_magic)) {
            pr_err_ratelimited("ino=%llu: %s block %llu has an impossible entry count -- refusing it\n",
                               (unsigned long long) inode->i_ino, what, (unsigned long long) lba);
            cetrafs_sb_corrupt_inode(inode);
            brelse(bh);
            return NULL;
        }
        return bh;
    }

    /* Without it, a peer may be mid-write. A DIRECTORY is always in
     * this case: it never holds a file lock, so every peer walking a
     * spilled directory reads its leaf unsynchronised. Verify the tail
     * and retry a mismatch, which is a torn write far more often than
     * it is corruption. */
    return cetrafs_blk_tail_bread(inode->i_sb, lba, tail_magic, what);
}

struct buffer_head *cetrafs_read_tree_bh(struct inode *inode, u64 lba, u32 tail_magic, const char *what)
{
    return cetrafs_read_tree_bh_for(inode, lba, tail_magic, what, false);
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
    /* dir.c reaches a leaf through here rather than through
     * cetrafs_read_tree_bh(), so the address check has to be repeated:
     * a subsystem with its own reader is exactly how a check added at
     * "the" choke point misses the blocks it was written for. */
    int chk = cetrafs_lba_run_check(inode->i_sb, lba, 1);

    if (chk == -EAGAIN)
        return NULL; /* past a layout this node cannot catch up with: refused, not damage */
    if (chk) {
        pr_err_ratelimited("dir ino=%llu: extent leaf %llu is not a data address -- refusing it (fsck)\n",
                           (unsigned long long) inode->i_ino, (unsigned long long) lba);
        cetrafs_sb_corrupt_inode(inode);
        return NULL;
    }

    if (!fresh) {
        /* Same as the file path above: unchanged-since-we-last-read is
         * not the same as sane, and a block not in the cache yet is
         * coming off the device -- verify it there. */
        struct buffer_head *bh = sb_getblk(inode->i_sb, lba);

        if (bh && !buffer_uptodate(bh)) {
            brelse(bh);
            return cetrafs_blk_tail_bread(inode->i_sb, lba, CETRAFS_LEAF_TAIL_MAGIC, "extent leaf");
        }
        if (bh && !cetrafs_blk_struct_ok_magic(bh, CETRAFS_LEAF_TAIL_MAGIC)) {
            pr_err_ratelimited("dir ino=%llu: extent leaf %llu has an impossible entry count -- refusing it\n",
                               (unsigned long long) inode->i_ino, (unsigned long long) lba);
            cetrafs_sb_corrupt_inode(inode);
            brelse(bh);
            return NULL;
        }
        return bh;
    }
    return cetrafs_blk_tail_bread(inode->i_sb, lba, CETRAFS_LEAF_TAIL_MAGIC, "extent leaf");
}

/* v2: an interior index block, same freshness rules, its own tail magic
 * so a block of the wrong KIND is caught rather than mis-parsed. */
struct buffer_head *cetrafs_read_index_bh(struct inode *inode, u64 lba)
{
    return cetrafs_read_tree_bh(inode, lba, CETRAFS_INDEX_TAIL_MAGIC, "extent index");
}

/* The read-path variants: see cetrafs_read_tree_bh_for(). */
struct buffer_head *cetrafs_read_leaf_bh_for(struct inode *inode, u64 lba, bool reader)
{
    return cetrafs_read_tree_bh_for(inode, lba, CETRAFS_LEAF_TAIL_MAGIC, "extent leaf", reader);
}

struct buffer_head *cetrafs_read_index_bh_for(struct inode *inode, u64 lba, bool reader)
{
    return cetrafs_read_tree_bh_for(inode, lba, CETRAFS_INDEX_TAIL_MAGIC, "extent index", reader);
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
/*
 * A stopped mount answers no question about a file -- its cached
 * attributes describe a file a peer may own by now
 * (docs/internal/ERRORS.md). Unmount does not ask, so it still works.
 */
int cetrafs_getattr(struct mnt_idmap *idmap, const struct path *path, struct kstat *stat, u32 request_mask,
                    unsigned int query_flags)
{
    struct inode *inode = d_inode(path->dentry);

    (void) query_flags;
    if (cetrafs_sb_is_fenced(inode->i_sb))
        return -EIO;
    generic_fillattr(idmap, request_mask, inode, stat);
    return 0;
}

static const char *cetrafs_get_link(struct dentry *dentry, struct inode *inode, struct delayed_call *done)
{
    if (cetrafs_sb_is_fenced(inode->i_sb))
        return ERR_PTR(-EIO);
    return page_get_link(dentry, inode, done);
}

const struct inode_operations cetrafs_symlink_iops = {
    .get_link = cetrafs_get_link,
    .setattr = cetrafs_setattr,
    .getattr = cetrafs_getattr,
    /* A link carries xattrs too (trusted.*, security.*). Without this the
     * VFS lists only the security module's, and cp -a / rsync -X, which
     * list before they copy, dropped the rest. */
    .listxattr = cetrafs_listxattr,
};

/* TEST ONLY: stall a refresh between its "no local changes" verdict and
 * the stores that act on it, so a test can land a local write there. */
static unsigned int cetrafs_apply_refresh_stall_ms;
cetrafs_test_param(apply_refresh_stall_ms, cetrafs_apply_refresh_stall_ms, uint, 0644);
MODULE_PARM_DESC(apply_refresh_stall_ms, "TEST ONLY: widen a refresh's dirty-check-to-store window");

/*
 * Does this node hold state for the inode that the device does not have
 * yet? An extent shadow not yet published, or a file-domain stat field
 * that differs from the baseline -- the record as this node last read
 * or stamped it. No baseline means no answer, which counts as yes.
 *
 * The fields are exactly the ones writeback's own "nothing to publish"
 * test compares (cetrafs_write_vfs_inode()): size, blocks, atime and
 * mtime are what a dirty inode can carry unpublished. The namespace
 * fields are not deferred -- chmod, chown and link-count changes write
 * their sector before they return -- and the baseline is installed from
 * the file-sector image, where they read as zero.
 *
 * Called with inode_lock and invalidate_lock held, which every local
 * writer of these fields holds too.
 */
static bool cetrafs_inode_has_unpublished_state(struct inode *inode)
{
    struct cetrafs_stat_baseline b;

    if (cetrafs_inode_fd_dirty(inode))
        return true;
    if (!cetrafs_inode_stat_baseline_get(inode, &b))
        return true;
    return b.size != (u64) i_size_read(inode) || b.blocks != (u64) inode->i_blocks ||
           b.atime != (u64) inode_get_atime_sec(inode) || b.mtime != (u64) inode_get_mtime_sec(inode);
}

/* TEST ONLY: the next apply loses its inode_lock trylock, as it does to
 * a local writer retrying -ETXTBSY. tests/kernel/lock_resume_reconcile.sh. */
static bool cetrafs_apply_trylock_fail_once;
cetrafs_test_param(apply_trylock_fail_once, cetrafs_apply_trylock_fail_once, bool, 0644);
MODULE_PARM_DESC(apply_trylock_fail_once, "TEST ONLY: the next refresh apply finds the inode lock contended");

/* Why an apply that returned 0 applied nothing. */
enum cetrafs_apply_decline {
    CETRAFS_APPLY_DONE = 0,
    CETRAFS_APPLY_CONTENDED, /* a trylock failed: someone held the lock for a moment */
    CETRAFS_APPLY_LOCAL,     /* this node holds state the device does not have */
};

static int __cetrafs_apply_raw_to_vfs_inode(struct inode *inode, const cetrafs_inode_t *raw,
                                            enum cetrafs_apply_decline *why, bool pub_held, u64 epoch);

/*
 * An LSM's cached inode label (class 42's sibling of S_NOSEC). A peer's
 * setxattr of security.* reaches this node as a record refresh, which
 * goes through none of the VFS paths that tell the LSM, so the label it
 * cached -- and enforces -- stayed the old one. The record has no xattr
 * stamp; a setxattr moves ctime, in SECONDS. So the label is dropped
 * when ctime moved, and also once more after a refresh made while
 * ctime's second could still produce a change (seen no later than
 * ctime + 1): a second change in the same second leaves ctime equal.
 * Caller holds inode_lock.
 */
static atomic64_t cetrafs_label_invalidations = ATOMIC64_INIT(0);

u64 cetrafs_label_invalidation_count(void)
{
    return (u64) atomic64_read(&cetrafs_label_invalidations);
}

static bool cetrafs_inode_label_may_be_stale(struct inode *inode, const cetrafs_inode_t *raw)
{
    time64_t ctime = (time64_t) cetrafs_le64(raw->ctime);
    time64_t now = ktime_get_real_seconds();
    time64_t *seen_at = cetrafs_inode_label_seen_at(inode);
    bool stale = inode_get_ctime(inode).tv_sec != ctime || *seen_at <= ctime + 1;

    *seen_at = now;
    return stale;
}

int cetrafs_apply_raw_to_vfs_inode(struct inode *inode, const cetrafs_inode_t *raw)
{
    enum cetrafs_apply_decline why;

    return __cetrafs_apply_raw_to_vfs_inode(inode, raw, &why, false, CETRAFS_REC_EPOCH_NONE);
}

/* The refresh's apply: the caller holds fd_pub_mutex and sampled the
 * record's publish epoch before its read (cetrafs_rec_epoch_sample()). */
static int cetrafs_apply_raw_to_vfs_inode_sampled(struct inode *inode, const cetrafs_inode_t *raw, u64 epoch)
{
    enum cetrafs_apply_decline why;

    return __cetrafs_apply_raw_to_vfs_inode(inode, raw, &why, true, epoch);
}

/*
 * The apply for a boundary that must NOT proceed on the old view: an
 * open that found a peer's record, a lock resume, the defrag pin. The
 * plain apply declines in silence when it loses a trylock -- right for
 * d_revalidate, which asks again on the next lookup, and wrong here,
 * where the caller goes on to trust its cache. A resume's own local
 * writer, retrying -ETXTBSY, takes inode_lock for a moment on every
 * retry, so losing that trylock is not rare; and the caller then let
 * the writer in on the pre-handoff i_size.
 *
 * So a contended apply is retried, bounded and killable; a decline for
 * local state the device does not have is -EBUSY, and so is running out
 * of retries. The caller fails the boundary rather than proceeding.
 */
int cetrafs_apply_raw_to_vfs_inode_sure(struct inode *inode, const cetrafs_inode_t *raw)
{
    int attempt;

    for (attempt = 0; attempt < 400; attempt++) {
        enum cetrafs_apply_decline why;
        int ret = __cetrafs_apply_raw_to_vfs_inode(inode, raw, &why, false, CETRAFS_REC_EPOCH_NONE);

        if (ret)
            return ret;
        if (why == CETRAFS_APPLY_DONE)
            return 0;
        if (why == CETRAFS_APPLY_LOCAL)
            return -EBUSY;
        if (fatal_signal_pending(current))
            return -EINTR;
        usleep_range(200, 500);
    }
    pr_warn_ratelimited("ino=%llu: refresh could not take the inode's locks -- refusing\n",
                        (unsigned long long) inode->i_ino);
    return -EBUSY;
}

/* TEST ONLY: apply the record as the caller read it -- no publish
 * mutex, no re-read when a local publish may have landed behind the
 * read. The negative control for
 * tests/kernel/refresh_ns_publish.sh. */
static bool cetrafs_refresh_ns_unguarded;
cetrafs_test_param(refresh_ns_unguarded, cetrafs_refresh_ns_unguarded, bool, 0644);
MODULE_PARM_DESC(refresh_ns_unguarded, "TEST ONLY: a refresh applies its read over a local namespace publish");

static atomic64_t cetrafs_refresh_ns_rereads = ATOMIC64_INIT(0);

u64 cetrafs_refresh_ns_reread_count(void)
{
    return (u64) atomic64_read(&cetrafs_refresh_ns_rereads);
}

/*
 * Make the namespace half of *raw the record as the device holds it NOW,
 * for a caller holding every lock a local publisher of in-core state
 * holds (BUG-CLASSES class 29). The caller's read may predate a local
 * publish: chmod, link, setxattr, a rename's ctime -- each swaps the
 * record and then sets the same field in core, and applying the older
 * read afterwards put the in-core field back to a value the device no
 * longer holds. While this node keeps the file open for write it is
 * never refreshed again, so the revert stays.
 *
 * Every such publisher holds inode_lock, or fd_pub_mutex where the VFS
 * does not lock the inode (a directory renamed inside one parent), from
 * its swap to its in-core store; the apply holds both. A namespace
 * update STAGED for the namespace lock's release is no exception: the
 * release runs inside the operation, under the VFS's lock of every
 * inode it stages on (parents, the unlink/rmdir victim). So by the time
 * the apply has its locks, every local publish has landed -- and one
 * that landed after the caller's read moved the epoch it sampled
 * (cetrafs_rec_epoch_bump()): then re-read, and take the namespace
 * sector from the device. The file sector stays the caller's, judged by
 * file_seq (cetrafs_refresh_settle()). A caller with no sample
 * (CETRAFS_REC_EPOCH_NONE) always re-reads.
 */
static int cetrafs_apply_settle_ns(struct inode *inode, cetrafs_inode_t *raw, u64 epoch)
{
    cetrafs_inode_t *now;
    int ret;

    if (READ_ONCE(cetrafs_refresh_ns_unguarded))
        return 0; /* TEST ONLY: see the knob */
    if (epoch != CETRAFS_REC_EPOCH_NONE && cetrafs_rec_epoch_sample(inode->i_sb, inode->i_ino) == epoch)
        return 0;

    now = kmalloc(sizeof(*now), GFP_NOFS);
    if (!now)
        return -ENOMEM;
    atomic64_inc(&cetrafs_refresh_ns_rereads);
    cetrafs_invalidate_raw_inode(inode->i_sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(inode->i_sb, inode->i_ino, now);
    if (!ret)
        memcpy(raw, now, CETRAFS_INODE_NS_BYTES);
    kfree(now);
    return ret;
}

/* Is 'raw' still a record of THIS file, of the same type, that the
 * namespace still has? Run on every record an apply would store. */
static int cetrafs_apply_identity_check(struct inode *inode, const cetrafs_inode_t *raw)
{
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
    if (cetrafs_le32(raw->nlink) == 0)
        return -ESTALE;

    if (((inode->i_mode ^ cetrafs_le32(raw->mode)) & S_IFMT) != 0) {
        pr_err("ino=%llu: refusing a refresh that would change its type (0%o -> 0%o) with the same generation\n",
               (unsigned long long) inode->i_ino, inode->i_mode & S_IFMT, cetrafs_le32(raw->mode) & S_IFMT);
        cetrafs_sb_corrupt_inode(inode);
        return -EUCLEAN;
    }
    return 0;
}

static int __cetrafs_apply_raw_to_vfs_inode(struct inode *inode, const cetrafs_inode_t *in,
                                            enum cetrafs_apply_decline *why, bool pub_held, u64 epoch)
{
    cetrafs_inode_t *raw;
    bool label_stale;
    bool pub = false;
    int ret;
    bool dirty;

    *why = CETRAFS_APPLY_DONE;

    raw = kmalloc(sizeof(*raw), GFP_NOFS);
    if (!raw)
        return -ENOMEM;
    memcpy(raw, in, sizeof(*raw));
    ret = cetrafs_apply_identity_check(inode, raw);
    if (ret)
        goto out_free;

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
     *
     * And the verdict must still hold when the stores land. Checked
     * bare, it did not: an extending write sets i_size and only THEN
     * dirties the inode, so a refresh judging "clean" in between -- or
     * just before the write -- went on to store the device's older
     * size over it (tests/kernel/refresh_vs_local_write.sh: 20 of 20
     * rounds, 2026-11-01). The check and the stores therefore run
     * under the locks the local writers of these fields hold:
     * inode_lock (write(2), truncate, fallocate, setattr) and the
     * exclusive invalidate_lock (get_block's i_blocks from a page
     * fault). Both are TRY-locks -- callers reach this from
     * d_revalidate and open with fd_pub_mutex held, which ranks below
     * both -- and a lock someone holds means a local writer is active:
     * decline, exactly as for a dirty inode.
     */
    if (cetrafs_apply_trylock_fail_once) {
        cetrafs_apply_trylock_fail_once = false; /* TEST ONLY */
        *why = CETRAFS_APPLY_CONTENDED;
        goto out_free;
    }
    /* fd_pub_mutex too, which a publisher holding no inode_lock holds
     * across its swap and its in-core store (cetrafs_apply_settle_ns()).
     * Taken first and blocking: it is a leaf, and ranks below both. */
    if (!pub_held && !READ_ONCE(cetrafs_refresh_ns_unguarded)) {
        cetrafs_inode_fd_pub_lock(inode);
        pub = true;
    }
    if (!inode_trylock(inode)) {
        *why = CETRAFS_APPLY_CONTENDED;
        goto out_pub;
    }
    if (!down_write_trylock(&inode->i_mapping->invalidate_lock)) {
        inode_unlock(inode);
        *why = CETRAFS_APPLY_CONTENDED;
        goto out_pub;
    }
    spin_lock(&inode->i_lock);
    dirty = (inode_state_read(inode) & I_DIRTY_ALL) != 0;
    spin_unlock(&inode->i_lock);
    /*
     * The VFS dirty flag alone over-answers. Close publishes the record
     * through a CAS of its own and leaves the flag set until writeback's
     * ->write_inode runs, ~30 s later -- so a peer that opened, extended
     * and closed inside that window was declined here, silently, and
     * this node reopened holding its own old i_size and cached tree. An
     * append then landed at the stale end of file over the peer's data
     * (tests/kernel/refresh_after_own_close.sh). What the guard is for is
     * state this node has NOT published: an extent shadow still staged,
     * or a stat field that differs from what this node last saw on the
     * device or put there (the stat baseline).
     */
    if (dirty && !cetrafs_inode_has_unpublished_state(inode))
        dirty = false;
    if (dirty) {
        *why = CETRAFS_APPLY_LOCAL;
        goto out_unlock;
    }
    if (cetrafs_apply_refresh_stall_ms && S_ISREG(inode->i_mode))
        msleep(cetrafs_apply_refresh_stall_ms);

    /* The namespace half as the device holds it now (BUG-CLASSES class
     * 29), judged again: the re-read may say the file is gone. */
    ret = cetrafs_apply_settle_ns(inode, raw, epoch);
    if (!ret)
        ret = cetrafs_apply_identity_check(inode, raw);
    if (ret)
        goto out_unlock;

    label_stale = cetrafs_inode_label_may_be_stale(inode, raw);
    cetrafs_inode_adopt_identity(inode, raw);
    set_nlink(inode, cetrafs_le32(raw->nlink));
    i_size_write(inode, cetrafs_le64(raw->size));
    inode->i_blocks = cetrafs_le64(raw->blocks);
    inode_set_atime(inode, (time64_t) cetrafs_le64(raw->atime), 0);
    inode_set_mtime(inode, (time64_t) cetrafs_le64(raw->mtime), 0);
    inode_set_ctime(inode, (time64_t) cetrafs_le64(raw->ctime), 0);
    cetrafs_inode_stat_baseline_set(inode, raw);
    up_write(&inode->i_mapping->invalidate_lock);
    inode_unlock(inode);
    if (pub)
        cetrafs_inode_fd_pub_unlock(inode);
    pub = false;
    if (label_stale) {
        /* A labelling LSM (SELinux, Smack) re-reads security.* on next
         * use; with none, the hook does nothing. */
        security_inode_invalidate_secctx(inode);
        atomic64_inc(&cetrafs_label_invalidations);
    }

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

    /* The same goes for the tree a READER maps through: it trusts its
     * cached leaves on the strength of file_seq alone
     * (cetrafs_lock_read_cache_trusted()), and this record is the
     * device's word that the file may have changed. Cold sends its reads
     * fresh until the reconcile -- which runs where buffers may be
     * dropped -- has thrown the old tree away. */
    if (S_ISREG(inode->i_mode))
        cetrafs_inode_mark_tree_cold(inode);

    ret = invalidate_inode_pages2(inode->i_mapping);
    if (ret)
        pr_warn("ino=%llu could not fully drop stale page cache on refresh: %d\n", (unsigned long long) inode->i_ino,
                ret);
    ret = 0;
    goto out_free;

out_unlock:
    up_write(&inode->i_mapping->invalidate_lock);
    inode_unlock(inode);
out_pub:
    if (pub)
        cetrafs_inode_fd_pub_unlock(inode);
out_free:
    kfree(raw);
    return ret;
}

/* TEST ONLY: hold a refresh between its first read and its verdict, with
 * the publish mutex held. A publisher that takes no mutex (the directory
 * nslock release) can land a publish inside that window.
 * tests/kernel/refresh_superseded_own_seq.sh. */
static unsigned int cetrafs_refresh_compare_stall_ms;
cetrafs_test_param(refresh_compare_stall_ms, cetrafs_refresh_compare_stall_ms, uint, 0644);
MODULE_PARM_DESC(refresh_compare_stall_ms, "TEST ONLY: stall a refresh between its read and its verdict (ms)");

/* TEST ONLY: judge a superseded own stamp by the old age compare, with no
 * re-read -- the negative control for tests/kernel/refresh_superseded_own_seq.sh. */
static bool cetrafs_refresh_seq_age_compare;
cetrafs_test_param(refresh_seq_age_compare, cetrafs_refresh_seq_age_compare, bool, 0644);
MODULE_PARM_DESC(refresh_seq_age_compare, "TEST ONLY: judge own stamps by the old age compare (no re-read)");

/* Module-wide refresh counters, read through procfs info. */
static atomic64_t cetrafs_refresh_stalls = ATOMIC64_INIT(0);
static atomic64_t cetrafs_refresh_candidates = ATOMIC64_INIT(0);
static atomic64_t cetrafs_refresh_refused = ATOMIC64_INIT(0);

void cetrafs_refresh_counters(u64 *stalls, u64 *candidates, u64 *refused)
{
    *stalls = (u64) atomic64_read(&cetrafs_refresh_stalls);
    *candidates = (u64) atomic64_read(&cetrafs_refresh_candidates);
    *refused = (u64) atomic64_read(&cetrafs_refresh_refused);
}

/* Re-reads a settle makes before it gives up and refuses. */
#define CETRAFS_REFRESH_SETTLE_TRIES 4

/* TEST ONLY: a settle's re-read never agrees, so every settle runs out
 * of tries and refuses -- the refuse path, with the knob off as the
 * comparison (tests/kernel/refresh_settle_refuse.sh). */
static bool cetrafs_refresh_settle_churn;
cetrafs_test_param(refresh_settle_churn, cetrafs_refresh_settle_churn, bool, 0644);
MODULE_PARM_DESC(refresh_settle_churn, "TEST ONLY: a settle's re-read never agrees, so it refuses");

/*
 * Settle a record read under the publish mutex that carries this node's
 * OWN file_seq, when that stamp is not the one our last publish noted.
 *
 * How a read gets superseded: a publisher that took no fd_pub_mutex --
 * the directory's nslock release did, before it was brought under the
 * mutex -- could land between this read and the verdict, then note its
 * stamp, so the note moved on while the read still showed the record
 * before that publish. Applying the read reverted in-core state to a
 * record the device no longer held. Every file-sector publisher now
 * holds the mutex; this settle stays as defence in depth.
 *
 * Why a re-read settles it: a note is only taken AFTER its publish has
 * landed, and every publish stamps a seq no other write carries. So read
 * the note (n1), re-read the record, read the note again (n2). If n1 == n2
 * and the re-read carries the seq of the first read, no publish landed
 * between them, and the first read stands. Otherwise the first read is
 * superseded: continue with the re-read, judged the same way. Nothing is
 * ordered by age here -- stamps wrap, and a stamp from before a wrap can
 * look newer than a note.
 *
 * What makes the last step safe: the caller holds fd_pub_mutex from its
 * read to the apply, and every publisher of the file sector holds it
 * across its CAS and its note (BUG-CLASSES.md class 29). So no publish
 * can land between the last n2 read and the apply. The re-read is kept
 * as defence in depth for a publisher that is missing from that list.
 *
 * Returns 1 to apply *cur, 0 to refuse (in-core stays; the next refresh
 * retries), or a negative errno from the re-read.
 */
static int cetrafs_refresh_settle(struct inode *inode, cetrafs_inode_t *cur)
{
    struct super_block *sb = inode->i_sb;
    u64 ino = inode->i_ino;
    u32 me = 0;
    int try;

    if (cetrafs_sb_get_node_id(sb, &me))
        return 1; /* no node id: nothing here can be ours to judge */
    me &= 0xFFFFu;

    for (try = 0; try < CETRAFS_REFRESH_SETTLE_TRIES; try++) {
        u64 seq = cetrafs_le64(cur->file_seq);
        u64 n1 = cetrafs_inode_local_file_seq(inode);
        u64 n2;
        cetrafs_inode_t nxt;
        int ret;

        /* Not ours, the note itself, or the note is foreign: nothing we
         * published can be superseded. U64_MAX (no note yet) is still a
         * candidate: a publish can land before its note does. */
        if (CETRAFS_FILE_SEQ_NODE(seq) != me || seq == n1 ||
            (n1 != U64_MAX && CETRAFS_FILE_SEQ_NODE(n1) != me))
            return 1;

        atomic64_inc(&cetrafs_refresh_candidates);
        if (READ_ONCE(cetrafs_refresh_seq_age_compare)) {
            /* TEST ONLY control: the old verdict, age-ordered, no re-read. */
            if (n1 != U64_MAX && cetrafs_sb_own_seq_older(sb, seq, n1, cetrafs_inode_local_file_seq_at(inode))) {
                atomic64_inc(&cetrafs_refresh_refused);
                return 0;
            }
            return 1;
        }

        cetrafs_invalidate_raw_inode(sb, ino);
        ret = cetrafs_read_raw_inode(sb, ino, &nxt);
        if (ret)
            return ret;
        n2 = cetrafs_inode_local_file_seq(inode);
        if (n1 == n2 && cetrafs_le64(nxt.file_seq) == seq && !READ_ONCE(cetrafs_refresh_settle_churn))
            return 1;
        *cur = nxt;
    }
    atomic64_inc(&cetrafs_refresh_refused);
    return 0;
}

/* v0x0008 reuse detection: a different generation means this is not the
 * same file this object was instantiated from -- a peer deleted it and
 * reused the number. Refreshing stat fields onto an object wearing the
 * OLD file's i_op/i_fop would type-confuse the VFS. Unhash the stale
 * object so the next iget instantiates a fresh one. */
static int cetrafs_refresh_reuse_check(struct inode *inode, const cetrafs_inode_t *raw)
{
    if (cetrafs_inode_get_generation(inode) == cetrafs_le64(raw->generation))
        return 0;
    remove_inode_hash(inode);
    return -ESTALE;
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
    u64 epoch;
    int ret;

    /* IDENTITY, not content -- see cetrafs_lock_identity_cache_trusted().
     * This gate also guards the generation check below, so it must not
     * be satisfied by a file nobody has open. */
    if (cetrafs_lock_identity_cache_trusted(inode))
        return 0;

    /* Read AND stamp under the publish mutex: the publisher holds it
     * across its CAS and its note of the stamped seq, so this refresh
     * runs either entirely before the publish or entirely after it: every
     * publisher of the file sector takes it (BUG-CLASSES class 29). The
     * settle below is defence in depth for a publisher that does not. */
    cetrafs_inode_fd_pub_lock(inode);
    /* Before the read: a namespace publish landing behind it moves this,
     * and the apply re-reads (cetrafs_apply_settle_ns()). */
    epoch = cetrafs_rec_epoch_sample(sb, inode->i_ino);
    cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    ret = cetrafs_read_raw_inode(sb, inode->i_ino, &raw);
    if (ret) {
        cetrafs_inode_fd_pub_unlock(inode);
        return ret;
    }
    if (cetrafs_refresh_reuse_check(inode, &raw)) {
        cetrafs_inode_fd_pub_unlock(inode);
        return -ESTALE;
    }

    if (unlikely(READ_ONCE(cetrafs_refresh_compare_stall_ms))) {
        atomic64_inc(&cetrafs_refresh_stalls);
        msleep(READ_ONCE(cetrafs_refresh_compare_stall_ms)); /* TEST ONLY: see the knob */
    }

    ret = cetrafs_refresh_settle(inode, &raw);
    if (ret <= 0) {
        cetrafs_inode_fd_pub_unlock(inode);
        return ret;
    }
    /* The settle may have replaced the read: judge the record it returns. */
    if (cetrafs_refresh_reuse_check(inode, &raw)) {
        cetrafs_inode_fd_pub_unlock(inode);
        return -ESTALE;
    }

    ctrace("FDREFRESH ino=%llu verdict=apply rawseq=%llx cached=%llx rawsize=%llu coresize=%llu dirty=%d\n",
           (unsigned long long) inode->i_ino, (unsigned long long) cetrafs_le64(raw.file_seq),
           (unsigned long long) cetrafs_inode_local_file_seq(inode), (unsigned long long) cetrafs_le64(raw.size),
           (unsigned long long) i_size_read(inode), (int) cetrafs_inode_fd_dirty(inode));

    ret = cetrafs_apply_raw_to_vfs_inode_sampled(inode, &raw, epoch);
    cetrafs_inode_fd_pub_unlock(inode);
    if (ret == -ESTALE) {
        /* apply() says the record describes a deleted file (the
         * generation case was handled above). Unhash for the same
         * reason: cetrafs_iget()'s cache-hit path reacts to -ESTALE by
         * dropping its reference and retrying, and a retry that found
         * this same object still hashed would refresh it, get -ESTALE
         * again, and spin forever. */
        remove_inode_hash(inode);
    }
    return ret;
}
