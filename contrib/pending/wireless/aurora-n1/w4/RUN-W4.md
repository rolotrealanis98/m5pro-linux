# RUN-W4: restart with the N1 trained and in use (kernel shutdown park + m1n1 warm entry)

**Attended: Rolando at the machine, panel filmed from the moment `systemctl reboot` is typed until the login prompt of
the next boot** (the shutdown lines of the old kernel and the m1n1 lines of the new boot both scroll by on the panel; there
is no persistent kernel log across a restart).

## 0. The failure and what W4 changes

DAILY-WIFI promotion (RESULTS.md, 2026-11-07 14:04 UTC): `systemctl reboot` from the DAILY-WIFI-T1 boot (N1 trained,
wlan0 used) came back on `boot.bin.prev` as `fallback-after-failure`, PMU count 1. Nobody saw the panel, so where it stopped
is not known. A fallback with PMU count 1 means the boot after the restart command did not end in a clean
`macsmc-reboot` and something reset the SoC (the stage-1 watchdog, armed for 150 s at hand-over and fed by Linux's
`apple_wdt`). That fits three places, and W4 covers each:

| where it can stop | why it is plausible | W4 |
|---|---|---|
| A. the old kernel's `device_shutdown()` (before the SoC reset) | J714c, same symptom: `initcall_debug` showed the CPU stall in `apple_centauri ...: shutdown`; nothing parks the adopted port; `macsmc-reboot` clears iBoot's boot stage only *after* `device_shutdown()` (sys-off RESTART_PREPARE), so a hang there counts as a failed boot | kernel 0001: `pcie-apple` shutdown parks each adopted port (decoding off, PME_Turn_Off and L2, PERST# asserted, port and lane clocks off; bounded 500 ms waits) and strips ASPM from adopted root ports; 0002: `centauri` leaves an N1 that never booted alone at remove/shutdown |
| B. the new boot's m1n1 | the SoC reset does not reset the N1: it keeps running its firmware with gP13 released; m1n1 then trained a port whose partner is warm. The only unbounded waits in the n1=4 path were the SMC client's (`smc_cmd`) and RTKit's boot loops | m1n1 0027: prints the entry state and what gP13 reads; a released gP13 gets a 250 ms reset instead of 50 ms; a live port is parked first (STOP if the link does not drop within 100 ms); SMC replies bounded to 2 s (`SMC: no reply`) |
| C. the new boot's kernel | if the 50 ms pulse did not reset the N1, 0026 accepted it as 106b:1901 (firmware personality); Linux then adopts a running N1 that still believes in its old host session (`phase0: -16` at best, DMA into unmapped IOVAs and a fault storm at worst) | 0027: with the SMC release the endpoint must answer 106b:1900 (ROM) or the training stops and the port stays disabled: Linux boots without the N1 instead |

What each m1n1 step does to a warm N1 (the SoC side of port 0 is cold after any SoC reset: W0/W1 read
`linksts 0xc300220c ltssm 0x0` from iBoot):
- `storage before` and the ANS start (0025): ANS, its NVMe block, SART and the APCIE_ST*/ANS PS registers only. Nothing on
  GP port 0.
- stages A and S: the GP power closure and shared PHY, as on a cold boot (the SoC side is cold); PERST# is still asserted
  (iBoot's pad state), so the N1 sees its link held in reset.
- SMC gP13 pulse (0026): template | 0, then | 1. On a warm N1 this is the only thing that returns it to the ROM; 0027 makes
  the hold 250 ms when gP13 read released, and prints the read value so the next run shows the warm state directly.
- `port 0 link` (stages B-E, F): with the N1 back in the ROM, the same as a cold boot. Without a working reset the N1
  linked as 106b:1901 (accepted by 0026, refused by 0027).
- Endpoint config reads happen only after `port ready` and `link up`; every m1n1 poll is bounded. A config read that never
  completes is a hardware stall (the J714c's kernel-side hang); m1n1 does not issue one before the link is up.

## 1. Ingredients

| part | W4 | DAILY-WIFI-T1 (the failing boot) |
|---|---|---|
| m1n1 | `w4/build/m1n1-plain-n1-warm.bin` `4c202e9d...` (0020-0023, 0025, 0026, **0027**), `v2.0.0-78-g2ce0f78e` | `m1n1-plain-n1-smc.bin` `a4cc59fd...` |
| kernel | `/Volumes/linux-cs/wt-n1shut-out/arch/arm64/boot/Image.gz` `005c6ea9...`, `7.3.0-gff289b9ce8ec` = `f080637018df` + linux 0001 + 0002, same `.config` | `wt-betizzel-out` `ec0873a2...`, `7.3.0-gf080637018df` |
| chosen lines, DTB, initramfs (stitched FTAB) | DAILY-WIFI-T1's bytes (the booted file is `90f30233`: mk-daily's `5e188412` plus the inserted `n1=4` line): `n1=4`, `pcie_aspm=off`, selftest on, battery | same |

Payloads (`w4/private/`, 0700; the initramfs carries the FTAB):
- `w4-n1warm-20261107-a9911c95.bin` (sha256 `a9911c959767f08a5a6ebb141d263dab6bc79af3b8ec7a755cf2a6289ce70606`), deploy `w4/private/deploy-W4.sh`
- `w4d-n1warm-20261107-f723c9fe.bin` (sha256 `f723c9fe14273e36ac38a85ccfa37b960f4ee71680253ee84635981be2e33043`) = W4 + `initcall_debug` (each device's shutdown is printed), deploy `deploy-W4D.sh`

Rebuild: `w4/build.sh` (m1n1, container; also rebuilds n1-smc byte-identical as the recipe check); kernel: worktree
`/Volumes/linux-cs/wt-n1shut` (branch `j716s-n1shut`), `.config` copied from `wt-betizzel-out`, then
`make LLVM=1 ARCH=arm64 O=/Volumes/linux-cs/wt-n1shut-out HOSTCFLAGS=-I$HOME/Work/omarchy-m5/scripts/host-shim
HOSTCFLAGS_file2alias.o=-D_POSIX_C_SOURCE=200809L -j12 Image.gz` with the SERIES.md PATH; payload:
`python3 -I w4/mk-w4.py [w4d] [--daily <sha256> ...]` (asserts every input digest; `--daily` adds a known-good daily
to the deploy guard, which knows the lid daily `534ca146`, `dcec81ed` and `275d84ec`).
`gen-deploy-w2.py` prints only "wrote deploy-<TAG>.sh" and writes the script next to itself; mk-w4.py runs a scratch copy
of it inside `w4/private/`, so the deploy scripts land there.

```
export HOST=root@<macbook-ip>                       # Ethernet adapter attached
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes)
P=~/Work/agents/n1-wifi/prep; W=~/Work/agents/n1-wifi/w4/private; L=~/Work/agents/n1-wifi/logs; TAG=w4-$(date +%Y%m%d-%H%M)
```

## 2. Procedure

**Start only after the coordinator's "MacBook is yours"** (the crash-log loop test owns the MacBook until then).


1. **Precheck** (RUN-W2 step 1): at most 4 payloads, >= 94 MB free, boot.bin or prev a known daily, no `boot.bin.failed`.
   The root already has the DAILY-WIFI-T1 Wi-Fi setup (wpa_supplicant@wlan0, the wlan0 `.network`).
2. **Deploy** `HOST=$HOST bash $W/deploy-W4.sh | tee $L/$TAG-deploy.txt`; must end `boot.bin = <W4 payload>`, prev = the
   daily. Any `ABORT`: STOP.
3. **Cold boot into W4**: `systemctl poweroff`, wait 15 s, press power. Film. Expect DAILY-WIFI-T1's lines plus the new
   m1n1 ones: `pcie-t6050: entry: linksts 0xc300220c ltssm 0x0 perst 0x...`, `pcie-t6050: gP13 reads 0x...` (record the
   cold value), `SMC key gP13 <- 0x00800000: 0`, `<- 0x00800001: 0`, `endpoint 01:00.0 is 0x1900106b`, `port 0 up`.
   Read back (`$P/READBACK.sh`, VERDICT TEST, `n1 chosen var: 4`); `wpa_cli -i wlan0 status` until `COMPLETED`,
   `ping -c3 -I wlan0 1.1.1.1`.
4. **The test: restart from the live N1.** With wlan0 associated and a ping running over wlan0:
   `ssh ... 'sync; systemctl reboot'`. Film the panel through the shutdown. Expected on the way down (W4 prints them at
   the normal log level): `pcie-apple 1cb0000000.pcie: port 0 held for the restart`. On the way up: `gP13 reads
   0x00800001: N1 released (warm)` (this is the warm state the old m1n1 never handled), the pulse, `endpoint ... 0x1900106b`,
   then the kernel as in step 3.
   Wait as RUN-W2 step 3 (8 min). Read back: VERDICT TEST, `boot-slot: primary`, PMU scratchpad count 0, `n1 chosen var: 4`.
5. **PASS = step 4 three times in a row** (each from a boot with wlan0 associated), each back on the primary slot with
   wlan0 associated and hci0 present, plus one `systemctl poweroff` / power-on cycle. Then the Wi-Fi stack can be retried as
   the daily (same ingredients, `--daily`), with this kernel's two patches added to the series.

## 3. Results and what to do

| seen | meaning | next |
|---|---|---|
| step 4 passes x3 | fixed (A, B or C; the film says which lines appeared) | promote |
| back on the daily (`fallback-after-failure`, PMU count 1), film shows the old kernel stopping after `held for the restart` or before it | still A: some device's shutdown stalls | run **W4D** (deploy-W4D.sh, steps 3-4): `initcall_debug` prints `... shutdown` per device; the last line names the device. Send it |
| film shows m1n1 lines and a `pcie-t6050: STOP: ...` on the warm boot (e.g. `endpoint 01:00.0 is 0x1901106b, not the N1 in its ROM`, `link down after PERST#`, `SMC: no reply`) | B/C caught: the boot continues without the N1 (no `wlan0`), no fallback | send the lines; the N1 reset needs more than the gP13 pulse (longer hold, or `bpli` warm reset from the ADT) |
| m1n1 frozen on a line > 150 s | an unbounded wait left (RTKit boot loop) | the watchdog falls back by itself; send the last line |
| kernel up, root never mounts / probe hang | not self-healing | power-button hold 10 s; send the film |

## 4. Loop safety: which cases recover by themselves

Recovery path in every covered case: a SoC reset without `macsmc-reboot` -> iBoot counts a failed boot -> the A/B stage-1
boots `boot.bin.prev` (the daily) -> back on SSH in about 3-5 min. Then restore `boot.bin` from prev before any further
reboot (RUN-W2 step 6).

| failure | covered? |
|---|---|
| hang in m1n1 stage-2 (any wait, the SMC client, RTKit) | **yes**: the stage-1 watchdog (150 s, `m1n1.wdt=keep`), never fed by m1n1 |
| m1n1 STOP (warm N1 not reset, link stays up, SMC no reply) | **yes, nothing to recover**: the kernel boots without the N1 on Ethernet; selftest keeps the boot |
| kernel hard hang before or after `apple_wdt` takes over (all CPUs stuck, e.g. a fabric stall on an endpoint access) | **yes**: nobody feeds the watchdog |
| a device shutdown that stalls the whole SoC (the J714c's case) | **yes**: same watchdog, still running during the restart (`apple_wdt` does not stop on reboot) |
| a device shutdown that blocks one CPU or sleeps forever while the others keep feeding the watchdog | **no**: power-button hold |
| a hang in iBoot or in stage-1 before it arms the watchdog (the warm N1 disturbing the loader itself) | **no** (unless iBoot resets by itself, which the 14:04 fallback may have been): power-button hold. The kernel park (PERST# asserted, L2, port off) is the defence |
| root never mounts / a kernel probe sleeping forever | **no**: power-button hold (Linux feeds the watchdog) |
| root mounted, network down | **yes**: m5-selftest reverts after 90 s |

m1n1 writes nothing to NVMe (two 4 KiB reads); its SMC writes are the gP13 reset key only; the kernel park touches only
port 0 of apcie0.
