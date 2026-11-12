package main

import (
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

// infoCounter reads one "key: value" line of this node's procfs info.
func infoCounter(c *Client, key string) (int64, error) {
	var pr ProcRawResult
	resp, err := c.Call("proc_raw", ProcRawArgs{Device: c.Device})
	if e := decodeResult(c.Name, resp, err, &pr); e != nil {
		return 0, e
	}
	for _, l := range strings.Split(pr.Info, "\n") {
		f := strings.Fields(l)
		if len(f) == 2 && f[0] == key+":" {
			return strconv.ParseInt(f[1], 10, 64)
		}
	}
	return 0, fmt.Errorf("%s: no %q in info -- module predates it", c.Name, key)
}

// RunZeroRange: fallocate(FALLOC_FL_ZERO_RANGE) zeroes written blocks in
// place (WRITE ZEROES, no free, no allocation), across nodes.
//
// In place means the extent tree does not change, so nothing about the
// file's layout tells a peer its cached data is stale. What only two
// nodes can show:
//
//  1. a peer that read the file before sees the zeros after, buffered
//     and direct -- its page cache is dropped by the change stamp, not
//     by a layout change;
//  2. a zero is refused while a peer holds the file: by the file lock
//     on a default mount, by the foreign-open check under nofilelock,
//     and the peer's data is untouched;
//  3. a node whose cached view of the file is out of date (a peer
//     shrank it and reused the space) zeroes only what the file holds
//     NOW: the in-place count is exactly the blocks inside the new
//     size, and the peer's new file -- written into the freed space --
//     reads back whole.
//
// Every zero asserts the in-place count, so a device without WRITE
// ZEROES (which takes the old punch + preallocate path) fails setup
// rather than passing on the path this does not test.
//
// No negative control for 1-3: no knob makes a node keep a stale page
// cache or extent tree, and part 3 cannot prove the new file landed in
// the freed blocks. These checks can only fail, never be shown able to.
// The in-place count in part 3 does discriminate a stale SIZE: a node
// clipping to the old size would zero twice as many blocks.
func RunZeroRange(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("zero-range needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	defer func() {
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
		stamp = "ZERO-A"
		other = "ZERO-O"
		never = "ZERO-NEVER-WRITTEN"
	)
	dir := baseDir + "/zero-range"
	img := dir + "/img"
	oth := dir + "/other"
	size := 32 * mib
	fmt.Printf("=== zero-range: ZERO_RANGE in place, %s <-> %s ===\n", a.Name, b.Name)
	ok := true

	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir %s: %w", dir, err)
	}
	all := func(n int64) []int64 {
		out := make([]int64, n/dioBlock)
		for i := range out {
			out[i] = int64(i) * dioBlock
		}
		return out
	}
	write := func(c *Client, path, st string, sz int64) error {
		if err := callOK(c, "write_at", WriteAtArgs{Path: path, Offset: 0, Size: 0, Create: true}); err != nil {
			return err
		}
		var res DioWriteResult
		resp, e := c.Call("dio_write", DioWriteArgs{Path: path, Offsets: all(sz), Stamp: st, Par: 16, Fsync: true})
		if e2 := decodeResult(c.Name, resp, e, &res); e2 != nil {
			return e2
		}
		if res.Failed > 0 {
			return fmt.Errorf("%d blocks failed, first: %s", res.Failed, res.FirstError)
		}
		return nil
	}
	if err := write(a, img, stamp, size); err != nil {
		return false, fmt.Errorf("%s: writing %s: %w", a.Name, img, err)
	}

	// The model: which blocks of img are zero, and its size.
	zeroed := map[int64]bool{}
	verify := func(c *Client, label string) {
		var must []int64
		nz := 0
		for off := int64(0); off < size; off += dioBlock {
			if zeroed[off] {
				nz++
			} else {
				must = append(must, off)
			}
		}
		for _, direct := range []bool{false, true} {
			how := "buffered"
			if direct {
				how = "direct"
			}
			var v VerifyBlocksResult
			resp, e := c.Call("verify_blocks", VerifyBlocksArgs{Path: img, Size: size, Direct: direct,
				Stamps: []string{stamp}, Forbidden: never, Must: []DioMust{{Stamp: stamp, Offsets: must}}})
			l := fmt.Sprintf("%s (%s read on %s)", label, how, c.Name)
			if err := decodeResult(c.Name, resp, e, &v); err != nil {
				check(&ok, l, false, err.Error())
				continue
			}
			check(&ok, l, v.Missing == 0 && v.Garbage == 0 && v.Forbidden == 0 && v.Valid[stamp] == len(must) && v.Zero == nz,
				fmt.Sprintf("valid %v zero %d (want %d) missing %d garbage %d of %d blocks; %s",
					v.Valid, v.Zero, nz, v.Missing, v.Garbage, v.Blocks, strings.Join(v.Details, "; ")))
		}
	}
	// zero runs one ZERO_RANGE on c and returns how many blocks it zeroed
	// in place; -1 on error.
	zero := func(c *Client, off, length int64, mode uint32) (int64, error) {
		z0, err := infoCounter(c, "zero_inplace_blocks")
		if err != nil {
			return -1, err
		}
		if err := callOK(c, "fallocate", FallocateArgs{Path: img, Offset: off, Length: length, Mode: mode}); err != nil {
			return -1, err
		}
		z1, err := infoCounter(c, "zero_inplace_blocks")
		if err != nil {
			return -1, err
		}
		return z1 - z0, nil
	}
	mark := func(off, length int64) {
		for o := off; o < off+length && o < size; o += dioBlock {
			zeroed[o] = true
		}
	}

	// --- 1. both nodes read it; b zeroes; a sees zeros ---
	verify(a, "setup: the image reads back whole")
	verify(b, "setup: the image reads back whole")
	n, err := zero(b, 4*mib, 8*mib, fallocZeroRange|fallocKeepSize)
	if err != nil {
		return false, fmt.Errorf("%s: zero 4..12 MiB: %w", b.Name, err)
	}
	if n != 8*mib/dioBlock {
		check(&ok, "setup: the zero took the in-place path", false,
			fmt.Sprintf("zero_inplace_blocks moved by %d, want %d -- the device has no WRITE ZEROES, or the path changed", n, 8*mib/dioBlock))
		return ok, nil
	}
	check(&ok, fmt.Sprintf("1: %s zeroed 2048 blocks in place", b.Name), true, "")
	mark(4*mib, 8*mib)
	verify(a, "1: the peer that cached the data sees the zeros")
	verify(b, "1: the zeroing node sees them too")

	// --- 2a. default mount: refused while the peer holds the file ---
	var h OpenHoldResult
	resp, e := a.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdwr"})
	if err := decodeResult(a.Name, resp, e, &h); err != nil {
		return false, fmt.Errorf("%s: open_hold %s: %w", a.Name, img, err)
	}
	n, err = zero(b, 16*mib, 4*mib, fallocZeroRange|fallocKeepSize)
	check(&ok, fmt.Sprintf("2a: %s's zero is refused while %s holds the file (file lock)", b.Name, a.Name),
		err != nil && n == -1, fmt.Sprintf("err %v, %d blocks zeroed in place", err, n))
	if err := callOK(a, "close", CloseArgs{Handle: h.Handle}); err != nil {
		return false, fmt.Errorf("%s: close: %w", a.Name, err)
	}
	verify(a, "2a: and the file is untouched")

	// --- 2b. nofilelock: refused while the peer has it open to read ---
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	if err := mountAllNoFileLock(clients); err != nil {
		return false, err
	}
	resp, e = a.Call("open_hold", OpenHoldArgs{Path: img, Mode: "rdonly"})
	if err := decodeResult(a.Name, resp, e, &h); err != nil {
		return false, fmt.Errorf("%s: open_hold %s: %w", a.Name, img, err)
	}
	var hr HeldIOResult
	resp, e = a.Call("read_held", HeldIOArgs{Handle: h.Handle, Offset: 16 * mib, Size: int(4 * mib)})
	if err := decodeResult(a.Name, resp, e, &hr); err != nil {
		return false, fmt.Errorf("%s: read_held: %w", a.Name, err)
	}
	n, err = zero(b, 16*mib, 4*mib, fallocZeroRange|fallocKeepSize)
	check(&ok, fmt.Sprintf("2b: %s's zero is refused while %s reads the file (nofilelock)", b.Name, a.Name),
		err != nil && n == -1, fmt.Sprintf("err %v, %d blocks zeroed in place", err, n))
	var hr2 HeldIOResult
	resp, e = a.Call("read_held", HeldIOArgs{Handle: h.Handle, Offset: 16 * mib, Size: int(4 * mib)})
	if err := decodeResult(a.Name, resp, e, &hr2); err != nil {
		check(&ok, "2b: the reader's fd still reads", false, err.Error())
	} else {
		check(&ok, "2b: the reader's open fd reads the same data", hr2.Checksum == hr.Checksum,
			fmt.Sprintf("checksum %s -> %s", hr.Checksum, hr2.Checksum))
	}
	if err := callOK(a, "close", CloseArgs{Handle: h.Handle}); err != nil {
		return false, fmt.Errorf("%s: close: %w", a.Name, err)
	}
	verify(b, "2b: and the file is untouched")

	// Once the reader is gone the same zero goes through.
	n, err = zero(b, 16*mib, 4*mib, fallocZeroRange|fallocKeepSize)
	check(&ok, "2b: once the reader closed, the zero goes through in place",
		err == nil && n == 4*mib/dioBlock, fmt.Sprintf("err %v, %d blocks in place (want %d)", err, n, 4*mib/dioBlock))
	if err == nil {
		mark(16*mib, 4*mib)
	}
	verify(a, "2b: the reader that cached the data sees the zeros (nofilelock)")

	// --- 3. b's view of the file goes stale; it must zero only what is there now ---
	// b has img's tree cached from the zero above. a shrinks the file to
	// 16 MiB and writes a new file into the space that frees.
	if err := callOK(a, "truncate", TruncateArgs{Path: img, Size: 16 * mib}); err != nil {
		return false, fmt.Errorf("%s: truncate: %w", a.Name, err)
	}
	size = 16 * mib
	for o := range zeroed {
		if o >= size {
			delete(zeroed, o)
		}
	}
	if err := write(a, oth, other, 16*mib); err != nil {
		return false, fmt.Errorf("%s: writing %s: %w", a.Name, oth, err)
	}
	// 12..20 MiB with KEEP_SIZE: 12..16 is the file, 16..20 is past its end.
	n, err = zero(b, 12*mib, 8*mib, fallocZeroRange|fallocKeepSize)
	check(&ok, fmt.Sprintf("3: %s zeroes only the 1024 blocks inside the new size", b.Name),
		err == nil && n == 4*mib/dioBlock, fmt.Sprintf("err %v, %d blocks in place (want %d; %d means it used the old size)",
			err, n, 4*mib/dioBlock, 8*mib/dioBlock))
	if err == nil {
		mark(12*mib, 4*mib)
	}
	verify(a, "3: the shrunk image")
	for _, c := range []*Client{a, b} {
		for _, direct := range []bool{false, true} {
			var v VerifyBlocksResult
			resp, e := c.Call("verify_blocks", VerifyBlocksArgs{Path: oth, Size: 16 * mib, Direct: direct,
				Stamps: []string{other}, Forbidden: never, Must: []DioMust{{Stamp: other, Offsets: all(16 * mib)}}})
			l := fmt.Sprintf("3: the new file in the freed space is whole (direct=%v on %s)", direct, c.Name)
			if err := decodeResult(c.Name, resp, e, &v); err != nil {
				check(&ok, l, false, err.Error())
				continue
			}
			check(&ok, l, v.Missing == 0 && v.Zero == 0 && v.Garbage == 0 && v.Valid[other] == int(16*mib/dioBlock),
				fmt.Sprintf("valid %v zero %d missing %d garbage %d; %s", v.Valid, v.Zero, v.Missing, v.Garbage,
					strings.Join(v.Details, "; ")))
		}
	}

	// --- fsck ---
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
		fmt.Printf("PASS: zero-range: in place, visible across nodes, refused under a peer, never past what the file holds\n")
	}
	return ok, nil
}

// RunFstrimPool: the FITRIM pool pass on one node racing the other
// node's allocations.
//
// With discard off, a group emptied and handed back reaches the
// unowned pool still mapped; fstrim's pool pass then claims each such
// group into a Zone Group of its own, discards it, and hands it back.
// A peer allocating at the same moment claims groups out of the same
// pool. Both claims are a CAS on the group's descriptor, so exactly one
// of them may win any group. What only two nodes can show is that this
// holds against a real peer: the allocating node's data reads back
// whole on the other node, fstrim never fails, and the volume checks
// clean -- a group owned by both nodes, or handed back with data in it,
// is what fsck reports.
//
// Setup is asserted: each node must hand at least one group back
// undiscarded, and the pool pass must discard at least one group during
// the race, or the race did not happen. No negative control: the races
// this exercises are decided by the device's CAW, which no knob weakens.
func RunFstrimPool(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("fstrim-pool needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	defer func() {
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
		mib   = 1 << 20
		files = 8
		fsz   = 128 * mib
	)
	dir := baseDir + "/fstrim-pool"
	fmt.Printf("=== fstrim-pool: FITRIM's pool pass against a peer's allocations, %s <-> %s ===\n", a.Name, b.Name)
	ok := true
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir %s: %w", dir, err)
	}
	// Auto-defrag off: it is not what this tests, and a writer's
	// defrag of a file just written holds that file's lock, refusing
	// the peer's read-back (TODO.md, Availability: ETXTBSY after close).
	for _, c := range []*Client{a, b} {
		if err := callOK(c, "set_control", SetControlArgs{Key: "auto_defrag", Value: "off"}); err != nil {
			return false, fmt.Errorf("%s: auto_defrag=off: %w", c.Name, err)
		}
	}
	for _, c := range []*Client{a, b} {
		if err := callOK(c, "set_control", SetControlArgs{Key: "discard", Value: "off"}); err != nil {
			return false, fmt.Errorf("%s: discard=off: %w", c.Name, err)
		}
	}

	// Fill and delete on both nodes; wait for each to hand groups back.
	for _, c := range []*Client{a, b} {
		for i := 0; i < files; i++ {
			p := fmt.Sprintf("%s/fill-%s-%d", dir, c.Name, i)
			if err := callOK(c, "write", WriteArgs{Path: p, Size: fsz, Stamp: "FILL-" + c.Name}); err != nil {
				return false, fmt.Errorf("%s: fill %s: %w", c.Name, p, err)
			}
		}
	}
	marker := fmt.Sprintf("ctest-fstrim-pool-%d", time.Now().UnixNano())
	for _, c := range []*Client{a, b} {
		_ = callOK(c, "dmesg_mark", DmesgMarkArgs{Marker: marker})
		for i := 0; i < files; i++ {
			if err := callOK(c, "unlink", UnlinkArgs{Path: fmt.Sprintf("%s/fill-%s-%d", dir, c.Name, i)}); err != nil {
				return false, fmt.Errorf("%s: unlink: %w", c.Name, err)
			}
		}
	}
	for _, c := range []*Client{a, b} {
		handed := 0
		for deadline := time.Now().Add(5 * time.Minute); time.Now().Before(deadline); time.Sleep(5 * time.Second) {
			var t DmesgTailResult
			resp, err := c.Call("dmesg_tail", DmesgTailArgs{Lines: 5000, Since: marker})
			if decodeResult(c.Name, resp, err, &t) == nil {
				handed = strings.Count(t.Text, "handed back from ZG")
			}
			if handed > 0 {
				break
			}
		}
		if handed == 0 {
			check(&ok, fmt.Sprintf("setup: %s handed an emptied group back to the pool", c.Name), false,
				"no 'handed back from ZG' within 5 minutes")
			return ok, nil
		}
		check(&ok, fmt.Sprintf("setup: %s handed %d group(s) back with discard off", c.Name, handed), true, "")
	}
	for _, c := range []*Client{a, b} {
		if err := callOK(c, "set_control", SetControlArgs{Key: "discard", Value: "on"}); err != nil {
			return false, fmt.Errorf("%s: discard=on: %w", c.Name, err)
		}
	}

	// The race, both ways round: one node trims the pool while the other
	// writes enough to claim groups out of it.
	pooled := int64(0)
	for round, pair := range [][2]*Client{{a, b}, {b, a}} {
		trimmer, writer := pair[0], pair[1]
		h0, err := infoCounter(trimmer, "discard_handback_bgs")
		if err != nil {
			return false, err
		}
		var wg sync.WaitGroup
		var trimErr error
		var trimmed FstrimResult
		sums := make([]string, files)
		werrs := make([]error, files)
		wg.Add(2)
		go func() {
			defer wg.Done()
			resp, e := trimmer.Call("fstrim", FstrimArgs{})
			trimErr = decodeResult(trimmer.Name, resp, e, &trimmed)
		}()
		go func() {
			defer wg.Done()
			for i := 0; i < files; i++ {
				var wr WriteResult
				resp, e := writer.Call("write", WriteArgs{Path: fmt.Sprintf("%s/r%d-%d", dir, round, i), Size: fsz,
					Stamp: fmt.Sprintf("RACE-%d-%d", round, i)})
				werrs[i] = decodeResult(writer.Name, resp, e, &wr)
				sums[i] = wr.Checksum
			}
		}()
		wg.Wait()
		h1, err := infoCounter(trimmer, "discard_handback_bgs")
		if err != nil {
			return false, err
		}
		pooled += h1 - h0
		check(&ok, fmt.Sprintf("round %d: %s's fstrim succeeds while %s allocates (%d MiB trimmed, %d pool group(s))",
			round+1, trimmer.Name, writer.Name, trimmed.Bytes>>20, h1-h0), trimErr == nil, fmt.Sprint(trimErr))
		for i := 0; i < files; i++ {
			p := fmt.Sprintf("%s/r%d-%d", dir, round, i)
			if werrs[i] != nil {
				check(&ok, fmt.Sprintf("round %d: %s writes %s", round+1, writer.Name, p), false, werrs[i].Error())
				continue
			}
			var rr ReadResult
			resp, e := trimmer.Call("read", ReadArgs{Path: p})
			rerr := decodeResult(trimmer.Name, resp, e, &rr)
			if rerr != nil {
				check(&ok, fmt.Sprintf("round %d: %s reads %s", round+1, trimmer.Name, p), false, rerr.Error())
				continue
			}
			check(&ok, fmt.Sprintf("round %d: %s reads %s whole", round+1, trimmer.Name, p),
				rr.Size == fsz && rr.Checksum == sums[i], fmt.Sprintf("size %d checksum %s, written %s", rr.Size, rr.Checksum, sums[i]))
		}
	}
	check(&ok, fmt.Sprintf("setup: the pool pass discarded %d group(s) during the races", pooled), pooled > 0,
		"it found nothing to trim -- the race did not happen")

	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	var fr FsckResult
	resp, e := a.Call("fsck", FsckArgs{})
	if err := decodeResult(a.Name, resp, e, &fr); err != nil {
		check(&ok, "fsck ran", false, err.Error())
	} else {
		check(&ok, "fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, fr.Output))
	}
	if ok {
		fmt.Printf("PASS: fstrim-pool: the pool pass and a peer's claims never share a group\n")
	}
	return ok, nil
}

// RunHandbackUnknown: a peer allocating while a hand-back discard's
// outcome is unknown.
//
// An emptied Block Group is discarded and then published FREE. When the
// discard fails as a transport error does, nobody knows whether the
// UNMAP is still executing on the array, so the group must not reach
// the pool: it stays drained and marked pending, and only a later
// discard that completes publishes it. If it were published FREE
// anyway, a peer could claim it and write data that the late UNMAP
// then destroys. The scenario forces unknown outcomes on a
// (discard_fail_unknown) while it hands groups back, has b allocate
// heavily from the pool at the same time, then lets a's retry finish,
// and requires b's data to read back whole and fsck to be clean.
//
// Setup is asserted: a must count unknown hand-back outcomes and hold
// groups pending, or nothing was tested. No negative control: no knob
// publishes a pending group early.
func RunHandbackUnknown(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("handback-unknown needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	two := []*Client{a, b}
	failSet := false
	defer func() {
		if failSet {
			_ = callOK(a, "mod_param", ModParamArgs{Name: "discard_fail_unknown", Value: "0"})
		}
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	if err := mountAllDefault(two); err != nil {
		return false, err
	}
	const (
		mib   = 1 << 20
		files = 8
		fsz   = 128 * mib
	)
	dir := baseDir + "/handback-unknown"
	fmt.Printf("=== handback-unknown: %s's hand-back discards fail unknown while %s allocates ===\n", a.Name, b.Name)
	ok := true
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir %s: %w", dir, err)
	}
	for i := 0; i < files; i++ {
		if err := callOK(a, "write", WriteArgs{Path: fmt.Sprintf("%s/a%d", dir, i), Size: fsz, Stamp: "A"}); err != nil {
			return false, fmt.Errorf("%s: fill: %w", a.Name, err)
		}
	}
	u0, err := infoCounter(a, "discard_handback_unknown")
	if err != nil {
		return false, err
	}
	if err := callOK(a, "mod_param", ModParamArgs{Name: "discard_fail_unknown", Value: "1000000"}); err != nil {
		return false, fmt.Errorf("%s: discard_fail_unknown: %w", a.Name, err)
	}
	failSet = true
	for i := 0; i < files; i++ {
		if err := callOK(a, "unlink", UnlinkArgs{Path: fmt.Sprintf("%s/a%d", dir, i)}); err != nil {
			return false, fmt.Errorf("%s: unlink: %w", a.Name, err)
		}
	}
	// b allocates while a's hand-backs come back unknown.
	sums := map[string]string{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < files; i++ {
			p := fmt.Sprintf("%s/b%d", dir, i)
			var wr WriteResult
			resp, e := b.Call("write", WriteArgs{Path: p, Size: fsz, Stamp: fmt.Sprintf("B%d", i)})
			if decodeResult(b.Name, resp, e, &wr) == nil {
				mu.Lock()
				sums[p] = wr.Checksum
				mu.Unlock()
			}
		}
	}()
	unknown, pending := int64(0), int64(0)
	for t := time.Now(); time.Since(t) < 3*time.Minute; time.Sleep(2 * time.Second) {
		u, _ := infoCounter(a, "discard_handback_unknown")
		p, _ := infoCounter(a, "discard_pending_bgs")
		unknown = u - u0
		if p > pending {
			pending = p
		}
		if unknown > 0 && pending > 0 {
			break
		}
	}
	wg.Wait()
	check(&ok, fmt.Sprintf("setup: %s's hand-back discards came back unknown (%d) and held %d group(s) pending",
		a.Name, unknown, pending), unknown > 0 && pending > 0, "no unknown outcome -- nothing was tested")
	check(&ok, fmt.Sprintf("%s wrote all %d files meanwhile", b.Name, files), len(sums) == files, fmt.Sprintf("%d written", len(sums)))

	// The array answers again: the pending groups are discarded and published.
	_ = callOK(a, "mod_param", ModParamArgs{Name: "discard_fail_unknown", Value: "0"})
	failSet = false
	cleared := false
	for t := time.Now(); time.Since(t) < 5*time.Minute; time.Sleep(3 * time.Second) {
		if p, err := infoCounter(a, "discard_pending_bgs"); err == nil && p == 0 {
			cleared = true
			break
		}
	}
	check(&ok, fmt.Sprintf("%s's pending groups are discarded and handed back once discards work", a.Name), cleared,
		"still pending after 5 minutes")

	for p, sum := range sums {
		for _, c := range two {
			var rr ReadResult
			resp, e := c.Call("read", ReadArgs{Path: p})
			if err := decodeResult(c.Name, resp, e, &rr); err != nil {
				check(&ok, fmt.Sprintf("%s reads %s", c.Name, p), false, err.Error())
				continue
			}
			check(&ok, fmt.Sprintf("%s reads %s whole", c.Name, p), rr.Checksum == sum && rr.Size == fsz,
				fmt.Sprintf("size %d checksum %s, written %s", rr.Size, rr.Checksum, sum))
		}
	}
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	var fr FsckResult
	resp, e := a.Call("fsck", FsckArgs{})
	if err := decodeResult(a.Name, resp, e, &fr); err != nil {
		check(&ok, "fsck ran", false, err.Error())
	} else {
		check(&ok, "fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, fr.Output))
	}
	if ok {
		fmt.Printf("PASS: handback-unknown: a group whose discard may still run never reaches a peer\n")
	}
	return ok, nil
}
