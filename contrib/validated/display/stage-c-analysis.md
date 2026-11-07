# Display stage C (J716s, DCP fw 27.3): journal analysis, 2026-11-07

Studio-only. Inputs: logs/stagec-journal.txt (3803 kernel lines, 1.58 s .. 77.25 s uptime), logs/stagec-m1n1.txt, run-stagec.log,
the stage C DTB (t6050-j716s-daily-dcp9c.dtb, decompiled), kernel tree /Volumes/linux-cs/wt-gpu-e1 (3671d907d570), the runtime ADT
(names, sizes and register offsets only below; no serials, no calibration bytes). "Inference" is marked; everything else was read.

## 0. What the run did and did not measure

- Boot: kernel cmdline `drm.debug=0x1e log_buf_len=4M dyndbg="file drivers/gpu/drm/apple/* +p; file drivers/iommu/apple-dart.c +p"`.
  0x1e = DRIVER|KMS|PRIME|ATOMIC (no VBL 0x20). The ring buffer starts at the "Booting Linux" line and the journal ends at the SSH capture
  (77.25 s): **nothing was truncated**. The flood is `pr_publish: id: 119 = 65536` (2053 of 3803 lines, 54 %, one per ~40 ms, forever).
- The journal was captured BEFORE the remote test, so it holds boot only; the test itself produced no usable data:
  - `modetest -M appledrm` is the wrong driver name (drm_driver.name is "apple", apple_drv.c:55): `conn=` and `crtc=` came back empty, no flip ran.
  - `/sys/kernel/tracing` does not exist: **CONFIG_TRACING/FTRACE/EVENT_TRACING/TRACEPOINTS are all unset** in the built config
    (wt-gpu-e1-out/.config; only DYNAMIC_DEBUG, DEBUG_FS). So every `trace_iomfb_*` (swap_submit, swap_complete, callback, push,
    timing_mode, parse_mode_*, brightness, vrr_timestamps) compiled to nothing. The run script's swap counters could never have worked.
  - The backlight "50 %" test wrote 300 into a panel already at 300 (max 600): a no-op. Then it wrote 600 (100 %) and read nothing back.
  - `fault lines: 1` is a false positive: `grep -i "BUG:"` matched `printk: debug: skip boot console de-registration` (journal line 8).
    Real fault grep (DCP has crashed, swap failed, set_digital_out_mode timed out, oops, apple-dart fault, SError, WARNING): 0 hits.

## 1. Every firmware complaint and driver warning (journal order)

Line = journal line. FW = DCP firmware syslog (via RTKit), DRV = kernel driver.

| # | Line | Source | Message | Meaning | Matters? | ADT provides | DT / driver pass-through |
|---|---|---|---|---|---|---|---|
| 1 | 462, 771 | FW ck_PCC2DBlm_v5 | `IOMFB LACS_ERROR: DCP took too long to respond to LAS stats` (2x: before and just after "boot done"; not periodic) | The mini-LED backlight local-dimming module (BLM, "PCC2D") wants ambient-light-sensor ("LAS") statistics from the AP side and gets none. First one is stale iBoot-era ring content (printed before any Linux callback). | Low now (no local dimming / auto-brightness, panel runs uniform); revisit for HDR/EDR peak | disp0 `function-pcc_update` -> /backlight (PCCU), `function-pmu_ram_access` -> /arm-io/smc/iop-smc-nub/smc-pmu, `function-mcc_dataset` -> /arm-io/mcc, /arm-io/i2c5/mogul-las (reg 0x10), /backlight `pcc-table`, `pcc-ramp-time`, `supports-gcp`, `use-cabal`, `use-trinity`, `use-AAB-architecture` | None today. These are AP-side services (macOS functions), not DT data. Only a future ALS/LTS feed could silence it. Do nothing now. |
| 2 | 463 | FW | `BLM LTS data hasn't been read in more than 10 secs` (1x) | Same engine: nobody read its LTS buffer for >10 s (iBoot -> kernel gap). | Low, same as 1 | same | none |
| 3 | 464-465 | FW ap_link | shared memory dva / `DCP heap size 0x1000000 [iBoot:0x1000000]` | Info. | no | - | - |
| 4 | 466 | FW | `Could not find Backlight service` | Firmware looked for its backlight IOService before the AP-service callbacks existed (D207 match_backlight_service is answered later, driver has it). Printed at start_ios, before "Created AP Services" (line 468). | No (backlight works: apple-panel-bl 300/600) | /backlight node, `dcp-brightness-node=1` (firmware-owned backlight) | none; already handled by iomfbep_cb_match_backlight_service |
| 5 | 467 | FW | `Could not find nvram service` | No NVRAM IOService; firmware cannot persist/read its own brightness / True Tone state. | Low (brightness restore across reboot is lost; see #17) | /chosen `nvram-proxy-data`, `nvram-raw`, `nvram-bank-*`, /arm-io/qspi/spinor/anvram | none; Linux nvram path is a separate project (~/Work/agents/nvram-t6050) |
| 6 | 693 | FW ableCompensator | `initial_guess: temperature from SMC not set, using PMU temperature as initial guess: 30.289993286` | The backlight temperature compensator took its start temperature from D401 get_uint_prop obj "SUMP" key "Temperature", which the driver answers with the **hard-coded 3029** (30.29 C; iomfb_template.c:966-979, "TODO: value from j314c"). The number in the log is exactly 3029/100. | Medium-low: compensation always thinks 30.29 C. Fix is real work, not DT | /arm-io/spi4/display-temp-sens1..3, /product `display-temp-compensation` (164 B), disp0 `temperature-compensation`=0 | Driver: replace the constant with a real PMU/SMC temperature (hwmon already exposes ~269 temp inputs, journal shows them "not attached to any thermal zone") |
| 7 | 694 | FW | `Could not find table 'display-backlight-compensation-v1' in registry. Using default table.` | Table lookup by name; the driver serves named blobs through D400 get_data_prop (obj "VORP"), by `of_find_property(dcp_node, key)` (iomfb_v27.c:353-367, cap 0xc00 bytes). No such DT property exists, so the default (uncompensated) table is used. | Low: brightness/temperature calibration not applied; no visible fault | No property of that name anywhere in the ADT. Nearest data: /product `display-temp-compensation` (164 B) (inference: this is its source, unverified); /backlight calibration set: `iDAC2MilliAmpsTable` 1024 B, `milliAmps2DACTablePart1` 512 B, `Part2` 256 B, `nits2mAmps{0,1,2}Coef`, `mA2Nits{0,1,2}Coef`, `calibrated{Max,Mid}Current`, `L{max,mid,min}Product`, `backlight-marketing-table` 68 B, `user-accessible-max-nits`, `EDRPotentialHeadroom` | Experiment only: `display-backlight-compensation-v1 = [<164 B from /product display-temp-compensation>];` on the dcp node (per-unit data: generate in mk-dcp-dtb.py from the ADT, never commit). Success = line 694 disappears and brightness at 600 nits does not change. Risk: wrong format is silently ignored or mis-scales brightness. |
| 8 | 695-698, 712-715 | FW + DRV | `updateFrequencies: minimum-frequency property not found, using getClockFrequency(0)` / `DCP requested undeclared provider clock index 0` (DRV dev_err, iomfb_v27.c:288) / `returned pixelClock = 0` / `EDT ERROR: getClockFrequency(0) (0) < videoClock 521064960! Giving up on frequencies` (2x) | `minimum-frequency` is an EDT (ADT) key via D124 read_edt_data; absent in the ADT, so "not found" is true. The fallback asks D408 getClockFrequency(0). The driver's table is empty (`apple,clock-ids;` -> num_firmware_clocks=0, dcp.c:5197-5208) so it answers 0 Hz. The firmware needs >= videoClock = 3536*2456*120/2 = 521 064 960 Hz and otherwise gives up its frequency/perf-state derivation and runs `perf_state = 5, disp_clock = 677384448` (lines 699-700, its own default). | Medium-low: DVFS/perf state and power are not derived from the clock; display works. Easy to fix, so fix. | **/arm-io/disp0 `clock-ids` = {0x169, 0x1ca}** (the node that owns the pipe the message comes from: UPPipeDCP_H17GSCD). /arm-io/dcp `clock-ids` is empty, which is what the DT copied. /arm-io `clock-frequencies[]` (267 entries) holds the iBoot-programmed video clock 521065000 at index 7 and 24, and 712000000 at 129 (the value Aurora's t6030/t6041 `clk_disp0` uses). The clock-ids 0x169/0x1ca are not indices into that table; the id->rate map is unknown (inference). | DT, see snippet A. Aurora precedent: t8103 `clocks=<&clk_disp0>` fixed 533333328; t600x 237333328; t6030 and t6041-j616c 712000000; t8142-j813 `clkref`+clock-194 (H17P path). Driver: only the index is used (`trampoline_get_frequency_v27`), ids are not compared, so one or two entries both work. |
| 9 | 699-701 | FW | `set_disp_perf_state: video_clock = 521065000, disp_clock = 677384448`, `config_disp_perf_state ... perf_state = 5`, `videoClock is zero, defaulting to 521065000` | Consequence of 8. 521065000 equals ADT clock-frequencies[7]. | Same as 8 | see 8 | After the DT fix, check these lines change or stay; perf state may move below 5 (good: power) |
| 10 | 702 | FW | `Not enabling kIOMFBSupportRelbufInfoCb for clients` | Driver does not implement the release-buffer-info callback. | No | - | - |
| 11 | 720 | FW | `DPTX Generic SDP base index missing` then `Enabling Dynamic SDP allocation ... max_available_sdp_count:1` | Secondary-data-packet base channel is not described for this pipe, firmware falls back to dynamic allocation. The internal eDP link is behind the DP855 TCON inside the firmware; the driver has `num_dptx_ports = 0`. | No (informational; SDP only matters for HDR/VSC packets) | /arm-io/dptx0-aux, dptx1-aux (not the internal link) | none |
| 12 | 723-725 | FW | `load APT M3 IMem 0x9130 / DMem 0x6844 / 0x60b8` | APT (adaptive power/timing) coprocessor firmware loaded OK. | no (good) | disp0 `supports-apt`=1 | - |
| 13 | 727-740 | FW | `ERB: TSQ is not in VBlank ... tsq = 1060 v_blank = 222 ... vbi_pulse is close to end of active ... Early release buffer feature not recommended, check timings for the platform` / `ERB:Early release buffer NOT enabled` | Early-release-buffer (hand the old scanout buffer back before the next vblank) is auto-disabled because its own timing arithmetic fails. The numbers it used differ from the ADT: it used tsq lines 1060, subframe duration 100000 nclks, lead time 15256; the ADT says `subframe-interrupt-time-lines` 0x42a (1066), `subframe-duration-nclks` 0x186da (100058), `display-lead-time-nclks` 0x4adf (19167). **Hypothesis (not proven): D124 read_edt_data returns the firmware's own default for every key** (iomfb_template.c:1406-1419: `value[0]=req->value[0], ret=0`) so the ADT values never reach it. | Low-medium: ERB off costs one frame of buffer-release latency (swap_complete arrives later); no corruption | disp0: `subframe-interrupt-time-lines`, `subframe-duration-nclks`, `display-lead-time-nclks`, `output-fifo-fill-time-nclks`, `output-fifo-fill-time-lines`, `display-timing-info` (8 u32 = fits the 8-word EDT reply), `dot-pitch`, `dot-pitch-float` (0x437e999a = 254.6 ppi), `max-scaling-ratio`, `display-default-color`, `temperature-compensation`, `KSF_version` | Driver: make D124 look the key up (see follow-up D2). First log what keys it asks (the eDP case is not logged: iomfb_template.c:1410 `if (fixed_connector_type != eDP) dev_dbg`). |
| 14 | 741 | FW CAHandler | `load_ca_data: Unrecognized data version 0 (expected 1 or 2)` | The "CA" blob it asked for arrived as zero length/zeros (driver returns success with an untouched buffer when the DT property is missing, iomfb_v27.c:362-364), so version byte 0. CA = colour adaptation (True Tone / white point; ADT has `truetone-shift-a/b`, `default-whitepoint-type` under /backlight). | Low: no True Tone / colour-adaptation tuning | /backlight `truetone-shift-a`, `truetone-shift-b`, `default-whitepoint-type`, `blr-cct-warning`; disp0 `display-default-color`; /product `artwork-display-gamut` | Key name unknown: log D400 keys first (D3). Do not invent a blob. |
| 15 | 754 | FW | `init_power_lut: failed to read power-lut-data-x` | Same mechanism: named blob not supplied, default power LUT. | Low: power-optimisation LUT absent | Not in the ADT under that name (searched all node property names for "lut") | Log D400/D124 key; otherwise leave |
| 16 | 756 | FW | `IOMFB:create_default_fb_surface: Creating default FB surface failed - width = 3456, height = 2234` | The firmware's own default framebuffer surface could not be created. No driver dev_err fired (`unsupported DFB layout`, `invalid default framebuffer dimensions` absent). The driver path that can fail silently is `complete_dfb_surface()` (iomfb_template.c:797-808): the callback is answered `false` whenever the A534 register_dfb_surface reply is non-zero, with no log. The A534 surface descriptor is the 27.2 one; 27.3 grew IOMFBSwap and may have grown the descriptor (unchecked). | **Medium**: the code comment at iomfb_template.c:736-741 says a firmware without a default surface programs the engine from a null base and the piodma DART faults. Scanout works now because every swap carries its own surface, but a blank/clear/idle path could hit it. No DART fault in 77 s. | /chosen has no framebuffer node in this ADT; vram comes from the loader (`dcp handed off: vram 0x10bd15f4000+0x72c4000`, `memory-region` on dcp) | Driver: log the A534 status in complete_dfb_surface and the request; compare descriptor size with 27.3 (follow-up D4). |
| 17 | 770 | FW | `IOMFB: panel charge parity violation [0xfb3fab5]` (1x, 0.4 ms before the first modeset, none afterwards) | LCD charge-balance (polarity inversion) bookkeeping mismatched once while the firmware re-synced the already-running pipe after RTKit handover. Inference: one-shot re-sync artifact. | Low if it stays at 1; **watch for recurrence** (repeats under load would mean flicker/DC-balance risk) | - | none; count it on the next boot after 5 min of fbcon/compositor activity |
| 18 | 776 | FW | `clamshell value is 1` | The firmware's clamshell (lid-closed) flag reads 1 with the lid open. Source unknown (AP-fed or SMC). | Unknown, **check**: if it is the lid state it can make the DCP blank the internal panel when an external display attaches | /arm-io/smc (the kernel registers the SMC lid input device: "Apple SMC power/lid events") | none yet; test with an external display or lid close once |
| 19 | 955 | DRV dev_warn | `backlight restore unavailable: -61` (-ENODATA) | `dcp_backlight_dpms(dcp,true)` at the first CRTC enable ran before any backlight device existed (the fallback registers it 0.95 s later, line 2.564). Pure ordering. | No | - | Driver: treat -ENODATA as silent (dcp.c:4252 `dev_warn` -> `dev_dbg` when ret == -ENODATA) |
| 20 | 2.564 | DRV info | `no loader brightness reported; backlight starts at 300 nits without a panel change` + FW `brightness_changed: brightness value: 19660800` (= 300.0 nits in 16.16) 32 ms later | The fallback registers the class device at max/2 = 300 and reports it; the loader's real level is unknown (no powerlog report, H17G firmware never published pr_publish id 20: 0 hits). The firmware's `brightness_changed` echo suggests the 300 nit level was applied or merely reported - not distinguishable from the log. | Medium for UX: panel brightness after takeover is 300 or iBoot's level, unmeasured | /backlight `user-accessible-max-nits`, `backlight-update-policy`=1, `sync-backlight-off`=1 | Measure: read the panel with a photo/lux at boot before and after the 2.56 s line; test with a level that is not 300 (see section 4) |
| 21 | 453 | DRV | `panel identity fallback: ADT parsed, panel node absent, dimensions 345x223 mm` | The ADT has no top-level `panel`/`product/panel` node; sizes came from the DT panel node (width-mm 0x159=345, height-mm 0xdf=223). The ADT's own `dot-pitch-float` 254.6 ppi gives 344.8 mm, consistent. | No | /product `raw-panel-serial-number`, `artwork-display-gamut`, disp0 `dot-pitch-float` | none |
| 22 | 909-913 | DRV | `no EDID source` then `using firmware-derived EDID metadata`; `Assigning EDID-1.4 digital sink color depth as 0 bpc`; `ELD monitor Apple Panel` | Internal panel has no EDID; a synthesized one is built from firmware metadata. bpc 0 = unknown depth in the synthesized EDID. | Low | - | optional: panel `apple,color-gamut` (below) |
| 23 | 718-762 | FW | `set_run_mode_safe: deferring 2 -> 4`, `Found AFK dict`, `Didnt find export_uuid`, `IOMFB UUID Exporting UUID :0` | Info. | no | - | - |
| - | 2053 lines | DRV dbg | `pr_publish: id: 119 = 65536` every 40 ms | A firmware property publish that never changes (1.0 in 16.16). Pure log noise; proves the firmware thread is alive (no hang) until 77 s. | no | - | filter it (section 3) |
| - | 269 lines | hwmon | `tempN_input not attached to any thermal zone` | SMC/PMU temperature sensors without thermal zones. Unrelated noise, but the source for item 6. | no | - | - |

Not in the list but missing from the DT and read by the driver (found by reading the callbacks against the ADT):

- `apple,artwork-display-gamut` on the dcp node: D204 ideal_screen_space (iomfb_v27.c:430-448) returns 1 when absent, 2 for "P3". The ADT says /product `artwork-display-gamut` = "P3". Stage C DTB has neither this nor panel `apple,color-gamut`. Aurora's j616s/j616c set `apple,color-gamut = "display-p3"` on the panel. Medium (colour management sees the wrong ideal space).
- `apple,iomfb-surfaces` absent: defaults to surfaces {0,1} (journal shows plane-0 and plane-1). Fine.

## 2. Swaps after the mode set

Facts from the journal (all `apple-drm display-subsystem`, drm.debug atomic lines; apple-drm only):

| t (s) | event | blocked for | reading |
|---|---|---|---|
| 1.593162 | `dcp_hotplug() connected:1 valid_mode:0 nr_modes:0`, then `nr_modes:6` at 1.609731 | - | connector eDP-2 (id 49) appears |
| 1.614 | simpledrm FB:40 removed, its CRTC and connector eDP-1 removed | - | handover from simpledrm (CRTC disable of simpledrm is not a scanout change) |
| 1.618131 | atomic commit 1: full modeset, `set_digital_out_mode(color:1 timing:2) "3456x2234": 120 1042130 ...` | 1.2 ms | firmware answered `Already set to timingID: 2 colorID: 1. 3456x2234 link: 1`: **no retrain, the 120 Hz timing iBoot left running was adopted**; `finished with 8500 to spare` (not a timeout) |
| 1.620511 | commit 2 (fbdev pan, FB:52, plane-0) | 0.15 ms | sub-ms: either a swap acked at once or the early-return fake vblank (iomfb.c:3470-3476, `schedule_work(&dcp->vblank_wq)`); not distinguishable |
| 1.621879 | commit 3 | 0.07 ms | same |
| 1.620812 | `Console: switching to colour frame buffer device 432x139` (3456/8 x 2234/16) and 1.622174 `fb0: appledrm frame buffer device` | - | **fbcon took over eDP-2** |
| 1.889667 | commit 4 (VT/console activation, plane-0 FB:52, CRTC and connector re-linked) | 0.09 ms | as 2 |
| 1.891464 | commit 5 | **16.5 ms** | a vblank-paced flip: DRM waits for the CRTC event which only a swap completion (or fake vblank work) sends; 16.5 ms = 2 frames at 120 Hz |
| 1.909213 | commit 6 | **14.9 ms** | same |
| 1.957142 | commit 7 | **18.9 ms** | same |
| 8.950185 | commit 8 | 0.14 ms | idle console blank/unblank |
| 8.9 .. 77 | no commits | - | nothing drew: no compositor, a static console |

So: 8 atomic commits (1 modeset + 7 plane commits); >= 3 of them waited one to two 120 Hz frames for completion, with no `swap failed`, `swap_start was rejected`, `overlapping present`, `unexpected present submission`, `firmware aborted present`, `unexpected busy command channel`, `clear swap timed out`, `DCP has crashed` or DART fault. That is consistent with swaps being accepted and completed, but it is **not proof**: success paths are silent. Swap submit/complete are tracepoints only (compiled out), no vblank line was enabled (drm.debug 0x20 missing), and `set_digital_out_mode` had nothing to do (already in timing 2). Frame count after the modeset cannot be stated; best statement: 3 flips confirmed blocking-and-completing, 4 sub-ms commits undetermined, 0 frames known from vblank/swap counters.

## 3. dyndbg / debug subset for the next boot

Keep (cmdline; replaces the current one):

```
drm.debug=0x06 log_buf_len=16M
dyndbg="file drivers/gpu/drm/apple/dcp.c +p; file drivers/gpu/drm/apple/iomfb.c +p; file drivers/gpu/drm/apple/iomfb_template.c +p; file drivers/gpu/drm/apple/iomfb_v27.c +p; file drivers/gpu/drm/apple/apple_drv.c +p; file drivers/gpu/drm/apple/dcp_backlight.c +p; format 'pr_publish: id: 119' -p; file drivers/iommu/apple-dart.c +p"
trace_event=dcp:iomfb_swap_submit,dcp:iomfb_swap_complete,dcp:iomfb_callback,dcp:iomfb_timing_mode,dcp:iomfb_brightness,dcp:iomfb_color_mode,dcp:iomfb_vrr_timestamps trace_buf_size=8M
```

- drm.debug bits: 0x02 DRIVER, 0x04 KMS, 0x08 PRIME, 0x10 ATOMIC, 0x20 VBL; the old 0x1e was DRIVER|KMS|PRIME|ATOMIC. 0x06 is enough; drop ATOMIC (~25 lines per commit, a flood the moment a compositor runs at 120 Hz). Turn atomic and vblank on only around a test: `echo 0x36 > /sys/module/drm/parameters/debug` (0x20 = VBL).
- The `format ... -p` after the broad `+p` disables just the id-119 line (dyndbg commands apply in order). Safer: add `case 119: break;` next to `case 20` in iomfb_cb_pr_publish (iomfb_template.c:921).
- `trace_event=` needs **CONFIG_FTRACE=y, CONFIG_TRACING=y (EVENT_TRACING follows)**; add to j716s-dcp.config. Then `cat /sys/kernel/tracing/trace` holds swap_submit/swap_complete with ids from boot. Without this rebuild, add `dev_dbg` lines instead (D5).

## 4. Follow-ups, ranked by impact

Impact = what it unblocks or what is wrong on screen; effort in brackets.

### Measurement/tooling (blocks every conclusion) [small]
1. Rebuild with `CONFIG_FTRACE=y CONFIG_TRACING=y` (append to aurora/j716s-dcp.config) so the dcp tracepoints exist; boot with the cmdline of section 3.
2. Fix run-stagec.sh: `modetest -M apple`; resolve CONN/CRTC with `-c`/`-p`; run `modetest -M apple -s CONN@CRTC:3456x2234-120 -v` and read the reported flip frequency (page-flip events: expect ~120.00 Hz); capture the journal AFTER the test; backlight test must write a level != current (e.g. 150, then 450) and read `actual_brightness`, with a `brightness_changed` journal line as the proof; `grep -w "BUG:"` (not -i) for the fault scan.
3. Add to the same script: `cat /sys/kernel/debug/dri/1/state`, `/sys/class/drm/card1-eDP-2/{status,enabled,dpms}`, and a photo/lux note by a human for "panel actually lit at the right level".

### DT additions (stage-C DTB generator, mk-fixed9.py / mk-dcp-dtb.py) [small each]
A. Firmware provider clock (removes lines 8, 9; low risk):
```
/ {
	clk_disp0: clock-disp0 {            /* sibling of clock-ref, as t6030-dcp.dtsi / t6041-j616c.dts */
		compatible = "fixed-clock";
		#clock-cells = <0>;
		clock-frequency = <712000000>;  /* >= 521064960 videoClock; alt: 521065000 = ADT clock-frequencies[7] */
		clock-output-names = "clk_disp0";
	};
};
dcp@48ae00000 {
	clocks = <&clk_disp0>;
	apple,clock-ids = <0x169>;          /* ADT /arm-io/disp0 clock-ids = <0x169 0x1ca>; only index 0 was requested */
	/* replace the empty `apple,clock-ids;` */
};
```
   (If both ids are kept, add a second fixed clock; driver only checks `count(clocks) == count(ids)`, dcp.c:5203-5206.) Verify next boot: the three FW lines and the dev_err vanish, `set_disp_perf_state` values logged; if `perf_state` drops, confirm no flicker at 120 Hz.
B. Gamut (colour correctness):
```
dcp@48ae00000 {
	apple,artwork-display-gamut = "P3";   /* ADT /product artwork-display-gamut; D204 now returns 1 */
	panel {
		apple,color-gamut = "display-p3"; /* as t6040-j616s.dts, t6041-j616c.dts */
	};
};
```
C. `adj-height-mm = <216>;` on the panel only if the notch is hidden (loader log: notch rows kept, so not needed now).
D. Experimental, per-unit, never committed: `display-backlight-compensation-v1` from /product `display-temp-compensation` (see row 7), only after follow-up D3 shows the key and size the firmware asks for.

### Driver fixes [file:function]
D1. `iomfb_template.c:iomfb_cb_pr_publish` - ignore id 119 (log flood).  [trivial]
D2. `iomfb_template.c:dcpep_cb_read_edt_data` (1406-1419) - (a) log every key/count for eDP too (drop the `!= eDP` condition) once per key; (b) then answer from a DT table: look the key up as a u32 array on the dcp node (or a `apple,edt` child) and return up to `count` words with `ret = 1`, keeping the echo-default for unknown keys. Candidate keys from the ADT: `subframe-interrupt-time-lines`, `subframe-duration-nclks`, `display-lead-time-nclks`, `output-fifo-fill-time-nclks`, `output-fifo-fill-time-lines`, `display-timing-info`, `dot-pitch`, `max-scaling-ratio`. Expected visible change: ERB lines 13 show 1066 lines / 100058 nclks / 19167 nclks. If ERB then enables, watch swap completion timing. [small + one boot]
D3. `iomfb_v27.c:trampoline_get_data_prop_v27` (353) and `iomfb_template.c:dcpep_cb_get_uint_prop` (961) - dev_dbg the `obj`, `key`, requested length, found/not found. This names the CA blob and the power-lut property and tells whether `display-backlight-compensation-v1` goes through D400 at all. [trivial]
D4. `iomfb_template.c:complete_dfb_surface` (797) and `iomfbep_cb_create_dfb_surface` (809) - log the A534 status word and the size; compare the 27.3 register_dfb_surface surface descriptor with `struct dcp_h17p_dfb_surface_req` (0x230). Explains row 16. [small]
D5. `iomfb_template.c:dcpep_cb_swap_complete` (704) and `dcp_swapped` (3094) - `dev_dbg("swap %u submitted/completed")` for builds without tracing. [trivial]
D6. `iomfb_template.c:dcpep_cb_get_uint_prop` (961-979) - replace the 3029 constant with a real temperature (SMC/PMU hwmon). [medium]
D7. `dcp.c:4252` (`dcp_backlight_dpms` caller) - silence -ENODATA. [trivial]
D8. `parser.c:parse_mode` (~944) - `dev_dbg` per mode: id, rate, vrr_seen, min_vrr, max_vrr, result (the tracepoints that carry this are compiled out). [trivial]
D9. VRR: see section 5; apply contrib/pending/dcp/vrr/patches/on-promotion/0002 when VRR is tested.

### What must be measured on the next boot
1. Trace/dmesg: `iomfb_swap_submit`/`iomfb_swap_complete` counts and ids during `modetest ... -v` at 120 Hz; flip frequency reported by modetest; submit->complete latency (1 frame = 8.3 ms; 2 frames if ERB stays off).
2. After DT A: the 5 lines of rows 8-9 gone; `perf_state` value; idle power (wattmeter or SMC) with the panel at a fixed level compared with the previous kernel.
3. After DT B: nothing visible in dmesg; compare colours of a P3 test image (modetest `-P`/kmscube pattern) before/after.
4. D2/D3 keys: the set of D124/D400/D401 keys requested, counts and lengths -> decides DT work for rows 7, 13, 14, 15.
5. Brightness: the real iBoot level before 2.56 s (photo of the lock-screen-free fbcon at a known low macOS level - TEST-PLAN 0c) and the response of `brightness_changed` to writes of 150/450 (not 300).
6. Recurrence count of `panel charge parity violation` and `LACS_ERROR` over 10 minutes with a moving image; any `swap failed`, `DCP has crashed`, apple-dart fault.
7. Lid/clamshell (row 18): close the lid (suspend aside, just the lid switch) and attach an external display; note whether eDP-2 goes dark.

## 5. Modes: driver vs firmware

Journal (drm probe, apple_drv ELD "Apple Panel"):

| # | refresh | clock kHz | htotal x vtotal | flags | type | firmware timing id (from the VRR/promotion static analysis, `vrr/REPORT.md`) |
|---|---|---|---|---|---|---|
| 1 | 120.00 | 1042130 | 3536 x 2456 | +hsync +vsync (0x5) | DRIVER|**PREFERRED** (0x48) | 2 (confirmed: `set_digital_out_mode(color:1 timing:2)`) |
| 2 | 60.00 | 521065 | 3536 x 2456 | 0x5 | DRIVER (0x40) | 3..7 "IsPromoted" |
| 3 | 59.94 | 520544 | 3536 x 2456 | 0x5 | 0x40 | " |
| 4 | 50.00 | 520853 | 3536 x 2946 | 0x5 | 0x40 | " |
| 5 | 48.00 | 416852 | 3536 x 2456 | 0x5 | 0x40 | " |
| 6 | 47.95 | 416435 | 3536 x 2456 | 0x5 | 0x40 | " |

- All six are 3456x2234 (notch rows kept: loader `asahi,show-notch=1`); hsync_start 3464, hsync_end 3496; vsync_start 2352, vsync_end 2360 (the 50 Hz one 2842/2850). Clock arithmetic checks out: 3536*2456*{120,60,48} and 3536*2946*50, and the 59.94/47.95 entries are the /1.001 rates. The six names are identical ("3456x2234"); sysfs `modes` lists the same string six times (run log). Userspace must pick by refresh (modetest prints it).
- Preferred = the 120 Hz timing, which is also what iBoot left active, so the first modeset was a no-op for the firmware.
- No TimingElements dictionary lines exist in this journal (no dev_dbg prints them; the `trace_iomfb_parse_mode_*` tracepoints are compiled out), so a direct line-by-line comparison with the published dictionary is not possible from this boot. The static firmware analysis (`vrr/REPORT.md`) lists the same six timings (ID 2 = 120 Hz preferred, IDs 3-7 = 60, 48, 59.94, 47.952, 50) with all Min/MaximumVariableRefreshRate = 0: this matches.
- vrr: `set_digital_out_mode() ... range:0 vrr:0` (`range` is the colour range, not a refresh range). With vrr=0 for the 120 Hz timing, `connector->vrr_capable` is 0 and `monitor_range` min/max_vfreq stay 0. Cause in code: firmware publishes zero min/max, so `vrr_seen==3`, and for firmware 27.x `ctx->zero_vrr_range_fallback` is false (iomfb.c:1979, true only for desktop 26.6), so `dcp_refresh_range(..., internal && vrr_fallback)` never applies its 24-120 Hz default (dcp-refresh.h). `needs_timestamps` is still true for the 120 Hz timing (`internal && dcp_refresh_is_promotion`), so `dcp->use_timestamps` = true and swaps carry the three timestamp words; those sit at the start of IOMFBSwap, before GAP0 (0x98), so the 27.3 re-layout does not move them (iomfb_v27.h).
  Expected, not a bug: V0 of the VRR plan ("vrr_capable 0 on the default boot"). VRR needs vrr/patches/on-promotion/0002 plus `appledrm.fw27_panel_vrr=1`.
