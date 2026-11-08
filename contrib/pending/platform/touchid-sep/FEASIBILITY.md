# Touch ID + Secure Enclave on the M5 Pro (T6050 / J716s): feasibility map

Desk research only (2026-11-08); nothing booted. Sources: the local kernel
worktrees in `/Volumes/linux-cs/linux` (`AI:` = remote `aurora/integration`
@ 33bec4016c46 = github.com/aurora-silicon/linux; `WIP:` = `aurora/aurora-wip`
@ 05eaa1f71fa0; `OJ:` = `omacom/j716s` @ 23480bf91efd = omacom/linux-aurora;
`JL:` = local `aurora-j716s` @ b790125548c4), AsahiLinux m1n1 at `~/Work/m1n1`,
the Aura bootloader clone `~/Work/agents/aurora-prs-2/ref/aura`
(aurora-silicon/aura @ 21a8ab9, 1.0.0b6), public GitHub read via `gh`
(aurora-silicon/linux default branch `integration/aurora` @ feb65753a18a,
aurora-sep-userspace @ c80144bd654a, aurora-silicon.github.io @
6bc583afd862, omacom/omarchy-mac-pkgs, omacom/omarchy-pkgs,
omacom/linux-aurora and chriskearney/aurora-linux issues), the private
J716s runtime ADT and the macOS 27.3 ioreg/kernelcache dumps under
`~/Work/studio-artifacts/` (cited by node/property/class name, offset and
size only; no per-unit values).

## 1. What Aurora's Touch ID stack is

### Kernel (`drivers/soc/apple/`, Rust, module `apple_sep`)
- `sep.rs` (2792 lines) + `profile.rs`, `sbio.rs`, `sks.rs`, `xarm.rs`,
  `xart_store.rs`, `xart_apfs.rs`, `keybag.rs`, `keybag_identity.rs`,
  `os_identity.rs`, `sensor.rs` + `sensor_shim.c`, `pm.rs`, `fv.rs`,
  `hwrng.rs`, `trusted.rs`, `diag.rs` (`AI:drivers/soc/apple/sep.rs:10-44`,
  `Makefile:44-46`). Kconfig `APPLE_SEP` (tristate, `default m if
  ARCH_APPLE`) depends on RUST, SPI, RUST_APPLE_MAILBOX, OF_DYNAMIC,
  HW_RANDOM, TRUSTED_KEYS, PM (`AI:drivers/soc/apple/Kconfig:151-190`).
- Origin: `93198abf2df1` 2024-11-10 Sasha Finkelstein "soc: apple: Add SEP
  driver" (353 lines, mic secure-disable only; this is what the Asahi base
  of the J716s kernel, `m5-t6050` = asahi-wip-7.2 @ 236788cd2602, carries).
  Everything Touch ID is Aurora, 2026-09-09 onwards (`cfb448ae49f1`
  DjDeveloperr "add Apple SEP driver (Touch ID and key sealing)";
  `bc78c192066a` Chromatischer "add typed platform profiles";
  `9ada58c94be2` "use shared xART gigalocker"; latest on AI `def843b07b33`
  2026-11-06; lockout/password re-arm work is WIP-only, 2026-11-07/08).
- Binding: `compatible = "apple,sep"` only, generic ASC mailbox
  (`mboxes`/`mbox-names = "mbox"`, DTS mailboxes are
  `apple,tXXXX-asc-mailbox` + `apple,asc-mailbox-v4`), `iommus = <&sep_dart 0>`,
  optional `power-domains`, `memory-region`, `iboot-manifest`,
  `local-policy-manifest` (`AI:Documentation/devicetree/bindings/soc/apple/apple,sep.yaml`).
  No RTKit; the SEP speaks its own endpoint protocol: control 0x00, SBIO
  0x08 (biometrics), SCRD 0x0a, SKS 0x12 (key store / keybags), XARM 0x13
  (the SEP asks the AP to read/write the xART "gigalocker"), discover 0xFD,
  shmem 0xFE, boot 0xFF (`AI:drivers/soc/apple/proto.rs:8-15`, `sep.rs:2288-2306`).
- **Two boot models, selected by the platform profile**:
  - *Cold boot* (M1 only: T8103, T6000/1): `MSG_BOOT_TZ0` on 0xFF, then
    `dma_map_resource` of the reserved region `sepfw`, `MSG_BOOT_IMG4` with
    the firmware IOVA and the `iboot-manifest`/`local-policy-manifest`
    props, then `MSG_SET_SHMEM` (`sep.rs:1042-1160`, `shmem.rs:28-29,200`).
    m1n1 injects those: AsahiLinux m1n1 `src/kboot.c` `dt_set_sep()`
    (62ff43f0, Sasha Finkelstein, 2024-11-10) keys off the FDT alias `sep`,
    reserves `/chosen/memory-map` `SEPFW` as `/reserved-memory/sep-firmware`
    and publishes `lpol`/`ibot` from `/chosen/boot-object-manifests`.
  - *Warm attach* (`Bootstrap::WarmRegister`, everything newer: T8112,
    T6020/1, T8122, T8140, T6040/1, T8132): iBoot leaves a running SEP; the
    driver sends one shared-memory registration on 0xFE and expects the
    discovery burst on 0xFD (`sep.rs:1010-1040`). The SEP and its DART ship
    `status = "disabled"` in the DTS and are flipped to `okay` by an
    `of_changeset` at module init, with the DART `apple,dma-range` taken
    from the profile because "The SEP only accepts IOVAs in the window iBoot
    programmed" (`dt.rs`, `AI:arch/arm64/boot/dts/apple/t604x.dtsi:943-949`).
    A DT marker `apple,sep-shmem-registered-iova` is written before the
    registration message so a reload can never register twice ("could park
    the SEP", `sep.rs:1020-1035, 2645-2651`): registration is one-shot per
    boot, and a wrong IOVA/size parks the SEP until a cold boot. **Even on
    warm machines the shared-memory table needs the bootloader-injected
    `local-policy-manifest` and `iboot-manifest` props** (`shmem.rs:28-29,
    104-110, 190-200`: "refusing to attach: device-tree property '..' missing
    or unreadable; a CINP-only table would burn the one-shot registration and
    fault"); m1n1's `dt_set_sep()` provides them when the DT has the `sep`
    alias. The cold/warm choice is hard-coded per profile; the kernel never
    reads `sepfw-booted`/`sepfw-load-at-boot`.
- **SoC gating**: `profile.rs::select()` (`AI:drivers/soc/apple/profile.rs:617-670`)
  matches whole entries of the root `compatible` list and returns `ENODEV`
  for unknown SoCs, refusing unchecked boards even on known SoCs (T8122 only
  j613/j615, T6040 only j614s/j616s, T6041 only j616c, T8132 only j713).
  Profiles: T8103 `:191`, T6000 `:234`, T6020 `:270`, T6020_SEPOS13 `:308`,
  T8140 `:324`, T8112 `:369`, T8122 `:417`, T6040 `:441`, T6041 `:455`,
  T8132 `:472`. A `PlatformProfile` holds: shmem capacity (0x30000 M1 /
  0x40000 later) and first item (`CNIP`/`CINP`), bootstrap (Boot /
  WarmRegister), sensor {controller base (diag only), CS, 8 MHz, 20 ns
  CS setup/hold, SPI mode 1|2, expected ID 0x3352|0x3356}, DART window
  (`apple,dma-offset`/`dma-range`), `wide_dma_mask`, `firmware_region`
  (cold only), `keybag_create` variant, `nonce_session`, key-store dialect
  (Sepos13 / Variant5), `persistent_enrol`, `xart_guard` level. No endpoint
  ids or xART layout live in it. Log on miss: `no platform profile for this
  SoC; the SEP stays disabled` (`sep.rs:2724`). **No T6050/J716s string
  exists in AI, WIP, JL or OJ**; only the inventory compatibles commit
  f67926c275ea (2026-11-08) names T6050 in `apple,sep.yaml`.
- Userspace surface: misc device `/dev/sep-bio` (0600, published only after
  SKS is ready), uapi `include/uapi/linux/apple-sep.h`
  (`SEP_BIO_IFACE_VERSION 5`, ioctls `SEP_BIO_GET_INFO/LIST/ENROL_START/
  ENROL_POLL/VERIFY_START/VERIFY_POLL/CANCEL/DELETE/DELETE_ALL/ATTEST/
  LIST_ENCLAVE/DELETE_ORPHAN/PREPARE_ENROL`); only operation, stage,
  status, opaque UUID and host label cross it. Also hwrng, Linux trusted
  keys sealed to the enclave ref-key, a FileVault kernel API, and read-only
  sysfs `diag/*` (`AI:Documentation/ABI/testing/sysfs-driver-apple-sep`).
- Sensor ("mesa"): an SPI slave child of the SoC `spi2`, `compatible =
  "apple,mesa-fingerprint"`, native CS 0 (20 ns CS setup/hold), 8 MHz,
  `spi-cpha` or `spi-cpol` per board, data-ready `interrupts`, power via
  `enable-gpios` *or* SMC rails (`apple,smc-power-key`/`-rails`, J700),
  `firmware-name = "apple/mesacal-<board>.bin", "apple/msrk-<board>.bin"`
  (`AI:Documentation/devicetree/bindings/input/apple,mesa-fingerprint.yaml`,
  `sensor_shim.c:470-504`). The host only moves frames; the SEP matches
  ("no biometric image ever crosses to userspace", `sbio.rs:4-5`). Two
  sensor generations: 0x3352 (M1, M2, M3 Air) and 0x3356 "V3" (J700, M4
  family) which needs a nonce-authenticated session with the signed root
  key `msrk-*` (`profile.rs:464-472`, `sbio.rs:2313`).
- Power/sleep: enclave power domains are held on across sleep via device
  links ("once one of them is switched off, it stops reading its mailbox
  for good", `pm_shim.c:74-82`); captures are ended before suspend
  (`pm.rs:3-4`); hibernation refused (`AI:tools/aurora-sep/HIBERNATION.md`).

### Persistent state and what "keybag" / "bless" mean
- Linux has its own SEP identity: an *identity keybag* created through SKS,
  wrapped by the enclave, stored as `/var/lib/aurora-sep-keybag.bin`
  (`keybag.rs:1-62`). "NEVER create a second bag while a stored blob exists:
  it orphans the previous one in the enclave with no recovery"
  (`keybag.rs:6-8`). Other host files: `aurora-sep-refkey*.bin`,
  `apple-sep-catacomb-*.bin`, `aurora-sep-host-state.bin` (identity index +
  lockout; "Nothing regenerates it", `AI:tools/aurora-sep/HOST-STATE.md`),
  `aurora-sep-xart-*.bin` guard files.
- The device-wide store is the **xART gigalocker**, a 6 MiB `.gl` file in
  the iBoot System Container APFS volume shared with macOS. Linux opens
  `/dev/disk/by-partlabel/iBootSystemContainer`, resolves the extent via
  read-only APFS metadata and writes only to a single unsnapshotted extent
  (`xart_store.rs:16,176-195`, `xart_apfs.rs`). The anti-replay lane is
  selected by an OS UUID (`/chosen/apfs-preboot-uuid`, forwarded by Aura):
  "Two operating systems that present the same identity share a lane, and
  enrolling in one of them invalidates the other's material"
  (`AI:tools/aurora-sep/OS-IDENTITY.md:1-5`).
- Module params: `xart_writes` (default 1), `provision_keybag` (default 1,
  requires `xart_writes`), `xart_guard` (level 1 refuses rewriting records
  Linux did not create; default 1 on M2/M3/M4 Pro, 0 on M1 since
  `def843b07b33`) (`sep.rs:2741-2790`, `AI:tools/aurora-sep/XART-SAFETY.md`).
  "With writes off the driver still attaches, but refuses Touch ID enrol and
  verify: the enclave saves anti-replay state after every match" (Kconfig
  help `:172-190`).
- **"bless" is unrelated to Touch ID**: `aurora-bless` is Aurora's fork of
  `asahi-nvram`/`asahi-bless` (startup-volume selector with Neo NVRAM
  support; omacom/omarchy-pkgs `pkgbuilds/aurora-bless/PKGBUILD`,
  github.com/aurora-silicon/aurora-bless). The word does not occur in the
  SEP driver or its docs. "Reset" = `aurora-xart reset-touchid`
  (github.com/aurora-silicon/aurora-xart; "like xartutil on macOS", never
  writes xART, has no erase) or `install-aurora-sep.sh --reset-touchid`:
  moves Linux's own state files aside so the driver creates a new keybag;
  the old bag stays an orphan in the enclave; restoring old files never
  rolls back the enclave's counters (`XART-SAFETY.md`, `HOST-STATE.md`).

### Bootloader
- AsahiLinux m1n1 (what this project boots with) queries the SEP ROM
  endpoint for the RNG seed on every boot (`~/Work/m1n1/src/kboot.c:316`,
  `src/sep.c`). Aurora's installer treats that as a stop condition: it
  expects the stage-2 log line `SEP: Preserving iBoot warm registration;
  seeding RNG from ADT` and "NO line reading 'SEP: couldn't get enough
  random bytes'" (`AI:tools/aurora-sep/install-aurora-sep.sh:6474`). Aura skips that on everything but T8103/T600x: "On M2
  (T8112, T602x) and later SoCs, iBoot establishes hardware warm registration
  of the SEP and Touch ID sensor before handoff. Querying the SEP ASC
  mailbox in aura desynchronizes this state, causing the SEP firmware to
  refuse subsequent biometric commands." (aura `src/kboot.c:858-876`,
  `sep_warm_active`). Aura also forwards `apfs-preboot-uuid` and has a
  J614s special case for SEP ranges overlapping DCP logs (`:7096-7200`).

### Userspace
- `aurora-silicon/aurora-sep-userspace`: libfprint driver `aurora`
  (`libfprint/drivers/aurora/aurora.c`, shipped as
  `libfprint/libfprint-1.94.100-apple-sep.patch`, binds the misc device by
  name: `FPI_DEVICE_UDEV_SUBTYPE_MISC, .misc_name = "sep-bio"`, accepts ABI
  v4/v5), fprintd 1.94.5 patches, `touchid-rearm` PAM module (password
  required after boot and after 48 h / 156 h, `/etc/aurora/touchid.conf`),
  `luks/` (SEP-sealed LUKS2) and `fido/`. README: "The enclave does all of
  the matching, so no image, template or key material ever reaches
  userspace." (https://github.com/aurora-silicon/aurora-sep-userspace/blob/c80144bd654a/README.md)
- Kernel-tree glue `tools/aurora-sep/`: `apple-sep.service`
  (`ConditionPathExists=/dev/disk/by-partlabel/iBootSystemContainer`,
  `modprobe apple-sep`), `apple-sep.path`, `fprintd-aurora.conf`,
  `extract-mesa-calibration`, sleep hook, Arch package `aurora-touchid`
  (`aurora-touchid-setup` = `fprintd-enroll`, `fprintd-verify`, then PAM
  edits for sudo/polkit/omarchy-lock) (https://github.com/aurora-silicon/linux/tree/feb65753a18a/tools/aurora-sep).
- Omarchy: `libfprint-git` on aarch64 carries the same driver
  (omacom/omarchy-pkgs `pkgbuilds/libfprint-git/`, drop-in
  `fprintd-aurora-touchid.conf` = `DeviceAllow=/dev/sep-bio rw` +
  `DeviceAllow=char-input r`); the flow lives in omacom/omarchy-mac-pkgs
  `omarchy-mac/lib/touchid-eligibility` (DT-only check),
  `entrypoints/enable-fingerprint` (consent text: "Touch ID on Linux is
  experimental and can be unstable. It shares this Mac's Secure Enclave with
  macOS, so back up any data on your macOS partition first."),
  `lib/touchid-enable` (extracts `apple/mesa_calibration.bin` from this
  Mac's iBoot System Container, writes `/etc/modprobe.d/omarchy-mac-touchid.conf`
  with `options apple_sep xart_writes=1 provision_keybag=1`, `modprobe apple-sep`).
- **macOS prerequisites: none** (no macOS enrolment, password or pairing).
  The Mac must still have its iBoot System Container (the macOS stub):
  calibration and the V3 sensor root key come from it, and the xART store
  lives in it. The early PR omacom/linux-aurora#7 (2026-09-18) asked for a
  macOS enrolment and a copied `/var/root/mesa_calibration.bin`; that was
  superseded by the NVMe extraction. Observed interactions with macOS
  boots: a macOS boot after a fresh Linux install cleared a refused keybag
  creation on M2 Max (omacom/linux-aurora#209), while on an M3 Air one
  macOS boot left Linux Touch ID blocked on every boot (#396, open).

### Where it works today
- Omarchy offers Touch ID only on `t8112`, `t6020`/`t6021`, `t8140`, and
  `t8122` with `j613`/`j615`; M1 family returns `unsupported:m1-family`
  ("wait for their xART guard path"); every M4 and M5 board returns
  `unsupported:board` (omacom/omarchy-mac-pkgs `lib/touchid-eligibility`).
- Aurora's public matrix (aurora-silicon.github.io `src/data/support.json`
  @ 6bc583afd862): works on j700, j613, j413/j415/j493, j414s/c, j416s/c,
  the M1 family, j616s (T6040, "an enrolled finger matches across reboots",
  PRs #498/#545) and j616c (T6041, #732); partial on j713 (installer does
  not collect its sensor files, #457); untested j715 (#1129); none on j604;
  **no Touch ID row at all for any M5 board (j714s, j716s, j714c, j716c,
  j704, j813, j815)**. The project's own J716s report omacom/linux-aurora#423
  lists Touch ID as "not planned".
- Tree evidence per `profile.rs` doc comments: T8103/J313; T6000 J314s/J316s;
  T6020 J414s ("enrol, match, and reboot"); T8140 J700; T8112 J413/J415;
  T8122 J613 (J615 not run); T6040 J614s/J616s; T8132 J713; T6041 J616c
  (`profile.rs:5-6, 228-232, 407-415, 430-472, 655-667`). T6030 (M3 Pro/Max)
  has no profile and no DT nodes (omacom/linux-aurora#418, PRs #282/#581 open).
- Owner reports: j313 enrol/verify/sudo/polkit/lock, survives s2idle
  (chriskearney/aurora-linux#42); j316c all pass incl. verify after reboot
  (omacom/linux-aurora#309); j493 4 reboots + 3 s2idle cycles (#142).
- Known limits: attach happens once per boot ("reboot rather than
  restarting the service or reloading apple_sep"); hibernation unsupported;
  j316s "Touch ID lost after resume" (support.json); T8112 lacks the
  data-ready IRQ and polls SPI (#53); keybag creation can time out and leave
  an `EEXIST` intent (#209, #369); `CREATE_KEYBAG` status -13 on some J413
  (#397); boot-policy change (new Stage 1) strands Touch ID until
  `aurora-sep-policy-change` (aurora-silicon/linux#1190, J616s); lockout
  after failed matches needs a password and persists across reboot; xART
  writes not byte-validated on M2 (`tools/aurora-sep/README.md`); "Login
  must stay password-based until a live post-reboot identity and successful
  match are independently verified" (same README).
- Project rule (aurora-silicon/linux and omacom/linux-aurora
  `CONTRIBUTING.md`): distinguish enrolment, verification and verification
  after a reboot; never post enrolled data; never reset a keybag to prepare
  a report.

## 2. What the J716s / T6050 has (ADT, macOS 27.3)

| ADT node | compatible | What matters |
|---|---|---|
| `/arm-io/sep` | `iop-sep,ascwrap-v6` | `reg` = {bus 0x3_0260_0000 size 0x88000, bus 0x3_0205_0000 size 0x4000}; arm-io bus 0 -> phys 0x2_0000_0000, so `sep@502600000`-style in Linux (macOS `sep@2600000`); AIC irqs 534,533,536,535; pmgr gate `SEP` (id 185); `iommu-parent` -> `dart-sep/mapper-sep`; **`sepfw-loaded = 1`, `sepfw-booted = 1`** (iBoot already booted SEPOS -> warm attach, like T8112+), `sep-boot-slot = 2`, `sika-support = 1`, `aarch64`, `cpu-ctrl-filtered`, `self-power-gate`, `ucert-*`, `ucont-*`, `iop-version = 1` |
| `/arm-io/sep/iop-sep-nub` | `iop-nub,sep` | `tz0-size-set = 1` (~32 MiB), `tz1-size-set = 0`, `ar0-size-set = 1`, `ar1-size-set = 0`; children `Sandcat`, `xART`, `InvalidateHmac` |
| `/arm-io/dart-sep` | `dart,t8110` | `reg` = {0x3_00b8_0000 size 0x20000, 0x8_03f0_0000 size 0x4000}, irq 543, `sid-count = 3`, `exclave-sid = 2`, 16 KiB pages, `vm-base`/`vm-size` present (these give the profile's `apple,dma-range`; values intentionally not copied here, read them from the ADT when writing the DT) |
| `/arm-io/esm` | `iop,exclave-sep-manager` | **new vs. M1-M4 trees**: `com.apple.service.ExclaveSEPManager`, irqs 540,537, reg 0x5_4267_c000; macOS `ExclaveSEPManagerProxy`. Nothing in AI references it |
| `/arm-io/error-handler/sep-error-handler` | - | irqs 541,542,546-549 |
| `/arm-io/spi2` | `spi-1,spimc` | `reg` 0x3_0510_8000 size 0x4000 (macOS `spi2@5108000`), irq 1369, pmgr `SPI2` (204) under `SPI_P` (199); dma via sio (unused by `spi-apple`) |
| `/arm-io/spi2/mesa` | `biosensor,mesa` | **SPI slave, CS 0, 8 MHz, `mesaType = 1`**, data-ready = `gpio0` (AP pinctrl) pin 138, type 3; power = `nub-gpio0` pin 21 (`function-mesa_pwr`, GPIO form, not SMC); `function-monitor-current-3v0` = SMC key `IIDR`; HID event -> `/buttons`; macOS `AppleBiometricSensor` + `AppleMesaLib` plug-in on `AppleSPIMCController`, `AppleMesaSEPDriver`, `AppleBiometricServices` under `sep-endpoint,sbio`; `SensorID`, `mesa-state`, `MesaCalBlobSource`, `patch-version`, `spi-clock-phase` properties exist (values not recorded) |
| `/chosen` | - | `sepfw-load-at-boot = 1`, `enable-sep-rm = 0`; `memory-map` `SEPFW` (0x5BC000 B) and `SEPPatches` (0xC000 B); `boot-object-manifests`/`secure-boot-hashes` `sepi`; `syscfg-keybag-*` |
| pinctrl | `gpio0` (`gpio,t8101`, 0x9c00_0000 size 0x44000, 221 pins); `nub-gpio0` (0x881e_4000 size 0x4000, 61 pins) | Linux needs `pinctrl_nub` for the power pin; JL/OJ T6050 DTs have only `pinctrl_ap` |

macOS endpoints on the J716s: `cntl hibe stac xars xarm pnon hdcp sbio skdl
sse scrd sks` (`m5-ioreg-l.txt:21117-21515`). Kexts: `AppleSEPManager`,
`AppleSEPKeyStore`, `AppleCredentialManager`, `AppleBiometricSensor`,
`AppleMesaSEPDriver`, `AppleBiometricServices`, `ExclaveSEPManagerProxy`,
`SEPHibernation` (`m5-kextstat.txt`). Kernelcache strings
(`derived/kc.macho`): `sep-boot-slot` 0x6b3e4f, `sepfw-booted` 0x6afe65,
`biosensor,mesa` 0x6181ba, and `AppleMesaSEPDriver: Using ANE0` /
`Trying ANE1` 0x61a8ab-0x61a91b: **the M5 mesa driver looks up an ANE power
function**, which no earlier board needed.

Evidence the warm model applies: the project's m1n1 prints `SEP: couldn't
get enough random bytes for KASLR seed` on the J716s
(`~/Work/studio-artifacts/boot-arch-1.log:37`): the ROM getrand on 0xFF
times out, exactly the symptom Aura avoids by not touching the mailbox.

### Comparison with the closest supported SoC (T6040 / J616s, `AI:t604x.dtsi`, `t604x-j614-j616.dtsi:1742-1790`)
| | T6040 J616s | T6050 J716s (ADT) |
|---|---|---|
| sep | `sep@406600000`, size 0x88000, `ps_sep`, mailbox `sep_mbox` + 4 irqs, `apple,t6041-dart` with `apple,dma-range` | `sep` size 0x88000, pmgr `SEP`, 4 irqs, `dart,t8110` with `exclave-sid`; same shape |
| boot | warm attach | `sepfw-booted = 1` -> warm attach |
| sensor | spi2, mode 2, 0x3356 V3, nonce session, power NUB GPIO 53, data-ready AP GPIO 116 | spi2, `mesaType = 1`, power NUB GPIO 21, data-ready AP GPIO 138; sensor ID/mode to be read from the ADT (`SensorID`, `spi-clock-phase`) |
| extras | - | `esm` exclave SEP manager; ANE power lookup in macOS mesa driver |

## 3. What is missing for T6050 / J716s

Per-SoC:
- `sep`, `sep_dart`, `sep_mbox`, `spi2` nodes in `t6050-die0.dtsi`
  (addresses/irqs above), `pinctrl_nub`; `ps_sep` (0x298) and `ps_spi2`
  (0x330) already exist in `OJ:t6050-pmgr.dtsi:912,1078` but not in `JL`.
- A `T6050` `PlatformProfile` + `select()` arm gated on `apple,j716s`
  (template: T6040, `profile.rs:441-462`: warm register, wide DMA, V3
  sensor, nonce session, `xart_guard = 1`), with the DART window from
  `dart-sep` `vm-base`/`vm-size`.
- `CONFIG_RUST=y` + `CONFIG_APPLE_SEP=m`: `OJ:arch/arm64/configs/j716s.config:6-7`
  forces `CONFIG_RUST=n`; `JL` asahi.config has both on.
- Unknowns: whether the SBIO path works without the `esm` exclave manager
  (M4 trees have no such node and work; the M5 exclave split is new), and
  whether the sensor needs ANE power (macOS looks it up).

Per-board:
- `&mesa` wiring in `t6050-j716s.dts`: `enable-gpios = <&pinctrl_nub 21 ...>`,
  `interrupt-parent = <&pinctrl_ap>`, `interrupts = <138 ...>`, SPI mode from
  the ADT, `spi-cs-setup/hold-delay-ns = <20>`, `firmware-name =
  "apple/mesacal-j716s.bin", "apple/msrk-j716s.bin"`; `aliases { sep = &sep; }`.
- Per-machine calibration/root-key extraction from the iBoot container.

Bootloader:
- Port Aura's `sep_warm_active` (skip the SEP RNG query on T6050) and the
  `apfs-preboot-uuid` forward into `patches/m1n1` **before** any SEP work.

## 4. Feasibility ladder

| Step | Effort | What can go wrong | Irreversible? | macOS first |
|---|---|---|---|---|
| (0) m1n1 stops querying the SEP on T6050 (aura `kboot.c:858-876`). | hours | nothing; removes a known desync cause | no | none |
| (a) SEP attaches, discovery only: `sep`/`sep_dart`/`sep_mbox` nodes + `sep` alias (so m1n1 injects the manifests) + a T6050 profile cloned from T6040 (warm, Variant5, CINP, 0x40000, nonce session, wide DMA, DART window from the ADT, `xart_guard = 1`), module loaded with `xart_writes=0 provision_keybag=0`. Success = `attach: N endpoints advertised in M messages`, SKS advertised within 90 s, sysfs `diag/*`, hwrng. | days (DT from ADT + a profile arm; the driver refuses unknown SoCs, so nothing runs until the arm exists) | The 0xFE registration is one-shot per boot: a wrong DART window/IOVA parks the SEP until a cold boot (iBoot reloads SEPOS: `sepfw-load-at-boot = 1`). With writes off the xART store opens read-only, enclave write requests get EROFS, and "the driver still attaches, but refuses Touch ID enrol and verify". `repair_disk()` only runs with writes armed. | no | none; re-check macOS Touch ID afterwards anyway |
| (b) Sensor enumerates: `spi2` + `pinctrl_nub` + `mesa` node, calibration blob, sensor-ID readback via SBIO (`diag/sensor`). | days | Power/mode mismatch: binds but no identities (J293 lesson, `t8103-j293.dts:113-118`); possible ANE-power dependency. No SEP state written. | no | none |
| (c) Enrol + verify on Linux: `xart_writes=1 provision_keybag=1`, `/dev/sep-bio`, aurora libfprint + fprintd. | weeks; first xART writer on an M5-class SEP; wait for an upstream T6050/T8150-class profile if one appears | **Writes device-wide SEP state**: identity keybag via SKS and xART records in the shared gigalocker. Known behaviours on newer Macs: keybag creation rewrites a shared root; boot-policy changes trigger record rewrites; `xart_guard=1` blocks touching macOS-created records. A bad write = orphaned Linux bag (re-enrol on Linux) and, in the worst case, macOS Touch ID re-enrolment / keychain check. | yes for the Linux bag (never create a second one); counters in the enclave never roll back | working macOS enrolment + password, full backup incl. the iBoot System Container; afterwards verify macOS Touch ID unlock and keychain ("treat macOS Touch ID as unverified until ... checked there", XART-SAFETY.md) |
| (d) Survives reboot and s2idle. | unknown on T6050; J716s sleep itself is open (`contrib/pending/platform/lid-sleep`) | Power domains must stay on across sleep (device links exist); hibernation is refused by design. | no | none |

House rules for every step: never post enrolled data, xART dumps, keybag
UUIDs, `SensorID`/serials; never run `--reset-touchid` or delete a keybag
to "clean up"; never copy state files between machines.

## 5. Security / privacy assessment

- Linux gains: a mailbox to the SEP; the hardware RNG; trusted-key sealing;
  the SBIO command channel (enrol/verify results, opaque identity UUIDs);
  read/write of the xART gigalocker inside the iBoot System Container.
  It never sees fingerprint images or templates (matching is in the SEP).
- Stays in the SEP: templates, every keybag's keys, anti-replay counters,
  SIKA/Sandcat attestation state.
- Separation from macOS: Linux has its own OS UUID lane, identity keybag and
  SEP user context, so macOS enrolments are not read or deleted. But the
  enclave and the gigalocker are device-wide; Aurora documents real-world
  rewrites of pre-Linux records on M1 Pro and M4 Pro and asks users to
  re-verify macOS Touch ID afterwards.
- Cost of a bug, in Aurora's own words (omacom/omarchy-mac-pkgs
  `mac-manual/content/04-security.md`): "Linux and macOS share that state:
  it is one file in the Mac's iBoot System Container, and both systems
  update it." On a bug that writes it wrongly, **with FileVault on "macOS
  can't unlock its disk and won't start... Getting the Mac back takes a DFU
  restore, which erases it"**; with FileVault off "macOS resets its keychain
  and Touch ID fingerprints". So: (i) mailbox/DMA mistakes -> SEP
  unresponsive until a cold boot; (ii) xART/keybag mistakes -> Linux
  enrolments lost (orphan bag, no recovery), macOS Touch ID/keychain reset,
  and in the FileVault case a DFU restore of the whole Mac; (iii) the
  silicon is never bricked (SEPOS/TZ0 reloaded by iBoot every boot, DFU
  available) but the data can be. No issue so far reports a lost macOS
  enrolment (#209 checked macOS afterwards and it was fine).
- Privacy: `/dev/sep-bio` is 0600 and the driver is not autoloaded by
  alias; keep PAM/fprintd off until (c) is proven on this machine.

## 6. Recommendation and first step

1. Do (0) now: one m1n1 patch, pure risk reduction, independent of
   everything else.
2. Prepare (a) and (b) as DT + profile work from the ADT (all public-safe
   values are in section 2; the DART window and sensor ID/mode are to be
   read from the ADT into the DT, not into docs), with the module locked
   to `xart_writes=0 provision_keybag=0`. Test attended: serial console,
   `dmesg` for `attach:` and `diag/*`, cold boot afterwards, then boot macOS
   and confirm Touch ID unlock still works.
3. Do not do (c) on the J716s until Aurora has a working M5-class profile
   elsewhere or until the T6050 discovery-only attach and sensor readback
   have been stable across several boots; the J716s should not be the
   first xART writer on a new SEP generation. Before (c): FileVault state
   of the macOS volume decides the blast radius (see section 5); a Time
   Machine/clone backup of macOS and a copy of the iBoot System Container
   are the minimum.
4. Report findings in Aurora's format (enrolment / verification /
   verification after reboot), never with enrolled data.

## 7. Upstream to follow
- aurora-silicon/linux `integration` and `aurora-wip`:
  `drivers/soc/apple/{sep.rs,profile.rs,sbio.rs,xart_*.rs,keybag*.rs}`,
  `tools/aurora-sep/{README,XART-SAFETY,OS-IDENTITY,HOST-STATE,M1-SUPPORT}.md`,
  `include/uapi/linux/apple-sep.h`, bindings `apple,sep.yaml`,
  `apple,mesa-fingerprint.yaml`; watch for any T6050/T8150/J716s profile.
- aurora-silicon/aurora-sep-userspace `main` (libfprint driver
  `libfprint/drivers/aurora/aurora.c` via `libfprint-1.94.100-apple-sep.patch`,
  fprintd patches, `touchid-rearm`), aurora-silicon/aurora-xart.
- aurora-silicon/aurora-silicon.github.io `src/data/support.json` (the
  board matrix; watch for an M5 Touch ID row).
- aurora-silicon/aura `src/kboot.c` (`sep_warm_active`, `dt_set_sep`).
- omacom/linux-aurora issues #418 (T6030 profile), #396/#397/#209/#369
  (keybag/guard failure modes), #423 (this J716s), PRs #200 (T8132/J715),
  #248 (J713), #282/#581 (J514s T6030); aurora-silicon/linux issue #1190 and
  the T6050 inventory commit f67926c275ea (2026-11-08, `apple,sep.yaml`).
- omacom/omarchy-mac-pkgs `omarchy-mac/lib/touchid-*`, PRs #64, #69, #87;
  omacom/omarchy-pkgs `pkgbuilds/libfprint-git/`.
- chriskearney/aurora-linux (frozen): #35, #42 and `install-aurora-sep.sh` releases.
- AsahiLinux/m1n1 `kboot.c` `dt_set_sep` (62ff43f0).
