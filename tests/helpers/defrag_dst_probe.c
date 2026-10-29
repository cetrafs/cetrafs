// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * defrag_dst_probe.c -- test-only helper: build a badly fragmented file
 * with verifiable content, defrag it, and check it afterwards.
 *
 * The point is a defrag that takes SECONDS. Its destination run is
 * allocated up front and referenced by nothing until each step commits,
 * so a move that outlives a scrub cycle is the only way to show whether
 * the background scrub will reclaim it out from under the mover.
 *
 * Fragmenting takes two files written in lockstep: cetrafs reuses a
 * block when a file is rewritten in place, so overwriting cannot
 * fragment anything. Interleaving the allocations of two files and then
 * deleting one leaves the survivor's blocks scattered.
 *
 * Usage: defrag_dst_probe <dir> <blocks> build|defrag|verify
 */
#define _GNU_SOURCE
#include <cetrafs.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BS 4096
static unsigned char buf[BS], want[BS];

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
        w[k] = mix(blk * 2654435761u + k);
}

int main(int argc, char **argv)
{
    char victim[512], spacer[512];
    uint64_t n, nblocks;
    int fd, fd2;

    if (argc < 4)
        return 2;
    nblocks = strtoull(argv[2], NULL, 0);
    snprintf(victim, sizeof(victim), "%s/victim", argv[1]);
    snprintf(spacer, sizeof(spacer), "%s/spacer", argv[1]);

    if (!strcmp(argv[3], "build")) {
        fd = open(victim, O_RDWR | O_CREAT | O_TRUNC, 0644);
        fd2 = open(spacer, O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd < 0 || fd2 < 0) {
            perror("open");
            return 2;
        }
        for (n = 0; n < nblocks; n++) {
            fill(buf, n);
            if (pwrite(fd, buf, BS, (off_t) n * BS) != BS)
                break;
            /* one block of the other file between each of ours */
            memset(want, 0x5a, BS);
            if (pwrite(fd2, want, BS, (off_t) n * BS) != BS)
                break;
            if ((n & 63) == 0) {
                fsync(fd);
                fsync(fd2);
            }
        }
        fsync(fd);
        fsync(fd2);
        close(fd);
        close(fd2);
        unlink(spacer); /* leave the survivor's blocks scattered */
        sync();
        printf("built: %llu blocks\n", (unsigned long long) n);
        return 0;
    }

    if (!strcmp(argv[3], "defrag")) {
        struct cetrafs_defrag_stats st;
        fd = open(victim, O_RDWR);
        if (fd < 0) {
            perror("open");
            return 2;
        }
        if (ioctl(fd, CETRAFS_IOC_DEFRAG, &st) == 0)
            printf("defrag: %llu -> %llu extents, %llu blocks moved\n", (unsigned long long) st.extents_before,
                   (unsigned long long) st.extents_after, (unsigned long long) st.blocks_moved);
        else
            printf("defrag: failed %s\n", strerror(errno));
        close(fd);
        return 0;
    }

    fd = open(victim, O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 2;
    }
    for (n = 0; n < nblocks; n++) {
        if (pread(fd, buf, BS, (off_t) n * BS) != BS)
            break;
        fill(want, n);
        if (memcmp(buf, want, BS)) {
            printf("content: bad at block %llu\n", (unsigned long long) n);
            close(fd);
            return 1;
        }
    }
    printf("content: ok (%llu blocks)\n", (unsigned long long) n);
    close(fd);
    return 0;
}
