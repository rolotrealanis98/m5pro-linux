# R3-Q payload, mk-r3.py style: R3-O with a kernel rebuilt with patches/kernel-r3q/0001-0003.
# Run after rebuilding /Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz:
#   python3 -I ~/Work/agents/pipe-park/mk-r3q.py
import gzip, hashlib, pathlib, struct
H = pathlib.Path.home()
PP = H/"Work/agents/pipe-park"
m1n1 = PP/"build/m1n1-plain-r2-pipepark.bin"           # R3-O's m1n1 (ccbb51bc + 0020)
img = pathlib.Path("/Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz")
dtb = H/"Work/agents/atc-tunables/t6050-j716s-typec-fixed7.dtb"
initrd = H/"Work/omarchy-m5/build/initramfs-selftest.cpio.gz"
BASE = ("earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused "
        "no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5")
ARGS = BASE + " initcall_blacklist=macsmc_power_driver_init m5.selftest=1"
R3N_IMAGE = "5f8b3e78da16cdaaf870385a3f095f9d1689cf9987f8605e5d9608095a6d8f54"
sha = lambda b: hashlib.sha256(b).hexdigest()
PIN = {m1n1: "a28b1815432f27fd8126a1f4a561dc639f398151ff4ff9a6aaa740a5ad18ff46",
       dtb: "1eb0fcef30554d7f6873c03372466daa837c0d2af7bba8eb138f0d1323347d25",
       initrd: "ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a"}
for f, h in PIN.items():
    assert sha(f.read_bytes()) == h, f"input changed: {f}"
k = img.read_bytes()
assert sha(k) != R3N_IMAGE, "Image.gz is still the R3-N/R3-O kernel: rebuild it with kernel-r3q first"
raw = gzip.decompress(k)
# 0002's warning string proves the series is in; 0003 has no string of its own (check git log).
assert b"lock not acknowledged; continuing" in raw, "0002 not in this Image.gz"
gzip.decompress(initrd.read_bytes())
m = m1n1.read_bytes(); d = dtb.read_bytes()
assert len(m) == 0x400000 and struct.unpack(">I", d[4:8])[0] == len(d)
name = "R3-Q-aurora-fwrestart-j716s-fixed7-pipepark-selftest.bin"
blob = (m + f"chosen.bootargs={ARGS}\n".encode() + b"chosen.asahi,show-notch=1\n" + k + d
        + initrd.read_bytes())
(PP/"payloads"/name).write_bytes(blob)
lines = [f"{sha(blob)}  {name}", f"{sha(k)}  Image.gz (aurora-j716s + kernel-r3q 0001-0003)"]
print("\n".join(lines))
with open(PP/"payloads/SHA256SUMS-R3Q", "w") as f:
    f.write("\n".join(lines + [f"{sha(x.read_bytes())}  {x.name}" for x in (m1n1, dtb, initrd)]) + "\n")
