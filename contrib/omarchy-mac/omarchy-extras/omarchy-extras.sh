#!/bin/bash
# Omarchy extras the owner asked for on 2026-11-16 ("install those"): docker + ufw (Omarchy's firewall step), CUPS,
# and the optional packages from omarchy-base that the bring-up skipped. Run as root ON the MacBook:
#   ssh root@MBP 'bash -s' < omarchy-extras.sh
# Then, from the Studio, confirm SSH still works and cancel the firewall dead-man:
#   ssh root@MBP 'systemctl stop m5-ufw-deadman.timer && ufw status verbose'
set -uo pipefail
U=rolo
# Omarchy 4.5 refuses direct pacman upgrades (00-omarchy-update-guard.hook) and points to `omarchy update`, which also runs
# migrations and boot-chain refreshes we keep away from on this machine. Its documented bypass:
export OMARCHY_ALLOW_DIRECT_PACMAN=1
say() { echo "== $*"; }

say "full upgrade first (an earlier 'pacman -Sy' may have refreshed the db; never install on a partial upgrade)"
pacman -Syu --noconfirm || { echo "upgrade failed: stopping"; exit 1; }

say "packages (each checked against the repos; missing ones are listed, not fatal)"
WANT="docker docker-buildx docker-compose ufw ufw-docker libreoffice-fresh moonlight-qt qemu-user-static-binfmt
hyprland-preview-share-picker dotnet-runtime mariadb-libs postgres-libs widevine"
HAVE=; MISSING=
for p in $WANT; do if pacman -Si "$p" >/dev/null 2>&1; then HAVE="$HAVE $p"; else MISSING="$MISSING $p"; fi; done
echo "   installing:$HAVE"; [ -n "$MISSING" ] && echo "   not in the repos for aarch64:$MISSING"
# hyprland-preview-share-picker may pull upstream hyprland, which IgnorePkg refuses (we run hyprland-m5pro): pacman
# stops with an IgnorePkg prompt answered "no" by --noconfirm. Retry without it in that case.
pacman -S --needed --noconfirm $HAVE || pacman -S --needed --noconfirm ${HAVE//hyprland-preview-share-picker/}
# omarchy-hyprland-titlebars is a compiled Hyprland plugin: it must match the running Hyprland build exactly, and ours
# is hyprland-m5pro 0.57.1. Not installed here; check `pacman -Si omarchy-hyprland-titlebars` (depends/version) first.
pacman -Si omarchy-hyprland-titlebars 2>/dev/null | grep -E '^(Version|Depends On)'

say "docker (Omarchy enable-services: docker.socket; user in the docker group, effective at next login)"
systemctl enable --now docker.socket
getent group docker >/dev/null && usermod -aG docker "$U"

say "printing + local discovery (enable-services: cups, avahi-daemon)"
systemctl enable --now cups.service avahi-daemon.service

say "systemd-oomd (needs PSI: next6 and later)"
if [ -e /proc/pressure/memory ]; then systemctl enable --now systemd-oomd.service; else systemctl enable systemd-oomd.service; echo "   enabled; starts on a kernel with PSI"; fi

say "firewall: keep remote access first, then Omarchy's own step"
command -v ufw >/dev/null || { echo "   ufw not installed: skipped"; exit 0; }
# Dead-man: if the new rules cut SSH, ufw turns itself off after 5 minutes.
systemd-run --unit=m5-ufw-deadman --on-active=300 /usr/bin/ufw disable
ufw allow in on tailscale0 comment 'tailscale (ssh from the Studio)'
ufw allow from 10.0.0.0/8 to any port 22 proto tcp comment 'ssh from home LAN'
ufw allow from 192.168.0.0/16 to any port 22 proto tcp comment 'ssh from home LAN'
OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install PATH=/usr/share/omarchy/bin:$PATH \
  bash -c 'source "$OMARCHY_INSTALL/config/firewall.sh"'
ufw --force enable
ufw status verbose | head -30
echo "NOW: from the Studio, ssh in again and run: systemctl stop m5-ufw-deadman.timer"
