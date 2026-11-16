# Root file system check at boot (J716s initramfs)

The bring-up initramfs (`initramfs-ftab-wdt2`, Alpine/musl) mounted `m5.root` directly and had no `e2fsck`, so the
ext4 errors logged since 2026-11-08 ("mounting fs with errors, running e2fsck is recommended", online resize refused)
were never repaired.

`init` here (the final init of the five-archive initramfs; v1 kept only the first archive and is not to be used) adds, before the mount:
- `e2fsck -p` (preen) every boot, as distros do: instant on a clean file system, repairs what is safe unattended.
- `m5.fsck=force` on the command line: one `e2fsck -f -y` pass. `m5.nofsck` skips the check.
- Bounded by `timeout 600`; the result goes to `/var/log/m5-fsck.log` (exit code: 0 clean, 1 repaired, 4 needs a manual run).

`e2fsck` 1.47.2 and its libraries come from Alpine 3.22 aarch64 `e2fsprogs` (musl, same as the initramfs). Tested in a
container: chrooted into the initramfs, preen and forced passes on a scratch ext4 image, `sh -n init`. Not booted yet.
Packed boot files: `next4b-everyday-fsck-*` and `next4b-fsck-force-*` (`/Volumes/m5pro/bench/pr-verify/`), via
`NEXT_IR` in `m5pro-linux-re/tooling/pr-verify/mk-next-test.py`.

## v3: `m5.root=` by name (PARTUUID / LABEL / UUID)

`init.v3` is `init` (v2) plus a resolver, so root can be named instead of numbered. The GPT on this disk is unsorted and
Apple's or Windows' tools may renumber it; `m5.root=/dev/nvme0n1p5` would then mount the wrong partition or none.

- `m5.root=PARTUUID=<guid>` (case-insensitive, with or without dashes): busybox `findfs`/`blkid` know no PARTUUID, so
  `m5_partno` reads the primary GPT itself (sector size from sysfs, header at LBA 1, entries from the header's LBA, count
  and size from the header), finds the entry whose unique GUID matches, and `m5_resolve` maps entry N to the kernel's
  partition N (`/sys/class/block/<disk>/*/partition`). Whole disks only; `loop`, `ram`, `zram`, `dm-`, `md`, `nbd` are skipped.
- `m5.root=LABEL=<label>` / `UUID=<fs uuid>`: `busybox findfs` (probes `/proc/partitions`, no udev). No spaces in a label.
- Bounded wait: the resolver is tried at once and then once a second inside the existing 30 s wait loop (the ANS rebind
  logic is untouched), so a disk that appears late is found; the root check, fsck and mount then use the resolved `/dev` path.
  On failure the old "did not mount after 30 s; staying in initramfs" diagnostics run, naming the spec.
- `m5.root=/dev/...` (or anything else): byte-for-byte the old behaviour; the resolver is not called.
- Logs `debug: <spec> is <dev>` on the console and `m5-root: ...` in `dmesg`.

`initramfs-ftab-wdt2-fsck-v3.cpio.gz` (in `/Volumes/m5pro/bench/fsck/`) is v2 with only the `init` entry replaced (the
cpio is rewritten entry by entry, so every other header, mode, owner, device node and byte is identical: 551 entries,
`init` differs, size 11538 -> 15005). Not booted. Tested offline in an Alpine 3.22 aarch64 container with the same
busybox 1.37 and a synthetic unsorted 4096-byte-sector GPT on a loop device with partition scan: all six PARTUUIDs (upper
and lower case) resolve to the kernel's partition of the same number, as do LABEL and UUID; unknown GUID/label and a
missing `/dev` path wait out the bound and leave `ROOT` unresolved; `busybox sh -n init` passes. The container cannot
mount, so the mount/`switch_root` tail was not run.

Use: `m5.root=PARTUUID=<root partition PARTUUID>` (read it with `blkid /dev/nvme0n1p5` on the running system, or
`sgdisk -i 5`). Pack with `NEXT_IR` in `m5pro-linux-re/tooling/pr-verify/mk-next-test.py` as for v2.
