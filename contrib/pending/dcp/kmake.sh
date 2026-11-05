#!/usr/bin/env bash
# Build helper for /Volumes/linux-cs/wt-dcp (mirrors omarchy-m5 scripts/build-kernel.sh Darwin branch).
export PATH="$(brew --prefix coreutils)/libexec/gnubin:$(brew --prefix gnu-sed)/libexec/gnubin:/opt/homebrew/opt/llvm/bin:$PATH"
GMAKE="$(command -v gmake)"
exec "$GMAKE" -C /Volumes/linux-cs/wt-dcp ARCH=arm64 LLVM=1 -j8 \
  "HOSTCFLAGS=-I$HOME/Work/omarchy-m5/scripts/host-shim" \
  "HOSTCFLAGS_file2alias.o=-D_POSIX_C_SOURCE=200809L" "$@"
