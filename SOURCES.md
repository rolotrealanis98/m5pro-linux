# Pinned sources

Everything the M5 was booted with on 2026-10-20, by exact revision.

| Source | Revision | Where it lives on the Studio |
|---|---|---|
| m1n1 (github.com/AsahiLinux/m1n1) | `main` @ `7cde7d1a` + `patches/m1n1/` = branch `m5-t6050` @ `549ec7c1` | `~/Work/m1n1` |
| omarchy-m5 (github.com/betizzel/omarchy-m5) | `main` @ `15cd70c` + `patches/omarchy-m5/` = branch `j716s` @ `16837f2` | `~/Work/omarchy-m5` |
| Linux (github.com/AsahiLinux/linux) | `asahi-wip-7.2` @ `236788cd2602` + omarchy-m5 `patches/linux/0001-0009` = branch `m5-t6050` @ `666335fea5e3` | `~/Work/omarchy-m5/vendor/linux` (worktree of `~/linux`) |
| Kernel config | `defconfig asahi.config omarchy-bringup.config omarchy-storage-net.config omarchy-smc.config` | built with `GCC=1 scripts/build-kernel.sh` |
| Kernel release | `7.2.2-01023-g666335fea5e3` | `vendor/linux/arch/arm64/boot/Image.gz` |
| Initramfs userland | Alpine minirootfs 3.21.3 aarch64 (sha256 checked against Alpine) | `build/initramfs*.cpio*` |
| Root filesystem | Arch Linux ARM aarch64 tarball of 2026-08-05 (GPG signature checked, key 68B3537F39A313B3E574D06777193F152BDBE6A6) | `build/rootfs/m5root.img.gz` |
| macOS on the M5 | 27.2 build 26B5112a (a 26B118 update is staged, not installed) | — |

## Toolchain on the Studio

- clang 23.1.3 for m1n1; GCC for the kernel (no `ld.lld` installed).
- rustup 1.98.1 with `rust-src` and the `aarch64-unknown-none-softfloat` target (kernel needs rustc >= 1.96).
- bindgen 0.72.1. Python 3.14 venv at `~/Work/m1n1/.venv` with pyserial, construct, asn1.
