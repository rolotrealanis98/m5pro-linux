#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build or inspect an m1n1 boot object with appended variables, M5 Pro (T6050) rules.

  mk-stage1.py stage1  --m1n1 m1n1-chain.bin --esp-partuuid UUID [--path m1n1/boot.bin] -o stage1.bin
  mk-stage1.py esp     --m1n1 m1n1-chain.bin --esp-partuuid UUID --path m1n1/slot-a.bin -o m1n1/boot.bin
  mk-stage1.py inspect FILE

Modes
  stage1  The object iBoot loads (kmutil configure-boot --raw). Layout:
              m1n1 | "key=value\\n"... | 00 00 00 00 | zero pad to a 64 KiB multiple
          The terminator is needed because nothing follows the file in memory
          (asahi-installer src/m1n1.py:5 writes the same "\\0\\0\\0\\0"); m1n1's payload
          scan stops on it (m1n1 src/payload.c, load_one_payload: `empty`).
          The 64 KiB padding follows GravityLinux/installer 517c72a (pads "the complete
          boot object, including variables"); on M4+ a non-16 KiB-multiple object was
          seen rejected (m5pro-linux docs/boot-and-recovery.md:163-169).
          Size: the last image that booted as stage-1 on this J716s with a CHAINLOADING
          build is 0x430000 (padded, chain-esp-small.bin); a plain 0x4D0000 image also
          boots; 0x4E0000..0x4F0000 loop (same doc, lines 129-181). This tool refuses
          anything above 0x4D0000 and warns above 0x430000. Neither number is a
          documented limit; they are the measured envelope.
  esp     A CHAINLOADING m1n1 read from the ESP by another m1n1 (a "stage-1.5").
          No terminator and no padding: the loading m1n1 appends its own chosen.*
          variables and the terminator after the file (m1n1 src/chainload.c:87-98).
          A terminator inside the file would hide those variables from the next stage.
  inspect Print size, alignment, build type and the variables after the m1n1 image
          (the image ends with the 8-byte "STACKBOT" marker; asahi-installer
          src/m1n1.py:18 uses the same marker to read variables back).

Variable rules enforced (m1n1 src/payload.c check_var): name <= 64 bytes before '=',
value <= 1024 bytes, no newline inside, <= 16 chosen.* variables in total (including the
one a CHAINLOADING build adds itself), and only names m1n1 knows (chosen.*, chainload=,
display=, mitigations=, tso=). The last chainload= wins in m1n1, so only one is allowed.
"""
import argparse
import re
import sys
import uuid

KIB = 1024
STAGE1_ALIGN = 64 * KIB
STAGE1_HARD_MAX = 0x4D0000      # largest stage-1 measured to boot (plain build)
STAGE1_TESTED_CHAIN = 0x430000  # largest CHAINLOADING stage-1 measured to boot
MAX_VAR_NAME = 64
MAX_VAR_SIZE = 1024
MAX_CHOSEN_VARS = 16
KNOWN_PREFIXES = ("chosen.", "chainload=", "display=", "mitigations=", "tso=")
STACKBOT = b"STACKBOT"
CHAIN_MARK = b"chosen.asahi,m1n1-stage1-version="       # only in CHAINLOADING builds
PLAIN_MARK = b"Chainloading files not supported"         # only in CHAINLOADING=0 builds


def die(msg):
    sys.exit(f"mk-stage1: ERROR: {msg}")


def build_type(img):
    chain, plain = CHAIN_MARK in img, PLAIN_MARK in img
    if chain and not plain:
        return "chainloading"
    if plain and not chain:
        return "plain"
    return "unknown"


def m1n1_end(img):
    i = img.find(STACKBOT)
    if i < 0:
        return None
    return i + len(STACKBOT)


def check_vars(vars_, chainloading):
    chosen = 1 if chainloading else 0
    seen_chainload = False
    for v in vars_:
        if "\n" in v or "\0" in v:
            die(f"variable contains a newline or NUL: {v!r}")
        if "=" not in v:
            die(f"variable has no '=': {v!r}")
        name, val = v.split("=", 1)
        if len(name) > MAX_VAR_NAME:
            die(f"variable name longer than {MAX_VAR_NAME}: {name!r}")
        if len(val) > MAX_VAR_SIZE:
            die(f"value of {name} longer than {MAX_VAR_SIZE} bytes ({len(val)})")
        if not v.startswith(KNOWN_PREFIXES):
            die(f"m1n1 ignores unknown variable {name!r}")
        if v.startswith("chosen."):
            chosen += 1
        if v.startswith("chainload="):
            if seen_chainload:
                die("more than one chainload= (m1n1 keeps only the last)")
            seen_chainload = True
    if chosen > MAX_CHOSEN_VARS:
        die(f"{chosen} chosen.* variables, m1n1 keeps {MAX_CHOSEN_VARS}")


def chainload_var(partuuid, path):
    try:
        u = uuid.UUID(partuuid)
    except ValueError:
        die(f"not a UUID: {partuuid!r}")
    if not path or path.startswith("/") or ";" in path or "\\" in path:
        die(f"path must be relative to the ESP root, '/'-separated, no ';': {path!r}")
    # rust/src/chainload.rs: spec.split(';') -> Uuid::parse_str, then the FAT path
    return f"chainload={str(u).lower()};{path}"


def cmd_build(a, mode):
    img = open(a.m1n1, "rb").read()
    kind = build_type(img)
    end = m1n1_end(img)
    if end is None:
        die(f"{a.m1n1}: no STACKBOT marker, not an m1n1 image")
    if end != len(img):
        die(f"{a.m1n1}: {len(img) - end} bytes after STACKBOT; pass the bare m1n1 image, "
            "not one that already carries variables or payloads")
    if kind != "chainloading" and not a.allow_plain:
        die(f"{a.m1n1} is a {kind} build; a chainload= stage needs CHAINLOADING=1 "
            "(--allow-plain only for a proxy/rescue object without chainload=)")
    vars_ = []
    if a.esp_partuuid:
        chainload_var(a.esp_partuuid, a.path)   # validates the UUID and path first
        if a.efi_var:
            # Lets Linux find its ESP from /proc/device-tree/chosen/asahi,efi-system-partition
            # (asahi-installer src/osinstall.py:188-189 sets the same variable). Stage-1 passes
            # chosen.* on to the next stage (src/payload.c payload_run -> chainload_load).
            vars_.append(f"chosen.asahi,efi-system-partition={str(uuid.UUID(a.esp_partuuid)).lower()}")
        if kind == "chainloading":
            vars_.append(chainload_var(a.esp_partuuid, a.path))
    elif kind == "chainloading":
        die("--esp-partuuid is required for a chainloading build")
    vars_ += a.var or []
    check_vars(vars_, kind == "chainloading")

    blob = img + b"".join(v.encode("ascii") + b"\n" for v in vars_)
    if mode == "stage1":
        blob += b"\0\0\0\0"
        blob += b"\0" * (-len(blob) % STAGE1_ALIGN)
        size = len(blob)
        if size > STAGE1_HARD_MAX and not a.force:
            die(f"stage-1 is 0x{size:x} bytes, above the 0x{STAGE1_HARD_MAX:x} measured to boot on "
                "J716s (rebuild with a smaller MAX_CPUS / no LOGO, or --force)")
        if kind == "chainloading" and size > STAGE1_TESTED_CHAIN:
            print(f"mk-stage1: WARNING: 0x{size:x} > 0x{STAGE1_TESTED_CHAIN:x}, the largest "
                  "CHAINLOADING stage-1 measured to boot", file=sys.stderr)
    with open(a.out, "wb") as f:
        f.write(blob)
    print(f"{a.out}: {mode}, {kind} m1n1 0x{len(img):x} + {len(vars_)} vars -> 0x{len(blob):x} bytes")
    for v in vars_:
        print(f"  {v}")


def cmd_inspect(a):
    blob = open(a.file, "rb").read()
    end = m1n1_end(blob)
    print(f"{a.file}: 0x{len(blob):x} bytes ({len(blob)}), "
          f"64K-aligned={len(blob) % STAGE1_ALIGN == 0} 16K-aligned={len(blob) % (16 * KIB) == 0}")
    print(f"  build: {build_type(blob)}")
    if end is None:
        print("  no STACKBOT marker")
        return 1
    print(f"  m1n1 image ends at 0x{end:x}")
    tail = blob[end:]
    vars_, pos = [], 0
    while pos < len(tail):
        if tail[pos:pos + 4] == b"\0\0\0\0":
            rest = tail[pos + 4:]
            print(f"  terminator at +0x{end + pos:x}; "
                  f"{'zero padding' if not rest.strip(bytes(1)) else 'NON-ZERO data'} after it (0x{len(rest):x})")
            break
        nl = tail.find(b"\n", pos)
        line = tail[pos:nl] if nl >= 0 else b""
        if nl < 0 or b"=" not in line[:MAX_VAR_NAME + 1]:
            print(f"  payload/non-variable data at +0x{end + pos:x}: {tail[pos:pos + 8].hex()}")
            break
        vars_.append(line.decode("ascii", "replace"))
        pos = nl + 1
    else:
        print("  no terminator (fine for an ESP-resident object, wrong for an iBoot stage-1)")
    for v in vars_:
        print(f"  var: {v}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for mode in ("stage1", "esp"):
        p = sub.add_parser(mode)
        p.add_argument("--m1n1", required=True, help="bare m1n1.bin (CHAINLOADING=1 build)")
        p.add_argument("--esp-partuuid", help="GPT unique partition GUID of the ESP "
                       "(macOS: diskutil info -plist diskXsY -> DiskUUID)")
        p.add_argument("--path", default="m1n1/boot.bin", help="file on the ESP to chainload")
        p.add_argument("--no-efi-var", dest="efi_var", action="store_false",
                       help="omit chosen.asahi,efi-system-partition=")
        p.add_argument("--var", action="append", help="extra variable, e.g. display=...")
        p.add_argument("--allow-plain", action="store_true")
        p.add_argument("--force", action="store_true")
        p.add_argument("-o", "--out", required=True)
    p = sub.add_parser("inspect")
    p.add_argument("file")
    a = ap.parse_args()
    if a.cmd == "inspect":
        return cmd_inspect(a)
    return cmd_build(a, a.cmd)


if __name__ == "__main__":
    sys.exit(main())
