package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// RunChurnTrim: the content oracle across FITRIM on two nodes.
//
// tests/kernel/churn_oracle.sh runs several writers that free and reuse
// space, and can say what every block of every file must hold; it is
// what found the two corruptions no targeted suite did. Here it runs on
// two nodes at once against the shared LUN while both trim in a loop:
// every pass claims free runs, UNMAPs them and gives them back while
// the peer and the local writers allocate around them. A block the
// trim discards under a file, a claim the allocator hands out anyway,
// a run given back into the wrong bitmap -- each shows as a block whose
// content is not what the oracle wrote. Two rounds, each followed by a
// remount of both nodes and a verify of every actor on the node that
// ran it (the oracle's state lives there), then fsck.
//
// Setup is asserted: the trims must discard something. The negative
// control (CTEST_CHURN_CONTROL=1) turns the trim's claim off
// (trim_skip_claim), which tests/kernel/fstrim_claim.sh shows lets the
// UNMAP land on a file's data, and holds every discard 200 ms
// (trim_discard_stall_ms) so the churn allocates into the unclaimed
// run before it lands: without the hold the window is a few
// microseconds. Even with it the control has not fired here (see the
// end of the function): the discrimination this scenario can show is
// unproven, and the control says so instead of passing.
func RunChurnTrim(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("churn-trim needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	two := []*Client{a, b}
	control := os.Getenv("CTEST_CHURN_CONTROL") != ""
	defer func() {
		if control {
			for _, c := range two {
				_ = callOK(c, "mod_param", ModParamArgs{Name: "trim_skip_claim", Value: "0"})
				_ = callOK(c, "mod_param", ModParamArgs{Name: "trim_discard_stall_ms", Value: "0"})
			}
		}
		if uerr := ensureUnmounted(clients); uerr != nil {
			fmt.Printf("WARNING: cleanup unmount failed: %v\n", uerr)
		}
		if err := mkfsOn(a); err != nil {
			fmt.Printf("WARNING: could not reformat the LUN to its full size: %v\n", err)
		}
	}()
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	// A small volume, so every trim pass works the groups the churn
	// allocates in: on the whole LUN a pass spends nearly all its time
	// on empty groups nobody writes to, and the control never fires.
	if err := mkfsOn(a, "-s", "4G", "-b", "512", "-z", "2"); err != nil {
		return false, fmt.Errorf("setup: %w", err)
	}
	if err := mountAllDefault(two); err != nil {
		return false, err
	}
	const (
		actorsPerNode = 2
		secs          = 60
		files         = 24
		maxblk        = 384
		rounds        = 2
	)
	seed := time.Now().UnixNano() % 1000000007
	dir := baseDir + "/churn-trim"
	fmt.Printf("=== churn-trim: content oracle on %s and %s while both trim (seed %d) ===\n", a.Name, b.Name, seed)
	ok := true
	if control {
		fmt.Printf("  NEGATIVE CONTROL: trim_skip_claim=1, trim_discard_stall_ms=200 on both nodes\n")
		for _, c := range two {
			if err := callOK(c, "mod_param", ModParamArgs{Name: "trim_skip_claim", Value: "1"}); err != nil {
				return false, fmt.Errorf("%s: trim_skip_claim: %w", c.Name, err)
			}
			if err := callOK(c, "mod_param", ModParamArgs{Name: "trim_discard_stall_ms", Value: "200"}); err != nil {
				return false, fmt.Errorf("%s: trim_discard_stall_ms: %w", c.Name, err)
			}
		}
	}
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir %s: %w", dir, err)
	}

	type actor struct {
		c  *Client
		id int
	}
	var actors []actor
	conns := map[*Client][]*Client{}
	for ni, c := range two {
		cs, closeAll, err := c.Parallel(actorsPerNode+1, 10*time.Second)
		if err != nil {
			return false, fmt.Errorf("%s: connections: %w", c.Name, err)
		}
		defer closeAll()
		conns[c] = cs
		for k := 0; k < actorsPerNode; k++ {
			actors = append(actors, actor{c: c, id: ni*actorsPerNode + k})
		}
	}

	var trimmed uint64
	for r := 1; r <= rounds; r++ {
		var wg sync.WaitGroup
		results := make([]ChurnResult, len(actors))
		errs := make([]error, len(actors))
		for i, ac := range actors {
			wg.Add(1)
			go func(i int, ac actor) {
				defer wg.Done()
				conn := conns[ac.c][1+ac.id%actorsPerNode]
				resp, e := conn.Call("churn", ChurnArgs{Mode: "churn", Dir: dir, Actor: ac.id, Seed: seed + int64(r),
					Secs: secs, Files: files, MaxBlk: maxblk})
				errs[i] = decodeResult(ac.c.Name, resp, e, &results[i])
			}(i, ac)
		}
		// Both nodes trim in a loop while the churn runs.
		stop := make(chan struct{})
		var tw sync.WaitGroup
		var tmu sync.Mutex
		trimErrs := []string{}
		for _, c := range two {
			tw.Add(1)
			go func(c *Client) {
				defer tw.Done()
				for {
					select {
					case <-stop:
						return
					default:
					}
					var fr FstrimResult
					resp, e := conns[c][0].Call("fstrim", FstrimArgs{})
					if err := decodeResult(c.Name, resp, e, &fr); err != nil {
						tmu.Lock()
						trimErrs = append(trimErrs, err.Error())
						tmu.Unlock()
					} else {
						tmu.Lock()
						trimmed += fr.Bytes
						tmu.Unlock()
					}
					time.Sleep(3 * time.Second)
				}
			}(c)
		}
		wg.Wait()
		close(stop)
		tw.Wait()
		for i, ac := range actors {
			check(&ok, fmt.Sprintf("round %d: actor %d on %s churned", r, ac.id, ac.c.Name),
				errs[i] == nil && results[i].ExitCode == 0,
				fmt.Sprintf("err %v exit %d: %s", errs[i], results[i].ExitCode, results[i].Output))
		}
		check(&ok, fmt.Sprintf("round %d: every fstrim succeeded", r), len(trimErrs) == 0, strings.Join(trimErrs, "; "))

		// Remount both: what was published must be on the device.
		if err := ensureUnmounted(clients); err != nil {
			return false, err
		}
		if err := mountAllDefault(two); err != nil {
			return false, err
		}
		for _, ac := range actors {
			var vr ChurnResult
			resp, e := ac.c.Call("churn", ChurnArgs{Mode: "verify", Dir: dir, Actor: ac.id})
			err := decodeResult(ac.c.Name, resp, e, &vr)
			check(&ok, fmt.Sprintf("round %d: actor %d's files on %s match the oracle after a remount", r, ac.id, ac.c.Name),
				err == nil && vr.ExitCode == 0, fmt.Sprintf("err %v exit %d: %s", err, vr.ExitCode, vr.Output))
		}
	}
	check(&ok, fmt.Sprintf("setup: the trims discarded %d MiB while the churn ran", trimmed>>20), trimmed > 0,
		"nothing was trimmed -- the race did not happen")

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
	if control {
		// The control's job is to FAIL the oracle. Measured 2026-11-12
		// (4 GiB volume, 200 ms hold, two rounds, twice): it does not --
		// an allocation landing in the unclaimed run in the hold is rare
		// under this churn. The claim's discrimination is shown where it
		// can be arranged, tests/kernel/fstrim_claim.sh case 2; this
		// scenario's own is NOT shown, and a green control says so
		// rather than passing.
		if ok {
			fmt.Printf("CONTROL DID NOT FIRE: the oracle held without the claim -- this scenario's discrimination " +
				"is not shown (tests/kernel/fstrim_claim.sh shows the claim's)\n")
			return false, nil
		}
		fmt.Printf("PASS: control: without the claim the oracle caught the trim destroying data\n")
		return true, nil
	}
	if ok {
		fmt.Printf("PASS: churn-trim: every block matches the oracle across two nodes trimming\n")
	}
	return ok, nil
}

// mkfsOn reformats the shared device from c (forced), with extra mkfs
// arguments; mkfs's own output comes back in the error.
func mkfsOn(c *Client, extra ...string) error {
	var mr MkfsResult
	resp, e := c.Call("mkfs", MkfsArgs{Force: true, Extra: extra})
	if err := decodeResult(c.Name, resp, e, &mr); err != nil {
		return err
	}
	if mr.ExitCode != 0 {
		return fmt.Errorf("mkfs %v: exit %d: %s %s", extra, mr.ExitCode, mr.Stdout, mr.Stderr)
	}
	return nil
}
