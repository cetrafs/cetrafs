package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// RunRepairClaimRace: two nodes' repairers race for the volume's repair
// claim, through the array's COMPARE AND WRITE.
//
// fsck -r and growfs take a Node Registry row in REPAIR before they
// write, as a SCSI COMPARE AND WRITE through SG_IO where the device has
// it (userspace/devutil.h). tests/kernel/repair_claim_caw.sh races two
// repairers on one host against a LIO loopback disk; here they are on
// two nodes and the device is the real array.
//
// B (on the second node) reads a FREE row and is held 7 s before its
// claim (CETRAFS_TEST_REPAIR_CLAIM_GAP_SECS); A (on the first) starts a
// second later, claims, settles and holds 16 s. B's late claim must
// miscompare: B never reaches its repair, and A keeps its claim.
//
// Negative control (CTEST_REPAIR_CONTROL=1): CETRAFS_TEST_TOOLS_NO_CAW
// on both, the blind write a device without CAW still takes -- B then
// lands on A's claim, proving the staging reaches the race.
func RunRepairClaimRace(clients []*Client, baseDir string) (bool, error) {
	if len(clients) < 2 {
		return false, fmt.Errorf("repair-claim-race needs at least 2 clients")
	}
	a, b := clients[0], clients[1]
	control := os.Getenv("CTEST_REPAIR_CONTROL") != ""
	if err := ensureUnmounted(clients); err != nil {
		return false, err
	}
	var env []string
	if control {
		fmt.Printf("  NEGATIVE CONTROL: CETRAFS_TEST_TOOLS_NO_CAW=1 on both repairers\n")
		env = []string{"CETRAFS_TEST_TOOLS_NO_CAW=1"}
	}
	fmt.Printf("=== repair-claim-race: fsck -r on %s (late claim) and %s, through the array's CAW ===\n", b.Name, a.Name)

	type res struct {
		r   FsckResult
		err error
	}
	run := func(c *Client, extra ...string) chan res {
		ch := make(chan res, 1)
		go func() {
			resp, e := c.Call("fsck", FsckArgs{Repair: true, Env: append(append([]string{}, env...), extra...)})
			var fr FsckResult
			err := decodeResult(c.Name, resp, e, &fr)
			ch <- res{fr, err}
		}()
		return ch
	}
	chB := run(b, "CETRAFS_TEST_REPAIR_CLAIM_GAP_SECS=7", "CETRAFS_TEST_REPAIR_HOLD_SECS=8")
	time.Sleep(time.Second)
	chA := run(a, "CETRAFS_TEST_REPAIR_HOLD_SECS=16")
	rb, ra := <-chB, <-chA
	if rb.err != nil || ra.err != nil {
		return false, fmt.Errorf("fsck: %v / %v", rb.err, ra.err)
	}
	bIn := strings.Contains(rb.r.Output, "claimed registry row")
	aLost := strings.Contains(ra.r.Output, "claim was taken away")
	aIn := strings.Contains(ra.r.Output, "claimed registry row")
	fmt.Printf("  %s (late): reached its repair=%v; %s: claimed=%v lost it=%v\n", b.Name, bIn, a.Name, aIn, aLost)

	ok := true
	if !aIn {
		check(&ok, "setup: "+a.Name+" took the claim", false, firstLine(ra.r.Output))
		return false, nil
	}
	if control {
		check(&ok, "control: without CAW the late claimant lands on the claim", bIn || aLost,
			fmt.Sprintf("B in=%v A lost=%v", bIn, aLost))
		return ok, nil
	}
	check(&ok, "the late claimant never reached its repair", !bIn, lastLines(rb.r.Output, 4))
	check(&ok, a.Name+" kept its claim", !aLost, lastLines(ra.r.Output, 4))

	resp, e := a.Call("fsck", FsckArgs{})
	var fr FsckResult
	if err := decodeResult(a.Name, resp, e, &fr); err != nil {
		check(&ok, "fsck ran", false, err.Error())
	} else {
		check(&ok, "fsck clean afterwards, no claim left behind", fr.Clean, firstLine(fr.Output))
	}
	if ok {
		fmt.Printf("PASS: repair-claim-race\n")
	} else {
		fmt.Printf("FAIL: repair-claim-race: see failed checks above\n")
	}
	return ok, nil
}

func lastLines(s string, n int) string {
	l := strings.Split(strings.TrimSpace(s), "\n")
	if len(l) > n {
		l = l[len(l)-n:]
	}
	return strings.Join(l, " | ")
}
