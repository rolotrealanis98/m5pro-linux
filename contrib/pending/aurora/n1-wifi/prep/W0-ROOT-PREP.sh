#!/usr/bin/env bash
# W0-ROOT-PREP.sh - root prep on the J716s (Arch Linux ARM root, nvme0n1p5) before the N1 Wi-Fi test boots W0/W1.
# Run as root on the MacBook, over SSH, with the Ethernet adapter up:
#     bash W0-ROOT-PREP.sh /root/j716s-ftab.bin
# The only argument is the FTAB file the coordinator scp'd to the MacBook first. Private: the FTAB is per unit;
# never copy it into a repo. Idempotent: safe to run again; re-running with the same file changes nothing.
#
# What it does:
#   1. checks the FTAB (size, "rkosftab" magic at 0x20) and installs it, unmodified, as
#      /usr/lib/firmware/apple/centauri/j716s-ftab.bin (root:root 0644; /lib -> usr/lib on Arch).
#      The kernel asks for exactly this name: the J716s DT control function has
#      firmware-name = "apple/centauri/j716s-ftab.bin", and centauri_pci.c reads it with
#      request_firmware_direct(&fw, c->firmware_name, dev) (no helper, no fallback, no compression).
#   2. pacman -S --needed --noconfirm iwd wireless-regdb bluez bluez-utils   (never -Syu; no -y)
#   3. enables and starts NOTHING, writes no iwd/networkd config, leaves 20-wired.network alone.
#   4. prints a checklist. Exit status 0 = everything in the checklist is OK or only a WARN.
set -u
FW_REL=apple/centauri/j716s-ftab.bin
FW_DST=/usr/lib/firmware/$FW_REL
PKGS=(iwd wireless-regdb bluez bluez-utils)
SRC=${1:-}
fail=0; warn=0
ok()   { printf '  [ ok ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=1; }
wrn()  { printf '  [WARN] %s\n' "$*"; warn=1; }

[ "$#" -eq 1 ] || { echo "usage: $0 <path-to-ftab.bin>   (exactly one argument)" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 2; }
[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 2; }

echo "== 1. firmware =="
size=$(stat -c %s "$SRC")
magic=$(dd if="$SRC" bs=1 skip=32 count=8 2>/dev/null | tr -d '\0')
if [ "$size" -lt 1048576 ] || [ "$size" -gt 67108864 ]; then
    echo "refusing: $SRC is $size bytes (driver accepts 0x30..64 MiB; a real FTAB is tens of MB)" >&2; exit 2
fi
if [ "$magic" != "rkosftab" ]; then
    echo "refusing: bytes 0x20..0x27 of $SRC are not the FTAB magic" >&2; exit 2
fi
src_sha=$(sha256sum "$SRC" | cut -d' ' -f1)
dst_sha=$(sha256sum "$FW_DST" 2>/dev/null | cut -d' ' -f1 || true)
if [ "$src_sha" = "${dst_sha:-none}" ]; then
    echo "  already installed with identical content: leaving it"
else
    install -D -m 0644 -o root -g root "$SRC" "$FW_DST.new" && sync && mv -f "$FW_DST.new" "$FW_DST" && sync \
        || { echo "install failed" >&2; rm -f "$FW_DST.new"; exit 1; }
    echo "  installed $FW_DST"
fi
dst_sha=$(sha256sum "$FW_DST" | cut -d' ' -f1)

echo "== 2. packages =="
missing=()
for p in "${PKGS[@]}"; do pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ "${#missing[@]}" -eq 0 ]; then
    echo "  all installed already: ${PKGS[*]}"
else
    echo "  installing: ${missing[*]}  (pacman -S --needed --noconfirm; no -y, no -u)"
    if ! pacman -S --needed --noconfirm "${PKGS[@]}"; then
        echo "  pacman failed. If it says 'target not found' or 404, the local sync database is stale." >&2
        echo "  Do NOT run -Syu from a script: report it to the human (a partial -Sy upgrade is not allowed)." >&2
    fi
fi

echo "== 3. checklist =="
[ "$(readlink -f /lib/firmware/$FW_REL)" = "$FW_DST" ] && ok "/lib/firmware/$FW_REL resolves to $FW_DST" || bad "/lib/firmware does not resolve to /usr/lib/firmware (is /lib a symlink to usr/lib?)"
[ "$(stat -c '%U:%G %a' "$FW_DST")" = "root:root 644" ] && ok "owner root:root, mode 0644" || bad "owner/mode wrong: $(stat -c '%U:%G %a' "$FW_DST")"
[ "$(dd if="$FW_DST" bs=1 skip=32 count=8 2>/dev/null)" = "rkosftab" ] && ok "installed file has the rkosftab magic" || bad "installed file lacks the rkosftab magic"
[ "$(stat -c %s "$FW_DST")" -eq "$size" ] && ok "size $size bytes (compare with the Studio: stat -f %z on ftab.bin)" || bad "size differs from the source"
echo "  sha256 of the installed file (compare by eye with: shasum -a 256 on the Studio's ftab.bin): ${dst_sha}"
for p in "${PKGS[@]}"; do pacman -Qq "$p" >/dev/null 2>&1 && ok "package $p $(pacman -Q "$p" | cut -d' ' -f2)" || bad "package $p missing"; done
for u in iwd bluetooth wpa_supplicant NetworkManager; do
    st=$(systemctl is-enabled "$u" 2>&1 | head -1)
    case "$u:$st" in
        iwd:enabled|bluetooth:enabled) wrn "$u is enabled (this script enables nothing; it was already so)";;
        wpa_supplicant:enabled|NetworkManager:enabled) wrn "$u is enabled: it would fight iwd / take over eth (ROOT-SETUP 2)";;
        *) ok "$u is-enabled: $st";;
    esac
done
for u in systemd-networkd; do
    systemctl is-active "$u" >/dev/null 2>&1 && ok "$u active (keeps DHCP on the Ethernet; do not touch)" || wrn "$u not active"
done
ls /etc/systemd/network/20-wired.network >/dev/null 2>&1 && ok "20-wired.network present (left untouched)" || wrn "no 20-wired.network: how does the Ethernet get its address?"
# phram: the only way to read m1n1's log from Linux. The series kernel has MTD_PHRAM=m.
if ls /lib/modules/"$(uname -r)"/kernel/drivers/mtd/devices/phram.ko* >/dev/null 2>&1; then
    ok "phram.ko installed for $(uname -r): 'modprobe phram' will expose the m1n1 log"
else
    wrn "no phram.ko for $(uname -r): m1n1's log cannot be read from Linux; photograph the panel during boot instead"
fi
mountpoint -q /boot || mount /dev/nvme0n1p4 /boot 2>/dev/null
n=$(ls /boot/m1n1/boot.bin* 2>/dev/null | wc -l); free=$(df -Pm /boot | awk 'NR==2{print $4}')
[ "$n" -le 4 ] && ok "ESP: $n boot.bin* files, $free MB free (a W payload is about 38 MB; the deploy plan wants >= 94 MB free)" || wrn "ESP holds $n boot.bin* files, prune to four (ESP-POLICY.md)"
[ "${free:-0}" -ge 94 ] || wrn "ESP has only ${free:-?} MB free: prune before deploying"
uname -r | grep -q '^7.3.0-g4f630b11270d' && ok "running the series daily kernel $(uname -r)" || wrn "running kernel is $(uname -r), not the series daily 7.3.0-g4f630b11270d"
echo
echo "Not done on purpose: no 'systemctl enable', no /etc/iwd or networkd changes, no removal of $SRC."
echo "Next: delete the staging copy ($SRC) once this prints no FAIL, then deploy W0."
[ "$fail" -eq 0 ] || { echo "RESULT: FAIL (see [FAIL] lines)"; exit 1; }
[ "$warn" -eq 0 ] && echo "RESULT: OK" || echo "RESULT: OK with warnings"
