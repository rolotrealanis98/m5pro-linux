#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Emit the device-tree tunables that the Aurora T6050 combo/DP PHY driver
(drivers/phy/apple/atc-t6050-dp.c + atc-t6050-combo.h) parses, straight from
an Apple Device Tree (ADT) dump.

Usage:
  gen-atc-tunables.py --adt adt.bin --atc 1                 # property lines on stdout
  gen-atc-tunables.py --adt adt.bin --atc 1 -o frag.txt
  gen-atc-tunables.py --adt adt.bin --atc 1 --check-dts j716s.dts   # cross-check DT reg windows

Run with the m1n1 proxyclient venv (needs m1n1.adt):
  ~/Work/m1n1/.venv/bin/python gen-atc-tunables.py ...

-------------------------------------------------------------------------------
How the values travel (all verified against the J716s ADT, see REPORT.md)
-------------------------------------------------------------------------------
ADT tunable record (m1n1 src/kboot_atc.c `struct atc_tunable`, 12 bytes LE):
    u32 offset:24, size:8   (size is in bits, always 32)
    u32 mask
    u32 value
The offset is relative to ONE ADT `reg` window of the node.  On T6050 the
driver's bank numbers ARE the atc-phyN ADT reg indices:
    bank 0      = atc-phyN reg[0]  (DT "usb2phy")
    bank 2..35  = atc-phyN reg[2..35] = core + {0,0x400,...,0x29000}
                  (driver core_banks[], atc-t6050-dp.c:41-48)
    bank 38..43 = atc-phyN reg[38..43] (DT "usb-control","reset","fabric",
                  "axi2af","lioa","common-cfg"; atc-t6050-dp.c:49-53)
    bank 44     = usb-drdN reg[3] (DT "pipehandler"; atc-t6050-combo.h:383-385)
The driver applies each list at dp->banks[bank] (apple_tunable_apply()), and
devm_apple_tunable_parse() (drivers/soc/apple/tunable.c) checks
offset % 4 == 0 and offset <= resource_size(bank) - 4, where a core bank's
resource runs from core+bank_offset to the END of "core" (atc-t6050-dp.c:643-650).
=> The DT value is the ADT record verbatim: <offset mask value>, no rebasing.
   (Contrast m1n1's T8103/T6000 table, which adds reg_offset to rebase onto a
   single "common" window; and Aura's J614s/T6040 table, kboot_atc.c:1002-1023,
   which rebases lane/PLL lists onto "core" with a bias = bank offset.)
"""
import argparse
import os
import re
import struct
import sys

M1N1_PROXY = os.path.expanduser("~/Work/m1n1/proxyclient")

# (source node, ADT name, DT property, driver bank, required-by-driver, note)
# source: "atc" = /arm-io/atc-phyN, "drd" = /arm-io/usb-drdN
# Required column: what t6050_dp_probe()/combo_setup() refuse to probe without,
# for an apple,t6050-combo-phy node with mode-switch (Type-C).
MAP = [
    ("atc", "tunable_ATC0AXI2AF",             "apple,tunable-axi2af",         41, True,  "dp.c:55, combo.h:40"),
    ("atc", "tunable_ATC_FABRIC",             "apple,tunable-fabric",         40, True,  "dp.c:55, combo.h:40"),
    ("atc", "tunable_ATC_COMMON_CFG",         "apple,tunable-common-cfg",     43, True,  "dp.c:56, combo.h:41"),
    ("atc", "tunable_ATC0AXI2AF_LIOA",        "apple,tunable-lioa",           42, True,  "dp.c:56, combo.h:41"),
    ("atc", "tunable_LN0_RX_CFG_TX_OF_RXCLK", "apple,tunable-lane0-rx-clock", 20, True,  "dp.c:57, combo.h:42"),
    ("atc", "tunable_LN1_RX_CFG_TX_OF_RXCLK", "apple,tunable-lane1-rx-clock", 29, True,  "dp.c:57, combo.h:42"),
    ("atc", "tunable_LN0_RX_EQ_DFLT",         "apple,tunable-lane0-rx-eq",    18, True,  "dp.c:58, combo.h:43"),
    ("atc", "tunable_LN1_RX_EQ_DFLT",         "apple,tunable-lane1-rx-eq",    27, True,  "dp.c:58, combo.h:43"),
    ("atc", "tunable_AUSPLL_CORE",            "apple,tunable-auspll",          8, True,  "dp.c:59, combo.h:44"),
    # index >= 9: only parsed when the node has mode-switch (dp.c:724)
    ("atc", "tunable_AUS40CMN_SHM",           "apple,tunable-aus40cmn-shm",    5, True,  "dp.c:60, typec only"),
    ("atc", "tunable_CIO4PLL_CORE",           "apple,tunable-cio4pll",        10, True,  "dp.c:60, typec only"),
    # combo_setup(), atc-t6050-combo.h:398-409 (combo only, silent -ENOENT if absent)
    ("atc", "tunable_USB2PHY_DFLT",           "apple,tunable-usb2-default",    0, True,  "combo.h:398"),
    ("atc", "tunable_USB2PHY_HOST",           "apple,tunable-usb2-host",       0, True,  "combo.h:402"),
    ("drd", "tunable_PIPE_HANDLER_DEFAULT",   "apple,tunable-pipe-default",   44, True,  "combo.h:406"),
]

# ADT tunables the driver does not consume (reported, not emitted)
UNUSED = {
    "tunable_USB2PHY_DEV": "USB2 device mode; combo PHY is host-only (combo_usb2_mode)",
    "tunable_LN0_RX_TOP_CIO_DFLT": "CIO/USB4 only",
    "tunable_LN1_RX_TOP_CIO_DFLT": "CIO/USB4 only",
    "tunable_UC_REGS_CIO_DFLT": "CIO/USB4 only (empty in ADT)",
    "tunable_LN0_RX_EQ_CIO_DFLT": "CIO/USB4 only (empty in ADT)",
    "tunable_LN1_RX_EQ_CIO_DFLT": "CIO/USB4 only (empty in ADT)",
}

CORE_SIZE = 0x2c000  # driver minimum for a combo "core" (dp.c:638); matches the DT reg


def load(adt_path):
    sys.path.insert(0, M1N1_PROXY)
    from m1n1.adt import load_adt
    with open(adt_path, "rb") as f:
        return load_adt(f.read())


def regs(node):
    out = []
    while True:
        try:
            out.append(node.get_reg(len(out)))
        except Exception:
            return out


def bank_window(bank, atc_regs, drd_regs):
    """(base, size) the driver bounds-checks a tunable of this bank against."""
    if bank == 44:
        return drd_regs[3]
    if bank in (0, 1) or bank >= 36:
        return atc_regs[bank]
    core = atc_regs[2][0]
    base = atc_regs[bank][0]
    return base, core + CORE_SIZE - base  # core bank: to the end of "core"


def records(raw, name):
    if raw is None or len(raw) == 0:
        return []
    if len(raw) % 12:
        raise ValueError(f"{name}: length {len(raw)} not a multiple of 12")
    out = []
    for i in range(0, len(raw), 12):
        w0, mask, value = struct.unpack_from("<III", raw, i)
        out.append((w0 & 0xffffff, w0 >> 24, mask, value))
    return out


def generate(adt, idx):
    atc = adt[f"/arm-io/atc-phy{idx}"]
    try:
        drd = adt[f"/arm-io/usb-drd{idx}"]
    except Exception:
        drd = None
    atc_regs = regs(atc)
    drd_regs = regs(drd) if drd is not None else []
    if len(atc_regs) < 44:
        raise SystemExit(f"atc-phy{idx}: expected 44 reg windows, found {len(atc_regs)}")
    if drd is not None and drd_regs[4] != atc_regs[1]:
        raise SystemExit(f"usb-drd{idx} reg[4] != atc-phy{idx} reg[1]: drd/atc pairing is wrong")
    props, problems, info = [], [], []
    for src, aname, fname, bank, required, ref in MAP:
        node = atc if src == "atc" else drd
        if node is None:
            problems.append(f"{fname}: no usb-drd{idx} in ADT (needed for {aname})")
            continue
        raw = node._properties.get(aname)
        if raw is None or not isinstance(raw, (bytes, bytearray)) or len(raw) == 0:
            (problems if required else info).append(f"{fname}: ADT {aname} missing/empty")
            continue
        base, size = bank_window(bank, atc_regs, drd_regs)
        recs = records(raw, aname)
        for off, bits, mask, value in recs:
            if bits != 32:
                problems.append(f"{aname}: record size {bits} != 32")
            if off % 4:
                problems.append(f"{aname}: unaligned offset {off:#x}")
            if off > size - 4:
                problems.append(f"{aname}: offset {off:#x} beyond bank {bank} window {size:#x}")
            if value & ~mask:
                info.append(f"{aname}: value {value:#x} sets bits outside mask {mask:#x} at {off:#x}")
        props.append((fname, aname, src, bank, base, size, ref, recs))
    unused = [(k, UNUSED[k]) for k in atc._properties if k in UNUSED]
    meta = dict(port=int(atc._properties.get("port-number", -1)),
                ptype=int(atc._properties.get("port-type", -1)),
                core=atc_regs[2][0], pipe=drd_regs[3][0] if drd_regs else None)
    return props, problems, info, unused, meta


def fmt(idx, props, problems, info, unused, meta):
    L = []
    L.append(f"/* ADT /arm-io/atc-phy{idx} (port-number {meta['port']}, port-type {meta['ptype']}), "
             f"core {meta['core']:#x}" + (f", pipehandler {meta['pipe']:#x}" if meta['pipe'] else "") + " */")
    L.append("/* Generated by gen-atc-tunables.py: <offset mask value> per record, offsets relative to")
    L.append("   the driver bank named in each comment, copied verbatim from the ADT record. */")
    for fname, aname, src, bank, base, size, ref, recs in props:
        L.append(f"/* {aname} ({'usb-drd' if src == 'drd' else 'atc-phy'}{idx}) -> bank {bank} "
                 f"@ {base:#x}, window {size:#x}; {ref} */")
        body = "\n\t\t".join(f"0x{o:x} 0x{m:x} 0x{v:x}" for o, _, m, v in recs)
        L.append(f"{fname} = <{body}>;")
    if unused:
        L.append("/* Present in the ADT, not consumed by the driver: " +
                 "; ".join(f"{k} ({why})" for k, why in unused) + " */")
    for p in problems:
        L.append(f"/* PROBLEM: {p} */")
    for p in info:
        L.append(f"/* note: {p} */")
    return "\n".join(L) + "\n"


def check_dts(path, idx, meta, props):
    """Check the DTS node at the ADT core address carries the same windows."""
    text = open(path).read()
    m = re.search(r"phy@%x \{(.*?)\n\t\t\};" % meta["core"], text, re.S)
    if not m:
        return [f"DTS: no phy@{meta['core']:x} node"]
    node = m.group(1)
    cells = [int(x, 16) for x in re.search(r"reg = <([^>]*)>", node).group(1).split()]
    names = re.findall(r'"([^"]+)"', re.search(r"reg-names = ([^;]*);", node).group(1))
    win = {n: ((cells[4*i] << 32) | cells[4*i+1], (cells[4*i+2] << 32) | cells[4*i+3])
           for i, n in enumerate(names)}
    want = {41: "axi2af", 40: "fabric", 42: "lioa", 43: "common-cfg", 0: "usb2phy", 44: "pipehandler"}
    out = []
    for fname, aname, src, bank, base, size, ref, recs in props:
        if bank in want:
            b, s = win.get(want[bank], (None, None))
            if b != base or s != size:
                out.append(f"DTS {want[bank]} = {b and hex(b)}/{s and hex(s)} but ADT bank {bank} = {base:#x}/{size:#x}")
        else:
            b, s = win["core"]
            if not (b <= base < b + s) or b + s - base != size:
                out.append(f"DTS core window does not cover bank {bank} like the ADT")
    return out or [f"DTS phy@{meta['core']:x}: every tunable bank matches its DT reg window"]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--adt", default=os.path.expanduser("~/Work/studio-artifacts/adt-runtime-j716s.bin"))
    ap.add_argument("--atc", type=int, required=True)
    ap.add_argument("-o", "--output")
    ap.add_argument("--check-dts")
    a = ap.parse_args()
    adt = load(a.adt)
    props, problems, info, unused, meta = generate(adt, a.atc)
    text = fmt(a.atc, props, problems, info, unused, meta)
    if a.output:
        open(a.output, "w").write(text)
    else:
        sys.stdout.write(text)
    if a.check_dts:
        for line in check_dts(a.check_dts, a.atc, meta, props):
            print(line, file=sys.stderr)
    for p in problems:
        print(f"atc-phy{a.atc}: PROBLEM {p}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
