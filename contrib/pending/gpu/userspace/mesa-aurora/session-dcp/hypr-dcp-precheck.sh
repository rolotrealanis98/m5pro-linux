#!/bin/bash
# Which card is which on this boot, by driver (card numbers change per boot).
# Read-only; run as root on the MacBook, or over ssh from the Studio:
#   ssh -i ~/.ssh/mbp -o BatchMode=yes root@<macbook> 'bash -s' < hypr-dcp-precheck.sh
# Prints one line per DRM node with the bound driver, the DRM driver name
# (DRM_IOCTL_VERSION), connectors and the role, then what hypr-gpu-session
# would export. Exit 0 = DCP session possible (apple card with a connected
# eDP + one aurora/asahi render node), 1 = not.
# shellcheck disable=SC2015
SYS=${HYPR_SYS:-/sys}   # test hook: a fake sysfs root
APPLE='apple-drm|apple|appledrm' GPU='aurora|asahi' SIMPLE='simple-framebuffer|simpledrm'
drmname() {  # DRM_IOCTL_VERSION name of a node (works on card and renderD nodes)
  python3 -I - "$1" 2>/dev/null <<'PY'
import ctypes, fcntl, struct, sys
n = ctypes.create_string_buffer(64)
req = struct.pack('iiiQQQQQQ', 0, 0, 0, 64, ctypes.addressof(n), 0, 0, 0, 0)
try:
    with open(sys.argv[1], 'rb') as fd:
        fcntl.ioctl(fd, 0xC0406400, req)
    print(n.value.decode())
except OSError as e:
    print(f"? ({e.strerror})")
PY
}
echo "kernel $(uname -r)  booted $(uptime -s 2>/dev/null)"
apple='' apple_conn='' gpu='' render='' simple='' nrender=0
for c in "$SYS"/class/drm/card* "$SYS"/class/drm/renderD*; do
  n=${c##*/}; [[ $n =~ ^(card|renderD)[0-9]+$ ]] || continue
  drv=$(readlink -f "$c/device/driver" 2>/dev/null); drv=${drv##*/}
  dev=$(readlink -f "$c/device"); conns=''
  for s in "$SYS"/class/drm/"$n"-*/status; do
    [ -r "$s" ] || continue
    k=${s%/status}; k=${k##*/}; conns="$conns ${k#"$n"-}=$(cat "$s")"
  done
  role=other
  if [[ $n == renderD* ]]; then
    nrender=$((nrender + 1)); role="render node"
    if [[ $drv =~ ^($GPU)$ ]]; then role="GPU render node (Hyprland renders here)"; render=/dev/dri/$n; fi
  elif [[ $drv =~ ^($APPLE)$ ]]; then
    role="DCP display (scanout, KMS)"
    if [[ $conns == *eDP-*=connected* ]]; then
      apple=/dev/dri/$n; apple_conn=$(grep -o 'eDP-[0-9]*=connected' <<<"$conns" | head -1); apple_conn=${apple_conn%=*}
    fi
  elif [[ $drv =~ ^($GPU)$ ]]; then role="GPU (render only, no KMS)"; gpu=/dev/dri/$n
  elif [[ $drv =~ ^($SIMPLE)$ ]]; then role="simpledrm (iBoot framebuffer, CPU copy)"; simple=/dev/dri/$n
  fi
  printf '%-11s driver=%-19s drm=%-10s dev=%s\n            role: %s%s\n' "/dev/dri/$n" "${drv:-none}" "$(drmname /dev/dri/"$n")" "${dev##*/}" "$role" "${conns:+  connectors:$conns}"
done
echo
p=/sys/module/appledrm/parameters/fw27_panel_vrr
echo "panel VRR opt-in: $( [ -r $p ] && cat $p || echo 'no fw27_panel_vrr parameter') ; cmdline: $(grep -o 'appledrm\.[a-z0-9_]*=[^ ]*' /proc/cmdline | tr '\n' ' ')"
echo "tracefs: $( [ -d /sys/kernel/tracing/events ] && echo mounted || { grep -q tracefs /proc/filesystems && echo 'available (not mounted)' || echo 'not in kernel'; })  dcp:iomfb_swap_complete: $( [ -d /sys/kernel/tracing/events/dcp/iomfb_swap_complete ] && echo yes || echo 'not visible')"
env=/etc/mesa-aurora/session.env
echo "Mesa session.env: $(sed -n 's|^LIBGL_DRIVERS_PATH=\(.*\)/lib/dri$|\1|p' $env 2>/dev/null) ($(grep -q '^MESA_LOADER_DRIVER_OVERRIDE=zink' $env 2>/dev/null && echo zink || echo native GL))"
for f in /usr/local/lib/hypr-cards.sh /usr/local/bin/hypr-gpu-session /usr/local/bin/hypr-dcp-verify ~rolo/.local/bin/hypr-session ~rolo/.config/hypr/m5pro-dcp.lua; do
  printf 'installed: %-40s %s\n' "$f" "$( [ -e "$f" ] && echo yes || echo no)"
done
grep -q 'M5PRO_HYPR_PROFILE' ~rolo/.config/hypr/hyprland.lua 2>/dev/null && echo "hyprland.lua: profile switch present" || echo "hyprland.lua: profile switch MISSING (loads m5pro.lua only)"
echo
if [ -n "$apple" ] && [ -n "$render" ] && [ "$nrender" = 1 ]; then
  echo "DCP session: yes  AQ_DRM_DEVICES=$apple (panel $apple_conn)  render node $render (GPU card ${gpu:-?})"
  exit 0
fi
echo "DCP session: no   apple+connected eDP=${apple:-none} GPU render=${render:-none} renderD count=$nrender simpledrm=${simple:-none}"
[ "$nrender" -gt 1 ] && echo "  more than one renderD: aquamarine will not pair the apple card with the GPU (software rendering)"
exit 1
