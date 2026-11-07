# Omarchy-chain test B1 for the J716s — built, not booted (2026-11-07)

Chain: our A/B stage 1 (unchanged) -> m1n1/boot.bin (B1 = Ed's j714c/m1n1 5bb6965d99b1 + RVBAR relay, m1n1.wdt=keep,
PIPE park 0020, combo-PHY tunables 0021; built with m1n1-aurora flags + -DT6050_NO_HOST_PREP; 0x410000 bytes
e3c2374f…) -> U-Boot (Ed's j714c/t6050 70e990818a, apple_m1_defconfig + EFI_RT_VOLATILE_STORE, panel console,
WATCHDOG_AUTOSTART=n, NVMe/board DEBUG; 8036ff2e…) -> Limine 12.9.6-1 (ALARM extra, the package Omarchy installs)
-> the 87-patch daily kernel as a bare EFI-stub Image (7.3.0-ga0f2f30c967b) with the FTAB initramfs.
Composition by asahi-scripts 20261023-1 `update-m1n1` unmodified: m1n1 + 116 DTBs (linux-aurora 7.2.11.aurora15's
115 + our t6050-j716s.dtb 659af884) + gzip U-Boot + one chosen.m5pro,stage2 marker; reproducible byte-identical.

ESP files (staged ~/Work/agents/omarchy-chain/out/esp/, initramfs in private/esp/): m1n1/boot.bin 10,264,914 B
2591da1f…; EFI/BOOT/BOOTAA64.EFI 335,872 B 11288bad…; limine.conf 1,993 B 9d6ad3e7…; m5chain/Image 49,875,456 B
01c202b7…; m5chain/initramfs-ftab.cpio.gz 16,779,326 B cffbbaf1…. +73.7 MiB new, net ~+38 MB (≈180 of 476 MB used).

limine.conf: default entry protocol efi (EFI stub, cmdline `initrd=/m5chain/initramfs-ftab.cpio.gz m5.chain=limine-efi`
+ daily bootargs incl. m5.root= and pcie_aspm=off + root=/dev/nvme0n1p5, no m5.selftest); entry 2 protocol linux;
no dtb_path (U-Boot passes m1n1's prepared tree); BLAKE2B hashes on each path.

Deploy (Studio, machine on the daily, primary slot): `HOST=root@<ip> bash deploy-OMARCHY-CHAIN-B1.sh` (preflight,
verified copies, boot.bin.prev = running daily, boot.bin = B1, remount, re-hash; no reboot) -> ATTENDED COLD START
(`systemctl poweroff`, power button; a warm restart is not enough: B1 has no warm-N1 entry) ->
`check-OMARCHY-CHAIN-B1.sh` (cmdline contains m5.chain=limine-efi; /chosen shows m5pro,stage2, linux,uefi-*,
u-boot,version; dmesg "EFI by Das U-Boot"; LoaderInfo Limine 12.9.6; 18 CPUs; ans-rtkit reserved-memory) ->
`cleanup-OMARCHY-CHAIN-B1.sh`.

Fallback: only stage 1's 150 s watchdog (no Linux inside B1, no self-test); stage 2 keeps it armed, U-Boot/Limine leave
it, apple_wdt takes over; a hang before that resets to boot.bin.prev. Limine's menu is unusable (no keyboard before
Linux); default boots after 5 s; `default_entry: 3` for entry 2.

Risks: (1) NVMe takeover differs from Ed's chain: his stage 1 hands over a live ANS session (nvme.adopt=live-rtkit-v1 ->
/chosen/asahi,nvme-adopt); ours stops ANS, so U-Boot does a fresh RTKit handshake on T6050 for the first time
("ANS RTKit handshake failed" -> watchdog fallback; fix = port the live hand-over into our stage 1, another 1TR install);
(2) ESP space fine for the test, a real install (UKIs, boot.bin.old, vendorfw) unmeasured; (3) U-Boot runs on our DT
(NVMe node matches a T6050 profile; our PCIe node matches nothing in U-Boot); (4) no Linux-side self-test: a kernel
without network needs a power-button hold or macOS; (5) no Wi-Fi (no N1 hand-off; kernel does not train the port; the
omacom N1 port conflicts in kboot.c): SSH over the USB Ethernet adapter; (6) test binaries differ slightly from
Omarchy's; (7) first boot of a fresh file may fall back once (use esp-put).

Repo: contrib/pending/installer/omarchy-chain/ (build.sh, mk-esp.py, deploy/check/cleanup scripts, 4 m1n1 patches
without AI trailers, SHA256SUMS, README.md), commit e3b1cd7. m1n1 worktree ~/Work/agents/omarchy-chain/m1n1 (branch
j716s/omarchy-chain 772ffa5), remote edimoldovan in aurora-prs-2/m1n1.
