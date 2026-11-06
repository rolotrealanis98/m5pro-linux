#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
Read-only, fault-tolerant dump of the PMP coprocessor window (ADT /arm-io/pmp0,
reg[0]) over the m1n1 USB proxy, for joshuaswarren's "does mBoot start the PMP"
question (omacom/linux-aurora #293).

Run it on the tethered J716s (R1 step 3, R1-TEST-PLAN.md):
  1. --stage handoff       stage-1 proxy right after the stub hands off (nothing booted)
  2. --stage m1n1-stage2   after chainloading stage-2 m1n1 (its full init, 18 CPUs started)
  3. --stage after-linux   optional: after a tethered Linux boot and a warm reboot back
                           into the stage-1 proxy
then:  pmp-dump.py --diff OUTDIR/pmp0-handoff.bin OUTDIR/pmp0-m1n1-stage2.bin

What it does (reads only; it never writes a device register):
  * looks up /arm-io/pmp0 reg[0] in the LIVE ADT (expected 0x284e00000 + 0x88000 on J716s,
    same as J716c) and refuses to run if the size is unexpected;
  * reads the two PMGR power-state registers behind the node's clock gates (ADT gate
    ids 27 and 28 -> 0x280600128 and 0x280600130 on J716s; recomputed from the live ADT)
    and records them: if a domain is not on, reads of the block may fault;
  * copies the window in 1 KiB chunks with m1n1's exception guard (SKIP|SILENT): a chunk
    whose copy faulted is re-read word by word (up to --max-word-chunks chunks) so the
    exact faulting words are known. Faulting words are stored as 0xdeadfa17 and listed;
  * writes OUTDIR/pmp0-<stage>.bin, OUTDIR/pmp0-<stage>.json (fault map, PMGR values,
    sha256) and prints a short summary. No ADT identifiers are printed or saved.

If the proxy stops answering during the read, the block hung the bus: that is an answer
too. Note the chunk offset printed last, then hold the power button (no data is lost).

Usage (m5.sh runs it from ~/Work/m1n1/proxyclient with the m1n1 venv and finds the device):
  host/macos/m5.sh py ~/Work/agents/integration/r1/pmp-dump.py --stage handoff
  host/macos/m5.sh py ~/Work/agents/integration/r1/pmp-dump.py --diff A.bin B.bin   # no device needed
"""
import argparse, hashlib, json, os, pathlib, struct, sys, time

CHUNK = 0x400
POISON = 0xDEADFA17
EXPECTED_SIZE = 0x88000
GATES = (27, 28)


def diff(a_path, b_path, limit):
    a = pathlib.Path(a_path).read_bytes()
    b = pathlib.Path(b_path).read_bytes()
    if len(a) != len(b):
        sys.exit(f"size mismatch {len(a):#x} vs {len(b):#x}")
    words = len(a) // 4
    wa = struct.unpack(f"<{words}I", a)
    wb = struct.unpack(f"<{words}I", b)
    changed = [i for i in range(words) if wa[i] != wb[i]]
    print(f"{len(changed)} of {words} words differ")
    for i in changed[:limit]:
        tag = ""
        if wa[i] == POISON or wb[i] == POISON:
            tag = "  (fault marker on one side)"
        print(f"  +{i * 4:#07x}: {wa[i]:#010x} -> {wb[i]:#010x}{tag}")
    if len(changed) > limit:
        print(f"  ... {len(changed) - limit} more (raise --limit)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", help="label: handoff, m1n1-stage2, after-linux, ...")
    ap.add_argument("--out", default=os.path.expanduser("~/Work/m5-logs/r1-pmp"))
    ap.add_argument("--max-word-chunks", type=int, default=8,
                    help="faulted chunks to re-read word by word (each is 256 proxy calls)")
    ap.add_argument("--diff", nargs=2, metavar=("A", "B"))
    ap.add_argument("--limit", type=int, default=200)
    args = ap.parse_args()

    if args.diff:
        return diff(*args.diff, args.limit)
    if not args.stage or not all(c.isalnum() or c == "-" for c in args.stage):
        ap.error("--stage LABEL ([A-Za-z0-9-]) is required unless --diff is given")

    sys.path.insert(0, os.getcwd())  # run from m1n1/proxyclient
    from m1n1.setup import p, u      # connects to the proxy
    from m1n1.proxy import GUARD

    dt = u.adt
    node = dt["/arm-io/pmp0"]
    base, size = node.get_reg(0)
    if size != EXPECTED_SIZE:
        sys.exit(f"pmp0 reg[0] size {size:#x} != {EXPECTED_SIZE:#x}; not reading")

    pmgr = dt["/arm-io/pmgr"]
    ps = {}
    for dev in pmgr.devices:
        gid = dt.pmgr_dev_get_id(dev)
        if gid in GATES and not dev.flags.no_ps:
            addr = dt.pmgr_dev_get_addr(dev)
            ps[f"gate{gid}"] = {"addr": hex(addr), "value": hex(p.read32(addr))}
    for k, v in ps.items():
        val = int(v["value"], 16)
        print(f"PMGR {k} @ {v['addr']} = {v['value']} (target {val & 0xf:#x}, actual {(val >> 4) & 0xf:#x})")

    buf = u.malloc(CHUNK)
    data = bytearray()
    faults = []          # [chunk_off, n_exceptions]
    word_faults = []     # exact faulting word offsets
    word_chunks = 0
    t0 = time.time()
    for off in range(0, size, CHUNK):
        print(f"\rreading +{off:#07x}", end="", flush=True)
        p.set_exc_guard(GUARD.SKIP | GUARD.SILENT)
        p.memcpy32(buf, base + off, CHUNK)
        p.udelay(50)  # let an asynchronous SError land before counting
        n = p.get_exc_count()
        p.set_exc_guard(GUARD.OFF)
        chunk = bytearray(u.iface.readmem(buf, CHUNK))
        if n:
            faults.append([off, n])
            if word_chunks < args.max_word_chunks:
                word_chunks += 1
                for w in range(0, CHUNK, 4):
                    p.set_exc_guard(GUARD.SKIP | GUARD.SILENT)
                    v = p.read32(base + off + w)
                    p.udelay(10)
                    bad = p.get_exc_count()
                    p.set_exc_guard(GUARD.OFF)
                    if bad:
                        word_faults.append(off + w)
                        v = POISON
                    chunk[w:w + 4] = struct.pack("<I", v & 0xffffffff)
            else:
                chunk[:] = struct.pack("<I", POISON) * (CHUNK // 4)
        data += chunk
    print(f"\rread {size:#x} bytes in {time.time() - t0:.1f} s; "
          f"{len(faults)} chunk(s) faulted, {len(word_faults)} word(s) located")
    u.free(buf)

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    binf = out / f"pmp0-{args.stage}.bin"
    binf.write_bytes(data)
    meta = {
        "stage": args.stage,
        "window": {"base": hex(base), "size": hex(size)},
        "pmgr": ps,
        "chunk": hex(CHUNK),
        "faulted_chunks": [[hex(o), n] for o, n in faults],
        "faulted_words": [hex(o) for o in word_faults],
        "fault_marker": hex(POISON),
        "sha256": hashlib.sha256(data).hexdigest(),
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    (out / f"pmp0-{args.stage}.json").write_text(json.dumps(meta, indent=1) + "\n")
    print(f"wrote {binf} ({meta['sha256'][:16]}...)")


if __name__ == "__main__":
    main()
