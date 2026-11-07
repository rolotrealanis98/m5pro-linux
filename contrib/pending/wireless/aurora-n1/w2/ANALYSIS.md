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

## 7. W2 / W2b results and patch 0026 (W2c, W2d)

**Results.** W2 (n1=3, twice) proved 0025: ANS started from stopped (`0x0`), block 1 read, storage unchanged through A
and S, re-read identical, ANS stopped again, Linux on NVMe normally, no revert. The port then stopped at
`STOP: link up: 0x410028208 = 0xab001208 after 500 ms` (final `rc ctl 0x1 stat 0x1, port status 0xd, ltssm 0x1`: RC
running, port ready, LTSSM started, no link; what a held-in-reset endpoint looks like). W2b (n1=4) stopped before B with
`function-reset is not an SMC pKW4`.

**The J716s descriptors** (`adt-runtime-j716s.bin`, `/arm-io/apcie0/pci-bridge0`; each property is phandle, function
name, two args, little-endian; the SMC PMU nub is phandle 654, gpio0 is 459):

| property | raw bytes | decoded |
|---|---|---|
| `function-reset` | `8e 02 00 00 34 57 4b 70 33 31 50 67 00 00 80 00` | pKW4, key `gP13` (0x67503133), template 0x00800000 |
| `function-warm_reset` | `8e 02 00 00 34 57 4b 70 69 6c 70 62 00 00 00 01` | pKW4, key `bpli`, template 0x01000000 (not used) |
| `function-perst` | `cb 01 00 00 4f 49 50 47 50 00 00 00 00 00 00 00` | GPIO, pin 80, flags 0 (what 0023 drives) |
| `function-clkreq` | GPIO pin 76, flags 2 | not touched (the endpoint drives it) |
| `function-pcie_port_control` | `PrtC` -> apcie0 (phandle 141), arg 142 | apcie0's own port control |
| `function-dart_*` | `Fact`/`Self`/`SReq`/`SRel` -> dart-apcie0 (148) | DART control, not resets |

`centauri-control`, `-alpha`, `-beta` carry no reset or power functions (only `pci-skip-rematch-reset`). pci-bridge1
(SD reader) has perst GPIO 81, clkreq GPIO 77 and an SMC pKW8 `sd_pwr_en`.

So the J716s N1 reset *is* an SMC pKW4 "gP13" with template 0x00800000: the same descriptor as Aura's J813
(`SMC_KEY_GP13 0x67503133`, `N1_RESET_LO 0x800000`, written as `0x800000 | level`). 0023's check was a bug:
`adt_getprop_copy()` (Rust, `rust/src/adt.rs`) returns the copied length on success, and 0023 compared it with 0
(the PERST# lookup three lines above correctly tests `< 0`). The SMC was never written on W2b. edimoldovan/m1n1
still has no J714c N1 code on any public branch (rechecked: `t6050-aurora`, `t6050-wip`, `t6050-boot`,
`integration/aurora`); Aura `main` has only the J813 file (no change since `21c3f707e0`).

**0026** (`9b9c8e1d` on 0025, branch `n1-smc`):
* compares `adt_getprop_copy()` with the property size, so `gP13`/0x00800000 is taken;
* `n1_smc_release()` pulses as J813: `smc_init()` (10 s RTKit wait), write `template | 0`, 50 ms, `template | 1`,
  50 ms, `smc_shutdown()`, 100 ms, then the port reset table; a non-zero SMC result stops the training;
* link-up wait 1 s whenever the SMC release runs (`n1=2`, `4`, `5`); `n1=1`/`3` keep 500 ms and the identical sequence;
* `n1=5` = `n1=4` in J813's port order: config tunables, APPCLK; lane refclk (clk0/clk1 req/ack, bit 4 clear, bits 9
  and 10, t-refclk-to-perst); internal reset bit 0 and PERST# release; then the PIPE reset wait (`0xa8` bit 0, 100 ms),
  bit 16 clear, port ready, APPCLK bit 8, idle; then the DBI writes; LTSSM; 1 s. Bit 16 clear and APPCLK bit 8 stay
  because Linux's adoption requires them (J813 hands Linux a generic ECAM host and skips both).
* Size: the plain image must stay 0x400000. rodata and the relocations share one 128 KiB window, which 0026 first
  overflowed by 8 bytes (image 0x410000, refused by mk-daily). Two 0025 messages were shortened to fit; 0x28 bytes are
  left. `build.sh` now fails if any image is not 0x400000.

Run order: **W2c = `n1=4` on the 0026 m1n1** (the one missing step, the reset pulse, with 0023's port order that reached
the LTSSM on W2); **W2d = `n1=5`** only if W2c stops at link up. Each changes one thing.

**The allowed change at 0x419600048.** That is ANS reg[0] + 0x48, the ASC `CPU_STATUS` register (m1n1
`proxyclient/m1n1/hw/asc.py`: bit 0 RUNNING, bit 1 STOPPED, bit 2 IRQ_NOT_PEND, bit 3 FIQ_NOT_PEND, bit 5 IDLE; the
names are partly guesses). 0x6e = bits 1,2,3,5,6; 0x6d = bits 0,2,3,5,6; 0x6c = bits 2,3,5,6. Only bits 0-1 move: the
ANS core's run/wait state at the instant of the read. Not a counter (W2b ran shorter than W2 and moved "further").
Expected for a live coprocessor, and 0023 already puts it in the non-fatal set; the fatal ones (PS targets, SART,
`CC`, `BOOT_STATUS`, RUN) did not move.
