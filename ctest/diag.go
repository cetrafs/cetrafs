// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"fmt"
)

// RunDiag dumps each client's raw /proc/fs/cetrafs/<device>/ files and a
// dmesg tail, one client at a time (order doesn't matter here -- this
// isn't exercising a race, just collecting evidence after one happened).
// Exists so a real multi-node run can be troubleshot directly instead of
// asking whoever's driving the test to manually ssh in and copy-paste.
func RunDiag(clients []*Client, dmesgLines int) (bool, error) {
	for _, c := range clients {
		fmt.Printf("\n========== %s (%s) ==========\n", c.Name, c.Addr)

		resp, err := c.Call("proc_raw", ProcRawArgs{Device: c.Device})
		var raw ProcRawResult
		if err := decodeResult(c.Name, resp, err, &raw); err != nil {
			fmt.Printf("  proc_raw: %v\n", err)
		} else {
			fmt.Printf("---- %s: /proc/fs/cetrafs/%s/properties ----\n%s\n", c.Name, c.Device, raw.Properties)
			fmt.Printf("---- %s: /proc/fs/cetrafs/%s/info ----\n%s\n", c.Name, c.Device, raw.Info)
			fmt.Printf("---- %s: /proc/fs/cetrafs/%s/cluster ----\n%s\n", c.Name, c.Device, raw.Cluster)
		}

		resp, err = c.Call("dmesg_tail", DmesgTailArgs{Lines: dmesgLines})
		var dm DmesgTailResult
		if err := decodeResult(c.Name, resp, err, &dm); err != nil {
			fmt.Printf("  dmesg_tail: %v\n", err)
		} else {
			fmt.Printf("---- %s: dmesg (last %d lines) ----\n%s\n", c.Name, dmesgLines, dm.Text)
		}
	}
	return true, nil
}
