#!/bin/bash
# Compile the drm/apple objects that include the files the two commits touch, with the exact kbuild
# command lines of a real DRM_APPLE=y build (wt-gpu-e1-out, a #1012-based tree), pointed at the PR
# branch: drivers/gpu/drm/apple from the sparse worktree, the rest of the tree from a git archive of the same
# commit). Objects go to a scratch dir; nothing is linked. Usage: compile-objs.sh <clang> <outdir>
set -u
CLANG=${1:-/opt/homebrew/opt/llvm/bin/clang}; OUT=${2:-/tmp/dcp-objs}
OBJDIR=/Volumes/linux-cs/wt-gpu-e1-out; OLD=/Volumes/linux-cs/wt-gpu-e1
APPLE=${APPLE:-/Volumes/linux-cs/wt-dcp-pr/drivers/gpu/drm/apple}; REST=${REST:?git archive <rev> include arch/arm64/include into a dir}
OBJS="afk connector apple_drv dcp-180hz dcp-fabric dcp dcp-hdmi dcp_backlight dptxep dcpext_drm ibootep dcpext_scanout iomfb_v12_3 iomfb iomfb_v13_3 iomfb_h17p iomfb_v14_7_tpl iomfb_v14_7 iomfb_v26_6 iomfb_v27 iomfb_v26_6_desktop j613_dcp_activate systemep parser plane"
mkdir -p "$OUT"; cd "$OBJDIR" || exit 1
$CLANG --version | head -1
fail=0
for o in $OBJS; do
    cmd=$(sed -n 's/^savedcmd_[^ ]* := //p' drivers/gpu/drm/apple/.$o.o.cmd)
    cmd=${cmd//$OLD\/drivers\/gpu\/drm\/apple/$APPLE}
    cmd=${cmd//$OLD/$REST}
    cmd=$(sed -E "s#^clang #$CLANG #; s#-Wp,-MMD,[^ ]+ ##; s#-c -o [^ ]+\.o #-c -o $OUT/$o.o #" <<<"$cmd")
    if eval "$cmd" 2>"$OUT/$o.log"; then r=ok; else r=FAIL; fail=1; fi
    echo "$o: $r, $(grep -c 'warning:' "$OUT/$o.log") warnings, $(grep -c 'error:' "$OUT/$o.log") errors"
done
exit $fail
