// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * getdents_probe.c -- test-only helper: iterate a directory the way the
 * kernel really hands entries out, with control over the buffer size.
 *
 * Every existing test reads directories through `ls` or opendir(), which
 * use a buffer big enough to swallow a whole small directory in one
 * call. That never exercises the RESUME path: cetrafs_readdir() restarts
 * the walk from the first block on every getdents call and skips what it
 * has already emitted by comparing each entry's position against
 * ctx->pos, so an off-by-one there duplicates or drops entries only when
 * the buffer forces more than one call.
 *
 * Usage: getdents_probe list <dir> <bufsize>   one name per line
 *        getdents_probe seek <dir>             telldir/seekdir round-trip
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

struct linux_dirent64 {
    unsigned long long d_ino;
    long long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[];
};

static int do_list(const char *path, size_t bufsz)
{
    char *buf = malloc(bufsz);
    int fd = open(path, O_RDONLY | O_DIRECTORY);
    long n;

    if (fd < 0 || !buf) {
        perror("open");
        return 1;
    }
    for (;;) {
        n = syscall(SYS_getdents64, fd, buf, bufsz);
        if (n < 0) {
            perror("getdents64");
            close(fd);
            return 1;
        }
        if (n == 0)
            break;
        for (long off = 0; off < n;) {
            struct linux_dirent64 *d = (struct linux_dirent64 *) (buf + off);
            printf("%s\n", d->d_name);
            off += d->d_reclen;
        }
    }
    close(fd);
    free(buf);
    return 0;
}

/*
 * telldir() returns an opaque position that seekdir() must be able to
 * return to. cetrafs derives it from (logical block, slot), which is
 * stable while the entry stays put -- asserted here rather than assumed.
 */
static int do_seek(const char *path)
{
    DIR *d = opendir(path);
    struct dirent *e;
    long mark = -1;
    char want[256] = {0};
    int seen = 0;

    if (!d) {
        perror("opendir");
        return 1;
    }
    while ((e = readdir(d))) {
        if (++seen == 4) {
            /* the position BEFORE reading the next entry */
            mark = telldir(d);
            e = readdir(d);
            if (!e)
                break;
            snprintf(want, sizeof(want), "%s", e->d_name);
            break;
        }
    }
    if (mark < 0 || !want[0]) {
        fprintf(stderr, "directory too small for the seek probe\n");
        closedir(d);
        return 2;
    }
    seekdir(d, mark);
    e = readdir(d);
    if (!e) {
        printf("SEEK-EMPTY\n");
        closedir(d);
        return 0;
    }
    printf("%s %s\n", strcmp(e->d_name, want) == 0 ? "SEEK-OK" : "SEEK-WRONG", e->d_name);
    closedir(d);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 4 && !strcmp(argv[1], "list"))
        return do_list(argv[2], (size_t) strtoul(argv[3], NULL, 0));
    if (argc == 3 && !strcmp(argv[1], "seek"))
        return do_seek(argv[2]);
    fprintf(stderr, "usage: %s list <dir> <bufsize>\n       %s seek <dir>\n", argv[0], argv[0]);
    return 2;
}
