# macOS as a VM inside Linux on the J716s (M5 Pro): status pointer

Research only, 2026-11-17. Nothing here has run on M5 yet.

**Verdict:** feasible through QEMU's `vmapple` machine under KVM, as on M1/M2 hosts. KVM itself works: the J716s
kernels start every CPU at EL2 and initialise KVM in VHE mode, and T6050 Linux guests are proven
([aurora-silicon/linux#1724](https://github.com/aurora-silicon/linux/pull/1724)). One M5-specific unknown decides the
cost: whether plain EL2 can write Apple's pointer-authentication registers (APCTL and KERNKEY through their `_EL12`
aliases, and the VM key). KVM must load them for each macOS vCPU. The existing KVM patch enables them only on M1/M2, and
aura/m1n1 treat them as locked from M4 on. Nobody has measured T6050.

## What works elsewhere

| Host | Result | Where |
|---|---|---|
| M1 Max / M1 Ultra, Fedora Asahi | macOS 13.6 and 26.4 guests, daily CI, Metal via Reims | [aquarat/apple-macos-arm64-vm-guest](https://github.com/aquarat/apple-macos-arm64-vm-guest) |
| M1 Max, Omarchy + linux-aurora | macOS 26.4 + Xcode 27.2, 95-99 % of host CPU speed, no Apple Account | [sapoepsilon/omvm](https://github.com/sapoepsilon/omvm) |
| M2 Pro | 13.6 to Setup Assistant; M2 PAuth guard fix | [steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64](https://github.com/steelbrain/experiment-macOS-arm64-on-asahi-linux-arm64) |
| M2 Ultra, Omarchy | 13.6 daily desktop; 27.2 to Setup Assistant after two QEMU fixes (virtio PCI capabilities in ascending order; a virtio-blk vendor capability with fFeatures = 1, so APFS mounts the unencrypted Data volume) | this project's maintainer, not yet published |
| J714s (M5 Pro) | macOS 27.0 to loginwindow + SSH as aura's only guest (SPTM/NV2). Linux is not running, and a USB host drives it | [aurora-silicon/aura#70](https://github.com/aurora-silicon/aura/pull/70) |

## M5 notes

- Not needed: SPTM, GXF and nested virtualization (`VirtualMac2,1` guests run at EL1).
- Needed: the two KVM patches (PAuth state, no-syndrome MMIO decode). The MMIO patch applies cleanly to 7.3; the PAuth
  patch needs a small rebase plus the T6050 parts.
- M5 has no FEAT_SSBS. Older macOS guests need SCTLR.DSSBS faked (see the QEMU vmapple M4 RFC). Target 27.x guests.
- More GIC system-register trapping than M2 (`[G0G1CD]`): slower for interrupt-heavy loads.
- Graphics: Metal is translated to Vulkan by Reims. On M5 that means the Borealis Vulkan driver (non-conformant), with
  lavapipe or VNC as fallbacks. No native Metal.
- Licence: up to two additional virtualised macOS copies on Apple hardware that runs macOS. Supply your own AVPBooter,
  IPSW and Xcode, and never redistribute them.

## First tests

1. Probe the PAuth registers from the m1n1 proxy (read/write with the exception guard). This is the decision gate.
2. QEMU vmapple on the stock kernel until AVPBooter/iBoot hand off to XNU (no kernel change).
3. Patched kernel, a 27.2 guest headless to SSH.

Results will be added here and to `gap-map.csv` once they exist.
