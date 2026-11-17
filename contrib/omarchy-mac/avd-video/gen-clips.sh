#!/bin/sh
# Silent synthetic test clips (no audio track). testsrc2 + light noise so the bitstreams are not trivial.
set -e
SRC="testsrc2=size=1920x1080:rate=30,noise=alls=12:allf=t"
SRC4K="testsrc2=size=3840x2160:rate=30,noise=alls=12:allf=t"
# ALARM libx265 is 8-bit only, so there is no 10-bit HEVC clip here.
F="ffmpeg -hide_banner -loglevel error -y -f lavfi"
$F -i "$SRC" -t 10 -an -pix_fmt yuv420p -c:v libx264 -profile:v high -preset veryfast -b:v 8M h264-1080p.mp4
$F -i "$SRC" -t 10 -an -pix_fmt yuv420p -c:v libx265 -preset veryfast -b:v 6M -tag:v hvc1 hevc-1080p.mp4
$F -i "$SRC" -t 10 -an -pix_fmt yuv420p -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 -b:v 6M vp9-1080p.webm
$F -i "$SRC" -t 6 -an -pix_fmt yuv420p -c:v libaom-av1 -cpu-used 8 -row-mt 1 -usage realtime -b:v 5M av1-1080p.mp4
$F -i "$SRC" -t 6 -an -pix_fmt yuv420p -c:v libaom-av1 -cpu-used 8 -row-mt 1 -usage realtime -tiles 4x2 -b:v 5M av1-1080p-8tile.mp4
$F -i "$SRC4K" -t 6 -an -pix_fmt yuv420p -c:v libx265 -preset ultrafast -b:v 20M -tag:v hvc1 hevc-2160p.mp4
$F -i "$SRC4K" -t 6 -an -pix_fmt yuv420p -c:v libx264 -preset ultrafast -b:v 25M h264-2160p.mp4
sha256sum *.mp4 *.webm > SHA256SUMS
echo done
