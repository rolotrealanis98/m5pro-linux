#!/usr/bin/env python3
# Generates deploy-W2.sh (or deploy-W2b.sh) from mk-daily.py --deploy-plan (steps 0-2) plus guard 0b, as
# n1-wifi/prep/gen-deploy.py does for W0/W1, with one change: the guard knows both dailies of 2026-11-07
# (dcec81ed, the WFI daily now in boot.bin per aurora/STATE.md, and 275d84ec, its predecessor), so it never
# "restores" the old daily over the new one.
#   python3 -I gen-deploy-w2.py <payload file name in aurora-kernel/payloads> [TAG]
# It prints only "wrote deploy-<TAG>.sh"; the script itself is written next to this file (w2/prep/).
import pathlib, subprocess, sys
H = pathlib.Path.home()
T = H/"Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools"
O = H/"Work/agents/aurora-kernel/payloads"
HERE = pathlib.Path(__file__).resolve().parent
name = sys.argv[1]
tag = sys.argv[2] if len(sys.argv) > 2 else "W2"
DAILIES = ["dcec81eda0d83d7c746f44c767b8e2967ea038938ef76a3632edcb1857701655",
           "275d84ecfee87a2441e9cbd3f550129101dc82680e38abdb01c37c159af8d030"]
GUARD = '''# 0b. GUARD (added by prep): boot.bin.prev must end up as a known daily (dcec81ed or 275d84ec). The stock plan copies
#     whatever boot.bin is onto prev when the RUNNING payload is not a test; after an A/B stage-1 fallback boot.bin is
#     still the failed test while the machine runs the daily, and the stock plan would then overwrite prev with it.
ssh "${SSHO[@]}" "$HOST" 'bash -s' <<'REMOTE'
set -eu
cd /boot/m1n1
known() { case "$1" in DAILYLIST) return 0;; *) return 1;; esac; }
bs=$(sha256sum boot.bin | cut -d' ' -f1); ps=$(sha256sum boot.bin.prev | cut -d' ' -f1)
if grep -q 'm5.selftest=1' /proc/cmdline; then
    known "$ps" || { echo "ABORT: running a test and boot.bin.prev is not a known daily ($ps)"; exit 1; }
    echo "guard ok: test boot running, prev is a known daily (${ps:0:8})"
elif known "$bs"; then
    echo "guard ok: boot.bin is a known daily (${bs:0:8}); the plan makes prev = it"
elif known "$ps"; then
    echo "boot.bin is a leftover failed test and the machine runs the daily: restoring boot.bin from prev"
    cp boot.bin.prev boot.bin.restore && sync
    [ "$(sha256sum boot.bin.restore | cut -d' ' -f1)" = "$ps" ] || { rm -f boot.bin.restore; echo ABORT; exit 1; }
    mv -f boot.bin.restore boot.bin && sync && echo "boot.bin = daily ${ps:0:8} again"
else
    echo "ABORT: neither boot.bin nor boot.bin.prev is a known daily: stop and ask Rolando"; exit 1
fi
REMOTE

'''.replace("DAILYLIST", "|".join(DAILIES))
raw = subprocess.run([sys.executable, "-I", str(T/"mk-daily.py"), "--deploy-plan", "--payload", str(O/name),
                      "--host", "root@LINUX_IP"], check=True, capture_output=True, text=True).stdout
head = raw.split("# 3. reboot", 1)[0]
old = "HOST=root@LINUX_IP            # the running Linux root, over ssh"
assert old in head
head = head.replace(old, "HOST=${HOST:?set HOST=root@<macbook-ip>}   # the running Linux root, over ssh")
m = "# 1. copy to boot.bin.new"
assert m in head
head = head.replace(m, GUARD + m)
body = (f"#!/usr/bin/env bash\n# deploy {name}: steps 0-2 of mk-daily.py --deploy-plan plus guard 0b. Does NOT reboot.\n"
        f"# usage: HOST=root@<macbook-ip> bash deploy-{tag}.sh\nset -eu\n" + head)
(HERE/f"deploy-{tag}.sh").write_text(body)
print("wrote", f"deploy-{tag}.sh")
