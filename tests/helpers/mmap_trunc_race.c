// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * mmap_trunc_race.c -- test-only helper: faults racing a shrinking
 * truncate on one file, with a content oracle.
 *
 * Three processes share one file of <pages> pages. Every page starts as
 * P0 (written with write(2)). Two MAP_SHARED mappers store P1 into the
 * first word of pages, over and over; a truncator shrinks the file to
 * <keep> pages and grows it back to <pages>, <rounds> times. A store past
 * the shrunk end takes SIGBUS, which the mapper recovers from and counts.
 * A store into a grown-back hole is a fault that allocates a block while
 * the truncate's frees are still pending.
 *
 * Oracle, checked after all three exit (the file's own read path):
 *   - the size is <pages> pages (the last operation was the grow);
 *   - pages below <keep> hold P1: the truncate never touches them, and
 *     the mappers stored P1 there before the first shrink (a lost store
 *     or a stale page below the end is a violation);
 *   - pages at or above <keep> hold 0 (a hole) or P1 (a store after the
 *     grow). P0 there is a dropped block that came back: stale data.
 *
 * Usage: mmap_trunc_race <file> <rounds> <pages> <keep>
 * Output: "ROUNDS=.. bus=.. stores=.. lost=.. stale=.. other=.. size=.."
 * Exit: 0 oracle holds; 1 a violation; 2 the race did not happen (no
 * SIGBUS: the stores never reached a shrunk file, so nothing was tested).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define PG 4096u
#define P0 UINT64_C(0x5a5a5a5a5a5a5a5a)
#define P1 UINT64_C(0xa5a5a5a5a5a5a5a5)

struct shared {
    volatile int started;   /* mappers that finished their first pass */
    volatile int done;      /* the truncator has finished its last grow */
    volatile long bus[2];   /* per-mapper SIGBUS count */
    volatile long stores[2];
};

static sigjmp_buf env;
static volatile sig_atomic_t armed;

static void on_bus(int sig)
{
    (void) sig;
    if (armed)
        siglongjmp(env, 1);
    _exit(3); /* a SIGBUS outside a store is not ours to recover */
}

static void die(const char *m)
{
    fprintf(stderr, "mmap_trunc_race: %s: %s\n", m, strerror(errno));
    exit(4);
}

static void mapper(int idx, const char *path, unsigned long pages, struct shared *sh)
{
    int fd = open(path, O_RDWR);
    volatile uint8_t *map;
    struct sigaction sa;
    unsigned long p;

    if (fd < 0)
        die("open (mapper)");
    map = mmap(NULL, pages * PG, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED)
        die("mmap");
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_bus;
    sigaction(SIGBUS, &sa, NULL);

    /* First pass: every page is a P1 before any shrink can run. */
    for (p = 0; p < pages; p++)
        *(volatile uint64_t *) (map + p * PG) = P1;
    __sync_fetch_and_add(&sh->started, 1);

    while (!sh->done) {
        for (p = 0; p < pages && !sh->done; p++) {
            if (sigsetjmp(env, 1) == 0) {
                armed = 1;
                *(volatile uint64_t *) (map + p * PG) = P1;
                armed = 0;
                sh->stores[idx]++;
            } else {
                armed = 0;
                sh->bus[idx]++;
            }
        }
    }
    munmap((void *) map, pages * PG);
    close(fd);
    _exit(0);
}

static void truncator(const char *path, unsigned long rounds, unsigned long pages, unsigned long keep,
                      struct shared *sh)
{
    int fd = open(path, O_RDWR);
    unsigned long r;

    if (fd < 0)
        die("open (truncator)");
    while (sh->started < 2)
        usleep(1000);
    for (r = 0; r < rounds; r++) {
        if (ftruncate(fd, (off_t) keep * PG) != 0)
            die("ftruncate shrink");
        if (ftruncate(fd, (off_t) pages * PG) != 0)
            die("ftruncate grow");
    }
    sh->done = 1;
    close(fd);
    _exit(0);
}

int main(int argc, char **argv)
{
    unsigned long rounds, pages, keep, p;
    struct shared *sh;
    long bus = 0, stores = 0;
    unsigned long lost = 0, stale = 0, other = 0;
    struct stat st;
    pid_t kids[3];
    int fd, status, i, bad = 0;
    uint64_t w;

    if (argc != 5) {
        fprintf(stderr, "usage: %s <file> <rounds> <pages> <keep>\n", argv[0]);
        return 2;
    }
    rounds = strtoul(argv[2], NULL, 10);
    pages = strtoul(argv[3], NULL, 10);
    keep = strtoul(argv[4], NULL, 10);
    if (!rounds || !pages || keep == 0 || keep >= pages) {
        fprintf(stderr, "mmap_trunc_race: need rounds>0, 0<keep<pages\n");
        return 2;
    }

    /* Every page P0 through write(2), then synced: real blocks to drop. */
    fd = open(argv[1], O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        die("create");
    for (p = 0; p < pages; p++) {
        w = P0;
        if (pwrite(fd, &w, sizeof(w), (off_t) (p * PG)) != (ssize_t) sizeof(w))
            die("pwrite P0");
    }
    if (fsync(fd) != 0)
        die("fsync");
    close(fd);

    sh = mmap(NULL, sizeof(*sh), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (sh == MAP_FAILED)
        die("mmap shared");
    memset((void *) sh, 0, sizeof(*sh));

    for (i = 0; i < 3; i++) {
        kids[i] = fork();
        if (kids[i] < 0)
            die("fork");
        if (kids[i] == 0) {
            if (i < 2)
                mapper(i, argv[1], pages, sh);
            else
                truncator(argv[1], rounds, pages, keep, sh);
        }
    }
    for (i = 0; i < 3; i++) {
        if (waitpid(kids[i], &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            fprintf(stderr, "mmap_trunc_race: child %d failed (status %d)\n", i, status);
            bad = 1;
        }
    }
    for (i = 0; i < 2; i++) {
        bus += sh->bus[i];
        stores += sh->stores[i];
    }

    fd = open(argv[1], O_RDONLY);
    if (fd < 0 || fstat(fd, &st) != 0)
        die("reopen");
    for (p = 0; p < pages; p++) {
        if (pread(fd, &w, sizeof(w), (off_t) (p * PG)) != (ssize_t) sizeof(w))
            die("pread");
        if (p < keep) {
            if (w != P1)
                lost++;
        } else if (w == P0) {
            stale++;
        } else if (w != 0 && w != P1) {
            other++;
        }
    }
    close(fd);
    printf("ROUNDS=%lu bus=%ld stores=%ld lost=%lu stale=%lu other=%lu size=%ld\n", rounds, bus, stores, lost,
           stale, other, (long) st.st_size);
    if (bad || lost || stale || other || st.st_size != (off_t) pages * PG)
        return 1;
    if (bus == 0)
        return 2;
    return 0;
}
