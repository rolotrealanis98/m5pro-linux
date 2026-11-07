# RUN-W1: N1 Wi-Fi stage 1 (m1n1 trains apcie0 port 0, `chosen.m5pro,n1=1`)

**Attended only: Rolando at the machine for the whole run.** Run it only after RUN-W0 finished with "PASS, port not trained"
(or W0 failed only because the log was unreadable and Rolando accepts the risk). The root prep of RUN-W0 step 2 must already be done.

Payload: `~/Work/agents/aurora-kernel/payloads/w1-n1train-20261107-3c0a1eff.bin`
(sha256 `3c0a1eff5525cf20495e61f33481f2b9aec2d7d38a6b1322ae5d52468183e97b`, 38 MB). Identical to W0 except the m1n1
(`n1-train`, `d31e5248`: 0020+0021+0022+0023) and one inserted line, `chosen.m5pro,n1=1` (18 bytes after the notch line;
`contrib/pending/wireless/aurora-n1/prep/mk-w1.py` is the recipe). Same kernel, DTB, initramfs and bootargs as W0.

Risk (from the plan): 0023 starts the GP PHY and applies tunables on apcie0 while the NVMe controller shares those blocks. m1n1 snapshots storage
state before and after and stops if it changed, but a change cannot be undone: NVMe may be lost for that boot. No data is written by m1n1.

```
export HOST=root@<macbook-ip>                       # Ethernet adapter attached
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes)
P=~/Work/agents/n1-wifi/prep; L=~/Work/agents/n1-wifi/logs; TAG=w1-$(date +%Y%m%d-%H%M)
```

## 1. Precheck: same as RUN-W0 step 1 (daily or W0 running; if W0 is running the selftest count is 1 and that is fine)
Additionally: `ssh "${SSHO[@]}" $HOST 'sha256sum /boot/m1n1/boot.bin.prev' ` must start `275d84ec` (the daily).

## 2. Deploy
```
HOST=$HOST bash $P/deploy-W1.sh | tee $L/$TAG-deploy.txt
```
Must end `boot.bin = w1-n1train-20261107-3c0a1eff.bin`; `boot.bin.prev` = `275d84ec`. Any `ABORT`: STOP.

## 3. Reboot (attended) and wait
```
ssh "${SSHO[@]}" $HOST 'sync; systemctl reboot'; t0=$(date +%s); sleep 180
until ssh "${SSHO[@]}" -o ConnectTimeout=5 -o BatchMode=yes $HOST true 2>/dev/null; do
  [ $(( $(date +%s) - t0 )) -gt 420 ] && { echo NO-SSH-AFTER-7-MIN; break; }; sleep 10; done
```
Rolando watches the panel: photograph the m1n1 lines (`n1:` / `pcie-t6050:` / `STOP:`) if the machine stops on them.
If the panel freezes with no network after 5 minutes, or the screen stays in the initramfs shell: Rolando holds the power button about 10 s
(iBoot counts a failed boot, stage-1 then boots `boot.bin.prev` = the daily). Then step 6.

## 4. Read back
```
ssh "${SSHO[@]}" $HOST 'bash -s' < $P/READBACK.sh > $L/$TAG-readback.txt 2>&1; grep -a -A1 VERDICT $L/$TAG-readback.txt
grep -a 'n1 chosen var' -A0 $L/$TAG-readback.txt
```
`VERDICT: TEST payload` and `n1 chosen var: 1` mean the W1 boot is the one that stayed up. Anything else: step 6.
No `network OK` yet in the journal: wait 60 s and read back once more.

## 5. Pass/fail (W1)
Decisive lines (R3-W-RECIPE.md section 3 has the full list):

| # | source | line | meaning |
|---|---|---|---|
| 1 | m1n1 | `n1: chosen.m5pro,n1=1: training apcie0 port 0` | the variable was read |
| 2 | m1n1 | `pcie-t6050: storage before: reference`, then `storage after A: unchanged\|allowed`, `storage after S: ...` (or `shared GP init already in place`) | NVMe state held |
| 3 | m1n1 | `pcie-t6050: port 0 link Gen1 x1`, `endpoint 01:00.0 is 0x1900106b`, `storage after F`, `pcie-t6050: port 0 up, N1 at 01:00`, `n1: port 0 up: root port and DART okay` | the port trained |
| 4 | kernel | `apple-pcie 1cb0000000.pcie: port 0: RID 0100 -> SID 1, slot 1`, `adopted port 0, endpoint 01:00`, `pci 0000:01:00.0: [106b:1900]`, no DART fault | adoption |
| 5 | kernel | no `required firmware apple/centauri/j716s-ftab.bin unavailable` | FTAB found in the initramfs |
| 6 | kernel | `link retrained after a root-port reset`, then `[106b:1901]`, `[106b:1902]`, `[106b:1903]` | ROM boot done, functions up |
| 7 | kernel | `Wi-Fi firmware channels`, then `wlan0` in `ip -br link` / `iw dev` | **Wi-Fi radio registered** |
| 8 | kernel | `Bluetooth: hci0`, then `hci0` in `btmgmt info` | **Bluetooth registered** |
| 9 | journal | `network OK, keeping this payload` | the boot is stable |

- **PASS (this round): rows 1-9, with `wlan0` and `hci0` present.** Then run `W1-POST-ROOT.sh` (writes iwd/networkd config, starts iwd and bluetooth for this boot only):
  `scp "${SSHO[@]}" $P/W1-POST-ROOT.sh $HOST:/root/ && ssh "${SSHO[@]}" $HOST 'bash /root/W1-POST-ROOT.sh' | tee $L/$TAG-post.txt`.
  The scan list shows SSIDs of nearby networks when the radio works. Associating needs the Wi-Fi passphrase: Rolando does that (`iwctl --passphrase ... station wlan0 connect <SSID>`), never in a script or file.
  The plan's full pass is a DHCP lease on wlan0 and three boots in a row with a power-off between each.
- **STOP and send logs** (do not retry): any m1n1 `STOP: ...` line, `storage changed`, kernel `phase0: -5` (ROM rejected the FTAB: needs the im4m stitched in, ANALYSIS.md 2.3),
  `phase0: -110`, `phase0: -16` (warm boot: power off fully, one retry is allowed only for -16), SError or DART fault at the `410000000.iommu` probe.
  The meaning of every line: R3-W-RECIPE.md section 4.
- `STOP: link up: 0x410028208 = 0x... after 500 ms`: the N1 is probably still in SMC reset: that is the only trigger for W2 (`python3 -I prep/mk-w1.py 2` builds it; not built yet).

## 6. After a failure and after every test: same as RUN-W0 step 7
Copy `/boot/r1-logs/selftest-*`, delete any `boot.bin.failed`, and if the machine runs the daily while `boot.bin` still holds W1,
`cp boot.bin.prev boot.bin && sync` before the next reboot. Copy everything (readback, r1-logs, photos) to `~/Work/agents/n1-wifi/logs/`.

## Loop safety (W1)
Same net as W0 (see RUN-W0 "Loop safety"), with the honest limits for the training step:
- **Port training hangs or the m1n1 hard-hangs** (a PHY or link wait that never returns, a bus stall on a gated block): the CPU stops, the 150 s stage-1 watchdog is not fed,
  the SoC resets, iBoot counts a bad boot, stage-1 boots `boot.bin.prev` = the daily (no `n1` variable, no training). Back at about 200 to 300 s. `boot.bin` still holds W1: restore it (step 6) before rebooting.
  m1n1's own waits are bounded by its timeouts and end in `STOP:` (it then boots without the N1; the kernel sees the port disabled and the boot continues as W0).
- **m1n1 stops with `STOP:` or training is refused**: not a hang; the kernel boots, no N1, selftest passes on the Ethernet, W1 simply reports a fail. Read the line.
- **NVMe disturbed so the root does not mount**: NOT self-healing. The kernel is alive, the initramfs waits for the root and then stays in a shell; Linux feeds the watchdog, so there is no
  reset and no revert. This is why Rolando must be there: hold the power button about 10 s; iBoot counts a failed boot and stage-1 starts the daily from `boot.bin.prev`.
  (The initramfs also has sshd on the USB gadget link; that link is for diagnosis only. Do not `reboot` from it: a clean reboot clears the failure count and boots W1 again.)
- **Root mounted, Ethernet down** (for example storage fine but the network driver broke): the selftest service reverts to `boot.bin.prev` 90 s after `network-online`, once.
- **Training succeeds, then a kernel probe hangs hard or panics**: watchdog path as the first item. A probe that merely sleeps forever is the same as the NVMe case: power-button hold.
- `sync` before the reboot is already in the commands; nothing writes to the root or the ESP from m1n1.
