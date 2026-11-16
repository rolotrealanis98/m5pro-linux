# J716s speakers: speakerguardd v2 instead of speakersafetyd

Design change, 2026-11-15. Nothing here has run on the MacBook: no package built, no tuning collected, no speaker played.
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
| `install.sh` | installs the two drop-ins above and `sgv2-telemetry` into `/usr/local/bin`, enables the boot unit |
| `sgv2-telemetry.py` | read-only decoder of the engine page (coil and magnet temperatures, power, V/I mean squares, gain) |
| `../ucm/j716/HiFi.conf` | installed by `../install.sh`; offers no Speaker device while `/run/speakerguardd-graph/speakerguardd-owns-speakers` exists |
| `../j716-profile/j716-audio-ab v2` | removes `99-asahi-j716.conf`: v2 builds its own voicing and owns `hw:AppleJ716,1`, so the staged J616s-derived graph (bring-up or profile) must not also filter that PCM |

`contrib/distro/pkg/speakerguardd-v2` and `pkg/aurora-speaker-upgrade` build the two packages; `lzfse` (alarm-aurora
`packages/lzfse`) is needed to read LZFSE-compressed System files.

## The kernel ceiling, the fixed ceiling and no V/I sense

Read in aurora-silicon/linux `integration/aurora` `sound/soc/apple/macaudio.c` (the tree `j716s-next` is rebased on) and
in `contrib/validated/aurora/series/patches/0067` and `0077`. Not run.

- **Our -30 dB is the legacy interface's ceiling.** The J716 entry has `safe_vol = -30` and `max_vol = -30` (0077); `max_vol`
  (0067) is applied only in `macaudio_vlimit_unlock()`, i.e. under "Speaker Volume Unlock" (speakersafetyd's interface).
- **Under v2 it does not apply.** The dual-interface kernel hands the speakers to "Speaker Protection" (a lease). There
  the volume controls are the driver's and hold the amps at a fixed operating gain, `macaudio_spk_gain()` = 0 dB for a
  granted lease; all attenuation is the engine's. So switching to v2 removes the kernel's -30 dB from the path: the
  limit becomes v2's engine and its V/I sense, nothing else. Without a grant the kernel's floor holds.
- **8360c9788f29 (`spk_fixed_ceiling`)** is for a machine whose sense never reaches the AP: its SN012776 volumes are limited to
  `safe_vol` in every state, a grant runs the amps at `safe_vol`, and it gets no sense PCM. It is in `integration/aurora`.
  v2 needs the sense PCM (twelve captured channels in the self-check), so on such a machine v2 never qualifies and the
  kernel ceiling alone holds. It is a ceiling-only mode, not a ceiling under v2; there is no upstream mode that combines a
  kernel ceiling with a running v2.
- **J716s has sense** (the AOP sense PCM; the daemon read about 4x the electrical power, `j716.conf.aid41` header), so it
  must not set `spk_fixed_ceiling` while v2 is the plan. Keep it as the fallback: if the sense offset cannot be settled,
  port 8360c9788f29, set `.spk_fixed_ceiling = true` on the J716 entry (replaces 0067's `max_vol`), and the speakers play
  at `-30 dB` with no daemon.
- A 4x over-read errs on the safe side (the model heats faster than the coil), but it must be understood before the first
  grant, because v2's protection is only as good as that sense.

## Will it qualify? (the likely stops)

1. **macOS build.** `parity.json` attests 25C56, 25G72, 25G83 and 26A428 only; this Mac is on 27.3. v2 then qualifies only
   if the Mac's AID speaker files equal 25G83's (`reference.rs`). AID41 is in 25G83's reference table
   (`reference-25G83.json` has AID41), and our README says AID41's tuning is byte-identical to AID35 and AID29, so it may
   pass; not checked against the MacBook's System volume. A refusal is the expected safe outcome.
2. **Speaker ID.** From `/chosen/asahi,speaker-id` or the installer bundle. Nothing in our m1n1 patches or J716s DT sets
   it (searched `patches/`, `contrib/distro`, `contrib/pending/*/patches`); the J716's ADT valid ids are 0 and 3 (`pending/audio/TEST-PLAN.md`). If missing, the tool
   refuses and points at the macOS collection (`aurora-installer` `tools/speaker-tuning/collect-macos.sh`, run by the
   owner on the Mac's own macOS).
3. **ADT.** The tool wants the `adt` MTD partition; on our kernel the ADT is a `phram` region (`modprobe phram`, then
   `/dev/mtd1`, `validated/integration/RESULTS.md`). Pass `--adt FILE` (a `dd` of it) if the tool does not find it.
4. **PipeWire.** Stock PipeWire lacks Aurora's PipeWire patches (1006, 1007, 1008, 1010 in omarchy-m5's note): a repeated volume update can attenuate twice (quieter,
   not louder); a speaker sink that tried to start before the grant can stay unable to start until PipeWire restarts
   (silence, not an unprotected path).
5. **Short lsm2 presets** need the live macOS parameter readback (`lsm2-param-fill.bin`); only the macOS collection makes it.

## Test order

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
