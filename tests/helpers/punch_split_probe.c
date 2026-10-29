// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * punch_split_probe.c -- test-only helper: punch PART of a preallocated
 * range and read back the part that survived.
 *
 * fallocate(KEEP_SIZE) hands a file real blocks it has never written.
 * They read as zeros only because the extent is flagged uninitialized;
 * the blocks themselves still hold whatever their previous owner left.
 * Punching part of such an extent TRIMS or SPLITS it, and the surviving
 * pieces must keep that flag -- otherwise blocks that were never
 * written start serving a deleted file's contents.
 *
 * The donor file exists to make that recognisable: it is written, then
 * deleted, so the allocator hands its blocks to the victim's
 * preallocation and any leak reads as "DONOR-block-N" instead of zeros.
 *
 * The offsets mirror what tests/kernel/churn_oracle.sh found:
 * fallocate [185,+5) then punch [168,+20) removes 185-187 and leaves
 * 188-189.
 *
 * Usage: punch_split_probe <dir>   (prints one line per checked block)
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/falloc.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#define BS 4096
static unsigned char b[BS];
static int nz(void){for(int i=0;i<BS;i++) if(b[i]) return 1; return 0;}
int main(int argc,char**argv){
    char p1[512],p2[512];
    snprintf(p1,sizeof(p1),"%s/victim",argv[1]); snprintf(p2,sizeof(p2),"%s/donor",argv[1]);
    /* donor leaves a recognisable pattern in blocks that get recycled */
    int fd=open(p2,O_RDWR|O_CREAT|O_TRUNC,0644);
    for(int i=0;i<400;i++){memset(b,0,BS);snprintf((char*)b,BS,"DONOR-block-%d",i);pwrite(fd,b,BS,(off_t)i*BS);}
    fsync(fd);close(fd);sync();unlink(p2);sync();
    /* victim: sparse, then preallocate a range, then punch PART of it */
    fd=open(p1,O_RDWR|O_CREAT|O_TRUNC,0644);
    ftruncate(fd,(off_t)214*BS);
    if(fallocate(fd,FALLOC_FL_KEEP_SIZE,(off_t)185*BS,(off_t)5*BS)){perror("fallocate");return 2;}
    if(fallocate(fd,FALLOC_FL_PUNCH_HOLE|FALLOC_FL_KEEP_SIZE,(off_t)168*BS,(off_t)20*BS)){perror("punch");return 2;}
    fsync(fd);close(fd);sync();
    int d=open("/proc/sys/vm/drop_caches",O_WRONLY); if(d>=0){ if(write(d,"3",1)!=1){} close(d);}
    fd=open(p1,O_RDONLY);
    int bad=0;
    for(int blk=188;blk<=189;blk++){memset(b,0,BS);pread(fd,b,BS,(off_t)blk*BS);
        printf("  block %d: %s\n", blk, nz()? (char*)b : "zeros");
        if(nz()) bad++;}
    close(fd); return bad?1:0;
}
