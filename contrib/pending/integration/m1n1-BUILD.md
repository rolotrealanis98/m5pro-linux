# m1n1-r2: stage-2 m1n1-plain.bin for T6050 (J716s)

`m1n1-plain.bin` sha256 `7497c0b1dec6ad44595851f172b63ed820b0c4204ee3804bb2e54770006aecc7`,
0x400000 bytes, banner `m1n1 v2.0.0-70-gccbb51bc`.

## Tree

`tree/` is a clone of `~/Work/m1n1`, branch `m1n1-r2`:

| commit | what |
|---|---|
| `459a3af2` | m5-t6050 as used for R1 (upstream 7cde7d1a + our patches 0001-0015) |
| `01cf956d` | + `patches/0017-kboot-keep-the-notch-rows-with-chosen.asahi-show-not.patch` (diff identical to `contrib/pending/integration/patches/m1n1/0017`) |
| `ccbb51bc` | + `patches/0018-usb-pd-t6050-power-up-the-HPMs-with-bounded-SPMI-and.patch` (HEAD, tree `9edaae86`) |

To integrate: keep the series 0001-0015 as is (0005 stays; 0018 undoes its hunk in `usb.c`),
then `git am` 0017 and 0018. Checked: `git am` of both on a fresh clone at 459a3af2 gives the same
tree object as `tree/` HEAD.

## Toolchain (same recipe as the R1 binary)

Apple `container` CLI 1.6.1, image `docker.io/library/fedora:43` (local id f01112b9a1f1), arm64:

- clang 21.1.8 (Fedora 21.1.8-6.fc43), LLD 21.1.8, llvm-21.1.8-6.fc43
- rustc 1.99.1 (58cf8f9c3 2026-10-13), cargo 1.99.1, target `aarch64-unknown-none-softfloat` + `rust-src` (rustup pinned to 1.99.1)
- GNU Make 4.4.1, ImageMagick 7.1.2.34, python3, git

## Steps

```
~/Work/agents/m1n1-r2/build.sh        # ~3 min, writes build/
cp build/m1n1-plain-r2.bin m1n1-plain.bin
python3 -I mk-r2-payloads.py          # writes R2-*.bin and SHA256SUMS
```

`build.sh` starts container `m1n1r2build` with `tree/` mounted at `/src` and `build/` at `/out`,
runs `dnf install clang lld llvm make git python3 rustup ImageMagick diffutils which`,
`rustup-init --default-toolchain 1.99.1 -t aarch64-unknown-none-softfloat -c rust-src`, then for
each of 459a3af2, 01cf956d and m1n1-r2: `git clone /src /build && git checkout <ref> &&
make -j8 CHAINLOADING=0` (no RELEASE, so the framebuffer console stays on), copying
`build/m1n1.bin`. The cargo step fetches crates and rust-fatfs at the revision pinned in the tree.

This is the recipe from the 2026-11-04 session that built `~/Work/m1n1-linuxbuild/m1n1-plain.bin`
(it cloned `~/Work/m1n1` HEAD). The draft script it used is gone from the scratchpad; the recipe
was recovered from that session's transcript.

## Verification

| check | result |
|---|---|
| baseline 459a3af2 rebuilt with this recipe | `742c59817f39cd0f2ab2cce50db347d8ad951d6848f56e492987c66d9c4b11a9`, **byte-identical to the R1 m1n1-plain.bin** |
| notch only (01cf956d) | `77ecc5bbe0d2e327a061d38de1b58332ad82476e009c73ea1ad3f534e5e28c27` (build/m1n1-plain-notch.bin, fallback) |
| r2 (ccbb51bc) | `7497c0b1dec6ad44595851f172b63ed820b0c4204ee3804bb2e54770006aecc7` |
| size | all three 0x400000 (4194304), so the payload offset (`_payload_start`) is unchanged |
| compiler warnings | none in `build/m1n1-plain-r2.log` |
| clang-format (tree's .clang-format) | clean on the changed .c/.h files |
| version banner (`strings`) | `##m1n1_ver##v2.0.0-70-gccbb51bc` |
| new strings present | `display: keeping the notch rows (chosen.asahi,show-notch=1), %lux%lu`, `usb: %s: USB-PD controller in S0, IRQs masked`, `tps6598x: power state %u -> 0 (S0)`, `tps6598x: timed out selecting SPMI register 0x%x`, `spmi: stale RX FIFO did not drain` |
| payload parser still takes `chosen.*` | `src/payload.c` unchanged from 459a3af2 (`git diff --stat 459a3af2 HEAD -- src/payload.c` empty; only `kboot.c` changes, by 0017, which reads the existing `chosen_params[]`); `chosen.` and `FDT: couldn't set chosen.%s property` strings still in the image |
| payloads | `mk-r2-payloads.py` (copy of `integration/r1/mk-r1-payloads.py`; only M1N1, OUT and the payload list changed) verified each layout piece and the single-gzip-member checks; R2-A/R2-B are byte-identical to R1-D/R1-E from offset 0x400000 on (only the m1n1 differs) |

Inputs are the R1 ones, hashes unchanged (see `SHA256SUMS`): `integration/build/r1/{Image.gz,
t6050-j716s.dtb,t6050-j716s-usbhost.dtb}`, `omarchy-m5/build/initramfs-debug.cpio.gz`.
Bootargs (both): `earlycon=efifb keep_bootcon console=tty0 loglevel=8 pd_ignore_unused
clk_ignore_unused no_console_suspend nvme_apple.flush_interval=0 m5.root=/dev/nvme0n1p5`, then
`chosen.asahi,show-notch=1`.

## 0018 in short

The "USB-PD setup" in 160b644c is not a T6050-specific sequence: it is upstream's generic HPM
power-up in `usb_init()` (`SSPS` to S0, mask and clear the IRQs, for every `hpmN` with
`usbc,sn201202x,spmi` on an `aapl,spmi` bus), which that tree does not skip on T6050, made
hang-proof by aurora-silicon's bounding commits (89927e5f, 1bbfce33, 3e52d9f1, 6aa43a58,
a8848d62, ccd41355). `usb_init()` runs in `kboot_boot()` before every kernel handoff in both trees,
so the stage-2 payload boot is where it takes effect. Everything is ADT-driven: no register
offsets or SPMI SIDs are hardcoded, so J714c and J716s differ only in what the ADT lists. J716s
runtime ADT: `nub-spmi-a0` (gen 4) has hpm0 (SID 0xc, port 1, left back), hpm1 (SID 0xa, port 2,
left front), hpm5 (SID 0x8, class 0x0b, port-type 0x11, the MagSafe controller); `nub-spmi-a1`
(gen 4) has hpm2 (SID 0xc, port 3, right). All four are matched (index < USB_IODEV_COUNT = 8), the
same as 160b644c does on J714c. (Physical labels from `agents/usb/REPORT.md`, which marks them as
partly guessed.)

160b644c itself is "kboot: GPU handoff for T6050" on edimoldovan/m1n1 `t6050-aurora` (the Omacom
m1n1 lineage; the commit is not on github.com/omacom/m1n1's branches). The PD behaviour is that
tree's state at 160b644c, not that commit's diff.

Not ported: the T6050 USB 2.0 host prep (65bbd8b6..103ab882, `usb_t6050_host_prep()` before the
jump). It is PHY/dwc3 setup for a kernel without a T6050 usb2 PHY driver; our usbhost DTB has
`apple,t6050-usb2phy` and does that in the kernel.

## R2-C / R2-D: + 0019 (dart-pmp0 DAPF), 2026-11-06

| commit | what |
|---|---|
| `d5b29b03` | + `patches/0019-dapf-add-the-T6050-PMP-DART-dart-pmp0.patch`: port of edimoldovan/m1n1 `fc277aa1be` (author kept, AI-assisted note and both Co-Authored-By lines kept). Our two-field `dapf_entries[]` has no alias/FDT gating, so `dapf_init_all()` in `kboot_boot()` programs `/arm-io/dart-pmp0` (reg[1] `0x2841b0000`, 31 slices) on every stage-2 boot. Table reflowed one entry per line (clang-format clean). |

`build.sh` now builds four refs; 459a3af2, 01cf956d and ccbb51bc reproduce `742c5981...`,
`77ecc5bb...` and `7497c0b1...` byte for byte, and m1n1-r2 HEAD gives
`build/m1n1-plain-r2-pmpdapf.bin` = `m1n1-plain-pmpdapf.bin`:
`2c46317d123e3fdf0cd33228614835612a55d49b953bb4cec9ec0abbed9db177`, 0x400000 bytes, banner
`##m1n1_ver##v2.0.0-71-gd5b29b03`, 0 compiler warnings, string `/arm-io/dart-pmp0` present.

`mk-r2-payloads.py` takes a per-payload m1n1 now; R2-A/R2-B regenerate byte-identical.
`R2-C-usbhost-battery-pmpdapf.bin` (R2-B's DTB and args) `3a95fb4c...`,
`R2-D-olddtb-battery-pmpdapf.bin` (R2-A's) `59f24efb...`; both byte-identical to R2-B/R2-A from
0x400000 on. Sums: `SHA256SUMS` (all four) and `SHA256SUMS-r2cd`. Copied with `SHA256SUMS-r2cd`
to iCloud `m5pro-r1/`.
