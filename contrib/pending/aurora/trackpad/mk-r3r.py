# R3-R payload, mk-r3q.py style: aurora-j716s + patches/r3r + HID_MAGICMOUSE=y, with a fixed8 DTB.
# Run after rebuilding /Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz (R3-R-RECIPE.md):
#   python3 -I ~/Work/agents/trackpad-aurora/mk-r3r.py              # R3-R: fixed8, power blacklisted
#   python3 -I ~/Work/agents/trackpad-aurora/mk-r3r.py ring         # fallback: ring transport DTB
#   python3 -I ~/Work/agents/trackpad-aurora/mk-r3r.py pcio         # fallback: pcIO reset (needs 0005)
#   python3 -I ~/Work/agents/trackpad-aurora/mk-r3r.py fixed8 power # R3-S: drop the macsmc_power blacklist
import gzip, hashlib, pathlib, struct, sys
H = pathlib.Path.home()
TA = H/"Work/agents/trackpad-aurora"
variant = sys.argv[1] if len(sys.argv) > 1 else "fixed8"
power = len(sys.argv) > 2 and sys.argv[2] == "power"
DTBS = {"fixed8": "t6050-j716s-typec-fixed8.dtb", "ring": "t6050-j716s-typec-fixed8-ring.dtb",
        "pcio": "t6050-j716s-typec-fixed8-pcio.dtb"}
m1n1 = H/"Work/agents/pipe-park/build/m1n1-plain-r2-pipepark.bin"
img = pathlib.Path("/Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz")
dtb = TA/"dt"/DTBS[variant]
initrd = H/"Work/omarchy-m5/build/initramfs-selftest.cpio.gz"
BASE = ("earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused "
        "no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5")
# R3-S (power): no blacklist, plus the SMC T6 debug args (panel stays readable on an oops).
ARGS = BASE + (" panic=0 pause_on_oops=300 ignore_loglevel" if power
               else " initcall_blacklist=macsmc_power_driver_init") + " m5.selftest=1"
sha = lambda b: hashlib.sha256(b).hexdigest()
PIN = {m1n1: "a28b1815432f27fd8126a1f4a561dc639f398151ff4ff9a6aaa740a5ad18ff46",
       initrd: "ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a",
       TA/"dt"/DTBS["fixed8"]: "6592850c2794db7f358bc12b9a94ec6c13e5cd2c76093109b6f0e40b8b127293",
       TA/"dt"/DTBS["ring"]: "73834dbc03d3405759b0d0f0449e9fe98d3a611c9ce811a045895df67f3f9a86",
       TA/"dt"/DTBS["pcio"]: "543cfded54a019d079bf7ff4666c03c836cd63f0745c9ecdcbf39c19889a46ab"}
for f, h in PIN.items():
    assert sha(f.read_bytes()) == h, f"input changed: {f}"
k = img.read_bytes()
raw = gzip.decompress(k)
# Strings that prove the kernel is the R3-R one.
NEED = {b"magicmouse hid parse failed": "CONFIG_HID_MAGICMOUSE is not =y",
        b"AFE reset %s": "patches/r3r/0001 (dockchannel-hid settle + log) is not in",
        b"no minimum key %s": "patches/r3r/0002 (macsmc-hwmon) is not in"}
if variant == "pcio":
    NEED[b"pcIO is not an eight-byte output key"] = "patches/optional-pcio/0005 is not in"
for s, why in NEED.items():
    assert s in raw, why
gzip.decompress(initrd.read_bytes())
m = m1n1.read_bytes(); d = dtb.read_bytes()
assert len(m) == 0x400000 and struct.unpack(">I", d[4:8])[0] == len(d)
tag = ("R3-S" if power else "R3-R") + {"fixed8": "", "ring": "-ring", "pcio": "-pcio"}[variant]
name = f"{tag}-aurora-trackpad-j716s-{variant}-selftest.bin"
blob = (m + f"chosen.bootargs={ARGS}\n".encode() + b"chosen.asahi,show-notch=1\n" + k + d
        + initrd.read_bytes())
(TA/"payloads"/name).write_bytes(blob)
lines = [f"{sha(blob)}  {name}", f"{sha(k)}  Image.gz (aurora-j716s + r3r)",
         f"{sha(d)}  {dtb.name}", f"bootargs: {ARGS}"]
print("\n".join(lines))
with open(TA/"payloads"/f"SHA256SUMS-{tag}", "w") as f:
    f.write("\n".join(lines + [f"{sha(x.read_bytes())}  {x.name}" for x in (m1n1, initrd)]) + "\n")
