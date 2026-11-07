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
