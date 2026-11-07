#!/bin/bash
# Quick single build of one commit in the Fedora 43 container (same toolchain as build.sh).
set -euo pipefail
REF=$1; NAME=${2:-quick}; shift 2 || true
HERE=$(cd "$(dirname "$0")" && pwd)
TREE=$HOME/Work/agents/aurora-prs-2/m1n1
container rm -f omacomquick >/dev/null 2>&1 || true
container run -d --name omacomquick -v "$TREE:/src" -v "$HERE:/out" docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f omacomquick >/dev/null 2>&1 || true' EXIT
container exec omacomquick bash -c "
set -e
dnf -y -q install clang clang-tools-extra lld llvm make git python3 rustup ImageMagick diffutils which >/dev/null
rustup-init -y -q --no-modify-path --default-toolchain 1.99.1 -t aarch64-unknown-none-softfloat -c rust-src >/dev/null 2>&1
export PATH=\$HOME/.cargo/bin:\$PATH
git config --global --add safe.directory '*'
rm -rf /build && git clone -q /src /build && cd /build && git checkout -q $REF
make -j8 $* > /out/$NAME.log 2>&1 || { tail -40 /out/$NAME.log; exit 1; }
echo \"$NAME: \$(grep -c 'warning:' /out/$NAME.log) warnings, \$(stat -c %s build/m1n1.bin) bytes\"
grep 'warning:' /out/$NAME.log | sort -u | head -30
"
