// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"os"
	"path/filepath"
	"testing"
)

// A real /proc/fs/cetrafs/<dev>/info excerpt, captured from a running
// mount. The point of pinning real text is that the previous regex was
// written against a format that no longer exists -- it still required
// journal_size_blocks, removed when journals went per-node -- so not one
// zone-group line matched, and every scenario reasoning about ownership
// silently saw none. A fixture taken from the kernel's own output is
// what makes that a test failure instead of a quiet skip.
const realInfo = `device: loop0
this_node_id: 0
file_lock: on
free_data_blocks: 131065
  zg 0: owner=0 (this node) first_bg=0 bg_count=1 free_data_blocks=131065
  zg 1: owner=none first_bg=1 bg_count=2 free_data_blocks=262130
`

func writeTmp(t *testing.T, name, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestParseInfoZoneGroups(t *testing.T) {
	var out ProcSnapshotResult
	if err := parseInfoFile(writeTmp(t, "info", realInfo), &out); err != nil {
		t.Fatalf("parsing a real info file: %v", err)
	}
	if out.ThisNodeID != 0 {
		t.Fatalf("this_node_id: got %d want 0", out.ThisNodeID)
	}
	if len(out.ZoneGroups) != 2 {
		t.Fatalf("zone groups: got %d want 2 -- the zg lines did not parse", len(out.ZoneGroups))
	}
	z := out.ZoneGroups[0]
	if z.Owner != 0 || !z.ThisNode || z.FirstBG != 0 || z.BGCount != 1 || z.FreeDataBlocks != 131065 {
		t.Fatalf("zg 0 parsed wrong: %+v", z)
	}
	if out.ZoneGroups[1].Owner != -1 {
		t.Fatalf("zg 1 owner=none should parse as -1, got %d", out.ZoneGroups[1].Owner)
	}
}

// The durable half: a zg line this parser cannot read must be an ERROR.
// Silently skipping one is precisely how the stale regex hid for weeks.
func TestParseInfoRejectsUnknownZGFormat(t *testing.T) {
	bad := "this_node_id: 0\n  zg 0: owner=0 something_new=7\n"
	var out ProcSnapshotResult
	if err := parseInfoFile(writeTmp(t, "info", bad), &out); err == nil {
		t.Fatal("an unparsable zg line was accepted -- it must fail loudly instead")
	}
}
