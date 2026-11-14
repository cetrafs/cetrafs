package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// RunForeignFreeBatch: a file of many extents, freed by a node that does
// not own their Zone Groups, reaches the owner's pending-free queue in a
// few swaps, not one per extent (audit P10).
//
// A writes N one-block extents: write_at at a stride, so no two are
// contiguous in the file and none merges. B unlinks the file, so every
// extent is a foreign free and goes to A's queue. On B the scenario reads
// the swaps (pending_free_appends) and the entries they carried
// (pending_free_entries), and times the unlink.
//
//	batched       the default batch: swaps must be a small fraction of the
//	              entries (several per swap)
//	one-per-swap  pf_batch_size=1 on B -- the negative control: one swap
//	              per entry, as before the batch
//	concurrent    A's heartbeat drains every second while B unlinks: A's
//	              drain and B's appends interleave, and nothing may be
//	              lost or freed twice
//	queue-full    pf_force_queue_full on B: every extent is dropped and
//	              counted, and the unlink still succeeds for the caller
//
// After the first three phases A alone remounts (its mount applies the
// queue), unmounts, and fsck must be clean with free space back where it
// was before any file was written. The queue-full phase runs last: its
// extents are deliberately leaked until the scrub reclaims them.
//
// CTEST_PFB_EXTENTS sets N (default 3000, at least 200).
func RunForeignFreeBatch(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("foreign-free-batch needs at least 2 clients")
	}
	n := 3000
	if v := os.Getenv("CTEST_PFB_EXTENTS"); v != "" {
		x, err := strconv.Atoi(v)
		if err != nil {
			return false, fmt.Errorf("CTEST_PFB_EXTENTS=%q: %w", v, err)
		}
		n = x
	}
	if n < 200 {
		return false, fmt.Errorf("foreign-free-batch: %d extents is too few to measure a batch", n)
	}
	a, b := clients[0], clients[1]
	two := []*Client{a, b}

	defer func() {
		_ = callOK(b, "mod_param", ModParamArgs{Name: "pf_batch_size", Value: "0"})
		_ = callOK(b, "mod_param", ModParamArgs{Name: "pf_force_queue_full", Value: "0"})
		_ = callOK(a, "mod_param", ModParamArgs{Name: "hb_interval_secs", Value: "15"})
		if uerr := ensureUnmounted(two); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()
	if err := ensureUnmounted(two); err != nil {
		return false, err
	}
	if err := mountAllDefault(two); err != nil {
		return false, err
	}

	ok := true
	var snap ProcSnapshotResult
	resp, err := a.Call("proc_snapshot", ProcSnapshotArgs{Device: a.Device})
	if err := decodeResult(a.Name, resp, err, &snap); err != nil {
		return false, err
	}
	ownedByA := 0
	for _, zg := range snap.ZoneGroups {
		if zg.ThisNode {
			ownedByA++
		}
	}
	check(&ok, a.Name+" owns a Zone Group the file can be written into", ownedByA > 0,
		"no Zone Group owned -- nothing would be written there")
	if !ok {
		return false, nil
	}

	dir := baseDir + "/pf-batch"
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}
	base, err := statfsFree(a)
	if err != nil {
		return false, err
	}

	// writeExtents: n one-block extents in f, written by A.
	writeExtents := func(f string) error {
		for i := 0; i < n; i++ {
			r, e := a.Call("write_at", WriteAtArgs{Path: f, Offset: int64(i) * 8192, Size: 4096, Stamp: "pfb", Create: i == 0})
			if err := decodeResult(a.Name, r, e, nil); err != nil {
				return fmt.Errorf("write_at %s extent %d: %w", f, i, err)
			}
		}
		return nil
	}

	// unlinkByB: B deletes f and reports what its queue appends did.
	type phaseResult struct {
		entries, swaps, leaks int64
		cas                   int64
		wall                  time.Duration
		err                   error
	}
	unlinkByB := func(f string) phaseResult {
		var r phaseResult
		e0, _ := infoCounter(b, "pending_free_entries")
		s0, _ := infoCounter(b, "pending_free_appends")
		l0, _ := infoCounter(b, "foreign_free_leaks")
		c0, _ := infoCounter(b, "cas_ops")
		t0 := time.Now()
		resp, e := b.Call("unlink", UnlinkArgs{Path: f})
		r.wall = time.Since(t0)
		r.err = decodeResult(b.Name, resp, e, nil)
		e1, _ := infoCounter(b, "pending_free_entries")
		s1, _ := infoCounter(b, "pending_free_appends")
		l1, _ := infoCounter(b, "foreign_free_leaks")
		c1, _ := infoCounter(b, "cas_ops")
		r.entries, r.swaps, r.leaks, r.cas = e1-e0, s1-s0, l1-l0, c1-c0
		return r
	}

	// ---- batched -------------------------------------------------------
	fmt.Printf("=== foreign-free-batch: %d extents written by %s, unlinked by %s ===\n", n, a.Name, b.Name)
	f1 := dir + "/batched"
	if err := writeExtents(f1); err != nil {
		return false, err
	}
	r1 := unlinkByB(f1)
	if r1.err != nil {
		return false, fmt.Errorf("%s: unlink (batched): %w", b.Name, r1.err)
	}
	fmt.Printf("  batched:      %d entries in %d swap(s), %d CAS op(s), unlink %.2fs\n", r1.entries, r1.swaps, r1.cas, r1.wall.Seconds())
	check(&ok, "setup: the unlink queued the extents to "+a.Name+"'s queue (one entry per extent)",
		r1.entries >= int64(n)*9/10,
		fmt.Sprintf("%d entries for %d extents", r1.entries, n))
	check(&ok, fmt.Sprintf("batched: %d entries took %d swap(s) -- several per swap", r1.entries, r1.swaps),
		r1.swaps >= 1 && r1.swaps*8 <= r1.entries,
		fmt.Sprintf("%d swaps", r1.swaps))

	// ---- one per swap: the negative control ---------------------------
	if err := callOK(b, "mod_param", ModParamArgs{Name: "pf_batch_size", Value: "1"}); err != nil {
		return false, err
	}
	f2 := dir + "/one-per-swap"
	if err := writeExtents(f2); err != nil {
		return false, err
	}
	r2 := unlinkByB(f2)
	if err := callOK(b, "mod_param", ModParamArgs{Name: "pf_batch_size", Value: "0"}); err != nil {
		return false, err
	}
	if r2.err != nil {
		return false, fmt.Errorf("%s: unlink (one-per-swap): %w", b.Name, r2.err)
	}
	fmt.Printf("  one-per-swap: %d entries in %d swap(s), %d CAS op(s), unlink %.2fs\n", r2.entries, r2.swaps, r2.cas, r2.wall.Seconds())
	check(&ok, fmt.Sprintf("control: pf_batch_size=1 gives one swap per entry (%d for %d)", r2.swaps, r2.entries),
		r2.entries >= int64(n)*9/10 && r2.swaps >= r2.entries*9/10 && r2.swaps <= r2.entries,
		"the knob does not restore the one-per-extent path, so the batched count proves nothing")

	// ---- concurrent: A drains every second while B unlinks -------------
	if err := callOK(a, "mod_param", ModParamArgs{Name: "hb_interval_secs", Value: "1"}); err != nil {
		return false, err
	}
	f3 := dir + "/concurrent"
	if err := writeExtents(f3); err != nil {
		return false, err
	}
	r3 := unlinkByB(f3)
	time.Sleep(4 * time.Second) // a few of A's ticks, to drain what the unlink queued
	if err := callOK(a, "mod_param", ModParamArgs{Name: "hb_interval_secs", Value: "15"}); err != nil {
		return false, err
	}
	if r3.err != nil {
		return false, fmt.Errorf("%s: unlink (concurrent): %w", b.Name, r3.err)
	}
	fmt.Printf("  concurrent:   %d entries in %d swap(s), %d CAS op(s), unlink %.2fs, %s draining every 1 s\n",
		r3.entries, r3.swaps, r3.cas, r3.wall.Seconds(), a.Name)

	// ---- recovery: A alone applies the queue, then fsck ----------------
	if err := ensureUnmounted(two); err != nil {
		return false, fmt.Errorf("unmount before the recovery mount: %w", err)
	}
	if err := callOK(a, "mount", MountArgs{}); err != nil {
		return false, fmt.Errorf("%s: recovery mount: %w", a.Name, err)
	}
	afterMount, err := statfsFree(a)
	if err != nil {
		return false, err
	}
	if err := ensureUnmounted([]*Client{a}); err != nil {
		return false, err
	}
	check(&ok, "recovery: free space is back where it started after "+a.Name+"'s mount applied the queue",
		afterMount == base, fmt.Sprintf("%d free blocks, started at %d", afterMount, base))
	resp, e := a.Call("fsck", FsckArgs{})
	var fr FsckResult
	if err := decodeResult(a.Name, resp, e, &fr); err != nil {
		check(&ok, "fsck ran", false, err.Error())
	} else {
		check(&ok, "fsck clean: no extent leaked and none freed twice", fr.Clean,
			fmt.Sprintf("exit %d: %s", fr.ExitCode, firstLine(fr.Output)))
	}

	// ---- queue-full: every extent dropped, counted, caller unharmed ----
	if err := mountAllDefault(two); err != nil {
		return false, err
	}
	if err := callOK(b, "mod_param", ModParamArgs{Name: "pf_force_queue_full", Value: "1"}); err != nil {
		return false, err
	}
	f4 := dir + "/queue-full"
	if err := writeExtents(f4); err != nil {
		return false, err
	}
	r4 := unlinkByB(f4)
	if err := callOK(b, "mod_param", ModParamArgs{Name: "pf_force_queue_full", Value: "0"}); err != nil {
		return false, err
	}
	fmt.Printf("  queue-full:   %d leaked, %d swap(s), unlink %.2fs\n", r4.leaks, r4.swaps, r4.wall.Seconds())
	check(&ok, "queue-full: the unlink succeeded for the caller", r4.err == nil,
		fmt.Sprintf("%v", r4.err))
	check(&ok, fmt.Sprintf("queue-full: all %d extents dropped and counted as leaks", n),
		r4.leaks >= int64(n)*9/10 && r4.swaps == 0 && r4.entries == 0,
		fmt.Sprintf("%d leaks, %d swaps, %d entries", r4.leaks, r4.swaps, r4.entries))

	if ok {
		fmt.Printf("PASS: foreign-free-batch\n")
	} else {
		fmt.Printf("FAIL: foreign-free-batch: see failed checks above\n")
	}
	return ok, nil
}

// statfsFree is the free block count of c's mount.
func statfsFree(c *Client) (uint64, error) {
	var sf StatfsResult
	resp, err := c.Call("statfs", struct{}{})
	if err := decodeResult(c.Name, resp, err, &sf); err != nil {
		return 0, fmt.Errorf("%s: statfs: %w", c.Name, err)
	}
	return sf.FreeBlocks, nil
}
