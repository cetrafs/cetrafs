// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * grow_claim_probe.c -- test-only helper: issue CETRAFS_IOC_GROW on a
 * mounted volume, presenting a CHOSEN claim identity (Node Registry row
 * and nonce), with the superblock the device currently holds.
 *
 * The superblock is unchanged, so the kernel never publishes anything:
 * a probe that passes the claim check fails later with -ESTALE ("the
 * volume is no longer the one growfs read"), and one refused by the
 * claim check fails with -EBUSY before the superblock is looked at.
 * That is the discrimination grow_claim_owner.sh asserts on. A probe
 * presenting a real claim's identity is therefore a safe way to ask the
 * kernel "would you have accepted this caller?".
 *
 * Usage: grow_claim_probe <mountdir> <device> <row> <nonce-hex-32>
 * Prints "grow_claim_probe: errno=N (text)" or "grow_claim_probe: ok".
 */
#include <cetrafs.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    cetrafs_grow_arg_t ga;
    unsigned char block[CETRAFS_BLOCK_SIZE];
    int dfd, dev, i;
    unsigned long row;

    if (argc != 5) {
        fprintf(stderr, "usage: %s <mountdir> <device> <row> <nonce-hex-32>\n", argv[0]);
        return 2;
    }
    if (strlen(argv[4]) != 2 * sizeof(ga.claim_nonce)) {
        fprintf(stderr, "grow_claim_probe: the nonce must be %zu hex digits\n", 2 * sizeof(ga.claim_nonce));
        return 2;
    }
    row = strtoul(argv[3], NULL, 0);

    dev = open(argv[2], O_RDONLY | O_CLOEXEC);
    if (dev < 0 || pread(dev, block, sizeof(block), 0) != (ssize_t) sizeof(block)) {
        perror("grow_claim_probe: reading block 0");
        return 2;
    }
    close(dev);

    memset(&ga, 0, sizeof(ga));
    memcpy(&ga.sb, block, sizeof(ga.sb));
    ga.claim_row = cetrafs_cpu_to_le32((uint32_t) row);
    for (i = 0; i < (int) sizeof(ga.claim_nonce); i++) {
        unsigned int b;

        if (sscanf(argv[4] + 2 * i, "%2x", &b) != 1) {
            fprintf(stderr, "grow_claim_probe: bad nonce\n");
            return 2;
        }
        ga.claim_nonce[i] = (unsigned char) b;
    }

    dfd = open(argv[1], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd < 0) {
        perror("grow_claim_probe: open mount");
        return 2;
    }
    if (ioctl(dfd, CETRAFS_IOC_GROW, &ga) < 0) {
        printf("grow_claim_probe: errno=%d (%s)\n", errno, strerror(errno));
        close(dfd);
        return 1;
    }
    printf("grow_claim_probe: ok\n");
    close(dfd);
    return 0;
}
