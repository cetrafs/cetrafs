// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * record_write_storm.c -- test-only helper: drive concurrent inode-RECORD
 * writes against concurrent forced-fresh reads of the same records.
 *
 * Every chmod() rewrites the file's on-disk inode record through
 * cetrafs_write_raw_inode(); every open() of a file drives lock.c's
 * invalidate-then-read of ITS record, which is a forced-fresh read. Run
 * both at once across many files and the two collide on the buffer
 * cache.
 *
 * Each file is written once and then left alone, which is what makes a
 * lost write observable: a record write that gets reverted is simply the
 * final state of that file, so checking every file's mode at the end
 * finds it. (Hammering one file instead would hide all but the last
 * loss, since each write is a blind full-record overwrite.)
 *
 * Usage: record_write_storm <base-dir> <writers> <files-per-writer> <readers>
 */
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* The mode every file must end up with: distinctive, and not a mode any
 * other step in the suite sets. */
#define TARGET_MODE 0751

/* mode: 0 = stat+open (default), 1 = stat only, 2 = open only. Lets a
 * bisect tell a lookup-time refresh (stat) from an open-boundary one. */
static int reader_mode;

static void reader_loop(const char *base, int writers, int per)
{
    char path[1024];
    int w, f;

    for (;;) {
        for (w = 0; w < writers; w++) {
            for (f = 0; f < per; f++) {
                struct stat st;
                int fd;

                snprintf(path, sizeof(path), "%s/w%d/f%d", base, w, f);
                if (reader_mode != 2) {
                    if (stat(path, &st) != 0)
                        continue;
                    if (reader_mode == 1)
                        continue;
                }
                fd = open(path, O_RDONLY);
                if (fd >= 0)
                    close(fd);
            }
        }
    }
}

int main(int argc, char **argv)
{
    const char *base;
    int writers, per, readers, i, j, bad = 0;
    pid_t *rpids;
    char path[1024];

    if (argc != 5) {
        fprintf(stderr, "usage: %s <base-dir> <writers> <files-per-writer> <readers>\n", argv[0]);
        return 2;
    }
    base = argv[1];
    writers = atoi(argv[2]);
    per = atoi(argv[3]);
    readers = atoi(argv[4]);
    { const char *m = getenv("RWS_READER_MODE"); reader_mode = m ? atoi(m) : 0; }
    if (writers < 1 || per < 1 || readers < 0)
        return 2;

    for (i = 0; i < writers; i++) {
        snprintf(path, sizeof(path), "%s/w%d", base, i);
        if (mkdir(path, 0755) != 0) {
            perror("mkdir");
            return 1;
        }
    }

    rpids = calloc((size_t) (readers ? readers : 1), sizeof(*rpids));
    if (!rpids)
        return 1;
    for (i = 0; i < readers; i++) {
        pid_t pid = fork();

        if (pid == 0) {
            reader_loop(base, writers, per);
            _exit(0);
        }
        rpids[i] = pid;
    }

    for (i = 0; i < writers; i++) {
        pid_t pid = fork();

        if (pid < 0) {
            perror("fork");
            return 1;
        }
        if (pid == 0) {
            for (j = 0; j < per; j++) {
                int fd;

                snprintf(path, sizeof(path), "%s/w%d/f%d", base, i, j);
                fd = creat(path, 0644);
                if (fd < 0)
                    _exit(1);
                close(fd);
                /* The record write whose loss this test detects. */
                if (chmod(path, TARGET_MODE) != 0)
                    _exit(1);
            }
            _exit(0);
        }
    }

    for (i = 0; i < writers; i++) {
        int status = 0;

        if (wait(&status) < 0 || status != 0)
            bad++;
    }
    for (i = 0; i < readers; i++) {
        kill(rpids[i], SIGKILL);
        waitpid(rpids[i], NULL, 0);
    }
    free(rpids);

    if (bad) {
        fprintf(stderr, "%d writer(s) failed\n", bad);
        return 1;
    }
    return 0;
}
