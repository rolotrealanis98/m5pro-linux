# W3: the N1 ROM wants the static Image4 manifest stitched into the FTAB (2026-11-07)

(Saved by the coordinator from the agent's hand-back; ANALYSIS and RUN-W3 are condensed here. Digests live only in
`private/SHA256SUMS`; nothing in this file identifies the unit.)

## Result
- `phase0: -5` = the ROM did not accept the image (`image_response` at BAR0+0x8040 != 1, or stage != 4; our kernel does not
  print which). The ROM validates an IM4M taken from the FTAB's ticket slot: header 0x10 = ticket offset, 0x14 = ticket
  length, IM4M appended after the last entry. The bundle `ftab.bin` has both words at 0 and no ticket.
- The manifest `centauri.j716sap.im4m` (restore bundle, `restore/centauri/`) is NOT per unit: no ECID, no BNCH/snon;
  CHIP 0x2026, BORD 0x841, CPRO 1, CSEC 1 (production); 38/38 SHA-384 image digests match our FTAB. The Studio's own
  `restore-staged/centauri/` copy is byte-identical. edimoldovan's J714c merge 671fd38e1c0d used the same recipe.
- Driver (`centauri_pci.c`): probe reads `firmware-name`, platform-id 0xc6050, protocol 27; phase 0 `centauri_rom_boot()`
  does ONE `request_firmware_direct()` (no .im4m request), file 0x30..64 MiB with `rkosftab` at 0x20, whole file in one
  DMA buffer, platform-id to 0x807c, descriptor to 0x8044/0x8048, 0x20 to 0x804c, doorbell 0x9000, poll 0x8040 20 s
  (-110 timeout, != 1 -> -EIO), then stage must reach 4. Phase 1 = port cycle, phase 2 = IPC (Alpha 1902, Beta 1903).
  `APPLE_CENTAURI=y`: the file is read from the INITRAMFS (`wait_for_initramfs`), the root copy only serves rebinds.
- Corrections: the FTAB/manifest are per macOS build and board, not per unit (still private); ROOT-SETUP's ".im4m not
  needed" was wrong; `ccaf` is globally signed, not per-device calibration.

## Built (`private/`, 0700)
`j716s-ftab-w3.bin` 31139056 B (ticket at 0x1db0694, 7772 B; built by `mk-ftab-w3.py`: verifies input structure, manifest
globality/production/CHIP/BORD/38 digests, output re-parsed, only bytes 0x10-0x17 changed before the ticket); 
`initramfs-selftest-n1-w3.cpio.gz`; payload `w3-n1ftab-20261107-33add271.bin` = W2c bytes 0..0x149a4b6 + the new
initramfs (m1n1 n1-smc `n1=4`, kernel 4f630b11270d, stack DTB, same bootargs); `deploy-W3.sh`.
Tools: `tools/im4m-props.py`, `tools/dgst-match.py`, `ftab-ls.py` (print names, booleans, counts only).

## Run (attended; film the panel)
1. Precheck as RUN-W2: <= 4 payloads, >= 94 MB free, boot.bin or prev is a known daily, no boot.bin.failed.
2. Root copy: scp `private/j716s-ftab-w3.bin` to /root, check no updates/ or vendor/ copy exists, size 31139056, magic,
   ticket fields (31131284 7772), keep `j716s-ftab.bin.w0`, install, compare digests without printing them.
   Do not unbind/bind on a running W2c boot as a pre-test (stale 0x8040 gives a meaningless -5).
3. Deploy `private/deploy-W3.sh` (sha verified, prev = known daily, same guard as W2c).
4. **Power off fully** (`systemctl poweroff`), wait 15 s, press power (a warm N1 can answer `phase0: -16`).
5. Readback as W2 plus `dmesg | grep -iE "centauri|phase[0-9]|retrained|106b:19|Wi-Fi firmware|IPC|Alpha|Beta|hci0|wlan"`.
PASS: m1n1 rows as W2c; adopted port, [106b:1900]; NO "required firmware unavailable" and NO phase0 line (ROM success is
silent); `link retrained after a root-port reset`; [106b:1901]/[1902]/[1903] with RID 0101->SID 2, 0102->SID 3; `Wi-Fi
firmware channel list` / `channels`; wlan0; hci0; macsmc and battery fine. Then `W1-POST-ROOT.sh`, Rolando types the
passphrase; full pass = DHCP lease, scan list, three cold boots.
STOP: `phase0: -5` again (W3b = kernel with edimoldovan 50519853a58d printing image_response/stage); -110 (DMA/DART/MSI);
-22 or firmware unavailable (wrong initramfs); phase1/port-cycle lines = ROM accepted, retrain failed; phase2/IPC lines =
firmware ran, IPC failed; Beta lines = Wi-Fi ok, BT not; SError/DART fault; freeze 20-40 s after boot = J714c's ASPM
pattern (next: `pcie_aspm=off`); -16 = warm N1, power off fully, one retry.
Loop safety as W2c (only the FTAB bytes differ); not self-healing: a restart that hangs with the N1 link alive (J714c
needed a pcie-apple shutdown park we lack) and a root that never mounts: power-button hold.
Rollback: ESP prev; root `mv -f j716s-ftab.bin.w0 j716s-ftab.bin`. Rebuild: `mk-ftab-w3.py`, `mk-initramfs-n1-w3.py`,
`mk-w3.py` (each asserts its inputs' digests).
Open after a pass: no ASPM strip on the adopted port, no shutdown park (both from the J714c), unverified Wi-Fi function.
