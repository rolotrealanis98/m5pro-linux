import sys, gzip, hashlib, pathlib
m1n1 = pathlib.Path.home()/"Work/agents/m1n1-r2/m1n1-plain.bin"
img  = pathlib.Path("/Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz")
initrd = pathlib.Path.home()/"Work/omarchy-m5/build/initramfs-debug.cpio.gz"
BASE = "earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5"
GATED = BASE + " initcall_blacklist=macsmc_power_driver_init"
out = pathlib.Path.home()/"Work/agents/aurora-kernel/payloads"
def members(b):
    n=0; off=0
    while off < len(b):
        d = gzip.GzipFile(fileobj=__import__("io").BytesIO(b[off:]))
        d.read(); off += d.fileobj.tell() if hasattr(d.fileobj,'tell') else len(b); n+=1
        break
    return n
assert len(m1n1.read_bytes()) == 0x400000
sums=[]
for name, dtb, args in [
    ("R3-A-aurora-j716c-gated.bin", "/Users/rolo/Work/agents/aurora-kernel/t6050-j716c-cpuorder.dtb", GATED),
    ("R3-B-aurora-j716s-gated.bin", "/Users/rolo/Work/agents/aurora-kernel/t6050-j716s-cpuorder.dtb", GATED),
]:
    blob = m1n1.read_bytes() + f"chosen.bootargs={args}\n".encode() + b"chosen.asahi,show-notch=1\n" + img.read_bytes() + pathlib.Path(dtb).read_bytes() + initrd.read_bytes()
    p = out/name; p.write_bytes(blob)
    h = hashlib.sha256(blob).hexdigest(); sums.append(f"{h}  {name}")
    print(f"{name}: {len(blob)} bytes sha256 {h[:16]}")
for f in [m1n1, img, initrd]:
    sums.append(f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.name}")
(out/"SHA256SUMS").write_text("\n".join(sums)+"\n")
