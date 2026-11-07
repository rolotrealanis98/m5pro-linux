#!/usr/bin/env bash
# PR checks in a Fedora 43 container with omacom's tools/aurora-ci (copied to /Volumes/linux-cs/n1kernel-tools/aurora-ci):
# check-commits, compile-check per commit, dt-check base vs head, checkpatch --strict, and optionally dtbs_check of DTBS.
# Usage: check.sh TREE BASE HEAD LOGDIR [DTB...]
set -euo pipefail
T=$1; BASE=$2; HEAD=$3; LOG=$4; shift 4; DTBS="$*"
NAME=kn1pr$RANDOM
container rm -f $NAME >/dev/null 2>&1 || true
container run -d --name $NAME -m 16g -c 8 -v /Volumes/linux-cs:/Volumes/linux-cs -v "$LOG:/log" fedora:43 sleep infinity >/dev/null
trap "container rm -f $NAME >/dev/null 2>&1 || true" EXIT
container exec -e T="$T" -e BASE="$BASE" -e HEAD="$HEAD" -e DTBS="$DTBS" $NAME bash -c '
set -uo pipefail
for i in 1 2 3; do dnf -q install -y clang lld llvm make flex bison bc openssl-devel elfutils-libelf-devel python3 python3-pip python3-devel swig git perl gcc diffutils findutils kmod cpio gzip zstd tar libyaml-devel which > /log/dnf.log 2>&1 && break; sleep 5; done
git config --global --add safe.directory "*"
A=/Volumes/linux-cs/n1kernel-tools/aurora-ci
pip install -q --require-hashes -r $A/dt-requirements.txt > /log/pip.log 2>&1 || tail -5 /log/pip.log
O=/root/out-$(basename $T); mkdir -p $O
cd $T; git checkout -q --detach "$HEAD"
{ git log --oneline -1; clang --version | head -1; dt-validate --version 2>&1 | head -1; } > /log/toolchain.txt
echo "== check-commits"; python3 $A/check-commits.py --repo $T --base "$BASE" --head "$HEAD" > /log/check-commits.log 2>&1; echo "rc=$?" | tee -a /log/check-commits.log
echo "== config"; make -s LLVM=1 ARCH=arm64 O=$O/cfg defconfig asahi.config > /log/config.log 2>&1
scripts/config --file $O/cfg/.config -e PCIE_APPLE -e APPLE_DART -e GPIO_MACSMC -e MFD_MACSMC >/dev/null; make -s LLVM=1 ARCH=arm64 O=$O/cfg olddefconfig >> /log/config.log 2>&1
grep -E "^CONFIG_(PCIE_APPLE|APPLE_DART|GPIO_MACSMC|MFD_MACSMC)=" $O/cfg/.config > /log/config-symbols.txt
echo "== compile-check"; python3 $A/compile-check.py --tree $T --base "$BASE" --head "$HEAD" --config $O/cfg/.config --out $O/cc --per-commit --jobs 8 --rust skip > /log/compile-check.log 2>&1; echo "rc=$?" | tee -a /log/compile-check.log; cp $O/cc/summary.md /log/compile-check-summary.md 2>/dev/null
echo "== dt-check"; python3 $A/dt-check.py --tree $T --base "$BASE" --head "$HEAD" --out $O/dt --jobs 8 > /log/dt-check.log 2>&1; echo "rc=$?" | tee -a /log/dt-check.log; cp $O/dt/*.md $O/dt/*.json /log/ 2>/dev/null
cd $T; git checkout -q --detach "$HEAD"
if [ -n "$DTBS" ]; then echo "== dtbs_check"; make -s LLVM=1 ARCH=arm64 O=$O/dtb defconfig >/dev/null 2>&1
  for d in $DTBS; do make LLVM=1 ARCH=arm64 O=$O/dtb W=1 CHECK_DTBS=y apple/$d.dtb > /log/dtbs_check-$d.log 2>&1; echo "$d rc=$?" | tee -a /log/dtbs_check-$d.log; done
  make LLVM=1 ARCH=arm64 O=$O/dtb dt_binding_check DT_SCHEMA_FILES="pci/apple,pcie.yaml:iommu/apple,dart.yaml" > /log/dt_binding_check.log 2>&1; echo "binding rc=$?" | tee -a /log/dt_binding_check.log; fi
echo "== checkpatch"; rm -rf /tmp/p; git format-patch -q -o /tmp/p "$BASE..$HEAD"; for f in /tmp/p/*.patch; do echo "### $(basename $f)"; scripts/checkpatch.pl --strict --no-tree -q $f; done > /log/checkpatch-strict.log 2>&1; grep -c -E "^(ERROR|WARNING|CHECK)" /log/checkpatch-strict.log
'
echo "container checks finished"
