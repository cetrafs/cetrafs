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

// infoField reads one "key: value" line of c's procfs info as a string.
func infoField(c *Client, key string) string {
	var pr ProcRawResult
	resp, err := c.Call("proc_raw", ProcRawArgs{Device: c.Device})
	if decodeResult(c.Name, resp, err, &pr) != nil {
		return ""
	}
	for _, l := range strings.Split(pr.Info, "\n") {
		if v, found := strings.CutPrefix(l, key+": "); found {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// RunZgClaimVsReplay: a node's heartbeat does not wait inside a Zone
// Group takeover for a peer replaying the group's dead owner, and does
// not take the group before that replay is done.
//
// Taking a dead owner's Zone Group replays its journal first, and when a
// LIVE peer holds the replay claim the taker waits for it -- up to the
// claim cap, several stale windows. In the heartbeat that wait held the
// node's claim mutex and parked the whole maintenance pass behind it:
// sweeps, frees, every retry. The heartbeat now leaves the group for its
// next tick (zg_claim_replay_deferrals), and keeps an allocator's
// request for it standing.
//
// Two Zone Groups, three nodes: b and c own one each, a owns none, so
// a's heartbeat goes for the first group it can take. c dies with
// journal entries durable and not applied; b claims c's area and is held
// mid-replay (journal_replay_apply_pause_ms); a is kept out until then
// (journal_replay_refuse). While b is held, a's heartbeat passes must go
// on, its takeover must be deferred, and a must still own nothing: the
// group is taken only once b's replay is done.
//
// Control (CTEST_ZGCLAIM_CONTROL=1): a's heartbeat waits for the replay
// (zg_claim_always_waits) -- its passes must stop while b is held.
func RunZgClaimVsReplay(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 3 {
		return skipScenario("zg-claim-vs-replay needs a dead node and two survivors, have %d", len(clients))
	}
	control := os.Getenv("CTEST_ZGCLAIM_CONTROL") != ""
	a, b, c := clients[0], clients[1], clients[2]
	if err := ensureUnmounted(clients); err != nil {
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
		if err := mkfsOn(a); err != nil {
			fmt.Printf("WARNING: could not reformat the LUN to its full size: %v\n", err)
		}
	}()
	if err := mkfsOn(a, "-s", "4G", "-z", "2"); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	// b and c first: each claims one of the two groups, a gets none.
	if err := mountAllDefault([]*Client{b, c, a}); err != nil {
		return false, err
	}
	setClusterTiming(clients, 5, 15, false)
	restores = append(restores, func() { setClusterTiming(clients, defaultHBIntervalSecs, defaultStaleSecs, true) })
	if err := waitAdvertisedInterval(a, c, 5, 20*time.Second); err != nil {
		fmt.Printf("WARNING: %s\n", err)
	}

	ok := true
	pass := func(l string) { check(&ok, l, true, "") }
	dir := baseDir + "/zg-claim"
	img := dir + "/vm.img"
	fmt.Printf("=== zg-claim-vs-replay: %s dies dirty, %s replays it slowly, %s's heartbeat wants its group ===\n",
		c.Name, b.Name, a.Name)
	if control {
		fmt.Printf("  NEGATIVE CONTROL: %s's heartbeat waits for the replay\n", a.Name)
	}
	for _, cl := range []*Client{b, c} {
		if w := infoField(cl, "write_ready"); w != "yes" {
			check(&ok, "setup: "+cl.Name+" owns a zone group", false, "write_ready="+w)
			return ok, nil
		}
	}
	if w := infoField(a, "write_ready"); w != "no" {
		check(&ok, "setup: "+a.Name+" owns no zone group", false, "write_ready="+w)
		return ok, nil
	}
	pass("setup: " + b.Name + " and " + c.Name + " own a zone group each, " + a.Name + " none")
	var snapC ProcSnapshotResult
	resp, err := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
	if e := decodeResult(c.Name, resp, err, &snapC); e != nil {
		return false, fmt.Errorf("setup: %w", e)
	}
	cID := snapC.ThisNodeID

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
		r, err := modParams(a, "zg_claim_always_waits", "1")
		restores = append(restores, r)
		if err != nil {
			return false, fmt.Errorf("setup: %w", err)
		}
	}

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
	mark := fmt.Sprintf("ctest-zgclaim-%d", time.Now().UnixNano())
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
	pass("setup: " + c.Name + " stopped with journal entries durable and not applied")
	if err := callOK(c, "link_down", nil); err != nil {
		return false, fmt.Errorf("%s link_down: %w", c.Name, err)
	}
	linkDown = true
	if !waitSeenStale([]*Client{a, b}, 90*time.Second) {
		check(&ok, "setup: "+a.Name+" and "+b.Name+" see "+c.Name+" stale", false, "never went stale")
		return ok, nil
	}
	if !waitDmesg(b, mark, "journal replay: pausing", 60*time.Second) {
		check(&ok, "setup: "+b.Name+" is replaying "+c.Name+"'s journal", false, "no 'journal replay: pausing' on "+b.Name)
		return ok, nil
	}
	pass("setup: " + b.Name + " holds the replay claim on " + c.Name + "'s journal and is paused in it")

	_ = callOK(a, "mod_param", ModParamArgs{Name: "journal_replay_refuse", Value: "0"})
	s0, err := infoCounter(a, "hb_sweeps")
	if err != nil {
		return false, err
	}
	d0, err := infoCounter(a, "zg_claim_replay_deferrals")
	if err != nil {
		return false, err
	}
	time.Sleep(4 * time.Second)
	s1, _ := infoCounter(a, "hb_sweeps")
	time.Sleep(15 * time.Second)
	s2, _ := infoCounter(a, "hb_sweeps")
	d2, _ := infoCounter(a, "zg_claim_replay_deferrals")
	wr := infoField(a, "write_ready")
	// The pause is per entry: c's area stays dirty until b has redone
	// them all.
	if journalState(a, cID) != 1 {
		check(&ok, "setup: "+b.Name+" was still held for the whole measurement", false,
			"its replay ended early -- nothing below is measured")
		return ok, nil
	}
	if control {
		check(&ok, fmt.Sprintf("control: with the takeover waiting, %s's heartbeat passes stop (%d -> %d over 15 s)",
			a.Name, s1, s2), s2 <= s1, "they went on -- the scenario cannot tell the two apart")
	} else {
		check(&ok, fmt.Sprintf("%s's heartbeat passes go on while %s replays (%d -> %d -> %d)", a.Name, b.Name, s0, s1, s2),
			s2 >= s1+2, "the maintenance pass is parked behind the takeover")
		check(&ok, fmt.Sprintf("%s's takeover was left for a later tick (%d deferrals)", a.Name, d2-d0),
			d2 > d0, "no deferral counted -- the takeover never met the replay")
	}
	check(&ok, a.Name+" took no zone group while "+b.Name+" was replaying its owner", wr == "no",
		"write_ready="+wr+" -- the group was taken under the replay")

	// Once b is done, a's next tick takes the group. b's later entries
	// go unpaused.
	_ = callOK(b, "mod_param", ModParamArgs{Name: "journal_replay_apply_pause_ms", Value: "0"})
	took := false
	for i := 0; i < 120 && !took; i++ {
		took = infoField(a, "write_ready") == "yes"
		if !took {
			time.Sleep(time.Second)
		}
	}
	check(&ok, a.Name+" takes "+c.Name+"'s zone group once "+b.Name+"'s replay is done", took, "it still owns none")

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
		fmt.Printf("PASS: zg-claim-vs-replay\n")
	} else {
		fmt.Printf("FAIL: zg-claim-vs-replay: see failed checks above\n")
	}
	return ok, nil
}

// RunReaderReattach: a write-open reclaiming a dead reader's presence
// bit does not take the bit that reader's NEXT incarnation stamped.
//
// A write-open that finds a stale node's reader bit fences the node and
// clears the bit. If the node re-attaches and opens the file again
// before that clear lands, the bit is a live reader's. The swap used to
// compare the row number only, re-read the row afterwards and give the
// bit back if it had beaten -- which also gave a bit back to a node that
// re-attached WITHOUT re-opening (01554cb, then F10). Every presence bit
// now records the incarnation that stamped it and the clear takes only
// the one it judged (format 0x000A). Staged single-node by poking a
// registry row (reclaim_incarnation.sh); this is the real thing.
//
// b reads f and drops off the device; a's write-open fences b and is
// held just before its clear (reclaim_stall_before_swap_ms). b comes
// back as a fresh mount -- a new incarnation, its re-attach sweep
// clearing the old bit -- and opens f for read again. When a's clear
// lands it must find the new incarnation's bit and refuse the write-open
// (ETXTBSY): b is reading.
//
// Control (CTEST_READER_CONTROL=1): the clear takes b's bit whatever
// incarnation stamped it (lock_reader_clear_any_incarnation) -- a's
// write-open succeeds under b's live read.
func RunReaderReattach(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return skipScenario("reader-reattach needs two nodes, have %d", len(clients))
	}
	control := os.Getenv("CTEST_READER_CONTROL") != ""
	a, b := clients[0], clients[1]
	two := []*Client{a, b}
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	if err := mountAllDefault(two); err != nil {
		return false, err
	}
	var restores []func()
	linkDown := false
	var handles [][2]any // {client, handle}
	defer func() {
		for i := len(restores) - 1; i >= 0; i-- {
			restores[i]()
		}
		for _, h := range handles {
			_, _ = h[0].(*Client).Call("close", CloseArgs{Handle: h[1].(uint64)})
		}
		if linkDown {
			if _, err := b.Call("link_up", nil); err != nil {
				fmt.Printf("WARNING: could not restore %s's device: %v\n", b.Name, err)
			}
		}
		_ = ensureUnmounted(clients)
	}()
	setClusterTiming(two, 5, 15, false)
	restores = append(restores, func() { setClusterTiming(two, defaultHBIntervalSecs, defaultStaleSecs, true) })
	if err := waitAdvertisedInterval(a, b, 5, 20*time.Second); err != nil {
		fmt.Printf("WARNING: %s\n", err)
	}

	ok := true
	pass := func(l string) { check(&ok, l, true, "") }
	dir := baseDir + "/reader-reattach"
	f := dir + "/f"
	fmt.Printf("=== reader-reattach: %s reads f and dies, %s's write-open clears it while %s comes back and reads again ===\n",
		b.Name, a.Name, b.Name)
	if control {
		fmt.Printf("  NEGATIVE CONTROL: %s's clear takes %s's bit whatever incarnation stamped it\n", a.Name, b.Name)
	}
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}
	var oh OpenHoldResult
	resp, err := a.Call("open_hold", OpenHoldArgs{Path: f, Mode: "rdwr", Create: true})
	if e := decodeResult(a.Name, resp, err, &oh); e != nil {
		return false, fmt.Errorf("setup: %s create: %w", a.Name, e)
	}
	if err := callOK(a, "write_held", HeldIOArgs{Handle: oh.Handle, Offset: 0, Size: 4096, Stamp: "f-"}); err != nil {
		return false, fmt.Errorf("setup: %s write: %w", a.Name, err)
	}
	if err := callOK(a, "close", CloseArgs{Handle: oh.Handle}); err != nil {
		return false, fmt.Errorf("setup: %s close: %w", a.Name, err)
	}
	openRead := func() (uint64, error) {
		var r OpenHoldResult
		resp, err := b.Call("open_hold", OpenHoldArgs{Path: f, Mode: "rdonly"})
		if e := decodeResult(b.Name, resp, err, &r); e != nil {
			return 0, e
		}
		handles = append(handles, [2]any{b, r.Handle})
		return r.Handle, nil
	}
	hB, err := openRead()
	if err != nil {
		return false, fmt.Errorf("setup: %s read-open: %w", b.Name, err)
	}

	// b's next mount: its re-attach watches its old row for b's stale
	// window, a module default -- the compressed one, not 120 s.
	if r, err := modParams(b, "stale_secs", "15", "hb_interval_secs", "5"); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	} else {
		restores = append(restores, r)
	}
	if err := callOK(b, "link_down", nil); err != nil {
		return false, fmt.Errorf("%s link_down: %w", b.Name, err)
	}
	linkDown = true
	if !waitSeenStale([]*Client{a}, 90*time.Second) {
		check(&ok, "setup: "+a.Name+" sees "+b.Name+" stale", false, "never went stale")
		return ok, nil
	}
	pass("setup: " + b.Name + " holds f open for read and is stale to " + a.Name)

	const stall = 60 * time.Second
	if control {
		r, err := modParams(a, "lock_reader_clear_any_incarnation", "1")
		restores = append(restores, r)
		if err != nil {
			return false, fmt.Errorf("setup: %w", err)
		}
	}
	r, err := modParams(a, "reclaim_stall_before_swap_ms", fmt.Sprint(stall.Milliseconds()))
	restores = append(restores, r)
	if err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	// The open runs on a second connection: one connection carries one
	// request at a time, and the probes below would queue behind it.
	conns, closeConns, err := a.Parallel(2, 10*time.Second)
	if err != nil {
		return false, err
	}
	defer closeConns()
	var openErr error
	var aHandle uint64
	openDone := make(chan struct{})
	go func() {
		defer close(openDone)
		var h OpenHoldResult
		resp, err := conns[1].Call("open_hold", OpenHoldArgs{Path: f, Mode: "rdwr"})
		openErr = decodeResult(a.Name, resp, err, &h)
		aHandle = h.Handle
	}()
	time.Sleep(3 * time.Second)
	var mp ModParamResult
	resp, err = a.Call("mod_param", ModParamArgs{Name: "reclaim_stall_before_swap_ms", Value: "0"})
	_ = decodeResult(a.Name, resp, err, &mp)
	select {
	case <-openDone:
		check(&ok, "setup: "+a.Name+"'s write-open is held before its clear", false,
			fmt.Sprintf("it returned at once (%v)", openErr))
		if aHandle != 0 {
			handles = append(handles, [2]any{a, aHandle})
		}
		return ok, nil
	default:
	}
	if strings.TrimSpace(mp.Prev) != "0" {
		check(&ok, "setup: "+a.Name+"'s write-open is held before its clear", false,
			"the one-shot stall was not taken -- the open is waiting on something else")
		<-openDone
		return ok, nil
	}
	pass("setup: " + a.Name + "'s write-open fenced " + b.Name + " and is held before clearing its bit")

	// b comes back: a fresh mount, a new incarnation, and f open again.
	_, _ = b.Call("close", CloseArgs{Handle: hB}) // on a fenced mount: errors, but the fd goes
	if _, err := b.Call("link_up", nil); err != nil {
		return false, fmt.Errorf("%s link_up: %w", b.Name, err)
	}
	linkDown = false
	_ = ensureUnmounted([]*Client{b})
	t0 := time.Now()
	if err := mountAllDefault([]*Client{b}); err != nil {
		check(&ok, "setup: "+b.Name+" re-attaches", false, err.Error())
		<-openDone
		return ok, nil
	}
	_, rerr := openRead()
	stillHeld := false
	select {
	case <-openDone:
	default:
		stillHeld = true
	}
	if rerr != nil || !stillHeld {
		check(&ok, "setup: "+b.Name+" re-attached and read-opened f while "+a.Name+"'s clear was held", false,
			fmt.Sprintf("read-open %v, %s's open still held %v (re-attach took %s)", rerr, a.Name, stillHeld,
				time.Since(t0).Round(time.Second)))
		<-openDone
		return ok, nil
	}
	pass(fmt.Sprintf("setup: %s re-attached (%s) and read-opened f while %s's clear was held", b.Name,
		time.Since(t0).Round(time.Second), a.Name))

	<-openDone
	if aHandle != 0 {
		handles = append(handles, [2]any{a, aHandle})
	}
	busy := openErr != nil && strings.Contains(openErr.Error(), "text file busy")
	if control {
		check(&ok, "control: clearing whatever incarnation, "+a.Name+"'s write-open got f under "+b.Name+"'s live read",
			openErr == nil, fmt.Sprintf("it failed (%v) -- the scenario cannot tell the two apart", openErr))
	} else {
		check(&ok, a.Name+"'s write-open is refused: "+b.Name+"'s new open is a live reader", busy,
			fmt.Sprintf("open returned %v", openErr))
	}

	for _, h := range handles {
		_, _ = h[0].(*Client).Call("close", CloseArgs{Handle: h[1].(uint64)})
	}
	handles = nil
	_ = ensureUnmounted(two)
	var fr FsckResult
	resp, err = a.Call("fsck", FsckArgs{})
	if e := decodeResult(a.Name, resp, err, &fr); e != nil {
		check(&ok, "fsck ran", false, e.Error())
	} else {
		check(&ok, "fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, firstLine(fr.Output)))
	}
	if ok {
		fmt.Printf("PASS: reader-reattach\n")
	} else {
		fmt.Printf("FAIL: reader-reattach: see failed checks above\n")
	}
	return ok, nil
}

// thisNode returns c's own registry row as its snapshot shows it.
func thisNode(c *Client) (NodeInfo, error) {
	var snap ProcSnapshotResult
	resp, err := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
	if e := decodeResult(c.Name, resp, err, &snap); e != nil {
		return NodeInfo{}, e
	}
	for _, n := range snap.Nodes {
		if n.ThisNode {
			return n, nil
		}
	}
	return NodeInfo{}, fmt.Errorf("%s: no row of its own in the snapshot", c.Name)
}

// RunTwinWatch: a machine mounting with a live node's identity waits a
// whole stale window before it takes that node's row.
//
// A registry row carrying this machine's identity and not left cleanly
// is either this machine's own crashed mount or a TWIN -- a cloned VM,
// firmware without a unique UUID -- that is alive. The mount watches the
// row and takes it only if it does not beat. The watch was two
// advertised beats + 5 s (65 s at the default 30 s beat) where every
// peer waits the stale window before calling a node dead, and a node
// does not fence itself until three beats have failed: a twin whose
// beats stalled for 65..90 s was alive, unfenced, and had its row taken
// -- two machines running as one node. The watch now waits the stale
// window (a2c53e3), staged single-node only until now.
//
// a beats every 30 s (the longest interval allowed): the old watch is
// 65 s, a's lease 90 s. b reloads the module with a's node_uuid. Right
// after a renews, a's next tick is held 45 s before its renewal
// (hb_tick_stall_ms): 75 s of silence, past the old watch and short of
// a's lease. b mounts at once: its watch must see a beat again and
// refuse the mount.
//
// Control (CTEST_TWIN_CONTROL=1): b watches for the old window
// (twin_watch_short) -- it takes a's row and mounts.
func RunTwinWatch(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return skipScenario("twin-watch needs two machines, have %d", len(clients))
	}
	_ = baseDir
	control := os.Getenv("CTEST_TWIN_CONTROL") != ""
	a, b := clients[0], clients[1]
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	reloaded := false
	defer func() {
		_ = ensureUnmounted(clients)
		if reloaded {
			if err := callOK(b, "module_reload", ModuleReloadArgs{}); err != nil {
				fmt.Printf("WARNING: %s: could not reload the module plainly: %v\n", b.Name, err)
			}
		}
	}()
	if err := mountAllDefault([]*Client{a}); err != nil {
		return false, err
	}
	ok := true
	pass := func(l string) { check(&ok, l, true, "") }
	me, err := thisNode(a)
	if err != nil {
		return false, err
	}
	fmt.Printf("=== twin-watch: %s mounts with %s's identity (%s) while %s's beats stall 45 s ===\n",
		b.Name, a.Name, me.UUID, a.Name)
	if control {
		fmt.Printf("  NEGATIVE CONTROL: %s watches two beats + 5 s only\n", b.Name)
	}
	if err := callOK(b, "module_reload", ModuleReloadArgs{Params: []string{"node_uuid=" + me.UUID}}); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	reloaded = true
	if control {
		if err := callOK(b, "mod_param", ModParamArgs{Name: "twin_watch_short", Value: "1"}); err != nil {
			return false, fmt.Errorf("setup: %w", err)
		}
	}
	setClusterTiming([]*Client{a}, 30, 120, true)
	defer setClusterTiming([]*Client{a}, defaultHBIntervalSecs, defaultStaleSecs, false)
	mark := fmt.Sprintf("ctest-twin-%d", time.Now().UnixNano())
	for _, cl := range []*Client{a, b} {
		_ = callOK(cl, "dmesg_mark", DmesgMarkArgs{Marker: mark})
	}

	// Line the stall up with a renewal: a's NEXT tick holds 45 s, so its
	// row is silent for one interval plus that. Two renewals first: the
	// one already armed may still be at the old interval.
	seq0 := me.HBSeq
	var r0 time.Time
	for k := 0; k < 2; k++ {
		renewed := false
		for i := 0; i < 280 && !renewed; i++ {
			time.Sleep(250 * time.Millisecond)
			if n, err := thisNode(a); err == nil && n.HBSeq != seq0 {
				renewed = true
				seq0 = n.HBSeq
			}
		}
		if !renewed {
			check(&ok, "setup: "+a.Name+" renews its row", false, "hb_seq did not move in 70 s")
			return ok, nil
		}
	}
	r0 = time.Now()
	if err := callOK(a, "mod_param", ModParamArgs{Name: "hb_tick_stall_ms", Value: "45000"}); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	t0 := time.Now()
	resp, merr := b.Call("mount", MountArgs{})
	merr = decodeResult(b.Name, resp, merr, nil)
	took := time.Since(t0).Round(time.Second)
	_ = callOK(a, "mod_param", ModParamArgs{Name: "hb_tick_stall_ms", Value: "0"})

	bLog := dmesgSince(b, mark)
	if !strings.Contains(bLog, "carries this machine's identity and was not left cleanly") {
		check(&ok, "setup: "+b.Name+" found "+a.Name+"'s row under its own identity and watched it", false,
			fmt.Sprintf("no watch in its log (mount %v after %s)", merr, took))
		return ok, nil
	}
	// a must have stayed alive through its stall: past its lease (90 s
	// from that renewal) and not expired. (Under the control a is fenced
	// anyway once b takes its row -- for that, not for its lease.)
	if d := time.Until(r0.Add(100 * time.Second)); d > 0 {
		time.Sleep(d)
	}
	if aLog := dmesgSince(a, mark); strings.Contains(aLog, "lease expired") {
		check(&ok, "setup: "+a.Name+" stayed alive through its stall", false,
			"its lease expired -- the stall was longer than a's lease, nothing below is measured")
		return ok, nil
	}
	pass(fmt.Sprintf("setup: %s watched %s's row (from %s after its renewal) while %s stalled and stayed alive",
		b.Name, a.Name, t0.Sub(r0).Round(time.Millisecond), a.Name))

	if control {
		check(&ok, fmt.Sprintf("control: watching two beats + 5 s, %s took the live %s's row and mounted (%s)",
			b.Name, a.Name, took), merr == nil, fmt.Sprintf("the mount failed (%v) -- the scenario cannot tell the two apart", merr))
	} else {
		check(&ok, fmt.Sprintf("%s's mount is refused: the row beat again within the stale window (%s)", b.Name, took),
			merr != nil, "it mounted as "+a.Name+"'s twin")
	}
	_ = ensureUnmounted(clients)
	if err := callOK(b, "module_reload", ModuleReloadArgs{}); err != nil {
		fmt.Printf("WARNING: %s: could not reload the module plainly: %v\n", b.Name, err)
	}
	reloaded = false
	var fr FsckResult
	resp, err = a.Call("fsck", FsckArgs{})
	if e := decodeResult(a.Name, resp, err, &fr); e != nil {
		check(&ok, "fsck ran", false, e.Error())
	} else if !control {
		check(&ok, "fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, firstLine(fr.Output)))
	}
	if ok {
		fmt.Printf("PASS: twin-watch\n")
	} else {
		fmt.Printf("FAIL: twin-watch: see failed checks above\n")
	}
	return ok, nil
}
