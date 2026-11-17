# airdrop

AirDrop on the J716s, using the N1's own firmware AWDL. The research, ranked options and plan are in
`/Volumes/m5pro/bench/requests/airdrop-1.md`.

- Scope: `t6050`. Status: experimental (built, not booted). Upstream: aurora-silicon/linux (centauri), later an Owly radio backend
  (t4t5/owly `owly-radio::Backend`) and the Omdrop Omarchy plugin for the UI.
- `aci-probe.py`: talks to the firmware's AWDL (interface 1) and NAN (interface 2) through the centauri debugfs probe.
  - `caps` works on any centauri kernel and is read-only. It decodes the firmware's AWDL defaults, which are already in the station's
    system capabilities reply.
  - Everything else needs kernel branch `j716s-airdrop-aci` (commit `8b3e07c68dbf`, on j716s-touchid), plus
    `aci-probe.py enable`.
- Nothing is installed on the Mac and nothing is enabled. The probe changes nothing until root sets
  `/sys/module/apple_centauri_t6050/parameters/aci_debug` to 1.
- Safety: on interface 0 (wlan0) the kernel accepts only read-only queries. A firmware command that times out takes the whole Wi-Fi
  function down until a reboot, so run the write commands (`configure`, `start`, `stop`, `send`) only with a second way into the machine
  (USB Ethernet).
- Undo: none needed. To stop, run `aci-probe.py stop` and then `aci-probe.py disable`.
- `fallback/taildrop-receive.sh --user NAME [--dry-run|--remove]` (root) gives iPhone <-> Mac sharing that works today on any network.
  It runs the two steps of Omarchy's own Tailscale install that a hand-installed Tailscale skipped: `tailscale set --operator=NAME`
  and enabling the stock user unit `omarchy-tailscale-receive.service`, which saves Taildrop files to `~/Downloads` and notifies.
  After that, the iPhone shares through the share sheet > Tailscale, and the Mac sends with `omarchy tailscale send`. LocalSend is
  already wired into Omarchy's menu (Trigger > Share). Staged, not applied (the dry run was checked on the Mac). Findings and the
  awdl0 design are in `/Volumes/m5pro/bench/requests/airdrop-2.md`.
- M1b (2026-11-17, next7 kernel). The firmware accepted AWDL on interface 1: GetSystemCaps, configure and start all returned 0, and
  availability-window events ran on channel 6 next to the station. About 11 s later the firmware halted (stage 3), wlan0 dropped, and
  the run's watchdog rebooted the Mac. The cause is not captured yet. Results and the next step (capture the crash log, then start
  with all nine TLVs as macOS sends them) are in `/Volumes/m5pro/bench/requests/airdrop-3.md`. Do not run `start` outside an
  attended session with a Wi-Fi watchdog.
- M1c (kernel branch `j716s-airdrop-m1c2` = j716s-next7 + `09d76e17d60b`, test file `airdrop-m1c2-test-20261117-f836807f.bin`; built, not booted. The first build on next7b is superseded because next7b does not boot). With `aci_debug`, the kernel saves
  the firmware crash log on a halt: the crash-log tables named in the control function's config space, plus the Wi-Fi segments
  read through BAR4. It also keeps AWDL/NAN management frames in debugfs `aci_frames`.
  - `n1-crashlog.py DIR [FTAB]` decodes a saved halt against the firmware's assert database (the ftab `_wfa` entry, read in place)
    into "ASSERT file.c-line" lines.
  - `aci-probe.py start --full --seq 149|6+149|default` sends all nine start blocks as macOS does; `frames`, `halt` and `save DIR`
    are new.
  - Status 347 (`AciWifiTlvsParsingFailed`, airdrop-6): the firmware's sync-parameters TLV (ff04) takes only channel-sequence
    encodings 0/1, flags without 0x800/0x200, and fixed AW/extension values; our ff04 carried encoding 3 (and, in "air" form, flags
    0x1800). `start --full` now sends macOS's fresh-start blocks by default (the firmware's own 71-byte ff04, no ff12), checks every
    payload against the firmware's TLV rules first (`fw_check`) and refuses to send one it predicts 347 for. `--caps FILE --dry-run`
    runs the check offline.
  - `retest/m1c-retest.sh` runs the retest from the Studio. A watchdog reboots only when Wi-Fi *and* the wired link are both down
    for 90 s. A mirror unit saves events, frames and any halt to `/root` every 2 s. `--collect STAMP` fetches and decodes after a
    reboot.
