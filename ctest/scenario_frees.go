package main

import (
	"fmt"
	"os"
	"time"
)

// RunFreesInFlight: a scrub must not reclaim blocks a PEER is freeing.
//
// Class 46. A truncate publishes the shorter extent map first and frees
// afterwards; blocks in another node's Zone Group are freed by queueing
// them to that node (one append per extent). Between the publish and an
// append, the block is set in the owner's bitmap and referenced by no
// inode -- a leak to every test the owner's scrub has. The truncating
// node says so in its registry row (frees_inflight) and the scrub skips
// the cycle (cetrafs_frees_quiet()). Single-node,
// scrub_ignore_local_frees makes the row the only cover, but the row is
// then written and read by the same node; here they are two.
//
// A writes a 64 MiB file in its own Zone Groups, with a 5 s scrub. B
// truncates it to zero with its queue append held 30 s
// (pf_append_stall_ms; the file's blocks are one physical run, so the
// free is one append): 30 s of frees in flight. A's scrub must skip at
// least one cycle and reclaim nothing meanwhile; after B's frees drain,
// fsck must be clean.
//
// Negative control (CTEST_FREES_CONTROL=1): scrub_ignore_peer_frees on
// A. Its scrub then reclaims the blocks in transit.
func RunFreesInFlight(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("frees-in-flight needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	two := []*Client{a, b}
	control := os.Getenv("CTEST_FREES_CONTROL") != ""
	setA := [][2]string{{"scrub", "1"}, {"scrub_interval_secs", "5"}, {"scrub_gap_secs", "1"}, {"alloc_run_blocks", "0"}}
	if control {
		setA = append(setA, [2]string{"scrub_ignore_peer_frees", "1"})
	}
	defer func() {
		_ = callOK(a, "mod_param", ModParamArgs{Name: "scrub_ignore_peer_frees", Value: "0"})
		_ = callOK(a, "mod_param", ModParamArgs{Name: "alloc_run_blocks", Value: "256"})
		_ = callOK(b, "mod_param", ModParamArgs{Name: "pf_append_stall_ms", Value: "0"})
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
		// The scrub cadence goes back to its defaults for whatever runs next.
		for _, kv := range [][2]string{{"scrub_interval_secs", "1800"}, {"scrub_gap_secs", "15"}} {
			_ = callOK(a, "mod_param", ModParamArgs{Name: kv[0], Value: kv[1]})
		}
	}()
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	for _, kv := range setA {
		if err := callOK(a, "mod_param", ModParamArgs{Name: kv[0], Value: kv[1]}); err != nil {
			return false, fmt.Errorf("%s: %s: %w", a.Name, kv[0], err)
		}
	}
	if err := mountAllDefault(two); err != nil {
		return false, err
	}
	if control {
		fmt.Printf("  NEGATIVE CONTROL: scrub_ignore_peer_frees=1 on %s\n", a.Name)
	}
	dir := baseDir + "/frees-in-flight"
	fmt.Printf("=== frees-in-flight: %s truncates a file in %s's Zone Groups while %s scrubs ===\n", b.Name, a.Name, a.Name)
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}
	f := dir + "/victim"
	if err := callOK(a, "write", WriteArgs{Path: f, Size: 64 << 20, Stamp: "f"}); err != nil {
		return false, fmt.Errorf("setup write: %w", err)
	}

	if err := callOK(b, "mod_param", ModParamArgs{Name: "pf_append_stall_ms", Value: "30000"}); err != nil {
		return false, err
	}
	skips0, err := infoCounter(a, "scrub_inflight_skips")
	if err != nil {
		return false, err
	}
	rec0, _ := infoCounter(a, "scrub_reclaimed")
	cyc0, _ := infoCounter(a, "scrub_cycles")

	start := time.Now()
	done := make(chan error, 1)
	go func() { done <- callOK(b, "truncate", TruncateArgs{Path: f, Size: 0}) }()
	terr := <-done
	window := time.Since(start)
	_ = callOK(b, "mod_param", ModParamArgs{Name: "pf_append_stall_ms", Value: "0"})
	skips1, _ := infoCounter(a, "scrub_inflight_skips")
	rec1, _ := infoCounter(a, "scrub_reclaimed")
	cyc1, _ := infoCounter(a, "scrub_cycles")
	fmt.Printf("  %s's truncate: %v after %.1fs; %s's scrub: skips %d->%d, reclaimed %d->%d, cycles %d->%d\n",
		b.Name, terr, window.Seconds(), a.Name, skips0, skips1, rec0, rec1, cyc0, cyc1)

	ok := true
	if terr != nil {
		return false, fmt.Errorf("%s: truncate: %w", b.Name, terr)
	}
	if window < 15*time.Second {
		check(&ok, "setup: the truncate kept frees in flight for 15 s or more", false,
			fmt.Sprintf("%.1fs -- did its blocks go to %s's queue?", window.Seconds(), a.Name))
		return false, nil
	}
	if control {
		check(&ok, "control: a scrub blind to the peer reclaims the blocks in transit", rec1 > rec0,
			fmt.Sprintf("reclaimed %d -> %d", rec0, rec1))
		return ok, nil
	}
	check(&ok, a.Name+"'s scrub skipped while "+b.Name+"'s frees were in flight", skips1 > skips0,
		fmt.Sprintf("skips %d -> %d", skips0, skips1))
	check(&ok, a.Name+"'s scrub reclaimed nothing meanwhile", rec1 == rec0, fmt.Sprintf("reclaimed %d -> %d", rec0, rec1))

	// Let A drain the queued frees, then judge the bitmaps.
	time.Sleep(40 * time.Second)
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	resp, e := a.Call("fsck", FsckArgs{})
	var fr FsckResult
	if err := decodeResult(a.Name, resp, e, &fr); err != nil {
		check(&ok, "fsck ran", false, err.Error())
	} else {
		check(&ok, "fsck clean: nothing freed twice", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, firstLine(fr.Output)))
	}
	if ok {
		fmt.Printf("PASS: frees-in-flight\n")
	} else {
		fmt.Printf("FAIL: frees-in-flight: see failed checks above\n")
	}
	return ok, nil
}
