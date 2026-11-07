# R3-AUDIO: AOP audio on the Aurora kernel (kernel rebuild with Rust needed)

You build the kernel. I did not build or boot anything. m1n1, initramfs and bootargs are R3-R's. New: 11 kernel patches,
Rust on, audio config, and two DTBs from fixed8. Two payloads:
- **R3-AUDIO-A**: AOP + microphone array + headphone jack. Speakers held off (amps stay in hardware shutdown).
- **R3-AUDIO-B**: A plus the speakers, at most -40 dB (bootarg) under the kernel's -30 dB, amp level 10 of the ADT's 15.
  Only after ROOT-SETUP.md §5's checks pass on A.

## 1. Kernel (`/Volumes/linux-cs/wt-aurora`, branch aurora-j716s @ 6d9f1ec652a6 or later)
Rust toolchain on the Studio first (the AOP and AOP-audio drivers are Rust; today `# CONFIG_RUST is not set`):
```
rustup component add rust-src                    # the rustup toolchain, not Homebrew's rustc (no rust-src)
cargo install --locked bindgen-cli               # >= 0.71.1 (scripts/min-tool-version.sh)
export PATH=$HOME/.cargo/bin:$PATH               # rustup's rustc/cargo before /opt/homebrew/bin
export LIBCLANG_PATH=/opt/homebrew/opt/llvm/lib  # bindgen's libclang
cd /Volumes/linux-cs/wt-aurora && make ARCH=arm64 LLVM=1 rustavailable    # must say "Rust is available!"
```
Then:
```
git log --oneline -1            # 6d9f1ec652a6, or 302945c1ecb3 (16 centauri Wi-Fi/BT commits that landed on the
                                # branch during this session); the series applies in sequence on both
git am ~/Work/agents/audio-aurora/patches/kernel-audio/00*.patch
scripts/kconfig/merge_config.sh -m .config ~/Work/agents/audio-aurora/audio.config
make ARCH=arm64 LLVM=1 olddefconfig
grep -E '^CONFIG_(RUST|APPLE_AOP|SND_SOC_APPLE_AOP_AUDIO|SND_SOC_APPLE_MACAUDIO|SND_SOC_TAS2764|SND_SOC_CS42L84|APPLE_ADMAC|PINCTRL_APPLE_GPIO|I2C_APPLE|GPIO_SHARED_PROXY|HID_MAGICMOUSE)=y$' .config | wc -l   # 11
grep -E '^# CONFIG_APPLE_PMP is not set$' .config
make ARCH=arm64 LLVM=1 -j12 Image.gz
```
- `merge_config.sh` warns for each value it overrides (the `=m` ones become `=y`); any "Value requested ... not in final
  .config" line other than for symbols you knowingly dropped means a dependency is missing (usually RUST: rustavailable failed).
- Diff the config against the R3-R one and read it: `scripts/diffconfig .config.old .config`. Turning RUST on exposes Rust
  drivers; only `APPLE_PMP` defaults to y on ARCH_APPLE, and audio.config keeps it off.
- Expect a compile-fix round in the Rust files (`drivers/soc/apple/aop.rs`, `sound/soc/apple/aop_audio.rs`,
  `sound/soc/apple/aop_t8140.rs`, `rust/kernel/soc/apple/rtkit.rs`): the port was never compiled. Each patch's own text says
  what was adapted. The scratch tree `/Volumes/linux-cs/wt-audio-aurora` (branch `audio-aurora-scratch`, tree ade4e2b8) holds the
  same result for comparison.

| patch | what | author |
|---|---|---|
| 0001 macaudio: per-machine speaker volume ceiling | `max_vol` + `snd_soc_macaudio.speaker_max_db` | ed (port) |
| 0002 rtkit: let a client leave placed buffers unacknowledged | opt-in flag; others keep the echo | ours |
| 0003 aop: T6050 setup port and firmware DMA window | `apple,t6050-aop`, setup endpoints 0x20/0x23/0x32, early AP wake | ed (port) |
| 0004 aop_t8140: T6050 variant | `apple,t6050-aop-audio`: MCA-stream speakers + V/I sense, no LPAI | ed (port) |
| 0005 aop_t8140: T6050 speaker service has no output mute | | ed |
| 0006 re-align the V/I sense words | sense words one bit early on T6050 | ed |
| 0007 run the speakers only while the sense drains | | ed |
| 0008 microphone array on the LEAP-S ADMAC | 3 x float32 hpai | ed |
| 0009 microphone setup of the T604x flow | pdm0/lpai setup before pwrd | ed |
| 0010 drain the sense RX for the whole speaker run | driver-owned sense DMA ring | ed |
| 0011 macaudio: Add the J716 | `apple,j716-macaudio`, -30 dB in every state | ours |

sha256 of each patch: `SHA256SUMS` in this folder.

## 2. DTBs and payloads (current lineage: fixed8-notun-edp, kernel from the container build)
```
python3 -I ~/Work/agents/audio-aurora/mk-audio-dtb.py           # from ~/Work/agents/aurora-kernel/dts/j716s-typec-fixed8-notun-edp.dts
python3 -I ~/Work/agents/audio-aurora/mk-audio-dtb.py fixed8    # older fixed8 lineage (per-unit tunables baked in; private)
```
| DTB | sha256 |
|---|---|
| `dt/t6050-j716s-audio-notun-edp.dtb` (speakers off, mic + jack on) | d69345c1d7b0f3c4ce5edd32b254bb6e9985a637b6a8951de49d18feaa2c97f3 |
| `dt/t6050-j716s-audio-spk-notun-edp.dtb` (+ `apple,speaker-config`, amp level 10) | 9dce1b4fca95107d64841871c09fa539c9a27797012ab5a9f6a234c425c58772 |
| `dt/t6050-j716s-audio.dtb` / `-spk.dtb` (fixed8 lineage, private) | 6f400150... / 68f6c84d... (unchanged) |

The audio delta to the source DT is the same 192 decompiled lines in both lineages: pinctrl_ap opens 106/107/134/139;
i2c1/i2c2 on, new i2c3 + I2C3 power state; 6 amps + cs42l84; aop_mbox, aop_dart (+`apple,t8142-dart`), base-ns ADMAC,
aop on; new setup mailbox 0x2d067c000 and LEAP-S proxy ADMAC 0x2d3200000; aop audio node (Ed's DMA names + `hpai`,
chassis J716); sound card `apple,j716-macaudio`. The notun-edp DTS files (`dt/j716s-audio*-notun-edp.dts`) carry no
per-unit values (no tunables; MAC/BD addresses are zero placeholders) and can be published.

Payloads:
```
python3 -I ~/Work/agents/audio-aurora/mk-r3audio.py          # payloads/R3-AUDIO-A-aurora-j716s-audio-notun-edp-selftest.bin
python3 -I ~/Work/agents/audio-aurora/mk-r3audio.py spk      # payloads/R3-AUDIO-B-aurora-j716s-spk-notun-edp-selftest.bin
```
- Layout as R3-X: m1n1 (0x400000), `chosen.bootargs=`, `chosen.asahi,show-notch=1`, Image.gz, DTB, initramfs.
- **m1n1 must be pipepark-atc** (0020 + 0021): the notun DT relies on 0021 to fill the ATC tunables.
- The script pins every input, and also checks the kernel for the audio series, the built-in drivers, patch 0029
  (`apple,internal-panel`) and HID_MAGICMOUSE.
- Bootargs: R3-X's (with the macsmc_power blacklist; `power` as second argument drops it, only if R3-S passed). B adds
  `snd_soc_macaudio.speaker_max_db=-40`.

| input | path | sha256 |
|---|---|---|
| m1n1 | `~/Work/agents/pipe-park/build/m1n1-plain-r2-pipepark-atc.bin` | 28b26ebcf91e11e512ef100aae0b3e66d174ebf8a380c243dea4763ae2459a33 |
| kernel | `~/Work/agents/audio-aurora/kbuild/obj/arch/arm64/boot/Image.gz` (aurora-j716s-audio, RUST=y) | 00e8df6f06a95e7e48577784a75d95be054c0b148ca829a8375cf5ed476f0480 |
| initramfs | `~/Work/omarchy-m5/build/initramfs-selftest.cpio.gz` | ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a |
| R3-AUDIO-A payload | `payloads/R3-AUDIO-A-aurora-j716s-audio-notun-edp-selftest.bin` | a7c05d1aa8556756ebad620db127753dd7994f5005f9c8052939fe0b152362e2 |
| R3-AUDIO-B payload | `payloads/R3-AUDIO-B-aurora-j716s-spk-notun-edp-selftest.bin` | 34e9603708ea25e1b1314f89a4d63f4678a2e5cdca8214e1520889c5242b363c |

## 3. What proves each stage (R3-AUDIO-A)
Run `dmesg` after boot; then the ROOT-SETUP.md §4 commands.
1. **Boot unchanged**: keyboard, trackpad ("Touch MT ready"), NVMe, USB as on R3-R. If not, stop: the regression is from
   Rust/pinctrl/I2C, not audio (see §4, first rows).
2. **Pins and buses**: `ls -l /sys/bus/i2c/devices/ | grep -E '00(3[89a-d]|4b)'` shows 1-0038 1-0039 1-003a 2-004b 3-003b
   3-003c 3-003d, each with `driver -> tas2764` / `cs42l84`. No `requested reserved line` or `-EPROBE_DEFER` loops in dmesg for them.
3. **AOP up**:
   - `290c00000.aop: 13 AFK endpoints started` (the count is J714c's; any number with no error after it passes),
   - `AFK endpoint 0x2? channel ? announces aop-audio` (also `aop-audprov`, `aop-voicetrigger`),
   - no `setup port: boot incomplete`, no `AOP firmware crashed`, no `RTKit wake failed`.
4. **Cards**: `cat /proc/asound/cards` lists `AppleJ716 ... MacBook Pro J716` and `AppleJ716AOP ... MacBook Pro J716 AOP`.
   macaudio says `the boot loader passed no amp levels, disabling speakers` (expected on A).
5. **Mic**: `arecord -D hw:AppleJ716AOP,0 -f FLOAT_LE -c 3 -r 48000 -d 5 /tmp/mic.wav` records. On the first open the AOP
   driver logs `lpai channel masks: 0x0`, `pdm0 config: 0x0`, `pdm0 hf decimator: 0x0` (0 = accepted). Speech at roughly
   -60 dBFS raw passes; the DSP source "MacBook Pro J716 Microphone" adds +36 dB.
6. **Jack** (optional): headphones in, `aplay -D plughw:AppleJ716,0` of a quiet file. Unverified on T6050 by anyone.

R3-AUDIO-B adds (ROOT-SETUP.md §5 has the commands and the stop rules):
7. No "passed no amp levels"; `Speaker volumes unlocked` after speakersafetyd starts; `Speaker volume ceiling -40 dB`.
8. `speakersafetyd` journal: opens `hw:AppleJ716,2`, 12 channels, no panic; per-speaker temperatures move during a tone.
9. A -40 dBFS tone through `plughw:AppleJ716,1` is faintly audible on all six drivers, and the amps' IRQ line stays quiet
   (no `fault:` lines from tas2764).

## 4. Failure signatures
| what you see | meaning | next |
|---|---|---|
| boot hangs or SErrors right after the mailbox/AOP probe | the setup mailbox at 0x2d067c000 is not reachable on this boot (Aurora reports an SError there; Ed reads it on J714c) | back to R3-R; send the last screen. Without the setup port the T6050 AFK endpoints never answer, so there is no audio fallback, only AOP-less boots |
| hang or regression before any audio line | RUST/pinctrl/I2C build change (`PINCTRL_APPLE_GPIO=y` binds pinctrl_ap for the first time) | boot R3-R; rebuild with `PINCTRL_APPLE_GPIO=y` but the fixed8 DTB to separate DT from config |
| no `AFK endpoints started`, no AOP lines at all | APPLE_AOP not built in, or the aop node is not okay | `zcat /proc/config.gz \| grep -E 'RUST|APPLE_AOP'`; `fdtget`-equivalent: `cat /proc/device-tree/soc@200000000/aop@290c00000/status` |
| `setup port: boot incomplete (AP power on: ..., endpoints: n/3)` | the TRUSTED side did not hand out all three setup endpoints | send dmesg; compare with Ed's J714c (3 endpoints) |
| `setup port: HELLO version 0x...` | different setup protocol version | send dmesg |
| `AOP firmware crashed`, or AFK silence after `endpoints started` | host buffer outside the firmware's window (Ed's first failure) | check `apple,dma-range` on the aop node; send the RTKit crashlog lines |
| `apple-dart 290fc0000.iommu` fault lines | stream or window mismatch on dart-aop (streams 0, 1, 8, 11 are used) | send dmesg; check the t8142 compatible made it into the DTB |
| `hpai: DMA channel unavailable` | LEAP-S proxy ADMAC did not probe | `ls /sys/bus/platform/devices/ \| grep 2d3200000`; dmesg for admac |
| mic records exact zeros or a flat floor | Ed's 10:36 state ("idle noise floor only") | check the `pdm0 ...` lines; record with the lid open (`Internal Mic Jack`: closed lid = unplugged) |
| amps or jack codec stuck in deferred probe | shared SDZ GPIO without the proxy, a reserved pin, or the I2C3 power state | `cat /sys/kernel/debug/devices_deferred`; `GPIO_SHARED_PROXY=y`; check `gpio-reserved-ranges` |
| `sound` deferred forever, no AppleJ716 card | its CPU component (the AOP audio node) never registered | fix the AOP rows above first |
| B: `driver can't assure safety on this model, disabling speakers` | 0011 missing (falls back to `apple,macaudio`) | check the J716 compatible string in the kernel |
| B: `Speaker volumes locked: ...` and silence | speakersafetyd not holding the lock (safe) | ROOT-SETUP.md §5; `journalctl -u speakersafetyd` |
| B: tas2764 `fault: bad TDM clock` | the AOP stopped the serializer under the amps (Ed: mute toggle, undrained sense) | send dmesg + speakersafetyd journal; boot A |
| B: speakersafetyd panics / negative power | sense words misaligned or wrong scale | stop; boot A; send the journal (0006 should prevent the alignment case) |
| B: right speakers' power ~4x the left in the daemon | J714c's i2c3 V/I doubling | halve right `is_scale`/`vs_scale` (ROOT-SETUP.md §5) |

## Rollback
As R3-X: restore `boot.bin.prev`. m1n1 (pipepark-atc) and the initramfs are R3-X's; kernel and DTB differ.
