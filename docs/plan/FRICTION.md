# Reboot friction and visibility: ranked proposals

Planning agent, 2026-11-05. Design only; nothing here ran on the MacBook; every prototype is
UNTESTED. Paths: repo = `~/Documents/GitHub/m5pro-linux`, kernel tree =
`/Volumes/linux-cs/wt-integration` (the B1/B2 integration tree), m1n1 clone =
`~/Work/agents/plan/m1n1` (branch `plan/boot-ab`), prototypes under `~/Work/agents/plan/`.

## The one mechanism everything hangs off

iBoot already keeps the bookkeeping we need, in the PMU scratchpad patch 0017 taught Linux to use:

- Linux `macsmc-reboot` writes `boot_stage = 0x30` at probe (`drivers/power/reset/macsmc-reboot.c:259`),
  clears the counts (`:263`, `:179-207`), and writes `boot_stage = 0` only from its **reboot
  notifier** (`:130-177`, write at `:164`, registered at `:292`).
- The panic path does not run reboot notifiers: `emergency_restart()` goes straight to
  `machine_emergency_restart()` (`kernel/reboot.c:92-97`). Hangs, watchdog bites, power-button
  holds and `macvdmtool reboot` do not run them either.
- iBoot finds `boot_stage != 0` at power-on, counts a boot error and records the stage
  (RESULTS.md:132-134: `PMU logged 1 boot error(s)`, `boot_error_stage = 0x30`; status doc
  lines 140-154), and after "a few" shows the "needs to be reinstalled" recovery.

So when stage-1 m1n1 runs, a non-zero `boot_error_count` means exactly "the previous attempt did
not end in a clean Linux restart", and `boot_error_stage` says roughly where (`0x2f` = before
Linux's SMC probe: m1n1 stage-2 or early kernel; `0x30` = after it). The distro design rejected
reusing this counter (`contrib/distro/DESIGN.md:108`, marked [assumption]) as a place to *write
our own state*; reading it, and clearing it the way Linux already does, uses iBoot's semantics as
they are.

m1n1 already has what is needed to read it: `src/spmi.c` has the gen-4 register layout
(`regs_gen4`, chosen when the bus node's `gen >= 4`), and the private ADT has the primary PMU on
`nub-spmi0` (`gen 4`, `is-primary 1`, `info-leg_scrpad 0xf800`; checked offline with the
proxyclient ADT parser, no identifiers quoted).

## Ranking

| # | Proposal | Removes intervention | Effort | HW time |
|---|---|---|---|---|
| P1 | Stage-1 A/B fallback + stage-1-armed watchdog (m1n1 0016) | 1, 3, 8, most of 4 | 1 day, prototype done | 1 ceremony + ~45 min of tests |
| P2 | Hang -> panic -> reset everywhere (kernel config + cmdline) | 4, 8 | 2 h, fragment done | 2 boots |
| P3 | netconsole over EEM into the Debian guest | 2, 8 | 0.5 day, prototype done | 1-2 boots |
| P4 | `m5-deploy.sh`: upload, rotate, reboot, verify, auto-rollback | 1, 4, most agent round trips | 1 day, prototype done | rides on the first deploy |
| P5 | pstore/ramoops in iBoot's panic region (`/pram`) | 2, 8 | 1 day | 3 probe boots |
| P6 | Studio-side hang watchdog (`macvdmtool reboot`) | residual 4 | 0.5 day | 1 forced hang |
| P7 | Panel camera + OCR | 2 (pre-network, m1n1, iBoot screens) | 1 day + a webcam | 30 min setup |
| P8 | Second network path: USB host Ethernet; libusb EEM bridge; later Thunderbolt IP | 5 | 0.5-2 days each | rides on Stage C |
| P9 | Startup disk / one-time boot from Linux and macOS | 6 | 0.5 day | 2 boots |
| P10 | Serial console | 2 | low priority | unknown |
| - | Physical setup that never changes | 7 | - | 15 min once |

(j), making probe hangs visible, is not a separate mechanism; it is P1 (the hang becomes a reset)
+ P2 (lockups become panics) + P5 (console text survives the reset) + P3's module hook. See the
last section.

---

## P1. Automatic A/B fallback in stage-1 m1n1

Prototype: `patches/m1n1/0016-chainload-A-B-fallback-on-iBoot-s-PMU-boot-error-cou.patch`
(commit `d52d4dd9` on `plan/boot-ab`); `patches/mk-stage1-ab-vars.diff`; `prototypes/rootfs/m5-boot-slot{,.service}`.

**Problem.** A payload that does not boot needs Rolando: macOS, `sudo diskutil mount`, copy
`boot.bin.prev` back (RESULTS.md:62-68, 155-156). m1n1 cannot write the ESP (read-only FAT,
DESIGN.md:24) and a failed chainload drops to the USB proxy (`src/chainload.c:136-153`), which needs
the tether.

**Mechanism.**
1. New stage-1 variables, all optional, ignored by an old stage-1 ("Unknown variable" in
   `src/payload.c` `check_var`): `chainload.fallback=<ESP PARTUUID>;m1n1/boot.bin.prev`,
   `chainload.wdt=150` (seconds, <= 170: the alarm is 32-bit at 24 MHz), `chainload.pmu-clear=0`
   (default 1).
2. Before chainloading, stage-1 reads scratchpad +1..+3 (new `src/pmu.c`, same ADT search as
   `proxyclient/m1n1/hw/pmu.py:find_primary_pmu`). Count != 0 -> try the fallback first. Either slot
   that cannot be read (missing file, FAT/GPT error) -> try the other, and only then the proxy.
   PMU unreadable -> primary (= today).
3. If the count was non-zero, stage-1 clears it: the same one-byte write Linux does at every boot
   (verified on hardware, RESULTS.md:132-134) and `proxyclient/tools/reset_panic_counter.py` does.
   iBoot then never reaches its recovery threshold, even when the failing payload dies before
   `macsmc-reboot` probes or the fallback is an old payload without 0017. That closes intervention 3
   for every payload, not only kernels carrying 0017.
4. The decision reaches Linux as `chosen.m5pro,boot-slot` (`primary`, `fallback-after-failure`,
   `primary-after-failure` = fallback unreadable) and `chosen.m5pro,pmu-scrpad` (the three raw
   bytes); stage-2 m1n1 already copies `chosen.*` into `/chosen` (`src/payload.c` `payload_run`).
5. With `chainload.wdt=N`, stage-1 arms the SoC watchdog right before the hand-over (new `wdt_arm()`
   in `src/wdt.c`) and appends ` m1n1.wdt=keep` to the next m1n1's boot_args cmdline, so stage-2's
   `wdt_disable()` leaves it armed (`src/wdt.c:45-49`, patch 0012). Linux `apple_wdt` sees
   `RESET_EN` and marks it running (`drivers/watchdog/apple_wdt.c:186-188`); with
   `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y` (integration `.config`) the core feeds it until
   userspace opens `/dev/watchdog0`. Anything that hangs between stage-1 and `apple_wdt`'s probe
   resets the machine after N s. The 2026-11-05 macsmc-power hang at 7.8 s is very likely in that
   window (`drivers/Makefile:120` links `power/` before `:123` `watchdog/`), and a bus-level stall
   after the probe stops the feeding kthread too. iBoot counts the failure, the next boot takes the
   fallback, **nobody touches the Mac**. If a slot fails to load, stage-1 disarms before dropping to
   the proxy, so a human at the tether is never reset.
6. Making it permanent is the root's job, since m1n1 cannot write FAT:
   `prototypes/rootfs/m5-boot-slot` on `fallback-after-failure` demotes `boot.bin` to
   `boot.bin.failed-<ts>` and copies `boot.bin.prev` over it, **only if** `m1n1/TRIAL` (written by
   `m5-deploy.sh`) matches `boot.bin`. A forced power-off of a good payload also counts as a
   failure; that must cost one boot on `boot.bin.prev`, not the payload. A primary-slot boot that
   reaches multi-user confirms the trial. Without this step every clean reboot would retry the bad
   `boot.bin` and boots would alternate.

**How the root marks success.** It does nothing new: a clean `reboot` (notifier -> `boot_stage = 0`)
is success; every unclean end (hang reset by the watchdog, panic, forced power-off, `macvdmtool
reboot`) is failure. The one case that would look clean, "root never mounts, someone reboots from
the initramfs shell", is made explicit by the debug initramfs: `m5.rootfail=panic:SECS` panics
after SECS s unless `/tmp/hold` exists (P3 prototype).

**Interaction with iBoot's counter and 0017.** 0017 still clears on every Linux boot; with stage-1
clearing first, Linux sees 0 and prints nothing, but the raw bytes reach userspace through
`chosen.m5pro,pmu-scrpad`, so the log line moves rather than disappears. `chainload.pmu-clear=0`
restores the old split (Linux reports and clears) if a test wants iBoot's raw count. macOS boots
clear it as before.

**Verified offline.** Builds clean for `CHAINLOADING=1` and plain (only the pre-existing clang
`-Wstack-usage` warning). Raw image still **0x420000**, same as the baseline (`.text` ends at
0x83854 of the 64 KiB-aligned 0x90000 boundary: 49 KiB of headroom before the image grows).
`prototypes/contrib/distro/tools/mk-stage1.py` (new `--fallback-path`, `--wdt`) wraps it with the
four variables into a **0x430000** object, the exact size and alignment of the stage-1 that boots
today; the cliff (0x4E0000 loops, status doc 105-110) is 0xB0000 away. Exact build:
`cd ~/Work/agents/plan/m1n1 && rm -f build/build_cfg.h && PATH=$HOME/.cargo/bin:$PATH gmake -j8 CHAINLOADING=1 EXTRA_CFLAGS="-Wstack-usage=2048 -march=armv8.4-a"`
(the baseline rebuilt this way is byte-identical to `m1n1-chain-baseline.bin`). Results:
`m1n1-chain-ab.bin` (sha256 `088c383b...`), `m1n1-plain-ab.bin` (0x410000).

**Risks.**
- SPMI from stage-1 is new. A wedged FIFO times out after 10 ms (`src/spmi.c` `wait_rx_fifo`) and
  is treated as "primary"; the write is the one Linux already does.
- If `apple_wdt` ever fails to probe (DT change, clock), a healthy boot is reset after N s: a
  boot loop alternating slots, cured only by `chainload.wdt=0` (a ceremony). Keep N = 150, run test
  step 1 before relying on it, and keep the current `chain-esp-small.bin` on the stub as the 1TR
  rollback (`stage1-install.sh:3-11`).
- In the proxy the kept watchdog is fed (`wdt_kick`, `src/wdt.c:19-23`), so a stage-2 that fell
  into the proxy stays there and its console replay can be read (`m5.sh log`).
- Installing is a ceremony (Rolando present, `stage1-install.sh` route).

**Hardware test, Round 1 (~45 min after the ceremony).**
1. Normal boot: `/proc/device-tree/chosen/m5pro,boot-slot` = `primary`, `pmu-scrpad` = `2f0000`
   or `300000`, 18 CPUs, `/sys/class/watchdog/watchdog0/state` running.
2. `systemctl reboot` x2: primary both times, counts 0.
3. Forced failure: deploy the known-bad macsmc-power payload (B2 without the blacklist). Expect a
   reset ~150 s in, then `fallback-after-failure`, and boot.bin demoted.
4. Panic: `echo c > /proc/sysrq-trigger` on a trial payload with `panic=10` -> fallback.
5. Rename `boot.bin.prev` away, hang the primary: proxy after the reset, no boot loop.

## P2. Turn every hang into a panic and every panic into a reset

Prototype: `prototypes/configs/m5-debug.config`.

**Problem.** The integration kernel has `# CONFIG_SOFTLOCKUP_DETECTOR is not set` (`.config:11891`),
no hard-lockup or hung-task detector, and `CONFIG_PANIC_TIMEOUT=0` (`:11890`): a panic waits
forever. TEST-PLAN T6 even asks for `panic=0 pause_on_oops=300` so the panel can be photographed
(`contrib/validated/legacy-7.2/smc/TEST-PLAN.md:53`). That is where intervention 4 comes from.

**Mechanism.** Soft-lockup panic; the buddy hard-lockup detector (no NMI needed: arm64 here has
`# CONFIG_ARM64_PSEUDO_NMI is not set` and AIC has none; the buddy detector watches CPUs from each
other with hrtimers, https://docs.kernel.org/admin-guide/lockup-watchdogs.html); hung-task at 120 s;
`PANIC_ON_OOPS`; `PANIC_TIMEOUT=10`. The running hardware watchdog from P1 is the backstop for a
hang where nothing schedules (the core stops feeding it, it bites after its 30 s default). Trial
cmdline: `watchdog.open_timeout=600` (the kernel stops feeding the watchdog if userspace has not
opened it by then; `drivers/watchdog/watchdog_dev.c:63`). Arch root: `RuntimeWatchdogSec=60s` in
`system.conf`, so a wedged PID 1 also resets. The photo-the-panel workflow is replaced by P3/P5
capture.

**Risk.** False positives from the busy-polling idle loop (`idle=nop`): soft lockup needs a CPU in
the kernel without scheduling for 20 s, which idle polling is not; watch the first boot. The 10 s
ANS RTKit wait (patch 0016) is far below hung-task's 120 s.

**Effort/HW.** Config merge, 2 boots (one normal, one `echo c`).

## P3. netconsole over the EEM link into the Debian guest

Prototypes: `patches/mk-debug-initramfs-netconsole.diff` (full file:
`prototypes/host/macos/mk-debug-initramfs.sh`), `prototypes/eem-vm/netconsole-guest.sh`,
`prototypes/eem-vm/m5-netconsole-listen.py`, `prototypes/rootfs/m5-netconsole.service`.

**Problem.** Kernel text is only on the panel; the bridge only carries SSH after sshd is up
(`mk-debug-initramfs.sh:86-89`).

**Mechanism.**
- Kernel: `CONFIG_NETCONSOLE=y`, `NETCONSOLE_DYNAMIC=y` (not set today, `.config:2711`).
- Debug initramfs, right after `usb-gadget-net` and dropbear: mounts configfs, waits up to 20 s for
  `10.55.0.1`/`10.55.2.1` to answer, creates one target per gadget link (`usb0` ->
  `10.55.0.1:6666`, `usb2` -> `10.55.2.1:6666`), console loglevel 8. No `remote_mac` is set:
  netconsole then uses Ethernet broadcast, fine on a point-to-point USB link and no MAC in any file
  (https://docs.kernel.org/networking/netconsole.html). It also prints the stage-1 decision from
  `/chosen`. The targets survive `switch_root` (configfs is unmounted first, the kernel objects
  stay), so systemd's boot and any later oops stream too; `m5-netconsole.service` re-arms them if
  the root recreates the gadget netdev.
- Studio: the guest has to have an address before the M5's initramfs sends anything. eem-vm's
  `setup()` only runs when someone calls the script, but QEMU's
  `usb-host,vendorid=0x1d6b,productid=0x0104` match re-attaches the gadget after every M5 reboot on
  its own (`~/Work/eem-vm/eem-vm.py:116-117`), so `netconsole-guest.sh` re-applies
  10.55.0.1/10.55.2.1 every 0.5 s, receives UDP 6666 with socat, keeps a copy in the guest and
  forwards to 10.0.2.2 (the Mac, via QEMU user networking). `m5-netconsole-listen.py` appends
  timestamped lines to `~/Work/m5-logs/netconsole.log`, which `m5-deploy.sh` slices per deploy. The
  guest must stay up: `eem-vm.py --keep` from a LaunchAgent, plus a proposed `--netconsole` flag
  that copies and starts the guest script.
- Probe bisect hook: `--module FILE.ko` packs modules into `/lib/modules/m5/`, and
  `m5.insmod=macsmc_power` loads them only after netconsole is up. Built-in drivers probe before
  `/init`, i.e. before a userspace-configured netconsole can exist, so for the macsmc-power hang the
  bisect kernel builds `CONFIG_MACSMC_POWER=m` (that kernel only), adds a `dev_info` before each SMC
  key access, and the last line before the hang lands on the Studio.

**Risk.** netpoll over a USB gadget is best effort: u_ether queues to the UDC from atomic context,
so lines up to the hang get out, but a CPU dead with interrupts off stops completions once the
request pool (~10) drains. Nothing printed before the guest answers is streamed (P5 covers that).
The generated `/init` passes `sh -n`; never booted.

**Effort/HW.** Half a day; the first boot with the fragment proves it. Same kernel build as P2.

## P4. `m5 deploy`

Prototype: `prototypes/host/macos/m5-deploy.sh`.

**Problem.** Every deploy so far was hand-run steps (RESULTS.md:20-23), and a non-booting payload
stalled the agent until Rolando was back.

**Mechanism.** One command.
1. Local: hash, size, and the kernel release read out of the gzip'd Image inside the payload
   (tested on a synthetic payload), so the post-boot check needs no input.
2. Upload over `eem-vm.py --put` to `boot.bin.new` and re-hash on the M5.
3. Rotate `boot.bin` -> `boot.bin.prev` only if the running boot came from the primary slot and is
   not itself on trial, so `boot.bin.prev` is always a payload that has booted.
4. Install, write `m1n1/TRIAL`, log to `DEPLOY.log`.
5. Clean reboot.
6. Wait for SSH; verify `uname -r`, slot = primary, `nproc` = 18, optional `--check 'CMD'`.
7. No SSH: save the m1n1 console replay if the proxy enumerated (`m5.sh log`, `m5.sh:105-139`),
   then `sudo macvdmtool reboot`.
8. Back on `fallback-after-failure`: collect pstore, the previous boot's journal and the
   netconsole slice into `~/Work/m5-logs/deploy-<ts>/`, demote, exit 1.
9. Still nothing: exit 3 with the exact manual steps.

On a stage-1 without A/B (no `m5pro,boot-slot`) it stops before step 7 and prints the macOS-side
copy instructions.

**Risk.** `macvdmtool reboot` needs passwordless sudo: add it to `host/macos/sudoers-m5pro`. Each
failed reachability probe through eem-vm costs ~30 s (its `setup()` waits up to 20 s for the
interface). `bash -n` and shellcheck clean apart from one informational warning; never run.

## P5. pstore/ramoops in iBoot's panic region

**Problem.** Text printed before the network is up, and the last words of a hard hang, are lost at
the reset.

**Evidence that DRAM survives a reset through iBoot.**
- The ADT has a `/pram` node (~1.5 MiB). Its address is above the RAM Linux is given (Linux RAM
  ends at 0x10b_c8a0_0000, `contrib/pending/gpu/REPORT.md` section 1), next to the boot framebuffer.
- XNU uses that node as its panic buffer: `check_for_panic_log()` does `SecureDTLookupEntry(0,
  "pram", ...)` and maps it as `gPanicBase`. Its comments say "DT properties for the panic region
  are populated by UpdateDeviceTree() in iBoot", complain when "iBoot didn't extract panic log from
  previous session crash", and `PE_sync_panic_buffers()` flushes it "as late as possible before
  reset" (https://github.com/apple-oss-distributions/xnu/blob/main/pexpert/arm/pe_init.c). The
  region exists to survive the reset and be read on the next boot.
- `/arm-io/wdt` also has `panic-save-flag-bit` and `awl-scratch-supported`: XNU probably sets a
  flag in always-on scratch before the reset, and iBoot may preserve or extract the region only
  when it is set. Unknown; measure.
- No Asahi or Apple-silicon ramoops precedent turned up. General background: ramoops only works
  where boot firmware does not clear DRAM; warm reboots preserve, cold ones do not
  ([OpenWrt thread](https://lists.openwrt.org/pipermail/openwrt-devel/2022-August/039296.html),
  https://docs.kernel.org/admin-guide/ramoops.html).

**Mechanism.** m1n1 stage-2 `kboot` adds `reserved-memory/ramoops@<pram base>` (`compatible =
"ramoops"`, `record-size 0x10000`, `console-size 0x80000`, `pmsg-size 0x10000`, `ecc-size 16`,
`mem-type 1` = unbuffered, because XNU's comment warns that dirty write-combined lines in the memory
cache can be lost at reset). Kernel: `PSTORE_RAM=y`, `PSTORE_CONSOLE=y` (`PSTORE_RAM` is `=m`
today, `.config:11127`, and modules never load). `/sys/fs/pstore/console-ramoops-0` then holds the
whole console of the previous boot, including built-in initcalls and a panic's oops;
`m5-deploy.sh` collects it.

**Retention probe first (Round 1, 3 boots, before writing the m1n1 change).** From Linux,
`busybox devmem`-write a 64-byte pattern into the last page of `/pram` (not System RAM, so
`STRICT_DEVMEM` allows it) and read it back after (a) `systemctl reboot` (watchdog restart),
(b) `echo c` + `panic=10`, (c) `macvdmtool reboot`. If iBoot zeroes `/pram`, repeat in a 1 MiB
carve-out m1n1 reserves inside normal RAM. If that is cleared too, P5 is dead and P3 carries the
load.

**Risk.** iBoot may treat a non-XNU header as garbage and clear it. Writing to `/pram` could
confuse a later macOS boot's panic reporting (`check_for_panic_log` only acts on its own magic);
zero the region on clean Linux shutdown to be safe.

**Effort/HW.** m1n1 kboot change ~60 lines; 3 probe boots + 1 validation boot.

## P6. Studio-side hang watchdog

**Problem.** What P1/P2 miss: the watchdog is fed by a live kthread while the interesting part of
the system is wedged, or stage-2 sits in the proxy.

**Mechanism.** A LaunchAgent `m5-hangwatch` (design). Every 30 s it records: gadget present
(`ioreg`), SSH through the persistent guest, m1n1 proxy present. It **fires only while armed**:
`m5-deploy.sh` and agents touch `~/Work/m5-logs/hangwatch.armed` with an expiry. Trigger: the last
state seen while armed was "Linux up" and SSH has been gone for N = 10 min, or the proxy has sat
for 5 min. Action: `sudo macvdmtool reboot` (works today, `boot-and-recovery.md:213-215`,
`m5.sh:140`), at most 3 per day, every action logged.

**Risk.** Resetting a Mac that is running **macOS** for Rolando (the gadget is absent then too):
hence armed-only, expiry and the "last state was Linux" rule. Never run it unarmed.

**Effort/HW.** Half a day; one forced hang.

## P7. A camera on the panel

**Problem.** Nobody but Rolando sees the panel. Network-free failures stay invisible to P3/P5:
iBoot recovery screens, m1n1 stage-1 text, earlycon before the gadget.

**Mechanism.** A UVC webcam on a gooseneck (USB on the Studio; 4K preferred), or a spare iPhone as
Continuity Camera (iPhone XR or later, locked, landscape, stationary;
https://support.apple.com/en-us/102546). Rolando's own iPhone leaves with him, so it does not count.
`host/macos/m5-panel.sh` (design):
- `snap`: `ffmpeg -f avfoundation -i "<cam>" -frames:v 1 ~/Work/m5-logs/panel/<ts>.png`
- `ocr`: a 40-line Swift tool with `VNRecognizeTextRequest`, accurate level, language correction
  off (https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- `watch`: one frame every 10 s while SSH is down, kept when it differs from the previous one, OCR
  appended to `panel.log`

`m5-deploy.sh` calls `snap`/`ocr` at step 7, and an agent can read the PNG directly. Legibility:
earlycon's 8x16 font on a 3456x2160 panel is small; once fbcon takes over,
`fbcon=font:TER16x32` (`CONFIG_FONT_TER16x32=y`) gives OCR 4x the pixels per glyph.

**Risk.** macOS camera permission (TCC) must be granted once to the capturing process; glare (tilt
the camera); the camera sees the desk, so frames stay local, never in the repo.

**Effort/HW.** 1 day; 30 min to mount and focus.

## P8. A second, better network path

**Problem.** The only network is CDC-EEM via a QEMU guest, because macOS has no EEM driver
(`boot-and-recovery.md:89-91`), and ACM/NCM fail on this port.

- **(a) USB host Ethernet after Stage C** (left-front port, `contrib/validated/legacy-7.2/usb/`): an
  AX88179/RTL8153 dongle (no firmware, both `=y` in the USB fragment) via a powered hub. DHCP from
  the Studio's LAN, SSH straight from macOS, internet for pacman. It takes the guest off the
  critical path, and it is the same port that later carries a Wi-Fi/BT dongle (ROADMAP T1.4).
  Risks (USB REPORT "Risks"): VBUS sourcing unproven (1b, PD controller), fragile hot-plug; plug in
  before boot.
- **(b) A libusb EEM bridge on macOS, replacing QEMU** (design, 1-2 days): claim the EEM interface
  with libusb, strip/add the 2-byte EEM headers, answer ARP, and hand IP packets to a `utun`
  interface (root, `PF_SYSTEM` control socket). The Mac then routes 10.55.0.0/24 natively and
  netconsole lands on a local UDP socket. Saves the 35-50 s guest boot and the re-attach race.
- **(c) Thunderbolt IP** once aurora's TB stack runs on the right port (ROADMAP T2.4): Linux
  `thunderbolt-net` speaks Apple's ThunderboltIP and talks to macOS's Thunderbolt Bridge
  (https://docs.kernel.org/admin-guide/thunderbolt.html, "Networking over Thunderbolt cable").
  Months away.

## P9. Startup disk and one-time boot

**Problem.** After a macOS boot the Mac comes back into macOS (Rolando sets Startup Disk to
Macintosh HD before trips, RESULTS.md:155-156); getting back needs the power-hold picker.

**Mechanism.** From Linux: `asahi-bless` (https://github.com/WhatAmISupposedToPutHere/asahi-nvram)
lists boot volumes and sets the next or default one. Untested on M5 (distro GAPS #22): run
`--list` read-only first, then a one-time switch to macOS and back. From macOS on the M5:
`sudo bless --mount /Volumes/Omarchy --setBoot` (Apple silicon asks for an admin credential) or
the Startup Disk pane's Restart; the one-time variant needs testing. Wrap it as `m5.sh to-linux`
behind `sudoers-m5pro`. Policy: keep the stub as the default and make macOS the exception (picker
or one-time), so every unattended reboot lands in Linux.

**Risk.** NVRAM writes from Linux on a new SoC: read-only first; never touch `boot-args` or
policies.

## P10. Serial console

`macvdmtool serial` over the TB cable answers BUSY `0x05ac80d2`, and `/chosen/debug-enabled = 0`
(`boot-and-recovery.md:213-215`). Apple's debug UART on USB-C is only muxed when the target's iBoot
allows it, and on this production machine it evidently does not, at least from a Mac acting as host.
Options: try `serial` while the M5 sits in m1n1 rather than Linux and on the other ports; a Central
Scrutinizer board (Asahi's open USB-PD/VDM + UART adapter, https://github.com/AsahiLinux/vdmtool)
might get a different answer than a Mac host, though the same `debug-enabled` gate probably
applies; m1n1's console goes to the s5l UART (`src/uart.c`) only if the pins are muxed. Lowest
priority: P3+P5+P7 cover the need without a hardware gamble. Revisit if P5's retention probe fails.

## Physical setup that never changes (intervention 7)

One 15-minute session on Sunday, then leave it:
- left-back (MagSafe side): the TB cable from the Studio's DFU port (`macvdmtool reboot`, gadget
  udc0);
- left-front: a powered USB hub with an Ethernet dongle (Stage C), later the Wi-Fi/BT dongle;
- right: gadget udc2 to the CalDigit (second link for netconsole);
- MagSafe charger in, camera on the panel, lid open.

## Probe hangs (j): making the macsmc-power hang visible

1. P1's watchdog resets the 7.8 s hang and the next boot takes the fallback: no human.
2. P5's console ramoops holds the text up to the hang, including built-in initcalls; with
   `initcall_debug` on the trial cmdline it names the last initcall, and with `dev_info`s the last
   SMC key.
3. P3's module hook: a bisect kernel with `MACSMC_POWER=m`, loaded by `m5.insmod=macsmc_power` after
   netconsole is up, streams the same lines live.
4. If all of that fails: run the kernel under the m1n1 hypervisor over the tether, which can stop
   the guest and dump every vCPU's PC (the HV runs on T6050 for macOS, m1n1 patches 0009-0011).
   Needs the proxy (move `boot.bin` aside from Linux) and the tether.

Agent's reading of the cause (unverified): a hard hang 7.8 s in, inside the probe, without even a
soft-lockup report (none was configured, P2), looks like a bus-level stall: a CPU stuck on a load
from a powered-down block, or an SMC call the firmware never answers while a lock is held. Bisect
order: the first `apple_smc_read` of each key in probe order, then power-supply registration, then
the notifier.
