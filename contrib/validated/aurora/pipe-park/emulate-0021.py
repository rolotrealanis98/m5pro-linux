#!/usr/bin/env python3
"""Emulate 0021 (dt_copy_atc_t6050_tunables) on the J716s runtime ADT and compare the result
with the 14 apple,tunable-* properties baked into a DTB. Run with the m1n1 proxyclient venv:
  PYTHONPATH=<m1n1>/proxyclient <venv>/python -I emulate-0021.py ADT DTB PORT"""
import struct, subprocess, sys, re
from m1n1.adt import load_adt

TABLE = [  # adt name, fdt name, from_drd, resource, bank offset (copy of 0021)
    ("tunable_ATC0AXI2AF", "apple,tunable-axi2af", False, "axi2af", 0),
    ("tunable_ATC_FABRIC", "apple,tunable-fabric", False, "fabric", 0),
    ("tunable_ATC_COMMON_CFG", "apple,tunable-common-cfg", False, "common-cfg", 0),
    ("tunable_ATC0AXI2AF_LIOA", "apple,tunable-lioa", False, "lioa", 0),
    ("tunable_LN0_RX_CFG_TX_OF_RXCLK", "apple,tunable-lane0-rx-clock", False, "core", 0xd000),
    ("tunable_LN1_RX_CFG_TX_OF_RXCLK", "apple,tunable-lane1-rx-clock", False, "core", 0x1d000),
    ("tunable_LN0_RX_EQ_DFLT", "apple,tunable-lane0-rx-eq", False, "core", 0xb000),
    ("tunable_LN1_RX_EQ_DFLT", "apple,tunable-lane1-rx-eq", False, "core", 0x1b000),
    ("tunable_AUSPLL_CORE", "apple,tunable-auspll", False, "core", 0x3200),
    ("tunable_AUS40CMN_SHM", "apple,tunable-aus40cmn-shm", False, "core", 0xa00),
    ("tunable_CIO4PLL_CORE", "apple,tunable-cio4pll", False, "core", 0x3a00),
    ("tunable_USB2PHY_DFLT", "apple,tunable-usb2-default", False, "usb2phy", 0),
    ("tunable_USB2PHY_HOST", "apple,tunable-usb2-host", False, "usb2phy", 0),
    ("tunable_PIPE_HANDLER_DEFAULT", "apple,tunable-pipe-default", True, "pipehandler", 0),
]

def dtb_node(dtc, dtb, unit):
    dts = subprocess.run([dtc, "-q", "-I", "dtb", "-O", "dts", dtb], capture_output=True,
                         text=True, check=True).stdout
    m = re.search(r"phy@%s \{(.*?)\n\t\t\};" % unit, dts, re.S)
    node = m.group(1)
    props = {}
    for name, body in re.findall(r"\s(apple,tunable-[\w-]+) = <([^>]*)>;", node):
        props[name] = [int(x, 16) for x in body.split()]
    names = re.search(r'reg-names = (.*?);', node, re.S).group(1)
    names = re.findall(r'"([^"]+)"', names)
    regs = [int(x, 16) for x in re.search(r"\sreg = <([^>]*)>;", node).group(1).split()]
    res = {n: ((regs[4*i] << 32) | regs[4*i+1], (regs[4*i+2] << 32) | regs[4*i+3])
           for i, n in enumerate(names)}
    return props, res

adt_path, dtb, port, dtc = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
adt = load_adt(open(adt_path, "rb").read())
atc, drd = adt["/arm-io/atc-phy%d" % port], adt["/arm-io/usb-drd%d" % port]
unit = "%x" % atc.get_reg(2)[0]
props, res = dtb_node(dtc, dtb, unit)
ok = True
for adt_name, fdt_name, from_drd, resource, bank_off in TABLE:
    raw = getattr(drd if from_drd else atc, adt_name.replace("-", "_"), None)
    if raw is None:
        raw = (drd if from_drd else atc)._properties[adt_name]
    if not isinstance(raw, bytes):
        raw = bytes(raw)
    window = res[resource][1] - bank_off
    gen = []
    for off_size, mask, value in struct.iter_unpack("<III", raw):
        off, size = off_size & 0xffffff, off_size >> 24
        assert size == 32 and off % 4 == 0 and off + 4 <= window, (adt_name, hex(off))
        gen += [off, mask, value]
    same = gen == props.get(fdt_name)
    ok &= same
    print("%-30s %-30s %3d tuples  %s" % (adt_name, fdt_name, len(gen) // 3,
                                          "identical" if same else "DIFFERENT"))
extra = set(props) - {t[1] for t in TABLE}
print("DTB tunables not produced by 0021:", sorted(extra) or "none")
print("RESULT:", "identical" if ok and not extra else "differs")
