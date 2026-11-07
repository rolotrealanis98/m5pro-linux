#!/bin/bash
# pt-one.sh <ref> <pytest args...>: one focused pytest run in the Fedora 43 container, full output
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TREE=$HOME/Work/agents/aurora-prs-2/m1n1; REF=$1; shift
container rm -f omacompt1 >/dev/null 2>&1 || true
container run -d --name omacompt1 -v "$TREE:/src" -v "$HERE:/out" docker.io/library/fedora:43 sleep infinity >/dev/null
trap 'container rm -f omacompt1 >/dev/null 2>&1 || true' EXIT
printf '%s\n' "$@" > "$HERE/.ptargs"
container exec omacompt1 bash -c "
dnf -y -q install clang lld llvm make git python3 python3-pip gcc >/dev/null; pip install -q -r /src/requirements.txt pytest==9.1.1 >/dev/null 2>&1
git config --global --add safe.directory '*'; cd / && git clone -q /src /pt && cd /pt && git checkout -q $REF
mapfile -t A < /out/.ptargs; pytest -p no:cacheprovider \"\${A[@]}\" 2>&1 | tail -60"
