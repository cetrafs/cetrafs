// SPDX-License-Identifier: GPL-2.0-or-later
// odirect_probe -- prove a file's extent map is consulted FRESH on a
// continuously-held open, the way qemu holds a VM image across a migration.
//
// The nofilelock coherency fix makes cetrafs_get_block() read the inode
// record and extent tree fresh from the device (not from this node's
// buffer cache) when the file lock is disabled. A re-open would hide the
// difference -- d_revalidate refreshes on every path lookup regardless of
// the lock -- so the only way to exercise the get_block freshness itself
// is to hold ONE open across a peer's change and read again without
// re-looking-up. O_DIRECT forces every read through get_block (no page
// cache), exactly like Proxmox's cache=none.
//
// usage: odirect_probe <file> <ready_gate> <go_gate>
//   open <file> O_RDWR|O_DIRECT, read 4096 @ offset 0, print first 10 bytes,
//   create <ready_gate>, wait for <go_gate> to appear (peer poke happens
//   meanwhile), read 4096 @ offset 0 again through the SAME fd, print first
//   10 bytes. Two lines on stdout: "read1 <bytes>" then "read2 <bytes>".
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void rd(int fd, char *out)
{
    void *buf = NULL;
    if (posix_memalign(&buf, 4096, 4096)) { perror("memalign"); exit(2); }
    ssize_t n = pread(fd, buf, 4096, 0);
    if (n < 0) { perror("pread"); exit(2); }
    memcpy(out, buf, 10);
    out[10] = 0;
    free(buf);
}

int main(int argc, char **argv)
{
    if (argc != 4) { fprintf(stderr, "usage: %s <file> <ready> <go>\n", argv[0]); return 2; }
    int fd = open(argv[1], O_RDWR | O_DIRECT);
    if (fd < 0) { perror("open O_DIRECT"); return 2; }

    char a[16], b[16];
    rd(fd, a);
    printf("read1 %s\n", a);
    fflush(stdout);

    int g = open(argv[2], O_CREAT | O_WRONLY, 0600);
    if (g >= 0) close(g);

    for (int i = 0; i < 300; i++) {           /* up to ~30s for the go gate */
        if (access(argv[3], F_OK) == 0)
            break;
        usleep(100000);
    }

    rd(fd, b);
    printf("read2 %s\n", b);
    fflush(stdout);
    close(fd);
    return 0;
}
