T6050: hand the GPU to the G17 driver (UAT, firmware and mailboxes from the ADT)

aurora-silicon/linux's G17 driver (`apple,agx-g17s`, #1012) takes over the M5 Pro GPU as iBoot leaves it: both GPU coprocessor images loaded but not started, and the UAT already set up. The driver needs that state described as reserved memory, plus the two coprocessor mailboxes at their native windows. `dt_set_gpu()` has no T6050 case today, so a J716s boot logs "ADT: GPU: unsupported chip!" and the GPU stays unusable.

This adds `dt_set_gpu_t6050()`, built like the T6040 fill (`dt_set_gpu_t6040()`): the same reserved-memory names, `dt_set_resvmem()`, the same region checks, regions published last, and the same disable path. Everything comes from the ADT of the current boot. It reads and writes no GPU register.

What it publishes, and where each value comes from:

| DT | ADT |
|---|---|
| `/reserved-memory/uat-handoff`, `uat-l2-pagetables`, `uat-pagetables`, `uat-ttbs` | `/arm-io/sgx` `gfx-handoff-*`, `gfx-shared-l2-region-*`, `gfx-shared-region-*`, `gpu-region-*` (base/size) |
| `/reserved-memory/gpu-fw-text` | `/arm-io/gfx-asc` `__TEXT` start to `/arm-io/gfx1-asc` `__TEXT` end (`segment-names` / `segment-ranges`) |
| `/reserved-memory/gpu-fw-data` | `gfx-asc` `__DATA` start to `gfx1-asc` `__DATA_SHARED_RO` end; each of the four segments must sit at the matching sgx `gfx{,1}-data{,-shared-ro}-base` |
| both GPU mailboxes: `reg` (wrapper + iop-vbar), then `status = "okay"` | `reg[0]` (0x88000 wrapper) and `reg[1]` (first 8 bytes of iop-vbar) of the coprocessor whose ADT `role` equals the mailbox's `apple,firmware-role` (GFX, GFX1) |

Checks done before anything is written:
- The gpu node's `sgx` reg base must equal the ADT's `/arm-io/sgx` reg.
- `fw-text` and `fw-data` must each be one contiguous span.
- Each mailbox needs its own coprocessor, and every interrupt it lists must be one of that coprocessor's ADT interrupts.
- Every region must be non-zero, 16 KiB aligned, below 4 TiB and must not overlap another region, and its `/reserved-memory` node must exist.

If any check fails, the code disables the gpu node, both mailboxes and every region it has already published, logs the reason, and the boot continues.

The firmware images are not at fixed addresses: on the same J716s, two iBoot builds placed `fw-text` 0x38000 apart and `fw-data` 0x8000 apart. For that reason none of these addresses is hardcoded.

When it runs: there is no `chosen.*` variable. As with T6040 and T8140, the fill runs when the device tree enables the gpu node (and the node is `apple,agx-g17s`); a DT that keeps the GPU disabled is left alone ("T6050 GPU is disabled in the device tree, not filling it"). The opt-ins elsewhere in this file guard GPU register access (the G15 powered identity probes, the stand-in power models); this code does none of that, and the DT that ships with the kernel is the thing that knows whether that kernel has the driver. The power domains (PMGR power-state group 3: GPX, AFR, CS, GFX) are the DT's, as on T6040.

On the J716s:

The same hand-off booted the GPU firmware. It read the same ADT sources and published the same values, from our own stage 2. In that build it was gated by a payload variable, enabled the gpu and PMGR nodes itself, and also checked the DT's GPU power-state registers against the ADT. m1n1:

```
FDT: GPU: T6050: ttbs          0x10bfffa8000..0x10bfffac000 (0x4000), outside Linux RAM
FDT: GPU: T6050: pagetables    0x10bfff28000..0x10bfffa8000 (0x80000), outside Linux RAM
FDT: GPU: T6050: handoff       0x10bfff20000..0x10bfff24000 (0x4000), outside Linux RAM
FDT: GPU: T6050: l2-pagetables 0x10bfff24000..0x10bfff28000 (0x4000), outside Linux RAM
FDT: GPU: T6050: fw-text       0x10001028000..0x100010cc000 (0xa4000), outside Linux RAM
FDT: GPU: T6050: fw-data       0x10002520000..0x100026a4000 (0x184000), outside Linux RAM
FDT: GPU: T6050: sgx 0x2300000000+0x3fdc000
FDT: GPU: T6050: mailbox GFX: wrapper 0x2302600000, iop-vbar 0x2302050000 (/arm-io/gfx-asc)
FDT: GPU: T6050: mailbox GFX1: wrapper 0x2302e00000, iop-vbar 0x2302850000 (/arm-io/gfx1-asc)
FDT: GPU: T6050: regions, mailboxes, GPU and PMGR nodes okay
```

Linux (aurora-silicon/linux #1012 with #1173 on top), firmware 27.3 beta 1 (26C5035r):

```
OF: reserved mem: 0x0000010001028000..0x00000100010cbfff (656 KiB) nomap non-reusable gpu-fw-text
OF: reserved mem: 0x0000010002520000..0x00000100026a3fff (1552 KiB) nomap non-reusable gpu-fw-data
OF: reserved mem: 0x0000010bfffa8000..0x0000010bfffabfff (16 KiB) nomap non-reusable uat-ttbs
OF: reserved mem: 0x0000010bfff28000..0x0000010bfffa7fff (512 KiB) nomap non-reusable uat-pagetables
OF: reserved mem: 0x0000010bfff24000..0x0000010bfff27fff (16 KiB) nomap non-reusable uat-l2-pagetables
OF: reserved mem: 0x0000010bfff20000..0x0000010bfff23fff (16 KiB) nomap non-reusable uat-handoff
aurora 2300000000.gpu: Probing...
aurora 2300000000.gpu: GPU ID registers: 0xb031100 0xb0a00 0x11020a 0x40404 0x1320311 0x400c1809
aurora 2300000000.gpu: GPU firmware build: 26C5035r for T6050 G17S, primary then secondary
aurora 2300000000.gpu: GPU firmware: 27.3 (26C5035r), G17S
aurora 2300000000.gpu: RTKit: Initializing (protocol version 12)
aurora 2300000000.gpu: RTKit: Initializing (protocol version 12)
aurora 2300000000.gpu: M5 primary initdata acknowledged
aurora 2300000000.gpu: M5 secondary initdata acknowledged
aurora 2300000000.gpu: M5 firmware opening records retired
[drm] Initialized aurora 1.0.0 for 2300000000.gpu on minor 1
```

`/dev/dri/renderD128` is present, both mailboxes are bound, and the GPU, AFR and GPX power domains are on. The machine ran for over two minutes with no SError and no UAT or DART fault. All six regions lie outside the RAM Linux gets: the firmware below `phys_base`, the UAT above the end of RAM.

This branch itself:
- [J716s boot of this branch: to be filled in after the attended boot]
- I ran `dt_set_gpu_t6050()` on a host against a J716s ADT from an older iBoot build, with the J716s DTB (gpu node enabled). It fills the six regions and both mailboxes with that build's addresses.
- With the gpu node disabled it changes nothing.
- Each malformed case leaves the GPU, both mailboxes and every region disabled: a wrong sgx base, two mailboxes claiming one role, a foreign interrupt, one mailbox instead of two.
- Built with clang/lld 21.1.8 and rustc 1.99.1 (Fedora 43). 15 warnings, the same as the base; none new. The added lines are clang-format clean.
- The plain `m1n1.bin` stays 0x410000 bytes, as on aurora-wip today. This change uses about 3.5 KiB of the `.text` padding and 1.5 KiB of the rodata/relocation padding.
- With #65 on top it still builds with no new warnings, at 0x420000 bytes; #65 alone already takes the image to that size.

Dependencies:
- m1n1: the T6050 bring-up series (#__, the four T6050 boot commits; not opened yet). This PR is stacked on it and is not needed for it. It does not need #65 (the N1 hand-off): it touches only `src/kboot_gpu.c`, and the two apply in either order.
- Linux: aurora-silicon/linux #1012 (the G17 driver and its `apple,agx-g17s` match) and #1173, which is stacked on it. #1173 adds the InitData for the macOS 27.2 and 27.3 GPU firmware, and a mailbox profile for the T6050 GPU coprocessors at the native windows this code publishes (`apple,t6050-native-ascwrap-v6`).
- J716s device tree (not posted yet): the GPU nodes. The six reserved-memory nodes and both mailboxes stay `disabled` with placeholder `reg`; m1n1 fills and enables them. The DT enables `&gpu` and the GPU's PMGR node.

Questions:
- Opt-in or default? I followed T6040: the hand-off runs whenever the DT enables the GPU, with no `chosen.*` variable. While the Linux side is unmerged, a DT that enables the GPU only exists with that work, so this changes nothing for other kernels. If you would rather have an explicit `chosen.asahi,t6050-gpu=1`, as the N1 hand-off (#65) has, it is a few lines on top of this.
- Mailboxes: m1n1 writes their windows from the ADT and enables them with the GPU, much as the G15 path enables a disabled mailbox together with the gpu node. t604x instead has the DT enable `gfx_mbox` with fixed `reg`. Would you rather the J716s DT do the same, and m1n1 only check the windows against the ADT?
- Image size: aurora-wip's plain image is 0x410000 with about 9 KiB of `.text` padding left. After this change about 5 KiB of `.text` and 6 KiB of rodata/relocation padding are left before the image grows to 0x420000; #65 crosses that line anyway. m1n1 finds its payload from its own size, so I know of no hard limit. Is there a size budget for stage 2 that I should keep to?
- T6051 (M5 Max) probably works the same way, but I only have T6050 data, so the dispatch covers T6050 only.
