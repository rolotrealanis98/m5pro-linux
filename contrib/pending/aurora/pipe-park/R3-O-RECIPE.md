# R3-O (and R3-P): R3-N with the PIPE parked the T6050 way

Built and ready in `~/Work/agents/pipe-park/payloads/` (`SHA256SUMS` there). Install as `boot.bin`
like R3-N. Stage-1 stays as it is. **Boot R3-O first**: it differs from R3-N only in the m1n1. The bytes
from offset 0x400000 on are identical to R3-N's (checked).

| payload | sha256 | m1n1 | DTB |
|---|---|---|---|
| `R3-O-aurora-j716s-fixed7-pipepark-selftest.bin` (25339289 B) | `454b7434daa2e6ba9e7105b7f948b51d69398df74723b601b7b75ec5124502ef` | `build/m1n1-plain-r2-pipepark.bin` = ccbb51bc (R3-N's m1n1) + 0020 | `~/Work/agents/atc-tunables/t6050-j716s-typec-fixed7.dtb` |
| `R3-P-aurora-j716s-fixed6-pipepark-atc-selftest.bin` (25336677 B) | `9d7865f2de209e5ea27c082bf19ab0faeb3e41fd8c8f288cb9e0f50583d57802` | `build/m1n1-plain-r2-pipepark-atc.bin` = ccbb51bc + 0020 + 0021 | `~/Work/agents/aurora-kernel/t6050-j716s-typec-fixed6.dtb` (no tunables; m1n1 adds them) |

## Recipe (`mk-r3o.py`, mk-r3.py style)

```
python3 -I ~/Work/agents/pipe-park/mk-r3o.py
```

Layout: `m1n1 (0x400000 B)` + `chosen.bootargs=<ARGS>\n` + `chosen.asahi,show-notch=1\n` + `Image.gz` +
`DTB` + `initramfs`, the same as R3-N. The script asserts every input hash below, checks for 0x400000
bytes and the banner, checks that both gzips are whole, and checks the DTB header size.

ARGS (= R3-N's, recovered from the R3-N payload):
```
earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5 initcall_blacklist=macsmc_power_driver_init m5.selftest=1
```

Inputs:
```
a28b1815432f27fd8126a1f4a561dc639f398151ff4ff9a6aaa740a5ad18ff46  m1n1-plain-r2-pipepark.bin
28b26ebcf91e11e512ef100aae0b3e66d174ebf8a380c243dea4763ae2459a33  m1n1-plain-r2-pipepark-atc.bin
5f8b3e78da16cdaaf870385a3f095f9d1689cf9987f8605e5d9608095a6d8f54  Image.gz
1eb0fcef30554d7f6873c03372466daa837c0d2af7bba8eb138f0d1323347d25  t6050-j716s-typec-fixed7.dtb
5dddc629de2ac0a035914ae210c7957a4139c97052016bedea69e8efa932ecc7  t6050-j716s-typec-fixed6.dtb
ce0b462c0ce465d7cde5fa73bac413f0bc4bf9c833efdf70c782dde06eba217a  initramfs-selftest.cpio.gz
```
Banners: R3-O `v2.0.0-71-gd956947e`, R3-P `v2.0.0-72-gf7555558`. Both are 0x400000 bytes.

## What to expect

m1n1 (panel, during `kboot phase: usb_init`), one line per port, after the four HPM lines:
```
usb: usb-drd0: PIPE on the dummy producer, MUX_CTRL 0x22 -> 0x42
usb: usb-drd1: PIPE on the dummy producer, MUX_CTRL 0x22 -> 0x42
usb: usb-drd2: PIPE on the dummy producer, MUX_CTRL 0x22 -> 0x42
```
The "before" value is whatever the previous agent left: 0x22 after stage-1's proxy, or iBoot's value if
stage-1 didn't touch it. Write it down. "NOT on" in that line means the mux didn't take the value:
photograph it.

R3-P only, during DT setup: `kboot: /arm-io/atc-phy1: T6050 combo PHY tunables passed` (and atc-phy2).
`FDT: Unable to set up T6050 ATC tunables ...` means the PHY gets no tunables and fails with -ENOENT.

Kernel (`dmesg | grep -iE 'phy|dwc3|sn2012|usb'`):
* Gone: `dummy PIPE park failed`, `Failed to assert reset, err=-5`, `sn201202x: waiting for the USB role switch`.
* Expected: dwc3-apple 2aa280000.usb probes, and sn201202x binds at spmi 1-0a. With nothing plugged into
  the left-front port, that is all: the combo PHY starts on the first Type-C event.
* Then plug a USB device into the **left-front** port (ATC1). You should see `usb 1-1: new high-speed` (USB2)
  and, for a USB3 device, a SuperSpeed enumeration. `USB3 PIPE switch failed (-N), the port runs USB2 only`
  is a soft fallback (note N). `start of mode N failed` or `USB3 PIPE switch failed (...): pipe ...` with
  words is a new fault: photograph the words.

## Rollback
Same as R3-N: hold power, then restore `boot.bin.prev` from macOS. Only the stage-2 m1n1 changes. 0020 adds three
register writes and three 10 us waits per port, and on T6050 only.
