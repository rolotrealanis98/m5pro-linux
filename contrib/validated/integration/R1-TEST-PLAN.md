# R1 hardware round, Sunday 2026-11-08: J716s (16-inch MacBook Pro, M5 Pro, T6050)

Rolando at the desk, about 3.5 to 4 h. Everything here was built and checked offline on
2026-11-05/06. R1-A and R1-B ran on 2026-11-06 (solo, see `RESULTS.md` "Round R1"); the rest has not run yet.

## What is new in the R1 kernel

Kernel tree `/Volumes/linux-cs/wt-integration`, branch `r1-integration` (B2 = integration 0001-0017,
plus 0018-0033 below). Patches: `~/Work/agents/integration/patches/linux/0018-0033`; omarchy-m5
form: `patches/omarchy-m5/0004-*` (apply after 0003).

| Patch | What | Effect on R1 |
|---|---|---|
| 0018 | macsmc: refuse a reply bigger than the read buffer, copy only the bytes returned | every SMC read |
| 0019 | macsmc: atomic SMC write (power-off) gives up after 0.5 s instead of spinning with IRQs off forever | power-off path only |
| 0020 | macsmc: keep the lock until GET_KEY_INFO's answer is copied (BCF0 width race) | battery probe |
| 0021-0022 | macsmc: key-index bounds, short #KEY reply = -EIO | none expected |
| 0023 | macsmc: low-gpio cell added only when the DT has it (J716s has it; now registered after hwmon/reboot/rtc) | watch trackpad |
| 0024-0027 | macsmc-power: B0RM byte order apart from BCF0 size, charge_lock and write-reply fixes, CHLS no longer forces discharge, optional props only if their keys exist, TTE/TTF -ENODATA | battery (R1-B) |
| 0028 | `macsmc_power.trace=1`: logs every SMC key before it is sent, during probe and the first property sweep | R1-B only |
| 0029-0030 | simpledrm eDP connector + `apple,internal-panel` on framebuffer0 | Omarchy lid lock, notch layout |
| 0031 | xhci-plat honours `wakeup-source` | no J716s user yet (all ports are snps,dwc3) |
| 0032 | fpwm0 + pwm-leds `kbd_backlight` | keyboard backlight |
| 0033 | `omarchy-desktop.config`: zram+zstd, nf_tables/nft_compat/conntrack/xt for ufw, PWM_APPLE=y, schedutil default, PM_DEBUG, hibernation off, report-only lockup detectors | all |
| 0034 | platform 0042: PMGR domains are left alone in system sleep on T6050 (s2idle guard) | step 5 only |

Most SMC/battery/desktop items are ports of edimoldovan/linux-aurora (J714c, same T6050), credited
per patch. None of them is a proven cause of the round-3 battery hang; step 2 finds the key.

## Payloads

`~/Work/agents/integration/payloads/r1/` (hashes in `SHA256SUMS`, copied at the end of this file).
Layout, one gzip member each, verified by `r1/mk-r1-payloads.py`:
`m1n1-plain.bin | chosen.bootargs=...\n | chosen.asahi,show-notch=1\n | Image.gz | DTB | initramfs-debug.cpio.gz`.

| File | DTB | Arguments on top of the B2 base* |
|---|---|---|
| `R1-A-olddtb-gated.bin` | t6050-j716s.dtb (normal board DTB, rebuilt with backlight + internal-panel) | `initcall_blacklist=macsmc_power_driver_init` |
| `R1-B-olddtb-battery-trace.bin` | same | `macsmc_power.trace=1 panic=0 pause_on_oops=300 ignore_loglevel` (no blacklist) |
| `R1-C-usbhost-gated.bin` | t6050-j716s-usbhost.dtb | `initcall_blacklist=macsmc_power_driver_init` |
| `R1-D-olddtb-battery.bin` | t6050-j716s.dtb | nothing (battery enabled, no trace/panic/pause_on_oops/ignore_loglevel); added 2026-11-06 after R1-B booted 3/3 |
| `R1-E-usbhost-battery.bin` | t6050-j716s-usbhost.dtb | nothing (same as R1-D); added 2026-11-06 |

\* B2 base: `earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused
no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5`. `cpufreq.default_governor=userspace`
is gone: schedutil is the default (the J714c ran the same OPPs on schedutil). kboot still appends
`idle=nop arm64.nowfxt`; never remove them.

**Notch:** m1n1's payload parser accepts `chosen.asahi,show-notch=1` (a `chosen.*` variable,
`src/payload.c` `check_var`), but the current `m1n1-plain.bin` (sha `742c5981...`) does not act on it:
it always trims the framebuffer below the notch. Expect the variable in `/proc/device-tree/chosen/`
and the notch still hidden (3456x2160). The fix is m1n1 patch
`patches/m1n1/0017-kboot-keep-the-notch-rows-with-chosen.asahi-show-not.patch` (port of edimoldovan's
`kboot_show_notch`), not built into these payloads because the m1n1-plain build recipe was not
reproduced here.

## Ground rules

- Before each deploy: `sha256sum` the payload on the Mac and compare with `SHA256SUMS`.
- Deploy = copy to `/boot/m1n1/boot.bin.new`, check hash, rotate `boot.bin -> boot.bin.prev`
  (only from a payload that booted), rename, `sync`, `systemctl reboot` (FRICTION P4; `m5-deploy.sh`
  does this when the A/B stage-1 is in).
- Save every step's evidence to `~/Work/m5-logs/r1-<step>-<time>/`: `dmesg`, `journalctl -b`,
  `/proc/cmdline`, panel photos.
- Rollback without A/B stage-1 (RESULTS.md "Asks"): power-hold, boot macOS, mount the OMARCHY ESP,
  `cp m1n1/boot.bin.prev m1n1/boot.bin`, eject, boot the stub. With A/B stage-1: a hang resets after
  150 s and boots `boot.bin.prev` on its own.
- Never in this round: suspend beyond S1, hibernation, removing `idle=nop arm64.nowfxt`, writes to
  the PMIC nvmem, NVRAM or boot policy outside step 0.

## Step 0: one-time A/B stage-1 ceremony (only if the main session confirms it), ~35 min

Gives automatic fallback (stage-1 reads iBoot's PMU boot-error count and boots `boot.bin.prev`
after a failed boot) and an armed SoC watchdog (150 s) that turns the 7.8 s battery hang into a
reset. Image: `m1n1-chain-ab.bin` (sha `088c383b...`, `contrib/pending/boot-ab/SHA256SUMS`), raw
0x420000, wrapped to 0x430000 (same size/alignment as today's stage-1; the cliff is at or below
0x4D0000).

1. On the Studio, build the stage-1 object (the ESP PARTUUID is read on the Mac, never written into
   a file in the repo):
   `prototypes/contrib/distro/tools/mk-stage1.py stage1 --m1n1 ~/Work/agents/plan/m1n1-chain-ab.bin
   --esp-partuuid <ESP PARTUUID> --fallback-path m1n1/boot.bin.prev --wdt 150 -o ~/Work/m1n1/stage1/boot-ab.bin`,
   then `mk-stage1.py inspect` it.
2. In macOS on the M5: copy today's stage-1 to `~/Work/m1n1/stage1/` as the rollback image, then
   `sudo host/macos/stage1-install.sh ~/Work/m1n1/stage1/boot-ab.bin`. Set Startup Disk to the stub,
   power-hold -> Omarchy -> step 2 (kmutil configure-boot from the paired 1TR).
3. First boot comes up on B2 (`boot.bin`, restored before the trip).
4. A/B tests 1-2 (FRICTION P1): `/proc/device-tree/chosen/m5pro,boot-slot` = `primary`,
   `m5pro,pmu-scrpad` = `2f0000` or `300000`, 18 CPUs, `/sys/class/watchdog/watchdog0/state` =
   active; `systemctl reboot` twice, primary both times.

Rollback: from a 1TR Terminal, `kmutil configure-boot -c /Volumes/Omarchy/m1n1/<old stage-1>.bin
--raw --entry-point 2048 --lowest-virtual-address 0 -v /Volumes/Omarchy`.
Skip the whole step if not confirmed: then every hang below costs a macOS round trip (~10 min),
so do steps 3 and 4 before step 2.

## Step 1: R1-A boot and desktop checks, ~45 min

Deploy `R1-A-olddtb-gated.bin` over B2.

| Check | Command | Pass |
|---|---|---|
| Kernel and args | `uname -r; cat /proc/cmdline` | release `7.2.2-ge1d2d7313745`; blacklist present; no `default_governor`; ends `idle=nop arm64.nowfxt` |
| 18 CPUs | `nproc; dmesg \| grep -i 'smp: Brought up'` | 18 |
| NVMe, trackpad | `dmesg \| grep -E 'nvme\|Touch MT ready\|afe-reset'` | NVMe up < 12 s; `Touch MT ready`; `macsmc-low-gpio` probed (0023 moved it after hwmon/reboot/rtc) |
| SMC core | `dmesg \| grep -iE 'macsmc\|smc'` | as B2: gpio, low-gpio, input, rtc, hwmon, reboot (poweroff-only); no `macsmc-power` line |
| cpufreq schedutil | `grep . /sys/devices/system/cpu/cpufreq/policy{0,6,12}/{scaling_governor,scaling_cur_freq,cpuinfo_min_freq,cpuinfo_max_freq}` | schedutil x3; idle 10 s -> 1344000/1344000/1308000; max 4308000 |
| cpufreq under load | `./cpuhz 1 & ./cpuhz 7 & ./cpuhz 13 &` (contrib/validated/legacy-7.2/cpufreq/tools) | busy cluster goes to 4308000; `cpuhz` within 2 % of `scaling_cur_freq` |
| OPP level offset (open question) | `./dvfs-regs` at idle and under load; `cpuhz` vs table | ours: p-state = table index + 2 (measured on J714s M cluster, guessed for P). edimoldovan's J714c DT uses index + 1 with the same frequencies. If `cpuhz 13` reads one table step higher than `scaling_cur_freq` (e.g. 1620 at 1308000), the P table is off by one: record, do not change anything today |
| Keyboard backlight | `cat /sys/class/leds/kbd_backlight/max_brightness`; `echo 32 > .../brightness`; `echo 255 ...`; `echo 0 ...` | 255; keys dim/full/off; no fpwm0/PMGR errors |
| eDP connector | `ls /sys/class/drm/; cat /sys/class/drm/card*-eDP-1/status /sys/class/drm/card*-eDP-1/modes` | `card0-eDP-1` (was `card0-Unknown-1`), connected, one mode |
| Lid | `evtest` on "Apple SMC power/lid events": close/open the lid | SW_LID 1/0. In an Omarchy session the lid locks the screen (needs the eDP connector) |
| Notch | `cat /sys/class/graphics/fb0/virtual_size; xxd /proc/device-tree/chosen/asahi,show-notch` | `3456,2160` and the property = "1" (inert with this m1n1, see Payloads) |
| zram | `zramctl; swapon --show; cat /sys/block/zram0/comp_algorithm` | zram0 with `[zstd]` (if zram-generator is installed; otherwise `modprobe`-free `echo 4G > /sys/block/zram0/disksize` after `cat /sys/class/zram-control/hot_add`) |
| ufw | `iptables -V; ufw enable; ufw status verbose; nft list ruleset \| head; ufw disable` | `nf_tables` backend; ufw active with its default rules, no "can't initialize iptables table" / missing-match errors; SSH over the gadget link still works while enabled (allow it first: `ufw allow in on usb0 to any port 22`) |
| No new noise | `dmesg -l err,warn` | nothing new vs B2 apart from expected `netfilter` notices; no lockup-detector lines |
| Restart | `systemctl reboot` | comes back on R1-A, no PMU boot error logged |
| Power-off (optional, finger on the button) | `systemctl poweroff` | machine off within seconds; if it is not off after 10 s, 0019's timeout should have printed `Atomic command timed out` before falling to the next handler: photograph |

Rollback: `boot.bin.prev` (B2). Any failure here does not block step 3; it blocks steps 2, 4, 5 only
if the boot itself is broken.

## Step 2: R1-B battery with the probe trace, ~30 min (+10 min if it hangs without A/B)

Deploy `R1-B-olddtb-battery-trace.bin` (only after R1-A booted: `boot.bin.prev` must be R1-A or B2).

Before rebooting, put the camera on the panel. During boot, at ~7-8 s, the panel shows
`macsmc-power macsmc-power: trace: <op> <KEY> size <n>` lines: `rd`/`wr` key reads/writes,
`info` key-existence/size queries, and step lines (`probe start`, `registering the battery`,
`registering the AC adapter`, `registering the SMC event notifier`, `probe done`,
`battery get_property <n>`).

**If it boots** (the fixes or the changed timing helped):
- `dmesg | grep 'macsmc-power' > trace.txt` (the whole trace); `dmesg | grep -iE 'battery|BCF0|CHLS|CHWA'`.
- SMC TEST-PLAN T6 checks: `ls /sys/class/power_supply/` -> `macsmc-battery macsmc-ac`;
  `cat /sys/class/power_supply/macsmc-battery/uevent`: STATUS matches the plug, CAPACITY = macOS %,
  VOLTAGE_NOW 11-13.1e6, CHARGE_NOW <= CHARGE_FULL (~8.4-8.8e6 µAh; ~20e6 = B0RM byte order wrong),
  CYCLE_COUNT = macOS, TEMP 200-400; TIME_TO_EMPTY absent/ENODATA on AC (0027).
- Unplug/replug MagSafe: `macsmc-ac/online` flips, STATUS follows within ~2 s.
- Which charge-limit key exists: the trace shows `rd CHWA` then (if it failed) `rd CHLS`.
  Do not write thresholds today.
- Two clean reboots on R1-B; then this payload's trace is no longer needed.

**If it hangs** (panel frozen):
1. Photograph the panel at once; the last `trace:` line names the key and the operation.
2. Leave it 60 s and photograph again: with 0033's detectors, a CPU spinning with interrupts on
   or off now prints `soft lockup` / `hard LOCKUP` / RCU stall text; nothing new = a whole-SoC freeze
   (bus or SMC), which is evidence too.
3. Recovery: with A/B stage-1 the watchdog resets it at 150 s and `boot.bin.prev` boots by itself
   (`m5pro,boot-slot` = `fallback-after-failure`). Without A/B: power-hold, macOS, restore
   `boot.bin.prev`, boot the stub.
4. **Rollback rule:** at most two hanging boots of R1-B in this session. The second attempt only if
   the first photo is unreadable or the last line is a step line, and then with
   `macsmc_power.trace_delay_ms=50 initcall_debug` added (needs a re-assembled payload: run
   `mk-r1-payloads.py` after editing its R1-B arguments; record the new hash). After that, battery
   stays blacklisted and the decision moves to R2.

What the last line tells us (decide in R2, not at the desk):

| Last trace line | Next build |
|---|---|
| `rd B0AV` or a key of `macsmc_battery_get_status` (CHCE, CHCC, CHSC, CHNC, CH0R, BSFC, BUIC, AC-i, CHWA/CHLS) | the first SMC read of the driver hangs: compare with hwmon reads that work; try the key from userspace via a debugfs read helper |
| `info BCF0` / `info CHTE` / `info CH0C` / `info CH0I` | GET_KEY_INFO for that key hangs: skip that query and assume the 27.x layout |
| `wr CHTE`, `wr CH0C`, `wr CH0I`, `wr CH0K`, `wr CH0B` | the "reset Optimised Battery Charging" writes: drop them on T6050 (they are writes to keys macOS 27 may have removed) |
| `rd BMDN` / `rd BMSN` / `rd BMDT` (size 255) | 255-byte string reads: read the key size first and ask only for that |
| `registering the battery` or `battery get_property <n>` | power_supply core sweep: the property `<n>` (enum power_supply_property) names the key |
| `probe done` | not the probe: SMC events (notifier) or the battery thermal zone/hwmon polling |

## Step 3: PMP window double dump for joshuaswarren (tethered, read-only), ~30 min

Question: does mBoot start the PMP coprocessor on 27.3 beta 1? Window: ADT `/arm-io/pmp0` reg[0] =
arm-io 0x84e00000 -> **0x284e00000, size 0x88000** (same as J716c), read from our runtime ADT with
`m1n1.adt`. Its clock/power gates are ADT ids 27 and 28 -> PMGR power-state registers
**0x280600128** (our `ps_pmp`) and **0x280600130** (`ps_pms_sram`). The script reads only these two
PMGR registers and the window, never writes a device register.

Script: `~/Work/agents/integration/r1/pmp-dump.py` (looks the window up in the live ADT, refuses an
unexpected size, records PMGR state, copies 1 KiB chunks under m1n1's exception guard, re-reads
faulting chunks word by word; faults are stored as `0xdeadfa17` and listed in a JSON file).

1. Get to the stage-1 proxy: from Linux `mv /boot/m1n1/boot.bin /boot/m1n1/boot.bin.hold`
   (with A/B also `mv boot.bin.prev boot.bin.prev.hold`, or it simply boots the fallback), `sync`,
   `systemctl reboot`. On the Studio: `host/macos/m5.sh wait`.
2. Dump A, right after the hand-off, nothing else run:
   `host/macos/m5.sh py ~/Work/agents/integration/r1/pmp-dump.py --stage handoff`
3. Chainload stage-2 m1n1 (its full init: PMGR setup, display, 17 secondaries), as `m5.sh boot-linux`
   does: `host/macos/m5.sh py tools/chainload.py -r -n ~/Work/studio-artifacts/m1n1-chain.bin`,
   `host/macos/m5.sh wait 120`, then Dump B:
   `host/macos/m5.sh py ~/Work/agents/integration/r1/pmp-dump.py --stage m1n1-stage2`
4. Optional Dump C (the "after a full tethered boot" reading): `host/macos/m5.sh boot-linux` with
   `LINUX_ARGS` = the R1-A arguments and the R1 kernel (`M5_ARTIFACTS` pointing at a folder with
   R1's Image.gz/DTB/initramfs-debug and m1n1-chain.bin); once Linux is up, `systemctl reboot`
   (boot.bin is still aside, so it returns to the stage-1 proxy), `m5.sh wait`, then
   `--stage after-linux`.
5. Diffs: `pmp-dump.py --diff ~/Work/m5-logs/r1-pmp/pmp0-handoff.bin ~/Work/m5-logs/r1-pmp/pmp0-m1n1-stage2.bin`
   (and against after-linux). Keep the .bin, .json and the diff text.
6. Restore: in Linux (step 4's boot, or `m5.sh boot-linux`), `mv boot.bin.hold boot.bin`
   (and `.prev.hold`), `sync`, `systemctl reboot` untethered.

Evidence: PMGR values (target/actual nibbles), fault map, sha256 of each dump, the diff. A fault or
an all-zero window with PMGR "off" is an answer ("not started / gated"); live, changing words
between A and B mean the PMP runs. If the proxy stops answering mid-read, write down the last
chunk offset it printed and power-hold: the block hung the bus, which is also an answer.
Publishing: hexdumps of the changed words and the PMGR values only (no ADT identifiers).

## Step 4: R1-C USB host with the Ethernet adapter, ~35 min

Deploy `R1-C-usbhost-gated.bin`. Host port = left-front (dwc3_1 @ 0x2aa280000); the tether stays on
left-back. Plug the USB-C Ethernet adapter (r8152/ax88179/cdc_ncm) into the left-front port
**before** booting (edimoldovan: left-front only enumerates when plugged before boot with his
kernel/m1n1). Have the inline power meter between port and adapter.

| Check | Command | Pass |
|---|---|---|
| PHY/xhci | `dmesg \| grep -E 'phy-apple-usb2\|xhci\|2aa280000'` | three phy lines (2aaa90000 "default host mode"); xhci-hcd with two root hubs; no -110 / HC died / DART faults |
| Roles | `cat /sys/class/usb_role/2aa280000.usb-role-switch/role; ls /sys/class/udc` | `host`; udc = 2a2280000.usb and 382280000.usb only |
| Tether | `ssh` over the left-back link | still works |
| VBUS | meter | ~5 V = the PD controller sources VBUS; 0 V = no VBUS (our m1n1 0005 skips the T6050 USB-PD setup; Omacom m1n1 160b644c does it): try a self-powered hub, then stop and note it |
| Enumeration | `lsusb; dmesg \| grep 'usb 1-'` | `new high-speed USB device`, driver binds |
| Network | `ip link; networkctl; ping -c3 -I eth0 <gateway>` | link up, DHCP lease, ping OK |
| Throughput (optional) | `curl -o /dev/null <LAN file>` | record MB/s (USB 2.0: <= ~35 MB/s) |
| Replug | unplug/replug the adapter | record whether it re-enumerates; if not: `echo 2aa280000.usb > /sys/bus/platform/drivers/dwc3/unbind; echo 2aa280000.usb > .../bind` |

Rollback: R1-A (or B2) as `boot.bin`. A USB failure is not a hang risk; the old DTB is the rollback.

## Step 5: s2idle first safe step, only if step 2 passed, ~10 min

Guards (platform TEST-PLAN): R1-A or R1-B running; kernel has 0034 (= platform 0042):
`cat /sys/module/pmgr_pwrstate/parameters/sleep_power_off` -> `-1`; the logind/sleep safe defaults
from `contrib/pending/platform/userspace/etc/systemd/` installed (nothing triggers sleep on its own);
logs to `/dev/shm`.

1. S0: `cat /sys/power/state /sys/power/mem_sleep /sys/power/pm_test` -> `freeze` present,
   `[s2idle]`; `echo 1 > /sys/power/pm_debug_messages; echo 1 > /sys/power/pm_print_times`.
2. S1 (freezer only, no device callbacks), detached because the SSH link may stutter:
   `setsid sh -c 'echo freezer > /sys/power/pm_test; echo freeze > /sys/power/state; echo rc=$? > /dev/shm/s1.rc' &`
3. Pass: `/dev/shm/s1.rc` = `rc=0`, `PM: suspend exit` in dmesg, SSH and input still alive.

Stop there. S2 (devices: NVMe ANS shutdown/restart over RTKit) and later steps need the root
read-only and belong to R2. Rollback: none needed for S1; if the machine does not come back within
30 s, power-hold (no device was suspended, nothing to repair).

## Time budget

| Step | Minutes |
|---|---|
| 0 A/B ceremony (if confirmed) | 35 |
| 1 R1-A | 45 |
| 2 R1-B (boots / hangs with A/B / hangs without A/B) | 20 / 25 / 35 |
| 3 PMP dumps (A+B; C adds 15) | 30 |
| 4 R1-C | 35 |
| 5 S0+S1 | 10 |
| Total | about 3 h 15 to 3 h 50 |

## Uncertain going in

- Whether 0018-0027 change the battery hang at all: edimoldovan's probe issues essentially the same
  SMC commands on J714c and works; the remaining differences are board (J716s battery/gas gauge),
  our DT (low-gpio bank, macsmc-reboot enabled) and timing.
- The P-cluster OPP p-state offset (+2 ours vs +1 his, same frequencies).
- VBUS on the left-front port without the T6050 USB-PD setup in m1n1.
- The notch variable is inert until m1n1-plain is rebuilt with patch m1n1/0017.
- zram-generator/ufw availability on the Arch root (the kernel side is in; userspace may need
  `pacman -S zram-generator ufw`).

## Payload hashes

```
6d6a402b4192c0bd09e28fd87bfe55880a9a2338cace52b9e36398ce9970bf49  R1-A-olddtb-gated.bin
c4edcb33058b44f0f89168b8e507afa338edc580559c872fe7141f2fe19bea8a  R1-B-olddtb-battery-trace.bin
019cf5f17a2e347ae4a3add9e476a6fb35799e8f8244ba5ea0ec455c2d21c244  R1-C-usbhost-gated.bin
063475c85444e463d685d06b56f1a8bd3bc355ea3f148135a53a42e54d962905  R1-D-olddtb-battery.bin
28627b6c3292366b95d300cf136956da1ecf70d117dcbcc19b977668c60564fc  R1-E-usbhost-battery.bin

# inputs
742c59817f39cd0f2ab2cce50db347d8ad951d6848f56e492987c66d9c4b11a9  m1n1-plain.bin
f8435d87324341f64793c7e1e95915a5ac02de537274516f847fa3dc29a3b91d  Image.gz
41ff0eb5b9a7a129b38b960350e10f431fa962dd5578acf66670556c283e5558  t6050-j716s.dtb
64d2c6cbef0566a6d3edfa20c910d8bb3e13a516bbcdb39037a85c6a8d561949  t6050-j716s-usbhost.dtb
22ba864fdc2dd54bec076b3085ac90b2a5f6fd94286b138b8ea45c232c8ee825  initramfs-debug.cpio.gz
```
