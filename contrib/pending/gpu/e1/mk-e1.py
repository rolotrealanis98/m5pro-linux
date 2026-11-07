#!/usr/bin/env python3
"""mk-e1.py - build the GPU E1 payloads for the J716s with mk-daily.py, then add the m1n1 variable.

  python3 -I ~/Work/agents/gpu-e1/mk-e1.py          # builds both:
    e1a-ctl   kernel + DTB + m1n1 of E1, NO chosen.m5pro,gpu line: the control (every GPU node stays disabled)
    e1b-gpu   the same payload plus the line chosen.m5pro,gpu=1 after the notch line: the E1 test

Both: mk-daily.py --label ... --battery --kernel <E1 Image.gz> --dtb <E1 DTB> --m1n1 <gpu m1n1>, selftest ON
(m5.selftest=1, the default for a test payload), default initramfs (selftest, pinned in mk-daily.py).
The script asserts that e1b differs from e1a only by that one line, and that both are mk-daily.py's own layout.
Output: ~/Work/agents/gpu-e1/payloads/<label>-<date>-<sha8>.bin, .recipe.txt and a SHA256SUMS line each.
Never touches the machine; deploy with mk-daily.py --deploy-plan --payload <file> (RUN-E1.md).
"""
import datetime, hashlib, pathlib, subprocess, sys, tempfile

H = pathlib.Path.home()
E1 = H / "Work/agents/gpu-e1"
MKDAILY = H / "Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
OUT = E1 / "payloads"
INPUTS = {   # path, sha256 pin
    "kernel": (E1 / "kbuild/Image.gz", "744216550510f5c03b18587bba06cc643586089f12ab72f51d041c3e6bca77e3"),
    "dtb": (E1 / "kbuild/t6050-j716s-gpu.dtb", "0d19b701128583d54beab2c4c4c0579f3fd1d8a4bb18259c2db1c821177ff36f"),
    "m1n1": (E1 / "build/m1n1-plain-gpu.bin", "a23a3e96ec1a4e05091add9df09f8dab270bc02d62be88aa6bdcb2cfe0ce497b"),
}
M = 0x400000
NOTCH = b"chosen.asahi,show-notch=1\n"
GPU_LINE = b"chosen.m5pro,gpu=1\n"
sha = lambda b: hashlib.sha256(b).hexdigest()


def die(msg):
    sys.exit(f"mk-e1: {msg}")


for k, (p, pin) in INPUTS.items():
    if not p.is_file():
        die(f"{k} {p} missing")
    if sha(p.read_bytes()) != pin:
        die(f"{k} {p} changed (sha256 != pin {pin[:16]}); rebuild on purpose? update the pin")

date = datetime.date.today().strftime("%Y%m%d")
OUT.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    r = subprocess.run([sys.executable, "-I", str(MKDAILY), "--out", tmp, "--label", "e1base", "--battery",
                        "--kernel", str(INPUTS["kernel"][0]), "--dtb", str(INPUTS["dtb"][0]),
                        "--m1n1", str(INPUTS["m1n1"][0]), "--date", date],
                       check=True, capture_output=True, text=True)
    base = next(pathlib.Path(tmp).glob("e1base-*.bin")).read_bytes()
    base_recipe = r.stdout

m1n1 = INPUTS["m1n1"][0].read_bytes()
if base[:M] != m1n1 or base[M:M + 16] != b"chosen.bootargs=":
    die("mk-daily.py layout changed: m1n1 is not the first 4 MiB or no bootargs line after it")
nl = base.index(b"\n", M) + 1
args = base[M:nl]
if b"m5.selftest=1" not in args or b"initcall_blacklist=macsmc_power_driver_init" in args:
    die(f"unexpected bootargs (want selftest on, battery on): {args!r}")
if base[nl:nl + len(NOTCH)] != NOTCH or b"chosen.m5pro" in base[M:M + 4096]:
    die("no notch line after the bootargs, or an m5pro variable already present")
at = nl + len(NOTCH)
payloads = {"e1a-ctl": base, "e1b-gpu": base[:at] + GPU_LINE + base[at:]}
assert payloads["e1b-gpu"].replace(GPU_LINE, b"", 1) == payloads["e1a-ctl"]

sums = OUT / "SHA256SUMS"
have = sums.read_text().splitlines() if sums.exists() else []
for label, blob in payloads.items():
    d = sha(blob)
    name = f"{label}-{date}-{d[:8]}.bin"
    dest = OUT / name
    if dest.exists() and sha(dest.read_bytes()) != d:
        die(f"{dest} exists with other content")
    dest.write_bytes(blob)
    line = f"{d}  {name}"
    if line not in have:
        with open(sums, "a") as f:
            f.write(line + "\n")
    rec = [f"payload   {name}", f"sha256    {d}", f"size      {len(blob)}",
           f"m1n1 var  {'chosen.m5pro,gpu=1 (after the notch line)' if label == 'e1b-gpu' else 'none (control)'}",
           "built by  mk-e1.py from this mk-daily.py run (its payload = e1a-ctl byte for byte):", ""]
    (OUT / (name + ".recipe.txt")).write_text("\n".join(rec) + base_recipe)
    print(f"{name}  {d}")
