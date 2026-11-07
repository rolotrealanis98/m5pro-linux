#!/bin/bash
# A/B of native Gallium GL (/opt/mesa-aurora-gl, agx3c + gl-native series)
# against the zink tree (/opt/mesa-aurora) on the J716s GPU kernel. Run as
# root on the GPU payload (aurora DRM driver bound). Nothing is installed or
# changed by this script; the session swap is a separate, manual step (see the
# test plan). Log: /root/gl-native-ab-<time>.log
#   gl-native-ab.sh            # A: native tree; B: zink tree, same steps
#   gl-native-ab.sh native     # only the native tree
set -u
NEW=${NEW:-/opt/mesa-aurora-gl}
OLD=${OLD:-/opt/mesa-aurora}
SMOKE=${SMOKE:-/usr/local/bin/gl-native-smoke}
PROBE=${PROBE:-/usr/local/bin/gl-native-probe}
W=/usr/local/bin/mesa-aurora
LOG=/root/gl-native-ab-$(date +%Y%m%d-%H%M%S).log
exec > >(tee "$LOG") 2>&1
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/0}
mkdir -p "$XDG_RUNTIME_DIR"
unset DISPLAY WAYLAND_DISPLAY
pass=0; fail=0
KMSG=$(dmesg | wc -l)
OUT=$(mktemp)

kmsg_new() {
  local now; now=$(dmesg | wc -l)
  dmesg | sed -n "$((KMSG + 1)),${now}p" |
    grep -iE 'aurora|asahi|agx|gpu|fault|timeout|hang|recover|submit failed|oops|BUG' ||
    echo "(no new GPU kernel lines)"
  KMSG=$now
}

# step NAME TIMEOUT WANT_REGEX REJECT_REGEX cmd...
step() {
  local name=$1 t=$2 want=$3 reject=$4; shift 4
  echo; echo "=== $name"; echo "+ $*"
  timeout --kill-after=5 "$t" "$@" > "$OUT" 2>&1; local rc=$?
  cat "$OUT"; echo "--- rc=$rc"
  local klog; klog=$(kmsg_new); echo "--- kernel log:"; echo "$klog"
  local why=
  [ $rc -ne 0 ] && why="exit $rc"
  grep -q 'submit failed' <<<"$klog" && why="${why:+$why, }kernel refused a submission"
  grep -q 'DRM_IOCTL_ASAHI_SUBMIT .* failed' "$OUT" && why="${why:+$why, }driver saw a refused submission"
  [ -n "$want" ] && ! grep -qE "$want" "$OUT" && why="${why:+$why, }output lacks /$want/"
  [ -n "$reject" ] && grep -qE "$reject" "$OUT" && why="${why:+$why, }output has /$reject/"
  if [ -z "$why" ]; then pass=$((pass + 1)); echo "STEP PASS: $name"
  else fail=$((fail + 1)); echo "STEP FAIL: $name ($why)"; fi
}

python3 - <<'PY'
import ctypes, fcntl, struct
buf = ctypes.create_string_buffer(1024)
with open('/dev/dri/renderD128', 'rb') as fd:
    fcntl.ioctl(fd, 0x40186440, struct.pack('IIQQ', 0, 0, ctypes.addressof(buf), 1024))
f, = struct.unpack_from('<Q', buf.raw, 0)
g, v, r, chip = struct.unpack_from('<4I', buf.raw, 8)
print(f"kernel: G{g}{chr(v)} rev {r} chip {chip:#x} features {f:#x} "
      f"render_resources={'yes' if f >> 17 & 1 else 'NO'} v2={'yes' if f >> 18 & 1 else 'no'} "
      f"compute_resources={'yes' if f >> 28 & 1 else 'no'}")
PY
echo "kernel $(uname -r); native tree $(cat $NEW/MESA_COMMIT 2>/dev/null); zink tree $(cat $OLD/MESA_COMMIT 2>/dev/null)"
[ -d "$NEW/lib" ] || { echo "no $NEW: install the tarball first"; exit 2; }

run() {  # run LABEL PREFIX GLMODE
  local label=$1; export MESA_AURORA_PREFIX=$2 MESA_AURORA_GL=$3
  local apple='Apple M5 Pro' native_only=
  [ "$3" = asahi ] && native_only=zink
  echo; echo "########## $label: MESA_AURORA_PREFIX=$2 MESA_AURORA_GL=$3"
  step "$label 1. eglinfo -B (surfaceless): renderer is $([ "$3" = asahi ] && echo 'the native driver, not zink' || echo zink)" 30 \
    "renderer: .*$apple" "$native_only" $W eglinfo -B -p surfaceless
  # The EGL device platform on renderD128 (eglinfo has no device platform;
  # the smoke test prints GL_RENDERER from it).
  step "$label 2. gl-native-smoke on renderD128 (12 scenes, pixels checked)" 30 \
    "GL_RENDERER: $apple|GL_RENDERER: zink.*$apple" "$native_only" $W "$SMOKE" /dev/dri/renderD128
  step "$label 2b. gl-native-probe (blend/mask alpha, GBM LINEAR buffers, GBM window surface)" 30 \
    "RESULT: PASS" "$native_only" $W "$PROBE" /dev/dri/renderD128
  step "$label 3. egl-offscreen-test (first accelerated GLES frame)" 30 \
    "RESULT: PASS" "$native_only" $W egl-offscreen-test /dev/dri/renderD128
  step "$label 4. gbm-scanout-test on renderD128, LINEAR into simpledrm" 30 \
    "GL_RENDERER: .*$apple" "$native_only" env GBM_TEST_RENDER_NODE=/dev/dri/renderD128 $W gbm-scanout-test
  step "$label 5. gpubench-gl render.light (functional)" 60 \
    "\"renderer\":\"[^\"]*$apple" "$native_only" env GB_WARMUP_MS=20 GB_RUNS=1 GB_RUN_MS=40 GB_TIMED_RUNS=1 \
    $W /opt/gpubench/bin/gpubench-gl --test render.light --depths 1
}

run A-native "$NEW" asahi
[ "${1:-}" = native ] || run B-zink "$OLD" zink
rm -f "$OUT"
echo; echo "=== summary: $pass passed, $fail failed; log $LOG"
