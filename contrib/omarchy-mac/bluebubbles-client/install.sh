#!/bin/bash
# Install a built tarball on the Mac next to the upstream install and point the wrapper at it.
#   install.sh TARBALL [TAG]     TAG names the backups (default: the tarball's label)
# Runs on the Studio; reaches the Mac through the bench ssh wrapper under the Mac lock.
# Refuses while BlueBubbles runs (shared app data dir). Backs up before replacing, deletes nothing.
set -euo pipefail
TAR=${1:?tarball}; TAG=${2:-$(basename "$TAR" .tar.gz | sed 's/^bluebubbles-linux-aarch64-//')}
HERE=$(cd "$(dirname "$0")" && pwd)
MBP=${MBP:-/Volumes/m5pro/bench/session-20261123/mbp}
DAY=$(date +%Y%m%d)
DEST=${BB_DEST:-bluebubbles-m5pro}   # BB_DEST=bluebubbles-m5pro-dev installs a side copy for testing and leaves the wrapper alone
[ -n "${BB_DEST:-}" ] || lockf -t 1800 /Volumes/m5pro/bench/.mac-lock "$MBP" "pgrep -x bluebubbles >/dev/null && { echo 'BlueBubbles is running; close it first' >&2; exit 1; }; exit 0"
cat "$TAR" | lockf -t 1800 /Volumes/m5pro/bench/.mac-lock "$MBP" "set -e; O=/home/rolo/.local/opt; D=\$O/$DEST
  [ -d \$D ] && mv \$D \$D.pre-$TAG-$DAY
  mkdir -p \$D && tar -xz -C \$D
  # The Klipy (GIF) key lives in the upstream release's .env; builds here have an empty one. Reuse the installed upstream copy.
  [ -s \$O/bluebubbles/data/flutter_assets/.env ] && cp -p \$O/bluebubbles/data/flutter_assets/.env \$D/data/flutter_assets/.env
  chown -R rolo:rolo \$D"
[ -n "${BB_DEST:-}" ] && { echo "installed $TAR -> ~/.local/opt/$DEST (wrapper untouched)"; exit 0; }
W=/home/rolo/.local/bin/bluebubbles
lockf -t 1800 /Volumes/m5pro/bench/.mac-lock "$MBP" "[ -e $W.pre-m5pro-client-20261127 ] || cp -p $W $W.pre-m5pro-client-20261127"
cat "$HERE/files/bluebubbles" | lockf -t 1800 /Volumes/m5pro/bench/.mac-lock "$MBP" "cat > $W && chmod 755 $W && chown rolo:rolo $W"
echo "installed $TAR -> ~/.local/opt/bluebubbles-m5pro (wrapper backup: $W.pre-m5pro-client-20261127)"
