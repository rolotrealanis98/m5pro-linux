# Loop safety: a hung test boot must reset itself

Status: v1 tested on hardware 2026-11-07/08 (below): the hand-over failed and the negative test did not run. v2 built, not yet booted.

## Why

The Thunderbolt T0 boot (`contrib/pending/thunderbolt/T0-HANG-ANALYSIS.md`) hung in kernel init for two hours
with no reset: `apple_wdt` is armed by stage 1 (`m1n1.wdt=keep`) and the kernel core feeds it
(`CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED`) until userspace opens `/dev/watchdog0`. Nothing ever opened it
(`watchdog.open_timeout` default 0, `RuntimeWatchdogSec` unset), so a hung init was fed forever.

## What

1. **Test payloads** (`m5.selftest=1`) get `watchdog.open_timeout=300` (`mk-daily.diff`, option
   `--wdt-open-timeout`, `--no-wdt-check` for the negative test). A boot that never reaches userspace is reset
   at about 330 s and stage 1 falls back to `boot.bin.prev`.
2. **Initramfs opener** (`add-wdt-opener.py`, v2 below): with `m5.selftest=1`, `/init` opens `/dev/watchdog0` after devtmpfs
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

## Hardware results of v1 (twins 2daadc5b opener, 242a6abb no-opener; runner `loop/run-wdt-safety.sh`)

- **Positive (opener, `open_timeout=300`)**: booted twice, up past 400 s, "network OK", clean `systemctl reboot` on the
  primary slot. The hand-over did NOT happen: no drop-in installed, `RuntimeWatchdogUSec=0`, `wdctl` and
  systemd-shutdown got "Device or resource busy". The petter fed the dog for the whole boot, so the pass proves nothing
  about the bound.
- **Negative (no opener, `open_timeout=120`)**: NOT RUN. The journal has no boot of the twin; the "previous boot" with a
  clean systemd-shutdown at 149.6 s is the daily that wrote the twin. The fallback kernel came 80 s after the reboot
  (a normal reboot-to-kernel time); the PMU error stage 0x30 was already 0x30 before the test (stale), so it says
  nothing. Likely the counted-restart class of `firstboot/REPORT.md` (a restart shortly after an ESP write), or the twin
  died within seconds.

## Root cause of the failed hand-over, and v2

Most likely cause (inferred from the symptoms and a dash simulation; not yet seen on the machine): v1 probed `/proc/$PID/fd/9` 0.3 s after starting the petter. The pet loop runs `sleep 10 9>&-`; an in-process
`sleep` (busybox NOFORK) applies `9>&-` to the shell itself for the duration and keeps the fd at a number >= 10 (dash
does exactly this). So fd 9 does not exist while the loop sleeps, the probe failed, v1 cleared `M5WDT` ("could not open") and the
pre-`switch_root` block (`if [ -n "$M5WDT" ]`) never ran: no drop-in, petter never killed. The init anchors were
fine (the same `/init` ran, the selftest installer beside it worked).

v2 (`add-wdt-opener.py`, marker `m5-wdt-opener v2`, `mk-daily.py` refuses v1 images):
- The petter PID is always remembered; the probe only chooses a log line (it looks for any fd of the PID that points
  at `watchdog0`).
- The hand-over no longer depends on the probe: on every `m5.selftest=1` boot it installs the drop-in (unless the root
  sets `RuntimeWatchdogSec`), then `kill -9` the petter and every other process whose `/proc/*/fd/*` resolves to
  `/dev/watchdog0`, and loops until nobody holds it (3 s bound, WARNING if not). Plain close, no `V`.
- Logging to the console and `/dev/kmsg`: `dmesg | grep m5-wdt` shows, in order, "initramfs reached", "stage mark 0x31
  written", "/dev/watchdog0 opened, petting ...", "installed ...m5pro-watchdog.conf" (or "root already sets ..."),
  "/dev/watchdog0 released ... nobody holds it". A WARNING line says which step failed.
- PMU boot_stage marks, same byte as `m5-stage-mark.sh` (scratchpad 0xf801, nvmem under `spmi@28a014000/pmic@e`):
  0x31 as soon as the initramfs runs (background, waits up to 20 s for the nvmem), 0x32 right before `switch_root`
  (after the hand-over). The root's units then write 0x33 and 0x34. Error stage after an abrupt reset:
  0x30 died before the initramfs (kernel), 0x31 in the initramfs, 0x32 after the hand-over and before the root unit
  (a failed hand-over bites 30 s after this), 0x33/0x34 later. A stale error stage can be cleared first by writing
  0xf803 (not done by these scripts).
- Negative test without a second initramfs: bootarg `m5.wdt=off` (only with `m5.selftest=1`) writes the marks and
  skips the opener, the drop-in and the hand-over. Twin `wdt2-noopener` = new initramfs + `m5.wdt=off` +
  `watchdog.open_timeout=120`: the root comes up (0x33/0x34), then the core stops feeding at 120 s and the dog bites
  at about 150 s of kernel uptime with error stage 0x33/0x34, then the stage-1 fallback. The root must have no
  `RuntimeWatchdogSec` drop-in (the opener twin installs one: `rm /etc/systemd/system.conf.d/m5pro-watchdog.conf`
  first, or run the negative twin first).

## Rerun

1. Remove the drop-in on the root. Put `wdt2-noopener`, settle at least 120 s, reboot. Outcomes: error stage 0x33/0x34 +
   fallback = bite worked; 0x30 + no twin journal = died in the kernel; 0x31 = died in the initramfs; stage unchanged and no
   twin boot = counted restart, the twin never ran (repeat).
2. Put `wdt2-opener`. Expect the m5-wdt lines above, the drop-in present, `RuntimeWatchdogUSec=1min`, `wdctl` able to
   read (systemd owns the device: `wdctl` itself gets EBUSY from the single-open device, use `systemctl show` and the
   kernel log instead), no reset past 400 s, a clean reboot on the primary slot, and no "Failed to open watchdog".

Journal evidence: journald writes the persistent journal through a mapped file; a hard reset loses up to about 30 s
(kernel writeback) of the tail, except messages of priority crit and above (synced at once). The journal lives in `/run`
until `systemd-journal-flush.service` moves it to `/var/log/journal` (a few seconds after the root mounts), so a boot
that dies earlier than that, or never reaches userspace, leaves no journal at all. A boot that was reset at 150 s would
show in `journalctl --list-boots`. `m5-wdt` lines go through `/dev/kmsg`, so they are in the journal too.

Settle before a reboot into a twin: `esp-put` already idles 60 s and the runner then rebooted 7 s later (67 s). Data so far:
0 failures in 17 with >= 60 s, 2 of 2 clean with 5 min, and this run is a probable 1 in 18. Use `ESP_SETTLE=120` for twins
(cost one extra minute), and treat "fallback with no twin journal and stage 0x30/0x00" as an inconclusive run to repeat,
not a result. The `unsafe_shutdowns=` field of `esp-put` printed empty on the MacBook root in that run (`nvme smart-log`
gave nothing), so the counter did not guard anything; install `nvme-cli` or read the counter another way.
