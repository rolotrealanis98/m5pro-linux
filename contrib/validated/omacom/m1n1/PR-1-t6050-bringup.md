smp: T6050: forward secondaries whose RVBAR is locked to the stage 1 base (stacked on #30)

Base: #30 (edimoldovan:j714c/diskboot, ad08bf5), which sits on integration/aurora 121fcbf3. The first nine commits are #30's. This PR adds two. Branch: `omacom/t6050-bringup`. The stack merges cleanly with the current integration/aurora (c614476, after #25).

Our J716s (MacBook Pro 16-inch, M5 Pro) needed four T6050 changes before an Aurora m1n1 could boot Linux on it. #30 (which replaces #26 and #27) already makes three of them for the J714c, and they cover the J716s too, so I dropped mine:

- **CPU_START**: one bit per CPU index. Mine set the same bits from the ADT cpu-id, which is the same number on T6050. CPU_START +0x0/+0x4 read 0x3fffe at rest on the J716s.
- **I2C**: the `/arm-io/i2c` limit of `dt_disable_missing_devs()` goes to 16. The J716s also has i2c0 to i2c8.
- **NVMe**: the J716s ADT has the same 64 KiB `nvme` alias at 0x45dcc0000 and the same NVMMU at 0x41dcc0000 as the J714c, so #30's 0x30000 aperture matches it. Mine used Linux's `apple,t6050-nvme-ans2` layout (linear queue registers in the NVMMU block), which needs T6040 split-BAR code that omacom does not have.

What this adds:

- `tests: build the T6050 paths that #30 adds`. Five CI host tests compile production bodies that #30 extends, and they fail on its head:
  - `test_nvme_adoption`, `test_smp_handoff_gate` and `test_m3_defaults_optout` do not know `T6050`, and `test_smp_handoff_gate` also has no stub for `dapf_init()`.
  - `test_universal_boot`'s stage 1 config block now reads `boot_spec` and `kernel`.
  - `test_t8103_inherited_reservation` no longer finds the end of its block (`T8140 || T6050`).

  The harnesses get the defines, the stub, the two declarations and both forms of the match. integration/aurora passes them before and after. @edimoldovan, feel free to fold this into #30.
- `smp: t6050: forward cores locked to a stage 1 base the image left`. iBoot locks the RVBAR of every T6050 secondary to the base of the image it loaded: stage 1. A stage 2 with a kernel appended (about 38 MiB on the J716s) does not fit between that base and the secondary-only CTRR window (about 12 MiB of room). So a stage 1 that places it above the window runs it at another address. The secondaries then reset into the retired stage 1's vectors, `smp_prepare_rvbar()` refuses them, and kboot disables them ("is not alive").
  - On T6050, slot 0 of that vector table is rewritten once with the absolute forwarding stub start.S already writes at a moved M3 image's old base (`ldr x16, 1f; br x16; 1: .quad _vectors_start`).
  - That only happens for a table with m1n1's four slot tags, in RAM below this image and outside the CTRR window, at EL2. kboot reserves the 16K page.
  - The T8140 relay now shares the write and read-back helper. Its behaviour is unchanged, and the existing parity test still compares it with the old code.
  - A new host test covers the T6050 relay:
    - it is written once and read back;
    - while a relay exists, a core locked elsewhere is refused;
    - nothing is written outside EL2, for a foreign table, inside the CTRR window, above this image, below RAM, for an unlocked RVBAR, or on another SoC.

When the relay runs: only for a stage 2 too big to stay at stage 1's base. #30's Omarchy chain never gets there: the ESP's stage 2 with U-Boot appended is small enough to stay at the base. Our J716s chain needs it, because our A/B stage 1 chainloads a stage 2 that carries the kernel, DTB and initramfs.

### Testing

MacBook Pro 16-inch, M5 Pro (J716s, Mac17,8, 48 GiB), macOS 27.3 beta 1 stub (26C5035r, `mBoot-20457.60.65.0.1`). Boot chain: our A/B stage 1 (kmutil, watchdog armed for 150 s) chainloads `boot.bin` from the ESP, which is a stage 2 with the kernel, DTB and initramfs appended. Kernel: integration/aurora with the T6050 series (the daily, `7.3.0-ga0f2f30c967b`).

- **This stack on hardware (2026-11-07).** The full stack up to `omacom/wdt-keep`, built on #26 before #30 replaced it, booted the J716s on the first pass. #26 has the same T6050 code as #30, minus USB host prep, the PMP DAPF, the G17 GPU fill and the live-ANS marking.
  - `SMP: installed RVBAR relay`, then Linux on 18 CPUs: pass.
  - Also in that boot: `Primary WDT left armed` (PR-5), the N1 trained by the loader (PR-2), the MTP DAPF programmed.
  - Wi-Fi came up. There was no USB gadget network, as expected: integration/aurora has no T6050 combo-PHY tunable fill.
- Before that, the same forwarding stub, with the same checks, had run in our own stage 2 on every J716s boot since 2026-11-04.
- **The rebase onto #30** has not booted on the J716s. #30's USB host prep runs on every T6050 boot and has so far run only on the J714c.
- **Builds:** each commit and the tip, with `make` and with `make CHAINLOADING=1` (Fedora 43, clang/lld 21.1.8, rustc 1.99.1): no new warnings against #30. `m1n1.bin` is 0x410000 bytes (plain) and 0x420000 bytes (`CHAINLOADING=1`), the same as #30.
- **pytest:** CI's set (`tests/python` and the two T8122 GPU tests) passes on this branch and on every later branch of the stack. On #30's head, the five tests above fail.
- `git clang-format`: clean.

Stack (each PR is stacked on the previous one):
1. #30 (edimoldovan): T6050 boot from disk through the Omarchy chain
2. this PR: CI test fixes for #30, and the RVBAR relay
3. N1 hand-off (`omacom/t6050-n1`), optional
4. GPU hand-off for `apple,agx-g17s` (`omacom/t6050-gpu`)
5. internal display hand-off, opt-in (`omacom/t6050-display`)
6. `m1n1.wdt=keep` (`omacom/wdt-keep`). It does not depend on 1-5: `omacom/wdt-keep-standalone` is the same commit on integration/aurora c614476.

Questions:
- Should the T6050 stage 1 copy a large stage 2 down to run_base, as T8140 does, instead of stage 2 forwarding from the retired vectors? Then the relay would not be needed. No J716s boot without the relay has had the CPU_START fix, so the failure has never been shown on its own.
- T6051: #30 treats the J714c's M5 Max as T6050. If any M5 Max reports T6051, it needs the same `chip_id` checks.
