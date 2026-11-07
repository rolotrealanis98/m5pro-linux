# R3-AUDIO payload, R3-X style: the container-built audio kernel (aurora-j716s-audio = 302945c1 + 0029 + kernel-audio,
# RUST=y) with a J716s audio DTB on the current DT lineage (fixed8-notun-edp: no baked apple,tunable-* lists, m1n1 0021
# fills them at boot, so m1n1 must be pipepark-atc as on R3-T/V/X).
#   python3 -I ~/Work/agents/audio-aurora/mk-r3audio.py              # R3-AUDIO-A: AOP + mic + jack, speakers off
#   python3 -I ~/Work/agents/audio-aurora/mk-r3audio.py spk          # R3-AUDIO-B: + speakers (only after ROOT-SETUP §5)
#   add "power" as a second argument to drop the macsmc_power blacklist (only if R3-S passed)
import gzip, hashlib, pathlib, struct, sys
H = pathlib.Path.home()
AA = H/"Work/agents/audio-aurora"
variant = sys.argv[1] if len(sys.argv) > 1 else "audio"
power = len(sys.argv) > 2 and sys.argv[2] == "power"
assert variant in ("audio", "spk"), "variant is audio or spk"
DTBS = {"audio": ("t6050-j716s-audio-notun-edp.dtb",
                  "d69345c1d7b0f3c4ce5edd32b254bb6e9985a637b6a8951de49d18feaa2c97f3"),
        "spk": ("t6050-j716s-audio-spk-notun-edp.dtb",
                "9dce1b4fca95107d64841871c09fa539c9a27797012ab5a9f6a234c425c58772")}
m1n1 = H/"Work/agents/pipe-park/build/m1n1-plain-r2-pipepark-atc.bin"     # 0020 + 0021 (ATC tunables from the ADT)
img = AA/"kbuild/obj/arch/arm64/boot/Image.gz"                             # container build, 2026-11-06
dtb = AA/"dt"/DTBS[variant][0]
initrd = H/"Work/omarchy-m5/build/initramfs-selftest.cpio.gz"
BASE = ("earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused "
        "no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5")
ARGS = BASE + ("" if power else " initcall_blacklist=macsmc_power_driver_init") + " m5.selftest=1"
if variant == "spk":
    # The first speaker boot: 10 dB under the kernel's -30 dB ceiling (the parameter can only lower it).
    ARGS += " snd_soc_macaudio.speaker_max_db=-40"
sha = lambda b: hashlib.sha256(b).hexdigest()
PIN = {m1n1: "28b26ebcf91e11e512ef100aae0b3e66d174ebf8a380c243dea4763ae2459a33",
       initrd: "ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a",
       img: "00e8df6f06a95e7e48577784a75d95be054c0b148ca829a8375cf5ed476f0480",
       AA/"dt"/DTBS["audio"][0]: DTBS["audio"][1],
       AA/"dt"/DTBS["spk"][0]: DTBS["spk"][1]}
for f, h in PIN.items():
    assert sha(f.read_bytes()) == h, f"input changed: {f}"
k = img.read_bytes()
raw = gzip.decompress(k)
# Strings that prove the kernel carries the audio series, the built-in drivers and the R3-X changes.
NEED = {b"Speaker volume ceiling %d dB": "kernel-audio/0001 (macaudio ceiling) is not in",
        b"AFK endpoints started": "kernel-audio/0003 (AOP T6050) is not in, or CONFIG_APPLE_AOP is not =y",
        b"apple,t6050-aop-audio": "kernel-audio/0004, or CONFIG_SND_SOC_APPLE_AOP_AUDIO is not =y",
        b"apple,j716-macaudio": "kernel-audio/0011, or CONFIG_SND_SOC_APPLE_MACAUDIO is not =y",
        b"the boot loader passed no amp levels": "CONFIG_SND_SOC_APPLE_MACAUDIO is not =y",
        b"apple,internal-panel": "patch 0029 (simpledrm eDP connector) is not in; the notun-edp DT expects it",
        b"magicmouse hid parse failed": "CONFIG_HID_MAGICMOUSE is not =y (the R3-R trackpad fix)"}
for s, why in NEED.items():
    assert s in raw, why
gzip.decompress(initrd.read_bytes())
m = m1n1.read_bytes(); d = dtb.read_bytes()
assert len(m) == 0x400000 and struct.unpack(">I", d[4:8])[0] == len(d)
tag = {"audio": "R3-AUDIO-A", "spk": "R3-AUDIO-B"}[variant] + ("-power" if power else "")
name = f"{tag}-aurora-j716s-{variant}-notun-edp-selftest.bin"
blob = (m + f"chosen.bootargs={ARGS}\n".encode() + b"chosen.asahi,show-notch=1\n" + k + d
        + initrd.read_bytes())
(AA/"payloads").mkdir(exist_ok=True)
(AA/"payloads"/name).write_bytes(blob)
lines = [f"{sha(blob)}  {name}", f"{sha(k)}  Image.gz (aurora-j716s-audio, container build)",
         f"{sha(d)}  {dtb.name}", f"bootargs: {ARGS}"]
print("\n".join(lines))
with open(AA/"payloads"/f"SHA256SUMS-{tag}", "w") as f:
    f.write("\n".join(lines + [f"{sha(x.read_bytes())}  {x.name}" for x in (m1n1, initrd)]) + "\n")
