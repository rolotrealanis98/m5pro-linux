# J716s audio on the Aurora kernel: analysis (2026-11-06, Studio only, nothing built or booted)

Base: `/Volumes/linux-cs/wt-aurora` branch `aurora-j716s` @ `6d9f1ec652a6` (read-only).
Scratch worktree: `/Volumes/linux-cs/wt-audio-aurora`, local branch `audio-aurora-scratch` (11 commits on 6d9f1ec).
Source of the port: `github.com/edimoldovan/linux-aurora` branch `t6050-j714c` @ `671fd38e1c0d` (fetched as remote
`edimoldovan` in `/Volumes/linux-cs/linux`; his base is integration/aurora `44d5afc79da7`, 2026-10-20, an ancestor of ours).

## 1. Bottom line
- Ed's J714c audio is a **T6050-generic AOP audio stack** plus a thin J714 layer. The generic part is 10 kernel commits in
  four files (`aop.rs`, `rtkit.rs`/`rtkit.c`, `t8140_aop_audio.rs`, `macaudio.c`). All of it ported onto 6d9f1ec (section 3);
  the series applies in sequence on wt-aurora and gives the scratch tree byte for byte (tree `ade4e2b8`).
- **Speakers:** working on J714c through the AOP's MCA serializer stream (6 x 32-bit out, 12 x 16-bit V/I sense back), with
  speakersafetyd running. Ed's last commit lifts J714 to the J314 level (gain 15, no unlocked ceiling); for J716 we keep his
  earlier "-30 dB in every state" stage (7818011b2ba8) in our own machine entry (patch 0011).
- **Microphones:** the 3-capsule array works through the LEAP-S ADMAC's non-secure proxy, but very quietly: speech near the
  machine reads about -62 dBFS raw, and his asahi-audio PR adds +36 dB in a DSP graph. His kernel commits of 10:20 and 10:36
  still say "idle noise floor only"; his asahi-audio commit of 14:50 records speech. **This corrects our REPORT.md (11-04),
  which called the built-in mics "probably impossible" on M5.**
- **No firmware file is needed on Linux.** iBoot preloads the AOP firmware (`mac17jaop`); the J716s ADT has the AOP's
  `segment-ranges` filled in, and the driver requests no firmware for T6050 (section 6).
- **Hard prerequisite:** the whole AOP stack is Rust. Today's wt-aurora `.config` has `# CONFIG_RUST is not set`, and
  `bindgen` is not installed on the Studio. Turning Rust on is the main build-side change and risk (ROOT-SETUP.md §1,
  R3-AUDIO-RECIPE.md §1).
- Mic first: yes. The default DTB brings up AOP + mic + jack with the speakers held off (amps in hardware shutdown).

## 2. Ed's commits since 2026-11-05 (author `ed`, GitHub edimoldovan)
G = generic T6050 (ported), B = J714c board/config (not ported, J716 equivalent written instead), N = not audio.

| commit | time | subject | class |
|---|---|---|---|
| c04e453c26ac | 11-05 15:26 | dts: t6050: real MPIDRs for clusters 1 and 2 | N |
| 13c28edbabb6 | 11-05 16:10 | configs: j714c: zram swap and Landlock | N |
| edc3ec0480a4 | 11-05 16:38 | drm/asahi: g17: T6050 crash-log buffers | N |
| e0a190841586 | 11-05 17:18 | dts: t6050: cpufreq for clusters 1 and 2 | N |
| 594f4b3a49ec | 11-05 17:45 | dts: t6050-j714c: keyboard backlight | N |
| 0fbd859e287d | 11-05 18:08 | rtkit: give the T6050 AP power ACK a short window | G, not needed: our rtkit.c waits for the ACK in full (`apple_rtkit_set_ap_power_state`, no T6050 skip) |
| 4602eba4b9d2 | 11-05 18:08 | dts: t6050-j714c: SMC lid, power button, RTC, GPIO | N |
| 9dee12b1266c | 11-05 18:08 | simpledrm: eDP connector | N |
| 17b3cc9ca3a6 | 11-05 19:22 | configs: j714c: s2idle | N |
| 9f8535b38fcb | 11-05 19:22 | xhci-plat: honour wakeup-source | N |
| 68d2fe0a8e7f | 11-05 19:41 | macsmc-power: initialise work items before the notifier | N (ours: 6477b7bef65e) |
| 0bc84cc4a6b2 | 11-05 19:41 | configs: j714c: SMC battery | N |
| c5b0600d19a4 | 11-05 19:53 | dts: t6050-j714c: SMC sensors | N |
| 00662e9fd517 | 11-06 00:45 | configs: j714c: netfilter and PCI | N |
| c5b75c4f7a9d | 11-05 20:00 | dts: j714c: audio stage A, amps and jack codec on I2C | B (DT; J716s version in the DT snippet) |
| 3326c74270cc | 11-05 20:00 | macaudio: per-machine speaker volume ceiling, J714 config | G (ceiling) + B (J714 entry) -> 0001 |
| 053f1912e7d5 | 11-05 20:53 | t6050: AOP bring-up step 1, J714c | G (aop.rs) + B (DT, config) -> 0003 |
| 1079af2f94d2 | 11-05 21:05 | t8140_aop_audio: T6050 variant; J714c sound card | G (driver) + B (DT, J714 entry) -> 0004 |
| f4427365cc8f | 11-05 23:34 | aop: T6050 setup port and firmware DMA window | G (aop.rs, rtkit) + B (DT) -> 0002 + 0003 |
| 7818011b2ba8 | 11-06 00:10 | macaudio, t8140_aop_audio: J714 speakers on, -30 dB everywhere | G (no output mute on T6050) -> 0005; B (J714 entry) |
| a97d98de3360 | 11-06 01:54 | t8140_aop_audio: re-align the V/I sense words | G -> 0006 |
| 2932d59e0511 | 11-06 08:25 | configs: j714c: the defaults the working builds had | B |
| 392796584e77 | 11-06 08:26 | t8140_aop_audio: speakers only while the sense drains | G -> 0007 |
| 8838ca614344 | 11-06 10:20 | t8140_aop_audio: microphone array on the LEAP-S ADMAC | G (driver) + B (DT) -> 0008 |
| c7a1fe3e38d3 | 11-06 10:36 | t8140_aop_audio: microphone setup of the T604x flow | G -> 0009 |
| 369cac02ce47 | 11-06 12:11 | t8140_aop_audio: drain the sense RX for the whole speaker run | G -> 0010 |
| f21e1ea10bbd | 11-06 15:33 | macaudio: J714 speakers at the J314 level | B (not ported on purpose) |
| 803e0a80475e .. a9a49ace93f5 | 11-06 11:22-22:12 | N1 Wi-Fi/BT (centauri), PCIe adopt path, iwd config (12 commits) | N |

"J714c" in the subjects of 0006-0010 is where they were tested; the code is keyed on the T6050 `HwConfig`, not the board.

Userspace (all open, by edimoldovan, 2026-11-06):
- aurora-silicon/asahi-audio #20 (`edimoldovan/asahi-audio:j714` @ 61cdb964c7b1): J714 speakers take the J314 tuning with the
  tweeter outputs moved last (ADT slot order LW1 RW1 LW2 RW2 LT RT); WirePlumber rule for `hw:AppleJ714,1`; mic graph
  `firs/j714/mic.json` for `hw:AppleJ714AOP,0` (3 x float32, -3.6 dB on capsule 3, average, +36 dB, 120 Hz HPF, limiter -1 dBFS).
- aurora-silicon/alsa-ucm-conf-asahi #10 (`j714` @ 401a49d4f7ee): `macaudio/MacBook Pro J714.conf` (J514 profile: jack dev 0,
  6 speaker channels dev 1, element "Left Woofer 1 Speaker Volume") and `t8140-aop-audio/MacBook Pro J714 AOP Audio.conf`
  (`aop_audio/3chan/HiFi.conf`).
- omacom/omarchy-mac-pkgs #94 (`j714-speaker-safety` @ 76571ca2e697): speakersafetyd `apple/j714.conf`, derived from **our**
  `j716.conf` plus per-speaker `z_nominal` from the J714c ADT and **halved is_scale/vs_scale (1.875/7) on the three i2c3
  (right) amps**, which report V and I at twice the left amps'. Our j716.conf lacks that halving (ROOT-SETUP.md §4).

## 3. The port (patches/kernel-audio)
| patch | author | from | what changed in the port |
|---|---|---|---|
| 0001 macaudio: per-machine speaker volume ceiling | ed | 3326c74270cc | ceiling applied in today's per-control `macaudio_vlimit_unlock()`; J714 entry and config dropped |
| 0002 rtkit: let a client leave placed buffers unacknowledged | ours (Assisted-by: LLM) | replaces the rtkit.c hunk of f4427365cc8f | Ed removed the placed-buffer echo for every client; DCP, the G17 GPU and the T6040 USB2 PHY still rely on it here, so it is a new opt-in flag `APPLE_RTKIT_PLACED_BUFFERS_UNACKED` + `RtKit::new_with_placed_buffers_unacked()` |
| 0003 aop: T6050 setup port and firmware DMA window | ed | 053f1912e7d5 + f4427365cc8f (driver parts, squashed) | T6050 entry carries this tree's `ncal`/`fw_regions`/`bootargs_word_access`/`halt_on_failed_start`; new `placed_buffers` field so only T6050 gets the unacked RTKit mode (Ed's tree switched every AOP to `COPROC_PLACES_BUFFERS`); stale "without the setup port" comment fixed |
| 0004 aop_t8140: T6050 variant | ed | 1079af2f94d2 | `t8140_aop_audio.rs` is `aop_t8140.rs` here, a backend of `aop_audio.rs` (aurora 5d99c282f87b): `apple,t6050-aop-audio` goes into aop_audio.rs's table as `AopVariant::T8140(&HW_T6050)` |
| 0005 aop_t8140: T6050 speaker service has no output mute | ed | 7818011b2ba8, driver part | message trimmed to the driver change |
| 0006-0010 sense re-align, sense-drain gating, LEAP-S mic, T604x mic setup, sense RX drain | ed | a97d98de3360, 392796584e77, 8838ca614344, c7a1fe3e38d3, 369cac02ce47 | applied unchanged (3-way, no conflicts) |
| 0011 macaudio: Add the J716 | ours (Assisted-by: LLM) | new | `apple,j716-macaudio`: SN012776 2W+1T, `safe_vol` -30 and `max_vol` -30, `fe_dai_names` j714-pcm-0..2, jack bclk ratio 64; amp levels from the DT; binding enum entry |

Verification done: `git apply --check` then `--cached` apply of 0001..0011 in order against wt-aurora's HEAD tree (temporary
index; wt-aurora untouched) -> tree `ade4e2b81033298c9b678bf3a79942a4aa9cdd1a`, equal to the scratch worktree's.
wt-aurora moved to `302945c1ecb3` during this session (16 centauri Wi-Fi/BT commits applied by someone else, none in these
files); the series also applies in sequence there.
`rustfmt --check` parses every touched Rust file without errors (it reports formatting differences only: 7 hunks in aop.rs,
18 in aop_t8140.rs, mostly Ed's unformatted blocks). **Not done: no compile** (CONFIG_RUST is off and no bindgen; the brief
said not to build). Expect a compile-fix round for the Rust files on the first build.

## 4. What integration/aurora (6d9f1ec) already has
| block | driver | compatibles | Kconfig | state in wt-aurora .config |
|---|---|---|---|---|
| AOP | `drivers/soc/apple/aop.rs` (Rust) | t8103/t8112/t6000/t6020/t8140/t6041/t8132-aop; **no t6050/t8152 before 0003** | `APPLE_AOP` (depends RUST, PM) | not set (RUST off) |
| AOP audio | `sound/soc/apple/aop_audio.rs` + `aop_t8140.rs`, `aop_spkr.rs` (J616s), `aop_lid.rs` | apple,aop-audio, t6030/t6041/t8140-aop-audio; **no t6050 before 0004** | `SND_SOC_APPLE_AOP_AUDIO` (Ed's tree: `SND_SOC_APPLE_T8140_AOP_AUDIO`) | not set |
| machine | `sound/soc/apple/macaudio.c` | j180..j713, j614/j616(-jack), j700, apple,macaudio; **J716 in 0011** | `SND_SOC_APPLE_MACAUDIO` | m |
| amps | `sound/soc/codecs/tas2764.c` | ti,tas2764, ti,sn012776 (+ apple,speaker-config / amp-tx-zd-config / bop-config / amp-dcblocker-config / deferred-shutdown / SDZ-supply group) | `SND_SOC_TAS2764` | m |
| jack | `sound/soc/codecs/cs42l84.c` | cirrus,cs42l84 | `SND_SOC_CS42L84` | m |
| ADMAC | `drivers/dma/apple-admac.c` | t8140 (evolved layout), t8132, t8122, t8103, apple,admac | `APPLE_ADMAC` | m |
| MCA | `sound/soc/apple/mca.c` | t8103-mca, apple,mca (unused on T6050: no AP MCA) | `SND_SOC_APPLE_MCA` | m |
| setup mailbox | `drivers/soc/apple/mailbox.c` | apple,t8140-aop-setup-mailbox | `APPLE_MAILBOX` | y |
| dart-aop | `drivers/iommu/apple-dart.c` | per-stream/fw_mirror only for t8140/t8142(/t6041) DARTs | `APPLE_DART` | y |
| pinctrl | `pinctrl-apple-gpio` | apple,t8103-pinctrl | `PINCTRL_APPLE_GPIO` | m |
| I2C | `i2c-pasemi` Apple | apple,t8103-i2c | `I2C_APPLE` | m |

No modules are built for the M5 payloads (R3-R-RECIPE.md), so every `=m` above is absent at runtime today.

T6050 DT in the tree (`t6050-die0.dtsi:639-775`, Aurora PR #945): `pinctrl_ap`, i2c1, i2c2 (no i2c3), `aop_mbox`, `aop_dart`
(`apple,t6050-dart`, `apple,t8110-dart`), `admac_base_ns`, `aop` (`apple,t6050-aop`, `apple,t8152-aop`, mmio 0x1e0000) with an
`audio` child (`apple,t6050-aop-audio`, dma-names cout/cin/spkr/sense), all disabled "until Aura's checks pass". Two points
differ from Ed's working J714c: Aurora says the `aop-exclave-mailbox` "takes an SError from the AP" and boots the AOP "as on
T8152, over the RTKit mailbox alone"; Ed found that without the setup port the AFK endpoints never answer, and reaches it at
**0x2d067c000** (ASC + 1 GiB + 0x7c000; his first try at the translated 0x4d067c000 hung). Ed also needs the
`apple,t8142-dart` compatible on dart-aop for the retained-root path. The DT snippet follows Ed. Aurora's own M5 AOP audio
(T8142 J813 / T8152 J873, setup port included) is on branch `j813-audio-initialization-20261106` @ ad4910ce6ec1, not merged;
it is the likely future upstream shape and a fallback reference.

## 5. J716s deltas (J716s ADT `adt-runtime-j716s.bin`, hardware properties only)
| item | J716s | J714c (Ed) | note |
|---|---|---|---|
| amps | 6 x sn012776: i2c1 0x38 LW1 (`audio-speaker`, holds speaker-config), 0x39 LW2, 0x3a LT; i2c3 0x3b RW1, 0x3c RW2, 0x3d RT | same addresses and buses | 16" vs 14" chassis; AID41 vs AID40 |
| speaker order | audio-speaker, speaker1..5 = LW1 RW1 LW2 RW2 LT RT (phandles 86/81/87/82/88) | same | slot order for the card and DSP |
| speaker-config rows | (rx, gain, vsense, isense) = (0,15,0,2) (1,15,4,6) (2,15,8,10) (3,15,12,14) (4,15,16,18) (5,15,20,22) | gain 15 | DT uses imon 4n / vmon 4n+2 (tas2764 convention) |
| amp-tx-zd-config | rows f0f0f0ff.. and 0f0f0fff.. | same | card idle masks 0xf0f0f0 / 0x0f0f0f on links 0/1, as Ed |
| amp lines | SDZ AP GPIO 107 (shared), IRQ AP 106; speaker-id 136/137 | same | fixed8 reserves them: the snippet opens 106/107/134/139 |
| jack | cs42l84 i2c2 0x4b, reset AP 139, IRQ AP 134 | same | |
| I2C | i2c1 0x505014000 IRQ 1376 pmgr 0x2c8; i2c2 ..018000 1377 0x2d0; i2c3 ..01c000 1378 0x2d8 | same | fixed8 has no i2c3 node and no I2C3 power state: the snippet adds both |
| AOP | ascwrap-v6, ASC 0x290600000 (+0x88000), SRAM 0x290c00000 (+0x2f0000), mbox IRQ 578-581; firmware `mac17jaop`, preloaded | same | |
| setup port | aop-exclave-mailbox 0x2d067c000 +0x4000, IRQ [585, 582], dart-aop mapper 1 | same | |
| dart-aop | 0x290fc0000, IRQ 616, AP SIDs 0,16,3,8,10; exclave SIDs 1,11,9; vm-base-0 0x10040000000, vm-base-1 0x20000000000 | same | |
| ADMAC base-ns | 0x293800000, IRQ 637, 13+13 ch, SID 8 | same | |
| mic | `audio-hp-mic` = leap-s-adma-rx-0 (iop-audio-s), 3 capsules (`imi1 imi2 imi3`), lpcm float32 48 kHz 12 B/frame; proxy `admac-hp-mic-ec-proxy` 0x2d3200000 +0x34000; leap-s IRQ 638, 9+9 ch, SID 11; `/product builtin-mics` = 3 | same | |

## 6. AOP firmware
The macOS restore bundle has `Firmware/AOP/aopfw-mac17jaop.RELEASE.im4p` (3.6 MB) and `AOP2/aop2fw-mac17jaop2.RELEASE.im4p`.
Linux does not load either: iBoot loads `mac17jaop` before m1n1 (J716s ADT `/arm-io/aop/iop-aop-nub`: firmware-name
`mac17jaop`, firmware-type `scrt`, `/arm-io/aop` segment-ranges filled), and `aop.rs` only starts the halted CPU. The only file
the driver can request is an ALS calibration named by an `als` child's `firmware-name`; on T6050 that step is skipped (setup
endpoints 0x20/0x23/0x32, no ALS endpoint 0x21). No im4p extraction tool is needed.

## 7. Risks found while porting
- Our macaudio and tas2764 are newer than Ed's (lease-based volume lock, speaker admission, amp levels from the DT, SDZ
  groups, deferred shutdown). None of that was exercised on T6050. Most likely trouble: the speaker link's BCLK ratio (Ed:
  macaudio's default 256 with an I2S IB_IF format; J616s here uses 250 and NB_IF) and garbage in the sense slots at stream end
  (`apple,deferred-shutdown` exists for AOP-fed amps; not set, to match Ed).
- `CONFIG_RUST=y` also turns on `APPLE_PMP` (`default y if ARCH_APPLE`); audio.config sets it off.
- `PINCTRL_APPLE_GPIO=y` binds pinctrl_ap for the first time on this kernel (previous REPORT: sync_state of its PMGR domains);
  `pd_ignore_unused` stays in the bootargs.
- Ed's mic level: speech -62 dBFS raw. Usable only through the DSP graph.
- 0003 gives every AOP (not only T6050) Rust `shmem_alloc`/`shmem_map` callbacks, as Ed's tree does: RTKit buffers are then
  allocated by aop.rs on the same device instead of by rtkit.c, and a placed-buffer request that used to fail with -EINVAL on
  T6040/T8140/T8132 would now be mapped. Only T6050 gets the placed-buffer RTKit flags.

## Sources
- edimoldovan/linux-aurora t6050-j714c @ 671fd38e1c0d (commit messages quoted above; J714c DTS at that tip).
- PRs read with read-only `gh api`: aurora-silicon/asahi-audio#20, aurora-silicon/alsa-ucm-conf-asahi#10, omacom/omarchy-mac-pkgs#94
  (head branches cloned to the session scratchpad, read only).
- aurora-silicon/linux branches (ls-remote): j813-audio-initialization-20261106, t6050/*, j716c/*.
- wt-aurora files: `drivers/soc/apple/aop.rs`, `rtkit.c`, `rust/kernel/soc/apple/rtkit.rs`, `sound/soc/apple/{aop_audio,aop_t8140,macaudio}`,
  `sound/soc/codecs/tas2764.c`, `drivers/dma/apple-admac.c`, `drivers/iommu/apple-dart.c:4204,4499`, `t6050-die0.dtsi`, `t6050-j775d.dts`.
- Ours: `contrib/pending/audio/REPORT.md`, `contrib/pending/aurora/ANALYSIS.md` (m5pro-linux); J716s ADT via m1n1.adt.
