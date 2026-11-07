# Selecting the macOS boot volume from Linux on the J716s: feasibility

2026-11-07. Studio-only research, no MacBook access. Nothing was written or enabled.

## Verdict

- **Reading** the boot selection from Linux is feasible with a small DT change (enable the QSPI node, describe the
  `nvram` partition) plus the `spi-apple-qspi` module that is already in our modules tarball. Stock `asahi-bless
  --list/--get-boot` and `asahi-nvram read` should then work.
- **Writing** it (Linux -> macOS) is not possible with the Aurora driver as published: `spi-apple-qspi` admits NVRAM
  writes only on boards in a hard-coded table, and the J716s is not in it. It needs a one-entry driver patch whose values
  (JEDEC ID, block-protect bits) we cannot know until the read-only step runs.
- **The way back (macOS -> Linux) cannot be unattended without Rolando's admin password**, which we do not want. The
  loop-safe design is a *next-boot-only* selection written from Linux, so that macOS needs no privileged action to hand
  control back (details below). The reboot itself out of macOS still needs a person (power button, or the GUI Restart of
  the logged-in console user), because `reboot`/`shutdown` need root and `rolo` has no sudo.

## 1. Facts about this machine

From the runtime ADT m1n1 handed over (`~/Work/studio-artifacts/adt-runtime-j716s.bin`, parsed read-only; model
`Mac17,8`, compatible `J716sAP`):

| ADT node | Value |
|---|---|
| `/arm-io/qspi` | compatible `qspi,qspimc`; reg P = 0x3_0511_8000 (+0x4000) and C = 0x3_0511_8800 (+0x4000); interrupt 0x55d (1373); clock-gates 0xd0 (208); clock-ids 0x1b8 (440) |
| `/arm-io/qspi/spinor` | compatible `nor-flash,spi`; reg `<0x0 0x19 ...>` (CS0, 25) |
| `/arm-io/qspi/spinor/anvram` | compatible `nvram,nor`, **reg = 0x700000, 0xc0000** (768 KiB) |
| `/chosen` | `nvram-bank-count` = 12, `nvram-bank-size` = 0x10000 (12 banks of 64 KiB, as on the J775D); `nvram-proxy-data` = 64 KiB blob, magic `3VVN` (v3 format), which already contains `upgrade-boot-volume` |

Our DT (die offset +0x2_0000_0000 over the ADT address):
`spi@505118000`, `apple,t6050-qspi` + `apple,t8140-qspi`, `status = "disabled"`, no `flash@0`, no `nvram`
partition, no `nvram` alias (`contrib/validated/aurora/prs/board-v2/dtb/j716s-v2.dts:1399-1409`; originates in
series patch 0001 as `qspi: spi@505118000`). `t6050-j716s.dts` has no `&qspi` override (aliases: serial0, wifi0,
bluetooth0, keyboard).

Power: `ps_qspi` (pmgr +0x350, parent `ps_spi_p` +0x308) exists in the T6050 die0 DT with no `status`, so it is
available; J616s needs an explicit `&ps_qspi { status = "okay"; }` only because its SoC dtsi disables it.

The kernels we build on the series (`~/Work/agents/audio-aurora/kbuild*/obj/.config`) have `CONFIG_MTD=y`,
`CONFIG_MTD_SPI_NOR=y`, `CONFIG_SPI_APPLE_QSPI=m`. `spi-apple-qspi.ko` is in
`modules-7.3.0-g4f630b11270d.tar.zst` (`targets-series.txt:89`; the modules doc notes it has a DTB-matching alias).
`mtdchar` is part of MTD core in this tree (`drivers/mtd/Makefile`), so `/dev/mtdN` appears without another symbol.

## 2. What Asahi/Aurora DTs do

All describe the boot NOR under the controller node, one `flash@0` with `jedec,spi-nor` and a `fixed-partitions` child
labelled `nvram`; the driver and the tools find it by that label:

- J616s (M4 Pro 16"): `t604x-j614-j616.dtsi:1750-1771`. Static `reg = <0x700000 0x100000>`, 10 MHz, single-wire, plus
  `&ps_qspi { status = "okay"; }`; aliases `nvram = &nvram` and `spi0 = &qspi` (`:24-25`).
- J613: `t8122-j613-25g83-qspi.dtsi` (same shape on QSPIMC).
- **J775D (same T6050 family as ours)**: `t6050-j775d.dts:331-355` (on `aurora-ro/pr945-latest`). `&qspi` enabled; `flash@0`
  with `spi-max-frequency = <25000000>`, `spi-rx-bus-width = <1>`, `spi-tx-bus-width = <1>` (single-wire: "no
  quad-enable status write at probe"); `nvram: partition@700000` with `reg = <0x0 0x0>` and `status = "disabled"`, to be
  *filled by the loader* from ADT `/arm-io/qspi/spinor/anvram`; alias `nvram = &nvram` ("asahi-bless and the boot
  loader's dt_set_nvram find the partition by this alias"). Only the partition is exposed (no
  `MTD_PARTITIONED_MASTER`), so the rest of the boot NOR has no device node.

**Our m1n1 does not fill it.** `dt_set_nvram()` (`~/Work/agents/plan/m1n1/src/kboot.c:967-1013`; same in `dcp` and `gpu-e1`)
looks up `/arm-io/spi1/spinor/anvram` only. On T6050 the node is under `/arm-io/qspi`, so it prints "ADT: nvram partition
not found" and leaves the DT node disabled. None of our local m1n1 trees mention `qspi`. The static route below avoids
needing an m1n1 change.

## 3. Would the qspi driver plus a DT enable give `/dev/mtd`?

Yes, read-only, if the DT carries the node. Chain (`drivers/spi/spi-apple-qspi.c` on `aurora-ro/pr1012-latest`):

1. Probe needs the aperture >= 0x8a0 (ours 0x4800), a clock, an IRQ, powered `ps_qspi`; `apple,t8140-qspi` is matched
   through the fallback in our compatible (`:1257-1261`), giving the T8140 policy (data reads of any shape allowed).
2. The driver scans `flash@0/partitions` for exactly one `nvram` partition, 4 KiB aligned, end below 16 MiB
   (`apple_qspi_nvram_window`, `:932-980`); 0x700000 + 0xc0000 = 0x7c0000 passes.
3. `spi-nor` binds to `flash@0` and registers the partition as `mtd0` (name `nvram`). Check:
   `cat /sys/class/mtd/mtd0/{name,size,erasesize}`, `/sys/bus/spi/devices/spi0.0/spi-nor/jedec_id`.
4. **Writes are refused.** `read_only` defaults true. Even with `read_only=0` the driver requires
   `nvram_write_candidate`, which needs a match in `apple_qspi_boards[]` (`:122-139`): j613, j713, j616s (t6041) and
   j700 only. The J775D DT comment says T8140 policy "admits programs and erases only inside this partition", but there is
   no t6050 row on any ref I checked (`pr1012-latest`, `pr945-latest`, `integration`, `pr1056`, `pr1070`), so J775D and
   J716s are read-only in practice. Denials log `NVRAM denied: reason=layout ...`.

A write enable would be one table row for `apple,t6050-qspi` / machine `apple,j716s` / base `0x505118000` /
`nvram_start 0x700000` / `nvram_size 0xc0000` plus the board's JEDEC ID and `bp_ok` (the SR1 block-protect bits iBoot leaves
set). The last two are unknown: get the JEDEC ID from step 3 and `bp_ok` from a status-register read. Do not guess them:
the row is the safety gate. Upstreaming it belongs with Aurora, not with us.

## 4. The userspace tools

`asahi-nvram` and `asahi-bless` (https://github.com/WhatAmISupposedToPutHere/asahi-nvram, MIT, Rust, workspace with
`apple-nvram`, `asahi-bless`, `asahi-nvram`, `asahi-btsync`, `asahi-wifisync`):

- **Device path:** default `/dev/mtd/by-name/nvram`, override `-d/--device`. That by-name symlink is not created by
  the kernel; use `-d /dev/mtd0`, or a udev rule (untested): `SUBSYSTEM=="mtd", ATTR{name}=="nvram",
  SYMLINK+="mtd/by-name/nvram"`.
- **Both open the device read+write even for reads** (`OpenOptions::new().read(true).write(true)`), so pointing them at
  `/dev/mtd0ro` fails. On `/dev/mtd0` the open succeeds and only an actual program/erase hits the driver's refusal.
- **Boot candidates** come from `/dev/nvme0n1` GPT, 4096-byte blocks, partition type
  `7C3457EF-0000-11AA-AA11-00306543ECAC` (APFS container), then a parse of each container's volume groups. Our NVMe
  must therefore be `nvme0n1` (confirm on the box).
- **Variables:** `boot-volume` (system partition) for the default, `alt-boot-volume` for next-boot-only (`--next`).
  Commands: `--list-volumes`, `--get-boot [--next]`, `--set-boot <name|index> [--next]`, `--set-boot-macos`,
  `--clear-next`, `-y`. `--set-boot-macos` needs exactly one volume whose name starts with "Macintosh".
- **Format:** v1/v2 and v3 (`apple-nvram/src/v3.rs`). Our NVRAM is v3 with 12 banks. A May 2026 upstream commit "Support an
  arbitrary number of nvram partitions" (2026-05-22) is what a 12-bank layout needs; releases before it may mis-parse.
  Build from git `main` (last commit seen 2026-09-15) to be safe.
- **Packaging:** packaged in Debian (asahi-bless 0.4.2-6, asahi-nvram), Ubuntu (resolute: asahi-bless 0.4.3-1, asahi-nvram),
  Fedora and Gentoo (sys-apps/asahi-nvram, upstream 0.2.4 listed). A web search found no Arch Linux ARM package and no AUR
  entry; I did not query the AUR directly, so check `yay -Ss asahi-nvram` on the box. Fallback: `cargo build --release -p
  asahi-bless -p asahi-nvram` from the git checkout (Rust toolchain on the target, or cross-build on the Studio). Our distro
  design (`contrib/distro/DESIGN.md:237`) currently leaves `asahi-bless` out, consistent with this.

## 5. The way back from macOS

- `bless --mount <volume> --setBoot [--nextonly]` and `systemsetup -setstartupdisk` write the same NVRAM; on Apple silicon
  both ask for an admin credential. The Startup Disk pane asks too. `rolo` has no sudo and `nvram` writes need root, so
  macOS cannot return control by itself without the admin password.
- **Direction table**

| Direction | Mechanism | Unattended? |
|---|---|---|
| Linux -> macOS | `asahi-bless --next --set-boot-macos` (writes `alt-boot-volume`), then reboot as root on Linux | Yes, once section 3's write gate exists |
| macOS -> Linux | The next-boot-only flag is consumed by iBoot (intended semantics, **not verified on M5**), so the following boot uses `boot-volume`, which stays the Linux stub | Needs only a reboot, which a person starts: power button hold, power-hold boot picker, or Restart in the GUI as the console user. Not `reboot`/`shutdown`/`bless` (root) |
| macOS -> Linux, no flag consumed | `bless --setBoot` / Startup Disk | **No**: admin password |

  Current practice (`docs/plan/FRICTION.md` P9, `contrib/distro/GAPS.md` #22): the stub is the default and macOS is
  entered with the power-hold picker. FRICTION notes that after a macOS boot the Mac "comes back into macOS" when Startup Disk
  was set to Macintosh HD before trips: that is the persistent setting, the thing to avoid. Never set `boot-volume` to macOS.
- Therefore: **no unattended round trip.** The most we can build is "Linux requests a one-shot macOS boot; a human
  triggers the reboot out of macOS; the machine returns to Linux on its own". Even that needs Aurora's write gate for
  the J716s first and one hardware test of next-boot consumption.

## 6. Follow-up: a loop-safe DT patch (not written, proposal only)

It is the J775D block with this machine's own ADT numbers, so it is nearly trivial, but I did not apply it: the effect
is untested on hardware and the J775D uses a loader-filled partition. Proposed for `t6050-j716s.dts`, in the test DTB
only (the default DTB keeps `&qspi` disabled so the A/B stage-1 watchdog's known-good payload never touches the flash):

```dts
/* aliases { ... nvram = &nvram; }  (add to the existing aliases node) */

/*
 * Boot NOR, ADT /arm-io/qspi/spinor/anvram: reg 0x700000, 0xc0000 (12 banks of 64 KiB, /chosen
 * nvram-bank-count 12). Static values from the J716s runtime ADT, so no m1n1 change is needed. Read-only:
 * spi-apple-qspi has no J716s row in its write table. Sibling: t6050-j775d.dts (loader-filled variant).
 */
&qspi {
	status = "okay";

	flash@0 {
		compatible = "jedec,spi-nor";
		reg = <0>;
		spi-max-frequency = <25000000>;
		spi-rx-bus-width = <1>;
		spi-tx-bus-width = <1>;

		partitions {
			compatible = "fixed-partitions";
			#address-cells = <1>;
			#size-cells = <1>;

			nvram: partition@700000 {
				label = "nvram";
				reg = <0x700000 0xc0000>;
			};
		};
	};
};
```

Why it is loop-safe: the driver refuses every program and erase on this board (no table row), the DT exposes only the
partition (no whole-flash node), the node is off in the default DTB, and a hang is caught by the A/B watchdog. What is
unverified: the part's maximum SPI clock (J775D and J700 use 25 MHz, J616s 10 MHz; drop to 10 MHz if probe fails), the JEDEC
ID, and whether `spi-nor`'s probe-time block-protect handling (`CONFIG_MTD_SPI_NOR_SWP_DISABLE_ON_VOLATILE=y` is set in
our kernels) logs a denied write on this part (harmless, but expect a warning).

Test plan once the MacBook is on Linux with that DTB, all read-only:

1. `dmesg | grep -iE 'qspi|spi-nor|mtd'`; `cat /sys/class/mtd/mtd0/{name,size,erasesize}` -> `nvram`, 786432, 4096.
2. `/sys/bus/spi/devices/spi0.0/spi-nor/jedec_id` -> record it (needed for the write row).
3. `dd if=/dev/mtd0 of=/tmp/nvram.bin bs=64k` and compare the first 64 KiB with `/chosen/nvram-proxy-data` from the ADT
   (the blob iBoot passes; it should resemble the active bank, a sanity check on the read path, not a guarantee).
4. `asahi-bless -d /dev/mtd0 --list-volumes` and `--get-boot`; `asahi-nvram -d /dev/mtd0 read boot-volume` (use a build
   with the multi-bank parser). Never run `write`, `--set-boot*` or `--clear-next` until the write gate is agreed.
5. The macOS side of the picture is in the pull script's output: `meta/nvram-boot-vars.txt`, `meta/diskutil-apfs-list.txt`
   (volume UUIDs and roles) and `meta/preboot-boot-active.txt` (policy hash). They let you check by hand that
   what asahi-bless lists matches what macOS reports.

Tell Aurora (with the JEDEC ID and `bp_ok` from step 2 and the status-register read) that the J716s needs a row in
`apple_qspi_boards[]`; until it is there, this machine's NVRAM stays read-only from Linux by design.
