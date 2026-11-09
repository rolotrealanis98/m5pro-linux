# Touch ID / SEP on the J716s, rung (a): SEP attach, discovery only

Studio-side preparation only (2026-11-08); nothing here has touched the MacBook. Rung (a) of
`FEASIBILITY.md` section 4: the kernel registers its shared-memory table with the SEP iBoot left
running (one message on endpoint 0xFE), listens to the discovery burst, opens the key store, and
nothing else. xART writes are off, no identity keybag is created, no finger is enrolled, the sensor
is never powered. Private values (the payload, the machine's UUIDs, the manifests) stay in the
Studio's `~/Work/agents/sep/` (0700); this page carries hardware constants only.

## 1. What was built

| piece | where | state |
|---|---|---|
| kernel patches (3) | `patches/linux/0001-0003` (`soc: apple: sep: Add the T6050/J716s platform profile`; `arm64: dts: apple: t6050: Describe the SEP, its DART and the Touch ID bus; wire them on the J716s`; `arm64: configs: j716s: Build the SEP driver and the Touch ID bus driver as modules`) | on branch `j716s-sep-a` = `j716s-video-observe` (`0933f881d736`, the current daily's kernel + the video-observe series) + these three, in `/Volumes/linux-cs/linux` |
| m1n1 patch (1) | `patches/m1n1/0001-kboot-Pass-chosen-apfs-preboot-uuid-to-the-kernel.patch` | on branch `hv27-t6050-sep` = `hv27-t6050` (`63e6053c`, the loader that booted the daily today) + this one, in the hv27 clone (`~/Work/agents/hv27/m1n1`, edited in the worktree `~/Work/agents/sep/m1n1-sep`) |
| loader | `~/Work/agents/sep/m1n1-build/m1n1-sep-plain.bin`, 0x430000 | see `m1n1-build/SHA256SUMS`; the recipe check rebuilds `hv27-t6050` byte-identical to `m1n1-hv27-plain.bin` (3ea65595) |
| kernel build | `~/Work/agents/sep/kbuild-sep/` (Image.gz, `t6050-j716s-sep-a.dtb`, `modules-7.3.0-g<rel>.tar.zst`, config, SHA256SUMS) by `build-kernel-sep.sh` | config = the video-observe kernel's `.config` unchanged (`CONFIG_APPLE_SEP=m` and `CONFIG_SPI_APPLE=m` were already in it from asahi.config; the daily just never shipped `apple-sep.ko`); modules = the daily list + `drivers/soc/apple/apple-sep.ko` |
| payload | `~/Work/agents/sep/sep-a-test-20261108-1ddb466a.bin` by `mk-sep-a-test.py` (label `sep-a-test`, `m5.selftest=1`, `watchdog.open_timeout=300`, the daily's variables and bootargs, plus `apple_sep.xart_writes=0 apple_sep.provision_keybag=0`) | self-reverting (stage-1 A/B + watchdog: a boot that does not come up falls back to the daily) |
| runner | `~/Work/agents/sep/run-sep-a.sh` (template `run-video-observe2.sh`; restores `daily-dcp-rec-video-20261108-26ca25f0.bin`) | refuses to run without `SEP_A_CONFIRM=yes`; prints the warning first |

### Artifacts as built (2026-11-08 10:53, Studio, all in `~/Work/agents/sep/`, 0600/0700)
| artifact | sha256 |
|---|---|
| `sep-a-test-20261108-1ddb466a.bin` (payload, 42199126 bytes, loader at 0x0+0x430000) | `1ddb466a2d7319148a95a048e935d62d004adbcb58b44048560921e2246bd678` |
| `m1n1-build/m1n1-sep-plain.bin` (loader, 0x430000; `hv27-t6050-sep` a1e855e8) | `6563f88f8caffacebb3bc7f8f91c1e55860d3c14da01a4ab6d2987e4e132ee2e` |
| `kbuild-sep/Image.gz` (`7.3.0-ga826082e87de`) | `c644af9d43948e8b1dc18ab4bbb419e1ddf6817bfaaf69484a098b7ce3714ec3` |
| `kbuild-sep/t6050-j716s-sep-a.dtb` | `1af2111221f5883e41bbf43813de92fbd4009f224ce6a824507725fa6b01cbc4` |
| `modules-7.3.0-ga826082e87de.tar.zst` (daily list + `apple-sep.ko`, `spi-apple.ko`) | `8b5c7d0f9da7f6a4a28be49fbd9a125f343b8a49b9bf1f7987e287a127940e24` |
| restore target `video-observe/daily-dcp-rec-video-20261108-26ca25f0.bin` | `26ca25f055dd83e813abdcfe898b72d56185fdd6e676bffedcd0141ad9b0f2e5` |

Fallback loader if you would rather not carry the extra m1n1 commit: `hv27/m1n1-build/m1n1-hv27-plain.bin`
(3ea65595, the daily-boot-tested one). Rebuilding the payload with it only means changing `M1N1` and its pin
in `mk-sep-a-test.py`; the kernel then logs `xART: /chosen/apfs-preboot-uuid is unavailable` (no OS identity).

### m1n1: what the loader has to add, and does
Aurora's warm-attach table needs the bootloader-injected `iboot-manifest` and `local-policy-manifest`
on the `sep` node ("refusing to attach: device-tree property '..' missing or unreadable; a CINP-only
table would burn the one-shot registration and fault", `shmem.rs`). The hv27 tree already carries
AsahiLinux's `dt_set_sep()` (`src/kboot.c`, 62ff43f0): when the DTB has the alias `sep` it reserves
`/chosen/memory-map` `SEPFW` as `/reserved-memory/sep-firmware` (+ `memory-region` on the node) and
copies `/chosen/boot-object-manifests` `lpol` and `ibot` onto the node. The J716s ADT has all three
(`SEPFW` 0x5bc000 bytes, `lpol` 2893 bytes, `ibot` 9025 bytes), so the manifests needed no m1n1
change: the DT patch adds the alias and the loader does the rest, silently (it only logs on failure,
and a failure there fails the boot, which the self-revert catches).

What m1n1 did not do is forward `/chosen/apfs-preboot-uuid`, the driver's xART OS identity
(`IdentitySource::Chosen`; "never invents one"; the enclave's `GET_OS_UUID` is answered
`STATUS_UNAVAILABLE` without it). Aura forwards it on every Mac and the study listed the port under
"Bootloader" as a prerequisite; step 0 had only done the RNG-query skip. The one m1n1 commit here
adds it (string form, length logged, value never printed). With it the kernel logs `xART: using
/chosen/apfs-preboot-uuid`; with the plain hv27 loader it would log `xART: /chosen/apfs-preboot-uuid
is unavailable` and the enclave's lane lookups would fail "unavailable", a confounder for the
90-second key-store expectation. The identity is the Linux stub volume group's, not macOS's
(OS-IDENTITY.md), so it does not point the enclave at macOS's records.

### Kernel patches, in short
- `profile.rs`: `T6050` = `T6040` (warm register, 0x40000/CINP **-> 0x1c000 since patch 0004: the macOS 27.3 capture registers a 0x1c000 table on endpoint 0xFE**, Variant5 key store, variant-5
  keybag create, nonce session, wide DMA mask, `DART_HIGH_ALIAS` fallback window, `xart_guard = 1`)
  with the J716s sensor controller base `0x505108000`, `persistent_enrol = false` (nothing is tested
  here), selected only when the root compatible has both `apple,t6050` and `apple,j716s`. KUnit
  cases added next to the existing ones (not built: `CONFIG_KUNIT` is off in this config).
- `t6050-die0.dtsi`: `sep_dart` (`iommu@500b80000`, `apple,t6050-dart`/`t8110`, IRQ 543, static
  `apple,dma-range = <0x10000004000 0xffff0000>`, `apple,dma-offset = <0>`), `sep`
  (`sep@502600000`, `apple,sep`, `ps_sep`), `sep_mbox` (`mailbox@502608000`,
  `apple,t6050-asc-mailbox`/`asc-mailbox-v4`, IRQs 533/534/535/536 as send-empty, send-not-empty,
  recv-empty, recv-not-empty), `spi2` (`spi@505108000`, `apple,t6050-spi`/`t8103-spi`, IRQ 1369,
  `ps_spi2`) with the `mesa` child (`apple,mesa-fingerprint`, 8 MHz, `spi-cpol`), `pinctrl_nub`
  (`pinctrl@2881e4000`, 61 pins, IRQs 706..718, `ps_nub_gpio`); power states `ps_sep` (pmgr1
  +0x298, always-on), `ps_spi2` (pmgr1 +0x330, parent `ps_spi_p`), `ps_nub_gpio` (pmgr2 +0x88,
  always-on). All disabled.
- `t6050-j716s.dts`: alias `sep = &sep`; `&sep_mbox okay`; `&pinctrl_nub okay` with only pin 21
  exposed and the interrupt properties deleted (J616s precedent: the AOP owns some of them);
  `&spi2 okay`; `&mesa okay` with `enable-gpios = <&pinctrl_nub 21 GPIO_ACTIVE_HIGH>`,
  `interrupts = <138 IRQ_TYPE_EDGE_RISING>` from `&pinctrl_ap`, 20 ns CS setup/hold,
  `firmware-name = "apple/mesacal-j716s.bin", "apple/msrk-j716s.bin"` (named, not shipped);
  pinctrl_ap's reserved ranges open pin 138 (`<135 4>` -> `<135 3>`). `sep` and `sep_dart` stay
  disabled: apple_sep flips them with an `of_changeset` when it loads, as on J616s.
- `j716s.config`: `CONFIG_APPLE_SEP=m`, `CONFIG_SPI_APPLE=m`.

The sensor nodes are inert in this rung: apple_sep binds the sensor only on the first open of
`/dev/sep-bio` (`activate_touchid()` -> `attach_sensor()`), which the runner never does. They are in
the test DTB so that spi2 and pinctrl_nub probing is seen once before rung (b).

## 2. Pre-flight for Rolando (do all of it before the runner)

1. **macOS state first**: boot macOS once, confirm Touch ID unlock works today (so a change
   afterwards is attributable), note FileVault state (`fdesetup status`). Do not change anything.
2. **Back up the iBoot System Container** (it holds the xART gigalocker, the device-wide SEP state
   shared with macOS; this rung opens it read-only, the backup is for the rungs after it and for
   peace of mind). On the daily Linux, as root, read-only on the source:
   ```
   P=/dev/disk/by-partlabel/iBootSystemContainer
   readlink -f $P; blockdev --getsize64 $P        # expect 576716800 (550 MiB, macOS disk0s1, 4 KiB blocks)
   dd if=$P of=/root/isc-backup-$(date +%Y%m%d).img bs=1M count=550 iflag=fullblock conv=fsync status=progress
   sha256sum /root/isc-backup-*.img; chmod 600 /root/isc-backup-*.img
   ```
   `count=550` must equal the size printed; if `blockdev` says anything else, use that size (bytes /
   1048576) and tell the agent. Then copy the image to the Studio
   (`scp root@<mbp>:/root/isc-backup-*.img ~/Work/agents/sep/private/`) and keep it 0600: it is
   per-unit SEP state and never goes into a repo or a report. A backup cannot roll the enclave's
   counters back (XART-SAFETY.md); it is what lets a corrupted store be put back, not a time machine.
3. **Machine**: on mains power, lid open, screen on, nobody using it; no other Studio runner active
   (`/run/m5pro-studio-busy` absent). The USB tether and ssh working as for every test.
4. **Studio**: `~/Work/agents/sep/kbuild-sep/SHA256SUMS`, the payload's `.recipe.txt` (bootargs end
   in `apple_sep.xart_writes=0 apple_sep.provision_keybag=0`), `m1n1-build/SHA256SUMS` (recipe check
   line present). `~/Work/agents/sep/vol/linux-cs-sep.sparsebundle` attached if anything is rebuilt.
5. Read section 4 (abort) once more, then:
   ```
   SEP_A_CONFIRM=yes ~/Work/agents/sep/run-sep-a.sh ~/Work/agents/sep/sep-a-test-20261108-1ddb466a.bin
   ```
6. **Afterwards, always**: cold boot (power off, 10 s, power on) before booting macOS; in macOS
   check Touch ID unlock and a keychain-backed login; only then any further Linux SEP test.

## 3. What the boot should show

m1n1 stage-2 log (`strings /dev/mtd0` on the booted kernel; the runner saves it):
- `SEP: Preserving iBoot warm registration; seeding RNG from ADT` and no `SEP: couldn't get enough
  random bytes` (step 0, 72ed8f9c).
- `FDT: Passing apfs-preboot-uuid (36 characters)` (the new commit).
- no `FDT: sep alias not found` and no `ADT: could not get ...` line: `dt_set_sep()` ran silently.

Device tree of the booted kernel (the runner's pre-flight, `preflight.txt`):
- `/proc/device-tree/aliases/sep` = `/soc@200000000/sep@502600000`; on that node `iboot-manifest`
  (9025 bytes), `local-policy-manifest` (2893 bytes), `memory-region`; `status = disabled`; no
  `apple,sep-shmem-registered-iova`. `/proc/device-tree/reserved-memory/sep-firmware*` present.
- `iommu@500b80000` disabled, with `apple,dma-range`; `502608000.mailbox` bound to `apple-mailbox`;
  `505108000.spi` bound to `spi-apple` with `spi2.0` under `/sys/bus/spi/devices` (no driver: the
  sensor driver is registered only on the first `/dev/sep-bio` open); `2881e4000.pinctrl` bound.
- `/dev/disk/by-partlabel/iBootSystemContainer` present (the store is opened at probe, before the
  registration; a missing link fails the probe before anything is sent).

Load (`load.txt`): `drivers_autoprobe` is set to 0 first, so `modprobe apple_sep` only runs the
module init: `apple_sep: SEP DART state: enabled=false, apple,dma-offset present=true,
apple,dma-range present=true`, `SEP DART changeset applied (..., status okay)` (the window name in
that line is the profile's fallback; the DT values are what the DART reads), `SEP node enabled;
platform device should now exist`. Then `/sys/module/apple_sep/parameters/xart_writes` and
`provision_keybag` must read `0` and `502600000.sep` must exist unbound with no registration
marker. Only then the runner asks the bus to probe `500b80000.iommu` (-> `apple-dart`) and then
`502600000.sep` (-> `apple_sep`), which is the moment the one-shot registration is sent.

Attach (`dmesg-sep.txt`, `diag.txt`), in order:
- `xART: APFS-resolved .gl extent (base 0x...); N slots, M live records, max revision R, ...; writes
  disabled` (the store validated read-only; `diag/xart = disabled`). A `created a new host-state
  store` line means `/var/lib/aurora-sep-host-state.bin` was created on the Linux root (Linux-side
  bookkeeping, not SEP state; it is left in place, see HOST-STATE.md).
- within ~3 s: `attach: N endpoints advertised in M messages` -> `diag/attach = attached`,
  `diag/endpoints` >= 1 (study: expect the control/discovery endpoints first, sbio 0x08 and scrd
  0x0a next, the key store 0x12 last; on J616s the ladder is 7 -> 11 -> 12).
- `xART: using /chosen/apfs-preboot-uuid`; the enclave's xART reads served from the read-only store;
  any `xART: refused the enclave's write (op 0x..): writes are disabled (xart_writes=0)` is the
  expected answer to a write request, not a fault.
- within 90 s: the key store advertised, `diag/keystore = open`, `diag/keybag` reporting that none
  was provisioned (`provision_keybag=0`), `/dev/sep-bio` published (0600; the runner only lists it),
  `hwrng: registered after ready-phase survey`, `rng_available` listing the SEP source.
- `diag/sensor`, `diag/touchid`, `diag/sensor_attach` unchanged from their initial values; no DART
  fault, no `SError`, no `Oops`.

Success for rung (a) = `diag/attach = attached`, `diag/xart = disabled`, key store open, no fault,
and after the cold boot macOS Touch ID still unlocks. "attached but no key store within 90 s" is a
partial result worth a report (endpoints seen, exchange stuck), not a retry: do not reload the
module (`apple_sep` refuses a second load in one boot by design) and do not reboot into the test
again before reading the logs.

## 4. Abort and recovery

- The runner refuses without `SEP_A_CONFIRM=yes`, refuses a payload whose recipe lacks the read-only
  bootargs, and stops before `modprobe` if any pre-flight line fails (nothing was sent). If the
  parameters do not read 0 after the load it `rmmod`s the unbound module (still nothing sent) and
  restores the daily.
- The payload is a self-reverting test (`m5.selftest=1`, `watchdog.open_timeout=300`): a kernel that
  hangs or panics before userspace is reset by the watchdog and stage 1 boots the daily again. The
  runner always writes the daily back to `boot.bin` at the end, whatever happened.
- **A parked SEP** (the attach fails: `attach: ... no endpoint advertised`, `diag/attach = failed`,
  or the SEP goes silent after a wrong window) is not fixed by a reboot: iBoot reloads SEPOS at
  every boot (`sepfw-load-at-boot = 1`) but the enclave's state needs a power cycle. The runner then
  **powers the MacBook off instead of rebooting**: wait 10 s after the screen is dark, press power;
  the daily boots (boot.bin already restored). Then macOS once, Touch ID check, before anything else.
- If the Mac does not come back at all: hold power 10 s, power on; stage 1 falls back on its own. If
  it still does not boot Linux, macOS from the Startup Manager, then the usual ESP restore
  (`r1-deploy.sh restore prev`) from there.
- If macOS Touch ID does not work afterwards: do not re-enrol in macOS right away; collect the Linux
  logs (`~/Work/agents/sep/sep-a-<date>/`), note what macOS says, and decide with the ISC backup in
  hand. This rung wrote nothing to the store, so a macOS-side change would be an enclave reaction to
  the session itself (Aurora has seen a macOS boot both clear and cause a refusal, #209/#396), which
  is exactly what rung (a) is meant to find out before any writer runs on this machine.
- Never: `--reset-touchid`, deleting `/var/lib/aurora-sep-*`, copying state files, loading with
  `xart_writes=1`, opening `/dev/sep-bio` by hand (it powers the sensor and starts a session).

## 5. What the ADT said against the study (read on the Studio from the runtime ADT, names/offsets only)

- The study's mesa property list (`SensorID`, `mesa-state`, `MesaCalBlobSource`, `patch-version`,
  `spi-clock-phase`) is macOS IORegistry (AppleBiometricSensor), not ADT: the ADT node has
  `sensor-id = 0x3356` (V3, as expected), `mesaType = 1`, `spi-frequency = 8000000`,
  `interrupts = [138, 3]` on `gpio0`, `function-mesa_pwr = GPIO(nub-gpio0, 21, 0x101)`, power-on/off
  delays and the SMC current monitor, and **no SPI-mode property**: the bus configuration sits in
  the child's `reg` words (word 2 `0x08010100`; the SoC's other SPI slaves, the NOR and spi4's
  parts, have `0x08010000`). CPOL vs CPHA cannot be read off that alone, so the DT keeps the sensor
  family's mode 2 (`spi-cpol`, as J700/J616s/J713); rung (b) can flip it with
  `apple_sep.sensor_spi_mode=1` without a rebuild (the node's mode is what the shim programs; the
  profile's is informational).
- The data-ready interrupt type: the ADT says `3`; on this ADT type `1` is what Linux wires as
  `IRQ_TYPE_LEVEL_LOW` (the amps, the jack codec), so `3` is something else, and every board with
  this sensor takes the line as `IRQ_TYPE_EDGE_RISING`. Used that; the IRQ is not touched in rung (a).
- `dart-sep`: the study's "vm-base/vm-size" are the whole DART (`0x10000000000` + `0x30000000000`,
  three streams); the window that matters is stream 0's, `vm-base-0 = 0x10000004000`,
  `vm-size-0 = 0xffff0000` (`sid-count 3`, `exclave-sid 2`; `mapper-sep` = stream 0 is the SEP's
  `iommu-parent`, `mapper-sep-exclave` = stream 2 is `esm`'s). T6040's static window is
  `0x3ff00000` long; T6050's is `0xffff0000`, and that is what the DT carries.
- The SEP's mailbox IRQs: the ADT order `[534, 533, 536, 535]` is the T6050 die's convention
  (SMC `[900, 899, 902, 901]`, ANS `[1348, 1347, 1350, 1349]`, both booted) = [send-not-empty,
  send-empty, recv-not-empty, recv-empty], so the DT lists 533, 534, 535, 536.
- `/chosen/boot-object-manifests` has `lpol` and `ibot` (the study had noted only `sepi`): m1n1's
  `dt_set_sep()` works unchanged. `/chosen/apfs-preboot-uuid` is present as a 36-character string.
- Power: the study's missing `pinctrl_nub` also needs `NUB_GPIO` (pmgr group 2 +0x88, critical);
  `SEP` (185) is group 1 +0x298, critical, parent FAB8_SOC; `SPI2` (204) group 1 +0x330 under
  `SPI_P` (199). The ADT agrees with OJ's `t6050-pmgr.dtsi` offsets.
- Unchanged from the study and untouched here: `/arm-io/esm` (exclave SEP manager, IRQs 540/537,
  DART stream 2) and the macOS mesa driver's ANE power lookup. Whether the discovery completes
  without the exclave manager is one of the things rung (a) answers.

## 6. Build notes (Studio)
- Two build volumes died under the kernel build today, both **sparsebundle** disk images:
  `/Volumes/linux-cs-gpurec` (shared; four other agents were building on it; registered `wt-sep`
  there 09:59, committed 10:03, ENXIO "Device not configured" on every file read and write from
  ~10:09) and then my private `linux-cs-sep.sparsebundle` (ENXIO at ~10:19 after a few minutes of
  compiling). Each time the container's VM had first logged "Too many open files in system" (its
  `fs.file-max` defaults to 111919). The Studio's long-lived build volumes (`linux-cs`, `loopq-out`,
  `tb-daily`, the n1k out volume) are single-file `.sparseimage`s, so the build now runs on
  `~/Work/agents/sep/vol/linux-cs-sep2.sparseimage` at `/Volumes/linux-cs-sep2` (`wt-sep`,
  `wt-sep-out`, 5 GiB guard), with `fs.file-max` raised inside the container (to 1648448, the VM's
  ceiling) and `-j6`. Nothing was done to the shared volume or to the dead bundle (still attached as
  `/Volumes/linux-cs-sep`): their owner should detach/check them and `git worktree prune` the two
  dead `wt-sep` registrations in `/Volumes/linux-cs/linux`. The branch and its commits were never at
  risk: they live in the main repository.
- `build-kernel-sep.sh` retries the container step in a fresh container on a file-handle or mount
  fault (the object dir persists) and records `fs.file-nr` in `kbuild-sep/attempts.txt`.
- The runner probes the DART and the SEP through `/sys/bus/platform/drivers_probe`, not the
  drivers' `bind` files: `apple-dart` suppresses its bind attributes, and `drivers_probe` works with
  `drivers_autoprobe = 0`, which is what keeps `modprobe apple_sep` from binding before the parameter
  check.

## Update 2026-11-09 (after the hypervisor capture)

macOS 27.3's AppleSEPManager, captured under the m1n1 hypervisor on this J716s
(`contrib/pending/hv/captures/DECODE-SEP-SMC-DCP-20261109.md`), registers a **0x1c000**-byte table on endpoint 0xFE
(warm registration, no boot-ROM traffic), then receives seven endpoints (hibe 0x14, stac 0x18, cntl 0x00, xars 0x10,
xarm 0x13, pnon 0x15, hdcp 0x0e), does GET_ENTROPY (tag 8, no NOP probes), per-endpoint OOL buffers, SECMODE, and
drives hdcp, stac and xars. Patch `patches/linux/0004-soc-apple-sep-T6050-register-a-0x1c000-table.diff` sets
`shmem_capacity` for T6050 accordingly (the manifests tile to 0x14000, so they fit). Rebuilt payload:
`sep-a2-test-20261108-fb200ca2.bin` (agent dir, runner `run-sep-a2.sh`). Differences that stay in the Linux attach
and may matter if discovery stalls at 7 endpoints: the NOP survey before SECMODE, entropy tag 0xE7, and the three
endpoints (hdcp, stac, xars) Linux does not drive. The registration is one-shot per boot: a wrong table parks the
SEP until a cold boot, so the backup step before rung (a) stands.
