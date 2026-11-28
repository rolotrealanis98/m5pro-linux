#!/bin/bash
# Build the BlueBubbles Linux arm64 bundle in an Ubuntu 24.04 arm64 container on the Studio
# (same distro and Flutter pin as upstream's ubuntu-24.04-arm CI job), serialized with the
# shared build lock. Source is copied INTO the container (git archive), so the checkout stays clean
# and the build does not walk the host mount (vnode pressure, see studio-vnode-exhaustion).
#
#   build.sh [REF]      REF = git ref of the checkout (default: the branch m5pro/client)
#                       REF=v2.1.6+desktop.96 reproduces the upstream release unmodified.
# Output: $OUT/bluebubbles-linux-aarch64-<label>-<commit>.tar.gz (+ .sha256 and build log); an existing file is never replaced
set -euo pipefail
if [ -z "${BB_LOCKED:-}" ]; then BB_LOCKED=1 exec lockf /Volumes/m5pro/bench/.build-lock "$0" "$@"; fi

REPO=${REPO:-/Volumes/m5pro/bluebubbles/bluebubbles-app}
REF=${1:-m5pro/client}
FLUTTER_VERSION=${FLUTTER_VERSION:-$(sed -n 's/^  FLUTTER_VERSION: "\(.*\)"/\1/p' "$REPO/.github/workflows/desktop-builds.yml" | head -1)}
OUT=${OUT:-/Volumes/m5pro/bluebubbles/out}
NAME=${BB_CONTAINER:-bb-build}
CTR=/opt/homebrew/bin/container
LABEL=$(echo "$REF" | tr '/+' '--')-$(git -C "$REPO" rev-parse --short "$REF")   # one file per commit: outputs are never replaced
mkdir -p "$OUT"; LOG="$OUT/build-$LABEL.log"; [ ! -e "$OUT/bluebubbles-linux-aarch64-$LABEL.tar.gz" ] || { echo "already built: $OUT/bluebubbles-linux-aarch64-$LABEL.tar.gz"; exit 0; }

if ! $CTR ls -a | awk '{print $1}' | grep -qx "$NAME"; then
  $CTR create --name "$NAME" -c 10 -m 16G -v "$OUT:/out" ubuntu:24.04 sleep infinity
fi
$CTR ls | awk '{print $1}' | grep -qx "$NAME" || $CTR start "$NAME"
X() { $CTR exec "$NAME" bash -lc "$1"; }

{
echo "== $(date -u +%FT%TZ) ref=$REF flutter=$FLUTTER_VERSION"
X 'command -v make >/dev/null && command -v clang >/dev/null && command -v javac >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends default-jdk-headless build-essential ca-certificates curl git unzip xz-utils zip jq clang cmake ninja-build pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev libmpv-dev libayatana-appindicator3-dev libnotify-dev libjson-glib-dev libglu1-mesa; }'
X "[ -x /opt/flutter/bin/flutter ] && [ \"\$(cat /opt/flutter/version 2>/dev/null)\" = $FLUTTER_VERSION ] || { rm -rf /opt/flutter; git clone -q --depth 1 -b $FLUTTER_VERSION https://github.com/flutter/flutter.git /opt/flutter; }"
X 'git config --global --add safe.directory "*"; /opt/flutter/bin/flutter --version'
X 'rm -rf /work && mkdir /work'
git -C "$REPO" archive "$REF" | $CTR exec -i "$NAME" tar -x -C /work
# The slim profile (BB_SLIM) is on for our branch and off for a pure upstream tag; override with BB_SLIM=0|1.
case "${BB_SLIM:-auto}" in auto) case "$REF" in v*|diag-base*) SLIM=0 ;; *) SLIM=1 ;; esac ;; *) SLIM=$BB_SLIM ;; esac
ARGS=""; [ "$SLIM" = 1 ] && ARGS="--dart-define=BB_SLIM=true"
echo "slim profile: $SLIM"
printf '%s\n' '#!/bin/bash' 'if [ "$1" = build ]; then exec /opt/flutter/bin/flutter "$@" '"$ARGS"'; fi' 'exec /opt/flutter/bin/flutter "$@"' | $CTR exec -i "$NAME" bash -c 'cat > /usr/local/bin/flutter-bb && chmod +x /usr/local/bin/flutter-bb'
X 'cd /work && : > .env && export FLUTTER_CMD=flutter-bb PATH=/opt/flutter/bin:$PATH && bash linux/build.sh'
X 'cp /work/bluebubbles-linux-aarch64.tar.gz /out/bluebubbles-linux-aarch64-'"$LABEL"'.tar.gz'
echo "== done $(date -u +%FT%TZ)"
} 2>&1 | tee "$LOG"
( cd "$OUT" && shasum -a 256 "bluebubbles-linux-aarch64-$LABEL.tar.gz" | tee "bluebubbles-linux-aarch64-$LABEL.tar.gz.sha256" )
