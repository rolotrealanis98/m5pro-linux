# GPU on the M5 Pro J716s (T6050, AGX G17S): landscape, software desktop, go/no-go (2026-11-04, agent output)

Design and research only; nothing ran on the MacBook. Compile checks in /Volumes/linux-cs/wt-gpu.
Tags: [ADT] this machine's runtime ADT (hardware-description properties only), [code], [web] with URL/date,
[log] the 2026-11-04 Linux diagnostics, [compile], [inferred], [unknown].

## Decision
- NO-GO on writing our own G17 port in the next 3 months. The stub pairs 27.3 beta 1 GPU firmware; no public
  driver supports any 27.x GPU firmware. Learning its ABI ourselves means tracing macOS 27.3 under the m1n1
  hypervisor on this machine: m5-hv support is days old and unproven on M5, the GPU tracer stops at macOS 13.5
  (G14X), and tracing ties up the only tether host for days. Own-port estimate 10-19 weeks to "firmware answers".
- SHIP the software-rendered desktop now (userspace/ + config fragment). Omarchy 4 detects llvmpipe and turns
  off animations, blur and shadows on its own.
- WATCH aurora-silicon; re-decide when a trigger fires. Public today: G17 kernel code for A18 Pro and M4 Pro on
  26.x firmware; a Mesa branch with an opt-in "M5 bring-up" path naming chip_id 0x6050; a support page listing
  the M5 Pro GPU as "partial". Their M5 kernel runtime is NOT public (uAPI reserves its feature bits, "this
  kernel never" reports them). Trigger 1: aurora publishes the T6050 runtime -> adopt, 3-6 weeks (Rust on the
  Darwin build, matching firmware build, T6050 config, frames copied into simpledrm). Trigger 2: m1n1 boots
  macOS 27 on M5 under the hypervisor for other people -> re-cost own port.
- One cheap read-only step when the owner allows: scripts/gfx-fw-read.py (DRAM reads only, never GPU
  registers): identifies the loaded GPU firmware with aurora's hash scheme and reads the SAPT table.

## 1. Hardware [ADT] vs T6020 (M2 Pro, in-tree) and T8140 (A18 Pro, aurora DT)
- arm-io ranges map bus 0x20_2000_0000 -> 0x22_2000_0000; the GPU block is at 0x23_xxxx_xxxx.
- compatible `gpu,t6050` (no Linux binding). SGX registers 0x23_0000_0000+0x3fdc000, "fender" window
  0x23_00d0_0000+0x177000. IRQs sgx 2448-2451, 450, 2806 (idx 5, marked invalid), 2463, 2465; gfx-asc
  2797-2800; gfx1-asc 2801-2804.
- TWO firmware CPUs (same offsets from SGX as T8140): gfx-asc (role GFX) 0x23_0260_0000+0x88000, vbar
  0x23_0205_0000; gfx1-asc (GFX1) 0x23_02e0_0000+0x88000, second reg 0x23_0285_0000+0x60000. Both
  iop,ascwrap-v6, rtbuddy-v2, firmware-name GFX/GFX1, pre-loaded=1, data-isolation=1.
- Power: gates 616 GFX_SGX, 615 GFX_BUSY, 614 GFX_ASC, 657 GFX_ASC1, under PMGR "GFX" (pmgr3+0x110, parents
  AFR and GPX). Handover gfx = 0x0f040300 (off, auto-PM).
- IOMMU: mapper-gfx-asc (`iommu-mapper,gfx`), GPU's own page tables (UAT), no DART. NO exclave mappers for
  the GPU (unlike ISP, AOP, SEP, DCP, dcpext0-3).
- 14 performance states (24 MHz idle to 1620 MHz), two tables, separate afr/cs tables, min SRAM 775 mV.
- New properties vs in-tree DTs: agx-address-space-mgmt-mode 1, gptbat-ready 1, ttbat-phys-addr-base
  0x42fffea (= gpu-region 0x10bfffa8000 >> 14), has-kf, gpu-supports-higher-mA, verify-gmmu-tlbis-at-sync
  with gmmu-tlbi-verification-reg 0x23_0000_d878 bit 4.
- /arm-io/sapt (GPU permission table): policy 2, table at 0x10bd12e4000, 3145728 two-bit entries.
- T6030 (M3 Pro): no GPU node in this tree; aurora-stable t6030.rs (SGX 0x2_9000_0000, firmware V14_8_3).
- Core count [unknown]: no property; Apple sells 16- or 20-core; two perf tables + pmgr mgpu-count-per-die 2
  suggest two clusters [inferred]. m1n1 reads core masks from GPU registers (needs power).
- Firmware in memory: iBoot loaded `gfxf`. GFX TEXT 0x100_00ff_0000+0x50000, DATA 0x100_0251_8000+0xc0000,
  SHARED_RO 0x100_025d_8000+0x8000; GFX1 TEXT 0x100_0104_0000+0x54000, DATA 0x100_025e_0000+0xb4000,
  SHARED_RO 0x100_0269_4000+0x8000. Carve-outs: handoff 0x10b_fff2_0000+0x4000, shared-l2
  0x10b_fff2_4000+0x4000, shared 0x10b_fff2_8000+0x80000, TTBAT 0x10b_fffa_8000+0x4000. All outside Linux
  RAM (0x100_03b6_c000..0x10b_c8a0_0000) [log].
- Two dies (aic-numdies-per-die 2, B2BD_AFR_*/B2B_CTRL_GFX domains). m1n1 m5-t6050 `dt_set_gpu()` prints
  "unsupported chip" and returns (src/kboot_gpu.c:504-527). Studio restore bundle GPU firmware is
  Firmware/agx/armfw_g14d.im4p; J716s likely armfw_g17s* [inferred].

## 2. Drivers
- This tree (236788cd2): drivers/gpu/drm/asahi supports t8103, t8112, t600x, t602x; version table G13/G14/G14X
  with firmware 12.3/12.4/13.5 (driver.rs:191-216). Rust; CONFIG_RUST off in our build. bits/210-gpu
  (2026-11-02) same.
- Upstream Asahi [web]: M3 targets 14.8.3; "SPTM is mandatory for XNU on M4 and above"; HV emulates SPRR/GXF
  (https://asahilinux.org/2026/08/progress-report-7-2/). M3 GPU still unsupported
  (https://asahilinux.org/2026/09/m2-episode-1/). XDC 2026 M3 GPU RE talk (https://phoronix.com/news/XDC-2026-Talks).
  No public G16/G17 work from Asahi.
- aurora-silicon/linux (integration/aurora 1d76233f 2026-11-04; aurora/bits/210-gpu 4383f9d5 2026-10-17):
  new drivers/gpu/drm/asahi/g17/ module, "two coprocessor instances, primary and secondary" sharing UAT and
  TTBAT (= T6050 layout). Chips: apple,agx-t8140 (A18 Pro, 2 instances, fw 26A428), apple,agx-t6040 (M4 Pro,
  1 instance, fw 25G83 = macOS 26.6.2). No t6050/t8142 in 316 branches. Firmware gate: interface version
  [0x04c0, 0x0396, 0xa322, 0x0c8a] at initdata root+0; M4 Pro path hashes TEXT (fwid.rs) and refuses unknown
  builds before writing anything (good model to copy). Still needed per SoC: register-window table (18 MMIO
  slots), core layout, perf config, "region C", UAT quirks, crash-buffer addresses. uAPI
  DRM_ASAHI_GPU_HAL_300 "never reported by this kernel"; feature bits 17-28 belong to the M5 runtime.
  No SAPT handling in aurora's driver or Aura.
- aurora Mesa aurora-wip c1753704 (2026-11-05): "AGX3" ISA family incl. G17G/G17S/G17C;
  agx_params_m5_bringup_supported() accepts G17S chip_id 0x6050 with HAL300; agx3_m5_graphics_program.c.
  support.json (2026-11-03) lists j716s GPU/Vulkan/RT "partial", "Project owner confirmation", no public code.
- Cody Ho / Niklas Sheth: GLES 3.0 conformant on M4 and MacBook Neo; M5 "firmware ABI fully reverse
  engineered", kernel side a prototype drm-shim (https://codyho.dev/blog/gpu-driver/ ~2026-09-15). SPTM/SAPT
  notes: https://github.com/ADevWithAnIdea/apple-silicon-re docs/sptm/uat.md (2026-11-03); SAPT "revoke" is
  macOS 27+ only.
- Generations: M3 (G15) new fw ABI 14.8.3 + AGX3 ISA; M4/A18 (G16/G17P) HAL200 + new fw interface, SPTM;
  M5 (G17G/S/C) HAL300, two firmware instances, SAPT, 27.x firmware. Whether "compact AFK" affects GPU fw [unknown].

## 3. Tooling for a firmware-ABI port
- m1n1 HV: main has SPTM/TXM/Exclaves loading (2026-11-01), M5 sysregs + TLBI patching (2026-10-26), T8142 CPU
  start; m5-hv ae801ef7 (2026-11-04) adds XNU/SPTM/cL4 contexts. Nobody reports macOS 27 reaching a GPU
  desktop under the HV on M5.
- GPU tracer (proxyclient/m1n1/trace/agx.py, fw/agx) stops at V13_5/G14X (last change 2025-01-21); no
  two-instance, HAL200/300 or TTBAT support.
- Own-port estimate: HV usable for macOS 27 on M5 (outside our control) 2-6 wk; tracer port 2-3 wk; tracing
  1-2 wk; kernel bring-up to first init 4-8 wk; total 10-19 weeks.
- Static analysis: TEXT images (320/336 KiB) readable from DRAM or the 26C5035r bundle, but the initdata
  layout lives in macOS's kext; disassembling it is unacceptable for clean-room projects.
- Re-pairing the stub to 26.x swaps every coprocessor firmware at once; only helps once a public driver
  supports that exact M5 build.

## 4. Desktop without the GPU (deliverable)
- Mesa GBM fallback order: hw driver, zink, kms_swrast, swrast; GBM_ALWAYS_SOFTWARE skips to kms_swrast.
  llvmpipe shares buffers via udmabuf, but CONFIG_UDMABUF is off and DMABUF_HEAPS_SYSTEM=m (no modules on root).
- Omarchy 4 (quattro, Hyprland 0.56, Lua config) applies default/hypr/software-rendering.lua when it detects llvmpipe.
- Framebuffer 3456x2160x4 at 0x10bd16edc00 [log]; pixel format [unknown]. simpledrm: one fixed mode, no vblank
  (no pacing, can tear), no cursor plane. No published software-rendering numbers for any M-series; Asahi's
  2022 alpha note called M1 software rendering "surprisingly usable".
- Recommendation: Hyprland (Omarchy) on llvmpipe; low-CPU fallback sway with WLR_RENDERER=pixman; not GNOME/Plasma.
  Costs: continuously redrawing apps, simpledrm's ~30 MB CPU copy per full frame.
- Files (install paths in userspace/README.md): packages.txt (mesa, vulkan-swrast, loader, mesa-utils,
  vulkan-tools, wayland-utils, drm_info, glmark2, xwayland, foot, sway, btop; not mesa-asahi/vulkan-asahi);
  uwsm/env.d/90-m5-softrender (+ environment.d copy): GALLIUM_DRIVER=llvmpipe, GBM_ALWAYS_SOFTWARE=1 (remove
  once a GPU driver exists), VK_DRIVER_FILES/VK_ICD_FILENAMES -> lavapipe, commented LP_NUM_THREADS,
  GSK_RENDERER=cairo, QT_QUICK_BACKEND=software; hypr/m5-softrender.lua (scale 2, no_hardware_cursors, vfr,
  animations/blur/shadows/dimming off); sway/config.d/50-m5-softrender + bin/sway-softrender;
  bin/m5-softrender-check (read-only inventory, --bench adds idle CPU and windowed glmark2).
- Kernel: configs/omarchy-softrender.config (UDMABUF=y, DMABUF_HEAPS(_SYSTEM)=y, SYNC_FILE=y, SIMPLEDRM=y).

## 5. Staged plan
| stage | what | effort | hardware risk | gate |
|---|---|---|---|---|
| 0 | software desktop | 0.5-1 day incl. measurements | none | now |
| 1 | read-only identification: gfx-fw-read.py dump/id/sapt; compare with armfw_g17s* from the 26C5035r Mac17,8 bundle | 1-2 days | DRAM reads only | owner allows root access |
| 2 | prerequisites: CONFIG_RUST on the Darwin build; worktree with aurora's g17 module; T6050 config refusing unidentified firmware | 1-2 weeks, compile only | none | trigger 1 or 2 |
| 3 | "firmware answers": power GFX via genpd, TTBAT/handoff/page-table roots, start GFX+GFX1, RTKit handshake on both mailboxes, read firmware syslog; stop before initdata | 2-4 weeks with a matching public runtime | GPU power-on, ASC start | firmware identified |
| 4 | initdata accepted, one compute job, Mesa M5 path, frames into simpledrm | 4-8+ weeks | GPU DMA | stage 3 |

Watching stage 3 safely: simpledrm scans out iBoot's framebuffer through DCP in its own display power domains;
GFX (under AFR/GPX) is a separate tree, so a GPU crash should not take the console down [inferred]. Hazards:
(1) reading GPU registers with GFX off can stop the bus: never touch SGX/ASC before genpd reports it on;
(2) wrong GPU page tables corrupt RAM: map only driver-owned pages, read SAPT first (if fully permissive
nothing else limits the GPU); (3) ABI mismatch: refuse unknown TEXT hashes, never send initdata to an
unidentified build. Run with GPU nodes disabled in the default DTB, a separate test DTB with the driver built
in but gated off by a module parameter, bind at runtime over SSH, `dmesg -w` over the USB link, watchdog armed,
ramoops (PSTORE_RAM =m today, needs =y + reserved region). Success: RTKit HELLO/EPMAP on both mailboxes,
firmware syslog text, clean shutdown on unbind.

## 6. Deliverables and checks
- patches/omarchy-m5/0001-dt-t6050-describe-the-gpu-disabled-and-add-a-softrender-config-fragment.patch:
  new dt/t6050-gpu.dtsi (gfx_mbox, gfx1_mbox, gpu, all disabled; header records ADT facts and carve-outs),
  include in t6050.dtsi, build-kernel.sh install lines. Applies on j716s@2c87598; conflicts mechanically
  with DCP omarchy 0001. [compile] j716s and j714s DTBs W=1 clean (one target per call); okay nodes 8,
  disabled 22 -> 25. SHA256SUMS: j716s+gpu d0e391fa..., j714s+gpu 5ecaaaf9..., j716s baseline d4364f78...
  J714s assumed to match J716s (same SoC).
- Config fragment: merged on the main .config changes only UDMABUF (off->y) and DMABUF_HEAPS_SYSTEM (m->y);
  udmabuf.o and system_heap.o W=1 clean.
- scripts/gfx-fw-read.py: stage-1 tool; offline id/sapt modes tested on synthetic data; dump never ran;
  aligned 8-byte /dev/mem reads, refuses ranges overlapping Linux RAM.
- userspace/ scripts pass bash -n. Nothing ran on the M5. No commits anywhere.

## Verified / inferred / unknown
- Verified: ADT values and Linux RAM bounds; in-tree driver and m1n1 coverage; aurora branches, firmware gate,
  uAPI reservations, Mesa M5 bring-up check; Omarchy software-rendering handling; Mesa GBM fallback and
  llvmpipe udmabuf use; Asahi public status; builds and patch application.
- Inferred: mailbox at ASC+0x8000 and IRQ order for ascwrap-v6; two GPU clusters; console survives a GPU
  crash; SAPT permissive on boots without SPTM; armfw_g17s* name; J714s matches J716s.
- Unknown: whether 27.3b1 firmware keeps the G17 interface version; which firmware aurora's private M5 runtime
  targets; SAPT contents at handoff; framebuffer pixel format; this unit's GPU core count; the T6050
  register-window table; whether the HV can trace the GPU under macOS 27 on M5; real llvmpipe numbers here.

Cleanup: worktree /Volumes/linux-cs/wt-gpu; private clone ~/Work/agents/gpu/omarchy-m5; ~/Work/agents/gpu/ref/.
