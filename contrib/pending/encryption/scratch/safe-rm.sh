#!/bin/bash
# safe-rm.sh DIR: the only way the requests tell anyone to remove a scratch tree. Refuses while anything is mounted under it.
. "$(dirname "$0")/m5-chroot.sh"
for d in "$@"; do m5_safe_rm "$d" && echo "removed $d"; done
