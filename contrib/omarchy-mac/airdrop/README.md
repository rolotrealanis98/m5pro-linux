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
