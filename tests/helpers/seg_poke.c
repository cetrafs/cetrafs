// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * seg_poke.c -- test-only helper: damage the Block Group table CHAIN.
 *
 * The table stopped being one contiguous run: the first segment is the
 * run mkfs laid down, and growing APPENDS segments linked by `next`
 * (docs/internal/BG-OWNERSHIP-DESIGN.md). A chain brings failure modes
 * a contiguous array does not have -- a loop, a segment that is not
 * one, a link into the middle of data, a link left dangling by a crash
 * -- and every one of those has to be something fsck reports rather
 * than something it walks off the end of.
 *
 * This injects them. Without it, "fsck detects a broken chain" is an
 * assertion nobody has measured.
 *
 * Usage: seg_poke <dev> loop          -- point the tail back at the head
 *        seg_poke <dev> magic         -- corrupt the first segment's magic
 *        seg_poke <dev> crc           -- corrupt its checksum
 *        seg_poke <dev> dangle <lba>  -- point the tail at <lba>
 *        seg_poke <dev> firstid <n>   -- lie about the segment's first id
 *        seg_poke <dev> dump
 */
#define _GNU_SOURCE
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

static void die(const char *m)
{
    fprintf(stderr, "seg_poke: %s\n", m);
    exit(1);
}

static void rd(int fd, void *b, size_t n, off_t off)
{
    if (pread(fd, b, n, off) != (ssize_t) n)
        die("short read");
}

static void wr(int fd, const void *b, size_t n, off_t off)
{
    if (pwrite(fd, b, n, off) != (ssize_t) n)
        die("short write");
}

static void restamp(cetrafs_bg_segment_t *seg)
{
    seg->checksum = 0;
    seg->checksum = cetrafs_cpu_to_le64((uint64_t) crc32c_struct(seg, sizeof(*seg),
                                                                 offsetof(cetrafs_bg_segment_t, checksum),
                                                                 sizeof(seg->checksum)));
}

int main(int argc, char **argv)
{
    cetrafs_superblock_t sb;
    cetrafs_bg_segment_t seg;
    uint64_t head, cur, prev = 0;
    int fd;

    if (argc < 3) {
        fprintf(stderr, "usage: %s <dev> loop|magic|crc|dangle <lba>|firstid <n>|dump\n", argv[0]);
        return 2;
    }
    fd = open(argv[1], O_RDWR);
    if (fd < 0)
        die("open");
    rd(fd, &sb, sizeof(sb), 0);
    if (cetrafs_le32(sb.magic) != CETRAFS_MAGIC)
        die("not a cetrafs volume");

    head = cetrafs_le64(sb.bg_table_next);
    if (!head)
        die("no appended segment: grow the volume first");

    /* Walk to the tail, which is what every injection targets. */
    cur = head;
    for (;;) {
        rd(fd, &seg, sizeof(seg), (off_t) cur * CETRAFS_BLOCK_SIZE);
        if (cetrafs_le32(seg.magic) != CETRAFS_BGSEG_MAGIC)
            die("chain is already broken");
        if (!cetrafs_le64(seg.next))
            break;
        prev = cur;
        cur = cetrafs_le64(seg.next);
    }
    (void) prev;

    if (!strcmp(argv[2], "dump")) {
        printf("head=%" PRIu64 " tail=%" PRIu64 " count=%u first_bg_id=%u\n", head, cur, cetrafs_le32(seg.count),
               cetrafs_le32(seg.first_bg_id));
    } else if (!strcmp(argv[2], "loop")) {
        seg.next = cetrafs_cpu_to_le64(head);
        restamp(&seg);
        wr(fd, &seg, sizeof(seg), (off_t) cur * CETRAFS_BLOCK_SIZE);
        printf("seg_poke: tail %" PRIu64 " now points back at the head %" PRIu64 "\n", cur, head);
    } else if (!strcmp(argv[2], "magic")) {
        rd(fd, &seg, sizeof(seg), (off_t) head * CETRAFS_BLOCK_SIZE);
        seg.magic = cetrafs_cpu_to_le32(0xDEADBEEF);
        restamp(&seg);
        wr(fd, &seg, sizeof(seg), (off_t) head * CETRAFS_BLOCK_SIZE);
        printf("seg_poke: head %" PRIu64 " magic destroyed\n", head);
    } else if (!strcmp(argv[2], "crc")) {
        rd(fd, &seg, sizeof(seg), (off_t) head * CETRAFS_BLOCK_SIZE);
        seg.checksum = cetrafs_cpu_to_le64(cetrafs_le64(seg.checksum) ^ 0xFFULL);
        wr(fd, &seg, sizeof(seg), (off_t) head * CETRAFS_BLOCK_SIZE);
        printf("seg_poke: head %" PRIu64 " checksum corrupted\n", head);
    } else if (!strcmp(argv[2], "dangle")) {
        if (argc < 4)
            die("dangle needs an lba");
        seg.next = cetrafs_cpu_to_le64(strtoull(argv[3], NULL, 0));
        restamp(&seg);
        wr(fd, &seg, sizeof(seg), (off_t) cur * CETRAFS_BLOCK_SIZE);
        printf("seg_poke: tail %" PRIu64 " now points at %s\n", cur, argv[3]);
    } else if (!strcmp(argv[2], "firstid")) {
        if (argc < 4)
            die("firstid needs a value");
        rd(fd, &seg, sizeof(seg), (off_t) head * CETRAFS_BLOCK_SIZE);
        seg.first_bg_id = cetrafs_cpu_to_le32((uint32_t) strtoul(argv[3], NULL, 0));
        restamp(&seg);
        wr(fd, &seg, sizeof(seg), (off_t) head * CETRAFS_BLOCK_SIZE);
        printf("seg_poke: head %" PRIu64 " first_bg_id -> %s\n", head, argv[3]);
    } else {
        die("unknown operation");
    }
    close(fd);
    return 0;
}
