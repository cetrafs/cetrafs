// SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-cetrafs-Proprietary
/*
 * sb_restamp -- recompute a cetrafs image's superblock checksum in
 * place, after the fuzzer has mutated SB fields.
 *
 * Most blind mutations die at the SB CRC check before any geometry code
 * runs; the interesting attack surface (cetrafs_validate_layout(), every
 * region start used as a read/write base, every count used to size an
 * allocation) is only reachable with a checksum-VALID superblock. This
 * is the fuzzing counterpart of what a real attacker trivially does.
 *
 * Reuses include/cetrafs.h + userspace/crc32c.h so the format knowledge
 * stays in one place (same pattern as tests/helpers/zg_poke.c).
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cetrafs.h"
#include "crc32c.h"

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <image>\n", argv[0]);
        return 2;
    }
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    cetrafs_superblock_t sb;
    if (pread(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb)) {
        perror("pread");
        return 1;
    }
    sb.checksum = 0;
    uint32_t crc = crc32c_struct(&sb, sizeof(sb), offsetof(cetrafs_superblock_t, checksum), sizeof(sb.checksum));
    sb.checksum = htole64((uint64_t) crc);
    if (pwrite(fd, &sb, sizeof(sb), 0) != (ssize_t) sizeof(sb)) {
        perror("pwrite");
        return 1;
    }
    close(fd);
    return 0;
}
