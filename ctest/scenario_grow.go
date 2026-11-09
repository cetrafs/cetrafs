// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

// RunGrowLive: grow the volume on one node while another writes to it.
//
// The single-node suites (tests/kernel/grow_live*.sh) stage the peer
// with grow_skip_local_publish; this is the real one. Node A runs
// growfs.cetra on its mounted volume while node B streams files into
// it. Then:
//
//   - A is at the new layout_gen at once (it published);
//   - B reaches it within a few heartbeats (cetrafs_sb_layout_refresh()),
//     and both report the same capacity;
//   - every file B wrote before, during and after the grow reads back
//     intact from A;
//   - B can write past the capacity the volume had before the grow --
//     sized so it MUST claim one of the new pool Block Groups when the
//     old ones are full (asserted only when the old free space was small
//     enough to be crossed; otherwise reported, not passed);
//   - fsck is clean afterwards.
//
// Needs a shared device LARGER than the volume on it: format it with
// mkfs.cetra -s smaller than the device. Skips otherwise, saying so.
func RunGrowLive(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return skipScenario("grow-live needs two nodes")
	}
	a, b := clients[0], clients[1]
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	growOf := func(c *Client, dry bool) (MkfsResult, error) {
		resp, err := c.Call("growfs", GrowfsArgs{DryRun: dry})
		var r MkfsResult
		return r, decodeResult(c.Name, resp, err, &r)
	}
	infoOf := func(c *Client, key string) (uint64, error) {
		resp, err := c.Call("proc_raw", ProcRawArgs{Device: c.Device})
		var pr ProcRawResult
		if err := decodeResult(c.Name, resp, err, &pr); err != nil {
			return 0, err
		}
		for _, line := range strings.Split(pr.Info, "\n") {
			if strings.HasPrefix(line, key+":") {
				return strconv.ParseUint(strings.TrimSpace(strings.TrimPrefix(line, key+":")), 10, 64)
			}
		}
		return 0, fmt.Errorf("%s: no %q in procfs info", c.Name, key)
	}
	statfsOf := func(c *Client) (StatfsResult, error) {
		resp, err := c.Call("statfs", struct{}{})
		var r StatfsResult
		return r, decodeResult(c.Name, resp, err, &r)
	}

	plan, err := growOf(a, true)
	if err != nil {
		return false, err
	}
	if strings.Contains(plan.Stdout, "nothing to do") || plan.ExitCode != 0 {
		return skipScenario("the shared device has no room past the volume (format it with mkfs.cetra -s " +
			"smaller than the device to run grow-live): " + firstLine(plan.Stdout+plan.Stderr))
	}
	if !strings.Contains(plan.Stdout, "growing it live") {
		return false, fmt.Errorf("%s: a dry run on a mounted volume did not plan a live grow: %s", a.Name,
			firstLine(plan.Stdout))
	}

	ok := true
	resp, err := b.Call("mkdir", MkdirArgs{Path: baseDir})
	_ = decodeResult(b.Name, resp, err, nil) // may exist from an earlier run
	genA0, err := infoOf(a, "layout_gen")
	if err != nil {
		return false, err
	}
	genB0, err := infoOf(b, "layout_gen")
	if err != nil {
		return false, err
	}
	check(&ok, "both nodes start at the same layout_gen", genA0 == genB0, fmt.Sprintf("A=%d B=%d", genA0, genB0))
	sb0, err := statfsOf(b)
	if err != nil {
		return false, err
	}

	// B writes throughout the grow.
	const fileBytes = 16 << 20
	type written struct{ path, stamp string }
	var (
		mu    sync.Mutex
		files []written
		werr  error
		stop  = make(chan struct{})
		wg    sync.WaitGroup
	)
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			p := fmt.Sprintf("%s/during-%d", baseDir, i)
			st := fmt.Sprintf("grow-live-%d-", i)
			resp, err := b.Call("write", WriteArgs{Path: p, Size: fileBytes, Stamp: st})
			if err := decodeResult(b.Name, resp, err, nil); err != nil {
				mu.Lock()
				werr = err
				mu.Unlock()
				return
			}
			mu.Lock()
			files = append(files, written{p, st})
			mu.Unlock()
		}
	}()

	time.Sleep(2 * time.Second)
	res, err := growOf(a, false)
	time.Sleep(2 * time.Second)
	close(stop)
	wg.Wait()
	if err != nil {
		return false, err
	}
	check(&ok, "growfs grew the mounted volume live", res.ExitCode == 0 && strings.Contains(res.Stdout, "completed live"),
		firstLine(res.Stderr+res.Stdout))
	if werr != nil {
		check(&ok, "B kept writing through the grow", false, werr.Error())
	}
	genA1, _ := infoOf(a, "layout_gen")
	check(&ok, "the grower is at the new layout_gen at once", genA1 == genA0+1, fmt.Sprintf("%d -> %d", genA0, genA1))

	// B catches up on its heartbeat. CETRAFS heartbeats are seconds
	// apart; give it a few.
	var genB1 uint64
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if genB1, err = infoOf(b, "layout_gen"); err == nil && genB1 == genA1 {
			break
		}
		time.Sleep(time.Second)
	}
	check(&ok, "the other node caught up with the grow on its own", genB1 == genA1, fmt.Sprintf("B at %d, A at %d", genB1, genA1))
	sa, _ := statfsOf(a)
	sb1, _ := statfsOf(b)
	check(&ok, "both nodes report the same grown capacity", sa.TotalBlocks == sb1.TotalBlocks && sb1.TotalBlocks > sb0.TotalBlocks,
		fmt.Sprintf("before %d, A %d, B %d", sb0.TotalBlocks, sa.TotalBlocks, sb1.TotalBlocks))

	// Past the old capacity: B writes until it has used more than the
	// free space the volume had before the grow, so its last blocks must
	// come from a Block Group the grow added.
	oldFreeBytes := int64(sb0.FreeBlocks) * sb0.BlockSize
	if oldFreeBytes < 4<<30 {
		var past int64
		for i := 0; past <= oldFreeBytes+fileBytes; i++ {
			p := fmt.Sprintf("%s/after-%d", baseDir, i)
			st := fmt.Sprintf("grow-live-after-%d-", i)
			resp, err := b.Call("write", WriteArgs{Path: p, Size: fileBytes, Stamp: st})
			if err := decodeResult(b.Name, resp, err, nil); err != nil {
				check(&ok, "B writes past the capacity the volume had before the grow", false,
					fmt.Sprintf("after %d MiB: %v", past>>20, err))
				break
			}
			files = append(files, written{p, st})
			past += fileBytes
		}
		if past > oldFreeBytes {
			check(&ok, "B wrote past the capacity the volume had before the grow", true, "")
		}
	} else {
		fmt.Printf("  (the volume had %d MiB free before the grow -- too much to fill here; the new space was "+
			"not provably written)\n", oldFreeBytes>>20)
	}

	// Everything B wrote reads back on A.
	bad := 0
	for _, f := range files {
		resp, err := a.Call("read", ReadArgs{Path: f.path})
		var r ReadResult
		if err := decodeResult(a.Name, resp, err, &r); err != nil || r.Size != fileBytes ||
			r.Checksum != sha256Hex(buildStampedContent(f.stamp, fileBytes)) {
			bad++
		}
	}
	check(&ok, fmt.Sprintf("all %d files B wrote read back intact on A", len(files)), bad == 0 && len(files) > 0,
		fmt.Sprintf("%d bad", bad))
	for _, f := range files {
		resp, err := b.Call("unlink", UnlinkArgs{Path: f.path})
		_ = decodeResult(b.Name, resp, err, nil)
	}

	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	resp, err = a.Call("fsck", FsckArgs{})
	var fr FsckResult
	if err := decodeResult(a.Name, resp, err, &fr); err != nil {
		return false, err
	}
	check(&ok, "fsck is clean after the live grow", fr.Clean, firstLine(fr.Output))
	return ok, nil
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
