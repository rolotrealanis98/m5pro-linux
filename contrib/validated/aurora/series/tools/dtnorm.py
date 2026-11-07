#!/usr/bin/env python3
"""dtnorm.py FILE.dtb [--order]

Print a DTB as one sorted line per property, "path: name = value", with every
phandle cell replaced by "&{/path/of/target}", so two DTBs built from different
sources (different node order, different phandle numbering) can be compared with
diff. The phandle/linux,phandle properties themselves are dropped. --order prints
the child order of every node instead (to catch order that matters, e.g. /cpus).
"""
import struct, sys, re

def parse(blob):
    magic, totalsize, off_struct, off_strings, off_rsv, ver, lcv, bcpu, sz_str, sz_struct = struct.unpack(">10I", blob[:40])
    assert magic == 0xd00dfeed
    strings = blob[off_strings:off_strings + sz_str]
    def getstr(o):
        return strings[o:strings.index(b"\0", o)].decode()
    p = off_struct
    root = None
    stack = []
    while True:
        tok, = struct.unpack(">I", blob[p:p+4]); p += 4
        if tok == 1:
            e = blob.index(b"\0", p)
            name = blob[p:e].decode(); p = (e + 4) & ~3
            node = {"name": name, "props": {}, "children": [], "parent": stack[-1] if stack else None}
            if stack: stack[-1]["children"].append(node)
            else: root = node
            stack.append(node)
        elif tok == 2:
            stack.pop()
        elif tok == 3:
            ln, no = struct.unpack(">II", blob[p:p+8]); p += 8
            val = blob[p:p+ln]; p = (p + ln + 3) & ~3
            stack[-1]["props"][getstr(no)] = val
        elif tok == 4:
            continue
        elif tok == 9:
            break
    return root

def path(n):
    if n["parent"] is None: return "/"
    pp = path(n["parent"])
    return (pp if pp != "/" else "") + "/" + n["name"]

def walk(n):
    yield n
    for c in n["children"]:
        yield from walk(c)

def cells(v):
    return list(struct.unpack(">%dI" % (len(v)//4), v)) if len(v) % 4 == 0 else None

def u32(n, name, default=None):
    v = n["props"].get(name)
    return struct.unpack(">I", v)[0] if v is not None and len(v) == 4 else default

# property -> name of the provider's #cells property (None: plain phandle list)
LIST = {
    "clocks": "#clock-cells", "power-domains": "#power-domain-cells", "resets": "#reset-cells",
    "iommus": "#iommu-cells", "mboxes": "#mbox-cells", "phys": "#phy-cells",
    "interrupts-extended": "#interrupt-cells", "pwms": "#pwm-cells", "dmas": "#dma-cells",
    "sound-dai": "#sound-dai-cells", "performance-domains": "#performance-domain-cells",
    "thermal-sensors": "#thermal-sensor-cells", "io-channels": "#io-channel-cells",
    "nvmem-cells": None, "memory-region": None, "cpu-idle-states": None, "apple,sart": None,
    "next-level-cache": None, "operating-points-v2": None, "interrupt-parent": None,
    "remote-endpoint": None, "msi-parent": "#msi-cells", "apple,helper-cpu": "#helper-cells",
    "power-supply": None, "cpu": None, "cpus": None, "apple,dcp": None, "apple,dcp-dart": None,
    "apple,asc-dram-mask": None, "sound-dai-0": None, "apple,pmgr-misc": None,
    "apple,smc": None, "rtkit-helper": None, "apple,coprocessor": None,
    "pinctrl-0": None, "pinctrl-1": None, "apple,dart": None,
}

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    blob = open(args[0], "rb").read()
    root = parse(blob)
    nodes = list(walk(root))
    ph = {}
    for n in nodes:
        for k in ("phandle", "linux,phandle"):
            if k in n["props"]:
                ph[u32(n, k)] = n
    def ref(v):
        return "&{%s}" % path(ph[v]) if v in ph else "<BADPH 0x%x>" % v
    if "--order" in sys.argv:
        for n in nodes:
            if n["children"]:
                print(path(n) + ": " + " ".join(c["name"] for c in n["children"]))
        return
    out = []
    for n in nodes:
        P = path(n)
        if not n["props"] and not n["children"]:
            out.append("%s: (empty node)" % P)
        out.append("%s: (node)" % P)
        for name, v in n["props"].items():
            if name in ("phandle", "linux,phandle"):
                continue
            c = cells(v)
            s = None
            if c is not None and (name in LIST or name.endswith("-gpios") or name == "gpios" or name.endswith("-gpio")):
                key = LIST.get(name, "#gpio-cells")
                items, i = [], 0
                try:
                    while i < len(c):
                        t = c[i]; i += 1
                        if t == 0 and key is not None:
                            items.append("<0>"); continue
                        nc = u32(ph[t], key, 0) if key else 0
                        items.append("<%s%s>" % (ref(t), "".join(" 0x%x" % x for x in c[i:i+nc])))
                        i += nc
                    s = ", ".join(items)
                except KeyError:
                    s = None
            elif c is not None and name == "interrupt-map":
                ac = u32(n, "#address-cells", 0); ic = u32(n, "#interrupt-cells", 1)
                items, i = [], 0
                while i < len(c):
                    child = c[i:i+ac+ic]; i += ac + ic
                    par = ph[c[i]]; i += 1
                    pac = u32(par, "#address-cells", 0); pic = u32(par, "#interrupt-cells", 1)
                    rest = c[i:i+pac+pic]; i += pac + pic
                    items.append("<%s %s %s>" % (" ".join("0x%x" % x for x in child), ref(par_ph(par)), " ".join("0x%x" % x for x in rest)))
                s = ", ".join(items)
            elif c is not None and name == "gpio-ranges":
                s = ", ".join("<%s 0x%x 0x%x 0x%x>" % (ref(c[i]), c[i+1], c[i+2], c[i+3]) for i in range(0, len(c), 4))
            elif c is not None and name in ("iommu-map", "msi-map"):
                items = []
                for i in range(0, len(c), 4):
                    items.append("<0x%x %s 0x%x 0x%x>" % (c[i], ref(c[i+1]), c[i+2], c[i+3]))
                s = ", ".join(items)
            if s is None:
                if len(v) and v[-1] == 0 and all(32 <= b < 127 for b in v[:-1].replace(b"\0", b" ")) and b"\0\0" not in v and v[0] != 0:
                    s = ", ".join('"%s"' % x for x in v[:-1].decode().split("\0"))
                elif c is not None:
                    s = "<" + " ".join("0x%x" % x for x in c) + ">"
                else:
                    s = "[" + " ".join("%02x" % b for b in v) + "]"
            out.append("%s: %s = %s" % (P, name, s) if len(v) else "%s: %s" % (P, name))
    for l in sorted(out):
        print(l)

def par_ph(n):
    return u32(n, "phandle", u32(n, "linux,phandle"))

main()
