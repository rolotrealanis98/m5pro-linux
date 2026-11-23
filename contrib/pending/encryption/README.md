# storage.encryption: staged path to an encrypted root (J716s)

Index. Design: [DESIGN.md](DESIGN.md). Migration of the real root: [DRAFT-MIGRATION.md](DRAFT-MIGRATION.md) (draft, owner approval only).
Nothing here touches the live root; the initramfs variant is built but not installed or booted anywhere.

| Path | What |
|---|---|
| `initramfs/init.v4` | init.v3 + LUKS stage (`m5.crypt=off`, `m5.crypt_selftest=<file>`); a plain root takes the v3 path |
| `initramfs/m5-crypt.sh`, `m5-unlock`, `m5-crypt.conf` | unlock logic (SEP token, console prompt, ssh), gadget-ssh helper, apple_sep options |
| `tools/build-initramfs.sh` (+`in-container.sh`, `mk-chroot-tar.sh`) | v3 base + cryptsetup 2.7.5 (external tokens on) + aurora-sep plugin + apple-sep.ko -> one-gzip-member initramfs (Alpine 3.22 container) |
| `tests/qemu/` | QEMU/HVF test of the whole init flow with the user-key plugin build (token, passphrase, failure, off, plain, selftest) |
| `scratch/` | `scratch-test.sh` (enc-1, passed on the Mac), `enc2-prep.sh`, `enc3-prep.sh`, `m5-chroot.sh` (private-namespace chroot helpers), `safe-rm.sh` |
| `tools/pack-enc.sh` | initramfs with key store + self-reverting boot file for encryption-2/-3 |
| `rootside/touchid-up.v2` | full replacement of the root's touchid-up: finishes the attach (complete_attach) after an initramfs SEP load; unverified sysfs path |

Build: `tools/build-initramfs.sh --kbuild /Volumes/m5pro/bench/pr-verify/kbuild-xdr [--keystore DIR]`; outputs under
`/Volumes/m5pro/bench/encryption/`. QEMU test: build with `--test`, see the script headers.
Upstream read: aurora-silicon/aurora-sep-userspace `luks/`, docs `luks-sep*.md` (clone `/Volumes/m5pro/wt/encryption-src/sep`),
omacom/omarchy-mac-pkgs `omarchy-mac-boot` `omarchy-mac-encrypt`.
