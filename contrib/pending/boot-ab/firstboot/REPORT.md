# First boot of a freshly written boot.bin falls back once (2026-11-07)

Verdict: the timed cases are not the stage-1 misreading the new file. In 2 of 3 timed fallbacks the stage-1 never
read the new boot.bin: on its first pass after `systemctl reboot` it found iBoot's error count already non-zero and
went straight to boot.bin.prev, so iBoot had counted the restart of the session that wrote the file. In the third
(DCP-A) the new payload ran and was reset within tens of seconds. Common factor: a reboot about 1 s after tens of MB
were written to the FAT ESP.

## Evidence (reboot sent -> kernel start, Studio clock minus /proc/uptime)

| Boot | Fallback boot | Clean reboots, same script | Extra |
|---|---|---|---|
| crash-log T1 first boot | 27-28 s | 22 s | ~6 s |
| W4 restore of the lid daily | 21-25 s | 21-23 s | 0-3 s |
| DCP-A first boot | ~61 s | 25-27 s | ~35 s (early reset of the attempt, error stage 0x30) |
| board-v2 first boot | 33-42 s | 21-25 s | 8-17 s, ambiguous |

- A failed primary attempt costs >= the 150 s watchdog or a second iBoot pass + stage-1 + the 35 MB read; 0-6 s
  extra leaves no room, so the fallback was decided on the first pass.
- Stage-1 0016 sets `fallback-after-failure` whenever the count is non-zero: "the writing session ended badly" and
  "the new payload failed" look the same.
- Precedent R3-AUDIO-B2: daily restored then reboot -> fallback-after-failure 52 s later, pmu-scrpad 300100,
  error stage 0x00 (counted after Linux's reboot notifier wrote boot_stage = 0; macsmc-reboot.c runs it before
  device_shutdown()).
- Every fallback-after-failure today followed an ESP write + reboot ~1 s later (DAILY-WIFI 14:04, W4 and DCP-B
  restores included); all 8-10 reboots without a payload write were clean (p ~ 2 % if writes did not matter).
- Probable trigger: vfat has no ->sync_fs, so sync(2) sends no device FLUSH and ~70 MB + FAT/directory sectors can
  still sit in the controller's write cache; apple-nvme's final shutdown waits <= 5 s (shutdown_timeout) then
  disables the controller and leaves its CPU running into the restart; a missed shutdown is counted unsafe and
  "recovers on the next start". The 5 s fits T1's ~6 s extra. drop_caches sends no flush (failed once); unmount +
  remount + re-hash add idle seconds (3/3 clean).

## Stage-1 read path: not today's cause, two defects fixed in 0017

- Fragmentation/alignment irrelevant (rust-fatfs walks the chain; ~20k 4 KiB reads for 40 MB, 1-3 s).
- Defect A: rust-fatfs seek(End) stops at the end of a short FAT chain (or 0 with no first cluster); load_image
  used that as the size and could boot a truncated or empty image (empty -> exception -> reboot = counted failure).
  A read() returning 0 early would spin until the watchdog.
- Defect B: watchdog armed before the read, so read time ate into the payload's 150 s.

## Fixes

`0017-chainload-check-the-image-against-its-directory-entr.patch` (on 0016; compile-checked only, sizes unchanged
0x420000 CHAINLOADING / 0x410000 plain; installing it is a stage-1 ceremony):
- image size checked against the directory entry; mismatch, 0, > 256 MiB or short read fails the slot and the other
  slot is tried in the same boot (not a counted failure);
- watchdog re-armed with the full chainload.wdt once the image is in memory;
- new `chosen.m5pro,stage1` = `pmu=...;why=...;slot=...;read_ms=...;size=...;wdt=...;mark=...`;
- opt-in `chainload.stage-mark=1`: stage-1 writes boot_stage 0x31 (primary) / 0x32 (fallback) before hand-over;
  error stage 0x00 (the session died in its own restart) then boots the primary; `chainload.restart-failure=fallback`
  turns that off; 0x32 also boots the primary first. `m5pro,boot-slot` values unchanged.

`esp-put.sh SRC NAME SHA` (replaces scp .new / mv / sync): copy to /root, cp to NAME.new, `sync NAME.new` (fsync
sends the FLUSH on FAT), verify hash, mv, `sync NAME /boot/m1n1`, umount, fsync the block device, drop_caches,
remount read-only (ESP_RW=1 keeps rw), re-hash cold, wait ESP_SETTLE (5 s), print unsafe_shutdowns.

`firstboot-probe.sh <reboot epoch>`: classifies each boot (first-pass <= 32 s, attempt-reset-early 32-150 s,
watchdog > 150 s) with slot, pmu scrpad and unsafe_shutdowns.

## Corrections to RESULTS.md

- E2b "fell back once" is wrong: slot() returned empty; ssh answered ~100 s after the reboot then timed out, so E2b
  booted and went silent.
- The W4 restore fallback does not fit "a loader without 0027 hangs once on the warm N1" (no time for a hang); it fits
  the counted-restart cause.

## Read-only facts still to collect on the MacBook

    cat /sys/module/nvme_core/parameters/shutdown_timeout
    nvme id-ctrl /dev/nvme0 | grep -E '^(vwc|rtd3e) '
    nvme smart-log /dev/nvme0 | grep -i unsafe
    fsck.fat -n -v /dev/nvme0n1p4 | head -30
    filefrag -v /boot/m1n1/boot.bin /boot/m1n1/boot.bin.prev

Studio: `~/Work/agents/stage1-firstboot/` (branch firstboot c3fe53bc on 0016, built images m1n1-chain-firstboot.bin
a80a6de0…, m1n1-plain-firstboot.bin 7f0ca1fd…, SHA256SUMS, esp-put.sh, firstboot-probe.sh).

## Revised model (2026-11-07 22:30 UTC)

The ESP write is not what gets a restart counted; the outgoing session's own restart is (the plain no-write reboot from
the twin and 7 clean esp-put restores rule out write timing as the main factor; the earlier correlation was confounded
because nearly every reboot followed a write; esp-put stays, it costs nothing). Two classes:
- Error stage 00 ("first pass"): the outgoing session died after Linux's reboot notifier wrote boot_stage 0, so the
  reset was not the normal SMC restart. Cases: #26 restore (+2-5 s), power-kernel restore (+5-8 s), crash-log T1
  (+6 s), audio B2 (+30 s). Leading mechanism: macsmc's restart handler writes MBSE=`phra` in atomic mode;
  `apple_smc_write_atomic` waits up to 5 s (another 5 s if an earlier command is pending); on failure, or if the SoC has
  not reset 100 ms after the write, the notifier chain falls through to `apple_wdt_restart`, a watchdog reset, which
  iBoot counts with error stage = current boot_stage = 00. Timing fits (+5/+10 s = unanswered phra, +0 = phra slower
  than 100 ms, +30 = a stall earlier in device_shutdown). The power kernel plausibly adds SMC traffic during shutdown
  (cpufreq, SoC-die zone, PMC observation); the omacom loader changes the SMC RTKit session Linux inherits and the NVMe
  shutdown path (live ANS adoption).
- Error stage 0x30: the newly started payload panicked in its first seconds of Linux, then PANIC_TIMEOUT=10 reset it
  (DCP-A, the first T1 attempt, the GPU daily after omacom #30). External warm state (N1) is the suspect.

Discriminating experiment: no-write `systemctl reboot` x3 from a power-T1 session and from an omacom #30 session, with
firstboot-probe.sh after each (counted with no write = the session's restart path; +5/+10 s = atomic timeout). If counted:
unbind the power kernel's new drivers before rebooting, x3. Attended confirmation: film the panel for `Atomic SMC command
timed out`, `atomic: earlier command still pending`, `Failed to issue MBSE = phra`, `Unable to restart system`, `nvme …
shutdown notification failed`. Real fix lives in macsmc and the power drivers (quiesce SMC users before atomic mode; wait
longer than 100 ms before the watchdog fallthrough).

0017 with `chainload.stage-mark=1` would have booted the primary slot on all three error-00 fallbacks today
(`why=restart-failure`), still falls back on the 0x30 panics (macsmc overwrites 0x31 with 0x30 at probe, so the
userspace marks 0x33/0x34 add the information), reports 0x31 for a death in stage 2, 0x32 for the fallback slot dying,
plus read_ms/size/wdt on every boot. Recommendation: install it (attended ~25 min ceremony, rollback image ready).
