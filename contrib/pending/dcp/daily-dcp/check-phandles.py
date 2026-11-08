#!/usr/bin/env python3
"""Check which display nodes of a J716s DTB have a phandle (what dt_set_display_t6050() needs).

Usage: check-phandles.py [--expect-missing|--expect-present] file.dtb [file.dtb ...]
With no flag it just prints. Needs `dtc` on PATH (no pylibfdt). Exit 1 if an expectation fails.

The five nodes: the dcp (apple,t6050-dcp), the display subsystem (apple,display-subsystem), the DARTs the dcp and the
display subsystem name in iommus, and the mailbox the dcp names in mboxes.
"""
import re, subprocess, sys


def parse(dtb):
    out = subprocess.run(["dtc", "-q", "-I", "dtb", "-O", "dts", dtb], check=True, capture_output=True, text=True).stdout
    root = {"name": "/", "props": {}, "kids": [], "path": ""}
    stack = [root]
    for line in out.splitlines():
        line = line.strip()
        m = re.match(r"^([\w@,.+-]*(?:/)?)\s*\{$", line)
        if m:
            name = m.group(1) or "/"
            if len(stack) == 1 and name == "/":
                continue
            n = {"name": name, "props": {}, "kids": [], "path": stack[-1]["path"] + "/" + name}
            stack[-1]["kids"].append(n)
            stack.append(n)
        elif line == "};":
            if len(stack) > 1:
                stack.pop()
        elif line.endswith(";"):
            k, _, v = line[:-1].partition("=")
            stack[-1]["props"][k.strip()] = v.strip()
    return root


def walk(n):
    yield n
    for k in n["kids"]:
        yield from walk(k)


def cells(v):
    m = re.match(r"^<(.*)>$", v or "")
    return [int(x, 16) if x.startswith("0x") else int(x) for x in m.group(1).split()] if m else []


def main():
    args = sys.argv[1:]
    mode = None
    while args and args[0].startswith("--"):
        a = args.pop(0)
        mode = {"--expect-missing": "missing", "--expect-present": "present"}[a]
    ok = True
    for dtb in args:
        nodes = list(walk(parse(dtb)))
        byph = {}
        for n in nodes:
            ph = cells(n["props"].get("phandle"))
            if ph:
                byph[ph[0]] = n

        def by_compat(c):
            r = [n for n in nodes if c in n["props"].get("compatible", "")]
            assert len(r) == 1, (c, len(r))
            return r[0]

        def ref(n, prop):
            c = cells(n["props"].get(prop))
            return byph.get(c[0]) if c else None

        dcp, disp = by_compat('"apple,t6050-dcp"'), by_compat('"apple,display-subsystem"')
        found = [("dcp", dcp), ("display-subsystem", disp), ("dart-dcp (dcp iommus)", ref(dcp, "iommus")),
                 ("dart-disp0 (display-subsystem iommus)", ref(disp, "iommus")), ("mailbox (dcp mboxes)", ref(dcp, "mboxes"))]
        print(dtb)
        for label, n in found:
            if n is None:
                print(f"  {label:42s} UNRESOLVED (iommus/mboxes phandle does not name a node with a phandle)")
                ok = False
                continue
            ph = cells(n["props"].get("phandle"))
            print(f"  {label:42s} {n['path']:60s} phandle {hex(ph[0]) if ph else 'NONE'}")
        has = [bool(n and cells(n["props"].get("phandle"))) for _, n in found]
        want_missing = [True, True, False, False, False]
        if mode == "missing":
            good = [(not h) if w else h for h, w in zip(has, want_missing)]
        elif mode == "present":
            good = has
        else:
            good = [True] * 5
        if not all(good):
            ok = False
            print("  EXPECTATION FAILED")
        elif mode:
            print("  as expected")
    sys.exit(0 if ok else 1)


main()
