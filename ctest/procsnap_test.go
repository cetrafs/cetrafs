// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
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
  zg 0: owner=0 (this node) block_groups=1 free_data_blocks=131065
  zg 1: owner=none block_groups=2 free_data_blocks=262130
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
	if z.Owner != 0 || !z.ThisNode || z.FirstBG != -1 || z.BGCount != 1 || z.FreeDataBlocks != 131065 {
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

// Same discipline for the cluster file. The node-line regex has now
// drifted from the kernel's emitter THREE times (journal_size_blocks,
// caps=, then stale_secs= and departure= in format 0x000A), and every
// time the symptom was silence: Nodes stayed empty and every
// staleness-driven scenario waited forever on a peer that was long
// stale. The fixture is the kernel's real output; the assertion that
// bites is Stale=yes actually parsing as true. TestNodeLineTracksEmitter
// below checks the field order against procfs.c itself, so the fixture
// going stale with the regex is no longer enough to hide a drift.
const realCluster = `node 0: state=REGISTERED uuid=00112233-4455-6677-8899-aabbccddeeff hb_seq=42 last_seen=12345 label=nodeA caps=0x1 stale_secs=120 departure=none stale=no (this node)
node 1: state=REGISTERED uuid=ffeeddcc-bbaa-9988-7766-554433221100 hb_seq=7 last_seen=99 label=nodeB caps=0x0 stale_secs=15 departure=dead stale=yes
`

func TestParseClusterNodes(t *testing.T) {
	var out ProcSnapshotResult
	if err := parseClusterFile(writeTmp(t, "cluster", realCluster), &out); err != nil {
		t.Fatalf("parsing a real cluster file: %v", err)
	}
	if len(out.Nodes) != 2 {
		t.Fatalf("nodes: got %d want 2 -- the node lines did not parse", len(out.Nodes))
	}
	if !out.Nodes[0].ThisNode || out.Nodes[0].Stale || out.Nodes[0].HBSeq != 42 {
		t.Fatalf("node 0 parsed wrong: %+v", out.Nodes[0])
	}
	if !out.Nodes[1].Stale || out.Nodes[1].Label != "nodeB" {
		t.Fatalf("node 1 must parse stale=yes: %+v", out.Nodes[1])
	}
	if out.Nodes[0].StaleSecs != 120 || out.Nodes[1].StaleSecs != 15 || out.Nodes[1].Departure != "dead" {
		t.Fatalf("stale_secs/departure parsed wrong: %+v / %+v", out.Nodes[0], out.Nodes[1])
	}
}

// A node line the pattern cannot read must fail the snapshot, not be
// skipped: skipping is exactly the silence described above.
func TestParseClusterRejectsUnknownNodeLine(t *testing.T) {
	var out ProcSnapshotResult
	bad := "node 0: state=REGISTERED uuid=x hb_seq=1 last_seen=1 label=a caps=0x1 newfield=7 stale=no\n"
	if err := parseClusterFile(writeTmp(t, "cluster", bad), &out); err == nil {
		t.Fatalf("an unparsable node line was accepted (nodes=%+v) -- it must fail loudly instead", out.Nodes)
	}
}

// The parser must track the emitter: read the key order of the node
// line straight out of kmod/procfs.c's format string and require the
// regex to name the same keys in the same order.
func TestNodeLineTracksEmitter(t *testing.T) {
	src, err := os.ReadFile("../kmod/procfs.c")
	if err != nil {
		t.Skipf("no kernel source next to ctest: %v", err)
	}
	i := strings.Index(string(src), `"node %u: state=`)
	if i < 0 {
		t.Fatal("procfs.c no longer emits a \"node %u: state=\" line -- update this test and the parser")
	}
	// The format is a run of adjacent string literals ending at the
	// first argument; join them.
	var format strings.Builder
	rest := string(src[i:])
	for {
		rest = strings.TrimLeft(rest, " \t\n")
		if !strings.HasPrefix(rest, `"`) {
			break
		}
		end := strings.Index(rest[1:], `"`)
		if end < 0 {
			t.Fatal("unterminated format literal in procfs.c")
		}
		format.WriteString(rest[1 : end+1])
		rest = rest[end+2:]
	}
	keys := regexp.MustCompile(`([a-z_]+)=`)
	var emitted, parsed []string
	for _, m := range keys.FindAllStringSubmatch(format.String(), -1) {
		emitted = append(emitted, m[1])
	}
	for _, m := range keys.FindAllStringSubmatch(reNodeLine.String(), -1) {
		parsed = append(parsed, m[1])
	}
	if strings.Join(emitted, " ") != strings.Join(parsed, " ") {
		t.Fatalf("procfs.c emits keys %v, reNodeLine parses %v -- the parser has drifted from the emitter", emitted, parsed)
	}
}
