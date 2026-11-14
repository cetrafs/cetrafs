#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# le_const_scan.py -- find on-disk __le* fields stored to, or compared with,
# a bare constant (audit C11). Prints one "file:line: text" per violation.
#
# Why: sparse (make endian-check) flags a host integer assigned to a
# __le field only when the constant is non-zero, so `rec.lock_mode =
# CETRAFS_LOCK_NONE` and `hdr->state == 0` pass the sparse build on any
# host. The stored VALUE is wrong on a big-endian host the moment the
# constant is not zero, and a compare against it is wrong whenever the
# field is read without conversion.
#
# How: the field is resolved, not matched by name. The base of each
# member chain (`rec.lock_mode`, `de[e].inode`, `raw->eh.eh_depth`) is
# given the type of its nearest declaration, and each member is looked up
# in the struct definitions of include/cetrafs.h. Designated initialisers
# (`T v = { .field = CONST }`, possibly over several lines) are resolved
# against T. A name shared by a host field and an __le field is therefore
# judged per site, not per name.
#
# Usage: le_const_scan.py <tree-root> [--self-test]
# Exit 0 with no output when clean; exit 1 with the violations otherwise.
import os
import re
import sys

KEYWORDS = {"return", "else", "goto", "case", "sizeof", "typedef", "struct", "union", "enum", "if", "while",
            "for", "do", "switch", "const", "static", "inline", "void", "int", "unsigned", "long", "u8", "u16",
            "u32", "u64", "bool", "char"}
LE_TYPES = {"__le16": 16, "__le32": 32, "__le64": 64}
CONST_RHS = r'\(?\s*-?\s*(?:[A-Z][A-Z0-9_]*\b|\d+[uUlL]*\b)'


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def match_brace(text, i):
    """text[i] == '{'; return the index of its matching '}' (or -1)."""
    depth = 0
    for j in range(i, len(text)):
        c = text[j]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return j
    return -1


def parse_structs(header):
    """Map struct tag and typedef name -> {field: type-word} (type-word is 'le16'/'le32'/'le64'
    for on-disk fields, the C type otherwise). Nested struct bodies are recorded as 'nested'."""
    structs = {}
    for m in re.finditer(r'\b(typedef\s+)?struct\s*(\w*)\s*\{', header):
        open_at = m.end() - 1
        close = match_brace(header, open_at)
        if close < 0:
            continue
        body = header[open_at + 1:close]
        fields = {}
        depth = 0
        cur = ""
        for c in body:
            if c == '{':
                depth += 1
            if c == '}':
                depth -= 1
            if c == ';' and depth == 0:
                decl = cur.strip()
                cur = ""
                if not decl or '(' in decl and '[' not in decl and '*' not in decl.split('(')[0]:
                    continue
                dm = re.match(r'(.*?)\b([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*$', decl, re.S)
                if not dm:
                    continue
                tyw = dm.group(1).replace("CETRA_PACKED", " ").strip()
                name = dm.group(2)
                if "{" in tyw or not tyw:
                    tyw = "nested"
                tword = tyw.split()[0] if tyw.split() else ""
                fields[name] = "le" + str(LE_TYPES[tword]) if tword in LE_TYPES else tyw.replace("*", "").strip()
                if tyw.endswith("*") or "*" in tyw:
                    fields[name] = "ptr:" + fields[name]
            else:
                cur += c
        tag = m.group(2)
        tail = header[close + 1:close + 200]
        if m.group(1):  # typedef struct [tag] {...} [CETRA_PACKED] name;
            tm = re.match(r'\s*(?:CETRA_PACKED|__attribute__\(\(packed\)\))?\s*([A-Za-z_]\w*)', tail)
            if tm:
                structs[tm.group(1)] = fields
        if tag:
            structs[tag] = fields
    return structs


def struct_type_of(decltype):
    t = re.sub(r'\b(const|volatile|struct|union)\b', ' ', decltype).strip()
    return t.split()[-1] if t.split() else ""


def find_decl_type(src, pos, name):
    """Nearest declaration of `name` before pos: its (non-pointer-stripped) type word, or None."""
    pat = re.compile(r'(?<![\w.>])((?:const\s+|volatile\s+|struct\s+|union\s+)*[A-Za-z_]\w*)\s*(\*+\s*)?'
                     r'(?:const\s+)?\b%s\b\s*(?:\[[^\]]*\])?\s*(?=[;=,)\[{]|$)' % re.escape(name), re.M)
    best = None
    for m in pat.finditer(src, 0, pos):
        t = m.group(1).split()[-1]
        if t in KEYWORDS:
            continue
        best = (t, bool(m.group(2)))
    return best


def scan_file(path, structs, violations):
    raw = open(path, errors="replace").read()
    src = strip_comments(raw)
    lines_at = [0]
    for ch_i, ch in enumerate(src):
        if ch == '\n':
            lines_at.append(ch_i + 1)

    def lineno(pos):
        lo, hi = 0, len(lines_at) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if lines_at[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def le_of(tname, member):
        fields = structs.get(tname)
        return fields.get(member) if fields else None

    # 1. member chains: BASE(.|->)MEMBER... (==|!=|=) CONST
    chain = re.compile(r'(?<![\w.>])([A-Za-z_]\w*)((?:\s*\[[^\]\n]*\])?(?:\s*(?:\.|->)\s*[A-Za-z_]\w*(?:\s*\[[^\]\n]*\])?)+)'
                       r'\s*(==|!=|=(?!=))\s*(' + CONST_RHS + r')')
    for m in chain.finditer(src):
        base = m.group(1)
        rest = re.sub(r'\s+', '', m.group(2))
        members = re.findall(r'(?:\.|->)([A-Za-z_]\w*)', rest)
        if not members:
            continue
        # the type of the base: its declaration; a pointer or array is the same struct either way
        found = find_decl_type(src, m.start(), base)
        if not found:
            continue
        tname = struct_type_of(found[0])
        ok = True
        for mem in members[:-1]:
            nxt = le_of(tname, mem)
            if nxt is None:
                ok = False
                break
            tname = struct_type_of(nxt.replace("ptr:", ""))
        if not ok:
            continue
        final = le_of(tname, members[-1])
        if final and final.startswith("le"):
            violations.append((path, lineno(m.start()), m.group(0), final, m.group(3), m.group(4), "chain"))

    # 2. designated initialisers: TYPE var = { ... .field = CONST ... }
    init = re.compile(r'\b((?:struct\s+)?[A-Za-z_]\w*)\s+[A-Za-z_]\w*\s*(?:\[[^\]]*\])?\s*=\s*\{')
    for m in init.finditer(src):
        tname = m.group(1).split()[-1]
        if tname in KEYWORDS or tname not in structs:
            continue
        open_at = m.end() - 1
        close = match_brace(src, open_at)
        if close < 0:
            continue
        body = src[open_at + 1:close]
        depth = 0
        for dm in re.finditer(r'[{}]|(?<![\w.>])\.\s*([A-Za-z_]\w*)\s*=\s*(' + CONST_RHS + r')', body):
            if dm.group(0) == '{':
                depth += 1
            elif dm.group(0) == '}':
                depth -= 1
            elif depth == 0:
                fld = le_of(tname, dm.group(1))
                if fld and fld.startswith("le"):
                    violations.append((path, lineno(open_at + 1 + dm.start()), dm.group(0), fld, "=", dm.group(2),
                                       "init"))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = sys.argv[1]
    hdr_path = os.path.join(root, "include", "cetrafs.h")
    structs = parse_structs(strip_comments(open(hdr_path, errors="replace").read()))
    files = []
    for sub in ("kmod", "userspace", "include"):
        for dp, _, fns in os.walk(os.path.join(root, sub)):
            for fn in fns:
                if fn.endswith((".c", ".h")):
                    files.append(os.path.join(dp, fn))
    violations = []
    for f in sorted(files):
        scan_file(f, structs, violations)
    for path, line, text, width, op, rhs, kind in violations:
        print("%s:%d: %s" % (os.path.relpath(path, root), line, text))
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
