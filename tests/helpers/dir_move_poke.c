// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * dir_move_poke -- test-only helper: move a DIRECTORY from one parent to
 * another directly on a cetrafs image, the way a PEER node's completed
 * rename leaves the device: the name leaves the old parent's dirent
 * block and appears in the new parent's, the child's '..' is rewritten,
 * both parents' link counts and sizes move, and every directory touched
 * gets a new dirent_seq -- all with valid checksums.
 *
 * A live mount on this host does not see it in its caches until its own
 * forced-fresh reads (the dirent_seq gate) look, which is exactly what a
 * peer's rename looks like to a node whose lookups ran a moment before.
 *
 * Small directories only: every directory involved must hold its entries
 * in one inline extent (depth 0), which any freshly made test tree does.
 *
 * usage: dir_move_poke <image> <from_dir_ino> <name> <to_dir_ino>
 */
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

static int fd;
static cetrafs_superblock_t sb;

static void rd(void *b, size_t n, off_t o)
{
    if (pread(fd, b, n, o) != (ssize_t) n) {
        perror("pread");
        exit(2);
    }
}

static void wr(const void *b, size_t n, off_t o)
{
    if (pwrite(fd, b, n, o) != (ssize_t) n) {
        perror("pwrite");
        exit(2);
    }
}

static off_t rec_off(uint64_t ino)
{
    return (off_t) (cetrafs_le64(sb.inode_table_start) + ino - 1) * cetrafs_le32(sb.block_size);
}

static void rec_read(uint64_t ino, cetrafs_inode_t *r)
{
    rd(r, sizeof(*r), rec_off(ino));
}

static void rec_write(uint64_t ino, cetrafs_inode_t *r)
{
    cetrafs_inode_stamp_crcs_us(r);
    wr(r, sizeof(*r), rec_off(ino));
}

/* The one dirent block of a small directory. */
static uint64_t dir_block(uint64_t ino)
{
    cetrafs_inode_t r;

    rec_read(ino, &r);
    if (cetrafs_le16(r.eh.eh_depth) != 0 || cetrafs_le16(r.eh.eh_entries) != 1 ||
        cetrafs_extent_len(r.et.leaf[0].ee_len) != 1) {
        fprintf(stderr, "ino %" PRIu64 ": not a one-block inline directory\n", ino);
        exit(2);
    }
    return cetrafs_extent_phys_from_hilo(r.et.leaf[0].ee_start_hi, r.et.leaf[0].ee_start_lo);
}

static void blk_stamp(uint8_t *blk)
{
    cetrafs_dirent_tail_t *tail = (cetrafs_dirent_tail_t *) (blk + CETRAFS_DIRENT_TAIL_OFF);

    tail->magic = cetrafs_cpu_to_le32(CETRAFS_DIRENT_TAIL_MAGIC);
    tail->crc = cetrafs_cpu_to_le32(crc32c_update(0, blk, CETRAFS_DIRENT_TAIL_OFF));
}

static void dir_touch(uint64_t ino, int nlink_delta, int64_t size_delta)
{
    cetrafs_inode_t r;

    rec_read(ino, &r);
    r.nlink = cetrafs_cpu_to_le32((uint32_t) ((int) cetrafs_le32(r.nlink) + nlink_delta));
    r.size = cetrafs_cpu_to_le64((uint64_t) ((int64_t) cetrafs_le64(r.size) + size_delta));
    r.dirent_seq = cetrafs_cpu_to_le64(cetrafs_le64(r.dirent_seq) + 1);
    rec_write(ino, &r);
}

int main(int argc, char **argv)
{
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    uint64_t from, to, child = 0, b;
    const char *name;
    size_t nlen;
    cetrafs_dirent_t *de = (cetrafs_dirent_t *) blk;
    unsigned int e;

    if (argc != 5) {
        fprintf(stderr, "usage: %s <image> <from_dir_ino> <name> <to_dir_ino>\n", argv[0]);
        return 2;
    }
    fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 2;
    }
    rd(&sb, sizeof(sb), 0);
    from = strtoull(argv[2], NULL, 0);
    name = argv[3];
    nlen = strlen(name);
    to = strtoull(argv[4], NULL, 0);

    /* 1. Take the name out of the old parent. */
    b = dir_block(from);
    rd(blk, sizeof(blk), (off_t) b * CETRAFS_BLOCK_SIZE);
    for (e = 0; e < CETRAFS_DIRENTS_PER_BLOCK; e++)
        if (cetrafs_le64(de[e].inode) && cetrafs_le16(de[e].name_len) == nlen && !memcmp(de[e].name, name, nlen)) {
            if (de[e].file_type != CETRAFS_FT_DIR) {
                fprintf(stderr, "'%s' is not a directory\n", name);
                return 2;
            }
            child = cetrafs_le64(de[e].inode);
            memset(&de[e], 0, sizeof(de[e]));
            break;
        }
    if (!child) {
        fprintf(stderr, "no '%s' in ino %" PRIu64 "\n", name, from);
        return 2;
    }
    blk_stamp(blk);
    wr(blk, sizeof(blk), (off_t) b * CETRAFS_BLOCK_SIZE);

    /* 2. Put it in the new parent. */
    b = dir_block(to);
    rd(blk, sizeof(blk), (off_t) b * CETRAFS_BLOCK_SIZE);
    for (e = 0; e < CETRAFS_DIRENTS_PER_BLOCK; e++)
        if (!cetrafs_le64(de[e].inode))
            break;
    if (e == CETRAFS_DIRENTS_PER_BLOCK) {
        fprintf(stderr, "ino %" PRIu64 ": no free slot\n", to);
        return 2;
    }
    memset(&de[e], 0, sizeof(de[e]));
    de[e].inode = cetrafs_cpu_to_le64(child);
    de[e].name_len = cetrafs_cpu_to_le16((uint16_t) nlen);
    de[e].file_type = CETRAFS_FT_DIR;
    memcpy(de[e].name, name, nlen);
    blk_stamp(blk);
    wr(blk, sizeof(blk), (off_t) b * CETRAFS_BLOCK_SIZE);

    /* 3. The child's '..'. */
    b = dir_block(child);
    rd(blk, sizeof(blk), (off_t) b * CETRAFS_BLOCK_SIZE);
    for (e = 0; e < CETRAFS_DIRENTS_PER_BLOCK; e++)
        if (cetrafs_le64(de[e].inode) && cetrafs_le16(de[e].name_len) == 2 && !memcmp(de[e].name, "..", 2))
            break;
    if (e == CETRAFS_DIRENTS_PER_BLOCK) {
        fprintf(stderr, "ino %" PRIu64 ": no '..'\n", child);
        return 2;
    }
    de[e].inode = cetrafs_cpu_to_le64(to);
    blk_stamp(blk);
    wr(blk, sizeof(blk), (off_t) b * CETRAFS_BLOCK_SIZE);

    /* 4. Counts and change stamps: the old parent loses the child's '..',
     * the new one gains it. */
    dir_touch(from, -1, -(int64_t) sizeof(cetrafs_dirent_t));
    dir_touch(to, +1, (int64_t) sizeof(cetrafs_dirent_t));
    dir_touch(child, 0, 0);
    fsync(fd);
    printf("%" PRIu64 "\n", child);
    return 0;
}
