#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
T6050 USB-C: check t6050-usb-host.dtsi against the runtime ADT and generate
t6050-usb-pd.dtsi (SN201202x USB-PD controllers on nub-spmi-aN) from it.

    gen-usb-dt.py ADT.bin --check                 # port map + inferred-address check
    gen-usb-dt.py ADT.bin --dump                  # every USB/PD/SPMI node, all properties
    gen-usb-dt.py ADT.bin --pd [--host-port 1] [--all-hpm] > t6050-usb-pd.dtsi

Needs m1n1's proxyclient on PYTHONPATH (or M1N1_PROXYCLIENT), like
omarchy-m5 scripts/gen-storage-net-dt.py. No device access; read-only.

The ADT carries the serial number and MAC addresses: --dump prints only the
nodes below, never the whole tree, but do not commit its output unreviewed.
"""
import argparse
import os
import sys

sys.path.insert(0, os.environ.get('M1N1_PROXYCLIENT',
                                  os.path.expanduser('~/Work/m1n1/proxyclient')))
from m1n1 import adt  # noqa: E402

# usb2phy addresses t6050-usb-host.dtsi uses without ADT confirmation
INFERRED_USB2PHY = {0: 0x2a2a90000, 1: 0x2aaa90000, 2: 0x382a90000}
INFERRED_DWC3 = {0: 0x2a2280000, 1: 0x2aa280000, 2: 0x382280000}
# Asahi labels for t603x 16" (J516) hpm nodes, used only as a fallback
LABELS = {0: "USB-C Left-back", 1: "USB-C Left-front", 2: "USB-C Right"}


def node(dt, path):
    try:
        return dt[path]
    except KeyError:
        return None


def prop(n, name, default=None):
    return n._properties.get(name, default)


def first_byte(v):
    """hpm 'reg' (m1n1 tps6598x_init reads its first byte as the SID)."""
    if isinstance(v, int):
        return v & 0xff
    if isinstance(v, (bytes, bytearray)):
        return v[0]
    if isinstance(v, (list, tuple)) and v:
        return first_byte(v[0])
    if hasattr(v, 'addr'):
        a = v.addr
        return first_byte(a)
    raise ValueError(f"cannot read SID from {v!r}")


def fmt(v):
    if isinstance(v, (bytes, bytearray)):
        return v.hex()
    if isinstance(v, int):
        return hex(v)
    return repr(v)


def reg(n, idx):
    try:
        return n.get_reg(idx)
    except Exception:
        return None


def spmi_buses(dt):
    arm = dt['/arm-io']
    for n in arm:
        compat = prop(n, 'compatible') or []
        if isinstance(compat, str):
            compat = [compat]
        if any(c in ('aapl,spmi', 'spmi,gen3') for c in compat):
            yield n


def hpms(bus):
    for c in bus:
        compat = prop(c, 'compatible') or []
        if isinstance(compat, str):
            compat = [compat]
        if 'usbc,sn201202x,spmi' in compat:
            yield c


def cmd_dump(dt):
    paths = []
    for i in range(4):
        for p in (f'/arm-io/usb-drd{i}', f'/arm-io/atc-phy{i}', f'/arm-io/dart-usb{i}'):
            if node(dt, p) is not None:
                paths.append(p)
    for b in spmi_buses(dt):
        paths.append(b._path)
        paths += [h._path for h in hpms(b)]
    for p in paths:
        n = dt[p]
        print(f"== {p}")
        for k, v in n._properties.items():
            if k in ('name',):
                continue
            print(f"   {k} = {fmt(v)}")
        for i in range(12):
            r = reg(n, i)
            if r is None:
                break
            print(f"   reg[{i}] -> {r[0]:#x} size {r[1]:#x}")


def cmd_check(dt):
    ok = True
    print("drd  port  dwc3(reg0)       pipehandler(reg3)  atc-phy reg0 (usb2phy)  inferred     match")
    for i in range(3):
        d = node(dt, f'/arm-io/usb-drd{i}')
        a = node(dt, f'/arm-io/atc-phy{i}')
        if d is None or a is None:
            print(f"drd{i}: missing usb-drd{i} or atc-phy{i}")
            ok = False
            continue
        d0 = reg(d, 0)
        d3 = reg(d, 3)
        a0 = reg(a, 0)
        port = prop(d, 'port-number', '?')
        m = a0 and a0[0] == INFERRED_USB2PHY[i] and d0 and d0[0] == INFERRED_DWC3[i]
        ok &= bool(m)
        print(f"drd{i}  {port!s:4}  {d0[0]:#x}      {d3[0] if d3 else 0:#x}        "
              f"{a0[0]:#x} size {a0[1]:#x}  {INFERRED_USB2PHY[i]:#x}  {'OK' if m else 'MISMATCH'}")
    print()
    for b in spmi_buses(dt):
        hs = list(hpms(b))
        if not hs:
            continue
        r0 = reg(b, 0)
        print(f"{b._path}: gen={prop(b, 'gen', 'absent')} reg0={r0[0]:#x} "
              f"interrupts={fmt(prop(b, 'interrupts'))}")
        for h in hs:
            print(f"   {h.name}: SID={first_byte(prop(h, 'reg')):#x} "
                  f"interrupts={fmt(prop(h, 'interrupts'))}")
    print()
    print("usb2phy addresses in t6050-usb-host.dtsi:", "CONFIRMED" if ok else "WRONG, fix them")
    return 0 if ok else 1


def hpm_index(h):
    return int(h.name[3:]) if h.name[3:].isdigit() else None


def cmd_pd(dt, host_port, all_hpm=False):
    out = []
    w = out.append
    w("// SPDX-License-Identifier: GPL-2.0+ OR MIT")
    w("/*")
    w(" * T6050 SN201202x USB-PD controllers. GENERATED from the runtime ADT by")
    w(" * gen-usb-dt.py --pd. Include AFTER t6050-usb-host.dtsi.")
    w(" *")
    w(" * Gen >= 4 SPMI buses get no interrupts (Linux runs them polled, see")
    w(" * the omarchy-m5 SPMI gen 4 patch) and the hpm nodes get none either:")
    w(" * sn201202x then polls register selection and events (patch 0003).")
    w(f" * By default only the host port's controller (hpm{host_port}) is described,")
    w(" * so the other ports' PD controllers are not touched at all; --all-hpm")
    w(" * adds them, without role-switch links.")
    w(f" * Only the host port (T6050_USB_HOST_PORT = {host_port}) is linked to its")
    w(" * dwc3 role switch; the gadget ports' connectors have no endpoints, so")
    w(" * the PD driver never changes their data role.")
    w(" */")
    w("")
    w("#include <dt-bindings/spmi/spmi.h>")
    w("")
    w("&soc {")
    for b in spmi_buses(dt):
        hs = [h for h in hpms(b) if all_hpm or hpm_index(h) == host_port]
        if not hs:
            continue
        gen = prop(b, 'gen', -1)
        if isinstance(gen, (bytes, bytearray)):
            gen = int.from_bytes(gen[:4], 'little', signed=True)
        a, _ = b.get_reg(0)
        bname = b.name.replace('-', '_')          # nub_spmi_a0
        ints = list(prop(b, 'interrupts') or [])
        w(f"\t/* ADT {b._path}: gen {gen}, interrupts {ints} */")
        w(f"\t{bname}: spmi@{a:x} {{")
        if gen >= 4:
            w('\t\tcompatible = "apple,t6050-spmi";')
        else:
            w('\t\tcompatible = "apple,t8103-spmi";')
        w(f"\t\treg = <{a >> 32:#x} {a & 0xffffffff:#010x} 0x0 0x100>;")
        w("\t\t#address-cells = <2>;")
        w("\t\t#size-cells = <0>;")
        if gen < 4 and len(ints) >= 2:
            # same convention as nub-spmi0 in t6050-smc.dtsi: [256 (internal), AIC line, ...]
            w("\t\t#interrupt-cells = <2>;")
            w("\t\tinterrupt-controller;")
            w("\t\tinterrupt-parent = <&aic>;")
            w(f"\t\tinterrupts = <AIC_IRQ {ints[1]} IRQ_TYPE_LEVEL_HIGH>;")
        w(f"\t\tpower-domains = <&ps_{bname}>;")
        w("")
        for h in hs:
            sid = first_byte(prop(h, 'reg'))
            idx = hpm_index(h)
            hi = list(prop(h, 'interrupts') or [])
            w(f"\t\t/* ADT {h._path}: interrupts {hi} */")
            w(f"\t\t{h.name}: usb-pd@{sid:x} {{")
            w('\t\t\tcompatible = "apple,sn201202x";')
            w(f"\t\t\treg = <{sid:#x} SPMI_USID>;")
            if gen < 4 and hi:
                base = hi[0]
                # Asahi t8122/t603x: irq, select = +2, sleep = +6, wake = +8
                w(f"\t\t\t/* [INFERENCE] select/sleep/wake = irq + 2/6/8 like t8122/t603x;")
                w(f"\t\t\t * check against the raw ADT list above */")
                w(f"\t\t\tinterrupts = <{base} IRQ_TYPE_EDGE_RISING>,")
                w(f"\t\t\t\t<{base + 2} IRQ_TYPE_EDGE_RISING>,")
                w(f"\t\t\t\t<{base + 6} IRQ_TYPE_EDGE_RISING>,")
                w(f"\t\t\t\t<{base + 8} IRQ_TYPE_EDGE_RISING>;")
                w('\t\t\tinterrupt-names = "irq", "select", "sleep", "wake";')
            if idx is not None and idx in (0, 1, 2):
                w("")
                w(f"\t\t\ttypec{idx}: connector {{")
                w('\t\t\t\tcompatible = "usb-c-connector";')
                w(f'\t\t\t\tlabel = "{LABELS[idx]}";')
                w('\t\t\t\tpower-role = "dual";')
                w('\t\t\t\tdata-role = "dual";')
                if idx == host_port:
                    w("")
                    w("\t\t\t\tports {")
                    w("\t\t\t\t\t#address-cells = <1>;")
                    w("\t\t\t\t\t#size-cells = <0>;")
                    w("\t\t\t\t\tport@0 {")
                    w("\t\t\t\t\t\treg = <0>;")
                    w(f"\t\t\t\t\t\ttypec{idx}_connector_hs: endpoint {{")
                    w(f"\t\t\t\t\t\t\tremote-endpoint = <&dwc3_{idx}_hs>;")
                    w("\t\t\t\t\t\t};")
                    w("\t\t\t\t\t};")
                    w("\t\t\t\t};")
                w("\t\t\t};")
            w("\t\t};")
            w("")
        w("\t};")
        w("")
    w("};")
    w("")
    w(f"&dwc3_{host_port} {{")
    w("\tport {")
    w(f"\t\tdwc3_{host_port}_hs: endpoint {{")
    w(f"\t\t\tremote-endpoint = <&typec{host_port}_connector_hs>;")
    w("\t\t};")
    w("\t};")
    w("};")
    print("\n".join(out))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('adt')
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--check', action='store_true')
    g.add_argument('--dump', action='store_true')
    g.add_argument('--pd', action='store_true')
    ap.add_argument('--host-port', type=int, default=1)
    ap.add_argument('--all-hpm', action='store_true',
                    help='also describe the gadget ports\' (and hpm5) PD controllers')
    a = ap.parse_args()
    dt = adt.load_adt(open(a.adt, 'rb').read())
    if a.check:
        return cmd_check(dt)
    if a.dump:
        return cmd_dump(dt)
    return cmd_pd(dt, a.host_port, a.all_hpm)


if __name__ == '__main__':
    sys.exit(main())
