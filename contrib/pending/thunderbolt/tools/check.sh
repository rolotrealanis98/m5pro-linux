#!/bin/bash
# check.sh <tree> <dtb> <log>  -- dtbs_check equivalent (dt-mk-schema + dt-validate -m)
set -e
V=${DT_SCHEMA_BIN:-$HOME/Work/agents/board-pr/venv/bin}
T=$1; S=$(dirname $3)/schema-$(basename $T).json
[ -f "$S" ] || $V/dt-mk-schema -j -u $T/Documentation/devicetree/bindings > "$S" 2>$(dirname $3)/mk-schema-$(basename $T).log
$V/dt-validate -m -u $T/Documentation/devicetree/bindings -p "$S" "$2" > "$3" 2>&1 || true
wc -l < "$3"
