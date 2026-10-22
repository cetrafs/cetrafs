// SPDX-License-Identifier: GPL-2.0-or-later
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/debugfs.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/module.h>

#include "kmod.h"

/* The Makefile stamps this from `git describe` (printed at load, exposed
 * as MODULE_VERSION). Fall back if the module was built without our
 * Makefile, so the symbol always resolves. */
#ifndef CETRAFS_BUILD_VERSION
#define CETRAFS_BUILD_VERSION "unknown"
#endif

/* Automatic background defragmentation (defrag.c): on by
 * default -- the target workload (long-lived VM images) is exactly the
 * one that fragments over months with nobody watching. auto_defrag=0
 * turns the janitor off entirely (the explicit defrag.cetra ioctl keeps
 * working); auto_defrag_extents is the last-writer-close extent count
 * that queues a file for background relocation. */
bool cetrafs_auto_defrag = true;
module_param_named(auto_defrag, cetrafs_auto_defrag, bool, 0644);
MODULE_PARM_DESC(auto_defrag, "automatically defragment files in the background (default 1)");

/* A file qualifies for background defrag only when BOTH hold: its
 * fragmentation index (cetrafs_frag_index_pct: extents as a % of the
 * minimum possible for its size) is >= auto_defrag_min_pct, AND it has
 * at least auto_defrag_min_extents extents. The index gate is the real
 * one -- it never flags a contiguous file no matter how large (a
 * contiguous file scores 100) -- while the absolute floor just avoids
 * churning tiny files whose index looks high but whose gain is a handful
 * of blocks (e.g. a 2-block file in 2 extents scores 200 but isn't worth
 * moving). */
unsigned int cetrafs_auto_defrag_min_pct = 200;
module_param_named(auto_defrag_min_pct, cetrafs_auto_defrag_min_pct, uint, 0644);
MODULE_PARM_DESC(auto_defrag_min_pct,
                 "fragmentation index %% (100 = contiguous) at/above which a file auto-defrags (default 200)");

unsigned int cetrafs_auto_defrag_min_extents = 4;
module_param_named(auto_defrag_min_extents, cetrafs_auto_defrag_min_extents, uint, 0644);
MODULE_PARM_DESC(
    auto_defrag_min_extents,
    "absolute minimum extent count below which a file never auto-defrags, regardless of index (default 4)");

static struct file_system_type cetrafs_file_system_type = {
    .owner = THIS_MODULE,
    .name = CETRAFS_NAME,
    .init_fs_context = cetrafs_init_fs_context,
    .kill_sb = cetrafs_kill_sb,
    .fs_flags = FS_REQUIRES_DEV,
    .next = NULL,
};

static int __init cetrafs_init(void)
{
    const char *muuid = get_stable_machine_uuid();
    int ret;

    fs_debug(info, "========================= IN %s UUID %s", __FUNCTION__, muuid);

    ret = cetrafs_init_inode_cache();
    if (ret) {
        pr_err("Failed to create inode cache\n");
        return ret;
    }

    ret = cetrafs_proc_module_init();
    if (ret) {
        pr_err("Failed to create /proc/fs/cetrafs\n");
        goto err_inode;
    }

    ret = register_filesystem(&cetrafs_file_system_type);
    if (ret) {
        pr_err("Failed to register file system\n");
        goto err_proc;
    }

    /* Opt-in read-only ATS/CAW capability probe (caw.c) -- a no-op
     * unless the caw_probe=<device> module param is set. */
    cetrafs_caw_probe_at_load();

    pr_info(CETRAFS_NAME " module loaded (build %s)\n", CETRAFS_BUILD_VERSION);
    return 0;

err_proc:
    cetrafs_proc_module_exit();
err_inode:
    /* rcu_barrier() BEFORE kmem_cache_destroy(), the same order
     * cetrafs_exit() uses and the order every filesystem needs: inodes
     * are freed from an RCU callback, so destroying the cache first can
     * tear down memory a pending callback still reaches. This path had
     * them the other way round. It is reached only when registration or
     * procfs init fails, before any inode can have existed, so nothing
     * was pending in practice -- but the next person to add a step
     * above it would inherit a use-after-free, and the two paths
     * disagreeing is a trap in itself. */
    rcu_barrier();
    cetrafs_destroy_inode_cache();
    return ret;
}

static void __exit cetrafs_exit(void)
{
    fs_debug(info, "========================= IN %s", __FUNCTION__);

    int ret = unregister_filesystem(&cetrafs_file_system_type);
    if (ret)
        pr_err("Failed to unregister file system\n");

    cetrafs_proc_module_exit();

    /* The memory guaranteed to be freed only after rcu_barrier() */
    rcu_barrier();

    cetrafs_destroy_inode_cache();

    fs_debug(info, "module unloaded\n");
}

module_init(cetrafs_init);
module_exit(cetrafs_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Massimo Cetra");
MODULE_DESCRIPTION("An alternative to VMFS");
MODULE_VERSION(CETRAFS_BUILD_VERSION); /* git build stamp -- see the Makefile */
/* Publishes the "fs-cetrafs" alias, which is what get_fs_type() asks
 * modprobe for when a mount names a filesystem no registered type
 * matches. Without it, `mount -t cetrafs` on a host that has the module
 * installed but not loaded fails with "unknown filesystem type" -- so
 * every boot needed an explicit load (a modules-load.d entry, an
 * rc.local modprobe) purely to make mounting work, and an operator who
 * forgot got a confusing error rather than a working mount. With it,
 * the first mount loads the module, exactly as for any in-tree
 * filesystem; /etc/fstab entries and a cluster manager's own mount
 * calls then need no special-casing. */
MODULE_ALIAS_FS("cetrafs");
