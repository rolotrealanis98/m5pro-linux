#!/bin/bash
# macos-scan.sh: read-only fact collection on the J716s (MacBook Pro 16" M5 Pro, T6050) from macOS,
# for the open questions in contrib/pending/*/REPORT.md. Checklist: docs/macos-scan-checklist.md.
#
#   bash macos-scan.sh            scan: collect, redact, tarball (no sudo, ~2-4 min)
#   bash macos-scan.sh ports      interactive: map Port-USB-C@N to physical ports (plug a device per prompt)
#   sudo bash macos-scan.sh stub  also list the Linux stub's Preboot restore bundle (mounts it READ-ONLY)
#   bash macos-scan.sh redact     re-run only the redaction pass + tarball (after ports/stub)
#
# Read-only by construction: ioreg, system_profiler, sysctl, plutil, kmutil showloaded, nvram -p
# (print only), diskutil list/info, find/ls/stat, shasum. It never runs csrutil, bputil, kmutil
# load/configure, nvram writes, kextload, pmset changes, defaults write or anything that touches
# SIP/LocalPolicy. The only state change anywhere is `stub`'s read-only mount of the stub Preboot
# volume, unmounted again if this script mounted it.
#
# Output: ~/m5scan/<YYYY-MM-DD>/
#   raw/         everything as collected. Contains serial numbers, MACs, UUIDs. NEVER copy this off
#                the MacBook or into the repo. raw/ioreg-*-full.txt are the complete registry dumps.
#   redacted/    targeted extracts with identifiers replaced; SUMMARY.txt is in here, and
#                ANSWERS.md (redacted) if ~/m5scan/<date>/ANSWERS.md exists when redaction runs.
#   m5scan-<date>-redacted.tar.gz   redacted/ only. This is what comes back to the Studio.
# Re-running overwrites that day's directory (idempotent).
#
# Bash 3.2 compatible (macOS /bin/bash). Needs only stock macOS tools (perl is used for redaction).

set -u
umask 077
export LC_ALL=C

CMD=${1:-scan}
DATE=$(date +%F)
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
    HOME_DIR=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
else
    HOME_DIR=$HOME
fi
OUT=${M5SCAN_OUT:-$HOME_DIR/m5scan/$DATE}
RAW=$OUT/raw
RED=$OUT/redacted
TARBALL=$OUT/m5scan-$DATE-redacted.tar.gz
DT_FULL=$RAW/ioreg-devicetree-full.txt
SVC_FULL=$RAW/ioreg-service-full.txt

say() { printf '%s\n' "$*" >&2; }
hdr() { printf '\n===== %s\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }   # log a command and its output

# ---------------------------------------------------------------- helpers over the raw ioreg dumps
# subtree REGEX FILE: every object whose name (before @ / space) matches REGEX, with all of its
# properties and children, as ioreg prints them.
subtree() {
    awk -v re="$1" '
    {
        p = index($0, "+-o ")
        if (p > 0) {
            if (inside && p <= depth) inside = 0
            if (!inside) {
                name = substr($0, p + 4); sub(/[@ ].*/, "", name)
                if (name ~ re) { inside = 1; depth = p; print "----" }
            }
        }
        if (inside) print
    }' "$2"
}
# ctxgrep REGEX FILE: lines whose lower-cased text matches REGEX (give it lower case), each
# preceded once by the "+-o" header of the object it belongs to.
ctxgrep() {
    awk -v re="$1" '
    index($0, "+-o ") > 0 { hdr = $0; shown = 0 }
    tolower($0) ~ re { if (!shown) { print hdr; shown = 1 } if ($0 != hdr) print }' "$2"
}
# dtstr KEY: first value of KEY in the device tree dump, hex blob decoded as a C string.
dtstr() {
    grep -m1 "\"$1\" = " "$DT_FULL" 2>/dev/null | sed 's/.*= //' | perl -ne '
        chomp; if (/^<([0-9a-fA-F]+)>$/) { my $s = pack("H*", $1); $s =~ s/\0.*//s; print "$s\n" } else { print "$_\n" }'
}
# fwlist DIR LABEL HASH(yes|no): names, sizes and (optionally) sha256 of every file under DIR.
fwlist() {
    local d=$1 label=$2 hash=$3
    [ -d "$d" ] || { echo "# $label: $d not present"; return; }
    echo "# $label: $d"
    find "$d" -type f 2>/dev/null | sort | while IFS= read -r f; do
        sz=$(stat -f %z "$f" 2>/dev/null)
        case "$f" in   # personalized / per-device objects: never hash (a hash would be a fingerprint)
            *apticket*|*.im4m|*/boot/*|*[Ff][Tt][Aa][Bb]*|*personaliz*) h="(personalized: no hash)" ;;
            *) if [ "$hash" = yes ]; then h="sha256=$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1)"; else h=""; fi ;;
        esac
        case "$f" in *.im4p) h="$h  im4p=$(im4p_hdr "$f")" ;; esac
        printf '%s  %10s  %s\n' "$h" "$sz" "${f#$d/}"
    done
}
# im4p_hdr FILE: the IM4P header's 4cc type and description string (file metadata only, no payload)
im4p_hdr() {
    perl -e 'open(my $F, "<", $ARGV[0]) or exit; binmode $F; read($F, my $b, 512); my $i = 0;
        sub len { my $l = ord(substr($b, $i++, 1)); if ($l & 0x80) { my $n = $l & 0x7f; $l = 0; $l = ($l << 8) | ord(substr($b, $i++, 1)) for 1 .. $n } $l }
        exit unless ord(substr($b, $i++, 1)) == 0x30; len();
        my @s; for (1 .. 3) { $i++; my $l = len(); push @s, substr($b, $i, $l); $i += $l }
        print "$s[1]:\"$s[2]\"" if $s[0] eq "IM4P";' "$1" 2>/dev/null
}
restore_dirs() { ls -d /System/Volumes/Preboot/*/restore 2>/dev/null; }

# ---------------------------------------------------------------- collection sections
s00_system() {
    hdr "macOS and machine"
    run sw_vers
    run uname -mrsv
    run sysctl hw.model hw.machine hw.ncpu hw.memsize hw.nperflevels kern.osversion kern.osproductversion
    run sysctl -a hw.perflevel0 hw.perflevel1 hw.perflevel2
    run sysctl machdep.cpu.brand_string
    run system_profiler SPHardwareDataType SPSoftwareDataType
    hdr "device tree root / chosen / product (decoded strings)"
    for k in compatible model target-type board-id chip-id platform-name product-soc-name \
             firmware-version system-firmware-version os-firmware-version \
             wifi-chipset product-name product-description; do
        printf '%-26s %s\n' "$k" "$(dtstr "$k")"
    done
    subtree '^(chosen|product)$' "$DT_FULL" | grep -v -E '"(boot-args|boot-uuid|boot-nonce|apfs-preboot-uuid|.*serial.*|.*nonce.*|.*uuid.*|.*mac-address.*)" ='
    hdr "NVRAM: variable names, plus brightness/backlight/boot-args values (print only)"
    nvram -p 2>/dev/null | awk '{print $1}' | sort
    echo "--- values:"
    nvram -p 2>/dev/null | grep -i -E '^(.*backlight.*|.*bright.*|boot-args|auto-boot|.*stage.*|.*boot-?volume.*)\s'
}

s01_dumps() {
    ioreg -l -w0 -p IODeviceTree > "$DT_FULL" 2>/dev/null
    ioreg -l -w0 > "$SVC_FULL" 2>/dev/null
    hdr "IOService class census"
    grep -o '<class [A-Za-z0-9_]*' "$SVC_FULL" | sed 's/<class //' | sort | uniq -c | sort -k2
    hdr "IODeviceTree node names"
    grep -o '+-o [^ <]*' "$DT_FULL" | sed 's/+-o //' | sort | uniq -c | sort -k2
    hdr "kexts loaded (name, version)"
    kmutil showloaded --list-only 2>/dev/null | awk 'NR>1 {print $6, $7}' | sort
    hdr "kexts on disk that match T6050 / T605x hardware (name, version, match strings)"
    for p in /System/Library/Extensions/*.kext/Contents/Info.plist; do
        m=$(plutil -p "$p" 2>/dev/null | grep -o -i -E '"[a-z0-9,_-]*t605[0-9x][a-z0-9,_-]*"' | sort -u | tr '\n' ' ')
        [ -n "$m" ] || continue
        v=$(plutil -extract CFBundleShortVersionString raw -o - "$p" 2>/dev/null)
        k=${p%/Contents/Info.plist}; printf '%-48s %-12s %s\n' "${k##*/}" "$v" "$m"
    done
    hdr "coprocessor firmware versions (RTBuddy / IOP / firmware-version keys, with owning object)"
    ctxgrep '"(firmwareversion|rtkitversion|iofirmwareversion|firmware-version|fw version|firmware version|rom version|iop-version|fw bundle version|fw phy version|fw mac version)"' "$SVC_FULL"
}

s02_dcp() {
    hdr "DT: dcp, dcpext*, disp0, display pipe, backlight, panel"
    subtree '^(dcp|dcpext[0-9]*|disp0|dispext[0-9]*|dart-dcp|dart-disp0|backlight|disp-bklt|twodbl|exbrightpil|dynamic-pil|dp855|exdisplaypipe.*)$' "$DT_FULL"
    hdr "IOService: framebuffers / DCP experts / CLCD (depth-limited key extract)"
    ctxgrep '(iomfb|clcd|framebuffer|dcpexpert|appledcp|mobiledisp|exdisplaypipe|dcp-|dcpext)' "$SVC_FULL" | grep -E '\+-o|"(IOMFB[A-Za-z_]*|DCP[A-Za-z_]*|FirmwareVersion|RTKitVersion|IOClass|IONameMatched|compatible|Firmware[A-Za-z ]*|[A-Za-z]*[Vv]ersion[A-Za-z]*)" ='
    hdr "IOService: brightness / nits / local dimming / panel"
    ctxgrep '(nits|bright|dimming|backlight|panel|edr|xdr|minilED|mini-led|ambient|blmax|blmin)' "$SVC_FULL" | cut -c1-600
    hdr "IOMobileFramebuffer objects, full properties (first 2 levels)"
    for c in IOMobileFramebufferShim AppleCLCD2 IOMobileFramebuffer AppleDCPExpert; do
        printf '\n--- class %s\n' "$c"; ioreg -r -c "$c" -l -w0 -d2 2>/dev/null | cut -c1-2000
    done
    run system_profiler SPDisplaysDataType
}

s03_wireless() {
    hdr "DT: apcie0 and the N1 (centauri) nodes"
    subtree '^(apcie0|pci-bridge0|centauri.*|wlan.*|bluetooth.*|spmi-wifibt|sacm|dart-apcie0)$' "$DT_FULL"
    hdr "DT lines naming centauri / proxima / platform id / wifi"
    ctxgrep '(centauri|proxima|platform-id|wifi-|wlan|bluetooth-|n1-|antenna|module-instance|sku)' "$DT_FULL" | cut -c1-400
    hdr "IOService: PCI devices (vendor/device, class, link status/capabilities)"
    ctxgrep '"(vendor-id|device-id|subsystem-id|class-code|revision-id|iopciexpresslinkstatus|iopciexpresslinkcapabilities|iopciexpresscapabilities|iopcilinkspeed|iopcilinkwidth|pcie-link-speed|pcie-link-width|maximum-link-speed|centauri-builtin|iopcimatch)"' "$SVC_FULL"
    hdr "IOService: Centauri / WLAN / Bluetooth objects"
    ctxgrep '(centauri|proxima|ftab|ioUserNetworkWLAN|wlan|bluetooth|platformconfig|firmwareversion|fw version|chipset|module|board|sku|antenna)' "$SVC_FULL" | cut -c1-600
    for c in AppleCentauriManager AppleCentauriManagerHelper; do
        printf '\n--- class %s\n' "$c"; ioreg -r -c "$c" -l -w0 -d2 2>/dev/null | cut -c1-2000
    done
    hdr "Kexts with Centauri / N1 / WLAN / Bluetooth names: Info.plist personalities and versions"
    for k in /System/Library/Extensions/*.kext; do
        case "${k##*/}" in *[Cc]entauri*|*[Pp]roxima*|*N1*|*WLAN*|*Wlan*|*Bluetooth*|*ACIPC*|*Acipc*)
            printf '\n--- %s\n' "${k##*/}"
            plutil -p "$k/Contents/Info.plist" 2>/dev/null | grep -E '"(CFBundleShortVersionString|CFBundleVersion|IOClass|IOProviderClass|IONameMatch|IOPCIMatch|IOPropertyExistsMatch|IOPropertyMatch)" =>|"[a-z0-9]+,t6?05[0-9x]' ;;
        esac
    done
    hdr "Firmware files that look like N1 / Wi-Fi / BT (names and sizes only; FTAB is personalized)"
    find /usr/share/firmware /usr/standalone/firmware /System/Library/Extensions /Library/Apple \
         /System/Volumes/Preboot /System/Library/PrivateFrameworks/*WiFi* /System/Library/PrivateFrameworks/*Bluetooth* \
         \( -iname '*centauri*' -o -iname '*proxima*' -o -iname '*ftab*' -o -iname '*rkos*' -o -iname '*n1*fw*' \
            -o -iname '*j716s*' -o -iname '*acipc*' \) 2>/dev/null \
        | grep -v -E '\.metallib$' | sort | while IFS= read -r f; do printf '%10s  %s\n' "$(stat -f %z "$f" 2>/dev/null)" "$f"; done
    echo "--- /usr/share/firmware/wifi and bluetooth entries (names only):"
    ls -1 /usr/share/firmware/wifi /usr/share/firmware/bluetooth 2>/dev/null
    hdr "system_profiler: Wi-Fi card (network lists withheld), Bluetooth controller (paired devices withheld), PCI"
    system_profiler SPAirPortDataType 2>/dev/null | awk '
        /^ +(Current Network Information|Other Local Wi-Fi Networks):/ { skip = 1; print "          (" $1 " " $2 " ... section withheld)"; next }
        /^ {8}[^ ]/ { skip = 0 } !skip'
    system_profiler SPBluetoothDataType 2>/dev/null | awk '/^ {6}(Connected|Not Connected|Paired|Devices)/ { exit } { print }'
    system_profiler SPPCIDataType 2>/dev/null
}

s04_gpu() {
    hdr "DT: gpu, sgx, gfx-asc, gfx1-asc, sapt, mapper-gfx"
    subtree '^(gpu|sgx|gfx-asc|gfx1-asc|sapt|mapper-gfx.*|gfx|agx.*)$' "$DT_FULL" | cut -c1-600
    hdr "IOService: AGX accelerator keys (core count, generation, firmware)"
    ctxgrep '"(gpu-core-count|num_cores|num_gps|gpu_gen|gpuconfigurationvariable|agxfirmware[a-z]*|firmwareversion|rtkitversion|model|compatible|sapt[a-z_-]*|uat[a-z_-]*|ttbat[a-z_-]*|agx-address-space-mgmt-mode|gptbat-ready|iogles[a-z]*|metalpluginname|performancestatistics)"' "$SVC_FULL" | grep -v -i -E 'userclient' | cut -c1-1500
    for c in AGXAccelerator AGXFirmwareKextG17RTBuddy; do
        printf '\n--- class %s (depth 1)\n' "$c"; ioreg -r -c "$c" -l -w0 -d1 2>/dev/null | grep -v -E '"PerformanceStatistics"' | cut -c1-1500
    done
    hdr "GPU from system_profiler"
    system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset|Cores|Metal|Vendor|Type|Bus'
    hdr "AGX firmware images in the restore bundle(s)"
    for r in $(restore_dirs); do ls -l "$r/Firmware/agx" 2>/dev/null; done
}

s05_audio() {
    hdr "DT: AOP and its audio children, speakers, amps, jack codec, ADMAC/LEAP"
    subtree '^(aop|iop-aop-nub|aop-audio|aop-voicetrigger|aop-exclave-mailbox|aop-exclave-ioreporting|audio.*|codec.*|admac.*|leap.*|hpai|spkr|mca.*|i2c[123]|dart-aop)$' "$DT_FULL" | cut -c1-600
    hdr "DT lines: speaker/mic/secure audio"
    ctxgrep '(speaker|thiele|amp-|sn012776|tas2764|cs42l84|microphone|secure-mic|hpmic|hpai|iop-audio|exclave)' "$DT_FULL" | cut -c1-400
    hdr "IOService: audio objects (amps, codec, AOP audio, mic devices, exclave audio)"
    ctxgrep '(sn012776|tas27|cs42l|amp|speaker|calib|microphone|lpmic|aopaudio|iopaudio|exclavesaudio|isolated|secure|leap|admac|voicetrigger|spu)' "$SVC_FULL" | grep -E '\+-o|"[^"]*" =' | cut -c1-600
    run system_profiler SPAudioDataType
    hdr "kexts loaded that carry audio / exclave names"
    kmutil showloaded --list-only 2>/dev/null | awk 'NR>1 {print $6, $7}' | grep -i -E 'audio|exclave|aop|spu|admac|leap' | sort
}

s06_isp() {
    hdr "DT: ISP and exclave camera proxies, privacy indicator"
    subtree '^(isp.*|dart-isp.*|camera.*|exbrightpil|dynamic-pil|mpm)$' "$DT_FULL" | cut -c1-600
    hdr "IOService: camera / ISP objects"
    ctxgrep '(isp|camera|h1[0-9]camera|exclave)' "$SVC_FULL" | grep -E '\+-o|"(IOClass|IONameMatched|FirmwareVersion|RTKitVersion|[A-Za-z ]*[Vv]ersion|exclave[^"]*|Sensor[^"]*|Model[^"]*)" =' | cut -c1-600
    run system_profiler SPCameraDataType
}

s07_tb_usb() {
    hdr "DT: Type-C / USB4 / ATC / HPM / DRD nodes (thunderbolt-drom is withheld by redaction)"
    subtree '^(atc-phy[0-9]*|atc[0-9]*|acio[0-9]*|acio-phy-cpu[0-9]*|dart-acio[0-9]*|usb-drd[0-9]*|apciec[0-9]*|hpm[0-9]*|nub-spmi-a[0-9]*|uatcrt.*|lstx.*|usb4.*)$' "$DT_FULL" | grep -v -E '"(thunderbolt-drom|DROM)"' | cut -c1-600
    hdr "IOService: HPM (PD controllers) with their place in the tree (bus parent)"
    ioreg -w0 -t -r -c AppleHPMDevice 2>/dev/null | grep -E '\+-o' | cut -c1-300
    ioreg -w0 -r -c AppleHPMDevice -l -d1 2>/dev/null | grep -E '\+-o|"(RID|Address|Version|IOClass)" ='
    hdr "IOService: Type-C port controllers (Port-USB-C@N, Port-MagSafe...)"
    ioreg -w0 -r -c AppleTCControllerType10 -l -d1 2>/dev/null | grep -E '\+-o|"(PortDescription|PortType|PortTypeDescription|TransportsSupported|TransportsProvisioned|BuiltIn|ConnectionActive|ConnectionCount|FW Version|IOAccessoryPrimaryDevicePort|Pin Configuration|IOAccessoryUSBConnectString)" ='
    ctxgrep '(port-magsafe|magsafe|parentbuiltinportnumber|usbcportnumber|port-usb-c)' "$SVC_FULL" | grep -E '\+-o|"(PortDescription|ParentBuiltInPortNumber|UsbCPortNumber|PortNumber|Description)" =' | cut -c1-300
    hdr "IOService: Thunderbolt switches/routers (UID and DROM withheld by redaction)"
    ctxgrep '(iothunderboltswitch|thunderbolt version|router|link speed|link width|generation)' "$SVC_FULL" | grep -v -E '"(DROM|UID)"' | cut -c1-400
    run system_profiler SPThunderboltDataType SPUSBHostDataType SPPowerDataType
}

s08_smc() {
    hdr "IOService: AppleSMC and clients (properties only; there is no read-only macOS CLI for SMC keys)"
    for c in AppleSMC AppleSMCKeysEndpoint AppleSMCInterface AppleSMCLMU; do
        printf '\n--- class %s\n' "$c"; ioreg -r -c "$c" -l -w0 -d1 2>/dev/null | cut -c1-800
    done
    hdr "IOService: battery (capacity, cycle count, design values; serials withheld)"
    ioreg -r -c AppleSmartBattery -l -w0 -d1 2>/dev/null | grep -v -E '"(BatteryData|ManufacturerData|BatteryInvalidWakeSeconds)"' | cut -c1-600
    run pmset -g batt
    run pmset -g therm
    run pmset -g ps
    hdr "DT: smc, smc-pmu (pcIO functions), SPMI buses, PMU (abbey)"
    subtree '^(smc|iop-smc-nub|smc-pmu|nub-spmi[0-9a-z-]*|spmi-abbey|abbey|pmu.*|spmi[0-9]*)$' "$DT_FULL" | cut -c1-600
    hdr "DT lines: pcIO / gP / gp functions and SMC key references"
    ctxgrep '(function-|pcio|gp[0-9a-f][0-9a-f]|smc-)' "$DT_FULL" | grep -E '\+-o|"function-[^"]*" =' | cut -c1-400
}

s09_backlight_als_kbd() {
    hdr "DT: keyboard backlight PWM, ALS, lid angle, buttons"
    subtree '^(pwm[0-9]*|kbd-backlight|als|las|lid.*|buttons|accel|gyro|keyboard.*)$' "$DT_FULL" | cut -c1-600
    hdr "IOService: backlight / keyboard backlight / ALS objects"
    ctxgrep '(backlight|keyboardbacklight|kbd|als|ambient|lux|calibrationdata|colorsensor|lmu)' "$SVC_FULL" | grep -E '\+-o|"[^"]*" =' | cut -c1-600
    hdr "Exclave services named anywhere in the device tree"
    grep -i -E 'exclave' "$DT_FULL" | grep -o -E '"[^"]*" = .*' | perl -pe 's/<([0-9a-fA-F]+)>/my $s=pack("H*",$1); $s=~s|\0+$||; $s=~s|\0| |g; ($s=~m|^[\x20-\x7e]+$|) ? "\"$s\"" : "<$1>"/ge' | sort | uniq -c
    hdr "ExclaveOS cryptex (names only)"
    find /System/Volumes/Preboot/Cryptexes/ExclaveOS -maxdepth 4 2>/dev/null | head -200
}

s10_trackpad() {
    hdr "DT: dockchannel-mtp, mtp-transport, multi-touch, stm"
    subtree '^(dockchannel-mtp|mtp-transport|multi-touch|stm|keyboard|actuator|tp-accel|mtp.*)$' "$DT_FULL" | cut -c1-600
    hdr "IOService: MTP / multitouch power and reset properties"
    ctxgrep '(powermethod|power-sequence|reset-sequence|function-afe-reset|function-stm-reset|afe|mtpfirmware|multitouch|mtp|dockchannel)' "$SVC_FULL" | grep -E '\+-o|"[^"]*" =' | cut -c1-600
}

s11_pmu() {
    hdr "DT: PMU scratchpad / boot stage / fault names (info-* properties)"
    ctxgrep '(scrpad|scratch|boot_stage|boot-stage|bootstage|shutdown|info-leg|info-rtc|info-clock|fault_name|event_name|pmu)' "$DT_FULL" | cut -c1-400
    hdr "IOService: PMU boot/fault reporting keys"
    ctxgrep '"(iopmu[a-z]*|boot stage|bootstage|boot_stage|bootfailure|boot-error|panic[a-z ]*)"' "$SVC_FULL" | cut -c1-400
}

s12_firmware() {
    hdr "Main macOS restore bundle(s) on Preboot (names, sizes, sha256 of non-personalized files)"
    for r in $(restore_dirs); do
        echo "## bundle: $r"
        for p in SystemVersion.plist RestoreVersion.plist; do
            printf '%s: %s %s\n' "$p" "$(plutil -extract ProductVersion raw -o - "$r/$p" 2>/dev/null)" "$(plutil -extract ProductBuildVersion raw -o - "$r/$p" 2>/dev/null)"
        done
        ls -1 "$r" 2>/dev/null | grep -v -E '^apticket\.' ; echo "(apticket.*.im4m: $(ls "$r" 2>/dev/null | grep -c '^apticket\.') files, not listed)"
        fwlist "$r/Firmware" "restore Firmware" yes
        fwlist "$r/centauri" "restore centauri (N1 manifests)" no
        ls -1 "$r" 2>/dev/null | grep -i -E 'kernelcache|sptm|txm' | while read -r f; do printf '%10s  %s\n' "$(stat -f %z "$r/$f")" "$f"; done
        local bm="$r/BuildManifest.plist" n=0 dc
        printf -- '--- BuildManifest %s %s: identities and components (Path, Is* flags)\n' \
            "$(plutil -extract ProductVersion raw -o - "$bm" 2>/dev/null)" "$(plutil -extract ProductBuildVersion raw -o - "$bm" 2>/dev/null)"
        while dc=$(plutil -extract "BuildIdentities.$n.Info.DeviceClass" raw -o - "$bm" 2>/dev/null); do
            printf '\n## identity %s: %s / %s\n' "$n" "$dc" "$(plutil -extract "BuildIdentities.$n.Info.Variant" raw -o - "$bm" 2>/dev/null)"
            plutil -extract "BuildIdentities.$n.Manifest" raw -o - "$bm" 2>/dev/null | while IFS= read -r c; do
                p=$(plutil -extract "BuildIdentities.$n.Manifest.$c.Info.Path" raw -o - "$bm" 2>/dev/null)
                fl=$(plutil -extract "BuildIdentities.$n.Manifest.$c.Info" xml1 -o - "$bm" 2>/dev/null \
                     | perl -0ne 'print join(",", /<key>(Is[A-Za-z]+)<\/key>\s*<true\/>/g)')
                printf '%-30s %-72s %s\n' "$c" "$p" "$fl"
            done
            n=$((n + 1))
        done
    done
    hdr "/usr/standalone/firmware (names, sizes; sha256 for FUD)"
    fwlist /usr/standalone/firmware/FUD "FUD" yes
    find /usr/standalone/firmware -maxdepth 2 2>/dev/null | sort
    hdr "/usr/share/firmware (names, sizes)"
    fwlist /usr/share/firmware "share/firmware" no
    hdr "Preboot: every *.im4p / *.bin / *.img4 by name (UUID path parts are redacted later)"
    find /System/Volumes/Preboot -type f \( -iname '*.im4p' -o -iname '*.img4' -o -iname '*.bin' \) 2>/dev/null \
        | grep -v -E '/boot/[0-9A-Fa-f]{32,}/' | sort | while IFS= read -r f; do printf '%10s  %s\n' "$(stat -f %z "$f" 2>/dev/null)" "$f"; done
    echo "(per-device boot/<hash>/ objects not listed)"
    hdr "Volumes (for locating the Linux stub; read-only listing)"
    run diskutil list internal
    diskutil apfs list 2>/dev/null | grep -E 'Container disk|Name:|Role|Capacity Consumed|Mount Point|APFS Volume Disk' | head -120
}

stub_preboot() {   # root only: list the stub's Preboot restore bundle (stub System volume named Omarchy*)
    [ "$(id -u)" = 0 ] || { say "stub: run with sudo (it mounts the stub Preboot READ-ONLY)"; exit 1; }
    mkdir -p "$RAW"
    local name=${STUB_NAME:-Omarchy} pb mnt we_mounted=0
    pb=$(diskutil apfs list -plist | plutil -convert json -o - - | perl -MJSON::PP -e '
        local $/; my $d = decode_json(<STDIN>); my $name = shift;
        for my $c (@{ $d->{Containers} }) { my @v = @{ $c->{Volumes} || [] };
            next unless grep { (grep { $_ eq "System" } @{ $_->{Roles} || [] }) && ($_->{Name} // "") =~ /^\Q$name\E/ } @v;
            for (@v) { print "$_->{DeviceIdentifier}\n" if grep { $_ eq "Preboot" } @{ $_->{Roles} || [] } } }' "$name")
    [ -n "$pb" ] || { say "stub: no APFS container with a System volume named $name*"; exit 1; }
    mnt=$(diskutil info "$pb" | awk -F': *' '/Mount Point/{print $2}')
    if [ -z "$mnt" ] || [ "$mnt" = "Not mounted" ]; then
        diskutil mount readOnly "$pb" >/dev/null || { say "stub: could not mount $pb read-only"; exit 1; }
        we_mounted=1; mnt=$(diskutil info "$pb" | awk -F': *' '/Mount Point/{print $2}')
    fi
    {
        hdr "Linux stub Preboot ($pb, mounted read-only by this script: $we_mounted)"
        for r in "$mnt"/*/restore; do
            [ -d "$r" ] || continue
            echo "## stub bundle: $r"
            printf 'SystemVersion: %s %s\n' "$(plutil -extract ProductVersion raw -o - "$r/SystemVersion.plist" 2>/dev/null)" "$(plutil -extract ProductBuildVersion raw -o - "$r/SystemVersion.plist" 2>/dev/null)"
            printf 'BuildManifest: %s\n' "$(plutil -extract ProductBuildVersion raw -o - "$r/BuildManifest.plist" 2>/dev/null)"
            fwlist "$r/Firmware" "stub restore Firmware" yes
            fwlist "$r/centauri" "stub restore centauri" no
        done
        find "$mnt" -path '*CoreServices*' -name SystemVersion.plist 2>/dev/null | while read -r f; do
            printf '%s: %s %s\n' "$f" "$(plutil -extract ProductVersion raw -o - "$f")" "$(plutil -extract ProductBuildVersion raw -o - "$f")"
        done
        echo "--- names matching dcp / agx / ftab / centauri anywhere in the stub Preboot:"
        find "$mnt" -type f \( -iname '*dcp*' -o -iname '*agx*' -o -iname '*armfw*' -o -iname '*centauri*' -o -iname '*ftab*' \) 2>/dev/null \
            | while read -r f; do printf '%10s  %s\n' "$(stat -f %z "$f")" "$f"; done
    } > "$RAW/13-stub-preboot.txt" 2>&1
    [ "$we_mounted" = 1 ] && diskutil unmount "$pb" >/dev/null
    [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$OUT"
    say "stub: wrote $RAW/13-stub-preboot.txt"
}

ports_map() {   # interactive: which Port-USB-C@N is which physical receptacle
    mkdir -p "$RAW"
    snap() { ioreg -w0 -r -c AppleTCControllerType10 -l -d1 2>/dev/null | awk '
        /\+-o / { n = $2 } /"ConnectionActive" =/ { a[n] = $NF } /"ConnectionCount" =/ { c[n] = $NF }
        END { for (k in a) printf "%s active=%s count=%s\n", k, a[k], c[k] }' | sort; }
    {
        hdr "Port map, $(date)"
        echo "baseline (unplug everything you can; the charger may stay on MagSafe):"; snap
        for loc in "left-back (next to MagSafe)" "left-front" "right" "MagSafe (charger)"; do
            printf '\n>> Plug a USB device or charger into: %s, then press Enter (or type s to skip) ' "$loc" >&2
            read -r ans </dev/tty; [ "$ans" = s ] && continue
            sleep 3; echo "--- after plugging into $loc:"; snap
            printf '>> Unplug it, then press Enter ' >&2; read -r _ </dev/tty; sleep 2
        done
        hdr "HPM controllers with their bus parents"
        ioreg -w0 -t -r -c AppleHPMDevice 2>/dev/null | grep -E '\+-o' | cut -c1-300
    } | tee "$RAW/14-ports-map.txt"
}

# ---------------------------------------------------------------- redaction
write_redactor() {
cat > "$OUT/.redact.pl" <<'PERL'
#!/usr/bin/perl
# redact.pl IDS_FILE < in > out
use strict; use warnings;
my @lit;
if (open my $fh, '<', $ARGV[0]) { while (<$fh>) { chomp; s/^\s+|\s+$//g; push @lit, $_ if length($_) >= 4 } }
@lit = sort { length($b) <=> length($a) } @lit;
my $litre = @lit ? join('|', map { quotemeta } @lit) : undef;
my $keyre = qr/serial|mac-?addr|macaddress|btaddress|bt-address|deviceaddress|wifi-?address|bluetooth-?address|bd_?addr|ethernet-?address|uuid|udid|ecid|unique|nonce|imei|meid|iccid|drom|mlb|apple-?id|icloud|dsid|guid|consoleusers|^uid$|owner|calib|provision|activation|user ?name|computer ?name|host ?name|local ?host|email|account|region-info|system-id|ssid|networkname|\bsn\b/i;
sub blob {
    my ($hex) = @_; my $n = length($hex) / 2;
    if ($n >= 8) { my $s = pack('H*', $hex); $s =~ s/\0+$//;
        if (length($s) >= 4 && $s =~ /^[\x20-\x7e\0]+$/) { $s =~ s/\0/|/g; $s =~ tr/"<>/'()/; return "<ascii \"$s\">"; } }
    return $n >= 32 ? "<blob $n bytes>" : "<$hex>";
}
sub redict {   # recurse into an inline dict/array value
    my ($v) = @_;
    $v =~ s/("([^"]*)"\s*=\s*)(\{(?:[^{}]++|\{[^{}]*+\})*+\}|\((?:[^()]++|\([^()]*+\))*+\)|<[^>]*>|"[^"]*"|[^,}){(\s]+)/ my ($a, $k, $w) = ($1, $2, $3); ($k =~ $keyre) ? "$a<REDACTED>" : (index("{(", substr($w, 0, 1)) >= 0 && length($w) < length($v) ? $a . redict($w) : "$a$w") /ge;
    return $v;
}
while (my $l = <STDIN>) {
    $l =~ s/<([0-9a-fA-F]{16,})>/blob($1)/ge;
    # "key" = value, also inside inline dicts {"k"=v,...}: a dict or array value (two levels deep) is
    # recursed into; deeper ones fail to match, so their inner pairs are visited one by one.
    $l =~ s/("([^"]*)"\s*=\s*)(\{(?:[^{}]++|\{[^{}]*+\})*+\}|\((?:[^()]++|\([^()]*+\))*+\)|<[^>]*>|"[^"]*"|[^,}){(\s]+)/ my ($a, $k, $v) = ($1, $2, $3); ($k =~ $keyre) ? "$a<REDACTED>" : (index("{(", substr($v, 0, 1)) >= 0 ? $a . redict($v) : "$a$v") /ge;
    if ($l =~ /^(\s*)([^:"|]{1,60}):\s+(\S.*)$/) { my ($i, $k) = ($1, $2); $l = "$i$k: <REDACTED>\n" if $k =~ $keyre || $k =~ /\baddress\b/i; }
    $l =~ s/\b(?:[0-9a-fA-F]{2}[:-]){7}[0-9a-fA-F]{2}\b/<EUI64>/g;
    $l =~ s/\b(?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}\b/<MAC>/g;
    $l =~ s/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/<UUID>/g;
    $l =~ s/(?<![0-9A-Za-z])[0-9]{15,17}(?![0-9A-Za-z])/<IMEI-LIKE>/g;
    $l =~ s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<EMAIL>/g;
    $l =~ s/(?<!sha256=)\b[0-9a-fA-F]{40,}\b/'<HEX' . length($&) . '>'/ge;
    $l =~ s{/Users/[^/\s"]+}{/Users/<user>}g;
    $l =~ s/[A-Z][\w.-]*(?:'|’)s(?=\s)/<OWNER>'s/g;   # "Name's iPhone" style device names
    $l =~ s/$litre/<ID>/gi if defined $litre;
    print $l;
}
PERL
}

collect_ids() {   # this machine's own identifiers, for literal replacement (stays in raw/, mode 600)
    {
        ioreg -rd1 -c IOPlatformExpertDevice -w0 2>/dev/null | grep -E '"(IOPlatformSerialNumber|IOPlatformUUID|serial-number|mlb-serial-number)"' \
            | sed -E 's/.*= //; s/^"//; s/"$//' | perl -ne 'chomp; if (/^<([0-9a-f]+)>$/i) { my $s = pack("H*", $1); $s =~ s/\0.*//s; print "$s\n" } else { print "$_\n" }'
        system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number|Hardware UUID|Provisioning UDID/{print $2}'
        ifconfig -a 2>/dev/null | awk '/ether /{print $2}' | while read -r m; do echo "$m"; echo "$m" | tr -d ':'; done
        system_profiler SPBluetoothDataType SPAirPortDataType 2>/dev/null | awk -F': ' '/Address:|MAC Address/{print $2}' \
            | while read -r m; do echo "$m"; echo "$m" | tr -d ':-'; done
        scutil --get ComputerName 2>/dev/null; scutil --get LocalHostName 2>/dev/null; hostname 2>/dev/null; hostname -s 2>/dev/null
        id -un 2>/dev/null; id -F 2>/dev/null; id -F 2>/dev/null | awk '{print $1}'; [ -n "${SUDO_USER:-}" ] && echo "$SUDO_USER"
    } | grep -v -E '^\s*$|^(root|Not Available|none)$' | sort -u > "$RAW/.ids"
    chmod 600 "$RAW/.ids"
}

redact_all() {
    [ -d "$RAW" ] || { say "redact: $RAW missing; run a scan first"; exit 1; }
    write_redactor
    perl -c "$OUT/.redact.pl" >/dev/null 2>&1 || { say "REDACTION FAILED: redactor does not compile"; perl -c "$OUT/.redact.pl"; rm -f "$TARBALL"; return 1; }
    collect_ids
    rm -rf "$RED"; mkdir -p "$RED"
    for f in "$RAW"/*.txt; do
        case "${f##*/}" in ioreg-*-full.txt) continue ;; esac
        perl "$OUT/.redact.pl" "$RAW/.ids" < "$f" > "$RED/${f##*/}"
    done
    # answers written by Claude Code on the MacBook (prompt in the checklist) go through the same pass
    [ -f "$OUT/ANSWERS.md" ] && perl "$OUT/.redact.pl" "$RAW/.ids" < "$OUT/ANSWERS.md" > "$RED/ANSWERS.md"
    # verification: no literal identifier and no UUID/MAC-shaped string may survive
    local bad=0
    if [ -s "$RAW/.ids" ] && grep -r -i -l -F -f "$RAW/.ids" "$RED" >/dev/null 2>&1; then
        say "REDACTION FAILED: a literal identifier survived in:"; grep -r -i -l -F -f "$RAW/.ids" "$RED" >&2; bad=1
    fi
    if grep -r -l -E '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' "$RED" >/dev/null 2>&1; then
        say "REDACTION FAILED: UUID/MAC-shaped strings survived in:"; grep -r -l -E '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' "$RED" >&2; bad=1
    fi
    if grep -r -i -l -E '"[^"<]*(serial|uuid|udid|mac-?address|imei|iccid|drom|mlb|ecid|unique-chip)[^"]*" ?= ?("[^<"]|<[0-9a-fA-F"]|[0-9])' "$RED" >/dev/null 2>&1; then
        say "REDACTION FAILED: an identifier-named property kept its value in:"
        grep -r -i -n -o -E '"[^"<]*(serial|uuid|udid|mac-?address|imei|iccid|drom|mlb|ecid|unique-chip)[^"]*" ?= ?("[^<"]|<[0-9a-fA-F"]|[0-9])' "$RED" | cut -c1-200 >&2; bad=1
    fi
    if [ "$bad" = 1 ]; then rm -f "$TARBALL"; say "No tarball written. Fix the redactor and run: bash $0 redact"; return 1; fi
    tar -czf "$TARBALL" -C "$OUT" redacted
    say "redaction OK: $(ls "$RED" | wc -l | tr -d ' ') files; tarball $TARBALL ($(stat -f %z "$TARBALL") bytes)"
}

# ---------------------------------------------------------------- summary
summary() {
    {
        echo "m5scan $DATE  (macos-scan.sh; redacted copy)"
        echo "macOS:            $(sw_vers -productVersion) $(sw_vers -buildVersion)"
        echo "model:            $(sysctl -n hw.model)   compatible: $(dtstr compatible)"
        echo "board-id/chip-id: $(grep -m1 '"board-id" = ' "$DT_FULL" | sed 's/.*= //') / $(grep -m1 '"chip-id" = ' "$DT_FULL" | sed 's/.*= //')"
        echo "chosen firmware-version (stage-2 mBoot, from the boot object's bundle): $(dtstr firmware-version)"
        echo "chosen system-firmware-version (LLB/system):                           $(dtstr system-firmware-version)"
        echo "DCP kext:         $(grep -E '^AppleMobileDispT605X-DCP' "$RAW/01-registry.txt" | head -1)"
        echo "DCP/dcpext firmware strings in IOService (often none are exposed):"
        subtree '^(dcp|dcpext[0-9]*)$' "$SVC_FULL" | grep -E '"(FirmwareVersion|RTKitVersion)" =' | sed 's/^[ |]*/    /' | sort -u | head -8
        echo "DCP firmware in the macOS restore bundle: $(for r in $(restore_dirs); do ls "$r/Firmware/dcp" 2>/dev/null; done | tr '\n' ' ')"
        echo "GPU cores:        $(grep -m1 -E '"gpu-core-count" = ' "$SVC_FULL" | sed 's/.*= //')  ($(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Total Number of Cores/{print $2; exit}') per system_profiler)"
        echo "GPU kext:         $(grep -E '^AGXG17X\.kext' "$RAW/01-registry.txt" | head -1)"
        echo "N1 PCI functions (106b:1900-1903): $(grep -c -E '"device-id" = <0[0-3]190000>' "$SVC_FULL")   centauri objects: $(grep -c -i -E '\+-o .*centauri' "$SVC_FULL")"
        echo "restore bundles:  $(restore_dirs | wc -l | tr -d ' ')   firmware dirs: $(for r in $(restore_dirs); do ls "$r/Firmware" 2>/dev/null; done | sort -u | tr '\n' ' ')"
        echo "Type-C ports:     $(ioreg -w0 -r -c AppleTCControllerType10 -d1 2>/dev/null | grep -c '+-o')   HPM devices: $(ioreg -w0 -r -c AppleHPMDevice -d1 2>/dev/null | grep -c '+-o')"
        echo "files:"; ls -1 "$RAW" | grep -v -E '^\.|full' | sed 's/^/    /'
        echo "Raw dumps (stay on this Mac): ioreg-devicetree-full.txt, ioreg-service-full.txt"
    } > "$RAW/SUMMARY.txt" 2>&1
}

# ---------------------------------------------------------------- main
case "$CMD" in
    scan)
        [ "$(uname -m)" = arm64 ] || { say "Apple silicon only"; exit 1; }
        rm -rf "$RAW" "$RED"; mkdir -p "$RAW"
        say "macos-scan: writing to $OUT (read-only scan)"
        say "  [1/13] registry dumps";  s01_dumps        > "$RAW/01-registry.txt" 2>&1
        say "  [2/13] system";          s00_system       > "$RAW/00-system.txt" 2>&1
        say "  [3/13] dcp/display";     s02_dcp          > "$RAW/02-dcp-display.txt" 2>&1
        say "  [4/13] wireless (N1)";   s03_wireless     > "$RAW/03-wireless-n1.txt" 2>&1
        say "  [5/13] gpu";             s04_gpu          > "$RAW/04-gpu.txt" 2>&1
        say "  [6/13] audio";           s05_audio        > "$RAW/05-audio.txt" 2>&1
        say "  [7/13] isp/camera";      s06_isp          > "$RAW/06-isp-camera.txt" 2>&1
        say "  [8/13] tb/usb/pd";       s07_tb_usb       > "$RAW/07-tb-usb-pd.txt" 2>&1
        say "  [9/13] smc/battery";     s08_smc          > "$RAW/08-smc-battery.txt" 2>&1
        say "  [10/13] backlight/als";  s09_backlight_als_kbd > "$RAW/09-backlight-als-kbd.txt" 2>&1
        say "  [11/13] trackpad";       s10_trackpad     > "$RAW/10-trackpad-mtp.txt" 2>&1
        say "  [12/13] pmu";            s11_pmu          > "$RAW/11-pmu-scratchpad.txt" 2>&1
        say "  [13/13] firmware";       s12_firmware     > "$RAW/12-firmware.txt" 2>&1
        summary
        redact_all
        echo; cat "$RED/SUMMARY.txt" 2>/dev/null
        echo; echo "Next (optional): bash $0 ports   |   sudo bash $0 stub   then: bash $0 redact"
        ;;
    ports)  ports_map; say "now run: bash $0 redact" ;;
    stub)   stub_preboot; say "now run: bash $0 redact (as your user)" ;;
    redact) [ -f "$DT_FULL" ] && summary; redact_all ;;
    -h|--help|help) sed -n '2,24p' "$0" ;;
    *) say "unknown command $CMD (scan|ports|stub|redact|help)"; exit 2 ;;
esac
