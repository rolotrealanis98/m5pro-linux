# airpods-control

AirPods noise control from Linux: `airpods-mode anc|transparency|adaptive|off`, plus battery (case and each bud), ear detection and conversation awareness. Targets the owner's **AirPods Pro** first; **AirPods Max** also works by the protocol (single "headphones" battery, no adaptive).

- Scope: `generic`. Status: `staged` (install, undo and the DeviceID step verified in an Arch Linux ARM aarch64 container; the optional LibrePods build is NOT verified (container build did not finish); AAP traffic not yet tried against real AirPods). Upstream: none/personal (protocol knowledge from LibrePods; nothing to send them).
- How it works: Apple's AAP over L2CAP PSM 0x1001, which BlueZ exposes as a plain Python `AF_BLUETOOTH` socket. `files/usr/local/bin/airpods-mode` is a ~200-line stdlib script (no build, no Qt). It works on its own; with the optional user service below it asks the service instead of opening a second connection. Packet layouts come from LibrePods' `AAP Definitions.md` and its Rust client.
- The AirPods must be **connected** (A2DP up). One AAP client at a time: close LibrePods before using `airpods-mode`, and the reverse.

## Panel and service (staged, untested on the Mac)

`files/usr/local/bin/airpods-daemon` + `files/usr/lib/systemd/user/airpods-control.service` is a user service that owns the one AAP connection and serves state and commands on `$XDG_RUNTIME_DIR/airpods-control.sock`. The Omarchy Bluetooth panel reads it (battery left/right/case, ear detection, noise mode, conversation awareness under a connected AirPods row). Design, install, undo and the upstream plan: `shell/DESIGN.md`, `shell/README.md`. Test without Bluetooth: `python3 -I shell/test/daemon-fake-aap-test.py`.

## Choice of tool

| Candidate | Verdict |
|---|---|
| **`airpods-mode` (this item)** | Chosen. No dependency beyond python3 + bluetoothctl (both stock). Headless: keybinds, waybar, scripts. No DeviceID change needed for modes/battery/ear/CA. |
| LibrePods Qt (`linux/` on main, v1.0.4) | Works (Max listed fully supported, Pro 2 best), has `librepods-ctl noise:*`. But: tray GUI app that must run, Qt6 stack (~15 pkgs), no status/battery CLI, AGPL-3.0, no AUR package. Optional here: `install.sh --with-librepods` builds a pinned commit via `librepods/PKGBUILD`. |
| LibrePods Rust (`linux/rust` branch) | Rewrite in progress, not in a release, iced GUI + big crate tree. Not used. |
| MagicPodsCore / MagicPods | Not found as a maintained Linux package; "MagicPods for Linux" is a Steam app, not usable here. |
| EarPort | GNOME Shell extension; Omarchy is Hyprland. |
| AUR | None found for LibrePods. |

## Use

```sh
airpods-mode status            # mode, battery, ear detection, conversation awareness
airpods-mode anc | transparency | adaptive | off | toggle
airpods-mode ca on|off
airpods-mode battery
airpods-mode status --waybar   # {"text","tooltip","class","percentage"} for a custom waybar/quickshell module
airpods-mode watch             # live events (mode, battery, ear, you speaking)
```
If both a Pro and a Max are connected, pass `--name pro|max` (or `--mac`, or `AIRPODS_MAC`).
`off` fails with a clear message if the AirPods have "Off" disabled (enable it once from an Apple device). Adaptive is Pro-only.

Hyprland bindings (add to `~/.config/hypr/bindings.conf`; not installed automatically):
```
bindd = SUPER ALT, A, AirPods noise control cycle, exec, airpods-mode toggle
```

## Install / undo

```sh
sudo contrib/omarchy-mac/airpods-control/install.sh              # only /usr/local/bin/airpods-mode
sudo contrib/omarchy-mac/airpods-control/install.sh --with-librepods   # optional GUI (makepkg, ~10 min, needs sudo from a normal user)
sudo contrib/omarchy-mac/airpods-control/install.sh --remove     # removes both
```
Installed paths: `/usr/local/bin/airpods-mode`, optional `pkg:librepods`.

## BlueZ DeviceID (separate, optional, NOT needed)

`bluez-deviceid.sh enable|disable|status [--restart]` sets `DeviceID = bluetooth:004C:0000:0000` in `/etc/bluetooth/main.conf` (backup `main.conf.before-omarchy-mac`, tagged line, exact undo). LibrePods asks for it only for hearing-aid, transparency tuning, rename and multi-device handoff, none of which `airpods-mode` does.
- Changes the SDP Device ID record BlueZ publishes to every remote device, so the Mac claims to be an Apple host. The AirPods cache it at pairing: re-pair after changing it.
- iPhone pairing (stored link key) and NAP tethering (BNEP/PAN) do not read that record, so no breakage is expected, but it is unverified; an iPhone may change what it offers a Mac that says it is Apple. Apply only if `airpods-mode` shows no data, and re-test the iPhone tether afterwards.
- Takes effect after `systemctl restart bluetooth`, which drops the AirPods and any Bluetooth audio for a few seconds.
