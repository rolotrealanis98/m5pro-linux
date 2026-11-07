#!/bin/bash
# Re-apply PR #938 (T6050 protocol-27 N1 Wi-Fi/BT) on top of PR #937 in /Volumes/linux-cs/wt-n1.
# integration/aurora carries a different N1 driver (J813/J873, board table, no DT firmware-name)
# under the same file names. Policy per commit C: the driver files (drivers/net/wireless/apple/**,
# drivers/bluetooth/btcentauri.c, the two centauri bindings) become exactly C's tree; the
# bluetooth Kconfig/Makefile swap integration's BT_CENTAURI for the PR's BT_HCICENTAURI; every
# other file is the normal 3-way cherry-pick result.
set -euo pipefail
cd /Volumes/linux-cs/wt-n1
G="git -c user.name=n1 -c user.email=n1@local"
L=/Volumes/linux-cs/linux
for C in $(git -C $L rev-list --reverse aurora/pr-937-pcie..aurora/pr-938-n1); do
    $G cherry-pick -n -x "$C" >/dev/null 2>&1 || true
    # driver dirs = C's tree, extras removed
    for f in $(git ls-files drivers/net/wireless/apple drivers/bluetooth/btcentauri.c \
                  Documentation/devicetree/bindings/net/wireless/apple,centauri.yaml \
                  Documentation/devicetree/bindings/net/bluetooth/apple,centauri.yaml); do
        git cat-file -e "$C:$f" 2>/dev/null || git rm -q --cached -f "$f" && rm -f "$f" 2>/dev/null || true
    done
    for f in $(git ls-tree -r --name-only "$C" -- drivers/net/wireless/apple drivers/bluetooth/btcentauri.c \
                  Documentation/devicetree/bindings/net/wireless/apple,centauri.yaml \
                  Documentation/devicetree/bindings/net/bluetooth/apple,centauri.yaml); do
        git checkout "$C" -- "$f"
    done
    # bluetooth Kconfig/Makefile: start from HEAD, drop BT_CENTAURI, add C's BT_HCICENTAURI if C has it
    git checkout HEAD -- drivers/bluetooth/Kconfig drivers/bluetooth/Makefile
    python3 - "$C" <<'PY'
import re, subprocess, sys
C = sys.argv[1]
def show(p):
    r = subprocess.run(["git", "show", f"{C}:{p}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""
k = open("drivers/bluetooth/Kconfig").read()
k = re.sub(r"\nconfig BT_CENTAURI\n(?:\t.*\n|\n(?=\t))*", "\n", k)
ck = show("drivers/bluetooth/Kconfig")
m = re.search(r"\nconfig BT_HCICENTAURI\n(?:\t.*\n|\n(?=\t))*", ck)
if m:
    k = k.replace("\nendmenu", m.group(0).rstrip("\n") + "\n\nendmenu", 1) if "BT_HCICENTAURI" not in k else k
open("drivers/bluetooth/Kconfig", "w").write(k)
mk = open("drivers/bluetooth/Makefile").read()
mk = re.sub(r"obj-\$\(CONFIG_BT_CENTAURI\)\s*\+= btcentauri\.o\n", "", mk)
if "BT_HCICENTAURI" in show("drivers/bluetooth/Makefile") and "BT_HCICENTAURI" not in mk:
    mk = mk.rstrip("\n") + "\nobj-$(CONFIG_BT_HCICENTAURI) += btcentauri.o\n"
open("drivers/bluetooth/Makefile", "w").write(mk)
PY
    git add -A drivers/bluetooth/Kconfig drivers/bluetooth/Makefile
    if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
        echo "UNRESOLVED in $C:"; git diff --name-only --diff-filter=U; exit 1
    fi
    git add -A
    msg=$(git -C $L log -1 --format=%B "$C")
    $G commit -q --no-verify -C "$C" >/dev/null
    $G commit -q --amend --no-verify -m "$msg

(cherry picked from commit $C)
[n1-wifi: on aurora-j716s this driver replaces integration's J813/J873 N1 driver files]"
    echo "picked $C -> $(git log -1 --format='%h %s')"
done
