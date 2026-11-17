#!/bin/bash
# Attended AVD (hardware video decode) check for the J716s after the first boot with avd-fw-v5-t2.bin in place.
# Run as root on the MacBook, at the desktop, with the owner watching:  bash /home/rolo/gpu-ab/avd/avd-next-boot.sh [stage]
# Stages (default: all, in order, stopping at the first failed gate): kernel vainfo ffmpeg mpv chrome
# Silent: the clips have no audio track and every player runs with audio off.
# Writes everything to /home/rolo/gpu-ab/avd/run-<time>/ (summary.txt is the result).
set -u
U=rolo; UID_=1001
BASE=/home/rolo/gpu-ab/avd; CLIPS=$BASE/clips
RUN=$BASE/run-$(date +%Y%m%d-%H%M%S); mkdir -p "$RUN"; chown $U:$U "$RUN"
SUM=$RUN/summary.txt
AV1DRV=/opt/libva-avd-av1/dri          # alarm-aurora#330 build (Chrome AV1 fixes), side by side
RN=/dev/dri/renderD128
WL=$(ls /run/user/$UID_ | grep -E '^wayland-[0-9]+$' | head -1)
# the desktop session's Mesa (hypr-gpu-session reads this at login); without it mpv/Chrome started from here get stock Mesa
mapfile -t SESSENV < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' /etc/mesa-aurora/session.env)
asuser() { runuser -u $U -- env "${SESSENV[@]}" XDG_RUNTIME_DIR=/run/user/$UID_ \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus WAYLAND_DISPLAY=$WL "$@"; }
# Owner rule: windows open on Hyprland workspace 5 without switching to it (never the active workspace, never focus).
# onws5 TAG CMD...: Hyprland starts CMD there (so it gets the session's own env); returns when CMD has exited.
HIS=$(ls -t /run/user/$UID_/hypr | head -1)
onws5() {
  local tag=$1; shift; local w=$RUN/$tag.ws5.sh
  { echo '#!/bin/bash'; printf '%q ' "$@"; echo "> $RUN/$tag.log 2>&1; touch $RUN/$tag.done"; } > "$w"; chmod +x "$w"; chown $U:$U "$w"
  runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/$UID_ HYPRLAND_INSTANCE_SIGNATURE=$HIS \
    hyprctl dispatch "hl.dsp.exec_cmd(\"$w\", {workspace = \"5 silent\"})" >/dev/null
  for _ in $(seq 1 120); do [ -e "$RUN/$tag.done" ] && return 0; sleep 0.5; done; return 1
}
say() { echo "$*" | tee -a "$SUM"; }
# TIMED CMD...: runs CMD and prints "<wall> s wall <user> s user <sys> s sys" as its last stderr line (no /usr/bin/time here)
TIMED=(bash -c 'TIMEFORMAT="%R s wall %U s user %S s sys"; time "$@"' _)
D0=$(dmesg | wc -l)   # gates look only at kernel lines logged after this script started
bad_avd() { dmesg | tail -n +$((D0 + 1)) | grep -iE 'avd.*(recover|timeout|timed out|firmware error|open firmware error|probe.*failed|boot failed)' ; }
gate() { if bad_avd >/dev/null; then say "STOP: AVD error in dmesg:"; bad_avd | tail -5 | tee -a "$SUM"; exit 1; fi; }
STAGES=${1:-all}
want() { [ "$STAGES" = all ] || [ "$STAGES" = "$1" ]; }
say "AVD check $(date -u +%FT%TZ), kernel $(uname -r), uptime $(cut -d' ' -f1 /proc/uptime)s"

if want kernel; then
  say "== kernel"
  dmesg | grep -iE 'avd' > "$RUN/dmesg-avd.txt"; tail -15 "$RUN/dmesg-avd.txt" | tee -a "$SUM"
  grep -q 'Direct firmware load.*avd' "$RUN/dmesg-avd.txt" && { say "FAIL: firmware not found (is /usr/lib/firmware/apple/avd-fw-v5-t2.bin there?)"; exit 1; }
  grep -qiE 'probe.*failed|boot failed' "$RUN/dmesg-avd.txt" && { say "FAIL: probe failed"; exit 1; }
  grep -q 't8142' "$RUN/dmesg-avd.txt" && say "WARN: T8142 variant named (expected the t6050 variant, NO_RECOVERY_RESET)"
  grep -oE 'using [a-z]+ transport.*|legacy transport.*' "$RUN/dmesg-avd.txt" | tail -1 | sed 's/^/transport: /' | tee -a "$SUM"
  v4l2-ctl --list-devices > "$RUN/v4l2-devices.txt" 2>&1; cat "$RUN/v4l2-devices.txt" >> "$SUM"
  VDEV=$(for d in /dev/video*; do v4l2-ctl -d $d --info 2>/dev/null | grep -qE 'Driver name *: *(apple-)?avd' && echo $d; done | head -1)
  [ -n "$VDEV" ] || { say "FAIL: no avd V4L2 node"; exit 1; }
  say "avd node: $VDEV; media nodes: $(ls /dev/media* 2>/dev/null | tr '\n' ' ')"
  v4l2-ctl -d $VDEV --list-formats-out 2>&1 | grep -E "\[[0-9]+\]" | tee -a "$SUM"
  gate
fi

if want vainfo; then
  say "== vainfo (automatic discovery: libva picks aurora_drv_video.so from the DRM driver name)"
  asuser env -u LIBVA_DRIVER_NAME timeout 30 vainfo --display drm --device $RN > "$RUN/vainfo.txt" 2>&1
  grep -E 'Driver version|VAProfile|init failed|vaInitialize' "$RUN/vainfo.txt" | tee -a "$SUM"
  grep -q VAProfileH264 "$RUN/vainfo.txt" || { say "FAIL: no H.264 profile from VA-API"; exit 1; }
  gate
fi

# ffmpeg: hardware (VA-API -> v4l2_request -> AVD) vs software, frame by frame. NV12 on both sides.
hw_vs_sw() { # clip [extra env...]
  local c=$1; shift; local n=${c%.*}
  asuser env "$@" "${TIMED[@]}" timeout 120 ffmpeg -hide_banner -nostdin -loglevel error \
    -hwaccel vaapi -hwaccel_device $RN -hwaccel_output_format vaapi -i "$CLIPS/$c" -an -vf hwdownload,format=nv12 \
    -f framemd5 "$RUN/$n.hw.md5" 2> "$RUN/$n.hw.log"
  asuser "${TIMED[@]}" timeout 120 ffmpeg -hide_banner -nostdin -loglevel error \
    -i "$CLIPS/$c" -an -vf format=nv12 -f framemd5 "$RUN/$n.sw.md5" 2> "$RUN/$n.sw.log"
  local nh ns same
  nh=$(grep -vc '^#' "$RUN/$n.hw.md5" 2>/dev/null); ns=$(grep -vc '^#' "$RUN/$n.sw.md5" 2>/dev/null)
  same=$(diff <(grep -v '^#' "$RUN/$n.hw.md5" | awk -F, '{print $NF}') <(grep -v '^#' "$RUN/$n.sw.md5" | awk -F, '{print $NF}') >/dev/null && echo identical || echo DIFFER)
  say "$c: hw frames $nh, sw frames $ns, pixels $same | hw $(tail -1 "$RUN/$n.hw.log") | sw $(tail -1 "$RUN/$n.sw.log")"
  grep -iE 'error|failed|fallback' "$RUN/$n.hw.log" | head -3 | sed 's/^/   hw: /' | tee -a "$SUM"
  gate
}
if want ffmpeg; then
  say "== ffmpeg VA-API vs software (packaged driver)"
  for c in h264-1080p.mp4 hevc-1080p.mp4 vp9-1080p.webm av1-1080p.mp4 h264-2160p.mp4 hevc-2160p.mp4; do hw_vs_sw $c; done
  say "== ffmpeg AV1 with the alarm-aurora#330 driver (Chrome AV1 fixes) from $AV1DRV"
  for c in av1-1080p.mp4 av1-1080p-8tile.mp4; do
    hw_vs_sw $c LIBVA_DRIVERS_PATH=$AV1DRV LIBVA_DRIVER_NAME=v4l2_request
    mv "$RUN/${c%.*}.hw.md5" "$RUN/${c%.*}.av1fix.hw.md5"
  done
fi

if want mpv; then
  say "== mpv on workspace 5 (~8 s per run, audio off). To watch for green/corrupt frames, switch to workspace 5 yourself."
  for c in h264-1080p.mp4 hevc-2160p.mp4 vp9-1080p.webm av1-1080p.mp4; do
    for hw in vaapi no; do
      t=mpv-$c-$hw
      onws5 $t "${TIMED[@]}" timeout 60 mpv --no-config --no-audio --ao=null --hwdec=$hw \
        --vo=gpu --length=8 --msg-level=all=info,vd=v "$CLIPS/$c" || say "$t: did not finish"
      say "$c hwdec=$hw: $(grep -oE 'Using (hardware|software) decoding[^.]*' "$RUN/$t.log" | head -1) | $(tail -1 "$RUN/$t.log")"
      gate
    done
  done
  say "mpv default (/etc/mpv/mpv.conf hwdec=auto-safe, includes vaapi):"
  onws5 mpv-default timeout 30 mpv --no-audio --ao=null --length=4 --msg-level=all=info,vd=v "$CLIPS/h264-1080p.mp4"
  grep -E 'Using (hardware|software) decoding' "$RUN/mpv-default.log" | tee -a "$SUM"
fi

if want chrome; then
  say "== Chrome on workspace 5 (test profile /home/rolo/gpu-ab/chrome-test-avd, never the main profile; page is muted)"
  P=/home/rolo/gpu-ab/chrome-test-avd; asuser mkdir -p $P
  # stock = Omarchy flags + packaged driver; forced = same + the features that lift Chrome's VA-API vendor/GL gates
  # (the AVD driver's vendor string is not Intel/AMD/Mesa Gallium); av1fix = stock flags + the alarm-aurora#330 driver
  # vk = stock driver with the proposed Vulkan flags (chrome-gpu-ab): decode must still be VA-API there before the flags change
  for drv in stock forced av1fix vk; do
    E=(); X=()
    [ $drv = av1fix ] && E=(LIBVA_DRIVERS_PATH=$AV1DRV LIBVA_DRIVER_NAME=v4l2_request)
    [ $drv = vk ] && X=(--use-angle=vulkan --enable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE)
    [ $drv = forced ] && X=(--enable-features=VaapiIgnoreDriverChecks,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL)
    for c in h264-1080p.mp4 av1-1080p-8tile.mp4; do
      t=chrome-$drv-$c; L=$RUN/$t.log
      onws5 $t env "${E[@]}" timeout 25 /opt/google/chrome/chrome --user-data-dir=$P --no-first-run --no-default-browser-check \
        --ozone-platform=wayland --render-node-override=$RN --mute-audio --autoplay-policy=no-user-gesture-required \
        "${X[@]}" --enable-logging=stderr --v=0 --vmodule='*vaapi*=1,video_decoder_pipeline=1,decoder_selector=1' \
        "file://$BASE/play.html#$c" &
      sleep 8; G=$(pgrep -u $U -n -f -- '--type=gpu-process')   # newest GPU process = the test Chrome's (started last)
      C1=$(awk '{print $14+$15}' /proc/$G/stat 2>/dev/null); sleep 10; C2=$(awk '{print $14+$15}' /proc/$G/stat 2>/dev/null)
      # VA-API through v4l2_request means the GPU process holds the avd /dev/media and /dev/video nodes open
      say "chrome $drv $c: gpu-process open nodes: $(ls -l /proc/$G/fd 2>/dev/null | grep -oE '/dev/(media|video)[0-9]+' | sort -u | tr '\n' ' ')"
      wait
      say "chrome $drv $c: decoder $(grep -oE 'VaapiVideoDecoder|VDAVideoDecoder|FFmpegVideoDecoder|Dav1dVideoDecoder|VpxVideoDecoder' "$L" | sort | uniq -c | tr '\n' ' ')| gpu-process CPU $(( (${C2:-0}-${C1:-0}) * 100 / (10 * $(getconf CLK_TCK)) ))% of a core"
      grep -E 'vaInitialize|vaEndPicture failed|VA_STATUS|AVDTEST' "$L" | head -8 | sed 's/^/   /' | tee -a "$SUM"
      gate
    done
  done
  say "By hand: open chrome://gpu in the MAIN Chrome after a restart and check 'Video Acceleration Information' is no longer empty;"
  say "play a muted YouTube video, chrome://media-internals -> kVideoDecoderName should read VaapiVideoDecoder."
fi
say "dmesg tail:"; dmesg | tail -15 >> "$SUM"
chown -R $U:$U "$RUN"; echo "done: $SUM"
