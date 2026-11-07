#!/usr/bin/env bash
# build-audio-pkgs.sh - build the Asahi audio userspace packages for aarch64 Arch Linux ARM in an
# ALARM container on the Studio (the ALARM repos do not ship them). Run it yourself:
#   bash ~/Work/agents/audio-aurora/build-audio-pkgs.sh
# Output: ~/Work/agents/audio-aurora/pkgs/*.pkg.tar.*  -> then on the MacBook root:
#   scp -i ~/.ssh/mbp ~/Work/agents/audio-aurora/pkgs/*.pkg.tar.* root@<macbook>:/root/j716-audio/pkgs/
#   ssh ... 'pacman -U --noconfirm /root/j716-audio/pkgs/*.pkg.tar.* && bash /root/j716-audio/audio-root-setup.sh'
# Packages: speakersafetyd (REQUIRED before any speaker boot), bankstown-lv2, triforce-lv2, asahi-audio,
# alsa-ucm-conf-asahi. Sources: github.com/AsahiLinux/PKGBUILDs (upstream PKGBUILDs; our J716 profile and
# graphs are separate files already installed on the root).
set -euo pipefail
OUT=$HOME/Work/agents/audio-aurora/pkgs; mkdir -p "$OUT"
container rm -f alarmpkg >/dev/null 2>&1 || true
container run -d --name alarmpkg -m 12g -c 8 -v "$OUT:/out" --arch arm64 docker.io/menci/archlinuxarm:base-devel sleep infinity >/dev/null
trap 'container rm -f alarmpkg >/dev/null 2>&1 || true' EXIT
container exec alarmpkg bash -c '
set -uo pipefail
echo "== keyring =="; pacman-key --init 2>&1 | tail -2; pacman-key --populate archlinuxarm 2>&1 | tail -2
# pacman 7 sandboxes downloads with Landlock + the alpm user; neither works inside this container runtime.
grep -q "^DisableSandbox" /etc/pacman.conf || sed -i "s/^\[options\]/[options]\nDisableSandbox/" /etc/pacman.conf
grep -n "DisableSandbox" /etc/pacman.conf | head -1
echo "== packages =="; pacman -Syu --noconfirm --needed base-devel git rust cargo cmake meson ninja lv2 pkgconf alsa-lib pipewire wireplumber python 2>&1 | tail -5 || { echo "PACMAN FAILED"; exit 1; }
useradd -m build 2>/dev/null || true; echo "build ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/build
su - build -c "
set -e
git clone -q --depth 1 https://github.com/AsahiLinux/PKGBUILDs.git
for p in speakersafetyd bankstown triforce-lv2 alsa-ucm-conf-asahi asahi-audio; do
  if [ -d PKGBUILDs/\$p ]; then (cd PKGBUILDs/\$p && echo \"== \$p ==\" && makepkg -s --noconfirm --nocheck 2>&1 | tail -3 && cp -v *.pkg.tar.* /out/ && sudo pacman -U --noconfirm *.pkg.tar.* >/dev/null ) || echo \"FAILED \$p\"; else echo \"no PKGBUILD for \$p\"; fi
done
"
ls -la /out
'
echo "pkg build finished: $OUT"
