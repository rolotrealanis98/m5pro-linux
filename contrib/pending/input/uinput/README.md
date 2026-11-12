# Virtual input: uinput and uhid (issue #4)

The daily kernel had neither `/dev/uinput` nor `/dev/uhid` (`# CONFIG_INPUT_UINPUT is not set`,
`# CONFIG_UHID is not set`; no fragment in `defconfig asahi.config j716s.config` turns them on).
That blocks ydotool/dotool, key remappers, Steam Input, bluetoothd's AVRCP keys (uinput) and every
Bluetooth LE keyboard or mouse (bluetoothd's HID over GATT goes through uhid).

Config only: no source, DT, loader or initramfs change.

| File | What |
|---|---|
| `../../../validated/aurora/series/j716s.config`, `../../../distro/pkg/linux-m5pro/m5pro-distro.config` | `CONFIG_INPUT_UINPUT=y`, `CONFIG_UHID=y` |
| `build-kernel-uinput.sh` | kernel branch `j716s-uinput` = the daily's `0933f881d736` + the fragment commit; config = the daily's + the two symbols (the build stops on any other difference); DTB must equal the daily's |
| `mk-uinput.py test\|daily` | the installed daily (`daily-dcp-rec-video-hv27`, c7f84366) with only the kernel replaced: `uinput-test` (self-reverting) and `daily-uinput-hv27` |
| `run-uinput.sh prep\|test\|promote` | modules + udev rule + self-check onto the root; test boot; promotion |
| `70-m5pro-uinput.rules` | `/dev/uinput` is `root:root 0600` when the driver is built in; the rule gives it to group `input` and to the seat user |
| `uinput-selfcheck.py` | stdlib-only proof on the machine: a uinput device whose button press is read back from evdev, and a uhid device that shows up on the HID bus |

Baseline on the daily (`7.3.0-g0933f881d736`), 2026-11-10: `uinput-selfcheck.py` fails both
(`/dev/uinput does not exist`, `/dev/uhid does not exist`).
