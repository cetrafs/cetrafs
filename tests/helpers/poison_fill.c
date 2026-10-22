// SPDX-License-Identifier: GPL-2.0-or-later
/* Fill a file with 0xAB, <MiB> megabytes of it.
 *
 * The fallocate suite poisons the free space so a preallocated extent
 * that leaked its previous contents reads as 0xAB rather than as zero.
 * That only works if the poison covers enough of the volume that the
 * later reservation MUST reuse it, which means writing hundreds of MiB
 * -- too slow and too awkward to do from a shell heredoc. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s <file> <MiB>\n", argv[0]);
        return 2;
    }
    long mb = strtol(argv[2], NULL, 10);
    int fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    char *buf = malloc(1 << 20);
    if (!buf) {
        close(fd);
        return 1;
    }
    memset(buf, 0xAB, 1 << 20);
    for (long i = 0; i < mb; i++) {
        ssize_t n = write(fd, buf, 1 << 20);
        if (n != (1 << 20)) {
            /* Running out of space is the expected end of a fill. */
            break;
        }
    }
    free(buf);
    if (fsync(fd) != 0) {
        perror("fsync");
        close(fd);
        return 1;
    }
    close(fd);
    return 0;
}
