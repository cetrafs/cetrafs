// SPDX-License-Identifier: GPL-2.0-or-later
// dio_aio -- O_DIRECT writes kept IN FLIGHT, through Linux AIO.
//
// A synchronous O_DIRECT write holds inode_lock until it completes, so
// nothing a shell or python can issue ever has two of them in flight
// against one file, or one in flight while something else runs. qemu
// with aio=native or io_uring does exactly that. Raw syscalls, so no
// libaio is needed on the test box.
//
// usage:
//   dio_aio pair <file> <nblocks> <half>
//       For each block b of the (preallocated or sparse) file: two
//       writes in ONE io_submit, <half> bytes of 'A' at b*4096 and
//       <half> bytes of 'B' at b*4096 + <half>, then wait for both.
//       Then read every block back O_DIRECT and count the blocks where
//       either half is not what was written. Prints
//       "blocks=<n> lost=<n> zeros=<n>" (zeros: lost blocks where the
//       damaged half reads as zeros). Exit 0 if the writes all worked.
//
//   dio_aio trunc <file> <off> <len> <newsize>
//       Submit ONE async write of <len> bytes at <off>, then ftruncate
//       the file to <newsize> while it is in flight, then reap it.
//       Prints "submitted inflight=<0|1>" before the truncate (1: the
//       write had not completed yet, so the truncate really raced it),
//       then "trunc_ms=<n> trunc=<rc> write=<res>".
//
//   dio_aio readmid <file> <off> <len> <delay_ms> <read_blk>
//       Submit ONE async write of <len> bytes of 'D' at <off>, wait
//       <delay_ms>, then read block <read_blk> O_DIRECT while the write
//       may still be completing. Prints "inflight=<0|1> read=<n>
//       first=<c>" (c: the block's first byte, '0' for NUL), then reaps.
//
//   dio_aio unit <file> <blk_a> <blk_b> <gap_ms>
//       Submit ONE async 4 KiB write of 'A' at <blk_a>, wait <gap_ms>,
//       then submit and reap ONE of 'B' at <blk_b>, then reap the first.
//       Reads both blocks back O_DIRECT and prints "a=<c> b=<c>" (each
//       block's first byte, '0' for NUL; '?' for a block not all one
//       byte) and "a_inflight=<0|1>" (1: A had not completed when B did).
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/aio_abi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static long io_setup(unsigned n, aio_context_t *ctx)
{
    return syscall(SYS_io_setup, n, ctx);
}
static long io_submit(aio_context_t ctx, long n, struct iocb **cbs)
{
    return syscall(SYS_io_submit, ctx, n, cbs);
}
static long io_getevents(aio_context_t ctx, long min, long max, struct io_event *ev, struct timespec *to)
{
    return syscall(SYS_io_getevents, ctx, min, max, ev, to);
}

static void *abuf(size_t n)
{
    void *p = NULL;

    if (posix_memalign(&p, 4096, n)) {
        perror("posix_memalign");
        exit(2);
    }
    return p;
}

static void prep(struct iocb *cb, int fd, void *buf, size_t len, long long off)
{
    memset(cb, 0, sizeof(*cb));
    cb->aio_fildes = fd;
    cb->aio_lio_opcode = IOCB_CMD_PWRITE;
    cb->aio_buf = (uint64_t) (uintptr_t) buf;
    cb->aio_nbytes = len;
    cb->aio_offset = off;
}

static long long now_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int do_pair(const char *path, long nblocks, size_t half)
{
    aio_context_t ctx = 0;
    int fd = open(path, O_RDWR | O_DIRECT);
    char *a = abuf(half), *b = abuf(half), *r = abuf(4096);
    long blk, lost = 0, zeros = 0, failed = 0;

    if (fd < 0 || io_setup(8, &ctx) < 0) {
        perror("open/io_setup");
        return 2;
    }
    memset(a, 'A', half);
    memset(b, 'B', half);
    for (blk = 0; blk < nblocks; blk++) {
        struct iocb c1, c2, *cbs[2] = { &c1, &c2 };
        struct io_event ev[2];
        long got = 0;

        prep(&c1, fd, a, half, blk * 4096LL);
        prep(&c2, fd, b, half, blk * 4096LL + (long long) half);
        if (io_submit(ctx, 2, cbs) != 2) {
            perror("io_submit");
            return 2;
        }
        while (got < 2) {
            long n = io_getevents(ctx, 1, 2 - got, ev, NULL);

            if (n < 0) {
                if (errno == EINTR)
                    continue;
                perror("io_getevents");
                return 2;
            }
            for (long i = 0; i < n; i++)
                if ((long long) ev[i].res != (long long) half)
                    failed++;
            got += n;
        }
    }
    for (blk = 0; blk < nblocks; blk++) {
        if (pread(fd, r, 4096, blk * 4096LL) != 4096) {
            perror("pread");
            return 2;
        }
        int ok_a = memcmp(r, a, half) == 0;
        int ok_b = memcmp(r + half, b, half) == 0;

        if (!ok_a || !ok_b) {
            const char *bad = !ok_a ? r : r + half;
            size_t i;

            lost++;
            for (i = 0; i < half && bad[i] == 0; i++)
                ;
            if (i == half)
                zeros++;
        }
    }
    printf("blocks=%ld lost=%ld zeros=%ld failed=%ld\n", nblocks, lost, zeros, failed);
    return failed ? 1 : 0;
}

static int do_trunc(const char *path, long long off, size_t len, long long newsize)
{
    aio_context_t ctx = 0;
    int fd = open(path, O_RDWR | O_DIRECT);
    char *buf = abuf(len);
    struct iocb c, *cbs[1] = { &c };
    struct io_event ev;
    struct timespec zero = { 0, 0 };
    long long t0;
    int rc;

    if (fd < 0 || io_setup(4, &ctx) < 0) {
        perror("open/io_setup");
        return 2;
    }
    memset(buf, 'T', len);
    prep(&c, fd, buf, len, off);
    if (io_submit(ctx, 1, cbs) != 1) {
        perror("io_submit");
        return 2;
    }
    printf("submitted inflight=%d\n", io_getevents(ctx, 0, 1, &ev, &zero) == 0 ? 1 : 0);
    fflush(stdout);
    t0 = now_ms();
    rc = ftruncate(fd, newsize);
    long long dt = now_ms() - t0;
    int terr = rc ? errno : 0;
    long n;

    while ((n = io_getevents(ctx, 1, 1, &ev, NULL)) < 0 && errno == EINTR)
        ;
    printf("trunc_ms=%lld trunc=%d write=%lld\n", dt, terr, n == 1 ? (long long) ev.res : -1LL);
    return 0;
}

static int do_unit(const char *path, long long ba, long long bb, long gap_ms)
{
    aio_context_t ctx = 0;
    int fd = open(path, O_RDWR | O_DIRECT);
    char *a = abuf(4096), *b = abuf(4096), *r = abuf(4096);
    struct iocb c1, c2, *p1[1] = { &c1 }, *p2[1] = { &c2 };
    struct io_event ev[2];
    struct timespec zero = { 0, 0 };
    long got_a = 0, n;
    char ca, cb;
    int inflight = 0;

    if (fd < 0 || io_setup(4, &ctx) < 0) {
        perror("open/io_setup");
        return 2;
    }
    memset(a, 'A', 4096);
    memset(b, 'B', 4096);
    prep(&c1, fd, a, 4096, ba * 4096LL);
    prep(&c2, fd, b, 4096, bb * 4096LL);
    if (io_submit(ctx, 1, p1) != 1) {
        perror("io_submit a");
        return 2;
    }
    usleep((useconds_t) gap_ms * 1000);
    if (io_submit(ctx, 1, p2) != 1) {
        perror("io_submit b");
        return 2;
    }
    /* reap until B is done; note whether A was still out at that point */
    for (;;) {
        n = io_getevents(ctx, 1, 1, ev, NULL);
        if (n < 0 && errno == EINTR)
            continue;
        if (n != 1) {
            perror("io_getevents");
            return 2;
        }
        if (ev[0].obj == (uint64_t) (uintptr_t) &c1) {
            got_a = 1;
            continue;
        }
        break;
    }
    if (!got_a) {
        inflight = io_getevents(ctx, 0, 1, ev, &zero) == 0;
        if (!inflight)
            got_a = 1;
    }
    while (!got_a) {
        n = io_getevents(ctx, 1, 1, ev, NULL);
        if (n == 1)
            got_a = 1;
        else if (n < 0 && errno != EINTR) {
            perror("io_getevents a");
            return 2;
        }
    }
    ca = cb = '?';
    if (pread(fd, r, 4096, ba * 4096LL) == 4096) {
        size_t i;

        for (i = 1; i < 4096 && r[i] == r[0]; i++)
            ;
        ca = i == 4096 ? (r[0] ? r[0] : '0') : '?';
    }
    if (pread(fd, r, 4096, bb * 4096LL) == 4096) {
        size_t i;

        for (i = 1; i < 4096 && r[i] == r[0]; i++)
            ;
        cb = i == 4096 ? (r[0] ? r[0] : '0') : '?';
    }
    printf("a=%c b=%c a_inflight=%d\n", ca, cb, inflight);
    close(fd);
    return 0;
}

static int do_readmid(const char *path, long long off, size_t len, long delay_ms, long long rblk)
{
    aio_context_t ctx = 0;
    int fd = open(path, O_RDWR | O_DIRECT);
    char *buf = abuf(len), *r = abuf(4096);
    struct iocb c, *cbs[1] = { &c };
    struct io_event ev;
    struct timespec zero = { 0, 0 };
    long n;
    ssize_t got;

    if (fd < 0 || io_setup(4, &ctx) < 0) {
        perror("open/io_setup");
        return 2;
    }
    memset(buf, 'D', len);
    prep(&c, fd, buf, len, off);
    if (io_submit(ctx, 1, cbs) != 1) {
        perror("io_submit");
        return 2;
    }
    usleep(delay_ms * 1000);
    int inflight = io_getevents(ctx, 0, 1, &ev, &zero) == 0;

    got = pread(fd, r, 4096, rblk * 4096LL);
    printf("inflight=%d read=%zd first=%c\n", inflight, got, got > 0 ? (r[0] ? r[0] : '0') : '-');
    if (inflight)
        while ((n = io_getevents(ctx, 1, 1, &ev, NULL)) < 0 && errno == EINTR)
            ;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 5 && strcmp(argv[1], "pair") == 0) {
        size_t half = strtoul(argv[4], NULL, 0);

        if (!half || half % 512 || half * 2 > 4096) {
            fprintf(stderr, "half must be a multiple of 512, at most 2048\n");
            return 2;
        }
        return do_pair(argv[2], strtol(argv[3], NULL, 0), half);
    }
    if (argc == 6 && strcmp(argv[1], "trunc") == 0)
        return do_trunc(argv[2], strtoll(argv[3], NULL, 0), strtoul(argv[4], NULL, 0), strtoll(argv[5], NULL, 0));
    if (argc == 6 && strcmp(argv[1], "unit") == 0)
        return do_unit(argv[2], strtoll(argv[3], NULL, 0), strtoll(argv[4], NULL, 0), strtol(argv[5], NULL, 0));
    if (argc == 7 && strcmp(argv[1], "readmid") == 0)
        return do_readmid(argv[2], strtoll(argv[3], NULL, 0), strtoul(argv[4], NULL, 0), strtol(argv[5], NULL, 0),
                          strtoll(argv[6], NULL, 0));
    fprintf(stderr,
            "usage: %s pair <file> <nblocks> <half>\n"
            "       %s trunc <file> <off> <len> <newsize>\n"
            "       %s readmid <file> <off> <len> <delay_ms> <read_blk>\n"
            "       %s unit <file> <blk_a> <blk_b> <gap_ms>\n",
            argv[0], argv[0], argv[0], argv[0]);
    return 2;
}
