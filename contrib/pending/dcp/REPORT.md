# DCP on the M5 Pro J716s (T6050): design report (2026-11-04, agent output, compile-checked only)

Coordinator note: the agent inferred from the build letter that the stub is "27.2 beta". That is wrong:
the Mac Studio's released macOS 27.2 is build 26B123, so 26C5035r is 27.3 beta 1 as documented elsewhere
in this repo. The open question in section 0 stands regardless: does aurora's firmware-27 method table
match the DCP firmware that 26C5035r pairs?

## Decision
1. Ship three things now; none puts the display at risk: the DT description of the display pipeline with
   every node disabled (omarchy 0001), a drm/apple guard that refuses T6050 (linux 0020), and an m1n1
   firmware-table fix (m1n1 0001). Then run TEST-PLAN steps 0-4, which only read from the DCP.
2. Brightness, modesetting and display power management (path a1): adopt aurora-silicon's public T6050
   "firmware-27" DCP code (aurora-silicon/linux branch `t6050/dcp`, d977897ba23f, 2026-10-26, ~+4k lines,
   includes swap-record brightness fields). Catch: it sits on a drm/apple far from ours (~67k vs 12k lines)
   and its docs say it is not validated on hardware. Estimate 2-4 weeks with hardware iterations.
3. Gate before a1: confirm the stub's DCP firmware ABI matches aurora's table. aurora's j716c DT says 27.0
   and 27.2 already use different IOMFB method IDs. Consider re-pairing the stub to a released build that
   aurora's code matches (a re-pair swaps every coprocessor firmware; coordinate with SMC/NVMe owners).
4. No safe way to change brightness without a DCP driver. The backlight LED chip is `disp-bklt` on i2c7 at
   0x44, owned by DCP firmware (mini-LED local dimming updated continuously; `/backlight` has
   `dcp-brightness-node = 1`). Driving it from Linux is rejected. Zero-code option: iBoot may restore the
   last macOS brightness when it lights the panel (TEST-PLAN 0c, unverified).
5. Our own port from hypervisor traces (path a2) is fallback only: m1n1 can host macOS 27 with SPTM and
   Exclaves (`m5-hv` branch landing), but the 27.x DCP message format changed ("compact AFK framing"):
   6-10 weeks.

## 1. Hardware and boot chain (ADT; arm-io ranges add 0x2_0000_0000; no identifiers)
| node | MMIO | IRQs | notes |
|---|---|---|---|
| dcp | 0x48ae00000+0x88000 (ASC), 0x48a850000+0x4000 | 1043-1050 | iop,ascwrap-v6; power-gates [606]; iommu-parent mapper-dcp (SID 23) + mapper-dcp-exclave (SID 24); rtbuddy-v2, pre-loaded=1, running=1 |
| disp0 | 0x488000000+0x4000000, 0x48a240000+0x10000, 0x48a3ac000+0x4000, 0x48a800000+0x800000, 0x286700000+0x114000 | 980-990, 1000 | compatible disp0,t605x |
| dart-dcp | 0x48a340000+0x20000 | 990 | dart,t8110; sid 23, exclave-sid 24; iBoot pre-populated L1 tables for 23 and 24 |
| dart-disp0 | 0x48a300000+0xc000 | 990 | disp0 SID 0, piodma 16, scl 3, sca 4; exclave-sid 3, 4 |
| dart-disp0-isoc | 0x48a180000 | 1013 | SID 30 |
| dcpext0..3 | 0x2b2e00000, 0x392e00000, 0x302e00000, 0x306e00000 | mailbox 1123-1126, 1195-1198, 1267-1270, 1339-1342 | DARTs at ...340000/...300000, IRQs 1070/1142/1214/1286 |
| i2c7/disp-bklt | i2c7 0x50502c000, IRQ 1382 | - | I2C 0x44, no compatible |
| /backlight | - | - | dcp-brightness-node=1; user-accessible-max-nits 600 (override 1000); child `twodbl` |
| /exbrightpil, dynamic-pil | - | - | exclave EXBrightPILCore: privacy-indicator brightness (inferred) |
| spi4/dp855 | - | - | Parade DP855 timing controller |

- No separate DCP version string in the ADT; the DCP firmware is paired with the OS. Stub boot logs
  `OS FW version: unknown (mBoot-20457.60.65.0.1)`. `/chosen/boot-object-manifests` lists `dcpf` and `dcp2`.
- m1n1 (m5-t6050 @459a3af2): `dt_set_display()` locks dart-disp0, prints "unknown compatible" for
  apple,t6050 and returns: no `apple,firmware-version`/`firmware-compat`, no DCP reserved memory, no
  display node enabled. Latent hazard: with the version unknown the guard at display.c:405 never fires; a
  reconfigure branch (external display at boot) would talk 13.x-era protocol to a 27.x DCP. m1n1 0001 closes this.
- omarchy-m5 DT (2c87598): only `framebuffer0`; pmgr has `disp_*`/`dispext*` domains; disp_cpu boots on
  under auto-PM. `.config` has DRM_APPLE=m but no modules load; console is simpledrm.

## 2. Firmware ABIs, in-tree and public
- In-tree (asahi-wip-7.2): iomfb_v12_3, iomfb_v13_3 (13.5), iomfb_v14_7; dcp.c accepts compat 12.3.0,
  13.3.0+fw 13.5.0, 13.5.0, 14.7.0. Compatibles t6020-dcp, t8112-dcp, dcp, dcpext. No DT for t603x,
  t8122, t8132 or t6050. Probe rejects unknown ABI before hardware access (dcp.c:1175); simpledrm removed
  only after a DCP started (apple_drv.c:502).
- AsahiLinux bits/200-dcp (2026-11-02): same three ABIs; M3 targets 14.8.3; nothing named for M4/M5.
  https://asahilinux.org/2026/08/progress-report-7-2/ , https://asahilinux.org/2026/09/m2-episode-1/
- chadmed/linux dcp/14.8.3: M3 WIP. jannau: older branches only.
- aurora-silicon/linux: `t6050/dcp` (binding apple,t6050-dcp/-dcpext, firmware-compat <27 0 0>,
  apple,clock-ids, framebuffer memory-region; v27 swap record brightness_update 0x354, brightness_nits
  0x35e; written for Linux under their EL2 monitor "Aura"; "hardware validation pending");
  `j716c/t6050-platform` (J716c DT with dcpext0; comment: stub firmware "27.0 or 27.2, whose IOMFB method
  IDs differ"; public iomfb_v27.c has one table); also `t6050/display-phy`, `apif-dcp-firmware`,
  `m4/pr2-gpu-dcp`, `drm/dcp-audio-26-abi`. https://github.com/aurora-silicon/linux ,
  https://github.com/aurora-silicon/aura (firmware table stops at 27.0).
- Not found: DCP work in betizzel/omarchy-m5 or linux-aurora.
- m1n1 hypervisor: main has `--sptm-mode/--sptm/--txm/--exclave-bundle` + M5 patches; `m5-hv`
  (2026-11-04) adds XNU/SPTM/cL4 contexts; the DCP tracer's tables stop at 14.7.

## 3. Paths
- (a1) Adopt aurora's firmware-27 code, recommended, 2-4 weeks: confirm stub ABI or re-pair; import
  aurora's drm/apple and its handling of DARTs iBoot left locked (our in-tree locked-DART path wipes the
  L1 table on detach, apple-dart.c:469-472, which would destroy the firmware's SID-23 mappings); add m1n1
  T6050 handoff (reserved memory for DCP + boot framebuffer, write compat <27 0 0> only for a verified
  build, enable nodes); fill in bw-scratch offset and clock-ids; bring-up order brightness, modeset,
  display power. Risks: unvalidated code, ABI mismatch, adopted session cannot be rebound; a DCP crash
  leaves the panel black until reboot, so SSH/tether is needed.
- (a2) Own port from traces, 6-10 weeks (m1n1 SPTM+Exclaves on M5, tracer updated for 27.x framing).
- (b) Stay on simpledrm: disp-bklt direct drive rejected; no SMC backlight key; m1n1 only speaks the
  iBoot endpoint (0x23 ops 1-6, 15-18), ops 7-14 unexplored and risky. Only zero-code option is TEST-PLAN 0c.
- (c) Brightness-only client: same handshake and swap as a1, saves ~30%; treat as a1's first milestone.
- Display PM groundwork impossible without an IOMFB session; keep pd_ignore_unused, never let genpd power
  off disp_* while DCP drives the panel.

## 4. Deliverables (all pass git apply --check; nothing committed)
- linux `0020-drm-apple-dcp-refuse-t6050-and-report-an-undriven-coprocessor.patch`: t6050-dcp/-dcpext with
  `no_fw_abi` (never driven); opt-in `appledrm.report_coproc=1` reads ASC CPU_CONTROL once and logs
  whether the coprocessor runs. W=1 clean except 8 pre-existing kernel-doc warnings.
- omarchy `0001-dt-t6050-describe-the-dcp-display-pipeline-disabled.patch`: new dt/t6050-dcp.dtsi (DARTs,
  mailboxes, dcp+piodma, display-subsystem, dcpext0-3, all disabled, aliases m1n1 looks up); J716s panel
  node 345x223 mm (adjusted 216), 600 nits. "okay" node count unchanged (8).
- omarchy `0002` (optional): boot framebuffer holds ps_disp_cpu. omarchy `0003`: omarchy-dcp-test.config
  (DRM_APPLE=y) + t6050-j716s-dcptest.dts (&dcp okay); opt-in only.
- m1n1 `0001-firmware-recognise-the-27.1-and-27.2-beta-iBoot-strings-seen-on-J716s.patch`: adds
  mBoot-20457.41.2 and mBoot-20457.60.65.0.1 (naming per the agent's inference; see coordinator note).
  Brew clang needs `EXTRA_CFLAGS="-Xclang -target-feature -Xclang +tlb-rmi"` for src/hv/hv_sprr.c on m5-t6050.
- scripts/dcp-devmem-check.sh: read-only ASC/DART register check (dry-run only).
- build/: t6050-j716s.dtb b56049a5..., t6050-j714s.dtb 1f338967..., t6050-j716s-fbpd.dtb 4f1c82bd...,
  t6050-j716s-dcptest.dtb 84a8e75f... (SHA256SUMS); baseline/ holds unpatched DTBs.
- Conflicts: omarchy 0001/0003 need mechanical rebases against the integration, audio and usb omarchy
  patches (t6050-j716s.dts, build-kernel.sh lists); linux 0020 is isolated.

## Verified / inferred / unknown
- Verified: ADT values, m1n1 log lines, in-tree ABI list and probe order, public branches, patches apply,
  drm/apple W=1 builds, DTBs build, m1n1 links, config resolves.
- Inferred: i2c7 DCP-owned; exclave SIDs 3/4 are privacy-indicator planes; aurora's code can run without
  Aura; panel dimensions; disp_cpu is the framebuffer domain; mailbox IRQ ordering. (Stub version
  inference corrected above.)
- Unknown: whether aurora's 27.x table matches 26C5035r; dart-dcp lock state/table depth at handoff
  (TEST-PLAN step 1); internal DCP bw-scratch offset and clock-ids; iBoot brightness carry-over; iBoot
  endpoint brightness op; whether 27.x DCP firmware blocks waiting for an Exclave peer.

Cleanup: worktree /Volumes/linux-cs/wt-dcp; private clones ~/Work/agents/dcp/{omarchy-m5,m1n1}; ref/.
Note for builders: gmake -j8 with several DTB targets at once hung; build one target per call.
