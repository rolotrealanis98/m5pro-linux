# Desktop defaults for the J716s (staged 2026-11-16; applied on the MacBook 2026-11-16 on 7.3.0-g4e0413c09f9a)

Applied and checked: lock screen (Omarchy PAM file was missing), charge limit (80/75, `Not charging` at 89 %, 0 W), journal 1.5 G -> 475 M, `/boot` read-only
automount, fstrim.timer, screensaver off, menu rows parse, region US. Not yet: systemd-oomd and the fq/bbr sysctl keys
(need next6's PSI and qdiscs), lid lock (next boot).

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
| `~/.config/omarchy/shell.json` `idle` (edited by `apply.sh`, backup `.before-m5pro-idle`) | screensaver off (`0`), lock at 300 s; Omarchy's lock screen turns the panel off 5 s after locking | current Omarchy has no hypridle: its shell's idle service (`plugins/services/idle`) runs screensaver and lock, and `omarchy-brightness-display off` blanks with `hl.dsp.dpms({ action = "disable" })`. DCP off/on cycle checked attended 2026-11-16, no errors. The screensaver cost ~7700 IPIs/s |
| `wireless-regdb` + `etc/systemd/system/m5pro-regdom.service`, `WIRELESS_REGDOM="US"` in `/etc/conf.d/wireless-regdom` (only if no country is set) | regulatory database loaded after the root fs, country set | cfg80211 is built in and looks before the root fs is mounted (`failed to load regulatory.db`, domain 00). On US the Wi-Fi firmware lists 59 6 GHz channels (0 on 00) |
| fstab root line: `x-systemd.growfs` removed (backup `/etc/fstab.before-m5pro-growfs`) | no failed unit at boot | `systemd-growfs-root` failed every boot with EPERM; the ext4 is already the partition's full size |
| `fstrim.timer` | weekly TRIM if the NVMe reports discard | |
| `systemd-oomd` | PSI-based OOM handling | needs `CONFIG_PSI` (next6) |
| `usr/local/bin/m5pro-charge-limit`, `usr/local/lib/m5pro/charge-limit-restore`, `etc/udev/rules.d/94-m5pro-battery-charge-limit.rules`, `/etc/udev/macsmc-battery.conf` (`CHARGE_CONTROL_END_THRESHOLD=80`, written only if absent) | battery charge limit, default 80 % (resumes at 75 %); `m5pro-charge-limit [50-99\|100\|full\|status]`; `full` = 100 % until unplugged or reboot | the SMC key CHLS through `macsmc-power` (any 10-99 %); udev restores the saved value at boot and on unplug. Same saved file and line as omarchy-mac's `omarchy battery charge limit` (omacom/omarchy-mac-pkgs `76d8b722`) and asahi-scripts, so moving to either keeps the value |
| `user/omarchy/menu-battery-rows.jsonc` | System > Battery charge limit: Limit to 80 %, Charge to 100 % once, No limit, Show | merged into `~/.config/omarchy/extensions/omarchy-menu.jsonc` (backup `.before-m5pro-battery`); sudo asks in a floating terminal |

Charge limit check (on the charger, battery above 80 %): `m5pro-charge-limit` shows 80/75; within a minute
`status` reads `Not charging` and `current_now` is 0 or negative. `m5pro-charge-limit full` -> `Charging`;
unplug -> back to 80. Reboot -> still 80. Untested on the J716s; whether macOS keeps or rewrites the SMC value
after a visit is unknown (macOS's own Battery setting may set its own limit).

Order: `baseline.sh` -> attended DPMS cycle -> `apply.sh` -> `baseline.sh` again.
