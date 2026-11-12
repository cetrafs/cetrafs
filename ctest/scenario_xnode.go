// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// Shared by the cross-node fix scenarios below.

// setClusterTiming sets the heartbeat interval and stale window on every
// client. Shrinking: interval first; growing back: stale window first,
// so a node never advertises an interval longer than a peer's window.
func setClusterTiming(clients []*Client, hb, stale int, staleFirst bool) {
	order := [][2]string{{"hb_interval_secs", fmt.Sprint(hb)}, {"stale_secs", fmt.Sprint(stale)}}
	if staleFirst {
		order[0], order[1] = order[1], order[0]
	}
	for _, cl := range clients {
		for _, kv := range order {
			resp, err := cl.Call("set_control", SetControlArgs{Key: kv[0], Value: kv[1]})
			if e := decodeResult(cl.Name, resp, err, nil); e != nil {
				fmt.Printf("WARNING: %s could not set %s=%s: %v\n", cl.Name, kv[0], kv[1], e)
			}
		}
	}
}

// waitSeenStale waits until every observer's registry view shows a
// foreign node stale. Returns false on timeout.
func waitSeenStale(observers []*Client, limit time.Duration) bool {
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		all := true
		for _, o := range observers {
			var snap ProcSnapshotResult
			resp, err := o.Call("proc_snapshot", ProcSnapshotArgs{Device: o.Device})
			seen := false
			if decodeResult(o.Name, resp, err, &snap) == nil {
				for _, n := range snap.Nodes {
					if n.Stale && !n.ThisNode {
						seen = true
					}
				}
			}
			all = all && seen
		}
		if all {
			return true
		}
		time.Sleep(time.Second)
	}
	return false
}

// modParams sets module parameters on a client and returns a func that
// puts every one back to what it read before.
func modParams(c *Client, kv ...string) (func(), error) {
	var undo [][2]string
	restore := func() {
		for i := len(undo) - 1; i >= 0; i-- {
			_ = callOK(c, "mod_param", ModParamArgs{Name: undo[i][0], Value: undo[i][1]})
		}
	}
	for i := 0; i+1 < len(kv); i += 2 {
		var r ModParamResult
		resp, err := c.Call("mod_param", ModParamArgs{Name: kv[i], Value: kv[i+1]})
		if e := decodeResult(c.Name, resp, err, &r); e != nil {
			restore()
			return func() {}, fmt.Errorf("%s: %s=%s: %w", c.Name, kv[i], kv[i+1], e)
		}
		prev := strings.TrimSpace(r.Prev)
		if prev == "Y" {
			prev = "1"
		} else if prev == "N" {
			prev = "0"
		}
		undo = append(undo, [2]string{kv[i], prev})
	}
	return restore, nil
}

// RunSweepVsOpenReplay: a node's heartbeat keeps working while one of
// its opens waits for a peer replaying a dead node's journal.
//
// Before a node takes anything a dead node held -- a file lock, a Zone
// Group -- it replays that node's journal, and if a LIVE peer holds the
// replay claim it waits for that peer to finish (up to the claim cap,
// several stale windows). The heartbeat's stale-journal sweep does not
// wait: it walks away and tries next tick. It used to take the area's
// replay mutex unconditionally, and that mutex is held by the waiting
// open -- so the maintenance pass parked for as long as the open waited
// (926e670, staged single-node with a forged "live" claim). This is
// the real thing: three nodes, the live replayer genuinely live.
//
// c dies with journal entries durable and not applied
// (journal_batch_crash_before_targets) while holding a file's lock. b
// claims c's area and is held mid-replay (journal_replay_apply_pause_ms);
// a was kept out until then (journal_replay_refuse). a then opens c's
// file: the open fences c and waits on b's claim. Meanwhile a's
// completed heartbeat passes (hb_sweeps) must keep rising, and once b
// finishes the open gets the file.
//
// Control (CTEST_SWEEP_CONTROL=1): a's sweep waits for the mutex
// (journal_sweep_waits) -- its passes must stop while the open waits.
func RunSweepVsOpenReplay(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 3 {
		return skipScenario("sweep-vs-open-replay needs a dead node and two survivors, have %d", len(clients))
	}
	control := os.Getenv("CTEST_SWEEP_CONTROL") != ""
	a, b, c := clients[0], clients[1], clients[2]
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	if err := mountAllDefault(clients); err != nil {
		return false, err
	}
	var restores []func()
	linkDown := false
	var cHandle uint64
	defer func() {
		for i := len(restores) - 1; i >= 0; i-- {
			restores[i]()
		}
		if cHandle != 0 {
			_, _ = c.Call("close", CloseArgs{Handle: cHandle})
		}
		if linkDown {
			if _, err := c.Call("link_up", nil); err != nil {
				fmt.Printf("WARNING: could not restore %s's device: %v\n", c.Name, err)
			}
		}
		_ = ensureUnmounted(clients)
	}()
	setClusterTiming(clients, 5, 15, false)
	restores = append(restores, func() { setClusterTiming(clients, defaultHBIntervalSecs, defaultStaleSecs, true) })
	if err := waitAdvertisedInterval(a, c, 5, 20*time.Second); err != nil {
		fmt.Printf("WARNING: %s\n", err)
	}

	ok := true
	dir := baseDir + "/sweep-open"
	img := dir + "/vm.img"
	fmt.Printf("=== sweep-vs-open-replay: %s dies dirty, %s replays it slowly, %s's open waits ===\n", c.Name, b.Name, a.Name)
	if control {
		fmt.Printf("  NEGATIVE CONTROL: %s's sweep waits for the area mutex\n", a.Name)
	}
	for _, kv := range []struct {
		cl *Client
		p  []string
	}{
		{a, []string{"journal_replay_refuse", "1"}},
		{b, []string{"journal_replay_apply_pause_ms", "40000"}},
	} {
		r, err := modParams(kv.cl, kv.p...)
		restores = append(restores, r)
		if err != nil {
			return false, fmt.Errorf("setup: %w", err)
		}
	}
	if control {
		r, err := modParams(a, "journal_sweep_waits", "1")
		restores = append(restores, r)
		if err != nil {
			return false, fmt.Errorf("setup: %w", err)
		}
	}

	if err := callOK(c, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}
	var oh OpenHoldResult
	resp, err := c.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdwr", Create: true})
	if e := decodeResult(c.Name, resp, err, &oh); e != nil {
		return false, fmt.Errorf("setup: %s open: %w", c.Name, e)
	}
	cHandle = oh.Handle
	if err := callOK(c, "fallocate", FallocateArgs{Path: img, Length: 64 << 20}); err != nil {
		return false, fmt.Errorf("setup: %s fallocate: %w", c.Name, err)
	}
	for i := 0; i < 8; i++ {
		if err := callOK(c, "write_held", HeldIOArgs{Handle: cHandle, Offset: int64(i*997%16000) * 4096, Size: 4096,
			Stamp: fmt.Sprintf("c-%d-", i)}); err != nil {
			return false, fmt.Errorf("setup: %s write %d: %w", c.Name, i, err)
		}
	}
	mark := fmt.Sprintf("ctest-sweep-%d", time.Now().UnixNano())
	for _, cl := range clients[:3] { // each node's own log: a search on one without it reads it all
		_ = callOK(cl, "dmesg_mark", DmesgMarkArgs{Marker: mark})
	}
	if r, err := modParams(c, "journal_batch_crash_before_targets", "1"); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	} else {
		restores = append(restores, r)
	}
	_ = callOK(c, "write_held", HeldIOArgs{Handle: cHandle, Offset: 12345 * 4096, Size: 4096, Stamp: "c-last-"})
	if !strings.Contains(dmesgSince(c, mark), "before their targets") {
		check(&ok, "setup: "+c.Name+" stopped with journal entries durable and not applied", false,
			"no 'TEST stop ... before their targets' in its dmesg")
		return ok, nil
	}
	pass := func(l string) { check(&ok, l, true, "") }
	pass("setup: " + c.Name + " stopped with journal entries durable and not applied, holding vm.img's lock")
	if err := callOK(c, "link_down", nil); err != nil {
		return false, fmt.Errorf("%s link_down: %w", c.Name, err)
	}
	linkDown = true
	if !waitSeenStale([]*Client{a, b}, 90*time.Second) {
		check(&ok, "setup: "+a.Name+" and "+b.Name+" see "+c.Name+" stale", false, "never went stale")
		return ok, nil
	}

	// b's heartbeat claims c's area and is held on its first entry.
	paused := false
	for i := 0; i < 60 && !paused; i++ {
		paused = strings.Contains(dmesgSince(b, mark), "journal replay: pausing")
		if !paused {
			time.Sleep(time.Second)
		}
	}
	if !paused {
		check(&ok, "setup: "+b.Name+" is replaying "+c.Name+"'s journal", false, "no 'journal replay: pausing' on "+b.Name)
		return ok, nil
	}
	pass("setup: " + b.Name + " holds the replay claim on " + c.Name + "'s journal and is paused in it")

	_ = callOK(a, "mod_param", ModParamArgs{Name: "journal_replay_refuse", Value: "0"})
	s0, err := infoCounter(a, "hb_sweeps")
	if err != nil {
		return false, err
	}
	// The open runs on a second connection to a: one connection
	// carries one request at a time, and the counter reads below would
	// otherwise queue behind the open they are watching.
	conns, closeConns, err := a.Parallel(2, 10*time.Second)
	if err != nil {
		return false, err
	}
	defer closeConns()
	aOpen := conns[1]
	var wg sync.WaitGroup
	var openErr error
	var aHandle uint64
	openDone := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer close(openDone)
		var h OpenHoldResult
		resp, err := aOpen.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdwr"})
		openErr = decodeResult(a.Name, resp, err, &h)
		aHandle = h.Handle
	}()
	time.Sleep(4 * time.Second)
	s1, _ := infoCounter(a, "hb_sweeps")
	time.Sleep(15 * time.Second)
	s2, _ := infoCounter(a, "hb_sweeps")
	select {
	case <-openDone:
		check(&ok, "setup: "+a.Name+"'s open waits for "+b.Name+"'s replay", false,
			fmt.Sprintf("it returned at once (%v) -- nothing below is measured", openErr))
		wg.Wait()
		if aHandle != 0 {
			_ = callOK(a, "close", CloseArgs{Handle: aHandle})
		}
		return ok, nil
	default:
	}
	pass("setup: " + a.Name + "'s open of vm.img is waiting for " + b.Name + "'s replay")
	if control {
		check(&ok, fmt.Sprintf("control: with the sweep waiting for the mutex, %s's heartbeat passes stop (%d -> %d over 15 s)",
			a.Name, s1, s2), s2 <= s1, "they went on -- the scenario cannot tell the two apart")
	} else {
		check(&ok, fmt.Sprintf("%s's heartbeat passes go on while its open waits (%d -> %d -> %d)", a.Name, s0, s1, s2),
			s2 >= s1+2, "the maintenance pass is parked behind the waiting open")
	}
	wg.Wait()
	if !control {
		check(&ok, a.Name+"'s open gets vm.img once "+b.Name+" has replayed", openErr == nil && aHandle != 0, fmt.Sprint(openErr))
	}
	if aHandle != 0 {
		_ = callOK(a, "close", CloseArgs{Handle: aHandle})
	}

	// c comes back as a fresh mount, then everything leaves cleanly.
	_ = ensureUnmounted([]*Client{a, b})
	_, _ = c.Call("close", CloseArgs{Handle: cHandle}) // on a stopped mount: errors, but the fd goes
	cHandle = 0
	if _, err := c.Call("link_up", nil); err != nil {
		return false, fmt.Errorf("%s link_up: %w", c.Name, err)
	}
	linkDown = false
	_ = ensureUnmounted([]*Client{c})
	if err := mountAllDefault([]*Client{c}); err == nil {
		_ = ensureUnmounted([]*Client{c})
	}
	var fr FsckResult
	resp, err = a.Call("fsck", FsckArgs{})
	if e := decodeResult(a.Name, resp, err, &fr); e != nil {
		check(&ok, "fsck ran", false, e.Error())
	} else {
		check(&ok, "fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, firstLine(fr.Output)))
	}
	if ok {
		fmt.Printf("PASS: sweep-vs-open-replay\n")
	} else {
		fmt.Printf("FAIL: sweep-vs-open-replay: see failed checks above\n")
	}
	return ok, nil
}

// journalState reads node id's journal area flag off the device:
// 0 clean, 1 dirty, -1 unreadable.
func journalState(c *Client, id int) int {
	var dr DeviceReadResult
	resp, err := c.Call("device_read", DeviceReadArgs{Kind: "journal", Args: []string{fmt.Sprint(id)}})
	if decodeResult(c.Name, resp, err, &dr) != nil {
		return -1
	}
	var st int
	if _, e := fmt.Sscanf(strings.TrimSpace(dr.Output), "state=%d", &st); e != nil {
		return -1
	}
	return st
}

// waitDmesg polls c's log since mark for want.
func waitDmesg(c *Client, mark, want string, limit time.Duration) bool {
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		if strings.Contains(dmesgSince(c, mark), want) {
			return true
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
}

// RunReplayAfterTruncate: a dead node's journal replayed after a
// survivor freed what it targets, by two survivors, the first of which
// cannot consume.
//
// Under nofilelock a VM's writer holds no lock, only its presence bit.
// When that node dies the VM is restarted elsewhere, and the new
// writer's first truncate fences the dead node and clears its bit --
// without replaying its journal, which only a lock holder's reclaim
// does. The truncate then frees blocks the dead node's surviving
// entries target, and the replay comes later, from a sweep. Two fixes
// meet here, both staged single-node by planting entries:
//   - a target freed since its entry is not redone (a19ef23);
//   - a replay that cannot consume an entry leaves the area DIRTY, so
//     the next replay finds the redo in place and finishes (88f350b).
//
// c stops with entries for vm.img's tree blocks durable and not applied
// (journal_batch_crash_before_targets) and loses its device. a and b
// are kept out of its journal (journal_replay_refuse) while a truncates
// vm.img to 0. Then b replays with its consume failed once
// (journal_consume_fail_once): the area must still read DIRTY. Then a
// replays: the area reads CLEAN. vm.img stays empty on both survivors
// -- the replay of its old tree blocks resurrects nothing -- and fsck is
// clean once c has come back.
//
// On the rig (2026-11-12) the truncated target is refused before the
// freed-bit check is reached: its owner no longer maps it ("no longer
// a block of its owner -- freed and reused since"). Either refusal
// keeps the old tree block off the device; the outcome is what is
// checked.
//
// Control (CTEST_CONSUME_CONTROL=1): b parks the area after the failed
// consume as it used to (journal_consume_fail_park) -- it must read
// CLEAN with the entry left behind.
func RunReplayAfterTruncate(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 3 {
		return skipScenario("replay-after-truncate needs a dead node and two survivors, have %d", len(clients))
	}
	control := os.Getenv("CTEST_CONSUME_CONTROL") != ""
	a, b, c := clients[0], clients[1], clients[2]
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	for _, cl := range clients[:3] {
		if err := callOK(cl, "mount", MountArgs{NoFileLock: true}); err != nil {
			return false, fmt.Errorf("setup: %s mount nofilelock: %w", cl.Name, err)
		}
	}
	var restores []func()
	linkDown := false
	var cHandle uint64
	defer func() {
		for i := len(restores) - 1; i >= 0; i-- {
			restores[i]()
		}
		if cHandle != 0 {
			_, _ = c.Call("close", CloseArgs{Handle: cHandle})
		}
		if linkDown {
			if _, err := c.Call("link_up", nil); err != nil {
				fmt.Printf("WARNING: could not restore %s's device: %v\n", c.Name, err)
			}
		}
		_ = ensureUnmounted(clients)
	}()
	setClusterTiming(clients[:3], 5, 15, false)
	restores = append(restores, func() { setClusterTiming(clients[:3], defaultHBIntervalSecs, defaultStaleSecs, true) })
	if err := waitAdvertisedInterval(a, c, 5, 20*time.Second); err != nil {
		fmt.Printf("WARNING: %s\n", err)
	}
	param := func(cl *Client, kv ...string) error {
		r, err := modParams(cl, kv...)
		restores = append(restores, r)
		return err
	}

	ok := true
	pass := func(l string) { check(&ok, l, true, "") }
	dir := baseDir + "/replay-trunc"
	img := dir + "/vm.img"
	fmt.Printf("=== replay-after-truncate: %s dies dirty, %s truncates its VM image, %s and %s replay ===\n",
		c.Name, a.Name, b.Name, a.Name)
	if control {
		fmt.Printf("  NEGATIVE CONTROL: %s parks the area after its failed consume\n", b.Name)
	}
	for _, cl := range []*Client{a, b} {
		if err := param(cl, "journal_replay_refuse", "1"); err != nil {
			return false, fmt.Errorf("setup: %w", err)
		}
	}
	var snapC ProcSnapshotResult
	resp, err := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
	if e := decodeResult(c.Name, resp, err, &snapC); e != nil {
		return false, fmt.Errorf("setup: %s snapshot: %w", c.Name, e)
	}
	cID := snapC.ThisNodeID

	if err := callOK(c, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}
	var oh OpenHoldResult
	resp, err = c.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdwr", Create: true})
	if e := decodeResult(c.Name, resp, err, &oh); e != nil {
		return false, fmt.Errorf("setup: %s open: %w", c.Name, e)
	}
	cHandle = oh.Handle
	if err := callOK(c, "fallocate", FallocateArgs{Path: img, Length: 64 << 20}); err != nil {
		return false, fmt.Errorf("setup: %s fallocate: %w", c.Name, err)
	}
	for i := 0; i < 8; i++ {
		if err := callOK(c, "write_held", HeldIOArgs{Handle: cHandle, Offset: int64(i*997%16000) * 4096, Size: 4096,
			Stamp: fmt.Sprintf("c-%d-", i)}); err != nil {
			return false, fmt.Errorf("setup: %s write %d: %w", c.Name, i, err)
		}
	}
	mark := fmt.Sprintf("ctest-rtrunc-%d", time.Now().UnixNano())
	for _, cl := range clients[:3] {
		_ = callOK(cl, "dmesg_mark", DmesgMarkArgs{Marker: mark})
	}
	if err := param(c, "journal_batch_crash_before_targets", "1"); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	_ = callOK(c, "write_held", HeldIOArgs{Handle: cHandle, Offset: 12345 * 4096, Size: 4096, Stamp: "c-last-"})
	if !strings.Contains(dmesgSince(c, mark), "before their targets") {
		check(&ok, "setup: "+c.Name+" stopped with journal entries durable and not applied", false,
			"no 'TEST stop ... before their targets' in its dmesg")
		return ok, nil
	}
	pass("setup: " + c.Name + " stopped with vm.img's tree blocks journaled and not written")
	if err := callOK(c, "link_down", nil); err != nil {
		return false, fmt.Errorf("%s link_down: %w", c.Name, err)
	}
	linkDown = true
	if !waitSeenStale([]*Client{a, b}, 90*time.Second) {
		check(&ok, "setup: "+a.Name+" and "+b.Name+" see "+c.Name+" stale", false, "never went stale")
		return ok, nil
	}
	if st := journalState(a, cID); st != 1 {
		check(&ok, "setup: "+c.Name+"'s journal area is dirty", false, fmt.Sprintf("state %d", st))
		return ok, nil
	}

	// The restarted VM's first act: truncate. No lock to reclaim, so
	// nothing replays c first.
	if err := callOK(a, "truncate", TruncateArgs{Path: img, Size: 0}); err != nil {
		check(&ok, a.Name+" truncates the dead node's VM image", false, err.Error())
		return ok, nil
	}
	if st := journalState(a, cID); st != 1 {
		check(&ok, "setup: "+c.Name+"'s journal is still unreplayed after the truncate", false, fmt.Sprintf("state %d", st))
		return ok, nil
	}
	pass("setup: " + a.Name + " truncated vm.img with " + c.Name + "'s journal still unreplayed")

	// b replays and cannot consume.
	if err := param(b, "journal_consume_fail_once", "1"); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	if control {
		if err := param(b, "journal_consume_fail_park", "1"); err != nil {
			return false, fmt.Errorf("setup: %w", err)
		}
	}
	_ = callOK(b, "mod_param", ModParamArgs{Name: "journal_replay_refuse", Value: "0"})
	if !waitDmesg(b, mark, "could not consume", 40*time.Second) {
		check(&ok, "setup: "+b.Name+"'s replay fails to consume", false, "no 'could not consume' on "+b.Name)
		return ok, nil
	}
	_ = callOK(b, "mod_param", ModParamArgs{Name: "journal_replay_refuse", Value: "1"}) // no second try from b
	st := journalState(a, cID)
	if control {
		check(&ok, "control: parked after the failed consume, the area reads clean with its entry left", st == 0,
			fmt.Sprintf("state %d -- the scenario cannot tell the two apart", st))
	} else {
		check(&ok, b.Name+"'s replay could not consume; the area stays dirty for the next replay", st == 1,
			fmt.Sprintf("state %d", st))
		_ = callOK(a, "mod_param", ModParamArgs{Name: "journal_replay_refuse", Value: "0"})
		check(&ok, a.Name+" replays it after "+b.Name, waitDmesg(a, mark, fmt.Sprintf("journal replay: node %d replayed", cID), 40*time.Second),
			"no replay of "+c.Name+"'s journal on "+a.Name)
		time.Sleep(2 * time.Second)
		check(&ok, "and the area reads clean", journalState(a, cID) == 0, fmt.Sprintf("state %d", journalState(a, cID)))
	}
	for _, cl := range []*Client{a, b} {
		var s StatResult
		resp, err := cl.Call("stat", StatArgs{Path: img})
		if e := decodeResult(cl.Name, resp, err, &s); e != nil {
			check(&ok, cl.Name+" stats vm.img", false, e.Error())
			continue
		}
		check(&ok, fmt.Sprintf("vm.img is still empty on %s: the replay of its old tree blocks resurrected nothing", cl.Name),
			s.Size == 0, fmt.Sprintf("size %d", s.Size))
	}

	_ = ensureUnmounted([]*Client{a, b})
	_, _ = c.Call("close", CloseArgs{Handle: cHandle})
	cHandle = 0
	if _, err := c.Call("link_up", nil); err != nil {
		return false, fmt.Errorf("%s link_up: %w", c.Name, err)
	}
	linkDown = false
	_ = ensureUnmounted([]*Client{c})
	if err := callOK(c, "mount", MountArgs{NoFileLock: true}); err == nil {
		_ = ensureUnmounted([]*Client{c})
	}
	var fr FsckResult
	resp, err = a.Call("fsck", FsckArgs{})
	if e := decodeResult(a.Name, resp, err, &fr); e != nil {
		check(&ok, "fsck ran", false, e.Error())
	} else {
		check(&ok, "fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, firstLine(fr.Output)))
	}
	if ok {
		fmt.Printf("PASS: replay-after-truncate\n")
	} else {
		fmt.Printf("FAIL: replay-after-truncate: see failed checks above\n")
	}
	return ok, nil
}
