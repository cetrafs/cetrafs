package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// RunLateFlush: a close that failed under nofilelock is finished later
// -- by the heartbeat, a sync or the unmount -- and that late write must
// not land over a peer that wrote the file in between.
//
// s preallocates vm.img in eight separate ranges (their extents live in
// one leaf block, past the four inline slots) and fsyncs a write into
// the last. Then it writes into range 0 with no fsync and closes with
// its tree flush failed (tree_flush_fail_once): the leaf edit stays held
// back and the close is queued for the heartbeat, whose maintenance pass
// is held off (hb_maint_delay_ms). d -- the VM restarted elsewhere --
// writes into range 1 and fsyncs: the same leaf, converted by d and
// written through d's journal. Then s's heartbeat finishes the close,
// writing the leaf it held back -- which predates d's conversion, so d's
// fsynced block read as preallocated zeros again (audit 2026-11-15
// BC-31; reproduced on two nodes before the fix).
//
//	setup: s's close failed and was queued; d's write landed first;
//	1. s's late flush finds the leaf changed and drops its set;
//	2. after both remount, d's block reads back what d wrote;
//	3. s's fsynced block reads back;
//	4. fsck is clean.
//
// Control (CTEST_LATE_FLUSH_CONTROL=1): s sets late_flush_blind, which
// writes the set without the check; 2 must fail.
//
// late-publish (inline): the same with nothing held back. One
// preallocated range, so the map is the record's inline extents; s's
// close fails its record publish (close_publish_fail) and d converts a
// unit further along. s's heartbeat publish carried its shadow's root
// over d's (audit 2026-11-15 BC-54, reproduced on two nodes before the
// fix); 1 is now the publish dropping its map. Control:
// stat_publish_root_over_peer.
func RunLateFlush(clients []*Client, baseDir string, inline bool) (bool, error) {
	name, knob, failKnob, failMsg, dropMsg := "late-flush", "late_flush_blind", "tree_flush_fail_once",
		"extent-tree blocks not durable", "changed on the device since this node held it back"
	if inline {
		name, knob, failKnob, failMsg, dropMsg = "late-publish", "stat_publish_root_over_peer", "close_publish_fail",
			"failed to persist inode state", "published the file's extent map after this node's pending one"
	}
	if len(clients) < 2 {
		return skipScenario("%s needs two nodes, have %d", name, len(clients))
	}
	control := os.Getenv("CTEST_LATE_FLUSH_CONTROL") != ""
	s, d := clients[0], clients[1]
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	if err := mountAllNoFileLock(clients[:2]); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	var restores []func()
	var sHandle, dHandle uint64
	defer func() {
		if sHandle != 0 {
			_, _ = s.Call("close", CloseArgs{Handle: sHandle})
		}
		if dHandle != 0 {
			_, _ = d.Call("close", CloseArgs{Handle: dHandle})
		}
		for i := len(restores) - 1; i >= 0; i-- {
			restores[i]()
		}
		_ = ensureUnmounted(clients)
	}()
	setClusterTiming(clients[:2], 5, 15, false)
	restores = append(restores, func() { setClusterTiming(clients[:2], defaultHBIntervalSecs, defaultStaleSecs, true) })
	param := func(cl *Client, kv ...string) error {
		r, err := modParams(cl, kv...)
		restores = append(restores, r)
		return err
	}

	ok := true
	pass := func(l string) { check(&ok, l, true, "") }
	dir := baseDir + "/" + name
	img := dir + "/vm.img"
	fmt.Printf("=== %s: %s's close fails, %s writes vm.img, %s's late write must not undo it ===\n",
		name, s.Name, d.Name, s.Name)
	if control {
		fmt.Printf("  NEGATIVE CONTROL: %s writes without the check (%s)\n", s.Name, knob)
		if err := param(s, knob, "1"); err != nil {
			return false, fmt.Errorf("setup: %w", err)
		}
	}
	_ = callOK(s, "unlink", UnlinkArgs{Path: img}) // an earlier run's
	if err := callOK(s, "mkdir", MkdirArgs{Path: dir}); err != nil && !strings.Contains(err.Error(), "exists") {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}

	const blk = 4096
	const rng = 16 * blk // one preallocated range; ranges start every 2*rng
	var oh OpenHoldResult
	resp, err := s.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdwr", Create: true})
	if e := decodeResult(s.Name, resp, err, &oh); e != nil {
		return false, fmt.Errorf("setup: %s open: %w", s.Name, e)
	}
	sHandle = oh.Handle
	ranges, rlen, sOff, dOff := 8, int64(rng), int64(7*2*rng+blk), int64(2*rng+blk)
	if inline {
		ranges, rlen, sOff, dOff = 1, 256*blk, 100*blk, 40*blk // one extent; d's unit is apart from s's
	}
	for i := 0; i < ranges; i++ {
		if err := callOK(s, "fallocate", FallocateArgs{Path: img, Offset: int64(i) * 2 * rng, Length: rlen}); err != nil {
			return false, fmt.Errorf("setup: %s fallocate %d: %w", s.Name, i, err)
		}
	}
	var sr HeldIOResult
	resp, err = s.Call("write_held", HeldIOArgs{Handle: sHandle, Offset: sOff, Size: blk, Stamp: "s-sync-"})
	if e := decodeResult(s.Name, resp, err, &sr); e != nil {
		return false, fmt.Errorf("setup: %s write: %w", s.Name, e)
	}

	// Keep the heartbeat's retry out until d has written; wait out a
	// pass already running without the delay.
	if err := param(s, "hb_maint_delay_ms", "25000"); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	time.Sleep(7 * time.Second)

	mark := fmt.Sprintf("ctest-lateflush-%d", time.Now().UnixNano())
	for _, cl := range clients[:2] {
		_ = callOK(cl, "dmesg_mark", DmesgMarkArgs{Marker: mark})
	}
	if err := callOK(s, "write_held", HeldIOArgs{Handle: sHandle, Offset: blk, Size: blk, Stamp: "s-late-",
		NoSync: true}); err != nil {
		return false, fmt.Errorf("setup: %s unsynced write: %w", s.Name, err)
	}
	if err := param(s, failKnob, "1"); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	_ = callOK(s, "close", CloseArgs{Handle: sHandle})
	sHandle = 0
	if !strings.Contains(dmesgSince(s, mark), failMsg) {
		check(&ok, "setup: "+s.Name+"'s close failed", false, "no '"+failMsg+"' in its dmesg")
		return ok, nil
	}
	pass("setup: " + s.Name + "'s close failed and was queued")

	// d: the VM restarted elsewhere, writing into the next range.
	resp, err = d.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdwr"})
	if e := decodeResult(d.Name, resp, err, &oh); e != nil {
		return false, fmt.Errorf("%s open: %w", d.Name, e)
	}
	dHandle = oh.Handle
	var dr HeldIOResult
	resp, err = d.Call("write_held", HeldIOArgs{Handle: dHandle, Offset: dOff, Size: blk, Stamp: "d-new-"})
	if e := decodeResult(d.Name, resp, err, &dr); e != nil {
		return false, fmt.Errorf("%s write: %w", d.Name, e)
	}
	_ = callOK(d, "close", CloseArgs{Handle: dHandle})
	dHandle = 0
	if strings.Contains(dmesgSince(s, mark), "finished by the heartbeat") {
		check(&ok, "setup: "+s.Name+"'s retry waited for "+d.Name+"'s write", false,
			"the heartbeat finished the close before "+d.Name+" wrote -- nothing to race")
		return ok, nil
	}
	pass("setup: " + d.Name + " wrote and fsynced while " + s.Name + "'s close was pending")

	// s's heartbeat finishes the close.
	if !waitDmesg(s, mark, "finished by the heartbeat", 60*time.Second) {
		check(&ok, "setup: "+s.Name+"'s heartbeat finished the close", false, "no 'finished by the heartbeat'")
		return ok, nil
	}
	sd := dmesgSince(s, mark)
	if control {
		fmt.Printf("  (control: %s's late flush ran without the check)\n", s.Name)
	} else {
		check(&ok, "1: "+s.Name+"'s late write found the file changed and dropped its own",
			strings.Contains(sd, dropMsg), "no drop message:\n"+indent(sd))
	}
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount: %w", err)
	}
	if err := mountAllNoFileLock(clients[:2]); err != nil {
		return false, fmt.Errorf("remount: %w", err)
	}
	readSum := func(c *Client, off int64) string {
		var rr ReadAtResult
		resp, err := c.Call("read_at", ReadAtArgs{Path: img, Offset: off, Size: blk})
		if e := decodeResult(c.Name, resp, err, &rr); e != nil {
			return "error: " + e.Error()
		}
		return rr.Checksum
	}
	got := readSum(s, dOff)
	check(&ok, "2: "+d.Name+"'s fsynced block reads back after "+s.Name+"'s late flush", got == dr.Checksum,
		fmt.Sprintf("got %s, want %s", got, dr.Checksum))
	got = readSum(d, sOff)
	check(&ok, "3: "+s.Name+"'s fsynced block reads back", got == sr.Checksum, fmt.Sprintf("got %s, want %s", got, sr.Checksum))

	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	var fr FsckResult
	resp, err = s.Call("fsck", FsckArgs{})
	if e := decodeResult(s.Name, resp, err, &fr); e != nil {
		check(&ok, "4: fsck ran", false, e.Error())
	} else {
		check(&ok, "4: fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, fr.Output))
	}
	return ok, nil
}

func indent(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i := range lines {
		lines[i] = "    " + lines[i]
	}
	return strings.Join(lines, "\n")
}
