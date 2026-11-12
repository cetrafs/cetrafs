// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// RunGrowTwice: two live grows in a row while a peer streams a VM image
// into the space they add.
//
// grow-live covers one grow on a volume that never fills. Not run there:
// a SECOND grow (its descriptors chain onto the first grow's tail -- the
// tail-link swap), a node streaming one large open file through both
// grows, and a Zone Group claiming the new pool Block Groups while the
// layout that adds them is being published on that node
// (cetrafs_layout_publish() vs cetrafs_sb_owned_bgs_derive(), both under
// owned_lock). Nothing here makes the two overlap or checks that they
// did; the overlap is forced, with a control, in
// tests/kernel/grow_live_owned_race.sh.
//
// The volume is rebuilt small (4 GiB, 512 MiB groups, two Zone Groups)
// and B fills what it can allocate until ENOSPC, then frees 512 MiB. B
// then opens vm.img and writes
// into it through one held fd, fsync per 4 MiB chunk, while A
// grows the volume to 6 GiB and then to 8 GiB. B's writes can only land
// if B adopts each grow and claims the groups it adds as they appear;
// it streams until it has adopted the second grow and then 256 MiB
// more, so part of the image can only live in that grow. The heartbeat refresh is
// off on B while it streams, so only the ENOSPC refresh can adopt a
// grow; it is turned back on afterwards for the catch-up check.
// Then: both nodes at layout_gen +2 with the same capacity, every chunk
// of the image reads back on A, fsck clean. The LUN is reformatted to
// its full size afterwards.
func RunGrowTwice(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return skipScenario("grow-twice needs two nodes")
	}
	a, b := clients[0], clients[1]
	two := []*Client{a, b}
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
	control := os.Getenv("CTEST_GROW_CONTROL") != ""
	knobs := [][2]string{{"layout_refresh_hb_off", "1"}}
	if control {
		knobs = append(knobs, [2]string{"alloc_enospc_refresh_off", "1"})
	}
	defer func() {
		for _, kv := range knobs {
			_ = callOK(b, "mod_param", ModParamArgs{Name: kv[0], Value: "0"})
		}
		_ = ensureUnmounted(clients)
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
	if err := mountAllDefault(two); err != nil {
		return false, err
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
	statfsOf := func(c *Client) StatfsResult {
		resp, err := c.Call("statfs", struct{}{})
		var r StatfsResult
		_ = decodeResult(c.Name, resp, err, &r)
		return r
	}
	growTo := func(size string) (MkfsResult, error) {
		resp, err := a.Call("growfs", GrowfsArgs{Size: size})
		var r MkfsResult
		return r, decodeResult(a.Name, resp, err, &r)
	}

	ok := true
	dir := baseDir + "/grow-twice"
	fmt.Printf("=== grow-twice: %s grows the volume twice while %s streams a VM image into it ===\n", a.Name, b.Name)
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}
	// B fills what it can allocate (its own Zone Groups; statfs counts
	// the whole volume, which B cannot reach) until ENOSPC.
	const fill = 64 << 20
	var fills []string
	for i := 0; i < 200; i++ {
		p := fmt.Sprintf("%s/fill-%d", dir, i)
		err := callOK(b, "write", WriteArgs{Path: p, Size: fill, Stamp: "fill"})
		if err != nil {
			if !strings.Contains(strings.ToLower(err.Error()), "no space") {
				return false, fmt.Errorf("setup fill: %w", err)
			}
			_ = callOK(b, "unlink", UnlinkArgs{Path: p})
			break
		}
		fills = append(fills, p)
	}
	// 512 MiB of headroom: enough to keep streaming while both grows
	// publish (a few seconds), a third of the image -- the rest can only
	// land in what the grows add.
	if len(fills) < 8 {
		return false, fmt.Errorf("setup: %s wrote only %d fill files", b.Name, len(fills))
	}
	for _, p := range fills[len(fills)-8:] {
		if err := callOK(b, "unlink", UnlinkArgs{Path: p}); err != nil {
			return false, fmt.Errorf("setup unlink: %w", err)
		}
	}
	s0 := statfsOf(b)
	gen0a, gen0b := infoOf(a, "layout_gen"), infoOf(b, "layout_gen")
	fmt.Printf("  setup: %d MiB free of %d MiB; layout_gen %d/%d\n", int64(s0.AvailBlocks)*s0.BlockSize>>20,
		int64(s0.TotalBlocks)*s0.BlockSize>>20, gen0a, gen0b)

	// From here B can reach a grow only through the allocator's refresh
	// at ENOSPC: its heartbeat's refresh is off. The control turns that
	// off too, and B must then run out.
	for _, kv := range knobs {
		if err := callOK(b, "mod_param", ModParamArgs{Name: kv[0], Value: kv[1]}); err != nil {
			return false, err
		}
	}
	if control {
		fmt.Printf("  NEGATIVE CONTROL: alloc_enospc_refresh_off=1 on %s\n", b.Name)
	}
	img := dir + "/vm.img"
	resp, err := b.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdwr", Create: true})
	var oh OpenHoldResult
	if err := decodeResult(b.Name, resp, err, &oh); err != nil {
		return false, fmt.Errorf("%s: open vm.img: %w", b.Name, err)
	}
	// B streams until it has adopted the second grow, then 256 MiB more
	// into the space only that grow added. How much the first grow alone
	// leaves room for depends on which groups B claims, so the size is
	// not fixed; the cap bounds a node that never adopts it.
	const chunk = 4 << 20
	const maxBytes = 5632 << 20
	const after2 = (256 << 20) / chunk
	sums := make([]string, 0, maxBytes/chunk)
	var (
		werr error
		wg   sync.WaitGroup
	)
	wg.Add(1)
	go func() {
		defer wg.Done()
		left := -1
		for i := 0; i < maxBytes/chunk && left != 0; i++ {
			resp, err := b.Call("write_held", HeldIOArgs{Handle: oh.Handle, Offset: int64(i) * chunk, Size: chunk,
				Stamp: fmt.Sprintf("vm-%04d-", i)})
			var hr HeldIOResult
			if err := decodeResult(b.Name, resp, err, &hr); err != nil {
				werr = fmt.Errorf("chunk %d (%d MiB in): %w", i, i*chunk>>20, err)
				return
			}
			sums = append(sums, hr.Checksum)
			if left > 0 {
				left--
			} else if left < 0 && i%8 == 7 && infoOf(b, "layout_gen") == gen0b+2 {
				left = after2
			}
		}
	}()

	time.Sleep(time.Second)
	r1, err := growTo("6G")
	if err != nil || r1.ExitCode != 0 || !strings.Contains(r1.Stdout, "completed live") {
		check(&ok, "first live grow (4 -> 6 GiB)", false, fmt.Sprintf("%v %s", err, firstLine(r1.Stderr+r1.Stdout)))
	} else {
		check(&ok, "first live grow (4 -> 6 GiB)", true, "")
	}
	time.Sleep(3 * time.Second)
	r2, err := growTo("8G")
	if err != nil || r2.ExitCode != 0 || !strings.Contains(r2.Stdout, "completed live") {
		check(&ok, "second live grow (6 -> 8 GiB), chained on the first", false, fmt.Sprintf("%v %s", err, firstLine(r2.Stderr+r2.Stdout)))
	} else {
		check(&ok, "second live grow (6 -> 8 GiB), chained on the first", true, "")
	}
	wg.Wait()
	_ = callOK(b, "close", CloseArgs{Handle: oh.Handle})
	if control {
		check(&ok, "control: without the refresh at ENOSPC, "+b.Name+" runs out after the grows", werr != nil &&
			strings.Contains(werr.Error(), "no space"), fmt.Sprint(werr))
		return ok, nil
	}
	check(&ok, b.Name+" streamed the image through both grows", werr == nil, fmt.Sprint(werr))

	if werr == nil {
		gs := infoOf(b, "layout_gen")
		check(&ok, "setup: "+b.Name+" adopted the second grow while streaming (by the ENOSPC refresh)", gs == gen0b+2,
			fmt.Sprintf("B %d->%d", gen0b, gs))
	}
	// Hand B back its heartbeat refresh: the catch-up below is that path.
	_ = callOK(b, "mod_param", ModParamArgs{Name: "layout_refresh_hb_off", Value: "0"})
	deadline := time.Now().Add(60 * time.Second)
	for infoOf(b, "layout_gen") != gen0b+2 && time.Now().Before(deadline) {
		time.Sleep(time.Second)
	}
	g1a, g1b := infoOf(a, "layout_gen"), infoOf(b, "layout_gen")
	check(&ok, "both nodes at layout_gen +2", g1a == gen0a+2 && g1b == gen0b+2, fmt.Sprintf("A %d->%d B %d->%d", gen0a, g1a, gen0b, g1b))
	sa, sb := statfsOf(a), statfsOf(b)
	check(&ok, "both nodes report the same 8 GiB capacity", sa.TotalBlocks == sb.TotalBlocks &&
		int64(sa.TotalBlocks)*sa.BlockSize >= 7<<30, fmt.Sprintf("A %d B %d blocks", sa.TotalBlocks, sb.TotalBlocks))

	if werr == nil {
		bad := 0
		for i, want := range sums {
			resp, err := a.Call("read_at", ReadAtArgs{Path: img, Offset: int64(i) * chunk, Size: chunk})
			var rr ReadAtResult
			if decodeResult(a.Name, resp, err, &rr) != nil || rr.Checksum != want {
				bad++
			}
		}
		check(&ok, fmt.Sprintf("all %d chunks of the image read back on %s", len(sums), a.Name), bad == 0,
			fmt.Sprintf("%d bad", bad))
	}

	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	resp, err = a.Call("fsck", FsckArgs{})
	var fr FsckResult
	if err := decodeResult(a.Name, resp, err, &fr); err != nil {
		check(&ok, "fsck ran", false, err.Error())
	} else {
		check(&ok, "fsck clean after two live grows", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, firstLine(fr.Output)))
	}
	if ok {
		fmt.Printf("PASS: grow-twice\n")
	} else {
		fmt.Printf("FAIL: grow-twice: see failed checks above\n")
	}
	return ok, nil
}
