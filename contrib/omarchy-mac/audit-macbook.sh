#!/usr/bin/env bash
# audit-macbook.sh - READ-ONLY. Run from the Studio. Lists what on the MacBook differs from a stock Omarchy
# install (paths and package names only, never file contents), then prints what INVENTORY.md does not track.
#
#   MBP_HOST=<address> contrib/omarchy-mac/audit-macbook.sh [--raw] [--strict]
#     MBP_KEY   ssh key (default ~/.ssh/mbp)      MBP_USER  desktop user (default rolo)
#     --raw     also print every finding, not only the untracked ones
#     --strict  exit 1 when anything is untracked
#
# Nothing is written on the MacBook. Output is scrubbed of IPv4/MAC-looking strings before it is shown.
# Known-stock items (Omarchy installer output, machine state) are listed in audit-ignore.txt next to this script.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
INV=$HERE/INVENTORY.md
IGN=$HERE/audit-ignore.txt
RAW=0; STRICT=0
for a in "$@"; do case $a in --raw) RAW=1;; --strict) STRICT=1;; *) echo "unknown option $a" >&2; exit 2;; esac; done
: "${MBP_HOST:?set MBP_HOST to the the MacBook address}"
MBP_KEY=${MBP_KEY:-$HOME/.ssh/mbp}; MBP_USER=${MBP_USER:-rolo}
SSH=(ssh -i "$MBP_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20 "root@$MBP_HOST")
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT

# ---- remote, read-only collection (section markers: "## name") ---------------------------------------------------
"${SSH[@]}" "MBP_USER=$MBP_USER bash -s" >"$OUT" <<'REMOTE'
export LC_ALL=C
H=/home/$MBP_USER
OWNED=$(mktemp); trap 'rm -f "$OWNED"' EXIT
pacman -Qlq 2>/dev/null | sed 's:/$::' | sort -u >"$OWNED"
owner() { pacman -Qqo "$1" 2>/dev/null | head -1; }

echo "## kernel"; uname -r
echo "## foreign-packages"; pacman -Qm
echo "## explicit-packages"; pacman -Qqe
echo "## modified-package-files"
# "warning: pkg: /path (reason)" and "backup file: pkg: /path (reason)"; one line per package+path
pacman -Qkk 2>/dev/null | awk -F': ' '/^(warning|backup file): /{ sub(/^(warning|backup file): /,""); split($0,a,": "); pkg=a[1]; rest=substr($0,length(pkg)+3);
  path=rest; sub(/ \(.*/,"",path); r=rest; sub(/^[^(]*\(/,"",r); sub(/\)$/,"",r); k=pkg"\t"path; why[k]=why[k] (why[k]?",":"") r }
  END{ for(k in why) print k "\t" why[k] }' | sort
echo "## unowned-etc"
# machine state and generated trust stores are excluded here, on the MacBook, so their names (Wi-Fi/VPN profile
# names, host keys) are never even printed
find /etc \( -type f -o -type l \) 2>/dev/null | sort | comm -23 - "$OWNED" | grep -Ev \
  '^/etc/(machine-id|hostname|hosts|localtime|adjtime|resolv\.conf|mtab|\.pwd\.lock|\.updated|shadow-?|passwd-?|group-?|gshadow-?|subuid-?|subgid-?|ssh/ssh_host_|NetworkManager/system-connections/|NetworkManager/NetworkManager\.state|ca-certificates/extracted/|ssl/certs/|pacman\.d/gnupg/|pacman\.d/mirrorlist|ld\.so\.cache|udev/hwdb\.bin|tailscale|wireguard/|openvpn/|ppp/|cups/(printers\.conf|ppd/|subscriptions\.conf|ssl/)|machine-info|os-release|issue|locale\.conf|vconsole\.conf|fstab\.before|group\.bak|passwd\.bak|shadow\.bak|lvm/|iwd/|wpa_supplicant/|bluetooth/|avahi/|docker/key\.json|iproute2/rt_)' | grep -Ev '\.(pacnew|pacsave|pacorig)$' 
echo "## usr-local"
find /usr/local -mindepth 1 \( -type f -o -type l \) -not -path '*/__pycache__/*' 2>/dev/null | sort
echo "## unowned-usr-share-lib-opt"
for d in /opt /usr/share/omarchy-local /usr/lib/firmware/apple /usr/lib/systemd/system /usr/lib/udev/rules.d /usr/lib/modprobe.d /usr/lib/sysctl.d /usr/lib/systemd/system-sleep /usr/lib/systemd/user /usr/share/wireplumber /usr/share/alsa/ucm2 /usr/share/pipewire /usr/lib/security /usr/lib/pam.d /usr/share/polkit-1 /usr/share/libinput; do
  [ -d "$d" ] && find "$d" \( -type f -o -type l \) 2>/dev/null | sort | comm -23 - "$OWNED"
done
echo "## enabled-units-not-in-preset"
PRESET=$(cat /usr/lib/systemd/system-preset/*.preset /etc/systemd/system-preset/*.preset 2>/dev/null | sed -n 's/^enable[[:space:]]\+//p')
systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null | awk '{print $1}' | while read -r u; do
  hit=0; for p in $PRESET; do case $u in $p) hit=1; break;; esac; done
  [ $hit = 0 ] && echo "$u"
done
echo "## user-units-enabled"
sudo -u "$MBP_USER" XDG_RUNTIME_DIR=/run/user/$(id -u "$MBP_USER") systemctl --user list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null | awk '{print $1}'
echo "## dropin-dirs"
find /etc/systemd/system /etc/systemd/user -name '*.conf' 2>/dev/null | sort
echo "## config-dirs"
for d in /etc/modprobe.d /etc/modules-load.d /etc/udev/rules.d /etc/udev/hwdb.d /etc/sysctl.d /etc/tmpfiles.d /etc/pam.d /etc/sudoers.d /etc/polkit-1/rules.d /etc/systemd/network /etc/NetworkManager/conf.d /etc/NetworkManager/dispatcher.d /etc/systemd/journald.conf.d /etc/systemd/logind.conf.d /etc/systemd/sleep.conf.d /etc/systemd/zram-generator.conf.d /etc/libinput /etc/conf.d /etc/mkinitcpio.conf.d /etc/pacman.d/hooks /etc/default; do
  [ -d "$d" ] && find "$d" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | sort | while read -r f; do o=$(owner "$f"); echo "$f	${o:-LOCAL}"; done
done
echo "## home-config"
# files in the user's hypr/omarchy config that differ from the Omarchy defaults (or have no default), no backups
for root in hypr omarchy; do
  find "$H/.config/$root" -type f 2>/dev/null | sort | while read -r f; do
    case $f in *.bak|*.bak.*|*.pre-*|*.before-*|*.orig*|*.sample|*.lock) continue;; esac
    rel=${f#$H/.config/$root/}; st=LOCAL
    for d in /usr/share/omarchy/config/$root /usr/share/omarchy/default/$root /usr/share/omarchy/config/omarchy; do
      if [ -f "$d/$rel" ]; then cmp -s "$d/$rel" "$f" && st=SAME || st=DIFFERS; break; fi
    done
    [ $st != SAME ] && echo "~/.config/$root/$rel	$st"
  done
done
echo "## home-other"
for d in "$H/.config/systemd/user" "$H/.local/bin" "$H/.config/environment.d" "$H/.config/wireplumber" "$H/.config/pipewire" "$H/.config/waybar" "$H/.config/autostart" "$H/.config/uwsm" "$H/.local/share/applications" "$H/.local/share/omarchy"; do
  [ -d "$d" ] && find "$d" -maxdepth 2 \( -type f -o -type l \) -not -name '*.bak' -not -name 'mimeinfo.cache' 2>/dev/null | sort | sed "s:^$H:~:"
done
echo "## firmware-generated"
ls /usr/lib/firmware/apple 2>/dev/null | sed 's:^:/usr/lib/firmware/apple/:'
echo "## end"
REMOTE
rc=$?
[ $rc -eq 0 ] || { echo "ssh/collection failed (rc=$rc)" >&2; exit 3; }
sed -i.bak -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<ip>/g; s/\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b/<mac>/g' "$OUT"; rm -f "$OUT.bak"

# ---- local comparison ------------------------------------------------------------------------------------------
sect() { awk -v s="## $1" '$0==s{f=1;next} /^## /{f=0} f' "$OUT"; }

# tracked patterns: every `...` token in INVENTORY.md that starts with / ~ pkg: unit: ; plus audit-ignore.txt
PATS=()
if [ -f "$INV" ]; then
  while IFS= read -r t; do PATS+=("$t"); done < <(grep -o '`[^`]*`' "$INV" | tr -d '`' | grep -E '^(/|~|pkg:|unit:)' | sort -u)
fi
IGNP=()
if [ -f "$IGN" ]; then
  while IFS= read -r l; do l=${l%%#*}; l=${l%"${l##*[![:space:]]}"}; [ -n "$l" ] && IGNP+=("$l"); done <"$IGN"
fi
is_match() { # key, patterns...
  local k=$1 p; shift
  for p in "$@"; do
    case $p in
      */) [[ $k == "$p"* ]] && return 0 ;;
      *) [[ $k == $p ]] && return 0 ;;
    esac
  done
  return 1
}
tracked() { is_match "$1" "${PATS[@]}"; }
ignored() { is_match "$1" "${IGNP[@]}"; }

UNT=(); TOTAL=0
note() { # category key detail
  TOTAL=$((TOTAL+1))
  [ $RAW = 1 ] && printf '  %-14s %s %s\n' "$1" "$2" "${3:-}"
  if ignored "$2"; then return; fi
  if tracked "$2"; then return; fi
  UNT+=("$1|$2|${3:-}")
}
[ $RAW = 1 ] && echo "== findings (every difference from stock)"
echo "MacBook kernel: $(sect kernel)"
while IFS= read -r l; do [ -n "$l" ] && note "foreign-pkg" "pkg:${l%% *}" "${l#* }"; done < <(sect foreign-packages)
while IFS=$'\t' read -r pkg path why; do [ -n "$path" ] && note "modified-file" "$path" "($pkg: $why)"; done < <(sect modified-package-files)
while IFS= read -r l; do [ -n "$l" ] && note "unowned-etc" "$l"; done < <(sect unowned-etc)
while IFS= read -r l; do [ -n "$l" ] && note "usr-local" "$l"; done < <(sect usr-local)
while IFS= read -r l; do [ -n "$l" ] && note "unowned-system" "$l"; done < <(sect unowned-usr-share-lib-opt)
while IFS= read -r l; do [ -n "$l" ] && note "enabled-unit" "unit:$l"; done < <(sect enabled-units-not-in-preset)
while IFS= read -r l; do [ -n "$l" ] && note "user-unit" "unit:$l"; done < <(sect user-units-enabled)
while IFS= read -r l; do [ -n "$l" ] && note "dropin" "$l"; done < <(sect dropin-dirs)
while IFS=$'\t' read -r f o; do [ "$o" = LOCAL ] && note "local-config" "$f"; done < <(sect config-dirs)
while IFS=$'\t' read -r f st; do [ -n "$f" ] && note "home-config" "$f" "($st)"; done < <(sect home-config)
while IFS= read -r l; do [ -n "$l" ] && note "home-other" "$l"; done < <(sect home-other)

# PRIVATE per-machine firmware: reported, never to be copied
echo; echo "== per-machine firmware (PRIVATE: generated on the MacBook, never committed)"
sect firmware-generated | grep -Ei 'cal|msrk|tpmtfw|panel|aop-als' | sed 's/^/  /' || true

echo; echo "== untracked (not in $(basename "$INV") and not in $(basename "$IGN")): ${#UNT[@]} of $TOTAL findings"
if [ ${#UNT[@]} -gt 0 ]; then
  printf '%s\n' "${UNT[@]}" | sort | awk -F'|' '{printf "  %-14s %s %s\n",$1,$2,$3}'
fi

# reverse check: paths INVENTORY.md lists as installed that are not on the MacBook (stale rows, or a script that never landed)
echo; echo "== listed in $(basename "$INV") but not on the MacBook"
MISS=$(printf '%s\n' "${PATS[@]}" | grep -E '^(/|~/)' | grep -vE '^/Volumes/|[*]|[.][.][.]' | sed "s:^~:/home/$MBP_USER:" \
  | "${SSH[@]}" 'while IFS= read -r p; do [ -e "$p" ] || [ -L "$p" ] || echo "$p"; done' | sed "s:^/home/$MBP_USER:~:")
if [ -n "$MISS" ]; then echo "$MISS" | sed 's/^/  /'; else echo "  none"; fi
[ $STRICT = 1 ] && [ ${#UNT[@]} -gt 0 ] && exit 1
exit 0
