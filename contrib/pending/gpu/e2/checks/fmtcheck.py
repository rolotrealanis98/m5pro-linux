#!/usr/bin/env python3
"""Lines a commit range adds to .rs files that rustfmt (the tree's .rustfmt.toml) would change.

usage: fmtcheck.py <tree> <base> [head]   -> prints offending lines, exit 1 if any
"""
import difflib, os, re, subprocess, sys, tempfile
tree, base = sys.argv[1], sys.argv[2]
head = sys.argv[3] if len(sys.argv) > 3 else "HEAD"
git = lambda *a: subprocess.run(["git", "-C", tree, *a], check=True, capture_output=True, text=True).stdout
bad = 0
for f in git("diff", "--name-only", base, head, "--", "*.rs").split():
    try:
        text = git("show", f"{head}:{f}")
    except subprocess.CalledProcessError:
        continue
    added = set()
    for h in re.finditer(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", git("diff", "-U0", base, head, "--", f), re.M):
        start, n = int(h.group(1)), int(h.group(2) or 1)
        added.update(range(start, start + n))
    with tempfile.NamedTemporaryFile("w", suffix=".rs", delete=False) as t:
        t.write(text)
    subprocess.run(["rustfmt", "--edition", "2021", "--config-path", os.path.join(tree, ".rustfmt.toml"), t.name],
                   capture_output=True)
    fmt = open(t.name).read().split("\n"); os.unlink(t.name)
    lines = text.split("\n")
    sm = difflib.SequenceMatcher(None, lines, fmt, autojunk=False)
    changed = set()
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op != "equal":
            changed.update(range(i1 + 1, max(i2, i1 + 1) + 1))
    hits = sorted(changed & added)
    print(f"{f}: {len(added)} added lines, {len(hits)} not rustfmt-clean")
    for n in hits[:40]:
        print(f"  {n}: {lines[n-1] if n <= len(lines) else ''}")
    bad += len(hits)
sys.exit(1 if bad else 0)
