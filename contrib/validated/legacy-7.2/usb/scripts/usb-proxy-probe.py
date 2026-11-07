#!/usr/bin/env python3
"""USB-C stage 0 on T6050: confirm what the USB 2.0 host DT assumes, from the
m1n1 proxy, before any Linux boot with it. Read-mostly; see --pd below.

Run from the tether bundle (hv/ next to proxyclient/) or with PYTHONPATH set,
with the M5 sitting in the m1n1 proxy (so usb_init/usb_phy_bringup has run):

    usb-proxy-probe.py            # ADT port map + usb2phy registers (reads only)
    usb-proxy-probe.py --pd       # + USB-PD controllers over SPMI (see below)
    usb-proxy-probe.py --pd --wake

Part 1 (always, reads only):
  - ADT usb-drdN / atc-phyN / dart-usbN regs and port-number, and whether
    atc-phyN reg[0] equals the usb2phy address t6050-usb-host.dtsi assumes.
  - The usb2phy registers m1n1 programmed (USBCTL, CTL, SIG, MISCTUNE), each
    read behind m1n1's exception guard. Expected after m1n1's usb_phy_bringup:
    USBCTL=0x2, SIG=0x01c1000f, MISCTUNE=0x008c0813.

Part 2 (--pd): for every sn201202x under a nub-spmi bus, read the TPS
registers VID, MODE, SYSTEM_POWER_STATE, STATUS, POWER_STATUS, DATA_STATUS
with the register-select protocol (a zero-write of the register number, then
poll register 0; data at extended register 0x20). The zero-write only moves
the controller's register pointer. Every loop is bounded: m1n1's own C loop
on this protocol is what hung usb_init on T6050 (patches/m1n1/0005), so this
is also where we find out why. --wake first sends SPMI WAKEUP to each
controller (what m1n1 and Linux do before talking to it); without it nothing
but the select/read protocol is sent. Never sends SLEEP/SHUTDOWN, never
writes a TPS register, never issues a 4CC command.
"""
import argparse
import pathlib
import sys
import time

sys.path.append(str(pathlib.Path(__file__).resolve().parents[1] / "proxyclient"))
from m1n1.setup import *            # noqa: F401,F403  (u, p)
from m1n1.proxy import ProxyError, GUARD
from m1n1.hw.spmi import SPMI

INFERRED_USB2PHY = {0: 0x2a2a90000, 1: 0x2aaa90000, 2: 0x382a90000}
USB2PHY_REGS = (("USBCTL", 0x00), ("CTL", 0x04), ("SIG", 0x08), ("MISCTUNE", 0x1c))
LOAD = "ldr w0, [x0]\n dsb sy\n isb"

TPS_REGS = (("VID", 0x00, 4), ("MODE", 0x03, 4), ("SYSTEM_POWER_STATE", 0x20, 1),
            ("STATUS", 0x1a, 8), ("POWER_STATUS", 0x3f, 2), ("DATA_STATUS", 0x5f, 5))


def guarded_read32(addr):
    try:
        return u.exec(LOAD, addr, silent=True) & 0xffffffff
    except ProxyError:
        return None


def adt_node(path):
    try:
        return u.adt[path]
    except KeyError:
        return None


def part1():
    print("== USB-C ports (ADT) and usb2phy state")
    for i in range(4):
        d = adt_node(f"/arm-io/usb-drd{i}")
        a = adt_node(f"/arm-io/atc-phy{i}")
        if d is None:
            continue
        port = getattr(d, "port_number", "?")
        regs = []
        for k in range(8):
            try:
                regs.append(d.get_reg(k))
            except Exception:
                break
        print(f"usb-drd{i}: port-number {port}, " +
              ", ".join(f"reg[{k}]={r[0]:#x}/{r[1]:#x}" for k, r in enumerate(regs)))
        if a is None:
            print(f"  atc-phy{i}: absent")
            continue
        phy = a.get_reg(0)[0]
        exp = INFERRED_USB2PHY.get(i)
        verdict = "matches dtsi" if phy == exp else f"DIFFERS from dtsi ({exp:#x})" if exp else ""
        print(f"  atc-phy{i} reg[0] (usb2phy) = {phy:#x}  {verdict}")
        vals = []
        for name, off in USB2PHY_REGS:
            v = guarded_read32(phy + off)
            vals.append(f"{name}={'SError' if v is None else f'{v:#010x}'}")
        print("  " + " ".join(vals))
    print()


def first_byte(v):
    """hpm 'reg': m1n1 tps6598x_init() uses its first byte as the SPMI SID."""
    if isinstance(v, int):
        return v & 0xff
    if isinstance(v, (bytes, bytearray)):
        return v[0]
    if isinstance(v, (list, tuple)) and v:
        return first_byte(v[0])
    if hasattr(v, "addr"):
        return first_byte(v.addr)
    raise ValueError(f"cannot read SID from {v!r}")


def select(spmi, sid, reg, deadline_s=0.2):
    spmi.write_zero(sid, reg)
    end = time.time() + deadline_s
    n = 0
    while True:
        v = spmi.read_reg(sid, 0)
        n += 1
        if v == reg:
            return True, n, v
        if v != (reg | 0x80):
            return False, n, v
        if time.time() > end:
            return False, n, v


def tps_read(spmi, sid, reg, size):
    ok, n, v = select(spmi, sid, reg)
    if not ok:
        return None, f"select {reg:#04x} failed after {n} polls, reg0={v:#04x}"
    data = b""
    off = 0x20
    while len(data) < size:
        k = min(16, size - len(data))
        data += spmi.read_ext(sid, off, k)
        off += k
    return data, f"{n} poll(s)"


def part2(wake):
    print("== USB-PD controllers (sn201202x) over SPMI")
    p.set_exc_guard(GUARD.SKIP | GUARD.SILENT)
    try:
        for bus in u.adt["/arm-io"]:
            hpms = [c for c in bus if "usbc,sn201202x,spmi" in (getattr(c, "compatible", []) or [])]
            if not hpms:
                continue
            path = f"/arm-io/{bus.name}"
            gen = getattr(bus, "gen", "absent")
            base = bus.get_reg(0)[0]
            print(f"{path}: gen={gen} reg[0]={base:#x} interrupts={list(getattr(bus, 'interrupts', []))}")
            st = guarded_read32(base + (0x200 if gen == 4 else 0x0))
            print(f"  controller STATUS = {'SError' if st is None else f'{st:#010x}'}")
            if st is None:
                continue
            spmi = SPMI(u, path)
            for h in hpms:
                sid = first_byte(h._properties["reg"])
                print(f"  {h.name}: SID {sid:#x} interrupts={list(getattr(h, 'interrupts', []))}")
                try:
                    if wake:
                        spmi.wakeup(sid)
                        time.sleep(0.01)
                        print("    WAKEUP sent")
                    for name, reg, size in TPS_REGS:
                        data, how = tps_read(spmi, sid, reg, size)
                        if data is None:
                            print(f"    {name}: {how}")
                            break
                        txt = data.decode("ascii", "replace") if name == "MODE" else data.hex()
                        print(f"    {name} ({reg:#04x}) = {txt}  [{how}]")
                except Exception as e:
                    print(f"    error: {e}")
            print(f"  exceptions during this bus: {p.get_exc_count()}")
    finally:
        p.set_exc_guard(GUARD.OFF)


ap = argparse.ArgumentParser()
ap.add_argument("--pd", action="store_true")
ap.add_argument("--wake", action="store_true")
args = ap.parse_args()
part1()
if args.pd:
    part2(args.wake)
