// SPDX-License-Identifier: GPL-2.0-or-later
package main

import "testing"

// The build gate's identity: what passes as "the same source" must be
// exactly the +src. suffix, and a version without one must not pass.
func TestModuleSourceID(t *testing.T) {
	cases := map[string]string{
		"0.9.2-5-gabc1234+src.0123456789ab":                "0123456789ab",
		"0.9.2-5-gabc1234-dirty.7a17e284+src.0123456789ab": "0123456789ab",
		"0.9.1-58-g3586a3a":                                "", // an old module: no source hash
		"0.9.2+src.":                                       "",
		"":                                                 "",
	}
	for in, want := range cases {
		if got := moduleSourceID(in); got != want {
			t.Errorf("moduleSourceID(%q) = %q, want %q", in, got, want)
		}
	}
}
