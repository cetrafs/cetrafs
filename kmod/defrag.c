// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * defrag.c -- per-file online defragmentation.
 *
 * The mover is INCREMENTAL: it relocates the file's mapped blocks, in
 * logical order, into contiguous runs -- one when a free run the file's
 * size exists, otherwise as few as fit (struct cetrafs_defrag_dst) --
 * holes staying holes and preallocated extents preallocated, one step at
 * a time, taking inode_lock only for
 * the duration of each step and dropping it in between, so a file that is
 * CONTINUOUSLY OPEN FOR WRITE (the target workload -- a VM disk image
 * open for months) still gets defragmented, with the VM's own writes
 * interleaving freely between steps. An "inode_lock across the whole
 * move" design would leave exactly those always-open files unreachable,
 * which is the whole point of doing it this way.
 *
 * Each step moves at most CETRAFS_DEFRAG_STEP_BLOCKS blocks from the
 * front of the still-unmoved region into their final contiguous
 * position, then rewrites the extent tree to: [already-moved prefix, as
 * one contiguous run] + [not-yet-moved suffix, its ORIGINAL extents]. An
 * extent that reaches past the cap is split at it, its remainder heading
 * the suffix (audit 2026-11-06 M9: whole-extent steps made a 100 GiB
 * extent one lock hold). Entry count: the prefix needs ceil(moved/MASK)
 * run entries and the suffix drops every extent wholly consumed, so the
 * tree grows past the original count by at most one, and only on a step
 * that consumed no whole extent. cetrafs_defrag_commit() builds a fresh
 * tree at whatever depth that needs; if it cannot (a file already at the
 * format's entry ceiling) the commit fails before publishing and the
 * pass stops, leaving the file as the last step left it.
 *
 * The tree is valid and consistent at EVERY step boundary: the suffix
 * still points at its untouched original blocks, the prefix at the new
 * run. An interrupted pass (concurrent unlink/truncate/hole-punch,
 * unmount drain, fence, I/O error, crash) just leaves a
 * partially-defragmented but perfectly correct file -- there is no
 * mid-swap window to recover and no fsck reconciliation needed.
 *
 * Cross-node safety comes from the pass pinning this node's on-disk
 * whole-file exclusive lock (lock.c's cetrafs_lock_defrag_begin()): the
 * file either already had local writers (lock was ours) or the mover
 * claims it exactly as a write-open would, only if the file is idle and
 * fully unlocked. No other NODE can touch the file for the pass's life.
 * LOCAL concurrency is what the per-step inode_lock handles.
 *
 * Triggers (both in lock.c / file.c): the last-writer close reports the
 * final extent count, and -- crucially for always-open files --
 * file.c's extent-append path reports when a growing open file crosses
 * the threshold mid-flight. Either queues the inode (deduped) onto a
 * per-mount ordered workqueue, gated/tuned by the auto_defrag /
 * auto_defrag_extents module params.
 */
#define pr_fmt(fmt) "cetrafs: " fmt

#include <linux/blkdev.h>
#include <linux/buffer_head.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/math64.h>
#include <linux/minmax.h>
#include <linux/slab.h>
#include <linux/sort.h>
#include <linux/string.h>
#include <linux/workqueue.h>

#include <linux/mm.h>

#include <linux/delay.h>

#include "kmod.h"

/* TEST ONLY: make invalidate_inode_pages2_range() "fail" after a step's
 * commit, on demand. The abort that used to sit on that failure freed
 * part of the just-committed destination run (cross-file overlap); the
 * forced-drop that replaced it is only testable if the failure can be
 * produced deterministically. */
/* TEST ONLY: skip the preallocated-extent refusal below, which is the
 * only way to show that the refusal -- and not something further down --
 * is what keeps an uninitialized extent's stale blocks out of the
 * file's data. */
/* TEST ONLY: leave the destination run OFF the live-reservation
 * registry, the way it used to be -- the negative control showing that
 * the registration is what stops the scrub reclaiming a move in
 * progress. */
static bool cetrafs_defrag_skip_resv;
cetrafs_test_param(defrag_skip_resv, cetrafs_defrag_skip_resv, bool, 0644);
MODULE_PARM_DESC(defrag_skip_resv,
                 "TEST ONLY: do not register the defrag destination run (the scrub may reclaim it mid-move)");

/* TEST ONLY: a moved preallocated extent loses its flag -- the stale
 * blocks behind it become the file's data (tests/kernel/defrag_uninit_extent.sh's
 * control). */
static bool cetrafs_defrag_ignore_uninit;
cetrafs_test_param(defrag_ignore_uninit, cetrafs_defrag_ignore_uninit, bool, 0644);
MODULE_PARM_DESC(defrag_ignore_uninit,
                 "TEST ONLY: defrag publishes moved preallocated extents as written (their stale blocks as data)");

/* TEST ONLY: a step does not convert the inode's pending buffered
 * stores first (tests/kernel/defrag_sparse.sh's control). */
static bool cetrafs_defrag_pending_unconverted;
cetrafs_test_param(defrag_pending_unconverted, cetrafs_defrag_pending_unconverted, bool, 0644);
MODULE_PARM_DESC(defrag_pending_unconverted, "TEST ONLY: a defrag step moves blocks with buffered stores still pending");

static bool cetrafs_defrag_fail_invalidate;
cetrafs_test_param(defrag_fail_invalidate, cetrafs_defrag_fail_invalidate, bool, 0644);
MODULE_PARM_DESC(defrag_fail_invalidate,
                 "TEST ONLY: make the post-commit page drop fail, exercising the forced-drop path");

/*
 * Test only: the next tree publish lands, but reports a failure -- the
 * CAS whose timeout could not be settled (its re-read failed, or someone
 * wrote the region meanwhile).
 */
static bool cetrafs_defrag_publish_lost_ack;
cetrafs_test_param(defrag_publish_lost_ack, cetrafs_defrag_publish_lost_ack, bool, 0644);
MODULE_PARM_DESC(defrag_publish_lost_ack, "TEST ONLY: the next defrag tree publish lands but reports -EIO");

/*
 * Test-only: hold inode_lock open between steps for this long.
 *
 * The window the per-step re-check exists for is the gap where this
 * mover deliberately drops inode_lock, and in production it is as
 * short as the mover can make it. Driving a writer into it needs it
 * held open.
 */
static unsigned int cetrafs_defrag_step_delay_ms;
cetrafs_test_param(defrag_step_delay_ms, cetrafs_defrag_step_delay_ms, uint, 0644);
MODULE_PARM_DESC(defrag_step_delay_ms, "TEST ONLY: pause between defrag steps, with inode_lock dropped");

/* TEST ONLY: pause the background pass between being queued and pinning
 * the file. The trigger is a close, and a close's open has just
 * refreshed this node's view of the file; what a peer writes AFTER it
 * is what the pass has to see, and in production that window is the
 * workqueue's latency. tests/kernel/defrag_fresh_leaf.sh. */
static unsigned int cetrafs_auto_defrag_begin_delay_ms;
cetrafs_test_param(auto_defrag_begin_delay_ms, cetrafs_auto_defrag_begin_delay_ms, uint, 0644);
MODULE_PARM_DESC(auto_defrag_begin_delay_ms, "TEST ONLY: pause a queued background defrag before it pins the file");

/* TEST ONLY: pause after the last step, locks dropped, before the pass
 * finishes its bookkeeping. */
static unsigned int cetrafs_defrag_final_stall_ms;
cetrafs_test_param(defrag_final_stall_ms, cetrafs_defrag_final_stall_ms, uint, 0644);
MODULE_PARM_DESC(defrag_final_stall_ms, "TEST ONLY: pause after the last defrag step, with inode_lock dropped");

/* The per-step shape re-check (length + the logical shape) can catch a
 * rewritten prefix too. That makes the prefix walk below unreachable
 * from a test -- and an unreachable check is an unproven one. This knob
 * relaxes the shape half so a suite can make the walk the sole guard and
 * prove it works: with it set and the walk removed, the rewritten bytes
 * are lost and 16 blocks leak. */
static bool cetrafs_defrag_skip_dense_recheck;
cetrafs_test_param(defrag_skip_dense_recheck, cetrafs_defrag_skip_dense_recheck, bool, 0644);
MODULE_PARM_DESC(defrag_skip_dense_recheck,
                 "TEST ONLY: skip the per-step density re-check, leaving the prefix walk alone");

/* Cap on blocks relocated per inode_lock hold. A HARD cap: an extent
 * that reaches past it is split at it, the rest left in place for the
 * next step. Rounding up to the next whole extent made a 100 GiB extent
 * one step, under inode_lock and invalidate_lock, with no interruption
 * point -- every guest write, DIO and fault waited out the whole copy
 * (audit 2026-11-06 M9). Small enough that a VM write rarely waits long
 * for the lock. */
#define CETRAFS_DEFRAG_STEP_BLOCKS 128

/* TEST ONLY: copy one block per round trip, as before audit 2026-11-14
 * M1 -- the control of tests/kernel/defrag_copy_batched.sh. */
/* TEST ONLY: one stall between a step's source read and its writes
 * (tests/kernel/defrag_vs_fence.sh), and that gate's control. */
static unsigned int cetrafs_defrag_copy_stall_ms;
cetrafs_test_param(defrag_copy_stall_ms, cetrafs_defrag_copy_stall_ms, uint, 0644);
static bool cetrafs_defrag_copy_gate_off;
cetrafs_test_param(defrag_copy_gate_off, cetrafs_defrag_copy_gate_off, bool, 0644);

static bool cetrafs_defrag_copy_serial;
cetrafs_test_param(defrag_copy_serial, cetrafs_defrag_copy_serial, bool, 0644);
MODULE_PARM_DESC(defrag_copy_serial, "TEST ONLY: the defrag mover copies one block per round trip");

/* Moves stopped because a peer asked for the file (procfs defrag_yields). */
static atomic64_t cetrafs_defrag_yields = ATOMIC64_INIT(0);
u64 cetrafs_defrag_yield_count(void)
{
    return (u64) atomic64_read(&cetrafs_defrag_yields);
}

/* TEST ONLY: the mover ignores a peer's request to step aside -- the
 * negative control of ctest's defrag-yield. */
static bool cetrafs_defrag_ignore_yield;
cetrafs_test_param(defrag_ignore_yield, cetrafs_defrag_ignore_yield, bool, 0644);
MODULE_PARM_DESC(defrag_ignore_yield, "TEST ONLY: background defrag ignores a peer's request for the file");

/* TEST ONLY: this node's own stop ask (a first local open, a suspend)
 * quiets the file as a peer's does, as before -- the control of
 * tests/kernel/defrag_random_holes.sh round R. */
static bool cetrafs_defrag_local_stop_quiets;
cetrafs_test_param(defrag_local_stop_quiets, cetrafs_defrag_local_stop_quiets, bool, 0644);
MODULE_PARM_DESC(defrag_local_stop_quiets, "TEST ONLY: a local stop ask quiets the janitor as a peer's yield does");

/* The most blocks any one step has moved under the locks since the
 * module loaded -- procfs info's defrag_max_step_blocks, which is what
 * shows the cap holding (tests/kernel/defrag_step_bounded.sh). */
static atomic64_t cetrafs_defrag_max_step = ATOMIC64_INIT(0);
u64 cetrafs_defrag_max_step_blocks(void)
{
    return (u64) atomic64_read(&cetrafs_defrag_max_step);
}

/*
 * The mover mutates the extent tree and frees the blocks it moved off.
 * inode_lock excludes write(2), truncate, punch and fallocate -- but not
 * a page fault, which cannot take it (it holds mmap_lock, and i_rwsem is
 * taken before mmap_lock everywhere else). invalidate_lock is the one
 * the fault path can take, and cetrafs_page_mkwrite()/cetrafs_write_begin()
 * now do: without it here a store through a mapping appends to the tree
 * this is rebuilding, or keeps buffers on blocks this is about to free.
 *
 * Always as a pair, so the ten exits below cannot drop one and keep the
 * other.
 */
static void cetrafs_defrag_inode_lock(struct inode *inode)
{
    inode_lock(inode);
    filemap_invalidate_lock(inode->i_mapping);
}

/*
 * The same pair, for a step that FREES blocks: the mover frees the old
 * physical blocks once the new run is committed, and O_DIRECT bypasses
 * the page cache -- so an already-submitted DIO is aimed straight at
 * those blocks and inode_lock does not exclude it. Drained here, BEFORE
 * invalidate_lock: an O_DIRECT write's completion takes that lock to
 * convert what it wrote (cetrafs_dio_end_io()), so waiting for it while
 * holding the lock deadlocks. inode_lock keeps a new direct write from
 * starting until the pair is dropped.
 *
 * Only where blocks are freed: draining stops a writer's whole queue,
 * and the analysis pass that usually ends in a decline has no reason to.
 */
static void cetrafs_defrag_inode_lock_drained(struct inode *inode)
{
    inode_lock(inode);
    inode_dio_wait(inode);
    filemap_invalidate_lock(inode->i_mapping);
}

static void cetrafs_defrag_inode_unlock(struct inode *inode)
{
    filemap_invalidate_unlock(inode->i_mapping);
    inode_unlock(inode);
}

/* A file's extent list, read out of the inode (inline) or its one
 * external leaf. 'arr' is caller-allocated (CETRAFS_EXT_BLOCK_MAX_LEAVES
 * entries). */
struct cetrafs_ext_list {
    cetrafs_extent_t *arr;
    u32 count;
    u32 cap; /* entries the caller allocated arr for */
    u16 depth;
    u64 nblocks;     /* total logical blocks covered */
    u64 leaf_lba;    /* external leaf LBA if depth==1, else 0 */
    bool dense;      /* no interior holes: extent i starts where i-1 ended */
    bool has_uninit; /* any extent is preallocated-but-never-written */
    /* Which logical blocks are mapped, as runs: (start, length) pairs
     * in logical order, 'runs' of them in 'rl' (2 * cap entries).
     * Preallocated or written does not enter it -- each step reads the
     * flags afresh and the commit publishes them as they are. The list
     * itself, not a CRC of it: the plan maps rank k to a logical block,
     * so a layout that changed between steps but hashed the same would
     * have had the next step copy blocks to the wrong place (audit
     * 2026-11-15 F-16). */
    u32 runs;
    u64 *rl;
};

/* Cap on how fragmented a file this collapser will take on: every file
 * the tree can hold (4 x 254 x 254). It was 65,536, declining the most
 * fragmented files -- the ones that need it most (audit 2026-11-15
 * A-14) -- because each step rebuilt the whole tree; a step now patches
 * only what it touches (cetrafs_tree_patch()), and what is left per step
 * is reading and sorting the list, O(n log n) in memory. */
#define CETRAFS_DEFRAG_MAX_EXTENTS                                                                                   \
    ((u32) (ARRAY_SIZE(((cetrafs_inode_t *) NULL)->et.idx) * CETRAFS_EXT_BLOCK_MAX_IDX * CETRAFS_EXT_BLOCK_MAX_LEAVES))

/* TEST ONLY: a lower cap, so a suite can have a file declined at will
 * (tests/kernel/defrag_declines.sh). 0: CETRAFS_DEFRAG_MAX_EXTENTS. */
static unsigned int cetrafs_defrag_extent_cap;
cetrafs_test_param(defrag_extent_cap, cetrafs_defrag_extent_cap, uint, 0644);
MODULE_PARM_DESC(defrag_extent_cap, "TEST ONLY: defrag declines a file with more extents than this");

/*
 * The record the move is planned from. Fresh unless this node is the
 * file's local writer: the defrag pin taken on an idle file runs none of
 * the open path's change-stamp check, so a record this node cached
 * before a peer wrote and closed the file would otherwise be the plan --
 * and the commit publishes a whole new tree built from it. Overlaid, so
 * this node's own unpublished shadow still wins.
 */
static int cetrafs_defrag_read_raw(struct super_block *sb, struct inode *inode, cetrafs_inode_t *raw)
{
    if (!cetrafs_lock_held_for_write_locally(inode))
        cetrafs_invalidate_raw_inode(sb, inode->i_ino);
    return cetrafs_read_raw_inode_overlaid(sb, inode, raw); /* torn-read-safe vs a concurrent publish */
}

/* TEST ONLY: leave the extent list in array order, as before P11 -- the
 * control of tests/kernel/defrag_random_holes.sh. */
static bool cetrafs_defrag_extents_unsorted;
cetrafs_test_param(defrag_extents_unsorted, cetrafs_defrag_extents_unsorted, bool, 0644);
MODULE_PARM_DESC(defrag_extents_unsorted, "TEST ONLY: the defragmenter reads the extent array unsorted");

/* Logical order of two extent records, for the sort in read_extents(). */
static int cetrafs_defrag_ext_cmp(const void *a, const void *b)
{
    u32 ea = cetrafs_ee_lblk((const cetrafs_extent_t *) a);
    u32 eb = cetrafs_ee_lblk((const cetrafs_extent_t *) b);

    return (ea > eb) - (ea < eb);
}

static u64 cetrafs_defrag_run_end(const struct cetrafs_ext_list *el, u32 i)
{
    return (u64) cetrafs_ee_lblk(&el->arr[i]) + cetrafs_ee_len(&el->arr[i]);
}

/*
 * The mover counts in RANKS: the k-th mapped block of the file in
 * logical order is the k-th block of the destination run. For a file
 * with no holes rank and logical block are the same number; for a sparse
 * one they are not, and what touches the page cache needs the logical
 * one. The logical block of rank r, and the end (exclusive) of the
 * logical range ranks [.., r) reach.
 */
static u64 cetrafs_defrag_rank_logical(const struct cetrafs_ext_list *el, u64 r)
{
    u64 o = 0;
    u32 e;

    for (e = 0; e < el->count; e++) {
        u64 len = cetrafs_ee_len(&el->arr[e]);

        if (r < o + len)
            return cetrafs_ee_lblk(&el->arr[e]) + (r - o);
        o += len;
    }
    return el->count ? cetrafs_defrag_run_end(el, el->count - 1) : 0;
}

static u64 cetrafs_defrag_rank_logical_end(const struct cetrafs_ext_list *el, u64 r)
{
    return r ? cetrafs_defrag_rank_logical(el, r - 1) + 1 : 0;
}

static int cetrafs_defrag_read_extents(struct inode *inode, const cetrafs_inode_t *raw, struct cetrafs_ext_list *el)
{
    struct super_block *sb = inode->i_sb;
    u32 i;
    u64 expect = 0;

    el->depth = cetrafs_le16(raw->eh.eh_depth);
    el->leaf_lba = 0;

    if (cetrafs_le16(raw->eh.eh_magic) != CETRAFS_EXT_MAGIC)
        return -EIO;

    if (cetrafs_le16(raw->eh.eh_depth) == 0) {
        el->count = min_t(u32, cetrafs_le16(raw->eh.eh_entries), 4);
        memcpy(el->arr, raw->et.leaf, el->count * sizeof(el->arr[0]));
    } else if (cetrafs_le16(raw->eh.eh_depth) == 1) {
        struct buffer_head *bh;
        const cetrafs_extent_hdr_t *hdr;

        el->leaf_lba = cetrafs_ei_child(&raw->et.idx[0]);
        /* Through the tree reader, which reads fresh unless this node
         * is the file's local writer, and checks the address. It was a
         * plain cached read under "defrag pins the file's exclusive write
         * lock, so no peer can be rewriting this leaf: cached is
         * correct" -- true of the move, false of the cache: the pin
         * stops a peer from writing NEXT, not from having written since
         * this node cached the leaf. A peer that appended to it in place
         * and closed left this node a leaf naming fewer extents; defrag
         * rebuilt the file from it and published, and the peer's extents
         * were gone (tests/kernel/defrag_fresh_leaf.sh). Depth 2 already
         * went through cetrafs_tree_flatten(), which reads this way. */
        bh = cetrafs_read_leaf_bh(inode, el->leaf_lba);
        if (!bh)
            return -EIO;
        hdr = (const cetrafs_extent_hdr_t *) bh->b_data;
        el->count = min_t(u32, cetrafs_le16(hdr->eh_entries), CETRAFS_EXT_BLOCK_MAX_LEAVES);
        memcpy(el->arr, bh->b_data + sizeof(*hdr), el->count * sizeof(el->arr[0]));
        brelse(bh);
    } else {
        /* Depth 2 (v2): flatten the whole tree. Beyond the cap it is
         * declined (not failed) -- the file works, it is just left
         * fragmented rather than churned for many minutes. */
        cetrafs_extent_t *flat = NULL;
        u32 n = 0;
        int fret = cetrafs_tree_flatten(inode, raw, &flat, &n);

        if (fret)
            return fret;
        if (n > el->cap) {
            kvfree(flat);
            pr_debug("defrag: ino=%llu has %u extents (> cap %u) -- declined\n", (unsigned long long) inode->i_ino, n,
                     el->cap);
            return -EOPNOTSUPP;
        }
        el->count = n;
        if (n)
            memcpy(el->arr, flat, (size_t) n * sizeof(el->arr[0]));
        kvfree(flat);
    }

    {
        unsigned int c = READ_ONCE(cetrafs_defrag_extent_cap); /* TEST ONLY: see the parameter */

        if (c && el->count > c)
            return -EOPNOTSUPP;
    }

    /* The extent array is UNSORTED (cetrafs_leaf_array_insert() appends,
     * and merges only with the last entry), so a file filled in random
     * order lists its extents in arrival order. The mover reads the array
     * as the file's logical map, and the density test below asks whether
     * it is contiguous -- so put it in logical order first. Without this a
     * 64 MiB random fill (16,384 extents) was declined as "interior holes"
     * forever, and the janitor could never heal it (audit P11). */
    if (el->count > 1 && !READ_ONCE(cetrafs_defrag_extents_unsorted))
        sort(el->arr, el->count, sizeof(el->arr[0]), cetrafs_defrag_ext_cmp, NULL);

    el->dense = true;
    el->has_uninit = false;
    el->runs = 0;
    for (i = 0; i < el->count; i++) {
        /* Defrag copies these blocks and FREES them: an address read off
         * the device is checked before either (rule 19, as the free path
         * and the data path do). */
        int chk = cetrafs_lba_run_check(sb, cetrafs_ee_pblk(&el->arr[i]),
                                        cetrafs_ee_len(&el->arr[i]));

        if (chk == -EAGAIN)
            return -EIO; /* past a layout this node cannot catch up with: not damage */
        if (chk) {
            pr_err_ratelimited("defrag: ino=%llu extent %u is not a data address -- refusing it (fsck)\n",
                               (unsigned long long) inode->i_ino, i);
            cetrafs_sb_corrupt_inode(inode);
            return -EUCLEAN;
        }
        if (cetrafs_ee_lblk(&el->arr[i]) != expect)
            el->dense = false;
        /* The plan maps the k-th mapped block in logical order to the
         * k-th block of the run, which needs the list in that order with
         * nothing overlapping. Sorted above, so only an overlap (damage)
         * or the unsorted test read gets here: decline, as the density
         * test used to. */
        if (i && cetrafs_ee_lblk(&el->arr[i]) < cetrafs_defrag_run_end(el, i - 1))
            return -EOPNOTSUPP;
        /* A run continues while the next extent starts where the last
         * ended, however the extents inside it are cut (a convert splits
         * one). */
        if (!i || cetrafs_ee_lblk(&el->arr[i]) != cetrafs_defrag_run_end(el, i - 1)) {
            el->rl[2 * el->runs] = cetrafs_ee_lblk(&el->arr[i]);
            el->rl[2 * el->runs + 1] = 0;
            el->runs++;
        }
        el->rl[2 * el->runs - 1] += cetrafs_ee_len(&el->arr[i]);
        /* cetrafs_extent_len() MASKS the uninit bit off, so a
         * preallocated extent is indistinguishable from data here
         * unless it is asked about explicitly. See the refusal below
         * for why that mattered. */
        if (cetrafs_ee_uninit(&el->arr[i]))
            el->has_uninit = true;
        expect += cetrafs_ee_len(&el->arr[i]);
    }
    el->nblocks = expect;
    return 0;
}

/*
 * The destination: runs ("segments"), each holding the next ranks of the
 * file in order. One run the size of the whole file used to be required,
 * so a file larger than the largest free run -- any image larger than a
 * Block Group -- was never defragmented (audit 2026-11-15 A-14). A
 * segment is allocated when the one before it is fully committed: as
 * large as what is left of the file, or the largest that fits, down to
 * CETRAFS_DEFRAG_SEG_MIN blocks. A step never crosses a segment.
 */
struct cetrafs_defrag_seg {
    u64 first; /* the rank of its first block */
    u64 base;  /* its first block on the device */
    u64 count;
};

struct cetrafs_defrag_dst {
    struct cetrafs_defrag_seg *seg;
    u32 n, cap;
};

#define CETRAFS_DEFRAG_SEG_MIN 1024u /* 4 MiB: a segment smaller than this is not worth a pass */

/* TEST ONLY: segments no larger than this many blocks, so a loop-sized
 * file spans several (tests/kernel/defrag_segments.sh). 0: no cap. */
static unsigned int cetrafs_defrag_seg_max;
cetrafs_test_param(defrag_seg_max, cetrafs_defrag_seg_max, uint, 0644);
MODULE_PARM_DESC(defrag_seg_max, "TEST ONLY: defrag destination runs of at most this many blocks");

/* TEST ONLY: one run the size of the file or nothing, as before
 * (tests/kernel/defrag_segments.sh's control). */
static bool cetrafs_defrag_one_run;
cetrafs_test_param(defrag_one_run, cetrafs_defrag_one_run, bool, 0644);
MODULE_PARM_DESC(defrag_one_run, "TEST ONLY: defrag needs one free run the size of the file, as before");

static atomic64_t cetrafs_defrag_segments = ATOMIC64_INIT(0);

u64 cetrafs_defrag_segment_count(void)
{
    return (u64) atomic64_read(&cetrafs_defrag_segments);
}

/* The segment holding rank r (r below the last segment's end). */
static const struct cetrafs_defrag_seg *cetrafs_defrag_seg_of(const struct cetrafs_defrag_dst *d, u64 r)
{
    u32 lo = 0, hi = d->n;

    while (hi - lo > 1) {
        u32 mid = lo + (hi - lo) / 2;

        if (d->seg[mid].first <= r)
            lo = mid;
        else
            hi = mid;
    }
    return &d->seg[lo];
}

static u64 cetrafs_defrag_dst_of(const struct cetrafs_defrag_dst *d, u64 r)
{
    const struct cetrafs_defrag_seg *g = cetrafs_defrag_seg_of(d, r);

    return g->base + (r - g->first);
}

static u64 cetrafs_defrag_seg_end(const struct cetrafs_defrag_dst *d, u64 r)
{
    const struct cetrafs_defrag_seg *g = cetrafs_defrag_seg_of(d, r);

    return g->first + g->count;
}

/* Room for one more segment. */
static int cetrafs_defrag_dst_room(struct cetrafs_defrag_dst *d)
{
    if (d->n == d->cap) {
        u32 ncap = d->cap ? d->cap * 2 : 16;
        struct cetrafs_defrag_seg *ns = kvmalloc_array(ncap, sizeof(*ns), GFP_KERNEL);

        if (!ns)
            return -ENOMEM;
        if (d->n)
            memcpy(ns, d->seg, (size_t) d->n * sizeof(*ns));
        kvfree(d->seg);
        d->seg = ns;
        d->cap = ncap;
    }
    return 0;
}

/* TEST ONLY: every pass starts from the file's first block, as before --
 * the control of tests/kernel/defrag_random_holes.sh. */
static bool cetrafs_defrag_restart_from_zero;
cetrafs_test_param(defrag_restart_from_zero, cetrafs_defrag_restart_from_zero, bool, 0644);
MODULE_PARM_DESC(defrag_restart_from_zero, "TEST ONLY: a defrag pass re-moves the runs already in place");

/*
 * The file's leading runs already in place: from rank 0, each maximal
 * physically contiguous run of at least CETRAFS_DEFRAG_SEG_MIN blocks --
 * what a segment of this mover is -- entered into 'd' as a segment where
 * it lies, so the pass starts after them. Returns the first rank not
 * covered ('el' sorted, the caller's read).
 *
 * A pass stopped by a local open is handed back and judged again, and it
 * used to start over from rank 0: it moved the run the stopped pass had
 * just placed to a new place, and with the file opened every second (a
 * monitor, a backup's stat, filefrag) no pass ever got past the first
 * few seconds of the file (tests/kernel/defrag_random_holes.sh). The
 * runs entered here are the file's as they stand: the commit republishes
 * them unchanged (cetrafs_defrag_pieces() maps every rank through 'd'),
 * the prefix check verifies them like any committed rank, and nothing
 * frees them (a block is freed only where its source is not its
 * destination).
 *
 * What is left after them must make a segment of its own. A shorter
 * tail placed after the kept runs is one more short extent, and the
 * pass ends where it began: a 64 MiB run followed by one block elsewhere
 * kept the run, moved the block to another lone block, and stayed at two
 * extents on every pass (tests/kernel/defrag_step_bounded.sh). So kept
 * runs are given back, the last first, until the rest makes a segment --
 * at worst the whole file moves, as it did before.
 */
static int cetrafs_defrag_dst_placed(const struct cetrafs_ext_list *el, u64 nblocks, struct cetrafs_defrag_dst *d,
                                     u64 *out)
{
    u64 rank = 0;
    u32 i = 0;
    int ret;

    *out = 0;
    if (READ_ONCE(cetrafs_defrag_restart_from_zero) || READ_ONCE(cetrafs_defrag_extents_unsorted))
        return 0;
    while (i < el->count) {
        u64 base = cetrafs_extent_phys_from_hilo(el->arr[i].ee_start_hi, el->arr[i].ee_start_lo);
        u64 count = 0;

        /* One run: each extent starting where the one before ended. */
        for (; i < el->count; i++) {
            u64 len = cetrafs_extent_len(el->arr[i].ee_len);

            if (!len || cetrafs_extent_phys_from_hilo(el->arr[i].ee_start_hi, el->arr[i].ee_start_lo) != base + count)
                break;
            count += len;
        }
        if (count < CETRAFS_DEFRAG_SEG_MIN)
            break;
        ret = cetrafs_defrag_dst_room(d);
        if (ret)
            return ret;
        d->seg[d->n].first = rank;
        d->seg[d->n].base = base;
        d->seg[d->n].count = count;
        d->n++;
        rank += count;
    }
    while (d->n && rank < nblocks && nblocks - rank < CETRAFS_DEFRAG_SEG_MIN) {
        d->n--;
        rank -= d->seg[d->n].count;
    }
    *out = rank;
    return 0;
}

/* The next segment, from rank 'first', 'left' ranks still to place. The
 * span is published with the bits (cetrafs_alloc_pick_run_resv()). */
static int cetrafs_defrag_dst_grow(struct super_block *sb, struct cetrafs_defrag_dst *d, u64 first, u64 left,
                                   struct cetrafs_resv_span *span)
{
    u64 want = left, base;
    unsigned int cap = READ_ONCE(cetrafs_defrag_seg_max);
    int ret;

    if (cap && want > cap)
        want = cap;
    ret = cetrafs_defrag_dst_room(d);
    if (ret)
        return ret;
    for (;;) {
        ret = cetrafs_alloc_pick_run_resv(sb, want, &base, span);
        if (!ret)
            break;
        if (ret != -ENOSPC || want <= min_t(u64, CETRAFS_DEFRAG_SEG_MIN, left) || READ_ONCE(cetrafs_defrag_one_run))
            return ret;
        want = max_t(u64, want / 2, min_t(u64, CETRAFS_DEFRAG_SEG_MIN, left));
    }
    d->seg[d->n].first = first;
    d->seg[d->n].base = base;
    d->seg[d->n].count = want;
    d->n++;
    atomic64_inc(&cetrafs_defrag_segments);
    return 0;
}

/*
 * The new run's entries for ranks [from, to): each piece at its own
 * logical block, at its rank's place on the destination, with its own extent's flag -- a
 * hole stays a hole and a preallocated block stays preallocated. Pieces
 * that continue each other logically, physically and in kind are one
 * entry, split at the length cap. The pieces are head[] whole, then the
 * first split_off blocks of 'split' (the extent the step ends inside, as
 * it was before the suffix took its remainder). *lo / *hi: the logical
 * range the emitted pieces span. -EIO: they do not add up to [from, to).
 */
static int cetrafs_defrag_pieces(const cetrafs_extent_t *head, u32 head_count, const cetrafs_extent_t *split,
                                 u32 split_off, u64 from, u64 to, const struct cetrafs_defrag_dst *d,
                                 cetrafs_extent_t *out, u32 *out_n, u32 cap, u64 *lo, u64 *hi)
{
    u64 off = 0, got = 0;
    u32 i, n = *out_n;

    *lo = U64_MAX;
    *hi = 0;
    for (i = 0; i <= head_count && off < to; i++) {
        const cetrafs_extent_t *x = i < head_count ? &head[i] : split;
        u64 len, lg, skip;
        bool un;

        if (!x)
            break;
        len = min_t(u64, i < head_count ? cetrafs_ee_len(x) : split_off, to - off);
        lg = cetrafs_ee_lblk(x);
        un = cetrafs_ee_uninit(x) && !READ_ONCE(cetrafs_defrag_ignore_uninit);
        /* Ranks below 'from' are not this window's. */
        skip = from > off ? min_t(u64, from - off, len) : 0;
        off += skip;
        lg += skip;
        len -= skip;
        if (len && lg < *lo)
            *lo = lg;

        while (len) {
            cetrafs_extent_t *p = n ? &out[n - 1] : NULL;
            u32 plen = p ? cetrafs_ee_len(p) : 0;
            u64 take, phys = cetrafs_defrag_dst_of(d, off);
            u64 seg_left = cetrafs_defrag_seg_end(d, off) - off; /* a piece stays inside its segment */

            if (p && (u64) cetrafs_ee_lblk(p) + plen == lg &&
                cetrafs_ee_pblk(p) + plen == phys &&
                cetrafs_ee_uninit(p) == un && plen < CETRAFS_EXT_LEN_MASK) {
                take = min3(len, (u64) CETRAFS_EXT_LEN_MASK - plen, seg_left);
                cetrafs_ee_set_len(p, plen + (u32) take, un);
            } else {
                if (n >= cap)
                    return -EIO; /* cannot happen: one entry per source piece */
                take = min3(len, (u64) CETRAFS_EXT_LEN_MASK, seg_left);
                memset(&out[n], 0, sizeof(out[n]));
                cetrafs_ee_set_lblk(&out[n], (u32) lg);
                cetrafs_ee_set_len(&out[n], (u32) take, un);
                cetrafs_ee_set_pblk(&out[n], phys);
                n++;
            }
            len -= take;
            lg += take;
            off += take;
            got += take;
            *hi = lg;
        }
    }
    *out_n = n;
    return got == to - from ? 0 : -EIO;
}

/*
 * Persist a layout of: ranks [0, moved) on the destination 'd' (each
 * at its own logical block, see cetrafs_defrag_pieces()), followed by the
 * suffix -- the original extents from rank 'moved' on, already shifted so
 * entry 0 is the first piece at or after it. The step [prev, moved) goes
 * through the tree patch, which writes only what changes; a tree it
 * cannot patch (depth 0/1, one that would fit a leaf, a full root) gets a
 * FRESH tree at whatever depth the result needs -- so a depth-2 file still
 * collapses to depth 0 at the end. Either way the new root is published
 * and only then the old tree's blocks the new one no longer names are
 * freed. Caller holds inode_lock and the defrag pin.
 *
 * Copy-on-write in both cases (rather than editing leaves in place) is
 * what makes it crash-safe: the old tree is intact until the new root is
 * durable, and new and old meta are disjoint where they differ (new
 * allocated before old freed). It also keeps raw.blocks honest across a
 * depth change, which the old in-place path did not (a depth-1->0
 * collapse leaked the leaf from i_blocks).
 */
static int cetrafs_defrag_commit(struct inode *inode,
                                 cetrafs_inode_t *raw,
                                 const struct cetrafs_defrag_dst *d,
                                 u64 prev,
                                 u64 moved,
                                 u64 nblocks,
                                 const cetrafs_extent_t *head,
                                 u32 head_count,
                                 const cetrafs_extent_t *split,
                                 u32 split_off,
                                 const cetrafs_extent_t *suffix,
                                 u32 suffix_count)
{
    struct super_block *sb = inode->i_sb;
    cetrafs_extent_t *out;
    /* Names the OLD tree, freed after the publish. Off the stack: a
     * record is 652 bytes, and this runs under the defrag worker's own
     * frame -- its caller heap-allocates the same type for this reason
     * (audit 2026-11-05, section 3). */
    cetrafs_inode_t *old;
    u32 n = 0, i, cap = head_count + 1 + suffix_count + d->n + 8;
    u64 meta = 0;
    bool verdict_old = false; /* a failed publish proven NOT to have landed */
    int ret;

    out = kvmalloc_array(cap, sizeof(*out), GFP_KERNEL);
    old = kmalloc(sizeof(*old), GFP_KERNEL);
    if (!out || !old) {
        kvfree(out);
        kfree(old);
        return -ENOMEM;
    }
    *old = *raw;

    /* Prefix: ranks [0, moved) on the destination, each at its own
     * logical block and with its own extent's flag -- a hole stays a
     * hole and a preallocated block stays preallocated. Pieces that
     * continue each other logically, physically and in kind are one
     * entry, split at the length cap. The pieces are head[] whole, then
     * the first split_off blocks of 'split' (the extent the step ends
     * inside, as it was before the suffix took its remainder). */
    /*
     * First the step alone, through the tree patch: the step's logical
     * span leaves the tree (it holds exactly the step's ranks) and its
     * pieces on the new run go in, extending the run the steps before
     * built. Only the leaves and interiors that change are written --
     * the rebuild below wrote the whole tree every 128 blocks (audit
     * 2026-11-15 A-14). A tree it cannot patch is rebuilt.
     */
    {
        u64 lo, hi;
        u32 an = 0;

        ret = cetrafs_defrag_pieces(head, head_count, split, split_off, prev, moved, d, out, &an, cap, &lo, &hi);
        if (ret)
            goto out;
        ret = an ? cetrafs_tree_patch(inode, raw, lo, hi, out, an, U32_MAX, nblocks, &meta) : -EAGAIN;
        if (ret && ret != -EAGAIN) {
            *raw = *old;
            goto out;
        }
    }
    if (ret == -EAGAIN) {
        u64 lo, hi;

        ret = cetrafs_defrag_pieces(head, head_count, split, split_off, 0, moved, d, out, &n, cap, &lo, &hi);
        if (ret)
            goto out;
        /* Suffix: original extents for [moved, nblocks), verbatim. */
        for (i = 0; i < suffix_count && n < cap; i++)
            out[n++] = suffix[i];
        ret = cetrafs_tree_build(inode, out, n, raw, &meta);
    }
    if (ret) {
        *raw = *old;
        goto out;
    }
    raw->blocks = cetrafs_cpu_to_le64((nblocks + meta) * (CETRAFS_BLOCK_SIZE / 512));
    {
        u64 fd_seq;

        verdict_old = false;
        cetrafs_inode_fd_pub_lock(inode);
        /*
         * Size and times come from the LIVE inode, read under the
         * publish mutex -- NOT from the record image this move started
         * from. The mover re-reads the extent map every step, so the
         * tree it publishes tracks a concurrent local writer -- but
         * raw->size was frozen at move start, and the final step's
         * publish copied it wholesale over a size the owner had grown
         * meanwhile: fresh tree, stale size, fresh stamp. An 8-core
         * churn run lost the owner's extension to exactly this (ino 76:
         * blocks said 95, size said 76 -- a mixed-vintage record), and
         * it is why "defrag an open file" is legal but was not SAFE.
         * Every local size writer updates i_size under locks this mutex
         * orders with, so this read cannot regress (2026-10-29).
         */
        raw->size = cetrafs_cpu_to_le64((u64) i_size_read(inode));
        raw->atime = cetrafs_cpu_to_le64((u64) inode_get_atime_sec(inode));
        raw->mtime = cetrafs_cpu_to_le64((u64) inode_get_mtime_sec(inode));
        fd_seq = cetrafs_inode_fd_seq(inode);
        ret = cetrafs_write_raw_inode_fd(sb, inode->i_ino, raw, inode);
        if (!ret && cetrafs_defrag_publish_lost_ack) {
            cetrafs_defrag_publish_lost_ack = false;
            ret = -EIO; /* test only, see the knob */
        }
        if (ret) {
            /*
             * A failed publish is not proof that nothing landed: a CAS
             * whose timeout could not be settled returns an error with
             * its outcome unknown. Freeing the new tree on the strength
             * of the error alone leaves a record that may name it
             * reading FREE to the allocator. Ask the record which tree
             * it names -- under this mutex, so a landing is marked
             * published exactly as a clean one is -- and free only what
             * it provably does not name. If it cannot say, free
             * neither: a leak the scrub reclaims, never a shared block.
             */
            cetrafs_inode_t *now = kmalloc(sizeof(*now), GFP_NOFS);
            int vret = -ENOMEM;

            if (now) {
                cetrafs_invalidate_raw_inode(sb, inode->i_ino);
                vret = cetrafs_read_raw_inode(sb, inode->i_ino, now);
            }
            if (!vret && !memcmp(&now->eh, &raw->eh, sizeof(now->eh)) && !memcmp(&now->et, &raw->et, sizeof(now->et))) {
                pr_warn("defrag: ino=%llu publish reported %d but the record names the new tree -- keeping it\n",
                        (unsigned long long) inode->i_ino, ret);
                ret = 0;
            } else if (!vret && !memcmp(&now->eh, &old->eh, sizeof(now->eh)) &&
                       !memcmp(&now->et, &old->et, sizeof(now->et))) {
                verdict_old = true;
            } else {
                pr_err("defrag: ino=%llu publish failed (%d) and the record names neither tree (%d) -- freeing "
                       "neither, nor the copied data; what is unreferenced is a leak the scrub reclaims\n",
                       (unsigned long long) inode->i_ino, ret, vret);
            }
            kfree(now);
        }
        if (!ret)
            cetrafs_inode_fd_published(inode, fd_seq); /* this publish supersedes the overlaid shadow */
        cetrafs_inode_fd_pub_unlock(inode);
    }
    if (ret) {
        if (verdict_old) {
            cetrafs_tree_free_meta_except(inode, raw, old); /* provably unreferenced: undo the new blocks */
            *raw = *old;
            goto out;
        }
        *raw = *old;
        ret = -ENOTRECOVERABLE; /* outcome unknown: the caller must free no destination block */
        goto out;
    }
    cetrafs_tree_free_meta_except(inode, old, raw); /* what the old tree had and the new one does not */

out:
    kvfree(out);
    kfree(old);
    return ret;
}

/*
 * The relocation core, shared by the explicit ioctl and the background
 * worker. Caller must already hold the defrag pin
 * (cetrafs_lock_defrag_begin()). Incremental: see the file header.
 */
int cetrafs_defrag_inode(struct inode *inode, struct cetrafs_defrag_stats *out_stats)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_ext_list el;
    struct cetrafs_defrag_stats stats = {0};
    /*
     * The record lives on the HEAP, like fallocate's pair and for the
     * same reason: cetrafs_inode_t is a 652-byte struct (its on-disk
     * record is 1 KiB), and 652 bytes of kernel stack in a function
     * that then calls into the allocator,
     * the journal and the CAS layer is a lot to spend on one local. A
     * KASAN build puts the frame at 1296 bytes and refuses to compile
     * it, which is how this one surfaced.
     *
     * The macro keeps the body reading as it did -- the same shape
     * cetrafs_fallocate() uses.
     */
    cetrafs_inode_t *rawp;
    struct buffer_head **copy_src, **copy_dst;
    sector_t *copy_lba; /* one step's source blocks, for the batched read (M1) */
    u32 *copy_off;      /* ...and each one's block offset from the step's start */
#define raw (*rawp)
    u64 nblocks, moved = 0, placed;
    struct cetrafs_defrag_dst dst = {0};
    u64 *snapshot_rl = NULL;
    u32 snapshot_runs = 0;
    bool have_dst = false;
    /*
     * The destination run is bitmap-allocated and referenced by NOTHING
     * until each step's commit publishes it -- for the whole move, which
     * for a large file is seconds, not the single get_block() the
     * scrub's leak argument assumes. scrub.c's header states the rule:
     * "anything that leaves a block bitmap-allocated for longer than one
     * get_block() without committing an extent MUST appear there [on the
     * reservation registry]". This run did not, and lock.c's speculative
     * run was the only thing that ever did -- so the background scrub
     * reclaimed a live defrag destination, the allocator handed those
     * blocks to another file, and the commit published them anyway.
     */
    struct cetrafs_resv_span dst_span = {.link = LIST_HEAD_INIT(dst_span.link)};
    int ret;

    el.cap = CETRAFS_DEFRAG_MAX_EXTENTS;
    el.arr = kvmalloc_array(el.cap, sizeof(*el.arr), GFP_KERNEL);
    el.rl = kvmalloc_array(2 * (size_t) el.cap, sizeof(*el.rl), GFP_KERNEL);
    if (!el.arr || !el.rl) {
        kvfree(el.arr);
        kvfree(el.rl);
        return -ENOMEM;
    }
    rawp = kmalloc(sizeof(*rawp), GFP_NOFS);
    /* One step's buffers, source then destination (M1). */
    copy_src = kcalloc(2 * CETRAFS_DEFRAG_STEP_BLOCKS, sizeof(*copy_src), GFP_NOFS);
    copy_lba = kcalloc(CETRAFS_DEFRAG_STEP_BLOCKS, sizeof(*copy_lba), GFP_NOFS);
    copy_off = kcalloc(CETRAFS_DEFRAG_STEP_BLOCKS, sizeof(*copy_off), GFP_NOFS);
    if (!rawp || !copy_src || !copy_lba || !copy_off) {
        kfree(rawp);
        kfree(copy_src);
        kfree(copy_lba);
        kfree(copy_off);
        kvfree(el.arr);
        kvfree(el.rl);
        return -ENOMEM;
    }
    copy_dst = copy_src + CETRAFS_DEFRAG_STEP_BLOCKS;

    cetrafs_defrag_inode_lock(inode);
    /* The write gate, not just the fence: a damaged inode refuses every
     * write, and relocation rewrites its record and moves every block
     * (audit 2026-11-06 L21). Both the ioctl and the worker come here. */
    ret = cetrafs_write_gate(inode);
    if (ret)
        goto out_unlock;
    ret = cetrafs_defrag_read_raw(sb, inode, &raw);
    if (ret)
        goto out_unlock;
    if (!S_ISREG(inode->i_mode)) {
        ret = -EINVAL;
        goto out_unlock;
    }
    ret = cetrafs_defrag_read_extents(inode, &raw, &el);
    if (ret)
        goto out_unlock;

    stats.extents_before = el.count;
    stats.extents_after = el.count;
    nblocks = el.nblocks;

    if (el.count <= 1) {
        ret = 0; /* already contiguous */
        goto out_unlock;
    }
    /*
     * Holes and preallocated extents are kept: the destination run holds
     * the MAPPED blocks in logical order, each prefix entry goes back at
     * its own logical block, and a preallocated one keeps its flag (its
     * blocks are not copied -- nothing in them is the file's). Both used
     * to be refused, so a thin or preallocated VM image -- the usual
     * kind -- could never be defragmented (audit 2026-11-15 A-14).
     *
     * The refusal's reason, kept for what it guards: a preallocated
     * extent maps real blocks that have never been written, and reads as
     * zeros BECAUSE of the uninit flag. A mover that published the moved
     * blocks as plain data would copy whatever the previous owner left
     * and publish it as the file's (tests/kernel/churn_oracle.sh's
     * "HOLE HOLDS DATA"). The flag travels with the extent instead, and
     * defrag_ignore_uninit drops it to show that it must.
     */
    snapshot_runs = el.runs;
    snapshot_rl = kvmemdup(el.rl, 2 * (size_t) el.runs * sizeof(*el.rl), GFP_KERNEL);
    if (!snapshot_rl) {
        ret = -ENOMEM;
        goto out_unlock;
    }

    /* The span rides INSIDE the allocation -- bits set and span
     * published under one alloc_mutex hold -- because publish-after-
     * return left the run's first blocks stealable for a scrub cycle
     * (322 of them, in a loaded full-gate run). The negative control
     * passes NULL and publishes nothing, same observable as before. */
    /* The runs a stopped pass already placed stay where they are. */
    ret = cetrafs_defrag_dst_placed(&el, nblocks, &dst, &placed);
    if (ret)
        goto out_unlock;
    if (placed == nblocks) {
        ret = 0; /* every run is a segment already */
        goto out_unlock;
    }
    moved = placed;
    ret = cetrafs_defrag_dst_grow(sb, &dst, placed, nblocks - placed, cetrafs_defrag_skip_resv ? NULL : &dst_span);
    if (ret)
        goto out_unlock;
    have_dst = true;
    cetrafs_defrag_inode_unlock(inode);

    while (moved < nblocks) {
        struct blk_plug plug;
        u64 step_end, b, step_lo, step_hi, seg_end, lim;
        u32 si, suffix_start, split_off;
        bool foreign; /* an old block outside our own groups (cetrafs_frees_begin()) */

        /* The segment is fully committed: the file names all of it, so
         * its span goes, and the next segment comes with its own. */
        if (moved == dst.seg[dst.n - 1].first + dst.seg[dst.n - 1].count) {
            cetrafs_resv_unpublish(sb, &dst_span);
            have_dst = false;
            ret = cetrafs_defrag_dst_grow(sb, &dst, moved, nblocks - moved,
                                          cetrafs_defrag_skip_resv ? NULL : &dst_span);
            if (ret)
                goto out_free_tail; /* no room for more: the file stays as the steps so far left it */
            have_dst = true;
        }
        seg_end = cetrafs_defrag_seg_end(&dst, moved);
        lim = min_t(u64, CETRAFS_DEFRAG_STEP_BLOCKS, seg_end - moved);

        if (cetrafs_sb_defrag_draining(sb) || cetrafs_sb_is_fenced(sb)) {
            ret = -ECANCELED;
            goto out_free_tail;
        }
        ret = cetrafs_write_gate(inode); /* damage found mid-move */
        if (ret)
            goto out_free_tail;
        /* defrag.cetra on a VM image runs for minutes and pins the file
         * (every peer open refused) while it does; SIGKILL must stop it.
         * Between steps is the clean point: the committed prefix is the
         * file's data and the suffix still names valid blocks, exactly
         * as for -ECANCELED. The background worker has no signals, so
         * this is the ioctl's alone. */
        if (fatal_signal_pending(current)) {
            ret = -EINTR;
            goto out_free_tail;
        }

        if (cetrafs_defrag_step_delay_ms)
            msleep(cetrafs_defrag_step_delay_ms); /* test-only: the lock is NOT held here, which is the point */

        /* The step below frees the old physical blocks. */
        cetrafs_defrag_inode_lock_drained(inode);

        /* A buffered or mapped store into a preallocated block is data
         * to this node while the extent still says preallocated, until a
         * boundary converts it (enum cetrafs_gb_mode). The step copies
         * only what the tree calls written, so convert first: the
         * stores are on the device and the tree says so. */
        if (cetrafs_pending_any(inode) && !READ_ONCE(cetrafs_defrag_pending_unconverted)) {
            ret = cetrafs_convert_pending_locked(inode);
            if (ret) {
                cetrafs_defrag_inode_unlock(inode);
                goto out_free_tail;
            }
        }

        /* Re-read and revalidate: same file (generation), same shape
         * (length + dense), still long enough. Anything else -- a
         * truncate, a hole punch, a spill that changed the layout, inode
         * reuse -- aborts cleanly; the committed prefix is already the
         * file's real data and the suffix still points at valid blocks. */
        ret = cetrafs_defrag_read_raw(sb, inode, &raw);
        if (ret || cetrafs_le64(raw.generation) != cetrafs_inode_get_generation(inode)) {
            ret = ret ? ret : -ESTALE;
            cetrafs_defrag_inode_unlock(inode);
            goto out_free_tail;
        }
        /* A peer wants the file: it found our pin RELOCATING and swapped
         * in YIELD (cetrafs_lock_wait_yield()), and is waiting for it.
         * Stop at this boundary, where the file is consistent; the
         * caller clears the lock. The read above is fresh here: an idle
         * pin has no local writer. With one, the pin is that writer's
         * EXCLUSIVE lock and no peer asks. */
        /* ...or this node's own lock suspend did (a migration handoff):
         * same stop, no I/O to see it. */
        /* A peer's ask quiets the file for a while (-EAGAIN: it is
         * the peer's now). This node's own ask is a local open or
         * suspend passing through: the pass is cancelled, and handed
         * back to be judged again (-ECANCELED). Taken as a peer's, every
         * first open -- a backup's, a monitor's qemu-img info, filefrag
         * -- quieted the janitor for the whole quiet window, and a file
         * read now and then was never healed. */
        if ((cetrafs_le32(raw.lock_mode) == CETRAFS_LOCK_YIELD || cetrafs_lock_defrag_stop_asked(inode)) &&
            !READ_ONCE(cetrafs_defrag_ignore_yield)) {
            atomic64_inc(&cetrafs_defrag_yields);
            ret = cetrafs_le32(raw.lock_mode) == CETRAFS_LOCK_YIELD || READ_ONCE(cetrafs_defrag_local_stop_quiets)
                      ? -EAGAIN
                      : -ECANCELED;
            /* Its last close judges the file again: the pass handed
             * back below finds the opener still there (-EBUSY) and is
             * declined, and a read close queues nothing of its own. */
            if (ret == -ECANCELED)
                cetrafs_lock_defrag_rejudge_on_close(inode);
            cetrafs_defrag_inode_unlock(inode);
            goto out_free_tail;
        }
        ret = cetrafs_defrag_read_extents(inode, &raw, &el);
        /* The same mapped blocks at the same logical places as when the
         * pass began (a hole punched, filled or moved changes the plan:
         * rank k must still be the same logical block). Preallocated or
         * written may change between steps -- a write converts -- and
         * each step copies and publishes the flags as it reads them. */
        if (ret || el.nblocks != nblocks ||
            ((el.runs != snapshot_runs || memcmp(el.rl, snapshot_rl, 2 * (size_t) el.runs * sizeof(*el.rl))) &&
             !cetrafs_defrag_skip_dense_recheck)) {
            ret = ret ? ret : -ECANCELED;
            cetrafs_defrag_inode_unlock(inode);
            goto out_free_tail;
        }

        /*
         * And the prefix we already moved must still BE where we put
         * it.
         *
         * inode_lock is dropped between steps, which is what makes this
         * mover incremental and what lets a local writer in. The checks
         * above catch a different file (generation) and a resized one
         * (nblocks), but a punch FOLLOWED BY A REWRITE of the committed
         * prefix restores the block count while putting those logical
         * blocks on completely different physical ones. The commit
         * below would then republish [0, moved) as living at dst_base:
         * the rewritten data lost, the blocks after it corrupted, and
         * 16 blocks leaked -- measured, with this walk removed, by
         * tests/kernel/defrag_prefix_moved.sh.
         *
         * The density check above DOES reject that today, but only by
         * accident: the rewrite is APPENDED, so the array stops being
         * in logical order. That is a statement about array ordering,
         * not about where the prefix lives, and it would stop holding
         * the day a writer updates an entry in place or rebuilds the
         * array sorted. Hence defrag_skip_dense_recheck, which lets the
         * suite relax it and prove this walk alone is sufficient.
         *
         * Cheap, because the prefix is by construction one contiguous
         * run: walk the extents covering it and require them to be
         * exactly dst_base + offset.
         */
        if (moved) {
            u64 off = 0;
            u32 e;

            for (e = 0; e < el.count && off < moved; e++) {
                u64 phys = cetrafs_ee_pblk(&el.arr[e]);
                u64 len = cetrafs_ee_len(&el.arr[e]);

                u64 last = min_t(u64, off + len, moved) - 1;

                /* Both ends: the destination is several runs, and an
                 * extent starting right could still run past its own. */
                if (phys != cetrafs_defrag_dst_of(&dst, off) || phys + (last - off) != cetrafs_defrag_dst_of(&dst, last)) {
                    pr_warn_ratelimited(
                        "defrag: ino=%llu block %llu moved to %llu but now reads %llu -- rewritten under us, "
                        "abandoning the move\n",
                        (unsigned long long) inode->i_ino, (unsigned long long) off,
                        (unsigned long long) cetrafs_defrag_dst_of(&dst, off), (unsigned long long) phys);
                    ret = -ECANCELED;
                    cetrafs_defrag_inode_unlock(inode);
                    goto out_free_tail;
                }
                off += len;
            }
            if (off < moved) {
                ret = -ECANCELED;
                cetrafs_defrag_inode_unlock(inode);
                goto out_free_tail;
            }
        }

        /* Choose this step's end: up to the block cap. An extent that
         * runs past the cap is split there: [its start, step_end) moves
         * now, and the suffix handed to the commit starts with the rest
         * of it (split_off blocks in). Extents behind 'moved' were
         * committed earlier and the prefix walk above proved it. */
        split_off = 0;
        {
            u64 off = 0;

            suffix_start = el.count; /* index of first suffix extent after this step */
            step_end = moved;
            for (si = 0; si < el.count; si++) {
                u32 len = cetrafs_ee_len(&el.arr[si]);

                if (off + len <= moved) {
                    off += len; /* already behind the cursor */
                    continue;
                }
                /* this extent starts at or past 'moved' */
                if (off + len - moved > lim) {
                    step_end = moved + lim;
                    split_off = (u32) (step_end - off); /* within this extent, > 0 */
                    break;                              /* si: the split extent heads the suffix */
                }
                step_end = off + len;
                off += len;
                if (step_end - moved >= lim) {
                    si++;
                    break;
                }
            }
            suffix_start = si; /* first extent past step_end (trimmed by split_off) */
        }
        {
            s64 seen = atomic64_read(&cetrafs_defrag_max_step);

            while ((s64) (step_end - moved) > seen &&
                   !atomic64_try_cmpxchg(&cetrafs_defrag_max_step, &seen, (s64) (step_end - moved)))
                ;
        }

        /* Flush this step's page range so the writer's dirty pages reach
         * their CURRENT (old) blocks on disk, then copy old -> new.
         * Source reads are forced-fresh (cetrafs_bread_uncached): file
         * data lives in the inode page cache, a DIFFERENT address space
         * from sb_bread()'s block-device buffer cache, so a plain cached
         * read here can return a stale block-device buffer that never saw
         * the writer's just-flushed data -- the exact data-loss the
         * concurrent-writer test caught. The flush above makes the old
         * block on disk authoritative; the uncached read then gets it. */
        /* Pages are logical: the step's ranks reach from the logical
         * block of rank 'moved' to the end of rank step_end - 1. */
        step_lo = cetrafs_defrag_rank_logical(&el, moved);
        step_hi = cetrafs_defrag_rank_logical_end(&el, step_end);
        ret = filemap_write_and_wait_range(inode->i_mapping, (loff_t) step_lo << 12, (((loff_t) step_hi) << 12) - 1);
        if (ret) {
            cetrafs_defrag_inode_unlock(inode);
            goto out_free_tail;
        }

        /*
         * Copied a STEP at a time, however many source runs it crosses: its
         * source blocks read as one batch, its writes submitted together
         * and waited for once. A file fragmented into one-block runs -- what
         * defrag exists for -- paid a read and a write round trip per block
         * under the file's locks when the batch was per run (audit
         * 2026-11-14 M1). defrag_copy_serial copies one block per round
         * trip, test-only.
         */
        b = moved;
        while (b < step_end && !ret) {
            u64 bb = b, ce_off = 0;
            u32 ce = 0, nb = 0, i;
            u32 lim = READ_ONCE(cetrafs_defrag_copy_serial) ? 1 : CETRAFS_DEFRAG_STEP_BLOCKS;

            /* Inside the step too: a step is bounded, but an unmount, a
             * fence or SIGKILL should not wait out even that (M9).
             * Nothing is committed yet, so stopping here is the same
             * clean abort as between steps. */
            if (cetrafs_sb_defrag_draining(sb) || cetrafs_sb_is_fenced(sb) || fatal_signal_pending(current)) {
                ret = fatal_signal_pending(current) ? -EINTR : -ECANCELED;
                break;
            }

            /* This batch: the source of each block from bb on, across runs,
             * up to the batch cap. The cursor (ce, ce_off) only moves
             * forward, so the whole step costs one pass over the map. */
            for (; bb < step_end && nb < lim; bb++) {
                u64 src;

                while (ce < el.count && bb >= ce_off + cetrafs_ee_len(&el.arr[ce])) {
                    ce_off += cetrafs_ee_len(&el.arr[ce]);
                    ce++;
                }
                if (ce >= el.count) {
                    ret = -EIO; /* the map does not cover the step: the checks above make this damage */
                    break;
                }
                src = cetrafs_ee_pblk(&el.arr[ce]) + (bb - ce_off);
                if (src == cetrafs_defrag_dst_of(&dst, bb)) /* already in place */
                    continue;
                /* Preallocated: nothing in it is the file's, and it stays
                 * preallocated where it lands (cetrafs_defrag_commit()). */
                if (cetrafs_ee_uninit(&el.arr[ce]) && !READ_ONCE(cetrafs_defrag_ignore_uninit))
                    continue;
                copy_lba[nb] = src;
                copy_off[nb] = (u32) (bb - moved);
                nb++;
            }
            if (ret)
                break;
            b = bb;
            if (!nb)
                continue;

            /* Forced-fresh reads of every source block, as one batch. */
            ret = cetrafs_bread_uncached_list(sb, copy_lba, nb, copy_src);
            if (ret)
                break;
            if (unlikely(READ_ONCE(cetrafs_defrag_copy_stall_ms)))
                msleep(xchg(&cetrafs_defrag_copy_stall_ms, 0)); /* TEST ONLY: between the read and the writes */
            blk_start_plug(&plug);
            for (i = 0; i < nb; i++) {
                struct buffer_head *dbh;

                /*
                 * The fence again, here and per block: the test above
                 * precedes up to 128 forced-fresh reads, and a stall in
                 * them outlasting the stale window let a peer take the
                 * group, recount it from a device without the
                 * destination's bits, and hand the run to a growing
                 * file -- which these copies then overwrote with this
                 * file's old blocks (audit 2026-11-15 B-32). Before the
                 * buffer is dirtied, so nothing is left for writeback.
                 */
                if (cetrafs_sb_is_fenced(sb) && !READ_ONCE(cetrafs_defrag_copy_gate_off)) {
                    ret = -ECANCELED;
                    break;
                }
                dbh = sb_getblk(sb, cetrafs_defrag_dst_of(&dst, moved + copy_off[i]));
                copy_dst[i] = dbh;
                if (!dbh) {
                    ret = -EIO;
                    break;
                }
                /* Via the helpers: cetrafs_bh_end_update(sb, ) dirties before
                 * unlocking, closing the window in which a forced-fresh
                 * reader could take the lock on a clean, uptodate buffer
                 * and re-read the destination's OLD content over the
                 * copy we just made. */
                cetrafs_bh_begin_update(dbh);
                memcpy(dbh->b_data, copy_src[i]->b_data, CETRAFS_BLOCK_SIZE);
                cetrafs_bh_end_update(sb, dbh);
                cetrafs_write_pending_buffer(sb, dbh, REQ_SYNC);
            }
            blk_finish_plug(&plug);
            for (i = 0; i < nb; i++) {
                if (copy_dst[i]) {
                    wait_on_buffer(copy_dst[i]);
                    if (!buffer_uptodate(copy_dst[i]))
                        ret = -EIO;
                    else
                        cetrafs_held_unlist(sb, copy_dst[i]); /* written: not pinned until the tick (F-27) */
                    brelse(copy_dst[i]);
                    copy_dst[i] = NULL;
                }
                brelse(copy_src[i]);
                copy_src[i] = NULL;
            }
        }
        if (ret) {
            cetrafs_defrag_inode_unlock(inode);
            goto out_free_tail;
        }

        /* Remember the original physical blocks of the [moved, step_end)
         * range so they can be freed after the commit makes the new run
         * authoritative. (Skip any that were already in place.) */
        {
            cetrafs_extent_t *suffix = &el.arr[suffix_start];
            u32 suffix_count = el.count - suffix_start;
            u64 freed_from = moved;

            /* The split extent's remainder heads the suffix for the
             * commit only: the free loop below maps the old blocks by
             * walking el.arr's lengths, so the entry is restored before
             * anything else reads it. */
            cetrafs_extent_t whole = {0};

            if (split_off) {
                u32 len = cetrafs_ee_len(&suffix[0]);
                u64 phys = cetrafs_ee_pblk(&suffix[0]);

                whole = suffix[0];
                cetrafs_ee_set_lblk(&suffix[0], cetrafs_ee_lblk(&whole) + split_off);
                cetrafs_ee_set_len(&suffix[0], len - split_off, cetrafs_ee_uninit(&whole));
                cetrafs_ee_set_pblk(&suffix[0], phys + split_off);
            }
            /* The commit publishes the step and frees the old tree's
             * meta; the old data blocks follow below. From the publish
             * until those frees, announced (cetrafs_frees_begin()) --
             * to peers only if one of those blocks is outside our own
             * groups. el.arr maps [0, file end) in order, which is how
             * the free loop below walks it; suffix[0] is restored. */
            {
                u64 o = 0;
                u32 e;

                foreign = !cetrafs_tree_meta_is_ours(inode, &raw);
                for (e = 0; e < el.count && !foreign; e++) {
                    const cetrafs_extent_t *x = (e == suffix_start && split_off) ? &whole : &el.arr[e];
                    u64 len = cetrafs_ee_len(x);
                    u64 s = max(o, freed_from), t = min(o + len, step_end);

                    if (s < t &&
                        !cetrafs_lba_run_is_ours(
                            sb, cetrafs_ee_pblk(x) + (s - o), t - s))
                        foreign = true;
                    o += len;
                }
            }
            ret = cetrafs_frees_begin(sb, &foreign);
            if (!ret) {
                ret = cetrafs_defrag_commit(inode, &raw, &dst, moved, step_end, nblocks, el.arr, suffix_start,
                                            split_off ? &whole : NULL, split_off, suffix, suffix_count);
                if (ret)
                    cetrafs_frees_end(sb, foreign);
            }
            if (split_off)
                suffix[0] = whole;
            if (ret == -ENOTRECOVERABLE) {
                /* The record may name the new run: free none of it. */
                cetrafs_defrag_inode_unlock(inode);
                ret = -EIO;
                goto out_done;
            }
            if (ret) {
                cetrafs_defrag_inode_unlock(inode);
                goto out_free_tail;
            }
            /* The count the commit published, into core while this
             * step still holds the locks every i_blocks writer takes --
             * see the note after the loop. */
            inode->i_blocks = cetrafs_le64(raw.blocks);

            /* The commit just published [0, step_end) on the new run.
             * Advance the cursor BEFORE anything below can fail:
             * out_free_tail frees dst[moved, nblocks) on the promise
             * that [0, moved) is the file's real data, and an abort
             * between a commit and this line used to free 251 committed
             * blocks of an 8 MiB file -- which the allocator then handed
             * to other files (cross-file overlap, found by fsck after a
             * two-writer fill with auto-defrag). */
            moved = step_end;

            /* Drop the file's cached pages for the just-moved range: they
             * hold buffer_heads still mapped to the OLD blocks we're
             * about to free, so a subsequent read (or a racing reader's
             * writeback) through them would touch freed/reallocated
             * space. Clean here (we flushed above and hold inode_lock),
             * so this can't lose a dirty page; next access re-faults
             * against the new mapping and reads our synced new blocks. */
            /* PAGE indices, not block numbers -- see cetrafs_blk_to_pgoff().
             * These were passed raw, which is correct only while a page
             * is one block. */
            ret = invalidate_inode_pages2_range(inode->i_mapping, cetrafs_blk_to_pgoff(step_lo),
                                                cetrafs_blk_end_pgoff(step_hi - 1));
            if (cetrafs_defrag_fail_invalidate)
                ret = -EBUSY; /* TEST ONLY: a racing reader's page reference, on demand */
            if (ret) {
                /* A failure here is a transient reference (a racing
                 * reader) on a CLEAN page whose content equals the new
                 * blocks. Aborting is not an option: the commit is
                 * published, and a stale page left in the cache still
                 * maps the OLD blocks through its attached buffers, so a
                 * later write through it would land on freed (and by
                 * then reallocated) space. Force the pages out instead
                 * -- clean and flushed, so nothing is lost -- and carry
                 * on with the step. */
                unmap_mapping_range(inode->i_mapping, (loff_t) step_lo << 12, (loff_t) (step_hi - step_lo) << 12, 1);
                truncate_inode_pages_range(inode->i_mapping, (loff_t) step_lo << 12, ((loff_t) step_hi << 12) - 1);
                pr_info_ratelimited("defrag: ino=%llu forced page drop for blocks [%llu, %llu)\n",
                                    (unsigned long long) inode->i_ino, (unsigned long long) step_lo,
                                    (unsigned long long) step_hi);
                ret = 0;
            }

            /* The committed prefix now points at the new run; the old
             * physical blocks for [freed_from, step_end) are
             * unreferenced -- free them (per block, since they were
             * fragmented; foreign-ZG blocks queue automatically). */
            for (b = freed_from; b < step_end; b++) {
                u64 src = 0, o = 0;
                u32 e;

                for (e = 0; e < el.count; e++) {
                    u32 len = cetrafs_ee_len(&el.arr[e]);

                    if (b < o + len) {
                        src = cetrafs_ee_pblk(&el.arr[e]) + (b - o);
                        break;
                    }
                    o += len;
                }
                if (src != cetrafs_defrag_dst_of(&dst, b))
                    cetrafs_free_data_block(sb, src);
            }
            cetrafs_frees_end(sb, foreign);
        }

        cetrafs_defrag_inode_unlock(inode);
        cond_resched();
    }

    /* Done: the file lives in order on the destination's runs. Old tree meta (the
     * external leaf, and at depth 2 the interiors) was freed by each
     * cetrafs_defrag_commit() as it published the next tree, so there is
     * nothing left to free here.
     *
     * The final block count reached the IN-CORE inode inside each
     * step, under its locks (a depth-2 collapse frees meta blocks, so
     * i_blocks must drop, or writeback carries the stale count back).
     * It used to be stored HERE, from the last step's record, with both
     * locks already dropped -- an append landing in this gap had its
     * block counted by get_block and then uncounted, and the next
     * publish took the short count to the device
     * (tests/kernel/defrag_final_blocks.sh). */
    if (cetrafs_defrag_final_stall_ms)
        msleep(cetrafs_defrag_final_stall_ms); /* test-only: no lock held here */
    cetrafs_flush_dirty_free_counts(sb);

    /* One per run of mapped blocks (more where an extent's length cap or
     * a written/preallocated boundary splits one). */
    stats.extents_after = max_t(u64, snapshot_runs, CETRAFS_DIV_ROUND_UP(nblocks, (u64) CETRAFS_EXT_LEN_MASK));
    stats.blocks_moved = nblocks - placed;
    ret = 0;
    goto out_done;

out_unlock:
    cetrafs_defrag_inode_unlock(inode);
    goto out_done;

out_free_tail:
    /* Free the never-committed tail of the destination run; the
     * committed prefix [0, moved) is the file's real data now. */
    /* Only the current segment's: the earlier ones are committed, the
     * later ones never allocated. */
    if (have_dst && moved < nblocks) {
        u64 end = cetrafs_defrag_seg_end(&dst, moved);

        if (moved < end) {
            ctrace("DEFRAGFREE-TAIL ino=%llu lba=%llu count=%llu\n", (unsigned long long) inode->i_ino,
                   (unsigned long long) cetrafs_defrag_dst_of(&dst, moved), (unsigned long long) (end - moved));
            cetrafs_free_data_extent(sb, cetrafs_defrag_dst_of(&dst, moved), end - moved);
        }
    }
    cetrafs_flush_dirty_free_counts(sb);

out_done:
    /* After the tail free above: the freed remainder must become
     * allocatable again, and the committed prefix is referenced by the
     * file's own extents from here on. */
    cetrafs_resv_unpublish(sb, &dst_span);
    kvfree(dst.seg);
    if (out_stats)
        *out_stats = stats;
    kvfree(el.arr);
    kvfree(el.rl);
    kvfree(snapshot_rl);
    kfree(rawp);
    kfree(copy_src);
    kfree(copy_lba);
    kfree(copy_off);
    return ret;
#undef raw
}

/* ---- automatic background defrag ------------------------------------ */

struct cetrafs_defrag {
    struct workqueue_struct *wq;
};

/* Requests that found their inode number reused by another file. */
static atomic64_t cetrafs_defrag_stale_reqs = ATOMIC64_INIT(0);
/* Background passes started, and those a growing file cancelled. */
static atomic64_t cetrafs_defrag_passes = ATOMIC64_INIT(0);
static atomic64_t cetrafs_defrag_growth_cancels = ATOMIC64_INIT(0);
u64 cetrafs_defrag_pass_count(void)
{
    return (u64) atomic64_read(&cetrafs_defrag_passes);
}
u64 cetrafs_defrag_growth_cancel_count(void)
{
    return (u64) atomic64_read(&cetrafs_defrag_growth_cancels);
}

/* TEST ONLY: a pass a growing file cancelled is requeued at once and
 * leaves the append trigger armed, as before audit 2026-11-14 M2 -- the
 * control of tests/kernel/defrag_growth_backoff.sh. */
static bool cetrafs_defrag_growth_requeue;
cetrafs_test_param(defrag_growth_requeue, cetrafs_defrag_growth_requeue, bool, 0644);
MODULE_PARM_DESC(defrag_growth_requeue, "TEST ONLY: requeue a growth-cancelled defrag at once");
u64 cetrafs_defrag_stale_req_count(void)
{
    return (u64) atomic64_read(&cetrafs_defrag_stale_reqs);
}

struct cetrafs_defrag_req {
    struct work_struct work;
    struct super_block *sb;
    u64 ino;
    u64 gen; /* the file the request is about: a number gets reused */
};

static void cetrafs_defrag_worker(struct work_struct *work)
{
    struct cetrafs_defrag_req *req = container_of(work, struct cetrafs_defrag_req, work);
    struct super_block *sb = req->sb;
    struct inode *inode;
    int ret;

    if (cetrafs_sb_is_fenced(sb) || cetrafs_sb_defrag_draining(sb)) {
        /* Bailing before the iget below must still clear the dedup
         * latch, or every later consider() of the file reads "already
         * queued" for as long as its inode stays cached (audit L22).
         * ilookup: no I/O, and only the object the latch is on. */
        inode = ilookup(sb, req->ino);
        if (inode) {
            if (cetrafs_inode_get_generation(inode) == req->gen)
                cetrafs_lock_defrag_unqueue(inode);
            iput(inode);
        }
        goto out_free;
    }

    inode = cetrafs_iget(sb, req->ino);
    if (IS_ERR(inode))
        goto out_free;
    /* The file was deleted and its number given to another since the
     * request was queued: not the file anyone asked about (audit L2).
     * Its own latch is its own; leave it alone. */
    if (cetrafs_inode_get_generation(inode) != req->gen) {
        pr_debug("auto-defrag: ino=%llu is a different file now (generation %llu, queued for %llu) -- skipped\n",
                 (unsigned long long) req->ino, (unsigned long long) cetrafs_inode_get_generation(inode),
                 (unsigned long long) req->gen);
        atomic64_inc(&cetrafs_defrag_stale_reqs);
        iput(inode);
        goto out_free;
    }

    /* Clear the dedup latch first: a close/append that lands while we
     * work can legitimately re-arm. */
    cetrafs_lock_defrag_unqueue(inode);

    if (cetrafs_auto_defrag_begin_delay_ms)
        msleep(cetrafs_auto_defrag_begin_delay_ms); /* TEST ONLY */
    /* Given up to a peer moments ago: not again yet. */
    if (cetrafs_lock_defrag_yielded(inode)) {
        iput(inode);
        goto out_free;
    }
    if (S_ISREG(inode->i_mode) && inode->i_nlink > 0) {
        ret = cetrafs_lock_defrag_begin(inode);
        if (ret == 0) {
            struct cetrafs_defrag_stats stats = {0};
            loff_t size0 = i_size_read(inode);
            bool grew;

            atomic64_inc(&cetrafs_defrag_passes);
            ret = cetrafs_defrag_inode(inode, &stats);
            /* Cancelled because the file grew under the move: a backup
             * archive or a qcow2 still being written. Every pass then
             * allocated a full-size run, moved a step, freed it and was
             * queued again at once -- by its own hand-back below, or by
             * the append trigger, which a cancel left armed (audit
             * 2026-11-14 M2). Quiet the append trigger as for a decline;
             * the hand-back below waits for the writer's last close. */
            grew = ret == -ECANCELED && i_size_read(inode) != size0 && !READ_ONCE(cetrafs_defrag_growth_requeue);
            if (grew) {
                atomic64_inc(&cetrafs_defrag_growth_cancels);
                cetrafs_lock_defrag_quiet_for(inode, cetrafs_auto_defrag_quiet_secs);
            }
            /* Declined: it would be declined again. Keep the append
             * trigger quiet for a while (cetrafs_lock_defrag_quiet()). */
            if (ret == -EOPNOTSUPP || ret == -ENOSPC || ret == -EAGAIN)
                cetrafs_lock_defrag_quiet_for(inode, cetrafs_auto_defrag_quiet_secs);
            if (ret == -EAGAIN)
                cetrafs_lock_defrag_yielded_for(inode, cetrafs_auto_defrag_quiet_secs);
            if (ret == 0 && stats.blocks_moved)
                pr_debug("auto-defrag: ino=%llu extents %llu -> %llu (%llu blocks moved)\n",
                         (unsigned long long) inode->i_ino, (unsigned long long) stats.extents_before,
                         (unsigned long long) stats.extents_after, (unsigned long long) stats.blocks_moved);
            else if (ret == -ECANCELED)
                pr_debug("auto-defrag: ino=%llu stopped early (file in use / unmount); left consistent\n",
                         (unsigned long long) inode->i_ino);
            /*
             * Say so when we DECLINE, too -- but at DEBUG. A decline is
             * a NORMAL outcome, not an anomaly: a sparse file is the
             * usual case for a VM image, and the trigger re-arms on
             * every later append to the same file, so even rate-limited
             * these lines recurred forever in a production dmesg (seen
             * in the field: ~20 lines in 11s for one inode). The trace
             * still answers "why is this image never defragmented?" --
             * it just has to be asked for, via dynamic debug (+p).
             */
            else if (ret == -EOPNOTSUPP)
                pr_debug("auto-defrag: ino=%llu declined: fragmented past the mover's extent cap\n",
                         (unsigned long long) inode->i_ino);
            else if (ret == -ENOSPC)
                pr_debug(
                    "auto-defrag: ino=%llu declined: no contiguous run large enough in the "
                    "zone groups this node owns\n",
                    (unsigned long long) inode->i_ino);
            else if (ret == -EAGAIN)
                pr_debug("auto-defrag: ino=%llu stopped: a peer asked for the file\n",
                         (unsigned long long) inode->i_ino);
            else if (ret == -ESTALE)
                pr_debug(
                    "auto-defrag: ino=%llu declined: the file changed under us (unlinked, or "
                    "its number reused)\n",
                    (unsigned long long) inode->i_ino);
            else if (ret)
                pr_warn("auto-defrag: ino=%llu failed: %d\n", (unsigned long long) inode->i_ino, ret);

            cetrafs_lock_defrag_end(inode);
            /*
             * A CANCELED move must hand the baton back. The mover's pin
             * made the writer's close skip its own janitor trigger (the
             * release defers the lock-clear to defrag_end and considers
             * nothing), and the cancel means the move did not finish the
             * job -- so if nothing re-queues here, a file whose only
             * close raced one in-flight nudge stays fragmented FOREVER.
             * A full-gate tape showed exactly that staffette: nudge ->
             * begin -> writer's close (pin set, trigger skipped) ->
             * -ECANCELED -> silence. Re-judge it now that the pin is
             * gone; consider()'s own thresholds filter, and a writer
             * that is still active just repeats this handoff until its
             * real last close takes the normal path.
             *
             * After a growth cancel that writer is still here, so there
             * is nothing to hand back yet: its last close re-judges the
             * file. Requeueing now only restarts the move it outran.
             */
            if (ret == -ECANCELED && !(grew && cetrafs_lock_has_local_writer(inode)))
                cetrafs_defrag_rejudge(inode);
        } else {
            /* Could not take the file's lock: it is open for write
             * somewhere, or a peer holds it, or the inode was replaced.
             * Also silent until now, and the one most likely to be
             * asked about -- "why is this image never defragmented?" is
             * answered here. */
            pr_debug(
                "auto-defrag: ino=%llu declined: could not take the file lock (%d) -- in use "
                "here or held by a peer\n",
                (unsigned long long) inode->i_ino, ret);
        }
    }

    iput(inode);
out_free:
    kfree(req);
}

/*
 * Fragmentation index: 'extents' as a percentage of the minimum extent
 * count a file of 'nblocks' blocks could occupy. ideal =
 * ceil(nblocks / CETRAFS_EXT_LEN_MASK) (>= 1); a contiguous file (every
 * extent at the length cap) scores exactly 100 no matter how large or
 * how many block groups it spans -- which is why this, not raw extent
 * count or BG spread, is the trigger.
 */
unsigned int cetrafs_frag_index_pct(u64 nblocks, u32 extents)
{
    u64 ideal = CETRAFS_DIV_ROUND_UP(nblocks, (u64) CETRAFS_EXT_LEN_MASK);

    if (ideal == 0)
        ideal = 1;
    return (unsigned int) div64_u64((u64) extents * 100, ideal);
}

/* Judge the file again from its record, as a write close does: the
 * janitor queues it if it still needs it (one request per inode). */
void cetrafs_defrag_rejudge(struct inode *inode)
{
    cetrafs_inode_t rr;

    if (cetrafs_read_raw_inode_overlaid(inode->i_sb, inode, &rr) == 0 &&
        cetrafs_le16(rr.eh.eh_magic) == CETRAFS_EXT_MAGIC) {
        u32 ext = cetrafs_tree_extent_count_for(inode, &rr, true); /* only queues one */

        if (ext)
            cetrafs_defrag_consider(inode, ext, CETRAFS_DIV_ROUND_UP(cetrafs_le64(rr.size), CETRAFS_BLOCK_SIZE));
    }
}

void cetrafs_defrag_consider(struct inode *inode, u32 extents, u64 nblocks)
{
    struct super_block *sb = inode->i_sb;
    struct cetrafs_defrag *d = cetrafs_sb_get_defrag(sb);
    struct cetrafs_defrag_req *req;

    /* Both switches: the mount-wide one (nothing here may pin a file's
     * exclusive lock) and the janitor's own. The module param stays as
     * the cross-mount default. */
    if (!d || !cetrafs_auto_defrag || !cetrafs_sb_defrag_enabled(sb) || !cetrafs_sb_auto_defrag_enabled(sb) ||
        cetrafs_sb_is_fenced(sb) || cetrafs_sb_defrag_draining(sb))
        return;
    /* Regular files only. Directories reach the extent-append path too
     * now that dir.c grows through cetrafs_get_block(), and
     * both the worker and cetrafs_defrag_inode() would reject them --
     * but only after burning a queue slot and the dedup latch. */
    if (!S_ISREG(inode->i_mode))
        return;
    /* Both gates: an absolute extent floor (ignore trivially-small files
     * whose index looks high but whose gain is negligible) AND the real
     * fragmentation index. A big CONTIGUOUS file has many extents but
     * scores 100 -- correctly skipped. */
    if (extents < cetrafs_auto_defrag_min_extents)
        return;
    if (cetrafs_frag_index_pct(nblocks, extents) < cetrafs_auto_defrag_min_pct)
        return;
    if (!cetrafs_lock_defrag_try_queue(inode))
        return; /* already queued */

    req = kmalloc(sizeof(*req), GFP_NOFS);
    if (!req) {
        cetrafs_lock_defrag_unqueue(inode);
        return;
    }

    req->sb = sb;
    req->ino = inode->i_ino;
    req->gen = cetrafs_inode_get_generation(inode);
    INIT_WORK(&req->work, cetrafs_defrag_worker);
    queue_work(d->wq, &req->work);
}

int cetrafs_defrag_init(struct super_block *sb, struct cetrafs_defrag **out_d)
{
    struct cetrafs_defrag *d = kzalloc(sizeof(*d), GFP_KERNEL);

    (void) sb;
    if (!d)
        return -ENOMEM;

    /* Ordered (max_active = 1): one background move at a time per mount,
     * bounding the janitor's I/O footprint on the shared LUN. */
    d->wq = alloc_ordered_workqueue("cetrafs_defrag", 0);
    if (!d->wq) {
        kfree(d);
        return -ENOMEM;
    }

    *out_d = d;
    return 0;
}

void cetrafs_defrag_stop(struct cetrafs_defrag *d)
{
    if (!d)
        return;
    destroy_workqueue(d->wq); /* drains queued + running work first */
    kfree(d);
}
