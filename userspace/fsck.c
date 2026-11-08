// SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary
// fsck.cetrafs — v0.1 minimal checker for CETRAFS
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fs.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"
#include "devutil.h"

#define CETRAFS_ROOT_INO 1ULL

/*
 * Exit codes, because these are what a deployment script branches on:
 *
 *   0  the volume is clean
 *   1  problems were found and reported
 *   2  this tool was called wrong (usage)
 *   3  the volume could not be examined at all -- cannot open, cannot
 *      read, or it is mounted
 *
 * 2 and 3 used to be the same value, so a script could not tell "you
 * typed the wrong thing" from "the device is not there", which are
 * opposite situations: one is a bug in the caller, the other is a
 * missing disk.
 */
#define FSCK_EXIT_CLEAN 0
#define FSCK_EXIT_PROBLEMS 1
#define FSCK_EXIT_USAGE 2
#define FSCK_EXIT_NOEXAM 3

/* --- helpers --- */
static void diex(const char *m)
{
    perror(m);
    exit(FSCK_EXIT_NOEXAM);
}
/* Short reads are continued and EINTR retried, as growfs does; a read
 * that makes no progress is an EOF, not something to spin on. */
static void pread_all(int fd, void *buf, size_t len, off_t off)
{
    uint8_t *p = buf;
    while (len) {
        ssize_t r = pread(fd, p, len, off);
        if (r < 0 && errno == EINTR)
            continue;
        if (r < 0)
            diex("pread");
        if (r == 0) {
            fprintf(stderr, "pread: unexpected end of device at offset %lld\n", (long long) off);
            exit(FSCK_EXIT_NOEXAM);
        }
        p += r;
        off += r;
        len -= (size_t) r;
    }
}
static void *xcalloc(size_t n, size_t s)
{
    void *p = calloc(n, s);
    if (!p)
        diex("calloc");
    return p;
}

/*
 * Repair (-r). Off by default, and deliberately narrow.
 *
 * What it fixes is exactly the set of faults that are MECHANICALLY
 * DERIVABLE from data the filesystem still holds -- where there is one
 * right answer and no judgement to make:
 *
 *   - a bitmap bit disagreeing with what the extent trees reference, in
 *     either direction (a leaked block, or one that would be handed out
 *     twice);
 *   - a Block Group's cached free count, and a Zone Group's aggregate,
 *     disagreeing with the bitmaps they summarise;
 *   - an nlink disagreeing with the number of directory entries that
 *     actually name the inode.
 *
 * That is the residue an unclean crash leaves, and it is the whole
 * reason this volume could previously only be repaired by reformatting.
 *
 * What it deliberately does NOT fix, and why:
 *
 *   - CROSS-FILE OVERLAP. Two inodes reference one block; nothing on
 *     the disk says which of them should keep it. Guessing turns a
 *     detectable fault into a silent one.
 *   - An extent pointing outside every data region, or a record that
 *     fails its checksum. The structure that would tell us what it
 *     should have said is the structure that is broken.
 *   - An inode nothing names, or a dangling entry. Freeing the first
 *     destroys a user's data to recover space; removing the second
 *     destroys a name. Both are reported and left -- the same trade
 *     evict_inode's read-failure path has made: a
 *     bounded, diagnosable leak beats an unrecoverable deletion.
 *
 * And it refuses to touch anything at all if it found a fault in the
 * first list it cannot explain, because repairing around a corruption
 * you do not understand is how a recoverable volume becomes an
 * unrecoverable one.
 */
/* Kept byte-for-byte in step with fs.c's definitions: this tool exists
 * to explain a volume the kernel refuses, so it must refuse the same
 * bits. */
#define CETRAFS_KNOWN_INCOMPAT \
    (CETRAFS_FEAT_INCOMPAT_EXTENTS | CETRAFS_FEAT_INCOMPAT_GLOBAL_ITBL | CETRAFS_FEAT_INCOMPAT_NODE_REGISTRY)
#define CETRAFS_KNOWN_RO_COMPAT 0ULL

static int repair_mode;    /* -r given */
/* The Node Registry row this run holds while it repairs, so a node
 * cannot mount the volume mid-pass. -1 when nothing is held. See
 * devutil.h's cetrafs_repair_claim(). */
static int repair_row = -1;
static int repair_fd = -1;
static cetrafs_superblock_t repair_sb;

/* Registered with atexit() the moment the row is taken: every exit from
 * here on -- including die(), which the write helpers call -- has to
 * give the volume back. A missed release is not fatal (the lease
 * expires) but it leaves the volume unmountable for the staleness
 * window, which an operator would rightly call a bug. */
/* The claim's timer found our row taken, or a node beating under it
 * (devutil.h): stop before another write. Every repair write asks
 * (pwrite_all()), not only the loops that beat -- whole write phases run
 * between beats. */
static void fsck_repair_lost_check(void)
{
    if (cetrafs_repair_lost == 2) {
        /* The timer saw a node beating under the claim (devutil.h). */
        fprintf(stderr, "ERR: a node is mounted on this volume while it is being repaired -- stopping before "
                        "writing more\n");
        exit(FSCK_EXIT_NOEXAM);
    }
    if (cetrafs_repair_lost) {
        /* The timer's renewal found the row taken (devutil.h). */
        fprintf(stderr, "ERR: this repair's registry claim was taken away -- stopping before writing more\n");
        exit(FSCK_EXIT_NOEXAM);
    }
}

/* Refresh the claim while the passes run. Rate-limited to one write a
 * few seconds apart: a repair walks millions of inodes and the lease
 * only has to outlive the staleness window, not every iteration. */
static void fsck_repair_heartbeat(void)
{
    static time_t last;
    time_t now;

    if (repair_row < 0 || repair_fd < 0)
        return;
    fsck_repair_lost_check();
    now = time(NULL);
    if (last && now - last < 5)
        return;
    last = now;
    if (cetrafs_repair_renew(repair_fd, &repair_sb, (uint32_t) repair_row) != 0) {
        /* Somebody cleared our row. Carrying on would be repairing a
         * volume a node believes is free to mount. */
        fprintf(stderr, "ERR: this repair's registry claim was taken away -- stopping before writing more\n");
        exit(FSCK_EXIT_NOEXAM);
    }
}

static void fsck_repair_release_atexit(void)
{
    if (repair_row >= 0 && repair_fd >= 0) {
        cetrafs_repair_release(repair_fd, &repair_sb, (uint32_t) repair_row);
        repair_row = -1;
    }
}
static int repair_blocked; /* a fault we must not repair around */
static uint64_t repairs_made;
/* Faults found before the content pass declares its own counter (the
 * root-directory checks). Folded into the final total so an early fault
 * is never silently dropped from the count just because it was found
 * early -- and so a repaired one still makes the run report itself. */
static uint64_t early_problems;

/*
 * Set while the content pass walks a DELETED record (nlink=0): its
 * extents are not authoritative. Such a record is the residue of a
 * delete whose reclaim has not run yet, and the reclaim frees only the
 * number -- the blocks are long gone, or go through the leak reclaim,
 * which keeps every block a live record names. So its extents may name
 * blocks that are free, or another file's since: stale, not shared. What
 * that record's walk finds is reported as WARN, and a fault that would
 * otherwise disable repair only defers this run's leak clearing (the
 * blocks the record hides might belong to a file whose nlink drifted to
 * 0 while still named -- the namespace pass repairs that nlink, and the
 * next run walks the record as a live one).
 */
static int fsck_dead_walk;
static int fsck_dead_unwalkable;
#define FSCK_SEV (fsck_dead_walk ? "WARN" : "ERR")

static int fsck_all_zero(const uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; ++i)
        if (p[i])
            return 0;
    return 1;
}

static void repair_block(const char *why)
{
    if (fsck_dead_walk) {
        fsck_dead_unwalkable = 1;
        return;
    }
    if (!repair_blocked && repair_mode)
        fprintf(stderr, "NOTE: repair is disabled for this run: %s\n", why);
    repair_blocked = 1;
}

/* Write len bytes at off, or die: a partial repair write is worse than
 * none, and there is nothing sensible to do but stop.
 *
 * And durable before the next one. Repairs depend on each other in
 * program order -- an inode's bit before its record, its record before
 * the dirent naming it -- and a buffered write promises no order on
 * the device: a crash then keeps the dirent and loses the bit, and the
 * kernel hands the number out again. A write that fails only at
 * writeback was also reported "repaired". So every repair write is
 * synced, and a failed sync is exit 3 like a failed write. fsck -r is
 * offline and rare; correctness is the whole budget. */
static void pwrite_all(int fd, const void *buf, size_t len, off_t off)
{
    static long stop_after = -1;

    const uint8_t *p = buf;
    size_t left = len;
    off_t at = off;

    fsck_repair_lost_check();
    /* A short write is continued and EINTR retried (tests/image/
     * fsck_io_partial.sh): one pwrite that wrote part of a block used to
     * end the repair with that block half-written. No progress at all
     * is an error, not something to spin on. */
    while (left) {
        ssize_t w = pwrite(fd, p, left, at);

        if (w < 0 && errno == EINTR)
            continue;
        if (w < 0) {
            perror("pwrite (repair)");
            exit(FSCK_EXIT_NOEXAM);
        }
        if (w == 0) { /* no errno to report: perror would say "Success" */
            fprintf(stderr, "pwrite (repair): wrote nothing at offset %lld with %zu bytes left\n", (long long) at,
                    left);
            exit(FSCK_EXIT_NOEXAM);
        }
        p += w;
        at += w;
        left -= (size_t) w;
    }
    if (fdatasync(fd) != 0) {
        perror("fdatasync (repair)");
        exit(FSCK_EXIT_NOEXAM);
    }
    /* Test knob only: stop dead after the Nth repair write, as a crash
     * would -- no atexit, no release -- so a suite can check that every
     * prefix of a repair is a consistent volume. Unset normally. */
    if (stop_after < 0) {
        const char *e = getenv("CETRAFS_TEST_FSCK_STOP_AFTER_WRITES");

        stop_after = e ? atol(e) : 0;
    }
    if (stop_after > 0 && --stop_after == 0)
        _exit(99);
}

/* Rewrite one inode record's nlink, restamping the record checksum the
 * way inode.c's cetrafs_inode_crc() does (plain-native, over the record
 * with the checksum field zeroed). Records are one per block since
 * v0x0007, so this is a whole-block read-modify-write of a block that
 * holds nothing else. */
/*
 * Only a valid record OF THIS NUMBER may be field-patched and restamped.
 * Restamping restores the checksums over whatever the slot holds, so on
 * a never-written (all-zero) record it minted a checksum-valid record
 * for inode 0, mode 0 -- which the next run read as "a valid record for
 * another inode" and blocked every repair over (audit 2026-11-06 M12).
 * Such a slot is left for what reports it; this says why nothing was
 * written.
 */
static int fsck_record_restampable(const cetrafs_inode_t *in, uint64_t ino)
{
    if (cetrafs_inode_crcs_ok(in) && cetrafs_le64(in->ino) == ino)
        return 1;
    fprintf(stderr,
            "WARN: inode %" PRIu64 "'s record is not a valid record of that number -- not restamping it\n", ino);
    return 0;
}

static void repair_set_nlink(int fd, const cetrafs_superblock_t *sb, uint64_t ino, uint32_t nlink)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
    off_t off = (off_t) (cetrafs_le64(sb->inode_table_start) + (ino - 1)) * CETRAFS_BLOCK_SIZE;
    cetrafs_inode_t in;

    pread_all(fd, blk, sizeof(blk), off);
    memcpy(&in, blk, sizeof(in));
    if (!fsck_record_restampable(&in, ino))
        return;
    in.nlink = cetrafs_cpu_to_le32(nlink);
    cetrafs_inode_stamp_crcs_us(&in);
    memcpy(blk, &in, sizeof(in));
    pwrite_all(fd, blk, sizeof(blk), off);
}

/* Rewrite a directory record's size -- same read-modify-write and
 * restamp as repair_set_nlink() above. */
static void repair_set_dir_size(int fd, const cetrafs_superblock_t *sb, uint64_t ino, uint64_t size)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
    off_t off = (off_t) (cetrafs_le64(sb->inode_table_start) + (ino - 1)) * CETRAFS_BLOCK_SIZE;
    cetrafs_inode_t in;

    pread_all(fd, blk, sizeof(blk), off);
    memcpy(&in, blk, sizeof(in));
    if (!fsck_record_restampable(&in, ino))
        return;
    in.size = cetrafs_cpu_to_le64(size);
    cetrafs_inode_stamp_crcs_us(&in);
    memcpy(blk, &in, sizeof(in));
    pwrite_all(fd, blk, sizeof(blk), off);
}

/*
 * Directory data blocks found with a broken dirent tail during the scan,
 * repaired after the namespace pass -- '..' needs the parent, and the
 * parent is only known once every directory has been walked.
 */
struct bad_dirent_block {
    uint64_t ino;
    uint64_t phys;
    bool first_block;
};
static struct bad_dirent_block *bad_dirent_blocks;
static size_t bad_dirent_block_count, bad_dirent_block_cap;

static void note_bad_dirent_block(uint64_t ino, uint64_t phys, bool first_block)
{
    if (bad_dirent_block_count == bad_dirent_block_cap) {
        size_t ncap = bad_dirent_block_cap ? bad_dirent_block_cap * 2 : 8;
        struct bad_dirent_block *n = realloc(bad_dirent_blocks, ncap * sizeof(*n));

        if (!n)
            return; /* out of memory: report only, as before */
        bad_dirent_blocks = n;
        bad_dirent_block_cap = ncap;
    }
    bad_dirent_blocks[bad_dirent_block_count].ino = ino;
    bad_dirent_blocks[bad_dirent_block_count].phys = phys;
    bad_dirent_blocks[bad_dirent_block_count].first_block = first_block;
    bad_dirent_block_count++;
}

/*
 * Reinitialise a directory data block whose dirent tail is gone.
 *
 * A dirent block that fails its magic or its CRC on an UNMOUNTED volume
 * carries nothing a reader can trust: the kernel refuses the whole
 * directory (-EIO on readdir), which also means rmdir can never confirm
 * it is empty, so the directory cannot even be deleted. The volume is
 * stuck in a state no mounted operation can clear.
 *
 * The answer is derivable, which is why this is a repair and not a
 * report. The block's entries are already gone -- that is what "no
 * magic" means -- and every inode they named has by now been found
 * unreachable and linked into /lost+found, so nothing is lost by
 * rewriting the block as a VALID EMPTY one. For the directory's first
 * block the two structural entries are equally derivable: '.' is the
 * directory itself and '..' is whichever directory names it, which the
 * namespace pass has already established.
 *
 * What this does NOT do is invent entries for files whose names were in
 * the lost block; their inodes keep their data and reach the operator
 * through /lost+found, named by number. That is the same division of
 * labour as everywhere else in this tool: structure is rebuilt, content
 * is never guessed.
 */
static void repair_reinit_dirent_block(int fd, uint64_t phys, uint64_t self_ino, uint64_t parent_ino, bool first_block)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
    cetrafs_dirent_tail_t *tail;

    if (first_block) {
        cetrafs_dirent_t *d = (cetrafs_dirent_t *) blk;

        d[0].inode = cetrafs_cpu_to_le64(self_ino);
        d[0].file_type = CETRAFS_FT_DIR;
        d[0].name_len = cetrafs_cpu_to_le16(1);
        strncpy(d[0].name, ".", CETRAFS_FILENAME_MAX);

        d[1].inode = cetrafs_cpu_to_le64(parent_ino);
        d[1].file_type = CETRAFS_FT_DIR;
        d[1].name_len = cetrafs_cpu_to_le16(2);
        strncpy(d[1].name, "..", CETRAFS_FILENAME_MAX);
    }

    tail = (cetrafs_dirent_tail_t *) (blk + CETRAFS_DIRENT_TAIL_OFF);
    tail->magic = cetrafs_cpu_to_le32(CETRAFS_DIRENT_TAIL_MAGIC);
    tail->crc = cetrafs_cpu_to_le32(crc32c_update(0, blk, CETRAFS_DIRENT_TAIL_OFF));

    pwrite_all(fd, blk, sizeof(blk), (off_t) phys * CETRAFS_BLOCK_SIZE);
}

/* ---- lost+found ---------------------------------------------------
 *
 * The one repair that CREATES a directory entry rather than rewriting a
 * field in place, and the only answer there is for an orphan with a
 * live link count: the file still claims a link, so its data is still
 * wanted, and freeing it to recover space would destroy it.
 *
 * Everything below writes through the same conventions the kernel uses
 * -- plain-native record checksums, the dirent tail stamp, the inode
 * and data bitmaps -- because a repair that produces a clean checker
 * and an unusable volume has made things worse.
 *
 * The cached free counts are deliberately NOT adjusted here: the
 * content pass that reconciles them has already run by the time the
 * namespace pass knows who the orphans are, so a second `fsck -r`
 * settles them from the bitmaps, which is the truth. fsck says so.
 */
/*
 * Read one inode record.
 *
 * The bound is not decoration. Three of the four callers pass a number
 * fsck itself resolved, but the fourth takes it from a DIRENT on the
 * device -- and `inode_table_start + (ino - 1)` with an unchecked ino
 * addresses anything at all, including the data region, where the
 * bytes are whatever a user wrote into their own file. A record read
 * from there is attacker-chosen, and the caller in question goes on to
 * adopt it as /lost+found and write orphan entries into it.
 *
 * Out of range is zero-filled, which reads as mode 0: not a directory,
 * no valid checksum, no identity. Every caller already handles that.
 */
static void fsck_read_inode(int fd, const cetrafs_superblock_t *sb, uint64_t ino, cetrafs_inode_t *out)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};

    if (ino < 1 || ino > cetrafs_le32(sb->inodes_count)) {
        fprintf(stderr, "ERR: inode number %" PRIu64 " is outside the inode table (1..%u) -- not reading it\n", ino,
                cetrafs_le32(sb->inodes_count));
        memset(out, 0, sizeof(*out));
        return;
    }

    pread_all(fd, blk, sizeof(blk), (off_t) (cetrafs_le64(sb->inode_table_start) + (ino - 1)) * CETRAFS_BLOCK_SIZE);
    memcpy(out, blk, sizeof(*out));
}

static void fsck_write_inode(int fd, const cetrafs_superblock_t *sb, uint64_t ino, cetrafs_inode_t *in)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};

    cetrafs_inode_stamp_crcs_us(in);
    memcpy(blk, in, sizeof(*in));
    pwrite_all(fd, blk, sizeof(blk), (off_t) (cetrafs_le64(sb->inode_table_start) + (ino - 1)) * CETRAFS_BLOCK_SIZE);
}

/*
 * Does every slot in this dirent block still parse?
 *
 * The tail CRC covers the whole block, so a mismatch says "something in
 * here changed" and nothing about WHAT. The repair for an unreadable
 * block erases it and lets /lost+found have the contents by inode
 * number -- which is right when the entries are rubble, and throws away
 * every name in the directory when the damage was confined to the tail
 * (a torn write of the tail itself, a stamp that never landed, a bit
 * flipped in the CRC).
 *
 * This is the test for the second case, and it is deliberately
 * all-or-nothing: salvaging SOME entries out of a block means deciding
 * which of two disagreeing copies of the truth to keep, and a dirent
 * that parses can still name the wrong inode. Either the whole block is
 * coherent -- in which case re-stamping is lossless -- or it is not,
 * and the old answer stands.
 */
static int fsck_dirent_block_coherent(const uint8_t *db, const cetrafs_superblock_t *sb, int first_block,
                                      uint64_t self_ino)
{
    const cetrafs_dirent_t *de = (const cetrafs_dirent_t *) db;
    int saw_dot = 0, saw_dotdot = 0;

    for (unsigned s = 0; s < CETRAFS_DIRENTS_PER_BLOCK; ++s) {
        uint64_t ino = cetrafs_le64(de[s].inode);
        uint16_t nl = cetrafs_le16(de[s].name_len);

        if (ino == 0) {
            if (nl != 0)
                return 0; /* a free slot that is not blank is damage */
            continue;
        }
        if (ino > cetrafs_le32(sb->inodes_count))
            return 0;
        if (nl < 1 || nl > CETRAFS_FILENAME_MAX)
            return 0;
        if (memchr(de[s].name, 0, nl))
            return 0; /* a NUL inside the name it declares */
        if (de[s].file_type > CETRAFS_FT_SOCK)
            return 0;
        if (nl == 1 && de[s].name[0] == '.')
            saw_dot = (ino == self_ino);
        else if (nl == 2 && de[s].name[0] == '.' && de[s].name[1] == '.')
            saw_dotdot = 1;
    }

    /* A first block has to carry '.' and '..', and '.' has to point at
     * the directory itself. Without this an ERASED block -- every slot
     * blank, which passes every test above -- would be re-stamped as
     * "intact" and the directory would come back readable, empty, and
     * missing its structural entries. The rebuild path exists for
     * exactly that block. */
    if (first_block && !(saw_dot && saw_dotdot))
        return 0;
    return 1;
}

/* Stamp a dirent block's {magic, crc32c} tail, exactly as dir.c's
 * cetrafs_dirent_block_stamp() does: CRC32C over the block's first
 * CETRAFS_DIRENT_TAIL_OFF bytes. A block written without it fails every
 * lock-free reader's check and makes the directory unreadable. */
static void fsck_stamp_dirent_block(uint8_t *blk)
{
    cetrafs_dirent_tail_t tail;

    tail.magic = cetrafs_cpu_to_le32(CETRAFS_DIRENT_TAIL_MAGIC);
    tail.crc = cetrafs_cpu_to_le32(crc32c_update(0, blk, CETRAFS_DIRENT_TAIL_OFF));
    memcpy(blk + CETRAFS_DIRENT_TAIL_OFF, &tail, sizeof(tail));
}

/* Claim a free inode number in the in-memory bitmap the namespace pass
 * holds, AND on the device, before the caller writes the record or any
 * dirent naming it. It used to wait for the one write-back at the end
 * of the pass: a crash before that left a dirent naming an inode whose
 * bit was clear, which the kernel allocates again. */
static int fsck_alloc_inode(int fd, const cetrafs_superblock_t *sb, uint8_t *ibmap, int *dirty, uint64_t *out_ino)
{
    for (uint64_t ino = 2; ino <= cetrafs_le32(sb->inodes_count); ++ino) {
        uint64_t bit = ino - 1;
        uint64_t blk = (bit / 8) / CETRAFS_BLOCK_SIZE;

        if (ibmap[bit / 8] & (1u << (bit % 8)))
            continue;
        ibmap[bit / 8] |= (uint8_t) (1u << (bit % 8));
        *dirty = 1;
        pwrite_all(fd, ibmap + blk * CETRAFS_BLOCK_SIZE, CETRAFS_BLOCK_SIZE,
                   (off_t) (cetrafs_le64(sb->inode_bmap_start) + blk) * CETRAFS_BLOCK_SIZE);
        *out_ino = ino;
        return 0;
    }
    return -1;
}

/* Claim a free data block from the first Block Group that has one. */
/* Where the descriptors live, for fsck_alloc_block()'s count debit: set
 * once the Block Group table has been walked, NULL before (nothing
 * allocates that early). */
static const cetrafs_superblock_t *fsck_g_sb;
static const uint64_t *fsck_g_bg_desc_lba;

/* Debit one block from BG b's cached free count and its owner's (or the
 * pool's) aggregate, restamped the way the leak repair credits them. The
 * count checks ran earlier in the pass, so a block taken now without this
 * left both one high on disk and the next run reporting it (audit
 * 2026-11-06 L10, its sibling). */
static void fsck_adjust_bg_counts(int fd, uint32_t b, int credit)
{
    const cetrafs_superblock_t *sb = fsck_g_sb;
    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
    cetrafs_block_group_t bgd;
    cetrafs_zone_group_t zg;
    uint32_t z;
    int pool;

    if (!sb || !fsck_g_bg_desc_lba)
        return;
    pread_all(fd, blk, sizeof(blk), (off_t) fsck_g_bg_desc_lba[b] * CETRAFS_BLOCK_SIZE);
    memcpy(&bgd, blk, sizeof(bgd));
    if (credit)
        bgd.free_data_blocks = cetrafs_cpu_to_le64(cetrafs_le64(bgd.free_data_blocks) + 1);
    else if (cetrafs_le64(bgd.free_data_blocks))
        bgd.free_data_blocks = cetrafs_cpu_to_le64(cetrafs_le64(bgd.free_data_blocks) - 1);
    bgd.checksum = 0;
    bgd.checksum = cetrafs_cpu_to_le64(
        crc32c_struct(&bgd, sizeof(bgd), offsetof(cetrafs_block_group_t, checksum), sizeof(bgd.checksum)));
    memcpy(blk, &bgd, sizeof(bgd));
    pwrite_all(fd, blk, sizeof(blk), (off_t) fsck_g_bg_desc_lba[b] * CETRAFS_BLOCK_SIZE);

    z = cetrafs_le16(bgd.owner_zg);
    pool = z == CETRAFS_BG_OWNER_FREE;
    if (pool)
        z = b % cetrafs_le32(sb->zone_group_count);
    memset(blk, 0, sizeof(blk));
    pread_all(fd, blk, sizeof(blk), (off_t) (cetrafs_le64(sb->zg_table_start) + z) * CETRAFS_BLOCK_SIZE);
    memcpy(&zg, blk, sizeof(zg));
    if (credit && pool)
        zg.pool_free_blocks = cetrafs_cpu_to_le64(cetrafs_le64(zg.pool_free_blocks) + 1);
    else if (credit)
        zg.free_data_blocks = cetrafs_cpu_to_le64(cetrafs_le64(zg.free_data_blocks) + 1);
    else if (pool && cetrafs_le64(zg.pool_free_blocks))
        zg.pool_free_blocks = cetrafs_cpu_to_le64(cetrafs_le64(zg.pool_free_blocks) - 1);
    else if (!pool && cetrafs_le64(zg.free_data_blocks))
        zg.free_data_blocks = cetrafs_cpu_to_le64(cetrafs_le64(zg.free_data_blocks) - 1);
    zg.hot_checksum = 0;
    zg.hot_checksum = cetrafs_cpu_to_le64((uint64_t) crc32c_struct((const uint8_t *) &zg + CETRAFS_ZG_HOT_OFF,
                                                                   CETRAFS_ZG_HOT_LEN,
                                                                   offsetof(cetrafs_zone_group_t, hot_checksum) -
                                                                       CETRAFS_ZG_HOT_OFF,
                                                                   sizeof(zg.hot_checksum)));
    memcpy(blk, &zg, sizeof(zg));
    pwrite_all(fd, blk, sizeof(blk), (off_t) (cetrafs_le64(sb->zg_table_start) + z) * CETRAFS_BLOCK_SIZE);
}

static int fsck_alloc_block(int fd,
                            uint32_t bg_count,
                            const uint64_t *bg_data_start,
                            const uint64_t *bg_data_cnt,
                            const uint64_t *bg_bmap_lba,
                            uint64_t *out_lba)
{
    /* Test knob: force the "volume is full" answer. The failure path
     * below it used to LEAK the inode number lost+found had already
     * claimed -- and filling a real volume to exactly zero free blocks
     * is nondeterministic from a test (per-run allocation overheads
     * shift the count), so the path went unexercised. Same pattern as
     * devutil.h's CETRAFS_PEER_PROBE_SECS; unset in every normal run. */
    if (getenv("CETRAFS_FSCK_LF_NO_BLOCK"))
        return -1;
    for (uint32_t b = 0; b < bg_count; ++b) {
        uint64_t bmap_blocks = (bg_data_cnt[b] + CETRAFS_BLOCK_SIZE * 8 - 1) / (CETRAFS_BLOCK_SIZE * 8);
        uint8_t *bmap = (uint8_t *) xcalloc(bmap_blocks ? bmap_blocks : 1, CETRAFS_BLOCK_SIZE);

        pread_all(fd, bmap, (size_t) bmap_blocks * CETRAFS_BLOCK_SIZE, (off_t) bg_bmap_lba[b] * CETRAFS_BLOCK_SIZE);
        for (uint64_t i = 0; i < bg_data_cnt[b]; ++i) {
            if (bmap[i / 8] & (1u << (i % 8)))
                continue;
            bmap[i / 8] |= (uint8_t) (1u << (i % 8));
            pwrite_all(fd, bmap, (size_t) bmap_blocks * CETRAFS_BLOCK_SIZE,
                       (off_t) bg_bmap_lba[b] * CETRAFS_BLOCK_SIZE);
            fsck_adjust_bg_counts(fd, b, 0); /* the bit first: stopped between, a count reads one high -- the next run fixes it */
            *out_lba = bg_data_start[b] + i;
            free(bmap);
            return 0;
        }
        free(bmap);
    }
    return -1;
}

/* The dirent file_type for a raw mode -- the kernel's
 * cetrafs_dirent_type(). readdir hands it out as d_type, and `find -type
 * l`, fts, rsync and tar trust it without a stat. */
static uint8_t fsck_ft_for_mode(uint32_t mode)
{
    switch (mode & 0170000u) {
    case 0040000u:
        return CETRAFS_FT_DIR;
    case 0120000u:
        return CETRAFS_FT_LNK;
    case 0020000u:
        return CETRAFS_FT_CHR;
    case 0060000u:
        return CETRAFS_FT_BLK;
    case 0010000u:
        return CETRAFS_FT_FIFO;
    case 0140000u:
        return CETRAFS_FT_SOCK;
    default:
        return CETRAFS_FT_REG;
    }
}

/* Give back a block fsck_alloc_block() handed out and nothing came to
 * reference: its bit cleared, its counts credited. */
static void fsck_unalloc_block(int fd,
                               uint32_t bg_count,
                               const uint64_t *bg_data_start,
                               const uint64_t *bg_data_cnt,
                               const uint64_t *bg_bmap_lba,
                               uint64_t lba)
{
    for (uint32_t b = 0; b < bg_count; ++b) {
        uint64_t i;
        uint8_t byte;
        off_t at;

        if (lba < bg_data_start[b] || lba - bg_data_start[b] >= bg_data_cnt[b])
            continue;
        i = lba - bg_data_start[b];
        at = (off_t) bg_bmap_lba[b] * CETRAFS_BLOCK_SIZE + (off_t) (i / 8);
        pread_all(fd, &byte, 1, at);
        if (!(byte & (1u << (i % 8))))
            return;
        byte &= (uint8_t) ~(1u << (i % 8));
        pwrite_all(fd, &byte, 1, at);
        fsck_adjust_bg_counts(fd, b, 1);
        return;
    }
}

/* The physical block holding logical block 'n' of a depth-0 directory.
 * lost+found and the directories it holds are all built or walked here
 * at depth 0: a directory that spilled into an external leaf is left to
 * the kernel, and this only ever ADDS entries to a directory it created
 * itself. */
/* A block number read from a (possibly hostile) on-disk record, about to
 * become a byte offset as (off_t) lba * CETRAFS_BLOCK_SIZE. A value past
 * total_blocks is corruption, and that multiply is signed-overflow UB for a
 * huge lba besides (a fuzz finding). 0 is never a valid data/meta block
 * here (the superblock lives there). */
static int fsck_lba_in_range(uint64_t lba, uint64_t total_blocks)
{
    return lba != 0 && lba < total_blocks;
}

static int fsck_dir_block(const cetrafs_inode_t *in, uint32_t n, uint64_t total_blocks, uint64_t *out_lba)
{
    uint64_t seen = 0;

    if (in->eh.eh_depth != 0)
        return -1;
    for (uint32_t e = 0; e < cetrafs_le16(in->eh.eh_entries) && e < 4; ++e) {
        uint64_t len = cetrafs_le32(in->et.leaf[e].ee_len) & CETRAFS_EXT_LEN_MASK;
        uint64_t phys = ((uint64_t) cetrafs_le16(in->et.leaf[e].ee_start_hi) << 32) | cetrafs_le32(in->et.leaf[e].ee_start_lo);

        if (n < seen + len) {
            uint64_t lba = phys + (n - seen);

            /* phys and len both come off the disk, so the block this
             * resolves to need not be on the device at all -- and every
             * caller turns it into (off_t) lba * CETRAFS_BLOCK_SIZE,
             * which is signed-overflow UB before it is a bad read.
             * Refusing here covers all three callers at once. */
            if (!fsck_lba_in_range(lba, total_blocks))
                return -1;
            *out_lba = lba;
            return 0;
        }
        seen += len;
    }
    return -1;
}

/* How many blocks a depth-0 directory has, counting only extents that
 * lie wholly on the device.
 *
 * ee_len is 31 bits read off the disk, so four hostile extents sum to
 * eight billion -- and both callers below turn that count into one
 * pread per block. Same unbounded walk fsck_run_bg() stops in the
 * content pass, in the two repair paths that do not have the BG tables
 * to hand; a block past the end of the device holds no dirent either
 * way, so dropping it loses nothing a walk could have found. */
static uint32_t fsck_dir_nblocks(const cetrafs_inode_t *dir, uint64_t total_blocks)
{
    uint64_t n = 0;

    for (uint32_t e = 0; e < cetrafs_le16(dir->eh.eh_entries) && e < 4; ++e) {
        uint64_t len = cetrafs_le32(dir->et.leaf[e].ee_len) & CETRAFS_EXT_LEN_MASK;
        uint64_t phys = ((uint64_t) cetrafs_le16(dir->et.leaf[e].ee_start_hi) << 32) | cetrafs_le32(dir->et.leaf[e].ee_start_lo);

        if (len == 0 || !fsck_lba_in_range(phys, total_blocks) || phys + len > total_blocks)
            continue;
        n += len;
    }
    return n > total_blocks ? (uint32_t) total_blocks : (uint32_t) n;
}

/* State for one repair run's lost+found: resolved or created lazily, on
 * the first orphan that actually needs it, so a healthy volume never
 * grows one. */
struct fsck_lf {
    uint64_t ino;      /* 0 until resolved/created */
    uint64_t root_ino; /* where it lives */
    int tried;         /* resolution already attempted and failed */
    int created;       /* this run made it: root gained a subdirectory */
};

/* Add one entry to a depth-0 directory, growing it by a block if every
 * slot is full. Returns 0, or -1 if it cannot (no space, or the
 * directory has spilled into an external leaf -- which only the kernel
 * builds, and never for a lost+found this tool made). */
static int fsck_dir_link(int fd,
                         const cetrafs_superblock_t *sb,
                         uint32_t bg_count,
                         const uint64_t *bg_data_start,
                         const uint64_t *bg_data_cnt,
                         const uint64_t *bg_bmap_lba,
                         uint64_t dir_ino,
                         const char *name,
                         uint64_t target_ino,
                         uint8_t file_type)
{
    cetrafs_inode_t dir;
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    uint32_t nblocks = 0;
    uint64_t lba = 0;

    fsck_read_inode(fd, sb, dir_ino, &dir);
    /* The record is rewritten below: only a valid record of this number
     * may be (class 45). The caller's earlier check is not this one. */
    if (!fsck_record_restampable(&dir, dir_ino))
        return -1;
    if (dir.eh.eh_depth != 0)
        return -1;
    nblocks = fsck_dir_nblocks(&dir, cetrafs_le64(sb->total_blocks));

    for (uint32_t n = 0; n < nblocks; ++n) {
        cetrafs_dirent_t *de;

        if (fsck_dir_block(&dir, n, cetrafs_le64(sb->total_blocks), &lba))
            return -1;
        pread_all(fd, blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);
        de = (cetrafs_dirent_t *) blk;
        for (unsigned k = 0; k < CETRAFS_DIRENTS_PER_BLOCK; ++k) {
            if (de[k].inode)
                continue;
            memset(&de[k], 0, sizeof(de[k]));
            de[k].inode = cetrafs_cpu_to_le64(target_ino);
            de[k].file_type = file_type;
            de[k].name_len = cetrafs_cpu_to_le16((uint16_t) strlen(name));
            memcpy(de[k].name, name, strlen(name));
            fsck_stamp_dirent_block(blk);
            pwrite_all(fd, blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);
            goto linked;
        }
    }

    /* Every slot full: grow by one block, merging into the last extent
     * when it lands contiguously, exactly as the kernel's growth path
     * does. Four inline extents is the limit here -- see the comment on
     * fsck_dir_block(). */
    {
        uint64_t nlba = 0;

        if (fsck_alloc_block(fd, bg_count, bg_data_start, bg_data_cnt, bg_bmap_lba, &nlba))
            return -1;
        memset(blk, 0, sizeof(blk));
        {
            cetrafs_dirent_t *de = (cetrafs_dirent_t *) blk;

            de[0].inode = cetrafs_cpu_to_le64(target_ino);
            de[0].file_type = file_type;
            de[0].name_len = cetrafs_cpu_to_le16((uint16_t) strlen(name));
            memcpy(de[0].name, name, strlen(name));
        }
        fsck_stamp_dirent_block(blk);
        /* The block must be a VALID dirent block on the device before
         * the extent makes it reachable -- the same ordering rule the
         * kernel follows. */
        pwrite_all(fd, blk, sizeof(blk), (off_t) nlba * CETRAFS_BLOCK_SIZE);

        uint32_t e = cetrafs_le16(dir.eh.eh_entries);
        if (e > 0) {
            cetrafs_extent_t *last = &dir.et.leaf[e - 1];
            uint64_t lphys = ((uint64_t) cetrafs_le16(last->ee_start_hi) << 32) | cetrafs_le32(last->ee_start_lo);
            uint32_t llen = cetrafs_le32(last->ee_len) & CETRAFS_EXT_LEN_MASK;

            /* The packer, not a cast. ee_len is 31 bits of length plus
             * the uninit flag; casting the sum to uint16_t truncated it
             * at 65535 and, one block later, wrapped the length to ZERO
             * -- the exact value that made fiemap spin forever before
             * cetrafs_fiemap() learned to reject it. Growing past the
             * mask simply starts a new entry instead. */
            if (lphys + llen == nlba && (uint64_t) llen + 1 <= CETRAFS_EXT_LEN_MASK) {
                last->ee_len = cetrafs_extent_pack_len(llen + 1, 0);
                goto grown;
            }
        }
        if (e >= 4) {
            /* No slot for it: the block taken above goes back rather
             * than being left set and referenced by nothing (audit
             * 2026-11-06 L26). */
            fsck_unalloc_block(fd, bg_count, bg_data_start, bg_data_cnt, bg_bmap_lba, nlba);
            return -1;
        }
        dir.et.leaf[e].ee_block = cetrafs_cpu_to_le32(nblocks);
        dir.et.leaf[e].ee_len = cetrafs_extent_pack_len(1, 0);
        dir.et.leaf[e].ee_start_lo = cetrafs_cpu_to_le32((uint32_t) (nlba & 0xFFFFFFFFu));
        dir.et.leaf[e].ee_start_hi = cetrafs_cpu_to_le16((uint16_t) (nlba >> 32));
        dir.eh.eh_entries = cetrafs_cpu_to_le16((uint16_t) (e + 1));
    grown:
        dir.blocks = cetrafs_cpu_to_le64(cetrafs_le64(dir.blocks) + (CETRAFS_BLOCK_SIZE / 512));
    }

linked:
    dir.size = cetrafs_cpu_to_le64(cetrafs_le64(dir.size) + (sizeof(cetrafs_dirent_t)));
    dir.dirent_seq = cetrafs_cpu_to_le64(cetrafs_le64(dir.dirent_seq) + 1); /* every writer of a dirent block bumps it */
    if (file_type == CETRAFS_FT_DIR)
        dir.nlink = cetrafs_cpu_to_le32(cetrafs_le32(dir.nlink) + 1);
    fsck_write_inode(fd, sb, dir_ino, &dir);
    return 0;
}


/* Repoint a directory's '..' at a new parent. Only ever used on an
 * orphan being grafted into lost+found, which is why it is allowed to
 * assume '..' is the second entry of the first block -- every directory
 * this filesystem creates is built that way, and the namespace pass has
 * already reported any that is not. */
static void fsck_set_dotdot(int fd, const cetrafs_superblock_t *sb, uint64_t dir_ino, uint64_t parent)
{
    cetrafs_inode_t in;
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    cetrafs_dirent_t *de;
    uint64_t lba = 0;

    fsck_read_inode(fd, sb, dir_ino, &in);
    /* Its record is restamped below (class 45). */
    if (!fsck_record_restampable(&in, dir_ino))
        return;
    if (fsck_dir_block(&in, 0, cetrafs_le64(sb->total_blocks), &lba))
        return;
    pread_all(fd, blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);
    de = (cetrafs_dirent_t *) blk;
    if (!(cetrafs_le16(de[1].name_len) == 2 && de[1].name[0] == '.' && de[1].name[1] == '.'))
        return;
    de[1].inode = cetrafs_cpu_to_le64(parent);
    fsck_stamp_dirent_block(blk);
    pwrite_all(fd, blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);

    in.dirent_seq = cetrafs_cpu_to_le64(cetrafs_le64(in.dirent_seq) + 1);
    fsck_write_inode(fd, sb, dir_ino, &in);
}

/* Resolve /lost+found, creating it if it is not there. Lazy: a healthy
 * volume, and a run with no live orphans, never grows one. */
static uint64_t fsck_lost_found(int fd,
                                const cetrafs_superblock_t *sb,
                                uint32_t bg_count,
                                const uint64_t *bg_data_start,
                                const uint64_t *bg_data_cnt,
                                const uint64_t *bg_bmap_lba,
                                uint8_t *ibmap,
                                int *ibmap_dirty,
                                struct fsck_lf *lf)
{
    cetrafs_inode_t root, nd;
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    uint64_t lba = 0, ino = 0;
    uint32_t nblocks = 0;

    if (lf->ino || lf->tried)
        return lf->ino;
    lf->tried = 1;

    /* Already there? Take it only if it really is a directory -- a
     * regular file called lost+found is a fault of its own, not
     * somewhere to graft orphans. */
    fsck_read_inode(fd, sb, lf->root_ino, &root);
    /*
     * This tool reads and links only a depth-0 directory. A root that
     * has spilled into an external leaf (more than 4 extents) used to
     * skip the lookup, allocate a NEW lost+found -- an inode and a
     * block -- and then fail to link it, leaking both on every -r run.
     * Refuse before allocating anything; the orphans stay reported.
     */
    if (root.eh.eh_depth != 0) {
        fprintf(stderr, "ERR: the root directory has spilled into an extent leaf; this fsck can neither find nor "
                        "create /lost+found there -- orphans are reported, not relinked\n");
        return 0;
    }
    {
        nblocks = fsck_dir_nblocks(&root, cetrafs_le64(sb->total_blocks));
        for (uint32_t n = 0; n < nblocks; ++n) {
            const cetrafs_dirent_t *de;

            if (fsck_dir_block(&root, n, cetrafs_le64(sb->total_blocks), &lba))
                break;
            pread_all(fd, blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);
            de = (const cetrafs_dirent_t *) blk;
            for (unsigned k = 0; k < CETRAFS_DIRENTS_PER_BLOCK; ++k) {
                if (cetrafs_le64(de[k].inode) && cetrafs_le16(de[k].name_len) == 10 && !memcmp(de[k].name, "lost+found", 10)) {
                    cetrafs_inode_t cand;
                    uint64_t cand_ino = cetrafs_le64(de[k].inode);

                    fsck_read_inode(fd, sb, cand_ino, &cand);
                    /* Everything about this number came off the device.
                     * Before orphans are grafted into whatever it names,
                     * the record has to pass its own checksums and echo
                     * the number we looked it up by -- a valid record
                     * belonging to a different inode is not /lost+found
                     * either. */
                    if (!cetrafs_inode_crcs_ok(&cand) || cetrafs_le64(cand.ino) != cand_ino) {
                        fprintf(stderr,
                                "ERR: the /lost+found entry names inode %" PRIu64
                                ", whose record does not check out -- cannot recover orphans\n",
                                cand_ino);
                        return 0;
                    }
                    if (!S_ISDIR(cetrafs_le32(cand.mode))) {
                        fprintf(stderr, "ERR: /lost+found exists and is not a directory -- cannot recover orphans\n");
                        return 0;
                    }
                    lf->ino = cetrafs_le64(de[k].inode);
                    return lf->ino;
                }
            }
        }
    }

    if (fsck_alloc_inode(fd, sb, ibmap, ibmap_dirty, &ino)) {
        fprintf(stderr, "ERR: no free inode for /lost+found\n");
        return 0;
    }
    if (fsck_alloc_block(fd, bg_count, bg_data_start, bg_data_cnt, bg_bmap_lba, &lba)) {
        /* Give the inode number back. fsck_alloc_inode() set its bit in
         * the in-memory bitmap (and latched ibmap_dirty); bailing with
         * the bit still set would flush an ALLOCATED bit with no record
         * behind it -- which the next run reads as "inode marked in use
         * but its checksum is wrong" and blocks every repair over.
         * fsck -r must never manufacture the fault that stops fsck -r.
         * The bit is on the device already (fsck_alloc_inode()), so the
         * give-back goes there too, at once. (ibmap_dirty stays latched:
         * rewriting an unchanged bitmap is harmless, and other passes
         * may have dirtied it for real.) */
        {
            uint64_t bb = ((ino - 1) / 8) / CETRAFS_BLOCK_SIZE;

            ibmap[(ino - 1) / 8] &= (uint8_t) ~(1u << ((ino - 1) % 8));
            pwrite_all(fd, ibmap + bb * CETRAFS_BLOCK_SIZE, CETRAFS_BLOCK_SIZE,
                       (off_t) (cetrafs_le64(sb->inode_bmap_start) + bb) * CETRAFS_BLOCK_SIZE);
        }
        fprintf(stderr, "ERR: no free block for /lost+found\n");
        return 0;
    }

    memset(blk, 0, sizeof(blk));
    {
        cetrafs_dirent_t *de = (cetrafs_dirent_t *) blk;

        de[0].inode = cetrafs_cpu_to_le64(ino);
        de[0].file_type = CETRAFS_FT_DIR;
        de[0].name_len = cetrafs_cpu_to_le16(1);
        de[0].name[0] = '.';
        de[1].inode = cetrafs_cpu_to_le64(lf->root_ino);
        de[1].file_type = CETRAFS_FT_DIR;
        de[1].name_len = cetrafs_cpu_to_le16(2);
        de[1].name[0] = '.';
        de[1].name[1] = '.';
    }
    fsck_stamp_dirent_block(blk);
    pwrite_all(fd, blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);

    memset(&nd, 0, sizeof(nd));
    nd.ino = cetrafs_cpu_to_le64(ino);
    nd.mode = cetrafs_cpu_to_le32(S_IFDIR | 0700); /* root only: whatever ends up here is not public */
    nd.nlink = cetrafs_cpu_to_le32(2);
    nd.size = cetrafs_cpu_to_le64(sizeof(cetrafs_dirent_t) * 2);
    nd.blocks = cetrafs_cpu_to_le64(CETRAFS_BLOCK_SIZE / 512);
    nd.ctime = nd.mtime = nd.atime = cetrafs_cpu_to_le64((uint64_t) time(NULL));
    nd.flags = cetrafs_cpu_to_le32(CETRAFS_INODE_EXTENTS);
    /* Never 0: a zeroed generation is indistinguishable from an
     * unstamped record, and 0 is a valid node id for ns_lock_owner. */
    nd.generation = cetrafs_cpu_to_le64((uint64_t) time(NULL) | 1);
    nd.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
    nd.lock_owner_node = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
    nd.eh.eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    nd.eh.eh_entries = cetrafs_cpu_to_le16(1);
    nd.eh.eh_max = cetrafs_cpu_to_le16(4);
    nd.et.leaf[0].ee_block = 0;
    nd.et.leaf[0].ee_len = cetrafs_extent_pack_len(1, 0);
    nd.et.leaf[0].ee_start_lo = cetrafs_cpu_to_le32((uint32_t) (lba & 0xFFFFFFFFu));
    nd.et.leaf[0].ee_start_hi = cetrafs_cpu_to_le16((uint16_t) (lba >> 32));
    fsck_write_inode(fd, sb, ino, &nd);

    if (fsck_dir_link(fd, sb, bg_count, bg_data_start, bg_data_cnt, bg_bmap_lba, lf->root_ino, "lost+found", ino,
                      CETRAFS_FT_DIR)) {
        fprintf(stderr, "ERR: could not add /lost+found to the root directory\n");
        return 0;
    }
    printf("  created /lost+found (inode %" PRIu64 ")\n", ino);
    lf->ino = ino;
    lf->created = 1;
    return ino;
}

#ifndef FSCK_SET
#define FSCK_SET(bm, i) ((bm)[(i) / 8] |= (uint8_t) (1u << ((i) % 8)))
#define FSCK_GET(bm, i) (((bm)[(i) / 8] >> ((i) % 8)) & 1u)
#define FSCK_CLR(bm, i) ((bm)[(i) / 8] &= (uint8_t) ~(1u << ((i) % 8)))
#endif

/* Context for fsck_mark_run(): the content pass's reachability bitmaps,
 * the BG data-region tables, and the running tallies. */
struct fsck_refctx {
    uint8_t *refd;
    uint8_t *dupd;
    const uint64_t *bg_start;
    const uint64_t *bg_cnt;
    uint32_t nbg;
    uint64_t *problems;
    uint64_t *blocks_referenced;
    uint8_t *weakd; /* referenced only by deleted records (fsck_dead_walk) */
    uint64_t *stale; /* deleted records' blocks a live record also names */
};

/* Mark one physical run [phys, phys+len) as referenced by 'ino', flagging
 * an out-of-region block or a cross-file overlap. The one place the
 * content pass turns an extent (or a meta block) into bitmap bits, shared
 * by depth 0/1/2 so the depth-2 walk reuses exactly the depth-0 checks. */
/* The BG whose data region holds the WHOLE run [phys, phys+len), or -1.
 * An extent never crosses a BG, so a legal run fits entirely inside one
 * BG's data range and the question has a single answer for the run.
 *
 * It must be asked ONCE, before anything iterates: a hostile extent
 * carries len up to 2^31 with a wild phys, and a per-block loop then
 * runs billions of times and prints one complaint PER block -- GiB of
 * output and a near-hang on one crafted extent. fsck_mark_run() learned
 * that from a fuzz finding and fixed it HERE; the namespace walk in
 * main() had rolled its own loop over the same extents and had not, so
 * one mutated directory size still bought 19 MB of "no dirent-tail
 * magic" and a SIGXFSZ under a write limit (a later fuzz finding).
 * Hence a shared predicate rather than a second copy of the reasoning.
 *
 * *base_out, when asked for, receives the number of data blocks in the
 * BGs before the one found -- the caller's bitmap index of its first
 * block. It is meaningless, and untouched, when the answer is -1. */
static int fsck_run_bg(const uint64_t *bg_start, const uint64_t *bg_cnt, uint32_t nbg, uint64_t phys, uint64_t len,
                       uint64_t *base_out)
{
    uint64_t base = 0;

    for (uint32_t b = 0; b < nbg; ++b) {
        if (phys >= bg_start[b] && phys < bg_start[b] + bg_cnt[b]) {
            if (len > bg_cnt[b] || phys + len > bg_start[b] + bg_cnt[b])
                return -1;
            if (base_out)
                *base_out = base;
            return (int) b;
        }
        base += bg_cnt[b];
    }
    return -1;
}

/* An extent's LOGICAL fields, which fsck_mark_run() (physical) never
 * looked at. Each is something the kernel refuses or silently loses:
 * a zero length (seek/fiemap and the unwritten convert call the volume
 * corrupt), an end past the largest file (the convert refuses it), and
 * at depth 2 an extent outside the [ei_block, ei_block_end) range its
 * index entries advertise -- the lookup skips a child on that range, so
 * the block reads as a hole and the next write allocates over it. lo/hi
 * is the narrowest advertised range, hi == 0 for "none". Reported, not
 * repaired: none of these hides a block from the walk. */
/* The current inode's logical runs, for the overlap check after its
 * walk, and its file type, for the uninit check. */
struct fsck_lrun {
    uint64_t lo, hi;
};
static struct fsck_lrun *fsck_lruns;
static size_t fsck_nlruns, fsck_lruns_cap;
static uint32_t fsck_cur_fmt;

static int fsck_lrun_cmp(const void *a, const void *b)
{
    const struct fsck_lrun *x = a, *y = b;

    return x->lo < y->lo ? -1 : x->lo > y->lo;
}

/* Two extents of one file covering the same logical block: the
 * kernel's lookup takes whichever it meets first (file.c tolerates it
 * as "a damaged tree"), so the other's blocks are data nobody can
 * read, and which one wins depends on the array's order. */
static int fsck_lruns_overlap(uint64_t ino)
{
    if (fsck_nlruns < 2)
        return 0;
    qsort(fsck_lruns, fsck_nlruns, sizeof(*fsck_lruns), fsck_lrun_cmp);
    for (size_t i = 1; i < fsck_nlruns; i++) {
        if (fsck_lruns[i].lo < fsck_lruns[i - 1].hi) {
            fprintf(stderr,
                    "%s: inode %" PRIu64 " maps logical block %" PRIu64
                    " in two extents -- the kernel reads one and the other's blocks are lost to it\n",
                    FSCK_SEV, ino, fsck_lruns[i].lo);
            return 1;
        }
    }
    return 0;
}

static int fsck_extent_logical(uint64_t ino, const cetrafs_extent_t *x, uint64_t lo, uint64_t hi)
{
    uint64_t eb = cetrafs_le32(x->ee_block);
    uint64_t len = cetrafs_le32(x->ee_len) & CETRAFS_EXT_LEN_MASK;

    if (len) {
        if (fsck_nlruns == fsck_lruns_cap) {
            fsck_lruns_cap = fsck_lruns_cap ? fsck_lruns_cap * 2 : 64;
            fsck_lruns = (struct fsck_lrun *) realloc(fsck_lruns, fsck_lruns_cap * sizeof(*fsck_lruns));
            if (!fsck_lruns) {
                perror("realloc");
                exit(FSCK_EXIT_NOEXAM);
            }
        }
        fsck_lruns[fsck_nlruns].lo = eb;
        fsck_lruns[fsck_nlruns++].hi = eb + len;
    }
    /* Preallocated space exists only in regular files (fallocate is a
     * file operation). In a symlink it reads as zeros through
     * get_block; in a directory dir.c ignores the flag. Either way it
     * is a state no kernel path creates. */
    if (cetrafs_extent_is_uninit(x->ee_len) && fsck_cur_fmt != 0100000u) {
        fprintf(stderr, "%s: inode %" PRIu64 " (not a regular file) has a preallocated extent at logical block %" PRIu64
                        "\n",
                FSCK_SEV, ino, eb);
        return 1;
    }

    if (len == 0) {
        fprintf(stderr, "%s: inode %" PRIu64 " has an extent of length 0 at logical block %" PRIu64 "\n", FSCK_SEV,
                ino, eb);
        return 1;
    }
    if (eb + len > CETRAFS_MAX_FILE_BLOCKS) {
        fprintf(stderr, "%s: inode %" PRIu64 " has an extent [%" PRIu64 ",+%" PRIu64 ") past the largest file\n",
                FSCK_SEV, ino, eb, len);
        return 1;
    }
    if (hi && (eb < lo || eb + len > hi)) {
        fprintf(stderr,
                "%s: inode %" PRIu64 " has an extent [%" PRIu64 ",+%" PRIu64 ") outside the range [%" PRIu64
                ",%" PRIu64 ") its index advertises -- the kernel's lookup skips it\n",
                FSCK_SEV, ino, eb, len, lo, hi);
        return 1;
    }
    return 0;
}

static void fsck_mark_run(struct fsck_refctx *c, uint64_t phys, uint64_t len, uint64_t ino)
{
    uint64_t base = 0, idx0;
    int found;
    int overlap_reported = 0;

    if (len == 0)
        return;

    found = fsck_run_bg(c->bg_start, c->bg_cnt, c->nbg, phys, len, &base);
    if (found < 0) {
        fprintf(stderr,
                "%s: inode %" PRIu64 " extent [%" PRIu64 ",+%" PRIu64 ") is outside every data region\n",
                FSCK_SEV, ino, phys, len);
        if (!fsck_dead_walk)
            (*c->problems)++;
        repair_block("an extent points outside every data region, so the extent tree "
                     "cannot be trusted to say what is referenced");
        return;
    }

    idx0 = base + (phys - c->bg_start[found]);
    for (uint64_t k = 0; k < len; ++k) {
        uint64_t idx = idx0 + k;

        if (FSCK_GET(c->refd, idx) && fsck_dead_walk) {
            /* Live records were all walked first: whatever already
             * holds this block outranks a deleted record's claim. */
            (*c->stale)++;
        } else if (FSCK_GET(c->refd, idx)) {
            FSCK_SET(c->dupd, idx); /* this block is double-claimed */
            /* Report the overlap once per run, not once per block -- a
             * fully-overlapping multi-hundred-MB extent is one finding,
             * not hundreds of thousands of identical lines. Every block is
             * still processed, so a partial overlap marks exactly the
             * shared blocks and still counts the fresh ones. */
            if (!overlap_reported) {
                fprintf(stderr,
                        "ERR: block %" PRIu64 " is referenced by more than one inode (inode %" PRIu64
                        " among them) -- cross-file overlap\n",
                        phys + k, ino);
                (*c->problems)++;
                repair_block("two inodes reference one block and nothing on disk says which should keep it");
                overlap_reported = 1;
            }
        } else {
            /* CETRAFS_FSCK_DUMP_REFS=1: one line per block a live inode
             * OWNS, with that inode. Intersecting it with a trace of
             * what the online scrub freed is what turns "the scrub
             * reclaimed N blocks" into "the scrub freed inode X's
             * blocks". Marked here rather than in the bitmap sweep: the
             * sweep's reference set also counts blocks merely QUEUED for
             * a free, which are not owned by anybody. */
            if (getenv("CETRAFS_FSCK_DUMP_REFS"))
                fprintf(stderr, "REF: lba=%" PRIu64 " ino=%" PRIu64 "\n", phys + k, ino);
            FSCK_SET(c->refd, idx);
            if (fsck_dead_walk)
                FSCK_SET(c->weakd, idx);
            (*c->blocks_referenced)++;
        }
    }
}

/* Verify a leaf/interior block's v0x000F tail. Offline there is no
 * torn-write excuse, so a bad tail is real corruption. Returns 0 if OK. */
static int fsck_check_tail(const uint8_t *blk, uint32_t magic)
{
    const cetrafs_blk_tail_t *t = (const cetrafs_blk_tail_t *) (blk + CETRAFS_BLK_TAIL_OFF);

    if (cetrafs_le32(t->magic) != magic || cetrafs_le32(t->crc) != crc32c_update(0, blk, CETRAFS_BLK_TAIL_OFF))
        return -1;
    /* Integrity, then sense -- the kernel's order and its definition
     * (cetrafs_blk_struct_ok()). A count past what the block holds was
     * clamped below in silence, and the volume called clean while the
     * kernel refuses the block on every read. */
    if (!cetrafs_blk_struct_ok(blk, magic)) {
        fprintf(stderr, "ERR: block of kind 0x%08x passes its checksum but holds an impossible count or length\n",
                magic);
        return -1;
    }
    return 0;
}

/*
 * Salvage of a torn regular-file extent leaf (crash review 2026-11-08, C1).
 *
 * A crash can no longer tear one -- every leaf write is a journal target
 * and replay redoes it -- but media damage can, and a leaf that fails its
 * tail took the whole file with it: every read of its range -EIO, and
 * repair refused because its blocks could not be told from leaked ones.
 *
 * A leaf is a candidate when it is still a leaf (its tail magic and its
 * extent header magic are intact: a block reused as something else is
 * not salvaged, it is reported). Its entries are each judged on their
 * own, after the namespace pass, and kept only when ALL of these hold:
 *   - the run lies in one data region;
 *   - every block's bit is set and nothing else names it (the deferred
 *     leak set: the same evidence the leak clear acts on, so a kept
 *     block is one the clear would otherwise have freed);
 *   - the logical range is inside the range the index advertises, and
 *     overlaps neither the file's other extents nor an entry kept before;
 *   - the entry lies inside one 512-byte sector (one that crosses a
 *     boundary can be half of each of two images, every field plausible).
 * Anything else becomes a hole. A wrong keep can at worst hand the file
 * a block nobody owns; it can never share one. The salvage runs only
 * when nothing blocked repair -- an unreplayed journal entry included,
 * so a leaf a mount would redo is never touched.
 */
struct fsck_salvage {
    uint64_t ino, lba, rlo, rhi;
    struct fsck_lrun *lruns; /* the file's other logical runs */
    size_t nlruns;
    int has_lruns;
};
static struct fsck_salvage *fsck_salv;
static size_t fsck_nsalv, fsck_salv_cap;

static int fsck_leaf_salvageable(const uint8_t *blk)
{
    const cetrafs_blk_tail_t *t = (const cetrafs_blk_tail_t *) (blk + CETRAFS_BLK_TAIL_OFF);
    const cetrafs_extent_hdr_t *h = (const cetrafs_extent_hdr_t *) blk;

    return cetrafs_le32(t->magic) == CETRAFS_LEAF_TAIL_MAGIC && cetrafs_le16(h->eh_magic) == CETRAFS_EXT_MAGIC;
}

/* Only with -r, only a live regular file, only a block still a leaf. */
static int fsck_salvage_candidate(const cetrafs_inode_t *in, const uint8_t *blk)
{
    return repair_mode && !fsck_dead_walk && in->nlink && (cetrafs_le32(in->mode) & 0170000u) == 0100000u &&
           fsck_leaf_salvageable(blk);
}

static void fsck_salvage_note(uint64_t ino, uint64_t lba, uint64_t rlo, uint64_t rhi)
{
    if (fsck_nsalv == fsck_salv_cap) {
        fsck_salv_cap = fsck_salv_cap ? fsck_salv_cap * 2 : 8;
        fsck_salv = (struct fsck_salvage *) realloc(fsck_salv, fsck_salv_cap * sizeof(*fsck_salv));
        if (!fsck_salv) {
            perror("realloc");
            exit(FSCK_EXIT_NOEXAM);
        }
    }
    fsck_salv[fsck_nsalv++] = (struct fsck_salvage) {ino, lba, rlo, rhi, NULL, 0, 0};
}

/* At the end of an inode's walk: its candidates learn its other runs. */
static void fsck_salvage_attach_lruns(uint64_t ino)
{
    for (size_t s = 0; s < fsck_nsalv; s++) {
        if (fsck_salv[s].ino != ino || fsck_salv[s].has_lruns)
            continue;
        fsck_salv[s].has_lruns = 1;
        if (!fsck_nlruns)
            continue;
        fsck_salv[s].lruns = (struct fsck_lrun *) malloc(fsck_nlruns * sizeof(*fsck_lruns));
        if (!fsck_salv[s].lruns) {
            perror("malloc");
            exit(FSCK_EXIT_NOEXAM);
        }
        memcpy(fsck_salv[s].lruns, fsck_lruns, fsck_nlruns * sizeof(*fsck_lruns));
        fsck_salv[s].nlruns = fsck_nlruns;
    }
}

static int fsck_lrange_overlaps(const struct fsck_lrun *r, size_t n, uint64_t lo, uint64_t hi)
{
    for (size_t i = 0; i < n; i++)
        if (lo < r[i].hi && r[i].lo < hi)
            return 1;
    return 0;
}

/* Returns the number of leaves rewritten. 'leakd' loses the blocks kept. */
static uint64_t fsck_salvage_leaves(int fd, const uint64_t *bg_start, const uint64_t *bg_cnt, uint32_t nbg,
                                    uint8_t *leakd, uint64_t *leak_deferred)
{
    uint64_t rewritten = 0;

    for (size_t s = 0; s < fsck_nsalv; s++) {
        struct fsck_salvage *c = &fsck_salv[s];
        uint8_t blk[CETRAFS_BLOCK_SIZE];
        cetrafs_extent_hdr_t *h = (cetrafs_extent_hdr_t *) blk;
        cetrafs_extent_t *arr = (cetrafs_extent_t *) (blk + sizeof(*h));
        cetrafs_extent_t kept[CETRAFS_EXT_BLOCK_MAX_LEAVES];
        struct fsck_lrun kr[CETRAFS_EXT_BLOCK_MAX_LEAVES];
        cetrafs_blk_tail_t tail;
        uint32_t n, nk = 0;
        uint64_t holes = 0;

        pread_all(fd, blk, sizeof(blk), (off_t) c->lba * CETRAFS_BLOCK_SIZE);
        if (!fsck_leaf_salvageable(blk) || fsck_check_tail(blk, CETRAFS_LEAF_TAIL_MAGIC) == 0)
            continue; /* changed since the walk: nothing else writes offline, so never expected */
        n = cetrafs_le16(h->eh_entries) > CETRAFS_EXT_BLOCK_MAX_LEAVES ? CETRAFS_EXT_BLOCK_MAX_LEAVES
                                                                       : cetrafs_le16(h->eh_entries);
        for (uint32_t e = 0; e < n; e++) {
            const cetrafs_extent_t *x = &arr[e];
            uint64_t phys = ((uint64_t) cetrafs_le16(x->ee_start_hi) << 32) | cetrafs_le32(x->ee_start_lo);
            uint64_t len = cetrafs_le32(x->ee_len) & CETRAFS_EXT_LEN_MASK;
            uint64_t eb = cetrafs_le32(x->ee_block), base = 0, idx0;
            /* An entry that crosses a 512-byte sector boundary can be
             * half one image and half another -- a tear, or one damaged
             * sector -- and each half looks valid: a logical block from
             * one sector and a physical run from the next made the
             * salvaged file read block 188's bytes at offset 0. Every
             * other entry lies in one sector, so it is wholly old or
             * wholly new, and a real extent either way. */
            size_t off = sizeof(*h) + (size_t) e * sizeof(*x);
            int straddles = off / 512 != (off + sizeof(*x) - 1) / 512;
            int ok = !straddles && len && eb + len <= CETRAFS_MAX_FILE_BLOCKS &&
                     (!c->rhi || (eb >= c->rlo && eb + len <= c->rhi));
            int b = ok ? fsck_run_bg(bg_start, bg_cnt, nbg, phys, len, &base) : -1;

            if (b >= 0) {
                idx0 = base + (phys - bg_start[b]);
                for (uint64_t k = 0; k < len && ok; k++)
                    ok = FSCK_GET(leakd, idx0 + k) != 0;
            } else {
                ok = 0;
            }
            if (ok && (fsck_lrange_overlaps(c->lruns, c->nlruns, eb, eb + len) ||
                       fsck_lrange_overlaps(kr, nk, eb, eb + len)))
                ok = 0;
            if (!ok) {
                if (len && len <= CETRAFS_MAX_FILE_BLOCKS)
                    holes += len;
                continue;
            }
            for (uint64_t k = 0; k < len; k++)
                FSCK_CLR(leakd, idx0 + k);
            *leak_deferred -= len;
            kept[nk] = *x;
            kr[nk].lo = eb;
            kr[nk].hi = eb + len;
            nk++;
        }

        memset(blk + sizeof(*h), 0, CETRAFS_BLK_TAIL_OFF - sizeof(*h));
        memcpy(arr, kept, nk * sizeof(*kept));
        h->eh_entries = cetrafs_cpu_to_le16((uint16_t) nk);
        tail.magic = cetrafs_cpu_to_le32(CETRAFS_LEAF_TAIL_MAGIC);
        tail.crc = cetrafs_cpu_to_le32(crc32c_update(0, blk, CETRAFS_BLK_TAIL_OFF));
        memcpy(blk + CETRAFS_BLK_TAIL_OFF, &tail, sizeof(tail));
        if (fsck_check_tail(blk, CETRAFS_LEAF_TAIL_MAGIC) != 0) {
            fprintf(stderr, "ERR: inode %" PRIu64 "'s salvaged leaf (block %" PRIu64 ") would not verify -- left as is\n",
                    c->ino, c->lba);
            continue;
        }
        pwrite_all(fd, blk, sizeof(blk), (off_t) c->lba * CETRAFS_BLOCK_SIZE);
        rewritten++;
        printf("  salvaged inode %" PRIu64 "'s extent leaf (block %" PRIu64 "): kept %u of %u extent(s); %" PRIu64
               " logical block(s) of it now read as holes\n",
               c->ino, c->lba, nk, n, holes);
    }
    return rewritten;
}

static void fsck_salvage_free(void)
{
    for (size_t s = 0; s < fsck_nsalv; s++)
        free(fsck_salv[s].lruns);
    free(fsck_salv);
    fsck_salv = NULL;
    fsck_nsalv = fsck_salv_cap = 0;
}

int main(int argc, char **argv)
{
    const char *dev = NULL;

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "-r") || !strcmp(argv[i], "--repair"))
            repair_mode = 1;
        else if (argv[i][0] == '-') {
            fprintf(stderr, "unknown option %s\n", argv[i]);
            dev = NULL;
            break;
        } else if (!dev)
            dev = argv[i];
        else
            dev = NULL, i = argc;
    }
    if (!dev) {
        fprintf(stderr, "Usage: %s [-r] <blockdev>\n", argv[0]);
        fprintf(stderr, "  -r, --repair   fix the faults that have one derivable answer\n");
        fprintf(stderr, "                 (bitmap bits, cached free counts, link counts).\n");
        fprintf(stderr, "                 Never touches cross-file overlap, unreachable inodes\n");
        fprintf(stderr, "                 or dangling entries -- those are reported, not guessed.\n");
        fprintf(stderr, "exit: 0 clean, 1 problems found, 2 usage, 3 could not examine the device\n");
        return FSCK_EXIT_USAGE;
    }

    /* Safety first: never check a device a kernel on this system is
     * concurrently mutating -- see devutil.h. */
    {
        char where[4096];

        if (cetrafs_device_mounted(dev, where, sizeof(where))) {
            fprintf(stderr, "ERR: %s is mounted on %s -- unmount it first\n", dev, where);
            return FSCK_EXIT_NOEXAM;
        }
    }

    int fd = open(dev, (repair_mode ? O_RDWR : O_RDONLY) | O_CLOEXEC);
    if (fd < 0) {
        perror("open");
        return FSCK_EXIT_NOEXAM;
    }

    unsigned long long dev_bytes = 0;
    if (ioctl(fd, BLKGETSIZE64, &dev_bytes) < 0)
        diex("BLKGETSIZE64");
    uint64_t total_blocks = dev_bytes / CETRAFS_BLOCK_SIZE;

    /* SB */
    uint8_t sbblk[CETRAFS_BLOCK_SIZE] = {0};
    pread_all(fd, sbblk, sizeof(sbblk), 0);
    cetrafs_superblock_t sb;
    memcpy(&sb, sbblk, sizeof(sb));
    if (cetrafs_le32(sb.magic) != (uint32_t) CETRAFS_MAGIC) {
        fprintf(stderr, "ERR: bad magic\n");
        return 1;
    }

    /* The repair claim and the live-peer check come AFTER the
     * superblock is proven sound (below the layout checks): both read
     * and write registry rows at node_table_start + row, straight off
     * this superblock, and a claim aimed by a damaged one wrote a row --
     * and on exit a row of zeros -- into whatever the field named. */
    if (cetrafs_le32(sb.block_size) != (uint32_t) CETRAFS_BLOCK_SIZE) {
        fprintf(stderr, "ERR: block_size != %u\n", CETRAFS_BLOCK_SIZE);
        return 1;
    }
    uint64_t expect_min = 1 + cetrafs_le32(sb.zone_group_count) + cetrafs_le32(sb.block_group_count); /* bg table size */
    if (total_blocks < expect_min) {
        fprintf(stderr, "ERR: device smaller than metadata\n");
        return 1;
    }

    /* The same two refusals fs.c's fill_super() makes. fsck checked
     * neither, so a volume the kernel will not mount reported CLEAN --
     * which leaves the operator with a filesystem that fails to mount
     * and a checker that says nothing is wrong. Whatever stops a mount
     * has to be something this tool can name.
     *
     * total_blocks is not merely informational: the kernel refuses a
     * superblock claiming more of the device than exists, because every
     * allocation near the end would then be written past it. */
    if (cetrafs_le64(sb.total_blocks) > total_blocks) {
        fprintf(stderr,
                "ERR: superblock claims %" PRIu64 " blocks but the device holds %" PRIu64
                " -- it will not mount\n",
                (uint64_t) cetrafs_le64(sb.total_blocks), total_blocks);
        return 1;
    }
    /* From here on the VOLUME bounds the layout, as it does at mount
     * (cetrafs_validate_layout()) and on every I/O
     * (cetrafs_lba_run_is_data()). A device larger than its volume is
     * normal -- grown, not yet grown into -- and bounding by the device
     * passed a layout running past total_blocks that the mount refuses
     * (audit 2026-11-06 L25). */
    total_blocks = cetrafs_le64(sb.total_blocks);
    /*
     * fsck checked every structure in this filesystem except which
     * VERSION of the filesystem it was looking at. A build handed a
     * layout it does not understand reports the differences as damage,
     * which is the worst possible answer from the tool an operator asks
     * whether a volume is sound -- and the reason the 0x0008 -> 0x0009
     * step exists at all (cetrafs.h). Checked here, in the same place
     * and the same way the kernel checks it at mount.
     */
    if (cetrafs_le16(sb.version) < CETRAFS_VERSION_MIN || cetrafs_le16(sb.version) > CETRAFS_VERSION) {
        fprintf(stderr, "ERR: format version 0x%04X: this build accepts 0x%04X..0x%04X\n",
                (unsigned) cetrafs_le16(sb.version), (unsigned) CETRAFS_VERSION_MIN, (unsigned) CETRAFS_VERSION);
        return 1;
    }

    if (cetrafs_le64(sb.features_incompat) & ~CETRAFS_KNOWN_INCOMPAT) {
        fprintf(stderr,
                "ERR: unsupported INCOMPAT feature bits 0x%" PRIx64
                " -- this volume was written by something newer; it will not mount\n",
                (uint64_t) (cetrafs_le64(sb.features_incompat) & ~CETRAFS_KNOWN_INCOMPAT));
        return 1;
    }
    if (cetrafs_le64(sb.features_ro_compat) & ~CETRAFS_KNOWN_RO_COMPAT)
        fprintf(stderr,
                "WARN: unsupported RO_COMPAT feature bits 0x%" PRIx64 " -- this volume mounts read-only only\n",
                (uint64_t) (cetrafs_le64(sb.features_ro_compat) & ~CETRAFS_KNOWN_RO_COMPAT));

    uint32_t sb_crc = crc32c_struct(&sb, sizeof(sb), offsetof(cetrafs_superblock_t, checksum), sizeof(sb.checksum));
    if ((uint32_t) cetrafs_le64(sb.checksum) != sb_crc) {
        fprintf(stderr, "ERR: SB CRC mismatch (got 0x%08X want 0x%08X)\n", (uint32_t) cetrafs_le64(sb.checksum), sb_crc);
        return 1;
    }

    /*
     * The field checks fs.c's fill_super() makes before it looks at the
     * region map, same order. fsck had only some of them, so a volume
     * the kernel refuses to mount -- no Zone Groups, a Block Group too
     * small to hold its own bitmap, more inodes than records -- was
     * walked by code that divides by, indexes with and loops over these
     * very counts, and could be reported CLEAN.
     */
    {
        uint64_t zg = cetrafs_le32(sb.zone_group_count), bgs = cetrafs_le32(sb.block_group_count);
        uint64_t bgsz = cetrafs_le64(sb.bg_size_blocks), inodes = cetrafs_le32(sb.inodes_count);

        if (!zg || zg > CETRAFS_MAX_ZONE_GROUPS) {
            fprintf(stderr, "ERR: zone_group_count %" PRIu64 " (1..%u) -- it will not mount\n", zg,
                    CETRAFS_MAX_ZONE_GROUPS);
            return 1;
        }
        if (!bgs) {
            fprintf(stderr, "ERR: block_group_count 0 -- it will not mount\n");
            return 1;
        }
        if (bgsz < 64 || bgsz > CETRAFS_MAX_BG_SIZE_BLOCKS) {
            fprintf(stderr, "ERR: bg_size_blocks %" PRIu64 " (64..%llu) -- it will not mount\n", bgsz,
                    (unsigned long long) CETRAFS_MAX_BG_SIZE_BLOCKS);
            return 1;
        }
        if (!cetrafs_le64(sb.inode_bmap_blocks) || !cetrafs_le64(sb.inode_table_blocks)) {
            fprintf(stderr, "ERR: inode bitmap or inode table has no blocks (inode_bmap_blocks %" PRIu64
                            ", inode_table_blocks %" PRIu64 ") -- it will not mount\n",
                    (uint64_t) cetrafs_le64(sb.inode_bmap_blocks), (uint64_t) cetrafs_le64(sb.inode_table_blocks));
            return 1;
        }
        if (!inodes || inodes >= UINT32_MAX || inodes > cetrafs_le64(sb.inode_table_blocks)) {
            fprintf(stderr, "ERR: inodes_count %" PRIu64 " does not fit its table (%" PRIu64
                            " blocks, one record each) -- it will not mount\n",
                    inodes, (uint64_t) cetrafs_le64(sb.inode_table_blocks));
            return 1;
        }
        if (!cetrafs_le32(sb.node_table_count) || cetrafs_le32(sb.node_table_count) > cetrafs_le64(sb.node_table_blocks)) {
            fprintf(stderr, "ERR: node_table_count %u does not fit node_table_blocks %" PRIu64 " -- it will not mount\n",
                    cetrafs_le32(sb.node_table_count), (uint64_t) cetrafs_le64(sb.node_table_blocks));
            return 1;
        }
        if (cetrafs_le32(sb.node_entry_size) < sizeof(cetrafs_node_entry_t)) {
            fprintf(stderr, "ERR: node_entry_size %u < %zu -- it will not mount\n", cetrafs_le32(sb.node_entry_size),
                    sizeof(cetrafs_node_entry_t));
            return 1;
        }
    }

    /*
     * The region MAP, not just the bytes that describe it.
     *
     * A checksum proves the superblock was written intact; it says
     * nothing about whether what it says is possible. Every region
     * start below is used directly as a write target -- a superblock
     * claiming `inode_table_start = 1` makes every file creation
     * overwrite a Zone Group record, and 0 makes it overwrite the
     * superblock -- so a wrong-but-correctly-checksummed map is a
     * formatting gun, not a reading error.
     *
     * The kernel refuses such a volume at mount (fs.c's
     * cetrafs_validate_layout()). fsck did not check it at all: it
     * walked on and reported whatever downstream symptom appeared
     * first, so an inode table pointing at block 0 was announced as
     * "root is not a dir". That is a misleading answer from the one
     * tool an operator asks whether a volume is sound. Same checks,
     * same order, so both agree about what is mountable.
     */
    /* Before the regions, as the mount does: the bound is the format's
     * (cetrafs.h), not this device's. */
    if (cetrafs_le32(sb.node_journal_blocks) > CETRAFS_JOURNAL_MAX_BLOCKS) {
        fprintf(stderr, "ERR: per-node journal of %u blocks exceeds the format's %u\n",
                cetrafs_le32(sb.node_journal_blocks), CETRAFS_JOURNAL_MAX_BLOCKS);
        return 1;
    }
    {
        struct {
            const char *name;
            uint64_t start, count;
        } r[10];
        unsigned n = 0, i, j;
        uint64_t zg_cnt = cetrafs_le32(sb.zone_group_count), bg_cnt = cetrafs_le32(sb.block_group_count);

        r[n++] = (typeof(r[0])) {"superblock", 0, 1};
        r[n++] = (typeof(r[0])) {"zone group table", cetrafs_le64(sb.zg_table_start), zg_cnt};
        /* the FIRST SEGMENT only. The Block Group table is a chain: the run at
         * bg_table_start holds bg_table_first_count descriptors and the rest
         * live in appended segments elsewhere, so block_group_count stopped
         * being this region's length the moment a volume was grown
         * (docs/internal/BG-OWNERSHIP-DESIGN.md). */
        {
            uint64_t first = cetrafs_le64(sb.bg_table_first_count);

            if (!first || first > bg_cnt)
                first = bg_cnt; /* never grown */
            r[n++] = (typeof(r[0])) {"block group table", cetrafs_le64(sb.bg_table_start), first};
        }
        r[n++] = (typeof(r[0])) {"inode bitmap", cetrafs_le64(sb.inode_bmap_start), cetrafs_le64(sb.inode_bmap_blocks)};
        r[n++] = (typeof(r[0])) {"inode table", cetrafs_le64(sb.inode_table_start), cetrafs_le64(sb.inode_table_blocks)};
        r[n++] = (typeof(r[0])) {"node registry", cetrafs_le64(sb.node_table_start), cetrafs_le64(sb.node_table_blocks)};
        r[n++] = (typeof(r[0])) {"pending-free queues", cetrafs_le64(sb.pending_free_start),
                                 zg_cnt * (uint64_t) cetrafs_le32(sb.pending_free_blocks_per_zg)};
        r[n++] = (typeof(r[0])) {"per-node journals", cetrafs_le64(sb.node_journal_start),
                                 (uint64_t) cetrafs_le32(sb.node_table_count) * cetrafs_le32(sb.node_journal_blocks)};
        /* Bounding box, not a computed span, once a grow has left a
         * hole where a superseded tail reserve was (cetrafs.h). */
        {
            uint64_t data_start = cetrafs_le64(sb.bg_regions_start);
            uint64_t data_end = cetrafs_le64(sb.bg_data_end);

            if (!data_end)
                data_end = data_start + bg_cnt * cetrafs_le64(sb.bg_size_blocks);
            if (data_end < data_start) {
                fprintf(stderr, "ERR: layout: bg_data_end (%" PRIu64 ") precedes bg_regions_start (%" PRIu64 ")\n",
                        data_end, data_start);
                return 1;
            }

            /*
             * The box must be at least big enough to HOLD its Block Groups.
             *
             * This is what the old contiguous-span model gave for free and
             * the bounding box silently gave up: with the span, a carve
             * placed one BG too low made the computed span reach past the
             * tables and the overlap test caught it. The box is derived
             * from the same carve, so a low carve just produces a smaller
             * box that still "contains" its overlapping BGs -- and mounts.
             * A grow test injecting exactly that found this.
             *
             * A hole only ever makes the box LARGER than the sum of its
             * BGs, never smaller, so >= is the honest invariant. O(1), from
             * the superblock alone: no BG table scan on the mount path.
             */
            if (data_end - data_start < bg_cnt * cetrafs_le64(sb.bg_size_blocks)) {
                fprintf(stderr,
                        "ERR: layout: data area [%" PRIu64 ",%" PRIu64 ") is too small for %" PRIu64
                        " Block Group(s) of %" PRIu64 " blocks\n",
                        data_start, data_end, bg_cnt, (uint64_t) cetrafs_le64(sb.bg_size_blocks));
                return 1;
            }
            r[n++] = (typeof(r[0])) {"block group regions", data_start, data_end - data_start};
        }

        /* A legitimately absent region (a zero-sized journal, no
         * pending-free reservation) is dropped rather than read as an
         * overlap with the superblock at block 0. */
        for (i = 0; i < n;) {
            if (r[i].count == 0) {
                r[i] = r[--n];
                continue;
            }
            if (r[i].start == 0 && i != 0) {
                fprintf(stderr, "ERR: layout: %s starts at block 0 (the superblock itself)\n", r[i].name);
                return 1;
            }
            if (r[i].count > total_blocks || r[i].start > total_blocks - r[i].count) {
                fprintf(stderr, "ERR: layout: %s [%" PRIu64 ",+%" PRIu64 ") does not fit in total_blocks=%" PRIu64 "\n",
                        r[i].name, r[i].start, r[i].count, total_blocks);
                return 1;
            }
            i++;
        }
        for (i = 1; i < n; i++) { /* insertion sort by start */
            typeof(r[0]) key = r[i];

            for (j = i; j > 0 && r[j - 1].start > key.start; j--)
                r[j] = r[j - 1];
            r[j] = key;
        }
        for (i = 1; i < n; i++) {
            if (r[i].start < r[i - 1].start + r[i - 1].count) {
                fprintf(stderr, "ERR: layout: %s [%" PRIu64 ",+%" PRIu64 ") overlaps %s [%" PRIu64 ",+%" PRIu64 ")\n",
                        r[i].name, r[i].start, r[i].count, r[i - 1].name, r[i - 1].start, r[i - 1].count);
                return 1;
            }
        }

        /* And the three fields a reader simply trusts. The kernel
         * checks these at mount; fsck reported such a volume CLEAN. */
        if (cetrafs_le16(sb.sb_bytes) != sizeof(cetrafs_superblock_t)) {
            fprintf(stderr, "ERR: layout: sb_bytes %u != sizeof(superblock) %zu\n", (unsigned) cetrafs_le16(sb.sb_bytes),
                    sizeof(cetrafs_superblock_t));
            return 1;
        }
        /* The ON-DISK record size (two sectors), not sizeof(): the
         * in-core struct omits the file sector's zero tail. */
        if (cetrafs_le32(sb.inode_size) != CETRAFS_INODE_ONDISK_SIZE) {
            fprintf(stderr, "ERR: layout: inode_size %u != sizeof(inode) %zu\n", (unsigned) cetrafs_le32(sb.inode_size),
                    (size_t) CETRAFS_INODE_ONDISK_SIZE);
            return 1;
        }
        if (cetrafs_le64(sb.root_ino) == 0 || cetrafs_le64(sb.root_ino) > cetrafs_le32(sb.inodes_count)) {
            fprintf(stderr, "ERR: layout: root_ino %" PRIu64 " is outside the inode table (1..%u)\n",
                    (uint64_t) cetrafs_le64(sb.root_ino), cetrafs_le32(sb.inodes_count));
            return 1;
        }
        if (cetrafs_le32(sb.inodes_count) > cetrafs_le64(sb.inode_bmap_blocks) * CETRAFS_BLOCK_SIZE * 8) {
            fprintf(stderr, "ERR: layout: inodes_count %u exceeds the %" PRIu64 " bits in its bitmap\n",
                    cetrafs_le32(sb.inodes_count), (uint64_t) cetrafs_le64(sb.inode_bmap_blocks) * CETRAFS_BLOCK_SIZE * 8);
            return 1;
        }
        if (cetrafs_le32(sb.node_table_count) > CETRAFS_MAX_READER_NODES) {
            fprintf(stderr,
                    "ERR: layout: node_table_count %u exceeds CETRAFS_MAX_READER_NODES (%u) -- row %u would "
                    "alias row 0 in the read-presence mask\n",
                    sb.node_table_count, CETRAFS_MAX_READER_NODES, CETRAFS_MAX_READER_NODES);
            return 1;
        }
    }

    /*
     * Claim the volume before anything is written to it -- and only
     * once the superblock that says WHERE the claim goes has passed every
     * check above (CRC, fields, layout). The claim writes a row at
     * node_table_start + row and its release zeroes it; claimed from an
     * unchecked superblock, one flipped bit in node_table_start put both
     * into file data on exactly the damaged volume fsck was run on.
     *
     * The check below refuses to run against a volume a NODE has
     * mounted. This is the other direction, which nothing covered: a
     * node mounting halfway through `-r` finds structures being
     * rewritten under it by minutes of blind full-block writes. The
     * claim is a Node Registry row in CETRAFS_NODE_STATE_REPAIR, which
     * fill_super() refuses to mount past, and it is a lease -- renewed
     * as the passes run, expiring on its own if this process dies.
     *
     * BEFORE the live-peer check, not after, and the order is the
     * whole point: check-then-claim leaves the window between them
     * open, and a node mounting inside it sees no claim and is let in.
     * Claiming first means such a node is refused, and the check that
     * follows catches the peer that was already there -- in which case
     * this run bails and the row is released on the way out.
     */
    if (repair_mode) {
        uint32_t other_row = 0;
        char other[CETRAFS_NODE_LABEL_LEN + 1] = {0};
        int busy = cetrafs_find_repair_claim(fd, &sb, &other_row, other, sizeof(other));

        if (busy < 0) {
            fprintf(stderr, "ERR: %s: cannot read its Node Registry -- refusing to repair blind\n", dev);
            return FSCK_EXIT_NOEXAM;
        }
        if (busy) {
            fprintf(stderr, "ERR: %s is already being repaired (registry row %u%s%s)\n", dev, other_row,
                    other[0] ? ", " : "", other[0] ? other : "");
            return FSCK_EXIT_NOEXAM;
        }

        repair_row = cetrafs_repair_claim(fd, &sb, "fsck -r");
        if (repair_row == -2) {
            fprintf(stderr, "ERR: %s: another repair claimed this volume at the same time -- stopping\n", dev);
            return FSCK_EXIT_NOEXAM;
        }
        if (repair_row == -3) {
            fprintf(stderr, "ERR: %s: the superblock changed while this repair claimed the volume -- run it again\n",
                    dev);
            return FSCK_EXIT_NOEXAM;
        }
        if (repair_row < 0) {
            fprintf(stderr,
                    "ERR: %s: no free Node Registry row to claim for the repair -- refusing to\n"
                    "     write while a node could still mount it\n",
                    dev);
            return FSCK_EXIT_NOEXAM;
        }
        repair_fd = fd;
        repair_sb = sb;
        atexit(fsck_repair_release_atexit);
        printf("  claimed registry row %d for the duration of this repair\n", repair_row);
        fflush(stdout);
        /* Test knob only: a phase that does no inode work for this long,
         * so a suite can see the claim renew on its timer regardless.
         * Unset in every normal invocation. */
        if (getenv("CETRAFS_TEST_REPAIR_HOLD_SECS"))
            cetrafs_sleep_full((unsigned) atoi(getenv("CETRAFS_TEST_REPAIR_HOLD_SECS")));
    }

    {
        char label[CETRAFS_NODE_LABEL_LEN + 1] = {0};
        long long age = 0;
        uint32_t row = 0;

        /* Same reasoning one level out: a peer mutating this volume
         * while we walk it produces invented "errors", and a clean
         * result would be just as meaningless. See devutil.h. */
        int lp = cetrafs_find_live_peer(dev, &row, label, sizeof(label), &age);

        if (lp < 0) {
            fprintf(stderr,
                    "ERR: %s: cannot read its Node Registry (I/O error) -- unable to prove no\n"
                    "     other node has it mounted, so neither a verdict nor a repair would\n"
                    "     mean anything. Fix the device and retry.\n",
                    dev);
            return 3; /* could not examine, same class as an unopenable device */
        }
        if (lp) {
            fprintf(stderr,
                    "ERR: %s is mounted by another node (registry row %u%s%s, last seen %llds ago)\n"
                    "     -- its structures are being modified as we read them. Unmount it there;\n"
                    "     its row goes stale after %ds.\n",
                    dev, row, label[0] ? ", " : "", label[0] ? label : "", age, CETRAFS_NODE_STALE_SECS);
            return 1;
        }
    }

    /* ZG table. Also records each ZG's (first_bg_id, bg_count,
     * free_data_blocks) for the ZG<->BG ownership cross-checks below
     *: every ZG must claim a contiguous, non-overlapping
     * span of BG ids starting at 0 and covering all of them. (The
     * counts themselves are checked against the bitmaps by the content
     * pass, never cache-against-cache here -- see below.) */
    uint32_t *zg_owner = (uint32_t *) xcalloc(cetrafs_le32(sb.zone_group_count), sizeof(uint32_t));

    for (uint32_t z = 0; z < cetrafs_le32(sb.zone_group_count); ++z) {
        uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
        pread_all(fd, blk, sizeof(blk), (off_t) (cetrafs_le64(sb.zg_table_start) + z) * CETRAFS_BLOCK_SIZE);
        cetrafs_zone_group_t zg;
        memcpy(&zg, blk, sizeof(zg));
        if (cetrafs_le16(zg.zg_id) != (uint16_t) z) {
            fprintf(stderr, "ERR: ZG id %u != %u\n", zg.zg_id, z);
            return 1;
        }
        /* v0x0008: hot sector and cold remainder are checksummed
         * independently (cetrafs.h) -- verify both. */
        uint32_t zhot =
            crc32c_struct((const uint8_t *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                          offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF, sizeof(zg.hot_checksum));
        if ((uint32_t) cetrafs_le64(zg.hot_checksum) != zhot) {
            fprintf(stderr, "ERR: ZG%u hot-sector CRC mismatch\n", z);
            return 1;
        }
        uint32_t zcold = crc32c_struct((const uint8_t *) &zg + CETRAFS_ZG_COLD_OFF, CETRAFS_ZG_COLD_LEN,
                                       offsetof(cetrafs_zone_group_t, cold_checksum) - CETRAFS_ZG_COLD_OFF,
                                       sizeof(zg.cold_checksum));
        if ((uint32_t) cetrafs_le64(zg.cold_checksum) != zcold) {
            fprintf(stderr, "ERR: ZG%u cold-region CRC mismatch\n", z);
            return 1;
        }
        /* No span to check. A Zone Group no longer says which Block
         * Groups are its members; the Block Groups say so themselves,
         * and that mapping is validated below once they have been read
         * (docs/internal/BG-OWNERSHIP-DESIGN.md). What used to be
         * checked here -- that the spans were in range, contiguous, and
         * tiled the whole Block Group space -- was a property of how
         * mkfs laid them out, not of the format. */
        zg_owner[z] = cetrafs_le16(zg.owner_node_id);
    }

    /* Which Zone Group owns each Block Group, read from the Block
     * Groups. Filled by the BG table pass below, which is the only
     * thing that knows. */
    uint32_t *bg_owner_expected = (uint32_t *) xcalloc(cetrafs_le32(sb.block_group_count), sizeof(uint32_t));
    /* What each ZG's aggregate SHOULD be, accumulated in the content
     * pass from the bitmaps themselves rather than from the cached
     * per-BG numbers -- so a repair rebuilds it from the truth even
     * when several BG counters were wrong. */
    uint64_t *zg_free_truth = (uint64_t *) xcalloc(cetrafs_le32(sb.zone_group_count), sizeof(uint64_t));
    /* What each ZG record's pool_free_blocks SHOULD be: the capacity of
     * every UNOWNED Block Group sharded to it (bg %% zone_group_count --
     * the mkfs assignment mapping, reused as the shard key). */
    uint64_t *zg_pool_truth = (uint64_t *) xcalloc(cetrafs_le32(sb.zone_group_count), sizeof(uint64_t));

    /* Per-BG geometry, kept for the content passes at the end of main()
     * (extent overlap, bitmap-vs-reachability). Those need to map a
     * block LBA back to the BG and bitmap bit that should describe it. */
    uint64_t *bg_data_start = (uint64_t *) xcalloc(cetrafs_le32(sb.block_group_count), sizeof(uint64_t));
    uint64_t *bg_data_cnt = (uint64_t *) xcalloc(cetrafs_le32(sb.block_group_count), sizeof(uint64_t));
    uint64_t *bg_bmap_lba = (uint64_t *) xcalloc(cetrafs_le32(sb.block_group_count), sizeof(uint64_t));
    /* Each BG's CACHED free count, kept so pass 3 can compare it against
     * what that BG's bitmap actually says -- see the check there. */
    uint64_t *bg_free_cached = (uint64_t *) xcalloc(cetrafs_le32(sb.block_group_count), sizeof(uint64_t));

    /*
     * Where each Block Group's descriptor actually lives.
     *
     * The table is a chain: the run at bg_table_start holds
     * bg_table_first_count descriptors, and growing APPENDS segments
     * rather than moving anything, so `bg_table_start + b` is right
     * only for the first segment's ids
     * (docs/internal/BG-OWNERSHIP-DESIGN.md). Resolved once here, with
     * the chain validated as it is walked -- a loop, a bad magic or a
     * short chain is corruption and is reported as such.
     */
    uint64_t *bg_desc_lba = (uint64_t *) xcalloc(cetrafs_le32(sb.block_group_count), sizeof(uint64_t));
    fsck_g_sb = &sb;
    fsck_g_bg_desc_lba = bg_desc_lba;
    /* Each appended segment's [header, last descriptor], checked against
     * the Block Groups once their descriptors are read (as fs.c does). */
    uint64_t *seg_lo = (uint64_t *) xcalloc(cetrafs_le32(sb.block_group_count) + 1, sizeof(uint64_t));
    uint64_t *seg_hi = (uint64_t *) xcalloc(cetrafs_le32(sb.block_group_count) + 1, sizeof(uint64_t));
    uint32_t nsegs = 0;
    {
        uint32_t nbg = cetrafs_le32(sb.block_group_count), filled = 0, guard = 0;
        uint64_t first = cetrafs_le64(sb.bg_table_first_count);
        uint64_t seg_lba = cetrafs_le64(sb.bg_table_next);

        if (!first || first > nbg)
            first = nbg; /* never grown */
        for (uint32_t b = 0; b < first && b < nbg; b++)
            bg_desc_lba[b] = cetrafs_le64(sb.bg_table_start) + b;
        filled = (uint32_t) first;

        /* The WHOLE chain, not just until enough descriptors have been
         * collected. Stopping at `filled == nbg` never follows the
         * tail's `next`, so a chain that loops, or whose last link
         * points past the volume or into metadata, read as clean --
         * three injections that this check missed until they were
         * actually tried. A dangling tail is corruption even when every
         * descriptor is accounted for. */
        while (seg_lba) {
            cetrafs_bg_segment_t seg;

            if (++guard > nbg + 1) {
                fprintf(stderr, "ERR: Block Group table chain does not terminate\n");
                return 1;
            }
            if (seg_lba >= total_blocks) {
                fprintf(stderr, "ERR: Block Group table segment at %" PRIu64 " is past the end of the volume\n",
                        seg_lba);
                if (filled == nbg)
                    fprintf(stderr, "ERR: (a grow was interrupted before it published -- re-run growfs.cetra)\n");
                return 1;
            }
            pread_all(fd, &seg, sizeof(seg), (off_t) seg_lba * CETRAFS_BLOCK_SIZE);
            if (cetrafs_le32(seg.magic) != CETRAFS_BGSEG_MAGIC) {
                fprintf(stderr, "ERR: Block Group table segment at %" PRIu64 " has no magic\n", seg_lba);
                return 1;
            }
            {
                uint32_t scrc = crc32c_struct(&seg, sizeof(seg), offsetof(cetrafs_bg_segment_t, checksum),
                                              sizeof(seg.checksum));
                if ((uint32_t) cetrafs_le64(seg.checksum) != scrc) {
                    fprintf(stderr, "ERR: Block Group table segment at %" PRIu64 " fails its checksum\n", seg_lba);
                    return 1;
                }
            }
            if (cetrafs_le32(seg.first_bg_id) != filled) {
                fprintf(stderr, "ERR: Block Group table segment at %" PRIu64 " starts at id %u, expected %u\n",
                        seg_lba, cetrafs_le32(seg.first_bg_id), filled);
                return 1;
            }
            /* The kernel's bounds (fs.c), BEFORE the count drives a
             * loop: a segment claiming 2^32 descriptors walked that
             * many times and wrapped `filled` -- the mount refuses it in
             * a millisecond, fsck spun on it. And where the segment and
             * its descriptors sit: a grow puts them past every fixed
             * table, inside the device. */
            if (seg_lba < cetrafs_le64(sb.bg_regions_start)) {
                fprintf(stderr, "ERR: Block Group table segment at %" PRIu64 " lies among the fixed tables "
                                "(before block %" PRIu64 ")\n",
                        seg_lba, (uint64_t) cetrafs_le64(sb.bg_regions_start));
                return 1;
            }
            if (cetrafs_le32(seg.count) > nbg - filled) {
                fprintf(stderr, "ERR: Block Group table chain describes more than the %u Block Groups recorded "
                                "(segment at %" PRIu64 " claims %u, %u left)\n",
                        nbg, seg_lba, cetrafs_le32(seg.count), nbg - filled);
                if (cetrafs_le32(seg.first_bg_id) == nbg)
                    fprintf(stderr, "ERR: (a grow was interrupted before it published -- re-run growfs.cetra)\n");
                return 1;
            }
            if (seg_lba + 1 + cetrafs_le32(seg.count) > total_blocks) {
                fprintf(stderr, "ERR: Block Group table segment at %" PRIu64 " describes blocks past the end of "
                                "the volume\n",
                        seg_lba);
                return 1;
            }
            for (uint32_t i = 0; i < cetrafs_le32(seg.count); i++, filled++)
                bg_desc_lba[filled] = seg_lba + 1 + i;
            seg_lo[nsegs] = seg_lba;
            seg_hi[nsegs++] = seg_lba + 1 + cetrafs_le32(seg.count);
            seg_lba = cetrafs_le64(seg.next);
        }
        if (filled != nbg) {
            fprintf(stderr, "ERR: Block Group table chain describes %u of %u Block Groups\n", filled, nbg);
            return 1;
        }
    }

    /* BG table & regions monotonicity */
    uint64_t next = cetrafs_le64(sb.bg_regions_start);
    for (uint64_t b = 0; b < cetrafs_le32(sb.block_group_count); ++b) {
        uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
        pread_all(fd, blk, sizeof(blk), (off_t) bg_desc_lba[b] * CETRAFS_BLOCK_SIZE);
        cetrafs_block_group_t bg;
        memcpy(&bg, blk, sizeof(bg));
        /*
         * Ordered and non-overlapping, NOT exactly adjacent.
         *
         * This used to require start_block == the end of the previous
         * BG, which made contiguity a format invariant. It is not: each
         * grow leaves a HOLE where its predecessor's tail reserve was
         * (cetrafs.h's bg_data_end), so BG N+1 legitimately begins after
         * a gap. A correctly grown volume failed here on its SECOND
         * grow -- the fourth positional assumption this feature found,
         * after the three in the region-layout block above and one in
         * the kernel's own validator.
         *
         * What actually has to hold is that no two BGs overlap and none
         * escapes the data area, and that is what is checked now.
         */
        /* Its own id, against its place in the table: the kernel
         * refuses a descriptor that names another Block Group
         * (cetrafs_bg_geom_sane()); only the header's id was checked. */
        if (cetrafs_le32(bg.bg_id) != (uint32_t) b) {
            fprintf(stderr, "ERR: BG%zu descriptor says it is Block Group %u\n", (size_t) b, cetrafs_le32(bg.bg_id));
            return 1;
        }
        if (cetrafs_le64(bg.start_block) < next) {
            fprintf(stderr,
                    "ERR: BG%zu start %" PRIu64 " overlaps the previous Block Group (which ends at %" PRIu64 ")\n",
                    (size_t) b, (uint64_t) cetrafs_le64(bg.start_block), (uint64_t) next);
            return 1;
        }
        {
            uint64_t data_end = cetrafs_le64(sb.bg_data_end);
            uint64_t bg_end = cetrafs_le64(bg.start_block) + cetrafs_le64(bg.length_blocks);

            if (!data_end)
                data_end = cetrafs_le64(sb.bg_regions_start) +
                           (uint64_t) cetrafs_le32(sb.block_group_count) * cetrafs_le64(sb.bg_size_blocks);
            if (cetrafs_le64(bg.length_blocks) > CETRAFS_MAX_BG_SIZE_BLOCKS) {
                fprintf(stderr, "ERR: BG%zu length %" PRIu64 " exceeds the format's limit of %llu blocks\n", (size_t) b,
                        (uint64_t) cetrafs_le64(bg.length_blocks), (unsigned long long) CETRAFS_MAX_BG_SIZE_BLOCKS);
                return 1;
            }
            /* No sum in the test: start and length are both off the disk,
             * and a start near 2^64 wraps start + length to a small
             * bg_end that passes (audit 2026-11-06 L26). */
            if (cetrafs_le64(bg.start_block) > data_end ||
                cetrafs_le64(bg.length_blocks) > data_end - cetrafs_le64(bg.start_block) ||
                cetrafs_le64(bg.start_block) < cetrafs_le64(sb.bg_regions_start)) {
                fprintf(stderr,
                        "ERR: BG%zu [%" PRIu64 ",+%" PRIu64 ") falls outside the data area [%" PRIu64 ",%" PRIu64 ")\n",
                        (size_t) b, (uint64_t) cetrafs_le64(bg.start_block), (uint64_t) cetrafs_le64(bg.length_blocks),
                        (uint64_t) cetrafs_le64(sb.bg_regions_start), data_end);
                return 1;
            }
            /* A segment inside a Block Group: every descriptor update
             * then writes over that group's header, bitmap or data. The
             * mount refuses it; fsck walked past it. */
            for (uint32_t si = 0; si < nsegs; si++) {
                if (seg_lo[si] < bg_end && cetrafs_le64(bg.start_block) < seg_hi[si]) {
                    fprintf(stderr,
                            "ERR: Block Group table segment [%" PRIu64 ",%" PRIu64 ") overlaps BG%zu [%" PRIu64
                            ",+%" PRIu64 ")\n",
                            seg_lo[si], seg_hi[si], (size_t) b, (uint64_t) cetrafs_le64(bg.start_block),
                            (uint64_t) cetrafs_le64(bg.length_blocks));
                    return 1;
                }
            }
        }
        if (bg.off_bg_header != 0) {
            fprintf(stderr, "ERR: BG%zu header off not 0\n", (size_t) b);
            return 1;
        }
        uint32_t off_bmap, off_data;
        uint64_t data_cnt;
        cetrafs_calc_bg_layout(cetrafs_le64(bg.length_blocks), &off_bmap, &off_data, &data_cnt);
        if (cetrafs_le32(bg.off_data_bmap) != off_bmap || cetrafs_le32(bg.off_data_region) != off_data || cetrafs_le64(bg.data_block_count) != data_cnt) {
            fprintf(stderr, "ERR: BG%zu layout mismatch\n", (size_t) b);
            return 1;
        }

        /* BG descriptor fields (including checksum) are stored
         * plain-native, not __le* like SB/ZG -- compared directly. */
        uint32_t bg_crc =
            crc32c_struct(&bg, sizeof(bg), offsetof(cetrafs_block_group_t, checksum), sizeof(bg.checksum));
        if ((uint32_t) cetrafs_le64(bg.checksum) != bg_crc) {
            fprintf(stderr, "ERR: BG%zu descriptor CRC mismatch (got 0x%08X want 0x%08X)\n", (size_t) b,
                    (uint32_t) cetrafs_le64(bg.checksum), bg_crc);
            return 1;
        }

        bg_data_start[b] = (uint64_t) cetrafs_le64(bg.start_block) + cetrafs_le32(bg.off_data_region);
        bg_data_cnt[b] = cetrafs_le64(bg.data_block_count);
        bg_bmap_lba[b] = (uint64_t) cetrafs_le64(bg.start_block) + cetrafs_le32(bg.off_data_bmap);
        bg_free_cached[b] = cetrafs_le64(bg.free_data_blocks);

        /* BG header: first block of the BG's own region (off_bg_header,
         * already checked above to be 0). */
        uint8_t hblk[CETRAFS_BLOCK_SIZE] = {0};
        pread_all(fd, hblk, sizeof(hblk), (off_t) cetrafs_le64(bg.start_block) * CETRAFS_BLOCK_SIZE);
        cetrafs_bg_header_t bh;
        memcpy(&bh, hblk, sizeof(bh));
        if (cetrafs_le32(bh.bg_id) != (uint32_t) b) {
            fprintf(stderr, "ERR: BG%zu header id %u != %zu\n", (size_t) b, bh.bg_id, (size_t) b);
            return 1;
        }
        uint32_t bh_crc = crc32c_struct(&bh, sizeof(bh), offsetof(cetrafs_bg_header_t, checksum), sizeof(bh.checksum));
        if ((uint32_t) cetrafs_le64(bh.checksum) != bh_crc) {
            fprintf(stderr, "ERR: BG%zu header CRC mismatch (got 0x%08X want 0x%08X)\n", (size_t) b,
                    (uint32_t) cetrafs_le64(bh.checksum), bh_crc);
            return 1;
        }

        /* The Block Group's own record is the authority on who owns it.
         * What can still be wrong is that it names a Zone Group that
         * does not exist -- which would leave the Block Group
         * unreachable by any node, and would index past every per-ZG
         * array below. This replaces a comparison against the Zone
         * Group spans, which no longer exist
         * (docs/internal/BG-OWNERSHIP-DESIGN.md). */
        if (cetrafs_le16(bg.owner_zg) != CETRAFS_BG_OWNER_FREE &&
            cetrafs_le16(bg.owner_zg) >= cetrafs_le32(sb.zone_group_count)) {
            fprintf(stderr, "ERR: BG%zu is owned by Zone Group %u, but only %u exist\n", (size_t) b,
                    cetrafs_le16(bg.owner_zg), cetrafs_le32(sb.zone_group_count));
            return 1;
        }
        bg_owner_expected[b] = cetrafs_le16(bg.owner_zg);

        next = cetrafs_le64(bg.start_block) + cetrafs_le64(bg.length_blocks);
    }

    /* NO structural "ZG aggregate == sum of its BGs" cross-check here any
     * more (removed). It compared two CACHES against each
     * other and returned fatally -- yet the kernel flushes the BG counts
     * and the ZG aggregate as separate compare-and-swaps, so a crash
     * between the two leaves exactly that mismatch on a perfectly healthy
     * volume, which this check then declared unrepairable BEFORE the
     * content pass could run: no repair (which derives both counts from
     * the bitmaps -- the actual truth), and no deeper detection either
     * (cross-file overlap hid behind a count hiccup). The content pass
     * checks both counts against the bitmaps unconditionally and repairs
     * them under -r, which is strictly stronger. */

    if (sb.inode_bmap_blocks == 0 || sb.inode_table_blocks == 0) {
        fprintf(stderr, "ERR: inode structures not present\n");
        return 1;
    }

    /* Node Registry: packed densely like the inode table (reuses the same
     * layout helper), so its block count must match the same formula.
     * Scan every entry: a FREE slot is untouched (no further checks --
     * nothing has ever written to it); a REGISTERED one must have a
     * valid CRC and a recognized state. mkfs never registers a node
     * itself, so on a freshly-formatted volume
     * every entry is FREE -- this check also covers a volume where real
     * nodes have since registered. */
    if (cetrafs_le64(sb.node_table_blocks) != cetrafs_calc_inode_table_blocks(cetrafs_le32(sb.node_table_count), cetrafs_le32(sb.node_entry_size))) {
        fprintf(stderr, "ERR: node table layout mismatch\n");
        return 1;
    }

    /*
     * A zero-sized pending-free queue is broken however it is placed:
     * every cross-node free would have nowhere to go.
     */
    if (cetrafs_le32(sb.pending_free_blocks_per_zg) == 0) {
        fprintf(stderr, "ERR: pending-free queue has zero blocks per ZG\n");
        return 1;
    }

    /*
     * Three adjacency checks used to live here: pending_free_start ==
     * node_table_start + node_table_blocks, node_journal_start ==
     * pending_end, and pending/journal ending before bg_regions_start.
     * All three encoded the order mkfs happens to pack the prefix in as
     * if it were an invariant of the FORMAT. It is not -- every region's
     * location is a superblock field, and a GROWN volume has relocated
     * its ZG table, BG table and pending-free region into a reserve at
     * the end of the device, leaving the journals where they were
     * (docs/internal/EXTENDFS-DESIGN.md). A correct grown volume failed
     * all three.
     *
     * Nothing is lost: the sorted pairwise overlap pass above checks
     * every region against every other and bounds each one by
     * total_blocks, which is strictly stronger than three hand-picked
     * adjacency equalities -- and it holds wherever the regions are.
     * (The kernel's cetrafs_validate_layout() carried the same mistake
     * in the shape of a `bg_regions_start >= 1+Z+B` check; both were
     * found by the same grown image.)
     */

    /*
     * The tail reserve, when a grow has created one: the relocated
     * tables must actually live inside the region the superblock claims
     * holds them. The overlap pass proves they do not collide with
     * anything; this proves the superblock's own account of itself is
     * self-consistent, so a half-written grow cannot read as clean.
     */
    if (cetrafs_le64(sb.tail_reserve_blocks)) {
        uint64_t rs = cetrafs_le64(sb.tail_reserve_start);
        uint64_t re = rs + cetrafs_le64(sb.tail_reserve_blocks);
        uint64_t head = cetrafs_le64(sb.bg_table_next);

        /*
         * The reserve holds the Block Group table segment the last grow
         * APPENDED -- nothing else. It used to hold relocated copies of
         * the Zone Group table, the whole Block Group table and the
         * pending-free region; none of those move any more, so checking
         * that they live inside it is checking something that stopped
         * being true (docs/internal/BG-OWNERSHIP-DESIGN.md).
         */
        if (re > total_blocks || rs == 0) {
            fprintf(stderr, "ERR: tail reserve [%" PRIu64 ",+%" PRIu64 ") does not fit in total_blocks=%" PRIu64 "\n",
                    rs, cetrafs_le64(sb.tail_reserve_blocks), total_blocks);
            return 1;
        }
        if (!head) {
            fprintf(stderr, "ERR: a tail reserve is recorded but the Block Group table chain is empty\n");
            return 1;
        }
    } else if (cetrafs_le64(sb.layout_gen)) {
        fprintf(stderr, "ERR: layout_gen is %" PRIu64 " but no tail reserve is recorded\n",
                cetrafs_le64(sb.layout_gen));
        return 1;
    }
    uint8_t *node_registered = (uint8_t *) xcalloc(cetrafs_le32(sb.node_table_count) ? cetrafs_le32(sb.node_table_count) : 1, 1);
    uint8_t *node_departed = (uint8_t *) xcalloc(cetrafs_le32(sb.node_table_count) ? cetrafs_le32(sb.node_table_count) : 1, 1);
    uint32_t node_free_rows = 0, node_departed_rows = 0;
    for (uint32_t n = 0; n < cetrafs_le32(sb.node_table_count); ++n) {
        cetrafs_node_entry_t ne;
        /* one row per block as of v0x0007 */
        pread_all(fd, &ne, sizeof(ne), (off_t) (cetrafs_le64(sb.node_table_start) + n) * CETRAFS_BLOCK_SIZE);
        if (ne.state == CETRAFS_NODE_STATE_FREE) {
            node_free_rows++;
            continue;
        }
        if (cetrafs_le32(ne.state) == CETRAFS_NODE_STATE_REPAIR) {
            /* An offline repairer holding the volume -- including this
             * process, which claimed a row above. It is not a node and
             * owns no Zone Groups, so it takes no further part in the
             * checks below. A STALE one left behind by a killed
             * repairer is reported: it blocks mounting until its lease
             * expires, and an operator should know why. */
            long long age = (long long) time(NULL) - (long long) cetrafs_le64(ne.last_seen);

            if ((int) n != repair_row && age > (long long) CETRAFS_NODE_STALE_SECS)
                fprintf(stderr, "WARN: node slot %u holds a repair claim last refreshed %llds ago (%.*s)\n", n, age,
                        ne.label[0] ? (int) sizeof(ne.label) : 8, ne.label[0] ? ne.label : "no label");
            continue;
        }
        if (cetrafs_le32(ne.state) != CETRAFS_NODE_STATE_REGISTERED) {
            fprintf(stderr, "ERR: node slot %u has unrecognized state %u\n", n, ne.state);
            return 1;
        }
        uint32_t ne_crc = crc32c_struct(&ne, sizeof(ne), offsetof(cetrafs_node_entry_t, checksum), sizeof(ne.checksum));
        if ((uint32_t) cetrafs_le64(ne.checksum) != ne_crc) {
            fprintf(stderr, "ERR: node slot %u CRC mismatch (got 0x%08X want 0x%08X)\n", n, (uint32_t) cetrafs_le64(ne.checksum),
                    ne_crc);
            return 1;
        }
        node_registered[n] = 1;
        if (ne.last_seen == 0) {
            node_departed[n] = 1;
            node_departed_rows++;
        }
        /* A row that registered and then stopped. fsck cannot judge
         * liveness -- it has no second sample and must never compare
         * last_seen against ITS OWN clock, which is the mistake the
         * mkfs/fsck peer probe was built to avoid (two real nodes were
         * found 1h55m apart). What it CAN say is that the row was left
         * behind rather than released: last_seen == 0 is the explicit
         * "departed cleanly" sentinel, so anything else is a node that
         * did not get to write one. Reported, never fatal: it is
         * exactly the state a crash leaves, and the next node to mount
         * reclaims it. */
        if (ne.last_seen != 0)
            fprintf(stderr,
                    "WARN: node slot %u is REGISTERED and did not depart cleanly (hb_seq=%" PRIu64
                    ") -- a crashed "
                    "node, or one still running; its zone groups and locks are reclaimed by the next node to mount\n",
                    n, (uint64_t) cetrafs_le64(ne.hb_seq));
    }

    /*
     * A Zone Group owned by a row that is not REGISTERED.
     *
     * Nothing checked this, and the two halves were read in the wrong
     * order to do so -- the ZG table is walked long before the Node
     * Registry. It is not corruption: a FREE row reads as stale, so the
     * next node to mount reclaims the ZG. But it means that ZG's
     * capacity is sitting unused and unexplained, which is precisely
     * what an operator is asking about when they run fsck on a volume
     * that seems smaller than it should be.
     */
    for (uint32_t z = 0; z < cetrafs_le32(sb.zone_group_count); ++z) {
        if (zg_owner[z] == CETRAFS_NODE_ID_NONE)
            continue;
        if (zg_owner[z] >= cetrafs_le32(sb.node_table_count)) {
            fprintf(stderr, "WARN: ZG%u names owner node %u, which is outside the registry (0..%u)\n", z, zg_owner[z],
                    cetrafs_le32(sb.node_table_count) - 1);
            continue;
        }
        if (!node_registered[zg_owner[z]])
            fprintf(stderr,
                    "WARN: ZG%u is owned by node slot %u, which is not REGISTERED -- the zone group is orphaned and "
                    "its space unusable until some node reclaims it\n",
                    z, zg_owner[z]);
    }

    /*
     * Retire departed rows when the registry is full.
     *
     * Nothing in the kernel ever writes a row back to FREE: a node that
     * leaves keeps its row (last_seen 0) so it can re-attach by UUID. A
     * volume that has seen as many distinct node identities as it has
     * rows -- reinstalled hosts, new machine-ids -- refuses the next one
     * with "registry full", and only mkfs used to clear it.
     *
     * The kernel cannot retire such a row at registration: a lock, a
     * presence bit and a Zone Group name their holder by row number only,
     * so a new node on a departed row would silently inherit whatever the
     * old one still held. fsck -r can check that nothing does: it holds
     * the repair claim (no node can mount meanwhile), it has refused to
     * run beside a live peer, and it can read every record. A departed row
     * is freed only if no Zone Group, no exclusive or namespace lock, no
     * read or suspended-writer bit, no dirty journal and no journal
     * replay claim names it. Only
     * when no FREE row is left; otherwise the node may still come back to
     * its own row.
     */
    /* class 45: retires a row only when nothing on the volume names it */
    if (repair_mode && !repair_blocked && node_free_rows == 0 && node_departed_rows > 0) {
        uint32_t nrows = cetrafs_le32(sb.node_table_count);
        uint8_t *node_ref = (uint8_t *) xcalloc(nrows, 1);
        uint32_t retired = 0;

        for (uint32_t z = 0; z < cetrafs_le32(sb.zone_group_count); ++z)
            if (zg_owner[z] < nrows)
                node_ref[zg_owner[z]] = 1;
        for (uint32_t n = 0; n < nrows; ++n) {
            uint64_t area = cetrafs_le64(sb.node_journal_start) + (uint64_t) n * cetrafs_le32(sb.node_journal_blocks);
            cetrafs_node_journal_hdr_t flag;

            if (!cetrafs_le32(sb.node_journal_blocks))
                break;
            pread_all(fd, &flag, sizeof(flag), (off_t) area * CETRAFS_BLOCK_SIZE);
            if (cetrafs_le32(flag.magic) != CETRAFS_NODE_JOURNAL_MAGIC)
                continue;
            if (cetrafs_le32(flag.state) == CETRAFS_NODE_JOURNAL_DIRTY)
                node_ref[n] = 1;
            /* A replay claim names its REPLAYER's row, on another
             * node's area: a new node on that row would read as a live
             * replayer mid-replay, and the area's owner would wait on a
             * claim nobody releases. */
            if (cetrafs_le32(flag.replay_owner) < nrows)
                node_ref[cetrafs_le32(flag.replay_owner)] = 1;
        }
        for (uint64_t ino = 1; ino <= cetrafs_le32(sb.inodes_count); ++ino) {
            cetrafs_inode_t in;
            uint64_t bits;

            fsck_repair_heartbeat();
            pread_all(fd, &in, sizeof(in), (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE);
            if (!in.ino && !in.generation)
                continue; /* never written */
            if (cetrafs_le32(in.lock_mode) == CETRAFS_LOCK_EXCLUSIVE && cetrafs_le32(in.lock_owner_node) < nrows)
                node_ref[cetrafs_le32(in.lock_owner_node)] = 1;
            if (cetrafs_le32(in.ns_lock_owner) < nrows)
                node_ref[cetrafs_le32(in.ns_lock_owner)] = 1;
            bits = cetrafs_le64(in.read_open_nodes) | cetrafs_le64(in.suspended_writer_nodes);
            for (uint32_t n = 0; n < nrows && n < 64; ++n)
                if (bits & (1ULL << n))
                    node_ref[n] = 1;
        }
        for (uint32_t n = 0; n < nrows; ++n) {
            uint8_t zero[CETRAFS_BLOCK_SIZE];

            if (!node_departed[n] || node_ref[n] || (int) n == repair_row)
                continue;
            memset(zero, 0, sizeof(zero));
            pwrite_all(fd, zero, sizeof(zero), (off_t) (cetrafs_le64(sb.node_table_start) + n) * CETRAFS_BLOCK_SIZE);
            node_registered[n] = 0;
            retired++;
            repairs_made++;
            printf("  registry full: retired node slot %u, which departed cleanly and is referenced by nothing\n", n);
        }
        if (retired)
            fsync(fd);
        else
            fprintf(stderr, "WARN: the Node Registry is full and every departed row is still referenced -- no "
                            "row could be retired\n");
        free(node_ref);
    } else if (node_free_rows == 0 && node_departed_rows > 0 && !repair_mode) {
        fprintf(stderr, "WARN: the Node Registry is full; %u row(s) belong to nodes that departed cleanly -- "
                        "fsck -r retires those that nothing references\n",
                node_departed_rows);
    }

    /*
     * Cluster metadata: per-node journals and per-ZG pending-free queues
     *. Neither was checked at all, which meant the two
     * structures that exist precisely to survive a crash were the two
     * nobody verified after one.
     *
     * Checked before the content passes deliberately: a journal still
     * holding entries means writes that have not reached their targets,
     * so every conclusion the bitmap/extent reconciliation would draw
     * about this volume is provisional until it is replayed by a mount.
     */
    {
        uint64_t cl_problems = 0, journal_unapplied = 0;

        /* An LBA is legal as a journal target or a queued free only if
         * it lands inside some BG's data region -- the same question
         * journal.c asks before applying a payload. Returns the BG
         * index, or -1. */
#define FSCK_BG_FOR_LBA(lba, out_bg)                                                         \
    do {                                                                                     \
        (out_bg) = -1;                                                                       \
        for (uint32_t _b = 0; _b < cetrafs_le32(sb.block_group_count); ++_b) {                             \
            if ((lba) >= bg_data_start[_b] && (lba) < bg_data_start[_b] + bg_data_cnt[_b]) { \
                (out_bg) = (int64_t) _b;                                                     \
                break;                                                                       \
            }                                                                                \
        }                                                                                    \
    } while (0)

        if (cetrafs_le32(sb.node_journal_blocks) >= 1 + CETRAFS_JOURNAL_SLOT_BLOCKS) {
            uint64_t slots = (cetrafs_le32(sb.node_journal_blocks) - 1) / CETRAFS_JOURNAL_SLOT_BLOCKS;

            for (uint32_t n = 0; n < cetrafs_le32(sb.node_table_count); ++n) {
                uint64_t area = cetrafs_le64(sb.node_journal_start) + (uint64_t) n * cetrafs_le32(sb.node_journal_blocks);
                cetrafs_node_journal_hdr_t flag;

                pread_all(fd, &flag, sizeof(flag), (off_t) area * CETRAFS_BLOCK_SIZE);

                /* A zero-filled block reads CLEAN by design (fresh mkfs);
                 * anything that is neither zero nor the magic is garbage
                 * sitting where replay decides whether to scan. */
                if (cetrafs_le32(flag.magic) != 0 && cetrafs_le32(flag.magic) != CETRAFS_NODE_JOURNAL_MAGIC) {
                    fprintf(stderr, "ERR: node %u journal flag block has bad magic 0x%08X\n", n, (uint32_t) cetrafs_le32(flag.magic));
                    cl_problems++;
                } else if (cetrafs_le32(flag.magic) == CETRAFS_NODE_JOURNAL_MAGIC && cetrafs_le32(flag.state) == CETRAFS_NODE_JOURNAL_DIRTY) {
                    fprintf(stderr,
                            "WARN: node %u journal is DIRTY -- it crashed with entries outstanding; "
                            "mount the volume to replay them\n",
                            n);
                }

                for (uint64_t sl = 0; sl < slots; ++sl) {
                    uint64_t hlba = area + 1 + sl * CETRAFS_JOURNAL_SLOT_BLOCKS;
                    uint8_t hblk[CETRAFS_BLOCK_SIZE];
                    cetrafs_journal_header_t hdr;
                    int64_t tbg;

                    pread_all(fd, hblk, sizeof(hblk), (off_t) hlba * CETRAFS_BLOCK_SIZE);
                    memcpy(&hdr, hblk, sizeof(hdr));
                    if (cetrafs_le32(hdr.magic) != CETRAFS_JOURNAL_MAGIC)
                        continue; /* consumed or never written */

                    uint32_t hc = crc32c_struct(&hdr, sizeof(hdr), offsetof(cetrafs_journal_header_t, header_checksum),
                                                sizeof(hdr.header_checksum));
                    /* A torn slot -- header or payload failing its CRC
                     * -- is an entry that never committed, the normal
                     * residue of a crash mid-journal-write, and replay
                     * skips it (journal.c). It was ERR here: the volume
                     * failed every check after such a crash, with no
                     * repair to offer, for an entry nothing will ever
                     * apply. If the operation it covered had begun on
                     * its target, that block's own checksum says so. */
                    if ((uint32_t) cetrafs_le32(hdr.header_checksum) != hc) {
                        fprintf(stderr,
                                "WARN: node %u journal slot %" PRIu64
                                " header CRC mismatch -- a torn, uncommitted entry; replay skips it\n",
                                n, sl);
                        continue;
                    }

                    /* The check journal.c gained after review: an entry
                     * naming a block outside every data region would be
                     * applied blindly at mount, and pointed at block 0
                     * that destroys the superblock. */
                    FSCK_BG_FOR_LBA(cetrafs_le64(hdr.target_lba), tbg);
                    if (tbg < 0) {
                        fprintf(stderr,
                                "ERR: node %u journal slot %" PRIu64 " targets block %" PRIu64
                                ", which is outside every BG data region\n",
                                n, sl, (uint64_t) cetrafs_le64(hdr.target_lba));
                        cl_problems++;
                        continue;
                    }

                    uint8_t pay[CETRAFS_BLOCK_SIZE];
                    pread_all(fd, pay, sizeof(pay), (off_t) (hlba + 1) * CETRAFS_BLOCK_SIZE);
                    if ((uint32_t) cetrafs_le32(hdr.payload_checksum) != crc32c_update(0, pay, sizeof(pay))) {
                        fprintf(stderr,
                                "WARN: node %u journal slot %" PRIu64
                                " payload CRC mismatch (target block %" PRIu64
                                ") -- a torn entry; replay skips it\n",
                                n, sl, (uint64_t) cetrafs_le64(hdr.target_lba));
                    } else if (!(cetrafs_le32(hdr.flags) & CETRAFS_JRNL_F_FRESH)) {
                        /* A whole, valid entry. If its target already
                         * holds the payload, only the consume was lost
                         * and replay will change nothing. Otherwise the
                         * next mount WRITES it -- a dirent, an extent
                         * leaf, an xattr block this walk has not seen.
                         * Repairing now would reconcile against the
                         * pre-replay volume: clear bits the replayed
                         * leaf names, link into lost+found an inode the
                         * replayed dirent names. Replay is the mount's
                         * job (journal.c, with its guards); until it
                         * has run, this verdict is provisional and the
                         * repair must not run on it. */
                        uint8_t tgt[CETRAFS_BLOCK_SIZE];

                        pread_all(fd, tgt, sizeof(tgt), (off_t) cetrafs_le64(hdr.target_lba) * CETRAFS_BLOCK_SIZE);
                        if (crc32c_update(0, tgt, sizeof(tgt)) != (uint32_t) cetrafs_le32(hdr.payload_checksum)) {
                            fprintf(stderr,
                                    "WARN: node %u journal slot %" PRIu64
                                    " holds an entry not yet applied to block %" PRIu64 " -- a mount replays it\n",
                                    n, sl, (uint64_t) cetrafs_le64(hdr.target_lba));
                            journal_unapplied++;
                        }
                    }
                }
            }
        }

        /* Pending-free queues: one per ZG, holding extents a peer freed
         * out of a ZG it does not own. An entry naming blocks outside
         * the owning ZG would have the owner clear bits in somebody
         * else's bitmap on its next drain. */
        if (sb.pending_free_start) {
            for (uint32_t z = 0; z < cetrafs_le32(sb.zone_group_count); ++z) {
                for (uint32_t b = 0; b < cetrafs_le32(sb.pending_free_blocks_per_zg); ++b) {
                    uint64_t qlba = cetrafs_le64(sb.pending_free_start) + (uint64_t) z * cetrafs_le32(sb.pending_free_blocks_per_zg) + b;
                    uint8_t qblk[CETRAFS_BLOCK_SIZE];

                    pread_all(fd, qblk, sizeof(qblk), (off_t) qlba * CETRAFS_BLOCK_SIZE);
                    for (unsigned e = 0; e < CETRAFS_PENDING_FREE_PER_BLOCK; ++e) {
                        cetrafs_pending_free_t pe;
                        int64_t fbg, lbg;

                        memcpy(&pe, qblk + e * sizeof(pe), sizeof(pe));
                        if (cetrafs_le32(pe.magic) != CETRAFS_PENDING_FREE_MAGIC || cetrafs_le64(pe.lba) == 0)
                            continue;

                        if (pe.count == 0) {
                            fprintf(stderr, "ERR: ZG%u pending-free entry %u has count 0\n", z, e);
                            cl_problems++;
                            continue;
                        }
                        FSCK_BG_FOR_LBA((uint64_t) cetrafs_le64(pe.lba), fbg);
                        FSCK_BG_FOR_LBA((uint64_t) cetrafs_le64(pe.lba) + cetrafs_le32(pe.count) - 1, lbg);
                        if (fbg < 0 || lbg < 0) {
                            fprintf(stderr,
                                    "ERR: ZG%u pending-free entry %u names blocks %" PRIu64 "..%" PRIu64
                                    " outside every BG data region\n",
                                    z, e, (uint64_t) cetrafs_le64(pe.lba), (uint64_t) cetrafs_le64(pe.lba) + cetrafs_le32(pe.count) - 1);
                            cl_problems++;
                            continue;
                        }
                        if (fbg != lbg) {
                            fprintf(stderr,
                                    "ERR: ZG%u pending-free entry %u spans BG%" PRId64 " into BG%" PRId64
                                    " -- an extent never crosses a BG\n",
                                    z, e, fbg, lbg);
                            cl_problems++;
                            continue;
                        }
                        if (bg_owner_expected[fbg] == CETRAFS_BG_OWNER_FREE) {
                            fprintf(stderr,
                                    "ERR: ZG%u pending-free entry %u names blocks in BG%" PRId64
                                    ", which is owned by nobody\n",
                                    z, e, fbg);
                            cl_problems++;
                        } else if (bg_owner_expected[fbg] != z) {
                            fprintf(stderr,
                                    "ERR: ZG%u pending-free entry %u names blocks in BG%" PRId64
                                    ", which belongs to ZG%u\n",
                                    z, e, fbg, bg_owner_expected[fbg]);
                            cl_problems++;
                        }
                    }
                }
            }
        }
#undef FSCK_BG_FOR_LBA

        if (journal_unapplied)
            repair_block(
                "journal entries a mount has not yet replayed -- mount the volume once (replay runs at "
                "mount) and re-run fsck -r");

        if (cl_problems) {
            fprintf(stderr, "cetrafs fsck: %" PRIu64 " cluster-metadata problem(s) found\n", cl_problems);
            return 1;
        }
    }

    /* Root inode checks */
    uint64_t ioff = (uint64_t) (cetrafs_le64(sb.inode_table_start) + CETRAFS_ROOT_INO - 1) * CETRAFS_BLOCK_SIZE;
    cetrafs_inode_t ri;
    pread_all(fd, &ri, sizeof(ri), (off_t) ioff);
    if (((cetrafs_le32(ri.mode)) & 0170000) != S_IFDIR) {
        fprintf(stderr, "ERR: root is not a dir\n");
        return 1;
    }
    /* Per-sector CRCs, plain-native like the BG descriptor/header checksums. */
    if (!cetrafs_inode_crcs_ok(&ri)) {
        fprintf(stderr, "ERR: root inode CRC/identity mismatch (ns 0x%08X/0x%08X, fd 0x%08X/0x%08X)\n",
                (uint32_t) cetrafs_le64(ri.ns_checksum), cetrafs_inode_crc_ns_us(&ri),
                (uint32_t) cetrafs_le64(ri.fd_checksum), cetrafs_inode_crc_fd_us(&ri));
        return 1;
    }
    if (cetrafs_le16(ri.eh.eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(ri.eh.eh_depth) > 1 || cetrafs_le16(ri.eh.eh_entries) < 1) {
        fprintf(stderr, "ERR: root extents header invalid\n");
        return 1;
    }
    /*
     * Root's FIRST extent -- which is still the block mkfs placed,
     * because a directory only ever grows by appending and nothing
     * relocates one (defrag is gated on S_ISREG).
     *
     * This used to read ri.et.leaf[0] unconditionally and to require
     * eh_depth == 0, which is only true of a root that has never grown
     * past its four inline extents -- about 58 names. So on any real
     * volume fsck reported "root extents header invalid" forever after,
     * on a filesystem that was perfectly healthy: a check that cries
     * wolf, which is how people learn to ignore fsck and how a genuine
     * fault goes unnoticed. At depth 1 the inline array is an index
     * pointing at the external leaf, so et.leaf[0] is not an extent at
     * all and the lba check below compared garbage.
     */
    uint64_t root_lba;
    if (ri.eh.eh_depth == 0) {
        root_lba = (((uint64_t) cetrafs_le16(ri.et.leaf[0].ee_start_hi)) << 32) | cetrafs_le32(ri.et.leaf[0].ee_start_lo);
    } else {
        uint8_t rootleaf[CETRAFS_BLOCK_SIZE];
        uint64_t leaf_lba = ((uint64_t) cetrafs_le16(ri.et.idx[0].ei_leaf_hi) << 32) | cetrafs_le32(ri.et.idx[0].ei_leaf_lo);
        const cetrafs_extent_hdr_t *lh = (const cetrafs_extent_hdr_t *) rootleaf;
        const cetrafs_extent_t *le = (const cetrafs_extent_t *) (rootleaf + sizeof(*lh));

        pread_all(fd, rootleaf, sizeof(rootleaf), (off_t) leaf_lba * CETRAFS_BLOCK_SIZE);
        if (cetrafs_le16(lh->eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(lh->eh_entries) < 1) {
            fprintf(stderr, "ERR: root external extent leaf (block %" PRIu64 ") invalid\n", leaf_lba);
            return 1;
        }
        root_lba = ((uint64_t) cetrafs_le16(le[0].ee_start_hi) << 32) | cetrafs_le32(le[0].ee_start_lo);
    }
    uint64_t expect_root_lba = cetrafs_le64(sb.bg_regions_start) + 1 + (cetrafs_calc_bg_dbm_blocks(cetrafs_le64(sb.bg_size_blocks)));
    if (root_lba != expect_root_lba) {
        fprintf(stderr, "ERR: root data lba %" PRIu64 " != expected %" PRIu64 "\n", root_lba, expect_root_lba);
        return 1;
    }

    /* Verify '.' and '..' + the dirent-block tail checksum (v0x0007) */
    uint8_t dirblk[CETRAFS_BLOCK_SIZE];
    pread_all(fd, dirblk, sizeof(dirblk), (off_t) root_lba * CETRAFS_BLOCK_SIZE);
    {
        const cetrafs_dirent_tail_t *tail = (const cetrafs_dirent_tail_t *) (dirblk + CETRAFS_DIRENT_TAIL_OFF);
        uint32_t want = crc32c_update(0, dirblk, CETRAFS_DIRENT_TAIL_OFF);

        if (cetrafs_le32(tail->magic) != CETRAFS_DIRENT_TAIL_MAGIC || cetrafs_le32(tail->crc) != want) {
            fprintf(stderr, "ERR: root dirent block tail checksum invalid (magic=0x%08X crc=0x%08X want 0x%08X)\n",
                    tail->magic, tail->crc, want);
            early_problems++;
            /*
             * Root gets the same rebuild as any other directory, and
             * needs it more: an unreadable root dirent block makes the
             * WHOLE VOLUME unusable, and this check returns before any
             * content pass runs, so without the repair there is nothing
             * fsck can do for it at all.
             *
             * Root's parent is root, so both structural entries are
             * known outright -- no namespace pass required, which is why
             * this one is rebuilt here and now rather than deferred.
             * Anything the lost entries named becomes an unreachable
             * inode, which the content passes below then find and link
             * into /lost+found exactly as they would for any other
             * directory.
             */
            /* A torn TAIL over an intact entry table is the common case
             * (a crash mid-write of the tail sector), and every other
             * directory gets a re-stamp for it, keeping its names. The
             * root went straight to the rebuild: every top-level name
             * gone, before this run even knew whether repair was safe --
             * and if a later pass blocked repair, nothing linked the
             * orphans back (audit 2026-11-06 M11). A re-stamp writes the
             * same entries, so it is safe whatever the run finds later.
             * Only an incoherent table is rebuilt. */
            if (fsck_dirent_block_coherent(dirblk, &sb, 1, CETRAFS_ROOT_INO)) {
                /* class 45: lossless -- the same entries, re-stamped */
                if (repair_mode && !repair_blocked) {
                    fsck_stamp_dirent_block(dirblk);
                    pwrite_all(fd, dirblk, sizeof(dirblk), (off_t) root_lba * CETRAFS_BLOCK_SIZE);
                    repairs_made++;
                    printf("  re-stamped the root directory's dirent tail -- every entry in it is intact\n");
                } else {
                    printf("  the root directory's entry table is intact: -r would re-stamp its tail\n");
                    return 1;
                }
            } else if (repair_mode && !repair_blocked) {
                /* class 45: destructive before the verdict, and allowed --
                 * no pass runs without a root, the names lost were
                 * unreadable, and the orphans keep their records. */
                repair_reinit_dirent_block(fd, root_lba, CETRAFS_ROOT_INO, CETRAFS_ROOT_INO, true);
                repairs_made++;
                printf("  rebuilt the root directory's dirent block (with '.' and '..') -- its entries were damaged\n");
                pread_all(fd, dirblk, sizeof(dirblk), (off_t) root_lba * CETRAFS_BLOCK_SIZE);
            } else {
                return 1;
            }
        }
    }
    cetrafs_dirent_t *d = (cetrafs_dirent_t *) dirblk;
    if (!(cetrafs_le64(d[0].inode) == 1 && d[0].file_type == CETRAFS_FT_DIR && cetrafs_le16(d[0].name_len) == 1 && d[0].name[0] == '.')) {
        fprintf(stderr, "ERR: missing '.' entry\n");
        return 1;
    }
    if (!(cetrafs_le64(d[1].inode) == 1 && d[1].file_type == CETRAFS_FT_DIR && cetrafs_le16(d[1].name_len) == 2 && d[1].name[0] == '.' &&
          d[1].name[1] == '.')) {
        fprintf(stderr, "ERR: missing '..' entry\n");
        return 1;
    }

    /* Check bit 0 in BG0 data bitmap set */
    uint64_t dbm0_lba = cetrafs_le64(sb.bg_regions_start) + 1;
    uint8_t bm[CETRAFS_BLOCK_SIZE];
    pread_all(fd, bm, sizeof(bm), (off_t) dbm0_lba * CETRAFS_BLOCK_SIZE);
    bool bit0 = (bm[0] & 0x01) != 0;
    if (!bit0) {
        fprintf(stderr, "ERR: BG0 data bitmap bit0 not set\n");
        return 1;
    }

    /* ================= content passes =================================
     *
     * Everything above validates STRUCTURE -- checksums, layout
     * arithmetic, ownership spans. None of it can see the corruption
     * that actually matters: two files sharing a block, or blocks
     * marked in use that nothing references. Those need the inode table
     * walked and every extent collected, which is what follows.
     *
     * This is the pass that would have caught the 128 MiB leak that had
     * to be diagnosed by hand with two throwaway programs, and it is
     * the only thing in this tool that can detect cross-file block
     * overlap -- the single worst corruption this filesystem can
     * suffer, because it is silent and compounding.
     */
    {
        uint64_t total_data = 0;
        for (uint32_t b = 0; b < cetrafs_le32(sb.block_group_count); ++b)
            total_data += bg_data_cnt[b];

        /* Referenced/duplicate as BITMAPS, one bit per data block each,
         * not a u32 owner id per block. The owner array was 4 bytes per
         * block: fine on a 5 GiB test image (5 MB), but 1 GB on a 1 TB
         * LUN and 10 GB on a 10 TB one -- i.e. it would OOM on exactly
         * the volumes this filesystem is built for. Two bits per block
         * is 64 MB at 1 TB.
         *
         * The cost is that a duplicate can no longer name BOTH inodes
         * from the array alone, so the first few are remembered
         * explicitly (below) to keep the messages actionable; beyond
         * that the block number is still reported, which is what an
         * operator needs to act. */
        size_t bmwords = (total_data ? total_data : 1) / 8 + 1;
        uint8_t *refd = (uint8_t *) xcalloc(bmwords, 1);
        uint8_t *dupd = (uint8_t *) xcalloc(bmwords, 1);
        uint8_t *weakd = (uint8_t *) xcalloc(bmwords, 1);
        /* Leaked blocks to clear once the namespace pass has run: see
         * the reconcile loop below. */
        uint8_t *leakd = (uint8_t *) xcalloc(bmwords, 1);
        uint64_t leak_deferred = 0;
        uint64_t stale_blocks = 0, stale_before = 0;
/* FSCK_SET/FSCK_GET are defined globally above (guarded). */
        uint8_t *ibmap = (uint8_t *) xcalloc(cetrafs_le64(sb.inode_bmap_blocks), CETRAFS_BLOCK_SIZE);
        int ibmap_dirty = 0;
        uint64_t orphans_freed = 0;
        uint64_t orphans_linked = 0;
        struct fsck_lf lf = {0, cetrafs_le64(sb.root_ino), 0, 0};
        uint64_t problems = 0, inodes_seen = 0, extents_seen = 0, blocks_referenced = 0;

        pread_all(fd, ibmap, (size_t) cetrafs_le64(sb.inode_bmap_blocks) * CETRAFS_BLOCK_SIZE,
                  (off_t) cetrafs_le64(sb.inode_bmap_start) * CETRAFS_BLOCK_SIZE);

        /* Map a data-block LBA to its index in 'owner', or -1 if the LBA
         * is not inside any BG's data region (which is itself a fault:
         * an extent must never point at metadata). */
        /* (inline below; kept as a lambda-ish loop for clarity) */

        /* Two passes: live records (nlink > 0) first, then deleted
         * ones (fsck_dead_walk), so that a block a live record names is
         * the live record's whatever the inode numbering. */
        for (int dpass = 0; dpass < 2; ++dpass)
        for (uint64_t ino = 1; ino <= cetrafs_le32(sb.inodes_count); ++ino) {
            fsck_repair_heartbeat();
            uint64_t bit = ino - 1;
            if (!(ibmap[bit / 8] & (1u << (bit % 8))))
                continue; /* free inode */

            uint8_t iblk[CETRAFS_BLOCK_SIZE];
            cetrafs_inode_t in;
            pread_all(fd, iblk, sizeof(iblk), (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE);
            memcpy(&in, iblk, sizeof(in));

            fsck_dead_walk = 0;
            if (!cetrafs_inode_crcs_ok(&in) && dpass)
                continue; /* reported by the first pass */
            if (!cetrafs_inode_crcs_ok(&in) && fsck_all_zero(iblk, sizeof(iblk))) {
                /* All zero: the number was taken and its record never
                 * written -- a create stopped between the two (a crash,
                 * or a write the device refused). It names nothing, so
                 * it hides no blocks; the namespace pass frees the
                 * number under -r like any unnamed deleted record. */
                fprintf(stderr,
                        "WARN: inode %" PRIu64 " is marked in use but its record was never written -- "
                        "a create stopped before writing it\n",
                        ino);
                continue;
            }
            if (cetrafs_inode_crcs_ok(&in) && cetrafs_le64(in.ino) != ino) {
                if (dpass)
                    continue; /* reported by the first pass */
                /* A valid record in the wrong slot: whose blocks its
                 * extents name cannot be known, exactly as for a bad
                 * checksum below. */
                fprintf(stderr, "ERR: inode %" PRIu64 "'s slot holds a valid record for inode %" PRIu64 "\n", ino,
                        (uint64_t) cetrafs_le64(in.ino));
                problems++;
                repair_block("an inode slot holds another inode's record, so the blocks it names cannot be "
                             "attributed");
                continue;
            }
            if (!cetrafs_inode_crcs_ok(&in)) {
                fprintf(stderr, "ERR: inode %" PRIu64 " is marked in use but its checksum is wrong\n", ino);
                problems++;
                /* Critical for repair: this record is skipped, so its
                 * extents are never collected and every block it owns
                 * looks LEAKED. Clearing those bits would hand a live
                 * file's blocks to the allocator -- turning a readable
                 * corrupt inode into cross-file corruption. */
                repair_block(
                    "an inode record failed its checksum, so the blocks it owns cannot be "
                    "distinguished from leaked ones");
                continue;
            }
            if ((in.nlink == 0) != (dpass == 1))
                continue; /* the other pass's */
            fsck_dead_walk = dpass;
            stale_before = stale_blocks;
            inodes_seen++;

            /* A lock_mode no code writes: the kernel treats it as
             * neither free nor stealable, so the file could never be
             * opened for write again, and nothing used to say so.
             * Reported, not repaired: there is no basis for choosing
             * which mode was meant. */
            if (cetrafs_le32(in.lock_mode) != CETRAFS_LOCK_NONE && cetrafs_le32(in.lock_mode) != CETRAFS_LOCK_EXCLUSIVE)
                fprintf(stderr,
                        "WARN: inode %" PRIu64 " has lock_mode %u, which is neither unlocked nor exclusive -- "
                        "no node can open it for write\n",
                        ino, cetrafs_le32(in.lock_mode));

            /* A suspended-writer mark is always a subset of the
             * presence mask: the mark says which presence bits are a
             * writer handing over rather than a reader. A mark with no
             * presence bit under it reads, to the access rule's masks,
             * as a writer no node is -- and nothing ever clears it.
             * Reported, not repaired: whether the mark or the presence
             * is the stale half is the live node's to know. */
            if (cetrafs_le64(in.suspended_writer_nodes) & ~cetrafs_le64(in.read_open_nodes))
                fprintf(stderr,
                        "WARN: inode %" PRIu64 " marks node(s) 0x%" PRIx64 " as suspended writers without the "
                        "presence bit the mark qualifies\n",
                        ino,
                        (uint64_t) (cetrafs_le64(in.suspended_writer_nodes) & ~cetrafs_le64(in.read_open_nodes)));

            /* An allocated nlink=0 inode is left when a delete could
             * not free it -- a peer's open racing the unlink's check, an
             * opener that died holding it, an I/O error mid-free --
             * bounded, reclaimable (-r, or the online scrub), and
             * reported, but NOT a corruption this tool should fail the
             * volume on. See the unreachable-inode pass. */
            if (in.nlink == 0)
                fprintf(stderr, "WARN: inode %" PRIu64 " is allocated but has nlink=0 (orphan)\n", ino);

            /* A type the kernel cannot instantiate: iget refuses it
             * (-EUCLEAN), so the file is unreachable on every node. Its
             * blocks are still walked below. */
            {
                uint32_t fmt = cetrafs_le32(in.mode) & 0170000u;

                if (in.nlink != 0 && fmt != 0100000u && fmt != 0040000u && fmt != 0120000u) {
                    fprintf(stderr, "ERR: inode %" PRIu64 " has mode 0%o, a type the kernel refuses to open\n", ino,
                            cetrafs_le32(in.mode));
                    problems++;
                }
            }
            if (cetrafs_le16(in.eh.eh_magic) != CETRAFS_EXT_MAGIC && in.eh.eh_magic == 0 && in.nlink != 0 &&
                fsck_all_zero((const uint8_t *) &in.et, sizeof(in.et)) && in.eh.eh_entries == 0 &&
                in.eh.eh_depth == 0) {
                /* Nothing hidden (no extent bytes at all), but every
                 * creator stamps the magic, and the kernel refuses to
                 * map through a record without it (-EIO on the first
                 * read or write). Repair stays on, so the record goes
                 * on through the walk below: its extents mark nothing
                 * and its xattr block must still be marked, or a repair
                 * clears it as leaked (audit 2026-11-06 L23). */
                fprintf(stderr, "ERR: inode %" PRIu64 " has no extent header; the kernel refuses to map it\n", ino);
                problems++;
            } else if (cetrafs_le16(in.eh.eh_magic) != CETRAFS_EXT_MAGIC) {
                /* magic == 0 is a legitimate "no extents yet" record and
                 * is NOT an error -- blocking repair on it would disable
                 * repair on every healthy volume, which is the
                 * cries-wolf failure N5 is about. Only a header that is
                 * positively wrong hides blocks from the walk. */
                if (in.eh.eh_magic == 0 && in.nlink != 0 && fsck_all_zero((const uint8_t *) &in.et, sizeof(in.et))) {
                    /* No extent bytes, but a count or depth in the
                     * header: nothing the walk could follow either. */
                    fprintf(stderr,
                            "ERR: inode %" PRIu64 " has no extent header; the kernel refuses to map it\n", ino);
                    problems++;
                } else if (in.eh.eh_magic == 0 && in.nlink != 0) {
                    fprintf(stderr, "ERR: inode %" PRIu64 " has extent entries under a missing header\n", ino);
                    problems++;
                    repair_block("an inode's extent header is missing over extent data, so the blocks it owns "
                                 "cannot be distinguished from leaked ones");
                }
                if (in.eh.eh_magic != 0) {
                    fprintf(stderr, "%s: inode %" PRIu64 " has a bad extent header magic 0x%X\n", FSCK_SEV, ino, in.eh.eh_magic);
                    problems += !fsck_dead_walk;
                    repair_block(
                        "an inode's extent header is not valid, so the blocks it owns cannot be "
                        "distinguished from leaked ones");
                }
                continue;
            }
            if (cetrafs_le16(in.eh.eh_depth) > CETRAFS_EXT_MAX_DEPTH) {
                fprintf(stderr, "%s: inode %" PRIu64 " has extent depth %u (only 0, 1 and 2 exist)\n", FSCK_SEV, ino,
                        in.eh.eh_depth);
                problems += !fsck_dead_walk;
                /* Same reason as the bad-magic case above, and it was
                 * missing here: a tree this walker cannot descend means
                 * that inode's blocks never get marked referenced, so
                 * the leak pass sees them as unowned and `-r` CLEARS
                 * them. The file is the blocks. */
                repair_block(
                    "an inode's extent tree is deeper than the format allows, so the blocks it owns cannot be "
                    "distinguished from leaked ones");
                continue;
            }

            /* Turn this inode's extent tree into reachability bits. The
             * tree block itself (leaf, and at depth 2 the interiors) is a
             * data block too and must be accounted for, or it reads as a
             * leak. fsck_mark_run() is the shared depth-0 marking; the
             * depth-2 walk reuses it per leaf. */
            fsck_nlruns = 0;
            fsck_cur_fmt = cetrafs_le32(in.mode) & 0170000u;
            struct fsck_refctx rc = {refd,      dupd, bg_data_start, bg_data_cnt,
                                     cetrafs_le32(sb.block_group_count), &problems, &blocks_referenced,
                                     weakd,     &stale_blocks};
            uint64_t xattr_lba = cetrafs_le64(in.xattr_block);
            uint8_t leafblk[CETRAFS_BLOCK_SIZE];
            int tree_ok = 1;

            /* The record's inline count indexes a 4-slot array. Clamped
             * below in silence, which reported clean a record the kernel
             * refuses to map through. Its blocks cannot be told from
             * leaked ones either, so nothing is repaired around it. */
            if (cetrafs_le16(in.eh.eh_entries) > 4) {
                fprintf(stderr, "%s: inode %" PRIu64 " claims %u inline extent entries; the record holds 4\n", FSCK_SEV, ino,
                        cetrafs_le16(in.eh.eh_entries));
                problems += !fsck_dead_walk;
                repair_block("a record's inline extent count is impossible, so the blocks the inode owns cannot "
                             "be distinguished from leaked ones");
            }

            if (in.eh.eh_depth == 0) {
                uint32_t n = cetrafs_le16(in.eh.eh_entries) > 4 ? 4 : cetrafs_le16(in.eh.eh_entries);

                for (uint32_t e = 0; e < n; ++e) {
                    uint64_t phys = ((uint64_t) cetrafs_le16(in.et.leaf[e].ee_start_hi) << 32) | cetrafs_le32(in.et.leaf[e].ee_start_lo);

                    fsck_mark_run(&rc, phys, cetrafs_le32(in.et.leaf[e].ee_len) & CETRAFS_EXT_LEN_MASK, ino);
                    problems += fsck_extent_logical(ino, &in.et.leaf[e], 0, 0) && !fsck_dead_walk;
                    extents_seen++;
                }
            } else if (cetrafs_le16(in.eh.eh_depth) == 1) {
                uint64_t leaf_lba = ((uint64_t) cetrafs_le16(in.et.idx[0].ei_leaf_hi) << 32) | cetrafs_le32(in.et.idx[0].ei_leaf_lo);
                cetrafs_extent_hdr_t *lh;
                uint32_t n;

                if (!fsck_lba_in_range(leaf_lba, cetrafs_le64(sb.total_blocks))) {
                    fprintf(stderr, "%s: inode %" PRIu64 "'s extent leaf (block %" PRIu64 ") is out of range\n",
                            FSCK_SEV, ino, leaf_lba);
                    problems += !fsck_dead_walk;
                    repair_block("an extent leaf lba is out of range, so the blocks the inode "
                                 "owns cannot be distinguished from leaked ones");
                    tree_ok = 0;
                } else if (pread_all(fd, leafblk, sizeof(leafblk), (off_t) leaf_lba * CETRAFS_BLOCK_SIZE),
                           fsck_check_tail(leafblk, CETRAFS_LEAF_TAIL_MAGIC) != 0) {
                    fprintf(stderr, "%s: inode %" PRIu64 "'s extent leaf (block %" PRIu64 ") failed its tail checksum\n",
                            FSCK_SEV, ino, leaf_lba);
                    problems += !fsck_dead_walk;
                    if (fsck_salvage_candidate(&in, leafblk)) {
                        uint64_t rlo = 0, rhi = 0;

                        if (cetrafs_le32(in.et.idx[0].ei_block_end)) {
                            rlo = cetrafs_le32(in.et.idx[0].ei_block);
                            rhi = cetrafs_le32(in.et.idx[0].ei_block_end);
                        }
                        fsck_salvage_note(ino, leaf_lba, rlo, rhi);
                        fsck_mark_run(&rc, leaf_lba, 1, ino); /* the leaf block itself */
                    } else {
                        repair_block("an extent leaf failed its tail checksum, so the blocks the inode "
                                     "owns cannot be distinguished from leaked ones");
                        tree_ok = 0;
                    }
                } else {
                    lh = (cetrafs_extent_hdr_t *) leafblk;
                    n = cetrafs_le16(lh->eh_entries) > CETRAFS_EXT_BLOCK_MAX_LEAVES ? CETRAFS_EXT_BLOCK_MAX_LEAVES : cetrafs_le16(lh->eh_entries);
                    for (uint32_t e = 0; e < n; ++e) {
                        const cetrafs_extent_t *x = (const cetrafs_extent_t *) (leafblk + sizeof(*lh)) + e;
                        uint64_t phys = ((uint64_t) cetrafs_le16(x->ee_start_hi) << 32) | cetrafs_le32(x->ee_start_lo);

                        fsck_mark_run(&rc, phys, cetrafs_le32(x->ee_len) & CETRAFS_EXT_LEN_MASK, ino);
                        problems += fsck_extent_logical(ino, x, 0, 0) && !fsck_dead_walk;
                        extents_seen++;
                    }
                    fsck_mark_run(&rc, leaf_lba, 1, ino); /* the leaf block itself */
                }
            } else {
                /* depth 2: interiors -> leaves -> extents */
                uint8_t idxblk[CETRAFS_BLOCK_SIZE];
                uint32_t ni = cetrafs_le16(in.eh.eh_entries) > 4 ? 4 : cetrafs_le16(in.eh.eh_entries);

                /* An empty depth-2 node is refused by the kernel's append
                 * (-EUCLEAN): a tree is only ever deepened with entries. */
                if (ni == 0) {
                    fprintf(stderr, "%s: inode %" PRIu64 " has a depth-2 extent tree with no entries\n", FSCK_SEV, ino);
                    problems += !fsck_dead_walk;
                    /* And a count rotted to 0 hides the whole tree from
                     * this walk: its blocks would read as leaked. */
                    repair_block("a depth-2 extent tree claims no entries, so the blocks the inode owns cannot be "
                                 "distinguished from leaked ones");
                }

                for (uint32_t i = 0; i < ni && tree_ok; ++i) {
                    uint64_t ilba = ((uint64_t) cetrafs_le16(in.et.idx[i].ei_leaf_hi) << 32) | cetrafs_le32(in.et.idx[i].ei_leaf_lo);
                    cetrafs_extent_hdr_t *ih;
                    uint32_t iln;

                    if (!fsck_lba_in_range(ilba, cetrafs_le64(sb.total_blocks))) {
                        fprintf(stderr,
                                "%s: inode %" PRIu64 "'s extent index (block %" PRIu64 ") is out of range\n",
                                FSCK_SEV, ino, ilba);
                        problems += !fsck_dead_walk;
                        repair_block("an extent index lba is out of range, so the blocks the inode "
                                     "owns cannot be distinguished from leaked ones");
                        tree_ok = 0;
                        break;
                    }
                    pread_all(fd, idxblk, sizeof(idxblk), (off_t) ilba * CETRAFS_BLOCK_SIZE);
                    if (fsck_check_tail(idxblk, CETRAFS_INDEX_TAIL_MAGIC) != 0) {
                        fprintf(stderr,
                                "%s: inode %" PRIu64 "'s extent index (block %" PRIu64 ") failed its tail checksum\n",
                                FSCK_SEV, ino, ilba);
                        problems += !fsck_dead_walk;
                        repair_block("an extent index failed its tail checksum, so the blocks the inode "
                                     "owns cannot be distinguished from leaked ones");
                        tree_ok = 0;
                        break;
                    }
                    fsck_mark_run(&rc, ilba, 1, ino); /* the interior block itself */
                    ih = (cetrafs_extent_hdr_t *) idxblk;
                    iln = cetrafs_le16(ih->eh_entries) > CETRAFS_EXT_BLOCK_MAX_IDX ? CETRAFS_EXT_BLOCK_MAX_IDX : cetrafs_le16(ih->eh_entries);
                    if (iln == 0) {
                        fprintf(stderr, "%s: inode %" PRIu64 "'s extent index (block %" PRIu64 ") has no entries\n",
                                FSCK_SEV, ino, ilba);
                        problems += !fsck_dead_walk;
                        repair_block("an extent index claims no entries, so the blocks the inode owns cannot be "
                                     "distinguished from leaked ones");
                    }

                    for (uint32_t li = 0; li < iln && tree_ok; ++li) {
                        const cetrafs_extent_idx_t *ie = (const cetrafs_extent_idx_t *) (idxblk + sizeof(*ih)) + li;
                        uint64_t llba = ((uint64_t) cetrafs_le16(ie->ei_leaf_hi) << 32) | cetrafs_le32(ie->ei_leaf_lo);
                        cetrafs_extent_hdr_t *lh;
                        uint32_t n;
                        /* The narrowest range the lookup filters this
                         * leaf by: the root slot's and the interior
                         * entry's (cetrafs_idx_may_hold(); end 0 means
                         * no filter). */
                        uint64_t rlo = 0, rhi = 0;

                        if (cetrafs_le32(in.et.idx[i].ei_block_end)) {
                            rlo = cetrafs_le32(in.et.idx[i].ei_block);
                            rhi = cetrafs_le32(in.et.idx[i].ei_block_end);
                        }
                        if (cetrafs_le32(ie->ei_block_end)) {
                            if (!rhi || cetrafs_le32(ie->ei_block) > rlo)
                                rlo = cetrafs_le32(ie->ei_block);
                            if (!rhi || cetrafs_le32(ie->ei_block_end) < rhi)
                                rhi = cetrafs_le32(ie->ei_block_end);
                        }

                        if (!fsck_lba_in_range(llba, cetrafs_le64(sb.total_blocks))) {
                            fprintf(stderr,
                                    "%s: inode %" PRIu64 "'s extent leaf (block %" PRIu64 ") is out of range\n",
                                    FSCK_SEV, ino, llba);
                            problems += !fsck_dead_walk;
                            repair_block("an extent leaf lba is out of range, so the blocks the inode "
                                         "owns cannot be distinguished from leaked ones");
                            tree_ok = 0;
                            break;
                        }
                        pread_all(fd, leafblk, sizeof(leafblk), (off_t) llba * CETRAFS_BLOCK_SIZE);
                        if (fsck_check_tail(leafblk, CETRAFS_LEAF_TAIL_MAGIC) != 0) {
                            fprintf(stderr,
                                    "%s: inode %" PRIu64 "'s extent leaf (block %" PRIu64
                                    ") failed its tail checksum\n",
                                    FSCK_SEV, ino, llba);
                            problems += !fsck_dead_walk;
                            if (fsck_salvage_candidate(&in, leafblk)) {
                                /* Salvaged after the namespace pass; the
                                 * rest of the tree is still walked, or
                                 * its blocks would read as leaked. */
                                fsck_salvage_note(ino, llba, rlo, rhi);
                                fsck_mark_run(&rc, llba, 1, ino);
                                continue;
                            }
                            repair_block("an extent leaf failed its tail checksum, so the blocks the inode "
                                         "owns cannot be distinguished from leaked ones");
                            tree_ok = 0;
                            break;
                        }
                        fsck_mark_run(&rc, llba, 1, ino); /* the leaf block itself */
                        lh = (cetrafs_extent_hdr_t *) leafblk;
                        n = cetrafs_le16(lh->eh_entries) > CETRAFS_EXT_BLOCK_MAX_LEAVES ? CETRAFS_EXT_BLOCK_MAX_LEAVES : cetrafs_le16(lh->eh_entries);
                        for (uint32_t e = 0; e < n; ++e) {
                            const cetrafs_extent_t *x = (const cetrafs_extent_t *) (leafblk + sizeof(*lh)) + e;
                            uint64_t phys = ((uint64_t) cetrafs_le16(x->ee_start_hi) << 32) | cetrafs_le32(x->ee_start_lo);

                            fsck_mark_run(&rc, phys, cetrafs_le32(x->ee_len) & CETRAFS_EXT_LEN_MASK, ino);
                            problems += fsck_extent_logical(ino, x, rlo, rhi) && !fsck_dead_walk;
                            extents_seen++;
                        }
                    }
                }
            }

            if (!tree_ok)
                continue; /* a bad tail already reported; its blocks look leaked, repair refused */
            problems += fsck_lruns_overlap(ino) && !fsck_dead_walk;
            fsck_salvage_attach_lruns(ino);

            /* The xattr block is a referenced data block too (all depths).
             * Verify its tail; counted referenced even with a bad tail --
             * the block is still this inode's, and freeing it would be the
             * same cross-link corruption again. */
            if (xattr_lba && !fsck_lba_in_range(xattr_lba, cetrafs_le64(sb.total_blocks))) {
                fprintf(stderr, "%s: inode %" PRIu64 "'s xattr block (block %" PRIu64 ") is out of range\n",
                        FSCK_SEV, ino, xattr_lba);
                problems += !fsck_dead_walk;
            } else if (xattr_lba) {
                uint8_t xblk[CETRAFS_BLOCK_SIZE];

                pread_all(fd, xblk, sizeof(xblk), (off_t) xattr_lba * CETRAFS_BLOCK_SIZE);
                if (fsck_check_tail(xblk, CETRAFS_XATTR_TAIL_MAGIC) != 0) {
                    fprintf(stderr, "%s: inode %" PRIu64 "'s xattr block (block %" PRIu64 ") failed its tail checksum\n",
                            FSCK_SEV, ino, xattr_lba);
                    problems += !fsck_dead_walk;
                }
                fsck_mark_run(&rc, xattr_lba, 1, ino);
            }
            if (fsck_dead_walk && stale_blocks > stale_before)
                fprintf(stderr,
                        "WARN: inode %" PRIu64 " (deleted, not yet reclaimed) still names %" PRIu64
                        " block(s) another file now holds -- stale extents, dropped when the number is "
                        "reclaimed\n",
                        ino, stale_blocks - stale_before);
        }
        fsck_dead_walk = 0;

        /* Blocks sitting in a per-ZG pending-free queue are marked used
         * and referenced by nothing -- legitimately so, until their
         * owner drains the queue. Count them as referenced here, or
         * every volume with a queued cross-node free would report
         * phantom leaks, and a warning that cries wolf is one nobody
         * reads.
         *
         * A queued block that a file ALSO references is the opposite
         * case and a fault: the drain consumes an entry before applying
         * it, so an entry still queued has never been applied, and
         * applying it frees a block a live file names -- the allocator
         * then hands it to a second file. The reference wins; repair
         * drops the entry (the drain's own way of consuming one: zero
         * it), and any block of it nothing references is then an
         * ordinary leak the pass below reclaims. A block queued twice
         * is the same fault one drain later, and is treated the same. */
        uint64_t pending = 0, queued_live = 0;
        uint8_t *queued = (uint8_t *) xcalloc(bmwords, 1);
        if (sb.pending_free_start && sb.pending_free_blocks_per_zg) {
            for (uint32_t z = 0; z < cetrafs_le32(sb.zone_group_count); ++z) {
                for (uint32_t qb = 0; qb < cetrafs_le32(sb.pending_free_blocks_per_zg); ++qb) {
                    uint8_t q[CETRAFS_BLOCK_SIZE];
                    uint64_t qlba = cetrafs_le64(sb.pending_free_start) + (uint64_t) z * cetrafs_le32(sb.pending_free_blocks_per_zg) + qb;
                    int q_dirty = 0;

                    pread_all(fd, q, sizeof(q), (off_t) qlba * CETRAFS_BLOCK_SIZE);
                    for (uint32_t e = 0; e < CETRAFS_PENDING_FREE_PER_BLOCK; ++e) {
                        cetrafs_pending_free_t pe;
                        uint64_t live_lba = 0;
                        int live = 0;

                        memcpy(&pe, q + e * sizeof(pe), sizeof(pe));
                        if (!cetrafs_le64(pe.lba) || cetrafs_le32(pe.magic) != CETRAFS_PENDING_FREE_MAGIC || !cetrafs_le32(pe.count))
                            continue;
                        /* Pass 1: does any block of this entry already
                         * have an owner -- a file, or an earlier entry? */
                        for (uint32_t k = 0; k < cetrafs_le32(pe.count) && !live; ++k) {
                            uint64_t lba = cetrafs_le64(pe.lba) + k, ix = 0;

                            for (uint32_t b = 0; b < cetrafs_le32(sb.block_group_count); ++b) {
                                if (lba >= bg_data_start[b] && lba < bg_data_start[b] + bg_data_cnt[b]) {
                                    ix += lba - bg_data_start[b];
                                    /* A deleted record's claim does not make a
                                     * block live: freeing it is what the queue
                                     * is for. */
                                    if ((FSCK_GET(refd, ix) && !FSCK_GET(weakd, ix)) || FSCK_GET(queued, ix)) {
                                        live = 1;
                                        live_lba = lba;
                                    }
                                    break;
                                }
                                ix += bg_data_cnt[b];
                            }
                        }
                        if (live) {
                            if (queued_live < 8)
                                fprintf(stderr,
                                        "ERR: block %" PRIu64 " is queued for free in Zone Group %u (entry %" PRIu64
                                        "+%u) but is still in use -- draining the queue would free live data\n",
                                        live_lba, z, (uint64_t) cetrafs_le64(pe.lba), cetrafs_le32(pe.count));
                            queued_live++;
                            problems++;
                            /* class 45: keep -- a dropped queue entry leaks the block, never frees it */
                            if (repair_mode && !repair_blocked) {
                                memset(q + e * sizeof(pe), 0, sizeof(pe));
                                q_dirty = 1;
                                repairs_made++;
                                continue; /* dropped: its blocks are queued no longer */
                            }
                        }
                        /* Pass 2: count it as queued. */
                        for (uint32_t k = 0; k < cetrafs_le32(pe.count); ++k) {
                            uint64_t lba = cetrafs_le64(pe.lba) + k, ix = 0;

                            for (uint32_t b = 0; b < cetrafs_le32(sb.block_group_count); ++b) {
                                if (lba >= bg_data_start[b] && lba < bg_data_start[b] + bg_data_cnt[b]) {
                                    ix += lba - bg_data_start[b];
                                    FSCK_SET(queued, ix);
                                    if (!FSCK_GET(refd, ix)) {
                                        FSCK_SET(refd, ix); /* queued, not leaked */
                                        pending++;
                                    }
                                    break;
                                }
                                ix += bg_data_cnt[b];
                            }
                        }
                    }
                    if (q_dirty)
                        pwrite_all(fd, q, sizeof(q), (off_t) qlba * CETRAFS_BLOCK_SIZE);
                }
            }
        }
        free(queued);

        /* Reconcile what is referenced against what the bitmaps claim.
         * A block marked used but referenced by nothing is a leak; one
         * referenced but marked free will be handed out again. */
        uint64_t leaked = 0, unmarked = 0, idx = 0, miscounted = 0, stale_free = 0;
        /* Test knob only: a pause between the last heartbeat and this
         * pass's writes, so a suite can have a node appear there
         * (tests/kernel/fsck_write_after_lost_claim.sh). Unset normally. */
        if (repair_mode && getenv("CETRAFS_TEST_FSCK_HOLD_BEFORE_BG_PASS_SECS")) {
            printf("  holding before the block group pass (test)\n");
            fflush(stdout);
            cetrafs_sleep_full((unsigned) atoi(getenv("CETRAFS_TEST_FSCK_HOLD_BEFORE_BG_PASS_SECS")));
        }
        for (uint32_t b = 0; b < cetrafs_le32(sb.block_group_count); ++b) {
            uint64_t bmap_blocks = (bg_data_cnt[b] + CETRAFS_BLOCK_SIZE * 8 - 1) / (CETRAFS_BLOCK_SIZE * 8);
            uint8_t *bmap = (uint8_t *) xcalloc(bmap_blocks ? bmap_blocks : 1, CETRAFS_BLOCK_SIZE);
            uint64_t really_free = 0;
            int bmap_dirty = 0;

            pread_all(fd, bmap, (size_t) bmap_blocks * CETRAFS_BLOCK_SIZE, (off_t) bg_bmap_lba[b] * CETRAFS_BLOCK_SIZE);
            for (uint64_t i = 0; i < bg_data_cnt[b]; ++i, ++idx) {
                int marked = (bmap[i / 8] & (1u << (i % 8))) != 0;
                int is_refd = FSCK_GET(refd, idx) != 0;

                if (marked && !is_refd) {
                    leaked++;
                    /* CETRAFS_FSCK_DUMP_LEAKS=1: one line per leaked
                     * block, for post-mortem correlation against traces
                     * (who allocated it, who should have freed it). */
                    if (getenv("CETRAFS_FSCK_DUMP_LEAKS"))
                        fprintf(stderr, "LEAK: lba=%" PRIu64 "\n", bg_data_start[b] + i);
                    /* Nothing ALLOCATED references it -- the 128 MiB
                     * evict_inode class, which until now could only be
                     * recovered by reformatting. But this pass sees only
                     * records whose bit is set: a file a directory still
                     * names, whose inode bit is clear, owns blocks that
                     * look exactly like these, and only the namespace
                     * pass (later) finds that dirent and stops repairs.
                     * Clearing here freed that file's data first. So the
                     * clear waits for the namespace pass, and happens
                     * only if nothing there blocked repair; the bit
                     * stays counted as used until then. */
                    /* class 45: deferred -- this only marks; the clear runs after the namespace pass */
                    if (repair_mode && !repair_blocked && !fsck_dead_unwalkable) {
                        FSCK_SET(leakd, idx);
                        leak_deferred++;
                    }
                } else if (!marked && is_refd && FSCK_GET(weakd, idx)) {
                    /* Named only by a deleted record: its previous
                     * life's free already happened. Stale, not live, and
                     * left free. Setting the bit would only leak it: an
                     * unnamed deleted record is freed by this same run.
                     * A record whose nlink drifted to 0 while a name
                     * still points at it is the one case where the
                     * block is wanted -- the namespace pass reports that
                     * as ERR and repairs the nlink, and the next run
                     * walks the record as live and sets the bit then.
                     * Nothing allocates between two offline runs. */
                    stale_free++;
                } else if (!marked && is_refd) {
                    if (unmarked < 8)
                        fprintf(stderr,
                                "ERR: block %" PRIu64
                                " is referenced by an inode but marked FREE -- it can be "
                                "handed out again\n",
                                bg_data_start[b] + i);
                    unmarked++;
                    /* A live extent names it, so the bit must be set:
                     * leaving it clear means the allocator hands the
                     * same block to a second file. */
                    /* class 45: set -- marking a named block in use can only leak */
                    if (repair_mode && !repair_blocked) {
                        bmap[i / 8] |= (uint8_t) (1u << (i % 8));
                        bmap_dirty = 1;
                        marked = 1;
                        repairs_made++;
                    }
                }
                if (!marked)
                    really_free++;
            }

            if (bmap_dirty)
                pwrite_all(fd, bmap, (size_t) bmap_blocks * CETRAFS_BLOCK_SIZE,
                           (off_t) bg_bmap_lba[b] * CETRAFS_BLOCK_SIZE);
            /* The BG's own cached free_data_blocks against what its
             * bitmap actually says.
             *
             * Nothing checked this. The ZG<->sum(BG) cross-check above
             * only proves the two CACHED numbers agree with each other,
             * so a counter that drifted from its bitmap -- a double free
             * crediting a block twice, say -- stays invisible while both
             * halves remain consistently wrong. That number is what
             * statfs reports and what the allocator uses to choose which
             * Block Group to write to, so a drift makes the filesystem
             * claim space it does not have and allocate badly, with
             * nothing offline to notice.
             *
             * The bitmap is already being walked right here for the
             * reachability reconciliation, so the popcount is free. */
            if (bg_free_cached[b] != really_free) {
                fprintf(stderr,
                        "ERR: BG%u cached free_data_blocks %" PRIu64 " != %" PRIu64 " actually free in its bitmap\n", b,
                        bg_free_cached[b], really_free);
                miscounted++;
                /* The bitmap is the truth and has just been walked (and,
                 * above, corrected), so there is exactly one right
                 * answer. Rewrite the descriptor with its checksum
                 * restamped the same way mkfs does. */
                /* class 45: recount -- the count from the bitmap just walked */
                if (repair_mode && !repair_blocked) {
                    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
                    cetrafs_block_group_t bgd;

                    pread_all(fd, blk, sizeof(blk), (off_t) bg_desc_lba[b] * CETRAFS_BLOCK_SIZE);
                    memcpy(&bgd, blk, sizeof(bgd));
                    bgd.free_data_blocks = cetrafs_cpu_to_le64(really_free);
                    bgd.checksum = 0;
                    /* Exactly the convention mkfs stamps with and the
                     * structural pass above verifies -- plain-native,
                     * over the struct with the checksum field zeroed. */
                    bgd.checksum = cetrafs_cpu_to_le64(crc32c_struct(&bgd, sizeof(bgd), offsetof(cetrafs_block_group_t, checksum),
                                                 sizeof(bgd.checksum)));
                    memcpy(blk, &bgd, sizeof(bgd));
                    pwrite_all(fd, blk, sizeof(blk), (off_t) bg_desc_lba[b] * CETRAFS_BLOCK_SIZE);
                    repairs_made++;
                }
            }
            /* Carry the corrected figure, so the ZG aggregate below is
             * rebuilt from repaired numbers rather than stale ones. */
            bg_free_cached[b] = really_free;
            /* An unowned Block Group belongs to no Zone Group, so its
             * free space is in nobody's aggregate -- and indexing
             * zg_free_truth with CETRAFS_BG_OWNER_FREE would run off
             * the end of an array sized by the Zone Group count. */
            if (bg_owner_expected[b] != CETRAFS_BG_OWNER_FREE)
                zg_free_truth[bg_owner_expected[b]] += really_free;
            else
                /* ...except in the sharded pool, which exists precisely
                 * so that handed-back capacity is counted SOMEWHERE and
                 * statfs does not shrink by 512 MiB per release. */
                zg_pool_truth[b % cetrafs_le32(sb.zone_group_count)] += really_free;

            free(bmap);
        }

        /* The Zone Group aggregates, rebuilt from the bitmaps the loop
         * above just walked. The structural pass already compared each
         * aggregate against the SUM OF THE CACHED per-BG numbers, which
         * only proves the two caches agree with each other; this compares
         * it against what the bitmaps actually hold, and is the figure
         * the allocator's claim preference reads. */
        for (uint32_t z = 0; z < cetrafs_le32(sb.zone_group_count); ++z) {
            uint8_t zblk[CETRAFS_BLOCK_SIZE] = {0};
            cetrafs_zone_group_t zg;

            pread_all(fd, zblk, sizeof(zblk), (off_t) (cetrafs_le64(sb.zg_table_start) + z) * CETRAFS_BLOCK_SIZE);
            memcpy(&zg, zblk, sizeof(zg));
            int agg_ok = cetrafs_le64(zg.free_data_blocks) == zg_free_truth[z];
            int pool_ok = cetrafs_le64(zg.pool_free_blocks) == zg_pool_truth[z];

            if (agg_ok && pool_ok)
                continue;
            if (!pool_ok) {
                fprintf(stderr,
                        "ERR: ZG%u pool_free_blocks %" PRIu64 " != %" PRIu64
                        " actually free in the unowned Block Groups sharded to it\n",
                        z, (uint64_t) cetrafs_le64(zg.pool_free_blocks), zg_pool_truth[z]);
                problems++;
            }

            if (!agg_ok) {
                fprintf(stderr,
                        "ERR: ZG%u aggregate free_data_blocks %" PRIu64 " != %" PRIu64
                        " actually free in its Block Groups\n",
                        z, (uint64_t) cetrafs_le64(zg.free_data_blocks), zg_free_truth[z]);
                problems++;
            }
            /* class 45: recount -- the aggregate from its Block Groups */
            if (repair_mode && !repair_blocked) {
                zg.free_data_blocks = cetrafs_cpu_to_le64(zg_free_truth[z]);
                zg.pool_free_blocks = cetrafs_cpu_to_le64(zg_pool_truth[z]);
                /* free_data_blocks is a HOT field (v0x0008): only the
                 * hot half's checksum covers it. */
                zg.hot_checksum = 0;
                memcpy(zblk, &zg, sizeof(zg));
                zg.hot_checksum = cetrafs_cpu_to_le64((uint64_t) crc32c_struct(
                    (const uint8_t *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                    offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF, sizeof(zg.hot_checksum)));
                memcpy(zblk, &zg, sizeof(zg));
                pwrite_all(fd, zblk, sizeof(zblk), (off_t) (cetrafs_le64(sb.zg_table_start) + z) * CETRAFS_BLOCK_SIZE);
                repairs_made++;
            }
        }

        if (miscounted)
            problems += miscounted;
        if (leaked)
            fprintf(stderr, "WARN: %" PRIu64 " data block(s) marked in use but referenced by no inode (leaked)\n",
                    leaked);
        /* class 45: a message, not a repair */
        if (leaked && repair_mode && !repair_blocked && fsck_dead_unwalkable)
            fprintf(stderr, "NOTE: leaked blocks are not cleared this run: a deleted record's extent tree could "
                            "not be walked, and the blocks it hides cannot be told from leaked ones -- run fsck "
                            "-r again once the record is gone\n");
        if (stale_free)
            fprintf(stderr,
                    "WARN: %" PRIu64 " block(s) named only by deleted, not yet reclaimed records are already free "
                    "-- stale extents\n",
                    stale_free);
        if (unmarked) {
            fprintf(stderr, "ERR: %" PRIu64 " data block(s) in use but marked free\n", unmarked);
            problems += unmarked;
        }

        printf("  content: %" PRIu64 " inodes, %" PRIu64 " extents, %" PRIu64 " data blocks referenced", inodes_seen,
               extents_seen, blocks_referenced);
        if (pending)
            printf(", %" PRIu64 " queued for free", pending);
        if (leaked)
            printf(", %" PRIu64 " leaked", leaked);
        printf("\n");

        free(refd);
        free(dupd);
        free(weakd);
#undef FSCK_SET
#undef FSCK_GET

        /* ---- namespace pass -------------------------------------
         *
         * Blocks are now accounted for; names are not. An inode can be
         * allocated, checksum-clean and holding perfectly good extents
         * while NO directory entry points at it -- which is exactly what
         * a lost dirent leaves behind, and what nothing in
         * this tool could see until now. Walk every directory, tally the
         * references each inode actually receives, and compare.
         */
        uint32_t *refs = (uint32_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint32_t));
        /* '.' and '..' targets per directory, plus the parent that
         * actually names each inode -- so '..' can be checked against
         * where the tree really puts this directory, not just against
         * "some directory". 0 means "not seen". */
        uint32_t *dot_tgt = (uint32_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint32_t));
        uint32_t *dotdot_tgt = (uint32_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint32_t));
        uint32_t *parent = (uint32_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint32_t));
        uint8_t *walked = (uint8_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, 1);
        uint32_t *nlinks = (uint32_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint32_t));
        uint8_t *is_dir = (uint8_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, 1);
        /* A regular file that holds nothing at all: no size, no extent,
         * no xattr block. Unnamed, it is what a create stopped between
         * its record write and its directory entry leaves, and there is
         * nothing in it to recover. */
        uint8_t *empty = (uint8_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, 1);
        /* How many SUBDIRECTORIES each directory contains. A directory's
         * link count is 2 (itself, plus its own '.') plus one per
         * subdirectory, contributed by that child's '..'. Nothing
         * checked it: the reference tally below deliberately skips
         * directories, because entries naming one do not add to its
         * nlink the way a hardlink does -- which left a directory's
         * nlink validated by nothing at all, even though every
         * add_entry/remove_entry maintains it and several of this
         * review's findings touched that bookkeeping. */
        uint32_t *subdirs = (uint32_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint32_t));
        /* Subdirectories this run linked in after the tally was taken
         * (lost+found into root, an orphan directory into lost+found):
         * on disk the parent's nlink already counts each, and the
         * checks below must too, or a repair of a count that was wrong
         * anyway writes one that leaves them out (audit 2026-11-06 L10). */
        uint32_t *dir_gain = (uint32_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint32_t));
        /* Which directory names each DIRECTORY, for the reachability
         * walk below. One slot is enough because this format cannot
         * represent a directory with two parents: '..' is a single
         * dirent, which is why cetrafs_link() refuses to hardlink a
         * directory at all. Directories therefore form a tree, and
         * reachability is just "does the parent chain reach the root",
         * with no extra I/O and no edge list to store. */
        uint32_t *dir_parent = (uint32_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint32_t));
        /* A directory's size is a count: sizeof(cetrafs_dirent_t) per
         * occupied slot, '.' and '..' included -- mkdir starts it at two,
         * every add_entry/remove_entry moves it by one (dir.c). Nothing
         * checked it, so a size left wrong (a lost publish, a crash
         * between the entry and the record) stayed wrong for good, every
         * later create and unlink adjusting the wrong number
         * (tests/kernel/nslock_fd_publish_error.sh). dslots[] counts what
         * the walk finds; dwhole[] says the walk saw EVERY block, the
         * only case in which that count is the truth. */
        uint64_t *dsize = (uint64_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint64_t));
        uint32_t *dslots = (uint32_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint32_t));
        uint8_t *dwhole = (uint8_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, 1);
        uint64_t dirents_seen = 0;

        /*
         * Pass A: every allocated inode's type and link count, before
         * any directory is walked.
         *
         * This used to be folded into the walk below, which made
         * is_dir[] only valid for inodes the loop had already REACHED --
         * so counting a directory's subdirectories from it saw zero for
         * every child with a higher inode number, which is nearly all of
         * them. Root, walked first, therefore always appeared to contain
         * none. The subdirectory check added for this is only meaningful
         * with the type of every target already known.
         */
        for (uint64_t ino = 1; ino <= cetrafs_le32(sb.inodes_count); ++ino) {
            fsck_repair_heartbeat();
            uint64_t bit = ino - 1;
            uint8_t iblk[CETRAFS_BLOCK_SIZE];
            cetrafs_inode_t in;

            if (!(ibmap[bit / 8] & (1u << (bit % 8))))
                continue;
            pread_all(fd, iblk, sizeof(iblk), (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE);
            memcpy(&in, iblk, sizeof(in));
            if (!cetrafs_inode_crcs_ok(&in))
                continue; /* already reported above */
            nlinks[ino] = cetrafs_le32(in.nlink);
            is_dir[ino] = ((cetrafs_le32(in.mode) & 0170000u) == 0040000u);
            dsize[ino] = cetrafs_le64(in.size);
            empty[ino] = (cetrafs_le32(in.mode) & 0170000u) == 0100000u && !cetrafs_le64(in.size) &&
                         !cetrafs_le64(in.xattr_block) && (in.eh.eh_magic == 0 || !cetrafs_le16(in.eh.eh_entries));
        }

        /* Pass B: walk every directory's entries. */
        for (uint64_t ino = 1; ino <= cetrafs_le32(sb.inodes_count); ++ino) {
            fsck_repair_heartbeat();
            uint64_t bit = ino - 1;
            uint8_t iblk[CETRAFS_BLOCK_SIZE];
            cetrafs_inode_t in;

            if (!(ibmap[bit / 8] & (1u << (bit % 8))))
                continue;
            pread_all(fd, iblk, sizeof(iblk), (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE);
            memcpy(&in, iblk, sizeof(in));
            if (!cetrafs_inode_crcs_ok(&in))
                continue; /* already reported above */

            if (!is_dir[ino])
                continue;
            /*
             * A directory the walk cannot follow used to be skipped in
             * silence. Its names are then invisible to the reference
             * count: a child named only there reads as unreachable, one
             * also named elsewhere has its nlink "repaired" DOWN -- the
             * destructive direction, a later unlink of the other name
             * freeing an inode this directory still names. The kernel
             * refuses such a directory (directories never grow past
             * depth 1), so it is a fault, and one this run cannot repair
             * around.
             */
            if (cetrafs_le16(in.eh.eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(in.eh.eh_depth) > 1) {
                fprintf(stderr,
                        "ERR: directory inode %" PRIu64 " has an extent tree a directory cannot have (magic=0x%x "
                        "depth=%u) -- its entries cannot be read\n",
                        ino, cetrafs_le16(in.eh.eh_magic), cetrafs_le16(in.eh.eh_depth));
                problems++;
                repair_block("a directory's entries cannot be read, so no link count can be trusted");
                continue;
            }
            /* Its blocks are about to be walked, so '.'/'..' recorded
             * below are meaningful for it. A directory skipped above was
             * never looked at and must not be reported as missing them. */
            walked[ino] = 1;
            dwhole[ino] = 1; /* until a block is skipped below */

            cetrafs_extent_t ext[4 + CETRAFS_EXT_BLOCK_MAX_LEAVES];
            uint32_t n;
            uint8_t leafblk[CETRAFS_BLOCK_SIZE];

            if (in.eh.eh_depth == 0) {
                n = cetrafs_le16(in.eh.eh_entries) > 4 ? 4 : cetrafs_le16(in.eh.eh_entries);
                memcpy(ext, in.et.leaf, n * sizeof(ext[0]));
            } else {
                uint64_t lf = ((uint64_t) cetrafs_le16(in.et.idx[0].ei_leaf_hi) << 32) | cetrafs_le32(in.et.idx[0].ei_leaf_lo);

                /* The index entry is read off the device, so the leaf it
                 * names may be anywhere. Past total_blocks the multiply
                 * below is signed-overflow UB before it is even a bad
                 * read -- the reason fsck_lba_in_range() exists. */
                if (!fsck_lba_in_range(lf, total_blocks)) {
                    fprintf(stderr,
                            "ERR: directory inode %" PRIu64 " names extent leaf block %" PRIu64 ", which is not on the device\n",
                            ino, lf);
                    problems++;
                    dwhole[ino] = 0;
                    continue;
                }
                pread_all(fd, leafblk, sizeof(leafblk), (off_t) lf * CETRAFS_BLOCK_SIZE);
                cetrafs_extent_hdr_t *lh = (cetrafs_extent_hdr_t *) leafblk;
                n = cetrafs_le16(lh->eh_entries) > CETRAFS_EXT_BLOCK_MAX_LEAVES ? CETRAFS_EXT_BLOCK_MAX_LEAVES : cetrafs_le16(lh->eh_entries);
                memcpy(ext, leafblk + sizeof(*lh), n * sizeof(ext[0]));
            }

            uint64_t logical = 0;

            for (uint32_t e = 0; e < n; ++e) {
                uint64_t phys = ((uint64_t) cetrafs_le16(ext[e].ee_start_hi) << 32) | cetrafs_le32(ext[e].ee_start_lo);
                uint64_t len = cetrafs_le32(ext[e].ee_len) & CETRAFS_EXT_LEN_MASK;

                /* Judge the whole run before reading a single block of
                 * it -- see fsck_run_bg(). The content pass reports the
                 * same extent through fsck_mark_run(), so this walk only
                 * has to decline to follow it: skipping leaves the names
                 * it would have held unseen, which the reachability pass
                 * reports as what it is rather than as 300,000 lines. */
                if (fsck_run_bg(bg_data_start, bg_data_cnt, cetrafs_le32(sb.block_group_count), phys, len, NULL) < 0) {
                    fprintf(stderr,
                            "ERR: directory inode %" PRIu64 " extent [%" PRIu64 ",+%" PRIu64 ") is outside every data region\n",
                            ino, phys, len);
                    problems++;
                    logical += len;
                    dwhole[ino] = 0;
                    continue;
                }

                for (uint64_t k = 0; k < len; ++k, ++logical) {
                    uint8_t db[CETRAFS_BLOCK_SIZE];
                    cetrafs_dirent_tail_t tail;
                    cetrafs_dirent_t *de;

                    pread_all(fd, db, sizeof(db), (off_t) (phys + k) * CETRAFS_BLOCK_SIZE);
                    memcpy(&tail, db + CETRAFS_DIRENT_TAIL_OFF, sizeof(tail));
                    if (cetrafs_le32(tail.magic) != CETRAFS_DIRENT_TAIL_MAGIC) {
                        fprintf(stderr, "ERR: directory inode %" PRIu64 " block %" PRIu64 " has no dirent-tail magic\n",
                                ino, phys + k);
                        problems++;
                        note_bad_dirent_block(ino, phys + k, logical == 0);
                        dwhole[ino] = 0;
                        continue;
                    }
                    /* Same convention as dir.c's cetrafs_dirent_block_stamp():
                     * CRC32C over the block's first CETRAFS_DIRENT_TAIL_OFF
                     * bytes. A mismatch on an unmounted volume is real
                     * corruption, not the transient torn read the kernel
                     * retries through -- nothing is writing here. */
                    if (cetrafs_le32(tail.crc) != crc32c_update(0, db, CETRAFS_DIRENT_TAIL_OFF)) {
                        fprintf(stderr,
                                "ERR: directory inode %" PRIu64 " block %" PRIu64 " fails its dirent-tail CRC\n", ino,
                                phys + k);
                        problems++;
                        /* Damage confined to the tail leaves every entry
                         * intact; erasing the block would cost the
                         * directory all of its names for nothing. See
                         * fsck_dirent_block_coherent(). */
                        if (fsck_dirent_block_coherent(db, &sb, logical == 0, ino)) {
                            /* class 45: lossless -- the same entries, re-stamped */
                            if (repair_mode && !repair_blocked) {
                                fsck_stamp_dirent_block(db);
                                pwrite_all(fd, db, sizeof(db), (off_t) (phys + k) * CETRAFS_BLOCK_SIZE);
                                repairs_made++;
                                printf("  re-stamped the dirent tail of block %" PRIu64 " of directory inode %" PRIu64
                                       " -- every entry in it is intact\n",
                                       phys + k, ino);
                            } else {
                                printf("  block %" PRIu64 " of directory inode %" PRIu64
                                       " has an intact entry table: -r would re-stamp its tail\n",
                                       phys + k, ino);
                            }
                            /* Deliberately NOT skipped: the entries are
                             * sound, so counting them keeps nlink and
                             * reachability accurate -- and stops the
                             * orphan pass linking files that are named
                             * right here into /lost+found. */
                        } else {
                            note_bad_dirent_block(ino, phys + k, logical == 0);
                            dwhole[ino] = 0;
                            continue;
                        }
                    }
                    /* A valid checksum over an impossible entry: the
                     * kernel refuses this block on every read
                     * (cetrafs_blk_struct_ok()), so for the namespace it
                     * is as gone as one with a bad tail. Not repaired
                     * around: a name_len past the field cannot be
                     * trusted to say where the name ends. */
                    if (!cetrafs_blk_struct_ok(db, CETRAFS_DIRENT_TAIL_MAGIC)) {
                        fprintf(stderr,
                                "ERR: directory inode %" PRIu64 " block %" PRIu64
                                " passes its checksum but holds an entry with an impossible name length\n",
                                ino, phys + k);
                        problems++;
                        note_bad_dirent_block(ino, phys + k, logical == 0);
                        dwhole[ino] = 0;
                        continue;
                    }

                    de = (cetrafs_dirent_t *) db;
                    for (unsigned s = 0; s < CETRAFS_DIRENTS_PER_BLOCK; ++s) {
                        if (de[s].inode == 0)
                            continue;
                        dirents_seen++;
                        dslots[ino]++; /* every occupied slot is in the size, valid or not */
                        if (cetrafs_le64(de[s].inode) > cetrafs_le32(sb.inodes_count)) {
                            fprintf(stderr,
                                    "ERR: directory %" PRIu64 " has an entry for inode %" PRIu64
                                    " which is out of range\n",
                                    ino, (uint64_t) cetrafs_le64(de[s].inode));
                            problems++;
                            continue;
                        }
                        /* '.' and '..' are structural, not references to
                         * the named file in the nlink sense that matters
                         * here -- they are already accounted for by the
                         * directory's own nlink convention. Recorded
                         * rather than skipped outright, so where they
                         * POINT can be checked after the walk. */
                        if (cetrafs_le16(de[s].name_len) == 1 && de[s].name[0] == '.') {
                            dot_tgt[ino] = cetrafs_le64(de[s].inode);
                            continue;
                        }
                        if (cetrafs_le16(de[s].name_len) == 2 && de[s].name[0] == '.' && de[s].name[1] == '.') {
                            dotdot_tgt[ino] = cetrafs_le64(de[s].inode);
                            continue;
                        }

                        /* Whoever names it is its parent. Recorded for
                         * every entry, consulted only for directories --
                         * which cannot be hardlinked in this format, so
                         * there is exactly one. */
                        parent[cetrafs_le64(de[s].inode)] = (uint32_t) ino;

                        uint64_t t = cetrafs_le64(de[s].inode);
                        uint64_t tb = t - 1;
                        if (!(ibmap[tb / 8] & (1u << (tb % 8)))) {
                            fprintf(stderr,
                                    "ERR: directory %" PRIu64 " names inode %" PRIu64
                                    ", which is marked FREE -- dangling entry\n",
                                    ino, t);
                            problems++;
                            /* Not repaired: removing the entry destroys
                             * a name, and the reference tallies this
                             * pass computes are built from entries that
                             * include this one -- so an nlink "fix"
                             * derived from them would be wrong too. */
                            repair_block(
                                "a directory entry names an inode that is marked free, so the "
                                "reference tallies cannot be trusted");
                        }
                        refs[t]++;

                        /* The dirent's file_type is a COPY of the target's
                         * kind, handed to readdir as d_type; tools that trust
                         * d_type instead of stat (find -type, fts, rsync, tar)
                         * believe it. The inode mode is authoritative, so a
                         * mismatch is not corruption -- a WARN, not an ERR that
                         * would fail an otherwise healthy volume (and N9 found
                         * two kernel sites that once wrote the wrong byte).
                         * Checked DIR-vs-non-DIR, the consequential case that
                         * is_dir[t] already carries. */
                        if (is_dir[t] != (de[s].file_type == CETRAFS_FT_DIR))
                            fprintf(stderr,
                                    "WARN: directory %" PRIu64 " entry for inode %" PRIu64
                                    " has file_type=%u but the inode is %s\n",
                                    ino, t, (unsigned) de[s].file_type,
                                    is_dir[t] ? "a directory" : "not a directory");

                        /* Counted from the TARGET's mode rather than the
                         * entry's file_type: the type byte is a copy,
                         * and this check is worth more if it does not
                         * depend on the copy being right (two code paths were found
                         * that wrote the wrong one). */
                        if (is_dir[t]) {
                            subdirs[ino]++;
                            /* First namer wins: a second one is reported
                             * on its own ("named by N directory entries")
                             * and blocks repair, and picking either gives
                             * the same verdict below. */
                            if (dir_parent[t] == 0)
                                dir_parent[t] = (uint32_t) ino;
                        }
                    }
                }
            }
        }

        /* Before the orphan pass below: it links into lost+found, which
         * moves that directory's entries past what the walk counted. */
        for (uint64_t ino = 1; ino <= cetrafs_le32(sb.inodes_count); ++ino) {
            uint64_t want_size = (uint64_t) dslots[ino] * sizeof(cetrafs_dirent_t);

            if (!is_dir[ino] || !walked[ino] || !dwhole[ino] || dsize[ino] == want_size)
                continue;
            /* class 45: recount -- the size from the entries this walk counted */
            if (repair_mode && !repair_blocked) {
                repair_set_dir_size(fd, &sb, ino, want_size);
                repairs_made++;
            }
            fprintf(stderr,
                    "ERR: directory inode %" PRIu64 " has size %" PRIu64 " but holds %u entries (expected %" PRIu64 ")\n",
                    ino, dsize[ino], dslots[ino], want_size);
            problems++;
        }

        /*
         * A directory named more than once. This format has one '..' per
         * directory, so a second name is never legitimate: it is a
         * directory rename that crashed between adding the new name and
         * removing the old, and removing a directory through either name
         * frees what the other still names. Nothing else here says so --
         * the parents' link counts each include it, and repairing those
         * counts would only make the volume agree with itself around the
         * fault. Checked before the loop below, which repairs as it goes.
         */
        for (uint64_t ino = 2; ino <= cetrafs_le32(sb.inodes_count); ++ino) {
            uint64_t bit = ino - 1;

            if (!(ibmap[bit / 8] & (1u << (bit % 8))) || !is_dir[ino] || refs[ino] <= 1)
                continue;
            fprintf(stderr, "ERR: directory inode %" PRIu64 " is named by %u directory entries -- a directory has one\n",
                    ino, (unsigned) refs[ino]);
            problems++;
            repair_block("a directory has more than one name, so the link counts around it cannot be trusted");
        }

        for (uint64_t ino = 2; ino <= cetrafs_le32(sb.inodes_count); ++ino) {
            uint64_t bit = ino - 1;

            if (!(ibmap[bit / 8] & (1u << (bit % 8))))
                continue;
            /* A lost+found created by THIS loop, a few iterations back.
             * refs[] and nlinks[] were filled from the inode table
             * before it existed, so it reads as an orphan with nlink=0
             * -- unambiguous garbage by the rule below -- and the repair
             * would free the directory it had just grafted the orphans
             * into. Any repair that allocates inside the loop scanning
             * the bitmap has to skip what it allocated. */
            if (lf.ino && ino == lf.ino)
                continue;
            if (refs[ino] == 0) {
                /*
                 * Severity depends on nlink. nlink=0 and unnamed is what
                 * a delete leaves when it could not free the inode.
                 * Unlink refuses a file a live peer has open, so it is
                 * not the normal cross-node result: it needs that check
                 * to race a peer's open, an opener that died holding it
                 * (eviction refuses to free an inode a peer has open,
                 * and a reader-only peer cannot know the file died under
                 * it), or an I/O error mid-free. The number and its
                 * blocks stay allocated, bounded and reclaimable (fsck
                 * -r here; the online scrub on a live volume). That is a
                 * leak to report, not a corruption to fail on.
                 * nlink>0 and unnamed is a different animal entirely --
                 * a LOST NAME, data still wanted with no way to reach it
                 * -- and stays a hard ERR.
                 */
                if (nlinks[ino] == 0) {
                    fprintf(stderr,
                            "WARN: inode %" PRIu64 " is allocated (nlink=0) with no directory entry -- "
                            "deleted but not yet reclaimed\n",
                            ino);
                } else if (empty[ino]) {
                    fprintf(stderr,
                            "WARN: inode %" PRIu64 " is an empty file (nlink=%u) that no directory entry names -- "
                            "a create stopped before adding its name\n",
                            ino, nlinks[ino]);
                } else {
                    fprintf(stderr,
                            "ERR: inode %" PRIu64
                            " is allocated (nlink=%u) but NO directory entry names it -- "
                            "unreachable\n",
                            ino, nlinks[ino]);
                    problems++;
                }
                /*
                 * nlink=0 AND unnamed is unambiguous garbage: unlink
                 * already said so, and the record only survives because
                 * eviction did not finish -- a read failure at evict
                 * time (which deliberately leaves both the number and
                 * the blocks rather than freeing the number and losing
                 * track of the blocks), or a failed symlink unwind.
                 * Until now that space came back only by reformatting.
                 *
                 * Safe precisely here and nowhere else: this tool
                 * refuses to run at all on a volume mounted locally or
                 * carrying a live Node Registry row, so the "unlinked
                 * but still open" case that makes this state legitimate
                 * on a LIVE filesystem cannot be what we are looking at.
                 *
                 * nlink > 0 and unnamed is a different fault -- a lost
                 * dirent, where the data is still wanted -- and links
                 * it into /lost+found as the only repair this tool can make.
                 *
                 * Only the inode bitmap bit is cleared, exactly as the
                 * kernel's cetrafs_free_inode() does. Its data blocks
                 * then become bits marked in use that no allocated
                 * record references, which is the leak the content pass
                 * above already reclaims -- on the NEXT run, since that
                 * pass has been and gone. Hence the note below.
                 */
                if (nlinks[ino] != 0 && empty[ino] && repair_mode && !repair_blocked) {
                    /* Nothing to recover, so free it rather than give it
                     * a /lost+found name. nlink first: the kernel's
                     * allocator refuses a number whose record still
                     * claims links (cetrafs_alloc_inode()). */
                    repair_set_nlink(fd, &sb, ino, 0);
                    ibmap[bit / 8] &= (uint8_t) ~(1u << (bit % 8));
                    ibmap_dirty = 1;
                    orphans_freed++;
                    repairs_made++;
                } else if (nlinks[ino] == 0 && repair_mode && !repair_blocked) {
                    ibmap[bit / 8] &= (uint8_t) ~(1u << (bit % 8));
                    ibmap_dirty = 1;
                    orphans_freed++;
                    repairs_made++;
                } else if (nlinks[ino] > 0 && repair_mode && !repair_blocked) {
                    /* Still claims a link, so its data is still wanted:
                     * give it a name again rather than freeing it. The
                     * name is its inode number, which is the only thing
                     * about it that is still known -- the one that was
                     * lost is exactly what is gone. */
                    uint64_t lfino = fsck_lost_found(fd, &sb, cetrafs_le32(sb.block_group_count), bg_data_start, bg_data_cnt,
                                                     bg_bmap_lba, ibmap, &ibmap_dirty, &lf);
                    char nm[32];
                    cetrafs_inode_t oin;
                    uint8_t ft;

                    /* The type from the record, not DIR-or-REG: a
                     * recovered symlink typed as a regular file is
                     * missed by everything that trusts d_type (audit
                     * 2026-11-06 L26). is_dir[] stays the authority for
                     * directories, which the walk already decided. */
                    fsck_read_inode(fd, &sb, ino, &oin);
                    ft = is_dir[ino] ? CETRAFS_FT_DIR : fsck_ft_for_mode(cetrafs_le32(oin.mode));
                    if (ft == CETRAFS_FT_DIR && !is_dir[ino])
                        ft = CETRAFS_FT_REG;
                    snprintf(nm, sizeof(nm), "#%" PRIu64, ino);
                    if (lfino &&
                        !fsck_dir_link(fd, &sb, cetrafs_le32(sb.block_group_count), bg_data_start, bg_data_cnt, bg_bmap_lba, lfino,
                                       nm, ino, ft)) {
                        /* A recovered DIRECTORY's '..' must name its new
                         * parent, or the tree it has been grafted into
                         * disagrees with itself and the next run says so.
                         * fsck_dir_link() has already bumped
                         * lost+found's nlink for it. */
                        if (is_dir[ino]) {
                            fsck_set_dotdot(fd, &sb, ino, lfino);
                            if (lfino <= cetrafs_le32(sb.inodes_count))
                                dir_gain[lfino]++;
                        }
                        orphans_linked++;
                        repairs_made++;
                    } else {
                        fprintf(stderr,
                                "WARN: inode %" PRIu64 " could not be linked into /lost+found (%s) -- left unnamed\n",
                                ino, lfino ? "no room in it" : "no lost+found");
                    }
                }
            } else if (!is_dir[ino] && refs[ino] != nlinks[ino]) {
                /* The directory entries are the truth: nlink is a cache
                 * of how many of them there are, and P7 showed exactly
                 * how it drifts (a link() increment lost to a peer's
                 * concurrent record write). Setting it to the count has
                 * one right answer. */
                if (repair_mode && !repair_blocked) {
                    repair_set_nlink(fd, &sb, ino, refs[ino]);
                    repairs_made++;
                }
                fprintf(stderr, "ERR: inode %" PRIu64 " has nlink=%u but %u directory entries name it\n", ino,
                        nlinks[ino], refs[ino]);
                problems++;
            }

            /*
             * '.' and '..'. Structural entries every directory must
             * carry: '.' names the directory itself, '..' names the
             * directory that names it (root is its own parent). A
             * rename that moved a directory without rewriting '..'
             * leaves exactly this, and nothing else in this tool looks
             * at it -- the reference tally deliberately skips both.
             */
            if (is_dir[ino] && walked[ino]) {
                if (dot_tgt[ino] == 0) {
                    fprintf(stderr, "ERR: directory inode %" PRIu64 " has no '.' entry\n", ino);
                    problems++;
                } else if (dot_tgt[ino] != ino) {
                    fprintf(stderr, "ERR: directory inode %" PRIu64 " has '.' naming inode %u\n", ino, dot_tgt[ino]);
                    problems++;
                }

                /* 2 for itself and its own '.', plus one per
                 * subdirectory (each child's '..' names it). */
                if (nlinks[ino] + dir_gain[ino] != subdirs[ino] + dir_gain[ino] + 2) {
                    uint32_t want_n = subdirs[ino] + dir_gain[ino] + 2;

                    if (repair_mode && !repair_blocked) {
                        repair_set_nlink(fd, &sb, ino, want_n);
                        repairs_made++;
                    }
                    fprintf(stderr,
                            "ERR: directory inode %" PRIu64
                            " has nlink=%u but contains %u subdirector%s "
                            "(expected %u)\n",
                            ino, nlinks[ino] + dir_gain[ino], subdirs[ino] + dir_gain[ino],
                            subdirs[ino] + dir_gain[ino] == 1 ? "y" : "ies", want_n);
                    problems++;
                }

                uint32_t want = (ino == CETRAFS_ROOT_INO) ? (uint32_t) CETRAFS_ROOT_INO : parent[ino];

                if (dotdot_tgt[ino] == 0) {
                    fprintf(stderr, "ERR: directory inode %" PRIu64 " has no '..' entry\n", ino);
                    problems++;
                } else if (want && dotdot_tgt[ino] != want) {
                    /* want == 0 means nothing names this directory,
                     * already reported above as unreachable; there is no
                     * parent to compare against. */
                    fprintf(stderr,
                            "ERR: directory inode %" PRIu64 " has '..' naming inode %u, but it lives in inode %u\n",
                            ino, dotdot_tgt[ino], want);
                    problems++;
                }
            }
        }

        /* Root is deliberately outside the loop above (nothing NAMES
         * it, so its reference tally is always 0 and the unreachable
         * check would fire on every healthy volume) -- but its link
         * count is as checkable as any other directory's, and it is the
         * one directory every mkdir and rmdir at the top level touches. */
        if (lf.created)
            dir_gain[CETRAFS_ROOT_INO]++; /* lost+found, made above: its root nlink is already on disk */
        if (walked[CETRAFS_ROOT_INO] &&
            nlinks[CETRAFS_ROOT_INO] + dir_gain[CETRAFS_ROOT_INO] != subdirs[CETRAFS_ROOT_INO] + dir_gain[CETRAFS_ROOT_INO] + 2) {
            uint32_t rsub = subdirs[CETRAFS_ROOT_INO] + dir_gain[CETRAFS_ROOT_INO];

            if (repair_mode && !repair_blocked) {
                repair_set_nlink(fd, &sb, CETRAFS_ROOT_INO, rsub + 2);
                repairs_made++;
            }
            fprintf(stderr, "ERR: root directory has nlink=%u but contains %u subdirector%s (expected %u)\n",
                    nlinks[CETRAFS_ROOT_INO] + dir_gain[CETRAFS_ROOT_INO], rsub, rsub == 1 ? "y" : "ies", rsub + 2);
            problems++;
        }

        /* Reachability from the ROOT, as opposed to "named by
         * something".
         *
         * The unreachable check above asks whether ANY directory entry
         * names an inode. That is not the same question: two
         * directories naming each other are each named by something and
         * neither is reachable from the root, so a detached cycle --
         * the residue of an interrupted rename, or of a '..' that was
         * never fixed up -- passes every check in this tool while the
         * space it holds is unreachable to every node forever.
         *
         * Checkable with no extra I/O because directories form a TREE:
         * this format cannot represent one with two parents ('..' is a
         * single dirent, which is why link() refuses a directory), so
         * each has exactly one namer and reachability is just "does the
         * parent chain reach the root". A chain that revisits an inode
         * is a cycle; one that stops at an inode nothing names is a
         * detached subtree. Both are reported against the directory at
         * the top of the detached part rather than against every file
         * underneath it -- one line naming the subtree is more useful
         * than thousands naming its contents, and the contents are
         * unreachable for exactly one reason. */
        {
            /*
             * Each directory's verdict is memoised on every directory its
             * walk passes through: a walk stops at the first one already
             * decided and inherits its answer. Walking every chain from
             * scratch -- and clearing an inodes_count-sized `seen` per
             * directory -- was quadratic: a deep tree, or just many
             * directories on a large inode table, and fsck ran for hours
             * (audit L19). Now every directory is walked once.
             *
             * res: 0 undecided, 1 reaches the root, 2 leads into a cycle,
             * 3 stops at stopat[] (an inode nothing names, or out of
             * range). visit[] holds the id of the walk that marked it, so
             * a walk meeting its own mark is a cycle.
             */
            const uint64_t ninodes = cetrafs_le32(sb.inodes_count);
            uint8_t *res = (uint8_t *) xcalloc(ninodes + 1, 1);
            uint64_t *stopat = (uint64_t *) xcalloc(ninodes + 1, sizeof(uint64_t));
            uint64_t *visit = (uint64_t *) xcalloc(ninodes + 1, sizeof(uint64_t));
            uint64_t detached = 0, ndirs = 0, steps = 0;

            for (uint64_t ino = 2; ino <= ninodes; ++ino) {
                uint64_t bit = ino - 1;
                uint64_t cur, c;
                uint8_t r;
                int cycle;

                if (!(ibmap[bit / 8] & (1u << (bit % 8))) || !is_dir[ino])
                    continue;

                /* Walk up to the root, a decided directory, a break in
                 * the chain, or this walk's own mark. Terminates: every
                 * step either stops or marks a new inode. */
                ndirs++;
                cur = ino;
                stopat[0] = 0;
                for (;;) {
                    if (cur == CETRAFS_ROOT_INO) {
                        r = 1;
                        break;
                    }
                    if (cur == 0 || cur > ninodes) {
                        r = 3;
                        stopat[0] = cur; /* scratch: carried below */
                        break;
                    }
                    if (res[cur]) {
                        r = res[cur];
                        stopat[0] = stopat[cur];
                        break;
                    }
                    if (visit[cur] == ino) {
                        r = 2;
                        break;
                    }
                    visit[cur] = ino;
                    cur = dir_parent[cur];
                    steps++;
                }
                {
                    uint64_t stop = stopat[0];

                    /* Publish the verdict along the path just walked. */
                    for (c = ino; c != CETRAFS_ROOT_INO && c != 0 && c <= ninodes && !res[c]; c = dir_parent[c]) {
                        res[c] = r;
                        stopat[c] = stop;
                    }
                    cur = stop;
                }
                cycle = (r == 2);

                if (r == 1)
                    continue; /* reached the root: fine */

                /* Report the TOP of the detached part only: if this
                 * directory's own parent is also detached, the parent
                 * carries the report. */
                if (!cycle && dir_parent[ino] != 0 && dir_parent[ino] <= cetrafs_le32(sb.inodes_count) && is_dir[dir_parent[ino]])
                    continue;

                if (cycle)
                    fprintf(stderr,
                            "ERR: directory %" PRIu64
                            " is in a parent CYCLE that never reaches the root -- "
                            "it and everything under it is unreachable\n",
                            ino);
                else
                    fprintf(stderr,
                            "ERR: directory %" PRIu64
                            " is not reachable from the root (its parent chain "
                            "stops at inode %" PRIu64 ") -- it and everything under it is detached\n",
                            ino, cur);
                problems++;
                detached++;
            }
            free(res);
            free(stopat);
            free(visit);
            if (detached == 0)
                printf("  namespace: every directory is reachable from the root (%" PRIu64 " walk steps, %" PRIu64
                       " directories)\n",
                       steps, ndirs);
        }

        /*
         * Rebuild any directory block whose dirent tail was unreadable.
         * Deferred to here because '..' names the parent, and the parent
         * is only known once every directory has been walked.
         *
         * Left to the operator this was unfixable by any means the
         * filesystem offers: readdir returns -EIO, so rmdir can never
         * confirm the directory is empty and it cannot be deleted even
         * after its contents have been recovered into /lost+found. The
         * only remaining answer was to reformat the volume.
         */
        if (repair_mode && !repair_blocked && bad_dirent_block_count) {
            for (size_t i = 0; i < bad_dirent_block_count; ++i) {
                uint64_t ino = bad_dirent_blocks[i].ino;
                uint64_t par = (ino == CETRAFS_ROOT_INO) ? (uint64_t) CETRAFS_ROOT_INO : parent[ino];

                /* No parent means nothing names this directory; it has
                 * already been reported unreachable. Point '..' at the
                 * root so the rebuilt block is structurally valid --
                 * /lost+found is where its contents went anyway. */
                if (par == 0 || par > cetrafs_le32(sb.inodes_count))
                    par = CETRAFS_ROOT_INO;

                repair_reinit_dirent_block(fd, bad_dirent_blocks[i].phys, ino, par,
                                           bad_dirent_blocks[i].first_block);
                repairs_made++;
                printf("  rebuilt unreadable dirent block %" PRIu64 " of directory inode %" PRIu64 "%s\n",
                       bad_dirent_blocks[i].phys, ino,
                       bad_dirent_blocks[i].first_block ? " (with '.' and '..')" : "");
            }
            printf("  the directory is readable again and now EMPTY -- anything it held reached "
                   "/lost+found by inode number\n");
        }
        free(bad_dirent_blocks);
        bad_dirent_blocks = NULL;
        bad_dirent_block_count = bad_dirent_block_cap = 0;

        printf("  namespace: %" PRIu64 " directory entries across the tree\n", dirents_seen);
        /* The leaked blocks the content pass set aside, now that the
         * namespace has been walked and nothing in it stopped repair. */
        /* Torn leaves of live files, now that nothing else can claim
         * their blocks (see fsck_salvage_leaves()). Before the leak
         * clear: a kept block leaves the leak set. */
        if (fsck_nsalv && (repair_blocked || fsck_dead_unwalkable)) {
            fprintf(stderr, "NOTE: %zu torn extent leaf/leaves not salvaged: %s\n", fsck_nsalv,
                    repair_blocked ? "another fault blocks repair (see above)" : "a deleted record could not be walked");
        } else if (fsck_nsalv) {
            uint64_t nsalv = fsck_salvage_leaves(fd, bg_data_start, bg_data_cnt, cetrafs_le32(sb.block_group_count),
                                                 leakd, &leak_deferred);

            repairs_made += nsalv;
        }
        fsck_salvage_free();
        if (leak_deferred && repair_blocked) {
            fprintf(stderr, "NOTE: %" PRIu64 " leaked block(s) not cleared: the namespace pass found a fault "
                            "that makes them indistinguishable from a live file's\n",
                    leak_deferred);
        } else if (leak_deferred) {
            uint64_t ix = 0, cleared = 0;

            for (uint32_t b = 0; b < cetrafs_le32(sb.block_group_count); ++b) {
                uint64_t bmap_blocks = (bg_data_cnt[b] + CETRAFS_BLOCK_SIZE * 8 - 1) / (CETRAFS_BLOCK_SIZE * 8);
                uint8_t *bmap = (uint8_t *) xcalloc(bmap_blocks ? bmap_blocks : 1, CETRAFS_BLOCK_SIZE);
                int dirty = 0;
                uint64_t bg_before = cleared;

                pread_all(fd, bmap, (size_t) bmap_blocks * CETRAFS_BLOCK_SIZE,
                          (off_t) bg_bmap_lba[b] * CETRAFS_BLOCK_SIZE);
                for (uint64_t i = 0; i < bg_data_cnt[b]; ++i, ++ix) {
                    if (!((leakd[ix / 8] >> (ix % 8)) & 1u) || !(bmap[i / 8] & (1u << (i % 8))))
                        continue;
                    bmap[i / 8] &= (uint8_t) ~(1u << (i % 8));
                    dirty = 1;
                    cleared++;
                }
                if (dirty) {
                    uint64_t n = cleared - bg_before;
                    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
                    cetrafs_block_group_t bgd;
                    cetrafs_zone_group_t zg;
                    uint32_t z = bg_owner_expected[b];
                    int pool = z == CETRAFS_BG_OWNER_FREE;

                    /* The bits first, then the counters that credit
                     * them: stopped in between, the counts are low,
                     * which is the direction a reconcile only raises. */
                    pwrite_all(fd, bmap, (size_t) bmap_blocks * CETRAFS_BLOCK_SIZE,
                               (off_t) bg_bmap_lba[b] * CETRAFS_BLOCK_SIZE);

                    pread_all(fd, blk, sizeof(blk), (off_t) bg_desc_lba[b] * CETRAFS_BLOCK_SIZE);
                    memcpy(&bgd, blk, sizeof(bgd));
                    bgd.free_data_blocks = cetrafs_cpu_to_le64(cetrafs_le64(bgd.free_data_blocks) + n);
                    bgd.checksum = 0;
                    bgd.checksum = cetrafs_cpu_to_le64(crc32c_struct(
                        &bgd, sizeof(bgd), offsetof(cetrafs_block_group_t, checksum), sizeof(bgd.checksum)));
                    memcpy(blk, &bgd, sizeof(bgd));
                    pwrite_all(fd, blk, sizeof(blk), (off_t) bg_desc_lba[b] * CETRAFS_BLOCK_SIZE);

                    if (pool)
                        z = b % cetrafs_le32(sb.zone_group_count);
                    memset(blk, 0, sizeof(blk));
                    pread_all(fd, blk, sizeof(blk), (off_t) (cetrafs_le64(sb.zg_table_start) + z) * CETRAFS_BLOCK_SIZE);
                    memcpy(&zg, blk, sizeof(zg));
                    if (pool)
                        zg.pool_free_blocks = cetrafs_cpu_to_le64(cetrafs_le64(zg.pool_free_blocks) + n);
                    else
                        zg.free_data_blocks = cetrafs_cpu_to_le64(cetrafs_le64(zg.free_data_blocks) + n);
                    zg.hot_checksum = 0;
                    zg.hot_checksum = cetrafs_cpu_to_le64((uint64_t) crc32c_struct(
                        (const uint8_t *) &zg + CETRAFS_ZG_HOT_OFF, CETRAFS_ZG_HOT_LEN,
                        offsetof(cetrafs_zone_group_t, hot_checksum) - CETRAFS_ZG_HOT_OFF, sizeof(zg.hot_checksum)));
                    memcpy(blk, &zg, sizeof(zg));
                    pwrite_all(fd, blk, sizeof(blk), (off_t) (cetrafs_le64(sb.zg_table_start) + z) * CETRAFS_BLOCK_SIZE);
                }
                free(bmap);
            }
            repairs_made += cleared;
            printf("  cleared %" PRIu64 " leaked block(s)\n", cleared);
        }
        free(leakd);
        if (ibmap_dirty)
            pwrite_all(fd, ibmap, (size_t) cetrafs_le64(sb.inode_bmap_blocks) * CETRAFS_BLOCK_SIZE,
                       (off_t) cetrafs_le64(sb.inode_bmap_start) * CETRAFS_BLOCK_SIZE);
        if (orphans_linked)
            printf("  linked %" PRIu64 " orphaned inode(s) into /lost+found\n", orphans_linked);
        if (orphans_freed || orphans_linked)
            printf("  run fsck -r again to settle the free-space counters%s\n",
                   orphans_freed ? " and free the reclaimed blocks" : "");
        free(ibmap);
        free(refs);
        free(nlinks);
        free(is_dir);
        free(empty);
        free(dot_tgt);
        free(dotdot_tgt);
        free(parent);
        free(walked);
        free(subdirs);
        free(dir_gain);
        free(dir_parent);
        free(dsize);
        free(dslots);
        free(dwhole);

        problems += early_problems;
        if (problems) {
            fprintf(stderr, "cetrafs fsck: %" PRIu64 " problem(s) found\n", problems);
            if (repair_mode && repairs_made)
                fprintf(stderr,
                        "cetrafs fsck: %" PRIu64
                        " repaired -- re-run to confirm; anything still reported "
                        "needs a decision this tool will not make for you\n",
                        repairs_made);
            else if (repair_mode && repair_blocked)
                fprintf(stderr, "cetrafs fsck: nothing repaired (see the NOTE above)\n");
            return 1;
        }
    }

    printf("cetrafs fsck: OK\n");
    return 0;
}
