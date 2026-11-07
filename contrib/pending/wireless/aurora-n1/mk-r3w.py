#!/usr/bin/env python3
# R3-W payloads (mk-r3r.py style): aurora-j716s + patches/kernel-n1 + the N1 config, fixed9 DTB.
# Run after rebuilding /Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz (R3-W-RECIPE.md):
#   python3 -I ~/Work/agents/n1-wifi/mk-r3w.py probe      # R3-W0: m1n1 0022 only, reads port 0, no training
#   python3 -I ~/Work/agents/n1-wifi/mk-r3w.py train      # R3-W1: + 0023, chosen.m5pro,n1=1
#   python3 -I ~/Work/agents/n1-wifi/mk-r3w.py train-smc  # R3-W2: + 0023, chosen.m5pro,n1=2 (SMC gP13 release first)
# Outputs land in ~/Work/agents/n1-wifi/payloads/ (private: the initramfs carries the per-unit FTAB).
import gzip, hashlib, pathlib, struct, sys
H = pathlib.Path.home()
N1 = H/"Work/agents/n1-wifi"
variant = sys.argv[1] if len(sys.argv) > 1 else "probe"
assert variant in ("probe", "train", "train-smc"), variant
M1N1 = {"probe": N1/"build/m1n1-plain-n1-dt.bin", "train": N1/"build/m1n1-plain-n1-train.bin",
        "train-smc": N1/"build/m1n1-plain-n1-train.bin"}[variant]
img = pathlib.Path("/Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz")
dtb = N1/"dt/t6050-j716s-typec-fixed9.dtb"
initrd = N1/"payloads/initramfs-selftest-n1.cpio.gz"
ARGS = ("earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused "
        "no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5 "
        "initcall_blacklist=macsmc_power_driver_init m5.selftest=1")
sha = lambda b: hashlib.sha256(b).hexdigest()
PIN = {N1/"build/m1n1-plain-n1-dt.bin": "7621429bcd5716ad6443f131241d4cb9a3a54b6bfa7181da71390f9499a83914",
       N1/"build/m1n1-plain-n1-train.bin": "d31e5248fed273fdb4fd81cdb08bd007f82fc0df7e953e6ffb75434ba6a3deae",
       dtb: "edac01e04e254eb9bbc18b0a1332bb753357816d70bfc5ab186559275479e969",
       initrd: "caec8090b12f54614bc36bf652edfe55a944ddd52d07cb8b7a6a306d4c69e78a"}
for f, h in PIN.items():
    assert sha(f.read_bytes()) == h, f"input changed: {f}"
k = img.read_bytes()
raw = gzip.decompress(k)
# Strings that prove the kernel is the R3-W one (all built in).
NEED = {b"adopted port %d, endpoint %02x:00": "patches/kernel-n1 0003 (PR #937 adoption) is not in",
        b"link retrained after a root-port reset": "patches/kernel-n1 0006 is not in",
        b"missing personalized firmware name": "APPLE_CENTAURI is not =y (or 0008 missing)",
        b"Wi-Fi firmware channels": "APPLE_CENTAURI_WIFI is not =y (or 0015 missing)",
        b"Beta IPC initialization failed": "BT_HCICENTAURI is not =y (or 0010 missing)",
        b"apple,t6050-pinctrl": "PINCTRL_APPLE_GPIO is not =y (reset-gpios would defer forever)"}
for s, why in NEED.items():
    assert s in raw, why
gzip.decompress(initrd.read_bytes())
m = M1N1.read_bytes(); d = dtb.read_bytes()
assert len(m) == 0x400000 and struct.unpack(">I", d[4:8])[0] == len(d)
tag = {"probe": "R3-W0", "train": "R3-W1", "train-smc": "R3-W2"}[variant]
chosen = b"chosen.asahi,show-notch=1\n"
if variant != "probe":
    chosen += b"chosen.m5pro,n1=%s\n" % (b"1" if variant == "train" else b"2")
name = f"{tag}-aurora-n1-j716s-fixed9-{variant}-selftest.bin"
blob = m + f"chosen.bootargs={ARGS}\n".encode() + chosen + k + d + initrd.read_bytes()
(N1/"payloads").mkdir(exist_ok=True)
(N1/"payloads"/name).write_bytes(blob)
lines = [f"{sha(blob)}  {name}", f"{sha(k)}  Image.gz (aurora-j716s + kernel-n1)",
         f"{sha(m)}  {M1N1.name}", f"{sha(d)}  {dtb.name}", f"{sha(initrd.read_bytes())}  {initrd.name}",
         f"bootargs: {ARGS}", "chosen: " + chosen.decode().replace("\n", " ")]
print("\n".join(lines))
(N1/"payloads"/f"SHA256SUMS-{tag}").write_text("\n".join(lines) + "\n")
