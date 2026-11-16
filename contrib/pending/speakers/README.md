# speakers (2026-11-16): J716s speakers ready for a listening test

Area `speakers`. Nothing here has run on the MacBook. "Built" = built; "read" = source read; "derived offline" = run on the Mac
Studio against the compiled device tree. Nothing was played.

## What speakerguardd v2 needs on the J716s (source read at pin 04169c44)

| Need | Where v2 reads it | Status on the J716s |
|---|---|---|
| Machine description (amps, sense, transport, card, key) | the live device tree, `packaging/session/wiring.py` (`hardware`, `describe`) | derived offline from `t6050-j716s-next.dtb`: six amps in ADT order, slots 0-5, V/I sense channels 2n/2n+1, transport `apple,t6050-aop-audio` (= the T8142 entry: S24_LE playback, S16_LE sense, 12 sense channels), card `AppleJ716`, key `j716`, plugin `6ch-vi`. No refusal from the DT |
| Speaker ID (picks the tuning strip) | `/chosen/asahi,speaker-id` (one u32), else the installer bundle | exported by the aura loader (`kboot_audio_speaker_id`, strap pins GPIO 136/137, valid ids 0 and 3). Not yet seen on this machine: `sgv2-silent-check.sh pre` |
| Unit identity | root `serial-number` of the DT (loader copies it) must equal the ADT's | to be confirmed on the machine (`pre`, `check`) |
| ADT (acoustic-id 41, speaker-thiele-small, target-type) | the `adt` MTD partition (phram) or `--adt FILE` | `CONFIG_MTD_PHRAM=y` (built in); `pre` checks `/proc/mtd` |
| Tuning (macOS `AID41` Tunings, AudioDSP) | read per machine from the macOS System volume (APFS, read only), or the IPSW, or the owner's collection; never packaged | our firmware extraction does NOT provide it (it is separate by design); the machine's own System volume is read by `aurora-speaker-upgrade --check`, needs `lzfse` |
| Amp operating point | amps' "Amp Gain Volume" readback = the blob's full scale (macOS: level 15, 18.5 dBV); one 0.5 dB step off refuses | DT held level 10: fixed on branch `speakers` (see below) |
| Kernel interface | "Speaker Protection Interface" with item "Speaker Protection" | seen on the 2026-11-15 boot per the handoff; `pre` re-reads |
| macOS build gate | `reference.rs`: a build whose AID41 files equal 25G83's counts as 25G83 and uses its `parity.json` block; otherwise needs its own build's block (none for 27.3) | AID41 is in `reference-25G83.json`; whether the 27.3 files are byte-identical is only knowable on the machine: `check` reports it (a refusal is the safe outcome, nothing to force) |
| Gain bound | engine (spp3 thermal closed loop on V/I sense, fail-safe attenuation on bad sense or parameters) plus the kernel: lease renewed 50 ms only while a stream plays and the graph is exact; amps at "Amp Gain Volume" max with digital volume at the machine's `max_vol` | see the ceiling finding |

## Findings that change the earlier picture

1. **The kernel's -30 dB does apply under v2** (the earlier README said it did not). `macaudio_vlimit_unlock(unlock=true)` limits
   the amps' "Speaker Volume" to `SN012776_DB(max_vol)` and a grant sets them to `macaudio_spk_gain()`, both -30 dB (raw 141) on
   the J716. `sgv2-silent-check.sh` reads the amps' maxima and values (before, during the self-check's own grant, and after) and
   fails above raw 141.
2. **Real hole, fixed:** the lease's ramp-down (`macaudio_spk_ramp_down`) used absolute steps from -2 dB. Only
   `spk_fixed_ceiling` machines skipped steps above their operating gain, so a release, an owner exit or an owner replacement
   under a playing stream ran the J716's amps up to -2 dB (28 dB over the ceiling) for tens of milliseconds. Patch 0001. This is why
   the morning test must not use a kernel without it. The silent test cannot exercise it (no playing stream).
3. **Operating point:** DT level 10 vs macOS 15 would make the v2 supervisor refuse every grant. Patch 0002 sets the six rows to the
   ADT's `0f`. The loader's `kboot_audio_amp_config()` copies the ADT's `speaker-config` rows over the DT's, so the live level may already have been 15 on a boot with that loader; `pre` prints the live bytes per amp. This is +2.5 dB on the analog stage against the bring-up, ceiling unchanged; it is the
   one change that raises output and it is a separate commit so it can be dropped (v2 then refuses and the speakers stay silent).
4. **speakerguardd#186** (open): the switch makes `/etc/speakerguardd` 0700 and the seat user gets no graph. The boot drop-in
   and the check script create it 0755 first and chmod after.
5. **`spk_fixed_ceiling` cannot be combined with v2** (macaudio does not create the sense PCM for it). Fallback only.
6. #177 (S16_LE sense) and #178 (k114.conf) are for the legacy `speakerguardd` 0.1 daemon, not v2; v2 takes the sense format from
   `wiring.py` (T6050 = S16_LE). Not needed. #158 (T6050 transport) is in the pin.
7. **4x sense over-read**: unresolved, cannot be measured silently. It errs safe (the model heats faster than the coil); the morning
   procedure records v2's telemetry for a known tone.
8. **Arch Linux ARM has no `lzfse`**; the recipe is `contrib/distro/pkg/aurora-speaker-upgrade/lzfse/PKGBUILD`.

## What changed

Kernel branch `speakers` in `/Volumes/m5pro/linux` (worktree `/Volumes/m5pro/wt/speakers`), from `j716s-next2` (`e4fc1f3d43ba`):

- `483d072e61a7` macaudio: the lease's ramp-down starts below the machine's ceiling
- `524f61bed0f9` t6050-j716s.dts: amp level 15 (the ADT's)

(`patches/0001-*.patch`, `patches/0002-*.patch` here are the same two commits.)

Public repo, only under the allowed folders:

- `contrib/validated/desktop/audio/speakerguardd-v2/`: `README.md` (ceiling section corrected, qualifying notes), `install.sh`
  (`SGV2_NO_ENABLE=1`), `70-j716-speaker-upgrade-auto.conf` (#186), new `sgv2-silent-check.sh`
- `contrib/validated/desktop/audio/j716-profile/LISTENING-TEST.md`: the wrong "ceiling does not apply" paragraph
- `contrib/distro/pkg/speakerguardd-v2/PKGBUILD`, `pkg/aurora-speaker-upgrade/PKGBUILD`: header notes (built); new
  `pkg/aurora-speaker-upgrade/lzfse/PKGBUILD`
- `contrib/pending/speakers/`: this file, `MORNING.md`, `patches/`

Packages built with `makepkg --nodeps` in an Arch Linux ARM container (`menci/archlinuxarm:base-devel`, container `spk-build`,
rust 1.100) with `check()` passing: `/Volumes/m5pro/bench/speakers/pkgs/` (`lzfse-1.0-1`, `speakerguardd-v2-1.0.0alpha.1-41.1`,
`aurora-speaker-upgrade-0.1-16`). Upstream clone: `/Volumes/m5pro/bench/speakers/speakerguardd` at the pin.

## Next

Test request `/Volumes/m5pro/bench/requests/speakers-1.md` (silent bring-up, one boot). Then `MORNING.md`.
