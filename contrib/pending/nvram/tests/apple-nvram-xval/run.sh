#!/bin/bash
# SPDX-License-Identifier: MIT
# Cross-check v3-nvram.py's model of `asahi-bless --set-boot X` (no --next) against apple-nvram's own Rust code
# (path dependency in Cargo.toml: the asahi-nvram checkout at 3df52c9 on the work volume). Synthetic dumps only.
#   bash run.sh [SEEDS] [WORKDIR]
set -u
H=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd); T=$H/../../tools; N=${1:-60}; W=${2:-$(mktemp -d)}
CARGO_TARGET_DIR=$W/target cargo build --release -q --manifest-path "$H/Cargo.toml" || exit 1
V=EF57347C-0000-AA11-AA11-00306543ECAC:00000000-0000-4000-8000-000000000001:00000000-0000-4000-8000-000000000002
ok=0 bad=0 ref=0
for i in $(seq 1 "$N"); do
    python3 "$H/random-dump.py" "$H/../synth-nvram.py" "$W/d.bin" "$i"
    if python3 -I "$T/v3-nvram.py" plan-default "$W/d.bin" >/dev/null; then
        python3 -I "$T/v3-nvram.py" simulate-default "$W/d.bin" "$W/p.bin" >/dev/null
        "$W/target/release/xval" "$W/d.bin" "$W/r.bin" "$V" 2>/dev/null
        if cmp -s "$W/p.bin" "$W/r.bin" && python3 -I "$T/v3-nvram.py" verify-default "$W/d.bin" "$W/r.bin" >/dev/null; then ok=$((ok + 1)); else bad=$((bad + 1)); echo "MISMATCH seed $i"; fi
    else ref=$((ref + 1)); fi
done
echo "model == apple-nvram and verified: $ok; mismatched: $bad; refused by the plan: $ref"
[ "$bad" = 0 ]
