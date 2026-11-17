#!/bin/bash
# Chrome video decode A/B (as the desktop user): which libva driver and which Chrome GPU flags give hardware decode.
#   video-ab.sh OUTDIR "VARIANT..." "CLIP..."
# VARIANT: sw | gl | gl-av1fix | vk | vk-av1fix | vk-forced | vk-forced-av1fix | angle-vk | angle-vk-forced (flags() below)
# The page also logs the mean RGB of a 4x4 grid of the frame at t=2.0 s ("picture"); compare against sw.
# CLIP: file names in /home/rolo/gpu-ab/avd/clips (silent clips; the page is muted too).
# One Chrome window per run on Hyprland workspace 5, silently (owner rule), ~22 s; started by Hyprland so it gets the
# session env. Per run: WebCodecs prefer-hardware support per codec, frames/dropped from the page, whether the GPU
# process holds the AVD nodes (/dev/media*, /dev/video*) while playing, and CPU of the whole test Chrome over 10 s.
set -u
OUT=$1; VARIANTS=$2; CLIPS=$3
PAGE=/home/rolo/gpu-ab/avd/play.html
PROFILE=/home/rolo/gpu-ab/chrome-test-video
AV1DRV=/opt/libva-avd-av1/dri
LOCK=/home/rolo/gpu-ab/.gpu-window.lock
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=${HYPRLAND_INSTANCE_SIGNATURE:-$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)}
HZ=$(getconf CLK_TCK)
mkdir -p "$OUT" "$PROFILE"
VK="--use-angle=vulkan --enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar,Vulkan,DefaultANGLEVulkan,VulkanFromANGLE"
FORCE="VaapiIgnoreDriverChecks,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL"
flags() {
  case $1 in
    sw)             echo "--disable-accelerated-video-decode --enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar" ;;
    vk-forced-av1fix) echo "$VK,$FORCE" ;;
    gl|gl-av1fix)   echo "--enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar" ;;
    vk|vk-av1fix)   echo "$VK" ;;
    vk-forced)      echo "$VK,$FORCE" ;;
    angle-vk)       echo "--use-angle=vulkan --enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar" ;;
    angle-vk-forced) echo "--use-angle=vulkan --enable-features=TouchpadOverscrollHistoryNavigation,OverlayScrollbar,$FORCE" ;;
    *) echo "unknown variant $1" >&2; exit 2 ;;
  esac
}
envs() { case $1 in *av1fix) echo "LIBVA_DRIVERS_PATH=$AV1DRV LIBVA_DRIVER_NAME=v4l2_request" ;; esac; }
descendants() { local p=$1; echo $p; for c in $(ps -o pid= --ppid "$p"); do descendants "$c"; done; }
cpu_ticks() { local t=0 p; for p in "$@"; do t=$((t + $(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null || echo 0))); done; echo $t; }
for v in $VARIANTS; do
  for c in $CLIPS; do
    tag=$v-$c; L=$OUT/$tag.log; W=$OUT/$tag.launch.sh
    printf '#!/bin/sh\nexec env %s /opt/google/chrome/chrome --user-data-dir=%s --no-first-run --no-default-browser-check --ozone-platform=wayland --ozone-platform-hint=wayland --render-node-override=/dev/dri/renderD128 --password-store=basic --mute-audio --autoplay-policy=no-user-gesture-required --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --allow-file-access-from-files --enable-logging=stderr --v=0 %s "file://%s#%s" > "%s" 2>&1\n' \
      "$(envs $v)" "$PROFILE" "$(flags $v)" "$PAGE" "$c" "$L" > "$W"; chmod +x "$W"
    before=$(dmesg | wc -l)
    exec 9>"$LOCK"; flock 9
    hyprctl dispatch "hl.dsp.exec_cmd(\"$W\", {workspace = \"5 silent\"})" >/dev/null
    sleep 7
    B=$(pgrep -u "$(id -u)" -o -f "^/opt/google/chrome/chrome .*--user-data-dir=$PROFILE( |\$)")
    G=$(pgrep -u "$(id -u)" -n -f -- '--type=gpu-process')
    nodes=$(ls -l /proc/$G/fd 2>/dev/null | grep -oE '/dev/(media|video)[0-9]+' | sort -u | tr '\n' ' ')
    P=$(descendants "${B:-1}" | tr '\n' ' '); t1=$(cpu_ticks $P); sleep 10; t2=$(cpu_ticks $P)
    pkill -f -- "^/opt/google/chrome/chrome .*--user-data-dir=$PROFILE( |\$)"; sleep 3
    flock -u 9
    wc=$(grep -oE 'webcodecs [^"]*' "$L" | sed -E 's/webcodecs (.*) prefer-hardware supported=(true|false)/\1=\2/' | tr '\n' ' ')
    last=$(grep -oE "$c t=[^\"]*" "$L" | tail -1)
    err=$(grep -oE 'vaEndPicture failed|vaInitialize failed[^"]*|GPU process exited[^"]*' "$L" | sort | uniq -c | tr '\n' ' ')
    k=$(dmesg | tail -n +$((before + 1)) | grep -ciE 'avd.*(recover|timeout|error)|aurora.*fault|in-fence')
    pic=$(grep -oE 'picture t=[^"]*' "$L" | head -1)
    echo "$tag | $pic" >> "$OUT/pictures.txt"
    echo "$tag | avd nodes: ${nodes:-none} | chrome CPU $(( (t2 - t1) * 100 / (10 * HZ) ))% of a core | $last | hw: $wc| ${err:-no VA errors} | kernel lines $k"
  done
done
