# DCP on the J716s (M5 Pro, T6050): what Aurora PR #1012 needs, and whether to try it

Studio-only research, 2026-11-06. Nothing was built, booted, pushed or written to the MacBook. The DCP firmware was
read in memory only (header and version strings); no copy of it exists anywhere.

## Verdict (five lines)

1. PR #1012's display path is 12 C commits that cherry-pick onto our `aurora-j716s` tip `6d9f1ec652a6` with one trivial conflict. The 13 patches in `patches/kernel-dcp/` pass `git apply --check` in sequence.
2. The driver matches `apple,firmware-compat` exactly `"27.0.0"` (`dcp.c:4942`) and has one IOMFB method table. Our stub's DCP firmware is **AppleDCP-1317.60.10, SDK 27.3 (26C5035e)**: an ABI Aurora has never run. Aurora's own loader refuses everything but 27.0 and 27.2, and 27.2 alone already renumbers the methods.
3. Our m1n1 publishes nothing for T6050: it prints "unknown compatible" and has no 27.x firmware entry. Draft `0024` adds three things. First, a guarded read-only check of the DCP and DART state. Second, an opt-in handoff in Aura's shape. Third, the `__OS_LOG` reservations. These matter today: five running coprocessors write their logs into RAM Linux treats as free.
4. **Go** for stages A, B0 and B below. In those stages the honest compat makes the driver refuse at probe, before it touches the DCP, and simpledrm stays. **No-go** for driving the panel (stage C) until there is a 27.3 method table, or the stub is re-paired to 27.0, and the internal bandwidth-scratch offset is measured.
5. Worst realistic outcome of B is a black or garbled panel until a cold reboot. There is no plausible mechanism for panel damage. The DCP path does not touch the network, so SSH and the self-revert loop still work, but the loop cannot fire if the kernel stops before the root filesystem mounts. Run B with Rolando present.

## Sources

| Name | What | Revision |
|---|---|---|
| PR | aurora-silicon/linux #1012 (open) `funkzy/t6050-gpu-on-integration` | `d078ca18fa45`, merge base `11eccbedc3ed` (ancestor of our INT `33bec4016c46`, 236 commits behind it) |
| PICK | `/Volumes/linux-cs/wt-dcp-aurora`, branch `dcp-aurora-pick` (local only) | `6d9f1ec652a6` + 13 commits = `fe60b4615e4e` |
| AURA | aurora-silicon/aura `main` | `671c0cefdb39` (`ref/aura/`) |
| AURA61 | aurora-silicon/aura PR #61 "T6050: hand the display engine ... to Linux" (closed, not merged) | `09dca7f61740` (`ref/aura-pr61/`) |
| M1N1 | `~/Work/agents/m1n1-r2/tree` `pipe-park-r2-atc` | `f7555558` (R3-R's m1n1 is `pipe-park-r2` = `d956947e`). No `n1-handoff` branch exists anywhere under `~/Work/agents`, so 0024 sits on `pipe-park-r2-atc` and also applies to `pipe-park-atc` and `m1n1-r2` |
| ADT | `~/Work/studio-artifacts/adt-runtime-j716s.bin` via `~/Work/m1n1/proxyclient` | |
| FW | `~/Work/studio-artifacts/j716s-fw/Firmware/dcp/t605xdcp.im4p` sha256 `468cd936...b9c140` | read in place |

Line numbers below are for PICK unless prefixed.

---

## 1. What PR #1012's DCP path needs, and what our m1n1 does today

### 1.1 Driver gates, in probe order

| Gate | Where | Our J716s today |
|---|---|---|
| A previously retained live session blocks rebinding | `dcp.c:5969` (`dcp_session_retained`) | n/a |
| `apple,firmware-compat` read as 3-5 u32 cells, formatted `a.b.c[.d[.e]]`, compared **byte-exact** with `"27.0.0"`. Not a major-version match: 27.0.1 and 27.2.0 also fail. `apple,firmware-version` is not consulted for T6050. A mismatch returns `DCP_FIRMWARE_UNKNOWN`, then `-ENODEV`, **silently** upstream; patch 0013 adds the `dev_err` | `dcp.c:4932-4951`, `:5980-5982` | m1n1 sets no property, so the read fails and the driver returns `-ENODEV` |
| `apple,bw-scratch` must be present, or "Incompatible devicetree!" | `dcp.c:5993-5999` | unknown for the internal DCP (see 3.4) |
| `memory-region-names = "framebuffer"` on the dcp node (sets `dfb_region_size`); `apple,clock-ids` count must equal the clocks (empty list, no clocks, is valid) | `dcp.c:5155-5200` | m1n1 sets none |
| The DCP must be **running** (`CPU_CONTROL.RUN`): the driver adopts iBoot's session and never starts or stops the ASC (`adopt_live_session`, `apple_dcp_hw_t6050` at `dcp.c:7076`) | `dcp.c:5363-5373` | running: ADT `iop-dcp-nub running=1, pre-loaded=1`; m1n1 never starts its iBoot DCP client on an internal retina panel (`display.c:668` "already initialized"; `display_shutdown` is a no-op without it, `display.c:674-680`) |
| The PIODMA child device and its DART domain; `disp-N` regs; firmware metadata; RTKit init then wake with no reset ("negotiating RTKit with the running DCP") | `dcp.c:5461-5590` | |
| An internal (non-failsafe) DCP that fails bind fails the whole DRM master; the failsafe list holds only the `dcpext` variants | `dcp.c:5601-5630` | |
| DRM master (`apple,display-subsystem`) needs its own `memory-region` named `framebuffer` | `apple_drv.c:1405` | m1n1 sets none, and fixed8 has no display-subsystem node |
| simpledrm is evicted only after every DCP that can show the boot framebuffer reports ready and the takeover trial passes. Otherwise "keeping the boot framebuffer" | `apple_drv.c:1340-1378`, `:1460-1499` | |

### 1.2 DT nodes needed (none exist for the internal panel in any Aurora DT)

The PR adds no DT. T6050 display nodes live in `t6050-dieX.dtsi:101-185` (dcpext0 only) and `t6050-ultra.dtsi:408-415` (display-subsystem, J775D only). Every node is `disabled`, and the loader enables them. For the J716s internal panel, `mk-fixed9.py` adds:

| Node | Value (ADT, +0x2_0000_0000 arm-io offset) |
|---|---|
| `dart-dcp` `iommu@48a340000` | `apple,t6050-dart`, reg 0x20000, IRQ 990, dma-range 1 TiB + 3 TiB; DCP stream SID 23 (`l1-tt-23`), exclave SID 24 left alone |
| `dart-disp0` `iommu@48a300000` | reg 0xc000 (reg[0] only, as Aurora does for dispext0), IRQ 990 (shared with dart-dcp, as 1070 is for dcpext0's pair); scanout SID 0, PIODMA SID 16; exclave SIDs 3 and 4 (privacy-indicator planes) are never attached |
| `mailbox@48ae08000` | `apple,asc-mailbox-v4`, IRQs 1043..1046 |
| `dcp@48ae00000` | `apple,t6050-dcp`, reg coproc 0x4000 / disp-0 0x488000000+0x4000000 / disp-1 0x48a240000 / disp-2 0x48a3ac000 / disp-3 0x48a800000+0x800000 / disp-4 PMC 0x286700000+0x114000 / iop-vbar 0x48a850000; `iommus = <dart-dcp 23>`, `apple,dcp-index = <0>`, `apple,clock-ids;` (ADT `clock-ids` is present and empty), `piodma { iommus = <dart-disp0 16>; }`, `panel { apple,panel-j716 / -mini-led / panel; 345 x 223 mm; max-brightness 600 }` |
| `display-subsystem` | `iommus = <dart-disp0 0>` |
| backlight | none needed: it is DCP-side (`/backlight dcp-brightness-node=1`, `dcp_backlight.c:277` for v27). Linux must never master i2c7/`disp-bklt` |
| mipi/eDP | none: the panel link (DP855 TCON) is behind the DCP firmware; `num_dptx_ports = 0` |

### 1.3 Loader duties (Aura is Aurora's loader, not m1n1)

Aura's T6050 handoff (AURA61 `kboot_display_handoff.c:3420-3488`, only for J775D dcpext0) is the reference. Each duty below, with our m1n1 status:

| Duty | Aura (AURA61) | Our m1n1 (`pipe-park-r2-atc`) | Draft 0024 |
|---|---|---|---|
| Firmware identity: `apple,firmware-version`/`-compat` = the stub's firmware (`firmware_set_fdt`); refuses anything but 27.0/27.2 | `:3466-3471`, `:3381-3385` | T6050 hits "unknown compatible" (`kboot.c:2075`) and returns before `dt_set_dcp_firmware` (`kboot.c:1565`); `mBoot-20457.60.65.0.1` is not in the table, so `os_firmware` = unknown, `{0}`, 1 cell | adds `V27_2` and `V27_3B1` = `{27,2,98,1}`; publishes the stub's version honestly; `chosen.m5,t6050-dcp-compat=27.0.0` forces `<27 0 0>` (stage C only) |
| Memory: reserve `/vram` no-map, `compatible = "framebuffer"`, `memory-region` on dcp and display-subsystem. Nothing else (DART tables, firmware segments and /vram lie above OS RAM) | `:3422-3462` | none for T6050; the M1/M2 path (`dt_add_reserved_regions`, `kboot.c:1618`) would init, **walk** and **shut down** the display DARTs (`kboot.c:1739`) | same as Aura, by phandle; never calls `dt_add_reserved_regions` or `dart_init_fdt` on T6050 |
| Locked-DART state: check PROTECT and TCR/TTBR of SIDs 23/0/16 = four-level, on the ADT's `l1-tt` | `:3153-3249` | `dart_lock_adt` on dart-disp0 only (sets PROTECT if clear) | same checks, guarded reads; logged every boot; the lock runs afterwards, so the log shows iBoot's own state |
| `__OS_LOG` segments of running coprocessors | AURA61 `kboot.c:7037-7096` | none | ported (`dt_reserve_t6050_oslogs`) |
| Enable nodes only when everything checks out, as one edit | scratch-copy commit | n/a | all checks run before the first DT write; the nodes are enabled last |

On J716s the ADT matches what the kernel expects. `l1-tt-23` = 0x10bffea0000, `l1-tt-0` = 0x10bffed0000, `l1-tt-16` = 0x10bffe20000, all above the usable RAM end 0x10bc89f8000 (boot-arch-1.log:109). `/vram` = 0x10bd15f4000+0x72c4000 is the boot framebuffer region: m1n1's simplefb at 0x10bd16edc00 lies inside it. The DCP's `__TEXT` is below the usable start and `__DATA`/`__SHARED*` are above the usable end. Whether iBoot really left the DARTs locked and four-level is **not yet measured**; stage A logs it.

### 1.4 A live problem found on the way: coprocessor logs in Linux RAM

The ADT's `segment-ranges` place these `__OS_LOG` segments (flags 0xa) inside the usable range m1n1 publishes (0x10003b64000..0x10bc89f8000):

`dcp` 0x10006020000+0x28000, `dcpext0..3` 0x10006048000/70000/98000/c0000 (+0x28000 each), `aop` 0x100060e8000+0x37000, `mtp` 0x10006120000+0x3000, `auss-cpu0` 0x10006124000+0x2514.

That is about 1.1 MB that running coprocessors keep writing. Nothing reserves it today (boot-arch-1.log has no such node), so Linux can hand those pages to anything. Aura's comment says iBoot moves them every boot. The kernel (0x10012800000) and FDT (0x10009558000) were clear of them in that log; page cache and slab are not. Patch 0024 reserves them regardless of the display opt-in. This could explain rare unexplained corruption and deserves a test on its own.

---

## 2. Firmware ABI

### 2.1 What 27.3 beta 1 is

- IM4P type `dcpf`, description `1`, LZFSE payload (`bvx2`), uncompressed 0x011e0000. The header has no version.
- Strings found in the payload (read in memory):
  - `AppleDCP-1317.60.10~440-t605xdcp.RELEASE`
  - `BUILD-INFO {"DisplayName":"roottask.IOP_ASC7.RELEASE","SourceVersion":"1223.60.2","SdkVersion":"27.3","SdkBuild":"26C5035e",...,"ProjectName":"pitayaOS"}`
  - `RTKit_armv8_cl4_Oz_flto_pac-3514.60.8`
  - `AppleFirmwareKit-743.60.3`

  The DCP runs RTKit on a cL4 roottask (pitayaOS).
- m1n1: `OS FW version: unknown (mBoot-20457.60.65.0.1)`. The `.60` train is 27.3. Aura's table has 27.0 = `mBoot-20457.1.29` (AURA `firmware.c:217`) and 27.2 = `mBoot-20457.41.3` (AURA61 `firmware.c:219`).
- The macOS scan (`02-dcp-display.txt`) carries no DCP firmware version, only `iop-version 1` and the DP855 `firmware-ver`.

### 2.2 Does Aurora's 27.0 ABI cover 27.3? Probably not

- There is one table, `iomfb_v27.c:54` (A000 ... A489, for example `A408 swap_submit`, `A484 set_power_state`), selected only by `DCP_FIRMWARE_V_27_0`. No `V_27_2` or `V_27_3` exists in PR #1012 or PICK.
- Aurora's own DT says 27.0 and 27.2 "IOMFB method IDs differ" (`t6050-dieX.dtsi:175-178`). The PR body lists "firmware 27.2 (DCP probe refuses it; no panic)" as not supported. AURA61 tested 27.0 only ("Not tested: a 27.2 stub with this tree").
- Evidence the payloads have not drifted: the 27.3 firmware's `IOMobileFramebuffer::swap_submit_dcp_main(const IOMFBSwap*, Surface**, const dva_t*, const dva_t*, bool, double, dva_t, bool, uint32_t, bool*, const uint32_t*, uint32_t*)` lines up parameter for parameter with `struct dcp_swap_submit_req_v27` / `_resp_v27` (`iomfb_v27.h:45-79`). So the swap record layout may be unchanged. The method selectors cannot be checked from strings; that needs the dispatch table, by disassembly or a macOS hv trace.
- Conclusion: if 27.0 to 27.2 renumbered, assume 27.3 renumbered too. Treat publishing `27.0.0` on this stub as wrong until a 27.3 table exists.

### 2.3 What a mismatch does

- **Honest compat** (0024 default: `27.2.98.1`): the driver returns `-ENODEV` at `dcp.c:5980`, before any DCP MMIO, mailbox or RTKit message. This is a clean failure; simpledrm stays.
- **Forced `27.0.0` on 27.3 firmware**: the RTKit handshake and the early EPIC/AFK service setup are likely to work, since they are not IOMFB-numbered. The first IOMFB calls then reach different firmware methods with the wrong payload sizes. Expected results, from most to least likely:
  - a firmware assert, which crashes RTKit; the driver marks the DCP crashed and the panel freezes or goes black until a cold boot;
  - a call that silently does the wrong thing (power, brightness, modeset) with garbage arguments;
  - timeouts.

  The kernel itself should not hang: boot waits are bounded (`DCP_BOOT_TIMEOUT` 1 s, `dcp.c:162`; ready wait 3 s, `apple_drv.c:1340`). Eviction of simpledrm happens only after ready plus the takeover trial (`apple_drv.c:1460-1499`). A crash after eviction still means a black panel until reboot.

---

## 3. Patches

### 3.1 m1n1 draft `patches/m1n1/0024-kboot-T6050-reserve-coprocessor-logs-describe-the-in.patch`

On `pipe-park-r2-atc` (`f7555558`), commit `eb13da2e` in the private clone `~/Work/agents/dcp-aurora/m1n1` (branch `dcp-0024`). `git apply --check` passes on `pipe-park-r2-atc`, `pipe-park-atc` and `m1n1-r2`. Not built: `build.sh` needs the Fedora container. A host `clang-23 --target=aarch64-linux-gnu -fsyntax-only` with m1n1's warning flags is clean for `kboot.c` and `firmware.c`. Line numbers below are in the patched `src/kboot.c`:

- `:2050` `dt_reserve_t6050_oslogs()`: reserves the coprocessor logs (always on T6050).
- `:2168` `t6050_disp_read()`: guarded reads (`GUARD_SKIP|GUARD_SILENT`) of ASC `CPU_CONTROL` 0x44 / `CPU_STATUS` 0x48, DART `PROTECT` 0x200, and `TCR`/`TTBR` (0x1000/0x1400 + 4*sid) for SIDs 23/0/16, compared with the ADT's `l1-tt-N`.
- `:2216` `dt_set_display_t6050()`: opt-in `chosen.m5,t6050-display=1`. It requires a known firmware, a running DCP, both DARTs locked, and all three streams four-level on the ADT's roots. It also requires the DT's dcp, DARTs, mailbox and piodma to match the ADT addresses, and `/vram` to lie above OS RAM. Only then does it change the DT: `vram@...` no-map `framebuffer`, `memory-region` on dcp and display-subsystem, firmware-version/-compat, and status okay on five nodes. Override at `:2269`.
- `:2312-2328` `dt_set_display()`: for T6050, runs the read, the reservations and the optional handoff, then the old `dart_lock_adt`, and returns. The "unknown compatible" path is no longer reached on T6050.
- `firmware.c:214`: adds V27_2 and V27_3B1. Of the `os_firmware.version` users, only display/ISP/GPU switches change, and none takes a new branch on T6050. `display.c:405` (the reconfigure guard) now fires, which is the protective direction.

### 3.2 Kernel `patches/kernel-dcp/0001..0013` (base `6d9f1ec652a6`)

| # | PR commit | Subject |
|---|---|---|
| 0001 | `2b564db1e5d3` | drm/apple: Add T6050 firmware-27 display support. **Conflict** in `afk.c` `afk_recv_handle_init()`: INT added the H17G (M5 base) powerlog fallback. Resolved by keeping it and widening the props-parse condition to `H17P \|\| V_27_0` |
| 0002 | `eb027c6e6118` | log DCP CoreAnalytics events |
| 0003 | `b07d043049a5` | hand the analytics payload back unchanged |
| 0004 | `b379d8d8a192` | iommu/apple-dart: T6050 boot-locked display DARTs |
| 0005 | `c07bc8bc78ec` | iommu/apple-dart: fix DCP buffer setup (four-level firmware subtrees, `fw_mirror`) |
| 0006 | `648a76045be5` | dptx: DP link with fw 27 (inert for the internal panel) |
| 0007 | `59cb5ce253f7` | garbled output with fw 27 |
| 0008 | `e59d1cf02526` | dcpext EDID (inert here) |
| 0009 | `e9fcf14dd4a0` | fw 27 analytics answer |
| 0010 | `95bcc467a278` | more than one DCP |
| 0011 | `b4b28b262f9b` | one failed DCP taking down every display |
| 0012 | `637bddce5b8d` | firmware buffer requests reaching any mapped memory (touches `apple-dart.c`, `include/linux/soc/apple/dart.h`) |
| 0013 | ours | drm/apple: say why a T6050 DCP is not started (`dev_err` on a compat mismatch, `dev_info` on accept) |

- Not taken from the PR: `e15f70bc981c` (hwmon), and the GPU, Rust and Mesa UAPI commits. The 12 display commits are the PR's only changes under `drivers/gpu/drm/apple`, `apple-dart` and `dart.h` (no merges in the PR).
- PICK vs PR tip, restricted to those paths, differs only by INT's newer drm/apple work (22 files, the same as `11eccbedc3ed..33bec4016c46`) plus the `afk.c` resolution.
- Not compiled (per brief). Semantic risk: 0001 was written against an INT 236 commits older; the only textual overlap was `afk.c`, and INT's H17G/M4 changes elsewhere in `dcp.c`/`iomfb*.c` merged cleanly.
- Apply with `git am patches/kernel-dcp/*.patch` on `6d9f1ec652a6`.

### 3.3 Config `config/j716s-dcp.config`

`BACKLIGHT_CLASS_DEVICE=y` is required: R3-R has it `=m`, which caps `DRM_APPLE` at `=m`, and no modules load. Add `DRM_APPLE=y` with `DRM_APPLE_AUDIO` off, and keep simpledrm. `APPLE_DART`, `APPLE_RTKIT`, `APPLE_MAILBOX`, `MULTIPLEXER` and `TYPEC` are already `=y`. Add `DYNAMIC_DEBUG=y` for the `dev_dbg` lines.

### 3.4 fixed9 DT `mk-fixed9.py`

Generates `dt/j716s-typec-fixed9.dts` and `dt/t6050-j716s-typec-fixed9.dtb` (per-unit: never publish) from fixed8. It adds the five nodes of 1.2 with phandles 0xd0-0xd4, all disabled, and reuses fixed8's PMC window node (phandle 0x12). The DTB compiled with Aurora's dtc. `status = "okay"` count is unchanged (1).

`apple,bw-scratch` is left out on purpose. The bandwidth agent table (`/arm-io/pmgr bwr-agent`) gives DISP_INT BIRQ 0x96 (slot 1) vs DISP_EXT0 0x36 (slot 4, whose scratch Aurora put at PMC+0x2c000), with no derivable formula. Without it the driver refuses even a forced 27.0.0 compat ("Incompatible devicetree!"), which acts as a second interlock in front of stage C. Fill `BW_SCRATCH_OFFSET` once it is measured (a macOS hv trace of DISP_INT's bandwidth request).

---

## 4. Go/no-go and the smallest safe experiments

| Stage | Payload change from R3-R | Touches | Expected and proving lines | Risk |
|---|---|---|---|---|
| **A** (go) | m1n1 + 0024, **not armed**; kernel/DTB unchanged | guarded MMIO reads of a powered, running block; reserved-memory nodes | m1n1 log (UART, or the `logbuf` phram region m1n1 publishes): `DCP: T6050: dcp at 0x48ae00000: CPU_CONTROL ... (running)`, three `SID n: ... four-level, the ADT's table`, `FDT: T6050: reserved 9 coprocessor __OS_LOG segments in RAM`, `not armed`. Kernel: `/proc/iomem` / `/sys/firmware/devicetree/base/reserved-memory/os-log@*` | minimal: a read of a gated register is skipped by the guard; reservations stay clear of kernel, initrd and FDT |
| **B0** (go) | A + armed (`chosen.m5,t6050-display=1`) + fixed9; kernel R3-R (`DRM_APPLE` off) | apple-dart probes the two locked DARTs; no client attaches | `DCP: T6050: dcp handed off: vram 0x10bd15f4000+0x72c4000 ...; firmware-compat 27.2.98`; `apple-dart 48a340000.iommu: DART [... locked: 1, ...] initialized` and the same for `48a300000`; no `apple-dart ... fault`; simpledrm unchanged | low: a locked DART is not reset; the risk is a DART probe writing to error/IRQ registers of an in-use DART |
| **B** (go, Rolando present) | B0 + kernel 0001-0013 + `j716s-dcp.config`; bootargs add `drm.debug=0x1e log_buf_len=4M dyndbg="file drivers/gpu/drm/apple/* +p; file drivers/iommu/apple-dart.c +p"` | default-domain attach of SID 23 (dcp) and SID 0 (display-subsystem) through `fw_mirror`; the dcp probe stops at the compat gate | `apple-dcp 48ae00000.dcp: T6050 display not started: DCP firmware-compat 27.2.98.1 is not 27.0.0`; `[drm] Initialized simpledrm` stays and `/sys/class/drm/card0/device/driver` -> simple-framebuffer; no DART faults; panel unchanged | moderate: `fw_mirror` adoption of the **live scanout** stream was tested only on J775D dcpext0. A wrong import shows as DART faults and a garbled or black panel, with SSH still up |
| **C** (no-go) | B + `chosen.m5,t6050-dcp-compat=27.0.0` + measured `BW_SCRATCH_OFFSET` | RTKit and IOMFB with a 27.0 table on 27.3 firmware | would show `DCP firmware-compat 27.0.0 (FW: 27.2.98.1)`, `endpoints started`, then IOMFB errors or a crash | high: DCP crash, black panel until cold boot; garbage arguments to power/brightness methods. Needs a 27.3 table or a 27.0 stub first |

**Risk to boot and panel, precisely:**

- Everything above leaves the DCP firmware and the panel power path alone until stage C. iBoot re-initialises the DCP on every cold boot, so any display state the kernel breaks is undone by a power cycle.
- `DRM_APPLE=y` and apple-dart probe during device initcalls, **before the root filesystem mounts**. The self-revert service (90 s, `ip route`/`ping 1.1.1.1`, then copy `boot.bin.prev` and reboot) only exists after the root mounts and needs the network.
- The DCP does not affect USB tethering or Wi-Fi. So a broken display with a running kernel is still recovered by the loop (if the network is up) or by SSH. A hang or panic in DART/DCP probe before the root mounts is not: it needs Rolando and the A/B stage-1 path.
- Keep `pd_ignore_unused clk_ignore_unused`. The DCP nodes carry no `power-domains`, as in Aurora's dieX, so runtime PM cannot gate `disp0`/`dcp` under the firmware.

**What would unblock C:**

1. A 27.3 IOMFB method table. Either Aurora adds a 27.2/27.3 profile (their DT already anticipates 27.2), or we build one from a macOS 27.3 hv trace of the selectors (m1n1 `m5-hv` + `trace_dcp`). Alternatively, re-pair the stub to macOS 27.0 (`mBoot-20457.1.29`); that swaps every coprocessor firmware and needs SMC/NVMe owners' sign-off.
2. The DISP_INT `bw-scratch` offset.
3. Stage B passing with zero DART faults.

## 5. Files

See `SHA256SUMS` in this folder. Private, per-unit, never publish: `dt/` (it carries fixed8's ATC tunables). `ref/` holds public Aura sources fetched at the commits named above.

Leftovers to clean up when this work is done:

- `/Volumes/linux-cs/wt-dcp-aurora` (worktree, local branch `dcp-aurora-pick`)
- ref `refs/dcp-aurora/pr1012` in `/Volumes/linux-cs/linux`
- `~/Work/agents/dcp-aurora/m1n1` (shared clone)
