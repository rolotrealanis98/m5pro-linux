# RUN-E1: GPU ID registers and the clean M5 Pro refusal on the J716s

Step E1 of the GPU plan (`contrib/pending/gpu/hwdata/ANALYSIS.md` section 4). E0 (2026-11-07 12:41 UTC) said
**GO E1** (PMP gates on, PMP SRAM not cold, GFX `0x0f040300` = off): E1 does not touch the PMP.

What E1 does: m1n1 0026, asked by `chosen.m5pro,gpu=1`, hands the GPU description to Linux (six reserved regions,
mailbox windows, GPU and PMGR group-3 nodes `okay`). Linux powers AFR and GFX on (PMGR group 3, `apple,always-on`),
Aurora's driver (#1012, unmodified) maps `sgx`, reads the ID and core-mask registers, picks #1012's own M5 Pro
config and refuses: "M5 Pro bare-metal GPU tables not yet available". No coprocessor is started, no firmware or
InitData is written, no mailbox driver binds, no UAT is touched.

## 0. Ingredients

| Part | File | sha256 |
|---|---|---|
| m1n1 | `~/Work/agents/gpu-e1/build/m1n1-plain-gpu.bin` (f7555558 = daily m1n1 `28b26ebc` + 0026, `v2.0.0-73-g965b7d86`) | `a23a3e96ec1a4e05091add9df09f8dab270bc02d62be88aa6bdcb2cfe0ce497b` |
| kernel | `~/Work/agents/gpu-e1/kbuild/Image.gz`, `7.3.0-gc0838b776f2b` (branch `j716s-series-gpu`) | `744216550510f5c03b18587bba06cc643586089f12ab72f51d041c3e6bca77e3` |
| DTB | `~/Work/agents/gpu-e1/kbuild/t6050-j716s-gpu.dtb` (= daily DTB `594f2a9f` + the disabled GPU nodes + `gpu` alias) | `0d19b701128583d54beab2c4c4c0579f3fd1d8a4bb18259c2db1c821177ff36f` |
| initramfs | mk-daily.py's pinned `selftest` | `1f61a850fb49764126d7a79e9f8adce5508cd6109b302e1441989bb89cd7903b` |
| bootargs | mk-daily.py BASE + `m5.selftest=1`, battery on (`--battery`) | |

Payloads (`~/Work/agents/gpu-e1/payloads/`, built by `python3 -I ~/Work/agents/gpu-e1/mk-e1.py`, which runs
`mk-daily.py --label e1base --battery --kernel <Image.gz> --dtb <dtb> --m1n1 <m1n1-plain-gpu.bin>` and then inserts
the m1n1 variable line after the notch line; the two differ by that one line only):

| Run | Payload | sha256 | m1n1 variable |
|---|---|---|---|
| E1a (control) | `e1a-ctl-20261107-296e21f7.bin` | `296e21f770d4fbe723c8e46575a676c075452da24d6dd6bfd9041e2b31724ad7` | none: every GPU node stays disabled |
| **E1b (test)** | `e1b-gpu-20261107-b26e203c.bin` | `b26e203c3ea30c50bd28eec2064c81296ece018b1b26f8b4dbb9f20c53cb6817` | `chosen.m5pro,gpu=1` |

E1a is the same kernel, DTB and m1n1 without the variable: it shows the Rust kernel (`RUST=y`, `DRM_ASAHI=y`, config
diff against the daily = only the Rust/GPU symbols, `kbuild/diffconfig-vs-series.txt`) boots like the daily before
anything GPU-related is switched on. Run it first; it can run unattended through the loop. E1b: attended preferred
(film the panel from power-on), unattended is acceptable (section 6).

```
export HOST=root@<macbook-ip>                       # Ethernet adapter attached (the self-test needs it)
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes)
T=~/Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools; E=~/Work/agents/gpu-e1; P=$E/payloads
mkdir -p $E/logs
```

## 1. Precheck (on the daily)

```
ssh "${SSHO[@]}" $HOST 'uname -r; cat /proc/cmdline; cd /boot/m1n1 && sha256sum boot.bin* | cut -c1-8,65-; ls boot.bin* | wc -l; df -Pm /boot | tail -1; ls /boot/r1-logs | grep -c selftest'
```
Need: running `boot.bin` = the WFI daily `dcec81ed` (no `m5.selftest=1` in the cmdline), at most 4 payloads,
at least 72 MB free, no `boot.bin.failed` left in `r1-logs/selftest-*` (copy the logs to the Studio, then delete it).

## 2. E1a (control)

```
python3 -I $T/mk-daily.py --deploy-plan --payload $P/e1a-ctl-20261107-296e21f7.bin --host $HOST > $E/logs/deploy-e1a.sh
less $E/logs/deploy-e1a.sh    # then run its steps 0-3 one by one, reading each output
```
The plan copies to `boot.bin.new`, checks the sha256, makes `boot.bin.prev` = the running daily (`dcec81ed`), moves
the payload into `boot.bin` and reboots. Wait 3 minutes, then:
```
ssh "${SSHO[@]}" $HOST 'bash -s' < $E/e1-readback.sh | tee $E/logs/e1a-readback.txt | tail -3
```
Pass: `VERDICT: CONTROL (no gpu var): gpu node disabled = as designed`, `network: up`, `bad lines: 0`, and
`journalctl -t m5-selftest` shows "network OK". Any other result: STOP, E1b is pointless until E1a boots like the daily
(send `e1a-readback.txt` and `/boot/r1-logs/e1-*/`).

## 3. E1b (the test)

From the E1a boot (a test payload, so the plan keeps `boot.bin.prev` = `dcec81ed`):
```
python3 -I $T/mk-daily.py --deploy-plan --payload $P/e1b-gpu-20261107-b26e203c.bin --host $HOST > $E/logs/deploy-e1b.sh
```
Run steps 0-3 the same way (step 2 must print "running payload is a test (m5.selftest=1): boot.bin.prev stays as is";
`boot.bin.prev` must hash to `dcec81ed`). Reboot, film the panel, wait 3 minutes:
```
ssh "${SSHO[@]}" $HOST 'bash -s' < $E/e1-readback.sh | tee $E/logs/e1b-readback.txt | tail -3
scp "${SSHO[@]}" -r "$HOST:/boot/r1-logs/e1-*" $E/logs/
```

## 4. Pass lines (E1b)

m1n1 (panel film, and `m1n1-gpu-lines.txt` from the phram log, which the E1 kernel has built in). Values are the
41.2-capture ones; on the 60.65 stub fw-data is expected at `0x10002520000` (the macOS 27.3 scan moved the DATA
segments by 0x8000), fw-text's base may move too. **Sizes must be 0xa4000 and 0x184000.**

| # | line | meaning |
|---|---|---|
| 1 | `FDT: m5pro,gpu = '1'`, `FDT: GPU: T6050: chosen.m5pro,gpu=1: GPU hand-off` | variable read |
| 2 | `ttbs 0x10bfffa8000..0x10bfffac000 (0x4000)`, `pagetables 0x10bfff28000.. (0x80000)`, `handoff 0x10bfff20000.. (0x4000)`, `l2-pagetables 0x10bfff24000.. (0x4000)` | UAT regions from sgx |
| 3 | `fw-text 0x10000ff0000..0x10001094000 (0xa4000)`, `fw-data 0x10002520000..0x100026a4000 (0x184000)`, each `outside Linux RAM` | segment-ranges contiguous, DATA bases agree with sgx |
| 4 | `sgx 0x2300000000+0x3fdc000`, `mailbox GFX: wrapper 0x2302600000, iop-vbar 0x2302050000`, `mailbox GFX1: wrapper 0x2302e00000, iop-vbar 0x2302850000` | windows from the ADT |
| 5 | `PS gpx 0x2300e80000 = 0x1f0003ff` (or similar, on), `PS afr ... = 0x0f040300`, `PS cs ... = 0x0f000300`, `PS gfx 0x2300e80110 = 0x0f040300` | E0's values, read once |
| 6 | `FDT: GPU: T6050: regions, mailboxes, GPU and PMGR nodes okay` | hand-off done |

Kernel (`e1b-readback.txt`, `gpu-lines.txt`, `dmesg.txt`):

| # | line | meaning |
|---|---|---|
| 7 | six `OF: reserved mem: 0x...  nomap non-reusable {uat-ttbs,uat-pagetables,uat-handoff,uat-l2-pagetables,gpu-fw-text,gpu-fw-data}` (656 KiB fw-text, 1552 KiB fw-data) | regions reserved |
| 8 | `... power-controller@100: always-on domain afr is off at boot, turning it on`, the same for `gfx` (`@110`); no `cannot read power state`, no `pm_genpd_init failed` | PMGR group 3 powered (the only new register writes of E1) |
| 9 | `aurora 2300000000.gpu: Probing...` about 10-12 s after boot (see note) | driver bound |
| 10 | **`aurora 2300000000.gpu: GPU ID registers: 0xb031100 ...`** (six values) | **ID read: family 0xb, variant 3, revision 0x11 = B1** |
| 11 | `Core masks: [ 0x3ff, 0x3ff, ... ]` (multi-line) | 2 x 10 cores |
| 12 | **`aurora 2300000000.gpu: M5 Pro bare-metal GPU tables not yet available`** | **the clean refusal** |
| 13 | no SError, Oops, panic, RCU stall, DART fault (`bad lines: 0`); `network: up`; m5-selftest "network OK" | the rest of the system unaffected |

Readback verdict: **`VERDICT: PASS E1: ID 0xb031100 ..., clean refusal`** with no `network DOWN`. Also record
`pm_genpd_summary` (gfx/afr on, cs off) and that `2302600000.mailbox` / `2302e00000.mailbox` exist with no driver.

Note on timing: the mailbox nodes are `okay` with a placeholder compatible no driver binds, so fw_devlink holds the
GPU probe until the deferred-probe timeout (10 s after late init) relaxes the link. Rows 9-12 therefore appear late,
not near the other drivers. If they never appear: `devices_deferred.txt` names the supplier it waits for.

## 5. Stop lines

* m1n1 `FDT: GPU: T6050: STOP: check failed, GPU nodes stay disabled` with the preceding reason (fw-text/fw-data not
  contiguous, a DATA base differing from sgx, a PMGR or mailbox address differing from the ADT, a misaligned region):
  safe, nothing was enabled, Linux boots like E1a. Send the line; the fix is in m1n1 (or the DT) before E1b again.
  `could not update the DT` is the same class.
* `No M5 configuration for GPU variant 0x.. with N dies`: the ID read worked but the part is not variant 3 / 1 die.
  Not dangerous; send the `GPU ID registers` line (it answers UNKNOWN-1 differently than expected).
* `Invalid core counts (0 x 0)` or `GPU ID registers: 0x0 ...` / `0xffffffff ...`: sgx did not answer as powered.
  Do not repeat; check the PS lines (row 8, `pm_genpd_summary`).
* `Unknown GPU revision`, `Leftover core mask`: ID read worked, decoding differs. Send the line.
* `SError`, `Unhandled fault`, `Internal error`, `Kernel panic`, `rcu: ... stall`, `blocked for more than`, any DART
  fault, or a hang after the `afr`/`gfx` power-on lines: **STOP, do not rerun E1b.** The machine recovers by itself
  (section 6); bring back `/boot/r1-logs/selftest-*` and the panel film. The suspect is the PMGR group-3 power-on
  or the first sgx read with GFX on; the next step would split them (pmgr node on, GPU node off).
* `network DOWN` / a self-revert (`boot.bin` back at `dcec81ed` after reboot): STOP, collect `selftest-*`.

## 6. After the run, and why the loop is safe

After a pass: copy the logs, then put the daily back as `boot.bin` (a test that reached the network stays as
`boot.bin`):
```
ssh "${SSHO[@]}" $HOST 'cd /boot/m1n1 && [ "$(sha256sum boot.bin.prev | cut -c1-8)" = dcec81ed ] && cp boot.bin.prev boot.bin && sync && sha256sum boot.bin | cut -c1-8'
```
Prune any `boot.bin.failed`; at most four payloads at rest (ESP-POLICY.md).

Loop safety:
* **prev is the WFI daily `dcec81ed`, without `m5.selftest`:** every recovery path lands on a payload known to
  reach the network, and a revert can never copy a self-testing payload onto itself (no reboot loop).
* **Hang or panic before the root mounts** (m1n1, the PMGR power-on, the first sgx read): the A/B stage-1 has armed
  the SoC watchdog (150 s); nobody feeds it, the SoC resets, iBoot counts the failed boot, stage-1 boots
  `boot.bin.prev` (`fallback-after-failure`, as on 2026-11-07 after AUDIO-B2). A plain reboot afterwards returns to the
  primary slot. m1n1 0026 itself cannot stop a boot: it never bails, writes no register, and reads only the four PS
  words that m1n1's `pmgr_init()` already reads on every boot.
* **Late failure** (the GPU probe runs about 10 s after late init, when the kernel may already feed the watchdog): a
  panic stops the feeding (watchdog reset as above); a stuck CPU with the rest alive shows as an RCU stall (stop line)
  and, if the network is gone, the self-test reverts 90 s after `network-online` (copies `boot.bin.prev` over
  `boot.bin`, reboots). Not covered automatically: a root that never mounts with the watchdog still fed; the panel
  shows it, and holding power 10 s gives the stage-1 fallback on the next boot (as in RUN-W2), or macOS
  `r1-deploy.sh restore prev`.
* **No RAM corruption risk at E1:** nothing can DMA. The GPU's coprocessors stay stopped (iBoot leaves them loaded,
  not started; no mailbox driver binds, so no CPU_RUN write; the driver refuses before `Gpu::new`, so no UAT, no
  firmware data, no InitData). The GPU's own DMA starts only at E3 (ASC start through the mailboxes, UAT tables in
  `pagetables`). All six regions are `no-map` and lie outside the RAM Linux gets (fw-text/fw-data below `phys_base`,
  the UAT regions above its end), so even the firmware images in them are not touched by Linux. The PMP is not touched.
* **Nothing persists:** PMGR state resets with the SoC; nothing is written to NVMe beyond a normal boot, nor to NVRAM or
  the SMC. The only lasting effect of a pass is GFX/AFR left on for the rest of that boot (`apple,always-on`).
