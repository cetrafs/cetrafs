package main

import (
	"fmt"
	"os"
	"sort"
	"strings"
)

// RunRenameLoop: two nodes move two directories into each other at once.
//
// Node A runs `mv P Q/` while node B runs `mv Q P/`. Each node's VFS
// checks for a move into itself against its OWN dentry cache, which the
// peer's move is not in, so both checks pass. Without the device-side
// cycle check both moves land: P and Q become each other's children and
// leave the tree -- unreachable from the root on every node, with
// everything under them. tests/kernel/rename_cycle_peer.sh plays node B
// by editing the image; this is the real race, on two nodes over the
// shared LUN.
//
// Both renames are held between their lookups and their namespace
// locks (rename_prelock_stall_ms), where the race is decided, so every
// round is a real crossing rather than a probability. Each round must
// end with exactly one move done, the other refused, and -- from BOTH
// nodes -- one of P/Q at the top with the other inside it and each
// directory's file readable. Then fsck.
//
// Negative control (CTEST_RENAME_CONTROL=1): rename_skip_cycle_check on
// both nodes. Both moves must then succeed and the pair vanish, or the
// scenario is not exercising the race it claims to.
func RunRenameLoop(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("rename-loop needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	two := []*Client{a, b}
	control := os.Getenv("CTEST_RENAME_CONTROL") != ""
	setBoth := func(name, val string) error {
		for _, c := range two {
			if err := callOK(c, "mod_param", ModParamArgs{Name: name, Value: val}); err != nil {
				return fmt.Errorf("%s: %s=%s: %w", c.Name, name, val, err)
			}
		}
		return nil
	}
	defer func() {
		_ = setBoth("rename_prelock_stall_ms", "0")
		_ = setBoth("rename_skip_cycle_check", "0")
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
	rounds := 10
	if control {
		rounds = 3
	}
	dir := baseDir + "/rename-loop"
	fmt.Printf("=== rename-loop: %s moves P into Q while %s moves Q into P, %d rounds ===\n", a.Name, b.Name, rounds)
	if control {
		fmt.Printf("  NEGATIVE CONTROL: rename_skip_cycle_check=1 on both nodes\n")
		if err := setBoth("rename_skip_cycle_check", "1"); err != nil {
			return false, err
		}
	}
	if err := callOK(a, "mkdir", MkdirArgs{Path: dir}); err != nil {
		return false, fmt.Errorf("setup mkdir %s: %w", dir, err)
	}
	if err := setBoth("rename_prelock_stall_ms", "300"); err != nil {
		return false, err
	}

	ok := true
	crossed, lost := 0, 0
	for r := 0; r < rounds; r++ {
		top := fmt.Sprintf("%s/r%d", dir, r)
		P, Q := top+"/P", top+"/Q"
		for _, d := range []string{top, P, Q} {
			if err := callOK(a, "mkdir", MkdirArgs{Path: d}); err != nil {
				return false, fmt.Errorf("setup mkdir %s: %w", d, err)
			}
		}
		if err := callOK(a, "write", WriteArgs{Path: P + "/p", Size: 4096, Stamp: fmt.Sprintf("p%d", r)}); err != nil {
			return false, fmt.Errorf("setup write: %w", err)
		}
		if err := callOK(a, "write", WriteArgs{Path: Q + "/q", Size: 4096, Stamp: fmt.Sprintf("q%d", r)}); err != nil {
			return false, fmt.Errorf("setup write: %w", err)
		}
		// Both nodes look everything up first: their dentry caches
		// must hold P and Q side by side, as in the real race.
		for _, c := range two {
			for _, pth := range []string{P, Q, P + "/p", Q + "/q"} {
				if _, there, err := statPath(c, pth); err != nil || !there {
					return false, fmt.Errorf("setup: %s does not see %s (%v)", c.Name, pth, err)
				}
			}
		}

		var outA, outB callOutcome
		done := make(chan struct{}, 2)
		start := make(chan struct{})
		go func() {
			<-start
			resp, err := a.Call("rename", RenameArgs{Old: P, New: Q + "/P"})
			outA = callOutcome{client: a, resp: resp, err: err}
			done <- struct{}{}
		}()
		go func() {
			<-start
			resp, err := b.Call("rename", RenameArgs{Old: Q, New: P + "/Q"})
			outB = callOutcome{client: b, resp: resp, err: err}
			done <- struct{}{}
		}()
		close(start)
		<-done
		<-done
		if outA.err != nil || outB.err != nil {
			return false, fmt.Errorf("round %d: transport: %v / %v", r, outA.err, outB.err)
		}
		okA, okB := outA.resp.OK, outB.resp.OK
		fmt.Printf("  round %d: %s mv P Q/: %s; %s mv Q P/: %s\n", r, a.Name, verdict(outA), b.Name, verdict(outB))
		if okA && okB {
			crossed++
		}

		// What each node sees now.
		for _, c := range two {
			resp, err := c.Call("readdir", ReaddirArgs{Path: top})
			var rd ReaddirResult
			if err := decodeResult(c.Name, resp, err, &rd); err != nil {
				return false, fmt.Errorf("round %d: %s readdir %s: %w", r, c.Name, top, err)
			}
			names := append([]string(nil), rd.Names...)
			sort.Strings(names)
			got := strings.Join(names, ",")
			var want []string
			switch {
			case okA && !okB:
				want = []string{Q + "/q", Q + "/P/p"}
			case okB && !okA:
				want = []string{P + "/p", P + "/Q/q"}
			}
			reachable := (got == "Q" && okA && !okB) || (got == "P" && okB && !okA)
			if !reachable {
				lost++
			}
			if control {
				continue
			}
			check(&ok, fmt.Sprintf("round %d: %s sees exactly one of P/Q at the top", r, c.Name), reachable,
				fmt.Sprintf("listing [%s], %s ok=%v, %s ok=%v", got, a.Name, okA, b.Name, okB))
			for _, pth := range want {
				_, there, err := statPath(c, pth)
				check(&ok, fmt.Sprintf("round %d: %s reaches %s", r, c.Name, strings.TrimPrefix(pth, top+"/")),
					err == nil && there, fmt.Sprint(err))
			}
		}
	}
	_ = setBoth("rename_prelock_stall_ms", "0")

	if control {
		check(&ok, "control: both moves succeeded and the pair left the tree in some round -- the race is real",
			crossed > 0 && lost > 0, fmt.Sprintf("crossed=%d lost-views=%d", crossed, lost))
		if err := ensureUnmounted(clients); err != nil {
			return false, err
		}
		// fsck must see what the nodes saw, then the volume is rebuilt:
		// the cycle is on the device by design and would fail whatever
		// runs next.
		resp, e := a.Call("fsck", FsckArgs{})
		var fr FsckResult
		if err := decodeResult(a.Name, resp, e, &fr); err == nil {
			check(&ok, "control: fsck reports the damage", !fr.Clean, fmt.Sprintf("exit %d", fr.ExitCode))
		}
		var mr MkfsResult
		resp, e = a.Call("mkfs", MkfsArgs{Force: true})
		if err := decodeResult(a.Name, resp, e, &mr); err != nil || mr.ExitCode != 0 {
			fmt.Printf("WARNING: control: reformat failed (%v, exit %d): %s %s -- reformat the LUN by hand\n", err, mr.ExitCode, mr.Stdout, mr.Stderr)
		} else {
			fmt.Printf("  (control: the volume held a cycle by design and has been reformatted)\n")
		}
		return ok, nil
	}
	check(&ok, "no round let both moves through", crossed == 0, fmt.Sprintf("crossed=%d", crossed))

	if err := ensureUnmounted(clients); err != nil {
		return false, fmt.Errorf("unmount before fsck: %w", err)
	}
	resp, e := a.Call("fsck", FsckArgs{})
	var fr FsckResult
	if err := decodeResult(a.Name, resp, e, &fr); err != nil {
		check(&ok, "fsck ran", false, err.Error())
	} else {
		check(&ok, "fsck clean", fr.Clean, fmt.Sprintf("exit %d: %s", fr.ExitCode, fr.Output))
	}
	if ok {
		fmt.Printf("PASS: rename-loop: every crossing left one move done and the tree whole\n")
	} else {
		fmt.Printf("FAIL: rename-loop: see failed checks above\n")
	}
	return ok, nil
}

func verdict(o callOutcome) string {
	if o.resp.OK {
		return "done"
	}
	return "refused (" + o.resp.Error + ")"
}
