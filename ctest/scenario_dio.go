package main

import (
	"fmt"
	"math/rand"
	"strconv"
	"strings"
	"time"
)

// RunDirectWrite: O_DIRECT writes into holes and preallocated space,
// across nodes.
//
// Such a write leaves its blocks unwritten (they read as zeros) and the
// completion converts them once the data is on the device. What only
// two nodes can show:
//
//   - the conversion is what a PEER sees: a write converted on one node
//     reads back on the other, buffered and direct, and the blocks
//     around it read as zeros -- never as the data a deleted file left
//     there (the free space is seeded with a marker first);
//   - a peer takes over a file whose blocks the first node converted,
//     and writes into it directly in turn;
//   - a node cut off with direct writes in flight leaves a file in which
//     every block the peer reads is zeros or a complete write, never a
//     deleted file's data, and the peer can go on writing into it.
//
// The negative control turns the conversion off on the writer
// (dio_skip_convert) and requires the peer to see those blocks missing:
// without it, a verifier that never compared anything would pass too.
// The opposite direction -- a peer reading a deleted file's data -- has
// no control: no knob makes the module expose stale blocks, and the
// scenario does not prove the seeded blocks are the ones reused. That
// check can only fail, never be shown able to.
func RunDirectWrite(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("direct-write needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	a, b := clients[0], clients[1]
	linkRestored := true
	skipSet := false
	defer func() {
		if !linkRestored {
			if _, err := a.Call("link_up", nil); err != nil {
				fmt.Printf("WARNING: could not restore %s's device: %v\n", a.Name, err)
			}
		}
		if skipSet {
			_, _ = a.Call("mod_param", ModParamArgs{Name: "dio_skip_convert", Value: "0"})
		}
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	const (
		secret = "SECRET-DELETED-"
		mib    = int64(1) << 20
	)
	dir := baseDir + "/direct-write"
	img := dir + "/img"
	imgSize := 64 * mib
	fmt.Printf("=== direct write: O_DIRECT into holes and preallocated space, %s <-> %s ===\n", a.Name, b.Name)

	ok := true
	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}

	// Seed this node's free space with a marker: write a file, delete it.
	// The blocks a direct write is given next are likely these, and a
	// reader that sees the marker is reading a deleted file's data.
	for _, c := range []*Client{a, b} {
		p := dir + "/seed-" + c.Name
		if resp, err := c.Call("write", WriteArgs{Path: p, Size: int(128 * mib), Stamp: secret}); decodeResult(c.Name, resp, err, nil) != nil {
			return false, fmt.Errorf("%s: seeding free space failed", c.Name)
		}
		if resp, err := c.Call("unlink", UnlinkArgs{Path: p}); decodeResult(c.Name, resp, err, nil) != nil {
			return false, fmt.Errorf("%s: unlinking the seed failed", c.Name)
		}
	}

	// One permutation of the file's blocks, cut into disjoint sets.
	rnd := rand.New(rand.NewSource(20261104))
	perm := rnd.Perm(int(imgSize / dioBlock))
	take := func(n int) []int64 {
		out := make([]int64, n)
		for i := range out {
			out[i] = int64(perm[i]) * dioBlock
		}
		perm = perm[n:]
		return out
	}
	alpha, bravo, charlie := take(768), take(768), take(64)

	counters := func(c *Client) (fallbacks, converts int64, err error) {
		var pr ProcRawResult
		resp, e := c.Call("proc_raw", ProcRawArgs{Device: c.Device})
		if e2 := decodeResult(c.Name, resp, e, &pr); e2 != nil {
			return 0, 0, e2
		}
		fallbacks, converts = -1, -1
		for _, l := range strings.Split(pr.Info, "\n") {
			f := strings.Fields(l)
			if len(f) != 2 {
				continue
			}
			v, _ := strconv.ParseInt(f[1], 10, 64)
			switch f[0] {
			case "dio_fallbacks:":
				fallbacks = v
			case "dio_converts:":
				converts = v
			}
		}
		if fallbacks < 0 || converts < 0 {
			return 0, 0, fmt.Errorf("%s: no dio_fallbacks/dio_converts in info -- module predates direct fill", c.Name)
		}
		return fallbacks, converts, nil
	}

	// dioWrite runs one foreground batch and checks the module took the
	// direct path for every block of it.
	dioWrite := func(c *Client, path, stamp string, offs []int64, label string) bool {
		f0, c0, err := counters(c)
		if err != nil {
			check(&ok, label+": counters readable", false, err.Error())
			return false
		}
		var res DioWriteResult
		resp, e := c.Call("dio_write", DioWriteArgs{Path: path, Offsets: offs, Stamp: stamp, Par: 16, Fsync: true})
		if e2 := decodeResult(c.Name, resp, e, &res); e2 != nil || res.Failed > 0 {
			check(&ok, label, false, fmt.Sprintf("call error %v, %d failed, first: %s", e2, res.Failed, res.FirstError))
			return false
		}
		f1, c1, err := counters(c)
		if err != nil {
			check(&ok, label+": counters readable", false, err.Error())
			return false
		}
		check(&ok, label+": every block stayed direct", f1 == f0,
			fmt.Sprintf("dio_fallbacks %d -> %d: some went through the page cache", f0, f1))
		check(&ok, label+": and was converted on completion", c1-c0 >= int64(len(offs)),
			fmt.Sprintf("dio_converts %d -> %d for %d blocks -- the setup did not take the path under test", c0, c1, len(offs)))
		return true
	}

	verify := func(c *Client, path string, size int64, direct bool, stamps []string, must []DioMust) (VerifyBlocksResult, error) {
		var v VerifyBlocksResult
		resp, e := c.Call("verify_blocks", VerifyBlocksArgs{Path: path, Size: size, Direct: direct,
			Stamps: stamps, Forbidden: secret, Must: must})
		err := decodeResult(c.Name, resp, e, &v)
		return v, err
	}
	// verifyExact: every Must block is its writer's, everything else is zeros.
	verifyExact := func(c *Client, path string, size int64, must []DioMust, label string) {
		var stamps []string
		n := 0
		for _, m := range must {
			stamps = append(stamps, m.Stamp)
			n += len(m.Offsets)
		}
		for _, direct := range []bool{false, true} {
			how := "buffered"
			if direct {
				how = "direct"
			}
			v, err := verify(c, path, size, direct, stamps, must)
			if err != nil {
				check(&ok, fmt.Sprintf("%s (%s read on %s)", label, how, c.Name), false, err.Error())
				continue
			}
			valid := 0
			for _, k := range v.Valid {
				valid += k
			}
			check(&ok, fmt.Sprintf("%s (%s read on %s)", label, how, c.Name),
				v.Missing == 0 && v.Forbidden == 0 && v.Garbage == 0 && valid == n && v.Zero == v.Blocks-n,
				fmt.Sprintf("valid %v zero %d missing %d forbidden %d garbage %d of %d blocks; %s",
					v.Valid, v.Zero, v.Missing, v.Forbidden, v.Garbage, v.Blocks, strings.Join(v.Details, "; ")))
		}
	}

	// --- 1. a writes into holes and into preallocated space; b reads ---
	if resp, err := a.Call("write_at", WriteAtArgs{Path: img, Offset: 0, Size: 0, Create: true}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s: create %s", a.Name, img)
	}
	if resp, err := a.Call("truncate", TruncateArgs{Path: img, Size: imgSize}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s: truncate %s", a.Name, img)
	}
	if resp, err := a.Call("fallocate", FallocateArgs{Path: img, Offset: 16 * mib, Length: 16 * mib}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s: fallocate %s", a.Name, img)
	}
	if !dioWrite(a, img, "ALPHA", alpha, fmt.Sprintf("%s writes %d blocks directly", a.Name, len(alpha))) {
		return ok, nil
	}
	mustA := DioMust{Stamp: "ALPHA", Offsets: alpha}
	verifyExact(b, img, imgSize, []DioMust{mustA}, fmt.Sprintf("%s sees exactly %s's direct writes, zeros elsewhere", b.Name, a.Name))

	// --- 2. b takes the file over and writes into it directly ---
	if !dioWrite(b, img, "BRAVO", bravo, fmt.Sprintf("%s writes %d more blocks directly", b.Name, len(bravo))) {
		return ok, nil
	}
	mustB := DioMust{Stamp: "BRAVO", Offsets: bravo}
	verifyExact(a, img, imgSize, []DioMust{mustA, mustB}, fmt.Sprintf("%s sees both nodes' writes", a.Name))

	// --- 3. negative control: no conversion, and the peer must notice ---
	var mp ModParamResult
	resp, err := a.Call("mod_param", ModParamArgs{Name: "dio_skip_convert", Value: "1"})
	if e := decodeResult(a.Name, resp, err, &mp); e != nil {
		return false, fmt.Errorf("%s: cannot set dio_skip_convert: %v", a.Name, e)
	}
	skipSet = true
	var cres DioWriteResult
	resp, err = a.Call("dio_write", DioWriteArgs{Path: img, Offsets: charlie, Stamp: "CHARLIE", Par: 16, Fsync: true})
	cerr := decodeResult(a.Name, resp, err, &cres)
	if _, e := a.Call("mod_param", ModParamArgs{Name: "dio_skip_convert", Value: "0"}); e == nil {
		skipSet = false
	}
	if cerr != nil || cres.Failed > 0 {
		return false, fmt.Errorf("control write failed: %v %s", cerr, cres.FirstError)
	}
	v, err := verify(b, img, imgSize, false, []string{"ALPHA", "BRAVO", "CHARLIE"},
		[]DioMust{mustA, mustB, {Stamp: "CHARLIE", Offsets: charlie}})
	check(&ok, "control: with the conversion skipped, the peer reports those blocks missing",
		err == nil && v.Missing == len(charlie) && v.Valid["CHARLIE"] == 0,
		fmt.Sprintf("err %v, missing %d of %d, valid %v -- the verification cannot see a write that never became visible",
			err, v.Missing, len(charlie), v.Valid))

	// --- 4. a is cut off with direct writes in flight; b takes over ---
	img2 := dir + "/img2"
	img2Size := 1024 * mib
	if resp, err := a.Call("write_at", WriteAtArgs{Path: img2, Offset: 0, Size: 0, Create: true}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s: create %s", a.Name, img2)
	}
	if resp, err := a.Call("truncate", TruncateArgs{Path: img2, Size: img2Size}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s: truncate %s", a.Name, img2)
	}
	if resp, err := a.Call("fallocate", FallocateArgs{Path: img2, Offset: 256 * mib, Length: 64 * mib}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s: fallocate %s", a.Name, img2)
	}
	// DELTA, fsynced before the cut, lives in [0, 256M); the stream cut
	// mid-flight lives in [256M, 1G), over the preallocated range too,
	// so it can never overwrite what must survive. FOXTROT, the peer's
	// writes after the takeover, lands in the stream's region: into what
	// the dead node left unwritten, half-converted or written.
	split := 256 * mib
	rnd2 := rand.New(rand.NewSource(4))
	pick := func(lo, hi int64, n int) []int64 {
		p := rnd2.Perm(int((hi - lo) / dioBlock))
		out := make([]int64, n)
		for i := range out {
			out[i] = lo + int64(p[i])*dioBlock
		}
		return out
	}
	delta := pick(0, split, 256)
	foxtrot := pick(split, img2Size, 256)
	if !dioWrite(a, img2, "DELTA", delta, fmt.Sprintf("%s writes %d durable blocks", a.Name, len(delta))) {
		return ok, nil
	}

	setTiming := func(hb, stale string, staleFirst bool) {
		order := [][2]string{{"hb_interval_secs", hb}, {"stale_secs", stale}}
		if staleFirst {
			order = [][2]string{{"stale_secs", stale}, {"hb_interval_secs", hb}}
		}
		for _, c := range []*Client{a, b} {
			for _, kv := range order {
				resp, err := c.Call("set_control", SetControlArgs{Key: kv[0], Value: kv[1]})
				if e := decodeResult(c.Name, resp, err, nil); e != nil {
					fmt.Printf("WARNING: %s could not set %s=%s: %v\n", c.Name, kv[0], kv[1], e)
				}
			}
		}
	}
	timingSet := true
	restoreTiming := func() {
		if timingSet {
			setTiming(fmt.Sprintf("%d", defaultHBIntervalSecs), fmt.Sprintf("%d", defaultStaleSecs), true)
			timingSet = false
		}
	}
	setTiming("5", "15", false)
	defer restoreTiming()
	if err := waitAdvertisedInterval(b, a, 5, 20*time.Second); err != nil {
		fmt.Printf("WARNING: %s\n", err)
	}

	// A stream far longer than the few seconds before the cut, so writes
	// are in flight when the device goes. Never fsynced: what of it
	// survives is up to the crash, but every block must be whole or zero.
	var job DioWriteResult
	resp, err = a.Call("dio_write", DioWriteArgs{Path: img2, Count: 200000, Lo: split, Hi: img2Size, Seed: 7,
		Stamp: "ECHO", Par: 32, Background: true})
	if e := decodeResult(a.Name, resp, err, &job); e != nil {
		return false, fmt.Errorf("%s: starting the background stream: %v", a.Name, e)
	}
	var snapA ProcSnapshotResult
	resp, err = a.Call("proc_snapshot", ProcSnapshotArgs{Device: a.Device})
	if e := decodeResult(a.Name, resp, err, &snapA); e != nil {
		return false, fmt.Errorf("proc_snapshot on %s: %v", a.Name, e)
	}
	time.Sleep(3 * time.Second)
	var mid DioWriteResult
	resp, err = a.Call("dio_wait", DioWaitArgs{Job: job.Job, TimeoutSecs: 0})
	if e := decodeResult(a.Name, resp, err, &mid); e != nil || mid.Done {
		return false, fmt.Errorf("setup: the background stream was not still running at the cut (done=%v, err %v) -- nothing would be in flight", mid.Done, e)
	}
	fmt.Printf("--- %s: device offline with direct writes in flight\n", a.Name)
	linkRestored = false
	if resp, err := a.Call("link_down", nil); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s link_down failed", a.Name)
	}
	var end DioWriteResult
	resp, err = a.Call("dio_wait", DioWaitArgs{Job: job.Job, TimeoutSecs: 180})
	if e := decodeResult(a.Name, resp, err, &end); e != nil || !end.Done {
		fmt.Printf("WARNING: the stream on %s had not ended 180s after the cut (err %v)\n", a.Name, e)
	} else {
		fmt.Printf("    stream on %s: %d written before the cut, %d failed (%s)\n", a.Name, end.Written, end.Failed, end.FirstError)
		check(&ok, "the cut interrupted the stream", end.Failed > 0,
			"every write succeeded -- the device was not cut while writes were in flight")
	}

	stale := false
	for i := 0; i < 150 && !stale; i++ {
		var snapB ProcSnapshotResult
		resp, err := b.Call("proc_snapshot", ProcSnapshotArgs{Device: b.Device})
		if decodeResult(b.Name, resp, err, &snapB) == nil {
			for _, n := range snapB.Nodes {
				if n.Stale && n.ID == snapA.ThisNodeID {
					stale = true
				}
			}
		}
		if !stale {
			time.Sleep(time.Second)
		}
	}
	check(&ok, fmt.Sprintf("%s sees %s go stale", b.Name, a.Name), stale, "the peer never timed out")
	if stale {
		var h OpenHoldResult
		resp, err := b.Call("open_hold", OpenHoldArgs{Path: img2, Mode: "rdwr"})
		rErr := decodeResult(b.Name, resp, err, &h)
		check(&ok, fmt.Sprintf("%s takes over the file the cut node was writing", b.Name), rErr == nil,
			fmt.Sprintf("open refused: %v", rErr))
		if rErr == nil {
			_, _ = b.Call("close", CloseArgs{Handle: h.Handle})
		}
		mustD := DioMust{Stamp: "DELTA", Offsets: delta}
		for _, direct := range []bool{false, true} {
			v, err := verify(b, img2, img2Size, direct, []string{"DELTA", "ECHO"}, []DioMust{mustD})
			check(&ok, fmt.Sprintf("after the cut, every block %s reads (direct=%v) is zeros or a whole write, the fsynced ones intact", b.Name, direct),
				err == nil && v.Missing == 0 && v.Forbidden == 0 && v.Garbage == 0,
				fmt.Sprintf("err %v; valid %v zero %d missing %d forbidden %d garbage %d; %s",
					err, v.Valid, v.Zero, v.Missing, v.Forbidden, v.Garbage, strings.Join(v.Details, "; ")))
			if err == nil {
				fmt.Printf("    %d of the stream's blocks survived the cut, %d blocks read as zeros\n", v.Valid["ECHO"], v.Zero)
			}
		}
		// b writes into the dead node's file, holes and unconverted blocks alike.
		if dioWrite(b, img2, "FOXTROT", foxtrot, fmt.Sprintf("%s writes %d blocks into it directly", b.Name, len(foxtrot))) {
			v, err := verify(b, img2, img2Size, false, []string{"DELTA", "ECHO", "FOXTROT"},
				[]DioMust{mustD, {Stamp: "FOXTROT", Offsets: foxtrot}})
			check(&ok, "and they read back, with nothing else disturbed",
				err == nil && v.Missing == 0 && v.Forbidden == 0 && v.Garbage == 0,
				fmt.Sprintf("err %v; valid %v missing %d forbidden %d garbage %d; %s",
					err, v.Valid, v.Missing, v.Forbidden, v.Garbage, strings.Join(v.Details, "; ")))
		}
	}

	fmt.Printf("--- %s: device back\n", a.Name)
	if resp, err := a.Call("link_up", nil); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s link_up failed", a.Name)
	}
	linkRestored = true
	fenced := false
	for i := 0; i < 150 && !fenced; i++ {
		var s ProcSnapshotResult
		resp, err := a.Call("proc_snapshot", ProcSnapshotArgs{Device: a.Device})
		if decodeResult(a.Name, resp, err, &s) == nil && s.Fenced {
			fenced = true
		} else {
			time.Sleep(time.Second)
		}
	}
	check(&ok, fmt.Sprintf("%s fences itself once its device returns", a.Name), fenced,
		"a node whose lease was revoked went on as if it still owned the file")

	// Clean slate, then the volume must check clean. The timing lives
	// in the mount, so put it back while there is one.
	restoreTiming()
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	var fr FsckResult
	resp, err = a.Call("fsck", FsckArgs{})
	if e := decodeResult(a.Name, resp, err, &fr); e != nil {
		check(&ok, "fsck ran", false, e.Error())
	} else {
		// A cut node leaves blocks it allocated and never published --
		// leaked, reclaimed by the scrub, not damage. Anything that is
		// damage fails.
		fatal := stormFsckFatal(fr.Output)
		check(&ok, "fsck finds no damage afterwards", len(fatal) == 0,
			fmt.Sprintf("exit %d: %s", fr.ExitCode, strings.Join(fatal, "; ")))
		// Leave the volume as found. The cut node's allocated-but-never-
		// published blocks are leaks the scrub would reclaim later -- in
		// the middle of scrub-transit, whose whole assertion is that the
		// scrub reclaims nothing. Only once no damage was found.
		if len(fatal) == 0 && !fr.Clean {
			var rr FsckResult
			resp, err = a.Call("fsck", FsckArgs{Repair: true})
			if e := decodeResult(a.Name, resp, err, &rr); e != nil {
				fmt.Printf("WARNING: fsck -r could not run: %v\n", e)
			}
			resp, err = a.Call("fsck", FsckArgs{})
			e := decodeResult(a.Name, resp, err, &rr)
			check(&ok, "fsck -r reclaims what the cut left, and the volume checks clean", e == nil && rr.Clean,
				fmt.Sprintf("err %v, exit %d: %s", e, rr.ExitCode, rr.Output))
		}
	}
	if ok {
		fmt.Printf("PASS: direct write: converted on completion, visible across nodes, nothing stale after a cut\n")
	}
	return ok, nil
}
