#!/bin/sh
# compare-dt.sh NEW.dtb REF.dtb
# Semantic comparison of two DTBs: properties (phandles resolved to paths, sorted)
# and child order of every node. Exit 0 when both match.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
python3 "$here/dtnorm.py" "$1" > "$tmp/new.norm"
python3 "$here/dtnorm.py" "$2" > "$tmp/ref.norm"
python3 "$here/dtnorm.py" --order "$1" > "$tmp/new.order"
python3 "$here/dtnorm.py" --order "$2" > "$tmp/ref.order"
rc=0
echo "### properties (< new, > ref)"
diff "$tmp/new.norm" "$tmp/ref.norm" || rc=1
echo "### child order (< new, > ref)"
diff "$tmp/new.order" "$tmp/ref.order" || rc=1
rm -r "$tmp"
exit $rc
