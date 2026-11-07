# W2: the ANS guard and the N1 training (2026-11-07)

(Saved by the coordinator from the agent's hand-back.) Result: option (b) built as m1n1 patch 0025 behind
`chosen.m5pro,n1=3` (= `n1=1` + ANS) and `n1=4` (= `n1=2` + ANS; `n1=2` was already 0023's SMC `gP13` release). `n1=1`/`2`
unchanged. m1n1 `build/m1n1-plain-n1-ans.bin` sha256 69730b19..., banner v2.0.0-76-g3e7019df; payload
`w2-n1ans-20261107-2dedddda.bin` = W1 byte-identical from 0x400000 except `n1=3` (`prep/mk-w2.py`; `mk-w2.py 4` builds W2b).
`deploy-W2.sh` accepts either daily (`dcec81ed` or `275d84ec`); `mk-w2.py` keeps W1's bootargs (no wfi_trap flag).

## 1. What "(before)" reads (0023 `storage_check`)
| check | register | J716s |
|---|---|---|
| ANS running | `/arm-io/ans` reg[0]+0x44 (ASC CPU control) bit 4 RUN | 0x419600044: read 0 on W1 -> STOP |
| NVMe boot status | reg[9]+0x1300 == 0xde71ce55 | 0x45dcd1300 |
| NVMe fatal | reg[9]+0x1c (CSTS) bit 1 | |
Nothing was written before the STOP; W1's `n1: port 0:` line is iBoot's own register state.

## 2. Why ANS is stopped in stage-2
The A/B stage-1 (`d52d4dd9` on `459a3af2`, chainloading) runs `nvme_init()`, reads `boot.bin`, then `nvme_shutdown()`
(NVMe shutdown, RTKit sleep, RUN cleared, PMGR reset; firmware stays loaded). Stage-2 is built without chainloading and
never touches NVMe. Linux's nvme-apple (`apple,t6050-nvme-ans2`) sees RUN clear and restarts ANS itself (hence our 10 s
handshake wait, `d27a723f18b9`). Aura's guard assumed J775D where the loader leaves ANS running. No public edimoldovan/m1n1
or Aura branch has T6050 N1 training; Aura's J813 N1 code (`21c3f707e0`, T8142, PR #79) has no storage guard (GP PCIe is
not the storage controller there).

## 3. Is the guard needed with ANS down?
Stages A and S touch shared state: PMGR power-up of APCIE_SYS_GP, APCIE_PHY_SW, APHY_GP_AUS5; AUS5 AON +0x5c; 78 axi2af
tunables; rc+0x04 lane config; shared PHY tunables and Gen5 PHY start; refclk and RC run. Linux never repairs this (the
T6050 nvme node has no power-domains/resets; the driver only writes RUN, handshakes, polls boot status). With ANS down
there is no torn DMA; the risk is persistent misconfiguration found only when Linux restarts ANS ("ANS did not boot" /
timeouts -> root does not mount -> attended power-hold), or, unlikely, a misprogrammed axi2af moving wrong data silently.

## 4. Options
(a) train without the reference when ANS is stopped: smallest, but shared writes in an unmeasured state and failure only
visible in Linux. **(b) stage-2 runs `nvme_init()`, trains with the snapshot, `nvme_shutdown()`:** storage live during the
shared init (what Aura measured), every check meaningful, a real read test before and after, Linux gets today's ANS
state; costs: ANS boots twice, m1n1's RTKit wait made settable (10 s); new risk: m1n1 starting a stopped T6050 ANS never
tried (caught). (c) train in stage-1: rejected (shared by both slots, 1TR to change, no watchdog until hand-over, no
opt-in, image at the size limit).

## 5. 0025 `pcie_t6050_n1_train_ans()`
1. ANS already running -> plain `n1=1`/`2` path. 2. `nvme_init()` with 10 s RTKit wait; fail with RUN clear -> stop,
boot without N1; fail with RUN set -> treat as storage lost (6). 3. read NVMe block 1 (GPT header; signature reported);
read fails -> `nvme_shutdown()`, stop, boot without N1. 4. unchanged 0023 training with the reference taken live.
5. afterwards require: same storage registers, same block bytes, then `nvme_shutdown()` with RUN clear. 6. any failure:
`STOP: storage lost (...)`, 15 s for a panel photo, `wdt_reboot()` (skips NVMe shutdown: a wedged ANS can spin the RTKit
power-state loop; nothing was written) -> iBoot counts the failed boot -> stage-1 boots the daily.
Loop safety: m1n1 hangs -> 150 s watchdog -> daily (unattended). Detectable storage damage now self-heals. Remaining
attended case: storage fine in m1n1 but Linux cannot restart ANS (why W2 stays attended).

## 6. If W2 stops at `link up ... after 500 ms`
Aura's J813 code pulses the N1 reset through SMC `gP13` (0x800000, 50 ms, 0x800001, 50 ms, 100 ms before port reset);
0023's `n1=2`/`4` writes `template|1` and waits 10 ms. Next run W2b (`n1=4`); then the pulse and J813's timings.

## W2 expected lines
Good: `pcie-t6050: ANS stopped (0x...): starting it`, `nvme: initialized`, `storage before: reference`,
`storage after training: NVMe read identical`, `ANS stopped again for Linux`. Bad, self-recovering: `STOP: storage lost`.
Risks: starting a stopped T6050 ANS from m1n1 (clean fail -> boot without N1; half-booted -> reset to daily); RTKit boot
loops without timeout covered by the 150 s watchdog.

## Round 2 (after W2/W2b): patch 0026, W2c and W2d

* W2 proved 0025 (storage path fine, Linux on NVMe). W2b's `function-reset is not an SMC pKW4` was a 0023 bug: the ADT
  descriptor is pKW4 `gP13` template 0x00800000 (the J813 descriptor), but 0023 compared `adt_getprop_copy()`'s return
  (the length on success) with 0. Decoding and comparison: ANALYSIS.md section 7.
* 0026 (`0026-pcie-t6050-pulse-the-N1-reset-through-the-SMC-as-on-.patch`, commit `9b9c8e1d`, author and Signed-off-by
  Rolando, no other trailers): length check fixed; J813 pulse (0x00800000, 50 ms, 0x00800001, 50 ms, 100 ms before the
  port reset); 1 s link-up wait with the SMC release; `n1=5` = J813 port order. `git am` of 0025+0026 on a fresh
  `n1-handoff` gives the w2 tree (`4cd69475`).
* Build (container): `m1n1-plain-n1-smc.bin` sha256 `a4cc59fd94f9abc896a1ea4dd0964bf0710f154290ff957b44f31aefa9127db4`,
  0x400000, banner `v2.0.0-77-g9b9c8e1d`, 0 warnings; n1-train and n1-ans rebuild byte-identical (`d31e5248`,
  `69730b19`). The first 0026 build was 0x410000 (rodata + relocations window overflowed by 8 bytes); two 0025 messages
  were shortened, 0x28 bytes left, and `build.sh` now refuses an image that is not 0x400000.
* Payloads: W2c `w2c-n1smc-20261107-d8bab230.bin` (`n1=4`, `d8bab230...`), W2d `w2d-n1smc-20261107-e46ceca4.bin`
  (`n1=5`, `e46ceca4...`), both W1 byte-identical from 0x400000 except the `n1` line. `prep/mk-w2.py w2c|w2d`;
  `prep/deploy-W2c.sh`, `prep/deploy-W2d.sh` from `gen-deploy-w2.py` (stdout is only "wrote ...", the script lands in
  `prep/`).
* `n1=4` reused (its meaning, ANS + SMC release, is unchanged; it now works). `n1=5` added for the J813 port order, so
  W2c isolates the reset pulse and W2d the order.
* 0x419600048 0x6e -> 0x6d/0x6c: ASC CPU_STATUS run/wait bits of the live ANS core, not a counter; expected and
  correctly non-fatal.
* New risk: m1n1 now talks to the SMC (RTKit wake, two key writes, quiesce) before Linux, untested on T6050 (Aura does
  the same on J813). A hang is bounded by the 150 s watchdog; a macsmc problem in Linux would show as missing battery /
  odd reboots, not a hang. RUN-W2.md asks for the macsmc check.
