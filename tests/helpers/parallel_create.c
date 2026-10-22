// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * parallel_create.c -- test-only helper: N processes each creat()ing M
 * files in its OWN directory under <base>.
 *
 * The separate directories are the whole point. Every namespace mutation
 * brackets itself in nslock.c's per-inode lock on the PARENT, so N
 * creates in one directory are serialised by that lock and never
 * contend for anything below it. Creates in N *different* directories
 * take N different locks and run genuinely in parallel, which is the
 * only way to put real concurrent pressure on the shared global inode
 * bitmap underneath -- the one allocator every directory shares.
 *
 * Shell is far too slow to expose that window (a `: > file` loop spends
 * milliseconds per create, so the microseconds that matter almost never
 * overlap); a tight creat() loop from forked children does it in one
 * run.
 *
 * Usage: parallel_create <base-dir> <procs> <files-per-proc>
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    const char *base;
    int procs, per, i, j, failures = 0;
    char path[1024];

    if (argc != 4) {
        fprintf(stderr, "usage: %s <base-dir> <procs> <files-per-proc>\n", argv[0]);
        return 2;
    }
    base = argv[1];
    procs = atoi(argv[2]);
    per = atoi(argv[3]);
    if (procs < 1 || per < 1)
        return 2;

    for (i = 0; i < procs; i++) {
        snprintf(path, sizeof(path), "%s/d%d", base, i);
        if (mkdir(path, 0755) != 0) {
            perror("mkdir");
            return 1;
        }
    }

    for (i = 0; i < procs; i++) {
        pid_t pid = fork();

        if (pid < 0) {
            perror("fork");
            return 1;
        }
        if (pid == 0) {
            for (j = 0; j < per; j++) {
                int fd;

                snprintf(path, sizeof(path), "%s/d%d/f%d", base, i, j);
                fd = creat(path, 0644);
                if (fd < 0)
                    _exit(1);
                close(fd);
            }
            _exit(0);
        }
    }

    for (i = 0; i < procs; i++) {
        int status = 0;

        if (wait(&status) < 0 || status != 0)
            failures++;
    }
    if (failures) {
        fprintf(stderr, "%d child(ren) failed to create their files\n", failures);
        return 1;
    }
    return 0;
}
