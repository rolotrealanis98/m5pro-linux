# A reboot while the SSD is still busy gets counted or breaks the next boot

2026-11-07/08, J716s, A/B stage-1 (0016). Earlier name: "the first boot of a freshly written boot.bin falls back once".

## Conclusion
The cause is a restart issued while the internal SSD controller (ANS) is still working after a write burst. That the
writes went to the ESP was a coincidence: FAT, the stage-1 file read and the payload content are not involved.

| Symptom | Error stage | Fallback kernel start vs a clean reboot | What happened |
|---|---|---|---|
| Counted restart | `00` | +0 to +8 s | The session's restart went wrong after Linux wrote boot_stage 0: controller shutdown and then the SMC `phra` restart did not finish, `apple_wdt`'s restart handler reset the machine by watchdog, iBoot counted it. The new file is not read on that boot. |
| Next boot panics | `30` | +33 to +41 s | The restart went through but the controller was reset while busy; the next boot started a controller still recovering and Linux panicked within ~5 s; `CONFIG_PANIC_TIMEOUT=10` reset it 10 s later. |

Calibration: after a sysrq-c panic the next kernel starts 22-26 s after the reset; a clean reboot in these scripts puts
the kernel start 26-29 s after the reboot command (73-77 s uptime at the ~103 s probe).

## Experiment table ("immediate" = reboot ~1 s after the burst)

| Run | Session | Last I/O before the reboot | Result |
|---|---|---|---|
| crash-log T1, W4 restore, #26 restore, power restore | various | ESP write, immediate | 4 x `00` (+6, +0-3, +2-5, +5-8 s) |
| DCP-A, first power-T1 attempt, GPU daily after omacom #30 | various | ESP write, immediate | 3 x `30` (+33 to +36 s) |
| exp4 arm 2 (`run-restart-exp4.log`) | omacom #30 | 70 MB `dd conv=fsync` on the ext4 root, immediate, no ESP write | 1 x `30` (+35 s), 2 clean |
| exp rounds 1-2 | omacom #30 | ESP write, then 5 min idle | 2 clean |
| exp3 control | omacom #30 | none (plain reboot) | 3 clean |
| exp2 | power kernel | none (plain reboot) | 3 clean |
| exp4 arm 4 and every restore with the 60 s settle | various | ESP write, then 60 s idle | 9 clean |

With at least 60 s of idle: 0 failures in 17 (~0.1 % chance if idle made no difference). Immediate after a burst: about 1
in 3 fails. The userspace stage marks (0x33 root mounted, 0x34 network up) read back in every session; arm 2.1 still
reported error stage `30`, so that boot died before its root was mounted.

## Mechanism (inferred; no console capture of a failing pair yet)
- Linux's T6050 shutdown: SHN with a 5 s `shutdown_timeout`, then the controller is disabled and its firmware left
  running into the reset (`drivers/nvme/host/apple.c`); after a burst the controller keeps working for seconds after
  the last FLUSH.
- Case 1 (00): SHN takes up to 5 s, the SMC `phra` (atomic, 5 s timeout, 100 ms grace) does not take effect,
  `macsmc_restart` returns NOTIFY_OK and `apple_wdt_restart` resets by watchdog.
- Case 2 (30): the controller is reset mid-work (an unsafe shutdown, recovered on the next start); that recovery is then
  interrupted several times (iBoot starts it; stage-1's `nvme_shutdown` sends SHN then `pmgr_reset`; stage-2 starts it
  again for the N1 storage check (0025); Linux probes or adopts it). A recovering controller can panic Linux within
  seconds only through hard paths (an SError on a register access, or an oops in the NVMe interrupt handler).
- Not the cause: the omacom loader and the power kernel (plain reboots 6 of 6 clean). `nvme_apple.flush_interval=0` is
  unrelated (every flush is synchronous on T6050).

## Fixes
1. Loop scripts, now: at least 60 s idle before `systemctl reboot` after any I/O burst; `esp-put.sh` defaults to
   `ESP_SETTLE=60`.
2. Global, no rebuild: a systemd-shutdown hook that runs `sync` and `sleep 20` (installed on the MacBook as
   `/usr/lib/systemd/system-shutdown/m5pro-settle.sh`). Optionally `nvme_core.shutdown_timeout=30` in the bootargs
   (the T6050 path takes `clamp(RTD3E, param, 60)`): candidate for the next daily.
3. Kernel, for review: apple-nvme final shutdown = Flush, then SHN, wait for completion with a 30-60 s bound and log the
   time, disable only after completion or timeout (warn on timeout); optionally a reboot notifier above macsmc-reboot
   doing the same; macsmc: wait longer than 100 ms after `phra` before the watchdog fallthrough.
4. Stage-1 0017 with `chainload.stage-mark=1`, recommended (attended ceremony): `00` cases boot primary, `30` cases still
   fall back (correct); `m5pro,stage1` reports read time and the slot reason. Risks: untested on hardware; 0x31/0x32 are
   new values for iBoot (counted like any non-zero value).

## To confirm
Film the panel through an immediate reboot after a 70 MB fsync burst (`shutdown notification failed`, `Atomic SMC
command timed out`, `Failed to issue MBSE = phra`, `Unable to restart system`, then the next boot's panic text, on
screen for 10 s); log the SHN duration (fix 3); keep `firstboot-probe.sh` (bands: first pass <= 35 s, m1n1 reboot
36-54, Linux panic 55-74, apple_wdt 75-169, stage-1 wdt >= 170) and `m5-stage-mark.sh dump` in the loop state lines.

## Earlier findings that still hold
0016 read defects fixed by 0017 (seek(End) clamps on a short chain, a 0-byte read can spin, watchdog armed before the
read); `sync(2)` on vfat sends no device FLUSH but fsync does; two earlier records were wrong (E2b "fell back" was an
empty slot read; the W4 restore fallback was not a warm-N1 hang).

Files: `0017-…patch`, `esp-put.sh`, `firstboot-probe.sh`, `m5-stage-mark.sh`, `SHA256SUMS`. Studio: ~/Work/agents/stage1-firstboot/.
