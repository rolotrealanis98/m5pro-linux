#!/usr/bin/env python3
"""Decode the sep/dcp/smc mailbox windows of an m1n1 hypervisor MMIO trace.

usage: mbox-decode.py TRACE.log [--dev sep|dcp|smc|pmp] [--polls]

Mailbox layout (Apple ASC, as in m1n1 hw/asc.py and Linux apple-mailbox):
  +0x110 A2I_CTRL   (status of the AP->coprocessor FIFO)
  +0x114 I2A_CTRL   (status of the coprocessor->AP FIFO)
  +0x800 A2I_MSG0 / +0x808 A2I_MSG1   (a send is complete when MSG1 is written)
  +0x830 I2A_MSG0 / +0x838 I2A_MSG1   (a receive pops when MSG1 is read)
CTRL word: FIFOCNT 23:20, OVERFLOW 18, EMPTY 17, FULL 16, RPTR 15:12,
           WPTR 11:8, ENABLE 0.
I2A_MSG1 read-back: OUTCNT 56:52, INCNT 51:48, OUTPTR 47:44, INPTR 43:40
           (FIFO state, not payload); bits 7:0 are the RTKit endpoint.

Decoders:
  RTKit  (dcp, smc, pmp): endpoint = MSG1[7:0]; mgmt (ep 0) type = MSG0[59:52].
  PMP app endpoint 0x20: TYPE = MSG0[55:48] (m1n1 proxyclient/experiments/pmp_init.py).
  SEP    : own format, ep = MSG0[7:0], tag 15:8, type/opcode 23:16,
           param 31:24, data 63:32 (m1n1 hw/sep.py SEPMessage; Linux
           drivers/soc/apple/proto.rs).  ep 0xFD = discovery, 0xFE = shmem,
           0xFF = boot ROM, 0x00 = control.
Pure offline parser: reads the log only.
"""
import re
import sys
import argparse
from collections import OrderedDict

LINE = re.compile(
    r"^\[cpu(\d+)\] \[0x([0-9a-f]+)\] MMIO: ([RW])\.(\d)\s+\+?\s*0x([0-9a-f]+) "
    r"\((\w+)\.mbox, offset 0x([0-9a-f]+)\) = 0x([0-9a-f]+)")


# ---------------------------------------------------------------- helpers
def ctrl_str(v):
    f = []
    f.append(f"cnt={(v >> 20) & 0xf}")
    f.append(f"rptr={(v >> 12) & 0xf}")
    f.append(f"wptr={(v >> 8) & 0xf}")
    if v & (1 << 18):
        f.append("OVERFLOW")
    if v & (1 << 17):
        f.append("EMPTY")
    if v & (1 << 16):
        f.append("FULL")
    f.append(f"en={v & 1}")
    return ",".join(f)


def ascii4(v):
    """4 chars, most significant byte first (how m1n1 sep.py builds names)."""
    s = "".join(chr((v >> (8 * i)) & 0xff) for i in (3, 2, 1, 0))
    return s if all(32 <= ord(c) < 127 for c in s) else None


# -------------------------------------------------------------- SEP decode
SEP_EP_NAMES = {0xfd: "discover", 0xfe: "shmem", 0xff: "boot"}
SEP_CTRL_OPS = {0x00: "NOP", 0x01: "REPLY", 0x02: "OOL_IN_ADDR", 0x03: "OOL_OUT_ADDR",
                0x04: "OOL_IN_SIZE", 0x05: "OOL_OUT_SIZE", 0x14: "SECMODE",
                0x18: "(0x18, wedges per Linux note)", 0x36: "GET_ENTROPY"}


def sep_fields(m0):
    return dict(ep=m0 & 0xff, tag=(m0 >> 8) & 0xff, ty=(m0 >> 16) & 0xff,
                param=(m0 >> 24) & 0xff, data=(m0 >> 32) & 0xffffffff)


def sep_decode(direction, m0, m1, state):
    f = sep_fields(m0)
    ep, tag, ty, par, data = f["ep"], f["tag"], f["ty"], f["param"], f["data"]
    base = (f"ep={ep:#04x} tag={tag:#04x} type={ty:#04x} param={par:#04x} "
            f"data={data:#010x}")
    if ep == 0xfd:
        if ty == 0:
            nm = ascii4(data)
            state["eps"][par] = nm
            return f"{base} | DISCOVER descriptor: endpoint {par:#04x} name '{nm}'"
        if ty == 1:
            return (f"{base} | DISCOVER config for endpoint {par:#04x} "
                    f"('{state['eps'].get(par)}') cfg bytes "
                    f"{[(data >> (8 * i)) & 0xff for i in (3, 2, 1, 0)]}")
        return f"{base} | DISCOVER other"
    if ep == 0xfe and direction == "A2I":
        size = ty * 0x1000
        iova = data << 12
        return (f"{base} | SHMEM registration: size field {ty:#x} -> {size:#x} bytes, "
                f"iova field {data:#x} -> iova {iova:#x}")
    if ep == 0xff:
        return f"{base} | BOOT ROM type {ty:#x}"
    if ep == 0x00:
        nm = SEP_CTRL_OPS.get(ty, "?")
        if direction == "A2I":
            extra = ""
            if ty in (2, 3, 4, 5):
                extra = f" for ep {par:#04x} ('{state['eps'].get(par)}')"
                if ty in (4, 5):
                    extra += f" len={data:#x}"
                else:
                    extra += f" iova={data << 12:#x}"
            state["pending"].append((tag, nm))
            return f"{base} | CONTROL request {nm}{extra}"
        # I2A on control endpoint
        req = None
        for i, (t, n) in enumerate(state["pending"]):
            if t == tag:
                req = n
                del state["pending"][i]
                break
        return (f"{base} | CONTROL I2A type {ty:#x}"
                f"{' (reply?)' if ty == 1 else ' (unsolicited / unknown)'}"
                f"{' to ' + req if req else ''}")
    nm = state["eps"].get(ep)
    if ep == 0x13:
        # Linux xarm.rs: bytes = [ep, tag, opcode|status, len_lo, len_hi, arg0, arg1, arg2]
        b = m0.to_bytes(8, "little")
        who = "request" if direction == "I2A" else "reply"
        ops = {0x00: "ROOT_READ", 0x01: "ROOT_WRITE", 0x05: "SESSION_READ", 0x06: "SESSION_WRITE",
               0x07: "SESSION_DELETE", 0x0e: "QUERY_PROTECTED", 0x13: "GET_OS_UUID"}
        return (f"{base} | xarm {who}: tag={b[1]:#04x} "
                f"{'opcode' if direction == 'I2A' else 'status'}={b[2]:#04x}"
                f"({ops.get(b[2], '?') if direction == 'I2A' else ''}) "
                f"len={b[3] | (b[4] << 8):#x} args={b[5]:#04x},{b[6]:#04x},{b[7]:#04x}")
    if ep == 0x0e:
        return f"{base} | 'hdcp' endpoint message (format not known; tag/type/param shown)"
    if ep == 0x18:
        return f"{base} | 'stac' endpoint message (format not known; tag/type/param shown)"
    if ep == 0x10:
        return f"{base} | 'xars' endpoint message (format not known; tag/type/param shown)"
    return f"{base} | endpoint '{nm}'" if nm else base


# ------------------------------------------------------------ RTKit decode
# Linux drivers/soc/apple/rtkit.c, m1n1 fw/asc/{mgmt,syslog,ioreporting,oslog,crash}.py
RTK_EP_NAMES = {0: "mgmt", 1: "crashlog", 2: "syslog", 3: "debug/kdebug", 4: "ioreport",
                8: "oslog", 0x20: "app0x20", 0x37: "dcpep(IOMFB)"}
MGMT_TYPES = {1: "HELLO", 2: "HELLO_ACK", 3: "PING", 4: "PONG", 5: "STARTEP",
              6: "SET_IOP_PWR", 7: "IOP_PWR_ACK", 8: "EPMAP", 0xb: "SET_AP_PWR/ACK",
              0xf: "type0xf(undocumented in m1n1/Linux)"}
SMC_CMDS = {0x10: "READ_KEY", 0x11: "WRITE_KEY", 0x12: "GET_KEY_BY_INDEX",
            0x13: "GET_KEY_INFO", 0x17: "INITIALIZE", 0x18: "NOTIFICATION", 0x20: "RW_KEY"}
KDEBUG = {1: "GET_BUFFER/SET_BUFFER0", 2: "SET_BUFFER1/PREALLOC0", 3: "PREALLOC1", 8: "START"}


def key4(v):
    s = "".join(chr((v >> (8 * i)) & 0xff) for i in (3, 2, 1, 0))
    return s if all(32 <= ord(c) < 127 for c in s) else f"{v:#010x}"


def rtkit_decode(direction, m0, m1, state):
    ep = m1 & 0xff
    nm = RTK_EP_NAMES.get(ep, f"ep{ep:#x}")
    pre = f"ep={ep:#x}({nm}) "
    if ep == 0:
        t = (m0 >> 52) & 0xff
        tn = MGMT_TYPES.get(t, f"type{t:#x}")
        d = ""
        if t in (1, 2):
            d = f" min_ver={m0 & 0xffff} max_ver={(m0 >> 16) & 0xffff}"
        elif t == 5:
            d = f" ep={(m0 >> 32) & 0xff:#x} flag={(m0 >> 1) & 1} ({'start' if m0 & 2 else 'stop'})"
        elif t in (6, 7, 0xb):
            d = f" state={m0 & 0xffff:#x}"
        elif t == 8:
            last = (m0 >> 51) & 1
            base = (m0 >> 32) & 7
            bm = m0 & 0xffffffff
            eps = [32 * base + i for i in range(32) if bm & (1 << i)]
            if direction == "I2A":
                d = f" last={last} base={base} bitmap={bm:#010x} eps={[hex(e) for e in eps]}"
                state["epmap"].extend(eps)
            else:
                d = f" (AP reply) last={last} base={base} more={m0 & 1}"
        return pre + tn + d
    if ep == 1:  # crashlog (m1n1 crash.py): TYPE 63:52 SIZE 51:44 DVA 43:0
        t = (m0 >> 52) & 0xfff
        if t == 1:
            return (pre + f"BUFFER_REQUEST size={((m0 >> 44) & 0xff) << 12:#x} "
                    f"addr={m0 & 0xfffffffffff:#x}" +
                    (" (firmware-placed)" if direction == "I2A" and m0 & 0xfffffffffff else ""))
        return pre + f"type {t:#x} msg0={m0:#018x}"
    if ep == 2:  # syslog: TYPE 59:52
        t = (m0 >> 52) & 0xff
        if t == 8:
            return pre + f"INIT entries={m0 & 0xffff} entry_size={(m0 >> 24) & 0xffff}"
        if t == 1:
            return (pre + f"BUFFER_REQUEST size={((m0 >> 44) & 0xff) << 12:#x} "
                    f"addr={m0 & 0xfffffffffff:#x}" +
                    (" (AP reply)" if direction == "A2I" else ""))
        if t == 5:
            return pre + f"LOG index={m0 & 0xff}" + (" (AP ack)" if direction == "A2I" else "")
        return pre + f"type {t:#x} msg0={m0:#018x}"
    if ep == 3:  # kdebug: TYPE 55:48 DATA 47:0
        t = (m0 >> 48) & 0xff
        return pre + f"KDEBUG type={t:#x}({KDEBUG.get(t, '?')}) data={m0 & 0xffffffffffff:#x}"
    if ep == 4:  # ioreport: TYPE 63:52
        t = (m0 >> 52) & 0xfff
        if t == 1:
            return (pre + f"BUFFER_REQUEST size={((m0 >> 44) & 0xff) << 12:#x} "
                    f"dva={m0 & 0xfffffffffff:#x}")
        return pre + {8: "REPORT", 0xc: "START"}.get(t, f"type {t:#x}")
    if ep == 8:  # oslog (Linux): TYPE 63:56 SIZE 55:36 IOVA 35:0 (<<12)
        t = (m0 >> 56) & 0xff
        if t == 1:
            return (pre + f"BUFFER_REQUEST size={(m0 >> 36) & 0xfffff:#x} "
                    f"iova={(m0 & 0xfffffffff) << 12:#x}")
        return pre + f"type {t:#x} msg0={m0:#018x} (not decoded by m1n1/Linux)"
    if ep == 0x20 and state.get("smc"):
        return pre + smc_decode(direction, m0, state)
    if ep == 0x20 and state.get("pmp"):
        return pre + pmp_decode(direction, m0, state)
    if ep == 7 and state.get("pmp"):
        # unidentified endpoint started by the PMP EPMAP; crashlog-like layout
        # (TYPE 63:52, SIZE 51:44 in pages, DVA 43:0) but the AP reply has TYPE 5
        t = (m0 >> 52) & 0xfff
        return (pre + f"BUFFER-REQUEST-like type={t:#x} size={((m0 >> 44) & 0xff) << 12:#x} "
                f"addr={m0 & 0xfffffffffff:#x} (role of ep 0x7 unidentified)")
    if ep == 0x37:  # m1n1 fw/dcp/dcpep.py
        t = m0 & 0xf
        if t == 0:
            return pre + f"SET_SHMEM dva={(m0 >> 16):#x}"
        if t == 1:
            return pre + "INIT_COMPLETE"
        if t == 2:
            return pre + (f"CALL ctx={(m0 >> 8) & 0xf} ack={(m0 >> 6) & 1} "
                          f"off={(m0 >> 16) & 0xffff:#x} len={m0 >> 32:#x}")
    return pre + f"msg0={m0:#018x}"


def smc_decode(direction, m0, state):
    if direction == "A2I":
        ty = m0 & 0xff
        mid = (m0 >> 12) & 0xf
        size = (m0 >> 16) & 0xff
        wsize = (m0 >> 24) & 0xff
        key = (m0 >> 32) & 0xffffffff
        cn = SMC_CMDS.get(ty, "?")
        if ty == 0x17:
            return f"id={mid} INITIALIZE"
        if ty in (0x13, 0x10, 0x11, 0x20):
            return (f"id={mid} {cn} key={key4(key)}" +
                    (f" size={size}" if ty in (0x10, 0x11) else "") +
                    (f" rsize={size} wsize={wsize}" if ty == 0x20 else ""))
        if ty == 0x12:
            return f"id={mid} {cn} index={key:#x}"
        return f"id={mid} cmd={ty:#x}({cn})"
    # I2A
    if not state.get("smc_init_done"):
        state["smc_init_done"] = True
        return f"INITIALIZE reply: shmem/SRAM address {m0:#x}"
    res = m0 & 0xff
    mid = (m0 >> 12) & 0xf
    size = (m0 >> 16) & 0xff
    val = (m0 >> 32) & 0xffffffff
    kv = key4(val) if size == 4 and all(32 <= ((val >> (8 * i)) & 0xff) < 127 for i in range(4)) else ""
    return (f"id={mid} result={res:#x}{'(ok)' if res == 0 else '(error)'} size={size} "
            f"value={val:#x}" + (f" ('{kv}')" if kv else ""))


# PMP application endpoint 0x20, layouts from m1n1 proxyclient/experiments/pmp_init.py
# (PMPMessage TYPE = 55:48; IOVA = 47:0).  PMP initiates every request; the AP only replies.
PMP_TYPES = {0x10: "GET_IOVA_TABLE", 0x11: "IOVA_TABLE_ACK", 0x12: "MALLOC", 0x13: "MALLOC_ACK",
             0x14: "FREE", 0x15: "FREE_ACK", 0x30: "SET_BUF", 0x31: "SET_BUF_ACK",
             0x32: "ADVERTISE", 0x33: "ADVERTISE_ACK", 0x34: "SET_VAL", 0x35: "SET_VAL_ACK"}


def pmp_decode(direction, m0, state):
    t = (m0 >> 48) & 0xff
    hi = m0 >> 56
    low = m0 & 0xffffffffffff
    nm = PMP_TYPES.get(t, f"type{t:#x}")
    extra = ""
    if t == 0x11:
        extra = f" table_iova={low:#x}" + (" (none)" if low == 0 else "")
    elif t == 0x12:
        extra = f" size={m0 & 0xffffff:#x}"
    elif t == 0x13:
        extra = f" iova={low:#x}"
    elif t in (0x14, 0x30, 0x32):
        extra = f" iova={low:#x}"
    elif t == 0x33:
        extra = f" index={(m0 >> 32) & 0xffff:#x} size={m0 & 0xffffffff:#x}"
    elif t == 0x34:
        extra = f" index={m0 & 0xffff:#x}"
    elif t == 0x35:
        extra = f" size={m0 & 0xffffffff:#x}"
    if hi:
        extra += f" (bits 63:56={hi:#x})"
    return f"PMP {nm}{extra}"


# ------------------------------------------------------------------ driver
def parse(path, only=None):
    devs = OrderedDict()
    stat_prev = {}
    with open(path, errors="replace") as fh:
        for ln, line in enumerate(fh, 1):
            m = LINE.match(line)
            if not m:
                continue
            cpu, pc, rw, w, addr, dev, off, val = m.groups()
            if only and dev != only:
                continue
            off = int(off, 16)
            val = int(val, 16)
            pc = int(pc, 16)
            d = devs.setdefault(dev, dict(msgs=[], polls=[], cur_a2i=None, cur_i2a=None,
                                          cnt_polls=0, ctrl_last={}, stat={}))
            if off in (0x110, 0x114):
                d["cnt_polls"] += 1
                key = "A2I" if off == 0x110 else "I2A"
                d["polls"].append((ln, pc, rw, key, val))
                continue
            if rw == "W" and off == 0x800:
                d["cur_a2i"] = (ln, pc, val)
            elif rw == "W" and off == 0x808 and d["cur_a2i"]:
                l0, pc0, v0 = d["cur_a2i"]
                d["msgs"].append(dict(dir="A2I", line=l0, pc=pc0, m0=v0, m1=val))
                d["cur_a2i"] = None
            elif rw == "R" and off == 0x830:
                d["cur_i2a"] = (ln, pc, val)
            elif rw == "R" and off == 0x838 and d["cur_i2a"]:
                l0, pc0, v0 = d["cur_i2a"]
                d["msgs"].append(dict(dir="I2A", line=l0, pc=pc0, m0=v0, m1=val))
                d["cur_i2a"] = None
            else:
                d.setdefault("other", []).append((ln, pc, rw, off, val))
    return devs


def run_poll_summary(d):
    """Collapse consecutive identical poll reads into runs."""
    out = []
    for (ln, pc, rw, key, val) in d["polls"]:
        if out and out[-1]["key"] == key and out[-1]["val"] == val and out[-1]["pc"] == pc \
                and out[-1]["rw"] == rw:
            out[-1]["n"] += 1
            out[-1]["last"] = ln
        else:
            out.append(dict(first=ln, last=ln, pc=pc, rw=rw, key=key, val=val, n=1))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--dev", choices=["sep", "dcp", "smc", "pmp"])
    ap.add_argument("--polls", action="store_true", help="also print poll runs")
    a = ap.parse_args()

    devs = parse(a.log, a.dev)
    for dev, d in devs.items():
        print("=" * 100)
        n_a = sum(1 for m in d["msgs"] if m["dir"] == "A2I")
        n_i = sum(1 for m in d["msgs"] if m["dir"] == "I2A")
        print(f"{dev}.mbox: {len(d['msgs'])} messages ({n_a} A2I, {n_i} I2A), "
              f"{d['cnt_polls']} status polls (+0x110/+0x114)")
        if d.get("other"):
            print(f"  other accesses: {len(d['other'])} (first {d['other'][:3]})")
        state = dict(eps={}, pending=[], epmap=[], smc=(dev == "smc"), pmp=(dev == "pmp"))
        dec = sep_decode if dev == "sep" else rtkit_decode
        names = []
        for i, m in enumerate(d["msgs"]):
            txt = dec(m["dir"], m["m0"], m["m1"], state)
            print(f"{i:4d} L{m['line']:<6d} pc={m['pc']:#018x} {m['dir']} "
                  f"msg0={m['m0']:#018x} info={m['m1']:#018x}  {txt}")
        if dev == "sep":
            print("\nSEP endpoint table (index -> name, in advertised order):")
            for idx, nm in state["eps"].items():
                print(f"  {idx:#04x} ({idx:3d})  {nm}")
        elif state["epmap"]:
            print("\nRTKit endpoint map from I2A EPMAP:", [hex(e) for e in state["epmap"]])
        if a.polls:
            print("\npoll runs (+0x110 A2I / +0x114 I2A):")
            for r in run_poll_summary(d):
                print(f"  L{r['first']}-L{r['last']} x{r['n']} pc={r['pc']:#018x} {r['key']} "
                      f"{r['val']:#x} [{ctrl_str(r['val'])}]")
        # summary of last poll values
        if d["polls"]:
            lp = d["polls"][-1]
            print(f"\nlast status poll: L{lp[0]} pc={lp[1]:#x} {lp[3]} {lp[4]:#x} [{ctrl_str(lp[4])}]")
        if d["msgs"]:
            lm = d["msgs"][-1]
            print(f"last message: L{lm['line']} {lm['dir']} msg0={lm['m0']:#x}")


if __name__ == "__main__":
    main()
