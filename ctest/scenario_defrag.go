package main

import (
	"fmt"
	"strings"
	"time"
)

// RunDefragYield: the background defrag must not lock a peer out of a
// file it is merely tidying.
//
// The janitor relocates a fragmented file under the file's whole-file
// lock, taken exactly as a write-open takes it, and holds it for the
// whole pass -- minutes for a large image. A peer's open meanwhile
// fails ETXTBSY: on a default mount a VM stopped on one host cannot be
// started on another until a background optimisation finishes. Seen in
// fstrim-pool as reads of a just-written file refused for over 10 s.
//
// The scenario fragments a file on a (blocks written in reverse order),
// slows the move with defrag_step_delay_ms so it is caught in flight,
// then opens the file on b. The open must succeed, the move must step
// aside, and the data must read back whole. A real writer is the
// control the other way: while a holds the file open for write, b's
// open must still be refused, and promptly.
func RunDefragYield(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("defrag-yield needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	stepDelaySet := false
	defer func() {
		if stepDelaySet {
			_ = callOK(a, "mod_param", ModParamArgs{Name: "defrag_step_delay_ms", Value: "0"})
			_ = callOK(a, "mod_param", ModParamArgs{Name: "defrag_ignore_yield", Value: "0"})
			_ = callOK(b, "mod_param", ModParamArgs{Name: "lock_yield_wait_ms", Value: "10000"})
		}
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	if err := mountAllDefault(clients); err != nil {
		return false, err
	}
	const (
		mib   = int64(1) << 20
		stamp = "DEFRAG-Y"
	)
	dir := baseDir + "/defrag-yield"
	size := 32 * mib
	fmt.Printf("=== defrag-yield: a peer's open vs a background move, %s <-> %s ===\n", a.Name, b.Name)
	ok := true
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir %s: %w", dir, err)
	}
	if err := callOK(a, "mod_param", ModParamArgs{Name: "defrag_step_delay_ms", Value: "200"}); err != nil {
		return false, fmt.Errorf("%s: defrag_step_delay_ms: %w", a.Name, err)
	}
	stepDelaySet = true

	// Ascending, but written alongside a second file: the two
	// interleave on the device, so the file is dense (defrag declines
	// anything else) and made of many short extents.
	n := size / dioBlock
	offs := make([]int64, n)
	for i := range offs {
		offs[i] = int64(i) * dioBlock
	}
	pinned := func(c *Client) int64 {
		v, err := infoCounter(c, "defrag_pinned")
		if err != nil {
			return -1
		}
		return v
	}
	waitPinned := func(want int64, limit time.Duration) bool {
		for t := time.Now(); time.Since(t) < limit; time.Sleep(100 * time.Millisecond) {
			if pinned(a) == want {
				return true
			}
		}
		return false
	}
	// fragmented writes a fresh fragmented file on a and waits for a's
	// janitor to be moving it.
	fragmented := func(path string) error {
		if err := callOK(a, "write_at", WriteAtArgs{Path: path, Offset: 0, Size: 0, Create: true}); err != nil {
			return err
		}
		pad := path + ".pad"
		var bg DioWriteResult
		// Block 0 left a hole: the janitor declines a sparse file, so
		// the only move this node makes is the one under test.
		resp, e := a.Call("dio_write", DioWriteArgs{Path: pad, Offsets: offs[1:], Stamp: "PAD", Par: 1, Create: true, Background: true})
		if err := decodeResult(a.Name, resp, e, &bg); err != nil {
			return fmt.Errorf("starting %s: %w", pad, err)
		}
		var wr DioWriteResult
		resp, e = a.Call("dio_write", DioWriteArgs{Path: path, Offsets: offs, Stamp: stamp, Par: 1, Fsync: true})
		if err := decodeResult(a.Name, resp, e, &wr); err != nil || wr.Failed > 0 {
			return fmt.Errorf("writing %s: %v (%d failed)", path, err, wr.Failed)
		}
		var bw DioWriteResult
		resp, e = a.Call("dio_wait", DioWaitArgs{Job: bg.Job, TimeoutSecs: 300})
		if err := decodeResult(a.Name, resp, e, &bw); err != nil || !bw.Done {
			return fmt.Errorf("waiting for %s: %v (done %v)", pad, err, bw.Done)
		}
		if !waitPinned(1, 60*time.Second) {
			return fmt.Errorf("defrag_pinned=%d 60 s after writing %s -- the move never started", pinned(a), path)
		}
		return nil
	}
	setParam := func(c *Client, name, v string) error {
		return callOK(c, "mod_param", ModParamArgs{Name: name, Value: v})
	}

	// 1. b opens the file mid-move: twice as negative controls, then for real.
	cases := []struct {
		label        string
		node         *Client
		param, value string
		wantOpen     bool
	}{
		{"control: a peer that does not ask (the old open) is refused", b, "lock_yield_wait_ms", "0", false},
		{"control: a move that ignores the ask keeps the peer out", a, "defrag_ignore_yield", "1", false},
		{"1: the peer's open gets the file from a background move", nil, "", "", true},
	}
	for ci, k := range cases {
		path := fmt.Sprintf("%s/img%d", dir, ci)
		if err := fragmented(path); err != nil {
			check(&ok, "setup: "+a.Name+"'s janitor is moving the file", false, err.Error())
			return ok, nil
		}
		if k.node != nil {
			if err := setParam(k.node, k.param, k.value); err != nil {
				return false, fmt.Errorf("%s: %s=%s: %w", k.node.Name, k.param, k.value, err)
			}
		}
		y0, _ := infoCounter(a, "defrag_yields")
		t0 := time.Now()
		var h OpenHoldResult
		resp, e := b.Call("open_hold", OpenHoldArgs{Path: path, Mode: "rdonly"})
		oerr := decodeResult(b.Name, resp, e, &h)
		waited := time.Since(t0).Round(10 * time.Millisecond)
		if k.node != nil {
			def := "0"
			if k.param == "lock_yield_wait_ms" {
				def = "10000"
			}
			_ = setParam(k.node, k.param, def)
		}
		if !k.wantOpen {
			if oerr == nil {
				_ = callOK(b, "close", CloseArgs{Handle: h.Handle})
			}
			check(&ok, fmt.Sprintf("%s (%s)", k.label, waited), oerr != nil && strings.Contains(oerr.Error(), "text file busy"),
				fmt.Sprintf("the open returned %v -- the move had stepped aside anyway, so case 1 proves nothing", oerr))
			waitPinned(0, 5*time.Minute)
			continue
		}
		check(&ok, fmt.Sprintf("%s (in %s)", k.label, waited), oerr == nil, fmt.Sprint(oerr))
		if oerr != nil {
			waitPinned(0, 5*time.Minute)
			continue
		}
		y1, _ := infoCounter(a, "defrag_yields")
		check(&ok, "1: the move stepped aside", y1 == y0+1 && waitPinned(0, 10*time.Second),
			fmt.Sprintf("defrag_yields %d -> %d, defrag_pinned=%d on %s", y0, y1, pinned(a), a.Name))
		var v VerifyBlocksResult
		resp, e = b.Call("verify_blocks", VerifyBlocksArgs{Path: path, Size: size, Direct: true, Stamps: []string{stamp},
			Forbidden: "DEFRAG-NEVER", Must: []DioMust{{Stamp: stamp, Offsets: offs}}})
		if err := decodeResult(b.Name, resp, e, &v); err != nil {
			check(&ok, "1: the peer reads the file whole", false, err.Error())
		} else {
			check(&ok, "1: the peer reads the file whole", v.Missing == 0 && v.Garbage == 0 && v.Zero == 0 &&
				v.Valid[stamp] == int(n), fmt.Sprintf("valid %v zero %d missing %d garbage %d; %s",
				v.Valid, v.Zero, v.Missing, v.Garbage, strings.Join(v.Details, "; ")))
		}
		if err := callOK(b, "close", CloseArgs{Handle: h.Handle}); err != nil {
			return false, fmt.Errorf("%s: close: %w", b.Name, err)
		}
	}
	img := dir + "/img2"

	// 2. Control: a real writer still refuses the peer, promptly.
	var h OpenHoldResult
	resp, e := a.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdwr"})
	if err := decodeResult(a.Name, resp, e, &h); err != nil {
		return false, fmt.Errorf("%s: open_hold rdwr: %w", a.Name, err)
	}
	t0 := time.Now()
	var h2 OpenHoldResult
	resp, e = b.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdonly"})
	oerr := decodeResult(b.Name, resp, e, &h2)
	waited := time.Since(t0)
	if oerr == nil {
		_ = callOK(b, "close", CloseArgs{Handle: h2.Handle})
	}
	check(&ok, fmt.Sprintf("2: a writer on %s still refuses %s's open (in %s)", a.Name, b.Name, waited.Round(10*time.Millisecond)),
		oerr != nil && strings.Contains(oerr.Error(), "text file busy") && waited < 3*time.Second,
		fmt.Sprintf("err %v after %s", oerr, waited))
	if err := callOK(a, "close", CloseArgs{Handle: h.Handle}); err != nil {
		return false, fmt.Errorf("%s: close: %w", a.Name, err)
	}

	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	var fr FsckResult
	resp, e = a.Call("fsck", FsckArgs{})
	if err := decodeResult(a.Name, resp, e, &fr); err != nil {
		check(&ok, "fsck ran", false, err.Error())
	} else {
		check(&ok, "fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, fr.Output))
	}
	if ok {
		fmt.Printf("PASS: defrag-yield: a background move steps aside for a peer's open\n")
	}
	return ok, nil
}
