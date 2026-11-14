package main

import (
	"strings"
	"testing"
)

// fuzzJudgeBlock: every verdict the content oracle can give, and the two
// it must not (zeros, and the file's own block in place).
func TestFuzzJudgeBlock(t *testing.T) {
	blk := func(fid, node string, off int64) []byte {
		b := make([]byte, dioBlock)
		blockStamp(b, fuzzStamp(fid, node), off)
		return b
	}
	torn := blk("aaaa", "n1", 8192)
	copy(torn[2048:], blk("aaaa", "n2", 8192)[2048:])
	cases := []struct {
		name string
		b    []byte
		off  int64
		want string
	}{
		{"zeros", make([]byte, dioBlock), 4096, ""},
		{"own", blk("aaaa", "n1", 4096), 4096, ""},
		{"own, other node", blk("aaaa", "n2", 4096), 4096, ""},
		{"foreign", blk("bbbb", "n1", 4096), 4096, "another file's block"},
		{"misplaced", blk("aaaa", "n1", 0), 4096, "from offset 0"},
		{"torn", torn, 8192, "torn"},
		{"garbage", []byte(strings.Repeat("x", dioBlock)), 0, "not a fuzz stamp"},
	}
	for _, c := range cases {
		got := fuzzJudgeBlock(c.b, "aaaa", c.off)
		if (c.want == "") != (got == "") || !strings.Contains(got, c.want) {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// fuzzJudgeLive: torn between two of this file's stamps is fine; another
// file's unit, or this file's from another offset, is not.
func TestFuzzJudgeLive(t *testing.T) {
	blk := func(fid, node string, off int64) []byte {
		b := make([]byte, dioBlock)
		blockStamp(b, fuzzStamp(fid, node), off)
		return b
	}
	torn := blk("aaaa", "n1", 8192)
	copy(torn[2048:], blk("aaaa", "n2", 8192)[2048:])
	cases := []struct {
		name string
		b    []byte
		off  int64
		want string
	}{
		{"zeros", make([]byte, dioBlock), 4096, ""},
		{"own", blk("aaaa", "n1", 4096), 4096, ""},
		{"torn between own stamps", torn, 8192, ""},
		{"foreign", blk("bbbb", "n1", 4096), 4096, "another file's block"},
		{"misplaced", blk("aaaa", "n1", 0), 4096, "from offset 0"},
	}
	for _, c := range cases {
		got := fuzzJudgeLive(c.b, "aaaa", c.off)
		if (c.want == "") != (got == "") || !strings.Contains(got, c.want) {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
