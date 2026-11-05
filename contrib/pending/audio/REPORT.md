# Audio on M5 Pro (T6050, J716s): design report (2026-11-04, agent output, compile-checked only)
# (REPORT.md was refused by the tool permission layer; this is the same report as .txt)

Kernel base: asahi-wip-7.2 @ 236788cd2 + omarchy-m5 patches/linux/0001-0009 (the main tree's `git diff HEAD`).
DT base: omarchy-m5 j716s @ 2c87598. Nothing was run on the M5.

## Bottom line
- The speaker and jack hardware is the same as every 16-inch MacBook Pro since M1: six SN012776 (TAS2764) amps on
  i2c1 (0x38/0x39/0x3a, left) and i2c3 (0x3b/0x3c/0x3d, right), CS42L84 jack codec on i2c2 0x4b.
- The I2S side changed, and it is the blocker. The J716s ADT has no `mca` node, and every audio power domain
  (AUDIO_P, AUDIO_MCA0-5_M, AUDIO_BASE_NS_A, AUDIO_LEAP_*, PDM*_AUDIO_REF) is `no_ps` under AOP_FILTER: the AOP
  firmware owns the MCA, its clocks and its power. Streams are `iop-adma-stream,mca` children of
  `/arm-io/iop-audio-controller` (`AOPAudioService`). mca.c cannot drive this; the "I2S/NCO unchanged since M1, porting
  is mostly DT" line in docs/research/m5-pro-hardware-matrix.md is wrong for M5.
- So no speaker or headphone sound is possible yet, from any patch here. What is delivered:
  1. Stage A, bootable now: a separate DTB that binds the six amps and the jack codec on I2C. No sound card, amps held
     in hardware shutdown. Proves buses, addresses, GPIOs and jack plug detection.
  2. Two kernel safety patches for later: J716 machine config with speakers off by default and a hard volume
     ceiling while speakersafetyd holds the volume unlocked.
  3. Userspace profiles (speakersafetyd, DSP graph, UCM, udev) for stage B, deliberately conservative.
  4. A stage B plan: port Aurora Silicon's working AOP speaker/jack transport for J616s (M4 Pro 16"), which uses
     the same ADT layout.
- Built-in mics: probably impossible. On J716s the mic stream `hpai` is `iop-audio-s` on the secure ADMAC (leap-s, no
  AP DART) behind exclave service `com.apple.service.HPMicAudioDriver`. M4 Pro still used the non-secure leap-ns.
  The headset mic on the jack (`cin `, non-secure) comes with stage B.
- ALS: an AOP service like on M3. Feasible only once AOP runs under Linux (same prerequisite as stage B). Not built.

## 1. What the J716s ADT says (hardware properties only)
| Item | J716s ADT | J516 (M3, Asahi DT) | J316/J416 (M1/M2) |
|---|---|---|---|
| Left amps | i2c1 0x38 LW1 ("audio-speaker", primary), 0x39 LW2, 0x3a LT | same | same |
| Right amps | i2c3 0x3b RW1, 0x3c RW2, 0x3d RT | same | same |
| Jack codec | i2c2 0x4b cs42l84 | same | same |
| I2C controllers | 0x505014000/018000/01c000, AIC 1376/1377/1378, pmgr I2C1-3 0x2c8/0x2d0/0x2d8 (AP domain) | 0x391014000.. | - |
| Amp SDZ / IRQ | gpio0 (pinctrl_ap) 107 / 106 | AP 28 / 29 | J316 AP 178/179, J416 AP 57/58 |
| Codec reset / IRQ | AP 139 / AP 134 | nub 58 / AP 30 | nub 4/AP 180, nub 8/AP 59 |
| Speaker-ID GPIOs | AP 136, 137 (valid ids 0 and 3) | - | - |
| speaker-config | 6 entries, amp_gain 15, sense pairs 0/2 4/6 8/10 12/14 16/18 20/22 | gain 15 | gain 15 |
| amp-tx-zd-config | 0xfff0f0f0, 0xff0f0f0f (bus-keeper masks) | 0xf0f0f0/0x0f0f0f in DT | same |
| Acoustic ID | 41 | 29 | 9 / 15 |
| speaker-thiele-small | spA0-spA5, Re 3.29-3.39 ohm (calibration) | - | - |
| I2S | AOP-owned, no MCA node, no AP power domain | mca@393400000 + admac (sio DART) | mca + admac |
| Speaker stream | 'spkr': TX base-ns tx0 6 ch 32 bit <=48 kHz, sense RX base-ns rx0 12 ch 16 bit; 12 MHz, 250 bit/frame | MCA 0+1 | MCA 0+1 |
| Jack stream | 'cout' TX base-ns tx2 2 ch 32 bit <=96 kHz; 'cin ' RX base-ns rx2 1 ch | MCA 2 | MCA 2 |
| ADMAC | base-ns 0x293800000/0x34000 IRQ 637, DART dart-aop SID 8; leap-ns 0x293300000 IRQ 639; leap-s 0x293200000 IRQ 638 no AP DART | admac 24 ch | admac |
| dart-aop | 0x290fc0000/0xc000 IRQ 616, AP SIDs 0,16,3,8,10; exclave SIDs 1,11,9 | aop_dart | - |
| Built-in mics | 'hpai' iop-audio-s, leap-s rx0, exclave HPMicAudioDriver; `supports-secure-microphone = 1` | AOP 'hpai' via aop_admac (works) | AOP/PDM |
| AOP | ascwrap-v6, reg 0x290600000/0x88000 + 0x290c00000/0x2f0000 SRAM, IRQ 578-581, plus aop-exclave-mailbox | t6031 aop | - |

- The base-ns ADMAC channel register layout is not apple-admac's: ADT channel regs put TX n at 0x8000 + n*0x200 and
  RX n at 0xc000 + n*0x200 (apple-admac interleaves them at 0x8000 + ch*0x200); descriptor/report ports match.
  Aurora Silicon measured the same on T8140 and T8132 and added `evolved_layout` to apple-admac.
- M4: the in-tree t8132 DTs have no audio. The Omarchy-M4-Native T8132 gap analysis reports the same architecture on
  J713 ("No MCA-style I2S controller exists ... BLOCKED ON DRIVER WORK"). Aurora Silicon's linux
  (`integration/aurora`) runs J616s (T6040) speakers and jack on it: `sound/soc/apple/aop_spkr.rs`, a J616 macaudio
  variant, `apple,t8132-admac` with the evolved layout, its own j616 speakersafetyd profile.
- Note: the brief's "J616 (M3 16-inch)" is the M4 Pro/Max 16-inch; the in-tree M3 16-inch is J516 (t6030/t6031).

## 2. Deliverables (this folder)
| File | Applies to | What |
|---|---|---|
| patches/linux/0030-ASoC-apple-macaudio-add-J716-speakers-off.patch | kernel base | `apple,j716-macaudio`: SN012776, 2W+1T, enable_speakers=false, amp gain limit 10 (16 dBV; ADT/J516 use 15), safe_vol -20 |
| patches/linux/0031-ASoC-apple-macaudio-per-machine-speaker-volume-ceiling.patch | base + 0030 | `max_vol` per machine (J716 -30 dB) applied while speakersafetyd holds the volume unlocked, plus `snd_soc_macaudio.speaker_max_db` (can only lower it). Other machines unchanged |
| patches/omarchy-m5/0001-j716s-audio-stage-A-DTB-amps-and-jack-codec-on-I2C.patch | omarchy-m5 j716s | new `dt/t6050-j716s-audio.dts` (separate DTB), `dt/t6050-audio.dtsi` (architecture notes + stage B skeleton under `#ifdef T6050_AUDIO_STAGE_B`), `configs/omarchy-audio.config`, build-kernel.sh wiring |
| build/t6050-j716s-audio.dtb | - | stage A DTB, sha256 f3548a9176c95cd9f460c24ab510d9b6f22cbd9a432ffe9292ea54af6f745912 |
| userspace/ | Arch root, stage B | speakersafetyd `apple/j716.conf`, udev rule, asahi-audio `j716/graph.json` + WirePlumber fragment, UCM `MacBook Pro J716.conf`, README.md with install paths |
| TEST-PLAN.txt | - | staged plan with safety gates and rollback |

Stage A DTB vs t6050-j716s.dtb (sha256 d4364f78..., unchanged): model string, i2c1/2/3 `okay`, the seven codec nodes.
Nothing else. The i2c1-3 controller nodes already exist in t6050.dtsi and match the ADT; no pinctrl-0 added (iBoot
muxes the pins for the boot chime; the T6050 pin function number is unconfirmed).

Config (omarchy-audio.config): PINCTRL_APPLE_GPIO, I2C_APPLE, SOUND, SND, SND_SOC, SND_SOC_TAS2764, SND_SOC_CS42L84,
SND_SOC_APPLE_MACAUDIO, DYNAMIC_DEBUG, DEBUG_FS, GPIO_CDEV all =y. Warning: PINCTRL_APPLE_GPIO is =m today, so no Apple
pinctrl driver is bound on the M5 (diag dmesg: "sync_state() pending due to 29c000000.pinctrl"). Building it in binds
pinctrl_ap/aop/nub and lets those PMGR domains reach sync_state; omarchy 0004 keeps pd_ignore_unused honoured. That is
the main boot risk of stage A, not the audio nodes.

Compile verification (worktree /Volumes/linux-cs/wt-audio, LLVM=1, -j8): sound/soc/apple/ (macaudio.o, mca.o),
tas2764.o, cs42l84.o build W=1 with no warnings; t6050-j716s.dtb, t6050-j716s-audio.dtb, t6050-j714s.dtb build W=1
clean; the stage B skeleton compiles warning-free with -DT6050_AUDIO_STAGE_B. 0030 passes `git apply --check` on the
main tree; 0031 on base+0030; the omarchy patch on ~/Work/omarchy-m5. No dtbs_check (no dt-schema here). Remove the
worktree with `git -C /Volumes/linux-cs/linux worktree remove --force /Volumes/linux-cs/wt-audio`. I briefly made a
local commit in that detached worktree and reset it at once (an unreferenced object remains until gc; no branch).

## 3. Speaker safety
Kernel gates, in order (all must be passed deliberately):
1. No CPU DAI for T6050 exists, so no card, so the amps are never powered: tas2764 requests the shared SDZ line
   (AP 107) output-low at I2C probe and only raises it from the ASoC component probe. That is safer than today, where
   no driver touches SDZ after iBoot's chime.
2. 0030: J716 speakers are not in the card unless `snd_soc_macaudio.please_blow_up_my_speakers=1`. The DT
   compatible is `apple,j716-macaudio`, `apple,macaudio` only: a kernel without 0030 falls back to jack-only, never
   to the J316 profile.
3. Existing macaudio interlock: without speakersafetyd the speaker volumes are clamped to raw 1 (-100 dB); the daemon
   must hold the lock and ping every 250 ms or they clamp again.
4. 0031: while unlocked, J716 is capped at -30 dB (can be lowered at boot with `speaker_max_db`).
5. Amp gain limited to 10 (16 dBV) instead of 15.
6. DSP graph: -10 dB max volume, 4th-order high-pass (woofers 180 Hz, tweeters 2 kHz), -12 dBFS limiters.

speakersafetyd `j716.conf`, numbers and where they come from:
| Value | Source | Safe? |
|---|---|---|
| is_scale 3.75, vs_scale 14, z_shunt 0.09 | j316.conf (amp sense ADC full scale) | yes: same amp |
| a_t_20c/a_t_35c | j316.conf (voice-coil copper tempco) | yes: material constant |
| visense_pcm 2, channels 12, period 4096, link_gains, uclamp_max 64, t_window 20, t_hysteresis 5, t_ambient 50 | j316.conf | yes: same driver/card layout |
| z_nominal 3.60 | j316.conf | close: ADT calibration Re 3.29-3.39 ohm; used for logging and min_gain |
| tau_coil/tau_magnet (5.60/197.25 woofers, 1.3/73.26 tweeters) | j316.conf | UNKNOWN for AID41; kept, compensated below |
| tr_coil/tr_magnet x1.25 (woofers 28.75/50, tweeters 56.25/62.5) | j316.conf x1.25 | conservative: model predicts 25% more heating per watt |
| t_limit 120 (j316 140) | lowered | conservative: reduction starts at 100 C |
| channel map LW1 0/1, RW1 2/3, LW2 4/5, RW2 6/7, LT 8/9, RT 10/11 | ADT speaker-config order, = Aurora j616.conf (tested amp by amp on J616s) | must match DT slots; TEST-PLAN B3 re-checks per amp |

Why this is not a validated profile: the thermal constants describe J316 drivers. Aurora kept them unchanged for J616
because its drivers are in the J316 tuning family; nothing says AID41 is. The derating, lower t_limit, gain 10 and the
-30 dB ceiling keep real power far below the model's limits, but excursion (bass) is not modelled by speakersafetyd at
all, hence the high-pass in the graph and no FIR/bass enhancement. Raising any cap needs measured AID41 data.
(Model floor with these values at 16 dBV: woofers max 0.89 W steady, min_gain -14 dB; the shipped service's `-m 7`
makes the daemon panic, and the kernel relock the volume, if it ever needs more than 7 dB of reduction.)

asahi-audio: no J716 FIRs exist (they are measured per chassis); reusing J316's EQ could boost bass on unknown drivers,
so `j716/graph.json` is a protective graph, not a tuning. Output order LW1 RW1 LW2 RW2 LT RT (ADT order). UCM: same as
J516 (`laptops/HiFi.conf`, cs42l84 Headphones). Card id `AppleJ716`; speakersafetyd derives `apple/j716.conf` and
`hw:AppleJ716` from compatible `apple,j716s`. Upstream udev rules lack J716; `96-speakersafetyd-j716.rules` adds it.

## 4. Mics and ALS
- Built-in mics: secure path on M5 (see section 1). A non-secure route would need the AOP to stream `hpai` over
  leap-ns, which the ADT does not offer for this stream (leap-ns carries only `audio-leap-internal-loopback`).
  Treat as not feasible until someone shows leap-s is reachable without exclaves.
- Headset mic: `cin ` on base-ns rx2, non-secure; comes with the stage B jack card.
- ALS: `/arm-io/aop/iop-aop-nub/als` (harmony-db-version 3). Needs AOP RTKit/EPIC under Linux (drivers/soc/apple/aop.rs
  and aop_als.rs, both Rust; omarchy builds with CONFIG_RUST off). T6050 also has `aop-exclave-mailbox` and
  `aop-exclave-ioreporting`; whether an AP RTKit session coexists with them is unknown. Report only.

## 5. Stage B (what has to be written next)
1. CONFIG_RUST on (bindgen on the macOS host), aop.rs for T6050 (`iop,ascwrap-v6`; mailbox, dart-aop SID 0, regions
   above). Prove AOP comes up and the `aop-audio` service announces before anything audio.
2. apple-admac: Aurora's `evolved_layout` (TX bank 0x8000, RX bank 0xc000), base-ns 13+13 channels, DART SID 8.
3. Port Aurora's `aop_spkr.rs` (attach 'spkr'/'cout'/'cin ', power states `pw1 `/`pwrd` via property 202, serializer
   restart per prepare) and the J616 macaudio variant (I2S NB_IF, 250-bit frame at 12 MHz, jack as its own card) as a
   J716 entry that keeps enable_speakers=false, amp gain 10 and max_vol -30 (fold 0030/0031 into it).
4. DT: replace the `#ifdef T6050_AUDIO_STAGE_B` skeleton with the real nodes (aop, aop_mbox, aop_dart, admac
   base-ns, aop_audio with dmas spkr/sense/cout/cin; codec order LW1 RW1 LW2 RW2 LT RT as already used for the slots).
Risks: AOP exclave coexistence; Aurora still reports an intermittent I2C STOP timeout during amp shutdown on J616s;
the ADMAC sample-width field for sense is zero in the ADT (format must be confirmed by capture).

## 6. Conflicts with pending work
- USB agent's omarchy patch edits the same build-kernel.sh install list and DTB block: keep both file lists and both
  DTB lines.
- SMC agent (t6050-smc.dtsi SPMI reg, `&smc_hwmon` in t6050-j716s.dts) and trackpad agent (`smc_gpio_low` in
  t6050-smc.dtsi): no textual overlap; the audio DTB includes t6050-j716s.dts and inherits their changes.
- Kernel patches 0030/0031 touch only sound/soc/apple/macaudio.c; no other pending patch does.

## 7. Verified / inferred / guessed
- Verified (ADT): every address, IRQ, I2C address, GPIO number, stream FourCC, DMA channel, DART SID, power-domain
  ownership and acoustic ID above. Verified (compile): as in section 2.
- Inferred: GPIO polarities and IRQ types (copied from J516; the ADT flag words have the same shape); that the amps
  do not answer I2C while SDZ is low (datasheet behaviour); sense-slot order (ADT order, as Aurora on J616s).
- Guessed / unknown: AID41 speaker thermal parameters; whether AOP can be driven from Linux with exclaves active.

## Sources
- ADT: ~/Work/studio-artifacts/adt-runtime-j716s.bin (private; only hardware properties quoted).
- Aurora Silicon linux, integration/aurora: https://github.com/aurora-silicon/linux (sound/soc/apple/aop_spkr.rs,
  drivers/dma/apple-admac.c, arch/arm64/boot/dts/apple/t604x-j614-j616.dtsi); speakerguardd:
  https://github.com/aurora-silicon/speakerguardd ; J616 profile:
  https://github.com/aurora-silicon/alarm-aurora/blob/main/packages/speakersafetyd-aurora-profiles/j616.conf ;
  asahi-audio clone notes: https://github.com/aurora-silicon/asahi-audio/blob/HEAD/README.J616s.md
- T8132 gap analysis: https://github.com/Kb2uka/Omarchy-M4-Native/blob/develop/docs/t8132-gap-analysis.md
- speakersafetyd: https://github.com/AsahiLinux/speakersafetyd ; asahi-audio: https://github.com/AsahiLinux/asahi-audio ;
  alsa-ucm-conf-asahi: https://github.com/AsahiLinux/alsa-ucm-conf-asahi
- Asahi docs, speakers: https://asahilinux.org/docs/sw/audio-userspace/ ; M3 announcement:
  https://asahilinux.org/2026/09/m2-episode-1/ ; M4 difficulty:
  https://www.linux-magazine.com/Online/News/Asahi-Linux-Runs-into-Issues-with-M4-Support
- macOS kext symbol list for future RE: https://github.com/blacktop/symbolicator/blob/main/kernel/27.2/kexts/AOPAudio2.json
- Not found: any public omarchy-m5 (betizzel) audio work, or any public M5 audio driver.
