// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * caps_scan_probe -- test-only: list the registered rows
 * cetrafs_scan_node_caps() sees, one "row=<n> label=<l> caps=<x>" line
 * each. tests/image/growfs_caps_fresh.sh fills this host's page cache
 * with the registry first and registers a row in the backing file after,
 * so a scan served from the cache does not list it.
 *
 * usage: caps_scan_probe <device>
 */
#include <errno.h>
#include <fcntl.h>
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

#include "devutil.h"

int main(int argc, char **argv)
{
    char labels[64][CETRAFS_NODE_LABEL_LEN + 1];
    uint32_t caps[64], rows[64];
    int n, i;

    if (argc != 2) {
        fprintf(stderr, "usage: %s <device>\n", argv[0]);
        return 2;
    }
    n = cetrafs_scan_node_caps(argv[1], labels, caps, rows, 64);
    if (n < 0) {
        fprintf(stderr, "scan failed\n");
        return 1;
    }
    for (i = 0; i < n; i++)
        printf("row=%u label=%s caps=0x%x\n", rows[i], labels[i], caps[i]);
    return 0;
}
