# airpods-control / shell: Mac-side install of the panel controls

Read `DESIGN.md` first. Two layers, installed separately:

1. **Root item** (`../install.sh`): `/usr/local/bin/airpods-mode` (updated), `/usr/local/bin/airpods-daemon`, `/usr/lib/systemd/user/airpods-control.service`. Starts nothing.
2. **Panel clone** (`install-shell.sh`, as the desktop user): `~/.config/omarchy/plugins/rolo.bluetooth/` = stock `omarchy.bluetooth` + `bluetooth-panel-airpods.patch`. Staging touches no running process; `--enable` and `--remove` hot-swap the Bluetooth panel in the running shell (**plugin reload, not a shell restart; owner approval needed first**).

Nothing here restarts the Omarchy shell, PipeWire, WirePlumber or Hyprland. The daemon takes the single AAP connection: close LibrePods first.

## Install (on the MacBook, from a copy of `contrib/omarchy-mac/`)

```sh
sudo bash airpods-control/install.sh                                   # files only
systemctl --user daemon-reload && systemctl --user enable --now airpods-control.service
airpods-mode status                                                    # now answered through the daemon (AirPods connected)
bash airpods-control/shell/install-shell.sh --check                    # read-only: the patch must apply cleanly to the installed plugin
bash airpods-control/shell/install-shell.sh --stage                    # builds the clone, loads nothing
# owner-approved shell step: **reloads the Bluetooth panel in the running shell**
bash airpods-control/shell/install-shell.sh --enable
```

## Undo

```sh
bash airpods-control/shell/install-shell.sh --remove                   # **reloads the panel back to stock**; clone kept as a hidden .rolo.bluetooth.bak.* folder
systemctl --user disable --now airpods-control.service
sudo bash airpods-control/install.sh --remove                          # removes the daemon, unit and the airpods-mode changes (original comes back from .before-omarchy-mac)
```
Without the daemon `airpods-mode` works as before. `enable` edits `~/.config/omarchy/shell.json` (the shell swaps `omarchy.bluetooth` for the clone); `omarchy-shell-config`'s install overwrites that file and would undo the swap: re-run `--enable` after it, and capture the new `shell.json` into that item if the owner keeps the panel.

## Checks without Bluetooth (any machine with python3)

```sh
python3 -I shell/test/daemon-fake-aap-test.py          # 19 PASS: state, mode, ca, off refused, push to other clients, CLI via daemon, name filter
```
Panel logic (Node): in the Omarchy clone `CDPATH= bash test/shell.d/bluetooth-test.sh`.

## Files

| File | |
|---|---|
| `DESIGN.md` | design note, upstream plan, risks |
| `install-shell.sh` | `--check`, `--stage`, `--enable`, `--remove` (user) |
| `bluetooth-panel-airpods.patch` | diff of the plugin dir `v4.5.0` -> clone branch (applied with `patch -p5`) |
| `upstream/0001-bluetooth-panel-airpods.patch` | the same as a full commit incl. i18n keys and tests, for a PR against omacom/omarchy |
| `test/daemon-fake-aap-test.py` | fake-AirPods test of daemon and CLI |

## What to fetch from the Mac to confirm the version (read-only)

`/usr/share/omarchy/shell/plugins/panels/bluetooth/{Panel.qml,Model.js,manifest.json}` (v4.5.0 sha256: Panel.qml `1e03d3ae942f4fe095a57252d1f8253a4de269428bc5444b75ac30da84e1b269`, Model.js `b34f3259c6553f20ce37619d2f390cd3293303266f89f2a6df0b6810da384417`, manifest.json `c15c51ab8a6cb82df8ebe3a5195b8d69c69d2ff9bbd00d748204d81a3ddc1d8a`), `/usr/share/omarchy/version`, `pacman -Q omarchy quickshell`, `ls ~/.config/omarchy/plugins`, `~/.config/omarchy/shell.json`.
