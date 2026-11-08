# shellcheck shell=bash disable=SC2034
# Display/GPU card discovery for the M5 Pro (J716s) desktop session. Sourced by
# /usr/local/bin/hypr-gpu-session, ~/.local/bin/hypr-session and
# hypr-dcp-verify. Install as /usr/local/lib/hypr-cards.sh.
#
# Cards are found by the kernel driver bound to their device, never by number
# (the apple, aurora and simpledrm cards are numbered in probe order):
#   apple card   display subsystem bound to apple-drm (DRM driver name "apple"):
#                KMS only, the DCP scans out; no render node
#   aurora card  the GPU (DRM driver "aurora", legacy "asahi"): render only, no
#                KMS; its render node is the renderD* on the same device
#   simpledrm    the iBoot framebuffer (simple-framebuffer), CPU copy scanout
#
# hypr_cards_scan sets:
#   APPLE_CARD APPLE_CONNECTOR  e.g. /dev/dri/card1 eDP-1 (a connected eDP only)
#   AURORA_CARD AURORA_RENDER   e.g. /dev/dri/card0 /dev/dri/renderD128
#   SIMPLE_CARD                 e.g. /dev/dri/card2
#   RENDER_COUNT                number of renderD* nodes on the system
HYPR_SYS=${HYPR_SYS:-/sys}   # test hook: a fake sysfs root
HYPR_APPLE_DRIVERS='apple-drm|apple|appledrm'
HYPR_AURORA_DRIVERS='aurora|asahi'
HYPR_SIMPLE_DRIVERS='simple-framebuffer|simpledrm'

hypr_card_driver() {  # $HYPR_SYS/class/drm/cardN -> bound driver name
  local d
  d=$(readlink -f "$1/device/driver" 2>/dev/null) || return 1
  [ -n "$d" ] && echo "${d##*/}"
}

hypr_cards_scan() {
  local c n drv dev r s
  APPLE_CARD='' APPLE_CONNECTOR='' AURORA_CARD='' AURORA_RENDER='' SIMPLE_CARD='' RENDER_COUNT=0
  for c in "$HYPR_SYS"/class/drm/card*; do
    n=${c##*/}
    [[ $n =~ ^card[0-9]+$ ]] || continue          # skip connectors (cardN-eDP-1)
    drv=$(hypr_card_driver "$c") || continue
    if [[ $drv =~ ^($HYPR_APPLE_DRIVERS)$ ]]; then
      for s in "$HYPR_SYS"/class/drm/"$n"-eDP-*/status; do
        [ -r "$s" ] && [ "$(cat "$s" 2>/dev/null)" = connected ] || continue
        APPLE_CARD=/dev/dri/$n
        s=${s%/status}; s=${s##*/}; APPLE_CONNECTOR=${s#"$n"-}
        break
      done
    elif [[ $drv =~ ^($HYPR_AURORA_DRIVERS)$ ]]; then
      AURORA_CARD=/dev/dri/$n
      dev=$(readlink -f "$c/device")
      for r in "$HYPR_SYS"/class/drm/renderD*; do
        [ -e "$r" ] || continue
        [ "$(readlink -f "$r/device")" = "$dev" ] && AURORA_RENDER=/dev/dri/${r##*/}
      done
    elif [[ $drv =~ ^($HYPR_SIMPLE_DRIVERS)$ ]]; then
      SIMPLE_CARD=/dev/dri/$n
    fi
  done
  for r in "$HYPR_SYS"/class/drm/renderD*; do [ -e "$r" ] && RENDER_COUNT=$((RENDER_COUNT + 1)); done
  return 0
}

# True when this kernel carries the DCP display driver at all (built in or
# loaded), whether or not it has bound yet.
hypr_dcp_expected() {
  [ -d "$HYPR_SYS"/bus/platform/drivers/apple-drm ] || [ -d "$HYPR_SYS"/module/appledrm ]
}

# Wait up to $1 seconds (default 20) for a connected eDP on the apple card.
# apple-drm binds after the DCP firmware handshake, which can finish after the
# tty2 autologin; starting on simpledrm and losing it to apple-drm mid-session
# would kill Hyprland. Returns 0 when the apple card is ready.
hypr_wait_for_dcp() {
  local limit=${1:-20} t=0
  hypr_cards_scan
  [ -n "$APPLE_CARD" ] && return 0
  hypr_dcp_expected || return 1
  command -v udevadm >/dev/null && timeout 10 udevadm settle -t 8 2>/dev/null
  while [ $t -lt "$limit" ]; do
    hypr_cards_scan
    [ -n "$APPLE_CARD" ] && return 0
    sleep 1; t=$((t + 1))
  done
  return 1
}

# 1 when the panel offers VRR: the connector's vrr_capable property, read with
# modetest (no DRM master needed), else the opt-in module parameter
# appledrm.fw27_panel_vrr=1 (the only way the firmware-27 panel offers VRR).
hypr_panel_vrr() {
  local v p=$HYPR_SYS/module/appledrm/parameters/fw27_panel_vrr
  if command -v modetest >/dev/null; then
    v=$(timeout 5 modetest -M apple -c 2>/dev/null |
        awk '/[0-9]+ vrr_capable:/{f=1; next} f && /value:/{print $2; exit}')
    case $v in 1) echo 1; return;; 0) echo 0; return;; esac
  fi
  if [ -r "$p" ] && [[ $(cat "$p") == [Yy1]* ]]; then echo 1; return; fi
  grep -qw 'appledrm.fw27_panel_vrr=1' /proc/cmdline 2>/dev/null && { echo 1; return; }
  echo 0
}
