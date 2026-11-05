# J716s platform userspace (Arch root)

Install paths are the paths under this folder. Copy as root, then
`systemctl daemon-reload && systemctl restart systemd-logind` (logind
restart ends graphical sessions; do it from SSH or reboot instead).

| File | Install to | Default |
|---|---|---|
| etc/systemd/logind.conf.d/10-m5pro-safe.conf | /etc/systemd/logind.conf.d/ | install now: logind ignores power key, lid, sleep keys |
| etc/systemd/sleep.conf.d/10-m5pro-no-sleep.conf | /etc/systemd/sleep.conf.d/ | install now: systemctl suspend/hibernate refused |
| etc/udev/rules.d/90-m5pro-kbd-backlight.rules | /etc/udev/rules.d/ | optional: group video may write kbd_backlight |
| usr/local/bin/m5-temps | /usr/local/bin/ | read-only dump of SMC temps, fans, zones, cooling devices |
| usr/local/bin/m5-fan-floor + etc/systemd/system/m5-fan-floor.service | /usr/local/bin/, /etc/systemd/system/ | NOT enabled; only if TEST-PLAN F1 shows fans do not ramp |
| hypr/m5pro-kbd-backlight.conf | ~/.config/hypr/ (source it) | optional binds (brightnessctl) |
| stages/logind-20-poweroff-verified.conf | /etc/systemd/logind.conf.d/20-m5pro-power.conf | only after TEST-PLAN P2 |
| stages/logind-30-s2idle-verified.conf + stages/sleep-30-s2idle.conf | logind.conf.d/30-m5pro-sleep.conf, sleep.conf.d/30-m5pro-s2idle.conf; remove 10-m5pro-no-sleep.conf | only after TEST-PLAN S1-S6 |

Also run once (belt and braces for anything that bypasses sleep.conf):

```
systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

(`suspend.target`/`sleep.target` stay unmasked so stage S needs no unmask;
`AllowSuspend=no` already refuses them.)

Nothing here needs a udev hwdb entry: the SMC "power/lid events" device
reports KEY_POWER and SW_LID directly, and the built-in keyboard has no
keyboard-light keys. Keyboard brightness is restored across boots by
systemd (systemd-backlight@leds:kbd_backlight.service, automatic).

Fan policy default: none. The SMC runs both fans autonomously; Linux only
reads them (`macsmc_hwmon.fan_control` stays 0).
