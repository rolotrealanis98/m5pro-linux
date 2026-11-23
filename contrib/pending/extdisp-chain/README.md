# extdisp-chain: the three ledger rows behind external displays (offline, 2026-11-23)

Rows: `soc.dp-muxes-retimers`, `audio.hdmi`, `desktop.external-displays-shell`. Nothing here was booted. Branch
`j716s-extdisp-chain` (worktree `/Volumes/m5pro/wt/extdisp-chain`, local) = `j716s-t2-hdmi` (`28d018f6fade`) + 3 commits (tip `db1ac6b01504`).
Test request: `/Volumes/m5pro/bench/requests/extdisp-chain-1.md`. Build results: "Builds" at the end.

## soc.dp-muxes-retimers

| piece | finding | action |
|---|---|---|
| DP crossbar `atc2-dpxbar` (and atc0/1/3) | The row is stale. The ADT compatible is `atc-dpxbar,t6050` + `atc-dpxbar,t8142` on all four; our DT has `apple,t6050-display-crossbar` + `apple,t8142-display-crossbar` for all four (`t6050-die0.dtsi:354` atc2, `t6050-peripherals.dtsi` atc0/1/3); `drivers/mux/apple-display-crossbar.c` matches both (`apple_dpxbar_ids`, T6050 entry with `status_log_only`); the binding `apple,display-crossbar.yaml` lists the two-item form. The old "failed to match any schema" lines in earlier dtbs_check logs predate the binding entry. The J716s DT enables atc2/atc1 crossbars through `t6050-j714s-display.dtsi` (already included by `t6050-j716s.dts`) and atc3 in the HDMI DTB. | none needed; upstream #1515's right-port crossbar is the same node |
| `atc*-dpin0..3` (DP IN adapters) | Described: 16 `apple,t6050-dpin` nodes (`t6050-peripherals.dtsi`), binding `display/apple,dpin.yaml`; the router's `dpinN` interrupts are wired for ATC2 in `t6050-j714s-display.dtsi` (`&acio2`). Their driver is the Thunderbolt connection manager (`apple-dpin-state.c`), only live with a tunnel (usb.thunderbolt). #1692 (T6020 retry) does not touch T6050. | none; needs a TB display (not tested) |
| retimers `uatcrt0..2` | i2c6 0x18/0x19/0x1a, ADT compatible `atcrt` only, macOS driver `AppleTypeCRetimer` (user-client i2c, i2c speed word 0x9c4), no interrupt, no gpio. No chip name, register map or firmware in any artifact we hold; Linux's `typec/retimer` class has no consumer for it. Nothing in the kernel needs them for USB 40 Gb/s (USB4 core's retimer scan finds none, harmless), only TB5 80 Gb/s / DP2.1 UHBR links would. | **infeasible offline**: unknown part and protocol; would need an I2C trace of macOS under the hypervisor with a TB5 device. Left as is. |
| `pcon0` (i2c8 0x08) | HDMI converter side channel, no compatible; the M4 boards drive HDMI without it. | not described (as before) |

## audio.hdmi

- macOS 27.3 ioreg: `dp-audio2` -> `dart-dispext1-isoc` (0x392180000) + `admac-dispext1` (0x392140000, compat `admac,t6050`),
  power gate 81, `mapper-dispext1-dpa`. dcpext1 is the HDMI engine (extdisp-1.md), so HDMI sound is dp-audio2, **not** dp-audio1
  (extdisp-1.md's "dp-audio1 = dcpext1's audio" was wrong: dp-audio1 is dispext0's). dp-audio1 = dcpext0 = USB-C engine.
- The driver side already exists and needs no code: `drivers/gpu/drm/apple/audio.c` + `av.c` (desktop audio role,
  `dcp_av_audio_cmds_v27`), `apple,t6050-dpaudio` (binding `sound/apple,t6030-dpaudio.yaml`), `apple,t6050-display-admac`
  (`drivers/dma/apple-admac.c`), and aura already copies the control-block tunables for `admac-dispext1-control`
  (`dt_set_admac_control_tunables()`, engines disp0, dispext0..3).
- Missing, and now added (commit `a221b675fe8e`): `DISPEXT1_ADMA` pmgr node @0x2d8 (ADT power device 81; the coverage
  manifest said MISSING), the ADMAC/DART moved into it with the display-ADMAC compatible, window and control alias (dispext0's
  recipe, `b8e6029323c7`), `dpaudio2` linked to dcpext1 port 0 in the HDMI DTB; the HDMI DTB also includes the J714s file
  for dcpext0's DPA (USB-C DP audio).
- Config: `j716s.config` had `# CONFIG_DRM_APPLE_AUDIO is not set` (a leftover of the first DCP bring-up, when SND was a
  module). SND is `=y` here now, so `CONFIG_DRM_APPLE_AUDIO=y` (commit `b267ed097666`): without it no dpaudio would bind.
- Not done: dp-audio3/4 (dispext2/3, DPA for dcpext2/3: the right USB-C port's engine, if the crossbar allocates it),
  HDMI 2.1 FRL, audio over DP tunnels. Upstream reports hardware audio "unqualified" (#729 is J616s only, SIO based).
- Expected on boot: `apple-dcpaudio` / `apple-dpaudio` lines, no ALSA card until a sink with audio connects (the card is
  created at DPA bind: `dcpaud_init_snd_card()`, card slot >= 8, name from the sink), jack + ELD control on hotplug.

## desktop.external-displays-shell (clamshell)

- `FramebufferDCP.cpp:4846: clamshell value is 1` is printed by the **DCP firmware** (RTKit syslog), once per DCP boot, in every
  capture we hold (21 occurrences, always 1, always with the lid open; the Windows consoles saw the same). Nothing in the
  Linux tree contains the string or reads the SMC lid state into the DCP.
- Where it comes from: the line lands right after "DCP booted" and right before our "DCP is_main_display" callback. That is
  where the H17 client-open sequence runs `... A474 A478 A476(1) A478 A412` (`iomfb_template.c` `dcp_client_open_run`,
  `DCP_STEP_A476`; A412 is `is_main_display`). A476 is the one-u32 method whose own source comment says "the firmware expects
  this to be 1; fits set_dcp_clamshellstate()". macOS sends the same A476(1) on every DPMS off/on and sleep sequence with the
  lid open (`dcp.c` s2r comment, measured on T8140; `iomfb_template.c` for the H17 table). So the value in the log is the **1 Linux itself sends**, and 1 is what macOS
  sends with the lid open: it is not a lid-closed report. Evidence: call order and the single occurrence per boot; not
  proven (no firmware disassembly, no capture with a different value).
- Consequence for the blanking worry: the internal panel's DCP never sees an external display attach (each external display
  has its own DCP firmware: dcpext0..3); the only shared piece is the display crossbar. Linux sends nothing lid-related to the
  internal DCP, so lid-open behaviour is whatever DRM/userspace does. The userspace side: logind `HandleLidSwitchDocked=ignore`
  (`contrib/omarchy-mac/lid-sleep-s2idle`), systemd treats a connected non-internal DRM connector (HDMI-A) as docked (to be confirmed on hardware);
  Omarchy ships `omarchy-hyprland-monitor-clamshell` (not read here) for the closed-lid case.
- What Linux should send with the lid closed is **unknown**: probably A476(0) (never captured), and wiring SW_LID from
  `macsmc-input` to it is a guess that could blank or wedge the panel. Not implemented. A closed-lid macOS trace
  (`hv` under macOS: close lid with an external display, watch A476) would settle it.
- Test (in the request): with the display attached and the lid open, `eDP-1` stays connected and lit, `clamshell value`
  lines count and values, no `DPMS`/blank on the internal DCP.

## Builds and checks (2026-11-23, all offline)

- **Container build of `j716s-t2-hdmi` (`28d018f6fade`)**, the one t2-stack-1 only host-compiled: `build-next.sh WT=t2-hdmi` BUILD OK
  `7.3.0-g28d018f6fade`; Image.gz, `t6050-j716s.dtb`, modules; `modules-missing.txt` and `modules-unsigned.txt` empty; no warning in
  drm/apple, macsmc or the DTs (only Rust deprecation warnings elsewhere). Results `/Volumes/m5pro/bench/pr-verify/kbuild-t2-hdmi/`.
  Not covered by it: the HDMI DTB (host dtc built it) and KUnit (not run).
- **Container build of `j716s-extdisp-chain` (`db1ac6b01504`)**: BUILD OK `7.3.0-gdb1ac6b01504`, `kbuild-extdisp-chain/`, modules empty-missing/unsigned,
  `CONFIG_DRM_APPLE_AUDIO=y` and `audio.o`, `av.o`, `apple-admac.o` compiled without warnings. The everyday `t6050-j716s.dtb` differs from
  t2-hdmi's only by the new disabled nodes and renumbered phandles. KUnit not run.
- DTB: host dtc reproduces the kernel-built everyday DTB byte for byte, so `t6050-j716s-hdmi.dtb` (sha `9f892705...`) is trustworthy.
  `dt-validate` (dtschema, pip, scratchpad venv) on the HDMI DTB: no finding on the new audio, ADMAC, DART or pmgr nodes; the `gpio-pcio` finding
  is fixed by the binding commit. Still reported, not ours to fix here: `typec0-dpin2/3`, `typec1-dpin2/3` mux names (upstream #1515's
  `t6050-j714s-display.dtsi` outruns `apple,dcp-typec-routes.yaml`), `pcie port0`, `apple,internal-panel`, dwc3 `iommus`; dtc warns about the
  ANE's duplicate `reserved-memory/ane-firmware-*@0` (from the ANE branch under this base).
- Test boot packed: `extdisp-chain-20261123-e640221b.bin` (loader `aura-j716s-s2r-ext-cam2-nohostwait.bin`, never booted), request `extdisp-chain-1.md`.

## Not done / infeasible

- Retimers (`uatcrt0..2`): unknown part and firmware, see above.
- Closed-lid behaviour: needs a macOS capture of A476 with the lid closed and an external display; SW_LID to DCP is not wired.
- DPA for dcpext2/dcpext3 (dp-audio3/4), HDMI 2.1 FRL, audio on DP tunnels.
- A loader with the external-engine handoff on top of the current daily loader (`j716s-camera-1`): aura `6ad04ef3` + `bfb36556` are only in the
  s2r lineage; cherry-picking them onto `j716s-camera-1` would be aura work, not done (outside the kernel branch rule).
