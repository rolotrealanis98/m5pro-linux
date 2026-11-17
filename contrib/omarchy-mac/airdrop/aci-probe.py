#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Probe the N1 firmware's AWDL and NAN interfaces through centauri's debugfs "aci".

Needs a kernel with "wifi: apple: centauri: t6050: ACI probe for the AWDL and NAN
interfaces" (branch j716s-airdrop-aci) and root. Nothing here touches wlan0: the
kernel refuses every command on interface 0 except read-only queries.

  aci-probe.py caps                   any centauri kernel: decode debugfs system_caps (read-only)
  aci-probe.py status                 kernel support, aci_debug, debugfs files
  aci-probe.py enable | disable       switch the probe (aci_debug) at run time
  aci-probe.py version                AciGetVersion on interface 0 (read-only)
  aci-probe.py defaults awdl|nan      AciGetSystemCaps on interface 1 or 2: the firmware's
                                      default AWDL/NAN TLVs (what macOS reads first; read-only)
  aci-probe.py configure MAC          AciConfigureInterface on interface 1 (AWDL) with MAC
  aci-probe.py start                  AciStartInterface on interface 1 with the firmware's own
                                      defaults echoed back (macOS's layout: 5-byte prefix + TLVs)
  aci-probe.py start --full [--seq none|default|149|6+149] [--mac MAC]
                       [--ff04 fw|fwraw|air|none] [--skip TAG,TAG] [--ext]
                       [--caps FILE] [--dry-run] [--force]
                                      the blocks macOS's startAwdlInterface sends, in its order:
                                      fe08/ff05/fe00/fe01 from the defaults, fe02/fe03 (the
                                      defaults' extra PSF/MIF TLVs, empty when the firmware gives
                                      none, as on macOS), ff04, then ff12 only with a --seq.
                                      "--seq none" (default) sends no ff12, as macOS on a fresh
                                      start; the others add ff12 in encoding 3 (channel, op class).
                                      ff04: "fw" (default) is the firmware's own ff04 value, 71
                                      bytes from the reply, exactly what macOS copies; "fwraw" is
                                      the same value without the trailing bytes; "air" is OWL's
                                      values (the firmware refuses it: flag 0x800, encoding 3);
                                      "none" leaves it out. --ext adds an 11-byte ff20 of zeros
                                      (the firmware then ignores ff12). --skip leaves out tags.
                                      Before sending, the payload is checked against the
                                      firmware's TLV rules (fw_check); a payload the firmware
                                      would refuse with status 347 is not sent unless --force.
                                      --caps FILE builds from a saved GetSystemCaps reply (e.g.
                                      debugfs system_caps) instead of asking the firmware;
                                      --dry-run prints the payload and the check, sends nothing.
  aci-probe.py ifstatus | ifconfig    AciGetInterfaceStatus / AciGetInterfaceConfiguration on 1
  aci-probe.py stop                   AciStopInterface on interface 1
  aci-probe.py events                 the last 32 firmware events (aci_events)
  aci-probe.py frames                 management-ring packets for interfaces 1/2 (M1c kernel)
  aci-probe.py halt                   check the alpha stage now (captures a halt) and print halt_info
  aci-probe.py save DIR               copy halt_info, halt_crashlog, halt_scratch, aci_events and
                                      aci_frames to DIR (M1c kernel)
  aci-probe.py send IF CMD [HEX]      any allowed command, e.g. send 1 0x50002

Command ids are (group << 16) | opcode, from the name table in macOS 27.3's
WLANACIAdapter (see /Volumes/m5pro/bench/requests/airdrop-1.md). A command that times
out makes the driver fault the whole Wi-Fi function (wlan0 goes down until a reboot or
rebind), so run the write commands only with another way into the machine.
"""
import os
import struct
import sys

PHY = os.environ.get("ACI_PHY", "phy0")
ACI = f"/sys/kernel/debug/ieee80211/{PHY}/aci"
DBG = f"/sys/kernel/debug/ieee80211/{PHY}"
EVENTS = f"{DBG}/aci_events"
PARAM = "/sys/module/apple_centauri_t6050/parameters/aci_debug"

IF_STATION, IF_AWDL, IF_NAN = 0, 1, 2
CMD = {
    "GetVersion": 0x00000, "ConfigureInterface": 0x00001, "StartInterface": 0x00002,
    "StopInterface": 0x00003, "GetSystemCaps": 0x00008, "SetInterfaceConfiguration": 0x0000C,
    "GetInterfaceConfiguration": 0x0000D, "GetInterfaceStatus": 0x00014,
    "AwdlOpenLink": 0x50000, "AwdlCloseLink": 0x50001, "AwdlGetAssociatedLinks": 0x50002,
    "AwdlSendUnicastMif": 0x50003, "AwdlRangingControl": 0x50004,
}
# AciPackedDataAwdl* tags (mapAwdlTlvTypeToString). 0xff00 | n carries AWDL
# over-the-air TLV type n in its air format; 0xfe0n are host-API-only.
TLV = {
    0xFE00: "AdditionalElectionParameters", 0xFE01: "MifAndSyncParameters",
    0xFE02: "AdditionalTLVsToTransmitInPsf", 0xFE03: "AdditionalTLVsToTransmitInMif",
    0xFE04: "SetPeerParameters", 0xFE05: "GetPeerParametersInfoUnknown",
    0xFE06: "GetPeerParametersInfoKnown", 0xFE07: "GetPeerParametersNoPeers",
    0xFE08: "GeneralConfigParameters", 0xFE09: "GetDeviceCapabilities",
    0xFE0A: "PsfDwellTime", 0xFE0B: "SocialSlotConfig", 0xFE0C: "ChannelSpec",
    0xFE0D: "AdditionalTLVsToTransmitInUnicastMif",
    0xFF00: "SsthRequest", 0xFF01: "ServiceRequest", 0xFF02: "ServiceResponse",
    0xFF03: "NullResponse", 0xFF04: "SyncParameters (air TLV 4)",
    0xFF05: "ElectionParameters (air TLV 5)", 0xFF06: "ServiceParameters (air TLV 6)",
    0xFF07: "EnhancedDataRateCapabilities (air TLV 7)",
    0xFF08: "EnhancedDataRateOperation (air TLV 8)", 0xFF0C: "DataPathState (air TLV 12)",
    0xFF11: "80211IeContainer (air TLV 17)", 0xFF12: "ChannelSequence (air TLV 18)",
    0xFF13: "SocChansList", 0xFF17: "NanSync", 0xFF19: "BroadcastCsa", 0xFF1A: "UnicastCsa",
    0xFF20: "ExtendedChannelSequence",
}
# What macOS's startAwdlInterface sends, in this order, after the prefix, with
# the lengths it uses. The firmware's replies pad every TLV to 4 bytes (19 -> 20,
# 43 -> 44, 38 -> 40), so echoed defaults are cut back to these. None = variable
# (the PSF/MIF extra TLVs). macOS builds SyncParameters (71 bytes; the firmware
# default is 56) and ExtendedChannelSequence from host state: "start" leaves them
# out unless --with-sync is given.
START_TLVS = [(0xFE08, 3), (0xFF05, 19), (0xFE00, 43), (0xFE01, 20), (0xFE02, None),
              (0xFE03, None), (0xFF04, 71), (0xFF12, 38), (0xFF20, 11)]
HOST_BUILT = {0xFF04, 0xFF20}
START_PREFIX = bytes([0x02, 0x06, 0x00, 0x00, 0x00])  # station: 00 0b 00 00 00
STOP_PAYLOAD = bytes(5)


# AWDL channel encoding 3: (channel, operating class), OWL's values.
CH6, CH44, CH149, IDLE = (6, 0x51), (44, 0x80), (149, 0x80), (0, 0)
SEQUENCES = {
    "149": [CH149] * 16,
    "6+149": ([CH6] * 4 + [CH149] * 4) * 2,
}


def chanseq(slots):
    """AWDL channel sequence in air format: 38 bytes for 16 two-byte slots."""
    out = bytearray([len(slots) - 1, 3, 0, 3]) + struct.pack("<H", 0xFFFF)
    for ch, opclass in slots:
        out += bytes([ch, opclass])
    return bytes(out)


def sync_params(mac, seq, slots):
    """AWDL sync parameters TLV body in air format (OWL awdl_sync_params_tlv): 33 + 38 bytes.

    The firmware refuses this form (see fw_check): flags 0x1800 has bit 0x800, and its sequence
    is in encoding 3. Kept to reproduce the 10:50 runs."""
    used = [ch for ch, _ in slots if ch]
    master = 6 if 6 in used else (used[0] if used else 6)
    head = struct.pack("<BHBBHHHHHHBBBB6sBBHH",
                       used[0] if used else 6,  # next AW channel
                       0,                       # TX down counter
                       master,                  # master channel
                       0,                       # guard time
                       16, 110,                 # AW period, AF (PSF) period, TU
                       0x1800,                  # flags (OWL's value)
                       16, 16, 0,               # ext / common / remaining AW length
                       3, 3, 3, 3,              # min ext, max ext mcast/ucast/af
                       mac, 4, 0,               # master address = ours, presence mode 4
                       0, 0)                    # next AW seq, AP alignment
    assert len(head) == 33
    return head + seq


# The N1 firmware's rules for the AWDL TLVs of AciStartInterface and AciSetInterfaceConfiguration,
# read from the UMAC code in the ftab's "aciw" entry (UMAC addresses; airdrop-6.md has the table).
# The start handler (in NETIF_AWDL_HandleEvent) passes everything after the 24-byte header and the
# 5-byte prefix to the TLV parser at 0x530f80 (awdl_cb.c AwdlTlvsSet); when that returns false the
# command fails with 347, AciWifiTlvsParsingFailed. TLVs are packed back to back, no padding.
FW_LEN = {0xFE00: (43, 44), 0xFE01: (20, 20), 0xFE02: (0, 0x180), 0xFE03: (0, 0x500),
          0xFE08: (3, 4), 0xFE0B: (2, 4), 0xFF04: (39, 0xFFFF), 0xFF05: (19, 20)}
FW_TAGS = set(FW_LEN) | {0xFE0A, 0xFF12, 0xFF13, 0xFF20, 0x0106, 0x0185, 0xF709}


def ff04_problems(v):
    """Why the firmware's ff04 handler (0x5316cc, with 0x5307a0) would refuse this value."""
    u16 = lambda o: struct.unpack_from("<H", v, o)[0]  # noqa: E731
    if len(v) < 39:
        return [f"length {len(v)}, at least 39"]
    p, enc = [], v[34]
    if not 1 <= v[3] <= 184:
        p.append(f"master channel {v[3]}")
    if u16(9) & 0x0A00:
        p.append(f"flags {u16(9):#06x} have bit 0x0800 or 0x0200")
    for name, got, want in (("AW period", u16(5), 16), ("extension length", u16(11), 16),
                            ("common AW length", u16(13), 16), ("max unicast extensions", v[19], 3),
                            ("presence mode", v[27], 4), ("sequence count", v[33], 15),
                            ("duplicate count", v[35], 0), ("step count", v[36], 3),
                            ("fill channel", u16(37), 0xFFFF)):
        if got != want:
            p.append(f"{name} {got:#x}, must be {want:#x}")
    if enc > 1:
        p.append(f"channel sequence encoding {enc}: ff04 takes only 0 (channel) or 1 (legacy "
                 "2-byte); encoding 3 belongs in ff12")
    elif len(v) < 39 + 16 * (enc + 1):
        p.append(f"length {len(v)} too short for 16 slots in encoding {enc}")
    else:
        for i in range(16):
            ch = v[39 + i] if enc == 0 else v[39 + 2 * i + 1]
            if ch > 184:
                p.append(f"slot {i}: channel {ch}")
    return p


def fw_check(area):
    """Problems the firmware's TLV parser finds in a start TLV area (the bytes after the prefix).
    Lines starting "note:" do not fail the command."""
    out, pos, seen = [], 0, {}
    while pos + 4 <= len(area):
        tag, n = struct.unpack_from("<HH", area, pos)
        v = area[pos + 4:pos + 4 + n]
        pos += 4 + n
        if len(v) < n:
            out.append(f"{tag:#06x}: length {n} runs past the end")
            break
        seen[tag] = v
        if tag not in FW_TAGS:
            out.append(f"{tag:#06x}: a tag the parser does not take")
        elif tag in FW_LEN and not FW_LEN[tag][0] <= n <= FW_LEN[tag][1]:
            out.append(f"{tag:#06x}: length {n}, the parser takes {FW_LEN[tag][0]}..{FW_LEN[tag][1]}")
        elif tag == 0xFE01:
            u16 = struct.unpack_from("<HH", v, 12)
            if v[0] > 1 or v[1] > 1 or max(u16) > 0x400 or v[16:20] == bytes(4):
                out.append("0xfe01: bytes 0/1 must be 0 or 1, the u16s at 12/14 at most 0x400, "
                           "the u32 at 16 non-zero")
        elif tag == 0xFE0B:
            w = struct.unpack_from("<H", v)[0]
            if not w or bin(w).count("1") >= 6:
                out.append(f"0xfe0b: slot mask {w:#06x} (non-zero, fewer than 6 bits)")
        elif tag == 0xFF04:
            out += [f"0xff04: {p}" for p in ff04_problems(v)]
    if pos < len(area) and pos + 4 > len(area):
        out.append(f"note: {len(area) - pos} trailing bytes ignored")
    s = seen.get(0xFF12)
    if s is not None:
        if len(s) < 38 or s[1] != 3:
            out.append("note: ff12 is not 38 bytes in encoding 3; the firmware ignores it")
        elif 0xFF20 in seen and (len(seen[0xFF20]) < 9 or
                                 (struct.unpack_from("<H", seen[0xFF20], 6)[0] & 0x804) != 0x804 or
                                 seen[0xFF20][8] != 2):
            out.append("note: ff20 lacks bits 0x804 at 6 or 2 at 8; the firmware ignores ff12")
        elif s[0] > 15 or not any(s[6 + 2 * i] for i in range(s[0] + 1)):
            out.append("0xff12: more than 16 slots, or no slot with a channel")
    return out


def value_at(reply, tag):
    """Offset of a TLV's value in a reply, or None."""
    pos = 0
    while pos + 4 <= len(reply):
        t, n = struct.unpack_from("<HH", reply, pos)
        if t == tag:
            return pos + 4
        pos += 4 + n
    return None


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def aci(ifidx, cmd, payload=b""):
    req = struct.pack("<BBHI", ifidx, 0, 0, cmd) + payload
    try:
        fd = os.open(ACI, os.O_RDWR)
    except OSError as e:
        die(f"{ACI}: {e} (kernel without the probe, or not root)")
    try:
        os.write(fd, req)
        os.lseek(fd, 0, os.SEEK_SET)
        res = os.read(fd, 8 + 4096)
    except OSError as e:
        die(f"command {cmd:#x} on interface {ifidx}: {e.strerror}"
            + (" (aci_debug off, or a command the kernel refuses)" if e.errno == 1 else ""))
    finally:
        os.close(fd)
    ret, status, size = struct.unpack_from("<iHH", res)
    return ret, status, res[8:8 + size]


def tlvs(buf, start=0):
    pos, out = start, []
    while pos + 4 <= len(buf):
        tag, length = struct.unpack_from("<HH", buf, pos)
        if pos + 4 + length > len(buf):
            break
        out.append((tag, buf[pos + 4:pos + 4 + length]))
        pos += 4 + length
    return out, pos


def show(ret, status, reply, decode=True):
    print(f"result {ret} firmware status {status} reply {len(reply)} bytes")
    if not reply:
        return
    found, end = tlvs(reply)
    if decode and found and end == len(reply):
        for tag, val in found:
            print(f"  {tag:#06x} {TLV.get(tag, '?'):40s} {len(val):4d}  {val[:40].hex()}"
                  + ("..." if len(val) > 40 else ""))
    else:
        for i in range(0, len(reply), 32):
            print(f"  {i:04x}: {reply[i:i + 32].hex()}")


def defaults(ifidx):
    ret, status, reply = aci(ifidx, CMD["GetSystemCaps"])
    return ret, status, reply


def main(argv):
    if not argv:
        die(__doc__)
    op, args = argv[0], argv[1:]
    if op == "status":
        print("aci_debug:", open(PARAM).read().strip() if os.path.exists(PARAM)
              else "missing (kernel without the probe)")
        for p in (ACI, EVENTS):
            print(p, "present" if os.path.exists(p) else "missing")
    elif op in ("enable", "disable"):
        with open(PARAM, "w") as f:
            f.write("1" if op == "enable" else "0")
    elif op == "caps":
        # Any centauri kernel: the station's AciGetSystemCaps reply, kept in
        # debugfs at bring-up. It already holds the firmware's AWDL defaults.
        with open(f"/sys/kernel/debug/ieee80211/{PHY}/system_caps", "rb") as f:
            show(0, 0, f.read())
    elif op == "version":
        show(*aci(IF_STATION, CMD["GetVersion"]), decode=False)
    elif op == "defaults":
        which = {"awdl": IF_AWDL, "nan": IF_NAN}.get(args[0] if args else "awdl")
        if which is None:
            die("defaults awdl|nan")
        show(*defaults(which))
    elif op == "configure":
        if not args:
            die("configure MAC (a locally administered address, e.g. 02:..)")
        mac = bytes.fromhex(args[0].replace(":", ""))
        if len(mac) != 6 or not mac[0] & 2:
            die("use a locally administered MAC (second-lowest bit of the first byte set)")
        show(*aci(IF_AWDL, CMD["ConfigureInterface"], mac))
    elif op == "start" and "--full" in args:
        def opt(name, default):
            return args[args.index(name) + 1] if name in args else default
        mac = bytes.fromhex(opt("--mac", "02:00:00:00:00:01").replace(":", ""))
        if "--caps" in args:
            with open(opt("--caps", ""), "rb") as f:
                reply = f.read()
        else:
            ret, status, reply = defaults(IF_AWDL)
            if ret:
                die(f"cannot read the defaults first: {ret} status {status}")
        have = dict(tlvs(reply)[0])
        mode = opt("--seq", "none")
        fwseq = have[0xFF12][:38]
        if mode == "none":     # macOS on a fresh start: its sequence state is still empty, no ff12
            seq, slots = None, []
        elif mode == "default":
            seq = fwseq
            slots = [(seq[6 + 2 * i], seq[7 + 2 * i]) for i in range(16)]
        elif mode in SEQUENCES:
            slots = SEQUENCES[mode]
            seq = chanseq(slots)
        else:
            die("--seq none|default|149|6+149")
        ff04 = opt("--ff04", "fw")
        if ff04 == "fw":
            # getAwdlDefaultValuesFromDevice copies 0x47 bytes from the firmware's ff04 value
            # (whatever follows it in the reply included) and startAwdlInterface sends them back.
            at = value_at(reply, 0xFF04)
            sync = reply[at:at + 71].ljust(71, b"\0")
        elif ff04 == "fwraw":
            sync = have[0xFF04][:55]   # the firmware's own ff04 as it reports it (encoding-0 sequence)
        elif ff04 == "air":
            sync = sync_params(mac, seq or fwseq, slots or
                               [(fwseq[6 + 2 * i], fwseq[7 + 2 * i]) for i in range(16)])
        elif ff04 == "none":
            sync = None
        else:
            die("--ff04 fw|fwraw|air|none")
        skip = {int(t, 16) for t in opt("--skip", "").split(",") if t}
        blocks = [(0xFE08, have[0xFE08][:3]), (0xFF05, have[0xFF05][:19]),
                  (0xFE00, have[0xFE00][:43]), (0xFE01, have[0xFE01][:20]),
                  (0xFE02, have.get(0xFE02, b"")), (0xFE03, have.get(0xFE03, b""))]
        if sync is not None:
            blocks.append((0xFF04, sync))
        if seq is not None:
            blocks.append((0xFF12, seq))
        if "--ext" in args:
            blocks.append((0xFF20, bytes(11)))
        blocks = [(t, v) for t, v in blocks if t not in skip]
        payload = bytearray(START_PREFIX)
        for tag, val in blocks:
            payload += struct.pack("<HH", tag, len(val)) + val
        print("start --full: " + ", ".join(f"{t:#06x}/{len(v)}" for t, v in blocks)
              + f"; ff04 {ff04}; sequence {mode}"
              + (": " + " ".join(str(c) for c, _ in slots) if slots else ""))
        problems = fw_check(bytes(payload[len(START_PREFIX):]))
        refused = [p for p in problems if not p.startswith("note:")]
        for p in problems:
            print(f"fw_check: {p}")
        print("fw_check: " + ("the firmware would refuse this with status 347" if refused
                              else "the firmware's TLV parser takes this"))
        if "--dry-run" in args:
            for i in range(0, len(payload), 32):
                print(f"  {i:04x}: {payload[i:i + 32].hex()}")
            return
        if refused and "--force" not in args:
            die("not sent: fw_check predicts status 347 (--force sends it anyway)")
        show(*aci(IF_AWDL, CMD["StartInterface"], bytes(payload)))
    elif op == "start":
        ret, status, reply = defaults(IF_AWDL)
        if ret:
            die(f"cannot read the defaults first: {ret} status {status}")
        have = dict(tlvs(reply)[0])
        payload = bytearray(START_PREFIX)
        for tag, length in START_TLVS:
            if tag in HOST_BUILT and "--with-sync" not in args:
                continue
            if tag not in have:
                print(f"note: firmware default has no {tag:#06x} {TLV.get(tag)}; not sent")
                continue
            val = have[tag] if length is None else have[tag][:length]
            if length is not None and len(val) < length:
                print(f"note: {tag:#06x} default is {len(val)} bytes, macOS sends {length}; sent as is")
            payload += struct.pack("<HH", tag, len(val)) + val
        show(*aci(IF_AWDL, CMD["StartInterface"], bytes(payload)))
    elif op == "stop":
        show(*aci(IF_AWDL, CMD["StopInterface"], STOP_PAYLOAD))
    elif op == "ifstatus":
        show(*aci(IF_AWDL, CMD["GetInterfaceStatus"]))
    elif op == "ifconfig":
        show(*aci(IF_AWDL, CMD["GetInterfaceConfiguration"]))
    elif op == "events":
        print(open(EVENTS).read(), end="")
    elif op == "frames":
        print(open(f"{DBG}/aci_frames").read(), end="")
    elif op == "halt":
        print(open(f"{DBG}/halt_check").read(), end="")
        print(open(f"{DBG}/halt_info").read(), end="")
    elif op == "save":
        if not args:
            die("save DIR")
        os.makedirs(args[0], exist_ok=True)
        for name in ("halt_info", "halt_crashlog", "halt_scratch", "aci_events", "aci_frames"):
            try:
                data = open(f"{DBG}/{name}", "rb").read()
            except OSError as e:
                print(f"{name}: {e.strerror}")
                continue
            with open(os.path.join(args[0], name), "wb") as f:
                f.write(data)
            print(f"{name}: {len(data)} bytes")
    elif op == "send":
        if len(args) < 2:
            die("send IF CMD [HEX]")
        show(*aci(int(args[0], 0), int(args[1], 0),
                  bytes.fromhex(args[2]) if len(args) > 2 else b""))
    else:
        die(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
