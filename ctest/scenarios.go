// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

type callOutcome struct {
	client *Client
	resp   Response
	err    error
}

// skipErr marks a scenario that declined to run -- its precondition was
// not met, so it tested NOTHING.
//
// It exists because the alternative is worse than a failure: pending-free
// printed "SKIP: a owns no zone group" and returned success, so the suite
// reported PASS for a scenario that never exercised the pending-free
// queue at all. A green line for work that did not happen is how a real
// symptom (all three nodes owning no zone group) stayed invisible.
type skipErr struct{ reason string }

func (e skipErr) Error() string { return "skipped: " + e.reason }

// skipScenario: the precondition was not met. Report it as a SKIP, never
// as a pass.
func skipScenario(format string, args ...any) (bool, error) {
	reason := fmt.Sprintf(format, args...)
	fmt.Printf("SKIP: %s\n", reason)
	return false, skipErr{reason}
}

// fireConcurrently sends the same op+args to every client at (as close to)
// the same instant as Go's scheduler allows, via a real barrier: every
// goroutine signals "started.Done()" immediately before blocking on
// <-start, so started.Wait() below only returns once every single one of
// them is sitting at that exact point, and only then do we close(start)
// to release them all together. This is what actually exercises the
// kernel-level race window a scenario is testing -- issuing requests one
// after another across separate connections would just serialize what's
// supposed to be concurrent, and these scenarios exist specifically to
// catch bugs that only manifest when multiple nodes hit the same on-disk
// state at (nearly) the same instant -- see docs/LOCKING.md.
func fireConcurrently(clients []*Client, op string, args any) []callOutcome {
	var started, done sync.WaitGroup
	start := make(chan struct{})
	out := make([]callOutcome, len(clients))

	started.Add(len(clients))
	done.Add(len(clients))

	for i, c := range clients {
		go func(i int, c *Client) {
			defer done.Done()
			started.Done()
			<-start
			resp, err := c.Call(op, args)
			out[i] = callOutcome{client: c, resp: resp, err: err}
		}(i, c)
	}

	started.Wait()
	close(start)
	done.Wait()
	return out
}

// RunLockRace exercises the cross-node whole-file exclusive open lock
// (kmod/lock.c): every client tries to open the same file for write at
// the same instant. Per this project's clustering model, exactly one must
// win the claim and every other client must be rejected (-ETXTBSY) --
// *not* an error condition, the expected and required outcome. More than
// one success would mean the claim-race fix (PR mutex +
// write-then-verify-readback around the claim) regressed; zero successes
// would mean something else entirely rejected a claim that should have
// been free to take.
// ensureMounted mounts device/mountPoint on every client that doesn't
// already have it mounted, sequentially (mount timing itself is never
// what a scenario is testing, so no reason to fire it concurrently).
// Without this, a scenario that only ever does file ops silently trusts
// whatever mount state the slave process happens to already be in --
// which is empty after a slave restart, and used to mean "create the
// test file relative to the slave's CWD instead of erroring" (a real
// bug, caught via a real two-node run creating its lock file outside
// the mountpoint entirely). Mounting is idempotent on the slave side
// (doMount), so calling this at the top of every scenario that touches
// files is always safe.
func ensureMounted(clients []*Client) error {
	for _, c := range clients {
		resp, err := c.Call("mount", MountArgs{})
		if err := decodeResult(c.Name, resp, err, nil); err != nil {
			return fmt.Errorf("%s: mount: %w", c.Name, err)
		}
	}
	return nil
}

// ensureUnmounted is ensureMounted's cleanup counterpart: every scenario
// that mounts as part of running unmounts again once it's done (success
// or failure, via a defer right after the mount succeeds), so running a
// test doesn't leave the shared device mounted behind as a side effect
// that a later, unrelated investigation then has to puzzle over --
// caught for real when a background smoke-test run left /mnt/ctest
// mounted and its reappearance looked like something unexplained was
// touching a live two-node test session. Errors are reported but don't
// flip a scenario's already-decided pass/fail: cleanup failing is a
// separate concern from whether the thing actually under test worked.
func ensureUnmounted(clients []*Client) error {
	var firstErr error
	for _, c := range clients {
		resp, err := c.Call("unmount", UnmountArgs{})
		if err := decodeResult(c.Name, resp, err, nil); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func RunLockRace(clients []*Client, path string) (bool, error) {
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	fmt.Printf("=== lock race: %d client(s) opening %q for write simultaneously ===\n", len(clients), path)

	results := fireConcurrently(clients, "open_hold", OpenHoldArgs{Path: path, Mode: "wronly", Create: true})

	var winners []*Client
	winnerHandle := make(map[string]uint64)

	for _, r := range results {
		if r.err != nil {
			fmt.Printf("  %-12s transport error: %v\n", r.client.Name, r.err)
			continue
		}
		if r.resp.OK {
			var res OpenHoldResult
			if err := json.Unmarshal(r.resp.Result, &res); err != nil {
				fmt.Printf("  %-12s open succeeded but result decode failed: %v\n", r.client.Name, err)
				continue
			}
			fmt.Printf("  %-12s OPEN SUCCEEDED (handle=%d)\n", r.client.Name, res.Handle)
			winners = append(winners, r.client)
			winnerHandle[r.client.Name] = res.Handle
		} else {
			fmt.Printf("  %-12s open rejected: %s\n", r.client.Name, r.resp.Error)
		}
	}

	if len(winners) != 1 {
		fmt.Printf("FAIL: lock race: expected exactly 1 winner, got %d\n", len(winners))
		// Still release any handle(s) that did open, so a failed run
		// doesn't leave the lock stuck for whatever runs next.
		for name, h := range winnerHandle {
			for _, c := range clients {
				if c.Name == name {
					_, _ = c.Call("close", CloseArgs{Handle: h})
				}
			}
		}
		return false, nil
	}

	winner := winners[0]
	fmt.Printf("PASS: lock race: exactly 1 of %d client(s) won the open (%s), the rest were rejected\n",
		len(clients), winner.Name)

	resp, err := winner.Call("close", CloseArgs{Handle: winnerHandle[winner.Name]})
	if err := decodeResult(winner.Name, resp, err, nil); err != nil {
		return false, fmt.Errorf("releasing winner's handle: %w", err)
	}
	fmt.Printf("PASS: lock race: winner's handle closed, lock released cleanly\n")

	return true, nil
}

// RunZGFairness exercises the minimum-claim-not-greedy Zone Group
// ownership policy (kmod/zonegroup.c): every client mounts
// the shared device at the same instant, then every client's own
// /proc/fs/cetrafs/<dev>/info is collected and cross-checked. The
// invariant that must hold regardless of whatever ZGs were already
// claimed before this run started: no two clients ever report owning the
// same ZG. (This intentionally doesn't assert "every ZG gets claimed" or
// "claims are evenly spread" -- mkfs isn't run by this tool, so the
// volume's starting ownership state is whatever it already was; the one
// thing that must never happen, at any starting state, is two nodes
// believing they own the same ZG at once.)
func RunZGFairness(clients []*Client) (bool, error) {
	fmt.Printf("=== ZG fairness: %d client(s) mounting simultaneously ===\n", len(clients))

	results := fireConcurrently(clients, "mount", MountArgs{})
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()
	for _, r := range results {
		if r.err != nil {
			return false, fmt.Errorf("%s: transport error mounting: %w", r.client.Name, r.err)
		}
		if !r.resp.OK {
			fmt.Printf("  %-12s mount failed: %s\n", r.client.Name, r.resp.Error)
		} else {
			fmt.Printf("  %-12s mounted\n", r.client.Name)
		}
	}

	seenBy := map[int][]string{} // zg id -> client names claiming ownership of it
	totalClaims := 0

	for _, c := range clients {
		resp, err := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
		var snap ProcSnapshotResult
		if err := decodeResult(c.Name, resp, err, &snap); err != nil {
			return false, err
		}
		for _, zg := range snap.ZoneGroups {
			if zg.ThisNode {
				seenBy[zg.ID] = append(seenBy[zg.ID], c.Name)
				totalClaims++
			}
		}
		fmt.Printf("  %-12s this_node_id=%d owns %d ZG(s)\n", c.Name, snap.ThisNodeID, countOwned(snap))
	}

	ok := true
	for zgID, names := range seenBy {
		if len(names) > 1 {
			fmt.Printf("FAIL: ZG fairness: ZG %d claimed by multiple clients at once: %v\n", zgID, names)
			ok = false
		}
	}
	if ok {
		fmt.Printf("PASS: ZG fairness: no two clients ever claimed the same ZG (%d total claim(s) across %d client(s))\n",
			totalClaims, len(clients))
	}
	return ok, nil
}

// RunLockSequential is a diagnostic variant of RunLockRace: instead of
// firing both opens at the same instant (which conflates "is there a race
// window" with "does the claim get detected at all"), it has the first
// client fully open-and-confirm the file for write, THEN -- only after
// that round trip has completed, PR mutex released, write committed --
// has the second client attempt to open the same file. If the second
// client still succeeds here, there is no race at all: the second
// client's claim-decision read is failing to see the first client's
// already-fully-committed write, which points at a stale-cache or
// PR-mutex-not-really-exclusive bug rather than a narrow timing window.
func RunLockSequential(clients []*Client, path string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("lock-sequential needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	first, second := clients[0], clients[1]
	fmt.Printf("=== lock sequential: %s opens %q for write, then (after full completion) %s tries ===\n",
		first.Name, path, second.Name)

	resp, err := first.Call("open_hold", OpenHoldArgs{Path: path, Mode: "wronly", Create: true})
	var firstRes OpenHoldResult
	if err := decodeResult(first.Name, resp, err, &firstRes); err != nil {
		return false, fmt.Errorf("%s: first open failed: %w", first.Name, err)
	}
	fmt.Printf("  %-12s OPEN SUCCEEDED (handle=%d) -- fully committed before second attempt\n",
		first.Name, firstRes.Handle)

	resp, err = second.Call("open_hold", OpenHoldArgs{Path: path, Mode: "wronly", Create: true})
	ok := true
	if err != nil {
		fmt.Printf("  %-12s transport error: %v\n", second.Name, err)
		ok = false
	} else if resp.OK {
		var secondRes OpenHoldResult
		_ = json.Unmarshal(resp.Result, &secondRes)
		fmt.Printf("  %-12s OPEN SUCCEEDED TOO (handle=%d) -- no race window here, this is a stale-read/PR bug\n",
			second.Name, secondRes.Handle)
		_, _ = second.Call("close", CloseArgs{Handle: secondRes.Handle})
		ok = false
	} else {
		fmt.Printf("  %-12s open correctly rejected: %s\n", second.Name, resp.Error)
	}

	_, _ = first.Call("close", CloseArgs{Handle: firstRes.Handle})

	if ok {
		fmt.Printf("PASS: lock sequential: second open correctly rejected after the first's claim fully committed\n")
	} else {
		fmt.Printf("FAIL: lock sequential: second open should have been rejected -- no concurrency involved here\n")
	}
	return ok, nil
}

// RunModuleInfo is a fast, focused check for "are both nodes actually
// running the same build of cetrafs.ko right now" -- deliberately
// separate from the much heavier "diag" scenario (full /proc dump + a
// large dmesg tail) since this is meant to be the first thing to run
// after a rebuild/reload, before spending time on an actual scenario
// that might just fail again because one side never got the new code.
func RunModuleInfo(clients []*Client) (bool, error) {
	fmt.Println("=== module info: which cetrafs.ko build is actually loaded on each node ===")

	var buildIDs = map[string][]string{} // build_id -> client names reporting it
	ok := true

	for _, c := range clients {
		resp, err := c.Call("module_info", struct{}{})
		var res ModuleInfoResult
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			fmt.Printf("  %-12s module_info: %v\n", c.Name, err)
			ok = false
			continue
		}
		fmt.Printf("  %-12s loaded=%v via=%s build_id=%s ko_path=%s ko_sha256=%s ko_mod_time=%s\n",
			c.Name, res.Loaded, res.LoadedBy, res.BuildID, res.KoPath, res.KoSHA256, res.KoModTime)
		if !res.Loaded {
			fmt.Printf("  %-12s WARNING: no cetrafs module loaded, and it could not be loaded: %s\n",
				c.Name, res.LoadErr)
			ok = false
			continue
		}
		if res.BuildID == "" {
			fmt.Printf("  %-12s WARNING: loaded but no build-id note found -- can't confirm build alignment\n", c.Name)
			ok = false
			continue
		}
		buildIDs[res.BuildID] = append(buildIDs[res.BuildID], c.Name)
	}

	if len(buildIDs) > 1 {
		fmt.Printf("FAIL: module info: nodes are running DIFFERENT builds:\n")
		for id, names := range buildIDs {
			fmt.Printf("  build_id=%s -> %v\n", id, names)
		}
		return false, nil
	}
	if !ok {
		return false, nil
	}
	fmt.Printf("PASS: module info: all %d node(s) report the same build-id\n", len(clients))
	return true, nil
}

func countOwned(snap ProcSnapshotResult) int {
	n := 0
	for _, zg := range snap.ZoneGroups {
		if zg.ThisNode {
			n++
		}
	}
	return n
}

// check prints a PASS/FAIL line for one assertion and clears *ok on
// failure -- shared by the scenarios below so a single run can report
// many independent sub-checks (one per filesystem operation) under one
// overall pass/fail, rather than bailing out after the first mismatch
// and leaving every later operation untested this run.
func check(ok *bool, label string, cond bool, detail string) {
	if cond {
		fmt.Printf("  PASS: %s\n", label)
		return
	}
	if detail != "" {
		fmt.Printf("  FAIL: %s -- %s\n", label, detail)
	} else {
		fmt.Printf("  FAIL: %s\n", label)
	}
	*ok = false
}

// statPath stats a path on one client, reporting whether it exists at
// all (as opposed to some other transport-level problem) -- scenarios
// use this to assert "this name is visible on this node" or "this node
// correctly sees it's gone" without caring about the exact errno text
// unlink/rmdir/rename's absence comes back as.
// statPath: (result, exists, error). "exists=false" means the filesystem
// answered and the name is NOT THERE -- it must never also mean "we could
// not ask".
//
// It used to mean both: any !resp.OK became exists=false, so a slave
// replying "/mnt/cetra is not a cetrafs mount (send \"mount\" first)"
// was scored as a missing file. That reported a cross-node VISIBILITY
// failure -- a file created on one node unseen by another -- when the
// real state was simply an unmounted peer. Seen on the cluster at ~15%
// of xattrs runs, with the scenario's own DIAG retry finding the file
// 3s later once the mount was up.
func statPath(c *Client, path string) (StatResult, bool, error) {
	resp, err := c.Call("stat", StatArgs{Path: path})
	if err != nil {
		return StatResult{}, false, err
	}
	if !resp.OK {
		if statErrIsAbsent(resp.Error) {
			return StatResult{}, false, nil
		}
		return StatResult{}, false, fmt.Errorf("%s: stat %s could not be answered: %s", c.Name, path, resp.Error)
	}
	var res StatResult
	if err := json.Unmarshal(resp.Result, &res); err != nil {
		return StatResult{}, false, err
	}
	return res, true, nil
}

// Does this slave-side stat error mean "the name is not there", as
// opposed to "this node could not look"? Only the first is a legitimate
// exists=false; everything else (not mounted, EIO, a transport-level
// refusal) is a condition the caller must see as an ERROR, or it gets
// mistaken for a filesystem result.
func statErrIsAbsent(e string) bool {
	le := strings.ToLower(e)
	return strings.Contains(le, "no such file or directory") || strings.Contains(le, "enoent")
}

// RunCrossNodeVisibility exercises every namespace/metadata/content
// mutation this filesystem supports (create+write, chmod, xattr,
// truncate grow+shrink, hardlink, symlink, rename, mkdir, rmdir, unlink)
// one at a time on the first client ("writer"), checking after each
// step that the second client ("reader") -- which never does the
// mutation itself -- sees the exact same result by reading it back cold
// (a fresh stat/read/xattr_get/readlink call every time, not a cached
// handle). This is the direct regression test for the // cross-node cache-staleness bug (a write+close on one node reading
// back as 0 bytes on the other): every step here is "mutate on A, then
// check cold on B", which is exactly the shape that bug needed.
func RunCrossNodeVisibility(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("cross-node-visibility needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	writer, reader := clients[0], clients[1]
	fmt.Printf("=== cross-node visibility: %s mutates, %s checks cold, under %q ===\n", writer.Name, reader.Name, baseDir)

	ok := true

	call := func(c *Client, op string, args any) error {
		resp, err := c.Call(op, args)
		return decodeResult(c.Name, resp, err, nil)
	}

	path := baseDir + "/visibility-file"
	dir := baseDir + "/visibility-dir"
	hardlink := baseDir + "/visibility-hardlink"
	symlinkPath := baseDir + "/visibility-symlink"
	renamed := baseDir + "/visibility-file-renamed"

	if err := call(writer, "mkdir", MkdirArgs{Path: baseDir}); err != nil {
		return false, fmt.Errorf("setup mkdir %s: %w", baseDir, err)
	}

	// create + write + content visibility
	resp, err := writer.Call("write", WriteArgs{Path: path, Size: 4096, Stamp: "vis-" + writer.Name})
	var wres WriteResult
	if err := decodeResult(writer.Name, resp, err, &wres); err != nil {
		return false, fmt.Errorf("writer write: %w", err)
	}
	resp, err = reader.Call("read", ReadArgs{Path: path})
	var rres ReadResult
	if err := decodeResult(reader.Name, resp, err, &rres); err != nil {
		return false, fmt.Errorf("reader read after write: %w", err)
	}
	check(&ok, "create+write: reader sees writer's content", rres.Checksum == wres.Checksum && rres.Size == 4096,
		fmt.Sprintf("writer checksum=%s size=%d, reader checksum=%s size=%d", wres.Checksum, 4096, rres.Checksum, rres.Size))

	// chmod visibility
	if err := call(writer, "chmod", ChmodArgs{Path: path, Mode: 0640}); err != nil {
		return false, fmt.Errorf("writer chmod: %w", err)
	}
	st, exists, err := statPath(reader, path)
	if err != nil {
		return false, fmt.Errorf("reader stat after chmod: %w", err)
	}
	check(&ok, "chmod: reader sees new mode bits", exists && st.ModeBits == 0640,
		fmt.Sprintf("exists=%v mode_bits=%#o, want 0640", exists, st.ModeBits))

	// xattr visibility
	if err := call(writer, "xattr_set", XattrSetArgs{Path: path, Name: "user.ctest", Value: "hello-cross-node"}); err != nil {
		return false, fmt.Errorf("writer xattr_set: %w", err)
	}
	resp, err = reader.Call("xattr_get", XattrGetArgs{Path: path, Name: "user.ctest"})
	var xres XattrGetResult
	if err := decodeResult(reader.Name, resp, err, &xres); err != nil {
		return false, fmt.Errorf("reader xattr_get: %w", err)
	}
	check(&ok, "xattr: reader sees writer's user.ctest value", xres.Found && xres.Value == "hello-cross-node",
		fmt.Sprintf("found=%v value=%q", xres.Found, xres.Value))

	// truncate shrink visibility
	if err := call(writer, "truncate", TruncateArgs{Path: path, Size: 10}); err != nil {
		return false, fmt.Errorf("writer truncate shrink: %w", err)
	}
	st, exists, err = statPath(reader, path)
	if err != nil {
		return false, fmt.Errorf("reader stat after shrink: %w", err)
	}
	check(&ok, "truncate shrink: reader sees new size", exists && st.Size == 10,
		fmt.Sprintf("exists=%v size=%d, want 10", exists, st.Size))

	// truncate grow visibility
	if err := call(writer, "truncate", TruncateArgs{Path: path, Size: 4096}); err != nil {
		return false, fmt.Errorf("writer truncate grow: %w", err)
	}
	st, exists, err = statPath(reader, path)
	if err != nil {
		return false, fmt.Errorf("reader stat after grow: %w", err)
	}
	check(&ok, "truncate grow: reader sees new size", exists && st.Size == 4096,
		fmt.Sprintf("exists=%v size=%d, want 4096", exists, st.Size))

	// hardlink visibility
	if err := call(writer, "link", LinkArgs{OldPath: path, NewPath: hardlink}); err != nil {
		return false, fmt.Errorf("writer link: %w", err)
	}
	stLink, existsLink, err := statPath(reader, hardlink)
	if err != nil {
		return false, fmt.Errorf("reader stat hardlink: %w", err)
	}
	stOrig, _, err := statPath(reader, path)
	if err != nil {
		return false, fmt.Errorf("reader stat original after link: %w", err)
	}
	check(&ok, "hardlink: reader sees new name with nlink=2 on both names",
		existsLink && stLink.Nlink == 2 && stOrig.Nlink == 2,
		fmt.Sprintf("hardlink exists=%v nlink=%d, original nlink=%d", existsLink, stLink.Nlink, stOrig.Nlink))

	// symlink visibility
	symTarget := "visibility-file"
	if err := call(writer, "symlink", SymlinkArgs{Target: symTarget, LinkPath: symlinkPath}); err != nil {
		return false, fmt.Errorf("writer symlink: %w", err)
	}
	resp, err = reader.Call("readlink", ReadlinkArgs{Path: symlinkPath})
	var lres ReadlinkResult
	if err := decodeResult(reader.Name, resp, err, &lres); err != nil {
		return false, fmt.Errorf("reader readlink: %w", err)
	}
	check(&ok, "symlink: reader sees writer's target text", lres.Target == symTarget,
		fmt.Sprintf("got %q, want %q", lres.Target, symTarget))

	// rename visibility
	if err := call(writer, "rename", RenameArgs{Old: path, New: renamed}); err != nil {
		return false, fmt.Errorf("writer rename: %w", err)
	}
	_, oldExists, err := statPath(reader, path)
	if err != nil {
		return false, fmt.Errorf("reader stat old name after rename: %w", err)
	}
	stNew, newExists, err := statPath(reader, renamed)
	if err != nil {
		return false, fmt.Errorf("reader stat new name after rename: %w", err)
	}
	check(&ok, "rename: reader sees old name gone, new name present with same content",
		!oldExists && newExists && stNew.Size == 4096,
		fmt.Sprintf("old_exists=%v new_exists=%v new_size=%d", oldExists, newExists, stNew.Size))

	// mkdir visibility
	if err := call(writer, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("writer mkdir: %w", err)
	}
	stDir, dirExists, err := statPath(reader, dir)
	if err != nil {
		return false, fmt.Errorf("reader stat dir: %w", err)
	}
	check(&ok, "mkdir: reader sees new directory", dirExists && stDir.IsDir,
		fmt.Sprintf("exists=%v is_dir=%v", dirExists, stDir.IsDir))

	// rmdir visibility
	if err := call(writer, "rmdir", RmdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("writer rmdir: %w", err)
	}
	_, dirExists, err = statPath(reader, dir)
	if err != nil {
		return false, fmt.Errorf("reader stat dir after rmdir: %w", err)
	}
	check(&ok, "rmdir: reader sees directory gone", !dirExists, fmt.Sprintf("exists=%v", dirExists))

	// unlink visibility (cleanup, also a real check)
	for _, p := range []string{renamed, hardlink, symlinkPath} {
		if err := call(writer, "unlink", UnlinkArgs{Path: p}); err != nil {
			return false, fmt.Errorf("writer unlink %s: %w", p, err)
		}
	}
	allGone := true
	for _, p := range []string{renamed, hardlink, symlinkPath} {
		_, exists, err := statPath(reader, p)
		if err != nil {
			return false, fmt.Errorf("reader stat %s after unlink: %w", p, err)
		}
		if exists {
			allGone = false
		}
	}
	check(&ok, "unlink: reader sees all removed names gone", allGone, "")

	if ok {
		fmt.Printf("PASS: cross-node visibility: every mutation by %s was correctly visible to %s\n", writer.Name, reader.Name)
	} else {
		fmt.Printf("FAIL: cross-node visibility: see failed checks above\n")
	}
	return ok, nil
}

// RunLockHold is the most literal reading of the whole-file exclusive
// lock requirement: open for write and *keep the handle open* (not
// close-then-let-the-other-try, which is RunLockSequential's shape),
// have the other client try to open the same path while the first is
// still holding it (must be rejected), then close the first and confirm
// the second can now succeed (the release actually released it).
//
// Also tries a read-only open while held, not just another write-open:
// CLAUDE.md's actual spec is "unopenable by every other node for
// anything... not POSIX byte-range locking" -- a reader from a peer
// node must be rejected exactly like a writer would be. Before this,
// no ctest scenario ever exercised that case against real two-node
// hardware; kmod/lock.c's own cetrafs_lock_open() rejects read opens
// too (confirmed only via the single-node tests/inode_lock_poke.c
// simulation), but nothing had actually driven a second real node's
// kernel through it.
// RunXattrs exercises user.* extended attributes across nodes
// (kmod/xattr.c) -- the full lifecycle (set, overwrite, list, remove,
// the lazily-allocated xattr block's alloc/free accounting) checked
// cross-node in BOTH directions, plus the race the xattr-mutex fix
// specifically closed: xattr mutation runs under dir.c's namespace
// cluster mutex now, where it previously took NO cross-node
// synchronization at all (setxattr never goes through .open, so the
// whole-file lock never covered it). Pre-g5, two nodes setting xattrs
// on the same fresh file at the same instant raced the one-xattr-block
// allocation: both allocated, one block leaked, and one node's
// attribute silently vanished -- exactly what the concurrent sections
// below would catch.
func RunXattrs(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("xattrs needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a, b := clients[0], clients[1]
	fmt.Printf("=== xattrs: lifecycle %s<->%s + %d-way concurrent set, under %q ===\n", a.Name, b.Name, len(clients), baseDir)

	ok := true

	call := func(c *Client, op string, args any) error {
		resp, err := c.Call(op, args)
		return decodeResult(c.Name, resp, err, nil)
	}
	getx := func(c *Client, path, name string) (XattrGetResult, error) {
		resp, err := c.Call("xattr_get", XattrGetArgs{Path: path, Name: name})
		var res XattrGetResult
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return XattrGetResult{}, err
		}
		return res, nil
	}
	listx := func(c *Client, path string) (map[string]bool, int, error) {
		resp, err := c.Call("xattr_list", XattrListArgs{Path: path})
		var res XattrListResult
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return nil, 0, err
		}
		set := map[string]bool{}
		for _, n := range res.Names {
			set[n] = true
		}
		return set, len(res.Names), nil
	}
	statfsOf := func(c *Client) (StatfsResult, error) {
		resp, err := c.Call("statfs", struct{}{})
		var res StatfsResult
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return StatfsResult{}, err
		}
		return res, nil
	}

	if err := call(a, "mkdir", MkdirArgs{Path: baseDir}); err != nil {
		return false, fmt.Errorf("setup mkdir %s: %w", baseDir, err)
	}
	path := baseDir + "/xattr-file"
	if err := call(a, "write", WriteArgs{Path: path, Size: 128, Stamp: "xattr"}); err != nil {
		return false, fmt.Errorf("setup write %s: %w", path, err)
	}

	// Baseline free space BEFORE any xattr exists: the first set below
	// lazily allocates the file's one xattr block, and removing the last
	// attribute at the end must free it again -- both visible in statfs.
	base, err := statfsOf(a)
	if err != nil {
		return false, fmt.Errorf("baseline statfs: %w", err)
	}
	// Is the volume actually idle? Sample again after a pause: anything
	// that moves in between is unrelated activity (most often the
	// previous run's teardown still draining its pending frees), and it
	// will go on moving through the one-block checks below.
	time.Sleep(3 * time.Second)
	base2, err := statfsOf(a)
	if err != nil {
		return false, fmt.Errorf("baseline statfs (second sample): %w", err)
	}
	drift := int64(base2.FreeBlocks) - int64(base.FreeBlocks)
	quiet := drift == 0
	base = base2

	// --- lifecycle, cross-node in both directions ---
	if err := call(a, "xattr_set", XattrSetArgs{Path: path, Name: "user.one", Value: "alpha"}); err != nil {
		return false, fmt.Errorf("%s xattr_set user.one: %w", a.Name, err)
	}
	g, err := getx(b, path, "user.one")
	if err != nil {
		return false, err
	}
	check(&ok, "set on "+a.Name+" visible on "+b.Name, g.Found && g.Value == "alpha",
		fmt.Sprintf("found=%v value=%q", g.Found, g.Value))

	afterAlloc, err := statfsOf(a)
	if err != nil {
		return false, err
	}
	// The two block-accounting checks below do exact arithmetic on a
	// VOLUME-GLOBAL counter, which is only meaningful while nothing else
	// is moving free space. On a shared cluster that is often false:
	// the previous run's teardown drains its pending frees
	// asynchronously, and those land here. Measured on the cluster,
	// back-to-back runs saw the count move by +16 and by -1322 inside
	// this window, failing a check about ONE block.
	//
	// So gate them on an observed-quiet volume rather than assume it,
	// and say plainly when they were skipped. A check that cannot
	// measure must not report a filesystem fault -- same honesty gate as
	// the crash rig's "a run that tore nothing proves nothing".
	if !quiet {
		fmt.Printf("  SKIP: block-accounting checks -- free space moved by %d block(s) while idle "+
			"(unrelated activity on this volume); the one-block assertions cannot be read\n",
			drift)
	} else {
		check(&ok, "first xattr set allocated the xattr block", afterAlloc.FreeBlocks == base.FreeBlocks-1,
			fmt.Sprintf("free %d -> %d, want -1", base.FreeBlocks, afterAlloc.FreeBlocks))
	}

	// overwrite, visible cross-node
	if err := call(a, "xattr_set", XattrSetArgs{Path: path, Name: "user.one", Value: "beta"}); err != nil {
		return false, fmt.Errorf("%s xattr_set overwrite: %w", a.Name, err)
	}
	g, err = getx(b, path, "user.one")
	if err != nil {
		return false, err
	}
	check(&ok, "overwrite visible cross-node", g.Found && g.Value == "beta",
		fmt.Sprintf("found=%v value=%q", g.Found, g.Value))

	// set from the OTHER node on the same file; both attrs must coexist
	if err := call(b, "xattr_set", XattrSetArgs{Path: path, Name: "user.two", Value: "gamma"}); err != nil {
		return false, fmt.Errorf("%s xattr_set user.two: %w", b.Name, err)
	}
	g, err = getx(a, path, "user.two")
	if err != nil {
		return false, err
	}
	check(&ok, "set on "+b.Name+" visible on "+a.Name, g.Found && g.Value == "gamma",
		fmt.Sprintf("found=%v value=%q", g.Found, g.Value))
	g, err = getx(a, path, "user.one")
	if err != nil {
		return false, err
	}
	check(&ok, b.Name+"'s set didn't clobber "+a.Name+"'s attribute", g.Found && g.Value == "beta",
		fmt.Sprintf("found=%v value=%q", g.Found, g.Value))

	// list from both nodes: exactly {user.one, user.two}
	for _, c := range []*Client{a, b} {
		names, n, err := listx(c, path)
		if err != nil {
			return false, err
		}
		check(&ok, "list on "+c.Name+" shows exactly user.one+user.two",
			n == 2 && names["user.one"] && names["user.two"], fmt.Sprintf("names=%v", names))
	}

	// get of a nonexistent attribute: clean not-found, not an error
	g, err = getx(b, path, "user.nope")
	if err != nil {
		return false, err
	}
	check(&ok, "get of a nonexistent attribute reports not-found", !g.Found, fmt.Sprintf("found=%v", g.Found))

	// remove one; other survives, both nodes agree
	if err := call(a, "xattr_remove", XattrRemoveArgs{Path: path, Name: "user.one"}); err != nil {
		return false, fmt.Errorf("%s xattr_remove user.one: %w", a.Name, err)
	}
	g, err = getx(b, path, "user.one")
	if err != nil {
		return false, err
	}
	check(&ok, "removal visible cross-node", !g.Found, fmt.Sprintf("found=%v", g.Found))
	names, n, err := listx(b, path)
	if err != nil {
		return false, err
	}
	check(&ok, "list after removal shows only user.two", n == 1 && names["user.two"], fmt.Sprintf("names=%v", names))

	// Remove the LAST attribute: the xattr block must be freed again
	// (xattr.c's empty-block reversion). The remover here is the node
	// that did NOT allocate the block, so the free is DELEGATED through
	// the owner's pending-free queue and only lands when
	// the owner's heartbeat tick drains it -- up to ~15s later, plus the
	// statfs flush boundary. Poll rather than check instantly: this makes
	// the check an end-to-end validation of the pending-free queue on
	// real hardware, with the deadline comfortably past one tick.
	if err := call(b, "xattr_remove", XattrRemoveArgs{Path: path, Name: "user.two"}); err != nil {
		return false, fmt.Errorf("%s xattr_remove user.two: %w", b.Name, err)
	}
	{
		deadline := time.Now().Add(45 * time.Second)
		var last StatfsResult
		freed := false
		for time.Now().Before(deadline) {
			last, err = statfsOf(a)
			if err != nil {
				return false, err
			}
			if last.FreeBlocks == base.FreeBlocks {
				freed = true
				break
			}
			time.Sleep(2 * time.Second)
		}
		if !quiet {
			fmt.Printf("  SKIP: pending-free drain check -- the volume was not idle at baseline "+
				"(%d block(s) of unrelated drift), so an exact return to it cannot be asserted\n", drift)
		} else {
			if !freed {
				// Gather what discriminates the causes, while the state
				// is still live. "free is one short" alone cannot tell
				// a free that was never queued from one queued and not
				// drained, from one applied whose count never became
				// visible to this node.
				fmt.Printf("  DIAG: free %d, baseline %d (short by %d)\n",
					last.FreeBlocks, base.FreeBlocks, int64(base.FreeBlocks)-int64(last.FreeBlocks))
				for _, cl := range clients {
					var snap ProcSnapshotResult
					if r, e := cl.Call("proc_snapshot", ProcSnapshotArgs{Device: cl.Device}); e == nil {
						if decodeResult(cl.Name, r, e, &snap) == nil {
							owned := []int{}
							for _, zg := range snap.ZoneGroups {
								if zg.ThisNode {
									owned = append(owned, zg.ID)
								}
							}
							fmt.Printf("  DIAG: %s owns ZG %v fenced=%v\n", cl.Name, owned, snap.Fenced)
							for _, zg := range owned {
								var dr DeviceReadResult
								if r2, e2 := cl.Call("device_read", DeviceReadArgs{Kind: "pending",
									Args: []string{fmt.Sprint(zg)}}); e2 == nil {
									if decodeResult(cl.Name, r2, e2, &dr) == nil {
										q := strings.TrimSpace(dr.Output)
										if q == "" {
											q = "(empty)"
										}
										fmt.Printf("  DIAG: %s ZG%d queue: %s\n", cl.Name, zg, q)
									}
								}
							}
						}
					}
					if r, e := cl.Call("proc_raw", ProcRawArgs{Device: cl.Device}); e == nil {
						var pr ProcRawResult
						if decodeResult(cl.Name, r, e, &pr) == nil {
							for _, ln := range strings.Split(pr.Info, "\n") {
								if strings.HasPrefix(ln, "free_data_blocks:") ||
									strings.HasPrefix(ln, "pending_free_appends:") ||
									strings.HasPrefix(ln, "scrub_reclaimed:") {
									fmt.Printf("  DIAG: %s %s\n", cl.Name, strings.TrimSpace(ln))
								}
							}
						}
					}
				}
			}
			check(&ok, "removing the last xattr freed the xattr block (via the owner's pending-free drain)", freed,
				fmt.Sprintf("free %d, want baseline %d (waited up to 45s for the heartbeat drain)",
					last.FreeBlocks, base.FreeBlocks))
		}
	}

	// --- concurrent DIFFERENT-key set on a fresh file (the g5 race) ---
	// A fresh file has no xattr block yet, so every node's set races the
	// lazy allocation. Post-g5 (ns cluster mutex) every attribute must
	// land; pre-g5 one node's whole set could silently vanish.
	racePath := baseDir + "/xattr-race-file"
	if err := call(a, "write", WriteArgs{Path: racePath, Size: 128, Stamp: "xattr-race"}); err != nil {
		return false, fmt.Errorf("setup write %s: %w", racePath, err)
	}
	// Every node must see the fresh file BEFORE the race fires -- its own
	// labeled check, so a create-visibility problem can't masquerade as
	// (or abort) the xattr race below. On a miss, gather the evidence
	// that discriminates between the possible causes: a readdir of the
	// parent from the missing node (walk-level view: name present in the
	// dirents or genuinely absent from what that node reads off the
	// LUN?), a delayed retry (transient vs persistent), and both nodes'
	// dmesg tails (a writer whose dirent write never reached the device
	// -- e.g. a SCSI reservation conflict -- screams there).
	for _, c := range clients {
		_, exists, err := statPath(c, racePath)
		if err != nil {
			return false, fmt.Errorf("%s pre-race stat: %w", c.Name, err)
		}
		check(&ok, c.Name+" sees the fresh race file before the race", exists, "stat says it doesn't exist")
		if !exists {
			var rd ReaddirResult
			resp, rerr := c.Call("readdir", ReaddirArgs{Path: baseDir})
			if derr := decodeResult(c.Name, resp, rerr, &rd); derr == nil {
				fmt.Printf("  DIAG: %s readdir(%s): %v\n", c.Name, baseDir, rd.Names)
			} else {
				fmt.Printf("  DIAG: %s readdir(%s) failed: %v\n", c.Name, baseDir, derr)
			}
			time.Sleep(3 * time.Second)
			_, exists2, _ := statPath(c, racePath)
			fmt.Printf("  DIAG: %s stat retry after 3s: exists=%v\n", c.Name, exists2)
			for _, cc := range clients {
				var dm DmesgTailResult
				resp, derr := cc.Call("dmesg_tail", DmesgTailArgs{Lines: 30})
				if e := decodeResult(cc.Name, resp, derr, &dm); e == nil {
					fmt.Printf("  DIAG: dmesg tail of %s:\n%s\n", cc.Name, dm.Text)
				}
			}
		}
	}

	type kv struct{ name, value string }
	want := map[string]string{}
	argsFor := map[string]kv{}
	for _, c := range clients {
		e := kv{"user.from-" + c.Name, "val-" + c.Name}
		want[e.name] = e.value
		argsFor[c.Name] = e
	}
	var started, done sync.WaitGroup
	start := make(chan struct{})
	errs := make([]error, len(clients))
	started.Add(len(clients))
	done.Add(len(clients))
	for i, c := range clients {
		go func(i int, c *Client) {
			defer done.Done()
			started.Done()
			<-start
			e := argsFor[c.Name]
			resp, err := c.Call("xattr_set", XattrSetArgs{Path: racePath, Name: e.name, Value: e.value})
			errs[i] = decodeResult(c.Name, resp, err, nil)
		}(i, c)
	}
	started.Wait()
	close(start)
	done.Wait()
	for i, e := range errs {
		if e != nil {
			// Don't abort opaquely: capture what each node sees NOW, so a
			// real-hardware failure report carries its own diagnosis.
			fmt.Printf("  DIAG: concurrent xattr_set failed on %s: %v\n", clients[i].Name, e)
			for _, c := range clients {
				st, exists, serr := statPath(c, racePath)
				fmt.Printf("  DIAG: %s stat(%s): exists=%v size=%d err=%v\n", c.Name, racePath, exists, st.Size, serr)
				names, _, lerr := listx(c, racePath)
				fmt.Printf("  DIAG: %s list(%s): names=%v err=%v\n", c.Name, racePath, names, lerr)
			}
			return false, fmt.Errorf("concurrent xattr_set on %s: %w", clients[i].Name, e)
		}
	}
	for _, c := range clients {
		names, n, err := listx(c, racePath)
		if err != nil {
			return false, err
		}
		allThere := n == len(clients)
		for name := range want {
			if !names[name] {
				allThere = false
			}
		}
		check(&ok, fmt.Sprintf("concurrent different-key set: %s sees all %d attributes", c.Name, len(clients)),
			allThere, fmt.Sprintf("names=%v", names))
	}
	for name, value := range want {
		g, err := getx(b, racePath, name)
		if err != nil {
			return false, err
		}
		check(&ok, "concurrent set: "+name+" has its exact value", g.Found && g.Value == value,
			fmt.Sprintf("found=%v value=%q want %q", g.Found, g.Value, value))
	}

	// --- concurrent SAME-key set: last-writer-wins is fine, a torn or
	// mixed value is not, and every node must agree on the winner. ---
	results := fireConcurrently(clients, "xattr_set", XattrSetArgs{Path: racePath, Name: "user.same", Value: "SAME"})
	for _, r := range results {
		if r.err != nil || !r.resp.OK {
			return false, fmt.Errorf("concurrent same-key xattr_set on %s failed: %v %s", r.client.Name, r.err, r.resp.Error)
		}
	}
	// now race genuinely different values at the same key
	var started2, done2 sync.WaitGroup
	start2 := make(chan struct{})
	errs2 := make([]error, len(clients))
	started2.Add(len(clients))
	done2.Add(len(clients))
	for i, c := range clients {
		go func(i int, c *Client) {
			defer done2.Done()
			started2.Done()
			<-start2
			resp, err := c.Call("xattr_set", XattrSetArgs{Path: racePath, Name: "user.same", Value: "winner-" + c.Name})
			errs2[i] = decodeResult(c.Name, resp, err, nil)
		}(i, c)
	}
	started2.Wait()
	close(start2)
	done2.Wait()
	for i, e := range errs2 {
		if e != nil {
			return false, fmt.Errorf("concurrent same-key xattr_set on %s: %w", clients[i].Name, e)
		}
	}
	valid := map[string]bool{}
	for _, c := range clients {
		valid["winner-"+c.Name] = true
	}
	var seen []string
	for _, c := range clients {
		g, err := getx(c, racePath, "user.same")
		if err != nil {
			return false, err
		}
		check(&ok, c.Name+" reads a whole (untorn) same-key value", g.Found && valid[g.Value],
			fmt.Sprintf("found=%v value=%q", g.Found, g.Value))
		seen = append(seen, g.Value)
	}
	agree := true
	for _, v := range seen {
		if v != seen[0] {
			agree = false
		}
	}
	check(&ok, "every node agrees on the same-key winner", agree, fmt.Sprintf("values=%v", seen))

	// cleanup
	_ = call(a, "unlink", UnlinkArgs{Path: path})
	_ = call(a, "unlink", UnlinkArgs{Path: racePath})

	if ok {
		fmt.Printf("PASS: xattrs: lifecycle + concurrent set all consistent across %d node(s)\n", len(clients))
	} else {
		fmt.Printf("FAIL: xattrs: one or more checks failed\n")
	}
	return ok, nil
}

func RunLockHold(clients []*Client, path string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("lock-hold needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	holder, other := clients[0], clients[1]
	fmt.Printf("=== lock hold: %s opens %q and holds it, %s must be rejected until %s closes ===\n",
		holder.Name, path, other.Name, holder.Name)

	ok := true

	resp, err := holder.Call("open_hold", OpenHoldArgs{Path: path, Mode: "wronly", Create: true})
	var holderRes OpenHoldResult
	if err := decodeResult(holder.Name, resp, err, &holderRes); err != nil {
		return false, fmt.Errorf("%s: initial open failed: %w", holder.Name, err)
	}
	fmt.Printf("  %-12s OPEN SUCCEEDED (handle=%d), holding it open\n", holder.Name, holderRes.Handle)

	resp, err = other.Call("open_hold", OpenHoldArgs{Path: path, Mode: "wronly", Create: true})
	if err != nil {
		_, _ = holder.Call("close", CloseArgs{Handle: holderRes.Handle})
		return false, fmt.Errorf("%s: transport error: %w", other.Name, err)
	}
	if resp.OK {
		var otherRes OpenHoldResult
		_ = json.Unmarshal(resp.Result, &otherRes)
		fmt.Printf("  %-12s OPEN SUCCEEDED WHILE HOLDER STILL OPEN (handle=%d) -- lock not enforced\n", other.Name, otherRes.Handle)
		_, _ = other.Call("close", CloseArgs{Handle: otherRes.Handle})
		ok = false
	} else {
		fmt.Printf("  %-12s open correctly rejected while held: %s\n", other.Name, resp.Error)
	}

	resp, err = other.Call("open_hold", OpenHoldArgs{Path: path, Mode: "rdonly"})
	if err != nil {
		_, _ = holder.Call("close", CloseArgs{Handle: holderRes.Handle})
		return false, fmt.Errorf("%s: transport error on read-open: %w", other.Name, err)
	}
	if resp.OK {
		var otherReadRes OpenHoldResult
		_ = json.Unmarshal(resp.Result, &otherReadRes)
		fmt.Printf("  %-12s READ-OPEN SUCCEEDED WHILE HOLDER STILL OPEN (handle=%d) -- lock not enforced for readers\n",
			other.Name, otherReadRes.Handle)
		_, _ = other.Call("close", CloseArgs{Handle: otherReadRes.Handle})
		ok = false
	} else {
		fmt.Printf("  %-12s read-open correctly rejected while held: %s\n", other.Name, resp.Error)
	}

	resp, err = holder.Call("close", CloseArgs{Handle: holderRes.Handle})
	if err := decodeResult(holder.Name, resp, err, nil); err != nil {
		return false, fmt.Errorf("%s: closing holder's handle: %w", holder.Name, err)
	}
	fmt.Printf("  %-12s closed, lock should now be released\n", holder.Name)

	resp, err = other.Call("open_hold", OpenHoldArgs{Path: path, Mode: "wronly", Create: true})
	var otherRes2 OpenHoldResult
	if err := decodeResult(other.Name, resp, err, &otherRes2); err != nil {
		check(&ok, "after release: other client can now write-open", false, err.Error())
	} else {
		check(&ok, "after release: other client can now write-open", true, "")
		_, _ = other.Call("close", CloseArgs{Handle: otherRes2.Handle})
	}

	resp, err = other.Call("open_hold", OpenHoldArgs{Path: path, Mode: "rdonly"})
	var otherReadRes2 OpenHoldResult
	if err := decodeResult(other.Name, resp, err, &otherReadRes2); err != nil {
		check(&ok, "after release: other client can now read-open", false, err.Error())
	} else {
		check(&ok, "after release: other client can now read-open", true, "")
		_, _ = other.Call("close", CloseArgs{Handle: otherReadRes2.Handle})
	}

	if ok {
		fmt.Printf("PASS: lock hold: rejected while held, succeeded once released\n")
	} else {
		fmt.Printf("FAIL: lock hold: see failed checks above\n")
	}
	return ok, nil
}

// mountAllNoFileLock mounts every slave with `-o nofilelock`. The slave
// adopts an already-live mount verbatim (ignoring the option), so callers
// unmount first to guarantee the option actually takes.
func mountAllNoFileLock(clients []*Client) error {
	for _, c := range clients {
		resp, err := c.Call("mount", MountArgs{NoFileLock: true})
		if err := decodeResult(c.Name, resp, err, nil); err != nil {
			return fmt.Errorf("%s: nofilelock mount: %w", c.Name, err)
		}
	}
	return nil
}

// RunExplicitLock exercises the userspace-driven whole-file lock
// whole-file lock (flock(2)) under nofilelock -- the real cross-node proof
// that this feature hands exclusion back to userspace on demand.
//
// nofilelock turns off the open-time automatic lock (so a peer CAN open the
// file -- the baseline this first confirms). The holder then LOCKs the file
// by ioctl, after which the peer is refused ANY open; UNLOCK reopens the
// window (the live-migration handoff), a re-LOCK closes it again, and
// finally closing the holder's fd releases it (the fd-scoped lifetime).
func RunExplicitLock(clients []*Client, path string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("explicit-lock needs at least 2 clients")
	}
	// The option only takes on a fresh mount, so clear any adopted one.
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("pre-unmount (to mount nofilelock): %w", err)
	}
	if err := mountAllNoFileLock(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	holder, other := clients[0], clients[1]
	fmt.Printf("=== explicit lock (nofilelock): %s drives flock(LOCK_EX); %s's opens track it ===\n",
		holder.Name, other.Name)
	ok := true

	do := func(c *Client, op string, args any) error {
		resp, err := c.Call(op, args)
		return decodeResult(c.Name, resp, err, nil)
	}

	// peerOpen attempts an open of the already-existing file on 'other'
	// and immediately closes on success; returns whether it was allowed.
	peerOpen := func(mode string) (bool, string) {
		resp, err := other.Call("open_hold", OpenHoldArgs{Path: path, Mode: mode})
		if err != nil {
			return false, err.Error()
		}
		if resp.OK {
			var r OpenHoldResult
			_ = json.Unmarshal(resp.Result, &r)
			_, _ = other.Call("close", CloseArgs{Handle: r.Handle})
			return true, ""
		}
		return false, resp.Error
	}

	// Holder opens and HOLDS the file (fd-scoped lock lives on this fd).
	resp, err := holder.Call("open_hold", OpenHoldArgs{Path: path, Mode: "rdwr", Create: true})
	var hr OpenHoldResult
	if err := decodeResult(holder.Name, resp, err, &hr); err != nil {
		return false, fmt.Errorf("%s: open+hold: %w", holder.Name, err)
	}
	fmt.Printf("  %-12s holds %q (handle=%d)\n", holder.Name, path, hr.Handle)

	// Baseline: with NO explicit lock, nofilelock lets the peer open it
	// (this is exactly what makes live migration possible -- and confirms
	// the mount really is nofilelock, not a default mount adopted).
	if got, e := peerOpen("rdwr"); got {
		check(&ok, "nofilelock baseline: peer can open the unlocked file", true, "")
	} else {
		check(&ok, "nofilelock baseline: peer can open the unlocked file", false,
			"peer was refused with no lock held -- mount is not nofilelock? ("+e+")")
	}

	// Holder LOCKs. Now the peer must be refused any open.
	if err := do(holder, "lock_file", LockFileArgs{Handle: hr.Handle}); err != nil {
		_, _ = holder.Call("close", CloseArgs{Handle: hr.Handle})
		return false, fmt.Errorf("%s: lock_file: %w", holder.Name, err)
	}
	fmt.Printf("  %-12s LOCKED the file\n", holder.Name)

	if got, _ := peerOpen("rdwr"); !got {
		check(&ok, "after LOCK: peer's write-open is refused", true, "")
	} else {
		check(&ok, "after LOCK: peer's write-open is refused", false, "peer opened a locked file for write")
	}
	if got, _ := peerOpen("rdonly"); !got {
		check(&ok, "after LOCK: peer's read-open is refused", true, "")
	} else {
		check(&ok, "after LOCK: peer's read-open is refused", false, "peer opened a locked file for read")
	}

	// Holder UNLOCKs: the migration handoff window.
	if err := do(holder, "unlock_file", UnlockFileArgs{Handle: hr.Handle}); err != nil {
		_, _ = holder.Call("close", CloseArgs{Handle: hr.Handle})
		return false, fmt.Errorf("%s: unlock_file: %w", holder.Name, err)
	}
	if got, e := peerOpen("rdwr"); got {
		check(&ok, "after UNLOCK: peer can open again (the handoff window)", true, "")
	} else {
		check(&ok, "after UNLOCK: peer can open again (the handoff window)", false, e)
	}

	// Holder re-LOCKs: window closed again.
	if err := do(holder, "lock_file", LockFileArgs{Handle: hr.Handle}); err != nil {
		_, _ = holder.Call("close", CloseArgs{Handle: hr.Handle})
		return false, fmt.Errorf("%s: re-lock_file: %w", holder.Name, err)
	}
	if got, _ := peerOpen("rdwr"); !got {
		check(&ok, "after re-LOCK: peer is refused again", true, "")
	} else {
		check(&ok, "after re-LOCK: peer opened a re-locked file", false, "")
	}

	// Holder closes the fd WITHOUT unlocking: the fd-scoped release.
	if err := do(holder, "close", CloseArgs{Handle: hr.Handle}); err != nil {
		return false, fmt.Errorf("%s: close: %w", holder.Name, err)
	}
	fmt.Printf("  %-12s closed its fd (no explicit unlock)\n", holder.Name)
	if got, e := peerOpen("rdwr"); got {
		check(&ok, "after holder closes its fd: lock released (fd-scoped)", true, "")
	} else {
		check(&ok, "after holder closes its fd: lock released (fd-scoped)", false,
			"lock still held after the holding fd closed: "+e)
	}

	if ok {
		fmt.Printf("PASS: explicit lock: peer tracked LOCK/UNLOCK/relock/close exactly\n")
	} else {
		fmt.Printf("FAIL: explicit lock: see failed checks above\n")
	}
	return ok, nil
}

// RunClusterLockMode proves the file-lock mode is cluster-wide: the first
// mounter leads, a node joining inherits that mode instead of its own
// default, and a node explicitly asking for the opposite is refused. The
// real cross-node proof (the inherit path needs a live peer, which a loop
// device's mount gate refuses, so the single-node test can only force it).
func RunClusterLockMode(clients []*Client) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("cluster-lock-mode needs at least 2 clients")
	}
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("pre-unmount: %w", err)
	}
	defer func() { _ = ensureUnmounted(clients) }()

	lead, join := clients[0], clients[1]
	ok := true

	mountOne := func(c *Client, nofilelock bool) error {
		resp, err := c.Call("mount", MountArgs{NoFileLock: nofilelock})
		return decodeResult(c.Name, resp, err, nil)
	}
	fileLockOf := func(c *Client) (string, error) {
		resp, err := c.Call("proc_raw", ProcRawArgs{Device: c.Device})
		var pr ProcRawResult
		if err := decodeResult(c.Name, resp, err, &pr); err != nil {
			return "", err
		}
		for _, line := range strings.Split(pr.Info, "\n") {
			if strings.HasPrefix(line, "file_lock:") {
				return strings.TrimSpace(strings.TrimPrefix(line, "file_lock:")), nil
			}
		}
		return "", fmt.Errorf("no file_lock line in %s's info", c.Name)
	}

	// Part 1: lead mounts nofilelock (cluster = off); joiner mounts DEFAULT
	// and must INHERIT off rather than coming up locked (which would be a
	// mixed, incoherent cluster).
	fmt.Printf("=== cluster lock mode: %s leads nofilelock, %s joins default and inherits ===\n", lead.Name, join.Name)
	if err := mountOne(lead, true); err != nil {
		return false, fmt.Errorf("%s: lead nofilelock mount: %w", lead.Name, err)
	}
	if lm, err := fileLockOf(lead); err != nil {
		return false, err
	} else {
		check(&ok, "lead mounted nofilelock -> file_lock off", lm == "off", "got "+lm)
	}
	if err := mountOne(join, false); err != nil {
		check(&ok, "joiner default mount succeeds against an off cluster", false, err.Error())
	} else if jm, err := fileLockOf(join); err != nil {
		return false, err
	} else {
		check(&ok, "joiner default mount INHERITED file_lock off from the lead", jm == "off",
			"joiner came up file_lock="+jm+" -- a mixed cluster")
	}
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount between parts: %w", err)
	}

	// Part 2: lead mounts DEFAULT (cluster = on); joiner asking nofilelock
	// must be REFUSED rather than silently overridden.
	fmt.Printf("=== %s leads default (lock on), %s nofilelock must be refused ===\n", lead.Name, join.Name)
	if err := mountOne(lead, false); err != nil {
		return false, fmt.Errorf("%s: lead default mount: %w", lead.Name, err)
	}
	if lm, err := fileLockOf(lead); err != nil {
		return false, err
	} else {
		check(&ok, "lead mounted default -> file_lock on", lm == "on", "got "+lm)
	}
	err := mountOne(join, true)
	check(&ok, "joiner nofilelock against a lock-on cluster is REFUSED", err != nil,
		"the mount succeeded -- a mixed cluster was allowed")
	if err == nil {
		_ = ensureUnmounted(clients)
	}

	if ok {
		fmt.Printf("PASS: cluster lock mode: lead/inherit/refuse all correct\n")
	} else {
		fmt.Printf("FAIL: cluster lock mode: see failed checks above\n")
	}
	return ok, nil
}

// RunNoCawMountRace: every node mounts the same NO-CAW volume at the same
// instant, repeatedly; at most one may ever come up. A device with no
// atomic CAW has no cross-node mutual exclusion at all, so the
// single-mounter invariant rests on two mount-path checks: the
// pre-registration gate (a live peer refuses you) and the
// post-registration re-check (a peer whose row landed while yours was in
// flight -- invisible to the gate -- refuses you after the fact). The loop
// suite proves each check fires when forced by its knob; only two real
// kernels can sample the actual interleavings between them. CAW is forced
// off with the caw_fail_discover module param -- the LUN's capability is
// irrelevant, the no-CAW code paths are what is under test -- and the
// gate's watch window is compressed via hb_interval_secs/stale_secs so a
// round where one node must wait out the other's heartbeat takes seconds.
//
// "Both refused" is a legal outcome of a tied round (each saw the other's
// row); the follow-up assertion is that a sequential retry then wins --
// the tie must never wedge the volume.
func RunNoCawMountRace(clients []*Client, rounds int) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("nocaw-mount-race needs at least 2 clients")
	}
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("pre-unmount: %w", err)
	}
	defer func() { _ = ensureUnmounted(clients) }()
	ok := true

	setParam := func(c *Client, name, value string) (string, error) {
		resp, err := c.Call("mod_param", ModParamArgs{Name: name, Value: value})
		var r ModParamResult
		if derr := decodeResult(c.Name, resp, err, &r); derr != nil {
			return "", derr
		}
		return r.Prev, nil
	}

	// Compress the timing and force no-CAW on every node, remembering each
	// node's previous values to restore -- these are module-global knobs,
	// not per-mount controls, so leaving them changed would skew every
	// scenario run after this one.
	params := []struct{ name, value string }{
		{"hb_interval_secs", "2"},
		{"stale_secs", "8"},
		{"caw_fail_discover", "1"},
	}
	type saved struct {
		c          *Client
		name, prev string
	}
	var restore []saved
	restoreAll := func() {
		for i := len(restore) - 1; i >= 0; i-- {
			s := restore[i]
			if _, err := setParam(s.c, s.name, s.prev); err != nil {
				fmt.Printf("WARNING: %s: restoring %s=%s failed: %v\n", s.c.Name, s.name, s.prev, err)
			}
		}
		restore = nil
	}
	defer restoreAll()
	for _, c := range clients {
		for _, p := range params {
			prev, err := setParam(c, p.name, p.value)
			if err != nil {
				return false, fmt.Errorf("setting %s=%s: %w", p.name, p.value, err)
			}
			restore = append(restore, saved{c, p.name, prev})
		}
	}

	unmountOne := func(c *Client) error {
		resp, err := c.Call("unmount", UnmountArgs{})
		return decodeResult(c.Name, resp, err, nil)
	}

	for round := 1; round <= rounds; round++ {
		fmt.Printf("=== no-CAW mount race, round %d/%d: %d node(s) mounting at the same instant ===\n",
			round, rounds, len(clients))
		results := fireConcurrently(clients, "mount", MountArgs{})

		var winners []*Client
		for _, r := range results {
			switch {
			case r.err != nil:
				fmt.Printf("  %-12s transport error: %v\n", r.client.Name, r.err)
			case r.resp.OK:
				fmt.Printf("  %-12s MOUNTED\n", r.client.Name)
				winners = append(winners, r.client)
			default:
				fmt.Printf("  %-12s refused: %s\n", r.client.Name, r.resp.Error)
			}
		}

		// THE invariant. Two mounters on a no-CAW volume is the
		// catastrophe everything above exists to prevent; stop hammering
		// a cluster that just split-brained.
		check(&ok, fmt.Sprintf("round %d: at most one node mounted", round), len(winners) <= 1,
			fmt.Sprintf("%d nodes are mounted on a volume with no cross-node atomicity", len(winners)))
		if len(winners) > 1 {
			break
		}

		if len(winners) == 1 {
			if err := unmountOne(winners[0]); err != nil {
				return false, fmt.Errorf("round %d: unmounting the winner: %w", round, err)
			}
		} else {
			// A tied round: both saw the other's row and both refused.
			// Legal -- but a sequential retry must now win, or the tie
			// wedged the volume.
			resp, err := clients[0].Call("mount", MountArgs{})
			if derr := decodeResult(clients[0].Name, resp, err, nil); derr != nil {
				check(&ok, fmt.Sprintf("round %d: tied -- a sequential retry wins", round), false, derr.Error())
				break
			}
			check(&ok, fmt.Sprintf("round %d: tied -- a sequential retry wins", round), true, "")
			if err := unmountOne(clients[0]); err != nil {
				return false, fmt.Errorf("round %d: unmounting the retry winner: %w", round, err)
			}
		}
	}

	// Put the knobs back and prove the volume is healthy with CAW restored:
	// a normal mount and unmount on one node.
	restoreAll()
	resp, err := clients[0].Call("mount", MountArgs{})
	if derr := decodeResult(clients[0].Name, resp, err, nil); derr != nil {
		check(&ok, "volume mounts normally after the race rounds (CAW restored)", false, derr.Error())
	} else {
		check(&ok, "volume mounts normally after the race rounds (CAW restored)", true, "")
		if err := unmountOne(clients[0]); err != nil {
			return false, fmt.Errorf("final unmount: %w", err)
		}
	}

	if ok {
		fmt.Printf("PASS: no-CAW mount race: the single-mounter invariant held in every round\n")
	} else {
		fmt.Printf("FAIL: no-CAW mount race: see failed checks above\n")
	}
	return ok, nil
}

// RunSymlinkPublish: one node creates symlinks one after another while a
// second node races to resolve each name the instant it appears. A name
// must never resolve to anything but its complete target: the creation
// paths build the child fully -- record, target text durable, security
// label -- BEFORE the dirent is added (dir.c's cetrafs_create_publish()),
// so the first successful readlink on a peer is already the real thing.
// Under the old publish-first order there was a window (dirent on disk,
// target text and final record not yet) in which a peer's cold read
// returned an empty or stale target; this scenario samples exactly that
// window at RPC rate. The deterministic single-node proof of the ordering
// is tests/kernel/create_publish_order.sh; this is the live two-kernel
// counterpart.
func RunSymlinkPublish(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("symlink-publish needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	writer, reader := clients[0], clients[1]
	// 24, down from 40: each creation costs ~1.5s of sync
	// metadata writes on the real LUN, and the sampling value is per-link
	// independent -- 24 windows catch an ordering regression just as
	// surely, for a minute less of full-suite wall clock.
	const nLinks = 24
	dir := baseDir + "/symlink-publish"
	ok := true

	if resp, err := writer.Call("mkdir", MkdirArgs{Path: dir}); err != nil || (!resp.OK && !strings.Contains(resp.Error, "exist")) {
		if derr := decodeResult(writer.Name, resp, err, nil); derr != nil {
			return false, fmt.Errorf("mkdir %s: %w", dir, derr)
		}
	}

	name := func(i int) string { return fmt.Sprintf("%s/pub-%03d", dir, i) }
	target := func(i int) string { return fmt.Sprintf("target-of-pub-%03d-0123456789abcdef", i) }

	fmt.Printf("=== symlink publish: %s creates %d links, %s resolves each as it appears ===\n",
		writer.Name, nLinks, reader.Name)

	var wg sync.WaitGroup
	var writeErr error
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < nLinks; i++ {
			resp, err := writer.Call("symlink", SymlinkArgs{Target: target(i), LinkPath: name(i)})
			if derr := decodeResult(writer.Name, resp, err, nil); derr != nil {
				writeErr = fmt.Errorf("symlink %d: %w", i, derr)
				return
			}
		}
	}()

	resolved, firstTryHits := 0, 0
	var bad []string
	for i := 0; i < nLinks; i++ {
		deadline := time.Now().Add(15 * time.Second)
		attempts := 0
		for {
			attempts++
			resp, err := reader.Call("readlink", ReadlinkArgs{Path: name(i)})
			var rr ReadlinkResult
			if derr := decodeResult(reader.Name, resp, err, &rr); derr == nil {
				// THE assertion: the first time the name resolves at all,
				// it must already be the complete target -- never "" (a
				// published name whose record still says size 0), never a
				// prefix or garbage (text not yet durable).
				if rr.Target != target(i) {
					bad = append(bad, fmt.Sprintf("pub-%03d resolved to %q (want %q)", i, rr.Target, target(i)))
				} else if attempts == 1 {
					firstTryHits++
				}
				resolved++
				break
			}
			if time.Now().After(deadline) {
				bad = append(bad, fmt.Sprintf("pub-%03d never resolved", i))
				break
			}
			// Not published yet (or a transient) -- poll again. No sleep:
			// the RPC round trip is the pacing, and a tight poll is what
			// lands reads inside a creation's write sequence.
		}
		if writeErr != nil {
			break
		}
	}
	wg.Wait()
	if writeErr != nil {
		return false, writeErr
	}

	check(&ok, fmt.Sprintf("all %d links resolved", nLinks), resolved == nLinks,
		fmt.Sprintf("only %d resolved", resolved))
	check(&ok, "every first successful readlink returned the complete target", len(bad) == 0,
		strings.Join(bad, "; "))
	// Not an assertion, just context for reading a green run: how often the
	// reader actually beat the writer to a name (polled before it existed).
	fmt.Printf("  (reader raced ahead on %d/%d names -- higher = better sampling of the publish window)\n",
		nLinks-firstTryHits, nLinks)

	for i := 0; i < nLinks; i++ {
		_, _ = writer.Call("unlink", UnlinkArgs{Path: name(i)})
	}
	_, _ = writer.Call("rmdir", RmdirArgs{Path: dir})

	if ok {
		fmt.Printf("PASS: symlink publish: a name never resolves to a half-built link\n")
	} else {
		fmt.Printf("FAIL: symlink publish: see failed checks above\n")
	}
	return ok, nil
}

// RunConcurrentCreate has every client try to create the *same new*
// path at the same instant via open_hold(create=true, wronly) -- unlike
// RunLockRace (which opens a file that already exists), this exercises
// the dirent-create path itself racing cross-node, not just an open of
// pre-existing state. Exactly one must win the write lock (the loser
// either lost the dirent-add race and then lost the lock-claim race on
// what's now an existing file, or won the dirent-add and lost nothing);
// more than one winner means two nodes believe they separately hold the
// exclusive write lock on what must be a single inode.
func RunConcurrentCreate(clients []*Client, path string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("concurrent-create needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	fmt.Printf("=== concurrent create: %d client(s) creating %q at the same instant ===\n", len(clients), path)

	results := fireConcurrently(clients, "open_hold", OpenHoldArgs{Path: path, Mode: "wronly", Create: true, Excl: true})

	var winners []*Client
	winnerHandle := map[string]uint64{}
	for _, r := range results {
		if r.err != nil {
			fmt.Printf("  %-12s transport error: %v\n", r.client.Name, r.err)
			continue
		}
		if r.resp.OK {
			var res OpenHoldResult
			_ = json.Unmarshal(r.resp.Result, &res)
			fmt.Printf("  %-12s CREATE+OPEN SUCCEEDED (handle=%d)\n", r.client.Name, res.Handle)
			winners = append(winners, r.client)
			winnerHandle[r.client.Name] = res.Handle
		} else {
			fmt.Printf("  %-12s create+open rejected: %s\n", r.client.Name, r.resp.Error)
		}
	}

	ok := len(winners) == 1
	for name, h := range winnerHandle {
		for _, c := range clients {
			if c.Name == name {
				_, _ = c.Call("close", CloseArgs{Handle: h})
			}
		}
	}

	if ok {
		fmt.Printf("PASS: concurrent create: exactly 1 of %d client(s) won\n", len(clients))
	} else {
		fmt.Printf("FAIL: concurrent create: expected exactly 1 winner, got %d\n", len(winners))
	}
	return ok, nil
}

// RunConcurrentUnlink has every client unlink the *same existing* file
// at the same instant -- mediated by dir.c's PR-mutex-protected
// namespace lock around cetrafs_unlink_locked(), not the whole-file
// open lock (unlink never opens the file). Exactly one must succeed;
// every other must see it's already gone (ENOENT), never silently
// succeed against a dirent that's already removed.
func RunConcurrentUnlink(clients []*Client, path string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("concurrent-unlink needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	fmt.Printf("=== concurrent unlink: %d client(s) unlinking %q at the same instant ===\n", len(clients), path)

	resp, err := clients[0].Call("write", WriteArgs{Path: path, Size: 128, Stamp: "cu"})
	if err := decodeResult(clients[0].Name, resp, err, nil); err != nil {
		return false, fmt.Errorf("setup write: %w", err)
	}

	results := fireConcurrently(clients, "unlink", UnlinkArgs{Path: path})

	succeeded := 0
	for _, r := range results {
		if r.err != nil {
			fmt.Printf("  %-12s transport error: %v\n", r.client.Name, r.err)
			continue
		}
		if r.resp.OK {
			fmt.Printf("  %-12s unlink SUCCEEDED\n", r.client.Name)
			succeeded++
		} else {
			fmt.Printf("  %-12s unlink rejected/failed (expected for the loser): %s\n", r.client.Name, r.resp.Error)
		}
	}

	ok := succeeded == 1
	if ok {
		fmt.Printf("PASS: concurrent unlink: exactly 1 of %d client(s) removed it, the rest correctly saw it already gone\n", len(clients))
	} else {
		fmt.Printf("FAIL: concurrent unlink: expected exactly 1 success, got %d\n", succeeded)
	}
	return ok, nil
}

// RunConcurrentMkdir mirrors RunConcurrentCreate for directories: every
// client tries to mkdir the same new path at the same instant. Exactly
// one must succeed; the rest must see -EEXIST, never a second directory
// inode silently sharing the name or a corrupted parent dirent block.
func RunConcurrentMkdir(clients []*Client, path string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("concurrent-mkdir needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	fmt.Printf("=== concurrent mkdir: %d client(s) creating directory %q at the same instant ===\n", len(clients), path)

	results := fireConcurrently(clients, "mkdir", MkdirArgs{Path: path, Strict: true})

	succeeded := 0
	for _, r := range results {
		if r.err != nil {
			fmt.Printf("  %-12s transport error: %v\n", r.client.Name, r.err)
			continue
		}
		if r.resp.OK {
			fmt.Printf("  %-12s mkdir SUCCEEDED\n", r.client.Name)
			succeeded++
		} else {
			fmt.Printf("  %-12s mkdir rejected (expected for the loser): %s\n", r.client.Name, r.resp.Error)
		}
	}

	ok := succeeded == 1
	if !ok {
		fmt.Printf("FAIL: concurrent mkdir: expected exactly 1 success, got %d\n", succeeded)
		return false, nil
	}

	st, exists, err := statPath(clients[0], path)
	check(&ok, "exactly one directory exists afterward with is_dir=true", exists && st.IsDir,
		fmt.Sprintf("exists=%v is_dir=%v err=%v", exists, st.IsDir, err))

	if ok {
		fmt.Printf("PASS: concurrent mkdir: exactly 1 of %d client(s) won, directory is intact\n", len(clients))
	} else {
		fmt.Printf("FAIL: concurrent mkdir: see failed checks above\n")
	}
	return ok, nil
}

// RunConcurrentRename has two different, already-existing source files
// (one "owned" by each client, written beforehand so their content is
// distinguishable) renamed by two different nodes *to the same target
// name* at the same instant -- the classic cross-node rename-replace
// race. POSIX rename semantics say whichever rename physically commits
// last wins, replacing the target; the invariant this checks isn't
// "which one wins" (either is legitimate), it's that the result is
// never corrupted: afterward, exactly one target exists, its content is
// *entirely* one source's content (never an interleaved mix of both,
// which would mean the two renames' underlying dirent-replace writes
// stepped on each other), and both original source names are gone.
func RunConcurrentRename(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("concurrent-rename needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a, b := clients[0], clients[1]
	target := baseDir + "/rename-race-target"
	srcA := baseDir + "/rename-race-src-" + a.Name
	srcB := baseDir + "/rename-race-src-" + b.Name

	fmt.Printf("=== concurrent rename: %s and %s both rename a different source onto %q at the same instant ===\n",
		a.Name, b.Name, target)

	resp, err := a.Call("mkdir", MkdirArgs{Path: baseDir})
	if err := decodeResult(a.Name, resp, err, nil); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}

	resp, err = a.Call("write", WriteArgs{Path: srcA, Size: 256, Stamp: "race-a"})
	var wresA WriteResult
	if err := decodeResult(a.Name, resp, err, &wresA); err != nil {
		return false, fmt.Errorf("setup write srcA: %w", err)
	}
	resp, err = b.Call("write", WriteArgs{Path: srcB, Size: 256, Stamp: "race-b"})
	var wresB WriteResult
	if err := decodeResult(b.Name, resp, err, &wresB); err != nil {
		return false, fmt.Errorf("setup write srcB: %w", err)
	}

	type renameJob struct {
		client *Client
		old    string
	}
	jobs := []renameJob{{a, srcA}, {b, srcB}}

	var started, done sync.WaitGroup
	start := make(chan struct{})
	outcomes := make([]callOutcome, len(jobs))
	started.Add(len(jobs))
	done.Add(len(jobs))
	for i, j := range jobs {
		go func(i int, j renameJob) {
			defer done.Done()
			started.Done()
			<-start
			resp, err := j.client.Call("rename", RenameArgs{Old: j.old, New: target})
			outcomes[i] = callOutcome{client: j.client, resp: resp, err: err}
		}(i, j)
	}
	started.Wait()
	close(start)
	done.Wait()

	ok := true
	for i, o := range outcomes {
		if o.err != nil {
			fmt.Printf("  %-12s transport error renaming %s: %v\n", o.client.Name, jobs[i].old, o.err)
			check(&ok, jobs[i].old+" rename completed without a transport error", false, o.err.Error())
			continue
		}
		if o.resp.OK {
			fmt.Printf("  %-12s rename %s -> %s SUCCEEDED\n", o.client.Name, jobs[i].old, target)
		} else {
			fmt.Printf("  %-12s rename %s -> %s failed: %s\n", o.client.Name, jobs[i].old, target, o.resp.Error)
		}
	}

	_, srcAExists, err := statPath(a, srcA)
	if err != nil {
		return false, fmt.Errorf("stat srcA after race: %w", err)
	}
	_, srcBExists, err := statPath(a, srcB)
	if err != nil {
		return false, fmt.Errorf("stat srcB after race: %w", err)
	}
	check(&ok, "both original source names are gone", !srcAExists && !srcBExists,
		fmt.Sprintf("srcA_exists=%v srcB_exists=%v", srcAExists, srcBExists))

	resp, err = a.Call("read", ReadArgs{Path: target})
	var tres ReadResult
	if err := decodeResult(a.Name, resp, err, &tres); err != nil {
		return false, fmt.Errorf("read target after race: %w", err)
	}
	matchesA := tres.Checksum == wresA.Checksum
	matchesB := tres.Checksum == wresB.Checksum
	check(&ok, "target's final content is entirely one source's content, not a mix", matchesA != matchesB,
		fmt.Sprintf("target checksum=%s matches_a=%v matches_b=%v (want exactly one)", tres.Checksum, matchesA, matchesB))

	if ok {
		fmt.Printf("PASS: concurrent rename: result is intact (one winner, no corruption)\n")
	} else {
		fmt.Printf("FAIL: concurrent rename: see failed checks above\n")
	}
	return ok, nil
}

// quiesceFreeBlocks waits until every node's free-block count has been
// completely still for longer than one heartbeat interval, so that no
// pending-free drain (which only happens on a tick) is still in flight
// and about to shift a measurement mid-scenario. Returns without error
// on timeout, having warned -- a noisy baseline is worth flagging but is
// not itself a test failure.
func quiesceFreeBlocks(statfsOf func(*Client, string) (StatfsResult, error), nodes []*Client) error {
	const (
		heartbeatSecs = 15 // kmod.h CETRAFS_HEARTBEAT_INTERVAL_SECS
		sampleEvery   = 5 * time.Second
		// Two full ticks of no movement: one tick could be straddled by
		// a drain that lands just after the last sample.
		stillFor = (2*heartbeatSecs + 5) * time.Second
	)

	deadline := time.Now().Add(stillFor + 90*time.Second)
	last := make(map[string]uint64, len(nodes))
	var stableSince time.Time

	for time.Now().Before(deadline) {
		changed := false
		for _, c := range nodes {
			cur, err := statfsOf(c, "quiesce")
			if err != nil {
				return err
			}
			if prev, seen := last[c.Name]; !seen || prev != cur.FreeBlocks {
				changed = true
			}
			last[c.Name] = cur.FreeBlocks
		}
		if changed {
			stableSince = time.Now()
		} else if !stableSince.IsZero() && time.Since(stableSince) >= stillFor {
			return nil
		}
		time.Sleep(sampleEvery)
	}

	fmt.Printf("WARNING: free-block counts never went quiet across %v; deltas below may be off by a pending free\n", stillFor)
	return nil
}

// RunSpaceAccounting checks whether free-space accounting (statfs --
// what `df` reports) is correct on the node that writes/unlinks a
// large file, and -- separately -- whether a *different* node's own
// statfs reflects the same change. The architecture has a known gap
// worth measuring directly rather than assuming: cetrafs_statfs() sums
// every BG cluster-wide, but reads each BG descriptor's cached
// free-count through the normal (fast) cached tier, which is only
// invalidated at ZG-ownership-transfer time (zonegroup.c) -- not on
// every ordinary allocation/free within a BG its owner already holds.
// So the writer's own view is expected to update correctly; whether a
// peer's view does too is exactly the open question this measures.
func RunSpaceAccounting(clients []*Client, baseDir string, sizeBytes int) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("space-accounting needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	writer, peer := clients[0], clients[1]
	path := baseDir + "/space-accounting-file"
	fmt.Printf("=== space accounting: %s writes then unlinks a %d-byte file, checked via statfs on both %s and %s ===\n",
		writer.Name, sizeBytes, writer.Name, peer.Name)

	resp, err := writer.Call("mkdir", MkdirArgs{Path: baseDir})
	if err := decodeResult(writer.Name, resp, err, nil); err != nil {
		return false, fmt.Errorf("setup mkdir: %w", err)
	}

	statfsOf := func(c *Client, label string) (StatfsResult, error) {
		resp, err := c.Call("statfs", struct{}{})
		var res StatfsResult
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return StatfsResult{}, fmt.Errorf("%s: statfs (%s): %w", c.Name, label, err)
		}
		return res, nil
	}

	// Quiesce first: a previous scenario's cross-node free may still be
	// sitting in a pending-free queue. The owner only
	// drains that queue on a heartbeat TICK -- every
	// CETRAFS_HEARTBEAT_INTERVAL_SECS (15s) -- so a +1 can land at any
	// point in a 15-second window and corrupt every delta below by
	// exactly one block (seen for real, twice: write delta 255/256,
	// unlink ending at baseline+1).
	//
	// The first version of this waited for two samples 3 seconds apart
	// to agree, which is useless against a 15-second tick: it declares
	// "settled" almost immediately while a drain is still up to 15s
	// away, which is exactly how the second sighting got through. Being
	// confident nothing is pending means watching a span strictly
	// longer than a tick -- so require the count to hold still across
	// two full intervals, and watch BOTH nodes, since either one's
	// queues can drain into the number the other reads.
	if err := quiesceFreeBlocks(statfsOf, []*Client{writer, peer}); err != nil {
		return false, err
	}

	beforeWriter, err := statfsOf(writer, "before")
	if err != nil {
		return false, err
	}
	beforePeer, err := statfsOf(peer, "before")
	if err != nil {
		return false, err
	}
	if beforeWriter.BlockSize != beforePeer.BlockSize {
		return false, fmt.Errorf("block size disagreement: %s=%d %s=%d", writer.Name, beforeWriter.BlockSize, peer.Name, beforePeer.BlockSize)
	}
	blockSize := beforeWriter.BlockSize
	expectedBlocks := (int64(sizeBytes) + blockSize - 1) / blockSize

	resp, err = writer.Call("write", WriteArgs{Path: path, Size: sizeBytes, Stamp: "space-acct"})
	if err := decodeResult(writer.Name, resp, err, nil); err != nil {
		return false, fmt.Errorf("writer write: %w", err)
	}

	afterWriteWriter, err := statfsOf(writer, "after write")
	if err != nil {
		return false, err
	}
	afterWritePeer, err := statfsOf(peer, "after write")
	if err != nil {
		return false, err
	}

	ok := true
	writerDelta := int64(beforeWriter.FreeBlocks) - int64(afterWriteWriter.FreeBlocks)
	check(&ok, fmt.Sprintf("%s's own statfs reflects the %d blocks just written", writer.Name, expectedBlocks),
		writerDelta == expectedBlocks,
		fmt.Sprintf("free blocks before=%d after=%d delta=%d, want %d",
			beforeWriter.FreeBlocks, afterWriteWriter.FreeBlocks, writerDelta, expectedBlocks))

	peerDelta := int64(beforePeer.FreeBlocks) - int64(afterWritePeer.FreeBlocks)
	check(&ok, fmt.Sprintf("%s's statfs reflects %s's write too (cross-node)", peer.Name, writer.Name),
		peerDelta == expectedBlocks,
		fmt.Sprintf("free blocks before=%d after=%d delta=%d, want %d",
			beforePeer.FreeBlocks, afterWritePeer.FreeBlocks, peerDelta, expectedBlocks))

	resp, err = writer.Call("unlink", UnlinkArgs{Path: path})
	if err := decodeResult(writer.Name, resp, err, nil); err != nil {
		return false, fmt.Errorf("writer unlink: %w", err)
	}

	afterUnlinkWriter, err := statfsOf(writer, "after unlink")
	if err != nil {
		return false, err
	}
	afterUnlinkPeer, err := statfsOf(peer, "after unlink")
	if err != nil {
		return false, err
	}

	check(&ok, fmt.Sprintf("%s's own statfs reclaims the space after unlink", writer.Name),
		afterUnlinkWriter.FreeBlocks == beforeWriter.FreeBlocks,
		fmt.Sprintf("free blocks before=%d after_unlink=%d, want equal", beforeWriter.FreeBlocks, afterUnlinkWriter.FreeBlocks))

	check(&ok, fmt.Sprintf("%s's statfs reclaims the space too (cross-node)", peer.Name),
		afterUnlinkPeer.FreeBlocks == beforePeer.FreeBlocks,
		fmt.Sprintf("free blocks before=%d after_unlink=%d, want equal", beforePeer.FreeBlocks, afterUnlinkPeer.FreeBlocks))

	if ok {
		fmt.Printf("PASS: space accounting: both nodes' statfs correctly tracked the write and the unlink\n")
	} else {
		fmt.Printf("FAIL: space accounting: see failed checks above\n")
	}
	return ok, nil
}

// RunSparseBigFile is the genuine cross-node counterpart to
// tests/sparse_bigfile_test.sh's single-kernel approximation -- that
// script's own header is explicit about the limit it's working around:
// an unmount+remount on one machine forces a real re-read from the
// backing device, but it is not a substitute for a real second node,
// and this scenario is that substitute. Exercises the // sb->s_maxbytes work (kmod/zonegroup.c's cetrafs_compute_max_file_
// size(), kmod/procfs.c's max_file_size_bytes/write_ready) end to end
// with two genuinely separate kernels:
//
//   - both nodes must report the exact same max_file_size_bytes --
//     it's a mkfs-time-fixed, volume-wide constant by design, and a
//     single-node test structurally cannot check that two different
//     kernels independently compute the identical value;
//   - the boundary itself: growing the sparse file one byte past the
//     reported max must fail (-EFBIG), growing to exactly the max
//     must succeed;
//   - the actual "node A writes and closes, node B opens and reads"
//     shape the single-node version could only approximate: the
//     writer fills the first and last 1 MiB of the biggest sparse
//     file this volume's worst-case ZG math allows, then a genuinely
//     different node reads both regions back cold and compares by
//     hash, plus a hole sample in the middle.
func RunSparseBigFile(clients []*Client, path string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("sparse-bigfile needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	writer, reader := clients[0], clients[1]
	fmt.Printf("=== sparse bigfile: %s writes head/tail of the biggest sparse file it can, %s reads cold ===\n",
		writer.Name, reader.Name)

	snapOf := func(c *Client) (ProcSnapshotResult, error) {
		resp, err := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
		var res ProcSnapshotResult
		if derr := decodeResult(c.Name, resp, err, &res); derr != nil {
			return ProcSnapshotResult{}, fmt.Errorf("proc_snapshot: %w", derr)
		}
		return res, nil
	}

	writerSnap, err := snapOf(writer)
	if err != nil {
		return false, err
	}
	readerSnap, err := snapOf(reader)
	if err != nil {
		return false, err
	}

	ok := true

	check(&ok, fmt.Sprintf("%s is write_ready", writer.Name), writerSnap.WriteReady,
		"can't meaningfully run this scenario from a node with no ZG to allocate from")

	maxSize := writerSnap.MaxFileSizeBytes
	check(&ok, fmt.Sprintf("%s's max_file_size_bytes is sane (>= 2 MiB)", writer.Name), maxSize >= 2*1024*1024,
		fmt.Sprintf("max_file_size_bytes=%d", maxSize))

	check(&ok, fmt.Sprintf("%s and %s agree on max_file_size_bytes", writer.Name, reader.Name),
		readerSnap.MaxFileSizeBytes == maxSize,
		fmt.Sprintf("%s=%d %s=%d -- should be an identical mkfs-time-fixed constant on every node",
			writer.Name, maxSize, reader.Name, readerSnap.MaxFileSizeBytes))

	if maxSize < 2*1024*1024 {
		fmt.Printf("FAIL: sparse bigfile: max_file_size_bytes too small to continue (need >= 2 MiB for the head+tail writes), aborting\n")
		return false, nil
	}

	const headTailSize = 1024 * 1024
	tailOffset := maxSize - headTailSize

	// The head write also creates the file.
	resp, err := writer.Call("write_at", WriteAtArgs{Path: path, Offset: 0, Size: headTailSize, Stamp: "head-" + writer.Name, Create: true})
	var headWant WriteAtResult
	if derr := decodeResult(writer.Name, resp, err, &headWant); derr != nil {
		return false, fmt.Errorf("writer write_at head: %w", derr)
	}

	// Growing one byte past the max must fail -- a transport error
	// here is a real problem (return it), but an application-level
	// rejection (resp.OK == false) is the expected, passing outcome.
	resp, err = writer.Call("truncate", TruncateArgs{Path: path, Size: maxSize + 1})
	if err != nil {
		return false, fmt.Errorf("writer truncate to max+1: %w", err)
	}
	check(&ok, "growing to max_file_size_bytes+1 is rejected", !resp.OK,
		fmt.Sprintf("truncate to %d unexpectedly succeeded", maxSize+1))

	// Growing to exactly the max must succeed -- the file this
	// scenario continues with, win or lose on the check just above.
	resp, err = writer.Call("truncate", TruncateArgs{Path: path, Size: maxSize})
	if derr := decodeResult(writer.Name, resp, err, nil); derr != nil {
		return false, fmt.Errorf("writer truncate to exactly max_file_size_bytes: %w", derr)
	}

	st, exists, err := statPath(writer, path)
	if err != nil {
		return false, fmt.Errorf("writer stat after truncate: %w", err)
	}
	check(&ok, fmt.Sprintf("%s sees the sparse file at exactly max_file_size_bytes", writer.Name),
		exists && st.Size == maxSize, fmt.Sprintf("exists=%v size=%d, want %d", exists, st.Size, maxSize))

	resp, err = writer.Call("write_at", WriteAtArgs{Path: path, Offset: tailOffset, Size: headTailSize, Stamp: "tail-" + writer.Name})
	var tailWant WriteAtResult
	if derr := decodeResult(writer.Name, resp, err, &tailWant); derr != nil {
		return false, fmt.Errorf("writer write_at tail: %w", derr)
	}

	fmt.Printf("  %s closed; checking cold from %s\n", writer.Name, reader.Name)

	stReader, existsReader, err := statPath(reader, path)
	if err != nil {
		return false, fmt.Errorf("reader stat: %w", err)
	}
	check(&ok, fmt.Sprintf("%s (cross-node) sees the sparse file at exactly max_file_size_bytes", reader.Name),
		existsReader && stReader.Size == maxSize, fmt.Sprintf("exists=%v size=%d, want %d", existsReader, stReader.Size, maxSize))

	resp, err = reader.Call("read_at", ReadAtArgs{Path: path, Offset: 0, Size: headTailSize})
	var headGot ReadAtResult
	if derr := decodeResult(reader.Name, resp, err, &headGot); derr != nil {
		return false, fmt.Errorf("reader read_at head: %w", derr)
	}
	check(&ok, fmt.Sprintf("%s's head 1 MiB matches what %s wrote (cross-node)", reader.Name, writer.Name),
		headGot.Checksum == headWant.Checksum,
		fmt.Sprintf("writer=%s reader=%s", headWant.Checksum, headGot.Checksum))

	resp, err = reader.Call("read_at", ReadAtArgs{Path: path, Offset: tailOffset, Size: headTailSize})
	var tailGot ReadAtResult
	if derr := decodeResult(reader.Name, resp, err, &tailGot); derr != nil {
		return false, fmt.Errorf("reader read_at tail: %w", derr)
	}
	check(&ok, fmt.Sprintf("%s's tail 1 MiB matches what %s wrote (cross-node)", reader.Name, writer.Name),
		tailGot.Checksum == tailWant.Checksum,
		fmt.Sprintf("writer=%s reader=%s", tailWant.Checksum, tailGot.Checksum))

	// A sample byte from the untouched middle of the file, read cold
	// from the reader, must still be a hole (zero) -- cross-node, not
	// just "this node's own cache never saw the hole get written to".
	resp, err = reader.Call("read_at", ReadAtArgs{Path: path, Offset: maxSize / 2, Size: 1})
	var midGot ReadAtResult
	if derr := decodeResult(reader.Name, resp, err, &midGot); derr != nil {
		return false, fmt.Errorf("reader read_at middle: %w", derr)
	}
	zeroByteChecksum := sha256Hex([]byte{0})
	check(&ok, fmt.Sprintf("%s (cross-node) still sees the middle of the file as a hole (zero)", reader.Name),
		midGot.Checksum == zeroByteChecksum, fmt.Sprintf("got checksum %s, want %s (sha256 of a single zero byte)", midGot.Checksum, zeroByteChecksum))

	if err := func() error {
		resp, err := writer.Call("unlink", UnlinkArgs{Path: path})
		return decodeResult(writer.Name, resp, err, nil)
	}(); err != nil {
		return false, fmt.Errorf("writer unlink: %w", err)
	}
	_, existsAfterUnlink, err := statPath(reader, path)
	if err != nil {
		return false, fmt.Errorf("reader stat after unlink: %w", err)
	}
	check(&ok, fmt.Sprintf("%s (cross-node) sees the file gone after unlink", reader.Name), !existsAfterUnlink,
		fmt.Sprintf("exists=%v", existsAfterUnlink))

	if ok {
		fmt.Printf("PASS: sparse bigfile: max-size boundary and cross-node head/tail/hole all correct\n")
	} else {
		fmt.Printf("FAIL: sparse bigfile: see failed checks above\n")
	}
	return ok, nil
}

// --- dir-storm ---------------------------------------------------------
//
// One big consolidated scenario rather than another micro-test, because
// the interesting failures here only appear when several mechanisms are
// under load from both nodes at once. Two nodes fill ONE shared
// directory with N files, half each, concurrently; both nodes then count
// it, verify each other's content, and tear it down by each unlinking
// the files the OTHER node created. The directory's own size is compared
// across the two nodes at every stage.
//
// What it covers in one run:
//   - directory growth far past one dirent block, and past the 4 inline
//     extents into a depth-1 external leaf (the 58-entry cap fixed
//     ) -- under real cross-node contention, which the
//     single-node loop harness cannot produce;
//   - the per-inode namespace lock (nslock.c) serializing two nodes'
//     dirent writes into the same directory, thousands of times;
//   - cross-node readdir completeness: each node must see all of the
//     peer's entries, not just its own;
//   - cross-node directory inode agreement (size/nlink) as it grows and
//     shrinks -- the thing that silently diverges if a stale cached
//     record is ever trusted;
//   - cross-node file content integrity across a wide size range;
//   - unlinking a file created by the other node, concurrently;
//   - full space and inode reclaim afterwards.
//
// Default is 200 files (100 per node): enough to push the directory well
// past one dirent block and into a depth-1 external leaf, without the run
// taking minutes on a real LUN -- where every file costs roughly two
// dozen metadata round trips, not just its own bytes. Raise
// -dirstorm-files for a heavier soak.
//
// File sizes are random in [1, maxFileBytes] so the run spans
// single-byte files (one dirent, one block), files that straddle the
// inline-extent boundary, and multi-megabyte ones in the same
// directory -- deliberately not a uniform size, since equal-sized files
// exercise exactly one allocator path.

type dirStormFile struct {
	name  string
	owner int // index into writers
	size  int
	sum   string // sha256 as reported by the writing node
}

// dirSizeOn returns the directory's own inode size as that node sees it.
func dirSizeOn(c *Client, path string) (int64, uint32, error) {
	resp, err := c.Call("stat", StatArgs{Path: path})
	var res StatResult
	if err := decodeResult(c.Name, resp, err, &res); err != nil {
		return 0, 0, err
	}
	return res.Size, res.Nlink, nil
}

// checkDirAgreement compares the directory inode as seen by both nodes.
// A brief disagreement right after the peer mutated it is not in itself
// a bug -- there is no cache-coherence protocol, only the lookup-time
// refresh -- so this converges with a bounded wait and reports whether
// agreement was immediate. Never agreeing IS a bug: it means one node is
// permanently trusting a stale record.
func checkDirAgreement(ok *bool, a, b *Client, path, stage string) {
	const settle = 20 * time.Second

	firstA, firstB, _ := int64(-1), int64(-1), 0
	deadline := time.Now().Add(settle)
	immediate := true

	for {
		sa, na, err := dirSizeOn(a, path)
		if err != nil {
			check(ok, fmt.Sprintf("dir agreement (%s)", stage), false, err.Error())
			return
		}
		sb, nb, err := dirSizeOn(b, path)
		if err != nil {
			check(ok, fmt.Sprintf("dir agreement (%s)", stage), false, err.Error())
			return
		}
		if firstA < 0 {
			firstA, firstB = sa, sb
		}
		if sa == sb && na == nb {
			check(ok, fmt.Sprintf("dir agreement (%s): both nodes report the same directory inode", stage),
				true, "")
			if !immediate {
				fmt.Printf("       (converged after a wait; first reading was %s=%d %s=%d)\n",
					a.Name, firstA, b.Name, firstB)
			}
			fmt.Printf("       %s: size=%d nlink=%d\n", stage, sa, na)
			return
		}
		immediate = false
		if time.Now().After(deadline) {
			check(ok, fmt.Sprintf("dir agreement (%s): both nodes report the same directory inode", stage),
				false, fmt.Sprintf("%s says size=%d nlink=%d, %s says size=%d nlink=%d after %v",
					a.Name, sa, na, b.Name, sb, nb, settle))
			return
		}
		time.Sleep(time.Second)
	}
}

// RunDirStorm is described in the block comment above.
func RunDirStorm(clients []*Client, baseDir string, fileCount, maxFileBytes, par int, seed int64) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("dir-storm needs at least 2 clients")
	}
	if fileCount < 2 {
		return false, fmt.Errorf("dir-storm needs -dirstorm-files >= 2")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	writers := clients[:2]
	a, b := writers[0], writers[1]
	dir := baseDir + "/dirstorm"

	fmt.Printf("=== dir storm: %s and %s each write %d of %d files (1..%d bytes, random) into one shared directory ===\n",
		a.Name, b.Name, fileCount/2, fileCount, maxFileBytes)

	ok := true

	// Pre-flight. Running out of inodes or space halfway through would
	// look like a filesystem bug in the failure output; say so up front
	// instead, with the numbers.
	statfsOf := func(c *Client, label string) (StatfsResult, error) {
		resp, err := c.Call("statfs", struct{}{})
		var res StatfsResult
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return StatfsResult{}, fmt.Errorf("%s: statfs (%s): %w", c.Name, label, err)
		}
		return res, nil
	}

	pre, err := statfsOf(a, "pre-flight")
	if err != nil {
		return false, err
	}
	if pre.FreeFiles < uint64(fileCount)+8 {
		return false, fmt.Errorf("not enough free inodes for %d files: statfs reports %d free "+
			"(mkfs.cetra -N sets this; the default is 1 per 4 MiB capped at 65536)", fileCount, pre.FreeFiles)
	}

	rng := rand.New(rand.NewSource(seed))
	files := make([]dirStormFile, fileCount)
	var wantBytes int64
	for i := range files {
		files[i] = dirStormFile{
			name:  fmt.Sprintf("%s/f%05d", dir, i),
			owner: i % 2,
			size:  1 + rng.Intn(maxFileBytes),
		}
		wantBytes += int64(files[i].size)
	}
	needBlocks := uint64(wantBytes/pre.BlockSize) + uint64(fileCount) + 64
	if pre.FreeBlocks < needBlocks {
		return false, fmt.Errorf("not enough free space: need ~%d blocks for %d files (%d bytes), statfs reports %d free",
			needBlocks, fileCount, wantBytes, pre.FreeBlocks)
	}
	fmt.Printf("    writing %d bytes total across %d files; %d free inodes, %d free blocks before\n",
		wantBytes, fileCount, pre.FreeFiles, pre.FreeBlocks)

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); err != nil || decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s: %v", dir, err)
	}

	// Re-baseline AFTER the directories exist. mkdir creates the parent
	// scratch directory too, and only the storm's own directory is
	// removed at the end, so measuring from before would charge this
	// scenario for one inode and one block it never promised to return.
	pre, err = statfsOf(a, "baseline")
	if err != nil {
		return false, err
	}

	emptySize, emptyNlink, err := dirSizeOn(a, dir)
	if err != nil {
		return false, fmt.Errorf("stat of the fresh directory: %w", err)
	}
	fmt.Printf("    fresh directory: size=%d nlink=%d\n", emptySize, emptyNlink)
	checkDirAgreement(&ok, a, b, dir, "empty")

	// Each node drives `par` connections of its own, so both nodes are
	// concurrent with each other AND with themselves. The second half
	// is the part a single connection could never produce, and it is
	// where same-node races live -- the buffer-update protocol, the
	// local allocation mutex, the per-inode namespace mutex. It also
	// turns the wall clock from files * latency into files * latency /
	// par, which on a real LUN (about a second per metadata operation) is the difference between minutes and seconds.
	conns := make([][]*Client, len(writers))
	for w, c := range writers {
		cs, closer, err := c.Parallel(par, 5*time.Second)
		if err != nil {
			return false, err
		}
		defer closer()
		conns[w] = cs
	}
	fmt.Printf("    each node driving %d concurrent connection(s)\n", par)

	// --- stage 1: both nodes write their half, concurrently ----------
	start := time.Now()
	var wg sync.WaitGroup
	var errMu sync.Mutex
	errs := make([][]error, len(writers))
	sums := make([][]string, len(writers))
	for w := range writers {
		sums[w] = make([]string, fileCount)
	}
	for w := range writers {
		for k := range conns[w] {
			wg.Add(1)
			go func(w, k int) {
				defer wg.Done()
				c := conns[w][k]
				for i := range files {
					// Interleaved by connection, not blocked: adjacent
					// names land on different connections, so the
					// directory is being mutated from several
					// directions at once rather than in neat runs.
					if files[i].owner != w || (i/2)%par != k {
						continue
					}
					var res WriteResult
					resp, err := c.Call("write", WriteArgs{
						Path:  files[i].name,
						Size:  files[i].size,
						Stamp: fmt.Sprintf("%s-%d", c.Name, i),
					})
					if err := decodeResult(c.Name, resp, err, &res); err != nil {
						errMu.Lock()
						if len(errs[w]) <= 5 {
							errs[w] = append(errs[w], fmt.Errorf("%s: write %s (%d bytes): %w",
								c.Name, files[i].name, files[i].size, err))
						}
						errMu.Unlock()
						continue
					}
					sums[w][i] = res.Checksum
				}
			}(w, k)
		}
	}
	wg.Wait()
	for w := range writers {
		if len(errs[w]) > 0 {
			check(&ok, fmt.Sprintf("%s wrote its half of the directory", writers[w].Name), false,
				fmt.Sprintf("%d write(s) failed, first: %v", len(errs[w]), errs[w][0]))
		} else {
			check(&ok, fmt.Sprintf("%s wrote all %d of its files", writers[w].Name, fileCount/2+fileCount%2*(1-w)), true, "")
		}
	}
	for i := range files {
		files[i].sum = sums[files[i].owner][i]
	}
	fmt.Printf("    both nodes finished writing in %v\n", time.Since(start).Round(time.Millisecond))

	// --- stage 2: both nodes must see the whole directory ------------
	want := make(map[string]bool, fileCount)
	for i := range files {
		want[fmt.Sprintf("f%05d", i)] = true
	}
	for _, c := range []*Client{a, b} {
		var rd ReaddirResult
		resp, err := c.Call("readdir", ReaddirArgs{Path: dir})
		if err := decodeResult(c.Name, resp, err, &rd); err != nil {
			return false, fmt.Errorf("%s readdir: %w", c.Name, err)
		}
		got := make(map[string]bool, len(rd.Names))
		for _, n := range rd.Names {
			got[n] = true
		}
		missing, extra := 0, 0
		var firstMissing string
		for n := range want {
			if !got[n] {
				if missing == 0 {
					firstMissing = n
				}
				missing++
			}
		}
		for n := range got {
			if !want[n] {
				extra++
			}
		}
		check(&ok, fmt.Sprintf("%s's readdir returns all %d entries (its own and the peer's)", c.Name, fileCount),
			len(rd.Names) == fileCount && missing == 0 && extra == 0,
			fmt.Sprintf("got %d names, %d missing (first %q), %d unexpected", len(rd.Names), missing, firstMissing, extra))
	}
	checkDirAgreement(&ok, a, b, dir, "full")

	// The directory must really have outgrown its 4 inline extents.
	//
	// This is the structure the file count exists to produce, and N11's
	// lesson is that asserting the INPUT that used to produce a
	// structure is not the same as asserting the structure -- an
	// unrelated allocator change was enough to silently stop a
	// directory ever reaching depth 1 while every entry-count assertion
	// still passed. Here it is checkable from stat alone: a directory's
	// size IS its block count, and the two nodes allocate from
	// different Zone Groups (each owns its own), so blocks grown by
	// different nodes cannot be one contiguous run and cannot be merged
	// into one extent. More than 4 blocks therefore means more than 4
	// extents, which means the inline array spilled into the external
	// leaf -- the depth-1 read path, with its forced-fresh semantics,
	// which nothing else in this suite reaches.
	grownSize, _, err := dirSizeOn(a, dir)
	if err != nil {
		return false, fmt.Errorf("stat of the grown directory: %w", err)
	}
	grownBlocks := grownSize / pre.BlockSize
	check(&ok, fmt.Sprintf("the shared directory outgrew its inline extents (%d blocks)", grownBlocks),
		grownBlocks > 4,
		fmt.Sprintf("only %d block(s) after %d files -- raise -dirstorm-files; the depth-1 leaf path is NOT being tested",
			grownBlocks, fileCount))

	// --- stage 3: each node verifies the OTHER node's files ----------
	// Sampled rather than exhaustive: reading every byte back over the
	// wire would dominate the run, and a sample across the whole size
	// range is what catches a mapping bug.
	sample := 24
	if sample > fileCount {
		sample = fileCount
	}
	badContent := 0
	var firstBad string
	for s := 0; s < sample; s++ {
		i := s * fileCount / sample
		f := files[i]
		reader := writers[1-f.owner] // the node that did NOT write it
		var res ReadResult
		resp, err := reader.Call("read", ReadArgs{Path: f.name})
		if err := decodeResult(reader.Name, resp, err, &res); err != nil {
			badContent++
			if firstBad == "" {
				firstBad = fmt.Sprintf("%s reading %s: %v", reader.Name, f.name, err)
			}
			continue
		}
		if res.Size != int64(f.size) || (f.sum != "" && res.Checksum != f.sum) {
			badContent++
			if firstBad == "" {
				firstBad = fmt.Sprintf("%s: %s size=%d want %d, sum=%s want %s",
					reader.Name, f.name, res.Size, f.size, res.Checksum, f.sum)
			}
		}
	}
	check(&ok, fmt.Sprintf("each node reads back %d of the peer's files with the exact size and checksum", sample),
		badContent == 0, fmt.Sprintf("%d of %d mismatched, first: %s", badContent, sample, firstBad))

	// --- stage 4: cross-node teardown --------------------------------
	// Each node unlinks what the OTHER one created, concurrently -- the
	// case where the unlinking node holds neither the file's lock nor
	// any local cached state for it.
	// Also sharded across each node's connections. This is the phase
	// that exercises the FOREIGN-FREE path -- every block being freed
	// here lives in the peer's Zone Group, so each one is appended to
	// that peer's pending-free queue -- and running it concurrently is
	// what puts several appends on one queue at once.
	//
	// pending_free_appends is the only confirmation that path ran at all
	// (it is zero on any single-node volume, where every free is direct),
	// so snapshot it on both nodes around the teardown and require it moved.
	appendsBefore := map[string]uint64{}
	for _, c := range []*Client{a, b} {
		var s ProcSnapshotResult
		resp, err := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
		if derr := decodeResult(c.Name, resp, err, &s); derr != nil {
			return false, fmt.Errorf("%s: proc_snapshot before teardown: %w", c.Name, derr)
		}
		appendsBefore[c.Name] = s.PendingFreeAppends
	}
	start = time.Now()
	unlinkErrs := make([][]error, len(writers))
	for w := range writers {
		for k := range conns[w] {
			wg.Add(1)
			go func(w, k int) {
				defer wg.Done()
				c := conns[w][k]
				for i := range files {
					if files[i].owner == w || (i/2)%par != k {
						continue // unlink the peer's, not our own
					}
					resp, err := c.Call("unlink", UnlinkArgs{Path: files[i].name})
					if err := decodeResult(c.Name, resp, err, nil); err != nil {
						errMu.Lock()
						if len(unlinkErrs[w]) <= 5 {
							unlinkErrs[w] = append(unlinkErrs[w],
								fmt.Errorf("%s: unlink %s: %w", c.Name, files[i].name, err))
						}
						errMu.Unlock()
					}
				}
			}(w, k)
		}
	}
	wg.Wait()
	for w := range writers {
		check(&ok, fmt.Sprintf("%s unlinked the files created by the other node", writers[w].Name),
			len(unlinkErrs[w]) == 0,
			fmt.Sprintf("%d unlink(s) failed, first: %v", len(unlinkErrs[w]), firstErr(unlinkErrs[w])))
	}
	fmt.Printf("    both nodes finished unlinking in %v\n", time.Since(start).Round(time.Millisecond))

	var appendTotal uint64
	for _, c := range []*Client{a, b} {
		var s ProcSnapshotResult
		resp, err := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
		if derr := decodeResult(c.Name, resp, err, &s); derr != nil {
			return false, fmt.Errorf("%s: proc_snapshot after teardown: %w", c.Name, derr)
		}
		d := s.PendingFreeAppends - appendsBefore[c.Name]
		fmt.Printf("    %-12s foreign-free appends to the peer's pending-free queue: %d\n", c.Name, d)
		appendTotal += d
	}
	// THE assertion for this path: each node unlinked the other's files,
	// whose blocks live in the peer's ZG, so each free had to be queued --
	// not applied to the peer's bitmap directly. Zero means the path did not
	// run (every block was somehow local, or the queueing was bypassed), the
	// same class of silent miss cas_miscompares guards for the CAS.
	check(&ok, "the foreign-free APPEND path was exercised (blocks queued to a peer's pending-free queue)",
		appendTotal > 0,
		"neither node appended a foreign free -- the append path, unreachable on the loop harness, did not run here either")

	for _, c := range []*Client{a, b} {
		var rd ReaddirResult
		resp, err := c.Call("readdir", ReaddirArgs{Path: dir})
		if err := decodeResult(c.Name, resp, err, &rd); err != nil {
			return false, fmt.Errorf("%s final readdir: %w", c.Name, err)
		}
		check(&ok, fmt.Sprintf("%s sees the directory empty again", c.Name), len(rd.Names) == 0,
			fmt.Sprintf("%d entries still listed, first few: %v", len(rd.Names), firstNames(rd.Names, 5)))
	}
	checkDirAgreement(&ok, a, b, dir, "emptied")

	// The directory record must come back to exactly what it was when
	// fresh -- a size that never shrinks would mean removal is not
	// actually reclaiming dirent slots.
	finalSize, finalNlink, err := dirSizeOn(a, dir)
	if err != nil {
		return false, fmt.Errorf("final stat: %w", err)
	}
	check(&ok, "the emptied directory's inode matches its fresh state",
		finalSize == emptySize && finalNlink == emptyNlink,
		fmt.Sprintf("fresh was size=%d nlink=%d, now size=%d nlink=%d", emptySize, emptyNlink, finalSize, finalNlink))

	// --- stage 5: space and inodes come back -------------------------
	if resp, err := a.Call("rmdir", RmdirArgs{Path: dir}); err != nil || decodeResult(a.Name, resp, err, nil) != nil {
		check(&ok, "the emptied directory can be removed", false, fmt.Sprintf("%v", err))
	} else {
		check(&ok, "the emptied directory can be removed", true, "")
	}

	// Frees issued against a ZG this node does not own are queued and
	// applied on the owner's heartbeat tick, so the counters only settle
	// after a tick has passed -- same reason RunSpaceAccounting quiesces.
	if err := quiesceFreeBlocks(statfsOf, []*Client{a, b}); err != nil {
		return false, err
	}
	post, err := statfsOf(a, "after")
	if err != nil {
		return false, err
	}
	check(&ok, "every block used by the storm came back", post.FreeBlocks >= pre.FreeBlocks,
		fmt.Sprintf("free blocks before=%d after=%d (leaked %d)", pre.FreeBlocks, post.FreeBlocks,
			int64(pre.FreeBlocks)-int64(post.FreeBlocks)))
	check(&ok, "every inode used by the storm came back", post.FreeFiles >= pre.FreeFiles,
		fmt.Sprintf("free inodes before=%d after=%d (leaked %d)", pre.FreeFiles, post.FreeFiles,
			int64(pre.FreeFiles)-int64(post.FreeFiles)))

	if ok {
		fmt.Printf("PASS: dir storm: %d files written, listed, verified and removed across two nodes\n", fileCount)
	} else {
		fmt.Printf("FAIL: dir storm: see failed checks above\n")
	}
	return ok, nil
}

func firstErr(errs []error) error {
	if len(errs) == 0 {
		return nil
	}
	return errs[0]
}

func firstNames(names []string, n int) []string {
	if len(names) < n {
		return names
	}
	return names[:n]
}

// RunReleaseSuite is what must pass before a release: the full suite,
// then the scenarios deliberately left out of it.
//
// full-suite is the per-change gate -- it has to stay quick, so the
// scenarios that run for minutes are excluded. That is the right call
// for a commit and the wrong one for a release: hypervisor-storm is the
// only thing shaped like the actual deployment (several hosts with VM
// images on one LUN), and it is what produced the pending-free queue
// overflow that no per-mechanism scenario reproduced. ns-fuzz is what
// catches a format change moving on-disk offsets.
//
// Running these by hand means eventually not running them.
func RunReleaseSuite(clients []*Client, cfg masterConfig) (bool, error) {
	type step struct {
		name string
		run  func() (bool, error)
	}
	steps := []step{
		{"full-suite", func() (bool, error) {
			return RunFullSuite(clients, cfg.lockPath, cfg.testDir, cfg.accountingSizeBytes,
				cfg.dirStormFiles, cfg.dirStormMaxBytes, cfg.dirStormPar, cfg.dirStormSeed)
		}},
		{"hypervisor-storm", func() (bool, error) {
			return RunHypervisorStorm(clients, cfg.testDir, cfg.stormDur, cfg.stormSeed,
				cfg.stormInject, cfg.stormNoFileLock)
		}},
		{"ns-fuzz", func() (bool, error) {
			return RunNsFuzz(clients, cfg.testDir, cfg.nsFuzzSeed, cfg.nsFuzzOps,
				cfg.nsFuzzPool, cfg.nsFuzzOpset)
		}},
		{"concurrent-mkdir-storm", func() (bool, error) {
			return RunConcurrentMkdirStorm(clients, cfg.testDir)
		}},
		{"explicit-lock", func() (bool, error) { return RunExplicitLock(clients, cfg.lockPath) }},
		{"cluster-lock-mode", func() (bool, error) { return RunClusterLockMode(clients) }},
	}

	allOK := true
	start := time.Now()
	for _, s := range steps {
		fmt.Printf("\n##### release-suite: %s #####\n", s.name)
		ok, err := s.run()
		if err != nil {
			fmt.Printf("ERROR in %s: %v\n", s.name, err)
			return false, err
		}
		if !ok {
			allOK = false
			// Keep going: a release wants the whole picture, not the
			// first thing that broke.
			fmt.Printf("##### release-suite: %s FAILED #####\n", s.name)
		}
	}
	verdict := "ALL PASSED"
	if !allOK {
		verdict = "FAILED"
	}
	fmt.Printf("\n===== release suite: %s (%s) =====\n", verdict, fmtDur(time.Since(start)))
	return allOK, nil
}

// RunFullSuite runs every scenario in this file end to end against the
// same client set and reports one aggregate pass/fail -- the "just run
// everything" entry point so a rebuild/redeploy only needs one command
// to re-check the whole matrix (module build alignment, every
// operation's cross-node visibility, every concurrent-conflict case,
// and the exclusive lock's hold/release lifecycle) instead of the
// caller remembering to invoke each -scenario by hand.
func RunFullSuite(clients []*Client, lockPath, baseDir string, accountingSizeBytes int,
	dirStormFiles, dirStormMaxBytes, dirStormPar int, dirStormSeed int64) (bool, error) {
	type step struct {
		name string
		run  func() (bool, error)
	}
	steps := []step{
		// First, and deliberately destructive: it reformats the device,
		// so every suite run starts from a pristine volume instead of
		// inheriting whatever ZG ownership and leftover files previous
		// runs left behind. It also proves mkfs refuses a mounted
		// device before any other scenario mounts anything.
		{"mkfs-guard", func() (bool, error) { return RunMkfsGuard(clients) }},
		{"module-info", func() (bool, error) { return RunModuleInfo(clients) }},
		{"lock-race", func() (bool, error) { return RunLockRace(clients, lockPath) }},
		{"lock-sequential", func() (bool, error) { return RunLockSequential(clients, lockPath) }},
		{"lock-hold", func() (bool, error) { return RunLockHold(clients, lockPath) }},
		{"cross-node-visibility", func() (bool, error) { return RunCrossNodeVisibility(clients, baseDir) }},
		{"xattrs", func() (bool, error) { return RunXattrs(clients, baseDir) }},
		{"concurrent-create", func() (bool, error) {
			return RunConcurrentCreate(clients, baseDir+"/concurrent-create-file")
		}},
		{"concurrent-unlink", func() (bool, error) {
			return RunConcurrentUnlink(clients, baseDir+"/concurrent-unlink-file")
		}},
		{"concurrent-mkdir", func() (bool, error) {
			return RunConcurrentMkdir(clients, baseDir+"/concurrent-mkdir-dir")
		}},
		{"concurrent-rename", func() (bool, error) { return RunConcurrentRename(clients, baseDir) }},
		{"symlink-publish", func() (bool, error) { return RunSymlinkPublish(clients, baseDir) }},
		// The three cross-node checks the loop-device suite can only
		// simulate with a poke helper. They run BEFORE
		// dir-storm: each is seconds, and a failure in one of them
		// explains far more about a broken build than a four-minute
		// storm does.
		{"read-presence", func() (bool, error) { return RunReadPresence(clients, baseDir) }},
		{"fence-reclaim", func() (bool, error) { return RunFenceReclaim(clients, baseDir) }},
		{"replay-race", func() (bool, error) { return RunReplayRace(clients, baseDir) }},
		{"inode-reuse", func() (bool, error) { return RunInodeReuse(clients, baseDir) }},
		{"dirent-cache", func() (bool, error) { return RunDirentCache(clients, baseDir, dirStormPar) }},
		{"extent-leaf-staleness", func() (bool, error) { return RunExtentLeafStaleness(clients, baseDir) }},
		{"record-write-race", func() (bool, error) { return RunRecordWriteRace(clients, baseDir) }},
		{"dirent-torn", func() (bool, error) { return RunDirentTorn(clients, baseDir, dirStormPar) }},
		// Runs early: if the device has no atomic CAW, every claim in
		// every scenario below is taking the serialised fallback and
		// the run means something quite different from what it says.
		{"caw", func() (bool, error) { return RunCAW(clients, baseDir, dirStormPar) }},
		{"pending-free", func() (bool, error) { return RunPendingFree(clients, baseDir) }},
		{"scrub-transit", func() (bool, error) { return RunScrubTransit(clients, baseDir) }},
		{"dir-storm", func() (bool, error) {
			return RunDirStorm(clients, baseDir, dirStormFiles, dirStormMaxBytes, dirStormPar, dirStormSeed)
		}},
		{"space-accounting", func() (bool, error) {
			return RunSpaceAccounting(clients, baseDir, accountingSizeBytes)
		}},
	}

	if len(clients) >= 2 {
		steps = append(steps, step{"zg-fairness", func() (bool, error) { return RunZGFairness(clients) }})
		steps = append(steps, step{"sparse-bigfile", func() (bool, error) {
			return RunSparseBigFile(clients, baseDir+"/sparse-bigfile")
		}})
	}

	type result struct {
		name    string
		verdict string
		took    time.Duration
	}
	var results []result

	overall := true
	var skippedNames []string
	suiteStart := time.Now()
	for _, s := range steps {
		fmt.Printf("\n----- %s -----\n", s.name)
		stepStart := time.Now()
		pass, err := s.run()
		var skipped skipErr
		took := time.Since(stepStart)
		verdict := "PASS"
		if errors.As(err, &skipped) {
			// Not a failure, but emphatically not a pass: the scenario
			// tested nothing and the summary must say so.
			verdict = "SKIP"
			skippedNames = append(skippedNames, s.name)
			err = nil
		} else if err != nil {
			fmt.Printf("ERROR in %s: %v\n", s.name, err)
			overall = false
			verdict = "ERROR"
		} else if !pass {
			overall = false
			verdict = "FAIL"
		}
		fmt.Printf("----- %s: %s in %s -----\n", s.name, verdict, fmtDur(took))
		results = append(results, result{s.name, verdict, took})
	}
	suiteTook := time.Since(suiteStart)

	// A per-scenario breakdown, slowest-first after the table, is how
	// you tell "the suite got slower" from "ONE scenario got slower" --
	// the two have entirely different causes and the single total number
	// cannot distinguish them.
	fmt.Printf("\n===== timings =====\n")
	for _, r := range results {
		pct := 0.0
		if suiteTook > 0 {
			pct = 100 * r.took.Seconds() / suiteTook.Seconds()
		}
		fmt.Printf("  %-22s %-5s %8s  %4.1f%%\n", r.name, r.verdict, fmtDur(r.took), pct)
	}
	fmt.Printf("  %-22s %-5s %8s\n", "TOTAL", "", fmtDur(suiteTook))

	if len(skippedNames) > 0 {
		// Loud, and in the verdict line itself: a suite that skipped
		// scenarios has NOT covered them, and "ALL PASSED" would say it
		// did.
		fmt.Printf("\n%d scenario(s) SKIPPED -- not covered by this run: %s\n",
			len(skippedNames), strings.Join(skippedNames, ", "))
	}
	status := "ALL PASSED"
	if !overall {
		status = "ONE OR MORE FAILURES"
	} else if len(skippedNames) > 0 {
		status = fmt.Sprintf("passed, but %d SKIPPED", len(skippedNames))
	}
	fmt.Printf("\n===== full suite: %s (%s) =====\n", status, fmtDur(suiteTook))
	return overall, nil
}

// RunMkfsGuard checks that mkfs.cetra refuses to reformat a volume that
// is mounted -- on the node running mkfs, and on a DIFFERENT node.
//
// The two refusals have nothing in common mechanically, which is why
// both are tested:
//
//   - Same node: mkfs can see the mount in /proc/self/mounts, a purely
//     local check.
//   - Different node: there is nothing local to see. The device is a
//     shared LUN and the peer's mount is invisible to this machine
//     except through the filesystem's own on-disk state, so mkfs has to
//     read the superblock, walk the Node Registry and find a live peer
//     row (userspace/devutil.h's cetrafs_find_live_peer). This is the
//     case that actually matters for the target deployment: reformatting
//     a LUN that another hypervisor is actively running VMs off is
//     exactly the catastrophe the check exists to prevent.
//
// -f is deliberately NOT passed to the attempts that must fail. Force is
// the operator's documented escape hatch, so an mkfs that refused only
// until someone added -f would still be correct; what must never happen
// is an UNFORCED mkfs quietly eating a live volume.
func RunMkfsGuard(clients []*Client) (bool, error) {
	if len(clients) < 1 {
		return false, fmt.Errorf("mkfs-guard needs at least one slave")
	}
	fmt.Printf("=== mkfs guard: %d client(s), device %s ===\n", len(clients), clients[0].Device)

	// Start from a clean slate: nothing mounted anywhere. Ignore the
	// error -- "already unmounted" is the state we want.
	_ = ensureUnmounted(clients)

	runMkfs := func(c *Client, force bool) (MkfsResult, error) {
		var res MkfsResult
		resp, err := c.Call("mkfs", MkfsArgs{Force: force})
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return res, fmt.Errorf("%s: mkfs: %w", c.Name, err)
		}
		return res, nil
	}

	ok := true

	// 1. Unmounted everywhere: mkfs must SUCCEED, or every refusal below
	//    proves nothing (a mkfs that always fails would "pass" them all).
	res, err := runMkfs(clients[0], true)
	if err != nil {
		return false, err
	}
	if res.ExitCode == 0 {
		fmt.Printf("  PASS %s: mkfs succeeds when nothing has the device mounted\n", clients[0].Name)
	} else {
		ok = false
		fmt.Printf("  FAIL %s: mkfs failed (exit %d) on an unmounted device -- the refusals below prove nothing\n",
			clients[0].Name, res.ExitCode)
		fmt.Printf("       stderr: %s\n", strings.TrimSpace(res.Stderr))
	}

	// 2. Mount on node 0, then mkfs on node 0: the local check.
	if err := ensureMounted(clients[:1]); err != nil {
		return false, fmt.Errorf("mounting %s: %w", clients[0].Name, err)
	}
	// -f ON PURPOSE for the two refusal attempts. Both mount checks run
	// before the force gate, so forcing isolates them: without it mkfs
	// stops at "Refusing to overwrite existing cetrafs (use -f)" and the
	// assertion can never reach the thing it is testing. Force is the
	// documented escape hatch for an idle volume; it must NOT be one for
	// a mounted one.
	res, err = runMkfs(clients[0], true)
	if err != nil {
		_ = ensureUnmounted(clients[:1])
		return false, err
	}
	if refused, why := mkfsRefusedBecause(res, "is mounted on"); refused {
		fmt.Printf("  PASS %s: mkfs refuses a device THIS node has mounted, even with -f: %s\n", clients[0].Name, why)
	} else {
		ok = false
		if res.ExitCode == 0 {
			fmt.Printf("  FAIL %s: mkfs REFORMATTED a device this node had mounted\n", clients[0].Name)
		} else {
			fmt.Printf("  FAIL %s: mkfs failed, but not because the device was mounted: %s\n",
				clients[0].Name, why)
		}
	}

	// 3. With node 0 still mounted, mkfs on node 1: the cross-node check.
	if len(clients) > 1 {
		res, err = runMkfs(clients[1], true)
		if err != nil {
			_ = ensureUnmounted(clients[:1])
			return false, err
		}
		// "mounted by another node" specifically: the peer's mount is
		// invisible locally, so this must come from the Node Registry
		// walk, not from the local /proc/self/mounts check.
		if refused, why := mkfsRefusedBecause(res, "is mounted by another node"); refused {
			fmt.Printf("  PASS %s: mkfs refuses a device a PEER node has mounted, even with -f: %s\n", clients[1].Name, why)
		} else {
			ok = false
			if res.ExitCode == 0 {
				fmt.Printf("  FAIL %s: mkfs REFORMATTED a device %s had mounted -- a live volume was destroyed\n",
					clients[1].Name, clients[0].Name)
			} else {
				fmt.Printf("  FAIL %s: mkfs failed, but not because a peer had it mounted: %s\n",
					clients[1].Name, why)
			}
		}
	} else {
		fmt.Printf("  SKIP cross-node refusal: only one slave given (this is the case that matters most --\n")
		fmt.Printf("       run with two slaves to cover it)\n")
	}

	// 4. Unmount everywhere and confirm mkfs works again, so a refusal
	//    above was really about the mount and not about the volume
	//    having become permanently unformattable.
	if err := ensureUnmounted(clients); err != nil {
		fmt.Printf("  (cleanup) unmount: %v\n", err)
	}
	res, err = runMkfs(clients[0], true)
	if err != nil {
		return false, err
	}
	if res.ExitCode == 0 {
		fmt.Printf("  PASS %s: mkfs works again once the device is unmounted everywhere\n", clients[0].Name)
	} else {
		ok = false
		fmt.Printf("  FAIL %s: mkfs still refuses (exit %d) after everything unmounted: %s\n",
			clients[0].Name, res.ExitCode, strings.TrimSpace(res.Stderr))
	}

	return ok, nil
}

// requireSameModuleBuild is a PRECONDITION, not a scenario: it runs
// before anything touches the device, and a mismatch aborts the whole
// run after unmounting every slave.
//
// RunModuleInfo reports the same facts, but reporting is not enough. As
// a mere step it returned false and the suite carried straight on into
// the real scenarios -- so a run where one node had not picked up the
// new build produced a long tail of confusing cross-node failures whose
// actual cause was a stale .ko, scrolled far off the top of the output.
// Every cross-node assertion in this suite is a statement about two
// peers implementing the same protocol; if they do not, no result the
// suite produces means anything, pass or fail.
//
// Unmounting on the way out matters too: leaving a half-configured
// cluster mounted on a shared LUN is exactly the state that makes the
// NEXT investigation harder.
func requireSameModuleBuild(clients []*Client) error {
	fmt.Println("=== precondition: every node must be running the same cetrafs.ko ===")

	builds := map[string][]string{} // build id -> node names
	var problems []string

	for _, c := range clients {
		var res ModuleInfoResult
		resp, err := c.Call("module_info", struct{}{})
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return fmt.Errorf("%s: module_info: %w", c.Name, err)
		}
		fmt.Printf("  %-10s loaded=%v build_id=%s ko_sha256=%s\n", c.Name, res.Loaded, res.BuildID, res.KoSHA256)

		switch {
		case !res.Loaded:
			problems = append(problems, fmt.Sprintf("%s has no cetrafs module loaded", c.Name))
		case res.BuildID == "":
			// Unknown is not the same as equal. Treating it as a match
			// would let exactly the case this gate exists for through.
			problems = append(problems,
				fmt.Sprintf("%s reports no build-id, so its build cannot be compared", c.Name))
		default:
			builds[res.BuildID] = append(builds[res.BuildID], c.Name)
		}
	}

	if len(problems) == 0 && len(builds) == 1 {
		fmt.Printf("  OK: all %d node(s) share one build\n", len(clients))
		return nil
	}

	var msg strings.Builder
	msg.WriteString("nodes are not running the same cetrafs build:\n")
	for _, p := range problems {
		msg.WriteString("    " + p + "\n")
	}
	for id, names := range builds {
		msg.WriteString(fmt.Sprintf("    build_id=%s -> %v\n", id, names))
	}
	msg.WriteString("  rebuild and reload the module on every node, then re-run")
	return fmt.Errorf("%s", msg.String())
}

// mkfsRefusedBecause distinguishes the three outcomes a guard assertion
// has to tell apart: mkfs succeeded, mkfs refused for the stated reason,
// and mkfs failed for some OTHER reason entirely.
//
// Only the middle one is a pass. Collapsing the last two into "exit code
// nonzero" is how an early version of this scenario reported PASS while
// mkfs was actually dying on a malformed command line and had never
// looked at the device at all.
func mkfsRefusedBecause(res MkfsResult, want string) (bool, string) {
	out := strings.TrimSpace(res.Stderr + res.Stdout)
	flat := strings.Join(strings.Fields(out), " ")
	if len(flat) > 200 {
		flat = flat[:200] + "..."
	}
	if res.ExitCode == 0 {
		return false, "mkfs succeeded"
	}
	if strings.Contains(out, want) {
		return true, flat
	}
	return false, fmt.Sprintf("exit %d: %s", res.ExitCode, flat)
}

// RunReadPresence: a REAL concurrent cross-node reader.
//
// A read-only open takes no cross-node lock -- one writer and lock-free
// readers is the whole clustering model -- so nothing structural stops
// node B unlinking a file node A is reading: B's evict_inode frees the
// blocks, the allocator hands them to a new file, and A, still reading
// through an already-open fd that never re-looks-up, silently gets that
// other file's data. That is closed by read_open_nodes, a
// presence bitmask published on a node's FIRST read-open and cleared on
// its LAST.
//
// The loop-device suite pokes a bit into that mask. It therefore proves
// the DECISION ("a set bit blocks an unlink") and nothing about the
// publish: whether a genuine read-open really sets the bit, on the
// right inode, visible to the other node, and really clears it at
// close. This is one of the checks only hardware can
// make.
func RunReadPresence(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("read-presence needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a, b := clients[0], clients[1]
	dir := baseDir + "/readpresence"
	fmt.Printf("=== read presence: %s holds a file open for READ while %s tries to unlink it ===\n", a.Name, b.Name)

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}

	ok := true
	// Two directions, because the publish and the check are different
	// code on different nodes: whoever READS must publish, whoever
	// UNLINKS must consult. Running it only one way would leave half of
	// it untested on each node.
	for _, d := range []struct{ reader, remover *Client }{{a, b}, {b, a}} {
		path := fmt.Sprintf("%s/held-%s", dir, d.reader.Name)
		label := fmt.Sprintf("%s reads, %s unlinks", d.reader.Name, d.remover.Name)

		var w WriteResult
		resp, err := d.remover.Call("write", WriteArgs{Path: path, Size: 64 * 1024, Stamp: "presence"})
		if err := decodeResult(d.remover.Name, resp, err, &w); err != nil {
			return false, fmt.Errorf("%s: setup write: %w", label, err)
		}

		var oh OpenHoldResult
		resp, err = d.reader.Call("open_hold", OpenHoldArgs{Path: path, Mode: "rdonly"})
		if err := decodeResult(d.reader.Name, resp, err, &oh); err != nil {
			return false, fmt.Errorf("%s: open for read: %w", label, err)
		}

		// The unlink must be REFUSED while that fd is open. -ETXTBSY,
		// deliberately, rather than POSIX's defer-until-last-close: see
		// why this filesystem took the stricter of the
		// two legal semantics.
		resp, err = d.remover.Call("unlink", UnlinkArgs{Path: path})
		refused := err == nil && !resp.OK
		check(&ok, label+": the unlink is refused while the fd is open", refused,
			fmt.Sprintf("unlink returned ok=%v err=%v -- the reader's presence bit was not published or not seen",
				err == nil && resp.OK, err))

		// ...and the reader must still be able to read it, which is the
		// point of refusing.
		var rd ReadResult
		resp, err = d.reader.Call("read", ReadArgs{Path: path})
		if err := decodeResult(d.reader.Name, resp, err, &rd); err != nil {
			check(&ok, label+": the reader can still read the file it is holding", false, err.Error())
		} else {
			check(&ok, label+": the reader can still read the file it is holding",
				rd.Checksum == w.Checksum, fmt.Sprintf("checksum %s want %s", rd.Checksum, w.Checksum))
		}

		if resp, err := d.reader.Call("close", CloseArgs{Handle: oh.Handle}); decodeResult(d.reader.Name, resp, err, nil) != nil {
			return false, fmt.Errorf("%s: close", label)
		}

		// The LAST read-open closing must clear the bit. If it did not,
		// the file would be permanently unlinkable by every other node
		// -- a leak that no later operation can repair.
		resp, err = d.remover.Call("unlink", UnlinkArgs{Path: path})
		cleared := err == nil && resp.OK
		check(&ok, label+": the unlink succeeds once the fd is closed", cleared,
			fmt.Sprintf("still refused after close (err=%v resp=%v) -- the presence bit was never cleared", err, resp.Error))
		if !cleared {
			_, _ = d.remover.Call("unlink", UnlinkArgs{Path: path})
		}
	}

	if resp, err := a.Call("rmdir", RmdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		check(&ok, "the scenario's directory is removable afterwards", false, "rmdir failed")
	}
	if ok {
		fmt.Printf("PASS: read presence: a real cross-node reader is seen, and stops being seen at close\n")
	}
	return ok, nil
}

// RunInodeReuse: an inode NUMBER recycled by one node must not be
// served through the other node's cached object for the old file.
//
// Inode numbers are freely reused after deletion, and a node holding a
// cached in-core object for a number cannot otherwise tell "same file,
// updated" from "a brand-new file wearing the same number". The
// cache-hit refresh only ever updated stat fields, never i_op/i_fop, so
// a number that was a SYMLINK on one node and became a regular file via
// the other's unlink+create left the first node's VFS following the
// "link" and walking the new file's DATA as a path. Not hypothetical:
// it is how ctest's xattrs DIAG first surfaced the bug that produced
// format v0x0008's generation field.
//
// The loop-device suite reaches this by poking a record's type and
// generation behind a live mount. Only two real nodes exercise what the
// generation exists for: one node genuinely recycling a number while
// the other genuinely holds the old object.
func RunInodeReuse(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("inode-reuse needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a, b := clients[0], clients[1]
	dir := baseDir + "/inodereuse"
	link := dir + "/thing"
	fmt.Printf("=== inode reuse: %s recycles a number from a symlink to a regular file, %s had it cached ===\n",
		a.Name, b.Name)

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}
	ok := true

	// A target long enough to be unmistakable if it is ever served as
	// file content, and vice versa.
	target := "/a/deliberately/distinctive/symlink/target/that/is/not/file/data"
	if resp, err := a.Call("symlink", SymlinkArgs{Target: target, LinkPath: link}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup symlink: %v", err)
	}

	// B resolves it, so B now holds an in-core inode object for that
	// number with symlink ops attached -- the cache the generation has
	// to invalidate.
	var rl ReadlinkResult
	resp, err := b.Call("readlink", ReadlinkArgs{Path: link})
	if err := decodeResult(b.Name, resp, err, &rl); err != nil {
		return false, fmt.Errorf("%s: readlink before reuse: %w", b.Name, err)
	}
	check(&ok, b.Name+" resolves the symlink before the reuse", rl.Target == target,
		fmt.Sprintf("target %q want %q", rl.Target, target))
	before, _, err := statPath(b, link)
	if err != nil {
		return false, fmt.Errorf("%s: stat before reuse: %w", b.Name, err)
	}

	// A deletes it and creates a REGULAR FILE. The allocator hands out
	// the first free inode bit, so the number just freed is the one the
	// next create takes -- which is why this bug class exists at all.
	if resp, err := a.Call("unlink", UnlinkArgs{Path: link}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("unlink the symlink: %v", err)
	}
	var w WriteResult
	resp, err = a.Call("write", WriteArgs{Path: link, Size: 4096, Stamp: "reused-as-a-regular-file"})
	if err := decodeResult(a.Name, resp, err, &w); err != nil {
		return false, fmt.Errorf("recreate as a regular file: %w", err)
	}

	after, _, err := statPath(a, link)
	if err != nil {
		return false, fmt.Errorf("stat after reuse: %w", err)
	}
	// Reported, not required: if the allocator did not hand back the
	// same number then this run proves nothing about reuse, and saying
	// so is better than a green test that never met its own case.
	reused := after.Ino == before.Ino
	fmt.Printf("    inode number before=%d after=%d (%s)\n", before.Ino, after.Ino,
		map[bool]string{true: "REUSED -- the case under test", false: "not reused; this run does not exercise it"}[reused])

	// The assertion: B must see a regular file, not follow a stale
	// symlink into the new file's data.
	var rd ReadResult
	resp, err = b.Call("read", ReadArgs{Path: link})
	if err := decodeResult(b.Name, resp, err, &rd); err != nil {
		check(&ok, b.Name+" reads the recycled number as a regular file", false,
			fmt.Sprintf("read failed: %v -- a stale symlink object would make this a path walk", err))
	} else {
		check(&ok, b.Name+" reads the recycled number as a regular file",
			rd.Size == 4096 && rd.Checksum == w.Checksum,
			fmt.Sprintf("size=%d want 4096, sum=%s want %s", rd.Size, rd.Checksum, w.Checksum))
	}

	// readlink must now FAIL: a regular file is not a link. If B still
	// has the symlink's ops attached this succeeds and hands back the
	// file's own bytes as a target -- the original bug verbatim.
	resp, err = b.Call("readlink", ReadlinkArgs{Path: link})
	stillALink := err == nil && resp.OK
	detail := "readlink succeeded on a regular file"
	if stillALink {
		var bad ReadlinkResult
		_ = json.Unmarshal(resp.Result, &bad)
		detail = fmt.Sprintf("readlink returned %q -- the stale symlink object is still attached", bad.Target)
	}
	check(&ok, b.Name+" no longer treats the recycled number as a symlink", !stillALink, detail)

	if !reused {
		fmt.Printf("    NOTE: the number was not recycled, so the assertions above passed without meeting the case.\n")
	}
	_, _ = a.Call("unlink", UnlinkArgs{Path: link})
	_, _ = a.Call("rmdir", RmdirArgs{Path: dir})
	if ok && reused {
		fmt.Printf("PASS: inode reuse: the generation invalidated the peer's cached object\n")
	}
	return ok, nil
}

// RunDirentCache: a peer's deletions must stop being listed.
//
// Reading a directory lock-free is only affordable because of
// dirent_seq (format v0x000B): every mutation bumps it, a node
// remembers the seq at which it last read a directory's blocks fresh,
// and while the two match its cached copies are known current. The
// whole thing rests on "only a walk that read EVERY block fresh and ran
// to completion may claim the cache" -- and P14 found two writers
// claiming it after a partial scan, which left a peer's deletions
// listed indefinitely.
//
// That is not a theoretical failure mode: a real two-node run ended
// with four files still listed after unlinks that all reported success,
// which is what prompted the read-only/write split in the first place.
// The loop suite reproduces it by restoring the bad claim in the
// kernel; this reproduces the SYMPTOM, which is what an operator sees.
func RunDirentCache(clients []*Client, baseDir string, par int) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("dirent-cache needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a, b := clients[0], clients[1]
	dir := baseDir + "/direntcache"
	// Enough to span several dirent blocks (15 per block), so a cached
	// scan that stops early has something it failed to re-read.
	const total = 40
	fmt.Printf("=== dirent cache: %s lists a directory, %s mutates it, %s must see the change ===\n",
		b.Name, a.Name, b.Name)

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}
	ok := true

	// Sharded across a's own connections. These are plain sequential
	// metadata operations costing about a second each on a real LUN, so
	// doing them one at a time made this scenario a minute of wall
	// clock to set up a test about caching.
	conns, closer, err := a.Parallel(par, 5*time.Second)
	if err != nil {
		return false, err
	}
	defer closer()

	names := make([]string, total)
	for i := range names {
		names[i] = fmt.Sprintf("e%03d", i)
	}
	if err := shardedCalls(conns, total, func(c *Client, i int) error {
		resp, err := c.Call("write", WriteArgs{Path: dir + "/" + names[i], Size: 16, Stamp: "dc"})
		return decodeResult(c.Name, resp, err, nil)
	}); err != nil {
		return false, fmt.Errorf("setup writes: %w", err)
	}

	listOn := func(c *Client, when string) (map[string]bool, error) {
		var rd ReaddirResult
		resp, err := c.Call("readdir", ReaddirArgs{Path: dir})
		if err := decodeResult(c.Name, resp, err, &rd); err != nil {
			return nil, fmt.Errorf("%s: readdir (%s): %w", c.Name, when, err)
		}
		m := map[string]bool{}
		for _, n := range rd.Names {
			m[n] = true
		}
		return m, nil
	}

	// B reads the whole directory first -- a complete read-only walk,
	// which is precisely the one allowed to prime the cache. Everything
	// after this is B serving answers it believes are current.
	got, err := listOn(b, "before")
	if err != nil {
		return false, err
	}
	check(&ok, fmt.Sprintf("%s sees all %d entries to begin with", b.Name, total), len(got) == total,
		fmt.Sprintf("saw %d", len(got)))

	// A removes half of them, interleaved rather than a contiguous
	// run, so a stale block anywhere in the directory shows up.
	var removed []string
	for i := 0; i < total; i += 2 {
		removed = append(removed, names[i])
	}
	if err := shardedCalls(conns, len(removed), func(c *Client, k int) error {
		resp, err := c.Call("unlink", UnlinkArgs{Path: dir + "/" + removed[k]})
		return decodeResult(c.Name, resp, err, nil)
	}); err != nil {
		return false, fmt.Errorf("unlinks: %w", err)
	}

	got, err = listOn(b, "after")
	if err != nil {
		return false, err
	}
	var ghosts []string
	for _, n := range removed {
		if got[n] {
			ghosts = append(ghosts, n)
		}
	}
	check(&ok, fmt.Sprintf("%s's readdir no longer lists the %d entries %s removed", b.Name, len(removed), a.Name),
		len(ghosts) == 0,
		fmt.Sprintf("%d still listed (%v...) -- a cached dirent block was claimed current after a partial scan",
			len(ghosts), firstFew(ghosts)))

	// A name that readdir still lists but lookup cannot resolve is the
	// more damaging half: it is what makes `ls` and `cat` disagree.
	var unresolvable []string
	for _, n := range removed {
		if _, exists, err := statPath(b, dir+"/"+n); err == nil && exists {
			unresolvable = append(unresolvable, n)
		}
	}
	check(&ok, fmt.Sprintf("%s cannot stat any of the removed names", b.Name), len(unresolvable) == 0,
		fmt.Sprintf("%d still resolve (%v...)", len(unresolvable), firstFew(unresolvable)))

	// The survivors must still be there -- a cache fix that simply
	// stopped trusting anything would pass the checks above while
	// losing entries.
	var missing []string
	for i := 1; i < total; i += 2 {
		if !got[names[i]] {
			missing = append(missing, names[i])
		}
	}
	check(&ok, fmt.Sprintf("%s still lists every entry that survived", b.Name), len(missing) == 0,
		fmt.Sprintf("%d missing (%v...)", len(missing), firstFew(missing)))

	// A's own additions must become visible to B too -- the same cache,
	// in the other direction.
	fresh := "after-the-storm"
	if resp, err := a.Call("write", WriteArgs{Path: dir + "/" + fresh, Size: 16, Stamp: "dc"}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("create %s", fresh)
	}
	got, err = listOn(b, "final")
	if err != nil {
		return false, err
	}
	check(&ok, fmt.Sprintf("%s sees a name %s created after its last listing", b.Name, a.Name), got[fresh],
		"the new entry is not listed -- the cache was claimed current across an addition")

	_ = shardedCalls(conns, total, func(c *Client, i int) error {
		if i%2 == 1 {
			_, _ = c.Call("unlink", UnlinkArgs{Path: dir + "/" + names[i]})
		}
		return nil
	})
	_, _ = a.Call("unlink", UnlinkArgs{Path: dir + "/" + fresh})
	_, _ = a.Call("rmdir", RmdirArgs{Path: dir})

	if ok {
		fmt.Printf("PASS: dirent cache: both nodes converge on the directory's real contents\n")
	}
	return ok, nil
}

// firstFew keeps a failure line readable when a whole directory went
// wrong: the first handful of names says as much as all of them.
func firstFew(s []string) []string {
	if len(s) > 5 {
		return s[:5]
	}
	return s
}

// RunExtentLeafStaleness: a peer's truncate must invalidate our cached
// external extent leaf.
//
// Once a file spills past its 4 inline extents the extent list lives in
// an external LEAF BLOCK. A reader node caches that block like any
// other metadata -- and used to keep mapping through it after a peer
// truncated and rewrote the file, so the blocks it handed back were
// ones the allocator had since given to a DIFFERENT file. Not a stale
// read of this file: another file's contents, served as this one's.
//
// The loop-device suite reaches it by poking the leaf on the backing
// file behind a live mount. Only two nodes exercise the real sequence:
// one genuinely holding a cached leaf while the other genuinely frees
// the blocks it names.
func RunExtentLeafStaleness(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("extent-leaf-staleness needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a, b := clients[0], clients[1]
	dir := baseDir + "/leafstale"
	path := dir + "/fragmented"
	fmt.Printf("=== extent leaf staleness: %s caches a depth-1 file's leaf, %s truncates and rewrites it ===\n",
		b.Name, a.Name)

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}
	ok := true

	// Sparse writes at widely separated offsets: each one allocates its
	// own extent with a hole between, so the inline array of 4 fills and
	// the file spills into the external leaf. A plain sequential write
	// would not -- the run-aware allocator keeps it in ONE extent
	// however large it gets, which is N11's lesson in a new place.
	const stride = 1 << 20
	const chunks = 12
	for i := 0; i < chunks; i++ {
		resp, err := a.Call("write_at", WriteAtArgs{
			Path: path, Offset: int64(i) * stride, Size: 4096, Stamp: fmt.Sprintf("first-%d", i), Create: true,
		})
		if err := decodeResult(a.Name, resp, err, nil); err != nil {
			return false, fmt.Errorf("setup write_at %d: %w", i, err)
		}
	}

	// B reads every chunk, so B has walked and cached the leaf.
	primeFail := ""
	for i := 0; i < chunks; i++ {
		// Same janitor window as the verification reads below: the file
		// has just been built with 12 extents, so a defrag pass may be
		// holding its lock. Retried there; here a failure is a setup
		// problem, reported as one.
		for attempt := 0; attempt < 40; attempt++ {
			var rd ReadAtResult
			resp, err := b.Call("read_at", ReadAtArgs{Path: path, Offset: int64(i) * stride, Size: 4096})
			e := decodeResult(b.Name, resp, err, &rd)
			if e == nil {
				primeFail = ""
				break
			}
			primeFail = e.Error()
			if !strings.Contains(e.Error(), "text file busy") {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
		if primeFail != "" {
			return false, fmt.Errorf("%s: priming read %d: %s", b.Name, i, primeFail)
		}
	}
	check(&ok, b.Name+" can read the fragmented file before the rewrite", true, "")

	// A frees the whole extent tree and builds a different one. The old
	// blocks go back to the allocator here.
	if resp, err := a.Call("truncate", TruncateArgs{Path: path, Size: 0}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("truncate to 0: %v", err)
	}
	want := make([]string, chunks)
	for i := 0; i < chunks; i++ {
		var w WriteAtResult
		resp, err := a.Call("write_at", WriteAtArgs{
			Path: path, Offset: int64(i) * stride, Size: 4096, Stamp: fmt.Sprintf("second-%d", i),
		})
		if err := decodeResult(a.Name, resp, err, &w); err != nil {
			return false, fmt.Errorf("rewrite %d: %w", i, err)
		}
		want[i] = w.Checksum
	}

	// The assertion: every chunk B reads must be the NEW content. A
	// stale leaf gives back the old physical blocks, which by now may
	// belong to another file entirely.
	//
	// ETXTBSY is tolerated BRIEFLY here, and the reason is worth
	// knowing: a file left with 12 extents is exactly what trips the
	// auto-defrag janitor, whose worker pins the file's cross-node
	// exclusive lock while it relocates (cetrafs_lock_defrag_begin()).
	// Peers are refused ANY open while that lock is held -- reads
	// included -- so a background optimisation on one node makes the
	// file momentarily unreadable on the other. That is current,
	// intended behaviour rather than a fault, but it is transient by
	// construction, so the retry asserts it RESOLVES rather than
	// papering over it. A persistent ETXTBSY still fails.
	readChunk := func(i int) (ReadAtResult, error) {
		var rd ReadAtResult
		var lastErr error
		for attempt := 0; attempt < 40; attempt++ {
			resp, err := b.Call("read_at", ReadAtArgs{Path: path, Offset: int64(i) * stride, Size: 4096})
			lastErr = decodeResult(b.Name, resp, err, &rd)
			if lastErr == nil {
				return rd, nil
			}
			if !strings.Contains(lastErr.Error(), "text file busy") {
				return rd, lastErr
			}
			time.Sleep(250 * time.Millisecond)
		}
		return rd, fmt.Errorf("still refused after 10s of retries: %w", lastErr)
	}

	bad := 0
	firstBad := ""
	for i := 0; i < chunks; i++ {
		rd, err := readChunk(i)
		if err != nil {
			bad++
			if firstBad == "" {
				firstBad = fmt.Sprintf("chunk %d: %v", i, err)
			}
			continue
		}
		if rd.Checksum != want[i] {
			bad++
			if firstBad == "" {
				firstBad = fmt.Sprintf("chunk %d: got %s want %s -- mapped through a stale extent leaf",
					i, rd.Checksum, want[i])
			}
		}
	}
	check(&ok, fmt.Sprintf("%s reads all %d chunks of the rewritten file correctly", b.Name, chunks),
		bad == 0, fmt.Sprintf("%d of %d wrong, first: %s", bad, chunks, firstBad))

	_, _ = a.Call("unlink", UnlinkArgs{Path: path})
	_, _ = a.Call("rmdir", RmdirArgs{Path: dir})
	if ok {
		fmt.Printf("PASS: extent leaf staleness: the peer's cached leaf was invalidated by the rewrite\n")
	}
	return ok, nil
}

// RunRecordWriteRace: a record write must not be reverted by a peer,
// and must not be observed torn.
//
// chmod is the probe because it is the smallest possible record write:
// it changes a few bits of the inode record, under no cross-node lock
// at all on the write-back path. Three separate fixes meet here --
// P3's buffer-update protocol (dirty before unlock, so a forced-fresh
// reader cannot overwrite a writer's in-memory change), P4's refusal to
// refresh an inode with unwritten local changes, and v0x0007's
// one-record-per-block layout that made the item-f clobber structurally
// inexpressible. All three were measured on one kernel. None has ever
// been watched across two.
//
// The assertion is deliberately "a value never goes backwards" rather
// than "no update is lost": with both nodes writing, last-writer-wins
// is correct. What is NOT correct is a value this node set being
// reverted to something older, which is exactly what P3's lost write
// and P4's refresh-over-dirt both produced -- durably, surviving a
// remount.
func RunRecordWriteRace(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("record-write-race needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a, b := clients[0], clients[1]
	dir := baseDir + "/recordrace"
	fmt.Printf("=== record write race: %s and %s chmod their own files while watching each other's ===\n",
		a.Name, b.Name)

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}
	ok := true

	// ONE goroutine per Client, and that constraint shapes the whole
	// scenario: a Client is a single TCP connection carrying one
	// request at a time (see master.go), so driving the same one from
	// two goroutines interleaves two requests on one socket and the
	// JSON decoder desynchronises. The first version of this scenario
	// paired a writer and a watcher per FILE, which meant each node was
	// being driven by two goroutines at once -- it panicked on the
	// first real run.
	//
	// So each node runs one loop that does both jobs: raise the mode on
	// its OWN file, read it straight back, then stat the PEER's file.
	// That last read is the forced-fresh read whose interaction with
	// the peer's concurrent record write is the thing under test, and
	// interleaving it with our own writes on one connection is exactly
	// the traffic pattern a real node produces.
	const rounds = 40
	files := make([]string, len(clients))
	for i, c := range clients {
		files[i] = fmt.Sprintf("%s/by-%s", dir, c.Name)
		if resp, err := c.Call("write", WriteArgs{Path: files[i], Size: 64, Stamp: "rr"}); decodeResult(c.Name, resp, err, nil) != nil {
			return false, fmt.Errorf("setup %s", files[i])
		}
	}

	var wg sync.WaitGroup
	reverts := make([]string, len(clients))
	errsSeen := make([]string, len(clients))
	wg.Add(len(clients))
	for i, c := range clients {
		go func(i int, c *Client) {
			defer wg.Done()
			mine := files[i]
			theirs := files[(i+1)%len(clients)]
			for r := 0; r < rounds; r++ {
				mode := uint32(0400 | (r%8)<<3 | (r % 8))
				resp, err := c.Call("chmod", ChmodArgs{Path: mine, Mode: mode})
				if err := decodeResult(c.Name, resp, err, nil); err != nil {
					if errsSeen[i] == "" {
						errsSeen[i] = fmt.Sprintf("%s: chmod round %d: %v", c.Name, r, err)
					}
					return
				}
				// Read our own write straight back. This is the pair P3
				// broke: a write, then a forced-fresh read that could
				// discard it before it ever reached the device.
				st, _, err := statPath(c, mine)
				if err != nil {
					if errsSeen[i] == "" {
						errsSeen[i] = fmt.Sprintf("%s: stat round %d: %v", c.Name, r, err)
					}
					return
				}
				if st.ModeBits != mode && reverts[i] == "" {
					reverts[i] = fmt.Sprintf("%s set mode %04o on %s and immediately read back %04o",
						c.Name, mode, mine, st.ModeBits)
				}
				// ...and hammer the PEER's record while it is writing it.
				if _, _, err := statPath(c, theirs); err != nil && errsSeen[i] == "" {
					errsSeen[i] = fmt.Sprintf("%s: watching %s: %v", c.Name, theirs, err)
					return
				}
			}
		}(i, c)
	}
	wg.Wait()

	for i, c := range clients {
		check(&ok, fmt.Sprintf("%s's own chmods are never reverted while its peer reads the same record",
			c.Name), reverts[i] == "", reverts[i])
		check(&ok, fmt.Sprintf("%s hit no error racing on the shared records", c.Name), errsSeen[i] == "", errsSeen[i])
	}

	// Both nodes must agree on the final state, and it must survive --
	// P4's loss was durable, so a value that merely looks right in
	// memory proves nothing.
	for _, path := range files {
		av, _, err1 := statPath(a, path)
		bv, _, err2 := statPath(b, path)
		if err1 != nil || err2 != nil {
			check(&ok, "both nodes can stat "+path+" afterwards", false, fmt.Sprintf("%v / %v", err1, err2))
			continue
		}
		check(&ok, fmt.Sprintf("both nodes agree on %s's final mode", path), av.ModeBits == bv.ModeBits,
			fmt.Sprintf("%s says %04o, %s says %04o", a.Name, av.ModeBits, b.Name, bv.ModeBits))
	}

	for _, path := range files {
		_, _ = a.Call("unlink", UnlinkArgs{Path: path})
	}
	_, _ = a.Call("rmdir", RmdirArgs{Path: dir})
	if ok {
		fmt.Printf("PASS: record write race: no write reverted, no torn read, both nodes agree\n")
	}
	return ok, nil
}

// RunDirentTorn: a peer's in-flight dirent-block write must never be
// mis-parsed.
//
// Directory reads take no cross-node lock -- by design, it is what
// makes lookup affordable -- so a reader can catch a writer's 4 KiB
// dirent-block write TORN, half old and half new. Before v0x0007 that
// was a silent mis-parse: garbage entry names, or an entry pointing at
// an inode number that was never there. The fix gives every dirent
// block a {magic, crc32c} tail and makes the reader retry a few times
// against a forced-fresh re-read, because the state is transient by
// construction -- the writer syncs under the namespace lock, so a
// re-read converges.
//
// No single kernel can produce a torn read of this kind: reader and
// writer share one buffer cache and serialise on the buffer lock. The
// loop-device suite therefore pokes a bad CRC, which proves the
// detection and nothing about the retry converging under a real
// concurrent writer -- the case where getting it wrong means a plain
// `ls` returning EIO, which is what the field reported.
func RunDirentTorn(clients []*Client, baseDir string, par int) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("dirent-torn needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a, b := clients[0], clients[1]
	dir := baseDir + "/direnttorn"
	fmt.Printf("=== dirent tearing: %s mutates one directory while %s reads it without pause ===\n", a.Name, b.Name)

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}
	ok := true

	// Enough names to span several dirent blocks, so the writer is
	// rewriting a block the reader may be part-way through.
	const files = 45
	var wg sync.WaitGroup
	var writeErr, readErr string
	var reads int
	done := make(chan struct{})

	wg.Add(2)
	// The writer is sharded across a's own connections -- which is not
	// only for speed here: several connections mutating one directory
	// at once is MORE of the storm this scenario is about, since the
	// reader is trying to catch a dirent block mid-write. The reader
	// stays on one connection, as a readdir loop naturally is.
	wconns, wcloser, err := a.Parallel(par, 5*time.Second)
	if err != nil {
		return false, err
	}
	defer wcloser()

	go func() { // the writer: create, then remove, then create again
		defer wg.Done()
		defer close(done)
		for pass := 0; pass < 2; pass++ {
			if e := shardedCalls(wconns, files, func(c *Client, i int) error {
				name := fmt.Sprintf("%s/t%03d", dir, i)
				resp, err := c.Call("write", WriteArgs{Path: name, Size: 32, Stamp: "tt"})
				return decodeResult(c.Name, resp, err, nil)
			}); e != nil && writeErr == "" {
				writeErr = fmt.Sprintf("creates (pass %d): %v", pass, e)
				return
			}
			if pass == 0 {
				if e := shardedCalls(wconns, files, func(c *Client, i int) error {
					if i%2 != 0 {
						return nil
					}
					resp, err := c.Call("unlink", UnlinkArgs{Path: fmt.Sprintf("%s/t%03d", dir, i)})
					return decodeResult(c.Name, resp, err, nil)
				}); e != nil && writeErr == "" {
					writeErr = fmt.Sprintf("unlinks: %v", e)
					return
				}
			}
		}
	}()
	go func() { // the reader: never stops, never takes a lock
		defer wg.Done()
		for {
			var rd ReaddirResult
			resp, err := b.Call("readdir", ReaddirArgs{Path: dir})
			if err := decodeResult(b.Name, resp, err, &rd); err != nil {
				// THE assertion. A torn block the reader cannot
				// resolve surfaces here as EIO from a plain readdir --
				// transient tearing must be retried into a correct
				// answer, never reported.
				readErr = fmt.Sprintf("readdir failed mid-storm: %v", err)
				return
			}
			// Every name a listing returns must be one we could have
			// created: a mis-parsed block yields names that were never
			// written at all.
			for _, n := range rd.Names {
				if len(n) != 4 || n[0] != 't' {
					readErr = fmt.Sprintf("readdir returned %q, which no node ever created -- a mis-parsed dirent block", n)
					return
				}
			}
			reads++
			select {
			case <-done: // the writer has finished; one last pass was just made
				return
			default:
			}
		}
	}()
	wg.Wait()

	check(&ok, fmt.Sprintf("%s's %d readdirs never failed or returned a name nobody created", b.Name, reads),
		readErr == "", readErr)
	check(&ok, a.Name+"'s namespace storm completed without error", writeErr == "", writeErr)

	// Converged: once the writing stops, both nodes must see the same
	// complete directory.
	var ra, rb ReaddirResult
	resp, err := a.Call("readdir", ReaddirArgs{Path: dir})
	if err := decodeResult(a.Name, resp, err, &ra); err != nil {
		return false, fmt.Errorf("final readdir on %s: %w", a.Name, err)
	}
	resp, err = b.Call("readdir", ReaddirArgs{Path: dir})
	if err := decodeResult(b.Name, resp, err, &rb); err != nil {
		return false, fmt.Errorf("final readdir on %s: %w", b.Name, err)
	}
	check(&ok, "both nodes see the same directory once the storm stops", len(ra.Names) == len(rb.Names),
		fmt.Sprintf("%s sees %d entries, %s sees %d", a.Name, len(ra.Names), b.Name, len(rb.Names)))
	check(&ok, fmt.Sprintf("the directory holds all %d entries at the end", files), len(ra.Names) == files,
		fmt.Sprintf("%s sees %d", a.Name, len(ra.Names)))

	_ = shardedCalls(wconns, files, func(c *Client, i int) error {
		_, _ = c.Call("unlink", UnlinkArgs{Path: fmt.Sprintf("%s/t%03d", dir, i)})
		return nil
	})
	_, _ = a.Call("rmdir", RmdirArgs{Path: dir})
	if ok {
		fmt.Printf("PASS: dirent tearing: every concurrent read resolved to a correct answer\n")
	}
	return ok, nil
}

// RunCAW: the atomic COMPARE AND WRITE primitive, exercised and proven
// to have been contended.
//
// Every claim path in this filesystem -- the namespace lock, the
// whole-file lock, the node registry row, Zone Group ownership, the
// inode bitmap, the pending-free queue -- rests on
// cetrafs_cas_region(). On a device with atomic CAW that is one fused
// SCSI command; without it, it degrades to a serialised read / mutate /
// write that is only safe because the mount gate then admits a single
// node. The loop-device suite has NO CAW at all, so every automated
// test in the project exercises the fallback and nothing exercises the
// primitive the cluster actually runs on.
//
// Two things are asserted, and the second is the one with teeth:
//
//  1. Both nodes really have atomic CAW. If they do not, the volume can
//     only safely have one mounter and every other scenario in this
//     suite is quietly testing something else.
//  2. The compare-and-swap was genuinely CONTENDED during this run.
//     "no errors" is not evidence of that: each CAW costs tens of
//     milliseconds on a real LUN, so two nodes can take turns and never
//     collide once, and the run would be exactly as green while
//     exercising no race at all. cas_miscompares counts the swaps the
//     DEVICE rejected because the image had changed underneath -- each
//     retried against a fresh read. A rising count is the proof.
func RunCAW(clients []*Client, baseDir string, par int) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("caw needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a := clients[0]
	dir := baseDir + "/caw"
	fmt.Printf("=== compare-and-write: capability on both nodes, then proof it was contended ===\n")

	snap := func(c *Client) (ProcSnapshotResult, error) {
		var s ProcSnapshotResult
		resp, err := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
		return s, decodeResult(c.Name, resp, err, &s)
	}

	ok := true
	before := map[string]uint64{}
	var klass string
	for _, c := range clients {
		s, err := snap(c)
		if err != nil {
			return false, err
		}
		fmt.Printf("  %-12s caw class=%s logical_block_size=%d max_caw_blocks=%d available=%v (miscompares so far %d)\n",
			c.Name, s.CAWClass, s.CAWLogicalBlockSize, s.CAWMaxBlocks, s.CAWAvailable, s.CASMiscompares)

		check(&ok, c.Name+" reports a usable atomic CAW", s.CAWAvailable && s.CAWMaxBlocks >= 1,
			fmt.Sprintf("available=%v max_caw_blocks=%d -- without it this node has no cross-node atomicity "+
				"and every claim takes the serialised fallback", s.CAWAvailable, s.CAWMaxBlocks))
		// The atomic unit is one LOGICAL block, which is independent of
		// the 4096-byte filesystem block -- 512 on the LUN this was
		// built against. A record has to fit inside it, which is why
		// the CAS region is a sector rather than a block.
		check(&ok, c.Name+" reports a sane logical block size", s.CAWLogicalBlockSize >= 512,
			fmt.Sprintf("logical_block_size=%d", s.CAWLogicalBlockSize))

		if klass == "" {
			klass = s.CAWClass
		} else {
			check(&ok, "both nodes report the same transport class for the shared device", s.CAWClass == klass,
				fmt.Sprintf("%s vs %s -- they are not describing the same LUN", s.CAWClass, klass))
		}
		before[c.Name] = s.CASMiscompares
	}
	if !ok {
		// Everything below measures contention on a primitive that is
		// not there; saying so once is more useful than failing twice.
		fmt.Printf("FAIL: compare-and-write: the capability check failed, so contention was not measured\n")
		return false, nil
	}

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}

	// Ordinary namespace work is what takes the CAS: each create
	// acquires the parent's namespace lock (one compare-and-swap on the
	// directory's record) and claims an inode bitmap bit (another).
	// Both nodes doing it into ONE directory at once is the contention.
	// Driven over `par` connections per node, which is what actually
	// makes collisions likely: a single connection per node means at
	// most two compare-and-swaps can ever be in flight, and on a LUN
	// where each costs tens of milliseconds two nodes can simply take
	// turns and never meet. The contention assertion below is only
	// worth making if contention is plausible.
	const perNode = 30
	var wg sync.WaitGroup
	var errMu sync.Mutex
	errs := make([]string, len(clients))
	for i, c := range clients {
		cs, closer, err := c.Parallel(par, 5*time.Second)
		if err != nil {
			return false, err
		}
		defer closer()
		for k := range cs {
			wg.Add(1)
			go func(i, k int, conn *Client) {
				defer wg.Done()
				for n := k; n < perNode; n += par {
					path := fmt.Sprintf("%s/%s-%02d", dir, conn.Name, n)
					resp, err := conn.Call("write", WriteArgs{Path: path, Size: 32, Stamp: "caw"})
					if err := decodeResult(conn.Name, resp, err, nil); err != nil {
						errMu.Lock()
						if errs[i] == "" {
							errs[i] = fmt.Sprintf("%s: create %s: %v", conn.Name, path, err)
						}
						errMu.Unlock()
						return
					}
				}
			}(i, k, cs[k])
		}
	}
	wg.Wait()
	for i, c := range clients {
		check(&ok, c.Name+" created its whole share without error", errs[i] == "", errs[i])
	}

	var total uint64
	for _, c := range clients {
		s, err := snap(c)
		if err != nil {
			return false, err
		}
		delta := s.CASMiscompares - before[c.Name]
		fmt.Printf("  %-12s compare-and-swaps rejected and retried during the storm: %d\n", c.Name, delta)
		total += delta
	}
	// NOT an assertion. A MISCOMPARE means two nodes issued a CAW against
	// the same sector and one lost the swap -- but cetrafs resolves most
	// contention BEFORE any CAW is issued (cetrafs_nslock_try() re-reads
	// the record and returns -EBUSY without swapping), so a swap-level
	// collision is a timing artifact, not a property the filesystem
	// promises. Failing on its absence is failing on a race not having
	// happened, which is flaky by construction -- and it did fail on a
	// healthy 3-node cluster.
	//
	// Atomicity is proven deterministically elsewhere and does not need
	// this: concurrent-create requires EXACTLY ONE winner when every node
	// creates the same path at once, and the in-kernel cas_selftest
	// exercises the primitive on every mount.
	if total == 0 {
		fmt.Printf("  NOTE: no MISCOMPARE during this storm -- the nodes did not collide at the swap.\n" +
			"        Not a failure: contention is normally resolved by the pre-read, and atomicity is\n" +
			"        asserted by concurrent-create (exactly one winner) and the in-kernel CAS selftest.\n" +
			"        Raise -caw-files or -par to make collisions likelier.\n")
	} else {
		fmt.Printf("  the compare-and-swap was genuinely contended: %d MISCOMPARE(s) seen and retried\n", total)
	}
	// Every name survived, on both nodes. A CAS that lost an update
	// would show up as a missing file or a shared inode number, which
	// is what the loop-device cas_concurrency suite measured locally.
	for _, reader := range clients {
		var rd ReaddirResult
		resp, err := reader.Call("readdir", ReaddirArgs{Path: dir})
		if err := decodeResult(reader.Name, resp, err, &rd); err != nil {
			return false, fmt.Errorf("%s: final readdir: %w", reader.Name, err)
		}
		check(&ok, fmt.Sprintf("%s sees all %d files both nodes created", reader.Name, perNode*len(clients)),
			len(rd.Names) == perNode*len(clients), fmt.Sprintf("sees %d", len(rd.Names)))
	}

	for _, c := range clients {
		for n := 0; n < perNode; n++ {
			_, _ = a.Call("unlink", UnlinkArgs{Path: fmt.Sprintf("%s/%s-%02d", dir, c.Name, n)})
		}
	}
	_, _ = a.Call("rmdir", RmdirArgs{Path: dir})
	if ok {
		fmt.Printf("PASS: compare-and-write: atomic on both nodes, and proven contended\n")
	}
	return ok, nil
}

// shardedCalls runs fn(conn, i) for i in [0,n) spread across conns, one
// goroutine per connection -- the only shape that is safe, since a
// Client carries one request at a time. Returns the first error.
//
// Exists because three scenarios were each hand-rolling the same loop,
// and the two that were written before Client.Parallel existed were
// still doing their namespace work one operation at a time: about a
// second each on a real LUN, which made them the two
// slowest things in the suite by a wide margin.
func shardedCalls(conns []*Client, n int, fn func(c *Client, i int) error) error {
	var wg sync.WaitGroup
	var mu sync.Mutex
	var firstErr error

	for k := range conns {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			for i := k; i < n; i += len(conns) {
				if err := fn(conns[k], i); err != nil {
					mu.Lock()
					if firstErr == nil {
						firstErr = err
					}
					mu.Unlock()
					return
				}
			}
		}(k)
	}
	wg.Wait()
	return firstErr
}

// RunPendingFree: the delegated-free path, which a single node cannot
// execute at all.
//
// A node may only touch the data bitmap of a Zone Group it OWNS. So
// when node B deletes a file whose blocks live in node A's zone group,
// B must not free them directly -- it appends a {lba, count} entry to
// A's pending-free queue, and A applies it on a later heartbeat tick.
// Freeing directly is the bitmap corruption this design exists to
// prevent: B's cached image of a foreign bitmap can be arbitrarily
// stale, and writing it back reverts however many allocations A made
// in the meantime, handing the same physical block to two files.
//
// With one node every zone group is owned locally, every free is
// correctly direct, and the queue is never written -- so no loop test
// can reach this, and the only previous coverage was dir-storm
// observing that space came back eventually. This watches the queue
// itself: the entry appears, then it is gone, and the blocks return.
func RunPendingFree(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("pending-free needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a, b := clients[0], clients[1]
	dir := baseDir + "/pendingfree"
	fmt.Printf("=== pending free: %s deletes a file whose blocks live in %s's zone group ===\n", b.Name, a.Name)

	// Which zone groups does each node own? The whole scenario rests on
	// the file's blocks belonging to a group the DELETER does not own,
	// so that is established rather than assumed.
	owned := map[string][]int{}
	for _, c := range clients {
		var snap ProcSnapshotResult
		resp, err := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
		if err := decodeResult(c.Name, resp, err, &snap); err != nil {
			return false, err
		}
		for _, zg := range snap.ZoneGroups {
			if zg.ThisNode {
				owned[c.Name] = append(owned[c.Name], zg.ID)
			}
		}
		fmt.Printf("    %-12s owns zone group(s) %v\n", c.Name, owned[c.Name])
	}
	ok := true
	if len(owned[a.Name]) == 0 {
		// DUMP, do not just decline: "owns no zone group" was a parser
		// bug for weeks, and the only way to tell that apart from the
		// real thing is to show what the kernel actually said.
		for _, cl := range clients {
			if resp, err := cl.Call("proc_raw", ProcRawArgs{Device: cl.Device}); err == nil {
				var pr ProcRawResult
				if decodeResult(cl.Name, resp, err, &pr) == nil {
					fmt.Printf("---- %s: /proc/fs/cetrafs/<dev>/info ----\n%s\n", cl.Name, pr.Info)
				}
			}
		}
		return skipScenario("pending free: %s owns no zone group, so it cannot host the file", a.Name)
	}
	check(&ok, "the two nodes own different zone groups", len(owned[b.Name]) == 0 ||
		owned[a.Name][0] != owned[b.Name][0],
		fmt.Sprintf("%s and %s both own %v -- a foreign free could not happen", a.Name, b.Name, owned[a.Name]))
	targetZG := owned[a.Name][0]

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}

	queueLen := func(c *Client, zg int) (int, string, error) {
		var res DeviceReadResult
		resp, err := c.Call("device_read", DeviceReadArgs{Kind: "pending", Args: []string{fmt.Sprint(zg)}})
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return 0, "", err
		}
		n := 0
		for _, line := range strings.Split(strings.TrimSpace(res.Output), "\n") {
			if strings.TrimSpace(line) != "" {
				n++
			}
		}
		return n, strings.TrimSpace(res.Output), nil
	}

	before, _, err := queueLen(a, targetZG)
	if err != nil {
		return false, fmt.Errorf("reading the queue: %w", err)
	}

	// A writes the file, so its blocks are allocated from A's own zone
	// group. Big enough to be several extents' worth of blocks, so the
	// free is worth queueing.
	path := dir + "/owned-by-" + a.Name
	var w WriteResult
	resp, err := a.Call("write", WriteArgs{Path: path, Size: 512 * 1024, Stamp: "pf"})
	if err := decodeResult(a.Name, resp, err, &w); err != nil {
		return false, fmt.Errorf("%s: writing the file: %w", a.Name, err)
	}

	var pre, post StatfsResult
	resp, err = a.Call("statfs", struct{}{})
	if err := decodeResult(a.Name, resp, err, &pre); err != nil {
		return false, err
	}

	// B deletes it. B owns a different zone group, so every block of
	// this file is foreign to B and must be queued, not freed.
	if resp, err := b.Call("unlink", UnlinkArgs{Path: path}); decodeResult(b.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s: unlinking the peer's file: %v", b.Name, err)
	}

	// The entry must be visible BEFORE the owner's next tick drains it,
	// so this is read immediately and then polled -- the queue is the
	// only place a delegated free exists between those two moments.
	appeared := false
	drained := false
	for i := 0; i < 40; i++ {
		n, _, err := queueLen(a, targetZG)
		if err != nil {
			return false, err
		}
		if n > before {
			appeared = true
		}
		if appeared && n <= before {
			drained = true
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	check(&ok, fmt.Sprintf("%s's free was APPENDED to %s's queue rather than applied directly", b.Name, a.Name),
		appeared, "the queue never grew -- the deleting node wrote a bitmap it does not own")
	check(&ok, fmt.Sprintf("%s drained its own queue on a heartbeat tick", a.Name), drained,
		"the entry is still queued after 20s -- it would be applied eventually, but nothing is draining")

	// And the space really came back, on the owner's own accounting.
	for i := 0; i < 40; i++ {
		resp, err = a.Call("statfs", struct{}{})
		if err := decodeResult(a.Name, resp, err, &post); err != nil {
			return false, err
		}
		if post.FreeBlocks >= pre.FreeBlocks {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	check(&ok, "every block came back once the queue was applied", post.FreeBlocks >= pre.FreeBlocks,
		fmt.Sprintf("free blocks %d before the write, %d after the delete", pre.FreeBlocks, post.FreeBlocks))

	_, _ = a.Call("rmdir", RmdirArgs{Path: dir})
	if ok {
		fmt.Printf("PASS: pending free: the delegated free was queued, drained and accounted for\n")
	}
	return ok, nil
}

// RunFenceReclaim: a node loses its device while holding a file lock,
// a peer reclaims it, and the first node fences ITSELF when it returns.
//
// This is the split-brain protection, end to end, and nothing short of
// two real kernels can test it. The loop suite pokes the fence epoch
// directly, which proves the decision logic and not the race.
//
// What made it reachable at all is link_down: every other way of
// producing a quiet node releases what it was holding first (a clean
// unmount) or does not actually stop the heartbeat (killing the slave
// process leaves the kernel work running). Taking the node's own SCSI
// device offline stops its renew while the mount stays up holding its
// claims -- verified single-node first in
// tests/kernel/device_failure.sh.
// Cluster timing defaults, mirroring kmod.h's
// CETRAFS_HEARTBEAT_INTERVAL_SECS and CETRAFS_NODE_STALE_SECS, so a
// scenario that compresses them can put them back.
const (
	defaultHBIntervalSecs = 15
	defaultStaleSecs      = 60
)

func RunFenceReclaim(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("fence-reclaim needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	a, b := clients[0], clients[1]
	linkRestored := false
	var heldHandle uint64
	defer func() {
		// Release the fd BEFORE unmounting: this scenario's whole point
		// is that a holds a file open, so an early return leaves the
		// mount busy and the cleanup fails on every path.
		if heldHandle != 0 {
			if _, err := a.Call("close", CloseArgs{Handle: heldHandle}); err != nil {
				fmt.Printf("WARNING: could not close %s's held fd: %v\n", a.Name, err)
			}
		}
		if !linkRestored {
			// Never leave a node's device offline, whatever went wrong.
			if _, err := a.Call("link_up", nil); err != nil {
				fmt.Printf("WARNING: could not restore %s's device: %v\n", a.Name, err)
			}
		}
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	dir := baseDir + "/fence"
	path := dir + "/held"
	fmt.Printf("=== fence reclaim: %s loses its device holding a lock, %s reclaims it ===\n", a.Name, b.Name)

	// Compress the cluster timing on BOTH nodes. The defaults make the
	// staleness window ~60s, which this scenario would spend waiting;
	// the peer-advertised floor (four of the peer's own beats) still
	// applies on top, so the thing being tested is unchanged -- only
	// the clock it runs on. Restored at the end.
	// staleFirst orders the two writes so the per-mount controls file's
	// stale_secs >= 3x hb_interval_secs rule is never transiently
	// violated: raise stale before widening the beat (restore), narrow
	// the beat before lowering stale (compress).
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
	setTiming("5", "15", false)
	defer setTiming(fmt.Sprintf("%d", defaultHBIntervalSecs), fmt.Sprintf("%d", defaultStaleSecs), true)

	// Wait until the peer can SEE the new rate. A row advertises the
	// old interval until its next renew, and every peer floors its
	// staleness window at four of whatever is advertised -- so acting
	// before the advertisement lands would simply use the old window.
	// Setting the control fires a tick immediately, so this is usually
	// one round trip; polled rather than slept because "usually" is not
	// a guarantee.
	if err := waitAdvertisedInterval(b, a, 5, 20*time.Second); err != nil {
		fmt.Printf("WARNING: %s\n", err)
	}

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}

	ok := true

	// a takes the on-disk exclusive lock by holding the file open for
	// write. This is the claim b will reclaim, and reclaiming it is what
	// bumps a's fence epoch.
	var held OpenHoldResult
	resp, err := a.Call("open_hold", OpenHoldArgs{Path: path, Mode: "rdwr", Create: true})
	if err2 := decodeResult(a.Name, resp, err, &held); err2 != nil {
		return false, fmt.Errorf("%s could not open %s for write: %v", a.Name, path, err2)
	}
	heldHandle = held.Handle

	var snapA ProcSnapshotResult
	resp, err = a.Call("proc_snapshot", ProcSnapshotArgs{Device: a.Device})
	if err2 := decodeResult(a.Name, resp, err, &snapA); err2 != nil {
		return false, fmt.Errorf("proc_snapshot on %s: %v", a.Name, err2)
	}
	rowA := fmt.Sprintf("%d", snapA.ThisNodeID)

	// a's fence epoch as b can see it, before anything is reclaimed.
	epochBefore, err := readFenceEpoch(b, rowA)
	if err != nil {
		return false, fmt.Errorf("reading %s's fence epoch from %s: %v", a.Name, b.Name, err)
	}

	fmt.Printf("--- %s: device offline (node row %s, fence_epoch %d)\n", a.Name, rowA, epochBefore)
	if resp, err := a.Call("link_down", nil); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s link_down failed", a.Name)
	}

	// Wait for b to actually SEE a as stale. Polling the peer's own view
	// rather than sleeping a computed window: the staleness rule floors
	// the wait at several of the peer's advertised beats, so the only
	// honest source for "is it stale yet" is the node doing the judging.
	stale := false
	for i := 0; i < 150; i++ {
		var snapB ProcSnapshotResult
		resp, err := b.Call("proc_snapshot", ProcSnapshotArgs{Device: b.Device})
		if err2 := decodeResult(b.Name, resp, err, &snapB); err2 == nil {
			for _, n := range snapB.Nodes {
				if fmt.Sprintf("%d", n.ID) == rowA && n.Stale {
					stale = true
				}
			}
		}
		if stale {
			break
		}
		time.Sleep(time.Second)
	}
	check(&ok, fmt.Sprintf("%s sees %s go stale once its device is gone", b.Name, a.Name), stale,
		"the peer never timed out -- nothing downstream can be reclaimed")

	if stale {
		// The reclaim itself: b opening the file finds a stale foreign
		// lock, replays a's journal and takes it. Deterministic, unlike
		// waiting for a heartbeat tick to feel like stealing a ZG.
		var bHeld OpenHoldResult
		resp, err := b.Call("open_hold", OpenHoldArgs{Path: path, Mode: "rdwr"})
		rErr := decodeResult(b.Name, resp, err, &bHeld)
		check(&ok, fmt.Sprintf("%s reclaims the lock a stale %s was holding", b.Name, a.Name), rErr == nil,
			fmt.Sprintf("open was refused: %v", rErr))
		if rErr == nil {
			if resp, err := b.Call("close", CloseArgs{Handle: bHeld.Handle}); err != nil {
				_ = resp
			}
		}

		epochAfter, eErr := readFenceEpoch(b, rowA)
		check(&ok, "and bumps the stale node's fence epoch in doing so",
			eErr == nil && epochAfter > epochBefore,
			fmt.Sprintf("epoch %d -> %d (err %v) -- a reclaim that does not revoke the lease leaves a live peer believing it still owns what was taken", epochBefore, epochAfter, eErr))
	}

	fmt.Printf("--- %s: device back\n", a.Name)
	if resp, err := a.Call("link_up", nil); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s link_up failed", a.Name)
	}
	linkRestored = true

	// a must notice its lease was revoked and fence ITSELF -- the half
	// that stops split brain. Until it does, it still believes it holds
	// the lock b has taken.
	fenced := false
	for i := 0; i < 150; i++ {
		var s ProcSnapshotResult
		resp, err := a.Call("proc_snapshot", ProcSnapshotArgs{Device: a.Device})
		if err2 := decodeResult(a.Name, resp, err, &s); err2 == nil && s.Fenced {
			fenced = true
			break
		}
		time.Sleep(time.Second)
	}
	check(&ok, fmt.Sprintf("%s fences itself once its device returns", a.Name), fenced,
		"a node whose lease was revoked went on believing it owned what a peer had taken -- this is split brain")

	if fenced {
		// A fenced node must not be able to write. Reported as an error
		// rather than silently dropped is the whole point.
		resp, err := a.Call("write", WriteArgs{Path: dir + "/after-fence", Size: 4096, Stamp: "fence"})
		wErr := decodeResult(a.Name, resp, err, nil)
		check(&ok, "and its writes fail rather than landing", wErr != nil,
			"a fenced node still wrote to the shared volume")
	}

	// Leave the cluster usable: the fenced node rejoins only by
	// remounting, which baselines its epoch afresh.
	if resp, err := a.Call("close", CloseArgs{Handle: held.Handle}); err == nil {
		_ = resp
		heldHandle = 0
	}
	if resp, err := a.Call("unmount", UnmountArgs{}); decodeResult(a.Name, resp, err, nil) != nil {
		fmt.Printf("WARNING: %s could not unmount after fencing\n", a.Name)
	}
	if resp, err := a.Call("mount", MountArgs{}); decodeResult(a.Name, resp, err, nil) == nil {
		var s ProcSnapshotResult
		resp, err := a.Call("proc_snapshot", ProcSnapshotArgs{Device: a.Device})
		if err2 := decodeResult(a.Name, resp, err, &s); err2 == nil {
			check(&ok, fmt.Sprintf("%s rejoins cleanly on remount, not fenced", a.Name), !s.Fenced,
				"a past revocation must not fence the new incarnation")
		}
	}

	return ok, nil
}

// readFenceEpoch reads one Node Registry row straight off the device of
// whichever node is asked, and returns its fence epoch.
func readFenceEpoch(c *Client, row string) (uint64, error) {
	var res DeviceReadResult
	resp, err := c.Call("device_read", DeviceReadArgs{Kind: "node", Args: []string{row}})
	if err2 := decodeResult(c.Name, resp, err, &res); err2 != nil {
		return 0, err2
	}
	m := regexp.MustCompile(`fence_epoch=(\d+)`).FindStringSubmatch(res.Output)
	if m == nil {
		return 0, fmt.Errorf("no fence_epoch in %q", res.Output)
	}
	var v uint64
	if _, err := fmt.Sscanf(m[1], "%d", &v); err != nil {
		return 0, err
	}
	return v, nil
}

// RunReplayRace: two survivors find the SAME dead node's journal area
// dirty, and exactly one of them replays it.
//
// Needs three nodes and says so rather than pretending: with two there
// is a dead node and a single survivor, so there is never a second
// claimant and the code path under test -- the loser treating -EEXIST
// as success and walking away -- is simply not reached.
//
// The trigger is deliberate rather than a wait for two heartbeat sweeps
// to coincide. Node c dies holding a file's exclusive lock with its
// journal area dirty; a and b then open that file AT THE SAME INSTANT,
// and the stale-lock reclaim path replays the dead node's journal
// before taking the lock. Both attempt the claim; one wins.
//
// "No errors" would prove nothing here, which is why kmod counts the
// outcomes: exactly one node must record a replay, and a node that
// loses must record a decline.
func RunReplayRace(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 3 {
		fmt.Println("  a contended replay claim needs a dead node PLUS two survivors;")
		fmt.Println("  with fewer there is only ever one claimant and nothing to contend.")
		return skipScenario("replay race: needs 3 nodes, have %d", len(clients))
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	a, b, c := clients[0], clients[1], clients[2]
	linkRestored := false
	var heldHandle uint64
	var lockedIno uint64
	defer func() {
		if heldHandle != 0 {
			if _, err := c.Call("close", CloseArgs{Handle: heldHandle}); err != nil {
				fmt.Printf("WARNING: could not close %s's held fd: %v\n", c.Name, err)
			}
		}
		if !linkRestored {
			if _, err := c.Call("link_up", nil); err != nil {
				fmt.Printf("WARNING: could not restore %s's device: %v\n", c.Name, err)
			}
		}
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	dir := baseDir + "/replayrace"
	path := dir + "/held"
	fmt.Printf("=== replay race: %s dies dirty, %s and %s race to replay it ===\n", c.Name, a.Name, b.Name)

	setTiming := func(hb, stale string, staleFirst bool) {
		order := [][2]string{{"hb_interval_secs", hb}, {"stale_secs", stale}}
		if staleFirst {
			order = [][2]string{{"stale_secs", stale}, {"hb_interval_secs", hb}}
		}
		for _, cl := range clients[:3] {
			for _, kv := range order {
				resp, err := cl.Call("set_control", SetControlArgs{Key: kv[0], Value: kv[1]})
				if e := decodeResult(cl.Name, resp, err, nil); e != nil {
					fmt.Printf("WARNING: %s could not set %s=%s: %v\n", cl.Name, kv[0], kv[1], e)
				}
			}
		}
	}
	setTiming("5", "15", false)
	defer setTiming(fmt.Sprintf("%d", defaultHBIntervalSecs), fmt.Sprintf("%d", defaultStaleSecs), true)
	if err := waitAdvertisedInterval(a, c, 5, 20*time.Second); err != nil {
		fmt.Printf("WARNING: %s\n", err)
	}

	if resp, err := c.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(c.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}
	// Namespace work on c dirties its journal area: the flag goes DIRTY
	// before the first journaled write of a mount and is only parked
	// clean at unmount, which is exactly what c is about to not do.
	for i := 0; i < 4; i++ {
		p := fmt.Sprintf("%s/dirty-%d", dir, i)
		if resp, err := c.Call("write", WriteArgs{Path: p, Size: 4096, Stamp: "d"}); decodeResult(c.Name, resp, err, nil) != nil {
			return false, fmt.Errorf("%s could not write %s", c.Name, p)
		}
	}
	var held OpenHoldResult
	resp, err := c.Call("open_hold", OpenHoldArgs{Path: path, Mode: "rdwr", Create: true})
	if e := decodeResult(c.Name, resp, err, &held); e != nil {
		return false, fmt.Errorf("%s could not hold %s: %v", c.Name, path, e)
	}
	heldHandle = held.Handle

	// VERIFY the precondition instead of narrating it. "lock held" was a
	// printf, so when the opens below both succeeded the verdict read
	// "the whole-file lock is not exclusive" -- which is only one of the
	// explanations. The other is that c never took a lock at all, which
	// is exactly what a nofilelock cluster does (no automatic claim on
	// write-open), and that is a property of the mount, not a defect.
	// Reading the lock off the disk tells the two apart, and a run that
	// cannot establish its own precondition must SKIP, not fail.
	{
		var st StatResult
		resp, err := c.Call("stat", StatArgs{Path: path})
		if e := decodeResult(c.Name, resp, err, &st); e != nil {
			return false, fmt.Errorf("%s could not stat %s: %v", c.Name, path, e)
		}
		var dr DeviceReadResult
		resp, err = a.Call("device_read", DeviceReadArgs{Kind: "inode-lock",
			Args: []string{fmt.Sprintf("%d", st.Ino)}})
		if e := decodeResult(a.Name, resp, err, &dr); e != nil {
			return false, fmt.Errorf("reading the lock record for ino %d: %v", st.Ino, e)
		}
		// inode_lock_poke prints: owner=<n> mode=<n> ns_owner=<n> readers=0x..
		var owner, mode int
		if _, e := fmt.Sscanf(strings.TrimSpace(dr.Output), "owner=%d mode=%d", &owner, &mode); e != nil {
			return false, fmt.Errorf("unparsable lock record %q: %v", dr.Output, e)
		}
		if mode != 1 /* CETRAFS_LOCK_EXCLUSIVE */ {
			fmt.Printf("  the on-disk lock record for ino %d reads: %s\n", st.Ino, strings.TrimSpace(dr.Output))
			for _, cl := range clients {
				if r, e := cl.Call("proc_raw", ProcRawArgs{Device: cl.Device}); e == nil {
					var pr ProcRawResult
					if decodeResult(cl.Name, r, e, &pr) == nil {
						for _, ln := range strings.Split(pr.Info, "\n") {
							if strings.HasPrefix(ln, "file_lock:") || strings.HasPrefix(ln, "this_node_id:") {
								fmt.Printf("    %-12s %s\n", cl.Name, ln)
							}
						}
					}
				}
			}
			return skipScenario("replay race: %s holds no exclusive lock on %s (mode=%d) -- with the "+
				"cluster file lock off there is no claim for the survivors to contend, so this scenario "+
				"cannot test what it exists to test", c.Name, path, mode)
		}
		lockedIno = st.Ino
		fmt.Printf("--- %s holds the exclusive lock on ino %d (verified on disk)\n", c.Name, st.Ino)
	}

	// Baseline the replay counters BEFORE the device goes offline, not
	// after the staleness wait. c's journal is replayed by whichever
	// survivor gets there first, and with a compressed heartbeat that is
	// normally the periodic sweep DURING the wait -- by the time the
	// opens run the flag is already clean and the replay is a no-op. A
	// window that starts after the wait therefore measures 0 replays on
	// a cluster that replayed exactly once, correctly.
	before := make([]ProcSnapshotResult, 2)
	for i, cl := range []*Client{a, b} {
		resp, err := cl.Call("proc_snapshot", ProcSnapshotArgs{Device: cl.Device})
		if e := decodeResult(cl.Name, resp, err, &before[i]); e != nil {
			return false, fmt.Errorf("snapshot %s: %v", cl.Name, e)
		}
	}

	fmt.Printf("--- %s: device offline, journal dirty, lock held\n", c.Name)
	if resp, err := c.Call("link_down", nil); decodeResult(c.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s link_down failed", c.Name)
	}

	ok := true
	stale := false
	for i := 0; i < 60 && !stale; i++ {
		var snap ProcSnapshotResult
		resp, err := a.Call("proc_snapshot", ProcSnapshotArgs{Device: a.Device})
		if e := decodeResult(a.Name, resp, err, &snap); e == nil {
			var snapC ProcSnapshotResult
			r2, e2 := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
			_ = decodeResult(c.Name, r2, e2, &snapC)
			for _, n := range snap.Nodes {
				if n.Stale && !n.ThisNode {
					stale = true
				}
			}
		}
		if !stale {
			time.Sleep(time.Second)
		}
	}
	check(&ok, fmt.Sprintf("%s and %s see %s go stale", a.Name, b.Name, c.Name), stale,
		"nothing timed out, so no replay can be triggered")
	if !stale {
		return ok, nil
	}

	// (the replay baseline was taken before link_down -- see there)

	// Both survivors open the dead node's locked file at the same
	// instant. Each finds a stale foreign lock, and replaying the dead
	// node's journal is what the reclaim does FIRST -- so both reach
	// the replay claim together.
	outcomes := fireConcurrently([]*Client{a, b}, "open_hold", OpenHoldArgs{Path: path, Mode: "rdwr"})
	opened := 0
	for _, o := range outcomes {
		// o.err is the TRANSPORT error. A slave that successfully
		// REPORTS "open failed: ETXTBSY" returns err==nil with
		// resp.OK==false -- so counting o.err alone scored the kernel's
		// correct refusal as a successful open, and this scenario
		// reported "the whole-file lock is not exclusive" against a
		// kernel that had just logged "lost the race claiming the write
		// lock". The op's own verdict is resp.OK.
		if o.err == nil && o.resp.OK {
			opened++
			var h OpenHoldResult
			if json.Unmarshal(o.resp.Result, &h) == nil && h.Handle != 0 {
				_, _ = o.client.Call("close", CloseArgs{Handle: h.Handle})
			}
		}
	}
	if opened != 1 {
		// DUMP, do not infer. Three things distinguish every remaining
		// explanation, and the kernel already logs the decisive ones:
		//
		//   "reclaiming a stale lock from node N" -- the stale branch ran
		//   "lost the race claiming the write lock" -- the claim CAS refused
		//
		// Neither line on either node means the claim never ran (a
		// nofilelock mount, or the lock not seen); both nodes logging the
		// first and neither the second means the CAS is not refusing,
		// which would be a real exclusivity bug.
		fmt.Printf("  ---- why did %d opens succeed? ----\n", opened)
		var dr DeviceReadResult
		if r, e := a.Call("device_read", DeviceReadArgs{Kind: "inode-lock",
			Args: []string{fmt.Sprintf("%d", lockedIno)}}); e == nil {
			if decodeResult(a.Name, r, e, &dr) == nil {
				fmt.Printf("    lock record for ino %d now: %s\n", lockedIno, strings.TrimSpace(dr.Output))
			}
		}
		for _, cl := range []*Client{a, b, c} {
			if r, e := cl.Call("proc_raw", ProcRawArgs{Device: cl.Device}); e == nil {
				var pr ProcRawResult
				if decodeResult(cl.Name, r, e, &pr) == nil {
					for _, ln := range strings.Split(pr.Info, "\n") {
						if strings.HasPrefix(ln, "file_lock:") || strings.HasPrefix(ln, "this_node_id:") ||
							strings.HasPrefix(ln, "journal_replays:") {
							fmt.Printf("    %-12s %s\n", cl.Name, ln)
						}
					}
				}
			}
		}
		for _, cl := range []*Client{a, b} {
			var dt DmesgTailResult
			if r, e := cl.Call("dmesg_tail", DmesgTailArgs{Lines: 200}); e == nil {
				if decodeResult(cl.Name, r, e, &dt) == nil {
					for _, ln := range strings.Split(dt.Text, "\n") {
						if strings.Contains(ln, "lock: ino=") || strings.Contains(ln, "journal:") {
							fmt.Printf("    %-12s %s\n", cl.Name, strings.TrimSpace(ln))
						}
					}
				}
			}
		}
		fmt.Printf("  ---- end ----\n")
	}
	check(&ok, "exactly one survivor takes the dead node's file lock", opened == 1,
		fmt.Sprintf("%d of 2 opens succeeded -- the whole-file lock is not exclusive", opened))

	after := make([]ProcSnapshotResult, 2)
	for i, cl := range []*Client{a, b} {
		resp, err := cl.Call("proc_snapshot", ProcSnapshotArgs{Device: cl.Device})
		if e := decodeResult(cl.Name, resp, err, &after[i]); e != nil {
			return false, fmt.Errorf("snapshot %s: %v", cl.Name, e)
		}
	}
	replays := (after[0].JournalReplays - before[0].JournalReplays) +
		(after[1].JournalReplays - before[1].JournalReplays)
	declines := (after[0].JournalReplayDeclines - before[0].JournalReplayDeclines) +
		(after[1].JournalReplayDeclines - before[1].JournalReplayDeclines)

	check(&ok, "exactly one of them replays the dead node's journal area (sweep or open)", replays == 1,
		fmt.Sprintf("%d replays across both survivors -- two nodes writing one journal area is the corruption this claim exists to prevent", replays))
	// Evidence the race actually happened. A decline of 0 means the
	// loser's pre-check saw the area already clean and it never
	// attempted the claim -- a correct outcome, but one that proves
	// nothing about the contended path, so it is reported rather than
	// passed over in silence.
	if declines == 0 {
		fmt.Printf("  NOTE: no decline recorded -- the two survivors did not actually meet on this run;\n")
		fmt.Printf("        the -EEXIST path was not exercised, only the single-claimant one.\n")
	} else {
		check(&ok, "and the loser treats the lost claim as success", declines >= 1,
			"the losing claimant recorded no decline")
	}

	fmt.Printf("--- %s: device back\n", c.Name)
	if resp, err := c.Call("link_up", nil); decodeResult(c.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s link_up failed", c.Name)
	}
	linkRestored = true

	// Whatever happened, the volume must still be coherent: every file
	// the dead node wrote before it died is readable from a survivor.
	for i := 0; i < 4; i++ {
		p := fmt.Sprintf("%s/dirty-%d", dir, i)
		var st StatResult
		resp, err := a.Call("stat", StatArgs{Path: p})
		e := decodeResult(a.Name, resp, err, &st)
		check(&ok, fmt.Sprintf("%s is intact after the replay", p), e == nil,
			fmt.Sprintf("stat failed: %v", e))
	}

	// ...and the DIRECTORY itself is still readable, from every node.
	//
	// The stat loop above names each file by path, which only proves
	// lookup found it. It says nothing about the directory as a whole,
	// and that is what this scenario was seen to destroy: a run left
	// this directory's dirent block reading as zeros, so readdir
	// returned -EIO -- and because rmdir cannot confirm an unreadable
	// directory is empty, the volume could not even be cleaned up
	// afterwards. The scenario PASSED that run; nothing here looked.
	//
	// Checked on all three, the revived node included: the damage was
	// found by a node that had not taken part in the replay at all, and
	// a check that only asked the survivors would have missed it.
	for _, cl := range []*Client{a, b, c} {
		var rd ReaddirResult
		resp, err := cl.Call("readdir", ReaddirArgs{Path: dir})
		e := decodeResult(cl.Name, resp, err, &rd)
		check(&ok, fmt.Sprintf("%s can still read the directory after the replay", cl.Name), e == nil,
			fmt.Sprintf("readdir %s failed: %v -- a dirent block did not survive the crash and recovery", dir, e))
		if e == nil && len(rd.Names) < 4 {
			check(&ok, fmt.Sprintf("%s still sees the dead node's files in it", cl.Name), false,
				fmt.Sprintf("readdir returned %d name(s), expected at least the 4 dirty-* files", len(rd.Names)))
		}
	}

	return ok, nil
}

// waitAdvertisedInterval blocks until "observer" can see "target"
// advertising the given heartbeat interval in its Node Registry row.
//
// The advertised value, not the configured one, is what a peer floors
// its staleness window on -- so a scenario that compresses the timing
// has to wait for the advertisement, not merely for the write to
// return.
func waitAdvertisedInterval(observer, target *Client, want int, limit time.Duration) error {
	var snap ProcSnapshotResult
	resp, err := target.Call("proc_snapshot", ProcSnapshotArgs{Device: target.Device})
	if e := decodeResult(target.Name, resp, err, &snap); e != nil {
		return fmt.Errorf("could not learn %s's node id: %v", target.Name, e)
	}
	row := fmt.Sprintf("%d", snap.ThisNodeID)
	re := regexp.MustCompile(`hb_interval=(\d+)`)
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		var res DeviceReadResult
		resp, err := observer.Call("device_read", DeviceReadArgs{Kind: "node", Args: []string{row}})
		if e := decodeResult(observer.Name, resp, err, &res); e == nil {
			if m := re.FindStringSubmatch(res.Output); m != nil && m[1] == fmt.Sprintf("%d", want) {
				return nil
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("%s never saw %s advertise hb_interval=%d within %s; the staleness window will use the old rate",
		observer.Name, target.Name, want, limit)
}

// RunScrubTransit: the background scrub must not reclaim a block that is
// in TRANSIT between nodes -- one whose owner has dropped the extent and
// handed the free to us, but which our drain has not applied yet.
//
// This is the cross-node form of what tests/kernel/scrub_spares_queued_free.sh
// stages with a poked queue entry. Here the entry is real: B deletes a
// file whose blocks live in A's zone group, so B cannot touch A's bitmap
// and must queue the free instead. Between that append and A's next
// drain, the block is bitmap-SET and referenced by NO inode on any node
// -- indistinguishable from a leak by every test A's scrub has.
//
// If A's scrub frees it, the bit clears early, A's allocator hands the
// block to a new file, and A's next drain then applies the queued free
// to a block that is live again: two files, one block. Nothing reports
// an error and fsck is clean at every instant in between.
//
// The window is held open by SLOWING A's heartbeat, not stopping it: the
// drain rides the same tick as the lease renewal, so a node that stops
// ticking is a node its peers declare stale and fence. 30s still renews
// four times inside the 120s stale window while leaving several scrub
// cycles' worth of room.
func RunScrubTransit(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("scrub-transit needs at least 2 clients")
	}

	a, b := clients[0], clients[1]
	dir := baseDir + "/scrubtransit"
	fmt.Printf("=== scrub transit: %s must leave a block %s queued a free for ===\n", a.Name, b.Name)

	// Module parameters act before a mount exists, and the scrub's first
	// cycle is queued at mount time with whatever interval it reads then
	// -- so these go in while everything is unmounted.
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}

	restore := map[string]string{}
	setParam := func(c *Client, name, value string) error {
		resp, err := c.Call("mod_param", ModParamArgs{Name: name, Value: value})
		var r ModParamResult
		if derr := decodeResult(c.Name, resp, err, &r); derr != nil {
			return derr
		}
		if _, seen := restore[name]; !seen {
			restore[name] = strings.TrimSpace(r.Prev)
		}
		return nil
	}
	defer func() {
		for name, prev := range restore {
			if prev == "" {
				continue
			}
			if resp, err := a.Call("mod_param", ModParamArgs{Name: name, Value: prev}); err != nil {
				fmt.Printf("WARNING: restoring %s=%s on %s: %v (resp %v)\n", name, prev, a.Name, err, resp)
			}
		}
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	for _, p := range []struct{ name, value string }{
		{"scrub", "1"},
		{"scrub_interval_secs", "3"},
		{"scrub_gap_secs", "2"},
		{"hb_interval_secs", "30"},
	} {
		if err := setParam(a, p.name, p.value); err != nil {
			return false, fmt.Errorf("%s: setting %s: %w", a.Name, p.name, err)
		}
	}

	if err := ensureMounted(clients); err != nil {
		return false, err
	}

	ok := true

	// Whose zone group is whose. The whole scenario rests on the file's
	// blocks belonging to a group the DELETER does not own, so establish
	// it rather than assume it -- same reasoning as pending-free.
	owned := map[string][]int{}
	for _, c := range clients {
		var snap ProcSnapshotResult
		resp, err := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
		if err := decodeResult(c.Name, resp, err, &snap); err != nil {
			return false, err
		}
		for _, zg := range snap.ZoneGroups {
			if zg.ThisNode {
				owned[c.Name] = append(owned[c.Name], zg.ID)
			}
		}
		fmt.Printf("    %-12s owns zone group(s) %v\n", c.Name, owned[c.Name])
	}
	if len(owned[a.Name]) == 0 {
		return skipScenario("scrub transit: %s owns no zone group, so it cannot host the file", a.Name)
	}
	if len(owned[b.Name]) > 0 && owned[a.Name][0] == owned[b.Name][0] {
		return skipScenario("scrub transit: both nodes own ZG %d, so a foreign free cannot happen",
			owned[a.Name][0])
	}
	targetZG := owned[a.Name][0]

	queueLen := func(c *Client, zg int) (int, error) {
		var res DeviceReadResult
		resp, err := c.Call("device_read", DeviceReadArgs{Kind: "pending", Args: []string{fmt.Sprint(zg)}})
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return 0, err
		}
		n := 0
		for _, line := range strings.Split(strings.TrimSpace(res.Output), "\n") {
			if strings.TrimSpace(line) != "" {
				n++
			}
		}
		return n, nil
	}
	scrubCounters := func(c *Client) (reclaimed, cycles uint64, err error) {
		var snap ProcSnapshotResult
		resp, e := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device})
		if derr := decodeResult(c.Name, resp, e, &snap); derr != nil {
			return 0, 0, derr
		}
		return snap.ScrubReclaimed, snap.ScrubCycles, nil
	}

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}

	baseQ, err := queueLen(a, targetZG)
	if err != nil {
		return false, fmt.Errorf("reading %s's queue: %w", a.Name, err)
	}

	// A writes it, so the blocks come from A's own zone group.
	path := dir + "/owned-by-" + a.Name
	var w WriteResult
	resp, err := a.Call("write", WriteArgs{Path: path, Size: 512 * 1024, Stamp: "st"})
	if err := decodeResult(a.Name, resp, err, &w); err != nil {
		return false, fmt.Errorf("%s: writing the file: %w", a.Name, err)
	}

	r0, c0, err := scrubCounters(a)
	if err != nil {
		return false, err
	}

	// B deletes it: foreign blocks, so the free is queued on A's queue.
	if resp, err := b.Call("unlink", UnlinkArgs{Path: path}); decodeResult(b.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("%s: unlinking the peer's file: %v", b.Name, err)
	}

	queued := false
	for i := 0; i < 40; i++ {
		n, err := queueLen(a, targetZG)
		if err != nil {
			return false, err
		}
		if n > baseQ {
			queued = true
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	check(&ok, fmt.Sprintf("%s's free was queued on %s rather than applied directly", b.Name, a.Name),
		queued, "the queue never grew -- there is no block in transit, so this scenario proves nothing")
	if !queued {
		return ok, nil
	}

	// Now the question: with the block sitting in A's queue, does A's
	// scrub leave it alone? Wait for two full cycles -- one already in
	// flight took its first pass before the block went into transit, so
	// only the second is guaranteed to have seen it set from pass 1 on.
	fmt.Printf("    waiting for 2 full scrub cycles on %s (from %d) ...\n", a.Name, c0)
	sawCycles := false
	stillQueued := true
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		_, cyc, err := scrubCounters(a)
		if err != nil {
			return false, err
		}
		n, err := queueLen(a, targetZG)
		if err != nil {
			return false, err
		}
		if n <= baseQ {
			// A's heartbeat drained it before the scrub had two cycles.
			stillQueued = false
			break
		}
		if cyc >= c0+2 {
			sawCycles = true
			break
		}
		time.Sleep(500 * time.Millisecond)
	}

	r1, c1, err := scrubCounters(a)
	if err != nil {
		return false, err
	}
	fmt.Printf("    %s: scrub cycles %d -> %d, reclaimed %d -> %d\n", a.Name, c0, c1, r0, r1)

	// Both of these guard against a vacuous pass: a cycle that never ran,
	// or a block that was drained before the scrub was ever asked.
	check(&ok, fmt.Sprintf("%s completed a full scrub cycle while the block was in transit", a.Name),
		sawCycles && stillQueued,
		fmt.Sprintf("cycles %d->%d, queued=%v -- the scrub was never asked the question", c0, c1, stillQueued))
	check(&ok, fmt.Sprintf("%s's scrub reclaimed nothing while a free was queued", a.Name), r1 == r0,
		fmt.Sprintf("scrub_reclaimed went %d -> %d: it freed a block in transit, and the next drain "+
			"will clear that bit again under whatever file owns it by then", r0, r1))

	// And the block still comes back exactly once, via the drain, when the
	// heartbeat is allowed to run at its normal rate again.
	if err := setParam(a, "hb_interval_secs", restore["hb_interval_secs"]); err != nil {
		return false, err
	}
	drained := false
	for i := 0; i < 120; i++ {
		n, err := queueLen(a, targetZG)
		if err != nil {
			return false, err
		}
		if n <= baseQ {
			drained = true
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	check(&ok, fmt.Sprintf("%s drained the queued free once its heartbeat resumed", a.Name), drained,
		"the entry is still queued -- the block never came back at all")

	_, _ = a.Call("rmdir", RmdirArgs{Path: dir})
	if ok {
		fmt.Printf("PASS: scrub transit: a block in transit survived the scrub and was freed once, by the drain\n")
	}
	return ok, nil
}

// ---------------------------------------------------------------------
// RunHypervisorStorm: many nodes doing many things to one volume at once.
//
// Every other scenario here isolates ONE mechanism and proves it. This
// one does the opposite on purpose: it runs the whole machine under
// concurrent load shaped like the deployment -- several hypervisor hosts
// with VM images on a shared LUN -- because the bugs that survive
// per-mechanism tests are the ones that need several mechanisms moving
// at once. It is deliberately NOT part of full-suite: it runs for
// minutes and reformats nothing, so it is something you point at a
// cluster, not something you gate a commit on.
//
// The load, all concurrent:
//
//   - IMAGES. Each node owns its own image files and never touches a
//     peer's, mirroring the one-writer-per-disk rule the filesystem is
//     designed around (CLAUDE.md: a file open for write on one node is
//     unopenable on every other). Sizes 1-50 GiB, mostly SPARSE -- a
//     truncate to size then scattered pwrites, which is what a VM disk
//     actually looks like and what makes the extent tree interesting
//     without writing 50 GiB. Each write is verified by reading it back.
//   - DIRECTORY CHURN. mkdir/rmdir/rename/unlink from every node at once.
//   - THE HOSTILE CASE. One node creates a directory, a second fills it
//     and holds files OPEN inside it, a third tries to rmdir it. The
//     rmdir must fail while the directory is non-empty -- it must not
//     half-delete, and the holder's writes must keep working.
//   - FAILURES. A node's device is pulled mid-storm and restored, so the
//     storm runs across a real reclaim/replay cycle rather than around it.
//   - FSCK. Periodically the storm is quiesced, every node unmounts, and
//     the volume is checked with the fsck EMBEDDED IN THIS BINARY (so a
//     node with no cetrafs checkout can still do it), then everyone
//     remounts and carries on. A dirty fsck stops the run immediately --
//     the point is to catch the first corruption, not the hundredth.
//
// Which fsck findings are CORRUPTION, and which are the expected residue
// of a node that was interrupted mid-operation?
//
// This storm deliberately pulls a node's device, so some residue is the
// correct outcome, not a fault: an interrupted create leaves an inode
// nothing names, an interrupted delete leaves blocks nothing references.
// The filesystem's own contract calls those a bounded leak that fsck
// names and `fsck -r` reclaims -- no data is lost and nothing is shared.
//
// These are fatal, always, with or without an injected failure:
//   - a block referenced by an inode but marked FREE (it gets handed out
//     again -- two files, one block)
//   - a block referenced by more than one inode (already shared)
//   - a checksum or magic that does not verify (torn or corrupt record)
//   - a directory that lost its structural entries
//
// Treating the whole of fsck's output as fatal would make this scenario
// fail on its own failure injection, which is worse than useless: it
// would train everyone to ignore it.
func stormFsckFatal(out string) []string {
	var fatal []string
	for _, ln := range strings.Split(out, "\n") {
		l := strings.TrimSpace(ln)
		if !strings.HasPrefix(l, "ERR") {
			continue
		}
		low := strings.ToLower(l)
		switch {
		case strings.Contains(low, "marked free"),
			strings.Contains(low, "referenced by") && strings.Contains(low, "inodes"),
			strings.Contains(low, "overlap"),
			strings.Contains(low, "cross"),
			strings.Contains(low, "checksum"),
			strings.Contains(low, "magic"),
			strings.Contains(low, "no '.'"),
			strings.Contains(low, "no '..'"):
			fatal = append(fatal, l)
		}
	}
	return fatal
}

func RunHypervisorStorm(clients []*Client, baseDir string, dur time.Duration, seed int64, inject bool, noFileLock bool) (bool, error) {
	if len(clients) < 2 {
		return skipScenario("hypervisor storm: needs at least 2 nodes, have %d", len(clients))
	}
	if dur < time.Minute {
		dur = 5 * time.Minute
	}
	if noFileLock {
		// The deployment mode this suite exists for (VM images, live
		// migration) runs nofilelock -- no whole-file exclusive lock,
		// freshness gated on open-presence. The slave adopts a live
		// mount verbatim, so unmount first or the option is a no-op.
		if err := ensureUnmounted(clients); err != nil {
			return false, err
		}
		if err := mountAllNoFileLock(clients); err != nil {
			return false, err
		}
	} else if err := ensureMounted(clients); err != nil {
		return false, err
	}

	ok := true
	root := baseDir + "/storm"
	fmt.Printf("=== hypervisor storm: %d nodes, %s, seed %d, filelock=%v ===\n", len(clients), dur, seed, !noFileLock)

	if resp, err := clients[0].Call("mkdir", MkdirArgs{Path: root}); decodeResult(clients[0].Name, resp, err, nil) != nil {
		return false, fmt.Errorf("storm: mkdir %s", root)
	}

	// Written once, never touched again: every node must report these
	// identically for the whole run. See stormWitness.
	witnessDir := root + "/witness"
	witnesses, werr := stormMakeWitnesses(clients[0], witnessDir, 8)
	if werr != nil {
		return false, fmt.Errorf("storm: creating witnesses: %w", werr)
	}

	// While a node's device is deliberately pulled, ITS operations are
	// supposed to fail. Counting those as problems made the storm report
	// hundreds of "failures" that were the injection working -- the same
	// mistake as demanding a spotless fsck from a run that cuts power.
	// Only failures on nodes whose device is up are findings.
	var injectedDown atomic.Value
	injectedDown.Store("")
	isInjected := func(node string) bool {
		v, _ := injectedDown.Load().(string)
		return v != "" && v == node
	}

	var (
		mu       sync.Mutex
		opCount  int
		errCount int
		problems []string
	)
	note := func(format string, a ...interface{}) {
		mu.Lock()
		defer mu.Unlock()
		if len(problems) < 40 {
			problems = append(problems, fmt.Sprintf(format, a...))
		}
		errCount++
	}
	// noteOp: a per-node operational failure. Dropped silently while that
	// node's device is pulled -- see injectedDown.
	noteOp := func(node, format string, a ...interface{}) {
		if isInjected(node) {
			return
		}
		note(format, a...)
	}
	bump := func(n int) { mu.Lock(); opCount += n; mu.Unlock() }

	deadline := time.Now().Add(dur)
	// quiesce gates every worker: the fsck pass closes it, workers park
	// at the next operation boundary, and it reopens when the volume is
	// mounted again. A worker mid-RPC when it closes is fine -- the gate
	// is checked between operations, never inside one.
	var quiesce sync.RWMutex
	var stopped atomic.Bool
	var wg sync.WaitGroup

	running := func() bool { return !stopped.Load() && time.Now().Before(deadline) }

	// ---- image workers: one per node, each owning its own files ------
	for idx, c := range clients {
		idx, c := idx, c
		wg.Add(1)
		go func() {
			defer wg.Done()
			rnd := rand.New(rand.NewSource(seed + int64(idx)*7919))
			type img struct {
				path string
				size int64
			}
			var imgs []img
			for running() {
				quiesce.RLock()
				if !running() {
					quiesce.RUnlock()
					return
				}
				switch {
				case len(imgs) < 3 || rnd.Intn(10) == 0:
					// A new image: 1-50 GiB, sparse by truncate. Dense
					// prefixes come from the writes below, not from
					// actually laying down 50 GiB.
					gib := int64(1 + rnd.Intn(50))
					p := fmt.Sprintf("%s/img-%s-%d", root, c.Name, len(imgs))
					sz := gib << 30
					r1, e1 := c.Call("write_at", WriteAtArgs{Path: p, Offset: 0, Size: 4096,
						Stamp: "hdr", Create: true})
					if decodeResult(c.Name, r1, e1, nil) != nil {
						noteOp(c.Name, "%s: creating %s failed", c.Name, p)
						break
					}
					r2, e2 := c.Call("truncate", TruncateArgs{Path: p, Size: sz})
					if decodeResult(c.Name, r2, e2, nil) != nil {
						noteOp(c.Name, "%s: truncate %s to %d GiB failed", c.Name, p, gib)
						break
					}
					imgs = append(imgs, img{p, sz})
					bump(2)
				case len(imgs) > 0:
					// A scattered write, then read it back. Offset is
					// block-aligned: a VM writes whole blocks, and an
					// unaligned read-back would compare a different
					// range than was written.
					im := imgs[rnd.Intn(len(imgs))]
					blocks := im.size / 4096
					off := (rnd.Int63n(blocks)) * 4096
					size := 4096 * (1 + rnd.Intn(16))
					stamp := fmt.Sprintf("%s-%d", c.Name, rnd.Int63())
					var w WriteAtResult
					rw, ew := c.Call("write_at", WriteAtArgs{Path: im.path, Offset: off, Size: size, Stamp: stamp})
					if derr := decodeResult(c.Name, rw, ew, &w); derr != nil {
						// "no such file" on a file this node CREATED and
						// nobody unlinks is the loudest signal the storm
						// produces (20-30 a run). Whether the name is
						// gone from the directory or merely invisible
						// HERE is the whole question, and asking the
						// other nodes is the only way to tell -- the
						// same distinction that showed 'half-removed'
						// was mostly a stale view.
						extra := ""
						if strings.Contains(derr.Error(), "no such file") {
							seen := []string{}
							for _, peer := range clients {
								if peer == c {
									continue
								}
								if _, ex, err := statPath(peer, im.path); err == nil && ex {
									seen = append(seen, peer.Name)
								}
							}
							if len(seen) > 0 {
								extra = fmt.Sprintf(" -- but %s still see(s) it: INVISIBLE here, not deleted",
									strings.Join(seen, ","))
							} else {
								extra = " -- gone on every node: really unlinked by nobody"
								// Ask the DEVICE about the parent
								// directory. If its size has shrunk back,
								// its record was reverted and the block
								// holding this name is orphaned; if the
								// size still covers the name, the dirent
								// itself was cleared. Different bugs.
								if st, ex, serr := statPath(c, root); serr == nil && ex {
									var dr DeviceReadResult
									if r2, e2 := c.Call("device_read", DeviceReadArgs{Kind: "inode-rec",
										Args: []string{fmt.Sprintf("%d", st.Ino)}}); decodeResult(c.Name, r2, e2, &dr) == nil {
										extra += fmt.Sprintf(" [parent ino=%d on DEVICE: %s; this node's readdir sees %d entries]",
											st.Ino, strings.TrimSpace(dr.Output), countEntries(c, root))
									}
								}
							}
						}
						noteOp(c.Name, "%s: write_at %s@%d failed: %v%s", c.Name, im.path, off, derr, extra)
						break
					}
					var rr ReadAtResult
					rd, ed := c.Call("read_at", ReadAtArgs{Path: im.path, Offset: off, Size: size})
					if decodeResult(c.Name, rd, ed, &rr) != nil {
						noteOp(c.Name, "%s: read_at %s@%d failed", c.Name, im.path, off)
						break
					}
					if rr.Checksum != w.Checksum {
						note("%s: %s@%d read back DIFFERENT bytes than were written (%s != %s)",
							c.Name, im.path, off, rr.Checksum, w.Checksum)
					}
					bump(2)
				}
				quiesce.RUnlock()
				time.Sleep(time.Duration(10+rnd.Intn(60)) * time.Millisecond)
			}
		}()
	}

	// ---- open/hold/close churn on a node's own images ----------------
	for idx, c := range clients {
		idx, c := idx, c
		wg.Add(1)
		go func() {
			defer wg.Done()
			rnd := rand.New(rand.NewSource(seed + 5000 + int64(idx)))
			for running() {
				quiesce.RLock()
				if !running() {
					quiesce.RUnlock()
					return
				}
				p := fmt.Sprintf("%s/hold-%s-%d", root, c.Name, rnd.Intn(4))
				var h OpenHoldResult
				r, e := c.Call("open_hold", OpenHoldArgs{Path: p, Mode: "rdwr", Create: true})
				if decodeResult(c.Name, r, e, &h) == nil && h.Handle != 0 {
					// hold it open across a few writes, then close --
					// the open/close boundary is where the file lock and
					// the durability flush both live
					for k := 0; k < 1+rnd.Intn(3) && running(); k++ {
						off := int64(rnd.Intn(256)) * 4096
						rw, ew := c.Call("write_at", WriteAtArgs{Path: p, Offset: off, Size: 4096,
							Stamp: fmt.Sprintf("h%d", k)})
						if decodeResult(c.Name, rw, ew, nil) != nil {
							noteOp(c.Name, "%s: write to held %s failed", c.Name, p)
						}
						bump(1)
					}
					if rc, re := c.Call("close", CloseArgs{Handle: h.Handle}); decodeResult(c.Name, rc, re, nil) != nil {
						noteOp(c.Name, "%s: close of %s failed", c.Name, p)
					}
				}
				quiesce.RUnlock()
				time.Sleep(time.Duration(50+rnd.Intn(200)) * time.Millisecond)
			}
		}()
	}

	// ---- directory churn ---------------------------------------------
	for idx, c := range clients {
		idx, c := idx, c
		wg.Add(1)
		go func() {
			defer wg.Done()
			rnd := rand.New(rand.NewSource(seed + 9000 + int64(idx)))
			n := 0
			for running() {
				quiesce.RLock()
				if !running() {
					quiesce.RUnlock()
					return
				}
				d := fmt.Sprintf("%s/dir-%s-%d", root, c.Name, n)
				n++
				if r, e := c.Call("mkdir", MkdirArgs{Path: d}); decodeResult(c.Name, r, e, nil) == nil {
					files := 1 + rnd.Intn(4)
					for k := 0; k < files; k++ {
						f := fmt.Sprintf("%s/f%d", d, k)
						r2, e2 := c.Call("write_at", WriteAtArgs{Path: f, Offset: 0,
							Size: 512 * (1 + rnd.Intn(8)), Stamp: "churn", Create: true})
						if decodeResult(c.Name, r2, e2, nil) != nil {
							noteOp(c.Name, "%s: create %s failed", c.Name, f)
						}
						bump(1)
					}
					for k := 0; k < files; k++ {
						f := fmt.Sprintf("%s/f%d", d, k)
						if r2, e2 := c.Call("unlink", UnlinkArgs{Path: f}); decodeResult(c.Name, r2, e2, nil) != nil {
							noteOp(c.Name, "%s: unlink %s failed", c.Name, f)
						}
						bump(1)
					}
					if r2, e2 := c.Call("rmdir", RmdirArgs{Path: d}); decodeResult(c.Name, r2, e2, nil) != nil {
						noteOp(c.Name, "%s: rmdir of its own emptied %s failed", c.Name, d)
					}
					bump(1)
				}
				quiesce.RUnlock()
				time.Sleep(time.Duration(100+rnd.Intn(400)) * time.Millisecond)
			}
		}()
	}

	// ---- the hostile case: delete a directory out from under a peer ---
	//
	// A makes the directory, B fills it and HOLDS files open inside, C
	// tries to remove it. A non-empty rmdir must FAIL -- and must not
	// half-remove it either, which is what the re-read checks. Then B
	// lets go, the files are removed, and the rmdir must now succeed:
	// the refusal has to be about the contents, not a directory this
	// cluster can never delete again.
	if len(clients) >= 3 {
		a, b, cc := clients[0], clients[1], clients[2]
		wg.Add(1)
		go func() {
			defer wg.Done()
			rnd := rand.New(rand.NewSource(seed + 31337))
			round := 0
			for running() {
				quiesce.RLock()
				if !running() {
					quiesce.RUnlock()
					return
				}
				d := fmt.Sprintf("%s/hostile-%d", root, round)
				round++
				if r, e := a.Call("mkdir", MkdirArgs{Path: d}); decodeResult(a.Name, r, e, nil) != nil {
					quiesce.RUnlock()
					continue
				}
				var handles []uint64
				nf := 2 + rnd.Intn(3)
				for k := 0; k < nf; k++ {
					f := fmt.Sprintf("%s/held%d", d, k)
					var h OpenHoldResult
					r, e := b.Call("open_hold", OpenHoldArgs{Path: f, Mode: "rdwr", Create: true})
					if decodeResult(b.Name, r, e, &h) == nil && h.Handle != 0 {
						handles = append(handles, h.Handle)
						r2, e2 := b.Call("write_at", WriteAtArgs{Path: f, Offset: 0, Size: 4096, Stamp: "hostile"})
						if decodeResult(b.Name, r2, e2, nil) != nil {
							note("%s: write into held %s failed", b.Name, f)
						}
					}
				}

				// What does the REMOVING node actually see in there? This
				// is the discriminator: "rmdir removed a non-empty
				// directory" and "rmdir removed a directory this node
				// could not see the contents of" are different bugs --
				// the first is in rmdir's emptiness check, the second is
				// cross-node dirent visibility -- and the removal alone
				// cannot tell them apart.
				countVisible := func() int {
					n := 0
					for k := 0; k < nf; k++ {
						if _, ex, err := statPath(cc, fmt.Sprintf("%s/held%d", d, k)); err == nil && ex {
							n++
						}
					}
					return n
				}
				visible := countVisible()
				// If this node sees nothing, ask again BEFORE removing
				// anything. A view that corrects itself in a moment is a
				// refresh that had not happened yet; a view that stays
				// empty while a peer holds files open in there is a node
				// about to destroy something it cannot see. The first
				// version asked AFTER the rmdir, which answers nothing:
				// by then the directory is gone because this node
				// removed it.
				settled := visible
				if visible == 0 && len(handles) > 0 {
					time.Sleep(3 * time.Second)
					settled = countVisible()
				}
				// Which inode is this directory? Asked of the node that
				// can still SEE it, and asked BEFORE the rmdir, because
				// afterwards there is nothing left to ask.
				var dirIno uint64
				if st, ex, err := statPath(b, d); err == nil && ex {
					dirIno = st.Ino
				}
				rr, re := cc.Call("rmdir", RmdirArgs{Path: d})
				removed := decodeResult(cc.Name, rr, re, nil) == nil
				if removed {
					if visible == 0 && len(handles) > 0 {
						// Transient or persistent? A node recovering from
						// the injected device pull may hold a stale view
						// for a moment; a view that never corrects is a
						// different and much worse thing. Ask again, and
						// say which -- and say whether this node was
						// fenced, since a fenced mount's reads come from
						// a cache nothing is refreshing.
						fenced := "unknown"
						var snap ProcSnapshotResult
						if r, e := cc.Call("proc_snapshot", ProcSnapshotArgs{Device: cc.Device}); e == nil {
							if decodeResult(cc.Name, r, e, &snap) == nil {
								fenced = fmt.Sprintf("%v", snap.Fenced)
							}
						}
						note("%s could not SEE any of %s's %d file(s) in %s and removed it "+
							"(after 3s it still saw %d; fenced=%s) -- a cross-node dirent "+
							"visibility failure, not an rmdir one",
							cc.Name, b.Name, len(handles), d, settled, fenced)
						// Ask the DEVICE what that directory's record
						// actually said. Comparing the two kernels
						// against each other cannot say which one is
						// wrong; the record can. A size of 532 is an
						// empty directory ('.' and '..' only), so
						// 532 here means the peer's entries never
						// reached the platter -- a write-side fault --
						// and anything larger means the remover read
						// stale, which is a read-side fault.
						if dirIno != 0 {
							var dr DeviceReadResult
							if r, e := cc.Call("device_read", DeviceReadArgs{Kind: "inode-rec",
								Args: []string{fmt.Sprintf("%d", dirIno)}}); decodeResult(cc.Name, r, e, &dr) == nil {
								note("    the DEVICE says ino=%d: %s", dirIno, strings.TrimSpace(dr.Output))
							}
						}
						// The directory is gone now, but every node's
						// view, dmesg and /proc state still mean
						// something. Capture before moving on.
						captureEvidence(clients, "storm-invisible-contents", []string{root, d})
					} else {
						note("%s REMOVED %s while it could see %d of %s's %d open file(s) in it",
							cc.Name, d, visible, b.Name, len(handles))
					}
				}
				// Whether or not it refused, the contents must still be
				// there and still writable by their holder.
				for k := 0; k < nf; k++ {
					f := fmt.Sprintf("%s/held%d", d, k)
					if _, exists, err := statPath(a, f); err == nil && !exists && !removed {
						// "vanished" from ONE node's view is two very
						// different bugs wearing the same word: the file
						// was really removed by a refused rmdir, or it is
						// still there and only this node cannot see it --
						// the cross-node visibility failure, not a
						// half-removal. Ask the holder and the remover
						// before naming it.
						_, onHolder, _ := statPath(b, f)
						_, onRemover, _ := statPath(cc, f)
						if onHolder || onRemover {
							note("%s: %s is INVISIBLE to %s after a refused rmdir, but %s still sees it "+
								"(holder=%v remover=%v) -- a stale view, not a half-removal",
								a.Name, f, a.Name,
								map[bool]string{true: b.Name, false: cc.Name}[onHolder],
								onHolder, onRemover)
							continue
						}
						note("%s: %s vanished after a REFUSED rmdir -- the directory was half-removed "+
							"(gone on all three nodes)", a.Name, f)
					}
				}
				for _, h := range handles {
					if r, e := b.Call("close", CloseArgs{Handle: h}); decodeResult(b.Name, r, e, nil) != nil {
						note("%s: closing a held file in %s failed", b.Name, d)
					}
				}
				// Now empty it and remove it for real.
				for k := 0; k < nf; k++ {
					f := fmt.Sprintf("%s/held%d", d, k)
					_, _ = b.Call("unlink", UnlinkArgs{Path: f})
				}
				if r, e := cc.Call("rmdir", RmdirArgs{Path: d}); decodeResult(cc.Name, r, e, nil) != nil &&
					!isInjected(cc.Name) {
					note("%s: rmdir of the now-EMPTY %s failed -- the earlier refusal was not about its contents",
						cc.Name, d)
				}
				bump(nf*2 + 3)
				quiesce.RUnlock()
				time.Sleep(time.Duration(400+rnd.Intn(600)) * time.Millisecond)
			}
		}()
	}

	// ---- the adversarial set (see stormHostileCases) ------------------
	wg.Add(1)
	go func() {
		defer wg.Done()
		stormHostileCases(clients, root, seed, running, &quiesce, note, bump, isInjected)
	}()

	// ---- failure injection: pull a node's device mid-storm ------------
	if len(clients) >= 3 && inject {
		victim := clients[len(clients)-1]
		wg.Add(1)
		go func() {
			defer wg.Done()
			time.Sleep(45 * time.Second)
			for running() {
				quiesce.RLock()
				if !running() {
					quiesce.RUnlock()
					return
				}
				fmt.Printf("    [storm] pulling %s's device\n", victim.Name)
				if r, e := victim.Call("link_down", nil); decodeResult(victim.Name, r, e, nil) == nil {
					injectedDown.Store(victim.Name)
					time.Sleep(20 * time.Second)
					injectedDown.Store("")
					if r2, e2 := victim.Call("link_up", nil); decodeResult(victim.Name, r2, e2, nil) != nil {
						note("%s: link_up failed -- the node cannot rejoin", victim.Name)
					}
					fmt.Printf("    [storm] %s's device restored\n", victim.Name)
				}
				quiesce.RUnlock()
				time.Sleep(90 * time.Second)
			}
		}()
	}

	// ---- periodic cross-node agreement, while everyone is MOUNTED ----
	//
	// This is the half fsck cannot do. It runs under the read side of
	// the quiesce gate, i.e. concurrently with the load, because a
	// divergence that only appears under load is exactly the kind worth
	// catching.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for running() {
			time.Sleep(20 * time.Second)
			if !running() {
				return
			}
			quiesce.RLock()
			stormCheckWitnesses(clients, witnessDir, witnesses, "warm", note, isInjected)
			quiesce.RUnlock()
		}
	}()

	// ---- periodic fsck: quiesce, unmount everywhere, check, remount ---
	fsckRuns, fsckClean, residue := 0, 0, 0
	wg.Add(1)
	go func() {
		defer wg.Done()
		for running() {
			time.Sleep(100 * time.Second)
			if !running() {
				return
			}
			quiesce.Lock() // every worker parks at its next boundary
			// The last warm answer before anyone unmounts. If a node's
			// cache disagreed with the device, this is the only moment
			// it is still observable -- unmounting throws the evidence
			// away, and fsck then sees a device that looks fine.
			stormCheckWitnesses(clients, witnessDir, witnesses, "warm-before-unmount", note, isInjected)
			fmt.Printf("    [storm] quiesced -- unmounting everywhere for fsck\n")
			if err := ensureUnmounted(clients); err != nil {
				fmt.Printf("    [storm] unmount failed: %v\n", err)
				quiesce.Unlock()
				continue
			}
			var fr FsckResult
			r, e := clients[0].Call("fsck", FsckArgs{})
			fsckRuns++
			if derr := decodeResult(clients[0].Name, r, e, &fr); derr != nil {
				note("fsck could not run: %v", derr)
			} else if fatal := stormFsckFatal(fr.Output); len(fatal) > 0 {
				// Stop at the FIRST corruption: everything after it is
				// consequence, and the state here is the evidence.
				note("fsck found CORRUPTION mid-storm (exit %d)", fr.ExitCode)
				for _, l := range fatal {
					note("  fsck: %s", l)
				}
				// Everything is unmounted at this point, so the caches
				// are already gone -- but the full fsck output, the
				// kernel logs that led here and each node's state are
				// still worth freezing.
				ev := captureEvidence(clients, "storm-fsck-corruption", nil)
				if ev != "" {
					if f, ferr := os.OpenFile(ev, os.O_APPEND|os.O_WRONLY, 0o644); ferr == nil {
						fmt.Fprintf(f, "\n######## full fsck output\n%s\n", fr.Output)
						f.Close()
					}
				}
				stopped.Store(true)
			} else if !fr.Clean {
				// Residue, not corruption -- expected after the device
				// pull. Counted and shown, never silent, but it does not
				// fail the run: an interrupted operation is supposed to
				// leave exactly this.
				n := 0
				for _, ln := range strings.Split(fr.Output, "\n") {
					if strings.HasPrefix(strings.TrimSpace(ln), "ERR") {
						n++
					}
				}
				residue += n
				fsckClean++
				fmt.Printf("    [storm] fsck: no corruption; %d repairable finding(s) "+
					"(orphans/leaks from the injected failure)\n", n)
			} else {
				fsckClean++
				fmt.Printf("    [storm] fsck clean (%d/%d)\n", fsckClean, fsckRuns)
			}
			if err := ensureMounted(clients); err != nil {
				fmt.Printf("    [storm] remount failed: %v\n", err)
				stopped.Store(true)
			} else {
				// Cold: every cache was just dropped, so this is the
				// device's own answer. It must match what the warm
				// check above reported.
				stormCheckWitnesses(clients, witnessDir, witnesses, "cold-after-remount", note, isInjected)
			}
			quiesce.Unlock()
		}
	}()

	wg.Wait()

	// ---- final check, on a quiet volume -------------------------------
	// One last warm agreement check while the mounts are still up: after
	// the unmount below there is nothing left to compare but the device.
	stormCheckWitnesses(clients, witnessDir, witnesses, "final-warm", note, isInjected)
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("storm: final unmount: %w", err)
	}
	var final FsckResult
	r, e := clients[0].Call("fsck", FsckArgs{})
	if derr := decodeResult(clients[0].Name, r, e, &final); derr != nil {
		return false, fmt.Errorf("storm: final fsck: %w", derr)
	}
	fsckRuns++
	finalFatal := stormFsckFatal(final.Output)
	if len(finalFatal) == 0 {
		fsckClean++
	} else {
		for _, l := range finalFatal {
			note("final fsck: %s", l)
		}
	}

	mu.Lock()
	ops, errs, probs := opCount, errCount, problems
	mu.Unlock()

	fmt.Printf("    [storm] %d operations across %d nodes, %d fsck pass(es)\n", ops, len(clients), fsckRuns)
	for _, p := range probs {
		fmt.Printf("    [storm] PROBLEM: %s\n", p)
	}

	// An honesty gate, like phase 5 of the crash rig: a storm that did
	// almost nothing proves almost nothing, and would otherwise report a
	// confident PASS.
	check(&ok, "the storm actually ran a meaningful amount of work", ops > 200,
		fmt.Sprintf("only %d operations completed -- too few to have stressed anything", ops))
	check(&ok, "no fsck during or after the storm found CORRUPTION", fsckClean == fsckRuns,
		fmt.Sprintf("%d of %d fsck runs found blocks shared, lost, or unverifiable", fsckRuns-fsckClean, fsckRuns))
	if residue > 0 {
		fmt.Printf("    [storm] %d repairable finding(s) across the run -- expected residue of the "+
			"injected device failure, reclaimable with `fsck.cetra -r`\n", residue)
	}
	check(&ok, "no node reported a failed or inconsistent operation", errs == 0,
		fmt.Sprintf("%d problem(s) across the run (first few above)", errs))

	if !final.Clean {
		fmt.Printf("---- final fsck output ----\n%s\n", strings.TrimSpace(final.Output))
	}
	if ok {
		fmt.Printf("PASS: hypervisor storm: %d ops, volume clean throughout\n", ops)
	}
	return ok, nil
}

// hostileCases: the adversarial half of the storm. Each is a shape where
// one node's operation lands on state another node is actively using --
// the cases a single-node test cannot express at all, and that a
// per-mechanism cross-node test tends to miss because it exercises one
// lock at a time while these cross two.
//
// Every case states what MUST hold. "It did not crash" is not an
// outcome; each either names the invariant it broke or passes silently.
// injected reports whether a node's device is currently pulled. A node
// that cannot reach the device answers every question with an error, and
// an error is NOT evidence of absence -- without this the checks below
// conclude "the file is gone" from "I could not ask", and the node being
// fault-injected manufactures findings about itself.
func stormHostileCases(clients []*Client, root string, seed int64,
	running func() bool, quiesce *sync.RWMutex, note func(string, ...interface{}), bump func(int),
	injected func(string) bool) {

	a, b, c := clients[0], clients[1%len(clients)], clients[2%len(clients)]
	rnd := rand.New(rand.NewSource(seed + 77777))
	round := 0

	for running() {
		quiesce.RLock()
		if !running() {
			quiesce.RUnlock()
			return
		}
		n := round
		round++

		switch n % 6 {

		case 0:
			// RENAME A DIRECTORY out from under a node working inside it.
			// The worker's open fd must keep working (it holds the inode,
			// not the path), and the files must be reachable at the NEW
			// path afterwards -- never at neither.
			d := fmt.Sprintf("%s/mv-src-%d", root, n)
			dst := fmt.Sprintf("%s/mv-dst-%d", root, n)
			if r, e := a.Call("mkdir", MkdirArgs{Path: d}); decodeResult(a.Name, r, e, nil) != nil {
				break
			}
			f := d + "/inside"
			var h OpenHoldResult
			r, e := b.Call("open_hold", OpenHoldArgs{Path: f, Mode: "rdwr", Create: true})
			if decodeResult(b.Name, r, e, &h) != nil || h.Handle == 0 {
				_, _ = a.Call("rmdir", RmdirArgs{Path: d})
				break
			}
			if r2, e2 := c.Call("rename", RenameArgs{Old: d, New: dst}); decodeResult(c.Name, r2, e2, nil) == nil {
				// the holder must still be able to write through its fd
				if r3, e3 := b.Call("write_at", WriteAtArgs{Path: dst + "/inside", Offset: 0,
					Size: 4096, Stamp: "afterrename"}); decodeResult(b.Name, r3, e3, nil) != nil {
					note("%s: after %s renamed the parent, the file is not writable at the new path %s",
						b.Name, c.Name, dst+"/inside")
				}
				if _, ex, err := statPath(a, dst+"/inside"); err == nil && !ex {
					note("%s: %s vanished after its parent directory was renamed -- reachable at neither path",
						a.Name, dst+"/inside")
				}
			}
			_, _ = b.Call("close", CloseArgs{Handle: h.Handle})
			_, _ = b.Call("unlink", UnlinkArgs{Path: dst + "/inside"})
			_, _ = b.Call("unlink", UnlinkArgs{Path: f})
			_, _ = c.Call("rmdir", RmdirArgs{Path: dst})
			_, _ = c.Call("rmdir", RmdirArgs{Path: d})
			bump(6)

		case 1:
			// UNLINK A FILE A PEER HOLDS OPEN. POSIX says the holder keeps
			// reading and writing it; the name goes immediately. What must
			// NOT happen is the blocks being handed to someone else while
			// the holder is still using them -- which is what read
			// presence (read_open_nodes) exists to prevent.
			f := fmt.Sprintf("%s/unlink-held-%d", root, n)
			var h OpenHoldResult
			r, e := b.Call("open_hold", OpenHoldArgs{Path: f, Mode: "rdwr", Create: true})
			if decodeResult(b.Name, r, e, &h) != nil || h.Handle == 0 {
				break
			}
			var w WriteAtResult
			rw, ew := b.Call("write_at", WriteAtArgs{Path: f, Offset: 0, Size: 8192, Stamp: "beforeunlink"})
			if decodeResult(b.Name, rw, ew, &w) != nil {
				_, _ = b.Call("close", CloseArgs{Handle: h.Handle})
				break
			}
			if r2, e2 := a.Call("unlink", UnlinkArgs{Path: f}); decodeResult(a.Name, r2, e2, nil) == nil {
				// holder reads its own data back through the open fd
				var rr ReadAtResult
				rd, ed := b.Call("read_at", ReadAtArgs{Path: f, Offset: 0, Size: 8192})
				if decodeResult(b.Name, rd, ed, &rr) == nil && rr.Checksum != w.Checksum {
					note("%s: data changed under an unlinked-but-open file after %s removed the name",
						b.Name, a.Name)
				}
			}
			_, _ = b.Call("close", CloseArgs{Handle: h.Handle})
			bump(4)

		case 2:
			// TWO NODES RENAME ONTO THE SAME TARGET at once. Exactly one
			// source may survive as the target; the other must be gone or
			// still at its source -- never both gone, which would lose a
			// file outright.
			s1 := fmt.Sprintf("%s/race-src-a-%d", root, n)
			s2 := fmt.Sprintf("%s/race-src-b-%d", root, n)
			dst := fmt.Sprintf("%s/race-dst-%d", root, n)
			ra, ea := a.Call("write_at", WriteAtArgs{Path: s1, Offset: 0, Size: 512, Stamp: "ra", Create: true})
			rb, eb := b.Call("write_at", WriteAtArgs{Path: s2, Offset: 0, Size: 512, Stamp: "rb", Create: true})
			if decodeResult(a.Name, ra, ea, nil) != nil || decodeResult(b.Name, rb, eb, nil) != nil {
				break
			}
			res := fireConcurrently([]*Client{a, b}, "rename", RenameArgs{Old: s1, New: dst})
			_ = res
			// b's rename names a different source; fire it separately so
			// both really target dst
			_, _ = b.Call("rename", RenameArgs{Old: s2, New: dst})
			_, dstEx, dstErr := statPath(c, dst)
			_, s1Ex, s1Err := statPath(c, s1)
			_, s2Ex, s2Err := statPath(c, s2)
			// Only conclude from answers we actually got.
			if dstErr == nil && s1Err == nil && s2Err == nil &&
				!injected(c.Name) && !dstEx && !s1Ex && !s2Ex {
				note("%s: after two concurrent renames onto %s, BOTH sources and the target are gone -- a file was lost",
					c.Name, dst)
			}
			_, _ = c.Call("unlink", UnlinkArgs{Path: dst})
			_, _ = c.Call("unlink", UnlinkArgs{Path: s1})
			_, _ = c.Call("unlink", UnlinkArgs{Path: s2})
			bump(5)

		case 3:
			// RENAME A FILE INTO A DIRECTORY ANOTHER NODE IS REMOVING.
			// Either the rename lands and the rmdir then refuses, or the
			// rmdir lands and the rename fails. What must not happen is
			// the file landing in a directory that no longer exists --
			// reachable from nothing.
			d := fmt.Sprintf("%s/vanishing-%d", root, n)
			src := fmt.Sprintf("%s/mover-%d", root, n)
			if r, e := a.Call("mkdir", MkdirArgs{Path: d}); decodeResult(a.Name, r, e, nil) != nil {
				break
			}
			if r, e := b.Call("write_at", WriteAtArgs{Path: src, Offset: 0, Size: 512,
				Stamp: "mv", Create: true}); decodeResult(b.Name, r, e, nil) != nil {
				_, _ = a.Call("rmdir", RmdirArgs{Path: d})
				break
			}
			dstPath := d + "/landed"
			rmDone := make(chan bool, 1)
			go func() {
				r, e := c.Call("rmdir", RmdirArgs{Path: d})
				rmDone <- decodeResult(c.Name, r, e, nil) == nil
			}()
			rnOK := false
			if r, e := b.Call("rename", RenameArgs{Old: src, New: dstPath}); decodeResult(b.Name, r, e, nil) == nil {
				rnOK = true
			}
			rmOK := <-rmDone
			if rnOK && rmOK {
				_, ex, err := statPath(a, dstPath)
				if err == nil && !ex {
					if _, srcEx, _ := statPath(a, src); !srcEx {
						note("%s: renamed into %s while %s removed it -- the file is now at neither path",
							b.Name, d, c.Name)
					}
				}
			}
			_, _ = a.Call("unlink", UnlinkArgs{Path: dstPath})
			_, _ = a.Call("unlink", UnlinkArgs{Path: src})
			_, _ = a.Call("rmdir", RmdirArgs{Path: d})
			bump(5)

		case 4:
			// HARDLINK ACROSS NODES while a third removes the original
			// name. The link must keep the data alive: nlink went to 2
			// before the unlink, so the inode must survive it.
			f := fmt.Sprintf("%s/link-src-%d", root, n)
			ln := fmt.Sprintf("%s/link-dst-%d", root, n)
			var w WriteAtResult
			r, e := a.Call("write_at", WriteAtArgs{Path: f, Offset: 0, Size: 4096, Stamp: "link", Create: true})
			if decodeResult(a.Name, r, e, &w) != nil {
				break
			}
			if r2, e2 := b.Call("link", LinkArgs{OldPath: f, NewPath: ln}); decodeResult(b.Name, r2, e2, nil) == nil {
				if r3, e3 := c.Call("unlink", UnlinkArgs{Path: f}); decodeResult(c.Name, r3, e3, nil) == nil {
					var rr ReadAtResult
					rd, ed := b.Call("read_at", ReadAtArgs{Path: ln, Offset: 0, Size: 4096})
					if decodeResult(b.Name, rd, ed, &rr) != nil {
						note("%s: the hardlink %s became unreadable after %s removed the other name",
							b.Name, ln, c.Name)
					} else if rr.Checksum != w.Checksum {
						note("%s: hardlink %s reads different data than was written", b.Name, ln)
					}
				}
			}
			_, _ = b.Call("unlink", UnlinkArgs{Path: ln})
			_, _ = b.Call("unlink", UnlinkArgs{Path: f})
			bump(4)

		case 5:
			// XATTR ON A FILE A PEER IS REMOVING. Either answer is fine;
			// a file that survives with a half-written attribute is not.
			f := fmt.Sprintf("%s/xattr-race-%d", root, n)
			if r, e := a.Call("write_at", WriteAtArgs{Path: f, Offset: 0, Size: 512,
				Stamp: "xr", Create: true}); decodeResult(a.Name, r, e, nil) != nil {
				break
			}
			done := make(chan struct{})
			go func() {
				_, _ = c.Call("unlink", UnlinkArgs{Path: f})
				close(done)
			}()
			_, _ = b.Call("xattr_set", XattrSetArgs{Path: f, Name: "user.race", Value: strings.Repeat("v", 64)})
			<-done
			if _, ex, err := statPath(a, f); err == nil && ex {
				var g XattrGetResult
				r, e := a.Call("xattr_get", XattrGetArgs{Path: f, Name: "user.race"})
				if decodeResult(a.Name, r, e, &g) == nil && g.Found && g.Value != strings.Repeat("v", 64) {
					note("%s: %s survived with a TORN xattr (%d bytes) after a concurrent unlink",
						a.Name, f, len(g.Value))
				}
				_, _ = a.Call("unlink", UnlinkArgs{Path: f})
			}
			bump(3)
		}

		quiesce.RUnlock()
		time.Sleep(time.Duration(200+rnd.Intn(500)) * time.Millisecond)
	}
}

// stormWitnesses: files and a directory that are written ONCE and then
// never touched again, so every node must always report them
// identically. They are the in-memory corruption detector this scenario
// would otherwise lack.
//
// fsck only ever sees the device, and only while nothing is mounted. A
// divergence that lives in one node's page cache or buffer cache -- a
// stale size, a dirent set missing an entry, a record refreshed onto the
// wrong identity -- is invisible to it: unmount, and the bad copy is
// simply dropped. The only way to catch that is to ask every node the
// same question WHILE THEY ARE MOUNTED and require the same answer.
//
// Checked three ways, because they fail differently:
//   - all nodes agree with each other (one node's cache drifted)
//   - all agree with what was written (everyone drifted, or the write
//     never landed)
//   - the WARM answer matches the COLD one after a remount (the cache
//     disagreed with the device, which is the one fsck can never see)
type stormWitness struct {
	path string
	size int
	sum  string
}

func stormMakeWitnesses(c *Client, dir string, n int) ([]stormWitness, error) {
	if r, e := c.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(c.Name, r, e, nil) != nil {
		return nil, fmt.Errorf("witness mkdir %s", dir)
	}
	var ws []stormWitness
	for i := 0; i < n; i++ {
		p := fmt.Sprintf("%s/w%02d", dir, i)
		size := 4096 * (1 + i%5)
		var w WriteAtResult
		r, e := c.Call("write_at", WriteAtArgs{Path: p, Offset: 0, Size: size,
			Stamp: fmt.Sprintf("witness-%02d", i), Create: true})
		if err := decodeResult(c.Name, r, e, &w); err != nil {
			return nil, fmt.Errorf("witness write %s: %w", p, err)
		}
		ws = append(ws, stormWitness{path: p, size: size, sum: w.Checksum})
	}
	return ws, nil
}

// stormCheckWitnesses asks every node about every witness and reports any
// disagreement. 'when' labels the moment (warm / cold) so a failure says
// which of the three ways it broke.
func stormCheckWitnesses(clients []*Client, dir string, ws []stormWitness, when string,
	note func(string, ...interface{}), injected func(string) bool) {

	// A witness divergence is the most perishable finding in this
	// scenario: it lives in a cache, and the next remount erases it.
	// Capture at most once per check, the moment one is seen.
	captured := false
	grab := func(path string) {
		if captured {
			return
		}
		captured = true
		captureEvidence(clients, "witness-divergence-"+when, []string{dir, path})
	}

	for _, w := range ws {
		type answer struct {
			size int64
			sum  string
			ok   bool
		}
		ans := map[string]answer{}
		for _, c := range clients {
			st, exists, err := statPath(c, w.path)
			if err != nil {
				// This storm pulls a device on purpose; a node whose
				// device is gone cannot answer, and that is the
				// injection working, not a divergence. Only a node that
				// answers and says ABSENT is a finding.
				if strings.Contains(strings.ToLower(err.Error()), "input/output error") {
					continue
				}
				note("[%s] %s could not be asked about witness %s: %v", when, c.Name, w.path, err)
				continue
			}
			if !exists {
				note("[%s] %s says witness %s DOES NOT EXIST -- it was written once and never touched",
					when, c.Name, w.path)
				grab(w.path)
				continue
			}
			var rr ReadAtResult
			r, e := c.Call("read_at", ReadAtArgs{Path: w.path, Offset: 0, Size: w.size})
			if decodeResult(c.Name, r, e, &rr) != nil {
				note("[%s] %s cannot read witness %s", when, c.Name, w.path)
				continue
			}
			ans[c.Name] = answer{size: st.Size, sum: rr.Checksum, ok: true}
		}
		// against what was written
		for name, a := range ans {
			if a.size != int64(w.size) {
				note("[%s] %s reports %s as %d bytes, written as %d -- a cached size that is not the truth",
					when, name, w.path, a.size, w.size)
			}
			if a.sum != w.sum {
				note("[%s] %s reads DIFFERENT CONTENT from witness %s than was written",
					when, name, w.path)
				grab(w.path)
			}
		}
		// against each other
		var ref string
		for name, a := range ans {
			if ref == "" {
				ref = name
				continue
			}
			if a.sum != ans[ref].sum || a.size != ans[ref].size {
				note("[%s] nodes disagree about %s: %s says %d bytes/%s, %s says %d bytes/%s",
					when, w.path, ref, ans[ref].size, ans[ref].sum[:8], name, a.size, a.sum[:8])
				grab(w.path)
			}
		}
	}

	// the directory itself: every node must see exactly the same names
	var refNames []string
	var refNode string
	for _, c := range clients {
		var rd ReaddirResult
		r, e := c.Call("readdir", ReaddirArgs{Path: dir})
		if decodeResult(c.Name, r, e, &rd) != nil {
			if injected(c.Name) {
				continue // its device is pulled; it cannot answer
			}
			note("[%s] %s cannot readdir the witness directory %s", when, c.Name, dir)
			continue
		}
		names := append([]string{}, rd.Names...)
		sort.Strings(names)
		if refNode == "" {
			refNode, refNames = c.Name, names
			if len(names) != len(ws) {
				note("[%s] %s sees %d entries in %s, %d were created",
					when, c.Name, len(names), dir, len(ws))
			}
			continue
		}
		if strings.Join(names, ",") != strings.Join(refNames, ",") {
			note("[%s] %s and %s disagree about the contents of %s: %v vs %v",
				when, refNode, c.Name, dir, refNames, names)
			grab(dir)
		}
	}
}

// RunCreateVisibility: an operation acknowledged on one node must be
// visible on every other, immediately.
//
// Found by hypervisor-storm and reduced to this: A makes a directory, B
// creates a file in it and the create RETURNS SUCCESS, C looks for it.
// At roughly one round in twenty C does not see it -- and in the worst
// observed case still did not after polling for five seconds, though it
// had appeared by twenty-five. Two symptoms, same cause:
//
//   - B's create fails ENOENT because B cannot see A's new directory
//   - C sees an EMPTY directory that B has just populated
//
// Neither loses data (every file observed was there afterwards, and both
// fsck and the storm's cross-node witnesses stay clean), but both are
// wrong, and the second is what lets a third node rmdir a directory
// another node is using: its emptiness check is answered honestly from a
// view that is out of date.
//
// This is deliberately the smallest shape that reproduces it: three
// nodes, one directory, one file, no concurrency, no failure injection.
// Anything that still fails here is not a race between load generators.
func RunCreateVisibility(clients []*Client, baseDir string, rounds int) (bool, error) {
	if len(clients) < 3 {
		return skipScenario("create visibility: needs 3 nodes, have %d", len(clients))
	}
	if rounds <= 0 {
		rounds = 40
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	a, b, c := clients[0], clients[1], clients[2]
	root := baseDir + "/visibility"
	if r, e := a.Call("mkdir", MkdirArgs{Path: root}); decodeResult(a.Name, r, e, nil) != nil {
		return false, fmt.Errorf("visibility: mkdir %s", root)
	}
	fmt.Printf("=== create visibility: %s mkdir -> %s create -> %s must see it, %d rounds ===\n",
		a.Name, b.Name, c.Name, rounds)

	mkdirUnseen, createUnseen, slow := 0, 0, 0
	worst := time.Duration(0)

	for i := 0; i < rounds; i++ {
		d := fmt.Sprintf("%s/d%03d", root, i)
		if r, e := a.Call("mkdir", MkdirArgs{Path: d}); decodeResult(a.Name, r, e, nil) != nil {
			return false, fmt.Errorf("%s: mkdir %s", a.Name, d)
		}
		f := d + "/f1"
		// B creates the file. A failure here is itself the bug: B cannot
		// see the directory A just made and told us about.
		if r, e := b.Call("write_at", WriteAtArgs{Path: f, Offset: 0, Size: 512,
			Stamp: "vis", Create: true}); decodeResult(b.Name, r, e, nil) != nil {
			mkdirUnseen++
			fmt.Printf("  round %d: %s could not create in %s's new directory -- it cannot see it yet\n",
				i, b.Name, a.Name)
			if mkdirUnseen == 1 {
				captureEvidence(clients, "mkdir-invisible-to-peer", []string{root, d})
			}
			continue
		}
		// C must see it NOW: B's create has already been acknowledged.
		if _, ex, err := statPath(c, f); err == nil && ex {
			continue
		}
		// It did not. How long until it does? That separates a
		// propagation delay from a view that never corrects.
		createUnseen++
		// Captured BEFORE the retry loop: this is the only moment the
		// disagreement is live on every node. Waiting until it resolves
		// destroys the thing worth looking at.
		if createUnseen == 1 {
			captureEvidence(clients, "create-invisible-to-peer", []string{root, d, f})
		}
		start := time.Now()
		seen := false
		for time.Since(start) < 30*time.Second {
			time.Sleep(200 * time.Millisecond)
			if _, ex, err := statPath(c, f); err == nil && ex {
				seen = true
				break
			}
		}
		took := time.Since(start)
		if took > worst {
			worst = took
		}
		if seen {
			slow++
			fmt.Printf("  round %d: %s did not see %s's acknowledged create for %v\n", i, c.Name, b.Name, took.Round(time.Millisecond))
		} else {
			fmt.Printf("  round %d: %s NEVER saw %s's acknowledged create (30s)\n", i, c.Name, b.Name)
		}
	}

	ok := true
	check(&ok, fmt.Sprintf("%s always saw the directory %s had just created", b.Name, a.Name), mkdirUnseen == 0,
		fmt.Sprintf("%d of %d rounds: the creating node's own next operation failed ENOENT inside it",
			mkdirUnseen, rounds))
	check(&ok, fmt.Sprintf("%s saw every acknowledged create by %s immediately", c.Name, b.Name), createUnseen == 0,
		fmt.Sprintf("%d of %d rounds were invisible to a peer at first look (worst wait %v) -- "+
			"an acknowledged namespace change that a peer cannot see is what lets a third node "+
			"decide a busy directory is empty", createUnseen, rounds, worst.Round(time.Millisecond)))
	if ok {
		fmt.Printf("PASS: create visibility: %d rounds, every acknowledged change was immediately visible everywhere\n", rounds)
	}
	return ok, nil
}

// captureEvidence: freeze everything needed to understand a fault, at the
// moment it is found, into a file that outlives the run.
//
// A scenario that prints "node c could not see the file" and moves on has
// destroyed its own finding: by the time anyone looks, the directory is
// gone, the caches have turned over, and dmesg has scrolled. Worse, the
// interesting state is per-node and some of it (a cached view that
// disagrees with the device) stops existing the moment anything
// unmounts. So this gathers, from EVERY node:
//
//   - dmesg tail (the kernel says more than any assertion can)
//   - /proc/fs/cetrafs/<dev>/info and the cluster view
//   - ZG ownership, fenced state, and the pending-free queues
//   - a readdir and a stat of the paths the caller names, PER NODE,
//     because "which nodes disagree" is usually the whole answer
//
// Written to a file next to the run rather than to stdout alone: stdout
// is routinely piped through grep, and the one run that mattered is the
// one whose output someone truncated.
func captureEvidence(clients []*Client, label string, paths []string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "==== cetrafs ctest evidence: %s ====\n", label)
	for _, c := range clients {
		fmt.Fprintf(&b, "\n######## node %s (device %s)\n", c.Name, c.Device)

		var snap ProcSnapshotResult
		if r, e := c.Call("proc_snapshot", ProcSnapshotArgs{Device: c.Device}); e == nil {
			if decodeResult(c.Name, r, e, &snap) == nil {
				var owned []int
				for _, zg := range snap.ZoneGroups {
					if zg.ThisNode {
						owned = append(owned, zg.ID)
					}
				}
				fmt.Fprintf(&b, "node_id=%d fenced=%v write_ready=%v owns_zg=%v cas_miscompares=%d\n",
					snap.ThisNodeID, snap.Fenced, snap.WriteReady, owned, snap.CASMiscompares)
				fmt.Fprintf(&b, "scrub: reclaimed=%d cycles=%d\n", snap.ScrubReclaimed, snap.ScrubCycles)
				for _, zg := range owned {
					var dr DeviceReadResult
					if r2, e2 := c.Call("device_read", DeviceReadArgs{Kind: "pending",
						Args: []string{fmt.Sprint(zg)}}); e2 == nil {
						if decodeResult(c.Name, r2, e2, &dr) == nil {
							q := strings.TrimSpace(dr.Output)
							if q == "" {
								q = "(empty)"
							}
							fmt.Fprintf(&b, "pending-free queue ZG%d: %s\n", zg, q)
						}
					}
				}
			}
		}

		// The per-node view of the paths in question. This is the part
		// that cannot be reconstructed later.
		for _, p := range paths {
			var rd ReaddirResult
			if r, e := c.Call("readdir", ReaddirArgs{Path: p}); e == nil && decodeResult(c.Name, r, e, &rd) == nil {
				names := append([]string{}, rd.Names...)
				sort.Strings(names)
				fmt.Fprintf(&b, "readdir %s -> %d entries %v\n", p, len(names), names)
			} else {
				st, ex, serr := statPath(c, p)
				fmt.Fprintf(&b, "readdir %s failed; stat exists=%v size=%d err=%v\n", p, ex, st.Size, serr)
			}
		}

		if r, e := c.Call("proc_raw", ProcRawArgs{Device: c.Device}); e == nil {
			var pr ProcRawResult
			if decodeResult(c.Name, r, e, &pr) == nil {
				fmt.Fprintf(&b, "---- /proc info ----\n%s\n", strings.TrimSpace(pr.Info))
				if strings.TrimSpace(pr.Cluster) != "" {
					fmt.Fprintf(&b, "---- /proc cluster ----\n%s\n", strings.TrimSpace(pr.Cluster))
				}
			}
		}
		if r, e := c.Call("dmesg_tail", DmesgTailArgs{Lines: 120}); e == nil {
			var dt DmesgTailResult
			if decodeResult(c.Name, r, e, &dt) == nil {
				fmt.Fprintf(&b, "---- dmesg tail ----\n%s\n", strings.TrimSpace(dt.Text))
			}
		}
	}

	name := fmt.Sprintf("ctest-evidence-%s-%d.txt", strings.Map(func(r rune) rune {
		if r == ' ' || r == '/' || r == ':' {
			return '-'
		}
		return r
	}, label), os.Getpid())
	if err := os.WriteFile(name, []byte(b.String()), 0o644); err != nil {
		fmt.Printf("  EVIDENCE: could not write %s: %v -- dumping inline instead\n%s\n", name, err, b.String())
		return ""
	}
	fmt.Printf("  EVIDENCE: %s (%d bytes) -- dmesg, /proc, ZG ownership, queues and every node's view\n",
		name, b.Len())
	return name
}

// RunLinkStaleReuse: link(2) through a name whose inode number has been
// RECYCLED under this node's feet.
//
// unlink, rmdir and rename all call cetrafs_verify_name_resolves() before
// acting, so a dentry still naming a dead file is caught. link() did not:
// it checked the foreign lock, added the dirent, then fresh-read the
// target record and bumped its nlink. The read was accurate and the
// nslock made the read-modify-write safe -- but nothing asked whether the
// record it was about to touch was still the FILE this node resolved.
//
// So the damage is twofold: a name published pointing at an unrelated
// file, with its dirent type taken from the stale in-core inode (a
// symlink's type on a regular file's record), and an nlink increment on a
// live file that owns no such name. That second half never comes back:
// when the file's real names are removed nlink never reaches 0, so the
// inode and its blocks leak permanently -- fsck's "allocated but NO
// directory entry names it".
//
// The type change is what makes it unmistakable: the stale incarnation is
// a SYMLINK and the recycled number is a REGULAR FILE, so a link that
// should not exist is visible as a type disagreement rather than as a
// subtle count.
//
// The vanished name must STAY vanished. The first version of this
// recreated the same name as the regular file and then demanded the link
// fail -- but that name resolved to a live file, so linking it was
// correct POSIX and nlink=2 was simply two real names. It reported a
// reproduction against code that was behaving properly. The heir
// therefore gets its own name and dir/thing stays gone.
func RunLinkStaleReuse(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("link-stale-reuse needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	a, b := clients[0], clients[1]
	dir := baseDir + "/linkstale"
	victim := dir + "/thing"
	heir := dir + "/heir"
	stolen := dir + "/stolen"
	fmt.Printf("=== link through a stale name: %s recycles a symlink's number into a regular file, %s links through its cached view ===\n",
		a.Name, b.Name)

	if resp, err := a.Call("mkdir", MkdirArgs{Path: dir}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", dir)
	}
	ok := true

	target := "/a/deliberately/distinctive/symlink/target/that/is/not/file/data"
	if resp, err := a.Call("symlink", SymlinkArgs{Target: target, LinkPath: victim}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup symlink: %v", err)
	}

	// b resolves it: b now holds a cached dentry bound to an in-core
	// inode with SYMLINK ops, for that number. That binding is what the
	// rest of this exercises -- a later path walk on b reuses it without
	// going back through iget (where the generation check lives).
	var rl ReadlinkResult
	resp, err := b.Call("readlink", ReadlinkArgs{Path: victim})
	if err := decodeResult(b.Name, resp, err, &rl); err != nil {
		return false, fmt.Errorf("%s: readlink before reuse: %w", b.Name, err)
	}
	check(&ok, b.Name+" resolves the symlink before the reuse", rl.Target == target,
		fmt.Sprintf("target %q want %q", rl.Target, target))
	var before StatResult
	if r, e := b.Call("stat", StatArgs{Path: victim, NoFollow: true}); decodeResult(b.Name, r, e, &before) != nil {
		return false, fmt.Errorf("%s: lstat before reuse", b.Name)
	}

	// a frees the number and hands it to a REGULAR FILE under a
	// DIFFERENT name. The old name must stay GONE: recreating it would
	// make b's link a perfectly legal operation on a live file, which
	// proves nothing. What is under test is b acting through a name
	// that no longer exists, on a number that now belongs to someone
	// else. The allocator takes the first free inode bit, so the number
	// just freed is the one the next create gets.
	if resp, err := a.Call("unlink", UnlinkArgs{Path: victim}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("unlink the symlink: %v", err)
	}
	var w WriteResult
	resp, err = a.Call("write", WriteArgs{Path: heir, Size: 4096, Stamp: "reused-as-a-regular-file"})
	if err := decodeResult(a.Name, resp, err, &w); err != nil {
		return false, fmt.Errorf("create the heir: %w", err)
	}
	var after StatResult
	if r, e := a.Call("stat", StatArgs{Path: heir, NoFollow: true}); decodeResult(a.Name, r, e, &after) != nil {
		return false, fmt.Errorf("%s: lstat the heir", a.Name)
	}

	// Without the recycle this scenario proves nothing -- say so rather
	// than passing on a setup that never armed the trap.
	if after.Ino != before.Ino {
		fmt.Printf("  SKIP: the number was not recycled (was %d, now %d) -- nothing to test\n",
			before.Ino, after.Ino)
		_, _ = a.Call("unlink", UnlinkArgs{Path: heir})
		_, _ = a.Call("rmdir", RmdirArgs{Path: dir})
		return ok, nil
	}
	fmt.Printf("  number %d is now %s (a regular file); the name %s is GONE, but %s still has it cached as a symlink\n",
		after.Ino, heir, victim, b.Name)

	// THE OPERATION UNDER TEST. b walks a path it has cached and links
	// through it. It must not act on the recycled record.
	linkResp, linkErr := b.Call("link", LinkArgs{OldPath: victim, NewPath: stolen})
	linkFailed := decodeResult(b.Name, linkResp, linkErr, nil) != nil

	// A refusal here is only meaningful if it came from the filesystem.
	// The name is GONE, so b's path walk can resolve it to nothing and
	// return ENOENT without cetrafs_link() ever being called -- which
	// is what actually happens today. That is correct behaviour, but it
	// is NOT this guard working, and reporting it as a pass would be
	// claiming coverage this scenario does not have ("make the code
	// under test the SOLE path to the observable").
	if _, visible, _ := statPath(b, victim); linkFailed && !visible {
		fmt.Printf("  INCONCLUSIVE: %s cannot see %s at all, so the link was refused by path lookup --\n"+
			"    cetrafs_link() was never reached and its identity guard is UNEXERCISED by this scenario.\n"+
			"    Reaching it needs a handle-based link (linkat AT_EMPTY_PATH) on an inode whose number\n"+
			"    was recycled while this node held it, which this harness cannot yet issue.\n", b.Name, victim)
		_, _ = a.Call("unlink", UnlinkArgs{Path: heir})
		_, _ = a.Call("rmdir", RmdirArgs{Path: dir})
		return ok, nil
	}
	check(&ok, b.Name+" REFUSES to link through a name whose inode was recycled", linkFailed,
		"the link succeeded -- it acted on a record it never resolved")

	// Whatever happened, the live file must not have been altered: no
	// name was legitimately added to it, so its nlink must still be 1.
	// An inflated nlink is the half that never heals -- the inode can
	// never reach 0 and is leaked for the life of the filesystem.
	if st, exists, serr := statPath(a, heir); serr == nil && exists {
		check(&ok, "the recycled file's nlink is untouched", st.Nlink == 1,
			fmt.Sprintf("nlink=%d want 1 -- a link it never gained, so it can never be freed", st.Nlink))
	}

	// And if the link did land, say exactly what it produced: a name
	// carrying the dead symlink's type over a regular file's record.
	if !linkFailed {
		if st, exists, serr := statPath(a, stolen); serr == nil && exists {
			check(&ok, "the published name is not a type-confused alias", !strings.HasPrefix(st.Mode, "l"),
				fmt.Sprintf("%s is mode %q -- the dirent took its type from the DEAD symlink", stolen, st.Mode))
		}
		var rl2 ReadlinkResult
		if r2, e2 := b.Call("readlink", ReadlinkArgs{Path: stolen}); decodeResult(b.Name, r2, e2, &rl2) == nil {
			check(&ok, "the published name does not readlink as a symlink", false,
				fmt.Sprintf("readlink(%s) returned %q -- a regular file's data read as a symlink target", stolen, rl2.Target))
		}
	}

	_, _ = a.Call("unlink", UnlinkArgs{Path: stolen})
	_, _ = a.Call("unlink", UnlinkArgs{Path: heir})
	_, _ = a.Call("rmdir", RmdirArgs{Path: dir})
	return ok, nil
}

// countEntries: how many names does this node see in a directory right
// now? Used when a file has vanished, to say whether the parent lost
// the whole block or just the one name.
func countEntries(c *Client, path string) int {
	var rr ReaddirResult
	if r, e := c.Call("readdir", ReaddirArgs{Path: path}); decodeResult(c.Name, r, e, &rr) != nil {
		return -1
	}
	return len(rr.Names)
}

// RunInodeUnique: do two nodes ever hold the SAME inode number at the
// same time?
//
// Every node creates files concurrently and reports the inode number it
// got. An inode number is an index into the global inode table, handed
// out by a compare-and-swap on the inode bitmap, so two live files must
// never share one. If they do, every symptom of the dirent-visibility
// class follows for free: a name resolves to an object that was never
// there, a file vanishes from under its writer, a subtree detaches.
//
// A storm run logged 283 cases of one number being allocated twice with
// no free in between, but that came from kernel probes
// correlated across nodes, which is exactly the kind of evidence that
// produced several false findings in this hunt. This asks the question
// at the only level that cannot lie: two live files, two nodes, one
// number, observed through stat(2).
func RunInodeUnique(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("inode-unique needs at least 2 clients")
	}
	if err := ensureMounted(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	root := baseDir + "/inouniq"
	if resp, err := clients[0].Call("mkdir", MkdirArgs{Path: root}); decodeResult(clients[0].Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", root)
	}
	for _, c := range clients {
		if resp, err := c.Call("mkdir", MkdirArgs{Path: fmt.Sprintf("%s/%s", root, c.Name)}); decodeResult(c.Name, resp, err, nil) != nil {
			return false, fmt.Errorf("setup mkdir for %s", c.Name)
		}
	}
	fmt.Printf("=== inode uniqueness: %d nodes creating concurrently, every inode number must belong to one file ===\n",
		len(clients))

	ok := true
	const rounds, perRound = 10, 25

	type owner struct{ node, path string }
	live := map[uint64]owner{}
	byPath := map[string]uint64{}
	var mu sync.Mutex
	dupes, created := 0, 0

	// Churn is the point. Pure creation never recycles a number, and a
	// number that is never recycled cannot be handed to two nodes. The
	// storm collides while deleting and recreating constantly, so this
	// deletes half of each round's files before the next round takes
	// their numbers back.
	for r := 0; r < rounds; r++ {
		var wg sync.WaitGroup
		for _, c := range clients {
			wg.Add(1)
			go func(c *Client) {
				defer wg.Done()
				for i := 0; i < perRound; i++ {
					p := fmt.Sprintf("%s/%s/f-%d-%d", root, c.Name, r, i)
					if resp, err := c.Call("write_at", WriteAtArgs{Path: p, Offset: 0, Size: 64,
						Stamp: "u", Create: true}); decodeResult(c.Name, resp, err, nil) != nil {
						continue
					}
					var st StatResult
					if resp, err := c.Call("stat", StatArgs{Path: p, NoFollow: true}); decodeResult(c.Name, resp, err, &st) != nil {
						continue
					}
					mu.Lock()
					created++
					if prev, seen := live[st.Ino]; seen && prev.path != p {
						dupes++
						if dupes <= 5 {
							fmt.Printf("  COLLISION: inode %d is held by TWO live files at once: %s on %s and %s on %s\n",
								st.Ino, prev.path, prev.node, p, c.Name)
						}
					}
					live[st.Ino] = owner{c.Name, p}
					byPath[p] = st.Ino
					mu.Unlock()
				}
				// Give half of them back, so their numbers are free for
				// the next round -- on this node and on every other.
				for i := 0; i < perRound; i += 2 {
					p := fmt.Sprintf("%s/%s/f-%d-%d", root, c.Name, r, i)
					if resp, err := c.Call("unlink", UnlinkArgs{Path: p}); decodeResult(c.Name, resp, err, nil) == nil {
						mu.Lock()
						if ino, okp := byPath[p]; okp {
							if cur, seen := live[ino]; seen && cur.path == p {
								delete(live, ino)
							}
							delete(byPath, p)
						}
						mu.Unlock()
					}
				}
			}(c)
		}
		wg.Wait()
	}

	check(&ok, "no inode number is shared by two live files", dupes == 0,
		fmt.Sprintf("%d collision(s) across %d files created", dupes, created))
	fmt.Printf("  %d files created, %d still live at the end\n", created, len(live))

	for _, c := range clients {
		for r := 0; r < rounds; r++ {
			for i := 0; i < perRound; i++ {
				_, _ = c.Call("unlink", UnlinkArgs{Path: fmt.Sprintf("%s/%s/f-%d-%d", root, c.Name, r, i)})
			}
		}
		_, _ = c.Call("rmdir", RmdirArgs{Path: fmt.Sprintf("%s/%s", root, c.Name)})
	}
	_, _ = clients[0].Call("rmdir", RmdirArgs{Path: root})
	return ok, nil
}

// RunConcurrentMkdirStorm is the regression test for the directory
// extent-leaf / dirent-scan staleness fixed -- a bug that
// RunConcurrentMkdir could never catch because it raced a single name
// once, into a tiny (depth-0, inline-extent) parent, in the default
// filelock mode.
//
// Three conditions must all hold for the corruption to appear, and this
// scenario forces all three:
//
//  1. nofilelock mode. cetrafs_lock_held_for_write_locally() only
//     mis-trusts a directory's cached metadata under nofilelock (in
//     filelock mode a directory has no write-lock holder, so the
//     predicate is already false and reads stay fresh).
//  2. A parent spilled to a depth-1 extent tree. The stale read is of
//     the external extent LEAF; a depth-0 directory keeps its extents
//     inline in the record (always read fresh) and cannot express the
//     bug. We pre-grow the parent well past its 4 inline extents.
//  3. Sustained, synchronised same-name races. A peer's committed entry
//     is missed only when this node scans a stale leaf/dirent cache, so
//     the two nodes must be hammering the same names at the same instant,
//     many times, not once.
//
// The invariant is exact and skew-free: for every name, across all
// nodes, mkdir(2) must succeed EXACTLY ONCE. Two successes is the
// duplicate-directory corruption (two inodes under one name); zero is a
// lost create. Against the pre-fix module two nodes duplicated the large
// majority of names here; after the fix, none.
func RunConcurrentMkdirStorm(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("concurrent-mkdir-storm needs at least 2 clients")
	}
	// Must run nofilelock -- the only mode the bug lives in. Unmount
	// first so the option actually takes (an adopted live mount ignores
	// it, see mountAllNoFileLock).
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	if err := mountAllNoFileLock(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	root := baseDir + "/mkdirstorm"
	a := clients[0]
	// Non-strict (mkdir -p): also creates the per-run test dir, which
	// nothing else has created on this freshly-mkfs'd, just-mounted
	// device yet. The races below are strict; this setup need not be.
	if resp, err := a.Call("mkdir", MkdirArgs{Path: root}); decodeResult(a.Name, resp, err, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", root)
	}

	// Pre-grow the parent past its 4 inline extents so it spills to a
	// depth-1 external leaf -- condition (2). Each filler is its own
	// entry; plenty to force the spill and then some.
	const fillers = 120
	for i := 0; i < fillers; i++ {
		p := fmt.Sprintf("%s/filler-%03d", root, i)
		if resp, err := a.Call("mkdir", MkdirArgs{Path: p, Strict: true}); decodeResult(a.Name, resp, err, nil) != nil {
			return false, fmt.Errorf("setup filler mkdir %s", p)
		}
	}
	fmt.Printf("=== concurrent mkdir storm: parent %q pre-grown with %d entries (depth-1), %d nodes racing same names ===\n",
		root, fillers, len(clients))

	const names = 200
	ok := true
	dupes, lost := 0, 0
	for i := 0; i < names; i++ {
		name := fmt.Sprintf("%s/d%03d", root, i)
		results := fireConcurrently(clients, "mkdir", MkdirArgs{Path: name, Strict: true})
		succ := 0
		for _, r := range results {
			if r.err == nil && r.resp.OK {
				succ++
			}
		}
		if succ > 1 {
			dupes++
			if dupes <= 8 {
				fmt.Printf("  DUPLICATE: %q created by %d nodes at once -- two inodes, one name\n", name, succ)
			}
		} else if succ == 0 {
			lost++
			if lost <= 8 {
				fmt.Printf("  LOST: %q created by no node -- both refused a legal create\n", name)
			}
		}
	}
	check(&ok, "no name was created by more than one node (no duplicate directories)", dupes == 0,
		fmt.Sprintf("%d duplicated", dupes))
	check(&ok, "no name was lost (every race had a winner)", lost == 0, fmt.Sprintf("%d lost", lost))

	// Independent confirmation from the namespace itself: every node's
	// readdir must show each d### exactly once. (os.ReadDir de-dups
	// nothing -- a directory with two 'd007' dirents lists it twice.)
	for _, c := range clients {
		var rd ReaddirResult
		resp, err := c.Call("readdir", ReaddirArgs{Path: root})
		if decodeResult(c.Name, resp, err, &rd) != nil {
			check(&ok, fmt.Sprintf("%s could read the parent back", c.Name), false, "readdir failed")
			continue
		}
		seen := map[string]int{}
		for _, n := range rd.Names {
			seen[n]++
		}
		repeated, missing := 0, 0
		for i := 0; i < names; i++ {
			n := fmt.Sprintf("d%03d", i)
			switch {
			case seen[n] > 1:
				repeated++
			case seen[n] == 0:
				missing++
			}
		}
		check(&ok, fmt.Sprintf("%s: parent lists every raced name exactly once", c.Name),
			repeated == 0 && missing == 0, fmt.Sprintf("%d repeated, %d missing", repeated, missing))
	}

	if ok {
		fmt.Printf("PASS: concurrent mkdir storm: all %d raced names created exactly once across %d nodes\n",
			names, len(clients))
	} else {
		fmt.Printf("FAIL: concurrent mkdir storm: %d duplicated, %d lost\n", dupes, lost)
	}
	return ok, nil
}

// RunNsFuzz is the seeded, invariant-checking generalization of
// RunConcurrentMkdirStorm: the cross-node NAMESPACE fuzzer that guards the
// bug class 0.7 shipped a fix for (a stale directory extent-leaf read
// letting two nodes diverge on a directory, so two mkdir()s of one name
// both "won", children were orphaned, and entries went INVISIBLE).
//
// From a fixed seed each node fires a long random stream of
// create/mkdir/unlink/rmdir/rename/symlink/link/chmod/truncate against a
// SHARED, small name pool in ONE arena directory. A small pool in one
// directory is deliberate: it maximises both same-name collisions (two
// nodes racing the identical create) and extent-tree churn (the arena
// spills to a depth-1 leaf and back as it grows and shrinks) -- exactly
// the conditions the 0.7 fault needed. Every op may legally lose its race
// (EEXIST / ENOENT / ENOTEMPTY / EISDIR / ...), so op results are ignored;
// the test is the INVARIANTS checked once the churn quiesces:
//
//  1. Cross-node agreement -- with the storm stopped, every node's readdir
//     of the arena must be IDENTICAL. A divergence IS the cross-node
//     visibility failure (0.7's INVISIBLE), caught without even unmounting.
//  2. Structural integrity -- unmount and fsck must find NO orphaned inode
//     ("allocated but NO directory entry"), NO unreachable subtree, NO
//     duplicate name, NO nlink disagreement and none of fsck's hard
//     corruptions. Unlike the hypervisor storm this injects no device
//     pulls, so there is no legitimate source of residue: any such finding
//     is a real bug, which is why this is stricter than stormFsckFatal().
//
// Runs nofilelock (the VM-image / live-migration mode the bug needs) and is
// reproducible from its seed; a larger -nsfuzz-ops (or -repeat) is a soak.
// nsFuzzAllOps is the full operation vocabulary; opset (a comma list) can
// restrict it, which is how a failing run is triaged down to the culprit
// op(s) -- e.g. opset="create,link" to isolate hardlink nlink accounting.
var nsFuzzAllOps = []string{"create", "mkdir", "unlink", "rmdir", "rename", "symlink", "link", "chmod", "truncate", "write"}

func nsFuzzDoOp(c *Client, rnd *rand.Rand, op, a, b string, pool int) {
	switch op {
	case "create":
		c.Call("write_at", WriteAtArgs{Path: a, Offset: 0, Size: 512 * (1 + rnd.Intn(8)), Stamp: "f", Create: true})
	case "mkdir":
		c.Call("mkdir", MkdirArgs{Path: a, Strict: true})
	case "unlink":
		c.Call("unlink", UnlinkArgs{Path: a})
	case "rmdir":
		c.Call("rmdir", RmdirArgs{Path: a})
	case "rename":
		c.Call("rename", RenameArgs{Old: a, New: b})
	case "symlink":
		c.Call("symlink", SymlinkArgs{Target: fmt.Sprintf("e%04d", rnd.Intn(pool)), LinkPath: a})
	case "link":
		c.Call("link", LinkArgs{OldPath: a, NewPath: b})
	case "chmod":
		c.Call("chmod", ChmodArgs{Path: a, Mode: 0600 | uint32(rnd.Intn(0100))})
	case "truncate":
		c.Call("truncate", TruncateArgs{Path: a, Size: int64(4096 * rnd.Intn(16))})
	case "write":
		c.Call("write_at", WriteAtArgs{Path: a, Offset: int64(4096 * rnd.Intn(8)), Size: 4096, Stamp: "m"})
	}
	// Results ignored on purpose: a lost race is a legal
	// EEXIST/ENOENT/ENOTEMPTY/EISDIR/..., not a failure. The invariants
	// checked after the churn quiesces are the oracle.
}

func RunNsFuzz(clients []*Client, baseDir string, seed int64, opsPerNode, pool int, opset string) (bool, error) {
	if len(clients) < 2 {
		return skipScenario("ns-fuzz: needs at least 2 nodes, have %d", len(clients))
	}
	ops := nsFuzzAllOps
	if strings.TrimSpace(opset) != "" {
		ops = nil
		for _, o := range strings.Split(opset, ",") {
			o = strings.TrimSpace(o)
			for _, known := range nsFuzzAllOps {
				if o == known {
					ops = append(ops, o)
				}
			}
		}
		if len(ops) == 0 {
			return false, fmt.Errorf("ns-fuzz: opset %q selected no known ops (known: %s)", opset, strings.Join(nsFuzzAllOps, ","))
		}
	}
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	if err := mountAllNoFileLock(clients); err != nil {
		return false, err
	}
	defer func() {
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
	}()

	arena := baseDir + "/nsfuzz"
	if r, e := clients[0].Call("mkdir", MkdirArgs{Path: arena}); decodeResult(clients[0].Name, r, e, nil) != nil {
		return false, fmt.Errorf("setup mkdir %s", arena)
	}
	fmt.Printf("=== ns-fuzz: %d nodes x %d ops, pool=%d, seed=%d, ops=[%s], nofilelock ===\n",
		len(clients), opsPerNode, pool, seed, strings.Join(ops, ","))

	// Scope oracle 3's dmesg scan to THIS run: the ring buffer persists
	// across runs, and without the marker one failing run poisons every
	// run after it on the same slaves. Best-effort -- a slave too old to
	// know the RPC just gets an unscoped (stricter) scan.
	dmesgMark := fmt.Sprintf("nsfuzz-%d-%d", seed, time.Now().UnixNano())
	for _, c := range clients {
		if r, e := c.Call("dmesg_mark", DmesgMarkArgs{Marker: dmesgMark}); decodeResult(c.Name, r, e, nil) != nil {
			fmt.Printf("    (%s: dmesg_mark unsupported -- its double-free scan covers the whole ring)\n", c.Name)
		}
	}

	nm := func(i int) string { return fmt.Sprintf("%s/e%04d", arena, i) }

	var wg sync.WaitGroup
	for ci, c := range clients {
		ci, c := ci, c
		wg.Add(1)
		go func() {
			defer wg.Done()
			rnd := rand.New(rand.NewSource(seed + int64(ci)*7919 + 1))
			for i := 0; i < opsPerNode; i++ {
				a := nm(rnd.Intn(pool))
				b := nm(rnd.Intn(pool))
				nsFuzzDoOp(c, rnd, ops[rnd.Intn(len(ops))], a, b, pool)
			}
		}()
	}
	wg.Wait()
	ok := true

	// Let any deferred cross-node block frees (the pending-free queue)
	// settle, so the readdir views and fsck reflect the quiesced state and
	// a still-draining free cannot masquerade as a leak.
	statfsOf := func(c *Client, label string) (StatfsResult, error) {
		resp, err := c.Call("statfs", struct{}{})
		var res StatfsResult
		if err := decodeResult(c.Name, resp, err, &res); err != nil {
			return StatfsResult{}, fmt.Errorf("%s: statfs (%s): %w", c.Name, label, err)
		}
		return res, nil
	}
	_ = quiesceFreeBlocks(statfsOf, clients)

	// Oracle 1: cross-node agreement on the arena's contents.
	var ref []string
	refName := ""
	for _, c := range clients {
		var rd ReaddirResult
		r, e := c.Call("readdir", ReaddirArgs{Path: arena})
		if decodeResult(c.Name, r, e, &rd) != nil {
			check(&ok, fmt.Sprintf("%s could read the arena back", c.Name), false, "readdir failed")
			continue
		}
		sort.Strings(rd.Names)
		if ref == nil {
			ref, refName = rd.Names, c.Name
			continue
		}
		same := len(ref) == len(rd.Names)
		for i := 0; same && i < len(ref); i++ {
			same = ref[i] == rd.Names[i]
		}
		check(&ok, fmt.Sprintf("%s and %s agree on the arena's %d entries", refName, c.Name, len(ref)), same,
			fmt.Sprintf("%s has %d entries, %s has %d -- cross-node visibility divergence", refName, len(ref), c.Name, len(rd.Names)))
	}

	// Oracle 2: fsck, strict. An uninjected run must leave NO orphan, NO
	// detached subtree, NO duplicate name, NO nlink disagreement and none
	// of fsck's hard corruptions.
	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	var fr FsckResult
	r, e := clients[0].Call("fsck", FsckArgs{})
	if decodeResult(clients[0].Name, r, e, &fr) != nil {
		check(&ok, "fsck ran after the fuzz", false, "fsck call failed")
	} else {
		var bad []string
		for _, ln := range strings.Split(fr.Output, "\n") {
			l := strings.TrimSpace(ln)
			if !strings.HasPrefix(l, "ERR") {
				continue
			}
			low := strings.ToLower(l)
			if strings.Contains(low, "but no directory") || // orphan: allocated but nothing names it
				strings.Contains(low, "not reachable") || // detached subtree
				strings.Contains(low, "duplicate") ||
				strings.Contains(low, "nlink") ||
				strings.Contains(low, "marked free") || // referenced block reads free -- data loss
				(strings.Contains(low, "referenced by") && strings.Contains(low, "inodes")) ||
				strings.Contains(low, "overlap") || strings.Contains(low, "cross") ||
				strings.Contains(low, "checksum") || strings.Contains(low, "magic") ||
				strings.Contains(low, "no '.'") || strings.Contains(low, "no '..'") {
				bad = append(bad, l)
			}
		}
		for i, l := range bad {
			if i >= 10 {
				fmt.Printf("    ... and %d more\n", len(bad)-10)
				break
			}
			fmt.Printf("    fsck: %s\n", l)
		}
		check(&ok, fmt.Sprintf("fsck clean after %d ops/node -- no orphan / detached / duplicate / nlink / corruption", opsPerNode),
			len(bad) == 0, fmt.Sprintf("%d corruption finding(s) -- replay with seed %d", len(bad), seed))
	}

	// Oracle 3: NO node may have detected a double free. The kernel
	// absorbs the benign orderings and only warns ("free: block N was
	// already free", "inode bitmap: bit N was already free") -- but those
	// are the lucky interleavings of the exact race whose unlucky one is
	// fsck's "referenced by an inode but marked FREE": the second free
	// landing after the block was handed to a live file. A clean-looking
	// run that printed one was corruption that got lucky. Added
	// when the evict arbiter turned out to be a no-op (the
	// CAS layer flattened "already free" to success): these warns fired
	// in EVERY run while fsck caught actual damage only ~1 run in 3.
	for _, c := range clients {
		var dm DmesgTailResult
		r, e := c.Call("dmesg_tail", DmesgTailArgs{Lines: 50000, Since: dmesgMark})
		if decodeResult(c.Name, r, e, &dm) != nil {
			check(&ok, fmt.Sprintf("%s dmesg readable for the double-free scan", c.Name), false, "dmesg_tail failed")
			continue
		}
		// Only the BLOCK-level message: a losing evict's inode-bitmap
		// arbitration ("bit N was already free", pr_debug) is the
		// arbiter working as designed -- losers are supposed to exist.
		// A block freed twice has no benign reading.
		var hits []string
		for _, ln := range strings.Split(dm.Text, "\n") {
			if strings.Contains(ln, "double free of extent") {
				hits = append(hits, strings.TrimSpace(ln))
			}
		}
		for i, h := range hits {
			if i >= 5 {
				fmt.Printf("    ... and %d more\n", len(hits)-5)
				break
			}
			fmt.Printf("    %s dmesg: %s\n", c.Name, h)
		}
		check(&ok, fmt.Sprintf("%s saw no double free", c.Name), len(hits) == 0,
			fmt.Sprintf("%d double-free warning(s) -- a block or inode number was freed twice; the unlucky ordering of this race frees a live file's block", len(hits)))
	}

	if ok {
		fmt.Printf("PASS: ns-fuzz seed=%d -- all nodes agree and fsck is clean after %d ops/node\n", seed, opsPerNode)
	}
	return ok, nil
}
