// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * dirtree_poke -- test-only: plant a one-block directory on a raw,
 * UNMOUNTED cetrafs image, with a damaged dirent block that fsck's walk
 * must skip.
 *
 * usage: dirtree_poke <image> <dir-ino> <data-block> <victim-ino>
 *
 * Sets up inode <dir-ino> as a directory (mode 040755, nlink 2, size one
 * block, one inline extent of one block at <data-block>) and writes a
 * dirent block there with checksum-valid tail:
 *   slot 0  '.'  -> dir-ino
 *   slot 1  '..' -> root (1)
 *   slot 2  'v'  -> victim-ino   (the name the walk cannot read)
 *   slot 3  inode 0, name_len 4000 -- an impossible name length, so the
 *           whole block fails cetrafs_blk_struct_ok() and the walk skips it.
 * The victim is then an allocated inode whose only name sits in a block
 * fsck does not read. Its record is left as the caller planted it.
 *
 * The block is written to the backing file, like every poker here: the
 * caller flushes the loop device before the next read.
 */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

static void rd(int fd, void *b, size_t n, off_t o)
{
    if (pread(fd, b, n, o) != (ssize_t) n) {
        perror("pread");
        exit(2);
    }
}

static void wr(int fd, const void *b, size_t n, off_t o)
{
    if (pwrite(fd, b, n, o) != (ssize_t) n) {
        perror("pwrite");
        exit(2);
    }
}

int main(int argc, char **argv)
{
    cetrafs_superblock_t sb;
    cetrafs_inode_t in;
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    cetrafs_dirent_t *de = (cetrafs_dirent_t *) blk;
    cetrafs_dirent_tail_t tail;
    uint64_t dir, data, victim, bit;
    off_t boff;
    unsigned char byte;
    int fd;

    if (argc != 5) {
        fprintf(stderr, "usage: %s <image> <dir-ino> <data-block> <victim-ino>\n", argv[0]);
        return 2;
    }
    fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 2;
    }
    rd(fd, &sb, sizeof(sb), 0);
    dir = strtoull(argv[2], NULL, 0);
    data = strtoull(argv[3], NULL, 0);
    victim = strtoull(argv[4], NULL, 0);
    if (dir < 2 || dir > cetrafs_le32(sb.inodes_count) || victim < 2 || victim > cetrafs_le32(sb.inodes_count) ||
        dir == victim) {
        fprintf(stderr, "inode numbers out of range\n");
        return 2;
    }

    /* The directory's inode bit must be free: planting over a live
     * inode would make this a different test. */
    bit = dir - 1;
    boff = (off_t) cetrafs_le64(sb.inode_bmap_start) * CETRAFS_BLOCK_SIZE + (off_t) (bit / 8);
    rd(fd, &byte, 1, boff);
    if (byte & (1u << (bit % 8))) {
        fprintf(stderr, "dir-ino %" PRIu64 " is already allocated -- pick a free one\n", dir);
        return 2;
    }
    byte |= (unsigned char) (1u << (bit % 8));
    wr(fd, &byte, 1, boff);

    memset(&in, 0, sizeof(in));
    in.ino = cetrafs_cpu_to_le64(dir);
    in.mode = cetrafs_cpu_to_le32(040755);
    in.nlink = cetrafs_cpu_to_le32(2);
    in.size = cetrafs_cpu_to_le64(CETRAFS_BLOCK_SIZE);
    in.generation = cetrafs_cpu_to_le64(0x0D1EC7ULL + dir);
    in.eh.eh_magic = cetrafs_cpu_to_le16(CETRAFS_EXT_MAGIC);
    in.eh.eh_max = cetrafs_cpu_to_le16(4);
    in.eh.eh_entries = cetrafs_cpu_to_le16(1);
    cetrafs_ee_set_lblk(&in.et.leaf[0], 0);
    cetrafs_ee_set_len(&in.et.leaf[0], 1, 0);
    cetrafs_ee_set_pblk(&in.et.leaf[0], data);
    in.read_open_nodes = 0;
    in.ns_lock_owner = cetrafs_cpu_to_le32(CETRAFS_NODE_ID_NONE);
    cetrafs_inode_stamp_crcs_us(&in);
    {
        uint8_t rec[CETRAFS_BLOCK_SIZE];

        memset(rec, 0, sizeof(rec));
        memcpy(rec, &in, sizeof(in));
        wr(fd, rec, sizeof(rec), (off_t) (cetrafs_le64(sb.inode_table_start) + dir - 1) * CETRAFS_BLOCK_SIZE);
    }

    memset(blk, 0, sizeof(blk));
    de[0].inode = cetrafs_cpu_to_le64(dir);
    de[0].name_len = cetrafs_cpu_to_le16(1);
    de[0].file_type = CETRAFS_FT_DIR;
    de[0].name[0] = '.';
    de[1].inode = cetrafs_cpu_to_le64(1);
    de[1].name_len = cetrafs_cpu_to_le16(2);
    de[1].file_type = CETRAFS_FT_DIR;
    memcpy(de[1].name, "..", 2);
    de[2].inode = cetrafs_cpu_to_le64(victim);
    de[2].name_len = cetrafs_cpu_to_le16(1);
    de[2].file_type = CETRAFS_FT_REG;
    de[2].name[0] = 'v';
    de[3].name_len = cetrafs_cpu_to_le16(4000);
    memset(&tail, 0, sizeof(tail));
    tail.magic = cetrafs_cpu_to_le32(CETRAFS_DIRENT_TAIL_MAGIC);
    tail.crc = cetrafs_cpu_to_le32(crc32c_update(0, blk, CETRAFS_DIRENT_TAIL_OFF));
    memcpy(blk + CETRAFS_DIRENT_TAIL_OFF, &tail, sizeof(tail));
    wr(fd, blk, sizeof(blk), (off_t) data * CETRAFS_BLOCK_SIZE);

    printf("dirtree_poke: dir ino=%" PRIu64 " at block %" PRIu64 ", victim ino=%" PRIu64 " named only in it\n", dir,
           data, victim);
    close(fd);
    return 0;
}
