# Desktop defaults for the J716s (staged 2026-11-16, not run)

From the 2026-11-16 gap hunt and the Windows agent's Linux-side report
(`m5pro-windows/findings/linux/LINUX-SIDE-ISSUES-20261115.md`).

| File | What | Why |
|---|---|---|
| `baseline.sh` | Read-only snapshot (taint, boot time, TRIM, swap, regdb, Wi-Fi power save, BT, backlights, IIO, platform profile, battery, cpuidle/cpufreq, THP/MGLRU/PSI, hypridle, logind, ASPM, perf) | turns the gap hunt's "unknown" rows into facts; run before and after `apply.sh` |
| `apply.sh` | Installs everything below; idempotent | |
| fstab `/boot` line (added by `apply.sh`) | ESP automount read-only (`ro,...,x-systemd.automount,x-systemd.idle-timeout=120`) | A1: the generator mounted it read-write on every access. `esp-put.sh` remounts read-write only inside its own write |
| `etc/systemd/journald.conf.d/50-m5pro.conf` | journal capped at 500 MB | |
| `etc/systemd/zram-generator.conf.d/50-m5pro.conf` + `zram-generator` | zram swap, half of RAM up to 16 GiB, zstd | no swap today |
| `etc/sysctl.d/50-m5pro.conf` | zram swappiness; RT clamp line commented until the A/B (queue item 3) | |
| `etc/systemd/logind.conf.d/50-m5pro.conf` | lid close locks (not suspend yet) | suspend only after a lid/key wake from s2idle is proven |
| `user/hypr/hypridle.conf` | dim 4.5 min, kbd backlight off, lock 5 min, panel off 5.5 min, no screensaver; suspend listener commented | screensaver cost ~7700 IPIs/s; panel off needs the attended DPMS cycle (queue item 8) |
| `wireless-regdb` | Wi-Fi regulatory database | next4 journal: `failed to load regulatory.db` |
| `fstrim.timer` | weekly TRIM if the NVMe reports discard | |
| `systemd-oomd` | PSI-based OOM handling | needs `CONFIG_PSI` (next6) |
| `usr/local/bin/m5pro-charge-limit`, `usr/local/lib/m5pro/charge-limit-restore`, `etc/udev/rules.d/94-m5pro-battery-charge-limit.rules`, `/etc/udev/macsmc-battery.conf` (`CHARGE_CONTROL_END_THRESHOLD=80`, written only if absent) | battery charge limit, default 80 % (resumes at 75 %); `m5pro-charge-limit [50-99\|100\|full\|status]`; `full` = 100 % until unplugged or reboot | the SMC key CHLS through `macsmc-power` (any 10-99 %); udev restores the saved value at boot and on unplug. Same saved file and line as omarchy-mac's `omarchy battery charge limit` (omacom/omarchy-mac-pkgs `76d8b722`) and asahi-scripts, so moving to either keeps the value |
| `user/omarchy/menu-battery-rows.jsonc` | System > Battery charge limit: Limit to 80 %, Charge to 100 % once, No limit, Show | merged into `~/.config/omarchy/extensions/omarchy-menu.jsonc` (backup `.before-m5pro-battery`); sudo asks in a floating terminal |

Charge limit check (on the charger, battery above 80 %): `m5pro-charge-limit` shows 80/75; within a minute
`status` reads `Not charging` and `current_now` is 0 or negative. `m5pro-charge-limit full` -> `Charging`;
unplug -> back to 80. Reboot -> still 80. Untested on the J716s; whether macOS keeps or rewrites the SMC value
after a visit is unknown (macOS's own Battery setting may set its own limit).

Order: `baseline.sh` -> attended DPMS cycle -> `apply.sh` -> `baseline.sh` again.
