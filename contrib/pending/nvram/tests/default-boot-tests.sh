#!/bin/bash
# SPDX-License-Identifier: MIT
# Offline tests for tools/nvram-default-boot.sh: fake sysfs, a synthetic NVRAM file (synth-nvram.py, made-up values)
# and a stub asahi-bless that edits the file with apple-nvram's v3 logic (v3-nvram.py's model, which matches
# apple-nvram 3df52c9 byte for byte) and NOR semantics. Nothing here touches a real flash.
#   bash tests/default-boot-tests.sh [WORKDIR]
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd); TOOLS=$HERE/../tools
W=${1:-$(mktemp -d)}; mkdir -p "$W"; W=$(CDPATH='' cd -- "$W" && pwd)
pass=0 fail=0
ok() { echo "PASS  $*"; pass=$((pass + 1)); }
no() { echo "FAIL  $*"; fail=$((fail + 1)); }

mkdir -p "$W/bin"
cat > "$W/bin/asahi-bless" <<'EOF'
#!/usr/bin/env python3
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("v3", os.environ["V3"]); v3 = importlib.util.module_from_spec(spec); spec.loader.exec_module(v3)
T = "EF57347C-0000-AA11-AA11-00306543ECAC"
VOLS = [("Macintosh HD", "11111111-1111-4111-8111-111111111111", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"),
        ("Omarchy", "22222222-2222-4222-8222-222222222222", "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")]
a = sys.argv[1:]; dev = a[a.index("-d") + 1]; nxt = "--next" in a
d = open(dev, "rb").read(); banks, act = v3.parse(d); live = v3.active_vars(banks[act])
def cur(next_):
    v = live.get(("system", b"alt-boot-volume")) if next_ else None
    v = v or live.get(("system", b"boot-volume"))
    for n, p, g in VOLS:
        if v == ("%s:%s:%s" % (T, p, g)).encode(): return n
    return "No boot target set"
if "--list-volumes" in a:
    for i, (n, p, g) in enumerate(VOLS): print("%s%d) %s" % ("*" if cur(False) == n else " ", i + 1, n))
elif "--get-boot" in a: print(cur(nxt))
elif "--set-boot" in a:
    name = a[a.index("--set-boot") + 1]
    m = [x for x in VOLS if x[0].lower() == name.lower()] or [VOLS[int(name) - 1]]
    if open(os.environ["PARAM_FILE"]).read().strip() != "N": sys.exit("Error: Failed to save new nvram contents (EACCES)")
    key = b"alt-boot-volume" if nxt else b"boot-volume"
    p = v3.parse_bank(v3.ser(banks[act])); v3.insert(p, key, ("%s:%s:%s" % (T, m[0][1], m[0][2])).encode())
    if os.environ.get("STUB_EXTRA"): v3.insert(p, b"synthetic-03", b"changed", v3.COMMON)
    old = d[act * v3.PART:(act + 1) * v3.PART]; new = bytes(o & n for o, n in zip(old, v3.ser(p)))
    if os.environ.get("STUB_TORN"):   # driver latches after the page holding the old entry's state byte
        cut = (v3.live_bv(banks[act])[0]["off"] // 256 + 1) * 256; new = new[:cut] + old[cut:]
    open(dev, "r+b").write(d[:act * v3.PART] + new + d[(act + 1) * v3.PART:])
    if os.environ.get("STUB_TORN"): sys.exit("Error: Failed to save new nvram contents (EIO)")
EOF
printf '#!/bin/sh\nexit 0\n' > "$W/bin/flock"
printf '#!/bin/sh\ncat "%s/dmesg" 2>/dev/null\n' "$W" > "$W/bin/dmesg"
chmod +x "$W/bin/"*

setup() {  # setup SCENARIO
    rm -rf "$W/env"; E=$W/env; mkdir -p "$E/sys/bus/platform/devices/505118000.spi" "$E/sys/module/spi_apple_qspi/parameters" \
        "$E/sys/class/power_supply/macsmc-ac" "$E/sys/class/power_supply/macsmc-battery" "$E/sys/class/power_supply/hid-mouse" "$E/state" "$E/dev"
    echo "jedec=c88317 sr1=00 sr2=00 sr3=00" > "$E/sys/bus/platform/devices/505118000.spi/flash_status"
    echo Y > "$E/sys/module/spi_apple_qspi/parameters/read_only"
    echo Mains > "$E/sys/class/power_supply/macsmc-ac/type"; echo 1 > "$E/sys/class/power_supply/macsmc-ac/online"
    echo Battery > "$E/sys/class/power_supply/macsmc-battery/type"; echo 80 > "$E/sys/class/power_supply/macsmc-battery/capacity"
    echo Battery > "$E/sys/class/power_supply/hid-mouse/type"; echo Device > "$E/sys/class/power_supply/hid-mouse/scope"; echo 5 > "$E/sys/class/power_supply/hid-mouse/capacity"
    python3 "$HERE/synth-nvram.py" "$E/dev/mtd2" "$1"
    : > "$W/dmesg"
    mark
}
mark() { { echo "dump_sha256=$(sha256sum "$E/dev/mtd2" | cut -d' ' -f1)"; echo "dev=$E/dev/mtd2"; echo "jedec=c88317"
           echo "flash_status=jedec=c88317 sr1=00 sr2=00 sr3=00"; echo "kernel=test"; echo "time=now"; } > "$E/state/probe.pass"; }
run() {  # run ARGS... -> $out, $rc
    out=$(env PATH="$W/bin:$PATH" SYS="$E/sys" STATE="$E/state" LOCK="$E/lock" NVRAM_PROBE_NOROOT=1 V3="$TOOLS/v3-nvram.py" \
        PARAM_FILE="$E/sys/module/spi_apple_qspi/parameters/read_only" \
        EXPECT_BLESS_SHA256="${BLESS_SHA:-$(sha256sum "$W/bin/asahi-bless" | cut -d' ' -f1)}" \
        bash "$TOOLS/nvram-default-boot.sh" "$@" 2>&1); rc=$?
}
same() { [ "$(sha256sum "$E/dev/mtd2" | cut -d' ' -f1)" = "$(sed -n 's/^dump_sha256=//p' "$E/state/probe.pass")" ]; }
has() { printf '%s\n' "$out" | grep -q -- "$1"; }
ro() { [ "$(cat "$E/sys/module/spi_apple_qspi/parameters/read_only")" = Y ]; }

setup normal
run set omarchy --yes; { [ $rc = 0 ] && has 'already the default' && same; } && ok "omarchy is already the default: exits 0, nothing written" || no "already-default: rc $rc $out"
run set macos --test; { [ $rc = 0 ] && has 'TEST MODE PASSED' && has 'PLAN OK' && has 'sim: a simulated write' && same && ro; } && ok "test mode: plan + simulated verify pass, nothing armed or written" || no "test mode: rc $rc $out"
ls "$E/state/default-backups/"*/nvram-before.bin >/dev/null 2>&1 && ok "test mode keeps a backup" || no "no backup in test mode"
[ "$(stat -f %Lp "$E/state/default-backups" 2>/dev/null || stat -c %a "$E/state/default-backups")" = 700 ] && ok "backup folder is mode 700" || no "backup folder mode"
run set 3 --test; { [ $rc = 1 ] && has 'matches 0 volume groups'; } && ok "unknown index refused" || no "bad index: $out"
run set "Macintosh HD" --test; [ $rc = 0 ] && has "new default: Macintosh HD" && ok "target by name" || no "by name: $out"
run set 1 --test; [ $rc = 0 ] && has "new default: Macintosh HD (list index 1)" && ok "target by index" || no "by index: $out"

echo 0 > "$E/sys/class/power_supply/macsmc-ac/online"; run set macos --test
{ [ $rc = 1 ] && has 'connect the charger'; } && ok "refused on battery power" || no "no AC: $out"
echo 1 > "$E/sys/class/power_supply/macsmc-ac/online"; echo 30 > "$E/sys/class/power_supply/macsmc-battery/capacity"; run set macos --test
{ [ $rc = 1 ] && has 'battery 30 %'; } && ok "refused at 30 % (a 5 % mouse battery is ignored)" || no "low battery: $out"
echo 80 > "$E/sys/class/power_supply/macsmc-battery/capacity"
BLESS_SHA=0000 run set macos --test; { [ $rc = 1 ] && has 'not the audited asahi-bless'; } && ok "refused with another asahi-bless build" || no "bless sha: $out"
echo N > "$E/sys/module/spi_apple_qspi/parameters/read_only"; run set macos --test
{ [ $rc = 1 ] && has 'read_only is not Y'; } && ok "refused when the driver is already armed" || no "armed: $out"
echo Y > "$E/sys/module/spi_apple_qspi/parameters/read_only"
echo "spi-apple-qspi: NVRAM write fault at 0x790000" > "$W/dmesg"; run set macos --test
{ [ $rc = 1 ] && has 'logged a write fault'; } && ok "refused after a logged write fault" || no "fault: $out"
: > "$W/dmesg"
printf '\x00' | dd of="$E/dev/mtd2" bs=1 seek=$((0x95000)) conv=notrunc status=none; run set macos --test
{ [ $rc = 1 ] && has 'changed since the probe'; } && ok "refused when the NVRAM changed since the probe" || no "changed: $out"

for sc in pending tie full zeros badcrc twobv; do
    setup $sc; t=macos; [ $sc = twobv ] && t=omarchy; run set $t --test
    if [ $rc = 1 ] && same && ro; then ok "$sc: refused before arming ($(printf '%s\n' "$out" | grep -E 'REFUSED|FAIL ' | head -n1 | sed 's/^ *//'))"; else no "$sc: rc $rc $out"; fi
done

setup normal
run set macos --yes
{ [ $rc = 0 ] && has 'VERIFY OK' && has '^default: Macintosh HD' && has '^next:    Macintosh HD' && ro; } && ok "write: default -> macOS, verified, driver read-only again" || no "write macos: rc $rc $out"
ls "$E/state/default-backups/"*/nvram-after.bin >/dev/null 2>&1 && ok "after-image kept beside the backup" || no "no after image"
run set omarchy --yes; { [ $rc = 1 ] && has 'changed since the probe'; } && ok "second write needs a fresh probe" || no "stale marker: $out"
mark; run set omarchy --yes
{ [ $rc = 0 ] && has 'VERIFY OK' && has '^default: Omarchy' && ro; } && ok "write: default -> Omarchy again, verified" || no "write omarchy: rc $rc $out"

setup normal; STUB_EXTRA=1 run set macos --yes; export -n STUB_EXTRA 2>/dev/null
out2=$out; { [ $rc = 1 ] && printf '%s\n' "$out2" | grep -q 'UNEXPECTED RESULT' && printf '%s\n' "$out2" | grep -q 'FAIL  the only live variable'; } && ok "a write that also changed another variable is caught" || no "extra: rc $rc $out"
setup normal; STUB_TORN=1 run set macos --yes
{ [ $rc = 1 ] && has 'asahi-bless failed' && has 'VERIFY FAILED' && has 'RECOVERY' && ro; } && ok "torn write (driver latched mid-bank) is reported with the recovery steps" || no "torn: rc $rc $out"

setup normal; for _ in 1 2 3 4 5 6 7; do run set macos --test; sleep 1; done
[ "$(ls -1d "$E/state/default-backups/"*/ | wc -l | tr -d ' ')" = 5 ] && ok "backups pruned to the newest 5" || no "prune: $(ls "$E/state/default-backups")"

setup normal; run status; { [ $rc = 0 ] && has '^default: Omarchy' && has 'one-time target: none' && has 'PLAN OK'; } && ok "status" || no "status: $out"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
