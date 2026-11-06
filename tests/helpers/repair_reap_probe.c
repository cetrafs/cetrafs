// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * repair_reap_probe <dev> plant|renew|reap|show <row>
 *
 * Drives the tools' reap of a repair claim (cetrafs_repair_reap() in
 * userspace/devutil.h) on a CAW disk, for tests/kernel/repair_reap_keeps_saved.sh.
 *   plant  a REPAIR claim in <row>, hb_seq 5, borrowing a REGISTERED row
 *          kept at CETRAFS_REPAIR_SAVED_OFF -- a live repairer's block
 *   renew  sector 0 only, hb_seq + 1: the live repairer's renewal
 *   reap   judge the row as it stands now and reap it (the gap between
 *          the judgement and the swap is CETRAFS_TEST_REAP_GAP_SECS)
 *   show   "state=<n> hb=<n> saved=<state> saved_ok=<0|1>"
 * Every probe-side read and write is O_DIRECT: a page-cache writeback of
 * the whole block would hide what the swap did to its tail.
 */
#define _GNU_SOURCE
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
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "devutil.h"

static unsigned char *dbuf;

static int dread(int dfd, off_t off, size_t n)
{
    return pread(dfd, dbuf, n, off) == (ssize_t) n ? 0 : -1;
}

static int dwrite(int dfd, off_t off, size_t n)
{
    return pwrite(dfd, dbuf, n, off) == (ssize_t) n && fdatasync(dfd) == 0 ? 0 : -1;
}

int main(int argc, char **argv)
{
    cetrafs_superblock_t sb;
    cetrafs_node_entry_t ne;
    uint32_t row;
    off_t off;
    int fd, dfd;

    if (argc != 4) {
        fprintf(stderr, "usage: %s <dev> plant|renew|reap|show <row>\n", argv[0]);
        return 2;
    }
    row = (uint32_t) strtoul(argv[3], NULL, 0);
    fd = open(argv[1], O_RDWR);
    dfd = open(argv[1], O_RDWR | O_DIRECT);
    if (fd < 0 || dfd < 0 || posix_memalign((void **) &dbuf, 4096, CETRAFS_BLOCK_SIZE)) {
        perror("open");
        return 1;
    }
    if (pread(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb))
        return 1;
    off = (off_t) cetrafs_node_row_off(&sb, row);

    if (!strcmp(argv[2], "plant")) {
        cetrafs_node_entry_t saved;

        memset(dbuf, 0, CETRAFS_BLOCK_SIZE);
        memset(&ne, 0, sizeof(ne));
        ne.state = cetrafs_cpu_to_le32(CETRAFS_NODE_STATE_REPAIR);
        ne.last_seen = cetrafs_cpu_to_le64((uint64_t) time(NULL));
        ne.hb_seq = cetrafs_cpu_to_le64(5);
        memset(ne.node_uuid, 0x5a, sizeof(ne.node_uuid));
        snprintf(ne.label, sizeof(ne.label), "live-repairer");
        cetrafs_node_row_stamp(&ne);
        memset(&saved, 0, sizeof(saved));
        saved.state = cetrafs_cpu_to_le32(CETRAFS_NODE_STATE_REGISTERED);
        saved.last_seen = 0;
        saved.hb_seq = cetrafs_cpu_to_le64(77);
        memset(saved.node_uuid, 0xa5, sizeof(saved.node_uuid));
        snprintf(saved.label, sizeof(saved.label), "borrowed");
        cetrafs_node_row_stamp(&saved);
        memcpy(dbuf, &ne, sizeof(ne));
        memcpy(dbuf + CETRAFS_REPAIR_SAVED_OFF, &saved, sizeof(saved));
        return dwrite(dfd, off, CETRAFS_BLOCK_SIZE) ? 1 : 0;
    }
    if (!strcmp(argv[2], "renew")) {
        if (dread(dfd, off, CETRAFS_BLOCK_SIZE))
            return 1;
        memcpy(&ne, dbuf, sizeof(ne));
        ne.hb_seq = cetrafs_cpu_to_le64(cetrafs_le64(ne.hb_seq) + 1);
        ne.last_seen = cetrafs_cpu_to_le64((uint64_t) time(NULL));
        cetrafs_node_row_stamp(&ne);
        memcpy(dbuf, &ne, sizeof(ne));
        return dwrite(dfd, off, 512) ? 1 : 0; /* the record's sector, nothing else */
    }
    if (!strcmp(argv[2], "reap")) {
        if (!cetrafs_caw_probe(fd)) {
            fprintf(stderr, "no COMPARE AND WRITE on %s\n", argv[1]);
            return 3;
        }
        if (cetrafs_caw_lbs >= CETRAFS_BLOCK_SIZE) {
            fprintf(stderr, "logical block %u: the row has no separate tail\n", cetrafs_caw_lbs);
            return 3;
        }
        if (dread(dfd, off, CETRAFS_BLOCK_SIZE))
            return 1;
        memcpy(&ne, dbuf, sizeof(ne));
        posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
        cetrafs_repair_reap(fd, &sb, row, &ne);
        return 0;
    }
    if (!strcmp(argv[2], "show")) {
        cetrafs_node_entry_t saved;

        if (dread(dfd, off, CETRAFS_BLOCK_SIZE))
            return 1;
        memcpy(&ne, dbuf, sizeof(ne));
        memcpy(&saved, dbuf + CETRAFS_REPAIR_SAVED_OFF, sizeof(saved));
        printf("state=%u hb=%llu saved=%u saved_ok=%d\n", cetrafs_le32(ne.state),
               (unsigned long long) cetrafs_le64(ne.hb_seq), cetrafs_le32(saved.state),
               cetrafs_node_row_crc_ok(&saved));
        return 0;
    }
    fprintf(stderr, "unknown mode %s\n", argv[2]);
    return 2;
}
