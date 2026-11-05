# DCP test plan (J716s, T6050) - stage 0/1, read-only toward the display

Scope: validate the DCP description and the "decline safely" path. Nothing here starts, stops, resets or
messages the DCP; the panel stays on m1n1's framebuffer + simpledrm throughout. Brightness and modesetting are NOT
expected to change in any step. Each step is one boot; do them in order and stop at the first unexpected result.

Artifacts (all under ~/Work/agents/dcp/):
- patches/m1n1/0001-firmware-recognise-the-27.1-and-27.2-beta-iBoot-strings-seen-on-J716s.patch
- patches/omarchy-m5/0001-dt-t6050-describe-the-dcp-display-pipeline-disabled.patch (default DTB)
- patches/omarchy-m5/0002-dt-t6050-hold-disp_cpu-from-the-boot-framebuffer.patch (optional, Step 5)
- patches/omarchy-m5/0003-dcp-stage-1-test-config-fragment-and-test-dtb.patch (test-only fragment + DTB)
- patches/linux/0020-drm-apple-dcp-refuse-t6050-and-report-an-undriven-coprocessor.patch
- scripts/dcp-devmem-check.sh (read-only)
- build/*.dtb + build/SHA256SUMS (prebuilt: t6050-j716s.dtb = 0001, -fbpd = 0001+0002, -dcptest = 0001+0003)

Rollback, every step: restore the previous boot object. From Linux: `cp /boot/m1n1/boot.bin.prev /boot/m1n1/boot.bin`
(whatever path the current install uses for stage 2); if Linux does not come up: boot macOS (hold power -> Options),
mount the OMARCHY FAT volume and copy boot.bin.prev back. Before each install: `cp boot.bin boot.bin.prev` of the
known-good object, never overwrite .prev with an untested one. Power-hold (10 s) recovers any hang; none of these steps
leaves persistent state in the SoC (no NVRAM, no firmware, no PMGR writes).

## Step 0 - facts from macOS (optional, no Linux change, 15 min)
0a. Stub version (decides which DCP ABI to target): in macOS, `diskutil apfs list`, find the APFS container of the
    Linux install (the one whose Preboot holds the paired stub), mount its Preboot volume read-only, then
    `find /Volumes/<preboot> -name SystemVersion.plist -path '*CoreServices*' -exec plutil -p {} \;`.
    Record ProductVersion + ProductBuildVersion. Expected: build 26C5035r. Report whether ProductVersion is 27.2
    (inferred) or 27.3 (as stated in the brief).
0b. Locate the DCP firmware the stub pairs (for static analysis later, keep private, never commit):
    `find /Volumes/<preboot> -iname '*dcp*'`; note the file names and sizes only.
0c. Boot-brightness trick (no code): `nvram -p | grep -i -E 'backlight|bright'`. Record the variable names/values.
    Then set the panel to a low brightness in macOS, reboot into Linux, and note whether the Linux console comes up at
    that brightness (does iBoot restore the last macOS brightness for the boot object?). Repeat at high brightness.

## Step 1 - read-only register check under the CURRENT kernel (no install)
Needs a devmem reader on the target (omarchy-m5 tools/devmem.c built static, or busybox devmem if present).
`sudo sh dcp-devmem-check.sh /path/to/devmem`. Only "devmem ADDR 32" reads are issued.
Expected:
- CPU_CONTROL @0x48ae00044 has bit 4 (0x10) set -> "running".
- dart-dcp @0x48a340000: PARAMS4 num_sids plausible (<= 32); sid 23 TCR xlate=1, TTBR valid=1; record PROTECT
  (bit 0 set = iBoot locked it; unknown today) and whether TCR bit 3 (four-level) is set.
- dart-disp0 @0x48a300000: PROTECT bit 0 set (m1n1 dart_lock_adt() sets it every boot); sid 0 and sid 16 valid.
- l1-pa of dart-dcp sid 23 vs ADT l1-tt-23 0x10bffea0000, dart-disp0 sid 0 vs 0x10bffed0000 (the stub's boot may
  move them; a different but valid page-aligned address is fine; 0x0/0xffffffff is not).
Stop if: any read returns 0xffffffff/0xdeadbeef everywhere, or the machine SErrors (power-hold, report the address;
t6050-dcp.dtsi addresses would then be wrong).

## Step 2 - m1n1 firmware table (m1n1 patch 0001; same kernel, same DTB)
Build stage-2 m1n1 from ~/Work/m1n1 with the patch (git apply, do not commit), assemble boot.bin as usual
(scripts/mkpayload.sh / finish-install.sh), keep .prev.
Note: brew clang rejects src/hv/hv_sprr.c:1029 (TLBI VMALLS12E1OS needs tlb-rmi) on m5-t6050 459a3af2; the compile
check here used EXTRA_CFLAGS="-Xclang -target-feature -Xclang +tlb-rmi". Use whatever flags the current boot.bin used.
Expected on the m1n1 console/log: `OS FW version: 27.2 beta (mBoot-20457.60.65.0.1)` (was "unknown"), still
`display: Display is already initialized (3456x2234)`, `FDT: unknown compatible, skip display reserved-memory setup`,
logo and Linux console unchanged. In Linux: `tr '\0' '\n' < /proc/device-tree/chosen/asahi,os-fw-version` = 27.2 beta.
Everything else in dmesg identical to the previous boot (diff `dmesg | cut -c16-`).
If the stub turns out to be 27.3 (Step 0a), the label is wrong but behaviour is identical; report it.

## Step 3 - new default DTB (omarchy 0001), old kernel
Install build/t6050-j716s.dtb (sha256 b56049a5655e8e7f6ddfdc8af306bc247c4c8e33e050e99a35069cef669e028c) with the current Image.gz.
Expected: boot identical to before. `ls /proc/device-tree/soc | grep -E 'dcp@|iommu@48a|iommu@2b2|mbox@48ae'` lists
the new nodes; `cat /proc/device-tree/soc/dcp@48ae00000/status` = disabled (also for every new node);
`ls /sys/bus/platform/devices | grep -i dcp` is empty; dmesg has no apple-dcp/apple-dart/48ae lines;
`dmesg | grep simpledrm` still shows simpledrm on minor 0.
`hexdump -C /proc/device-tree/soc/dcp@48ae00000/apple,notch-height` = 0x4a (74) if m1n1 filled it (it looks up the
"dcp" alias; harmless). Rollback: previous DTB.

## Step 4 - drm/apple built in, test DTB, decline path (linux 0020 + omarchy 0003)
Kernel: apply-patches.sh + linux 0020; KCONFIG=(usual list) + omarchy-dcp-test.config; check .config has
CONFIG_DRM_APPLE=y, CONFIG_DRM_APPLE_AUDIO unset, CONFIG_DRM_SIMPLEDRM=y. DTB: build/t6050-j716s-dcptest.dtb
(sha256 84a8e75f56a172c901e24fba15bd5378c5b09a7d0463a27d1ffa077610638557; only the internal DCP node is okay - no mailbox, no DART, no display-subsystem).
4a. Normal cmdline. Expected dmesg (device 48ae00000.dcp):
    - `Could not read 'apple,firmware-compat'` (m1n1 does not write it for t6050) or
      `DCP firmware-compat X (FW: Y) is not supported`,
    - `no IOMFB ABI for this SoC's DCP firmware yet, the boot framebuffer stays with simpledrm`,
    - nothing from apple-dart, apple-mailbox or appledrm bind; simpledrm stays card0; console unchanged;
      `cat /sys/kernel/debug/devices_deferred` does not list the dcp (it failed with -ENODEV, not deferral).
4b. Add `appledrm.report_coproc=1`. Additional expected line:
    `coprocessor [mem 0x48ae00000-0x48ae03fff] is running (CPU_CONTROL 0x...), leaving it to the boot loader's session`
    with the same CPU_CONTROL value Step 1 read. This read is the same register Step 1 already read.
Stop if: the console goes black (should be impossible: no write path exists; report dmesg via ssh/tether), or any
apple-dart probe line appears (a DART node got enabled - check the DTB).
Rollback: previous kernel + previous DTB.

## Step 5 (optional) - boot framebuffer holds disp_cpu (omarchy 0002)
Install build/t6050-j716s-fbpd.dtb (sha256 4f1c82bd83eac124b915b2edb90607c69e4907d7cb2418e74abc4b9d4e7daca8) with the Step 3 kernel (pd_ignore_unused stays on the
cmdline: removing it would let genpd gate other unclaimed T6050 domains, which SErrors).
Expected: console unchanged; `cat /sys/kernel/debug/pm_genpd/pm_genpd_summary | grep -A2 disp_cpu` shows the
framebuffer as a consumer and status on; no PMGR write warnings. Do not suspend with this DTB (a genpd power-off of
disp_cpu at suspend would write PS while DCP drives the panel). Rollback: Step 3 DTB.

## What to report back
Step 0a ProductVersion/Build, 0b file names, 0c variables + whether brightness carries over; Step 1 full script output;
Step 2 m1n1 version line; Step 3 node list; Step 4 the apple-dcp lines; Step 5 genpd summary lines.
