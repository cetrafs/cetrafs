// SPDX-License-Identifier: GPL-2.0-or-later
package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Parses /proc/fs/cetrafs/<device>/{info,cluster} -- see kmod/procfs.c's
// cetrafs_proc_info_show()/cetrafs_proc_cluster_show() for the exact
// seq_printf() formats these regexes match. Kept here rather than
// shelling out to anything: these are plain text files any process can
// just read.
var (
	reThisNodeID       = regexp.MustCompile(`^this_node_id:\s*(\d+)`)
	reMaxFileSizeBytes = regexp.MustCompile(`^max_file_size_bytes:\s*(\d+)`)
	reWriteReady       = regexp.MustCompile(`^write_ready:\s*(yes|no)`)
	reFenced           = regexp.MustCompile(`^fenced:\s*(yes|no)`)
	reCASMiscompares   = regexp.MustCompile(`^cas_miscompares:\s*(\d+)`)
	reScrubReclaimed   = regexp.MustCompile(`^scrub_reclaimed:\s*(\d+)`)
	reScrubCycles      = regexp.MustCompile(`^scrub_cycles:\s*(\d+)`)
	reJournalReplays   = regexp.MustCompile(`^journal_replays:\s*(\d+)`)
	reJournalDeclines  = regexp.MustCompile(`^journal_replay_declines:\s*(\d+)`)
	rePendingAppends   = regexp.MustCompile(`^pending_free_appends:\s*(\d+)`)

	// properties: "caw: class=scsi logical_block_size=512 max_caw_blocks=1 available=yes"
	reCAW = regexp.MustCompile(
		`^caw: class=(\S+) logical_block_size=(\d+) max_caw_blocks=(\d+) available=(yes|no)`)

	// "  zg 0: owner=0 (this node) first_bg=0 bg_count=5 free_data_blocks=655334"
	// "  zg 1: owner=none first_bg=5 bg_count=4 free_data_blocks=524268"
	//
	// journal_size_blocks is NOT matched: it disappeared from this line
	// when journals went per-node, and requiring it meant not one zg line
	// matched from that day on. Nothing complained, because an
	// unmatched line was silently skipped -- so every scenario that
	// reasons about zone-group ownership quietly saw NO owners:
	// pending-free skipped itself as "a owns no zone group", and
	// zg-fairness passed vacuously over an empty set. reZGPrefix below
	// is what stops that recurring: a line that looks like a zg line but
	// does not parse is now an error, not a shrug.
	reZGLine = regexp.MustCompile(
		`^\s*zg (\d+): owner=(none|\d+)(?: \(this node\))? first_bg=(\d+) bg_count=(\d+) free_data_blocks=(\d+)`)
	reZGPrefix = regexp.MustCompile(`^\s*zg \d+: owner=`)

	// "node 0: state=REGISTERED uuid=...-...-...-...-... hb_seq=8 last_seen=123 label=host1 stale=no (this node)"
	reNodeLine = regexp.MustCompile(
		`^node (\d+): state=(\S+) uuid=(\S+) hb_seq=(\d+) last_seen=(\d+) label=(\S+) stale=(\S+)`)
)

func readProcSnapshot(device string) (ProcSnapshotResult, error) {
	var out ProcSnapshotResult
	base := devPath("/proc/fs/cetrafs", device)

	if err := parseInfoFile(filepath.Join(base, "info"), &out); err != nil {
		return out, fmt.Errorf("info: %w", err)
	}
	if err := parseClusterFile(filepath.Join(base, "cluster"), &out); err != nil {
		return out, fmt.Errorf("cluster: %w", err)
	}
	// properties carries the device's atomic-CAW capability, which
	// decides whether every claim in this filesystem takes the real
	// compare-and-swap or the serialised fallback. A scenario that does
	// not check it can pass against a cluster running entirely on the
	// fallback.
	if err := parsePropertiesFile(filepath.Join(base, "properties"), &out); err != nil {
		return out, fmt.Errorf("properties: %w", err)
	}
	return out, nil
}

func parseInfoFile(path string, out *ProcSnapshotResult) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()

		if m := reThisNodeID.FindStringSubmatch(line); m != nil {
			out.ThisNodeID, _ = strconv.Atoi(m[1])
			continue
		}

		if m := reMaxFileSizeBytes.FindStringSubmatch(line); m != nil {
			out.MaxFileSizeBytes, _ = strconv.ParseInt(m[1], 10, 64)
			continue
		}

		if m := reWriteReady.FindStringSubmatch(line); m != nil {
			out.WriteReady = m[1] == "yes"
			continue
		}

		if m := reFenced.FindStringSubmatch(line); m != nil {
			out.Fenced = m[1] == "yes"
			continue
		}

		if m := reJournalReplays.FindStringSubmatch(line); m != nil {
			v, _ := strconv.ParseUint(m[1], 10, 64)
			out.JournalReplays = v
			continue
		}
		if m := reJournalDeclines.FindStringSubmatch(line); m != nil {
			v, _ := strconv.ParseUint(m[1], 10, 64)
			out.JournalReplayDeclines = v
			continue
		}
		if m := reScrubReclaimed.FindStringSubmatch(line); m != nil {
			out.ScrubReclaimed, _ = strconv.ParseUint(m[1], 10, 64)
		}
		if m := reScrubCycles.FindStringSubmatch(line); m != nil {
			out.ScrubCycles, _ = strconv.ParseUint(m[1], 10, 64)
		}
		if m := reCASMiscompares.FindStringSubmatch(line); m != nil {
			out.CASMiscompares, _ = strconv.ParseUint(m[1], 10, 64)
			continue
		}
		if m := rePendingAppends.FindStringSubmatch(line); m != nil {
			out.PendingFreeAppends, _ = strconv.ParseUint(m[1], 10, 64)
			continue
		}

		if m := reZGLine.FindStringSubmatch(line); m != nil {
			id, _ := strconv.Atoi(m[1])
			owner := -1
			if m[2] != "none" {
				owner, _ = strconv.Atoi(m[2])
			}
			firstBG, _ := strconv.Atoi(m[3])
			bgCount, _ := strconv.Atoi(m[4])
			free, _ := strconv.ParseUint(m[5], 10, 64)
			out.ZoneGroups = append(out.ZoneGroups, ZGInfo{
				ID:             id,
				Owner:          owner,
				ThisNode:       strings.Contains(line, "(this node)"),
				FirstBG:        firstBG,
				BGCount:        bgCount,
				FreeDataBlocks: free,
			})
			continue
		}

		// A zg line this parser could not read is a FAILURE, not
		// something to skip: silently skipping one is what hid the
		// journal_size_blocks removal and left every ownership-based
		// scenario looking at an empty set for weeks.
		if reZGPrefix.MatchString(line) {
			return fmt.Errorf("unparsable zone-group line (the info format changed?): %q", line)
		}
	}
	return sc.Err()
}

func parseClusterFile(path string, out *ProcSnapshotResult) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		m := reNodeLine.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		id, _ := strconv.Atoi(m[1])
		hbSeq, _ := strconv.ParseUint(m[4], 10, 64)
		lastSeen, _ := strconv.ParseUint(m[5], 10, 64)
		out.Nodes = append(out.Nodes, NodeInfo{
			ID:       id,
			State:    m[2],
			UUID:     m[3],
			HBSeq:    hbSeq,
			LastSeen: lastSeen,
			Label:    m[6],
			Stale:    m[7] == "yes",
			ThisNode: strings.Contains(line, "(this node)"),
		})
	}
	return sc.Err()
}

func parsePropertiesFile(path string, out *ProcSnapshotResult) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if m := reCAW.FindStringSubmatch(sc.Text()); m != nil {
			out.CAWClass = m[1]
			out.CAWLogicalBlockSize, _ = strconv.Atoi(m[2])
			out.CAWMaxBlocks, _ = strconv.Atoi(m[3])
			out.CAWAvailable = m[4] == "yes"
		}
	}
	return sc.Err()
}
