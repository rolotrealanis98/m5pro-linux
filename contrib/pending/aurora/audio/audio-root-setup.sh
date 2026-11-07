#!/usr/bin/env bash
# J716 audio USERSPACE prep for the Arch Linux ARM root on the M5 Pro (run as root on the MacBook).
# Prereq (Studio): scp -r ~/Work/agents/audio-aurora/userspace root@<tailscale-ip>:/root/j716-audio
# Scope: Arch Linux ARM repos only (pacman -S --needed, never -Sy/-Syu); our files from /root/j716-audio.
# Does NOT add [asahi-alarm], clone or build anything, touch amps, reboot, or touch /boot, network, sshd, tailscale, Hyprland.
set -euo pipefail
SRC=${SRC:-/root/j716-audio}
UCM=/usr/share/alsa/ucm2
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -d "$SRC" ] || { echo "missing $SRC"; exit 1; }

echo "== 1. packages (ALARM [extra] only; no sync, no upgrade)"
[ "$(pacman -Qu 2>/dev/null | wc -l)" = 0 ] || echo "WARN: local DB shows upgradable packages; still NOT running -Syu"
pacman -S --needed --noconfirm pipewire wireplumber pipewire-alsa pipewire-pulse rtkit alsa-utils alsa-ucm-conf lsp-plugins-lv2 sox
for p in speakersafetyd asahi-audio alsa-ucm-conf-asahi bankstown-lv2 triforce-lv2; do
  if pacman -Si "$p" >/dev/null 2>&1; then pacman -S --needed --noconfirm "$p"
  else echo "MISSING (not in ALARM repos, must be built on the Studio and shipped as a package): $p"; fi
done

echo "== 2. J716 files"
install -Dm0644 "$SRC/speakersafetyd/apple/j716.conf"     /usr/share/speakersafetyd/apple/j716.conf
install -Dm0644 "$SRC/udev/96-speakersafetyd-j716.rules"  /usr/lib/udev/rules.d/96-speakersafetyd-j716.rules
install -Dm0644 "$SRC/asahi-audio/j716/graph.json"        /usr/share/asahi-audio/j716/graph.json
install -Dm0644 "$SRC/asahi-audio/j716/mic.json"          /usr/share/asahi-audio/j716/mic.json
install -Dm0644 "$SRC/asahi-audio/99-asahi-j716.conf"     /usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716.conf
install -Dm0644 "$SRC/asahi-audio/99-asahi-j716-mic.conf" /usr/share/wireplumber/wireplumber.conf.d/99-asahi-j716-mic.conf
install -Dm0644 "$SRC/alsa-ucm/ucm2/conf.d/macaudio/MacBook Pro J716.conf" "$UCM/conf.d/macaudio/MacBook Pro J716.conf"
[ -f "$UCM/conf.d/macaudio/laptops/HiFi.conf" ] || echo "NOTE: $UCM/conf.d/macaudio/laptops/HiFi.conf missing (alsa-ucm-conf-asahi); J716 macaudio UCM will fail to open -> PipeWire ACP falls back to plain ALSA"
# ROOT-SETUP.md section 3: AOP UCM only when the aop_audio tree exists.
if [ -f "$UCM/conf.d/aop_audio/3chan/HiFi.conf" ]; then
  install -Dm0644 "$SRC/alsa-ucm/ucm2/conf.d/t8140-aop-audio/MacBook Pro J716 AOP Audio.conf" \
                  "$UCM/conf.d/t8140-aop-audio/MacBook Pro J716 AOP Audio.conf"
else
  echo "SKIP AOP UCM: $UCM/conf.d/aop_audio/3chan/HiFi.conf missing (alsa-ucm-conf-asahi); mic opens as plain ALSA device"
fi
udevadm verify /usr/lib/udev/rules.d/96-speakersafetyd-j716.rules
udevadm control --reload

echo "== 3. user audio services (already Arch defaults; idempotent)"
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service

echo "== 4. checks"
pacman -Q pipewire wireplumber pipewire-pulse rtkit alsa-utils alsa-ucm-conf lsp-plugins-lv2 sox
if pacman -Q speakersafetyd >/dev/null 2>&1; then systemctl is-enabled speakersafetyd || true
else echo "speakersafetyd: NOT INSTALLED (speaker volume stays kernel-locked until it runs)"; fi
grep -c AppleJ716 /usr/lib/udev/rules.d/96-speakersafetyd-j716.rules
ls -la /usr/share/speakersafetyd/apple/ /usr/share/asahi-audio/j716/ /usr/share/wireplumber/wireplumber.conf.d/
find "$UCM/conf.d/macaudio" "$UCM/conf.d/t8140-aop-audio" -type f 2>/dev/null || true
wireplumber --version
