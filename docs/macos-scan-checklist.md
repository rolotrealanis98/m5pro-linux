# macOS scan checklist: J716s (MacBook Pro 16-inch M5 Pro, T6050), macOS 27.3 beta 1 (26C5035r)

Purpose: while the MacBook is away from the Studio (until 2026-11-08), collect from macOS the facts
that the design reports in `contrib/pending/*/REPORT.md` list as unknown, inferred or "verify", so
Sunday's hardware rounds start with answers. Everything here is read-only. The script
[`macos-scan.sh`](macos-scan.sh) does all of section 3 except the two interactive/root steps; the
commands are also listed one by one so a single answer can be re-checked by hand.

Validated on the Mac Studio (M2 Ultra, macOS 27.2 26B123) on 2026-11-05: `bash -n`, a full
`scan` run (2 min 18 s, 14 redacted files, 188 KB tarball, verification passed), the redaction of
an external display's EDID serials, paired Bluetooth device names and Wi-Fi network lists. Section
6 lists what differs per machine.

## 1. Rules (read before running anything)

1. **Read-only.** Allowed: `ioreg`, `system_profiler`, `sysctl`, `sw_vers`, `plutil -p/-extract`,
   `/usr/libexec/PlistBuddy -c Print`, `kmutil showloaded`, `nvram -p` (print only), `pmset -g`,
   `diskutil list/info/apfs list`, `ls`/`find`/`stat`, `shasum`.
2. **Never:** `csrutil`, `bputil`, `kmutil load/configure-boot/create`, `kextload`/`kextunload`,
   `nvram` with any argument other than `-p`, `pmset` without `-g`, `systemsetup`, `bless`,
   `diskutil mount` without `readOnly`, any `diskutil apfs` change, `defaults write` to system
   domains, third-party SMC tools (`smckit`, `iSMC`, `smcFanControl`, etc.), anything under
   `host/macos/` (those scripts mount stub volumes read-write and some rewrite them; even
   `refresh-stub-firmware.sh check` mounts the stub System volume read-write). No SIP, LocalPolicy,
   kext or NVRAM change of any kind.
3. **Output stays in `~/m5scan/<YYYY-MM-DD>/` on the MacBook.** `raw/` holds everything as
   collected, including serial numbers, MAC/Wi-Fi/BT addresses and UUIDs. `raw/ioreg-devicetree-full.txt`
   (the full `ioreg -l -p IODeviceTree` dump) and `raw/ioreg-service-full.txt` must never be copied
   off the MacBook, into the repo, or into a chat. They are not in the tarball.
4. **Redaction before anything leaves `raw/`.** The script's last step writes `redacted/`
   copies of the targeted extracts and replaces:
   - this machine's own serial number, platform UUID, provisioning UDID, every interface MAC
     (colon and bare forms), the Bluetooth address, computer name, local host name, account name and
     full name (collected into `raw/.ids`, mode 600, as literals to replace);
   - the values of properties whose names look like identifiers (`serial`, `mac-address`,
     `uuid`, `udid`, `ecid`, `unique-chip-id`, `nonce`, `imei`, `meid`, `iccid`, `drom`, `mlb`,
     `uid`, `system-id`, `ssid`, `calibration`, `owner`, `apple-id`, `icloud`, `dsid`, account/user/host
     names...), including inside inline dictionaries such as a display's `ProductAttributes`;
   - by pattern: UUID-shaped strings, MAC/EUI-64-shaped strings, 15-17 digit numbers (IMEI-like),
     e-mail addresses (iCloud ids), hex strings of 40+ characters (except the script's own
     `sha256=` firmware hashes), `/Users/<name>`, `Name's <device>` device names;
   - hex blobs of 32+ bytes that are not printable text become `<blob N bytes>` (this is how the
     Thunderbolt DROM and calibration blobs are withheld); printable blobs are decoded to text first
     and then pass through the rules above.
   It then **verifies**: any surviving literal identifier, UUID/MAC-shaped string or
   identifier-named property with a value aborts the tarball (`REDACTION FAILED`, no tarball).
5. **What may come back to the Studio / into the repo:** only
   `~/m5scan/<date>/m5scan-<date>-redacted.tar.gz` (contains `redacted/` only). Before committing
   anything from it, skim it once more by eye; the repo's privacy rule (README, "Not in this repo")
   still applies: no ADT dump, no serials, no MAC addresses.
6. **Firmware files are listed, never copied.** Names, sizes, IM4P header type/description and
   sha256 only. Personalized objects (`apticket*`, `*.im4m`, `boot/<hash>/`, anything FTAB-named)
   get names and sizes only: their hash would itself be a per-device fingerprint.
7. **Clean-room:** no `strings`, disassembly or symbol dumps of Apple kexts or firmware. Kext
   `Info.plist` metadata (versions, match strings) and IM4P headers are fine; payloads are not read.

## 2. Running it

On the MacBook (repo at `~/Documents/GitHub/m5pro-linux`; the two files must be on it, see the
hand-off note):

```bash
cd ~/Documents/GitHub/m5pro-linux
bash -n docs/macos-scan.sh && bash docs/macos-scan.sh scan      # 2-4 min, no sudo
bash docs/macos-scan.sh ports                                   # interactive, in Terminal (section 3.10)
sudo bash docs/macos-scan.sh stub                               # optional: stub Preboot, mounted READ-ONLY
bash docs/macos-scan.sh redact                                  # after ports/stub/ANSWERS.md: re-redact + new tarball
```

Files written (raw and redacted have the same names):

| file | covers |
|---|---|
| `00-system.txt` | macOS build, model, DT root/chosen/product, NVRAM variable names + brightness/boot-args values |
| `01-registry.txt` | IOService class census, DT node names, loaded kexts, on-disk kexts matching t6050/t605x, every coprocessor firmware/RTKit version string |
| `02-dcp-display.txt` | 3.1 DCP / display / backlight |
| `03-wireless-n1.txt` | 3.2 N1 Wi-Fi/BT |
| `04-gpu.txt` | 3.3 GPU |
| `05-audio.txt` | 3.4 audio |
| `06-isp-camera.txt` | 3.5 ISP/camera |
| `07-tb-usb-pd.txt` | 3.6 Thunderbolt/USB4 and 3.10 USB-C/PD |
| `08-smc-battery.txt` | 3.7 SMC |
| `09-backlight-als-kbd.txt` | 3.8 keyboard backlight, ALS, exclave service names |
| `10-trackpad-mtp.txt` | 3.9 trackpad MTP |
| `11-pmu-scratchpad.txt` | 3.11 PMU scratchpad |
| `12-firmware.txt` | 3.12 firmware locations, hashes, BuildManifest components |
| `13-stub-preboot.txt` | `stub` only: the Linux stub's own restore bundle |
| `14-ports-map.txt` | `ports` only: Port-USB-C@N to physical port |
| `SUMMARY.txt` | one screen of headline values |

### Prompt to paste into Claude Code on the MacBook

```text
You are on Rolando's MacBook Pro 16" M5 Pro (J716s, T6050), macOS 27.3 beta 1. Run the read-only
m5pro-linux hardware scan and summarise it. Rules: read-only. Do not use sudo, csrutil, bputil,
kmutil (except "showloaded"), kextload, nvram (except "-p"), pmset (except "-g"), bless, any
diskutil command that mounts read-write or changes volumes, or anything in host/macos/. Write
nothing outside ~/m5scan. Never open, print or quote files under ~/m5scan/*/raw/ (they contain
serial numbers, MAC addresses and UUIDs); work only from ~/m5scan/<today>/redacted/. Never put a
serial number, MAC/Bluetooth address, UUID, IMEI, Apple ID or iCloud identifier in the chat or in
any file.

1. cd ~/Documents/GitHub/m5pro-linux (git pull --ff-only if the files are missing; ask me if
   docs/macos-scan.sh still is not there).
2. bash -n docs/macos-scan.sh, then run: bash docs/macos-scan.sh scan
3. If it prints "REDACTION FAILED", stop and show me only the file names it listed.
4. Read docs/macos-scan-checklist.md section 3. For each question id (DCP-1, N1-1, ...) give
   the answer found in the redacted files, or "not visible from macOS", with the redacted file name
   and a short excerpt. Flag anything that contradicts the "Known" lines.
5. Save that as ~/m5scan/<today>/ANSWERS.md, then run: bash docs/macos-scan.sh redact
   (this redacts ANSWERS.md into the tarball). Print the tarball path and size.
6. Remind me to run, myself in Terminal: "bash docs/macos-scan.sh ports" (interactive port map)
   and optionally "sudo bash docs/macos-scan.sh stub", then "bash docs/macos-scan.sh redact".
```

## 3. Open questions, commands, what to look for

Grep forms below assume `D=~/m5scan/$(date +%F)/raw/ioreg-devicetree-full.txt` and
`S=~/m5scan/$(date +%F)/raw/ioreg-service-full.txt`; run them on the MacBook only and copy results
out through the redacted files, not the raw ones. "Known" = what the reports already have from the
ADT; don't re-derive it, confirm or contradict it.

### 3.1 DCP / display (report: `contrib/pending/dcp/`)

Decision it feeds: does aurora-silicon's `t6050/dcp` firmware-27 IOMFB table (iomfb_v27.c) apply
to the DCP firmware paired with 26C5035r, or does the stub need re-pairing to a build aurora matches?

Known: no DCP version string in the ADT; stub boot logs `OS FW version: unknown (mBoot-20457.60.65.0.1)`;
`/chosen/boot-object-manifests` lists `dcpf` and `dcp2`; panel 600 nits user max (1000 override),
`dcp-brightness-node = 1`; disp-bklt on i2c7 0x44 owned by DCP; Parade DP855 TCON on spi4. On 27.2
the T6050 DCP kext is `AppleMobileDispT605X-DCP` 140.0 (matches `disp0,t605x`, `dispext0-7,t605x`)
and an `EXDisplayPipeT605X` kext matches `exdisplaypipe,t605x` (an exclave display pipe).

| id | question | command | look for |
|---|---|---|---|
| DCP-1 | Exact DCP firmware the macOS bundle carries | `ls -l /System/Volumes/Preboot/*/restore/Firmware/dcp/`; `shasum -a 256` of it; IM4P header (script: `12-firmware.txt`, `im4p=dcpf:"..."`) | file name (Studio: `t602xdcp.im4p`; expect `t605xdcp.im4p` or similar), size, sha256, IM4P type `dcpf` |
| DCP-2 | DCP-side kext versions on 26C5035r | `plutil -p /System/Library/Extensions/AppleMobileDispT605X-DCP.kext/Contents/Info.plist \| grep -E 'Version\|IONameMatch'`; same for `IOMobileGraphicsFamily-DCP`, `AppleDCP`, `EXDisplayPipeT605X`, `DCPDPFamilyProxy`; `kmutil showloaded --list-only \| grep -i -E 'dcp\|mobiledisp\|exdisplay'` | CFBundleShortVersionString per kext (27.2: T605X-DCP 140.0, IOMobileGraphicsFamily-DCP 343.0.0, AppleDCP 1). A change from 27.2 hints the IOMFB ABI moved again |
| DCP-3 | DCP firmware/RTKit version exposed at runtime | `ioreg -r -n dcp -l -w0 \| grep -E '"(FirmwareVersion\|RTKitVersion)"'`; `01-registry.txt` "coprocessor firmware versions" | any `RTKitVersion` / `FirmwareVersion` under `dcp` / `dcpext*` (the Studio exposes none for DCP, but does for AOP: `mac14jaop:MAIN:...`) |
| DCP-4 | Stub pairing equals main macOS pairing | `sudo bash docs/macos-scan.sh stub` (mounts the stub Preboot read-only); compare `13-stub-preboot.txt` with `12-firmware.txt` | stub SystemVersion/BuildManifest = 26C5035r and identical sha256 for `Firmware/dcp/*` (and agx, AOP). If identical, everything learnt from macOS's own DCP applies to the stub |
| DCP-5 | IOMFB method/endpoint tables visible? | `ioreg -r -c IOMobileFramebufferShim -l -w0 -d2`; `grep -c DCPEndpoint $S`; script `02-dcp-display.txt` | endpoint object names (`DCPEndpointV2`, `AppleDCPLinkService*`), `IOMFB_*` keys. Method IDs are not in the registry; expect only endpoint names. Do not try to get them from kext binaries (clean-room) |
| DCP-6 | Panel and backlight properties | `ioreg -p IODeviceTree -r -n backlight -l -w0`; `ctxgrep` for `nits\|bright\|dimming\|backlight` (script); `system_profiler SPDisplaysDataType` | `user-accessible-max-nits`, override nits, `dcp-brightness-node`, local-dimming / mini-LED zone keys, `twodbl` child, panel ID/resolution/refresh range (ProMotion 1-120 Hz?), `IOMFB*` brightness keys |
| DCP-7 | Brightness NVRAM variables (TEST-PLAN 0c) | `nvram -p \| grep -i -E 'backlight\|bright'` | variable names and values. Note only; the carry-over test needs a Linux boot (Sunday) |
| DCP-8 | Exclave display pieces | `grep -i -E 'exclave\|exbright\|exdisplaypipe' $D` (script: `09-...` exclave list, `02-...`) | `EXBrightPILCore`, `exdisplaypipe` service names; whether a display-pipe exclave exists on J716s (affects whether 27.x DCP waits for an exclave peer) |

### 3.2 N1 Wi-Fi/Bluetooth (report: `contrib/pending/wireless/`)

Decision it feeds: where the personalized FTAB lives (extractor design), the J716s platform/board ID
for `apple,centauri-platform-id`, and whether iBoot/macOS train apcie0 port 0 at Gen3.

Known: `/product wifi-chipset = proxima`; apcie0 port 0 `maximum-link-speed 3`, `centauri-builtin`;
functions 106b:1900 (ROM)/1901 (running) control, 1902 Wi-Fi, 1903 BT; aurora J716c uses
`apple,centauri-platform-id = <0x000e6050>` and `apple/centauri/j716c-ftab.bin`. On 27.2,
`AppleCentauriManager.kext` matches `IOPCIMatch 0x1900106b` and `IOPropertyExistsMatch centauri-builtin`,
plus a helper on IONameMatch `centauri`. The Studio's 27.2 restore bundle already holds a
`restore/centauri/` folder of `centauri.<board>{,.dev,.insecure}.im4m` manifests, including j716sap.

| id | question | command | look for |
|---|---|---|---|
| N1-1 | Where the firmware/FTAB lives | `find /usr/share/firmware /usr/standalone/firmware /System/Library/Extensions /System/Volumes/Preboot /Library/Apple \( -iname '*centauri*' -o -iname '*proxima*' -o -iname '*ftab*' -o -iname '*rkos*' \) 2>/dev/null`; `ls /System/Volumes/Preboot/*/restore/centauri/`; `ls /usr/share/firmware/wifi` | a per-board firmware file or FTAB under Preboot (personalized: names/sizes only), `centauri.j716sap*.im4m`, a `proxima`/`centauri` entry in `/usr/share/firmware/wifi` (Broadcom Macs have `C-4388__s-*` there). Also check `/System/Volumes/iSCPreboot` and `/System/Volumes/Hardware` by `ls` only, without opening files (per-device data lives there) |
| N1-2 | Kext personalities and versions | `plutil -p .../AppleCentauriManager.kext/Contents/Info.plist`; any other kext matching `1902106b`/`1903106b` (`grep -l -E '190[0-3]106b' /System/Library/Extensions/*.kext/Contents/Info.plist`) | which kexts own Wi-Fi (fn 1) and BT (fn 2); versions on 26C5035r |
| N1-3 | Platform / board id macOS uses | `ioreg -p IODeviceTree -d1 -l -w0 \| grep -E '"(board-id\|chip-id\|compatible\|target-type)"'`; `grep -i -E 'platform-id\|board-id\|centauri' $D $S` | DT root `board-id` (Studio: `<0a000000>`); J716s expected `board<<16 \| 0x6050`; any `platform-id`-like property on the centauri objects |
| N1-4 | PCIe link at runtime | `ioreg -r -c IOPCIDevice -l -w0 \| grep -E '\+-o\|"(vendor-id\|device-id\|IOPCIExpressLinkStatus\|IOPCIExpressLinkCapabilities)"'`; `system_profiler SPPCIDataType` | four functions (device-id `<00190000>`..`<03190000>` LE) or three; `IOPCIExpressLinkStatus` speed (bits 3:0: 1=2.5, 2=5, 3=8 GT/s) and width (bits 9:4) |
| N1-5 | Firmware version / chipset strings | `system_profiler SPAirPortDataType` (network sections are withheld by the script), `SPBluetoothDataType` (controller only) | "Card Type", "Firmware Version", BT "Chipset", "Transport", "Firmware Version"; no SSIDs, no device list |
| N1-6 | spmi-wifibt / sacm / power | `ioreg -p IODeviceTree -r -n spmi-wifibt -l -w0`; `ioreg -p IODeviceTree -r -n centauri -l -w0` (MAC withheld by redaction) | power-related `function-*` entries, SACC references, whether macOS shows an AOP SPMI dependency |

### 3.3 GPU, G17 (report: `contrib/pending/gpu/`)

Known: `gpu,t6050`, two firmware CPUs (gfx-asc, gfx1-asc), SAPT at `/arm-io/sapt`, `ttbat-phys-addr-base`,
no core-count property in the ADT. On 27.2 the T6050 GPU kext is `AGXG17X` 362.5.1 (IONameMatch
`gpu,t6050`/`t6051`/`t6052`) with `AGXFirmwareKextG17XRTBuddy`; the restore bundle's GPU firmware is
`Firmware/agx/armfw_*.im4p` with IM4P type `gfxf`, and its payload is an `rkosftab` container.

| id | question | command | look for |
|---|---|---|---|
| GPU-1 | Core count of this unit | `ioreg -r -c AGXAccelerator -l -w0 -d1 \| grep -E 'gpu-core-count\|num_cores\|GPUConfigurationVariable'`; `system_profiler SPDisplaysDataType \| grep Cores` | 16 or 20; `num_gps`/cluster info in `GPUConfigurationVariable` (confirms two clusters) |
| GPU-2 | AGX firmware build | `ls -l /System/Volumes/Preboot/*/restore/Firmware/agx/`, sha256 + IM4P header (script `12-firmware.txt`); `ioreg -r -c AGXFirmwareKextG17RTBuddy -l -d1`; `grep -E 'RTKitVersion\|FirmwareVersion' 01-registry.txt` | file name (`armfw_g17s*`? `armfw_g17x*`?), size, sha256; RTKit version string under the GFX/GFX1 RTBuddy objects |
| GPU-3 | Kext generation naming | `01-registry.txt` "kexts on disk that match T6050"; `kmutil showloaded --list-only \| grep -i agx` | AGXG17X vs the report's "G17S" naming; Metal bundle loaded (`AGXMetalG17X`) |
| GPU-4 | SAPT / UAT / TTBAT properties at runtime | `grep -n -i -E '"(sapt[^"]*\|uat[^"]*\|ttbat[^"]*\|agx-address-space-mgmt-mode\|gptbat-ready)"' $S $D` | whether the registry shows SAPT policy/size or UAT page-table setup; values only (addresses are fine, not identifiers) |

### 3.4 Audio (report: `contrib/pending/audio/`)

Known: six SN012776 amps (i2c1 0x38-0x3a, i2c3 0x3b-0x3d), CS42L84 on i2c2 0x4b, speaker-thiele-small
Re 3.29-3.39 ohm in the ADT, speaker stream `spkr` AOP-owned, built-in mics `hpai` on secure ADMAC
behind exclave `com.apple.service.HPMicAudioDriver`, `supports-secure-microphone = 1`, AOP firmware
name `mac17jaop`.

| id | question | command | look for |
|---|---|---|---|
| AUD-1 | Speaker calibration visible in macOS | `grep -n -i -E 'calib\|thiele\|speaker-config\|spA[0-5]' $S` (script `05-audio.txt`, values withheld) | which objects carry calibration (amp nodes, AOP audio service), key names and byte sizes. Values stay on the MacBook |
| AUD-2 | AOP audio routing | `ioreg -r -c AppleAOPAudio -l -w0 -d2`; `ioreg -r -c AppleSPU -l -d1`; script ctxgrep for `aopaudio\|iopaudio\|leap\|admac` | AOP endpoint/service names for speaker (`spkr`), sense, `cout`/`cin` (jack), and whether speaker DMA is `AudioDMAController_T605x` (non-secure) |
| AUD-3 | Which mic path macOS uses | `system_profiler SPAudioDataType`; `kmutil showloaded --list-only \| grep -i -E 'exclave\|isolated\|lpmic'`; `grep -i -E 'IOPAudioIsolated\|IISAudioIsolated\|HPMic\|secure-mic' $S` | built-in mic device listed; `ExclavesAudioKext` / `IOPAudioIsolatedIOBufferDevice` / `IISAudioIsolatedStreamECProxy` loaded and attached to the mic = secure path confirmed |
| AUD-4 | AOP firmware build | `ls /System/Volumes/Preboot/*/restore/Firmware/AOP/`; `grep -A1 -i aop 01-registry.txt \| grep FirmwareVersion` | `aopfw-mac17jaop.*.im4p` name/sha256; runtime `FirmwareVersion` string `mac17jaop:...` |
| AUD-5 | Amp/codec objects | script ctxgrep `sn012776\|tas27\|cs42l\|amp` | macOS driver class per amp, its I2C address and any `amp-gain`, `speaker-id` property (valid ids 0/3 in ADT) |

### 3.5 ISP / camera (report: `contrib/pending/isp-tb/`)

| id | question | command | look for |
|---|---|---|---|
| ISP-1 | Which driver owns the camera | `system_profiler SPCameraDataType` (unique id withheld); `ioreg -r -c AppleH16CameraInterface -l -d1`; script `06-isp-camera.txt` | camera class (`AppleH16CameraInterface` or a newer one), whether it sits under an exclave proxy object, sensor model string |
| ISP-2 | ISP firmware location | `find /usr/share/firmware/isp /System/Volumes/Preboot -iname '*isp*'`; restore `Firmware/` listing | whether ISP firmware is a separate file or only in the kernelcache/exclave cryptex (`/System/Volumes/Preboot/Cryptexes/ExclaveOS`, names only) |
| ISP-3 | Privacy LED | `grep -i -E 'exbrightpil\|dynamic-pil\|privacy' $D $S` | EXBrightPILCore service name; any non-exclave LED control object |

### 3.6 Thunderbolt / USB4 (report: `contrib/pending/isp-tb/`)

Known: port 1 left-back (MagSafe side) = hpm0/atc-phy0/acio0/usb-drd0 = the tether; port 2 left-front
= hpm1; port 3 right = hpm2 on nub-spmi-a1 SID 0xc; MagSafe controller hpm5 (port-type 0x11).

| id | question | command | look for |
|---|---|---|---|
| TB-1 | Router per port, generation | `system_profiler SPThunderboltDataType` (UIDs/UUIDs withheld); `ioreg -r -c IOThunderboltSwitchType5 -l -d1` (or `...USB4`) | one router per receptacle, "Thunderbolt Version"/link speed (TB5 80 Gb/s?), receptacle numbers |
| TB-2 | Retimers | `grep -i -E 'uatcrt\|retimer' $D $S` | retimer nodes and whether macOS shows them as separately managed (TEST unknown: AP programming for TB5) |
| TB-3 | DROM | do not export. `ioreg ... DROM` stays in raw only | presence only |
| TB-4 | LSTX / CIO-reconfig | `grep -i -E 'lstx\|cio-reconfig\|reconfig' $D` | node/property names and offsets (hardware description, fine to keep) |

### 3.7 SMC (report: `contrib/pending/smc/`)

macOS has no read-only SMC key CLI; third-party SMC tools are out (rule 2). Get what the registry
and `pmset` expose.

| id | question | command | look for |
|---|---|---|---|
| SMC-1 | Battery values to check macsmc-power against | `ioreg -r -c AppleSmartBattery -l -w0 -d1` (serials withheld); `pmset -g batt` | DesignCapacity, NominalChargeCapacity/AppleRawMaxCapacity (mAh), CycleCount, Voltage, Temperature: the expected B0FC/B0RM magnitudes (report: B0FC 6242, B0RM 5968 after byte swap) |
| SMC-2 | SMC registry properties | `ioreg -r -c AppleSMC -l -d1`; `AppleSMCKeysEndpoint` | SMC firmware/protocol version strings, key count if published |
| SMC-3 | Thermal and fan state | `pmset -g therm`; `sudo powermetrics -n 1 --samplers thermal` (optional, read-only, needs sudo) | thermal pressure; fan RPM range if shown (F0Mx 7826 expected) |
| SMC-4 | smc-pmu pcIO functions | `ioreg -p IODeviceTree -r -n smc-pmu -l -w0`; script `08-smc-battery.txt` | every `function-*` with its word pair; confirms `gp1c` for the AFE reset and lists the other bank-1 users |

### 3.8 Keyboard backlight, ALS, exclave services (report: `contrib/pending/platform/`)

| id | question | command | look for |
|---|---|---|---|
| KBD-1 | Keyboard backlight owner | `ioreg -p IODeviceTree -r -n kbd-backlight -l -w0`; `grep -i -E 'KeyboardBacklight\|kbd' $S` | macOS class driving `pwm0` channel 0; confirms no SMC path |
| ALS-1 | ALS object and calibration | `ioreg -r -a -n als -l` (what asahi-installer's `asahi_firmware/als.py` reads); `ioreg -r -c AppleALSColorSensor -l -d1` | whether `CalibrationData` exists at the path als.py expects (size only), and whether the ALS sits under AOP directly or under the AOP exclave mailbox |
| EXC-1 | Exclave service names | `grep -i exclave $D` (script prints a deduplicated list) | full list of `com.apple.service.*` exclave services on J716s (camera, mic, AOP, display, brightness) |

### 3.9 Trackpad MTP (report: `contrib/pending/trackpad/`)

The AFE reset fix works (3/3 boots); polarity and the 50 ms settle are inferred.

| id | question | command | look for |
|---|---|---|---|
| MTP-1 | macOS power/reset properties | `grep -n -E '"(PowerMethod\|power-sequence\|reset-sequence)"' $S`; script `10-trackpad-mtp.txt` | `PowerMethod 2`; `reset-sequence` bytes `"function-afe-reset" 32 00 01 00`; `power-sequence ... 00 32 00 01` (J716c values). Different bytes on J716s = revisit polarity/settle |
| MTP-2 | MTP firmware version | `grep -i -E 'AppleMTPFirmware\|FirmwareVersion' 10-trackpad-mtp.txt 01-registry.txt` | `AppleMTPFirmwareMac-6320.86.1` (seen under Linux) or a newer string |
| MTP-3 | FUD Multitouch firmware in the bundle | `12-firmware.txt` BuildManifest section: component with `IsFUDFirmware` and a `Multitouch` path | the path `extract-tpmtfw.py` will read (`fud_firmware/<board>/Multitouch.im4p` expected) |

### 3.10 USB-C ports and PD controllers (reports: `contrib/pending/usb/`, `isp-tb/`)

| id | question | command | look for |
|---|---|---|---|
| PD-1 | HPM controllers and their buses | `ioreg -w0 -t -r -c AppleHPMDevice`; `ioreg -w0 -r -c AppleHPMDevice -l -d1 \| grep -E 'RID\|Address'` | each `AppleHPMDevice@<addr>` with `RID`, `Address` and its parent chain (SPMI bus a0/a1). Confirms hpm0/1/2/5 SIDs (0xc, 0xa, 0xc on a1, 0x8) |
| PD-2 | Which `Port-USB-C@N` is which receptacle | `bash docs/macos-scan.sh ports` (interactive: plug a device into each port when asked; it records `ConnectionActive`/`ConnectionCount` per port) | left-back (MagSafe side), left-front, right mapped to `Port-USB-C@1/2/3`; MagSafe controller object name |
| PD-3 | Port capabilities | `ioreg -w0 -r -c AppleTCControllerType10 -l -d1` | `TransportsSupported` per port (CC, USB2, USB3, CIO, DisplayPort), `FW Version` of each PD controller |

### 3.11 PMU scratchpad (reports: `platform/`, `smc/`, status "boot-failure counter")

Known and verified on hardware: Abbey cells `boot_stage` 0xf801, counts 0xf802, `shutdown_flag`
0xf80f bit 3. Missing: the ADT's own description, to replace the inference.

| id | question | command | look for |
|---|---|---|---|
| PMU-1 | Scratchpad layout properties | `grep -n -E 'info-leg_scrpad\|info-rtc_scrpad\|info-clock_offset\|scrpad\|boot_stage\|shutdown' $D`; script `11-pmu-scratchpad.txt` | values of `info-leg_scrpad`, `info-rtc_scrpad`, `info-clock_offset` on the abbey/PMU node (offsets are hardware description: keep) |
| PMU-2 | macOS PMU boot reporting | `grep -E '"IOPMU[A-Za-z]*"' $S` | `IOPMUBootAppName`, `IOPMUBootErrorAppName`, boot stage/error keys after the Linux boots: did macOS see failed boots? |

### 3.12 Firmware extraction prep

| id | question | command | look for |
|---|---|---|---|
| FW-1 | Restore bundle inventory | `ls /System/Volumes/Preboot/*/restore/`, `.../restore/Firmware/**` with sha256 and IM4P headers (script) | Firmware dirs (Studio 27.2: agx, all_flash, ane, AOP, ave, dcp, pmp, scodec, plus SmartIOFirmware, sptm, txm); kernelcache name (`kernelcache.release.mac17*`) |
| FW-2 | BuildManifest components for j716sap | script `12-firmware.txt` (plutil per component; the bundle carries only this Mac's identity) | per component: path and `Is*` flags (`IsLoadedByiBoot`, `IsFUDFirmware`, `IsFirmwarePayload`...). Read the flags rather than assuming: on the Studio's 27.2 bundle `Ap,DCP2` is `IsFUDFirmware` only while AOP, ANE0 and AVE are `IsFUDFirmware,IsLoadedByiBoot`; extract-tpmtfw.py's rule (`IsFUDFirmware` and not `IsLoadedByiBoot`) only takes Multitouch today |
| FW-3 | /usr/standalone/firmware FUD | `ls -R /usr/standalone/firmware/FUD` (script hashes them) | Multitouch / trackpad / keyboard FUD images for j716s |
| FW-4 | Stub bundle = main bundle | `sudo bash docs/macos-scan.sh stub` | same build and hashes (see DCP-4) |

What holds what, and who extracts it:

| firmware | where macOS keeps it | loaded by | extractor today |
|---|---|---|---|
| DCP (`dcpf`, `dcp2`) | restore `Firmware/dcp/` | iBoot (`boot-object-manifests`) | none needed as a file; only its build/hash identifies the ABI |
| GPU (`gfxf`, `armfw_*`) | restore `Firmware/agx/` | iBoot | none needed; `contrib/pending/gpu/scripts/gfx-fw-read.py` identifies it from DRAM under Linux |
| ANS (NVMe) | iBoot payload (all_flash / manifest) | iBoot | none needed (works) |
| MTP trackpad RTKit | manifest, `IsLoadedByiBoot` | iBoot | none needed |
| MTP trackpad CBOR blob `apple/tpmtfw-j716s.bin` | restore FUD `Multitouch.im4p` | Linux (dockchannel-hid) | `~/Work/omarchy-m5/scripts/extract-tpmtfw.py` (from asahi-installer `multitouch.py`; stub's bundle) |
| N1 personalized FTAB | unknown (N1-1) | Linux (aurora `centauri_pci` via `request_firmware_direct`) | none: new extractor needed once N1-1 is answered |
| ALS calibration `apple/aop-als-cal.bin` | ioreg `als` `CalibrationData` | Linux (aop_als) | asahi-installer `asahi_firmware/als.py` (path in the tree may differ on M5: ALS-1) |
| ISP setfiles | kernelcache / ISP firmware | Linux (apple-isp) | asahi-installer `asahi_firmware/isp.py` (moot while the ISP is exclave-owned) |
| Broadcom Wi-Fi/BT | `/usr/share/firmware/{wifi,bluetooth}` | n/a on M5 | asahi-installer `wifi.py`/`bluetooth.py` do not apply to the N1 |
| Stage-2 mBoot | stub Preboot restore bundle | iBoot | `host/macos/refresh-stub-firmware.sh` (not during travel: mounts read-write) |

## 4. What stays manual / for Sunday

- DCP TEST-PLAN 0c (brightness carry-over into Linux) and any Linux-side read (`dcp-devmem-check.sh`,
  `gfx-fw-read.py`) need a Linux boot: Sunday, not part of this scan.
- `powermetrics` and the `stub` step need sudo: Rolando runs them himself in Terminal, not Claude Code.

## 5. Offline clean-room reading (no hardware, no Apple binaries)

| # | read | why |
|---|---|---|
| R1 | aurora-silicon/linux `t6050/dcp` (d977897ba23f): `iomfb_v27.c`, the v27 swap record (brightness 0x354/0x35e), `firmware-compat` handling; `j716c/t6050-platform` DT comment on 27.0 vs 27.2 method IDs; aurora-silicon/aura firmware table | to know which build identity (kext version, DCP firmware hash, macOS build) their table was taken from, so DCP-1/2/4 can be matched to it directly |
| R2 | aurora `t6050/centauri-core` (a3cc811), `centauri-wifi`, `centauri-bluetooth`, `j716c/t6050-n1`, `j716c/t6050-pcie`, and `Documentation/arch/arm64/aurora-apif-centauri.rst` | FTAB expectations (`rkosftab` magic, platform id, BAR0 handshake, firmware-name) decide what N1-1/N1-3 must find and what the extractor must produce |
| R3 | aurora `drivers/gpu/drm/asahi/g17/` (`fwid.rs`, init gate) on `integration/aurora`; Mesa `aurora-wip` `agx_params_m5_bringup_supported()` | how they identify GPU firmware builds; whether GPU-2's IM4P hash or a TEXT hash is the key, and which build their private M5 runtime targets |
| R4 | aurora `sound/soc/apple/aop_spkr.rs`, J616 macaudio variant, `speakersafetyd-aurora-profiles/j616.conf` | the AOP speaker transport to port; which AOP service names (AUD-2) and calibration keys (AUD-1) it relies on |
| R5 | aurora `j716c/thunderbolt` (81bd9173..2ac11995), esp. ffb98ff6 (PHY firmware data restore) | which tunables/DROM fields come from the ADT vs m1n1, and what TB-1/TB-2 answers change |
| R6 | aurora trackpad commits 90916bb664 (J700) and c15edd5f86 (J813) | their polarity and settle choices vs MTP-1's `reset-sequence` bytes |
| R7 | asahi-installer `src/stub.py` `collect_firmware()`, `asahi_firmware/{multitouch,als,isp}.py` (local: `~/Work/asahi-installer`) | the FUD selection rule (`IsFUDFirmware` and not `IsLoadedByiBoot`) behind FW-2, and the ALS ioreg path behind ALS-1 |
| R8 | AsahiLinux docs and progress reports already cited in the reports (asahilinux.org/2026/08/progress-report-7-2/, asahilinux.org/docs/sw/audio-userspace/), plus the docs-site pages on the boot process / stub and on DCP | M3-era DCP ABI handling (14.8.3), speaker-safety model, stub/LocalPolicy behaviour behind DCP-4 |
| R9 | ADevWithAnIdea/apple-silicon-re `docs/sptm/uat.md` | SAPT/UAT semantics behind GPU-4 |

## 6. Mac Studio validation: what matched, what differs per machine

Ran on the Studio (J475d, M2 Ultra, macOS 27.2 26B123), 2026-11-05.

Same on any Mac with the same macOS build (so 27.2 values above are indicative, 26C5035r values
come from the MacBook): kext versions and match strings (AGXG17X 362.5.1, AppleMobileDispT605X-DCP 140.0,
AudioDMAController_T605x 600.45, AppleCentauriManager personalities), the restore bundle's
`centauri/` manifests list, IM4P header types.

Differs per machine (only the MacBook can answer): everything in the registry dumps; DT `board-id`
(Studio `<0a000000>`), `chip-id`; `/chosen/firmware-version` (Studio `mBoot-20457.41.3`; the
MacBook's main volume should show its 27.3b1 mBoot, but the stub's own pairing is only in the stub
Preboot, DCP-4); the restore bundle's Firmware set (it holds only this Mac's BuildIdentity: the
Studio's has `j475dap` only, so the j716sap component list exists only on the MacBook); GPU core
count; coprocessor version strings; ports/HPM layout (Studio: 6 Type-C controllers, 7 HPM devices).

Command-form notes from the validation:
- `ioreg -p IODeviceTree` prints most DT values as little-endian hex blobs; strings such as
  `firmware-version` decode cleanly (the script decodes them).
- `plutil -convert json` fails on `BuildManifest.plist` (it contains data objects); the script uses
  `plutil -extract` per key instead. `diskutil apfs list -plist` converts fine.
- The DCP RTBuddy objects expose no `FirmwareVersion` on the Studio; AOP does. Expect the same on
  the MacBook, hence DCP-1/2/4 rely on files and kext versions.
- `system_profiler SPBluetoothDataType`, `SPAirPortDataType`, `SPAudioDataType` and `SPCameraDataType`
  include paired-device names and nearby network names; the script trims or redacts them.
- An external display's `DisplayAttributes.ProductAttributes` carries its serial numbers inline;
  the nested-dictionary redaction handles it (verified).
- `/bin/bash` is 3.2 and `/usr/bin/python3` may be a CLT stub: the script uses bash 3.2 syntax and
  perl only.
