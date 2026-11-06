// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * fspick_reconfigure <mountpoint> [ro|rw]
 *
 * Reconfigure a mount through the new mount API: fspick(2), optionally
 * one "ro"/"rw" flag, then FSCONFIG_CMD_RECONFIGURE. With no flag the
 * context's sb_flags_mask carries no SB_RDONLY: a reconfigure that does
 * not touch read-only-ness at all (tests/kernel/reconfigure_flags_mask.sh).
 * Prints "ok" or "err <errno>".
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SYS_fspick
#define SYS_fspick 433
#endif
#ifndef SYS_fsconfig
#define SYS_fsconfig 431
#endif
#define FSCONFIG_SET_FLAG 0
#define FSCONFIG_CMD_RECONFIGURE 7
#define FSPICK_CLOEXEC 0x1

int main(int argc, char **argv)
{
    int fd;

    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: %s <mountpoint> [ro|rw]\n", argv[0]);
        return 2;
    }
    fd = (int) syscall(SYS_fspick, AT_FDCWD, argv[1], FSPICK_CLOEXEC);
    if (fd < 0) {
        printf("err %d\n", errno);
        return 1;
    }
    if (argc == 3 && syscall(SYS_fsconfig, fd, FSCONFIG_SET_FLAG, argv[2], NULL, 0) != 0) {
        printf("err %d\n", errno);
        return 1;
    }
    if (syscall(SYS_fsconfig, fd, FSCONFIG_CMD_RECONFIGURE, NULL, NULL, 0) != 0) {
        printf("err %d\n", errno);
        return 1;
    }
    printf("ok\n");
    return 0;
}
