# DRAFT, NOT APPROVED: encrypt the J716s root (p5)

**DRAFT. Only the owner (Rolando) may approve and run this. No agent runs any step. It rewrites the live root: data-loss risk.**
Nothing in this folder performs it; the build and test tools only touch files, loop devices of their own, and QEMU.

## Gate: do not start until all of these are recorded as PASS
1. encryption-1 (userspace scratch test on the Mac): PASS, incl. keyboard-is-builtin check and the foreign-token refusal.
2. encryption-2 (reboot test, `m5.crypt_selftest=`): the initramfs unseals a scratch LUKS image file with the real SEP in
   the `keystore_only` phase, boot continues, Touch ID back after `complete_attach`. (Not written yet: write after 1.)
3. encryption-3 rehearsal: root-in-a-file. A LUKS2 image file on the plain root holding a copy of the system is booted as the
   real root (initramfs opens it, owner types the passphrase on the keyboard, SEP path once, desktop, sudo, Touch ID, reboot,
   rollback by `boot.bin.prev`). Not built yet.
4. Backup verified (below) and the rescue payload boots on this machine.

## 0. Facts to measure first (read-only)
`lsblk -b`, `sgdisk -p /dev/nvme0n1`, `blkid`, `df -B1 /`, `tune2fs -l /dev/nvme0n1p5` (UUID, size), `cat /etc/fstab`
(root source), the current `boot.bin` and `boot.bin.prev` hashes. p5 is ~175 GB; used space unknown here.

## 1. Backup (nothing changes on the Mac)
- File-level: from the Studio over the gadget, `rsync -aHAX --numeric-ids` of `/` (excluding /proc /sys /dev /run /tmp) into
  `~/PlaybackBench`-style workbench is NOT for this; use `/Volumes/m5pro/bench/backups/m5root-<date>/` (never deleted).
- Block-level (preferred for rollback): `sudo dd if=/dev/nvme0n1p5 bs=16M status=progress | ssh studio 'pv > p5.img'` from a RAM-only
  rescue boot (p5 not mounted), `sha256` both sides. Gadget link is ~USB 2 speed: compute hours for the used size first;
  `e2image -ra`/`partclone.ext4` (used blocks only) if the image tools are in the rescue initramfs.
- LUKS header backup after step 3, copied OFF the Mac. Also record: root UUID, PARTUUID of p5, current fstab.
- Keep `boot.bin.prev` (plain-root initramfs) untouched until step 6 is accepted; it cannot unlock LUKS.

## 2. Rescue payload (RAM only)
A payload whose initramfs is `init.v4` with `m5.root` unset (stays in the shell, sshd up) and cryptsetup, e2fsck, resize2fs,
rsync present (add to the overlay; resize2fs/rsync are not in it today). Boot it self-reverting (`m5.selftest=1`).

## 3. Convert (two options; recommend A)
**A. Backup, then in-place reencrypt (offline, from the rescue payload).**
1. `e2fsck -f -y /dev/nvme0n1p5`; `resize2fs /dev/nvme0n1p5 <size - 64M>`; fsck again.
2. `cryptsetup reencrypt --encrypt --type luks2 --cipher aes-xts-plain64 --key-size 512 --reduce-device-size 32M
   --resilience checksum --pbkdf argon2id /dev/nvme0n1p5` with a strong passphrase typed on the keyboard (not a file).
   Interrupted? `cryptsetup reencrypt --resume-only` (journaled). Power must stay on (battery > 50%, charger in).
3. `cryptsetup luksHeaderBackup` -> copy off the Mac. Open it, `e2fsck -f`, compare a tree checksum against the backup.
**B. Restore into a fresh container** (cleaner, slower): `luksFormat` p5, mkfs.ext4, restore the file-level backup,
fix fstab/boot entries. The partition UUID stays; the ext4 UUID changes: fstab must follow.

## 4. Enroll and finish
`aurora-sep-cryptenroll /dev/nvme0n1p5` from the running system (needs the loaded apple_sep; the plain system can do it once it
boots encrypted by passphrase); recovery key (`aurora-sep-fde recovery --offline`), printed and stored off the Mac.
fstab root = `/dev/mapper/m5root` or the inner ext4 UUID. Install the `touchid-up` complete_attach change first.

## 5. Payload
Build the encrypted-root initramfs with the key store copies for the running kernel
(`tools/build-initramfs.sh --kbuild <kbuild> --keystore <dir>`), `m5.root=PARTUUID=<p5>` (container), pack with mk-daily
(`m5.selftest=1` first: wdt bites to `boot.bin.prev` which will NOT unlock LUKS: acceptable only if the rollback below is ready).
60 s idle after the ESP write before reboot (boot-and-recovery.md). First boot attended: type the passphrase.

## 6. Rollback
- Before step 3 finished: nothing to undo; restore `boot.bin.prev`.
- After A/B: `cryptsetup reencrypt --decrypt` from the rescue payload (needs the passphrase), or restore the block image from step 1.
- A payload with `m5.crypt=off` is for diagnosis only: it leaves the container closed.
- Keep the backup until two weeks of use, then the owner decides (nothing on /Volumes/m5pro is deleted by agents).

## Open risks
keyboard prompt untested on hardware; SEP initrd phase untested on J716s; `boot.bin.prev` cannot unlock; ESP key-store copy;
payload size on a 0.5 GB ESP (initramfs +5 MB measured, +1.3 MB module); rescue payload lacks resize2fs/rsync today.
