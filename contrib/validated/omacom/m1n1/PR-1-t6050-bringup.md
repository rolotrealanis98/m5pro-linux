smp: T6050: forward secondaries whose RVBAR is locked to the stage 1 base (stacked on #26)

Base: integration/aurora 121fcbf3 plus #26 (edimoldovan:j714c/t6050, 6d879ae). The first four commits are #26's. This PR adds two commits on top of them. Branch: `omacom/t6050-bringup`.

Our J716s (MacBook Pro 16-inch, M5 Pro) needed four T6050 changes before an Aurora m1n1 could boot Linux on it. #26 already makes three of them for the J714c (it is cut from edimoldovan's `j714c/m1n1` branch), and they cover the J716s too, so I dropped mine:

- **CPU_START**: #26 sets one bit per CPU index (`smp: T6050 releases one CPU per bit`). Mine set the same bits from the ADT cpu-id, which is the same number on T6050. CPU_START +0x0/+0x4 read 0x3fffe at rest on the J716s.
- **I2C**: #26 raises the `/arm-io/i2c` limit of `dt_disable_missing_devs()` to 16. The J716s also has i2c0 to i2c8.
- **NVMe**: the J716s ADT has the same 64 KiB `nvme` alias at 0x45dcc0000 and the same NVMMU at 0x41dcc0000 as the J714c, so #26's 0x30000 aperture matches it. Mine used Linux's `apple,t6050-nvme-ans2` layout (linear queue registers in the NVMMU block). That needs the T6040 split-BAR code, which integration/aurora does not have. The stage 2 that boots the J716s every day reaches the linear queue registers at +0x24908 of the 0x10000 alias, the same registers #26 uses.

What this adds:

- `tests: build the T6050 paths that #26 adds`. On #26's head, three CI host tests fail: `test_nvme_adoption` and `test_smp_handoff_gate` no longer compile (`T6050` is undeclared, and `dapf_init()` has no stub), and `test_t8103_inherited_reservation` no longer finds the end of its block (the heap check is now `T8140 || T6050`). The harnesses get the define, the stub and both forms of the match. integration/aurora passes them before and after. @edimoldovan, feel free to fold this into #26 instead.
- `smp: t6050: forward cores locked to a stage 1 base the image left`. iBoot locks the RVBAR of every T6050 secondary to the base of the image it loaded, which is stage 1. A stage 2 with a kernel appended (about 38 MiB on the J716s) does not fit between that base and the secondary-only CTRR window (about 12 MiB of room). So a stage 1 that places stage 2 above the window runs it at another address. Our A/B stage 1 does that. The secondaries then reset into the retired stage 1's vectors, `smp_prepare_rvbar()` refuses them, and kboot disables them ("is not alive").
  - On T6050, this rewrites slot 0 of that vector table once with the absolute forwarding stub that start.S already writes at a moved M3 image's old base (`ldr x16, 1f; br x16; 1: .quad _vectors_start`). T8140's single `b` can be out of range at this distance.
  - It does this only if the table has m1n1's four slot tags, lies in RAM below this image and outside the CTRR window, and the code runs at EL2. kboot reserves the 16K page, so a core that resets later still finds the relay.
  - The T8140 relay now shares the write and read-back helper. Its behaviour is unchanged: the existing parity test still compares its register sequence with the old code.
  - `tests/python/test_smp_legacy_rvbar.py`: the two existing harnesses now build the shared helper. A new case covers the T6050 relay. It is written once and read back. With a relay already in place, a core locked elsewhere is refused. Nothing is written outside EL2, for a foreign table, inside the CTRR window, above this image, below RAM, for an unlocked RVBAR, or on another SoC.

When this runs: only with a stage 2 that is too big to stay at stage 1's base. The Omarchy chain on the J714c never reaches it: stage 1 chainloads the ESP's stage 2 with U-Boot appended, which is small enough to stay at the base, so RVBAR already matches. The same is true of #27's stage 1, which boots U-Boot itself, and of a stage 1 that copies stage 2 down to run_base, as T8140 does. Our J716s chain needs it because its stage 2 carries the kernel, DTB and initramfs.

### Testing

MacBook Pro 16-inch, M5 Pro (J716s, Mac17,8, 48 GiB), macOS 27.3 beta 1 stub (26C5035r, `mBoot-20457.60.65.0.1`). Boot chain: our A/B stage 1 (kmutil) chainloads `boot.bin` from the ESP. That is a stage 2 with the kernel, DTB and initramfs appended, and it runs kboot.

This code ran in our own stage 2 (AsahiLinux m1n1 plus T6050 bring-up), not on this branch:

- The same forwarding stub at the locked RVBAR, with the same checks and page reservation, has run on every J716s boot since 2026-11-04. On 2026-11-07 that covered the daily, Wi-Fi, GPU, display and sleep test payloads, cold starts and `systemctl reboot` cycles. Every boot that reached Linux had 18 CPUs: pass.
- This branch: not booted. The boot-test payload is built; see the end of this description.
- Each commit and the tip build with `make` and with `make CHAINLOADING=1` (Fedora 43, clang/lld 21.1.8, rustc 1.99.1): 15 warnings, the same as #26, none new. `m1n1.bin` is 0x410000 bytes (plain) and 0x420000 bytes (`CHAINLOADING=1`), the same as #26.
- CI's pytest set (`tests/python` and the two T8122 GPU tests), run on Linux: all pass on this branch and on every later branch of the stack, including the three cases above and the new relay case. On #26's head, three fail.
- `git clang-format` on the changed lines: clean.

Boot-test payload for the J716s (not deployed): this branch's plain image with the daily's kernel, DTB and initramfs, self-test on. This loader disables the stage 1 watchdog, so the boot has to be attended. It also has no N1 code, so it has to start from a full power-off: after a restart with the N1 in use, a loader without the warm-N1 entry hangs once.

Stack (each PR is stacked on the previous one):
1. #26 (edimoldovan): CPU release, NVMe window, MTP DAPF, cpufreq
2. this PR: RVBAR relay
3. N1 hand-off (`omacom/t6050-n1`), optional
4. GPU hand-off (`omacom/t6050-gpu`)
5. internal display hand-off (`omacom/t6050-display`)
6. `m1n1.wdt=keep` (`omacom/wdt-keep`). It is independent of 1-5: `omacom/wdt-keep-standalone` is the same commit on integration/aurora.

Questions:

- Should the T6050 stage 1 copy a large stage 2 down to run_base, as T8140 does, instead of stage 2 forwarding from the retired vectors? Then this commit would not be needed. There is no J716s boot without the relay that also had the CPU_START fix, so the failure has never been shown on its own. On a cold boot of an older Aurora tree, CPUs 6-17 failed on the CPU_START bit, which #26 now fixes.
- T6051: #26 calls the M5 Max in the J714c a T6050. If any M5 Max reports T6051, it needs the same `chip_id` checks.
