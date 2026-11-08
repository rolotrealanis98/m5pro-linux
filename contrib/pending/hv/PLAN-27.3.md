# hv27: macOS 27.3 (26C5035r) under the m1n1 hypervisor on the J716s — attended run plan

Studio-side preparation only; nothing here has touched the MacBook. This is the repo-safe copy: volume-group UUIDs, boot-manifest hashes and payload hashes are replaced by
placeholders; the private plan, scripts and binaries are in the Studio's `~/Work/agents/hv27/` (0700).

## Status (2026-11-08)

- Rung i PASS (14:40 UTC), rung ii PASS (19:37 UTC: proxy on the Studio 70 s after reboot, identity and watchdog
  control OK; details and the GIC probes taken in that session in `contrib/validated/integration/RESULTS.md`).
- Rung iii-a PASS (21:32 UTC): macOS 27.3 boots into IOKit matching under the hypervisor with all 18 cores
  (guest files via an apfs-fuse read-only mount of Preboot). Boot args must omit `serial=3` (XNU hangs switching
  its console to the emulated uart0); the panel is the console. Rung iv (tracers) started the same evening.
  Rung iii-b waits for Rolando's decision below.

## 0. Decision needed before rung iii-b (read first)

The guest's boot session is the Linux stub's: iBoot booted the stub volume group (`/chosen/boot-uuid` =
the stub's <stub-VG-UUID>), measured the stub's LocalPolicy and started SEPOS for it. Macintosh HD is a
different volume group (<MacHD-VG-UUID>). Apple's Sealed Key Protection binds the Data volume's key-encryption
key to the measured LocalPolicy and sepOS ("If an unexpected change occurs to measured firmware, software,
or security configuration ... the KEK and the data become inaccessible",
support.apple.com/guide/security/sealed-key-protection-skp-secdc7c6c88e). So Macintosh HD booted inside the
stub's session is expected **not** to unlock its Data volume and not to reach a login window, and it would
run its SEP/xART traffic in the wrong OS's context. The Asahi docs say the same in practice: "While it is
possible to non-destructively override the boot object of your main macOS install, this approach is not
recommended ... We instead install a second copy of macOS" with `bputil -nkcas`, `csrutil disable` and
`kmutil configure-boot -c m1n1.bin --raw --entry-point 2048 --lowest-virtual-address 0 -v /Volumes/<test>`
(asahilinux.org/docs/sw/m1n1-hypervisor/), and "use the exact version you have installed".

Therefore:
- Rungs i, ii, iii-a run on the existing chain (stage-1 A/B -> proxy stage-2 on the ESP) and never let macOS
  touch the SSD.
- Rung iii-b (login window, needed for AVE/ProRes workloads and anything user-driven) needs a dedicated
  macOS 27.3 26C5035r volume with m1n1 as its boot object (Asahi layout). That is a separate attended
  ceremony (~30 GB in the main APFS container, a 26C5035r full installer, 1TR). Rolando decides. Never run
  `run-hv27.sh guest disk` against Macintosh HD.

## 1. Files

| what | where (Studio, private) | state |
|---|---|---|
| stage-2 proxy payload | `~/Work/agents/hv27/m1n1-build/m1n1-hv27-proxy.bin` sha256 `<sha8>`, 0x430000 | built |
| plain loader (same bytes) | `m1n1-build/m1n1-hv27-plain.bin` | built |
| rung-i payloads | `payloads/hv27-plain-selftest-20261108-<sha8>.bin` (recommended), `payloads/hv27-plain-test-20261108-<sha8>.bin` | built |
| guest kernelcache | `~/Work/studio-artifacts/macos-27.3/derived/kc.macho` (= `restore/kernelcache.release.mac17j` unwrapped; the installed BootKC unwraps to the same bytes, checked with `tools/im4p-extract.py`) | present |
| SPTM, TXM, ExclaveCore bundle, ExclaveOS trust cache + integrity catalog | not on the Studio | **missing: `fetch-27.3-guest-files.sh`** |
| proxyclient | `~/Work/agents/hv27/m1n1/proxyclient` (must match the stage-2: same tree) | |

Where they live on the MacBook (Macintosh HD volume group <MacHD-VG-UUID>, Preboot
volume; macOS path `/System/Volumes/Preboot/<VG>/...`). Component names from the 27.2 IPSW BuildManifest
(J716s, Update identity); 27.3 uses the same names, the numbered files are resolved from the installed
`restore/BuildManifest.plist` by the script:

| component | path under `<VG>/restore/` |
|---|---|
| `Ap,SecurePageTableMonitor` | `Firmware/sptm.t6050.release.im4p` |
| `Ap,TrustedExecutionMonitor` | `Firmware/txm.macosx.release.im4p` |
| `Ap,cL4` | `Firmware/image4/exclavecore_bundle.t6050.RELEASE.im4p` |
| `Ap,ExclaveOSTrustCache` | `Firmware/<ExclaveOS dmg>.dmg.aea.trustcache` |
| `Ap,ExclaveOSIntegrityCatalog` | `Firmware/<ExclaveOS dmg>.dmg.aea.integrity_catalog` |
| `KernelCache` | `kernelcache.release.mac17j` |
| `StaticTrustCache` | `Firmware/<n>.dmg.aea.trustcache` (cross-check only; m1n1 copies iBoot's TrustCache from the live memory map, which the 26C5035r-built stub provides) |

The personalized copies iBoot loads sit under `<VG>/boot/<boot-manifest-hash>/` (BootKC at
`System/Library/Caches/com.apple.kernelcaches/kernelcache`); the script lists and copies the matching files
there too, for comparison.

Run it on the MacBook as root: from Linux after mounting Preboot read-only (`apfs-fuse -v <idx>
<macOS APFS container> /mnt/macos-preboot`; the script refuses a rw mount), or from macOS
(`sudo sh fetch-27.3-guest-files.sh`). Then `scp` the tarball to
`~/Work/studio-artifacts/macos-27.3/hv-guest/` and `run-hv27.sh prep <tarball>` (unwraps IM4P/LZFSE,
checks Mach-O / DNUB magic, compares the kernelcache with `kc.macho`).

## 2. Chain behaviour (read from 0016, 0012 and the boot-ab reports)

- Stage-1 (installed, 0016): reads iBoot's PMU boot-error count; 0 -> `chainload=` (boot.bin), non-zero ->
  `chainload.fallback` (boot.bin.prev) first. It arms WD1 for 150 s right before the hand-over and appends
  ` m1n1.wdt=keep` to the stage-2 boot args.
- Stage-2 = `m1n1-hv27-proxy.bin` as boot.bin: no payload appended -> "No valid payload found" -> USB proxy.
  0012 leaves WD1 armed and resets its count in `proxy_process()` (every host request) and `hv_tick()`
  (1 kHz while a guest runs). **No host connection within ~150 s of the hand-over = watchdog reset.** iBoot
  finds boot_stage != 0, counts a failed boot, stage-1 boots boot.bin.prev = the daily. That is the
  self-revert when nobody connects. `m5.selftest` is not involved.
- Once connected, `run-hv27.sh` disarms WD1 (attended: an idle hypervisor shell sends no requests and would
  be reset after 150 s). `HV27_WDT=keep` keeps the dead-man switch instead.
- Every way the hv session ends (Ctrl-C then `reboot()` = watchdog reset, power-hold, a wedge with the
  watchdog kept) leaves boot_stage non-zero: the next boot is the fallback = the daily. If the guest ever
  shuts down cleanly (boot_stage 0), the next boot takes boot.bin = the proxy payload again; with no host it
  resets after 150 s and then falls back. Worst case one extra 150 s cycle.
- m5-boot-slot (demotion of a failed boot.bin) is a prototype, not installed: after the session the daily
  runs from the fallback slot while boot.bin still holds the proxy payload. Restore boot.bin by hand
  (section 4, step 9) before any normal reboot.

## 3. Ladder

| rung | what | effort | risk | learn |
|---|---|---|---|---|
| i | daily boot with `hv27-plain-selftest` (only the loader differs from the deployed daily) | 15 min, 1-2 boots | low: a dead loader = 150 s watchdog -> fallback; a booted kernel without network self-reverts in 90 s (m5.selftest) | the rebased tree (upstream M5 hv + our series + step 0) still does the daily hand-off: 18 CPUs, display, N1, GPU, AVE hand-off, and `SEP: Preserving iBoot warm registration` instead of the getrand timeout |
| ii | proxy payload as boot.bin, `run-hv27.sh smoke` | 15 min | low: no host = 150 s -> daily; nothing leaves m1n1 | stage-2 USB device mode on the left-back port from a chained, relocated stage-2; identity and base; watchdog control |
| iii-a | `run-hv27.sh guest nodisk` (SPTM + TXM + cL4 + XNU, `--strip-node iop-ans-nub`), then `nodisk-sk0` if cL4 fails early | 1-3 h per attempt, several attempts likely | medium for time, low for data: XNU cannot start the SSD controller, so no APFS, no xART, no Data volume. macOS may still write NVRAM (qspi `anvram`) and SMC state; PMU counters are cleared by run_guest | how far upstream's M5 hv gets on T6050: SPTM bootstrap, TXM, cL4/Exclaves bring-up, XNU early boot and the BootKC kexts that start before root mount (DCP, SEP manager); stops at "waiting for root device" at best |
| iii-b | login window — only on a dedicated 26C5035r test volume (section 0) | ceremony + days | high: macOS writes its volumes, the shared Preboot/VM/Update volumes, NVRAM, and the device-wide xART store through the SEP | everything needing userspace |
| iv | tracers: `HV27_TRACE=dcp` first, then `sep`, `ave`, `apr` (`hv/hv27-trace.py`, ranges read from the ADT) | per target, hours | each traced range is emulated: slower guest, timing-sensitive firmware may time out | register/mailbox traffic per block; on iii-a only what runs before root mount |

## 4. Attended procedure

Hardware: section 7 checklist. Studio on macOS, `~/Work/m1n1/.venv` python.

1. On the daily (SSH): record `sha256sum /boot/m1n1/boot.bin /boot/m1n1/boot.bin.prev` (expected boot.bin
   = <sha8>, prev = <sha8>). Make the current daily the fallback:
   `esp-put /boot/m1n1/boot.bin boot.bin.prev <sha256>`.
2. Rung i: scp `hv27-plain-selftest-20261108-<sha8>.bin`, `esp-put <it> boot.bin <sha8>...0a32`
   (60 s settle is built in), `systemctl reboot`. Expect: slot=primary, kernel 7.3.0-g0933f881d736, 18 CPUs,
   dmesg/m1n1 log line `SEP: Preserving iBoot warm registration; seeding RNG from ADT`, no "couldn't get
   enough random bytes". Then put the daily back as boot.bin (<sha8>) and reboot once (it must come back).
3. Rung ii: scp `m1n1-hv27-proxy.bin`, `esp-put <it> boot.bin <sha256>`.
   On the Studio start `~/Work/agents/hv27/run-hv27.sh smoke` (it waits for the device), then on the Mac
   `systemctl reboot` (wait the 60 s settle first).
   Expected: console log `Primary WDT left armed (m1n1.wdt=keep)`, `No valid payload found`, `Running proxy...`;
   smoke prints `m1n1 v2.0.0-132-g63e6053c base 0x... chip 0x6050` and `stage-1 watchdog disarmed`.
   A different version string = STOP (the chain booted something else).
4. In the same boot (or after a power-hold and a fresh proxy boot): `run-hv27.sh guest nodisk`.
   Invocation it builds (logs in `runs/<date>-guest-nodisk/`):
   `run_guest.py --sptm-mode emulation -p sptm.macho -t txm.macho --exclave-bundle exclavecore.bundle
   --exclave-trustcache exclave-trustcache.bin --exclave-integrity-catalog exclave-integrity-catalog.bin
   --strip-node iop-ans-nub -l run_guest.log kernelcache.macho -- -v debug=0x14e serial=3 wdt=-1`
   (run_guest appends `aprr_jit=0 sprr_tpro=0 sprr_tpro_pagers=0 processor_exit=0 cluster_power=0`).
   Memory: everything above m1n1's heap; the 2 GiB SPRR pool goes into the fake SPTMDebug region
   (`--sprr-pool-size`, default 2048). `-r/--raw` is not used (that is for raw images). `-C 0` (one CPU)
   is the first thing to try if secondary start misbehaves.
   Expected order: `Removing ADT node .../iop-ans-nub`, `Loading TXM-ro ... CL4-rx ... SPTM-*` images,
   `Copying TrustCache/SEPFW/...`, `SPRR POOL`, guest start; then SPTM/XNU text on the virtual UART
   (serial=3), `CPUSTART W` lines and `Starting guest secondary` per core, exclaves bring-up, kexts,
   finally a wait for the root device (the SSD is gone). A panic or hang anywhere drops to the shell.
5. If cL4 never comes up: `run-hv27.sh guest nodisk-sk0` (no bundle, CL4 dummy page): tells SPTM/TXM/XNU
   problems apart from Secure Kernel problems; on M5 XNU is expected to panic once it needs Exclaves.
6. Tracers (rung iv), one group per run: `HV27_TRACE=dcp run-hv27.sh guest nodisk`, then `sep`, ...
7. Stop: Ctrl-C -> hypervisor shell; `cont()` resumes; `reboot()` hard-resets. Hung beyond the shell:
   hold power until off, press once.
8. The next boot is the fallback = the daily (iBoot counted the reset). Confirm `slot=fallback-after-failure`.
9. On the daily: `esp-put /boot/m1n1/boot.bin.prev boot.bin <sha8>...` so boot.bin is the daily again;
   reboot once to confirm `slot=primary`.

Abort paths: no proxy within 150 s -> watchdog -> daily; proxy shows a wrong version -> power-hold -> daily;
guest wedges m1n1 with the watchdog disarmed -> power-hold -> daily; daily does not come back -> boot
picker -> macOS -> put boot.bin back by hand (docs/boot-and-recovery.md "Recovery").

## 5. What macOS writes, and the risks

- iii-a (no SSD): NVRAM writes are possible (macOS's NVRAM lives in the SPI NOR `anvram` partition, not
  on the SSD; stripping `anvram` too is untested). SMC state (charge management, RTC) may be set; PMU
  scratchpad counters are written by run_guest and the fallback path. No APFS write, no xART write (the
  SEP's xART requests need the AP to write the iBoot System Container, which is unreachable), no keybag.
  SEPOS is reloaded by iBoot on every cold boot, so a confused SEP does not survive the reset.
- iii-b (with SSD, dedicated volume only): macOS mounts and writes its own System/Data volumes and the
  container-shared Preboot, VM and Update volumes; the SEP writes anti-replay state to the device-wide
  xART store in the iBoot System Container; NVRAM; Secure Storage counters. The Touch ID study
  (contrib/pending/platform/touchid-sep/FEASIBILITY.md sections 1 and 5): the xART store is one file
  shared by every OS on the Mac, "counters in the enclave never roll back", and a bad write can cost macOS
  Touch ID and keychain, or with FileVault on a DFU restore. Rules for any guest: never enrol or use Touch
  ID, never sign in to an Apple Account, never change Startup Disk, never type Macintosh HD's password.
- Irreversible: SEP anti-replay counters and xART records (iii-b); the test volume's own policy/keybag
  until the volume is deleted. Reversible: NVRAM, SMC settings, ESP files, PMU counters.
- No backup of the MacBook exists (docs/boot-and-recovery.md "Known gaps"): make one before iii-b, and
  record `fdesetup status` (FileVault decides the blast radius).

## 6. Blockers

1. SPTM/TXM/ExclaveCore/exclave trust cache/integrity catalog are not on the Studio: run the fetch script.
2. Login window (iii-b) needs the dedicated 26C5035r volume decision (section 0).
3. Untested on T6050: upstream's cL4 support was developed on T8142; MCC has no `mcc,t6050` driver
   (same as the daily). Expect iterations at iii-a.
4. `hv-trace-targets.md` was not completed in this pass; `hv/hv27-trace.py` reads its ranges from the ADT.

## 7. Hardware checklist (Rolando)

- [ ] Thunderbolt/USB-C cable from the Studio's DFU port (rear, next to Ethernet) to the MacBook's
      left-back port (MagSafe side) = hpm0 / usb-drd0, the proxy port used for every tether so far.
- [ ] MagSafe charger connected for the whole session (hv runs are long; the panel stays on).
- [ ] Lid open, panel visible (m1n1 and the guest print to it; photograph panics).
- [ ] Nothing else on the left-back port; hub/Ethernet on left-front as usual.
- [ ] SSH to the daily works before starting (needed for steps 1, 2, 9).
- [ ] Studio on macOS, `run-hv27.sh` started *before* the Mac reboots into the proxy payload.
- [ ] Before iii-b only: backup, FileVault state, the dedicated volume ceremony.
