# Rung iii-b runbook: a dedicated macOS 27.3 (26C5035r) volume with m1n1 as its boot object (J716s) — PRIVATE

Written 2026-11-08 on the Studio from PLAN.md sections 0 and 6, `m5pro-linux/contrib/pending/hv/PLAN-27.3.md`,
`m5pro-linux/docs/boot-and-recovery.md`, `host/macos/{refresh-stub-firmware,stage1-install,1tr-stage1}.sh`,
`docs/smp-t6050-raw-path.md`, `contrib/distro/DESIGN.md`, and the Asahi page
https://asahilinux.org/docs/sw/m1n1-hypervisor/ (fetched today). Nothing here has been run. No private values:
`<...>` placeholders are filled in at the keyboard and not written anywhere.

Tags: **[V]** = checked today against the repo notes or against tool help on the Studio (`bputil -h`,
`kmutil configure-boot --help`, `diskutil apfs addVolume|deleteVolume`, `softwareupdate -h`, `csrutil help`; the Studio
is macOS 27.2 26B123, the MacBook is 27.3 26C5035r, so flags can differ). **[U]** = not verified: from memory, from
the Asahi page, or an expected output I cannot confirm. Expected outputs marked [U] are shapes, not exact text.

Actors: **R** = Rolando at the MacBook. **C** = Claude from the Studio, `ssh rolo@<macos-side>` into *Macintosh HD's*
macOS (Tailscale, passwordless sudo via `/etc/sudoers.d/rolo-temp`). **S** = Studio local.

## 0. Read first: corrections to the brief, and what changes who can do what

1. **`bputil -v` takes a Volume Group UUID, not a path.** [V] (`bputil -h`: `-v, --vuid <UUID>`; the UUID comes from
   `diskutil apfs listVolumeGroups`). `bputil -nkcas -v /Volumes/macOS-hv` is wrong. `kmutil configure-boot -v` does take
   a volume path [V].
2. **The stub is not in the main container.** [V] `boot-and-recovery.md`: p2 = macOS container (813.0 GB = 757 GiB),
   p3 = the 6 GB "Omarchy" stub in its *own* APFS container (the `recreate` script's comment calls it disk0s3),
   p4 = EFI, p5 = Linux root, p6 = RecoveryOSContainer, p1 = iBootSystemContainer. So `diskutil apfs addVolume` into the
   main container cannot touch the stub's volumes. Step 3 re-checks this on the live machine before anything is created.
3. **C cannot follow the install onto macOS-hv.** Tailscale, user `rolo` and `rolo-temp` live on Macintosh HD. After the
   installer's first reboot the MacBook is a different OS with only the local user `hv`. Steps 4.2 onward are R at the
   keyboard (C is on the Studio for the HTTP server and the hv session). Optional: R turns on Remote Login on macOS-hv and
   gives C a LAN address for `ssh hv@...`; do not install Tailscale there.
4. **No watchdog or A/B on this path.** [V] The dead-man switch (stage-1 arms WD1; PLAN section 2) is stage-1's job.
   With m1n1 as macOS-hv's own boot object there is no stage-1: the proxy loader waits for a host forever, a wedge is
   power-hold, and nothing falls back to "the daily". The ESP `boot.bin`/`boot.bin.prev` are not involved and not touched.
5. **Do not run `nvram boot-args=-v` (Asahi's step 6).** It is machine-wide NVRAM, and `run_guest.py` passes its own
   boot-args. Skipped on purpose.
6. **Hard rules for the whole run:** never pick Macintosh HD or Omarchy as an install target; never type Macintosh HD's
   or Omarchy's password into macOS-hv; no Apple Account, no Touch ID, no iCloud on macOS-hv; never run
   `run-hv27.sh guest disk` unless the proxy came from macOS-hv (the env gate only checks your word).
7. **Build pin.** Installing a build other than 26C5035r can update machine-wide firmware (LLB/iBoot, possibly SEP) in the
   iBoot System Container (`smp-t6050-raw-path.md`: "the firmware is machine-wide"; the stub's mBoot is a separate,
   per-volume copy). That would break the SPTM/TXM/ExclaveCore files extracted from Macintosh HD and the stub chain's
   assumptions. Same build in, same firmware out is the expectation [U]. Anything else: STOP.

## Time budget (attended; excludes any full backup)

| step | who | estimate |
|---|---|---|
| 1 preconditions + baselines | C (R for the backup disk) | 30-60 min |
| 2 fetch + verify installer (~15 GB) | C | 20-60 min, mostly download |
| 3 create volume | C | 5 min |
| 4 install, Setup Assistant, checks | R | 60-90 min (installer 30-45, 3-4 reboots) |
| 4.5 optional Preboot cross-check from Macintosh HD | R + C | 20 min |
| 5 stage payload + 1TR ceremony | S, R | 30-45 min |
| 6 first boot, smoke, `guest disk` | R + S | 30-60 min to first answer; the guest session itself is open-ended |
| total to the first hv boot of macOS-hv | | about 3.5-5 h |

## 1. Preconditions and backups (C over SSH unless noted)

Goal: record enough to prove afterwards that Macintosh HD, the stub, the ESP and the policies are unchanged, and be able
to rebuild if not. Run from the Studio; keep outputs in `~/Work/agents/hv27/iiib-baseline/` (0700, never committed, they
contain UUIDs and serials).

1.1 Machine state (C):
```
ssh rolo@<macos-side> 'sw_vers; sudo diskutil list; sudo diskutil apfs list; diskutil apfs listVolumeGroups; fdesetup status; csrutil status; sudo bless --info; system_profiler SPHardwareDataType | grep -E "System Firmware|OS Loader"; pmset -g batt'
```
Expected: `ProductVersion 27.3`, `BuildVersion 26C5035r` [V per m5-sysver.txt]; the 813 GB container with Macintosh HD, a ~6 GB
container with the four Omarchy volumes, the EFI partition and the Linux root; `fdesetup status` is the blast-radius
record (PLAN section 5) — write it down; charger connected, battery above 50%. Save the full output.

1.2 Policy baseline (C). `bputil -e` ("display local policies for all OS installations") [V flag, from `bputil -h`; needs
root]. Whether it works from the running macOS or only from recovery is [U]:
```
ssh rolo@<macos-side> 'sudo bputil -e' > iiib-baseline/bputil-all-before.txt
```
If it refuses outside recovery, skip; step 5 takes the same baseline in 1TR (photograph it). Purpose: Macintosh HD and the
stub entries must read identically after step 5 (only a new macOS-hv entry appears).

1.3 Free space: need at least **100 GB free in the main container** (installer app ~15-18 GB on Macintosh HD's Data volume
+ a kept copy + the new System/Data volumes ~30 GB + working space). `diskutil apfs list` -> "Capacity Not Allocated" /
container free. Less than 100 GB: stop and free space; do not resize the container (p3-p6 sit behind it).

1.4 Backups (R decides; PLAN section 5 says none exists):
- A Time Machine backup of Macintosh HD to an external disk before anything else (`tmutil setdestination`,
  `tmutil startbackup`; R at the keyboard, the destination needs R's choice). `tmutil localsnapshot` is not a backup.
- The stub is already backed up on the MacBook (`~/Work/stub-backup-*`, from the 2026-11-04 `recreate`); confirm they exist
  (`ls ~/Work/stub-backup-*`).
- ESP: mount read-only and copy: `diskutil mount readOnly <ESP disk>` then `ditto /Volumes/OMARCHY <Studio-bound dir>`;
  record `shasum -a 256 m1n1/boot.bin m1n1/boot.bin.prev` (expected 26ca25f0... / 5c74c66c... per PLAN section 4 step 1, if
  unchanged). Do not mount the stub volumes read-write (`macos-scan-checklist.md` warns even `check` modes do).
- Studio side: the proxy image, `shasum -a 256 m1n1-build/m1n1-hv27-proxy.bin` must start `3ea65595` and be 4390912 bytes
  (0x430000) [V today]. Also the proven fallback boot objects exist: `~/Work/stage1-serve/plain-small.bin` (0x400000, b2b32375)
  and `boot-plain.bin` (0x4D0000, 5ddf1026).

1.5 macOS still boots: C is connected over SSH, so Macintosh HD is running. After step 4 it is booted once more from the
picker (4.5) as the real test.

1.6 Linux side untouched: nothing in this runbook writes p3-p6. Step 7 re-verifies by booting Omarchy.

1.7 Quiesce (C): `sudo softwareupdate --list` (lists only) — if a newer 27.3 beta than 26C5035r is offered, see 2.4 first.
No pending install on Macintosh HD during the run.

## 2. The 26C5035r installer on the MacBook (C)

2.1 What is offered [V flags]:
```
ssh rolo@<macos-side> 'sudo softwareupdate --list-full-installers'
```
[U] On a seeded Mac the list should include a 27.3 entry; whether a *beta* build appears here depends on the Mac's
seed enrollment. Check the current enrollment read-only: `sudo /System/Library/PrivateFrameworks/Seeding.framework/Resources/seedutil current`
[U path]. **Do not enroll, unenroll or change the seed program on Macintosh HD** to make this work.

2.2 Fetch [V flag text; beta behaviour U]:
```
ssh rolo@<macos-side> 'sudo softwareupdate --fetch-full-installer --full-installer-version 27.3'
```
Lands as `/Applications/Install macOS <name>.app` (~15 GB; 10-40 min). Immediately keep a copy: the installer deletes
itself after one install (Asahi page): `sudo mkdir -p ~/Work/installers && sudo ditto "/Applications/Install macOS"*.app ~/Work/installers/<name>.app`.

2.3 Verify the build (do all; the pass criterion is every string equals `26C5035r`):
```
APP=$(ls -d "/Applications/Install macOS"*.app | head -1)
plutil -p "$APP/Contents/Info.plist" | grep -E 'CFBundleShortVersionString|CFBundleVersion|DTPlatformVersion|LSMinimumSystemVersion'
hdiutil attach -nobrowse -readonly -mountpoint /private/tmp/ss "$APP/Contents/SharedSupport/SharedSupport.dmg"
ls -R /private/tmp/ss | head -40
```
[U layout] then, in what is mounted: the `com_apple_MobileAsset_MacSoftwareUpdate/*.xml` and
`com_apple_MobileAsset_SFRSoftwareUpdate/*.xml` plists (`plutil -p <file> | grep -iE 'build|osversion'`), and the payload
zip's manifest: `unzip -p /private/tmp/ss/com_apple_MobileAsset_MacSoftwareUpdate/*.zip AssetData/boot/BuildManifest.plist | plutil -extract ProductBuildVersion raw -`.
Reference value on this Mac [V idiom, `refresh-stub-firmware.sh`]:
`plutil -extract ProductBuildVersion raw -o - /System/Volumes/Preboot/<MacHD-VG>/restore/BuildManifest.plist` and
`sw_vers -buildVersion`, both 26C5035r. Detach with `hdiutil detach /private/tmp/ss`. The file layout inside the DMG is from
memory; adapt with `find /private/tmp/ss -name '*.xml' -o -name BuildManifest.plist`.

2.4 If the build is not 26C5035r (a newer 27.3 beta, or 27.3 final): **STOP.** Do not install it on the new volume (see
section 0 item 7); decide with R whether the whole rung moves to the new build (re-extract guest files, re-derive
`kc.macho`, new hashes). Apple stops signing old betas, so 26C5035r may no longer be installable at all (section 8, Q2).

2.5 Alternatives, in order of preference: (a) the same command on a Mac that is seeded, copying the app over (`ditto`/`scp -r`);
(b) Apple's developer downloads page, if it offers an installer package for this beta [U: it normally offers restore images
only]; (c) a third-party fetcher such as `mist-cli`, treating the result as untrusted until 2.3 passes [U]. **Not valid:**
the IPSW or an "InstallAssistant" built from it (a restore image is DFU/Configurator material and wipes the machine; Asahi
only uses an archived InstallAssistant.pkg for *released* builds). `createinstallmedia` is not needed: no external media.
Recovery's "Reinstall macOS" is not a way to pin a build [U].

## 3. Create the volume (C)

3.1 Find the main container from Macintosh HD itself [V idiom from `refresh-stub-firmware.sh`]:
```
CT=$(diskutil info / | awk -F': *' '/Part of Whole/{print $2}'); echo $CT
diskutil apfs list "$CT" | head -30
```
Expected: one container of ~813 GB (757 GiB) on `disk0s2`, volumes Macintosh HD / Data / Preboot / Recovery / VM (and
Update). It must NOT be the ~6 GB container. If the size is not ~813 GB: STOP.

3.2 Create, role none [V syntax, `diskutil apfs addVolume` help: `-role 0`, `-reserve`]; reservation only if step 1.3
showed less than ~150 GB free:
```
ssh rolo@<macos-side> "sudo diskutil apfs addVolume $CT APFS macOS-hv -role 0"          # no reservation
ssh rolo@<macos-side> "sudo diskutil apfs addVolume $CT APFS macOS-hv -role 0 -reserve 40g"   # only if tight
```
Do not pass `-group*`, `-sibling` or a passphrase. Expected: "Finished APFS operation on disk...", the volume mounts at
`/Volumes/macOS-hv`.

3.3 Check: `diskutil apfs list "$CT"` shows `macOS-hv`, "No specific role"; `diskutil apfs listVolumeGroups` is unchanged
from 1.1 (no new group yet); the stub container's listing is byte-identical to 1.1.

## 4. Install macOS onto it (R at the MacBook; C on standby)

Warn R: after the install starts, SSH from the Studio drops and the MacBook reboots several times. The installer makes
macOS-hv the startup volume; Omarchy stops being the default until step 5.9/7.

4.1 Start (R). Preferred: the GUI, because it asks for the owner credential itself and R types it (Claude never gets it):
open `Install macOS <name>.app` -> Continue -> agree -> **Show All Disks** -> choose **macOS-hv** (not Macintosh HD, not
Omarchy) -> Install. Terminal alternative [U for `--volume`, authentication flags on Apple silicon]:
```
sudo "/Applications/Install macOS <name>.app/Contents/Resources/startosinstall" --agreetolicense --volume /Volumes/macOS-hv
```
(the tool asks for the owner password interactively; R types it). Needs the network: the installer personalizes the
build with Apple (see Q2). Expected [U]: "Preparing", a restart into an installer progress screen, 2-3 more restarts over
30-45 min, ending at Setup Assistant on the new volume. The plain volume becomes the System volume `macOS-hv` with a new
`macOS-hv - Data` and a new volume group [U that the installer accepts a pre-made plain volume on 27.x: Q1].
If the installer refuses the volume: abort, step 7 (delete), and try the GUI route again; do not point it at anything else.

4.2 Setup Assistant (R), minimal: region/keyboard as needed; **skip** Apple Account / iCloud ("Set Up Later"); skip Screen
Time, Siri, analytics, Touch ID enrolment; create the local admin **hv** (account name `hv`) with a throwaway password
that is not used anywhere else (R keeps it in his password manager; it is the owner credential for `bputil`/`kmutil` in
step 5). If it asks to enable FileVault: **No**.

4.3 Immediately after the first login (R): System Settings -> General -> Software Update -> turn **off** automatic
downloads/installs and any beta/seed enrollment prompt (an auto-update would pull a newer build and, per section 0 item 7,
possibly new machine firmware). Turn Wi-Fi off (`networksetup -setairportpower en0 off`) once nothing more is needed.

4.4 Confirm (R in Terminal on macOS-hv; paste the output into the chat only after redacting UUIDs):
```
sw_vers                              # ProductVersion 27.3, BuildVersion 26C5035r
fdesetup status                      # FileVault is Off.
csrutil status                       # enabled (Full Security volume, nothing changed yet)
diskutil apfs listVolumeGroups       # a new group containing macOS-hv + macOS-hv - Data; note its UUID: <VGUID-hv>
system_profiler SPHardwareDataType | grep -E "System Firmware|OS Loader"   # same as 1.1
```
`sw_vers` must say 26C5035r; anything else: STOP (section 0 item 7), step 7. If `fdesetup status` is On, turn it off
(System Settings -> Privacy & Security -> FileVault; decrypt takes time) before step 5: `bputil -s` (SSV off) cannot be
set while FileVault is on [V `bputil -h`].

4.5 Optional but recommended, 20 min: cross-check macOS-hv's boot files from Macintosh HD. Preboot is container-shared, so
Macintosh HD can read macOS-hv's directory read-only. R: shut down, power-hold -> "Loading startup options" -> **Macintosh HD**
-> Continue (a one-time boot; whether this changes the default is [U]; Startup Disk must be set back to macOS-hv by
4.7). C then:
```
ssh rolo@<macos-side> 'ls /System/Volumes/Preboot/; for d in /System/Volumes/Preboot/*/restore; do echo $d; plutil -extract ProductBuildVersion raw -o - $d/BuildManifest.plist; echo; shasum -a 256 $d/kernelcache.release.mac17j; done'
```
Expected [U]: two UUID directories (Macintosh HD's and macOS-hv's), both builds `26C5035r`, identical kernelcache hashes
(PLAN: the installed BootKC unwraps to `kc.macho` for Macintosh HD; the guest kernelcache for macOS-hv should be the same
bytes). Also confirms Macintosh HD still boots (1.5) and `sudo diskutil apfs listVolumeGroups` shows both groups. A
mismatch means the guest files prepared from Macintosh HD do not belong to this volume: STOP, re-run
`fetch-27.3-guest-files.sh` logic against macOS-hv's VG.

4.6 R chooses macOS-hv again in the picker (Continue) and logs in once, so macOS-hv is the most recently booted OS.

4.7 Startup Disk check (R, in macOS-hv): System Settings -> General -> Startup Disk -> macOS-hv selected. This matters
for step 5: the "Options" recovery must be macOS-hv's *paired* recoveryOS (otherwise `kmutil` fails with
"Boot policy error: ... code pairing" [V, repo: that is what the stub saw from the wrong recovery]).

## 5. The 1TR ceremony for macOS-hv only

5.1 Stage the payload on the Studio (S), in its own directory (never serve `~/Work/stage1-serve` or anything else):
```
mkdir -p ~/Work/agents/hv27/serve-1tr && cp ~/Work/agents/hv27/m1n1-build/m1n1-hv27-proxy.bin ~/Work/agents/hv27/serve-1tr/
cd ~/Work/agents/hv27/serve-1tr && shasum -a 256 m1n1-hv27-proxy.bin     # 3ea655950e932392a273576847ec9713171fc52fee3217f46ad538168a11eae1
python3 -m http.server 8001 --bind <studio-lan-ip>
```
Why this route and not "put it on a volume": 1TR cannot read Data volumes without unlocking them; the System volume is
sealed; the stub's `/Volumes/Omarchy/m1n1/` would work (stage1-install.sh uses it) but writing there touches the stub, which
this run must not. The HTTP route is the one `1tr-stage1.sh` already proved (`curl`, `/tmp/...`). Fallback: a FAT/exFAT USB
stick with the same file; check the hash in 1TR either way.

5.2 Get into the right recovery (R): `sudo shutdown -h now` from macOS-hv; power-hold until "Loading startup options";
**Options -> Continue**. If asked to pick a user/volume to recover, pick macOS-hv and user `hv`. Menu bar: join Wi-Fi
(Wi-Fi icon, top right) on the same LAN as the Studio. Utilities -> Terminal.

5.3 Fetch and verify (R, recovery Terminal; `/tmp` is a RAM disk):
```
curl -f -o /tmp/m1n1-hv27-proxy.bin http://<studio-lan-ip>:8001/m1n1-hv27-proxy.bin
ls -l /tmp/m1n1-hv27-proxy.bin          # 4390912 bytes
shasum -a 256 /tmp/m1n1-hv27-proxy.bin  # must start 3ea65595 ... end eae1
```
The size is a 64 KiB multiple (0x430000), inside the measured iBoot envelope (stub stage-1 0x430000 and plain 0x4D0000 boot;
0x4E0000+ loop; `boot-and-recovery.md`, DESIGN.md) [V from notes, not for this image: Q6/Q7]. Stop the Studio HTTP server now.

5.4 Identify the target (R):
```
diskutil apfs listVolumeGroups     # find the group holding macOS-hv: <VGUID-hv>
diskutil list | grep -E 'macOS-hv|Macintosh|Omarchy'
csrutil status                     # in recovery it lists each OS install [V help]; format U
bputil -e                          # all policies: PHOTOGRAPH or copy; baseline for 5.8 (skip if 1.2 worked and nothing else changed)
bputil -d -v <VGUID-hv>            # expect Full Security (format U)
```
Do not run any `bputil` without `-v <VGUID-hv>`: with several installs it otherwise prompts for a UUID and a wrong pick
rewrites another OS's policy.

5.5 Lower the policy of macOS-hv only (R; prompts for the owner user `hv` and its password):
```
bputil -nkcas -v <VGUID-hv>
```
[V meaning from `bputil -h`: -n Permissive, -k kexts, -c CTRR off, -a custom boot-args, -s SSV off. Same flags as the Asahi
page; the stub uses `-nc`.] Expect it to finish without an error [U exact text]. Known failures on this machine:
`bputil` / `bless` "AP boot mode" (bootpolicy error 11) came from trying to rewrite an existing Permissive policy from
macOS userspace (`refresh-stub-firmware.sh` header) — it means you are not in recovery or not in the right one; stop and
re-enter 5.2. "Code pairing" (kmutil) = wrong recovery, same remedy; if it persists, STOP (do not try the stub's install-media
marker trick: that is for the stub only). The Startup Security Utility GUI is not a substitute: it offers Reduced Security
and kext approval, but not `-c`, `-a`, `-s` or Permissive.

5.6 SIP (R): `bputil` reset SIP, so disable it explicitly [Asahi page]:
```
csrutil disable
csrutil status                     # macOS-hv: disabled (U text); the other installs still enabled
```
If it asks which OS: macOS-hv. Per-OS scoping is by interactive selection or the volume it is launched against; there
is no `-v` form I could confirm [U]. If `csrutil status` shows another install changed: STOP and tell Claude.

5.7 Make m1n1 the boot object (R; prompts for the `hv` password):
```
ls /Volumes                        # macOS-hv should be listed; if not: diskutil mount <diskNsM of macOS-hv>
kmutil configure-boot -c /tmp/m1n1-hv27-proxy.bin --raw --entry-point 2048 --lowest-virtual-address 0 -v /Volumes/macOS-hv
```
[V flags, `kmutil configure-boot --help`: `--raw`, `--entry-point`, `--lowest-virtual-address`, `-v` path.] Same invocation
that registered the stage-1 on the stub. No `--compress`.

5.8 Verify (R, then C after reboot):
```
bputil -d -v <VGUID-hv>            # Permissive, kernel CTRR off, custom boot args allowed, SSV off; a custom boot object hash is present [U]
bputil -e                          # compare with 5.4: Macintosh HD and Omarchy entries unchanged
```
Same check later from C if `bputil -e` runs in macOS (1.2). The ceremony writes new files for macOS-hv's VGUID in the
iBootSystemContainer (p1, shared); existing entries are not modified. This is the same thing the stub's ceremony did.

5.9 Default startup (R, optional, recommended): in the same recovery, Utilities -> Startup Disk -> **Omarchy** -> Restart.
This keeps the daily as the default; hv sessions then start from the picker. May ask for the stub owner's password [U]. If it
errors, skip: the machine will sit in the m1n1 proxy on every plain power-on (black panel, USB device visible on a host)
until the default is changed from the picker (hold Option/Control for "Always Use" [U]) or from Macintosh HD's Startup Disk.
Then `reboot`. Do not `reboot` before 5.8 passed.

How this coexists with the Omarchy chain: policies are per volume group, kept per VGUID in the iSC. Macintosh HD, the
stub and macOS-hv are three independent entries. The stub stays Permissive with its own boot object (stage-1 A/B on the
ESP); macOS-hv becomes a second Permissive entry whose boot object is the proxy. Which one starts is the Startup Disk
default (after 5.9: Omarchy) or the picker (power-hold -> choose the volume). Nothing here edits the stub volumes, its
boot object, or the ESP. Two Permissive volumes coexisting is expected (Asahi supports several Linux stubs) but not
tested on this Mac [U]; 5.8's `bputil -e` and the step-7 boot of Omarchy are the checks.

## 6. First boot of macOS-hv under the hypervisor

Hardware (R, PLAN section 7): Studio DFU port (rear, next to Ethernet) to the MacBook's left-back port; MagSafe charger;
lid open; nothing else on that port.

6.1 Prove the loader (S first, then R):
```
cd ~/Work/agents/hv27 && ./run-hv27.sh smoke        # waits up to 600 s for 1209:316d
```
R: power-hold -> picker -> **macOS-hv** -> Continue (or plain power-on if macOS-hv is the default). Expected on the panel
[U, from rungs i-ii]: m1n1 banner `m1n1 v2.0.0-132-g63e6053c`, "No valid payload found", "Running proxy...". No
"Primary WDT left armed" line (no stage-1 `m1n1.wdt=keep` here). Studio prints
`m1n1 v2.0.0-132-g63e6053c base 0x... chip 0x6050 board 0x...` then a "stage-1 watchdog disarmed" line, which is just the
unconditional register write and harmless here. A different version string: STOP, power-hold, Omarchy from the picker.
If the panel shows the "needs to be reinstalled" recovery or the Apple logo loops (iBoot rejects the image, Q7): power-hold,
pick Omarchy/Macintosh HD from the picker (they are unaffected), then step 7 or reinstall a proven object on macOS-hv
(`boot-plain.bin` or `plain-small.bin`, via 1TR as in step 5; plain m1n1 has no payload so it also ends in the proxy).

6.2 Clear iBoot's failed-boot counter from the proxy, now and at the end of each session (no stage-1 does it on this
path; a high count sends the next boot to the reinstall screen; `boot-and-recovery.md`) [V tool exists]:
```
cd ~/Work/agents/hv27/m1n1/proxyclient && M1N1DEVICE=$(ls /dev/cu.usbmodem*1 | head -1) PYTHONPATH=. ~/Work/m1n1/.venv/bin/python tools/reset_panic_counter.py
```
(proxy interface = suffix 1; console = suffix 3, as `run-hv27.sh` assumes.)

6.3 Boot macOS with its SSD (S). The default boot-args in `run-hv27.sh` include `serial=3`, which hangs XNU at the console
switch (PLAN-27.3 status); override:
```
cd ~/Work/agents/hv27 && HV27_I_AM_ON_THE_TEST_VOLUME=yes HV27_ARGS="-v debug=0x14e wdt=-1" ./run-hv27.sh guest disk
```
`disk` mode drops `--strip-node iop-ans-nub` (so ANS and the SSD stay) [V from run-hv27.sh]. `HV27_TRACE` stays empty for
the first boot.

6.4 What to expect [U beyond iii-a]: the iii-a sequence (SPTM/TXM/cL4 images, per-core "Starting guest secondary", IOKit
matching) then, new, XNU starting the ANS/NVMe controller and mounting macOS-hv's System snapshot and Data; launchd;
Exclaves; DCP/display; the login window for user `hv` on the panel. The SEP session is the one iBoot started for macOS-hv's
policy (`/chosen/boot-uuid` = macOS-hv's group), which is the whole point of the dedicated volume. A panic or hang
anywhere drops to the hypervisor shell. Photograph panics.

6.5 Risk list (what this boot can write):
- NVRAM (`anvram`, SPI NOR; machine-wide) — reversible.
- The shared Preboot, VM (swap) and Update volumes in the main container: macOS-hv's own entries, but one volume each.
- xART / SEP anti-replay state in the iSC: device-wide, counters never roll back (PLAN section 5). Irreversible. Rules:
  no Touch ID, no Apple Account, never type Macintosh HD's password.
- Auto-mounting: macOS-hv's diskarbitration may mount Macintosh HD's volumes (its Data stays locked under another group's
  keybag; SKP) and the stub container's volumes read-write. Optional hardening, to do in step 4 before the ceremony: an
  `/etc/fstab` entry `UUID=<volume uuid> none apfs rw,noauto` per foreign volume [U]. Without it, do not browse Finder.
- The ESP (FAT, type EFI) is not auto-mounted by macOS and the Linux root (ext4) is not a macOS filesystem.
- The proxy has no watchdog: a wedge means power-hold; the forced reset is counted by iBoot (6.2).

6.6 Ending the session and going back to Omarchy: Ctrl-C -> hypervisor shell; `cont()` resumes; `reboot()` hard-resets.
Hung beyond the shell: hold power until off. Then run 6.2 again if the next boot lands on a screen with the reinstall
text. Power-hold -> picker -> **Omarchy** (or plain power-on if 5.9 left it the default). The daily comes up from the ESP
exactly as before: nothing in this rung writes `m1n1/boot.bin*`, so PLAN section 4 step 9 is not needed; confirm
`slot=primary` in the Linux log. Macintosh HD: picker -> Macintosh HD.

## 7. Rollback

7.1 Cheapest (nothing deleted): leave macOS-hv alone, make Omarchy the default again (5.9, or picker with "Always Use" [U],
or from Macintosh HD's Startup Disk pane; a Startup Disk or `bless` failure with "AP boot mode" is the Permissive-policy
rewrite problem: use the picker). The stub, stage-1 and the ESP were never touched.

7.2 Remove the m1n1 boot object but keep the volume: in the paired 1TR, `bputil -f -v <VGUID-hv>` ([V flag] Full Security)
and `csrutil enable`; macOS-hv will then not boot natively until a stock boot object is re-registered, so this is only
useful together with 7.3.

7.3 Delete the volume group (C, from Macintosh HD booted via the picker). First `diskutil apfs listVolumeGroups` and
confirm `<VGUID-hv>` is the group with only macOS-hv and macOS-hv - Data:
```
ssh rolo@<macos-side> 'sudo diskutil apfs deleteVolumeGroup <VGUID-hv>'
```
[V: `deleteVolume` help says the volume's XART, Preboot and Recovery entries are removed too; `deleteVolumeGroup` exists;
the stub script notes exit code -69495 about a Preboot directory is harmless.] Never name Macintosh HD's UUID.
If the group is not formed (failed install), `sudo diskutil apfs deleteVolume <macOS-hv diskNsM>`.
Optional policy cleanup: `sudo bputil -r <VGUID-hv>` ([V flag]: removes that group's macOS and paired-recoveryOS local
policies; do NOT use `-z`, it removes policies of every volume not currently present). Works from running macOS? [U]; else in 1TR.

7.4 Verify rollback (C): `diskutil apfs listVolumeGroups` shows only Macintosh HD's group; `diskutil apfs list` free space
is back; the stub container's listing and the ESP hashes (1.1, 1.4) are identical; `bputil -e` lists Macintosh HD and the
stub only; picker shows Macintosh HD + Omarchy; Omarchy boots to the daily. Keep `~/Work/installers/<name>.app` (the installer
deletes itself) if another attempt is likely, or delete it to free ~15 GB.

## 8. Open questions to settle (and where)

| # | question | settled by | if the answer is bad |
|---|---|---|---|
| Q1 | Does the 27.x installer accept a pre-made role-less plain volume and turn it into a new volume group? (Asahi does it on 13.5/14.8.3; not shown for 27.x) | step 4.1 | GUI "Show All Disks" route; else delete the volume and let the installer's own flow create it; do not use the Macintosh HD target |
| Q2 | Is 26C5035r still signed by Apple? Installing needs online personalization; Apple normally signs only the newest beta (beta 1 was 2026-11-03) | only by trying step 4.1; `softwareupdate --list` (1.7) hints at a newer build | The rung is blocked until a newer build is adopted: re-extract guest files, rebuild the plan's pins; section 0 item 7 applies |
| Q3 | Does the same-build install leave machine-wide firmware untouched? | 1.1 vs 4.4 firmware lines | Treat a change as new firmware: re-run rungs i-iii-a before trusting anything |
| Q4 | Is a beta fetchable with `--fetch-full-installer` on this Mac, and which seed is it on? | step 2.1-2.2 | alternatives in 2.5 |
| Q5 | Do two Permissive volume groups (stub + macOS-hv) coexist with Macintosh HD's policy? | 5.8 `bputil -e` and the step-7 Omarchy boot | delete macOS-hv (7.3); do not touch the stub |
| Q6 | Does `kmutil configure-boot` accept this image? The proxy file has **no** appended variables (plain). The stub's stage-1, a 0x430000 image *with* an appended `chainload=` variable and terminator, 64 KiB-aligned, was accepted (DESIGN.md: "including variables" must be a 16 KiB multiple on M4+). If variables were ever needed, append `name=value\0 ... \0\0\0\0` and re-pad to a 64 KiB multiple. | step 5.7 | an error from kmutil changes nothing; capture its text for upstream |
| Q7 | Has the hv27 image ever been booted straight from iBoot as a raw object? **No.** Rungs i-iii-a ran it relocated above the CTRR window, chainloaded by stage-1. Direct boot at iBoot's base should also make secondary start simpler (RVBAR = its own vectors), but the size cliff is layout-relative (`boot-and-recovery.md`), and the section table shows an image end of 0x440000 against a 0x430000 file (stage-1 had the same shape; not checked) | 6.1 | boot loop / "needs to be reinstalled": picker to Omarchy, then install `plain-small.bin` or `boot-plain.bin` as macOS-hv's object in 1TR (proxy only) and bisect size |
| Q8 | Does the "Options" recovery come up as macOS-hv's paired recoveryOS after 4.6-4.7? | 5.5 / 5.7 not erroring with "code pairing" | do not improvise with markers; STOP and ask |
| Q9 | Does Sealed Key Protection let macOS-hv's Data volume unlock when the measured boot object is the m1n1 proxy rather than Apple's kernelcache, under a policy lowered after the volume's creation? (Asahi's hv guide works for 13.5/14.8.3; M5 SKP is new) | 6.4 (login window or not) | no login window: rung iii-b stops at "root mounted, Data locked"; delete or keep for tracing |
| Q10 | Does `startosinstall --volume` on Apple silicon need `--user/--stdinpass` for an owner of the *host* OS? | 4.1 | use the GUI; R types the password |
| Q11 | Does `bputil -e/-d` run from the running macOS, so C can verify without 1TR? | 1.2 | verify only in 1TR |
| Q12 | Does the per-volume SIP choice stay scoped to macOS-hv (`csrutil disable` has no volume flag I could confirm)? | 5.6 `csrutil status` | restore from 1TR (`csrutil enable` on the other installs) |
| Q13 | Does the guest's auto-mounting of the stub and Macintosh HD volumes matter? | 6.5 hardening or just do not touch Finder | fstab noauto per foreign volume |
