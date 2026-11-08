#!/usr/bin/env python3
# GPU recovery2 TEST payloads, adapted from mk-recovery-test.py (same loader, variables, initramfs, tool):
#   daily-dcp-recovery2-test              bootargs of the recovery test: m5.selftest=1 watchdog.open_timeout=300 + EXTRA
#   daily-dcp-recovery2-pause2000-test    the same + aurora.m5_pause_timeout_us=2000 (experiment H1, gpu/faults/HYPOTHESES.md)
# kernel = kbuild-r2/Image.gz = j716s-daily-dcp-recovery2 (ed7e1d0c42b0 + gpu/faults 0001, 0002), release in kbuild-r2/kernel.release
# dtb    = kbuild-r2/t6050-j716s-daily-dcp-recovery2.dtb (in-tree; none of the patches touches a DT)
# Output (0600) in this directory: <label>-<date>-<sha8>.bin, .recipe.txt, .rel, modules-<rel>.tar.zst, SHA256SUMS lines.
#   python3 -I mk-recovery2-test.py
import hashlib, importlib.util, os, pathlib, shutil, subprocess, sys, tempfile
H = pathlib.Path.home(); R = H/"Work/agents/gpu-recovery"; K = R/"kbuild-r2"
VARIANTS = [("daily-dcp-recovery2-test", ""), ("daily-dcp-recovery2-pause2000-test", " aurora.m5_pause_timeout_us=2000")]
TOOL = H/"Work/agents/loop-safety/mk-daily.py"
REPO_TOOL = H/"Documents/GitHub/m5pro-linux/contrib/validated/aurora/tools/mk-daily.py"
DIFF = H/"Documents/GitHub/m5pro-linux/contrib/pending/boot-ab/loop-safety/mk-daily.diff"
M1N1 = H/"Work/agents/daily-dcp/m1n1-build/m1n1-plain-n1-dt-gpu-dcp-phfix.bin"
IR = H/"Work/agents/loop-safety/private/initramfs-ftab-wdt2.cpio.gz"
DAILY_DTB = H/"Work/agents/daily-dcp/kbuild/t6050-j716s-daily-dcp.dtb"
sha = lambda b: hashlib.sha256(b).hexdigest()
PINS = {M1N1: "98906d2912b9de1b384065ad316d25eac88b56286ac495c0d7e2dbd6f8abd477",
        IR: "abb4716532fbe4f2e366b80645d664f6797dc2cda3a5a0622616b80a7844d208",
        DAILY_DTB: "c8f1b960fa59b662c0bf58d5e952aaf73f313d3c769107f2ff9fc7aad09a105d"}
NOTCH = b"chosen.asahi,show-notch=1\nchosen.m5pro,gpu=1\nchosen.m5,t6050-display=1\n"
EXTRA = "log_buf_len=16M appledrm.fw27_panel_vrr=1 rcupdate.rcu_cpu_stall_timeout=21"
for f, h in PINS.items():
    if sha(f.read_bytes()) != h: sys.exit(f"mk-recovery-test: {f}: sha256 {sha(f.read_bytes())} != pin {h}")
if len(M1N1.read_bytes()) != 0x410000: sys.exit("mk-recovery-test: loader is not 0x410000 bytes")
with tempfile.TemporaryDirectory() as td:
    t = pathlib.Path(td)/"mk-daily.py"; shutil.copy(REPO_TOOL, t)
    subprocess.run(["patch", "-s", str(t), str(DIFF)], check=True)
    if t.read_bytes() != TOOL.read_bytes(): sys.exit(f"mk-recovery-test: {TOOL} is not the repo mk-daily.py with {DIFF.name} applied")
sums = {l.split()[1]: l.split()[0] for l in (K/"SHA256SUMS").read_text().splitlines() if l.strip()}
rel = (K/"kernel.release").read_text().strip()
kern, dtb, mods = K/"Image.gz", K/"t6050-j716s-daily-dcp-recovery2.dtb", K/f"modules-{rel}.tar.zst"
for f in (kern, dtb, mods, K/"kernel.release"):
    if sha(f.read_bytes()) != sums[f.name]: sys.exit(f"mk-recovery-test: {f} does not match {K}/SHA256SUMS")
same_dtb = sha(dtb.read_bytes()) == PINS[DAILY_DTB]
R.mkdir(mode=0o700, exist_ok=True)
for LABEL, MORE in VARIANTS:
    spec = importlib.util.spec_from_file_location("mk_daily", TOOL); mk = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mk); mk.M1N1_SIZE = 0x410000; mk.NOTCH = NOTCH
    sys.argv = [str(TOOL), "--out", str(R), "--label", LABEL, "--battery", "--selftest", "--m1n1", str(M1N1), "--kernel", str(kern),
                "--dtb", str(dtb), "--initramfs", str(IR), "--extra", EXTRA + MORE]
    mk.main()
    p = sorted(R.glob(f"{LABEL}-2*.bin"), key=lambda x: x.stat().st_mtime)[-1]
    (R/(p.name[:-4] + ".rel")).write_text(rel + "\n")
    shutil.copyfile(mods, R/mods.name)
    r = p.with_name(p.name + ".recipe.txt")
    with open(r, "a") as f:
        f.write(f"note      built by mk-recovery2-test.py: loop-safety patched mk-daily.py as a module (diff applied, checked), M1N1_SIZE=0x410000\n"
                f"note      GPU recovery2 test payload ({LABEL}) for the daily daily-dcp-lfix-vrr-20261107-7e244836: same loader (phfix 98906d29), variables and VRR bootarg; "
                f"kernel = j716s-daily-dcp-recovery2 (bd53915f2ef1 + gpu/recovery 0001-0003 + gpu/faults 0001-0002, config = daily-dcp), release {rel}; "
                f"in-tree DTB {'identical to the daily c8f1b960' if same_dtb else 'DIFFERS from the daily c8f1b960'}; "
                f"initramfs = initramfs-ftab-wdt2 (daily ftab + watchdog opener v2); m5.selftest=1 + watchdog.open_timeout=300\n"
                f"note      extra bootargs: {EXTRA + MORE}\n"
                f"note      modules: modules-{rel}.tar.zst (daily list), install before booting: tar -C / -xf modules-{rel}.tar.zst && depmod {rel}\n"
                f"note      test: contrib/pending/gpu/recovery/{{stress-load.sh,fault-watch.sh}}; run-recovery2-test.sh drives it\n"
                f"note      deploy plan: python3 -I {H}/Work/agents/daily-dcp/mk-daily-dcp.py plan <this payload> root@<host> (0x410000 offset)\n")
    with open(R/"SHA256SUMS", "a") as f:
        have = (R/"SHA256SUMS").read_text() if (R/"SHA256SUMS").exists() else ""
        for x in (p, R/mods.name, R/(p.name[:-4] + ".rel"), kern, dtb):
            line = f"{sha(x.read_bytes())}  {x.name if x.parent == R else ('r2-' + x.name)}\n"
            if line not in have: f.write(line); have += line
    for x in list(R.glob(f"{LABEL}-2*")) + list(R.glob("modules-*")) + [R/"SHA256SUMS"]:
        os.chmod(x, 0o600)
    print(f"{LABEL}: {p}  {sha(p.read_bytes())}  release {rel}  dtb-same-as-daily={same_dtb}")
