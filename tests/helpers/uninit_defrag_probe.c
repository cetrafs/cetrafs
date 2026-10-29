// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * uninit_defrag_probe.c -- test-only helper: build a file whose extent
 * list contains a PREALLOCATED (uninitialized) extent over a block that
 * still holds recognisable old content, then defrag it and report what
 * the file reads back.
 *
 * The shape matters and is not obvious, which is why it is a helper
 * rather than a few lines of shell:
 *
 *   1. write the file, then rewrite alternate blocks -- so it has
 *      several extents and the defrag has work to do;
 *   2. punch a hole at block PUNCH -- the blocks are freed, and the
 *      range correctly reads zeros;
 *   3. fallocate(KEEP_SIZE) ACROSS that hole -- the allocator hands the
 *      same block straight back, now mapped by an extent flagged
 *      uninitialized. It still reads zeros (the flag is what makes it),
 *      but the block on the platter still holds step 1's bytes;
 *   4. defrag.
 *
 * A mover that copies blocks and rebuilds the prefix as one plain
 * extent drops the flag and publishes those bytes as the file's data.
 *
 * Prints one "key: value" line per probe; the suite asserts on them.
 * Usage: uninit_defrag_probe <path>
 */
#define _GNU_SOURCE
#include <cetrafs.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/falloc.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BS 4096
#define NB 116
#define PUNCH 112
#define PUNCH_N 4
#define PRE_FROM 102
#define PRE_N 11

static unsigned char buf[BS];

static const char *probe(int fd, int blk)
{
    int i;
    memset(buf, 0, BS);
    if (pread(fd, buf, BS, (off_t) blk * BS) != BS)
        return "unreadable";
    for (i = 0; i < BS; i++)
        if (buf[i])
            return "data";
    return "zeros";
}

int main(int argc, char **argv)
{
    struct cetrafs_defrag_stats st;
    int fd, b, rc;

    if (argc < 2)
        return 2;
    fd = open(argv[1], O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror("open");
        return 2;
    }
    for (b = 0; b < NB; b++) {
        memset(buf, 0, BS);
        snprintf((char *) buf, BS, "ORIGINAL-block-%d", b);
        if (pwrite(fd, buf, BS, (off_t) b * BS) != BS) {
            perror("write");
            return 2;
        }
    }
    fsync(fd);
    for (b = 1; b < NB; b += 2) { /* fragment it */
        memset(buf, 0, BS);
        snprintf((char *) buf, BS, "REWRITE-block-%d", b);
        pwrite(fd, buf, BS, (off_t) b * BS);
    }
    fsync(fd);

    if (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, (off_t) PUNCH * BS, (off_t) PUNCH_N * BS)) {
        printf("setup: punch failed (%s)\n", strerror(errno));
        return 2;
    }
    if (fallocate(fd, FALLOC_FL_KEEP_SIZE, (off_t) PRE_FROM * BS, (off_t) PRE_N * BS)) {
        printf("setup: fallocate failed (%s)\n", strerror(errno));
        return 2;
    }
    printf("before: %s\n", probe(fd, PUNCH));

    rc = ioctl(fd, CETRAFS_IOC_DEFRAG, &st);
    if (rc == 0)
        printf("defrag: ran (%llu -> %llu extents, %llu blocks moved)\n", (unsigned long long) st.extents_before,
               (unsigned long long) st.extents_after, (unsigned long long) st.blocks_moved);
    else
        printf("defrag: declined %s\n", strerror(errno));

    printf("warm: %s\n", probe(fd, PUNCH));
    fsync(fd);
    close(fd);
    sync();
    fd = open("/proc/sys/vm/drop_caches", O_WRONLY);
    if (fd >= 0) {
        if (write(fd, "3", 1) != 1)
            perror("drop_caches");
        close(fd);
    }
    fd = open(argv[1], O_RDONLY);
    if (fd < 0)
        return 2;
    printf("cold: %s\n", probe(fd, PUNCH));
    close(fd);
    return 0;
}
