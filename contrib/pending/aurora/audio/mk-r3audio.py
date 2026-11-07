# R3-AUDIO payload, mk-r3r.py style: aurora-j716s (6d9f1ec652a6) + patches/kernel-audio + audio.config,
# with the J716s audio DTB. Run after rebuilding /Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz
# (R3-AUDIO-RECIPE.md):
#   python3 -I ~/Work/agents/audio-aurora/mk-r3audio.py              # R3-AUDIO-A: AOP + mic + jack, speakers off
#   python3 -I ~/Work/agents/audio-aurora/mk-r3audio.py spk          # R3-AUDIO-B: + speakers (only after ROOT-SETUP §4)
#   add "power" as a second argument to drop the macsmc_power blacklist (only if R3-S passed)
import gzip, hashlib, pathlib, struct, sys
H = pathlib.Path.home()
AA = H/"Work/agents/audio-aurora"
variant = sys.argv[1] if len(sys.argv) > 1 else "audio"
power = len(sys.argv) > 2 and sys.argv[2] == "power"
assert variant in ("audio", "spk"), "variant is audio or spk"
DTBS = {"audio": "t6050-j716s-audio.dtb", "spk": "t6050-j716s-audio-spk.dtb"}
m1n1 = H/"Work/agents/pipe-park/build/m1n1-plain-r2-pipepark.bin"
img = pathlib.Path("/Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz")
dtb = AA/"dt"/DTBS[variant]
initrd = H/"Work/omarchy-m5/build/initramfs-selftest.cpio.gz"
BASE = ("earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused "
        "no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5")
ARGS = BASE + ("" if power else " initcall_blacklist=macsmc_power_driver_init") + " m5.selftest=1"
if variant == "spk":
    # The first speaker boot: 10 dB under the kernel's -30 dB ceiling (the parameter can only lower it).
    ARGS += " snd_soc_macaudio.speaker_max_db=-40"
sha = lambda b: hashlib.sha256(b).hexdigest()
PIN = {m1n1: "a28b1815432f27fd8126a1f4a561dc639f398151ff4ff9a6aaa740a5ad18ff46",
       initrd: "ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a",
       AA/"dt"/DTBS["audio"]: "6f40015081e0d5d73adcb6cd66ee3cdb1591bea2de3fd81a7fde7906deaa92cd",
       AA/"dt"/DTBS["spk"]: "68f6c84df349da6b40f8bc6465cbdca1c553a717207b93cad3c9916c2c867685"}
for f, h in PIN.items():
    assert sha(f.read_bytes()) == h, f"input changed: {f}"
k = img.read_bytes()
raw = gzip.decompress(k)
# Strings that prove the kernel carries the audio series and the built-in drivers.
NEED = {b"Speaker volume ceiling %d dB": "kernel-audio/0001 (macaudio ceiling) is not in",
        b"AFK endpoints started": "kernel-audio/0003 (AOP T6050) is not in, or CONFIG_APPLE_AOP is not =y",
        b"apple,t6050-aop-audio": "kernel-audio/0004, or CONFIG_SND_SOC_APPLE_AOP_AUDIO is not =y",
        b"apple,j716-macaudio": "kernel-audio/0011, or CONFIG_SND_SOC_APPLE_MACAUDIO is not =y",
        b"the boot loader passed no amp levels": "CONFIG_SND_SOC_APPLE_MACAUDIO is not =y",
        b"magicmouse hid parse failed": "CONFIG_HID_MAGICMOUSE is not =y (the R3-R trackpad fix)"}
for s, why in NEED.items():
    assert s in raw, why
gzip.decompress(initrd.read_bytes())
m = m1n1.read_bytes(); d = dtb.read_bytes()
assert len(m) == 0x400000 and struct.unpack(">I", d[4:8])[0] == len(d)
tag = {"audio": "R3-AUDIO-A", "spk": "R3-AUDIO-B"}[variant] + ("-power" if power else "")
name = f"{tag}-aurora-j716s-{variant}-selftest.bin"
blob = (m + f"chosen.bootargs={ARGS}\n".encode() + b"chosen.asahi,show-notch=1\n" + k + d
        + initrd.read_bytes())
(AA/"payloads").mkdir(exist_ok=True)
(AA/"payloads"/name).write_bytes(blob)
lines = [f"{sha(blob)}  {name}", f"{sha(k)}  Image.gz (aurora-j716s + kernel-audio)",
         f"{sha(d)}  {dtb.name}", f"bootargs: {ARGS}"]
print("\n".join(lines))
with open(AA/"payloads"/f"SHA256SUMS-{tag}", "w") as f:
    f.write("\n".join(lines + [f"{sha(x.read_bytes())}  {x.name}" for x in (m1n1, initrd)]) + "\n")
