#!/bin/bash
# SPDX-License-Identifier: MIT
# iPhone <-> Mac file sharing that works today, while AirDrop over the N1 is being built (airdrop-1/2).
#
# Omarchy already ships both halves; on this Mac Tailscale was installed by hand during bring-up,
# so Omarchy's own "install service tailscale" step never ran its last two lines. This does just those:
#   1. tailscale set --operator=USER   (lets the desktop user run `tailscale file get`)
#   2. enable the stock user unit omarchy-tailscale-receive.service (saves Taildrop files to ~/Downloads
#      and posts a notification with a preview)
# It changes no network settings: no `tailscale up`, no routes, no Wi-Fi.
#
# Usage (root):  taildrop-receive.sh --user NAME [--dry-run]   |   taildrop-receive.sh --user NAME --remove
set -euo pipefail

user="" dry=false remove=false
while (($#)); do
  case "$1" in
  --user) user="$2"; shift 2 ;;
  --dry-run) dry=true; shift ;;
  --remove) remove=true; shift ;;
  *) echo "usage: $0 --user NAME [--dry-run|--remove]" >&2; exit 2 ;;
  esac
done
[[ -n $user ]] || { echo "--user NAME is required" >&2; exit 2; }
[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 1; }
id "$user" >/dev/null
command -v tailscale >/dev/null || { echo "tailscale is not installed" >&2; exit 1; }
[[ -f /usr/lib/systemd/user/omarchy-tailscale-receive.service ]] || { echo "Omarchy's receive unit is missing" >&2; exit 1; }

run() { echo "+ $*"; $dry || "$@"; }
as_user() { run systemctl --user -M "$user@" "$@"; }

if $remove; then
  as_user disable --now omarchy-tailscale-receive.service
  run tailscale set --operator=
  exit 0
fi

run tailscale set --operator="$user"
as_user enable --now omarchy-tailscale-receive.service
$dry || as_user is-active omarchy-tailscale-receive.service

cat <<EOF

Done. How to use it:
  iPhone/iPad -> Mac: Share sheet > Tailscale > this Mac. The file lands in ~$user/Downloads with a notification.
                      Works on any network (hotel Wi-Fi with client isolation included), both devices on the tailnet.
  Mac -> iPhone:      omarchy tailscale send <device> FILE...   (tailscale file cp --targets lists the devices)
  Same Wi-Fi, no Tailscale: Omarchy menu > Trigger > Share (LocalSend; the LocalSend app on the iPhone).
                      On networks that isolate clients, use LocalSend's "send to address" with the Mac's Tailscale IP.
EOF
