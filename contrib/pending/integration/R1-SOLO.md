# R1 on the MacBook alone (no Studio, no tether, no SSH)

You need: the MacBook, its power cable, the USB-C Ethernet adapter (step 6), a phone for photos.
Evidence = photos of the panel plus the logs the scripts save on the Linux partition.
Everything below is typed at the MacBook: in macOS (`r1-deploy.sh`) or as root at the Linux console (`r1-local.sh`).

## 0. Copy the files (macOS)
From iCloud Drive `m5pro-r1/` (let every file finish downloading first):
```
mkdir -p ~/Work/m5-r1
cp ~/Library/Mobile\ Documents/com~apple~CloudDocs/m5pro-r1/{R1-*.bin,SHA256SUMS,r1-deploy.sh,r1-local.sh} ~/Work/m5-r1/
cd ~/Work/m5-r1 && chmod +x r1-deploy.sh r1-local.sh
```
`r1-deploy.sh` asks for your macOS login password at the `sudo` prompt (it needs it for `diskutil`). Run it as yourself, not with `sudo`.

The files live in the repo as `host/macos/r1-deploy.sh` and `contrib/pending/integration/r1/r1-local.sh`; payloads and `SHA256SUMS` are built on the Studio (`mk-r1-payloads.py`) and carried over iCloud Drive.

**Mount point on this Mac:** the ESP can mount as `/Volumes/OMARCHY 1` when a stale `/Volumes/OMARCHY` mount point exists. In that case mount it yourself (`sudo diskutil mount disk0s4`) and give the script the path, which it then treats as already mounted and leaves mounted:
```
export ESP_DIR="/Volumes/OMARCHY 1"
./r1-deploy.sh status
```
**Dirty FAT after a Linux reboot:** if Linux was rebooted or powered off without unmounting `/boot`, macOS refuses or mounts the ESP read-only (Linux logs `Volume was not properly unmounted`). Clear it with
```
sudo diskutil unmount disk0s4 && sudo fsck_msdos -y /dev/disk0s4
```
and mount again.

## 1. Look at the Linux partition (macOS)
`./r1-deploy.sh status` shows each `boot.bin*` with its name. Expect `boot.bin` = B2 and `boot.bin.prev` = P3 or known-good.
It mounts the partition (running `fsck_msdos -y` once if the mount fails) and unmounts it again.

## 2. R1-A (about 45 min)
1. `./r1-deploy.sh deploy R1-A-olddtb-gated.bin` (checks the hash against `SHA256SUMS`, refuses on mismatch; `boot.bin.prev` is left alone).
   It also puts `r1-local.sh` at the root of the Linux partition.
2. Startup Disk (or hold power at boot) -> the Omarchy stub, restart.
3. Log in at the console as root, then: `bash /boot/r1-local.sh a`
   - If `/boot/r1-local.sh` is missing: `mount /dev/nvme0n1p4 /boot` and retry.
   - It asks you to watch the keyboard backlight (answer y/n) and to close then open the lid within 15 s (only if `evtest` is installed; the script blocks lid-suspend while it runs). `--quick` skips all questions.
   - `ufw`/`zram` lines show FAIL or SKIP if the Arch root lacks `ufw`/`zram-generator` and there is no network to install them: that is an answer, not a problem.
4. **Photograph the framed `====` summary block.** Then `systemctl reboot` and confirm it comes back to the login (photo of the kernel line: `uname -r`).
5. `systemctl poweroff`, hold power -> Macintosh HD, then `./r1-deploy.sh logs` (copies the ESP's `r1-logs` into `~/Work/m5-logs/r1-logs`). Do this on every macOS visit.

## 3. R1-B battery trace (about 30 min)  only if R1-A booted
1. `./r1-deploy.sh deploy --rotate R1-B-olddtb-battery-trace.bin` (`--rotate` makes the booted R1-A the new `boot.bin.prev`). Set the Omarchy stub, restart.
2. Put the phone on the panel, recording, **before** you restart. At about 7-8 s the panel prints lines like
   `macsmc-power macsmc-power: trace: rd B0AV size 4` (`rd`/`wr`/`info` + SMC key) and step lines (`probe start`, `registering the battery`, `probe done`).
3. Boots: `bash /boot/r1-local.sh b`. Unplug then replug MagSafe when asked. Photograph the summary, `systemctl reboot` twice (it must come back both times).
4. Hangs (panel frozen):
   1. Photograph at once: the last `trace:` line names the key. Wait 60 s, photograph again (lockup/stall text, or nothing).
   2. Hold power about 10 s until off, hold power again -> Macintosh HD.
   3. `./r1-deploy.sh restore` (puts `boot.bin.prev` = R1-A back as `boot.bin`), Startup Disk -> Omarchy, restart. Booting macOS once also clears the PMU boot-error counter; without it the next Linux boots count as failed.
   4. Do not retry R1-B: a second try needs a payload rebuilt on the Studio. Battery stays off until the next round.

## 4. R1-C USB host (about 35 min)
1. Plug the USB-Ethernet adapter into the **left-front** port, then `./r1-deploy.sh deploy R1-C-usbhost-gated.bin` (no `--rotate`), Startup Disk -> Omarchy, restart. Boot with the adapter attached; a power meter between port and adapter, if you have one, should read about 5 V (0 V = no VBUS on that port).
2. `bash /boot/r1-local.sh c`: unplug the adapter, then plug it into left-rear, left-front and right in turn when asked (press Enter each time). Photograph the summary.
3. A USB failure is not a hang risk. Rollback: `./r1-deploy.sh restore`.

## 4b. R1-D / R1-E: battery without the trace (next solo round)
`R1-D-olddtb-battery.bin` (normal DTB) and `R1-E-usbhost-battery.bin` (usbhost DTB) carry the B2 base arguments only: battery driver enabled, no `macsmc_power.trace`, no `panic=0 pause_on_oops=300 ignore_loglevel`. Deploy with `./r1-deploy.sh deploy --rotate R1-D-olddtb-battery.bin` (R1-B booted 3/3, so it is a safe `boot.bin.prev`). Since 2026-11-06 evening `r1-local.sh` has a `d` step (general: passive collection plus battery and USB presence checks, no prompts) and detects a battery-on payload from the command line (`--battery` forces it): `bash /boot/r1-local.sh d` fits R1-D, R1-E and the R2 payloads.

## 5. Finish and send back
- Leave the machine on a payload that boots: `./r1-deploy.sh restore b2` (or `deploy R1-A-olddtb-gated.bin` if you want to keep R1-A). `./r1-deploy.sh status` to confirm.
- `./r1-deploy.sh logs` once more, then zip: `ditto -c -k --keepParent ~/Work/m5-logs ~/Desktop/m5-logs.zip`.
- Send `m5-logs.zip` and all panel photos (summary blocks, the R1-B boot trace, any hang).

## Not possible without the Studio
- Step 0 (A/B stage-1 ceremony and the 150 s watchdog fallback): every hang costs a macOS round trip.
- Step 3 (PMP double dumps) needs the m1n1 proxy on the Studio.
- No live SSH or dmesg streaming, no `cpuhz`/`dvfs-regs` OPP-offset check, no step 5 (s2idle): console, photos and saved logs only.
