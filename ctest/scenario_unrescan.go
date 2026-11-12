package main

import (
	"fmt"
	"os"
	"strings"
)

// RunGrowUnrescanned: a live grow while one node's device has not been
// rescanned.
//
// On a SAN the LUN is grown on the array, one host rescans and runs the
// grow, and the others see the bigger device only when they rescan. Until
// then a node cannot adopt the grown layout -- it would describe blocks
// its device does not have -- and a file a peer wrote into the new space
// lies past everything it knows. Reading it must fail with EIO ("cannot
// tell", cetrafs_lba_run_check()), never mark the file damaged: the
// address is valid on every node that has rescanned. Once this node
// rescans it catches up by itself and the same file reads and writes.
//
// B mounts a device-mapper view of the LUN exactly the size of the
// volume (view_device); A grows the volume from 4 to 6 GiB and writes a
// 2.5 GiB file, more than the old volume can hold, so some of it can only
// be in the new space. Then:
//   - B reads it: the chunks past its device fail, the rest read right,
//     its damage count does not move, and it is still at the old layout;
//   - B's view is grown to the whole LUN, live (the rescan): every chunk
//     reads back, B is at A's layout, nothing was counted as damage, and
//     B can write the file;
//   - fsck clean.
//
// Control (CTEST_UNRESCAN_CONTROL=1): B's heartbeat refresh and its
// on-demand refresh are off (layout_refresh_hb_off,
// layout_past_end_no_refresh), so the rescan alone must not make the file
// readable -- what makes it readable is B catching up.
func RunGrowUnrescanned(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return skipScenario("grow-unrescanned needs two nodes")
	}
	a, b := clients[0], clients[1]
	two := []*Client{a, b}
	control := os.Getenv("CTEST_UNRESCAN_CONTROL") != ""
	const volBytes = 4 << 30
	mkfs := func(extra ...string) error {
		var mr MkfsResult
		resp, e := a.Call("mkfs", MkfsArgs{Force: true, Extra: extra})
		if err := decodeResult(a.Name, resp, e, &mr); err != nil {
			return err
		}
		if mr.ExitCode != 0 {
			return fmt.Errorf("mkfs %v: exit %d: %s %s", extra, mr.ExitCode, mr.Stdout, mr.Stderr)
		}
		return nil
	}
	knobs := [][2]string{}
	if control {
		knobs = append(knobs, [2]string{"layout_refresh_hb_off", "1"}, [2]string{"layout_past_end_no_refresh", "1"})
	}
	defer func() {
		for _, kv := range knobs {
			_ = callOK(b, "mod_param", ModParamArgs{Name: kv[0], Value: "0"})
		}
		_ = ensureUnmounted(clients)
		_ = callOK(b, "view_device", ViewDeviceArgs{Sectors: -1})
		if err := mkfs(); err != nil {
			fmt.Printf("WARNING: could not reformat the LUN to its full size: %v\n", err)
		}
	}()
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	if err := mkfs("-s", "4G", "-b", "512", "-z", "2"); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	if err := callOK(b, "view_device", ViewDeviceArgs{Sectors: volBytes / 512}); err != nil {
		return false, fmt.Errorf("setup: %s's view of the LUN: %w", b.Name, err)
	}
	if err := mountAllDefault(two); err != nil {
		return false, fmt.Errorf("setup: mount (%s on a 4 GiB view): %w", b.Name, err)
	}
	infoOf := func(c *Client, key string) uint64 {
		resp, err := c.Call("proc_raw", ProcRawArgs{Device: c.Device})
		var pr ProcRawResult
		if decodeResult(c.Name, resp, err, &pr) != nil {
			return 0
		}
		for _, line := range strings.Split(pr.Info, "\n") {
			if strings.HasPrefix(line, key+":") {
				var v uint64
				fmt.Sscanf(strings.TrimSpace(strings.TrimPrefix(line, key+":")), "%d", &v)
				return v
			}
		}
		return 0
	}

	ok := true
	dir := baseDir + "/grow-unrescanned"
	img := dir + "/vm.img"
	fmt.Printf("=== grow-unrescanned: %s grows the volume while %s's device still has the old size ===\n", a.Name, b.Name)
	if control {
		fmt.Printf("  NEGATIVE CONTROL: %s's layout refreshes are off\n", b.Name)
	}
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}
	gen0b := infoOf(b, "layout_gen")
	var gr MkfsResult
	resp, err := a.Call("growfs", GrowfsArgs{Size: "6G"})
	if err := decodeResult(a.Name, resp, err, &gr); err != nil || gr.ExitCode != 0 || !strings.Contains(gr.Stdout, "completed live") {
		return false, fmt.Errorf("setup: the live grow failed: %v %s", err, firstLine(gr.Stderr+gr.Stdout))
	}
	pass := func(label string) { check(&ok, label, true, "") }
	pass("setup: " + a.Name + " grew the volume to 6 GiB live")

	// A writes 2.5 GiB: more than the old volume holds.
	const chunk = 4 << 20
	const n = (2560 << 20) / chunk
	resp, err = a.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdwr", Create: true})
	var oh OpenHoldResult
	if err := decodeResult(a.Name, resp, err, &oh); err != nil {
		return false, fmt.Errorf("%s: open vm.img: %w", a.Name, err)
	}
	sums := make([]string, n)
	for i := 0; i < n; i++ {
		resp, err := a.Call("write_held", HeldIOArgs{Handle: oh.Handle, Offset: int64(i) * chunk, Size: chunk,
			Stamp: fmt.Sprintf("img-%04d-", i)})
		var hr HeldIOResult
		if err := decodeResult(a.Name, resp, err, &hr); err != nil {
			_ = callOK(a, "close", CloseArgs{Handle: oh.Handle})
			return false, fmt.Errorf("setup: %s writing chunk %d: %w", a.Name, i, err)
		}
		sums[i] = hr.Checksum
	}
	if err := callOK(a, "close", CloseArgs{Handle: oh.Handle}); err != nil {
		return false, fmt.Errorf("setup: %s close: %w", a.Name, err)
	}
	pass(fmt.Sprintf("setup: %s wrote %d MiB into the grown volume", a.Name, n*chunk>>20))

	readAll := func(c *Client) (good, eio, wrong int, first string) {
		for i := 0; i < n; i++ {
			resp, err := c.Call("read_at", ReadAtArgs{Path: img, Offset: int64(i) * chunk, Size: chunk})
			var rr ReadAtResult
			if e := decodeResult(c.Name, resp, err, &rr); e != nil {
				if strings.Contains(strings.ToLower(e.Error()), "input/output") {
					eio++
				} else {
					wrong++
				}
				if first == "" {
					first = fmt.Sprintf("chunk %d: %v", i, e)
				}
				continue
			}
			if rr.Checksum != sums[i] {
				wrong++
				if first == "" {
					first = fmt.Sprintf("chunk %d: wrong content", i)
				}
				continue
			}
			good++
		}
		return
	}

	// --- before the rescan
	dmg0 := infoOf(b, "corruptions")
	good, eio, wrong, first := readAll(b)
	if eio == 0 {
		check(&ok, "setup: some of the file lies past "+b.Name+"'s device", false,
			fmt.Sprintf("all %d chunks read on %s -- nothing landed in the new space", good, b.Name))
		return ok, nil
	}
	check(&ok, fmt.Sprintf("before the rescan %s reads the old space and gets EIO for the new (%d read, %d EIO)",
		b.Name, good, eio), wrong == 0, first)
	if !control {
		check(&ok, b.Name+" counted none of it as damage", infoOf(b, "corruptions") == dmg0,
			fmt.Sprintf("corruptions %d -> %d", dmg0, infoOf(b, "corruptions")))
	}
	check(&ok, b.Name+" is still at the old layout", infoOf(b, "layout_gen") == gen0b,
		fmt.Sprintf("layout_gen %d -> %d", gen0b, infoOf(b, "layout_gen")))

	// --- the rescan
	for _, kv := range knobs {
		if err := callOK(b, "mod_param", ModParamArgs{Name: kv[0], Value: kv[1]}); err != nil {
			return false, fmt.Errorf("control knob %s: %w", kv[0], err)
		}
	}
	if err := callOK(b, "view_device", ViewDeviceArgs{Sectors: 0}); err != nil {
		return false, fmt.Errorf("the rescan of %s's view: %w", b.Name, err)
	}
	good, eio, wrong, first = readAll(b)
	if control {
		check(&ok, "control: with its refreshes off, "+b.Name+" still cannot read the new space after the rescan",
			eio > 0 || wrong > 0, fmt.Sprintf("%d of %d chunks read", good, n))
		return ok, nil
	}
	check(&ok, fmt.Sprintf("after the rescan %s reads all %d chunks", b.Name, n), good == n,
		fmt.Sprintf("%d EIO, %d wrong; %s", eio, wrong, first))
	check(&ok, b.Name+" caught up to "+a.Name+"'s layout", infoOf(b, "layout_gen") == infoOf(a, "layout_gen"),
		fmt.Sprintf("%s %d, %s %d", b.Name, infoOf(b, "layout_gen"), a.Name, infoOf(a, "layout_gen")))
	check(&ok, "and counted nothing as damage", infoOf(b, "corruptions") == dmg0,
		fmt.Sprintf("corruptions %d -> %d", dmg0, infoOf(b, "corruptions")))
	resp, err = b.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdwr"})
	var bh OpenHoldResult
	if e := decodeResult(b.Name, resp, err, &bh); e != nil {
		check(&ok, b.Name+" can write the file (it was never marked damaged)", false, e.Error())
	} else {
		e := callOK(b, "write_held", HeldIOArgs{Handle: bh.Handle, Offset: int64(n-1) * chunk, Size: chunk, Stamp: "b-wrote"})
		_ = callOK(b, "close", CloseArgs{Handle: bh.Handle})
		check(&ok, b.Name+" can write the file (it was never marked damaged)", e == nil, fmt.Sprint(e))
	}

	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	resp, err = a.Call("fsck", FsckArgs{})
	var fr FsckResult
	if err := decodeResult(a.Name, resp, err, &fr); err != nil {
		check(&ok, "fsck ran", false, err.Error())
	} else {
		check(&ok, "fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, firstLine(fr.Output)))
	}
	if ok {
		fmt.Printf("PASS: grow-unrescanned\n")
	} else {
		fmt.Printf("FAIL: grow-unrescanned: see failed checks above\n")
	}
	return ok, nil
}
