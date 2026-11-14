#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Class 54 scan (docs/internal/BUG-CLASSES.md): a non-re-entrant namespace
lock taken again, in the same task, while a path already holds it.

usage: ns_reentry_scan.py <kmod-dir>
Prints one line per finding:
    <file>:<holder> -> <callee> -> ... -> <file>:<acquirer>:<line>
Nothing printed means the tree holds.

Model. A HOLDER is a function with a namespace-lock acquire site
(cetrafs_nslock_acquire*, cetrafs_inode_ns_mutex_lock, or a raw
mutex_lock of ns_mutex). Its held region runs from the first acquire to
the next release (cetrafs_nslock_release*, cetrafs_inode_ns_mutex_unlock),
or to the end of the body. Every function CALLED inside that region runs
under the lock, so its whole body is walked, transitively. An acquire site
reached that way is a self-wait -- unless it is GUARDED: it sits in an
`if (!G)` block where G is assigned from cetrafs_inode_ns_held_by_current()
(xattr.c's nesting check), so a caller that already holds the lock skips it.

The acquire and release entry points are opaque: their own bodies are the
primitives. Edges the walk cannot follow as direct calls are supplied by
VFS_EDGES: setattr_prepare() reaches the xattr handlers' .set (killpriv
strips security.capability through vfs_removexattr), notify_change()
reaches the .setattr operations. A new indirect edge must be added there.

Negative control: tests/image/source_invariants.sh plants a holder that
reaches an unguarded acquire by a direct call and through VFS_EDGES, and
runs this scan on a copy of kmod/ whose nesting guard is removed.
"""
import os
import re
import sys

ACQUIRE = re.compile(r"\b(cetrafs_nslock_acquire\w*|cetrafs_inode_ns_mutex_lock)\s*\(|"
                     r"\bmutex_lock\w*\s*\(\s*&[^;]*ns_mutex")
RELEASE = re.compile(r"\b(cetrafs_nslock_release\w*|cetrafs_inode_ns_mutex_unlock)\s*\(")
OPAQUE = {"cetrafs_nslock_acquire", "cetrafs_nslock_acquire_set", "cetrafs_nslock_acquire_set_vfs",
          "cetrafs_nslock_acquire_tries", "__cetrafs_nslock_acquire_set", "cetrafs_inode_ns_mutex_lock",
          "cetrafs_inode_ns_mutex_unlock", "cetrafs_nslock_release", "cetrafs_nslock_release_set"}
KEYWORDS = {"if", "while", "for", "switch", "return", "sizeof", "do", "else"}
VFS_EDGES = {
    "setattr_prepare": "xattr-set",
    "vfs_removexattr": "xattr-set",
    "__vfs_removexattr": "xattr-set",
    "vfs_setxattr": "xattr-set",
    "__vfs_setxattr": "xattr-set",
    "__vfs_setxattr_noperm": "xattr-set",
    "notify_change": "setattr-op",
}
MAX_DEPTH = 12


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


def guard_names(body):
    return set(re.findall(r"\b(\w+)\s*=[^;]*held_by_current\s*\(", body))


def _guard_cond(cond, guards):
    return "held_by_current(" in cond or any(
        re.search(r"!\s*" + re.escape(g) + r"\b", cond) for g in guards)


def guarded(body, pos, guards):
    """True if the site is the statement of `if (... !G ...)` (braced or not)."""
    lead = re.search(r"\bif\s*\(([^{};]*)\)\s*(?:return\s+|[\w.>-]+\s*=\s*)?$", body[max(0, pos - 300):pos])
    if lead:
        return _guard_cond(lead.group(1), guards)
    depth = 0
    i = pos - 1
    while i >= 0:
        c = body[i]
        if c == "}":
            depth += 1
        elif c == "{":
            if depth == 0:
                head = body[max(0, i - 400):i]
                m = re.search(r"\bif\s*\(([^{};]*)\)\s*$", head)
                if not m:
                    return False
                return _guard_cond(m.group(1), guards)
            depth -= 1
        i -= 1
    return False


def unguarded_acquires(body):
    guards = guard_names(body)
    return [m.start() for m in ACQUIRE.finditer(body) if not guarded(body, m.start(), guards)]


def region_end(body, start):
    m = RELEASE.search(body, start)
    return m.start() if m else len(body)


def calls_in(text):
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\(", text):
        if m.group(1) not in KEYWORDS:
            yield m.group(1)


def main(kdir):
    funcs = {}          # name -> (file, body)
    handlers = set()    # xattr handler .set targets
    setattr_ops = set() # .setattr operation targets
    for fn in sorted(os.listdir(kdir)):
        if not fn.endswith(".c"):
            continue
        src = strip(open(os.path.join(kdir, fn), encoding="utf-8", errors="replace").read())
        if fn == "xattr.c":
            handlers.update(m.group(1) for m in re.finditer(r"\.set\s*=\s*(\w+)", src))
        setattr_ops.update(m.group(1) for m in re.finditer(r"\.setattr\s*=\s*(\w+)", src))
        for name, body in functions(src):
            funcs.setdefault(name, (fn, body))
    vfs_targets = {"xattr-set": handlers, "setattr-op": setattr_ops}

    findings = []
    seen = set()

    def report(holder, hfile, path):
        """path: the hops from the holder to the function holding the self-wait."""
        target = path[-1]
        tfile, tbody = funcs[target]
        line = tbody[:unguarded_acquires(tbody)[0]].count("\n") + 1
        key = (holder, tuple(path))
        if key not in seen:
            seen.add(key)
            findings.append("%s:%s -> %s -> %s:%d" % (hfile, holder, " -> ".join(path), tfile, line))

    def walk(holder, hfile, region, path, depth, on_path):
        """Every call in region runs under the holder's lock; path leads to region."""
        for callee in calls_in(region):
            if callee in OPAQUE or callee == holder:
                continue
            # A VFS entry point reaches module targets through a table; the
            # entry point's name stays in the path as the hop.
            if callee in VFS_EDGES:
                steps = [[callee, t] for t in sorted(vfs_targets[VFS_EDGES[callee]])]
            else:
                steps = [[callee]]
            for step in steps:
                t = step[-1]
                if t not in funcs or t in OPAQUE or t in on_path or depth >= MAX_DEPTH:
                    continue
                tbody = funcs[t][1]
                if unguarded_acquires(tbody):
                    report(holder, hfile, path + step)
                walk(holder, hfile, tbody, path + step, depth + 1, on_path | {t})

    for name, (fn, body) in funcs.items():
        if name in OPAQUE:
            continue
        raw = [m.start() for m in ACQUIRE.finditer(body)]
        if not raw:
            continue
        first = raw[0]
        end = region_end(body, first)
        # A second unguarded acquire inside the same held region: a direct self-wait.
        for s in unguarded_acquires(body):
            # Only a second acquire in a later statement or branch: two
            # acquires joined by one ?: expression are alternatives.
            if first < s < end and re.search(r"[;}]", body[first:s]):
                line = body[:s].count("\n") + 1
                key = (name, (), name)
                if key not in seen:
                    seen.add(key)
                    findings.append("%s:%s -> %s:%d (direct)" % (fn, name, fn, line))
        walk(name, fn, body[first:end], [], 0, {name})
    for f in findings:
        print(f)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
