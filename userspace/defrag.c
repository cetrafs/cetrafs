// SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary
/* defrag.cetra -- trigger cetrafs's per-file online defragmentation
 * (CETRAFS_IOC_DEFRAG) and report what it did.
 *
 * Opens the file for WRITING on purpose: the write-open claims the
 * cross-node whole-file exclusive lock, which is exactly what makes the
 * kernel-side relocation safe while the cluster is live -- a file
 * another node currently holds open for write is correctly refused
 * (-ETXTBSY) at open() here, same as any other write-open.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "cetrafs.h"

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr,
                "Usage: %s <file-on-a-cetrafs-mount>\n"
                "  Relocates a regular file into one contiguous run, online.\n"
                "  Opens O_RDWR: the write-open claims the whole-file exclusive\n"
                "  lock that makes the move safe, so a file another node holds\n"
                "  open for write is refused. Sparse files (interior holes) are\n"
                "  declined -- they cannot be relocated block-for-block.\n"
                "  Exit: 0 done, 1 failed, 2 usage.\n",
                argv[0]);
        return 2;
    }

    int fd = open(argv[1], O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ETXTBSY)
            fprintf(stderr, "%s: held open for write by another node -- its whole-file lock is exclusive\n", argv[1]);
        else
            fprintf(stderr, "open(%s): %s\n", argv[1], strerror(errno));
        return 1;
    }

    struct cetrafs_defrag_stats st;
    memset(&st, 0, sizeof(st));

    if (ioctl(fd, CETRAFS_IOC_DEFRAG, &st) != 0) {
        switch (errno) {
        case EOPNOTSUPP:
            /* The kernel returns this both for a sparse file (interior
             * holes, which cannot be moved block-for-block) and for a
             * mount with defragmentation turned off -- it does not tell
             * them apart, so neither do we. */
            fprintf(stderr,
                    "%s: defragmentation not supported here -- the file is sparse (has interior\n"
                    "       holes), or defrag is disabled on this mount "
                    "(/proc/fs/cetrafs/<dev>/controls).\n",
                    argv[1]);
            break;
        case EBADF:
            fprintf(stderr, "%s: not opened for write (the write-open is the exclusivity)\n", argv[1]);
            break;
        case ENOTTY:
            fprintf(stderr, "%s: not on a cetrafs mount (or the module predates the defrag ioctl)\n", argv[1]);
            break;
        default:
            fprintf(stderr, "defrag(%s): %s\n", argv[1], strerror(errno));
        }
        close(fd);
        return 1;
    }
    close(fd);

    printf("defrag %s: extents %" PRIu64 " -> %" PRIu64 " (%" PRIu64 " blocks moved)\n", argv[1],
           (uint64_t) st.extents_before, (uint64_t) st.extents_after, (uint64_t) st.blocks_moved);
    return 0;
}
