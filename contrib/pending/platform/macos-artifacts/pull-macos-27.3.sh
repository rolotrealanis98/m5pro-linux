#!/usr/bin/env bash
# pull-macos-27.3.sh - one-shot, read-only extraction of macOS GPU/display driver
# artifacts from the M5 Pro MacBook Pro (J716s) while it is booted into macOS.
#
# Run on the Studio:
#   HOST=rolo@<tailscale-ip> bash pull-macos-27.3.sh [OPTIONS] [OUTDIR]
#
# OUTDIR defaults to ~/Work/studio-artifacts/macos-<version>-<build>/ (the PRIVATE
# area). Nothing fetched here may ever go into a git repository: the script refuses
# an OUTDIR under ~/Documents/GitHub, under ~/Work/agents, or inside any git work
# tree. The output holds serial numbers (ioreg) and hashes (MANIFEST.txt).
#
# Rules this script follows:
#   - read-only on the Mac: ssh + rsync/scp reads, ioreg, sw_vers, nvram -p (read),
#     diskutil list, kmutil inspect/showloaded. No sudo, no writes, no password
#     prompt (ssh BatchMode; whatever needs root is skipped and reported).
#   - nothing is copied until the size estimate is printed; above --max-gb
#     (default 20) it aborts unless --yes.
#
# Options:
#   --list         discovery + size table only; copy nothing
#   --yes, -y      proceed even above the size limit
#   --max-gb N     size limit in GiB (default 20)
#   --skip-ioreg   do not capture ioreg / nvram / diskutil text dumps
#   -h, --help
#
# Environment:
#   HOST       required, user@host of the Mac booted into macOS
#   SSH_OPTS   extra ssh options (word-split), e.g. "-i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes"
#
# Needs on the Studio: bash >= 3.2, ssh, rsync (or scp), shasum or sha256sum, awk, df, du.

set -o pipefail
umask 077

PROG=${0##*/}

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
die()   { echo "$PROG: error: $*" >&2; exit 1; }
note()  { echo "== $*"; }

YES=0; LIST_ONLY=0; SKIP_IOREG=0; MAX_GB=20; OUT=
while [ $# -gt 0 ]; do
  case $1 in
    --yes|-y)     YES=1 ;;
    --list)       LIST_ONLY=1 ;;
    --skip-ioreg) SKIP_IOREG=1 ;;
    --max-gb)     shift; MAX_GB=${1:-} ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; [ $# -gt 0 ] && OUT=$1; break ;;
    -*)           die "unknown option: $1 (try --help)" ;;
    *)            [ -z "$OUT" ] || die "more than one output directory given"; OUT=$1 ;;
  esac
  shift
done
case $MAX_GB in ''|*[!0-9]*) die "--max-gb needs a whole number" ;; esac

[ -n "${HOST:-}" ] || die "set HOST=user@host (the Mac booted into macOS), e.g. HOST=rolo@<macbook-tailscale-ip>"
case $HOST in -*|*[[:space:]]*|*[!A-Za-z0-9@._:%-]*) die "HOST looks wrong: $HOST" ;; esac

for t in ssh awk df du sort find; do command -v "$t" >/dev/null 2>&1 || die "missing local tool: $t"; done
if command -v shasum >/dev/null 2>&1; then SHA() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then SHA() { sha256sum "$1" | awk '{print $1}'; }
else die "need shasum or sha256sum"; fi
if [ "$(uname -s)" = Darwin ]; then FSIZE() { stat -f %z "$1"; }; else FSIZE() { stat -c %s "$1"; }; fi
USE_RSYNC=0; command -v rsync >/dev/null 2>&1 && USE_RSYNC=1
if [ "$USE_RSYNC" = 0 ]; then command -v scp >/dev/null 2>&1 || die "need rsync or scp"; fi

# ---- ssh plumbing: one multiplexed connection, never ask for a password -----------
CTL=$(mktemp -d /tmp/pm27.XXXXXX) || die "mktemp failed"
SSH_ARGS=(-o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
          -o NumberOfPasswordPrompts=0 -o ConnectTimeout=10 -o ServerAliveInterval=15
          -o ControlMaster=auto -o "ControlPath=$CTL/c" -o ControlPersist=300)
# shellcheck disable=SC2206
[ -n "${SSH_OPTS:-}" ] && SSH_ARGS+=( $SSH_OPTS )
cleanup() { ssh "${SSH_ARGS[@]}" -O exit "$HOST" >/dev/null 2>&1; rm -rf "${CTL:?}"; }
trap cleanup EXIT
trap 'echo; echo "$PROG: interrupted" >&2; exit 130' INT TERM

rsh()        { ssh "${SSH_ARGS[@]}" "$HOST" "$@"; }       # remote command string
rsh_script() { ssh "${SSH_ARGS[@]}" "$HOST" sh -s; }      # POSIX sh script on stdin

hs() { awk -v k="$1" 'BEGIN{ if (k>=1048576) printf "%.2f GiB",k/1048576; else if (k>=1024) printf "%.1f MiB",k/1024; else printf "%d KiB",k }'; }

# ---- 1. reach the Mac and make sure it is macOS -------------------------------------
note "connecting to $HOST (BatchMode, no password prompts)"
KERN=$(rsh 'uname -s' 2>"$CTL/err") || {
  cat "$CTL/err" >&2
  die "cannot ssh to $HOST non-interactively. Is the Mac booted into macOS, is Tailscale up, and does key auth work?"
}
if [ "$KERN" != Darwin ]; then
  die "$HOST answers as '$KERN', not Darwin: the MacBook is still running Linux. Boot it into macOS first."
fi
PV=$(rsh 'sw_vers -productVersion' 2>/dev/null | tr -d '\r')
BV=$(rsh 'sw_vers -buildVersion' 2>/dev/null | tr -d '\r')
UV=$(rsh 'uname -v' 2>/dev/null | tr -d '\r')
HM=$(rsh 'sysctl -n hw.model' 2>/dev/null | tr -d '\r')
ARCH=$(rsh 'uname -m' 2>/dev/null | tr -d '\r')
[ -n "$PV" ] && [ -n "$BV" ] || die "sw_vers returned nothing; is this really macOS?"
note "macOS $PV ($BV) on $HM ($ARCH)"
echo "   uname -v: $UV"
case $PV in
  27.3*) : ;;
  *) echo "WARNING: this Mac runs macOS $PV, not 27.3. The artifacts will NOT match the 27.3 stub firmware." >&2 ;;
esac
case $HM in
  Mac17,*) : ;;
  *) echo "WARNING: hw.model is '$HM'; the J716s MacBook Pro 16-inch M5 Pro reports Mac17,8 in its ADT." >&2 ;;
esac

# ---- 2. output directory (private area only) ------------------------------------------
abspath() {   # lexical absolute path with the nearest existing ancestor resolved (pwd -P)
  local p=$1 anc rest=
  case $p in /*) ;; *) p=$PWD/$p ;; esac
  anc=$p
  while [ ! -d "$anc" ]; do rest=/$(basename "$anc")$rest; anc=$(dirname "$anc"); done
  printf '%s%s\n' "$(cd "$anc" && pwd -P)" "$rest"
}
[ -n "$OUT" ] || OUT="$HOME/Work/studio-artifacts/macos-$PV-$BV"
OUT=$(abspath "${OUT%/}")
HOME_P=$(cd "$HOME" && pwd -P)
case $OUT in
  "$HOME_P/Documents/GitHub"/*|"$HOME/Documents/GitHub"/*|"$HOME_P/Work/agents"/*|"$HOME/Work/agents"/*)
    die "refusing OUTDIR under a repo / agent area: $OUT (use ~/Work/studio-artifacts/...)" ;;
esac
d=$OUT
while [ "$d" != / ] && [ -n "$d" ]; do
  if [ -e "$d/.git" ]; then die "refusing OUTDIR inside a git work tree ($d): $OUT"; fi
  d=$(dirname "$d")
done
mkdir -p "$OUT/meta" "$OUT/fs" "$OUT/ioreg" || die "cannot create $OUT"
chmod 700 "$OUT" 2>/dev/null
# belt and braces: if anything ever makes this a repo, git sees nothing
printf '*\n' > "$OUT/.gitignore"
note "output: $OUT (private; contains serials and hashes)"

# ---- 3. version record ---------------------------------------------------------------
{
  echo "pulled_at_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host: $HOST"
  echo "--- sw_vers"; rsh 'sw_vers' 2>&1
  echo "--- uname -a"; rsh 'uname -a' 2>&1
  echo "--- uname -v"; echo "$UV"
  echo "--- sysctl"; rsh 'sysctl hw.model hw.machine kern.osversion kern.osproductversion' 2>&1
} > "$OUT/meta/VERSION.txt" 2>&1
note "build string recorded: $OUT/meta/VERSION.txt"

# ---- 4. discovery on the Mac (read-only, no root) -----------------------------------
note "listing AGX / G17 kexts in /System/Library/Extensions"
rsh "ls /System/Library/Extensions | grep -iE 'agx|g17'" > "$OUT/meta/ls-extensions-agx-g17.txt" 2>&1
sed 's/^/   /' "$OUT/meta/ls-extensions-agx-g17.txt"
rsh "find /System/Volumes/Preboot -maxdepth 6 -iname '*kernelcache*' -o -iname '*.kc' 2>/dev/null" \
  > "$OUT/meta/find-preboot-kernelcache-depth6.txt" 2>&1

note "discovering artifacts (this walks Preboot; a few seconds)"
rsh_script > "$OUT/meta/inventory.tsv" 2>"$CTL/disc.err" <<'REMOTE'
# prints: TAG <tab> PATH <tab> KiB <tab> ok|noread
PB=/System/Volumes/Preboot
emit() {
  p=$2
  [ -e "$p" ] || [ -L "$p" ] || return 0
  if [ -r "$p" ] && { [ ! -d "$p" ] || [ -x "$p" ]; }; then r=ok; else r=noread; fi
  kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
  [ -n "$kb" ] || kb=0
  printf '%s\t%s\t%s\t%s\n' "$1" "$p" "$kb" "$r"
}
each() { tag=$1; shift; while IFS= read -r p; do [ -n "$p" ] && emit "$tag" "$p"; done; }

EXT=/System/Library/Extensions
PF=/System/Library/PrivateFrameworks
# AGX: G17 kexts, Metal G17 bundles, firmware kexts, AGX frameworks (all pattern-based)
find "$EXT" -maxdepth 1 \( -iname '*G17*' -o -iname 'AppleAGX*' -o -iname 'AGXFirmwareKextRTBuddy*' \) 2>/dev/null | sort | each agx
find "$PF"  -maxdepth 1 \( -iname '*G17*' -o -iname 'AGX*' \) 2>/dev/null | sort | each agx-fw
# DCP / display
find "$EXT" -maxdepth 1 \( -iname 'AppleDCP*' -o -iname 'DCP*' -o -iname 'IOMobileGraphicsFamily*' \
     -o -iname 'AppleMobileDispT605X*' -o -iname 'AppleDisplayCrossbar*' \) 2>/dev/null | sort | each dcp
find "$PF"  -maxdepth 1 \( -iname 'IOMobileGraphicsFamily*' -o -iname 'DCP*' \) 2>/dev/null | sort | each dcp-fw
# plain kernels (T6050 and the generic one), boot / system / aux collections on the system volume
find /System/Library/Kernels -maxdepth 1 \( -name kernel -o -name 'kernel.release.t605*' \) 2>/dev/null | sort | each kernel
for d in /System/Library/KernelCollections /Library/KernelCollections; do emit kc "$d"; done
# Preboot: kernelcaches / kernel collections / auxkc files (img4), KernelCollections dirs,
# the per-hash standalone firmware (iBoot, devicetree.img4, FUD, ...) and the boot/active policy pointer
find "$PB" -maxdepth 10 \( -name cryptex1 -o -name Cryptexes -o -name staging -o -name restore -o -name restore-staged -o -name KernelCollections \) -prune -o -type f \
     \( -iname '*kernelcache*' -o -iname '*.kc' -o -iname '*AuxiliaryKernelExtensions*' \) -print 2>/dev/null | sort | each kc
find "$PB" -maxdepth 10 \( -name cryptex1 -o -name Cryptexes -o -name staging -o -name restore -o -name restore-staged \) -prune -o \
     -type d \( -name KernelCollections -o -iname '*AuxiliaryKernelExtensions*' -o -path '*/usr/standalone/firmware' \) -print 2>/dev/null | sort | each boot-fw
for f in "$PB"/*/boot/active; do emit boot-meta "$f"; done
# restore bundles: the whole directory (kernelcache.release.*, BuildManifest.plist, Firmware/**: agx armfw_g17*.im4p,
# dcp, pmp, AOP, ane, ave, all_flash, t2026macG1/Release, ...). Small (tens of MiB).
for d in "$PB"/*/restore "$PB"/*/restore-staged; do emit restore "$d"; done
# version plists
emit meta /System/Library/CoreServices/SystemVersion.plist
emit meta /System/Library/CoreServices/SystemVersionCompat.plist
REMOTE
[ -s "$OUT/meta/inventory.tsv" ] || { cat "$CTL/disc.err" >&2; die "discovery returned nothing"; }
[ -s "$CTL/disc.err" ] && sed 's/^/   remote: /' "$CTL/disc.err" >&2

TAB=$(printf '\t')
# de-duplicate by path (first tag wins), then order by tag and path
sort -t "$TAB" -k2,2 -u "$OUT/meta/inventory.tsv" | sort -t "$TAB" -k1,1 -k2,2 > "$CTL/inv.tsv"
mv "$CTL/inv.tsv" "$OUT/meta/inventory.tsv"

# status column for the table: ok -> "will-copy", noread -> "NO-READ"
awk -F'\t' -v OFS='\t' '{ print ($4=="ok" ? "will-copy" : "NO-READ"), $1, $3, $2 }' "$OUT/meta/inventory.tsv" > "$CTL/plan.tsv"

print_table() {
  awk -F'\t' '
    function h(k) { if (k>=1048576) return sprintf("%.2f GiB",k/1048576); if (k>=1024) return sprintf("%.1f MiB",k/1024); return sprintf("%d KiB",k) }
    BEGIN { printf "%-11s %-9s %11s  %s\n","STATUS","TAG","SIZE","PATH" }
    { printf "%-11s %-9s %11s  %s\n",$1,$2,h($3),$4
      if ($1=="will-copy"||$1=="copied"||$1=="partial") t+=$3; else if ($1!="") skipped++ }
    END { printf "%-11s %-9s %11s  (%d entries not copied)\n","","TOTAL",h(t),skipped }' "$1"
}

note "size estimate (remote du -sk; ioreg/text dumps add ~30 MiB)"
print_table "$CTL/plan.tsv"
TOTAL_KB=$(awk -F'\t' '$1=="will-copy"{t+=$3} END{print t+0}' "$CTL/plan.tsv")
TOTAL_KB=$((TOTAL_KB + 30720))
LIMIT_KB=$((MAX_GB * 1024 * 1024))
echo "   estimated total: $(hs "$TOTAL_KB") (limit ${MAX_GB} GiB)"
if [ "$TOTAL_KB" -gt "$LIMIT_KB" ] && [ "$YES" != 1 ]; then
  die "estimate $(hs "$TOTAL_KB") exceeds ${MAX_GB} GiB; rerun with --yes (or --max-gb N) to proceed"
fi
AVAIL_KB=$(df -Pk "$OUT" | awk 'NR==2{print $4}')
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt $((TOTAL_KB + TOTAL_KB / 10)) ]; then
  die "not enough free space under $OUT: need ~$(hs $((TOTAL_KB + TOTAL_KB / 10))), have $(hs "$AVAIL_KB")"
fi
if [ "$LIST_ONLY" = 1 ]; then
  note "--list: nothing copied. Inventory: $OUT/meta/inventory.tsv"
  exit 0
fi

# ---- 5. copy (read-only on the Mac) ----------------------------------------------------
if [ "$USE_RSYNC" = 1 ]; then
  RS_OK=$(rsh 'command -v rsync >/dev/null 2>&1 && echo yes' 2>/dev/null)
  [ "$RS_OK" = yes ] || USE_RSYNC=0
fi
RSYNC_SSH="ssh ${SSH_ARGS[*]}"
if [ "$USE_RSYNC" = 1 ]; then note "copying with rsync -a --no-perms"; else note "copying with scp -r (rsync not available on both ends)"; fi

: > "$CTL/result.tsv"
while IFS="$TAB" read -r tag p kb rd; do
  [ -n "$p" ] || continue
  if [ "$rd" != ok ]; then
    printf 'NO-READ\t%s\t%s\t%s\n' "$tag" "$kb" "$p" >> "$CTL/result.tsv"; continue
  fi
  dest="$OUT/fs$(dirname "$p")"
  mkdir -p "$dest" || { printf 'FAILED\t%s\t0\t%s\n' "$tag" "$p" >> "$CTL/result.tsv"; continue; }
  if [ "$USE_RSYNC" = 1 ]; then
    rp=$(printf '%s' "$p" | sed 's/ /\\ /g')
    rsync -a --no-perms --no-owner --no-group -e "$RSYNC_SSH" "$HOST:$rp" "$dest/" 2>"$CTL/cp.err"
    rc=$?
  else
    scp -r -q "${SSH_ARGS[@]}" "$HOST:$p" "$dest/" 2>"$CTL/cp.err"
    rc=$?
  fi
  got=0
  [ -e "$dest/$(basename "$p")" ] && got=$(du -sk "$dest/$(basename "$p")" 2>/dev/null | awk '{print $1}')
  if [ "$rc" = 0 ]; then st=copied
  elif [ "${got:-0}" -gt 0 ]; then st=partial
  else st=FAILED; fi
  if [ "$rc" != 0 ]; then echo "   $st (rc=$rc): $p" >&2; sed 's/^/      /' "$CTL/cp.err" | head -5 >&2; fi
  printf '%s\t%s\t%s\t%s\n' "$st" "$tag" "${got:-0}" "$p" >> "$CTL/result.tsv"
done < "$OUT/meta/inventory.tsv"
chmod -R u+rwX "$OUT/fs" 2>/dev/null

# ---- 6. text dumps (ioreg contains serials: stays in the private dir) -----------------
dump() {   # dump <outfile relative to OUT> <remote command string>
  local f=$1; shift
  if rsh "$*" > "$OUT/$f" 2>"$CTL/d.err" && [ -s "$OUT/$f" ]; then
    printf 'copied\ttext\t%s\t%s\n' "$(du -sk "$OUT/$f" | awk '{print $1}')" "(remote) $*" >> "$CTL/result.tsv"
  else
    printf 'FAILED\ttext\t0\t(remote) %s\n' "$*" >> "$CTL/result.tsv"
    sed 's/^/   /' "$CTL/d.err" | head -3 >&2
    [ -s "$OUT/$f" ] || rm -f "${OUT:?}/${f:?}"
  fi
}
if [ "$SKIP_IOREG" != 1 ]; then
  note "capturing ioreg (device tree as macOS sees it; ~15 s each)"
  dump ioreg/ioreg-l-w0.txt                'ioreg -l -w0'
  dump ioreg/ioreg-IODeviceTree-l-w0.txt   'ioreg -p IODeviceTree -l -w0'
  # small extras, best effort, all non-root. nvram: variable NAMES only plus the boot selectors
  # (the full dump can hold tokens).
  dump meta/system-profiler-displays.txt   'system_profiler SPDisplaysDataType'
  dump meta/kmutil-showloaded.txt          'kmutil showloaded --list-only'
  dump meta/kmutil-inspect-installed.txt   'kmutil inspect -z --show-kext-uuids --show-kext-load-addresses --no-header'
  dump meta/preboot-boot-active.txt        'for f in /System/Volumes/Preboot/*/boot/active; do echo "$f"; cat "$f"; echo; done'
  dump meta/nvram-names.txt                'nvram -p | cut -f1'
  dump meta/nvram-boot-vars.txt            'nvram -p | grep -E "^(boot-volume|alt-boot-volume|upgrade-boot-volume|auto-boot)[[:space:]]"; true'
  dump meta/diskutil-list.txt              'diskutil list'
  dump meta/diskutil-apfs-list.txt         'diskutil apfs list'
fi

# ---- 7. table, manifest ------------------------------------------------------------------
cp "$CTL/result.tsv" "$OUT/meta/COPIED.tsv"
echo
note "result"
print_table "$CTL/result.tsv"
NBAD=$(awk -F'\t' '$1!="copied"{n++} END{print n+0}' "$CTL/result.tsv")
if [ "$NBAD" -gt 0 ]; then
  echo "   $NBAD entries were not copied cleanly (NO-READ = needs root, skipped on purpose; FAILED/partial = see messages above)."
fi

note "writing MANIFEST.txt (sha256 + size; private dir only)"
MAN="$OUT/MANIFEST.txt"
{
  echo "# macOS $PV ($BV) from $HM, pulled $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# PRIVATE: do not copy into any repo. sha256  size_bytes  path (relative to this directory)"
} > "$MAN"
( cd "$OUT" && find . -type f ! -name MANIFEST.txt ! -name .gitignore -print0 | sort -z ) |
while IFS= read -r -d '' f; do
  printf '%s  %12s  %s\n' "$(SHA "$OUT/$f")" "$(FSIZE "$OUT/$f")" "${f#./}"
done >> "$MAN"
NFILES=$(grep -vc '^#' "$MAN")
echo "   $NFILES files listed in $MAN"
note "done. Next: see EXTRACT.md (kernelcache -> kext extraction, first RE step)."
