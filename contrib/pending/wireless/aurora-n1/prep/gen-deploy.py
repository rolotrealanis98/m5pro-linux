#!/usr/bin/env python3
# Regenerates deploy-W0.sh / deploy-W1.sh from mk-daily.py --deploy-plan (steps 0-2) plus guard 0b.
#   python3 -I gen-deploy.py
import pathlib, subprocess, sys
H = pathlib.Path.home()
T = H/"Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools"
O = H/"Work/agents/aurora-kernel/payloads"
HERE = pathlib.Path(__file__).resolve().parent
DAILY = "275d84ecfee87a2441e9cbd3f550129101dc82680e38abdb01c37c159af8d030"
GUARD = '''# 0b. GUARD (added by prep): boot.bin.prev must end up as the daily DAILY8. The stock plan copies whatever boot.bin is
#     onto prev when the RUNNING payload is not a test; after an A/B stage-1 fallback boot.bin is still the failed test
#     while the machine runs the daily, and the stock plan would then overwrite prev with the failed test.
ssh "${SSHO[@]}" "$HOST" 'bash -s' <<'REMOTE'
set -eu
cd /boot/m1n1
D=DAILYFULL
bs=$(sha256sum boot.bin | cut -d' ' -f1); ps=$(sha256sum boot.bin.prev | cut -d' ' -f1)
if grep -q 'm5.selftest=1' /proc/cmdline; then
    [ "$ps" = "$D" ] || { echo "ABORT: running a test and boot.bin.prev is not the daily ($ps)"; exit 1; }
    echo "guard ok: test boot running, prev is the daily"
elif [ "$bs" = "$D" ]; then
    echo "guard ok: boot.bin is the daily (the plan will make prev = daily)"
elif [ "$ps" = "$D" ]; then
    echo "boot.bin is a leftover failed test and the machine runs the daily: restoring boot.bin from prev"
    cp boot.bin.prev boot.bin.restore && sync
    [ "$(sha256sum boot.bin.restore | cut -d' ' -f1)" = "$D" ] || { rm -f boot.bin.restore; echo ABORT; exit 1; }
    mv -f boot.bin.restore boot.bin && sync && echo "boot.bin = daily again"
else
    echo "ABORT: neither boot.bin nor boot.bin.prev is the daily: stop and ask Rolando"; exit 1
fi
REMOTE

'''.replace("DAILY8", DAILY[:8]).replace("DAILYFULL", DAILY)
for tag, name in (("W0", "w0-n1dt-20261107-24276a09.bin"), ("W1", "w1-n1train-20261107-3c0a1eff.bin")):
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
