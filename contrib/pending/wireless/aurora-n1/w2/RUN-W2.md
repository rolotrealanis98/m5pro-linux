# RUN-W2: N1 Wi-Fi with ANS started by stage-2 (W2, W2b done; W2c next, W2d after it)

**Attended only: Rolando at the machine for the whole run, panel filmed from power-on to the login prompt.**

## 0. Where the series stands

| run | n1 | m1n1 | result (2026-11-07) |
|---|---|---|---|
| W1 | 1 | n1-train `d31e5248` (0020-0023) | `STOP: ANS is not running (before)`: stage-1 leaves ANS stopped |
| W2 (twice) | 3 | n1-ans `69730b19` (+0025) | storage path proven (start ANS, read, A/S unchanged, re-read identical, ANS stopped, Linux on NVMe fine). `STOP: link up: 0x410028208 = 0xab001208 after 500 ms`; final `rc ctl 0x1 stat 0x1, port status 0xd linksts 0xab001208 ltssm 0x1` |
| W2b | 4 | n1-ans `69730b19` | `STOP: /arm-io/apcie0/pci-bridge0 function-reset is not an SMC pKW4`: a 0023 bug (the ADT descriptor *is* pKW4 "gP13" 0x00800000; the code compared `adt_getprop_copy()`'s returned length with 0). The SMC was never written |
| **W2c** | **4** | **n1-smc `a4cc59fd` (+0026)** | next: SMC gP13 pulse as on J813 (0x00800000, 50 ms, 0x00800001, 50 ms, 100 ms), 0023's port order (which reached the LTSSM on W2), 1 s link-up wait |
| W2d | 5 | n1-smc `a4cc59fd` | only if W2c stops at `link up ... after 1000 ms`: W2c + J813's port order |

`n1=4` keeps its meaning (ANS + SMC release); 0026 makes the release actually happen. `n1=5` is new. W2c and W2d are
built so that each changes one thing: W2c only adds the reset pulse that W2b never sent; W2d then changes the port order.

Payloads (in `~/Work/agents/aurora-kernel/payloads/`, each byte-identical to W1 from 0x400000 on except the `n1` line;
same kernel `7.3.0-g4f630b11270d`, DTB, initramfs with the FTAB, bootargs as W0/W1):

| run | payload | sha256 | deploy script |
|---|---|---|---|
| W2c | `w2c-n1smc-20261107-d8bab230.bin` | `d8bab230903bb7fc54338760d7ceb6c51f5897337c2d04558faa684793ae83fd` | `prep/deploy-W2c.sh` |
| W2d | `w2d-n1smc-20261107-e46ceca4.bin` | `e46ceca4936c506f703261fa87e8f4929816881803bfeee453e320221d046730` | `prep/deploy-W2d.sh` |
| W2 | `w2-n1ans-20261107-2dedddda.bin` | `2dedddda0ae91e45696b6fd0f4917dfb1a5d96ae835ea77244e8ba42296daccb` | `prep/deploy-W2.sh` |

m1n1 `m1n1-plain-n1-smc.bin` sha256 `a4cc59fd94f9abc896a1ea4dd0964bf0710f154290ff957b44f31aefa9127db4`
(0020+0021+0022+0023+0025+0026, `v2.0.0-77-g9b9c8e1d`).

Rebuilding (paths are relative to this `w2/` directory):
- `python3 -I prep/mk-w2.py w2c` (or `w2d`; `w2`, `w2b`, `3`, `4` rebuild the earlier ones). It pins W1's bootargs
  (mk-daily.py's BASE now adds `kvm-arm.wfi_trap_policy=trap`) and asserts the W1 equality.
- `python3 -I prep/gen-deploy-w2.py <payload file name> W2c`. Its only output on stdout is `wrote deploy-W2c.sh`; the
  script itself is written next to `gen-deploy-w2.py`, in `prep/`. The guard accepts either daily (`dcec81ed`, `275d84ec`).

```
export HOST=root@<macbook-ip>                       # Ethernet adapter attached
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes)
P=~/Work/agents/n1-wifi/prep; W=~/Work/agents/n1-wifi/w2/prep; L=~/Work/agents/n1-wifi/logs; T=w2c; TAG=$T-$(date +%Y%m%d-%H%M)
```

## 1. Precheck
Machine up on the daily (`dcec81ed`) or on a W2-series test payload.
```
ssh "${SSHO[@]}" $HOST 'cat /proc/cmdline; cd /boot/m1n1 && sha256sum boot.bin* | cut -c1-8,65-; ls boot.bin* | wc -l; df -Pm /boot | tail -1'
```
Need: at most 4 payloads, >= 94 MB free, and boot.bin or boot.bin.prev = `dcec81ed` or `275d84ec`. No `boot.bin.failed`
(copy `/boot/r1-logs` first, then delete it).

## 2. Deploy
```
HOST=$HOST bash $W/deploy-W2c.sh | tee $L/$TAG-deploy.txt
```
Must end `boot.bin = w2c-n1smc-20261107-d8bab230.bin`. On the daily, `boot.bin.prev` becomes the running daily; on a test
payload it stays as is. Any `ABORT`: STOP.

## 3. Reboot (attended) and wait
Power off fully first if the previous boot was a W2-series run that reached the SMC (a warm N1 can answer `phase0: -16`):
`ssh ... 'sync; systemctl poweroff'`, wait 15 s, press power. Otherwise:
```
ssh "${SSHO[@]}" $HOST 'sync; systemctl reboot'; t0=$(date +%s); sleep 180
until ssh "${SSHO[@]}" -o ConnectTimeout=5 -o BatchMode=yes $HOST true 2>/dev/null; do
  [ $(( $(date +%s) - t0 )) -gt 480 ] && { echo NO-SSH-AFTER-8-MIN; break; }; sleep 10; done
```
Film the panel: the `n1:` / `pcie-t6050:` / `nvme:` / `rtkit(...)` / `SMC` lines scroll away once the kernel prints.

What Rolando may see and does:
* `pcie-t6050: STOP: storage lost (...): watchdog reset in 15 s`: photograph, do nothing. The machine resets by itself,
  iBoot counts the failed boot, stage-1 boots `boot.bin.prev` (the daily). SSH back at about 3-5 min. Then step 6.
* m1n1 frozen on one line for more than 150 s (an SMC or ANS reply that never comes): the stage-1 watchdog resets it;
  same as above.
* Kernel up but the root never mounts, or no SSH after 8 min: hold the power button ~10 s. Never `reboot` from the
  initramfs shell. Next boot is the daily. Then step 6.

## 4. Read back
```
ssh "${SSHO[@]}" $HOST 'bash -s' < $P/READBACK.sh > $L/$TAG-readback.txt 2>&1; grep -a -A1 VERDICT $L/$TAG-readback.txt
grep -a 'n1 chosen var' $L/$TAG-readback.txt
```
`VERDICT: ... TEST payload` and `n1 chosen var: 4` (W2c) / `5` (W2d) = the test boot stayed up. Otherwise step 6.

## 5. Pass and stop lines

m1n1, in order (from the film); rows 2-3 and 6-7 are what W2 already showed:

| # | line | meaning |
|---|---|---|
| 1 | `n1: chosen.m5pro,n1=4: training apcie0 port 0 with ANS started after the SMC reset release` (W2d: `...release, J813 order`) | variable read |
| 2 | `pcie-t6050: ANS stopped (0x0): starting it`, `nvme: initialized at 0x45dcc0000`, `NVMe block 1 read (GPT header)` | storage path before |
| 3 | `storage before: reference`, `storage after A: unchanged`, `storage after S: unchanged` | shared init held storage |
| 4 | **new:** `rtkit(smc): booting with version ...`, `pcie-t6050: SMC key gP13 <- 0x00800000: 0`, then `... <- 0x00800001: 0` | the N1 reset pulse was sent and the SMC accepted both writes |
| 5 | `pcie-t6050: port 0 link Gen1 x1`, `endpoint 01:00.0 is 0x1900106b`, `storage after F: ...`, `port 0 up, N1 at 01:00` | **port trained (first time)** |
| 6 | `storage after training: ...` (an `0x419600048 ... -> ...` line classified `allowed` is normal: ANS CPU status bits), `NVMe read identical` | storage intact |
| 7 | `nvme: shutdown done`, `pcie-t6050: ANS stopped again for Linux` | Linux gets ANS as today |
| 8 | `n1: port 0 up: root port and DART okay` | DT hand-off |

Kernel and root (RUN-W1 rows 4-9): `apple-pcie 1cb0000000.pcie: port 0: RID 0100 -> SID 1, slot 1`,
`adopted port 0, endpoint 01:00`, `pci 0000:01:00.0: [106b:1900]`, no DART fault; no `required firmware
apple/centauri/j716s-ftab.bin unavailable`; `link retrained after a root-port reset`, `[106b:1901]`, `[106b:1902]`,
`[106b:1903]`; `Wi-Fi firmware channels`, `wlan0`; `Bluetooth: hci0`, `hci0`; NVMe partitions;
`network OK, keeping this payload`. Also check `macsmc` bound and the battery readable (`cat /sys/class/power_supply/*/capacity`):
m1n1 now talks to the SMC and quiesces its client before Linux (as Aura's J813 code does).

* **PASS: rows 1-8 and `wlan0` + `hci0`.** Then `W1-POST-ROOT.sh` as in RUN-W1 step 5 (Rolando types the Wi-Fi passphrase
  himself). Full pass = DHCP on wlan0 and three boots with a power-off between.
* **W2c stops at `STOP: link up: 0x410028208 = 0x... after 1000 ms`** with row 4 present: the reset pulse alone is not
  enough. Run **W2d** (`T=w2d`, `deploy-W2d.sh`, `n1 chosen var: 5`), power-off first. Send the `linksts` value either way.
* **STOP and send logs, do not retry:**
  - `SMC: failed to ...`, `SMC not available`, or row 4 with a non-zero result (`: <n>`): the SMC refused; the kernel then
    boots without the N1. Send the lines.
  - `STOP: ... function-reset is not an SMC pKW4` again: the 0026 m1n1 is not the one running (check the banner
    `v2.0.0-77-g9b9c8e1d`).
  - `STOP: storage lost (...)`, `storage changed`, `NVMe BOOT_STATUS`, `nvme_init failed`, `NVMe read before the training
    failed`, `phase0: -5 / -110`, SError or DART fault at `410000000.iommu`, kernel `ANS did not boot`, `macsmc` errors.
  - `phase0: -16`: power off fully, one retry allowed.

## 6. After every run
Copy `/boot/r1-logs/selftest-*` and the readback to `~/Work/agents/n1-wifi/logs/`, delete any `boot.bin.failed`.
If the machine runs the daily while `boot.bin` still holds a test: `cp boot.bin.prev boot.bin && sync` before the next
reboot (the deploy guard also does it). After a pass, prune the ESP to four payloads.

## Loop safety (W2 series)
* m1n1 hangs anywhere (ANS start, SMC handshake or write, training): stage-2 keeps the stage-1 watchdog armed
  (`m1n1.wdt=keep`), 150 s, iBoot counts, stage-1 boots `boot.bin.prev`. Unattended. (`smc_cmd()` and the RTKit boot loops
  wait without a timeout; the watchdog is their bound.)
* Storage doubt detected in m1n1: m1n1 resets through the watchdog itself 15 s after the STOP line. Unattended.
* Storage fine in m1n1 but Linux cannot restart ANS (root never mounts): not self-healing; power-button hold 10 s.
* SMC client quiesced by m1n1 and Linux's macsmc unhappy: the boot continues (root, network), but clean reboots may count as
  failures (macsmc-reboot clears iBoot's boot stage), so the next boot can take the fallback slot. Not a hang.
* Root mounted, network down: m5-selftest reverts to `boot.bin.prev` 90 s after `network-online`.
* m1n1 writes nothing to NVMe (two 4 KiB reads of LBA 1). The SMC writes are the N1 reset key only.
