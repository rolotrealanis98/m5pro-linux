#!/bin/bash
# First accelerated frame on the J716s: run as root on the GPU kernel (aurora
# driver loaded). Each step is independent and time-limited; the log is in
# /root/gpu-first-frame-<time>.log. Steps 1-7 draw nothing on screen.
#   gpu-first-frame.sh            # steps 0-7
#   gpu-first-frame.sh --screen   # also step 8: GPU frame on the panel for 10 s
#                                 # (switches to tty1 so Hyprland on tty2 gives up the card, then back)
LOG=/root/gpu-first-frame-$(date +%Y%m%d-%H%M%S).log
exec > >(tee "$LOG") 2>&1
W=/usr/local/bin/mesa-aurora
B=/opt/gpubench/bin
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/0}
mkdir -p "$XDG_RUNTIME_DIR"
unset DISPLAY WAYLAND_DISPLAY

KMSG_START=$(dmesg | wc -l)
pass=0; fail=0
kmsg_new() {  # GPU-related kernel lines since the last call
  local now; now=$(dmesg | wc -l)
  dmesg | sed -n "$((KMSG_START + 1)),${now}p" |
    grep -iE 'asahi|aurora|agx|gpu|drm|dcp|fault|timeout|hang|recover|oops|BUG' || echo "(no new GPU kernel lines)"
  KMSG_START=$now
}
OUT=$(mktemp)
step() {  # step "name" timeout 'regex the output must contain, or ""' cmd...
  local name=$1 t=$2 want=$3; shift 3
  echo; echo "=== $name"; echo "+ $*"
  timeout --kill-after=10 "$t" "$@" > "$OUT" 2>&1; local rc=$?
  cat "$OUT"
  echo "--- rc=$rc"; echo "--- kernel log:"; kmsg_new
  local why=
  [ $rc -ne 0 ] && why="exit $rc"
  if [ -n "$want" ] && ! grep -qE "$want" "$OUT"; then why="${why:+$why, }output lacks /$want/ (software fallback?)"; fi
  if [ -z "$why" ]; then pass=$((pass + 1)); echo "STEP PASS: $name"
  else fail=$((fail + 1)); echo "STEP FAIL: $name ($why)"; fi
}
APPLE='Apple M5'
FAST='GB_WARMUP_MS=20 GB_RUNS=1 GB_RUN_MS=40 GB_TIMED_RUNS=1'

echo "=== 0. identity ($(uname -r), $(date -u))"
echo "mesa: $(cat /opt/mesa-aurora/MESA_COMMIT 2>/dev/null)  gpubench: $(cat /opt/gpubench/COMMIT 2>/dev/null)"
ls -l /dev/dri /dev/dri/by-path 2>/dev/null
for c in /sys/class/drm/card[0-9] /sys/class/drm/renderD*; do
  [ -e "$c" ] && echo "${c##*/}: driver=$(basename "$(readlink -f "$c/device/driver")") dev=$(basename "$(readlink -f "$c/device")")"
done
python3 - <<'PY'
import ctypes, fcntl, glob, struct
# DRM_IOCTL_VERSION: the kernel driver's name, version and description per node.
for node in sorted(glob.glob('/dev/dri/card*') + glob.glob('/dev/dri/renderD*')):
    try:
        with open(node, 'rb') as fd:
            n, d, s = (ctypes.create_string_buffer(k) for k in (64, 64, 128))
            req = struct.pack('iiiQQQQQQ', 0, 0, 0, 64, ctypes.addressof(n),
                              64, ctypes.addressof(d), 128, ctypes.addressof(s))
            maj, mn, pl = struct.unpack('iii', fcntl.ioctl(fd, 0xC0406400, req)[:12])
            print(f"{node}: {n.value.decode()} {maj}.{mn}.{pl} ({s.value.decode()})")
    except OSError as e:
        print(f"{node}: {e}")
PY
grep -iE 'gpu|gfx|afr|agx' /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | head -20 || echo "(no pm_genpd summary)"
echo "--- kernel log so far (GPU lines):"; dmesg | grep -iE 'asahi|aurora|agx|\bgpu\b' | tail -30
KMSG_START=$(dmesg | wc -l)

step "1. Vulkan: ICD finds the aurora device" 60 "deviceName += $APPLE" $W vulkaninfo --summary
step "2. GLES: headless render on renderD128 (EGL device platform)" 60 "GL_RENDERER: +$APPLE" $W egl-offscreen-test /dev/dri/renderD128
step "3. EGL: eglinfo -B" 60 "renderer: $APPLE" $W eglinfo -B
step "4a. GBM on simpledrm -> kmsro -> GPU, PRIME into simpledrm (explicit LINEAR)" 60 "GL_RENDERER: $APPLE" $W gbm-scanout-test
step "4b. same, implicit modifier (what Hyprland does with AQ_NO_MODIFIERS=1)" 60 "GL_RENDERER: $APPLE" env GBM_TEST_NO_MODIFIERS=1 $W gbm-scanout-test
step "5a. Vulkan compute (gpubench compute.light, functional run)" 120 '"status":"ok"' env $FAST $W $B/gpubench-vk --test compute.light --depths 1
step "5b. Vulkan render (gpubench render.light, functional run)" 120 '"status":"ok"' env $FAST $W $B/gpubench-vk --test render.light --depths 1
step "5c. Vulkan stress: first render + render/compute chain, checked against CPU" 240 "" $W $B/gpubench-stress-vk --test render.first,xq.chain --duration 60 --kernel-log
step "6. vkmark headless cube, 5 s" 90 "$APPLE" $W vkmark --winsys headless -b cube:duration=5
step "7a. GL render (gpubench-gl render.light, functional run)" 120 "\"renderer\":\"$APPLE" env $FAST $W $B/gpubench-gl --test render.light --depths 1
step "7b. aurora-diag gpu (kernel driver attributes, Vulkan, GL)" 120 "$APPLE" $W aurora-diag gpu

if [ "$1" = --screen ]; then
  echo; echo "=== 8. GPU frame on the panel (left green, right orange, 10 s)"
  vt=$(fgconsole 2>/dev/null || echo 2)
  chvt 1; sleep 2   # the compositor on tty2 drops DRM master on the switch
  step "8. on-screen modeset of a GPU-rendered frame" 60 "frame on screen" $W gbm-scanout-test --show 10
  chvt "$vt"
fi

rm -f "$OUT"
echo; echo "=== summary: $pass passed, $fail failed; log $LOG"
