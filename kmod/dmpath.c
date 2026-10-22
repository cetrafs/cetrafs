// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * dmpath.c -- find the devices underneath a device-mapper node.
 *
 * WHY THIS EXISTS. cetrafs's cross-node exclusion is one atomic SCSI
 * COMPARE AND WRITE per claim (caw.c), issued in-kernel with
 * scsi_execute_cmd(), which needs a struct scsi_device. A dm node has
 * none: a dm device is not a SCSI device, and dm-multipath remaps BIOs
 * -- it has no representation for a passthrough CDB at all. (Userspace
 * `sg_compare_and_write /dev/mapper/mpathX` works only because SG_IO is
 * an ioctl, which dm forwards to a path via .prepare_ioctl; there is no
 * in-kernel caller for that machinery, and a module cannot fabricate the
 * __user pointer SG_IO requires now that set_fs() is gone.)
 *
 * So on multipath -- mandatory in the production deployments this
 * filesystem targets -- cetrafs saw class=none and fell back to the
 * single-mounter gate, i.e. no clustering at all, even though the LUN
 * and dm both handle CAW perfectly (verified end to end: a CAW through a
 * dm node succeeds, and a deliberate miscompare returns MISCOMPARE).
 *
 * The fix is to send that one command to a SCSI path underneath while
 * every ordinary read and write keeps going through dm, so multipath
 * failover still covers the data path. This file answers only the
 * narrow question "which devices are under this dm node?"; caw.c decides
 * which of them is usable (see its identity guard -- a path whose LBA
 * space is not identical to the dm node's would put CAW on the wrong
 * blocks).
 *
 * HOW. dm's own table-walk helpers (dm_get_live_table, dm_table_get_
 * target) are not exported to modules, so the table cannot be read
 * directly. What IS available is what dm publishes for exactly this
 * purpose: /sys/block/<dm>/slaves/, the holder/slave links the block
 * layer maintains (bd_link_disk_holder). Each entry's own "dev"
 * attribute gives major:minor, so resolution never depends on /dev
 * naming or on udev having run.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/string.h>

#include "kmod.h"

/* One directory level of /sys/block/<dm>/slaves/ collected by name. */
struct cetrafs_slave_dir {
    struct dir_context ctx;
    char names[CETRAFS_DM_MAX_SLAVES][DISK_NAME_LEN];
    unsigned int n;
    bool truncated;
};

static bool cetrafs_slave_actor(struct dir_context *ctx, const char *name, int namlen, loff_t off, u64 ino,
                                unsigned int dtype)
{
    struct cetrafs_slave_dir *d = container_of(ctx, struct cetrafs_slave_dir, ctx);

    (void) off;
    (void) ino;
    (void) dtype;

    if (namlen == 1 && name[0] == '.')
        return true;
    if (namlen == 2 && name[0] == '.' && name[1] == '.')
        return true;
    if (namlen <= 0 || namlen >= DISK_NAME_LEN)
        return true; /* not a device name we can use */
    if (d->n >= ARRAY_SIZE(d->names)) {
        d->truncated = true;
        return false; /* stop iterating */
    }

    memcpy(d->names[d->n], name, namlen);
    d->names[d->n][namlen] = '\0';
    d->n++;
    return true;
}

/* Read a sysfs "dev" attribute ("8:0\n") into a dev_t. */
static int cetrafs_sysfs_devt(const char *path, dev_t *out)
{
    char buf[32];
    struct file *f;
    loff_t pos = 0;
    ssize_t n;
    unsigned int maj, min;

    f = filp_open(path, O_RDONLY, 0);
    if (IS_ERR(f))
        return PTR_ERR(f);

    n = kernel_read(f, buf, sizeof(buf) - 1, &pos);
    filp_close(f, NULL);
    if (n <= 0)
        return -EIO;

    buf[n] = '\0';
    if (sscanf(buf, "%u:%u", &maj, &min) != 2)
        return -EINVAL;

    *out = MKDEV(maj, min);
    return 0;
}

static int cetrafs_dm_collect(const char *disk_name, dev_t *out, unsigned int max, unsigned int *n, int depth);

/* Does /sys/block/<name>/slaves/ hold anything? If so this device is
 * itself stacked (dm on dm, e.g. a partition or a mirror over the
 * multipath map) and is worth descending into. */
static bool cetrafs_dm_has_slaves(const char *disk_name)
{
    struct cetrafs_slave_dir d = {.ctx.actor = cetrafs_slave_actor};
    char path[96];
    struct file *f;

    if (snprintf(path, sizeof(path), "/sys/block/%s/slaves", disk_name) >= (int) sizeof(path))
        return false;
    f = filp_open(path, O_RDONLY | O_DIRECTORY, 0);
    if (IS_ERR(f))
        return false;
    iterate_dir(f, &d.ctx);
    filp_close(f, NULL);
    return d.n > 0;
}

/*
 * Collect the dev_t of every device under 'disk_name', depth-first.
 * Stacked nodes contribute both themselves and their own slaves: caw.c
 * filters by "has a scsi_device parent" and by its identity guard, so
 * handing it a superset is safe and keeps this side dumb.
 */
static int cetrafs_dm_collect(const char *disk_name, dev_t *out, unsigned int max, unsigned int *n, int depth)
{
    struct cetrafs_slave_dir d = {.ctx.actor = cetrafs_slave_actor};
    char path[96];
    struct file *f;
    unsigned int i;
    int ret;

    if (depth > CETRAFS_DM_MAX_DEPTH || *n >= max)
        return 0;

    if (snprintf(path, sizeof(path), "/sys/block/%s/slaves", disk_name) >= (int) sizeof(path))
        return -ENAMETOOLONG;

    f = filp_open(path, O_RDONLY | O_DIRECTORY, 0);
    if (IS_ERR(f))
        return PTR_ERR(f); /* not a stacked device: nothing under it */

    ret = iterate_dir(f, &d.ctx);
    filp_close(f, NULL);
    if (ret)
        return ret;
    if (d.truncated)
        pr_warn("dm path: %s has more than %u slaves; considering the first %u\n", disk_name,
                (unsigned int) ARRAY_SIZE(d.names), d.n);

    for (i = 0; i < d.n && *n < max; i++) {
        dev_t dev;

        if (snprintf(path, sizeof(path), "/sys/block/%s/slaves/%s/dev", disk_name, d.names[i]) >= (int) sizeof(path))
            continue;
        if (cetrafs_sysfs_devt(path, &dev) == 0)
            out[(*n)++] = dev;

        if (cetrafs_dm_has_slaves(d.names[i]))
            cetrafs_dm_collect(d.names[i], out, max, n, depth + 1);
    }
    return 0;
}

/*
 * Fill 'out' with the dev_t of the devices underneath 'bdev', and return
 * how many were found (0 if it is not a stacked device at all).
 */
int cetrafs_dm_underlying(struct block_device *bdev, dev_t *out, unsigned int max, unsigned int *out_n)
{
    *out_n = 0;

    if (!bdev || !bdev->bd_disk || !out || !max)
        return -EINVAL;

    return cetrafs_dm_collect(bdev->bd_disk->disk_name, out, max, out_n, 0);
}

/* ---- resolving a usable SCSI path ------------------------------------
 *
 * Everything below answers one question for caw.c: "give me a
 * scsi_device I may send this volume's COMPARE AND WRITE to". It is
 * deliberately self-contained -- caw.c's only change is to call
 * cetrafs_dmpath_sdev() when a bdev has no SCSI parent of its own.
 */

#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/unaligned.h>

#include <scsi/scsi_common.h>
#include <scsi/scsi_device.h>
#include <scsi/scsi_proto.h>

/* One resolved path per mounted stacked device. Four is well past the
 * number of cetrafs volumes a node is expected to mount at once; a fifth
 * simply re-resolves on every call rather than failing. */
#define CETRAFS_DM_CACHE_SLOTS 4

struct cetrafs_dmpath_entry {
    dev_t dm_dev;              /* nonzero: this slot belongs to that stacked device */
    dev_t path_dev;
    dev_t avoid;               /* a path that just failed a command; skipped when re-resolving */
    struct file *file;         /* the path, held open NON-exclusively */
    struct scsi_device *sdev;  /* reference held; NULL = needs (re)resolution */
    char name[DISK_NAME_LEN];
};

static struct cetrafs_dmpath_entry cetrafs_dmpath_cache[CETRAFS_DM_CACHE_SLOTS];
static DEFINE_MUTEX(cetrafs_dmpath_mutex);

/* One SCSI READ(16), used only by the identity guard below. */
/* Same generous ceiling caw.c uses: one small synchronous command. */
#define CETRAFS_DMPATH_TIMEOUT_JIFFIES (10 * HZ)

static int cetrafs_dmpath_read(struct scsi_device *sdev, u64 lba, unsigned int nblocks, void *buf, unsigned int lbs)
{
    unsigned char cdb[16] = {0};
    struct scsi_sense_hdr sshdr;
    struct scsi_exec_args args;
    u8 *sense;
    int ret;

    sense = kzalloc(SCSI_SENSE_BUFFERSIZE, GFP_KERNEL);
    if (!sense)
        return -ENOMEM;

    cdb[0] = 0x88; /* READ(16) */
    put_unaligned_be64(lba, &cdb[2]);
    put_unaligned_be32(nblocks, &cdb[10]);

    memset(&args, 0, sizeof(args));
    args.sense = sense;
    args.sense_len = SCSI_SENSE_BUFFERSIZE;
    args.sshdr = &sshdr;

    ret = scsi_execute_cmd(sdev, cdb, REQ_OP_DRV_IN, buf, (size_t) nblocks * lbs, CETRAFS_DMPATH_TIMEOUT_JIFFIES, 0,
                           &args);
    kfree(sense);
    return ret ? -EIO : 0;
}

/*
 * THE SAFETY GUARD. A path is only usable if its LBA space is IDENTICAL
 * to the stacked device's -- same LUN, same offset. A multipath map is
 * exactly that, but a partition or a linear map with an offset is not,
 * and sending COMPARE AND WRITE down one of those would read-and-write
 * the wrong blocks: silent, unbounded corruption, and nothing downstream
 * would ever detect it (the CAW would succeed, on somebody else's data).
 *
 * Proof, in two parts. The sizes must match, and -- because a size match
 * alone would also hold for a different LUN of the same model -- the
 * first filesystem block read through the PATH (by passthrough, so it is
 * the device's own bytes, not a cache) must be byte-identical to the one
 * read through the stacked device, AND must carry the cetrafs magic. The
 * magic requirement is what stops an all-zero block comparing equal to
 * an all-zero block on an unrelated device; the superblock is the right
 * subject precisely because it is stable and non-trivial (magic, UUID,
 * geometry), unlike an arbitrary block.
 *
 * Reading the superblock also proves the path answers passthrough
 * commands at all, which is the other thing we need to know before
 * trusting it with the cluster's mutual exclusion.
 */
static bool cetrafs_dmpath_identical(struct block_device *dm_bdev, struct scsi_device *sdev, const char *pname)
{
    unsigned int lbs = bdev_logical_block_size(dm_bdev);
    unsigned int nblocks;
    struct buffer_head *bh;
    void *buf;
    bool ok = false;

    if (!lbs || lbs > CETRAFS_BLOCK_SIZE || CETRAFS_BLOCK_SIZE % lbs)
        return false;
    nblocks = CETRAFS_BLOCK_SIZE / lbs;

    buf = kzalloc(CETRAFS_BLOCK_SIZE, GFP_KERNEL);
    if (!buf)
        return false;

    if (cetrafs_dmpath_read(sdev, 0, nblocks, buf, lbs)) {
        pr_warn("dm path: %s does not answer a passthrough READ -- not usable for CAW\n", pname);
        goto out;
    }

    if (cetrafs_le32(((const cetrafs_superblock_t *) buf)->magic) != CETRAFS_MAGIC) {
        pr_warn("dm path: %s has no cetrafs superblock at LBA 0 -- refusing to send CAW to it\n", pname);
        goto out;
    }

    bh = __bread_gfp(dm_bdev, 0, CETRAFS_BLOCK_SIZE, GFP_KERNEL);
    if (!bh)
        goto out;
    ok = memcmp(bh->b_data, buf, CETRAFS_BLOCK_SIZE) == 0;
    brelse(bh);

    if (!ok)
        pr_warn("dm path: %s block 0 differs from the mapped device's -- the mapping is not 1:1 "
                "(a partition or an offset?), refusing to send CAW to it\n",
                pname);
out:
    kfree(buf);
    return ok;
}

/* Release the held references, keeping the slot (and its 'avoid'
 * memory) associated with its stacked device. */
static void cetrafs_dmpath_drop_refs(struct cetrafs_dmpath_entry *e)
{
    if (e->sdev)
        scsi_device_put(e->sdev);
    if (e->file)
        fput(e->file);
    e->sdev = NULL;
    e->file = NULL;
    e->path_dev = 0;
    e->name[0] = '\0';
}

/* Try one candidate: open it non-exclusively (dm holds its paths
 * EXCLUSIVELY, so an exclusive open here returns -EBUSY), require a SCSI
 * parent, then put it through the identity guard. */
static int cetrafs_dmpath_try(struct block_device *dm_bdev, dev_t path_dev, struct cetrafs_dmpath_entry *e)
{
    struct block_device *pbdev;
    struct scsi_device *sdev;
    struct file *file;

    file = bdev_file_open_by_dev(path_dev, BLK_OPEN_READ, NULL, NULL);
    if (IS_ERR(file))
        return PTR_ERR(file);

    pbdev = file_bdev(file);
    if (!pbdev || bdev_nr_sectors(pbdev) != bdev_nr_sectors(dm_bdev)) {
        fput(file);
        return -ENXIO; /* different size: not a 1:1 map of this device */
    }

    sdev = cetrafs_caw_get_sdev(pbdev);
    if (!sdev) {
        fput(file);
        return -ENXIO; /* not a SCSI device (another dm layer, loop, ...) */
    }

    if (!cetrafs_dmpath_identical(dm_bdev, sdev, pbdev->bd_disk->disk_name)) {
        scsi_device_put(sdev);
        fput(file);
        return -EXDEV;
    }

    e->dm_dev = dm_bdev->bd_dev;
    e->path_dev = path_dev;
    e->file = file;
    e->sdev = sdev;
    strscpy(e->name, pbdev->bd_disk->disk_name, sizeof(e->name));
    return 0;
}

/*
 * Pick a usable path, preferring one that is not 'avoid' -- the path
 * that just failed a command. The second pass DOES reconsider it: on a
 * single-path map it is the only candidate, and a path that failed once
 * may well be healthy again. Retrying a still-broken path simply fails
 * the command again, which is no worse than having no path at all.
 */
static int cetrafs_dmpath_resolve(struct block_device *bdev, dev_t avoid, struct cetrafs_dmpath_entry *e)
{
    dev_t devs[CETRAFS_DM_MAX_SLAVES];
    unsigned int n = 0, i, pass;
    int ret;

    ret = cetrafs_dm_underlying(bdev, devs, ARRAY_SIZE(devs), &n);
    if (ret || !n)
        return ret ? ret : -ENODEV;

    for (pass = 0; pass < (avoid ? 2u : 1u); pass++)
    for (i = 0; i < n; i++) {
        if (pass == 0 && avoid && devs[i] == avoid)
            continue;
        if (pass == 1 && devs[i] != avoid)
            continue; /* pass 0 already tried these */
        if (cetrafs_dmpath_try(bdev, devs[i], e) == 0) {
            pr_info("dm path: %s -> sending COMPARE AND WRITE via %s (data I/O stays on the mapped "
                    "device, so multipath failover still covers it)\n",
                    bdev->bd_disk->disk_name, e->name);
            return 0;
        }
    }
    return -ENODEV;
}

/*
 * The scsi_device to send 'bdev's passthrough commands to, when 'bdev'
 * itself is not SCSI (a dm node). Returns a REFERENCED sdev the caller
 * must scsi_device_put(), or NULL.
 *
 * Cached: a sysfs walk plus an open and a READ per CAW would be absurd
 * on the cluster hot path. A cached path is revalidated with
 * scsi_device_online(), which is a field test and costs nothing -- so a
 * path that goes offline (cable, controller, fabric) is dropped and the
 * next call re-walks the slaves and picks another. A path that stays
 * "online" while failing every command -- an ALUA transition, a flaky
 * link -- is handled by cetrafs_dmpath_failed() below, which caw.c calls
 * on a transport error so the rotation is driven by the failure itself.
 */
struct scsi_device *cetrafs_dmpath_sdev(struct block_device *bdev)
{
    struct cetrafs_dmpath_entry *slot = NULL, *free_slot = NULL, tmp = {0};
    struct scsi_device *sdev = NULL;
    dev_t avoid = 0;
    unsigned int i;

    if (!bdev || !bdev->bd_disk)
        return NULL;

    mutex_lock(&cetrafs_dmpath_mutex);

    for (i = 0; i < ARRAY_SIZE(cetrafs_dmpath_cache); i++) {
        struct cetrafs_dmpath_entry *e = &cetrafs_dmpath_cache[i];

        if (!e->dm_dev) {
            if (!free_slot)
                free_slot = e;
            continue;
        }
        if (e->dm_dev == bdev->bd_dev) {
            slot = e;
            break;
        }
    }

    if (slot && slot->sdev) {
        /* Cheap liveness: a field test, no I/O. Catches the path the
         * SCSI layer has given up on; a path that fails commands while
         * still reading "online" is caught instead by
         * cetrafs_dmpath_failed(), driven by the error itself. */
        if (scsi_device_online(slot->sdev)) {
            if (scsi_device_get(slot->sdev) == 0)
                sdev = slot->sdev;
            goto out;
        }
        pr_warn("dm path: %s went offline -- re-resolving a path for CAW\n", slot->name);
        slot->avoid = slot->path_dev;
        cetrafs_dmpath_drop_refs(slot);
    }

    if (slot)
        avoid = slot->avoid;

    if (cetrafs_dmpath_resolve(bdev, avoid, &tmp) != 0)
        goto out;

    if (!slot)
        slot = free_slot;
    if (!slot) {
        /* No slot free: use this resolution once and release it, rather
         * than refuse CAW entirely. */
        if (scsi_device_get(tmp.sdev) == 0)
            sdev = tmp.sdev;
        cetrafs_dmpath_drop_refs(&tmp);
        goto out;
    }

    tmp.avoid = avoid;
    *slot = tmp;
    if (scsi_device_get(slot->sdev) == 0)
        sdev = slot->sdev;

out:
    mutex_unlock(&cetrafs_dmpath_mutex);
    return sdev;
}

/*
 * caw.c reports that 'sdev' just failed a command with a TRANSPORT error
 * (never a MISCOMPARE, which is a legitimate lost race). Evict it so the
 * next resolution picks a different path, and remember which one failed.
 *
 * This is what makes a path failure a hiccup rather than an outage. The
 * scsi_device_online() test above only fires once the SCSI layer has
 * given up on a path, which can take tens of seconds (dev_loss_tmo /
 * fast_io_fail_tmo) -- and cetrafs_node_renew_heartbeat() is itself a
 * compare-and-swap, so a CAW path that stays broken for longer than the
 * staleness window gets this node declared dead by its peers, reclaimed
 * and self-fenced. A single path failure must not take a node out when
 * multipath has another path sitting right there, so the error itself
 * drives the rotation rather than the SCSI layer's eventual verdict.
 */
void cetrafs_dmpath_failed(struct block_device *bdev, struct scsi_device *sdev)
{
    unsigned int i;

    if (!bdev || !sdev)
        return;

    mutex_lock(&cetrafs_dmpath_mutex);
    for (i = 0; i < ARRAY_SIZE(cetrafs_dmpath_cache); i++) {
        struct cetrafs_dmpath_entry *e = &cetrafs_dmpath_cache[i];

        if (e->dm_dev != bdev->bd_dev || e->sdev != sdev)
            continue;
        pr_warn("dm path: %s failed a COMPARE AND WRITE -- dropping it and trying another path\n", e->name);
        e->avoid = e->path_dev;
        cetrafs_dmpath_drop_refs(e);
        break;
    }
    mutex_unlock(&cetrafs_dmpath_mutex);
}

/* Release anything cached for 'bdev' -- called at unmount so a departed
 * volume stops holding its path device open. */
void cetrafs_dmpath_forget(struct block_device *bdev)
{
    unsigned int i;

    if (!bdev)
        return;

    mutex_lock(&cetrafs_dmpath_mutex);
    for (i = 0; i < ARRAY_SIZE(cetrafs_dmpath_cache); i++) {
        if (cetrafs_dmpath_cache[i].dm_dev == bdev->bd_dev) {
            cetrafs_dmpath_drop_refs(&cetrafs_dmpath_cache[i]);
            memset(&cetrafs_dmpath_cache[i], 0, sizeof(cetrafs_dmpath_cache[i]));
        }
    }
    mutex_unlock(&cetrafs_dmpath_mutex);
}
