#!/usr/bin/env bash
# Per-commit compile check of j716s-daily-dcp-recovery2 (run after build-kernel-r2.sh, same object dir and toolchain): for the base ed7e1d0c42b0 and each of the two fault commits,
# rebuild drivers/gpu/drm/asahi/ and drivers/gpu/drm/apple/
# from scratch (their objects deleted) with W=1 CLIPPY=1, keep the warnings, and compare each commit's set with the
# base's (paths and messages, line numbers stripped). Results in kbuild/check/. No tools/aurora-ci in this tree.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd); LOG=$S/kbuild-r2; mkdir -p "$LOG/check"
W=/Volumes/linux-cs-gpurec/wt-daily-dcp-recovery
[ -z "$(git -C $W status --porcelain)" ] || { echo "$W is dirty"; exit 1; }
container rm -f kgpurec2chk >/dev/null 2>&1 || true
container run -d --name kgpurec2chk -m 16g -c 8 -v /Volumes/linux-cs:/Volumes/linux-cs -v /Volumes/linux-cs-gpurec:/Volumes/linux-cs-gpurec -v "$LOG:/log" fedora:43 sleep infinity >/dev/null
trap 'container rm -f kgpurec2chk >/dev/null 2>&1 || true; git -C '$W' checkout -q j716s-daily-dcp-recovery2' EXIT
container exec kgpurec2chk bash -c '
set -euo pipefail
ulimit -n 1048576 2>/dev/null || ulimit -n 524288 || true
dnf -q install -y clang clang-devel clang-libs lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 git perl gcc rustup findutils diffutils kmod cpio gzip zstd patch tar curl pkgconf-pkg-config ncurses-devel >/dev/null 2>&1
rustup-init -y -q --default-toolchain 1.99.1 --profile minimal -c rust-src -c rustfmt -c clippy >/dev/null 2>&1
source ~/.cargo/env
git config --global --add safe.directory "*"
W=/Volumes/linux-cs-gpurec/wt-daily-dcp-recovery; O=/Volumes/linux-cs-gpurec/wt-daily-dcp-recovery2-out
BINDGEN=/Volumes/linux-cs/wt-daily-dcp/tools/aurora-bindgen/build/bin/bindgen
cd $W
for c in ed7e1d0c42b0 $(git rev-list --reverse ed7e1d0c42b0..j716s-daily-dcp-recovery2); do
  git checkout -q $c
  find $O/drivers/gpu/drm/asahi $O/drivers/gpu/drm/apple -name "*.o" -delete 2>/dev/null || true
  L=/log/check/$(git log -1 --format=%h)-$(git log -1 --format=%f | cut -c1-40).log
  if make -j8 LLVM=1 ARCH=arm64 O=$O BINDGEN=$BINDGEN LOCALVERSION= W=1 CLIPPY=1 drivers/gpu/drm/asahi/ drivers/gpu/drm/apple/ > $L 2>&1; then r=OK; else r=FAILED; fi
  # C: "path:line:col: warning: msg"; Rust/clippy: "warning: msg" then "--> path:line:col"
  awk '\''/^(warning|error)/ {m=$0; next} /--> .*drivers\/gpu\/drm\/(asahi|apple)/ {sub(/.*--> /,""); sub(/:[0-9]+:[0-9]+$/,""); print $0 ": " m; next} /drivers\/gpu\/drm\/(asahi|apple).*: (warning|error):/ {sub(/:[0-9]+:[0-9]+:/,":"); print}'\'' $L | sort -u > $L.warn || true
  echo "$(git log -1 --format="%h %s") build=$r warnings=$(wc -l < $L.warn)" | tee -a /log/check/summary.txt
done
B=$(ls /log/check/ed7e1d0c42b0*.log.warn)
for f in /log/check/*.log.warn; do [ "$f" = "$B" ] && continue; echo "== new vs base: $(basename $f)"; comm -13 $B $f; done | tee /log/check/new-warnings.txt
'
