# R2 test notes

Payloads (install as `boot.bin` like R1-D/R1-E; stage-1 is not touched):

- `R2-A-olddtb-battery-newm1n1.bin`: R1-D with the new m1n1 (normal DTB).
- `R2-B-usbhost-battery-newm1n1.bin`: R1-E with the new m1n1 (usbhost DTB, left-front port in host mode).

Run R2-A first: it changes only the m1n1 against a known payload.

## What to expect on the panel

m1n1 lines (white text, before the penguins), in this order:

1. `display: keeping the notch rows (chosen.asahi,show-notch=1), 3456x2234`. Proves 0017 ran.
2. `kboot phase: usb_init`, then one line per USB-PD controller, bus `nub-spmi-a1` first:
   `usb: /arm-io/nub-spmi-a1/hpm2: USB-PD controller in S0, IRQs masked`, the same for
   `nub-spmi-a0/hpm0`, `hpm1` and `hpm5`. A line `tps6598x: power state N -> 0 (S0)` before one
   of them means that controller was not in S0 and m1n1 switched it: that is the case that can
   change VBUS. Four "in S0" lines and no "power state" line means iBoot had them in S0 already
   and the setup changed only the IRQ masks.
3. `kboot phase: usb_init done`, then the usual `pcie_init`, `dapf_init_all`, SMP lines.

Failure lines to look for in step 2: `usb: tps6598x_powerup failed for ...`,
`usb: unable to disable IRQ masks for ...`, `tps6598x: timed out selecting SPMI register 0x..`,
`spmi: stale RX FIFO did not drain`, `spmi: Timeout waiting for RX data`, `spmi: Unexpected SPMI response ...`. Any of them: the boot should continue
anyway. Photograph and note which hpm.

In Linux:

- Framebuffer: `cat /sys/class/graphics/fb0/virtual_size` gives `3456,2234` (was `3456,2160`);
  `cat /sys/class/drm/card0-eDP-1/modes` gives `3456x2234`. The console and the desktop now start
  in the rows behind the notch, so the top ~74 rows are partly hidden by the camera housing.
  `apple,notch-height` is still in the DT (`/proc/device-tree/.../dcp*/apple,notch-height`) if a
  DCP node exists.
- No new kernel dmesg lines from the PD controllers: neither DTB has a tipd/cd321x node, so
  nothing in Linux talks to them. What can change on R2-B is the left-front port with a plain
  USB device or adapter plugged in: VBUS measured at ~5 V (was 0 V), then `usb 1-1: new
  high-speed USB device` and the driver binding (R1 test plan step 4 table).
- Everything else should match R1-D/R1-E (same kernel, DTB, initramfs, bootargs).

## What to photograph

1. The m1n1 lines from `display: keeping the notch rows` to `kboot phase: usb_init done`
   (they scroll quickly: film it, or photograph as soon as the penguins show).
2. The panel once the login/desktop is up, with the top edge in frame (notch rows used or not).
3. R2-B only: the meter on the left-front port (with and without a device), and `lsusb` /
   `dmesg | grep 'usb 1-'` output.
4. Charging: a photo of the MagSafe LED state and `cat /sys/class/power_supply/*/status` (hpm5,
   the MagSafe controller, now also gets S0 + masked IRQs).

## Risks and rollback

- Stage-2 stops in `usb_init`: the SPMI/HPM transport is bounded now, worst case about 6.5 s per
  controller (~26 s for four). If the panel sits on `kboot phase: usb_init` (or on one hpm line)
  for more than 60 s, photograph it, hold power, and restore `boot.bin.prev` from macOS (ESP,
  `m1n1/boot.bin.prev` -> `m1n1/boot.bin`).
- The tether port is hpm0 (left back). Its controller now goes through the same S0/IRQ-mask step
  that upstream m1n1 does on every other Apple silicon Mac. If the EEM tether does not come up
  on R2-A while it did on R1-D, that is the suspect; R2-A vs R1-D isolates it.
- Notch rows kept: cosmetic only; without the payload variable nothing changes.
- If stage-2 does not boot at all (no m1n1 text), the same rollback applies; `build/m1n1-plain-notch.bin`
  (0017 only, no PD change) is the next bisect step.

## R2-C / R2-D (2026-11-06): + dart-pmp0 DAPF

- `R2-C-usbhost-battery-pmpdapf.bin`: R2-B + m1n1 0019. `R2-D-olddtb-battery-pmpdapf.bin`: R2-A + 0019.
- On the panel, in `kboot phase: dapf_init_all`, expect a new block:
  `dapf: /arm-io/dart-pmp0 base 0x2841b0000 window 0x4000, dapf-instance-0 length ...`,
  `dapf:   slice 0 @ 0x2841b0000` ... `slice 30 @ 0x2841b0780`, `dapf: Initialized /arm-io/dart-pmp0`,
  then `kboot phase: dapf_init_all done`.
- Risk: our T6050 AOP DAPF raised an SError (that is why AOP is skipped). dart-pmp0 has no
  `allow-dram-apf-slices-0` and edimoldovan programmed it on J714c without faults, but it has not run
  on J716s. If the panel stops on a `dapf:   slice N @ 0x2841b...` line: photograph it, hold power,
  restore `boot.bin.prev` from macOS (same rollback as above).
- In Linux: `tr -d '\0' < /proc/device-tree/chosen/asahi,m1n1-stage2-version` should print
  `v2.0.0-71-gd5b29b03`. Then `~/Work/agents/pmp-favour/pmp-readback.sh` (`--gates-only` first).
