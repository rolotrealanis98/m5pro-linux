# RUN-W2: N1 Wi-Fi with ANS started by stage-2 (`chosen.m5pro,n1=3`)

**Attended only: Rolando at the machine for the whole run, panel filmed from power-on to the login prompt.**
W1 (n1=1) stopped at `pcie-t6050: STOP: ANS is not running (before)`: stage-1 leaves ANS stopped. W2 is W1 with
the 0025 m1n1, which starts ANS for the storage checks and stops it again before Linux.

Payload: `~/Work/agents/aurora-kernel/payloads/w2-n1ans-20261107-2dedddda.bin`
(sha256 `2dedddda0ae91e45696b6fd0f4917dfb1a5d96ae835ea77244e8ba42296daccb`, 38 MB). Byte-identical to W1 from
0x400000 on except `chosen.m5pro,n1=3` (was `=1`); same kernel `7.3.0-g4f630b11270d`, DTB, initramfs (with the FTAB)
and bootargs as W0/W1. m1n1 `m1n1-plain-n1-ans.bin` `69730b19...` (0020+0021+0022+0023+0025, `v2.0.0-76-g3e7019df`).
Recipe: `contrib/pending/wireless/aurora-n1/w2/prep/mk-w2.py` (it pins W1's bootargs, since mk-daily.py's BASE now adds `kvm-arm.wfi_trap_policy=trap`,
and asserts the W1 equality). Deploy script: `contrib/pending/wireless/aurora-n1/w2/prep/deploy-W2.sh` (`gen-deploy-w2.py`).

```
export HOST=root@<macbook-ip>                       # Ethernet adapter attached
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes)
P=~/Work/agents/n1-wifi/prep; W=~/Work/agents/n1-wifi/w2/prep; L=~/Work/agents/n1-wifi/logs; TAG=w2-$(date +%Y%m%d-%H%M)
```

## 1. Precheck
Machine up on the daily (aurora/STATE.md: `boot.bin` = `dcec81ed`, `boot.bin.prev` = `275d84ec`) or on W1.
```
ssh "${SSHO[@]}" $HOST 'cat /proc/cmdline; cd /boot/m1n1 && sha256sum boot.bin* | cut -c1-8,65-; ls boot.bin* | wc -l; df -Pm /boot | tail -1'
```
Need: at most 4 payloads, >= 94 MB free, and boot.bin or boot.bin.prev = `dcec81ed` or `275d84ec`. No `boot.bin.failed`
(delete it after copying `/boot/r1-logs`).

## 2. Deploy
```
HOST=$HOST bash $W/deploy-W2.sh | tee $L/$TAG-deploy.txt
```
Must end `boot.bin = w2-n1ans-20261107-2dedddda.bin`. On the daily, `boot.bin.prev` becomes the running daily (`dcec81ed`);
on W1 it stays as is. Any `ABORT`: STOP.

## 3. Reboot (attended) and wait
```
ssh "${SSHO[@]}" $HOST 'sync; systemctl reboot'; t0=$(date +%s); sleep 180
until ssh "${SSHO[@]}" -o ConnectTimeout=5 -o BatchMode=yes $HOST true 2>/dev/null; do
  [ $(( $(date +%s) - t0 )) -gt 480 ] && { echo NO-SSH-AFTER-8-MIN; break; }; sleep 10; done
```
Film the panel: the `n1:` / `pcie-t6050:` / `nvme:` / `rtkit(nvme):` lines scroll away once the kernel prints (there
is no phram in the kernel to read them back). The boot is a few seconds longer than W1 (ANS boots twice).

What Rolando may see and does:
* `pcie-t6050: STOP: storage lost (...): watchdog reset in 15 s, stage-1 then boots its fallback`: photograph, do
  nothing. The machine resets by itself, iBoot counts the failed boot, stage-1 boots `boot.bin.prev` (the daily).
  SSH back at about 3-5 min. Then step 6.
* m1n1 frozen on one line for more than 150 s: the stage-1 watchdog resets it; same as above (back at ~5 min).
* Kernel up but the root never mounts (initramfs waits, then a shell), or no SSH after 8 min: hold the power button
  ~10 s. Never `reboot` from the initramfs shell (a clean reboot clears the failure count and boots W2 again).
  Next boot is the daily. Then step 6.

## 4. Read back
```
ssh "${SSHO[@]}" $HOST 'bash -s' < $P/READBACK.sh > $L/$TAG-readback.txt 2>&1; grep -a -A1 VERDICT $L/$TAG-readback.txt
grep -a 'n1 chosen var' $L/$TAG-readback.txt
```
`VERDICT: ... TEST payload` and `n1 chosen var: 3` = the W2 boot stayed up. `boot.bin == boot.bin.prev` hashes or a
missing var = a fallback happened: step 6. No `network OK` yet: wait 60 s, read back again.

## 5. Pass and stop lines

m1n1, in order (from the film):

| # | line | meaning |
|---|---|---|
| 1 | `n1: chosen.m5pro,n1=3: training apcie0 port 0 with ANS started` | variable read |
| 2 | `pcie-t6050: ANS stopped (0x...): starting it`, `nvme: ANS is on die N`, `rtkit(nvme): booting with version ...`, `nvme: initialized at 0x...` (0x45dcc0000 expected) | stage-2 started ANS |
| 3 | `pcie-t6050: NVMe block 1 read (GPT header)` (or `no GPT signature`: fine, only reported) | storage path works before |
| 4 | `pcie-t6050: storage before: reference`, `storage after A: unchanged\|allowed`, `storage after S: ...` (or `shared GP init already in place`) | **the W1 blocker is gone** |
| 5 | `pcie-t6050: port 0 link Gen1 x1`, `endpoint 01:00.0 is 0x1900106b`, `storage after F: ...`, `port 0 up, N1 at 01:00` | port trained |
| 6 | `pcie-t6050: storage after training: unchanged\|allowed`, `storage after training: NVMe read identical` | storage intact after |
| 7 | `nvme: shutdown done`, `pcie-t6050: ANS stopped again for Linux` | Linux gets ANS as today |
| 8 | `n1: port 0 up: root port and DART okay` | DT hand-off |

Kernel and root (as RUN-W1 rows 4-9): `apple-pcie 1cb0000000.pcie: port 0: RID 0100 -> SID 1, slot 1`,
`adopted port 0, endpoint 01:00`, `pci 0000:01:00.0: [106b:1900]`, no DART fault; no `required firmware
apple/centauri/j716s-ftab.bin unavailable`; `link retrained after a root-port reset`, `[106b:1901]`, `[106b:1902]`,
`[106b:1903]`; `Wi-Fi firmware channels`, `wlan0`; `Bluetooth: hci0`, `hci0`; NVMe partitions and
`network OK, keeping this payload`.

* **PASS: m1n1 rows 1-8 and `wlan0` + `hci0`.** Then `W1-POST-ROOT.sh` as in RUN-W1 step 5 (Rolando types the Wi-Fi
  passphrase himself). Full pass = DHCP on wlan0 and three boots with a power-off between.
* **Partial pass, storage half proven:** rows 1-4 and 6-7 with a training `STOP:` in between, `n1: port 0 not up`,
  the kernel boots from NVMe. The ANS fix works; read the STOP line (R3-W-RECIPE.md section 4).
  `STOP: link up: 0x410028208 = 0x... after 500 ms` is the only trigger for **W2b** (`n1=4`, adds the SMC gP13
  release): `python3 -I $W/mk-w2.py 4`, then `python3 -I $W/gen-deploy-w2.py <new payload name> W2b`, same procedure.
* **STOP and send logs, do not retry:**
  - `pcie-t6050: STOP: nvme_init failed, ANS stopped as before: not training` (+ the `nvme:` / `rtkit(nvme):` lines):
    m1n1 could not start the stopped ANS; the kernel then boots as W0. Send the lines.
  - `STOP: NVMe read before the training failed: not training`: same, send.
  - `STOP: storage lost (...)` (machine resets itself): the training disturbed storage, or ANS did not stop. Send the
    photo; the next boot is the daily. Do not retry.
  - `storage changed`, `NVMe BOOT_STATUS`, `phase0: -5 / -110`, SError or DART fault at `410000000.iommu`, kernel
    `ANS did not boot` / `ANS did not initialize`. `phase0: -16`: power off fully, one retry allowed.

## 6. After every run
Copy `/boot/r1-logs/selftest-*` and the readback to `~/Work/agents/n1-wifi/logs/`, delete any `boot.bin.failed`.
If the machine runs the daily while `boot.bin` still holds W2: `cp boot.bin.prev boot.bin && sync` before the next
reboot (deploy-W2.sh's guard also does it). After a pass, prune the ESP to four payloads.

## Loop safety (W2)
* m1n1 hangs anywhere (ANS start, training): stage-2 keeps the stage-1 watchdog armed (`m1n1.wdt=keep`), 150 s,
  iBoot counts, stage-1 boots `boot.bin.prev`. Unattended.
* Storage doubt detected in m1n1 (register diff, failed or different re-read, ANS still running): m1n1 resets through
  the watchdog itself 15 s after the STOP line. Unattended. This was the attended case in W1's plan.
* Storage fine in m1n1 but Linux cannot restart ANS (root never mounts): **not self-healing**; the kernel feeds the
  watchdog. Power-button hold 10 s. This is why W2 is attended.
* Root mounted, network down: m5-selftest reverts to `boot.bin.prev` 90 s after `network-online`.
* m1n1 writes nothing to NVMe (two 4 KiB reads of LBA 1).
