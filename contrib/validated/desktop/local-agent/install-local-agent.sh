#!/usr/bin/env bash
# install-local-agent.sh: set up local Claude Code agents on the J716s MacBook.
#
# Run as root (ssh, or `sudo`) or as the target user. Idempotent: run it again after a BRIEF.md or SKILL.md change.
# It installs ~/.claude/skills/m5pro (SKILL.md + BRIEF.md), maintains one marked block in ~/.claude/CLAUDE.md, clones or
# updates ~/Work/m5pro-linux and ~/Work/m4-m5-linux, sets their git identity, creates the tracker labels, installs the
# one package the tracker's checks need (python-pytest), and prints a verification.
# It never touches /boot, Omarchy's own skill directories, ~/.claude/skills/synced, credentials or any system config.
#
#   install-local-agent.sh [--dry-run] [--no-clone] [--no-labels] [--no-pkgs] [--user NAME]
#
# The script, SKILL.md and BRIEF.md must sit in the same directory (copy the whole local-agent/ directory over).
set -euo pipefail

TARGET_USER=${M5PRO_USER:-rolo}
GIT_NAME="Rolando Trevino"
GIT_EMAIL="rolotrealanis@gmail.com"
REPO_OWNER=rolotrealanis98
M5_REPO=m5pro-linux
TRACKER_REPO=m4-m5-linux
DRY=0 DO_CLONE=1 DO_LABELS=1 DO_PKGS=1

while (($#)); do
  case $1 in
    --dry-run) DRY=1 ;;
    --no-clone) DO_CLONE=0 ;;
    --no-labels) DO_LABELS=0 ;;
    --no-pkgs) DO_PKGS=0 ;;
    --user) TARGET_USER=${2:?--user needs a name}; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for f in SKILL.md BRIEF.md; do
  [[ -f $SRC/$f ]] || { echo "missing $SRC/$f (copy the whole local-agent directory)" >&2; exit 1; }
done
grep -q '^name: m5pro$' "$SRC/SKILL.md" || { echo "SKILL.md frontmatter name is not m5pro" >&2; exit 1; }

hash12() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -c1-12; }

# Who am I, who is the target
if [[ -n ${TARGET_HOME:-} ]]; then HOME_DIR=$TARGET_HOME          # test override
elif command -v getent >/dev/null; then HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
else HOME_DIR=$(eval echo "~$TARGET_USER"); fi
[[ -n $HOME_DIR && -d $HOME_DIR ]] || { echo "no home directory for user $TARGET_USER" >&2; exit 1; }
TARGET_UID=$(id -u "$TARGET_USER"); TARGET_GID=$(id -g "$TARGET_USER")
ME=$(id -u)
if ((ME != 0 && ME != TARGET_UID)); then
  echo "run as root or as $TARGET_USER" >&2; exit 1
fi
IS_ROOT=0; ((ME == 0)) && IS_ROOT=1

WARN=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; WARN=$((WARN + 1)); }
step() { printf '\n== %s\n' "$*"; }
mut()  { if ((DRY)); then printf '  (dry-run) %s\n' "$*"; return 0; fi; "$@"; }

# Run a command as the target user with HOME set.
as_user() {
  if ((IS_ROOT)) && [[ $TARGET_USER != root ]]; then
    runuser -u "$TARGET_USER" -- env HOME="$HOME_DIR" "$@"
  else
    env HOME="$HOME_DIR" "$@"
  fi
}
# Same through a login shell (mise shims put gh and claude on PATH there), with the user's session bus so gh can reach
# the desktop keyring when the script runs over ssh.
as_user_login() {
  local bus=/run/user/$TARGET_UID/bus env_args=("HOME=$HOME_DIR" GH_PROMPT_DISABLED=1)
  if [[ -S $bus ]]; then env_args+=("XDG_RUNTIME_DIR=/run/user/$TARGET_UID" "DBUS_SESSION_BUS_ADDRESS=unix:path=$bus"); fi
  if ((IS_ROOT)) && [[ $TARGET_USER != root ]]; then
    runuser -u "$TARGET_USER" -- env "${env_args[@]}" bash -lc "$1"
  else
    env "${env_args[@]}" bash -lc "$1"
  fi
}
# install -d / install with the target user's ownership when root.
own_args=(); ((IS_ROOT)) && own_args=(-o "$TARGET_UID" -g "$TARGET_GID")
put_dir()  { mut install -d "${own_args[@]}" -m 0755 "$1"; }
put_file() { mut install "${own_args[@]}" -m "${3:-0644}" "$1" "$2"; }

CLAUDE_DIR=$HOME_DIR/.claude
SKILL_DIR=$CLAUDE_DIR/skills/m5pro
CLAUDE_MD=$CLAUDE_DIR/CLAUDE.md
WORK=$HOME_DIR/Work
BEGIN_MARK='<!-- BEGIN m5pro-local-agent (managed by install-local-agent.sh; edit the source in m5pro-linux, not here) -->'
END_MARK='<!-- END m5pro-local-agent -->'

# ---------------------------------------------------------------------------------------------------------------------
step "1. Skill: $SKILL_DIR"
if [[ -L $SKILL_DIR ]]; then
  echo "refusing: $SKILL_DIR is a symlink, not ours" >&2; exit 1
fi
put_dir "$CLAUDE_DIR"; put_dir "$CLAUDE_DIR/skills"; put_dir "$SKILL_DIR"
put_file "$SRC/SKILL.md" "$SKILL_DIR/SKILL.md"
put_file "$SRC/BRIEF.md" "$SKILL_DIR/BRIEF.md"
((DRY)) || say "  installed SKILL.md and BRIEF.md (Omarchy's skill directories are not touched)"

# ---------------------------------------------------------------------------------------------------------------------
step "2. CLAUDE.md block: $CLAUDE_MD"
block=$(mktemp)
trap 'rm -f "$block" "${newmd:-}"' EXIT
cat >"$block" <<BLOCK
$BEGIN_MARK
## This machine

This is the J716s Linux machine (MacBook Pro 16-inch M5 Pro, Omarchy on Arch ARM, hand-built boot chain). Read
\`~/.claude/skills/m5pro/BRIEF.md\` before changing anything, and use the \`m5pro\` skill for every desktop, audio, network,
app or crash task here. The brief's HARD RULES apply to every session, including a crash diagnosis started from the
"Process crashed" notification: never touch /boot, the kernel, firmware, the GPU session files or the speaker ceiling; never
reboot, restart the session or NetworkManager, or run \`omarchy update\`/\`pacman -Syu\`, without asking Rolando in chat. For a
crash, follow \`diagnose-crash\` plus the m5pro crash checklist (check \`dmesg\` for "GPU work of a client failed" first).
Fixes and bugs are recorded in the repos and tracker described in the brief.
$END_MARK
BLOCK
if [[ -f $CLAUDE_MD ]]; then
  nb=$(grep -c -F "<!-- BEGIN m5pro-local-agent" "$CLAUDE_MD" || true)
  ne=$(grep -c -F "<!-- END m5pro-local-agent" "$CLAUDE_MD" || true)
  if ((nb == 0 && ne == 0)); then
    if [[ ! -e $CLAUDE_MD.pre-m5pro ]]; then mut cp -p "$CLAUDE_MD" "$CLAUDE_MD.pre-m5pro"; fi
    if ((DRY)); then say "  (dry-run) append the block"; else
      { [[ -s $CLAUDE_MD ]] && echo; cat "$block"; } >>"$CLAUDE_MD"
      say "  appended the block (original kept as CLAUDE.md.pre-m5pro)"
    fi
  elif ((nb == 1 && ne == 1)); then
    newmd=$(mktemp)
    awk -v blk="$block" '
      index($0, "<!-- BEGIN m5pro-local-agent") { while ((getline l < blk) > 0) print l; skip = 1; next }
      index($0, "<!-- END m5pro-local-agent")   { skip = 0; next }
      !skip { print }' "$CLAUDE_MD" >"$newmd"
    if ((DRY)); then say "  (dry-run) replace the block"; else cat "$newmd" >"$CLAUDE_MD"; say "  replaced the existing block"; fi
  else
    echo "refusing: $CLAUDE_MD has unbalanced m5pro markers (BEGIN=$nb END=$ne); fix by hand" >&2; exit 1
  fi
else
  if ((DRY)); then say "  (dry-run) create with the block"; else cat "$block" >"$CLAUDE_MD"; say "  created with the block"; fi
fi
if ((IS_ROOT && !DRY)); then chown "$TARGET_UID:$TARGET_GID" "$CLAUDE_MD"; fi

# ---------------------------------------------------------------------------------------------------------------------
step "3. Packages the tracker checks need"
if ((DO_PKGS)); then
  if command -v pacman >/dev/null; then
    if pacman -Q python-pytest >/dev/null 2>&1; then
      ok "python-pytest already installed"
    elif ((IS_ROOT)); then
      say "  installing python-pytest (single package; the boot-chain guard is not triggered)"
      # No -y/-u: no database refresh, no upgrades. A failure (stale database) is reported, never worked around.
      mut pacman -S --needed --noconfirm python-pytest || warn "pacman -S python-pytest failed; ask Rolando (do not run -Sy)"
    else
      warn "python-pytest missing: run 'sudo pacman -S --needed python-pytest' (tracker 'make check' needs it)"
    fi
  else
    say "  no pacman here (test run): skipped"
  fi
else
  say "  skipped (--no-pkgs)"
fi

# ---------------------------------------------------------------------------------------------------------------------
step "4. Clones under $WORK"
sync_clone() {  # name
  local name=$1 dir=$WORK/$1 url=https://github.com/$REPO_OWNER/$1.git
  if [[ ! -d $dir/.git ]]; then
    put_dir "$WORK"
    mut as_user git clone --quiet "$url" "$dir"; ((DRY)) || say "  cloned $name"
  else
    local origin; origin=$(as_user git -C "$dir" remote get-url origin 2>/dev/null || true)
    if [[ $origin != "$url" && $origin != "${url%.git}" ]]; then
      warn "$dir has origin '$origin', expected $url; left alone"
      return 0
    fi
    if [[ -n $(as_user git -C "$dir" status --porcelain) ]]; then
      mut as_user git -C "$dir" fetch --quiet origin || true
      warn "$name has uncommitted changes: fetched only, not rebased"
    elif [[ $(as_user git -C "$dir" rev-parse --abbrev-ref HEAD) != main ]]; then
      mut as_user git -C "$dir" fetch --quiet origin || true
      warn "$name is not on main: fetched only"
    else
      mut as_user git -C "$dir" pull --quiet --rebase origin main; ((DRY)) || say "  updated $name"
    fi
  fi
  if [[ -d $dir/.git ]] || ((DRY)); then
    mut as_user git -C "$dir" config user.name "$GIT_NAME"
    mut as_user git -C "$dir" config user.email "$GIT_EMAIL"
    mut as_user git -C "$dir" config pull.rebase true
    mut as_user git -C "$dir" config rebase.autoStash true
  fi
}
if ((DO_CLONE)); then
  sync_clone "$M5_REPO"
  sync_clone "$TRACKER_REPO"
else
  say "  skipped (--no-clone)"
fi

# ---------------------------------------------------------------------------------------------------------------------
step "5. Tracker labels on $REPO_OWNER/$TRACKER_REPO"
LABELS=(
  "machine:j716s|1d76db|MacBook Pro 16-inch M5 Pro (J716s)"
  "attended|fbca04|Needs a person at the machine (hands or eyes)"
  "in-flight|0e8a16|Being worked on now"
  "blocked|b60205|Needs something not available yet"
  "upstream|5319e7|Waits for a kernel, loader, Mesa or Omarchy change"
  "help-wanted|008672|Extra attention is needed"
)
if ((DO_LABELS)); then
  if as_user_login "gh api user --jq .login" 2>/dev/null | grep -qx "$REPO_OWNER"; then
    for l in "${LABELS[@]}"; do
      IFS='|' read -r name color desc <<<"$l"
      # --force updates an existing label; idempotent.
      mut as_user_login "gh label create '$name' --color '$color' --description '$desc' --force -R $REPO_OWNER/$TRACKER_REPO >/dev/null" \
        && say "  label $name" || warn "could not create label $name"
    done
  else
    warn "gh is not logged in as $REPO_OWNER for this shell (ssh sessions often cannot reach the keyring). Create the labels from a desktop terminal:"
    for l in "${LABELS[@]}"; do
      IFS='|' read -r name color desc <<<"$l"
      say "        gh label create '$name' --color '$color' --description '$desc' --force -R $REPO_OWNER/$TRACKER_REPO"
    done
  fi
else
  say "  skipped (--no-labels)"
fi

# ---------------------------------------------------------------------------------------------------------------------
step "Verification"
if ((DRY)); then say "  (dry-run: nothing was changed, nothing to verify)"; exit 0; fi

for f in SKILL.md BRIEF.md; do
  if [[ -f $SKILL_DIR/$f ]] && cmp -s "$SRC/$f" "$SKILL_DIR/$f"; then
    ok "$SKILL_DIR/$f matches the source (sha256 $(hash12 "$SKILL_DIR/$f"))"
  else warn "$SKILL_DIR/$f differs from the source or is missing"; fi
done
[[ $(stat -c %U "$SKILL_DIR/SKILL.md" 2>/dev/null || stat -f %Su "$SKILL_DIR/SKILL.md") == "$TARGET_USER" ]] \
  && ok "skill files are owned by $TARGET_USER" || warn "skill files are not owned by $TARGET_USER"

if [[ $(grep -c -F "<!-- BEGIN m5pro-local-agent" "$CLAUDE_MD") == 1 ]] && grep -q 'skills/m5pro/BRIEF.md' "$CLAUDE_MD"; then
  ok "CLAUDE.md has exactly one m5pro block"
else warn "CLAUDE.md block missing or duplicated"; fi

for n in diagnose-crash omarchy omarchy-app; do
  p=$CLAUDE_DIR/skills/$n
  if [[ -L $p ]]; then ok "Omarchy skill $n untouched ($(readlink "$p"))"
  elif [[ -e $p ]]; then say "  info  $n is a real directory here (not ours, left alone)"
  else say "  info  $n not present"; fi
done

if ((DO_CLONE)); then
  for name in "$M5_REPO" "$TRACKER_REPO"; do
    d=$WORK/$name
    if [[ -d $d/.git ]]; then
      ok "$name: $(as_user git -C "$d" rev-parse --short HEAD) on $(as_user git -C "$d" rev-parse --abbrev-ref HEAD), author $(as_user git -C "$d" config user.name) <$(as_user git -C "$d" config user.email)>, origin $(as_user git -C "$d" remote get-url origin)"
    else warn "$d is not a clone"; fi
  done
  if [[ -f $WORK/$TRACKER_REPO/tools/validate.py ]]; then
    if (cd "$WORK/$TRACKER_REPO" && as_user python3 tools/validate.py >/dev/null 2>&1 && as_user python3 tools/privacy_scan.py >/dev/null 2>&1); then
      ok "tracker: tools/validate.py and tools/privacy_scan.py pass"
    else warn "tracker checks fail on a fresh clone (run 'make check' there and read the output)"; fi
  fi
  [[ -d $WORK/$M5_REPO/contrib/validated/desktop ]] && ok "m5pro-linux has contrib/validated/desktop/" || warn "m5pro-linux clone looks incomplete"
fi

claude_bin=$(as_user_login 'command -v claude' 2>/dev/null || true)
[[ -n $claude_bin ]] && ok "claude for $TARGET_USER: $claude_bin" || warn "claude not found in $TARGET_USER's login PATH"
gh_user=$(as_user_login 'gh api user --jq .login' 2>/dev/null || true)
[[ $gh_user == "$REPO_OWNER" ]] && ok "gh authenticated as $gh_user" || warn "gh is not authenticated as $REPO_OWNER in this shell (got '${gh_user:-nothing}'); fine if run over ssh, check from a desktop terminal"
if [[ -n $gh_user ]]; then
  have=$(as_user_login "gh label list -R $REPO_OWNER/$TRACKER_REPO --limit 100 --json name --jq '.[].name'" 2>/dev/null || true)
  miss=""
  for l in "${LABELS[@]}"; do n=${l%%|*}; grep -qx "$n" <<<"$have" || miss+=" $n"; done
  [[ -z $miss ]] && ok "tracker labels present" || warn "tracker labels missing:$miss"
fi
if as_user dmesg 2>/dev/null | head -1 | grep -q .; then ok "dmesg is readable by $TARGET_USER"; else warn "dmesg not readable by $TARGET_USER (crash checklist needs it)"; fi
if as_user sudo -n true 2>/dev/null; then say "  info  sudo is passwordless for $TARGET_USER (unexpected, brief says it asks for a password)"
else say "  info  sudo needs a password for $TARGET_USER, so local agents have no root (as designed)"; fi

# Crash-notification wiring (information only)
if [[ -r /usr/bin/omarchy-agent-crash && -r /usr/bin/omarchy-agent ]]; then
  say "  info  crash path: omarchy-crash-watch -> omarchy-agent-crash (fixed prompt naming the diagnose-crash skill)"
  say "        -> omarchy-agent --prompt -> 'claude --permission-mode auto -- <prompt>' started in ~/Work."
  say "        The prompt and skill list cannot be extended (no hook, variable or config file); the user-level CLAUDE.md block"
  say "        installed above is what reaches that session, and the skill description makes m5pro load as well."
  as_user_login 'echo "        default agent: $(omarchy-default-agent 2>/dev/null || cat ~/.config/omarchy/defaults/agent 2>/dev/null)"' 2>/dev/null || true
fi

echo
if ((WARN)); then echo "Done with $WARN warning(s); read the WARN lines above."; else echo "Done, no warnings."; fi
echo "Start a new Claude Code session on the machine for it to pick up the skill and CLAUDE.md block."
