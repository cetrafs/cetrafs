// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * msync_vs_write.c -- test-only helper: msync(MS_SYNC) against a concurrent
 * write(2) to the same page.
 *
 * Usage:
 *   msync_vs_write run   <file> <iters>   run both writers, print the last values
 *   msync_vs_write check <file> <a> <b>   read the two words back, compare
 *
 * run: writer A stores generation g into word 0 of a MAP_SHARED page and
 * calls msync(MS_SYNC) after each store; writer B pwrite(2)s counter c into
 * word 1 of the same page. Both are plain processes, so the page is written
 * through the mapping and the write(2) path at once. Every msync must
 * return 0. Prints "lastA=<g> lastB=<c>".
 * check: word 0 must equal <a> and word 1 must equal <b> -- the values the
 * writers last produced, read after a remount.
 * Exit: 0 ok; 1 a msync failed or a value is wrong; 2 usage; 4 system error.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define PG 4096

struct shared {
    volatile uint64_t last_a;
    volatile uint64_t last_b;
    volatile int msync_fail;
};

static void die(const char *m)
{
    fprintf(stderr, "msync_vs_write: %s: %s\n", m, strerror(errno));
    exit(4);
}

int main(int argc, char **argv)
{
    struct shared *sh;
    uint64_t iters, g, c;
    volatile uint64_t *map;
    pid_t a, b;
    int fd, status;

    if (argc < 3)
        goto usage;
    if (strcmp(argv[1], "check") == 0) {
        uint64_t w[2];

        if (argc != 5)
            goto usage;
        fd = open(argv[2], O_RDONLY);
        if (fd < 0 || pread(fd, w, sizeof(w), 0) != (ssize_t) sizeof(w))
            die("read back");
        close(fd);
        if (w[0] != strtoull(argv[3], NULL, 10) || w[1] != strtoull(argv[4], NULL, 10)) {
            printf("CHECK word0=%" PRIu64 " word1=%" PRIu64 " want %s %s\n", w[0], w[1], argv[3], argv[4]);
            return 1;
        }
        printf("CHECK ok word0=%" PRIu64 " word1=%" PRIu64 "\n", w[0], w[1]);
        return 0;
    }
    if (strcmp(argv[1], "run") != 0 || argc != 4)
        goto usage;
    iters = strtoull(argv[3], NULL, 10);
    if (!iters)
        goto usage;

    fd = open(argv[2], O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        die("create");
    if (ftruncate(fd, PG) != 0)
        die("ftruncate");
    map = mmap(NULL, PG, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED)
        die("mmap");
    sh = mmap(NULL, sizeof(*sh), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (sh == MAP_FAILED)
        die("mmap shared");
    memset((void *) sh, 0, sizeof(*sh));

    a = fork();
    if (a < 0)
        die("fork");
    if (a == 0) {
        for (g = 1; g <= iters; g++) {
            map[0] = g;
            if (msync((void *) map, PG, MS_SYNC) != 0) {
                sh->msync_fail = 1;
                _exit(1);
            }
            sh->last_a = g;
        }
        _exit(0);
    }
    b = fork();
    if (b < 0)
        die("fork");
    if (b == 0) {
        for (c = 1; c <= iters; c++) {
            uint64_t v = c;

            if (pwrite(fd, &v, sizeof(v), 8) != (ssize_t) sizeof(v))
                _exit(1);
            sh->last_b = c;
        }
        _exit(0);
    }
    if (waitpid(a, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        sh->msync_fail = 1;
    if (waitpid(b, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        sh->msync_fail = 1;
    printf("lastA=%" PRIu64 " lastB=%" PRIu64 "\n", (uint64_t) sh->last_a, (uint64_t) sh->last_b);
    munmap((void *) map, PG);
    close(fd);
    return sh->msync_fail ? 1 : 0;

usage:
    fprintf(stderr, "usage: %s run <file> <iters> | check <file> <a> <b>\n", argv[0]);
    return 2;
}
