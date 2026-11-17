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
  aci-probe.py ifstatus | ifconfig    AciGetInterfaceStatus / AciGetInterfaceConfiguration on 1
  aci-probe.py stop                   AciStopInterface on interface 1
  aci-probe.py events                 the last 32 firmware events (aci_events)
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
EVENTS = f"/sys/kernel/debug/ieee80211/{PHY}/aci_events"
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
    elif op == "send":
        if len(args) < 2:
            die("send IF CMD [HEX]")
        show(*aci(int(args[0], 0), int(args[1], 0),
                  bytes.fromhex(args[2]) if len(args) > 2 else b""))
    else:
        die(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
