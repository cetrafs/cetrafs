// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * repair_watch_probe -- test-only: does a repair claim's heartbeat watch
 * see a peer's beat that reached the DEVICE after this process cached
 * the registry?
 *
 * A peer on another host writes its row past its own cache; this host
 * sees the write only if the tool drops its cached pages before it
 * re-reads. The loop device here reproduces that exactly: the watch is
 * armed through the device (filling this host's page cache), the peer's
 * beat is written into the BACKING FILE (the loop device's cache is not
 * told), and the watch's tick must then see the beat.
 *
 * usage: repair_watch_probe <device> <image>
 *   The image's row 1 must be a REGISTERED row (node_poke sets it up).
 *   Prints "cached_hb=<n> watch_beat=<0|1>". watch_beat=1 is the only
 *   correct answer: the peer beat.
 */
#define _GNU_SOURCE /* O_DIRECT, for devutil.h's device reads */
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
    cetrafs_superblock_t sb;
    cetrafs_node_entry_t cached, peer;
    unsigned char blk[CETRAFS_BLOCK_SIZE];
    int fd, ifd;
    off_t off;

    if (argc != 3) {
        fprintf(stderr, "usage: %s <device> <image>\n", argv[0]);
        return 2;
    }
    fd = open(argv[1], O_RDWR);
    if (fd < 0 || pread(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb) || cetrafs_le32(sb.magic) != CETRAFS_MAGIC) {
        perror("open/read superblock");
        return 2;
    }
    /* Row 0 is ours; row 1 is the peer. Arm the watch through the device:
     * this read is what fills this host's cache for the registry. */
    cetrafs_repair_watch_arm(fd, &sb, 0);
    off = cetrafs_node_row_off(&sb, 1);
    if (pread(fd, blk, sizeof(blk), off) != (ssize_t) sizeof(blk)) {
        perror("pread row 1");
        return 2;
    }
    memcpy(&cached, blk, sizeof(cached));
    printf("cached_hb=%u ", (unsigned) cetrafs_le64(cached.hb_seq));

    /* The peer beats: its row is written to the device's backing store,
     * past this host's cached copy. */
    ifd = open(argv[2], O_RDWR);
    if (ifd < 0 || pread(ifd, blk, sizeof(blk), off) != (ssize_t) sizeof(blk)) {
        perror("open/read image row 1");
        return 2;
    }
    memcpy(&peer, blk, sizeof(peer));
    peer.hb_seq = cetrafs_cpu_to_le64(cetrafs_le64(peer.hb_seq) + 1);
    cetrafs_node_row_stamp(&peer);
    memcpy(blk, &peer, sizeof(peer));
    if (pwrite(ifd, blk, sizeof(blk), off) != (ssize_t) sizeof(blk)) {
        perror("pwrite image row 1");
        return 2;
    }
    close(ifd);

    printf("watch_beat=%d\n", cetrafs_repair_node_beat(fd, &sb, 0));
    close(fd);
    return 0;
}
