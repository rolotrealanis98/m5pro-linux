#!/bin/bash
# Builds branch tb/j716s-daily = daily series tip + revert of our 0051 + PR #946's own commits,
# with plumbing only (no worktree). The one conflict (pcie-apple.c struct hw_info fields) is
# resolved by keeping both sides.
set -e
cd /Volumes/linux-cs/linux
BASE=${1:-a0f2f30c967b}
export GIT_COMMITTER_NAME="Rolando Trevino" GIT_COMMITTER_EMAIL=rolotrealanis@gmail.com
cur=$BASE
# 1. revert 0051 (#946 carries the hardware-checked T6050 CIO reset)
R=14e7655c3ff6
t=$(git merge-tree --write-tree --merge-base=$R $cur $R^ | head -1)
msg=$(printf 'Revert "reset: apple-cio: Add the T6050 reconfiguration register"\n\nThis reverts commit %s. "reset: apple-cio: add the T6050 CIO reconfig\nrequest" from aurora-silicon/linux#946 replaces it: on T6050 the odd bit\nis a done flag, and request and done must both clear before the CPU\nwrapper is touched.\n\nSigned-off-by: Rolando Trevino <rolotrealanis@gmail.com>\nAssisted-by: LLM Claude\n' "$(git rev-parse --short=12 $R)")
cur=$(GIT_AUTHOR_NAME="$GIT_COMMITTER_NAME" GIT_AUTHOR_EMAIL=$GIT_COMMITTER_EMAIL git commit-tree $t -p $cur -m "$msg")
for c in $(git rev-list --reverse aurora/pr946~18..aurora/pr946); do
  out=$(git merge-tree --write-tree --merge-base=$c^ $cur $c 2>&1) && rc=0 || rc=$?
  t=$(echo "$out" | head -1)
  if [ $rc -ne 0 ]; then
    f=drivers/pci/controller/pcie-apple.c
    echo "$out" | grep -q "CONFLICT.*$f" || { echo "unexpected conflict in $c"; echo "$out"; exit 1; }
    git show $t:$f | python3 -c '
import sys,re
s=sys.stdin.read()
def fix(m):
    ours,theirs=m.group(1),m.group(3)
    return ours+"".join(l for l in theirs.splitlines(True) if l not in ours)
s,n=re.subn(r"<<<<<<< [^\n]*\n(.*?)\|\|\|\|\|\|\| [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n",fix,s,flags=re.S)
assert n==1 and "<<<<<<<" not in s
sys.stdout.write(s)' > /tmp/.tbstack.c
    blob=$(git hash-object -w /tmp/.tbstack.c); rm -f /tmp/.tbstack.c
    export GIT_INDEX_FILE=$(mktemp -u)
    git read-tree $t; git update-index --cacheinfo 100644,$blob,$f; t=$(git write-tree); rm -f $GIT_INDEX_FILE; unset GIT_INDEX_FILE
  fi
  [ "$t" = "$(git rev-parse $cur^{tree})" ] && { echo "skip (in series) $(git log -1 --format=%s $c)"; continue; }
  cur=$(GIT_AUTHOR_NAME="$(git log -1 --format=%an $c)" GIT_AUTHOR_EMAIL="$(git log -1 --format=%ae $c)" GIT_AUTHOR_DATE="$(git log -1 --format=%aD $c)" git commit-tree $t -p $cur -m "$(git log -1 --format=%B $c)")
done
git update-ref refs/heads/tb/j716s-daily $cur
git log --oneline $BASE..tb/j716s-daily
