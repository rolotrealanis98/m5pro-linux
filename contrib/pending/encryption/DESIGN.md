# storage.encryption: LUKS2 root on the J716s (design)

Status 2026-11-23: built and tested in QEMU (initramfs logic only); nothing run on the J716s yet. Nothing here encrypts or
formats anything: the live root stays plain ext4 until the owner approves DRAFT-MIGRATION.md.

## Decision: LUKS2 on ext4 now, btrfs + Omarchy's layout later
- Boot chain today: stage 1 (m1n1) -> aura stage 2 from the ESP (p4, FAT, unencrypted) = m1n1 + Image.gz + dtb +
  one-gzip-member initramfs -> `m5.root=` ext4 on p5 -> `switch_root`. The initramfs is busybox/Alpine 3.22 (`init.v3`
  from contrib/pending/fsck), no systemd, no modules, no udev.
- omarchy-mac-boot assumes U-Boot -> Limine -> UKI with a systemd initrd, a 2 GiB Boot ext4 partition, a btrfs root and
  `omarchy-mac-encrypt` (in-place `cryptsetup reencrypt --encrypt --reduce-device-size 32M` with a key file on Boot, journaled,
  rekeyed afterwards). None of that is on this chain (no Boot partition, no UKI), and btrfs.ko is a module here.
  Following it means the installer work (contrib/pending/installer/PLAN.md phase 5), not an in-place change.
- So: LUKS2 container on p5 with the existing ext4 inside, unlocked by `init.v4` (v3 plus a bounded LUKS stage). Same
  `fsck`, same `m5.root=PARTUUID=` resolver (it names the container, the mapper carries the ext4). btrfs + snapper stays a
  separate, later conversion (fresh install, not `btrfs-convert` on the daily root), and when it lands the LUKS layer
  does not change.

## Layers
`p5 (PARTUUID) -> LUKS2 (aes-xts-plain64, argon2id passphrase slot + aurora-sep token slot [+ recovery key]) -> /dev/mapper/m5root -> ext4`

## Keyboard in the initramfs
- Internal keyboard = DockChannel HID: `APPLE_DOCKCHANNEL=y`, `HID_DOCKCHANNEL=y`, `HID_APPLE=y`, `VT`/`INPUT_EVDEV=y` are
  built in (kbuild-xdr config): **no module to carry**. It needs the MTP firmware `lib/firmware/apple/tpmtfw-j716s.bin`
  (81 KB), already in the v3 base and kept in v4. Without that file there is no keyboard and no prompt.
- `m5c_kbd_wait` waits (20 s) for an input device with the `kbd` handler and logs its name before prompting.
  A kernel that makes any of those `=m` breaks the prompt: the config check in encryption-1 and the request for the first
  reboot test must name the config.
- Second input path: the USB gadget (EEM) + dropbear already in v3. `ssh root@10.55.0.2 m5-unlock` types the passphrase
  from the Studio when the keyboard fails. This makes a dead keyboard recoverable, not a brick.
- Kernel needs built in: `DM_CRYPT=y`, `CRYPTO_XTS/AES(_ARM64_CE_BLK)=y`, `CRYPTO_USER_API_AEAD/SKCIPHER/HASH=y`, `CRYPTO_CCM=y`,
  `KEYS`, `TRUSTED_KEYS=y`, `BLK_DEV_LOOP=y` (all =y in kbuild-xdr; `DM_CRYPT` was missing from older j716s fragments). `APPLE_SEP=m`.

## Unlock order (`initramfs/m5-crypt.sh`, all bounded)
1. Device is LUKS (`cryptsetup isLuks`, read-only) and `m5.crypt` is not `off`; otherwise v3 behaviour exactly.
2. If the header has an `aurora-sep` token: `insmod apple-sep.ko keystore_only=1 xart_writes=0 provision_keybag=0 xart_guard=1`
   (+ `apple_sep.*` words from the cmdline, the OS-identity pin), key store copies in `/var/lib/aurora-sep-*.bin`;
   then `cryptsetup open --token-only --token-type aurora-sep` (plugin waits up to `m5.crypt_sep_wait`, default 45 s).
   The module is only loaded when a token exists, so a passphrase-only LUKS never changes SEP behaviour.
3. Else/after: console prompt, 3 tries x 120 s; a password-mode (FileVault-model, `aurora-sep-fde`) token takes the typed
   secret as its PIN. Between tries `/dev/mapper/m5root` is checked, so `m5-unlock` over ssh also works.
4. Failure: LUKS device untouched, init falls into the existing "staying in initramfs" shell + dropbear; with
   `m5.selftest=1` the watchdog still bites after `m5.wdt_diag` seconds and stage 1 reverts to `boot.bin.prev`.

## SEP-sealed unlock, honestly
- Token = AES key sealed by the SEP (trusted key) wrapping a keyslot secret; password fallback slot always stays.
  Bound to this Mac + the Linux OS identity (`apple_sep.os_uuid_*`); no PIN/Touch ID binding, no boot measurement.
- Needs the key store copies in the initramfs (`aurora-sep-keybag.bin`, `-refkey.bin`): they sit on the unencrypted ESP.
  Only usable by this SEP under this identity; same exposure as `/var/lib` on today's plain root. `boot-chain=audit` default.
- Kernel side exists (`keystore_only`, `complete_attach` in apple-sep.ko of kbuild-xdr) but **has never run on a J716s**.
  First real test = encryption-2 (reboot, scratch file image, `m5.crypt_selftest=`). Initramfs phase is read-only toward xART;
  if an unseal needs an xART write it fails and the passphrase prompt appears.
- Root side: after a `keystore_only` boot, the real root must write `complete_attach` or Touch ID stays off for that boot.
  `rootside/touchid-up.v2` (full replacement script; not applied; contrib/pending/touchid-omarchy is not edited here).
- Coupling: the initramfs carries apple-sep.ko for ONE kernel release (`/lib/modules/apple-sep.release`); every kernel
  change needs a rebuilt initramfs (`tools/build-initramfs.sh --kbuild <kbuild>`). A mismatch only disables the SEP step.

## Recovery if unlock fails
| Failure | What happens | Way out |
|---|---|---|
| SEP refuses / identity changed / key store stale | passphrase prompt | type passphrase |
| keyboard dead | prompt unusable | `ssh root@10.55.0.2 m5-unlock` over the gadget |
| both | stays in initramfs shell (sshd up) | Studio over gadget: unlock by hand; watchdog (selftest boots) reverts to `boot.bin.prev` |
| bad initramfs | no unlock | stage 1 reverts / `boot.bin.prev` (plain-root initramfs) works because it ignores LUKS (`m5.root` would still point at the container: so DO NOT let `boot.bin.prev` age past the migration; see DRAFT) |
| header damaged | | LUKS header backup (taken before migration, kept off the Mac) |
| passphrase lost | data lost | recovery key (`aurora-sep-fde recovery`, offline slot) stored off the machine |

## Not covered
Plymouth/graphical prompt (text console only), btrfs, TPM-style PCR measurement, hibernate/resume to an encrypted swap,
suspend-to-RAM key handling (deep sleep keeps the mapping in RAM as on any dm-crypt system), ESP/payload integrity (the payload is not
encrypted or signed by this change).

## Watchdog during the prompt
- Stage 1 arms a 150 s watchdog (`m1n1.wdt=keep`). In init.v3 it is handled only with `m5.selftest=1` (the opener pets `/dev/watchdog0`
  from init, `m5wdt_release` hands it over without the magic close, `m5.wdt_diag` bounds a failed boot at 600 s).
- Without selftest nothing in init opens it. The kernel does the feeding: `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y`,
  `CONFIG_WATCHDOG_OPEN_TIMEOUT=0` (kbuild-xdr) make the watchdog core ping a running watchdog until userspace opens it, with no
  deadline. So an idle prompt should NOT reset the Mac, but that is a reading of the config, not a hardware observation:
  encryption-2 phase B measures it (a non-selftest boot idling at the prompt for 200 s > 150 s). A reset there is harmless
  (stage 1 falls back to `boot.bin.prev`) but means the premise is wrong and init must pet it itself.
- init.v4 adds no feeding of its own. Selftest boots are covered by the existing opener (it keeps petting through the prompt;
  the unlock budget is bounded at 45 s SEP wait + 3 x 120 s, after which the existing `m5.wdt_diag` bite applies). It stops
  petting at hand-over exactly as before (`m5wdt_release`), the crypt code never opens the device itself.
- If phase B shows a reset: add an opener to `m5c_open` (start before the SEP wait, release before `switch_root`) reusing `m5wdt_*`.

## Past incident: scratch-test.sh and the live /dev (2026-11-23)
The first encryption-1 script `--rbind` mounted the Mac's real `/dev` (and `/sys`) under its chroot and its cleanup did not unmount
them (`umount` without `-R`, errors hidden). The request's cleanup `rm -rf /var/tmp/m5-enc1` then removed every device node of the
live `/dev` and the contents of `/dev/shm`; the Mac needed a reboot. Rules now, enforced in `scratch/m5-chroot.sh` and used by every
script handed over:
1. All chroot mounts live in a private mount namespace (`unshare -m --propagation private`): they disappear when the script exits,
   even if cleanup fails.
2. The real `/dev` is never mounted into a chroot: a private tmpfs `/dev` with copies of null, zero, urandom, random, tty, full,
   loop-control, the loop devices and `mapper/control`; `/sys` is a non-recursive bind, `/proc` and `/run` are fresh.
3. Teardown unmounts deepest first, lazily as a fallback, and verifies with `/proc/self/mountinfo` that nothing is left.
4. Nobody is told to `rm -rf` a scratch tree: `scratch/safe-rm.sh DIR` refuses unless nothing is mounted under DIR and DIR is under
   `/var/tmp/m5-*` or `/var/lib/m5-enc*`.
5. Reviewed for the same hazard: `init.v4` and `m5-crypt.sh` (initramfs only: no `rm -r`, `umount` only of their own mounts, a
   `mount --move` of the plain root in rootfile mode), the QEMU harness (files under bench/), the build scripts (containers, bench/).
   The old bundle `/Volumes/m5pro/bench/encryption/mac/` is superseded (its script is replaced by an abort stub); use `mac2/`.
   The m5-chroot logic was exercised with real mounts in a privileged Alpine container (refuses while mounted, teardown verified,
   outer namespace clean); the scripts as a whole were NOT run on the Mac since the incident.

## Rehearsal modes in init.v4 (for encryption-2/-3)
- `m5.crypt_selftest=<path>` (+ `m5.crypt_selftest_prompt=1`): unlock a scratch LUKS2 FILE on the plain root before switch_root;
  token phase unattended, prompt phase (SEP forced off) with the owner typing on the built-in keyboard. Result in `/var/log/m5-crypt-selftest.log`.
- `m5.crypt_rootfile=<path>`: root-in-a-file. Unlock the file (token, then prompt), mount its ext4, `mount --move` the plain root to
  `/outer`, `switch_root` into the file. Any failure boots the plain root. QEMU tests T1-T9 cover both (12/12).

## Key store freshness (found 2026-11-23: the keybag's mtime moves at every boot)
- `/var/lib/aurora-sep-keybag.bin` (1612 B) is rewritten by apple_sep each boot (its mtime equals the host-state file's); refkey.bin is
  stable (Nov 17). Whether the CONTENT changes is not known: keybag.rs rewrites a record with state/intent fields and a CRC, so the file can
  change with the wrapped bag unchanged. The upstream design only warns (`aurora-sep-initrd-check`: "rebuild the initramfs").
- A stale copy might still unseal (the SEP recovers the bag from the wrapped data it is handed) or might not. Not designed on hope:
  1. Source of truth for the initramfs = the ESP directory `m5sep/` (`m5.esp=`, default `/dev/nvme0n1p4`, mounted read-only for the copy),
     NOT the payload. `rootside/m5pro-sep-keystore-sync` (+ `.service`, `.path`) copies the files there whenever they differ (after touchid-up
     and on every change of the files), atomically. The embedded copy (build time) is only the fallback if the ESP is unreadable.
  2. Every unlock logs which source and the sha256 prefix of each file (`key store (esp|embedded): name hash size`), so a stale-copy failure is
     distinguishable from a SEP refusal. encryption-2 compares those hashes with the Mac's files just before the reboot.
  3. If the unseal still fails with a fresh copy, the passphrase prompt is the designed fallback; nothing is lost.
- Security: the keybag record holds the bag secret (apple-sep.rst: "secret state"). On the ESP and in the payload it is as exposed as
  `/var/lib` on today's plain root, and once the root is encrypted it is MORE exposed than the root would be (the point of encrypting).
  It only helps someone who can also talk to THIS Mac's SEP under this Linux identity. That is the same trust model as TPM-without-PIN
  and as upstream's initrd design; the owner must accept it explicitly (DRAFT-MIGRATION.md gate).
