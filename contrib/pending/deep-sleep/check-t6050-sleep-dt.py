#!/usr/bin/env python3
"""
Offline check of a T6050 device tree's deep-sleep data against the kernel's parser.

Replays what drivers/soc/apple/sleep-t6050.h does with the apple,t6050-sleep node at probe
(t6050_sleep_map_regs, t6050_sleep_map_radio, t6050_sleep_map_ops, t6050_sleep_map_data,
t6050_cpm_prop, t6050_boot_clk_gating) and reports every item the driver would refuse, leave
out or warn about. The power-word list is read from the tree's sleep-t6050-tables.h.

usage: check-t6050-sleep-dt.py KERNEL_TREE board.dtb [other.dtb]
With a second DTB, also lists every sleep-node and sleep-consumer property that differs.
"""
import re
import struct
import sys

# ---------------------------------------------------------------- FDT


class Node:
    def __init__(self, name, parent):
        self.name, self.parent, self.props, self.children = name, parent, {}, []

    def path(self):
        if self.parent is None:
            return "/"
        p = self.parent.path()
        return (p if p != "/" else "") + "/" + self.name

    def u32s(self, name):
        v = self.props.get(name)
        return None if v is None else list(struct.unpack(">%dI" % (len(v) // 4), v))

    def u64s(self, name):
        v = self.props.get(name)
        return None if v is None else list(struct.unpack(">%dQ" % (len(v) // 8), v))

    def strs(self, name):
        v = self.props.get(name)
        return [] if v is None else v.rstrip(b"\0").decode().split("\0")


def parse_fdt(path):
    b = open(path, "rb").read()
    magic, _, off_struct, off_strings = struct.unpack(">IIII", b[:16])
    assert magic == 0xD00DFEED, "not a DTB"
    i, root, cur = off_struct, None, None
    while True:
        tok = struct.unpack(">I", b[i:i + 4])[0]
        i += 4
        if tok == 1:
            end = b.index(b"\0", i)
            name = b[i:end].decode()
            i = (end + 4) & ~3
            n = Node(name, cur)
            if cur is None:
                root = n
            else:
                cur.children.append(n)
            cur = n
        elif tok == 2:
            cur = cur.parent
        elif tok == 3:
            ln, no = struct.unpack(">II", b[i:i + 8])
            i += 8
            nm = b[off_strings + no:b.index(b"\0", off_strings + no)].decode()
            cur.props[nm] = b[i:i + ln]
            i = (i + ln + 3) & ~3
        elif tok == 4:
            continue
        elif tok == 9:
            break
    return root


def walk(n):
    yield n
    for c in n.children:
        yield from walk(c)


def regs(n):
    p = n.parent
    ac = (p.u32s("#address-cells") or [2])[0]
    sc = (p.u32s("#size-cells") or [1])[0]
    v = n.u32s("reg") or []
    out, step = [], ac + sc
    for k in range(0, len(v), step):
        a = 0
        for x in v[k:k + ac]:
            a = (a << 32) | x
        s = 0
        for x in v[k + ac:k + step]:
            s = (s << 32) | x
        out.append((a, s))
    return out


# ---------------------------------------------------------------- driver constants

REGIONS = [("ps0", 0x4000, True), ("ps1", 0x4000, True), ("ps-aon", 0xc000, True),
           ("ps-gpx", 0x4000, True), ("ps-media", 0xc000, True), ("ps-gfx-aon", 0x4000, True),
           ("clk", 0x10000, False), ("clk-soc", 0x4000, False), ("clk1", 0x4000, False),
           ("afr-clk", 0x4000, False), ("media-clk", 0x10000, False), ("perf", 0x20000, False),
           ("media-perf", 0x14000, False), ("table0", 0x4000, False), ("table1", 0x4000, False),
           ("media-table", 0x4000, False)]
REGION_ENUM = ["T6050_PS0", "T6050_PS1", "T6050_PS_AON", "T6050_PS_GPX", "T6050_PS_MEDIA",
               "T6050_PS_GFX_AON", "T6050_CLK", "T6050_CLK_SOC", "T6050_CLK1", "T6050_AFR_CLK",
               "T6050_MEDIA_CLK", "T6050_PERF", "T6050_MEDIA_PERF", "T6050_TABLE0",
               "T6050_TABLE1", "T6050_MEDIA_TABLE"]
MAP_REGS_MIN = {"cluster": 0x20, "pwrgate": 0x134, "cpu-start": 0x14, "commit": 4, "wdt": 0x100,
                "wdt-aux": 0x30, "disp-gate": 0x544, "spmi": 0x224, "pmc-voters": 0x10008,
                "pmc-rails": 0x202c, "ptd": 0x10f08}
STEPS = 20
RUNWAY_MAX = 1000000
OP_KINDS = 8
RBLK_SPMI, RBLK_NODE, RBLK_COUNT = 8, 16, 64
SPMI_SRC_STATUS, SPMI_IRQ_STATUS = 0x600, 0x620  # see below: read from the tree
SEQS = ["apple,seq-boot", "apple,seq-stage", "apple,seq-commit-wdt", "apple,seq-commit-afr",
        "apple,seq-commit-sio", "apple,seq-display-gate"]
RADIO = ["apple,radio-link-down", "apple,radio-link-down-port", "apple,radio-port-wake",
         "apple,radio-dart-wake", "apple,radio-phy-wake", "apple,phy-park", "apple,phy-down"]


def ps_all(tree):
    t = open(tree + "/drivers/soc/apple/sleep-t6050-tables.h").read()
    body = t[t.index("t6050_ps_all[]"):]
    body = body[:body.index("};")]
    return {(REGION_ENUM.index(r) << 20) | int(o, 16)
            for r, o in re.findall(r"T6050_W\((T6050_\w+),\s*(0x[0-9a-fA-F]+)\)", body)}


def spmi_consts(tree):
    t = open(tree + "/drivers/soc/apple/sleep-t6050.h").read()
    g = {}
    for k in ("M5_SPMI_SRC_STATUS", "M5_SPMI_IRQ_STATUS"):
        m = re.search(r"#define\s+%s\s+(0x[0-9a-fA-F]+)" % k, t)
        if not m:
            m = re.search(r"#define\s+%s\s+(0x[0-9a-fA-F]+)" % k,
                          open(tree + "/drivers/soc/apple/sleep.c").read())
        g[k] = int(m.group(1), 16) if m else None
    return g


# ---------------------------------------------------------------- checks


def check(tree, dtb):
    root = parse_fdt(dtb)
    nodes = list(walk(root))
    by_ph = {}
    for n in nodes:
        ph = n.u32s("phandle")
        if ph:
            by_ph[ph[0]] = n
    sl = [n for n in nodes if b"apple,t6050-sleep" in n.props.get("compatible", b"").split(b"\0")]
    errs, warns, info = [], [], []
    if len(sl) != 1:
        return ["%d apple,t6050-sleep nodes" % len(sl)], [], []
    s = sl[0]
    info.append("sleep node %s" % s.path())
    if s.props.get("status", b"okay\0").rstrip(b"\0") not in (b"okay", b"ok"):
        errs.append("sleep node not enabled")
    names, rg = s.strs("reg-names"), regs(s)
    if len(names) != len(rg) or len(rg) != 46:
        errs.append("reg %d entries, reg-names %d (binding: 46)" % (len(rg), len(names)))
    size = {nm: rg[k][1] for k, nm in enumerate(names) if k < len(rg)}
    # sleep_region_map: each region by name, at least its size
    for nm, sz, _ in REGIONS:
        if size.get(nm, 0) < sz:
            errs.append("region %s missing or smaller than %#x" % (nm, sz))
    for nm, mn in MAP_REGS_MIN.items():
        if size.get(nm, 0) < mn:
            errs.append("missing/short %s aperture (probe fails)" % nm)

    def phs(prop):
        v = s.u32s(prop) or []
        return [by_ph.get(x) for x in v]

    # cpm-boot
    cpm = s.u64s("apple,cpm-boot")
    if cpm is not None:
        if len(cpm) % 3:
            errs.append("apple,cpm-boot not in threes (probe fails)")
        else:
            for k in range(0, len(cpm), 3):
                c, off = cpm[k], cpm[k + 1]
                if c > 2 or off + 8 > size.get("cpm%d" % c, 0):
                    warns.append("cpm-boot entry %d outside cpm%d" % (k // 3, c))
            info.append("cpm-boot: %d writes" % (len(cpm) // 3))
    # radio blocks
    rblk = {}
    radio = phs("apple,radio-pcie")
    rn = radio[0] if radio else None
    if rn is not None:
        rnames, rregs = rn.strs("reg-names"), regs(rn)
        rsz = {nm: rregs[k][1] for k, nm in enumerate(rnames) if k < len(rregs)}
        rst = {nm: rregs[k][0] for k, nm in enumerate(rnames) if k < len(rregs)}
        for blk, nm, fixed in ((0, "config", 0x1000), (1, "port0", 0x24000), (2, "phy0", 0),
                               (3, "rc", 0)):
            if nm in rsz:
                rblk[blk] = fixed or rsz[nm]
            else:
                errs.append("radio host %s has no %s (probe -EINVAL)" % (rn.path(), nm))
        if "phy0" in rst and (rst["phy0"] & 0xfffff) == 0x10000:
            rblk[4], rblk[5] = 0x10000, 0x4000
        else:
            warns.append("phy0 not at 0x...10000: lane and common PHY blocks unmapped")
        port = rn.children[0] if rn.children else None
        if not port or "reset-gpios" not in port.props:
            errs.append("radio port has no reset-gpios (probe -EINVAL)")
        im = rn.u32s("iommu-map")
        if not im:
            warns.append("radio host has no iommu-map: no radio DART")
        info.append("radio host %s" % rn.path())
    for k, nm in ((6, "storage-phy"), (7, "storage-phy-ip")):
        if nm in size:
            rblk[k] = size[nm]
    buses = phs("apple,spmi-buses")
    for k, b in enumerate(buses[:5]):
        if b is None:
            errs.append("apple,spmi-buses[%d] dangles" % k)
            continue
        rblk[RBLK_SPMI + k] = regs(b)[0][1]
    for k in range(len(rg)):
        rblk[RBLK_NODE + k] = rg[k][1]

    def ops(prop, mandatory_note=""):
        v = s.u32s(prop)
        if v is None:
            warns.append("%s absent: its step is left out%s" % (prop, mandatory_note))
            return 0
        if len(v) % 4:
            errs.append("%s: not in fours (probe fails)" % prop)
            return 0
        for k in range(0, len(v), 4):
            kind, blk, off = v[k] & 0xff, v[k + 1], v[k + 2]
            if kind >= OP_KINDS or blk >= RBLK_COUNT or blk not in rblk or off % 2 or \
               off + 4 > rblk[blk]:
                warns.append("%s: entry %d outside its block, sequence NOT USED" % (prop, k // 4))
                return 0
        return len(v) // 4

    for p in RADIO + SEQS:
        n = ops(p)
        if n:
            info.append("%s: %d ops" % (p, n))
    # map_data
    sched = s.u32s("apple,commit-schedule-us")
    if not sched or len(sched) < STEPS:
        errs.append("no commit schedule (-ENODATA: no deep sleep)")
    else:
        runway = (s.u32s("apple,commit-runway-us") or [0])[0]
        for k, v in enumerate(sched[:STEPS]):
            if runway and v >= runway:
                errs.append("commit step %d too early (-EINVAL)" % k)
        if not runway:
            runway = max(sched[:STEPS]) + 1000
        if runway > RUNWAY_MAX:
            errs.append("commit runway too long")
        info.append("schedule %s, runway %d us" % (sched[:STEPS], runway))
    pol = s.u32s("apple,smc-sleep-policy")
    if not pol or len(pol) < 6:
        errs.append("no SMC sleep spacings (-ENODATA: no deep sleep)")
    else:
        info.append("smc policy pmVC %#x spacings %s" % (pol[0], pol[1:6]))
    psw = ps_all(tree)

    def valid_word(w, power):
        r, off = (w >> 20) & 0x1f, w & 0xfffff
        if w & ~((1 << 25) - 1) or r >= len(REGIONS) or off & 3:
            return False
        nm, sz, pw = REGIONS[r]
        return off <= sz - 4 and pw == power

    for prop, power in (("apple,wake-order", True), ("apple,entry-clk-words", False),
                        ("apple,entry-perf-words", False)):
        v = s.u32s(prop)
        if v is None:
            warns.append("%s absent" % prop)
            continue
        bad = None
        for k, w in enumerate(v):
            if power and w & 0x80000000:
                if (w & 0x7fffffff) not in psw:
                    bad = k
                    break
            elif not valid_word(w, False):
                bad = k
                break
        if bad is not None:
            warns.append("%s: entry %d (%#x) not a known word, list NOT USED" % (prop, bad, v[bad]))
        else:
            info.append("%s: %d words" % (prop, len(v)))
    v = s.u32s("apple,ptd-sleep")
    if not (v and len(v) == 5 and v[0] < 0x1000 and all(x < 64 for x in v[1:])):
        warns.append("apple,ptd-sleep missing or invalid")
    v = s.u32s("apple,pmu-sleep-reads") or []
    if not v or len(v) % 2 or any(v[k] > 0xffff or not 0 < v[k + 1] <= 8 for k in range(0, len(v), 2)):
        warns.append("apple,pmu-sleep-reads missing or has a dropped pair")
    v = s.u32s("apple,spmi-sleep-order") or []
    if any(x >= 5 for x in v):
        warns.append("apple,spmi-sleep-order has an index >= 5 (dropped)")
    c = spmi_consts(tree)
    v = s.u32s("apple,spmi-pmu-sources")
    if not (v and len(v) == 2 and v[1] and c["M5_SPMI_SRC_STATUS"] is not None and
            c["M5_SPMI_SRC_STATUS"] <= v[0] < c["M5_SPMI_IRQ_STATUS"] and not v[0] % 4):
        warns.append("apple,spmi-pmu-sources missing or outside %s" % c)
    v = s.u32s("apple,pmu-wake-stage")
    if not v or v[0] > 0xff:
        warns.append("apple,pmu-wake-stage missing")
    v = s.u32s("apple,pmu-alarm-rearm")
    if not (v and len(v) == 2 and max(v) <= 0xff):
        warns.append("apple,pmu-alarm-rearm missing: the alarm is not rearmed")
    v = s.u32s("apple,complex-requests") or []
    if not v or len(v) % 2 or len(v) > 8:
        warns.append("apple,complex-requests missing: any complex state refuses")
    v = s.u32s("apple,pmc-sleep-channels") or []
    if not v or any(x >= 8 for x in v):
        warns.append("apple,pmc-sleep-channels missing or dropped entries")
    for p in ("apple,wake-enable", "apple,pinctrl-skip-pins", "apple,sleep-low-pins"):
        v = s.u32s(p)
        if not v:
            warns.append("%s absent" % p)
    pc = phs("apple,pinctrl")
    npins = pc[0].u32s("apple,npins")[0] if pc and pc[0] and pc[0].u32s("apple,npins") else None
    for p in ("apple,pinctrl-skip-pins", "apple,sleep-low-pins"):
        for x in s.u32s(p) or []:
            if npins is not None and x >= npins:
                errs.append("%s: pin %d >= apple,npins %d" % (p, x, npins))
    v = s.u32s("apple,clk-gating-boot")
    if v is not None:
        if len(v) % 3:
            warns.append("apple,clk-gating-boot not in threes: not written")
        else:
            badc = 0
            for k in range(0, len(v), 3):
                idx, off = v[k], v[k + 1]
                nm = names[idx] if idx < min(len(names), 48) else ""
                if not ("clk" in nm or "table" in nm) or off % 4 or off + 4 > rg[idx][1]:
                    badc += 1
            (warns if badc else info).append("clk-gating-boot: %d writes, %d outside the clock pages"
                                             % (len(v) // 3, badc))
    # DART GAPF slices: apple,sleep-darts then the radio's DART
    darts = phs("apple,sleep-darts")
    for k, d in enumerate(darts):
        if d is None:
            errs.append("apple,sleep-darts[%d] dangles" % k)
            continue
        sl_ = d.u32s("apple,gapf-slice")
        if not sl_ or sl_[0] >= 0x4000 or sl_[0] % 4:
            warns.append("%s: no usable apple,gapf-slice" % d.path())
    dcps = phs("apple,display-coprocessors")
    if len(dcps) != 5 or None in dcps:
        errs.append("apple,display-coprocessors: %d resolved of 5" % len([d for d in dcps if d]))
    return errs, warns, info


CONSUMER_LABEL_PROPS = ("apple,sram-keep", "apple,ptd-boot", "apple,ptd-echo-entry",
                        "apple,gapf-slice", "apple,gapf-slice-values", "apple,warm-reset-writes",
                        "apple,endpoint-sleep-smc-writes", "apple,endpoint-wake-smc-writes",
                        "apple,channel-threshold", "apple,channel-limit", "apple,init-arg",
                        "apple,sleep-message", "apple,wake-message", "apple,open-endpoints",
                        "apple,sleep-endpoints", "apple,wake-endpoints", "apple,sleep-report",
                        "apple,sleep-power-args", "apple,sleep-a500-args",
                        "apple,sleep-display-power-args", "apple,sleep-display-stage-args",
                        "apple,panel-hdcp-open-arg", "apple,panel-video-open-delay-us",
                        "apple,sleep-wake-delay-ms", "apple,sleep-ps-auto")


def compare(a, b):
    ra, rb = parse_fdt(a), parse_fdt(b)
    pa = {n.path(): n for n in walk(ra)}
    pb = {n.path(): n for n in walk(rb)}
    out = []
    sa = [n for n in pa.values() if b"apple,t6050-sleep" in n.props.get("compatible", b"")]
    sb = [n for n in pb.values() if b"apple,t6050-sleep" in n.props.get("compatible", b"")]
    phprops = ("apple,display-coprocessors", "apple,pinctrl", "apple,radio-pcie",
               "apple,sleep-darts", "apple,spmi-buses")

    def resolved(root, node, k):
        ph = {n.u32s("phandle")[0]: n.path() for n in walk(root) if n.u32s("phandle")}
        return [ph.get(x) for x in node.u32s(k) or []]

    if sa and sb:
        ka, kb = sa[0].props, sb[0].props
        for k in sorted(set(ka) | set(kb)):
            if k == "phandle":
                continue
            if k in phprops:
                if resolved(ra, sa[0], k) != resolved(rb, sb[0], k):
                    out.append("sleep node: %s points elsewhere" % k)
            elif ka.get(k) != kb.get(k):
                out.append("sleep node: %s differs" % k)
    for path in sorted(set(pa) & set(pb)):
        for k in CONSUMER_LABEL_PROPS:
            if pa[path].props.get(k) != pb[path].props.get(k):
                out.append("%s: %s differs" % (path, k))
    for path in sorted(set(pa) ^ set(pb)):
        n = pa.get(path) or pb.get(path)
        if any(k in n.props for k in CONSUMER_LABEL_PROPS):
            out.append("%s only in %s" % (path, "first" if path in pa else "second"))
    return out


def main():
    tree, dtb = sys.argv[1], sys.argv[2]
    errs, warns, info = check(tree, dtb)
    for x in info:
        print("ok    ", x)
    for x in warns:
        print("WARN  ", x)
    for x in errs:
        print("ERROR ", x)
    if len(sys.argv) > 3:
        diff = compare(dtb, sys.argv[3])
        print("== differences against %s: %d" % (sys.argv[3], len(diff)))
        for x in diff:
            print("  ", x)
    print("RESULT", "FAIL" if errs else ("PASS with warnings" if warns else "PASS"))
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
