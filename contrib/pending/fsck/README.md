# Root file system check at boot (J716s initramfs)

The bring-up initramfs (`initramfs-ftab-wdt2`, Alpine/musl) mounted `m5.root` directly and had no `e2fsck`, so the
ext4 errors logged since 2026-11-08 ("mounting fs with errors, running e2fsck is recommended", online resize refused)
were never repaired.

`init` here adds, before the mount:
- `e2fsck -p` (preen) every boot, as distros do: instant on a clean file system, repairs what is safe unattended.
- `m5.fsck=force` on the command line: one `e2fsck -f -y` pass. `m5.nofsck` skips the check.
- Bounded by `timeout 600`; the result goes to `/var/log/m5-fsck.log` (exit code: 0 clean, 1 repaired, 4 needs a manual run).

`e2fsck` 1.47.2 and its libraries come from Alpine 3.22 aarch64 `e2fsprogs` (musl, same as the initramfs). Tested in a
container: chrooted into the initramfs, preen and forced passes on a scratch ext4 image, `sh -n init`. Not booted yet.
Packed boot files: `next4b-everyday-fsck-*` and `next4b-fsck-force-*` (`/Volumes/m5pro/bench/pr-verify/`), via
`NEXT_IR` in `m5pro-linux-re/tooling/pr-verify/mk-next-test.py`.
