# Loop safety: a hung test boot must reset itself

Status: built 2026-11-07, hardware test queued (negative, positive, clean reboot), results to follow below.

## Why

The Thunderbolt T0 boot (`contrib/pending/thunderbolt/T0-HANG-ANALYSIS.md`) hung in kernel init for two hours
with no reset: `apple_wdt` is armed by stage 1 (`m1n1.wdt=keep`) and the kernel core feeds it
(`CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED`) until userspace opens `/dev/watchdog0`. Nothing ever opened it
(`watchdog.open_timeout` default 0, `RuntimeWatchdogSec` unset), so a hung init was fed forever.

## What

1. **Test payloads** (`m5.selftest=1`) get `watchdog.open_timeout=300` (`mk-daily.diff`, option
   `--wdt-open-timeout`, `--no-wdt-check` for the negative test). A boot that never reaches userspace is reset
   at about 330 s and stage 1 falls back to `boot.bin.prev`.
2. **Initramfs opener** (`add-wdt-opener.py`): with `m5.selftest=1`, `/init` opens `/dev/watchdog0` after devtmpfs
   and writes `.` every 10 s, never `V`. Before `switch_root` it installs
   `/etc/systemd/system.conf.d/m5pro-watchdog.conf` on the root if no `RuntimeWatchdogSec>0` is set, then kills the
   petter so systemd can open the single-open device. If the root never mounts, petting stops after `m5.wdt_diag=`
   seconds (default 600), so the "root never mounts" hole in ESP-POLICY.md now also ends in a fallback.
   The builder refuses an initramfs without the opener marker when `open_timeout` is set.
3. **systemd owns the dog on the root** (`m5pro-watchdog.conf`): `RuntimeWatchdogSec=60`, `RebootWatchdogSec=5min`.
   A plain close without `V` does not disarm `apple_wdt` ("watchdog did not stop!"), so a pet service that dies
   at shutdown would bite mid-shutdown; PID 1 pets through shutdown, and `watchdog_pm_notifier` plus
   `apple_wdt_suspend/resume` cover s2idle.

The daily gets no `open_timeout`; the drop-in reaches it through the shared root (first test boot installs it).

## Test plan (unattended, runner `~/Work/agents/loop-safety/loop/run-wdt-safety.sh`)

1. Negative: `wdt-noopener` twin (old initramfs, `open_timeout=120`, drop-in removed first): expect a reset about
   150 s after boot and a stage-1 fallback to prev (the daily).
2. Positive: `wdt-opener` twin (`open_timeout=300`): m5-wdt lines in dmesg, drop-in installed,
   `RuntimeWatchdogUSec=1min`, no reset past 400 s of uptime.
3. Clean `systemctl reboot` of the opener twin, no spurious fallback. Then the daily is restored.
4. Later (attended): lid-close s2idle on the daily with the drop-in active.

Files: `add-wdt-opener.py`, `mk-daily.diff` (against `contrib/validated/aurora/tools/mk-daily.py`), `mk-twins.py`,
`m5pro-watchdog.conf`. The patched initramfs images stay private (they embed the firmware table).
