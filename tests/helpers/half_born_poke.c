// SPDX-License-Identifier: GPL-2.0-or-later
// half_born_poke -- stage a create that stopped after its birth claim
// on a raw, UNMOUNTED cetrafs image: set inode #ino's bit and write its
// slot as a HALF-BORN record -- the namespace sector checksummed, naming
// no file, claimed by <owner> at <incarnation>; the file sector zeros.
// That is what a birth claim over a never-written slot leaves when its
// node stops before the record write.
//
// usage: half_born_poke <image> <ino> <owner_node_id> <incarnation>
//        half_born_poke <image> <ino> --landed
//        half_born_poke <image> <ino> --landed-fd <owner_node_id> <incarnation>
//
// --landed stages the other half-landed shape (audit 2026-11-15 BM-69):
// inode #ino's bit set, its file sector left as it is, its namespace
// sector restamped on the NEXT generation -- what a create's whole-
// record write leaves when it stops between its two sectors. A slot
// with no file in it (mkfs's dead stamp) is given a regular file's
// mode and one link, as the create was writing.
//
// --landed-fd stages the other half: the namespace sector is the birth
// claim of <owner> at <incarnation> over the slot's dead record, and the
// FILE sector has landed, restamped on the next generation.
#include <fcntl.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static int landed(const char *path, uint64_t ino, int fd_half, uint32_t owner, uint32_t inc)
{
    int fd = open(path, O_RDWR);
    cetrafs_superblock_t sb;
    uint8_t blk[CETRAFS_BLOCK_SIZE];
    cetrafs_inode_t in;

    if (fd < 0) {
        perror("open");
        return 2;
    }
    rd(fd, &sb, sizeof(sb), 0);
    if (!ino || ino > cetrafs_le32(sb.inodes_count)) {
        fprintf(stderr, "ino %" PRIu64 " out of range\n", ino);
        return 2;
    }
    uint64_t bblk = 0, boff = 0; /* the bit's block, and its offset in that block */

    cetrafs_u_ino_lba(fd, &sb, ino, &bblk, &boff);
    off_t roff = (off_t) cetrafs_u_ino_lba(fd, &sb, ino, NULL, NULL) * CETRAFS_BLOCK_SIZE;

    rd(fd, blk, sizeof(blk), roff);
    memcpy(&in, blk, sizeof(in));
    if (!cetrafs_inode_crcs_ok(&in) || cetrafs_le64(in.ino) != ino) {
        fprintf(stderr, "ino %" PRIu64 ": not a valid record to half-land\n", ino);
        return 2;
    }
    if (fd_half) {
        /* The claim's sector over the dead record, and a file sector of
         * the next generation -- an empty tree, as a create writes. */
        in.ns_lock_owner = cetrafs_cpu_to_le32(owner);
        in.ns_lock_incarnation = cetrafs_cpu_to_le32(inc);
        in.ns_checksum = cetrafs_cpu_to_le64(0);
        in.ns_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_ns_us(&in));
        in.fd_generation = cetrafs_cpu_to_le64(cetrafs_le64(in.generation) + 1);
        in.fd_ino = in.ino;
        in.fd_checksum = 0;
        in.fd_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_fd_us(&in));
        memcpy(blk, &in, sizeof(in));
        wr(fd, blk, CETRAFS_INODE_NS_BYTES + CETRAFS_INODE_FD_BYTES, roff);
    } else {
        if (!in.mode) {
            in.mode = cetrafs_cpu_to_le32(0100644);
            in.nlink = cetrafs_cpu_to_le32(1);
        }
        in.generation = cetrafs_cpu_to_le64(cetrafs_le64(in.fd_generation) + 1);
        in.ns_checksum = cetrafs_cpu_to_le64(0);
        in.ns_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_ns_us(&in));
        memcpy(blk, &in, CETRAFS_INODE_NS_BYTES); /* the file sector as it was */
        wr(fd, blk, CETRAFS_INODE_NS_BYTES, roff);
    }
    if (cetrafs_bmap_poke_off_us(fd, bblk, boff, 1, 0) < 0) { /* set, its sector restamped */
        perror("bitmap");
        return 1;
    }
    if (fsync(fd) != 0) {
        perror("fsync");
        return 2;
    }
    close(fd);
    printf("ino=%" PRIu64 " half-landed: namespace generation %" PRIu64 ", file sector %" PRIu64 "\n", ino,
           (uint64_t) cetrafs_le64(in.generation), (uint64_t) cetrafs_le64(in.fd_generation));
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 4 && !strcmp(argv[3], "--landed"))
        return landed(argv[1], strtoull(argv[2], NULL, 0), 0, 0, 0);
    if (argc == 6 && !strcmp(argv[3], "--landed-fd"))
        return landed(argv[1], strtoull(argv[2], NULL, 0), 1, (uint32_t) strtoul(argv[4], NULL, 0),
                      (uint32_t) strtoul(argv[5], NULL, 0));
    if (argc != 5) {
        fprintf(stderr, "usage: %s <image> <ino> <owner_node_id> <incarnation>\n", argv[0]);
        return 2;
    }
    uint64_t ino = strtoull(argv[2], NULL, 0);
    uint32_t owner = (uint32_t) strtoul(argv[3], NULL, 0);
    uint32_t inc = (uint32_t) strtoul(argv[4], NULL, 0);
    int fd = open(argv[1], O_RDWR);
    cetrafs_superblock_t sb;

    if (fd < 0) {
        perror("open");
        return 2;
    }
    rd(fd, &sb, sizeof(sb), 0);
    if (!ino || ino > cetrafs_le32(sb.inodes_count)) {
        fprintf(stderr, "ino %" PRIu64 " out of range\n", ino);
        return 2;
    }

    uint64_t bblk = 0, boff = 0;

    cetrafs_u_ino_lba(fd, &sb, ino, &bblk, &boff);
    if (cetrafs_bmap_poke_off_us(fd, bblk, boff, 1, 0) < 0) { /* set, its sector restamped */
        perror("bitmap");
        return 1;
    }

    uint8_t blk[CETRAFS_BLOCK_SIZE];
    cetrafs_inode_t in;
    memset(blk, 0, sizeof(blk));
    memset(&in, 0, sizeof(in));
    in.ino = cetrafs_cpu_to_le64(ino);
    in.ns_lock_owner = cetrafs_cpu_to_le32(owner);
    in.ns_lock_incarnation = cetrafs_cpu_to_le32(inc);
    in.dirent_seq = cetrafs_cpu_to_le64(1);
    in.ns_checksum = cetrafs_cpu_to_le64(0);
    in.ns_checksum = cetrafs_cpu_to_le64(cetrafs_inode_crc_ns_us(&in));
    memcpy(blk, &in, CETRAFS_INODE_NS_BYTES); /* the file sector stays zeros */
    wr(fd, blk, sizeof(blk), (off_t) cetrafs_u_ino_lba(fd, &sb, ino, NULL, NULL) * CETRAFS_BLOCK_SIZE);
    if (fsync(fd) != 0) {
        perror("fsync");
        return 2;
    }
    close(fd);
    printf("ino=%" PRIu64 " half-born, claimed by node %u incarnation %u\n", ino, owner, inc);
    return 0;
}
