#!/bin/bash
# video-test.sh: J716s media engine checks, run as root on the booted Arch root.
#
#   video-test.sh probe      load apple_avd (and apple_jpeg if its node is on), check
#                            probe, firmware boot, /dev/video*, DART faults
#   video-test.sh decode     H.264 and HEVC decode through GStreamer v4l2codecs,
#                            compared frame-exact with the software decoders
#   video-test.sh vaapi      the same clips through VA-API (libva-v4l2-request)
#   video-test.sh jpeg       NV12 frames through the JPEG encoder
#
# Every step has a timeout and only reads or writes under $WORK. Modules come
# from /lib/modules/$(uname -r)/updates when present (the T6050 builds), else
# from the running kernel's tree. The payload boots with
# module_blacklist=apple_avd,apple_jpeg, so nothing here runs at boot.
set -u
WORK=${WORK:-/root/video-test}
CLIPS=${CLIPS:-$WORK/clips}
mkdir -p "$WORK"
LOG=$WORK/$(date +%Y%m%d-%H%M%S)-$1.log
exec > >(tee "$LOG") 2>&1

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0
dmesg_mark() { echo "video-test: $1" > /dev/kmsg; }
dmesg_since() { dmesg | sed -n "/video-test: $1/,\$p"; }
dart_faults() { dmesg_since "$1" | grep -iE 'dart.*(fault|error)|apple-dart.*(err|fault)' || true; }

vdev_for() { # driver name -> /dev/videoN
	for d in /sys/class/video4linux/video*; do
		[ -e "$d/device/driver" ] || continue
		if [ "$(basename "$(readlink -f "$d/device/driver")")" = "$1" ]; then
			echo "/dev/$(basename "$d")"; return 0
		fi
	done
	return 1
}

probe() {
	dmesg_mark probe
	uname -r
	ls -l /lib/firmware/apple/avd-fw-v5-t2.bin || fail "avd-fw-v5-t2.bin missing"
	timeout 60 modprobe apple_avd || fail "modprobe apple_avd"
	sleep 3
	if [ -d /sys/firmware/devicetree/base/soc@2280000000/jpeg@2281000000 ] &&
	   [ "$(tr -d '\0' < /sys/firmware/devicetree/base/soc@2280000000/jpeg@2281000000/status 2>/dev/null || echo okay)" = okay ]; then
		timeout 60 modprobe apple_jpeg || fail "modprobe apple_jpeg"
		sleep 2
	fi
	dmesg_since probe | grep -iE 'avd|jpeg|dart' | tail -40
	modinfo -F filename apple_avd
	V=$(vdev_for avd) && pass "AVD at $V" || fail "no AVD video node"
	dmesg_since probe | grep -q 'firmware probe boot failed' && fail "AVD firmware did not boot"
	dmesg_since probe | grep -qi 'CM3' && dmesg_since probe | grep -i 'CM3'
	[ -n "${V:-}" ] && timeout 10 v4l2-ctl -d "$V" --info --list-formats-out
	J=$(vdev_for apple-jpeg) && pass "JPEG at $J" || echo "no JPEG node (expected on stage V1)"
	F=$(dart_faults probe); [ -z "$F" ] && pass "no DART faults" || { echo "$F"; fail "DART faults"; }
}

mkclips() {
	mkdir -p "$CLIPS"
	[ -s "$CLIPS/h264.mp4" ] || timeout 120 ffmpeg -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 \
		-t 3 -c:v libx264 -profile:v high -pix_fmt yuv420p -g 30 -bf 2 "$CLIPS/h264.mp4"
	[ -s "$CLIPS/hevc.mp4" ] || timeout 300 ffmpeg -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 \
		-t 3 -c:v libx265 -pix_fmt yuv420p -x265-params keyint=30:bframes=2 -tag:v hvc1 "$CLIPS/hevc.mp4"
}

# gst_md5 CLIP PARSER DECODER -> md5 of the raw NV12 frames
gst_md5() {
	timeout 120 gst-launch-1.0 -q filesrc location="$1" ! qtdemux ! "$2" ! "$3" ! \
		videoconvert ! video/x-raw,format=NV12 ! filesink location="$WORK/out.nv12" >/dev/null 2>&1 || return 1
	md5sum < "$WORK/out.nv12" | cut -d' ' -f1
}

decode() {
	dmesg_mark decode
	mkclips
	for c in "h264 h264parse v4l2slh264dec avdec_h264" "hevc h265parse v4l2slh265dec avdec_h265"; do
		set -- $c
		hw=$(gst_md5 "$CLIPS/$1.mp4" "$2" "$3") || { fail "$1: hardware decode did not finish"; continue; }
		sw=$(gst_md5 "$CLIPS/$1.mp4" "$2" "$4") || { fail "$1: software decode failed"; continue; }
		[ "$hw" = "$sw" ] && pass "$1 bit-exact ($hw)" || fail "$1 differs (hw $hw sw $sw)"
	done
	dmesg_since decode | grep -iE 'avd|recover|timeout' | tail -20
	F=$(dart_faults decode); [ -z "$F" ] && pass "no DART faults" || { echo "$F"; fail "DART faults"; }
}

vaapi() {
	dmesg_mark vaapi
	mkclips
	V=$(vdev_for avd) || { fail "no AVD node"; return; }
	export LIBVA_DRIVER_NAME=v4l2_request LIBVA_V4L2_REQUEST_VIDEO_PATH=$V
	timeout 20 vainfo || fail "vainfo"
	for c in h264 hevc; do
		timeout 120 ffmpeg -loglevel error -hwaccel vaapi -i "$CLIPS/$c.mp4" -f rawvideo -pix_fmt nv12 "$WORK/va-$c.nv12" -y &&
			timeout 120 ffmpeg -loglevel error -i "$CLIPS/$c.mp4" -f rawvideo -pix_fmt nv12 "$WORK/sw-$c.nv12" -y || { fail "$c: ffmpeg"; continue; }
		cmp -s "$WORK/va-$c.nv12" "$WORK/sw-$c.nv12" && pass "$c VA-API bit-exact" || fail "$c VA-API differs"
	done
	F=$(dart_faults vaapi); [ -z "$F" ] && pass "no DART faults" || { echo "$F"; fail "DART faults"; }
}

jpeg() {
	dmesg_mark jpeg
	dmesg | grep -i 'JPEG encoder, HWREV\|unsupported HWREV' | tail -2
	J=$(vdev_for apple-jpeg) || { fail "no JPEG node"; return; }
	rm -f "$WORK"/j*.jpg
	timeout 60 gst-launch-1.0 -q videotestsrc num-buffers=10 ! video/x-raw,format=NV12,width=640,height=480 ! \
		v4l2jpegenc device="$J" ! multifilesink location="$WORK/j%02d.jpg" || fail "JPEG encode"
	n=0; for f in "$WORK"/j*.jpg; do
		[ -s "$f" ] && timeout 20 ffmpeg -loglevel error -i "$f" -f null - && n=$((n + 1))
	done
	[ $n = 10 ] && pass "10 JPEG frames decode" || fail "$n of 10 JPEG frames decode"
	F=$(dart_faults jpeg); [ -z "$F" ] && pass "no DART faults" || { echo "$F"; fail "DART faults"; }
}

case "${1:-}" in
probe|decode|vaapi|jpeg) "$1" ;;
*) echo "usage: $0 probe|decode|vaapi|jpeg"; exit 2 ;;
esac
echo "log: $LOG"
[ $FAILED = 0 ] && echo RESULT: PASS || echo RESULT: FAIL
exit $FAILED
