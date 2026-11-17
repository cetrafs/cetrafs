#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Class 57 scan (docs/internal/BUG-CLASSES.md): a tool function that
reads Node Registry rows -- the region peers on other hosts write while a
tool runs -- must drop this host's cached copy first in the same function
(posix_fadvise / a *_drop_cache helper / O_DIRECT, or read through
cetrafs_pread_device(), which goes to the device), or be named in the
allowlist given on the command line with why its callers do.

usage: c57_scan.py <allowlisted-function,...> <file>...
Prints file:function for each reader that drops nothing."""
import re
import sys


def strip(src):
    src = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return re.sub(r'"(\\.|[^"\\])*"', '""', src)


def functions(src):
    for m in re.finditer(r"^[A-Za-z_][^;{}\n]*?\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*\{", src, flags=re.M):
        depth, i = 0, m.end() - 1
        while i < len(src):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        yield m.group(1), src[m.end():i]


allow = set(filter(None, sys.argv[1].split(",")))
for path in sys.argv[2:]:
    for name, body in functions(strip(open(path).read())):
        reads = re.search(r"\bpread(_all)?\s*\(", body)
        rows = re.search(r"cetrafs_node_row_off\s*\(|cetrafs_le64\(\s*[\w>.-]*\bnode_table_start\s*\)", body)
        drops = re.search(r"posix_fadvise|drop_cache\s*\(|O_DIRECT|cetrafs_pread_device\s*\(", body)
        if reads and rows and not drops and name not in allow:
            print(f"{path}:{name}")
