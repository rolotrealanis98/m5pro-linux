# AirPods controls in the Omarchy Bluetooth panel: design note

Status: implemented and unit-tested off the Mac; the QML has never run (no Quickshell here). Written 2026-11-23 against Omarchy `v4.5.0`
(omacom/omarchy, tag, shell version file says `4.0.0.alpha`). Clone with the work: `/Volumes/m5pro/wt/omarchy-shell-airpods`, branch `airpods-controls`, one commit.

## What the owner sees

Open the Bluetooth panel (bar icon). Under a **connected AirPods** row, an extra block shows:

```
󰂱  Rolo's AirPods Pro                              <- stock row, unchanged (click disconnects, right-click, x forgets)
    Left 82%   Right 80% +   Case 100%   ·   In both ears
    [ Off ] [ Transparency ] [ Adaptive ] [ ANC ]      <- current mode lit; click to switch
    Conversation awareness                       (o-)   <- only when the AirPods report it
```
Keyboard: `m` cycles the mode (the AirPods row under the cursor, else the first connected one). The bar icon and the rest of the panel are untouched.
Right/left battery show only for parts that report (a bud in the case still reports). A "+" in the sketch is the Nerd Font bolt (U+F0E7) the panel draws for a charging part.

## Where, and why there

| Place | Decision |
|---|---|
| **Bluetooth panel, under the connected device row** | Yes. It is where a user looks for "my AirPods"; BlueZ already gives us the device, name and connected state; the stock row already shows a single battery value, which AirPods get wrong (it is one number). The change is one new block per connected row, so it is small enough to propose. |
| Audio panel (output device menu) | Not in this change. The audio panel lists PipeWire sinks (`SinkRow`) with its own cursor model; a mode chip there is a second consumer of the same client (`AirPodsClient.qml` is panel-agnostic) and can follow once the Bluetooth one is accepted. Mapping a sink to a BlueZ address already exists in the Bluetooth panel (`bluetoothSinkMatchesDevice`). |
| Bar widget / OSD | Out of scope (the old `airpods-mode status --waybar` stays for people who want a bar module). |
| A separate plugin | No: the owner asked for the native panel; the stock plugin is cloned (`rolo.bluetooth`), not replaced by a new one. |

## One owner of the socket: `airpods-daemon`

AirPods accept one AAP (L2CAP PSM 0x1001) client at a time, so a click must not open a connection. A small **user service** holds it:

```
 Bluetooth panel (QML)  --\                         +--> AAP channel to AirPods #1
 airpods-mode (CLI)     ---+--  $XDG_RUNTIME_DIR/airpods-control.sock  -- airpods-daemon (python3 stdlib, systemd --user) --+--> AAP channel to AirPods #2
 anything else          --/        newline-delimited JSON, mode 0600
                                                      ^ BlueZ: `bluetoothctl devices Connected`, re-read on a dbus-monitor
                                                        "Connected" change and every 15 s
```
Protocol (full text in the daemon's docstring):
- server -> client, on connect and after every visible change: `{"event":"state","devices":{"<ADDR>":{name, model, aap, error, modes[], mode, battery{left,right,case,headphones}, ear[2], conversation_awareness, off_allowed}}}`
- client -> server: `{"cmd":"mode","address":"<ADDR>","value":"anc|transparency|adaptive|off","id":N}`, `{"cmd":"ca","address":..,"value":true|false,"id":N}`, `{"cmd":"state"}`
- server -> requester: `{"event":"result","id":N,"ok":true}` or `ok:false,"error":"..."` (e.g. the "Off is disabled on the AirPods, enable it from an Apple device" case)

Choices:
- **Unix socket, not D-Bus.** Quickshell has a first-class `Socket` client (the shell itself uses one for its IPC) and no general D-Bus client; a socket needs no bus name, no introspection XML and no dependency, and the daemon needs no `dbus-python`. A D-Bus facade (`org.omarchy.AirPods`) can wrap the same state later if other desktops want it; nothing here blocks it.
- **The daemon holds the connection while AirPods are connected**, not per click: battery and ear events are push-only on AAP, and a per-click connect would take ~1 s and fight itself. Idle cost without AirPods: a sleeping python process and one blocked `dbus-monitor`.
- **The panel connects lazily**: only while the panel is open *and* an AirPods device is connected (`AirPodsClient.active`). Closed panel = no socket.
- **`airpods-mode` becomes a client** when the socket exists (same commands, same output, same exit codes), and runs its own connection otherwise, so keybindings keep working either way.
- Per-device worker thread with 2 s to 30 s reconnect backoff; state is dropped to "AAP closed" on disconnect and the UI says "Noise control unavailable" instead of showing stale numbers.
- Model detail: `Pro` offers Off/Transparency/Adaptive/ANC, `Max` Off/Transparency/ANC (single "headphones" battery, no ear row), other AirPods only get battery until they report a mode. Off is hidden when the AirPods report it disabled.

## Degrading for everything else

- **Non-Apple headphones, mice, keyboards:** `Model.isAirPods` is a name test (BlueZ `deviceName` first, so a renamed pair still matches); no match means no client, no socket, no extra item: the panel renders exactly as before. The daemon also never opens a device whose BlueZ Name/alias lacks "AirPods".
- **Omarchy without the service** (every non-Mac, every machine that never installed it): the client never turns on `linked`, `devices` stays empty, the AirPods block is hidden. No error text, no log spam beyond Quickshell's own failed-`connect` line every 4 s while the panel is open with an AirPods connected.
- **Service up, AAP channel not open** (LibrePods holds it, AirPods in the case, handshake failed): block shows only the dim line "Noise control unavailable".
- **Strings:** English fallbacks are inline; the upstream commit adds 18 keys to `default/i18n/en/shell.json`.

## What is in the clone and the repo

Omarchy shell clone (branch `airpods-controls`, base `v4.5.0`, 6 files, +391/-6):
`shell/plugins/panels/bluetooth/{Panel.qml (+58), Model.js (+114, pure functions), AirPodsClient.qml (new), AirPodsControls.qml (new)}`, `default/i18n/en/shell.json (+18)`, `test/shell.d/bluetooth-test.sh (+36, Node tests of the new Model functions)`.
omarchy-mac item `airpods-control` (this folder's parent): `files/usr/local/bin/airpods-daemon` (new), `airpods-mode` (client path added), `files/usr/lib/systemd/user/airpods-control.service` (new), `shell/` (this note, `install-shell.sh`, `bluetooth-panel-airpods.patch`, `upstream/0001-...patch`, `test/`).

## Upstream path (omacom/omarchy)

1. **Issue first** (not opened; owner decides): "AirPods noise control, per-bud battery and ear detection in the Bluetooth panel", linking the protocol source (LibrePods' AAP notes) and showing a screenshot from the Mac.
2. **PR A: the panel half** (`upstream/0001-bluetooth-panel-airpods.patch`, already format-patch, rebases on `quattro`; the file drift to `quattro` is large, so it must be re-made there: the Bluetooth `Panel.qml` is touched by few later commits, `Model.js` additions are self-contained). It is inert without a service: reviewers can accept it as "reads an optional socket", like the other panels' optional helpers. Needs: the socket protocol documented in `docs/` (text above), the 18 keys, the Node tests (done).
3. **PR B (separate, optional): the service.** Either `bin/omarchy-airpods` + a user unit in omarchy-settings, or left to the community plugin ecosystem; the reference implementation is `airpods-daemon`. Omarchy's decision: they may prefer a Quickshell-native service plugin (`kinds: ["service"]`, like `omarchy.battery`) doing the L2CAP in a tiny helper; the panel code does not change.
4. Open points for upstream: AirPods is Apple-specific and the AAP protocol is reverse-engineered (LibrePods), so they may want it behind an opt-in; per-model feature tables (hearing aid, Pro 2 features) are not implemented.

## Risks and what is untested

- QML has never been loaded: no Quickshell on the build host. Risk areas: `Socket` + `SplitParser` client API in Quickshell on the Mac (same classes the shell uses server-side), the `Column` delegate replacing the bare `DeviceRow` in the connected `Repeater`, `ButtonGroup` width in a 380 px panel.
- Verified off the Mac: Node tests of Model.js (`bluetooth-test.sh`, all pass), i18n key coverage and QML Text-format scan, `patch` applies to a pristine v4.5.0 plugin dir byte-for-byte, daemon + `airpods-mode` against a fake AirPods (19 checks).
- Not verified at all: the daemon against real AirPods (the existing `airpods-mode` was verified by the owner today; the daemon reuses its packet code), dbus-monitor trigger, `Restart` behaviour, more than one AirPods connected, conversation awareness echo, ear-detection bud order (shown as a count, not left/right, on purpose).
- Installed Omarchy on the Mac might not be exactly `v4.5.0` (the shell advances); `install-shell.sh --check` tests that the patch applies to the installed files and fails with nothing changed if not.
