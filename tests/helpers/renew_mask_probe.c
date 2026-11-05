// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * renew_mask_probe -- test-only: does a SIGALRM tick run INSIDE a
 * main-line cetrafs_repair_renew()?
 *
 * The repair tools renew their registry claim from the work loop and
 * from a SIGALRM timer, through the same function and the same static
 * CAW buffer; a tick between the main line's read and its CAW made the
 * CAW miscompare (audit 2026-11-05, N7). devutil.h is compiled here with
 * pread() redirected to a wrapper that raises SIGALRM during the
 * renewal's own read -- the worst-placed tick, delivered on demand. The
 * handler records whether the renewal was still in progress.
 *
 * usage: renew_mask_probe <image>   prints "inside=<0|1> fired=<0|1>"
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/fs.h>
#include <scsi/sg.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static ssize_t probe_pread(int fd, void *buf, size_t n, off_t off);
#define pread probe_pread
#include "devutil.h"
#undef pread

static volatile sig_atomic_t fired, fired_inside;
static int arm;

static ssize_t probe_pread(int fd, void *buf, size_t n, off_t off)
{
    ssize_t r = pread(fd, buf, n, off);

    if (arm) {
        arm = 0;
        raise(SIGALRM); /* the tick, at the worst moment */
        fired_inside = fired; /* delivered at once: the handler ran mid-renewal */
    }
    return r;
}

static void on_alrm(int sig)
{
    (void) sig;
    fired = 1;
}

int main(int argc, char **argv)
{
    cetrafs_superblock_t sb;
    int fd;

    if (argc != 2) {
        fprintf(stderr, "usage: %s <image>\n", argv[0]);
        return 2;
    }
    fd = open(argv[1], O_RDWR);
    if (fd < 0 || pread(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb)) {
        perror("open/read superblock");
        return 2;
    }
    signal(SIGALRM, on_alrm);
    arm = 1;
    (void) cetrafs_repair_renew(fd, &sb, 0); /* row 0 is not ours: it answers -1 after its read */
    printf("inside=%d fired=%d\n", (int) fired_inside, (int) fired);
    return arm ? 3 : 0; /* 3: the renewal never read, nothing was probed */
}
