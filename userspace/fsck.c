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
static void pread_all(int fd, void *buf, size_t len, off_t off)
{
    uint8_t *p = buf;
    while (len) {
        ssize_t r = pread(fd, p, len, off);
        if (r <= 0)
            diex("pread");
        p += r;
        off += r;
        len -= r;
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
static int repair_blocked; /* a fault we must not repair around */
static uint64_t repairs_made;
/* Faults found before the content pass declares its own counter (the
 * root-directory checks). Folded into the final total so an early fault
 * is never silently dropped from the count just because it was found
 * early -- and so a repaired one still makes the run report itself. */
static uint64_t early_problems;

static void repair_block(const char *why)
{
    if (!repair_blocked && repair_mode)
        fprintf(stderr, "NOTE: repair is disabled for this run: %s\n", why);
    repair_blocked = 1;
}

/* Write len bytes at off, or die: a partial repair write is worse than
 * none, and there is nothing sensible to do but stop. */
static void pwrite_all(int fd, const void *buf, size_t len, off_t off)
{
    if (pwrite(fd, buf, len, off) != (ssize_t) len) {
        perror("pwrite (repair)");
        exit(FSCK_EXIT_NOEXAM);
    }
}

/* Rewrite one inode record's nlink, restamping the record checksum the
 * way inode.c's cetrafs_inode_crc() does (plain-native, over the record
 * with the checksum field zeroed). Records are one per block since
 * v0x0007, so this is a whole-block read-modify-write of a block that
 * holds nothing else. */
static void repair_set_nlink(int fd, const cetrafs_superblock_t *sb, uint64_t ino, uint32_t nlink)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};
    off_t off = (off_t) (cetrafs_le64(sb->inode_table_start) + (ino - 1)) * CETRAFS_BLOCK_SIZE;
    cetrafs_inode_t in;

    pread_all(fd, blk, sizeof(blk), off);
    memcpy(&in, blk, sizeof(in));
    in.nlink = cetrafs_cpu_to_le32(nlink);
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
static void fsck_read_inode(int fd, const cetrafs_superblock_t *sb, uint64_t ino, cetrafs_inode_t *out)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE] = {0};

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

/* Claim a free inode number from the in-memory bitmap the namespace
 * pass already holds; the caller writes it back once. */
static int fsck_alloc_inode(const cetrafs_superblock_t *sb, uint8_t *ibmap, int *dirty, uint64_t *out_ino)
{
    for (uint64_t ino = 2; ino <= cetrafs_le32(sb->inodes_count); ++ino) {
        uint64_t bit = ino - 1;

        if (ibmap[bit / 8] & (1u << (bit % 8)))
            continue;
        ibmap[bit / 8] |= (uint8_t) (1u << (bit % 8));
        *dirty = 1;
        *out_ino = ino;
        return 0;
    }
    return -1;
}

/* Claim a free data block from the first Block Group that has one. */
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
            *out_lba = bg_data_start[b] + i;
            free(bmap);
            return 0;
        }
        free(bmap);
    }
    return -1;
}

/* The physical block holding logical block 'n' of a depth-0 directory.
 * lost+found and the directories it holds are all built or walked here
 * at depth 0: a directory that spilled into an external leaf is left to
 * the kernel, and this only ever ADDS entries to a directory it created
 * itself. */
static int fsck_dir_block(const cetrafs_inode_t *in, uint32_t n, uint64_t *out_lba)
{
    uint32_t seen = 0;

    if (in->eh.eh_depth != 0)
        return -1;
    for (uint32_t e = 0; e < cetrafs_le16(in->eh.eh_entries) && e < 4; ++e) {
        uint32_t len = cetrafs_le32(in->et.leaf[e].ee_len) & CETRAFS_EXT_LEN_MASK;
        uint64_t phys = ((uint64_t) cetrafs_le16(in->et.leaf[e].ee_start_hi) << 32) | cetrafs_le32(in->et.leaf[e].ee_start_lo);

        if (n < seen + len) {
            *out_lba = phys + (n - seen);
            return 0;
        }
        seen += len;
    }
    return -1;
}

/* State for one repair run's lost+found: resolved or created lazily, on
 * the first orphan that actually needs it, so a healthy volume never
 * grows one. */
struct fsck_lf {
    uint64_t ino;      /* 0 until resolved/created */
    uint64_t root_ino; /* where it lives */
    int tried;         /* resolution already attempted and failed */
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
    if (dir.eh.eh_depth != 0)
        return -1;
    for (uint32_t e = 0; e < cetrafs_le16(dir.eh.eh_entries) && e < 4; ++e)
        nblocks += cetrafs_le32(dir.et.leaf[e].ee_len) & CETRAFS_EXT_LEN_MASK;

    for (uint32_t n = 0; n < nblocks; ++n) {
        cetrafs_dirent_t *de;

        if (fsck_dir_block(&dir, n, &lba))
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

            if (lphys + llen == nlba) {
                last->ee_len = cetrafs_cpu_to_le32((uint16_t) (llen + 1));
                goto grown;
            }
        }
        if (e >= 4)
            return -1;
        dir.et.leaf[e].ee_block = cetrafs_cpu_to_le32(nblocks);
        dir.et.leaf[e].ee_len = cetrafs_cpu_to_le32(1);
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
    if (fsck_dir_block(&in, 0, &lba))
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
    if (root.eh.eh_depth == 0) {
        for (uint32_t e = 0; e < cetrafs_le16(root.eh.eh_entries) && e < 4; ++e)
            nblocks += cetrafs_le32(root.et.leaf[e].ee_len) & CETRAFS_EXT_LEN_MASK;
        for (uint32_t n = 0; n < nblocks; ++n) {
            const cetrafs_dirent_t *de;

            if (fsck_dir_block(&root, n, &lba))
                break;
            pread_all(fd, blk, sizeof(blk), (off_t) lba * CETRAFS_BLOCK_SIZE);
            de = (const cetrafs_dirent_t *) blk;
            for (unsigned k = 0; k < CETRAFS_DIRENTS_PER_BLOCK; ++k) {
                if (cetrafs_le64(de[k].inode) && cetrafs_le16(de[k].name_len) == 10 && !memcmp(de[k].name, "lost+found", 10)) {
                    cetrafs_inode_t cand;

                    fsck_read_inode(fd, sb, cetrafs_le64(de[k].inode), &cand);
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

    if (fsck_alloc_inode(sb, ibmap, ibmap_dirty, &ino)) {
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
         * (ibmap_dirty stays latched: rewriting an unchanged bitmap is
         * harmless, and other passes may have dirtied it for real.) */
        ibmap[(ino - 1) / 8] &= (uint8_t) ~(1u << ((ino - 1) % 8));
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
    nd.et.leaf[0].ee_len = cetrafs_cpu_to_le32(1);
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
    return ino;
}

#ifndef FSCK_SET
#define FSCK_SET(bm, i) ((bm)[(i) / 8] |= (uint8_t) (1u << ((i) % 8)))
#define FSCK_GET(bm, i) (((bm)[(i) / 8] >> ((i) % 8)) & 1u)
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
};

/* Mark one physical run [phys, phys+len) as referenced by 'ino', flagging
 * an out-of-region block or a cross-file overlap. The one place the
 * content pass turns an extent (or a meta block) into bitmap bits, shared
 * by depth 0/1/2 so the depth-2 walk reuses exactly the depth-0 checks. */
/* A block number read from a (possibly hostile) on-disk record, about to
 * become a byte offset as (off_t) lba * CETRAFS_BLOCK_SIZE. A value past
 * total_blocks is corruption, and that multiply is signed-overflow UB for a
 * huge lba besides (a fuzz finding). 0 is never a valid data/meta block
 * here (the superblock lives there). */
static int fsck_lba_in_range(uint64_t lba, uint64_t total_blocks)
{
    return lba != 0 && lba < total_blocks;
}

static void fsck_mark_run(struct fsck_refctx *c, uint64_t phys, uint64_t len, uint64_t ino)
{
    uint64_t base = 0, idx0;
    int b, found = -1;
    int overlap_reported = 0;

    if (len == 0)
        return;

    /* Validate the whole run against the data regions ONCE, up front. A
     * hostile extent can carry len up to 2^31 and a wild phys; the old
     * per-block loop then iterated billions of times and printed one
     * "outside every data region" line PER block -- GiB of output and a
     * near-hang on a single crafted extent (a fuzz finding). An extent
     * never crosses a BG, so a legal run fits entirely inside one BG's
     * data range; anything else is one problem, reported once. */
    for (b = 0; b < (int) c->nbg; ++b) {
        if (phys >= c->bg_start[b] && phys < c->bg_start[b] + c->bg_cnt[b]) {
            found = b;
            break;
        }
        base += c->bg_cnt[b];
    }
    if (found < 0 || len > c->bg_cnt[found] || phys + len > c->bg_start[found] + c->bg_cnt[found]) {
        fprintf(stderr,
                "ERR: inode %" PRIu64 " extent [%" PRIu64 ",+%" PRIu64 ") is outside every data region\n",
                ino, phys, len);
        (*c->problems)++;
        repair_block("an extent points outside every data region, so the extent tree "
                     "cannot be trusted to say what is referenced");
        return;
    }

    idx0 = base + (phys - c->bg_start[found]);
    for (uint64_t k = 0; k < len; ++k) {
        uint64_t idx = idx0 + k;

        if (FSCK_GET(c->refd, idx)) {
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
            (*c->blocks_referenced)++;
        }
    }
}

/* Verify a leaf/interior block's v0x000F tail. Offline there is no
 * torn-write excuse, so a bad tail is real corruption. Returns 0 if OK. */
static int fsck_check_tail(const uint8_t *blk, uint32_t magic)
{
    const cetrafs_blk_tail_t *t = (const cetrafs_blk_tail_t *) (blk + CETRAFS_BLK_TAIL_OFF);

    return (cetrafs_le32(t->magic) == magic && cetrafs_le32(t->crc) == crc32c_update(0, blk, CETRAFS_BLK_TAIL_OFF)) ? 0 : -1;
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
            for (uint32_t i = 0; i < cetrafs_le32(seg.count); i++, filled++)
                if (filled < nbg)
                    bg_desc_lba[filled] = seg_lba + 1 + i;
            if (filled > nbg) {
                fprintf(stderr, "ERR: Block Group table chain describes %u Block Groups, more than the %u recorded\n",
                        filled, nbg);
                return 1;
            }
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
            if (bg_end > data_end || cetrafs_le64(bg.start_block) < cetrafs_le64(sb.bg_regions_start)) {
                fprintf(stderr,
                        "ERR: BG%zu [%" PRIu64 ",+%" PRIu64 ") falls outside the data area [%" PRIu64 ",%" PRIu64 ")\n",
                        (size_t) b, (uint64_t) cetrafs_le64(bg.start_block), (uint64_t) cetrafs_le64(bg.length_blocks),
                        (uint64_t) cetrafs_le64(sb.bg_regions_start), data_end);
                return 1;
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
    for (uint32_t n = 0; n < cetrafs_le32(sb.node_table_count); ++n) {
        cetrafs_node_entry_t ne;
        /* one row per block as of v0x0007 */
        pread_all(fd, &ne, sizeof(ne), (off_t) (cetrafs_le64(sb.node_table_start) + n) * CETRAFS_BLOCK_SIZE);
        if (ne.state == CETRAFS_NODE_STATE_FREE)
            continue;
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
        uint64_t cl_problems = 0;

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
                    if ((uint32_t) cetrafs_le32(hdr.header_checksum) != hc) {
                        fprintf(stderr, "ERR: node %u journal slot %" PRIu64 " header CRC mismatch\n", n, sl);
                        cl_problems++;
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
                                "ERR: node %u journal slot %" PRIu64
                                " payload CRC mismatch -- it would be applied "
                                "over block %" PRIu64 "\n",
                                n, sl, (uint64_t) cetrafs_le64(hdr.target_lba));
                        cl_problems++;
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
            if (repair_mode && !repair_blocked) {
                repair_reinit_dirent_block(fd, root_lba, CETRAFS_ROOT_INO, CETRAFS_ROOT_INO, true);
                repairs_made++;
                printf("  rebuilt the root directory's dirent block (with '.' and '..')\n");
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
/* FSCK_SET/FSCK_GET are defined globally above (guarded). */
        uint8_t *ibmap = (uint8_t *) xcalloc(cetrafs_le64(sb.inode_bmap_blocks), CETRAFS_BLOCK_SIZE);
        int ibmap_dirty = 0;
        uint64_t orphans_freed = 0;
        uint64_t orphans_linked = 0;
        struct fsck_lf lf = {0, cetrafs_le64(sb.root_ino), 0};
        uint64_t problems = 0, inodes_seen = 0, extents_seen = 0, blocks_referenced = 0;

        pread_all(fd, ibmap, (size_t) cetrafs_le64(sb.inode_bmap_blocks) * CETRAFS_BLOCK_SIZE,
                  (off_t) cetrafs_le64(sb.inode_bmap_start) * CETRAFS_BLOCK_SIZE);

        /* Map a data-block LBA to its index in 'owner', or -1 if the LBA
         * is not inside any BG's data region (which is itself a fault:
         * an extent must never point at metadata). */
        /* (inline below; kept as a lambda-ish loop for clarity) */

        for (uint64_t ino = 1; ino <= cetrafs_le32(sb.inodes_count); ++ino) {
            uint64_t bit = ino - 1;
            if (!(ibmap[bit / 8] & (1u << (bit % 8))))
                continue; /* free inode */

            uint8_t iblk[CETRAFS_BLOCK_SIZE];
            cetrafs_inode_t in;
            pread_all(fd, iblk, sizeof(iblk), (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE);
            memcpy(&in, iblk, sizeof(in));

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
            inodes_seen++;

            /* An allocated nlink=0 inode is the designed residue of a
             * cross-node delete whose destroyer could not free it (a
             * peer held it open) -- bounded, reclaimable (-r, or the
             * online scrub), and reported, but NOT a corruption this
             * tool should fail the volume on. See the unreachable-inode
             * pass for the full account. */
            if (in.nlink == 0)
                fprintf(stderr, "WARN: inode %" PRIu64 " is allocated but has nlink=0 (orphan)\n", ino);

            if (cetrafs_le16(in.eh.eh_magic) != CETRAFS_EXT_MAGIC) {
                /* magic == 0 is a legitimate "no extents yet" record and
                 * is NOT an error -- blocking repair on it would disable
                 * repair on every healthy volume, which is the
                 * cries-wolf failure N5 is about. Only a header that is
                 * positively wrong hides blocks from the walk. */
                if (in.eh.eh_magic != 0) {
                    fprintf(stderr, "ERR: inode %" PRIu64 " has a bad extent header magic 0x%X\n", ino, in.eh.eh_magic);
                    problems++;
                    repair_block(
                        "an inode's extent header is not valid, so the blocks it owns cannot be "
                        "distinguished from leaked ones");
                }
                continue;
            }
            if (cetrafs_le16(in.eh.eh_depth) > CETRAFS_EXT_MAX_DEPTH) {
                fprintf(stderr, "ERR: inode %" PRIu64 " has extent depth %u (only 0, 1 and 2 exist)\n", ino,
                        in.eh.eh_depth);
                problems++;
                continue;
            }

            /* Turn this inode's extent tree into reachability bits. The
             * tree block itself (leaf, and at depth 2 the interiors) is a
             * data block too and must be accounted for, or it reads as a
             * leak. fsck_mark_run() is the shared depth-0 marking; the
             * depth-2 walk reuses it per leaf. */
            struct fsck_refctx rc = {refd,      dupd, bg_data_start, bg_data_cnt,
                                     cetrafs_le32(sb.block_group_count), &problems, &blocks_referenced};
            uint64_t xattr_lba = cetrafs_le64(in.xattr_block);
            uint8_t leafblk[CETRAFS_BLOCK_SIZE];
            int tree_ok = 1;

            if (in.eh.eh_depth == 0) {
                uint32_t n = cetrafs_le16(in.eh.eh_entries) > 4 ? 4 : cetrafs_le16(in.eh.eh_entries);

                for (uint32_t e = 0; e < n; ++e) {
                    uint64_t phys = ((uint64_t) cetrafs_le16(in.et.leaf[e].ee_start_hi) << 32) | cetrafs_le32(in.et.leaf[e].ee_start_lo);

                    fsck_mark_run(&rc, phys, cetrafs_le32(in.et.leaf[e].ee_len) & CETRAFS_EXT_LEN_MASK, ino);
                    extents_seen++;
                }
            } else if (cetrafs_le16(in.eh.eh_depth) == 1) {
                uint64_t leaf_lba = ((uint64_t) cetrafs_le16(in.et.idx[0].ei_leaf_hi) << 32) | cetrafs_le32(in.et.idx[0].ei_leaf_lo);
                cetrafs_extent_hdr_t *lh;
                uint32_t n;

                if (!fsck_lba_in_range(leaf_lba, cetrafs_le64(sb.total_blocks))) {
                    fprintf(stderr, "ERR: inode %" PRIu64 "'s extent leaf (block %" PRIu64 ") is out of range\n",
                            ino, leaf_lba);
                    problems++;
                    repair_block("an extent leaf lba is out of range, so the blocks the inode "
                                 "owns cannot be distinguished from leaked ones");
                    tree_ok = 0;
                } else if (pread_all(fd, leafblk, sizeof(leafblk), (off_t) leaf_lba * CETRAFS_BLOCK_SIZE),
                           fsck_check_tail(leafblk, CETRAFS_LEAF_TAIL_MAGIC) != 0) {
                    fprintf(stderr, "ERR: inode %" PRIu64 "'s extent leaf (block %" PRIu64 ") failed its tail checksum\n",
                            ino, leaf_lba);
                    problems++;
                    repair_block("an extent leaf failed its tail checksum, so the blocks the inode "
                                 "owns cannot be distinguished from leaked ones");
                    tree_ok = 0;
                } else {
                    lh = (cetrafs_extent_hdr_t *) leafblk;
                    n = cetrafs_le16(lh->eh_entries) > CETRAFS_EXT_BLOCK_MAX_LEAVES ? CETRAFS_EXT_BLOCK_MAX_LEAVES : cetrafs_le16(lh->eh_entries);
                    for (uint32_t e = 0; e < n; ++e) {
                        const cetrafs_extent_t *x = (const cetrafs_extent_t *) (leafblk + sizeof(*lh)) + e;
                        uint64_t phys = ((uint64_t) cetrafs_le16(x->ee_start_hi) << 32) | cetrafs_le32(x->ee_start_lo);

                        fsck_mark_run(&rc, phys, cetrafs_le32(x->ee_len) & CETRAFS_EXT_LEN_MASK, ino);
                        extents_seen++;
                    }
                    fsck_mark_run(&rc, leaf_lba, 1, ino); /* the leaf block itself */
                }
            } else {
                /* depth 2: interiors -> leaves -> extents */
                uint8_t idxblk[CETRAFS_BLOCK_SIZE];
                uint32_t ni = cetrafs_le16(in.eh.eh_entries) > 4 ? 4 : cetrafs_le16(in.eh.eh_entries);

                for (uint32_t i = 0; i < ni && tree_ok; ++i) {
                    uint64_t ilba = ((uint64_t) cetrafs_le16(in.et.idx[i].ei_leaf_hi) << 32) | cetrafs_le32(in.et.idx[i].ei_leaf_lo);
                    cetrafs_extent_hdr_t *ih;
                    uint32_t iln;

                    if (!fsck_lba_in_range(ilba, cetrafs_le64(sb.total_blocks))) {
                        fprintf(stderr,
                                "ERR: inode %" PRIu64 "'s extent index (block %" PRIu64 ") is out of range\n",
                                ino, ilba);
                        problems++;
                        repair_block("an extent index lba is out of range, so the blocks the inode "
                                     "owns cannot be distinguished from leaked ones");
                        tree_ok = 0;
                        break;
                    }
                    pread_all(fd, idxblk, sizeof(idxblk), (off_t) ilba * CETRAFS_BLOCK_SIZE);
                    if (fsck_check_tail(idxblk, CETRAFS_INDEX_TAIL_MAGIC) != 0) {
                        fprintf(stderr,
                                "ERR: inode %" PRIu64 "'s extent index (block %" PRIu64 ") failed its tail checksum\n",
                                ino, ilba);
                        problems++;
                        repair_block("an extent index failed its tail checksum, so the blocks the inode "
                                     "owns cannot be distinguished from leaked ones");
                        tree_ok = 0;
                        break;
                    }
                    fsck_mark_run(&rc, ilba, 1, ino); /* the interior block itself */
                    ih = (cetrafs_extent_hdr_t *) idxblk;
                    iln = cetrafs_le16(ih->eh_entries) > CETRAFS_EXT_BLOCK_MAX_IDX ? CETRAFS_EXT_BLOCK_MAX_IDX : cetrafs_le16(ih->eh_entries);

                    for (uint32_t li = 0; li < iln && tree_ok; ++li) {
                        const cetrafs_extent_idx_t *ie = (const cetrafs_extent_idx_t *) (idxblk + sizeof(*ih)) + li;
                        uint64_t llba = ((uint64_t) cetrafs_le16(ie->ei_leaf_hi) << 32) | cetrafs_le32(ie->ei_leaf_lo);
                        cetrafs_extent_hdr_t *lh;
                        uint32_t n;

                        if (!fsck_lba_in_range(llba, cetrafs_le64(sb.total_blocks))) {
                            fprintf(stderr,
                                    "ERR: inode %" PRIu64 "'s extent leaf (block %" PRIu64 ") is out of range\n",
                                    ino, llba);
                            problems++;
                            repair_block("an extent leaf lba is out of range, so the blocks the inode "
                                         "owns cannot be distinguished from leaked ones");
                            tree_ok = 0;
                            break;
                        }
                        pread_all(fd, leafblk, sizeof(leafblk), (off_t) llba * CETRAFS_BLOCK_SIZE);
                        if (fsck_check_tail(leafblk, CETRAFS_LEAF_TAIL_MAGIC) != 0) {
                            fprintf(stderr,
                                    "ERR: inode %" PRIu64 "'s extent leaf (block %" PRIu64
                                    ") failed its tail checksum\n",
                                    ino, llba);
                            problems++;
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
                            extents_seen++;
                        }
                    }
                }
            }

            if (!tree_ok)
                continue; /* a bad tail already reported; its blocks look leaked, repair refused */

            /* The xattr block is a referenced data block too (all depths).
             * Verify its tail; counted referenced even with a bad tail --
             * the block is still this inode's, and freeing it would be the
             * same cross-link corruption again. */
            if (xattr_lba && !fsck_lba_in_range(xattr_lba, cetrafs_le64(sb.total_blocks))) {
                fprintf(stderr, "ERR: inode %" PRIu64 "'s xattr block (block %" PRIu64 ") is out of range\n",
                        ino, xattr_lba);
                problems++;
            } else if (xattr_lba) {
                uint8_t xblk[CETRAFS_BLOCK_SIZE];

                pread_all(fd, xblk, sizeof(xblk), (off_t) xattr_lba * CETRAFS_BLOCK_SIZE);
                if (fsck_check_tail(xblk, CETRAFS_XATTR_TAIL_MAGIC) != 0) {
                    fprintf(stderr, "ERR: inode %" PRIu64 "'s xattr block (block %" PRIu64 ") failed its tail checksum\n",
                            ino, xattr_lba);
                    problems++;
                }
                fsck_mark_run(&rc, xattr_lba, 1, ino);
            }
        }

        /* Blocks sitting in a per-ZG pending-free queue are marked used
         * and referenced by nothing -- legitimately so, until their
         * owner drains the queue. Count them as referenced here, or
         * every volume with a queued cross-node free would report
         * phantom leaks, and a warning that cries wolf is one nobody
         * reads. */
        uint64_t pending = 0;
        if (sb.pending_free_start && sb.pending_free_blocks_per_zg) {
            for (uint32_t z = 0; z < cetrafs_le32(sb.zone_group_count); ++z) {
                for (uint32_t qb = 0; qb < cetrafs_le32(sb.pending_free_blocks_per_zg); ++qb) {
                    uint8_t q[CETRAFS_BLOCK_SIZE];
                    uint64_t qlba = cetrafs_le64(sb.pending_free_start) + (uint64_t) z * cetrafs_le32(sb.pending_free_blocks_per_zg) + qb;

                    pread_all(fd, q, sizeof(q), (off_t) qlba * CETRAFS_BLOCK_SIZE);
                    for (uint32_t e = 0; e < CETRAFS_PENDING_FREE_PER_BLOCK; ++e) {
                        cetrafs_pending_free_t pe;

                        memcpy(&pe, q + e * sizeof(pe), sizeof(pe));
                        if (!cetrafs_le64(pe.lba) || cetrafs_le32(pe.magic) != CETRAFS_PENDING_FREE_MAGIC || !cetrafs_le32(pe.count))
                            continue;
                        for (uint32_t k = 0; k < cetrafs_le32(pe.count); ++k) {
                            uint64_t lba = cetrafs_le64(pe.lba) + k, ix = 0;

                            for (uint32_t b = 0; b < cetrafs_le32(sb.block_group_count); ++b) {
                                if (lba >= bg_data_start[b] && lba < bg_data_start[b] + bg_data_cnt[b]) {
                                    ix += lba - bg_data_start[b];
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
                }
            }
        }

        /* Reconcile what is referenced against what the bitmaps claim.
         * A block marked used but referenced by nothing is a leak; one
         * referenced but marked free will be handed out again. */
        uint64_t leaked = 0, unmarked = 0, idx = 0, miscounted = 0;
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
                    /* Nothing references it, so clearing the bit cannot
                     * lose anything -- the 128 MiB evict_inode class,
                     * which until now could only be recovered by
                     * reformatting. */
                    if (repair_mode && !repair_blocked) {
                        bmap[i / 8] &= (uint8_t) ~(1u << (i % 8));
                        bmap_dirty = 1;
                        marked = 0;
                        repairs_made++;
                    }
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
        /* Which directory names each DIRECTORY, for the reachability
         * walk below. One slot is enough because this format cannot
         * represent a directory with two parents: '..' is a single
         * dirent, which is why cetrafs_link() refuses to hardlink a
         * directory at all. Directories therefore form a tree, and
         * reachability is just "does the parent chain reach the root",
         * with no extra I/O and no edge list to store. */
        uint32_t *dir_parent = (uint32_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, sizeof(uint32_t));
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
        }

        /* Pass B: walk every directory's entries. */
        for (uint64_t ino = 1; ino <= cetrafs_le32(sb.inodes_count); ++ino) {
            uint64_t bit = ino - 1;
            uint8_t iblk[CETRAFS_BLOCK_SIZE];
            cetrafs_inode_t in;

            if (!(ibmap[bit / 8] & (1u << (bit % 8))))
                continue;
            pread_all(fd, iblk, sizeof(iblk), (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * CETRAFS_BLOCK_SIZE);
            memcpy(&in, iblk, sizeof(in));
            if (!cetrafs_inode_crcs_ok(&in))
                continue; /* already reported above */

            if (!is_dir[ino] || cetrafs_le16(in.eh.eh_magic) != CETRAFS_EXT_MAGIC || cetrafs_le16(in.eh.eh_depth) > 1)
                continue;
            /* Its blocks are about to be walked, so '.'/'..' recorded
             * below are meaningful for it. A directory skipped above was
             * never looked at and must not be reported as missing them. */
            walked[ino] = 1;

            cetrafs_extent_t ext[4 + CETRAFS_EXT_BLOCK_MAX_LEAVES];
            uint32_t n;
            uint8_t leafblk[CETRAFS_BLOCK_SIZE];

            if (in.eh.eh_depth == 0) {
                n = cetrafs_le16(in.eh.eh_entries) > 4 ? 4 : cetrafs_le16(in.eh.eh_entries);
                memcpy(ext, in.et.leaf, n * sizeof(ext[0]));
            } else {
                uint64_t lf = ((uint64_t) cetrafs_le16(in.et.idx[0].ei_leaf_hi) << 32) | cetrafs_le32(in.et.idx[0].ei_leaf_lo);
                pread_all(fd, leafblk, sizeof(leafblk), (off_t) lf * CETRAFS_BLOCK_SIZE);
                cetrafs_extent_hdr_t *lh = (cetrafs_extent_hdr_t *) leafblk;
                n = cetrafs_le16(lh->eh_entries) > CETRAFS_EXT_BLOCK_MAX_LEAVES ? CETRAFS_EXT_BLOCK_MAX_LEAVES : cetrafs_le16(lh->eh_entries);
                memcpy(ext, leafblk + sizeof(*lh), n * sizeof(ext[0]));
            }

            uint64_t logical = 0;

            for (uint32_t e = 0; e < n; ++e) {
                uint64_t phys = ((uint64_t) cetrafs_le16(ext[e].ee_start_hi) << 32) | cetrafs_le32(ext[e].ee_start_lo);
                uint64_t len = cetrafs_le32(ext[e].ee_len) & CETRAFS_EXT_LEN_MASK;

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
                        note_bad_dirent_block(ino, phys + k, logical == 0);
                        continue;
                    }

                    de = (cetrafs_dirent_t *) db;
                    for (unsigned s = 0; s < CETRAFS_DIRENTS_PER_BLOCK; ++s) {
                        if (de[s].inode == 0)
                            continue;
                        dirents_seen++;
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
                            /* First namer wins: a second one is already
                             * reported by the nlink check, and picking
                             * either gives the same verdict below. */
                            if (dir_parent[t] == 0)
                                dir_parent[t] = (uint32_t) ino;
                        }
                    }
                }
            }
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
                 * Severity depends on nlink. nlink=0 and unnamed is the
                 * DESIGNED residue of cross-node deletion: eviction
                 * refuses to free an inode a peer still has open (the
                 * read-presence bit), and a reader-only peer's own evict
                 * cannot know the file died under it -- so the number
                 * and its blocks stay allocated, bounded and reclaimable
                 * (fsck -r here; the online scrub on a live volume).
                 * That is a leak to report, not a corruption to fail on.
                 * nlink>0 and unnamed is a different animal entirely --
                 * a LOST NAME, data still wanted with no way to reach it
                 * -- and stays a hard ERR.
                 */
                if (nlinks[ino] == 0) {
                    fprintf(stderr,
                            "WARN: inode %" PRIu64 " is allocated (nlink=0) with no directory entry -- "
                            "deleted but not yet reclaimed (peer held it open at delete)\n",
                            ino);
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
                if (nlinks[ino] == 0 && repair_mode && !repair_blocked) {
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

                    snprintf(nm, sizeof(nm), "#%" PRIu64, ino);
                    if (lfino &&
                        !fsck_dir_link(fd, &sb, cetrafs_le32(sb.block_group_count), bg_data_start, bg_data_cnt, bg_bmap_lba, lfino,
                                       nm, ino, is_dir[ino] ? CETRAFS_FT_DIR : CETRAFS_FT_REG)) {
                        /* A recovered DIRECTORY's '..' must name its new
                         * parent, or the tree it has been grafted into
                         * disagrees with itself and the next run says so.
                         * fsck_dir_link() has already bumped
                         * lost+found's nlink for it. */
                        if (is_dir[ino])
                            fsck_set_dotdot(fd, &sb, ino, lfino);
                        orphans_linked++;
                        repairs_made++;
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
                if (nlinks[ino] != subdirs[ino] + 2) {
                    if (repair_mode && !repair_blocked) {
                        repair_set_nlink(fd, &sb, ino, subdirs[ino] + 2);
                        repairs_made++;
                    }
                    fprintf(stderr,
                            "ERR: directory inode %" PRIu64
                            " has nlink=%u but contains %u subdirector%s "
                            "(expected %u)\n",
                            ino, nlinks[ino], subdirs[ino], subdirs[ino] == 1 ? "y" : "ies", subdirs[ino] + 2);
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
        if (walked[CETRAFS_ROOT_INO] && nlinks[CETRAFS_ROOT_INO] != subdirs[CETRAFS_ROOT_INO] + 2) {
            if (repair_mode && !repair_blocked) {
                repair_set_nlink(fd, &sb, CETRAFS_ROOT_INO, subdirs[CETRAFS_ROOT_INO] + 2);
                repairs_made++;
            }
            fprintf(stderr, "ERR: root directory has nlink=%u but contains %u subdirector%s (expected %u)\n",
                    nlinks[CETRAFS_ROOT_INO], subdirs[CETRAFS_ROOT_INO], subdirs[CETRAFS_ROOT_INO] == 1 ? "y" : "ies",
                    subdirs[CETRAFS_ROOT_INO] + 2);
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
            uint8_t *seen = (uint8_t *) xcalloc(cetrafs_le32(sb.inodes_count) + 1, 1);
            uint64_t detached = 0;

            for (uint64_t ino = 2; ino <= cetrafs_le32(sb.inodes_count); ++ino) {
                uint64_t bit = ino - 1;
                uint64_t cur;
                uint64_t steps = 0;
                int cycle = 0;

                if (!(ibmap[bit / 8] & (1u << (bit % 8))) || !is_dir[ino])
                    continue;

                /* Walk up, marking as we go. The step limit is a
                 * backstop: a cycle is normally caught by `seen`, but a
                 * corrupt parent map must not be able to hang the
                 * tool. */
                memset(seen, 0, cetrafs_le32(sb.inodes_count) + 1);
                cur = ino;
                while (cur != CETRAFS_ROOT_INO && steps++ <= cetrafs_le32(sb.inodes_count)) {
                    if (cur == 0 || cur > cetrafs_le32(sb.inodes_count))
                        break;
                    if (seen[cur]) {
                        cycle = 1;
                        break;
                    }
                    seen[cur] = 1;
                    cur = dir_parent[cur];
                }

                if (cur == CETRAFS_ROOT_INO)
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
            free(seen);
            if (detached == 0)
                printf("  namespace: every directory is reachable from the root\n");
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
        free(dot_tgt);
        free(dotdot_tgt);
        free(parent);
        free(walked);
        free(subdirs);
        free(dir_parent);

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
