# Thunderbolt/USB4 on the J716s: round 2 plan (2026-11-08, prepared on the Studio, nothing booted)

Round 1 (2026-11-08 00:02 UTC, `tb-t0-20261107-ee8f136e`, kernel `7.3.0-g121f7cde7d92`) hung in kernel init:
`swapper/0` blocked in `deferred_probe_initcall` -> `flush_work` for 1000+ s, no watchdog reset, power cycle.
`T0-HANG-ANALYSIS.md` ranks the causes; this round applies the fix it names whatever the cause turns out to be,
and boots a ladder that adds the round 1 device tree back one piece at a time. Everything below is built; the boots
are Rolando's, attended. Tracker: rolotrealanis98/m4-m5-linux#1.

## What changed since round 1

1. **Kernel base.** The daily is now `j716s-video-observe` (`7.3.0-g0933f881d736`, the video/ProRes observe series on
   the DCP recovery daily). Branch `j716s-tb-r2` = that daily + the 18 commits of `j716s-daily-dcp-tb`
   (`patches/daily-stack/0001-0017`, Aurora #946's drivers and T6050 DT, plus the `j716s.config` USB4 lines) + the
   two round 2 DT commits (`patches/round2/`). Cherry-pick conflicts: `t6050-max.dtsi` (the daily's
   `#include "t6050-media.dtsi"` vs the ATC2 block) and `j716s.config` (the video lines vs the USB4 lines), both
   sides kept. Kernel `7.3.0-g<tip>`, config = the daily kernel's `.config` + `config/j716s-usb4.config`
   (USB4, USB4_APPLE_SOC, USB4_CONFIGFS, BLK_DEV_NVME, IGC, R8169, TIGON3 =y; HOTPLUG_PCI_PCIE =y; ATLANTIC stays
   off because the daily has no NET_VENDOR_AQUANTIA, exactly as in the round 1 kernel). Built in the Fedora 43
   container (clang 21, rustc 1.99.1, the daily's bindgen); modules tarball from the daily list.
2. **The DT fix, upstream shape** (`patches/round2/0001`, `0002`): in `t6050-max.dtsi` every node of both routers is
   `status = "disabled"`: acio2, acio2_mbox, the five ATC2 power states (atc2_cio, _cio_pcie, _cio_usb, _cio_auss,
   atc2_pcie), the pcie-tunnel-2 container, and the same for ATC1 (acio1 already was). The J716c enables ATC2's set
   next to its tunables and connector endpoint (its DTB changes only by the `status` words), and the J716s enables
   the right port's set with the two suppliers only a router uses: `ps_auss` (ATC2_CIO_AUSS's second parent, always
   on) and `pinctrl_aop` with only pin 81 (LSTX) exposed, plus the connector graph hpm2 `port@3` <-> acio2 `port@1`
   and the `usb4-2-*` / `atcphy2` aliases for the loader. ATC1's router stays off; ATC0 (the tether) is not
   described. What round 1 booted had: ATC1's five domains live (now off), ATC2's five live (unchanged), acio2 live
   with a disabled pin controller and a disabled `ps_auss` (now both enabled: nothing defers forever), and no
   connector graph (now present: the PD controller finds the router's switch).
3. **Safety.** Every payload is a test payload: `m5.selftest=1` (self-revert without network in 90 s) +
   `watchdog.open_timeout=300` (if userspace never opens `/dev/watchdog0`, the core stops feeding the SoC watchdog
   after 300 s and it bites within 30 s; stage 1 then falls back to the previous `boot.bin`) with the `initramfs-ftab-wdt2`
   opener, battery driver on (attended). Round 1 ran without `watchdog.open_timeout` and the kernel fed the watchdog
   forever; this path has not been exercised on this exact hang yet (first-boot analysis: it covers a hang that
   happens after `apple_wdt` probed, which a deferred-probe hang does).
4. **Loader.** The daily's `m1n1-plain-n1-dt-gpu-dcp-phfix-ave` (pinned). It has no T6050 USB4 tables, so the router
   finds no `apple,tunable-rc` and refuses to probe (`-EINVAL`, "Missing bootloader RC tuning"): a clean failure
   that the ladder wants (it tests the boot, not the router). Its M1-shaped `usb4-N-acio` alias handling copies what
   it can from the ADT and drops the rest; it does not stop the boot. The router's real start (T1+) needs
   `patches/m1n1/0030-0031` (drafts, syntax-checked, never built): out of this round.

## The ladder (`dt/round2/t6050-j716s-tb-ladder.dts`, `tools/mk-tb-ladder.sh`; proof in `logs/round2-dt-proof.txt`)

Cumulative; each rung is one payload, one boot, one `run-tb-ladder.sh` invocation, the daily restored at the end.
The same kernel for all; only the DTB changes. "PASS" = ssh back within ~2 min, the rung's nodes in the state the table
says, no hang, no SError, no new deferred probe other than the expected ones, the daily restored.

| Rung | DTB adds (over the previous rung) | What a PASS proves | What a HANG means |
|---|---|---|---|
| **K0** | nothing enabled: all 28 Thunderbolt nodes present and `disabled`, no graph, no aliases (`gpio-reserved-ranges` on the still-disabled pin controller is the only property change) | the kernel + config delta (USB4 core, the T6050 router, PHY CIO, DART and PCIe-C drivers built in) boots on the daily DT | the kernel or the config, not the device tree: next isolation is USB4_APPLE_SOC=m (module) on the same DT, then the USB4 core itself |
| **D1** | `acio2_mbox` (mailbox@381108000) | apple-mailbox binds an ASC mailbox whose coprocessor is cold without touching it | the router CPU mailbox probe (an SError on a cold wrapper would show as a fault, not a hang) |
| **D2** | the five ATC2 power states + `ps_auss` | the pmgr-pwrstate probes, which power ATC2_CIO on through their own `power-domains` link with the PHY in USB mode (round 1's top candidate), do not hang; `pm_genpd_summary` shows atc2_cio* and auss | the CIO domain power-on with the PHY not in CIO mode, or the PMGR polls: the fix is then to keep ATC2_CIO's children from powering it at probe (a `power-domains`-less description or a driver change), the M1-M3 trees do not have this problem |
| **D3** | `pinctrl_aop` (pin 81 only), `acio2`, `pcie-tunnel-2` (no graph, no aliases) | the router probes and fails cleanly with -EINVAL (no tunables); the AOP pin controller binds; nothing waits | the acio probe path before its tunable check (match data, resources), the pin controller, or fw_devlink around the router's suppliers |
| **T0** | the in-tree DTB: the connector graph and the `usb4-2-*`/`atcphy2` aliases | hpm2 (the right port's PD controller) looks for the router's Thunderbolt switch, waits bounded, carries on; the right port keeps USB and PD; the loader's alias pass is harmless | the Type-C graph (fw_devlink hpm2 <-> acio2) or the PD controller waiting on a switch that never registers |

Order: K0, D1, D2, D3, T0. Do not skip: a hang at a rung is the result (the node set that rung adds), and the next step
is a `-cap` boot of the same rung (payloads built with `--capture`: `initcall_debug dyndbg="func really_probe +p"`,
the probe start lines on the panel; slower boot) to name the probe. Never T1 (a device in the port) before T0 passes.

If K0 hangs: build the same tree with USB4_APPLE_SOC=m (one config line) and boot the K0 DTB again; a pass then puts
the hang in the Apple USB4 driver's init or probe path (`drivers/thunderbolt/apple.c`), a hang again in the core or
the other =y changes (NVMe/IGC/R8169 built in, HOTPLUG_PCI_PCIE). If D2 hangs: the bisect set of the first analysis
(`~/Work/agents/tb-j716s/incident/bisect/`, five domains vs ten, domains without the two children) splits it further.

## Attended steps (Rolando)

Before: the MacBook on the daily, ssh up, **nothing in the right port** (the port on the HDMI/SD side), the tether
cable in the left-back (MagSafe-side) port as always, the display open so the panel can be photographed.

For each rung, in order:
1. `cd ~/Work/agents/tb-r2 && ./run-tb-ladder.sh payloads/tb-r2-<rung>-<date>-<sha8>.bin` (the modules install once).
2. Watch the panel from the reboot. Clean boot: ssh back in 70-110 s, the script collects and restores the daily
   (another reboot), prints `RESULT`. Done with the rung; read `tb-<rung>-<date>/run.txt`.
3. Hang: the panel stops scrolling; the first `INFO: task swapper/0:1 blocked for more than 120 seconds` appears at
   about 2-4 min. **Photograph the panel then** (the lines above the report name the probes in flight). Expected
   next: at ~5-6 min the watchdog bites, the panel goes dark, m1n1 falls back to the daily, ssh returns at ~7-8 min
   and the script says `FELL BACK` with `kind=attempt-apple-wdt-bite` from the first-boot probe. If the panel still
   shows the report past ~8 min, the hang beat the watchdog as in round 1: hold the power button until off, press it
   again, wait for ssh, then `./run-tb-ladder.sh --restore`. Either way the rung's result is "hang"; stop the ladder,
   send the photo and `run.txt`.
4. Only after T0 passes: nothing to plug yet. The next round (T1) needs the loader with the T6050 USB4 tables
   (`patches/m1n1/0030-0031`), and the first device goes into the **right port only** (a USB4/TB SSD enclosure or a
   second dock; never the tether dock), with the port empty at boot and plugged after ssh is up.

Which device, when: none in this round. The right port stays empty through K0-T0 because the T0 kernel can register
the router's Type-C switch once the loader fills the tunables; with the plain loader it cannot, but an empty port
keeps the result independent of that.

## Risk

- A hang needs the power button if the watchdog path does not fire (round 1 showed one way it can be defeated:
  the kernel fed the dog; `watchdog.open_timeout` closes that, untested on this hang). Attended only.
- D2 powers ATC2_CIO (and CIO_PCIE, CIO_USB, CIO_AUSS) with the PHY in USB mode: the T6050 driver says this must
  not happen. The round 1 DT did the same (and ATC1's) and showed no SError on the photographed panel, only the hang;
  a bus fault here would surface as "SError"/"Unhandled fault" on the panel, and the watchdog covers the recovery.
- `pinctrl_aop` enabled for the first time on this board (D3, T0): the AOP block (audio) runs behind it; only pin
  81 is exposed (`gpio-reserved-ranges`), the J716c runs with the same node. Pin reads on reserved pins do not happen.
- `ps_auss` always-on, as the loader leaves it. No power state is ever turned off by this round.
- The PD controller on the right port (hpm2) waits for the router's switch at T0 and then carries on without it
  (bounded by the driver core); if it does not, the right port loses USB until the daily is back. The tether port is
  never described.
- The daily DTB check (`logs/round2-dt-proof.txt`): no display, GPU, audio or media node differs between the daily
  and any rung; K0 adds only disabled nodes.

## What remains after the ladder (not in upstream, not in this round)

- **The router's start (T1-T2):** needs the loader to pass the router, NHI, DART, tunnel and PHY CIO tables from the
  ADT (`patches/m1n1/0030-0031`, drafts on the n1-warm tree; Aurora's aura#103 moves the same way: the register index
  by router generation, `reg 1` for `acio,v2`, the `hi_up` NHI table for every v2 router; "proven on the M2, not
  tested on a T6050"). With the tables the right port can enter CIO mode, the router's M3 boots, the NHI and the
  `thunderbolt 0-0` domain appear, USB3 over the router's tunnel. First plug: a TB SSD enclosure, attended, the
  tunables compared with the J716c's (identical per `logs/adt-vs-j716c-tunables.txt`).
- **PCIe tunnelling:** Aurora-only (`patches/daily-stack/0013-0016`, `apple,t6050-pciec`, the kernel cold-initialises
  the PCIe-C root port, MSI slice 192-223); upstream's series has no PCIe tunnels for any Apple SoC. Carried, inert
  until the router runs (the container is populated by the router after a tunnel is enabled). ATC1's slice 160-191
  is inferred, not measured.
- **DisplayPort tunnelling / DP alt mode:** no. Needs the DCP's external display path (`dcpext0`, `atc2_xbar`, the
  PHY's DP lane, a connector `port@2`); upstream has no DP tunnels; our T6050 DP-in work (`apple-dpin-*`) is
  Aurora's and untested here. `lid-sleep` tests keep TB unplugged: suspend with an active tunnel is unsupported
  upstream (resume into an SError).
- **Upstream v2 contract** (Sven Peter, 2026-09-06): Type-C alt-mode notifiers instead of `thunderbolt-switch`, the
  connector endpoint at `port@2` (ours is `port@3`, Aurora v1-era), a dwc3 `port@1/endpoint@1` link for USB3
  tunnels. We keep Aurora's stack (it is that series plus the T6050 layer); when Aurora rebases, drop
  `thunderbolt-switch`, move the endpoint, add the dwc3 link. The per-board enable shape of this round is already
  the upstream one.
- **Aurora PRs checked (2026-11-08):** #946 head `31785b39df6b` = what `patches/daily-stack` carries (18 commits; the
  three PHY commits not in our stack, "carry on when the PIPE lock is not acknowledged", "park the PIPE from a dummy
  producer on any clock", "restart the PHY firmware on its original data", are already in the daily). #939 head
  `c24e75ca9d99` and #940 head `c0e42a1852a6` match our local refs; #480 (DjDeveloperr's combo PHY,
  `2aaccf67c6c3`) is in the daily as `afb6b329b252`. Nothing newer than what we carry; the only news is the aura#103
  comment above.

## Files

- Repo: `patches/round2/0001-0002` (the DT fix), `dt/round2/t6050-j716s-tb-ladder.dts`, `tools/mk-tb-ladder.sh`,
  `logs/round2-dt-proof.txt`, `logs/dtbs_check-r2-t0-vs-daily.txt` (the T0 DTB adds only the known lines: the
  t6050 pmgr-pwrstate and pciec compatibles, `apple,msi-vector-base`'s type, the loader-filled DROM).
- Studio, `~/Work/agents/tb-r2/`: `build-kernel-tb-r2.sh` (+ `kbuild/`), `mk-tb-ladder-test.py` (+ `payloads/`),
  `run-tb-ladder.sh`, `dtproof-r2.sh`, `dt/` (the five DTBs). Worktree `/Volumes/tb-daily/wt-tb`, branch
  `j716s-tb-r2` (first made on `/Volumes/linux-cs-gpurec` as planned; that volume went unreadable under four
  concurrent builds and was left alone).

## Payloads (built 2026-11-08, `~/Work/agents/tb-r2/payloads/`, sha256 of the `.bin`)

Kernel `7.3.0-ge9876a4d2646` (branch `j716s-tb-r2` tip `e9876a4d2646`, Image.gz `e006b8a6...`), loader
`m1n1-plain-n1-dt-gpu-dcp-phfix-ave` (`fb29185c`), initramfs `initramfs-ftab-wdt2` (`abb47165`), modules
`modules-7.3.0-ge9876a4d2646.tar.zst` (`64470af0...`, installed once by the runner). DTBs from `tools/mk-tb-ladder.sh`:
K0 `fc922eb3`, D1 `c8b869c4`, D2 `82ba799b`, D3 `e804db9d`, T0 `c438d2ef` (= the container-built in-tree DTB); the
daily DTB is `4a8cfe25`.

| Rung | payload | sha256 | capture variant (`-cap`) | sha256 |
|---|---|---|---|---|
| K0 | `tb-r2-k0-20261108-df5e0efb.bin` | `df5e0efbeec40437605905b00e88ed4b323ad286df044ef14070e869b89eedc8` | `tb-r2-k0-cap-20261108-a666aa2c.bin` | `a666aa2c53dec2721bc3c3971ab4abd21906f053debd21deab83446e809c4bc7` |
| D1 | `tb-r2-d1-20261108-488d6a41.bin` | `488d6a41da783e7f30d1b6fb2120b4c3850a800350ac2cf82905d98eb33e1a61` | `tb-r2-d1-cap-20261108-02c1c2c3.bin` | `02c1c2c3b1f4203fa273415292c5981d1a29e177da924d795de368f51cd3a6d1` |
| D2 | `tb-r2-d2-20261108-34de9aa1.bin` | `34de9aa171aeefeebedb1e254173cb756382e7e4a51222088a9c3700f260bc59` | `tb-r2-d2-cap-20261108-1d28e7ae.bin` | `1d28e7aefe00a499f7a4652ae481fee88f15f2a8b46272f8a35cb2e668de1bb4` |
| D3 | `tb-r2-d3-20261108-269e7c1e.bin` | `269e7c1e2f128b46283ca167cd549893efc6ef7f22f751b207485690214314da` | `tb-r2-d3-cap-20261108-73a574cd.bin` | `73a574cd9319d4fcedad5bfdbd57133b254476b74cdfa27a8dfb8a518c7571dd` |
| T0 | `tb-r2-t0-20261108-8a442eac.bin` | `8a442eac4a7a81fc3242eb20ac31d18f2c3907ffb2ce41c61f47d6b518ce17a2` | `tb-r2-t0-cap-20261108-f91cf910.bin` | `f91cf9105275fddcbe1b69b284a1c6a2c0e8a059e5e7ddf0dd54cd14847fdd89` |

Bootargs: the daily's + `m5.selftest=1 watchdog.open_timeout=300 ... printk.time=1`; the `-cap` variants add
`initcall_debug dyndbg="func really_probe +p"`. Each `.bin` has its `.recipe.txt`, `.rel` and `.rung` next to it.
