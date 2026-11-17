# J716s speakers: speakerguardd v2 instead of speakersafetyd

Design change, 2026-11-15; updated 2026-11-16. Nothing here has run on the MacBook: no tuning collected, no speaker played. The three
packages (`lzfse`, `speakerguardd-v2`, `aurora-speaker-upgrade`) were built with `makepkg` in an Arch Linux ARM container on the
Mac Studio, their `check()` suites passed (cargo 234+36 tests, python 37), nothing was installed anywhere.
The speakersafetyd profile in `../j716-profile/` stays in the tree (it is the record of the AID41 numbers) but is no
longer the path: speakersafetyd is held off on this machine (it panics at `main.rs:298`, an `.unwrap()` on a `readi`
error other than ESTRPIPE).

## Pins

| What | Source | Pin |
|---|---|---|
| speakerguardd 1.0 (branch `v2`) | aurora-silicon/speakerguardd | `04169c4470650f8e2554db70d4072fb92e484138` (PR #175 merge, 2026-11-13); contains #158 `apple,t6050-aop-audio` in `wiring.py`; tarball sha256 `c6d8b07251eb34f42d97fee293ff87a1da3fc765d1e42c7af8786ee22ae27e88` |
| recipes `speakerguardd-v2`, `aurora-speaker-upgrade` | aurora-silicon/alarm-aurora `packages/` | `282881f37c86` (main is `27109d22`); copies in `contrib/distro/pkg/` |
| depends change (no `pipewire-speaker-graph`, no `aurora-audio`), boot-time switch unit, wait for the card, telemetry decoder | betizzel/omarchy-m5 (MIT) | `installer/recipes/speakerguardd-v2-upstream` and `omarchy-aurora-firmware` (`70-aurora-speaker-upgrade-auto.conf` `101a6e6c4fa1`, j714s12), `sgv2-telemetry.py` `1b9d5ef99def`, `speakersafetyd-hold.conf` `6b316fe76f41`; repo main `18e7d51` |
| UCM v2 condition | aurora-silicon/alsa-ucm-conf-asahi | `96b3206` `laptops/HiFi.conf` |

## What v2 derives itself

Channel map, V/I slot order, card, amp count, PipeWire/WirePlumber graph and voicing come from the live device tree, this
Mac's own macOS tuning and a silent self-check; there is no per-board file (`docs/NEW-PLATFORM.md` in the source). So no
J716 file is gathered or edited. The tuning is read per machine (macOS System volume read only, or Apple's restore image,
or a collection made on the Mac) and stays under `/var/lib/aurora-speaker-upgrade/bundle`; nothing from Apple is packaged.

`gate.json` and `parity.json` are upstream's and must not be edited. `speakerguardd-gate explain` must name exactly one
stack, or none.

## Files

| file | install as |
|---|---|
| `70-j716-speaker-upgrade-auto.conf` | `/usr/lib/systemd/system/aurora-speaker-upgrade.service.d/70-m5pro-j716s-auto.conf`, and enable `aurora-speaker-upgrade.service`: the switch runs at boot, after waiting up to 60 s for `/proc/asound/AppleJ716` (without the wait, the J714s image's unit ran 0.2 s before the card and left the speakers at the floor) |
| `speakersafetyd-hold.conf` | `/usr/lib/systemd/system/speakersafetyd.service.d/50-m5pro-j716-hold.conf`: speakersafetyd never starts on `apple,j716*`. Needed beside v2's own gate, which starts it on a dual-interface kernel whenever the Mac is not switched to v2 |
| `install.sh` | installs the two drop-ins above and `sgv2-telemetry` into `/usr/local/bin`, enables the boot unit (`SGV2_NO_ENABLE=1`: not) |
| `sgv2-silent-check.sh` | the silent bring-up: `pre`, `install DIR`, `check`, `switch`, `verify`, `undo` (reads only, nothing audible; see the header) |
| `sgv2-telemetry.py` | read-only decoder of the engine page: header (health bits, sense proof and binding, amps word, delay estimator), per channel modeled power, coil temperatures, gain, the spp3 pilot-bin V/I powers and closed-loop state; `--watch SECONDS` prints `RESULT` verdicts for a listening test (rewritten 2026-11-17, speakers-5: the upstream decoder printed microwatts as 0.0000 W and lsm2-only meters as NaN) |
| `../ucm/j716/HiFi.conf` | installed by `../install.sh`; offers no Speaker device while `/run/speakerguardd-graph/speakerguardd-owns-speakers` exists |
| `../j716-profile/j716-audio-ab v2` | removes `99-asahi-j716.conf`: v2 builds its own voicing and owns `hw:AppleJ716,1`, so the staged J616s-derived graph (bring-up or profile) must not also filter that PCM |

`contrib/distro/pkg/speakerguardd-v2` and `pkg/aurora-speaker-upgrade` build the two packages; `lzfse` (alarm-aurora
`packages/lzfse`) is needed to read LZFSE-compressed System files.

## The kernel ceiling under v2, the fixed ceiling and no V/I sense

Corrected 2026-11-16 after reading `sound/soc/apple/macaudio.c` of `j716s-next2` (the first version of this section said the
-30 dB does not apply under v2; it does).

- **The J716 entry has `safe_vol = -30` and `max_vol = -30`.** `macaudio_max_vol()` is the lower of `max_vol` and the
  `snd_soc_macaudio.speaker_max_db` module parameter (0444: boot command line only).
- **Under the lease the ceiling is the operating gain.** `macaudio_spk_enter_lease()` calls `macaudio_vlimit_unlock(ma, true)`,
  which limits every SN012776 "Speaker Volume" to `SN012776_DB(macaudio_max_vol())`; a grant sets every amp's volume to
  `macaudio_spk_gain(ma, true)` = the same value (raw 141 = -30 dB; 0 dB is raw 201, 0.5 dB a step); the userspace volume controls
  are read-only for userspace while leased. So v2 runs the amps at -30 dB digital with the analog "Amp Gain Volume" fixed at its
  limit (the ADT level, 15 = 18.5 dBV as macOS runs it), and all further attenuation is the engine's. The kernel -30 dB is
  therefore in the path under v2 exactly as under the legacy lock. This matches omarchy-m5's J714s (speakers heard at 30 % with a
  -30 dB cap).
- **A real hole, fixed on kernel branch `speakers`** (`contrib/pending/speakers/patches/`): `macaudio_spk_ramp_down()` walks
  absolute steps -2, -4, -6 ... -50 dB under a still-playing stream when the owner releases, vanishes or is replaced. Only a
  `spk_fixed_ceiling` machine skipped the steps at or above its operating gain, so on the J716 a release ran the amps up to
  -2 dB (28 dB over the ceiling) for a few tens of ms. The patch skips every step at or above the operating gain, whichever way
  the machine holds it. The silent test cannot show the ramp (it needs a playing stream); the morning test must keep the stop
  commands in `MORNING.md`, which the fix makes safe, and the kernel without the fix must not be used for the first sound.
- **`spk_fixed_ceiling` (8360c9788f29) is not usable with v2.** `macaudio.c` does not set `has_sense` for a fixed-ceiling machine
  (no sense PCM), and v2 needs the 12-channel sense PCM. It is the fallback if the sense cannot be trusted: set it on the J716
  entry and the speakers play at -30 dB with no daemon.
- **J716s has sense** (the AOP sense PCM, S16_LE on the T6050 transport entry of `wiring.py`). The legacy daemon read about 4x the
  electrical power (`j716.conf.aid41` header): V and I each about 2x, as from a one-bit slot offset. A 4x over-read errs on the
  safe side (the model heats faster than the coil), but it is unresolved and cannot be measured silently; the morning test
  records v2's telemetry for a known tone (`MORNING.md`, step 6).
- **Amp operating point.** v2's supervisor grants only while every amp's "Amp Gain Volume" reads back the tuning's own full
  scale (one 0.5 dB step either way refuses). macOS runs level 15; the DT held 10 (16 dBV) from the bring-up. Branch `speakers`
  sets the DT's six `apple,speaker-config` rows to the ADT's `0f` (the loader writes the same values when it copies the ADT's
  group). Net effect against the old bring-up: the analog stage is 2.5 dB hotter, the -30 dB digital ceiling unchanged.

## Will it qualify? (the likely stops)

1. **macOS build.** `parity.json` attests 25C56, 25G72, 25G83 and 26A428 only; this Mac is on 27.3. v2 then qualifies only
   if the Mac's AID speaker files equal 25G83's (`reference.rs`). AID41 is in 25G83's reference table
   (`reference-25G83.json` has AID41), and our README says AID41's tuning is byte-identical to AID35 and AID29, so it may
   pass; not checked against the MacBook's System volume. A refusal is the expected safe outcome.
2. **Speaker ID.** From `/chosen/asahi,speaker-id` or the installer bundle. The aura loader exports it
   (`/Volumes/m5pro/aura` `src/kboot_audio.c` `kboot_audio_speaker_id()`, called from `kboot.c` for every chip but the T8152): it
   reads the ADT's two strap pins (`function-speaker-id0/1`, AP GPIO 136 and 137 on the J716s ADT, `find-speaker-id` = 1) and
   writes one u32, or 65535 when the strap value is not in `valid-speaker-ids` (0 and 3 here). It has never been seen on this
   machine: `sgv2-silent-check.sh pre` reads it. (The first version of this README said nothing sets it; the loader does, our
   DT does not need to.) If it reads 65535 or is missing, the tool refuses and points at the macOS collection (`aurora-installer` `tools/speaker-tuning/collect-macos.sh`, run by the
   owner on the Mac's own macOS).
3. **ADT.** The tool wants the `adt` MTD partition; on our kernel the ADT is a `phram` region (`/dev/mtd1`,
   `validated/integration/RESULTS.md`; `CONFIG_MTD_PHRAM=y` in the `speakers` kernel's config, so no modprobe is needed).
   `sgv2-silent-check.sh pre` checks `/proc/mtd`. Pass `--adt FILE` (a `dd` of it) if the tool does not find it.
   The Linux device tree must also carry the root `serial-number` (the loader's `dt_set_serial_number`): the tool refuses when
   the ADT and the device tree name different units.
4. **PipeWire.** Stock PipeWire lacks Aurora's PipeWire patches (1006, 1007, 1008, 1010 in omarchy-m5's note): a repeated volume update can attenuate twice (quieter,
   not louder); a speaker sink that tried to start before the grant can stay unable to start until PipeWire restarts
   (silence, not an unprotected path).
5. **Short lsm2 presets** need the live macOS parameter readback (`lsm2-param-fill.bin`); only the macOS collection makes it.
   (AID41 is spp3, so this should not apply.)
6. **`/etc/speakerguardd` mode (speakerguardd#186, open).** The switch creates it 0700 under umask 077 and the seat user's session
   then links no graph (silent speakers on every later boot). The boot drop-in creates it 0755 first and chmods it after;
   `sgv2-silent-check.sh switch` does the same.
7. **LZFSE.** The tool reads LZFSE-compressed System files through `liblzfse`; Arch Linux ARM has no package. The recipe is
   `contrib/distro/pkg/aurora-speaker-upgrade/lzfse/PKGBUILD` (a copy of alarm-aurora's, built and its round-trip check run).

Checked offline 2026-11-16 (not on the machine): v2's own device-tree derivation (`wiring.read_dtb`, `hardware`, `describe`) run on
`kbuild-next2/t6050-j716s-next.dtb` gives six amps in ADT order (LW1 RW1 LW2 RW2 LT RT), slots 0-5, V/I sense channels 2n/2n+1,
transport `aop-dma` (`apple,t6050-aop-audio`), card `AppleJ716`, key `j716`, plugin `6ch-vi`, S24_LE playback, 12 sense channels:
no refusal from the DT side. What this does not cover: the macOS tuning (parity on 27.3), the switch test and the live sense.

## Test order

Steps 1-4 are `sgv2-silent-check.sh pre|install|check|switch|verify` (request `/Volumes/m5pro/bench/requests/speakers-1.md`); step 5 is the owner's, `contrib/pending/speakers/MORNING.md`.

On the dev Linux, not the image. Adapted from omarchy-m5's J714s protocol; `LISTENING-TEST.md` (parent of `j716-profile/`)
has the stop rules.

1. Read only: `uname -r`, `amixer -c AppleJ716 cget name='Speaker Protection Interface'` (the control must exist),
   `/proc/device-tree/chosen`, `/proc/mtd`.
2. Install both packages. `speakerguardd-gate explain` must say legacy or none with speakersafetyd held (nothing runs).
3. `aurora-speaker-upgrade --check --json /root/sgv2-check.json --device <the System volume's partition>`: collects,
   compiles and self-checks in `/run`, stores and switches nothing. Record which macOS build was read.
4. `j716-audio-ab v2`, `aurora-speaker-upgrade run`, then `speakerguardd-gate explain` and
   `systemctl status speakerguardd-v2`; log in as the seat user so the switch test and the graph run.
5. Before any sample: v2 owns "Speaker Protection", the voicing sink is at 5 % (the first start defaults to 30 %), nothing
   else plays, no amp fault latch. Then a 2 s pink burst or 1 kHz at 5 %, then 10 %, with `sgv2-telemetry.py` and the
   kernel log running. Stop on a fault, a NaN, a temperature rising without bound, or a grant with the sense not moving.

Undo: `systemctl disable aurora-speaker-upgrade; aurora-speaker-upgrade --revert; pacman -R speakerguardd-v2`, then
`j716-audio-ab bringup` for the old graph. The kernel returns to "Speaker Volume Unlock" and its -30 dB ceiling; with
speakersafetyd held off (`speakersafetyd-hold.conf`) the speakers then stay at the kernel's floor.
