# GPU + DCP "early panic" of daily-dcp-phfix-test: a counted restart, not a panic (2026-11-08)

Studio-only reading of the round-4 run (`~/Work/agents/daily-dcp/loop/run-dcp-round4.log`). Nothing was run on the
MacBook. Private inputs (journals, payloads, the m1n1 logs) stay on the Studio.

## What was observed

| Boot (round 4, in order) | delta | slot | pmu | firstboot-probe said | kernel that ran |
|---|---|---|---|---|---|
| B4-nogpu `2b6f5c26` (display hand-off, no `gpu=1`) | 50 s | primary | 300030 | clean | 7.3.0-gbd53915f2ef1: apple-drm on eDP-2, Hyprland |
| B4-twin `e03be5ac` (`gpu=1` + display, phfix DTB) | **55 s** | fallback-after-failure | **300100** | attempt-linux-panic | **the fallback daily** 7.3.0-g36845aa5f650 |
| B4-vrr `be84bb7d` (= e03be5ac + `appledrm.fw27_panel_vrr=1`) | 50 s | primary | 300000 | clean | 7.3.0-gbd53915f2ef1: card0 aurora, card1 apple-drm, Wi-Fi, two-card Hyprland |

`reboot->ssh` was 107 s for e03be5ac and 106-107 s for the two clean boots around it.

## Why it was a counted restart of the B4 session

**Conclusion:** the e03be5ac kernel almost certainly never ran. Stage 1 found iBoot's boot-error count already set by
the B4 session's own `systemctl reboot` and booted `boot.bin.prev` on its first pass. This is case 1 ("counted
restart") of `contrib/pending/boot-ab/firstboot/REPORT.md`: error stage `00`, within +0 to +8 s of a clean boot, and
the new file is not read.

1. **The timing has no room for a second boot.**
   - The fallback kernel started 55 s after the reboot command. The clean boots in the same loop started at 48-51 s
     (the eight clean probes in `run-dcp-bisect*.log` and `run-dcp-round4.log`).
   - A panic would need all of: the attempted kernel's start, about 1-2 s to the panic, `CONFIG_PANIC_TIMEOUT=10`,
     and a second reset-to-kernel cycle of 22-26 s (sysrq-c calibration). That adds about 35 s over a clean boot. We saw
     +5 s.
2. **Error stage `00` cannot come from a Linux panic.**
   - boot_stage 0x00 is written only by `macsmc_reboot_notify()` (`drivers/power/reset/macsmc-reboot.c:153-156`). That
     is a reboot notifier, called from `kernel_restart_prepare()` (`kernel/reboot.c:110-115`), so only an orderly
     `kernel_restart()` writes it.
   - A panic restarts through `emergency_restart()` (`kernel/panic.c:743`, `kernel/reboot.c:94-107`), which calls no
     reboot notifier. The value then stays at the 0x30 that macsmc-reboot wrote at probe (`macsmc-reboot.c:240-243`).
3. **The probe order rules out a panic in either band.**
   - On the dual boot that worked (`journal-daily-dcp-phfix-test-vrr.txt`), aurora probes at line 754 and
     `macsmc-reboot: Handling reboot` registers at line 838, after it.
   - A panic in the GPU probe would therefore have had no restart handler at all. That means the stage-1 watchdog:
     delta about 208 s, pmu `xx30`.
   - A panic after line 838 would have left error stage 30 and given about +35 s.
4. **The same parts booted three minutes later.** be84bb7d has the same kernel, DTB, loader, variables and initramfs.
   It differs only in one appledrm bootarg (VRR opt-in), which acts after probe. It booted with both drivers, and the
   coordinator reports glmark2 on the GPU at 911 FPS with the DCP scanning out.
5. **Why the probe printed "attempt-linux-panic".** Its absolute bands were calibrated at a clean delta of 21-29 s,
   before the 20 s `m5pro-settle` shutdown hook. The hook and the loops' `sync; sleep 5` moved clean boots to about
   50 s, so 55 s fell into the old panic band.
   - Fixed in place, uncommitted: `firstboot-probe.sh` now classifies relative to `CLEAN_BASE` (argument 2 or env,
     default 50 s). It keeps the old bands in a comment and carries today's calibration: clean 48-51 s, counted restart
     55 s, stage-1 watchdog 207-209 s.

**Still open: why the B4 session's restart was counted.**
- That session ran Hyprland on the DCP card. Before the reboot it had the journal dump, the 42 MB scp to `/root` and
  `esp-put` with its 60 s settle, then `sync; sleep 5`.
- REPORT.md's case 1 mechanism: `phra` does not take effect after boot_stage 0, and `apple_wdt` restarts the machine.
  The apple-drm shutdown also runs in `device_shutdown()` after boot_stage 0. This is the first counted restart
  recorded with the settle in place: 0 of 17 before, now 1 of about 13.
- The B4 boot's own journal on the MacBook holds its shutdown messages up to journald's exit (commands below).

## Code reading for a real GPU + DCP race (kept short, since there is no panic to explain)

Nothing static couples the two drivers, and the observed probe order is sequential:
- **simpledrm, aperture and fbdev:** aurora is render-only. It declares only RENDER and SYNCOBJ features, with no
  modeset and no fbdev (`drivers/gpu/drm/asahi/driver.rs:106-110`), so it never touches the aperture. apple-drm removes
  simpledrm (`drivers/gpu/drm/apple/apple_drv.c:1505`) and registers card1 (`:1512`) from its own `module_init`
  (`:1794`). That finishes at journal line 370-382, long before aurora probes (line 754), which takes the freed minor 0.
- **Probe order:** aurora probes after macsmc's RTKit init in both B3 (GPU alone, lines 302 then 673) and the dual
  boot (385 then 754). So it is a deferred probe in a fixed position, after the DCP takeover, not concurrent with it.
- **IOMMU:** the GPU uses its own UAT. The DCP uses `dart_dcp` and `dart_disp0`. No shared DART.
- **Power domains:** the GPU's are `ps_gfx`, `ps_afr` and `ps_gpx` under the GPU's own PMGR node
  (`arch/arm64/boot/dts/apple/t6050-j716s.dts:1000-1077`). The dcp node has no power-domains
  (`t6050-die0.dtsi:830-862`). The DCP's `apple,bw-scratch` (dcpext0 PMC page) and `clk_disp0` have no GPU user.
- **Reserved memory as m1n1 wrote it with both hand-offs** (dual-boot journal lines 10-26), all disjoint:
  - vram 0x10bd15f4000+0x72c4000;
  - os-log 0x1000655c000-0x10006677fff;
  - flash 0x10006000000-0x100060b7fff;
  - gpu-fw-text 0x10001028000-0x100010cbfff;
  - gpu-fw-data 0x10002520000-0x100026a3fff;
  - UAT 0x10bfff20000-0x10bfffabfff.
- **Panic settings:** `PANIC_ON_OOPS` is unset, there is no hung-task panic (`BOOTPARAM_HUNG_TASK_PANIC=0`), and no
  softlockup or hardlockup detector. An oops in a probe worker would not panic, only an SError, an oops in interrupt
  or init context, or an explicit `panic()`. The remaining runtime coupling is the GPU firmware boot (it maps PMGR pages
  0x280414000 etc.) while fbcon flips on the DCP. That cannot be read from code, and one dual boot shows it working.

No concrete bug was found, so no fix payload was built.

## The capture kernel: what it is for

A backup in case a GPU + DCP failure does reproduce. The GPU driver is a module, so the DCP probes alone at boot, the
root mounts, journald flushes, and aurora probes only when started from userspace. Its output then lands in the
persistent journal and in a live `dmesg -w`.

- Branch `j716s-daily-dcp-capture` = `j716s-daily-dcp` bd53915f2ef1 + one commit adding
  `arch/arm64/configs/j716s-capture.config` (`CONFIG_DRM_ASAHI=m`). `scripts/diffconfig` against the daily-dcp config
  prints only `DRM_ASAHI y -> m`. The Kconfig help says "the module will be called aurora"; it has OF aliases, so udev
  would autoload it.
- Release: **7.3.0-gfd123f96ef9d** (capture tip fd123f96ef9d; the daily-dcp kernel is 7.3.0-gbd53915f2ef1). Artefacts
  and SHA256SUMS are in `~/Work/agents/daily-dcp/capture/kbuild/`:

  | File | sha256 |
  |---|---|
  | Image.gz | fadf372df2961f780fb70e25de350c763d0c101ad8e6acd4e680b2365443673d |
  | t6050-j716s-daily-dcp.dtb | c8f1b960…, byte-identical to the daily-dcp in-tree DTB |
  | modules-7.3.0-gfd123f96ef9d.tar.zst | 313b156c5081e66fdee17bfeb7951dd1a7f9e0571b539eca71584be9c090799b |
  | config | 8bc39789…; System.map 4e1bab71… |

- The tarball has 127 modules: the daily's 126 non-built-in targets plus `drivers/gpu/drm/asahi/aurora.ko` (vermagic
  `7.3.0-gfd123f96ef9d`, no module dependencies).
- modpost reports no undefined symbols, and the staged depmod gave no errors. `System.map` has no aurora initcall, so
  the device initcalls go simpledrm, then `appledrm_register`.
- Built by `~/Work/agents/daily-dcp/capture/build-kernel-capture.sh`, a copy of `build-kernel.sh`:
  - container `kdailydcpcap`, `-j8`, the ENFILE retry wrapper kept;
  - worktree and objects on a case-sensitive sparse bundle on the internal disk (`/Volumes/linux-cs-capture`), so
    `/Volumes/linux-cs` keeps its 16 GiB free.
- **One GPU probe per boot.** aurora pins itself with `try_module_get` before the first firmware-visible write and
  stays loaded until reboot (`drivers/gpu/drm/asahi/retain.rs:1-12`). `modprobe -r` and rebind cannot repeat the
  probe. To repeat it, loop boots: boot the capture payload, modprobe, collect, reboot.
- Payloads in `~/Work/agents/daily-dcp/capture/` are the L-test form with only the kernel swapped. The builder, run
  with the original kernel, reproduces L-test 14f93bfc byte for byte:
  - `daily-dcp-capture-test`: `modprobe.blacklist=aurora`. udev does not autoload; an explicit `modprobe aurora`
    ignores the blacklist.
  - `daily-dcp-capture-test-udev`: no blacklist. udev loads aurora at coldplug, possibly before the journal is flushed.

  | Payload | sha256 |
  |---|---|
  | `daily-dcp-capture-test-20261107-28b0d916.bin` | 28b0d916442b8ab41d3f8ccda0da47f2aaa828746fffe954b3e0d9fff70c7cf3 |
  | `daily-dcp-capture-test-udev-20261107-efa38ac9.bin` | efa38ac9fba64fbaf68d193e888eaf53bf7ba52bd57d2140b4cda5d4954beacb |

  - Re-parsed against L-test: m1n1 98906d29, show-notch and variables, DTB and initramfs bytes identical. The
    Image.gz is the capture build's. The bootargs equal L-test's, plus `modprobe.blacklist=aurora` in the first payload.
  - Built by `mk-daily-dcp-capture.py`, files 0600, recipes and SHA256SUMS next to them.
  - Install the modules tarball before the first boot, because the release string is new.
- Order: first re-run L-test (or e03be5ac) as-is; it is expected to boot like be84bb7d. Use the capture payload only
  if a GPU + DCP boot really fails with error stage 30 or a stage-1-watchdog delta.

## Commands (Studio side; `H=root@<macbook>`, `SSHO="-i ~/.ssh/mbp -o IdentitiesOnly=yes -o BatchMode=yes"`)

Before the capture boot:

```sh
REL=7.3.0-gfd123f96ef9d; C=~/Work/agents/daily-dcp/capture
scp $SSHO $C/kbuild/modules-$REL.tar.zst $H:/root/ && ssh $SSHO $H "tar --zstd -xf /root/modules-$REL.tar.zst -C / && depmod $REL && ls /lib/modules/$REL/kernel/drivers/gpu/drm/asahi/"
python3 -I ~/Work/agents/daily-dcp/mk-daily-dcp.py plan $C/daily-dcp-capture-test-*.bin $H   # then esp-put, 60 s settle
```

On the capture boot (blacklist variant):

```sh
# 1. state: right kernel, aurora NOT loaded, the journal persistent and flushed
ssh $SSHO $H 'uname -r; grep -o "modprobe.blacklist=[^ ]*" /proc/cmdline; lsmod | grep -w aurora || echo "aurora not loaded";
  ls -d /var/log/journal/*; systemctl is-active systemd-journal-flush; journalctl --flush; sync;
  for c in /sys/class/drm/card[0-9]; do echo "$c $(basename $(readlink $c/device/driver))"; done'
# 2. in a tmux pane on the Studio, a live copy that survives a panic (ssh output already received stays on disk)
tmux new -d -s cap "ssh $SSHO $H 'dmesg -w' | tee ~/Work/agents/daily-dcp/capture/dmesg-w-\$(date +%H%M%S).txt"
# 3. debug on, probe the GPU once (one probe per boot: aurora pins itself until reboot)
ssh $SSHO $H 'echo 0x1e > /sys/module/drm/parameters/debug
  echo "module aurora +p" > /sys/kernel/debug/dynamic_debug/control 2>/dev/null
  echo "file drivers/gpu/drm/apple/* +p" > /sys/kernel/debug/dynamic_debug/control
  logger -t capture "modprobe aurora begins"; journalctl --sync
  time modprobe aurora; echo "modprobe rc=$?"; sleep 5; journalctl --sync; echo 0 > /sys/module/drm/parameters/debug'
# 4. collect
ssh $SSHO $H 'journalctl -k -b -o short-monotonic --no-pager > /root/cap-k.txt; dmesg > /root/cap-dmesg.txt
  ls /sys/kernel/debug/dri/; for d in /sys/kernel/debug/dri/*/; do echo "== $d $(cat $d/name 2>/dev/null)"; cat $d/clients 2>/dev/null; done > /root/cap-dri.txt
  cat /sys/kernel/debug/dri/*/state > /root/cap-dri-state.txt 2>/dev/null
  for c in /sys/class/drm/card[0-9]; do echo "$c $(basename $(readlink $c/device/driver))"; done >> /root/cap-dri.txt
  grep -cE "BUG:|Oops|WARNING|SError|flip_done timed out|DCP has crashed" /root/cap-dmesg.txt'
scp $SSHO "$H:/root/cap-*.txt" ~/Work/agents/daily-dcp/capture/
```

If the machine resets during `modprobe`, after the fallback boot comes up:

```sh
ssh $SSHO $H 'journalctl --list-boots | tail -4; journalctl -k -b -1 -o short-monotonic --no-pager | tail -150'
```

Why the B4 restart was counted (its last journal lines, shutdown included up to journald's exit):

```sh
ssh $SSHO $H 'journalctl --list-boots | tail -8'      # pick the 7.3.0-gbd53915f2ef1 boot from about 04:17-04:20 UTC
ssh $SSHO $H 'journalctl -b <B4 idx> -o short-monotonic --no-pager | tail -80'
```

Files next to this note (uncommitted): `j716s-capture.config` (the fragment committed on `j716s-daily-dcp-capture`),
`build-kernel-capture.sh`, `mk-daily-dcp-capture.py`. Also changed in place: `contrib/pending/boot-ab/firstboot/firstboot-probe.sh`
(bands relative to `CLEAN_BASE`). A rebuild needs the sparse bundle
`~/Work/agents/daily-dcp/capture-vol/linux-cs-capture.sparsebundle` attached at `/Volumes/linux-cs-capture`.
