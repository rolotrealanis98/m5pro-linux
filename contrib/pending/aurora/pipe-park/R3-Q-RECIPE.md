# R3-Q: R3-O plus Aurora's PHY firmware restart fix (kernel rebuild needed)

You build the kernel. I did not build it. The m1n1, DTB, initramfs and bootargs are the same as R3-O.

## 1. Kernel

In `/Volumes/linux-cs/wt-aurora` (branch aurora-j716s @ da5a44d086e6):
```
git am ~/Work/agents/pipe-park/patches/kernel-r3q/0001-*.patch \
       ~/Work/agents/pipe-park/patches/kernel-r3q/0002-*.patch \
       ~/Work/agents/pipe-park/patches/kernel-r3q/0003-*.patch
```
Then build Image.gz as for R3-N/R3-O, with the same config. 0003 alone is the minimum. All three is the
recommendation: 0002 for USB3, and 0001 matches Aurora's tree.

| patch | Aurora commit (j716c/thunderbolt) | sha256 |
|---|---|---|
| 0001 park the PIPE from a dummy producer on any clock | 6f93def30893 | see SHA256SUMS |
| 0002 carry on when the PIPE lock is not acknowledged | e604b7f414b4 | see SHA256SUMS |
| 0003 restart the PHY firmware on its original data | b8f2be0fef93 | see SHA256SUMS |

## 2. Payload (`mk-r3q.py`, mk-r3.py style)
```
python3 -I ~/Work/agents/pipe-park/mk-r3q.py
```
It writes `payloads/R3-Q-aurora-fwrestart-j716s-fixed7-pipepark-selftest.bin` and `payloads/SHA256SUMS-R3Q`.
Layout as R3-N: m1n1 (0x400000) + `chosen.bootargs=` line + `chosen.asahi,show-notch=1` + Image.gz +
DTB + initramfs. It refuses the old kernel (sha 5f8b3e78...) and an Image.gz without 0002's string
(`lock not acknowledged; continuing`). 0003 has no string of its own: check that `git log -3` shows it
before building.

| input | path | sha256 |
|---|---|---|
| m1n1 (R3-O's: ccbb51bc + 0020, v2.0.0-71-gd956947e) | `~/Work/agents/pipe-park/build/m1n1-plain-r2-pipepark.bin` | a28b1815432f27fd8126a1f4a561dc639f398151ff4ff9a6aaa740a5ad18ff46 |
| kernel | `/Volumes/linux-cs/wt-aurora/arch/arm64/boot/Image.gz` (rebuilt) | printed by the script |
| DTB | `~/Work/agents/atc-tunables/t6050-j716s-typec-fixed7.dtb` | 1eb0fcef30554d7f6873c03372466daa837c0d2af7bba8eb138f0d1323347d25 |
| initramfs | `~/Work/omarchy-m5/build/initramfs-selftest.cpio.gz` | ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a |

Bootargs:
```
earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5 initcall_blacklist=macsmc_power_driver_init m5.selftest=1
```

## 3. What to expect (hub plugged in at boot, as in R3-O)

* 0.7 s: the first "RTKit: Initializing", xhci buses 1 and 2, the hub on bus 1.
* About 1.3 s: xhci removed (the DP pin D switch). Then the second "RTKit: Initializing" and **no**
  `bank2+260 timeout`. No `start of mode 3 failed`.
* xhci comes back. The Genesys USB2 hub and its devices (Logitech receiver, card reader, RTL8153) appear
  on bus 1. With 0002, the VIA USB3 hub should appear on bus 2 as `new SuperSpeed`, possibly after a
  `PIPE lock not acknowledged; continuing (...)` warning, which is expected.
* `sn201202x`: no "failed to configure" and no "safe mode" errors.
* Then unplug and replug the hub once: a third RTKit start must also come up. This is the case 0003
  fixes.
* If `bank2+260 timeout` still shows on the second start, photograph the line. That means the data
  restore is not enough on J716s.

## Rollback
As for R3-O: restore `boot.bin.prev`. Only the kernel differs from R3-O.
