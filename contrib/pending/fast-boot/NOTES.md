# fast-boot notes (2026-11-23)

Working notes for the quiet-fast boot. Request for the orchestrator: `/Volumes/m5pro/bench/requests/fast-boot-1.md`.
Numbers are read from the Mac's journals and the aura log (mtd0); "estimated" means arithmetic on those lines.

## Timeline of a real boot (daily 624bd344, boot of 2026-11-23 08:50; same numbers at 11:33)

Aura's log counts from the SoC reset; the kernel clock starts when aura vectors into it.

| Stage | Since power-on | Takes |
|---|---|---|
| iBoot + stage 1 (reads the 43 MB boot.bin) | 0 - 14.08 s | 14.1 s, split unknown |
| aura stage 2 | 14.08 - 20.46 s | 6.4 s (USB2 1.3, kernel inflate 1.07, initramfs inflate 0.83, measure 0.23, log lines ~1.6) |
| kernel to /init | 20.46 - 22.0 s | 1.5 s |
| initramfs (fsck -p clean, mount) | 22.0 - 22.2 s | 0.2 s |
| systemd to getty@tty2 | to 23.3 s | 1.1 s |
| getty Type=idle wait | 23.3 - 27.8 s | 4.5 s |
| login to Hyprland | to 28.9 s | 1.0 s |
| Hyprland to lock (lock-at-login sleeps 2 s) | to 32.5 s | 3.6 s |
| lock to panel blanked (Omarchy idleMs 5000) | to 37.7 s | 5.2 s |

Cold boot to lock screen about 33 s. Linux restart (`systemctl reboot` to lock screen) about 59 s: 3.3 s shutdown, 23.5 s tail
(20 s is the `sleep 20` in /usr/lib/systemd/system-shutdown/m5pro-settle.sh), 20.5 s pre-kernel, 12 s to the lock.
Journal stops 44-45 s before the next kernel in 3 of 3 restarts.

## Ranked changes (estimates until tested)

1. Settle only after a write burst (m5pro-settle.sh v2): restart -20 s, Linux to macOS -20 s. Medium risk, see the 60 s rule.
2. Autologin getty Type=simple: -2.3 s steady, -4.5 s on a new kernel or test boot. Low.
3. lock-at-login v2 (poll the lock plugin, no sleep 2): -2 to -3.6 s. Low.
4. aura FB_SILENT_MODE (fast-boot-2): up to -1.6 s and no aura text. Low-medium, a new loader image.
5. quiet bootargs (fast-boot-1): clean kernel/systemd screen; little time. netconsole then shows errors only.
6. initramfs v4q: banner to the log; /etc/m5-verbose raises the loglevel after the root mount.
7. Panel floor 30 %; 8. keep the panel lit 120 s after the boot lock; 9. ~/.hushlogin.
10. Plymouth splash: not built (extra DCP modeset, untried).
Not changed: e2fsck -p (0.1 s), aura USB2 bring-up (safety step), systemd units (nothing blocks), initramfs trimming (31 of 41.6 MB is
the N1 FTAB the built-in driver reads at 1.45 s; open).

Combined: restart 59 s -> about 31 s; cold boot to lock 32.5 s -> about 24 s; iBoot + stage 1 (14.1 s) becomes the largest block.

## Debug escape hatch

ESP allows four payloads. Keep the verbose daily 624bd344 as boot.bin.prev (do not rotate it on promotion); reach it with the
documented forced reset (hold power until off, press once). `touch /etc/m5-verbose` raises the console loglevel to 8 after the root
mount. dmesg, journal (log_buf_len=16M), mtd0 aura log, boot_stage marks, pstore unchanged. Lost: live text on a hang before the
initramfs (its DIAG block still prints). No key-at-boot: stage 1 and aura have no keyboard.

## Display: why the login screen sometimes is dark

1. lock-at-login locks with no input; Omarchy's lock plugin (idleMs 5000) runs `hyprctl dpms disable` 5 s later: lock PAM 12.14 s,
   DCP brightness 0 at 17.47 s. Waking is a DCP modeset (0.24 s) and Touch ID is paused while blank. v2 re-wakes during the first 120 s;
   one blink remains. Clean fix is Omarchy-side (skip the idle blank for an input-less boot lock).
2. systemd-backlight restores the last saved level: 8 of 41 boots since 11-17 below 120/600 (5 below 60, e.g. 42 and 69 on 11-23),
   auto-brightness is paused while locked. v2 install adds a 30 % floor.
3. session-restore windows (Claude, Chrome) appear before the old lock; with the earlier lock they open behind it.
No DCP error or timeout in the last 9 boots.

## Built

- /Volumes/m5pro/bench/pr-verify/fast-boot-1-20261123-d050d4ef.bin  d050d4efd5fb13ad336fb1cb44d11dcaab13602214a012fe80a69af44509ddac
- /Volumes/m5pro/bench/pr-verify/fast-boot-2-20261123-545bc33a.bin  545bc33ada4578cf3805e66335459858bcecc7d096cac74b991a5ddcf1b7f9b4
- silent loader /Volumes/m5pro/out/aura/fastboot-silent/aura.bin  04812d6d7865096f48826cd01b711280cf96ab866051e69be064c3041c9a34f9
  (aura j716s-camera-1 191168bb + EXTRA_CFLAGS=-DFB_SILENT_MODE); control build fastboot-repro (8e6e6d5e..., not bit-equal to the daily's
  loader: ImageMagick 7.1.2.36 vs .35 changes the logo data)
- initramfs v4q /Volumes/m5pro/bench/fast-boot/initramfs-ftab-wdt2-fsck-v4q.cpio.gz  fed94b1fdc60ef09070fcf31dd1288484074857cf3d296ff54e45541b82bf434
- mk-fast-boot.py (pack), mk-initramfs-v4q.py, fast-boot-timeline.py, userspace/install-fast-boot.sh (+ undo)
Superseded first-pack files (da43de4f, b8ed2b52) stay on the volume. Same kernel/DTB/modules as the daily; test form self-reverts.

## Open

- iBoot vs stage 1 split (owner stopwatch point 3 in the request).
- /boot/r1-logs/.reverted-once exists: a no-network test would not revert.
- If aura boot_args.video.display is 0 on this Mac, fast-boot-2 prints as before.

## Round 2 (2026-11-23 evening): request /Volumes/m5pro/bench/requests/fast-boot-2.md

- Daily now 7cf5348b (silent aura without host wait): aura 14.33 -> 18.93 s (4.60 s, was 6.41), Hyprland 22.69 s, lock 24.47 s; the
  7.2 ms/line aura print cost is gone (1.0 ms). iBoot + stage 1 = 14.3 s = 58 % of the time to the lock screen, split unknown.
- fast-boot-3 (test) c0d91103 / daily form f42d76ae: bootargs `quiet loglevel=3 logo.nologo ... systemd.show_status=false udev.log_level=3
  plymouth.enable=0`, initramfs v5 (init output fully silent under quiet, failure paths back on the console, selftest unit Type=exec).
  Packer: `FASTBOOT_PROFILE=polish python3 -I -B mk-fast-boot.py` (`FASTBOOT_DAILY=1` for the daily form). `console=tty3` rejected (hides the DIAG).
- userspace/install-polish.sh: removes the getty@tty1 boot symlink (VT1 stays blank; logind autovt keeps Ctrl+Alt+F1 login). Undo included.
- Stage 1: enrolled = boot-ab.bin 920ed202 (3 identical copies read from the stub, p3). Built on macOS; the Fedora container rebuild lays out
  differently, so the silent stage 1 is the enrolled image with ONE instruction changed (0x26aec mov w0,#1 -> #0), sha bc060f93; files and ceremony
  in the request; stage1/ (bench/fast-boot/stage1) holds the sources of the container builds, s1-timing.patch (optional timing property) and the rollback.
- Housekeeping slip: while tidying bench/fast-boot/stage1/dist I `rm -f`'d three wrapped images I had made minutes earlier (container-build
  variants); mk-dist.sh regenerated them identically. Nothing else was removed.

## Result (2026-11-23, evening)

The owner enrolled `s1-silent-patched-wdt150.bin` (sha256 `bc060f93...`) through 1TR (`stage1-install.sh`, then power-hold -> Omarchy -> step2).
First boot: primary slot, 18 CPUs, systemd feeding `/dev/watchdog0` (1 min), stage-1 version string unchanged
(`v2.0.0-68-g459a3af2-dirty`), no text on the panel from the Apple logo to the lock screen. With the polished daily
`daily-20261123-f42d76ae` (logo.nologo, systemd.show_status=false, initramfs v5, blank tty1): aura starts 13.61 s (was 14.33 s), kernel
18.25 s, Hyprland 21.86 s, lock screen 23.64 s. Rollback stage 1: `rollback-boot-ab-920ed202.bin` on the stub (`/Volumes/Omarchy/m1n1/`),
in `~/Work/m1n1/stage1/` on the MacBook's macOS and in `/Volumes/m5pro/bench/fast-boot/stage1/xfer/`; the macOS backup of what was enrolled
before is `~/Work/m1n1/stage1/rollback-installed-20261123.bin` (920ed202...).
