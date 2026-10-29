// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * scrub_shadow_probe.c -- test-only helper: hold a large, WRITTEN but
 * UNPUBLISHED file open while the background scrub runs, then say
 * whether its data survived.
 *
 * The hot write path stages extent state in the inode's in-core shadow
 * and publishes it to the device only at a durability boundary. Between
 * those two moments the file's blocks are bitmap-allocated and named by
 * nothing on the platter -- which is indistinguishable from a leak to
 * anything that decides from the on-disk records alone.
 *
 * So: write, do NOT fsync, and keep the fd open across a couple of
 * scrub cycles. The content check afterwards is the one that matters;
 * the suite watches scrub_reclaimed over the same window.
 *
 * Usage: scrub_shadow_probe <path> <blocks> <hold-secs>
 * Prints "written: N", then "content: ok" or "content: bad at block B".
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BS 4096

static unsigned char buf[BS];

static uint64_t mix(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return x;
}

static void fill(unsigned char *b, uint64_t blk)
{
    uint64_t *w = (uint64_t *) b;
    unsigned k;
    for (k = 0; k < BS / 8; k++)
        w[k] = mix(blk * 1000003u + k);
}

int main(int argc, char **argv)
{
    unsigned char want[BS];
    uint64_t n, nblocks;
    unsigned hold;
    int fd;

    if (argc < 4)
        return 2;
    nblocks = strtoull(argv[2], NULL, 0);
    hold = (unsigned) strtoul(argv[3], NULL, 0);

    fd = open(argv[1], O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror("open");
        return 2;
    }
    for (n = 0; n < nblocks; n++) {
        fill(buf, n);
        if (pwrite(fd, buf, BS, (off_t) n * BS) != BS)
            break;
    }
    printf("written: %llu\n", (unsigned long long) n);
    fflush(stdout);
    nblocks = n;

    /* No fsync, no close: the extents stay in the shadow, and the blocks
     * stay unreferenced by anything the scrub can read off the device. */
    sleep(hold);

    fsync(fd);
    close(fd);
    fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        perror("reopen");
        return 2;
    }
    for (n = 0; n < nblocks; n++) {
        if (pread(fd, buf, BS, (off_t) n * BS) != BS) {
            printf("content: bad at block %llu (short read)\n", (unsigned long long) n);
            close(fd);
            return 1;
        }
        fill(want, n);
        if (memcmp(buf, want, BS)) {
            printf("content: bad at block %llu\n", (unsigned long long) n);
            close(fd);
            return 1;
        }
    }
    printf("content: ok\n");
    close(fd);
    return 0;
}
