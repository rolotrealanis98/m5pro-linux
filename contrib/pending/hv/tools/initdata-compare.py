#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""initdata-compare.py CAPTURE_DIR [--pr-src initdata.rs] [--public-md OUT.md] [--private-json OUT.json]

Turns the raw InitData dumps written by hv27-gpu-initdata.py (CAPTURE_DIR/initdata-<asc>-<tag>-<n>/) into
  * a PRIVATE json (every observed value, pointers included; stays on the Studio), and
  * a PUBLIC markdown field/validation summary against the sites of aurora-silicon/linux#1173 marked "not yet
    confirmed from captured InitData" (11 items on 12 comment lines at d8ca53c82e52).

The public summary carries offsets, sizes and the constant values at the PR's sites only. Pointers are shown as a
class ("pointer"/"null"/"value"), never as an address; no physical or virtual address, hash, serial, UUID or MAC
appears. A redaction check scans the public text before it is written and refuses to write it on any hit.

Expectations are parsed from the PR source (--pr-src, g17/fw/m5/initdata.rs at the PR head); built-in defaults
(d8ca53c82e52) are used for anything the parser does not find, and the summary says which.
"""
import argparse, glob, json, os, re, struct, sys

# ------------------------------------------------------------------------------------------- PR expectations
DEFAULTS = {
    "M5_INITDATA_VERSION_WORD": 0x0c8e_0339_8728_04c0,
    "M5_26B123_INITDATA_VERSION_WORD": 0x0c8e_4339_8728_04c0,
    "ABI_ALLOCATION_SIZES_26A428_M5": [0x2850, 0x0c18, 0x1048, 0x0e10, 0x126b0, 0x0068, 0x0800, 0x0088, 0x1800,
                                       0x04c0, 0x4000, 0x0030, 0xe730, 0x0780, 0x0020, 0x01b0, 0x4800, 0x28800,
                                       0x79800, 0x9000, 0x00a8, 0x0008, 0x1ca0, 0x00e4],
    "ABI_ALLOCATION_SIZES_26B123_M5": [0x2850, 0x0c18, 0x1048, 0x0e10, 0x12728, 0x0068, 0x0800, 0x0088, 0x1800,
                                       0x04c0, 0x4000, 0x0030, 0xe730, 0x0790, 0x0020, 0x01b0, 0x4800, 0x28800,
                                       0x79800, 0x9000, 0x00a8, 0x0008, 0x1ca0, 0x00e4],
    "M5_26B123_STATUS_CONFIG_BANDS": [(0x000, 0x5dc, 0x0), (0x5dc, 0x608, 0x4), (0x608, 0x638, 0x8),
                                      (0x638, 0x664, 0xc), (0x664, 0x780, 0x10)],
    "M5_26B123_STATUS_CONFIG_INSERTED": [(0x5dc, 0), (0x60c, 5000), (0x640, 0), (0x670, 0)],
    "M5_26C5035_HW_DATA_BANDS": [(0x0000, 0x2720, 0), (0x2720, 0x284c, 4)],
    "M5_26C5035_HW_FORCED_IDLE_TIMEOUT": 0x2720,
    "M5_GPU_TIMEOUT_SECONDS": 5,
    "M5_26B123_POLICY_BANDS": [(0x0000, 0x4910, 0), (0x4910, 0x491c, 0x10), (0x491c, 0x49b8, 0x14),
                               (0x49b8, 0x4a98, 0x18), (0x4a98, 0x12668, 0x30), (0x12668, 0x126b0, 0x78)],
    "M5_26B123_POLICY_CONTROLLER_WORDS": [(0x492c, 5000), (0x4a14, 1600)],
    "M5_26B123_POLICY_CONTROLLER_WORDS_G17D": [(0x4920, 2500), (0x4928, 800), (0x492c, 1100), (0x49e4, 0),
                                               (0x4a14, 1600)],
    "M5_POLICY_STATE_PTR": 0x8254,
    "M5_POLICY_AON_PTD_PTR": 0x11a1c,
    "M5_KICK_SHARED_POINTER": 0x27dc,
    "M5_STATUS_CONFIG_LINK_WORD": 0x774,
    "M5_STATUS_CONFIG_LINK_PTR": 0x778,
    "M5_STATUS_CONFIG_HISTORY": 0x73c,
    "M5_STATUS_CONFIG_HISTORY_GENERATION": 0x74c,
    "M5_STATUS_CONFIG_HISTORY_SLOTS": 0x750,
    "M5_HW_DATA_INSERT": 0x267c,
    "M5_HW_DATA_INSERT_LEN": 8,
    "COMMON26_KSM_COMPLETION_TABLE_OFFSET": 0x2734,
    "COMMON26_QOS_POINTER_OFFSET": 0x27cc,
    "COMMON26_HW_FIXED_WORD_OFFSET": 0x2714,
    "COMMON26_HW_FIXED_WORD_VALUE": 0x96,
    "COMMON26_HW_CHIP_ID_OFFSET": 0xfb0,
    "M5_POLICY_MAXIMUM_POWER": 0xa18,
}
# The 12 comment lines -> 11 items (name, file:line at d8ca53c82e52); lines are re-read from --pr-src when given.
SITES = [
    ("M5_26B123_STATUS_CONFIG_BANDS", "g17/fw/m5/initdata.rs:1488"),
    ("M5_26B123_STATUS_CONFIG_INSERTED", "g17/fw/m5/initdata.rs:1503"),
    ("M5_26B123_INITDATA_VERSION_WORD", "g17/fw/m5/initdata.rs:1743"),
    ("ABI_ALLOCATION_SIZES_26B123_M5", "g17/fw/m5/initdata.rs:1756"),
    ("M5_26C5035_HW_DATA_BANDS", "g17/fw/m5/initdata.rs:1775"),
    ("M5_26C5035_HW_FORCED_IDLE_TIMEOUT", "g17/fw/m5/initdata.rs:1783"),
    ("M5_GPU_TIMEOUT_SECONDS", "g17/fw/m5/initdata.rs:1786-1787"),
    ("M5_26B123_POLICY_BANDS", "g17/fw/m5/initdata.rs:2280"),
    ("M5_26B123_POLICY_CONTROLLER_WORDS", "g17/fw/m5/initdata.rs:2299"),
    ("M5_26B123_POLICY_CONTROLLER_WORDS_G17D", "g17/fw/m5/initdata.rs:2306"),
    ("M5Layouts (V26C5035)", "g17/fw/variant.rs:40"),
]


def _int(s):
    return int(s.replace("_", ""), 0)


def parse_pr(path):
    """Constants of g17/fw/m5/initdata.rs; returns (values, provenance per name, site lines)."""
    vals, prov = dict(DEFAULTS), {k: "default" for k in DEFAULTS}
    lines = {}
    if not path:
        return vals, prov, lines
    src = open(path).read()
    num = r"0x[0-9a-fA-F_]+|\d[\d_]*"
    for name in DEFAULTS:
        m = re.search(r"const %s:\s*[^=]+=\s*(%s)\s*;" % (name, num), src)
        if m:
            vals[name], prov[name] = _int(m.group(1)), "parsed"
            continue
        m = re.search(r"const %s:\s*\[usize;\s*24\]\s*=\s*\[(.*?)\];" % name, src, re.S)
        if m:
            vals[name], prov[name] = [_int(x) for x in re.findall(num, m.group(1))], "parsed"
            continue
        m = re.search(r"const %s:\s*&\[LayoutBand\]\s*=\s*&\[(.*?)\];" % name, src, re.S)
        if m:
            bands = []
            for a, b, c in re.findall(r"band\(\s*(%s)\s*,\s*([A-Za-z0-9_]+)\s*,\s*(-?(?:%s))\s*," % (num, num), m.group(1)):
                bands.append((_int(a), b, _int(c)))
            vals[name], prov[name] = bands, "parsed"
            continue
        m = re.search(r"const %s:\s*&\[\(usize,\s*u32\)\]\s*=\s*&?\[(.*?)\];" % name, src, re.S)
        if m:
            vals[name] = [(_int(a), _int(b)) for a, b in re.findall(r"\(\s*(%s)\s*,\s*(%s)\s*\)" % (num, num), m.group(1))]
            prov[name] = "parsed"
    sizes0 = vals["ABI_ALLOCATION_SIZES_26A428_M5"]
    named = {"M5_POLICY_SIZE": sizes0[4], "M5_STATUS_CONFIG_SIZE": sizes0[13]}
    for k in ("M5_26B123_STATUS_CONFIG_BANDS", "M5_26C5035_HW_DATA_BANDS", "M5_26B123_POLICY_BANDS"):
        vals[k] = [(a, named[b] if isinstance(b, str) and b in named else (_int(b) if isinstance(b, str) else b), c)
                   for a, b, c in vals[k]]
    for i, ln in enumerate(src.split("\n"), 1):
        if "captured InitData" in ln:
            for j, nl in enumerate(src.split("\n")[i:i + 4], i + 1):
                m = re.search(r"const (\w+)", nl)
                if m:
                    lines.setdefault(m.group(1), i)
                    break
    return vals, prov, lines


def relocate(bands, off):
    for a, b, d in bands:
        if a <= off < b:
            return off + d
    return None

# ------------------------------------------------------------------------------------------- packing (driver)
def rup(v, a):
    return (v + a - 1) & ~(a - 1)


def packed(sizes):
    out = [0] * len(sizes)
    for i in range(1, len(sizes)):
        out[i] = rup(out[i - 1] + sizes[i - 1], 0x40)
    return out


def layouts(t):
    sh = [t[0], t[1], t[2], t[3], t[4], t[5], t[6], 0, t[7]] + [t[8]] * 12 + [t[9], t[10], t[9], t[10]]
    so = packed(sh)
    rs = [t[14], t[11], t[15], t[11], t[11], t[16], t[17], t[18], t[19], t[16]]
    pv = [t[11]] * 13 + [t[12], t[13]] + rs + rs + [t[11], t[20], t[21]]
    po = packed(pv)
    return {"hw": so[0], "view0": so[1], "view1": so[2], "view2": so[3], "policy": so[4], "view3": so[5],
            "view4": so[6], "main0": so[21], "main1": so[23]}, \
           {"status_b": po[13], "status_config": po[14], "status_a0": po[15], "status_a1": po[25],
            "sx1": po[36], "policy_state": po[37]}

# ------------------------------------------------------------------------------------------- dumps
class Dump:
    def __init__(self, d):
        self.dir = d
        self.idx = json.load(open(os.path.join(d, "index.json")))
        self.role = self.idx.get("role")
        self.b = {}
        for name, o in self.idx.get("objects", {}).items():
            p = os.path.join(d, f"{name}.bin")
            if os.path.exists(p) and not o.get("missing"):
                self.b[name] = open(p, "rb").read()

    def va(self, name):
        o = self.idx["objects"].get(name)
        return o.get("va") if o else None

    def u32(self, name, off):
        b = self.b.get(name)
        return struct.unpack_from("<I", b, off)[0] if b is not None and off + 4 <= len(b) else None

    def u64(self, name, off):
        b = self.b.get(name)
        return struct.unpack_from("<Q", b, off)[0] if b is not None and off + 8 <= len(b) else None


def looks_va(v):
    return v is not None and (v >> 44 == 0xfffff or 0x10_0000_0000 <= v < (1 << 42))


def cls(v):
    if v is None:
        return "no data"
    if v == 0:
        return "null"
    return "pointer" if looks_va(v) else "value"


def load(capdir):
    dirs = sorted(glob.glob(os.path.join(capdir, "initdata-*"))) or ([capdir] if os.path.exists(os.path.join(capdir, "index.json")) else [])
    dumps = [Dump(d) for d in dirs]
    pick = {}
    for want in ("send", "ack", "manual"):
        for dm in dumps:
            if dm.idx.get("tag") == want and dm.role in (0, 1) and dm.role not in pick and "root" in dm.b:
                pick[dm.role] = dm
    acks = 0
    for j in glob.glob(os.path.join(capdir, "gpu-mbox.jsonl")):
        for ln in open(j):
            try:
                r = json.loads(ln)
            except ValueError:
                continue
            acks += r.get("fw") == "INITDATA_ACK"
    return dumps, pick.get(0), pick.get(1), acks

# ------------------------------------------------------------------------------------------- checks
def run(capdir, pr):
    V, prov, lines = pr
    dumps, P, S, acks = load(capdir)
    res, ctx, priv = [], [], {"dumps": [d.dir for d in dumps]}
    T0, T2 = V["ABI_ALLOCATION_SIZES_26A428_M5"], V["ABI_ALLOCATION_SIZES_26B123_M5"]

    def add(name, prv, obs, verdict, how):
        res.append({"site": name, "pr": prv, "observed": obs, "verdict": verdict, "evidence": how})

    ctx.append(f"primary dump: {'yes' if P else 'NO'}; secondary dump: {'yes' if S else 'NO'}; "
               f"INITDATA acknowledgements seen in the mailbox log: {acks}")
    for R, tag in ((P, "primary"), (S, "secondary")):
        if R:
            ctx.append(f"{tag} root: page size {R.u32('root', 0x30) & 0xffff:#x}, page bits {R.b['root'][0x32]}, "
                       f"levels {R.b['root'][0x33]}, instance kind {R.u32('root', 0x28)}, fixed word {R.u32('root', 0x2c)} "
                       f"(PR: 0x4000, 14, 3, role, 1)")

    # version word
    vw = [R.u64("root", 0) for R in (P, S) if R]
    if not vw:
        add("M5_26B123_INITDATA_VERSION_WORD", "0x0c8e_4339_8728_04c0", "no data", "NO DATA", "root+0x00")
    else:
        same = all(v == V["M5_26B123_INITDATA_VERSION_WORD"] for v in vw)
        old = all(v == V["M5_INITDATA_VERSION_WORD"] for v in vw)
        fmt = lambda v: "0x" + "_".join(f"{v:016x}"[i:i + 4] for i in range(0, 16, 4))
        add("M5_26B123_INITDATA_VERSION_WORD", fmt(V["M5_26B123_INITDATA_VERSION_WORD"]),
            ", ".join(sorted({fmt(v) for v in vw})),
            "CONFIRMED" if same else ("CONTRADICTED (27.0 word)" if old else "CONTRADICTED"),
            f"root+0x00 of {len(vw)} root(s), read from guest memory")
        priv["version_words"] = vw

    # sizes via the packing deltas
    L0, L2 = layouts(T0), layouts(T2)
    obs_sh, obs_pv = {}, {}
    if P:
        hw = P.va("hw_data")
        for k in ("view0", "view1", "view2", "view3", "view4"):
            if P.va(k) and hw:
                obs_sh[k] = P.va(k) - hw
        if P.va("main_config") and hw:
            obs_sh["main0"] = P.va("main_config") - hw
        if P.va("status_b"):
            obs_pv["status_b"] = P.va("status_b")
        obs_pv["status_a0"] = P.u64("root", 0xa8)
    if S:
        hw = S.va("hw_data")
        if S.va("policy") and hw:
            obs_sh["policy"] = S.va("policy") - hw
        if S.va("main_config") and hw:
            obs_sh["main1"] = S.va("main_config") - hw
        obs_pv["status_config"] = S.u64("root", 0xb8)
        obs_pv["status_a1"] = S.u64("root", 0xa8)
        obs_pv["sx1"] = S.u64("root", 0xc0)
        ps = S.u64("policy", relocate(V["M5_26B123_POLICY_BANDS"], V["M5_POLICY_STATE_PTR"]) or 0)
        if looks_va(ps):
            obs_pv["policy_state"] = ps
    deltas = []
    for k, v in obs_sh.items():
        deltas.append((f"bundle {k} - hw_data", v, L0[0][k], L2[0][k]))
    if "status_config" in obs_pv:
        sc = obs_pv["status_config"]
        for k in ("status_b", "status_a0", "status_a1", "sx1", "policy_state"):
            if looks_va(obs_pv.get(k)):
                deltas.append((f"private {k} - status_config", obs_pv[k] - sc,
                               L0[1][k] - L0[1]["status_config"], L2[1][k] - L2[1]["status_config"]))
    m2 = [d for d in deltas if d[1] == d[3] and d[2] != d[3]]
    m0 = [d for d in deltas if d[1] == d[2] and d[2] != d[3]]
    neither = [d for d in deltas if d[1] not in (d[2], d[3])]
    disc = [d for d in deltas if d[2] != d[3]]
    priv["spacing"] = deltas
    sc_end = pol_end = None
    if S and "status_config" in S.b:
        nz = [i for i, x in enumerate(S.b["status_config"][:T2[13]]) if x]
        sc_end = (max(nz) + 1) if nz else 0
    if S and "policy" in S.b:
        nz = [i for i, x in enumerate(S.b["policy"][:T2[4]]) if x]
        pol_end = (max(nz) + 1) if nz else 0
    ext = f"; last nonzero byte: policy {pol_end:#x}, status config {sc_end:#x}" if pol_end is not None and sc_end is not None else ""
    if disc and len(m2) == len(disc):
        v = "CONFIRMED (policy 0x12728, status config 0x790)"
    elif disc and len(m0) == len(disc):
        v = "CONTRADICTED (27.0 sizes)"
    elif not deltas:
        v = "NO DATA"
    else:
        v = "NOT OBSERVABLE by spacing (macOS does not pack these objects like the driver)" if neither else "MIXED"
    add("ABI_ALLOCATION_SIZES_26B123_M5", "entries 4 and 13: 0x12728, 0x790 (27.0: 0x126b0, 0x780)",
        f"{len(m2)}/{len(disc)} size-dependent spacings match 27.2+, {len(m0)} match 27.0, {len(neither)} neither{ext}",
        v, "distance between the objects macOS allocated (pointer differences, not the pointers), "
           "against the driver's packed layout of each size table")
    for name, ob, e0, e2 in deltas:
        ctx.append(f"spacing {name}: observed {ob:#x}, 27.0 packing {e0:#x}, 27.2+ packing {e2:#x}")

    # status config
    if S and "status_config" in S.b:
        ins = V["M5_26B123_STATUS_CONFIG_INSERTED"]
        got = [(o, S.u32("status_config", o)) for o, _ in ins]
        add("M5_26B123_STATUS_CONFIG_INSERTED", ", ".join(f"{o:#x}={x}" for o, x in ins),
            ", ".join(f"{o:#x}={x}" for o, x in got),
            "CONFIRMED" if [x for _, x in got] == [x for _, x in ins] else "CONTRADICTED",
            "u32 words of the status config macOS built (secondary root+0xb8)")
        bands = V["M5_26B123_STATUS_CONFIG_BANDS"]
        lp_new = relocate(bands, V["M5_STATUS_CONFIG_LINK_PTR"])
        lw_new = relocate(bands, V["M5_STATUS_CONFIG_LINK_WORD"])
        a_new = cls(S.u64("status_config", lp_new))
        a_old = cls(S.u64("status_config", V["M5_STATUS_CONFIG_LINK_PTR"]))
        b = S.b["status_config"]

        def mask(o, n):
            return [1 if struct.unpack_from("<I", b, o + i)[0] else 0 for i in range(0, n, 4)]
        s64 = sum(x == y for x, y in zip(mask(0x5b4, 0x64), mask(0x5b4 + 0x64, 0x64))) / (0x64 // 4)
        s5c = sum(x == y for x, y in zip(mask(0x5b4, 0x5c), mask(0x5b4 + 0x5c, 0x5c))) / (0x5c // 4)
        hist = [relocate(bands, V[k]) for k in ("M5_STATUS_CONFIG_HISTORY", "M5_STATUS_CONFIG_HISTORY_GENERATION",
                                                "M5_STATUS_CONFIG_HISTORY_SLOTS")]
        ok = a_new == "pointer" and a_old != "pointer"
        bad = a_old == "pointer" and a_new != "pointer"
        add("M5_26B123_STATUS_CONFIG_BANDS",
            f"link word/pointer {lw_new:#x}/{lp_new:#x} (27.0 0x774/0x778); controller blocks 0x64 apart; history "
            f"{hist[0]:#x}/{hist[1]:#x}/{hist[2]:#x}",
            f"u64 at {lp_new:#x}: {a_new}, at 0x778: {a_old}; link word {S.u32('status_config', lw_new):#x}; "
            f"block word-pattern agreement at stride 0x64 {s64:.2f} vs 0x5c {s5c:.2f}",
            "CONSISTENT" if ok and s64 >= s5c else ("CONTRADICTED" if bad else "INCONCLUSIVE"),
            "pointer position and block structure in the status config macOS built")
        priv["status_config_history"] = {f"{o:#x}": S.u64("status_config", o) for o in hist if o is not None}
    else:
        add("M5_26B123_STATUS_CONFIG_INSERTED", "0x5dc=0, 0x60c=5000, 0x640=0, 0x670=0", "no data", "NO DATA", "")
        add("M5_26B123_STATUS_CONFIG_BANDS", "", "no data", "NO DATA", "")

    # HW data
    R = P or S
    if R and "hw_data" in R.b:
        hb = V["M5_26C5035_HW_DATA_BANDS"]
        ins, ln = V["M5_HW_DATA_INSERT"], V["M5_HW_DATA_INSERT_LEN"]
        m5 = lambda c: c + ln if c >= ins else c                      # COMMON26 -> 26A428 M5 offset
        ct0 = m5(V["COMMON26_KSM_COMPLETION_TABLE_OFFSET"]); ct2 = relocate(hb, ct0)
        q0 = m5(V["COMMON26_QOS_POINTER_OFFSET"]); q2 = relocate(hb, q0)
        k0 = V["M5_KICK_SHARED_POINTER"]; k2 = relocate(hb, k0)
        fw0 = m5(V["COMMON26_HW_FIXED_WORD_OFFSET"])
        ones0 = [0x2842, 0x2846]; ones2 = [relocate(hb, o) for o in ones0]

        def table_at(o):
            e = [(R.u32("hw_data", o + 0x20 * i + 0x10), R.u32("hw_data", o + 0x20 * i + 0x14),
                  R.u32("hw_data", o + 0x20 * i + 0x18)) for i in range(4)]
            return all(x[2] == i for i, x in enumerate(e)) and len({(x[0], x[1]) for x in e}) == 1 and e[0][0], e
        t2, e2 = table_at(ct2)
        t0, e0 = table_at(ct0)
        anchors = {
            "chip id below the band": R.u32("hw_data", V["COMMON26_HW_CHIP_ID_OFFSET"]) == 0x6050,
            f"fixed word 0x96 at {fw0:#x} (below 0x2720, unmoved)": R.u32("hw_data", fw0) == V["COMMON26_HW_FIXED_WORD_VALUE"],
            f"completion table at {ct2:#x} (27.0/27.2: {ct0:#x})": bool(t2) and not t0,
            f"QoS pointer at {q2:#x} (27.0/27.2: {q0:#x})": cls(R.u64("hw_data", q2)) == "pointer",
            f"kick-shared pointer at {k2:#x} (27.0/27.2: {k0:#x})": cls(R.u64("hw_data", k2)) == "pointer",
            f"words = 1 at {ones2[0]:#x}/{ones2[1]:#x} (27.0/27.2: {ones0[0]:#x}/{ones0[1]:#x})":
                R.u32("hw_data", ones2[1]) == 1 and R.u32("hw_data", ones0[0]) != 1,
            "0x284c..0x2850 zero (dropped tail)": R.u32("hw_data", 0x284c) == 0,
        }
        npass = sum(anchors.values())
        unshift = (bool(t0) and not t2) or cls(R.u64("hw_data", k0)) == "pointer" and cls(R.u64("hw_data", k2)) != "pointer"
        add("M5_26C5035_HW_DATA_BANDS", "0x0000..0x2720 +0, 0x2720..0x284c +4",
            f"{npass}/{len(anchors)} anchors: " + "; ".join(f"{k}: {'yes' if v else 'no'}" for k, v in anchors.items()),
            "CONFIRMED" if npass == len(anchors) else ("CONTRADICTED (unshifted layout)" if unshift else "PARTIAL"),
            "positions of fields with known shape in the HW data macOS built (main config +0x00)")
        fi = R.u32("hw_data", V["M5_26C5035_HW_FORCED_IDLE_TIMEOUT"])
        add("M5_26C5035_HW_FORCED_IDLE_TIMEOUT", f"u32 at {V['M5_26C5035_HW_FORCED_IDLE_TIMEOUT']:#x}, a time in ms",
            f"{fi}", "POSITION AND VALUE OBSERVED; meaning not observable from a static dump" if fi else "CONTRADICTED (zero)",
            "u32 of the HW data macOS built")
        want = V["M5_GPU_TIMEOUT_SECONDS"] * 1000
        add("M5_GPU_TIMEOUT_SECONDS", f"{V['M5_GPU_TIMEOUT_SECONDS']} s -> {want} ms at 0x2720", f"{fi}",
            "CONFIRMED" if fi == want else "CONTRADICTED", "the value macOS wrote at 0x2720")
        priv["hw_tables"] = {"at_new": e2, "at_old": e0}
        ctx.append(f"HW data core type word (0x10d4): {R.u32('hw_data', 0x10d4):#x}, revision (0x10d8): "
                   f"{R.u32('hw_data', 0x10d8):#x}, GPU cores (0x10dc): {R.u32('hw_data', 0x10dc)}")
    else:
        for n in ("M5_26C5035_HW_DATA_BANDS", "M5_26C5035_HW_FORCED_IDLE_TIMEOUT", "M5_GPU_TIMEOUT_SECONDS"):
            add(n, "", "no data", "NO DATA", "")

    # policy
    if S and "policy" in S.b:
        pb = V["M5_26B123_POLICY_BANDS"]
        st0, st2 = V["M5_POLICY_STATE_PTR"], relocate(pb, V["M5_POLICY_STATE_PTR"])
        ao0, ao2 = V["M5_POLICY_AON_PTD_PTR"], relocate(pb, V["M5_POLICY_AON_PTD_PTR"])
        tb0 = 0x122f0; tb2 = relocate(pb, tb0)
        b = S.b["policy"]
        ent = lambda base, i: b[base + 24 * i: base + 24 * i + 24]
        n2 = sum(1 for i in range(40) if any(ent(tb2, i)))
        trail0, trail2 = relocate(pb, 0x12668), 0x12668
        anchors = {
            f"state pointer at {st2:#x} (27.0 {st0:#x})": cls(S.u64("policy", st2)) == "pointer" and cls(S.u64("policy", st0)) != "pointer",
            f"AON PTD pointer at {ao2:#x} (27.0 {ao0:#x})": cls(S.u64("policy", ao2)) == "pointer" and cls(S.u64("policy", ao0)) != "pointer",
            f"maximum power word at {V['M5_POLICY_MAXIMUM_POWER']:#x} (below 0x4910, unmoved) nonzero": bool(S.u32("policy", V["M5_POLICY_MAXIMUM_POWER"])),
        }
        npass = sum(anchors.values())
        old = cls(S.u64("policy", st0)) == "pointer" and cls(S.u64("policy", st2)) != "pointer"
        add("M5_26B123_POLICY_BANDS", "bands +0x10/+0x14/+0x18/+0x30/+0x78 from 0x4910",
            f"{npass}/{len(anchors)} anchors: " + "; ".join(f"{k}: {'yes' if v else 'no'}" for k, v in anchors.items())
            + f"; table at {tb2:#x}: {n2} nonzero 24-byte entries of 40 (27.0: 37)",
            "CONFIRMED" if npass == len(anchors) else ("CONTRADICTED (27.0 positions)" if old else "PARTIAL"),
            "pointer positions in the power policy macOS built (secondary main config +0x481)")
        cw = V["M5_26B123_POLICY_CONTROLLER_WORDS"]
        got = [(o, S.u32("policy", o)) for o, _ in cw]
        add("M5_26B123_POLICY_CONTROLLER_WORDS", ", ".join(f"{o:#x}={x}" for o, x in cw),
            ", ".join(f"{o:#x}={x}" for o, x in got),
            "CONFIRMED" if [x for _, x in got] == [x for _, x in cw] else "CONTRADICTED (macOS writes other values on this part)",
            "u32 words of the power policy macOS built")
        ct = R.u32("hw_data", 0x10d4) if R else None
        add("M5_26B123_POLICY_CONTROLLER_WORDS_G17D", "G17D (core type 0x1a) words",
            f"part is core type {ct:#x}" if ct is not None else "no data",
            "NOT OBSERVABLE on this part (G17S)" if ct != 0x1a else "SEE PRIVATE JSON", "core type word of the HW data")
        priv["policy_controller_region"] = {f"{o:#x}": S.u32("policy", o) for o in range(0x4910, 0x4a20, 4)}
        priv["policy_trailing"] = {f"{o:#x}": S.u32("policy", o) for o in range(trail0, trail0 + 0x10, 4)} if trail0 else {}
    else:
        for n in ("M5_26B123_POLICY_BANDS", "M5_26B123_POLICY_CONTROLLER_WORDS", "M5_26B123_POLICY_CONTROLLER_WORDS_G17D"):
            add(n, "", "no data", "NO DATA", "")

    # send vs ack: which words the firmware changed after it read the graph (counts public, offsets private)
    changed = {}
    for role in (0, 1):
        snd = [d for d in dumps if d.role == role and d.idx.get("tag") == "send"]
        ack = [d for d in dumps if d.role == role and d.idx.get("tag") == "ack"]
        if snd and ack:
            for name in sorted(set(snd[0].b) & set(ack[0].b)):
                x, y = snd[0].b[name], ack[0].b[name]
                offs = [o for o in range(0, min(len(x), len(y)) - 3, 4) if x[o:o + 4] != y[o:o + 4]]
                if offs:
                    changed[f"role{role}.{name}"] = offs
    priv["changed_send_to_ack"] = {k: [hex(o) for o in v] for k, v in changed.items()}
    ctx.append("words changed between the INITDATA store and the acknowledgement (firmware writes): " +
               (", ".join(f"{k} {len(v)}" for k, v in changed.items()) or "none"))

    # variant (aggregate)
    hard = [r for r in res if r["verdict"].startswith("CONTRADICTED")]
    nodata = [r for r in res if r["verdict"] == "NO DATA"]
    add("M5Layouts (V26C5035)", "the 27.3 beta 1 graph = 26B123's + the HW data word at 0x2720",
        f"{len(res) - len(hard) - len(nodata)} of {len(res)} items without contradiction; "
        f"firmware acknowledgements of macOS's InitData: {acks}",
        "CONSISTENT" if not hard and not nodata else ("CONTRADICTED" if hard else "INCOMPLETE"),
        "aggregate of the items above")
    order = {n: i for i, (n, _) in enumerate(SITES)}
    res.sort(key=lambda r: order.get(r["site"], 99))
    for r in res:
        r["where"] = dict(SITES).get(r["site"], "")
        if r["site"] in lines:
            r["where"] = f"g17/fw/m5/initdata.rs:{lines[r['site']]}"
    return res, ctx, priv, prov

# ------------------------------------------------------------------------------------------- redaction
BAN = [
    (re.compile(r"0x[0-9a-fA-F]{9,}"), "long hex (address-like)"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "UUID"),
    (re.compile(r"\b[0-9a-fA-F]{24,}\b"), "hash-like hex run"),
    (re.compile(r"\b(?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}\b"), "MAC address"),
    (re.compile(r"\b(?=[A-Z0-9]*\d[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z][A-Z0-9]*[A-Z])[A-Z0-9]{10,12}\b"), "serial-like token"),
    (re.compile(r"/(?:Users|Volumes|private|home)/"), "local path"),
]


def redaction_hits(text):
    return [(why, m.group(0)) for rx, why in BAN for m in rx.finditer(text)]


def public_md(res, ctx, prov):
    out = ["# GPU InitData of macOS 27.3 beta 1 (26C5035r) on a J716s, against aurora-silicon/linux#1173", "",
           "Observed, not derived: the InitData graph macOS built for the G17S GPU firmware, read from guest memory "
           "under the m1n1 hypervisor at the moment macOS wrote the INITDATA mailbox word (before the firmware saw "
           "it), by walking the GPU's own page tables. Machine: MacBook Pro 16-inch (M5 Pro, T6050, G17S), booted "
           "from its 27.3 beta 1 stub firmware; guest kernelcache 26C5035r; no SSD attached to the guest. No value "
           "below comes from the kext or firmware code.", "",
           "Pointers are shown only as a class (pointer / null / value); sizes come from distances between objects, "
           "never from addresses.", "",
           "| PR item | where (PR head) | PR value | observed | verdict |", "|---|---|---|---|---|"]
    esc = lambda s: str(s).replace("|", "\\|")
    for r in res:
        out.append(f"| `{r['site']}` | {r['where']} | {esc(r['pr'])} | {esc(r['observed'])} | {r['verdict']} |")
    out += ["", "How each item was observed:", ""]
    for r in res:
        out.append(f"- `{r['site']}`: {r['evidence']}")
    out += ["", "Context:", ""] + [f"- {c}" for c in ctx]
    parsed = sorted(k for k, v in prov.items() if v == "parsed")
    out += ["", f"Expectations parsed from the PR source: {len(parsed)} constants; the rest from the d8ca53c82e52 "
            "defaults built into the script.", ""]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--pr-src")
    ap.add_argument("--public-md")
    ap.add_argument("--private-json")
    a = ap.parse_args()
    pr = parse_pr(a.pr_src)
    res, ctx, priv, prov = run(a.capture, pr)
    md = public_md(res, ctx, prov)
    hits = redaction_hits(md)
    for r in res:
        print(f"{r['verdict']:<60} {r['site']}")
    if a.private_json:
        json.dump({"results": res, "context": ctx, "private": priv, "provenance": prov}, open(a.private_json, "w"),
                  indent=1, default=lambda v: hex(v) if isinstance(v, int) else str(v))
        print(f"private json -> {a.private_json}")
    if hits:
        print("REDACTION CHECK FAILED, public summary NOT written:")
        for why, s in hits[:20]:
            print(f"  {why}: {s[:6]}...")
        sys.exit(3)
    if a.public_md:
        open(a.public_md, "w").write(md)
        print(f"public summary -> {a.public_md} (redaction check passed)")
    else:
        print(md)


if __name__ == "__main__":
    main()
