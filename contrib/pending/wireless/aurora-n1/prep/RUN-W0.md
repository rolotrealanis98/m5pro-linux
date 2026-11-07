# RUN-W0: N1 Wi-Fi stage 0 (m1n1 reads port 0, trains nothing)

Payload: `~/Work/agents/aurora-kernel/payloads/w0-n1dt-20261107-24276a09.bin`
(sha256 `24276a09a92905965c59997a56ce88f474c48f4510945e27156bed3a2bd6dad8`, 38 MB).
Contents: series kernel `7.3.0-g4f630b11270d` (same as the daily), the daily's DTB (`stack-right-port+hwmon`, `594f2a9f`),
m1n1 `n1-dt` (`7621429b`, the daily's m1n1 plus 0022 and one dapf line, see REPORT.md), selftest initramfs on the
current base `1f61a850` plus the FTAB, battery driver on, `m5.selftest=1`.
Everything below runs on the Studio. Logs and the FTAB are private: never into a repo.

```
export HOST=root@<macbook-ip>                       # Ethernet adapter attached, daily running
SSHO=(-i "$HOME/.ssh/mbp" -o IdentitiesOnly=yes)
P=~/Work/agents/n1-wifi/prep; L=~/Work/agents/n1-wifi/logs; TAG=w0-$(date +%Y%m%d-%H%M)
FTAB=~/Work/studio-artifacts/j716s-fw/Firmware/t2026macG1/Release/ftab.bin
```

## 1. Precheck on the running daily (stop on any "STOP")
```
ssh "${SSHO[@]}" $HOST 'uname -r; grep -c m5.selftest=1 /proc/cmdline; tr -d "\0" </proc/device-tree/chosen/m5pro,boot-slot; echo; cat /sys/class/watchdog/watchdog0/state /sys/class/watchdog/watchdog0/timeleft 2>&1; ip -br a | grep -v "^lo"'
```
Expect: `7.3.0-g4f630b11270d`, `0` (daily has no selftest flag), `primary`, watchdog `active` with a timeleft that is not `0`
(that is the A/B stage-1's 150 s watchdog being kept fed by Linux: the pre-root safety net), an Ethernet interface with an address.
- kernel differs or selftest count is 1: STOP (a test is running, not the daily). Boot the daily first.
- watchdog not `active`: STOP and tell Rolando; the 150 s hard-hang net is not armed on this ESP.

## 2. Root prep (once; idempotent)
```
scp "${SSHO[@]}" "$FTAB" $HOST:/root/j716s-ftab.bin
scp "${SSHO[@]}" $P/W0-ROOT-PREP.sh $HOST:/root/
ssh "${SSHO[@]}" $HOST 'bash /root/W0-ROOT-PREP.sh /root/j716s-ftab.bin' | tee $L/$TAG-rootprep.txt
S=$(shasum -a 256 "$FTAB" | cut -d' ' -f1); R=$(ssh "${SSHO[@]}" $HOST 'sha256sum /usr/lib/firmware/apple/centauri/j716s-ftab.bin' | cut -d' ' -f1); [ "$S" = "$R" ] && echo FTAB-MATCH || echo FTAB-MISMATCH
```
Need: last line of the script `RESULT: OK` or `RESULT: OK with warnings`, and `FTAB-MATCH`. A `[FAIL]` line or FTAB-MISMATCH: STOP.
Warnings that are fine: no `phram.ko` (then the m1n1 log must be read from the panel, see step 6), `iwd`/`bluetooth` enabled.
Warnings that block: ESP has less than 94 MB free or more than four `boot.bin*` files (prune first, ESP-POLICY.md).
Then: `ssh "${SSHO[@]}" $HOST 'rm /root/j716s-ftab.bin /root/W0-ROOT-PREP.sh'`. Nothing was enabled; the Ethernet config was not touched.

## 3. Deploy (ESP swap, `boot.bin.prev` = the daily)
```
HOST=$HOST bash $P/deploy-W0.sh | tee $L/$TAG-deploy.txt
```
Must end with `boot.bin = w0-n1dt-20261107-24276a09.bin`. The listing must show `boot.bin.prev` = `275d84ec...` (the daily):
`ssh "${SSHO[@]}" $HOST 'sha256sum /boot/m1n1/boot.bin*' | cut -c1-12,65-`. Any `ABORT`: STOP.

## 4. Reboot and wait
```
ssh "${SSHO[@]}" $HOST 'sync; systemctl reboot'; t0=$(date +%s); sleep 180
until ssh "${SSHO[@]}" -o ConnectTimeout=5 -o BatchMode=yes $HOST true 2>/dev/null; do
  [ $(( $(date +%s) - t0 )) -gt 420 ] && { echo NO-SSH-AFTER-7-MIN; break; }; sleep 10; done
```
Timeline: test boot reaches the network in about 60 s; the self-revert check fires 90 s later (about 150 s); a revert or
a watchdog fallback comes back up as the daily between 200 and 300 s. So an answer before 420 s is either the W0 boot or the daily.
NO-SSH-AFTER-7-MIN: do not retry anything; tell Rolando (power-button hold, or macOS `r1-deploy.sh restore prev`).

## 5. Read back
```
ssh "${SSHO[@]}" $HOST 'bash -s' < $P/READBACK.sh > $L/$TAG-readback.txt 2>&1; grep -a -A1 VERDICT $L/$TAG-readback.txt
```
- `VERDICT: ... TEST payload`: continue. If the `m5-selftest` section has no `network OK` line yet, wait 60 s and run the readback once more.
- `VERDICT: ... did NOT stay up`: the boot fell back (watchdog or self-revert). Go to step 7 (failure).

## 6. Pass/fail (W0)
Collect these from `$L/$TAG-readback.txt`:

| # | what | where | expected |
|---|---|---|---|
| 1 | stayed up | VERDICT + journal `network OK, keeping this payload` | test payload, network OK |
| 2 | m1n1 saw the control function | m1n1 section: `n1: control function: firmware-name apple/centauri/j716s-ftab.bin, platform-id 0x000c6050` | present |
| 3 | **port 0 state** | m1n1 section: `n1: port 0: rc ctl 0x.. stat 0x.. , port status 0x.. linksts 0x.. ltssm 0x..` | present; copy the whole line |
| 4 | not trained (expected) | `n1: port 0 not up: root port and DART disabled`; kernel `apple-pcie 1cb0000000.pcie: probe with driver apple-pcie failed with error -22`; `pci@0,0/status` = `disabled` | all three |
| 5 | tunables lists | readback "device tree: port 0" lists five `*-tunables` entries under `pci@0,0` | five present |
| 6 | no new breakage | `dmesg -l err` section: only the known noise (pmgr "Failed to reach power", the `-22` above) | no `SError`, `fault`, `BUG`, `Oops`, `Call trace` anywhere in the dmesg-grep section |
| 7 | network | `ip -br addr`: Ethernet up with an address | yes |

Linksts bit 0 of line 3: `python3 -c "import re,sys;v=int(re.search(r'linksts 0x([0-9a-f]+)',open(sys.argv[1],errors='replace').read()).group(1),16);print('linksts bit0 =',v&1)" $L/$TAG-readback.txt`

Outcome:
- **PASS, port not trained** (bit0 = 0, rows 1-7 as expected): W0 done. The answer to "does iBoot train port 0" is NO. Go to `RUN-W1.md` (needs Rolando present).
- **PASS, port trained** (bit0 = 1): kernel should show `adopted port 0, endpoint 01:00`, `wlan0`, `hci0` in the readback. Then training is not needed:
  evaluate W1's pass list on this boot (R3-W-RECIPE.md section 3, steps 3-8), run `W1-POST-ROOT.sh`, skip W1.
- **FAIL / odd**: rows 2-4 missing (no n1 lines in the m1n1 log): the m1n1 log may be unreadable (no phram): look at the panel photo; if neither is available, report and stop.
  `SError` / `fault` / hang: step 7.

## 7. After a failure (fallback or revert happened) and after every test
```
ssh "${SSHO[@]}" $HOST 'ls -lt /boot/r1-logs | head; sha256sum /boot/m1n1/boot.bin* | cut -c1-12,65-'
mkdir -p $L/$TAG-r1logs && scp -r "${SSHO[@]}" "$HOST:/boot/r1-logs/selftest-*" $L/$TAG-r1logs/ 2>&1 | tail -3
ssh "${SSHO[@]}" $HOST 'rm -f /boot/r1-logs/selftest-*/boot.bin.failed; ls /boot/m1n1'
```
- `boot.bin` == `boot.bin.prev` (both `275d84ec`): the self-revert service already restored the daily. Nothing else to do.
- `boot.bin` is still the W0 hash while the machine runs the daily (stage-1 watchdog fallback; nothing restores `boot.bin`):
  run `cp boot.bin.prev boot.bin && sync` in `/boot/m1n1` on the MacBook before anything else. `deploy-W*.sh` does the same in its guard 0b, but do not reboot first: the next clean reboot would run W0 again.
- Keep the ESP at four files or fewer.
Send Rolando: `$L/$TAG-readback.txt`, the r1-logs copy, and the exact line that failed.

## Loop safety (W0)
- m1n1 `n1-dt` does only reads of apcie0 (rc, port, link-status registers) and DT edits; it writes no hardware register and trains nothing.
  The readbacks are of the controller the NVMe already runs on, but it is unmeasured on J716s.
- The deploy keeps `boot.bin.prev` = the daily (guard 0b; the daily has no selftest flag and no n1 code), verified by sha before `boot.bin` is replaced.
- Failure modes and what recovers them without a person:
  1. m1n1 or the early kernel hard-hangs (bus stall, SError panic): stage-1's watchdog (150 s) is not fed once the CPU is dead, the SoC resets,
     iBoot counts a bad boot (PMU boot-error count), stage-1 boots `boot.bin.prev`. Back as the daily at about 200 to 300 s. `boot.bin` still holds W0: step 7.
  2. Root mounts but the Ethernet never comes up (for example the new kernel/DT broke it): the selftest service waits 90 s after `network-online`, copies
     `boot.bin.prev` over `boot.bin` and reboots, once (the loop guard file stops a second revert).
- Not recovered without a person (the watchdog keeps being fed by a live kernel): a kernel that stays scheduling but never mounts the root
  (the initramfs then sits in a shell, sshd on the USB gadget link only), or a probe that sleeps forever. Recovery: hold the power button about 10 s;
  iBoot counts a failed boot and stage-1 starts `boot.bin.prev`. W0 has no known path to that state (reads only), but it is why nobody should stay
  away from the machine during the 7 minutes.
