# W0 / W1 prep report (2026-11-07)

Nothing was run on the MacBook. No pushes, no commits. Everything is under `~/Work/agents/n1-wifi/prep/`; payloads are in
`~/Work/agents/aurora-kernel/payloads/` (private: they carry the FTAB inside the initramfs).

## Ready

| item | file | sha256 |
|---|---|---|
| W0 payload | `payloads/w0-n1dt-20261107-24276a09.bin` (38 MB) | `24276a09a92905965c59997a56ce88f474c48f4510945e27156bed3a2bd6dad8` |
| W1 payload | `payloads/w1-n1train-20261107-3c0a1eff.bin` (38 MB) | `3c0a1eff5525cf20495e61f33481f2b9aec2d7d38a6b1322ae5d52468183e97b` |
| initramfs (selftest base `1f61a850` + FTAB) | `n1-wifi/payloads/initramfs-selftest-n1-b1f61a85.cpio.gz` | `4f299656af6ad896e98ad7e206ae6c7765c097b9389128126c59586e2fe023e4` |

Both are in `payloads/SHA256SUMS` with recipe files next to them. W1 = W0 with the `train` m1n1 and `chosen.m5pro,n1=1` inserted (verified: bytes
after the insert are identical to W0, the first 0x400000 bytes are exactly the two m1n1 binaries).
Ingredients of both: series kernel `975dab00` (`7.3.0-g4f630b11270d`, the daily's), DTB `stack-right-port+hwmon.dtb` (`594f2a9f`, the daily's), `--battery`,
`m5.selftest=1`, daily bootargs. Prep files: `W0-ROOT-PREP.sh`, `READBACK.sh`, `W1-POST-ROOT.sh`, `deploy-W0.sh`, `deploy-W1.sh`
(`gen-deploy.py` regenerates them), `mk-w1.py`, `mk-initramfs-n1-b1f61a85.py`, `RUN-W0.md`, `RUN-W1.md`. Scripts pass `bash -n` and shellcheck (info notes only).

## Where this differs from `LOOP-PLAN.md`, and why (all deliberate)

1. **DTB is the daily's `stack-right-port+hwmon.dtb`, not `--dtb series`.** `--dtb series` is `wt-series-out`'s DTB (`8c4df67a`, 6 Nov 21:18), which predates series 0059/0060
   (SMC sensors, right port). W0/W1 on it would drop those two features and not be "the daily plus Wi-Fi". The daily DTB already has everything the plan wants:
   `pci@0,0` with `apple,link-trained-by-bootloader`, `reset-gpios` pin 80, `gpio-reserved-ranges` leaving pin 80 open, the control function with
   `firmware-name = "apple/centauri/j716s-ftab.bin"`, platform id `0xc6050`, protocol 27, wifi and bluetooth nodes. No new DTB was needed or built.
   The `*-tunables` lists on `pci@0,0` are written by m1n1 0022 (W0 readback row 5 checks they appear; fallback `fixed9` as in the plan).
2. **The n1 initramfs was rebuilt on the current selftest base.** The plan's `initramfs-selftest-n1.cpio.gz` sits on base `ce0b462c`; the daily and `mk-daily.py`'s
   pin are `1f61a850` (rebuilt 6 Nov 22:07, commit 2539360: self-revert loop guard, one revert then stay up). Using the old one would have put an older
   self-revert (no loop guard) in the test payloads. `mk-initramfs-n1-b1f61a85.py` is the original script with the base hash and output name changed.
3. **ESP deploy has an added guard (0b).** The stock `--deploy-plan` step 2 copies whatever `boot.bin` is onto `boot.bin.prev` when the running payload is not a test.
   After a stage-1 watchdog fallback, `boot.bin` still holds the failed test while the daily runs, so the next deploy would overwrite prev with the failed test.
   The guard restores `boot.bin` from prev in that case and aborts unless prev ends up as the daily (`275d84ec`).

## m1n1 lineage (checked, no rebuild needed)

Both n1 binaries contain the pipe-park (0020) and ATC tunables (0021) code: the strings `tunable_PIPE_HANDLER_DEFAULT`, `apple,tunable-pipe-default`,
`usb: usb-drd%u: PIPE %s the dummy producer`, `atc-apcie-*-tunables`, `FDT: Unable to set up T6050 ATC tunables` are present in `n1-dt` and `n1-train`, as in the daily's `28b26ebc`.
They do not predate 0021. Lineage: `n1-dt` = `v2.0.0-74-g0bc8917e` = commit `71a91b1b` (pipe-park-atc: 0020+0021) + 0022; `n1-train` = `v2.0.0-75-g119168fa` = + 0023.
**One difference from the daily's m1n1:** the daily's `v2.0.0-72-gf7555558` is the same 0020+0021 on `ccbb51bc`; the n1 tree rebases that on `d5b29b03`
(`dapf: add the T6050 PMP DART (dart-pmp0)`, +8/-2 lines in `src/dapf.c`, the only tree difference). So W0/W1 also run `dapf_init` on `/arm-io/dart-pmp0`,
which the daily does not. It is outside the USB3 / trackpad paths, but it is a real delta from the daily (a PMP DAPF write at boot). If you want W0 to differ from
the daily by the n1 code only, rebuild `n1-handoff` on `pipe-park-r2-atc` (`f7555558`) with `~/Work/agents/n1-wifi/build.sh` (about 3 minutes in the Apple `container` Fedora 43 build;
cherry-pick 0022 and 0023 onto that ref first). I did not run it.

## Kernel config: no rebuild needed

`wt-series-out/.config`: `PCIE_APPLE=y`, `PCIE_APPLE_MSI_DOORBELL_ADDR=0xfffff000`, `PINCTRL_APPLE_GPIO=y`, `RFKILL=y`, `CFG80211=y`, `APPLE_CENTAURI=y`, `APPLE_CENTAURI_WIFI=y`,
`BT=y`, `BT_HCICENTAURI=y`, `APPLE_DART=y`, `FW_LOADER=y`, `FW_LOADER_COMPRESS` off. All seven marker strings (adoption, retrain, personalized firmware name, Wi-Fi channels,
Beta IPC, `apple,t6050-pinctrl`, `required firmware %s unavailable`) are in `Image.gz` `975dab00`. Gaps (as the plan says): `MTD_PHRAM=m` (needs `phram.ko` on the root to read the m1n1 log;
`W0-ROOT-PREP.sh` reports whether it is installed), `BT_LE` off (BLE scans may be empty).
Firmware request, quoted from `drivers/net/wireless/apple/centauri/centauri_pci.c:123`: `ret = request_firmware_direct(&fw, c->firmware_name, dev);`, with
`firmware_name` read from the DT property `firmware-name` (line 349), which is `apple/centauri/j716s-ftab.bin`: so `/lib/firmware/apple/centauri/j716s-ftab.bin` (= `/usr/lib/firmware/...`
on Arch), uncompressed. The driver rejects a file under 0x30 bytes or without `rkosftab` at 0x20.

## Safety findings (read before W1)

- **The "150 s watchdog" covers hard hangs only.** `CONFIG_APPLE_WATCHDOG=y`, `WATCHDOG_HANDLE_BOOT_ENABLED=y`, `WATCHDOG_OPEN_TIMEOUT=0`: once Linux probes the watchdog it feeds it forever until userspace opens it.
  A kernel that keeps running but never mounts the root (the selftest initramfs then stays in a shell with sshd on the USB gadget link) or a probe that sleeps forever is therefore NOT reverted.
  LOOP-PLAN's W1 risk statement says the NVMe-lost case "is recovered by the 150 s A/B watchdog"; from the kernel config and `mk-selftest-initramfs.sh` that is true only if the machine hard-hangs. For NVMe lost with a live kernel, recovery is a power-button hold
  (about 10 s: iBoot counts a failed boot, stage-1 boots `boot.bin.prev`). Hence W1 is written as attended-only.
- Stage-1 A/B is taken from STATE.md. I cannot see its variables; RUN-W0 step 1 checks that the daily reports boot slot `primary` and that `/sys/class/watchdog/watchdog0` is `active`.
- After a stage-1 fallback nothing restores `boot.bin` (the `m5-boot-slot` demotion script is a prototype, not installed as far as I can tell). Step 7 of RUN-W0 and guard 0b handle it.
- `--battery` payloads are "attended boot only" per `mk-daily.py`; W0 is lower risk than W1, but Rolando should know the battery driver is on in both.

## Not ready / not done

- Nothing was run against the MacBook, so the SSH address, the root prep, the readback script and the phram log read are untested. `W0-ROOT-PREP.sh` uses GNU `stat -c` and `pacman` (fine on the Arch root, not testable on macOS).
- **W2 is not built** (`python3 -I prep/mk-w1.py 2` produces it; the plan allows it only after W1 stops at `link up ... after 500 ms`).
- The m1n1 log read needs `phram.ko` for `7.3.0-g4f630b11270d` on the root. If it is missing, the key W0 line (`n1: port 0: ... linksts ...`) has to come from a photo of the panel during boot, and W0's answer then needs Rolando.
- Wi-Fi association (the plan's final pass) needs the passphrase: only Rolando. `W1-POST-ROOT.sh` stops at "scan lists SSIDs" and "bluetoothctl scan".
- The FTAB has no ticket (ANALYSIS.md 2.3): `phase0: -5` is a real possibility and would end the loop at W1 until the manifest is stitched in.
- The deploy overwrites `boot.bin.prev` (currently R2-B `5091e1fe`, per STATE.md) with the daily. R2-B stays in the repo's R2 payload list; the ESP loses that fallback, which is what the ESP policy wants.
- The ESP needs room for a 38 MB payload plus a 25 MB prev copy in flight; `W0-ROOT-PREP.sh` and deploy step 0 check for 94 MB free.

## Open questions

1. W1 only with Rolando present? (written that way; say if the NVMe-lost case is acceptable unattended, I would not.)
2. Rebuild the n1 m1n1 on `f7555558` so the only delta from the daily is the N1 code (drops the dapf line)? About 3 minutes if the container runs.
3. Is `phram.ko` on the root? If not, install the kernel modules or accept a photo-based W0.
4. Should W1-POST-ROOT's config (iwd main.conf, `25-wireless.network`) be applied before W0 instead? It is inert until a `wlan` interface exists, but it was kept out of the root prep because the brief said to enable nothing.
