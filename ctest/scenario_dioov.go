// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// RunDirectOverwrite: an O_DIRECT overwrite of written blocks, on one
// node, against a peer, under both lock modes.
//
// A block-aligned O_DIRECT overwrite of written blocks inside i_size runs
// under the SHARED inode_lock (kmod/file.c, cetrafs_dio_overwrite_write()),
// so a synchronous writer is not serialised against itself. What only two
// nodes can show is the boundary of that claim:
//
//   - default lock: the overwriting node holds the whole-file lock for the
//     length of the write, so the peer's open is refused while the overwrite
//     is in flight, and the peer's punch, truncate and write cannot run until
//     it has finished. Afterwards the peer reads every overwritten block as
//     the overwriter wrote it, and the peer's own changes read back on the
//     overwriter.
//   - nofilelock: the overwriter takes flock(LOCK_EX) first. The peer's open is
//     refused for as long as the lock is held, overwrites included; once the
//     overwriter unlocks, the peer's handoff sees exactly what was written.
//
// Both are checked against the counter the shared path bumps, so the
// overwrites are known to have run in their shared section and not beside
// it. Nothing here runs a peer's punch against an UNLOCKED overwrite under
// nofilelock: no lock stands between them in that mode, the exposure is the
// same as for the exclusive path, and a scenario cannot assert an outcome
// for it that the mode does not promise.
//
// There is no negative control at the cross-node level. Removing the local
// lock (dio_overwrite_nolock) leaves the peer's refusal unchanged, because the
// peer is refused by the cross-node lock, not by inode_lock; the local race
// control is tests/kernel/dio_overwrite_shared.sh.
func RunDirectOverwrite(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("direct-overwrite needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	const (
		blocks = 4096 // 16 MiB
		bs     = 4096
		punch  = 0x03 // FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE
	)
	dir := baseDir + "/direct-overwrite"
	path := dir + "/img"
	size := int64(blocks) * bs
	fmt.Printf("=== direct overwrite: O_DIRECT overwrites of written blocks, %s <-> %s ===\n", a.Name, b.Name)
	ok := true

	do := func(c *Client, op string, args any) error {
		resp, err := c.Call(op, args)
		return decodeResult(c.Name, resp, err, nil)
	}
	// overwriteCounter reads the shared-path count from procfs.
	overwriteCounter := func(c *Client) (int64, error) {
		var pr ProcRawResult
		resp, err := c.Call("proc_raw", ProcRawArgs{Device: c.Device})
		if err := decodeResult(c.Name, resp, err, &pr); err != nil {
			return 0, err
		}
		for _, l := range strings.Split(pr.Info, "\n") {
			f := strings.Fields(l)
			if len(f) == 2 && f[0] == "dio_overwrites:" {
				v, _ := strconv.ParseInt(f[1], 10, 64)
				return v, nil
			}
		}
		return 0, fmt.Errorf("%s: no dio_overwrites in info", c.Name)
	}
	allBlocks := func() []int64 {
		out := make([]int64, blocks)
		for i := range out {
			out[i] = int64(i) * bs
		}
		return out
	}
	every := func(step int) []int64 {
		var out []int64
		for i := 0; i < blocks; i += step {
			out = append(out, int64(i)*bs)
		}
		return out
	}
	// verifyDirect reads [0, size) on c and requires the stamped blocks to be
	// exactly must, the rest zeros, no forbidden data and no garbage.
	verifyDirect := func(c *Client, stamps []string, must []DioMust, direct bool) (VerifyBlocksResult, error) {
		var v VerifyBlocksResult
		resp, err := c.Call("verify_blocks", VerifyBlocksArgs{Path: path, Size: size, Direct: direct,
			Stamps: stamps, Forbidden: "SECRET-NEVER", Must: must})
		err = decodeResult(c.Name, resp, err, &v)
		return v, err
	}
	// runJob starts an overwrite of offs on c, one write in flight at a time
	// so the job is long enough for the peer to act while it runs, and
	// returns its handle.
	runJob := func(c *Client, offs []int64, stamp string) (uint64, error) {
		var r DioWriteResult
		resp, err := c.Call("dio_write", DioWriteArgs{Path: path, Offsets: offs, Stamp: stamp, Par: 1, Fsync: true, Background: true})
		if err := decodeResult(c.Name, resp, err, &r); err != nil {
			return 0, err
		}
		return r.Job, nil
	}
	// peerOpen tries a write-open on b; it returns whether it was allowed.
	peerOpen := func() (bool, string) {
		resp, err := b.Call("open_hold", OpenHoldArgs{Path: path, Mode: "rdwr"})
		if err != nil {
			return false, err.Error()
		}
		if resp.OK {
			var r OpenHoldResult
			_ = json.Unmarshal(resp.Result, &r)
			_, _ = b.Call("close", CloseArgs{Handle: r.Handle})
			return true, ""
		}
		return false, resp.Error
	}

	// ---- part 1: default lock ----
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("pre-unmount: %w", err)
	}
	if err := mountAllDefault(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()
	if err := do(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}
	fmt.Println("  -- default lock")
	var base DioWriteResult
	resp, err := a.Call("dio_write", DioWriteArgs{Path: path, Offsets: allBlocks(), Stamp: "BASE", Par: 16, Fsync: true, Create: true})
	if err := decodeResult(a.Name, resp, err, &base); err != nil || base.Failed > 0 {
		return false, fmt.Errorf("setup: writing the base image failed: %v (failed %d)", err, base.Failed)
	}
	v, err := verifyDirect(a, []string{"BASE"}, nil, true)
	if err != nil || v.Zero != 0 || v.Valid["BASE"] != blocks {
		return false, fmt.Errorf("setup: base image does not read back on %s: %v %+v", a.Name, err, v)
	}

	// The overwrite: every second block, held in flight while the peer tries.
	ow := every(2)
	c0, err := overwriteCounter(a)
	if err != nil {
		return false, err
	}
	job, err := runJob(a, ow, "OVW")
	if err != nil {
		return false, fmt.Errorf("%s: overwrite: %w", a.Name, err)
	}
	time.Sleep(300 * time.Millisecond)
	pre := DioWriteResult{}
	resp, e := a.Call("dio_wait", DioWaitArgs{Job: job, TimeoutSecs: 0})
	_ = decodeResult(a.Name, resp, e, &pre)
	if pre.Done {
		return false, fmt.Errorf("setup: the overwrite finished before the peer acted -- the window was not held")
	}
	got, e2 := peerOpen()
	check(&ok, "default lock: the peer's write-open is refused while the overwrite is in flight", !got,
		fmt.Sprintf("the peer was allowed to open: %s", e2))
	var fin DioWriteResult
	resp, e = a.Call("dio_wait", DioWaitArgs{Job: job, TimeoutSecs: 600})
	if err := decodeResult(a.Name, resp, e, &fin); err != nil || !fin.Done || fin.Failed > 0 {
		return false, fmt.Errorf("%s: overwrite did not finish cleanly: %v %+v", a.Name, err, fin)
	}
	c1, err := overwriteCounter(a)
	if err != nil {
		return false, err
	}
	check(&ok, fmt.Sprintf("default lock: the overwrite took the shared path (%d writes)", len(ow)),
		c1-c0 == int64(len(ow)),
		fmt.Sprintf("dio_overwrites moved %d for %d writes -- the setup did not take the path under test", c1-c0, len(ow)))

	// The peer reads the overwrite, buffered and direct, and the rest of
	// the image is the base.
	must := []DioMust{{Stamp: "OVW", Offsets: ow}}
	for _, direct := range []bool{true, false} {
		v, err := verifyDirect(b, []string{"BASE", "OVW"}, must, direct)
		label := fmt.Sprintf("default lock: the peer reads every overwritten block as written (direct=%v)", direct)
		check(&ok, label, err == nil && v.Missing == 0 && v.Forbidden == 0 && v.Garbage == 0 && v.Zero == 0 &&
			v.Valid["OVW"] == len(ow) && v.Valid["BASE"] == blocks-len(ow),
			fmt.Sprintf("err=%v %+v", err, v))
	}

	// The peer's turn: a punch and an overwrite of its own, which the
	// overwriter must then read back.
	if err := do(b, "fallocate", FallocateArgs{Path: path, Offset: 0, Length: 64 * bs, Mode: punch}); err != nil {
		check(&ok, "default lock: the peer punches a range once the overwrite is closed", false, err.Error())
	} else {
		check(&ok, "default lock: the peer punches a range once the overwrite is closed", true, "")
	}
	peer := []int64{bs * 1000, bs * 1001}
	var pw DioWriteResult
	resp, e = b.Call("dio_write", DioWriteArgs{Path: path, Offsets: peer, Stamp: "PEER", Par: 2, Fsync: true})
	if err := decodeResult(b.Name, resp, e, &pw); err != nil || pw.Failed > 0 {
		check(&ok, "default lock: the peer overwrites blocks after the handoff", false, fmt.Sprintf("%v %+v", err, pw))
	} else {
		check(&ok, "default lock: the peer overwrites blocks after the handoff", true, "")
	}
	// The punch zeroed the first 64 blocks, whatever the overwrite had put
	// there; the peer's two blocks are its own.
	v, err = verifyDirect(a, []string{"BASE", "OVW", "PEER"}, []DioMust{{Stamp: "PEER", Offsets: peer}}, true)
	check(&ok, "default lock: the overwriter reads the peer's punch and overwrite (the punch zeroed its range)",
		err == nil && v.Missing == 0 && v.Forbidden == 0 && v.Garbage == 0 && v.Zero >= 64 && v.Valid["PEER"] == 2,
		fmt.Sprintf("err=%v %+v", err, v))

	ensureUnmounted(clients)

	// ---- part 2: nofilelock, the explicit lock held across the overwrite ----
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("pre-unmount: %w", err)
	}
	if err := mountAllNoFileLock(clients); err != nil {
		return false, err
	}
	fmt.Println("  -- nofilelock, explicit flock across the overwrite")
	resp, err = a.Call("open_hold", OpenHoldArgs{Path: path, Mode: "rdwr"})
	var hr OpenHoldResult
	if err := decodeResult(a.Name, resp, err, &hr); err != nil {
		return false, fmt.Errorf("%s: open+hold: %w", a.Name, err)
	}
	if err := do(a, "lock_file", LockFileArgs{Handle: hr.Handle}); err != nil {
		_, _ = a.Call("close", CloseArgs{Handle: hr.Handle})
		return false, fmt.Errorf("%s: lock_file: %w", a.Name, err)
	}
	c0, err = overwriteCounter(a)
	if err != nil {
		return false, err
	}
	job, err = runJob(a, ow, "OVW2")
	if err != nil {
		return false, fmt.Errorf("%s: overwrite under flock: %w", a.Name, err)
	}
	time.Sleep(300 * time.Millisecond)
	pre = DioWriteResult{}
	resp, e = a.Call("dio_wait", DioWaitArgs{Job: job, TimeoutSecs: 0})
	_ = decodeResult(a.Name, resp, e, &pre)
	if pre.Done {
		_, _ = a.Call("close", CloseArgs{Handle: hr.Handle})
		return false, fmt.Errorf("setup: the flocked overwrite finished before the peer acted")
	}
	got, e2 = peerOpen()
	check(&ok, "nofilelock: the peer is refused while the overwriter holds flock, overwrite in flight", !got,
		fmt.Sprintf("the peer was allowed to open: %s", e2))
	resp, e = a.Call("dio_wait", DioWaitArgs{Job: job, TimeoutSecs: 600})
	fin = DioWriteResult{}
	if err := decodeResult(a.Name, resp, e, &fin); err != nil || !fin.Done || fin.Failed > 0 {
		_, _ = a.Call("close", CloseArgs{Handle: hr.Handle})
		return false, fmt.Errorf("%s: flocked overwrite did not finish cleanly: %v %+v", a.Name, err, fin)
	}
	c1, err = overwriteCounter(a)
	if err != nil {
		_, _ = a.Call("close", CloseArgs{Handle: hr.Handle})
		return false, err
	}
	// The part-1 punch left the first 64 blocks as holes. A write into a
	// hole is not an overwrite of written blocks, so those 32 writes take
	// the exclusive path, and only the rest may count as shared.
	shared := 0
	for _, o := range ow {
		if o >= 64*bs {
			shared++
		}
	}
	check(&ok, fmt.Sprintf("nofilelock: the flocked overwrite took the shared path (%d of %d writes; the rest hit holes)", shared, len(ow)),
		c1-c0 == int64(shared),
		fmt.Sprintf("dio_overwrites moved %d, expected %d", c1-c0, shared))
	v, err = verifyDirect(a, []string{"BASE", "OVW", "OVW2", "PEER"}, []DioMust{{Stamp: "OVW2", Offsets: ow}}, true)
	check(&ok, "nofilelock: the overwriter reads its own flocked overwrite back",
		err == nil && v.Missing == 0 && v.Forbidden == 0 && v.Garbage == 0 && v.Valid["OVW2"] == len(ow),
		fmt.Sprintf("err=%v %+v", err, v))

	// Handoff: unlock and close; the peer opens and reads what was written.
	if err := do(a, "unlock_file", UnlockFileArgs{Handle: hr.Handle}); err != nil {
		_, _ = a.Call("close", CloseArgs{Handle: hr.Handle})
		return false, fmt.Errorf("%s: unlock_file: %w", a.Name, err)
	}
	_, _ = a.Call("close", CloseArgs{Handle: hr.Handle})
	got, e2 = peerOpen()
	check(&ok, "nofilelock: after the unlock the peer can open again", got, e2)
	for _, direct := range []bool{true, false} {
		v, err := verifyDirect(b, []string{"BASE", "OVW", "OVW2", "PEER"}, []DioMust{{Stamp: "OVW2", Offsets: ow}}, direct)
		check(&ok, fmt.Sprintf("nofilelock: the peer reads the flocked overwrite after the handoff (direct=%v)", direct),
			err == nil && v.Missing == 0 && v.Forbidden == 0 && v.Garbage == 0 && v.Valid["OVW2"] == len(ow),
			fmt.Sprintf("err=%v %+v", err, v))
	}

	ensureUnmounted(clients)
	fsck, err := a.Call("fsck", FsckArgs{})
	var fr FsckResult
	if err := decodeResult(a.Name, fsck, err, &fr); err != nil || !fr.Clean {
		check(&ok, "fsck clean after both lock modes", false, fmt.Sprintf("%v %s", err, fr.Output))
	} else {
		check(&ok, "fsck clean after both lock modes", true, "")
	}
	return ok, nil
}
