# SPDX-License-Identifier: MIT
# run_guest.py -m module: MMIO trace hooks for the hv27 targets on the J716s (T6050), all taken from the
# ADT at run time (no addresses hard-coded). Choose groups with HV27_TRACE, comma-separated:
#   sep     SEP ASC: CPU control page + mailbox window (reg[0] + 0x8000), and its reg[1] page
#   esm     the Exclave SEP manager page (/arm-io/esm, exclave-assigned: accesses come from the cL4 VM)
#   isp     the exclave ISP proxy windows (/arm-io/isp-exclave-s-proxy, camera indicator path) and isp0 reg[1..2]
#   ave     AVE encoder (/arm-io/ave0, every reg)
#   apr     ProRes engine (/arm-io/apr0, every reg)
#   dcp     internal DCP ASC: CPU control page, mailbox window, reg[1] (NOT disp0: too hot)
#   darts   writes only, to dart-sep, dart-isp0, dart-ave0, dart-apr0, dart-dcp (page-table base / enable)
#   all     everything above
# Every traced range is unmapped from the guest and emulated by m1n1, so each access costs a round trip
# through the hypervisor; the mailbox windows are small on purpose. Mode: HV27_TRACE_MODE=async|sync
# (default async; sync stalls the guest until the host has logged the access, exact ordering).
import os
from m1n1.utils import irange
from m1n1.hv import TraceMode

groups = {g.strip() for g in os.environ.get("HV27_TRACE", "").split(",") if g.strip()}
if "all" in groups:
    groups = {"sep", "esm", "isp", "ave", "apr", "dcp", "darts"}
# "smc": the SMC ASC (steady, moderate traffic once AppleSMC starts): the delivery check for live tracing
mode = TraceMode.SYNC if os.environ.get("HV27_TRACE_MODE", "async") == "sync" else TraceMode.ASYNC

def _h27_reg(path, i):
    return hv.adt[path].get_reg(i)

def _h27_tr(name, base, size, read=True):
    hv.trace_range(irange(base, size), mode, read=read, write=True, name=name)
    print(f"hv27-trace: {name:<22} {base:#x}+{size:#x}{'' if read else ' (writes only)'}")

_h27_mbox_only = os.environ.get("HV27_TRACE_MBOX_ONLY") == "1"   # only the mailbox page per ASC (cheapest, hot path)
def _h27_asc(name, path):
    base, _ = _h27_reg(path, 0)
    _h27_tr(f"{name}.mbox", base + 0x8000, 0x4000)
    if _h27_mbox_only: return
    _h27_tr(f"{name}.cpu", base, 0x100)
    b1, s1 = _h27_reg(path, 1)
    _h27_tr(f"{name}.reg1", b1, s1)

def _h27_whole(name, path):
    node = hv.adt[path]
    spans = sorted((*node.get_reg(i), i) for i in range(len(node.reg)))
    merged = []   # apr0's reg[3] and reg[4] overlap: one tracer per merged span
    for b, s, i in spans:
        if merged and b <= merged[-1][0] + merged[-1][1]:
            mb, ms, mi = merged[-1]
            merged[-1] = (mb, max(mb + ms, b + s) - mb, f"{mi}+{i}")
        else:
            merged.append((b, s, str(i)))
    for b, s, i in merged:
        _h27_tr(f"{name}.reg{i}", b, s)

def _h27_dart_writes(name, path):
    try:
        b, s = _h27_reg(path, 0)
    except KeyError:
        print(f"hv27-trace: {path} missing"); return
    _h27_tr(name, b, s, read=False)

if "sep" in groups:
    _h27_asc("sep", "/arm-io/sep")
if "esm" in groups:
    _h27_whole("esm", "/arm-io/esm")
if "isp" in groups:
    _h27_whole("isp-exclave-s", "/arm-io/isp-exclave-s-proxy")
    for i in (1, 2):
        b, s = _h27_reg("/arm-io/isp0", i)
        _h27_tr(f"isp0.reg{i}", b, s)
if "ave" in groups:
    _h27_whole("ave0", "/arm-io/ave0")
if "apr" in groups:
    _h27_whole("apr0", "/arm-io/apr0")
if "dcp" in groups:
    _h27_asc("dcp", "/arm-io/dcp")
if "smc" in groups:
    _h27_asc("smc", "/arm-io/smc")
if "pmp" in groups:
    _h27_asc("pmp", "/arm-io/pmp0")
if "ptd" in groups:   # the PMP report region (PTD aperture, 0x14000): offsets status/tgt_read/tgt_write/actual/fast_die
    b, sz = hv.adt["/arm-io/pmp0"].get_reg(2) if len(hv.adt["/arm-io/pmp0"].reg) > 2 else (0x284240000, 0x14000)
    _h27_tr("pmp.ptd", 0x284240000, 0x14000)
if "pmc" in groups:
    try: _h27_whole("pmc", "/arm-io/pmc")
    except KeyError: print("hv27-trace: /arm-io/pmc missing")
if "sio" in groups:
    _h27_asc("sio", "/arm-io/sio")
if "aop" in groups:
    _h27_asc("aop", "/arm-io/aop")
if "acio" in groups:   # Thunderbolt/USB4 coprocessors (RTBuddy ACIO1/2 start in the guest; acio0 is the proxy port and stripped)
    for n in ("acio1", "acio2", "acio3"):
        try: _h27_asc(n, f"/arm-io/{n}")
        except KeyError: pass
if "n1x" in groups:   # deep N1: root-port and bus 1/2 config space, PERST/CLKREQ GPIO page, PMGR APCIE chain
    _h27_tr("apcie0.ecam", 0x1cb0000000, 0x300000)
    _h27_tr("gpio0.pcie", 0x29c000000, 0x4000)
    _h27_tr("pmgr.apcie", 0x280900100, 0x200)
    try:
        node = hv.adt["/arm-io/apcie0"]
        for i in range(1, len(node.reg)):
            b, sz = node.get_reg(i); _h27_tr(f"apcie0.reg{i}", b, sz)
    except KeyError: print("hv27-trace: /arm-io/apcie0 missing")
if "n1" in groups:   # N1 Wi-Fi: PCIe root complex regs (not the 256 MiB ECAM window) + the centauri node
    try:
        node = hv.adt["/arm-io/apcie0"]
        for i in range(1, len(node.reg)):
            b, sz = node.get_reg(i); _h27_tr(f"apcie0.reg{i}", b, sz)
    except KeyError: print("hv27-trace: /arm-io/apcie0 missing")
    # /arm-io/centauri has no reg (control node); the N1 endpoint itself lives behind the root port's ECAM
if "darts" in groups:
    for n in ("sep", "isp0", "ave0", "apr0", "dcp"):
        _h27_dart_writes(f"dart-{n}", f"/arm-io/dart-{n}")

print(f"hv27-trace: groups {sorted(groups) or 'none'}, mode {mode.name}")
